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

    public TrayMenuBuilder(
        Func<AppSettings> settingsProvider,
        UiLanguageService? languageService = null)
    {
        _settingsProvider = settingsProvider ?? throw new ArgumentNullException(nameof(settingsProvider));
        _languageService = languageService ?? UiLanguageService.Shared;
    }

    public TrayMenuModel Build()
    {
        var settings = AppSettingsContract.Admit(_settingsProvider());
        var text = _languageService;
        var widget = WidgetCatalog.Get(
            AppSettingsLifecycleMapping.ToWidgetVariant(settings.WidgetVariant));

        return new TrayMenuModel(
            toolTipText: "HerdrOps",
            items:
            [
                new TrayMenuItem(TrayCommand.ShowDashboard, text["TrayShowDashboard"]),
                new TrayMenuItem(
                    TrayCommand.ShowConfiguredWidget,
                    text.Format("TrayShowConfiguredWidgetFormat", widget.DisplayName)),
                new TrayMenuItem(
                    TrayCommand.SelectThaiLanguage,
                    text["LanguageThai"],
                    text.CurrentLanguage == UiLanguage.Thai),
                new TrayMenuItem(
                    TrayCommand.SelectEnglishLanguage,
                    text["LanguageEnglish"],
                    text.CurrentLanguage == UiLanguage.English),
                new TrayMenuItem(TrayCommand.Exit, text["TrayExit"]),
            ]);
    }
}
