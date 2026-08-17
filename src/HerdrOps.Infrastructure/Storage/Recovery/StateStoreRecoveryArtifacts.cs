using System.Globalization;
using System.Security.Cryptography;
using System.Text.Json;
using Microsoft.Data.Sqlite;

namespace HerdrOps.Infrastructure.Storage.Recovery;

internal static class StateStoreRecoveryArtifacts
{
    private const int MaximumArtifactAttempts = 64;
    private const int CopyBufferSize = 64 * 1024;
    private const string RecoveryDirectoryName = "recovery";
    private const string BackupDirectoryName = "backups";
    private const string QuarantineDirectoryName = "quarantine";
    private static readonly JsonSerializerOptions TraceJsonOptions = new()
    {
        WriteIndented = true,
    };

    public static StateStoreRecoveryBackupResult CreateBackup(
        SqliteConnection source,
        string databasePath,
        int fromVersion,
        int toVersion,
        TimeProvider timeProvider,
        StateStoreRecoveryOptions recoveryOptions)
    {
        ArgumentNullException.ThrowIfNull(source);
        ArgumentNullException.ThrowIfNull(timeProvider);
        ArgumentNullException.ThrowIfNull(recoveryOptions);

        var normalizedDatabasePath = StateStoreRecoveryPathPolicy.NormalizeDatabasePath(databasePath);
        var parent = Path.GetDirectoryName(normalizedDatabasePath)!;
        var backupDirectory = Path.Combine(parent, BackupDirectoryName);
        StateStoreRecoveryPathPolicy.EnsureDirectoryTree(backupDirectory);
        StateStoreRecoveryPathPolicy.EnsureContainedPath(parent, backupDirectory);

        var primaryIdentity = ComputeFileIdentity(normalizedDatabasePath);
        for (var attempt = 0; attempt < MaximumArtifactAttempts; attempt++)
        {
            var stamp = FormatStamp(timeProvider.GetUtcNow());
            var token = recoveryOptions.EffectiveGuidFactory().ToString("N");
            var baseName =
                $"{Path.GetFileName(normalizedDatabasePath)}.v{fromVersion}.pre-v{toVersion}.{stamp}.{token}.{attempt:D2}";
            var temporaryPath = Path.Combine(backupDirectory, $".{baseName}.tmp");
            var backupPath = Path.Combine(backupDirectory, $"{baseName}.bak");
            StateStoreRecoveryPathPolicy.EnsureContainedPath(parent, temporaryPath);
            StateStoreRecoveryPathPolicy.EnsureContainedPath(parent, backupPath);
            if (File.Exists(temporaryPath) ||
                Directory.Exists(temporaryPath) ||
                File.Exists(backupPath) ||
                Directory.Exists(backupPath))
            {
                continue;
            }

            var temporaryOwned = false;
            try
            {
                CreateEmptyFile(temporaryPath);
                temporaryOwned = true;
                recoveryOptions.EffectiveFaultInjector.OnPhase(
                    new StateStoreRecoveryPhaseContext(
                        StateStoreRecoveryPhase.AfterBackupTemporaryCreated,
                        fromVersion,
                        toVersion,
                        temporaryPath));
                using (var destination = OpenSqlite(temporaryPath, SqliteOpenMode.ReadWriteCreate))
                {
                    source.BackupDatabase(destination);
                    ValidateSqliteConnection(
                        destination,
                        temporaryPath,
                        expectedUserVersion: fromVersion);
                }

                FlushFile(temporaryPath);
                StateStoreRecoveryPathPolicy.ValidateExistingPrimary(temporaryPath);
                if (!TryMoveWithoutOverwrite(temporaryPath, backupPath))
                {
                    temporaryOwned = false;
                    var collisionFailure = new IOException(
                        "A backup artifact collision prevented atomic publication.");
                    if (!TryCleanupFile(
                            temporaryPath,
                            recoveryOptions,
                            collisionFailure,
                            "backup-collision-cleanup"))
                    {
                        throw collisionFailure;
                    }

                    continue;
                }
                temporaryOwned = false;

                var backupIdentity = ComputeFileIdentity(backupPath);
                var trace = CreateTrace(
                    operation: "MigrationBackup",
                    outcome: "BackupCreated",
                    databasePath: normalizedDatabasePath,
                    fromVersion,
                    toVersion,
                    primary: primaryIdentity,
                    backup: backupIdentity,
                    sidecars: null,
                    quarantineDirectory: null,
                    failure: null,
                    timeProvider);
                var tracePath = WriteTrace(
                    normalizedDatabasePath,
                    $"migration-backup-v{fromVersion}-v{toVersion}",
                    trace,
                    timeProvider,
                    recoveryOptions);
                return new StateStoreRecoveryBackupResult(backupPath, tracePath, backupIdentity);
            }
            catch (Exception primary)
            {
                if (temporaryOwned)
                {
                    CleanupFilePreservingPrimary(
                        temporaryPath,
                        recoveryOptions,
                        primary,
                        "backup-temporary-cleanup");
                }

                throw;
            }
        }

        throw new HerdrStateStoreException(
            $"Unable to allocate a non-colliding SQLite backup under '{backupDirectory}'.");
    }

