using System.Collections.ObjectModel;
using System.Globalization;
using HerdrOps.App.Live;
using HerdrOps.App.Localization;
using HerdrOps.App.Overview;
using HerdrOps.Domain.Evaluation;

namespace HerdrOps.App.Evaluation;

public enum EvaluationSnapshotAvailability
{
    Available = 1,
    Unavailable = 2,
}

/// <summary>
/// The complete input for one deterministic Evaluation presentation refresh.
/// The lists are copied at construction so every chart and table is rendered
/// from one stable snapshot rather than independently sampled collections.
/// </summary>
public sealed class EvaluationSnapshot
{
    public EvaluationSnapshot(
        EvaluationSnapshotAvailability availability,
        IReadOnlyList<EvaluationSnapshotRecord> evaluations,
        IReadOnlyList<EvaluationTrendValue> trend,
        string selectedTaskId,
        string selectedAgentId,
        DateOnly snapshotDate)
    {
        ArgumentNullException.ThrowIfNull(evaluations);
        ArgumentNullException.ThrowIfNull(trend);
        if (string.IsNullOrWhiteSpace(selectedTaskId))
        {
            throw new ArgumentException("A selected task identity is required.", nameof(selectedTaskId));
        }

        if (string.IsNullOrWhiteSpace(selectedAgentId))
        {
            throw new ArgumentException("A selected agent identity is required.", nameof(selectedAgentId));
        }

        Availability = availability;
        Evaluations = Freeze(evaluations);
        Trend = Freeze(trend);
        SelectedTaskId = selectedTaskId;
        SelectedAgentId = selectedAgentId;
        SnapshotDate = snapshotDate;
    }

    public EvaluationSnapshotAvailability Availability { get; }

    public IReadOnlyList<EvaluationSnapshotRecord> Evaluations { get; }

    public IReadOnlyList<EvaluationTrendValue> Trend { get; }

    public string SelectedTaskId { get; }

    public string SelectedAgentId { get; }

    public DateOnly SnapshotDate { get; }

    private static IReadOnlyList<T> Freeze<T>(IEnumerable<T> values) =>
        new ReadOnlyCollection<T>(values.ToArray());
}

public sealed record EvaluationSnapshotRecord(
    string EvaluationId,
    string TaskId,
    string TaskLabel,
    string AgentId,
    string AgentLabel,
    EvaluationScoreResult Result);

public sealed record EvaluationTrendValue(DateOnly Date, decimal? Score);

public sealed record EvaluationSummaryCard(
    string Id,
    string Label,
    string Value,
    string MetricLabel,
    string TrendLabel,
    decimal? Score,
    int? Count,
    decimal? Percentage,
    string AccentBrushKey,
    string AccessibilityText,
    string StatusText);

public sealed record EvaluationDistributionBin(
    string Id,
    string Label,
    int MinimumScore,
    int MaximumScore,
    int Count,
    decimal Percentage,
    string AccentBrushKey,
    string AccessibilityText,
    string StatusText);

public sealed record EvaluationTrendPoint(
    string Id,
    DateOnly Date,
    string DateLabel,
    decimal? Score,
    string ScoreLabel,
    string AccentBrushKey,
    string AccessibilityText,
    string StatusText);

public sealed record EvaluationDimensionRow(
    EvaluationDimension Dimension,
    string Label,
    decimal? Score,
    decimal WeightPercentage,
    string ScoreLabel,
    string StatusLabel,
    string AccentBrushKey,
    string AccessibilityText,
    string StatusText);

public sealed record EvaluationComparisonRow(
    EvaluationScoreSource Source,
    string Label,
    decimal? Score,
    int Count,
    decimal Percentage,
    string ScoreLabel,
    string ProvenanceId,
    string ProvenanceSha256,
    string AccentBrushKey,
    string AccessibilityText,
    string StatusText);

public sealed record EvaluationRankingRow(
    int Rank,
    string AgentId,
    string AgentLabel,
    decimal Score,
    string ScoreLabel,
    bool IsTie,
    string TieLabel,
    string AccentBrushKey,
    string AccessibilityText,
    string StatusText);

/// <summary>
/// Presentation-only Evaluation state. It accepts synthetic/contract data and
/// has no dependency on an installed Herdr runtime.
/// </summary>
public sealed class EvaluationState : ObservableState
{
    private const int PassScore = 60;

