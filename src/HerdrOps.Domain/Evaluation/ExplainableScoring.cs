using System.Globalization;
using HerdrOps.Domain.Activity;

namespace HerdrOps.Domain.Evaluation;

public enum EvaluationDimension
{
    GoalAlignment = 1,
    AcceptanceCriteria = 2,
    TechnicalQuality = 3,
    ScopeCompliance = 4,
    Evidence = 5,
    Communication = 6,
}

public enum EvaluationScoreSource
{
    Leader = 1,
    ProjectManager = 2,
    ObjectiveEvidence = 3,
}

public enum EvaluationDimensionScoreStatus
{
    Complete = 1,
    Missing = 2,
    Invalid = 3,
}

public enum EvaluationResultStatus
{
    Complete = 1,
    Incomplete = 2,
    Invalid = 3,
}

public sealed record EvaluationDimensionWeight(
    EvaluationDimension Dimension,
    int WeightBasisPoints);

public sealed record EvaluationSourceWeight(
    EvaluationScoreSource Source,
    int WeightBasisPoints);

public sealed record EvaluationFormulaDefinition(
    int ContractVersion,
    string FormulaId,
    int FormulaVersion,
    IReadOnlyList<EvaluationDimensionWeight> DimensionWeights,
    IReadOnlyList<EvaluationSourceWeight> SourceWeights,
    string FormulaSha256);

public sealed record EvaluationScoreInput(
    int? Score,
    string? ProvenanceId,
    string? EvidenceIdentitySha256);

public sealed record EvaluationDimensionInput(
    EvaluationDimension Dimension,
    EvaluationScoreInput Leader,
    EvaluationScoreInput ProjectManager,
    EvaluationScoreInput ObjectiveEvidence);

public sealed record EvaluationInputSnapshot(
    int ContractVersion,
    string EvaluationId,
    string TaskId,
    string AgentId,
    IReadOnlyList<EvaluationDimensionInput> Dimensions);

public sealed record EvaluationInputIssue(
    EvaluationDimension? Dimension,
    EvaluationScoreSource? Source,
    string Code,
    string Message);

public sealed record EvaluationDimensionScore(
    EvaluationDimension Dimension,
    int WeightBasisPoints,
    EvaluationDimensionScoreStatus Status,
    IReadOnlyList<EvaluationDimensionInput> ObservedInputs,
    EvaluationScoreInput Leader,
    EvaluationScoreInput ProjectManager,
    EvaluationScoreInput ObjectiveEvidence,
    decimal? DimensionScore,
    decimal? WeightedScore,
    IReadOnlyList<EvaluationInputIssue> Issues);

public sealed record EvaluationProvenanceRecord(
    EvaluationFormulaDefinition Formula,
    EvaluationInputSnapshot InputSnapshot,
    string FormulaSha256,
    string InputSnapshotSha256);

public sealed record EvaluationScoreResult(
    int ContractVersion,
    string EvaluationId,
    string TaskId,
    string AgentId,
    EvaluationResultStatus Status,
    decimal? TotalScore,
    int AvailableWeightBasisPoints,
    IReadOnlyList<EvaluationInputIssue> InputIssues,
    IReadOnlyList<EvaluationDimensionScore> Dimensions,
    EvaluationProvenanceRecord Provenance,
    string ResultSha256);

public sealed class EvaluationScoringContractException(string message) : Exception(message);

public static class EvaluationFormulaCatalog
{
    public const int ContractVersion = 1;
    public const string Version1FormulaId = "HERDROPS-EVALUATION-V1";

