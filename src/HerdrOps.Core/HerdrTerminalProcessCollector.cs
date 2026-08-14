using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using HerdrOps.Domain.Activity;
using HerdrOps.Infrastructure.Activity;
using HerdrOps.Infrastructure.Herdr;

namespace HerdrOps.Core;

public sealed record HerdrTerminalProcessCollectorOptions(
    int MaximumTerminalLines,
    int MaximumPanesPerCycle,
    TimeSpan TerminalReadInterval,
    TimeSpan ProcessPollInterval)
{
    public static HerdrTerminalProcessCollectorOptions Default { get; } = new(
        TerminalPreviewContract.DefaultMaximumLines,
        MaximumPanesPerCycle: 256,
        TerminalReadInterval: TimeSpan.FromSeconds(2),
        ProcessPollInterval: TimeSpan.FromSeconds(2));

    public void Validate()
    {
        if (MaximumTerminalLines is < 1 or > TerminalPreviewContract.HardMaximumLines)
        {
            throw new ArgumentOutOfRangeException(
                nameof(MaximumTerminalLines),
                $"Terminal collection must request between 1 and {TerminalPreviewContract.HardMaximumLines} lines.");
        }

        if (MaximumPanesPerCycle is < 1 or > 4096)
        {
            throw new ArgumentOutOfRangeException(
                nameof(MaximumPanesPerCycle),
                "A collection cycle must inspect between 1 and 4096 panes.");
        }

        ValidateInterval(TerminalReadInterval, nameof(TerminalReadInterval));
        ValidateInterval(ProcessPollInterval, nameof(ProcessPollInterval));
    }

    private static void ValidateInterval(TimeSpan value, string name)
    {
        if (value < TimeSpan.FromMilliseconds(100) || value > TimeSpan.FromMinutes(5))
        {
            throw new ArgumentOutOfRangeException(
                name,
                "Collector intervals must be between 100 milliseconds and 5 minutes.");
        }
    }
}

public sealed record TerminalPreviewCollectionTrace(
    string PaneId,
    string? AgentTerminalId,
    ulong SignaledRevision,
    ulong ReadRevision,
    int MaximumLines,
    string Source,
    string Format,
    bool SourceTruncated,
    DateTimeOffset ObservedUtc,
    string RedactedSummary,
    string RawPayloadSha256,
    string RedactedPayloadSha256,
    int RedactionCount,
    bool SummaryTruncated,
    ActivityPipelineDisposition PipelineDisposition,
    string EventIdentitySha256);

public sealed record ProcessTelemetryCollectionTrace(
    WindowsProcessTelemetryObservation Observation,
    ActivityPipelineDisposition PipelineDisposition,
    string EventIdentitySha256);

public sealed record HerdrPaneCollectionFailure(
    string PaneId,
    string Operation,
    string FailureCode);

public sealed record HerdrTerminalProcessCollectionCycle(
    DateTimeOffset StartedUtc,
    DateTimeOffset FinishedUtc,
    bool Connected,
    int AvailablePaneCount,
    int InspectedPaneCount,
    int SkippedPaneCount,
    int TerminalReadAttemptCount,
    int ProcessPollAttemptCount,
    IReadOnlyList<TerminalPreviewCollectionTrace> TerminalPreviews,
    IReadOnlyList<ProcessTelemetryCollectionTrace> ProcessTelemetry,
    IReadOnlyList<WindowsProcessCorrelationFailure> ProcessFailures,
    IReadOnlyList<HerdrPaneCollectionFailure> CollectionFailures);

/// <summary>
/// Performs one bounded, read-only inspection cycle over an already admitted Herdr runtime.
/// Raw terminal text and raw command lines exist only inside the call stack and are redacted
/// before activity events or trace records are produced.
/// </summary>
public sealed class HerdrTerminalProcessCollector
{
    private readonly object _processPollGate = new();
    private readonly IHerdrPaneInspectionClient _paneClient;
    private readonly HerdrPipeEndpoint _endpoint;
    private readonly HerdrTerminalProcessCollectorOptions _options;
    private readonly TerminalReadPlanner _terminalPlanner;
    private readonly SensitiveTextRedactor _redactor;
    private readonly WindowsProcessCorrelationCollector _processCollector;
    private readonly ActivityEventPipeline _activityPipeline;
    private readonly TimeProvider _timeProvider;
    private readonly Dictionary<string, DateTimeOffset> _lastProcessPollUtc = new(StringComparer.Ordinal);

