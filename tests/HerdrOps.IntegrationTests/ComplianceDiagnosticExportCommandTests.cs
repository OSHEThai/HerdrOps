using System.Text;
using System.Text.Json;
using HerdrOps.Cli;
using HerdrOps.Core;

namespace HerdrOps.IntegrationTests;

[TestClass]
public sealed class ComplianceDiagnosticExportCommandTests
{
    [TestMethod]
    public void CoreDirectCommandPublishesBoundedAllowlistedJson()
    {
        using var fixture = TemporaryDirectory.Create();
        var inputPath = Path.Combine(fixture.Path, "input.json");
        var outputPath = Path.Combine(fixture.Path, "export.json");
        File.WriteAllText(inputPath, FixtureJson(), new UTF8Encoding(false));

        using var output = new StringWriter();
        using var error = new StringWriter();
        var exitCode = ComplianceDiagnosticExportCommand.Run(
            [
                ComplianceDiagnosticExportCommand.CommandName,
                "--input",
                inputPath,
                "--output",
                outputPath,
            ],
            output,
            error);

        Assert.AreEqual(ComplianceDiagnosticExportCommand.SuccessExitCode, exitCode, error.ToString());
        Assert.AreEqual(string.Empty, error.ToString());
        Assert.IsTrue(File.Exists(outputPath));
        using var document = JsonDocument.Parse(File.ReadAllBytes(outputPath));
        Assert.AreEqual(
            "v0.5.compliance-diagnostic-export.v1",
            document.RootElement.GetProperty("schemaVersion").GetString());
        Assert.AreEqual(1, document.RootElement.GetProperty("recordCount").GetInt32());
        var outputText = File.ReadAllText(outputPath, Encoding.UTF8);
        Assert.IsFalse(outputText.Contains("password", StringComparison.Ordinal));
        Assert.IsFalse(outputText.Contains("C:\\Users\\Alice", StringComparison.Ordinal));
        Assert.IsFalse(outputText.Contains("free prose", StringComparison.Ordinal));
    }

    [TestMethod]
    public void CoreDirectCommandDoesNotOverwriteExistingDestination()
    {
        using var fixture = TemporaryDirectory.Create();
        var inputPath = Path.Combine(fixture.Path, "input.json");
        var outputPath = Path.Combine(fixture.Path, "existing.json");
        File.WriteAllText(inputPath, FixtureJson(), new UTF8Encoding(false));
        var sentinel = Encoding.UTF8.GetBytes("existing-sentinel");
        File.WriteAllBytes(outputPath, sentinel);

        using var output = new StringWriter();
        using var error = new StringWriter();
        var exitCode = ComplianceDiagnosticExportCommand.Run(
            [
                ComplianceDiagnosticExportCommand.CommandName,
                "--input",
                inputPath,
                "--output",
                outputPath,
            ],
            output,
            error);

        Assert.AreEqual(ComplianceDiagnosticExportCommand.ExportFailureExitCode, exitCode);
        Assert.AreEqual(string.Empty, output.ToString());
        CollectionAssert.AreEqual(sentinel, File.ReadAllBytes(outputPath));
        StringAssert.Contains(error.ToString(), "cannot be overwritten");
    }

    [TestMethod]
    public void CoreRejectsHostileSecretPathAndProseInputWithoutCreatingOutput()
    {
        using var fixture = TemporaryDirectory.Create();
        var inputPath = Path.Combine(fixture.Path, "hostile-input.json");
        var outputPath = Path.Combine(fixture.Path, "hostile-output.json");
        var hostileInput = FixtureJson().Replace(
            "\"schemaVersion\": \"v0.5.compliance-diagnostic-input.v1\",",
            "\"schemaVersion\": \"v0.5.compliance-diagnostic-input.v1\",\n" +
            "  \"token\": \"integration-secret-token\",\n" +
            "  \"path\": \"C:/Users/Alice/private.txt\",\n" +
            "  \"notes\": \"free prose secret\",",
            StringComparison.Ordinal);
        File.WriteAllText(inputPath, hostileInput, new UTF8Encoding(false));

        using var output = new StringWriter();
        using var error = new StringWriter();
        var exitCode = ComplianceDiagnosticExportCommand.Run(
            [
                ComplianceDiagnosticExportCommand.CommandName,
                "--input",
                inputPath,
                "--output",
                outputPath,
            ],
            output,
            error);

        Assert.AreEqual(ComplianceDiagnosticExportCommand.ExportFailureExitCode, exitCode);
        Assert.IsFalse(File.Exists(outputPath));
        Assert.IsFalse(error.ToString().Contains("integration-secret-token", StringComparison.Ordinal));
        Assert.IsFalse(error.ToString().Contains("C:/Users/Alice/private.txt", StringComparison.Ordinal));
        Assert.IsFalse(error.ToString().Contains("free prose secret", StringComparison.Ordinal));
    }

