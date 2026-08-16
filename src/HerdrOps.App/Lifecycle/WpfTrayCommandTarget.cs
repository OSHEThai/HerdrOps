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
public sealed class WpfTrayCommandTarget : ITrayCommandTarget
{
    private readonly Func<MainWindow?> _dashboardProvider;
    private readonly IWidgetWindowLauncher _widgetLauncher;
    private readonly Func<AppSettings> _settingsProvider;
    private readonly Action<AppSettingsLanguage> _languageSelected;
    private readonly Action _exit;
    private readonly UiLanguageService _languageService;

    public WpfTrayCommandTarget(
        Func<MainWindow?> dashboardProvider,
        IWidgetWindowLauncher widgetLauncher,
        Func<AppSettings> settingsProvider,
        Action<AppSettingsLanguage> languageSelected,
        Action exit,
        UiLanguageService? languageService = null)
    {
        _dashboardProvider = dashboardProvider ?? throw new ArgumentNullException(nameof(dashboardProvider));
        _widgetLauncher = widgetLauncher ?? throw new ArgumentNullException(nameof(widgetLauncher));
        _settingsProvider = settingsProvider ?? throw new ArgumentNullException(nameof(settingsProvider));
        _languageSelected = languageSelected ?? throw new ArgumentNullException(nameof(languageSelected));
        _exit = exit ?? throw new ArgumentNullException(nameof(exit));
        _languageService = languageService ?? UiLanguageService.Shared;
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

    public void ShowConfiguredWidget()
    {
        var settings = AppSettingsContract.Admit(_settingsProvider());
        var variant = AppSettingsLifecycleMapping.ToWidgetVariant(settings.WidgetVariant);
        InvokeOnDashboard(() => _widgetLauncher.Open(variant));
    }

    public void SelectLanguage(AppSettingsLanguage language)
    {
        InvokeOnDashboard(() =>
        {
            _languageService.SetLanguage(AppSettingsLifecycleMapping.ToUiLanguage(language));
            _languageSelected(language);
        });
    }

    public void Exit() => _exit();

    private MainWindow RequireDashboard() => _dashboardProvider()
        ?? throw new InvalidOperationException("The HerdrOps Dashboard is unavailable.");

    private void InvokeOnDashboard(Action action)
    {
        ArgumentNullException.ThrowIfNull(action);
        var dashboard = RequireDashboard();
        if (dashboard.Dispatcher.CheckAccess())
        {
            action();
            return;
        }

        dashboard.Dispatcher.Invoke(action);
    }
}
