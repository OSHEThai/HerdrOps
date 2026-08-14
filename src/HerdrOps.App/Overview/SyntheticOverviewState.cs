using HerdrOps.Contracts;

namespace HerdrOps.App.Overview;

/// <summary>
/// Deterministic sample state used exclusively for the v0.1 Overview visual slice.
/// </summary>
public sealed record SyntheticOverviewState(
    EvidenceClass EvidenceClass,
    string SourceLabel,
    string ConnectionLabel,
    DateTimeOffset SnapshotTimestamp,
    IReadOnlyList<OverviewSummaryCard> SummaryCards,
    IReadOnlyList<OverviewActivity> RecentActivities,
    IReadOnlyList<OverviewScorePoint> ScoreTrend,
    IReadOnlyList<OverviewWorkstream> Workstreams,
    IReadOnlyList<OverviewTopAgent> TopAgents,
    IReadOnlyList<OverviewAlert> Alerts)
{
    public string ActivitySourceLabel => "SYNTHETIC";

    public string ActivityFooterLabel => $"{RecentActivities.Count} deterministic events";

    public string WorkDistributionTotal => Workstreams.Sum(workstream => workstream.Count)
        .ToString(System.Globalization.CultureInfo.InvariantCulture);

    public string ScoreTrendStatus => "Synthetic score fixture";

    public string TopAgentsSourceLabel => "SYNTHETIC";

    public string AgentListThaiTitle => "ตัวแทนที่ทำผลงานดี";

    public string AgentListEnglishTitle => "Top Agents";

    public string AlertsCountLabel => $"{Alerts.Count} items";

    public static SyntheticOverviewState Create()
    {
        return new SyntheticOverviewState(
            EvidenceClass.Synthetic,
            "SYNTHETIC DATA",
            "Herdr not connected",
            new DateTimeOffset(2026, 8, 14, 14, 32, 0, TimeSpan.FromHours(7)),
            CreateSummaryCards(),
            CreateActivities(),
            CreateScoreTrend(),
            CreateWorkstreams(),
            CreateTopAgents(),
            CreateAlerts());
    }

    private static IReadOnlyList<OverviewSummaryCard> CreateSummaryCards() =>
    [
        new(
            "สถานะรวม",
            "Total Agents",
            "12",
            "Online 10   Offline 2",
            "Synthetic roster",
            "\uE716",
            OverviewBrushKeys.Primary,
            [4, 5, 5, 7, 6, 8, 7],
            false,
            0),
        new(
            "กำลังทำงาน",
            "Working",
            "7",
            "58%",
            "+1 from baseline",
            "\uE9D9",
            OverviewBrushKeys.Working,
            [3, 4, 6, 5, 7, 9, 7],
            false,
            0),
        new(
            "ติดขัด",
            "Blocked",
            "2",
            "17%",
            "0 change",
            "\uEA39",
            OverviewBrushKeys.Blocked,
            [1, 1, 2, 1, 2, 2, 2],
            false,
            0),
        new(
            "เสร็จสิ้น",
            "Done",
            "3",
            "25%",
            "+1 today",
            "\uE73E",
            OverviewBrushKeys.Done,
            [0, 1, 1, 2, 1, 2, 3],
            false,
            0),
        new(
            "คะแนนวันนี้",
            "Daily Score",
            "86",
            "/100",
            "+5 from yesterday",
            "\uE9D2",
            OverviewBrushKeys.Working,
            [],
            true,
            86),
    ];

    private static IReadOnlyList<OverviewActivity> CreateActivities() =>
    [
        new("14:32", "PM", "Project Manager", "มอบหมายงาน Backend API Integration ให้ Backend Leader", "TASK-118", OverviewBrushKeys.Review),
        new("14:31", "BL", "Backend Leader", "มอบหมายพัฒนา /auth/service.cs ให้ Backend Worker 01", "TASK-115", OverviewBrushKeys.Working),
        new("14:30", "BW", "Backend Worker 01", "เริ่มดำเนินงาน TASK-115 ที่ไฟล์ auth/service.cs", "TASK-115", OverviewBrushKeys.Primary),
        new("14:29", "PS", "PM Secretary", "อัปเดตข้อมูลโครงการ: เปลี่ยนกำหนดส่ง Release v1.2", "PROJECT", OverviewBrushKeys.Review),
        new("14:28", "PM", "Project Manager", "มอบหมายตรวจสอบ Unit Tests ให้ Test Worker", "TASK-120", OverviewBrushKeys.Review),
        new("14:27", "TW", "Test Worker", "อัปโหลดไฟล์รายงานผลการทดสอบ UnitTest_Report_0513.xlsx", "FILE", OverviewBrushKeys.Working),
    ];

    private static IReadOnlyList<OverviewScorePoint> CreateScoreTrend() =>
    [
        new("7 พ.ค.", 62),
        new("8 พ.ค.", 72),
        new("9 พ.ค.", 65),
        new("10 พ.ค.", 78),
        new("11 พ.ค.", 71),
        new("12 พ.ค.", 81),
        new("13 พ.ค.", 86),
    ];

    private static IReadOnlyList<OverviewWorkstream> CreateWorkstreams() =>
    [
        new("Backend", 5, 42, OverviewBrushKeys.Primary),
        new("Frontend", 3, 25, OverviewBrushKeys.Review),
        new("Test", 2, 15, OverviewBrushKeys.Working),
        new("DevOps", 1, 10, OverviewBrushKeys.Idle),
        new("Security", 1, 8, OverviewBrushKeys.Blocked),
    ];

    private static IReadOnlyList<OverviewTopAgent> CreateTopAgents() =>
    [
        new(1, "PS", "PM Secretary", 98, 3, OverviewBrushKeys.Review),
        new(2, "BW", "Backend Worker 02", 95, 5, OverviewBrushKeys.Working),
        new(3, "TW", "Test Worker", 90, 2, OverviewBrushKeys.Working),
        new(4, "BW", "Backend Worker 01", 88, 0, OverviewBrushKeys.Primary),
        new(5, "DW", "DevOps Worker", 85, -1, OverviewBrushKeys.Idle),
    ];

    private static IReadOnlyList<OverviewAlert> CreateAlerts() =>
    [
        new("Backend Leader", "ไม่สามารถอัปโหลดไฟล์ผลงาน 2 รายการเกินกำหนด", "14:31", "Blocked", OverviewBrushKeys.Blocked),
        new("Scope Violation (สงสัย)", "ตรวจพบการแก้ไขไฟล์นอกเหนือจากขอบเขตงานใน TASK-113", "14:29", "Suspected", OverviewBrushKeys.Idle),
        new("PM Secretary", "ยังไม่ได้บันทึกรายงานประจำวัน", "14:28", "Pending", OverviewBrushKeys.Idle),
    ];
}

