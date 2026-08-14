using System.Diagnostics;
using System.Text.Json;
using HerdrOps.Domain.Activity;
using HerdrOps.Infrastructure.Activity;
using HerdrOps.Infrastructure.Herdr;

namespace HerdrOps.IntegrationTests;

[TestClass]
public sealed class WindowsProcessTelemetryTests
{
    [TestMethod]
    public void CorrelationReadsOnlyHerdrReportedPidsAndRedactsCommandMetadata()
    {
        const string secret = "terminal-process-secret-123456";
        var observedUtc = Utc(12, 0, 0);
        var reader = new RecordingProcessReader(processId => Available(processId, observedUtc));
        var collector = new WindowsProcessCorrelationCollector(
            reader,
            new WindowsProcessTelemetryTracker(new WindowsProcessTelemetryOptions(
                TimeSpan.FromSeconds(10),
                MaximumTrackedProcesses: 8,
                ProcessorCount: 4)),
            new SensitiveTextRedactor());
        var processInfo = new HerdrPaneProcessInfo(
            "pane-1",
            ShellProcessId: 100,
            ForegroundProcessGroupId: 101,
            Tty: null,
            [
                new HerdrPaneProcess(
                    ProcessId: 101,
                    Name: "dotnet",
                    Argv0: "dotnet",
                    Arguments: ["dotnet", "build", $"API_KEY={secret}"],
                    CommandLine: $"dotnet build API_KEY={secret}",
                    CurrentDirectory: "Z:\\HerdrOps"),
            ]);

        var batch = collector.Collect(processInfo, observedUtc);

        CollectionAssert.AreEqual(new[] { 100, 101 }, reader.RequestedProcessIds);
        Assert.HasCount(2, batch.Observations);
        Assert.HasCount(0, batch.Failures);
        var foreground = batch.Observations.Single(item => item.ProcessId == 101);
        Assert.AreEqual(HerdrReportedProcessSource.Foreground, foreground.ReportedSource);
        Assert.AreEqual("dotnet", foreground.ReportedProcessName);
        Assert.AreEqual(observedUtc.AddSeconds(10), foreground.ExpiresUtc);
        Assert.AreEqual(1, foreground.CommandRedactionCount);
        StringAssert.Contains(foreground.RedactedCommandSummary, "API_KEY=[REDACTED]");
        Assert.IsFalse(JsonSerializer.Serialize(batch).Contains(secret, StringComparison.Ordinal));
    }

    [TestMethod]
    public void CpuUsesPidAndStartTimeAndPidReuseStartsWithNoBaseline()
    {
        var tracker = new WindowsProcessTelemetryTracker(new WindowsProcessTelemetryOptions(
            TimeSpan.FromSeconds(10),
            MaximumTrackedProcesses: 8,
            ProcessorCount: 2));
        var redactor = new SensitiveTextRedactor();
        var startUtc = Utc(10, 0, 0);
        var first = Sample(501, startUtc, Utc(12, 0, 0), totalCpuSeconds: 1);
        var second = Sample(501, startUtc, Utc(12, 0, 2), totalCpuSeconds: 2);
        var reused = Sample(501, startUtc.AddMinutes(1), Utc(12, 0, 3), totalCpuSeconds: 0);

        var firstObservation = tracker.Observe(
            "pane-1", HerdrReportedProcessSource.Foreground, "agent", "agent", first, redactor);
        var secondObservation = tracker.Observe(
            "pane-1", HerdrReportedProcessSource.Foreground, "agent", "agent", second, redactor);
        var reusedObservation = tracker.Observe(
            "pane-1", HerdrReportedProcessSource.Foreground, "agent", "agent", reused, redactor);

        Assert.IsNull(firstObservation.CpuPercent);
        Assert.AreEqual(25d, secondObservation.CpuPercent);
        Assert.IsNull(reusedObservation.CpuPercent);
        Assert.AreEqual(startUtc.AddMinutes(1), reusedObservation.ProcessStartUtc);
        Assert.AreEqual(1, tracker.TrackedProcessCount);
    }

