using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using HerdrOps.App.Files;
using HerdrOps.App.Live;
using HerdrOps.App.Localization;
using HerdrOps.App.Overview;
using HerdrOps.App.Shell;
using HerdrOps.App.Widgets;

namespace HerdrOps.App.Views;

/// <summary>
/// Shared application chrome and navigation for all canonical pages.
/// </summary>
public partial class ShellView : UserControl
{
    private const double CompactSidebarBreakpoint = 1200;
    private const double CompactVerticalBreakpoint = 800;
    private const double ProjectSelectorBreakpoint = 1080;
    private const double StatusLegendBreakpoint = 1480;
    private readonly bool _syntheticPreview;

    public ShellView()
        : this(new LiveDashboardState(), syntheticPreview: false)
    {
    }

    public ShellView(LiveDashboardState liveDashboard)
        : this(liveDashboard, syntheticPreview: false)
    {
    }

    private ShellView(
        LiveDashboardState liveDashboard,
        bool syntheticPreview)
    {
        LiveDashboard = liveDashboard ?? throw new ArgumentNullException(nameof(liveDashboard));
        _syntheticPreview = syntheticPreview;
        Navigation = new ShellNavigationController();
        InitializeComponent();
        DataContext = Navigation;
        RealtimeActivityPage.DataContext = LiveDashboard.RealtimeActivity;
        DelegationGraphPage.DataContext = LiveDashboard.DelegationGraph;
        TaskAlignmentPage.DataContext = LiveDashboard.TaskAlignment;
        FileActivityPage.DataContext = syntheticPreview
            ? FileActivityState.CreateSyntheticPreview()
            : FileActivityState.CreateUnavailable();
        if (!syntheticPreview)
        {
            OverviewPage.DataContext = LiveDashboard.Overview;
            OverviewPage.UseWidgetState(LiveDashboard.Widgets);
            LiveOrganizationPage.DataContext = LiveDashboard.Organization;
            AgentDetailPage.DataContext = LiveDashboard.AgentDetail;
        }

        Navigation.PropertyChanged += OnNavigationPropertyChanged;
        WeakEventManager<UiLanguageService, EventArgs>.AddHandler(
            LanguageService,
            nameof(UiLanguageService.LanguageChanged),
            OnLanguageChanged);
        Unloaded += OnUnloaded;
        UpdatePageVisibility();
    }

    public static ShellView CreateSyntheticPreview() => new(
        LiveDashboardState.CreateSyntheticPreview(),
        syntheticPreview: true);

    public ShellNavigationController Navigation { get; }

    public LiveDashboardState LiveDashboard { get; }

    public UiLanguageService LanguageService => UiLanguageService.Shared;

    public void SetLanguage(UiLanguage language) => LanguageService.SetLanguage(language);

    public bool TryNavigateByKey(Key key, ModifierKeys modifiers)
    {
        var handled = Navigation.TryHandleKey(key, modifiers);
        if (handled)
        {
            NavigationList.ScrollIntoView(Navigation.SelectedDestination);
        }

        return handled;
    }

    public bool NavigateTo(string destinationId)
    {
        if (string.IsNullOrWhiteSpace(destinationId))
        {
            return false;
        }

        var index = Navigation.Destinations
            .Select((destination, position) => (destination, position))
            .FirstOrDefault(item => string.Equals(
                item.destination.Id,
                destinationId,
                StringComparison.Ordinal))
            .position;
        if (index < 0 || index >= Navigation.Destinations.Count ||
            !string.Equals(
                Navigation.Destinations[index].Id,
                destinationId,
                StringComparison.Ordinal))
        {
            return false;
        }

        Navigation.SelectedIndex = index;
        NavigationList.ScrollIntoView(Navigation.SelectedDestination);
        return true;
    }