    public static StateStoreRecoveryRestoreResult RestoreBackup(
        string databasePath,
        string backupPath,
        string expectedBackupSha256,
        StateStoreRecoveryFileIdentity? expectedDestinationIdentity,
        TimeProvider timeProvider,
        StateStoreRecoveryOptions recoveryOptions)
    {
        if (string.IsNullOrWhiteSpace(expectedBackupSha256))
        {
            throw new ArgumentException(
                "The expected backup SHA-256 identity is required.",
                nameof(expectedBackupSha256));
        }

        ArgumentNullException.ThrowIfNull(timeProvider);
        ArgumentNullException.ThrowIfNull(recoveryOptions);

        var normalizedDatabasePath = StateStoreRecoveryPathPolicy.NormalizeDatabasePath(databasePath);
        var normalizedBackupPath =
            StateStoreRecoveryPathPolicy.NormalizeDatabasePath(backupPath);
        var parent = Path.GetDirectoryName(normalizedDatabasePath)!;
        var backupDirectory = Path.Combine(parent, BackupDirectoryName);
        StateStoreRecoveryPathPolicy.EnsureContainedPath(
            backupDirectory,
            normalizedBackupPath);
        StateStoreRecoveryPathPolicy.ValidateExistingCopySource(normalizedBackupPath);
        var backupVersion = ValidateSqliteFile(normalizedBackupPath);
        var backupIdentity = ComputeFileIdentity(normalizedBackupPath);
        EnsureExpectedIdentity("backup source", expectedBackupSha256, backupIdentity);

        var destinationWasPresent = IdentifyExpectedDestination(
            normalizedDatabasePath,
            expectedDestinationIdentity,
            out var originalDestinationIdentity);

        string? temporaryPath = null;
        string? priorPath = null;
        var movedIntoPlace = false;
        var replacementAttempted = false;
        var restoreCompleted = false;
        try
        {
            for (var attempt = 0; attempt < MaximumArtifactAttempts; attempt++)
            {
                var stamp = FormatStamp(timeProvider.GetUtcNow());
                var token = recoveryOptions.EffectiveGuidFactory().ToString("N");
                var baseName =
                    $"{Path.GetFileName(normalizedDatabasePath)}.rollback.{stamp}.{token}.{attempt:D2}";
                var candidateTemporaryPath = Path.Combine(parent, $".{baseName}.tmp");
                var candidatePriorPath = Path.Combine(parent, $"{baseName}.prior.bak");
                StateStoreRecoveryPathPolicy.EnsureContainedPath(parent, candidateTemporaryPath);
                StateStoreRecoveryPathPolicy.EnsureContainedPath(parent, candidatePriorPath);
                if (File.Exists(candidateTemporaryPath) ||
                    Directory.Exists(candidateTemporaryPath) ||
                    File.Exists(candidatePriorPath) ||
                    Directory.Exists(candidatePriorPath))
                {
                    continue;
                }

                temporaryPath = candidateTemporaryPath;
                priorPath = candidatePriorPath;
                CopyExactly(normalizedBackupPath, temporaryPath);
                ValidateSqliteFile(temporaryPath, backupVersion);
                recoveryOptions.EffectiveFaultInjector.OnPhase(
                    new StateStoreRecoveryPhaseContext(
                        StateStoreRecoveryPhase.BeforeRollback,
                        backupVersion,
                        backupVersion,
                        temporaryPath));

                var stagedIdentity = ComputeFileIdentity(temporaryPath);
                EnsureExpectedIdentity("staged backup", expectedBackupSha256, stagedIdentity);
                backupIdentity = ComputeFileIdentity(normalizedBackupPath);
                EnsureExpectedIdentity("backup source", expectedBackupSha256, backupIdentity);
                var destinationStillPresent = IdentifyExpectedDestination(
                    normalizedDatabasePath,
                    expectedDestinationIdentity,
                    out _);
                if (destinationStillPresent != destinationWasPresent)
                {
                    throw new HerdrStateStoreException(
                        "The destination presence changed before atomic restore.");
                }

                if (destinationWasPresent)
                {
                    replacementAttempted = true;
                    File.Replace(
                        temporaryPath,
                        normalizedDatabasePath,
                        priorPath,
                        ignoreMetadataErrors: true);
                    movedIntoPlace = true;
                }
                else
                {
                    replacementAttempted = true;
                    File.Move(temporaryPath, normalizedDatabasePath, overwrite: false);
                    movedIntoPlace = true;
                    priorPath = null;
                }

                recoveryOptions.EffectiveFaultInjector.OnPhase(
                    new StateStoreRecoveryPhaseContext(
                        StateStoreRecoveryPhase.AfterRestoreReplacement,
                        backupVersion,
                        backupVersion,
                        normalizedDatabasePath));

                var restoredVersion = ValidateSqliteFile(
                    normalizedDatabasePath,
                    expectedUserVersion: backupVersion);
                var restoredIdentity = ComputeFileIdentity(normalizedDatabasePath);
                EnsureExpectedIdentity(
                    "restored destination",
                    expectedBackupSha256,
                    restoredIdentity);
                backupIdentity = ComputeFileIdentity(normalizedBackupPath);
                EnsureExpectedIdentity("backup source", expectedBackupSha256, backupIdentity);
                recoveryOptions.EffectiveFaultInjector.OnPhase(
                    new StateStoreRecoveryPhaseContext(
                        StateStoreRecoveryPhase.AfterRollback,
                        backupVersion,
                        restoredVersion,
                        normalizedBackupPath));

                var trace = CreateTrace(
                    operation: "BackupRestore",
                    outcome: "BackupRestored",
                    databasePath: normalizedDatabasePath,
                    fromVersion: backupVersion,
                    toVersion: restoredVersion,
                    primary: restoredIdentity,
                    backup: backupIdentity,
                    sidecars: null,
                    quarantineDirectory: null,
                    failure: null,
                    timeProvider);
                var tracePath = WriteTrace(
                    normalizedDatabasePath,
                    "backup-restore",
                    trace,
                    timeProvider,
                    recoveryOptions);
                restoreCompleted = true;
                return new StateStoreRecoveryRestoreResult(
                    normalizedDatabasePath,
                    normalizedBackupPath,
                    tracePath,
                    priorPath,
                    restoredIdentity);
            }

            throw new HerdrStateStoreException(
                $"Unable to allocate a non-colliding rollback artifact beside '{normalizedDatabasePath}'.");
        }
        catch (Exception primary)
        {
            if (replacementAttempted && !restoreCompleted)
            {
                RollbackDestination(
                    normalizedDatabasePath,
                    originalDestinationIdentity,
                    priorPath,
                    recoveryOptions,
                    primary);
            }

            if (!movedIntoPlace && temporaryPath is not null)
            {
                CleanupFilePreservingPrimary(
                    temporaryPath,
                    recoveryOptions,
                    primary,
                    "restore-temporary-cleanup");
            }

            throw;
        }
    }

