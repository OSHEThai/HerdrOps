using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using HerdrOps.Domain.Evaluation;
using HerdrOps.Domain.Exports;
using HerdrOps.Domain.Summaries;

namespace HerdrOps.UnitTests;

[TestClass]
public sealed class DeterministicSnapshotExporterTests
{
    private static readonly DateTimeOffset GenerationUtc =
        new(2026, 8, 16, 0, 0, 0, TimeSpan.Zero);

    [TestMethod]
    public void EvaluationExportIsDeterministicAndReconcilesToAcceptedResult()
    {
        var manifest = ReadExportManifest();
        var fixture = ReadScoringFixture();
        var accepted = new EvaluationScoringEngine().Calculate(
            fixture.Input,
            EvaluationFormulaCatalog.Version1);

        var first = DeterministicSnapshotExporter.ExportEvaluation(accepted, GenerationUtc);
        var second = DeterministicSnapshotExporter.ExportEvaluation(accepted, GenerationUtc);

        Assert.AreEqual(first.Json, second.Json);
        Assert.AreEqual(first.Markdown, second.Markdown);
        Assert.AreEqual(first.Csv, second.Csv);
        Assert.AreEqual(manifest.EvaluationJsonSha256, first.JsonSha256);
        Assert.AreEqual(manifest.EvaluationMarkdownSha256, first.MarkdownSha256);
        Assert.AreEqual(manifest.EvaluationCsvSha256, first.CsvSha256);
        Assert.AreEqual(manifest.EvaluationExportId, first.ExportId);
        Assert.AreEqual(manifest.EvaluationSourceSnapshotSha256, first.SourceSnapshotSha256);
        Assert.AreEqual(accepted.Provenance.InputSnapshotSha256, first.SourceSnapshotSha256);
        Assert.AreEqual(first.ExportId, first.Manifest.ExportId);
        Assert.AreEqual(first.SourceSnapshotSha256, first.Manifest.SourceSnapshotSha256);
        Assert.AreEqual(first.JsonSha256, Sha256(first.Json));
        Assert.AreEqual(first.MarkdownSha256, Sha256(first.Markdown));
        Assert.AreEqual(first.CsvSha256, Sha256(first.Csv));
        Assert.AreEqual(first.Manifest.TotalByteLength, Encoding.UTF8.GetByteCount(first.Json) +
            Encoding.UTF8.GetByteCount(first.Markdown) +
            Encoding.UTF8.GetByteCount(first.Csv));
        StringAssert.Contains(first.Json, "HERDROPS-EVALUATION-V1");
        StringAssert.Contains(first.Json, accepted.ResultSha256);
        StringAssert.Contains(first.Markdown, "# HerdrOps Snapshot Export");
        StringAssert.Contains(first.Markdown, first.ExportId);
        StringAssert.Contains(first.Csv, "$.acceptedSnapshot.dimensions[0].weightedScore");

        using var document = JsonDocument.Parse(first.Json);
        var root = document.RootElement;
        Assert.AreEqual("evaluation-score-result", root.GetProperty("metadata").GetProperty("exportKind").GetString());
        Assert.AreEqual(manifest.GenerationUtc, root.GetProperty("metadata").GetProperty("generatedUtc").GetString());
        Assert.AreEqual(manifest.Encoding, first.Encoding);
        Assert.AreEqual(first.ExportId, root.GetProperty("metadata").GetProperty("exportId").GetString());
        Assert.AreEqual(
            first.SourceSnapshotSha256,
            root.GetProperty("metadata").GetProperty("sourceSnapshotSha256").GetString());
        Assert.AreEqual(manifest.RedactionPolicyId, root
            .GetProperty("metadata")
            .GetProperty("redactionPolicy")
            .GetProperty("policyId")
            .GetString());
        Assert.AreEqual(accepted.TotalScore, root
            .GetProperty("acceptedSnapshot")
            .GetProperty("totalScore")
            .GetDecimal());
        Assert.AreEqual(accepted.ResultSha256, root
            .GetProperty("source")
            .GetProperty("resultSha256")
            .GetString());
        Assert.HasCount(18, root
            .GetProperty("source")
            .GetProperty("sourceIdentities")
            .EnumerateArray());
    }