public sealed record OverviewSummaryCard(
    string ThaiTitle,
    string EnglishTitle,
    string Value,
    string Metric,
    string Trend,
    string IconGlyph,
    string AccentBrushKey,
    IReadOnlyList<double> SparklineValues,
    bool IsGauge,
    double GaugeValue);

public sealed record OverviewActivity(
    string Time,
    string Initials,
    string Agent,
    string Description,
    string Reference,
    string AccentBrushKey);

public sealed record OverviewScorePoint(string DateLabel, double Score);

public sealed record OverviewWorkstream(
    string Name,
    int Count,
    double Percentage,
    string AccentBrushKey);

public sealed record OverviewTopAgent(
    int Rank,
    string Initials,
    string Name,
    int Score,
    int Delta,
    string AccentBrushKey,
    bool HasScore = true,
    string? StatusLabel = null)
{
    public string ScoreLabel => HasScore
        ? Score.ToString(System.Globalization.CultureInfo.InvariantCulture)
        : "—";

    public string DeltaLabel => !HasScore
        ? StatusLabel ?? "Unknown"
        : Delta switch
        {
            > 0 => $"▲ {Delta}",
            < 0 => $"▼ {Math.Abs(Delta)}",
            _ => "—",
        };
}

public sealed record OverviewAlert(
    string Title,
    string Description,
    string Time,
    string State,
    string AccentBrushKey);

public static class OverviewBrushKeys
{
    public const string Primary = "HerdrOps.Brush.Chart.Primary";
    public const string Working = "HerdrOps.Brush.Chart.Working";
    public const string Idle = "HerdrOps.Brush.Chart.Idle";
    public const string Blocked = "HerdrOps.Brush.Chart.Blocked";
    public const string Review = "HerdrOps.Brush.Chart.Review";
    public const string Done = "HerdrOps.Brush.Chart.Done";
    public const string Offline = "HerdrOps.Brush.Status.Offline";
}
