using System.Globalization;
using System.IO;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using HerdrOps.App.Live;
using HerdrOps.App.StateIpc;
using HerdrOps.App.Views;
using HerdrOps.Contracts.StateIpc;

namespace HerdrOps.RuntimeTests;

[TestClass]
public sealed class LiveDashboardRenderingTests
{
    [TestMethod]
    public void LiveOverviewOrganizationAndAgentDetailRenderFromOneCoreSnapshot()
    {
        WpfTestHost.Run(() =>
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
    }

    [TestMethod]
    public void UnsupportedHerdrFieldsRenderAsUnknownAndAgentTopologyIsKeyboardSelectable()
    {
        WpfTestHost.Run(() =>
        {
            var dashboard = CreateDashboard();
            var shell = new ShellView(dashboard);
            shell.Navigation.SelectedIndex = 1;
            Layout(shell, new Size(1672, 941));
            var topology = EnumerateDescendants(shell)
                .OfType<ListBox>()
                .Single(list => string.Equals(
                    AutomationProperties.GetName(list),
                    "โครงสร้าง Workspace Tab และ Agent จาก Core",
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
                .Select(text => text.Text)
                .ToArray();
            Assert.IsTrue(visibleText.Contains("Unknown", StringComparer.Ordinal));
            Assert.IsFalse(visibleText.Contains("100", StringComparer.Ordinal));
        });
    }

    private static LiveDashboardState CreateDashboard()
    {
        var state = CreateState();
        var payload = new HerdrOpsStateSnapshotPayload(
            state,
            HerdrOpsStateIpcJson.ComputeSha256(state));
        var envelope = HerdrOpsStateIpcJson.CreateEnvelope(
            HerdrOpsStateIpcProtocol.MessageTypes.Snapshot,
            state.LastIngestSequence,
            new DateTimeOffset(2026, 8, 14, 14, 32, 0, TimeSpan.Zero),
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
                null),
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
        Assert.IsGreaterThan(10_000L, output.Length, $"Rendered evidence was unexpectedly small: {path}");
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
