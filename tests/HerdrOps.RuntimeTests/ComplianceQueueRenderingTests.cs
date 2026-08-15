using System.IO;
using System.Security.Cryptography;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using HerdrOps.App.Compliance;
using HerdrOps.App.Localization;
using HerdrOps.App.Views;

namespace HerdrOps.RuntimeTests;

[TestClass]
[DoNotParallelize]
public sealed class ComplianceQueueRenderingTests
{
    private const int ReferenceWidth = 1672;
    private const int ReferenceHeight = 941;
    private const int CompactWidth = 1366;
    private const int CompactHeight = 768;

    private static readonly string[] LocalizedKeys =
    [
        "ComplianceQueuePageTitle",
        "ComplianceQueueSyntheticSource",
        "ComplianceQueueSyntheticBoundary",
        "ComplianceQueueFilterAll",
        "ComplianceQueueFilterSeverity",
        "ComplianceQueueFilterState",
        "ComplianceQueueFilterActor",
        "ComplianceQueueFilterTask",
        "ComplianceQueueFilterReviewer",
        "ComplianceQueueFilterSort",
        "ComplianceQueueColumnSeverity",
        "ComplianceQueueColumnAgent",
        "ComplianceQueueColumnTaskIssue",
        "ComplianceQueueColumnState",
        "ComplianceQueueColumnTime",
        "ComplianceQueueColumnReviewer",
        "ComplianceQueueDetailsTitle",
        "ComplianceQueueEvidenceTitle",
        "ComplianceQueueReviewActionsTitle",
        "ComplianceQueueActionConfirm",
        "ComplianceQueueActionSendToLeader",
        "ComplianceQueueActionEscalateToProjectManager",
        "ComplianceQueueActionDismiss",
        "ComplianceQueueActionUnavailablePreview",
    ];

    [TestMethod]
    public void ActualWpfComplianceQueueRendersAuditedReadOnlyEvidence()
    {
        WpfTestHost.Run(RenderEvidence, TimeSpan.FromSeconds(90));
    }

    private static void RenderEvidence()
    {
        var language = UiLanguageService.Shared;
        var evidenceDirectory = Path.Combine(
            FindRepositoryRoot(),
            "artifacts",
            "design-evidence",
            "v0.5.0",
            "issue-26",
            "compliance-queue");
        Directory.CreateDirectory(evidenceDirectory);

        try
        {
            language.SetLanguage(UiLanguage.Thai);
            var thaiShell = CreateComplianceQueueShell();
            var thaiPage = PreparePrimaryCapture(thaiShell, ReferenceWidth, ReferenceHeight);
            AssertThaiSurface(thaiShell, thaiPage, language);
            AssertPrimaryCriticalCapture(thaiPage, language);
            AssertTypographyAndKeyRegions(thaiPage, language);
            AssertReviewNavigation(thaiPage, language);
            var thaiPrimaryPath = Path.Combine(evidenceDirectory, "compliance-queue-th-1672x941.png");
            var thaiMissingPath = Path.Combine(evidenceDirectory, "compliance-queue-th-missing-1672x941.png");
            RenderPng(
                thaiShell,
                ReferenceWidth,
                ReferenceHeight,
                thaiPrimaryPath);

            RenderMissingEvidencePng(
                thaiShell,
                thaiPage,
                ReferenceWidth,
                ReferenceHeight,
                thaiMissingPath,
                language);
            AssertCaptureBytesDiffer(thaiPrimaryPath, thaiMissingPath);

            var thaiCompactShell = CreateComplianceQueueShell();
            var thaiCompactPage = PreparePrimaryCapture(thaiCompactShell, CompactWidth, CompactHeight);
            AssertThaiSurface(thaiCompactShell, thaiCompactPage, language);
            AssertCompactViewport(thaiCompactShell, thaiCompactPage);
            RenderPng(
                thaiCompactShell,
                CompactWidth,
                CompactHeight,
                Path.Combine(evidenceDirectory, "compliance-queue-th-1366x768.png"));

            var thaiDiagnosticsShell = CreateComplianceQueueShell();
            var thaiDiagnosticsPage = PreparePrimaryCapture(thaiDiagnosticsShell, ReferenceWidth, ReferenceHeight);
            AssertSelectionFailsClosed(thaiDiagnosticsShell, thaiDiagnosticsPage);
            AssertEvidenceProvenanceAndSemanticBrushes(thaiDiagnosticsShell, thaiDiagnosticsPage);
            AssertReadOnlyReviewActions(thaiDiagnosticsPage);

            language.SetLanguage(UiLanguage.English);
            var englishShell = CreateComplianceQueueShell();
            var englishPage = PreparePrimaryCapture(englishShell, ReferenceWidth, ReferenceHeight);
            AssertEnglishSurface(englishShell, englishPage, language);
            AssertPrimaryCriticalCapture(englishPage, language);
            AssertTypographyAndKeyRegions(englishPage, language);
            AssertReviewNavigation(englishPage, language);
            var englishPrimaryPath = Path.Combine(evidenceDirectory, "compliance-queue-en-1672x941.png");
            var englishMissingPath = Path.Combine(evidenceDirectory, "compliance-queue-en-missing-1672x941.png");
            RenderPng(
                englishShell,
                ReferenceWidth,
                ReferenceHeight,
                englishPrimaryPath);

            RenderMissingEvidencePng(
                englishShell,
                englishPage,
                ReferenceWidth,
                ReferenceHeight,
                englishMissingPath,
                language);
            AssertCaptureBytesDiffer(englishPrimaryPath, englishMissingPath);

            var englishDiagnosticsShell = CreateComplianceQueueShell();
            var englishDiagnosticsPage = PreparePrimaryCapture(englishDiagnosticsShell, ReferenceWidth, ReferenceHeight);
            AssertSelectionFailsClosed(englishDiagnosticsShell, englishDiagnosticsPage);
            AssertEvidenceProvenanceAndSemanticBrushes(englishDiagnosticsShell, englishDiagnosticsPage);
            AssertReadOnlyReviewActions(englishDiagnosticsPage);
        }
        finally
        {
            language.SetLanguage(UiLanguage.Thai);
        }
    }