    public static EvaluationFormulaDefinition Version1 { get; } =
        EvaluationFormulaContract.Create(
            Version1FormulaId,
            formulaVersion: 1,
            dimensionWeights:
            [
                new(EvaluationDimension.GoalAlignment, 2_000),
                new(EvaluationDimension.AcceptanceCriteria, 2_000),
                new(EvaluationDimension.TechnicalQuality, 2_000),
                new(EvaluationDimension.ScopeCompliance, 1_500),
                new(EvaluationDimension.Evidence, 1_500),
                new(EvaluationDimension.Communication, 1_000),
            ],
            sourceWeights:
            [
                new(EvaluationScoreSource.Leader, 3_000),
                new(EvaluationScoreSource.ProjectManager, 3_000),
                new(EvaluationScoreSource.ObjectiveEvidence, 4_000),
            ]);
}

public static class EvaluationFormulaContract
{
    private static readonly EvaluationDimension[] ExpectedDimensions =
        Enum.GetValues<EvaluationDimension>();
    private static readonly EvaluationScoreSource[] ExpectedSources =
        Enum.GetValues<EvaluationScoreSource>();

    public static EvaluationFormulaDefinition Create(
        string formulaId,
        int formulaVersion,
        IReadOnlyList<EvaluationDimensionWeight> dimensionWeights,
        IReadOnlyList<EvaluationSourceWeight> sourceWeights)
    {
        var candidate = new EvaluationFormulaDefinition(
            EvaluationFormulaCatalog.ContractVersion,
            formulaId,
            formulaVersion,
            dimensionWeights,
            sourceWeights,
            string.Empty);
        return NormalizeAndValidate(candidate);
    }

    public static EvaluationFormulaDefinition NormalizeAndValidate(
        EvaluationFormulaDefinition formula)
    {
        ArgumentNullException.ThrowIfNull(formula);
        if (formula.ContractVersion != EvaluationFormulaCatalog.ContractVersion)
        {
            throw new EvaluationScoringContractException(
                $"Unsupported evaluation formula contract v{formula.ContractVersion}.");
        }

        var formulaId = NormalizeRequired(formula.FormulaId, nameof(formula.FormulaId));
        if (formula.FormulaVersion <= 0)
        {
            throw new EvaluationScoringContractException(
                "Evaluation formula version must be positive.");
        }

        var dimensions = NormalizeDimensionWeights(formula.DimensionWeights);
        var sources = NormalizeSourceWeights(formula.SourceWeights);
        var normalized = formula with
        {
            FormulaId = formulaId,
            DimensionWeights = dimensions,
            SourceWeights = sources,
            FormulaSha256 = string.Empty,
        };
        var expectedHash = ComputeSha256(normalized);
        if (!string.IsNullOrEmpty(formula.FormulaSha256) &&
            !string.Equals(formula.FormulaSha256, expectedHash, StringComparison.Ordinal))
        {
            throw new EvaluationScoringContractException(
                "Evaluation formula SHA-256 does not match its normalized definition.");
        }

        return normalized with { FormulaSha256 = expectedHash };
    }

    private static IReadOnlyList<EvaluationDimensionWeight> NormalizeDimensionWeights(
        IReadOnlyList<EvaluationDimensionWeight> weights)
    {
        ArgumentNullException.ThrowIfNull(weights);
        var normalized = weights
            .OrderBy(item => item.Dimension)
            .ToArray();
        if (normalized.Length != ExpectedDimensions.Length ||
            normalized.Select(item => item.Dimension).Distinct().Count() != normalized.Length ||
            !normalized.Select(item => item.Dimension).SequenceEqual(ExpectedDimensions))
        {
            throw new EvaluationScoringContractException(
                "Evaluation formula must define each of the six dimensions exactly once.");
        }

        ValidateWeightTotal(
            normalized.Select(item => item.WeightBasisPoints),
            "dimension");
        return Array.AsReadOnly(normalized);
    }

    private static IReadOnlyList<EvaluationSourceWeight> NormalizeSourceWeights(
        IReadOnlyList<EvaluationSourceWeight> weights)
    {
        ArgumentNullException.ThrowIfNull(weights);
        var normalized = weights
            .OrderBy(item => item.Source)
            .ToArray();
        if (normalized.Length != ExpectedSources.Length ||
            normalized.Select(item => item.Source).Distinct().Count() != normalized.Length ||
            !normalized.Select(item => item.Source).SequenceEqual(ExpectedSources))
        {
            throw new EvaluationScoringContractException(
                "Evaluation formula must define Leader, Project Manager, and objective evidence weights exactly once.");
        }

        ValidateWeightTotal(
            normalized.Select(item => item.WeightBasisPoints),
            "source");
        return Array.AsReadOnly(normalized);
    }

