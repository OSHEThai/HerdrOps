using HerdrOps.App.Localization;

namespace HerdrOps.App.Widgets;

/// <summary>
/// The seven widget variants approved by the v0.1 visual contract.
/// </summary>
public enum WidgetVariant
{
    Compact,
    Normal,
    Expanded,
    FloatingMini,
    FloatingVertical,
    Notification,
    AgentDetailPopup,
}

public sealed record WidgetVariantDescriptor(
    WidgetVariant Variant,
    string NameKey,
    string DescriptionKey,
    double WindowWidth,
    double WindowHeight,
    bool DefaultTopmost,
    bool ShowInTaskbar)
{
    public string DisplayName => UiLanguageService.Shared[NameKey];

    public string Description => UiLanguageService.Shared[DescriptionKey];
}

public sealed record WidgetGalleryItem(
    string Key,
    string DisplayName,
    string Description,
    WidgetVariant Variant,
    double PreviewWidth,
    double PreviewHeight,
    bool IsDashboard,
    string ActionLabel,
    string AutomationName);

/// <summary>
/// Single source of truth for widget names, dimensions, and window policies.
/// </summary>
public static class WidgetCatalog
{
    public static IReadOnlyList<WidgetVariantDescriptor> All { get; } =
    [
        new(WidgetVariant.Compact, "WidgetCompactName", "WidgetCompactDescription", 300, 330, false, true),
        new(WidgetVariant.Normal, "WidgetNormalName", "WidgetNormalDescription", 340, 448, false, true),
        new(WidgetVariant.Expanded, "WidgetExpandedName", "WidgetExpandedDescription", 620, 390, false, true),
        new(WidgetVariant.FloatingMini, "WidgetMiniName", "WidgetMiniDescription", 230, 220, true, false),
        new(WidgetVariant.FloatingVertical, "WidgetVerticalName", "WidgetVerticalDescription", 168, 474, true, false),
        new(WidgetVariant.Notification, "WidgetNotificationName", "WidgetNotificationDescription", 328, 410, true, false),
        new(WidgetVariant.AgentDetailPopup, "WidgetAgentDetailName", "WidgetAgentDetailDescription", 340, 448, false, true),
    ];

    public static WidgetVariantDescriptor Get(WidgetVariant variant) =>
        All.Single(descriptor => descriptor.Variant == variant);

    public static IReadOnlyList<WidgetGalleryItem> CreateAdaptiveGalleryItems()
    {
        var text = UiLanguageService.Shared;
        var items = All.Select(descriptor => new WidgetGalleryItem(
            descriptor.Variant.ToString(),
            descriptor.DisplayName,
            descriptor.Description,
            descriptor.Variant,
            descriptor.WindowWidth,
            descriptor.WindowHeight,
            false,
            text["WidgetOpen"],
            $"{text["WidgetOpen"]}: {descriptor.DisplayName}"))
            .ToList();
        items.Add(new WidgetGalleryItem(
            "Dashboard",
            text["WidgetDashboardName"],
            text["WidgetDashboardDescription"],
            WidgetVariant.Compact,
            1672,
            941,
            true,
            text["WidgetBackDashboard"],
            text["WidgetBackDashboardAutomation"]));
        return items;
    }
}