    private static ShellView CreateComplianceQueueShell()
    {
        var shell = ShellView.CreateSyntheticPreview();
        Assert.IsTrue(shell.NavigateTo("compliance-queue"));
        return shell;
    }

    private static ComplianceQueueView PreparePrimaryCapture(
        ShellView shell,
        int width,
        int height)
    {
        Layout(shell, width, height);
        var page = AssertQueueSurface(shell, width, height);
        var state = Assert.IsInstanceOfType<ComplianceQueueState>(page.DataContext);

        state.SelectedSeverityFilter = state.SeverityFilters.Single(item => item.Id == "all");
        state.SelectedStateFilter = state.StateFilters.Single(item => item.Id == "all");
        state.SelectedActorFilter = state.ActorFilters.Single(item => item.Id == "all");
        state.SelectedTaskFilter = state.TaskFilters.Single(item => item.Id == "all");
        state.SelectedReviewerFilter = state.ReviewerFilters.Single(item => item.Id == "all");
        state.SelectedSortOption = state.SortOptions.Single(item => item.Id == "severity");
        Layout(shell, width, height);

        var criticalLabel = state.SeverityFilters.Single(item => item.Id == "critical").Label;
        var critical = state.VisibleIncidents.First(item => item.Severity == criticalLabel);
        state.SelectedIncident = critical;
        var viewport = Assert.IsInstanceOfType<ScrollViewer>(page.FindName("ComplianceDetailsEvidenceViewport"));
        viewport.ScrollToHome();
        Layout(shell, width, height);

        Assert.AreEqual(critical.IncidentId, state.SelectedIncident?.IncidentId);
        Assert.AreEqual(critical.IncidentId, state.SelectedDetail?.IncidentId);
        return page;
    }

    private static void AssertPrimaryCriticalCapture(
        ComplianceQueueView page,
        UiLanguageService language)
    {
        var state = Assert.IsInstanceOfType<ComplianceQueueState>(page.DataContext);
        var selected = state.SelectedIncident;
        var detail = state.SelectedDetail;
        Assert.IsNotNull(selected);
        Assert.IsNotNull(detail);
        Assert.AreEqual(selected!.IncidentId, detail!.IncidentId);
        Assert.IsTrue(
            detail.EvidenceItems.Any(item => item.Availability == ComplianceQueueEvidenceAvailability.Missing),
            "The primary Critical incident must carry an explicit Missing evidence record.");
        AssertVisibleTextContains(page, language["ComplianceQueueDetailsTitle"]);
        AssertVisibleTextContains(page, selected.Severity);
    }

    private static void RenderMissingEvidencePng(
        ShellView shell,
        ComplianceQueueView page,
        int width,
        int height,
        string outputPath,
        UiLanguageService language)
    {
        var state = Assert.IsInstanceOfType<ComplianceQueueState>(page.DataContext);
        var selectedIncidentId = state.SelectedIncident?.IncidentId;
        Assert.IsNotNull(selectedIncidentId);

        state.SelectedSeverityFilter = state.SeverityFilters.Single(item => item.Id == "critical");
        state.SelectedStateFilter = state.StateFilters.Single(item => item.Id == "all");
        state.SelectedActorFilter = state.ActorFilters.Single(item => item.Id == "all");
        state.SelectedTaskFilter = state.TaskFilters.Single(item => item.Id == "TASK-56");
        state.SelectedReviewerFilter = state.ReviewerFilters.Single(item => item.Id == "all");
        state.SelectedSortOption = state.SortOptions.Single(item => item.Id == "severity");
        Layout(shell, width, height);

        Assert.HasCount(1, state.VisibleIncidents, "The missing-evidence capture must use a deterministic TASK-56 filter.");
        Assert.AreEqual(selectedIncidentId, state.SelectedIncident?.IncidentId);
        Assert.AreEqual(selectedIncidentId, state.SelectedDetail?.IncidentId);
        Assert.AreEqual("TASK-56", state.SelectedIncident?.TaskId);
        AssertVisibleTextContains(page, "TASK-56");

        var viewport = Assert.IsInstanceOfType<ScrollViewer>(page.FindName("ComplianceDetailsEvidenceViewport"));
        viewport.ScrollToEnd();
        viewport.UpdateLayout();
        Layout(shell, width, height);
        viewport.ScrollToEnd();
        viewport.UpdateLayout();
        var missingText = AssertMissingEvidenceVisible(page, viewport, language["ComplianceQueueEvidenceMissing"]);
        var renderedTextBounds = BoundsRelativeTo(missingText, shell);
        RenderPng(shell, width, height, outputPath);
        AssertRenderedPngContainsTextInk(outputPath, renderedTextBounds);

        ResetPrimaryFilters(state);
        Layout(shell, width, height);
        var criticalLabel = state.SeverityFilters.Single(item => item.Id == "critical").Label;
        state.SelectedIncident = state.VisibleIncidents.First(item => item.Severity == criticalLabel);
        viewport.ScrollToHome();
        Layout(shell, width, height);
        Assert.AreEqual(selectedIncidentId, state.SelectedIncident?.IncidentId);
        Assert.AreEqual(selectedIncidentId, state.SelectedDetail?.IncidentId);
    }

