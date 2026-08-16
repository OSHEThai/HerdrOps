using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using Path = System.IO.Path;
using HerdrOps.App.Live;
using HerdrOps.App.Localization;
using HerdrOps.App.Shell;
using HerdrOps.App.Views;
using HerdrOps.App.Widgets;

namespace HerdrOps.RuntimeTests;

/// <summary>
/// Produces candidate design-parity captures from deterministic in-process WPF fixtures.
/// This class deliberately never starts Herdr, connects to a socket, or claims release evidence.
/// </summary>
[TestClass]
[DoNotParallelize]
public sealed class DesignParityRenderingTests
{
    private const int ReferenceWidth = 1672;
    private const int ReferenceHeight = 941;
    private const int CompactWidth = 1366;
    private const int CompactHeight = 768;
    private const int WidgetBoardWidth = 1536;
    private const int WidgetBoardHeight = 1024;
    private const double HorizontalTextFitTolerance = 3;
    private const double VerticalTextFitTolerance = 4;

    private static readonly IReadOnlyList<UiLanguage> Languages =
    [
        UiLanguage.Thai,
        UiLanguage.English,
    ];

    private static readonly IReadOnlyList<SizeSpec> ShellSizes =
    [
        new("reference", ReferenceWidth, ReferenceHeight),
        new("compact", CompactWidth, CompactHeight),
    ];

    private static readonly IReadOnlyList<PageDescriptor> Pages =
    [
        new("overview", "01-overview.png", typeof(OverviewView), "ภาพรวม", "Overview"),
        new("live-organization", "02-live-organization.png", typeof(LiveOrganizationView), "โครงสร้างองค์กรสด", "Live Organization"),
        new("realtime-activity", "03-realtime-activity.png", typeof(RealtimeActivityView), "กิจกรรมเวลาจริง", "Realtime Activity"),
        new("delegation-graph", "04-delegation-graph.png", typeof(DelegationGraphView), "กราฟการมอบหมาย", "Delegation Graph"),
        new("agent-detail", "05-agent-detail.png", typeof(AgentDetailView), "รายละเอียดเอเจนต์", "Agent Detail"),
        new("task-alignment", "06-task-alignment.png", typeof(TaskAlignmentView), "ความสอดคล้องของงาน", "Task Alignment"),
        new("file-activity", "07-file-activity.png", typeof(FileActivityView), "กิจกรรมไฟล์", "File Activity"),
        new("compliance-queue", "08-compliance-queue.png", typeof(ComplianceQueueView), "คิวตรวจความสอดคล้อง", "Compliance Queue"),
        new("evaluation", "09-evaluation.png", typeof(EvaluationView), "การประเมิน", "Evaluation"),
        new("daily-summary", "10-daily-summary.png", typeof(DailySummaryView), "สรุปรายวัน", "Daily Summary"),
    ];

    private static readonly IReadOnlyList<ReferenceEntry> References =
    [
        new("01-overview.png", ReferenceWidth, ReferenceHeight, 1_592_813, "2D390E965001986EB95E0C395177FC978385C98927B117AB0DE7C1C80266B90B"),
        new("02-live-organization.png", ReferenceWidth, ReferenceHeight, 1_518_762, "21531405D1BF5F8C520F60E98107C464071EB089327D35D34552486AE982C35D"),
        new("03-realtime-activity.png", ReferenceWidth, ReferenceHeight, 1_739_843, "1EFBF8A309665511E6BF330E736D2B4CE96791338DB2101B7723B1A5C987BD0F"),
        new("04-delegation-graph.png", ReferenceWidth, ReferenceHeight, 1_659_041, "61831A14CA46726C1CB5376F61957EA2CBDFAB534F3D681F02561B38CB774AA1"),
        new("05-agent-detail.png", ReferenceWidth, ReferenceHeight, 1_663_880, "6E8E8749ACC3D791CF3719DD0173E75B7BB52FA1ECD3A2319271B41F719CAF84"),
        new("06-task-alignment.png", ReferenceWidth, ReferenceHeight, 1_585_608, "0A9AEBBFB97C23F2A0593248E9FFADFD5F5B4579161ED340496E2BD3B45E832D"),
        new("07-file-activity.png", ReferenceWidth, ReferenceHeight, 1_672_825, "2BFB03357D9FFE4D4C11582D311D45CF2CFCCBD69A63D15130FD1EEBA0537F24"),
        new("08-compliance-queue.png", ReferenceWidth, ReferenceHeight, 1_714_456, "685B54499D36C564A67FD74F81798825470F462FE8D5379D6C1D47E1ABABB45C"),
        new("09-evaluation.png", ReferenceWidth, ReferenceHeight, 1_483_137, "7721C24EE49887286854D07132BBFE12C52B028AAE50CE7EB8062F0877C2B23D"),
        new("10-daily-summary.png", ReferenceWidth, ReferenceHeight, 1_627_596, "A44CAFDFB9A8B34694B67B6AABAD86B8B65A99A8A947C7CAB83C11FE7464F693"),
        new("11-widget-concepts.png", WidgetBoardWidth, WidgetBoardHeight, 1_800_245, "6AB57A967BE8C62A436A8F5C6DBB89616B210E66DD34AB851D148B4DCC1A904A"),
    ];

