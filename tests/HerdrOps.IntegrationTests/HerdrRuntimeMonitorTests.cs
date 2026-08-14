using System.Globalization;
using HerdrOps.Core;
using HerdrOps.Domain.Herdr;
using HerdrOps.Infrastructure.Herdr;

namespace HerdrOps.IntegrationTests;

[TestClass]
public sealed class HerdrRuntimeMonitorTests
{
    [TestMethod]
    public async Task ForcedDisconnectBootstrapsFreshSnapshotWithoutDuplicateState()
    {
        var initial = CreateSnapshot(revision: 1, HerdrAgentStatus.Working);
        var recovered = CreateSnapshot(revision: 4, HerdrAgentStatus.Idle);
        var apiClient = new ScriptedApiClient(
            [initial, initial, recovered, recovered],
            [
                ScriptedSubscription.EndImmediately(),
                ScriptedSubscription.BlockUntilCancelled(),
            ]);
        var monitor = CreateMonitor(apiClient);
        using var cancellation = new CancellationTokenSource();
        var runTask = monitor.RunAsync(cancellation.Token);

        await WaitForAsync(
            monitor,
            state => state.BootstrapCount >= 2 && state.Status == HerdrRuntimeMonitorStatus.Connected);
        cancellation.Cancel();
        await Assert.ThrowsAsync<OperationCanceledException>(() => runTask);

        var final = monitor.Current;
        Assert.AreEqual(HerdrRuntimeMonitorStatus.Stopped, final.Status);
        Assert.AreEqual(2, final.State.ConnectionEpoch);
        Assert.HasCount(1, final.State.Workspaces);
        Assert.HasCount(1, final.State.Tabs);
        Assert.HasCount(1, final.State.Panes);
        Assert.HasCount(1, final.State.Agents);
        Assert.AreEqual((ulong)4, final.State.Panes["pane-1"].Revision);
        Assert.AreEqual(HerdrAgentStatus.Idle, final.State.Agents["terminal-1"].AgentStatus);
        Assert.IsGreaterThanOrEqualTo(1, final.ReconciliationCount);
        Assert.AreEqual(1, final.DisconnectCount);
    }

    [TestMethod]
    public async Task PaneRevisionGapTriggersFreshSnapshotReconciliation()
    {
        var beforeGap = CreateSnapshot(revision: 1, HerdrAgentStatus.Working);
        var afterGap = CreateSnapshot(revision: 5, HerdrAgentStatus.Blocked);
        var apiClient = new ScriptedApiClient(
            [beforeGap, beforeGap, afterGap, afterGap],
            [
                ScriptedSubscription.WithEvents(
                    new HerdrPaneChangedEvent(
                        "pane_updated",
                        afterGap.Panes[0])),
                ScriptedSubscription.BlockUntilCancelled(),
            ]);
        var monitor = CreateMonitor(apiClient);
        using var cancellation = new CancellationTokenSource();
        var runTask = monitor.RunAsync(cancellation.Token);

        await WaitForAsync(
            monitor,
            state => state.BootstrapCount >= 2 && state.State.Panes["pane-1"].Revision == 5);
        cancellation.Cancel();
        await Assert.ThrowsAsync<OperationCanceledException>(() => runTask);

        Assert.AreEqual((ulong)5, monitor.Current.State.Panes["pane-1"].Revision);
        Assert.AreEqual(HerdrAgentStatus.Blocked, monitor.Current.State.Agents["terminal-1"].AgentStatus);
        Assert.IsGreaterThanOrEqualTo(1, monitor.Current.ReconciliationCount);
        Assert.AreEqual(0, monitor.Current.DisconnectCount);
        Assert.IsTrue(
            apiClient.SubscriptionPaneIds.All(ids => ids.SetEquals(["pane-1"])),
            "Every subscription should be derived from the preceding snapshot pane set.");
    }