    private static bool IdentifyExpectedDestination(
        string databasePath,
        StateStoreRecoveryFileIdentity? expectedIdentity,
        out StateStoreRecoveryFileIdentity? actualIdentity)
    {
        StateStoreRecoveryPathPolicy.EnsureNoReparseComponents(
            databasePath,
            includeLeaf: true);
        if (Directory.Exists(databasePath))
        {
            throw new StateStoreCorruptionException(
                $"The state-store path '{databasePath}' is a directory, not a SQLite database.");
        }

        if (!File.Exists(databasePath))
        {
            actualIdentity = null;
        }
        else
        {
            actualIdentity = ComputeFileIdentity(databasePath);
        }

        if (!AreIdentical(expectedIdentity, actualIdentity))
        {
            throw new HerdrStateStoreException(
                "The destination file identity changed before atomic restore.");
        }

        return actualIdentity is not null;
    }

    private static void EnsureExpectedIdentity(
        string label,
        string expectedSha256,
        StateStoreRecoveryFileIdentity actualIdentity)
    {
        if (!string.Equals(
                expectedSha256,
                actualIdentity.Sha256,
                StringComparison.OrdinalIgnoreCase))
        {
            throw new HerdrStateStoreException(
                $"The {label} file identity changed before atomic restore.");
        }
    }