    private static readonly IReadOnlyList<EvaluationDimension> Dimensions =
        Enum.GetValues<EvaluationDimension>();

    private static readonly IReadOnlyList<EvaluationScoreSource> Sources =
        Enum.GetValues<EvaluationScoreSource>();

    private readonly EvaluationSnapshot _snapshot;
    private UiLanguage _language;
    private string _sourceLabel = string.Empty;
    private string _evidenceBoundaryLabel = string.Empty;
    private string _evaluationCountLabel = string.Empty;
    private int _evaluationCountTotal;
    private IReadOnlyList<EvaluationSummaryCard> _summaryCards = [];
    private IReadOnlyList<EvaluationDistributionBin> _distributionBins = [];
    private string _distributionTotalLabel = string.Empty;
    private IReadOnlyList<EvaluationTrendPoint> _trendPoints = [];
    private IReadOnlyList<EvaluationDimensionRow> _dimensionRows = [];
    private IReadOnlyList<EvaluationComparisonRow> _comparisonRows = [];
    private IReadOnlyList<EvaluationRankingRow> _topAgents = [];
    private IReadOnlyList<EvaluationRankingRow> _lowAgents = [];
    private string _selectedTaskLabel = string.Empty;
    private string _selectedAgentLabel = string.Empty;
    private string _missingScoreLabel = string.Empty;
    private int _missingScoreCount;

