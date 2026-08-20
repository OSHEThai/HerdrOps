using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using HerdrOps.App.Evaluation;
using HerdrOps.App.Files;
using HerdrOps.App.Live;
using HerdrOps.App.Localization;
using HerdrOps.App.Overview;
using HerdrOps.App.Shell;
using HerdrOps.App.Summaries;
using HerdrOps.App.Widgets;
using HerdrOps.Domain.Settings;

namespace HerdrOps.App.Views;

internal interface IPageResourceOwner
{
    void ReleaseResources();
}

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
    private readonly Action<UiLanguage>? _languageSelector;
    private readonly Action<AppSettingsWidgetVariant>? _widgetSelected;
    private readonly Action<bool>? _widgetEnabled;
    private readonly IWidgetWindowLauncher? _widgetLauncher;
    private string? _activeDestinationId;
    private string? _activePageName;
    private bool _resourcesReleased;

    public ShellView()
        : this(new LiveDashboardState(), syntheticPreview: false)
    {
    }

    public ShellView(LiveDashboardState liveDashboard)
        : this(liveDashboard, null, null, null, null)
    {
    }

    public ShellView(
        LiveDashboardState liveDashboard,
        Action<UiLanguage>? languageSelector,
        Action<AppSettingsWidgetVariant>? widgetSelected,
        Action<bool>? widgetEnabled,
        IWidgetWindowLauncher? widgetLauncher)
        : this(
            liveDashboard,
            syntheticPreview: false,
            languageSelector,
            widgetSelected,
            widgetEnabled,
            widgetLauncher)
    {
    }

    private ShellView(
        LiveDashboardState liveDashboard,
        bool syntheticPreview,
        Action<UiLanguage>? languageSelector = null,
        Action<AppSettingsWidgetVariant>? widgetSelected = null,
        Action<bool>? widgetEnabled = null,
        IWidgetWindowLauncher? widgetLauncher = null)
    {
        LiveDashboard = liveDashboard ?? throw new ArgumentNullException(nameof(liveDashboard));
        _syntheticPreview = syntheticPreview;
        _languageSelector = languageSelector;
        _widgetSelected = widgetSelected;
        _widgetEnabled = widgetEnabled;
        _widgetLauncher = widgetLauncher;
        Navigation = new ShellNavigationController();
        InitializeComponent();
        DataContext = Navigation;

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

    public int RetainedPageCount => PageHost.Content is null ? 0 : 1;

    public string? ActivePageName => _activePageName;

    public void SetLanguage(UiLanguage language)
    {
        if (_languageSelector is not null)
        {
            _languageSelector(language);
            return;
        }

        LanguageService.SetLanguage(language);
    }

    public bool TryNavigateByKey(Key key, ModifierKeys modifiers)
    {
        if (_resourcesReleased)
        {
            return false;
        }

        var handled = Navigation.TryHandleKey(key, modifiers);
        if (handled)
        {
            NavigationList.ScrollIntoView(Navigation.SelectedDestination);
        }

        return handled;
    }

    public bool NavigateTo(string destinationId)
    {
        if (_resourcesReleased || string.IsNullOrWhiteSpace(destinationId))
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
        if (PageHost.Content is FileActivityView
            {
                DataContext: FileActivityState fileActivity,
            })
        {
            fileActivity.RefreshLanguage();
        }
        if (PageHost.Content is EvaluationView
            {
                DataContext: EvaluationState evaluation,
            })
        {
            evaluation.RefreshLanguage();
        }
        if (PageHost.Content is DailySummaryView
            {
                DataContext: DailySummaryState dailySummary,
            })
        {
            dailySummary.RefreshLanguage();
        }
        if (_syntheticPreview && PageHost.Content is OverviewView overview)
        {
            overview.DataContext = SyntheticOverviewState.Create();
            overview.UseWidgetState(SyntheticWidgetState.Create());
        }
    }

    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        ReleaseResources();
    }

    internal void ReleaseResources()
    {
        if (_resourcesReleased)
        {
            return;
        }

        _resourcesReleased = true;
        Navigation.PropertyChanged -= OnNavigationPropertyChanged;
        WeakEventManager<UiLanguageService, EventArgs>.RemoveHandler(
            LanguageService,
            nameof(UiLanguageService.LanguageChanged),
            OnLanguageChanged);
        ReleaseActivePage();
        Unloaded -= OnUnloaded;
    }

    private void UpdatePageVisibility()
    {
        var destinationId = Navigation.SelectedDestination.Id;
        if (string.Equals(_activeDestinationId, destinationId, StringComparison.Ordinal) &&
            PageHost.Content is not null)
        {
            PlaceholderPage.Visibility = Visibility.Collapsed;
            return;
        }

        ReleaseActivePage();
        var page = CreatePage(destinationId);
        if (page is null)
        {
            PlaceholderPage.Visibility = Visibility.Visible;
            return;
        }

        _activeDestinationId = destinationId;
        _activePageName = page.Value.Name;
        RegisterName(_activePageName, page.Value.Page);
        PageHost.Content = page.Value.Page;
        PlaceholderPage.Visibility = Visibility.Collapsed;
    }

    private (string Name, FrameworkElement Page)? CreatePage(string destinationId)
    {
        switch (destinationId)
        {
            case "overview":
                {
                    var page = new OverviewView
                    {
                        DataContext = _syntheticPreview
                            ? SyntheticOverviewState.Create()
                            : LiveDashboard.Overview,
                    };
                    page.UseWidgetState(
                        _syntheticPreview
                            ? SyntheticWidgetState.Create()
                            : LiveDashboard.Widgets,
                        _widgetLauncher);
                    page.UseSettingsLifecycle(_widgetSelected, _widgetEnabled);
                    return ("OverviewPage", page);
                }

            case "live-organization" when !_syntheticPreview:
                return ("LiveOrganizationPage", new LiveOrganizationView
                {
                    DataContext = LiveDashboard.Organization,
                });
            case "realtime-activity":
                return ("RealtimeActivityPage", new RealtimeActivityView
                {
                    DataContext = LiveDashboard.RealtimeActivity,
                });
            case "delegation-graph":
                return ("DelegationGraphPage", new DelegationGraphView
                {
                    DataContext = LiveDashboard.DelegationGraph,
                });
            case "agent-detail" when !_syntheticPreview:
                return ("AgentDetailPage", new AgentDetailView
                {
                    DataContext = LiveDashboard.AgentDetail,
                });
            case "task-alignment":
                return ("TaskAlignmentPage", new TaskAlignmentView
                {
                    DataContext = LiveDashboard.TaskAlignment,
                });
            case "file-activity":
                return ("FileActivityPage", new FileActivityView
                {
                    DataContext = _syntheticPreview
                        ? FileActivityState.CreateSyntheticPreview()
                        : FileActivityState.CreateUnavailable(),
                });
            case "compliance-queue":
                return ("ComplianceQueuePage", new ComplianceQueueView
                {
                    DataContext = LiveDashboard.ComplianceQueue,
                });
            case "evaluation":
                return ("EvaluationPage", new EvaluationView
                {
                    DataContext = _syntheticPreview
                        ? EvaluationState.CreateSyntheticPreview()
                        : EvaluationState.CreateUnavailable(),
                });
            case "daily-summary":
                return ("DailySummaryPage", new DailySummaryView
                {
                    DataContext = _syntheticPreview
                        ? DailySummaryState.CreateSyntheticPreview()
                        : DailySummaryState.CreateUnavailable(),
                });
            default:
                return null;
        }
    }

    private void ReleaseActivePage()
    {
        if (PageHost.Content is IPageResourceOwner resourceOwner)
        {
            resourceOwner.ReleaseResources();
        }

        if (_activePageName is not null)
        {
            UnregisterName(_activePageName);
        }

        PageHost.Content = null;
        _activeDestinationId = null;
        _activePageName = null;
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
