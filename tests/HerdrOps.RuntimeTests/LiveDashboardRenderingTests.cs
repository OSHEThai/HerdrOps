using System.Globalization;
using System.IO;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using HerdrOps.App.Live;
using HerdrOps.App.Localization;
using HerdrOps.App.Organization;
using HerdrOps.App.StateIpc;
using HerdrOps.App.Views;
using HerdrOps.Contracts.StateIpc;

namespace HerdrOps.RuntimeTests;

[TestClass]
[DoNotParallelize]
public sealed class LiveDashboardRenderingTests
{
    [TestMethod]
    public void LiveOverviewOrganizationAndAgentDetailRenderFromOneCoreSnapshot()
    {
        WpfTestHost.Run(() =>
        {
            RunWithLanguage(UiLanguage.Thai, () =>
            {
                var dashboard = CreateDashboard();
                var outputDirectory = Path.Combine(
                    FindRepositoryRoot(),
                    "artifacts",
                    "design-evidence",
                    "v0.2.0",
                    "issue-9",
                    "contract-backed-wpf");
                Directory.CreateDirectory(outputDirectory);
                var pages = new[]
                {
                    (Index: 0, Name: "overview", Type: typeof(OverviewView), Tag: "ThaiOverviewCheck"),
                    (Index: 1, Name: "live-organization", Type: typeof(LiveOrganizationView), Tag: "ThaiLiveOrganizationCheck"),
                    (Index: 4, Name: "agent-detail", Type: typeof(AgentDetailView), Tag: "ThaiAgentDetailCheck"),
                };

                foreach (var page in pages)
                {
                    foreach (var size in new[] { new Size(1672, 941), new Size(1366, 768) })
                    {
                        var shell = new ShellView(dashboard);
                        shell.Navigation.SelectedIndex = page.Index;
                        Layout(shell, size);
                        var visiblePage = EnumerateDescendants(shell)
                            .OfType<FrameworkElement>()
                            .Single(element => element.GetType() == page.Type);
                        Assert.AreEqual(Visibility.Visible, visiblePage.Visibility);
                        Assert.IsGreaterThan(0d, visiblePage.ActualWidth);
                        Assert.IsGreaterThan(0d, visiblePage.ActualHeight);
                        AssertThaiTextFits(shell, page.Tag);
                        var suffix = size.Width < 1500 ? "1366x768" : "1672x941";
                        SavePng(shell, size, Path.Combine(outputDirectory, $"{page.Name}-{suffix}.png"));
                    }
                }
            });
        });
    }

    [TestMethod]
    public void UnsupportedHerdrFieldsRenderAsUnknownAndAgentTopologyIsKeyboardSelectable()
    {
        WpfTestHost.Run(() =>
        {
            RunWithLanguage(UiLanguage.Thai, () =>
            {
                var text = UiLanguageService.Shared;
                var dashboard = CreateDashboard();
                var shell = new ShellView(dashboard);
                shell.Navigation.SelectedIndex = 1;
                Layout(shell, new Size(1672, 941));
                var topology = EnumerateDescendants(shell)
                    .OfType<ListBox>()
                    .Single(list => string.Equals(
                        AutomationProperties.GetName(list),
                        text["OrganizationHierarchyAutomation"],
                        StringComparison.Ordinal));
                var agentItems = topology.Items
                    .OfType<HerdrOps.App.Organization.OrganizationNode>()
                    .Where(node => node.IsAgent)
                    .ToArray();
                Assert.HasCount(2, agentItems);
                Assert.IsTrue(topology.Focusable);
                topology.SelectedItem = agentItems.Single(node => node.AgentTerminalId == "terminal-2");
                topology.GetBindingExpression(ListBox.SelectedItemProperty)?.UpdateSource();
                Assert.AreEqual("terminal-2", dashboard.AgentDetail.Terminal);

                shell.Navigation.SelectedIndex = 4;
                Layout(shell, new Size(1672, 941));
                var visibleText = EnumerateDescendants(shell)
                    .OfType<TextBlock>()
                    .Where(IsEffectivelyVisible)
                    .Select(textBlock => textBlock.Text)
                    .ToArray();
                Assert.IsTrue(visibleText.Contains(text["ValueUnknown"], StringComparer.Ordinal));
                Assert.IsFalse(visibleText.Contains("100", StringComparer.Ordinal));
            });
        });
    }

