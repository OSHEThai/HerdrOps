using HerdrOps.Core;
using HerdrOps.Domain.Activity;
using HerdrOps.Domain.Herdr;

namespace HerdrOps.IntegrationTests;

[TestClass]
public sealed class HerdrRealtimeActivityRuntimeTraceCommandTests
{
    [TestMethod]
    public void TransitionKeyRetentionHasAnExplicitFifoBound()
    {
        var keys = new BoundedTransitionKeySet(capacity: 3);

        Assert.IsTrue(keys.TryAdd("pane-a:1"));
        Assert.IsTrue(keys.TryAdd("pane-a:2"));
        Assert.IsTrue(keys.TryAdd("pane-a:3"));
        Assert.AreEqual(3, keys.Count);
        Assert.IsFalse(keys.TryAdd("pane-a:2"));
        Assert.AreEqual(3, keys.Count);

        Assert.IsTrue(keys.TryAdd("pane-a:4"));
        Assert.AreEqual(3, keys.Count);
        Assert.IsTrue(keys.TryAdd("pane-a:1"), "The oldest key is eligible again only after FIFO eviction.");
        Assert.AreEqual(3, keys.Count);
    }

    [TestMethod]
    public void OnStateChangedRetainsOnlyBoundedEventWindowForAnAdversarialStream()
    {
        var capture = new HerdrRealtimeActivityRuntimeTraceCapture("adversarial-runtime-sha");
        var totalEvents = HerdrRealtimeActivityRuntimeTraceCommand.MaximumRetainedEvents + 257;

        for (var eventCount = 1L; eventCount <= totalEvents; eventCount++)
        {
            capture.OnStateChanged(null, CreateAcceptedSnapshot(eventCount));
        }

        var retained = capture.RetainedEvents;
        Assert.AreEqual(
            HerdrRealtimeActivityRuntimeTraceCommand.MaximumRetainedEvents,
            capture.RetainedEventCount);
        Assert.HasCount(
            HerdrRealtimeActivityRuntimeTraceCommand.MaximumRetainedEvents,
            retained);
        Assert.AreEqual(totalEvents, capture.AcceptedEventCount);
        Assert.AreEqual(
            totalEvents - HerdrRealtimeActivityRuntimeTraceCommand.MaximumRetainedEvents + 1,
            retained[0].HerdrEventCount);
        Assert.AreEqual(totalEvents, retained[^1].HerdrEventCount);
    }

    [TestMethod]
    public void AcceptedCountIsRetentionWindowedWhenBothDedupeCachesEvict()
    {
        var capture = new HerdrRealtimeActivityRuntimeTraceCapture(
            "adversarial-runtime-sha",
            ActivityPipelineOptions.Default with
            {
                MaximumDeduplicationEntries = 2,
            });
        var uniqueEvents = HerdrRealtimeActivityRuntimeTraceCommand.MaximumSeenTransitionKeys + 2;

        for (var eventCount = 1L; eventCount <= uniqueEvents; eventCount++)
        {
            capture.OnStateChanged(null, CreateAcceptedSnapshot(eventCount));
        }

        Assert.AreEqual(uniqueEvents, capture.AcceptedEventCount);
        capture.OnStateChanged(null, CreateAcceptedSnapshot(1));

        Assert.AreEqual(
            uniqueEvents + 1,
            capture.AcceptedEventCount,
            "AcceptedEventCount is a pipeline-disposition count with retention-windowed identity suppression; it is not an absolute unique-transition count.");
        Assert.AreEqual(
            HerdrRealtimeActivityRuntimeTraceCommand.MaximumRetainedEvents,
            capture.RetainedEventCount);
        Assert.AreEqual(1L, capture.RetainedEvents[^1].HerdrEventCount);
    }

    [TestMethod]
    public void TransitionKeyRetentionRemainsBoundedForAnAdversarialUniqueStream()
    {
        var keys = new BoundedTransitionKeySet(HerdrRealtimeActivityRuntimeTraceCommand.MaximumSeenTransitionKeys);

        for (var index = 0; index < 100_000; index++)
        {
            Assert.IsTrue(keys.TryAdd($"pane-adversarial:{index}"));
        }

        Assert.AreEqual(HerdrRealtimeActivityRuntimeTraceCommand.MaximumSeenTransitionKeys, keys.Count);
        Assert.AreEqual(HerdrRealtimeActivityRuntimeTraceCommand.MaximumSeenTransitionKeys, keys.Capacity);
    }