    [TestMethod]
    public void EvaluationExportRejectsTamperedTopLevelSourceFields()
    {
        var fixture = ReadScoringFixture();
        var accepted = new EvaluationScoringEngine().Calculate(
            fixture.Input,
            EvaluationFormulaCatalog.Version1);
        var firstDimension = accepted.Dimensions[0];
        var tamperedResults = new[]
        {
            accepted with
            {
                Dimensions = accepted.Dimensions
                    .Select(item => item.Dimension == firstDimension.Dimension
                        ? item with { Leader = item.Leader with { Score = item.Leader.Score + 1 } }
                        : item)
                    .ToArray(),
            },
            accepted with
            {
                Dimensions = accepted.Dimensions
                    .Select(item => item.Dimension == firstDimension.Dimension
                        ? item with
                        {
                            ProjectManager = item.ProjectManager with
                            {
                                ProvenanceId = $"{item.ProjectManager.ProvenanceId}-tampered",
                            },
                        }
                        : item)
                    .ToArray(),
            },
            accepted with
            {
                Dimensions = accepted.Dimensions
                    .Select(item => item.Dimension == firstDimension.Dimension
                        ? item with
                        {
                            ObjectiveEvidence = item.ObjectiveEvidence with
                            {
                                EvidenceIdentitySha256 = new string('0', 64),
                            },
                        }
                        : item)
                    .ToArray(),
            },
        };

        foreach (var tampered in tamperedResults)
        {
            Assert.ThrowsExactly<SnapshotExportException>(() =>
                DeterministicSnapshotExporter.ExportEvaluation(tampered, GenerationUtc));
        }
    }

    [TestMethod]
    public void DailySummaryExportIncludesUtcBoundariesAndAcceptedSourceIdentities()
    {
        var fixture = ReadDailySummaryFixture();
        var timeZone = CreateFixedOffsetTimeZone(fixture.TimeZoneOffsetMinutes);
        var accepted = DailySummaryAggregator.Aggregate(
            fixture.LocalDate,
            timeZone,
            fixture.Sources);

        var export = DeterministicSnapshotExporter.ExportDailySummary(
            accepted,
            timeZone,
            GenerationUtc);

        var manifest = ReadExportManifest();
        var expectedIdentity =
            $"json={manifest.DailyJsonSha256}; markdown={manifest.DailyMarkdownSha256}; " +
            $"csv={manifest.DailyCsvSha256}; exportId={manifest.DailyExportId}; " +
            $"sourceSnapshot={manifest.DailySourceSnapshotSha256}";
        var observedIdentity =
            $"json={export.JsonSha256}; markdown={export.MarkdownSha256}; " +
            $"csv={export.CsvSha256}; exportId={export.ExportId}; " +
            $"sourceSnapshot={export.SourceSnapshotSha256}";
        Assert.AreEqual(
            expectedIdentity,
            observedIdentity,
            $"Observed deterministic Daily Summary export identity: {observedIdentity}");
        Assert.AreEqual(accepted.SourceSetSha256, export.SourceSnapshotSha256);
        Assert.AreEqual(export.ExportId, export.Manifest.ExportId);
        Assert.AreEqual(export.JsonSha256, Sha256(export.Json));
        Assert.AreEqual(export.MarkdownSha256, Sha256(export.Markdown));
        Assert.AreEqual(export.CsvSha256, Sha256(export.Csv));
        StringAssert.Contains(export.Markdown, "## Source");
        StringAssert.Contains(export.Json, "2026-08-14T17:00:00.0000000Z");
        StringAssert.Contains(export.Json, "2026-08-15T17:00:00.0000000Z");
        StringAssert.Contains(export.Csv, "$.acceptedSnapshot.acceptedSources[0].sourceId");

        using var document = JsonDocument.Parse(export.Json);
        var root = document.RootElement;
        var source = root.GetProperty("source");
        Assert.AreEqual("fixture-utc-420", source.GetProperty("timeZoneId").GetString());
        Assert.AreEqual("2026-08-14T17:00:00.0000000Z", source.GetProperty("utcDayStart").GetString());
        Assert.AreEqual("2026-08-15T17:00:00.0000000Z", source.GetProperty("utcDayEndExclusive").GetString());
        Assert.AreEqual(accepted.ResultSha256, root
            .GetProperty("acceptedSnapshot")
            .GetProperty("resultSha256")
            .GetString());
        Assert.HasCount(fixture.Expected.AcceptedSourceCount, root
            .GetProperty("acceptedSnapshot")
            .GetProperty("acceptedSources")
            .EnumerateArray());
    }

