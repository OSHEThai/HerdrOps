using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using HerdrOps.App.Live;
using HerdrOps.App.Shell;
using HerdrOps.App.StateIpc;

namespace HerdrOps.App.Views;

/// <summary>
/// Shared application chrome and navigation for all canonical pages.
/// </summary>
public partial class ShellView : UserControl
{
    private const double CompactSidebarBreakpoint = 1200;
    private const double CompactVerticalBreakpoint = 800;
    private const double ProjectSelectorBreakpoint = 1080;
    private const double StatusLegendBreakpoint = 1280;
    private readonly bool _syntheticPreview;
    private readonly LiveDashboardSession? _liveSession;
    private CancellationTokenSource? _sessionCancellation;
    private Task? _sessionTask;

    public ShellView()
        : this(new LiveDashboardState(), syntheticPreview: false, startProductionSession: true)
    {
    }

    public ShellView(LiveDashboardState liveDashboard)
        : this(liveDashboard, syntheticPreview: false, startProductionSession: false)
    {
    }

    private ShellView(
        LiveDashboardState liveDashboard,
        bool syntheticPreview,
        bool startProductionSession)
    {
        LiveDashboard = liveDashboard ?? throw new ArgumentNullException(nameof(liveDashboard));
        _syntheticPreview = syntheticPreview;
        Navigation = new ShellNavigationController();
        InitializeComponent();
        DataContext = Navigation;
        if (!syntheticPreview)
        {
            OverviewPage.DataContext = LiveDashboard.Overview;
            LiveOrganizationPage.DataContext = LiveDashboard.Organization;
            AgentDetailPage.DataContext = LiveDashboard.AgentDetail;
        }

        if (startProductionSession)
        {
            _liveSession = new LiveDashboardSession(
                new HerdrOpsStatePipeClient(HerdrOpsStatePipeClientOptions.ForCurrentUser()),
                LiveDashboard,
                new DispatcherLiveDashboardUiScheduler(Dispatcher));
        }

        Navigation.PropertyChanged += OnNavigationPropertyChanged;
        UpdatePageVisibility();
    }

    public static ShellView CreateSyntheticPreview() => new(
        LiveDashboardState.CreateSyntheticPreview(),
        syntheticPreview: true,
        startProductionSession: false);

    public ShellNavigationController Navigation { get; }

    public LiveDashboardState LiveDashboard { get; }

    public bool IsStateSessionRunning => _sessionTask is { IsCompleted: false };

    public bool TryNavigateByKey(Key key, ModifierKeys modifiers)
    {
        var handled = Navigation.TryHandleKey(key, modifiers);
        if (handled)
        {
            NavigationList.ScrollIntoView(Navigation.SelectedDestination);
        }

        return handled;
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
        OverviewPage.Visibility = isOverview ? Visibility.Visible : Visibility.Collapsed;
        LiveOrganizationPage.Visibility = isLiveOrganization
            ? Visibility.Visible
            : Visibility.Collapsed;
        AgentDetailPage.Visibility = isAgentDetail ? Visibility.Visible : Visibility.Collapsed;
        PlaceholderPage.Visibility = isOverview || isLiveOrganization || isAgentDetail
            ? Visibility.Collapsed
            : Visibility.Visible;
    }

    private void OnShellLoaded(object sender, RoutedEventArgs e)
    {
        if (_liveSession is null || _sessionTask is { IsCompleted: false })
        {
            return;
        }

        _sessionCancellation?.Dispose();
        _sessionCancellation = new CancellationTokenSource();
        _sessionTask = _liveSession.RunAsync(_sessionCancellation.Token);
        _ = ObserveSessionAsync(_sessionTask);
    }

    private async void OnShellUnloaded(object sender, RoutedEventArgs e)
    {
        var cancellation = _sessionCancellation;
        var sessionTask = _sessionTask;
        _sessionCancellation = null;
        _sessionTask = null;
        if (cancellation is null)
        {
            return;
        }

        cancellation.Cancel();
        try
        {
            if (sessionTask is not null)
            {
                await sessionTask.ConfigureAwait(true);
            }
        }
        catch
        {
            // The state session reports recoverable failures in the visible connection state.
        }
        finally
        {
            cancellation.Dispose();
        }
    }

    private static async Task ObserveSessionAsync(Task sessionTask)
    {
        try
        {
            await sessionTask.ConfigureAwait(false);
        }
        catch
        {
            // Prevent an unobserved task fault during WPF shutdown. The session fails closed.
        }
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