    private static void RollbackDestination(
        string databasePath,
        StateStoreRecoveryFileIdentity? originalDestinationIdentity,
        string? priorPath,
        StateStoreRecoveryOptions recoveryOptions,
        Exception primary)
    {
        try
        {
            StateStoreRecoveryPathPolicy.EnsureNoReparseComponents(
                databasePath,
                includeLeaf: true);

            recoveryOptions.EffectiveFaultInjector.OnPhase(
                new StateStoreRecoveryPhaseContext(
                    StateStoreRecoveryPhase.BeforeRestoreRollback,
                    0,
                    0,
                    databasePath));

            if (originalDestinationIdentity is not null)
            {
                if (priorPath is null)
                {
                    throw new HerdrStateStoreException(
                        "The original destination artifact was not retained for restore rollback.");
                }

                StateStoreRecoveryPathPolicy.EnsureNoReparseComponents(
                    priorPath,
                    includeLeaf: true);
                if (File.Exists(databasePath))
                {
                    File.Replace(
                        priorPath,
                        databasePath,
                        destinationBackupFileName: null,
                        ignoreMetadataErrors: true);
                }
                else
                {
                    File.Move(priorPath, databasePath, overwrite: false);
                }
            }
            else
            {
                if (Directory.Exists(databasePath))
                {
                    throw new HerdrStateStoreException(
                        "The restore destination became a directory while rolling back.");
                }

                if (File.Exists(databasePath))
                {
                    recoveryOptions.EffectiveCleanup.DeleteFile(databasePath);
                }
            }

            recoveryOptions.EffectiveFaultInjector.OnPhase(
                new StateStoreRecoveryPhaseContext(
                    StateStoreRecoveryPhase.AfterRestoreRollbackOperation,
                    0,
                    0,
                    databasePath));
        }
        catch (Exception rollbackFailure)
        {
            StateStoreRecoveryDiagnostics.AttachCleanupFailure(
                primary,
                "restore-rollback-operation",
                databasePath,
                rollbackFailure);
        }

        try
        {
            _ = IdentifyExpectedDestination(
                databasePath,
                originalDestinationIdentity,
                out _);
        }
        catch (Exception rollbackStateFailure)
        {
            StateStoreRecoveryDiagnostics.AttachRollbackStateFailure(
                primary,
                databasePath,
                rollbackStateFailure);
        }
    }

