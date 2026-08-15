using HerdrOps.Domain.Herdr;

namespace HerdrOps.UnitTests;

[TestClass]
public sealed class HerdrStateReducerTests
{
    private readonly HerdrStateReducer _reducer = new();

    [TestMethod]
    public void SnapshotBootstrapsEveryWorkspaceTabPaneAndAgent()
    {
        var state = _reducer.Reconcile(CreateSnapshot(), connectionEpoch: 1, ingestSequence: 1);

        Assert.AreEqual("0.8.0-preview", state.Version);
        Assert.AreEqual(19, state.Protocol);
        Assert.HasCount(1, state.Workspaces);
        Assert.HasCount(1, state.Tabs);
        Assert.HasCount(1, state.Panes);
        Assert.HasCount(1, state.Agents);
        Assert.AreEqual("workspace-1", state.FocusedWorkspaceId);
        Assert.AreEqual("tab-1", state.FocusedTabId);
        Assert.AreEqual("pane-1", state.FocusedPaneId);
        Assert.AreEqual(HerdrAgentStatus.Working, state.Agents["terminal-1"].AgentStatus);
    }

    [TestMethod]
    public void DuplicateSnapshotIdentifierFailsClosed()
    {
        var snapshot = CreateSnapshot();
        snapshot = snapshot with { Panes = [snapshot.Panes[0], snapshot.Panes[0]] };

        var exception = Assert.ThrowsExactly<HerdrStateConsistencyException>(
            () => _reducer.Reconcile(snapshot, connectionEpoch: 1, ingestSequence: 1));

        StringAssert.Contains(exception.Message, "Duplicate pane identifier");
    }

    [TestMethod]
    public void SnapshotWithBrokenAgentReferenceFailsClosed()
    {
        var snapshot = CreateSnapshot();
        snapshot = snapshot with
        {
            Agents = [snapshot.Agents[0] with { PaneId = "missing-pane" }],
        };

        var exception = Assert.ThrowsExactly<HerdrStateConsistencyException>(
            () => _reducer.Reconcile(snapshot, connectionEpoch: 1, ingestSequence: 1));

        StringAssert.Contains(exception.Message, "inconsistent workspace, tab, or pane references");
    }

    [TestMethod]
    public void SnapshotCollectionCountsMustAgree()
    {
        var snapshot = CreateSnapshot();
        snapshot = snapshot with
        {
            Workspaces = [snapshot.Workspaces[0] with { PaneCount = 2 }],
        };

        var exception = Assert.ThrowsExactly<HerdrStateConsistencyException>(
            () => _reducer.Reconcile(snapshot, connectionEpoch: 1, ingestSequence: 1));

        StringAssert.Contains(exception.Message, "counts disagree");
    }

    [TestMethod]
    public void SnapshotFocusMirrorsMustAgree()
    {
        var snapshot = CreateTwoTabSnapshot() with
        {
            FocusedTabId = "tab-2",
            FocusedPaneId = null,
        };

        var exception = Assert.ThrowsExactly<HerdrStateConsistencyException>(
            () => _reducer.Reconcile(snapshot, connectionEpoch: 1, ingestSequence: 1));

        StringAssert.Contains(exception.Message, "active tab does not match");
    }

