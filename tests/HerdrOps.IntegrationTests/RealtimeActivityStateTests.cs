using System.Text.RegularExpressions;
using HerdrOps.App.Activity;
using HerdrOps.App.Localization;
using HerdrOps.Contracts;

namespace HerdrOps.IntegrationTests;

[TestClass]
[DoNotParallelize]
public sealed class RealtimeActivityStateTests
{
    [TestInitialize]
    public void UseThaiDefault() => UiLanguageService.Shared.SetLanguage(UiLanguage.Thai);

    [TestCleanup]
    public void RestoreThaiDefault() => UiLanguageService.Shared.SetLanguage(UiLanguage.Thai);

    [TestMethod]
    public void FiveDimensionFiltersProduceTheSameStableResultForTheSameFixture()
    {
        var first = RealtimeActivityState.CreateSyntheticPreview();
        var second = RealtimeActivityState.CreateSyntheticPreview();

        ApplyScopeViolationFilters(first);
        ApplyScopeViolationFilters(second);

        CollectionAssert.AreEqual(
            first.VisibleEvents.Select(item => item.EventId).ToArray(),
            second.VisibleEvents.Select(item => item.EventId).ToArray());
        Assert.HasCount(1, first.VisibleEvents);
        Assert.AreEqual("EVT-007", first.VisibleEvents[0].EventId);
        Assert.AreEqual("TASK-113", first.VisibleEvents[0].TaskId);
        Assert.AreEqual(UiLanguageService.Shared["RealtimeEvidenceObserved"], first.VisibleEvents[0].EvidenceLevel);
    }

    [TestMethod]
    public void SelectedEventDetailAndEvidenceAlwaysReferenceTheSameEvent()
    {
        var state = RealtimeActivityState.CreateSyntheticPreview();
        var violation = state.VisibleEvents.Single(item => item.EventId == "EVT-007");

        state.SelectedEvent = violation;

        Assert.IsNotNull(state.SelectedDetail);
        Assert.AreEqual("EVT-007", state.SelectedDetail.EventId);
        Assert.AreEqual(violation.Title, state.SelectedDetail.Title);
        Assert.AreEqual(violation.EvidenceSources, state.EvidenceSources);
        Assert.HasCount(3, state.EvidenceSources);
        Assert.IsTrue(state.EvidenceSources.Any(item => item.DisplayName == "AuthService.cs"));

        state.SelectedSeverityFilter = state.SeverityFilters.Single(item => item.Id == "info");

        Assert.IsNotNull(state.SelectedEvent);
        Assert.AreNotEqual("EVT-007", state.SelectedEvent.EventId);
        Assert.AreEqual(state.SelectedEvent.EventId, state.SelectedDetail?.EventId);
        Assert.AreEqual(state.SelectedEvent.EvidenceSources, state.EvidenceSources);
    }

    [TestMethod]
    public void PagingIsStableAndNeverExceedsTheDeclaredHistoryBound()
    {
        var state = RealtimeActivityState.CreateSyntheticPreview();
        var firstPage = state.VisibleEvents.Select(item => item.EventId).ToArray();

        Assert.HasCount(RealtimeActivityState.PageSize, firstPage);
        Assert.IsTrue(state.HasMore);
        state.LoadMore();

        Assert.IsLessThanOrEqualTo(RealtimeActivityState.MaximumHistory, state.VisibleEvents.Count);
        Assert.IsGreaterThan(firstPage.Length, state.VisibleEvents.Count);
        CollectionAssert.AreEqual(
            firstPage,
            state.VisibleEvents.Take(firstPage.Length).Select(item => item.EventId).ToArray());
        Assert.HasCount(state.VisibleEvents.Count, state.VisibleEvents.Select(item => item.EventId).Distinct().ToArray());
        Assert.IsFalse(state.HasMore);
    }

    [TestMethod]
    public void LanguageRefreshKeepsFilterIdentityWhileReplacingAllLocalizedPresentation()
    {
        var state = RealtimeActivityState.CreateSyntheticPreview();
        ApplyScopeViolationFilters(state);
        var eventIds = state.VisibleEvents.Select(item => item.EventId).ToArray();
        Assert.IsTrue(Regex.IsMatch(state.VisibleEvents[0].Title, "[ก-๙]", RegexOptions.CultureInvariant));

        UiLanguageService.Shared.SetLanguage(UiLanguage.English);
        state.RefreshLanguage();

        Assert.AreEqual("15m", state.SelectedTimeFilter.Id);
        Assert.AreEqual("worker", state.SelectedRoleFilter.Id);
        Assert.AreEqual("high", state.SelectedSeverityFilter.Id);
        Assert.AreEqual("TASK-113", state.SelectedTaskFilter.Id);
        Assert.AreEqual("observed", state.SelectedEvidenceFilter.Id);
        CollectionAssert.AreEqual(eventIds, state.VisibleEvents.Select(item => item.EventId).ToArray());
        Assert.IsFalse(Regex.IsMatch(state.VisibleEvents[0].Title, "[ก-๙]", RegexOptions.CultureInvariant));
        Assert.IsFalse(Regex.IsMatch(state.VisibleEvents[0].Description, "[ก-๙]", RegexOptions.CultureInvariant));
        Assert.AreEqual("Suspected scope violation", state.VisibleEvents[0].Title);
    }

    [TestMethod]
    public void ProductionStateFailsClosedUntilAnActualActivityStreamIsConnected()
    {
        var state = RealtimeActivityState.CreateUnavailable();

        Assert.AreEqual(EvidenceClass.Contract, state.EvidenceClass);
        Assert.IsFalse(state.IsSyntheticPreview);
        Assert.IsEmpty(state.VisibleEvents);
        Assert.IsNull(state.SelectedEvent);
        Assert.IsNull(state.SelectedDetail);
        Assert.IsEmpty(state.EvidenceSources);
        Assert.AreEqual(UiLanguageService.Shared["RealtimeLiveSourceUnavailable"], state.SourceLabel);
        Assert.AreEqual(UiLanguageService.Shared["RealtimeWaitingForLiveEvents"], state.ConnectionLabel);
        Assert.IsTrue(state.SummaryCards.All(card => card.Value == "0"));
    }

    private static void ApplyScopeViolationFilters(RealtimeActivityState state)
    {
        state.SelectedTimeFilter = state.TimeFilters.Single(item => item.Id == "15m");
        state.SelectedRoleFilter = state.RoleFilters.Single(item => item.Id == "worker");
        state.SelectedSeverityFilter = state.SeverityFilters.Single(item => item.Id == "high");
        state.SelectedTaskFilter = state.TaskFilters.Single(item => item.Id == "TASK-113");
        state.SelectedEvidenceFilter = state.EvidenceFilters.Single(item => item.Id == "observed");
    }
}
