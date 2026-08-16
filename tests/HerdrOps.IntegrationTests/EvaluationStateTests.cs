using HerdrOps.App.Evaluation;
using HerdrOps.App.Localization;

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
            Assert.HasCount(3, state.ComparisonRows);
            Assert.HasCount(5, state.TopAgents);
            Assert.HasCount(5, state.LowAgents);

            var expectedScored = state.Snapshot.Evaluations
                .Count(item => item.Result.Status == HerdrOps.Domain.Evaluation.EvaluationResultStatus.Complete);
            Assert.AreEqual(
                expectedScored,
                state.DistributionBins.Sum(item => item.Count),
                string.Join(", ", state.Snapshot.Evaluations.Select(item =>
                    $"{item.AgentId}:{item.Result.Status}:{item.Result.TotalScore}")));
            Assert.AreEqual(expectedScored, state.SummaryCards.Single(item => item.Id == "scored").Count);
            CollectionAssert.AreEqual(
                state.Snapshot.Trend.Select(item => item.Score).ToArray(),
                state.TrendPoints.Select(item => item.Score).ToArray());
            CollectionAssert.AreEqual(
                Enum.GetValues<HerdrOps.Domain.Evaluation.EvaluationDimension>(),
                state.DimensionRows.Select(item => item.Dimension).ToArray());
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
            StringAssert.Contains(state.MissingScoreLabel, "excluded from ranking and pass rate");
            Assert.AreEqual(1, state.SummaryCards.Single(item => item.Id == "missing").Count);
            Assert.AreEqual(5, state.SummaryCards.Single(item => item.Id == "pass-rate").Count);
            Assert.IsFalse(state.TopAgents.Any(item => item.AgentId == "agent-security-worker"));
            Assert.IsFalse(state.LowAgents.Any(item => item.AgentId == "agent-security-worker"));
            Assert.IsTrue(state.DimensionRows.Any(item => item.StatusLabel == "Missing score"));
            Assert.IsTrue(state.ComparisonRows.All(item => item.StatusText == "Missing score"));
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
            StringAssert.Contains(tie.TieLabel, "Tied at rank");
            StringAssert.Contains(tie.AccessibilityText, tie.AgentLabel);
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
            Assert.AreEqual("Average Score", state.SummaryCards.Single(item => item.Id == "average-score").Label);
            Assert.IsFalse(state.SummaryCards.Single(item => item.Id == "average-score").Label.Contains("คะแนน", StringComparison.Ordinal));
            Assert.AreEqual("Synthetic data", state.SourceLabel);
            Assert.IsFalse(state.EvidenceBoundaryLabel.Contains("หลักฐาน", StringComparison.Ordinal));
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
            Assert.AreEqual("Evaluation data unavailable", state.SourceLabel);
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
