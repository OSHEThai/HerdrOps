using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;
using HerdrOps.App.Widgets;

namespace HerdrOps.RuntimeTests;

[TestClass]
public sealed class WidgetAccessibilityTests
{
    [TestMethod]
    public void WidgetGalleryExposesKeyboardFocusAndAccessibleOpenActions()
    {
        WpfTestHost.Run(() =>
        {
            var launcher = new RecordingLauncher();
            var gallery = new WidgetGalleryView(SyntheticWidgetState.Create(), launcher);
            gallery.Measure(new Size(1536, 1024));
            gallery.Arrange(new Rect(0, 0, 1536, 1024));
            gallery.UpdateLayout();

            var openButtons = EnumerateDescendants(gallery)
                .OfType<Button>()
                .Where(button => button.Tag is string value && Enum.TryParse<WidgetVariant>(value, out _))
                .Where(IsEffectivelyVisible)
                .ToArray();

            Assert.HasCount(WidgetCatalog.All.Count, openButtons);
            foreach (var button in openButtons)
            {
                Assert.IsTrue(button.Focusable, $"Open action is not keyboard focusable: {button.Tag}");
                Assert.IsTrue(button.IsTabStop, $"Open action is not in the tab order: {button.Tag}");
                Assert.IsGreaterThanOrEqualTo(40d, button.ActualHeight, $"Open action is too short: {button.Tag}");
                Assert.IsFalse(
                    string.IsNullOrWhiteSpace(AutomationProperties.GetName(button)),
                    $"Open action lacks an accessible name: {button.Tag}");

                button.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            }

            CollectionAssert.AreEquivalent(
                Enum.GetValues<WidgetVariant>(),
                launcher.Opened.ToArray());
        });
    }

    [TestMethod]
    public void SemanticTextContrastMeetsWcagAa()
    {
        WpfTestHost.Run(() =>
        {
            var surface = GetColor("HerdrOps.Color.Navy.850");
            Assert.IsGreaterThanOrEqualTo(4.5, ContrastRatio(GetColor("HerdrOps.Color.White.100"), surface));
            Assert.IsGreaterThanOrEqualTo(4.5, ContrastRatio(GetColor("HerdrOps.Color.Slate.300"), surface));
            Assert.IsGreaterThanOrEqualTo(4.5, ContrastRatio(GetColor("HerdrOps.Color.Blue.400"), surface));
        });
    }

    [TestMethod]
    public void ReducedMotionDisablesWidgetTransitions()
    {
        var explicitReducedMotion = WidgetMotionPolicy.Create(
            reducedMotionRequested: true,
            systemAnimationsEnabled: true);
        var systemReducedMotion = WidgetMotionPolicy.Create(
            reducedMotionRequested: false,
            systemAnimationsEnabled: false);
        var standardMotion = WidgetMotionPolicy.Create(
            reducedMotionRequested: false,
            systemAnimationsEnabled: true);

        Assert.IsTrue(explicitReducedMotion.ReducedMotion);
        Assert.AreEqual(TimeSpan.Zero, explicitReducedMotion.TransitionDuration);
        Assert.IsTrue(systemReducedMotion.ReducedMotion);
        Assert.AreEqual(TimeSpan.Zero, systemReducedMotion.TransitionDuration);
        Assert.IsFalse(standardMotion.ReducedMotion);
        Assert.IsLessThanOrEqualTo(TimeSpan.FromMilliseconds(150), standardMotion.TransitionDuration);
    }

    [TestMethod]
    public void WidgetWindowsUseBoundedAndReversibleBehavior()
    {
        WpfTestHost.Run(() =>
        {
            var state = SyntheticWidgetState.Create();
            var workArea = new Rect(100, 80, 800, 600);

            foreach (var descriptor in WidgetCatalog.All)
            {
                var window = new WidgetWindow(descriptor, state);
                Assert.AreEqual(WindowStyle.None, window.WindowStyle);
                Assert.AreEqual(ResizeMode.NoResize, window.ResizeMode);
                Assert.AreEqual(descriptor.DefaultTopmost, window.Topmost);
                Assert.AreEqual(descriptor.ShowInTaskbar, window.ShowInTaskbar);
                Assert.IsTrue(window.IsDragEnabled);
                StringAssert.Contains(window.Title, "Synthetic Preview");

                var initialTopmost = window.Topmost;
                window.ToggleTopmost();
                Assert.AreNotEqual(initialTopmost, window.Topmost);
                window.ToggleTopmost();
                Assert.AreEqual(initialTopmost, window.Topmost);

                var constrained = window.ConstrainTo(
                    workArea,
                    new Point(-1000, 5000));
                Assert.IsGreaterThanOrEqualTo(workArea.Left, constrained.X);
                Assert.IsGreaterThanOrEqualTo(workArea.Top, constrained.Y);
                Assert.IsLessThanOrEqualTo(workArea.Right, constrained.X + window.Width);
                Assert.IsLessThanOrEqualTo(workArea.Bottom, constrained.Y + window.Height);
            }
        });
    }

