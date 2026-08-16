using System.Collections.ObjectModel;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
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
        DateOnly snapshotDate,
        decimal? previousAverageScore,
        int leaderReviewsPending,
        int projectManagerReviewsPending,
        int recurringIssueCount)
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
        PreviousAverageScore = previousAverageScore;
        LeaderReviewsPending = Math.Max(0, leaderReviewsPending);
        ProjectManagerReviewsPending = Math.Max(0, projectManagerReviewsPending);
        RecurringIssueCount = Math.Max(0, recurringIssueCount);
    }

    public EvaluationSnapshotAvailability Availability { get; }

    public IReadOnlyList<EvaluationSnapshotRecord> Evaluations { get; }

    public IReadOnlyList<EvaluationTrendValue> Trend { get; }

    public string SelectedTaskId { get; }

    public string SelectedAgentId { get; }

    public DateOnly SnapshotDate { get; }

    public decimal? PreviousAverageScore { get; }

    public int LeaderReviewsPending { get; }

    public int ProjectManagerReviewsPending { get; }

    public int RecurringIssueCount { get; }

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
    decimal? WeightPercentage,
    string ScoreLabel,
    string StatusLabel,
    string AccentBrushKey,
    string AccessibilityText,
    string StatusText);

public sealed record EvaluationComparisonRow(
    EvaluationDimension Dimension,
    string Label,
    decimal? WeightPercentage,
    string WeightLabel,
    int? LeaderScore,
    string LeaderScoreLabel,
    string LeaderProvenanceId,
    string LeaderEvidenceIdentitySha256,
    int? ProjectManagerScore,
    string ProjectManagerScoreLabel,
    string ProjectManagerProvenanceId,
    string ProjectManagerEvidenceIdentitySha256,
    int? ObjectiveEvidenceScore,
    string ObjectiveEvidenceScoreLabel,
    string ObjectiveEvidenceProvenanceId,
    string ObjectiveEvidenceIdentitySha256,
    decimal? WeightedScore,
    string WeightedScoreLabel,
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
    string StatusText,
    string TaskId,
    string TaskLabel,
    string EvaluationId,
    string ContextLabel,
    string FormulaId,
    string InputSnapshotSha256,
    string InputSnapshotSha256Display,
    string InputSnapshotSha256AccessibilityValue,
    decimal? TrendDelta,
    string TrendLabel,
    string ProvenanceLabel);

/// <summary>
/// Presentation-only Evaluation state. It accepts synthetic/contract data and
/// has no dependency on an installed Herdr runtime.
/// </summary>
public sealed class EvaluationState : ObservableState
{
    private static readonly IReadOnlyList<EvaluationDimension> Dimensions =
        Enum.GetValues<EvaluationDimension>();

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
    private string _comparisonTotalScoreLabel = string.Empty;
    private string _dimensionWeightedAverageLabel = string.Empty;
    private string _comparisonFormulaLabel = string.Empty;
    private string _comparisonSnapshotSha256 = string.Empty;
    private string _missingScoreLabel = string.Empty;
    private string _rankingEmptyLabel = string.Empty;
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

    public string ComparisonTotalScoreLabel => _comparisonTotalScoreLabel;

    public string DimensionWeightedAverageLabel => _dimensionWeightedAverageLabel;

    public string ComparisonFormulaLabel => _comparisonFormulaLabel;

    public string ComparisonSnapshotSha256 => _comparisonSnapshotSha256;

    public string MissingScoreLabel => _missingScoreLabel;

    public int MissingScoreCount => _missingScoreCount;

