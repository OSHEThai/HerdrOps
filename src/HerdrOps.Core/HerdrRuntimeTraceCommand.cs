using System.Collections.Concurrent;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using HerdrOps.Contracts;
using HerdrOps.Domain.Herdr;
using HerdrOps.Infrastructure.Herdr;

namespace HerdrOps.Core;

public sealed record HerdrRuntimeTraceTransition(
    DateTimeOffset ObservedUtc,
    HerdrRuntimeMonitorStatus Status,
    long ConnectionEpoch,
    long BootstrapCount,
    long EventCount,
    long DisconnectCount,
    long ReconciliationCount,
    long IngestSequence,
    int WorkspaceCount,
    int TabCount,
    int PaneCount,
    int AgentCount,
    bool AllAgentsHaveLiveIdentity,
    string StateFingerprintSha256,
    string ContractStateSha256,
    string AgentTopologySha256,
    string AgentStatusStateSha256,
    HerdrServerProcessIdentity? ServerIdentity,
    string? AcceptedEventKind,
    string? Reason)
{
    public HerdrAcceptedAgentStatusEvent? AcceptedAgentStatusEvent { get; init; }
}

public sealed record HerdrRuntimeTraceReport(
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
    HerdrRuntimeAdmission? Admission,
    HerdrServerProcessIdentity? ObservedServerIdentity,
    HerdrRuntimeMonitorSnapshot FinalMonitorState,
    IReadOnlyList<HerdrRuntimeTraceTransition> Transitions,
    string Message);

public static class HerdrRuntimeTraceCommand
{
    private const int RuntimeFailureExitCode = 2;
    private const int EnvironmentGateExitCode = 3;
    private const int UsageFailureExitCode = 64;
    private const int MaximumTransitions = 2048;

