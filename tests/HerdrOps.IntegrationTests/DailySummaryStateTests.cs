using System.Text.RegularExpressions;
using HerdrOps.App.Localization;
using HerdrOps.App.Summaries;
using HerdrOps.Contracts;
using HerdrOps.Domain.Summaries;

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
    public void SyntheticProjectionResolvesAcceptedSourceReferencesForEveryRow()
    {
        var state = DailySummaryState.CreateSyntheticPreview();
        var snapshot = state.Snapshot!;
        var accepted = snapshot.AcceptedSources.ToDictionary(
            item => item.SourceId,
            StringComparer.Ordinal);

        var missingTest = state.AreasToImprove.Single(item => item.Id == "area-missing-test");
        CollectionAssert.AreEqual(new[] { "activity-003" }, missingTest.SourceIds.ToArray());

        var rows = state.SummaryCards.Select(item => (item.SourceIds, item.SourceReferences))
            .Concat(state.Highlights.Select(item => (item.SourceIds, item.SourceReferences)))
            .Concat(state.Strengths.Select(item => (item.SourceIds, item.SourceReferences)))
            .Concat(state.AreasToImprove.Select(item => (item.SourceIds, item.SourceReferences)))
            .Concat(state.RepeatedIssues.Select(item => (item.SourceIds, item.SourceReferences)))
            .Concat(state.RecommendedActions.Select(item => (item.SourceIds, item.SourceReferences)))
            .Concat(state.Timeline.Select(item => (item.SourceIds, item.SourceReferences)))
            .Concat(state.Workstreams.Select(item => (item.SourceIds, item.SourceReferences)))
            .ToArray();

        foreach (var row in rows)
        {
            CollectionAssert.AreEqual(
                row.SourceIds.ToArray(),
                row.SourceReferences.Select(item => item.SourceId).ToArray());
            Assert.IsNotEmpty(row.SourceReferences);
            foreach (var reference in row.SourceReferences)
            {
                Assert.IsTrue(accepted.TryGetValue(reference.SourceId, out var acceptedReference));
                Assert.AreEqual(acceptedReference!.Kind, reference.Kind);
                Assert.AreEqual(acceptedReference.SourceHashSha256, reference.SourceHashSha256);
            }
        }

        var activity003 = accepted["activity-003"];
        StringAssert.Contains(
            missingTest.SourceProvenanceLabel,
            $"{activity003.SourceId}#{activity003.SourceHashSha256}");
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
        Assert.IsTrue(state.AreasToImprove.All(item => !ContainsThai(item.SourceLabel + item.SourceProvenanceLabel)));

        UiLanguageService.Shared.SetLanguage(UiLanguage.Thai);
        state.RefreshLanguage();
        Assert.AreEqual("สรุปรายวัน", UiLanguageService.Shared["DailySummaryPageTitle"]);
        Assert.IsTrue(state.SummaryCards.All(card => ContainsThai(card.Title + card.Detail)));
        Assert.IsTrue(state.Highlights.All(item => ContainsThai(item.Summary)));
        Assert.IsTrue(state.RecommendedActions.All(item => ContainsThai(item.Description)));
        Assert.IsTrue(state.AreasToImprove.All(item => ContainsThai(item.SourceLabel)));
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
        Assert.IsTrue(state.SummaryCards.All(card => card.SourceReferences.Count == 0));
        Assert.IsTrue(state.SummaryCards.All(card =>
            card.SourceProvenanceLabel == UiLanguageService.Shared["DailySummaryNoRecords"]));
        Assert.IsEmpty(state.Highlights);
        Assert.IsEmpty(state.Workstreams);
        StringAssert.Contains(state.BoundaryLabel, "สแนปช็อต");
    }

    private static bool ContainsThai(string value) =>
        Regex.IsMatch(value, "[ก-๙]", RegexOptions.CultureInvariant);
}