    public EvaluationState(EvaluationSnapshot snapshot)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        _snapshot = snapshot;
        _language = UiLanguageService.Shared.CurrentLanguage;
        Render();
    }

    public EvaluationSnapshot Snapshot => _snapshot;

    public UiLanguage SelectedLanguage => _language;

    public string SourceLabel => _sourceLabel;

    public string EvidenceBoundaryLabel => _evidenceBoundaryLabel;

    public string EvaluationCountLabel => _evaluationCountLabel;

    public int EvaluationCountTotal => _evaluationCountTotal;

    public int EvaluationCount => _evaluationCountTotal;

    public IReadOnlyList<EvaluationSummaryCard> SummaryCards => _summaryCards;

    public IReadOnlyList<EvaluationDistributionBin> DistributionBins => _distributionBins;

    public string DistributionTotalLabel => _distributionTotalLabel;

    public IReadOnlyList<EvaluationTrendPoint> TrendPoints => _trendPoints;

    public IReadOnlyList<EvaluationDimensionRow> DimensionRows => _dimensionRows;

    public IReadOnlyList<EvaluationComparisonRow> ComparisonRows => _comparisonRows;

    public IReadOnlyList<EvaluationRankingRow> TopAgents => _topAgents;

    public IReadOnlyList<EvaluationRankingRow> LowAgents => _lowAgents;

    public string SelectedTaskLabel => _selectedTaskLabel;

    public string SelectedAgentLabel => _selectedAgentLabel;

    public string MissingScoreLabel => _missingScoreLabel;

    public int MissingScoreCount => _missingScoreCount;

    public static EvaluationState CreateSyntheticPreview() =>
        new(CreateSyntheticSnapshot(includeMissingScore: false));

    public static EvaluationState CreateMissingScorePreview() =>
        new(CreateSyntheticSnapshot(includeMissingScore: true));

    public static EvaluationState CreateUnavailable() =>
        new(new EvaluationSnapshot(
            EvaluationSnapshotAvailability.Unavailable,
            [],
            Enumerable.Range(0, 7)
                .Select(offset => new EvaluationTrendValue(
                    new DateOnly(2026, 8, 8).AddDays(offset),
                    null))
                .ToArray(),
            "TASK-118",
            "agent-project-manager",
            new DateOnly(2026, 8, 14)));

    /// <summary>
    /// Re-renders all localized labels from the same immutable snapshot.
    /// Call after changing <see cref="UiLanguageService.CurrentLanguage"/>.
    /// </summary>
    public void RefreshLanguage()
    {
        _language = UiLanguageService.Shared.CurrentLanguage;
        Render();
    }

    private void Render()
    {
        var text = new Copy(_language);
        var selected = _snapshot.Evaluations
            .FirstOrDefault(item =>
                string.Equals(item.TaskId, _snapshot.SelectedTaskId, StringComparison.Ordinal) &&
                string.Equals(item.AgentId, _snapshot.SelectedAgentId, StringComparison.Ordinal));
        var scored = _snapshot.Evaluations
            .Where(HasScore)
            .OrderBy(item => item.EvaluationId, StringComparer.Ordinal)
            .ToArray();

        _sourceLabel = _snapshot.Availability == EvaluationSnapshotAvailability.Unavailable
            ? text.UnavailableSource
            : text.SyntheticSource;
        _evidenceBoundaryLabel = text.EvidenceBoundary;
        _evaluationCountTotal = _snapshot.Evaluations.Count;
        _evaluationCountLabel = text.Count(_evaluationCountTotal);
        _missingScoreCount = _snapshot.Evaluations.Count(item => !HasScore(item));
        _missingScoreLabel = text.MissingScores(_missingScoreCount);
        _selectedTaskLabel = selected is null
            ? text.Unavailable
            : selected.TaskLabel;
        _selectedAgentLabel = selected is null
            ? text.Unavailable
            : selected.AgentLabel;
        _summaryCards = Freeze(BuildSummaryCards(text, scored));
        _distributionBins = Freeze(BuildDistribution(text, scored));
        _distributionTotalLabel = text.ScoredCount(scored.Length);
        _trendPoints = Freeze(BuildTrend(text));
        _dimensionRows = Freeze(BuildDimensions(text, selected));
        _comparisonRows = Freeze(BuildComparison(text, selected));
        _topAgents = Freeze(BuildRankings(text, scored, descending: true));
        _lowAgents = Freeze(BuildRankings(text, scored, descending: false));

        Raise(nameof(SelectedLanguage));
        Raise(nameof(SourceLabel));
        Raise(nameof(EvidenceBoundaryLabel));
        Raise(nameof(EvaluationCountLabel));
        Raise(nameof(EvaluationCountTotal));
        Raise(nameof(EvaluationCount));
        Raise(nameof(SummaryCards));
        Raise(nameof(DistributionBins));
        Raise(nameof(DistributionTotalLabel));
        Raise(nameof(TrendPoints));
        Raise(nameof(DimensionRows));
        Raise(nameof(ComparisonRows));
        Raise(nameof(TopAgents));
        Raise(nameof(LowAgents));
        Raise(nameof(SelectedTaskLabel));
        Raise(nameof(SelectedAgentLabel));
        Raise(nameof(MissingScoreLabel));
        Raise(nameof(MissingScoreCount));
    }

    private IReadOnlyList<EvaluationSummaryCard> BuildSummaryCards(
        Copy text,
        IReadOnlyList<EvaluationSnapshotRecord> scored)
    {
        var average = scored.Count == 0
            ? (decimal?)null
            : Round(scored.Average(item => item.Result.TotalScore!.Value));
        var passed = scored.Count(item => item.Result.TotalScore >= PassScore);
        var passRate = scored.Count == 0
            ? (decimal?)null
            : Round(passed * 100m / scored.Count);
        var status = _snapshot.Availability == EvaluationSnapshotAvailability.Unavailable
            ? text.Unavailable
            : text.SyntheticStatus;

        return
        [
            Card("average-score", text.AverageScore, FormatScore(average), text.OutOf100,
                text.AverageScoreStatus(average), average, null, null,
                OverviewBrushKeys.Primary, text.Accessibility(text.AverageScore, FormatScore(average)), status),
            Card("evaluations", text.TotalEvaluations, _evaluationCountTotal.ToString(CultureInfo.InvariantCulture),
                text.Records, text.Count(_evaluationCountTotal), null, _evaluationCountTotal, null,
                OverviewBrushKeys.Working, text.Accessibility(text.TotalEvaluations, _evaluationCountTotal.ToString(CultureInfo.InvariantCulture)), status),
            Card("scored", text.ScoredEvaluations, scored.Count.ToString(CultureInfo.InvariantCulture),
                text.Records, text.ScoredCount(scored.Count), null, scored.Count, null,
                OverviewBrushKeys.Done, text.Accessibility(text.ScoredEvaluations, scored.Count.ToString(CultureInfo.InvariantCulture)), status),
            Card("missing", text.MissingScoresLabel, _missingScoreCount.ToString(CultureInfo.InvariantCulture),
                text.Records, _missingScoreLabel, null, _missingScoreCount, null,
                _missingScoreCount == 0 ? OverviewBrushKeys.Done : OverviewBrushKeys.Idle,
                text.Accessibility(text.MissingScoresLabel, _missingScoreCount.ToString(CultureInfo.InvariantCulture)), status),
            Card("pass-rate", text.PassRate, FormatPercentage(passRate), text.Percent,
                text.PassRateStatus(passed, scored.Count), passRate is null ? null : (decimal?)passed, scored.Count,
                passRate, OverviewBrushKeys.Review, text.Accessibility(text.PassRate, FormatPercentage(passRate)), status),
        ];
    }

    private static EvaluationSummaryCard Card(
        string id,
        string label,
        string value,
        string metric,
        string trend,
        decimal? score,
        int? count,
        decimal? percentage,
        string brush,
        string accessibility,
        string status) =>
        new(id, label, value, metric, trend, score, count, percentage, brush, accessibility, status);

    private IReadOnlyList<EvaluationDistributionBin> BuildDistribution(
        Copy text,
        IReadOnlyList<EvaluationSnapshotRecord> scored)
    {
        var bins = new (string Id, int Min, int Max, string Brush)[]
        {
            ("excellent", 90, 100, OverviewBrushKeys.Primary),
            ("good", 75, 89, OverviewBrushKeys.Review),
            ("pass", 60, 74, OverviewBrushKeys.Working),
            ("improve", 40, 59, OverviewBrushKeys.Idle),
            ("fail", 0, 39, OverviewBrushKeys.Blocked),
        };

        return bins.Select(bin =>
        {
            var count = scored.Count(item => bin.Id switch
            {
                "excellent" => item.Result.TotalScore >= 90,
                "good" => item.Result.TotalScore >= 75 && item.Result.TotalScore < 90,
                "pass" => item.Result.TotalScore >= 60 && item.Result.TotalScore < 75,
                "improve" => item.Result.TotalScore >= 40 && item.Result.TotalScore < 60,
                _ => item.Result.TotalScore < 40,
            });
            var percentage = scored.Count == 0 ? 0m : Round(count * 100m / scored.Count);
            var label = text.DistributionLabel(bin.Id);
            return new EvaluationDistributionBin(
                bin.Id,
                label,
                bin.Min,
                bin.Max,
                count,
                percentage,
                bin.Brush,
                text.Accessibility(label, $"{count}, {FormatPercentage(percentage)}"),
                text.SyntheticStatus);
        }).ToArray();
    }

    private IReadOnlyList<EvaluationTrendPoint> BuildTrend(Copy text) =>
        _snapshot.Trend
            .OrderBy(item => item.Date)
            .Take(7)
            .Select(item =>
            {
                var scoreLabel = FormatScore(item.Score);
                var status = item.Score is null ? text.MissingScore : text.Complete;
                var dateLabel = text.Date(item.Date);
                return new EvaluationTrendPoint(
                    item.Date.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture),
                    item.Date,
                    dateLabel,
                    item.Score,
                    scoreLabel,
                    item.Score is null ? OverviewBrushKeys.Offline : OverviewBrushKeys.Primary,
                    text.Accessibility(dateLabel, scoreLabel),
                    status);
            })
            .ToArray();

    private IReadOnlyList<EvaluationDimensionRow> BuildDimensions(
        Copy text,
        EvaluationSnapshotRecord? selected)
    {
        var formulaWeights = EvaluationFormulaCatalog.Version1.DimensionWeights
            .ToDictionary(item => item.Dimension, item => item.WeightBasisPoints);
        var resultByDimension = selected?.Result.Dimensions
            .ToDictionary(item => item.Dimension);

        return Dimensions.Select(dimension =>
        {
            var weight = formulaWeights[dimension] / 100m;
            var result = resultByDimension?.GetValueOrDefault(dimension);
            var score = result?.Status == EvaluationDimensionScoreStatus.Complete
                ? result.DimensionScore
                : null;
            var status = selected is null
                ? text.Unavailable
                : text.DimensionStatus(result?.Status);
            var label = text.Dimension(dimension);
            return new EvaluationDimensionRow(
                dimension,
                label,
                score,
                weight,
                FormatScore(score),
                status,
                BrushFor(result?.Status),
                text.Accessibility(label, $"{FormatScore(score)}, {status}"),
                status);
        }).ToArray();
    }

    private IReadOnlyList<EvaluationComparisonRow> BuildComparison(
        Copy text,
        EvaluationSnapshotRecord? selected)
    {
        var sourceWeights = EvaluationFormulaCatalog.Version1.SourceWeights
            .ToDictionary(item => item.Source, item => item.WeightBasisPoints / 100m);

        return Sources.Select(source =>
        {
            var label = text.Source(source);
            if (selected is null)
            {
                return new EvaluationComparisonRow(
                    source,
                    label,
                    null,
                    0,
                    sourceWeights[source],
                    FormatScore(null),
                    string.Empty,
                    string.Empty,
                    OverviewBrushKeys.Offline,
                    text.Accessibility(label, text.Unavailable),
                    text.Unavailable);
            }

            var values = selected.Result.Dimensions
                .Select(item => SourceInput(item, source))
                .Where(item => item.Score is not null)
                .Select(item => item.Score!.Value)
                .ToArray();
            var complete = selected.Result.Status == EvaluationResultStatus.Complete &&
                           values.Length == Dimensions.Count;
            var score = complete
                ? (decimal?)Round(selected.Result.Dimensions
                    .Zip(EvaluationFormulaCatalog.Version1.DimensionWeights)
                    .Sum(pair => (SourceInput(pair.First, source).Score ?? 0) * pair.Second.WeightBasisPoints) /
                        10_000m)
                : null;
            var provenance = selected.Result.Dimensions
                .Select(item => SourceInput(item, source))
                .FirstOrDefault(item => item.ProvenanceId is not null);
            var status = complete ? text.Complete : text.MissingScore;
            return new EvaluationComparisonRow(
                source,
                label,
                score,
                values.Length,
                sourceWeights[source],
                FormatScore(score),
                provenance?.ProvenanceId ?? string.Empty,
                provenance?.ProvenanceSha256 ?? string.Empty,
                complete ? OverviewBrushKeys.Primary : OverviewBrushKeys.Idle,
                text.Accessibility(label, $"{FormatScore(score)}, {status}"),
                status);
        }).ToArray();
    }

    private IReadOnlyList<EvaluationRankingRow> BuildRankings(
        Copy text,
        IReadOnlyList<EvaluationSnapshotRecord> scored,
        bool descending)
    {
        var ordered = (descending
                ? scored.OrderByDescending(item => item.Result.TotalScore)
                : scored.OrderBy(item => item.Result.TotalScore))
            .ThenBy(item => item.AgentLabel, StringComparer.Ordinal)
            .ThenBy(item => item.AgentId, StringComparer.Ordinal)
            .ToArray();
        var rows = new List<EvaluationRankingRow>(Math.Min(5, ordered.Length));
        for (var index = 0; index < ordered.Length && rows.Count < 5; index++)
        {
            var item = ordered[index];
            var score = item.Result.TotalScore!.Value;
            var rank = index == 0 || ordered[index - 1].Result.TotalScore != score
                ? index + 1
                : rows[^1].Rank;
            var tie = ordered.Count(other => other.Result.TotalScore == score) > 1;
            var tieLabel = tie ? text.Tie(rank) : string.Empty;
            rows.Add(new EvaluationRankingRow(
                rank,
                item.AgentId,
                item.AgentLabel,
                score,
                FormatScore(score),
                tie,
                tieLabel,
                descending ? OverviewBrushKeys.Primary : OverviewBrushKeys.Review,
                text.Accessibility(item.AgentLabel, $"{FormatScore(score)}, {tieLabel}"),
                tie ? tieLabel : text.Complete));
        }

        return rows;
    }

    private static EvaluationScoreInput SourceInput(
        EvaluationDimensionScore dimension,
        EvaluationScoreSource source) => source switch
        {
            EvaluationScoreSource.Leader => dimension.Leader,
            EvaluationScoreSource.ProjectManager => dimension.ProjectManager,
            EvaluationScoreSource.ObjectiveEvidence => dimension.ObjectiveEvidence,
            _ => throw new ArgumentOutOfRangeException(nameof(source)),
        };

    private static bool HasScore(EvaluationSnapshotRecord item) =>
        item.Result.Status == EvaluationResultStatus.Complete && item.Result.TotalScore is not null;

    private static string FormatScore(decimal? score) => score?.ToString("0.##", CultureInfo.InvariantCulture) ?? "—";

    private static string FormatPercentage(decimal? percentage) =>
        percentage is null ? "—" : $"{percentage.Value:0.##}%";

    private static decimal Round(decimal value) => decimal.Round(value, 2, MidpointRounding.AwayFromZero);

    private static string BrushFor(EvaluationDimensionScoreStatus? status) => status switch
    {
        EvaluationDimensionScoreStatus.Complete => OverviewBrushKeys.Primary,
        EvaluationDimensionScoreStatus.Missing => OverviewBrushKeys.Idle,
        EvaluationDimensionScoreStatus.Invalid => OverviewBrushKeys.Blocked,
        _ => OverviewBrushKeys.Offline,
    };

    private static IReadOnlyList<T> Freeze<T>(IEnumerable<T> values) =>
        new ReadOnlyCollection<T>(values.ToArray());

    private static EvaluationSnapshot CreateSyntheticSnapshot(bool includeMissingScore)
    {
        var records = new List<EvaluationSnapshotRecord>
        {
            Record("evaluation-001", "TASK-118", "Authentication API Integration", "agent-pm-secretary", "PM Secretary", [96, 94, 93, 92, 91, 90], [94, 92, 91, 90, 89, 88], [98, 96, 95, 94, 93, 92]),
            Record("evaluation-002", "TASK-115", "AuthService implementation", "agent-backend-worker-02", "Backend Worker 02", [92, 90, 88, 86, 90, 91], [90, 88, 87, 85, 89, 88], [94, 92, 90, 88, 92, 93]),
            Record("evaluation-003", "TASK-120", "Unit test coverage", "agent-test-worker", "Test Worker", [92, 90, 88, 86, 90, 91], [90, 88, 87, 85, 89, 88], [94, 92, 90, 88, 92, 93]),
            Record("evaluation-004", "TASK-113", "Auth scope review", "agent-backend-leader", "Backend Leader", [82, 80, 78, 76, 80, 81], [80, 78, 77, 75, 79, 78], [84, 82, 80, 78, 82, 83]),
            Record("evaluation-005", "TASK-122", "JWT helper refactor", "agent-devops-worker", "DevOps Worker", [72, 70, 68, 66, 70, 71], [70, 68, 67, 65, 69, 68], [74, 72, 70, 68, 72, 73]),
        };

        if (includeMissingScore)
        {
            records.Add(RecordWithMissingScore(
                "evaluation-006",
                "TASK-125",
                "Release evidence review",
                "agent-security-worker",
                "Security Worker"));
        }

        var trend = new[] { 72m, 74m, 76m, 79m, 81m, 82m, 82m }
            .Select((score, index) => new EvaluationTrendValue(
                new DateOnly(2026, 8, 8).AddDays(index),
                score))
            .ToArray();
        return new EvaluationSnapshot(
            EvaluationSnapshotAvailability.Available,
            records,
            trend,
            includeMissingScore ? "TASK-125" : "TASK-118",
            includeMissingScore ? "agent-security-worker" : "agent-pm-secretary",
            new DateOnly(2026, 8, 14));
    }

    private static EvaluationSnapshotRecord Record(
        string evaluationId,
        string taskId,
        string taskLabel,
        string agentId,
        string agentLabel,
        IReadOnlyList<int> leader,
        IReadOnlyList<int> projectManager,
        IReadOnlyList<int> evidence)
    {
        var result = new EvaluationScoringEngine().Calculate(
            new EvaluationInputSnapshot(
                EvaluationFormulaCatalog.ContractVersion,
                evaluationId,
                taskId,
                agentId,
                Dimensions.Select((dimension, index) => new EvaluationDimensionInput(
                    dimension,
                    Score(leader[index], $"{evaluationId}:leader:{index}"),
                    Score(projectManager[index], $"{evaluationId}:pm:{index}"),
                    Score(evidence[index], $"{evaluationId}:evidence:{index}")))
                    .ToArray()),
            EvaluationFormulaCatalog.Version1);
        return new EvaluationSnapshotRecord(evaluationId, taskId, taskLabel, agentId, agentLabel, result);
    }

    private static EvaluationSnapshotRecord RecordWithMissingScore(
        string evaluationId,
        string taskId,
        string taskLabel,
        string agentId,
        string agentLabel)
    {
        var result = new EvaluationScoringEngine().Calculate(
            new EvaluationInputSnapshot(
                EvaluationFormulaCatalog.ContractVersion,
                evaluationId,
                taskId,
                agentId,
                Dimensions.Select((dimension, index) => new EvaluationDimensionInput(
                    dimension,
                    Score(index == 5 ? null : 78 - index, $"{evaluationId}:leader:{index}"),
                    Score(index == 5 ? null : 76 - index, $"{evaluationId}:pm:{index}"),
                    Score(index == 5 ? null : 80 - index, $"{evaluationId}:evidence:{index}")))
                    .ToArray()),
            EvaluationFormulaCatalog.Version1);
        return new EvaluationSnapshotRecord(evaluationId, taskId, taskLabel, agentId, agentLabel, result);
    }

    private static EvaluationScoreInput Score(int? score, string provenanceId) =>
        score is null
            ? new EvaluationScoreInput(null, null, null)
            : new EvaluationScoreInput(score, provenanceId, new string('A', 64));

    private sealed class Copy(UiLanguage language)
    {
        private readonly UiLanguage _language = language;

        public string SyntheticSource => _language == UiLanguage.Thai ? "ข้อมูลจำลอง" : "Synthetic data";

        public string UnavailableSource => _language == UiLanguage.Thai ? "ยังไม่มีข้อมูลการประเมิน" : "Evaluation data unavailable";

        public string EvidenceBoundary => _language == UiLanguage.Thai
            ? "หลักฐานสังเคราะห์และสัญญาเท่านั้น · ไม่ใช่ Runtime ของ Herdr"
            : "Synthetic and contract evidence only · not Herdr runtime";

        public string SyntheticStatus => _language == UiLanguage.Thai ? "ข้อมูลจำลอง" : "Synthetic";

        public string Unavailable => _language == UiLanguage.Thai ? "ไม่พร้อมใช้งาน" : "Unavailable";

        public string Complete => _language == UiLanguage.Thai ? "มีคะแนนครบ" : "Complete";

        public string MissingScore => _language == UiLanguage.Thai ? "ไม่มีคะแนน" : "Missing score";

        public string AverageScore => _language == UiLanguage.Thai ? "คะแนนเฉลี่ย" : "Average Score";

        public string TotalEvaluations => _language == UiLanguage.Thai ? "การประเมินทั้งหมด" : "Total Evaluations";

        public string ScoredEvaluations => _language == UiLanguage.Thai ? "การประเมินที่มีคะแนน" : "Scored Evaluations";

        public string MissingScoresLabel => _language == UiLanguage.Thai ? "คะแนนที่ขาดหาย" : "Missing Scores";

        public string PassRate => _language == UiLanguage.Thai ? "อัตราผ่าน" : "Pass Rate";

        public string OutOf100 => "/100";

        public string Records => _language == UiLanguage.Thai ? "รายการ" : "records";

        public string Percent => "%";

        public string Count(int count) => _language == UiLanguage.Thai
            ? $"{count.ToString(CultureInfo.InvariantCulture)} รายการ"
            : $"{count.ToString(CultureInfo.InvariantCulture)} records";

        public string ScoredCount(int count) => _language == UiLanguage.Thai
            ? $"มีคะแนน {count.ToString(CultureInfo.InvariantCulture)} รายการ"
            : $"{count.ToString(CultureInfo.InvariantCulture)} scored evaluations";

        public string MissingScores(int count) => _language == UiLanguage.Thai
            ? $"ขาดคะแนน {count.ToString(CultureInfo.InvariantCulture)} รายการ · ไม่นำไปจัดอันดับหรือคำนวณผ่าน"
            : $"{count.ToString(CultureInfo.InvariantCulture)} missing-score records · excluded from ranking and pass rate";

        public string AverageScoreStatus(decimal? score) => score is null ? Unavailable : SyntheticStatus;

        public string PassRateStatus(int passed, int total) => total == 0
            ? Unavailable
            : _language == UiLanguage.Thai
                ? $"ผ่าน {passed} จาก {total} รายการที่มีคะแนน"
                : $"{passed} of {total} scored evaluations passed";

        public string Accessibility(string label, string value) =>
            _language == UiLanguage.Thai ? $"{label}: {value}" : $"{label}: {value}";

        public string DistributionLabel(string id) => _language == UiLanguage.Thai
            ? id switch
            {
                "excellent" => "90–100 ดีเยี่ยม",
                "good" => "75–89 ดี",
                "pass" => "60–74 ผ่าน",
                "improve" => "40–59 ต้องปรับปรุง",
                _ => "0–39 ไม่ผ่าน",
            }
            : id switch
            {
                "excellent" => "90–100 Excellent",
                "good" => "75–89 Good",
                "pass" => "60–74 Pass",
                "improve" => "40–59 Improve",
                _ => "0–39 Fail",
            };

        public string Date(DateOnly date) => _language == UiLanguage.Thai
            ? $"{date.Day} {ThaiMonth(date.Month)}"
            : date.ToString("MMM d", CultureInfo.GetCultureInfo("en-US"));

        public string Dimension(EvaluationDimension dimension) => _language == UiLanguage.Thai
            ? dimension switch
            {
                EvaluationDimension.GoalAlignment => "ความสอดคล้องกับเป้าหมาย",
                EvaluationDimension.AcceptanceCriteria => "เกณฑ์การยอมรับ",
                EvaluationDimension.TechnicalQuality => "คุณภาพทางเทคนิค",
                EvaluationDimension.ScopeCompliance => "การปฏิบัติตามขอบเขต",
                EvaluationDimension.Evidence => "หลักฐาน",
                _ => "การสื่อสาร",
            }
            : dimension switch
            {
                EvaluationDimension.GoalAlignment => "Goal Alignment",
                EvaluationDimension.AcceptanceCriteria => "Acceptance Criteria",
                EvaluationDimension.TechnicalQuality => "Technical Quality",
                EvaluationDimension.ScopeCompliance => "Scope Compliance",
                EvaluationDimension.Evidence => "Evidence",
                _ => "Communication",
            };

        public string Source(EvaluationScoreSource source) => _language == UiLanguage.Thai
            ? source switch
            {
                EvaluationScoreSource.Leader => "หัวหน้าทีม",
                EvaluationScoreSource.ProjectManager => "ผู้จัดการโครงการ",
                _ => "หลักฐานตามวัตถุประสงค์",
            }
            : source switch
            {
                EvaluationScoreSource.Leader => "Leader",
                EvaluationScoreSource.ProjectManager => "Project Manager",
                _ => "Objective Evidence",
            };

        public string DimensionStatus(EvaluationDimensionScoreStatus? status) => status switch
        {
            EvaluationDimensionScoreStatus.Complete => Complete,
            EvaluationDimensionScoreStatus.Missing => MissingScore,
            EvaluationDimensionScoreStatus.Invalid => _language == UiLanguage.Thai ? "ข้อมูลไม่ถูกต้อง" : "Invalid",
            _ => Unavailable,
        };

        public string Tie(int rank) => _language == UiLanguage.Thai
            ? $"เสมอที่อันดับ {rank}"
            : $"Tied at rank {rank}";

        private static string ThaiMonth(int month) => month switch
        {
            1 => "ม.ค.",
            2 => "ก.พ.",
            3 => "มี.ค.",
            4 => "เม.ย.",
            5 => "พ.ค.",
            6 => "มิ.ย.",
            7 => "ก.ค.",
            8 => "ส.ค.",
            9 => "ก.ย.",
            10 => "ต.ค.",
            11 => "พ.ย.",
            _ => "ธ.ค.",
        };
    }
}

public static class EvaluationBrushKeys
{
    public const string Primary = OverviewBrushKeys.Primary;
    public const string Working = OverviewBrushKeys.Working;
    public const string Idle = OverviewBrushKeys.Idle;
    public const string Blocked = OverviewBrushKeys.Blocked;
    public const string Review = OverviewBrushKeys.Review;
    public const string Offline = OverviewBrushKeys.Offline;
}
