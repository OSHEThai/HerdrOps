using HerdrOps.App.Live;
using HerdrOps.App.Localization;
using HerdrOps.App.StateIpc;
using HerdrOps.Contracts.StateIpc;
using HerdrOps.Infrastructure.StateIpc;

namespace HerdrOps.IntegrationTests;

[TestClass]
[DoNotParallelize]
public sealed class LiveDashboardStateTests
{
    [TestInitialize]
    public void UseThaiDefault() => UiLanguageService.Shared.SetLanguage(UiLanguage.Thai);

    [TestCleanup]
    public void RestoreThaiDefault() => UiLanguageService.Shared.SetLanguage(UiLanguage.Thai);

    [TestMethod]
    public void CoreSnapshotDrivesAllThreePagesWithoutInventingUnsupportedData()
    {
        var state = HerdrStateTestData.CreateState(sequence: 1);
        var dashboard = new LiveDashboardState();
        var update = SnapshotUpdate(state);

        dashboard.ApplyUpdate(update, update.Envelope.SentUtc.AddMilliseconds(12));

        Assert.IsTrue(dashboard.IsLive);
        Assert.AreEqual(UiLanguageService.Shared["CoreSnapshotSource"], dashboard.SourceLabel);
        Assert.AreEqual(UiLanguageService.Shared["CoreConnectedFreshnessUnknown"], dashboard.ConnectionLabel);
        Assert.AreEqual("HerdrOps", dashboard.ProjectLabel);
        Assert.AreEqual("1", dashboard.Overview.SummaryCards[0].Value);
        Assert.AreEqual("1", dashboard.Overview.SummaryCards.Single(card => card.Id == "working").Value);
        Assert.AreEqual("—", dashboard.Overview.SummaryCards.Single(card => card.Id == "daily-score").Value);
        Assert.IsEmpty(dashboard.Overview.ScoreTrend);
        Assert.AreEqual("—", dashboard.Overview.TopAgents[0].ScoreLabel);
        Assert.IsTrue(dashboard.Organization.Nodes.Any(node => node.AgentTerminalId == "terminal-1"));
        Assert.AreEqual("terminal-1", dashboard.Organization.SelectedAgent.Terminal);
        Assert.AreEqual("terminal-1", dashboard.AgentDetail.Terminal);
        Assert.AreEqual(UiLanguageService.Shared["AgentFactLatestAccepted"], dashboard.AgentDetail.RecentFacts[0].Value);
        Assert.IsTrue(dashboard.AgentDetail.UnsupportedSections.All(
            section => section.Value == UiLanguageService.Shared["ValueUnknown"]));
    }

    [TestMethod]
    public void OfflineTransitionDoesNotLeaveLastKnownWorkingStatusCurrent()
    {
        var state = HerdrStateTestData.CreateState(sequence: 1, status: "Working");
        var dashboard = new LiveDashboardState();
        var update = SnapshotUpdate(state);
        dashboard.ApplyUpdate(update, update.Envelope.SentUtc.AddMilliseconds(5));

        dashboard.MarkOffline(
            new IOException("synthetic disconnect"),
            update.Envelope.SentUtc.AddSeconds(1));

        Assert.IsFalse(dashboard.IsLive);
        Assert.AreEqual(UiLanguageService.Shared["StatusOffline"], dashboard.AgentDetail.Status);
        Assert.AreEqual(UiLanguageService.Shared["StatusOffline"], dashboard.Organization.SelectedAgent.Status);
        var working = dashboard.Overview.SummaryCards.Single(card => card.Id == "working");
        Assert.AreEqual("—", working.Value);
        Assert.AreEqual(UiLanguageService.Shared["StatusOffline"], working.Metric);
        Assert.AreEqual(
            UiLanguageService.Shared.Format("LiveOverviewLastKnownCountFormat", 1),
            working.Trend);
        Assert.IsTrue(dashboard.Overview.Alerts.Any(
            alert => alert.State == UiLanguageService.Shared["StatusOffline"]));
    }

    [TestMethod]
    public void OrganizationSelectionUpdatesAgentDetailFromTheSameSnapshot()
    {
        var state = CreateTwoAgentState();
        var dashboard = new LiveDashboardState();
        var update = SnapshotUpdate(state);
        dashboard.ApplyUpdate(update, update.Envelope.SentUtc.AddMilliseconds(4));
        var second = dashboard.Organization.Nodes.Single(node => node.AgentTerminalId == "terminal-2");

        dashboard.Organization.SelectedNode = second;

        Assert.AreEqual("terminal-2", dashboard.SelectedTerminalId);
        Assert.AreEqual("terminal-2", dashboard.AgentDetail.Terminal);
        Assert.AreEqual(UiLanguageService.Shared["StatusUnknown"], dashboard.AgentDetail.Status);
        Assert.AreEqual("—", dashboard.Overview.TopAgents.Single(agent => agent.Name == "Worker 02").ScoreLabel);
    }

