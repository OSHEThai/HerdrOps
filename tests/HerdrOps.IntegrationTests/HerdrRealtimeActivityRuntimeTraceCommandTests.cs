using HerdrOps.Core;

namespace HerdrOps.IntegrationTests;

[TestClass]
public sealed class HerdrRealtimeActivityRuntimeTraceCommandTests
{
    [TestMethod]
    public async Task MissingReportIsRejectedBeforeRuntimeAdmission()
    {
        using var output = new StringWriter();
        using var error = new StringWriter();

        var exitCode = await HerdrRealtimeActivityRuntimeTraceCommand.RunAsync(
            [HerdrRealtimeActivityRuntimeTraceCommand.CommandName, "--seconds", "5"],
            output,
            error,
            environmentVariableReader: _ => "1");

        Assert.AreEqual(64, exitCode);
        StringAssert.Contains(error.ToString(), "--report is required");
    }

    [TestMethod]
    public async Task InvalidDurationIsRejectedDeterministically()
    {
        using var output = new StringWriter();
        using var error = new StringWriter();

        var exitCode = await HerdrRealtimeActivityRuntimeTraceCommand.RunAsync(
            [HerdrRealtimeActivityRuntimeTraceCommand.CommandName, "--seconds", "0", "--report", "ignored.json"],
            output,
            error,
            environmentVariableReader: _ => "1");

        Assert.AreEqual(64, exitCode);
        StringAssert.Contains(error.ToString(), "from 1 through 3600");
    }

    [TestMethod]
    public async Task MissingAuthorizedHerdrEnvironmentFailsClosedWithoutWritingReport()
    {
        var reportPath = Path.Combine(
            Path.GetTempPath(),
            "HerdrOps.IntegrationTests",
            $"realtime-activity-runtime-{Guid.NewGuid():N}.json");
        using var output = new StringWriter();
        using var error = new StringWriter();

        var exitCode = await HerdrRealtimeActivityRuntimeTraceCommand.RunAsync(
            [HerdrRealtimeActivityRuntimeTraceCommand.CommandName, "--report", reportPath],
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
            $"realtime-activity-runtime-{Guid.NewGuid():N}.json");
        var missingExecutable = Path.Combine(
            Path.GetTempPath(),
            "HerdrOps.IntegrationTests",
            $"missing-herdr-{Guid.NewGuid():N}.exe");
        using var output = new StringWriter();
        using var error = new StringWriter();

        var exitCode = await HerdrRealtimeActivityRuntimeTraceCommand.RunAsync(
            [
                HerdrRealtimeActivityRuntimeTraceCommand.CommandName,
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
