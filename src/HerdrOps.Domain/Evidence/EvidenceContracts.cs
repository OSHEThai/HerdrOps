using System.Buffers.Binary;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;

namespace HerdrOps.Domain.Evidence;

public enum EvidenceArtifactAvailability
{
    Present = 1,
    Missing = 2,
}

public enum EvidenceArtifactStorageKind
{
    ExternalReference = 1,
    ManagedCopy = 2,
}

public enum ReviewAuditActionKind
{
    Opened = 1,
    EvidenceAttached = 2,
    NoteAdded = 3,
    Closed = 4,
}

public enum ReviewAuditState
{
    Open = 1,
    Closed = 2,
}

public sealed record EvidenceCaptureRequest(
    int ContractVersion,
    string TaskId,
    string ActorId,
    string SourceEventId,
    string Source,
    string SourceReference,
    DateTimeOffset ObservedUtc,
    DateTimeOffset IngestedUtc,
    DateTimeOffset? RetainUntilUtc,
    bool CreateManagedCopy);

public sealed record EvidenceMetadata(
    int ContractVersion,
    string EvidenceIdentitySha256,
    string TaskId,
    string ActorId,
    string SourceEventId,
    string Source,
    string SourceReference,
    DateTimeOffset ObservedUtc,
    DateTimeOffset IngestedUtc,
    DateTimeOffset RetainUntilUtc,
    EvidenceArtifactAvailability Availability,
    EvidenceArtifactStorageKind StorageKind,
    long? ContentLength,
    string? ContentSha256,
    string? ManagedRelativePath,
    string MetadataSha256);

public sealed record ReviewAuditAppendRequest(
    int ContractVersion,
    Guid AuditEventId,
    string ReviewCaseId,
    string ReviewerActorId,
    string ReviewerRole,
    ReviewAuditActionKind ActionKind,
    ReviewAuditState ReviewState,
    string Reason,
    DateTimeOffset OccurredUtc,
    IReadOnlyList<string> EvidenceIdentitySha256s);

public sealed record ReviewAuditEvent(
    int ContractVersion,
    Guid AuditEventId,
    string ReviewCaseId,
    long Sequence,
    string ReviewerActorId,
    string ReviewerRole,
    ReviewAuditActionKind ActionKind,
    ReviewAuditState ReviewState,
    string Reason,
    DateTimeOffset OccurredUtc,
    IReadOnlyList<string> EvidenceIdentitySha256s,
    string EvidenceSetSha256,
    string? PreviousAuditSha256,
    string AuditSha256);

public static class EvidenceMetadataContract
{
    public const int ContractVersion = 1;
    public const int MaximumIdentifierLength = 128;
    public const int MaximumSourceLength = 64;
    public const int MaximumReferenceLength = 2048;
    public const int MaximumManagedPathLength = 512;

    public static EvidenceMetadata Create(
        EvidenceCaptureRequest request,
        EvidenceArtifactAvailability availability,
        long? contentLength,
        string? contentSha256,
        string? managedRelativePath)
    {
        var normalizedRequest = NormalizeRequest(request);
        if (!Enum.IsDefined(availability))
        {
            throw new EvidenceContractException(
                "Evidence availability contains an unsupported value.");
        }

        var storageKind = availability == EvidenceArtifactAvailability.Present &&
            normalizedRequest.CreateManagedCopy
                ? EvidenceArtifactStorageKind.ManagedCopy
                : EvidenceArtifactStorageKind.ExternalReference;
        var candidate = new EvidenceMetadata(
            ContractVersion,
            string.Empty,
            normalizedRequest.TaskId,
            normalizedRequest.ActorId,
            normalizedRequest.SourceEventId,
            normalizedRequest.Source,
            normalizedRequest.SourceReference,
            normalizedRequest.ObservedUtc,
            normalizedRequest.IngestedUtc,
            normalizedRequest.RetainUntilUtc!.Value,
            availability,
            storageKind,
            contentLength,
            contentSha256,
            managedRelativePath,
            string.Empty);
        var normalized = NormalizeCore(candidate, requireHashes: false);
        var identity = ComputeIdentitySha256(normalized);
        normalized = normalized with { EvidenceIdentitySha256 = identity };
        return normalized with { MetadataSha256 = ComputeMetadataSha256(normalized) };
    }

