using HerdrOps.Contracts;
using HerdrOps.App.Localization;

namespace HerdrOps.App.Widgets;

public interface IWidgetState
{
    EvidenceClass EvidenceClass { get; }

    bool IsLive { get; }

    string SourceLabel { get; }

    string CompactSourceLabel { get; }

    string ConnectionLabel { get; }

    string CompactConnectionLabel { get; }

    string ConnectionBrushKey { get; }

    string GalleryDescription { get; }

    string DashboardPreviewLabel { get; }

    string WindowTitleSuffix { get; }

    string DetailsSourceLabel { get; }

    DateTimeOffset SnapshotAt { get; }

    long Sequence { get; }

    int TotalAgents { get; }

    int WorkingCount { get; }

    int BlockedCount { get; }

    int DoneCount { get; }

    string WorkingCountLabel { get; }

    string BlockedCountLabel { get; }

    string DoneCountLabel { get; }

    string DailyScoreLabel { get; }

    string PositiveDeltaLabel { get; }

    string NegativeDeltaLabel { get; }

    string LatencyLabel { get; }

    int UpdateSampleCount { get; }

    double? LastUpdateLatencyMilliseconds { get; }

    double? P95UpdateLatencyMilliseconds { get; }

    IReadOnlyList<WidgetAgent> Agents { get; }

    IReadOnlyList<WidgetNotice> Notices { get; }

    IReadOnlyList<WidgetNotice> PriorityNotices { get; }

    WidgetAgent SelectedAgent { get; }

    IReadOnlyList<WidgetActivity> SelectedAgentActivity { get; }
}

public interface IInteractiveWidgetState : IWidgetState
{
    bool AcknowledgeNotificationGroup(string groupId, DateTimeOffset acknowledgedUtc);
}

public sealed record WidgetAgent(
    string TerminalId,
    string Initials,
    string Name,
    string Role,
    string AssignedBy,
    string Activity,
    string Elapsed,
    int? Score,
    string Status,
    string StatusBrushKey,
    string StartedLabel)
{
    public string? TaskId { get; init; }

    public string LifecycleProvenance { get; init; } = string.Empty;

    public string? ScoreProvenance { get; init; }

    public bool HasTaskAlignment { get; init; }

    public bool CanOpenTaskAlignment =>
        HasTaskAlignment && !string.IsNullOrWhiteSpace(TaskId);

    public string ScoreLabel => Score is { } value
        ? value.ToString(System.Globalization.CultureInfo.InvariantCulture)
        : "—";

    public string ScoreWithMaximumLabel => Score is { } value
        ? $"{value}/100"
        : UiLanguageService.Shared["ValueUnknown"];

    public string AgentDetailsAutomationName => UiLanguageService.Shared.Format(
        "WidgetOpenAgentDetailsAutomationFormat",
        Name);

    public string TaskAlignmentAutomationName => CanOpenTaskAlignment
        ? UiLanguageService.Shared.Format(
            "WidgetOpenTaskAlignmentAutomationFormat",
            TaskId!)
        : UiLanguageService.Shared["WidgetTaskAlignmentUnavailableAutomation"];
}

public sealed record WidgetNotificationRoute(
    string SourceEventId,
    Guid CorrelationId,
    string EventIdentitySha256,
    string? AgentTerminalId,
    string? TaskId);

public sealed record WidgetNotice(
    string AgentName,
    string Message,
    string Time,
    string IconGlyph,
    string StatusBrushKey,
    string State,
    string GroupId = "",
    int GroupCount = 1,
    int UnacknowledgedCount = 0,
    bool IsAcknowledged = false,
    string GroupCountLabel = "",
    string AcknowledgementLabel = "",
    string OpenAutomationName = "",
    string AcknowledgeAutomationName = "",
    WidgetNotificationRoute? Route = null)
{
    public bool CanOpen => Route is not null;

    public bool CanAcknowledge => GroupId.Length > 0 && UnacknowledgedCount > 0;
}

public sealed record WidgetActivity(string Time, string Description);