    [TestMethod]
    public void SequentialPaneRevisionAppliesAndGapRequestsReconciliation()
    {
        var state = _reducer.Reconcile(CreateSnapshot(), connectionEpoch: 1, ingestSequence: 1);
        var sequential = state.Panes["pane-1"] with { Revision = 2, Title = "new title" };

        var applied = _reducer.Apply(
            state,
            new HerdrPaneChangedEvent("pane_updated", sequential),
            ingestSequence: 2);
        var gap = _reducer.Apply(
            applied.State,
            new HerdrPaneRevisionChangedEvent(
                "pane_output_changed",
                "workspace-1",
                "pane-1",
                Revision: 5),
            ingestSequence: 3);
        var stale = _reducer.Apply(
            applied.State,
            new HerdrPaneChangedEvent(
                "pane_updated",
                sequential with { Revision = 1, Title = "stale title" }),
            ingestSequence: 4);

        Assert.AreEqual(HerdrStateApplyDisposition.Applied, applied.Disposition);
        Assert.AreEqual((ulong)2, applied.State.Panes["pane-1"].Revision);
        Assert.AreEqual(HerdrStateApplyDisposition.ReconciliationRequired, gap.Disposition);
        StringAssert.Contains(gap.Reason!, "jumped from 2 to 5");
        Assert.AreSame(applied.State, gap.State);
        Assert.AreEqual(HerdrStateApplyDisposition.Duplicate, stale.Disposition);
        Assert.AreEqual((ulong)2, stale.State.Panes["pane-1"].Revision);
        Assert.AreEqual("new title", stale.State.Panes["pane-1"].Title);
    }

    [TestMethod]
    public void TabAndPaneFocusUpdateEveryMirroredFocusFieldAtomically()
    {
        var state = _reducer.Reconcile(CreateTwoTabSnapshot(), connectionEpoch: 1, ingestSequence: 1);

        var tabFocused = _reducer.Apply(
            state,
            new HerdrTabFocusedEvent("tab_focused", "workspace-1", "tab-2"),
            ingestSequence: 2);
        var paneFocused = _reducer.Apply(
            tabFocused.State,
            new HerdrPaneFocusedEvent("pane_focused", "workspace-1", "pane-2"),
            ingestSequence: 3);

        Assert.AreEqual("workspace-1", tabFocused.State.FocusedWorkspaceId);
        Assert.AreEqual("tab-2", tabFocused.State.FocusedTabId);
        Assert.IsNull(tabFocused.State.FocusedPaneId);
        Assert.AreEqual("tab-2", tabFocused.State.Workspaces["workspace-1"].ActiveTabId);
        Assert.IsFalse(tabFocused.State.Tabs["tab-1"].Focused);
        Assert.IsTrue(tabFocused.State.Tabs["tab-2"].Focused);
        Assert.IsTrue(tabFocused.State.Panes.Values.All(pane => !pane.Focused));
        Assert.IsTrue(tabFocused.State.Agents.Values.All(agent => !agent.Focused));

        Assert.AreEqual("workspace-1", paneFocused.State.FocusedWorkspaceId);
        Assert.AreEqual("tab-2", paneFocused.State.FocusedTabId);
        Assert.AreEqual("pane-2", paneFocused.State.FocusedPaneId);
        Assert.AreEqual("tab-2", paneFocused.State.Workspaces["workspace-1"].ActiveTabId);
        Assert.IsFalse(paneFocused.State.Panes["pane-1"].Focused);
        Assert.IsTrue(paneFocused.State.Panes["pane-2"].Focused);
        Assert.IsFalse(paneFocused.State.Agents["terminal-1"].Focused);
        Assert.IsTrue(paneFocused.State.Agents["terminal-2"].Focused);
    }

    [TestMethod]
    public void DuplicateAgentStatusDoesNotCreateDuplicateAgentState()
    {
        var state = _reducer.Reconcile(CreateSnapshot(), connectionEpoch: 1, ingestSequence: 1);
        var duplicate = _reducer.Apply(
            state,
            new HerdrPaneAgentStatusChangedEvent(
                "pane.agent_status_changed",
                "workspace-1",
                "pane-1",
                HerdrAgentStatus.Working,
                "codex",
                "Codex",
                "Worker"),
            ingestSequence: 2);
        var changed = _reducer.Apply(
            duplicate.State,
            new HerdrPaneAgentStatusChangedEvent(
                "pane.agent_status_changed",
                "workspace-1",
                "pane-1",
                HerdrAgentStatus.Blocked,
                "codex",
                "Codex",
                "Waiting"),
            ingestSequence: 3);

        Assert.AreEqual(HerdrStateApplyDisposition.Duplicate, duplicate.Disposition);
        Assert.HasCount(1, duplicate.State.Agents);
        Assert.AreEqual(HerdrStateApplyDisposition.Applied, changed.Disposition);
        Assert.AreEqual(HerdrAgentStatus.Blocked, changed.State.Panes["pane-1"].AgentStatus);
        Assert.AreEqual(HerdrAgentStatus.Blocked, changed.State.Agents["terminal-1"].AgentStatus);
        Assert.AreEqual("Waiting", changed.State.Agents["terminal-1"].Title);
    }

