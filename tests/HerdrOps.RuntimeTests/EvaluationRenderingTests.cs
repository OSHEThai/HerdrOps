using System.IO;
using System.Security.Cryptography;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using HerdrOps.App.Evaluation;
using HerdrOps.App.Localization;
using HerdrOps.App.Views;
using HerdrOps.Domain.Evaluation;

namespace HerdrOps.RuntimeTests;

[TestClass]
[DoNotParallelize]
public sealed class EvaluationRenderingTests
{
    private const int ReferenceWidth = 1672;
    private const int ReferenceHeight = 941;
    private const int CompactWidth = 1366;
    private const int CompactHeight = 768;
    private const double GeometryEpsilon = 0.5;

    private static readonly string[] RegionNames =
    [
        "EvaluationEvidenceBoundary",
        "EvaluationSummaryRegion",
        "EvaluationDistributionRegion",
        "EvaluationTrendRegion",
        "EvaluationDimensionRegion",
        "EvaluationComparisonRegion",
        "EvaluationTopAgentsRegion",
        "EvaluationLowAgentsRegion",
    ];

    private static readonly string[] EvaluationCopyKeys =
    [
        "EvaluationPageTitle",
        "EvaluationSyntheticSource",
        "EvaluationLiveSourceUnavailable",
        "EvaluationSyntheticBoundary",
        "EvaluationLiveBoundary",
        "EvaluationAverageScoreToday",
        "EvaluationComparedToYesterday",
        "EvaluationTotalEvaluations",
        "EvaluationToday",
        "EvaluationLeaderReviewsPending",
        "EvaluationPmReviewsPending",
        "EvaluationRecurringIssues",
        "EvaluationFromLastWeek",
        "EvaluationScoreDistributionTitle",
        "EvaluationEvaluations",
        "EvaluationScoreBandExcellent",
        "EvaluationScoreBandGood",
        "EvaluationScoreBandAcceptable",
        "EvaluationScoreBandNeedsImprovement",
        "EvaluationScoreBandFail",
        "EvaluationScoreTrendTitle",
        "EvaluationPeriod7Days",
        "EvaluationPeriodToday",
        "EvaluationPeriodLastWeek",
        "EvaluationDimensionBreakdownTitle",
        "EvaluationDimensionGoalAlignment",
        "EvaluationDimensionAcceptanceCriteria",
        "EvaluationDimensionTechnicalQuality",
        "EvaluationDimensionScopeCompliance",
        "EvaluationDimensionEvidence",
        "EvaluationDimensionCommunication",
        "EvaluationWeightedAverage",
        "EvaluationScoreComparisonTitle",
        "EvaluationComparisonDimension",
        "EvaluationComparisonLeaderScore",
        "EvaluationComparisonPmScore",
        "EvaluationComparisonObjectiveEvidence",
        "EvaluationComparisonWeightedScore",
        "EvaluationComparisonTotal",
        "EvaluationTotalWeight",
        "EvaluationTopPerformingAgentsTitle",
        "EvaluationLowPerformingAgentsTitle",
        "EvaluationViewAll",
        "EvaluationTieLabel",
        "EvaluationMissingScoreLabel",
        "EvaluationCompleteLabel",
        "EvaluationInvalidLabel",
        "EvaluationUnavailableLabel",
        "EvaluationSyntheticStatus",
        "EvaluationNoRankingData",
        "EvaluationRankingUnavailable",
    ];

    [TestMethod]
    public void SyntheticWpfEvaluationRendersLocalizedReferenceHierarchyAndMissingScore()
    {
        WpfTestHost.Run(RenderEvidence, TimeSpan.FromSeconds(90));
    }

