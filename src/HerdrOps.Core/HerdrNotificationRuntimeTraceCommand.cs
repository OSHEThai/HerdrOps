using System.Collections.Concurrent;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using HerdrOps.Contracts;
using HerdrOps.Domain.Activity;
using HerdrOps.Domain.Herdr;
using HerdrOps.Domain.Notifications;
using HerdrOps.Infrastructure.Herdr;

namespace HerdrOps.Core;

public sealed record HerdrNotificationRuntimeTraceRecord(
    string PaneId,
    string AgentTerminalId,
    string AgentStatus,
    string PipelineDisposition,
    string NotificationDisposition,
    bool ShowPopup,
    long HerdrEventCount,
    long HerdrIngestSequence,
    long HerdrConnectionEpoch,
    DateTimeOffset OccurredUtc,
    DateTimeOffset ObservedUtc);

public sealed record HerdrNotificationRuntimeTraceReport(
    int ContractVersion,
    string EvidenceClassification,
    bool RuntimeObserved,
    bool NotificationDeliveryObserved,
    bool HerdrAgentCorrelationObserved,
    bool SessionControlInvoked,
    string ProductAssemblySha256,
    DateTimeOffset StartedUtc,
    DateTimeOffset FinishedUtc,
    int RequestedDurationSeconds,
    HerdrRuntimeAdmission? Admission,
    HerdrServerProcessIdentity? MonitorServerIdentity,
    HerdrRuntimeMonitorSnapshot FinalMonitorState,
    int AgentStatusTransitionCount,
    int AcceptedImmediateCount,
    int AcceptedBufferedCount,
    int DuplicateCount,
    int IgnoredCount,
    int PopupRequestedCount,
    int AgentCorrelatedNotificationCount,
    IReadOnlyList<HerdrNotificationRuntimeTraceRecord> Transitions,
    string Message,
    string EvidenceBoundary);

