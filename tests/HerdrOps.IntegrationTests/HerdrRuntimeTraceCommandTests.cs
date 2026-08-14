using HerdrOps.Core;

namespace HerdrOps.IntegrationTests;

[TestClass]
public sealed class HerdrRuntimeTraceCommandTests
{
    [TestMethod]
    public void RuntimeFactoryRejectsMissingExecutableBeforePipeConnection()
    {
        var missingExecutable = Path.Combine(
            Path.GetTempPath(),
            "HerdrOps.IntegrationTests",
            $"missing-herdr-{Guid.NewGuid():N}.exe");

        var exception = Assert.ThrowsExactly<HerdrRuntimeAdmissionException>(() =>
            new HerdrRuntimeMonitorFactory().Create(missingExecutable, "must-not-connect"));

        StringAssert.Contains(exception.Message, "protocol admission failed");
        StringAssert.Contains(exception.Message, "was not found");
    }

    [TestMethod]
    public async Task MissingReportIsRejectedBeforeRuntimeAdmission()
    {
        using var output = new StringWriter();
        using var error = new StringWriter();

        var exitCode = await HerdrRuntimeTraceCommand.RunAsync(
            ["trace-herdr-runtime", "--seconds", "5"],
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

        var exitCode = await HerdrRuntimeTraceCommand.RunAsync(
            ["trace-herdr-runtime", "--seconds", "0", "--report", "ignored.json"],
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
            $"runtime-{Guid.NewGuid():N}.json");
        using var output = new StringWriter();
        using var error = new StringWriter();

        var exitCode = await HerdrRuntimeTraceCommand.RunAsync(
            ["trace-herdr-runtime", "--report", reportPath],
            output,
            error,
            environmentVariableReader: _ => null);

        Assert.AreEqual(3, exitCode);
        Assert.IsFalse(File.Exists(reportPath));
        StringAssert.Contains(error.ToString(), "HERDR_ENV=1");
    }

    [TestMethod]
    public async Task TerminalProcessTraceRequiresReportBeforeRuntimeAdmission()
    {
        using var output = new StringWriter();
        using var error = new StringWriter();

        var exitCode = await HerdrTerminalProcessTraceCommand.RunAsync(
            ["trace-herdr-terminal-process", "--seconds", "5"],
            output,
            error,
            environmentVariableReader: _ => "1");

        Assert.AreEqual(64, exitCode);
        StringAssert.Contains(error.ToString(), "--report is required");
    }

    [TestMethod]
    public async Task TerminalProcessTraceRejectsAnUnboundedLineRequest()
    {
        using var output = new StringWriter();
        using var error = new StringWriter();

        var exitCode = await HerdrTerminalProcessTraceCommand.RunAsync(
            [
                "trace-herdr-terminal-process",
                "--lines",
                "201",
                "--report",
                "ignored.json",
            ],
            output,
            error,
            environmentVariableReader: _ => "1");

        Assert.AreEqual(64, exitCode);
        StringAssert.Contains(error.ToString(), "from 1 through 200");
    }

    [TestMethod]
    public async Task TerminalProcessTraceRequiresAuthorizedHerdrEnvironmentWithoutWritingReport()
    {
        var reportPath = Path.Combine(
            Path.GetTempPath(),
            "HerdrOps.IntegrationTests",
            $"terminal-process-{Guid.NewGuid():N}.json");
        using var output = new StringWriter();
        using var error = new StringWriter();

        var exitCode = await HerdrTerminalProcessTraceCommand.RunAsync(
            ["trace-herdr-terminal-process", "--report", reportPath],
            output,
            error,
            environmentVariableReader: _ => null);

        Assert.AreEqual(3, exitCode);
        Assert.IsFalse(File.Exists(reportPath));
        StringAssert.Contains(error.ToString(), "HERDR_ENV=1");
    }
}