    private static void RenderEvidence()
    {
        var repositoryRoot = FindRepositoryRoot();
        var referencePath = Path.Combine(repositoryRoot, "docs", "design", "reference", "09-evaluation.png");
        Assert.IsTrue(File.Exists(referencePath), $"Approved Evaluation reference is missing: {referencePath}");

        var evidenceDirectory = Path.Combine(
            repositoryRoot,
            "artifacts",
            "design-evidence",
            "v0.6.0",
            "issue-31",
            "evaluation");
        Directory.CreateDirectory(evidenceDirectory);
        var language = UiLanguageService.Shared;

        try
        {
            language.SetLanguage(UiLanguage.Thai);
            var thaiShell = CreateEvaluationShell();
            Layout(thaiShell, ReferenceWidth, ReferenceHeight);
            var thaiPage = Page(thaiShell);
            AssertRegions(thaiShell, thaiPage);
            var thaiState = Assert.IsInstanceOfType<EvaluationState>(thaiPage.DataContext);
            AssertAccessibilityEquivalents(thaiPage, thaiState, language);
            AssertThaiSurface(thaiPage, language);
            AssertComparisonAggregateBindingsAndValues(thaiPage, thaiState);
            AssertReferenceRankingGeometry(thaiPage);
            var thaiPath = Path.Combine(evidenceDirectory, "evaluation-th-1672x941.png");
            RenderPng(thaiShell, ReferenceWidth, ReferenceHeight, thaiPath);

            var compactShell = CreateEvaluationShell();
            Layout(compactShell, CompactWidth, CompactHeight);
            var compactPage = Page(compactShell);
            AssertRegions(compactShell, compactPage);
            var compactState = Assert.IsInstanceOfType<EvaluationState>(compactPage.DataContext);
            AssertAccessibilityEquivalents(compactPage, compactState, language);
            AssertThaiSurface(compactPage, language);
            var scroll = Assert.IsInstanceOfType<ScrollViewer>(compactPage.FindName("EvaluationScrollViewer"));
            AssertCompactGeometry(compactPage, scroll);
            var compactPath = Path.Combine(evidenceDirectory, "evaluation-th-1366x768.png");
            RenderPng(compactShell, CompactWidth, CompactHeight, compactPath);

            var missingShell = CreateEvaluationShell();
            var missingPage = Page(missingShell);
            missingPage.DataContext = EvaluationState.CreateMissingScorePreview();
            Layout(missingShell, ReferenceWidth, ReferenceHeight);
            var missingState = Assert.IsInstanceOfType<EvaluationState>(missingPage.DataContext);
            Assert.AreEqual(1, missingState.MissingScoreCount);
            Assert.AreEqual(5, missingState.EvaluationCountScored);
            Assert.AreEqual("5 / 6", missingState.DistributionCenterValue);
            AssertRegions(missingShell, missingPage);
            AssertAccessibilityEquivalents(missingPage, missingState, language);
            AssertMissingAndInvalidStatuses(missingPage, missingState, language);
            var missingPath = Path.Combine(evidenceDirectory, "evaluation-th-missing-score-1672x941.png");
            RenderPng(missingShell, ReferenceWidth, ReferenceHeight, missingPath);
            AssertDifferentImages(thaiPath, missingPath);

            var unavailableShell = CreateEvaluationShell();
            var unavailablePage = Page(unavailableShell);
            unavailablePage.DataContext = EvaluationState.CreateUnavailable();
            Layout(unavailableShell, ReferenceWidth, ReferenceHeight);
            var unavailableState = Assert.IsInstanceOfType<EvaluationState>(unavailablePage.DataContext);
            AssertRegions(unavailableShell, unavailablePage);
            AssertAccessibilityEquivalents(unavailablePage, unavailableState, language);
            AssertUnavailablePresentation(unavailablePage, unavailableState, language);

            language.SetLanguage(UiLanguage.English);
            var englishShell = CreateEvaluationShell();
            Layout(englishShell, ReferenceWidth, ReferenceHeight);
            var englishPage = Page(englishShell);
            AssertRegions(englishShell, englishPage);
            var englishState = Assert.IsInstanceOfType<EvaluationState>(englishPage.DataContext);
            AssertAccessibilityEquivalents(englishPage, englishState, language);
            AssertEnglishSurface(englishPage, language);
            AssertComparisonAggregateBindingsAndValues(englishPage, englishState);
            AssertReferenceRankingGeometry(englishPage);
            var englishPath = Path.Combine(evidenceDirectory, "evaluation-en-1672x941.png");
            RenderPng(englishShell, ReferenceWidth, ReferenceHeight, englishPath);
            AssertDifferentImages(thaiPath, englishPath);

            var englishUnavailableShell = CreateEvaluationShell();
            var englishUnavailablePage = Page(englishUnavailableShell);
            englishUnavailablePage.DataContext = EvaluationState.CreateUnavailable();
            Layout(englishUnavailableShell, ReferenceWidth, ReferenceHeight);
            var englishUnavailableState = Assert.IsInstanceOfType<EvaluationState>(englishUnavailablePage.DataContext);
            AssertRegions(englishUnavailableShell, englishUnavailablePage);
            AssertAccessibilityEquivalents(englishUnavailablePage, englishUnavailableState, language);
            AssertUnavailablePresentation(englishUnavailablePage, englishUnavailableState, language);

            var englishCompactShell = CreateEvaluationShell();
            Layout(englishCompactShell, CompactWidth, CompactHeight);
            var englishCompactPage = Page(englishCompactShell);
            AssertRegions(englishCompactShell, englishCompactPage);
            var englishCompactState = Assert.IsInstanceOfType<EvaluationState>(englishCompactPage.DataContext);
            AssertAccessibilityEquivalents(englishCompactPage, englishCompactState, language);
            AssertEnglishSurface(englishCompactPage, language);
            var englishCompactScroll = Assert.IsInstanceOfType<ScrollViewer>(englishCompactPage.FindName("EvaluationScrollViewer"));
            AssertCompactGeometry(englishCompactPage, englishCompactScroll);
            var englishCompactPath = Path.Combine(evidenceDirectory, "evaluation-en-1366x768.png");
            RenderPng(englishCompactShell, CompactWidth, CompactHeight, englishCompactPath);
            AssertDifferentImages(compactPath, englishCompactPath);
        }
        finally
        {
            language.SetLanguage(UiLanguage.Thai);
        }
    }