    [TestMethod]
    public void FreshSnapshotReplacesPriorStateWithoutDuplicates()
    {
        var first = _reducer.Reconcile(CreateSnapshot(), connectionEpoch: 1, ingestSequence: 1);
        var replacementSnapshot = CreateSnapshot() with
        {
            Panes = [CreateSnapshot().Panes[0] with { Revision = 7 }],
            Agents = [CreateSnapshot().Agents[0] with { Revision = 7, AgentStatus = HerdrAgentStatus.Idle }],
        };

        var replacement = _reducer.Reconcile(
            replacementSnapshot,
            connectionEpoch: 2,
            ingestSequence: 2);

        Assert.HasCount(1, first.Panes);
        Assert.HasCount(1, replacement.Panes);
        Assert.HasCount(1, replacement.Agents);
        Assert.AreEqual((ulong)7, replacement.Panes["pane-1"].Revision);
        Assert.AreEqual(HerdrAgentStatus.Idle, replacement.Agents["terminal-1"].AgentStatus);
        Assert.AreEqual(2, replacement.ConnectionEpoch);
    }

    [TestMethod]
    public void AgentStatusWithoutSnapshotAgentRequestsReconciliation()
    {
        var snapshot = CreateSnapshot() with { Agents = [] };
        var state = _reducer.Reconcile(snapshot, connectionEpoch: 1, ingestSequence: 1);

        var result = _reducer.Apply(
            state,
            new HerdrPaneAgentStatusChangedEvent(
                "pane.agent_status_changed",
                "workspace-1",
                "pane-1",
                HerdrAgentStatus.Working,
                "codex",
                "Codex",
                "Worker"),
            ingestSequence: 2);

        Assert.AreEqual(HerdrStateApplyDisposition.ReconciliationRequired, result.Disposition);
        StringAssert.Contains(result.Reason!, "no matching agent record");
    }

    [TestMethod]
    public void AgentFreeUnknownStatusDoesNotRequestReconciliation()
    {
        var snapshot = CreateSnapshot() with
        {
            Panes =
            [
                CreateSnapshot().Panes[0] with
                {
                    AgentStatus = HerdrAgentStatus.Unknown,
                    Agent = null,
                    DisplayAgent = null,
                    Title = null,
                },
            ],
            Agents = [],
        };
        var state = _reducer.Reconcile(snapshot, connectionEpoch: 1, ingestSequence: 1);

        var result = _reducer.Apply(
            state,
            new HerdrPaneAgentStatusChangedEvent(
                "pane.agent_status_changed",
                "workspace-1",
                "pane-1",
                HerdrAgentStatus.Unknown,
                Agent: null,
                DisplayAgent: null,
                Title: "Windows PowerShell"),
            ingestSequence: 2);

        Assert.AreEqual(HerdrStateApplyDisposition.Applied, result.Disposition);
        Assert.AreEqual(2, result.State.LastIngestSequence);
        Assert.AreEqual("Windows PowerShell", result.State.Panes["pane-1"].Title);
        Assert.IsEmpty(result.State.Agents);
    }