    [TestMethod]
    public void ExportPreservesValidIncompleteAndRejectsInvalidOrNonUtcInputs()
    {
        var scoring = ReadScoringFixture();
        var engine = new EvaluationScoringEngine();
        var accepted = engine.Calculate(scoring.Input, EvaluationFormulaCatalog.Version1);
        var incomplete = engine.Calculate(
            scoring.Input with
            {
                Dimensions = scoring.Input.Dimensions
                    .Select(item => item.Dimension == EvaluationDimension.Communication
                        ? item with { Leader = new(null, null, null) }
                        : item)
                    .ToArray(),
            },
            EvaluationFormulaCatalog.Version1);

        var incompleteExport = DeterministicSnapshotExporter.ExportEvaluation(incomplete, GenerationUtc);
        using (var incompleteDocument = JsonDocument.Parse(incompleteExport.Json))
        {
            var incompleteSnapshot = incompleteDocument.RootElement.GetProperty("acceptedSnapshot");
            Assert.AreEqual("incomplete", incompleteSnapshot.GetProperty("status").GetString());
            Assert.AreEqual(JsonValueKind.Null, incompleteSnapshot.GetProperty("totalScore").ValueKind);
            Assert.AreEqual(
                "missing",
                incompleteSnapshot.GetProperty("dimensions")[5].GetProperty("status").GetString());
            Assert.AreEqual(
                JsonValueKind.Null,
                incompleteSnapshot.GetProperty("dimensions")[5].GetProperty("dimensionScore").ValueKind);
            var missingSourceIdentity = incompleteDocument.RootElement
                .GetProperty("source")
                .GetProperty("sourceIdentities")[15];
            Assert.AreEqual(JsonValueKind.Null, missingSourceIdentity.GetProperty("provenanceId").ValueKind);
            Assert.AreEqual(
                JsonValueKind.Null,
                missingSourceIdentity.GetProperty("evidenceIdentitySha256").ValueKind);
        }

        var invalid = engine.Calculate(
            scoring.Input with
            {
                Dimensions = scoring.Input.Dimensions
                    .Select(item => item.Dimension == EvaluationDimension.Evidence
                        ? item with
                        {
                            ObjectiveEvidence = item.ObjectiveEvidence with { Score = 101 },
                        }
                        : item)
                    .ToArray(),
            },
            EvaluationFormulaCatalog.Version1);
        Assert.AreEqual(EvaluationResultStatus.Invalid, invalid.Status);
        Assert.ThrowsExactly<SnapshotExportException>(() =>
            DeterministicSnapshotExporter.ExportEvaluation(invalid, GenerationUtc));
        Assert.ThrowsExactly<SnapshotExportException>(() =>
            DeterministicSnapshotExporter.ExportEvaluation(
                accepted with { ResultSha256 = new string('0', 64) },
                GenerationUtc));
        Assert.ThrowsExactly<SnapshotExportException>(() =>
            DeterministicSnapshotExporter.ExportEvaluation(
                accepted,
                GenerationUtc.ToOffset(TimeSpan.FromHours(7))));

        var dailyFixture = ReadDailySummaryFixture();
        var timeZone = CreateFixedOffsetTimeZone(dailyFixture.TimeZoneOffsetMinutes);
        var daily = DailySummaryAggregator.Aggregate(
            dailyFixture.LocalDate,
            timeZone,
            dailyFixture.Sources);
        Assert.ThrowsExactly<SnapshotExportException>(() =>
            DeterministicSnapshotExporter.ExportDailySummary(
                daily with { ResultSha256 = new string('0', 64) },
                timeZone,
                GenerationUtc));
        Assert.ThrowsExactly<SnapshotExportException>(() =>
            DeterministicSnapshotExporter.ExportDailySummary(
                daily,
                TimeZoneInfo.Utc,
                GenerationUtc));
        var sameIdDifferentOffset = TimeZoneInfo.CreateCustomTimeZone(
            timeZone.Id,
            TimeSpan.FromHours(6),
            "Mismatched Daily Summary fixture",
            "Mismatched Daily Summary fixture");
        Assert.ThrowsExactly<SnapshotExportException>(() =>
            DeterministicSnapshotExporter.ExportDailySummary(
                daily,
                sameIdDifferentOffset,
                GenerationUtc));
    }

