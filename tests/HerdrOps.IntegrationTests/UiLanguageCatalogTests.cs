using System.Text.RegularExpressions;
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
    public void EveryV01XamlLanguageBindingExistsAndNoBilingualLiteralRemains()
    {
        var root = FindRepositoryRoot();
        var relativePaths = new[]
        {
            "src/HerdrOps.App/Views/ShellView.xaml",
            "src/HerdrOps.App/Views/OverviewView.xaml",
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
        Assert.IsTrue(englishWidget.Notices.All(notice => !ContainsThai(notice.Message)));
        CollectionAssert.AreEqual(
            thaiOverview.SummaryCards.Select(card => card.Id).ToArray(),
            englishOverview.SummaryCards.Select(card => card.Id).ToArray());
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