    private static void AssertCaptureBytesDiffer(string primaryPath, string missingPath)
    {
        var primaryBytes = File.ReadAllBytes(primaryPath);
        var missingBytes = File.ReadAllBytes(missingPath);
        var primaryHash = Convert.ToHexString(SHA256.HashData(primaryBytes));
        var missingHash = Convert.ToHexString(SHA256.HashData(missingBytes));

        Assert.AreNotEqual(primaryHash, missingHash, $"Missing capture must differ from primary capture: {primaryPath}");
        Assert.IsFalse(primaryBytes.SequenceEqual(missingBytes), "Missing capture bytes must differ from the primary capture.");
    }

    private static void ResetPrimaryFilters(ComplianceQueueState state)
    {
        state.SelectedSeverityFilter = state.SeverityFilters.Single(item => item.Id == "all");
        state.SelectedStateFilter = state.StateFilters.Single(item => item.Id == "all");
        state.SelectedActorFilter = state.ActorFilters.Single(item => item.Id == "all");
        state.SelectedTaskFilter = state.TaskFilters.Single(item => item.Id == "all");
        state.SelectedReviewerFilter = state.ReviewerFilters.Single(item => item.Id == "all");
        state.SelectedSortOption = state.SortOptions.Single(item => item.Id == "severity");
    }

    private static TextBlock AssertMissingEvidenceVisible(
        ComplianceQueueView page,
        ScrollViewer viewport,
        string expected)
    {
        var evidenceRegion = Assert.IsInstanceOfType<FrameworkElement>(page.FindName("ComplianceEvidenceRegion"));
        var missingText = Descendants<TextBlock>(evidenceRegion)
            .Where(IsEffectivelyVisible)
            .FirstOrDefault(text => text.Text.Contains(expected, StringComparison.Ordinal));
        Assert.IsNotNull(missingText, $"Missing evidence label is not rendered: {expected}");

        var pageViewport = BoundsRelativeTo(viewport, page);
        var labelBounds = BoundsRelativeTo(missingText!, page);
        Assert.IsTrue(
            pageViewport.IntersectsWith(labelBounds),
            $"Missing evidence label is outside the evidence viewport: {expected}; offset={viewport.VerticalOffset:0.##}, extent={viewport.ExtentHeight:0.##}, viewport={viewport.ViewportHeight:0.##}, viewportBounds={pageViewport}, labelBounds={labelBounds}");
        return missingText;
    }

    private static void AssertRenderedPngContainsTextInk(string outputPath, Rect textBounds)
    {
        var decoder = new PngBitmapDecoder(
            new Uri(outputPath, UriKind.Absolute),
            BitmapCreateOptions.PreservePixelFormat,
            BitmapCacheOption.OnLoad);
        var frame = decoder.Frames[0];
        var converted = new FormatConvertedBitmap(frame, PixelFormats.Bgra32, null, 0);
        var stride = converted.PixelWidth * 4;
        var pixels = new byte[stride * converted.PixelHeight];
        converted.CopyPixels(pixels, stride, 0);

        var left = Math.Clamp((int)Math.Floor(textBounds.Left), 0, converted.PixelWidth - 1);
        var top = Math.Clamp((int)Math.Floor(textBounds.Top), 0, converted.PixelHeight - 1);
        var right = Math.Clamp((int)Math.Ceiling(textBounds.Right), left + 1, converted.PixelWidth);
        var bottom = Math.Clamp((int)Math.Ceiling(textBounds.Bottom), top + 1, converted.PixelHeight);
        var brightPixels = 0;

        for (var y = top; y < bottom; y++)
        {
            for (var x = left; x < right; x++)
            {
                var offset = (y * stride) + (x * 4);
                if (Math.Max(pixels[offset], Math.Max(pixels[offset + 1], pixels[offset + 2])) > 120)
                {
                    brightPixels++;
                }
            }
        }

        Assert.IsGreaterThan(0, brightPixels, $"Rendered PNG contains no visible Missing-label pixels in {outputPath}");
    }

    private static void AssertTypographyAndKeyRegions(
        ComplianceQueueView page,
        UiLanguageService language)
    {
        var state = Assert.IsInstanceOfType<ComplianceQueueState>(page.DataContext);
        var selected = state.SelectedIncident;
        Assert.IsNotNull(selected);
        var detailsTitle = language["ComplianceQueueDetailsTitle"];
        var evidenceTitle = language["ComplianceQueueEvidenceTitle"];
        var actionsTitle = language["ComplianceQueueReviewActionsTitle"];

        foreach (var title in new[] { detailsTitle, evidenceTitle, actionsTitle })
        {
            Assert.IsTrue(
                Descendants<TextBlock>(page).Any(text =>
                    IsEffectivelyVisible(text) &&
                    text.Text.Contains(title, StringComparison.Ordinal) &&
                    text.FontSize >= 13),
                $"Key region title is too small or missing: {title}");
        }

        Assert.IsTrue(
            Descendants<TextBlock>(page).Any(text =>
                IsEffectivelyVisible(text) &&
                string.Equals(text.Text, selected!.Actor, StringComparison.Ordinal) &&
                text.FontSize >= 11),
            "Selected Agent text did not meet the dense readability minimum.");
        Assert.IsTrue(
            Descendants<TextBlock>(page).Any(text =>
                IsEffectivelyVisible(text) &&
                string.Equals(text.Text, selected.Title, StringComparison.Ordinal) &&
                text.FontSize >= 11),
            "Selected issue text did not meet the dense readability minimum.");
        AssertQueueRowReadability(page);
    }

