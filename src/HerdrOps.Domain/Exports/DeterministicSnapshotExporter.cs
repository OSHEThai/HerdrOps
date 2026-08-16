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
    SnapshotExportRedactionPolicy RedactionPolicy);

public sealed record EvaluationExportSourceIdentity(
    string Dimension,
    string Source,
    string ProvenanceId,
    string EvidenceIdentitySha256);

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

public sealed record DeterministicSnapshotExport(
    SnapshotExportKind Kind,
    string Json,
    string Csv,
    string JsonSha256,
    string CsvSha256,
    string Encoding);

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

    private static readonly JsonSerializerOptions JsonOptions = CreateJsonOptions();
    private static readonly Regex FileSystemPathPattern = new(
        @"(?:[A-Za-z]:[\\/]|\\\\|(?:^|[\s])/(?:etc|home|Users|var|tmp|private)(?:[\\/]|$)|(?:^|[\s])~[\\/])",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);
    private static readonly Regex SecretOrTokenPattern = new(
        @"\b(?:api[_-]?key|client[_-]?secret|access[_-]?token|refresh[_-]?token|id[_-]?token|password|passwd|secret|credential|authorization|bearer|jwt|token)\b\s*(?:[:=]|$)",
        RegexOptions.Compiled | RegexOptions.CultureInvariant | RegexOptions.IgnoreCase);

    public static DeterministicSnapshotExport ExportEvaluation(
        EvaluationScoreResult acceptedSnapshot,
        DateTimeOffset generatedUtc)
    {
        var normalizedGeneratedUtc = NormalizeGeneratedUtc(generatedUtc);
        var accepted = ValidateEvaluation(acceptedSnapshot);
        var metadata = CreateMetadata(
            "evaluation-score-result",
            normalizedGeneratedUtc);
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

        return CreateExport(SnapshotExportKind.EvaluationScoreResult, document);
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

        var boundaries = CalculateDayBoundaries(accepted.LocalDate, timeZone);
        var metadata = CreateMetadata("daily-summary", normalizedGeneratedUtc);
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

        return CreateExport(SnapshotExportKind.DailySummary, document);
    }

    private static EvaluationScoreResult ValidateEvaluation(
        EvaluationScoreResult snapshot)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        EnsureEvaluationShape(snapshot);
        try
        {
            var reproduced = new EvaluationScoringEngine().Recalculate(snapshot);
            if (snapshot.Status != EvaluationResultStatus.Complete ||
                snapshot.TotalScore is null ||
                snapshot.InputIssues.Count != 0 ||
                snapshot.Dimensions.Any(item =>
                    item.Status != EvaluationDimensionScoreStatus.Complete ||
                    item.DimensionScore is null ||
                    item.WeightedScore is null))
            {
                throw new SnapshotExportException(
                    "Only complete, issue-free Evaluation Score Results can be exported.");
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
            exception is NullReferenceException)
        {
            throw new SnapshotExportException(
                "The Evaluation Score Result is not an accepted deterministic result.",
                exception);
        }

        return snapshot;
    }

    private static void EnsureEvaluationShape(EvaluationScoreResult snapshot)
    {
        ArgumentNullException.ThrowIfNull(snapshot.Provenance);
        ArgumentNullException.ThrowIfNull(snapshot.Provenance.Formula);
        ArgumentNullException.ThrowIfNull(snapshot.Provenance.Formula.DimensionWeights);
        ArgumentNullException.ThrowIfNull(snapshot.Provenance.Formula.SourceWeights);
        ArgumentNullException.ThrowIfNull(snapshot.Provenance.InputSnapshot);
        ArgumentNullException.ThrowIfNull(snapshot.Provenance.InputSnapshot.Dimensions);
        ArgumentNullException.ThrowIfNull(snapshot.InputIssues);
        ArgumentNullException.ThrowIfNull(snapshot.Dimensions);

        foreach (var issue in snapshot.InputIssues)
        {
            ArgumentNullException.ThrowIfNull(issue);
        }

        foreach (var dimension in snapshot.Provenance.InputSnapshot.Dimensions)
        {
            ArgumentNullException.ThrowIfNull(dimension);
            EnsureScoreInput(dimension.Leader);
            EnsureScoreInput(dimension.ProjectManager);
            EnsureScoreInput(dimension.ObjectiveEvidence);
        }

        foreach (var dimension in snapshot.Dimensions)
        {
            ArgumentNullException.ThrowIfNull(dimension);
            ArgumentNullException.ThrowIfNull(dimension.ObservedInputs);
            ArgumentNullException.ThrowIfNull(dimension.Issues);
            EnsureScoreInput(dimension.Leader);
            EnsureScoreInput(dimension.ProjectManager);
            EnsureScoreInput(dimension.ObjectiveEvidence);
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
            }
        }
    }

    private static void EnsureScoreInput(EvaluationScoreInput input)
    {
        ArgumentNullException.ThrowIfNull(input);
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
                    item.Leader.ProvenanceId ?? string.Empty,
                    item.Leader.EvidenceIdentitySha256 ?? string.Empty),
                new EvaluationExportSourceIdentity(
                    item.Dimension.ToString(),
                    EvaluationScoreSource.ProjectManager.ToString(),
                    item.ProjectManager.ProvenanceId ?? string.Empty,
                    item.ProjectManager.EvidenceIdentitySha256 ?? string.Empty),
                new EvaluationExportSourceIdentity(
                    item.Dimension.ToString(),
                    EvaluationScoreSource.ObjectiveEvidence.ToString(),
                    item.ObjectiveEvidence.ProvenanceId ?? string.Empty,
                    item.ObjectiveEvidence.EvidenceIdentitySha256 ?? string.Empty),
            })
            .ToArray();

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
        DateTimeOffset generatedUtc) =>
        new(
            ExportContractVersion,
            ExporterId,
            exportKind,
            FormatUtc(generatedUtc),
            "UTF-8 without BOM",
            new SnapshotExportRedactionPolicy(
                RedactionPolicyId,
                "fail-closed",
                ["filesystem-path", "secret", "token"],
                "reject export; never redact in place"));

    private static DeterministicSnapshotExport CreateExport<TDocument>(
        SnapshotExportKind kind,
        TDocument document)
    {
        var json = JsonSerializer.Serialize(document, JsonOptions)
            .Replace("\r\n", "\n", StringComparison.Ordinal)
            .Replace("\r", "\n", StringComparison.Ordinal);
        using var jsonDocument = JsonDocument.Parse(json);
        EnsureNoProhibitedContent(jsonDocument.RootElement, "$");
        var csv = BuildCsv(jsonDocument.RootElement);
        var jsonBytes = Encoding.UTF8.GetBytes(json);
        var csvBytes = Encoding.UTF8.GetBytes(csv);
        return new DeterministicSnapshotExport(
            kind,
            json,
            csv,
            ComputeSha256(jsonBytes),
            ComputeSha256(csvBytes),
            "UTF-8 without BOM; JSON LF; CSV CRLF");
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
                if (value is not null &&
                    (FileSystemPathPattern.IsMatch(value) || SecretOrTokenPattern.IsMatch(value)))
                {
                    throw new SnapshotExportException(
                        $"Export rejected by the fail-closed redaction policy at {path}.");
                }

                break;
        }
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
