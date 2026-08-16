using HerdrOps.App.RuntimeEvidence;

namespace HerdrOps.RuntimeTests;

[TestClass]
public sealed class RuntimeEvidenceQuiescenceTests
{
    private static readonly DateTimeOffset Start = new(
        2026,
        8,
        16,
        10,
        0,
        0,
        TimeSpan.Zero);

    [TestMethod]
    public void StableLiveStateCompletesOnlyAfterTheFullWindow()
    {
        var tracker = new RuntimeIdleQuiescenceTracker(requiredStableSeconds: 5);

        Assert.IsNull(tracker.Observe(Start, isLive: true, sequence: 13, eventCount: 3));
        Assert.IsNull(tracker.Observe(
            Start.AddMilliseconds(4999),
            isLive: true,
            sequence: 13,
            eventCount: 3));

        var result = tracker.Observe(
            Start.AddSeconds(5),
            isLive: true,
            sequence: 13,
            eventCount: 3);

        Assert.IsNotNull(result);
        Assert.AreEqual(13, result.StableSequence);
        Assert.AreEqual(3, result.StableEventCount);
        Assert.AreEqual(0, result.ResetCount);
    }

    [TestMethod]
    public void SequenceAdvanceResetsTheWindowAndPreservesItsProvenance()
    {
        var tracker = new RuntimeIdleQuiescenceTracker(requiredStableSeconds: 5);
        _ = tracker.Observe(Start, isLive: true, sequence: 13, eventCount: 3);
        Assert.IsNull(tracker.Observe(
            Start.AddSeconds(4),
            isLive: true,
            sequence: 14,
            eventCount: 3));
        Assert.IsNull(tracker.Observe(
            Start.AddSeconds(8),
            isLive: true,
            sequence: 14,
            eventCount: 3));

        var result = tracker.Observe(
            Start.AddSeconds(9),
            isLive: true,
            sequence: 14,
            eventCount: 3);

        Assert.IsNotNull(result);
        Assert.AreEqual(1, result.ResetCount);
        Assert.AreEqual("StateOrEventAdvanced", result.Resets[0].Reason);
        Assert.AreEqual(13, result.Resets[0].PreviousSequence);
        Assert.AreEqual(14, result.Resets[0].CurrentSequence);
    }

    [TestMethod]
    public void EventAdvanceResetsTheWindowWithoutSubtractingEventCredit()
    {
        var tracker = new RuntimeIdleQuiescenceTracker(requiredStableSeconds: 5);
        _ = tracker.Observe(Start, isLive: true, sequence: 13, eventCount: 3);
        Assert.IsNull(tracker.Observe(
            Start.AddSeconds(2),
            isLive: true,
            sequence: 17,
            eventCount: 4));

        var result = tracker.Observe(
            Start.AddSeconds(7),
            isLive: true,
            sequence: 17,
            eventCount: 4);

        Assert.IsNotNull(result);
        Assert.AreEqual(4, result.StableEventCount);
        Assert.AreEqual(3, result.Resets[0].PreviousEventCount);
        Assert.AreEqual(4, result.Resets[0].CurrentEventCount);
    }

    [TestMethod]
    public void LostAndRestoredLiveStateEachResetTheWindow()
    {
        var tracker = new RuntimeIdleQuiescenceTracker(requiredStableSeconds: 5);
        _ = tracker.Observe(Start, isLive: true, sequence: 13, eventCount: 3);
        Assert.IsNull(tracker.Observe(
            Start.AddSeconds(2),
            isLive: false,
            sequence: 13,
            eventCount: 3));
        Assert.IsNull(tracker.Observe(
            Start.AddSeconds(3),
            isLive: true,
            sequence: 18,
            eventCount: 4));

        var result = tracker.Observe(
            Start.AddSeconds(8),
            isLive: true,
            sequence: 18,
            eventCount: 4);

        Assert.IsNotNull(result);
        CollectionAssert.AreEqual(
            new[] { "LiveStateLost", "LiveStateRestored" },
            result.Resets.Select(reset => reset.Reason).ToArray());
    }

    [TestMethod]
    public void ObservationTimeCannotMoveBackward()
    {
        var tracker = new RuntimeIdleQuiescenceTracker(requiredStableSeconds: 5);
        _ = tracker.Observe(Start, isLive: true, sequence: 13, eventCount: 3);
        _ = tracker.Observe(
            Start.AddSeconds(4),
            isLive: true,
            sequence: 13,
            eventCount: 3);

        Assert.ThrowsExactly<ArgumentOutOfRangeException>(() => tracker.Observe(
            Start.AddSeconds(3),
            isLive: true,
            sequence: 13,
            eventCount: 3));
    }
}
