using System.IO;
using System.Security.Cryptography;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using HerdrOps.App.Evaluation;
using HerdrOps.App.Localization;
using HerdrOps.App.Views;

namespace HerdrOps.RuntimeTests;

[TestClass]
[DoNotParallelize]
public sealed class EvaluationRenderingTests
{
    private const int ReferenceWidth = 1672;
    private const int ReferenceHeight = 941;
    private const int CompactWidth = 1366;
    private const int CompactHeight = 768;

    private static readonly string[] RegionNames =
    [
        "EvaluationEvidenceBoundary",
        "EvaluationSummaryRegion",
        "EvaluationDistributionRegion",
        "EvaluationTrendRegion",
        "EvaluationDimensionRegion",
        "EvaluationComparisonRegion",
        "EvaluationTopAgentsRegion",
        "EvaluationLowAgentsRegion",
    ];

    private static readonly string[] EvaluationCopyKeys =
    [
        "EvaluationPageTitle",
        "EvaluationSyntheticSource",
        "EvaluationLiveSourceUnavailable",
        "EvaluationSyntheticBoundary",
        "EvaluationLiveBoundary",
        "EvaluationAverageScoreToday",
        "EvaluationComparedToYesterday",
        "EvaluationTotalEvaluations",
        "EvaluationToday",
        "EvaluationLeaderReviewsPending",
        "EvaluationPmReviewsPending",
        "EvaluationRecurringIssues",
        "EvaluationFromLastWeek",
        "EvaluationScoreDistributionTitle",
        "EvaluationEvaluations",
        "EvaluationScoreBandExcellent",
        "EvaluationScoreBandGood",
        "EvaluationScoreBandAcceptable",
        "EvaluationScoreBandNeedsImprovement",
        "EvaluationScoreBandFail",
        "EvaluationScoreTrendTitle",
        "EvaluationPeriod7Days",
        "EvaluationPeriodToday",
        "EvaluationPeriodLastWeek",
        "EvaluationDimensionBreakdownTitle",
        "EvaluationDimensionGoalAlignment",
        "EvaluationDimensionAcceptanceCriteria",
        "EvaluationDimensionTechnicalQuality",
        "EvaluationDimensionScopeCompliance",
        "EvaluationDimensionEvidence",
        "EvaluationDimensionCommunication",
        "EvaluationWeightedAverage",
        "EvaluationScoreComparisonTitle",
        "EvaluationComparisonDimension",
        "EvaluationComparisonLeaderScore",
        "EvaluationComparisonPmScore",
        "EvaluationComparisonObjectiveEvidence",
        "EvaluationComparisonWeightedScore",
        "EvaluationComparisonTotal",
        "EvaluationTotalWeight",
        "EvaluationTopPerformingAgentsTitle",
        "EvaluationLowPerformingAgentsTitle",
        "EvaluationViewAll",
        "EvaluationTieLabel",
        "EvaluationMissingScoreLabel",
        "EvaluationCompleteLabel",
        "EvaluationInvalidLabel",
        "EvaluationUnavailableLabel",
        "EvaluationSyntheticStatus",
        "EvaluationNoRankingData",
        "EvaluationRankingUnavailable",
    ];

    [TestMethod]
    public void SyntheticWpfEvaluationRendersLocalizedReferenceHierarchyAndMissingScore()
    {
        WpfTestHost.Run(RenderEvidence, TimeSpan.FromSeconds(90));
    }