    public string RankingEmptyLabel => _rankingEmptyLabel;

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
            new DateOnly(2026, 8, 14),
            previousAverageScore: null,
            leaderReviewsPending: 0,
            projectManagerReviewsPending: 0,
            recurringIssueCount: 0));

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
        _evidenceBoundaryLabel = _snapshot.Availability == EvaluationSnapshotAvailability.Unavailable
            ? text.LiveBoundary
            : text.SyntheticBoundary;
        _evaluationCountTotal = _snapshot.Evaluations.Count;
        _evaluationCountLabel = text.Count(_evaluationCountTotal);
        _missingScoreCount = _snapshot.Evaluations.Count(item => !HasScore(item));
        _missingScoreLabel = text.MissingScores(_missingScoreCount);
        _selectedTaskLabel = selected is null
            ? text.Unavailable
            : text.SelectedTask($"{selected.TaskId} · {selected.TaskLabel}");
        _selectedAgentLabel = selected is null
            ? text.Unavailable
            : text.SelectedAgent(selected.AgentLabel);
        _comparisonTotalScoreLabel = FormatScore(selected?.Result.TotalScore);
        var selectedFormulaAvailable = TryGetEmbeddedFormula(selected?.Result, out var selectedFormula);
        _comparisonFormulaLabel = selectedFormulaAvailable
            ? selectedFormula.FormulaId
            : text.Unavailable;
        _comparisonSnapshotSha256 = selected?.Result.Provenance?.InputSnapshotSha256 ?? string.Empty;
        _dimensionWeightedAverageLabel = scored.Length == 0
            ? text.Unavailable
            : FormatScore(Round(scored.Average(item => item.Result.TotalScore!.Value)));
        _rankingEmptyLabel = text.RankingEmpty;
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
        Raise(nameof(ComparisonTotalScoreLabel));
        Raise(nameof(DimensionWeightedAverageLabel));
        Raise(nameof(ComparisonFormulaLabel));
        Raise(nameof(ComparisonSnapshotSha256));
        Raise(nameof(MissingScoreLabel));
        Raise(nameof(MissingScoreCount));
        Raise(nameof(RankingEmptyLabel));
    }

    private IReadOnlyList<EvaluationSummaryCard> BuildSummaryCards(
        Copy text,
        IReadOnlyList<EvaluationSnapshotRecord> scored)
    {
        var average = scored.Count == 0
            ? (decimal?)null
            : Round(scored.Average(item => item.Result.TotalScore!.Value));
        var averageDelta = average is null || _snapshot.PreviousAverageScore is null
            ? (decimal?)null
            : Round(average.Value - _snapshot.PreviousAverageScore.Value);
        var status = _snapshot.Availability == EvaluationSnapshotAvailability.Unavailable
            ? text.Unavailable
            : text.SyntheticStatus;

        return
        [
            Card("average-score", text.AverageScore, FormatScore(average), text.OutOf100,
                text.ScoreDelta(averageDelta), average, null, null,
                OverviewBrushKeys.Primary, text.Accessibility(text.AverageScore, FormatScore(average)), status),
            Card("evaluations", text.TotalEvaluations, _evaluationCountTotal.ToString(CultureInfo.InvariantCulture),
                text.Records, text.Today, null, _evaluationCountTotal, null,
                OverviewBrushKeys.Working, text.Accessibility(text.TotalEvaluations, _evaluationCountTotal.ToString(CultureInfo.InvariantCulture)), status),
            Card("leader-pending", text.LeaderReviewsPending,
                _snapshot.LeaderReviewsPending.ToString(CultureInfo.InvariantCulture),
                text.Records, text.FromTotal(_evaluationCountTotal), null,
                _snapshot.LeaderReviewsPending, null, OverviewBrushKeys.Idle,
                text.Accessibility(text.LeaderReviewsPending, _snapshot.LeaderReviewsPending.ToString(CultureInfo.InvariantCulture)), status),
            Card("pm-pending", text.ProjectManagerReviewsPending,
                _snapshot.ProjectManagerReviewsPending.ToString(CultureInfo.InvariantCulture),
                text.Records, text.FromTotal(_evaluationCountTotal), null,
                _snapshot.ProjectManagerReviewsPending, null, OverviewBrushKeys.Review,
                text.Accessibility(text.ProjectManagerReviewsPending, _snapshot.ProjectManagerReviewsPending.ToString(CultureInfo.InvariantCulture)), status),
            Card("recurring", text.RecurringIssues,
                _snapshot.RecurringIssueCount.ToString(CultureInfo.InvariantCulture),
                text.Records, text.FromLastWeek, null, _snapshot.RecurringIssueCount, null,
                OverviewBrushKeys.Blocked,
                text.Accessibility(text.RecurringIssues, _snapshot.RecurringIssueCount.ToString(CultureInfo.InvariantCulture)), status),
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
        var formulaAvailable = TryGetEmbeddedFormula(selected?.Result, out var formula);
        var formulaWeights = formulaAvailable
            ? formula.DimensionWeights.ToDictionary(item => item.Dimension, item => item.WeightBasisPoints)
            : null;
        var resultByDimension = selected?.Result.Dimensions?
            .GroupBy(item => item.Dimension)
            .ToDictionary(group => group.Key, group => group.Last());

        return Dimensions.Select(dimension =>
        {
            var weight = formulaWeights is not null && formulaWeights.TryGetValue(dimension, out var weightBasisPoints)
                ? weightBasisPoints / 100m
                : (decimal?)null;
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
        var formulaAvailable = TryGetEmbeddedFormula(selected?.Result, out var formula);
        var weights = formulaAvailable
            ? formula.DimensionWeights.ToDictionary(item => item.Dimension, item => item.WeightBasisPoints / 100m)
            : null;
        var results = selected?.Result.Dimensions?
            .GroupBy(item => item.Dimension)
            .ToDictionary(group => group.Key, group => group.Last());

        return Dimensions.Select(dimension =>
        {
            var result = results?.GetValueOrDefault(dimension);
            var weight = weights is not null && weights.TryGetValue(dimension, out var resolvedWeight)
                ? resolvedWeight
                : (decimal?)null;
            var leader = result?.Leader ?? new EvaluationScoreInput(null, null, null);
            var projectManager = result?.ProjectManager ?? new EvaluationScoreInput(null, null, null);
            var evidence = result?.ObjectiveEvidence ?? new EvaluationScoreInput(null, null, null);
            var complete = formulaAvailable && result?.Status == EvaluationDimensionScoreStatus.Complete;
            var status = selected is null
                ? text.Unavailable
                : text.DimensionStatus(result?.Status);
            var label = text.Dimension(dimension);
            var weighted = complete ? result!.WeightedScore : null;
            return new EvaluationComparisonRow(
                dimension,
                label,
                weight,
                weight is null ? text.Unavailable : FormatPercentage(weight),
                leader.Score,
                FormatScore(leader.Score),
                leader.ProvenanceId ?? string.Empty,
                leader.EvidenceIdentitySha256 ?? string.Empty,
                projectManager.Score,
                FormatScore(projectManager.Score),
                projectManager.ProvenanceId ?? string.Empty,
                projectManager.EvidenceIdentitySha256 ?? string.Empty,
                evidence.Score,
                FormatScore(evidence.Score),
                evidence.ProvenanceId ?? string.Empty,
                evidence.EvidenceIdentitySha256 ?? string.Empty,
                weighted,
                formulaAvailable
                    ? $"{FormatScore(weighted)} / {FormatScore(weight)}"
                    : text.Unavailable,
                BrushFor(result?.Status),
                text.Accessibility(
                    label,
                    $"{FormatScore(leader.Score)}, {FormatScore(projectManager.Score)}, {FormatScore(evidence.Score)}, {FormatScore(weighted)}, {status}"),
                status);
        }).ToArray();
    }

    private IReadOnlyList<EvaluationRankingRow> BuildRankings(
        Copy text,
        IReadOnlyList<EvaluationSnapshotRecord> scored,
        bool descending)
    {
        var snapshotAverage = scored.Count == 0
            ? (decimal?)null
            : Round(scored.Average(item => item.Result.TotalScore!.Value));
        var ordered = (descending
                ? scored.OrderByDescending(item => item.Result.TotalScore)
                : scored.OrderBy(item => item.Result.TotalScore))
            .ThenBy(item => item.AgentId, StringComparer.Ordinal)
            .ThenBy(item => item.EvaluationId, StringComparer.Ordinal)
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
            var trendDelta = snapshotAverage is null ? (decimal?)null : Round(score - snapshotAverage.Value);
            var formulaAvailable = TryGetEmbeddedFormula(item.Result, out var formula);
            var formulaId = formulaAvailable ? formula.FormulaId : text.Unavailable;
            var rawInputSnapshotSha256 = item.Result.Provenance?.InputSnapshotSha256 ?? string.Empty;
            var inputSnapshotSha256 = IsSha256(rawInputSnapshotSha256)
                ? rawInputSnapshotSha256
                : string.Empty;
            var inputSnapshotSha256Display = ShortHash(inputSnapshotSha256, text.Unavailable);
            var inputSnapshotSha256AccessibilityValue = string.IsNullOrWhiteSpace(inputSnapshotSha256)
                ? text.Unavailable
                : inputSnapshotSha256;
            var contextLabel = text.RankingContext(item.TaskId, item.TaskLabel, item.EvaluationId);
            var provenanceLabel = text.RankingProvenance(formulaId, inputSnapshotSha256Display);
            var trendLabel = text.RankingTrend(trendDelta);
            rows.Add(new EvaluationRankingRow(
                rank,
                item.AgentId,
                item.AgentLabel,
                score,
                FormatScore(score),
                tie,
                tieLabel,
                descending ? OverviewBrushKeys.Primary : OverviewBrushKeys.Review,
                text.Accessibility(
                    item.AgentLabel,
                    $"{FormatScore(score)}, {tieLabel}, {contextLabel}, {trendLabel}, " +
                    $"{provenanceLabel}, {inputSnapshotSha256AccessibilityValue}"),
                tie ? $"{tieLabel} · {trendLabel}" : $"{text.Complete} · {trendLabel}",
                item.TaskId,
                item.TaskLabel,
                item.EvaluationId,
                contextLabel,
                formulaId,
                inputSnapshotSha256,
                inputSnapshotSha256Display,
                inputSnapshotSha256AccessibilityValue,
                trendDelta,
                trendLabel,
                provenanceLabel));
        }

        return rows;
    }

    private static bool HasScore(EvaluationSnapshotRecord item) =>
        item.Result.Status == EvaluationResultStatus.Complete && item.Result.TotalScore is not null;

    private static string FormatScore(decimal? score) => score?.ToString("0.##", CultureInfo.InvariantCulture) ?? "—";

    private static string FormatPercentage(decimal? percentage) =>
        percentage is null ? "—" : $"{percentage.Value:0.##}%";

    private static string ShortHash(string value, string unavailable)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return unavailable;
        }

        return value.Length <= 12 ? value : $"{value[..12]}…";
    }

    private static bool TryGetEmbeddedFormula(
        EvaluationScoreResult? result,
        out EvaluationFormulaDefinition formula)
    {
        formula = null!;
        if (result?.Provenance is not { } provenance ||
            provenance.Formula is null ||
            provenance.InputSnapshot is null ||
            result.Dimensions is null)
        {
            return false;
        }

        EvaluationFormulaDefinition normalized;
        try
        {
            normalized = EvaluationFormulaContract.NormalizeAndValidate(provenance.Formula);
        }
        catch (Exception exception) when (
            exception is ArgumentNullException or
            EvaluationScoringContractException or
            InvalidOperationException)
        {
            return false;
        }

        if (result.ContractVersion != normalized.ContractVersion ||
            !IsSha256(provenance.InputSnapshotSha256) ||
            !string.Equals(provenance.FormulaSha256, normalized.FormulaSha256, StringComparison.Ordinal) ||
            !string.Equals(provenance.InputSnapshot.EvaluationId, result.EvaluationId, StringComparison.Ordinal) ||
            !string.Equals(provenance.InputSnapshot.TaskId, result.TaskId, StringComparison.Ordinal) ||
            !string.Equals(provenance.InputSnapshot.AgentId, result.AgentId, StringComparison.Ordinal))
        {
            return false;
        }

        var formulaWeights = normalized.DimensionWeights.ToDictionary(
            item => item.Dimension,
            item => item.WeightBasisPoints);
        if (result.Dimensions.Count != Dimensions.Count ||
            result.Dimensions.Select(item => item.Dimension).Distinct().Count() != Dimensions.Count ||
            result.Dimensions.Any(item =>
                !formulaWeights.TryGetValue(item.Dimension, out var expectedWeight) ||
                item.WeightBasisPoints != expectedWeight))
        {
            return false;
        }

        formula = normalized;
        return true;
    }

    private static bool IsSha256(string? value) =>
        value is not null && value.Length == 64 && value.All(static character =>
            (character >= '0' && character <= '9') ||
            (character >= 'A' && character <= 'F') ||
            (character >= 'a' && character <= 'f'));

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
            new DateOnly(2026, 8, 14),
            previousAverageScore: 82m,
            leaderReviewsPending: 2,
            projectManagerReviewsPending: 1,
            recurringIssueCount: 1);
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
            : new EvaluationScoreInput(
                score,
                provenanceId,
                Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(provenanceId))));

    private sealed class Copy(UiLanguage language)
    {
        private readonly UiLanguageService _service = UiLanguageService.Shared;
        private readonly CultureInfo _culture = CultureInfo.GetCultureInfo(
            language == UiLanguage.Thai ? "th-TH" : "en-US");

        public string SyntheticSource => _service["EvaluationSyntheticSource"];

        public string UnavailableSource => _service["EvaluationLiveSourceUnavailable"];

        public string SyntheticBoundary => _service["EvaluationSyntheticBoundary"];

        public string LiveBoundary => _service["EvaluationLiveBoundary"];

        public string SyntheticStatus => _service["EvaluationSyntheticStatus"];

        public string Unavailable => _service["EvaluationUnavailableLabel"];

        public string Complete => _service["EvaluationCompleteLabel"];

        public string MissingScore => _service["EvaluationMissingScoreLabel"];

        public string RankingEmpty => _service["EvaluationRankingEmptyLabel"];

        public string AverageScore => _service["EvaluationAverageScoreToday"];

        public string TotalEvaluations => _service["EvaluationTotalEvaluations"];

        public string LeaderReviewsPending => _service["EvaluationLeaderReviewsPending"];

        public string ProjectManagerReviewsPending => _service["EvaluationPmReviewsPending"];

        public string RecurringIssues => _service["EvaluationRecurringIssues"];

        public string Today => _service["EvaluationToday"];

        public string FromLastWeek => _service["EvaluationFromLastWeek"];

        public string OutOf100 => "/100";

        public string Records => _service["EvaluationEvaluations"];

        public string Count(int count) => _service.Format("EvaluationTotalEvaluationsFormat", count);

        public string ScoredCount(int count) => _service.Format("EvaluationScoredCountFormat", count);

        public string MissingScores(int count) => _service.Format("EvaluationMissingScoreDetailFormat", count);

        public string FromTotal(int count) => _service.Format("EvaluationFromTotalFormat", count);

        public string SelectedTask(string value) => _service.Format("EvaluationSelectedTaskFormat", value);

        public string SelectedAgent(string value) => _service.Format("EvaluationSelectedAgentFormat", value);

        public string ScoreDelta(decimal? delta)
        {
            if (delta is null)
            {
                return Unavailable;
            }

            var key = delta >= 0m ? "EvaluationDeltaUpFormat" : "EvaluationDeltaDownFormat";
            var value = Math.Abs(delta.Value).ToString("0.##", CultureInfo.InvariantCulture);
            return $"{_service.Format(key, value)} · {_service["EvaluationComparedToYesterday"]}";
        }

        public string Accessibility(string label, string value) =>
            $"{label}: {value}";

        public string DistributionLabel(string id) => _service[id switch
        {
            "excellent" => "EvaluationScoreBandExcellent",
            "good" => "EvaluationScoreBandGood",
            "pass" => "EvaluationScoreBandAcceptable",
            "improve" => "EvaluationScoreBandNeedsImprovement",
            _ => "EvaluationScoreBandFail",
        }];

        public string Date(DateOnly date) => date
            .ToDateTime(TimeOnly.MinValue)
            .ToString("d MMM", _culture);

        public string Dimension(EvaluationDimension dimension) => _service[dimension switch
        {
            EvaluationDimension.GoalAlignment => "EvaluationDimensionGoalAlignment",
            EvaluationDimension.AcceptanceCriteria => "EvaluationDimensionAcceptanceCriteria",
            EvaluationDimension.TechnicalQuality => "EvaluationDimensionTechnicalQuality",
            EvaluationDimension.ScopeCompliance => "EvaluationDimensionScopeCompliance",
            EvaluationDimension.Evidence => "EvaluationDimensionEvidence",
            _ => "EvaluationDimensionCommunication",
        }];

        public string DimensionStatus(EvaluationDimensionScoreStatus? status) => status switch
        {
            EvaluationDimensionScoreStatus.Complete => Complete,
            EvaluationDimensionScoreStatus.Missing => MissingScore,
            EvaluationDimensionScoreStatus.Invalid => _service["EvaluationInvalidLabel"],
            _ => Unavailable,
        };

        public string Tie(int rank) =>
            $"{_service["EvaluationTieLabel"]} · {_service.Format("EvaluationRankFormat", rank)}";

        public string RankingContext(string taskId, string taskLabel, string evaluationId) =>
            _service.Format("EvaluationRankingContextFormat", taskId, taskLabel, evaluationId);

        public string RankingProvenance(string formulaId, string snapshotHashDisplay) =>
            _service.Format("EvaluationRankingProvenanceFormat", formulaId, snapshotHashDisplay);

        public string RankingTrend(decimal? delta)
        {
            if (delta is null)
            {
                return Unavailable;
            }

            if (delta == 0m)
            {
                return _service["EvaluationRankingTrendAtAverage"];
            }

            var key = delta > 0m
                ? "EvaluationRankingTrendAboveAverageFormat"
                : "EvaluationRankingTrendBelowAverageFormat";
            return _service.Format(key, Math.Abs(delta.Value).ToString("0.##", CultureInfo.InvariantCulture));
        }
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