    private static void AssertOuterColumnHierarchy(ComplianceQueueView page, int width)
    {
        var mainColumn = Assert.IsInstanceOfType<FrameworkElement>(page.FindName("ComplianceQueueMainColumn"));
        var detailColumn = Assert.IsInstanceOfType<FrameworkElement>(page.FindName("ComplianceQueueDetailColumn"));
        var summary = Assert.IsInstanceOfType<FrameworkElement>(page.FindName("ComplianceSummaryCardsRegion"));
        var detailsViewport = Assert.IsInstanceOfType<FrameworkElement>(page.FindName("ComplianceDetailsEvidenceViewport"));
        var actions = Assert.IsInstanceOfType<FrameworkElement>(page.FindName("ComplianceActionsRegion"));

        var mainBounds = BoundsRelativeTo(mainColumn, page);
        var detailBounds = BoundsRelativeTo(detailColumn, page);
        var summaryBounds = BoundsRelativeTo(summary, page);
        var detailsBounds = BoundsRelativeTo(detailsViewport, page);
        var actionsBounds = BoundsRelativeTo(actions, page);

        Assert.IsGreaterThanOrEqualTo(page.ActualWidth * 0.68, detailBounds.Left, $"The detail column is too far left at {width}px: {detailBounds}");
        Assert.IsLessThanOrEqualTo(page.ActualWidth * 0.80, detailBounds.Left, $"The detail column is too far right at {width}px: {detailBounds}");
        Assert.IsLessThanOrEqualTo(detailBounds.Left + 0.5, mainBounds.Right, "The main and detail columns overlap.");
        Assert.IsLessThanOrEqualTo(1.5, Math.Abs(summaryBounds.Top - detailBounds.Top), "The detail column must begin beside the summary cards.");
        Assert.IsLessThanOrEqualTo(1.5, Math.Abs(detailsBounds.Left - detailBounds.Left), "Details are not docked inside the right column.");
        Assert.IsLessThanOrEqualTo(1.5, Math.Abs(actionsBounds.Left - detailBounds.Left), "Review Actions are not docked inside the right column.");
        Assert.IsGreaterThanOrEqualTo(detailBounds.Bottom - 1.5, actionsBounds.Bottom, "Review Actions do not reach the bottom of the right column.");
    }

    private static void AssertQueueRowReadability(ComplianceQueueView page)
    {
        var state = Assert.IsInstanceOfType<ComplianceQueueState>(page.DataContext);
        var row = state.VisibleIncidents.Skip(1).First();
        var surface = ResolveBrushColor(page, "HerdrOps.Brush.Surface");
        var primary = ResolveBrushColor(page, "HerdrOps.Brush.TextPrimary");
        var secondary = ResolveBrushColor(page, "HerdrOps.Brush.TextSecondary");

        foreach (var (value, minimumSize) in new[]
                 {
                     (row.Actor, 12d),
                     (row.Title, 12d),
                     (row.Time, 11d),
                     (row.Reviewer, 11d),
                 })
        {
            var text = FindQueueRowText(page, row, value);
            Assert.AreEqual(primary, Assert.IsInstanceOfType<SolidColorBrush>(text.Foreground).Color, $"Primary queue text uses the wrong brush: {value}");
            Assert.IsGreaterThanOrEqualTo(minimumSize, text.FontSize, $"Primary queue text is too small: {value}");
            Assert.IsGreaterThanOrEqualTo(4.5, ContrastRatio(primary, surface), $"Primary queue text lacks contrast: {value}");
        }

        foreach (var value in new[] { row.ReviewerRole, row.Description, row.RelativeTime })
        {
            var text = FindQueueRowText(page, row, value);
            Assert.AreEqual(secondary, Assert.IsInstanceOfType<SolidColorBrush>(text.Foreground).Color, $"Secondary queue text uses the wrong brush: {value}");
            Assert.IsGreaterThanOrEqualTo(10d, text.FontSize, $"Secondary queue text is too small: {value}");
            Assert.IsGreaterThanOrEqualTo(3d, ContrastRatio(secondary, surface), $"Secondary queue text lacks contrast: {value}");
        }
    }

    private static TextBlock FindQueueRowText(
        ComplianceQueueView page,
        ComplianceQueueIncidentRow row,
        string value)
    {
        var text = Descendants<TextBlock>(page)
            .Where(IsEffectivelyVisible)
            .Where(item => item.DataContext is ComplianceQueueIncidentRow candidate && candidate.IncidentId == row.IncidentId)
            .FirstOrDefault(item => string.Equals(item.Text, value, StringComparison.Ordinal));
        Assert.IsNotNull(text, $"Queue row text is not rendered for {row.IncidentId}: {value}");
        return text!;
    }