    public static string Quarantine(
        string databasePath,
        Exception failure,
        int? schemaVersion,
        string phase,
        TimeProvider timeProvider,
        StateStoreRecoveryOptions recoveryOptions)
    {
        ArgumentNullException.ThrowIfNull(failure);
        ArgumentNullException.ThrowIfNull(timeProvider);
        ArgumentNullException.ThrowIfNull(recoveryOptions);

        var normalizedDatabasePath = StateStoreRecoveryPathPolicy.NormalizeDatabasePath(databasePath);
        StateStoreRecoveryPathPolicy.ValidateExistingCopySource(normalizedDatabasePath);
        var parent = Path.GetDirectoryName(normalizedDatabasePath)!;
        var quarantineRoot = Path.Combine(parent, QuarantineDirectoryName);
        StateStoreRecoveryPathPolicy.EnsureDirectoryTree(quarantineRoot);
        StateStoreRecoveryPathPolicy.EnsureContainedPath(parent, quarantineRoot);

        var primaryIdentity = ComputeFileIdentity(normalizedDatabasePath);
        var sidecarPaths = new[]
        {
            normalizedDatabasePath + "-wal",
            normalizedDatabasePath + "-shm",
        }
        .Where(File.Exists)
        .ToArray();
        foreach (var sidecarPath in sidecarPaths)
        {
            StateStoreRecoveryPathPolicy.ValidateExistingCopySource(sidecarPath);
        }

        for (var attempt = 0; attempt < MaximumArtifactAttempts; attempt++)
        {
            var stamp = FormatStamp(timeProvider.GetUtcNow());
            var token = recoveryOptions.EffectiveGuidFactory().ToString("N");
            var baseName =
                $"{Path.GetFileName(normalizedDatabasePath)}.corrupt.{stamp}.{token}.{attempt:D2}";
            var quarantinePath = Path.Combine(quarantineRoot, baseName);
            var stagingPath = Path.Combine(quarantineRoot, $".{baseName}.staging");
            StateStoreRecoveryPathPolicy.EnsureContainedPath(parent, quarantinePath);
            StateStoreRecoveryPathPolicy.EnsureContainedPath(parent, stagingPath);
            if (File.Exists(quarantinePath) ||
                Directory.Exists(quarantinePath) ||
                File.Exists(stagingPath) ||
                Directory.Exists(stagingPath))
            {
                continue;
            }

            Directory.CreateDirectory(stagingPath);
            try
            {
                StateStoreRecoveryPathPolicy.EnsureNoReparseComponents(
                    stagingPath,
                    includeLeaf: true);
                var stagedPrimaryPath = Path.Combine(
                    stagingPath,
                    Path.GetFileName(normalizedDatabasePath));
                CopyExactly(normalizedDatabasePath, stagedPrimaryPath);
                var stagedPrimaryIdentity = ComputeFileIdentity(stagedPrimaryPath);
                if (!AreIdentical(primaryIdentity, stagedPrimaryIdentity))
                {
                    throw new HerdrStateStoreException(
                        "The state-store primary changed while it was being quarantined.");
                }

                var stagedSidecars = new List<StateStoreRecoveryFileIdentity>();
                foreach (var sidecarPath in sidecarPaths)
                {
                    var stagedSidecarPath = Path.Combine(
                        stagingPath,
                        Path.GetFileName(sidecarPath));
                    CopyExactly(sidecarPath, stagedSidecarPath);
                    stagedSidecars.Add(ComputeFileIdentity(stagedSidecarPath));
                }

                var trace = CreateTrace(
                    operation: "CorruptedStateQuarantine",
                    outcome: "Quarantined",
                    databasePath: normalizedDatabasePath,
                    fromVersion: schemaVersion,
                    toVersion: null,
                    primary: primaryIdentity,
                    backup: null,
                    sidecars: stagedSidecars.Count == 0 ? null : stagedSidecars.ToArray(),
                    quarantineDirectory: baseName,
                    failure: failure,
                    timeProvider: timeProvider,
                    phase: phase);
                var metadata = new
                {
                    ContractVersion = 1,
                    Operation = "CorruptedStateQuarantine",
                    DatabasePathToken = StateStoreRecoveryDiagnostics.TokenizePath(normalizedDatabasePath),
                    OriginalPrimaryRetained = true,
                    Primary = StateStoreRecoveryDiagnostics.SafeIdentity(primaryIdentity),
                    Sidecars = stagedSidecars.Count == 0
                        ? null
                        : stagedSidecars.Select(StateStoreRecoveryDiagnostics.SafeIdentity).ToArray(),
                    SchemaVersion = schemaVersion,
                    FailurePhase = phase,
                    FailureType = StateStoreRecoveryDiagnostics.SanitizeMessage(failure.GetType().FullName),
                    FailureMessage = StateStoreRecoveryDiagnostics.SanitizeMessage(failure.Message),
                    TraceFileName = "recovery-trace.json",
                    EvidenceClasses = new[] { "Static", "Synthetic", "Contract" },
                    ActualHerdrRuntime = "NOT_OBSERVED",
                    Release = "NOT_OBSERVED",
                    ObservedUtc = FormatUtc(timeProvider.GetUtcNow()),
                };
                WriteJsonFile(
                    Path.Combine(stagingPath, "metadata.json"),
                    metadata);
                WriteJsonFile(
                    Path.Combine(stagingPath, "recovery-trace.json"),
                    trace);

                recoveryOptions.EffectiveFaultInjector.OnPhase(
                    new StateStoreRecoveryPhaseContext(
                        StateStoreRecoveryPhase.BeforeQuarantineMove,
                        schemaVersion ?? 0,
                        null,
                        quarantinePath));
                try
                {
                    Directory.Move(stagingPath, quarantinePath);
                }
                catch (IOException moveFailure) when (
                    File.Exists(quarantinePath) || Directory.Exists(quarantinePath))
                {
                    var collisionFailure = new IOException(
                        "A quarantine artifact collision prevented atomic publication.",
                        moveFailure);
                    if (!TryCleanupDirectory(
                            stagingPath,
                            recoveryOptions,
                            collisionFailure,
                            "quarantine-collision-cleanup"))
                    {
                        throw collisionFailure;
                    }

                    continue;
                }

                return quarantinePath;
            }
            catch (Exception primary)
            {
                CleanupDirectoryPreservingPrimary(
                    stagingPath,
                    recoveryOptions,
                    primary,
                    "quarantine-staging-cleanup");
                throw;
            }
        }

        throw new HerdrStateStoreException(
            $"Unable to allocate a non-colliding quarantine directory under '{quarantineRoot}'.");
    }

    internal static string GetQuarantineCandidatePathForTesting(
        string databasePath,
        DateTimeOffset utcNow,
        Guid token,
        int attempt)
    {
        var normalized = StateStoreRecoveryPathPolicy.NormalizeDatabasePath(databasePath);
        var root = Path.Combine(
            Path.GetDirectoryName(normalized)!,
            QuarantineDirectoryName);
        var name =
            $"{Path.GetFileName(normalized)}.corrupt.{FormatStamp(utcNow)}.{token:N}.{attempt:D2}";
        return Path.Combine(root, name);
    }

