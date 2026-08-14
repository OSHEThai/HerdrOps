using HerdrOps.Contracts;

namespace HerdrOps.App.Widgets;

/// <summary>
/// Deterministic state shared by every v0.1 widget variant.
/// </summary>
public sealed class SyntheticWidgetState : IWidgetState
{
    private SyntheticWidgetState(
        IReadOnlyList<WidgetAgent> agents,
        IReadOnlyList<WidgetNotice> notices,
        IReadOnlyList<WidgetActivity> selectedAgentActivity)
    {
        Agents = agents;
        Notices = notices;
        SelectedAgentActivity = selectedAgentActivity;
    }

    public EvidenceClass EvidenceClass => EvidenceClass.Synthetic;

    public bool IsLive => false;

    public string SourceLabel => "SYNTHETIC DATA";

    public string CompactSourceLabel => "SYN";

    public string ConnectionLabel => "Herdr not connected";

    public string CompactConnectionLabel => "Synthetic preview";

    public string ConnectionBrushKey => "HerdrOps.Brush.Status.Working";

    public string GalleryDescription =>
        "ต้นแบบ WPF ทั้ง 7 รูปแบบ · ใช้ข้อมูล Synthetic ชุดเดียวกัน · ยังไม่เชื่อมต่อ Herdr";

    public string DashboardPreviewLabel => "SYNTHETIC PREVIEW";

    public string WindowTitleSuffix => "Synthetic Preview";

    public string DetailsSourceLabel => "รายละเอียดเดียวกันจากสถานะ Synthetic ชุดกลาง";

    public DateTimeOffset SnapshotAt { get; } =
        new(2026, 8, 14, 14, 32, 0, TimeSpan.FromHours(7));

    public long Sequence => 0;

    public int TotalAgents => 12;

    public int WorkingCount => 7;

    public int BlockedCount => 2;

    public int DoneCount => 3;

    public string WorkingCountLabel => WorkingCount.ToString();

    public string BlockedCountLabel => BlockedCount.ToString();

    public string DoneCountLabel => DoneCount.ToString();

    public int DailyScore => 86;

    public int PositiveDelta => 48;

    public int NegativeDelta => -8;

    public string DailyScoreLabel => $"{DailyScore}/100";

    public string PositiveDeltaLabel => $"+{PositiveDelta}";

    public string NegativeDeltaLabel => NegativeDelta.ToString();

    public string LatencyLabel => "Synthetic snapshot";

    public int UpdateSampleCount => 0;

    public double? LastUpdateLatencyMilliseconds => null;

    public double? P95UpdateLatencyMilliseconds => null;

    public IReadOnlyList<WidgetAgent> Agents { get; }

    public IReadOnlyList<WidgetNotice> Notices { get; }

    public IReadOnlyList<WidgetNotice> PriorityNotices => Notices.Take(2).ToArray();

    public WidgetAgent SelectedAgent => Agents[3];

    public IReadOnlyList<WidgetActivity> SelectedAgentActivity { get; }

    public static SyntheticWidgetState Create() =>
        new(
            [
                new("pm", "PM", "Project Manager", "PM", "System", "กำลังตรวจรวมแผนโปรเจกต์", "02:14", 95, "Working", "HerdrOps.Brush.Status.Working", "14:20"),
                new("ps", "PS", "PM Secretary", "Secretary", "Project Manager", "อัปเดตทะเบียนงาน", "00:38", 98, "Review", "HerdrOps.Brush.Status.Review", "14:20"),
                new("bl", "BL", "Backend Leader", "Leader", "Project Manager", "รอข้อมูลจาก Worker", "05:42", 72, "Blocked", "HerdrOps.Brush.Status.Blocked", "14:20"),
                new("bw", "BW", "Backend Worker 01", "Worker", "Backend Leader", "แก้ไขไฟล์ auth/service.cs", "01:27", 88, "Working", "HerdrOps.Brush.Status.Working", "14:20"),
                new("w2", "W2", "Backend Worker 02", "Worker", "Backend Leader", "ทำงาน TASK-118", "00:44", 100, "Done", "HerdrOps.Brush.Status.Done", "14:20"),
                new("w3", "W3", "Backend Worker 03", "Worker", "Backend Leader", "อ่านไฟล์ config.yml", "02:31", 80, "Idle", "HerdrOps.Brush.Status.Idle", "14:20"),
                new("tw", "TW", "Test Worker", "Worker", "Test Leader", "รัน Integration Tests", "03:16", 90, "Working", "HerdrOps.Brush.Status.Working", "14:20"),
                new("dw", "DW", "DevOps Worker", "Worker", "DevOps Leader", "Deploy to staging", "01:02", 85, "Working", "HerdrOps.Brush.Status.Working", "14:20"),
            ],
            [
                new("Backend Leader", "พบงานนอกคำสั่งของ Worker 03", "14:32", "\uE7BA", "HerdrOps.Brush.Status.Blocked", "Blocked"),
                new("Worker 02", "ทำงาน TASK-118 เสร็จแล้ว", "14:30", "\uE73E", "HerdrOps.Brush.Status.Done", "Done"),
                new("PM Secretary", "อัปเดตข้อมูลโครงการแล้ว", "14:30", "\uE946", "HerdrOps.Brush.Status.Review", "Review"),
                new("Project Manager", "อนุมัติแผนงาน Backend", "14:28", "\uE73E", "HerdrOps.Brush.Status.Done", "Done"),
            ],
            [
                new("14:20", "รับงาน TASK-115 จาก Leader"),
                new("14:21", "เปิดไฟล์ auth/service.cs"),
                new("14:22", "แก้ไขไฟล์ auth/service.cs"),
                new("14:25", "บันทึกไฟล์ auth/service.cs"),
            ]);
}
