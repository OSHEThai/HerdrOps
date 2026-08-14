using System.Globalization;
using System.IO;
using System.Threading;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using HerdrOps.App.Views;

namespace HerdrOps.RuntimeTests;

[TestClass]
public sealed class ShellRenderingTests
{
    private const int ReferenceWidth = 1672;
    private const int ReferenceHeight = 941;

    [TestMethod]
    public void ActualWpfShellAndOverviewRenderWithoutThaiClippingAtRequiredSizes()
    {
        Exception? renderingFailure = null;
        var renderingThread = new Thread(() =>
        {
            try
            {
                RenderEvidence();
            }
            catch (Exception exception)
            {
                renderingFailure = exception;
            }
        });

        renderingThread.SetApartmentState(ApartmentState.STA);
        renderingThread.Start();

        Assert.IsTrue(
            renderingThread.Join(TimeSpan.FromSeconds(30)),
            "WPF evidence rendering exceeded 30 seconds.");
        if (renderingFailure is not null)
        {
            Assert.Fail(renderingFailure.ToString());
        }
    }

    private static void RenderEvidence()
    {
        var application = new HerdrOps.App.App();
        application.InitializeComponent();

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

    private static void RenderView(
        FrameworkElement view,
        int pixelWidth,
        int pixelHeight,
        double scale,
        string clippingTag,
        string outputPath)
    {
        var logicalSize = new Size(pixelWidth / scale, pixelHeight / scale);
        view.Measure(logicalSize);
        view.Arrange(new Rect(logicalSize));
        view.UpdateLayout();

        AssertThaiTextFits(view, scale, clippingTag);
        if (string.Equals(clippingTag, "ThaiOverviewCheck", StringComparison.Ordinal))
        {
            AssertOverviewRegionsAreLaidOut(view);
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

        Assert.IsGreaterThan(
            10_000L,
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
