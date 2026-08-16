using HerdrOps.App.Localization;
using HerdrOps.App.Widgets;
using HerdrOps.Domain.Lifecycle;
using HerdrOps.Domain.Settings;

namespace HerdrOps.App.Lifecycle;

/// <summary>
/// Projects admitted settings and the one selected UI language into a tray menu.
/// </summary>
public sealed class TrayMenuBuilder
{
    private readonly Func<AppSettings> _settingsProvider;
    private readonly UiLanguageService _languageService;
    private readonly Func<StartupRegistrationStatus>? _startupStatusProvider;

    public TrayMenuBuilder(
        Func<AppSettings> settingsProvider,
        UiLanguageService? languageService = null,
        Func<StartupRegistrationStatus>? startupStatusProvider = null)
    {
        _settingsProvider = settingsProvider ?? throw new ArgumentNullException(nameof(settingsProvider));
        _languageService = languageService ?? UiLanguageService.Shared;
        _startupStatusProvider = startupStatusProvider;
    }

    public TrayMenuModel Build()
    {
        var settings = AppSettingsContract.Admit(_settingsProvider());
        var text = _languageService;
        var widget = WidgetCatalog.Get(
            AppSettingsLifecycleMapping.ToWidgetVariant(settings.WidgetVariant));

        var items = new List<TrayMenuItem>
        {
            new(TrayCommand.ShowDashboard, text["TrayShowDashboard"]),
            new(
                TrayCommand.ShowConfiguredWidget,
                text.Format("TrayShowConfiguredWidgetFormat", widget.DisplayName)),
            new(
                TrayCommand.SelectThaiLanguage,
                text["LanguageThai"],
                text.CurrentLanguage == UiLanguage.Thai),
            new(
                TrayCommand.SelectEnglishLanguage,
                text["LanguageEnglish"],
                text.CurrentLanguage == UiLanguage.English),
        };

        if (_startupStatusProvider is not null)
        {
            var startupStatus = _startupStatusProvider();
            items.Add(new TrayMenuItem(
                TrayCommand.ToggleStartAtLogon,
                startupStatus.State == StartupRegistrationState.Conflicting
                    ? text["TrayStartAtLogonConflict"]
                    : startupStatus.IsEnabled
                        ? text["TrayStartAtLogonDisable"]
                        : text["TrayStartAtLogonEnable"]));
        }

        items.Add(new TrayMenuItem(TrayCommand.Exit, text["TrayExit"]));
        return new TrayMenuModel("HerdrOps", items);
    }
}
