using System.IO;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using HerdrOps.App.Localization;
using HerdrOps.App.Views;
using HerdrOps.App.Widgets;

namespace HerdrOps.RuntimeTests;

[TestClass]
[DoNotParallelize]
public sealed class LanguageSwitchRenderingTests
{
    [TestMethod]
    public void ShellOverviewAndWidgetsRenderOneSelectedLanguageAtATime()
    {
        WpfTestHost.Run(() =>
        {
            var language = UiLanguageService.Shared;
            try
            {
                language.SetLanguage(UiLanguage.Thai);
                var shell = ShellView.CreateSyntheticPreview();
                Layout(shell, 1672, 941);

                Assert.AreEqual("ภาพรวม", shell.Navigation.SelectedDestination.DisplayName);
                AssertVisibleTextContains(shell, language["OverviewTotalAgents"]);
                AssertVisibleTextDoesNotContain(shell, language.Text(UiLanguage.English, "OverviewTotalAgents"));

                var thaiButton = Assert.IsInstanceOfType<Button>(shell.FindName("ThaiLanguageButton"));
                var englishButton = Assert.IsInstanceOfType<Button>(shell.FindName("EnglishLanguageButton"));
                Assert.IsTrue(thaiButton.Focusable && thaiButton.IsTabStop);
                Assert.IsTrue(englishButton.Focusable && englishButton.IsTabStop);
                Assert.IsFalse(string.IsNullOrWhiteSpace(AutomationProperties.GetName(thaiButton)));
                Assert.IsFalse(string.IsNullOrWhiteSpace(AutomationProperties.GetName(englishButton)));

                var evidenceDirectory = Path.Combine(
                    FindRepositoryRoot(),
                    "artifacts",
                    "design-evidence",
                    "v0.1",
                    "issue-60");
                Directory.CreateDirectory(evidenceDirectory);
                var thaiShell = ShellView.CreateSyntheticPreview();
                thaiShell.Navigation.SelectedIndex = 1;
                RenderPng(thaiShell, 1672, 941, Path.Combine(evidenceDirectory, "shell-th-100.png"));
                RenderPng(ShellView.CreateSyntheticPreview(), 1672, 941, Path.Combine(evidenceDirectory, "overview-th-100.png"));
                RenderPng(new WidgetGalleryView(), 1536, 1024, Path.Combine(evidenceDirectory, "widget-gallery-th-100.png"));

                englishButton.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                Layout(shell, 1672, 941);

                Assert.AreEqual(UiLanguage.English, language.CurrentLanguage);
                Assert.AreEqual("Overview", shell.Navigation.SelectedDestination.DisplayName);
                AssertVisibleTextContains(shell, language["OverviewTotalAgents"]);
                AssertNoVisibleThaiCopy(shell);

                var gallery = new WidgetGalleryView();
                Layout(gallery, 1536, 1024);
                AssertVisibleTextContains(gallery, language["WidgetGalleryTitle"]);
                AssertVisibleTextContains(gallery, language["WidgetCompactName"]);
                AssertNoVisibleThaiCopy(gallery);

                var englishShell = ShellView.CreateSyntheticPreview();
                englishShell.Navigation.SelectedIndex = 1;
                RenderPng(englishShell, 1672, 941, Path.Combine(evidenceDirectory, "shell-en-100.png"));
                RenderPng(ShellView.CreateSyntheticPreview(), 1672, 941, Path.Combine(evidenceDirectory, "overview-en-100.png"));
                RenderPng(gallery, 1536, 1024, Path.Combine(evidenceDirectory, "widget-gallery-en-100.png"));
            }
            finally
            {
                language.SetLanguage(UiLanguage.Thai);
            }
        });
    }

    private static void AssertNoVisibleThaiCopy(DependencyObject root)
    {
        var thaiCopy = VisibleText(root)
            .Where(value => Regex.IsMatch(value, "[ก-๙]", RegexOptions.CultureInvariant))
            .ToArray();
        Assert.IsEmpty(thaiCopy, $"English mode contains Thai copy: {string.Join(" | ", thaiCopy)}");
    }

    private static void AssertVisibleTextContains(DependencyObject root, string expected) =>
        Assert.IsTrue(
            VisibleText(root).Any(value => value.Contains(expected, StringComparison.Ordinal)),
            $"Visible text does not contain: {expected}");

    private static void AssertVisibleTextDoesNotContain(DependencyObject root, string unexpected) =>
        Assert.IsFalse(
            VisibleText(root).Any(value => value.Contains(unexpected, StringComparison.Ordinal)),
            $"Visible text still contains the other locale: {unexpected}");

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

    private static void Layout(FrameworkElement element, double width, double height)
    {
        var size = new Size(width, height);
        element.Measure(size);
        element.Arrange(new Rect(size));
        element.UpdateLayout();
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
        Assert.IsGreaterThan(10_000L, output.Length, $"Language evidence was unexpectedly small: {outputPath}");
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