    [TestMethod]
    public async Task StalePaneEventQueuedBeforeAuthoritativeSnapshotIsIgnoredWithoutReconciliation()
    {
        var authoritative = CreateSnapshot(revision: 5, HerdrAgentStatus.Working);
        var stalePane = authoritative.Panes[0] with
        {
            Revision = 4,
            AgentStatus = HerdrAgentStatus.Blocked,
            Title = "stale",
        };
        var apiClient = new ScriptedApiClient(
            [authoritative, authoritative],
            [
                ScriptedSubscription.WithEventsThenBlock(
                    new HerdrPaneChangedEvent("pane_updated", stalePane)),
            ]);
        var monitor = CreateMonitor(apiClient);
        using var cancellation = new CancellationTokenSource();
        var runTask = monitor.RunAsync(cancellation.Token);

        await WaitForAsync(monitor, state => state.EventCount == 1);
        cancellation.Cancel();
        await Assert.ThrowsAsync<OperationCanceledException>(() => runTask);

        Assert.AreEqual(1, monitor.Current.BootstrapCount);
        Assert.AreEqual(0, monitor.Current.ReconciliationCount);
        Assert.AreEqual((ulong)5, monitor.Current.State.Panes["pane-1"].Revision);
        Assert.AreEqual(HerdrAgentStatus.Working, monitor.Current.State.Panes["pane-1"].AgentStatus);
        Assert.AreEqual("Worker", monitor.Current.State.Panes["pane-1"].Title);
    }

    [TestMethod]
    public async Task FilteredAgentStatusEventUpdatesCurrentStateWithoutAnotherBootstrap()
    {
        var snapshot = CreateSnapshot(revision: 1, HerdrAgentStatus.Working);
        var apiClient = new ScriptedApiClient(
            [snapshot, snapshot],
            [
                ScriptedSubscription.WithEventsThenBlock(
                    new HerdrPaneAgentStatusChangedEvent(
                        "pane.agent_status_changed",
                        "workspace-1",
                        "pane-1",
                        HerdrAgentStatus.Blocked,
                        "codex",
                        "Codex",
                        "Waiting")),
            ]);
        var monitor = CreateMonitor(apiClient);
        using var cancellation = new CancellationTokenSource();
        var runTask = monitor.RunAsync(cancellation.Token);

        await WaitForAsync(
            monitor,
            state => state.State.Agents.TryGetValue("terminal-1", out var agent) &&
                     agent.AgentStatus == HerdrAgentStatus.Blocked);
        cancellation.Cancel();
        await Assert.ThrowsAsync<OperationCanceledException>(() => runTask);

        Assert.AreEqual(1, monitor.Current.BootstrapCount);
        Assert.AreEqual(HerdrAgentStatus.Blocked, monitor.Current.State.Panes["pane-1"].AgentStatus);
        Assert.AreEqual("Waiting", monitor.Current.State.Agents["terminal-1"].Title);
        Assert.AreEqual(1, monitor.Current.EventCount);
    }

    [TestMethod]
    public async Task TopologyEventReconcilesBeforePublishingIntermediateCounts()
    {
        var snapshot = CreateSnapshot(revision: 1, HerdrAgentStatus.Working);
        var createdPane = snapshot.Panes[0] with
        {
            PaneId = "pane-2",
            TerminalId = "terminal-2",
            Focused = false,
        };
        var apiClient = new ScriptedApiClient(
            [snapshot, snapshot, snapshot, snapshot],
            [
                ScriptedSubscription.WithEvents(
                    new HerdrPaneChangedEvent("pane_created", createdPane)),
                ScriptedSubscription.BlockUntilCancelled(),
            ]);
        var monitor = CreateMonitor(apiClient);
        var publishedIntermediatePane = false;
        monitor.StateChanged += (_, state) =>
            publishedIntermediatePane |= state.State.Panes.ContainsKey("pane-2");
        using var cancellation = new CancellationTokenSource();
        var runTask = monitor.RunAsync(cancellation.Token);

        await WaitForAsync(
            monitor,
            state => state.BootstrapCount >= 2 && state.Status == HerdrRuntimeMonitorStatus.Connected);
        cancellation.Cancel();
        await Assert.ThrowsAsync<OperationCanceledException>(() => runTask);

        Assert.IsFalse(publishedIntermediatePane);
        Assert.HasCount(1, monitor.Current.State.Panes);
        Assert.AreEqual(1, monitor.Current.EventCount);
        Assert.IsGreaterThanOrEqualTo(1, monitor.Current.ReconciliationCount);
    }