    private static ShellView CreateEvaluationShell()
    {
        var shell = ShellView.CreateSyntheticPreview();
        Assert.IsTrue(shell.NavigateTo("evaluation"));
        return shell;
    }

    private static EvaluationView Page(ShellView shell) =>
        Assert.IsInstanceOfType<EvaluationView>(shell.FindName("EvaluationPage"));

    private static void AssertAccessibilityEquivalents(
        EvaluationView page,
        EvaluationState state,
        UiLanguageService language)
    {
        AssertRegionAccessibility(
            page,
            "EvaluationEvidenceBoundary",
            language["EvaluationEvidenceBoundaryAutomation"]);
        AssertRegionAccessibility(
            page,
            "EvaluationDistributionRegion",
            language["EvaluationScoreDistributionAutomation"]);
        AssertRegionAccessibility(
            page,
            "EvaluationTrendRegion",
            language["EvaluationScoreTrendAutomation"]);
        AssertRegionAccessibility(
            page,
            "EvaluationDimensionRegion",
            language["EvaluationDimensionBreakdownAutomation"]);
        AssertRegionAccessibility(
            page,
            "EvaluationComparisonRegion",
            language["EvaluationComparisonTableAutomation"]);
        AssertRegionAccessibility(
            page,
            "EvaluationTopAgentsRegion",
            language["EvaluationTopPerformingAgentsAutomation"]);
        AssertRegionAccessibility(
            page,
            "EvaluationLowAgentsRegion",
            language["EvaluationLowPerformingAgentsAutomation"]);
        var center = Assert.IsInstanceOfType<FrameworkElement>(page.FindName("EvaluationDistributionCenter"));
        Assert.AreEqual(
            state.DistributionCenterAccessibilityText,
            AutomationProperties.GetName(center),
            "Distribution center automation semantics must reconcile scored and total records.");

        AssertAccessibleItems(
            page,
            "EvaluationSummaryRegion",
            state.SummaryCards.Select(item => item.AccessibilityText));
        AssertAccessibleItems(
            page,
            "EvaluationDistributionRegion",
            state.DistributionBins.Select(item => item.AccessibilityText));
        AssertAccessibleItems(
            page,
            "EvaluationDimensionRegion",
            state.DimensionRows.Select(item => item.AccessibilityText));
        AssertAccessibleItems(
            page,
            "EvaluationComparisonRegion",
            state.ComparisonRows.Select(item => item.AccessibilityText));
        var comparisonTotal = Assert.IsInstanceOfType<FrameworkElement>(
            page.FindName("EvaluationComparisonTotalRow"));
        Assert.AreEqual(
            state.ComparisonTotal.AccessibilityText,
            AutomationProperties.GetName(comparisonTotal),
            "The comparison total row must expose the same source-bound accessibility equivalent as its values.");
        Assert.AreEqual(
            state.ComparisonTotal.StatusText,
            AutomationProperties.GetHelpText(comparisonTotal),
            "The comparison total row must expose an explicit localized status.");
        AssertAccessibleItems(
            page,
            "EvaluationTopAgentsRegion",
            state.TopAgents.Select(item => item.AccessibilityText));
        AssertAccessibleItems(
            page,
            "EvaluationLowAgentsRegion",
            state.LowAgents.Select(item => item.AccessibilityText));

        Assert.IsTrue(
            state.TrendPoints.All(item =>
                !string.IsNullOrWhiteSpace(item.AccessibilityText) &&
                !string.IsNullOrWhiteSpace(item.StatusText)),
            "Every trend point must retain a localized accessibility and status equivalent.");
        Assert.IsTrue(
            state.DistributionBins.All(item => !string.IsNullOrWhiteSpace(item.StatusText)),
            "Every distribution bin must retain a localized status equivalent.");
        Assert.IsTrue(
            state.DimensionRows.All(item => !string.IsNullOrWhiteSpace(item.StatusText)),
            "Every dimension row must retain a localized status equivalent.");
        Assert.IsTrue(
            state.TopAgents.Concat(state.LowAgents).All(item =>
                !string.IsNullOrWhiteSpace(item.AccessibilityText) &&
                !string.IsNullOrWhiteSpace(item.StatusText)),
            "Every ranking row must retain a localized accessibility and status equivalent.");
    }