    private static void RenderEvidence()
    {
        var repositoryRoot = FindRepositoryRoot();
        var referencePath = Path.Combine(repositoryRoot, "docs", "design", "reference", "09-evaluation.png");
        Assert.IsTrue(File.Exists(referencePath), $"Approved Evaluation reference is missing: {referencePath}");

        var evidenceDirectory = Path.Combine(
            repositoryRoot,
            "artifacts",
            "design-evidence",
            "v0.6.0",
            "issue-31",
            "evaluation");
        Directory.CreateDirectory(evidenceDirectory);
        var language = UiLanguageService.Shared;

        try
        {
            language.SetLanguage(UiLanguage.Thai);
            var thaiShell = CreateEvaluationShell();
            Layout(thaiShell, ReferenceWidth, ReferenceHeight);
            var thaiPage = Page(thaiShell);
            AssertRegions(thaiShell, thaiPage);
            AssertThaiSurface(thaiPage, language);
            var thaiPath = Path.Combine(evidenceDirectory, "evaluation-th-1672x941.png");
            RenderPng(thaiShell, ReferenceWidth, ReferenceHeight, thaiPath);

            var compactShell = CreateEvaluationShell();
            Layout(compactShell, CompactWidth, CompactHeight);
            var compactPage = Page(compactShell);
            AssertRegions(compactShell, compactPage);
            AssertThaiSurface(compactPage, language);
            var scroll = Assert.IsInstanceOfType<ScrollViewer>(compactPage.FindName("EvaluationScrollViewer"));
            Assert.IsGreaterThan(0d, scroll.ViewportHeight);
            Assert.IsGreaterThanOrEqualTo(scroll.ViewportHeight, scroll.ExtentHeight);
            var compactPath = Path.Combine(evidenceDirectory, "evaluation-th-1366x768.png");
            RenderPng(compactShell, CompactWidth, CompactHeight, compactPath);

            var missingShell = CreateEvaluationShell();
            var missingPage = Page(missingShell);
            missingPage.DataContext = EvaluationState.CreateMissingScorePreview();
            Layout(missingShell, ReferenceWidth, ReferenceHeight);
            var missingState = Assert.IsInstanceOfType<EvaluationState>(missingPage.DataContext);
            Assert.AreEqual(1, missingState.MissingScoreCount);
            AssertVisibleTextContains(missingPage, language["EvaluationMissingScoreLabel"]);
            var missingPath = Path.Combine(evidenceDirectory, "evaluation-th-missing-score-1672x941.png");
            RenderPng(missingShell, ReferenceWidth, ReferenceHeight, missingPath);
            AssertDifferentImages(thaiPath, missingPath);

            language.SetLanguage(UiLanguage.English);
            var englishShell = CreateEvaluationShell();
            Layout(englishShell, ReferenceWidth, ReferenceHeight);
            var englishPage = Page(englishShell);
            AssertRegions(englishShell, englishPage);
            AssertEnglishSurface(englishPage, language);
            var englishPath = Path.Combine(evidenceDirectory, "evaluation-en-1672x941.png");
            RenderPng(englishShell, ReferenceWidth, ReferenceHeight, englishPath);
            AssertDifferentImages(thaiPath, englishPath);

            var englishCompactShell = CreateEvaluationShell();
            Layout(englishCompactShell, CompactWidth, CompactHeight);
            var englishCompactPage = Page(englishCompactShell);
            AssertRegions(englishCompactShell, englishCompactPage);
            AssertEnglishSurface(englishCompactPage, language);
            Assert.IsInstanceOfType<ScrollViewer>(englishCompactPage.FindName("EvaluationScrollViewer"));
            var englishCompactPath = Path.Combine(evidenceDirectory, "evaluation-en-1366x768.png");
            RenderPng(englishCompactShell, CompactWidth, CompactHeight, englishCompactPath);
            AssertDifferentImages(compactPath, englishCompactPath);
        }
        finally
        {
            language.SetLanguage(UiLanguage.Thai);
        }
    }

    private static ShellView CreateEvaluationShell()
    {
        var shell = ShellView.CreateSyntheticPreview();
        Assert.IsTrue(shell.NavigateTo("evaluation"));
        return shell;
    }

    private static EvaluationView Page(ShellView shell) =>
        Assert.IsInstanceOfType<EvaluationView>(shell.FindName("EvaluationPage"));

    private static void AssertRegions(ShellView shell, EvaluationView page)
    {
        Assert.AreEqual(Visibility.Visible, page.Visibility);
        Assert.AreEqual(
            Visibility.Collapsed,
            Assert.IsInstanceOfType<Grid>(shell.FindName("PlaceholderPage")).Visibility);
        foreach (var regionName in RegionNames)
        {
            var region = Assert.IsInstanceOfType<FrameworkElement>(page.FindName(regionName));
            Assert.AreEqual(Visibility.Visible, region.Visibility, $"Region is hidden: {regionName}");
            Assert.IsGreaterThan(0d, region.ActualWidth, $"Region has no width: {regionName}");
            Assert.IsGreaterThan(0d, region.ActualHeight, $"Region has no height: {regionName}");
        }
    }