    [TestMethod]
    public void CriticalWidgetFidelityActionsRemainVisible()
    {
        WpfTestHost.Run(() =>
        {
            var state = SyntheticWidgetState.Create();
            var vertical = new WidgetSurface(state)
            {
                Width = WidgetCatalog.Get(WidgetVariant.FloatingVertical).WindowWidth,
                Height = WidgetCatalog.Get(WidgetVariant.FloatingVertical).WindowHeight,
                Variant = WidgetVariant.FloatingVertical,
                IsInteractive = true,
            };
            Layout(vertical, vertical.Width, vertical.Height);
            var sourceLabel = EnumerateDescendants(vertical)
                .OfType<TextBlock>()
                .Single(text => string.Equals(text.Text, "SYN", StringComparison.Ordinal));
            Assert.IsGreaterThan(0d, sourceLabel.ActualWidth, "Floating Vertical must visibly render its Synthetic source label.");
            Assert.IsTrue(IsEffectivelyVisible(sourceLabel));
            var pinButton = EnumerateDescendants(vertical)
                .OfType<Button>()
                .Single(button => string.Equals(
                    AutomationProperties.GetName(button),
                    "ปักหมุดหรือยกเลิก Always on top",
                    StringComparison.Ordinal));
            var sourceRight = sourceLabel.TranslatePoint(
                new Point(sourceLabel.ActualWidth, 0),
                vertical).X;
            var pinLeft = pinButton.TranslatePoint(new Point(0, 0), vertical).X;
            Assert.IsLessThanOrEqualTo(
                pinLeft - 4,
                sourceRight,
                "Floating Vertical must preserve visible clearance between SYN and the pin control.");

            var detail = new WidgetSurface(state)
            {
                Width = WidgetCatalog.Get(WidgetVariant.AgentDetailPopup).WindowWidth,
                Height = WidgetCatalog.Get(WidgetVariant.AgentDetailPopup).WindowHeight,
                Variant = WidgetVariant.AgentDetailPopup,
                IsInteractive = true,
            };
            Layout(detail, detail.Width, detail.Height);
            var detailAction = EnumerateDescendants(detail)
                .OfType<Button>()
                .Single(button => string.Equals(button.Content?.ToString(), "ดูรายละเอียดทั้งหมด", StringComparison.Ordinal));
            Assert.IsGreaterThanOrEqualTo(40d, detailAction.ActualHeight);
            Assert.IsTrue(IsEffectivelyVisible(detailAction));

            var intermediateGallery = new WidgetGalleryView(state, new RecordingLauncher());
            Layout(intermediateGallery, 1500, 920);
            Assert.IsTrue(
                intermediateGallery.IsAdaptiveLayout,
                "Widths below the 1536-pixel fixed board must use the adaptive layout.");
            var intermediateActions = EnumerateDescendants(intermediateGallery)
                .OfType<Button>()
                .Where(IsEffectivelyVisible)
                .Where(button =>
                    string.Equals(button.Tag?.ToString(), "Dashboard", StringComparison.Ordinal) ||
                    Enum.TryParse<WidgetVariant>(button.Tag?.ToString(), out _))
                .ToArray();
            Assert.HasCount(8, intermediateActions);
        });
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

    private static Color GetColor(string key) =>
        Assert.IsInstanceOfType<Color>(Application.Current.FindResource(key));

    private static double ContrastRatio(Color first, Color second)
    {
        var lighter = Math.Max(RelativeLuminance(first), RelativeLuminance(second));
        var darker = Math.Min(RelativeLuminance(first), RelativeLuminance(second));
        return (lighter + 0.05) / (darker + 0.05);
    }

    private static double RelativeLuminance(Color color)
    {
        static double Convert(byte component)
        {
            var value = component / 255d;
            return value <= 0.04045
                ? value / 12.92
                : Math.Pow((value + 0.055) / 1.055, 2.4);
        }

        return (0.2126 * Convert(color.R)) +
               (0.7152 * Convert(color.G)) +
               (0.0722 * Convert(color.B));
    }

    private sealed class RecordingLauncher : IWidgetWindowLauncher
    {
        public List<WidgetVariant> Opened { get; } = [];

        public void Open(WidgetVariant variant) => Opened.Add(variant);
    }
}