    private static void AssertRegionAccessibility(
        EvaluationView page,
        string regionName,
        string expectedName)
    {
        var region = Assert.IsInstanceOfType<FrameworkElement>(page.FindName(regionName));
        var observedName = AutomationProperties.GetName(region);
        Assert.IsFalse(
            string.IsNullOrWhiteSpace(observedName),
            $"Accessibility name is missing for {regionName}.");
        Assert.AreEqual(expectedName, observedName, regionName);
    }

    private static void AssertAccessibleItems(
        EvaluationView page,
        string regionName,
        IEnumerable<string> expectedNames)
    {
        var region = Assert.IsInstanceOfType<FrameworkElement>(page.FindName(regionName));
        var observedNames = EnumerateDescendants(region)
            .OfType<FrameworkElement>()
            .Select(AutomationProperties.GetName)
            .Where(name => !string.IsNullOrWhiteSpace(name))
            .ToArray();

        foreach (var expectedName in expectedNames)
        {
            Assert.IsTrue(
                observedNames.Contains(expectedName, StringComparer.Ordinal),
                $"Accessibility equivalent is missing from {regionName}: {expectedName}");
        }
    }

    private static void AssertComparisonAggregateBindingsAndValues(
        EvaluationView page,
        EvaluationState state)
    {
        var dimensionRegion = Assert.IsInstanceOfType<FrameworkElement>(
            page.FindName("EvaluationDimensionRegion"));
        var comparisonRegion = Assert.IsInstanceOfType<FrameworkElement>(
            page.FindName("EvaluationComparisonRegion"));
        var totalRow = Assert.IsInstanceOfType<FrameworkElement>(
            page.FindName("EvaluationComparisonTotalRow"));

        AssertVisibleTextContains(dimensionRegion, state.DimensionWeightedAverageLabel);
        AssertVisibleTextDoesNotContain(dimensionRegion, state.ComparisonTotalScoreLabel);
        AssertVisibleTextContains(comparisonRegion, state.ComparisonTotalScoreLabel);
        AssertVisibleTextContains(comparisonRegion, state.ComparisonTotal.LeaderScoreLabel);
        AssertVisibleTextContains(comparisonRegion, state.ComparisonTotal.ProjectManagerScoreLabel);
        AssertVisibleTextContains(comparisonRegion, state.ComparisonTotal.ObjectiveEvidenceScoreLabel);
        AssertVisibleTextContains(comparisonRegion, state.ComparisonTotal.TotalWeightLabel);
        Assert.AreEqual(
            state.ComparisonTotal.AccessibilityText,
            AutomationProperties.GetName(totalRow));
    }

    private static void AssertReferenceRankingGeometry(EvaluationView page)
    {
        var scroll = Assert.IsInstanceOfType<ScrollViewer>(
            page.FindName("EvaluationScrollViewer"));
        scroll.ScrollToHome();
        scroll.UpdateLayout();

        var viewport = BoundsRelativeTo(scroll, page);
        var comparison = BoundsRelativeTo(
            Assert.IsInstanceOfType<FrameworkElement>(page.FindName("EvaluationComparisonRegion")),
            page);
        var top = BoundsRelativeTo(
            Assert.IsInstanceOfType<FrameworkElement>(page.FindName("EvaluationTopAgentsRegion")),
            page);
        var low = BoundsRelativeTo(
            Assert.IsInstanceOfType<FrameworkElement>(page.FindName("EvaluationLowAgentsRegion")),
            page);

        Assert.IsTrue(
            viewport.Contains(comparison) && viewport.Contains(top) && viewport.Contains(low),
            $"Reference Evaluation layout must show comparison and both rankings in the viewport: viewport={viewport}, comparison={comparison}, top={top}, low={low}");
        Assert.IsLessThanOrEqualTo(
            low.Left + GeometryEpsilon,
            top.Right,
            $"Top and low ranking panels must be side by side: top={top}, low={low}");
        Assert.IsLessThanOrEqualTo(
            GeometryEpsilon,
            Math.Abs(top.Top - low.Top),
            $"Top and low ranking panels must share the comparison row: top={top}, low={low}");
        Assert.IsFalse(
            HasPositiveAreaOverlap(top, low),
            $"Top and low ranking panels overlap at the reference viewport: top={top}, low={low}");
    }

