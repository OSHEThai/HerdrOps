using System.Security.Cryptography;
using System.Text;
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
            Assert.AreEqual("84.51", state.DimensionWeightedAverageLabel);
            Assert.AreEqual("93.25", state.ComparisonTotalScoreLabel);
            Assert.AreEqual(100m, state.ComparisonTotal.TotalWeightPercentage);
            Assert.AreEqual("100%", state.ComparisonTotal.TotalWeightLabel);
            Assert.AreEqual(93.05m, state.ComparisonTotal.LeaderScore);
            Assert.AreEqual(91.05m, state.ComparisonTotal.ProjectManagerScore);
            Assert.AreEqual(95.05m, state.ComparisonTotal.ObjectiveEvidenceScore);
            Assert.AreEqual("93.25", state.ComparisonTotal.WeightedScoreLabel);
        });
    }

    [TestMethod]
    public void EvaluationView_UsesDistinctAggregateAndSelectedTotalBindings()
    {
        var source = File.ReadAllText(Path.Combine(
            FindRepositoryRoot(),
            "src",
            "HerdrOps.App",
            "Views",
            "EvaluationView.xaml"));
        var dimensionStart = source.IndexOf(
            "x:Name=\"EvaluationDimensionRegion\"",
            StringComparison.Ordinal);
        var comparisonStart = source.IndexOf(
            "x:Name=\"EvaluationComparisonRegion\"",
            StringComparison.Ordinal);
        Assert.IsGreaterThanOrEqualTo(0, dimensionStart);
        Assert.IsGreaterThan(dimensionStart, comparisonStart);
        var dimensionRegion = source[dimensionStart..comparisonStart];
        var comparisonRegion = source[comparisonStart..];

        StringAssert.Contains(dimensionRegion, "Text=\"{Binding DimensionWeightedAverageLabel}\"");
        Assert.IsFalse(dimensionRegion.Contains(
            "Text=\"{Binding ComparisonTotalScoreLabel}\"",
            StringComparison.Ordinal));
        StringAssert.Contains(comparisonRegion, "Text=\"{Binding ComparisonTotalScoreLabel}\"");
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
            Assert.AreEqual(5, state.EvaluationCountScored);
            Assert.AreEqual("5 / 6", state.DistributionCenterValue);
            Assert.AreEqual("5 complete scored evaluations", state.DistributionCenterLabel);
            StringAssert.Contains(state.DistributionCenterAccessibilityText, "5 complete scored evaluations");
            StringAssert.Contains(state.DistributionCenterAccessibilityText, "6 evaluations");
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
    public void EmbeddedFormulaWeightsAreUsedAndInconsistentWeightsFailClosed()
    {
        WithLanguage(UiLanguage.English, () =>
        {
            var formula = CreateNonVersionOneFormula();
            var record = CreateRecord(
                "evaluation-custom-formula",
                "TASK-CUSTOM",
                "Custom formula task",
                "agent-custom",
                "Custom Agent",
                [20, 40, 60, 80, 70, 50],
                formula);
            var state = new EvaluationState(CreateSnapshot(record));

            Assert.AreEqual(formula.FormulaId, state.ComparisonFormulaLabel);
            Assert.AreEqual(
                formula.DimensionWeights.Single(item => item.Dimension == EvaluationDimension.GoalAlignment).WeightBasisPoints / 100m,
                state.DimensionRows.Single(item => item.Dimension == EvaluationDimension.GoalAlignment).WeightPercentage);
            Assert.AreEqual(
                formula.DimensionWeights.Single(item => item.Dimension == EvaluationDimension.GoalAlignment).WeightBasisPoints / 100m,
                state.ComparisonRows.Single(item => item.Dimension == EvaluationDimension.GoalAlignment).WeightPercentage);

            var tampered = record with
            {
                Result = record.Result with
                {
                    Dimensions = record.Result.Dimensions
                        .Select((item, index) => index == 0
                            ? item with { WeightBasisPoints = item.WeightBasisPoints + 1 }
                            : item)
                        .ToArray(),
                },
            };
            var failClosed = new EvaluationState(CreateSnapshot(tampered));

            Assert.AreEqual("Unavailable", failClosed.ComparisonFormulaLabel);
            Assert.IsNull(failClosed.DimensionRows.Single(item => item.Dimension == EvaluationDimension.GoalAlignment).WeightPercentage);
            Assert.IsNull(failClosed.ComparisonRows.Single(item => item.Dimension == EvaluationDimension.GoalAlignment).WeightPercentage);
            Assert.AreEqual("Unavailable", failClosed.ComparisonRows.Single(item => item.Dimension == EvaluationDimension.GoalAlignment).WeightLabel);
            Assert.IsNull(failClosed.ComparisonRows.Single(item => item.Dimension == EvaluationDimension.GoalAlignment).WeightedScore);
        });
    }

    [TestMethod]
    public void TamperedAcceptedResultsAreRejectedBeforePresentation()
    {
        WithLanguage(UiLanguage.English, () =>
        {
            var record = CreateRecord(
                "evaluation-tamper",
                "TASK-TAMPER",
                "Tamper task",
                "agent-tamper",
                "Tamper Agent",
                [88, 86, 84, 82, 80, 78],
                EvaluationFormulaCatalog.Version1);
            var result = record.Result;
            var tamperedResults = new (string Name, EvaluationScoreResult Result)[]
            {
                (
                    "total",
                    result with { TotalScore = result.TotalScore!.Value + 1m }),
                (
                    "weighted dimension",
                    result with
                    {
                        Dimensions = result.Dimensions
                            .Select((item, index) => index == 0
                                ? item with { WeightedScore = item.WeightedScore!.Value + 1m }
                                : item)
                            .ToArray(),
                    }),
                (
                    "input hash",
                    result with
                    {
                        Provenance = result.Provenance with
                        {
                            InputSnapshotSha256 = new string('0', 64),
                        },
                    }),
                (
                    "result hash",
                    result with { ResultSha256 = new string('0', 64) }),
            };

            foreach (var tampered in tamperedResults)
            {
                var state = new EvaluationState(CreateSnapshot(record with { Result = tampered.Result }));
                AssertTamperedResultFailsClosed(state, tampered.Name);
            }
        });
    }

    [TestMethod]
    public void DimensionWeightedAverageUsesEveryCompleteRecordAndKeepsSelectedTotalSeparate()
    {
        WithLanguage(UiLanguage.English, () =>
        {
            var formula = CreateNonVersionOneFormula();
            var selected = CreateRecord(
                "evaluation-selected",
                "TASK-SELECTED",
                "Selected task",
                "agent-selected",
                "Selected Agent",
                [50, 50, 50, 50, 50, 50],
                formula);
            var other = CreateRecord(
                "evaluation-other",
                "TASK-OTHER",
                "Other task",
                "agent-other",
                "Other Agent",
                [90, 90, 90, 90, 90, 90],
                formula);
            var state = new EvaluationState(CreateSnapshot(selected, other));

            Assert.AreEqual("50", state.ComparisonTotalScoreLabel);
            Assert.AreEqual("70", state.DimensionWeightedAverageLabel);
            Assert.AreNotEqual(state.ComparisonTotalScoreLabel, state.DimensionWeightedAverageLabel);
        });
    }

    [TestMethod]
    public void RankingsExposeLocalizedContextTrendAndTraceableProvenance()
    {
        var formula = CreateNonVersionOneFormula();
        var high = CreateRecord(
            "evaluation-high",
            "TASK-HIGH",
            "High task",
            "agent-high",
            "High Agent",
            [90, 90, 90, 90, 90, 90],
            formula);
        var low = CreateRecord(
            "evaluation-low",
            "TASK-LOW",
            "Low task",
            "agent-low",
            "Low Agent",
            [60, 60, 60, 60, 60, 60],
            formula);

        WithLanguage(UiLanguage.English, () =>
        {
            var state = new EvaluationState(CreateSnapshot(high, low));
            var row = state.TopAgents.Single(item => item.AgentId == "agent-high");
            var expectedHash = high.Result.Provenance.InputSnapshotSha256;

            Assert.AreEqual("TASK-HIGH", row.TaskId);
            Assert.AreEqual("High task", row.TaskLabel);
            Assert.AreEqual("evaluation-high", row.EvaluationId);
            StringAssert.Contains(row.ContextLabel, "Task TASK-HIGH: High task");
            StringAssert.Contains(row.ContextLabel, "evaluation evaluation-high");
            Assert.AreEqual(formula.FormulaId, row.FormulaId);
            Assert.AreEqual(expectedHash, row.InputSnapshotSha256);
            Assert.AreEqual($"{expectedHash[..12]}…", row.InputSnapshotSha256Display);
            Assert.AreEqual(expectedHash, row.InputSnapshotSha256AccessibilityValue);
            Assert.AreEqual(15m, row.TrendDelta);
            StringAssert.Contains(row.TrendLabel, "above snapshot average");
            StringAssert.Contains(row.ProvenanceLabel, formula.FormulaId);
            StringAssert.Contains(row.AccessibilityText, expectedHash);
            Assert.IsFalse(row.TrendLabel.Contains("history", StringComparison.OrdinalIgnoreCase));
        });

        WithLanguage(UiLanguage.Thai, () =>
        {
            var state = new EvaluationState(CreateSnapshot(high, low));
            var row = state.TopAgents.Single(item => item.AgentId == "agent-high");

            StringAssert.Contains(row.ContextLabel, "งาน");
            Assert.IsFalse(row.ContextLabel.Contains("Task ", StringComparison.Ordinal));
            StringAssert.Contains(row.TrendLabel, "สูงกว่าค่าเฉลี่ยชุดข้อมูล");
            Assert.IsFalse(row.TrendLabel.Contains("snapshot average", StringComparison.Ordinal));
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
        foreach (var language in new[] { UiLanguage.English, UiLanguage.Thai })
        {
            WithLanguage(language, () =>
            {
                var service = UiLanguageService.Shared;
                var unavailable = service["EvaluationUnavailableLabel"];
                var synthetic = service["EvaluationSyntheticStatus"];
                var missing = service["EvaluationMissingScoreLabel"];
                var state = EvaluationState.CreateUnavailable();

                Assert.AreEqual(EvaluationSnapshotAvailability.Unavailable, state.Snapshot.Availability);
                Assert.AreEqual(0, state.EvaluationCountTotal);
                Assert.AreEqual(0, state.EvaluationCountScored);
                Assert.IsEmpty(state.TopAgents);
                Assert.IsEmpty(state.LowAgents);
                Assert.AreEqual(service["EvaluationRankingUnavailable"], state.RankingEmptyLabel);
                Assert.AreEqual(unavailable, state.MissingScoreLabel);
                Assert.AreEqual(unavailable, state.EvaluationCountLabel);
                Assert.AreEqual(unavailable, state.DistributionTotalLabel);
                Assert.AreEqual(unavailable, state.DistributionCenterValue);
                Assert.AreEqual(unavailable, state.DistributionCenterLabel);
                Assert.IsFalse(state.MissingScoreLabel.Contains(missing, StringComparison.Ordinal));
                Assert.IsTrue(state.SummaryCards.All(item =>
                    item.Value == unavailable &&
                    item.MetricLabel == unavailable &&
                    item.TrendLabel == unavailable &&
                    item.Score is null &&
                    item.Count is null &&
                    item.Percentage is null));
                Assert.IsTrue(state.DimensionRows.All(item => item.StatusLabel == unavailable));
                Assert.IsTrue(state.DimensionRows.All(item => item.ScoreLabel == unavailable));
                Assert.IsTrue(state.ComparisonRows.All(item =>
                    item.WeightLabel == unavailable &&
                    item.LeaderScoreLabel == unavailable &&
                    item.ProjectManagerScoreLabel == unavailable &&
                    item.ObjectiveEvidenceScoreLabel == unavailable &&
                    item.WeightedScoreLabel == unavailable &&
                    item.StatusText == unavailable &&
                    !item.AccessibilityText.Contains("—", StringComparison.Ordinal)));
                Assert.AreEqual(unavailable, state.ComparisonTotal.TotalWeightLabel);
                Assert.AreEqual(unavailable, state.ComparisonTotal.LeaderScoreLabel);
                Assert.AreEqual(unavailable, state.ComparisonTotal.ProjectManagerScoreLabel);
                Assert.AreEqual(unavailable, state.ComparisonTotal.ObjectiveEvidenceScoreLabel);
                Assert.AreEqual(unavailable, state.ComparisonTotal.WeightedScoreLabel);
                Assert.AreEqual(unavailable, state.ComparisonTotal.StatusText);
                Assert.IsTrue(state.TrendPoints.All(item =>
                    item.Score is null &&
                    item.ScoreLabel == unavailable &&
                    item.StatusText == unavailable));
                Assert.IsTrue(state.DistributionBins.All(item =>
                    item.Count == 0 &&
                    item.CountLabel == unavailable &&
                    item.Percentage == -1m &&
                    item.PercentageLabel == unavailable &&
                    item.StatusText == unavailable));
                Assert.IsFalse(state.DistributionBins.Any(item => item.StatusText == synthetic));
                Assert.IsFalse(state.SummaryCards.Any(item =>
                    item.Value.Contains("0", StringComparison.Ordinal) ||
                    item.MetricLabel.Contains("Today", StringComparison.Ordinal) ||
                    item.TrendLabel.Contains("from 0", StringComparison.Ordinal) ||
                    item.TrendLabel.Contains("Synthetic", StringComparison.Ordinal)));
                Assert.AreEqual(
                    language == UiLanguage.English
                        ? "Live Evaluation source unavailable"
                        : "ยังไม่มีแหล่งข้อมูลการประเมินแบบสด",
                    state.SourceLabel);
                Assert.AreEqual(
                    language == UiLanguage.English
                        ? "No live Herdr state is available for Evaluation"
                        : "ยังไม่มีสถานะสดจาก Herdr สำหรับหน้าการประเมิน",
                    state.EvidenceBoundaryLabel);
            });
        }
    }

    private static void AssertTamperedResultFailsClosed(EvaluationState state, string mutation)
    {
        var invalid = UiLanguageService.Shared["EvaluationInvalidLabel"];
        var unavailable = UiLanguageService.Shared["EvaluationUnavailableLabel"];
        Assert.AreEqual(1, state.EvaluationCountTotal, mutation);
        Assert.AreEqual(0, state.EvaluationCountScored, mutation);
        Assert.AreEqual(1, state.InvalidScoreCount, mutation);
        Assert.IsEmpty(state.TopAgents, mutation);
        Assert.IsEmpty(state.LowAgents, mutation);
        Assert.AreEqual(invalid, state.ComparisonTotalScoreLabel, mutation);
        Assert.AreEqual(unavailable, state.ComparisonFormulaLabel, mutation);
        Assert.AreEqual(string.Empty, state.ComparisonSnapshotSha256, mutation);
        Assert.IsTrue(state.DimensionRows.All(item =>
            item.Score is null && item.StatusLabel == invalid), mutation);
        Assert.IsTrue(state.ComparisonRows.All(item =>
            item.WeightedScore is null && item.StatusText == invalid), mutation);
        Assert.IsTrue(state.DistributionBins.All(item =>
            item.Count == 0 && item.StatusText == invalid), mutation);
    }

    private static EvaluationFormulaDefinition CreateNonVersionOneFormula() =>
        EvaluationFormulaContract.Create(
            "HERDROPS-EVALUATION-TEST-V2",
            formulaVersion: 2,
            dimensionWeights:
            [
                new(EvaluationDimension.GoalAlignment, 1_000),
                new(EvaluationDimension.AcceptanceCriteria, 2_500),
                new(EvaluationDimension.TechnicalQuality, 1_500),
                new(EvaluationDimension.ScopeCompliance, 2_000),
                new(EvaluationDimension.Evidence, 2_000),
                new(EvaluationDimension.Communication, 1_000),
            ],
            sourceWeights:
            [
                new(EvaluationScoreSource.Leader, 2_000),
                new(EvaluationScoreSource.ProjectManager, 3_500),
                new(EvaluationScoreSource.ObjectiveEvidence, 4_500),
            ]);

    private static EvaluationSnapshotRecord CreateRecord(
        string evaluationId,
        string taskId,
        string taskLabel,
        string agentId,
        string agentLabel,
        IReadOnlyList<int> scores,
        EvaluationFormulaDefinition formula)
    {
        var dimensions = Enum.GetValues<EvaluationDimension>()
            .Select((dimension, index) => new EvaluationDimensionInput(
                dimension,
                Score(scores[index], $"{evaluationId}:leader:{index}"),
                Score(scores[index], $"{evaluationId}:pm:{index}"),
                Score(scores[index], $"{evaluationId}:evidence:{index}")))
            .ToArray();
        var result = new EvaluationScoringEngine().Calculate(
            new EvaluationInputSnapshot(
                EvaluationFormulaCatalog.ContractVersion,
                evaluationId,
                taskId,
                agentId,
                dimensions),
            formula);
        return new EvaluationSnapshotRecord(evaluationId, taskId, taskLabel, agentId, agentLabel, result);
    }

    private static EvaluationSnapshot CreateSnapshot(params EvaluationSnapshotRecord[] records) =>
        new(
            EvaluationSnapshotAvailability.Available,
            records,
            [],
            records[0].TaskId,
            records[0].AgentId,
            new DateOnly(2026, 8, 17),
            previousAverageScore: null,
            leaderReviewsPending: 0,
            projectManagerReviewsPending: 0,
            recurringIssueCount: 0);

    private static EvaluationScoreInput Score(int score, string provenanceId) =>
        new(
            score,
            provenanceId,
            Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(provenanceId))));

    private static string FindRepositoryRoot()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null)
        {
            if (File.Exists(Path.Combine(directory.FullName, "HerdrOps.sln")))
            {
                return directory.FullName;
            }

            directory = directory.Parent;
        }

        Assert.Fail("Could not locate HerdrOps.sln from the Integration test output directory.");
        return string.Empty;
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