    public HerdrTerminalProcessCollector(
        IHerdrPaneInspectionClient paneClient,
        HerdrPipeEndpoint endpoint,
        HerdrTerminalProcessCollectorOptions? options = null,
        SensitiveTextRedactor? redactor = null,
        WindowsProcessCorrelationCollector? processCollector = null,
        ActivityEventPipeline? activityPipeline = null,
        TimeProvider? timeProvider = null)
    {
        _paneClient = paneClient ?? throw new ArgumentNullException(nameof(paneClient));
        _endpoint = endpoint ?? throw new ArgumentNullException(nameof(endpoint));
        _options = options ?? HerdrTerminalProcessCollectorOptions.Default;
        _options.Validate();
        _terminalPlanner = new TerminalReadPlanner(new TerminalReadPlannerOptions(
            _options.MaximumTerminalLines,
            _options.MaximumPanesPerCycle,
            _options.TerminalReadInterval));
        _redactor = redactor ?? new SensitiveTextRedactor();
        _processCollector = processCollector ?? new WindowsProcessCorrelationCollector(redactor: _redactor);
        _activityPipeline = activityPipeline ?? new ActivityEventPipeline();
        _timeProvider = timeProvider ?? TimeProvider.System;
    }

    public async Task<HerdrTerminalProcessCollectionCycle> CollectOnceAsync(
        HerdrRuntimeMonitorSnapshot monitorSnapshot,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(monitorSnapshot);
        var startedUtc = _timeProvider.GetUtcNow();
        if (monitorSnapshot.Status != HerdrRuntimeMonitorStatus.Connected)
        {
            return EmptyCycle(startedUtc, connected: false, monitorSnapshot.State.Panes.Count);
        }

        var panes = monitorSnapshot.State.Panes.Values
            .OrderBy(pane => pane.PaneId, StringComparer.Ordinal)
            .Take(_options.MaximumPanesPerCycle)
            .ToArray();
        var terminalTraces = new List<TerminalPreviewCollectionTrace>();
        var processTraces = new List<ProcessTelemetryCollectionTrace>();
        var processFailures = new List<WindowsProcessCorrelationFailure>();
        var collectionFailures = new List<HerdrPaneCollectionFailure>();
        var terminalAttempts = 0;
        var processAttempts = 0;
        foreach (var pane in panes)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var paneObservedUtc = _timeProvider.GetUtcNow();
            var decision = _terminalPlanner.Evaluate(pane.PaneId, pane.Revision, paneObservedUtc);
            if (decision.ShouldRead)
            {
                terminalAttempts++;
                try
                {
                    var read = await _paneClient.ReadRecentUnwrappedAsync(
                            _endpoint,
                            pane.PaneId,
                            decision.MaximumLines,
                            cancellationToken)
                        .ConfigureAwait(false);
                    var readObservedUtc = _timeProvider.GetUtcNow();
                    var observation = TerminalPreviewSanitizer.Sanitize(
                        new TerminalPreviewPayload(
                            pane.PaneId,
                            pane.TerminalId,
                            read.Revision,
                            read.Truncated,
                            read.Text,
                            readObservedUtc),
                        _redactor);
                    _terminalPlanner.RecordSuccess(pane.PaneId, read.Revision, readObservedUtc);
                    var pipelineStep = _activityPipeline.Process(CreateTerminalEvent(
                        monitorSnapshot,
                        observation));
                    terminalTraces.Add(new TerminalPreviewCollectionTrace(
                        pane.PaneId,
                        pane.TerminalId,
                        pane.Revision,
                        read.Revision,
                        decision.MaximumLines,
                        read.Source,
                        read.Format,
                        read.Truncated,
                        readObservedUtc,
                        observation.RedactedSummary,
                        observation.RawPayloadSha256,
                        observation.RedactedPayloadSha256,
                        observation.RedactionCount,
                        observation.SummaryTruncated,
                        pipelineStep.Disposition,
                        pipelineStep.Event.EventIdentitySha256));
                }
                catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
                {
                    throw;
                }
                catch (Exception exception) when (IsExpectedInspectionFailure(exception))
                {
                    collectionFailures.Add(new HerdrPaneCollectionFailure(
                        pane.PaneId,
                        "pane.read",
                        MapFailureCode(exception)));
                }
            }

            paneObservedUtc = _timeProvider.GetUtcNow();
            if (!TryBeginProcessPoll(pane.PaneId, paneObservedUtc))
            {
                continue;
            }

            processAttempts++;
            try
            {
                var processInfo = await _paneClient.GetPaneProcessInfoAsync(
                        _endpoint,
                        pane.PaneId,
                        cancellationToken)
                    .ConfigureAwait(false);
                var processObservedUtc = _timeProvider.GetUtcNow();
                var batch = _processCollector.Collect(processInfo, processObservedUtc);
                processFailures.AddRange(batch.Failures);
                foreach (var observation in batch.Observations)
                {
                    var pipelineStep = _activityPipeline.Process(CreateProcessEvent(
                        monitorSnapshot,
                        observation));
                    processTraces.Add(new ProcessTelemetryCollectionTrace(
                        observation,
                        pipelineStep.Disposition,
                        pipelineStep.Event.EventIdentitySha256));
                }
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                throw;
            }
            catch (Exception exception) when (IsExpectedInspectionFailure(exception))
            {
                collectionFailures.Add(new HerdrPaneCollectionFailure(
                    pane.PaneId,
                    "pane.process_info",
                    MapFailureCode(exception)));
            }
        }

