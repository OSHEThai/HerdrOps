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
    public void ActualWpfShellRendersWithoutThaiClippingAtRequiredScaleFactors()
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
        var evidenceDirectory = Path.Combine(
            repositoryRoot,
            "artifacts",
            "design-evidence",
            "v0.1",
            "issue-2");
        Directory.CreateDirectory(evidenceDirectory);

        foreach (var scale in new[] { 1.0, 1.25, 1.5 })
        {
            var view = new ShellView();
            var logicalSize = new Size(ReferenceWidth / scale, ReferenceHeight / scale);
            view.Measure(logicalSize);
            view.Arrange(new Rect(logicalSize));
            view.UpdateLayout();

            AssertThaiTextFits(view, scale);

            var bitmap = new RenderTargetBitmap(
                ReferenceWidth,
                ReferenceHeight,
                96 * scale,
                96 * scale,
                PixelFormats.Pbgra32);
            bitmap.Render(view);

            var encoder = new PngBitmapEncoder();
            encoder.Frames.Add(BitmapFrame.Create(bitmap));
            var scaleLabel = FormattableString.Invariant($"{scale * 100:0}");
            var outputPath = Path.Combine(evidenceDirectory, $"shell-{scaleLabel}.png");
            using var output = File.Create(outputPath);
            encoder.Save(output);

            Assert.IsGreaterThan(
                10_000L,
                output.Length,
                $"Evidence image was unexpectedly small: {outputPath}");
        }
    }

    private static void AssertThaiTextFits(DependencyObject root, double pixelsPerDip)
    {
        var taggedTextBlocks = EnumerateDescendants(root)
            .OfType<TextBlock>()
            .Where(textBlock => string.Equals(textBlock.Tag as string, "ThaiCheck", StringComparison.Ordinal))
            .ToArray();

        Assert.IsNotEmpty(taggedTextBlocks, "No Thai clipping checkpoints were rendered.");

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
