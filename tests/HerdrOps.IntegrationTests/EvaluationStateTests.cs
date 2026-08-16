using HerdrOps.App.Evaluation;
using HerdrOps.App.Localization;
using HerdrOps.Domain.Evaluation;

namespace HerdrOps.IntegrationTests;

[TestClass]
[DoNotParallelize]
public sealed class EvaluationStateTests
{
    [TestMethod]
    public void SyntheticPreview_UsesOneSnapshotForEveryPresentationSurface()
    {
        WithLanguage(UiLanguage.English, () =>
        {
            var state = EvaluationState.CreateSyntheticPreview();

            Assert.AreEqual(EvaluationSnapshotAvailability.Available, state.Snapshot.Availability);
            Assert.AreSame(state.Snapshot, state.Snapshot);
            Assert.AreEqual(state.Snapshot.Evaluations.Count, state.EvaluationCountTotal);
            Assert.AreEqual(5, state.EvaluationCountTotal);
            Assert.HasCount(7, state.TrendPoints);
            Assert.HasCount(6, state.DimensionRows);
            Assert.HasCount(6, state.ComparisonRows);
            Assert.HasCount(5, state.TopAgents);
            Assert.HasCount(5, state.LowAgents);
            CollectionAssert.AreEqual(
                new[] { "average-score", "evaluations", "leader-pending", "pm-pending", "recurring" },
                state.SummaryCards.Select(item => item.Id).ToArray());

            var expectedScored = state.Snapshot.Evaluations
                .Count(item => item.Result.Status == EvaluationResultStatus.Complete);
            Assert.AreEqual(
                expectedScored,
                state.DistributionBins.Sum(item => item.Count),
                string.Join(", ", state.Snapshot.Evaluations.Select(item =>
                    $"{item.AgentId}:{item.Result.Status}:{item.Result.TotalScore}")));
            Assert.AreEqual(
                decimal.Round(
                    state.Snapshot.Evaluations
                        .Where(item => item.Result.TotalScore is not null)
                        .Average(item => item.Result.TotalScore!.Value),
                    2,
                    MidpointRounding.AwayFromZero),
                state.SummaryCards.Single(item => item.Id == "average-score").Score);
            Assert.AreEqual(
                state.Snapshot.LeaderReviewsPending,
                state.SummaryCards.Single(item => item.Id == "leader-pending").Count);
            Assert.AreEqual(
                state.Snapshot.ProjectManagerReviewsPending,
                state.SummaryCards.Single(item => item.Id == "pm-pending").Count);
            CollectionAssert.AreEqual(
                state.Snapshot.Trend.Select(item => item.Score).ToArray(),
                state.TrendPoints.Select(item => item.Score).ToArray());
            CollectionAssert.AreEqual(
                Enum.GetValues<EvaluationDimension>(),
                state.DimensionRows.Select(item => item.Dimension).ToArray());

            var selected = state.Snapshot.Evaluations.Single(item =>
                item.TaskId == state.Snapshot.SelectedTaskId &&
                item.AgentId == state.Snapshot.SelectedAgentId);
            foreach (var row in state.ComparisonRows)
            {
                var result = selected.Result.Dimensions.Single(item => item.Dimension == row.Dimension);
                Assert.AreEqual(result.Leader.Score, row.LeaderScore);
                Assert.AreEqual(result.ProjectManager.Score, row.ProjectManagerScore);
                Assert.AreEqual(result.ObjectiveEvidence.Score, row.ObjectiveEvidenceScore);
                Assert.AreEqual(result.WeightedScore, row.WeightedScore);
                Assert.AreEqual(result.Leader.ProvenanceId, row.LeaderProvenanceId);
                Assert.AreEqual(result.Leader.EvidenceIdentitySha256, row.LeaderEvidenceIdentitySha256);
                Assert.IsFalse(string.IsNullOrWhiteSpace(row.ObjectiveEvidenceProvenanceId));
            }

            Assert.AreEqual(selected.Result.Provenance.InputSnapshotSha256, state.ComparisonSnapshotSha256);
            Assert.AreEqual(selected.Result.Provenance.Formula.FormulaId, state.ComparisonFormulaLabel);
        });
    }

