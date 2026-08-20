using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using HerdrOps.Infrastructure.Storage;
using HerdrOps.Infrastructure.Storage.Recovery;
using Microsoft.Data.Sqlite;

namespace HerdrOps.IntegrationTests;

[TestClass]
public sealed class StateStoreRecoveryTests
{
    private static readonly DateTimeOffset FixedUtc =
        new(2026, 8, 17, 1, 2, 3, TimeSpan.Zero);

    private static readonly Guid FixedToken =
        Guid.Parse("11111111-2222-3333-4444-555555555555");

    [TestMethod]
    public void InterruptionBeforeBackupLeavesPrimaryUnchangedAndCreatesNoBackup()
    {
        using var directory = new TemporaryDirectory();
        var databasePath = Path.Combine(directory.Path, "before-backup.db");
        CreateLegacyDatabase(databasePath, "before-backup");
        var originalBytes = File.ReadAllBytes(databasePath);
        var options = CreateRecoveryOptions(StateStoreRecoveryPhase.BeforeBackup);

        Assert.Throws<StateStoreRecoveryInterruptionException>(() =>
            new SqliteHerdrStateStore(
                new HerdrStateStoreOptions(databasePath),
                new FixedTimeProvider(FixedUtc),
                options));

        CollectionAssert.AreEqual(originalBytes, File.ReadAllBytes(databasePath));
        Assert.IsFalse(Directory.Exists(Path.Combine(directory.Path, "backups")));
        Assert.AreEqual(0L, ReadUserVersion(databasePath));
    }

