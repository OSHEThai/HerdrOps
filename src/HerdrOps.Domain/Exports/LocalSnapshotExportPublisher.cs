using System.Globalization;
using System.Security;
using System.Security.Cryptography;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using HerdrOps.Domain.Evaluation;
using HerdrOps.Domain.Summaries;

namespace HerdrOps.Domain.Exports;

public enum SnapshotExportPublicationPhase
{
    StagingDirectoryCreated = 1,
    FilesWritten = 2,
    BeforeCommit = 3,
}

public sealed record LocalSnapshotExportPublication(
    string DirectoryPath,
    string JsonPath,
    string MarkdownPath,
    string CsvPath,
    string ManifestPath,
    SnapshotExportManifest Manifest);

public sealed class LocalSnapshotExportPublisher
{
    private const string ExportEncoding = "UTF-8 without BOM; JSON LF; CSV CRLF";
    private const string MetadataEncoding = "UTF-8 without BOM";

    private static readonly UTF8Encoding StrictUtf8 = new(
        encoderShouldEmitUTF8Identifier: false,
        throwOnInvalidBytes: true);

    private static readonly JsonSerializerOptions ValidationJsonOptions = new()
    {
        Encoder = JavaScriptEncoder.Default,
        PropertyNameCaseInsensitive = false,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
        Converters =
        {
            new JsonStringEnumConverter(JsonNamingPolicy.CamelCase, allowIntegerValues: false),
        },
    };

    private static readonly Regex FileSystemPathPattern = new(
        @"(?<![A-Za-z0-9_])(?:[A-Za-z]:[\\/]|\\\\[^\s\\/]+[\\/]|/(?!/)(?:[^\s/]+/)+[^\s/]+|~[\\/])",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);

    private static readonly Regex SecretOrTokenPattern = new(
        @"(?:\b(?:api[_-]?key|client[_-]?secret|access[_-]?token|refresh[_-]?token|id[_-]?token|password|passwd|secret|credential|authorization|bearer|jwt|token)\b\s*(?:[:=]|$)|\bBearer\s+[A-Za-z0-9._~+/=-]{12,}|\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b|(?<![A-Za-z0-9])(?:token|jwt)[A-Za-z0-9_-]{12,}(?![A-Za-z0-9]))",
        RegexOptions.Compiled | RegexOptions.CultureInvariant | RegexOptions.IgnoreCase);

    private static readonly Regex SensitivePropertyPattern = new(
        @"(?:secret|password|passwd|credential|authorization|bearer|jwt|token|api[_-]?key)",
        RegexOptions.Compiled | RegexOptions.CultureInvariant | RegexOptions.IgnoreCase);

    private readonly Action<SnapshotExportPublicationPhase>? _phaseObserver;

    public LocalSnapshotExportPublisher(
        Action<SnapshotExportPublicationPhase>? phaseObserver = null)
    {
        _phaseObserver = phaseObserver;
    }

    public LocalSnapshotExportPublication Publish(
        DeterministicSnapshotExport export,
        string destinationDirectory)
    {
        ArgumentNullException.ThrowIfNull(export);
        if (string.IsNullOrWhiteSpace(destinationDirectory))
        {
            throw new SnapshotExportException("The local export destination is required.");
        }

        ValidateExport(export);
        var destination = PrepareDestination(destinationDirectory);
        var directoryName = $"herdops-{export.Kind.ToString().ToLowerInvariant()}-{export.ExportId}";
        var finalDirectory = Path.Combine(destination, directoryName);
        EnsurePathIsAvailable(finalDirectory, "The local export already exists and will not be overwritten.");

        var stagingDirectory = Path.Combine(
            destination,
            $".{directoryName}.staging-{Guid.NewGuid():N}");
        var committed = false;
        try
        {
            EnsurePathIsAvailable(
                stagingDirectory,
                "The local export staging path is already in use.");
            Directory.CreateDirectory(stagingDirectory);
            EnsureNoReparsePointsInPath(stagingDirectory);
            _phaseObserver?.Invoke(SnapshotExportPublicationPhase.StagingDirectoryCreated);

            var jsonPath = Path.Combine(stagingDirectory, "snapshot.json");
            var markdownPath = Path.Combine(stagingDirectory, "snapshot.md");
            var csvPath = Path.Combine(stagingDirectory, "snapshot.csv");
            var manifestPath = Path.Combine(stagingDirectory, "manifest.json");
            WriteUtf8(jsonPath, export.Json, expectCrLf: false);
            WriteUtf8(markdownPath, export.Markdown, expectCrLf: false);
            WriteUtf8(csvPath, export.Csv, expectCrLf: true);
            WriteUtf8(
                manifestPath,
                DeterministicSnapshotExporter.SerializeManifest(export.Manifest),
                expectCrLf: false);
            ValidateStagedFiles(export, jsonPath, markdownPath, csvPath, manifestPath);
            _phaseObserver?.Invoke(SnapshotExportPublicationPhase.FilesWritten);
            ValidateStagedFiles(export, jsonPath, markdownPath, csvPath, manifestPath);
            _phaseObserver?.Invoke(SnapshotExportPublicationPhase.BeforeCommit);
            ValidateStagedFiles(export, jsonPath, markdownPath, csvPath, manifestPath);

            EnsureNoReparsePointsInPath(destination);
            EnsurePathIsAvailable(
                finalDirectory,
                "The local export already exists and will not be overwritten.");
            Directory.Move(stagingDirectory, finalDirectory);
            committed = true;
            return new LocalSnapshotExportPublication(
                finalDirectory,
                Path.Combine(finalDirectory, "snapshot.json"),
                Path.Combine(finalDirectory, "snapshot.md"),
                Path.Combine(finalDirectory, "snapshot.csv"),
                Path.Combine(finalDirectory, "manifest.json"),
                export.Manifest);
        }
        catch (SnapshotExportException)
        {
            throw;
        }
        catch (Exception exception)
        {
            throw new SnapshotExportException(
                "The local export publication failed before atomic commit.",
                exception);
        }
        finally
        {
            if (!committed && Directory.Exists(stagingDirectory))
            {
                try
                {
                    Directory.Delete(stagingDirectory, recursive: true);
                }
                catch
                {
                    // Preserve the original failure; the staging path is never published.
                }
            }
        }
    }