public sealed record WidgetUpdateLatencySample(
    long StateSequence,
    long EventCount,
    long EnvelopeSequence,
    Guid EnvelopeCorrelationId,
    string StateSha256,
    string UpdateKind,
    DateTimeOffset CoreAcceptedStateUtc,
    DateTimeOffset IpcSentUtc,
    DateTimeOffset WpfAppliedUtc)
{
    public double Milliseconds =>
        (WpfAppliedUtc - CoreAcceptedStateUtc).TotalMilliseconds;
}

public sealed record WidgetLatencySnapshot(
    int SampleCount,
    double? LastMilliseconds,
    double? P95Milliseconds,
    IReadOnlyList<WidgetUpdateLatencySample> Samples);

public sealed class WidgetUpdateTelemetry
{
    private const int MaximumSamples = 512;
    private readonly object _sync = new();
    private readonly Queue<WidgetUpdateLatencySample> _samples = new(MaximumSamples);

    public void Record(WidgetUpdateLatencySample sample)
    {
        ArgumentNullException.ThrowIfNull(sample);
        if (sample.StateSequence < 0 ||
            sample.EventCount < 0 ||
            sample.EnvelopeSequence < 0 ||
            string.IsNullOrWhiteSpace(sample.UpdateKind) ||
            (!string.Equals(sample.UpdateKind, "Unspecified", StringComparison.Ordinal) &&
             (string.IsNullOrWhiteSpace(sample.StateSha256) ||
              sample.StateSha256.Length != 64 ||
              !sample.StateSha256.All(Uri.IsHexDigit))) ||
            (sample.EnvelopeCorrelationId == Guid.Empty &&
             !string.Equals(sample.UpdateKind, "Unspecified", StringComparison.Ordinal)) ||
            (sample.UpdateKind is "Snapshot" or "Delta" &&
             sample.EnvelopeSequence != sample.StateSequence) ||
            sample.CoreAcceptedStateUtc.Offset != TimeSpan.Zero ||
            sample.IpcSentUtc.Offset != TimeSpan.Zero ||
            sample.WpfAppliedUtc.Offset != TimeSpan.Zero ||
            sample.IpcSentUtc < sample.CoreAcceptedStateUtc ||
            sample.WpfAppliedUtc < sample.IpcSentUtc ||
            !double.IsFinite(sample.Milliseconds))
        {
            throw new ArgumentOutOfRangeException(
                nameof(sample),
                "Widget update latency samples require a matching envelope identity, non-negative counters, UTC timestamps in order, and a non-blank update kind.");
        }

        lock (_sync)
        {
            if (_samples.Count == MaximumSamples)
            {
                _samples.Dequeue();
            }

            _samples.Enqueue(sample);
        }
    }

    public void Record(TimeSpan latency)
    {
        if (latency < TimeSpan.Zero || !double.IsFinite(latency.TotalMilliseconds))
        {
            throw new ArgumentOutOfRangeException(
                nameof(latency),
                "Widget update latency must be finite and non-negative.");
        }

        Record(new WidgetUpdateLatencySample(
            StateSequence: 0,
            EventCount: 0,
            EnvelopeSequence: 0,
            EnvelopeCorrelationId: Guid.Empty,
            StateSha256: string.Empty,
            UpdateKind: "Unspecified",
            DateTimeOffset.UnixEpoch,
            DateTimeOffset.UnixEpoch,
            DateTimeOffset.UnixEpoch.Add(latency)));
    }

    public void Reset()
    {
        lock (_sync)
        {
            _samples.Clear();
        }
    }

    public WidgetLatencySnapshot Snapshot()
    {
        lock (_sync)
        {
            if (_samples.Count == 0)
            {
                return new WidgetLatencySnapshot(0, null, null, []);
            }

            var samples = _samples.ToArray();
            var ordered = samples.Select(sample => sample.Milliseconds).Order().ToArray();
            var percentileIndex = Math.Max(0, (int)Math.Ceiling(ordered.Length * 0.95) - 1);
            return new WidgetLatencySnapshot(
                ordered.Length,
                samples[^1].Milliseconds,
                ordered[percentileIndex],
                samples);
        }
    }
}
