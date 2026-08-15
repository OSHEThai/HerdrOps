using System.Text.RegularExpressions;
using HerdrOps.App.Live;
using HerdrOps.App.Localization;
using HerdrOps.App.Overview;
using HerdrOps.App.Widgets;

namespace HerdrOps.IntegrationTests;

[TestClass]
[DoNotParallelize]
public sealed class UiLanguageCatalogTests
{
    [TestCleanup]
    public void RestoreThaiDefault() =>
        UiLanguageService.Shared.SetLanguage(UiLanguage.Thai);

    [TestMethod]
    public void ThaiIsTheDefaultAndBothCatalogsContainTheSameNonEmptyKeys()
    {
        var language = UiLanguageService.Shared;
        var thaiKeys = language.Keys(UiLanguage.Thai).Order(StringComparer.Ordinal).ToArray();
        var englishKeys = language.Keys(UiLanguage.English).Order(StringComparer.Ordinal).ToArray();

        Assert.AreEqual(UiLanguage.Thai, UiLanguageService.DefaultLanguage);
        CollectionAssert.AreEqual(thaiKeys, englishKeys);
        Assert.IsNotEmpty(thaiKeys);
        foreach (var key in thaiKeys)
        {
            Assert.IsFalse(string.IsNullOrWhiteSpace(language.Text(UiLanguage.Thai, key)), $"Thai text is empty: {key}");
            Assert.IsFalse(string.IsNullOrWhiteSpace(language.Text(UiLanguage.English, key)), $"English text is empty: {key}");
            Assert.IsFalse(
                Regex.IsMatch(language.Text(UiLanguage.English, key), "[ก-๙]", RegexOptions.CultureInvariant),
                $"English text contains Thai copy: {key}");
        }
    }

    [TestMethod]
    public void ThaiCatalogUsesThaiCoreTerminologyWithoutEnglishLabel()
    {
        var language = UiLanguageService.Shared;
        var retainedCoreLabels = language.Keys(UiLanguage.Thai)
            .Where(key => Regex.IsMatch(
                language.Text(UiLanguage.Thai, key),
                @"(?<![A-Za-z])Core(?![A-Za-z])",
                RegexOptions.CultureInvariant | RegexOptions.IgnoreCase))
            .ToArray();

        Assert.IsEmpty(
            retainedCoreLabels,
            $"Thai UI catalog retained English Core labels: {string.Join(", ", retainedCoreLabels)}");
    }

    [TestMethod]
    public void EveryV01XamlLanguageBindingExistsAndNoBilingualLiteralRemains()
    {
        var root = FindRepositoryRoot();
        var relativePaths = new[]
        {
            "src/HerdrOps.App/Views/ShellView.xaml",
            "src/HerdrOps.App/Views/OverviewView.xaml",
            "src/HerdrOps.App/Views/LiveOrganizationView.xaml",
            "src/HerdrOps.App/Views/AgentDetailView.xaml",
            "src/HerdrOps.App/Views/DelegationGraphView.xaml",
            "src/HerdrOps.App/Views/TaskAlignmentView.xaml",
            "src/HerdrOps.App/Views/ComplianceQueueView.xaml",
            "src/HerdrOps.App/Widgets/WidgetGalleryView.xaml",
            "src/HerdrOps.App/Widgets/WidgetSurface.xaml",
        };
        var knownKeys = UiLanguageService.Shared.Keys(UiLanguage.Thai).ToHashSet(StringComparer.Ordinal);

        foreach (var relativePath in relativePaths)
        {
            var xaml = File.ReadAllText(Path.Combine(root, relativePath));
            var referencedKeys = Regex.Matches(
                    xaml,
                    @"Binding \[([A-Za-z0-9]+)\]",
                    RegexOptions.CultureInvariant)
                .Select(match => match.Groups[1].Value)
                .Distinct(StringComparer.Ordinal)
                .ToArray();

            Assert.IsNotEmpty(referencedKeys, $"No localized bindings found in {relativePath}");
            Assert.IsTrue(
                referencedKeys.All(knownKeys.Contains),
                $"Unknown localized key in {relativePath}: {string.Join(", ", referencedKeys.Where(key => !knownKeys.Contains(key)))}");
            Assert.IsFalse(
                Regex.IsMatch(
                    xaml,
                    @"(?:Text|Content|AutomationProperties\.Name)=""[^""{]*[ก-๙]",
                    RegexOptions.CultureInvariant),
                $"Hard-coded Thai UI copy remains in {relativePath}");
            Assert.IsFalse(xaml.Contains("ThaiTitle", StringComparison.Ordinal), relativePath);
            Assert.IsFalse(xaml.Contains("EnglishTitle", StringComparison.Ordinal), relativePath);
            if (relativePath.EndsWith("LiveOrganizationView.xaml", StringComparison.Ordinal) ||
                relativePath.EndsWith("AgentDetailView.xaml", StringComparison.Ordinal) ||
                relativePath.EndsWith("TaskAlignmentView.xaml", StringComparison.Ordinal))
            {
                Assert.IsFalse(
                    Regex.IsMatch(
                        xaml,
                        @"(?:Text|Content|AutomationProperties\.Name)=""[^""{]*[A-Za-zก-๙]",
                        RegexOptions.CultureInvariant),
                    $"Hard-coded localized UI copy remains in {relativePath}");
            }
        }
    }

