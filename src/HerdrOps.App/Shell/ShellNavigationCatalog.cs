namespace HerdrOps.App.Shell;

/// <summary>
/// Canonical, ordered navigation catalog for the ten approved HerdrOps pages.
/// </summary>
public static class ShellNavigationCatalog
{
    public static IReadOnlyList<ShellDestination> All { get; } =
    [
        new("overview", "Overview", "ภาพรวม", "\uE80F", "Agent status, activity, scores, work distribution, and alerts", "สถานะเอเจนต์ กิจกรรม คะแนน การกระจายงาน และการแจ้งเตือน"),
        new("live-organization", "Live Organization", "โครงสร้างองค์กรสด", "\uE716", "Roles, reporting order, vacancies, and role conflicts", "บทบาท ลำดับการรายงาน ตำแหน่งว่าง และความขัดแย้งของหน้าที่"),
        new("realtime-activity", "Realtime Activity", "กิจกรรมเวลาจริง", "\uE9D9", "Event timeline, filters, details, and evidence sources", "ลำดับเหตุการณ์ ตัวกรอง รายละเอียด และแหล่งหลักฐาน"),
        new("delegation-graph", "Delegation Graph", "กราฟการมอบหมาย", "\uE8FA", "Task tree, delegation relationships, and handoff history", "ต้นไม้งาน ความสัมพันธ์การมอบหมาย และประวัติการส่งต่องาน"),
        new("agent-detail", "Agent Detail", "รายละเอียดเอเจนต์", "\uE77B", "Identity, current work, activity, evidence, scores, and related Agents", "ตัวตน งานปัจจุบัน กิจกรรม หลักฐาน คะแนน และเอเจนต์ที่เกี่ยวข้อง"),
        new("task-alignment", "Task Alignment", "ความสอดคล้องของงาน", "\uE9D5", "Assignment contract, plan, acceptance criteria, actual actions, and deviations", "สัญญามอบหมาย แผน เกณฑ์รับรอง การกระทำจริง และคำขอเบี่ยงเบน"),
        new("file-activity", "File Activity", "กิจกรรมไฟล์", "\uE8A5", "File reads, edits, creation, deletion, confidence, and differences", "การอ่าน แก้ไข สร้าง และลบไฟล์ รวมถึงระดับความเชื่อมั่นและความแตกต่าง"),
        new("compliance-queue", "Compliance Queue", "คิวตรวจความสอดคล้อง", "\uE83D", "Suspected events, evidence, and role-based review", "เหตุการณ์ต้องสงสัย หลักฐาน และการตรวจสอบตามบทบาท"),
        new("evaluation", "Evaluation", "การประเมิน", "\uE9D2", "Score trends, evaluation dimensions, and Agent comparison", "แนวโน้มคะแนน มิติการประเมิน และการเปรียบเทียบเอเจนต์"),
        new("daily-summary", "Daily Summary", "สรุปรายวัน", "\uE787", "Highlights, issues, recommendations, key events, and workstream summaries", "ไฮไลต์ ปัญหา ข้อเสนอแนะ เหตุการณ์สำคัญ และสรุปสายงาน"),
    ];
}