/// <summary>
/// Drives actual Herdr Agent-status transitions from an admitted live session through the
/// real activity pipeline and notification center, and captures the resulting delivery and
/// Agent-correlation evidence. This command never issues a Herdr session-control request.
/// </summary>
public static class HerdrNotificationRuntimeTraceCommand
{
    private const int RuntimeFailureExitCode = 2;
    private const int EnvironmentGateExitCode = 3;
    private const int UsageFailureExitCode = 64;
    private const int MaximumRetainedTransitions = 4096;

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
        if (args.Length == 0 ||
            !string.Equals(args[0], "trace-herdr-notification-runtime", StringComparison.Ordinal))
        {
            error.WriteLine("The Herdr notification runtime trace command name is required.");
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
        if (!string.Equals(readEnvironmentVariable("HERDR_ENV"), "1", StringComparison.Ordinal))
        {
            error.WriteLine(
                "Notification runtime trace is gated: run it from an authorized Herdr environment with HERDR_ENV=1.");
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

        var pipeline = new ActivityEventPipeline();
        var notificationCenter = new NotificationCenter();
        var transitions = new ConcurrentQueue<HerdrNotificationRuntimeTraceRecord>();
        var seenTransitionKeys = new ConcurrentDictionary<string, byte>(StringComparer.Ordinal);
        var acceptedImmediateCount = 0;
        var acceptedBufferedCount = 0;
        var duplicateCount = 0;
        var ignoredCount = 0;
        var popupRequestedCount = 0;
        var agentCorrelatedNotificationCount = 0;
        var localSourceSequence = 0L;

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
                return;
            }

            var transitionKey = $"{accepted.PaneId}:{snapshot.EventCount}";
            if (!seenTransitionKeys.TryAdd(transitionKey, 0))
            {
                return;
            }

            var urgent = accepted.AgentStatus == HerdrAgentStatus.Blocked;
            var occurredUtc = snapshot.LastTransitionUtc;
            var observedUtc = DateTimeOffset.UtcNow;
            var agentLabel = accepted.DisplayAgent ?? accepted.Agent ?? "unknown-agent";
            var summary = $"Agent {agentLabel} status changed to {accepted.AgentStatus}";
            var payloadSha256 = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(
                $"{accepted.PaneId}|{accepted.WorkspaceId}|{accepted.AgentStatus}|{snapshot.EventCount}")));

            var envelope = new ActivityEventEnvelope(
                ContractVersion: 1,
                SourceEventId: $"pane.agent_status_changed:{accepted.PaneId}:{snapshot.EventCount}",
                SourceKind: ActivitySourceKind.Herdr,
                SourceInstanceId: "herdr-agent-status-monitor",
                SourceEpoch: admitted.Admission.ExecutableSha256,
                SourceSequence: Interlocked.Increment(ref localSourceSequence),
                Confidence: ActivityConfidence.Observed,
                Urgency: urgent ? ActivityUrgency.High : ActivityUrgency.Normal,
                DeliveryMode: urgent ? ActivityDeliveryMode.Immediate : ActivityDeliveryMode.Debounced,
                EventType: "pane.agent_status_changed",
                OccurredUtc: occurredUtc,
                ObservedUtc: observedUtc,
                CorrelationId: Guid.NewGuid(),
                DebounceKey: urgent ? null : $"pane-status:{accepted.PaneId}",
                AgentTerminalId: pane.TerminalId,
                PaneId: accepted.PaneId,
                TaskId: null,
                ProcessId: null,
                RedactedSummary: summary,
                PayloadSha256: payloadSha256);

            ActivityPipelineStep step;
            NotificationCenterDecision decision;
            try
            {
                step = pipeline.Process(envelope);
                decision = notificationCenter.Accept(step);
            }
            catch (ActivityEventContractException)
            {
                return;
            }

            switch (step.Disposition)
            {
                case ActivityPipelineDisposition.AcceptedImmediate:
                    Interlocked.Increment(ref acceptedImmediateCount);
                    break;
                case ActivityPipelineDisposition.AcceptedBuffered:
                    Interlocked.Increment(ref acceptedBufferedCount);
                    break;
            }

            if (decision.Disposition == NotificationCenterDisposition.Duplicate)
            {
                Interlocked.Increment(ref duplicateCount);
            }
            else if (decision.Disposition == NotificationCenterDisposition.IgnoredPipelineDisposition)
            {
                Interlocked.Increment(ref ignoredCount);
            }
            else if (decision.Item?.AgentTerminalId is not null)
            {
                Interlocked.Increment(ref agentCorrelatedNotificationCount);
            }

            if (decision.ShowPopup)
            {
                Interlocked.Increment(ref popupRequestedCount);
            }

            transitions.Enqueue(new HerdrNotificationRuntimeTraceRecord(
                accepted.PaneId,
                pane.TerminalId,
                accepted.AgentStatus.ToString(),
                step.Disposition.ToString(),
                decision.Disposition.ToString(),
                decision.ShowPopup,
                snapshot.EventCount,
                snapshot.State.LastIngestSequence,
                snapshot.State.ConnectionEpoch,
                occurredUtc,
                observedUtc));
            while (transitions.Count > MaximumRetainedTransitions && transitions.TryDequeue(out _))
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

        var final = admitted.Monitor.Current;
        var monitorIdentity = final.ServerIdentity;
        var runtimeObserved = monitorFailure is null &&
                              final.BootstrapCount > 0 &&
                              IsAdmittedIdentity(monitorIdentity, admitted.Admission);
        var transitionRecords = transitions.ToArray();
        var notificationDeliveryObserved = acceptedImmediateCount + acceptedBufferedCount > 0;
        var herdrAgentCorrelationObserved = agentCorrelatedNotificationCount > 0;
        var completeRuntimeEvidence =
            runtimeObserved && notificationDeliveryObserved && herdrAgentCorrelationObserved;

        var message = completeRuntimeEvidence
            ? "Actual Herdr Agent-status transitions were delivered through the notification pipeline with Agent correlation. No session control was invoked."
            : runtimeObserved
                ? "The admitted Herdr runtime was observed, but no qualifying Agent-status transition produced a correlated notification during this run."
                : "No exact-hash-bound Herdr runtime was observed; this report receives no runtime credit.";
        if (monitorFailure is not null)
        {
            message += $" Monitor failed with {monitorFailure.GetType().Name}.";
        }

        var report = new HerdrNotificationRuntimeTraceReport(
            ContractVersion: 1,
            completeRuntimeEvidence ? EvidenceClass.Runtime.ToString() : "NoRuntimeCredit",
            runtimeObserved,
            notificationDeliveryObserved,
            herdrAgentCorrelationObserved,
            SessionControlInvoked: false,
            ComputeFileSha256(typeof(HerdrNotificationRuntimeTraceCommand).Assembly.Location),
            startedUtc,
            DateTimeOffset.UtcNow,
            durationSeconds,
            admitted.Admission,
            monitorIdentity,
            final,
            transitionRecords.Length,
            acceptedImmediateCount,
            acceptedBufferedCount,
            duplicateCount,
            ignoredCount,
            popupRequestedCount,
            agentCorrelatedNotificationCount,
            transitionRecords,
            message,
            "This is actual Herdr Agent-status transition evidence routed through the real activity pipeline and notification center for one admitted session. SessionControlInvoked=false means this command issued no Herdr session-control request. This does not prove Task correlation, installed-runtime notification latency, restart persistence, or v0.3 release readiness.");

        var json = JsonSerializer.Serialize(report, SerializerOptions) + "\n";
        try
        {
            new AtomicSchemaOutputWriter().Write(
                Path.GetFullPath(reportPath!),
                new UTF8Encoding(encoderShouldEmitUTF8Identifier: false).GetBytes(json));
        }
        catch (Exception exception) when (
            exception is IOException or ArgumentException or NotSupportedException or UnauthorizedAccessException)
        {
            error.WriteLine($"Notification runtime trace report could not be written: {exception.Message}");
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

    private static bool IsAdmittedIdentity(
        HerdrServerProcessIdentity? identity,
        HerdrRuntimeAdmission admission) =>
        identity is not null &&
        string.Equals(identity.ExecutablePath, admission.ExecutablePath, StringComparison.OrdinalIgnoreCase) &&
        string.Equals(identity.ExecutableSha256, admission.ExecutableSha256, StringComparison.Ordinal);

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
            "Usage: HerdrOps.Core trace-herdr-notification-runtime --report <json-path> [--seconds <1-3600>] [--herdr <path>] [--socket-path <path>]");
}