    private static void ValidateWeightTotal(IEnumerable<int> weights, string name)
    {
        var values = weights.ToArray();
        if (values.Any(value => value <= 0 || value > 10_000) ||
            values.Sum() != 10_000)
        {
            throw new EvaluationScoringContractException(
                $"Evaluation {name} weights must be positive and total 10,000 basis points.");
        }
    }

    private static string ComputeSha256(EvaluationFormulaDefinition formula)
    {
        using var writer = new CanonicalHashWriter("HerdrOps.EvaluationFormula.v1");
        writer.Write(formula.ContractVersion);
        writer.Write(formula.FormulaId);
        writer.Write(formula.FormulaVersion);
        writer.Write(formula.DimensionWeights.Count);
        foreach (var item in formula.DimensionWeights)
        {
            writer.Write((int)item.Dimension);
            writer.Write(item.WeightBasisPoints);
        }

        writer.Write(formula.SourceWeights.Count);
        foreach (var item in formula.SourceWeights)
        {
            writer.Write((int)item.Source);
            writer.Write(item.WeightBasisPoints);
        }

        return writer.Finish();
    }

    internal static string NormalizeRequired(string value, string name)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            throw new EvaluationScoringContractException(
                $"{name} is required.");
        }

        return value.Trim();
    }
}

public sealed class EvaluationScoringEngine
{
    public EvaluationScoreResult Calculate(
        EvaluationInputSnapshot input,
        EvaluationFormulaDefinition formula)
    {
        var normalizedFormula = EvaluationFormulaContract.NormalizeAndValidate(formula);
        var normalized = NormalizeInput(input);
        var normalizedInput = normalized.Input;
        var inputHash = ComputeInputSha256(normalizedInput);
        var sourceWeights = normalizedFormula.SourceWeights.ToDictionary(
            item => item.Source,
            item => item.WeightBasisPoints);
        var groupedInputs = normalizedInput.Dimensions
            .GroupBy(item => item.Dimension)
            .ToDictionary(group => group.Key, group => group.ToArray());
        var scores = normalizedFormula.DimensionWeights
            .Select(weight => EvaluateDimension(
                weight,
                groupedInputs.GetValueOrDefault(weight.Dimension) ?? [],
                sourceWeights))
            .ToArray();
        var status = normalized.Issues.Count > 0 ||
            scores.Any(item => item.Status == EvaluationDimensionScoreStatus.Invalid)
            ? EvaluationResultStatus.Invalid
            : scores.Any(item => item.Status == EvaluationDimensionScoreStatus.Missing)
                ? EvaluationResultStatus.Incomplete
                : EvaluationResultStatus.Complete;
        decimal? totalScore = status == EvaluationResultStatus.Complete
            ? decimal.Round(
                scores.Sum(item => item.WeightedScore!.Value),
                2,
                MidpointRounding.AwayFromZero)
            : null;
        var provenance = new EvaluationProvenanceRecord(
            normalizedFormula,
            normalizedInput,
            normalizedFormula.FormulaSha256,
            inputHash);
        var candidate = new EvaluationScoreResult(
            EvaluationFormulaCatalog.ContractVersion,
            normalizedInput.EvaluationId,
            normalizedInput.TaskId,
            normalizedInput.AgentId,
            status,
            totalScore,
            scores
                .Where(item => item.Status == EvaluationDimensionScoreStatus.Complete)
                .Sum(item => item.WeightBasisPoints),
            normalized.Issues,
            Array.AsReadOnly(scores),
            provenance,
            string.Empty);
        return candidate with { ResultSha256 = ComputeResultSha256(candidate) };
    }

