using HerdrOps.Infrastructure.StateIpc;
using HerdrOps.Infrastructure.Storage;

namespace HerdrOps.Core;

public static class HerdrOpsCoreStateServiceCommand
{
    private const int RuntimeFailureExitCode = 2;
    private const int UsageFailureExitCode = 64;

    public static async Task<int> RunAsync(
        string[] args,
        TextWriter output,
        TextWriter error,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(args);
        ArgumentNullException.ThrowIfNull(output);
        ArgumentNullException.ThrowIfNull(error);
        if (args.Length == 0 ||
            !string.Equals(args[0], "serve-herdr-state", StringComparison.Ordinal))
        {
            error.WriteLine("The Core state-service command name is required.");
            WriteUsage(error);
            return UsageFailureExitCode;
        }

        string? databasePath = null;
        string? executablePath = null;
        string? socketPath = null;
        for (var index = 1; index < args.Length; index++)
        {
            switch (args[index])
            {
                case "--database" when index + 1 < args.Length:
                    databasePath = args[++index];
                    break;
                case "--herdr" when index + 1 < args.Length:
                    executablePath = args[++index];
                    break;
                case "--socket-path" when index + 1 < args.Length:
                    socketPath = args[++index];
                    break;
                default:
                    error.WriteLine($"Invalid or incomplete option: {args[index]}");
                    WriteUsage(error);
                    return UsageFailureExitCode;
            }
        }

        if (IsInvalidExplicitValue(databasePath) ||
            IsInvalidExplicitValue(executablePath) ||
            IsInvalidExplicitValue(socketPath))
        {
            error.WriteLine("Explicit Core state-service option values cannot be blank.");
            WriteUsage(error);
            return UsageFailureExitCode;
        }

        try
        {
            var storeOptions = databasePath is null
                ? HerdrStateStoreOptions.ForCurrentUser()
                : new HerdrStateStoreOptions(Path.GetFullPath(databasePath));
            using var store = new SqliteHerdrStateStore(storeOptions);
            var pipeOptions = HerdrOpsStatePipeServerOptions.ForCurrentUser();
            var coordinator = new HerdrStateProjectionCoordinator(store, pipeOptions);
            var admitted = new HerdrRuntimeMonitorFactory().Create(
                executablePath,
                socketPath,
                coordinator.RestoredDomainState);
            var diagnostics = store.GetDiagnostics();
            output.WriteLine(
                $"HerdrOps Core state service starting: schema={diagnostics.SchemaVersion}, journal={diagnostics.JournalMode}, sequence={coordinator.CurrentState.LastIngestSequence}.");
            await new HerdrOpsCoreStateService(admitted.Monitor, coordinator)
                .RunAsync(cancellationToken)
                .ConfigureAwait(false);
            output.WriteLine("HerdrOps Core state service stopped.");
            return 0;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            output.WriteLine("HerdrOps Core state service stopped.");
            return 0;
        }
        catch (Exception exception) when (
            exception is IOException or ArgumentException or InvalidOperationException or UnauthorizedAccessException)
        {
            error.WriteLine($"Core state service failed: {exception.Message}");
            return RuntimeFailureExitCode;
        }
    }

    private static bool IsInvalidExplicitValue(string? value) =>
        value is not null && string.IsNullOrWhiteSpace(value);

    private static void WriteUsage(TextWriter writer) =>
        writer.WriteLine(
            "Usage: HerdrOps.Core serve-herdr-state [--database <absolute-path>] [--herdr <path>] [--socket-path <path>]");
}
