using System.IO;
using System.Security.Cryptography;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using HerdrOps.App.Localization;
using HerdrOps.App.Summaries;
using HerdrOps.App.Views;

namespace HerdrOps.RuntimeTests;

[TestClass]
[DoNotParallelize]
public sealed class DailySummaryRenderingTests
{
    private const int ReferenceWidth = 1672;
    private const int ReferenceHeight = 941;
    private const int CompactWidth = 1366;
    private const int CompactHeight = 768;

    [TestMethod]
    public void ActualWpfDailySummaryRendersSyntheticEvidenceInBothLanguages()
    {
        WpfTestHost.Run(RenderEvidence, TimeSpan.FromSeconds(90));
    }

    private static void RenderEvidence()
    {
        var language = UiLanguageService.Shared;
        var evidenceDirectory = Path.Combine(
            FindRepositoryRoot(),
            "artifacts",
            "design-evidence",
            "v0.6.0",
            "issue-32",
            "daily-summary");
        Directory.CreateDirectory(evidenceDirectory);

        try
        {
            language.SetLanguage(UiLanguage.Thai);
            var thaiShell = CreateShell();
            Layout(thaiShell, ReferenceWidth, ReferenceHeight);
            AssertSurface(thaiShell, thaiShell.FindName("DailySummaryPage"), language, expectThai: true);
            var thaiPath = Path.Combine(evidenceDirectory, "daily-summary-th-1672x941.png");
            RenderPng(thaiShell, ReferenceWidth, ReferenceHeight, thaiPath);

            var thaiCompact = CreateShell();
            Layout(thaiCompact, CompactWidth, CompactHeight);
            AssertSurface(thaiCompact, thaiCompact.FindName("DailySummaryPage"), language, expectThai: true);
            var compactPath = Path.Combine(evidenceDirectory, "daily-summary-th-1366x768.png");
            RenderPng(thaiCompact, CompactWidth, CompactHeight, compactPath);

            var missingShell = CreateShell();
            var missingPage = Assert.IsInstanceOfType<DailySummaryView>(missingShell.FindName("DailySummaryPage"));
            missingPage.DataContext = DailySummaryState.CreateUnavailable();
            Layout(missingShell, ReferenceWidth, ReferenceHeight);
            AssertSurface(missingShell, missingPage, language, expectThai: true, expectMissing: true);
            var missingPath = Path.Combine(evidenceDirectory, "daily-summary-th-missing-1672x941.png");
            RenderPng(missingShell, ReferenceWidth, ReferenceHeight, missingPath);
            Assert.AreNotEqual(PixelHash(thaiPath), PixelHash(missingPath));

            language.SetLanguage(UiLanguage.English);
            var englishShell = CreateShell();
            Layout(englishShell, ReferenceWidth, ReferenceHeight);
            AssertSurface(englishShell, englishShell.FindName("DailySummaryPage"), language, expectThai: false);
            var englishPath = Path.Combine(evidenceDirectory, "daily-summary-en-1672x941.png");
            RenderPng(englishShell, ReferenceWidth, ReferenceHeight, englishPath);
            Assert.AreNotEqual(PixelHash(thaiPath), PixelHash(englishPath));
        }
        finally
        {
            language.SetLanguage(UiLanguage.Thai);
        }
    }

    private static ShellView CreateShell()
    {
        var shell = ShellView.CreateSyntheticPreview();
        Assert.IsTrue(shell.NavigateTo("daily-summary"));
        return shell;
    }

