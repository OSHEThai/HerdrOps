using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using HerdrOps.Core;

namespace HerdrOps.IntegrationTests;

[TestClass]
public sealed class AssignmentLifecycleReplayCommandTests
{
    private const string ExpectedInputSha256 =
        "03A13C69A59BC7F99D5BB3055E012A711F073EE214337E7DF6A42A1B3C2CB62C";

    private const string ExpectedResultSha256 =
        "896D7ED38511AA038F77B8361038F4D26A90A7E713677C3A16BA1A3E87047B0F";

    [TestMethod]
    public void CommittedLifecycleFixtureProducesByteIdenticalReportsAndExpectedHash()
    {
        var temporaryDirectory = CreateTemporaryDirectory();
        try
        {
            var fixturePath = FindFixture();
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
            Assert.AreEqual(10L, diagnostics.GetProperty("processedEventCount").GetInt64());
            Assert.AreEqual(8L, diagnostics.GetProperty("appliedEventCount").GetInt64());
            Assert.AreEqual(1L, diagnostics.GetProperty("orphanEventCount").GetInt64());
            Assert.AreEqual(1L, diagnostics.GetProperty("duplicateHandoffCount").GetInt64());
            Assert.AreEqual(3, diagnostics.GetProperty("relationshipCount").GetInt32());
            var task = replay.GetProperty("currentTasks")[0].GetProperty("state");
            Assert.AreEqual("HandedOff", task.GetProperty("status").GetString());
            Assert.AreEqual("reviewer-01", task.GetProperty("currentAssigneeId").GetString());
            Assert.AreEqual(1, task.GetProperty("deviationCount").GetInt32());
            Assert.AreEqual(1, task.GetProperty("evidenceCount").GetInt32());
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
                  "runtimeObserved": true
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

        var exitCode = AssignmentLifecycleReplayCommand.Run(
            ["assignment-lifecycle-replay", "--input", "fixture.json"],
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
        var fixturePath = FindFixture();

        var result = Run(fixturePath, fixturePath);

        Assert.AreEqual(2, result.ExitCode);
        Assert.AreEqual(string.Empty, result.Output);
        StringAssert.Contains(result.Error, "must be different files");
        Assert.AreEqual(
            ExpectedInputSha256,
            Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(fixturePath))));
    }

    private static CommandResult Run(string inputPath, string reportPath)
    {
        using var output = new StringWriter();
        using var error = new StringWriter();
        var exitCode = AssignmentLifecycleReplayCommand.Run(
            [
                "assignment-lifecycle-replay",
                "--input",
                inputPath,
                "--report",
                reportPath,
            ],
            output,
            error);
        return new CommandResult(exitCode, output.ToString(), error.ToString());
    }

    private static string FindFixture() => Path.Combine(
        FindRepositoryRoot(),
        "tests",
        "fixtures",
        "v0.4",
        "assignment-lifecycle-replay.json");

    private static string CreateTemporaryDirectory()
    {
        var path = Path.Combine(
            Path.GetTempPath(),
            $"herdrops-assignment-lifecycle-replay-{Guid.NewGuid():N}");
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