    private static void AssertMissingAndInvalidStatuses(
        EvaluationView missingPage,
        EvaluationState missingState,
        UiLanguageService language)
    {
        var missingLabel = language["EvaluationMissingScoreLabel"];
        AssertVisibleTextContains(missingPage, missingState.DistributionCenterValue);
        AssertVisibleTextContains(missingPage, missingState.DistributionCenterLabel);
        Assert.IsTrue(
            missingState.DimensionRows.Any(item => item.StatusLabel == missingLabel),
            "The missing-score preview must expose a missing dimension status.");
        AssertVisibleTextContains(missingPage, missingLabel);

        var invalidState = CreateInvalidScorePreview(missingState);
        var invalidShell = CreateEvaluationShell();
        var invalidPage = Page(invalidShell);
        invalidPage.DataContext = invalidState;
        Layout(invalidShell, ReferenceWidth, ReferenceHeight);

        var invalidLabel = language["EvaluationInvalidLabel"];
        Assert.IsTrue(
            invalidState.DimensionRows.Any(item => item.StatusLabel == invalidLabel),
            "The invalid-score preview must expose an invalid dimension status.");
        AssertVisibleTextContains(invalidPage, invalidLabel);
        AssertAccessibilityEquivalents(invalidPage, invalidState, language);
    }

    private static void AssertUnavailablePresentation(
        EvaluationView page,
        EvaluationState state,
        UiLanguageService language)
    {
        var unavailable = language["EvaluationUnavailableLabel"];
        var synthetic = language["EvaluationSyntheticStatus"];
        var missing = language["EvaluationMissingScoreLabel"];
        var rankingUnavailable = language["EvaluationRankingUnavailable"];
        Assert.AreEqual(unavailable, state.EvaluationCountLabel);
        Assert.AreEqual(rankingUnavailable, state.RankingEmptyLabel);
        Assert.IsTrue(state.SummaryCards.All(item =>
            item.Value == unavailable &&
            item.MetricLabel == unavailable &&
            item.TrendLabel == unavailable &&
            item.Score is null &&
            item.Count is null &&
            item.Percentage is null));
        Assert.AreEqual(unavailable, state.DistributionCenterValue);
        Assert.AreEqual(unavailable, state.DistributionCenterLabel);
        Assert.AreEqual(unavailable, state.DistributionTotalLabel);
        Assert.IsTrue(state.DistributionBins.All(item =>
            item.Percentage == -1m &&
            item.CountLabel == unavailable &&
            item.PercentageLabel == unavailable &&
            item.StatusText == unavailable));
        Assert.IsTrue(state.TrendPoints.All(item =>
            item.Score is null &&
            item.ScoreLabel == unavailable &&
            item.StatusText == unavailable));
        Assert.IsTrue(state.DimensionRows.All(item =>
            item.ScoreLabel == unavailable &&
            item.StatusLabel == unavailable));
        Assert.IsTrue(state.ComparisonRows.All(item =>
            item.WeightLabel == unavailable &&
            item.LeaderScoreLabel == unavailable &&
            item.ProjectManagerScoreLabel == unavailable &&
            item.ObjectiveEvidenceScoreLabel == unavailable &&
            item.WeightedScoreLabel == unavailable &&
            item.StatusText == unavailable));
        Assert.AreEqual(unavailable, state.ComparisonTotal.TotalWeightLabel);
        Assert.AreEqual(unavailable, state.ComparisonTotal.LeaderScoreLabel);
        Assert.AreEqual(unavailable, state.ComparisonTotal.ProjectManagerScoreLabel);
        Assert.AreEqual(unavailable, state.ComparisonTotal.ObjectiveEvidenceScoreLabel);
        Assert.AreEqual(unavailable, state.ComparisonTotal.WeightedScoreLabel);
        Assert.AreEqual(unavailable, state.ComparisonTotal.StatusText);
        Assert.IsFalse(state.DistributionBins.Any(item => item.StatusText == synthetic));
        AssertVisibleTextContains(page, unavailable);
        AssertVisibleTextContains(page, rankingUnavailable);
        AssertVisibleTextDoesNotContain(page, synthetic);
        AssertVisibleTextDoesNotContain(page, missing);
        AssertVisibleTextDoesNotContain(page, "—");
        Assert.IsFalse(VisibleText(page).Any(value =>
            string.Equals(value, language["EvaluationToday"], StringComparison.Ordinal)));
        Assert.IsFalse(VisibleText(page).Any(value =>
            value.Contains("from 0", StringComparison.Ordinal)));
        Assert.IsFalse(VisibleText(page).Any(value =>
            value.Contains(language["EvaluationNoRankingData"], StringComparison.Ordinal)));
    }

