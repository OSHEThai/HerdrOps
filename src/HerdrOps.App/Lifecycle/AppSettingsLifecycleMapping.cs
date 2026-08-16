using HerdrOps.App.Localization;
using HerdrOps.App.Widgets;
using HerdrOps.Domain.Settings;

namespace HerdrOps.App.Lifecycle;

public static class AppSettingsLifecycleMapping
{
    public static UiLanguage ToUiLanguage(AppSettingsLanguage language) => language switch
    {
        AppSettingsLanguage.Thai => UiLanguage.Thai,
        AppSettingsLanguage.English => UiLanguage.English,
        _ => throw new ArgumentOutOfRangeException(nameof(language), language, "Unknown settings language."),
    };

    public static WidgetVariant ToWidgetVariant(AppSettingsWidgetVariant variant) => variant switch
    {
        AppSettingsWidgetVariant.Compact => WidgetVariant.Compact,
        AppSettingsWidgetVariant.Normal => WidgetVariant.Normal,
        AppSettingsWidgetVariant.Expanded => WidgetVariant.Expanded,
        AppSettingsWidgetVariant.FloatingMini => WidgetVariant.FloatingMini,
        AppSettingsWidgetVariant.FloatingVertical => WidgetVariant.FloatingVertical,
        AppSettingsWidgetVariant.Notification => WidgetVariant.Notification,
        AppSettingsWidgetVariant.AgentDetailPopup => WidgetVariant.AgentDetailPopup,
        _ => throw new ArgumentOutOfRangeException(nameof(variant), variant, "Unknown settings widget variant."),
    };
}
