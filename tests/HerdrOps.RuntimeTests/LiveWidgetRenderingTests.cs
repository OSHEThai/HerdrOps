using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using HerdrOps.App.Alignment;
using HerdrOps.App.Localization;
using HerdrOps.App.Live;
using HerdrOps.App.StateIpc;
using HerdrOps.App.Widgets;
using HerdrOps.Contracts.StateIpc;
using HerdrOps.Domain.Assignments;

namespace HerdrOps.RuntimeTests;

[TestClass]
[DoNotParallelize]
public sealed class LiveWidgetRenderingTests
{
    private static readonly DateTimeOffset EvidenceUtc = new(
        2026,
        8,
        14,
        14,
        32,
        0,
        TimeSpan.Zero);

    [TestInitialize]
    public void UseThaiDefault() => UiLanguageService.Shared.SetLanguage(UiLanguage.Thai);

    [TestCleanup]
    public void RestoreThaiDefault() => UiLanguageService.Shared.SetLanguage(UiLanguage.Thai);

    [TestMethod]
    public void LiveCompactNormalAndFloatingVerticalRenderFromSharedCoreState()
    {
        WpfTestHost.Run(() =>
        {
            var dashboard = CreateDashboard(sequence: 20);
            var sharedState = dashboard.Widgets;
            var outputDirectory = Path.Combine(
                FindRepositoryRoot(),
                "artifacts",
                "design-evidence",
                "v0.2.0",
                "issue-10",
                "contract-backed-wpf");
            Directory.CreateDirectory(outputDirectory);
            var variants = new[]
            {
                (Variant: WidgetVariant.Compact, FileName: "compact.png", RequiresThaiCheck: true),
                (Variant: WidgetVariant.Normal, FileName: "normal.png", RequiresThaiCheck: true),
                (Variant: WidgetVariant.FloatingVertical, FileName: "floating-vertical.png", RequiresThaiCheck: false),
            };

            foreach (var item in variants)
            {
                var descriptor = WidgetCatalog.Get(item.Variant);
                var surface = new WidgetSurface(sharedState)
                {
                    Width = descriptor.WindowWidth,
                    Height = descriptor.WindowHeight,
                    Variant = item.Variant,
                    IsInteractive = true,
                };
                var size = new Size(descriptor.WindowWidth, descriptor.WindowHeight);
                Layout(surface, size);

                Assert.AreSame(sharedState, surface.State);
                var surfaceRoot = Assert.IsInstanceOfType<FrameworkElement>(surface.FindName("SurfaceRoot"));
                Assert.AreSame(sharedState, surfaceRoot.DataContext);
                Assert.AreEqual(12, sharedState.TotalAgents);
                AssertHeaderSource(
                    surface,
                    item.Variant == WidgetVariant.FloatingVertical
                        ? UiLanguageService.Shared["CoreCompact"]
                        : UiLanguageService.Shared["CoreStateSource"]);
                AssertInteractiveActionsAreAccessible(surface);
                if (item.RequiresThaiCheck)
                {
                    AssertThaiTextFits(surface);
                }

                if (item.Variant is WidgetVariant.Normal or WidgetVariant.FloatingVertical)
                {
                    AssertAllAgentsAreReachable(surface, sharedState.Agents.Count, item.Variant);
                }

                SavePng(surface, size, Path.Combine(outputDirectory, item.FileName));
            }
        });
    }