    private static readonly JsonSerializerOptions SerializerOptions = new()
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
            !string.Equals(args[0], "trace-herdr-runtime", StringComparison.Ordinal))
        {
            error.WriteLine("The runtime-trace command name is required.");
            WriteUsage(error);
            return UsageFailureExitCode;
        }

        var durationSeconds = 30;
        string? executablePath = null;
        string? socketPath = null;
        string? reportPath = null;
        for (var index = 1; index < args.Length; index++)
        {
            switch (args[index])
            {
                case "--seconds" when index + 1 < args.Length:
                    if (!int.TryParse(args[++index], out durationSeconds) || durationSeconds is < 1 or > 3600)
                    {
                        error.WriteLine("Option --seconds must be an integer from 1 through 3600.");
                        WriteUsage(error);
                        return UsageFailureExitCode;
                    }
                    break;
                case "--herdr" when index + 1 < args.Length:
                    executablePath = args[++index];
                    if (IsInvalidValue(executablePath))
                    {
                        error.WriteLine("Option --herdr requires a non-empty executable path.");
                        WriteUsage(error);
                        return UsageFailureExitCode;
                    }
                    break;
                case "--socket-path" when index + 1 < args.Length:
                    socketPath = args[++index];
                    if (IsInvalidValue(socketPath))
                    {
                        error.WriteLine("Option --socket-path requires a non-empty Herdr socket path.");
                        WriteUsage(error);
                        return UsageFailureExitCode;
                    }
                    break;
                case "--report" when index + 1 < args.Length:
                    reportPath = args[++index];
                    if (IsInvalidValue(reportPath))
                    {
                        error.WriteLine("Option --report requires a non-empty JSON path.");
                        WriteUsage(error);
                        return UsageFailureExitCode;
                    }
                    break;
                default:
                    error.WriteLine($"Invalid or incomplete option: {args[index]}");
                    WriteUsage(error);
                    return UsageFailureExitCode;
            }
        }

        if (string.IsNullOrWhiteSpace(reportPath))
        {
            error.WriteLine("Option --report is required so runtime observations are retained.");
            WriteUsage(error);
            return UsageFailureExitCode;
        }

        var readEnvironmentVariable = environmentVariableReader ?? Environment.GetEnvironmentVariable;
        if (!string.Equals(
                readEnvironmentVariable("HERDR_ENV"),
                "1",
                StringComparison.Ordinal))
        {
            error.WriteLine(
                "Runtime trace is gated: run it from an authorized Herdr environment with HERDR_ENV=1.");
            return EnvironmentGateExitCode;
        }

        var startedUtc = DateTimeOffset.UtcNow;
        HerdrAdmittedRuntimeMonitor admitted;
        try
        {
            admitted = new HerdrRuntimeMonitorFactory().Create(executablePath, socketPath);
        }
        catch (Exception exception) when (
            exception is IOException or ArgumentException or InvalidOperationException or UnauthorizedAccessException)
        {
            error.WriteLine($"Runtime admission failed: {exception.Message}");
            return RuntimeFailureExitCode;
        }

        var transitions = new ConcurrentQueue<HerdrRuntimeTraceTransition>();
        admitted.Monitor.StateChanged += (_sender, state) =>
        {
            transitions.Enqueue(HerdrRuntimeEvidence.CreateTransition(state));
            while (transitions.Count > MaximumTransitions && transitions.TryDequeue(out _))
            {
            }
        };

        using var durationCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        durationCancellation.CancelAfter(TimeSpan.FromSeconds(durationSeconds));
        try
        {
            await admitted.Monitor.RunAsync(durationCancellation.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (durationCancellation.IsCancellationRequested)
        {
        }

        var final = admitted.Monitor.Current;
        var observedServerIdentity = final.ServerIdentity;
        var observedTransitions = transitions.ToArray();
        var acceptedEventObserved =
            HerdrRuntimeEvidence.HasAcceptedAgentStatusEvent(observedTransitions);
        var runtimeObserved = final.BootstrapCount > 0 &&
                              observedServerIdentity is not null &&
                              string.Equals(
                                  observedServerIdentity.ExecutableSha256,
                                  admitted.Admission.ExecutableSha256,
                                  StringComparison.Ordinal);
        var reconnectObserved = final.BootstrapCount > 1 && final.DisconnectCount > 0;
        var report = new HerdrRuntimeTraceReport(
            runtimeObserved ? EvidenceClass.Runtime.ToString() : "NoRuntimeCredit",
            runtimeObserved,
            SessionControlInvoked: false,
            SnapshotObserved: runtimeObserved,
            EventObserved: acceptedEventObserved,
            ReconnectObserved: reconnectObserved,
            startedUtc,
            DateTimeOffset.UtcNow,
            durationSeconds,
            Environment.MachineName,
            Environment.OSVersion.VersionString,
            admitted.Admission,
            observedServerIdentity,
            final,
            observedTransitions,
            runtimeObserved
                ? "An exact-hash-bound Herdr server snapshot was observed. Event and reconnect flags require their own true values for credit."
                : "No exact-hash-bound Herdr server snapshot was observed; this report receives no runtime credit.");
        var reportJson = JsonSerializer.Serialize(report, SerializerOptions);
        try
        {
            new AtomicSchemaOutputWriter().Write(
                reportPath,
                Encoding.UTF8.GetBytes(reportJson + Environment.NewLine));
        }
        catch (Exception exception) when (
            exception is IOException or ArgumentException or NotSupportedException or UnauthorizedAccessException)
        {
            error.WriteLine($"Runtime trace report could not be written: {exception.Message}");
            return RuntimeFailureExitCode;
        }

        output.WriteLine(reportJson);
        if (!runtimeObserved)
        {
            error.WriteLine(report.Message);
            return RuntimeFailureExitCode;
        }

        return 0;
    }

    private static bool IsInvalidValue(string value) =>
        string.IsNullOrWhiteSpace(value) || value.StartsWith("--", StringComparison.Ordinal);

    private static void WriteUsage(TextWriter writer) =>
        writer.WriteLine(
            "Usage: HerdrOps.Core trace-herdr-runtime --report <json-path> [--seconds <1-3600>] [--herdr <path>] [--socket-path <path>]");
}
