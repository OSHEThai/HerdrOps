using HerdrOps.Contracts;

namespace HerdrOps.App.Widgets;

/// <summary>
/// Deterministic state shared by every v0.1 widget variant.
/// </summary>
public sealed class SyntheticWidgetState
{
    private SyntheticWidgetState(
        IReadOnlyList<SyntheticWidgetAgent> agents,
        IReadOnlyList<SyntheticWidgetNotice> notices,
        IReadOnlyList<SyntheticWidgetActivity> selectedAgentActivity)
    {
        Agents = agents;
        Notices = notices;
        SelectedAgentActivity = selectedAgentActivity;
    }

    public EvidenceClass EvidenceClass => EvidenceClass.Synthetic;

    public string SourceLabel => "SYNTHETIC DATA";

    public string ConnectionLabel => "Herdr not connected";

    public DateTimeOffset SnapshotAt { get; } =
        new(2026, 8, 14, 14, 32, 0, TimeSpan.FromHours(7));

    public int TotalAgents => 12;

    public int WorkingCount => 7;

    public int BlockedCount => 2;

    public int DoneCount => 3;

    public int DailyScore => 86;

    public int PositiveDelta => 48;

    public int NegativeDelta => -8;

    public IReadOnlyList<SyntheticWidgetAgent> Agents { get; }

    public IReadOnlyList<SyntheticWidgetNotice> Notices { get; }

    public IReadOnlyList<SyntheticWidgetNotice> PriorityNotices => Notices.Take(2).ToArray();

    public SyntheticWidgetAgent SelectedAgent => Agents[3];

    public IReadOnlyList<SyntheticWidgetActivity> SelectedAgentActivity { get; }

    public static SyntheticWidgetState Create() =>
        new(
            [
                new("PM", "Project Manager", "PM", "กำลังตรวจรวมแผนโปรเจกต์", "02:14", 95, "Working", "HerdrOps.Brush.Status.Working"),
                new("PS", "PM Secretary", "Secretary", "อัปเดตทะเบียนงาน", "00:38", 98, "Review", "HerdrOps.Brush.Status.Review"),
                new("BL", "Backend Leader", "Leader", "รอข้อมูลจาก Worker", "05:42", 72, "Blocked", "HerdrOps.Brush.Status.Blocked"),
                new("BW", "Backend Worker 01", "Worker", "แก้ไขไฟล์ auth/service.cs", "01:27", 88, "Working", "HerdrOps.Brush.Status.Working"),
                new("W2", "Backend Worker 02", "Worker", "ทำงาน TASK-118", "00:44", 100, "Done", "HerdrOps.Brush.Status.Done"),
                new("W3", "Backend Worker 03", "Worker", "อ่านไฟล์ config.yml", "02:31", 80, "Idle", "HerdrOps.Brush.Status.Idle"),
                new("TW", "Test Worker", "Worker", "รัน Integration Tests", "03:16", 90, "Working", "HerdrOps.Brush.Status.Working"),
                new("DW", "DevOps Worker", "Worker", "Deploy to staging", "01:02", 85, "Working", "HerdrOps.Brush.Status.Working"),
            ],
            [
                new("Backend Leader", "พบงานนอกคำสั่งของ Worker 03", "14:32", "HerdrOps.Brush.Status.Blocked"),
                new("Worker 02", "ทำงาน TASK-118 เสร็จแล้ว", "14:30", "HerdrOps.Brush.Status.Working"),
                new("PM Secretary", "อัปเดตข้อมูลโครงการแล้ว", "14:30", "HerdrOps.Brush.Status.Review"),
                new("Project Manager", "อนุมัติแผนงาน Backend", "14:28", "HerdrOps.Brush.Status.Done"),
            ],
            [
                new("14:20", "รับงาน TASK-115 จาก Leader"),
                new("14:21", "เปิดไฟล์ auth/service.cs"),
                new("14:22", "แก้ไขไฟล์ auth/service.cs"),
                new("14:25", "บันทึกไฟล์ auth/service.cs"),
            ]);
}

public sealed record SyntheticWidgetAgent(
    string Initials,
    string Name,
    string Role,
    string Activity,
    string Elapsed,
    int Score,
    string Status,
    string StatusBrushKey);

public sealed record SyntheticWidgetNotice(
    string AgentName,
    string Message,
    string Time,
    string StatusBrushKey);

public sealed record SyntheticWidgetActivity(string Time, string Description);