    [TestMethod]
    public void ReconnectPolicyIsExponentiallyBoundedWithJitter()
    {
        var policy = HerdrReconnectPolicy.Default;

        var firstMinimum = policy.CalculateDelay(0, jitterSample: 0);
        var firstMaximum = policy.CalculateDelay(0, jitterSample: 1);
        var cappedMinimum = policy.CalculateDelay(100, jitterSample: 0);
        var cappedMaximum = policy.CalculateDelay(100, jitterSample: 1);

        Assert.AreEqual(TimeSpan.FromMilliseconds(80), firstMinimum);
        Assert.AreEqual(TimeSpan.FromMilliseconds(120), firstMaximum);
        Assert.AreEqual(TimeSpan.FromMilliseconds(1600), cappedMinimum);
        Assert.AreEqual(TimeSpan.FromMilliseconds(2000), cappedMaximum);
    }

    [TestMethod]
    public async Task RepeatedImmediateReconciliationsIncreaseBackoffAttempt()
    {
        var snapshot = CreateSnapshot(revision: 1, HerdrAgentStatus.Working);
        var topologyEvent = new HerdrPaneChangedEvent(
            "pane_created",
            snapshot.Panes[0] with { PaneId = "pane-2", TerminalId = "terminal-2" });
        var apiClient = new ScriptedApiClient(
            [snapshot, snapshot, snapshot, snapshot, snapshot, snapshot],
            [
                ScriptedSubscription.WithEvents(topologyEvent),
                ScriptedSubscription.WithEvents(topologyEvent),
                ScriptedSubscription.BlockUntilCancelled(),
            ]);
        var reconnectDelay = new RecordingReconnectDelay();
        var monitor = CreateMonitor(apiClient, reconnectDelay);
        using var cancellation = new CancellationTokenSource();
        var runTask = monitor.RunAsync(cancellation.Token);

        await WaitForAsync(monitor, state => state.BootstrapCount >= 3);
        cancellation.Cancel();
        await Assert.ThrowsAsync<OperationCanceledException>(() => runTask);

        CollectionAssert.AreEqual(new[] { 0, 1 }, reconnectDelay.Attempts.Take(2).ToArray());
    }

