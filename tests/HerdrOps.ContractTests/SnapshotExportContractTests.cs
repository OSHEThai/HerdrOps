using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using HerdrOps.Domain.Evaluation;
using HerdrOps.Domain.Exports;
using HerdrOps.Domain.Summaries;

namespace HerdrOps.ContractTests;

[TestClass]
public sealed class SnapshotExportContractTests
{
    [TestMethod]
    public void ExportContractUsesStableUtf8OrderingHashesAndFailClosedPolicy()
    {
        var fixture = ReadFixture();
        var accepted = new EvaluationScoringEngine().Calculate(
            fixture.Input,
            EvaluationFormulaCatalog.Version1);
        var export = DeterministicSnapshotExporter.ExportEvaluation(
            accepted,
            new DateTimeOffset(2026, 8, 16, 0, 0, 0, TimeSpan.Zero));

        var jsonBytes = Encoding.UTF8.GetBytes(export.Json);
        var markdownBytes = Encoding.UTF8.GetBytes(export.Markdown);
        var csvBytes = Encoding.UTF8.GetBytes(export.Csv);
        CollectionAssert.AreNotEqual(new byte[] { 0xEF, 0xBB, 0xBF }, jsonBytes[..3]);
        CollectionAssert.AreNotEqual(new byte[] { 0xEF, 0xBB, 0xBF }, markdownBytes[..3]);
        CollectionAssert.AreNotEqual(new byte[] { 0xEF, 0xBB, 0xBF }, csvBytes[..3]);
        Assert.DoesNotContain('\r', export.Json);
        Assert.DoesNotContain('\r', export.Markdown);
        Assert.IsTrue(export.Csv.EndsWith("\r\n", StringComparison.Ordinal));
        Assert.AreEqual(
            Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(jsonBytes)),
            export.JsonSha256);
        Assert.AreEqual(
            Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(markdownBytes)),
            export.MarkdownSha256);
        Assert.AreEqual(
            Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(csvBytes)),
            export.CsvSha256);
        Assert.AreEqual("UTF-8 without BOM; JSON LF; CSV CRLF", export.Encoding);
        Assert.AreEqual(export.ExportId, export.Manifest.ExportId);
        Assert.AreEqual(export.SourceSnapshotSha256, export.Manifest.SourceSnapshotSha256);
        Assert.AreEqual(export.JsonSha256, export.Manifest.JsonSha256);
        Assert.AreEqual(export.MarkdownSha256, export.Manifest.MarkdownSha256);
        Assert.AreEqual(export.CsvSha256, export.Manifest.CsvSha256);
        Assert.AreEqual(
            jsonBytes.LongLength + markdownBytes.LongLength + csvBytes.LongLength,
            export.Manifest.TotalByteLength);
        Assert.IsLessThanOrEqualTo(
            DeterministicSnapshotExporter.MaximumTotalOutputBytes,
            export.Manifest.TotalByteLength);

        using var document = JsonDocument.Parse(export.Json);
        var root = document.RootElement;
        CollectionAssert.AreEqual(
            new[] { "metadata", "source", "acceptedSnapshot" },
            root.EnumerateObject().Select(item => item.Name).ToArray());
        var policy = root.GetProperty("metadata").GetProperty("redactionPolicy");
        Assert.AreEqual("HERDROPS-LOCAL-EXPORT-REDACTION-V1", policy.GetProperty("policyId").GetString());
        Assert.AreEqual("fail-closed", policy.GetProperty("mode").GetString());
        CollectionAssert.AreEqual(
            new[] { "filesystem-path", "secret", "token" },
            policy.GetProperty("prohibitedContentKinds")
                .EnumerateArray()
                .Select(item => item.GetString())
                .ToArray());
        Assert.AreEqual("reject export; never redact in place", policy.GetProperty("action").GetString());
        StringAssert.StartsWith(export.Csv, "path,type,value\r\n");
    }

    [TestMethod]
    public void PublisherRejectsHashConsistentForgedEnvelopeAndUnsafeDestinationWithoutPublication()
    {
        var fixture = ReadFixture();
        var accepted = new EvaluationScoringEngine().Calculate(
            fixture.Input,
            EvaluationFormulaCatalog.Version1);
        var export = DeterministicSnapshotExporter.ExportEvaluation(
            accepted,
            new DateTimeOffset(2026, 8, 16, 0, 0, 0, TimeSpan.Zero));
        var forgedJson = export.Json.Replace(
            "\"acceptedSnapshot\":",
            "\"unknownField\":true,\"acceptedSnapshot\":",
            StringComparison.Ordinal);
        var forged = RebindEnvelope(export, forgedJson);
        var root = Path.Combine(Path.GetTempPath(), $"herdops-contract-{Guid.NewGuid():N}");
        Directory.CreateDirectory(root);
        try
        {
            Assert.ThrowsExactly<SnapshotExportException>(() =>
                new LocalSnapshotExportPublisher().Publish(forged, root));
            Assert.ThrowsExactly<SnapshotExportException>(() =>
                new LocalSnapshotExportPublisher().Publish(export, Path.Combine(root, ".", "child")));
            Assert.HasCount(0, Directory.GetDirectories(root, "herdops-*"));
            Assert.HasCount(0, Directory.GetDirectories(root, ".herdops-*"));
        }
        finally
        {
            if (Directory.Exists(root))
            {
                Directory.Delete(root, recursive: true);
            }
        }
    }

    [TestMethod]
    public void PublisherRejectsHashConsistentForgedEvaluationAndDailyUnsafeContentBeforeStaging()
    {
        var unsafeValues = new[]
        {
            "relative/path.txt",
            "C:relative\\private.txt",
            "..\\private\\accepted.txt",
            "/private",
            "ghp_abcdefghijklmnopqrstuvwxyz1234567890",
            "github_pat_abcdefghijklmnopqrstuvwxyz1234567890",
            "sk-proj-abcdefghijklmnopqrstuvwxyz1234567890",
            "AKIAIOSFODNN7EXAMPLE",
            "tokenUltraSecretValue123456",
        };

        var evaluation = CreateEvaluationExport();
        using var evaluationDocument = JsonDocument.Parse(evaluation.Json);
        var taskId = evaluationDocument.RootElement
            .GetProperty("acceptedSnapshot")
            .GetProperty("taskId")
            .GetString();
        Assert.IsNotNull(taskId);

        var daily = CreateDailyExport("Contract baseline summary");
        using var dailyDocument = JsonDocument.Parse(daily.Json);
        var summary = dailyDocument.RootElement
            .GetProperty("acceptedSnapshot")
            .GetProperty("timeline")[0]
            .GetProperty("summary")
            .GetString();
        Assert.IsNotNull(summary);

        foreach (var unsafeValue in unsafeValues)
        {
            AssertRejectedBeforeStaging(
                ForgeJsonStringValue(evaluation, "taskId", taskId!, unsafeValue),
                unsafeValue);
            AssertRejectedBeforeStaging(
                ForgeJsonStringValue(daily, "summary", summary!, unsafeValue),
                unsafeValue);
        }
    }

    [TestMethod]
    public void PublisherPreservesDynamicBacktickMarkdownValues()
    {
        var backtick = (char)96;
        var value = "Contract literal " + backtick + " and " + new string(backtick, 2);
        var export = CreateDailyExport(value);
        var root = Path.Combine(
            Path.GetTempPath(),
            $"herdops-contract-{Guid.NewGuid():N}");
        Directory.CreateDirectory(root);
        try
        {
            var publication = new LocalSnapshotExportPublisher().Publish(export, root);
            var json = File.ReadAllText(publication.JsonPath, Encoding.UTF8);
            var markdown = File.ReadAllText(publication.MarkdownPath, Encoding.UTF8);
            var delimiter = new string(backtick, 3);

            using var document = JsonDocument.Parse(json);
            Assert.AreEqual(
                value,
                document.RootElement
                    .GetProperty("acceptedSnapshot")
                    .GetProperty("timeline")[0]
                    .GetProperty("summary")
                    .GetString());
            StringAssert.Contains(markdown, $"{delimiter}{value}{delimiter}");
            Assert.IsFalse(
                markdown.Contains("Contract literal ' and ''", StringComparison.Ordinal));
            Assert.AreEqual(
                export.MarkdownSha256,
                Convert.ToHexString(
                    System.Security.Cryptography.SHA256.HashData(
                        File.ReadAllBytes(publication.MarkdownPath))));
        }
        finally
        {
            if (Directory.Exists(root))
            {
                Directory.Delete(root, recursive: true);
            }
        }
    }

    private static DeterministicSnapshotExport CreateEvaluationExport()
    {
        var fixture = ReadFixture();
        var accepted = new EvaluationScoringEngine().Calculate(
            fixture.Input,
            EvaluationFormulaCatalog.Version1);
        return DeterministicSnapshotExporter.ExportEvaluation(
            accepted,
            new DateTimeOffset(2026, 8, 16, 0, 0, 0, TimeSpan.Zero));
    }

    private static DeterministicSnapshotExport CreateDailyExport(string summary)
    {
        var fixture = ReadDailySummaryFixture();
        var timeZone = TimeZoneInfo.CreateCustomTimeZone(
            $"fixture-utc-{fixture.TimeZoneOffsetMinutes}",
            TimeSpan.FromMinutes(fixture.TimeZoneOffsetMinutes),
            "Daily Summary fixture",
            "Daily Summary fixture");
        DailySummarySource[] sources =
        [
            fixture.Sources[0] with { Summary = summary },
            .. fixture.Sources.Skip(1),
        ];
        var accepted = DailySummaryAggregator.Aggregate(
            fixture.LocalDate,
            timeZone,
            sources);
        return DeterministicSnapshotExporter.ExportDailySummary(
            accepted,
            timeZone,
            new DateTimeOffset(2026, 8, 16, 0, 0, 0, TimeSpan.Zero));
    }

    private static DailySummaryFixture ReadDailySummaryFixture()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null &&
               !File.Exists(Path.Combine(directory.FullName, "HerdrOps.sln")))
        {
            directory = directory.Parent;
        }

        Assert.IsNotNull(directory);
        var path = Path.Combine(
            directory!.FullName,
            "tests",
            "fixtures",
            "v0.6",
            "daily-summary-aggregation.json");
        var options = new JsonSerializerOptions
        {
            PropertyNameCaseInsensitive = true,
        };
        return JsonSerializer.Deserialize<DailySummaryFixture>(
                   File.ReadAllText(path, Encoding.UTF8),
                   options)
               ?? throw new AssertFailedException("The Daily Summary fixture was empty.");
    }

    private static DeterministicSnapshotExport ForgeJsonStringValue(
        DeterministicSnapshotExport export,
        string propertyName,
        string originalValue,
        string replacementValue)
    {
        var forgedJson = export.Json.Replace(
            $"\"{propertyName}\": {JsonSerializer.Serialize(originalValue)}",
            $"\"{propertyName}\": {JsonSerializer.Serialize(replacementValue)}",
            StringComparison.Ordinal);
        Assert.AreNotEqual(export.Json, forgedJson);
        return RebindEnvelope(export, forgedJson);
    }

    private static void AssertRejectedBeforeStaging(
        DeterministicSnapshotExport export,
        string unsafeValue)
    {
        var root = Path.Combine(
            Path.GetTempPath(),
            $"herdops-contract-{Guid.NewGuid():N}");
        Directory.CreateDirectory(root);
        var phaseCount = 0;
        try
        {
            var exception = Assert.ThrowsExactly<SnapshotExportException>(() =>
                new LocalSnapshotExportPublisher(_ => phaseCount++).Publish(export, root));
            Assert.AreEqual(0, phaseCount);
            Assert.DoesNotContain(unsafeValue, exception.Message);
            Assert.HasCount(0, Directory.GetDirectories(root, "herdops-*"));
            Assert.HasCount(0, Directory.GetDirectories(root, ".herdops-*"));
        }
        finally
        {
            if (Directory.Exists(root))
            {
                Directory.Delete(root, recursive: true);
            }
        }
    }

    private static ScoringFixture ReadFixture()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null &&
               !File.Exists(Path.Combine(directory.FullName, "HerdrOps.sln")))
        {
            directory = directory.Parent;
        }

        Assert.IsNotNull(directory);
        var path = Path.Combine(
            directory!.FullName,
            "tests",
            "fixtures",
            "v0.6",
            "scoring-golden-v1.json");
        var options = new JsonSerializerOptions
        {
            PropertyNameCaseInsensitive = true,
            Converters = { new JsonStringEnumConverter() },
        };
        return JsonSerializer.Deserialize<ScoringFixture>(
                   File.ReadAllText(path, Encoding.UTF8),
                   options)
                   ?? throw new AssertFailedException("The scoring fixture was empty.");
    }

    private static DeterministicSnapshotExport RebindEnvelope(
        DeterministicSnapshotExport export,
        string json)
    {
        var strictUtf8 = new UTF8Encoding(false, true);
        var jsonBytes = strictUtf8.GetBytes(json);
        var manifest = export.Manifest with
        {
            JsonSha256 = Sha256(jsonBytes),
            JsonByteLength = jsonBytes.LongLength,
            TotalByteLength = jsonBytes.LongLength +
                export.Manifest.MarkdownByteLength +
                export.Manifest.CsvByteLength,
        };
        return export with
        {
            Json = json,
            JsonSha256 = manifest.JsonSha256,
            Manifest = manifest,
        };
    }

    private static string Sha256(byte[] bytes) =>
        Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(bytes));

    private sealed record DailySummaryFixture(
        int ContractVersion,
        DateOnly LocalDate,
        int TimeZoneOffsetMinutes,
        DailySummarySource[] Sources,
        object Expected);

    private sealed record ScoringFixture(
        EvaluationInputSnapshot Input,
        decimal ExpectedTotalScore,
        string ExpectedFormulaSha256,
        string ExpectedInputSnapshotSha256,
        string ExpectedResultSha256);
}
