using System.Collections.Concurrent;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using HerdrOps.Contracts;
using HerdrOps.Contracts.StateIpc;
using HerdrOps.Domain.Herdr;
using HerdrOps.Infrastructure.Herdr;
using HerdrOps.Infrastructure.StateIpc;
using HerdrOps.Infrastructure.ReviewIpc;
using HerdrOps.Infrastructure.Storage;

namespace HerdrOps.Core;

public static class HerdrOpsCoreStateServiceCommand
{
    private const int RuntimeFailureExitCode = 2;
    private const int UsageFailureExitCode = 64;
    private const int MaximumEvidenceTransitions = 2048;
    private const string CompletionSignalContract =
        "UniquePrevalidatedAbsolutePathContainingAnEmptyFileAfterAppExit";

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
        Func<string, string?>? environmentVariableReader = null,
        Func<string?, string?, HerdrSessionState?, HerdrAdmittedRuntimeMonitor>? admittedMonitorFactory = null)
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
        string? completionSignalPath = null;
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
                case "--completion-signal" when index + 1 < args.Length:
                    completionSignalPath = args[++index];
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
            IsInvalidExplicitValue(reportPath) ||
            IsInvalidExplicitValue(completionSignalPath))
        {
            error.WriteLine("Explicit Core state-service option values cannot be blank.");
            WriteUsage(error);
            return UsageFailureExitCode;
        }

        var evidenceMode = reportPath is not null ||
                           durationSeconds is not null ||
                           completionSignalPath is not null;
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

        if (completionSignalPath is not null)
        {
            if (!TryValidateCompletionSignalPath(
                    completionSignalPath,
                    reportPath!,
                    databasePath,
                    executablePath,
                    socketPath,
                    out var normalizedCompletionSignalPath,
                    out var completionSignalError))
            {
                error.WriteLine(completionSignalError);
                WriteUsage(error);
                return UsageFailureExitCode;
            }

            completionSignalPath = normalizedCompletionSignalPath;
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
            var admitted = admittedMonitorFactory is null
                ? new HerdrRuntimeMonitorFactory().Create(
                    executablePath,
                    socketPath,
                    coordinator.RestoredDomainState)
                : admittedMonitorFactory(
                    executablePath,
                    socketPath,
                    coordinator.RestoredDomainState);
            var reviewWorkflow = new ComplianceReviewWorkflowService(store);
            var reviewClientAuthorizer = new HerdrReviewClientProcessAuthorizer(
                admitted.PaneInspectionClient,
                admitted.Admission.Endpoint);
            var reviewCommandServer = new HerdrOpsReviewCommandPipeServer(
                HerdrOpsReviewCommandPipeServerOptions.ForCurrentUser(),
                reviewWorkflow.ExecuteAsync,
                reviewWorkflow.ReadCapabilitiesAsync,
                reviewClientAuthorizer.AuthorizeAsync);
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
            var completionSignalObserved = false;
            using var completionSignalObservationCancellation = completionSignalPath is null
                ? null
                : new CancellationTokenSource();
            var completionSignalTask = completionSignalPath is null
                ? null
                : ObserveCompletionSignalAsync(
                    completionSignalPath,
                    completionSignalObservationCancellation!.Token);
            try
            {
                var serviceTask = new HerdrOpsCoreStateService(
                        admitted.Monitor,
                        coordinator,
                        reviewCommandServer)
                    .RunAsync(effectiveCancellationToken);
                if (completionSignalTask is null)
                {
                    await serviceTask.ConfigureAwait(false);
                }
                else
                {
                    var completedTask = await Task
                        .WhenAny(serviceTask, completionSignalTask)
                        .ConfigureAwait(false);
                    if (ReferenceEquals(completedTask, completionSignalTask))
                    {
                        try
                        {
                            completionSignalObserved = await completionSignalTask
                                .ConfigureAwait(false);
                        }
                        finally
                        {
                            durationCancellation!.Cancel();
                            await serviceTask.ConfigureAwait(false);
                        }
                    }
                    else
                    {
                        await serviceTask.ConfigureAwait(false);
                        if (completionSignalTask.IsCompletedSuccessfully &&
                            completionSignalTask.Result)
                        {
                            completionSignalObserved = true;
                        }
                    }
                }
            }
            finally
            {
                completionSignalObservationCancellation?.Cancel();
                if (completionSignalTask is not null)
                {
                    try
                    {
                        await completionSignalTask.ConfigureAwait(false);
                    }
                    catch (OperationCanceledException) when (
                        completionSignalObservationCancellation?.IsCancellationRequested == true)
                    {
                    }
                }

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
                var evidenceTransitions = transitions.ToArray();
                var acceptedEventObserved =
                    HerdrRuntimeEvidence.HasAcceptedAgentStatusEvent(
                        evidenceTransitions);
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
                    EventObserved: acceptedEventObserved,
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
                    evidenceTransitions,
                    runtimeObserved
                        ? "The Core served state projected from an exact-hash-bound Herdr process; event and reconnect flags require independent true values."
                        : "No exact-hash-bound Herdr snapshot was observed; this report receives no runtime credit.")
                {
                    CompletionSignalObserved = completionSignalObserved,
                    CompletionSignalSemantics = completionSignalPath is null
                        ? null
                        : CompletionSignalContract,
                };
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

    private static bool TryValidateCompletionSignalPath(
        string path,
        string reportPath,
        string? databasePath,
        string? executablePath,
        string? socketPath,
        out string normalizedPath,
        out string error)
    {
        normalizedPath = string.Empty;
        error = string.Empty;
        if (!Path.IsPathFullyQualified(path))
        {
            error = "Option --completion-signal requires an absolute path.";
            return false;
        }

        try
        {
            normalizedPath = NormalizeComparablePath(path);
            if (File.Exists(normalizedPath) || Directory.Exists(normalizedPath))
            {
                error = "Option --completion-signal must name a new path that does not already exist.";
                return false;
            }

            var databaseAliasPath = databasePath ?? HerdrStateStoreOptions.ForCurrentUser().DatabasePath;
            foreach (var candidate in new[] { reportPath, databaseAliasPath, executablePath, socketPath })
            {
                if (string.IsNullOrWhiteSpace(candidate))
                {
                    continue;
                }

                if (StringComparer.OrdinalIgnoreCase.Equals(
                        normalizedPath,
                        NormalizeComparablePath(candidate)))
                {
                    error = "Option --completion-signal must not alias the report, database, executable, or socket path.";
                    return false;
                }
            }

            if (HasReparsePointInExistingParent(normalizedPath))
            {
                error = "Option --completion-signal must not use a reparse-point parent that could alias another path.";
                return false;
            }

            return true;
        }
        catch (Exception exception) when (
            exception is IOException or ArgumentException or NotSupportedException or UnauthorizedAccessException)
        {
            error = $"Option --completion-signal is not a safe absolute path: {exception.Message}";
            return false;
        }
    }

    private static string NormalizeComparablePath(string path) =>
        Path.TrimEndingDirectorySeparator(Path.GetFullPath(path));

    private static bool HasReparsePointInExistingParent(string path)
    {
        var current = Directory.GetParent(path);
        while (current is not null)
        {
            if (current.Exists && (current.Attributes & FileAttributes.ReparsePoint) != 0)
            {
                return true;
            }

            var parent = current.Parent;
            if (parent is null ||
                StringComparer.OrdinalIgnoreCase.Equals(parent.FullName, current.FullName))
            {
                break;
            }

            current = parent;
        }

        return false;
    }

    private static async Task<bool> ObserveCompletionSignalAsync(
        string path,
        CancellationToken cancellationToken)
    {
        while (true)
        {
            if (File.Exists(path))
            {
                if (HasReparsePointInExistingParent(path) ||
                    (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
                {
                    throw new InvalidOperationException(
                        "The completion signal became a reparse-point alias after validation.");
                }

                using var signal = new FileStream(
                    path,
                    FileMode.Open,
                    FileAccess.Read,
                    FileShare.Read,
                    bufferSize: 1,
                    FileOptions.SequentialScan);
                if (signal.Length != 0)
                {
                    throw new InvalidOperationException(
                        "The completion signal must be an empty marker file created by the Acceptance gate after App exit.");
                }

                return true;
            }

            try
            {
                await Task.Delay(TimeSpan.FromMilliseconds(50), cancellationToken)
                    .ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                return false;
            }
        }
    }

    private static void WriteUsage(TextWriter writer) =>
        writer.WriteLine(
            "Usage: HerdrOps.Core serve-herdr-state [--database <absolute-path>] [--herdr <path>] [--socket-path <path>] [--seconds <10-3600> --report <json-path> [--completion-signal <absolute-path>]]");
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
    string Message)
{
    public bool CompletionSignalObserved { get; init; }

    public string? CompletionSignalSemantics { get; init; }
}
