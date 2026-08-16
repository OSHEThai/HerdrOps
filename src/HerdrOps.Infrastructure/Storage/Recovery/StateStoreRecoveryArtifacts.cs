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

            CreateEmptyFile(temporaryPath);
            try
            {
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
                    TryDeleteFile(temporaryPath);
                    continue;
                }

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
            catch
            {
                TryDeleteFile(temporaryPath);
                throw;
            }
        }

        throw new HerdrStateStoreException(
            $"Unable to allocate a non-colliding SQLite backup under '{backupDirectory}'.");
    }

    public static StateStoreRecoveryRestoreResult RestoreBackup(
        string databasePath,
        string backupPath,
        TimeProvider timeProvider,
        StateStoreRecoveryOptions recoveryOptions)
    {
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
        StateStoreRecoveryPathPolicy.ValidateExistingPrimary(normalizedBackupPath);
        var backupVersion = ValidateSqliteFile(normalizedBackupPath);
        var backupIdentity = ComputeFileIdentity(normalizedBackupPath);

        var primaryExists = File.Exists(normalizedDatabasePath);
        if (primaryExists)
        {
            StateStoreRecoveryPathPolicy.EnsureNoReparseComponents(
                normalizedDatabasePath,
                includeLeaf: true);
        }

        string? temporaryPath = null;
        string? priorPath = null;
        var movedIntoPlace = false;
        var validatedAfterReplacement = false;
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
                        normalizedBackupPath));

                if (primaryExists)
                {
                    File.Replace(
                        temporaryPath,
                        normalizedDatabasePath,
                        priorPath,
                        ignoreMetadataErrors: true);
                    movedIntoPlace = true;
                }
                else
                {
                    File.Move(temporaryPath, normalizedDatabasePath, overwrite: false);
                    movedIntoPlace = true;
                    priorPath = null;
                }

                var restoredVersion = ValidateSqliteFile(
                    normalizedDatabasePath,
                    expectedUserVersion: backupVersion);
                validatedAfterReplacement = true;
                var restoredIdentity = ComputeFileIdentity(normalizedDatabasePath);
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
                recoveryOptions.EffectiveFaultInjector.OnPhase(
                    new StateStoreRecoveryPhaseContext(
                        StateStoreRecoveryPhase.AfterRollback,
                        backupVersion,
                        restoredVersion,
                        normalizedBackupPath));
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
        catch
        {
            if (movedIntoPlace && !validatedAfterReplacement && priorPath is not null)
            {
                try
                {
                    if (File.Exists(priorPath))
                    {
                        File.Replace(
                            priorPath,
                            normalizedDatabasePath,
                            destinationBackupFileName: null,
                            ignoreMetadataErrors: true);
                    }
                }
                catch
                {
                    // The original failure remains authoritative; the prior artifact is retained for diagnosis.
                }
            }

            if (!movedIntoPlace && temporaryPath is not null)
            {
                TryDeleteFile(temporaryPath);
            }

            throw;
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
                    OriginalDatabasePath = normalizedDatabasePath,
                    OriginalPrimaryRetained = true,
                    Primary = primaryIdentity,
                    Sidecars = stagedSidecars.Count == 0 ? null : stagedSidecars.ToArray(),
                    SchemaVersion = schemaVersion,
                    FailurePhase = phase,
                    FailureType = failure.GetType().FullName,
                    FailureMessage = failure.Message,
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

                try
                {
                    Directory.Move(stagingPath, quarantinePath);
                }
                catch (IOException)
                {
                    DeleteDirectoryTree(stagingPath);
                    continue;
                }

                return quarantinePath;
            }
            catch
            {
                DeleteDirectoryTree(stagingPath);
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
        DatabaseFileName: Path.GetFileName(databasePath),
        FromSchemaVersion: fromVersion,
        ToSchemaVersion: toVersion,
        Primary: primary,
        Backup: backup,
        Sidecars: sidecars,
        QuarantineDirectory: quarantineDirectory,
        Phase: phase,
        FailureType: failure?.GetType().FullName,
        FailureMessage: failure?.Message,
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

            WriteBytes(temporaryPath, json);
            if (TryMoveWithoutOverwrite(temporaryPath, tracePath))
            {
                return tracePath;
            }

            TryDeleteFile(temporaryPath);
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
        StateStoreRecoveryFileIdentity left,
        StateStoreRecoveryFileIdentity right) =>
        left.Length == right.Length &&
        string.Equals(left.Sha256, right.Sha256, StringComparison.Ordinal);

    private static void TryDeleteFile(string path)
    {
        try
        {
            if (File.Exists(path))
            {
                File.Delete(path);
            }
        }
        catch (FileNotFoundException)
        {
        }
    }

    private static void DeleteDirectoryTree(string path)
    {
        try
        {
            if (Directory.Exists(path))
            {
                Directory.Delete(path, recursive: true);
            }
        }
        catch (DirectoryNotFoundException)
        {
        }
    }

    private static string FormatStamp(DateTimeOffset value) =>
        value.ToUniversalTime().ToString(
            "yyyyMMddTHHmmssfff'Z'",
            CultureInfo.InvariantCulture);

    private static string FormatUtc(DateTimeOffset value) =>
        value.ToUniversalTime().ToString("O", CultureInfo.InvariantCulture);
}
