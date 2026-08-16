using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using HerdrOps.App.Live;
using HerdrOps.App.Localization;
using HerdrOps.Domain.Summaries;
using HerdrOps.Contracts;

namespace HerdrOps.App.Summaries;

public static class DailySummaryBrushKeys
{
    public const string Primary = "HerdrOps.Brush.Chart.Primary";
    public const string Working = "HerdrOps.Brush.Chart.Working";
    public const string Review = "HerdrOps.Brush.Chart.Review";
    public const string Blocked = "HerdrOps.Brush.Chart.Blocked";
    public const string Idle = "HerdrOps.Brush.Chart.Idle";
    public const string Evidence = "HerdrOps.Brush.TextMuted";
}

public sealed record DailySummarySummaryCard(
    string Id,
    string Title,
    string Value,
    string Detail,
    string IconGlyph,
    string AccentBrushKey,
    IReadOnlyList<string> SourceIds);

public sealed record DailySummaryHighlightRow(
    string Id,
    string Workstream,
    string Summary,
    string SourceLabel,
    IReadOnlyList<string> SourceIds,
    string AccentBrushKey);

public sealed record DailySummaryIssueRow(
    string Id,
    string Description,
    string OccurrenceLabel,
    string SourceLabel,
    IReadOnlyList<string> SourceIds,
    string AccentBrushKey);

public sealed record DailySummaryActionRow(
    int Number,
    string Description,
    string SourceLabel,
    IReadOnlyList<string> SourceIds,
    string AccentBrushKey);

public sealed record DailySummaryTimelineRow(
    string Time,
    string Category,
    string Summary,
    string SourceLabel,
    IReadOnlyList<string> SourceIds,
    string AccentBrushKey);

public sealed record DailySummaryWorkstreamRow(
    string Workstream,
    string StatusLabel,
    string SourceCountLabel,
    string ActivityEvidenceLabel,
    string ProgressLabel,
    string ScoreLabel,
    string ImportantLabel,
    IReadOnlyList<string> SourceIds,
    string AccentBrushKey);

/// <summary>
/// Presentation projection for the deterministic Daily Summary aggregate.
/// Synthetic mode is intentionally explicit; live mode is unavailable until a
/// runtime collector admits an authoritative snapshot.
/// </summary>
public sealed class DailySummaryState : ObservableState
{
    private readonly bool _syntheticPreview;
    private readonly DailySummarySnapshot? _snapshot;
    private string _sourceLabel = string.Empty;
    private string _boundaryLabel = string.Empty;
    private string _dateLabel = string.Empty;
    private string _sourceSetLabel = string.Empty;
    private string _resultLabel = string.Empty;
    private IReadOnlyList<DailySummarySummaryCard> _summaryCards = [];
    private IReadOnlyList<DailySummaryHighlightRow> _highlights = [];
    private IReadOnlyList<DailySummaryHighlightRow> _strengths = [];
    private IReadOnlyList<DailySummaryHighlightRow> _areasToImprove = [];
    private IReadOnlyList<DailySummaryIssueRow> _repeatedIssues = [];
    private IReadOnlyList<DailySummaryActionRow> _recommendedActions = [];
    private IReadOnlyList<DailySummaryTimelineRow> _timeline = [];
    private IReadOnlyList<DailySummaryWorkstreamRow> _workstreams = [];

    private DailySummaryState(bool syntheticPreview)
    {
        _syntheticPreview = syntheticPreview;
        EvidenceClass = syntheticPreview ? EvidenceClass.Synthetic : EvidenceClass.Contract;
        _snapshot = syntheticPreview ? CreateSnapshot() : null;
        RefreshLanguage();
    }

    public static DailySummaryState CreateSyntheticPreview() => new(syntheticPreview: true);

    public static DailySummaryState CreateUnavailable() => new(syntheticPreview: false);

    public EvidenceClass EvidenceClass { get; }

    public bool IsSyntheticPreview => _syntheticPreview;

    public DailySummarySnapshot? Snapshot => _snapshot;

    public string SourceLabel
    {
        get => _sourceLabel;
        private set => Set(ref _sourceLabel, value);
    }

    public string BoundaryLabel
    {
        get => _boundaryLabel;
        private set => Set(ref _boundaryLabel, value);
    }

