using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using HerdrOps.Domain.Evidence;
using Microsoft.Data.Sqlite;

namespace HerdrOps.Infrastructure.Storage;

public sealed partial class SqliteHerdrStateStore
{
    private const int EvidenceCopyBufferSize = 128 * 1024;
    private const string RetentionPendingDirectoryName = ".retention";
    private const string RetentionPendingFileSuffix = ".pending";

    private static readonly JsonSerializerOptions EvidenceSerializerOptions =
        new(JsonSerializerDefaults.Web)
        {
            AllowDuplicateProperties = false,
            AllowTrailingCommas = false,
            MaxDepth = 32,
            PropertyNameCaseInsensitive = false,
            ReadCommentHandling = JsonCommentHandling.Disallow,
            RespectRequiredConstructorParameters = true,
            UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
            WriteIndented = false,
        };

    // Internal diagnostic hook (InternalsVisibleTo: HerdrOps.IntegrationTests).
    // Raised only after the retention transaction acquired its IMMEDIATE write
    // reservation. Tests use it as a deterministic barrier for SQLite
    // contention; production behavior does not depend on the hook.
    internal event Action? EvidenceRetentionTransactionStarted;

    public HerdrEvidenceWriteResult CaptureEvidence(
        EvidenceCaptureRequest request,
        string artifactPath)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (string.IsNullOrWhiteSpace(artifactPath) ||
            !Path.IsPathFullyQualified(artifactPath))
        {
            throw new ArgumentException(
                "The evidence artifact path must be absolute.",
                nameof(artifactPath));
        }

