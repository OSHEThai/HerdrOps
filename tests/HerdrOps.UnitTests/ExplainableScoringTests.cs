using HerdrOps.Domain.Evaluation;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace HerdrOps.UnitTests;

[TestClass]
public sealed class ExplainableScoringTests
{
    [TestMethod]
    public void GoldenVersion1FixtureIsDeterministicAndExplainable()
    {
        var engine = new EvaluationScoringEngine();
        var fixture = LoadGoldenFixture();

        var first = engine.Calculate(fixture.Input, EvaluationFormulaCatalog.Version1);
        var reordered = engine.Calculate(
            fixture.Input with
            {
                Dimensions = fixture.Input.Dimensions.Reverse().ToArray(),
            },
            EvaluationFormulaCatalog.Version1);

        Assert.AreEqual(EvaluationResultStatus.Complete, first.Status);
        Assert.AreEqual(fixture.ExpectedTotalScore, first.TotalScore);
        Assert.AreEqual(10_000, first.AvailableWeightBasisPoints);
        Assert.AreEqual(first.TotalScore, reordered.TotalScore);
        Assert.AreEqual(first.Provenance.InputSnapshotSha256, reordered.Provenance.InputSnapshotSha256);
        Assert.AreEqual(first.ResultSha256, reordered.ResultSha256);
        Assert.AreEqual(fixture.ExpectedFormulaSha256, first.Provenance.FormulaSha256);
        Assert.AreEqual(fixture.ExpectedInputSnapshotSha256, first.Provenance.InputSnapshotSha256);
        Assert.AreEqual(fixture.ExpectedResultSha256, first.ResultSha256);
        StringAssert.Matches(first.ResultSha256, new("^[0-9A-F]{64}$"));
        Assert.HasCount(6, first.Dimensions);
        Assert.IsTrue(first.Dimensions.All(item =>
            item.Status == EvaluationDimensionScoreStatus.Complete &&
            item.Issues.Count == 0 &&
            item.DimensionScore is not null &&
            item.WeightedScore is not null));
    }

    [TestMethod]
    public void MissingScoreRemainsVisibleAndCannotProduceAnOverallPass()
    {
        var snapshot = CompleteSnapshot();
        var goal = snapshot.Dimensions.Single(item =>
            item.Dimension == EvaluationDimension.GoalAlignment);
        var result = new EvaluationScoringEngine().Calculate(
            snapshot with
            {
                Dimensions = snapshot.Dimensions
                    .Select(item => item.Dimension == EvaluationDimension.GoalAlignment
                        ? goal with { ProjectManager = new(null, null, null) }
                        : item)
                    .ToArray(),
            },
            EvaluationFormulaCatalog.Version1);

        Assert.AreEqual(EvaluationResultStatus.Incomplete, result.Status);
        Assert.IsNull(result.TotalScore);
        Assert.AreEqual(8_000, result.AvailableWeightBasisPoints);
        var goalResult = result.Dimensions.Single(item =>
            item.Dimension == EvaluationDimension.GoalAlignment);
        Assert.AreEqual(EvaluationDimensionScoreStatus.Missing, goalResult.Status);
        Assert.IsTrue(goalResult.Issues.Any(item =>
            item.Source == EvaluationScoreSource.ProjectManager &&
            item.Code == "missing-score"));
    }

    [TestMethod]
    public void InvalidScoreAndProvenanceRemainVisibleAndCannotProduceAResult()
    {
        var snapshot = CompleteSnapshot();
        var evidence = snapshot.Dimensions.Single(item =>
            item.Dimension == EvaluationDimension.Evidence);
        var result = new EvaluationScoringEngine().Calculate(
            snapshot with
            {
                Dimensions = snapshot.Dimensions
                    .Select(item => item.Dimension == EvaluationDimension.Evidence
                        ? evidence with
                        {
                            ObjectiveEvidence = new(101, "objective:evidence", "not-a-hash"),
                        }
                        : item)
                    .ToArray(),
            },
            EvaluationFormulaCatalog.Version1);

        Assert.AreEqual(EvaluationResultStatus.Invalid, result.Status);
        Assert.IsNull(result.TotalScore);
        var evidenceResult = result.Dimensions.Single(item =>
            item.Dimension == EvaluationDimension.Evidence);
        CollectionAssert.AreEquivalent(
            new[] { "invalid-score-range", "invalid-provenance-sha256" },
            evidenceResult.Issues.Select(item => item.Code).ToArray());
    }

    [TestMethod]
    public void MissingAndDuplicateDimensionsFailClosed()
    {
        var snapshot = CompleteSnapshot();
        var withoutCommunication = snapshot with
        {
            Dimensions = snapshot.Dimensions
                .Where(item => item.Dimension != EvaluationDimension.Communication)
                .ToArray(),
        };
        var duplicateGoal = snapshot with
        {
            Dimensions = [.. snapshot.Dimensions, snapshot.Dimensions[0]],
        };
        var engine = new EvaluationScoringEngine();

        var missing = engine.Calculate(withoutCommunication, EvaluationFormulaCatalog.Version1);
        var duplicate = engine.Calculate(duplicateGoal, EvaluationFormulaCatalog.Version1);

        Assert.AreEqual(EvaluationResultStatus.Incomplete, missing.Status);
        Assert.IsTrue(missing.Dimensions.Any(item =>
            item.Dimension == EvaluationDimension.Communication &&
            item.Status == EvaluationDimensionScoreStatus.Missing));
        Assert.AreEqual(EvaluationResultStatus.Invalid, duplicate.Status);
        Assert.IsTrue(duplicate.Dimensions.Any(item =>
            item.Dimension == EvaluationDimension.GoalAlignment &&
            item.Issues.Any(issue => issue.Code == "duplicate-dimension")));
    }