    public static EvidenceMetadata NormalizeAndValidate(EvidenceMetadata metadata)
    {
        ArgumentNullException.ThrowIfNull(metadata);
        var normalized = NormalizeCore(metadata, requireHashes: true);
        var expectedIdentity = ComputeIdentitySha256(normalized);
        if (!string.Equals(
                normalized.EvidenceIdentitySha256,
                expectedIdentity,
                StringComparison.Ordinal))
        {
            throw new EvidenceContractException(
                "The evidence identity SHA-256 does not match its canonical linkage and content.");
        }

        var expectedMetadata = ComputeMetadataSha256(normalized);
        if (!string.Equals(
                normalized.MetadataSha256,
                expectedMetadata,
                StringComparison.Ordinal))
        {
            throw new EvidenceContractException(
                "The evidence metadata SHA-256 does not match its canonical content.");
        }

        return normalized;
    }

    public static string NormalizeEvidenceIdentity(string value) =>
        EvidenceContractNormalization.NormalizeSha256(
            value,
            "evidenceIdentitySha256");

    private static EvidenceCaptureRequest NormalizeRequest(EvidenceCaptureRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (request.ContractVersion != ContractVersion)
        {
            throw new EvidenceContractException(
                $"Evidence capture contract v{request.ContractVersion} is unsupported; expected v{ContractVersion}.");
        }

        var observedUtc = EvidenceContractNormalization.EnsureUtc(
            request.ObservedUtc,
            nameof(request.ObservedUtc));
        var ingestedUtc = EvidenceContractNormalization.EnsureUtc(
            request.IngestedUtc,
            nameof(request.IngestedUtc));
        var retainUntilUtc = EvidenceRetentionPolicy.ResolveRetainUntil(
            observedUtc,
            request.RetainUntilUtc);
        if (ingestedUtc < observedUtc)
        {
            throw new EvidenceContractException(
                "Evidence ingest time cannot precede its observed time.");
        }

        if (retainUntilUtc < observedUtc)
        {
            throw new EvidenceContractException(
                "Evidence retention time cannot precede its observed time.");
        }

        return request with
        {
            TaskId = EvidenceContractNormalization.NormalizeIdentifier(
                request.TaskId,
                nameof(request.TaskId),
                MaximumIdentifierLength),
            ActorId = EvidenceContractNormalization.NormalizeIdentifier(
                request.ActorId,
                nameof(request.ActorId),
                MaximumIdentifierLength),
            SourceEventId = EvidenceContractNormalization.NormalizeIdentifier(
                request.SourceEventId,
                nameof(request.SourceEventId),
                MaximumIdentifierLength),
            Source = EvidenceContractNormalization.NormalizeIdentifier(
                request.Source,
                nameof(request.Source),
                MaximumSourceLength),
            SourceReference = EvidenceContractNormalization.NormalizeText(
                request.SourceReference,
                nameof(request.SourceReference),
                MaximumReferenceLength),
            ObservedUtc = observedUtc,
            IngestedUtc = ingestedUtc,
            RetainUntilUtc = retainUntilUtc,
        };
    }

    private static EvidenceMetadata NormalizeCore(
        EvidenceMetadata metadata,
        bool requireHashes)
    {
        if (metadata.ContractVersion != ContractVersion ||
            !Enum.IsDefined(metadata.Availability) ||
            !Enum.IsDefined(metadata.StorageKind))
        {
            throw new EvidenceContractException(
                "Evidence metadata has an unsupported contract, availability, or storage value.");
        }

        var request = NormalizeRequest(new EvidenceCaptureRequest(
            metadata.ContractVersion,
            metadata.TaskId,
            metadata.ActorId,
            metadata.SourceEventId,
            metadata.Source,
            metadata.SourceReference,
            metadata.ObservedUtc,
            metadata.IngestedUtc,
            metadata.RetainUntilUtc,
            metadata.StorageKind == EvidenceArtifactStorageKind.ManagedCopy));
        var contentSha256 = metadata.ContentSha256 is null
            ? null
            : EvidenceContractNormalization.NormalizeSha256(
                metadata.ContentSha256,
                nameof(metadata.ContentSha256));
        var managedPath = metadata.ManagedRelativePath is null
            ? null
            : EvidenceContractNormalization.NormalizeManagedRelativePath(
                metadata.ManagedRelativePath,
                MaximumManagedPathLength);
        if (metadata.Availability == EvidenceArtifactAvailability.Present)
        {
            if (metadata.ContentLength is null or < 0 || contentSha256 is null)
            {
                throw new EvidenceContractException(
                    "Present evidence requires non-negative content length and exact SHA-256.");
            }

            if (metadata.StorageKind == EvidenceArtifactStorageKind.ManagedCopy && managedPath is null)
            {
                throw new EvidenceContractException(
                    "Managed evidence requires a relative object path.");
            }

            if (metadata.StorageKind == EvidenceArtifactStorageKind.ExternalReference && managedPath is not null)
            {
                throw new EvidenceContractException(
                    "External evidence cannot claim a managed object path.");
            }
        }
        else if (metadata.ContentLength is not null ||
                 contentSha256 is not null ||
                 managedPath is not null ||
                 metadata.StorageKind != EvidenceArtifactStorageKind.ExternalReference)
        {
            throw new EvidenceContractException(
                "Missing evidence must keep content and managed-object fields explicitly null.");
        }

        return metadata with
        {
            TaskId = request.TaskId,
            ActorId = request.ActorId,
            SourceEventId = request.SourceEventId,
            Source = request.Source,
            SourceReference = request.SourceReference,
            ObservedUtc = request.ObservedUtc,
            IngestedUtc = request.IngestedUtc,
            RetainUntilUtc = request.RetainUntilUtc!.Value,
            ContentSha256 = contentSha256,
            ManagedRelativePath = managedPath,
            EvidenceIdentitySha256 = requireHashes
                ? EvidenceContractNormalization.NormalizeSha256(
                    metadata.EvidenceIdentitySha256,
                    nameof(metadata.EvidenceIdentitySha256))
                : string.Empty,
            MetadataSha256 = requireHashes
                ? EvidenceContractNormalization.NormalizeSha256(
                    metadata.MetadataSha256,
                    nameof(metadata.MetadataSha256))
                : string.Empty,
        };
    }

