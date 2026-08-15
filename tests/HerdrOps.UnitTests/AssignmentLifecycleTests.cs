using System.Security.Cryptography;
using System.Text;
using HerdrOps.Domain.Assignments;

namespace HerdrOps.UnitTests;

[TestClass]
public sealed class AssignmentLifecycleTests
{
    private static readonly DateTimeOffset BaseUtc =
        new(2026, 8, 15, 1, 0, 0, TimeSpan.Zero);

    [TestMethod]
    public void CompletePmLeaderWorkerReviewTraceIsDeterministicAndProvenanced()
    {
        var events = CompleteTrace();

        var first = AssignmentLifecycleReplay.Run(events);
        var second = AssignmentLifecycleReplay.Run(events);

        Assert.AreEqual(first.ResultSha256, second.ResultSha256);
        Assert.AreEqual(first.Diagnostics, second.Diagnostics);
        CollectionAssert.AreEqual(first.Steps.ToArray(), second.Steps.ToArray());
        Assert.AreEqual(7L, first.Diagnostics.ProcessedEventCount);
        Assert.AreEqual(7L, first.Diagnostics.AppliedEventCount);
        Assert.AreEqual(7L, first.Diagnostics.ConsumedSequenceCount);
        Assert.AreEqual(7L, first.Diagnostics.LastSequence);
        Assert.HasCount(1, first.CurrentTasks);
        var task = first.CurrentTasks[0];
        Assert.AreEqual(AssignmentTaskStatus.HandedOff, task.State.Status);
        Assert.AreEqual("reviewer-01", task.State.CurrentAssigneeId);
        Assert.IsNull(task.State.CurrentAssigneeRole);
        Assert.AreEqual(50, task.State.ProgressPercent);
        Assert.AreEqual(1, task.State.EvidenceCount);
        Assert.AreEqual(1, task.State.HandoffCount);
        Assert.AreEqual(events[0].EventId, task.State.Contract.AssignmentEventId);
        Assert.AreEqual(events[0].CorrelationId, task.State.Contract.CorrelationId);
        Assert.HasCount(3, first.Relationships);
        CollectionAssert.AreEqual(
            new[]
            {
                AssignmentRelationshipKind.Assignment,
                AssignmentRelationshipKind.Delegation,
                AssignmentRelationshipKind.Handoff,
            },
            first.Relationships.Select(relationship => relationship.RelationshipKind).ToArray());
        Assert.IsTrue(first.Relationships.All(relationship =>
            relationship.ProvenanceEventSha256.Length == 64 &&
            relationship.RelationshipSha256.Length == 64));
        Assert.HasCount(7, first.AuditTrail);
        Assert.IsTrue(first.AuditTrail.All(audit =>
            audit.Disposition == AssignmentLifecycleDisposition.Applied &&
            audit.ConsumesSequence &&
            audit.AuditSha256.Length == 64));
        Assert.HasCount(3, first.CurrentRoles);
        CollectionAssert.AreEqual(
            new[] { "backend-leader", "backend-worker-01", "project-manager" },
            first.CurrentRoles.Select(role => role.ActorId).ToArray());
    }

    [TestMethod]
    public void MissingAcknowledgementIsAuditedWithoutAdvancingTaskTipAndCanRecover()
    {
        var assignment = CreateEvent(
            AssignmentLifecycleEventKind.Assignment,
            sequence: 1,
            actorId: "project-manager",
            actorRole: "Project Manager",
            targetAgentId: "backend-leader");
        var prematureProgress = CreateEvent(
            AssignmentLifecycleEventKind.Progress,
            sequence: 2,
            actorId: "backend-leader",
            actorRole: "Backend Leader",
            parentEventId: assignment.EventId,
            progressPercent: 10);
        var acknowledgement = CreateEvent(
            AssignmentLifecycleEventKind.Acknowledgement,
            sequence: 3,
            actorId: "backend-leader",
            actorRole: "Backend Leader",
            parentEventId: assignment.EventId);

        var replay = AssignmentLifecycleReplay.Run(
            [assignment, prematureProgress, acknowledgement]);

        Assert.AreEqual(
            AssignmentLifecycleDisposition.InvalidTransition,
            replay.Steps[1].Audit.Disposition);
        Assert.AreEqual("missing-acknowledgement", replay.Steps[1].Audit.Code);
        Assert.AreEqual(
            replay.Steps[0].CurrentTask!.StateSha256,
            replay.Steps[1].CurrentTask!.StateSha256);
        Assert.AreEqual(
            AssignmentLifecycleDisposition.Applied,
            replay.Steps[2].Audit.Disposition);
        Assert.AreEqual(AssignmentTaskStatus.Acknowledged, replay.CurrentTasks[0].State.Status);
        Assert.AreEqual(3L, replay.Diagnostics.ConsumedSequenceCount);
        Assert.AreEqual(1L, replay.Diagnostics.InvalidTransitionCount);
    }

