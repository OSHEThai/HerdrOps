using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using HerdrOps.Domain.Evaluation;
using HerdrOps.Domain.Exports;

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
        var csvBytes = Encoding.UTF8.GetBytes(export.Csv);
        CollectionAssert.AreNotEqual(new byte[] { 0xEF, 0xBB, 0xBF }, jsonBytes[..3]);
        CollectionAssert.AreNotEqual(new byte[] { 0xEF, 0xBB, 0xBF }, csvBytes[..3]);
        Assert.DoesNotContain('\r', export.Json);
        Assert.IsTrue(export.Csv.EndsWith("\r\n", StringComparison.Ordinal));
        Assert.AreEqual(
            Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(jsonBytes)),
            export.JsonSha256);
        Assert.AreEqual(
            Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(csvBytes)),
            export.CsvSha256);
        Assert.AreEqual("UTF-8 without BOM; JSON LF; CSV CRLF", export.Encoding);

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

    private sealed record ScoringFixture(
        EvaluationInputSnapshot Input,
        decimal ExpectedTotalScore,
        string ExpectedFormulaSha256,
        string ExpectedInputSnapshotSha256,
        string ExpectedResultSha256);
}