    private static string ComputeIdentitySha256(EvidenceMetadata metadata)
    {
        using var writer = new EvidenceCanonicalHashWriter(
            "HerdrOps.EvidenceIdentity.v1");
        writer.Write(metadata.ContractVersion);
        writer.Write(metadata.TaskId);
        writer.Write(metadata.ActorId);
        writer.Write(metadata.SourceEventId);
        writer.Write(metadata.Source);
        writer.Write(metadata.SourceReference);
        writer.Write((int)metadata.Availability);
        writer.Write(metadata.ContentLength);
        writer.Write(metadata.ContentSha256);
        return writer.Finish();
    }

    private static string ComputeMetadataSha256(EvidenceMetadata metadata)
    {
        using var writer = new EvidenceCanonicalHashWriter(
            "HerdrOps.EvidenceMetadata.v1");
        writer.Write(metadata.EvidenceIdentitySha256);
        writer.Write(metadata.ObservedUtc);
        writer.Write(metadata.IngestedUtc);
        writer.Write(metadata.RetainUntilUtc);
        writer.Write((int)metadata.StorageKind);
        writer.Write(metadata.ManagedRelativePath);
        return writer.Finish();
    }
}

public static class ReviewAuditContract
{
    public const int ContractVersion = 1;
    public const int MaximumEvidenceLinks = 256;
    public const int MaximumReasonLength = 2048;

    public static ReviewAuditEvent Create(
        ReviewAuditAppendRequest request,
        long sequence,
        string? previousAuditSha256)
    {
        var normalizedRequest = NormalizeRequest(request);
        if (sequence <= 0)
        {
            throw new EvidenceContractException(
                "A review audit sequence must be positive.");
        }

        var previous = previousAuditSha256 is null
            ? null
            : EvidenceContractNormalization.NormalizeSha256(
                previousAuditSha256,
                nameof(previousAuditSha256));
        if ((sequence == 1) != (previous is null))
        {
            throw new EvidenceContractException(
                "Only the first review audit event can omit the previous audit SHA-256.");
        }

        var evidenceSetSha256 = ComputeEvidenceSetSha256(
            normalizedRequest.EvidenceIdentitySha256s);
        var candidate = new ReviewAuditEvent(
            ContractVersion,
            normalizedRequest.AuditEventId,
            normalizedRequest.ReviewCaseId,
            sequence,
            normalizedRequest.ReviewerActorId,
            normalizedRequest.ReviewerRole,
            normalizedRequest.ActionKind,
            normalizedRequest.ReviewState,
            normalizedRequest.Reason,
            normalizedRequest.OccurredUtc,
            normalizedRequest.EvidenceIdentitySha256s,
            evidenceSetSha256,
            previous,
            string.Empty);
        return candidate with { AuditSha256 = ComputeAuditSha256(candidate) };
    }

