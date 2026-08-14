using System.Globalization;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using HerdrOps.App.Views;
using HerdrOps.App.Widgets;

namespace HerdrOps.RuntimeTests;

[TestClass]
public sealed class ShellRenderingTests
{
    private const int ReferenceWidth = 1672;
    private const int ReferenceHeight = 941;

    [TestMethod]
    public void ActualWpfShellAndOverviewRenderWithoutThaiClippingAtRequiredSizes()
    {
        WpfTestHost.Run(RenderEvidence);
    }

    [TestMethod]
    public void ActualWpfWidgetGalleryAndEveryVariantRenderAtRequiredSizes()
    {
        WpfTestHost.Run(RenderWidgetEvidence);
    }

    private static void RenderEvidence()
    {
        var repositoryRoot = FindRepositoryRoot();
        var shellEvidenceDirectory = Path.Combine(
            repositoryRoot,
            "artifacts",
            "design-evidence",
            "v0.1",
            "issue-2");
        Directory.CreateDirectory(shellEvidenceDirectory);

        foreach (var scale in new[] { 1.0, 1.25, 1.5 })
        {
            var view = new ShellView();
            view.Navigation.SelectedIndex = 1;
            var scaleLabel = FormattableString.Invariant($"{scale * 100:0}");
            RenderView(
                view,
                ReferenceWidth,
                ReferenceHeight,
                scale,
                "ThaiCheck",
                Path.Combine(shellEvidenceDirectory, $"shell-{scaleLabel}.png"));
        }

        var overviewEvidenceDirectory = Path.Combine(
            repositoryRoot,
            "artifacts",
            "design-evidence",
            "v0.1",
            "issue-3");
        Directory.CreateDirectory(overviewEvidenceDirectory);

        foreach (var scale in new[] { 1.0, 1.25, 1.5 })
        {
            var scaleLabel = FormattableString.Invariant($"{scale * 100:0}");
            RenderView(
                new ShellView(),
                ReferenceWidth,
                ReferenceHeight,
                scale,
                "ThaiOverviewCheck",
                Path.Combine(overviewEvidenceDirectory, $"overview-{scaleLabel}.png"));
        }

        RenderView(
            new ShellView(),
            1366,
            768,
            1,
            "ThaiOverviewCheck",
            Path.Combine(overviewEvidenceDirectory, "overview-1366x768.png"));
    }

    private static void RenderWidgetEvidence()
    {
        var repositoryRoot = FindRepositoryRoot();
        var widgetEvidenceDirectory = Path.Combine(
            repositoryRoot,
            "artifacts",
            "design-evidence",
            "v0.1",
            "issue-4");
        Directory.CreateDirectory(widgetEvidenceDirectory);

        foreach (var scale in new[] { 1.0, 1.25, 1.5 })
        {
            var scaleLabel = FormattableString.Invariant($"{scale * 100:0}");
            RenderView(
                new WidgetGalleryView(),
                1536,
                1024,
                scale,
                "ThaiWidgetCheck",
                Path.Combine(widgetEvidenceDirectory, $"widget-gallery-{scaleLabel}.png"));
        }

        RenderView(
            new WidgetGalleryView(),
            1366,
            768,
            1,
            "ThaiWidgetCheck",
            Path.Combine(widgetEvidenceDirectory, "widget-gallery-1366x768.png"));

        var state = SyntheticWidgetState.Create();
        foreach (var descriptor in WidgetCatalog.All)
        {
            var window = new WidgetWindow(descriptor, state);
            var surface = Assert.IsInstanceOfType<WidgetSurface>(window.Content);
            RenderView(
                surface,
                (int)descriptor.WindowWidth,
                (int)descriptor.WindowHeight,
                1,
                clippingTag: null,
                Path.Combine(
                    widgetEvidenceDirectory,
                    $"widget-{descriptor.Variant.ToString().ToLowerInvariant()}.png"));
        }
    }

