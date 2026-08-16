using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Reflection;
using HerdrOps.Domain.Evaluation;
using HerdrOps.Domain.Exports;
using HerdrOps.Domain.Summaries;

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

    [TestMethod]
    public void PublishRejectsInvalidUtf8MutationBeforeAtomicCommit()
    {
        var export = CreateExport();
        var root = CreateTemporaryDirectory();
        try
        {
            var publisher = new LocalSnapshotExportPublisher(phase =>
            {
                if (phase == SnapshotExportPublicationPhase.FilesWritten)
                {
                    var stagingDirectory = Directory.GetDirectories(root, ".herdops-*").Single();
                    File.WriteAllBytes(Path.Combine(stagingDirectory, "snapshot.md"), [0xFF]);
                }
            });

            Assert.ThrowsExactly<SnapshotExportException>(() => publisher.Publish(export, root));
            AssertNoPublishedExport(root);
        }
        finally
        {
            DeleteTemporaryDirectory(root);
        }
    }

    [TestMethod]
    public void PublishRejectsRelativeRootDotParentDriveRelativeNetworkAndDeviceDestinations()
    {
        var export = CreateExport();
        var root = CreateTemporaryDirectory();
        try
        {
            var driveRoot = Path.GetPathRoot(root) ??
                throw new AssertFailedException("The test path has no drive root.");
            var driveRelative = driveRoot.TrimEnd(
                Path.DirectorySeparatorChar,
                Path.AltDirectorySeparatorChar) + "relative-export";
            var invalidDestinations = new[]
            {
                "relative-export",
                Path.Combine(root, ".", "child"),
                Path.Combine(root, "..", "child"),
                driveRelative,
                driveRoot,
                @"\\server\share\herdops",
                @"\\?\C:\herdops",
                @"\\.\pipe\herdops",
                @"\??\C:\herdops",
            };

            foreach (var destination in invalidDestinations)
            {
                Assert.ThrowsExactly<SnapshotExportException>(() =>
                    new LocalSnapshotExportPublisher().Publish(export, destination));
            }

            AssertNoPublishedExport(root);
        }
        finally
        {
            DeleteTemporaryDirectory(root);
        }
    }

    [TestMethod]
    public void PublishRejectsExistingReparsePointAncestorDestinationAndCollision()
    {
        var export = CreateExport();
        var root = CreateTemporaryDirectory();
        var target = Path.Combine(root, "reparse-target");
        var link = Path.Combine(root, "reparse-link");
        var finalLink = Path.Combine(
            root,
            $"herdops-{export.Kind.ToString().ToLowerInvariant()}-{export.ExportId}");
        try
        {
            Directory.CreateDirectory(target);
            if (!TryCreateDirectoryReparsePoint(link, target))
            {
                Assert.Inconclusive(
                    "The test environment cannot create a directory symlink or junction; reparse-point rejection is not treated as passing.");
            }

            Assert.ThrowsExactly<SnapshotExportException>(() =>
                new LocalSnapshotExportPublisher().Publish(export, link));
            Assert.ThrowsExactly<SnapshotExportException>(() =>
                new LocalSnapshotExportPublisher().Publish(export, Path.Combine(link, "child")));
            RemoveReparsePoint(link);

            if (!TryCreateDirectoryReparsePoint(finalLink, target))
            {
                Assert.Inconclusive(
                    "The test environment cannot create a final-directory reparse fixture; reparse-point rejection is not treated as passing.");
            }

            Assert.ThrowsExactly<SnapshotExportException>(() =>
                new LocalSnapshotExportPublisher().Publish(export, root));
            Assert.IsFalse(File.Exists(Path.Combine(target, "snapshot.json")));
            Assert.IsFalse(File.Exists(Path.Combine(finalLink, "snapshot.json")));
        }
        finally
        {
            RemoveReparsePoint(link);
            RemoveReparsePoint(finalLink);
            DeleteTemporaryDirectory(root);
        }
    }

    [TestMethod]
    public void PublishRejectsInvalidUtf16SurrogatesBeforeCreatingStaging()
    {
        foreach (var report in new[] { "json", "markdown", "csv" })
        {
            var export = CreateExport();
            var invalid = "\uD800";
            export = report switch
            {
                "json" => export with { Json = invalid },
                "markdown" => export with { Markdown = invalid },
                "csv" => export with { Csv = invalid },
                _ => throw new AssertFailedException($"Unknown report: {report}"),
            };
            var root = CreateTemporaryDirectory();
            try
            {
                Assert.ThrowsExactly<SnapshotExportException>(() =>
                    new LocalSnapshotExportPublisher().Publish(export, root));
                AssertNoPublishedExport(root);
            }
            finally
            {
                DeleteTemporaryDirectory(root);
            }
        }
    }

    [TestMethod]
    public void PublishRejectsHashConsistentForgedSensitiveEnvelopeWithoutFinalFiles()
    {
        var export = CreateExport();
        var forgedJson = export.Json.Replace(
            "\"acceptedSnapshot\":",
            "\"password\":\"tokenUltraSecretValue123456789\",\"acceptedSnapshot\":",
            StringComparison.Ordinal);
        var forged = RebindEnvelope(export, json: forgedJson);
        var root = CreateTemporaryDirectory();
        try
        {
            Assert.ThrowsExactly<SnapshotExportException>(() =>
                new LocalSnapshotExportPublisher().Publish(forged, root));
            AssertNoPublishedExport(root);
        }
        finally
        {
            DeleteTemporaryDirectory(root);
        }
    }

    [TestMethod]
    public void PublishRejectsHashConsistentForgedEvaluationAndDailyUnsafeContentBeforeStaging()
    {
        var unsafeValues = new[]
        {
            "C:\\private\\accepted.txt",
            "/var/private/accepted.txt",
            "\\\\server\\share\\accepted.txt",
            "Bearer abcdefghijklmnopQRSTUV1234",
            "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjMifQ.signatureabcdefgh",
            "tokenUltraSecretValue123456",
            "ghp_abcdefghijklmnopqrstuvwxyz1234567890",
            "gho_abcdefghijklmnopqrstuvwxyz1234567890",
            "github_pat_abcdefghijklmnopqrstuvwxyz1234567890",
            "sk-proj-abcdefghijklmnopqrstuvwxyz1234567890",
            "xoxb-abcdefghijklmnopqrstuvwxyz1234",
            "AKIAIOSFODNN7EXAMPLE",
            "ASIAIOSFODNN7EXAMPLE",
            "AIzaSyabcdefghijklmnopqrstuvwxyz123456",
            "glpat-abcdefghijklmnopqrstuvwxyz123456",
            "npm_abcdefghijklmnopqrstuvwxyz123456",
            "hf_abcdefghijklmnopqrstuvwxyz123456",
            "dop_v1_abcdefghijklmnopqrstuvwxyz123456",
            "relative/path.txt",
            "C:relative\\private.txt",
            "C:private",
            "..\\private\\accepted.txt",
            "../private",
            "private/accepted.txt",
            "\\private\\accepted.txt",
            "/private",
        };

        foreach (var unsafeValue in unsafeValues)
        {
            var evaluation = CreateExport();
            using (var evaluationDocument = JsonDocument.Parse(evaluation.Json))
            {
                var taskId = evaluationDocument.RootElement
                    .GetProperty("acceptedSnapshot")
                    .GetProperty("taskId")
                    .GetString()
                    ?? throw new AssertFailedException("The Evaluation task ID was missing.");
                AssertRejectedBeforeStaging(
                    ForgeJsonStringValue(evaluation, "taskId", taskId, unsafeValue),
                    unsafeValue);
            }

            var daily = CreateDailyExport();
            using (var dailyDocument = JsonDocument.Parse(daily.Json))
            {
                var summary = dailyDocument.RootElement
                    .GetProperty("acceptedSnapshot")
                    .GetProperty("timeline")[0]
                    .GetProperty("summary")
                    .GetString()
                    ?? throw new AssertFailedException("The Daily Summary timeline summary was missing.");
                AssertRejectedBeforeStaging(
                    ForgeJsonStringValue(daily, "summary", summary, unsafeValue),
                    unsafeValue);
            }
        }
    }

    [TestMethod]
    public void PublishAcceptsHarmlessDailyTextAndPreservesDynamicBacktickDelimiter()
    {
        var backtick = (char)96;
        var harmlessValues = new[]
        {
            "token refresh completed",
            "secret wording is policy-safe",
            "A/B",
            "1/2",
            "github_pat_ is a documented prefix",
            "sk- is a documented prefix",
            "Literal " + backtick + " one and " + new string(backtick, 2) + " two",
        };

        foreach (var harmlessValue in harmlessValues)
        {
            var export = CreateDailyExport(harmlessValue);
            var root = CreateTemporaryDirectory();
            try
            {
                var publication = new LocalSnapshotExportPublisher().Publish(export, root);
                var json = File.ReadAllText(publication.JsonPath, Encoding.UTF8);
                var markdown = File.ReadAllText(publication.MarkdownPath, Encoding.UTF8);

                using var document = JsonDocument.Parse(json);
                Assert.AreEqual(
                    harmlessValue,
                    document.RootElement
                        .GetProperty("acceptedSnapshot")
                        .GetProperty("timeline")[0]
                        .GetProperty("summary")
                        .GetString());
                Assert.AreEqual(export.MarkdownSha256, Sha256(File.ReadAllBytes(publication.MarkdownPath)));
                if (harmlessValue.IndexOf(backtick) >= 0)
                {
                    var delimiter = new string(backtick, 3);
                    StringAssert.Contains(markdown, $"{delimiter}{harmlessValue}{delimiter}");
                    Assert.IsFalse(
                        markdown.Contains("Literal ' one and '' two", StringComparison.Ordinal));
                }
            }
            finally
            {
                DeleteTemporaryDirectory(root);
            }
        }
    }

    [TestMethod]
    public void PublishRejectsHashConsistentForgedProjectionAndManifestVersionWithoutFinalFiles()
    {
        var export = CreateExport();
        var forgedProjection = RebindEnvelope(
            export,
            markdown: export.Markdown + "forged\n");
        var forgedManifest = export with
        {
            Manifest = export.Manifest with { ContractVersion = 99 },
        };
        var root = CreateTemporaryDirectory();
        try
        {
            Assert.ThrowsExactly<SnapshotExportException>(() =>
                new LocalSnapshotExportPublisher().Publish(forgedProjection, root));
            Assert.ThrowsExactly<SnapshotExportException>(() =>
                new LocalSnapshotExportPublisher().Publish(forgedManifest, root));
            AssertNoPublishedExport(root);
        }
        finally
        {
            DeleteTemporaryDirectory(root);
        }
    }

    [TestMethod]
    public void PublishRevalidatesDailySummaryEnvelopeWithCustomTimeZone()
    {
        var fixture = ReadDailySummaryFixture();
        var timeZone = TimeZoneInfo.CreateCustomTimeZone(
            $"fixture-utc-{fixture.TimeZoneOffsetMinutes}",
            TimeSpan.FromMinutes(fixture.TimeZoneOffsetMinutes),
            "Daily Summary fixture",
            "Daily Summary fixture");
        var accepted = DailySummaryAggregator.Aggregate(
            fixture.LocalDate,
            timeZone,
            fixture.Sources);
        var export = DeterministicSnapshotExporter.ExportDailySummary(
            accepted,
            timeZone,
            GenerationUtc);
        var root = CreateTemporaryDirectory();
        try
        {
            var publication = new LocalSnapshotExportPublisher().Publish(export, root);

            Assert.IsTrue(File.Exists(publication.JsonPath));
            Assert.IsTrue(File.Exists(publication.MarkdownPath));
            Assert.IsTrue(File.Exists(publication.CsvPath));
            Assert.AreEqual(export.JsonSha256, Sha256(File.ReadAllBytes(publication.JsonPath)));
            Assert.AreEqual(export.MarkdownSha256, Sha256(File.ReadAllBytes(publication.MarkdownPath)));
            Assert.AreEqual(export.CsvSha256, Sha256(File.ReadAllBytes(publication.CsvPath)));
        }
        finally
        {
            DeleteTemporaryDirectory(root);
        }
    }

    [TestMethod]
    public void PublishRejectsDailyExportWhoseAcceptedSnapshotIsNotBoundToTopLevelSourceHash()
    {
        var accepted = CreateDailyExport();
        var forgedIdentity = CreateDailyExport(
            sourceHashSha256: Sha256(new UTF8Encoding(false).GetBytes("forged daily source identity")));
        var forged = ForgeDailyTopLevelSourceSnapshot(accepted, forgedIdentity);
        Assert.AreNotEqual(accepted.SourceSnapshotSha256, forged.SourceSnapshotSha256);
        var root = CreateTemporaryDirectory();
        var phaseCount = 0;
        try
        {
            var exception = Assert.ThrowsExactly<SnapshotExportException>(() =>
                new LocalSnapshotExportPublisher(_ => phaseCount++).Publish(forged, root));

            StringAssert.Contains(exception.Message, "top-level source snapshot");
            Assert.AreEqual(0, phaseCount);
            AssertNoPublishedExport(root);
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

    private static DeterministicSnapshotExport CreateDailyExport(
        string? summary = null,
        string? sourceHashSha256 = null)
    {
        var fixture = ReadDailySummaryFixture();
        var timeZone = TimeZoneInfo.CreateCustomTimeZone(
            $"fixture-utc-{fixture.TimeZoneOffsetMinutes}",
            TimeSpan.FromMinutes(fixture.TimeZoneOffsetMinutes),
            "Daily Summary fixture",
            "Daily Summary fixture");
        var sources = summary is null && sourceHashSha256 is null
            ? fixture.Sources
            : [
                fixture.Sources[0] with
                {
                    Summary = summary ?? fixture.Sources[0].Summary,
                    SourceHashSha256 = sourceHashSha256 ?? fixture.Sources[0].SourceHashSha256,
                },
                .. fixture.Sources.Skip(1),
            ];
        var accepted = DailySummaryAggregator.Aggregate(
            fixture.LocalDate,
            timeZone,
            sources);
        return DeterministicSnapshotExporter.ExportDailySummary(
            accepted,
            timeZone,
            GenerationUtc);
    }

    private static DailySummaryFixture ReadDailySummaryFixture()
    {
        var root = FindRepositoryRoot();
        var options = new JsonSerializerOptions
        {
            PropertyNameCaseInsensitive = true,
        };
        return JsonSerializer.Deserialize<DailySummaryFixture>(
                   File.ReadAllText(
                       Path.Combine(root, "tests", "fixtures", "v0.6", "daily-summary-aggregation.json")),
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
        return RebindEnvelope(export, json: forgedJson);
    }

    private static void AssertRejectedBeforeStaging(
        DeterministicSnapshotExport export,
        string unsafeValue)
    {
        var root = CreateTemporaryDirectory();
        var phaseCount = 0;
        try
        {
            var exception = Assert.ThrowsExactly<SnapshotExportException>(() =>
                new LocalSnapshotExportPublisher(_ => phaseCount++).Publish(export, root));
            Assert.AreEqual(0, phaseCount);
            Assert.DoesNotContain(unsafeValue, exception.Message);
            AssertNoPublishedExport(root);
        }
        finally
        {
            DeleteTemporaryDirectory(root);
        }
    }

    private static DeterministicSnapshotExport RebindEnvelope(
        DeterministicSnapshotExport export,
        string? json = null,
        string? markdown = null,
        string? csv = null)
    {
        var nextJson = json ?? export.Json;
        var nextMarkdown = markdown ?? export.Markdown;
        var nextCsv = csv ?? export.Csv;
        var strictUtf8 = new UTF8Encoding(false, true);
        var jsonBytes = strictUtf8.GetBytes(nextJson);
        var markdownBytes = strictUtf8.GetBytes(nextMarkdown);
        var csvBytes = strictUtf8.GetBytes(nextCsv);
        var manifest = export.Manifest with
        {
            JsonSha256 = Sha256(jsonBytes),
            MarkdownSha256 = Sha256(markdownBytes),
            CsvSha256 = Sha256(csvBytes),
            JsonByteLength = jsonBytes.LongLength,
            MarkdownByteLength = markdownBytes.LongLength,
            CsvByteLength = csvBytes.LongLength,
            TotalByteLength = (long)jsonBytes.Length + markdownBytes.Length + csvBytes.Length,
        };
        return export with
        {
            Json = nextJson,
            Markdown = nextMarkdown,
            Csv = nextCsv,
            JsonSha256 = manifest.JsonSha256,
            MarkdownSha256 = manifest.MarkdownSha256,
            CsvSha256 = manifest.CsvSha256,
            Manifest = manifest,
        };
    }

    private static DeterministicSnapshotExport ForgeDailyTopLevelSourceSnapshot(
        DeterministicSnapshotExport accepted,
        DeterministicSnapshotExport forgedIdentity)
    {
        var forgedJson = accepted.Json
            .Replace(
                $"\"exportId\": \"{accepted.ExportId}\"",
                $"\"exportId\": \"{forgedIdentity.ExportId}\"",
                StringComparison.Ordinal)
            .Replace(
                $"\"sourceSnapshotSha256\": \"{accepted.SourceSnapshotSha256}\"",
                $"\"sourceSnapshotSha256\": \"{forgedIdentity.SourceSnapshotSha256}\"",
                StringComparison.Ordinal);
        using var document = JsonDocument.Parse(forgedJson);
        var strictUtf8 = new UTF8Encoding(false, true);
        var jsonBytes = strictUtf8.GetBytes(forgedJson);
        var csv = InvokeCanonicalCsv(document.RootElement);
        var csvBytes = strictUtf8.GetBytes(csv);
        var jsonSha256 = Sha256(jsonBytes);
        var csvSha256 = Sha256(csvBytes);
        var markdown = InvokeCanonicalMarkdown(
            document.RootElement,
            forgedIdentity.ExportId,
            forgedIdentity.SourceSnapshotSha256,
            jsonSha256,
            csvSha256);
        var markdownBytes = strictUtf8.GetBytes(markdown);
        var markdownSha256 = Sha256(markdownBytes);
        var manifest = accepted.Manifest with
        {
            ExportId = forgedIdentity.ExportId,
            SourceSnapshotSha256 = forgedIdentity.SourceSnapshotSha256,
            JsonSha256 = jsonSha256,
            MarkdownSha256 = markdownSha256,
            CsvSha256 = csvSha256,
            JsonByteLength = jsonBytes.LongLength,
            MarkdownByteLength = markdownBytes.LongLength,
            CsvByteLength = csvBytes.LongLength,
            TotalByteLength = (long)jsonBytes.Length + markdownBytes.Length + csvBytes.Length,
        };
        return accepted with
        {
            Json = forgedJson,
            Csv = csv,
            JsonSha256 = jsonSha256,
            CsvSha256 = csvSha256,
            Markdown = markdown,
            MarkdownSha256 = markdownSha256,
            ExportId = forgedIdentity.ExportId,
            SourceSnapshotSha256 = forgedIdentity.SourceSnapshotSha256,
            Manifest = manifest,
        };
    }

    private static string InvokeCanonicalCsv(JsonElement root)
    {
        var method = typeof(LocalSnapshotExportPublisher).GetMethod(
                         "BuildCanonicalCsv",
                         BindingFlags.NonPublic | BindingFlags.Static)
                     ?? throw new AssertFailedException("The canonical CSV builder was not found.");
        return (string)(method.Invoke(null, [root])
                        ?? throw new AssertFailedException("The canonical CSV builder returned no value."));
    }

    private static string InvokeCanonicalMarkdown(
        JsonElement root,
        string exportId,
        string sourceSnapshotSha256,
        string jsonSha256,
        string csvSha256)
    {
        var method = typeof(LocalSnapshotExportPublisher).GetMethod(
                         "BuildCanonicalMarkdown",
                         BindingFlags.NonPublic | BindingFlags.Static)
                     ?? throw new AssertFailedException("The canonical Markdown builder was not found.");
        return (string)(method.Invoke(
                            null,
                            [
                                SnapshotExportKind.DailySummary,
                                root,
                                exportId,
                                sourceSnapshotSha256,
                                jsonSha256,
                                csvSha256,
                            ])
                        ?? throw new AssertFailedException("The canonical Markdown builder returned no value."));
    }

    private static void AssertNoPublishedExport(string root)
    {
        Assert.HasCount(0, Directory.GetDirectories(root, "herdops-*"));
        Assert.HasCount(0, Directory.GetDirectories(root, ".herdops-*"));
    }

    private static bool TryCreateDirectoryReparsePoint(string linkPath, string targetPath)
    {
        try
        {
            Directory.CreateSymbolicLink(linkPath, targetPath);
            return true;
        }
        catch (Exception) when (
            OperatingSystem.IsWindows() ||
            OperatingSystem.IsLinux() ||
            OperatingSystem.IsMacOS())
        {
            try
            {
                var startInfo = new System.Diagnostics.ProcessStartInfo
                {
                    FileName = Environment.GetEnvironmentVariable("ComSpec") ??
                        Path.Combine(Environment.SystemDirectory, "cmd.exe"),
                    CreateNoWindow = true,
                    RedirectStandardError = true,
                    RedirectStandardOutput = true,
                    UseShellExecute = false,
                };
                startInfo.ArgumentList.Add("/d");
                startInfo.ArgumentList.Add("/c");
                startInfo.ArgumentList.Add("mklink");
                startInfo.ArgumentList.Add("/J");
                startInfo.ArgumentList.Add(linkPath);
                startInfo.ArgumentList.Add(targetPath);
                using var process = System.Diagnostics.Process.Start(startInfo);
                if (process is null)
                {
                    return false;
                }

                _ = process.StandardOutput.ReadToEnd();
                _ = process.StandardError.ReadToEnd();
                process.WaitForExit();
                return process.ExitCode == 0;
            }
            catch
            {
                return false;
            }
        }
    }

    private static void RemoveReparsePoint(string path)
    {
        try
        {
            var attributes = File.GetAttributes(path);
            if (attributes.HasFlag(FileAttributes.ReparsePoint))
            {
                Directory.Delete(path, recursive: false);
            }
        }
        catch (Exception) when (
            OperatingSystem.IsWindows() ||
            OperatingSystem.IsLinux() ||
            OperatingSystem.IsMacOS())
        {
        }
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
}
