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
    string DisplayName,
    string ThaiDescription,
    double WindowWidth,
    double WindowHeight,
    bool DefaultTopmost,
    bool ShowInTaskbar);

public sealed record WidgetGalleryItem(
    string Key,
    string DisplayName,
    string ThaiDescription,
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
        new(WidgetVariant.Compact, "Compact Widget", "สรุปสถานะและเหตุการณ์สำคัญ", 300, 330, false, true),
        new(WidgetVariant.Normal, "Normal Widget", "แสดง Agent ทั้งหมดแบบเลื่อนได้", 340, 448, false, true),
        new(WidgetVariant.Expanded, "Expanded Widget", "ตารางกิจกรรมและคะแนนแบบละเอียด", 620, 390, false, true),
        new(WidgetVariant.FloatingMini, "Floating Mini Widget", "สถานะสำคัญสำหรับลอยมุมจอ", 230, 220, true, false),
        new(WidgetVariant.FloatingVertical, "Floating Vertical Widget", "รายชื่อ Agent แนวตั้งที่ประหยัดพื้นที่", 168, 474, true, false),
        new(WidgetVariant.Notification, "Notification Widget", "เหตุการณ์สำคัญแบบเรียลไทม์", 328, 410, true, false),
        new(WidgetVariant.AgentDetailPopup, "Agent Detail Popup", "รายละเอียด Agent และกิจกรรมล่าสุด", 340, 448, false, true),
    ];

    public static WidgetVariantDescriptor Get(WidgetVariant variant) =>
        All.Single(descriptor => descriptor.Variant == variant);

    public static IReadOnlyList<WidgetGalleryItem> CreateAdaptiveGalleryItems()
    {
        var items = All.Select(descriptor => new WidgetGalleryItem(
            descriptor.Variant.ToString(),
            descriptor.DisplayName,
            descriptor.ThaiDescription,
            descriptor.Variant,
            descriptor.WindowWidth,
            descriptor.WindowHeight,
            false,
            "เปิด Widget",
            $"เปิด {descriptor.DisplayName}"))
            .ToList();
        items.Add(new WidgetGalleryItem(
            "Dashboard",
            "Dashboard launch / preview",
            "กลับไปยังหน้าต่างหลักที่ใช้ข้อมูล Synthetic",
            WidgetVariant.Compact,
            1672,
            941,
            true,
            "กลับไปยัง Dashboard",
            "กลับไปยัง Dashboard หลัก"));
        return items;
    }
}
