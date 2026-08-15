using System.IO;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using HerdrOps.App.Alignment;
using HerdrOps.App.Localization;
using HerdrOps.App.Views;

namespace HerdrOps.RuntimeTests;

[TestClass]
[DoNotParallelize]
public sealed class TaskAlignmentRenderingTests
{
    [TestMethod]
    public void ActualWpfTaskAlignmentRendersLocalizedTraceableReferenceRegions()
    {
        WpfTestHost.Run(RenderEvidence, TimeSpan.FromSeconds(90));
    }

    [TestMethod]
    public void RenderedProjectionExposesAnalyzerVerdictScoresAndEvidenceBoundary()
    {
        WpfTestHost.Run(() =>
        {
            UiLanguageService.Shared.SetLanguage(UiLanguage.Thai);
            var shell = CreateAlignmentShell();
            Layout(shell, 1672, 941);
            var page = Page(shell);
            var state = Assert.IsInstanceOfType<TaskAlignmentState>(page.DataContext);

            Assert.IsTrue(state.HasAnalysis);
            Assert.AreEqual("76/100", state.Header.GoalScore);
            Assert.AreEqual("88/100", state.Header.ScopeScore);
            Assert.AreEqual("40/100", state.Header.AcceptanceScore);
            Assert.AreEqual(
                UiLanguageService.Shared["AlignmentVerdictPartial"],
                state.Header.Verdict);
            AssertVisibleTextContains(page, state.Header.Verdict);
            AssertVisibleTextContains(page, state.EvidenceBoundary);
            Assert.IsFalse(string.IsNullOrWhiteSpace(
                AutomationProperties.GetName(
                    Assert.IsInstanceOfType<Grid>(page.FindName("AlignmentRoot")))));
            AssertRegions(shell);
        });
    }

    private static void RenderEvidence()
    {
        var evidenceDirectory = Path.Combine(
            FindRepositoryRoot(),
            "artifacts",
            "design-evidence",
            "v0.4.0",
            "issue-21",
            "contract-backed-wpf");
        Directory.CreateDirectory(evidenceDirectory);
        var language = UiLanguageService.Shared;

        try
        {
            language.SetLanguage(UiLanguage.Thai);
            var thaiShell = CreateAlignmentShell();
            Layout(thaiShell, 1672, 941);
            RenderPng(
                thaiShell,
                1672,
                941,
                Path.Combine(evidenceDirectory, "task-alignment-th-1672x941.png"));
            AssertRegions(thaiShell);
            AssertVisibleTextContains(thaiShell, language["AlignmentContractTitle"]);
            AssertVisibleTextContains(thaiShell, language["AlignmentCriteriaTitle"]);
            AssertVisibleTextContains(thaiShell, language["AlignmentDeviationTitle"]);
            AssertVisibleTextContains(thaiShell, language["AlignmentSyntheticBoundary"]);
            AssertVisibleTextDoesNotContain(thaiShell, "Assignment Contract");
            AssertVisibleTextDoesNotContain(thaiShell, "Partially Misaligned");

            var compactShell = CreateAlignmentShell();
            Layout(compactShell, 1366, 768);
            RenderPng(
                compactShell,
                1366,
                768,
                Path.Combine(evidenceDirectory, "task-alignment-th-1366x768.png"));
            AssertRegions(compactShell);

            language.SetLanguage(UiLanguage.English);
            var englishShell = CreateAlignmentShell();
            Layout(englishShell, 1672, 941);
            RenderPng(
                englishShell,
                1672,
                941,
                Path.Combine(evidenceDirectory, "task-alignment-en-1672x941.png"));
            AssertRegions(englishShell);
            AssertVisibleTextContains(englishShell, "Assignment Contract");
            AssertVisibleTextContains(englishShell, "Partially Misaligned");
            AssertNoVisibleThaiCopy(englishShell);
        }
        finally
        {
            language.SetLanguage(UiLanguage.Thai);
        }
    }

    private static ShellView CreateAlignmentShell()
    {
        var shell = ShellView.CreateSyntheticPreview();
        Assert.IsTrue(shell.NavigateTo("task-alignment"));
        return shell;
    }

    private static TaskAlignmentView Page(ShellView shell) =>
        Assert.IsInstanceOfType<TaskAlignmentView>(shell.FindName("TaskAlignmentPage"));

    private static void AssertRegions(ShellView shell)
    {
        var page = Page(shell);
        Assert.AreEqual(Visibility.Visible, page.Visibility);
        Assert.AreEqual(
            Visibility.Collapsed,
            Assert.IsInstanceOfType<Grid>(shell.FindName("PlaceholderPage")).Visibility);
        foreach (var regionName in new[]
                 {
                     "AlignmentVerdictRegion",
                     "AlignmentTaskHeaderRegion",
                     "AlignmentContractRegion",
                     "AlignmentAcknowledgementRegion",
                     "AlignmentPlannedStepsRegion",
                     "AlignmentCriteriaRegion",
                     "AlignmentFilesRegion",
                     "AlignmentActionsRegion",
                     "AlignmentDeviationRegion",
                     "AlignmentEvidenceRegion",
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
        Assert.IsGreaterThan(
            10_000L,
            output.Length,
            $"Evidence image was unexpectedly small: {outputPath}");
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
}