    [TestMethod]
    public void EvaluationExportRejectsDuplicateSourceIdentities()
    {
        var fixture = ReadScoringFixture();
        var duplicateInput = fixture.Input with
        {
            Dimensions = fixture.Input.Dimensions
                .Select(item => item.Dimension == EvaluationDimension.AcceptanceCriteria
                    ? item with
                    {
                        Leader = item.Leader with
                        {
                            ProvenanceId = fixture.Input.Dimensions[0].Leader.ProvenanceId,
                            EvidenceIdentitySha256 = fixture.Input.Dimensions[0].Leader.EvidenceIdentitySha256,
                        },
                    }
                    : item)
                .ToArray(),
        };
        var invalid = new EvaluationScoringEngine().Calculate(
            duplicateInput,
            EvaluationFormulaCatalog.Version1);

        Assert.AreEqual(EvaluationResultStatus.Invalid, invalid.Status);
        Assert.ThrowsExactly<SnapshotExportException>(() =>
            DeterministicSnapshotExporter.ExportEvaluation(invalid, GenerationUtc));
    }

    [TestMethod]
    public void RedactionPolicyRejectsPathsSecretsAndTokensWithoutProducingOutput()
    {
        var fixture = ReadDailySummaryFixture();
        var timeZone = CreateFixedOffsetTimeZone(fixture.TimeZoneOffsetMinutes);
        var adversarialValues = new[]
        {
            "C:\\private\\accepted.txt",
            "/var/private/accepted.txt",
            "\\\\server\\share\\accepted.txt",
            "Bearer abcdefghijklmnopQRSTUV1234",
            "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjMifQ.signatureabcdefgh",
            "tokenUltraSecretValue123456",
            "ghp_abcdefghijklmnopqrstuvwxyz1234567890",
            "github_pat_abcdefghijklmnopqrstuvwxyz1234567890",
            "sk-proj-abcdefghijklmnopqrstuvwxyz1234567890",
            "xoxb-abcdefghijklmnopqrstuvwxyz1234",
            "AKIAIOSFODNN7EXAMPLE",
            "relative/path.txt",
            "C:relative\\private.txt",
            "C:private",
            "..\\private\\accepted.txt",
            "../private",
            "private/accepted.txt",
            "\\private\\accepted.txt",
            "/private",
        };

        foreach (var adversarialValue in adversarialValues)
        {
            var source = fixture.Sources[0] with { Summary = adversarialValue };
            var accepted = DailySummaryAggregator.Aggregate(
                fixture.LocalDate,
                timeZone,
                [source, .. fixture.Sources.Skip(1)]);

            var exception = Assert.ThrowsExactly<SnapshotExportException>(() =>
                DeterministicSnapshotExporter.ExportDailySummary(
                    accepted,
                    timeZone,
                    GenerationUtc));

            StringAssert.Contains(exception.Message, "fail-closed");
            Assert.DoesNotContain(adversarialValue, exception.Message);
        }

        var harmlessValues = new[]
        {
            "token refresh completed",
            "secret wording is policy-safe",
            "A/B",
            "1/2",
            "github_pat_ is a documented prefix",
            "sk- is a documented prefix",
        };
        foreach (var harmlessValue in harmlessValues)
        {
            var source = fixture.Sources[0] with { Summary = harmlessValue };
            var accepted = DailySummaryAggregator.Aggregate(
                fixture.LocalDate,
                timeZone,
                [source, .. fixture.Sources.Skip(1)]);

            _ = DeterministicSnapshotExporter.ExportDailySummary(
                accepted,
                timeZone,
                GenerationUtc);
        }
    }