    private static void ValidateExport(DeterministicSnapshotExport export)
    {
        try
        {
            ValidateEnvelopeShape(export);

            var jsonBytes = GetStrictUtf8Bytes(export.Json, "JSON report");
            var markdownBytes = GetStrictUtf8Bytes(export.Markdown, "Markdown report");
            var csvBytes = GetStrictUtf8Bytes(export.Csv, "CSV report");
            var manifestJson = DeterministicSnapshotExporter.SerializeManifest(export.Manifest);
            var manifestBytes = GetStrictUtf8Bytes(manifestJson, "manifest");
            var totalBytes = (long)jsonBytes.Length + markdownBytes.Length + csvBytes.Length;

            EnsureNoUtf8Bom(jsonBytes, "JSON report");
            EnsureNoUtf8Bom(markdownBytes, "Markdown report");
            EnsureNoUtf8Bom(csvBytes, "CSV report");
            EnsureNoUtf8Bom(manifestBytes, "manifest");
            if (export.Json.Contains('\r') || export.Markdown.Contains('\r'))
            {
                throw new SnapshotExportException(
                    "The local export JSON and Markdown reports must use LF line endings.");
            }

            EnsureCrLfOnly(export.Csv, "CSV report");
            if (jsonBytes.Length != export.Manifest.JsonByteLength ||
                markdownBytes.Length != export.Manifest.MarkdownByteLength ||
                csvBytes.Length != export.Manifest.CsvByteLength ||
                totalBytes != export.Manifest.TotalByteLength ||
                totalBytes > DeterministicSnapshotExporter.MaximumTotalOutputBytes ||
                !ShaEqual(Sha256(jsonBytes), export.JsonSha256) ||
                !ShaEqual(Sha256(markdownBytes), export.MarkdownSha256) ||
                !ShaEqual(Sha256(csvBytes), export.CsvSha256))
            {
                throw new SnapshotExportException(
                    "The local export bytes do not reconcile to their manifest.");
            }

            ValidateCanonicalEnvelope(export, export.Json);
        }
        catch (SnapshotExportException)
        {
            throw;
        }
        catch (Exception exception) when (
            exception is ArgumentException or
            JsonException or
            FormatException or
            InvalidOperationException or
            NullReferenceException or
            KeyNotFoundException or
            OverflowException or
            NotSupportedException or
            TimeZoneNotFoundException or
            InvalidTimeZoneException)
        {
            throw new SnapshotExportException(
                "The local export envelope is malformed or outside the export contract.",
                exception);
        }
    }

    private static void ValidateEnvelopeShape(DeterministicSnapshotExport export)
    {
        if (export.Manifest is null ||
            !Enum.IsDefined(export.Kind) ||
            export.Kind is not (SnapshotExportKind.EvaluationScoreResult or SnapshotExportKind.DailySummary))
        {
            throw new SnapshotExportException("The local export kind is unsupported.");
        }

        var manifest = export.Manifest;
        if (manifest.ContractVersion != DeterministicSnapshotExporter.ExportContractVersion ||
            manifest.Kind != export.Kind ||
            !string.Equals(manifest.ExportId, export.ExportId, StringComparison.Ordinal) ||
            !ShaEqual(manifest.SourceSnapshotSha256, export.SourceSnapshotSha256) ||
            !ShaEqual(manifest.JsonSha256, export.JsonSha256) ||
            !ShaEqual(manifest.MarkdownSha256, export.MarkdownSha256) ||
            !ShaEqual(manifest.CsvSha256, export.CsvSha256) ||
            !IsSha256(export.ExportId) ||
            !IsSha256(export.SourceSnapshotSha256) ||
            !IsSha256(manifest.JsonSha256) ||
            !IsSha256(manifest.MarkdownSha256) ||
            !IsSha256(manifest.CsvSha256) ||
            manifest.JsonByteLength < 0 ||
            manifest.MarkdownByteLength < 0 ||
            manifest.CsvByteLength < 0 ||
            manifest.TotalByteLength < 0)
        {
            throw new SnapshotExportException("The local export manifest identity is inconsistent.");
        }

        if (!string.Equals(export.Encoding, ExportEncoding, StringComparison.Ordinal))
        {
            throw new SnapshotExportException("The local export encoding contract is invalid.");
        }
    }

    private static void ValidateCanonicalEnvelope(
        DeterministicSnapshotExport export,
        string json)
    {
        using var parsed = JsonDocument.Parse(
            json,
            new JsonDocumentOptions
            {
                AllowTrailingCommas = false,
                CommentHandling = JsonCommentHandling.Disallow,
                MaxDepth = 128,
            });
        EnsureNoProhibitedContent(parsed.RootElement, "$");
        EnsureSerializedBounds(parsed.RootElement);

        switch (export.Kind)
        {
            case SnapshotExportKind.EvaluationScoreResult:
                {
                    var document = DeserializeRequired<EvaluationSnapshotExportDocument>(json);
                    var generatedUtc = ValidateMetadata(
                        document.Metadata,
                        export,
                        "evaluation-score-result");
                    var accepted = ToEvaluationScoreResult(document.AcceptedSnapshot);
                    var expected = DeterministicSnapshotExporter.ExportEvaluation(accepted, generatedUtc);
                    EnsureCanonicalJson(document, json);
                    EnsureCanonicalEnvelope(export, expected);
                    break;
                }
            case SnapshotExportKind.DailySummary:
                {
                    var document = DeserializeRequired<DailySummarySnapshotExportDocument>(json);
                    _ = ValidateMetadata(document.Metadata, export, "daily-summary");
                    var accepted = ToDailySummarySnapshot(document);
                    ValidateDailySummarySnapshot(accepted);
                    ValidateDailySummarySource(document.Source, accepted);
                    EnsureCanonicalJson(document, json);
                    var jsonBytes = GetStrictUtf8Bytes(json, "JSON report");
                    var expectedCsv = BuildCanonicalCsv(parsed.RootElement);
                    var expectedMarkdown = BuildCanonicalMarkdown(
                        export.Kind,
                        parsed.RootElement,
                        export.ExportId,
                        export.SourceSnapshotSha256,
                        export.JsonSha256,
                        export.CsvSha256);
                    var csvBytes = GetStrictUtf8Bytes(expectedCsv, "CSV report");
                    var markdownBytes = GetStrictUtf8Bytes(expectedMarkdown, "Markdown report");
                    var expectedJsonSha256 = Sha256(jsonBytes);
                    var expectedCsvSha256 = Sha256(csvBytes);
                    var expectedMarkdownSha256 = Sha256(markdownBytes);
                    var expected = new DeterministicSnapshotExport(
                        export.Kind,
                        json,
                        expectedCsv,
                        expectedJsonSha256,
                        expectedCsvSha256,
                        ExportEncoding,
                        expectedMarkdown,
                        expectedMarkdownSha256,
                        export.ExportId,
                        export.SourceSnapshotSha256,
                        new SnapshotExportManifest(
                            DeterministicSnapshotExporter.ExportContractVersion,
                            export.Kind,
                            export.ExportId,
                            export.SourceSnapshotSha256,
                            expectedJsonSha256,
                            expectedMarkdownSha256,
                            expectedCsvSha256,
                            jsonBytes.LongLength,
                            markdownBytes.LongLength,
                            csvBytes.LongLength,
                            (long)jsonBytes.Length + markdownBytes.Length + csvBytes.Length));
                    EnsureCanonicalEnvelope(export, expected);
                    break;
                }
            default:
                throw new SnapshotExportException("The local export kind is unsupported.");
        }
    }