    [TestMethod]
    public void OrphanTaskAndParentRemainVisibleInAuditTrail()
    {
        var orphanTask = CreateEvent(
            AssignmentLifecycleEventKind.Acknowledgement,
            sequence: 1,
            taskId: "TASK-404",
            actorId: "worker-404",
            actorRole: "Worker",
            parentEventId: GuidFor(900));
        var assignment = CreateEvent(
            AssignmentLifecycleEventKind.Assignment,
            sequence: 2,
            actorId: "project-manager",
            actorRole: "Project Manager",
            targetAgentId: "backend-leader");
        var orphanParent = CreateEvent(
            AssignmentLifecycleEventKind.Acknowledgement,
            sequence: 3,
            actorId: "backend-leader",
            actorRole: "Backend Leader",
            parentEventId: GuidFor(901));

        var replay = AssignmentLifecycleReplay.Run([orphanTask, assignment, orphanParent]);

        CollectionAssert.AreEqual(
            new[]
            {
                AssignmentLifecycleDisposition.OrphanTask,
                AssignmentLifecycleDisposition.Applied,
                AssignmentLifecycleDisposition.OrphanParent,
            },
            replay.AuditTrail.Select(audit => audit.Disposition).ToArray());
        Assert.AreEqual(2L, replay.Diagnostics.OrphanEventCount);
        Assert.HasCount(1, replay.CurrentTasks);
        Assert.AreEqual(assignment.EventId, replay.CurrentTasks[0].State.LastEventId);
    }

    [TestMethod]
    public void SecondHandoffBeforeAcknowledgementIsExplicitlyVisible()
    {
        var events = CompleteTrace().ToList();
        var firstHandoff = events[^1];
        events.Add(CreateEvent(
            AssignmentLifecycleEventKind.Handoff,
            sequence: 8,
            actorId: "backend-worker-01",
            actorRole: "Backend Worker",
            parentEventId: firstHandoff.EventId,
            targetAgentId: "reviewer-02",
            handoffNote: "A second handoff should be rejected."));

        var replay = AssignmentLifecycleReplay.Run(events);
        var duplicate = replay.Steps[^1];

        Assert.AreEqual(
            AssignmentLifecycleDisposition.DuplicateHandoff,
            duplicate.Audit.Disposition);
        Assert.AreEqual("duplicate-handoff", duplicate.Audit.Code);
        Assert.IsTrue(duplicate.Audit.ConsumesSequence);
        Assert.AreEqual(1L, replay.Diagnostics.DuplicateHandoffCount);
        Assert.AreEqual("reviewer-01", replay.CurrentTasks[0].State.CurrentAssigneeId);
        Assert.AreEqual(1, replay.CurrentTasks[0].State.HandoffCount);
        Assert.HasCount(3, replay.Relationships);
    }

