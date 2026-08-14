using System.Text.RegularExpressions;
using HerdrOps.App.Live;
using HerdrOps.App.Localization;
using HerdrOps.Domain.Activity;
using HerdrOps.Domain.Notifications;

namespace HerdrOps.IntegrationTests;

[TestClass]
[DoNotParallelize]
public sealed class NotificationWidgetStateTests
{
    private static readonly DateTimeOffset BaseUtc = new(
        2026,
        8,
        15,
        2,
        0,
        0,
        TimeSpan.Zero);

    [TestInitialize]
    public void UseThaiDefault() => UiLanguageService.Shared.SetLanguage(UiLanguage.Thai);

    [TestCleanup]
    public void RestoreThaiDefault() => UiLanguageService.Shared.SetLanguage(UiLanguage.Thai);

    [TestMethod]
    public void AcceptedUrgentActivityGroupsOncePreservesRouteAndAcknowledgement()
    {
        var dashboard = CreateDashboard();
        var pipeline = new ActivityEventPipeline();
        var first = dashboard.ApplyActivity(pipeline.Process(CreateEvent(
            "alert-1",
            1,
            BaseUtc,
            ActivityUrgency.Critical,
            "terminal-2",
            "TASK-113",
            "TASK-113")));
        var second = dashboard.ApplyActivity(pipeline.Process(CreateEvent(
            "alert-2",
            2,
            BaseUtc.AddSeconds(1),
            ActivityUrgency.Critical,
            "terminal-2",
            "TASK-113",
            "TASK-113")));

        Assert.IsTrue(first.ShowPopup);
        Assert.IsFalse(second.ShowPopup);
        Assert.AreEqual(NotificationCenterDisposition.Grouped, second.Disposition);
        var notice = dashboard.Widgets.Notices[0];
        Assert.AreEqual(2, notice.GroupCount);
        Assert.AreEqual(2, notice.UnacknowledgedCount);
        Assert.AreEqual("alert-2", notice.Route?.SourceEventId);
        Assert.AreEqual("terminal-2", notice.Route?.AgentTerminalId);
        Assert.AreEqual("TASK-113", notice.Route?.TaskId);
        Assert.AreEqual(second.Item?.NotificationId, notice.Route?.EventIdentitySha256);
        Assert.IsTrue(notice.CanOpen);
        Assert.IsTrue(notice.CanAcknowledge);

        Assert.IsTrue(dashboard.Widgets.AcknowledgeNotificationGroup(
            notice.GroupId,
            BaseUtc.AddSeconds(2)));
        var acknowledged = dashboard.Widgets.Notices[0];
        Assert.IsTrue(acknowledged.IsAcknowledged);
        Assert.IsFalse(acknowledged.CanAcknowledge);
        Assert.AreEqual(0, acknowledged.UnacknowledgedCount);
        Assert.AreEqual(2, dashboard.Widgets.NotificationSnapshot.History.Count(item =>
            item.IsAcknowledged));

        UiLanguageService.Shared.SetLanguage(UiLanguage.English);
        dashboard.RefreshLanguage();
        var english = dashboard.Widgets.Notices[0];
        Assert.AreEqual("Acknowledged", english.AcknowledgementLabel);
        Assert.AreEqual("2 events grouped", english.GroupCountLabel);
        Assert.IsFalse(ContainsThai(string.Join(
            " ",
            english.State,
            english.AcknowledgementLabel,
            english.GroupCountLabel,
            english.OpenAutomationName,
            english.AcknowledgeAutomationName)));
    }

    [TestMethod]
    public void NotificationFloodControlKeepsHistoryGroupsAndPresentationBounded()
    {
        var dashboard = CreateDashboard();
        var pipeline = new ActivityEventPipeline();
        var popupCount = 0;
        for (var index = 0; index < 500; index++)
        {
            var decision = dashboard.ApplyActivity(pipeline.Process(CreateEvent(
                $"flood-{index}",
                index + 1,
                BaseUtc.AddMilliseconds(index * 10),
                ActivityUrgency.High,
                "terminal-2",
                "TASK-113",
                "TASK-113")));
            if (decision.ShowPopup)
            {
                popupCount++;
            }
        }

        var snapshot = dashboard.Widgets.NotificationSnapshot;
        Assert.AreEqual(1, popupCount);
        Assert.HasCount(128, snapshot.History);
        Assert.HasCount(1, snapshot.Groups);
        Assert.AreEqual(128, snapshot.Groups[0].EventCount);
        Assert.AreEqual(500L, snapshot.Diagnostics.AcceptedEventCount);
        Assert.AreEqual(499L, snapshot.Diagnostics.SuppressedUrgentPresentationCount);
        Assert.IsLessThanOrEqualTo(128, snapshot.Diagnostics.PeakHistoryCount);
        Assert.IsLessThanOrEqualTo(512, snapshot.Diagnostics.PeakRememberedIdentityCount);
        Assert.IsLessThanOrEqualTo(32, snapshot.Diagnostics.PeakVisibleGroupCount);
        Assert.HasCount(1, dashboard.Widgets.Notices.Where(notice => notice.CanOpen));
    }