    public EvaluationScoreResult Recalculate(EvaluationScoreResult historical)
    {
        ArgumentNullException.ThrowIfNull(historical);
        ArgumentNullException.ThrowIfNull(historical.Provenance);
        if (!string.Equals(
                historical.ResultSha256,
                ComputeResultSha256(historical),
                StringComparison.Ordinal))
        {
            throw new EvaluationScoringContractException(
                "Historical evaluation result SHA-256 does not match its recorded values.");
        }

        var reproduced = Calculate(
            historical.Provenance.InputSnapshot,
            historical.Provenance.Formula);
        if (!string.Equals(
                historical.Provenance.FormulaSha256,
                reproduced.Provenance.FormulaSha256,
                StringComparison.Ordinal))
        {
            throw new EvaluationScoringContractException(
                "Historical evaluation formula provenance does not match its retained formula.");
        }

        if (!string.Equals(
                historical.Provenance.InputSnapshotSha256,
                reproduced.Provenance.InputSnapshotSha256,
                StringComparison.Ordinal))
        {
            throw new EvaluationScoringContractException(
                "Historical evaluation input provenance does not match its retained snapshot.");
        }

        if (!string.Equals(
                historical.ResultSha256,
                reproduced.ResultSha256,
                StringComparison.Ordinal))
        {
            throw new EvaluationScoringContractException(
                "Historical evaluation result cannot be reproduced from its retained provenance.");
        }

        return reproduced;
    }

    private static NormalizedEvaluationInput NormalizeInput(EvaluationInputSnapshot input)
    {
        ArgumentNullException.ThrowIfNull(input);
        if (input.ContractVersion != EvaluationFormulaCatalog.ContractVersion)
        {
            throw new EvaluationScoringContractException(
                $"Unsupported evaluation input contract v{input.ContractVersion}.");
        }

        var issues = new List<EvaluationInputIssue>();
        var rawDimensions = input.Dimensions;
        if (rawDimensions is null)
        {
            issues.Add(new(
                null,
                null,
                "invalid-null-dimensions-collection",
                "The evaluation input has no dimension collection."));
            rawDimensions = [];
        }

        var normalizedDimensions = new List<EvaluationDimensionInput>(rawDimensions.Count);
        for (var index = 0; index < rawDimensions.Count; index++)
        {
            var item = rawDimensions[index];
            if (item is null)
            {
                issues.Add(new(
                    null,
                    null,
                    "invalid-null-dimension-record",
                    $"Dimension input index {index} is null."));
                continue;
            }

            if (!Enum.IsDefined(item.Dimension))
            {
                issues.Add(new(
                    null,
                    null,
                    "invalid-unknown-dimension",
                    $"Dimension input index {index} contains unknown value {(int)item.Dimension}."));
                continue;
            }

            normalizedDimensions.Add(item with
            {
                Leader = NormalizeScoreInput(
                    item.Leader,
                    item.Dimension,
                    EvaluationScoreSource.Leader,
                    issues),
                ProjectManager = NormalizeScoreInput(
                    item.ProjectManager,
                    item.Dimension,
                    EvaluationScoreSource.ProjectManager,
                    issues),
                ObjectiveEvidence = NormalizeScoreInput(
                    item.ObjectiveEvidence,
                    item.Dimension,
                    EvaluationScoreSource.ObjectiveEvidence,
                    issues),
            });
        }

        var dimensions = normalizedDimensions
            .OrderBy(item => item.Dimension)
            .ThenBy(item => item.Leader.Score)
            .ThenBy(item => item.Leader.ProvenanceId, StringComparer.Ordinal)
            .ThenBy(item => item.Leader.EvidenceIdentitySha256, StringComparer.Ordinal)
            .ThenBy(item => item.ProjectManager.Score)
            .ThenBy(item => item.ProjectManager.ProvenanceId, StringComparer.Ordinal)
            .ThenBy(item => item.ProjectManager.EvidenceIdentitySha256, StringComparer.Ordinal)
            .ThenBy(item => item.ObjectiveEvidence.Score)
            .ThenBy(item => item.ObjectiveEvidence.ProvenanceId, StringComparer.Ordinal)
            .ThenBy(item => item.ObjectiveEvidence.EvidenceIdentitySha256, StringComparer.Ordinal)
            .ToArray();
        var normalizedInput = input with
        {
            EvaluationId = NormalizeInputIdentifier(
                input.EvaluationId,
                nameof(input.EvaluationId),
                issues),
            TaskId = NormalizeInputIdentifier(
                input.TaskId,
                nameof(input.TaskId),
                issues),
            AgentId = NormalizeInputIdentifier(
                input.AgentId,
                nameof(input.AgentId),
                issues),
            Dimensions = Array.AsReadOnly(dimensions),
        };
        AddDuplicateIdentityIssues(normalizedInput.Dimensions, issues);
        return new(
            normalizedInput,
            Array.AsReadOnly(issues.ToArray()));
    }

