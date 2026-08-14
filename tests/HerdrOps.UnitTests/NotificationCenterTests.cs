using HerdrOps.Domain.Activity;
using HerdrOps.Domain.Notifications;

namespace HerdrOps.UnitTests;

[TestClass]
public sealed class NotificationCenterTests
{
    private static readonly DateTimeOffset BaseUtc = new(
        2026,
        8,
        15,
        1,
        0,
        0,
        TimeSpan.Zero);

    [TestMethod]
    public void UrgentDuplicateAppearsOnceAndRetainsExactEventAgentAndTaskRoute()
    {
        var pipeline = new ActivityEventPipeline();
        var center = new NotificationCenter();
        var activity = CreateEvent(
            sourceEventId: "alert-1",
            sourceSequence: 1,
            observedUtc: BaseUtc,
            urgency: ActivityUrgency.Critical,
            agentTerminalId: "terminal-7",
            taskId: "TASK-113");
        var accepted = pipeline.Process(activity);
        var duplicate = pipeline.Process(activity);

        var first = center.Accept(accepted);
        var second = center.Accept(duplicate);
        var replayedAcceptedStep = center.Accept(accepted);
        var snapshot = center.Snapshot();

        Assert.AreEqual(NotificationCenterDisposition.Added, first.Disposition);
        Assert.IsTrue(first.ShowPopup);
        Assert.AreEqual("alert-1", first.Item?.SourceEventId);
        Assert.AreEqual("terminal-7", first.Item?.AgentTerminalId);
        Assert.AreEqual("TASK-113", first.Item?.TaskId);
        Assert.AreEqual(NotificationCenterDisposition.IgnoredPipelineDisposition, second.Disposition);
        Assert.IsFalse(second.ShowPopup);
        Assert.AreEqual(NotificationCenterDisposition.Duplicate, replayedAcceptedStep.Disposition);
        Assert.IsFalse(replayedAcceptedStep.ShowPopup);
        Assert.HasCount(1, snapshot.History);
        Assert.AreEqual(1L, snapshot.Diagnostics.ImmediatePresentationCount);
    }

    [TestMethod]
    public void NoisyUrgentBurstGroupsSuppressesPopupsAndStaysWithinEveryBound()
    {
        var options = new NotificationCenterOptions(
            MaximumHistory: 8,
            MaximumRememberedIdentities: 12,
            MaximumVisibleGroups: 3,
            UrgentGroupSuppressionWindow: TimeSpan.FromSeconds(30),
            MaximumRememberedPresentationGroups: 6);
        var center = new NotificationCenter(options);
        var pipeline = new ActivityEventPipeline(new ActivityPipelineOptions(
            TimeSpan.FromMilliseconds(50),
            MaximumOpenDebounceBuckets: 4,
            MaximumDeduplicationEntries: 64,
            MaximumTrackedSourceStreams: 8,
            MaximumReplayEvents: 100));

        var popupCount = 0;
        for (var index = 0; index < 40; index++)
        {
            var step = pipeline.Process(CreateEvent(
                sourceEventId: $"noise-{index}",
                sourceSequence: index + 1,
                observedUtc: BaseUtc.AddMilliseconds(index * 100),
                urgency: ActivityUrgency.High,
                agentTerminalId: "terminal-2",
                taskId: "TASK-15"));
            if (center.Accept(step).ShowPopup)
            {
                popupCount++;
            }
        }

        var snapshot = center.Snapshot();

        Assert.AreEqual(1, popupCount);
        Assert.HasCount(8, snapshot.History);
        Assert.HasCount(1, snapshot.Groups);
        Assert.AreEqual(8, snapshot.Groups[0].EventCount);
        Assert.AreEqual(40L, snapshot.Diagnostics.AcceptedEventCount);
        Assert.AreEqual(39L, snapshot.Diagnostics.SuppressedUrgentPresentationCount);
        Assert.IsLessThanOrEqualTo(8, snapshot.Diagnostics.PeakHistoryCount);
        Assert.IsLessThanOrEqualTo(12, snapshot.Diagnostics.PeakRememberedIdentityCount);
        Assert.IsLessThanOrEqualTo(3, snapshot.Diagnostics.PeakVisibleGroupCount);
        Assert.IsLessThanOrEqualTo(
            6,
            snapshot.Diagnostics.PeakRememberedPresentationGroupCount);
    }