    [TestMethod]
    public void ExpandedWidgetRendersExactSharedAgentTaskStateAndDeepLinkActions()
    {
        WpfTestHost.Run(() =>
        {
            var outputDirectory = Path.Combine(
                FindRepositoryRoot(),
                "artifacts",
                "design-evidence",
                "v0.4.0",
                "issue-22",
                "contract-backed-wpf");
            Directory.CreateDirectory(outputDirectory);

            foreach (var language in new[] { UiLanguage.Thai, UiLanguage.English })
            {
                UiLanguageService.Shared.SetLanguage(language);
                var request = TaskAlignmentState.CreateSyntheticPreviewRequest();
                var currentTask = request.LifecycleReplay.CurrentTasks.Single().State;
                var session = CreateAssignmentState(
                    currentTask.CurrentAssigneeId,
                    currentTask.CurrentAssigneeRole!);
                var update = CreateAssignmentUpdate(session);
                var dashboard = new LiveDashboardState();
                dashboard.ApplyUpdate(update, update.Envelope.SentUtc.AddMilliseconds(12));
                dashboard.ApplyAssignmentWorkspace(
                    request.LifecycleReplay,
                    request,
                    "HerdrOps",
                    UiLanguageService.Shared["AlignmentSyntheticSource"],
                    UiLanguageService.Shared["AlignmentSyntheticBoundary"]);

                var agent = dashboard.Widgets.Agents.Single();
                Assert.AreEqual(currentTask.CurrentAssigneeId, agent.TerminalId);
                Assert.AreEqual(
                    UiLanguageService.Shared["WidgetAgentBackendWorkerRole"],
                    agent.Role);
                Assert.AreEqual(currentTask.TaskId, agent.TaskId);
                Assert.AreEqual("68", agent.ScoreLabel);
                Assert.AreEqual(currentTask.TaskId, dashboard.TaskAlignment.Header.TaskId);
                Assert.IsTrue(dashboard.TaskAlignment.HasExactTask(agent.TaskId!));
                Assert.IsTrue(agent.CanOpenTaskAlignment);
                Assert.AreEqual(
                    request.LifecycleReplay.CurrentTasks.Single().State.Contract.ProvenanceEventSha256,
                    agent.LifecycleProvenance);

                var descriptor = WidgetCatalog.Get(WidgetVariant.Expanded);
                var surface = new WidgetSurface(dashboard.Widgets)
                {
                    Width = descriptor.WindowWidth,
                    Height = descriptor.WindowHeight,
                    Variant = WidgetVariant.Expanded,
                    IsInteractive = true,
                };
                var size = new Size(descriptor.WindowWidth, descriptor.WindowHeight);
                Layout(surface, size);
                var visibleText = VisibleText(surface);
                if (language == UiLanguage.Thai)
                {
                    Assert.IsTrue(visibleText.Any(ContainsThai));
                    Assert.IsFalse(visibleText.Any(text =>
                        text.Contains("CORE", StringComparison.Ordinal) ||
                        text.Contains("Backend Worker", StringComparison.Ordinal) ||
                        text.Contains("Submitted", StringComparison.Ordinal)));
                }
                else
                {
                    Assert.IsTrue(visibleText.All(text => !ContainsThai(text)),
                        $"English Expanded widget retained Thai copy: {string.Join(" | ", visibleText.Where(ContainsThai))}");
                }

                var rowActions = EnumerateDescendants(surface)
                    .OfType<Button>()
                    .Where(button => ReferenceEquals(button.CommandParameter, agent))
                    .ToArray();
                Assert.HasCount(2, rowActions);
                Assert.IsTrue(rowActions.All(button => button.IsEnabled));
                Assert.IsTrue(rowActions.All(button =>
                    !string.IsNullOrWhiteSpace(AutomationProperties.GetName(button))));
                WidgetAgentEventArgs? agentNavigation = null;
                WidgetTaskEventArgs? taskNavigation = null;
                surface.AgentDetailsRequested += (_, eventArgs) => agentNavigation = eventArgs;
                surface.TaskAlignmentRequested += (_, eventArgs) => taskNavigation = eventArgs;
                rowActions.Single(button => string.Equals(
                        AutomationProperties.GetName(button),
                        agent.AgentDetailsAutomationName,
                        StringComparison.Ordinal))
                    .RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                rowActions.Single(button => string.Equals(
                        AutomationProperties.GetName(button),
                        agent.TaskAlignmentAutomationName,
                        StringComparison.Ordinal))
                    .RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                Assert.AreSame(agent, agentNavigation?.Agent);
                Assert.AreEqual(agent.TaskId, taskNavigation?.TaskId);
                AssertThaiTextFits(surface);

                var languageName = language == UiLanguage.Thai ? "thai" : "english";
                SavePng(
                    surface,
                    size,
                    Path.Combine(outputDirectory, $"expanded-{languageName}.png"));
            }
        });
    }