    private static EvaluationState CreateInvalidScorePreview(EvaluationState sourceState)
    {
        var sourceSnapshot = sourceState.Snapshot;
        var selected = sourceSnapshot.Evaluations.Single(item =>
            string.Equals(item.TaskId, sourceSnapshot.SelectedTaskId, StringComparison.Ordinal) &&
            string.Equals(item.AgentId, sourceSnapshot.SelectedAgentId, StringComparison.Ordinal));
        var invalidInputSnapshot = selected.Result.Provenance.InputSnapshot with
        {
            Dimensions = selected.Result.Provenance.InputSnapshot.Dimensions
                .Select((item, index) => index == 0
                    ? item with
                    {
                        Leader = new EvaluationScoreInput(101, "invalid:leader", "not-a-sha256")
                    }
                    : item)
                .ToArray(),
        };
        var invalidResult = new EvaluationScoringEngine().Calculate(
            invalidInputSnapshot,
            selected.Result.Provenance.Formula);
        Assert.AreEqual(EvaluationResultStatus.Invalid, invalidResult.Status);

        var evaluations = sourceSnapshot.Evaluations
            .Select(item => item.EvaluationId == selected.EvaluationId
                ? item with { Result = invalidResult }
                : item)
            .ToArray();
        return new EvaluationState(new EvaluationSnapshot(
            sourceSnapshot.Availability,
            evaluations,
            sourceSnapshot.Trend,
            sourceSnapshot.SelectedTaskId,
            sourceSnapshot.SelectedAgentId,
            sourceSnapshot.SnapshotDate,
            sourceSnapshot.PreviousAverageScore,
            sourceSnapshot.LeaderReviewsPending,
            sourceSnapshot.ProjectManagerReviewsPending,
            sourceSnapshot.RecurringIssueCount));
    }

    private static void AssertCompactGeometry(EvaluationView page, ScrollViewer scroll)
    {
        Assert.IsGreaterThan(0d, scroll.ViewportHeight, "Compact Evaluation viewport has no height.");
        Assert.IsGreaterThan(0d, scroll.ViewportWidth, "Compact Evaluation viewport has no width.");
        Assert.IsGreaterThanOrEqualTo(
            scroll.ViewportHeight - GeometryEpsilon,
            scroll.ExtentHeight,
            $"Evaluation content extent must be at least the viewport: extent={scroll.ExtentHeight:0.##}, viewport={scroll.ViewportHeight:0.##}");
        Assert.IsLessThanOrEqualTo(
            scroll.ViewportWidth + GeometryEpsilon,
            scroll.ExtentWidth,
            $"Evaluation content exceeds the disabled horizontal viewport: extent={scroll.ExtentWidth:0.##}, viewport={scroll.ViewportWidth:0.##}");

        var content = Assert.IsInstanceOfType<FrameworkElement>(scroll.Content);
        Assert.IsGreaterThan(0d, content.ActualWidth, "Compact Evaluation content has no width.");
        Assert.IsGreaterThan(0d, content.ActualHeight, "Compact Evaluation content has no height.");

        var regions = RegionNames
            .Select(name =>
            {
                var region = Assert.IsInstanceOfType<FrameworkElement>(page.FindName(name));
                Assert.IsTrue(IsDescendantOf(region, page), $"Region left the Evaluation hierarchy: {name}");
                var bounds = BoundsRelativeTo(region, content);
                Assert.IsTrue(
                    bounds.Left >= -GeometryEpsilon &&
                    bounds.Right <= content.ActualWidth + GeometryEpsilon,
                    $"Region is clipped horizontally by Evaluation content: {name} bounds={bounds} contentWidth={content.ActualWidth:0.##}");
                Assert.IsTrue(
                    bounds.Top >= -GeometryEpsilon &&
                    bounds.Bottom <= content.ActualHeight + GeometryEpsilon,
                    $"Region is clipped vertically by Evaluation content: {name} bounds={bounds} contentHeight={content.ActualHeight:0.##}");
                return (Name: name, Bounds: bounds);
            })
            .ToArray();

        for (var first = 0; first < regions.Length; first++)
        {
            for (var second = first + 1; second < regions.Length; second++)
            {
                Assert.IsFalse(
                    HasPositiveAreaOverlap(regions[first].Bounds, regions[second].Bounds),
                    $"Evaluation regions overlap: {regions[first].Name} and {regions[second].Name}");
            }
        }

        var finalRanking = Assert.IsInstanceOfType<FrameworkElement>(page.FindName("EvaluationLowAgentsRegion"));
        if (scroll.ScrollableHeight > GeometryEpsilon)
        {
            scroll.ScrollToEnd();
            scroll.UpdateLayout();
            var viewportBounds = BoundsRelativeTo(scroll, page);
            var finalRankingBounds = BoundsRelativeTo(finalRanking, page);
            Assert.IsTrue(
                IsEffectivelyVisible(finalRanking),
                "The final ranking region must remain visible after scrolling to the end.");
            Assert.IsTrue(
                finalRankingBounds.Top >= viewportBounds.Top - GeometryEpsilon &&
                finalRankingBounds.Bottom <= viewportBounds.Bottom + GeometryEpsilon,
                $"The final ranking region is not fully reachable at scroll end: ranking={finalRankingBounds}, viewport={viewportBounds}, offset={scroll.VerticalOffset:0.##}");
            Assert.IsTrue(
                viewportBounds.Contains(finalRankingBounds),
                $"The final ranking region is outside the scroll viewport at scroll end: ranking={finalRankingBounds}, viewport={viewportBounds}");
            Assert.IsNotEmpty(
                VisibleText(finalRanking),
                "The final ranking region has no visible text after scrolling to the end.");
        }
        else
        {
            var viewportBounds = BoundsRelativeTo(scroll, page);
            var finalRankingBounds = BoundsRelativeTo(finalRanking, page);
            Assert.IsTrue(
                viewportBounds.Contains(finalRankingBounds),
                $"The final ranking region is not visible without scrolling: ranking={finalRankingBounds}, viewport={viewportBounds}");
        }

        scroll.ScrollToHome();
        scroll.UpdateLayout();
        Assert.IsLessThanOrEqualTo(
            GeometryEpsilon,
            scroll.VerticalOffset,
            "Compact Evaluation geometry must restore the viewport to the top after the reachability check.");
    }

