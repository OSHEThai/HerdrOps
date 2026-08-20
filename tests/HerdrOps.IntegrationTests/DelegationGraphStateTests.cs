using System.Text.RegularExpressions;
using HerdrOps.App.Delegation;
using HerdrOps.App.Live;
using HerdrOps.App.Localization;

namespace HerdrOps.IntegrationTests;

[TestClass]
[DoNotParallelize]
public sealed class DelegationGraphStateTests
{
    [TestInitialize]
    public void UseThaiDefault() => UiLanguageService.Shared.SetLanguage(UiLanguage.Thai);

    [TestCleanup]
    public void RestoreThaiDefault() => UiLanguageService.Shared.SetLanguage(UiLanguage.Thai);

    [TestMethod]
    public void TaskSelectionSynchronizesGraphTimelineAndSelectedNodeDetail()
    {
        var state = DelegationGraphState.CreateSyntheticPreview();
        var blockedTask = state.TaskTreeItems.Single(item => item.TaskId == "TASK-122");

        state.SelectedTask = blockedTask;

        Assert.AreEqual("TASK-122", state.SelectedTask?.TaskId);
        Assert.IsTrue(state.GraphNodes.Any(item => item.Opacity == 1d));
        Assert.IsTrue(state.GraphNodes.Any(item => item.Opacity < 1d));
        Assert.IsTrue(state.GraphEdges.Where(item => item.Opacity >= 0.9d).All(item => item.TaskId == "TASK-122"));
        Assert.IsTrue(state.Timeline.All(item => item.TaskId == "TASK-122"));
        Assert.AreEqual(state.SelectedNode?.ActorId, state.SelectedDetail.ActorId);
        Assert.IsTrue(state.SelectedDetail.TaskIds.Contains("TASK-122", StringComparer.Ordinal));
    }

    [TestMethod]
    public void NodeSelectionFallsBackToActorRelatedTaskWhenTaskSelectionMismatches()
    {
        var state = DelegationGraphState.CreateSyntheticPreview();
        var selectedTask = state.TaskTreeItems.Single(item => item.TaskId == "TASK-122");
        var actor = state.GraphNodes.Single(item => item.ActorId == "backend-worker-01");

        state.SelectedTask = selectedTask;
        state.SelectedNode = actor;

        Assert.AreEqual("backend-worker-01", state.SelectedNode?.ActorId);
        Assert.AreEqual("TASK-115", state.SelectedTask?.TaskId);
        Assert.AreEqual("backend-worker-01", state.SelectedDetail.ActorId);
        Assert.IsTrue(state.Timeline.All(item => item.TaskId == "TASK-115"));
        Assert.IsTrue(state.GraphEdges.All(item => item.TaskId == "TASK-115" ? item.Opacity >= 0.9d : item.Opacity < 0.9d));
        Assert.AreNotEqual("—", state.SelectedDetail.AssignmentSummary);
        Assert.IsTrue(state.SelectedDetail.TaskIds.Contains("TASK-115", StringComparer.Ordinal));
        Assert.IsFalse(state.SelectedDetail.TaskIds.Contains("TASK-122", StringComparer.Ordinal));
    }

    [TestMethod]
    public void VisualAndAccessibleSelectionsRemainEquivalent()
    {
        var state = DelegationGraphState.CreateSyntheticPreview();
        var worker = state.GraphNodes.Single(item => item.ActorId == "frontend-worker-01");

        state.SelectedNode = worker;

        Assert.AreEqual(worker.ActorId, state.SelectedAccessibleItem?.ActorId);
        Assert.AreEqual(worker.ActorId, state.SelectedDetail.ActorId);

        var reviewer = state.AccessibleItems.Single(item => item.ActorId == "reviewer-01");
        state.SelectedAccessibleItem = reviewer;

        Assert.AreEqual(reviewer.ActorId, state.SelectedNode?.ActorId);
        Assert.AreEqual(reviewer.ActorId, state.SelectedDetail.ActorId);
        Assert.AreEqual(UiLanguageService.Shared["StatusReview"], state.SelectedDetail.Status);
    }

    [TestMethod]
    public void ProjectionPresentsWorkingIdleBlockedReviewAndDoneAsTextAndColor()
    {
        var state = DelegationGraphState.CreateSyntheticPreview();
        var statuses = state.GraphNodes.Select(item => item.Status).ToHashSet(StringComparer.Ordinal);

        foreach (var expected in new[]
                 {
                     UiLanguageService.Shared["StatusWorking"],
                     UiLanguageService.Shared["StatusIdle"],
                     UiLanguageService.Shared["StatusBlocked"],
                     UiLanguageService.Shared["StatusReview"],
                     UiLanguageService.Shared["StatusDone"],
                 })
        {
            Assert.Contains(expected, statuses);
        }

        Assert.IsTrue(state.GraphNodes.All(item => !string.IsNullOrWhiteSpace(item.StatusBrushKey)));
        Assert.IsTrue(state.AccessibleItems.All(item =>
            !string.IsNullOrWhiteSpace(item.Status) && !string.IsNullOrWhiteSpace(item.Description)));
    }

    [TestMethod]
    public void LanguageRefreshRebuildsDelegationPresentationWithoutRetainingThaiCopy()
    {
        var state = DelegationGraphState.CreateSyntheticPreview();
        var actorIds = state.GraphNodes.Select(item => item.ActorId).ToArray();
        Assert.IsTrue(state.GraphNodes.Any(item => ContainsThai(item.Name + item.Role + item.Status)));

        UiLanguageService.Shared.SetLanguage(UiLanguage.English);
        state.RefreshLanguage();

        CollectionAssert.AreEqual(actorIds, state.GraphNodes.Select(item => item.ActorId).ToArray());
        Assert.AreEqual("Deterministic lifecycle fixture", state.SourceLabel);
        Assert.IsTrue(state.GraphNodes.All(item => !ContainsThai(item.Name + item.Role + item.Status + item.TaskCount)));
        Assert.IsTrue(state.GraphEdges.All(item => !ContainsThai(item.Relationship + item.AutomationName)));
        Assert.IsTrue(state.Timeline.All(item => !ContainsThai(item.Kind + item.Actor + item.Target + item.Disposition)));
        Assert.IsTrue(state.AccessibleItems.All(item => !ContainsThai(item.Name + item.Description + item.Status)));
    }

    [TestMethod]
    public void ProductionDashboardFailsClosedUntilAdmittedLifecycleDataExists()
    {
        var dashboard = new LiveDashboardState();
        var state = dashboard.DelegationGraph;

        Assert.IsFalse(state.HasGraph);
        Assert.IsEmpty(state.TaskTreeItems);
        Assert.IsEmpty(state.GraphNodes);
        Assert.IsEmpty(state.GraphEdges);
        Assert.IsEmpty(state.Timeline);
        Assert.AreEqual(UiLanguageService.Shared["DelegationWaitingSource"], state.SourceLabel);
        Assert.AreEqual(UiLanguageService.Shared["DelegationUnavailableBoundary"], state.EvidenceBoundary);
        Assert.IsTrue(state.SummaryCards.All(item => item.Value == "—"));
    }

    private static bool ContainsThai(string value) =>
        Regex.IsMatch(value, "[ก-๙]", RegexOptions.CultureInvariant);
}
