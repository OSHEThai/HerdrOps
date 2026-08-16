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
        Assert.AreEqual(first.Csv, second.Csv);
        Assert.AreEqual(manifest.EvaluationJsonSha256, first.JsonSha256);
        Assert.AreEqual(manifest.EvaluationCsvSha256, first.CsvSha256);
        Assert.AreEqual(first.JsonSha256, Sha256(first.Json));
        Assert.AreEqual(first.CsvSha256, Sha256(first.Csv));
        StringAssert.Contains(first.Json, "HERDROPS-EVALUATION-V1");
        StringAssert.Contains(first.Json, accepted.ResultSha256);
        StringAssert.Contains(first.Csv, "$.acceptedSnapshot.dimensions[0].weightedScore");

        using var document = JsonDocument.Parse(first.Json);
        var root = document.RootElement;
        Assert.AreEqual("evaluation-score-result", root.GetProperty("metadata").GetProperty("exportKind").GetString());
        Assert.AreEqual(manifest.GenerationUtc, root.GetProperty("metadata").GetProperty("generatedUtc").GetString());
        Assert.AreEqual(manifest.Encoding, first.Encoding);
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
        Assert.AreEqual(manifest.DailyJsonSha256, export.JsonSha256);
        Assert.AreEqual(manifest.DailyCsvSha256, export.CsvSha256);
        Assert.AreEqual(export.JsonSha256, Sha256(export.Json));
        Assert.AreEqual(export.CsvSha256, Sha256(export.Csv));
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
    public void ExportRejectsIncompleteTamperedAndNonUtcInputs()
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

        Assert.ThrowsExactly<SnapshotExportException>(() =>
            DeterministicSnapshotExporter.ExportEvaluation(incomplete, GenerationUtc));
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
    }

    [TestMethod]
    public void RedactionPolicyRejectsPathsSecretsAndTokensWithoutProducingOutput()
    {
        var fixture = ReadDailySummaryFixture();
        var timeZone = CreateFixedOffsetTimeZone(fixture.TimeZoneOffsetMinutes);
        var source = fixture.Sources[0] with { Summary = "C:\\private\\accepted.txt" };
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
        Assert.DoesNotContain("accepted.txt", exception.Message);
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
        string EvaluationCsvSha256,
        string DailyJsonSha256,
        string DailyCsvSha256,
        string[] SourceFixtures);
}
