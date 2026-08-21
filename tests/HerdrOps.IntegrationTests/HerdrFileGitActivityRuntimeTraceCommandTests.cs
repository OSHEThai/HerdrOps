using HerdrOps.Core;

namespace HerdrOps.IntegrationTests;

[TestClass]
public sealed class HerdrFileGitActivityRuntimeTraceCommandTests
{
    [TestMethod]
    public async Task MissingReportIsRejectedBeforeRuntimeAdmission()
    {
        using var output = new StringWriter();
        using var error = new StringWriter();

        var exitCode = await HerdrFileGitActivityRuntimeTraceCommand.RunAsync(
            ["trace-herdr-file-git-activity", "--repo-root", Path.GetTempPath().TrimEnd('\\')],
            output,
            error,
            environmentVariableReader: _ => "1");

        Assert.AreEqual(64, exitCode);
        StringAssert.Contains(error.ToString(), "--repo-root and --report");
    }

    [TestMethod]
    public async Task RelativeRepositoryRootIsRejectedDeterministically()
    {
        using var output = new StringWriter();
        using var error = new StringWriter();

        var exitCode = await HerdrFileGitActivityRuntimeTraceCommand.RunAsync(
            ["trace-herdr-file-git-activity", "--repo-root", "relative-path", "--report", "ignored.json"],
            output,
            error,
            environmentVariableReader: _ => "1");

        Assert.AreEqual(64, exitCode);
        StringAssert.Contains(error.ToString(), "--repo-root and --report");
    }

    [TestMethod]
    public async Task MissingAuthorizedHerdrEnvironmentFailsClosedWithoutWritingReport()
    {
        var reportPath = Path.Combine(
            Path.GetTempPath(),
            "HerdrOps.IntegrationTests",
            $"file-git-runtime-{Guid.NewGuid():N}.json");
        using var output = new StringWriter();
        using var error = new StringWriter();

        var exitCode = await HerdrFileGitActivityRuntimeTraceCommand.RunAsync(
            [
                "trace-herdr-file-git-activity",
                "--repo-root",
                Path.GetTempPath().TrimEnd('\\'),
                "--report",
                reportPath,
            ],
            output,
            error,
            environmentVariableReader: _ => null);

        Assert.AreEqual(3, exitCode);
        Assert.IsFalse(File.Exists(reportPath));
        StringAssert.Contains(error.ToString(), "HERDR_ENV=1");
    }

    [TestMethod]
    public async Task RuntimeAdmissionFailureIsReportedWithoutWritingReport()
    {
        var reportPath = Path.Combine(
            Path.GetTempPath(),
            "HerdrOps.IntegrationTests",
            $"file-git-runtime-{Guid.NewGuid():N}.json");
        var missingExecutable = Path.Combine(
            Path.GetTempPath(),
            "HerdrOps.IntegrationTests",
            $"missing-herdr-{Guid.NewGuid():N}.exe");
        using var output = new StringWriter();
        using var error = new StringWriter();

        var exitCode = await HerdrFileGitActivityRuntimeTraceCommand.RunAsync(
            [
                "trace-herdr-file-git-activity",
                "--repo-root",
                Path.GetTempPath().TrimEnd('\\'),
                "--report",
                reportPath,
                "--herdr",
                missingExecutable,
                "--socket-path",
                "must-not-connect",
            ],
            output,
            error,
            environmentVariableReader: _ => "1");

        Assert.AreEqual(2, exitCode);
        Assert.IsFalse(File.Exists(reportPath));
        StringAssert.Contains(error.ToString(), "Runtime admission failed");
    }
}