    private static bool HasPositiveAreaOverlap(Rect first, Rect second)
    {
        var width = Math.Min(first.Right, second.Right) - Math.Max(first.Left, second.Left);
        var height = Math.Min(first.Bottom, second.Bottom) - Math.Max(first.Top, second.Top);
        return width > GeometryEpsilon && height > GeometryEpsilon;
    }

    private static bool IsDescendantOf(DependencyObject element, DependencyObject ancestor)
    {
        for (DependencyObject? current = element; current is not null; current = VisualTreeHelper.GetParent(current))
        {
            if (ReferenceEquals(current, ancestor))
            {
                return true;
            }
        }

        return false;
    }

    private static Rect BoundsRelativeTo(FrameworkElement element, FrameworkElement ancestor)
    {
        Assert.IsGreaterThan(0d, element.ActualWidth, "Geometry element has no rendered width.");
        Assert.IsGreaterThan(0d, element.ActualHeight, "Geometry element has no rendered height.");
        return element.TransformToAncestor(ancestor).TransformBounds(
            new Rect(0, 0, element.ActualWidth, element.ActualHeight));
    }

    private static void AssertRegions(ShellView shell, EvaluationView page)
    {
        Assert.AreEqual(Visibility.Visible, page.Visibility);
        Assert.AreEqual(
            Visibility.Collapsed,
            Assert.IsInstanceOfType<Grid>(shell.FindName("PlaceholderPage")).Visibility);
        foreach (var regionName in RegionNames)
        {
            var region = Assert.IsInstanceOfType<FrameworkElement>(page.FindName(regionName));
            Assert.AreEqual(Visibility.Visible, region.Visibility, $"Region is hidden: {regionName}");
            Assert.IsGreaterThan(0d, region.ActualWidth, $"Region has no width: {regionName}");
            Assert.IsGreaterThan(0d, region.ActualHeight, $"Region has no height: {regionName}");
        }
    }

    private static void AssertThaiSurface(EvaluationView page, UiLanguageService language)
    {
        AssertVisibleTextContains(page, language["EvaluationAverageScoreToday"]);
        AssertVisibleTextContains(page, language["EvaluationScoreDistributionTitle"]);
        AssertVisibleTextContains(page, language["EvaluationScoreTrendTitle"]);
        AssertVisibleTextContains(page, language["EvaluationDimensionBreakdownTitle"]);
        AssertVisibleTextContains(page, language["EvaluationScoreComparisonTitle"]);
        AssertNoCopyFromOtherLanguage(page, language, UiLanguage.English);
    }

    private static void AssertEnglishSurface(EvaluationView page, UiLanguageService language)
    {
        AssertVisibleTextContains(page, language["EvaluationAverageScoreToday"]);
        AssertVisibleTextContains(page, language["EvaluationScoreDistributionTitle"]);
        AssertVisibleTextContains(page, language["EvaluationTopPerformingAgentsTitle"]);
        AssertNoCopyFromOtherLanguage(page, language, UiLanguage.Thai);
    }

