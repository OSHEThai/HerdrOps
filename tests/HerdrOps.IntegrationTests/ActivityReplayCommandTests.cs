using System.Text;
using System.Text.Json;
using HerdrOps.Core;

namespace HerdrOps.IntegrationTests;

[TestClass]
public sealed class ActivityReplayCommandTests
{
    private const string ExpectedInputSha256 =
        "8A7276170438360238803DD057BB6FB81F2745EC888C1A9DD2CF304B824633E1";

    private const string ExpectedResultSha256 =
        "9FC1E4E87291608DE338361E31315ABB01A73ACF4457F55EC2E263A734D3D82E";

    [TestMethod]
    public void CommittedReplayFixtureProducesByteIdenticalReportsAndExpectedHash()
    {
        var temporaryDirectory = CreateTemporaryDirectory();
        try
        {
            var fixturePath = Path.Combine(
                FindRepositoryRoot(),
                "tests",
                "fixtures",
                "v0.3",
                "activity-replay.json");
            var firstReportPath = Path.Combine(temporaryDirectory, "first.json");
            var secondReportPath = Path.Combine(temporaryDirectory, "second.json");

            var first = Run(fixturePath, firstReportPath);
            var second = Run(fixturePath, secondReportPath);

            Assert.AreEqual(0, first.ExitCode);
            Assert.AreEqual(0, second.ExitCode);
            Assert.AreEqual(string.Empty, first.Error);
            Assert.AreEqual(string.Empty, second.Error);
            CollectionAssert.AreEqual(
                File.ReadAllBytes(firstReportPath),
                File.ReadAllBytes(secondReportPath));
            Assert.AreEqual(first.Output, second.Output);

            using var document = JsonDocument.Parse(File.ReadAllBytes(firstReportPath));
            var root = document.RootElement;
            Assert.AreEqual("Synthetic", root.GetProperty("evidenceClass").GetString());
            Assert.IsFalse(root.GetProperty("runtimeObserved").GetBoolean());
            Assert.AreEqual(ExpectedInputSha256, root.GetProperty("inputSha256").GetString());
            var replay = root.GetProperty("replay");
            Assert.AreEqual(ExpectedResultSha256, replay.GetProperty("resultSha256").GetString());
            var diagnostics = replay.GetProperty("diagnostics");
            Assert.AreEqual(12, diagnostics.GetProperty("ingestedEventCount").GetInt64());
            Assert.AreEqual(11, diagnostics.GetProperty("acceptedEventCount").GetInt64());
            Assert.AreEqual(1, diagnostics.GetProperty("duplicateEventCount").GetInt64());
            Assert.AreEqual(1, diagnostics.GetProperty("gapObservationCount").GetInt64());
            Assert.AreEqual(2, diagnostics.GetProperty("urgentInputEventCount").GetInt64());
            Assert.AreEqual(2, replay.GetProperty("urgentEmissionCount").GetInt64());
            Assert.AreEqual(
                diagnostics.GetProperty("acceptedEventCount").GetInt64(),
                diagnostics.GetProperty("emittedSourceEventCount").GetInt64());
        }
        finally
        {
            Directory.Delete(temporaryDirectory, recursive: true);
        }
    }

    [TestMethod]
    public void UnknownInputMemberFailsClosedWithoutReplacingReport()
    {
        var temporaryDirectory = CreateTemporaryDirectory();
        try
        {
            var inputPath = Path.Combine(temporaryDirectory, "unknown-member.json");
            var reportPath = Path.Combine(temporaryDirectory, "report.json");
            File.WriteAllText(
                inputPath,
                """
                {
                  "contractVersion": 1,
                  "events": [],
                  "unexpectedRuntimeClaim": true
                }
                """,
                new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
            var sentinel = Encoding.UTF8.GetBytes("existing-report");
            File.WriteAllBytes(reportPath, sentinel);

            var result = Run(inputPath, reportPath);

            Assert.AreEqual(2, result.ExitCode);
            Assert.AreEqual(string.Empty, result.Output);
            StringAssert.Contains(result.Error, "could not be mapped");
            CollectionAssert.AreEqual(sentinel, File.ReadAllBytes(reportPath));
        }
        finally
        {
            Directory.Delete(temporaryDirectory, recursive: true);
        }
    }

    [TestMethod]
    public void DuplicateJsonPropertyFailsClosedWithoutReport()
    {
        var temporaryDirectory = CreateTemporaryDirectory();
        try
        {
            var inputPath = Path.Combine(temporaryDirectory, "duplicate-property.json");
            var reportPath = Path.Combine(temporaryDirectory, "report.json");
            File.WriteAllText(
                inputPath,
                """
                {
                  "contractVersion": 1,
                  "contractVersion": 1,
                  "events": []
                }
                """,
                new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));

            var result = Run(inputPath, reportPath);

            Assert.AreEqual(2, result.ExitCode);
            Assert.AreEqual(string.Empty, result.Output);
            StringAssert.Contains(result.Error, "Duplicate property");
            Assert.IsFalse(File.Exists(reportPath));
        }
        finally
        {
            Directory.Delete(temporaryDirectory, recursive: true);
        }
    }

    [TestMethod]
    public void MissingRequiredReportOptionReturnsUsageFailure()
    {
        using var output = new StringWriter();
        using var error = new StringWriter();

        var exitCode = ActivityReplayCommand.Run(
            ["activity-replay", "--input", "fixture.json"],
            output,
            error);

        Assert.AreEqual(64, exitCode);
        Assert.AreEqual(string.Empty, output.ToString());
        StringAssert.Contains(error.ToString(), "Both --input and --report are required");
        StringAssert.Contains(error.ToString(), "Usage:");
    }

    [TestMethod]
    public void InputCannotBeOverwrittenByReport()
    {
        var fixturePath = Path.Combine(
            FindRepositoryRoot(),
            "tests",
            "fixtures",
            "v0.3",
            "activity-replay.json");

        var result = Run(fixturePath, fixturePath);

        Assert.AreEqual(2, result.ExitCode);
        Assert.AreEqual(string.Empty, result.Output);
        StringAssert.Contains(result.Error, "must be different files");
        Assert.AreEqual(ExpectedInputSha256, Convert.ToHexString(
            System.Security.Cryptography.SHA256.HashData(File.ReadAllBytes(fixturePath))));
    }

    private static CommandResult Run(string inputPath, string reportPath)
    {
        using var output = new StringWriter();
        using var error = new StringWriter();
        var exitCode = ActivityReplayCommand.Run(
            ["activity-replay", "--input", inputPath, "--report", reportPath],
            output,
            error);
        return new CommandResult(exitCode, output.ToString(), error.ToString());
    }

    private static string CreateTemporaryDirectory()
    {
        var path = Path.Combine(
            Path.GetTempPath(),
            $"herdrops-activity-replay-{Guid.NewGuid():N}");
        Directory.CreateDirectory(path);
        return path;
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

    private sealed record CommandResult(int ExitCode, string Output, string Error);
}
