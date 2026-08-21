using System.Collections.Concurrent;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using HerdrOps.Contracts;
using HerdrOps.Domain.Activity;
using HerdrOps.Domain.Herdr;
using HerdrOps.Infrastructure.Herdr;

namespace HerdrOps.Core;

public sealed record HerdrRealtimeActivityRuntimeTraceEvent(
    string SourceEventId,
    string PaneId,
    string AgentTerminalId,
    string AgentStatus,
    string PipelineDisposition,
    long EmissionCount,
    long HerdrEventCount,
    long HerdrIngestSequence,
    long HerdrConnectionEpoch,
    double LatencyMilliseconds,
    string EventIdentitySha256,
    string EnvelopeSha256,
    DateTimeOffset OccurredUtc,
    DateTimeOffset ObservedUtc);

public sealed record HerdrRealtimeActivityRuntimeTraceReport(
    int ContractVersion,
    string EvidenceClassification,
    bool RuntimeObserved,
    bool ActivityEventObserved,
    bool ActivityEmissionObserved,
    bool SessionControlInvoked,
    string ProductAssemblySha256,
    DateTimeOffset StartedUtc,
    DateTimeOffset FinishedUtc,
    int RequestedDurationSeconds,
    HerdrRuntimeAdmission? Admission,
    HerdrServerProcessIdentity? MonitorServerIdentity,
    HerdrRuntimeMonitorSnapshot FinalMonitorState,
    int AgentStatusTransitionCount,
    int AcceptedEventCount,
    int ImmediateEventCount,
    int BufferedEventCount,
    int DuplicateCount,
    int RejectedCount,
    long EmissionCount,
    double? FirstEventLatencyMilliseconds,
    double? MaximumEventLatencyMilliseconds,
    ActivityPipelineDiagnostics PipelineDiagnostics,
    IReadOnlyList<HerdrRealtimeActivityRuntimeTraceEvent> Events,
    string Message,
    string EvidenceBoundary);

/// <summary>
/// Captures actual accepted Herdr Agent-status transitions through the v0.3 activity
/// pipeline. The command never creates a transition and never invokes Herdr session
/// control; an operator must cause a real transition in the admitted session.
/// </summary>
public static class HerdrRealtimeActivityRuntimeTraceCommand
{
    public const string CommandName = "trace-herdr-realtime-activity";

    private const int RuntimeFailureExitCode = 2;
    private const int EnvironmentGateExitCode = 3;
    private const int UsageFailureExitCode = 64;
    private const int MaximumRetainedEvents = 4096;