        return new HerdrTerminalProcessCollectionCycle(
            startedUtc,
            _timeProvider.GetUtcNow(),
            Connected: true,
            monitorSnapshot.State.Panes.Count,
            panes.Length,
            Math.Max(0, monitorSnapshot.State.Panes.Count - panes.Length),
            terminalAttempts,
            processAttempts,
            terminalTraces.AsReadOnly(),
            processTraces.AsReadOnly(),
            processFailures.AsReadOnly(),
            collectionFailures.AsReadOnly());
    }

    private HerdrTerminalProcessCollectionCycle EmptyCycle(
        DateTimeOffset startedUtc,
        bool connected,
        int availablePaneCount) =>
        new(
            startedUtc,
            _timeProvider.GetUtcNow(),
            connected,
            availablePaneCount,
            InspectedPaneCount: 0,
            SkippedPaneCount: availablePaneCount,
            TerminalReadAttemptCount: 0,
            ProcessPollAttemptCount: 0,
            TerminalPreviews: [],
            ProcessTelemetry: [],
            ProcessFailures: [],
            CollectionFailures: []);

    private bool TryBeginProcessPoll(string paneId, DateTimeOffset observedUtc)
    {
        lock (_processPollGate)
        {
            if (_lastProcessPollUtc.TryGetValue(paneId, out var lastPollUtc) &&
                observedUtc < lastPollUtc + _options.ProcessPollInterval)
            {
                return false;
            }

            if (!_lastProcessPollUtc.ContainsKey(paneId) &&
                _lastProcessPollUtc.Count >= _options.MaximumPanesPerCycle)
            {
                var oldest = _lastProcessPollUtc
                    .OrderBy(item => item.Value)
                    .ThenBy(item => item.Key, StringComparer.Ordinal)
                    .First();
                _lastProcessPollUtc.Remove(oldest.Key);
            }

            _lastProcessPollUtc[paneId] = observedUtc;
            return true;
        }
    }

    private ActivityEventEnvelope CreateTerminalEvent(
        HerdrRuntimeMonitorSnapshot monitorSnapshot,
        TerminalPreviewObservation observation)
    {
        var paneToken = CreateStableToken(observation.PaneId);
        var sourceEventId = $"pane-read:{paneToken}:{observation.Revision}:{observation.RedactedPayloadSha256[..16]}";
        return new ActivityEventEnvelope(
            ActivityEventContract.Version,
            sourceEventId,
            ActivitySourceKind.Herdr,
            $"herdr-pane:{paneToken}",
            monitorSnapshot.State.ConnectionEpoch.ToString(CultureInfo.InvariantCulture),
            observation.Revision is > 0 and <= long.MaxValue
                ? checked((long)observation.Revision)
                : null,
            ActivityConfidence.Observed,
            ActivityUrgency.Normal,
            ActivityDeliveryMode.Debounced,
            "terminal.preview",
            observation.ObservedUtc,
            observation.ObservedUtc,
            CreateDeterministicCorrelationId(sourceEventId),
            $"terminal:{paneToken}",
            observation.AgentTerminalId,
            observation.PaneId,
            null,
            null,
            observation.RedactedSummary,
            observation.RedactedPayloadSha256);
    }

    private ActivityEventEnvelope CreateProcessEvent(
        HerdrRuntimeMonitorSnapshot monitorSnapshot,
        WindowsProcessTelemetryObservation observation)
    {
        var paneToken = CreateStableToken(observation.PaneId);
        var sourceEventId = string.Create(
            CultureInfo.InvariantCulture,
            $"process:{paneToken}:{observation.ProcessId}:{observation.ProcessStartUtc.UtcTicks}:{observation.ObservedUtc.UtcTicks}");
        var cpu = observation.CpuPercent is { } cpuPercent
            ? cpuPercent.ToString("0.###", CultureInfo.InvariantCulture) + "%"
            : "pending";
        var summary = _redactor.Redact(string.Create(
            CultureInfo.InvariantCulture,
            $"{observation.ProcessName} pid={observation.ProcessId} cpu={cpu} working_set={observation.WorkingSetBytes} command={observation.RedactedCommandSummary}"));
        var payload = JsonSerializer.SerializeToUtf8Bytes(observation);
        return new ActivityEventEnvelope(
            ActivityEventContract.Version,
            sourceEventId,
            ActivitySourceKind.WindowsProcess,
            $"windows-process:{observation.ProcessId}",
            observation.ProcessStartUtc.UtcTicks.ToString(CultureInfo.InvariantCulture),
            null,
            ActivityConfidence.Correlated,
            ActivityUrgency.Normal,
            ActivityDeliveryMode.Debounced,
            "process.telemetry",
            observation.ObservedUtc,
            observation.ObservedUtc,
            CreateDeterministicCorrelationId(sourceEventId),
            $"process:{paneToken}:{observation.ProcessId}",
            null,
            observation.PaneId,
            null,
            observation.ProcessId,
            summary.RedactedText,
            Convert.ToHexString(SHA256.HashData(payload)));
    }

    private static Guid CreateDeterministicCorrelationId(string value)
    {
        var hash = SHA256.HashData(Encoding.UTF8.GetBytes(value));
        return new Guid(hash.AsSpan(0, 16));
    }

    private static string CreateStableToken(string value) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value)))[..24];

    private static bool IsExpectedInspectionFailure(Exception exception) => exception is
        IOException or
        TimeoutException or
        UnauthorizedAccessException or
        ArgumentException or
        InvalidOperationException;

    private static string MapFailureCode(Exception exception) => exception switch
    {
        HerdrApiErrorException => "HerdrApiError",
        HerdrProtocolException => "HerdrProtocolRejected",
        TimeoutException => "TimedOut",
        UnauthorizedAccessException => "AccessDenied",
        ArgumentOutOfRangeException => "BoundRejected",
        ArgumentException => "InputRejected",
        InvalidOperationException => "StateRejected",
        IOException => "TransportUnavailable",
        _ => "InspectionFailed",
    };
}