    public static ReviewAuditEvent NormalizeAndValidate(ReviewAuditEvent auditEvent)
    {
        ArgumentNullException.ThrowIfNull(auditEvent);
        var normalized = Create(
            new ReviewAuditAppendRequest(
                auditEvent.ContractVersion,
                auditEvent.AuditEventId,
                auditEvent.ReviewCaseId,
                auditEvent.ReviewerActorId,
                auditEvent.ReviewerRole,
                auditEvent.ActionKind,
                auditEvent.ReviewState,
                auditEvent.Reason,
                auditEvent.OccurredUtc,
                auditEvent.EvidenceIdentitySha256s),
            auditEvent.Sequence,
            auditEvent.PreviousAuditSha256);
        var evidenceSet = EvidenceContractNormalization.NormalizeSha256(
            auditEvent.EvidenceSetSha256,
            nameof(auditEvent.EvidenceSetSha256));
        var auditSha = EvidenceContractNormalization.NormalizeSha256(
            auditEvent.AuditSha256,
            nameof(auditEvent.AuditSha256));
        if (!string.Equals(evidenceSet, normalized.EvidenceSetSha256, StringComparison.Ordinal) ||
            !string.Equals(auditSha, normalized.AuditSha256, StringComparison.Ordinal))
        {
            throw new EvidenceContractException(
                "The review audit hashes do not match the canonical event and evidence set.");
        }

        return normalized;
    }

    private static ReviewAuditAppendRequest NormalizeRequest(
        ReviewAuditAppendRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (request.ContractVersion != ContractVersion ||
            request.AuditEventId == Guid.Empty ||
            !Enum.IsDefined(request.ActionKind) ||
            !Enum.IsDefined(request.ReviewState))
        {
            throw new EvidenceContractException(
                "Review audit request has an unsupported contract, empty event ID, action, or state.");
        }

        if (request.EvidenceIdentitySha256s is null ||
            request.EvidenceIdentitySha256s.Count > MaximumEvidenceLinks)
        {
            throw new EvidenceContractException(
                $"A review audit event can link at most {MaximumEvidenceLinks} evidence identities.");
        }

        var evidenceIds = request.EvidenceIdentitySha256s
            .Select(EvidenceMetadataContract.NormalizeEvidenceIdentity)
            .Distinct(StringComparer.Ordinal)
            .OrderBy(item => item, StringComparer.Ordinal)
            .ToArray();
        if (evidenceIds.Length != request.EvidenceIdentitySha256s.Count)
        {
            throw new EvidenceContractException(
                "A review audit event cannot contain duplicate evidence identities.");
        }

        return request with
        {
            ReviewCaseId = EvidenceContractNormalization.NormalizeIdentifier(
                request.ReviewCaseId,
                nameof(request.ReviewCaseId),
                EvidenceMetadataContract.MaximumIdentifierLength),
            ReviewerActorId = EvidenceContractNormalization.NormalizeIdentifier(
                request.ReviewerActorId,
                nameof(request.ReviewerActorId),
                EvidenceMetadataContract.MaximumIdentifierLength),
            ReviewerRole = EvidenceContractNormalization.NormalizeText(
                request.ReviewerRole,
                nameof(request.ReviewerRole),
                EvidenceMetadataContract.MaximumIdentifierLength),
            Reason = EvidenceContractNormalization.NormalizeText(
                request.Reason,
                nameof(request.Reason),
                MaximumReasonLength),
            OccurredUtc = EvidenceContractNormalization.EnsureUtc(
                request.OccurredUtc,
                nameof(request.OccurredUtc)),
            EvidenceIdentitySha256s = Array.AsReadOnly(evidenceIds),
        };
    }

    private static string ComputeEvidenceSetSha256(IReadOnlyList<string> evidenceIds)
    {
        using var writer = new EvidenceCanonicalHashWriter(
            "HerdrOps.ReviewEvidenceSet.v1");
        writer.Write(evidenceIds.Count);
        foreach (var evidenceId in evidenceIds)
        {
            writer.Write(evidenceId);
        }

        return writer.Finish();
    }

    private static string ComputeAuditSha256(ReviewAuditEvent auditEvent)
    {
        using var writer = new EvidenceCanonicalHashWriter(
            "HerdrOps.ReviewAuditEvent.v1");
        writer.Write(auditEvent.ContractVersion);
        writer.Write(auditEvent.AuditEventId.ToString("D"));
        writer.Write(auditEvent.ReviewCaseId);
        writer.Write(auditEvent.Sequence);
        writer.Write(auditEvent.ReviewerActorId);
        writer.Write(auditEvent.ReviewerRole);
        writer.Write((int)auditEvent.ActionKind);
        writer.Write((int)auditEvent.ReviewState);
        writer.Write(auditEvent.Reason);
        writer.Write(auditEvent.OccurredUtc);
        writer.Write(auditEvent.EvidenceSetSha256);
        writer.Write(auditEvent.PreviousAuditSha256);
        return writer.Finish();
    }
}

