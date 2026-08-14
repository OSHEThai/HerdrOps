using System.Text.Json;
using HerdrOps.Core;
using HerdrOps.Domain.Activity;
using HerdrOps.Domain.Herdr;
using HerdrOps.Infrastructure.Activity;
using HerdrOps.Infrastructure.Herdr;

namespace HerdrOps.IntegrationTests;

[TestClass]
public sealed class HerdrTerminalProcessCollectorTests
{
    [TestMethod]
    public async Task ConnectedCycleReadsBoundedTerminalAndCorrelatesRedactedProcessTelemetry()
    {
        const string terminalSecret = "terminal-secret-123456";
        const string processSecret = "process-secret-123456";
        var clock = new ManualTimeProvider(Utc(12, 0, 0));
        var paneClient = new RecordingPaneClient(
            terminalText: $"PASSWORD={terminalSecret}\r\nbuild complete",
            processCommand: $"dotnet build API_KEY={processSecret}");
        var processReader = new DeterministicProcessReader();
        var processCollector = new WindowsProcessCorrelationCollector(
            processReader,
            new WindowsProcessTelemetryTracker(new WindowsProcessTelemetryOptions(
                TimeSpan.FromSeconds(10),
                MaximumTrackedProcesses: 8,
                ProcessorCount: 2)),
            new SensitiveTextRedactor());
        var collector = new HerdrTerminalProcessCollector(
            paneClient,
            HerdrPipeEndpoint.FromSocketPath("collector-test"),
            new HerdrTerminalProcessCollectorOptions(
                MaximumTerminalLines: 40,
                MaximumPanesPerCycle: 8,
                TerminalReadInterval: TimeSpan.FromSeconds(2),
                ProcessPollInterval: TimeSpan.FromSeconds(2)),
            processCollector: processCollector,
            timeProvider: clock);

        var cycle = await collector.CollectOnceAsync(
            CreateSnapshot(HerdrRuntimeMonitorStatus.Connected, revision: 7),
            TestContext.CancellationToken);
        var serialized = JsonSerializer.Serialize(cycle);

        Assert.IsTrue(cycle.Connected);
        Assert.AreEqual(1, cycle.TerminalReadAttemptCount);
        Assert.AreEqual(1, cycle.ProcessPollAttemptCount);
        Assert.HasCount(1, cycle.TerminalPreviews);
        Assert.HasCount(1, cycle.ProcessTelemetry);
        Assert.HasCount(0, cycle.ProcessFailures);
        Assert.HasCount(0, cycle.CollectionFailures);
        Assert.AreEqual(40, paneClient.MaximumLines.Single());
        Assert.AreEqual("recent_unwrapped", cycle.TerminalPreviews[0].Source);
        Assert.AreEqual("text", cycle.TerminalPreviews[0].Format);
        StringAssert.Contains(cycle.TerminalPreviews[0].RedactedSummary, "PASSWORD=[REDACTED]");
        Assert.AreEqual(700, cycle.ProcessTelemetry[0].Observation.ProcessId);
        Assert.AreEqual(HerdrReportedProcessSource.Foreground, cycle.ProcessTelemetry[0].Observation.ReportedSource);
        StringAssert.Contains(
            cycle.ProcessTelemetry[0].Observation.RedactedCommandSummary,
            "API_KEY=[REDACTED]");
        Assert.IsFalse(serialized.Contains(terminalSecret, StringComparison.Ordinal));
        Assert.IsFalse(serialized.Contains(processSecret, StringComparison.Ordinal));
    }

