using System.Windows;
using HerdrOps.App.Localization;
using HerdrOps.App.Widgets;
using HerdrOps.Domain.Lifecycle;
using HerdrOps.Domain.Settings;

namespace HerdrOps.App.Lifecycle;

/// <summary>
/// Adapts tray commands to the existing WPF Dashboard and widget launcher.
/// All external effects are supplied by the application composition root.
/// </summary>
public sealed class WpfTrayCommandTarget : ITrayCommandTarget, IStartAtLogonTrayCommandTarget
{
    private readonly Func<MainWindow?> _dashboardProvider;
    private readonly IWidgetWindowLauncher _widgetLauncher;
    private readonly Func<AppSettings> _settingsProvider;
    private readonly Action<AppSettingsLanguage> _languageSelected;
    private readonly Action<AppSettingsTheme> _themeSelected;
    private readonly Action _exit;
    private readonly Action _startAtLogonToggled;
    private readonly Action _widgetToggled;
    private readonly Action? _hideDashboard;
    private readonly Func<MainWindow?> _currentDashboardProvider;

    public WpfTrayCommandTarget(
        Func<MainWindow?> dashboardProvider,
        IWidgetWindowLauncher widgetLauncher,
        Func<AppSettings> settingsProvider,
        Action<AppSettingsLanguage> languageSelected,
        Action<AppSettingsTheme> themeSelected,
        Action exit,
        UiLanguageService? languageService = null,
        Action? startAtLogonToggled = null,
        Action? widgetToggled = null,
        Action? hideDashboard = null,
        Func<MainWindow?>? currentDashboardProvider = null)
    {
        _dashboardProvider = dashboardProvider ?? throw new ArgumentNullException(nameof(dashboardProvider));
        _widgetLauncher = widgetLauncher ?? throw new ArgumentNullException(nameof(widgetLauncher));
        _settingsProvider = settingsProvider ?? throw new ArgumentNullException(nameof(settingsProvider));
        _languageSelected = languageSelected ?? throw new ArgumentNullException(nameof(languageSelected));
        _themeSelected = themeSelected ?? throw new ArgumentNullException(nameof(themeSelected));
        _exit = exit ?? throw new ArgumentNullException(nameof(exit));
        _ = languageService;
        _startAtLogonToggled = startAtLogonToggled ??
            (() => throw new InvalidOperationException(
                "The WPF tray target has no start-at-logon handler."));
        _widgetToggled = widgetToggled ??
            (() => throw new InvalidOperationException(
                "The WPF tray target has no widget-enabled handler."));
        _hideDashboard = hideDashboard;
        _currentDashboardProvider = currentDashboardProvider ?? _dashboardProvider;
    }

    public void ShowDashboard()
    {
        InvokeOnDashboard(() =>
        {
            var dashboard = RequireDashboard();
            dashboard.Show();
            if (dashboard.WindowState == WindowState.Minimized)
            {
                dashboard.WindowState = WindowState.Normal;
            }

            dashboard.Activate();
        });
    }

    public void HideDashboard()
    {
        var dashboard = _currentDashboardProvider();
        if (dashboard is null)
        {
            return;
        }

        InvokeOnDashboard(
            _hideDashboard ?? dashboard.Hide,
            dashboard);
    }

    public void ShowConfiguredWidget()
    {
        var settings = AppSettingsContract.Admit(_settingsProvider());
        var variant = AppSettingsLifecycleMapping.ToWidgetVariant(settings.WidgetVariant);
        InvokeOnDashboard(() => _widgetLauncher.Open(variant));
    }

    public void ToggleWidgetEnabled() => InvokeOnDashboard(_widgetToggled);

    public void SelectLanguage(AppSettingsLanguage language)
    {
        InvokeOnDashboard(() =>
        {
            _languageSelected(language);
        });
    }

    public void SelectTheme(AppSettingsTheme theme)
    {
        InvokeOnDashboard(() =>
        {
            _themeSelected(theme);
        });
    }

    public void ToggleStartAtLogon() => InvokeOnDashboard(_startAtLogonToggled);

    public void Exit() => _exit();

    private MainWindow RequireDashboard() => _dashboardProvider()
        ?? throw new InvalidOperationException("The HerdrOps Dashboard is unavailable.");

    private void InvokeOnDashboard(Action action, MainWindow? knownDashboard = null)
    {
        ArgumentNullException.ThrowIfNull(action);
        var dashboard = knownDashboard ?? RequireDashboard();
        if (dashboard.Dispatcher.CheckAccess())
        {
            action();
            return;
        }

        dashboard.Dispatcher.Invoke(action);
    }
}