    [TestMethod]
    public void TelemetryExpiresAtItsExplicitTimeToLive()
    {
        var tracker = new WindowsProcessTelemetryTracker(new WindowsProcessTelemetryOptions(
            TimeSpan.FromSeconds(5),
            MaximumTrackedProcesses: 8,
            ProcessorCount: 1));
        var observedUtc = Utc(12, 0, 0);
        _ = tracker.Observe(
            "pane-1",
            HerdrReportedProcessSource.Shell,
            "pwsh",
            "pwsh",
            Sample(601, Utc(9, 0, 0), observedUtc, totalCpuSeconds: 1),
            new SensitiveTextRedactor());

        Assert.HasCount(1, tracker.Snapshot(observedUtc.AddSeconds(4.999)));
        Assert.AreEqual(1, tracker.Expire(observedUtc.AddSeconds(5)));
        Assert.HasCount(0, tracker.Snapshot(observedUtc.AddSeconds(5)));
    }

    [TestMethod]
    public void CorrelationReportsUnavailablePidWithoutInventingTelemetry()
    {
        var observedUtc = Utc(12, 0, 0);
        var reader = new RecordingProcessReader(processId => new WindowsProcessReadResult(
            processId,
            null,
            WindowsProcessReadFailure.ProcessNotFound));
        var collector = new WindowsProcessCorrelationCollector(reader);
        var processInfo = new HerdrPaneProcessInfo(
            "pane-missing",
            ShellProcessId: null,
            ForegroundProcessGroupId: null,
            Tty: null,
            [new HerdrPaneProcess(404, "missing", null, null, null, null)]);

        var batch = collector.Collect(processInfo, observedUtc);

        Assert.HasCount(0, batch.Observations);
        Assert.HasCount(1, batch.Failures);
        Assert.AreEqual((uint)404, batch.Failures[0].ReportedProcessId);
        Assert.AreEqual(WindowsProcessReadFailure.ProcessNotFound, batch.Failures[0].Failure);
    }

    [TestMethod]
    public void WindowsReaderSamplesTheCurrentProcessWithStableIdentity()
    {
        using var process = Process.GetCurrentProcess();
        var observedUtc = DateTimeOffset.UtcNow;

        var result = new WindowsProcessSnapshotReader().Read(process.Id, observedUtc);

        Assert.IsTrue(result.IsAvailable);
        Assert.IsNotNull(result.Sample);
        Assert.AreEqual(process.Id, result.Sample.ProcessId);
        Assert.AreEqual(observedUtc, result.Sample.ObservedUtc);
        Assert.IsGreaterThan(DateTimeOffset.UnixEpoch, result.Sample.ProcessStartUtc);
        Assert.IsGreaterThanOrEqualTo(0L, result.Sample.WorkingSetBytes);
        Assert.IsGreaterThanOrEqualTo(0L, result.Sample.PrivateMemoryBytes);
    }

    private static WindowsProcessReadResult Available(int processId, DateTimeOffset observedUtc) =>
        new(
            processId,
            Sample(processId, Utc(9, 0, 0), observedUtc, totalCpuSeconds: 1),
            WindowsProcessReadFailure.None);

    private static WindowsProcessSample Sample(
        int processId,
        DateTimeOffset startUtc,
        DateTimeOffset observedUtc,
        double totalCpuSeconds) =>
        new(
            processId,
            startUtc,
            "process-" + processId,
            observedUtc,
            TimeSpan.FromSeconds(totalCpuSeconds),
            WorkingSetBytes: 64 * 1024 * 1024,
            PrivateMemoryBytes: 32 * 1024 * 1024);

    private static DateTimeOffset Utc(int hour, int minute, int second) =>
        new(2026, 8, 14, hour, minute, second, TimeSpan.Zero);

    private sealed class RecordingProcessReader(
        Func<int, WindowsProcessReadResult> read) : IWindowsProcessSnapshotReader
    {
        private readonly List<int> _requestedProcessIds = [];

        public int[] RequestedProcessIds => [.. _requestedProcessIds];

        public WindowsProcessReadResult Read(int processId, DateTimeOffset observedUtc)
        {
            _requestedProcessIds.Add(processId);
            return read(processId);
        }
    }
}