    public string DateLabel
    {
        get => _dateLabel;
        private set => Set(ref _dateLabel, value);
    }

    public string SourceSetLabel
    {
        get => _sourceSetLabel;
        private set => Set(ref _sourceSetLabel, value);
    }

    public string ResultLabel
    {
        get => _resultLabel;
        private set => Set(ref _resultLabel, value);
    }

    public IReadOnlyList<DailySummarySummaryCard> SummaryCards
    {
        get => _summaryCards;
        private set => Set(ref _summaryCards, value);
    }

    public IReadOnlyList<DailySummaryHighlightRow> Highlights
    {
        get => _highlights;
        private set => Set(ref _highlights, value);
    }

    public IReadOnlyList<DailySummaryHighlightRow> Strengths
    {
        get => _strengths;
        private set => Set(ref _strengths, value);
    }

    public IReadOnlyList<DailySummaryHighlightRow> AreasToImprove
    {
        get => _areasToImprove;
        private set => Set(ref _areasToImprove, value);
    }

    public IReadOnlyList<DailySummaryIssueRow> RepeatedIssues
    {
        get => _repeatedIssues;
        private set => Set(ref _repeatedIssues, value);
    }

    public IReadOnlyList<DailySummaryActionRow> RecommendedActions
    {
        get => _recommendedActions;
        private set => Set(ref _recommendedActions, value);
    }

    public IReadOnlyList<DailySummaryTimelineRow> Timeline
    {
        get => _timeline;
        private set => Set(ref _timeline, value);
    }

    public IReadOnlyList<DailySummaryWorkstreamRow> Workstreams
    {
        get => _workstreams;
        private set => Set(ref _workstreams, value);
    }

    public string DailyScoreLabel => "—";

    public string DailyScoreDetail => UiLanguageService.Shared["DailySummaryNoScore"];

    public void RefreshLanguage()
    {
        var text = UiLanguageService.Shared;
        SourceLabel = _syntheticPreview
            ? text["DailySummarySyntheticSource"]
            : text["DailySummaryLiveSourceUnavailable"];
        BoundaryLabel = _syntheticPreview
            ? text["DailySummarySyntheticBoundary"]
            : text["DailySummaryLiveBoundary"];
        DateLabel = _snapshot is null
            ? "—"
            : _snapshot.LocalDate.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
        SourceSetLabel = _snapshot is null
            ? "—"
            : text.Format("DailySummarySourceSetFormat", _snapshot.AcceptedSources.Count, _snapshot.SourceSetSha256);
        ResultLabel = _snapshot is null
            ? "—"
            : text.Format("DailySummaryResultFormat", _snapshot.ResultSha256);
        SummaryCards = CreateSummaryCards(text);
        Highlights = CreateHighlights(text);
        Strengths = CreateStrengths(text);
        AreasToImprove = CreateAreasToImprove(text);
        RepeatedIssues = CreateRepeatedIssues(text);
        RecommendedActions = CreateRecommendedActions(text);
        Timeline = CreateTimeline(text);
        Workstreams = CreateWorkstreams(text);
        Raise(nameof(DailyScoreDetail));
    }

    private IReadOnlyList<DailySummarySummaryCard> CreateSummaryCards(UiLanguageService text)
    {
        if (_snapshot is null)
        {
            return
            [
                Card("accepted-sources", "DailySummaryAcceptedSources", "—", "DailySummaryNoLiveData", "\uE8A5", DailySummaryBrushKeys.Primary, []),
                Card("activity-events", "DailySummaryActivityEvents", "—", "DailySummaryNoLiveData", "\uE9D9", DailySummaryBrushKeys.Working, []),
                Card("evidence-items", "DailySummaryEvidenceItems", "—", "DailySummaryNoLiveData", "\uE8B7", DailySummaryBrushKeys.Evidence, []),
                Card("highlights", "DailySummaryHighlights", "—", "DailySummaryNoLiveData", "\uE734", DailySummaryBrushKeys.Review, []),
                Card("recommended-actions", "DailySummaryRecommendedActions", "—", "DailySummaryNoLiveData", "\uE73D", DailySummaryBrushKeys.Idle, []),
            ];
        }

        return
        [
            CardFromMetric("accepted-sources", "DailySummaryAcceptedSources", "\uE8A5", DailySummaryBrushKeys.Primary, text),
            CardFromMetric("activity-events", "DailySummaryActivityEvents", "\uE9D9", DailySummaryBrushKeys.Working, text),
            CardFromMetric("evidence-items", "DailySummaryEvidenceItems", "\uE8B7", DailySummaryBrushKeys.Evidence, text),
            CardFromMetric("highlights", "DailySummaryHighlights", "\uE734", DailySummaryBrushKeys.Review, text),
            CardFromMetric("recommended-actions", "DailySummaryRecommendedActions", "\uE73D", DailySummaryBrushKeys.Idle, text),
        ];
    }

