using HerdrOps.App.Live;
using HerdrOps.App.Localization;
using HerdrOps.App.StateIpc;
using HerdrOps.App.Widgets;
using HerdrOps.Contracts.StateIpc;
using HerdrOps.Infrastructure.StateIpc;

namespace HerdrOps.IntegrationTests;

[TestClass]
[DoNotParallelize]
public sealed class LiveWidgetStateTests
{
    [TestInitialize]
    public void UseThaiDefault() => UiLanguageService.Shared.SetLanguage(UiLanguage.Thai);

    [TestCleanup]
    public void RestoreThaiDefault() => UiLanguageService.Shared.SetLanguage(UiLanguage.Thai);

    [TestMethod]
    public void DashboardAndWidgetsUseTheSameSnapshotSelectionAndLatency()
    {
        var state = CreateState(sequence: 12);
        var update = SnapshotUpdate(state);
        var dashboard = new LiveDashboardState();
        var acceptedStateUtc = update.RuntimeHealth.LastAcceptedStateUtc!.Value;
        update = update with
        {
            Envelope = update.Envelope with
            {
                SentUtc = acceptedStateUtc.AddMilliseconds(10),
            },
        };

        dashboard.ApplyUpdate(update, acceptedStateUtc.AddMilliseconds(18));

        Assert.AreEqual(dashboard.CurrentState.LastIngestSequence, dashboard.Widgets.Sequence);
        Assert.AreEqual(dashboard.CurrentState.Agents.Count, dashboard.Widgets.TotalAgents);
        Assert.AreEqual("1", dashboard.Widgets.WorkingCountLabel);
        Assert.AreEqual("1", dashboard.Widgets.BlockedCountLabel);
        Assert.AreEqual("1", dashboard.Widgets.DoneCountLabel);
        Assert.AreEqual(UiLanguageService.Shared["CoreStateSource"], dashboard.Widgets.SourceLabel);
        Assert.AreEqual(UiLanguageService.Shared["ValueUnknown"], dashboard.Widgets.DailyScoreLabel);
        Assert.AreEqual("terminal-1", dashboard.Widgets.SelectedAgent.TerminalId);
        Assert.AreEqual(1, dashboard.Widgets.UpdateSampleCount);
        Assert.AreEqual(18d, dashboard.Widgets.LastUpdateLatencyMilliseconds);
        Assert.AreEqual(18d, dashboard.Widgets.P95UpdateLatencyMilliseconds);
        var sample = dashboard.Widgets.UpdateLatencySnapshot.Samples.Single();
        Assert.AreEqual(12L, sample.StateSequence);
        Assert.AreEqual(update.RuntimeHealth.EventCount, sample.EventCount);
        Assert.AreEqual(update.Envelope.Sequence, sample.EnvelopeSequence);
        Assert.AreEqual(update.Envelope.CorrelationId, sample.EnvelopeCorrelationId);
        Assert.AreEqual(HerdrOpsStateIpcJson.ComputeSha256(state), sample.StateSha256);
        Assert.AreEqual(HerdrOpsStateUpdateKind.Snapshot.ToString(), sample.UpdateKind);
        Assert.AreEqual(acceptedStateUtc, sample.CoreAcceptedStateUtc);
        Assert.AreEqual(acceptedStateUtc.AddMilliseconds(10), sample.IpcSentUtc);
        Assert.AreEqual(acceptedStateUtc.AddMilliseconds(18), sample.WpfAppliedUtc);

        dashboard.SelectAgent("terminal-3");

        Assert.AreEqual("terminal-3", dashboard.AgentDetail.Terminal);
        Assert.AreEqual("terminal-3", dashboard.Widgets.SelectedAgent.TerminalId);
        Assert.AreEqual(1, dashboard.Widgets.UpdateSampleCount);
    }