    private static void AssertSurface(
        ShellView shell,
        object? pageObject,
        UiLanguageService language,
        bool expectThai,
        bool expectMissing = false)
    {
        var page = Assert.IsInstanceOfType<DailySummaryView>(pageObject);
        Assert.AreEqual(Visibility.Visible, page.Visibility);
        Assert.AreEqual(Visibility.Collapsed, Assert.IsInstanceOfType<Grid>(shell.FindName("PlaceholderPage")).Visibility);

        foreach (var name in new[]
                 {
                     "DailySummaryEvidenceBoundary",
                     "DailySummarySummaryCardsRegion",
                     "DailySummaryHighlightsRegion",
                     "DailySummaryStrengthsRegion",
                     "DailySummaryAreasRegion",
                     "DailySummaryRepeatedIssuesRegion",
                     "DailySummaryRecommendationsRegion",
                     "DailySummaryTimelineRegion",
                     "DailySummaryWorkstreamRegion",
                     "DailySummaryDayOverviewRegion",
                 })
        {
            var region = Assert.IsInstanceOfType<FrameworkElement>(page.FindName(name));
            Assert.AreEqual(Visibility.Visible, region.Visibility, name);
            Assert.IsGreaterThan(0d, region.ActualWidth, name);
            Assert.IsGreaterThan(0d, region.ActualHeight, name);
        }

        var state = Assert.IsInstanceOfType<DailySummaryState>(page.DataContext);
        var summary = Assert.IsInstanceOfType<ItemsControl>(page.FindName("DailySummarySummaryCardsRegion"));
        Assert.HasCount(5, summary.Items);
        Assert.IsTrue(state.SummaryCards.All(card => card.SourceIds.All(
            sourceId => state.Snapshot is null || state.Snapshot.AcceptedSources.Any(item => item.SourceId == sourceId))));
        AssertVisibleTextContains(shell, language["DailySummaryPageTitle"]);
        AssertVisibleTextContains(page, expectMissing ? "—" : state.SourceLabel);

        var automation = AutomationProperties.GetName(page);
        Assert.AreEqual(language["DailySummaryPageAutomation"], automation);
        if (expectMissing)
        {
            Assert.IsNull(state.Snapshot);
            AssertVisibleTextContains(page, language["DailySummaryLiveBoundary"]);
        }

        var visible = VisibleText(shell);
        if (expectThai)
        {
            Assert.IsTrue(visible.Any(value => Regex.IsMatch(value, "[ก-๙]", RegexOptions.CultureInvariant)));
            AssertNoVisibleEnglishCopy(page);
        }
        else
        {
            AssertNoVisibleThaiCopy(shell);
        }
    }

    private static void AssertNoVisibleThaiCopy(DependencyObject root)
    {
        var values = VisibleText(root)
            .Where(value => Regex.IsMatch(value, "[ก-๙]", RegexOptions.CultureInvariant))
            .ToArray();
        Assert.IsEmpty(values, $"English Daily Summary contains Thai copy: {string.Join(" | ", values)}");
    }

    private static void AssertNoVisibleEnglishCopy(DependencyObject root)
    {
        var knownEnglish = new[]
        {
            "Daily Summary",
            "Accepted Sources",
            "Activity Events",
            "Evidence Items",
            "Recommended Actions",
            "Workstream Summary",
            "Key Events Timeline",
        };
        var values = VisibleText(root)
            .Where(value => knownEnglish.Any(english => value.Contains(english, StringComparison.Ordinal)))
            .ToArray();
        Assert.IsEmpty(values, $"Thai Daily Summary contains English copy: {string.Join(" | ", values)}");
    }

    private static void AssertVisibleTextContains(DependencyObject root, string expected) =>
        Assert.IsTrue(
            VisibleText(root).Any(value => value.Contains(expected, StringComparison.Ordinal)),
            $"Visible Daily Summary text does not contain: {expected}");

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
        for (DependencyObject? current = element; current is not null; current = VisualTreeHelper.GetParent(current))
        {
            if (current is UIElement { Visibility: not Visibility.Visible })
            {
                return false;
            }
        }

        return true;
    }

    private static void Layout(FrameworkElement view, int width, int height)
    {
        var size = new Size(width, height);
        view.Measure(size);
        view.Arrange(new Rect(size));
        view.UpdateLayout();
        view.InvalidateMeasure();
        view.Measure(size);
        view.Arrange(new Rect(size));
        view.UpdateLayout();
    }

    private static void RenderPng(FrameworkElement view, int width, int height, string outputPath)
    {
        Layout(view, width, height);
        var bitmap = new RenderTargetBitmap(width, height, 96, 96, PixelFormats.Pbgra32);
        bitmap.Render(view);
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using var stream = File.Create(outputPath);
        encoder.Save(stream);
    }

    private static string PixelHash(string path) =>
        Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(path)));

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

        Assert.Fail("Could not locate HerdrOps.sln from the test output directory.");
        return string.Empty;
    }
}
