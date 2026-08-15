using System.Security.Cryptography;
using System.Text;
using HerdrOps.App.Widgets;
using HerdrOps.App.Live;
using HerdrOps.Contracts.StateIpc;
using HerdrOps.Domain.Assignments;

namespace HerdrOps.IntegrationTests;

[TestClass]
public sealed class WidgetAssignmentProjectionTests
{
    private static readonly DateTimeOffset BaseUtc = new(
        2026,
        8,
        15,
        3,
        0,
        0,
        TimeSpan.Zero);

    [TestMethod]
    public void ExactTerminalAndRoleBindOneTaskWithLifecycleProvenanceAndScore()
    {
        var replay = AssignmentLifecycleReplay.Run(CreateActiveTask(
            "TASK-115",
            "terminal-1",
            "Worker"));
        var graph = AssignmentDelegationGraphProjector.Create(replay);
        var analysis = new TaskAlignmentAnalysisResult(
            TaskAlignmentContractRules.Version,
            "TASK-115",
            GoalAlignmentScore: 90,
            ScopeComplianceScore: 80,
            AcceptanceCriteriaScore: 70,
            HasMissingRequiredData: false,
            new TaskAlignmentVerdict(TaskAlignmentVerdictKind.Aligned, ["TASK-115"]),
            [],
            graph.GraphSha256,
            Hash("contract"),
            Hash("analysis"));

        var projection = WidgetAssignmentProjector.Create(
            LiveWidgetStateTests.CreateState(sequence: 12),
            replay,
            [analysis]);

        Assert.IsTrue(projection.HasAdmittedLifecycle);
        Assert.IsEmpty(projection.Diagnostics);
        Assert.HasCount(1, projection.Facts);
        var fact = projection.Facts.Single();
        Assert.AreEqual("terminal-1", fact.TerminalId);
        Assert.AreEqual("TASK-115", fact.TaskId);
        Assert.AreEqual("Worker", fact.ActorRole);
        Assert.AreEqual("project-manager", fact.AssignedByActorId);
        Assert.AreEqual("Implementation reached fifty percent.", fact.Activity);
        Assert.AreEqual(BaseUtc.AddSeconds(1), fact.StartedUtc);
        Assert.AreEqual(80, fact.Score);
        Assert.IsTrue(fact.HasTaskAlignment);
        Assert.AreEqual(analysis.AnalysisSha256, fact.ScoreProvenanceSha256);
        Assert.AreEqual(
            replay.CurrentTasks.Single().State.Contract.ProvenanceEventSha256,
            fact.LifecycleProvenanceSha256);
    }

    [TestMethod]
    public void MissingAgentAndRoleMismatchRemainDiagnosticOnly()
    {
        var session = LiveWidgetStateTests.CreateState(sequence: 12);
        var missingReplay = AssignmentLifecycleReplay.Run(CreateActiveTask(
            "TASK-116",
            "terminal-missing",
            "Worker"));
        var mismatchReplay = AssignmentLifecycleReplay.Run(CreateActiveTask(
            "TASK-117",
            "terminal-1",
            "Backend Worker"));

        var missing = WidgetAssignmentProjector.Create(session, missingReplay);
        var mismatch = WidgetAssignmentProjector.Create(session, mismatchReplay);

        Assert.IsEmpty(missing.Facts);
        Assert.AreEqual(
            WidgetAssignmentDiagnosticCode.MissingAgent,
            missing.Diagnostics.Single().Code);
        Assert.IsEmpty(mismatch.Facts);
        Assert.AreEqual(
            WidgetAssignmentDiagnosticCode.RoleMismatch,
            mismatch.Diagnostics.Single().Code);
    }

    [TestMethod]
    public void MultipleCurrentTasksForOneAgentFailClosed()
    {
        var events = CreateActiveTask("TASK-115", "terminal-1", "Worker")
            .Concat(CreateActiveTask(
                "TASK-118",
                "terminal-1",
                "Worker",
                startingSequence: 4))
            .ToArray();
        var replay = AssignmentLifecycleReplay.Run(events);

        var projection = WidgetAssignmentProjector.Create(
            LiveWidgetStateTests.CreateState(sequence: 12),
            replay);

        Assert.IsEmpty(projection.Facts);
        Assert.AreEqual(
            WidgetAssignmentDiagnosticCode.MultipleCurrentTasks,
            projection.Diagnostics.Single().Code);
    }