    [TestMethod]
    public void ReflectedAgentDetectionIsDuplicateButContradictoryDetectionReconciles()
    {
        var state = _reducer.Reconcile(CreateSnapshot(), connectionEpoch: 1, ingestSequence: 1);
        var reflected = _reducer.Apply(
            state,
            new HerdrPaneAgentDetectedEvent(
                "pane_agent_detected",
                "workspace-1",
                "pane-1",
                "codex",
                HerdrAgentStatus.Working,
                Released: false),
            ingestSequence: 2);
        var contradictory = _reducer.Apply(
            reflected.State,
            new HerdrPaneAgentDetectedEvent(
                "pane_agent_detected",
                "workspace-1",
                "pane-1",
                "codex",
                HerdrAgentStatus.Done,
                Released: true),
            ingestSequence: 3);

        Assert.AreEqual(HerdrStateApplyDisposition.Duplicate, reflected.Disposition);
        Assert.AreEqual(2, reflected.State.LastIngestSequence);
        Assert.AreEqual(HerdrStateApplyDisposition.ReconciliationRequired, contradictory.Disposition);
        StringAssert.Contains(contradictory.Reason!, "not reflected");
    }

    [TestMethod]
    public void ReleasedAgentDetectionAlreadyReflectedByAgentFreePaneIsDuplicate()
    {
        var snapshot = CreateSnapshot() with
        {
            Panes =
            [
                CreateSnapshot().Panes[0] with
                {
                    AgentStatus = HerdrAgentStatus.Unknown,
                    Agent = null,
                    DisplayAgent = null,
                    Title = null,
                },
            ],
            Agents = [],
        };
        var state = _reducer.Reconcile(snapshot, connectionEpoch: 1, ingestSequence: 1);

        var result = _reducer.Apply(
            state,
            new HerdrPaneAgentDetectedEvent(
                "pane_agent_detected",
                "workspace-1",
                "pane-1",
                "codex",
                HerdrAgentStatus.Done,
                Released: true),
            ingestSequence: 2);

        Assert.AreEqual(HerdrStateApplyDisposition.Duplicate, result.Disposition);
        Assert.AreEqual(2, result.State.LastIngestSequence);
    }

    [TestMethod]
    public void IdentityLessActiveFinalStatusRequestsReconciliation()
    {
        var snapshot = CreateSnapshot() with
        {
            Panes =
            [
                CreateSnapshot().Panes[0] with
                {
                    AgentStatus = HerdrAgentStatus.Unknown,
                    Agent = null,
                    DisplayAgent = null,
                    Title = null,
                },
            ],
            Agents = [],
        };
        var state = _reducer.Reconcile(snapshot, connectionEpoch: 1, ingestSequence: 1);

        var result = _reducer.Apply(
            state,
            new HerdrPaneAgentDetectedEvent(
                "pane_agent_detected",
                "workspace-1",
                "pane-1",
                Agent: null,
                HerdrAgentStatus.Working,
                Released: false),
            ingestSequence: 2);

        Assert.AreEqual(HerdrStateApplyDisposition.ReconciliationRequired, result.Disposition);
        StringAssert.Contains(result.Reason!, "not reflected");
    }

    [TestMethod]
    public void DetectionAgainstPartiallyIdentifiedPaneRequestsReconciliation()
    {
        var snapshot = CreateSnapshot() with
        {
            Panes =
            [
                CreateSnapshot().Panes[0] with
                {
                    AgentStatus = HerdrAgentStatus.Unknown,
                    Agent = null,
                    DisplayAgent = "Codex",
                    Title = null,
                },
            ],
            Agents = [],
        };
        var state = _reducer.Reconcile(snapshot, connectionEpoch: 1, ingestSequence: 1);

        var result = _reducer.Apply(
            state,
            new HerdrPaneAgentDetectedEvent(
                "pane_agent_detected",
                "workspace-1",
                "pane-1",
                Agent: null,
                FinalStatus: null,
                Released: false),
            ingestSequence: 2);

        Assert.AreEqual(HerdrStateApplyDisposition.ReconciliationRequired, result.Disposition);
        StringAssert.Contains(result.Reason!, "not reflected");
    }