    [TestMethod]
    public void RealtimeActivityDeepLinkSelectsOnlyAnExactKnownEvent()
    {
        var realtime = HerdrOps.App.Activity.RealtimeActivityState.CreateSyntheticPreview();

        Assert.IsTrue(realtime.TrySelectEvent("EVT-007"));
        Assert.AreEqual("EVT-007", realtime.SelectedEvent?.EventId);
        Assert.AreEqual("EVT-007", realtime.SelectedDetail?.EventId);
        var exact = realtime.SelectedEvent!;
        Assert.IsTrue(realtime.TrySelectEvent(
            exact.EventId,
            exact.CorrelationId,
            exact.EventIdentitySha256));
        Assert.IsFalse(realtime.TrySelectEvent(
            exact.EventId,
            exact.CorrelationId,
            new string('0', 64)));
        Assert.IsFalse(realtime.TrySelectEvent("EVT-NOT-PRESENT"));
        Assert.AreEqual("EVT-007", realtime.SelectedEvent?.EventId);
    }

    [TestMethod]
    public void NotificationProjectionFlattensAndBoundsAlreadyRedactedSummaryForTheWidget()
    {
        var dashboard = CreateDashboard();
        var pipeline = new ActivityEventPipeline();
        var summary = $"TASK-113\r\n\t{new string('X', 300)}";

        dashboard.ApplyActivity(pipeline.Process(CreateEvent(
            "bounded-summary",
            1,
            BaseUtc,
            ActivityUrgency.High,
            "terminal-2",
            "TASK-113",
            summary)));
        var notice = dashboard.Widgets.Notices[0];

        Assert.IsLessThanOrEqualTo(180, notice.Message.Length);
        Assert.DoesNotContain("\r", notice.Message, StringComparison.Ordinal);
        Assert.DoesNotContain("\n", notice.Message, StringComparison.Ordinal);
        Assert.DoesNotContain("\t", notice.Message, StringComparison.Ordinal);
        Assert.EndsWith("…", notice.Message, StringComparison.Ordinal);
        Assert.AreEqual(summary.Replace("\r\n", "\n", StringComparison.Ordinal),
            dashboard.Widgets.NotificationSnapshot.History[0].RedactedSummary);
    }

    private static LiveDashboardState CreateDashboard()
    {
        var dashboard = new LiveDashboardState();
        var update = LiveWidgetStateTests.SnapshotUpdate(LiveWidgetStateTests.CreateState(12));
        dashboard.ApplyUpdate(update, update.Envelope.SentUtc.AddMilliseconds(8));
        return dashboard;
    }

    private static ActivityEventEnvelope CreateEvent(
        string sourceEventId,
        long sourceSequence,
        DateTimeOffset observedUtc,
        ActivityUrgency urgency,
        string? agentTerminalId,
        string? taskId,
        string summary) =>
        new(
            ActivityEventContract.Version,
            sourceEventId,
            ActivitySourceKind.HerdrOpsCore,
            "notification-widget-tests",
            "epoch-1",
            sourceSequence,
            ActivityConfidence.Observed,
            urgency,
            ActivityDeliveryMode.Immediate,
            "scope-violation",
            observedUtc,
            observedUtc,
            Guid.Parse("32981895-c954-4eb7-b9de-bc77968747cd"),
            DebounceKey: null,
            agentTerminalId,
            PaneId: "pane-2",
            taskId,
            ProcessId: 2240,
            summary,
            PayloadSha256: new string('B', 64));

    private static bool ContainsThai(string value) => Regex.IsMatch(
        value,
        "[ก-๙]",
        RegexOptions.CultureInvariant);
}
