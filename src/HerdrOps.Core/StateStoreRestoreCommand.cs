using System.Text.Json;
using HerdrOps.Infrastructure.Storage.Recovery;

namespace HerdrOps.Core;

public static class StateStoreRestoreCommand
{
    private const int FailureExitCode = 2;
    private const int UsageFailureExitCode = 64;

    private static readonly JsonSerializerOptions OutputOptions = new()
    {
        WriteIndented = true,
    };

    public static int Run(
        string[] args,
        TextWriter output,
        TextWriter error,
        TimeProvider? timeProvider = null)
    {
        ArgumentNullException.ThrowIfNull(args);
        ArgumentNullException.ThrowIfNull(output);
        ArgumentNullException.ThrowIfNull(error);

        if (args.Length == 1 && string.Equals(args[0], "--help", StringComparison.Ordinal))
        {
            WriteUsage(output);
            return 0;
        }

        if (args.Length == 0 ||
            !string.Equals(args[0], "restore-state-store", StringComparison.Ordinal))
        {
            error.WriteLine("The Core state-store restore command name is required.");
            WriteUsage(error);
            return UsageFailureExitCode;
        }

        string? databasePath = null;
        string? backupPath = null;
        string? expectedBackupSha256 = null;
        string? expectedDatabaseSha256 = null;
        string? confirmation = null;
        var seen = new HashSet<string>(StringComparer.Ordinal);
        for (var index = 1; index < args.Length; index++)
        {
            var option = args[index];
            if (index + 1 >= args.Length || !seen.Add(option))
            {
                error.WriteLine($"Invalid, duplicate, or incomplete option: {option}");
                WriteUsage(error);
                return UsageFailureExitCode;
            }

            var value = args[++index];
            switch (option)
            {
                case "--database":
                    databasePath = value;
                    break;
                case "--backup":
                    backupPath = value;
                    break;
                case "--expected-backup-sha256":
                    expectedBackupSha256 = value;
                    break;
                case "--expected-database-sha256":
                    expectedDatabaseSha256 = value;
                    break;
                case "--confirm":
                    confirmation = value;
                    break;
                default:
                    error.WriteLine($"Invalid option: {option}");
                    WriteUsage(error);
                    return UsageFailureExitCode;
            }
        }

        if (new[] { databasePath, backupPath, expectedBackupSha256, expectedDatabaseSha256, confirmation }
            .Any(string.IsNullOrWhiteSpace))
        {
            error.WriteLine("The restore command requires explicit source, destination, identity, and confirmation options.");
            WriteUsage(error);
            return UsageFailureExitCode;
        }

        try
        {
            var report = new StateStoreRecoveryService().Restore(
                new StateStoreRestoreRequest(
                    databasePath!,
                    backupPath!,
                    expectedBackupSha256!,
                    expectedDatabaseSha256!,
                    confirmation!),
                timeProvider);
            output.WriteLine(JsonSerializer.Serialize(report, OutputOptions));
            return 0;
        }
        catch (StateStoreRestoreRejectedException exception)
        {
            error.WriteLine($"State-store restore rejected: {exception.Message}");
            return FailureExitCode;
        }
        catch (Exception exception) when (
            exception is IOException or UnauthorizedAccessException or ArgumentException or InvalidOperationException)
        {
            error.WriteLine("State-store restore failed closed: " + exception.GetType().Name);
            return FailureExitCode;
        }
    }

    private static void WriteUsage(TextWriter writer) =>
        writer.WriteLine(
            "Usage: HerdrOps.Core restore-state-store --database <absolute-path> --backup <absolute-backup-path> --expected-backup-sha256 <64-hex> --expected-database-sha256 <64-hex|ABSENT> --confirm RESTORE_STATE_STORE");
}