    [TestMethod]
    public void MarkdownCsvAndJsonPreserveEscapedValuesAndStrictUtf8RejectsSurrogates()
    {
        var fixture = ReadDailySummaryFixture();
        var timeZone = CreateFixedOffsetTimeZone(fixture.TimeZoneOffsetMinutes);
        const string specialValue = "Backtick ` with, comma [brackets] <tag>";
        var source = fixture.Sources[0] with { Summary = specialValue };
        var accepted = DailySummaryAggregator.Aggregate(
            fixture.LocalDate,
            timeZone,
            [source, .. fixture.Sources.Skip(1)]);
        var export = DeterministicSnapshotExporter.ExportDailySummary(
            accepted,
            timeZone,
            GenerationUtc);

        using var document = JsonDocument.Parse(export.Json);
        Assert.AreEqual(
            specialValue,
            document.RootElement
                .GetProperty("acceptedSnapshot")
                .GetProperty("timeline")[0]
                .GetProperty("summary")
                .GetString());
        StringAssert.Contains(export.Markdown, specialValue);
        StringAssert.Contains(export.Csv, specialValue);
        Assert.IsFalse(export.Markdown.Contains("Backtick '", StringComparison.Ordinal));

        var scoring = ReadScoringFixture();
        var surrogateSnapshot = new EvaluationScoringEngine().Calculate(
            scoring.Input with { TaskId = "TASK-\uD800" },
            EvaluationFormulaCatalog.Version1);
        Assert.ThrowsExactly<SnapshotExportException>(() =>
            DeterministicSnapshotExporter.ExportEvaluation(
                surrogateSnapshot,
                GenerationUtc));
    }

    [TestMethod]
    public void ExportRejectsIdentifierCollectionAndTotalOutputBounds()
    {
        var scoring = ReadScoringFixture();
        var engine = new EvaluationScoringEngine();
        var oversizedIdentifier = engine.Calculate(
            scoring.Input with { TaskId = new string('T', DeterministicSnapshotExporter.MaximumIdentifierLength + 1) },
            EvaluationFormulaCatalog.Version1);
        Assert.ThrowsExactly<SnapshotExportException>(() =>
            DeterministicSnapshotExporter.ExportEvaluation(oversizedIdentifier, GenerationUtc));

        var oversizedCollection = engine.Calculate(
            scoring.Input with
            {
                Dimensions = Enumerable.Repeat(
                        scoring.Input.Dimensions[0],
                        DeterministicSnapshotExporter.MaximumCollectionItems + 1)
                    .ToArray(),
            },
            EvaluationFormulaCatalog.Version1);
        Assert.ThrowsExactly<SnapshotExportException>(() =>
            DeterministicSnapshotExporter.ExportEvaluation(oversizedCollection, GenerationUtc));

        var dailyFixture = ReadDailySummaryFixture();
        var timeZone = CreateFixedOffsetTimeZone(dailyFixture.TimeZoneOffsetMinutes);
        var largeSummary = new string('x', 2_048);
        var largeSources = Enumerable.Range(0, 2_100)
            .Select(index => new DailySummarySource(
                $"large-{index:D5}",
                DailySummarySourceKind.ActivityEvent,
                new string('A', 64),
                new DateTimeOffset(2026, 8, 15, 3, 0, 0, TimeSpan.Zero),
                "Backend",
                "backend-worker-01",
                "TASK-115",
                "TaskStarted",
                largeSummary,
                true,
                false,
                null,
                null))
            .ToArray();
        var largeDaily = DailySummaryAggregator.Aggregate(
            dailyFixture.LocalDate,
            timeZone,
            largeSources);
        Assert.ThrowsExactly<SnapshotExportException>(() =>
            DeterministicSnapshotExporter.ExportDailySummary(
                largeDaily,
                timeZone,
                GenerationUtc));
    }