    [TestMethod]
    public void SyntheticOverviewAndWidgetCopyRebuildsAsOneSelectedLanguage()
    {
        var language = UiLanguageService.Shared;
        language.SetLanguage(UiLanguage.Thai);
        var thaiOverview = SyntheticOverviewState.Create();
        var thaiWidget = SyntheticWidgetState.Create();
        var thaiWidgetDescription = thaiWidget.GalleryDescription;

        language.SetLanguage(UiLanguage.English);
        var englishOverview = SyntheticOverviewState.Create();
        var englishWidget = SyntheticWidgetState.Create();

        Assert.AreNotEqual(thaiOverview.SourceLabel, englishOverview.SourceLabel);
        Assert.AreNotEqual(thaiOverview.SummaryCards[0].Title, englishOverview.SummaryCards[0].Title);
        Assert.AreNotEqual(thaiWidgetDescription, englishWidget.GalleryDescription);
        Assert.IsTrue(englishOverview.SummaryCards.All(card => !ContainsThai(card.Title + card.Metric + card.Trend)));
        Assert.IsTrue(englishOverview.RecentActivities.All(activity => !ContainsThai(activity.Description)));
        Assert.IsTrue(englishOverview.Alerts.All(alert => !ContainsThai(alert.Title + alert.Description + alert.State)));
        Assert.IsTrue(englishWidget.Agents.All(agent => !ContainsThai(agent.Role + agent.Activity + agent.Status)));
        Assert.IsTrue(englishWidget.Notices.All(notice => !ContainsThai(notice.Message + notice.State)));
        CollectionAssert.AreEqual(
            thaiOverview.SummaryCards.Select(card => card.Id).ToArray(),
            englishOverview.SummaryCards.Select(card => card.Id).ToArray());
    }

    [TestMethod]
    public void LiveDashboardCopyRebuildsFromThaiToEnglishWithoutRetainingThaiText()
    {
        var language = UiLanguageService.Shared;
        language.SetLanguage(UiLanguage.Thai);
        var dashboard = new LiveDashboardState();
        var state = LiveWidgetStateTests.CreateState(sequence: 12);
        var update = LiveWidgetStateTests.SnapshotUpdate(state);
        dashboard.ApplyUpdate(update, update.Envelope.SentUtc.AddMilliseconds(18));
        var thaiCopy = FlattenLocalizedCopy(dashboard).ToArray();
        var thaiActivity = dashboard.Overview.RecentActivities[0].Description;

        Assert.IsTrue(thaiCopy.Any(ContainsThai));
        Assert.IsTrue(ContainsThai(thaiActivity));

        language.SetLanguage(UiLanguage.English);
        dashboard.RefreshLanguage();
        var englishCopy = FlattenLocalizedCopy(dashboard).ToArray();

        Assert.AreNotEqual(thaiActivity, dashboard.Overview.RecentActivities[0].Description);
        Assert.IsTrue(englishCopy.All(value => !ContainsThai(value)),
            $"English live UI retained Thai copy: {string.Join(" | ", englishCopy.Where(ContainsThai))}");
        Assert.AreEqual("CORE SNAPSHOT", dashboard.SourceLabel);
        Assert.AreEqual("Working", dashboard.AgentDetail.Status);
        Assert.IsTrue(dashboard.Organization.SummaryCards.All(card => !ContainsThai(card.Title + card.Detail)));
        Assert.IsTrue(dashboard.AgentDetail.UnsupportedSections.All(
            section => !ContainsThai(section.Title + section.Value + section.Explanation)));
    }