    [TestMethod]
    public void AnalysisFromAnotherLifecycleCannotSupplyWidgetScore()
    {
        var replay = AssignmentLifecycleReplay.Run(CreateActiveTask(
            "TASK-115",
            "terminal-1",
            "Worker"));
        var analysis = new TaskAlignmentAnalysisResult(
            TaskAlignmentContractRules.Version,
            "TASK-115",
            100,
            100,
            100,
            HasMissingRequiredData: false,
            new TaskAlignmentVerdict(TaskAlignmentVerdictKind.Aligned, ["TASK-115"]),
            [],
            Hash("another-lifecycle"),
            Hash("contract"),
            Hash("analysis"));

        var projection = WidgetAssignmentProjector.Create(
            LiveWidgetStateTests.CreateState(sequence: 12),
            replay,
            [analysis]);

        Assert.IsNull(projection.Facts.Single().Score);
        Assert.IsFalse(projection.Facts.Single().HasTaskAlignment);
        Assert.AreEqual(
            WidgetAssignmentDiagnosticCode.AnalysisLifecycleMismatch,
            projection.Diagnostics.Single().Code);
    }

    [TestMethod]
    public void DashboardDelegationAndExpandedWidgetShareOneLifecycleTip()
    {
        var replay = AssignmentLifecycleReplay.Run(CreateActiveTask(
            "TASK-115",
            "terminal-1",
            "Worker"));
        var session = LiveWidgetStateTests.CreateState(sequence: 12);
        var update = LiveWidgetStateTests.SnapshotUpdate(session);
        var dashboard = new LiveDashboardState();
        dashboard.ApplyUpdate(update, update.Envelope.SentUtc.AddMilliseconds(8));

        dashboard.ApplyAssignmentWorkspace(
            replay,
            alignmentRequest: null,
            "HerdrOps",
            "Core lifecycle test",
            "Contract-backed lifecycle test only");

        var widgetAgent = dashboard.Widgets.Agents.Single(item =>
            item.TerminalId == "terminal-1");
        Assert.AreEqual("TASK-115", widgetAgent.TaskId);
        Assert.AreEqual(
            HerdrOps.App.Localization.UiLanguageService.Shared["WidgetAgentWorkerRole"],
            widgetAgent.Role);
        StringAssert.Contains(widgetAgent.Activity, "TASK-115");
        Assert.AreEqual(
            replay.CurrentTasks.Single().State.Contract.ProvenanceEventSha256,
            widgetAgent.LifecycleProvenance);
        Assert.IsFalse(widgetAgent.CanOpenTaskAlignment);
        Assert.IsTrue(dashboard.DelegationGraph.HasGraph);
        Assert.IsTrue(dashboard.DelegationGraph.TaskTreeItems.Any(item =>
            item.TaskId == widgetAgent.TaskId));
        Assert.IsFalse(
            dashboard.TaskAlignment.HasAnalysis,
            "A lifecycle alone must not manufacture Task Alignment analysis.");
    }

    private static IReadOnlyList<AssignmentLifecycleEvent> CreateActiveTask(
        string taskId,
        string assigneeId,
        string assigneeRole,
        long startingSequence = 1)
    {
        var assignmentId = GuidForSequence(startingSequence);
        var acknowledgementId = GuidForSequence(startingSequence + 1);
        return
        [
            CreateEvent(
                AssignmentLifecycleEventKind.Assignment,
                startingSequence,
                taskId,
                "project-manager",
                "Project Manager",
                "Assign implementation to the selected Agent.",
                parentEventId: null,
                targetAgentId: assigneeId),
            CreateEvent(
                AssignmentLifecycleEventKind.Acknowledgement,
                startingSequence + 1,
                taskId,
                assigneeId,
                assigneeRole,
                "The selected Agent acknowledged the assignment.",
                assignmentId),
            CreateEvent(
                AssignmentLifecycleEventKind.Progress,
                startingSequence + 2,
                taskId,
                assigneeId,
                assigneeRole,
                "Implementation reached fifty percent.",
                acknowledgementId,
                progressPercent: 50),
        ];
    }

    private static AssignmentLifecycleEvent CreateEvent(
        AssignmentLifecycleEventKind kind,
        long sequence,
        string taskId,
        string actorId,
        string actorRole,
        string summary,
        Guid? parentEventId,
        string? targetAgentId = null,
        int? progressPercent = null)
    {
        var occurredUtc = BaseUtc.AddSeconds(sequence - 1);
        return new AssignmentLifecycleEvent(
            AssignmentLifecycleContract.Version,
            GuidForSequence(sequence),
            kind,
            sequence,
            occurredUtc,
            occurredUtc.AddSeconds(1),
            AssignmentLifecycleContract.CoreSource,
            GuidForSequence(sequence + 1000),
            Hash($"submission-{sequence}"),
            taskId,
            actorId,
            actorRole,
            summary,
            parentEventId,
            targetAgentId,
            progressPercent,
            DeviationReason: null,
            EvidenceReference: null,
            EvidenceSha256: null,
            HandoffNote: null);
    }

    private static Guid GuidForSequence(long sequence) => Guid.Parse(
        $"00000000-0000-0000-0000-{sequence:000000000000}");

    private static string Hash(string value) => Convert.ToHexString(
        SHA256.HashData(Encoding.UTF8.GetBytes(value)));
}
