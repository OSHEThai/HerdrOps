using System.Globalization;
using System.IO;
using System.Security.Cryptography;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using HerdrOps.App.Views;
using HerdrOps.App.Localization;
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
        UiLanguageService.Shared.SetLanguage(UiLanguage.Thai);
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
            var view = ShellView.CreateSyntheticPreview();
            Assert.AreEqual(
                UiLanguageService.Shared["RealtimeActorProjectManager"],
                view.LiveDashboard.AgentDetail.Name);
            Assert.AreEqual(UiLanguageService.Shared["SyntheticProfile"], view.LiveDashboard.AgentDetail.Runtime);
            Assert.AreEqual(UiLanguageService.Shared["PreviewStatus"], view.LiveDashboard.AgentDetail.Status);
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
                ShellView.CreateSyntheticPreview(),
                ReferenceWidth,
                ReferenceHeight,
                scale,
                "ThaiOverviewCheck",
                Path.Combine(overviewEvidenceDirectory, $"overview-{scaleLabel}.png"));
        }

        RenderView(
            ShellView.CreateSyntheticPreview(),
            1366,
            768,
            1,
            "ThaiOverviewCheck",
            Path.Combine(overviewEvidenceDirectory, "overview-1366x768.png"));
    }

    private static void RenderWidgetEvidence()
    {
        UiLanguageService.Shared.SetLanguage(UiLanguage.Thai);
        var repositoryRoot = FindRepositoryRoot();
        var widgetEvidenceDirectory = Path.Combine(
            repositoryRoot,
            "artifacts",
            "design-evidence",
            "v0.1",
            "issue-4");
        Directory.CreateDirectory(widgetEvidenceDirectory);

        var galleryEvidence = new Dictionary<double, string>();
        foreach (var scale in new[] { 1.0, 1.25, 1.5 })
        {
            var scaleLabel = FormattableString.Invariant($"{scale * 100:0}");
            var outputPath = Path.Combine(widgetEvidenceDirectory, $"widget-gallery-{scaleLabel}.png");
            RenderView(
                new WidgetGalleryView(),
                1536,
                1024,
                scale,
                "ThaiWidgetCheck",
                outputPath);
            galleryEvidence.Add(scale, outputPath);
        }

        Assert.AreNotEqual(
            GetDecodedPixelHash(galleryEvidence[1.0]),
            GetDecodedPixelHash(galleryEvidence[1.25]),
            "125% Gallery evidence must exercise an adaptive layout, not only different PNG DPI metadata.");
        Assert.AreNotEqual(
            GetDecodedPixelHash(galleryEvidence[1.0]),
            GetDecodedPixelHash(galleryEvidence[1.5]),
            "150% Gallery evidence must exercise an adaptive layout, not only different PNG DPI metadata.");

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

        if (view is WidgetGalleryView)
        {
            // The gallery selects its responsive tree from SizeChanged, which is raised
            // during the first arrange. Give the newly visible tree a deterministic
            // measure/arrange pass before inspecting or rendering its item templates.
            view.InvalidateMeasure();
            view.Measure(logicalSize);
            view.Arrange(new Rect(logicalSize));
            view.UpdateLayout();
        }

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
        var previews = EnumerateDescendants(root)
            .OfType<WidgetSurface>()
            .Where(surface => surface.ActualWidth > 0 && surface.ActualHeight > 0)
            .Where(IsEffectivelyVisible)
            .ToArray();

        foreach (var variant in Enum.GetValues<WidgetVariant>())
        {
            Assert.IsTrue(
                previews.Any(preview => preview.Variant == variant),
                $"Missing visible Widget preview: {variant}");
        }

        var visibleLaunchActions = EnumerateDescendants(root)
            .OfType<Button>()
            .Where(button => button.ActualWidth > 0 && button.ActualHeight >= 40)
            .Where(IsEffectivelyVisible)
            .Where(button =>
                string.Equals(button.Tag?.ToString(), "Dashboard", StringComparison.Ordinal) ||
                Enum.TryParse<WidgetVariant>(button.Tag?.ToString(), out _))
            .ToArray();
        Assert.HasCount(8, visibleLaunchActions, "Every responsive layout must retain seven Widget actions plus Dashboard.");
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

    private static string GetDecodedPixelHash(string path)
    {
        using var input = File.OpenRead(path);
        var decoder = new PngBitmapDecoder(
            input,
            BitmapCreateOptions.PreservePixelFormat,
            BitmapCacheOption.OnLoad);
        var converted = new FormatConvertedBitmap(
            decoder.Frames[0],
            PixelFormats.Bgra32,
            destinationPalette: null,
            alphaThreshold: 0);
        var stride = converted.PixelWidth * 4;
        var pixels = new byte[stride * converted.PixelHeight];
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
