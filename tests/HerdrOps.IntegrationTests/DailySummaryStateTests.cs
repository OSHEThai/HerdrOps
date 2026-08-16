using System.Text.RegularExpressions;
using HerdrOps.App.Localization;
using HerdrOps.App.Summaries;
using HerdrOps.Contracts;

namespace HerdrOps.IntegrationTests;

[TestClass]
public sealed class DailySummaryStateTests
{
    [TestInitialize]
    public void SetUp() => UiLanguageService.Shared.SetLanguage(UiLanguage.Thai);

    [TestCleanup]
    public void TearDown() => UiLanguageService.Shared.SetLanguage(UiLanguage.Thai);

    [TestMethod]
    public void SyntheticProjectionUsesTheCommittedAggregateAndKeepsSourceLinks()
    {
        var state = DailySummaryState.CreateSyntheticPreview();
        var snapshot = state.Snapshot;

        Assert.AreEqual(EvidenceClass.Synthetic, state.EvidenceClass);
        Assert.IsTrue(state.IsSyntheticPreview);
        Assert.IsNotNull(snapshot);
        Assert.HasCount(5, snapshot!.AcceptedSources);
        Assert.HasCount(3, snapshot.Workstreams);
        Assert.HasCount(5, state.SummaryCards);
        Assert.HasCount(2, state.Highlights);
        Assert.HasCount(1, state.RepeatedIssues);
        Assert.HasCount(2, state.RecommendedActions);
        Assert.HasCount(5, state.Timeline);
        Assert.IsTrue(state.SummaryCards.All(card => card.SourceIds.All(
            sourceId => snapshot.AcceptedSources.Any(source => source.SourceId == sourceId))));
        Assert.IsTrue(state.Highlights.All(item => item.SourceIds.Count > 0));
        Assert.IsTrue(state.RepeatedIssues.All(item => item.SourceIds.Count > 0));
        Assert.IsTrue(state.RecommendedActions.All(item => item.SourceIds.Count > 0));
        Assert.AreEqual("—", state.DailyScoreLabel);
        Assert.AreEqual(UiLanguageService.Shared["DailySummaryNoScore"], state.DailyScoreDetail);
    }

    [TestMethod]
    public void LanguageRefreshKeepsTheSameAggregateAndUsesOneLanguageAtATime()
    {
        var state = DailySummaryState.CreateSyntheticPreview();
        var resultHash = state.Snapshot!.ResultSha256;

        UiLanguageService.Shared.SetLanguage(UiLanguage.English);
        state.RefreshLanguage();
        Assert.AreEqual(resultHash, state.Snapshot!.ResultSha256);
        Assert.AreEqual("Daily Summary", UiLanguageService.Shared["DailySummaryPageTitle"]);
        Assert.IsTrue(state.SummaryCards.All(card => !ContainsThai(card.Title + card.Detail)));
        Assert.IsTrue(state.Highlights.All(item => !ContainsThai(item.Summary)));
        Assert.IsTrue(state.RecommendedActions.All(item => !ContainsThai(item.Description)));

        UiLanguageService.Shared.SetLanguage(UiLanguage.Thai);
        state.RefreshLanguage();
        Assert.AreEqual("สรุปรายวัน", UiLanguageService.Shared["DailySummaryPageTitle"]);
        Assert.IsTrue(state.SummaryCards.All(card => ContainsThai(card.Title + card.Detail)));
        Assert.IsTrue(state.Highlights.All(item => ContainsThai(item.Summary)));
        Assert.IsTrue(state.RecommendedActions.All(item => ContainsThai(item.Description)));
    }

    [TestMethod]
    public void UnavailableProjectionFailsClosedWithExplicitMissingValues()
    {
        var state = DailySummaryState.CreateUnavailable();

        Assert.AreEqual(EvidenceClass.Contract, state.EvidenceClass);
        Assert.IsFalse(state.IsSyntheticPreview);
        Assert.IsNull(state.Snapshot);
        Assert.HasCount(5, state.SummaryCards);
        Assert.IsTrue(state.SummaryCards.All(card => card.Value == "—"));
        Assert.IsEmpty(state.Highlights);
        Assert.IsEmpty(state.Workstreams);
        StringAssert.Contains(state.BoundaryLabel, "สแนปช็อต");
    }

    private static bool ContainsThai(string value) =>
        Regex.IsMatch(value, "[ก-๙]", RegexOptions.CultureInvariant);
}
