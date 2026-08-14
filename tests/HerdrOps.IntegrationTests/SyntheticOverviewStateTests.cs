using HerdrOps.App.Overview;
using HerdrOps.App.Localization;
using HerdrOps.Contracts;

namespace HerdrOps.IntegrationTests;

[TestClass]
public sealed class SyntheticOverviewStateTests
{
    [TestMethod]
    public void OverviewFixtureIsDeterministicAndExplicitlySynthetic()
    {
        var first = SyntheticOverviewState.Create();
        var second = SyntheticOverviewState.Create();

        Assert.AreEqual(EvidenceClass.Synthetic, first.EvidenceClass);
        Assert.AreEqual(UiLanguageService.Shared["SyntheticData"], first.SourceLabel);
        Assert.AreEqual(UiLanguageService.Shared["HerdrNotConnected"], first.ConnectionLabel);
        Assert.AreEqual(
            new DateTimeOffset(2026, 8, 14, 14, 32, 0, TimeSpan.FromHours(7)),
            first.SnapshotTimestamp);

        CollectionAssert.AreEqual(
            first.SummaryCards.Select(CreateSummarySnapshot).ToArray(),
            second.SummaryCards.Select(CreateSummarySnapshot).ToArray());
        CollectionAssert.AreEqual(first.RecentActivities.ToArray(), second.RecentActivities.ToArray());
        CollectionAssert.AreEqual(first.ScoreTrend.ToArray(), second.ScoreTrend.ToArray());
        CollectionAssert.AreEqual(first.Workstreams.ToArray(), second.Workstreams.ToArray());
        CollectionAssert.AreEqual(first.TopAgents.ToArray(), second.TopAgents.ToArray());
        CollectionAssert.AreEqual(first.Alerts.ToArray(), second.Alerts.ToArray());

        Assert.HasCount(5, first.SummaryCards);
        Assert.HasCount(6, first.RecentActivities);
        Assert.HasCount(7, first.ScoreTrend);
        Assert.HasCount(5, first.Workstreams);
        Assert.HasCount(5, first.TopAgents);
        Assert.HasCount(3, first.Alerts);
    }

    [TestMethod]
    public void OverviewPercentagesAndAgentCountsRemainInternallyConsistent()
    {
        var state = SyntheticOverviewState.Create();

        Assert.AreEqual(100d, state.Workstreams.Sum(workstream => workstream.Percentage));
        Assert.AreEqual(12, state.Workstreams.Sum(workstream => workstream.Count));
        Assert.AreEqual(86d, state.ScoreTrend[^1].Score);
        Assert.IsTrue(state.Alerts.All(alert => !string.IsNullOrWhiteSpace(alert.State)));
    }

    private static string CreateSummarySnapshot(OverviewSummaryCard card)
    {
        return string.Join(
            "|",
            card.Id,
            card.Title,
            card.Value,
            card.Metric,
            card.Trend,
            card.IconGlyph,
            card.AccentBrushKey,
            string.Join(",", card.SparklineValues),
            card.IsGauge,
            card.GaugeValue);
    }
}
