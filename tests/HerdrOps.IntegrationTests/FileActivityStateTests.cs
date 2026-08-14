using HerdrOps.App.Files;
using HerdrOps.App.Localization;

namespace HerdrOps.IntegrationTests;

[TestClass]
[DoNotParallelize]
public sealed class FileActivityStateTests
{
    [TestMethod]
    public void SyntheticFixtureKeepsSelectionFiltersAndEvidenceBoundarySynchronized()
    {
        var language = UiLanguageService.Shared;
        try
        {
            language.SetLanguage(UiLanguage.English);
            var state = FileActivityState.CreateSyntheticPreview();

            Assert.IsTrue(state.IsSyntheticPreview);
            Assert.HasCount(5, state.SummaryCards);
            Assert.HasCount(10, state.VisibleEvents);
            Assert.IsNotNull(state.SelectedEvent);
            Assert.AreEqual(state.SelectedEvent.EventId, state.SelectedDetail?.EventId);
            StringAssert.Contains(state.ConnectionLabel, "not observed runtime evidence");

            state.SelectedActionFilter = state.ActionFilters.Single(item => item.Id == "blocked");

            Assert.HasCount(1, state.VisibleEvents);
            Assert.AreEqual("[blocked outside repository]", state.VisibleEvents[0].RelativePath);
            Assert.AreEqual("Out of Scope", state.VisibleEvents[0].ScopeLabel);
            Assert.AreEqual("38%", state.SelectedDetail?.Confidence);
        }
        finally
        {
            language.SetLanguage(UiLanguage.Thai);
        }
    }

    [TestMethod]
    public void LanguageRefreshProducesSingleLanguageRowsAndDetails()
    {
        var language = UiLanguageService.Shared;
        try
        {
            language.SetLanguage(UiLanguage.Thai);
            var state = FileActivityState.CreateSyntheticPreview();
            StringAssert.Contains(state.SummaryCards[0].Title, "ไฟล์");
            Assert.IsTrue(state.VisibleEvents.Any(item => item.Agent.Contains("ผู้", StringComparison.Ordinal)));
            state.SelectedEvent = state.VisibleEvents.Single(item => item.EventId == "FILE-010");
            Assert.AreEqual(
                language["FileDiffReadNotRetained"],
                state.SelectedDetail?.DiffLines.Single());

            language.SetLanguage(UiLanguage.English);
            state.RefreshLanguage();

            Assert.AreEqual("Files Read", state.SummaryCards[0].Title);
            Assert.IsFalse(state.VisibleEvents.Any(item => ContainsThai(item.Agent) || ContainsThai(item.Action)));
            Assert.IsFalse(ContainsThai(state.SelectedDetail?.Actor ?? string.Empty));
            Assert.IsFalse(ContainsThai(state.SelectedDetail?.Source ?? string.Empty));
            Assert.AreEqual(
                language["FileDiffReadNotRetained"],
                state.SelectedDetail?.DiffLines.Single());
        }
        finally
        {
            language.SetLanguage(UiLanguage.Thai);
        }
    }

    private static bool ContainsThai(string value) =>
        value.Any(character => character is >= '\u0E00' and <= '\u0E7F');
}