    [TestMethod]
    public void CoreOfflineMakesWidgetCountsAndAgentStatusesFailClosed()
    {
        var state = CreateState(sequence: 12);
        var update = SnapshotUpdate(state);
        var dashboard = new LiveDashboardState();
        dashboard.ApplyUpdate(update, update.Envelope.SentUtc.AddMilliseconds(9));

        dashboard.MarkOffline(
            new IOException("contract-backed disconnect"),
            update.Envelope.SentUtc.AddSeconds(1));

        Assert.IsFalse(dashboard.Widgets.IsLive);
        Assert.AreEqual(UiLanguageService.Shared["LastKnownSource"], dashboard.Widgets.SourceLabel);
        Assert.AreEqual("—", dashboard.Widgets.WorkingCountLabel);
        Assert.AreEqual("—", dashboard.Widgets.BlockedCountLabel);
        Assert.AreEqual("—", dashboard.Widgets.DoneCountLabel);
        Assert.IsTrue(dashboard.Widgets.Agents.All(
            agent => agent.Status == UiLanguageService.Shared["StatusOffline"]));
        Assert.AreEqual(UiLanguageService.Shared["StatusOffline"], dashboard.Widgets.Notices[0].State);
        Assert.IsFalse(dashboard.Widgets.Notices.Any(notice =>
            notice.State == UiLanguageService.Shared["StatusBlocked"] ||
            notice.State == UiLanguageService.Shared["StatusDone"]));
    }

    [TestMethod]
    public void ConnectedCoreWithoutAdmittedHerdrStateKeepsWidgetCountsUnknown()
    {
        var state = HerdrSessionStateContract.Empty;
        var update = SnapshotUpdate(state);
        var dashboard = new LiveDashboardState();

        dashboard.ApplyUpdate(update, update.Envelope.SentUtc.AddMilliseconds(7));

        Assert.IsTrue(dashboard.IsCoreConnected, "Core connectivity remains independently visible.");
        Assert.IsFalse(dashboard.Widgets.IsLive, "Herdr is not live before an admitted snapshot.");
        Assert.AreEqual(UiLanguageService.Shared["NoHerdrStateSource"], dashboard.Widgets.SourceLabel);
        Assert.AreEqual(UiLanguageService.Shared["EmptyCompact"], dashboard.Widgets.CompactSourceLabel);
        Assert.AreEqual("—", dashboard.Widgets.WorkingCountLabel);
        Assert.AreEqual("—", dashboard.Widgets.BlockedCountLabel);
        Assert.AreEqual("—", dashboard.Widgets.DoneCountLabel);
        Assert.IsEmpty(dashboard.Widgets.Agents);
        Assert.AreEqual(UiLanguageService.Shared["StatusUnknown"], dashboard.Widgets.Notices.Single().State);
    }

    [TestMethod]
    public void BlockedAndDoneAttentionBadgesRemainDistinct()
    {
        var state = CreateState(sequence: 12);
        var update = SnapshotUpdate(state);
        var dashboard = new LiveDashboardState();

        dashboard.ApplyUpdate(update, update.Envelope.SentUtc.AddMilliseconds(11));

        var blocked = dashboard.Widgets.PriorityNotices.Single(
            notice => notice.State == UiLanguageService.Shared["StatusBlocked"]);
        var done = dashboard.Widgets.PriorityNotices.Single(
            notice => notice.State == UiLanguageService.Shared["StatusDone"]);
        Assert.AreNotEqual(blocked.IconGlyph, done.IconGlyph);
        Assert.AreNotEqual(blocked.StatusBrushKey, done.StatusBrushKey);
        StringAssert.Contains(blocked.AgentName, UiLanguageService.Shared["StatusBlocked"]);
        StringAssert.Contains(done.AgentName, UiLanguageService.Shared["StatusDone"]);
    }