    [TestMethod]
    public void IdenticalRetryAndIdentityConflictDoNotConsumeSequenceTwice()
    {
        var assignment = CreateEvent(
            AssignmentLifecycleEventKind.Assignment,
            sequence: 1,
            actorId: "project-manager",
            actorRole: "Project Manager",
            targetAgentId: "backend-leader");
        var changed = assignment with { Summary = "Changed assignment content." };

        var replay = AssignmentLifecycleReplay.Run([assignment, assignment, changed]);

        CollectionAssert.AreEqual(
            new[]
            {
                AssignmentLifecycleDisposition.Applied,
                AssignmentLifecycleDisposition.Duplicate,
                AssignmentLifecycleDisposition.IdentityConflict,
            },
            replay.Steps.Select(step => step.Audit.Disposition).ToArray());
        Assert.HasCount(1, replay.AuditTrail);
        Assert.AreEqual(1L, replay.Diagnostics.ConsumedSequenceCount);
        Assert.AreEqual(1L, replay.Diagnostics.DuplicateEventCount);
        Assert.AreEqual(1L, replay.Diagnostics.ConflictEventCount);
    }

    [TestMethod]
    public void SequenceGapIsConsumedAsVisibleAuditWithoutMutatingTask()
    {
        var assignment = CreateEvent(
            AssignmentLifecycleEventKind.Assignment,
            sequence: 1,
            actorId: "project-manager",
            actorRole: "Project Manager",
            targetAgentId: "backend-leader");
        var gap = CreateEvent(
            AssignmentLifecycleEventKind.Acknowledgement,
            sequence: 3,
            actorId: "backend-leader",
            actorRole: "Backend Leader",
            parentEventId: assignment.EventId);

        var replay = AssignmentLifecycleReplay.Run([assignment, gap]);

        Assert.AreEqual(
            AssignmentLifecycleDisposition.SequenceGap,
            replay.Steps[1].Audit.Disposition);
        Assert.AreEqual(3L, replay.Diagnostics.LastSequence);
        Assert.AreEqual(1L, replay.Diagnostics.SequenceGapCount);
        Assert.AreEqual(assignment.EventId, replay.CurrentTasks[0].State.LastEventId);
    }

    [TestMethod]
    public void ProgressRegressionAndStaleParentAreAuditedDeterministically()
    {
        var events = CompleteTrace().Take(5).ToList();
        var progress = events[^1];
        events.Add(CreateEvent(
            AssignmentLifecycleEventKind.Progress,
            sequence: 6,
            actorId: "backend-worker-01",
            actorRole: "Backend Worker",
            parentEventId: progress.EventId,
            progressPercent: 40));
        events.Add(CreateEvent(
            AssignmentLifecycleEventKind.Evidence,
            sequence: 7,
            actorId: "backend-worker-01",
            actorRole: "Backend Worker",
            parentEventId: GuidFor(4),
            evidenceReference: "artifacts/stale.trx",
            evidenceSha256: Hash("stale")));

        var replay = AssignmentLifecycleReplay.Run(events);

        Assert.AreEqual("progress-regression", replay.Steps[5].Audit.Code);
        Assert.AreEqual("stale-parent", replay.Steps[6].Audit.Code);
        Assert.AreEqual(2L, replay.Diagnostics.InvalidTransitionCount);
        Assert.AreEqual(50, replay.CurrentTasks[0].State.ProgressPercent);
    }

    [TestMethod]
    public void ContractRejectsCrossKindFieldsAndNonUtcTime()
    {
        var crossKind = CreateEvent(
            AssignmentLifecycleEventKind.Assignment,
            sequence: 1,
            actorId: "project-manager",
            actorRole: "Project Manager",
            targetAgentId: "backend-leader") with
        {
            ProgressPercent = 50,
        };
        var nonUtc = crossKind with
        {
            ProgressPercent = null,
            AcceptedUtc = new DateTimeOffset(2026, 8, 15, 8, 0, 0, TimeSpan.FromHours(7)),
        };
        var acceptedBeforeOccurrence = crossKind with
        {
            ProgressPercent = null,
            AcceptedUtc = crossKind.OccurredUtc.AddTicks(-1),
        };

        Assert.Throws<AssignmentLifecycleContractException>(() =>
            AssignmentLifecycleContract.NormalizeAndValidate(crossKind));
        Assert.Throws<AssignmentLifecycleContractException>(() =>
            AssignmentLifecycleContract.NormalizeAndValidate(nonUtc));
        Assert.Throws<AssignmentLifecycleContractException>(() =>
            AssignmentLifecycleContract.NormalizeAndValidate(acceptedBeforeOccurrence));
    }