    [TestMethod]
    public void MissingScorePreview_IsExplicitAndExcludedFromPassAndRanking()
    {
        WithLanguage(UiLanguage.English, () =>
        {
            var state = EvaluationState.CreateMissingScorePreview();

            Assert.AreEqual(6, state.EvaluationCountTotal);
            Assert.AreEqual(1, state.MissingScoreCount);
            StringAssert.Contains(state.MissingScoreLabel, "excluded from ranking");
            Assert.AreEqual(6, state.SummaryCards.Single(item => item.Id == "evaluations").Count);
            Assert.AreEqual(5, state.DistributionBins.Sum(item => item.Count));
            Assert.IsFalse(state.TopAgents.Any(item => item.AgentId == "agent-security-worker"));
            Assert.IsFalse(state.LowAgents.Any(item => item.AgentId == "agent-security-worker"));
            Assert.IsTrue(state.DimensionRows.Any(item => item.StatusLabel == "Missing score"));
            Assert.AreEqual(
                "Missing score",
                state.ComparisonRows.Single(item => item.Dimension == EvaluationDimension.Communication).StatusText);
            Assert.AreEqual(
                5,
                state.ComparisonRows.Count(item => item.StatusText == "Complete"));
            Assert.IsNull(state.ComparisonRows.Single(item =>
                item.Dimension == EvaluationDimension.Communication).WeightedScore);
        });
    }

    [TestMethod]
    public void Rankings_MakeEqualScoresDeterministicAndExplicit()
    {
        WithLanguage(UiLanguage.English, () =>
        {
            var first = EvaluationState.CreateSyntheticPreview();
            var second = EvaluationState.CreateSyntheticPreview();

            CollectionAssert.AreEqual(
                first.TopAgents.Select(item => item.AgentId).ToArray(),
                second.TopAgents.Select(item => item.AgentId).ToArray());
            Assert.IsTrue(first.TopAgents.Any(item => item.IsTie));
            var tie = first.TopAgents.First(item => item.IsTie);
            StringAssert.Contains(tie.TieLabel, "Tied");
            StringAssert.Contains(tie.TieLabel, "Rank");
            StringAssert.Contains(tie.AccessibilityText, tie.AgentLabel);
            var tiedAgents = first.TopAgents
                .Where(item => item.IsTie)
                .Select(item => item.AgentId)
                .ToArray();
            CollectionAssert.AreEqual(
                tiedAgents.OrderBy(item => item, StringComparer.Ordinal).ToArray(),
                tiedAgents);
        });
    }

    [TestMethod]
    public void RefreshLanguage_RendersExactlyOneSelectedLanguage()
    {
        var service = UiLanguageService.Shared;
        var previous = service.CurrentLanguage;
        try
        {
            service.SetLanguage(UiLanguage.Thai);
            var state = EvaluationState.CreateSyntheticPreview();
            StringAssert.Contains(state.SummaryCards.Single(item => item.Id == "average-score").Label, "คะแนน");
            Assert.IsFalse(state.SummaryCards.Single(item => item.Id == "average-score").Label.Contains("Average", StringComparison.Ordinal));

            service.SetLanguage(UiLanguage.English);
            state.RefreshLanguage();
            Assert.AreEqual(UiLanguage.English, state.SelectedLanguage);
            Assert.AreEqual("Average Score Today", state.SummaryCards.Single(item => item.Id == "average-score").Label);
            Assert.IsFalse(state.SummaryCards.Single(item => item.Id == "average-score").Label.Contains("คะแนน", StringComparison.Ordinal));
            Assert.AreEqual("Deterministic synthetic evaluation data", state.SourceLabel);
            Assert.AreEqual(
                "Screen preview only · not evidence from a running Herdr instance",
                state.EvidenceBoundaryLabel);
        }
        finally
        {
            service.SetLanguage(previous);
        }
    }

    [TestMethod]
    public void UnavailablePreview_ReportsUnavailableWithoutRankingData()
    {
        WithLanguage(UiLanguage.English, () =>
        {
            var state = EvaluationState.CreateUnavailable();

            Assert.AreEqual(EvaluationSnapshotAvailability.Unavailable, state.Snapshot.Availability);
            Assert.AreEqual(0, state.EvaluationCountTotal);
            Assert.IsEmpty(state.TopAgents);
            Assert.IsEmpty(state.LowAgents);
            Assert.IsTrue(state.DimensionRows.All(item => item.StatusLabel == "Unavailable"));
            Assert.IsTrue(state.ComparisonRows.All(item => item.StatusText == "Unavailable"));
            Assert.IsTrue(state.TrendPoints.All(item => item.Score is null));
            Assert.AreEqual("Live Evaluation source unavailable", state.SourceLabel);
            Assert.AreEqual("No live Herdr state is available for Evaluation", state.EvidenceBoundaryLabel);
        });
    }

    private static void WithLanguage(UiLanguage language, Action action)
    {
        var service = UiLanguageService.Shared;
        var previous = service.CurrentLanguage;
        try
        {
            service.SetLanguage(language);
            action();
        }
        finally
        {
            service.SetLanguage(previous);
        }
    }
}
