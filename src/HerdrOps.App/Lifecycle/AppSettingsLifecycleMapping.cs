using HerdrOps.App.Localization;
using HerdrOps.App.Widgets;
using HerdrOps.Domain.Settings;

namespace HerdrOps.App.Lifecycle;

public static class AppSettingsLifecycleMapping
{
    public static AppSettingsLanguage ToAppSettingsLanguage(UiLanguage language) => language switch
    {
        UiLanguage.Thai => AppSettingsLanguage.Thai,
        UiLanguage.English => AppSettingsLanguage.English,
        _ => throw new ArgumentOutOfRangeException(nameof(language), language, "Unknown UI language."),
    };

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

    public static AppSettingsWidgetVariant ToAppSettingsWidgetVariant(WidgetVariant variant) => variant switch
    {
        WidgetVariant.Compact => AppSettingsWidgetVariant.Compact,
        WidgetVariant.Normal => AppSettingsWidgetVariant.Normal,
        WidgetVariant.Expanded => AppSettingsWidgetVariant.Expanded,
        WidgetVariant.FloatingMini => AppSettingsWidgetVariant.FloatingMini,
        WidgetVariant.FloatingVertical => AppSettingsWidgetVariant.FloatingVertical,
        WidgetVariant.Notification => AppSettingsWidgetVariant.Notification,
        WidgetVariant.AgentDetailPopup => AppSettingsWidgetVariant.AgentDetailPopup,
        _ => throw new ArgumentOutOfRangeException(nameof(variant), variant, "Unknown widget variant."),
    };
}