    private static void AssertThaiSurface(EvaluationView page, UiLanguageService language)
    {
        AssertVisibleTextContains(page, language["EvaluationAverageScoreToday"]);
        AssertVisibleTextContains(page, language["EvaluationScoreDistributionTitle"]);
        AssertVisibleTextContains(page, language["EvaluationScoreTrendTitle"]);
        AssertVisibleTextContains(page, language["EvaluationDimensionBreakdownTitle"]);
        AssertVisibleTextContains(page, language["EvaluationScoreComparisonTitle"]);
        AssertNoCopyFromOtherLanguage(page, language, UiLanguage.English);
    }

    private static void AssertEnglishSurface(EvaluationView page, UiLanguageService language)
    {
        AssertVisibleTextContains(page, language["EvaluationAverageScoreToday"]);
        AssertVisibleTextContains(page, language["EvaluationScoreDistributionTitle"]);
        AssertVisibleTextContains(page, language["EvaluationTopPerformingAgentsTitle"]);
        AssertNoCopyFromOtherLanguage(page, language, UiLanguage.Thai);
    }

    private static void AssertVisibleTextContains(DependencyObject root, string expected) =>
        Assert.IsTrue(
            VisibleText(root).Any(value => value.Contains(expected, StringComparison.Ordinal)),
            $"Visible text does not contain: {expected}");

    private static void AssertVisibleTextDoesNotContain(DependencyObject root, string unexpected) =>
        Assert.IsFalse(
            VisibleText(root).Any(value => value.Contains(unexpected, StringComparison.Ordinal)),
            $"Visible text contains text from the other language: {unexpected}");

    private static void AssertNoCopyFromOtherLanguage(
        DependencyObject root,
        UiLanguageService language,
        UiLanguage otherLanguage)
    {
        foreach (var key in EvaluationCopyKeys)
        {
            var otherText = language.Text(otherLanguage, key);
            if (string.IsNullOrWhiteSpace(otherText) || otherText.Contains("{", StringComparison.Ordinal))
            {
                continue;
            }

            AssertVisibleTextDoesNotContain(root, otherText);
        }
    }

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

    private static void AssertDifferentImages(string firstPath, string secondPath)
    {
        AssertNonBlankImage(firstPath);
        AssertNonBlankImage(secondPath);
        Assert.AreNotEqual(
            DecodedPixelHash(firstPath),
            DecodedPixelHash(secondPath),
            $"Captures must be visually distinct: {firstPath} and {secondPath}");
    }

    private static void AssertNonBlankImage(string path)
    {
        var pixels = DecodePixels(path, out _, out _);
        Assert.IsGreaterThan(8, pixels.Distinct().Count(), $"Evidence image is blank or flat: {path}");
    }

    private static string DecodedPixelHash(string path)
    {
        var pixels = DecodePixels(path, out _, out _);
        return Convert.ToHexString(SHA256.HashData(pixels));
    }

    private static byte[] DecodePixels(string path, out int width, out int height)
    {
        using var input = File.OpenRead(path);
        var frame = BitmapFrame.Create(input, BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnLoad);
        var converted = new FormatConvertedBitmap(frame, PixelFormats.Bgra32, null, 0);
        width = converted.PixelWidth;
        height = converted.PixelHeight;
        var pixels = new byte[width * height * 4];
        converted.CopyPixels(pixels, width * 4, 0);
        return pixels;
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
        long outputLength;
        using (var output = File.Create(outputPath))
        {
            encoder.Save(output);
            outputLength = output.Length;
        }

        Assert.IsGreaterThan(10_000L, outputLength, $"Evidence image is unexpectedly small: {outputPath}");
        AssertNonBlankImage(outputPath);
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

        Assert.Fail("Could not locate HerdrOps.sln from the WPF test output directory.");
        return string.Empty;
    }
}