    private static string NormalizeInputIdentifier(
        string? value,
        string name,
        ICollection<EvaluationInputIssue> issues)
    {
        if (!string.IsNullOrWhiteSpace(value))
        {
            return value.Trim();
        }

        issues.Add(new(
            null,
            null,
            "invalid-missing-input-identity",
            $"{name} is required."));
        return string.Empty;
    }

    private static EvaluationScoreInput NormalizeScoreInput(
        EvaluationScoreInput? input,
        EvaluationDimension dimension,
        EvaluationScoreSource source,
        ICollection<EvaluationInputIssue> issues)
    {
        if (input is null)
        {
            issues.Add(new(
                dimension,
                source,
                "invalid-null-source-record",
                $"{source} has a null score input record."));
            return MissingScoreInput();
        }

        return input with
        {
            ProvenanceId = string.IsNullOrWhiteSpace(input.ProvenanceId)
                ? null
                : input.ProvenanceId.Trim(),
            EvidenceIdentitySha256 = string.IsNullOrWhiteSpace(input.EvidenceIdentitySha256)
                ? null
                : input.EvidenceIdentitySha256.Trim().ToUpperInvariant(),
        };
    }

    private static void AddDuplicateIdentityIssues(
        IReadOnlyList<EvaluationDimensionInput> dimensions,
        ICollection<EvaluationInputIssue> issues)
    {
        var provenanceIds = new HashSet<string>(StringComparer.Ordinal);
        var evidenceIdentities = new HashSet<string>(StringComparer.Ordinal);
        foreach (var dimension in dimensions)
        {
            foreach (var (source, input) in new[]
            {
                (EvaluationScoreSource.Leader, dimension.Leader),
                (EvaluationScoreSource.ProjectManager, dimension.ProjectManager),
                (EvaluationScoreSource.ObjectiveEvidence, dimension.ObjectiveEvidence),
            })
            {
                if (input.ProvenanceId is not null && !provenanceIds.Add(input.ProvenanceId))
                {
                    issues.Add(new(
                        dimension.Dimension,
                        source,
                        "invalid-duplicate-provenance-id",
                        $"{source} reuses a provenance identity from another source slot."));
                }

                if (input.EvidenceIdentitySha256 is not null &&
                    !evidenceIdentities.Add(input.EvidenceIdentitySha256))
                {
                    issues.Add(new(
                        dimension.Dimension,
                        source,
                        "invalid-duplicate-evidence-identity-sha256",
                        $"{source} reuses an evidence identity from another source slot."));
                }
            }
        }
    }

