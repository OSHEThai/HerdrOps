using HerdrOps.App.Live;
using HerdrOps.App.Localization;
using HerdrOps.App.Organization;

namespace HerdrOps.IntegrationTests;

[TestClass]
[DoNotParallelize]
public sealed class SyntheticLiveOrganizationStateTests
{
    [TestInitialize]
    public void UseThaiDefault() => UiLanguageService.Shared.SetLanguage(UiLanguage.Thai);

    [TestCleanup]
    public void RestoreThaiDefault() => UiLanguageService.Shared.SetLanguage(UiLanguage.Thai);

    [TestMethod]
    public void SyntheticPreviewHasDeterministicOrganizationHierarchyAndSelection()
    {
        using var dashboard = LiveDashboardState.CreateSyntheticPreview();
        var organization = dashboard.Organization;
        var text = UiLanguageService.Shared;

        Assert.AreEqual(LiveDashboardConnectionStatus.SyntheticPreview, dashboard.ConnectionStatus);
        Assert.IsFalse(dashboard.IsLive);
        Assert.AreEqual(text["SyntheticShellPreview"], organization.SourceLabel);
        Assert.IsGreaterThan(0, organization.Nodes.Count);
        Assert.IsTrue(organization.Nodes.Any(node => node.Name == "Project Manager"));
        Assert.IsTrue(organization.Nodes.Any(node => node.Name == "PM Secretary"));
        Assert.IsTrue(organization.Nodes.Any(node => node.Name == "Backend Leader"));
        Assert.IsTrue(organization.Nodes.Any(node => node.Name == "Frontend Leader"));
        Assert.IsTrue(organization.Nodes.Any(node => node.Name == "Test Leader"));
        Assert.IsTrue(organization.Nodes.Any(node => node.Name == "DevOps Leader"));
        Assert.IsTrue(organization.Nodes.Any(node => !node.IsAgent));
        Assert.IsTrue(organization.SummaryCards.All(card =>
            int.TryParse(card.Value, out var value) && value > 0));

        var statuses = organization.Nodes.Select(node => node.Status).ToArray();
        Assert.IsTrue(statuses.Contains(text["StatusWorking"]));
        Assert.IsTrue(statuses.Contains(text["StatusIdle"]));
        Assert.IsTrue(statuses.Contains(text["StatusBlocked"]));
        Assert.IsTrue(statuses.Contains(text["StatusDone"]));
        Assert.AreEqual(
            LiveOrganizationState.SyntheticProjectManagerTerminalId,
            dashboard.SelectedTerminalId);
        Assert.AreEqual("Project Manager", organization.SelectedNode?.Name);
        Assert.AreEqual("Project Manager", organization.SelectedAgent.Name);
        Assert.AreEqual(text["StatusWorking"], organization.SelectedAgent.Status);
        Assert.IsTrue(organization.AttentionItems.Any(item =>
            item.Title == text["OrganizationRoleConflicts"]));
        Assert.IsTrue(organization.AttentionItems.Any(item =>
            item.Title == text.Format("OrganizationAttentionUnassignedFormat", 2)));
    }

    [TestMethod]
    public void SyntheticPreviewRefreshesAllOrganizationCopyForOneSelectedLanguage()
    {
        var language = UiLanguageService.Shared;
        language.SetLanguage(UiLanguage.Thai);
        using var dashboard = LiveDashboardState.CreateSyntheticPreview();
        var thaiTitle = dashboard.Organization.SummaryCards[0].Title;
        var thaiStatus = dashboard.Organization.SelectedAgent.Status;

        language.SetLanguage(UiLanguage.English);
        dashboard.RefreshLanguage();

        Assert.AreNotEqual(thaiTitle, dashboard.Organization.SummaryCards[0].Title);
        Assert.AreNotEqual(thaiStatus, dashboard.Organization.SelectedAgent.Status);
        Assert.AreEqual(language["StatusWorking"], dashboard.Organization.SelectedAgent.Status);
        Assert.IsTrue(dashboard.Organization.SummaryCards.All(card =>
            !ContainsThai(card.Title + card.Detail)));
        Assert.IsTrue(dashboard.Organization.Nodes.All(node =>
            !ContainsThai(node.NodeType + node.Subtitle + node.Status)));
        Assert.IsTrue(dashboard.Organization.AttentionItems.All(item =>
            !ContainsThai(item.Title + item.Detail)));
        Assert.IsFalse(ContainsThai(dashboard.Organization.HierarchyLabel));
    }

    [TestMethod]
    public void SyntheticPreviewProvidesReportingLinksAndPresentationBandsForTreeLayout()
    {
        using var dashboard = LiveDashboardState.CreateSyntheticPreview();
        var nodes = dashboard.Organization.Nodes;
        var projectManager = nodes.Single(node => node.Name == "Project Manager");
        var secretary = nodes.Single(node => node.Name == "PM Secretary");
        var backendLeader = nodes.Single(node => node.Name == "Backend Leader");
        var backendWorker = nodes.Single(node => node.Name == "Backend Worker 01");
        var vacantBackend = nodes.Single(node => node.NodeId == "synthetic-vacant-backend-worker-04");

        Assert.IsNull(projectManager.ParentNodeId);
        Assert.AreEqual(0, projectManager.LayoutRow);
        Assert.AreEqual(projectManager.NodeId, secretary.ParentNodeId);
        Assert.AreEqual(1, secretary.LayoutRow);
        Assert.AreEqual(projectManager.NodeId, backendLeader.ParentNodeId);
        Assert.AreEqual(2, backendLeader.LayoutRow);
        Assert.AreEqual(backendLeader.NodeId, backendWorker.ParentNodeId);
        Assert.AreEqual(3, backendWorker.LayoutRow);
        Assert.AreEqual(backendLeader.NodeId, vacantBackend.ParentNodeId);
        Assert.AreEqual(3, vacantBackend.LayoutRow);
    }

    [TestMethod]
    public void NormalDashboardConstructionRemainsRuntimeUnavailableAndUnpopulated()
    {
        using var dashboard = new LiveDashboardState();
        var text = UiLanguageService.Shared;

        Assert.AreEqual(LiveDashboardConnectionStatus.Waiting, dashboard.ConnectionStatus);
        Assert.IsFalse(dashboard.IsLive);
        Assert.AreEqual(0L, dashboard.CurrentState.LastIngestSequence);
        Assert.IsEmpty(dashboard.CurrentState.Agents);
        Assert.IsEmpty(dashboard.Organization.Nodes);
        Assert.IsTrue(dashboard.Organization.SummaryCards.All(card => card.Value == "0"));
        Assert.AreEqual(
            text["OrganizationAttentionCoreOfflineTitle"],
            dashboard.Organization.AttentionItems.Single().Title);
        Assert.AreEqual(text["NoAgentSelected"], dashboard.Organization.SelectedAgent.Name);
    }

    private static bool ContainsThai(string value) =>
        value.Any(character => character is >= '\u0E00' and <= '\u0E7F');
}
