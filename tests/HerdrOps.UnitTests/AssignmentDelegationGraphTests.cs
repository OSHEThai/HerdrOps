using HerdrOps.Domain.Assignments;

namespace HerdrOps.UnitTests;

[TestClass]
public sealed class AssignmentDelegationGraphTests
{
    [TestMethod]
    public void ResolveSelectedTaskIdFallsBackToCurrentActorTaskWhenRequestedTaskIsUnrelated()
    {
        var events = new[]
        {
            AssignmentLifecycleTests.CreateEvent(
                AssignmentLifecycleEventKind.Assignment,
                sequence: 1,
                actorId: "project-manager",
                actorRole: "Project Manager",
                taskId: "TASK-101",
                targetAgentId: "backend-worker-01"),
            AssignmentLifecycleTests.CreateEvent(
                AssignmentLifecycleEventKind.Acknowledgement,
                sequence: 2,
                actorId: "backend-worker-01",
                actorRole: "Backend Worker",
                taskId: "TASK-101",
                parentEventId: AssignmentLifecycleTests.GuidFor(1)),
            AssignmentLifecycleTests.CreateEvent(
                AssignmentLifecycleEventKind.Assignment,
                sequence: 3,
                actorId: "project-manager",
                actorRole: "Project Manager",
                taskId: "TASK-102",
                targetAgentId: "reviewer-01"),
        };
        var graph = AssignmentDelegationGraphProjector.Create(AssignmentLifecycleReplay.Run(events));

        Assert.AreEqual(
            "TASK-101",
            AssignmentDelegationGraphProjector.ResolveSelectedTaskIdForActor(
                graph,
                "backend-worker-01",
                "TASK-102"));
    }

    [TestMethod]
    public void ResolveSelectedTaskIdClearsRequestedTaskForUnknownActor()
    {
        var graph = AssignmentDelegationGraphProjector.Create(
            AssignmentLifecycleReplay.Run(AssignmentLifecycleTests.CompleteTrace()));

        Assert.IsNull(
            AssignmentDelegationGraphProjector.ResolveSelectedTaskIdForActor(
                graph,
                "actor-that-is-not-in-the-graph",
                "TASK-001"));
    }

    [TestMethod]
    public void ProjectionIsDeterministicAndBindsGraphItemsToReplayProvenance()
    {
        var replay = AssignmentLifecycleReplay.Run(AssignmentLifecycleTests.CompleteTrace());

        var first = AssignmentDelegationGraphProjector.Create(replay);
        var second = AssignmentDelegationGraphProjector.Create(replay);

        Assert.AreEqual(first.GraphSha256, second.GraphSha256);
        CollectionAssert.AreEqual(first.Tasks.ToArray(), second.Tasks.ToArray());
        CollectionAssert.AreEqual(
            first.Nodes.Select(item => item.ActorId).ToArray(),
            second.Nodes.Select(item => item.ActorId).ToArray());
        CollectionAssert.AreEqual(first.Edges.ToArray(), second.Edges.ToArray());
        CollectionAssert.AreEqual(first.Timeline.ToArray(), second.Timeline.ToArray());
        Assert.AreEqual(replay.ResultSha256, first.SourceReplaySha256);
        Assert.AreEqual(64, first.GraphSha256.Length);
        Assert.HasCount(1, first.Tasks);
        Assert.HasCount(4, first.Nodes);
        Assert.HasCount(3, first.Edges);
        Assert.HasCount(7, first.Timeline);
        CollectionAssert.AreEqual(
            new[]
            {
                AssignmentRelationshipKind.Assignment,
                AssignmentRelationshipKind.Delegation,
                AssignmentRelationshipKind.Handoff,
            },
            first.Edges.Select(item => item.RelationshipKind).ToArray());
        Assert.IsTrue(first.Tasks.All(item =>
            item.StateSha256.Length == 64 && item.ProvenanceEventSha256.Length == 64));
        Assert.IsTrue(first.Nodes.All(item =>
            item.ProvenanceEventSha256.Length == 64 && item.LastObservedUtc.Offset == TimeSpan.Zero));
        Assert.IsTrue(first.Edges.All(item =>
            item.ProvenanceEventSha256.Length == 64 && item.RelationshipSha256.Length == 64));
        Assert.IsTrue(first.Timeline.All(item =>
            item.LifecycleEventSha256.Length == 64 && item.AuditSha256.Length == 64));
        Assert.AreEqual("reviewer-01", first.Tasks[0].CurrentAssigneeId);
        Assert.IsTrue(first.Nodes.Single(item => item.ActorId == "reviewer-01").IsCurrentAssignee);
    }

    [TestMethod]
    public void OrphanLifecycleEventRemainsVisibleWithoutCreatingADelegationEdge()
    {
        var orphan = AssignmentLifecycleTests.CreateEvent(
            AssignmentLifecycleEventKind.Acknowledgement,
            sequence: 1,
            actorId: "orphan-worker",
            actorRole: "Worker",
            taskId: "TASK-404",
            parentEventId: AssignmentLifecycleTests.GuidFor(900));
        var assignment = AssignmentLifecycleTests.CreateEvent(
            AssignmentLifecycleEventKind.Assignment,
            sequence: 2,
            actorId: "project-manager",
            actorRole: "Project Manager",
            targetAgentId: "backend-leader");
        var replay = AssignmentLifecycleReplay.Run([orphan, assignment]);

        var graph = AssignmentDelegationGraphProjector.Create(replay);

        Assert.HasCount(2, graph.Timeline);
        Assert.AreEqual(
            AssignmentLifecycleDisposition.OrphanTask,
            graph.Timeline.Single(item => item.EventId == orphan.EventId).Disposition);
        Assert.HasCount(1, graph.Edges);
        Assert.AreEqual(AssignmentRelationshipKind.Assignment, graph.Edges[0].RelationshipKind);
        Assert.IsTrue(graph.Nodes.Any(item => item.ActorId == "orphan-worker"));
        Assert.AreEqual(1L, graph.Diagnostics.OrphanEventCount);
    }

    [TestMethod]
    public void ProjectorRejectsRelationshipThatDoesNotMatchItsLifecycleEvent()
    {
        var replay = AssignmentLifecycleReplay.Run(AssignmentLifecycleTests.CompleteTrace());
        var forgedRelationships = replay.Relationships.ToArray();
        forgedRelationships[0] = forgedRelationships[0] with { ToActorId = "forged-agent" };
        var forgedReplay = replay with { Relationships = forgedRelationships };

        Assert.Throws<AssignmentLifecycleContractException>(() =>
            AssignmentDelegationGraphProjector.Create(forgedReplay));
    }
}
