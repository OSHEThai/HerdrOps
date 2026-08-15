using System.IO;
using System.Security.Cryptography;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using HerdrOps.App.Delegation;
using HerdrOps.App.Localization;
using HerdrOps.App.Views;

namespace HerdrOps.RuntimeTests;

[TestClass]
[DoNotParallelize]
public sealed class DelegationGraphRenderingTests
{
    [TestMethod]
    public void ActualWpfDelegationGraphRendersLocalizedSynchronizedEvidence()
    {
        WpfTestHost.Run(RenderEvidence, TimeSpan.FromSeconds(90));
    }

    [TestMethod]
    public void GraphControlsAndTaskSelectionUpdateTheRenderedProjection()
    {
        WpfTestHost.Run(() =>
        {
            UiLanguageService.Shared.SetLanguage(UiLanguage.Thai);
            var shell = CreateDelegationShell();
            Layout(shell, 1672, 941);
            var page = Page(shell);
            var state = Assert.IsInstanceOfType<DelegationGraphState>(page.DataContext);
            var fit = FindButton(page, "FitButton");
            fit.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            var fittedScale = page.CurrentScale;

            FindButton(page, "ZoomInButton").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            Assert.IsGreaterThan(fittedScale, page.CurrentScale);
            FindButton(page, "ZoomOutButton").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));

            var task = state.TaskTreeItems.Single(item => item.TaskId == "TASK-122");
            var taskTree = Assert.IsInstanceOfType<ListBox>(page.FindName("TaskTreeList"));
            taskTree.SelectedItem = task;
            Layout(shell, 1672, 941);

            Assert.AreEqual("TASK-122", state.SelectedTask?.TaskId);
            Assert.IsTrue(state.Timeline.All(item => item.TaskId == "TASK-122"));
            Assert.IsTrue(state.GraphEdges.Where(item => item.Opacity >= 0.9d).All(item => item.TaskId == "TASK-122"));

            var blocked = state.GraphNodes.Single(item => item.ActorId == "backend-worker-02");
            var graphNodes = Assert.IsInstanceOfType<ListBox>(page.FindName("GraphNodeList"));
            graphNodes.SelectedItem = blocked;
            Layout(shell, 1672, 941);

            Assert.AreEqual(blocked.ActorId, state.SelectedDetail.ActorId);
            Assert.AreEqual(UiLanguageService.Shared["StatusBlocked"], state.SelectedDetail.Status);
            AssertVisibleTextContains(page, UiLanguageService.Shared["StatusBlocked"]);
        });
    }

    [TestMethod]
    public void AccessibleListExposesEquivalentNamesStatusesRelationshipsAndSelection()
    {
        WpfTestHost.Run(() =>
        {
            UiLanguageService.Shared.SetLanguage(UiLanguage.English);
            var shell = CreateDelegationShell();
            Layout(shell, 1672, 941);
            var page = Page(shell);
            var state = Assert.IsInstanceOfType<DelegationGraphState>(page.DataContext);
            FindButton(page, "AccessibleViewButton").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            Layout(shell, 1672, 941);

            var visual = Assert.IsInstanceOfType<Grid>(page.FindName("VisualGraphRegion"));
            var accessible = Assert.IsInstanceOfType<ListBox>(page.FindName("AccessibleNodeList"));
            Assert.IsTrue(state.IsAccessibleView);
            Assert.AreEqual(Visibility.Collapsed, visual.Visibility);
            Assert.AreEqual(Visibility.Visible, accessible.Visibility);
            Assert.HasCount(state.GraphNodes.Count, state.AccessibleItems);
            Assert.IsFalse(string.IsNullOrWhiteSpace(AutomationProperties.GetName(accessible)));

            foreach (var node in state.GraphNodes)
            {
                var equivalent = state.AccessibleItems.Single(item => item.ActorId == node.ActorId);
                Assert.AreEqual(node.Name, equivalent.Name);
                Assert.AreEqual(node.Status, equivalent.Status);
                Assert.IsFalse(string.IsNullOrWhiteSpace(equivalent.Description));
            }

            var reviewer = state.AccessibleItems.Single(item => item.ActorId == "reviewer-01");
            accessible.SelectedItem = reviewer;
            Layout(shell, 1672, 941);
            Assert.AreEqual(reviewer.ActorId, state.SelectedNode?.ActorId);
            Assert.AreEqual(reviewer.ActorId, state.SelectedDetail.ActorId);
            Assert.AreEqual("Review", state.SelectedDetail.Status);

            var firstContainer = Assert.IsInstanceOfType<ListBoxItem>(
                accessible.ItemContainerGenerator.ContainerFromIndex(0));
            Assert.IsTrue(firstContainer.Focusable);
            Assert.IsTrue(firstContainer.IsTabStop);
            AssertNoVisibleThaiCopy(page);
        });
    }

    private static void RenderEvidence()
    {
        var evidenceDirectory = Path.Combine(
            FindRepositoryRoot(),
            "artifacts",
            "design-evidence",
            "v0.4.0",
            "issue-20",
            "contract-backed-wpf");
        Directory.CreateDirectory(evidenceDirectory);
        var language = UiLanguageService.Shared;

        try
        {
            language.SetLanguage(UiLanguage.Thai);
            var thaiShell = CreateDelegationShell();
            PrepareGraph(thaiShell, 1672, 941);
            var thaiDefault = Path.Combine(evidenceDirectory, "delegation-graph-th-1672x941.png");
            RenderPng(thaiShell, 1672, 941, thaiDefault);
            AssertRegions(thaiShell);
            AssertVisibleTextContains(thaiShell, language["DelegationGraphTitle"]);
            AssertVisibleTextContains(thaiShell, language["DelegationTaskTreeTitle"]);
            AssertVisibleTextContains(thaiShell, language["DelegationDetailTitle"]);
            AssertVisibleTextContains(thaiShell, language["DelegationTimelineTitle"]);
            AssertVisibleTextContains(thaiShell, language["DelegationSyntheticBoundary"]);
            AssertVisibleTextDoesNotContain(thaiShell, "Assignment recorded for");
            AssertVisibleTextDoesNotContain(thaiShell, "Implementation and evidence are ready for review");

            var page = Page(thaiShell);
            var state = Assert.IsInstanceOfType<DelegationGraphState>(page.DataContext);
            state.SelectedTask = state.TaskTreeItems.Single(item => item.TaskId == "TASK-122");
            state.SelectedNode = state.GraphNodes.Single(item => item.ActorId == "backend-worker-02");
            Layout(thaiShell, 1672, 941);
            var thaiSelected = Path.Combine(
                evidenceDirectory,
                "delegation-graph-th-blocked-selected-1672x941.png");
            RenderPng(thaiShell, 1672, 941, thaiSelected);
            Assert.AreNotEqual(PixelHash(thaiDefault), PixelHash(thaiSelected));

            var compactShell = CreateDelegationShell();
            PrepareGraph(compactShell, 1366, 768);
            RenderPng(
                compactShell,
                1366,
                768,
                Path.Combine(evidenceDirectory, "delegation-graph-th-1366x768.png"));
            AssertRegions(compactShell);

            language.SetLanguage(UiLanguage.English);
            var englishShell = CreateDelegationShell();
            PrepareGraph(englishShell, 1672, 941);
            RenderPng(
                englishShell,
                1672,
                941,
                Path.Combine(evidenceDirectory, "delegation-graph-en-1672x941.png"));
            AssertVisibleTextContains(englishShell, "Delegation Graph");
            AssertVisibleTextContains(englishShell, "Task Tree");
            AssertNoVisibleThaiCopy(englishShell);

            var accessibleShell = CreateDelegationShell();
            PrepareGraph(accessibleShell, 1672, 941);
            var accessiblePage = Page(accessibleShell);
            FindButton(accessiblePage, "AccessibleViewButton")
                .RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            Layout(accessibleShell, 1672, 941);
            RenderPng(
                accessibleShell,
                1672,
                941,
                Path.Combine(evidenceDirectory, "delegation-graph-en-accessible-1672x941.png"));
            Assert.IsTrue(
                Assert.IsInstanceOfType<DelegationGraphState>(accessiblePage.DataContext).IsAccessibleView);
        }
        finally
        {
            language.SetLanguage(UiLanguage.Thai);
        }
    }

    private static ShellView CreateDelegationShell()
    {
        var shell = ShellView.CreateSyntheticPreview();
        shell.Navigation.SelectedIndex = 3;
        return shell;
    }

    private static DelegationGraphView Page(ShellView shell) =>
        Assert.IsInstanceOfType<DelegationGraphView>(shell.FindName("DelegationGraphPage"));

    private static Button FindButton(DelegationGraphView page, string name) =>
        Assert.IsInstanceOfType<Button>(page.FindName(name));

    private static void PrepareGraph(ShellView shell, int width, int height)
    {
        Layout(shell, width, height);
        FindButton(Page(shell), "FitButton").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        Layout(shell, width, height);
    }

    private static void AssertRegions(ShellView shell)
    {
        var page = Page(shell);
        Assert.AreEqual(Visibility.Visible, page.Visibility);
        Assert.AreEqual(
            Visibility.Collapsed,
            Assert.IsInstanceOfType<Grid>(shell.FindName("PlaceholderPage")).Visibility);
        foreach (var regionName in new[]
                 {
                     "DelegationSummaryRegion",
                     "TaskTreeRegion",
                     "DelegationGraphRegion",
                     "DelegationTimelineRegion",
                     "DelegationDetailRegion",
                 })
        {
            var region = Assert.IsInstanceOfType<FrameworkElement>(page.FindName(regionName));
            Assert.AreEqual(Visibility.Visible, region.Visibility, $"Region is hidden: {regionName}");
            Assert.IsGreaterThan(0d, region.ActualWidth, $"Region has no width: {regionName}");
            Assert.IsGreaterThan(0d, region.ActualHeight, $"Region has no height: {regionName}");
        }
    }

    private static void AssertNoVisibleThaiCopy(DependencyObject root)
    {
        var thai = VisibleText(root)
            .Where(value => Regex.IsMatch(value, "[ก-๙]", RegexOptions.CultureInvariant))
            .ToArray();
        Assert.IsEmpty(thai, $"English mode contains Thai copy: {string.Join(" | ", thai)}");
    }

    private static void AssertVisibleTextContains(DependencyObject root, string expected) =>
        Assert.IsTrue(
            VisibleText(root).Any(value => value.Contains(expected, StringComparison.Ordinal)),
            $"Visible text does not contain: {expected}");

    private static void AssertVisibleTextDoesNotContain(DependencyObject root, string unexpected) =>
        Assert.IsFalse(
            VisibleText(root).Any(value => value.Contains(unexpected, StringComparison.Ordinal)),
            $"Visible text contains text from the other language: {unexpected}");

    private static IReadOnlyList<string> VisibleText(DependencyObject root) =>
        EnumerateDescendants(root)
            .OfType<TextBlock>()
            .Where(IsEffectivelyVisible)
            .Select(text => new TextRange(text.ContentStart, text.ContentEnd).Text.Trim())
            .Where(text => !string.IsNullOrWhiteSpace(text))
            .ToArray();

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
        for (DependencyObject? current = element;
             current is not null;
             current = VisualTreeHelper.GetParent(current))
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
        Assert.IsGreaterThan(10_000L, output.Length, $"Evidence image was unexpectedly small: {outputPath}");
    }

    private static void Layout(FrameworkElement element, double width, double height)
    {
        var size = new Size(width, height);
        element.Measure(size);
        element.Arrange(new Rect(size));
        element.UpdateLayout();
    }

    private static string PixelHash(string path)
    {
        using var input = File.OpenRead(path);
        var decoder = new PngBitmapDecoder(
            input,
            BitmapCreateOptions.PreservePixelFormat,
            BitmapCacheOption.OnLoad);
        var frame = decoder.Frames[0];
        var stride = frame.PixelWidth * 4;
        var pixels = new byte[stride * frame.PixelHeight];
        var converted = new FormatConvertedBitmap(frame, PixelFormats.Bgra32, null, 0);
        converted.CopyPixels(pixels, stride, 0);
        return Convert.ToHexString(SHA256.HashData(pixels));
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