    [TestMethod]
    public void WidgetTelemetryKeepsBoundedSamplesAndComputesP95()
    {
        var telemetry = new WidgetUpdateTelemetry();
        for (var milliseconds = 1; milliseconds <= 600; milliseconds++)
        {
            telemetry.Record(TimeSpan.FromMilliseconds(milliseconds));
        }

        var snapshot = telemetry.Snapshot();

        Assert.AreEqual(512, snapshot.SampleCount);
        Assert.AreEqual(600d, snapshot.LastMilliseconds);
        Assert.AreEqual(575d, snapshot.P95Milliseconds);
    }

    [TestMethod]
    public void RuntimeLatencyBaselineExcludesInitialCatchupAndKeepsProvenance()
    {
        var dashboard = new LiveDashboardState();
        var initial = SnapshotUpdate(CreateState(sequence: 1));
        var initialAcceptedUtc = initial.RuntimeHealth.LastAcceptedStateUtc!.Value;
        initial = initial with
        {
            Envelope = initial.Envelope with
            {
                SentUtc = initialAcceptedUtc.AddMilliseconds(5),
            },
        };
        dashboard.ApplyUpdate(initial, initialAcceptedUtc.AddMilliseconds(1_200));

        var excluded = dashboard.Widgets.ResetUpdateLatencyMeasurement();

        Assert.AreEqual(1, excluded.SampleCount);
        Assert.AreEqual(1_200d, excluded.P95Milliseconds);
        Assert.AreEqual(0, dashboard.Widgets.UpdateSampleCount);

        foreach (var sequence in new long[] { 2, 3, 4 })
        {
            var update = SnapshotUpdate(CreateState(sequence));
            var acceptedUtc = update.RuntimeHealth.LastAcceptedStateUtc!.Value;
            update = update with
            {
                Envelope = update.Envelope with
                {
                    SentUtc = acceptedUtc.AddMilliseconds(2),
                },
            };
            dashboard.ApplyUpdate(update, acceptedUtc.AddMilliseconds(10));
        }

        var candidate = dashboard.Widgets.UpdateLatencySnapshot;
        Assert.AreEqual(3, candidate.SampleCount);
        Assert.AreEqual(10d, candidate.P95Milliseconds);
        CollectionAssert.AreEqual(
            new long[] { 2, 3, 4 },
            candidate.Samples.Select(sample => sample.StateSequence).ToArray());
        Assert.IsTrue(candidate.Samples.All(sample => sample.UpdateKind == "Snapshot"));
        Assert.IsTrue(candidate.Samples.All(sample => sample.Milliseconds == 10d));
    }

    [TestMethod]
    public void RuntimeLatencyRejectsAnUnboundEnvelopeIdentity()
    {
        var telemetry = new WidgetUpdateTelemetry();
        var acceptedUtc = HerdrStateTestData.ObservedUtc;

        Assert.ThrowsExactly<ArgumentOutOfRangeException>(() => telemetry.Record(
            new WidgetUpdateLatencySample(
                StateSequence: 12,
                EventCount: 4,
                EnvelopeSequence: 12,
                EnvelopeCorrelationId: Guid.Empty,
                StateSha256: HerdrOpsStateIpcJson.ComputeSha256(CreateState(sequence: 12)),
                UpdateKind: "Delta",
                acceptedUtc,
                acceptedUtc.AddMilliseconds(2),
                acceptedUtc.AddMilliseconds(9))));
    }