    [TestMethod]
    public async Task PaneMovedReconcilesCrossWorkspaceCountsAndResubscribesBeforePublishing()
    {
        var (beforeMove, afterMove) = CreateCrossWorkspaceMoveSnapshots();
        var movedEvent = HerdrProtocolJsonCodec.ParseEvent(
            """
            {
              "event": "pane_moved",
              "data": {
                "type": "pane_moved",
                "previous_pane_id": "pane-1",
                "previous_workspace_id": "workspace-1",
                "previous_tab_id": "tab-1",
                "pane": {
                  "pane_id": "pane-2",
                  "terminal_id": "terminal-1",
                  "workspace_id": "workspace-2",
                  "tab_id": "tab-2",
                  "focused": true,
                  "agent_status": "working",
                  "revision": 2,
                  "agent": "codex",
                  "display_agent": "Codex",
                  "title": "Worker",
                  "cwd": "Z:\\HerdrOps",
                  "foreground_cwd": "Z:\\HerdrOps",
                  "terminal_title": "Codex"
                }
              }
            }
            """);
        var apiClient = new ScriptedApiClient(
            [beforeMove, beforeMove, afterMove, afterMove],
            [
                ScriptedSubscription.WithEvents(movedEvent),
                ScriptedSubscription.BlockUntilCancelled(),
            ]);
        var monitor = CreateMonitor(apiClient);
        var publishedIntermediateMove = false;
        monitor.StateChanged += (_, state) =>
            publishedIntermediateMove |= state.State.ConnectionEpoch == 1 &&
                                         state.State.Panes.ContainsKey("pane-2");
        using var cancellation = new CancellationTokenSource();
        var runTask = monitor.RunAsync(cancellation.Token);

        await WaitForAsync(
            monitor,
            state => state.BootstrapCount >= 2 &&
                     state.State.Panes.ContainsKey("pane-2"));
        cancellation.Cancel();
        await Assert.ThrowsAsync<OperationCanceledException>(() => runTask);

        var final = monitor.Current;
        Assert.AreEqual(2, final.State.ConnectionEpoch);
        Assert.AreEqual(0, final.State.Workspaces["workspace-1"].PaneCount);
        Assert.AreEqual(1, final.State.Workspaces["workspace-2"].PaneCount);
        Assert.AreEqual(0, final.State.Tabs["tab-1"].PaneCount);
        Assert.AreEqual(1, final.State.Tabs["tab-2"].PaneCount);
        Assert.IsFalse(publishedIntermediateMove);
        Assert.IsFalse(final.State.Panes.ContainsKey("pane-1"));
        Assert.AreEqual("workspace-2", final.State.Panes["pane-2"].WorkspaceId);
        Assert.AreEqual("tab-2", final.State.Panes["pane-2"].TabId);
        Assert.AreEqual("workspace-2", final.State.Agents["terminal-1"].WorkspaceId);
        Assert.AreEqual("tab-2", final.State.Agents["terminal-1"].TabId);
        Assert.AreEqual("pane-2", final.State.Agents["terminal-1"].PaneId);
        Assert.HasCount(2, apiClient.SubscriptionPaneIds);
        Assert.IsTrue(apiClient.SubscriptionPaneIds[0].SetEquals(["pane-1"]));
        Assert.IsTrue(apiClient.SubscriptionPaneIds[1].SetEquals(["pane-2"]));
    }

    [TestMethod]
    public async Task ConnectedBootstrapRetainsTheVerifiedServerIdentityTuple()
    {
        var snapshot = CreateSnapshot(revision: 1, HerdrAgentStatus.Working);
        var identity = new HerdrServerProcessIdentity(
            ProcessId: 1234,
            DateTimeOffset.Parse("2026-08-14T10:00:00Z", CultureInfo.InvariantCulture),
            "C:\\Program Files\\Herdr\\herdr.exe",
            new string('A', 64));
        var apiClient = new ScriptedApiClient(
            [snapshot, snapshot],
            [ScriptedSubscription.BlockUntilCancelled()],
            identity);
        var monitor = CreateMonitor(apiClient);
        using var cancellation = new CancellationTokenSource();
        var runTask = monitor.RunAsync(cancellation.Token);

        await WaitForAsync(monitor, state => state.BootstrapCount == 1);
        cancellation.Cancel();
        await Assert.ThrowsAsync<OperationCanceledException>(() => runTask);

        Assert.AreEqual(identity, monitor.Current.ServerIdentity);
    }

