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

    // ── Hostile regressions: service-command and CLI exception.Message must not echo to output ──

    // Before hardening, the service-command infrastructure catch wrote exception.Message verbatim
    // to stderr, which would expose any path/secret/prose embedded in the pipe name.
    [TestMethod]
    public async Task ServiceCommandInfrastructureFailureDoesNotLeakExceptionMessageToStderr()
    {
        const string secretFragment = "super-secret-token-in-pipe-name";
        const string pathFragment = "C:/Users/Alice/private.txt";
        const string proseFragment = "prose secret hidden inside name";

        // A pipe name with embedded backslash is rejected by ValidateOptions with an
        // ArgumentException. The Message contains the pipe name string, which would leak secrets.
        var hostilePipeName = $"bad\\pipe\\{secretFragment}";

        using var output = new StringWriter();
        using var error = new StringWriter();
        var exitCode = await ComplianceDiagnosticExportCommand.RunServiceAsync(
            [
                ComplianceDiagnosticExportCommand.ServiceCommandName,
                "--pipe-name",
                hostilePipeName,
            ],
            output,
            error,
            CancellationToken.None).ConfigureAwait(false);

        Assert.AreEqual(ComplianceDiagnosticExportCommand.ExportFailureExitCode, exitCode);
        var stderrText = error.ToString();
        Assert.IsFalse(stderrText.Contains(secretFragment, StringComparison.Ordinal),
            "secret token must not appear in service-command stderr");
        Assert.IsFalse(stderrText.Contains(pathFragment, StringComparison.Ordinal),
            "path must not appear in service-command stderr");
        Assert.IsFalse(stderrText.Contains(proseFragment, StringComparison.Ordinal),
            "prose must not appear in service-command stderr");
        // The fixed public message must remain so the failure is still diagnosable.
        StringAssert.Contains(stderrText, "the service could not be started",
            "fixed public message must appear in service-command stderr");
    }

    [TestMethod]
    public async Task ServiceCommandOversizedPipeNameDoesNotLeakExceptionMessageToStderr()
    {
        // 129-character pipe name (one over the 128-char limit in ValidateOptions) that embeds a
        // secret token: the ArgumentException.Message contains the full name, which must not leak.
        const string secretFragment = "integration-secret-token";
        var oversizedName = new string('z', 105) + secretFragment; // 105 + 24 = 129 chars

        using var output = new StringWriter();
        using var error = new StringWriter();
        var exitCode = await ComplianceDiagnosticExportCommand.RunServiceAsync(
            [
                ComplianceDiagnosticExportCommand.ServiceCommandName,
                "--pipe-name",
                oversizedName,
            ],
            output,
            error,
            CancellationToken.None).ConfigureAwait(false);

        Assert.AreEqual(ComplianceDiagnosticExportCommand.ExportFailureExitCode, exitCode);
        var stderrText = error.ToString();
        Assert.IsFalse(stderrText.Contains(secretFragment, StringComparison.Ordinal),
            "secret token must not appear in service-command stderr");
        StringAssert.Contains(stderrText, "the service could not be started",
            "fixed public message must appear in service-command stderr");
    }

    [TestMethod]
    public async Task CliArgumentExceptionDoesNotLeakExceptionMessageToStderr()
    {
        // The CLI ArgumentException catch (from pipe-client ValidateOptions) previously wrote
        // exception.Message verbatim. A hostile pipe name with a backslash (which triggers
        // ArgumentException inside ValidateOptions) must not appear in CLI stderr.
        const string secretFragment = "cli-secret-token";
        const string pathFragment = "C:/Users/Alice/private.txt";
        const string proseFragment = "free prose secret cli";

        // A pipe name with embedded backslash is rejected by ValidateOptions with ArgumentException.
        var hostilePipeName = $"bad\\{secretFragment}\\{proseFragment}";

        using var fixture = TemporaryDirectory.Create();
        var outputPath = Path.Combine(fixture.Path, "hostile-cli.json");

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
                hostilePipeName,
                "--timeout-ms",
                "500",
            ],
            new StringReader(FixtureJson()),
            cliOutput,
            cliError).ConfigureAwait(false);

        Assert.AreEqual(HerdrOpsCliCommand.UsageFailureExitCode, exitCode);
        var stderrText = cliError.ToString();
        Assert.IsFalse(stderrText.Contains(secretFragment, StringComparison.Ordinal),
            "secret token must not appear in CLI stderr");
        Assert.IsFalse(stderrText.Contains(pathFragment, StringComparison.Ordinal),
            "path must not appear in CLI stderr");
        Assert.IsFalse(stderrText.Contains(proseFragment, StringComparison.Ordinal),
            "prose must not appear in CLI stderr");
        StringAssert.Contains(stderrText, "invalid-arguments",
            "invalid-arguments code must appear in CLI stderr for diagnosability");
        Assert.IsFalse(File.Exists(outputPath), "no output file must be created on argument failure");
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
