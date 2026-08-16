using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using HerdrOps.Domain.Evaluation;
using HerdrOps.Domain.Summaries;

namespace HerdrOps.Domain.Exports;

public enum SnapshotExportKind
{
    EvaluationScoreResult = 1,
    DailySummary = 2,
}

public sealed record SnapshotExportRedactionPolicy(
    string PolicyId,
    string Mode,
    IReadOnlyList<string> ProhibitedContentKinds,
    string Action);

public sealed record SnapshotExportMetadata(
    int ExportContractVersion,
    string ExporterId,
    string ExportKind,
    string GeneratedUtc,
    string Encoding,
    string ExportId,
    string SourceSnapshotSha256,
    SnapshotExportRedactionPolicy RedactionPolicy);

public sealed record EvaluationExportSourceIdentity(
    string Dimension,
    string Source,
    string? ProvenanceId,
    string? EvidenceIdentitySha256);

public sealed record EvaluationExportSource(
    int ContractVersion,
    string FormulaId,
    int FormulaVersion,
    string FormulaSha256,
    string InputSnapshotSha256,
    string ResultSha256,
    IReadOnlyList<EvaluationExportSourceIdentity> SourceIdentities);

public sealed record EvaluationScoreInputExport(
    int? Score,
    string? ProvenanceId,
    string? EvidenceIdentitySha256);

public sealed record EvaluationDimensionInputExport(
    EvaluationDimension Dimension,
    EvaluationScoreInputExport Leader,
    EvaluationScoreInputExport ProjectManager,
    EvaluationScoreInputExport ObjectiveEvidence);

public sealed record EvaluationInputSnapshotExport(
    int ContractVersion,
    string EvaluationId,
    string TaskId,
    string AgentId,
    IReadOnlyList<EvaluationDimensionInputExport> Dimensions);

public sealed record EvaluationInputIssueExport(
    EvaluationDimension? Dimension,
    EvaluationScoreSource? Source,
    string Code,
    string Message);

public sealed record EvaluationDimensionScoreExport(
    EvaluationDimension Dimension,
    int WeightBasisPoints,
    EvaluationDimensionScoreStatus Status,
    IReadOnlyList<EvaluationDimensionInputExport> ObservedInputs,
    EvaluationScoreInputExport Leader,
    EvaluationScoreInputExport ProjectManager,
    EvaluationScoreInputExport ObjectiveEvidence,
    decimal? DimensionScore,
    decimal? WeightedScore,
    IReadOnlyList<EvaluationInputIssueExport> Issues);

public sealed record EvaluationFormulaExport(
    int ContractVersion,
    string FormulaId,
    int FormulaVersion,
    IReadOnlyList<EvaluationDimensionWeight> DimensionWeights,
    IReadOnlyList<EvaluationSourceWeight> SourceWeights,
    string FormulaSha256);

public sealed record EvaluationProvenanceExport(
    EvaluationFormulaExport Formula,
    EvaluationInputSnapshotExport InputSnapshot,
    string FormulaSha256,
    string InputSnapshotSha256);

public sealed record EvaluationScoreResultExport(
    int ContractVersion,
    string EvaluationId,
    string TaskId,
    string AgentId,
    EvaluationResultStatus Status,
    decimal? TotalScore,
    int AvailableWeightBasisPoints,
    IReadOnlyList<EvaluationInputIssueExport> InputIssues,
    IReadOnlyList<EvaluationDimensionScoreExport> Dimensions,
    EvaluationProvenanceExport Provenance,
    string ResultSha256);

public sealed record EvaluationSnapshotExportDocument(
    SnapshotExportMetadata Metadata,
    EvaluationExportSource Source,
    EvaluationScoreResultExport AcceptedSnapshot);

public sealed record DailySummaryExportSourceIdentity(
    string SourceId,
    DailySummarySourceKind Kind,
    string SourceHashSha256);

public sealed record DailySummaryExportSource(
    int ContractVersion,
    string AggregatorId,
    string LocalDate,
    string TimeZoneId,
    string LocalDayStart,
    string LocalDayEndExclusive,
    string UtcDayStart,
    string UtcDayEndExclusive,
    string SourceSetSha256,
    string ResultSha256,
    IReadOnlyList<DailySummaryExportSourceIdentity> SourceIdentities);

public sealed record DailySummarySourceReferenceExport(
    string SourceId,
    DailySummarySourceKind Kind,
    string SourceHashSha256);

public sealed record DailySummaryMetricExport(
    string MetricId,
    int Value,
    IReadOnlyList<string> SourceIds);

public sealed record DailySummaryWorkstreamExport(
    string Workstream,
    int AcceptedSourceCount,
    int ActivityCount,
    int EvidenceCount,
    IReadOnlyList<string> SourceIds);

public sealed record DailySummaryTimelineEntryExport(
    string SourceId,
    DailySummarySourceKind Kind,
    string OccurredLocal,
    string Workstream,
    string Category,
    string Summary,
    string SourceHashSha256);

public sealed record DailySummaryHighlightExport(
    string SourceId,
    string Workstream,
    string Summary,
    IReadOnlyList<string> SourceIds);

public sealed record DailySummaryRepeatedIssueExport(
    string IssueKey,
    int OccurrenceCount,
    string Workstream,
    string Description,
    IReadOnlyList<string> SourceIds);

public sealed record DailySummaryRecommendedActionExport(
    string ActionKey,
    string Description,
    IReadOnlyList<string> SourceIds);

public sealed record DailySummarySnapshotExport(
    int ContractVersion,
    string AggregatorId,
    string LocalDate,
    string TimeZoneId,
    string SourceSetSha256,
    IReadOnlyList<DailySummarySourceReferenceExport> AcceptedSources,
    IReadOnlyList<DailySummaryMetricExport> Metrics,
    IReadOnlyList<DailySummaryWorkstreamExport> Workstreams,
    IReadOnlyList<DailySummaryHighlightExport> Highlights,
    IReadOnlyList<DailySummaryRepeatedIssueExport> RepeatedIssues,
    IReadOnlyList<DailySummaryRecommendedActionExport> RecommendedActions,
    IReadOnlyList<DailySummaryTimelineEntryExport> Timeline,
    string ResultSha256);

public sealed record DailySummarySnapshotExportDocument(
    SnapshotExportMetadata Metadata,
    DailySummaryExportSource Source,
    DailySummarySnapshotExport AcceptedSnapshot);

public sealed record SnapshotExportManifest(
    int ContractVersion,
    SnapshotExportKind Kind,
    string ExportId,
    string SourceSnapshotSha256,
    string JsonSha256,
    string MarkdownSha256,
    string CsvSha256,
    long JsonByteLength,
    long MarkdownByteLength,
    long CsvByteLength,
    long TotalByteLength);

public sealed record DeterministicSnapshotExport(
    SnapshotExportKind Kind,
    string Json,
    string Csv,
    string JsonSha256,
    string CsvSha256,
    string Encoding,
    string Markdown,
    string MarkdownSha256,
    string ExportId,
    string SourceSnapshotSha256,
    SnapshotExportManifest Manifest);

public sealed class SnapshotExportException : InvalidOperationException
{
    public SnapshotExportException(string message)
        : base(message)
    {
    }

    public SnapshotExportException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}

public static class DeterministicSnapshotExporter
{
    public const int ExportContractVersion = 1;
    public const string ExporterId = "HERDROPS-LOCAL-SNAPSHOT-EXPORT-V1";
    public const string RedactionPolicyId = "HERDROPS-LOCAL-EXPORT-REDACTION-V1";

    public const int MaximumTotalOutputBytes = 4 * 1024 * 1024;
    public const int MaximumCollectionItems = 10_000;
    public const int MaximumReferenceItems = 512;
    public const int MaximumTotalReferenceItems = 20_000;
    public const int MaximumIdentifierLength = 256;
    public const int MaximumTextLength = 8_192;
    public const int MaximumTextBytes = 8_192;
    public const int MaximumObjectProperties = 128;
    public const int MaximumSerializedNodes = 100_000;

