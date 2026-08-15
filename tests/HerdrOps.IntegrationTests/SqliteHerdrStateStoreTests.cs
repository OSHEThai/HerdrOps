using HerdrOps.Infrastructure.Storage;
using Microsoft.Data.Sqlite;

namespace HerdrOps.IntegrationTests;

[TestClass]
public sealed class SqliteHerdrStateStoreTests
{
    [TestMethod]
    public void WalStoreSurvivesRestartWithExactAcceptedState()
    {
        using var directory = new TemporaryDirectory();
        var databasePath = Path.Combine(directory.Path, "state", "herdrops.db");
        var options = new HerdrStateStoreOptions(databasePath);
        var first = HerdrStateTestData.CreateState(sequence: 1);
        var second = HerdrStateTestData.CreateState(sequence: 2, status: "Idle", revision: 2);
        string acceptedHash;

        using (var store = new SqliteHerdrStateStore(options))
        {
            var write = store.Commit(HerdrStateTestData.Commit(first));
            Assert.IsFalse(write.WasAlreadyPresent);
            acceptedHash = write.StoredState.StateSha256;
            var diagnostics = store.GetDiagnostics();
            Assert.AreEqual(2, diagnostics.SchemaVersion);
            Assert.AreEqual("wal", diagnostics.JournalMode, ignoreCase: true);
            Assert.AreEqual(2, diagnostics.SynchronousMode);
            Assert.IsTrue(diagnostics.ForeignKeysEnabled);
            Assert.AreEqual("ok", diagnostics.IntegrityResult, ignoreCase: true);
            Assert.AreEqual(1, diagnostics.EventCount);
        }

        using (var restarted = new SqliteHerdrStateStore(options))
        {
            var restored = restarted.ReadCurrent();
            Assert.IsNotNull(restored);
            Assert.AreEqual(1, restored.State.LastIngestSequence);
            Assert.AreEqual(acceptedHash, restored.StateSha256);
            Assert.AreEqual("Working", restored.State.Agents[0].AgentStatus);

            restarted.Commit(HerdrStateTestData.Commit(second));
            Assert.AreEqual(2, restarted.ReadCurrent()!.State.LastIngestSequence);
            Assert.AreEqual(2, restarted.GetDiagnostics().EventCount);
        }

        using var finalRestart = new SqliteHerdrStateStore(options);
        var final = finalRestart.ReadCurrent();
        Assert.IsNotNull(final);
        Assert.AreEqual(2, final.State.LastIngestSequence);
        Assert.AreEqual("Idle", final.State.Agents[0].AgentStatus);
        Assert.AreEqual((ulong)2, final.State.Panes[0].Revision);
    }

    [TestMethod]
    public void StoreRejectsSequenceGapWithoutChangingAcceptedState()
    {
        using var directory = new TemporaryDirectory();
        var options = new HerdrStateStoreOptions(Path.Combine(directory.Path, "herdrops.db"));
        using var store = new SqliteHerdrStateStore(options);
        var accepted = HerdrStateTestData.CreateState(sequence: 1);
        store.Commit(HerdrStateTestData.Commit(accepted));

        Assert.Throws<HerdrStateStoreException>(() =>
            store.Commit(HerdrStateTestData.Commit(
                HerdrStateTestData.CreateState(sequence: 3, status: "Blocked", revision: 3))));

        var current = store.ReadCurrent();
        Assert.IsNotNull(current);
        Assert.AreEqual(1, current.State.LastIngestSequence);
        Assert.AreEqual("Working", current.State.Agents[0].AgentStatus);
        Assert.AreEqual(1, store.GetDiagnostics().EventCount);
    }

    [TestMethod]
    public void ExistingVersionZeroDatabaseIsBackedUpBeforeMigration()
    {
        using var directory = new TemporaryDirectory();
        var databasePath = Path.Combine(directory.Path, "herdrops.db");
        using (var legacy = Open(databasePath))
        {
            using var command = legacy.CreateCommand();
            command.CommandText = """
                CREATE TABLE legacy_sentinel(value TEXT NOT NULL);
                INSERT INTO legacy_sentinel(value) VALUES ('preserve-me');
                PRAGMA user_version = 0;
                """;
            command.ExecuteNonQuery();
        }

        string backupPath;
        using (var migrated = new SqliteHerdrStateStore(new HerdrStateStoreOptions(databasePath)))
        {
            backupPath = migrated.LastBackupPath!;
            Assert.IsFalse(string.IsNullOrWhiteSpace(backupPath));
            Assert.IsTrue(File.Exists(backupPath));
            Assert.AreEqual(2, migrated.GetDiagnostics().SchemaVersion);
        }

        using (var backup = Open(backupPath))
        {
            using var command = backup.CreateCommand();
            command.CommandText = "SELECT value FROM legacy_sentinel;";
            Assert.AreEqual("preserve-me", command.ExecuteScalar());
            command.CommandText = "PRAGMA user_version;";
            Assert.AreEqual(0L, Convert.ToInt64(command.ExecuteScalar()));
        }

        using var reopened = new SqliteHerdrStateStore(new HerdrStateStoreOptions(databasePath));
        Assert.IsNull(reopened.LastBackupPath, "An already-current database must not be backed up again.");
    }