    [TestMethod]
    public async Task RestoredCountersContinueOnFirstBootstrapAfterCoreRestart()
    {
        var initial = new HerdrStateReducer().Reconcile(
            CreateSnapshot(revision: 3, HerdrAgentStatus.Working),
            connectionEpoch: 4,
            ingestSequence: 12);
        var recovered = CreateSnapshot(revision: 4, HerdrAgentStatus.Idle);
        var apiClient = new ScriptedApiClient(
            [recovered, recovered],
            [ScriptedSubscription.BlockUntilCancelled()]);
        var monitor = CreateMonitor(apiClient, initialState: initial);
        using var cancellation = new CancellationTokenSource();
        var runTask = monitor.RunAsync(cancellation.Token);

        await WaitForAsync(monitor, state => state.BootstrapCount == 1);
        cancellation.Cancel();
        await Assert.ThrowsAsync<OperationCanceledException>(() => runTask);

        Assert.AreEqual(5, monitor.Current.State.ConnectionEpoch);
        Assert.AreEqual(13, monitor.Current.State.LastIngestSequence);
        Assert.AreEqual((ulong)4, monitor.Current.State.Panes["pane-1"].Revision);
    }

    private static HerdrRuntimeMonitor CreateMonitor(
        IHerdrApiClient apiClient,
        IHerdrReconnectDelay? reconnectDelay = null,
        HerdrSessionState? initialState = null) => new(
        apiClient,
        HerdrPipeEndpoint.FromSocketPath("herdrops-scripted-test"),
        reconnectDelay: reconnectDelay ?? new NoReconnectDelay(),
        initialState: initialState);

    private static async Task WaitForAsync(
        HerdrRuntimeMonitor monitor,
        Func<HerdrRuntimeMonitorSnapshot, bool> predicate)
    {
        if (predicate(monitor.Current))
        {
            return;
        }

        var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        EventHandler<HerdrRuntimeMonitorSnapshot>? handler = null;
        handler = (_, state) =>
        {
            if (predicate(state))
            {
                completion.TrySetResult();
            }
        };
        monitor.StateChanged += handler;
        try
        {
            if (predicate(monitor.Current))
            {
                return;
            }

            await completion.Task.WaitAsync(TimeSpan.FromSeconds(5));
        }
        finally
        {
            monitor.StateChanged -= handler;
        }
    }