    [TestMethod]
    public void SyntheticOrganizationUsesCardTreeLayoutAndKeepsNodesKeyboardAccessible()
    {
        WpfTestHost.Run(() =>
        {
            RunWithLanguage(UiLanguage.Thai, () =>
            {
                using var dashboard = LiveDashboardState.CreateSyntheticPreview();
                var shell = new ShellView(dashboard);
                shell.Navigation.SelectedIndex = 1;
                Layout(shell, new Size(1680, 941));

                var panel = EnumerateDescendants(shell)
                    .OfType<OrganizationHierarchyPanel>()
                    .Single();
                Assert.IsGreaterThan(0d, panel.ActualWidth);
                Assert.IsGreaterThan(0d, panel.ActualHeight);

                var positionedNodes = panel.Children
                    .OfType<FrameworkElement>()
                    .Where(child => child.DataContext is OrganizationNode)
                    .Select(child =>
                    {
                        var node = (OrganizationNode)child.DataContext!;
                        var origin = child.TranslatePoint(new Point(0, 0), panel);
                        return (node, origin.X, origin.Y, child);
                    })
                    .ToArray();
                Assert.HasCount(dashboard.Organization.Nodes.Count, positionedNodes);
                Assert.IsGreaterThanOrEqualTo(
                    4,
                    positionedNodes.Select(item => Math.Round(item.X)).Distinct().Count(),
                    "The organization hierarchy is still arranged as one flat x-coordinate.");

                var projectManager = positionedNodes.Single(item => item.node.Name == "Project Manager");
                var backendLeader = positionedNodes.Single(item => item.node.Name == "Backend Leader");
                var backendWorker = positionedNodes.Single(item => item.node.Name == "Backend Worker 01");
                Assert.IsLessThan(
                    backendLeader.Y,
                    projectManager.Y,
                    $"Unexpected tree order: PM={projectManager.X},{projectManager.Y}; BL={backendLeader.X},{backendLeader.Y}; BW={backendWorker.X},{backendWorker.Y}");
                Assert.IsLessThan(
                    backendWorker.Y,
                    backendLeader.Y,
                    $"Unexpected worker order: BL={backendLeader.X},{backendLeader.Y}; BW={backendWorker.X},{backendWorker.Y}");
                Assert.AreNotEqual(projectManager.X, backendLeader.X);
                Assert.IsTrue(positionedNodes.All(item => item.child is Control { Focusable: true, IsTabStop: true }));
                Assert.IsTrue(positionedNodes.All(item =>
                    !string.IsNullOrWhiteSpace(AutomationProperties.GetName(item.child))));
            });
        });
    }

    [TestMethod]
    public void LiveOrganizationCardsAndStatusesFitInThaiAndEnglishAtReferenceSizes()
    {
        WpfTestHost.Run(() =>
        {
            var languageService = UiLanguageService.Shared;
            var previousLanguage = languageService.CurrentLanguage;
            try
            {
                foreach (var language in new[] { UiLanguage.Thai, UiLanguage.English })
                {
                    languageService.SetLanguage(language);
                    using var dashboard = LiveDashboardState.CreateSyntheticPreview();
                    foreach (var size in new[] { new Size(1672, 941), new Size(1366, 768) })
                    {
                        var shell = new ShellView(dashboard);
                        shell.Navigation.SelectedIndex = 1;
                        Layout(shell, size);
                        AssertOrganizationCardsFit(shell, size, language);
                    }
                }
            }
            finally
            {
                languageService.SetLanguage(previousLanguage);
            }
        });
    }