    [TestMethod]
    public void LatencyRetentionKeepsOnlyFirstAndMaximumForAnAdversarialStream()
    {
        var latencies = new BoundedLatencyAccumulator();

        for (var index = 0; index < 100_000; index++)
        {
            latencies.Add(index);
        }

        Assert.AreEqual(100_000L, latencies.ObservedCount);
        Assert.AreEqual(0d, latencies.First);
        Assert.AreEqual(99_999d, latencies.Maximum);
        Assert.AreEqual(HerdrRealtimeActivityRuntimeTraceCommand.MaximumLatencyAccumulatorValues, latencies.RetainedValueCount);
    }

    [TestMethod]
    public void LatencyRetentionRejectsNonFiniteAndNegativeValues()
    {
        var latencies = new BoundedLatencyAccumulator();

        Assert.ThrowsExactly<ArgumentOutOfRangeException>(() => latencies.Add(-0.1d));
        Assert.ThrowsExactly<ArgumentOutOfRangeException>(() => latencies.Add(double.NaN));
        Assert.ThrowsExactly<ArgumentOutOfRangeException>(() => latencies.Add(double.PositiveInfinity));
        Assert.AreEqual(0L, latencies.ObservedCount);
        Assert.AreEqual(0, latencies.RetainedValueCount);
    }

    [TestMethod]
    public void RuntimeTraceRetentionBoundsAreExplicitAndAligned()
    {
        var bounds = new HerdrRealtimeActivityRuntimeTraceRetentionBounds(
            HerdrRealtimeActivityRuntimeTraceCommand.MaximumRetainedEvents,
            HerdrRealtimeActivityRuntimeTraceCommand.MaximumSeenTransitionKeys,
            HerdrRealtimeActivityRuntimeTraceCommand.MaximumLatencyAccumulatorValues);

        Assert.AreEqual(4096, bounds.MaximumRetainedEvents);
        Assert.AreEqual(4096, bounds.MaximumSeenTransitionKeys);
        Assert.AreEqual(2, bounds.MaximumLatencyAccumulatorValues);
        Assert.AreEqual(
            BoundedLatencyAccumulator.MaximumRetainedValues,
            bounds.MaximumLatencyAccumulatorValues);
    }

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

    private static HerdrRuntimeMonitorSnapshot CreateAcceptedSnapshot(long eventCount)
    {
        var pane = new HerdrPaneSnapshot(
            "pane-1",
            "terminal-1",
            "workspace-1",
            "tab-1",
            Focused: true,
            HerdrAgentStatus.Working,
            (ulong)eventCount,
            "codex",
            "Codex",
            "Worker",
            "Z:\\HerdrOps",
            "Z:\\HerdrOps",
            "Codex");
        var state = HerdrSessionState.Empty with
        {
            ConnectionEpoch = 1,
            LastIngestSequence = eventCount,
            Panes = new Dictionary<string, HerdrPaneSnapshot>(StringComparer.Ordinal)
            {
                [pane.PaneId] = pane,
            },
        };
        var occurredUtc = DateTimeOffset.UtcNow.AddMilliseconds(-1);
        return new HerdrRuntimeMonitorSnapshot(
            HerdrRuntimeMonitorStatus.Connected,
            state,
            ServerIdentity: null,
            BootstrapCount: 1,
            EventCount: eventCount,
            DisconnectCount: 0,
            ReconciliationCount: 0,
            LastTransitionReason: null,
            LastTransitionUtc: occurredUtc)
        {
            AcceptedEventKind = HerdrRuntimeMonitor.AcceptedAgentStatusEventKind,
            AcceptedAgentStatusEvent = new HerdrAcceptedAgentStatusEvent(
                "workspace-1",
                "pane-1",
                HerdrAgentStatus.Working,
                "codex",
                "Codex",
                "Worker"),
        };
    }
}