    private static EvaluationDimensionScore EvaluateDimension(
        EvaluationDimensionWeight weight,
        IReadOnlyList<EvaluationDimensionInput> inputs,
        IReadOnlyDictionary<EvaluationScoreSource, int> sourceWeights)
    {
        if (inputs.Count == 0)
        {
            var missing = MissingScoreInput();
            return new EvaluationDimensionScore(
                weight.Dimension,
                weight.WeightBasisPoints,
                EvaluationDimensionScoreStatus.Missing,
                [],
                missing,
                missing,
                missing,
                null,
                null,
                [new(weight.Dimension, null, "missing-dimension", "The dimension has no input record.")]);
        }

        if (inputs.Count != 1)
        {
            var duplicate = inputs[0];
            return new EvaluationDimensionScore(
                weight.Dimension,
                weight.WeightBasisPoints,
                EvaluationDimensionScoreStatus.Invalid,
                Array.AsReadOnly(inputs.ToArray()),
                duplicate.Leader,
                duplicate.ProjectManager,
                duplicate.ObjectiveEvidence,
                null,
                null,
                [new(weight.Dimension, null, "duplicate-dimension", "The dimension has more than one input record.")]);
        }

        var input = inputs[0];
        var issues = new List<EvaluationInputIssue>();
        ValidateScore(weight.Dimension, EvaluationScoreSource.Leader, input.Leader, issues);
        ValidateScore(
            weight.Dimension,
            EvaluationScoreSource.ProjectManager,
            input.ProjectManager,
            issues);
        ValidateScore(
            weight.Dimension,
            EvaluationScoreSource.ObjectiveEvidence,
            input.ObjectiveEvidence,
            issues);
        var status = issues.Any(issue => issue.Code.StartsWith("invalid-", StringComparison.Ordinal))
            ? EvaluationDimensionScoreStatus.Invalid
            : issues.Count > 0
                ? EvaluationDimensionScoreStatus.Missing
                : EvaluationDimensionScoreStatus.Complete;
        if (status != EvaluationDimensionScoreStatus.Complete)
        {
            return new EvaluationDimensionScore(
                weight.Dimension,
                weight.WeightBasisPoints,
                status,
                Array.AsReadOnly(inputs.ToArray()),
                input.Leader,
                input.ProjectManager,
                input.ObjectiveEvidence,
                null,
                null,
                Array.AsReadOnly(issues.ToArray()));
        }

        var dimensionScore = decimal.Round(
            ((input.Leader.Score!.Value * sourceWeights[EvaluationScoreSource.Leader]) +
             (input.ProjectManager.Score!.Value * sourceWeights[EvaluationScoreSource.ProjectManager]) +
             (input.ObjectiveEvidence.Score!.Value * sourceWeights[EvaluationScoreSource.ObjectiveEvidence])) /
            10_000m,
            4,
            MidpointRounding.AwayFromZero);
        var weightedScore = decimal.Round(
            dimensionScore * weight.WeightBasisPoints / 10_000m,
            4,
            MidpointRounding.AwayFromZero);
        return new EvaluationDimensionScore(
            weight.Dimension,
            weight.WeightBasisPoints,
            status,
            Array.AsReadOnly(inputs.ToArray()),
            input.Leader,
            input.ProjectManager,
            input.ObjectiveEvidence,
            dimensionScore,
            weightedScore,
            []);
    }

    private static void ValidateScore(
        EvaluationDimension dimension,
        EvaluationScoreSource source,
        EvaluationScoreInput input,
        ICollection<EvaluationInputIssue> issues)
    {
        if (input.Score is null)
        {
            issues.Add(new(
                dimension,
                source,
                "missing-score",
                $"{source} has no score."));
            if (input.ProvenanceId is not null || input.EvidenceIdentitySha256 is not null)
            {
                issues.Add(new(
                    dimension,
                    source,
                    "invalid-orphan-provenance",
                    $"{source} supplied provenance without a score."));
            }

            return;
        }

        if (input.Score is < 0 or > 100)
        {
            issues.Add(new(
                dimension,
                source,
                "invalid-score-range",
                $"{source} score must be from 0 through 100."));
        }

        if (input.ProvenanceId is null)
        {
            issues.Add(new(
                dimension,
                source,
                "invalid-missing-provenance-id",
                $"{source} score has no provenance identity."));
        }

        if (!IsSha256(input.EvidenceIdentitySha256))
        {
            issues.Add(new(
                dimension,
                source,
                "invalid-evidence-identity-sha256",
                $"{source} score has no valid evidence identity SHA-256."));
        }
    }