    private static Color ResolveBrushColor(ComplianceQueueView page, string key) =>
        Assert.IsInstanceOfType<SolidColorBrush>(page.TryFindResource(key)).Color;

    private static double ContrastRatio(Color first, Color second)
    {
        var lighter = Math.Max(RelativeLuminance(first), RelativeLuminance(second));
        var darker = Math.Min(RelativeLuminance(first), RelativeLuminance(second));
        return (lighter + 0.05) / (darker + 0.05);
    }

    private static double RelativeLuminance(Color color)
    {
        static double Convert(byte component)
        {
            var value = component / 255d;
            return value <= 0.04045
                ? value / 12.92
                : Math.Pow((value + 0.055) / 1.055, 2.4);
        }

        return (0.2126 * Convert(color.R)) +
               (0.7152 * Convert(color.G)) +
               (0.0722 * Convert(color.B));
    }

    private static void AssertReviewNavigation(
        ComplianceQueueView page,
        UiLanguageService language)
    {
        var navigation = Descendants<Button>(page)
            .Where(button => button.Tag is string tag && tag.StartsWith("ComplianceNavigation", StringComparison.Ordinal))
            .ToArray();
        Assert.HasCount(3, navigation, "The queue footer must expose three non-mutating navigation affordances.");
        Assert.IsTrue(navigation.All(button => !button.IsEnabled));

        var expected = new Dictionary<string, (string Name, string Help)>(StringComparer.Ordinal)
        {
            ["ComplianceNavigationFirst"] = (
                language["ComplianceQueuePaginationPreviousName"],
                language["ComplianceQueuePaginationPreviousHelp"]),
            ["ComplianceNavigationCurrent"] = (
                language["ComplianceQueuePaginationCurrentName"],
                language["ComplianceQueuePaginationCurrentHelp"]),
            ["ComplianceNavigationNext"] = (
                language["ComplianceQueuePaginationNextName"],
                language["ComplianceQueuePaginationNextHelp"]),
        };

        foreach (var button in navigation)
        {
            var tag = Assert.IsInstanceOfType<string>(button.Tag);
            Assert.IsTrue(expected.ContainsKey(tag));
            Assert.AreEqual(expected[tag].Name, AutomationProperties.GetName(button), tag);
            Assert.AreEqual(expected[tag].Help, AutomationProperties.GetHelpText(button), tag);
        }

        var state = Assert.IsInstanceOfType<ComplianceQueueState>(page.DataContext);
        AssertVisibleTextContains(page, state.VisibleRangeLabel);
        Assert.IsTrue(
            state.VisibleRangeLabel.Contains(state.VisibleIncidents.Count.ToString(), StringComparison.Ordinal),
            "Pagination range must communicate the filtered visible count.");
    }