    private static readonly IReadOnlyDictionary<string, string> StatusBrushes =
        new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["Working"] = "HerdrOps.Brush.Status.Working",
            ["Idle"] = "HerdrOps.Brush.Status.Idle",
            ["Blocked"] = "HerdrOps.Brush.Status.Blocked",
            ["Review"] = "HerdrOps.Brush.Status.Review",
            ["Done"] = "HerdrOps.Brush.Status.Done",
            ["Offline"] = "HerdrOps.Brush.Status.Offline",
            ["Unknown"] = "HerdrOps.Brush.Status.Offline",
        };

    private static readonly IReadOnlyList<StatusDefinition> StatusDefinitions =
    [
        new("StatusWorking", "Working"),
        new("StatusIdle", "Idle"),
        new("StatusBlocked", "Blocked"),
        new("StatusReview", "Review"),
        new("StatusDone", "Done"),
        new("StatusOffline", "Offline"),
        new("StatusUnknown", "Unknown"),
    ];

    [TestMethod]
    public void SyntheticDesignParityCapturesAllReferenceDestinationsAndWidgetConcepts()
    {
        WpfTestHost.Run(RenderEvidence, TimeSpan.FromSeconds(180));
    }

    [TestMethod]
    public void ClippingRegressionFailsWhenNoWrapTextIsDeliberatelyNarrow()
    {
        WpfTestHost.Run(() =>
        {
            var host = new Border
            {
                Width = 24,
                Height = 32,
                ClipToBounds = true,
                Child = new TextBlock
                {
                    Text = "Deliberately clipped text",
                    FontSize = 14,
                    TextWrapping = TextWrapping.NoWrap,
                    TextTrimming = TextTrimming.None,
                },
            };

            Layout(host, 24, 32);

            var intrinsicWidth = 100d;
            Assert.Throws<AssertFailedException>(
                () => AssertIntrinsicExtentFits(
                    host.ActualWidth,
                    intrinsicWidth,
                    HorizontalTextFitTolerance,
                    "Deliberately clipped text must fail the available-versus-intrinsic width assertion."),
                "The clipping guard must fail when a no-wrap TextBlock is narrower than its intrinsic text.");
        });
    }

    private static void RenderEvidence()
    {
        var language = UiLanguageService.Shared;
        var repositoryRoot = FindRepositoryRoot();
        var evidenceRoot = Path.Combine(
            repositoryRoot,
            "artifacts",
            "design-evidence",
            "v0.7.0",
            "issue-35");
        var captureRoot = Path.Combine(evidenceRoot, "captures");
        Directory.CreateDirectory(captureRoot);
        WriteEvidenceBoundary(evidenceRoot);

        try
        {
            ValidateApprovedReferenceSet(repositoryRoot);
            ValidateImplementedCatalog();

            var captures = new List<CandidateCapture>();
            foreach (var selectedLanguage in Languages)
            {
                language.SetLanguage(selectedLanguage);
                AssertStatusSemantics();

                var languageCode = LanguageCode(selectedLanguage);
                foreach (var page in Pages)
                {
                    foreach (var size in ShellSizes)
                    {
                        var shell = CreateSyntheticShell(page.Id);
                        shell.NavigateTo(page.Id);
                        Layout(shell, size.Width, size.Height);

                        var activePage = AssertPageIsImplementedAndVisible(shell, page, size);
                        AssertShellRegions(shell, activePage, size);
                        AssertSelectedLanguage(shell, page, selectedLanguage);
                        AssertPageAccessibility(shell, activePage, page);
                        AssertTaggedTextFits(shell, size);

                        var outputPath = Path.Combine(
                            captureRoot,
                            languageCode,
                            "pages",
                            $"{page.Id}-{size.Name}.png");
                        captures.Add(CapturePng(
                            shell,
                            size.Width,
                            size.Height,
                            outputPath,
                            page.ReferenceFile,
                            selectedLanguage,
                            "page"));
                    }
                }

                var galleryReference = new WidgetGalleryView();
                Layout(galleryReference, WidgetBoardWidth, WidgetBoardHeight);
                AssertWidgetGallery(galleryReference, WidgetBoardWidth, WidgetBoardHeight);
                captures.Add(CapturePng(
                    galleryReference,
                    WidgetBoardWidth,
                    WidgetBoardHeight,
                    Path.Combine(captureRoot, languageCode, "widgets", "gallery-reference.png"),
                    "11-widget-concepts.png",
                    selectedLanguage,
                    "widget-gallery"));

                var galleryCompact = new WidgetGalleryView();
                Layout(galleryCompact, CompactWidth, CompactHeight);
                AssertWidgetGallery(galleryCompact, CompactWidth, CompactHeight);
                captures.Add(CapturePng(
                    galleryCompact,
                    CompactWidth,
                    CompactHeight,
                    Path.Combine(captureRoot, languageCode, "widgets", "gallery-compact.png"),
                    "11-widget-concepts.png",
                    selectedLanguage,
                    "widget-gallery"));

                foreach (var descriptor in WidgetCatalog.All)
                {
                    var state = SyntheticWidgetState.Create();
                    var surface = new WidgetSurface(state)
                    {
                        Variant = descriptor.Variant,
                        IsInteractive = true,
                        Width = descriptor.WindowWidth,
                        Height = descriptor.WindowHeight,
                    };
                    var width = checked((int)descriptor.WindowWidth);
                    var height = checked((int)descriptor.WindowHeight);
                    Layout(surface, width, height);
                    AssertWidgetSurface(surface, descriptor, width, height);

                    captures.Add(CapturePng(
                        surface,
                        width,
                        height,
                        Path.Combine(
                            captureRoot,
                            languageCode,
                            "widgets",
                            $"{descriptor.Variant.ToString().ToLowerInvariant()}-native.png"),
                        "11-widget-concepts.png",
                        selectedLanguage,
                        "widget-variant"));
                }
            }

            VerifyExpectedCaptures(captureRoot, captures);
            WriteCandidateManifest(evidenceRoot, captures);
        }
        finally
        {
            language.SetLanguage(UiLanguage.Thai);
        }
    }

    private static ShellView CreateSyntheticShell(string destinationId)
    {
        // Live Organization and Agent Detail require the public shell constructor so their
        // synthetic dashboard state is supplied to those two live-shaped views. No Herdr
        // client, socket, process, or runtime adapter is created here.
        return destinationId is "live-organization" or "agent-detail"
            ? new ShellView(LiveDashboardState.CreateSyntheticPreview())
            : ShellView.CreateSyntheticPreview();
    }

    private static FrameworkElement AssertPageIsImplementedAndVisible(
        ShellView shell,
        PageDescriptor page,
        SizeSpec size)
    {
        var implementedDestinations = shell.Navigation.Destinations
            .Select(destination => destination.Id)
            .ToArray();
        Assert.IsTrue(
            implementedDestinations.Contains(page.Id, StringComparer.Ordinal),
            $"Missing implemented destination: {page.Id}");

        var visiblePages = Pages
            .Select(candidate => FindVisiblePage(shell, candidate.PageType))
            .Where(candidate => candidate is not null)
            .Cast<FrameworkElement>()
            .ToArray();
        Assert.HasCount(1, visiblePages, $"Expected exactly one visible page at {size.Name} for {page.Id}.");
        Assert.AreEqual(page.PageType, visiblePages[0].GetType(), $"Wrong page rendered for {page.Id}.");
        Assert.IsGreaterThan(0d, visiblePages[0].ActualWidth, $"Page has no width: {page.Id}");
        Assert.IsGreaterThan(0d, visiblePages[0].ActualHeight, $"Page has no height: {page.Id}");
        return visiblePages[0];
    }

    private static void AssertShellRegions(
        ShellView shell,
        FrameworkElement activePage,
        SizeSpec size)
    {
        var shellRoot = FindNamed<FrameworkElement>(shell, "ShellRoot");
        Assert.IsGreaterThan(0d, shellRoot.ActualWidth);
        Assert.IsGreaterThan(0d, shellRoot.ActualHeight);

        var expectedVisible = new List<FrameworkElement>
        {
            FindNamed<FrameworkElement>(shell, "WideBrandMark"),
            FindNamed<FrameworkElement>(shell, "ProjectSelector"),
            FindNamed<FrameworkElement>(shell, "LanguageSelector"),
            FindNamed<FrameworkElement>(shell, "NavigationList"),
            activePage,
        };
        var statusLegend = FindNamed<FrameworkElement>(shell, "StatusLegend");
        var reviewLegendItem = FindNamed<FrameworkElement>(shell, "StatusReviewLegendItem");
        var doneLegendItem = FindNamed<FrameworkElement>(shell, "StatusDoneLegendItem");
        var isLiveOrganization = string.Equals(
            shell.Navigation.SelectedDestination.Id,
            "live-organization",
            StringComparison.Ordinal);
        Assert.AreEqual(
            isLiveOrganization ? Visibility.Collapsed : Visibility.Visible,
            reviewLegendItem.Visibility,
            "The shared legend must show Review on every page except Live Organization.");
        Assert.AreEqual(
            isLiveOrganization ? Visibility.Visible : Visibility.Collapsed,
            doneLegendItem.Visibility,
            "The Live Organization legend must show Done in place of Review.");
        var profilePanel = FindNamed<FrameworkElement>(shell, "ProfilePanel");
        if (size.Width >= 1480)
        {
            expectedVisible.Add(statusLegend);
        }

        if (size.Height >= 800)
        {
            expectedVisible.Add(profilePanel);
        }

        foreach (var region in expectedVisible)
        {
            Assert.AreEqual(Visibility.Visible, region.Visibility, $"Key region is hidden: {region.Name}");
            Assert.IsGreaterThan(0d, region.ActualWidth, $"Key region has no width: {region.Name}");
            Assert.IsGreaterThan(0d, region.ActualHeight, $"Key region has no height: {region.Name}");
            AssertRectInside(region, shellRoot, $"Key region is outside the shell: {region.Name}");
        }

        for (var firstIndex = 0; firstIndex < expectedVisible.Count; firstIndex++)
        {
            for (var secondIndex = firstIndex + 1; secondIndex < expectedVisible.Count; secondIndex++)
            {
                var first = expectedVisible[firstIndex];
                var second = expectedVisible[secondIndex];
                Assert.IsFalse(
                    GetBounds(first, shellRoot).IntersectsWith(GetBounds(second, shellRoot)),
                    $"Key shell regions overlap: {first.Name} and {second.Name}");
            }
        }

        var compactBrand = FindNamed<FrameworkElement>(shell, "CompactBrandMark");
        Assert.AreEqual(Visibility.Collapsed, compactBrand.Visibility);
        AssertImageBrandAsset(FindNamed<Rectangle>(shell, "WideBrandMark"));
        AssertImageBrandAsset(FindNamed<Rectangle>(shell, "CompactBrandMark"));

        var navigation = FindNamed<ListBox>(shell, "NavigationList");
        Assert.IsTrue(navigation.Focusable, "Main navigation is not keyboard focusable.");
        AssertHasAutomationName(navigation, "Main navigation");
        var navigationItems = EnumerateSelfAndDescendants(navigation)
            .OfType<ListBoxItem>()
            .Where(IsEffectivelyVisible)
            .ToArray();
        Assert.HasCount(shell.Navigation.Destinations.Count, navigationItems, "A destination is missing from the visible navigation list.");
        foreach (var item in navigationItems)
        {
            Assert.IsTrue(item.Focusable, "A navigation destination is not keyboard focusable.");
            Assert.IsTrue(item.IsTabStop, "A navigation destination is not in the tab order.");
            AssertHasAutomationName(item, "Navigation destination");
        }

        AssertHasAutomationName(FindNamed<Button>(shell, "ThaiLanguageButton"), "Thai language selector");
        AssertHasAutomationName(FindNamed<Button>(shell, "EnglishLanguageButton"), "English language selector");
    }

    private static void AssertPageAccessibility(
        ShellView shell,
        FrameworkElement activePage,
        PageDescriptor page)
    {
        var accessibleElements = EnumerateSelfAndDescendants(activePage)
            .Where(IsEffectivelyVisible)
            .Where(element => !string.IsNullOrWhiteSpace(AutomationProperties.GetName(element)))
            .ToArray();
        Assert.IsNotEmpty(
            accessibleElements,
            $"Missing accessibility automation equivalent for implemented page: {page.Id}");

        var focusableElements = EnumerateSelfAndDescendants(activePage)
            .OfType<Control>()
            .Where(control => !ReferenceEquals(control, activePage))
            .Where(control => control is ButtonBase or Selector or TextBoxBase or PasswordBox or Slider or DatePicker)
            .Where(IsEffectivelyVisible)
            .Where(control => control.Focusable && control.IsTabStop)
            .ToArray();
        foreach (var control in focusableElements)
        {
            AssertHasAutomationName(
                control,
                $"Keyboard control {control.GetType().Name} '{control.Name}' on page {page.Id}");
        }

        Assert.IsTrue(shell.NavigateTo(page.Id), $"Destination could not be activated: {page.Id}");
    }

    private static void AssertSelectedLanguage(
        DependencyObject root,
        PageDescriptor page,
        UiLanguage selectedLanguage)
    {
        var visibleText = VisibleText(root);
        var selectedName = selectedLanguage == UiLanguage.Thai ? page.ThaiName : page.EnglishName;
        var otherName = selectedLanguage == UiLanguage.Thai ? page.EnglishName : page.ThaiName;
        Assert.IsTrue(
            visibleText.Any(text => text.Contains(selectedName, StringComparison.Ordinal)),
            $"Selected language title is missing for {page.Id}: {selectedName}");
        Assert.IsFalse(
            visibleText.Any(text => text.Contains(otherName, StringComparison.Ordinal)),
            $"Both language titles are visible for {page.Id}: {selectedName} / {otherName}");

        if (selectedLanguage == UiLanguage.English)
        {
            var thaiText = visibleText.Where(ContainsThai).ToArray();
            Assert.IsEmpty(thaiText, $"English mode contains Thai UI copy: {string.Join(" | ", thaiText)}");
        }
        else
        {
            Assert.IsTrue(visibleText.Any(ContainsThai), $"Thai mode rendered no Thai UI copy for {page.Id}.");
        }

        UiLanguageRenderingAssertions.AssertOppositeUiTranslationsAbsent(
            visibleText,
            selectedLanguage,
            $"design parity page {page.Id}");
    }

    private static void AssertWidgetGallery(
        WidgetGalleryView gallery,
        int width,
        int height)
    {
        var visiblePreviews = EnumerateSelfAndDescendants(gallery)
            .OfType<WidgetSurface>()
            .Where(IsEffectivelyVisible)
            .ToArray();
        var expectedVariants = Enum.GetValues<WidgetVariant>();
        foreach (var variant in expectedVariants)
        {
            Assert.IsTrue(
                visiblePreviews.Any(preview => preview.Variant == variant),
                $"Widget gallery is missing visible variant {variant} at {width}x{height}.");
        }

        var launchActions = EnumerateSelfAndDescendants(gallery)
            .OfType<Button>()
            .Where(button => button.Tag is string tag &&
                            (string.Equals(tag, "Dashboard", StringComparison.Ordinal) ||
                             Enum.TryParse<WidgetVariant>(tag, out _)))
            .Where(IsEffectivelyVisible)
            .ToArray();
        Assert.HasCount(expectedVariants.Length + 1, launchActions, "Widget gallery is missing a launch action.");
        foreach (var action in launchActions)
        {
            Assert.IsTrue(action.Focusable, $"Widget launch action is not keyboard focusable: {action.Tag}");
            Assert.IsTrue(action.IsTabStop, $"Widget launch action is not in the tab order: {action.Tag}");
            Assert.IsGreaterThanOrEqualTo(40d, action.ActualHeight, $"Widget launch action is too short: {action.Tag}");
            AssertHasAutomationName(action, $"Widget launch action {action.Tag}");
        }

        var dashboardPreview = FindNamed<FrameworkElement>(gallery, "DashboardPreviewHost");
        Assert.IsGreaterThan(0d, dashboardPreview.ActualWidth, "Dashboard preview has no width.");
        Assert.IsGreaterThan(0d, dashboardPreview.ActualHeight, "Dashboard preview has no height.");
        var galleryText = VisibleText(gallery);
        Assert.IsTrue(
            galleryText.Any(text => text.Contains(UiLanguageService.Shared["WidgetGalleryTitle"], StringComparison.Ordinal)),
            "Widget gallery title is missing from the candidate capture.");
        if (UiLanguageService.Shared.CurrentLanguage == UiLanguage.English)
        {
            var thaiText = galleryText.Where(ContainsThai).ToArray();
            Assert.IsEmpty(thaiText, $"English Widget mode contains Thai UI copy: {string.Join(" | ", thaiText)}");
        }
        else
        {
            Assert.IsTrue(galleryText.Any(ContainsThai), "Thai Widget mode rendered no Thai UI copy.");
        }
        UiLanguageRenderingAssertions.AssertOppositeUiTranslationsAbsent(
            galleryText,
            UiLanguageService.Shared.CurrentLanguage,
            $"widget gallery {width}x{height}");
        AssertStatusSemantics();
    }

    private static void AssertWidgetSurface(
        WidgetSurface surface,
        WidgetVariantDescriptor descriptor,
        int width,
        int height)
    {
        var visiblePanels = new[]
        {
            "CompactPanel",
            "NormalPanel",
            "ExpandedPanel",
            "FloatingMiniPanel",
            "FloatingVerticalPanel",
            "NotificationPanel",
            "AgentDetailPanel",
        }
        .Select(name => FindNamed<FrameworkElement>(surface, name))
        .Where(panel => panel.Visibility == Visibility.Visible)
        .ToArray();
        Assert.HasCount(1, visiblePanels, $"Widget variant exposes an ambiguous visible panel: {descriptor.Variant}");
        Assert.IsGreaterThan(0d, visiblePanels[0].ActualWidth, $"Widget panel has no width: {descriptor.Variant}");
        Assert.IsGreaterThan(0d, visiblePanels[0].ActualHeight, $"Widget panel has no height: {descriptor.Variant}");
        AssertRectInside(visiblePanels[0], surface, $"Widget panel exceeds its surface: {descriptor.Variant}");

        var wordmark = FindNamed<TextBlock>(surface, "HeaderWordmark");
        Assert.AreEqual(
            "HerdrOps",
            wordmark.Text,
            "Widget wordmark must preserve the approved HerdrOps casing and spelling.");
        var sourceText = FindNamed<TextBlock>(surface, "HeaderSourceText");
        var dragSurface = FindNamed<FrameworkElement>(surface, "DragSurface");
        var expectedSource = descriptor.Variant == WidgetVariant.FloatingVertical
            ? UiLanguageService.Shared["SyntheticCompact"]
            : UiLanguageService.Shared["SyntheticData"];
        Assert.AreEqual(expectedSource, sourceText.Text, $"Widget source label drifted for {descriptor.Variant}.");
        Assert.AreEqual(TextTrimming.CharacterEllipsis, sourceText.TextTrimming, $"Widget source label must have explicit trimming: {descriptor.Variant}.");
        Assert.AreEqual(TextWrapping.NoWrap, sourceText.TextWrapping, $"Widget source label must not wrap in the header: {descriptor.Variant}.");
        Assert.IsGreaterThan(0d, sourceText.ActualWidth, $"Widget source label has no bounded width: {descriptor.Variant}.");
        AssertRectInside(sourceText, dragSurface, $"Widget source label exceeds its header: {descriptor.Variant}.");
        if (descriptor.Variant == WidgetVariant.FloatingMini)
        {
            Assert.AreEqual(230, width, "Floating Mini must retain its exact approved width.");
            Assert.AreEqual(220, height, "Floating Mini must retain its exact approved height.");
            if (UiLanguageService.Shared.CurrentLanguage == UiLanguage.English)
            {
                Assert.AreEqual("SYNTHETIC DATA", sourceText.Text, "English Floating Mini source treatment drifted.");
            }

            var sourceMeasurement = new TextBlock
            {
                Text = sourceText.Text,
                FontFamily = sourceText.FontFamily,
                FontSize = sourceText.FontSize,
                FontStretch = sourceText.FontStretch,
                FontStyle = sourceText.FontStyle,
                FontWeight = sourceText.FontWeight,
                FlowDirection = sourceText.FlowDirection,
                Language = sourceText.Language,
                TextWrapping = TextWrapping.NoWrap,
            };
            sourceMeasurement.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            AssertIntrinsicExtentFits(
                sourceText.ActualWidth,
                sourceMeasurement.DesiredSize.Width,
                HorizontalTextFitTolerance,
                $"Floating Mini source label is clipped at 230x220: available width={sourceText.ActualWidth}, intrinsic width={sourceMeasurement.DesiredSize.Width}.");
        }
        UiLanguageRenderingAssertions.AssertOppositeUiTranslationsAbsent(
            VisibleText(surface),
            UiLanguageService.Shared.CurrentLanguage,
            $"widget {descriptor.Variant}");
        AssertHasAutomationName(FindNamed<Button>(surface, "PinButton"), $"Widget pin action {descriptor.Variant}");
        AssertHasAutomationName(FindNamed<Button>(surface, "CloseButton"), $"Widget close action {descriptor.Variant}");

        var accessibleControls = EnumerateSelfAndDescendants(surface)
            .OfType<Control>()
            .Where(IsEffectivelyVisible)
            .Where(control => control.Focusable && control.IsTabStop)
            .ToArray();
        Assert.IsNotEmpty(accessibleControls, $"Widget variant has no keyboard controls: {descriptor.Variant}");
        foreach (var control in accessibleControls)
        {
            AssertHasAutomationName(control, $"Widget control {descriptor.Variant}");
        }

        Assert.IsGreaterThan(0, width);
        Assert.IsGreaterThan(0, height);
    }

    private static void AssertStatusSemantics()
    {
        var text = UiLanguageService.Shared;
        var localizedBrushes = StatusDefinitions.ToDictionary(
            definition => text[definition.LocalizationKey],
            definition => StatusBrushes[definition.SemanticStatus],
            StringComparer.Ordinal);
        Assert.HasCount(
            StatusDefinitions.Count,
            localizedBrushes,
            "Status labels conflict in the selected language.");

        var state = SyntheticWidgetState.Create();
        Assert.IsNotEmpty(state.Agents, "Synthetic Widget state has no Agent status rows.");
        foreach (var agent in state.Agents)
        {
            Assert.IsTrue(localizedBrushes.ContainsKey(agent.Status), $"Unsupported synthetic status label: {agent.Status}");
            Assert.AreEqual(
                localizedBrushes[agent.Status],
                agent.StatusBrushKey,
                $"Status '{agent.Status}' is mapped to a conflicting visual role.");
        }

        foreach (var notice in state.Notices)
        {
            Assert.IsTrue(localizedBrushes.ContainsKey(notice.State), $"Unsupported synthetic notice status: {notice.State}");
            Assert.AreEqual(
                localizedBrushes[notice.State],
                notice.StatusBrushKey,
                $"Notice status '{notice.State}' is mapped to a conflicting visual role.");
        }
    }

    private static void AssertTaggedTextFits(DependencyObject root, SizeSpec size)
    {
        var visibleTextBlocks = EnumerateSelfAndDescendants(root)
            .OfType<TextBlock>()
            .Where(IsEffectivelyVisible)
            .ToArray();
        var taggedCheckpoints = visibleTextBlocks
            .Where(textBlock => textBlock.Tag is string tag && tag.Contains("Check", StringComparison.Ordinal))
            .ToArray();
        var checkpoints = taggedCheckpoints.Length > 0
            ? taggedCheckpoints
            : visibleTextBlocks
                .Where(textBlock => textBlock.TextTrimming == TextTrimming.None)
                .Where(textBlock => IsMeaningfulAccessibleText(TextOf(textBlock)))
                .ToArray();
        Assert.IsNotEmpty(checkpoints, $"No clipping checkpoints rendered at {size.Name} size.");

        foreach (var textBlock in checkpoints)
        {
            var text = TextOf(textBlock);
            if (string.IsNullOrWhiteSpace(text) || textBlock.TextTrimming != TextTrimming.None)
            {
                continue;
            }

            var measurement = new TextBlock
            {
                Text = text,
                FontFamily = textBlock.FontFamily,
                FontSize = textBlock.FontSize,
                FontStretch = textBlock.FontStretch,
                FontStyle = textBlock.FontStyle,
                FontWeight = textBlock.FontWeight,
                FlowDirection = textBlock.FlowDirection,
                Language = textBlock.Language,
                LineHeight = textBlock.LineHeight,
                LineStackingStrategy = textBlock.LineStackingStrategy,
                TextWrapping = textBlock.TextWrapping,
            };

            if (textBlock.TextWrapping == TextWrapping.NoWrap)
            {
                measurement.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
                AssertIntrinsicExtentFits(
                    textBlock.ActualWidth,
                    measurement.DesiredSize.Width,
                    HorizontalTextFitTolerance,
                    $"Text is clipped at {size.Name}: available width={textBlock.ActualWidth}, intrinsic width={measurement.DesiredSize.Width}, text={text}");
                continue;
            }

            measurement.Measure(new Size(Math.Max(1, textBlock.ActualWidth), double.PositiveInfinity));
            AssertIntrinsicExtentFits(
                textBlock.ActualHeight,
                measurement.DesiredSize.Height,
                VerticalTextFitTolerance,
                $"Wrapped text is clipped at {size.Name}: available height={textBlock.ActualHeight}, intrinsic height={measurement.DesiredSize.Height}, text={text}");
        }
    }

    private static void AssertIntrinsicExtentFits(
        double availableExtent,
        double intrinsicExtent,
        double tolerance,
        string message)
    {
        Assert.IsGreaterThanOrEqualTo(
            intrinsicExtent - tolerance,
            availableExtent,
            message);
    }

    private static CandidateCapture CapturePng(
        FrameworkElement element,
        int width,
        int height,
        string outputPath,
        string referenceFile,
        UiLanguage language,
        string captureKind)
    {
        Layout(element, width, height);
        var bitmap = new RenderTargetBitmap(width, height, 96, 96, PixelFormats.Pbgra32);
        bitmap.Render(element);

        var directory = Path.GetDirectoryName(outputPath);
        Assert.IsFalse(string.IsNullOrWhiteSpace(directory));
        Directory.CreateDirectory(directory!);
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using (var output = File.Create(outputPath))
        {
            encoder.Save(output);
        }

        Assert.IsTrue(File.Exists(outputPath), $"Candidate capture was not written: {outputPath}");
        var visual = PngEvidenceAssertions.AssertValid(outputPath, width, height);

        return new CandidateCapture(
            Path.GetRelativePath(Path.Combine(FindRepositoryRoot(), "artifacts", "design-evidence", "v0.7.0", "issue-35"), outputPath).Replace('\\', '/'),
            referenceFile,
            LanguageCode(language),
            captureKind,
            width,
            height,
            visual.PixelCount,
            visual.PixelSha256);
    }

    private static void ValidateApprovedReferenceSet(string repositoryRoot)
    {
        var referenceDirectory = Path.Combine(repositoryRoot, "docs", "design", "reference");
        var manifestPath = Path.Combine(referenceDirectory, "MANIFEST.md");
        Assert.IsTrue(File.Exists(manifestPath), "Approved reference manifest is missing.");
        var manifest = File.ReadAllText(manifestPath);
        var referenceFiles = Directory.GetFiles(referenceDirectory, "*.png")
            .Select(Path.GetFileName)
            .Where(name => name is not null)
            .Cast<string>()
            .Order(StringComparer.Ordinal)
            .ToArray();
        CollectionAssert.AreEquivalent(
            References.Select(reference => reference.FileName).ToArray(),
            referenceFiles,
            "Approved reference set does not contain exactly the eleven manifest entries.");

        foreach (var reference in References)
        {
            var path = Path.Combine(referenceDirectory, reference.FileName);
            Assert.IsTrue(File.Exists(path), $"Approved reference is missing: {reference.FileName}");
            Assert.AreEqual(reference.Bytes, new FileInfo(path).Length, $"Approved reference byte drift: {reference.FileName}");
            Assert.AreEqual(
                reference.Sha256,
                Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(path))),
                $"Approved reference hash drift: {reference.FileName}");
            using var input = File.OpenRead(path);
            var decoder = new PngBitmapDecoder(
                input,
                BitmapCreateOptions.PreservePixelFormat,
                BitmapCacheOption.OnLoad);
            Assert.AreEqual(reference.Width, decoder.Frames[0].PixelWidth, $"Reference width drift: {reference.FileName}");
            Assert.AreEqual(reference.Height, decoder.Frames[0].PixelHeight, $"Reference height drift: {reference.FileName}");
            StringAssert.Contains(manifest, $"| `{reference.FileName}` | {reference.Width}×{reference.Height} |");
            StringAssert.Contains(manifest, reference.Sha256);
        }
    }

    private static void ValidateImplementedCatalog()
    {
        var destinations = ShellNavigationCatalog.All;
        Assert.HasCount(Pages.Count, destinations, "Implemented destination count does not match the ten page references.");
        CollectionAssert.AreEqual(
            Pages.Select(page => page.Id).ToArray(),
            destinations.Select(destination => destination.Id).ToArray(),
            "Implemented destination order does not match the approved reference order.");
        foreach (var page in Pages)
        {
            var destination = destinations.SingleOrDefault(candidate => candidate.Id == page.Id);
            Assert.IsNotNull(destination, $"Missing implemented destination: {page.Id}");
            Assert.IsFalse(string.IsNullOrWhiteSpace(destination!.EnglishName), $"Destination has no English name: {page.Id}");
            Assert.IsFalse(string.IsNullOrWhiteSpace(destination.ThaiName), $"Destination has no Thai name: {page.Id}");
        }

        var variants = Enum.GetValues<WidgetVariant>();
        Assert.HasCount(7, variants, "Widget variant enum no longer represents the seven approved concepts.");
        Assert.HasCount(variants.Length, WidgetCatalog.All, "Widget catalog does not cover every widget variant.");
        foreach (var variant in variants)
        {
            var descriptor = WidgetCatalog.All.SingleOrDefault(candidate => candidate.Variant == variant);
            Assert.IsNotNull(descriptor, $"Missing widget catalog variant: {variant}");
            Assert.IsGreaterThan(0d, descriptor!.WindowWidth, $"Widget variant has no width: {variant}");
            Assert.IsGreaterThan(0d, descriptor.WindowHeight, $"Widget variant has no height: {variant}");
        }
    }

    private static void VerifyExpectedCaptures(string captureRoot, IReadOnlyList<CandidateCapture> captures)
    {
        var expectedCount = (Pages.Count * Languages.Count * ShellSizes.Count) +
                            ((Languages.Count * 2) + (Languages.Count * Enum.GetValues<WidgetVariant>().Length));
        Assert.HasCount(expectedCount, captures, "Candidate capture count is incomplete.");
        var relativePaths = captures.Select(capture => capture.RelativePath).ToArray();
        Assert.HasCount(relativePaths.Length, relativePaths.Distinct(StringComparer.Ordinal), "Candidate capture paths collide.");

        var allFiles = Directory.GetFiles(captureRoot, "*.png", SearchOption.AllDirectories);
        Assert.HasCount(expectedCount, allFiles, "Candidate capture directory contains a missing or unexpected PNG.");
        var captureByPath = captures.ToDictionary(
            capture => capture.RelativePath,
            capture => capture,
            StringComparer.Ordinal);
        var captureDirectory = Path.GetFullPath(captureRoot);
        foreach (var capture in captures)
        {
            var path = ResolveCapturePath(capture.RelativePath);
            Assert.IsTrue(
                File.Exists(path),
                $"Candidate capture record points to a missing PNG: {capture.RelativePath}");
            var visual = PngEvidenceAssertions.AssertValid(path, capture.Width, capture.Height);
            Assert.AreEqual(
                capture.DecodedPixelCount,
                visual.PixelCount,
                $"Decoded pixel count drifted: {capture.RelativePath}");
            Assert.AreEqual(
                capture.DecodedPixelSha256,
                visual.PixelSha256,
                $"Decoded pixel hash drifted: {capture.RelativePath}");
        }

        foreach (var path in allFiles)
        {
            var relativePath = Path.GetRelativePath(captureDirectory, path).Replace('\\', '/');
            var candidatePath = $"captures/{relativePath}";
            Assert.IsTrue(
                captureByPath.ContainsKey(candidatePath),
                $"Candidate capture directory contains an unexpected PNG: {relativePath}");
        }

        string ResolveCapturePath(string relativePath)
        {
            const string capturePrefix = "captures/";
            Assert.IsTrue(
                relativePath.StartsWith(capturePrefix, StringComparison.Ordinal),
                $"Candidate capture path is outside the capture namespace: {relativePath}");
            var relativeCapturePath = relativePath[capturePrefix.Length..]
                .Replace('/', Path.DirectorySeparatorChar);
            var resolved = Path.GetFullPath(Path.Combine(captureDirectory, relativeCapturePath));
            var rootWithSeparator = captureDirectory.TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
            Assert.IsTrue(
                resolved.StartsWith(rootWithSeparator, StringComparison.OrdinalIgnoreCase),
                $"Candidate capture escaped the evidence directory: {relativePath}");
            return resolved;
        }
    }

    private static void WriteEvidenceBoundary(string evidenceRoot)
    {
        var boundary = string.Join(
            Environment.NewLine,
            [
                "HerdrOps v0.7.0 Issue #35 Design Parity",
                "EvidenceClass: Synthetic",
                "CandidateSyntheticCaptures: true",
                "HumanAcceptance: NOT PERFORMED / NOT CLAIMED",
                "ActualHerdrRuntime: NOT OBSERVED / NOT CLAIMED",
                "ReleaseEvidence: NOT PRODUCED / NOT CLAIMED",
                "Source: deterministic in-process WPF fixtures only",
            ]) + Environment.NewLine;
        File.WriteAllText(
            Path.Combine(evidenceRoot, "evidence-boundary.txt"),
            boundary,
            new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
    }

    private static void WriteCandidateManifest(string evidenceRoot, IReadOnlyList<CandidateCapture> captures)
    {
        var manifest = new CandidateEvidenceManifest(
            "HerdrOps v0.7.0 Issue #35 Design Parity",
            "Synthetic",
            "Candidate captures only",
            "NOT PERFORMED / NOT CLAIMED",
            "NOT OBSERVED / NOT CLAIMED",
            "NOT PRODUCED / NOT CLAIMED",
            Pages.Select(page => page.Id).ToArray(),
            Enum.GetValues<WidgetVariant>().Select(variant => variant.ToString()).ToArray(),
            captures.OrderBy(capture => capture.RelativePath, StringComparer.Ordinal).ToArray());
        File.WriteAllText(
            Path.Combine(evidenceRoot, "candidate-manifest.json"),
            JsonSerializer.Serialize(manifest, new JsonSerializerOptions { WriteIndented = true }) + Environment.NewLine,
            new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
    }

    private static void AssertImageBrandAsset(Rectangle mark)
    {
        Assert.IsInstanceOfType<ImageBrush>(mark.Fill, $"Brand mark is not backed by an approved image: {mark.Name}");
        var imageBrush = (ImageBrush)mark.Fill;
        Assert.IsNotNull(imageBrush.ImageSource, $"Brand mark image is missing: {mark.Name}");
        StringAssert.Contains(
            imageBrush.ImageSource!.ToString(),
            "ApprovedOverviewReference.png",
            $"Brand mark is not linked to the approved HerdrOps reference asset: {mark.Name}");
    }

    private static void AssertRectInside(FrameworkElement child, FrameworkElement parent, string message)
    {
        var bounds = GetBounds(child, parent);
        var parentBounds = new Rect(0, 0, parent.ActualWidth, parent.ActualHeight);
        Assert.IsTrue(
            bounds.Left >= parentBounds.Left - 1 &&
            bounds.Top >= parentBounds.Top - 1 &&
            bounds.Right <= parentBounds.Right + 1 &&
            bounds.Bottom <= parentBounds.Bottom + 1,
            $"{message} bounds={bounds} parent={parentBounds}");
    }

    private static Rect GetBounds(FrameworkElement child, FrameworkElement parent)
    {
        var origin = child.TranslatePoint(new Point(0, 0), parent);
        return new Rect(origin, new Size(child.ActualWidth, child.ActualHeight));
    }

    private static FrameworkElement? FindVisiblePage(ShellView shell, Type pageType) =>
        EnumerateSelfAndDescendants(shell)
            .OfType<FrameworkElement>()
            .SingleOrDefault(element => element.GetType() == pageType && IsEffectivelyVisible(element));

    private static T FindNamed<T>(DependencyObject root, string name)
        where T : FrameworkElement =>
        EnumerateSelfAndDescendants(root)
            .OfType<T>()
            .SingleOrDefault(element => string.Equals(element.Name, name, StringComparison.Ordinal))
        ?? throw new AssertFailedException($"Missing named design-parity region/control: {name}");

    private static void AssertHasAutomationName(DependencyObject element, string description)
    {
        Assert.IsFalse(
            string.IsNullOrWhiteSpace(AccessibleName(element)),
            $"Missing accessibility automation name: {description}");
    }

    private static string? AccessibleName(DependencyObject element)
    {
        var directName = AutomationProperties.GetName(element);
        if (IsMeaningfulAccessibleText(directName))
        {
            return directName;
        }

        if (element is ContentControl { Content: string content } && IsMeaningfulAccessibleText(content))
        {
            return content;
        }

        var descendantName = EnumerateDescendants(element)
            .Select(AutomationProperties.GetName)
            .FirstOrDefault(IsMeaningfulAccessibleText);
        if (descendantName is not null)
        {
            return descendantName;
        }

        return EnumerateDescendants(element)
            .OfType<TextBlock>()
            .Select(TextOf)
            .FirstOrDefault(IsMeaningfulAccessibleText);
    }

    private static bool IsMeaningfulAccessibleText(string? value) =>
        !string.IsNullOrWhiteSpace(value) &&
        value.Any(character => !char.IsControl(character) &&
                               character is not (>= '\uE000' and <= '\uF8FF'));

    private static IReadOnlyList<string> VisibleText(DependencyObject root) =>
        EnumerateSelfAndDescendants(root)
            .OfType<TextBlock>()
            .Where(IsEffectivelyVisible)
            .Select(TextOf)
            .Where(text => !string.IsNullOrWhiteSpace(text))
            .ToArray();

    private static string TextOf(TextBlock textBlock)
    {
        var text = new TextRange(textBlock.ContentStart, textBlock.ContentEnd).Text.Trim();
        return string.IsNullOrWhiteSpace(text) ? textBlock.Text.Trim() : text;
    }

    private static bool ContainsThai(string value) =>
        value.Any(character => character is >= '\u0E00' and <= '\u0E7F');

    private static IEnumerable<DependencyObject> EnumerateSelfAndDescendants(DependencyObject root)
    {
        yield return root;
        foreach (var descendant in EnumerateDescendants(root))
        {
            yield return descendant;
        }
    }

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
        for (DependencyObject? current = element; current is not null; current = VisualTreeHelper.GetParent(current))
        {
            if (current is UIElement uiElement && uiElement.Visibility != Visibility.Visible)
            {
                return false;
            }

            if (current is FrameworkElement frameworkElement &&
                (frameworkElement.ActualWidth <= 0 || frameworkElement.ActualHeight <= 0))
            {
                return false;
            }
        }

        return true;
    }

    private static void Layout(FrameworkElement element, int width, int height)
    {
        var size = new Size(width, height);
        element.Measure(size);
        element.Arrange(new Rect(size));
        element.UpdateLayout();
        element.InvalidateMeasure();
        element.Measure(size);
        element.Arrange(new Rect(size));
        element.UpdateLayout();
    }

    private static string LanguageCode(UiLanguage language) =>
        language == UiLanguage.Thai ? "th" : "en";

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

    private sealed record PageDescriptor(
        string Id,
        string ReferenceFile,
        Type PageType,
        string ThaiName,
        string EnglishName);

    private sealed record ReferenceEntry(
        string FileName,
        int Width,
        int Height,
        long Bytes,
        string Sha256);

    private sealed record SizeSpec(string Name, int Width, int Height);

    private sealed record StatusDefinition(string LocalizationKey, string SemanticStatus);

    private sealed record CandidateCapture(
        string RelativePath,
        string ReferenceFile,
        string Language,
        string CaptureKind,
        int Width,
        int Height,
        long DecodedPixelCount,
        string DecodedPixelSha256);

    private sealed record CandidateEvidenceManifest(
        string Title,
        string EvidenceClass,
        string CandidateStatus,
        string HumanAcceptance,
        string ActualHerdrRuntime,
        string ReleaseEvidence,
        IReadOnlyList<string> PageDestinations,
        IReadOnlyList<string> WidgetVariants,
        IReadOnlyList<CandidateCapture> Captures);
}