    internal static void ValidateConnectionIdentity(
        SqliteConnection connection,
        string expectedPath) =>
        ValidateDatabaseIdentity(connection, expectedPath);

    internal static StateStoreRecoveryFileIdentity IdentifyFile(string path) =>
        ComputeFileIdentity(path);

    private static StateStoreRecoveryTrace CreateTrace(
        string operation,
        string outcome,
        string databasePath,
        int? fromVersion,
        int? toVersion,
        StateStoreRecoveryFileIdentity? primary,
        StateStoreRecoveryFileIdentity? backup,
        StateStoreRecoveryFileIdentity[]? sidecars,
        string? quarantineDirectory,
        Exception? failure,
        TimeProvider timeProvider,
        string? phase = null) => new(
        ContractVersion: 1,
        Operation: operation,
        Outcome: outcome,
        EvidenceClassification: "Static|Synthetic|Contract",
        EvidenceClasses: new[] { "Static", "Synthetic", "Contract" },
        ActualHerdrRuntime: "NOT_OBSERVED",
        Release: "NOT_OBSERVED",
        DatabaseFileName: StateStoreRecoveryDiagnostics.TokenizeArtifactName(Path.GetFileName(databasePath)),
        FromSchemaVersion: fromVersion,
        ToSchemaVersion: toVersion,
        Primary: primary is null ? null : StateStoreRecoveryDiagnostics.SafeIdentity(primary),
        Backup: backup is null ? null : StateStoreRecoveryDiagnostics.SafeIdentity(backup),
        Sidecars: sidecars?.Select(StateStoreRecoveryDiagnostics.SafeIdentity).ToArray(),
        QuarantineDirectory: quarantineDirectory is null
            ? null
            : StateStoreRecoveryDiagnostics.TokenizeArtifactName(quarantineDirectory),
        Phase: phase,
        FailureType: failure is null
            ? null
            : StateStoreRecoveryDiagnostics.SanitizeMessage(failure.GetType().FullName),
        FailureMessage: failure is null
            ? null
            : StateStoreRecoveryDiagnostics.SanitizeMessage(failure.Message),
        ObservedUtc: FormatUtc(timeProvider.GetUtcNow()));

    private static string WriteTrace(
        string databasePath,
        string prefix,
        StateStoreRecoveryTrace trace,
        TimeProvider timeProvider,
        StateStoreRecoveryOptions recoveryOptions)
    {
        var parent = Path.GetDirectoryName(databasePath)!;
        var recoveryDirectory = Path.Combine(parent, RecoveryDirectoryName);
        StateStoreRecoveryPathPolicy.EnsureDirectoryTree(recoveryDirectory);
        StateStoreRecoveryPathPolicy.EnsureContainedPath(parent, recoveryDirectory);
        var json = JsonSerializer.SerializeToUtf8Bytes(trace, TraceJsonOptions);

        for (var attempt = 0; attempt < MaximumArtifactAttempts; attempt++)
        {
            var stamp = FormatStamp(timeProvider.GetUtcNow());
            var token = recoveryOptions.EffectiveGuidFactory().ToString("N");
            var baseName = $"{prefix}.{stamp}.{token}.{attempt:D2}";
            var temporaryPath = Path.Combine(recoveryDirectory, $".{baseName}.tmp");
            var tracePath = Path.Combine(recoveryDirectory, $"{baseName}.json");
            StateStoreRecoveryPathPolicy.EnsureContainedPath(parent, temporaryPath);
            StateStoreRecoveryPathPolicy.EnsureContainedPath(parent, tracePath);
            if (File.Exists(temporaryPath) ||
                Directory.Exists(temporaryPath) ||
                File.Exists(tracePath) ||
                Directory.Exists(tracePath))
            {
                continue;
            }

            try
            {
                WriteBytes(temporaryPath, json);
                recoveryOptions.EffectiveFaultInjector.OnPhase(
                    new StateStoreRecoveryPhaseContext(
                        StateStoreRecoveryPhase.AfterTraceTemporaryCreated,
                        trace.FromSchemaVersion ?? 0,
                        trace.ToSchemaVersion,
                        temporaryPath));
                if (TryMoveWithoutOverwrite(temporaryPath, tracePath))
                {
                    return tracePath;
                }

                var collisionFailure = new IOException(
                    "A recovery trace artifact collision prevented atomic publication.");
                if (!TryCleanupFile(
                        temporaryPath,
                        recoveryOptions,
                        collisionFailure,
                        "trace-temporary-cleanup"))
                {
                    throw collisionFailure;
                }
            }
            catch (Exception primary)
            {
                CleanupFilePreservingPrimary(
                    temporaryPath,
                    recoveryOptions,
                    primary,
                    "trace-temporary-cleanup");
                throw;
            }
        }

        throw new HerdrStateStoreException(
            $"Unable to allocate a non-colliding recovery trace under '{recoveryDirectory}'.");
    }

