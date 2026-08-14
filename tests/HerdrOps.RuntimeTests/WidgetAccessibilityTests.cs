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