    private static readonly JsonSerializerOptions JsonOptions = CreateJsonOptions();
    private static readonly UTF8Encoding StrictUtf8 = new(
        encoderShouldEmitUTF8Identifier: false,
        throwOnInvalidBytes: true);
    private static readonly Regex FileSystemPathPattern = new(
        @"(?<![A-Za-z0-9_])(?:[A-Za-z]:[\\/]|\\\\[^\s\\/]+[\\/]|/(?!/)(?:[^\s/]+/)+[^\s/]+|~[\\/])",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);
    private static readonly Regex PathCandidatePattern = new(
        @"(?<![A-Za-z0-9_])(?<candidate>[^\s,;()\[\]{}<>]*[\\/][^\s,;()\[\]{}<>]*)(?![A-Za-z0-9_])",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);
    private static readonly Regex DriveRelativePathPattern = new(
        @"(?<![A-Za-z0-9_])[A-Za-z]:[^\\/\s,;()\[\]{}<>]+",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);
    private static readonly Regex RelativeFilePathPattern = new(
        @"(?<![A-Za-z0-9_])[A-Za-z0-9_-]+\.(?:txt|json|csv|log|xml|ya?ml|cs|fs|vb|ps1|dll|exe|zip|db|sqlite|md|png|jpe?g|config|env)(?![A-Za-z0-9_])",
        RegexOptions.Compiled | RegexOptions.CultureInvariant | RegexOptions.IgnoreCase);
    private static readonly Regex SecretOrTokenPattern = new(
        @"(?:\b(?:api[_-]?key|client[_-]?secret|access[_-]?token|refresh[_-]?token|id[_-]?token|password|passwd|secret|credential|authorization|bearer|jwt|token)\b\s*(?:[:=]|$)|\bBearer\s+[A-Za-z0-9._~+/=-]{12,}|\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b|(?<![A-Za-z0-9])(?:token|jwt)[A-Za-z0-9_-]{12,}(?![A-Za-z0-9])|(?<![A-Za-z0-9])(?:gh[pousr]_[A-Za-z0-9]{8,}|github_pat_[A-Za-z0-9_]{8,}|sk-[A-Za-z0-9_-]{8,}|xox[baprs]-[A-Za-z0-9-]{12,}|(?:AKIA|ASIA)[A-Z0-9]{16}|AIza[A-Za-z0-9_-]{20,}|(?:glpat-|npm_|pypi-|hf_|dop_v1_)[A-Za-z0-9_-]{12,})(?![A-Za-z0-9_-]))",
        RegexOptions.Compiled | RegexOptions.CultureInvariant | RegexOptions.IgnoreCase);
    private static readonly Regex SensitivePropertyPattern = new(
        @"(?:secret|password|passwd|credential|authorization|bearer|jwt|token|api[_-]?key)",
        RegexOptions.Compiled | RegexOptions.CultureInvariant | RegexOptions.IgnoreCase);

    public static DeterministicSnapshotExport ExportEvaluation(
        EvaluationScoreResult acceptedSnapshot,
        DateTimeOffset generatedUtc)
    {
        var normalizedGeneratedUtc = NormalizeGeneratedUtc(generatedUtc);
        var accepted = ValidateEvaluation(acceptedSnapshot);
        var sourceSnapshotSha256 = RequireSha256(
            accepted.Provenance.InputSnapshotSha256,
            "Evaluation input snapshot SHA-256");
        var exportId = CreateExportId(
            SnapshotExportKind.EvaluationScoreResult,
            sourceSnapshotSha256,
            normalizedGeneratedUtc);
        var metadata = CreateMetadata(
            "evaluation-score-result",
            normalizedGeneratedUtc,
            exportId,
            sourceSnapshotSha256);
        var source = new EvaluationExportSource(
            accepted.ContractVersion,
            accepted.Provenance.Formula.FormulaId,
            accepted.Provenance.Formula.FormulaVersion,
            accepted.Provenance.FormulaSha256,
            accepted.Provenance.InputSnapshotSha256,
            accepted.ResultSha256,
            BuildEvaluationSourceIdentities(accepted.Provenance.InputSnapshot));
        var document = new EvaluationSnapshotExportDocument(
            metadata,
            source,
            MapEvaluation(accepted));

        return CreateExport(
            SnapshotExportKind.EvaluationScoreResult,
            document,
            exportId,
            sourceSnapshotSha256);
    }

    public static DeterministicSnapshotExport ExportDailySummary(
        DailySummarySnapshot acceptedSnapshot,
        TimeZoneInfo timeZone,
        DateTimeOffset generatedUtc)
    {
        ArgumentNullException.ThrowIfNull(timeZone);
        var normalizedGeneratedUtc = NormalizeGeneratedUtc(generatedUtc);
        DailySummarySnapshot accepted;
        try
        {
            accepted = DailySummaryAggregator.Validate(acceptedSnapshot);
        }
        catch (DailySummaryAggregationException exception)
        {
            throw new SnapshotExportException(
                "The Daily Summary snapshot is not an accepted deterministic result.",
                exception);
        }

        if (!string.Equals(accepted.TimeZoneId, timeZone.Id, StringComparison.Ordinal))
        {
            throw new SnapshotExportException(
                "The supplied Daily Summary time zone does not match the accepted snapshot.");
        }

        ValidateDailySummaryForExport(accepted);
        var sourceSnapshotSha256 = RequireSha256(
            accepted.SourceSetSha256,
            "Daily Summary source-set SHA-256");
        var exportId = CreateExportId(
            SnapshotExportKind.DailySummary,
            sourceSnapshotSha256,
            normalizedGeneratedUtc);

        var boundaries = BindAcceptedDayBoundaries(accepted, timeZone);
        var metadata = CreateMetadata(
            "daily-summary",
            normalizedGeneratedUtc,
            exportId,
            sourceSnapshotSha256);
        var source = new DailySummaryExportSource(
            accepted.ContractVersion,
            accepted.AggregatorId,
            FormatLocalDate(accepted.LocalDate),
            accepted.TimeZoneId,
            FormatLocalBoundary(boundaries.LocalStart),
            FormatLocalBoundary(boundaries.LocalEndExclusive),
            FormatUtc(boundaries.UtcStart),
            FormatUtc(boundaries.UtcEndExclusive),
            accepted.SourceSetSha256,
            accepted.ResultSha256,
            accepted.AcceptedSources
                .Select(item => new DailySummaryExportSourceIdentity(
                    item.SourceId,
                    item.Kind,
                    item.SourceHashSha256))
                .ToArray());
        var document = new DailySummarySnapshotExportDocument(
            metadata,
            source,
            MapDailySummary(accepted));

        return CreateExport(
            SnapshotExportKind.DailySummary,
            document,
            exportId,
            sourceSnapshotSha256);
    }

    private static EvaluationScoreResult ValidateEvaluation(
        EvaluationScoreResult snapshot)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        try
        {
            EnsureEvaluationShape(snapshot);
            var reproduced = new EvaluationScoringEngine().Recalculate(snapshot);
            if (!Enum.IsDefined(snapshot.Status) ||
                snapshot.Status == EvaluationResultStatus.Invalid)
            {
                throw new SnapshotExportException(
                    "The Evaluation Score Result has an invalid or unsupported status.");
            }

            if (snapshot.Status == EvaluationResultStatus.Complete)
            {
                if (snapshot.TotalScore is null ||
                    snapshot.InputIssues.Count != 0 ||
                    snapshot.Dimensions.Any(item =>
                        item.Status != EvaluationDimensionScoreStatus.Complete ||
                        item.DimensionScore is null ||
                        item.WeightedScore is null))
                {
                    throw new SnapshotExportException(
                        "The complete Evaluation Score Result has unexplained missing data.");
                }
            }
            else if (snapshot.TotalScore is not null ||
                     snapshot.InputIssues.Count != 0 ||
                     !snapshot.Dimensions.Any(item =>
                         item.Status == EvaluationDimensionScoreStatus.Missing) ||
                     snapshot.Dimensions.Any(item =>
                         item.Status == EvaluationDimensionScoreStatus.Invalid ||
                         item.Issues.Any(issue => issue.Code.StartsWith(
                             "invalid-",
                             StringComparison.Ordinal))))
            {
                throw new SnapshotExportException(
                    "The incomplete Evaluation Score Result contains invalid or unexplained data.");
            }

            if (!string.Equals(reproduced.ResultSha256, snapshot.ResultSha256, StringComparison.Ordinal))
            {
                throw new SnapshotExportException(
                    "The Evaluation Score Result could not be reproduced from its provenance.");
            }
        }
        catch (SnapshotExportException)
        {
            throw;
        }
        catch (Exception exception) when (
            exception is EvaluationScoringContractException ||
            exception is ArgumentException ||
            exception is NullReferenceException ||
            exception is InvalidOperationException)
        {
            throw new SnapshotExportException(
                "The Evaluation Score Result is not an accepted deterministic result.",
                exception);
        }

