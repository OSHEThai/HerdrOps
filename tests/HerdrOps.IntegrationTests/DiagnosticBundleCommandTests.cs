using System.Text;
using System.Text.Json;
using HerdrOps.Core;
using HerdrOps.Domain.Diagnostics;

namespace HerdrOps.IntegrationTests;

[TestClass]
[DoNotParallelize]
public sealed class DiagnosticBundleCommandTests
{
    [TestMethod]
    public void OperatorCommandPublishesSelectedRedactedSummaryAndCrashMetadata()
    {
        using var fixture = TemporaryDirectory.Create();
        var outputRoot = Directory.CreateDirectory(Path.Combine(fixture.Path, "diagnostics"));
        const string secret = "operator-secret-42";
        using var output = new StringWriter();
        using var error = new StringWriter();

        var exitCode = DiagnosticBundleCommand.Run(
            [
                DiagnosticBundleCommand.CommandName,
                "--output-root", outputRoot.FullName,
                "--bundle-name", "bundle-001",
                "--app-version", "0.7.0",
                "--process-version", "HerdrOps.Core/0.7.0",
                "--captured-at-utc", "2026-08-22T01:02:03Z",
                "--secret", secret,
                "--summary", $"selected summary secret={secret}; path=C:\\Users\\Alice\\state.db",
                "--crash", "2026-08-22T01:02:04Z", "System.Exception", "Unhandled",
                $"crash secret={secret}", $"at HerdrOps.Core.Run() C:\\Users\\Alice\\source.cs:42",
            ],
            output,
            error);

        Assert.AreEqual(DiagnosticBundleCommand.SuccessExitCode, exitCode, error.ToString());
        Assert.AreEqual(string.Empty, error.ToString());

        using var result = JsonDocument.Parse(output.ToString());
        var bundlePath = result.RootElement.GetProperty("BundleDirectoryPath").GetString();
        Assert.IsNotNull(bundlePath);
        Assert.IsTrue(Directory.Exists(bundlePath));
        Assert.AreEqual(1, result.RootElement.GetProperty("EntryCount").GetInt32());
        Assert.AreEqual(1, result.RootElement.GetProperty("CrashCount").GetInt32());

        foreach (var artifactPath in result.RootElement.GetProperty("ArtifactPaths").EnumerateArray())
        {
            var text = File.ReadAllText(artifactPath.GetString()!, Encoding.UTF8);
            Assert.IsFalse(text.Contains(secret, StringComparison.Ordinal), artifactPath.GetString());
            Assert.IsFalse(text.Contains("C:\\Users\\Alice", StringComparison.Ordinal), artifactPath.GetString());
        }

        using var crashMetadata = JsonDocument.Parse(
            File.ReadAllBytes(Path.Combine(bundlePath!, DiagnosticBundleSchema.CrashMetadataFileName)));
        Assert.AreEqual(
            "unhandled",
            crashMetadata.RootElement.GetProperty("crashes")[0].GetProperty("category").GetString());
    }

    [TestMethod]
    public void OperatorCommandRejectsTraversalWithoutPublishing()
    {
        using var fixture = TemporaryDirectory.Create();
        var outputRoot = Directory.CreateDirectory(Path.Combine(fixture.Path, "diagnostics"));
        using var output = new StringWriter();
        using var error = new StringWriter();

        var exitCode = DiagnosticBundleCommand.Run(
            [
                DiagnosticBundleCommand.CommandName,
                "--output-root", outputRoot.FullName,
                "--bundle-name", "..\\escape",
                "--app-version", "0.7.0",
                "--process-version", "HerdrOps.Core/0.7.0",
                "--summary", "selected summary",
            ],
            output,
            error);

        Assert.AreEqual(DiagnosticBundleCommand.FailureExitCode, exitCode);
        Assert.AreEqual(string.Empty, output.ToString());
        Assert.IsFalse(Directory.EnumerateDirectories(outputRoot.FullName).Any());
    }

    [TestMethod]
    public void OperatorCommandFailsClosedOnEntryAndInputBounds()
    {
        using var fixture = TemporaryDirectory.Create();
        var outputRoot = Directory.CreateDirectory(Path.Combine(fixture.Path, "diagnostics"));
        var tooManyArguments = new List<string>
        {
            DiagnosticBundleCommand.CommandName,
            "--output-root", outputRoot.FullName,
            "--bundle-name", "too-many",
            "--app-version", "0.7.0",
            "--process-version", "HerdrOps.Core/0.7.0",
        };
        for (var index = 0; index < 65; index++)
        {
            tooManyArguments.Add("--summary");
            tooManyArguments.Add($"summary-{index}");
        }

        using var countOutput = new StringWriter();
        using var countError = new StringWriter();
        Assert.AreEqual(
            DiagnosticBundleCommand.FailureExitCode,
            DiagnosticBundleCommand.Run(tooManyArguments.ToArray(), countOutput, countError));
        Assert.IsFalse(Directory.Exists(Path.Combine(outputRoot.FullName, "too-many")));

        using var sizeOutput = new StringWriter();
        using var sizeError = new StringWriter();
        Assert.AreEqual(
            DiagnosticBundleCommand.FailureExitCode,
            DiagnosticBundleCommand.Run(
                [
                    DiagnosticBundleCommand.CommandName,
                    "--output-root", outputRoot.FullName,
                    "--bundle-name", "too-large",
                    "--app-version", "0.7.0",
                    "--process-version", "HerdrOps.Core/0.7.0",
                    "--summary", new string('x', 70 * 1024),
                ],
                sizeOutput,
                sizeError));
        Assert.IsFalse(Directory.Exists(Path.Combine(outputRoot.FullName, "too-large")));
    }

    private sealed class TemporaryDirectory : IDisposable
    {
        private TemporaryDirectory(string path)
        {
            Path = path;
        }

        public string Path { get; }

        public static TemporaryDirectory Create()
        {
            var path = System.IO.Path.Combine(
                System.IO.Path.GetTempPath(),
                "HerdrOps-DiagnosticBundleCommandTests-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(path);
            return new TemporaryDirectory(path);
        }

        public void Dispose()
        {
            try
            {
                if (Directory.Exists(Path))
                {
                    Directory.Delete(Path, recursive: true);
                }
            }
            catch (IOException)
            {
            }
            catch (UnauthorizedAccessException)
            {
            }
        }
    }
}
