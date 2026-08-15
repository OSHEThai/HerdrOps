using System.IO;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using HerdrOps.App;
using HerdrOps.App.Live;
using HerdrOps.App.Localization;
using HerdrOps.App.StateIpc;
using HerdrOps.App.Widgets;
using HerdrOps.Contracts.StateIpc;
using HerdrOps.Domain.Activity;

namespace HerdrOps.RuntimeTests;

[TestClass]
[DoNotParallelize]
public sealed class NotificationWidgetRenderingTests
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
    public void ActualWpfNotificationAndAgentPopupRenderAsSeparateThaiAndEnglishModes()
    {
        WpfTestHost.Run(RenderLocalizedEvidence, TimeSpan.FromSeconds(90));
    }

    [TestMethod]
    public void WidgetActionsAcknowledgeAndForwardExactRoutesThroughTheWindowHost()
    {
        WpfTestHost.Run(() =>
        {
            UiLanguageService.Shared.SetLanguage(UiLanguage.Thai);
            try
            {
                var dashboard = CreateDashboard();
                var router = new RecordingRouter();
                var notificationWindow = new WidgetWindow(
                    WidgetCatalog.Get(WidgetVariant.Notification),
                    dashboard.Widgets,
                    router);
                notificationWindow.Show();
                notificationWindow.UpdateLayout();
                try
                {
                    var notificationSurface = Assert.IsInstanceOfType<WidgetSurface>(
                        notificationWindow.FindName("Surface"));
                    var openButton = EnumerateDescendants(notificationSurface)
                        .OfType<Button>()
                        .First(button =>
                            button.CommandParameter is WidgetNotice { CanOpen: true } notice &&
                            string.Equals(
                                AutomationProperties.GetName(button),
                                notice.OpenAutomationName,
                                StringComparison.Ordinal));
                    var openedNotice = Assert.IsInstanceOfType<WidgetNotice>(openButton.CommandParameter);
                    openButton.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));

                    Assert.HasCount(1, router.Notifications);
                    Assert.AreEqual(openedNotice.Route, router.Notifications[0]);

                    var acknowledgeButton = EnumerateDescendants(notificationSurface)
                        .OfType<Button>()
                        .First(button =>
                            button.CommandParameter is WidgetNotice { CanAcknowledge: true } notice &&
                            string.Equals(
                                AutomationProperties.GetName(button),
                                notice.AcknowledgeAutomationName,
                                StringComparison.Ordinal));
                    var acknowledgedNotice = Assert.IsInstanceOfType<WidgetNotice>(
                        acknowledgeButton.CommandParameter);
                    acknowledgeButton.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));

                    var acknowledgedGroup = dashboard.Widgets.NotificationSnapshot.Groups.Single(group =>
                        string.Equals(group.GroupId, acknowledgedNotice.GroupId, StringComparison.Ordinal));
                    Assert.AreEqual(0, acknowledgedGroup.UnacknowledgedCount);

                    var historyButton = Assert.IsInstanceOfType<Button>(
                        notificationSurface.FindName("ViewAllNotificationsButton"));
                    historyButton.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                    Assert.AreEqual(1, router.NotificationHistoryOpenCount);
                }
                finally
                {
                    notificationWindow.Close();
                }

                var agentWindow = new WidgetWindow(
                    WidgetCatalog.Get(WidgetVariant.AgentDetailPopup),
                    dashboard.Widgets,
                    router);
                agentWindow.Show();
                agentWindow.UpdateLayout();
                try
                {
                    var agentSurface = Assert.IsInstanceOfType<WidgetSurface>(
                        agentWindow.FindName("Surface"));
                    var agentButton = Assert.IsInstanceOfType<Button>(
                        agentSurface.FindName("ViewSelectedAgentButton"));
                    agentButton.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                    Assert.AreEqual(dashboard.Widgets.SelectedAgent.TerminalId, router.Agents.Single());
                }
                finally
                {
                    agentWindow.Close();
                }
            }
            finally
            {
                UiLanguageService.Shared.SetLanguage(UiLanguage.Thai);
            }
        });
    }

    [TestMethod]
    public void ApplicationRouterSelectsExactEventThenFallsBackOnlyToAnExactAgent()
    {
        WpfTestHost.Run(() =>
        {
            var application = Application.Current;
            var previousMainWindow = application.MainWindow;
            MainWindow? window = null;
            try
            {
                var preview = LiveDashboardState.CreateSyntheticPreview();
                window = new MainWindow(preview);
                application.MainWindow = window;
                var exactEvent = preview.RealtimeActivity.VisibleEvents.Single(item =>
                    string.Equals(item.EventId, "EVT-007", StringComparison.Ordinal));
                var eventRoute = new WidgetNotificationRoute(
                    exactEvent.EventId,
                    exactEvent.CorrelationId,
                    exactEvent.EventIdentitySha256,
                    AgentTerminalId: null,
                    TaskId: "TASK-113");

                Assert.IsTrue(ApplicationWidgetActionRouter.Shared.OpenNotification(eventRoute));
                Assert.AreEqual("realtime-activity", window.Shell.Navigation.SelectedDestination.Id);
                Assert.AreEqual("EVT-007", preview.RealtimeActivity.SelectedEvent?.EventId);
                window.Close();

                var live = CreateDashboard();
                window = new MainWindow(live);
                application.MainWindow = window;
                var agentRoute = eventRoute with
                {
                    SourceEventId = "event-not-in-realtime-page",
                    AgentTerminalId = "terminal-2",
                };
                Assert.IsTrue(ApplicationWidgetActionRouter.Shared.OpenNotification(agentRoute));
                Assert.AreEqual("agent-detail", window.Shell.Navigation.SelectedDestination.Id);
                Assert.AreEqual("terminal-2", live.SelectedTerminalId);

                var missingRoute = agentRoute with { AgentTerminalId = "terminal-missing" };
                Assert.IsFalse(ApplicationWidgetActionRouter.Shared.OpenNotification(missingRoute));
                Assert.AreEqual("terminal-2", live.SelectedTerminalId);
            }
            finally
            {
                if (window?.IsVisible == true)
                {
                    window.Close();
                }

                application.MainWindow = previousMainWindow;
                UiLanguageService.Shared.SetLanguage(UiLanguage.Thai);
            }
        });
    }

    private static void RenderLocalizedEvidence()
    {
        var evidenceDirectory = Path.Combine(
            FindRepositoryRoot(),
            "artifacts",
            "design-evidence",
            "v0.3.0",
            "issue-16",
            "contract-backed-wpf");
        Directory.CreateDirectory(evidenceDirectory);
        try
        {
            foreach (var language in new[] { UiLanguage.Thai, UiLanguage.English })
            {
                UiLanguageService.Shared.SetLanguage(language);
                var dashboard = CreateDashboard();
                var languageName = language == UiLanguage.Thai ? "th" : "en";
                var notification = CreateSurface(dashboard.Widgets, WidgetVariant.Notification);
                var detail = CreateSurface(dashboard.Widgets, WidgetVariant.AgentDetailPopup);

                RenderPng(
                    notification,
                    328,
                    410,
                    Path.Combine(evidenceDirectory, $"notification-{languageName}-328x410.png"));
                RenderPng(
                    detail,
                    340,
                    448,
                    Path.Combine(evidenceDirectory, $"agent-detail-{languageName}-340x448.png"));

                var visibleNotificationText = VisibleText(notification);
                Assert.IsTrue(visibleNotificationText.Contains(
                    UiLanguageService.Shared["WidgetNotificationFixtureDone"],
                    StringComparer.Ordinal));
                Assert.IsTrue(visibleNotificationText.Any(text => text.Contains(
                    language == UiLanguage.Thai ? "เหตุการณ์" : "events grouped",
                    StringComparison.Ordinal)));
                Assert.IsLessThanOrEqualTo(4, dashboard.Widgets.Notices.Count);
                Assert.IsTrue(dashboard.Widgets.Notices.Any(notice => notice.GroupCount == 2));
                Assert.IsTrue(dashboard.Widgets.Notices.Any(notice => notice.IsAcknowledged));

                var notificationItems = Assert.IsInstanceOfType<ItemsControl>(
                    notification.FindName("NotificationItems"));
                Assert.AreEqual(dashboard.Widgets.Notices.Count, notificationItems.Items.Count);
                var interactiveButtons = EnumerateDescendants(notification)
                    .OfType<Button>()
                    .Where(button => button.CommandParameter is WidgetNotice)
                    .ToArray();
                Assert.IsTrue(interactiveButtons.All(button =>
                    !string.IsNullOrWhiteSpace(AutomationProperties.GetName(button))));

                if (language == UiLanguage.English)
                {
                    AssertNoVisibleThaiCopy(notification);
                    AssertNoVisibleThaiCopy(detail);
                }
                else
                {
                    AssertVisibleTextDoesNotContain(notification, "Critical");
                    AssertVisibleTextDoesNotContain(notification, "Acknowledged");
                    AssertVisibleTextDoesNotContain(detail, "Recent Activity");
                    AssertVisibleTextDoesNotContain(detail, "View all details");
                }
            }
        }
        finally
        {
            UiLanguageService.Shared.SetLanguage(UiLanguage.Thai);
        }
    }

    private static WidgetSurface CreateSurface(IWidgetState state, WidgetVariant variant)
    {
        var descriptor = WidgetCatalog.Get(variant);
        var surface = new WidgetSurface(state)
        {
            Width = descriptor.WindowWidth,
            Height = descriptor.WindowHeight,
            Variant = variant,
            IsInteractive = true,
        };
        Layout(surface, descriptor.WindowWidth, descriptor.WindowHeight);
        return surface;
    }

    private static LiveDashboardState CreateDashboard()
    {
        var dashboard = new LiveDashboardState();
        var state = CreateState();
        var runtimeHealth = new HerdrRuntimeHealthContract(
            "Connected",
            BaseUtc,
            BaseUtc,
            BootstrapCount: 2,
            EventCount: state.LastIngestSequence,
            DisconnectCount: 0,
            ReconciliationCount: 0);
        var payload = new HerdrOpsStateSnapshotPayload(
            state,
            HerdrOpsStateIpcJson.ComputeSha256(state),
            runtimeHealth);
        var envelope = HerdrOpsStateIpcJson.CreateEnvelope(
            HerdrOpsStateIpcProtocol.MessageTypes.Snapshot,
            state.LastIngestSequence,
            BaseUtc,
            HerdrOpsStateIpcProtocol.CoreSource,
            Guid.Parse("ce835922-0909-4920-b189-9758120771b6"),
            payload);
        dashboard.ApplyUpdate(
            new HerdrOpsStateUpdate(
                HerdrOpsStateUpdateKind.Snapshot,
                state,
                envelope,
                payload,
                Delta: null,
                payload.RuntimeHealth),
            BaseUtc.AddMilliseconds(8));
        dashboard.SelectAgent("terminal-2");

        var pipeline = new ActivityEventPipeline();
        var events = new[]
        {
            CreateEvent(1, "scope-1", "scope-violation", "terminal-2", "TASK-113", ActivityUrgency.Critical, "WidgetNotificationFixtureScope"),
            CreateEvent(2, "scope-2", "scope-violation", "terminal-2", "TASK-113", ActivityUrgency.Critical, "WidgetNotificationFixtureScope"),
            CreateEvent(3, "blocked-1", "dependency-blocked", "terminal-3", "TASK-122", ActivityUrgency.High, "WidgetNotificationFixtureBlocked"),
            CreateEvent(4, "review-1", "review-ready", "terminal-1", "TASK-115", ActivityUrgency.High, "WidgetNotificationFixtureReview"),
            CreateEvent(5, "done-1", "task-done", "terminal-1", "TASK-118", ActivityUrgency.Normal, "WidgetNotificationFixtureDone"),
        };
        foreach (var activityEvent in events)
        {
            dashboard.ApplyActivity(pipeline.Process(activityEvent));
        }

        var review = dashboard.Widgets.Notices.Single(notice => string.Equals(
            notice.Message,
            UiLanguageService.Shared["WidgetNotificationFixtureReview"],
            StringComparison.Ordinal));
        dashboard.Widgets.AcknowledgeNotificationGroup(review.GroupId, BaseUtc.AddSeconds(6));
        return dashboard;
    }

    private static ActivityEventEnvelope CreateEvent(
        long sequence,
        string sourceEventId,
        string eventType,
        string terminalId,
        string taskId,
        ActivityUrgency urgency,
        string summaryKey) =>
        new(
            ActivityEventContract.Version,
            sourceEventId,
            ActivitySourceKind.HerdrOpsCore,
            "notification-rendering",
            "epoch-1",
            sequence,
            ActivityConfidence.Observed,
            urgency,
            ActivityDeliveryMode.Immediate,
            eventType,
            BaseUtc.AddSeconds(sequence),
            BaseUtc.AddSeconds(sequence),
            Guid.Parse("8023c1d9-8463-41cc-b926-d2056c64f347"),
            DebounceKey: null,
            terminalId,
            $"pane-{terminalId[^1]}",
            taskId,
            3000 + checked((int)sequence),
            UiLanguageService.Shared[summaryKey],
            new string('D', 64));

    private static HerdrSessionStateContract CreateState()
    {
        var thai = UiLanguageService.Shared.CurrentLanguage == UiLanguage.Thai;
        var names = thai
            ? new[] { "หัวหน้าทีมแบ็กเอนด์", "ผู้ปฏิบัติงานแบ็กเอนด์ 01", "ผู้ปฏิบัติงานทดสอบ" }
            : new[] { "Backend Leader", "Backend Worker 01", "Test Worker" };
        var roles = thai
            ? new[] { "หัวหน้าทีม", "ผู้ปฏิบัติงาน", "ผู้ปฏิบัติงาน" }
            : new[] { "Leader", "Worker", "Worker" };
        var statuses = new[] { "Working", "Blocked", "Idle" };
        var panes = statuses.Select((status, index) => new HerdrPaneStateContract(
            $"pane-{index + 1}",
            $"terminal-{index + 1}",
            "workspace-1",
            "tab-1",
            index == 0,
            status,
            checked((ulong)(20 + index)),
            "codex",
            "Codex",
            roles[index],
            "Z:\\HerdrOps",
            "Z:\\HerdrOps",
            "Codex")).ToArray();
        var agents = statuses.Select((status, index) => new HerdrAgentStateContract(
            $"terminal-{index + 1}",
            "workspace-1",
            "tab-1",
            $"pane-{index + 1}",
            index == 0,
            status,
            checked((ulong)(20 + index)),
            checked((ulong)(20 + index)),
            "codex",
            "Codex",
            names[index],
            roles[index],
            "Z:\\HerdrOps",
            "Z:\\HerdrOps",
            "Codex",
            true,
            false,
            false)).ToArray();
        return HerdrSessionStateContractReducer.NormalizeAndValidate(new HerdrSessionStateContract(
            "0.8.0-preview",
            19,
            2,
            20,
            [new("workspace-1", 1, "HerdrOps", true, 3, 1, "tab-1", "Blocked")],
            [new("tab-1", "workspace-1", 1, "Implementation", true, 3, "Blocked")],
            panes,
            agents,
            "workspace-1",
            "tab-1",
            "pane-1"));
    }

    private static IReadOnlyList<string> VisibleText(DependencyObject root) =>
        EnumerateDescendants(root)
            .OfType<TextBlock>()
            .Where(IsEffectivelyVisible)
            .Select(text => new TextRange(text.ContentStart, text.ContentEnd).Text.Trim())
            .Where(text => !string.IsNullOrWhiteSpace(text))
            .ToArray();

    private static void AssertNoVisibleThaiCopy(DependencyObject root)
    {
        var thai = VisibleText(root)
            .Where(value => Regex.IsMatch(value, "[ก-๙]", RegexOptions.CultureInvariant))
            .ToArray();
        Assert.IsEmpty(thai, $"English mode contains Thai copy: {string.Join(" | ", thai)}");
    }

    private static void AssertVisibleTextDoesNotContain(DependencyObject root, string unexpected) =>
        Assert.IsFalse(
            VisibleText(root).Any(value => value.Contains(unexpected, StringComparison.Ordinal)),
            $"Visible text contains copy from the other language: {unexpected}");

    private static IEnumerable<DependencyObject> EnumerateDescendants(DependencyObject parent)
    {
        for (var index = 0; index < VisualTreeHelper.GetChildrenCount(parent); index++)
        {
            var child = VisualTreeHelper.GetChild(parent, index);
            yield return child;
            foreach (var descendant in EnumerateDescendants(child))
            {
                yield return descendant;
            }
        }
    }

    private static bool IsEffectivelyVisible(DependencyObject element)
    {
        for (DependencyObject? current = element; current is not null; current = VisualTreeHelper.GetParent(current))
        {
            if (current is UIElement { Visibility: not Visibility.Visible })
            {
                return false;
            }
        }

        return true;
    }

    private static void RenderPng(
        FrameworkElement element,
        int pixelWidth,
        int pixelHeight,
        string outputPath)
    {
        Layout(element, pixelWidth, pixelHeight);
        var bitmap = new RenderTargetBitmap(
            pixelWidth,
            pixelHeight,
            96,
            96,
            PixelFormats.Pbgra32);
        bitmap.Render(element);
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using var output = File.Create(outputPath);
        encoder.Save(output);
        Assert.IsGreaterThan(4_000L, output.Length, $"Evidence image was unexpectedly small: {outputPath}");
    }

    private static void Layout(FrameworkElement element, double width, double height)
    {
        var size = new Size(width, height);
        element.Measure(size);
        element.Arrange(new Rect(size));
        element.UpdateLayout();
    }

    private static string FindRepositoryRoot()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null)
        {
            if (File.Exists(Path.Combine(directory.FullName, "HerdrOps.sln")))
            {
                return directory.FullName;
            }

            directory = directory.Parent;
        }

        Assert.Fail("Could not locate HerdrOps.sln from the runtime test output directory.");
        return string.Empty;
    }

    private sealed class RecordingRouter : IWidgetActionRouter
    {
        public List<WidgetNotificationRoute> Notifications { get; } = [];

        public List<string> Agents { get; } = [];

        public List<string> TaskAlignments { get; } = [];

        public int NotificationHistoryOpenCount { get; private set; }

        public bool OpenNotification(WidgetNotificationRoute route)
        {
            Notifications.Add(route);
            return true;
        }

        public bool OpenAgent(string terminalId)
        {
            Agents.Add(terminalId);
            return true;
        }

        public bool OpenTaskAlignment(string taskId)
        {
            TaskAlignments.Add(taskId);
            return true;
        }

        public bool OpenNotificationHistory()
        {
            NotificationHistoryOpenCount++;
            return true;
        }
    }
}