    [TestMethod]
    public void LiveWidgetBindingsRefreshWhenSameStateReceivesLaterSnapshot()
    {
        WpfTestHost.Run(() =>
        {
            var dashboard = CreateDashboard(sequence: 20);
            var sharedState = dashboard.Widgets;
            var compact = CreateSurface(sharedState, WidgetVariant.Compact);
            var normal = CreateSurface(sharedState, WidgetVariant.Normal);
            var normalItems = FindVisibleAgentItems(normal);

            Assert.AreEqual(20L, sharedState.Sequence);
            Assert.AreEqual(2, sharedState.BlockedCount);
            Assert.AreEqual("Worker 12", Assert.IsInstanceOfType<WidgetAgent>(normalItems.Items[11]).Name);

            var laterState = CreateState(sequence: 21, allDone: true);
            var laterUpdate = CreateUpdate(laterState);
            dashboard.ApplyUpdate(laterUpdate, laterUpdate.Envelope.SentUtc.AddMilliseconds(24));
            compact.UpdateLayout();
            normal.UpdateLayout();

            Assert.AreSame(sharedState, dashboard.Widgets);
            Assert.AreSame(sharedState, compact.State);
            Assert.AreSame(sharedState, normal.State);
            Assert.AreEqual(21L, sharedState.Sequence);
            Assert.AreEqual("0", sharedState.WorkingCountLabel);
            Assert.AreEqual("0", sharedState.BlockedCountLabel);
            Assert.AreEqual("12", sharedState.DoneCountLabel);
            Assert.AreEqual(2, sharedState.UpdateSampleCount);
            Assert.AreEqual(12, normalItems.Items.Count);
            Assert.IsTrue(normalItems.Items.OfType<WidgetAgent>().All(
                agent => agent.Status == UiLanguageService.Shared["StatusDone"]));
            Assert.IsTrue(VisibleText(compact).Contains("12", StringComparer.Ordinal));
        });
    }

    [TestMethod]
    public void AllLiveWidgetVariantsRenderThaiAndEnglishAsSeparateModes()
    {
        WpfTestHost.Run(() =>
        {
            var dashboard = CreateDashboard(sequence: 20);
            var outputDirectory = Path.Combine(
                FindRepositoryRoot(),
                "artifacts",
                "design-evidence",
                "v0.2.0",
                "issue-63",
                "contract-backed-wpf");
            Directory.CreateDirectory(outputDirectory);

            foreach (var language in new[] { UiLanguage.Thai, UiLanguage.English })
            {
                UiLanguageService.Shared.SetLanguage(language);
                dashboard.RefreshLanguage();
                foreach (var descriptor in WidgetCatalog.All)
                {
                    var surface = new WidgetSurface(dashboard.Widgets)
                    {
                        Width = descriptor.WindowWidth,
                        Height = descriptor.WindowHeight,
                        Variant = descriptor.Variant,
                        IsInteractive = true,
                    };
                    var size = new Size(descriptor.WindowWidth, descriptor.WindowHeight);
                    Layout(surface, size);
                    var visibleText = VisibleText(surface)
                        .Where(text => !string.IsNullOrWhiteSpace(text))
                        .ToArray();
                    if (language == UiLanguage.English)
                    {
                        Assert.IsTrue(
                            visibleText.All(text => !ContainsThai(text)),
                            $"English {descriptor.Variant} retained Thai copy: {string.Join(" | ", visibleText.Where(ContainsThai))}");
                    }
                    else
                    {
                        Assert.IsTrue(
                            visibleText.Any(ContainsThai),
                            $"Thai {descriptor.Variant} did not render Thai UI copy.");
                    }

                    var languageName = language == UiLanguage.Thai ? "thai" : "english";
                    var variantName = descriptor.Variant.ToString().ToLowerInvariant();
                    SavePng(surface, size, Path.Combine(outputDirectory, $"{languageName}-widget-{variantName}.png"));
                }
            }
        });
    }