    private static readonly JsonSerializerOptions SerializerOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter(allowIntegerValues: false) },
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

        if (!TryParseArguments(
                args,
                error,
                out var reportPath,
                out var durationSeconds,
                out var executablePath,
                out var socketPath))
        {
            return UsageFailureExitCode;
        }

        var readEnvironmentVariable = environmentVariableReader ?? Environment.GetEnvironmentVariable;
        if (!string.Equals(readEnvironmentVariable("HERDR_ENV"), "1", StringComparison.Ordinal))
        {
            error.WriteLine(
                "Realtime activity runtime trace is gated: run it from an authorized Herdr environment with HERDR_ENV=1.");
            return EnvironmentGateExitCode;
        }

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

        var activityPipeline = new ActivityEventPipeline();
        var pipelineLock = new object();
        var events = new ConcurrentQueue<HerdrRealtimeActivityRuntimeTraceEvent>();
        var seenTransitionKeys = new ConcurrentDictionary<string, byte>(StringComparer.Ordinal);
        var acceptedEventCount = 0;
        var immediateEventCount = 0;
        var bufferedEventCount = 0;
        var duplicateCount = 0;
        var rejectedCount = 0;
        var latencies = new List<double>();
        var sourceSequence = 0L;

        void OnStateChanged(object? sender, HerdrRuntimeMonitorSnapshot snapshot)
        {
            if (!string.Equals(
                    snapshot.AcceptedEventKind,
                    HerdrRuntimeMonitor.AcceptedAgentStatusEventKind,
                    StringComparison.Ordinal) ||
                snapshot.AcceptedAgentStatusEvent is null)
            {
                return;
            }

            var accepted = snapshot.AcceptedAgentStatusEvent;
            if (!snapshot.State.Panes.TryGetValue(accepted.PaneId, out var pane) ||
                string.IsNullOrWhiteSpace(pane.TerminalId))
            {
                Interlocked.Increment(ref rejectedCount);
                return;
            }

            var transitionKey = $"{accepted.PaneId}:{snapshot.EventCount}";
            if (!seenTransitionKeys.TryAdd(transitionKey, 0))
            {
                return;
            }

            var sourceEventId = $"pane.agent_status_changed:{accepted.PaneId}:{snapshot.EventCount}";
            var occurredUtc = snapshot.LastTransitionUtc.ToUniversalTime();
            var observedUtc = DateTimeOffset.UtcNow;
            var latencyMilliseconds = Math.Max(
                0d,
                (observedUtc - occurredUtc).TotalMilliseconds);
            var urgent = accepted.AgentStatus == HerdrAgentStatus.Blocked;
            var payloadSha256 = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(
                $"{accepted.PaneId}|{pane.TerminalId}|{accepted.AgentStatus}|{snapshot.EventCount}")));
            var envelope = new ActivityEventEnvelope(
                ContractVersion: ActivityEventContract.Version,
                SourceEventId: sourceEventId,
                SourceKind: ActivitySourceKind.Herdr,
                SourceInstanceId: "herdr-agent-status-monitor",
                SourceEpoch: admitted.Admission.ExecutableSha256,
                SourceSequence: Interlocked.Increment(ref sourceSequence),
                Confidence: ActivityConfidence.Observed,
                Urgency: urgent ? ActivityUrgency.High : ActivityUrgency.Normal,
                DeliveryMode: urgent ? ActivityDeliveryMode.Immediate : ActivityDeliveryMode.Debounced,
                EventType: HerdrRuntimeMonitor.AcceptedAgentStatusEventKind,
                OccurredUtc: occurredUtc,
                ObservedUtc: observedUtc,
                CorrelationId: CreateCorrelationId(sourceEventId),
                DebounceKey: urgent ? null : $"pane-status:{accepted.PaneId}",
                AgentTerminalId: pane.TerminalId,
                PaneId: accepted.PaneId,
                TaskId: null,
                ProcessId: null,
                RedactedSummary: "Herdr Agent status transition observed",
                PayloadSha256: payloadSha256);

            ActivityPipelineStep step;
            try
            {
                lock (pipelineLock)
                {
                    step = activityPipeline.Process(envelope);
                }
            }
            catch (ActivityEventContractException)
            {
                Interlocked.Increment(ref rejectedCount);
                return;
            }

            switch (step.Disposition)
            {
                case ActivityPipelineDisposition.AcceptedImmediate:
                    Interlocked.Increment(ref acceptedEventCount);
                    Interlocked.Increment(ref immediateEventCount);
                    break;
                case ActivityPipelineDisposition.AcceptedBuffered:
                    Interlocked.Increment(ref acceptedEventCount);
                    Interlocked.Increment(ref bufferedEventCount);
                    break;
                case ActivityPipelineDisposition.Duplicate:
                    Interlocked.Increment(ref duplicateCount);
                    break;
                default:
                    Interlocked.Increment(ref rejectedCount);
                    break;
            }

            lock (pipelineLock)
            {
                latencies.Add(latencyMilliseconds);
            }

            events.Enqueue(new HerdrRealtimeActivityRuntimeTraceEvent(
                sourceEventId,
                accepted.PaneId,
                pane.TerminalId,
                accepted.AgentStatus.ToString(),
                step.Disposition.ToString(),
                step.Emissions.Count,
                snapshot.EventCount,
                snapshot.State.LastIngestSequence,
                snapshot.State.ConnectionEpoch,
                latencyMilliseconds,
                step.Event.EventIdentitySha256,
                step.Event.EnvelopeSha256,
                occurredUtc,
                observedUtc));
            while (events.Count > MaximumRetainedEvents && events.TryDequeue(out _))
            {
            }
        }

        admitted.Monitor.StateChanged += OnStateChanged;
        var startedUtc = DateTimeOffset.UtcNow;
        Exception? monitorFailure = null;
        using var duration = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        duration.CancelAfter(TimeSpan.FromSeconds(durationSeconds));
        try
        {
            await admitted.Monitor.RunAsync(duration.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (duration.IsCancellationRequested)
        {
        }
        catch (Exception exception)
        {
            monitorFailure = exception;
        }
        finally
        {
            admitted.Monitor.StateChanged -= OnStateChanged;
        }

        ActivityPipelineDiagnostics pipelineDiagnostics;
        lock (pipelineLock)
        {
            _ = activityPipeline.FlushAll();
            pipelineDiagnostics = activityPipeline.GetDiagnostics();
        }

        var final = admitted.Monitor.Current;
        var monitorIdentity = final.ServerIdentity;
        var runtimeObserved = monitorFailure is null &&
                              final.BootstrapCount > 0 &&
                              IsAdmittedIdentity(monitorIdentity, admitted.Admission);
        var transitionRecords = events.ToArray();
        var activityEventObserved = acceptedEventCount > 0;
        var activityEmissionObserved = pipelineDiagnostics.EmissionCount > 0;
        var completeRuntimeEvidence =
            runtimeObserved && activityEventObserved && activityEmissionObserved;

        var message = completeRuntimeEvidence
            ? "Actual Herdr Agent-status transition(s) were admitted into the v0.3 activity pipeline and produced a bounded emission. No session control was invoked."
            : runtimeObserved
                ? "The admitted Herdr runtime was observed, but no qualifying activity event and emission were captured during this run."
                : "No exact-hash-bound Herdr runtime was observed; this report receives no runtime credit.";
        if (monitorFailure is not null)
        {
            message += $" Monitor failed with {monitorFailure.GetType().Name}.";
        }

        double? firstLatency = null;
        double? maximumLatency = null;
        lock (pipelineLock)
        {
            if (latencies.Count > 0)
            {
                firstLatency = latencies[0];
                maximumLatency = latencies.Max();
            }
        }

        var report = new HerdrRealtimeActivityRuntimeTraceReport(
            ContractVersion: 1,
            completeRuntimeEvidence ? EvidenceClass.Runtime.ToString() : "NoRuntimeCredit",
            runtimeObserved,
            activityEventObserved,
            activityEmissionObserved,
            SessionControlInvoked: false,
            ComputeFileSha256(typeof(HerdrRealtimeActivityRuntimeTraceCommand).Assembly.Location),
            startedUtc,
            DateTimeOffset.UtcNow,
            durationSeconds,
            admitted.Admission,
            monitorIdentity,
            final,
            transitionRecords.Length,
            acceptedEventCount,
            immediateEventCount,
            bufferedEventCount,
            duplicateCount,
            rejectedCount,
            pipelineDiagnostics.EmissionCount,
            firstLatency,
            maximumLatency,
            pipelineDiagnostics,
            transitionRecords,
            message,
            "This is actual Herdr Agent-status transition evidence routed through the v0.3 activity pipeline for one admitted session. SessionControlInvoked=false means this command issued no Herdr session-control request. This does not prove Task correlation, notification delivery, restart persistence, independent review, or v0.3 release readiness.");

        var json = JsonSerializer.Serialize(report, SerializerOptions) + "\n";
        try
        {
            new AtomicSchemaOutputWriter().Write(
                Path.GetFullPath(reportPath!),
                Encoding.UTF8.GetBytes(json));
        }
        catch (Exception exception) when (
            exception is IOException or ArgumentException or NotSupportedException or UnauthorizedAccessException)
        {
            error.WriteLine($"Realtime activity runtime trace report could not be written: {exception.Message}");
            return RuntimeFailureExitCode;
        }

        output.Write(json);
        if (!completeRuntimeEvidence)
        {
            error.WriteLine(message);
            return RuntimeFailureExitCode;
        }

        return 0;
    }

    private static bool TryParseArguments(
        string[] args,
        TextWriter error,
        out string? reportPath,
        out int durationSeconds,
        out string? executablePath,
        out string? socketPath)
    {
        reportPath = null;
        durationSeconds = 30;
        executablePath = null;
        socketPath = null;
        if (args.Length == 0 || !string.Equals(args[0], CommandName, StringComparison.Ordinal))
        {
            error.WriteLine("The realtime-activity trace command name is required.");
            WriteUsage(error);
            return false;
        }

        for (var index = 1; index < args.Length; index++)
        {
            switch (args[index])
            {
                case "--seconds" when index + 1 < args.Length:
                    if (!int.TryParse(args[++index], out durationSeconds) || durationSeconds is < 1 or > 3600)
                    {
                        error.WriteLine("Option --seconds must be an integer from 1 through 3600.");
                        WriteUsage(error);
                        return false;
                    }

                    break;
                case "--herdr" when index + 1 < args.Length:
                    executablePath = args[++index];
                    if (IsInvalidValue(executablePath))
                    {
                        error.WriteLine("Option --herdr requires a non-empty executable path.");
                        WriteUsage(error);
                        return false;
                    }

                    break;
                case "--socket-path" when index + 1 < args.Length:
                    socketPath = args[++index];
                    if (IsInvalidValue(socketPath))
                    {
                        error.WriteLine("Option --socket-path requires a non-empty Herdr socket path.");
                        WriteUsage(error);
                        return false;
                    }

                    break;
                case "--report" when index + 1 < args.Length:
                    reportPath = args[++index];
                    if (IsInvalidValue(reportPath))
                    {
                        error.WriteLine("Option --report requires a non-empty JSON path.");
                        WriteUsage(error);
                        return false;
                    }

                    break;
                default:
                    error.WriteLine($"Invalid or incomplete option: {args[index]}");
                    WriteUsage(error);
                    return false;
            }
        }

        if (string.IsNullOrWhiteSpace(reportPath))
        {
            error.WriteLine("Option --report is required so runtime observations are retained.");
            WriteUsage(error);
            return false;
        }

        return true;
    }

    private static bool IsAdmittedIdentity(
        HerdrServerProcessIdentity? identity,
        HerdrRuntimeAdmission admission) =>
        identity is not null &&
        string.Equals(identity.ExecutablePath, admission.ExecutablePath, StringComparison.OrdinalIgnoreCase) &&
        string.Equals(identity.ExecutableSha256, admission.ExecutableSha256, StringComparison.Ordinal);

    private static Guid CreateCorrelationId(string sourceEventId)
    {
        var hash = SHA256.HashData(Encoding.UTF8.GetBytes(
            $"HerdrOps.v0.3.RealtimeActivityCorrelation.v1\u001f{sourceEventId}"));
        return new Guid(hash.AsSpan(0, 16));
    }

    private static string ComputeFileSha256(string path)
    {
        using var input = new FileStream(
            path,
            FileMode.Open,
            FileAccess.Read,
            FileShare.Read,
            bufferSize: 81920,
            FileOptions.SequentialScan);
        return Convert.ToHexString(SHA256.HashData(input));
    }

    private static bool IsInvalidValue(string value) =>
        string.IsNullOrWhiteSpace(value) || value.StartsWith("--", StringComparison.Ordinal);

    private static void WriteUsage(TextWriter writer) =>
        writer.WriteLine(
            $"Usage: HerdrOps.Core {CommandName} --report <json-path> [--seconds <1-3600>] [--herdr <path>] [--socket-path <path>]");
}
