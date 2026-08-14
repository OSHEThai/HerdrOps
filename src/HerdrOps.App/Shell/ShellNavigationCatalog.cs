namespace HerdrOps.App.Shell;

/// <summary>
/// Canonical, ordered navigation catalog for the ten approved HerdrOps pages.
/// </summary>
public static class ShellNavigationCatalog
{
    public static IReadOnlyList<ShellDestination> All { get; } =
    [
        new("overview", "Overview", "ภาพรวม", "\uE80F", "สถานะ Agent กิจกรรม คะแนน การกระจายงาน และการแจ้งเตือน"),
        new("live-organization", "Live Organization", "โครงสร้างองค์กรสด", "\uE716", "บทบาท ลำดับการรายงาน ตำแหน่งว่าง และความขัดแย้งของหน้าที่"),
        new("realtime-activity", "Realtime Activity", "กิจกรรมเรียลไทม์", "\uE9D9", "ลำดับเหตุการณ์ ตัวกรอง รายละเอียด และแหล่งหลักฐาน"),
        new("delegation-graph", "Delegation Graph", "กราฟการมอบหมาย", "\uE8FA", "ต้นไม้งาน ความสัมพันธ์การมอบหมาย และประวัติการส่งต่องาน"),
        new("agent-detail", "Agent Detail", "รายละเอียด Agent", "\uE77B", "ตัวตน งานปัจจุบัน กิจกรรม หลักฐาน คะแนน และ Agent ที่เกี่ยวข้อง"),
        new("task-alignment", "Task Alignment", "ความสอดคล้องของงาน", "\uE9D5", "สัญญามอบหมาย แผน เกณฑ์รับรอง การกระทำจริง และคำขอเบี่ยงเบน"),
        new("file-activity", "File Activity", "กิจกรรมไฟล์", "\uE8A5", "การอ่าน แก้ไข สร้าง ลบไฟล์ รวมถึงระดับความเชื่อมั่นและ Diff"),
        new("compliance-queue", "Compliance Queue", "คิวตรวจสอบความสอดคล้อง", "\uE83D", "เหตุการณ์ต้องสงสัย หลักฐาน และการตรวจสอบตามบทบาท"),
        new("evaluation", "Evaluation", "การประเมิน", "\uE9D2", "แนวโน้มคะแนน มิติการประเมิน และการเปรียบเทียบ Agent"),
        new("daily-summary", "Daily Summary", "สรุปรายวัน", "\uE787", "ไฮไลต์ ปัญหา ข้อเสนอแนะ เหตุการณ์สำคัญ และสรุปสายงาน"),
    ];
}