    [TestMethod]
    public void ContractBackedWidgetAdapterP95StaysWithinReleaseTarget()
    {
        const int sampleCount = 200;
        const double targetMilliseconds = 250;
        var dashboard = CreateDashboard(sequence: 20);
        var updates = Enumerable.Range(21, sampleCount)
            .Select(sequence => CreateUpdate(CreateState(sequence, allDone: sequence % 2 == 0)))
            .ToArray();
        var samples = new double[sampleCount];
        var stopwatch = new Stopwatch();

        for (var index = 0; index < updates.Length; index++)
        {
            var update = updates[index];
            stopwatch.Restart();
            dashboard.ApplyUpdate(update, update.Envelope.SentUtc.AddMilliseconds(10));
            stopwatch.Stop();
            samples[index] = stopwatch.Elapsed.TotalMilliseconds;
        }

        var ordered = samples.Order().ToArray();
        var percentileIndex = Math.Max(0, (int)Math.Ceiling(ordered.Length * 0.95) - 1);
        var p95 = ordered[percentileIndex];
        var reportDirectory = Path.Combine(
            FindRepositoryRoot(),
            "artifacts",
            "performance-evidence",
            "v0.2.0",
            "issue-10");
        Directory.CreateDirectory(reportDirectory);
        var reportPath = Path.Combine(reportDirectory, "contract-backed-widget-measurement.txt");
        var report = new[]
        {
            "HerdrOps v0.2 Issue #10 Contract-backed Widget Adapter Measurement",
            $"GeneratedUtc: {DateTimeOffset.UtcNow:O}",
            "EvidenceClass: Synthetic",
            "MeasurementScope: synchronous in-process Core-contract-to-widget adapter application",
            $"Samples: {sampleCount.ToString(CultureInfo.InvariantCulture)}",
            $"MinimumMs: {ordered[0].ToString("0.000", CultureInfo.InvariantCulture)}",
            $"MedianMs: {ordered[ordered.Length / 2].ToString("0.000", CultureInfo.InvariantCulture)}",
            $"P95Ms: {p95.ToString("0.000", CultureInfo.InvariantCulture)}",
            $"MaximumMs: {ordered[^1].ToString("0.000", CultureInfo.InvariantCulture)}",
            $"SyntheticTargetMs: {targetMilliseconds.ToString("0", CultureInfo.InvariantCulture)}",
            $"SyntheticTargetResult: {(p95 <= targetMilliseconds ? "PASS" : "FAIL")}",
            "ActualHerdrRuntime: NOT OBSERVED / NOT CLAIMED",
            "ReferenceHostLatency: PENDING",
            "CorePlusAppResourceBudget: PENDING",
            "ActualRuntimeGate: PENDING",
        };
        File.WriteAllLines(reportPath, report);

        Assert.IsLessThanOrEqualTo(
            targetMilliseconds,
            p95,
            $"Contract-backed widget adapter p95 exceeded {targetMilliseconds:0} ms.");
        Assert.AreEqual(220L, dashboard.Widgets.Sequence);
        Assert.AreEqual(sampleCount + 1, dashboard.Widgets.UpdateSampleCount);
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
        Layout(surface, new Size(descriptor.WindowWidth, descriptor.WindowHeight));
        return surface;
    }

    private static LiveDashboardState CreateDashboard(long sequence)
    {
        var dashboard = new LiveDashboardState();
        var update = CreateUpdate(CreateState(sequence));
        dashboard.ApplyUpdate(update, update.Envelope.SentUtc.AddMilliseconds(18));
        return dashboard;
    }

    private static HerdrSessionStateContract CreateState(long sequence, bool allDone = false)
    {
        var statuses = allDone
            ? Enumerable.Repeat("Done", 12).ToArray()
            : new[]
            {
                "Working",
                "Working",
                "Idle",
                "Blocked",
                "Idle",
                "Done",
                "Working",
                "Idle",
                "Done",
                "Working",
                "Blocked",
                "Done",
            };
        var panes = statuses.Select((status, index) =>
        {
            var number = index + 1;
            var revision = checked((ulong)(sequence + number));
            return new HerdrPaneStateContract(
                $"pane-{number}",
                $"terminal-{number}",
                "workspace-1",
                "tab-1",
                number == 1,
                status,
                revision,
                number % 2 == 0 ? "claude" : "codex",
                number % 2 == 0 ? "Claude" : "Codex",
                number % 3 == 0 ? "Reviewer" : "Worker",
                "Z:\\HerdrOps",
                "Z:\\HerdrOps",
                number % 2 == 0 ? "Claude" : "Codex");
        }).ToArray();
        var agents = statuses.Select((status, index) =>
        {
            var number = index + 1;
            var revision = checked((ulong)(sequence + number));
            return new HerdrAgentStateContract(
                $"terminal-{number}",
                "workspace-1",
                "tab-1",
                $"pane-{number}",
                number == 1,
                status,
                revision,
                revision,
                number % 2 == 0 ? "claude" : "codex",
                number % 2 == 0 ? "Claude" : "Codex",
                $"Worker {number:00}",
                number % 3 == 0 ? "Reviewer" : "Worker",
                "Z:\\HerdrOps",
                "Z:\\HerdrOps",
                number % 2 == 0 ? "Claude" : "Codex",
                true,
                false,
                false);
        }).ToArray();
        var aggregateStatus = statuses.Contains("Blocked", StringComparer.Ordinal)
            ? "Blocked"
            : statuses.All(status => status == "Done")
                ? "Done"
                : "Working";
        return HerdrSessionStateContractReducer.NormalizeAndValidate(new HerdrSessionStateContract(
            "0.8.0-preview",
            19,
            2,
            sequence,
            [new("workspace-1", 1, "HerdrOps", true, panes.Length, 1, "tab-1", aggregateStatus)],
            [new("tab-1", "workspace-1", 1, "Implementation", true, panes.Length, aggregateStatus)],
            panes,
            agents,
            "workspace-1",
            "tab-1",
            "pane-1"));
    }