    [TestMethod]
    public void LivePagesRenderThaiAndEnglishAsSeparateModes()
    {
        WpfTestHost.Run(() =>
        {
            RunWithLanguage(UiLanguage.Thai, () =>
            {
                var dashboard = CreateDashboard();
                var outputDirectory = Path.Combine(
                    FindRepositoryRoot(),
                    "artifacts",
                    "design-evidence",
                    "v0.2.0",
                    "issue-63",
                    "contract-backed-wpf");
                Directory.CreateDirectory(outputDirectory);
                var pages = new[]
                {
                    (Index: 0, Name: "overview", Type: typeof(OverviewView)),
                    (Index: 1, Name: "live-organization", Type: typeof(LiveOrganizationView)),
                    (Index: 4, Name: "agent-detail", Type: typeof(AgentDetailView)),
                };

                foreach (var language in new[] { UiLanguage.Thai, UiLanguage.English })
                {
                    RunWithLanguage(language, () =>
                    {
                        dashboard.RefreshLanguage();
                        foreach (var page in pages)
                        {
                            var shell = new ShellView(dashboard);
                            shell.Navigation.SelectedIndex = page.Index;
                            var size = new Size(1672, 941);
                            Layout(shell, size);
                            var visiblePage = EnumerateDescendants(shell)
                                .OfType<FrameworkElement>()
                                .Single(element => element.GetType() == page.Type);
                            Assert.AreEqual(Visibility.Visible, visiblePage.Visibility);
                            var visibleText = EnumerateDescendants(shell)
                                .OfType<TextBlock>()
                                .Where(IsEffectivelyVisible)
                                .Select(textBlock => textBlock.Text)
                                .Where(text => !string.IsNullOrWhiteSpace(text))
                                .ToArray();
                            if (language == UiLanguage.English)
                            {
                                Assert.IsTrue(
                                    visibleText.All(text => !ContainsThai(text)),
                                    $"English {page.Name} retained Thai copy: {string.Join(" | ", visibleText.Where(ContainsThai))}");
                            }
                            else
                            {
                                Assert.IsTrue(visibleText.Any(ContainsThai), $"Thai {page.Name} did not render Thai UI copy.");
                            }

                            var languageName = language == UiLanguage.Thai ? "thai" : "english";
                            SavePng(shell, size, Path.Combine(outputDirectory, $"{languageName}-{page.Name}.png"));
                        }
                    });
                }
            });
        });
    }

    [TestMethod]
    public void HerdrReconnectRendersLastKnownStateAsOfflineInBothLanguages()
    {
        WpfTestHost.Run(() =>
        {
            RunWithLanguage(UiLanguage.Thai, () =>
            {
                var dashboard = CreateDashboard();
                var reconnecting = dashboard.CurrentRuntimeHealth with
                {
                    Status = "Reconnecting",
                    LastTransitionUtc = dashboard.CurrentRuntimeHealth.LastTransitionUtc.AddSeconds(1),
                    DisconnectCount = 1,
                    ReconciliationCount = 1,
                };
                var update = CreateRuntimeHealthUpdate(dashboard.CurrentState, reconnecting);
                dashboard.ApplyUpdate(update, update.Envelope.SentUtc.AddMilliseconds(5));
                var outputDirectory = Path.Combine(
                    FindRepositoryRoot(),
                    "artifacts",
                    "design-evidence",
                    "v0.2.0",
                    "issue-9",
                    "contract-backed-wpf");
                Directory.CreateDirectory(outputDirectory);

                Assert.IsTrue(dashboard.IsCoreConnected);
                Assert.IsFalse(dashboard.IsLive);
                foreach (var language in new[] { UiLanguage.Thai, UiLanguage.English })
                {
                    RunWithLanguage(language, () =>
                    {
                        var text = UiLanguageService.Shared;
                        var expectedReconnecting = text["HerdrReconnecting"];
                        var expectedOffline = text["StatusOffline"];
                        dashboard.RefreshLanguage();
                        var shell = new ShellView(dashboard);
                        shell.Navigation.SelectedIndex = 0;
                        var size = new Size(1672, 941);
                        Layout(shell, size);
                        Assert.AreEqual(expectedReconnecting, dashboard.ConnectionLabel);
                        var connectionStatusText = Assert.IsInstanceOfType<TextBlock>(
                            shell.FindName("ConnectionStatusText"));
                        Assert.AreEqual(expectedReconnecting, connectionStatusText.Text);
                        Assert.IsTrue(
                            IsEffectivelyVisible(connectionStatusText),
                            $"The connection status text was not rendered. Actual size: {connectionStatusText.ActualWidth:0.##}x{connectionStatusText.ActualHeight:0.##}.");
                        Assert.IsTrue(dashboard.Overview.TopAgents.All(
                            agent => agent.StatusLabel == expectedOffline));
                        var languageName = language == UiLanguage.Thai ? "thai" : "english";
                        SavePng(
                            shell,
                            size,
                            Path.Combine(outputDirectory, $"{languageName}-overview-herdr-reconnecting.png"));
                    });
                }
            });
        });
    }