    [TestMethod]
    public void ClosingWorkspaceCascadesAllDescendantsIdempotently()
    {
        var state = _reducer.Reconcile(CreateSnapshot(), connectionEpoch: 1, ingestSequence: 1);
        var closed = _reducer.Apply(
            state,
            new HerdrWorkspaceRemovedEvent("workspace_closed", "workspace-1"),
            ingestSequence: 2);
        var repeated = _reducer.Apply(
            closed.State,
            new HerdrWorkspaceRemovedEvent("workspace_closed", "workspace-1"),
            ingestSequence: 3);

        Assert.IsEmpty(closed.State.Workspaces);
        Assert.IsEmpty(closed.State.Tabs);
        Assert.IsEmpty(closed.State.Panes);
        Assert.IsEmpty(closed.State.Agents);
        Assert.AreEqual(HerdrStateApplyDisposition.Duplicate, repeated.Disposition);
    }

    private static HerdrSessionSnapshot CreateTwoTabSnapshot()
    {
        var snapshot = CreateSnapshot();
        return snapshot with
        {
            Workspaces =
            [
                snapshot.Workspaces[0] with
                {
                    PaneCount = 2,
                    TabCount = 2,
                },
            ],
            Tabs =
            [
                snapshot.Tabs[0],
                new HerdrTabSnapshot(
                    "tab-2",
                    "workspace-1",
                    2,
                    "Tests",
                    Focused: false,
                    PaneCount: 1,
                    HerdrAgentStatus.Working),
            ],
            Panes =
            [
                snapshot.Panes[0],
                new HerdrPaneSnapshot(
                    "pane-2",
                    "terminal-2",
                    "workspace-1",
                    "tab-2",
                    Focused: false,
                    HerdrAgentStatus.Working,
                    Revision: 1,
                    "codex",
                    "Codex",
                    "Worker 02",
                    "Z:\\HerdrOps",
                    "Z:\\HerdrOps",
                    "Codex"),
            ],
            Agents =
            [
                snapshot.Agents[0],
                new HerdrAgentSnapshot(
                    "terminal-2",
                    "workspace-1",
                    "tab-2",
                    "pane-2",
                    Focused: false,
                    HerdrAgentStatus.Working,
                    Revision: 1,
                    StateChangeSequence: 1,
                    "codex",
                    "Codex",
                    "Worker 02",
                    "Worker 02",
                    "Z:\\HerdrOps",
                    "Z:\\HerdrOps",
                    "Codex",
                    InteractiveReady: true,
                    LaunchPending: false,
                    ScreenDetectionSkipped: false),
            ],
        };
    }

    internal static HerdrSessionSnapshot CreateSnapshot(ulong revision = 1) => new(
        "0.8.0-preview",
        19,
        [
            new HerdrWorkspaceSnapshot(
                "workspace-1",
                1,
                "HerdrOps",
                Focused: true,
                PaneCount: 1,
                TabCount: 1,
                ActiveTabId: "tab-1",
                HerdrAgentStatus.Working),
        ],
        [
            new HerdrTabSnapshot(
                "tab-1",
                "workspace-1",
                1,
                "Core",
                Focused: true,
                PaneCount: 1,
                HerdrAgentStatus.Working),
        ],
        [
            new HerdrPaneSnapshot(
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
                "Codex"),
        ],
        [
            new HerdrAgentSnapshot(
                "terminal-1",
                "workspace-1",
                "tab-1",
                "pane-1",
                Focused: true,
                HerdrAgentStatus.Working,
                revision,
                StateChangeSequence: 1,
                "codex",
                "Codex",
                "Worker 01",
                "Worker",
                "Z:\\HerdrOps",
                "Z:\\HerdrOps",
                "Codex",
                InteractiveReady: true,
                LaunchPending: false,
                ScreenDetectionSkipped: false),
        ],
        "workspace-1",
        "tab-1",
        "pane-1");
}
