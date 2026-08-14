using System.Collections.Concurrent;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using HerdrOps.Contracts;
using HerdrOps.Contracts.StateIpc;
using HerdrOps.Infrastructure.Herdr;
using HerdrOps.Infrastructure.StateIpc;
using HerdrOps.Infrastructure.Storage;

namespace HerdrOps.Core;

public static class HerdrOpsCoreStateServiceCommand
{
    private const int RuntimeFailureExitCode = 2;
    private const int UsageFailureExitCode = 64;
    private const int MaximumEvidenceTransitions = 2048;

    private static readonly JsonSerializerOptions EvidenceSerializerOptions = new()
    {
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter() },
    };

    public static async Task<int> RunAsync(
        string[] args,
        TextWriter output,
        TextWriter error,
        CancellationToken cancellationToken = default,
        Func<string, string?>? environmentVariableReader = null)
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
        string? reportPath = null;
        int? durationSeconds = null;
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
                case "--report" when index + 1 < args.Length:
                    reportPath = args[++index];
                    break;
                case "--seconds" when index + 1 < args.Length:
                    if (!int.TryParse(args[++index], out var parsedDuration) ||
                        parsedDuration is < 10 or > 3600)
                    {
                        error.WriteLine("Option --seconds must be an integer from 10 through 3600.");
                        WriteUsage(error);
                        return UsageFailureExitCode;
                    }

                    durationSeconds = parsedDuration;
                    break;
                default:
                    error.WriteLine($"Invalid or incomplete option: {args[index]}");
                    WriteUsage(error);
                    return UsageFailureExitCode;
            }
        }

        if (IsInvalidExplicitValue(databasePath) ||
            IsInvalidExplicitValue(executablePath) ||
            IsInvalidExplicitValue(socketPath) ||
            IsInvalidExplicitValue(reportPath))
        {
            error.WriteLine("Explicit Core state-service option values cannot be blank.");
            WriteUsage(error);
            return UsageFailureExitCode;
        }

        var evidenceMode = reportPath is not null || durationSeconds is not null;
        if (evidenceMode &&
            (reportPath is null ||
             durationSeconds is null ||
             executablePath is null ||
             socketPath is null))
        {
            error.WriteLine(
                "Runtime evidence mode requires --report, --seconds, --herdr, and --socket-path together.");
            WriteUsage(error);
            return UsageFailureExitCode;
        }

        var readEnvironmentVariable = environmentVariableReader ?? Environment.GetEnvironmentVariable;
        if (evidenceMode &&
            !string.Equals(
                readEnvironmentVariable("HERDR_ENV"),
                "1",
                StringComparison.Ordinal))
        {
            error.WriteLine(
                "Runtime evidence mode requires an authorized Herdr environment with HERDR_ENV=1.");
            return 3;
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
            var transitions = new ConcurrentQueue<HerdrRuntimeTraceTransition>();
            EventHandler<HerdrRuntimeMonitorSnapshot>? evidenceHandler = null;
            var startedUtc = DateTimeOffset.UtcNow;
            if (evidenceMode)
            {
                evidenceHandler = (_sender, snapshot) =>
                {
                    transitions.Enqueue(HerdrRuntimeEvidence.CreateTransition(snapshot));
                    while (transitions.Count > MaximumEvidenceTransitions &&
                           transitions.TryDequeue(out _))
                    {
                    }
                };
                admitted.Monitor.StateChanged += evidenceHandler;
            }

            var diagnostics = store.GetDiagnostics();
            output.WriteLine(
                $"HerdrOps Core state service starting: schema={diagnostics.SchemaVersion}, journal={diagnostics.JournalMode}, sequence={coordinator.CurrentState.LastIngestSequence}.");
            using var durationCancellation = evidenceMode
                ? CancellationTokenSource.CreateLinkedTokenSource(cancellationToken)
                : null;
            if (durationCancellation is not null)
            {
                durationCancellation.CancelAfter(TimeSpan.FromSeconds(durationSeconds!.Value));
            }

            var effectiveCancellationToken = durationCancellation?.Token ?? cancellationToken;
            try
            {
                await new HerdrOpsCoreStateService(admitted.Monitor, coordinator)
                    .RunAsync(effectiveCancellationToken)
                    .ConfigureAwait(false);
            }
            finally
            {
                if (evidenceHandler is not null)
                {
                    admitted.Monitor.StateChanged -= evidenceHandler;
                }
            }

            output.WriteLine("HerdrOps Core state service stopped.");
            if (evidenceMode)
            {
                var finalMonitorState = admitted.Monitor.Current;
                var finalProjectedState = coordinator.CurrentState;
                var runtimeObserved = finalMonitorState.BootstrapCount > 0 &&
                                      finalMonitorState.ServerIdentity is not null &&
                                      string.Equals(
                                          finalMonitorState.ServerIdentity.ExecutableSha256,
                                          admitted.Admission.ExecutableSha256,
                                          StringComparison.Ordinal);
                var report = new HerdrCoreRuntimeEvidenceReport(
                    runtimeObserved ? EvidenceClass.Runtime.ToString() : "NoRuntimeCredit",
                    runtimeObserved,
                    SessionControlInvoked: false,
                    SnapshotObserved: runtimeObserved,
                    EventObserved: finalMonitorState.EventCount > 0,
                    ReconnectObserved: finalMonitorState.BootstrapCount > 1 &&
                                       finalMonitorState.DisconnectCount > 0,
                    startedUtc,
                    DateTimeOffset.UtcNow,
                    durationSeconds!.Value,
                    Environment.MachineName,
                    Environment.OSVersion.VersionString,
                    admitted.Admission,
                    finalMonitorState,
                    finalProjectedState,
                    HerdrOpsStateIpcJson.ComputeSha256(finalProjectedState),
                    transitions.ToArray(),
                    runtimeObserved
                        ? "The Core served state projected from an exact-hash-bound Herdr process; event and reconnect flags require independent true values."
                        : "No exact-hash-bound Herdr snapshot was observed; this report receives no runtime credit.");
                var reportJson = JsonSerializer.Serialize(report, EvidenceSerializerOptions);
                new AtomicSchemaOutputWriter().Write(
                    reportPath!,
                    Encoding.UTF8.GetBytes(reportJson + Environment.NewLine));
                output.WriteLine(reportJson);
            }

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
            "Usage: HerdrOps.Core serve-herdr-state [--database <absolute-path>] [--herdr <path>] [--socket-path <path>] [--seconds <10-3600> --report <json-path>]");
}

public sealed record HerdrCoreRuntimeEvidenceReport(
    string EvidenceClassification,
    bool RuntimeObserved,
    bool SessionControlInvoked,
    bool SnapshotObserved,
    bool EventObserved,
    bool ReconnectObserved,
    DateTimeOffset StartedUtc,
    DateTimeOffset FinishedUtc,
    int RequestedDurationSeconds,
    string HostName,
    string OperatingSystem,
    HerdrRuntimeAdmission Admission,
    HerdrRuntimeMonitorSnapshot FinalMonitorState,
    HerdrSessionStateContract FinalProjectedState,
    string FinalProjectedStateSha256,
    IReadOnlyList<HerdrRuntimeTraceTransition> Transitions,
    string Message);