    private static LiveDashboardState CreateDashboard()
    {
        var state = CreateState();
        var acceptedUtc = new DateTimeOffset(2026, 8, 14, 14, 32, 0, TimeSpan.Zero);
        var runtimeHealth = new HerdrRuntimeHealthContract(
            "Connected",
            acceptedUtc,
            acceptedUtc,
            2,
            12,
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
        var dashboard = new LiveDashboardState();
        dashboard.ApplyUpdate(
            new HerdrOpsStateUpdate(
                HerdrOpsStateUpdateKind.Snapshot,
                state,
                envelope,
                payload,
                null,
                runtimeHealth),
            envelope.SentUtc.AddMilliseconds(18));
        return dashboard;
    }

    private static HerdrSessionStateContract CreateState() =>
        HerdrSessionStateContractReducer.NormalizeAndValidate(new HerdrSessionStateContract(
            "0.8.0-preview",
            19,
            2,
            14,
            [new("workspace-1", 1, "HerdrOps", true, 2, 1, "tab-1", "Blocked")],
            [new("tab-1", "workspace-1", 1, "Implementation", true, 2, "Blocked")],
            [
                new("pane-1", "terminal-1", "workspace-1", "tab-1", true, "Working", 8, "codex", "Codex", "Worker", "Z:\\HerdrOps", "Z:\\HerdrOps", "Codex"),
                new("pane-2", "terminal-2", "workspace-1", "tab-1", false, "Unknown", 3, "claude", "Claude", "Reviewer", "Z:\\HerdrOps", null, "Claude"),
            ],
            [
                new("terminal-1", "workspace-1", "tab-1", "pane-1", true, "Working", 8, 8, "codex", "Codex", "Worker 01", "Worker", "Z:\\HerdrOps", "Z:\\HerdrOps", "Codex", true, false, false),
                new("terminal-2", "workspace-1", "tab-1", "pane-2", false, "Unknown", 3, 3, "claude", "Claude", "Reviewer 01", "Reviewer", "Z:\\HerdrOps", null, "Claude", null, null, null),
            ],
            "workspace-1",
            "tab-1",
            "pane-1"));

    private static HerdrOpsStateUpdate CreateRuntimeHealthUpdate(
        HerdrSessionStateContract state,
        HerdrRuntimeHealthContract health)
    {
        var payload = new HerdrOpsRuntimeHealthPayload(
            health,
            HerdrOpsStateIpcJson.ComputeSha256(state));
        var envelope = HerdrOpsStateIpcJson.CreateEnvelope(
            HerdrOpsStateIpcProtocol.MessageTypes.RuntimeHealth,
            state.LastIngestSequence,
            health.LastTransitionUtc,
            HerdrOpsStateIpcProtocol.CoreSource,
            Guid.NewGuid(),
            payload);
        return new HerdrOpsStateUpdate(
            HerdrOpsStateUpdateKind.RuntimeHealth,
            state,
            envelope,
            null,
            null,
            health);
    }

    private static void Layout(FrameworkElement view, Size size)
    {
        view.Measure(size);
        view.Arrange(new Rect(size));
        view.UpdateLayout();
    }

    private static void AssertThaiTextFits(DependencyObject root, string tag)
    {
        var checkpoints = EnumerateDescendants(root)
            .OfType<TextBlock>()
            .Where(text => string.Equals(text.Tag as string, tag, StringComparison.Ordinal))
            .Where(IsEffectivelyVisible)
            .ToArray();
        Assert.IsNotEmpty(checkpoints, $"No visible Thai clipping checkpoints were found for {tag}.");
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
                    $"Thai text clipped: {textBlock.Text}");
            }
        }
    }

    private static bool IsEffectivelyVisible(FrameworkElement element)
    {
        DependencyObject? current = element;
        while (current is FrameworkElement frameworkElement)
        {
            if (frameworkElement.Visibility != Visibility.Visible ||
                frameworkElement.ActualWidth <= 0 ||
                frameworkElement.ActualHeight <= 0)
            {
                return false;
            }

            current = VisualTreeHelper.GetParent(current);
        }

        return true;
    }

    private static bool ContainsThai(string value) =>
        value.Any(character => character is >= '\u0E00' and <= '\u0E7F');

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
        using (var output = File.Create(path))
        {
            encoder.Save(output);
        }
        PngEvidenceAssertions.AssertValid(
            path,
            checked((int)size.Width),
            checked((int)size.Height));
    }

    private static void AssertOrganizationCardsFit(
        ShellView shell,
        Size shellSize,
        UiLanguage language)
    {
        var text = UiLanguageService.Shared;
        var list = EnumerateDescendants(shell)
            .OfType<ListBox>()
            .Single(candidate => string.Equals(
                AutomationProperties.GetName(candidate),
                text["OrganizationHierarchyAutomation"],
                StringComparison.Ordinal));
        var panel = EnumerateDescendants(list)
            .OfType<OrganizationHierarchyPanel>()
            .Single();
        var cards = panel.Children
            .OfType<ListBoxItem>()
            .Where(card => card.DataContext is OrganizationNode)
            .ToArray();
        Assert.HasCount(17, cards, $"Organization card count drifted at {shellSize} in {language}.");

        var viewport = new Rect(0, 0, panel.ActualWidth, panel.ActualHeight);
        foreach (var card in cards)
        {
            var cardBounds = GetBounds(card, panel);
            Assert.IsTrue(
                viewport.Contains(cardBounds.TopLeft) && viewport.Contains(cardBounds.BottomRight),
                $"Organization card is clipped at {shellSize} in {language}: {card.DataContext} bounds={cardBounds} viewport={viewport}");

            var node = (OrganizationNode)card.DataContext!;
            var statuses = EnumerateDescendants(card)
                .OfType<TextBlock>()
                .Where(status => string.Equals(status.Text, node.Status, StringComparison.Ordinal))
                .ToArray();
            Assert.HasCount(1, statuses, $"Status text is missing or duplicated for {node.Name}.");
            var status = statuses[0];
            Assert.AreEqual(
                TextTrimming.CharacterEllipsis,
                status.TextTrimming,
                $"Status must be fully readable or deliberately ellipsized for {node.Name}.");
            Assert.IsTrue(
                !double.IsInfinity(status.Width) && status.Width > 0,
                $"Status has no bounded visual width for {node.Name}.");
            var statusBounds = GetBounds(status, card);
            var cardViewport = new Rect(0, 0, card.ActualWidth, card.ActualHeight);
            Assert.IsTrue(
                cardViewport.Contains(statusBounds.TopLeft) && cardViewport.Contains(statusBounds.BottomRight),
                $"Status is clipped inside organization card for {node.Name}: {statusBounds}");
        }

        var leaderNames = new[] { "Backend Leader", "Frontend Leader", "Test Leader", "DevOps Leader" };
        foreach (var leaderName in leaderNames)
        {
            Assert.IsTrue(
                cards.Any(card => ((OrganizationNode)card.DataContext!).Name == leaderName),
                $"Leader branch is missing at {shellSize} in {language}: {leaderName}");
        }
    }

    private static void RunWithLanguage(UiLanguage language, Action action)
    {
        ArgumentNullException.ThrowIfNull(action);
        var service = UiLanguageService.Shared;
        var previousLanguage = service.CurrentLanguage;
        try
        {
            service.SetLanguage(language);
            action();
        }
        finally
        {
            service.SetLanguage(previousLanguage);
        }
    }

    private static Rect GetBounds(FrameworkElement child, FrameworkElement parent)
    {
        var origin = child.TranslatePoint(new Point(0, 0), parent);
        return new Rect(origin, new Size(child.ActualWidth, child.ActualHeight));
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