    [TestMethod]
    public void CoreDirectCommandRejectsTraversalAndReparseOutputParents()
    {
        using var fixture = TemporaryDirectory.Create();
        var inputPath = Path.Combine(fixture.Path, "input.json");
        File.WriteAllText(inputPath, FixtureJson(), new UTF8Encoding(false));

        using (var output = new StringWriter())
        using (var error = new StringWriter())
        {
            var traversalPath = Path.Combine(fixture.Path, "..", "traversal.json");
            var exitCode = ComplianceDiagnosticExportCommand.Run(
                [
                    ComplianceDiagnosticExportCommand.CommandName,
                    "--input",
                    inputPath,
                    "--output",
                    traversalPath,
                ],
                output,
                error);
            Assert.AreEqual(ComplianceDiagnosticExportCommand.ExportFailureExitCode, exitCode);
            Assert.IsFalse(File.Exists(Path.GetFullPath(traversalPath)));
        }

        var target = Directory.CreateDirectory(Path.Combine(fixture.Path, "reparse-target"));
        var link = Path.Combine(fixture.Path, "reparse-link");
        try
        {
            try
            {
                Directory.CreateSymbolicLink(link, target.FullName);
            }
            catch (Exception exception) when (
                exception is UnauthorizedAccessException or IOException or PlatformNotSupportedException)
            {
                Assert.Inconclusive($"Symbolic-link creation is unavailable on this Windows host: {exception.GetType().Name}");
            }

            using var output = new StringWriter();
            using var error = new StringWriter();
            var exitCode = ComplianceDiagnosticExportCommand.Run(
                [
                    ComplianceDiagnosticExportCommand.CommandName,
                    "--input",
                    inputPath,
                    "--output",
                    Path.Combine(link, "reparse.json"),
                ],
                output,
                error);
            Assert.AreEqual(ComplianceDiagnosticExportCommand.ExportFailureExitCode, exitCode);
            Assert.IsFalse(File.Exists(Path.Combine(target.FullName, "reparse.json")));
        }
        finally
        {
            if (Directory.Exists(link))
            {
                Directory.Delete(link, recursive: false);
            }
        }
    }

    [TestMethod]
    public async Task CliToCorePipePublishesWithoutReturningOutputPathOrSecrets()
    {
        if (!OperatingSystem.IsWindows())
        {
            Assert.Inconclusive("The CLI/Core Named Pipe contract is Windows-only.");
        }

        using var fixture = TemporaryDirectory.Create();
        var outputPath = Path.Combine(fixture.Path, "pipe-export.json");
        var pipeName = $"herdrops-compliance-test-{Guid.NewGuid():N}";
        using var serviceCancellation = new CancellationTokenSource();
        using var serviceOutput = new StringWriter();
        using var serviceError = new StringWriter();
        var serviceTask = ComplianceDiagnosticExportCommand.RunServiceAsync(
            [
                ComplianceDiagnosticExportCommand.ServiceCommandName,
                "--pipe-name",
                pipeName,
            ],
            serviceOutput,
            serviceError,
            serviceCancellation.Token);

        try
        {
            await WaitForReadyAsync(serviceOutput).ConfigureAwait(false);
            using var cliOutput = new StringWriter();
            using var cliError = new StringWriter();
            var exitCode = await HerdrOpsCliCommand.RunAsync(
                    [
                        ComplianceDiagnosticExportCliCommand.CommandName,
                        "--input",
                        "-",
                        "--output",
                        outputPath,
                        "--pipe-name",
                        pipeName,
                        "--timeout-ms",
                        "5000",
                    ],
                    new StringReader(FixtureJson()),
                    cliOutput,
                    cliError)
                .ConfigureAwait(false);

            Assert.AreEqual(HerdrOpsCliCommand.SuccessExitCode, exitCode, cliError.ToString());
            Assert.AreEqual(string.Empty, cliError.ToString());
            Assert.IsTrue(File.Exists(outputPath));
            Assert.IsFalse(cliOutput.ToString().Contains(outputPath, StringComparison.Ordinal));
            Assert.IsFalse(cliOutput.ToString().Contains("password", StringComparison.Ordinal));
        }
        finally
        {
            serviceCancellation.Cancel();
            await serviceTask.ConfigureAwait(false);
        }

        Assert.AreEqual(string.Empty, serviceError.ToString());
    }

    private static async Task WaitForReadyAsync(StringWriter output)
    {
        for (var attempt = 0; attempt < 100; attempt++)
        {
            if (output.ToString().Contains(" service ready:", StringComparison.Ordinal))
            {
                return;
            }

            await Task.Delay(20).ConfigureAwait(false);
        }

        Assert.Fail("The Core compliance diagnostic export service did not become ready.");
    }

    private static string FixtureJson() => """
    {
      "schemaVersion": "v0.5.compliance-diagnostic-input.v1",
      "generatedUtc": "2026-08-21T01:02:03.0000000Z",
      "records": [
        {
          "incidentId": "INC-001",
          "incidentState": "Suspected",
          "registeredUtc": "2026-08-21T01:02:03.0000000Z",
          "updatedUtc": "2026-08-21T01:02:04.0000000Z",
          "registrationSha256": "1111111111111111111111111111111111111111111111111111111111111111",
          "review": null,
          "evidence": [
            {
              "evidenceId": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
              "state": "Present",
              "observedUtc": "2026-08-21T01:02:03.0000000Z",
              "metadataSha256": "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC",
              "contentSha256": "EEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE"
            }
          ]
        }
      ]
    }
    """;

    private sealed class TemporaryDirectory : IDisposable
    {
        private TemporaryDirectory(string path) => Path = path;

        public string Path { get; }

        public static TemporaryDirectory Create()
        {
            var path = System.IO.Path.Combine(
                System.IO.Path.GetTempPath(),
                $"herdrops-compliance-export-{Guid.NewGuid():N}");
            Directory.CreateDirectory(path);
            return new TemporaryDirectory(path);
        }

        public void Dispose()
        {
            if (Directory.Exists(Path))
            {
                Directory.Delete(Path, recursive: true);
            }
        }
    }
}