    [TestMethod]
    public void InterruptionAfterBackupLeavesByteIdentifiableRecoverableBackupAndTrace()
    {
        using var directory = new TemporaryDirectory();
        var databasePath = Path.Combine(directory.Path, "after-backup.db");
        CreateLegacyDatabase(databasePath, "after-backup");
        var originalBytes = File.ReadAllBytes(databasePath);
        string? backupPath = null;
        var options = new StateStoreRecoveryOptions(
            new DelegateStateStoreRecoveryFaultInjector(context =>
            {
                if (context.Phase == StateStoreRecoveryPhase.AfterBackup)
                {
                    backupPath = context.ArtifactPath;
                    throw new StateStoreRecoveryInterruptionException(context);
                }
            }),
            () => FixedToken);

        Assert.Throws<StateStoreRecoveryInterruptionException>(() =>
            new SqliteHerdrStateStore(
                new HerdrStateStoreOptions(databasePath),
                new FixedTimeProvider(FixedUtc),
                options));

        Assert.IsFalse(string.IsNullOrWhiteSpace(backupPath));
        var recoveredBackupPath = backupPath!;
        Assert.IsTrue(File.Exists(recoveredBackupPath));
        CollectionAssert.AreEqual(originalBytes, File.ReadAllBytes(databasePath));
        Assert.AreEqual(0L, ReadUserVersion(recoveredBackupPath));
        Assert.AreEqual("ok", ReadTextScalar(recoveredBackupPath, "PRAGMA integrity_check;"));

        var expectedHash = Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(recoveredBackupPath)));
        var tracePath = Directory.GetFiles(
                Path.Combine(directory.Path, "recovery"),
                "*.json")
            .Single();
        using var trace = JsonDocument.Parse(File.ReadAllBytes(tracePath));
        var root = trace.RootElement;
        CollectionAssert.AreEquivalent(
            new[] { "Static", "Synthetic", "Contract" },
            root.GetProperty("EvidenceClasses").EnumerateArray()
                .Select(element => element.GetString()!)
                .ToArray());
        Assert.AreEqual("NOT_OBSERVED", root.GetProperty("ActualHerdrRuntime").GetString());
        Assert.AreEqual("NOT_OBSERVED", root.GetProperty("Release").GetString());
        Assert.AreEqual(
            expectedHash,
            root.GetProperty("Backup").GetProperty("Sha256").GetString());
    }

    [TestMethod]
    public void InterruptedMigrationRollsBackAndBackupCanBeRestoredWithIntegrityCheck()
    {
        using var directory = new TemporaryDirectory();
        var databasePath = Path.Combine(directory.Path, "rollback.db");
        CreateLegacyDatabase(databasePath, "rollback");
        var options = new StateStoreRecoveryOptions(
            new DelegateStateStoreRecoveryFaultInjector(context =>
            {
                if (context.Phase == StateStoreRecoveryPhase.AfterMigrationBeforeCommit)
                {
                    throw new StateStoreRecoveryInterruptionException(context);
                }
            }),
            () => FixedToken);

        Assert.Throws<StateStoreRecoveryInterruptionException>(() =>
            new SqliteHerdrStateStore(
                new HerdrStateStoreOptions(databasePath),
                new FixedTimeProvider(FixedUtc),
                options));

        Assert.AreEqual(0L, ReadUserVersion(databasePath));
        Assert.AreEqual(0L, ReadLongScalar(
            databasePath,
            "SELECT COUNT(*) FROM sqlite_master WHERE name = 'schema_migrations';"));

        var backupPath = Directory.GetFiles(
                Path.Combine(directory.Path, "backups"),
                "*.bak")
            .Single();
        var originalBackupBytes = File.ReadAllBytes(backupPath);
        var expectedBackupIdentity = StateStoreRecoveryArtifacts.IdentifyFile(backupPath);
        var expectedDatabaseIdentity = StateStoreRecoveryArtifacts.IdentifyFile(databasePath);
        var restored = StateStoreRecoveryArtifacts.RestoreBackup(
            databasePath,
            backupPath,
            expectedBackupIdentity.Sha256,
            expectedDatabaseIdentity,
            new FixedTimeProvider(FixedUtc),
            new StateStoreRecoveryOptions(GuidFactory: () => FixedToken));

        CollectionAssert.AreEqual(originalBackupBytes, File.ReadAllBytes(databasePath));
        Assert.AreEqual("ok", ReadTextScalar(databasePath, "PRAGMA quick_check;"));
        Assert.AreEqual("ok", ReadTextScalar(databasePath, "PRAGMA integrity_check;"));
        Assert.IsTrue(File.Exists(restored.TracePath));
        Assert.IsTrue(
            restored.PriorDatabasePath is not null &&
            File.Exists(restored.PriorDatabasePath));
    }

    [TestMethod]
    public void RestoreRejectsChangedSourceOrStagedBytesBeforeAtomicReplace()
    {
        using var directory = new TemporaryDirectory();
        var databasePath = Path.Combine(directory.Path, "source-toctou.db");
        var changedPath = Path.Combine(directory.Path, "changed-source.db");
        CreateLegacyDatabase(databasePath, "original");
        CreateLegacyDatabase(changedPath, "changed");

        string backupPath;
        using (var source = OpenDatabase(databasePath, SqliteOpenMode.ReadWrite))
        {
            backupPath = StateStoreRecoveryArtifacts.CreateBackup(
                source,
                databasePath,
                fromVersion: 0,
                toVersion: HerdrStateStoreOptions.CurrentSchemaVersion,
                timeProvider: new FixedTimeProvider(FixedUtc),
                recoveryOptions: new StateStoreRecoveryOptions(GuidFactory: () => FixedToken))
                .BackupPath;
        }

        var originalDestinationBytes = File.ReadAllBytes(databasePath);
        var expectedBackupIdentity = StateStoreRecoveryArtifacts.IdentifyFile(backupPath);
        var expectedDestinationIdentity = StateStoreRecoveryArtifacts.IdentifyFile(databasePath);
        var replaceAttempt = 0;
        var exception = Assert.Throws<HerdrStateStoreException>(() =>
            StateStoreRecoveryArtifacts.RestoreBackup(
                databasePath,
                backupPath,
                expectedBackupIdentity.Sha256,
                expectedDestinationIdentity,
                new FixedTimeProvider(FixedUtc),
                new StateStoreRecoveryOptions(
                    new DelegateStateStoreRecoveryFaultInjector(context =>
                    {
                        if (context.Phase == StateStoreRecoveryPhase.BeforeRollback)
                        {
                            replaceAttempt++;
                            File.Copy(changedPath, backupPath, overwrite: true);
                        }
                    }),
                    () => FixedToken)));

        StringAssert.Contains(exception.Message, "identity", StringComparison.OrdinalIgnoreCase);
        Assert.AreEqual(1, replaceAttempt);
        CollectionAssert.AreEqual(originalDestinationBytes, File.ReadAllBytes(databasePath));
        Assert.IsFalse(
            Directory.GetFiles(directory.Path, "*.rollback.*.tmp", SearchOption.TopDirectoryOnly).Any());
        Assert.AreNotEqual(expectedBackupIdentity.Sha256, StateStoreRecoveryArtifacts.IdentifyFile(backupPath).Sha256);
    }

    [TestMethod]
    public void RestoreRejectsChangedStagedCopyBeforeAtomicReplace()
    {
        using var directory = new TemporaryDirectory();
        var databasePath = Path.Combine(directory.Path, "staged-toctou.db");
        var changedPath = Path.Combine(directory.Path, "changed-staged.db");
        CreateLegacyDatabase(databasePath, "original");
        CreateLegacyDatabase(changedPath, "changed");

        string backupPath;
        using (var source = OpenDatabase(databasePath, SqliteOpenMode.ReadWrite))
        {
            backupPath = StateStoreRecoveryArtifacts.CreateBackup(
                source,
                databasePath,
                fromVersion: 0,
                toVersion: HerdrStateStoreOptions.CurrentSchemaVersion,
                timeProvider: new FixedTimeProvider(FixedUtc),
                recoveryOptions: new StateStoreRecoveryOptions(GuidFactory: () => FixedToken))
                .BackupPath;
        }

        var originalDestinationBytes = File.ReadAllBytes(databasePath);
        var expectedBackupIdentity = StateStoreRecoveryArtifacts.IdentifyFile(backupPath);
        var expectedDestinationIdentity = StateStoreRecoveryArtifacts.IdentifyFile(databasePath);
        Assert.Throws<HerdrStateStoreException>(() =>
            StateStoreRecoveryArtifacts.RestoreBackup(
                databasePath,
                backupPath,
                expectedBackupIdentity.Sha256,
                expectedDestinationIdentity,
                new FixedTimeProvider(FixedUtc),
                new StateStoreRecoveryOptions(
                    new DelegateStateStoreRecoveryFaultInjector(context =>
                    {
                        if (context.Phase == StateStoreRecoveryPhase.BeforeRollback)
                        {
                            File.Copy(changedPath, context.ArtifactPath!, overwrite: true);
                        }
                    }),
                    () => FixedToken)));

        CollectionAssert.AreEqual(originalDestinationBytes, File.ReadAllBytes(databasePath));
        Assert.AreEqual(expectedBackupIdentity.Sha256, StateStoreRecoveryArtifacts.IdentifyFile(backupPath).Sha256);
        Assert.IsFalse(
            Directory.GetFiles(directory.Path, "*.rollback.*.tmp", SearchOption.TopDirectoryOnly).Any());
    }

    [TestMethod]
    public void FailedRestorePostconditionRollsExistingDestinationBackToOriginal()
    {
        using var directory = new TemporaryDirectory();
        var databasePath = Path.Combine(directory.Path, "postcondition.db");
        var changedPath = Path.Combine(directory.Path, "postcondition-changed.db");
        CreateLegacyDatabase(databasePath, "original");
        CreateLegacyDatabase(changedPath, "changed");

        string backupPath;
        using (var source = OpenDatabase(databasePath, SqliteOpenMode.ReadWrite))
        {
            backupPath = StateStoreRecoveryArtifacts.CreateBackup(
                source,
                databasePath,
                fromVersion: 0,
                toVersion: HerdrStateStoreOptions.CurrentSchemaVersion,
                timeProvider: new FixedTimeProvider(FixedUtc),
                recoveryOptions: new StateStoreRecoveryOptions(GuidFactory: () => FixedToken))
                .BackupPath;
        }

        var originalDestinationBytes = File.ReadAllBytes(databasePath);
        var expectedBackupIdentity = StateStoreRecoveryArtifacts.IdentifyFile(backupPath);
        var expectedDestinationIdentity = StateStoreRecoveryArtifacts.IdentifyFile(databasePath);
        Assert.Throws<HerdrStateStoreException>(() =>
            StateStoreRecoveryArtifacts.RestoreBackup(
                databasePath,
                backupPath,
                expectedBackupIdentity.Sha256,
                expectedDestinationIdentity,
                new FixedTimeProvider(FixedUtc),
                new StateStoreRecoveryOptions(
                    new DelegateStateStoreRecoveryFaultInjector(context =>
                    {
                        if (context.Phase == StateStoreRecoveryPhase.AfterRestoreReplacement)
                        {
                            File.Copy(changedPath, databasePath, overwrite: true);
                        }
                    }),
                    () => FixedToken)));

        CollectionAssert.AreEqual(originalDestinationBytes, File.ReadAllBytes(databasePath));
        Assert.IsFalse(
            Directory.GetFiles(directory.Path, "*.rollback.*.prior.bak", SearchOption.TopDirectoryOnly).Any());
    }

    [TestMethod]
    public void FailedRestorePostconditionLeavesAbsentDestinationAbsent()
    {
        using var directory = new TemporaryDirectory();
        var sourcePath = Path.Combine(directory.Path, "source.db");
        var databasePath = Path.Combine(directory.Path, "absent-destination.db");
        var changedPath = Path.Combine(directory.Path, "absent-changed.db");
        CreateLegacyDatabase(sourcePath, "source");
        CreateLegacyDatabase(changedPath, "changed");
        Directory.CreateDirectory(Path.Combine(directory.Path, "backups"));
        var backupPath = Path.Combine(directory.Path, "backups", "absent-destination.bak");
        File.Copy(sourcePath, backupPath);

        var expectedBackupIdentity = StateStoreRecoveryArtifacts.IdentifyFile(backupPath);
        Assert.Throws<HerdrStateStoreException>(() =>
            StateStoreRecoveryArtifacts.RestoreBackup(
                databasePath,
                backupPath,
                expectedBackupIdentity.Sha256,
                expectedDestinationIdentity: null,
                new FixedTimeProvider(FixedUtc),
                new StateStoreRecoveryOptions(
                    new DelegateStateStoreRecoveryFaultInjector(context =>
                    {
                        if (context.Phase == StateStoreRecoveryPhase.AfterRestoreReplacement)
                        {
                            File.Copy(changedPath, databasePath, overwrite: true);
                        }
                    }),
                    () => FixedToken)));

        Assert.IsFalse(File.Exists(databasePath));
    }

    [TestMethod]
    public void InjectedRollbackOperationFailurePreservesPrimaryAndRecordsRollbackStateFailure()
    {
        using var directory = new TemporaryDirectory();
        var databasePath = Path.Combine(directory.Path, "rollback-operation-failure.db");
        var changedPath = Path.Combine(directory.Path, "rollback-operation-changed.db");
        CreateLegacyDatabase(databasePath, "original");
        CreateLegacyDatabase(changedPath, "changed");
        string backupPath;
        using (var source = OpenDatabase(databasePath, SqliteOpenMode.ReadWrite))
        {
            backupPath = StateStoreRecoveryArtifacts.CreateBackup(
                source,
                databasePath,
                fromVersion: 0,
                toVersion: HerdrStateStoreOptions.CurrentSchemaVersion,
                timeProvider: new FixedTimeProvider(FixedUtc),
                recoveryOptions: new StateStoreRecoveryOptions(GuidFactory: () => FixedToken))
                .BackupPath;
        }

        var backupIdentity = StateStoreRecoveryArtifacts.IdentifyFile(backupPath);
        var destinationIdentity = StateStoreRecoveryArtifacts.IdentifyFile(databasePath);
        var exception = Assert.Throws<HerdrStateStoreException>(() =>
            StateStoreRecoveryArtifacts.RestoreBackup(
                databasePath,
                backupPath,
                backupIdentity.Sha256,
                destinationIdentity,
                new FixedTimeProvider(FixedUtc),
                new StateStoreRecoveryOptions(
                    new DelegateStateStoreRecoveryFaultInjector(context =>
                    {
                        if (context.Phase == StateStoreRecoveryPhase.AfterRestoreReplacement)
                        {
                            File.Copy(changedPath, databasePath, overwrite: true);
                        }
                        else if (context.Phase == StateStoreRecoveryPhase.BeforeRestoreRollback)
                        {
                            throw new IOException("injected rollback operation failure");
                        }
                    }),
                    () => FixedToken)));

        StringAssert.Contains(exception.Message, "identity", StringComparison.OrdinalIgnoreCase);
        var cleanupFailures = exception.Data["HerdrOps.RecoveryCleanupFailures"] as string[];
        Assert.IsNotNull(cleanupFailures);
        Assert.IsTrue(cleanupFailures!.Any(value => value.Contains("restore-rollback-operation", StringComparison.Ordinal)));
        var stateFailures = exception.Data["HerdrOps.RecoveryRollbackStateFailures"] as string[];
        Assert.IsNotNull(stateFailures);
        Assert.IsTrue(stateFailures!.Any(value => value.Contains("restore-rollback-state", StringComparison.Ordinal)));
        Assert.AreEqual(
            StateStoreRecoveryArtifacts.IdentifyFile(changedPath).Sha256,
            StateStoreRecoveryArtifacts.IdentifyFile(databasePath).Sha256);
    }

    [TestMethod]
    public void InjectedPostRollbackCorruptionIsReportedWithoutReplacingPrimary()
    {
        using var directory = new TemporaryDirectory();
        var databasePath = Path.Combine(directory.Path, "post-rollback-corruption.db");
        var changedPath = Path.Combine(directory.Path, "post-rollback-corruption-source.db");
        CreateLegacyDatabase(databasePath, "original");
        CreateLegacyDatabase(changedPath, "changed");
        string backupPath;
        using (var source = OpenDatabase(databasePath, SqliteOpenMode.ReadWrite))
        {
            backupPath = StateStoreRecoveryArtifacts.CreateBackup(
                source,
                databasePath,
                fromVersion: 0,
                toVersion: HerdrStateStoreOptions.CurrentSchemaVersion,
                timeProvider: new FixedTimeProvider(FixedUtc),
                recoveryOptions: new StateStoreRecoveryOptions(GuidFactory: () => FixedToken))
                .BackupPath;
        }

        var backupIdentity = StateStoreRecoveryArtifacts.IdentifyFile(backupPath);
        var destinationIdentity = StateStoreRecoveryArtifacts.IdentifyFile(databasePath);
        var exception = Assert.Throws<HerdrStateStoreException>(() =>
            StateStoreRecoveryArtifacts.RestoreBackup(
                databasePath,
                backupPath,
                backupIdentity.Sha256,
                destinationIdentity,
                new FixedTimeProvider(FixedUtc),
                new StateStoreRecoveryOptions(
                    new DelegateStateStoreRecoveryFaultInjector(context =>
                    {
                        if (context.Phase == StateStoreRecoveryPhase.AfterRestoreReplacement ||
                            context.Phase == StateStoreRecoveryPhase.AfterRestoreRollbackOperation)
                        {
                            File.Copy(changedPath, databasePath, overwrite: true);
                        }
                    }),
                    () => FixedToken)));

        StringAssert.Contains(exception.Message, "identity", StringComparison.OrdinalIgnoreCase);
        var stateFailures = exception.Data["HerdrOps.RecoveryRollbackStateFailures"] as string[];
        Assert.IsNotNull(stateFailures);
        Assert.IsTrue(stateFailures!.Any(value => value.Contains("restore-rollback-state", StringComparison.Ordinal)));
        Assert.AreEqual(
            StateStoreRecoveryArtifacts.IdentifyFile(changedPath).Sha256,
            StateStoreRecoveryArtifacts.IdentifyFile(databasePath).Sha256);
    }

    [TestMethod]
    public void RollbackCleanupFailurePreservesPrimaryAndRecordsEveryFailureContext()
    {
        using var directory = new TemporaryDirectory();
        var sourcePath = Path.Combine(directory.Path, "rollback-cleanup-source.db");
        var changedPath = Path.Combine(directory.Path, "rollback-cleanup-changed.db");
        var databasePath = Path.Combine(directory.Path, "rollback-cleanup-absent.db");
        CreateLegacyDatabase(sourcePath, "source");
        CreateLegacyDatabase(changedPath, "changed");
        Directory.CreateDirectory(Path.Combine(directory.Path, "backups"));
        var backupPath = Path.Combine(directory.Path, "backups", "rollback-cleanup-absent.bak");
        File.Copy(sourcePath, backupPath);
        var backupIdentity = StateStoreRecoveryArtifacts.IdentifyFile(backupPath);

        var exception = Assert.Throws<HerdrStateStoreException>(() =>
            StateStoreRecoveryArtifacts.RestoreBackup(
                databasePath,
                backupPath,
                backupIdentity.Sha256,
                expectedDestinationIdentity: null,
                new FixedTimeProvider(FixedUtc),
                new StateStoreRecoveryOptions(
                    new DelegateStateStoreRecoveryFaultInjector(context =>
                    {
                        if (context.Phase == StateStoreRecoveryPhase.AfterRestoreReplacement)
                        {
                            File.Copy(changedPath, databasePath, overwrite: true);
                        }
                    }),
                    () => FixedToken,
                    new ThrowingRecoveryCleanup())));

        StringAssert.Contains(exception.Message, "identity", StringComparison.OrdinalIgnoreCase);
        var cleanupFailures = exception.Data["HerdrOps.RecoveryCleanupFailures"] as string[];
        Assert.IsNotNull(cleanupFailures);
        Assert.IsTrue(cleanupFailures!.Any(value => value.Contains("restore-rollback-operation", StringComparison.Ordinal)));
        var stateFailures = exception.Data["HerdrOps.RecoveryRollbackStateFailures"] as string[];
        Assert.IsNotNull(stateFailures);
        Assert.IsTrue(stateFailures!.Any(value => value.Contains("restore-rollback-state", StringComparison.Ordinal)));
        Assert.IsTrue(File.Exists(databasePath));
    }

    [TestMethod]
    public void BackupCollisionCleanupFailurePreservesCollisionPrimary()
    {
        using var directory = new TemporaryDirectory();
        var databasePath = Path.Combine(directory.Path, "backup-collision.db");
        CreateLegacyDatabase(databasePath, "backup-collision");
        using var source = OpenDatabase(databasePath, SqliteOpenMode.ReadWrite);
        var options = new StateStoreRecoveryOptions(
            new DelegateStateStoreRecoveryFaultInjector(context =>
            {
                if (context.Phase == StateStoreRecoveryPhase.AfterBackupTemporaryCreated)
                {
                    var temporaryName = Path.GetFileName(context.ArtifactPath!)!;
                    var baseName = temporaryName[1..^4];
                    File.WriteAllText(
                        Path.Combine(Path.GetDirectoryName(context.ArtifactPath!)!, baseName + ".bak"),
                        "preserve-collision");
                }
            }),
            () => FixedToken,
            new ThrowingRecoveryCleanup());

        var exception = Assert.Throws<IOException>(() =>
            StateStoreRecoveryArtifacts.CreateBackup(
                source,
                databasePath,
                fromVersion: 0,
                toVersion: HerdrStateStoreOptions.CurrentSchemaVersion,
                timeProvider: new FixedTimeProvider(FixedUtc),
                recoveryOptions: options));

        StringAssert.Contains(exception.Message, "collision", StringComparison.OrdinalIgnoreCase);
        var cleanupFailures = exception.Data["HerdrOps.RecoveryCleanupFailures"] as string[];
        Assert.IsNotNull(cleanupFailures);
        Assert.IsTrue(cleanupFailures!.Any(value => value.Contains("backup-collision-cleanup", StringComparison.Ordinal)));
        Assert.HasCount(
            1,
            Directory.GetFiles(Path.Combine(directory.Path, "backups"), "*.tmp"));
    }

    [TestMethod]
    public void TraceCollisionCleanupFailurePreservesCollisionPrimary()
    {
        using var directory = new TemporaryDirectory();
        var databasePath = Path.Combine(directory.Path, "trace-collision.db");
        CreateLegacyDatabase(databasePath, "trace-collision");
        using var source = OpenDatabase(databasePath, SqliteOpenMode.ReadWrite);
        var options = new StateStoreRecoveryOptions(
            new DelegateStateStoreRecoveryFaultInjector(context =>
            {
                if (context.Phase == StateStoreRecoveryPhase.AfterTraceTemporaryCreated)
                {
                    var temporaryName = Path.GetFileName(context.ArtifactPath!)!;
                    var baseName = temporaryName[1..^4];
                    File.WriteAllText(
                        Path.Combine(Path.GetDirectoryName(context.ArtifactPath!)!, baseName + ".json"),
                        "preserve-trace-collision");
                }
            }),
            () => FixedToken,
            new ThrowingRecoveryCleanup());

        var exception = Assert.Throws<IOException>(() =>
            StateStoreRecoveryArtifacts.CreateBackup(
                source,
                databasePath,
                fromVersion: 0,
                toVersion: HerdrStateStoreOptions.CurrentSchemaVersion,
                timeProvider: new FixedTimeProvider(FixedUtc),
                recoveryOptions: options));

        StringAssert.Contains(exception.Message, "trace", StringComparison.OrdinalIgnoreCase);
        var cleanupFailures = exception.Data["HerdrOps.RecoveryCleanupFailures"] as string[];
        Assert.IsNotNull(cleanupFailures);
        Assert.IsTrue(cleanupFailures!.Any(value => value.Contains("trace-temporary-cleanup", StringComparison.Ordinal)));
    }

    [TestMethod]
    public void QuarantineCollisionCleanupFailurePreservesCollisionPrimary()
    {
        using var directory = new TemporaryDirectory();
        var databasePath = Path.Combine(directory.Path, "quarantine-collision-cleanup.db");
        File.WriteAllText(databasePath, "damaged-quarantine-collision");
        var options = new StateStoreRecoveryOptions(
            new DelegateStateStoreRecoveryFaultInjector(context =>
            {
                if (context.Phase == StateStoreRecoveryPhase.BeforeQuarantineMove)
                {
                    Directory.CreateDirectory(context.ArtifactPath!);
                    File.WriteAllText(
                        Path.Combine(context.ArtifactPath!, "keep.txt"),
                        "preserve-quarantine-collision");
                }
            }),
            () => FixedToken,
            new ThrowingRecoveryCleanup());

        var exception = Assert.Throws<IOException>(() =>
            StateStoreRecoveryArtifacts.Quarantine(
                databasePath,
                new InvalidOperationException("primary quarantine failure"),
                schemaVersion: null,
                phase: "test",
                timeProvider: new FixedTimeProvider(FixedUtc),
                recoveryOptions: options));

        StringAssert.Contains(exception.Message, "collision", StringComparison.OrdinalIgnoreCase);
        var cleanupFailures = exception.Data["HerdrOps.RecoveryCleanupFailures"] as string[];
        Assert.IsNotNull(cleanupFailures);
        Assert.IsTrue(cleanupFailures!.Any(value => value.Contains("quarantine-collision-cleanup", StringComparison.Ordinal)));
        var collisionPath = StateStoreRecoveryArtifacts.GetQuarantineCandidatePathForTesting(
            databasePath,
            FixedUtc,
            FixedToken,
            attempt: 0);
        Assert.AreEqual(
            "preserve-quarantine-collision",
            File.ReadAllText(Path.Combine(collisionPath, "keep.txt")));
    }

    [TestMethod]
    public void DanglingLeafReparsePointIsRejectedEvenWhenFileExistsIsFalse()
    {
        if (!OperatingSystem.IsWindows())
        {
            Assert.Inconclusive("The recovery target is Windows.");
        }

        using var directory = new TemporaryDirectory();
        var danglingPath = Path.Combine(directory.Path, "dangling-directory");
        try
        {
            _ = Directory.CreateSymbolicLink(danglingPath, Path.Combine(directory.Path, "missing-target"));
        }
        catch (Exception exception) when (
            exception is UnauthorizedAccessException or IOException or PlatformNotSupportedException)
        {
            Assert.Inconclusive($"Symbolic-link creation is unavailable on this Windows host: {exception.GetType().Name}");
        }

        Assert.IsFalse(File.Exists(danglingPath));
        Assert.Throws<HerdrStateStoreException>(() =>
            StateStoreRecoveryPathPolicy.EnsureNoReparseComponents(danglingPath, includeLeaf: true));
    }

    [TestMethod]
    public void StateStoreRejectsReparseOwnershipLockBeforeOpeningIt()
    {
        if (!OperatingSystem.IsWindows())
        {
            Assert.Inconclusive("The recovery target is Windows.");
        }

        using var directory = new TemporaryDirectory();
        var databasePath = Path.Combine(directory.Path, "store-lock-reparse.db");
        var outsideLockPath = Path.Combine(directory.Path, "store-outside.lock");
        CreateLegacyDatabase(databasePath, "store-lock-reparse");
        File.WriteAllText(outsideLockPath, "outside-lock");

        var lockPath = databasePath + ".core.lock";
        try
        {
            _ = File.CreateSymbolicLink(lockPath, outsideLockPath);
        }
        catch (Exception exception) when (
            exception is UnauthorizedAccessException or IOException or PlatformNotSupportedException)
        {
            Assert.Inconclusive($"Symbolic-link creation is unavailable on this Windows host: {exception.GetType().Name}");
        }

        try
        {
            Assert.Throws<HerdrStateStoreException>(() =>
                new SqliteHerdrStateStore(new HerdrStateStoreOptions(databasePath)));
            Assert.AreEqual("outside-lock", File.ReadAllText(outsideLockPath));
        }
        finally
        {
            File.Delete(lockPath);
        }
    }

    [TestMethod]
    public void StoreConstructorRejectsDanglingDatabaseLeafAfterAcquiringAndReleasesLock()
    {
        if (!OperatingSystem.IsWindows())
        {
            Assert.Inconclusive("The recovery target is Windows.");
        }

        using var directory = new TemporaryDirectory();
        var databasePath = Path.Combine(directory.Path, "dangling-store.db");
        var missingTargetPath = Path.Combine(directory.Path, "missing-target.db");
        try
        {
            _ = Directory.CreateSymbolicLink(databasePath, missingTargetPath);
        }
        catch (Exception exception) when (
            exception is UnauthorizedAccessException or IOException or PlatformNotSupportedException)
        {
            Assert.Inconclusive($"Symbolic-link creation is unavailable on this Windows host: {exception.GetType().Name}");
        }

        try
        {
            Assert.IsFalse(File.Exists(databasePath));
            Assert.Throws<HerdrStateStoreException>(() =>
                new SqliteHerdrStateStore(new HerdrStateStoreOptions(databasePath)));

            AssertLockReleased(databasePath);
            Assert.IsFalse(File.Exists(missingTargetPath));
        }
        finally
        {
            Directory.Delete(databasePath);
        }
    }

    [TestMethod]
    public void StoreConstructorRejectsDatabaseAppearanceAtPostLockAdmissionBoundary()
    {
        using var directory = new TemporaryDirectory();
        var databasePath = Path.Combine(directory.Path, "appeared-store.db");
        var options = new StateStoreRecoveryOptions(
            new DelegateStateStoreRecoveryFaultInjector(context =>
            {
                if (context.Phase == StateStoreRecoveryPhase.AfterDatabaseLeafInspection)
                {
                    CreateLegacyDatabase(databasePath, "appeared-after-probe");
                }
            }),
            () => FixedToken);

        var exception = Assert.Throws<HerdrStateStoreException>(() =>
            new SqliteHerdrStateStore(
                new HerdrStateStoreOptions(databasePath),
                new FixedTimeProvider(FixedUtc),
                options));

        StringAssert.Contains(exception.Message, "identity", StringComparison.OrdinalIgnoreCase);
        Assert.AreEqual(0L, ReadUserVersion(databasePath));
        AssertLockReleased(databasePath);
    }

    [TestMethod]
    public void StoreConstructorRejectsDatabaseChangeAtPostLockAdmissionBoundary()
    {
        using var directory = new TemporaryDirectory();
        var databasePath = Path.Combine(directory.Path, "changed-store.db");
        var changedPath = Path.Combine(directory.Path, "changed-source.db");
        CreateLegacyDatabase(databasePath, "original-before-probe");
        CreateLegacyDatabase(changedPath, "changed-after-probe");
        var originalIdentity = StateStoreRecoveryArtifacts.IdentifyFile(databasePath);
        var options = new StateStoreRecoveryOptions(
            new DelegateStateStoreRecoveryFaultInjector(context =>
            {
                if (context.Phase == StateStoreRecoveryPhase.AfterDatabaseLeafInspection)
                {
                    File.Copy(changedPath, databasePath, overwrite: true);
                }
            }),
            () => FixedToken);

        var exception = Assert.Throws<HerdrStateStoreException>(() =>
            new SqliteHerdrStateStore(
                new HerdrStateStoreOptions(databasePath),
                new FixedTimeProvider(FixedUtc),
                options));

        StringAssert.Contains(exception.Message, "identity", StringComparison.OrdinalIgnoreCase);
        Assert.AreNotEqual(originalIdentity.Sha256, StateStoreRecoveryArtifacts.IdentifyFile(databasePath).Sha256);
        Assert.AreEqual(0L, ReadUserVersion(databasePath));
        AssertLockReleased(databasePath);
    }

    [TestMethod]
    public void DamagedDatabaseIsQuarantinedWithoutSilentReset()
    {
        using var directory = new TemporaryDirectory();
        var databasePath = Path.Combine(directory.Path, "damaged.db");
        var damagedBytes = Encoding.UTF8.GetBytes("not-a-sqlite-database");
        File.WriteAllBytes(databasePath, damagedBytes);

        var exception = Assert.Throws<HerdrStateStoreException>(() =>
            new SqliteHerdrStateStore(new HerdrStateStoreOptions(databasePath)));

        CollectionAssert.AreEqual(damagedBytes, File.ReadAllBytes(databasePath));
        Assert.IsFalse(
            File.ReadAllBytes(databasePath)
                .AsSpan()
                .StartsWith(Encoding.ASCII.GetBytes("SQLite format 3\0")));

        var quarantineRoot = Path.Combine(directory.Path, "quarantine");
        var quarantinePath = Directory.GetDirectories(quarantineRoot).Single();
        var quarantinedPrimary = Path.Combine(quarantinePath, "damaged.db");
        CollectionAssert.AreEqual(damagedBytes, File.ReadAllBytes(quarantinedPrimary));
        Assert.IsTrue(File.Exists(Path.Combine(quarantinePath, "metadata.json")));
        Assert.IsTrue(File.Exists(Path.Combine(quarantinePath, "recovery-trace.json")));
        StringAssert.Contains(exception.Message, "not a SQLite database", StringComparison.Ordinal);
        Assert.IsFalse(exception.Message.Contains(databasePath, StringComparison.Ordinal));
    }

    [TestMethod]
    public void QuarantineCollisionDoesNotOverwritePriorQuarantine()
    {
        using var directory = new TemporaryDirectory();
        var databasePath = Path.Combine(directory.Path, "collision.db");
        var damagedBytes = Encoding.UTF8.GetBytes("damaged-collision");
        File.WriteAllBytes(databasePath, damagedBytes);

        var quarantineRoot = Path.Combine(directory.Path, "quarantine");
        Directory.CreateDirectory(quarantineRoot);
        var collidingPath = StateStoreRecoveryArtifacts.GetQuarantineCandidatePathForTesting(
            databasePath,
            FixedUtc,
            FixedToken,
            attempt: 0);
        Directory.CreateDirectory(collidingPath);
        var markerPath = Path.Combine(collidingPath, "do-not-overwrite.txt");
        File.WriteAllText(markerPath, "keep-this-quarantine");

        Assert.Throws<HerdrStateStoreException>(() =>
            new SqliteHerdrStateStore(
                new HerdrStateStoreOptions(databasePath),
                new FixedTimeProvider(FixedUtc),
                new StateStoreRecoveryOptions(GuidFactory: () => FixedToken)));

        Assert.AreEqual("keep-this-quarantine", File.ReadAllText(markerPath));
        var quarantineDirectories = Directory.GetDirectories(
            quarantineRoot,
            "collision.db.corrupt.*");
        Assert.HasCount(2, quarantineDirectories);
        Assert.IsTrue(
            File.Exists(Path.Combine(
                quarantineRoot,
                "collision.db.corrupt.20260817T010203000Z.11111111222233334444555555555555.01",
                "collision.db")));
    }

    [TestMethod]
    public void ExistingEmptyDatabaseIsRejectedAndQuarantinedInsteadOfInitialized()
    {
        using var directory = new TemporaryDirectory();
        var databasePath = Path.Combine(directory.Path, "empty.db");
        File.WriteAllBytes(databasePath, Array.Empty<byte>());

        Assert.Throws<HerdrStateStoreException>(() =>
            new SqliteHerdrStateStore(new HerdrStateStoreOptions(databasePath)));

        Assert.AreEqual(0L, new FileInfo(databasePath).Length);
        var quarantinePrimary = Directory.GetFiles(
                Directory.GetDirectories(Path.Combine(directory.Path, "quarantine")).Single(),
                "empty.db")
            .Single();
        Assert.AreEqual(0L, new FileInfo(quarantinePrimary).Length);
    }

    [TestMethod]
    public void TraversalDatabasePathIsRejectedBeforeFileOperations()
    {
        using var directory = new TemporaryDirectory();
        var traversalPath = Path.Combine(directory.Path, "..", "escaped.db");

        Assert.Throws<ArgumentException>(() =>
            new SqliteHerdrStateStore(new HerdrStateStoreOptions(traversalPath)));
        Assert.IsFalse(File.Exists(Path.Combine(directory.Path, "escaped.db")));
    }

    [TestMethod]
    public void RecoveryTraceAndQuarantineMetadataTokenizePathsAndRedactFailureMessages()
    {
        using var directory = new TemporaryDirectory();
        var databasePath = Path.Combine(directory.Path, "sensitive-state.db");
        File.WriteAllText(databasePath, "damaged");
        const string apiSecret = "recovery-api-secret";
        const string bearerSecret = "recovery-bearer-secret";
        var failure = new InvalidOperationException(
            $"API key is {apiSecret}; Authorization: Bearer {bearerSecret}; path={databasePath}");

        var quarantinePath = StateStoreRecoveryArtifacts.Quarantine(
            databasePath,
            failure,
            schemaVersion: null,
            phase: "initialization-validation",
            timeProvider: new FixedTimeProvider(FixedUtc),
            recoveryOptions: new StateStoreRecoveryOptions(GuidFactory: () => FixedToken));
        var files = Directory.GetFiles(quarantinePath, "*.json");

        foreach (var file in files)
        {
            var text = File.ReadAllText(file);
            Assert.IsFalse(text.Contains(databasePath, StringComparison.Ordinal), file);
            Assert.IsFalse(text.Contains(apiSecret, StringComparison.Ordinal), file);
            Assert.IsFalse(text.Contains(bearerSecret, StringComparison.Ordinal), file);
            Assert.IsFalse(text.Contains("Authorization: Bearer", StringComparison.Ordinal), file);
        }

        var metadata = File.ReadAllText(Path.Combine(quarantinePath, "metadata.json"));
        StringAssert.Contains(metadata, "DatabasePathToken");
        Assert.IsFalse(metadata.Contains("OriginalDatabasePath", StringComparison.Ordinal));
    }

    /// <summary>
    /// P1 — Apostrophe-path recovery-layer coverage (Issue #37 independent-review finding).
    ///
    /// Commit b6320c92 fixed apostrophe-in-path mis-termination in DiagnosticRedaction.cs and
    /// tested it via DiagnosticBundleTests.  This test closes the remaining gap by exercising
    /// StateStoreRecoveryArtifacts.Quarantine with a database path whose directory component
    /// contains a literal apostrophe (U+0027), verifying that:
    ///   1. recovery-trace.json and metadata.json do not contain the raw apostrophe-bearing path.
    ///   2. The failure message embedded in the trace does not expose the raw apostrophe-bearing path.
    ///   3. metadata.json carries a DatabasePathToken field (hash-based token, not the real path).
    ///   4. recovery-trace.json carries EvidenceClasses, ActualHerdrRuntime: NOT_OBSERVED, and
    ///      Release: NOT_OBSERVED as required by the recovery-trace contract.
    ///
    /// Evidence class: Synthetic (in-process file I/O; no Herdr runtime).
    /// </summary>
    [TestMethod]
    public void QuarantineWithApostrophePathDirectoryTokenizesAndRedactsSafely()
    {
        using var directory = new TemporaryDirectory();

        // Create a sub-directory whose name contains a literal apostrophe, matching
        // the class of path that commit b6320c92 was designed to handle safely
        // (e.g. C:\Users\O'Brien\AppData\Local\HerdrOps\state.db).
        var apostropheSubDir = Path.Combine(directory.Path, "O'Brien");
        Directory.CreateDirectory(apostropheSubDir);
        var databasePath = Path.Combine(apostropheSubDir, "state.db");
        File.WriteAllText(databasePath, "damaged");

        // Embed the raw apostrophe-bearing path into the failure message so the
        // redactor's quoted-path boundary logic is exercised end-to-end through
        // StateStoreRecoveryDiagnostics.SanitizeMessage -> DiagnosticTextRedactor.
        var failure = new InvalidOperationException(
            $"State-store integrity check failed; path='{databasePath}'; hint=see-diagnostics");

        var quarantinePath = StateStoreRecoveryArtifacts.Quarantine(
            databasePath,
            failure,
            schemaVersion: null,
            phase: "initialization-validation",
            timeProvider: new FixedTimeProvider(FixedUtc),
            recoveryOptions: new StateStoreRecoveryOptions(GuidFactory: () => FixedToken));

        // 1 & 2: Neither JSON artifact may expose the raw apostrophe-bearing path.
        var jsonFiles = Directory.GetFiles(quarantinePath, "*.json");
        Assert.IsGreaterThanOrEqualTo(2, jsonFiles.Length, "Expected at least metadata.json and recovery-trace.json");
        foreach (var file in jsonFiles)
        {
            var text = File.ReadAllText(file);
            Assert.IsFalse(
                text.Contains(databasePath, StringComparison.Ordinal),
                $"Raw apostrophe-bearing database path leaked into {Path.GetFileName(file)}");
            Assert.IsFalse(
                text.Contains(apostropheSubDir, StringComparison.Ordinal),
                $"Raw apostrophe-bearing sub-directory leaked into {Path.GetFileName(file)}");
            Assert.IsFalse(
                text.Contains("O'Brien", StringComparison.Ordinal),
                $"Apostrophe-bearing path component leaked into {Path.GetFileName(file)}");
        }

        // 3: metadata.json must carry a DatabasePathToken (hash), not the original path.
        var metadataText = File.ReadAllText(Path.Combine(quarantinePath, "metadata.json"));
        StringAssert.Contains(metadataText, "DatabasePathToken");
        Assert.IsFalse(metadataText.Contains("OriginalDatabasePath", StringComparison.Ordinal));

        // 4: recovery-trace.json must satisfy the evidence-class / runtime-status contract.
        using var traceDoc = System.Text.Json.JsonDocument.Parse(
            File.ReadAllBytes(Path.Combine(quarantinePath, "recovery-trace.json")));
        var root = traceDoc.RootElement;
        CollectionAssert.AreEquivalent(
            new[] { "Static", "Synthetic", "Contract" },
            root.GetProperty("EvidenceClasses").EnumerateArray()
                .Select(e => e.GetString()!)
                .ToArray());
        Assert.AreEqual("NOT_OBSERVED", root.GetProperty("ActualHerdrRuntime").GetString());
        Assert.AreEqual("NOT_OBSERVED", root.GetProperty("Release").GetString());
    }

    [TestMethod]
    public void CleanupFailurePreservesPrimaryExceptionAndRetainsTemporaryEvidence()
    {
        using var directory = new TemporaryDirectory();
        var databasePath = Path.Combine(directory.Path, "cleanup-failure.db");
        CreateLegacyDatabase(databasePath, "cleanup-failure");
        using var source = new SqliteConnection(new SqliteConnectionStringBuilder
        {
            DataSource = databasePath,
            Mode = SqliteOpenMode.ReadWrite,
            Pooling = false,
        }.ToString());
        source.Open();

        var options = new StateStoreRecoveryOptions(
            new DelegateStateStoreRecoveryFaultInjector(context =>
            {
                if (context.Phase == StateStoreRecoveryPhase.AfterBackupTemporaryCreated)
                {
                    throw new StateStoreRecoveryInterruptionException(context);
                }
            }),
            () => FixedToken,
            new ThrowingRecoveryCleanup());

        var exception = Assert.Throws<StateStoreRecoveryInterruptionException>(() =>
            StateStoreRecoveryArtifacts.CreateBackup(
                source,
                databasePath,
                fromVersion: 0,
                toVersion: HerdrStateStoreOptions.CurrentSchemaVersion,
                timeProvider: new FixedTimeProvider(FixedUtc),
                recoveryOptions: options));

        Assert.IsNotNull(exception.Data["HerdrOps.RecoveryCleanupFailure"]);
        Assert.IsNotNull(exception.Data["HerdrOps.RecoveryCleanupEvidence"]);
        var temporaryArtifacts = Directory.GetFiles(
            Path.Combine(directory.Path, "backups"),
            "*.tmp");
        Assert.HasCount(1, temporaryArtifacts);
        Assert.IsTrue(File.Exists(temporaryArtifacts[0]));
    }

    private static StateStoreRecoveryOptions CreateRecoveryOptions(
        StateStoreRecoveryPhase phase) =>
        new(
            new DelegateStateStoreRecoveryFaultInjector(context =>
            {
                if (context.Phase == phase)
                {
                    throw new StateStoreRecoveryInterruptionException(context);
                }
            }),
            () => FixedToken);

    private static SqliteConnection OpenDatabase(string path, SqliteOpenMode mode)
    {
        var connection = new SqliteConnection(new SqliteConnectionStringBuilder
        {
            DataSource = path,
            Mode = mode,
            Pooling = false,
        }.ToString());
        connection.Open();
        return connection;
    }

    private static void CreateLegacyDatabase(string path, string value)
    {
        using var connection = new SqliteConnection(new SqliteConnectionStringBuilder
        {
            DataSource = path,
            Mode = SqliteOpenMode.ReadWriteCreate,
            Pooling = false,
        }.ToString());
        connection.Open();
        using var command = connection.CreateCommand();
        command.CommandText = """
            CREATE TABLE legacy_sentinel(value TEXT NOT NULL);
            INSERT INTO legacy_sentinel(value) VALUES ($value);
            PRAGMA user_version = 0;
            """;
        command.Parameters.AddWithValue("$value", value);
        command.ExecuteNonQuery();
    }

    private static long ReadUserVersion(string path) =>
        ReadLongScalar(path, "PRAGMA user_version;");

    private static long ReadLongScalar(string path, string sql) =>
        Convert.ToInt64(ReadScalarObject(path, sql));

    private static string ReadTextScalar(string path, string sql) =>
        Convert.ToString(ReadScalarObject(path, sql))!;

    private static void AssertLockReleased(string databasePath)
    {
        var lockPath = databasePath + ".core.lock";
        using var stream = new FileStream(
            lockPath,
            FileMode.OpenOrCreate,
            FileAccess.ReadWrite,
            FileShare.None,
            bufferSize: 1,
            FileOptions.None);
    }

    private static object ReadScalarObject(string path, string sql)
    {
        using var connection = new SqliteConnection(new SqliteConnectionStringBuilder
        {
            DataSource = path,
            Mode = SqliteOpenMode.ReadOnly,
            Pooling = false,
        }.ToString());
        connection.Open();
        using var command = connection.CreateCommand();
        command.CommandText = sql;
        return command.ExecuteScalar()!;
    }

    private sealed class ThrowingRecoveryCleanup : IStateStoreRecoveryCleanup
    {
        public void DeleteFile(string path) =>
            throw new IOException("synthetic cleanup failure");

        public void DeleteDirectoryTree(string path) =>
            throw new IOException("synthetic cleanup failure");
    }
}