    private static void AssertVisibleTextContains(DependencyObject root, string expected) =>
        Assert.IsTrue(
            VisibleText(root).Any(value => value.Contains(expected, StringComparison.Ordinal)),
            $"Visible text does not contain: {expected}");

    private static void AssertVisibleTextDoesNotContain(DependencyObject root, string unexpected) =>
        Assert.IsFalse(
            VisibleText(root).Any(value => value.Contains(unexpected, StringComparison.Ordinal)),
            $"Visible text contains text from the other language: {unexpected}");

    private static void AssertNoCopyFromOtherLanguage(
        DependencyObject root,
        UiLanguageService language,
        UiLanguage otherLanguage)
    {
        foreach (var key in EvaluationCopyKeys)
        {
            var otherText = language.Text(otherLanguage, key);
            var selectedText = language[key];
            if (string.IsNullOrWhiteSpace(otherText) ||
                otherText.Contains("{", StringComparison.Ordinal) ||
                string.Equals(otherText, selectedText, StringComparison.Ordinal))
            {
                continue;
            }

            AssertVisibleTextDoesNotContain(root, otherText);
        }
    }

    private static IReadOnlyList<string> VisibleText(DependencyObject root) =>
        EnumerateDescendants(root)
            .OfType<TextBlock>()
            .Where(IsEffectivelyVisible)
            .Select(text => new TextRange(text.ContentStart, text.ContentEnd).Text.Trim())
            .Where(text => !string.IsNullOrWhiteSpace(text))
            .ToArray();

    private static IEnumerable<DependencyObject> EnumerateDescendants(DependencyObject parent)
    {
        for (var index = 0; index < VisualTreeHelper.GetChildrenCount(parent); index++)
        {
            var child = VisualTreeHelper.GetChild(parent, index);
            yield return child;
            foreach (var descendant in EnumerateDescendants(child))
            {
                yield return descendant;
            }
        }
    }

    private static bool IsEffectivelyVisible(DependencyObject element)
    {
        for (DependencyObject? current = element;
             current is not null;
             current = VisualTreeHelper.GetParent(current))
        {
            if (current is UIElement { Visibility: not Visibility.Visible })
            {
                return false;
            }
        }

        return true;
    }

    private static void AssertDifferentImages(string firstPath, string secondPath)
    {
        AssertNonBlankImage(firstPath);
        AssertNonBlankImage(secondPath);
        Assert.AreNotEqual(
            DecodedPixelHash(firstPath),
            DecodedPixelHash(secondPath),
            $"Captures must be visually distinct: {firstPath} and {secondPath}");
    }

    private static void AssertNonBlankImage(string path)
    {
        var pixels = DecodePixels(path, out _, out _);
        Assert.IsGreaterThan(8, pixels.Distinct().Count(), $"Evidence image is blank or flat: {path}");
    }

    private static string DecodedPixelHash(string path)
    {
        var pixels = DecodePixels(path, out _, out _);
        return Convert.ToHexString(SHA256.HashData(pixels));
    }

    private static byte[] DecodePixels(string path, out int width, out int height)
    {
        using var input = File.OpenRead(path);
        var frame = BitmapFrame.Create(input, BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnLoad);
        var converted = new FormatConvertedBitmap(frame, PixelFormats.Bgra32, null, 0);
        width = converted.PixelWidth;
        height = converted.PixelHeight;
        var pixels = new byte[width * height * 4];
        converted.CopyPixels(pixels, width * 4, 0);
        return pixels;
    }

    private static void RenderPng(
        FrameworkElement element,
        int pixelWidth,
        int pixelHeight,
        string outputPath)
    {
        Layout(element, pixelWidth, pixelHeight);
        var bitmap = new RenderTargetBitmap(
            pixelWidth,
            pixelHeight,
            96,
            96,
            PixelFormats.Pbgra32);
        bitmap.Render(element);
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        long outputLength;
        using (var output = File.Create(outputPath))
        {
            encoder.Save(output);
            outputLength = output.Length;
        }

        Assert.IsGreaterThan(10_000L, outputLength, $"Evidence image is unexpectedly small: {outputPath}");
        AssertNonBlankImage(outputPath);
    }

    private static void Layout(FrameworkElement element, double width, double height)
    {
        var size = new Size(width, height);
        element.Measure(size);
        element.Arrange(new Rect(size));
        element.UpdateLayout();
    }

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

        Assert.Fail("Could not locate HerdrOps.sln from the WPF test output directory.");
        return string.Empty;
    }
}