internal static class EvidenceContractNormalization
{
    public static string NormalizeIdentifier(
        string value,
        string name,
        int maximumLength)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            throw new EvidenceContractException(
                $"Evidence field {name} cannot be blank.");
        }

        var normalized = value.Normalize(NormalizationForm.FormC);
        if (!string.Equals(normalized, normalized.Trim(), StringComparison.Ordinal) ||
            normalized.Length > maximumLength ||
            normalized.Any(char.IsControl))
        {
            throw new EvidenceContractException(
                $"Evidence field {name} must be unpadded, bounded, and contain no control characters.");
        }

        return normalized;
    }

    public static string NormalizeText(string value, string name, int maximumLength)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            throw new EvidenceContractException(
                $"Evidence field {name} cannot be blank.");
        }

        var normalized = value
            .Replace("\r\n", "\n", StringComparison.Ordinal)
            .Replace('\r', '\n')
            .Normalize(NormalizationForm.FormC);
        if (normalized.Length > maximumLength ||
            normalized.Any(character =>
                char.IsControl(character) && character is not ('\n' or '\t')))
        {
            throw new EvidenceContractException(
                $"Evidence field {name} is too long or contains unsupported control characters.");
        }

        return normalized;
    }

    public static string NormalizeSha256(string value, string name)
    {
        if (value is null || value.Length != 64 || !value.All(IsHexCharacter))
        {
            throw new EvidenceContractException(
                $"Evidence field {name} must contain exactly 64 hexadecimal characters.");
        }

        return value.ToUpperInvariant();
    }

    public static string NormalizeManagedRelativePath(string value, int maximumLength)
    {
        var normalized = NormalizeText(value, "managedRelativePath", maximumLength)
            .Replace('\\', '/');
        if (normalized.StartsWith("/", StringComparison.Ordinal) ||
            normalized.EndsWith("/", StringComparison.Ordinal) ||
            normalized.Contains(':', StringComparison.Ordinal) ||
            normalized.Any(character =>
                !(char.IsAsciiLetterOrDigit(character) ||
                  character is '-' or '_' or '.' or '/')) ||
            normalized.Split('/', StringSplitOptions.None).Any(segment =>
                string.IsNullOrWhiteSpace(segment) || segment is "." or ".."))
        {
            throw new EvidenceContractException(
                "Managed evidence path must be a safe relative path.");
        }

        return normalized;
    }

    public static DateTimeOffset EnsureUtc(DateTimeOffset value, string name)
    {
        if (value.Offset != TimeSpan.Zero)
        {
            throw new EvidenceContractException(
                $"Evidence field {name} must be UTC.");
        }

        return value;
    }

    private static bool IsHexCharacter(char value) =>
        value is >= '0' and <= '9' or >= 'A' and <= 'F' or >= 'a' and <= 'f';
}

internal sealed class EvidenceCanonicalHashWriter : IDisposable
{
    private readonly IncrementalHash _hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
    private bool _finished;

    public EvidenceCanonicalHashWriter(string domain)
    {
        Write(domain);
    }

    public void Write(string? value)
    {
        if (value is null)
        {
            WriteLength(-1);
            return;
        }

        var bytes = Encoding.UTF8.GetBytes(value);
        WriteLength(bytes.Length);
        _hash.AppendData(bytes);
    }

    public void Write(int value)
    {
        Span<byte> bytes = stackalloc byte[sizeof(int)];
        BinaryPrimitives.WriteInt32LittleEndian(bytes, value);
        _hash.AppendData(bytes);
    }

    public void Write(long value)
    {
        Span<byte> bytes = stackalloc byte[sizeof(long)];
        BinaryPrimitives.WriteInt64LittleEndian(bytes, value);
        _hash.AppendData(bytes);
    }

    public void Write(long? value)
    {
        Write(value.HasValue ? 1 : 0);
        if (value.HasValue)
        {
            Write(value.Value);
        }
    }

    public void Write(DateTimeOffset value) =>
        Write(value.ToString("O", CultureInfo.InvariantCulture));

    public string Finish()
    {
        ObjectDisposedException.ThrowIf(_finished, this);
        _finished = true;
        return Convert.ToHexString(_hash.GetHashAndReset());
    }

    public void Dispose()
    {
        _hash.Dispose();
        _finished = true;
    }

    private void WriteLength(int value)
    {
        Span<byte> bytes = stackalloc byte[sizeof(int)];
        BinaryPrimitives.WriteInt32LittleEndian(bytes, value);
        _hash.AppendData(bytes);
    }
}

public sealed class EvidenceContractException : ArgumentException
{
    public EvidenceContractException(string message)
        : base(message)
    {
    }
}