    private static void RenderView(
        FrameworkElement view,
        int pixelWidth,
        int pixelHeight,
        double scale,
        string? clippingTag,
        string outputPath)
    {
        var logicalSize = new Size(pixelWidth / scale, pixelHeight / scale);
        view.Measure(logicalSize);
        view.Arrange(new Rect(logicalSize));
        view.UpdateLayout();

        if (!string.IsNullOrEmpty(clippingTag))
        {
            AssertThaiTextFits(view, scale, clippingTag);
        }

        if (string.Equals(clippingTag, "ThaiOverviewCheck", StringComparison.Ordinal))
        {
            AssertOverviewRegionsAreLaidOut(view);
        }
        else if (string.Equals(clippingTag, "ThaiWidgetCheck", StringComparison.Ordinal))
        {
            AssertWidgetVariantsAreLaidOut(view);
        }

        var bitmap = new RenderTargetBitmap(
            pixelWidth,
            pixelHeight,
            96 * scale,
            96 * scale,
            PixelFormats.Pbgra32);
        bitmap.Render(view);

        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using var output = File.Create(outputPath);
        encoder.Save(output);

        var minimumEvidenceBytes = pixelWidth * pixelHeight < 100_000
            ? 4_000L
            : 10_000L;
        Assert.IsGreaterThan(
            minimumEvidenceBytes,
            output.Length,
            $"Evidence image was unexpectedly small: {outputPath}");
    }

    private static void AssertThaiTextFits(
        DependencyObject root,
        double pixelsPerDip,
        string clippingTag)
    {
        var taggedTextBlocks = EnumerateDescendants(root)
            .OfType<TextBlock>()
            .Where(textBlock => string.Equals(textBlock.Tag as string, clippingTag, StringComparison.Ordinal))
            .Where(textBlock => textBlock.Visibility == Visibility.Visible && textBlock.ActualWidth > 0)
            .ToArray();

        Assert.IsNotEmpty(
            taggedTextBlocks,
            $"No Thai clipping checkpoints were rendered for tag {clippingTag}.");

        foreach (var textBlock in taggedTextBlocks)
        {
            var formattedText = new FormattedText(
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
                pixelsPerDip);

            if (textBlock.TextWrapping == TextWrapping.NoWrap)
            {
                Assert.IsLessThanOrEqualTo(
                    textBlock.ActualWidth + 3,
                    formattedText.WidthIncludingTrailingWhitespace,
                    $"Thai text clipped at {pixelsPerDip:P0}: {textBlock.Text}");
                continue;
            }

            formattedText.MaxTextWidth = Math.Max(1, textBlock.ActualWidth);
            Assert.IsLessThanOrEqualTo(
                textBlock.ActualHeight + 4,
                formattedText.Height,
                $"Wrapped Thai text clipped at {pixelsPerDip:P0}: {textBlock.Text}");
        }
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

    private static void AssertOverviewRegionsAreLaidOut(DependencyObject root)
    {
        var expectedRegionNames = new[]
        {
            "SummaryCardsRegion",
            "RecentActivityRegion",
            "ScoreTrendRegion",
            "WorkDistributionRegion",
            "TopAgentsRegion",
            "AlertsRegion",
        };
        var regions = EnumerateDescendants(root)
            .OfType<FrameworkElement>()
            .Where(element => expectedRegionNames.Contains(element.Name, StringComparer.Ordinal))
            .ToDictionary(element => element.Name, StringComparer.Ordinal);

        foreach (var regionName in expectedRegionNames)
        {
            Assert.IsTrue(regions.TryGetValue(regionName, out var region), $"Missing Overview region: {regionName}");
            Assert.IsNotNull(region);
            Assert.IsGreaterThan(0d, region.ActualWidth, $"Overview region has no width: {regionName}");
            Assert.IsGreaterThan(0d, region.ActualHeight, $"Overview region has no height: {regionName}");
            Assert.AreEqual(Visibility.Visible, region.Visibility, $"Overview region is hidden: {regionName}");
        }
    }

    private static void AssertWidgetVariantsAreLaidOut(DependencyObject root)
    {
        var expectedPreviewNames = new[]
        {
            "CompactPreview",
            "NormalPreview",
            "ExpandedPreview",
            "MiniPreview",
            "VerticalPreview",
            "NotificationPreview",
            "AgentDetailPreview",
        };
        var previews = EnumerateDescendants(root)
            .OfType<WidgetSurface>()
            .Where(surface => expectedPreviewNames.Contains(surface.Name, StringComparer.Ordinal))
            .ToDictionary(surface => surface.Name, StringComparer.Ordinal);

        foreach (var previewName in expectedPreviewNames)
        {
            Assert.IsTrue(previews.TryGetValue(previewName, out var preview), $"Missing Widget preview: {previewName}");
            Assert.IsNotNull(preview);
            Assert.IsGreaterThan(0d, preview.ActualWidth, $"Widget preview has no width: {previewName}");
            Assert.IsGreaterThan(0d, preview.ActualHeight, $"Widget preview has no height: {previewName}");
            Assert.AreEqual(Visibility.Visible, preview.Visibility, $"Widget preview is hidden: {previewName}");
        }
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