    [TestMethod]
    public void ReplayRejectsInputsAboveConfiguredBound()
    {
        var assignment = CreateEvent(
            AssignmentLifecycleEventKind.Assignment,
            sequence: 1,
            actorId: "project-manager",
            actorRole: "Project Manager",
            targetAgentId: "backend-leader");

        var exception = Assert.Throws<AssignmentLifecycleReplayException>(() =>
            AssignmentLifecycleReplay.Run([assignment, assignment], maximumReplayEvents: 1));

        StringAssert.Contains(exception.Message, "configured maximum is 1");
    }

    internal static IReadOnlyList<AssignmentLifecycleEvent> CompleteTrace()
    {
        var assignment = CreateEvent(
            AssignmentLifecycleEventKind.Assignment,
            sequence: 1,
            actorId: "project-manager",
            actorRole: "Project Manager",
            targetAgentId: "backend-leader");
        var leaderAcknowledgement = CreateEvent(
            AssignmentLifecycleEventKind.Acknowledgement,
            sequence: 2,
            actorId: "backend-leader",
            actorRole: "Backend Leader",
            parentEventId: assignment.EventId);
        var delegation = CreateEvent(
            AssignmentLifecycleEventKind.Delegation,
            sequence: 3,
            actorId: "backend-leader",
            actorRole: "Backend Leader",
            parentEventId: leaderAcknowledgement.EventId,
            targetAgentId: "backend-worker-01");
        var workerAcknowledgement = CreateEvent(
            AssignmentLifecycleEventKind.Acknowledgement,
            sequence: 4,
            actorId: "backend-worker-01",
            actorRole: "Backend Worker",
            parentEventId: delegation.EventId);
        var progress = CreateEvent(
            AssignmentLifecycleEventKind.Progress,
            sequence: 5,
            actorId: "backend-worker-01",
            actorRole: "Backend Worker",
            parentEventId: workerAcknowledgement.EventId,
            progressPercent: 50);
        var evidence = CreateEvent(
            AssignmentLifecycleEventKind.Evidence,
            sequence: 6,
            actorId: "backend-worker-01",
            actorRole: "Backend Worker",
            parentEventId: progress.EventId,
            evidenceReference: "artifacts/tests/self-report.trx",
            evidenceSha256: Hash("evidence"));
        var handoff = CreateEvent(
            AssignmentLifecycleEventKind.Handoff,
            sequence: 7,
            actorId: "backend-worker-01",
            actorRole: "Backend Worker",
            parentEventId: evidence.EventId,
            targetAgentId: "reviewer-01",
            handoffNote: "Implementation and evidence are ready for review.");
        return
        [
            assignment,
            leaderAcknowledgement,
            delegation,
            workerAcknowledgement,
            progress,
            evidence,
            handoff,
        ];
    }

    internal static AssignmentLifecycleEvent CreateEvent(
        AssignmentLifecycleEventKind eventKind,
        int sequence,
        string actorId,
        string actorRole,
        string taskId = "TASK-115",
        Guid? parentEventId = null,
        string? targetAgentId = null,
        int? progressPercent = null,
        string? deviationReason = null,
        string? evidenceReference = null,
        string? evidenceSha256 = null,
        string? handoffNote = null) => new(
        AssignmentLifecycleContract.Version,
        GuidFor(sequence),
        eventKind,
        sequence,
        BaseUtc.AddSeconds(sequence - 1),
        BaseUtc.AddSeconds(sequence),
        AssignmentLifecycleContract.CoreSource,
        GuidFor(100 + sequence),
        Hash($"self-report-{sequence}-{eventKind}"),
        taskId,
        actorId,
        actorRole,
        $"Lifecycle event {sequence}: {eventKind}.",
        parentEventId,
        targetAgentId,
        progressPercent,
        deviationReason,
        evidenceReference,
        evidenceSha256,
        handoffNote);

    internal static Guid GuidFor(int value) =>
        Guid.Parse($"00000000-0000-0000-0000-{value:000000000000}");

    internal static string Hash(string value) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value)));
}