    private static T DeserializeRequired<T>(string json)
        where T : class
    {
        var value = JsonSerializer.Deserialize<T>(json, ValidationJsonOptions);
        return value ?? throw new SnapshotExportException("The local export JSON document is null.");
    }

    private static DateTimeOffset ValidateMetadata(
        SnapshotExportMetadata? metadata,
        DeterministicSnapshotExport export,
        string expectedKind)
    {
        if (metadata is null ||
            metadata.ExportContractVersion != DeterministicSnapshotExporter.ExportContractVersion ||
            !string.Equals(metadata.ExporterId, DeterministicSnapshotExporter.ExporterId, StringComparison.Ordinal) ||
            !string.Equals(metadata.ExportKind, expectedKind, StringComparison.Ordinal) ||
            !string.Equals(metadata.Encoding, MetadataEncoding, StringComparison.Ordinal) ||
            !ShaEqual(metadata.ExportId, export.ExportId) ||
            !ShaEqual(metadata.SourceSnapshotSha256, export.SourceSnapshotSha256) ||
            metadata.RedactionPolicy is null ||
            metadata.RedactionPolicy.ProhibitedContentKinds is null ||
            !string.Equals(
                metadata.RedactionPolicy.PolicyId,
                DeterministicSnapshotExporter.RedactionPolicyId,
                StringComparison.Ordinal) ||
            !string.Equals(metadata.RedactionPolicy.Mode, "fail-closed", StringComparison.Ordinal) ||
            !metadata.RedactionPolicy.ProhibitedContentKinds.SequenceEqual(
                ["filesystem-path", "secret", "token"],
                StringComparer.Ordinal) ||
            !string.Equals(
                metadata.RedactionPolicy.Action,
                "reject export; never redact in place",
                StringComparison.Ordinal))
        {
            throw new SnapshotExportException("The local export metadata is outside the export contract.");
        }

        if (!DateTimeOffset.TryParseExact(
                metadata.GeneratedUtc,
                "yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'",
                CultureInfo.InvariantCulture,
                DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal,
                out var generatedUtc) ||
            generatedUtc.Offset != TimeSpan.Zero ||
            !string.Equals(FormatUtc(generatedUtc), metadata.GeneratedUtc, StringComparison.Ordinal))
        {
            throw new SnapshotExportException("The local export generation timestamp is invalid.");
        }

        var expectedExportId = CreateExportId(export.Kind, metadata.SourceSnapshotSha256, generatedUtc);
        if (!ShaEqual(expectedExportId, export.ExportId))
        {
            throw new SnapshotExportException("The local export ID does not match its metadata binding.");
        }

        return generatedUtc;
    }

    private static EvaluationScoreResult ToEvaluationScoreResult(
        EvaluationScoreResultExport? value)
    {
        if (value is null || value.Provenance is null)
        {
            throw new SnapshotExportException("The Evaluation export snapshot is incomplete.");
        }

        var provenance = value.Provenance;
        if (provenance.Formula is null || provenance.InputSnapshot is null)
        {
            throw new SnapshotExportException("The Evaluation export provenance is incomplete.");
        }

        return new EvaluationScoreResult(
            value.ContractVersion,
            value.EvaluationId,
            value.TaskId,
            value.AgentId,
            value.Status,
            value.TotalScore,
            value.AvailableWeightBasisPoints,
            value.InputIssues?.Select(ToEvaluationIssue).ToArray()
                ?? throw new SnapshotExportException("The Evaluation input issue collection is null."),
            value.Dimensions?.Select(ToEvaluationDimension).ToArray()
                ?? throw new SnapshotExportException("The Evaluation dimension collection is null."),
            new EvaluationProvenanceRecord(
                new EvaluationFormulaDefinition(
                    provenance.Formula.ContractVersion,
                    provenance.Formula.FormulaId,
                    provenance.Formula.FormulaVersion,
                    provenance.Formula.DimensionWeights?.Select(item =>
                            new EvaluationDimensionWeight(item.Dimension, item.WeightBasisPoints))
                        .ToArray()
                        ?? throw new SnapshotExportException("The Evaluation formula dimensions are null."),
                    provenance.Formula.SourceWeights?.Select(item =>
                            new EvaluationSourceWeight(item.Source, item.WeightBasisPoints))
                        .ToArray()
                        ?? throw new SnapshotExportException("The Evaluation formula sources are null."),
                    provenance.Formula.FormulaSha256),
                new EvaluationInputSnapshot(
                    provenance.InputSnapshot.ContractVersion,
                    provenance.InputSnapshot.EvaluationId,
                    provenance.InputSnapshot.TaskId,
                    provenance.InputSnapshot.AgentId,
                    provenance.InputSnapshot.Dimensions?.Select(ToEvaluationDimensionInput).ToArray()
                        ?? throw new SnapshotExportException("The Evaluation input dimensions are null.")),
                provenance.FormulaSha256,
                provenance.InputSnapshotSha256),
            value.ResultSha256);
    }