    private static void AssertCompactViewport(ShellView shell, ComplianceQueueView page)
    {
        Layout(shell, CompactWidth, CompactHeight);
        var pageBounds = new Rect(0, 0, page.ActualWidth, page.ActualHeight);
        var actions = Descendants<Button>(page)
            .Where(button => IsEffectivelyVisible(button))
            .Where(button => button.DataContext is ComplianceQueueReviewAction)
            .ToArray();
        Assert.HasCount(4, actions, "All four review actions must remain visible in the compact viewport.");

        foreach (var action in actions)
        {
            var bounds = BoundsRelativeTo(action, page);
            Assert.IsTrue(
                bounds.Top >= -0.5 && bounds.Bottom <= pageBounds.Bottom + 0.5,
                $"Review action is clipped by the compact viewport: {action.DataContext}");
        }

        var verticalScrollBars = Descendants<ScrollBar>(page)
            .Where(bar => IsEffectivelyVisible(bar) && bar.Orientation == Orientation.Vertical)
            .ToArray();
        Assert.IsNotEmpty(verticalScrollBars, "The compact queue must expose a vertical scroll affordance.");
        Assert.IsTrue(
            verticalScrollBars.All(bar => bar.ActualWidth > 0 && bar.ActualWidth <= 12),
            $"Compact scrollbar widths were not applied: {string.Join(", ", verticalScrollBars.Select(bar => bar.ActualWidth.ToString("0.##")))}");
        Assert.IsTrue(verticalScrollBars.All(bar => bar.Template is not null));
    }

    private static ComplianceQueueView AssertQueueSurface(
        ShellView shell,
        int width,
        int height)
    {
        var page = Assert.IsInstanceOfType<ComplianceQueueView>(shell.FindName("ComplianceQueuePage"));
        Assert.AreEqual(Visibility.Visible, page.Visibility);
        Assert.AreEqual(
            Visibility.Collapsed,
            Assert.IsInstanceOfType<Grid>(shell.FindName("PlaceholderPage")).Visibility);

        foreach (var regionName in new[]
                 {
                      "ComplianceSummaryCardsRegion",
                      "ComplianceFiltersRegion",
                      "ComplianceIncidentTableRegion",
                      "ComplianceQueueFooter",
                      "ComplianceDetailsRegion",
                      "ComplianceDetailsEvidenceViewport",
                      "ComplianceEvidenceRegion",
                     "ComplianceActionsRegion",
                 })
        {
            var region = Assert.IsInstanceOfType<FrameworkElement>(page.FindName(regionName));
            Assert.AreEqual(Visibility.Visible, region.Visibility, $"Region is hidden: {regionName}");
            Assert.IsGreaterThan(0d, region.ActualWidth, $"Region has no width at {width}x{height}: {regionName}");
            Assert.IsGreaterThan(0d, region.ActualHeight, $"Region has no height at {width}x{height}: {regionName}");
        }

        var summaryCards = Assert.IsInstanceOfType<ItemsControl>(page.FindName("ComplianceSummaryCardsRegion"));
        Assert.AreEqual(4, summaryCards.Items.Count, "The approved queue must preserve all four summary cards.");
        AssertOuterColumnHierarchy(page, width);

        var state = Assert.IsInstanceOfType<ComplianceQueueState>(page.DataContext);
        Assert.IsTrue(state.IsSyntheticPreview);
        Assert.IsNotEmpty(state.VisibleIncidents);
        Assert.IsNotNull(state.SelectedIncident);
        Assert.AreEqual(state.SelectedIncident?.IncidentId, state.SelectedDetail?.IncidentId);

        var filters = Descendants<ComboBox>(page).Where(IsEffectivelyVisible).ToArray();
        Assert.IsGreaterThanOrEqualTo(5, filters.Length, "The approved queue requires five filter controls.");

        var incidentLists = Descendants<ListBox>(page)
            .Where(IsEffectivelyVisible)
            .Where(list => list.Items.OfType<ComplianceQueueIncidentRow>().Any())
            .ToArray();
        Assert.HasCount(1, incidentLists, "The queue must expose one selectable incident list.");
        Assert.AreEqual(
            state.SelectedIncident?.IncidentId,
            (incidentLists[0].SelectedItem as ComplianceQueueIncidentRow)?.IncidentId);

        return page;
    }

    private static void AssertThaiSurface(
        ShellView shell,
        ComplianceQueueView page,
        UiLanguageService language)
    {
        AssertVisibleTextContains(page, language["ComplianceQueuePageTitle"]);
        AssertVisibleTextContains(page, language["ComplianceQueueEvidenceTitle"]);
        AssertVisibleTextContains(page, language["ComplianceQueueReviewActionsTitle"]);
        AssertVisibleTextContains(page, language["ComplianceQueueActionUnavailablePreview"]);
        AssertNoVisibleKnownEnglishCopy(page, language);
        AssertNoUnapprovedEnglishSurface(page);
        Assert.IsTrue(
            VisibleText(shell).Any(value => value.Contains(language["ComplianceQueuePageTitle"], StringComparison.Ordinal)),
            "Thai page title is not visible in the shared shell.");
    }

    private static void AssertEnglishSurface(
        ShellView shell,
        ComplianceQueueView page,
        UiLanguageService language)
    {
        AssertVisibleTextContains(page, language["ComplianceQueuePageTitle"]);
        AssertVisibleTextContains(page, language["ComplianceQueueEvidenceTitle"]);
        AssertVisibleTextContains(page, language["ComplianceQueueReviewActionsTitle"]);
        AssertVisibleTextContains(page, language["ComplianceQueueActionUnavailablePreview"]);
        AssertNoVisibleThaiCopy(shell);
        AssertNoVisibleThaiCopy(page);
    }

    private static void AssertSelectionFailsClosed(
        ShellView shell,
        ComplianceQueueView page)
    {
        var state = Assert.IsInstanceOfType<ComplianceQueueState>(page.DataContext);
        var queue = Descendants<ListBox>(page)
            .Single(list => list.Items.OfType<ComplianceQueueIncidentRow>().Any());
        var selected = state.SelectedIncident;
        Assert.IsNotNull(selected);
        Assert.AreEqual(selected!.IncidentId, state.SelectedDetail?.IncidentId);
        Assert.AreEqual(selected.IncidentId, (queue.SelectedItem as ComplianceQueueIncidentRow)?.IncidentId);

        var external = state.VisibleIncidents.First(item => item.IncidentId != selected.IncidentId);
        state.SelectedStateFilter = state.StateFilters.Single(item => item.Id == "suspected");
        Layout(shell, ReferenceWidth, ReferenceHeight);

        state.SelectedIncident = external;
        Layout(shell, ReferenceWidth, ReferenceHeight);

        var visibleIds = state.VisibleIncidents.Select(item => item.IncidentId).ToHashSet(StringComparer.Ordinal);
        Assert.IsTrue(
            state.SelectedIncident is null || visibleIds.Contains(state.SelectedIncident.IncidentId),
            "An incident outside the active filter must not remain selected.");
        Assert.AreEqual(state.SelectedIncident?.IncidentId, state.SelectedDetail?.IncidentId);
        Assert.IsTrue(
            queue.SelectedItem is null ||
            visibleIds.Contains(((ComplianceQueueIncidentRow)queue.SelectedItem).IncidentId),
            "The WPF list must fail closed for an out-of-filter selection.");

        state.SelectedStateFilter = state.StateFilters.Single(item => item.Id == "all");
        Layout(shell, ReferenceWidth, ReferenceHeight);
        var valid = state.VisibleIncidents.Last();
        state.SelectedIncident = valid;
        Layout(shell, ReferenceWidth, ReferenceHeight);
        Assert.AreEqual(valid.IncidentId, state.SelectedDetail?.IncidentId);
        Assert.AreEqual(valid.IncidentId, (queue.SelectedItem as ComplianceQueueIncidentRow)?.IncidentId);
    }

    private static void AssertEvidenceProvenanceAndSemanticBrushes(
        ShellView shell,
        ComplianceQueueView page)
    {
        var state = Assert.IsInstanceOfType<ComplianceQueueState>(page.DataContext);
        var allEvidence = new List<ComplianceQueueEvidenceItem>();

        foreach (var row in state.VisibleIncidents)
        {
            state.SelectedIncident = row;
            Layout(shell, ReferenceWidth, ReferenceHeight);
            var detail = state.SelectedDetail;
            Assert.IsNotNull(detail);
            Assert.AreEqual(row.IncidentId, detail!.IncidentId);
            Assert.IsNotEmpty(detail.EvidenceItems);
            allEvidence.AddRange(detail.EvidenceItems);

            foreach (var evidence in detail.EvidenceItems)
            {
                Assert.IsFalse(string.IsNullOrWhiteSpace(evidence.EvidenceId));
                Assert.IsFalse(string.IsNullOrWhiteSpace(evidence.FileName));
                Assert.IsFalse(string.IsNullOrWhiteSpace(evidence.Source));
                Assert.IsFalse(string.IsNullOrWhiteSpace(evidence.AvailabilityLabel));
                Assert.AreEqual(row.IncidentId, evidence.IncidentId);
                Assert.AreEqual(row.TaskId, evidence.TaskId);
                Assert.AreEqual(row.Actor, evidence.Actor);
                AssertVisibleTextContains(page, evidence.FileName);
                AssertVisibleTextContains(page, evidence.AvailabilityLabel);
            }
        }

        Assert.IsTrue(
            allEvidence.Any(item => item.Availability == ComplianceQueueEvidenceAvailability.Present),
            "Synthetic evidence must expose an explicit Present provenance state.");
        Assert.IsTrue(
            allEvidence.Any(item => item.Availability == ComplianceQueueEvidenceAvailability.Missing),
            "Synthetic evidence must expose an explicit Missing provenance state.");

        var rows = state.VisibleIncidents;
        Assert.IsTrue(rows.All(row => row.SeverityBrushKey.StartsWith(
            "HerdrOps.Brush.Severity.", StringComparison.Ordinal)));
        Assert.IsTrue(rows.All(row => row.StateBrushKey.StartsWith(
            "HerdrOps.Brush.Review.", StringComparison.Ordinal)));
        Assert.IsTrue(rows.Any(row => row.SeverityBrushKey != row.StateBrushKey));

        foreach (var key in rows.Select(row => row.SeverityBrushKey)
                     .Concat(rows.Select(row => row.StateBrushKey))
                     .Distinct(StringComparer.Ordinal))
        {
            Assert.IsInstanceOfType<Brush>(page.TryFindResource(key));
        }
    }

    private static void AssertReadOnlyReviewActions(ComplianceQueueView page)
    {
        var state = Assert.IsInstanceOfType<ComplianceQueueState>(page.DataContext);
        var disabledForeground = ResolveBrushColor(page, "HerdrOps.Brush.TextSecondary");
        Assert.HasCount(4, state.ReviewActions);
        Assert.IsTrue(state.ReviewActions.All(action => action.IsVisible));
        Assert.IsTrue(state.ReviewActions.All(action => !action.IsEnabled));
        Assert.IsTrue(state.ReviewActions.Any(action => action.IsRoleApplicable));
        Assert.IsTrue(state.ReviewActions.Any(action => !action.IsRoleApplicable));
        Assert.IsTrue(state.ReviewActions.All(action =>
            !string.IsNullOrWhiteSpace(action.RequiredRoleLabel) &&
            !string.IsNullOrWhiteSpace(action.UnavailableReason) &&
            !string.IsNullOrWhiteSpace(action.AutomationName)));

        var buttons = Descendants<Button>(page)
            .Where(button => IsEffectivelyVisible(button))
            .Where(button => button.DataContext is ComplianceQueueReviewAction)
            .ToArray();
        Assert.HasCount(state.ReviewActions.Count, buttons);

        foreach (var button in buttons)
        {
            var action = Assert.IsInstanceOfType<ComplianceQueueReviewAction>(button.DataContext);
            Assert.IsFalse(button.IsEnabled);
            Assert.AreEqual(disabledForeground, Assert.IsInstanceOfType<SolidColorBrush>(button.Foreground).Color);
            Assert.IsLessThan(1d, button.Opacity, $"Disabled action is not visually distinct: {action.Id}");
            Assert.IsTrue(
                ToolTipService.GetShowOnDisabled(button),
                $"Disabled action has no disabled tooltip: {action.Id}");
            Assert.IsFalse(
                string.IsNullOrWhiteSpace(button.ToolTip?.ToString()),
                $"Disabled action has no tooltip content: {action.Id}");
            Assert.IsFalse(
                string.IsNullOrWhiteSpace(AutomationProperties.GetHelpText(button)),
                $"Disabled action has no AutomationProperties.HelpText: {action.Id}");
        }
    }

    private static void AssertNoVisibleKnownEnglishCopy(
        DependencyObject root,
        UiLanguageService language)
    {
        foreach (var key in LocalizedKeys)
        {
            var english = language.Text(UiLanguage.English, key);
            var thai = language.Text(UiLanguage.Thai, key);
            if (string.IsNullOrWhiteSpace(english) || string.Equals(english, thai, StringComparison.Ordinal))
            {
                continue;
            }

            AssertVisibleTextDoesNotContain(root, english);
        }
    }

    private static void AssertNoUnapprovedEnglishSurface(DependencyObject root)
    {
        var allowedProperNames = new[]
        {
            "Herdr",
            "HerdrOps",
            "Git",
            "Project Manager",
            "PM Secretary",
            "Backend Leader",
            "Security Lead",
            "Backend Worker 01",
            "Backend Worker 02",
            "Frontend Worker 01",
            "Frontend Worker 02",
            "Security Worker",
            "Test Worker",
            "DevOps Worker",
            "PM",
            "TW",
            "BW",
            "FW",
            "DW",
            "PS",
            "SW",
            "BL",
            "SL",
        };

        var violations = new List<string>();
        foreach (var value in VisibleText(root))
        {
            var remaining = value;
            foreach (var literal in allowedProperNames)
            {
                remaining = Regex.Replace(
                    remaining,
                    Regex.Escape(literal),
                    string.Empty,
                    RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
            }

            remaining = Regex.Replace(remaining, @"synthetic://[^\s]+", string.Empty, RegexOptions.IgnoreCase);
            remaining = Regex.Replace(remaining, @"(?:TASK|INC|RULE|EVID)-[A-Z0-9-]+", string.Empty, RegexOptions.IgnoreCase);
            remaining = Regex.Replace(remaining, @"[A-Za-z0-9_]+\.(?:diff|yaml|cs|xlsx|json|md|yml)", string.Empty, RegexOptions.IgnoreCase);
            remaining = Regex.Replace(remaining, @"Issue\s*#\d+", string.Empty, RegexOptions.IgnoreCase);
            remaining = Regex.Replace(remaining, @"[0-9A-F]{16,}", string.Empty, RegexOptions.IgnoreCase);

            var latin = Regex.Matches(remaining, @"[A-Za-z]+", RegexOptions.CultureInvariant)
                .Select(match => match.Value)
                .ToArray();
            if (latin.Length > 0)
            {
                violations.Add($"{value} => {string.Join(", ", latin)}");
            }
        }

        Assert.IsEmpty(
            violations,
            $"Thai Compliance Queue surface contains unapproved English literals: {string.Join(" | ", violations)}");
    }

    private static void AssertNoVisibleThaiCopy(DependencyObject root)
    {
        var thaiCopy = VisibleText(root)
            .Where(value => Regex.IsMatch(value, "[ก-๙]", RegexOptions.CultureInvariant))
            .ToArray();
        Assert.IsEmpty(thaiCopy, $"English mode contains Thai copy: {string.Join(" | ", thaiCopy)}");
    }

    private static void AssertVisibleTextContains(DependencyObject root, string expected) =>
        Assert.IsTrue(
            VisibleText(root).Any(value => value.Contains(expected, StringComparison.Ordinal)),
            $"Visible text does not contain: {expected}");

    private static void AssertVisibleTextDoesNotContain(DependencyObject root, string unexpected) =>
        Assert.IsFalse(
            VisibleText(root).Any(value => value.Contains(unexpected, StringComparison.Ordinal)),
            $"Visible text contains English copy in Thai mode: {unexpected}");

    private static IReadOnlyList<string> VisibleText(DependencyObject root) =>
        Descendants<DependencyObject>(root)
            .OfType<TextBlock>()
            .Where(IsEffectivelyVisible)
            .Select(text => new TextRange(text.ContentStart, text.ContentEnd).Text.Trim())
            .Where(text => !string.IsNullOrWhiteSpace(text))
            .ToArray();

    private static IEnumerable<T> Descendants<T>(DependencyObject root)
        where T : DependencyObject
    {
        if (root is T typedRoot)
        {
            yield return typedRoot;
        }

        for (var index = 0; index < VisualTreeHelper.GetChildrenCount(root); index++)
        {
            var child = VisualTreeHelper.GetChild(root, index);
            foreach (var descendant in Descendants<T>(child))
            {
                yield return descendant;
            }
        }
    }

    private static bool IsEffectivelyVisible(DependencyObject element)
    {
        for (DependencyObject? current = element; current is not null; current = VisualTreeHelper.GetParent(current))
        {
            if (current is UIElement { Visibility: not Visibility.Visible })
            {
                return false;
            }
        }

        return true;
    }

    private static Rect BoundsRelativeTo(FrameworkElement element, FrameworkElement ancestor)
    {
        Assert.IsGreaterThan(0d, element.ActualWidth, "Element has no rendered width.");
        Assert.IsGreaterThan(0d, element.ActualHeight, "Element has no rendered height.");
        return element.TransformToAncestor(ancestor).TransformBounds(
            new Rect(0, 0, element.ActualWidth, element.ActualHeight));
    }

    private static void Layout(FrameworkElement element, int width, int height)
    {
        var size = new Size(width, height);
        element.Measure(size);
        element.Arrange(new Rect(size));
        element.UpdateLayout();
    }

    private static void RenderPng(
        FrameworkElement element,
        int width,
        int height,
        string outputPath)
    {
        Layout(element, width, height);
        var bitmap = new RenderTargetBitmap(width, height, 96, 96, PixelFormats.Pbgra32);
        bitmap.Render(element);
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using var output = File.Create(outputPath);
        encoder.Save(output);
        Assert.IsGreaterThan(10_000L, output.Length, $"Evidence image was unexpectedly small: {outputPath}");
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

        Assert.Fail("Could not locate HerdrOps.sln from the runtime test output directory.");
        return string.Empty;
    }
}