    [TestMethod]
    public async Task DashboardClientCancellationLeavesCorePipeServerRunning()
    {
        var pipeName = $"herdrops-dashboard-lifecycle-{Guid.NewGuid():N}";
        var server = new HerdrOpsStatePipeServer(
            new HerdrOpsStatePipeServerOptions(pipeName),
            HerdrStateTestData.Snapshot(HerdrSessionStateContract.Empty));
        using var serverCancellation = new CancellationTokenSource();
        var serverTask = server.RunAsync(serverCancellation.Token);
        await server.Ready.WaitAsync(TimeSpan.FromSeconds(5));
        var dashboard = new LiveDashboardState();
        var session = new LiveDashboardSession(
            new HerdrOpsStatePipeClient(new HerdrOpsStatePipeClientOptions(pipeName)),
            dashboard,
            new ImmediateScheduler());
        using var dashboardCancellation = new CancellationTokenSource();
        var dashboardTask = session.RunAsync(dashboardCancellation.Token);
        try
        {
            await WaitUntilAsync(() => dashboard.IsLive);
            dashboardCancellation.Cancel();
            await dashboardTask.WaitAsync(TimeSpan.FromSeconds(5));

            Assert.AreEqual(LiveDashboardConnectionStatus.Stopped, dashboard.ConnectionStatus);
            Assert.IsFalse(serverTask.IsCompleted, "Closing the Dashboard subscription must not stop Core collection.");
            var successor = new HerdrOpsStatePipeClient(new HerdrOpsStatePipeClientOptions(pipeName));
            await using var updates = successor.ReadUpdatesAsync().GetAsyncEnumerator();
            Assert.IsTrue(await updates.MoveNextAsync().AsTask().WaitAsync(TimeSpan.FromSeconds(5)));
            Assert.AreEqual(HerdrOpsStateUpdateKind.Snapshot, updates.Current.Kind);
        }
        finally
        {
            dashboardCancellation.Cancel();
            serverCancellation.Cancel();
            await ObserveCancellationAsync(dashboardTask);
            await ObserveCancellationAsync(serverTask);
        }
    }

    private static HerdrOpsStateUpdate SnapshotUpdate(HerdrSessionStateContract state)
    {
        var payload = HerdrStateTestData.Snapshot(state);
        var envelope = HerdrOpsStateIpcJson.CreateEnvelope(
            HerdrOpsStateIpcProtocol.MessageTypes.Snapshot,
            state.LastIngestSequence,
            HerdrStateTestData.ObservedUtc.AddSeconds(state.LastIngestSequence),
            HerdrOpsStateIpcProtocol.CoreSource,
            Guid.NewGuid(),
            payload);
        return new HerdrOpsStateUpdate(
            HerdrOpsStateUpdateKind.Snapshot,
            state,
            envelope,
            payload,
            null);
    }

    private static HerdrSessionStateContract CreateTwoAgentState()
    {
        var first = HerdrStateTestData.CreateState(sequence: 1);
        return HerdrSessionStateContractReducer.NormalizeAndValidate(first with
        {
            Workspaces =
            [
                first.Workspaces[0] with { PaneCount = 2 },
            ],
            Tabs =
            [
                first.Tabs[0] with { PaneCount = 2 },
            ],
            Panes =
            [
                first.Panes[0],
                new HerdrPaneStateContract(
                    "pane-2",
                    "terminal-2",
                    "workspace-1",
                    "tab-1",
                    Focused: false,
                    "Unknown",
                    Revision: 1,
                    "claude",
                    "Claude",
                    "Worker",
                    "Z:\\HerdrOps",
                    "Z:\\HerdrOps",
                    "Claude"),
            ],
            Agents =
            [
                first.Agents[0],
                new HerdrAgentStateContract(
                    "terminal-2",
                    "workspace-1",
                    "tab-1",
                    "pane-2",
                    Focused: false,
                    "Unknown",
                    Revision: 1,
                    StateChangeSequence: 1,
                    "claude",
                    "Claude",
                    "Worker 02",
                    "Worker",
                    "Z:\\HerdrOps",
                    "Z:\\HerdrOps",
                    "Claude",
                    InteractiveReady: null,
                    LaunchPending: null,
                    ScreenDetectionSkipped: null),
            ],
        });
    }

    private static async Task WaitUntilAsync(Func<bool> predicate)
    {
        var deadline = DateTime.UtcNow.AddSeconds(5);
        while (!predicate() && DateTime.UtcNow < deadline)
        {
            await Task.Delay(10);
        }

        Assert.IsTrue(predicate(), "The live Dashboard state did not arrive within five seconds.");
    }

    private static async Task ObserveCancellationAsync(Task task)
    {
        try
        {
            await task.WaitAsync(TimeSpan.FromSeconds(5));
        }
        catch (OperationCanceledException)
        {
        }
    }

    private sealed class ImmediateScheduler : ILiveDashboardUiScheduler
    {
        public ValueTask InvokeAsync(Action action, CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            action();
            return ValueTask.CompletedTask;
        }
    }
}