    private DailySummarySummaryCard CardFromMetric(
        string metricId,
        string titleKey,
        string iconGlyph,
        string brushKey,
        UiLanguageService text)
    {
        var metric = _snapshot!.Metrics.Single(item => item.MetricId == metricId);
        return Card(
            metricId,
            titleKey,
            metric.Value.ToString("N0", CultureInfo.CurrentCulture),
            "DailySummaryMetricSourceFormat",
            iconGlyph,
            brushKey,
            metric.SourceIds,
            text,
            metric.SourceIds.Count);
    }

    private DailySummarySummaryCard Card(
        string id,
        string titleKey,
        string value,
        string detailKey,
        string iconGlyph,
        string brushKey,
        IReadOnlyList<string> sourceIds,
        UiLanguageService? text = null,
        int? sourceCount = null) =>
        new(
            id,
            (text ?? UiLanguageService.Shared)[titleKey],
            value,
            text is null
                ? (UiLanguageService.Shared[detailKey])
                : (sourceCount is null
                    ? text[detailKey]
                    : text.Format(detailKey, sourceCount.Value)),
            iconGlyph,
            brushKey,
            sourceIds);

    private IReadOnlyList<DailySummaryHighlightRow> CreateHighlights(UiLanguageService text)
    {
        if (_snapshot is null)
        {
            return [];
        }

        return _snapshot.Highlights
            .Select(item => new DailySummaryHighlightRow(
                item.SourceId,
                item.Workstream,
                LocalizedSummary(item.SourceId, text),
                SourceLabelFor(item.SourceIds, text),
                item.SourceIds,
                DailySummaryBrushKeys.Working))
            .ToArray();
    }

    private IReadOnlyList<DailySummaryHighlightRow> CreateStrengths(UiLanguageService text) =>
        _snapshot is null
            ? []
            : [
                new("strength-backend", "Backend", text["DailySummaryStrengthBackend"], SourceLabelFor(BackendSources(), text), BackendSources(), DailySummaryBrushKeys.Working),
                new("strength-evidence", "Evidence", text["DailySummaryStrengthEvidence"], SourceLabelFor(EvidenceSources(), text), EvidenceSources(), DailySummaryBrushKeys.Primary),
                new("strength-review", "Review", text["DailySummaryStrengthReview"], SourceLabelFor(ReviewSources(), text), ReviewSources(), DailySummaryBrushKeys.Review),
            ];

    private IReadOnlyList<DailySummaryHighlightRow> CreateAreasToImprove(UiLanguageService text) =>
        _snapshot is null
            ? []
            : [
                new("area-api-latency", "Backend", text["DailySummaryAreaApiLatency"], SourceLabelFor(SourcesForIssue("api-latency"), text), SourcesForIssue("api-latency"), DailySummaryBrushKeys.Idle),
                new("area-missing-test", "Frontend", text["DailySummaryAreaMissingTest"], SourceLabelFor(SourcesForIssue("missing-test"), text), SourcesForIssue("missing-test"), DailySummaryBrushKeys.Idle),
                new("area-evidence", "Testing", text["DailySummaryAreaEvidence"], SourceLabelFor(EvidenceSources(), text), EvidenceSources(), DailySummaryBrushKeys.Idle),
            ];