    private static HerdrSessionStateContract CreateAssignmentState(
        string terminalId,
        string role)
    {
        const long sequence = 30;
        const string workspaceId = "workspace-assignment";
        const string tabId = "tab-assignment";
        const string paneId = "pane-assignment";
        return HerdrSessionStateContractReducer.NormalizeAndValidate(new HerdrSessionStateContract(
            "0.8.0-preview",
            19,
            2,
            sequence,
            [new(workspaceId, 1, "HerdrOps", true, 1, 1, tabId, "Working")],
            [new(tabId, workspaceId, 1, "Implementation", true, 1, "Working")],
            [new(paneId, terminalId, workspaceId, tabId, true, "Working", 30, "codex", "Codex", role, "Z:\\HerdrOps", "Z:\\HerdrOps", "Codex")],
            [new(terminalId, workspaceId, tabId, paneId, true, "Working", 30, 30, "codex", "Codex", "Backend Worker 01", role, "Z:\\HerdrOps", "Z:\\HerdrOps", "Codex", true, false, false)],
            workspaceId,
            tabId,
            paneId));
    }

    private static HerdrOpsStateUpdate CreateAssignmentUpdate(HerdrSessionStateContract state)
    {
        var acceptedUtc = new DateTimeOffset(2026, 8, 15, 3, 15, 0, TimeSpan.Zero);
        var runtimeHealth = new HerdrRuntimeHealthContract(
            "Connected",
            acceptedUtc,
            acceptedUtc,
            1,
            1,
            0,
            0);
        var payload = new HerdrOpsStateSnapshotPayload(
            state,
            HerdrOpsStateIpcJson.ComputeSha256(state),
            runtimeHealth);
        var envelope = HerdrOpsStateIpcJson.CreateEnvelope(
            HerdrOpsStateIpcProtocol.MessageTypes.Snapshot,
            state.LastIngestSequence,
            acceptedUtc,
            HerdrOpsStateIpcProtocol.CoreSource,
            Guid.NewGuid(),
            payload);
        return new HerdrOpsStateUpdate(
            HerdrOpsStateUpdateKind.Snapshot,
            state,
            envelope,
            payload,
            null,
            runtimeHealth);
    }

    private static HerdrOpsStateUpdate CreateUpdate(HerdrSessionStateContract state)
    {
        var acceptedUtc = EvidenceUtc.AddSeconds(state.LastIngestSequence);
        var runtimeHealth = new HerdrRuntimeHealthContract(
            "Connected",
            acceptedUtc,
            acceptedUtc,
            2,
            Math.Max(1, state.LastIngestSequence - 1),
            0,
            0);
        var payload = new HerdrOpsStateSnapshotPayload(
            state,
            HerdrOpsStateIpcJson.ComputeSha256(state),
            runtimeHealth);
        var envelope = HerdrOpsStateIpcJson.CreateEnvelope(
            HerdrOpsStateIpcProtocol.MessageTypes.Snapshot,
            state.LastIngestSequence,
            acceptedUtc,
            HerdrOpsStateIpcProtocol.CoreSource,
            Guid.NewGuid(),
            payload);
        return new HerdrOpsStateUpdate(
            HerdrOpsStateUpdateKind.Snapshot,
            state,
            envelope,
            payload,
            null,
            runtimeHealth);
    }

    private static void AssertHeaderSource(DependencyObject root, string expected)
    {
        var source = EnumerateDescendants(root)
            .OfType<TextBlock>()
            .Single(text => IsEffectivelyVisible(text) && string.Equals(text.Text, expected, StringComparison.Ordinal));
        Assert.IsGreaterThan(0d, source.ActualWidth);
    }