    private static EvaluationInputIssue ToEvaluationIssue(EvaluationInputIssueExport value) =>
        value is null
            ? throw new SnapshotExportException("The Evaluation issue collection contains a null record.")
            : new EvaluationInputIssue(value.Dimension, value.Source, value.Code, value.Message);

    private static EvaluationDimensionScore ToEvaluationDimension(
        EvaluationDimensionScoreExport value)
    {
        if (value is null)
        {
            throw new SnapshotExportException("The Evaluation dimension collection contains a null record.");
        }

        return new EvaluationDimensionScore(
            value.Dimension,
            value.WeightBasisPoints,
            value.Status,
            value.ObservedInputs?.Select(ToEvaluationDimensionInput).ToArray()
                ?? throw new SnapshotExportException("The Evaluation observed input collection is null."),
            ToEvaluationScoreInput(value.Leader),
            ToEvaluationScoreInput(value.ProjectManager),
            ToEvaluationScoreInput(value.ObjectiveEvidence),
            value.DimensionScore,
            value.WeightedScore,
            value.Issues?.Select(ToEvaluationIssue).ToArray()
                ?? throw new SnapshotExportException("The Evaluation dimension issue collection is null."));
    }

    private static EvaluationDimensionInput ToEvaluationDimensionInput(
        EvaluationDimensionInputExport value) =>
        value is null
            ? throw new SnapshotExportException("The Evaluation input collection contains a null record.")
            : new EvaluationDimensionInput(
                value.Dimension,
                ToEvaluationScoreInput(value.Leader),
                ToEvaluationScoreInput(value.ProjectManager),
                ToEvaluationScoreInput(value.ObjectiveEvidence));

    private static EvaluationScoreInput ToEvaluationScoreInput(
        EvaluationScoreInputExport? value) =>
        value is null
            ? throw new SnapshotExportException("The Evaluation score input is null.")
            : new EvaluationScoreInput(value.Score, value.ProvenanceId, value.EvidenceIdentitySha256);

    private static DailySummarySnapshot ToDailySummarySnapshot(
        DailySummarySnapshotExportDocument document)
    {
        if (document.AcceptedSnapshot is null)
        {
            throw new SnapshotExportException("The Daily Summary export snapshot is incomplete.");
        }

        var value = document.AcceptedSnapshot;
        if (!DateOnly.TryParseExact(
                value.LocalDate,
                "yyyy-MM-dd",
                CultureInfo.InvariantCulture,
                DateTimeStyles.None,
                out var localDate))
        {
            throw new SnapshotExportException("The Daily Summary local date is invalid.");
        }

        return new DailySummarySnapshot(
            value.ContractVersion,
            value.AggregatorId,
            localDate,
            value.TimeZoneId,
            value.SourceSetSha256,
            value.AcceptedSources?.Select(item => item is null
                    ? throw new SnapshotExportException("The Daily Summary source collection contains a null record.")
                    : new DailySummarySourceReference(item.SourceId, item.Kind, item.SourceHashSha256))
                .ToArray()
                ?? throw new SnapshotExportException("The Daily Summary source collection is null."),
            value.Metrics?.Select(item => item is null
                    ? throw new SnapshotExportException("The Daily Summary metric collection contains a null record.")
                    : new DailySummaryMetric(item.MetricId, item.Value, item.SourceIds))
                .ToArray()
                ?? throw new SnapshotExportException("The Daily Summary metric collection is null."),
            value.Workstreams?.Select(item => item is null
                    ? throw new SnapshotExportException("The Daily Summary workstream collection contains a null record.")
                    : new DailySummaryWorkstream(
                        item.Workstream,
                        item.AcceptedSourceCount,
                        item.ActivityCount,
                        item.EvidenceCount,
                        item.SourceIds))
                .ToArray()
                ?? throw new SnapshotExportException("The Daily Summary workstream collection is null."),
            value.Highlights?.Select(item => item is null
                    ? throw new SnapshotExportException("The Daily Summary highlight collection contains a null record.")
                    : new DailySummaryHighlight(item.SourceId, item.Workstream, item.Summary, item.SourceIds))
                .ToArray()
                ?? throw new SnapshotExportException("The Daily Summary highlight collection is null."),
            value.RepeatedIssues?.Select(item => item is null
                    ? throw new SnapshotExportException("The Daily Summary issue collection contains a null record.")
                    : new DailySummaryRepeatedIssue(
                        item.IssueKey,
                        item.OccurrenceCount,
                        item.Workstream,
                        item.Description,
                        item.SourceIds))
                .ToArray()
                ?? throw new SnapshotExportException("The Daily Summary issue collection is null."),
            value.RecommendedActions?.Select(item => item is null
                    ? throw new SnapshotExportException("The Daily Summary action collection contains a null record.")
                    : new DailySummaryRecommendedAction(item.ActionKey, item.Description, item.SourceIds))
                .ToArray()
                ?? throw new SnapshotExportException("The Daily Summary action collection is null."),
            value.Timeline?.Select(item => ToDailyTimelineEntry(item, localDate)).ToArray()
                ?? throw new SnapshotExportException("The Daily Summary timeline collection is null."),
            value.ResultSha256);
    }

    private static DailySummaryTimelineEntry ToDailyTimelineEntry(
        DailySummaryTimelineEntryExport value,
        DateOnly localDate)
    {
        if (value is null ||
            !DateTimeOffset.TryParseExact(
                value.OccurredLocal,
                "O",
                CultureInfo.InvariantCulture,
                DateTimeStyles.RoundtripKind,
                out var occurredLocal))
        {
            throw new SnapshotExportException("The Daily Summary timeline timestamp is invalid.");
        }

        if (occurredLocal.Date != localDate.ToDateTime(TimeOnly.MinValue).Date)
        {
            throw new SnapshotExportException("The Daily Summary timeline timestamp is outside its local day.");
        }

        return new DailySummaryTimelineEntry(
            value.SourceId,
            value.Kind,
            occurredLocal,
            value.Workstream,
            value.Category,
            value.Summary,
            value.SourceHashSha256);
    }

