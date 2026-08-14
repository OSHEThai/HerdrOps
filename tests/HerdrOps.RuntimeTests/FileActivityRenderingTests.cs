using System.IO;
using System.Security.Cryptography;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using HerdrOps.App.Files;
using HerdrOps.App.Localization;
using HerdrOps.App.Views;

namespace HerdrOps.RuntimeTests;

[TestClass]
[DoNotParallelize]
public sealed class FileActivityRenderingTests
{
    [TestMethod]
    public void ActualWpfFileActivityRendersLocalizedSynchronizedBoundedEvidence()
    {
        WpfTestHost.Run(RenderEvidence, TimeSpan.FromSeconds(90));
    }

    private static void RenderEvidence()
    {
        var evidenceDirectory = Path.Combine(
            FindRepositoryRoot(),
            "artifacts",
            "design-evidence",
            "v0.3.0",
            "issue-15",
            "contract-backed-wpf");
        Directory.CreateDirectory(evidenceDirectory);
        var language = UiLanguageService.Shared;
        try
        {
            language.SetLanguage(UiLanguage.Thai);
            var thaiShell = CreateFileActivityShell();
            var thaiDefault = Path.Combine(evidenceDirectory, "file-activity-th-1672x941.png");
            RenderPng(thaiShell, 1672, 941, thaiDefault);
            AssertRegions(thaiShell);
            AssertVisibleTextContains(thaiShell, language["FileSummaryRead"]);
            AssertVisibleTextContains(thaiShell, language["FileDetails"]);
            AssertVisibleTextContains(thaiShell, language["FileSyntheticBoundary"]);
            AssertVisibleTextDoesNotContain(thaiShell, "Files Read");
            AssertVisibleTextDoesNotContain(thaiShell, "File Details");
            AssertVisibleTextDoesNotContain(thaiShell, "All Actions");

            var page = Assert.IsInstanceOfType<FileActivityView>(thaiShell.FindName("FileActivityPage"));
            var state = Assert.IsInstanceOfType<FileActivityState>(page.DataContext);
            var blocked = state.VisibleEvents.Single(item => item.EventId == "FILE-006");
            state.SelectedEvent = blocked;
            Layout(thaiShell, 1672, 941);
            Assert.AreEqual("FILE-006", state.SelectedDetail?.EventId);
            Assert.AreEqual(language["FileBlockedPathPlaceholder"], state.SelectedDetail?.RelativePath);
            Assert.IsLessThanOrEqualTo(8, state.SelectedDetail?.DiffLines.Count ?? int.MaxValue);
            var thaiSelected = Path.Combine(
                evidenceDirectory,
                "file-activity-th-blocked-selected-1672x941.png");
            RenderPng(thaiShell, 1672, 941, thaiSelected);
            Assert.AreNotEqual(PixelHash(thaiDefault), PixelHash(thaiSelected));

            var compactShell = CreateFileActivityShell();
            RenderPng(
                compactShell,
                1366,
                768,
                Path.Combine(evidenceDirectory, "file-activity-th-1366x768.png"));
            AssertRegions(compactShell);

            thaiShell.SetLanguage(UiLanguage.English);
            Layout(thaiShell, 1672, 941);
            AssertVisibleTextContains(thaiShell, "Files Read");
            AssertVisibleTextContains(thaiShell, "[blocked outside repository]");
            AssertNoVisibleThaiCopy(thaiShell);

            var englishShell = CreateFileActivityShell();
            RenderPng(
                englishShell,
                1672,
                941,
                Path.Combine(evidenceDirectory, "file-activity-en-1672x941.png"));
            AssertRegions(englishShell);
            AssertVisibleTextContains(englishShell, "Files Read");
            AssertVisibleTextContains(englishShell, "File Details");
            AssertVisibleTextContains(englishShell, "All Actions");
            AssertNoVisibleThaiCopy(englishShell);
        }
        finally
        {
            language.SetLanguage(UiLanguage.Thai);
        }
    }

    private static ShellView CreateFileActivityShell()
    {
        var shell = ShellView.CreateSyntheticPreview();
        shell.Navigation.SelectedIndex = 6;
        return shell;
    }

    private static void AssertRegions(ShellView shell)
    {
        var page = Assert.IsInstanceOfType<FileActivityView>(shell.FindName("FileActivityPage"));
        Assert.AreEqual(Visibility.Visible, page.Visibility);
        Assert.AreEqual(
            Visibility.Collapsed,
            Assert.IsInstanceOfType<Grid>(shell.FindName("PlaceholderPage")).Visibility);
        foreach (var regionName in new[]
                 {
                     "FileSummaryCardsRegion",
                     "FileFiltersRegion",
                     "FileEventTableRegion",
                     "FileDetailsRegion",
                     "FileTimelineRegion",
                     "FileTypeRegion",
                     "FileRiskRegion",
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
            $"Visible text contains copy from the other language: {unexpected}");

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