    private static ScoringFixture ReadScoringFixture() =>
        ReadFixture<ScoringFixture>("scoring-golden-v1.json", new JsonSerializerOptions
        {
            PropertyNameCaseInsensitive = true,
            Converters = { new JsonStringEnumConverter() },
        });

    private static DailySummaryFixture ReadDailySummaryFixture() =>
        ReadFixture<DailySummaryFixture>("daily-summary-aggregation.json", new JsonSerializerOptions
        {
            PropertyNameCaseInsensitive = true,
        });

    private static ExportManifest ReadExportManifest() =>
        ReadFixture<ExportManifest>("snapshot-export-v1.json", new JsonSerializerOptions
        {
            PropertyNameCaseInsensitive = true,
        });

    private static T ReadFixture<T>(string fileName, JsonSerializerOptions options)
    {
        var path = Path.Combine(
            FindRepositoryRoot(),
            "tests",
            "fixtures",
            "v0.6",
            fileName);
        return JsonSerializer.Deserialize<T>(File.ReadAllText(path, Encoding.UTF8), options)
            ?? throw new AssertFailedException($"Fixture '{fileName}' was empty.");
    }

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

        Assert.Fail("Could not locate HerdrOps.sln from the test output directory.");
        return string.Empty;
    }

    private static TimeZoneInfo CreateFixedOffsetTimeZone(int offsetMinutes) =>
        TimeZoneInfo.CreateCustomTimeZone(
            $"fixture-utc-{offsetMinutes}",
            TimeSpan.FromMinutes(offsetMinutes),
            "Daily Summary fixture",
            "Daily Summary fixture");

    private static string Sha256(string value) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value)));

    private sealed record ScoringFixture(
        EvaluationInputSnapshot Input,
        decimal ExpectedTotalScore,
        string ExpectedFormulaSha256,
        string ExpectedInputSnapshotSha256,
        string ExpectedResultSha256);

    private sealed record DailySummaryFixture(
        int ContractVersion,
        DateOnly LocalDate,
        int TimeZoneOffsetMinutes,
        DailySummarySource[] Sources,
        ExpectedCounts Expected);

    private sealed record ExpectedCounts(
        int AcceptedSourceCount,
        int ActivityCount,
        int EvidenceCount,
        int WorkstreamCount,
        int HighlightCount,
        int RepeatedIssueCount,
        int RecommendedActionCount,
        int TimelineCount,
        string RepeatedIssueKey,
        string[] RepeatedIssueSourceIds);

    private sealed record ExportManifest(
        string FixtureId,
        string Classification,
        string GenerationUtc,
        string DailySummaryTimeZoneId,
        string Encoding,
        string RedactionPolicyId,
        string EvaluationJsonSha256,
        string EvaluationMarkdownSha256,
        string EvaluationCsvSha256,
        string EvaluationExportId,
        string EvaluationSourceSnapshotSha256,
        string DailyJsonSha256,
        string DailyMarkdownSha256,
        string DailyCsvSha256,
        string DailyExportId,
        string DailySourceSnapshotSha256,
        string[] SourceFixtures);
}
