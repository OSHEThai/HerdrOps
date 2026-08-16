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
        var restored = StateStoreRecoveryArtifacts.RestoreBackup(
            databasePath,
            backupPath,
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