        return snapshot;
    }

    private static void EnsureEvaluationShape(EvaluationScoreResult snapshot)
    {
        EnsureText(snapshot.EvaluationId, nameof(snapshot.EvaluationId), MaximumIdentifierLength);
        EnsureText(snapshot.TaskId, nameof(snapshot.TaskId), MaximumIdentifierLength);
        EnsureText(snapshot.AgentId, nameof(snapshot.AgentId), MaximumIdentifierLength);
        if (!Enum.IsDefined(snapshot.Status))
        {
            throw new SnapshotExportException("The Evaluation Score Result status is not defined.");
        }

        ArgumentNullException.ThrowIfNull(snapshot.Provenance);
        ArgumentNullException.ThrowIfNull(snapshot.Provenance.Formula);
        ArgumentNullException.ThrowIfNull(snapshot.Provenance.Formula.DimensionWeights);
        ArgumentNullException.ThrowIfNull(snapshot.Provenance.Formula.SourceWeights);
        ArgumentNullException.ThrowIfNull(snapshot.Provenance.InputSnapshot);
        ArgumentNullException.ThrowIfNull(snapshot.Provenance.InputSnapshot.Dimensions);
        ArgumentNullException.ThrowIfNull(snapshot.InputIssues);
        ArgumentNullException.ThrowIfNull(snapshot.Dimensions);
        EnsureCollectionCount(
            snapshot.Provenance.Formula.DimensionWeights,
            "evaluation formula dimensions");
        EnsureCollectionCount(snapshot.Provenance.Formula.SourceWeights, "evaluation formula sources");
        EnsureCollectionCount(snapshot.Provenance.InputSnapshot.Dimensions, "evaluation input dimensions");
        EnsureCollectionCount(snapshot.Dimensions, "evaluation result dimensions");
        EnsureSha256(snapshot.Provenance.FormulaSha256, "evaluation formula SHA-256");
        EnsureSha256(snapshot.Provenance.InputSnapshotSha256, "evaluation input snapshot SHA-256");
        EnsureSha256(snapshot.ResultSha256, "evaluation result SHA-256");
        EnsureText(
            snapshot.Provenance.Formula.FormulaId,
            nameof(snapshot.Provenance.Formula.FormulaId),
            MaximumIdentifierLength);
        EnsureText(
            snapshot.Provenance.InputSnapshot.EvaluationId,
            nameof(snapshot.Provenance.InputSnapshot.EvaluationId),
            MaximumIdentifierLength);
        EnsureText(
            snapshot.Provenance.InputSnapshot.TaskId,
            nameof(snapshot.Provenance.InputSnapshot.TaskId),
            MaximumIdentifierLength);
        EnsureText(
            snapshot.Provenance.InputSnapshot.AgentId,
            nameof(snapshot.Provenance.InputSnapshot.AgentId),
            MaximumIdentifierLength);

        foreach (var issue in snapshot.InputIssues)
        {
            ArgumentNullException.ThrowIfNull(issue);
            EnsureIssue(issue);
        }

        foreach (var dimension in snapshot.Provenance.InputSnapshot.Dimensions)
        {
            ArgumentNullException.ThrowIfNull(dimension);
            if (!Enum.IsDefined(dimension.Dimension))
            {
                throw new SnapshotExportException("The evaluation input has an unsupported dimension.");
            }

            EnsureScoreInput(dimension.Leader);
            EnsureScoreInput(dimension.ProjectManager);
            EnsureScoreInput(dimension.ObjectiveEvidence);
        }

        foreach (var dimension in snapshot.Dimensions)
        {
            ArgumentNullException.ThrowIfNull(dimension);
            if (!Enum.IsDefined(dimension.Dimension) || !Enum.IsDefined(dimension.Status))
            {
                throw new SnapshotExportException("The evaluation result has an unsupported dimension or status.");
            }

            ArgumentNullException.ThrowIfNull(dimension.ObservedInputs);
            ArgumentNullException.ThrowIfNull(dimension.Issues);
            EnsureCollectionCount(dimension.ObservedInputs, "evaluation observed inputs");
            EnsureCollectionCount(dimension.Issues, "evaluation dimension issues");
            EnsureScoreInput(dimension.Leader);
            EnsureScoreInput(dimension.ProjectManager);
            EnsureScoreInput(dimension.ObjectiveEvidence);
            EnsureDimensionScoreBindings(dimension);
            foreach (var observed in dimension.ObservedInputs)
            {
                ArgumentNullException.ThrowIfNull(observed);
                EnsureScoreInput(observed.Leader);
                EnsureScoreInput(observed.ProjectManager);
                EnsureScoreInput(observed.ObjectiveEvidence);
            }

            foreach (var issue in dimension.Issues)
            {
                ArgumentNullException.ThrowIfNull(issue);
                EnsureIssue(issue);
            }
        }

        EnsureEvaluationIdentitySet(snapshot.Provenance.InputSnapshot.Dimensions);
    }

    private static void EnsureDimensionScoreBindings(EvaluationDimensionScore dimension)
    {
        if (dimension.ObservedInputs.Count == 0)
        {
            if (HasScoreOrIdentity(dimension.Leader) ||
                HasScoreOrIdentity(dimension.ProjectManager) ||
                HasScoreOrIdentity(dimension.ObjectiveEvidence))
            {
                throw new SnapshotExportException(
                    "The evaluation result has top-level source data without an observed input record.");
            }

            return;
        }

        if (dimension.ObservedInputs.Count != 1)
        {
            throw new SnapshotExportException(
                "The evaluation result has duplicate observed input records for a dimension.");
        }

        var observed = dimension.ObservedInputs[0];
        if (!dimension.Leader.Equals(observed.Leader) ||
            !dimension.ProjectManager.Equals(observed.ProjectManager) ||
            !dimension.ObjectiveEvidence.Equals(observed.ObjectiveEvidence))
        {
            throw new SnapshotExportException(
                "The evaluation result top-level source fields do not match its observed inputs.");
        }
    }

    private static bool HasScoreOrIdentity(EvaluationScoreInput input) =>
        input.Score is not null ||
        input.ProvenanceId is not null ||
        input.EvidenceIdentitySha256 is not null;

    private static void EnsureEvaluationIdentitySet(
        IReadOnlyList<EvaluationDimensionInput> dimensions)
    {
        var provenanceIds = new HashSet<string>(StringComparer.Ordinal);
        var evidenceIdentities = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var dimension in dimensions)
        {
            EnsureEvaluationSourceIdentity(
                dimension.Dimension,
                EvaluationScoreSource.Leader,
                dimension.Leader,
                provenanceIds,
                evidenceIdentities);
            EnsureEvaluationSourceIdentity(
                dimension.Dimension,
                EvaluationScoreSource.ProjectManager,
                dimension.ProjectManager,
                provenanceIds,
                evidenceIdentities);
            EnsureEvaluationSourceIdentity(
                dimension.Dimension,
                EvaluationScoreSource.ObjectiveEvidence,
                dimension.ObjectiveEvidence,
                provenanceIds,
                evidenceIdentities);
        }
    }

    private static void EnsureEvaluationSourceIdentity(
        EvaluationDimension dimension,
        EvaluationScoreSource source,
        EvaluationScoreInput input,
        ISet<string> provenanceIds,
        ISet<string> evidenceIdentities)
    {
        if (input.Score is null)
        {
            if (input.ProvenanceId is not null || input.EvidenceIdentitySha256 is not null)
            {
                throw new SnapshotExportException(
                    $"The evaluation {dimension}/{source} has provenance without a score.");
            }

            return;
        }

        if (string.IsNullOrWhiteSpace(input.ProvenanceId) ||
            !IsSha256(input.EvidenceIdentitySha256))
        {
            throw new SnapshotExportException(
                $"The evaluation {dimension}/{source} has missing or malformed source identities.");
        }

        if (!provenanceIds.Add(input.ProvenanceId!))
        {
            throw new SnapshotExportException(
                $"The evaluation {dimension}/{source} has a duplicate provenance identity.");
        }

        if (!evidenceIdentities.Add(input.EvidenceIdentitySha256!))
        {
            throw new SnapshotExportException(
                $"The evaluation {dimension}/{source} has a duplicate evidence identity.");
        }
    }

    private static void EnsureScoreInput(EvaluationScoreInput input)
    {
        ArgumentNullException.ThrowIfNull(input);
        if (input.ProvenanceId is not null)
        {
            EnsureText(input.ProvenanceId, nameof(input.ProvenanceId), MaximumIdentifierLength);
        }

        if (input.EvidenceIdentitySha256 is not null)
        {
            EnsureSha256(input.EvidenceIdentitySha256, nameof(input.EvidenceIdentitySha256));
        }
    }

    private static void EnsureIssue(EvaluationInputIssue issue)
    {
        if (issue.Dimension is not null && !Enum.IsDefined(issue.Dimension.Value) ||
            issue.Source is not null && !Enum.IsDefined(issue.Source.Value))
        {
            throw new SnapshotExportException("The evaluation contains an unsupported issue identity.");
        }

        EnsureText(issue.Code, nameof(issue.Code), MaximumIdentifierLength);
        EnsureText(issue.Message, nameof(issue.Message), MaximumTextLength);
    }

    private static void EnsureCollectionCount<T>(
        IReadOnlyCollection<T> collection,
        string name)
    {
        if (collection.Count > MaximumCollectionItems)
        {
            throw new SnapshotExportException(
                $"The export exceeds the maximum {name} cardinality of {MaximumCollectionItems}.");
        }
    }

    private static void EnsureText(string? value, string name, int maximumLength)
    {
        if (string.IsNullOrWhiteSpace(value) ||
            value.Length > maximumLength ||
            value.Any(char.IsControl) ||
            !string.Equals(value, value.Trim(), StringComparison.Ordinal))
        {
            throw new SnapshotExportException(
                $"The export field {name} exceeds its text bound or is not normalized.");
        }

        EnsureStrictUtf8(value!, name);
        if (StrictUtf8.GetByteCount(value!) > MaximumTextBytes)
        {
            throw new SnapshotExportException(
                $"The export field {name} exceeds its UTF-8 byte bound.");
        }
    }

    private static void EnsureStrictUtf8(string value, string path)
    {
        try
        {
            _ = StrictUtf8.GetByteCount(value);
        }
        catch (EncoderFallbackException exception)
        {
            throw new SnapshotExportException(
                $"Export rejected invalid UTF-8 text at {path}.",
                exception);
        }
    }

    private static void EnsureSha256(string? value, string name)
    {
        if (value is not { Length: 64 } || !value.All(Uri.IsHexDigit))
        {
            throw new SnapshotExportException($"The export field {name} is not a SHA-256 identity.");
        }
    }

    private static string RequireSha256(string? value, string name)
    {
        EnsureSha256(value, name);
        return value!.ToUpperInvariant();
    }

    private static EvaluationScoreResultExport MapEvaluation(EvaluationScoreResult snapshot) =>
        new(
            snapshot.ContractVersion,
            snapshot.EvaluationId,
            snapshot.TaskId,
            snapshot.AgentId,
            snapshot.Status,
            snapshot.TotalScore,
            snapshot.AvailableWeightBasisPoints,
            snapshot.InputIssues.Select(MapIssue).ToArray(),
            snapshot.Dimensions.Select(MapDimensionScore).ToArray(),
            new EvaluationProvenanceExport(
                new EvaluationFormulaExport(
                    snapshot.Provenance.Formula.ContractVersion,
                    snapshot.Provenance.Formula.FormulaId,
                    snapshot.Provenance.Formula.FormulaVersion,
                    snapshot.Provenance.Formula.DimensionWeights.ToArray(),
                    snapshot.Provenance.Formula.SourceWeights.ToArray(),
                    snapshot.Provenance.Formula.FormulaSha256),
                MapInputSnapshot(snapshot.Provenance.InputSnapshot),
                snapshot.Provenance.FormulaSha256,
                snapshot.Provenance.InputSnapshotSha256),
            snapshot.ResultSha256);

    private static EvaluationInputSnapshotExport MapInputSnapshot(
        EvaluationInputSnapshot snapshot) =>
        new(
            snapshot.ContractVersion,
            snapshot.EvaluationId,
            snapshot.TaskId,
            snapshot.AgentId,
            snapshot.Dimensions.Select(MapDimensionInput).ToArray());

    private static EvaluationDimensionInputExport MapDimensionInput(
        EvaluationDimensionInput input) =>
        new(
            input.Dimension,
            MapScoreInput(input.Leader),
            MapScoreInput(input.ProjectManager),
            MapScoreInput(input.ObjectiveEvidence));

    private static EvaluationDimensionScoreExport MapDimensionScore(
        EvaluationDimensionScore input) =>
        new(
            input.Dimension,
            input.WeightBasisPoints,
            input.Status,
            input.ObservedInputs.Select(MapDimensionInput).ToArray(),
            MapScoreInput(input.Leader),
            MapScoreInput(input.ProjectManager),
            MapScoreInput(input.ObjectiveEvidence),
            input.DimensionScore,
            input.WeightedScore,
            input.Issues.Select(MapIssue).ToArray());

    private static EvaluationInputIssueExport MapIssue(EvaluationInputIssue issue) =>
        new(issue.Dimension, issue.Source, issue.Code, issue.Message);

    private static EvaluationScoreInputExport MapScoreInput(EvaluationScoreInput input) =>
        new(input.Score, input.ProvenanceId, input.EvidenceIdentitySha256);

    private static EvaluationExportSourceIdentity[] BuildEvaluationSourceIdentities(
        EvaluationInputSnapshot snapshot) =>
        snapshot.Dimensions
            .SelectMany(item => new[]
            {
                new EvaluationExportSourceIdentity(
                    item.Dimension.ToString(),
                    EvaluationScoreSource.Leader.ToString(),
                    item.Leader.ProvenanceId,
                    item.Leader.EvidenceIdentitySha256),
                new EvaluationExportSourceIdentity(
                    item.Dimension.ToString(),
                    EvaluationScoreSource.ProjectManager.ToString(),
                    item.ProjectManager.ProvenanceId,
                    item.ProjectManager.EvidenceIdentitySha256),
                new EvaluationExportSourceIdentity(
                    item.Dimension.ToString(),
                    EvaluationScoreSource.ObjectiveEvidence.ToString(),
                    item.ObjectiveEvidence.ProvenanceId,
                    item.ObjectiveEvidence.EvidenceIdentitySha256),
            })
            .ToArray();

    private static void ValidateDailySummaryForExport(DailySummarySnapshot snapshot)
    {
        try
        {
            EnsureDailySummaryTextShape(snapshot);
            EnsureCollectionCount(snapshot.AcceptedSources, "daily accepted sources");
            EnsureCollectionCount(snapshot.Metrics, "daily metrics");
            EnsureCollectionCount(snapshot.Workstreams, "daily workstreams");
            EnsureCollectionCount(snapshot.Highlights, "daily highlights");
            EnsureCollectionCount(snapshot.RepeatedIssues, "daily repeated issues");
            EnsureCollectionCount(snapshot.RecommendedActions, "daily recommended actions");
            EnsureCollectionCount(snapshot.Timeline, "daily timeline");
            var acceptedSources = snapshot.AcceptedSources.ToArray();
            var sourceById = acceptedSources.ToDictionary(
                item => item.SourceId,
                StringComparer.Ordinal);
            EnsureReferenceIds(
                acceptedSources.Select(item => item.SourceId).ToArray(),
                "daily accepted source IDs",
                requireSorted: false);

            if (!acceptedSources.Select(item => item.SourceId)
                    .SequenceEqual(snapshot.Timeline.Select(item => item.SourceId), StringComparer.Ordinal))
            {
                throw new SnapshotExportException(
                    "Daily Summary accepted sources and timeline are not canonically reconciled.");
            }

            var timelineById = snapshot.Timeline.ToDictionary(
                item => item.SourceId,
                StringComparer.Ordinal);
            foreach (var source in acceptedSources)
            {
                if (!Enum.IsDefined(source.Kind) ||
                    !IsSha256(source.SourceHashSha256) ||
                    !timelineById.TryGetValue(source.SourceId, out var timeline) ||
                    timeline.Kind != source.Kind ||
                    !string.Equals(timeline.SourceHashSha256, source.SourceHashSha256, StringComparison.Ordinal))
                {
                    throw new SnapshotExportException(
                        "Daily Summary source references do not reconcile to the accepted source set.");
                }
            }

            var expectedWorkstreams = snapshot.Timeline
                .GroupBy(item => item.Workstream, StringComparer.Ordinal)
                .OrderBy(group => group.Key, StringComparer.Ordinal)
                .Select(group => new
                {
                    Workstream = group.Key,
                    SourceIds = group.Select(item => item.SourceId).OrderBy(item => item, StringComparer.Ordinal).ToArray(),
                    ActivityCount = group.Count(item => item.Kind == DailySummarySourceKind.ActivityEvent),
                    EvidenceCount = group.Count(item => item.Kind == DailySummarySourceKind.Evidence),
                })
                .ToArray();
            if (snapshot.Workstreams.Count != expectedWorkstreams.Length ||
                !snapshot.Workstreams.Select(item => item.Workstream)
                    .SequenceEqual(expectedWorkstreams.Select(item => item.Workstream), StringComparer.Ordinal))
            {
                throw new SnapshotExportException("Daily Summary workstream ordering or cardinality is invalid.");
            }

            for (var index = 0; index < expectedWorkstreams.Length; index++)
            {
                var actual = snapshot.Workstreams[index];
                var expected = expectedWorkstreams[index];
                EnsureReferenceIds(actual.SourceIds, "daily workstream references");
                if (actual.AcceptedSourceCount != actual.SourceIds.Count ||
                    actual.ActivityCount != expected.ActivityCount ||
                    actual.EvidenceCount != expected.EvidenceCount ||
                    !actual.SourceIds.SequenceEqual(expected.SourceIds, StringComparer.Ordinal))
                {
                    throw new SnapshotExportException(
                        "Daily Summary workstream counts do not reconcile to the timeline.");
                }
            }

            var expectedMetricValues = new (string Id, int Value, string[] SourceIds)[]
            {
                ("accepted-sources", acceptedSources.Length, acceptedSources.Select(item => item.SourceId).OrderBy(item => item, StringComparer.Ordinal).ToArray()),
                ("activity-events", snapshot.Timeline.Count(item => item.Kind == DailySummarySourceKind.ActivityEvent), snapshot.Timeline.Where(item => item.Kind == DailySummarySourceKind.ActivityEvent).Select(item => item.SourceId).OrderBy(item => item, StringComparer.Ordinal).ToArray()),
                ("evidence-items", snapshot.Timeline.Count(item => item.Kind == DailySummarySourceKind.Evidence), snapshot.Timeline.Where(item => item.Kind == DailySummarySourceKind.Evidence).Select(item => item.SourceId).OrderBy(item => item, StringComparer.Ordinal).ToArray()),
                ("workstreams", snapshot.Workstreams.Count, acceptedSources.Select(item => item.SourceId).OrderBy(item => item, StringComparer.Ordinal).ToArray()),
                ("timeline-items", snapshot.Timeline.Count, acceptedSources.Select(item => item.SourceId).OrderBy(item => item, StringComparer.Ordinal).ToArray()),
                ("highlights", snapshot.Highlights.Count, snapshot.Highlights.SelectMany(item => item.SourceIds).OrderBy(item => item, StringComparer.Ordinal).ToArray()),
                ("repeated-issues", snapshot.RepeatedIssues.Count, snapshot.RepeatedIssues.SelectMany(item => item.SourceIds).OrderBy(item => item, StringComparer.Ordinal).ToArray()),
                ("recommended-actions", snapshot.RecommendedActions.Count, snapshot.RecommendedActions.SelectMany(item => item.SourceIds).OrderBy(item => item, StringComparer.Ordinal).ToArray()),
            };
            if (snapshot.Metrics.Count != expectedMetricValues.Length ||
                !snapshot.Metrics.Select(item => item.MetricId)
                    .SequenceEqual(expectedMetricValues.Select(item => item.Id), StringComparer.Ordinal))
            {
                throw new SnapshotExportException("Daily Summary metrics are not in the canonical order.");
            }

            for (var index = 0; index < expectedMetricValues.Length; index++)
            {
                var actual = snapshot.Metrics[index];
                var expected = expectedMetricValues[index];
                EnsureReferenceIds(actual.SourceIds, "daily metric references");
                if (actual.Value != expected.Value ||
                    !actual.SourceIds.SequenceEqual(expected.SourceIds, StringComparer.Ordinal))
                {
                    throw new SnapshotExportException(
                        "Daily Summary metric values do not reconcile to accepted references.");
                }
            }

            var expectedHighlightIds = snapshot.Timeline
                .Where(item => snapshot.Highlights.Any(highlight => highlight.SourceId == item.SourceId))
                .Select(item => item.SourceId)
                .ToArray();
            if (!snapshot.Highlights.Select(item => item.SourceId)
                    .SequenceEqual(expectedHighlightIds, StringComparer.Ordinal))
            {
                throw new SnapshotExportException("Daily Summary highlight ordering is not canonical.");
            }

            foreach (var highlight in snapshot.Highlights)
            {
                EnsureReferenceIds(highlight.SourceIds, "daily highlight references");
                if (!sourceById.ContainsKey(highlight.SourceId) ||
                    highlight.SourceIds.Count != 1 ||
                    !string.Equals(highlight.SourceIds[0], highlight.SourceId, StringComparison.Ordinal))
                {
                    throw new SnapshotExportException("Daily Summary highlight references are invalid.");
                }
            }

            var expectedIssueKeys = snapshot.RepeatedIssues
                .Select(item => item.IssueKey)
                .OrderBy(item => item, StringComparer.Ordinal)
                .ToArray();
            if (!snapshot.RepeatedIssues.Select(item => item.IssueKey)
                    .SequenceEqual(expectedIssueKeys, StringComparer.Ordinal))
            {
                throw new SnapshotExportException("Daily Summary repeated-issue ordering is not canonical.");
            }

            foreach (var issue in snapshot.RepeatedIssues)
            {
                EnsureReferenceIds(issue.SourceIds, "daily repeated-issue references");
                if (issue.OccurrenceCount < 2 || issue.OccurrenceCount != issue.SourceIds.Count ||
                    issue.SourceIds.Any(item => !sourceById.ContainsKey(item)))
                {
                    throw new SnapshotExportException("Daily Summary repeated-issue references are invalid.");
                }
            }

            var expectedActionKeys = snapshot.RecommendedActions
                .Select(item => item.ActionKey)
                .OrderBy(item => item, StringComparer.Ordinal)
                .ToArray();
            if (!snapshot.RecommendedActions.Select(item => item.ActionKey)
                    .SequenceEqual(expectedActionKeys, StringComparer.Ordinal))
            {
                throw new SnapshotExportException("Daily Summary recommended-action ordering is not canonical.");
            }

            foreach (var action in snapshot.RecommendedActions)
            {
                EnsureReferenceIds(action.SourceIds, "daily recommended-action references");
                if (action.SourceIds.Any(item => !sourceById.ContainsKey(item)))
                {
                    throw new SnapshotExportException("Daily Summary recommended-action references are invalid.");
                }
            }
        }
        catch (SnapshotExportException)
        {
            throw;
        }
        catch (Exception exception) when (
            exception is ArgumentException ||
            exception is InvalidOperationException ||
            exception is KeyNotFoundException)
        {
            throw new SnapshotExportException(
                "The Daily Summary contains invalid or unreconciled accepted data.",
                exception);
        }
    }

    private static void EnsureDailySummaryTextShape(DailySummarySnapshot snapshot)
    {
        EnsureText(snapshot.AggregatorId, nameof(snapshot.AggregatorId), MaximumIdentifierLength);
        EnsureText(snapshot.TimeZoneId, nameof(snapshot.TimeZoneId), MaximumIdentifierLength);

        foreach (var source in snapshot.AcceptedSources)
        {
            EnsureText(source.SourceId, nameof(source.SourceId), MaximumIdentifierLength);
            EnsureSha256(source.SourceHashSha256, nameof(source.SourceHashSha256));
        }

        foreach (var metric in snapshot.Metrics)
        {
            EnsureText(metric.MetricId, nameof(metric.MetricId), MaximumIdentifierLength);
            EnsureReferenceIds(metric.SourceIds, "daily metric references");
        }

        foreach (var workstream in snapshot.Workstreams)
        {
            EnsureText(workstream.Workstream, nameof(workstream.Workstream), MaximumIdentifierLength);
            EnsureReferenceIds(workstream.SourceIds, "daily workstream references");
        }

        foreach (var highlight in snapshot.Highlights)
        {
            EnsureText(highlight.SourceId, nameof(highlight.SourceId), MaximumIdentifierLength);
            EnsureText(highlight.Workstream, nameof(highlight.Workstream), MaximumIdentifierLength);
            EnsureText(highlight.Summary, nameof(highlight.Summary), MaximumTextLength);
            EnsureReferenceIds(highlight.SourceIds, "daily highlight references");
        }

        foreach (var issue in snapshot.RepeatedIssues)
        {
            EnsureText(issue.IssueKey, nameof(issue.IssueKey), MaximumIdentifierLength);
            EnsureText(issue.Workstream, nameof(issue.Workstream), MaximumIdentifierLength);
            EnsureText(issue.Description, nameof(issue.Description), MaximumTextLength);
            EnsureReferenceIds(issue.SourceIds, "daily repeated-issue references");
        }

        foreach (var action in snapshot.RecommendedActions)
        {
            EnsureText(action.ActionKey, nameof(action.ActionKey), MaximumIdentifierLength);
            EnsureText(action.Description, nameof(action.Description), MaximumTextLength);
            EnsureReferenceIds(action.SourceIds, "daily recommended-action references");
        }

        foreach (var timeline in snapshot.Timeline)
        {
            EnsureText(timeline.SourceId, nameof(timeline.SourceId), MaximumIdentifierLength);
            EnsureText(timeline.Workstream, nameof(timeline.Workstream), MaximumIdentifierLength);
            EnsureText(timeline.Category, nameof(timeline.Category), MaximumIdentifierLength);
            EnsureText(timeline.Summary, nameof(timeline.Summary), MaximumTextLength);
            EnsureSha256(timeline.SourceHashSha256, nameof(timeline.SourceHashSha256));
        }
    }

    private static void EnsureReferenceIds(
        IReadOnlyList<string> ids,
        string name,
        bool requireSorted = true)
    {
        ArgumentNullException.ThrowIfNull(ids);
        if (ids.Count > MaximumReferenceItems ||
            ids.Distinct(StringComparer.Ordinal).Count() != ids.Count)
        {
            throw new SnapshotExportException(
                $"The export field {name} exceeds reference bounds or contains duplicates.");
        }

        foreach (var id in ids)
        {
            EnsureText(id, name, MaximumIdentifierLength);
        }

        if (requireSorted && !ids.SequenceEqual(ids.OrderBy(item => item, StringComparer.Ordinal), StringComparer.Ordinal))
        {
            throw new SnapshotExportException($"The export field {name} is not canonically ordered.");
        }
    }

    private static DailySummarySnapshotExport MapDailySummary(
        DailySummarySnapshot snapshot) =>
        new(
            snapshot.ContractVersion,
            snapshot.AggregatorId,
            FormatLocalDate(snapshot.LocalDate),
            snapshot.TimeZoneId,
            snapshot.SourceSetSha256,
            snapshot.AcceptedSources
                .Select(item => new DailySummarySourceReferenceExport(
                    item.SourceId,
                    item.Kind,
                    item.SourceHashSha256))
                .ToArray(),
            snapshot.Metrics
                .Select(item => new DailySummaryMetricExport(
                    item.MetricId,
                    item.Value,
                    item.SourceIds.ToArray()))
                .ToArray(),
            snapshot.Workstreams
                .Select(item => new DailySummaryWorkstreamExport(
                    item.Workstream,
                    item.AcceptedSourceCount,
                    item.ActivityCount,
                    item.EvidenceCount,
                    item.SourceIds.ToArray()))
                .ToArray(),
            snapshot.Highlights
                .Select(item => new DailySummaryHighlightExport(
                    item.SourceId,
                    item.Workstream,
                    item.Summary,
                    item.SourceIds.ToArray()))
                .ToArray(),
            snapshot.RepeatedIssues
                .Select(item => new DailySummaryRepeatedIssueExport(
                    item.IssueKey,
                    item.OccurrenceCount,
                    item.Workstream,
                    item.Description,
                    item.SourceIds.ToArray()))
                .ToArray(),
            snapshot.RecommendedActions
                .Select(item => new DailySummaryRecommendedActionExport(
                    item.ActionKey,
                    item.Description,
                    item.SourceIds.ToArray()))
                .ToArray(),
            snapshot.Timeline
                .Select(item => new DailySummaryTimelineEntryExport(
                    item.SourceId,
                    item.Kind,
                    FormatDateTimeOffset(item.OccurredLocal),
                    item.Workstream,
                    item.Category,
                    item.Summary,
                    item.SourceHashSha256))
                .ToArray(),
            snapshot.ResultSha256);

    private static SnapshotExportMetadata CreateMetadata(
        string exportKind,
        DateTimeOffset generatedUtc,
        string exportId,
        string sourceSnapshotSha256) =>
        new(
            ExportContractVersion,
            ExporterId,
            exportKind,
            FormatUtc(generatedUtc),
            "UTF-8 without BOM",
            exportId,
            sourceSnapshotSha256,
            new SnapshotExportRedactionPolicy(
                RedactionPolicyId,
                "fail-closed",
                ["filesystem-path", "secret", "token"],
                "reject export; never redact in place"));

    private static DeterministicSnapshotExport CreateExport<TDocument>(
        SnapshotExportKind kind,
        TDocument document,
        string exportId,
        string sourceSnapshotSha256)
    {
        var json = JsonSerializer.Serialize(document, JsonOptions)
            .Replace("\r\n", "\n", StringComparison.Ordinal)
            .Replace("\r", "\n", StringComparison.Ordinal);
        using var jsonDocument = JsonDocument.Parse(json);
        EnsureNoProhibitedContent(jsonDocument.RootElement, "$");
        EnsureSerializedBounds(jsonDocument.RootElement);
        var csv = BuildCsv(jsonDocument.RootElement);
        var jsonBytes = StrictUtf8.GetBytes(json);
        var csvBytes = StrictUtf8.GetBytes(csv);
        var jsonSha256 = ComputeSha256(jsonBytes);
        var csvSha256 = ComputeSha256(csvBytes);
        var markdown = BuildMarkdown(
            kind,
            jsonDocument.RootElement,
            exportId,
            sourceSnapshotSha256,
            jsonSha256,
            csvSha256);
        var markdownBytes = StrictUtf8.GetBytes(markdown);
        var markdownSha256 = ComputeSha256(markdownBytes);
        var totalByteLength = (long)jsonBytes.Length + markdownBytes.Length + csvBytes.Length;
        if (totalByteLength > MaximumTotalOutputBytes)
        {
            throw new SnapshotExportException(
                $"The export exceeds the maximum total output size of {MaximumTotalOutputBytes} bytes.");
        }

        var manifest = new SnapshotExportManifest(
            ExportContractVersion,
            kind,
            exportId,
            sourceSnapshotSha256,
            jsonSha256,
            markdownSha256,
            csvSha256,
            jsonBytes.Length,
            markdownBytes.Length,
            csvBytes.Length,
            totalByteLength);
        return new DeterministicSnapshotExport(
            kind,
            json,
            csv,
            jsonSha256,
            csvSha256,
            "UTF-8 without BOM; JSON LF; CSV CRLF",
            markdown,
            markdownSha256,
            exportId,
            sourceSnapshotSha256,
            manifest);
    }

    private static void EnsureNoProhibitedContent(JsonElement element, string path)
    {
        switch (element.ValueKind)
        {
            case JsonValueKind.Object:
                foreach (var property in element.EnumerateObject())
                {
                    var propertyPath = $"{path}.{property.Name}";
                    if (!propertyPath.StartsWith(
                            "$.metadata.redactionPolicy",
                            StringComparison.Ordinal))
                    {
                        EnsureNoProhibitedContent(property.Value, propertyPath);
                    }
                }

                break;
            case JsonValueKind.Array:
                for (var index = 0; index < element.GetArrayLength(); index++)
                {
                    EnsureNoProhibitedContent(element[index], $"{path}[{index}]");
                }

                break;
            case JsonValueKind.String:
                var value = element.GetString();
                if (value is not null)
                {
                    EnsureStrictUtf8(value, path);
                    if (SensitivePropertyPattern.IsMatch(path) ||
                        ContainsUnsafePath(value) ||
                        SecretOrTokenPattern.IsMatch(value))
                    {
                        throw new SnapshotExportException(
                            $"Export rejected by the fail-closed redaction policy at {path}.");
                    }
                }

                break;
        }
    }

    private static bool ContainsUnsafePath(string value)
    {
        if (UnsafePathPrefixes.Any(prefix =>
                value.StartsWith(prefix, StringComparison.Ordinal)) ||
            FileSystemPathPattern.IsMatch(value) ||
            DriveRelativePathPattern.IsMatch(value) ||
            RelativeFilePathPattern.IsMatch(value))
        {
            return true;
        }

        foreach (Match match in PathCandidatePattern.Matches(value))
        {
            if (IsUnsafePathCandidate(match.Groups["candidate"].Value))
            {
                return true;
            }
        }

        return false;
    }

    private static bool IsUnsafePathCandidate(string candidate)
    {
        var normalized = candidate.TrimEnd('.', ',', ';', ':', ')', ']', '}');
        if (string.IsNullOrWhiteSpace(normalized))
        {
            return false;
        }

        if (UnsafePathPrefixes.Any(prefix =>
                normalized.StartsWith(prefix, StringComparison.Ordinal)) ||
            normalized.StartsWith("\\\\?\\", StringComparison.Ordinal) ||
            normalized.StartsWith("\\\\.\\", StringComparison.Ordinal) ||
            normalized.Contains("..", StringComparison.Ordinal))
        {
            return true;
        }

        if (Uri.TryCreate(normalized, UriKind.Absolute, out var uri) &&
            !string.IsNullOrWhiteSpace(uri.Scheme))
        {
            return true;
        }

        if (normalized.Contains('\\'))
        {
            return true;
        }

        var segments = normalized.Split('/');
        if (segments.Length < 2 || segments.Any(string.IsNullOrWhiteSpace))
        {
            return false;
        }

        if (segments.Any(segment => segment is "." or ".." || segment.Contains('.')))
        {
            return true;
        }

        if (segments.All(IsNumericPathSegment) ||
            segments.All(segment => segment.Length <= 1) ||
            HarmlessSlashValues.Contains(normalized))
        {
            return false;
        }

        return segments.All(IsPathSegment);
    }

    private static bool IsNumericPathSegment(string value) =>
        value.Length > 0 && value.All(character => character is >= '0' and <= '9');

    private static bool IsPathSegment(string value) =>
        value.Length > 1 && value.All(character =>
            char.IsLetterOrDigit(character) || character is '_' or '-');

    private static readonly HashSet<string> HarmlessSlashValues = new(
        StringComparer.OrdinalIgnoreCase)
    {
        "A/B",
        "and/or",
        "input/output",
        "read/write",
    };

    private static readonly string[] UnsafePathPrefixes =
    [
        "/",
        "\\",
        "//",
        "\\\\",
        "~/",
        "~\\",
        "./",
        ".\\",
        "../",
        "..\\",
    ];

    private static void EnsureSerializedBounds(JsonElement root)
    {
        var nodeCount = 0;
        var referenceCount = 0;
        WalkSerializedElement(root, "$", ref nodeCount, ref referenceCount);
    }

    private static void WalkSerializedElement(
        JsonElement element,
        string path,
        ref int nodeCount,
        ref int referenceCount)
    {
        nodeCount++;
        if (nodeCount > MaximumSerializedNodes)
        {
            throw new SnapshotExportException(
                $"The export exceeds the maximum serialized node count of {MaximumSerializedNodes}.");
        }

        switch (element.ValueKind)
        {
            case JsonValueKind.Object:
                var properties = element.EnumerateObject().ToArray();
                if (properties.Length > MaximumObjectProperties)
                {
                    throw new SnapshotExportException(
                        $"The export exceeds the maximum object property count of {MaximumObjectProperties}.");
                }

                foreach (var property in properties)
                {
                    WalkSerializedElement(
                        property.Value,
                        $"{path}.{property.Name}",
                        ref nodeCount,
                        ref referenceCount);
                }

                break;
            case JsonValueKind.Array:
                if (element.GetArrayLength() > MaximumCollectionItems)
                {
                    throw new SnapshotExportException(
                        $"The export exceeds the maximum collection cardinality of {MaximumCollectionItems}.");
                }

                if (IsReferencePath(path))
                {
                    referenceCount += element.GetArrayLength();
                    if (referenceCount > MaximumTotalReferenceItems)
                    {
                        throw new SnapshotExportException(
                            $"The export exceeds the maximum total reference cardinality of {MaximumTotalReferenceItems}.");
                    }
                }

                for (var index = 0; index < element.GetArrayLength(); index++)
                {
                    WalkSerializedElement(
                        element[index],
                        $"{path}[{index}]",
                        ref nodeCount,
                        ref referenceCount);
                }

                break;
            case JsonValueKind.String:
                var value = element.GetString();
                if (value is not null)
                {
                    EnsureStrictUtf8(value, path);
                    if (value.Length > MaximumTextLength ||
                        StrictUtf8.GetByteCount(value) > MaximumTextBytes)
                    {
                        throw new SnapshotExportException(
                            $"The export exceeds the maximum text bound of {MaximumTextLength} characters or {MaximumTextBytes} UTF-8 bytes.");
                    }
                }

                break;
        }
    }

    private static bool IsReferencePath(string path) =>
        path.Contains("sourceIds", StringComparison.Ordinal) ||
        path.Contains("sourceIdentities", StringComparison.Ordinal) ||
        path.EndsWith(".dimensions", StringComparison.Ordinal) ||
        path.EndsWith(".observedInputs", StringComparison.Ordinal) ||
        path.EndsWith(".acceptedSources", StringComparison.Ordinal) ||
        path.EndsWith(".timeline", StringComparison.Ordinal) ||
        path.EndsWith(".metrics", StringComparison.Ordinal) ||
        path.EndsWith(".workstreams", StringComparison.Ordinal) ||
        path.EndsWith(".highlights", StringComparison.Ordinal) ||
        path.EndsWith(".repeatedIssues", StringComparison.Ordinal) ||
        path.EndsWith(".recommendedActions", StringComparison.Ordinal);

    private static string BuildMarkdown(
        SnapshotExportKind kind,
        JsonElement root,
        string exportId,
        string sourceSnapshotSha256,
        string jsonSha256,
        string csvSha256)
    {
        var builder = new StringBuilder();
        builder.AppendLine("# HerdrOps Snapshot Export");
        builder.AppendLine();
        builder.AppendLine($"- Export ID: `{exportId}`");
        builder.AppendLine($"- Kind: `{kind}`");
        builder.AppendLine($"- Source Snapshot SHA-256: `{sourceSnapshotSha256}`");
        builder.AppendLine($"- JSON SHA-256: `{jsonSha256}`");
        builder.AppendLine($"- CSV SHA-256: `{csvSha256}`");
        builder.AppendLine("- Markdown SHA-256: recorded in `manifest.json`");
        builder.AppendLine();

        AppendMarkdownObject(builder, "Metadata", root.GetProperty("metadata"), 2);
        AppendMarkdownObject(builder, "Source", root.GetProperty("source"), 2);
        AppendMarkdownObject(builder, "Accepted Snapshot", root.GetProperty("acceptedSnapshot"), 2);
        return builder.ToString().Replace("\r\n", "\n", StringComparison.Ordinal)
            .Replace("\r", "\n", StringComparison.Ordinal);
    }

    private static void AppendMarkdownObject(
        StringBuilder builder,
        string title,
        JsonElement element,
        int headingLevel)
    {
        builder.Append(new string('#', Math.Min(headingLevel, 6)));
        builder.Append(' ');
        builder.AppendLine(title);
        builder.AppendLine();
        AppendMarkdownObjectFields(builder, element, headingLevel);
    }

    private static void AppendMarkdownObjectFields(
        StringBuilder builder,
        JsonElement element,
        int headingLevel)
    {
        foreach (var property in element.EnumerateObject())
        {
            var label = ToMarkdownLabel(property.Name);
            switch (property.Value.ValueKind)
            {
                case JsonValueKind.Object:
                    AppendMarkdownObject(builder, label, property.Value, headingLevel + 1);
                    break;
                case JsonValueKind.Array:
                    AppendMarkdownArray(builder, label, property.Value, headingLevel + 1);
                    break;
                default:
                    builder.Append("- ");
                    builder.Append(label);
                    builder.Append(": ");
                    builder.AppendLine(FormatMarkdownScalar(property.Value));
                    break;
            }
        }

        builder.AppendLine();
    }

    private static void AppendMarkdownArray(
        StringBuilder builder,
        string label,
        JsonElement array,
        int headingLevel)
    {
        builder.Append(new string('#', Math.Min(headingLevel, 6)));
        builder.Append(' ');
        builder.AppendLine(label);
        builder.AppendLine();
        if (array.GetArrayLength() == 0)
        {
            builder.AppendLine("- None");
            builder.AppendLine();
            return;
        }

        var index = 0;
        foreach (var item in array.EnumerateArray())
        {
            index++;
            if (item.ValueKind == JsonValueKind.Object)
            {
                builder.Append(new string('#', Math.Min(headingLevel + 1, 6)));
                builder.Append(" Item ");
                builder.AppendLine(index.ToString(CultureInfo.InvariantCulture));
                builder.AppendLine();
                AppendMarkdownObjectFields(builder, item, headingLevel + 1);
            }
            else
            {
                builder.Append("- ");
                builder.AppendLine(FormatMarkdownScalar(item));
            }
        }

        builder.AppendLine();
    }

    private static string FormatMarkdownScalar(JsonElement element)
    {
        if (element.ValueKind == JsonValueKind.Null)
        {
            return "null";
        }

        if (element.ValueKind != JsonValueKind.String)
        {
            return element.GetRawText();
        }

        var value = element.GetString() ?? string.Empty;
        var longestBacktickRun = 0;
        var currentBacktickRun = 0;
        foreach (var character in value)
        {
            if (character == '`')
            {
                currentBacktickRun++;
                longestBacktickRun = Math.Max(longestBacktickRun, currentBacktickRun);
            }
            else
            {
                currentBacktickRun = 0;
            }
        }

        var delimiter = new string('`', longestBacktickRun + 1);
        var paddedValue = value.Length > 0 && (value[0] == ' ' || value[^1] == ' ')
            ? $" {value} "
            : value;
        return $"{delimiter}{paddedValue}{delimiter}";
    }

    private static string ToMarkdownLabel(string value)
    {
        var builder = new StringBuilder(value.Length + 8);
        for (var index = 0; index < value.Length; index++)
        {
            var character = value[index];
            if (character is '_' or '-')
            {
                builder.Append(' ');
                continue;
            }

            if (index > 0 && char.IsUpper(character) && char.IsLower(value[index - 1]))
            {
                builder.Append(' ');
            }

            builder.Append(character);
        }

        return builder.ToString() is { Length: > 0 } label
            ? char.ToUpperInvariant(label[0]) + label[1..]
            : value;
    }

    private static string BuildCsv(JsonElement root)
    {
        var builder = new StringBuilder("path,type,value\r\n");
        AppendCsvRows(root, "$", builder);
        return builder.ToString();
    }

    private static void AppendCsvRows(
        JsonElement element,
        string path,
        StringBuilder builder)
    {
        switch (element.ValueKind)
        {
            case JsonValueKind.Object:
                var properties = element.EnumerateObject().ToArray();
                if (properties.Length == 0)
                {
                    AppendCsvRow(builder, path, "object", "{}");
                }
                else
                {
                    foreach (var property in properties)
                    {
                        AppendCsvRows(property.Value, $"{path}.{property.Name}", builder);
                    }
                }

                break;
            case JsonValueKind.Array:
                if (element.GetArrayLength() == 0)
                {
                    AppendCsvRow(builder, path, "array", "[]");
                }
                else
                {
                    for (var index = 0; index < element.GetArrayLength(); index++)
                    {
                        AppendCsvRows(element[index], $"{path}[{index}]", builder);
                    }
                }

                break;
            case JsonValueKind.String:
                AppendCsvRow(builder, path, "string", element.GetString() ?? string.Empty);
                break;
            case JsonValueKind.Null:
                AppendCsvRow(builder, path, "null", string.Empty);
                break;
            default:
                AppendCsvRow(builder, path, element.ValueKind.ToString().ToLowerInvariant(), element.GetRawText());
                break;
        }
    }

    private static void AppendCsvRow(
        StringBuilder builder,
        string path,
        string type,
        string value)
    {
        builder.Append(path);
        builder.Append(',');
        builder.Append(type);
        builder.Append(',');
        builder.Append(EscapeCsv(value));
        builder.Append("\r\n");
    }

    private static string EscapeCsv(string value)
    {
        if (!value.Contains('"') &&
            !value.Contains(',') &&
            !value.Contains('\r') &&
            !value.Contains('\n'))
        {
            return value;
        }

        return $"\"{value.Replace("\"", "\"\"", StringComparison.Ordinal)}\"";
    }

    private static DateTimeOffset NormalizeGeneratedUtc(DateTimeOffset generatedUtc)
    {
        if (generatedUtc.Offset != TimeSpan.Zero)
        {
            throw new SnapshotExportException(
                "Generation time must be supplied as an explicit UTC DateTimeOffset.");
        }

        return generatedUtc.ToUniversalTime();
    }

    private static DayBoundaries BindAcceptedDayBoundaries(
        DailySummarySnapshot snapshot,
        TimeZoneInfo timeZone)
    {
        var boundaries = CalculateDayBoundaries(snapshot.LocalDate, timeZone);
        var observedOffsets = new HashSet<TimeSpan>();
        foreach (var timeline in snapshot.Timeline)
        {
            var acceptedLocal = timeline.OccurredLocal;
            var projectedLocal = TimeZoneInfo.ConvertTime(acceptedLocal, timeZone);
            if (projectedLocal.DateTime != acceptedLocal.DateTime ||
                projectedLocal.Offset != acceptedLocal.Offset)
            {
                throw new SnapshotExportException(
                    "The supplied Daily Summary time zone rules do not match the accepted snapshot.");
            }

            observedOffsets.Add(acceptedLocal.Offset);
        }

        var localStart = DateTime.SpecifyKind(
            snapshot.LocalDate.ToDateTime(TimeOnly.MinValue),
            DateTimeKind.Unspecified);
        var localEndExclusive = localStart.AddDays(1);
        foreach (var boundary in new[] { (Local: localStart, Utc: boundaries.UtcStart), (Local: localEndExclusive, Utc: boundaries.UtcEndExclusive) })
        {
            var acceptedBoundary = snapshot.Timeline
                .Select(item => item.OccurredLocal)
                .FirstOrDefault(item =>
                    DateTime.SpecifyKind(item.DateTime, DateTimeKind.Unspecified) == boundary.Local);
            if (acceptedBoundary != default &&
                acceptedBoundary.ToUniversalTime() != boundary.Utc)
            {
                throw new SnapshotExportException(
                    "The supplied Daily Summary UTC boundaries do not match the accepted snapshot.");
            }
        }

        if (observedOffsets.Count > 0 &&
            timeZone.GetAdjustmentRules().Length == 0 &&
            !observedOffsets.Contains(timeZone.BaseUtcOffset))
        {
            throw new SnapshotExportException(
                "The supplied Daily Summary fixed offset does not match the accepted snapshot.");
        }

        return boundaries;
    }

    private static DayBoundaries CalculateDayBoundaries(
        DateOnly localDate,
        TimeZoneInfo timeZone)
    {
        var localStart = DateTime.SpecifyKind(
            localDate.ToDateTime(TimeOnly.MinValue),
            DateTimeKind.Unspecified);
        var localEndExclusive = localStart.AddDays(1);
        if (timeZone.IsInvalidTime(localStart) || timeZone.IsInvalidTime(localEndExclusive) ||
            timeZone.IsAmbiguousTime(localStart) || timeZone.IsAmbiguousTime(localEndExclusive))
        {
            throw new SnapshotExportException(
                "The Daily Summary local-day boundary is ambiguous or invalid in its time zone.");
        }

        return new DayBoundaries(
            localStart,
            localEndExclusive,
            new DateTimeOffset(TimeZoneInfo.ConvertTimeToUtc(localStart, timeZone)),
            new DateTimeOffset(TimeZoneInfo.ConvertTimeToUtc(localEndExclusive, timeZone)));
    }

    private static string FormatLocalDate(DateOnly value) =>
        value.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);

    private static string FormatLocalBoundary(DateTime value) =>
        value.ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff", CultureInfo.InvariantCulture);

    private static string FormatDateTimeOffset(DateTimeOffset value) =>
        value.ToString("O", CultureInfo.InvariantCulture);

    private static string FormatUtc(DateTimeOffset value) =>
        value.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'", CultureInfo.InvariantCulture);

    public static string SerializeManifest(SnapshotExportManifest manifest)
    {
        ArgumentNullException.ThrowIfNull(manifest);
        var json = JsonSerializer.Serialize(manifest, JsonOptions);
        return json.Replace("\r\n", "\n", StringComparison.Ordinal)
            .Replace("\r", "\n", StringComparison.Ordinal);
    }

    private static string CreateExportId(
        SnapshotExportKind kind,
        string sourceSnapshotSha256,
        DateTimeOffset generatedUtc)
    {
        var identity = string.Join(
            "|",
            "HerdrOps.SnapshotExport.v1",
            ((int)kind).ToString(CultureInfo.InvariantCulture),
            sourceSnapshotSha256,
            FormatUtc(generatedUtc));
        return ComputeSha256(StrictUtf8.GetBytes(identity));
    }

    private static bool IsSha256(string? value) =>
        value is { Length: 64 } && value.All(Uri.IsHexDigit);

    private static string ComputeSha256(byte[] bytes) =>
        Convert.ToHexString(SHA256.HashData(bytes));

    private static JsonSerializerOptions CreateJsonOptions() =>
        new()
        {
            Encoder = System.Text.Encodings.Web.JavaScriptEncoder.Default,
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
            WriteIndented = true,
            Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) },
        };

    private sealed record DayBoundaries(
        DateTime LocalStart,
        DateTime LocalEndExclusive,
        DateTimeOffset UtcStart,
        DateTimeOffset UtcEndExclusive);
}
