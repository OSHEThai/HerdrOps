using HerdrOps.App.Widgets;
using HerdrOps.Contracts;

namespace HerdrOps.IntegrationTests;

[TestClass]
public sealed class SyntheticWidgetStateTests
{
    [TestMethod]
    public void WidgetCatalogContainsEveryApprovedVariantExactlyOnce()
    {
        var expected = Enum.GetValues<WidgetVariant>();

        Assert.HasCount(expected.Length, WidgetCatalog.All);
        CollectionAssert.AreEquivalent(
            expected,
            WidgetCatalog.All.Select(descriptor => descriptor.Variant).ToArray());
        Assert.IsTrue(WidgetCatalog.All.All(descriptor => descriptor.WindowWidth > 0));
        Assert.IsTrue(WidgetCatalog.All.All(descriptor => descriptor.WindowHeight > 0));
    }

    [TestMethod]
    public void SharedWidgetStateIsDeterministicAndExplicitlySynthetic()
    {
        var first = SyntheticWidgetState.Create();
        var second = SyntheticWidgetState.Create();

        Assert.AreEqual(EvidenceClass.Synthetic, first.EvidenceClass);
        Assert.AreEqual("SYNTHETIC DATA", first.SourceLabel);
        Assert.AreEqual("Herdr not connected", first.ConnectionLabel);
        Assert.AreEqual(first.SnapshotAt, second.SnapshotAt);
        Assert.AreEqual(first.DailyScore, second.DailyScore);
        CollectionAssert.AreEqual(first.Agents.ToArray(), second.Agents.ToArray());
        CollectionAssert.AreEqual(first.Notices.ToArray(), second.Notices.ToArray());
    }

    [TestMethod]
    public void WidgetSummaryTotalsAreInternallyConsistent()
    {
        var state = SyntheticWidgetState.Create();

        Assert.AreEqual(
            state.TotalAgents,
            state.WorkingCount + state.BlockedCount + state.DoneCount);
        Assert.HasCount(2, state.PriorityNotices);
        Assert.IsTrue(state.Agents.All(agent => agent.StatusBrushKey.StartsWith("HerdrOps.Brush.Status.", StringComparison.Ordinal)));
    }

    [TestMethod]
    public void WindowBoundsKeepEveryEdgeInsideTheWorkArea()
    {
        var workArea = new System.Windows.Rect(100, 80, 800, 600);
        var windowSize = new System.Windows.Size(230, 220);

        var upperLeft = WidgetWindowBounds.Clamp(
            new System.Windows.Point(-500, -600),
            windowSize,
            workArea);
        var lowerRight = WidgetWindowBounds.Clamp(
            new System.Windows.Point(5000, 6000),
            windowSize,
            workArea);

        Assert.AreEqual(new System.Windows.Point(100, 80), upperLeft);
        Assert.AreEqual(new System.Windows.Point(670, 460), lowerRight);
    }
}