    [TestMethod]
    public void AcknowledgementIsIdempotentAndRemainsInBoundedHistory()
    {
        var pipeline = new ActivityEventPipeline();
        var center = new NotificationCenter();
        var first = center.Accept(pipeline.Process(CreateEvent(
            sourceEventId: "ack-1",
            sourceSequence: 1,
            observedUtc: BaseUtc,
            urgency: ActivityUrgency.High,
            agentTerminalId: "terminal-1",
            taskId: "TASK-1")));
        var acknowledgedUtc = BaseUtc.AddSeconds(1);

        Assert.IsTrue(center.Acknowledge(first.Item!.NotificationId, acknowledgedUtc));
        Assert.IsTrue(center.Acknowledge(first.Item.NotificationId, acknowledgedUtc.AddSeconds(1)));
        var snapshot = center.Snapshot();

        Assert.IsTrue(snapshot.History[0].IsAcknowledged);
        Assert.AreEqual(acknowledgedUtc, snapshot.History[0].AcknowledgedUtc);
        Assert.AreEqual(0, snapshot.Groups[0].UnacknowledgedCount);
        Assert.AreEqual(1L, snapshot.Diagnostics.AcknowledgementCount);
    }

    [TestMethod]
    public void GroupAcknowledgementCoversExistingItemsButNewEventBecomesUnacknowledged()
    {
        var pipeline = new ActivityEventPipeline();
        var center = new NotificationCenter();
        var first = center.Accept(pipeline.Process(CreateEvent(
            "group-1",
            1,
            BaseUtc,
            ActivityUrgency.High,
            "terminal-1",
            "TASK-1")));
        _ = center.Accept(pipeline.Process(CreateEvent(
            "group-2",
            2,
            BaseUtc.AddSeconds(1),
            ActivityUrgency.High,
            "terminal-1",
            "TASK-1")));

        Assert.AreEqual(2, center.AcknowledgeGroup(first.Group!.GroupId, BaseUtc.AddSeconds(2)));
        _ = center.Accept(pipeline.Process(CreateEvent(
            "group-3",
            3,
            BaseUtc.AddSeconds(3),
            ActivityUrgency.High,
            "terminal-1",
            "TASK-1")));
        var snapshot = center.Snapshot();

        Assert.HasCount(1, snapshot.Groups);
        Assert.AreEqual(3, snapshot.Groups[0].EventCount);
        Assert.AreEqual(1, snapshot.Groups[0].UnacknowledgedCount);
        Assert.IsFalse(snapshot.Groups[0].LatestItem.IsAcknowledged);
        Assert.AreEqual(2, snapshot.History.Count(item => item.IsAcknowledged));
    }

    [TestMethod]
    public void HiddenGroupKeepsFloodSuppressionUntilPresentationMemoryBoundEvictsIt()
    {
        var center = new NotificationCenter(new NotificationCenterOptions(
            MaximumHistory: 64,
            MaximumRememberedIdentities: 128,
            MaximumVisibleGroups: 3,
            UrgentGroupSuppressionWindow: TimeSpan.FromSeconds(30),
            MaximumRememberedPresentationGroups: 40));
        var pipeline = new ActivityEventPipeline();
        var original = center.Accept(pipeline.Process(CreateEvent(
            "original-1",
            1,
            BaseUtc,
            ActivityUrgency.High,
            "terminal-original",
            "TASK-ORIGINAL")));
        Assert.IsTrue(original.ShowPopup);

        for (var index = 0; index < 35; index++)
        {
            _ = center.Accept(pipeline.Process(CreateEvent(
                $"other-{index}",
                index + 2,
                BaseUtc.AddMilliseconds(index + 1),
                ActivityUrgency.High,
                $"terminal-{index}",
                $"TASK-{index}")));
        }

        var repeatedGroup = center.Accept(pipeline.Process(CreateEvent(
            "original-2",
            37,
            BaseUtc.AddSeconds(10),
            ActivityUrgency.High,
            "terminal-original",
            "TASK-ORIGINAL")));
        var snapshot = center.Snapshot();

        Assert.IsFalse(repeatedGroup.ShowPopup);
        Assert.AreEqual(NotificationCenterDisposition.Grouped, repeatedGroup.Disposition);
        Assert.HasCount(3, snapshot.Groups);
        Assert.AreEqual(0L, snapshot.Diagnostics.PresentationGroupEvictionCount);
        Assert.AreEqual(36, snapshot.Diagnostics.CurrentRememberedPresentationGroupCount);
    }

    private static ActivityEventEnvelope CreateEvent(
        string sourceEventId,
        long sourceSequence,
        DateTimeOffset observedUtc,
        ActivityUrgency urgency,
        string? agentTerminalId,
        string? taskId) =>
        new(
            ActivityEventContract.Version,
            sourceEventId,
            ActivitySourceKind.HerdrOpsCore,
            "notification-tests",
            "epoch-1",
            sourceSequence,
            ActivityConfidence.Observed,
            urgency,
            ActivityDeliveryMode.Immediate,
            "scope-violation",
            observedUtc,
            observedUtc,
            Guid.Parse("8da1c9b6-4ee7-4d9f-b43a-e8af5ed6e043"),
            DebounceKey: null,
            agentTerminalId,
            PaneId: "pane-1",
            taskId,
            ProcessId: 1200,
            RedactedSummary: "A redacted scope alert",
            PayloadSha256: new string('A', 64));
}