    private static EvaluationScoreInput MissingScoreInput() => new(null, null, null);

    private static bool IsSha256(string? value) =>
        value is { Length: 64 } && value.All(Uri.IsHexDigit);

    private static string ComputeInputSha256(EvaluationInputSnapshot input)
    {
        using var writer = new CanonicalHashWriter("HerdrOps.EvaluationInputSnapshot.v1");
        writer.Write(input.ContractVersion);
        writer.Write(input.EvaluationId);
        writer.Write(input.TaskId);
        writer.Write(input.AgentId);
        writer.Write(input.Dimensions.Count);
        foreach (var dimension in input.Dimensions)
        {
            writer.Write((int)dimension.Dimension);
            WriteScoreInput(writer, dimension.Leader);
            WriteScoreInput(writer, dimension.ProjectManager);
            WriteScoreInput(writer, dimension.ObjectiveEvidence);
        }

        return writer.Finish();
    }

    private static string ComputeResultSha256(EvaluationScoreResult result)
    {
        using var writer = new CanonicalHashWriter("HerdrOps.EvaluationScoreResult.v1");
        writer.Write(result.ContractVersion);
        writer.Write(result.EvaluationId);
        writer.Write(result.TaskId);
        writer.Write(result.AgentId);
        writer.Write((int)result.Status);
        writer.Write(result.TotalScore?.ToString(CultureInfo.InvariantCulture));
        writer.Write(result.AvailableWeightBasisPoints);
        writer.Write(result.Provenance.FormulaSha256);
        writer.Write(result.Provenance.InputSnapshotSha256);
        writer.Write(result.InputIssues.Count);
        foreach (var issue in result.InputIssues)
        {
            WriteIssue(writer, issue);
        }

        writer.Write(result.Dimensions.Count);
        foreach (var dimension in result.Dimensions)
        {
            writer.Write((int)dimension.Dimension);
            writer.Write(dimension.WeightBasisPoints);
            writer.Write((int)dimension.Status);
            writer.Write(dimension.DimensionScore?.ToString(CultureInfo.InvariantCulture));
            writer.Write(dimension.WeightedScore?.ToString(CultureInfo.InvariantCulture));
            WriteScoreInput(writer, dimension.Leader);
            WriteScoreInput(writer, dimension.ProjectManager);
            WriteScoreInput(writer, dimension.ObjectiveEvidence);
            writer.Write(dimension.ObservedInputs.Count);
            foreach (var observed in dimension.ObservedInputs)
            {
                writer.Write((int)observed.Dimension);
                WriteScoreInput(writer, observed.Leader);
                WriteScoreInput(writer, observed.ProjectManager);
                WriteScoreInput(writer, observed.ObjectiveEvidence);
            }

            writer.Write(dimension.Issues.Count);
            foreach (var issue in dimension.Issues)
            {
                WriteIssue(writer, issue);
            }
        }

        return writer.Finish();
    }

    private static void WriteScoreInput(
        CanonicalHashWriter writer,
        EvaluationScoreInput input)
    {
        writer.Write(input.Score);
        writer.Write(input.ProvenanceId);
        writer.Write(input.EvidenceIdentitySha256);
    }

    private static void WriteIssue(
        CanonicalHashWriter writer,
        EvaluationInputIssue issue)
    {
        writer.Write(issue.Dimension is null ? null : (int)issue.Dimension.Value);
        writer.Write(issue.Source is null ? null : (int)issue.Source.Value);
        writer.Write(issue.Code);
        writer.Write(issue.Message);
    }

    private sealed record NormalizedEvaluationInput(
        EvaluationInputSnapshot Input,
        IReadOnlyList<EvaluationInputIssue> Issues);
}