    private IReadOnlyList<DailySummaryIssueRow> CreateRepeatedIssues(UiLanguageService text) =>
        _snapshot is null
            ? []
            : _snapshot.RepeatedIssues.Select(item => new DailySummaryIssueRow(
                item.IssueKey,
                text["DailySummaryIssueApiLatency"],
                text.Format("DailySummaryOccurrenceFormat", item.OccurrenceCount),
                SourceLabelFor(item.SourceIds, text),
                item.SourceIds,
                DailySummaryBrushKeys.Blocked)).ToArray();

    private IReadOnlyList<DailySummaryActionRow> CreateRecommendedActions(UiLanguageService text) =>
        _snapshot is null
            ? []
            : _snapshot.RecommendedActions
                .Select((item, index) => new DailySummaryActionRow(
                    index + 1,
                    item.ActionKey == "Review API latency"
                        ? text["DailySummaryActionReviewApiLatency"]
                        : text["DailySummaryActionAddMissingTest"],
                    SourceLabelFor(item.SourceIds, text),
                    item.SourceIds,
                    DailySummaryBrushKeys.Primary))
                .ToArray();

    private IReadOnlyList<DailySummaryTimelineRow> CreateTimeline(UiLanguageService text) =>
        _snapshot is null
            ? []
            : _snapshot.Timeline.Select(item => new DailySummaryTimelineRow(
                item.OccurredLocal.ToString("HH:mm", CultureInfo.InvariantCulture),
                item.Category,
                LocalizedSummary(item.SourceId, text),
                SourceLabelFor([item.SourceId], text),
                [item.SourceId],
                BrushForCategory(item.Category))).ToArray();

    private IReadOnlyList<DailySummaryWorkstreamRow> CreateWorkstreams(UiLanguageService text) =>
        _snapshot is null
            ? []
            : _snapshot.Workstreams.Select(item => new DailySummaryWorkstreamRow(
                item.Workstream,
                text["DailySummaryAcceptedStatus"],
                text.Format("DailySummarySourceCountFormat", item.AcceptedSourceCount),
                text.Format("DailySummaryActivityEvidenceFormat", item.ActivityCount, item.EvidenceCount),
                text["DailySummaryProgressNotAvailable"],
                text["DailySummaryNoScore"],
                LatestWorkstreamSummary(item.Workstream, text),
                item.SourceIds,
                WorkstreamBrush(item.Workstream))).ToArray();

    private string SourceLabelFor(IEnumerable<string> sourceIds, UiLanguageService text)
    {
        var count = sourceIds.Distinct(StringComparer.Ordinal).Count();
        return text.Format("DailySummarySourceCountFormat", count);
    }

    private string LocalizedSummary(string sourceId, UiLanguageService text) => sourceId switch
    {
        "activity-001" => text["DailySummaryActivity001"],
        "activity-002" => text["DailySummaryActivity002"],
        "activity-003" => text["DailySummaryActivity003"],
        "activity-004" => text["DailySummaryActivity004"],
        "evidence-001" => text["DailySummaryEvidence001"],
        _ => text["DailySummaryNoSummary"],
    };

    private string LatestWorkstreamSummary(string workstream, UiLanguageService text) =>
        _snapshot!.Timeline
            .Where(item => string.Equals(item.Workstream, workstream, StringComparison.Ordinal))
            .OrderByDescending(item => item.OccurredLocal)
            .Select(item => LocalizedSummary(item.SourceId, text))
            .FirstOrDefault() ?? text["DailySummaryNoSummary"];

    private IReadOnlyList<string> BackendSources() => SourcesForWorkstream("Backend");

    private IReadOnlyList<string> EvidenceSources() =>
        _snapshot!.AcceptedSources
            .Where(item => item.Kind == DailySummarySourceKind.Evidence)
            .Select(item => item.SourceId)
            .OrderBy(item => item, StringComparer.Ordinal)
            .ToArray();

    private IReadOnlyList<string> ReviewSources() =>
        _snapshot!.Timeline
            .Where(item => item.Category == "ReviewRequested" || item.Category == "Review")
            .Select(item => item.SourceId)
            .OrderBy(item => item, StringComparer.Ordinal)
            .ToArray();

    private IReadOnlyList<string> SourcesForIssue(string issueKey) =>
        _snapshot!.RepeatedIssues
            .Where(item => item.IssueKey == issueKey)
            .SelectMany(item => item.SourceIds)
            .Distinct(StringComparer.Ordinal)
            .OrderBy(item => item, StringComparer.Ordinal)
            .ToArray();

