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
    public string ScoreLabel => Score is { } value
        ? value.ToString(System.Globalization.CultureInfo.InvariantCulture)
        : "—";

    public string ScoreWithMaximumLabel => Score is { } value
        ? $"{value}/100"
        : UiLanguageService.Shared["ValueUnknown"];
}

public sealed record WidgetNotice(
    string AgentName,
    string Message,
    string Time,
    string IconGlyph,
    string StatusBrushKey,
    string State);

public sealed record WidgetActivity(string Time, string Description);

public sealed record WidgetLatencySnapshot(
    int SampleCount,
    double? LastMilliseconds,
    double? P95Milliseconds);

public sealed class WidgetUpdateTelemetry
{
    private const int MaximumSamples = 512;
    private readonly object _sync = new();
    private readonly Queue<double> _samples = new(MaximumSamples);

    public void Record(TimeSpan latency)
    {
        if (latency < TimeSpan.Zero || !double.IsFinite(latency.TotalMilliseconds))
        {
            throw new ArgumentOutOfRangeException(
                nameof(latency),
                "Widget update latency must be finite and non-negative.");
        }

        lock (_sync)
        {
            if (_samples.Count == MaximumSamples)
            {
                _samples.Dequeue();
            }

            _samples.Enqueue(latency.TotalMilliseconds);
        }
    }

    public WidgetLatencySnapshot Snapshot()
    {
        lock (_sync)
        {
            if (_samples.Count == 0)
            {
                return new WidgetLatencySnapshot(0, null, null);
            }

            var ordered = _samples.Order().ToArray();
            var percentileIndex = Math.Max(0, (int)Math.Ceiling(ordered.Length * 0.95) - 1);
            return new WidgetLatencySnapshot(
                ordered.Length,
                _samples.Last(),
                ordered[percentileIndex]);
        }
    }
}
