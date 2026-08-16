using System.IO;
using System.Security.Cryptography;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using HerdrOps.App.Localization;
using HerdrOps.App.Summaries;
using HerdrOps.App.Views;
using HerdrOps.Domain.Summaries;

namespace HerdrOps.RuntimeTests;

[TestClass]
[DoNotParallelize]
public sealed class DailySummaryRenderingTests
{
    private const int ReferenceWidth = 1672;
    private const int ReferenceHeight = 941;
    private const int CompactWidth = 1366;
    private const int CompactHeight = 768;

    [TestMethod]
    public void ActualWpfDailySummaryRendersSyntheticEvidenceInBothLanguages()
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
            "v0.6.0",
            "issue-32",
            "daily-summary");
        Directory.CreateDirectory(evidenceDirectory);

        try
        {
            language.SetLanguage(UiLanguage.Thai);
            var thaiShell = CreateShell();
            Layout(thaiShell, ReferenceWidth, ReferenceHeight);
            AssertSurface(thaiShell, thaiShell.FindName("DailySummaryPage"), language, expectThai: true);
            var thaiPath = Path.Combine(evidenceDirectory, "daily-summary-th-1672x941.png");
            RenderPng(thaiShell, ReferenceWidth, ReferenceHeight, thaiPath);

            var thaiCompact = CreateShell();
            Layout(thaiCompact, CompactWidth, CompactHeight);
            AssertSurface(thaiCompact, thaiCompact.FindName("DailySummaryPage"), language, expectThai: true, assertCompact: true);
            var compactPath = Path.Combine(evidenceDirectory, "daily-summary-th-1366x768.png");
            RenderPng(thaiCompact, CompactWidth, CompactHeight, compactPath);

            var missingShell = CreateShell();
            var missingPage = Assert.IsInstanceOfType<DailySummaryView>(missingShell.FindName("DailySummaryPage"));
            missingPage.DataContext = DailySummaryState.CreateUnavailable();
            Layout(missingShell, ReferenceWidth, ReferenceHeight);
            AssertSurface(missingShell, missingPage, language, expectThai: true, expectMissing: true);
            var missingPath = Path.Combine(evidenceDirectory, "daily-summary-th-missing-1672x941.png");
            RenderPng(missingShell, ReferenceWidth, ReferenceHeight, missingPath);
            Assert.AreNotEqual(PixelHash(thaiPath), PixelHash(missingPath));

            language.SetLanguage(UiLanguage.English);
            var englishShell = CreateShell();
            Layout(englishShell, ReferenceWidth, ReferenceHeight);
            AssertSurface(englishShell, englishShell.FindName("DailySummaryPage"), language, expectThai: false);
            var englishPath = Path.Combine(evidenceDirectory, "daily-summary-en-1672x941.png");
            RenderPng(englishShell, ReferenceWidth, ReferenceHeight, englishPath);
            Assert.AreNotEqual(PixelHash(thaiPath), PixelHash(englishPath));
        }
        finally
        {
            language.SetLanguage(UiLanguage.Thai);
        }
    }

    private static ShellView CreateShell()
    {
        var shell = ShellView.CreateSyntheticPreview();
        Assert.IsTrue(shell.NavigateTo("daily-summary"));
        return shell;
    }

    private static void AssertSurface(
        ShellView shell,
        object? pageObject,
        UiLanguageService language,
        bool expectThai,
        bool expectMissing = false,
        bool assertCompact = false)
    {
        var page = Assert.IsInstanceOfType<DailySummaryView>(pageObject);
        Assert.AreEqual(Visibility.Visible, page.Visibility);
        Assert.AreEqual(Visibility.Collapsed, Assert.IsInstanceOfType<Grid>(shell.FindName("PlaceholderPage")).Visibility);

        foreach (var name in new[]
                 {
                     "DailySummaryEvidenceBoundary",
                     "DailySummarySummaryCardsRegion",
                     "DailySummaryHighlightsRegion",
                     "DailySummaryStrengthsRegion",
                     "DailySummaryAreasRegion",
                     "DailySummaryRepeatedIssuesRegion",
                     "DailySummaryRecommendationsRegion",
                     "DailySummaryTimelineRegion",
                     "DailySummaryWorkstreamRegion",
                     "DailySummaryDayOverviewRegion",
                 })
        {
            var region = Assert.IsInstanceOfType<FrameworkElement>(page.FindName(name));
            Assert.AreEqual(Visibility.Visible, region.Visibility, name);
            Assert.IsGreaterThan(0d, region.ActualWidth, name);
            Assert.IsGreaterThan(0d, region.ActualHeight, name);
        }

        var state = Assert.IsInstanceOfType<DailySummaryState>(page.DataContext);
        var summary = Assert.IsInstanceOfType<ItemsControl>(page.FindName("DailySummarySummaryCardsRegion"));
        Assert.HasCount(5, summary.Items);
        Assert.IsTrue(state.SummaryCards.All(card => card.SourceIds.All(
            sourceId => state.Snapshot is null || state.Snapshot.AcceptedSources.Any(item => item.SourceId == sourceId))));
        AssertVisibleTextContains(shell, language["DailySummaryPageTitle"]);
        AssertVisibleTextContains(page, expectMissing ? "—" : state.SourceLabel);

        var boundary = Assert.IsInstanceOfType<FrameworkElement>(page.FindName("DailySummaryEvidenceBoundary"));
        var boundaryAutomation = AutomationProperties.GetName(boundary);
        Assert.AreEqual(state.BoundaryLabel, boundaryAutomation);
        if (expectMissing)
        {
            Assert.AreNotEqual(language["DailySummarySyntheticBoundary"], boundaryAutomation);
            Assert.IsFalse(
                boundaryAutomation.Contains("synthetic", StringComparison.OrdinalIgnoreCase),
                "Unavailable Daily Summary must not announce synthetic evidence.");
        }

        AssertProvenanceAffordances(page, state);
        foreach (var sourceId in state.Strengths
                     .SelectMany(row => row.SourceIds)
                     .Concat(state.Timeline.SelectMany(row => row.SourceIds))
                     .Distinct(StringComparer.Ordinal))
        {
            AssertVisibleTextContains(page, sourceId);
        }

        if (assertCompact)
        {
            AssertCompactSurface(page);
        }

        if (expectMissing)
        {
            Assert.IsNull(state.Snapshot);
            AssertVisibleTextContains(page, language["DailySummaryLiveBoundary"]);
        }

        var visible = VisibleText(shell);
        if (expectThai)
        {
            Assert.IsTrue(visible.Any(value => Regex.IsMatch(value, "[ก-๙]", RegexOptions.CultureInvariant)));
            AssertNoVisibleEnglishCopy(page);
        }
        else
        {
            AssertNoVisibleThaiCopy(shell);
        }
    }

    private static void AssertCompactSurface(DailySummaryView page)
    {
        var scrollViewer = Assert.IsInstanceOfType<ScrollViewer>(page.FindName("DailySummaryScrollViewer"));
        Assert.IsInstanceOfType<StackPanel>(scrollViewer.Content, "Daily Summary content must retain one vertical page hierarchy.");

        var regionNames = new[]
        {
            "DailySummaryEvidenceBoundary",
            "DailySummarySummaryCardsRegion",
            "DailySummaryHighlightsRegion",
            "DailySummaryStrengthsRegion",
            "DailySummaryAreasRegion",
            "DailySummaryRepeatedIssuesRegion",
            "DailySummaryRecommendationsRegion",
            "DailySummaryTimelineRegion",
            "DailySummaryWorkstreamRegion",
            "DailySummaryDayOverviewRegion",
        };
        var regions = regionNames
            .Select(name => (Name: name, Element: Assert.IsInstanceOfType<FrameworkElement>(page.FindName(name))))
            .ToArray();
        var pageBounds = new Rect(0, 0, page.ActualWidth, page.ActualHeight);
        var bounds = regions.ToDictionary(
            item => item.Name,
            item => BoundsRelativeTo(item.Element, page),
            StringComparer.Ordinal);

        foreach (var (name, element) in regions)
        {
            Assert.IsTrue(IsDescendantOf(element, scrollViewer), $"{name} escaped the Daily Summary scroll hierarchy.");
            var regionBounds = bounds[name];
            Assert.IsTrue(
                regionBounds.Left >= pageBounds.Left - 1 && regionBounds.Right <= pageBounds.Right + 1,
                $"{name} exceeds the compact page width: {regionBounds} / {pageBounds}");

            foreach (var text in EnumerateDescendants(element).OfType<TextBlock>().Where(IsEffectivelyVisible))
            {
                var textBounds = BoundsRelativeTo(text, page);
                Assert.IsTrue(
                    textBounds.Left >= regionBounds.Left - 1 &&
                    textBounds.Top >= regionBounds.Top - 1 &&
                    textBounds.Right <= regionBounds.Right + 1 &&
                    textBounds.Bottom <= regionBounds.Bottom + 1,
                    $"Text escapes its compact region in {name}: {TextOf(text)} / {regionBounds}");
            }
        }

        for (var index = 0; index < regions.Length; index++)
        {
            for (var other = index + 1; other < regions.Length; other++)
            {
                Assert.IsFalse(
                    HasPositiveAreaOverlap(bounds[regions[index].Name], bounds[regions[other].Name]),
                    $"Daily Summary regions overlap at compact size: {regions[index].Name} {bounds[regions[index].Name]} and {regions[other].Name} {bounds[regions[other].Name]}");
            }
        }

        for (var index = 1; index < regions.Length; index++)
        {
            var previous = bounds[regions[index - 1].Name];
            var current = bounds[regions[index].Name];
            Assert.IsGreaterThanOrEqualTo(
                previous.Top - 1,
                current.Top,
                $"Daily Summary region order changed at compact size: {regions[index - 1].Name} -> {regions[index].Name}");
            if (Math.Abs(current.Top - previous.Top) <= 1)
            {
                Assert.IsGreaterThanOrEqualTo(
                    previous.Left - 1,
                    current.Left,
                    $"Same-row Daily Summary regions are out of order: {regions[index - 1].Name} -> {regions[index].Name}");
            }
        }

        Assert.IsGreaterThan(0d, scrollViewer.ViewportHeight, "The compact Daily Summary viewport must have height.");
        Assert.IsGreaterThan(
            scrollViewer.ViewportHeight + 1,
            scrollViewer.ExtentHeight,
            "The compact Daily Summary must expose content beyond the viewport for deterministic scrolling.");

        scrollViewer.ScrollToTop();
        scrollViewer.UpdateLayout();
        Assert.IsLessThanOrEqualTo(1d, scrollViewer.VerticalOffset, "Compact Daily Summary did not start at the top.");
        scrollViewer.ScrollToEnd();
        scrollViewer.UpdateLayout();
        Assert.IsLessThanOrEqualTo(
            1d,
            Math.Abs(scrollViewer.VerticalOffset - scrollViewer.ScrollableHeight),
            "Compact Daily Summary did not reach the scroll extent.");

        var bottomRegion = Assert.IsInstanceOfType<FrameworkElement>(page.FindName("DailySummaryDayOverviewRegion"));
        var bottomBounds = BoundsRelativeTo(bottomRegion, scrollViewer);
        var viewportBounds = new Rect(0, 0, scrollViewer.ViewportWidth, scrollViewer.ViewportHeight);
        Assert.IsTrue(
            bottomBounds.Bottom <= viewportBounds.Bottom + 1 && bottomBounds.Bottom > 0,
            $"The final Daily Summary region is not reachable at scroll end: {bottomBounds} / {viewportBounds}");

        AssertWorkstreamRows(page, Assert.IsInstanceOfType<DailySummaryState>(page.DataContext));
    }

    private static void AssertProvenanceAffordances(DailySummaryView page, DailySummaryState state)
    {
        var summaryCardsRegion = Assert.IsInstanceOfType<FrameworkElement>(page.FindName("DailySummarySummaryCardsRegion"));
        AssertRegionProvenance(summaryCardsRegion, state.SourceSetLabel, "summary cards");

        var workstreamRegion = Assert.IsInstanceOfType<FrameworkElement>(page.FindName("DailySummaryWorkstreamRegion"));
        AssertRegionProvenance(workstreamRegion, state.SourceSetLabel, "workstream group");

        var dayOverviewRegion = Assert.IsInstanceOfType<FrameworkElement>(page.FindName("DailySummaryDayOverviewRegion"));
        AssertRegionProvenance(dayOverviewRegion, state.SourceSetLabel, "day overview");

        var groups = new[]
        {
            (Name: "summary cards", Items: state.SummaryCards.Cast<object>().ToArray()),
            (Name: "highlights", Items: state.Highlights.Cast<object>().ToArray()),
            (Name: "strengths", Items: state.Strengths.Cast<object>().ToArray()),
            (Name: "areas to improve", Items: state.AreasToImprove.Cast<object>().ToArray()),
            (Name: "repeated issues", Items: state.RepeatedIssues.Cast<object>().ToArray()),
            (Name: "recommended actions", Items: state.RecommendedActions.Cast<object>().ToArray()),
            (Name: "timeline", Items: state.Timeline.Cast<object>().ToArray()),
            (Name: "workstreams", Items: state.Workstreams.Cast<object>().ToArray()),
        };

        foreach (var group in groups)
        {
            if (group.Items.Length == 0)
            {
                continue;
            }

            var itemsControl = FindItemsControlFor(page, group.Items, group.Name);
            foreach (var item in group.Items)
            {
                var provenance = ProvenanceOf(item);
                AssertDeterministicProvenance(item, provenance, group.Name);

                var container = itemsControl.ItemContainerGenerator.ContainerFromItem(item);
                Assert.IsNotNull(container, $"No rendered item container for {group.Name}.");
                var affordance = EnumerateDescendants(container!)
                    .OfType<FrameworkElement>()
                    .FirstOrDefault(element =>
                        element.Focusable &&
                        AutomationProperties.GetHelpText(element) == provenance.Label &&
                        string.Equals(element.ToolTip?.ToString(), provenance.Label, StringComparison.Ordinal));
                Assert.IsNotNull(affordance, $"{group.Name} item has no keyboard/assistive provenance affordance.");

                var provenanceLines = EnumerateDescendants(container!)
                    .OfType<TextBlock>()
                    .Where(IsEffectivelyVisible)
                    .Where(text => text.Text == provenance.Label)
                    .ToArray();
                Assert.IsNotEmpty(provenanceLines, $"{group.Name} item has no visible provenance line.");
                Assert.IsTrue(
                    provenanceLines.Any(text => text.TextTrimming == TextTrimming.CharacterEllipsis),
                    $"{group.Name} provenance line must use deterministic ellipsis for compact layouts.");
            }
        }
    }

    private static void AssertRegionProvenance(FrameworkElement region, string provenance, string regionName)
    {
        Assert.AreEqual(provenance, AutomationProperties.GetHelpText(region), $"Missing {regionName} provenance help text.");
        Assert.AreEqual(provenance, region.ToolTip?.ToString(), $"Missing {regionName} provenance tooltip.");
    }

    private static void AssertDeterministicProvenance(
        object item,
        (IReadOnlyList<string> SourceIds, IReadOnlyList<DailySummarySourceReference> References, string Label) provenance,
        string groupName)
    {
        Assert.IsFalse(string.IsNullOrWhiteSpace(provenance.Label), $"{groupName} item has empty provenance.");
        Assert.IsTrue(
            provenance.SourceIds.SequenceEqual(provenance.References.Select(reference => reference.SourceId)),
            $"{groupName} item source IDs do not match its source references.");
        foreach (var reference in provenance.References)
        {
            Assert.IsTrue(
                Regex.IsMatch(reference.SourceHashSha256, "^[0-9A-Fa-f]{64}$", RegexOptions.CultureInvariant),
                $"{groupName} item has a non-SHA-256 source hash.");
        }

        if (provenance.References.Count > 0)
        {
            var expected = string.Join(
                " · ",
                provenance.References.Select(reference => $"{reference.SourceId}#{reference.SourceHashSha256}"));
            Assert.AreEqual(expected, provenance.Label, $"{groupName} item provenance is not deterministic.");
        }
    }

    private static (IReadOnlyList<string> SourceIds, IReadOnlyList<DailySummarySourceReference> References, string Label) ProvenanceOf(object item) =>
        item switch
        {
            DailySummarySummaryCard value => (value.SourceIds, value.SourceReferences, value.SourceProvenanceLabel),
            DailySummaryHighlightRow value => (value.SourceIds, value.SourceReferences, value.SourceProvenanceLabel),
            DailySummaryIssueRow value => (value.SourceIds, value.SourceReferences, value.SourceProvenanceLabel),
            DailySummaryActionRow value => (value.SourceIds, value.SourceReferences, value.SourceProvenanceLabel),
            DailySummaryTimelineRow value => (value.SourceIds, value.SourceReferences, value.SourceProvenanceLabel),
            DailySummaryWorkstreamRow value => (value.SourceIds, value.SourceReferences, value.SourceProvenanceLabel),
            _ => throw new AssertFailedException($"Unsupported Daily Summary row type: {item.GetType().FullName}"),
        };

    private static ItemsControl FindItemsControlFor(
        DependencyObject root,
        IReadOnlyList<object> expectedItems,
        string groupName)
    {
        var matches = EnumerateDescendants(root)
            .OfType<ItemsControl>()
            .Where(control => control.Items.Count == expectedItems.Count)
            .Where(control => expectedItems
                .Select((item, index) => ReferenceEquals(control.Items[index], item))
                .All(matches => matches))
            .ToArray();
        Assert.HasCount(1, matches, $"Could not identify the rendered ItemsControl for {groupName}.");
        return matches[0];
    }

    private static void AssertWorkstreamRows(DailySummaryView page, DailySummaryState state)
    {
        if (state.Workstreams.Count == 0)
        {
            return;
        }

        var itemsControl = FindItemsControlFor(
            page,
            state.Workstreams.Cast<object>().ToArray(),
            "workstreams");
        foreach (var item in state.Workstreams)
        {
            var container = itemsControl.ItemContainerGenerator.ContainerFromItem(item);
            Assert.IsNotNull(container, "No rendered workstream item container.");
            var row = EnumerateDescendants(container!)
                .OfType<Grid>()
                .FirstOrDefault(element =>
                    element.Focusable &&
                    AutomationProperties.GetHelpText(element) == item.SourceProvenanceLabel);
            Assert.IsNotNull(row, "Workstream row has no provenance-aware root grid.");
            Assert.IsGreaterThan(0d, row!.ActualWidth, "Workstream row has no rendered width.");
            Assert.IsLessThanOrEqualTo(
                row.ActualWidth + 1,
                row.DesiredSize.Width,
                $"Workstream row desired width exceeds its compact layout width: {row.DesiredSize.Width} / {row.ActualWidth}.");

            var cells = row.Children
                .OfType<TextBlock>()
                .Where(text => Grid.GetRow(text) == 0)
                .ToArray();
            Assert.HasCount(7, cells, "Workstream row must retain all seven hierarchy columns.");
            foreach (var cell in cells)
            {
                Assert.IsGreaterThan(0d, cell.ActualWidth, "Workstream cell has no rendered width.");
                Assert.IsTrue(
                    cell.DesiredSize.Width <= cell.ActualWidth + 1 ||
                    cell.TextTrimming == TextTrimming.CharacterEllipsis ||
                    cell.TextWrapping != TextWrapping.NoWrap,
                    $"Workstream cell has no compact overflow policy: {cell.Text} ({cell.DesiredSize.Width} / {cell.ActualWidth}).");
            }

            var bounds = cells.Select(cell => BoundsRelativeTo(cell, row)).ToArray();
            for (var index = 0; index < bounds.Length; index++)
            {
                for (var other = index + 1; other < bounds.Length; other++)
                {
                    Assert.IsFalse(
                        HasPositiveAreaOverlap(bounds[index], bounds[other]),
                        $"Workstream sibling text overlaps in compact layout: {cells[index].Text} / {cells[other].Text}.");
                }
            }
        }
    }

    private static string TextOf(TextBlock text) =>
        new TextRange(text.ContentStart, text.ContentEnd).Text.Trim();

    private static bool HasPositiveAreaOverlap(Rect first, Rect second)
    {
        var horizontal = Math.Min(first.Right, second.Right) - Math.Max(first.Left, second.Left);
        var vertical = Math.Min(first.Bottom, second.Bottom) - Math.Max(first.Top, second.Top);
        return horizontal > 1 && vertical > 1;
    }

    private static void AssertNoVisibleThaiCopy(DependencyObject root)
    {
        var values = VisibleText(root)
            .Where(value => Regex.IsMatch(value, "[ก-๙]", RegexOptions.CultureInvariant))
            .ToArray();
        Assert.IsEmpty(values, $"English Daily Summary contains Thai copy: {string.Join(" | ", values)}");
    }

    private static void AssertNoVisibleEnglishCopy(DependencyObject root)
    {
        var knownEnglish = new[]
        {
            "Daily Summary",
            "Accepted Sources",
            "Activity Events",
            "Evidence Items",
            "Recommended Actions",
            "Workstream Summary",
            "Key Events Timeline",
        };
        var values = VisibleText(root)
            .Where(value => knownEnglish.Any(english => value.Contains(english, StringComparison.Ordinal)))
            .ToArray();
        Assert.IsEmpty(values, $"Thai Daily Summary contains English copy: {string.Join(" | ", values)}");
    }

    private static void AssertVisibleTextContains(DependencyObject root, string expected) =>
        Assert.IsTrue(
            VisibleText(root).Any(value => value.Contains(expected, StringComparison.Ordinal)),
            $"Visible Daily Summary text does not contain: {expected}");

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

    private static void Layout(FrameworkElement view, int width, int height)
    {
        var size = new Size(width, height);
        view.Measure(size);
        view.Arrange(new Rect(size));
        view.UpdateLayout();
        view.InvalidateMeasure();
        view.Measure(size);
        view.Arrange(new Rect(size));
        view.UpdateLayout();
    }

    private static void RenderPng(FrameworkElement view, int width, int height, string outputPath)
    {
        Layout(view, width, height);
        var bitmap = new RenderTargetBitmap(width, height, 96, 96, PixelFormats.Pbgra32);
        bitmap.Render(view);
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using var stream = File.Create(outputPath);
        encoder.Save(stream);
    }

    private static string PixelHash(string path) =>
        Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(path)));

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

        Assert.Fail("Could not locate HerdrOps.sln from the test output directory.");
        return string.Empty;
    }
}