    private void OnPreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (TryNavigateByKey(e.Key, Keyboard.Modifiers))
        {
            e.Handled = true;
        }
    }

    private void OnNavigationPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(ShellNavigationController.SelectedDestination))
        {
            UpdatePageVisibility();
        }
    }

    private void OnLanguageChanged(object? sender, EventArgs e)
    {
        if (!Dispatcher.CheckAccess())
        {
            if (!Dispatcher.HasShutdownStarted && !Dispatcher.HasShutdownFinished)
            {
                _ = Dispatcher.InvokeAsync(ApplyLanguageChange);
            }

            return;
        }

        ApplyLanguageChange();
    }

    private void ApplyLanguageChange()
    {
        Navigation.NotifyLanguageChanged();
        NavigationList.Items.Refresh();
        LiveDashboard.RefreshLanguage();
        if (FileActivityPage.DataContext is FileActivityState fileActivity)
        {
            fileActivity.RefreshLanguage();
        }
        if (_syntheticPreview)
        {
            OverviewPage.DataContext = SyntheticOverviewState.Create();
            OverviewPage.UseWidgetState(SyntheticWidgetState.Create());
        }
    }

    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        WeakEventManager<UiLanguageService, EventArgs>.RemoveHandler(
            LanguageService,
            nameof(UiLanguageService.LanguageChanged),
            OnLanguageChanged);
        Unloaded -= OnUnloaded;
    }

    private void UpdatePageVisibility()
    {
        var isOverview = string.Equals(
            Navigation.SelectedDestination.Id,
            "overview",
            StringComparison.Ordinal);
        var isLiveOrganization = !_syntheticPreview && string.Equals(
            Navigation.SelectedDestination.Id,
            "live-organization",
            StringComparison.Ordinal);
        var isAgentDetail = !_syntheticPreview && string.Equals(
            Navigation.SelectedDestination.Id,
            "agent-detail",
            StringComparison.Ordinal);
        var isRealtimeActivity = string.Equals(
            Navigation.SelectedDestination.Id,
            "realtime-activity",
            StringComparison.Ordinal);
        var isDelegationGraph = string.Equals(
            Navigation.SelectedDestination.Id,
            "delegation-graph",
            StringComparison.Ordinal);
        var isTaskAlignment = string.Equals(
            Navigation.SelectedDestination.Id,
            "task-alignment",
            StringComparison.Ordinal);
        var isFileActivity = string.Equals(
            Navigation.SelectedDestination.Id,
            "file-activity",
            StringComparison.Ordinal);
        OverviewPage.Visibility = isOverview ? Visibility.Visible : Visibility.Collapsed;
        LiveOrganizationPage.Visibility = isLiveOrganization
            ? Visibility.Visible
            : Visibility.Collapsed;
        AgentDetailPage.Visibility = isAgentDetail ? Visibility.Visible : Visibility.Collapsed;
        RealtimeActivityPage.Visibility = isRealtimeActivity
            ? Visibility.Visible
            : Visibility.Collapsed;
        DelegationGraphPage.Visibility = isDelegationGraph
            ? Visibility.Visible
            : Visibility.Collapsed;
        TaskAlignmentPage.Visibility = isTaskAlignment
            ? Visibility.Visible
            : Visibility.Collapsed;
        FileActivityPage.Visibility = isFileActivity
            ? Visibility.Visible
            : Visibility.Collapsed;
        PlaceholderPage.Visibility = isOverview ||
            isLiveOrganization ||
            isAgentDetail ||
            isRealtimeActivity ||
            isDelegationGraph ||
            isTaskAlignment ||
            isFileActivity
            ? Visibility.Collapsed
            : Visibility.Visible;
    }

    private void OnShellSizeChanged(object sender, SizeChangedEventArgs e)
    {
        StatusLegend.Visibility = e.NewSize.Width < StatusLegendBreakpoint
            ? Visibility.Collapsed
            : Visibility.Visible;
        ProjectSelector.Visibility = e.NewSize.Width < ProjectSelectorBreakpoint
            ? Visibility.Collapsed
            : Visibility.Visible;

        ApplySidebarMode(e.NewSize.Width < CompactSidebarBreakpoint);
        ApplyVerticalDensity(e.NewSize.Height < CompactVerticalBreakpoint);
    }

    private void OnToggleSidebarClick(object sender, RoutedEventArgs e)
    {
        ApplySidebarMode(!Navigation.IsCompactSidebar);
    }

    private void OnThaiLanguageClick(object sender, RoutedEventArgs e) =>
        SetLanguage(UiLanguage.Thai);

    private void OnEnglishLanguageClick(object sender, RoutedEventArgs e) =>
        SetLanguage(UiLanguage.English);

    private void ApplySidebarMode(bool compact)
    {
        Navigation.IsCompactSidebar = compact;
        var width = compact ? 72 : 248;
        SidebarColumn.Width = new GridLength(width);
        BrandColumn.Width = new GridLength(width);
        WideBrandMark.Visibility = compact ? Visibility.Collapsed : Visibility.Visible;
        CompactBrandMark.Visibility = compact ? Visibility.Visible : Visibility.Collapsed;
        ProfileText.Visibility = compact ? Visibility.Collapsed : Visibility.Visible;
        ProfileChevron.Visibility = compact ? Visibility.Collapsed : Visibility.Visible;
    }

    private void ApplyVerticalDensity(bool compact)
    {
        ProfileRow.Height = compact ? new GridLength(0) : new GridLength(132);
        ProfilePanel.Visibility = compact ? Visibility.Collapsed : Visibility.Visible;
        NavigationList.Margin = compact ? new Thickness(0, 4, 0, 4) : new Thickness(0, 12, 0, 8);
        NavigationList.ItemContainerStyle = (Style)FindResource(
            compact
                ? "HerdrOps.Style.NavItem.CompactVertical"
                : "HerdrOps.Style.NavItem");
    }

    private void OnMinimizeClick(object sender, RoutedEventArgs e)
    {
        if (Window.GetWindow(this) is { } window)
        {
            window.WindowState = WindowState.Minimized;
        }
    }

    private void OnMaximizeClick(object sender, RoutedEventArgs e)
    {
        if (Window.GetWindow(this) is { } window)
        {
            window.WindowState = window.WindowState == WindowState.Maximized
                ? WindowState.Normal
                : WindowState.Maximized;
        }
    }

    private void OnCloseClick(object sender, RoutedEventArgs e)
    {
        Window.GetWindow(this)?.Close();
    }
}