    private static void ValidateDailySummarySource(
        DailySummaryExportSource? source,
        DailySummarySnapshot snapshot)
    {
        if (source is null ||
            source.ContractVersion != snapshot.ContractVersion ||
            !string.Equals(source.AggregatorId, snapshot.AggregatorId, StringComparison.Ordinal) ||
            !string.Equals(source.LocalDate, snapshot.LocalDate.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture), StringComparison.Ordinal) ||
            !string.Equals(source.TimeZoneId, snapshot.TimeZoneId, StringComparison.Ordinal) ||
            !ShaEqual(source.SourceSetSha256, snapshot.SourceSetSha256) ||
            !ShaEqual(source.ResultSha256, snapshot.ResultSha256))
        {
            throw new SnapshotExportException(
                "The Daily Summary source metadata does not match its accepted snapshot.");
        }

        if (source.SourceIdentities is null ||
            source.SourceIdentities.Count != snapshot.AcceptedSources.Count ||
            source.SourceIdentities.Any(item => item is null) ||
            !source.SourceIdentities.Select(item => item.SourceId)
                .SequenceEqual(snapshot.AcceptedSources.Select(item => item.SourceId), StringComparer.Ordinal))
        {
            throw new SnapshotExportException(
                "The Daily Summary source identities do not match its accepted sources.");
        }

        for (var index = 0; index < snapshot.AcceptedSources.Count; index++)
        {
            var expected = snapshot.AcceptedSources[index];
            var actual = source.SourceIdentities[index];
            if (!string.Equals(actual.SourceId, expected.SourceId, StringComparison.Ordinal) ||
                actual.Kind != expected.Kind ||
                !string.Equals(actual.SourceHashSha256, expected.SourceHashSha256, StringComparison.Ordinal))
            {
                throw new SnapshotExportException(
                    "The Daily Summary source identity is not bound to its accepted source.");
            }
        }

        var expectedLocalStart = snapshot.LocalDate.ToDateTime(TimeOnly.MinValue);
        var expectedLocalEnd = expectedLocalStart.AddDays(1);
        if (!DateTime.TryParseExact(
                source.LocalDayStart,
                "yyyy-MM-dd'T'HH:mm:ss.fffffff",
                CultureInfo.InvariantCulture,
                DateTimeStyles.None,
                out var localStart) ||
            !DateTime.TryParseExact(
                source.LocalDayEndExclusive,
                "yyyy-MM-dd'T'HH:mm:ss.fffffff",
                CultureInfo.InvariantCulture,
                DateTimeStyles.None,
                out var localEnd) ||
            localStart != expectedLocalStart ||
            localEnd != expectedLocalEnd ||
            !DateTimeOffset.TryParseExact(
                source.UtcDayStart,
                "yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'",
                CultureInfo.InvariantCulture,
                DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal,
                out var utcStart) ||
            !DateTimeOffset.TryParseExact(
                source.UtcDayEndExclusive,
                "yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'",
                CultureInfo.InvariantCulture,
                DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal,
                out var utcEnd) ||
            !string.Equals(FormatUtc(utcStart), source.UtcDayStart, StringComparison.Ordinal) ||
            !string.Equals(FormatUtc(utcEnd), source.UtcDayEndExclusive, StringComparison.Ordinal) ||
            utcEnd <= utcStart)
        {
            throw new SnapshotExportException(
                "The Daily Summary local-day boundaries are invalid or not canonical.");
        }