    [TestMethod]
    public async Task RevisionsAndPollIntervalsPreventContinuousTerminalAndProcessReads()
    {
        var clock = new ManualTimeProvider(Utc(12, 0, 0));
        var paneClient = new RecordingPaneClient("build", "dotnet build");
        paneClient.ReadRevision = 1;
        var collector = CreateCollector(paneClient, clock);

        var first = await collector.CollectOnceAsync(
            CreateSnapshot(HerdrRuntimeMonitorStatus.Connected, revision: 1),
            TestContext.CancellationToken);
        clock.Advance(TimeSpan.FromSeconds(1));
        var unchangedInsideInterval = await collector.CollectOnceAsync(
            CreateSnapshot(HerdrRuntimeMonitorStatus.Connected, revision: 1),
            TestContext.CancellationToken);
        clock.Advance(TimeSpan.FromSeconds(1));
        var unchangedAfterInterval = await collector.CollectOnceAsync(
            CreateSnapshot(HerdrRuntimeMonitorStatus.Connected, revision: 1),
            TestContext.CancellationToken);
        clock.Advance(TimeSpan.FromSeconds(2));
        paneClient.ReadRevision = 2;
        var changed = await collector.CollectOnceAsync(
            CreateSnapshot(HerdrRuntimeMonitorStatus.Connected, revision: 2),
            TestContext.CancellationToken);

        Assert.AreEqual(1, first.TerminalReadAttemptCount);
        Assert.AreEqual(1, first.ProcessPollAttemptCount);
        Assert.AreEqual(0, unchangedInsideInterval.TerminalReadAttemptCount);
        Assert.AreEqual(0, unchangedInsideInterval.ProcessPollAttemptCount);
        Assert.AreEqual(0, unchangedAfterInterval.TerminalReadAttemptCount);
        Assert.AreEqual(1, unchangedAfterInterval.ProcessPollAttemptCount);
        Assert.AreEqual(1, changed.TerminalReadAttemptCount);
        Assert.AreEqual(1, changed.ProcessPollAttemptCount);
        Assert.AreEqual(2, paneClient.TerminalReadCount);
        Assert.AreEqual(3, paneClient.ProcessInfoCount);
    }

    [TestMethod]
    public async Task DisconnectedMonitorProducesNoInspectionCalls()
    {
        var paneClient = new RecordingPaneClient("must not read", "must not inspect");
        var collector = CreateCollector(
            paneClient,
            new ManualTimeProvider(Utc(12, 0, 0)));

        var cycle = await collector.CollectOnceAsync(
            CreateSnapshot(HerdrRuntimeMonitorStatus.Reconnecting, revision: 3),
            TestContext.CancellationToken);

        Assert.IsFalse(cycle.Connected);
        Assert.AreEqual(0, cycle.InspectedPaneCount);
        Assert.AreEqual(1, cycle.SkippedPaneCount);
        Assert.AreEqual(0, paneClient.TerminalReadCount);
        Assert.AreEqual(0, paneClient.ProcessInfoCount);
    }

    [TestMethod]
    public async Task ZeroPaneRevisionIsCollectedWithoutInventingAPositiveSourceSequence()
    {
        var paneClient = new RecordingPaneClient("initial output", "dotnet build")
        {
            ReadRevision = 0,
        };
        var collector = CreateCollector(
            paneClient,
            new ManualTimeProvider(Utc(12, 0, 0)));

        var cycle = await collector.CollectOnceAsync(
            CreateSnapshot(HerdrRuntimeMonitorStatus.Connected, revision: 0),
            TestContext.CancellationToken);

        Assert.HasCount(1, cycle.TerminalPreviews);
        Assert.AreEqual((ulong)0, cycle.TerminalPreviews[0].ReadRevision);
        Assert.AreEqual(ActivityPipelineDisposition.AcceptedBuffered, cycle.TerminalPreviews[0].PipelineDisposition);
    }

    public TestContext TestContext { get; set; } = null!;

    private static HerdrTerminalProcessCollector CreateCollector(
        RecordingPaneClient paneClient,
        TimeProvider timeProvider)
    {
        var processCollector = new WindowsProcessCorrelationCollector(
            new DeterministicProcessReader(),
            new WindowsProcessTelemetryTracker(new WindowsProcessTelemetryOptions(
                TimeSpan.FromSeconds(10),
                MaximumTrackedProcesses: 8,
                ProcessorCount: 2)),
            new SensitiveTextRedactor());
        return new HerdrTerminalProcessCollector(
            paneClient,
            HerdrPipeEndpoint.FromSocketPath("collector-test"),
            new HerdrTerminalProcessCollectorOptions(
                MaximumTerminalLines: 40,
                MaximumPanesPerCycle: 8,
                TerminalReadInterval: TimeSpan.FromSeconds(2),
                ProcessPollInterval: TimeSpan.FromSeconds(2)),
            processCollector: processCollector,
            timeProvider: timeProvider);
    }