    private static int ValidateSqliteFile(string path, int? expectedUserVersion = null)
    {
        StateStoreRecoveryPathPolicy.ValidateExistingPrimary(path);
        using var connection = OpenSqlite(path, SqliteOpenMode.ReadOnly);
        return ValidateSqliteConnection(connection, path, expectedUserVersion);
    }

    private static int ValidateSqliteConnection(
        SqliteConnection connection,
        string expectedPath,
        int? expectedUserVersion = null)
    {
        ValidateDatabaseIdentity(connection, expectedPath);
        var quickCheck = ExecuteScalarString(connection, "PRAGMA quick_check;");
        if (!string.Equals(quickCheck, "ok", StringComparison.OrdinalIgnoreCase))
        {
            throw new StateStoreCorruptionException(
                $"SQLite quick_check failed for '{expectedPath}': {quickCheck}");
        }

        var integrityCheck = ExecuteScalarString(connection, "PRAGMA integrity_check;");
        if (!string.Equals(integrityCheck, "ok", StringComparison.OrdinalIgnoreCase))
        {
            throw new StateStoreCorruptionException(
                $"SQLite integrity_check failed for '{expectedPath}': {integrityCheck}");
        }

        var userVersion = checked((int)ExecuteScalarInt64(connection, "PRAGMA user_version;"));
        _ = ExecuteScalarInt64(connection, "PRAGMA schema_version;");
        if (expectedUserVersion.HasValue && userVersion != expectedUserVersion.Value)
        {
            throw new StateStoreCorruptionException(
                $"SQLite user_version {userVersion} did not match expected v{expectedUserVersion.Value} for '{expectedPath}'.");
        }

        return userVersion;
    }

    private static void ValidateDatabaseIdentity(SqliteConnection connection, string expectedPath)
    {
        using var command = connection.CreateCommand();
        command.CommandText = "PRAGMA database_list;";
        using var reader = command.ExecuteReader();
        var foundMain = false;
        while (reader.Read())
        {
            var name = reader.GetString(1);
            if (!string.Equals(name, "main", StringComparison.Ordinal))
            {
                continue;
            }

            foundMain = true;
            var actualPath = reader.GetString(2);
            if (!string.Equals(
                    Path.GetFullPath(actualPath),
                    Path.GetFullPath(expectedPath),
                    StringComparison.OrdinalIgnoreCase))
            {
                throw new StateStoreCorruptionException(
                    $"SQLite main database identity '{actualPath}' did not match expected '{expectedPath}'.");
            }
        }

        if (!foundMain)
        {
            throw new StateStoreCorruptionException(
                $"SQLite did not expose a main database for '{expectedPath}'.");
        }
    }

    private static SqliteConnection OpenSqlite(string path, SqliteOpenMode mode)
    {
        var connection = new SqliteConnection(new SqliteConnectionStringBuilder
        {
            DataSource = path,
            Mode = mode,
            Cache = SqliteCacheMode.Default,
            Pooling = false,
        }.ToString());
        connection.Open();
        return connection;
    }

    private static string ExecuteScalarString(SqliteConnection connection, string sql) =>
        Convert.ToString(ExecuteScalar(connection, sql), CultureInfo.InvariantCulture)
        ?? throw new StateStoreCorruptionException($"SQLite returned no value for '{sql}'.");

    private static long ExecuteScalarInt64(SqliteConnection connection, string sql) =>
        Convert.ToInt64(ExecuteScalar(connection, sql), CultureInfo.InvariantCulture);

    private static object ExecuteScalar(SqliteConnection connection, string sql)
    {
        using var command = connection.CreateCommand();
        command.CommandText = sql;
        return command.ExecuteScalar()
            ?? throw new StateStoreCorruptionException($"SQLite returned no value for '{sql}'.");
    }

    private static StateStoreRecoveryFileIdentity ComputeFileIdentity(string path)
    {
        StateStoreRecoveryPathPolicy.ValidateExistingCopySource(path);
        using var stream = new FileStream(
            path,
            FileMode.Open,
            FileAccess.Read,
            FileShare.ReadWrite | FileShare.Delete,
            CopyBufferSize,
            FileOptions.SequentialScan);
        var hash = SHA256.HashData(stream);
        return new StateStoreRecoveryFileIdentity(
            Path.GetFileName(path),
            stream.Length,
            Convert.ToHexString(hash));
    }

