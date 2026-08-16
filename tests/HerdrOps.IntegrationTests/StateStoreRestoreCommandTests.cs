using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using HerdrOps.Core;
using HerdrOps.Infrastructure.Storage;
using HerdrOps.Infrastructure.Storage.Recovery;
using Microsoft.Data.Sqlite;

namespace HerdrOps.IntegrationTests;

[TestClass]
public sealed class StateStoreRestoreCommandTests
{
    private static readonly DateTimeOffset FixedUtc =
        new(2026, 8, 17, 2, 3, 4, TimeSpan.Zero);

    private static readonly Guid FixedToken =
        Guid.Parse("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee");

    [TestMethod]
    public void CoreRestoreCommandReachesExplicitServiceWithSourceAndDestinationIdentity()
    {
        using var directory = TemporaryDirectory.Create();
        var databasePath = Path.Combine(directory.Path, "restore.db");
        CreateLegacyDatabase(databasePath, "restore-command");
        var originalBytes = File.ReadAllBytes(databasePath);
        var expectedDatabaseSha256 = Convert.ToHexString(SHA256.HashData(originalBytes));

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

        var expectedBackupBytes = File.ReadAllBytes(backupPath);
        var expectedBackupSha256 = Convert.ToHexString(SHA256.HashData(expectedBackupBytes));
        var output = new StringWriter();
        var error = new StringWriter();
        var exitCode = StateStoreRestoreCommand.Run(
            [
                "restore-state-store",
                "--database", databasePath,
                "--backup", backupPath,
                "--expected-backup-sha256", expectedBackupSha256,
                "--expected-database-sha256", expectedDatabaseSha256,
                "--confirm", StateStoreRestoreContract.ConfirmationPhrase,
            ],
            output,
            error,
            new FixedTimeProvider(FixedUtc));

        Assert.AreEqual(0, exitCode);
        Assert.AreEqual(string.Empty, error.ToString());
        CollectionAssert.AreEqual(expectedBackupBytes, File.ReadAllBytes(databasePath));
        using var report = JsonDocument.Parse(output.ToString());
        var root = report.RootElement;
        Assert.AreEqual(expectedBackupSha256, root.GetProperty("ExpectedBackupSha256").GetString());
        Assert.AreEqual(expectedBackupSha256, root.GetProperty("ObservedDatabaseSha256").GetString());
        Assert.AreEqual("NOT_OBSERVED", root.GetProperty("ActualHerdrRuntime").GetString());
        Assert.AreEqual("NOT_OBSERVED", root.GetProperty("Release").GetString());
        Assert.IsFalse(output.ToString().Contains(databasePath, StringComparison.Ordinal));
        Assert.IsFalse(output.ToString().Contains(backupPath, StringComparison.Ordinal));
    }

    [TestMethod]
    public void CoreRestoreCommandFailsClosedWithoutExactConfirmation()
    {
        using var directory = TemporaryDirectory.Create();
        var output = new StringWriter();
        var error = new StringWriter();

        var exitCode = StateStoreRestoreCommand.Run(
            [
                "restore-state-store",
                "--database", Path.Combine(directory.Path, "restore.db"),
                "--backup", Path.Combine(directory.Path, "backups", "restore.bak"),
                "--expected-backup-sha256", new string('A', 64),
                "--expected-database-sha256", StateStoreRestoreContract.AbsentDestinationIdentity,
                "--confirm", "RESTORE_STATE_STORE_WITHOUT_REVIEW",
            ],
            output,
            error);

        Assert.AreEqual(2, exitCode);
        StringAssert.Contains(error.ToString(), "confirmation", StringComparison.OrdinalIgnoreCase);
    }

    [TestMethod]
    public void RestoreRejectsOwnershipLockReparsePointBeforeOpeningIt()
    {
        if (!OperatingSystem.IsWindows())
        {
            Assert.Inconclusive("The recovery target is Windows.");
        }

        using var directory = TemporaryDirectory.Create();
        var databasePath = Path.Combine(directory.Path, "lock-reparse.db");
        var outsideLockPath = Path.Combine(directory.Path, "outside.lock");
        CreateLegacyDatabase(databasePath, "lock-reparse");
        File.WriteAllText(outsideLockPath, "outside-lock");

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
            var originalDestinationBytes = File.ReadAllBytes(databasePath);
            var expectedBackupSha256 = StateStoreRecoveryArtifacts.IdentifyFile(backupPath).Sha256;
            var expectedDestinationIdentity = StateStoreRecoveryArtifacts.IdentifyFile(databasePath);

            Assert.Throws<StateStoreRestoreRejectedException>(() =>
                new StateStoreRecoveryService().Restore(
                    new StateStoreRestoreRequest(
                        databasePath,
                        backupPath,
                        expectedBackupSha256,
                        expectedDestinationIdentity.Sha256,
                        StateStoreRestoreContract.ConfirmationPhrase),
                    new FixedTimeProvider(FixedUtc)));

            CollectionAssert.AreEqual(originalDestinationBytes, File.ReadAllBytes(databasePath));
            Assert.AreEqual("outside-lock", File.ReadAllText(outsideLockPath));
        }
        finally
        {
            File.Delete(lockPath);
        }
    }

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
        using var connection = OpenDatabase(path, SqliteOpenMode.ReadWriteCreate);
        using var command = connection.CreateCommand();
        command.CommandText = """
            CREATE TABLE legacy_sentinel(value TEXT NOT NULL);
            INSERT INTO legacy_sentinel(value) VALUES ($value);
            PRAGMA user_version = 0;
            """;
        command.Parameters.AddWithValue("$value", value);
        command.ExecuteNonQuery();
    }

    private sealed class TemporaryDirectory : IDisposable
    {
        private TemporaryDirectory(string path)
        {
            Path = path;
        }

        public string Path { get; }

        public static TemporaryDirectory Create()
        {
            var path = System.IO.Path.Combine(
                System.IO.Path.GetTempPath(),
                "HerdrOps-Issue37",
                Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(path);
            return new TemporaryDirectory(path);
        }

        public void Dispose()
        {
            if (Directory.Exists(Path))
            {
                Directory.Delete(Path, recursive: true);
            }
        }
    }
}