    private static HerdrSessionSnapshot CreateSnapshot(
        ulong revision,
        HerdrAgentStatus agentStatus) => new(
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
                    agentStatus),
            ],
            [
                new HerdrTabSnapshot(
                    "tab-1",
                    "workspace-1",
                    1,
                    "Core",
                    Focused: true,
                    PaneCount: 1,
                    agentStatus),
            ],
            [
                new HerdrPaneSnapshot(
                    "pane-1",
                    "terminal-1",
                    "workspace-1",
                    "tab-1",
                    Focused: true,
                    agentStatus,
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
                    agentStatus,
                    revision,
                    StateChangeSequence: revision,
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

    private static (HerdrSessionSnapshot Before, HerdrSessionSnapshot After)
        CreateCrossWorkspaceMoveSnapshots()
    {
        var baseline = CreateSnapshot(revision: 1, HerdrAgentStatus.Working);
        var secondWorkspace = new HerdrWorkspaceSnapshot(
            "workspace-2",
            2,
            "Secondary",
            Focused: false,
            PaneCount: 0,
            TabCount: 1,
            ActiveTabId: "tab-2",
            HerdrAgentStatus.Working);
        var secondTab = new HerdrTabSnapshot(
            "tab-2",
            "workspace-2",
            1,
            "Secondary",
            Focused: false,
            PaneCount: 0,
            HerdrAgentStatus.Working);
        var before = baseline with
        {
            Workspaces = [baseline.Workspaces[0], secondWorkspace],
            Tabs = [baseline.Tabs[0], secondTab],
        };
        var movedPane = baseline.Panes[0] with
        {
            PaneId = "pane-2",
            WorkspaceId = "workspace-2",
            TabId = "tab-2",
            Revision = 2,
        };
        var movedAgent = baseline.Agents[0] with
        {
            PaneId = "pane-2",
            WorkspaceId = "workspace-2",
            TabId = "tab-2",
            Revision = 2,
        };
        var after = before with
        {
            Workspaces =
            [
                baseline.Workspaces[0] with { Focused = false, PaneCount = 0 },
                secondWorkspace with { Focused = true, PaneCount = 1 },
            ],
            Tabs =
            [
                baseline.Tabs[0] with { Focused = false, PaneCount = 0 },
                secondTab with { Focused = true, PaneCount = 1 },
            ],
            Panes = [movedPane],
            Agents = [movedAgent],
            FocusedWorkspaceId = "workspace-2",
            FocusedTabId = "tab-2",
            FocusedPaneId = "pane-2",
        };
        return (before, after);
    }

    private sealed class NoReconnectDelay : IHerdrReconnectDelay
    {
        public ValueTask DelayAsync(
            int consecutiveFailureCount,
            CancellationToken cancellationToken) => ValueTask.CompletedTask;
    }

    private sealed class RecordingReconnectDelay : IHerdrReconnectDelay
    {
        public List<int> Attempts { get; } = [];

        public ValueTask DelayAsync(
            int consecutiveFailureCount,
            CancellationToken cancellationToken)
        {
            Attempts.Add(consecutiveFailureCount);
            return ValueTask.CompletedTask;
        }
    }

    private sealed class ScriptedApiClient : IHerdrApiClient
    {
        private readonly Queue<HerdrSessionSnapshot> _snapshots;
        private readonly Queue<IHerdrEventSubscription> _subscriptions;

        public ScriptedApiClient(
            IEnumerable<HerdrSessionSnapshot> snapshots,
            IEnumerable<IHerdrEventSubscription> subscriptions,
            HerdrServerProcessIdentity? serverIdentity = null)
        {
            _snapshots = new Queue<HerdrSessionSnapshot>(snapshots);
            _subscriptions = new Queue<IHerdrEventSubscription>(subscriptions);
            LastVerifiedServerIdentity = serverIdentity;
        }

        public List<HashSet<string>> SubscriptionPaneIds { get; } = [];

        public HerdrServerProcessIdentity? LastVerifiedServerIdentity { get; }

        public Task<HerdrSessionSnapshot> GetSnapshotAsync(
            HerdrPipeEndpoint endpoint,
            CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (_snapshots.Count == 0)
            {
                throw new IOException("No scripted snapshot remains.");
            }

            return Task.FromResult(_snapshots.Dequeue());
        }

        public Task<IHerdrEventSubscription> SubscribeAsync(
            HerdrPipeEndpoint endpoint,
            IReadOnlyCollection<string> paneIds,
            CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            SubscriptionPaneIds.Add(paneIds.ToHashSet(StringComparer.Ordinal));
            if (_subscriptions.Count == 0)
            {
                throw new IOException("No scripted subscription remains.");
            }

            return Task.FromResult(_subscriptions.Dequeue());
        }
    }

    private sealed class ScriptedSubscription : IHerdrEventSubscription
    {
        private readonly Queue<HerdrStateEvent> _events;
        private readonly bool _blockAfterEvents;

        private ScriptedSubscription(IEnumerable<HerdrStateEvent> events, bool blockAfterEvents)
        {
            _events = new Queue<HerdrStateEvent>(events);
            _blockAfterEvents = blockAfterEvents;
        }

        public static ScriptedSubscription EndImmediately() => new([], blockAfterEvents: false);

        public static ScriptedSubscription BlockUntilCancelled() => new([], blockAfterEvents: true);

        public static ScriptedSubscription WithEvents(params HerdrStateEvent[] events) =>
            new(events, blockAfterEvents: false);

        public static ScriptedSubscription WithEventsThenBlock(params HerdrStateEvent[] events) =>
            new(events, blockAfterEvents: true);

        public async ValueTask<HerdrStateEvent> ReadNextAsync(CancellationToken cancellationToken)
        {
            if (_events.Count > 0)
            {
                return _events.Dequeue();
            }

            if (!_blockAfterEvents)
            {
                throw new EndOfStreamException("Scripted disconnect.");
            }

            await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken);
            throw new InvalidOperationException("The scripted blocking read unexpectedly resumed.");
        }

        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }
}