        ValidateLocalUtcBoundary(localStart, utcStart, "start");
        ValidateLocalUtcBoundary(localEnd, utcEnd, "end");
    }

    private static void ValidateDailySummarySnapshot(DailySummarySnapshot snapshot)
    {
        try
        {
            _ = DailySummaryAggregator.Validate(snapshot);
        }
        catch (DailySummaryAggregationException exception)
        {
            throw new SnapshotExportException(
                "The Daily Summary export snapshot is not an accepted deterministic result.",
                exception);
        }

        EnsureExportReferenceIds(
            snapshot.AcceptedSources.Select(item => item.SourceId).ToArray(),
            "Daily Summary accepted source IDs",
            requireSorted: false);
        foreach (var metric in snapshot.Metrics)
        {
            EnsureExportReferenceIds(metric.SourceIds, "Daily Summary metric references");
        }

        foreach (var workstream in snapshot.Workstreams)
        {
            EnsureExportReferenceIds(workstream.SourceIds, "Daily Summary workstream references");
        }

        foreach (var highlight in snapshot.Highlights)
        {
            EnsureExportReferenceIds(highlight.SourceIds, "Daily Summary highlight references");
        }

        foreach (var issue in snapshot.RepeatedIssues)
        {
            EnsureExportReferenceIds(issue.SourceIds, "Daily Summary repeated-issue references");
            if (issue.OccurrenceCount < 2)
            {
                throw new SnapshotExportException(
                    "Daily Summary repeated issues must have at least two occurrences.");
            }
        }

        foreach (var action in snapshot.RecommendedActions)
        {
            EnsureExportReferenceIds(action.SourceIds, "Daily Summary recommended-action references");
        }
    }

    private static void EnsureExportReferenceIds(
        IReadOnlyList<string> ids,
        string label,
        bool requireSorted = true)
    {
        if (ids is null ||
            ids.Count > DeterministicSnapshotExporter.MaximumReferenceItems ||
            ids.Any(string.IsNullOrWhiteSpace) ||
            ids.Any(item => item.Length > DeterministicSnapshotExporter.MaximumIdentifierLength) ||
            ids.Distinct(StringComparer.Ordinal).Count() != ids.Count ||
            requireSorted &&
            !ids.SequenceEqual(ids.OrderBy(item => item, StringComparer.Ordinal), StringComparer.Ordinal))
        {
            throw new SnapshotExportException(
                $"The export field {label} exceeds reference bounds or contains duplicates.");
        }
    }

    private static void ValidateLocalUtcBoundary(
        DateTime local,
        DateTimeOffset utc,
        string label)
    {
        var offset = local - utc.UtcDateTime;
        if (offset.Duration() > TimeSpan.FromHours(14) ||
            offset.Ticks % TimeSpan.TicksPerMinute != 0)
        {
            throw new SnapshotExportException(
                $"The Daily Summary {label} boundary has an invalid time-zone offset.");
        }

        try
        {
            var reconstructed = new DateTimeOffset(local, offset).ToUniversalTime();
            if (reconstructed != utc)
            {
                throw new SnapshotExportException(
                    $"The Daily Summary {label} boundary is not UTC-consistent.");
            }
        }
        catch (ArgumentException exception)
        {
            throw new SnapshotExportException(
                $"The Daily Summary {label} boundary has an invalid time-zone offset.",
                exception);
        }
    }

    private static void EnsureCanonicalJson<T>(T document, string json)
    {
        var canonical = JsonSerializer.Serialize(document, ValidationJsonOptions)
            .Replace("\r\n", "\n", StringComparison.Ordinal)
            .Replace('\r', '\n');
        if (!string.Equals(canonical, json, StringComparison.Ordinal))
        {
            throw new SnapshotExportException(
                "The local export JSON is not the canonical contract document.");
        }
    }

    private static void EnsureCanonicalEnvelope(
        DeterministicSnapshotExport actual,
        DeterministicSnapshotExport expected)
    {
        if (!string.Equals(actual.Json, expected.Json, StringComparison.Ordinal) ||
            !string.Equals(actual.Markdown, expected.Markdown, StringComparison.Ordinal) ||
            !string.Equals(actual.Csv, expected.Csv, StringComparison.Ordinal) ||
            !string.Equals(actual.Encoding, expected.Encoding, StringComparison.Ordinal) ||
            !ShaEqual(actual.JsonSha256, expected.JsonSha256) ||
            !ShaEqual(actual.MarkdownSha256, expected.MarkdownSha256) ||
            !ShaEqual(actual.CsvSha256, expected.CsvSha256) ||
            !ShaEqual(actual.ExportId, expected.ExportId) ||
            !ShaEqual(actual.SourceSnapshotSha256, expected.SourceSnapshotSha256) ||
            !ManifestEqual(actual.Manifest, expected.Manifest))
        {
            throw new SnapshotExportException(
                "The local export reports or manifest do not match the validated snapshot envelope.");
        }
    }

    private static bool ManifestEqual(
        SnapshotExportManifest actual,
        SnapshotExportManifest expected) =>
        actual.ContractVersion == expected.ContractVersion &&
        actual.Kind == expected.Kind &&
        ShaEqual(actual.ExportId, expected.ExportId) &&
        ShaEqual(actual.SourceSnapshotSha256, expected.SourceSnapshotSha256) &&
        ShaEqual(actual.JsonSha256, expected.JsonSha256) &&
        ShaEqual(actual.MarkdownSha256, expected.MarkdownSha256) &&
        ShaEqual(actual.CsvSha256, expected.CsvSha256) &&
        actual.JsonByteLength == expected.JsonByteLength &&
        actual.MarkdownByteLength == expected.MarkdownByteLength &&
        actual.CsvByteLength == expected.CsvByteLength &&
        actual.TotalByteLength == expected.TotalByteLength;

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
                    (SensitivePropertyPattern.IsMatch(path) ||
                     FileSystemPathPattern.IsMatch(value) ||
                     SecretOrTokenPattern.IsMatch(value)))
                {
                    throw new SnapshotExportException(
                        $"Export rejected by the fail-closed redaction policy at {path}.");
                }

                break;
        }
    }

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
        if (nodeCount > DeterministicSnapshotExporter.MaximumSerializedNodes)
        {
            throw new SnapshotExportException(
                $"The export exceeds the maximum serialized node count of {DeterministicSnapshotExporter.MaximumSerializedNodes}.");
        }

        switch (element.ValueKind)
        {
            case JsonValueKind.Object:
                var properties = element.EnumerateObject().ToArray();
                if (properties.Length > DeterministicSnapshotExporter.MaximumObjectProperties)
                {
                    throw new SnapshotExportException(
                        $"The export exceeds the maximum object property count of {DeterministicSnapshotExporter.MaximumObjectProperties}.");
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
                if (element.GetArrayLength() > DeterministicSnapshotExporter.MaximumCollectionItems)
                {
                    throw new SnapshotExportException(
                        $"The export exceeds the maximum collection cardinality of {DeterministicSnapshotExporter.MaximumCollectionItems}.");
                }

                if (IsReferencePath(path))
                {
                    if (element.GetArrayLength() > DeterministicSnapshotExporter.MaximumReferenceItems)
                    {
                        throw new SnapshotExportException(
                            $"The export exceeds the maximum reference cardinality of {DeterministicSnapshotExporter.MaximumReferenceItems}.");
                    }

                    referenceCount += element.GetArrayLength();
                    if (referenceCount > DeterministicSnapshotExporter.MaximumTotalReferenceItems)
                    {
                        throw new SnapshotExportException(
                            $"The export exceeds the maximum total reference cardinality of {DeterministicSnapshotExporter.MaximumTotalReferenceItems}.");
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
                if (value is not null &&
                    (value.Length > DeterministicSnapshotExporter.MaximumTextLength ||
                     StrictUtf8.GetByteCount(value) > DeterministicSnapshotExporter.MaximumTextBytes))
                {
                    throw new SnapshotExportException(
                        $"The export exceeds the maximum text bound of {DeterministicSnapshotExporter.MaximumTextLength} characters or {DeterministicSnapshotExporter.MaximumTextBytes} UTF-8 bytes.");
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

    private static string BuildCanonicalMarkdown(
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
        return builder.ToString()
            .Replace("\r\n", "\n", StringComparison.Ordinal)
            .Replace('\r', '\n');
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

    private static string FormatMarkdownScalar(JsonElement element) =>
        element.ValueKind == JsonValueKind.String
            ? $"`{(element.GetString() ?? string.Empty).Replace("`", "'", StringComparison.Ordinal).Replace('\n', ' ').Replace('\r', ' ')}`"
            : element.ValueKind == JsonValueKind.Null
                ? "null"
                : element.GetRawText();

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

    private static string BuildCanonicalCsv(JsonElement root)
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

    private static string PrepareDestination(string requestedDestination)
    {
        ValidateDestinationSyntax(requestedDestination);
        string destination;
        try
        {
            destination = Path.GetFullPath(requestedDestination);
        }
        catch (Exception exception) when (IsPathException(exception))
        {
            throw new SnapshotExportException(
                "The local export destination is not a valid local filesystem path.",
                exception);
        }

        ValidateLocalRoot(destination);
        try
        {
            EnsureNoReparsePointsInPath(destination);
            Directory.CreateDirectory(destination);
            EnsureNoReparsePointsInPath(destination);
        }
        catch (SnapshotExportException)
        {
            throw;
        }
        catch (Exception exception) when (IsPathException(exception))
        {
            throw new SnapshotExportException(
                "The local export destination could not be prepared.",
                exception);
        }

        return destination;
    }

    private static void ValidateDestinationSyntax(string path)
    {
        if (!Path.IsPathFullyQualified(path) ||
            path.Any(char.IsControl) ||
            ContainsDotOrParentSegment(path) ||
            IsNetworkOrDevicePath(path) ||
            ContainsAlternateDataStream(path) ||
            ContainsReservedDeviceName(path))
        {
            throw new SnapshotExportException(
                "The export destination must be a fully qualified local filesystem path without dot, parent, network, device, or reserved-device components.");
        }
    }

    private static void ValidateLocalRoot(string destination)
    {
        var root = Path.GetPathRoot(destination);
        if (string.IsNullOrWhiteSpace(root))
        {
            throw new SnapshotExportException("The local export destination has no filesystem root.");
        }

        var trimmedDestination = destination.TrimEnd(
            Path.DirectorySeparatorChar,
            Path.AltDirectorySeparatorChar);
        var trimmedRoot = root.TrimEnd(
            Path.DirectorySeparatorChar,
            Path.AltDirectorySeparatorChar);
        if (string.Equals(trimmedDestination, trimmedRoot, StringComparison.OrdinalIgnoreCase))
        {
            throw new SnapshotExportException("The local export destination cannot be a filesystem root.");
        }

        try
        {
            var drive = new DriveInfo(root);
            if (drive.DriveType is DriveType.Network or DriveType.NoRootDirectory or DriveType.Unknown)
            {
                throw new SnapshotExportException(
                    "The export destination must resolve to a local filesystem drive.");
            }
        }
        catch (SnapshotExportException)
        {
            throw;
        }
        catch (Exception exception) when (IsPathException(exception))
        {
            throw new SnapshotExportException(
                "The export destination drive could not be verified as local.",
                exception);
        }
    }

    private static bool ContainsDotOrParentSegment(string path) =>
        path.Replace('/', '\\')
            .Split('\\', StringSplitOptions.None)
            .Any(segment => segment is "." or "..");

    private static bool IsNetworkOrDevicePath(string path)
    {
        var normalized = path.Replace('/', '\\');
        return path.StartsWith("\\\\", StringComparison.Ordinal) ||
            path.StartsWith("//", StringComparison.Ordinal) ||
            normalized.StartsWith("\\??\\", StringComparison.OrdinalIgnoreCase) ||
            normalized.StartsWith("\\Device\\", StringComparison.OrdinalIgnoreCase) ||
            normalized.StartsWith("\\DosDevices\\", StringComparison.OrdinalIgnoreCase) ||
            normalized.StartsWith("\\GLOBALROOT\\", StringComparison.OrdinalIgnoreCase) ||
            normalized.StartsWith("\\GLOBAL??\\", StringComparison.OrdinalIgnoreCase) ||
            normalized.StartsWith("\\Sessions\\", StringComparison.OrdinalIgnoreCase) ||
            normalized.StartsWith("\\DeviceMap\\", StringComparison.OrdinalIgnoreCase) ||
            normalized.Contains("\\Device\\", StringComparison.OrdinalIgnoreCase) ||
            normalized.Contains("\\DosDevices\\", StringComparison.OrdinalIgnoreCase);
    }

    private static bool ContainsAlternateDataStream(string path)
    {
        var start = path.Length >= 2 && path[1] == ':' ? 2 : 0;
        return path[start..].Contains(':', StringComparison.Ordinal);
    }

    private static bool ContainsReservedDeviceName(string path)
    {
        var segments = path.Replace('/', '\\')
            .Split('\\', StringSplitOptions.RemoveEmptyEntries);
        foreach (var segment in segments)
        {
            var normalized = segment.TrimEnd(' ', '.');
            var name = normalized.Split('.', 2, StringSplitOptions.None)[0];
            if (name.Equals("CON", StringComparison.OrdinalIgnoreCase) ||
                name.Equals("PRN", StringComparison.OrdinalIgnoreCase) ||
                name.Equals("AUX", StringComparison.OrdinalIgnoreCase) ||
                name.Equals("NUL", StringComparison.OrdinalIgnoreCase) ||
                name.Equals("CLOCK$", StringComparison.OrdinalIgnoreCase) ||
                (name.Length == 4 &&
                 (name.StartsWith("COM", StringComparison.OrdinalIgnoreCase) ||
                  name.StartsWith("LPT", StringComparison.OrdinalIgnoreCase)) &&
                 name[3] is >= '1' and <= '9'))
            {
                return true;
            }
        }

        return false;
    }

    private static void EnsurePathIsAvailable(string path, string collisionMessage)
    {
        EnsureNoReparsePointsInPath(path);
        if (TryGetFileAttributes(path, out _))
        {
            throw new SnapshotExportException(collisionMessage);
        }
    }

    private static void EnsureNoReparsePointsInPath(string path)
    {
        string fullPath;
        try
        {
            fullPath = Path.GetFullPath(path);
        }
        catch (Exception exception) when (IsPathException(exception))
        {
            throw new SnapshotExportException(
                "The local export path could not be resolved.",
                exception);
        }

        var root = Path.GetPathRoot(fullPath);
        if (string.IsNullOrWhiteSpace(root))
        {
            throw new SnapshotExportException("The local export path has no filesystem root.");
        }

        var current = root;
        if (TryGetFileAttributes(current, out var rootAttributes) &&
            rootAttributes.HasFlag(FileAttributes.ReparsePoint))
        {
            throw new SnapshotExportException(
                "The local export path contains an existing reparse-point ancestor.");
        }

        var segments = fullPath[root.Length..]
            .Split(['\\', '/'], StringSplitOptions.RemoveEmptyEntries);
        for (var index = 0; index < segments.Length; index++)
        {
            current = Path.Combine(current, segments[index]);
            if (!TryGetFileAttributes(current, out var attributes))
            {
                return;
            }

            if (attributes.HasFlag(FileAttributes.ReparsePoint))
            {
                throw new SnapshotExportException(
                    "The local export path contains an existing reparse-point ancestor or destination.");
            }

            if (index < segments.Length - 1 &&
                !attributes.HasFlag(FileAttributes.Directory))
            {
                throw new SnapshotExportException(
                    "The local export path contains a non-directory ancestor.");
            }
        }
    }

    private static bool TryGetFileAttributes(string path, out FileAttributes attributes)
    {
        try
        {
            attributes = File.GetAttributes(path);
            return true;
        }
        catch (Exception exception) when (
            exception is FileNotFoundException or DirectoryNotFoundException)
        {
            attributes = default;
            return false;
        }
        catch (Exception exception) when (IsPathException(exception))
        {
            throw new SnapshotExportException(
                "The local export path could not be inspected safely.",
                exception);
        }
    }

    private static void WriteUtf8(string path, string content, bool expectCrLf)
    {
        var bytes = GetStrictUtf8Bytes(content, Path.GetFileName(path));
        EnsureNoUtf8Bom(bytes, Path.GetFileName(path));
        if (!expectCrLf && content.Contains('\r'))
        {
            throw new SnapshotExportException("The local export contains an invalid newline sequence.");
        }

        if (expectCrLf)
        {
            EnsureCrLfOnly(content, Path.GetFileName(path));
        }

        using var stream = new FileStream(
            path,
            FileMode.CreateNew,
            FileAccess.Write,
            FileShare.None,
            bufferSize: 64 * 1024,
            FileOptions.SequentialScan | FileOptions.WriteThrough);
        stream.Write(bytes);
        stream.Flush(flushToDisk: true);
    }

    private static void ValidateStagedFiles(
        DeterministicSnapshotExport export,
        string jsonPath,
        string markdownPath,
        string csvPath,
        string manifestPath)
    {
        var json = ReadStrictUtf8File(jsonPath);
        var markdown = ReadStrictUtf8File(markdownPath);
        var csv = ReadStrictUtf8File(csvPath);
        var manifest = ReadStrictUtf8File(manifestPath);
        var expectedManifest = DeterministicSnapshotExporter.SerializeManifest(export.Manifest);
        if (!string.Equals(json.Text, export.Json, StringComparison.Ordinal) ||
            !string.Equals(markdown.Text, export.Markdown, StringComparison.Ordinal) ||
            !string.Equals(csv.Text, export.Csv, StringComparison.Ordinal) ||
            !string.Equals(manifest.Text, expectedManifest, StringComparison.Ordinal) ||
            !ShaEqual(Sha256(json.Bytes), export.JsonSha256) ||
            !ShaEqual(Sha256(markdown.Bytes), export.MarkdownSha256) ||
            !ShaEqual(Sha256(csv.Bytes), export.CsvSha256))
        {
            throw new SnapshotExportException(
                "The staged local export failed strict UTF-8 reread and hash validation.");
        }
    }

    private static (byte[] Bytes, string Text) ReadStrictUtf8File(string path)
    {
        EnsureNoReparsePointsInPath(path);
        byte[] bytes;
        try
        {
            bytes = File.ReadAllBytes(path);
        }
        catch (Exception exception) when (IsPathException(exception))
        {
            throw new SnapshotExportException(
                "The staged local export could not be reread.",
                exception);
        }

        EnsureNoReparsePointsInPath(path);
        EnsureNoUtf8Bom(bytes, Path.GetFileName(path));
        try
        {
            return (bytes, StrictUtf8.GetString(bytes));
        }
        catch (DecoderFallbackException exception)
        {
            throw new SnapshotExportException(
                "The staged local export contains invalid UTF-8.",
                exception);
        }
    }

    private static byte[] GetStrictUtf8Bytes(string? value, string label)
    {
        if (value is null)
        {
            throw new SnapshotExportException($"The local export {label} is required.");
        }

        try
        {
            return StrictUtf8.GetBytes(value);
        }
        catch (EncoderFallbackException exception)
        {
            throw new SnapshotExportException(
                $"The local export {label} contains an invalid UTF-16 surrogate.",
                exception);
        }
    }

    private static void EnsureNoUtf8Bom(byte[] bytes, string label)
    {
        if (bytes.Length >= 3 &&
            bytes[0] == 0xEF &&
            bytes[1] == 0xBB &&
            bytes[2] == 0xBF)
        {
            throw new SnapshotExportException($"The local export {label} must not contain a UTF-8 BOM.");
        }
    }

    private static void EnsureCrLfOnly(string value, string label)
    {
        if (!value.EndsWith("\r\n", StringComparison.Ordinal))
        {
            throw new SnapshotExportException($"The local export {label} must end with CRLF.");
        }

        for (var index = 0; index < value.Length; index++)
        {
            if (value[index] == '\r' &&
                (index + 1 >= value.Length || value[index + 1] != '\n'))
            {
                throw new SnapshotExportException($"The local export {label} contains a lone CR.");
            }

            if (value[index] == '\n' &&
                (index == 0 || value[index - 1] != '\r'))
            {
                throw new SnapshotExportException($"The local export {label} contains a lone LF.");
            }
        }
    }

    private static bool IsPathException(Exception exception) =>
        exception is ArgumentException or
            IOException or
            UnauthorizedAccessException or
            NotSupportedException or
            SecurityException;

    private static bool IsSha256(string? value) =>
        value is { Length: 64 } && value.All(IsHexCharacter);

    private static bool ShaEqual(string? left, string? right) =>
        left is not null &&
        right is not null &&
        string.Equals(left, right, StringComparison.OrdinalIgnoreCase);

    private static bool IsHexCharacter(char value) =>
        value is >= '0' and <= '9' or
            >= 'A' and <= 'F' or
            >= 'a' and <= 'f';

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
        return Sha256(GetStrictUtf8Bytes(identity, "export identity"));
    }

    private static string FormatUtc(DateTimeOffset value) =>
        value.ToUniversalTime().ToString(
            "yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'",
            CultureInfo.InvariantCulture);

    private static string Sha256(byte[] bytes) =>
        Convert.ToHexString(SHA256.HashData(bytes));
}