    [TestMethod]
    public void HistoricalResultRecalculatesFromItsFrozenFormulaAfterCatalogChanges()
    {
        var engine = new EvaluationScoringEngine();
        var historical = engine.Calculate(CompleteSnapshot(), EvaluationFormulaCatalog.Version1);
        var changedFormula = EvaluationFormulaContract.Create(
            "HERDROPS-EVALUATION-V2-CANDIDATE",
            formulaVersion: 2,
            dimensionWeights:
            [
                new(EvaluationDimension.GoalAlignment, 2_500),
                new(EvaluationDimension.AcceptanceCriteria, 2_000),
                new(EvaluationDimension.TechnicalQuality, 2_000),
                new(EvaluationDimension.ScopeCompliance, 1_500),
                new(EvaluationDimension.Evidence, 1_000),
                new(EvaluationDimension.Communication, 1_000),
            ],
            sourceWeights:
            [
                new(EvaluationScoreSource.Leader, 2_500),
                new(EvaluationScoreSource.ProjectManager, 2_500),
                new(EvaluationScoreSource.ObjectiveEvidence, 5_000),
            ]);

        var currentCandidate = engine.Calculate(CompleteSnapshot(), changedFormula);
        var reproduced = engine.Recalculate(historical);

        Assert.AreNotEqual(historical.Provenance.FormulaSha256, currentCandidate.Provenance.FormulaSha256);
        Assert.AreNotEqual(historical.TotalScore, currentCandidate.TotalScore);
        Assert.AreEqual(historical.TotalScore, reproduced.TotalScore);
        Assert.AreEqual(historical.ResultSha256, reproduced.ResultSha256);
        Assert.AreEqual(historical.Provenance.FormulaSha256, reproduced.Provenance.FormulaSha256);
        Assert.AreEqual(historical.Provenance.InputSnapshotSha256, reproduced.Provenance.InputSnapshotSha256);
    }

    [TestMethod]
    public void HistoricalRecalculationRejectsTamperedResultAndInputProvenance()
    {
        var engine = new EvaluationScoringEngine();
        var historical = engine.Calculate(CompleteSnapshot(), EvaluationFormulaCatalog.Version1);
        var firstDimension = historical.Provenance.InputSnapshot.Dimensions[0];
        var tamperedInput = historical with
        {
            Provenance = historical.Provenance with
            {
                InputSnapshot = historical.Provenance.InputSnapshot with
                {
                    Dimensions = historical.Provenance.InputSnapshot.Dimensions
                        .Select(item => item.Dimension == firstDimension.Dimension
                            ? item with
                            {
                                Leader = item.Leader with { Score = item.Leader.Score + 1 },
                            }
                            : item)
                        .ToArray(),
                },
            },
        };
        var tamperedResult = historical with { TotalScore = historical.TotalScore + 1m };

        Assert.ThrowsExactly<EvaluationScoringContractException>(() =>
            engine.Recalculate(tamperedInput));
        Assert.ThrowsExactly<EvaluationScoringContractException>(() =>
            engine.Recalculate(tamperedResult));
    }

    [TestMethod]
    public void FormulaRejectsMissingDimensionsWeightDriftAndHashTampering()
    {
        var formula = EvaluationFormulaCatalog.Version1;

        Assert.ThrowsExactly<EvaluationScoringContractException>(() =>
            EvaluationFormulaContract.Create(
                "missing-dimension",
                1,
                formula.DimensionWeights.Take(5).ToArray(),
                formula.SourceWeights));
        Assert.ThrowsExactly<EvaluationScoringContractException>(() =>
            EvaluationFormulaContract.Create(
                "weight-drift",
                1,
                formula.DimensionWeights
                    .Select(item => item.Dimension == EvaluationDimension.GoalAlignment
                        ? item with { WeightBasisPoints = item.WeightBasisPoints + 1 }
                        : item)
                    .ToArray(),
                formula.SourceWeights));
        Assert.ThrowsExactly<EvaluationScoringContractException>(() =>
            EvaluationFormulaContract.NormalizeAndValidate(
                formula with { FormulaSha256 = new string('0', 64) }));
    }

    private static EvaluationInputSnapshot CompleteSnapshot() =>
        LoadGoldenFixture().Input;

    private static GoldenFixture LoadGoldenFixture()
    {
        var path = Path.Combine(
            AppContext.BaseDirectory,
            "Fixtures",
            "scoring-golden-v1.json");
        var options = new JsonSerializerOptions
        {
            PropertyNameCaseInsensitive = true,
            Converters = { new JsonStringEnumConverter() },
        };
        return JsonSerializer.Deserialize<GoldenFixture>(File.ReadAllText(path), options)
            ?? throw new InvalidOperationException("The v0.6 golden scoring fixture was null.");
    }

    private sealed record GoldenFixture(
        EvaluationInputSnapshot Input,
        decimal ExpectedTotalScore,
        string ExpectedFormulaSha256,
        string ExpectedInputSnapshotSha256,
        string ExpectedResultSha256);
}