    [TestMethod]
    public async Task AppRuntimeOwnsSubscriptionWithoutDashboardWindowLifetime()
    {
        var pipeName = $"herdrops-app-runtime-{Guid.NewGuid():N}";
        var server = new HerdrOpsStatePipeServer(
            new HerdrOpsStatePipeServerOptions(pipeName),
            HerdrStateTestData.Snapshot(CreateState(sequence: 12)));
        using var serverCancellation = new CancellationTokenSource();
        var serverTask = server.RunAsync(serverCancellation.Token);
        await server.Ready.WaitAsync(TimeSpan.FromSeconds(5));
        var dashboard = new LiveDashboardState();
        using var runtime = new LiveDashboardRuntime(
            new HerdrOpsStatePipeClient(new HerdrOpsStatePipeClientOptions(pipeName)),
            dashboard,
            new ImmediateScheduler());
        runtime.Start();
        try
        {
            await WaitUntilAsync(() => dashboard.IsLive);
            Assert.IsTrue(runtime.IsRunning);
            Assert.IsFalse(serverTask.IsCompleted);

            runtime.Stop();
            await runtime.Completion.WaitAsync(TimeSpan.FromSeconds(5));

            Assert.IsFalse(runtime.IsRunning);
            Assert.AreEqual(LiveDashboardConnectionStatus.Stopped, dashboard.ConnectionStatus);
            Assert.IsFalse(serverTask.IsCompleted, "Stopping the App subscription must not stop Core.");

            var queueTitle = dashboard.ComplianceQueue.SummaryCards[0].Title;
            runtime.Dispose();
            UiLanguageService.Shared.SetLanguage(UiLanguage.English);
            dashboard.ComplianceQueue.RefreshLanguage();
            Assert.AreEqual(
                queueTitle,
                dashboard.ComplianceQueue.SummaryCards[0].Title,
                "Disposing the App runtime must dispose its owned dashboard state.");
        }
        finally
        {
            runtime.Stop();
            serverCancellation.Cancel();
            await ObserveCancellationAsync(runtime.Completion);
            await ObserveCancellationAsync(serverTask);
        }
    }

    internal static HerdrSessionStateContract CreateState(long sequence)
    {
        var revision = checked((ulong)sequence);
        return HerdrSessionStateContractReducer.NormalizeAndValidate(new HerdrSessionStateContract(
            "0.8.0-preview",
            19,
            2,
            sequence,
            [new("workspace-1", 1, "HerdrOps", true, 3, 1, "tab-1", "Blocked")],
            [new("tab-1", "workspace-1", 1, "Implementation", true, 3, "Blocked")],
            [
                new("pane-1", "terminal-1", "workspace-1", "tab-1", true, "Working", revision, "codex", "Codex", "Worker", "Z:\\HerdrOps", "Z:\\HerdrOps", "Codex"),
                new("pane-2", "terminal-2", "workspace-1", "tab-1", false, "Blocked", revision, "claude", "Claude", "Reviewer", "Z:\\HerdrOps", "Z:\\HerdrOps", "Claude"),
                new("pane-3", "terminal-3", "workspace-1", "tab-1", false, "Done", revision, "codex", "Codex", "Worker", "Z:\\HerdrOps", "Z:\\HerdrOps", "Codex"),
            ],
            [
                new("terminal-1", "workspace-1", "tab-1", "pane-1", true, "Working", revision, revision, "codex", "Codex", "Worker 01", "Worker", "Z:\\HerdrOps", "Z:\\HerdrOps", "Codex", true, false, false),
                new("terminal-2", "workspace-1", "tab-1", "pane-2", false, "Blocked", revision, revision, "claude", "Claude", "Reviewer 01", "Reviewer", "Z:\\HerdrOps", "Z:\\HerdrOps", "Claude", true, false, false),
                new("terminal-3", "workspace-1", "tab-1", "pane-3", false, "Done", revision, revision, "codex", "Codex", "Worker 02", "Worker", "Z:\\HerdrOps", "Z:\\HerdrOps", "Codex", true, false, false),
            ],
            "workspace-1",
            "tab-1",
            "pane-1"));
    }

    internal static HerdrOpsStateUpdate SnapshotUpdate(HerdrSessionStateContract state)
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
            null,
            payload.RuntimeHealth);
    }

    private static async Task WaitUntilAsync(Func<bool> predicate)
    {
        var deadline = DateTime.UtcNow.AddSeconds(5);
        while (!predicate() && DateTime.UtcNow < deadline)
        {
            await Task.Delay(10);
        }

        Assert.IsTrue(predicate(), "The App-owned live state did not arrive within five seconds.");
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
