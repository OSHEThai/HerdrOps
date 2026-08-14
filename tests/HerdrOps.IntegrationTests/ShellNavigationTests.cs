using System.Windows.Input;
using HerdrOps.App.Shell;

namespace HerdrOps.IntegrationTests;

[TestClass]
public sealed class ShellNavigationTests
{
    [TestMethod]
    public void CatalogRegistersEveryCanonicalDestinationInApprovedOrder()
    {
        var actualIds = ShellNavigationCatalog.All
            .Select(destination => destination.Id)
            .ToArray();

        CollectionAssert.AreEqual(
            new[]
            {
                "overview",
                "live-organization",
                "realtime-activity",
                "delegation-graph",
                "agent-detail",
                "task-alignment",
                "file-activity",
                "compliance-queue",
                "evaluation",
                "daily-summary",
            },
            actualIds);

        Assert.IsTrue(ShellNavigationCatalog.All.All(destination =>
            !string.IsNullOrWhiteSpace(destination.EnglishName) &&
            !string.IsNullOrWhiteSpace(destination.ThaiName) &&
            !string.IsNullOrWhiteSpace(destination.IconGlyph)));
    }

    [TestMethod]
    public void KeyboardShortcutsTraverseAndWrapTheCanonicalDestinations()
    {
        var navigation = new ShellNavigationController();

        Assert.IsTrue(navigation.TryHandleKey(Key.PageDown, ModifierKeys.Control));
        Assert.AreEqual("live-organization", navigation.SelectedDestination.Id);

        navigation.SelectedIndex = navigation.Destinations.Count - 1;
        Assert.IsTrue(navigation.TryHandleKey(Key.PageDown, ModifierKeys.Control));
        Assert.AreEqual("overview", navigation.SelectedDestination.Id);

        Assert.IsTrue(navigation.TryHandleKey(Key.PageUp, ModifierKeys.Control));
        Assert.AreEqual("daily-summary", navigation.SelectedDestination.Id);

        Assert.IsTrue(navigation.TryHandleKey(Key.Home, ModifierKeys.Alt));
        Assert.AreEqual("overview", navigation.SelectedDestination.Id);

        Assert.IsTrue(navigation.TryHandleKey(Key.End, ModifierKeys.Alt));
        Assert.AreEqual("daily-summary", navigation.SelectedDestination.Id);

        Assert.IsFalse(navigation.TryHandleKey(Key.Enter, ModifierKeys.None));
    }
}