    private static HerdrRuntimeMonitorSnapshot CreateSnapshot(
        HerdrRuntimeMonitorStatus status,
        ulong revision)
    {
        var pane = new HerdrPaneSnapshot(
            "pane-1",
            "terminal-1",
            "workspace-1",
            "tab-1",
            Focused: true,
            HerdrAgentStatus.Working,
            revision,
            "codex",
            "Codex",
            "Worker",
            "Z:\\HerdrOps",
            "Z:\\HerdrOps",
            "Codex");
        var state = new HerdrSessionState(
            "0.8.0-preview",
            Protocol: 19,
            ConnectionEpoch: 1,
            LastIngestSequence: 1,
            new Dictionary<string, HerdrWorkspaceSnapshot>(),
            new Dictionary<string, HerdrTabSnapshot>(),
            new Dictionary<string, HerdrPaneSnapshot>(StringComparer.Ordinal)
            {
                [pane.PaneId] = pane,
            },
            new Dictionary<string, HerdrAgentSnapshot>(),
            "workspace-1",
            "tab-1",
            "pane-1");
        return new HerdrRuntimeMonitorSnapshot(
            status,
            state,
            ServerIdentity: null,
            BootstrapCount: status == HerdrRuntimeMonitorStatus.Connected ? 1 : 0,
            EventCount: 0,
            DisconnectCount: 0,
            ReconciliationCount: 0,
            LastTransitionReason: null,
            LastTransitionUtc: Utc(12, 0, 0));
    }

    private static DateTimeOffset Utc(int hour, int minute, int second) =>
        new(2026, 8, 14, hour, minute, second, TimeSpan.Zero);

    private sealed class RecordingPaneClient(
        string terminalText,
        string processCommand) : IHerdrPaneInspectionClient
    {
        private readonly List<int> _maximumLines = [];

        public int TerminalReadCount { get; private set; }

        public int ProcessInfoCount { get; private set; }

        public ulong ReadRevision { get; set; } = 7;

        public int[] MaximumLines => [.. _maximumLines];

        public HerdrServerProcessIdentity? LastVerifiedServerIdentity => null;

        public Task<HerdrPaneReadResult> ReadRecentUnwrappedAsync(
            HerdrPipeEndpoint endpoint,
            string paneId,
            int maximumLines,
            CancellationToken cancellationToken)
        {
            TerminalReadCount++;
            _maximumLines.Add(maximumLines);
            return Task.FromResult(new HerdrPaneReadResult(
                paneId,
                "workspace-1",
                "tab-1",
                "recent_unwrapped",
                "text",
                terminalText,
                ReadRevision,
                Truncated: false));
        }

        public Task<HerdrPaneProcessInfo> GetPaneProcessInfoAsync(
            HerdrPipeEndpoint endpoint,
            string paneId,
            CancellationToken cancellationToken)
        {
            ProcessInfoCount++;
            return Task.FromResult(new HerdrPaneProcessInfo(
                paneId,
                ShellProcessId: null,
                ForegroundProcessGroupId: 700,
                Tty: null,
                [
                    new HerdrPaneProcess(
                        ProcessId: 700,
                        Name: "dotnet",
                        Argv0: "dotnet",
                        Arguments: null,
                        CommandLine: processCommand,
                        CurrentDirectory: "Z:\\HerdrOps"),
                ]));
        }
    }

    private sealed class DeterministicProcessReader : IWindowsProcessSnapshotReader
    {
        private int _sampleNumber;

        public WindowsProcessReadResult Read(int processId, DateTimeOffset observedUtc)
        {
            _sampleNumber++;
            return new WindowsProcessReadResult(
                processId,
                new WindowsProcessSample(
                    processId,
                    Utc(9, 0, 0),
                    "dotnet",
                    observedUtc,
                    TimeSpan.FromSeconds(_sampleNumber),
                    WorkingSetBytes: 64 * 1024 * 1024,
                    PrivateMemoryBytes: 32 * 1024 * 1024),
                WindowsProcessReadFailure.None);
        }
    }

    private sealed class ManualTimeProvider(DateTimeOffset initialUtc) : TimeProvider
    {
        private DateTimeOffset _utcNow = initialUtc;

        public override DateTimeOffset GetUtcNow() => _utcNow;

        public void Advance(TimeSpan value) => _utcNow = _utcNow.Add(value);
    }
}