    private static IEnumerable<string> FlattenLocalizedCopy(LiveDashboardState dashboard)
    {
        yield return dashboard.SourceLabel;
        yield return dashboard.ConnectionLabel;
        yield return dashboard.StatusSummary;
        yield return dashboard.LastUpdateLabel;
        foreach (var card in dashboard.Overview.SummaryCards)
        {
            yield return card.Title;
            yield return card.Metric;
            yield return card.Trend;
        }

        yield return dashboard.Overview.ActivitySourceLabel;
        yield return dashboard.Overview.ActivityFooterLabel;
        yield return dashboard.Overview.ScoreTrendStatus;
        yield return dashboard.Overview.TopAgentsSourceLabel;
        yield return dashboard.Overview.AgentListTitle;
        yield return dashboard.Overview.AlertsCountLabel;
        foreach (var activity in dashboard.Overview.RecentActivities)
        {
            yield return activity.Description;
        }

        foreach (var alert in dashboard.Overview.Alerts)
        {
            yield return alert.Title;
            yield return alert.Description;
            yield return alert.State;
        }

        foreach (var row in dashboard.Overview.TopAgents)
        {
            yield return row.DeltaLabel;
        }

        yield return dashboard.Organization.HierarchyLabel;
        foreach (var card in dashboard.Organization.SummaryCards)
        {
            yield return card.Title;
            yield return card.Detail;
        }

        foreach (var node in dashboard.Organization.Nodes)
        {
            yield return node.NodeType;
            yield return node.Subtitle;
            yield return node.Status;
        }

        yield return dashboard.Organization.SelectedAgent.Status;
        yield return dashboard.Organization.SelectedAgent.SourceNote;
        foreach (var item in dashboard.Organization.AttentionItems)
        {
            yield return item.Title;
            yield return item.Detail;
        }

        yield return dashboard.AgentDetail.Status;
        yield return dashboard.AgentDetail.InteractiveReady;
        yield return dashboard.AgentDetail.LaunchPending;
        yield return dashboard.AgentDetail.ScreenDetectionSkipped;
        foreach (var fact in dashboard.AgentDetail.RecentFacts)
        {
            yield return fact.Label;
            yield return fact.Value;
            yield return fact.Source;
        }

        foreach (var section in dashboard.AgentDetail.UnsupportedSections)
        {
            yield return section.Title;
            yield return section.Value;
            yield return section.Explanation;
        }

        foreach (var related in dashboard.AgentDetail.RelatedAgents)
        {
            yield return related.Status;
        }

        yield return dashboard.Widgets.SourceLabel;
        yield return dashboard.Widgets.CompactSourceLabel;
        yield return dashboard.Widgets.ConnectionLabel;
        yield return dashboard.Widgets.CompactConnectionLabel;
        yield return dashboard.Widgets.GalleryDescription;
        yield return dashboard.Widgets.DashboardPreviewLabel;
        yield return dashboard.Widgets.WindowTitleSuffix;
        yield return dashboard.Widgets.DetailsSourceLabel;
        yield return dashboard.Widgets.DailyScoreLabel;
        yield return dashboard.Widgets.LatencyLabel;
        foreach (var agent in dashboard.Widgets.Agents)
        {
            yield return agent.AssignedBy;
            yield return agent.Activity;
            yield return agent.Elapsed;
            yield return agent.Status;
            yield return agent.StartedLabel;
        }

        foreach (var notice in dashboard.Widgets.Notices)
        {
            yield return notice.AgentName;
            yield return notice.Message;
            yield return notice.State;
        }

        foreach (var activity in dashboard.Widgets.SelectedAgentActivity)
        {
            yield return activity.Description;
        }
    }

    private static bool ContainsThai(string value) =>
        Regex.IsMatch(value, "[ก-๙]", RegexOptions.CultureInvariant);

    private static string FindRepositoryRoot()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null)
        {
            if (File.Exists(Path.Combine(directory.FullName, "HerdrOps.sln")))
            {
                return directory.FullName;
            }

            directory = directory.Parent;
        }

        Assert.Fail("Could not locate HerdrOps.sln from the integration test output directory.");
        return string.Empty;
    }
}