    [TestMethod]
    public void VersionOneDatabaseMigratesForwardWithoutLosingHistory()
    {
        using var directory = new TemporaryDirectory();
        var databasePath = Path.Combine(directory.Path, "herdrops-v1.db");
        var versionOne = SqliteHerdrStateStore.GetMigrationForTesting(1);
        using (var legacy = Open(databasePath))
        {
            using (var migration = legacy.CreateCommand())
            {
                migration.CommandText = versionOne.Sql;
                migration.ExecuteNonQuery();
            }

            using (var history = legacy.CreateCommand())
            {
                history.CommandText = """
                    INSERT INTO schema_migrations(version, name, applied_utc, script_sha256)
                    VALUES (1, $name, '2026-08-15T00:00:00.0000000+00:00', $hash);
                    PRAGMA user_version = 1;
                    """;
                history.Parameters.AddWithValue("$name", versionOne.Name);
                history.Parameters.AddWithValue("$hash", versionOne.ScriptSha256);
                history.ExecuteNonQuery();
            }

            using var legacyEvent = legacy.CreateCommand();
            legacyEvent.CommandText = """
                INSERT INTO state_events(
                    sequence, connection_epoch, observed_utc, ingested_utc,
                    source, event_type, correlation_id, state_sha256,
                    payload_json, payload_sha256)
                VALUES (
                    1, 1, '2026-08-15T00:00:00.0000000+00:00',
                    '2026-08-15T00:00:01.0000000+00:00', 'v1-test', 'snapshot',
                    '00000000-0000-0000-0000-000000000001', $stateHash,
                    '{}', $payloadHash);
                """;
            legacyEvent.Parameters.AddWithValue("$stateHash", new string('A', 64));
            legacyEvent.Parameters.AddWithValue("$payloadHash", new string('B', 64));
            legacyEvent.ExecuteNonQuery();
        }

        string backupPath;
        using (var migrated = new SqliteHerdrStateStore(
                   new HerdrStateStoreOptions(databasePath)))
        {
            backupPath = migrated.LastBackupPath!;
            Assert.IsTrue(File.Exists(backupPath));
            var diagnostics = migrated.GetDiagnostics();
            Assert.AreEqual(2, diagnostics.SchemaVersion);
            Assert.AreEqual(1L, diagnostics.EventCount);
            Assert.AreEqual(0L, diagnostics.LifecycleEventCount);
        }

        using (var current = Open(databasePath))
        {
            using var command = current.CreateCommand();
            command.CommandText = "SELECT COUNT(*) FROM schema_migrations;";
            Assert.AreEqual(2L, Convert.ToInt64(command.ExecuteScalar()));
            command.CommandText = "SELECT script_sha256 FROM schema_migrations WHERE version = 1;";
            Assert.AreEqual(versionOne.ScriptSha256, command.ExecuteScalar());
            command.CommandText = "SELECT source FROM state_events WHERE sequence = 1;";
            Assert.AreEqual("v1-test", command.ExecuteScalar());
            command.CommandText = "SELECT COUNT(*) FROM assignment_lifecycle_events;";
            Assert.AreEqual(0L, Convert.ToInt64(command.ExecuteScalar()));
        }

        using var backup = Open(backupPath);
        using var backupCommand = backup.CreateCommand();
        backupCommand.CommandText = "PRAGMA user_version;";
        Assert.AreEqual(1L, Convert.ToInt64(backupCommand.ExecuteScalar()));
        backupCommand.CommandText =
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'assignment_lifecycle_events';";
        Assert.AreEqual(0L, Convert.ToInt64(backupCommand.ExecuteScalar()));
        backupCommand.CommandText = "SELECT source FROM state_events WHERE sequence = 1;";
        Assert.AreEqual("v1-test", backupCommand.ExecuteScalar());
    }

    [TestMethod]
    public void FutureSchemaFailsClosedWithoutMigration()
    {
        using var directory = new TemporaryDirectory();
        var databasePath = Path.Combine(directory.Path, "future.db");
        using (var future = Open(databasePath))
        {
            using var command = future.CreateCommand();
            command.CommandText = "PRAGMA user_version = 3;";
            command.ExecuteNonQuery();
        }

        var exception = Assert.Throws<HerdrStateStoreException>(() =>
            new SqliteHerdrStateStore(new HerdrStateStoreOptions(databasePath)));
        StringAssert.Contains(exception.Message, "newer than supported", StringComparison.Ordinal);
    }

    [TestMethod]
    public void EventLedgerRejectsMutation()
    {
        using var directory = new TemporaryDirectory();
        var databasePath = Path.Combine(directory.Path, "herdrops.db");
        using var store = new SqliteHerdrStateStore(new HerdrStateStoreOptions(databasePath));
        store.Commit(HerdrStateTestData.Commit(HerdrStateTestData.CreateState(sequence: 1)));

        using var connection = Open(databasePath);
        using var command = connection.CreateCommand();
        command.CommandText = "UPDATE state_events SET source = 'tampered' WHERE sequence = 1;";
        var exception = Assert.Throws<SqliteException>(() => command.ExecuteNonQuery());
        StringAssert.Contains(exception.Message, "append-only", StringComparison.OrdinalIgnoreCase);
    }

    [TestMethod]
    public void SecondCoreStoreInstanceFailsUntilOwnerDisposes()
    {
        using var directory = new TemporaryDirectory();
        var options = new HerdrStateStoreOptions(Path.Combine(directory.Path, "herdrops.db"));
        var first = new SqliteHerdrStateStore(options);
        try
        {
            var exception = Assert.Throws<HerdrStateStoreException>(() =>
                new SqliteHerdrStateStore(options));
            StringAssert.Contains(exception.Message, "Another HerdrOps Core", StringComparison.Ordinal);
        }
        finally
        {
            first.Dispose();
        }

        using var successor = new SqliteHerdrStateStore(options);
        Assert.AreEqual(2, successor.GetDiagnostics().SchemaVersion);
    }

    private static SqliteConnection Open(string path)
    {
        var connection = new SqliteConnection(new SqliteConnectionStringBuilder
        {
            DataSource = path,
            Mode = SqliteOpenMode.ReadWriteCreate,
            Pooling = false,
        }.ToString());
        connection.Open();
        return connection;
    }
}