    private static void AssertInteractiveActionsAreAccessible(DependencyObject root)
    {
        var actions = EnumerateDescendants(root)
            .OfType<Button>()
            .Where(IsEffectivelyVisible)
            .ToArray();
        Assert.IsGreaterThanOrEqualTo(2, actions.Length);
        foreach (var action in actions)
        {
            Assert.IsTrue(action.Focusable);
            Assert.IsTrue(action.IsTabStop);
            Assert.IsFalse(string.IsNullOrWhiteSpace(AutomationProperties.GetName(action)));
        }
    }

    private static void AssertAllAgentsAreReachable(
        DependencyObject root,
        int expectedCount,
        WidgetVariant variant)
    {
        var items = FindVisibleAgentItems(root);
        Assert.AreEqual(expectedCount, items.Items.Count);
        if (variant != WidgetVariant.FloatingVertical)
        {
            return;
        }

        var scrollViewer = EnumerateDescendants(root)
            .OfType<ScrollViewer>()
            .Single(viewer =>
                IsEffectivelyVisible(viewer) &&
                string.Equals(
                    AutomationProperties.GetName(viewer),
                    UiLanguageService.Shared["WidgetAllAgentsList"],
                    StringComparison.Ordinal));
        Assert.IsGreaterThan(0d, scrollViewer.ScrollableHeight);
        scrollViewer.ScrollToEnd();
        scrollViewer.UpdateLayout();
        Assert.AreEqual(scrollViewer.ScrollableHeight, scrollViewer.VerticalOffset, 0.5);
    }

    private static ItemsControl FindVisibleAgentItems(DependencyObject root) =>
        EnumerateDescendants(root)
            .OfType<ItemsControl>()
            .Where(IsEffectivelyVisible)
            .Single(items => items.Items.Count > 0 && items.Items.OfType<WidgetAgent>().Any());

    private static IReadOnlyList<string> VisibleText(DependencyObject root) =>
        EnumerateDescendants(root)
            .OfType<TextBlock>()
            .Where(IsEffectivelyVisible)
            .Select(text => text.Text)
            .ToArray();

    private static bool ContainsThai(string value) =>
        value.Any(character => character is >= '\u0E00' and <= '\u0E7F');

    private static void AssertThaiTextFits(DependencyObject root)
    {
        var checkpoints = EnumerateDescendants(root)
            .OfType<TextBlock>()
            .Where(text => string.Equals(text.Tag as string, "ThaiWidgetCheck", StringComparison.Ordinal))
            .Where(IsEffectivelyVisible)
            .ToArray();
        Assert.IsNotEmpty(checkpoints);
        foreach (var textBlock in checkpoints)
        {
            var formatted = new FormattedText(
                textBlock.Text,
                CultureInfo.GetCultureInfo("th-TH"),
                textBlock.FlowDirection,
                new Typeface(
                    textBlock.FontFamily,
                    textBlock.FontStyle,
                    textBlock.FontWeight,
                    textBlock.FontStretch),
                textBlock.FontSize,
                textBlock.Foreground,
                1);
            if (textBlock.TextWrapping == TextWrapping.NoWrap)
            {
                Assert.IsLessThanOrEqualTo(
                    textBlock.ActualWidth + 3,
                    formatted.WidthIncludingTrailingWhitespace,
                    $"Thai widget text clipped: {textBlock.Text}");
            }
        }
    }

    private static void Layout(FrameworkElement view, Size size)
    {
        view.Measure(size);
        view.Arrange(new Rect(size));
        view.UpdateLayout();
    }

    private static bool IsEffectivelyVisible(DependencyObject element)
    {
        for (DependencyObject? current = element; current is not null; current = VisualTreeHelper.GetParent(current))
        {
            if (current is FrameworkElement frameworkElement &&
                (frameworkElement.Visibility != Visibility.Visible ||
                 frameworkElement.ActualWidth <= 0 ||
                 frameworkElement.ActualHeight <= 0))
            {
                return false;
            }
        }

        return true;
    }

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

    private static void SavePng(FrameworkElement view, Size size, string path)
    {
        var bitmap = new RenderTargetBitmap(
            checked((int)size.Width),
            checked((int)size.Height),
            96,
            96,
            PixelFormats.Pbgra32);
        bitmap.Render(view);
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using var output = File.Create(path);
        encoder.Save(output);
        Assert.IsGreaterThan(4_000L, output.Length, $"Rendered evidence was unexpectedly small: {path}");
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
}
