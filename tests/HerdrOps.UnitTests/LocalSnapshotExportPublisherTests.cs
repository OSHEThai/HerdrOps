using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using HerdrOps.Domain.Evaluation;
using HerdrOps.Domain.Exports;

namespace HerdrOps.UnitTests;

[TestClass]
public sealed class LocalSnapshotExportPublisherTests
{
    private static readonly DateTimeOffset GenerationUtc =
        new(2026, 8, 16, 0, 0, 0, TimeSpan.Zero);

    [TestMethod]
    public void PublishCreatesAtomicDirectoryPairWithManifestAndRereadHashes()
    {
        var export = CreateExport();
        var root = CreateTemporaryDirectory();
        try
        {
            var publication = new LocalSnapshotExportPublisher().Publish(export, root);

            Assert.IsTrue(Directory.Exists(publication.DirectoryPath));
            Assert.IsTrue(File.Exists(publication.JsonPath));
            Assert.IsTrue(File.Exists(publication.MarkdownPath));
            Assert.IsTrue(File.Exists(publication.CsvPath));
            Assert.IsTrue(File.Exists(publication.ManifestPath));
            Assert.AreEqual(export.ExportId, publication.Manifest.ExportId);
            Assert.AreEqual(export.JsonSha256, Sha256(File.ReadAllBytes(publication.JsonPath)));
            Assert.AreEqual(export.MarkdownSha256, Sha256(File.ReadAllBytes(publication.MarkdownPath)));
            Assert.AreEqual(export.CsvSha256, Sha256(File.ReadAllBytes(publication.CsvPath)));
            Assert.AreEqual(
                DeterministicSnapshotExporter.SerializeManifest(export.Manifest),
                File.ReadAllText(publication.ManifestPath, new UTF8Encoding(false)));
            Assert.HasCount(0, Directory.GetDirectories(root, ".herdops-*"));

            using var manifest = JsonDocument.Parse(File.ReadAllText(publication.ManifestPath));
            Assert.AreEqual(
                export.SourceSnapshotSha256,
                manifest.RootElement.GetProperty("sourceSnapshotSha256").GetString());
            Assert.AreEqual(
                export.MarkdownSha256,
                manifest.RootElement.GetProperty("markdownSha256").GetString());
        }
        finally
        {
            DeleteTemporaryDirectory(root);
        }
    }

    [TestMethod]
    public void PublishRejectsConflictWithoutOverwritingExistingPair()
    {
        var export = CreateExport();
        var root = CreateTemporaryDirectory();
        try
        {
            var first = new LocalSnapshotExportPublisher().Publish(export, root);
            var original = File.ReadAllBytes(first.JsonPath);

            Assert.ThrowsExactly<SnapshotExportException>(() =>
                new LocalSnapshotExportPublisher().Publish(export, root));

            CollectionAssert.AreEqual(original, File.ReadAllBytes(first.JsonPath));
            Assert.HasCount(1, Directory.GetDirectories(root, "herdops-*"));
            Assert.HasCount(0, Directory.GetDirectories(root, ".herdops-*"));
        }
        finally
        {
            DeleteTemporaryDirectory(root);
        }
    }

    [TestMethod]
    public void PublishFailureCleansStagingAndDoesNotPublishPartialPair()
    {
        var export = CreateExport();
        var root = CreateTemporaryDirectory();
        try
        {
            var publisher = new LocalSnapshotExportPublisher(phase =>
            {
                if (phase == SnapshotExportPublicationPhase.BeforeCommit)
                {
                    throw new InvalidOperationException("injected publication failure");
                }
            });

            Assert.ThrowsExactly<SnapshotExportException>(() => publisher.Publish(export, root));

            Assert.HasCount(0, Directory.GetDirectories(root, "herdops-*"));
            Assert.HasCount(0, Directory.GetDirectories(root, ".herdops-*"));
        }
        finally
        {
            DeleteTemporaryDirectory(root);
        }
    }

    private static DeterministicSnapshotExport CreateExport()
    {
        var root = FindRepositoryRoot();
        var options = new JsonSerializerOptions
        {
            PropertyNameCaseInsensitive = true,
            Converters = { new JsonStringEnumConverter() },
        };
        var fixture = JsonSerializer.Deserialize<ScoringFixture>(
            File.ReadAllText(Path.Combine(root, "tests", "fixtures", "v0.6", "scoring-golden-v1.json")),
            options) ?? throw new AssertFailedException("The scoring fixture was empty.");
        var accepted = new EvaluationScoringEngine().Calculate(
            fixture.Input,
            EvaluationFormulaCatalog.Version1);
        return DeterministicSnapshotExporter.ExportEvaluation(accepted, GenerationUtc);
    }

    private static string CreateTemporaryDirectory()
    {
        var path = Path.Combine(Path.GetTempPath(), $"herdops-export-test-{Guid.NewGuid():N}");
        Directory.CreateDirectory(path);
        return path;
    }

    private static void DeleteTemporaryDirectory(string path)
    {
        if (Directory.Exists(path))
        {
            Directory.Delete(path, recursive: true);
        }
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

    private static string Sha256(byte[] bytes) =>
        Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(bytes));

    private sealed record ScoringFixture(
        EvaluationInputSnapshot Input,
        decimal ExpectedTotalScore,
        string ExpectedFormulaSha256,
        string ExpectedInputSnapshotSha256,
        string ExpectedResultSha256);
}