    private static void CopyExactly(string sourcePath, string destinationPath)
    {
        StateStoreRecoveryPathPolicy.ValidateExistingCopySource(sourcePath);
        StateStoreRecoveryPathPolicy.EnsureNoReparseComponents(
            Path.GetDirectoryName(destinationPath)!,
            includeLeaf: true);
        using var source = new FileStream(
            sourcePath,
            FileMode.Open,
            FileAccess.Read,
            FileShare.Read,
            CopyBufferSize,
            FileOptions.SequentialScan);
        using var destination = new FileStream(
            destinationPath,
            FileMode.CreateNew,
            FileAccess.Write,
            FileShare.None,
            CopyBufferSize,
            FileOptions.SequentialScan);
        source.CopyTo(destination, CopyBufferSize);
        destination.Flush(flushToDisk: true);
    }

    private static void CreateEmptyFile(string path)
    {
        using var stream = new FileStream(
            path,
            FileMode.CreateNew,
            FileAccess.ReadWrite,
            FileShare.None,
            bufferSize: 1,
            FileOptions.WriteThrough);
        stream.Flush(flushToDisk: true);
    }

    private static void WriteBytes(string path, byte[] bytes)
    {
        using var stream = new FileStream(
            path,
            FileMode.CreateNew,
            FileAccess.Write,
            FileShare.None,
            CopyBufferSize,
            FileOptions.WriteThrough);
        stream.Write(bytes, 0, bytes.Length);
        stream.Flush(flushToDisk: true);
    }

    private static void WriteJsonFile(string path, object value) =>
        WriteBytes(path, JsonSerializer.SerializeToUtf8Bytes(value, TraceJsonOptions));

    private static void FlushFile(string path)
    {
        using var stream = new FileStream(
            path,
            FileMode.Open,
            FileAccess.ReadWrite,
            FileShare.Read,
            bufferSize: 1,
            FileOptions.WriteThrough);
        stream.Flush(flushToDisk: true);
    }

    private static bool TryMoveWithoutOverwrite(string sourcePath, string destinationPath)
    {
        try
        {
            File.Move(sourcePath, destinationPath, overwrite: false);
            return true;
        }
        catch (IOException) when (File.Exists(destinationPath) || Directory.Exists(destinationPath))
        {
            return false;
        }
    }

    private static bool AreIdentical(
        StateStoreRecoveryFileIdentity? left,
        StateStoreRecoveryFileIdentity? right) =>
        left is null && right is null ||
        left is not null && right is not null &&
        left.Length == right.Length &&
        string.Equals(left.Sha256, right.Sha256, StringComparison.Ordinal);

    private static void CleanupFilePreservingPrimary(
        string path,
        StateStoreRecoveryOptions recoveryOptions,
        Exception primary,
        string operation)
    {
        _ = TryCleanupFile(path, recoveryOptions, primary, operation);
    }

    private static void CleanupDirectoryPreservingPrimary(
        string path,
        StateStoreRecoveryOptions recoveryOptions,
        Exception primary,
        string operation)
    {
        _ = TryCleanupDirectory(path, recoveryOptions, primary, operation);
    }

    private static bool TryCleanupFile(
        string path,
        StateStoreRecoveryOptions recoveryOptions,
        Exception primary,
        string operation)
    {
        try
        {
            recoveryOptions.EffectiveCleanup.DeleteFile(path);
            return true;
        }
        catch (Exception cleanupFailure)
        {
            StateStoreRecoveryDiagnostics.AttachCleanupFailure(
                primary,
                operation,
                path,
                cleanupFailure);
            return false;
        }
    }

    private static bool TryCleanupDirectory(
        string path,
        StateStoreRecoveryOptions recoveryOptions,
        Exception primary,
        string operation)
    {
        try
        {
            recoveryOptions.EffectiveCleanup.DeleteDirectoryTree(path);
            return true;
        }
        catch (Exception cleanupFailure)
        {
            StateStoreRecoveryDiagnostics.AttachCleanupFailure(
                primary,
                operation,
                path,
                cleanupFailure);
            return false;
        }
    }

    private static string FormatStamp(DateTimeOffset value) =>
        value.ToUniversalTime().ToString(
            "yyyyMMddTHHmmssfff'Z'",
            CultureInfo.InvariantCulture);

    private static string FormatUtc(DateTimeOffset value) =>
        value.ToUniversalTime().ToString("O", CultureInfo.InvariantCulture);
}
