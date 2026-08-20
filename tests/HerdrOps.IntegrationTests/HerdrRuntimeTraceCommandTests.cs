using HerdrOps.Core;
using HerdrOps.Contracts;
using HerdrOps.Domain.Herdr;
using HerdrOps.Infrastructure.Herdr;

namespace HerdrOps.IntegrationTests;

[TestClass]
public sealed class HerdrRuntimeTraceCommandTests
{
    [TestMethod]
    public void TraceTransitionCopiesOnlyTheMonitorAcceptedEventProvenance()
    {
        var snapshot = new HerdrRuntimeMonitorSnapshot(
            HerdrRuntimeMonitorStatus.Connected,
            HerdrSessionState.Empty with
            {
                Version = "0.8.0-test",
                Protocol = 19,
                ConnectionEpoch = 2,
                LastIngestSequence = 11,
            },
            ServerIdentity: null,
            BootstrapCount: 2,
            EventCount: 6,
            DisconnectCount: 1,
            ReconciliationCount: 5,
            LastTransitionReason: null,
            LastTransitionUtc: DateTimeOffset.Parse("2026-08-16T03:04:01Z"));

        var eventTransition = HerdrRuntimeEvidence.CreateTransition(snapshot with
        {
            AcceptedEventKind = HerdrRuntimeMonitor.AcceptedAgentStatusEventKind,
            AcceptedAgentStatusEvent = new HerdrAcceptedAgentStatusEvent(
                "workspace-1",
                "pane-1",
                HerdrAgentStatus.Working,
                "codex",
                "Codex",
                "Working"),
        });
        var nonEventTransition = HerdrRuntimeEvidence.CreateTransition(snapshot);

        Assert.AreEqual(
            "pane.agent_status_changed",
            eventTransition.AcceptedEventKind);
        Assert.IsNotNull(eventTransition.AcceptedAgentStatusEvent);
        Assert.AreEqual("workspace-1", eventTransition.AcceptedAgentStatusEvent.WorkspaceId);
        Assert.AreEqual("pane-1", eventTransition.AcceptedAgentStatusEvent.PaneId);
        Assert.AreEqual(HerdrAgentStatus.Working, eventTransition.AcceptedAgentStatusEvent.AgentStatus);
        StringAssert.Matches(eventTransition.AgentTopologySha256, new("^[0-9A-F]{64}$"));
        StringAssert.Matches(eventTransition.AgentStatusStateSha256, new("^[0-9A-F]{64}$"));
        Assert.AreEqual(
            eventTransition.AgentTopologySha256,
            nonEventTransition.AgentTopologySha256);
        Assert.AreEqual(
            eventTransition.AgentStatusStateSha256,
            nonEventTransition.AgentStatusStateSha256);
        Assert.IsNull(nonEventTransition.AcceptedEventKind);
        Assert.IsNull(nonEventTransition.AcceptedAgentStatusEvent);
        Assert.IsTrue(HerdrRuntimeEvidence.HasAcceptedAgentStatusEvent(
            [nonEventTransition, eventTransition]));
        Assert.IsFalse(HerdrRuntimeEvidence.HasAcceptedAgentStatusEvent(
            [nonEventTransition]));
    }

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
    public void RuntimeFactoryDoesNotRetryAFailedAdmissionScan()
    {
        var executablePath = Path.Combine(
            Path.GetTempPath(),
            $"herdr-failed-admission-{Guid.NewGuid():N}.exe");
        File.WriteAllBytes(executablePath, [(byte)'M', (byte)'Z']);
        try
        {
            var scanner = new FailingAdmissionScanner();

            _ = Assert.ThrowsExactly<HerdrRuntimeAdmissionException>(() =>
                new HerdrRuntimeMonitorFactory(scanner).Create(
                    executablePath,
                    "must-not-connect"));

            Assert.AreEqual(1, scanner.CallCount);
        }
        finally
        {
            File.Delete(executablePath);
        }
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

    private sealed class FailingAdmissionScanner : IHerdrExecutableAdmissionScanner
    {
        public int CallCount { get; private set; }

        public HerdrExecutableAdmissionSnapshot Scan(
            string executablePath,
            HerdrProtocolSupportPolicy policy,
            bool captureBundledSchema)
        {
            CallCount++;
            throw new HerdrExecutableAdmissionScanException(
                HerdrExecutableAdmissionScanFailure.Unreadable,
                Path.GetFullPath(executablePath),
                Path.GetFullPath(executablePath),
                "test-release",
                2,
                "Synthetic admission read failure.");
        }
    }
}