    private IReadOnlyList<string> SourcesForWorkstream(string workstream) =>
        _snapshot!.Workstreams
            .Where(item => item.Workstream == workstream)
            .SelectMany(item => item.SourceIds)
            .Distinct(StringComparer.Ordinal)
            .OrderBy(item => item, StringComparer.Ordinal)
            .ToArray();

    private static string BrushForCategory(string category) => category switch
    {
        "ReviewRequested" or "Review" => DailySummaryBrushKeys.Review,
        "TestResult" or "EvidenceSubmitted" => DailySummaryBrushKeys.Working,
        _ => DailySummaryBrushKeys.Primary,
    };

    private static string WorkstreamBrush(string workstream) => workstream switch
    {
        "Backend" => DailySummaryBrushKeys.Working,
        "Frontend" => DailySummaryBrushKeys.Primary,
        "Testing" => DailySummaryBrushKeys.Review,
        _ => DailySummaryBrushKeys.Evidence,
    };

    private static DailySummarySnapshot CreateSnapshot()
    {
        var sources = new DailySummarySource[]
        {
            Source("activity-001", DailySummarySourceKind.ActivityEvent, "2026-08-14T17:00:00+00:00", "Backend", "backend-worker-01", "TASK-115", "TaskStarted", "Started Auth Service work", true, true, "api-latency", "Review API latency"),
            Source("activity-002", DailySummarySourceKind.ActivityEvent, "2026-08-15T03:15:00+00:00", "Backend", "backend-leader", "TASK-115", "ReviewRequested", "API latency review requested", true, false, "api-latency", "Review API latency"),
            Source("evidence-001", DailySummarySourceKind.Evidence, "2026-08-15T04:00:00+00:00", "Backend", "backend-worker-01", "TASK-115", "TestResult", "Authentication service tests passed", true, false, null, null),
            Source("activity-003", DailySummarySourceKind.ActivityEvent, "2026-08-15T09:30:00+00:00", "Frontend", "frontend-worker-01", "TASK-118", "Review", "Login review found a missing test", true, true, "missing-test", "Add missing test"),
            Source("activity-004", DailySummarySourceKind.ActivityEvent, "2026-08-15T16:59:00+00:00", "Testing", "test-worker-01", "TASK-120", "EvidenceSubmitted", "Unit test report submitted", true, false, null, null),
            Source("evidence-002", DailySummarySourceKind.Evidence, "2026-08-15T17:00:00+00:00", "DevOps", "devops-worker-01", "TASK-122", "Deployment", "Deployment evidence belongs to the next local day", true, false, null, null),
        };

        return DailySummaryAggregator.Aggregate(
            new DateOnly(2026, 8, 15),
            TimeZoneInfo.CreateCustomTimeZone("Asia/Bangkok", TimeSpan.FromHours(7), "Bangkok", "Bangkok"),
            sources);
    }

    private static DailySummarySource Source(
        string sourceId,
        DailySummarySourceKind kind,
        string occurredUtc,
        string workstream,
        string agentId,
        string taskId,
        string category,
        string summary,
        bool accepted,
        bool highlight,
        string? issueKey,
        string? recommendedAction)
    {
        var occurred = DateTimeOffset.Parse(
            occurredUtc,
            CultureInfo.InvariantCulture,
            DateTimeStyles.AssumeUniversal);
        var canonical = string.Join(
            '\u001F',
            sourceId,
            ((int)kind).ToString(CultureInfo.InvariantCulture),
            occurred.ToUniversalTime().ToString("O", CultureInfo.InvariantCulture),
            workstream,
            agentId,
            taskId,
            category,
            summary,
            accepted ? "1" : "0",
            highlight ? "1" : "0",
            issueKey ?? string.Empty,
            recommendedAction ?? string.Empty);
        var sourceHash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(canonical)));
        return new DailySummarySource(
            sourceId,
            kind,
            sourceHash,
            occurred,
            workstream,
            agentId,
            taskId,
            category,
            summary,
            accepted,
            highlight,
            issueKey,
            recommendedAction);
    }
}
