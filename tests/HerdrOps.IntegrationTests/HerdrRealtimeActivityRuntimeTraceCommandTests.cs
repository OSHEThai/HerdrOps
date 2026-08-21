using HerdrOps.Core;

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
}