        artifactPath = Path.GetFullPath(artifactPath);
        lock (_sync)
        {
            ThrowIfDisposed();
            if (!File.Exists(artifactPath))
            {
                var missing = EvidenceMetadataContract.Create(
                    request,
                    EvidenceArtifactAvailability.Missing,
                    contentLength: null,
                    contentSha256: null,
                    managedRelativePath: null);
                return PersistEvidence(missing, stagedPath: null);
            }

            if (!request.CreateManagedCopy)
            {
                var digest = ComputeFileDigest(artifactPath);
                var external = EvidenceMetadataContract.Create(
                    request,
                    EvidenceArtifactAvailability.Present,
                    digest.Length,
                    digest.Sha256,
                    managedRelativePath: null);
                return PersistEvidence(external, stagedPath: null);
            }

            var stagedPath = StageManagedEvidence(artifactPath, out var stagedDigest);
            try
            {
                var provisional = EvidenceMetadataContract.Create(
                    request,
                    EvidenceArtifactAvailability.Present,
                    stagedDigest.Length,
                    stagedDigest.Sha256,
                    "objects/provisional.evidence");
                var identity = provisional.EvidenceIdentitySha256;
                var relativePath = $"objects/{identity[..2]}/{identity[2..4]}/{identity}.evidence";
                var managed = EvidenceMetadataContract.Create(
                    request,
                    EvidenceArtifactAvailability.Present,
                    stagedDigest.Length,
                    stagedDigest.Sha256,
                    relativePath);
                return PersistEvidence(managed, stagedPath);
            }
            finally
            {
                TryDeleteManagedFile(stagedPath);
            }
        }
    }

    public HerdrStoredEvidence? ReadEvidence(string evidenceIdentitySha256)
    {
        var identity = EvidenceMetadataContract.NormalizeEvidenceIdentity(
            evidenceIdentitySha256);
        lock (_sync)
        {
            ThrowIfDisposed();
            return ReadEvidenceCore(identity, verifyManagedBytes: true);
        }
    }

    public IReadOnlyList<HerdrStoredEvidence> ReadTaskEvidence(string taskId)
    {
        taskId = NormalizeEvidenceIdentifier(taskId, nameof(taskId));
        lock (_sync)
        {
            ThrowIfDisposed();
            using var command = _connection.CreateCommand();
            command.CommandText = """
                SELECT evidence_identity_sha256
                FROM evidence_items
                WHERE task_id = $taskId
                ORDER BY observed_utc, evidence_identity_sha256;
                """;
            command.Parameters.AddWithValue("$taskId", taskId);
            var identities = new List<string>();
            using (var reader = command.ExecuteReader())
            {
                while (reader.Read())
                {
                    identities.Add(reader.GetString(0));
                }
            }

            return identities
                .Select(identity => ReadEvidenceCore(identity, verifyManagedBytes: true)
                    ?? throw new HerdrStateStoreException(
                        $"Evidence metadata '{identity}' disappeared during a locked read."))
                .ToArray();
        }
    }

    public HerdrReviewAuditWriteResult AppendReviewAudit(
        ReviewAuditAppendRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        lock (_sync)
        {
            ThrowIfDisposed();
            using var transaction = _connection.BeginTransaction(deferred: false);
            var existing = ReadReviewAuditEventById(request.AuditEventId, transaction);
            if (existing is not null)
            {
                var expected = ReviewAuditContract.Create(
                    request,
                    existing.Sequence,
                    existing.PreviousAuditSha256);
                if (!string.Equals(
                        expected.AuditSha256,
                        existing.AuditSha256,
                        StringComparison.Ordinal))
                {
                    throw new HerdrStateStoreException(
                        $"Review audit event '{request.AuditEventId:D}' already exists with different immutable content.");
                }

                transaction.Commit();
                return new HerdrReviewAuditWriteResult(existing, WasAlreadyPresent: true);
            }

            var previous = ReadLatestReviewAuditEvent(request.ReviewCaseId, transaction);
            var auditEvent = ReviewAuditContract.Create(
                request,
                previous?.Sequence + 1 ?? 1,
                previous?.AuditSha256);
            ValidateReviewTransition(previous, auditEvent);
            EnsureEvidenceLinksExist(auditEvent.EvidenceIdentitySha256s, transaction);
            InsertReviewAuditEvent(auditEvent, transaction);
            transaction.Commit();
            return new HerdrReviewAuditWriteResult(auditEvent, WasAlreadyPresent: false);
        }
    }

    public IReadOnlyList<ReviewAuditEvent> ReadReviewAudit(string reviewCaseId)
    {
        reviewCaseId = NormalizeEvidenceIdentifier(reviewCaseId, nameof(reviewCaseId));
        lock (_sync)
        {
            ThrowIfDisposed();
            using var transaction = _connection.BeginTransaction();
            using var command = _connection.CreateCommand();
            command.Transaction = transaction;
            command.CommandText = """
                SELECT audit_event_id
                FROM review_audit_events
                WHERE review_case_id = $reviewCaseId
                ORDER BY sequence;
                """;
            command.Parameters.AddWithValue("$reviewCaseId", reviewCaseId);
            var eventIds = new List<Guid>();
            using (var reader = command.ExecuteReader())
            {
                while (reader.Read())
                {
                    eventIds.Add(ParseGuid(reader.GetString(0), "audit_event_id"));
                }
            }

            var events = eventIds
                .Select(eventId => ReadReviewAuditEventById(eventId, transaction)
                    ?? throw new HerdrStateStoreException(
                        $"Review audit event '{eventId:D}' disappeared during a locked read."))
                .ToArray();
            ReviewAuditEvent? previous = null;
            foreach (var auditEvent in events)
            {
                ValidateReviewTransition(previous, auditEvent);
                previous = auditEvent;
            }

            transaction.Commit();
            return events;
        }
    }

    public HerdrEvidenceRetentionBatchResult ApplyEvidenceRetention(
        DateTimeOffset asOfUtc)
    {
        if (asOfUtc.Offset != TimeSpan.Zero)
        {
            throw new ArgumentException(
                "The evidence-retention cutoff must be UTC.",
                nameof(asOfUtc));
        }

        lock (_sync)
        {
            ThrowIfDisposed();
            using var transaction = _connection.BeginTransaction(deferred: false);
            EvidenceRetentionTransactionStarted?.Invoke();
            var results = new List<HerdrEvidenceRetentionResult>();
            RecoverPendingRetention(asOfUtc, results, transaction);
            var identities = ReadDueEvidenceIdentities(asOfUtc, transaction);
            results.EnsureCapacity(results.Count + identities.Count);
            foreach (var identity in identities)
            {
                if (IsProtectedByOpenReview(identity, transaction))
                {
                    results.Add(new HerdrEvidenceRetentionResult(
                        identity,
                        HerdrEvidenceRetentionOutcome.ProtectedByOpenReview,
                        asOfUtc,
                        RetentionEventId: null,
                        RetentionAuditSha256: null));
                    continue;
                }

                var stored = ReadEvidenceCore(
                        identity,
                        verifyManagedBytes: true,
                        transaction: transaction)
                    ?? throw new HerdrStateStoreException(
                        $"Due evidence metadata '{identity}' disappeared during retention.");
                var metadata = stored.Metadata;
                if (metadata.ManagedRelativePath is null ||
                    metadata.ContentLength is null ||
                    metadata.ContentSha256 is null)
                {
                    throw new HerdrStateStoreException(
                        $"Due managed evidence '{identity}' has incomplete immutable metadata.");
                }

                HerdrEvidenceRetentionOutcome outcome;
                string? pendingPath = null;
                if (stored.ManagedBytesAvailable)
                {
                    pendingPath = MoveManagedEvidenceToRetentionPending(metadata);
                    outcome = HerdrEvidenceRetentionOutcome.Purged;
                }
                else
                {
                    outcome = HerdrEvidenceRetentionOutcome.AlreadyMissing;
                }

                var retentionEvent = CreateRetentionAuditEvent(metadata, outcome);
                InsertRetentionAuditEventInTransaction(retentionEvent, transaction);
                if (pendingPath is not null)
                {
                    DeleteRetentionPendingFile(pendingPath, identity);
                }

                results.Add(new HerdrEvidenceRetentionResult(
                    identity,
                    outcome,
                    asOfUtc,
                    retentionEvent.RetentionEventId,
                    retentionEvent.RetentionAuditSha256));
            }

            transaction.Commit();
            return new HerdrEvidenceRetentionBatchResult(asOfUtc, results);
        }
    }

    public IReadOnlyList<HerdrEvidenceRetentionAuditEvent> ReadEvidenceRetentionAudit()
    {
        lock (_sync)
        {
            ThrowIfDisposed();
            using var command = _connection.CreateCommand();
            command.CommandText = """
                SELECT retention_event_id, evidence_identity_sha256, occurred_utc,
                       outcome, managed_relative_path, expected_content_length,
                       expected_content_sha256, retention_audit_sha256
                FROM evidence_retention_events
                ORDER BY occurred_utc, retention_event_id;
                """;
            var result = new List<HerdrEvidenceRetentionAuditEvent>();
            using var reader = command.ExecuteReader();
            while (reader.Read())
            {
                var auditEvent = new HerdrEvidenceRetentionAuditEvent(
                    ParseGuid(reader.GetString(0), "retention_event_id"),
                    EvidenceMetadataContract.NormalizeEvidenceIdentity(reader.GetString(1)),
                    ParseUtc(reader.GetString(2)),
                    (HerdrEvidenceRetentionOutcome)reader.GetInt32(3),
                    reader.GetString(4),
                    reader.GetInt64(5),
                    reader.GetString(6),
                    reader.GetString(7));
                ValidateRetentionAuditEvent(auditEvent);
                result.Add(auditEvent);
            }

            return result;
        }
    }

    private HerdrEvidenceWriteResult PersistEvidence(
        EvidenceMetadata metadata,
        string? stagedPath)
    {
        metadata = EvidenceMetadataContract.NormalizeAndValidate(metadata);
        var existing = ReadEvidenceCore(
            metadata.EvidenceIdentitySha256,
            verifyManagedBytes: true);
        if (existing is not null)
        {
            if (!string.Equals(
                    existing.Metadata.MetadataSha256,
                    metadata.MetadataSha256,
                    StringComparison.Ordinal))
            {
                throw new HerdrStateStoreException(
                    $"Evidence identity '{metadata.EvidenceIdentitySha256}' already exists with different immutable metadata.");
            }

            return new HerdrEvidenceWriteResult(existing, WasAlreadyPresent: true);
        }

        string? finalPath = null;
        var createdManagedFile = false;
        try
        {
            if (metadata.StorageKind == EvidenceArtifactStorageKind.ManagedCopy)
            {
                if (stagedPath is null || metadata.ManagedRelativePath is null)
                {
                    throw new HerdrStateStoreException(
                        "Managed evidence requires a staged file and immutable relative path.");
                }

                finalPath = ResolveManagedPath(metadata.ManagedRelativePath);
                Directory.CreateDirectory(Path.GetDirectoryName(finalPath)!);
                finalPath = ResolveManagedPath(metadata.ManagedRelativePath);
                if (File.Exists(finalPath))
                {
                    ValidateManagedFile(finalPath, metadata);
                }
                else
                {
                    File.Move(stagedPath, finalPath);
                    createdManagedFile = true;
                }
            }

            var metadataJson = JsonSerializer.Serialize(metadata, EvidenceSerializerOptions);
            var metadataJsonSha256 = ComputeUtf8Sha256(metadataJson);
            using var transaction = _connection.BeginTransaction(deferred: false);
            using var command = _connection.CreateCommand();
            command.Transaction = transaction;
            command.CommandText = """
                INSERT INTO evidence_items(
                    evidence_identity_sha256, contract_version, task_id, actor_id,
                    source_event_id, source, source_reference, observed_utc,
                    ingested_utc, retain_until_utc, availability, storage_kind,
                    content_length, content_sha256, managed_relative_path,
                    metadata_json, metadata_json_sha256, metadata_sha256)
                VALUES (
                    $identity, $contractVersion, $taskId, $actorId,
                    $sourceEventId, $source, $sourceReference, $observedUtc,
                    $ingestedUtc, $retainUntilUtc, $availability, $storageKind,
                    $contentLength, $contentSha256, $managedRelativePath,
                    $metadataJson, $metadataJsonSha256, $metadataSha256);
                """;
            command.Parameters.AddWithValue("$identity", metadata.EvidenceIdentitySha256);
            command.Parameters.AddWithValue("$contractVersion", metadata.ContractVersion);
            command.Parameters.AddWithValue("$taskId", metadata.TaskId);
            command.Parameters.AddWithValue("$actorId", metadata.ActorId);
            command.Parameters.AddWithValue("$sourceEventId", metadata.SourceEventId);
            command.Parameters.AddWithValue("$source", metadata.Source);
            command.Parameters.AddWithValue("$sourceReference", metadata.SourceReference);
            command.Parameters.AddWithValue("$observedUtc", FormatUtc(metadata.ObservedUtc));
            command.Parameters.AddWithValue("$ingestedUtc", FormatUtc(metadata.IngestedUtc));
            command.Parameters.AddWithValue("$retainUntilUtc", FormatUtc(metadata.RetainUntilUtc));
            command.Parameters.AddWithValue("$availability", (int)metadata.Availability);
            command.Parameters.AddWithValue("$storageKind", (int)metadata.StorageKind);
            command.Parameters.AddWithValue("$contentLength", (object?)metadata.ContentLength ?? DBNull.Value);
            command.Parameters.AddWithValue("$contentSha256", (object?)metadata.ContentSha256 ?? DBNull.Value);
            command.Parameters.AddWithValue("$managedRelativePath", (object?)metadata.ManagedRelativePath ?? DBNull.Value);
            command.Parameters.AddWithValue("$metadataJson", metadataJson);
            command.Parameters.AddWithValue("$metadataJsonSha256", metadataJsonSha256);
            command.Parameters.AddWithValue("$metadataSha256", metadata.MetadataSha256);
            command.ExecuteNonQuery();
            transaction.Commit();
        }
        catch
        {
            if (createdManagedFile && finalPath is not null)
            {
                TryDeleteManagedFile(finalPath);
            }

            throw;
        }

        var stored = ReadEvidenceCore(
            metadata.EvidenceIdentitySha256,
            verifyManagedBytes: true)
            ?? throw new HerdrStateStoreException(
                $"Evidence '{metadata.EvidenceIdentitySha256}' was not readable after insertion.");
        return new HerdrEvidenceWriteResult(stored, WasAlreadyPresent: false);
    }

    private HerdrStoredEvidence? ReadEvidenceCore(
        string evidenceIdentitySha256,
        bool verifyManagedBytes,
        bool allowPendingRetention = false,
        SqliteTransaction? transaction = null)
    {
        using var command = _connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = """
            SELECT evidence_identity_sha256, contract_version, task_id, actor_id,
                   source_event_id, source, source_reference, observed_utc,
                   ingested_utc, retain_until_utc, availability, storage_kind,
                   content_length, content_sha256, managed_relative_path,
                   metadata_json, metadata_json_sha256, metadata_sha256
            FROM evidence_items
            WHERE evidence_identity_sha256 = $identity;
            """;
        command.Parameters.AddWithValue("$identity", evidenceIdentitySha256);
        EvidenceMetadata metadata;
        using (var reader = command.ExecuteReader())
        {
            if (!reader.Read())
            {
                return null;
            }

            metadata = ReadAndValidateEvidenceMetadata(reader);
            if (reader.Read())
            {
                throw new HerdrStateStoreException(
                    $"Evidence identity '{evidenceIdentitySha256}' is not unique.");
            }
        }

        var retentionCompleted = HasRetentionEvent(evidenceIdentitySha256, transaction);
        var managedBytesAvailable = false;
        if (metadata.StorageKind == EvidenceArtifactStorageKind.ManagedCopy)
        {
            var path = ResolveManagedPath(metadata.ManagedRelativePath!);
            var pendingPath = GetRetentionPendingPath(metadata.EvidenceIdentitySha256);
            managedBytesAvailable = IsConfirmedRegularFile(
                path,
                $"Managed evidence bytes '{metadata.EvidenceIdentitySha256}'");
            var pendingBytesAvailable = IsConfirmedRegularFile(
                pendingPath,
                $"Pending retention bytes '{metadata.EvidenceIdentitySha256}'");
            if (managedBytesAvailable && pendingBytesAvailable)
            {
                throw new HerdrStateStoreException(
                    $"Managed evidence '{metadata.EvidenceIdentitySha256}' exists at both its object and pending-retention paths.");
            }

            if (pendingBytesAvailable && !allowPendingRetention)
            {
                throw new HerdrStateStoreException(
                    $"Managed evidence '{metadata.EvidenceIdentitySha256}' has an incomplete retention operation that must be recovered before reading.");
            }

            if (managedBytesAvailable && retentionCompleted)
            {
                throw new HerdrStateStoreException(
                    $"Managed evidence '{metadata.EvidenceIdentitySha256}' has bytes after its terminal retention event.");
            }

            if (managedBytesAvailable && verifyManagedBytes)
            {
                ValidateManagedFile(path, metadata);
            }

            if (pendingBytesAvailable && verifyManagedBytes)
            {
                ValidateManagedFile(pendingPath, metadata);
            }
        }

        return new HerdrStoredEvidence(
            metadata,
            managedBytesAvailable,
            retentionCompleted);
    }

    private static EvidenceMetadata ReadAndValidateEvidenceMetadata(SqliteDataReader reader)
    {
        var metadataJson = reader.GetString(15);
        if (!string.Equals(
                reader.GetString(16),
                ComputeUtf8Sha256(metadataJson),
                StringComparison.Ordinal))
        {
            throw new HerdrStateStoreException(
                "Persisted evidence metadata JSON failed its SHA-256 check.");
        }

        var metadata = DeserializeEvidence<EvidenceMetadata>(
            metadataJson,
            "evidence metadata");
        try
        {
            metadata = EvidenceMetadataContract.NormalizeAndValidate(metadata);
        }
        catch (EvidenceContractException exception)
        {
            throw new HerdrStateStoreException(
                "Persisted evidence metadata failed its canonical contract.",
                exception);
        }

        if (!string.Equals(metadata.EvidenceIdentitySha256, reader.GetString(0), StringComparison.Ordinal) ||
            metadata.ContractVersion != reader.GetInt32(1) ||
            !string.Equals(metadata.TaskId, reader.GetString(2), StringComparison.Ordinal) ||
            !string.Equals(metadata.ActorId, reader.GetString(3), StringComparison.Ordinal) ||
            !string.Equals(metadata.SourceEventId, reader.GetString(4), StringComparison.Ordinal) ||
            !string.Equals(metadata.Source, reader.GetString(5), StringComparison.Ordinal) ||
            !string.Equals(metadata.SourceReference, reader.GetString(6), StringComparison.Ordinal) ||
            metadata.ObservedUtc != ParseUtc(reader.GetString(7)) ||
            metadata.IngestedUtc != ParseUtc(reader.GetString(8)) ||
            metadata.RetainUntilUtc != ParseUtc(reader.GetString(9)) ||
            (int)metadata.Availability != reader.GetInt32(10) ||
            (int)metadata.StorageKind != reader.GetInt32(11) ||
            !NullableInt64Equals(metadata.ContentLength, reader, 12) ||
            !NullableTextEquals(metadata.ContentSha256, reader, 13) ||
            !NullableTextEquals(metadata.ManagedRelativePath, reader, 14) ||
            !string.Equals(metadata.MetadataSha256, reader.GetString(17), StringComparison.Ordinal))
        {
            throw new HerdrStateStoreException(
                $"Persisted evidence scalar columns do not match metadata '{metadata.EvidenceIdentitySha256}'.");
        }

        return metadata;
    }

    private string StageManagedEvidence(
        string sourcePath,
        out FileDigest digest)
    {
        var stagingDirectory = Path.Combine(ManagedEvidenceRootPath, ".staging");
        Directory.CreateDirectory(stagingDirectory);
        var stagedPath = Path.Combine(stagingDirectory, $"{Guid.NewGuid():N}.tmp");
        EnsureManagedPathHasNoReparsePoints(stagedPath);
        try
        {
            using var source = OpenEvidenceReadStream(sourcePath);
            using var destination = new FileStream(
                stagedPath,
                FileMode.CreateNew,
                FileAccess.Write,
                FileShare.None,
                EvidenceCopyBufferSize,
                FileOptions.SequentialScan | FileOptions.WriteThrough);
            using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            var buffer = new byte[EvidenceCopyBufferSize];
            long length = 0;
            int read;
            while ((read = source.Read(buffer, 0, buffer.Length)) > 0)
            {
                hash.AppendData(buffer, 0, read);
                destination.Write(buffer, 0, read);
                length = checked(length + read);
            }

            destination.Flush(flushToDisk: true);
            digest = new FileDigest(length, Convert.ToHexString(hash.GetHashAndReset()));
            return stagedPath;
        }
        catch
        {
            TryDeleteManagedFile(stagedPath);
            throw;
        }
    }

    private static FileDigest ComputeFileDigest(string path)
    {
        using var stream = OpenEvidenceReadStream(path);
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        var buffer = new byte[EvidenceCopyBufferSize];
        long length = 0;
        int read;
        while ((read = stream.Read(buffer, 0, buffer.Length)) > 0)
        {
            hash.AppendData(buffer, 0, read);
            length = checked(length + read);
        }

        return new FileDigest(length, Convert.ToHexString(hash.GetHashAndReset()));
    }

    private static FileStream OpenEvidenceReadStream(string path) =>
        new(
            path,
            FileMode.Open,
            FileAccess.Read,
            FileShare.Read,
            EvidenceCopyBufferSize,
            FileOptions.SequentialScan);

    private static void ValidateManagedFile(
        string path,
        EvidenceMetadata metadata)
    {
        var digest = ComputeFileDigest(path);
        if (digest.Length != metadata.ContentLength ||
            !string.Equals(digest.Sha256, metadata.ContentSha256, StringComparison.Ordinal))
        {
            throw new HerdrStateStoreException(
                $"Managed evidence bytes failed the immutable length/SHA-256 check for '{metadata.EvidenceIdentitySha256}'.");
        }
    }

    private string ResolveManagedPath(string relativePath)
    {
        var normalized = relativePath.Replace('/', Path.DirectorySeparatorChar);
        var root = Path.GetFullPath(ManagedEvidenceRootPath)
            .TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        var candidate = Path.GetFullPath(Path.Combine(root, normalized));
        if (!candidate.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
        {
            throw new HerdrStateStoreException(
                "Managed evidence metadata resolved outside the configured vault.");
        }

        EnsureManagedPathHasNoReparsePoints(candidate);
        return candidate;
    }

    private void EnsureManagedVaultRootIsSafe() =>
        EnsureManagedPathHasNoReparsePoints(ManagedEvidenceRootPath);

    private void EnsureManagedVaultParentChainIsSafe()
    {
        var root = Path.GetFullPath(ManagedEvidenceRootPath)
            .TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        var filesystemRoot = Path.GetPathRoot(root);
        if (string.IsNullOrWhiteSpace(filesystemRoot))
        {
            throw new HerdrStateStoreException(
                "The managed evidence vault has no filesystem or share root.");
        }

        var current = filesystemRoot;
        ValidateExistingDirectoryComponent(current);
        var relative = Path.GetRelativePath(filesystemRoot, root);
        foreach (var segment in relative.Split(
                     new[] { Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar },
                     StringSplitOptions.RemoveEmptyEntries))
        {
            current = Path.Combine(current, segment);
            ValidateExistingDirectoryComponent(current);
        }
    }

    private void EnsureManagedPathHasNoReparsePoints(string candidatePath)
    {
        var root = Path.GetFullPath(ManagedEvidenceRootPath)
            .TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        var candidate = Path.GetFullPath(candidatePath);
        if (!string.Equals(candidate, root, StringComparison.OrdinalIgnoreCase) &&
            !candidate.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
        {
            throw new HerdrStateStoreException(
                "Managed evidence path resolved outside the configured vault.");
        }

        EnsureManagedVaultParentChainIsSafe();
        if (string.Equals(candidate, root, StringComparison.OrdinalIgnoreCase))
        {
            return;
        }

        var relative = Path.GetRelativePath(root, candidate);
        var current = root;
        var segments = relative.Split(
            new[] { Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar },
            StringSplitOptions.RemoveEmptyEntries);
        for (var index = 0; index < segments.Length; index++)
        {
            current = Path.Combine(current, segments[index]);
            if (index < segments.Length - 1)
            {
                ValidateExistingDirectoryComponent(current);
            }
            else
            {
                RejectReparsePoint(current);
            }
        }
    }

    private static void RejectReparsePoint(string path)
    {
        var attributes = ReadPathAttributes(path, "Managed evidence vault path");
        if (attributes is null)
        {
            return;
        }

        if ((attributes.Value & FileAttributes.ReparsePoint) != 0)
        {
            throw new HerdrStateStoreException(
                $"Managed evidence vault path '{path}' contains a reparse point.");
        }
    }

    private static void ValidateExistingDirectoryComponent(string path)
    {
        var attributes = ReadPathAttributes(path, "Managed evidence vault ancestor");
        if (attributes is null)
        {
            return;
        }

        if ((attributes.Value & FileAttributes.ReparsePoint) != 0)
        {
            throw new HerdrStateStoreException(
                $"Managed evidence vault path '{path}' contains a reparse point.");
        }

        if ((attributes.Value & FileAttributes.Directory) == 0)
        {
            throw new HerdrStateStoreException(
                $"Managed evidence vault ancestor '{path}' is not a directory.");
        }
    }

    private static bool IsConfirmedRegularFile(string path, string description)
    {
        var attributes = ReadPathAttributes(path, description);
        if (attributes is null)
        {
            return false;
        }

        if ((attributes.Value & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0)
        {
            throw new HerdrStateStoreException(
                $"{description} is not a regular non-reparse file.");
        }

        return true;
    }

    private static FileAttributes? ReadPathAttributes(string path, string description)
    {
        try
        {
            return File.GetAttributes(path);
        }
        catch (FileNotFoundException)
        {
            return null;
        }
        catch (DirectoryNotFoundException)
        {
            return null;
        }
        catch (UnauthorizedAccessException exception)
        {
            throw new HerdrStateStoreException(
                $"{description} could not be inspected safely.",
                exception);
        }
        catch (IOException exception)
        {
            throw new HerdrStateStoreException(
                $"{description} could not be inspected safely.",
                exception);
        }
    }

    private void TryDeleteManagedFile(string path)
    {
        try
        {
            EnsureManagedPathHasNoReparsePoints(path);
            if (File.Exists(path))
            {
                File.Delete(path);
            }
        }
        catch (HerdrStateStoreException)
        {
        }
        catch (IOException)
        {
        }
        catch (UnauthorizedAccessException)
        {
        }
    }

    private void InsertReviewAuditEvent(
        ReviewAuditEvent auditEvent,
        SqliteTransaction transaction)
    {
        var auditJson = JsonSerializer.Serialize(auditEvent, EvidenceSerializerOptions);
        using (var command = _connection.CreateCommand())
        {
            command.Transaction = transaction;
            command.CommandText = """
                INSERT INTO review_audit_events(
                    audit_event_id, contract_version, review_case_id, sequence,
                    reviewer_actor_id, reviewer_role, action_kind, review_state,
                    reason, occurred_utc, evidence_set_sha256,
                    previous_audit_sha256, audit_sha256, audit_json,
                    audit_json_sha256)
                VALUES (
                    $eventId, $contractVersion, $reviewCaseId, $sequence,
                    $reviewerActorId, $reviewerRole, $actionKind, $reviewState,
                    $reason, $occurredUtc, $evidenceSetSha256,
                    $previousAuditSha256, $auditSha256, $auditJson,
                    $auditJsonSha256);
                """;
            command.Parameters.AddWithValue("$eventId", auditEvent.AuditEventId.ToString("D"));
            command.Parameters.AddWithValue("$contractVersion", auditEvent.ContractVersion);
            command.Parameters.AddWithValue("$reviewCaseId", auditEvent.ReviewCaseId);
            command.Parameters.AddWithValue("$sequence", auditEvent.Sequence);
            command.Parameters.AddWithValue("$reviewerActorId", auditEvent.ReviewerActorId);
            command.Parameters.AddWithValue("$reviewerRole", auditEvent.ReviewerRole);
            command.Parameters.AddWithValue("$actionKind", (int)auditEvent.ActionKind);
            command.Parameters.AddWithValue("$reviewState", (int)auditEvent.ReviewState);
            command.Parameters.AddWithValue("$reason", auditEvent.Reason);
            command.Parameters.AddWithValue("$occurredUtc", FormatUtc(auditEvent.OccurredUtc));
            command.Parameters.AddWithValue("$evidenceSetSha256", auditEvent.EvidenceSetSha256);
            command.Parameters.AddWithValue("$previousAuditSha256", (object?)auditEvent.PreviousAuditSha256 ?? DBNull.Value);
            command.Parameters.AddWithValue("$auditSha256", auditEvent.AuditSha256);
            command.Parameters.AddWithValue("$auditJson", auditJson);
            command.Parameters.AddWithValue("$auditJsonSha256", ComputeUtf8Sha256(auditJson));
            command.ExecuteNonQuery();
        }

        foreach (var evidenceIdentity in auditEvent.EvidenceIdentitySha256s)
        {
            using var link = _connection.CreateCommand();
            link.Transaction = transaction;
            link.CommandText = """
                INSERT INTO review_audit_evidence(audit_event_id, evidence_identity_sha256)
                VALUES ($eventId, $evidenceIdentity);
                """;
            link.Parameters.AddWithValue("$eventId", auditEvent.AuditEventId.ToString("D"));
            link.Parameters.AddWithValue("$evidenceIdentity", evidenceIdentity);
            link.ExecuteNonQuery();
        }
    }

    private ReviewAuditEvent? ReadReviewAuditEventById(
        Guid eventId,
        SqliteTransaction transaction)
    {
        using var command = _connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = """
            SELECT audit_event_id, contract_version, review_case_id, sequence,
                   reviewer_actor_id, reviewer_role, action_kind, review_state,
                   reason, occurred_utc, evidence_set_sha256,
                   previous_audit_sha256, audit_sha256, audit_json,
                   audit_json_sha256
            FROM review_audit_events
            WHERE audit_event_id = $eventId;
            """;
        command.Parameters.AddWithValue("$eventId", eventId.ToString("D"));
        StoredReviewAuditRow row;
        using (var reader = command.ExecuteReader())
        {
            if (!reader.Read())
            {
                return null;
            }

            row = ReadReviewAuditRow(reader);
            if (reader.Read())
            {
                throw new HerdrStateStoreException(
                    $"Review audit event '{eventId:D}' is not unique.");
            }
        }

        var evidenceLinks = ReadReviewAuditEvidenceLinks(eventId, transaction);
        var auditEvent = DeserializeEvidence<ReviewAuditEvent>(
            row.AuditJson,
            "review audit event");
        try
        {
            auditEvent = ReviewAuditContract.NormalizeAndValidate(auditEvent);
        }
        catch (EvidenceContractException exception)
        {
            throw new HerdrStateStoreException(
                $"Persisted review audit event '{eventId:D}' failed its canonical contract.",
                exception);
        }

        if (auditEvent.AuditEventId != row.EventId ||
            auditEvent.ContractVersion != row.ContractVersion ||
            !string.Equals(auditEvent.ReviewCaseId, row.ReviewCaseId, StringComparison.Ordinal) ||
            auditEvent.Sequence != row.Sequence ||
            !string.Equals(auditEvent.ReviewerActorId, row.ReviewerActorId, StringComparison.Ordinal) ||
            !string.Equals(auditEvent.ReviewerRole, row.ReviewerRole, StringComparison.Ordinal) ||
            auditEvent.ActionKind != row.ActionKind ||
            auditEvent.ReviewState != row.ReviewState ||
            !string.Equals(auditEvent.Reason, row.Reason, StringComparison.Ordinal) ||
            auditEvent.OccurredUtc != row.OccurredUtc ||
            !string.Equals(auditEvent.EvidenceSetSha256, row.EvidenceSetSha256, StringComparison.Ordinal) ||
            !string.Equals(auditEvent.PreviousAuditSha256, row.PreviousAuditSha256, StringComparison.Ordinal) ||
            !string.Equals(auditEvent.AuditSha256, row.AuditSha256, StringComparison.Ordinal) ||
            !auditEvent.EvidenceIdentitySha256s.SequenceEqual(evidenceLinks, StringComparer.Ordinal))
        {
            throw new HerdrStateStoreException(
                $"Persisted review audit columns or evidence links do not match event '{eventId:D}'.");
        }

        return auditEvent;
    }

    private ReviewAuditEvent? ReadLatestReviewAuditEvent(
        string reviewCaseId,
        SqliteTransaction transaction)
    {
        reviewCaseId = NormalizeEvidenceIdentifier(reviewCaseId, nameof(reviewCaseId));
        using var command = _connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = """
            SELECT audit_event_id
            FROM review_audit_events
            WHERE review_case_id = $reviewCaseId
            ORDER BY sequence DESC
            LIMIT 1;
            """;
        command.Parameters.AddWithValue("$reviewCaseId", reviewCaseId);
        var value = command.ExecuteScalar();
        return value is null
            ? null
            : ReadReviewAuditEventById(
                ParseGuid(Convert.ToString(value, System.Globalization.CultureInfo.InvariantCulture)!, "audit_event_id"),
                transaction);
    }

    private static StoredReviewAuditRow ReadReviewAuditRow(SqliteDataReader reader)
    {
        var auditJson = reader.GetString(13);
        if (!string.Equals(reader.GetString(14), ComputeUtf8Sha256(auditJson), StringComparison.Ordinal))
        {
            throw new HerdrStateStoreException(
                "Persisted review audit JSON failed its SHA-256 check.");
        }

        return new StoredReviewAuditRow(
            ParseGuid(reader.GetString(0), "audit_event_id"),
            reader.GetInt32(1),
            reader.GetString(2),
            reader.GetInt64(3),
            reader.GetString(4),
            reader.GetString(5),
            (ReviewAuditActionKind)reader.GetInt32(6),
            (ReviewAuditState)reader.GetInt32(7),
            reader.GetString(8),
            ParseUtc(reader.GetString(9)),
            reader.GetString(10),
            reader.IsDBNull(11) ? null : reader.GetString(11),
            reader.GetString(12),
            auditJson);
    }

    private IReadOnlyList<string> ReadReviewAuditEvidenceLinks(
        Guid eventId,
        SqliteTransaction transaction)
    {
        using var command = _connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = """
            SELECT evidence_identity_sha256
            FROM review_audit_evidence
            WHERE audit_event_id = $eventId
            ORDER BY evidence_identity_sha256;
            """;
        command.Parameters.AddWithValue("$eventId", eventId.ToString("D"));
        var links = new List<string>();
        using var reader = command.ExecuteReader();
        while (reader.Read())
        {
            links.Add(EvidenceMetadataContract.NormalizeEvidenceIdentity(reader.GetString(0)));
        }

        return links;
    }

    private void EnsureEvidenceLinksExist(
        IReadOnlyList<string> evidenceIdentities,
        SqliteTransaction transaction)
    {
        foreach (var identity in evidenceIdentities)
        {
            using var command = _connection.CreateCommand();
            command.Transaction = transaction;
            command.CommandText = """
                SELECT COUNT(*)
                FROM evidence_items
                WHERE evidence_identity_sha256 = $identity;
                """;
            command.Parameters.AddWithValue("$identity", identity);
            if (Convert.ToInt64(command.ExecuteScalar(), System.Globalization.CultureInfo.InvariantCulture) != 1)
            {
                throw new HerdrStateStoreException(
                    $"Review audit evidence identity '{identity}' does not exist.");
            }

            command.CommandText = """
                SELECT COUNT(*)
                FROM evidence_retention_events
                WHERE evidence_identity_sha256 = $identity;
                """;
            if (Convert.ToInt64(command.ExecuteScalar(), System.Globalization.CultureInfo.InvariantCulture) != 0)
            {
                throw new HerdrStateStoreException(
                    $"Review audit evidence identity '{identity}' has already reached terminal retention.");
            }
        }
    }

    private static void ValidateReviewTransition(
        ReviewAuditEvent? previous,
        ReviewAuditEvent current)
    {
        if (previous is null)
        {
            if (current.Sequence != 1 ||
                current.PreviousAuditSha256 is not null ||
                current.ActionKind != ReviewAuditActionKind.Opened ||
                current.ReviewState != ReviewAuditState.Open)
            {
                throw new HerdrStateStoreException(
                    "A review case must start with one open event at sequence 1.");
            }

            return;
        }

        if (previous.ReviewState == ReviewAuditState.Closed)
        {
            throw new HerdrStateStoreException(
                $"Closed review case '{current.ReviewCaseId}' cannot accept more ordinary audit events.");
        }

        if (current.Sequence != previous.Sequence + 1 ||
            !string.Equals(current.PreviousAuditSha256, previous.AuditSha256, StringComparison.Ordinal) ||
            current.OccurredUtc < previous.OccurredUtc ||
            current.ActionKind == ReviewAuditActionKind.Opened ||
            (current.ActionKind == ReviewAuditActionKind.Closed) !=
                (current.ReviewState == ReviewAuditState.Closed))
        {
            throw new HerdrStateStoreException(
                $"Review case '{current.ReviewCaseId}' has an invalid append-only transition or hash chain.");
        }
    }

    private void RecoverPendingRetention(
        DateTimeOffset asOfUtc,
        List<HerdrEvidenceRetentionResult> results,
        SqliteTransaction transaction)
    {
        var pendingDirectory = GetRetentionPendingDirectory();
        EnsureManagedPathHasNoReparsePoints(pendingDirectory);
        var attributes = ReadPathAttributes(
            pendingDirectory,
            "The pending-retention directory");
        if (attributes is null)
        {
            return;
        }

        if ((attributes.Value & FileAttributes.Directory) == 0 ||
            (attributes.Value & FileAttributes.ReparsePoint) != 0)
        {
            throw new HerdrStateStoreException(
                "The pending-retention path is not a regular non-reparse directory.");
        }

        string[] entries;
        try
        {
            entries = Directory.GetFileSystemEntries(pendingDirectory);
        }
        catch (UnauthorizedAccessException exception)
        {
            throw new HerdrStateStoreException(
                "The pending-retention directory could not be enumerated safely.",
                exception);
        }
        catch (IOException exception)
        {
            throw new HerdrStateStoreException(
                "The pending-retention directory could not be enumerated safely.",
                exception);
        }

        foreach (var pendingPath in entries.Order(StringComparer.OrdinalIgnoreCase))
        {
            EnsureManagedPathHasNoReparsePoints(pendingPath);
            _ = IsConfirmedRegularFile(
                pendingPath,
                $"Pending retention entry '{pendingPath}'");
            var fileName = Path.GetFileName(pendingPath);
            if (!fileName.EndsWith(
                    RetentionPendingFileSuffix,
                    StringComparison.Ordinal))
            {
                throw new HerdrStateStoreException(
                    $"Pending retention entry '{fileName}' has an invalid name.");
            }

            var encodedIdentity = fileName[..^RetentionPendingFileSuffix.Length];
            string identity;
            try
            {
                identity = EvidenceMetadataContract.NormalizeEvidenceIdentity(encodedIdentity);
            }
            catch (EvidenceContractException exception)
            {
                throw new HerdrStateStoreException(
                    $"Pending retention entry '{fileName}' has an invalid evidence identity.",
                    exception);
            }

            if (!string.Equals(encodedIdentity, identity, StringComparison.Ordinal) ||
                !string.Equals(
                    Path.GetFullPath(pendingPath),
                    GetRetentionPendingPath(identity),
                    StringComparison.OrdinalIgnoreCase))
            {
                throw new HerdrStateStoreException(
                    $"Pending retention entry '{fileName}' is not canonically named.");
            }

            var stored = ReadEvidenceCore(
                identity,
                verifyManagedBytes: true,
                allowPendingRetention: true,
                transaction: transaction)
                ?? throw new HerdrStateStoreException(
                    $"Pending retention entry '{identity}' has no immutable evidence metadata.");
            var metadata = stored.Metadata;
            if (metadata.StorageKind != EvidenceArtifactStorageKind.ManagedCopy ||
                metadata.ManagedRelativePath is null ||
                metadata.ContentLength is null ||
                metadata.ContentSha256 is null)
            {
                throw new HerdrStateStoreException(
                    $"Pending retention entry '{identity}' has incomplete managed-evidence metadata.");
            }

            var existingEvent = ReadRetentionAuditEvent(identity, transaction);
            if (existingEvent is not null)
            {
                ValidateRetentionAuditMatchesMetadata(existingEvent, metadata);
                if (existingEvent.Outcome != HerdrEvidenceRetentionOutcome.Purged)
                {
                    throw new HerdrStateStoreException(
                        $"Pending retention bytes '{identity}' conflict with an AlreadyMissing audit event.");
                }

                DeleteRetentionPendingFile(pendingPath, identity);
                results.Add(CreateRetentionResult(identity, asOfUtc, existingEvent));
                continue;
            }

            if (metadata.RetainUntilUtc > asOfUtc)
            {
                throw new HerdrStateStoreException(
                    $"Pending retention bytes '{identity}' are not due at the requested cutoff.");
            }

            if (IsProtectedByOpenReview(identity, transaction))
            {
                RestorePendingRetentionFile(metadata, pendingPath);
                continue;
            }

            var recoveredEvent = CreateRetentionAuditEvent(
                metadata,
                HerdrEvidenceRetentionOutcome.Purged);
            InsertRetentionAuditEventInTransaction(recoveredEvent, transaction);
            DeleteRetentionPendingFile(pendingPath, identity);
            results.Add(CreateRetentionResult(identity, asOfUtc, recoveredEvent));
        }
    }

    private string MoveManagedEvidenceToRetentionPending(EvidenceMetadata metadata)
    {
        var identity = metadata.EvidenceIdentitySha256;
        var managedPath = ResolveManagedPath(metadata.ManagedRelativePath!);
        if (!IsConfirmedRegularFile(managedPath, $"Managed evidence bytes '{identity}'"))
        {
            throw new HerdrStateStoreException(
                $"Managed evidence bytes '{identity}' disappeared before retention staging.");
        }

        ValidateManagedFile(managedPath, metadata);
        var pendingDirectory = GetRetentionPendingDirectory();
        EnsureManagedPathHasNoReparsePoints(pendingDirectory);
        Directory.CreateDirectory(pendingDirectory);
        EnsureManagedPathHasNoReparsePoints(pendingDirectory);
        var pendingPath = GetRetentionPendingPath(identity);
        if (ReadPathAttributes(
                pendingPath,
                $"Pending retention bytes '{identity}'") is not null)
        {
            throw new HerdrStateStoreException(
                $"Pending retention bytes '{identity}' already exist.");
        }

        try
        {
            File.Move(managedPath, pendingPath);
        }
        catch (UnauthorizedAccessException exception)
        {
            throw new HerdrStateStoreException(
                $"Managed evidence bytes '{identity}' could not enter recoverable retention staging.",
                exception);
        }
        catch (IOException exception)
        {
            throw new HerdrStateStoreException(
                $"Managed evidence bytes '{identity}' could not enter recoverable retention staging.",
                exception);
        }

        if (ReadPathAttributes(
                managedPath,
                $"Managed evidence bytes '{identity}'") is not null ||
            !IsConfirmedRegularFile(
                pendingPath,
                $"Pending retention bytes '{identity}'"))
        {
            throw new HerdrStateStoreException(
                $"Managed evidence bytes '{identity}' did not enter retention staging atomically.");
        }

        ValidateManagedFile(pendingPath, metadata);
        return pendingPath;
    }

    private void RestorePendingRetentionFile(
        EvidenceMetadata metadata,
        string pendingPath)
    {
        var identity = metadata.EvidenceIdentitySha256;
        var managedPath = ResolveManagedPath(metadata.ManagedRelativePath!);
        if (ReadPathAttributes(
                managedPath,
                $"Managed evidence bytes '{identity}'") is not null)
        {
            throw new HerdrStateStoreException(
                $"Managed evidence '{identity}' cannot restore pending bytes over an existing object.");
        }

        ValidateManagedFile(pendingPath, metadata);
        try
        {
            File.Move(pendingPath, managedPath);
        }
        catch (UnauthorizedAccessException exception)
        {
            throw new HerdrStateStoreException(
                $"Pending retention bytes '{identity}' could not be restored for an open review.",
                exception);
        }
        catch (IOException exception)
        {
            throw new HerdrStateStoreException(
                $"Pending retention bytes '{identity}' could not be restored for an open review.",
                exception);
        }

        if (!IsConfirmedRegularFile(managedPath, $"Managed evidence bytes '{identity}'") ||
            ReadPathAttributes(
                pendingPath,
                $"Pending retention bytes '{identity}'") is not null)
        {
            throw new HerdrStateStoreException(
                $"Pending retention bytes '{identity}' were not restored atomically.");
        }

        ValidateManagedFile(managedPath, metadata);
    }

    private void DeleteRetentionPendingFile(string pendingPath, string identity)
    {
        if (!IsConfirmedRegularFile(
                pendingPath,
                $"Pending retention bytes '{identity}'"))
        {
            return;
        }

        try
        {
            File.Delete(pendingPath);
        }
        catch (UnauthorizedAccessException exception)
        {
            throw new HerdrStateStoreException(
                $"Committed pending retention bytes '{identity}' could not be deleted.",
                exception);
        }
        catch (IOException exception)
        {
            throw new HerdrStateStoreException(
                $"Committed pending retention bytes '{identity}' could not be deleted.",
                exception);
        }

        if (ReadPathAttributes(
                pendingPath,
                $"Pending retention bytes '{identity}'") is not null)
        {
            throw new HerdrStateStoreException(
                $"Committed pending retention bytes '{identity}' still exist after deletion.");
        }
    }

    private string GetRetentionPendingDirectory() =>
        Path.Combine(ManagedEvidenceRootPath, RetentionPendingDirectoryName);

    private string GetRetentionPendingPath(string evidenceIdentitySha256)
    {
        var identity = EvidenceMetadataContract.NormalizeEvidenceIdentity(
            evidenceIdentitySha256);
        var path = Path.Combine(
            GetRetentionPendingDirectory(),
            identity + RetentionPendingFileSuffix);
        EnsureManagedPathHasNoReparsePoints(path);
        return Path.GetFullPath(path);
    }

    private static HerdrEvidenceRetentionResult CreateRetentionResult(
        string identity,
        DateTimeOffset evaluatedUtc,
        HerdrEvidenceRetentionAuditEvent auditEvent) =>
        new(
            identity,
            auditEvent.Outcome,
            evaluatedUtc,
            auditEvent.RetentionEventId,
            auditEvent.RetentionAuditSha256);

    private IReadOnlyList<string> ReadDueEvidenceIdentities(
        DateTimeOffset asOfUtc,
        SqliteTransaction transaction)
    {
        using var command = _connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = """
            SELECT evidence_identity_sha256
            FROM evidence_items AS evidence
            WHERE evidence.storage_kind = 2
              AND evidence.availability = 1
              AND evidence.retain_until_utc <= $asOfUtc
              AND NOT EXISTS (
                  SELECT 1
                  FROM evidence_retention_events AS retention
                  WHERE retention.evidence_identity_sha256 = evidence.evidence_identity_sha256)
            ORDER BY evidence.retain_until_utc, evidence.evidence_identity_sha256;
            """;
        command.Parameters.AddWithValue("$asOfUtc", FormatUtc(asOfUtc));
        var result = new List<string>();
        using var reader = command.ExecuteReader();
        while (reader.Read())
        {
            result.Add(EvidenceMetadataContract.NormalizeEvidenceIdentity(reader.GetString(0)));
        }

        return result;
    }

    private bool IsProtectedByOpenReview(
        string evidenceIdentitySha256,
        SqliteTransaction transaction)
    {
        using var command = _connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = """
            SELECT (EXISTS (
                SELECT 1
                FROM review_audit_events AS latest
                WHERE latest.review_state = 1
                  AND latest.review_case_id IN (
                      SELECT DISTINCT linked_event.review_case_id
                      FROM review_audit_evidence AS link
                      INNER JOIN review_audit_events AS linked_event
                          ON linked_event.audit_event_id = link.audit_event_id
                      WHERE link.evidence_identity_sha256 = $identity)
                  AND latest.sequence = (
                      SELECT MAX(candidate.sequence)
                      FROM review_audit_events AS candidate
                      WHERE candidate.review_case_id = latest.review_case_id)
            )) OR (EXISTS (
                SELECT 1
                FROM (
                    SELECT incident_id
                    FROM compliance_review_incident_evidence
                    WHERE evidence_identity_sha256 = $identity
                    UNION
                    SELECT events.incident_id
                    FROM compliance_review_event_evidence AS link
                    INNER JOIN compliance_review_events AS events
                        ON events.audit_event_id = link.audit_event_id
                    WHERE link.evidence_identity_sha256 = $identity
                ) AS linked
                LEFT JOIN compliance_review_incidents AS incident
                    ON incident.incident_id = linked.incident_id
                WHERE incident.state IS NULL OR incident.state NOT IN (4, 5)
            ));
            """;
        command.Parameters.AddWithValue("$identity", evidenceIdentitySha256);
        return Convert.ToInt64(command.ExecuteScalar(), System.Globalization.CultureInfo.InvariantCulture) == 1;
    }

    private bool HasRetentionEvent(
        string evidenceIdentitySha256,
        SqliteTransaction? transaction = null)
    {
        using var command = _connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = """
            SELECT COUNT(*)
            FROM evidence_retention_events
            WHERE evidence_identity_sha256 = $identity;
            """;
        command.Parameters.AddWithValue("$identity", evidenceIdentitySha256);
        var count = Convert.ToInt64(command.ExecuteScalar(), System.Globalization.CultureInfo.InvariantCulture);
        if (count is < 0 or > 1)
        {
            throw new HerdrStateStoreException(
                $"Evidence '{evidenceIdentitySha256}' has an invalid retention-event cardinality.");
        }

        return count == 1;
    }

    private HerdrEvidenceRetentionAuditEvent? ReadRetentionAuditEvent(
        string evidenceIdentitySha256,
        SqliteTransaction? transaction = null)
    {
        using var command = _connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = """
            SELECT retention_event_id, evidence_identity_sha256, occurred_utc,
                   outcome, managed_relative_path, expected_content_length,
                   expected_content_sha256, retention_audit_sha256
            FROM evidence_retention_events
            WHERE evidence_identity_sha256 = $identity;
            """;
        command.Parameters.AddWithValue("$identity", evidenceIdentitySha256);
        using var reader = command.ExecuteReader();
        if (!reader.Read())
        {
            return null;
        }

        var auditEvent = new HerdrEvidenceRetentionAuditEvent(
            ParseGuid(reader.GetString(0), "retention_event_id"),
            EvidenceMetadataContract.NormalizeEvidenceIdentity(reader.GetString(1)),
            ParseUtc(reader.GetString(2)),
            (HerdrEvidenceRetentionOutcome)reader.GetInt32(3),
            reader.GetString(4),
            reader.GetInt64(5),
            reader.GetString(6),
            reader.GetString(7));
        if (reader.Read())
        {
            throw new HerdrStateStoreException(
                $"Evidence '{evidenceIdentitySha256}' has duplicate retention events.");
        }

        ValidateRetentionAuditEvent(auditEvent);
        return auditEvent;
    }

    private static void ValidateRetentionAuditMatchesMetadata(
        HerdrEvidenceRetentionAuditEvent auditEvent,
        EvidenceMetadata metadata)
    {
        if (!string.Equals(
                auditEvent.EvidenceIdentitySha256,
                metadata.EvidenceIdentitySha256,
                StringComparison.Ordinal) ||
            !string.Equals(
                auditEvent.ManagedRelativePath,
                metadata.ManagedRelativePath,
                StringComparison.Ordinal) ||
            auditEvent.ExpectedContentLength != metadata.ContentLength ||
            !string.Equals(
                auditEvent.ExpectedContentSha256,
                metadata.ContentSha256,
                StringComparison.Ordinal))
        {
            throw new HerdrStateStoreException(
                $"Retention event for '{metadata.EvidenceIdentitySha256}' does not match immutable evidence metadata.");
        }
    }

    private HerdrEvidenceRetentionAuditEvent CreateRetentionAuditEvent(
        EvidenceMetadata metadata,
        HerdrEvidenceRetentionOutcome outcome)
    {
        if (outcome is not (HerdrEvidenceRetentionOutcome.Purged or
            HerdrEvidenceRetentionOutcome.AlreadyMissing))
        {
            throw new HerdrStateStoreException(
                "Only terminal managed-byte retention outcomes are persisted.");
        }

        var eventId = Guid.NewGuid();
        var occurredUtc = _timeProvider.GetUtcNow();
        var auditSha256 = ComputeRetentionAuditSha256(
            eventId,
            metadata.EvidenceIdentitySha256,
            occurredUtc,
            outcome,
            metadata.ManagedRelativePath!,
            metadata.ContentLength!.Value,
            metadata.ContentSha256!);
        return new HerdrEvidenceRetentionAuditEvent(
            eventId,
            metadata.EvidenceIdentitySha256,
            occurredUtc,
            outcome,
            metadata.ManagedRelativePath!,
            metadata.ContentLength.Value,
            metadata.ContentSha256!,
            auditSha256);
    }

    private void InsertRetentionAuditEvent(HerdrEvidenceRetentionAuditEvent auditEvent) =>
        InsertRetentionAuditEventCore(auditEvent, transaction: null);

    private void InsertRetentionAuditEventInTransaction(
        HerdrEvidenceRetentionAuditEvent auditEvent,
        SqliteTransaction transaction) =>
        InsertRetentionAuditEventCore(auditEvent, transaction);

    private void InsertRetentionAuditEventCore(
        HerdrEvidenceRetentionAuditEvent auditEvent,
        SqliteTransaction? transaction)
    {
        ValidateRetentionAuditEvent(auditEvent);
        var ownsTransaction = transaction is null;
        transaction ??= _connection.BeginTransaction(deferred: false);
        using var command = _connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = """
            INSERT INTO evidence_retention_events(
                retention_event_id, evidence_identity_sha256, occurred_utc,
                outcome, managed_relative_path, expected_content_length,
                expected_content_sha256, retention_audit_sha256)
            VALUES (
                $eventId, $identity, $occurredUtc, $outcome, $relativePath,
                $contentLength, $contentSha256, $auditSha256);
            """;
        command.Parameters.AddWithValue("$eventId", auditEvent.RetentionEventId.ToString("D"));
        command.Parameters.AddWithValue("$identity", auditEvent.EvidenceIdentitySha256);
        command.Parameters.AddWithValue("$occurredUtc", FormatUtc(auditEvent.OccurredUtc));
        command.Parameters.AddWithValue("$outcome", (int)auditEvent.Outcome);
        command.Parameters.AddWithValue("$relativePath", auditEvent.ManagedRelativePath);
        command.Parameters.AddWithValue("$contentLength", auditEvent.ExpectedContentLength);
        command.Parameters.AddWithValue("$contentSha256", auditEvent.ExpectedContentSha256);
        command.Parameters.AddWithValue("$auditSha256", auditEvent.RetentionAuditSha256);
        command.ExecuteNonQuery();
        if (ownsTransaction)
        {
            transaction.Commit();
            transaction.Dispose();
        }
    }

    private static void ValidateRetentionAuditEvent(
        HerdrEvidenceRetentionAuditEvent auditEvent)
    {
        if (auditEvent.RetentionEventId == Guid.Empty ||
            auditEvent.OccurredUtc.Offset != TimeSpan.Zero ||
            auditEvent.Outcome is not (HerdrEvidenceRetentionOutcome.Purged or
                HerdrEvidenceRetentionOutcome.AlreadyMissing) ||
            auditEvent.ExpectedContentLength < 0)
        {
            throw new HerdrStateStoreException(
                "Persisted evidence retention audit contains invalid scalar values.");
        }

        var identity = EvidenceMetadataContract.NormalizeEvidenceIdentity(
            auditEvent.EvidenceIdentitySha256);
        var contentSha = EvidenceMetadataContract.NormalizeEvidenceIdentity(
            auditEvent.ExpectedContentSha256);
        var expected = ComputeRetentionAuditSha256(
            auditEvent.RetentionEventId,
            identity,
            auditEvent.OccurredUtc,
            auditEvent.Outcome,
            auditEvent.ManagedRelativePath,
            auditEvent.ExpectedContentLength,
            contentSha);
        if (!string.Equals(
                EvidenceMetadataContract.NormalizeEvidenceIdentity(
                    auditEvent.RetentionAuditSha256),
                expected,
                StringComparison.Ordinal))
        {
            throw new HerdrStateStoreException(
                $"Persisted evidence retention audit '{auditEvent.RetentionEventId:D}' failed its SHA-256 check.");
        }
    }

    private static string ComputeRetentionAuditSha256(
        Guid eventId,
        string evidenceIdentitySha256,
        DateTimeOffset occurredUtc,
        HerdrEvidenceRetentionOutcome outcome,
        string managedRelativePath,
        long expectedContentLength,
        string expectedContentSha256)
    {
        var canonical = JsonSerializer.Serialize(
            new RetentionAuditCanonical(
                ContractVersion: 1,
                EventId: eventId.ToString("D"),
                EvidenceIdentitySha256: evidenceIdentitySha256,
                OccurredUtc: FormatUtc(occurredUtc),
                Outcome: (int)outcome,
                ManagedRelativePath: managedRelativePath,
                ExpectedContentLength: expectedContentLength,
                ExpectedContentSha256: expectedContentSha256),
            EvidenceSerializerOptions);
        return ComputeUtf8Sha256(canonical);
    }

    private static T DeserializeEvidence<T>(string json, string description)
    {
        try
        {
            return JsonSerializer.Deserialize<T>(json, EvidenceSerializerOptions)
                ?? throw new JsonException($"The {description} JSON contained null.");
        }
        catch (JsonException exception)
        {
            throw new HerdrStateStoreException(
                $"The persisted {description} is not valid strict JSON.",
                exception);
        }
    }

    private static string NormalizeEvidenceIdentifier(string value, string name)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            throw new ArgumentException(
                $"{name} cannot be blank.",
                name);
        }

        var normalized = value.Normalize(NormalizationForm.FormC);
        if (!string.Equals(normalized, normalized.Trim(), StringComparison.Ordinal) ||
            normalized.Length > EvidenceMetadataContract.MaximumIdentifierLength ||
            normalized.Any(char.IsControl))
        {
            throw new ArgumentException(
                $"{name} must be unpadded, bounded, and contain no control characters.",
                name);
        }

        return normalized;
    }

    private static bool NullableInt64Equals(
        long? expected,
        SqliteDataReader reader,
        int ordinal) => expected is null
        ? reader.IsDBNull(ordinal)
        : !reader.IsDBNull(ordinal) && expected.Value == reader.GetInt64(ordinal);

    private sealed record FileDigest(long Length, string Sha256);

    private sealed record StoredReviewAuditRow(
        Guid EventId,
        int ContractVersion,
        string ReviewCaseId,
        long Sequence,
        string ReviewerActorId,
        string ReviewerRole,
        ReviewAuditActionKind ActionKind,
        ReviewAuditState ReviewState,
        string Reason,
        DateTimeOffset OccurredUtc,
        string EvidenceSetSha256,
        string? PreviousAuditSha256,
        string AuditSha256,
        string AuditJson);

    private sealed record RetentionAuditCanonical(
        int ContractVersion,
        string EventId,
        string EvidenceIdentitySha256,
        string OccurredUtc,
        int Outcome,
        string ManagedRelativePath,
        long ExpectedContentLength,
        string ExpectedContentSha256);
}
