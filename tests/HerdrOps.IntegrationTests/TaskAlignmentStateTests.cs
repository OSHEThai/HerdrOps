using System.Text.RegularExpressions;
using HerdrOps.App.Alignment;
using HerdrOps.App.Live;
using HerdrOps.App.Localization;

namespace HerdrOps.IntegrationTests;

[TestClass]
[DoNotParallelize]
public sealed class TaskAlignmentStateTests
{
    [TestInitialize]
    public void UseThaiDefault() => UiLanguageService.Shared.SetLanguage(UiLanguage.Thai);

    [TestCleanup]
    public void RestoreThaiDefault() => UiLanguageService.Shared.SetLanguage(UiLanguage.Thai);

    [TestMethod]
    public void SyntheticProjectionUsesAnalyzerResultsAndPopulatesAllReferencePanels()
    {
        var state = TaskAlignmentState.CreateSyntheticPreview();

        Assert.IsTrue(state.HasAnalysis);
        Assert.AreEqual("TASK-120", state.Header.TaskId);
        Assert.AreEqual("76/100", state.Header.GoalScore);
        Assert.AreEqual("88/100", state.Header.ScopeScore);
        Assert.AreEqual("40/100", state.Header.AcceptanceScore);
        Assert.AreEqual(
            UiLanguageService.Shared["AlignmentVerdictPartial"],
            state.Header.Verdict);
        Assert.HasCount(6, state.ContractItems);
        Assert.HasCount(1, state.AcknowledgementItems);
        Assert.HasCount(6, state.PlannedSteps);
        Assert.HasCount(5, state.AcceptanceCriteria);
        Assert.HasCount(4, state.FilesTouched);
        Assert.HasCount(5, state.ObservedActions);
        Assert.HasCount(1, state.DeviationRequests);
        Assert.HasCount(2, state.EvidenceItems);
        Assert.IsTrue(state.FilesTouched.Any(item =>
            item.Status == UiLanguageService.Shared["AlignmentFindingScopePendingDeviation"]));
        Assert.IsFalse(state.FilesTouched.Any(item =>
            item.Status == UiLanguageService.Shared["AlignmentFindingScopeSuspectedViolation"]));
        Assert.IsTrue(AllItems(state).All(item =>
            !string.IsNullOrWhiteSpace(item.Provenance) &&
            !string.IsNullOrWhiteSpace(item.StatusBrushKey)));
    }

    [TestMethod]
    public void LanguageRefreshRebuildsAllSyntheticCopyWithoutRetainingThaiText()
    {
        var state = TaskAlignmentState.CreateSyntheticPreview();
        var itemIds = AllItems(state).Select(item => item.ItemId).ToArray();
        Assert.IsTrue(ContainsThai(state.Header.Goal + state.Header.Verdict));

        UiLanguageService.Shared.SetLanguage(UiLanguage.English);
        state.RefreshLanguage();

        CollectionAssert.AreEqual(itemIds, AllItems(state).Select(item => item.ItemId).ToArray());
        Assert.AreEqual("Deterministic analysis fixture", state.SourceLabel);
        Assert.AreEqual("Partially Misaligned", state.Header.Verdict);
        Assert.IsTrue(LocalizedCopy(state).All(value => !ContainsThai(value)),
            $"English Task Alignment retained Thai copy: {string.Join(" | ", LocalizedCopy(state).Where(ContainsThai))}");
    }

    [TestMethod]
    public void ProductionDashboardFailsClosedUntilAllAdmittedAnalysisInputsExist()
    {
        var dashboard = new LiveDashboardState();
        var state = dashboard.TaskAlignment;

        Assert.IsFalse(state.HasAnalysis);
        Assert.AreEqual(UiLanguageService.Shared["AlignmentWaitingSource"], state.SourceLabel);
        Assert.AreEqual(
            UiLanguageService.Shared["AlignmentUnavailableBoundary"],
            state.EvidenceBoundary);
        Assert.IsEmpty(state.ContractItems);
        Assert.IsEmpty(state.PlannedSteps);
        Assert.IsEmpty(state.FilesTouched);
        Assert.IsEmpty(state.EvidenceItems);
        Assert.AreEqual("—/100", state.Header.GoalScore);
        Assert.AreEqual(
            UiLanguageService.Shared["AlignmentVerdictInsufficient"],
            state.Header.Verdict);
    }

    private static IReadOnlyList<TaskAlignmentPanelItem> AllItems(TaskAlignmentState state) =>
        state.ContractItems
            .Concat(state.AcknowledgementItems)
            .Concat(state.PlannedSteps)
            .Concat(state.AcceptanceCriteria)
            .Concat(state.FilesTouched)
            .Concat(state.ObservedActions)
            .Concat(state.DeviationRequests)
            .Concat(state.EvidenceItems)
            .ToArray();

    private static IEnumerable<string> LocalizedCopy(TaskAlignmentState state)
    {
        yield return state.SourceLabel;
        yield return state.EvidenceBoundary;
        yield return state.Header.Goal;
        yield return state.Header.AssigneeName;
        yield return state.Header.Verdict;
        yield return state.Header.VerdictDetail;
        foreach (var item in AllItems(state))
        {
            yield return item.Title;
            yield return item.Detail;
            yield return item.Status;
        }
    }

    private static bool ContainsThai(string value) =>
        Regex.IsMatch(value, "[ก-๙]", RegexOptions.CultureInvariant);
}
