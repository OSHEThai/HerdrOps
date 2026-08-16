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

        Assert.IsNull(tracker.Observe(Start, Fingerprint()));
        Assert.IsNull(tracker.Observe(
            Start.AddMilliseconds(4999),
            Fingerprint()));

        var result = tracker.Observe(
            Start.AddSeconds(5),
            Fingerprint());

        Assert.IsNotNull(result);
        Assert.AreEqual(13, result.StableSequence);
        Assert.AreEqual(3, result.StableEventCount);
        Assert.AreEqual(0, result.ResetCount);
    }

    [TestMethod]
    public void SequenceAdvanceResetsTheWindowAndPreservesItsProvenance()
    {
        var tracker = new RuntimeIdleQuiescenceTracker(requiredStableSeconds: 5);
        _ = tracker.Observe(Start, Fingerprint());
        Assert.IsNull(tracker.Observe(
            Start.AddSeconds(4),
            Fingerprint(sequence: 14)));
        Assert.IsNull(tracker.Observe(
            Start.AddSeconds(8),
            Fingerprint(sequence: 14)));

        var result = tracker.Observe(
            Start.AddSeconds(9),
            Fingerprint(sequence: 14));

        Assert.IsNotNull(result);
        Assert.AreEqual(1, result.ResetCount);
        Assert.AreEqual("RuntimeFingerprintChanged", result.Resets[0].Reason);
        Assert.AreEqual(13, result.Resets[0].PreviousSequence);
        Assert.AreEqual(14, result.Resets[0].CurrentSequence);
    }

    [TestMethod]
    public void EventAdvanceResetsTheWindowWithoutSubtractingEventCredit()
    {
        var tracker = new RuntimeIdleQuiescenceTracker(requiredStableSeconds: 5);
        _ = tracker.Observe(Start, Fingerprint());
        Assert.IsNull(tracker.Observe(
            Start.AddSeconds(2),
            Fingerprint(sequence: 17, eventCount: 4)));

        var result = tracker.Observe(
            Start.AddSeconds(7),
            Fingerprint(sequence: 17, eventCount: 4));

        Assert.IsNotNull(result);
        Assert.AreEqual(4, result.StableEventCount);
        Assert.AreEqual(3, result.Resets[0].PreviousEventCount);
        Assert.AreEqual(4, result.Resets[0].CurrentEventCount);
    }

    [TestMethod]
    public void LostAndRestoredLiveStateEachResetTheWindow()
    {
        var tracker = new RuntimeIdleQuiescenceTracker(requiredStableSeconds: 5);
        _ = tracker.Observe(Start, Fingerprint());
        Assert.IsNull(tracker.Observe(
            Start.AddSeconds(2),
            Fingerprint(isLive: false)));
        Assert.IsNull(tracker.Observe(
            Start.AddSeconds(3),
            Fingerprint(sequence: 18, eventCount: 4)));

        var result = tracker.Observe(
            Start.AddSeconds(8),
            Fingerprint(sequence: 18, eventCount: 4));

        Assert.IsNotNull(result);
        CollectionAssert.AreEqual(
            new[] { "LiveStateLost", "LiveStateRestored" },
            result.Resets.Select(reset => reset.Reason).ToArray());
    }

    [TestMethod]
    public void NonSequenceFingerprintChangeResetsTheWindow()
    {
        var tracker = new RuntimeIdleQuiescenceTracker(requiredStableSeconds: 5);
        _ = tracker.Observe(Start, Fingerprint());
        Assert.IsNull(tracker.Observe(
            Start.AddSeconds(4),
            Fingerprint(reconciliationCount: 2)));

        var result = tracker.Observe(
            Start.AddSeconds(9),
            Fingerprint(reconciliationCount: 2));

        Assert.IsNotNull(result);
        Assert.AreEqual(1, result.ResetCount);
        Assert.AreEqual(
            2,
            result.Resets[0].CurrentFingerprint.ReconciliationCount);
    }

    [TestMethod]
    public void ObservationTimeCannotMoveBackward()
    {
        var tracker = new RuntimeIdleQuiescenceTracker(requiredStableSeconds: 5);
        _ = tracker.Observe(Start, Fingerprint());
        _ = tracker.Observe(
            Start.AddSeconds(4),
            Fingerprint());

        Assert.ThrowsExactly<ArgumentOutOfRangeException>(() => tracker.Observe(
            Start.AddSeconds(3),
            Fingerprint()));
    }

    private static RuntimeStateFingerprint Fingerprint(
        bool isLive = true,
        long sequence = 13,
        long eventCount = 3,
        long reconciliationCount = 1) => new(
            IsCoreConnected: isLive,
            IsLive: isLive,
            RuntimeStatus: isLive ? "Live" : "Reconnecting",
            LastTransitionUtc: Start.AddMinutes(-1),
            LastAcceptedStateUtc: isLive ? Start.AddMinutes(-1) : null,
            ConnectionEpoch: 1,
            LastIngestSequence: sequence,
            BootstrapCount: 1,
            EventCount: eventCount,
            DisconnectCount: isLive ? 0 : 1,
            ReconciliationCount: reconciliationCount,
            StateSha256: new string(isLive ? 'A' : 'B', 64));
}
