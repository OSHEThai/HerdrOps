using System.ComponentModel;
using System.Globalization;
using System.Runtime.CompilerServices;

namespace HerdrOps.App.Localization;

/// <summary>
/// Supplies one complete language catalog to every WPF surface.
/// Technical values such as product names, identifiers, and paths remain data and are not translated here.
/// </summary>
public sealed class UiLanguageService : INotifyPropertyChanged
{
    private static readonly IReadOnlyDictionary<string, string> Thai =
        new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["LanguageThai"] = "ไทย",
            ["LanguageEnglish"] = "อังกฤษ",
            ["SelectThai"] = "เปลี่ยนภาษาเป็นภาษาไทย",
            ["SelectEnglish"] = "เปลี่ยนภาษาเป็นภาษาอังกฤษ",
            ["ToggleNavigation"] = "ย่อหรือขยายแถบนำทาง",
            ["MinimizeWindow"] = "ย่อหน้าต่าง",
            ["MaximizeWindow"] = "ขยายหรือคืนขนาดหน้าต่าง",
            ["CloseWindow"] = "ปิดหน้าต่าง",
            ["MainNavigation"] = "หน้าหลักของ HerdrOps",
            ["ProjectPrefix"] = "โครงการ",
            ["StatusWorking"] = "กำลังทำงาน",
            ["StatusIdle"] = "ว่าง",
            ["StatusBlocked"] = "ติดขัด",
            ["StatusReview"] = "รอตรวจ",
            ["StatusOffline"] = "ออฟไลน์",
            ["StatusDone"] = "เสร็จแล้ว",
            ["StatusUnknown"] = "ไม่ทราบ",
            ["AgentSingular"] = "เอเจนต์",
            ["AgentPlural"] = "เอเจนต์",
            ["OpenWidgetGallery"] = "เปิดแกลเลอรีวิดเจ็ต",
            ["WidgetGalleryButton"] = "แกลเลอรีวิดเจ็ต",
            ["OverviewRecentActivity"] = "กิจกรรมล่าสุด",
            ["OverviewScoreTrend"] = "แนวโน้มคะแนนรายวัน 7 วัน",
            ["OverviewWorkDistribution"] = "การกระจายงาน",
            ["OverviewTopAgents"] = "เอเจนต์ที่ทำผลงานดี",
            ["OverviewAgentStatus"] = "สถานะเอเจนต์",
            ["OverviewAlerts"] = "การแจ้งเตือน",
            ["OverviewItemsFormat"] = "{0} รายการ",
            ["SyntheticData"] = "ข้อมูลจำลอง",
            ["SyntheticCompact"] = "จำลอง",
            ["SyntheticPreview"] = "ตัวอย่างจำลอง",
            ["SyntheticShellPreview"] = "ตัวอย่างเชลล์จากข้อมูลจำลอง",
            ["SyntheticRoster"] = "รายชื่อจำลอง",
            ["SyntheticSnapshot"] = "สแนปช็อตจำลอง",
            ["SyntheticProfile"] = "โปรไฟล์จำลอง",
            ["PreviewStatus"] = "ตัวอย่าง",
            ["HerdrNotConnected"] = "ยังไม่เชื่อมต่อ Herdr",
            ["NoActiveWorkspace"] = "ไม่มีพื้นที่ทำงานที่ใช้งานอยู่",
            ["UiPreviewReady"] = "ตัวอย่างส่วนติดต่อพร้อมใช้งาน",
            ["WaitingForCore"] = "กำลังรอบริการแกนระบบของผู้ใช้",
            ["LastCoreUpdateEmpty"] = "อัปเดตแกนระบบล่าสุด: —",
            ["OverviewActivitySource"] = "ข้อมูลจำลอง",
            ["OverviewActivityFooterFormat"] = "เหตุการณ์จำลองแบบกำหนดแน่นอน {0} รายการ",
            ["OverviewScoreFixture"] = "ชุดคะแนนจำลอง",
            ["OverviewTopAgentsSource"] = "ข้อมูลจำลอง",
            ["OverviewTotalAgents"] = "เอเจนต์ทั้งหมด",
            ["OverviewOnlineOffline"] = "ออนไลน์ 10   ออฟไลน์ 2",
            ["OverviewWorking"] = "กำลังทำงาน",
            ["OverviewBlocked"] = "ติดขัด",
            ["OverviewDone"] = "เสร็จสิ้น",
            ["OverviewDailyScore"] = "คะแนนวันนี้",
            ["OverviewFromBaseline"] = "+1 จากค่าฐาน",
            ["OverviewNoChange"] = "ไม่เปลี่ยนแปลง",
            ["OverviewTodayDelta"] = "+1 วันนี้",
            ["OverviewYesterdayDelta"] = "+5 จากเมื่อวาน",
            ["OverviewActivityPmAssign"] = "มอบหมายงานเชื่อมต่อส่วนหลังให้หัวหน้าส่วนหลัง",
            ["OverviewActivityLeaderAssign"] = "มอบหมายการพัฒนาไฟล์ /auth/service.cs ให้ผู้ปฏิบัติงานส่วนหลัง 01",
            ["OverviewActivityWorkerStart"] = "เริ่มดำเนินงาน TASK-115 ที่ไฟล์ auth/service.cs",
            ["OverviewActivitySecretaryUpdate"] = "อัปเดตข้อมูลโครงการและเปลี่ยนกำหนดส่งรุ่น v1.2",
            ["OverviewActivityPmTest"] = "มอบหมายการตรวจสอบชุดทดสอบให้ผู้ทดสอบ",
            ["OverviewActivityUpload"] = "อัปโหลดรายงานผลการทดสอบ UnitTest_Report_0513.xlsx",
            ["OverviewAlertUploadTitle"] = "หัวหน้าส่วนหลัง",
            ["OverviewAlertUploadText"] = "ไม่สามารถอัปโหลดผลงาน 2 รายการภายในกำหนด",
            ["OverviewAlertScopeTitle"] = "สงสัยว่าทำงานนอกขอบเขต",
            ["OverviewAlertScopeText"] = "ตรวจพบการแก้ไขไฟล์นอกขอบเขตของ TASK-113",
            ["OverviewAlertSecretaryTitle"] = "เลขานุการผู้จัดการโครงการ",
            ["OverviewAlertSecretaryText"] = "ยังไม่ได้บันทึกรายงานประจำวัน",
            ["StateSuspected"] = "ต้องสงสัย",
            ["StatePending"] = "รอดำเนินการ",
            ["WidgetGalleryTitle"] = "แกลเลอรีวิดเจ็ต HerdrOps",
            ["WidgetGalleryDescription"] = "ตัวอย่าง WPF ทั้ง 7 รูปแบบ ใช้ข้อมูลจำลองชุดเดียวกัน และยังไม่เชื่อมต่อ Herdr",
            ["WidgetOpen"] = "เปิดวิดเจ็ต",
            ["WidgetBackDashboard"] = "กลับไปยังแดชบอร์ด",
            ["WidgetBackDashboardAutomation"] = "กลับไปยังแดชบอร์ดหลัก",
            ["WidgetKeyboardHelp"] = "แป้นพิมพ์: Tab / Shift+Tab · Enter / Space · วิดเจ็ต: Esc, Ctrl+T, Ctrl+0",
            ["WidgetKeyboardShort"] = "Tab / Shift+Tab · Enter / Space",
            ["WidgetCompactName"] = "วิดเจ็ตแบบกะทัดรัด",
            ["WidgetCompactDescription"] = "สรุปสถานะและเหตุการณ์สำคัญ",
            ["WidgetNormalName"] = "วิดเจ็ตแบบมาตรฐาน",
            ["WidgetNormalDescription"] = "แสดงเอเจนต์ทั้งหมดแบบเลื่อนได้",
            ["WidgetExpandedName"] = "วิดเจ็ตแบบขยาย",
            ["WidgetExpandedDescription"] = "ตารางกิจกรรมและคะแนนแบบละเอียด",
            ["WidgetMiniName"] = "วิดเจ็ตลอยขนาดเล็ก",
            ["WidgetMiniDescription"] = "สถานะสำคัญสำหรับมุมจอ",
            ["WidgetVerticalName"] = "วิดเจ็ตลอยแนวตั้ง",
            ["WidgetVerticalDescription"] = "รายชื่อเอเจนต์แนวตั้งที่ประหยัดพื้นที่",
            ["WidgetNotificationName"] = "วิดเจ็ตแจ้งเตือน",
            ["WidgetNotificationDescription"] = "เหตุการณ์สำคัญแบบเวลาจริง",
            ["WidgetAgentDetailName"] = "หน้าต่างรายละเอียดเอเจนต์",
            ["WidgetAgentDetailDescription"] = "รายละเอียดเอเจนต์และกิจกรรมล่าสุด",
            ["WidgetDashboardName"] = "ตัวอย่างและทางลัดแดชบอร์ด",
            ["WidgetDashboardDescription"] = "ตัวอย่างหน้าต่างหลักและทางลัดกลับแดชบอร์ด",
            ["WidgetDashboardTitle"] = "แดชบอร์ด HerdrOps",
            ["WidgetDashboardPreview"] = "ตัวอย่างจำลอง",
            ["WidgetPin"] = "ปักหมุดหรือยกเลิกการอยู่บนสุด",
            ["WidgetClose"] = "ปิดวิดเจ็ต",
            ["WidgetResetPosition"] = "คืนวิดเจ็ตไปยังตำแหน่งที่มองเห็นได้",
            ["WidgetScoreToday"] = "คะแนนวันนี้",
            ["WidgetOverallScore"] = "คะแนนรวมวันนี้",
            ["WidgetAgent"] = "เอเจนต์",
            ["WidgetAllAgentsList"] = "รายชื่อเอเจนต์ทั้งหมดในวิดเจ็ตลอยแนวตั้ง",
            ["WidgetRole"] = "บทบาท",
            ["WidgetActivity"] = "งานหรือกิจกรรม",
            ["WidgetTime"] = "เวลา",
            ["WidgetScore"] = "คะแนน",
            ["WidgetLatestActivity"] = "กิจกรรมล่าสุด",
            ["WidgetStatus"] = "สถานะ",
            ["WidgetTask"] = "งาน",
            ["WidgetStarted"] = "เริ่มเมื่อ",
            ["WidgetAssignedBy"] = "มอบหมายโดย",
            ["WidgetViewAll"] = "ดูทั้งหมด",
            ["WidgetViewAgentDetails"] = "ดูรายละเอียดเอเจนต์ทั้งหมด",
            ["WidgetViewAllDetails"] = "ดูรายละเอียดทั้งหมด",
            ["WidgetDetailsSource"] = "รายละเอียดจากสถานะจำลองชุดกลาง",
            ["WidgetWindowSuffix"] = "ตัวอย่างจำลอง",
            ["WidgetAgentPmRole"] = "ผู้จัดการโครงการ",
            ["WidgetAgentSecretaryRole"] = "เลขานุการ",
            ["WidgetAgentLeaderRole"] = "หัวหน้าทีม",
            ["WidgetAgentWorkerRole"] = "ผู้ปฏิบัติงาน",
            ["WidgetAssignedSystem"] = "ระบบ",
            ["WidgetActivityPlan"] = "กำลังตรวจแผนโครงการรวม",
            ["WidgetActivityRegistry"] = "อัปเดตทะเบียนงาน",
            ["WidgetActivityWaiting"] = "กำลังรอข้อมูลจากผู้ปฏิบัติงาน",
            ["WidgetActivityEditing"] = "แก้ไขไฟล์ auth/service.cs",
            ["WidgetActivityTask"] = "ดำเนินงาน TASK-118",
            ["WidgetActivityReading"] = "อ่านไฟล์ config.yml",
            ["WidgetActivityTesting"] = "รันชุดทดสอบการเชื่อมต่อ",
            ["WidgetActivityDeploy"] = "นำขึ้นระบบทดสอบ",
            ["WidgetNoticeCommand"] = "พบงานนอกคำสั่งของผู้ปฏิบัติงาน 03",
            ["WidgetNoticeDone"] = "ดำเนินงาน TASK-118 เสร็จแล้ว",
            ["WidgetNoticeUpdated"] = "อัปเดตข้อมูลโครงการแล้ว",
            ["WidgetNoticeApproved"] = "อนุมัติแผนงานส่วนหลัง",
            ["WidgetFactReceived"] = "รับงาน TASK-115 จากหัวหน้าทีม",
            ["WidgetFactOpened"] = "เปิดไฟล์ auth/service.cs",
            ["WidgetFactEdited"] = "แก้ไขไฟล์ auth/service.cs",
            ["WidgetFactSaved"] = "บันทึกไฟล์ auth/service.cs",
            ["PlaceholderSyntheticPreview"] = "ตัวอย่างเชลล์จากข้อมูลจำลอง",
            ["PlaceholderSource"] = "แหล่งข้อมูล",
            ["PlaceholderSyntheticOnly"] = "ข้อมูลจำลองเท่านั้น",
            ["PlaceholderNoRealAgents"] = "ไม่มีข้อมูลเอเจนต์จริงในหน้าตัวอย่างนี้",
            ["PlaceholderRoute"] = "เส้นทางหน้าจอ",
            ["PlaceholderRegisteredRoute"] = "หนึ่งในสิบเส้นทางมาตรฐานที่ลงทะเบียนแล้ว",
            ["PlaceholderConnection"] = "การเชื่อมต่อ",
            ["PlaceholderV02Connection"] = "การเชื่อมต่อจริงเริ่มในขอบเขต v0.2",
            ["PlaceholderReady"] = "โครงหน้าจอพร้อมสำหรับเนื้อหาของรุ่นที่กำหนด",
            ["PlaceholderEvidenceBoundary"] = "หน้าตัวอย่างนี้ยืนยันโทเค็นการออกแบบ การนำทาง และเชลล์ที่ปรับตามขนาดเท่านั้น ไม่ใช่หลักฐานข้อมูลหรือสถานะจริงจาก Herdr",
            ["PlaceholderKeyboard"] = "แป้นพิมพ์: Ctrl+PageUp / Ctrl+PageDown · Alt+Home / Alt+End",
        };

    private static readonly IReadOnlyDictionary<string, string> English =
        new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["LanguageThai"] = "Thai",
            ["LanguageEnglish"] = "English",
            ["SelectThai"] = "Switch to Thai",
            ["SelectEnglish"] = "Switch to English",
            ["ToggleNavigation"] = "Collapse or expand navigation",
            ["MinimizeWindow"] = "Minimize window",
            ["MaximizeWindow"] = "Maximize or restore window",
            ["CloseWindow"] = "Close window",
            ["MainNavigation"] = "HerdrOps main navigation",
            ["ProjectPrefix"] = "Project",
            ["StatusWorking"] = "Working",
            ["StatusIdle"] = "Idle",
            ["StatusBlocked"] = "Blocked",
            ["StatusReview"] = "Review",
            ["StatusOffline"] = "Offline",
            ["StatusDone"] = "Done",
            ["StatusUnknown"] = "Unknown",
            ["AgentSingular"] = "Agent",
            ["AgentPlural"] = "Agents",
            ["OpenWidgetGallery"] = "Open Widget Gallery",
            ["WidgetGalleryButton"] = "Widget Gallery",
            ["OverviewRecentActivity"] = "Recent Activity",
            ["OverviewScoreTrend"] = "Daily Score Trend (7 days)",
            ["OverviewWorkDistribution"] = "Work Distribution",
            ["OverviewTopAgents"] = "Top Agents",
            ["OverviewAgentStatus"] = "Agent Status",
            ["OverviewAlerts"] = "Alerts",
            ["OverviewItemsFormat"] = "{0} items",
            ["SyntheticData"] = "SYNTHETIC DATA",
            ["SyntheticCompact"] = "SYN",
            ["SyntheticPreview"] = "Synthetic Preview",
            ["SyntheticShellPreview"] = "SYNTHETIC SHELL PREVIEW",
            ["SyntheticRoster"] = "Synthetic roster",
            ["SyntheticSnapshot"] = "Synthetic snapshot",
            ["SyntheticProfile"] = "Synthetic profile",
            ["PreviewStatus"] = "Preview",
            ["HerdrNotConnected"] = "Herdr not connected",
            ["NoActiveWorkspace"] = "No active workspace",
            ["UiPreviewReady"] = "UI preview ready",
            ["WaitingForCore"] = "Waiting for the per-user Core state service",
            ["LastCoreUpdateEmpty"] = "Last Core update: —",
            ["OverviewActivitySource"] = "SYNTHETIC",
            ["OverviewActivityFooterFormat"] = "{0} deterministic events",
            ["OverviewScoreFixture"] = "Synthetic score fixture",
            ["OverviewTopAgentsSource"] = "SYNTHETIC",
            ["OverviewTotalAgents"] = "Total Agents",
            ["OverviewOnlineOffline"] = "Online 10   Offline 2",
            ["OverviewWorking"] = "Working",
            ["OverviewBlocked"] = "Blocked",
            ["OverviewDone"] = "Done",
            ["OverviewDailyScore"] = "Daily Score",
            ["OverviewFromBaseline"] = "+1 from baseline",
            ["OverviewNoChange"] = "No change",
            ["OverviewTodayDelta"] = "+1 today",
            ["OverviewYesterdayDelta"] = "+5 from yesterday",
            ["OverviewActivityPmAssign"] = "Assigned Backend API Integration to Backend Leader",
            ["OverviewActivityLeaderAssign"] = "Assigned /auth/service.cs development to Backend Worker 01",
            ["OverviewActivityWorkerStart"] = "Started TASK-115 in auth/service.cs",
            ["OverviewActivitySecretaryUpdate"] = "Updated the project and changed the v1.2 release date",
            ["OverviewActivityPmTest"] = "Assigned unit test verification to Test Worker",
            ["OverviewActivityUpload"] = "Uploaded the UnitTest_Report_0513.xlsx test report",
            ["OverviewAlertUploadTitle"] = "Backend Leader",
            ["OverviewAlertUploadText"] = "Two deliverables were not uploaded by the deadline",
            ["OverviewAlertScopeTitle"] = "Suspected Scope Violation",
            ["OverviewAlertScopeText"] = "A file outside the TASK-113 scope was modified",
            ["OverviewAlertSecretaryTitle"] = "PM Secretary",
            ["OverviewAlertSecretaryText"] = "The daily report has not been recorded",
            ["StateSuspected"] = "Suspected",
            ["StatePending"] = "Pending",
            ["WidgetGalleryTitle"] = "HerdrOps Widget Gallery",
            ["WidgetGalleryDescription"] = "Seven WPF variants share one synthetic data set and are not connected to Herdr",
            ["WidgetOpen"] = "Open Widget",
            ["WidgetBackDashboard"] = "Back to Dashboard",
            ["WidgetBackDashboardAutomation"] = "Return to the main Dashboard",
            ["WidgetKeyboardHelp"] = "Keyboard: Tab / Shift+Tab · Enter / Space · Widget: Esc, Ctrl+T, Ctrl+0",
            ["WidgetKeyboardShort"] = "Tab / Shift+Tab · Enter / Space",
            ["WidgetCompactName"] = "Compact Widget",
            ["WidgetCompactDescription"] = "Summary status and important events",
            ["WidgetNormalName"] = "Normal Widget",
            ["WidgetNormalDescription"] = "Scrollable list of all Agents",
            ["WidgetExpandedName"] = "Expanded Widget",
            ["WidgetExpandedDescription"] = "Detailed activity and score table",
            ["WidgetMiniName"] = "Floating Mini Widget",
            ["WidgetMiniDescription"] = "Important status for a screen corner",
            ["WidgetVerticalName"] = "Floating Vertical Widget",
            ["WidgetVerticalDescription"] = "Space-efficient vertical Agent list",
            ["WidgetNotificationName"] = "Notification Widget",
            ["WidgetNotificationDescription"] = "Important events in real time",
            ["WidgetAgentDetailName"] = "Agent Detail Popup",
            ["WidgetAgentDetailDescription"] = "Agent details and recent activity",
            ["WidgetDashboardName"] = "Dashboard launch and preview",
            ["WidgetDashboardDescription"] = "Main-window preview and Dashboard shortcut",
            ["WidgetDashboardTitle"] = "HerdrOps Dashboard",
            ["WidgetDashboardPreview"] = "SYNTHETIC PREVIEW",
            ["WidgetPin"] = "Toggle always on top",
            ["WidgetClose"] = "Close Widget",
            ["WidgetResetPosition"] = "Return Widget to a visible position",
            ["WidgetScoreToday"] = "Today's score",
            ["WidgetOverallScore"] = "Overall score today",
            ["WidgetAgent"] = "Agent",
            ["WidgetAllAgentsList"] = "All Agents in the Floating Vertical Widget",
            ["WidgetRole"] = "Role",
            ["WidgetActivity"] = "Task or activity",
            ["WidgetTime"] = "Time",
            ["WidgetScore"] = "Score",
            ["WidgetLatestActivity"] = "Recent Activity",
            ["WidgetStatus"] = "Status",
            ["WidgetTask"] = "Task",
            ["WidgetStarted"] = "Started",
            ["WidgetAssignedBy"] = "Assigned by",
            ["WidgetViewAll"] = "View all",
            ["WidgetViewAgentDetails"] = "View all Agent details",
            ["WidgetViewAllDetails"] = "View all details",
            ["WidgetDetailsSource"] = "Details from the shared synthetic state",
            ["WidgetWindowSuffix"] = "Synthetic Preview",
            ["WidgetAgentPmRole"] = "Project Manager",
            ["WidgetAgentSecretaryRole"] = "Secretary",
            ["WidgetAgentLeaderRole"] = "Leader",
            ["WidgetAgentWorkerRole"] = "Worker",
            ["WidgetAssignedSystem"] = "System",
            ["WidgetActivityPlan"] = "Reviewing the consolidated project plan",
            ["WidgetActivityRegistry"] = "Updating the task register",
            ["WidgetActivityWaiting"] = "Waiting for Worker input",
            ["WidgetActivityEditing"] = "Editing auth/service.cs",
            ["WidgetActivityTask"] = "Working on TASK-118",
            ["WidgetActivityReading"] = "Reading config.yml",
            ["WidgetActivityTesting"] = "Running integration tests",
            ["WidgetActivityDeploy"] = "Deploying to staging",
            ["WidgetNoticeCommand"] = "Worker 03 performed work outside the instruction",
            ["WidgetNoticeDone"] = "TASK-118 is complete",
            ["WidgetNoticeUpdated"] = "Project information was updated",
            ["WidgetNoticeApproved"] = "The Backend plan was approved",
            ["WidgetFactReceived"] = "Received TASK-115 from the Leader",
            ["WidgetFactOpened"] = "Opened auth/service.cs",
            ["WidgetFactEdited"] = "Edited auth/service.cs",
            ["WidgetFactSaved"] = "Saved auth/service.cs",
            ["PlaceholderSyntheticPreview"] = "Synthetic shell preview",
            ["PlaceholderSource"] = "Data source",
            ["PlaceholderSyntheticOnly"] = "Synthetic only",
            ["PlaceholderNoRealAgents"] = "No real Agent data is shown in this preview",
            ["PlaceholderRoute"] = "Screen route",
            ["PlaceholderRegisteredRoute"] = "One of ten registered canonical routes",
            ["PlaceholderConnection"] = "Connection",
            ["PlaceholderV02Connection"] = "Live connectivity starts in the v0.2 scope",
            ["PlaceholderReady"] = "The screen frame is ready for its planned version content",
            ["PlaceholderEvidenceBoundary"] = "This preview verifies design tokens, navigation, and the responsive shell only. It is not evidence of real Herdr data or status.",
            ["PlaceholderKeyboard"] = "Keyboard: Ctrl+PageUp / Ctrl+PageDown · Alt+Home / Alt+End",
        };

    private UiLanguage _currentLanguage = UiLanguage.Thai;

    private UiLanguageService()
    {
        ValidateCatalogs();
    }

    public static UiLanguageService Shared { get; } = new();

    public static UiLanguage DefaultLanguage => UiLanguage.Thai;

    public event PropertyChangedEventHandler? PropertyChanged;

    public event EventHandler? LanguageChanged;

    public UiLanguage CurrentLanguage
    {
        get => _currentLanguage;
        private set
        {
            if (_currentLanguage == value)
            {
                return;
            }

            _currentLanguage = value;
            OnPropertyChanged();
            OnPropertyChanged(nameof(IsThai));
            OnPropertyChanged(nameof(IsEnglish));
            OnPropertyChanged("Item[]");
        }
    }

    public bool IsThai => CurrentLanguage == UiLanguage.Thai;

    public bool IsEnglish => CurrentLanguage == UiLanguage.English;

    public string this[string key] => Catalog(CurrentLanguage).TryGetValue(key, out var value)
        ? value
        : throw new KeyNotFoundException($"Missing {CurrentLanguage} UI text key: {key}");

    public IReadOnlyCollection<string> Keys(UiLanguage language) => Catalog(language).Keys.ToArray();

    public string Text(UiLanguage language, string key) => Catalog(language).TryGetValue(key, out var value)
        ? value
        : throw new KeyNotFoundException($"Missing {language} UI text key: {key}");

    public string Format(string key, params object[] arguments) => string.Format(
        CultureInfo.GetCultureInfo(CurrentLanguage == UiLanguage.Thai ? "th-TH" : "en-US"),
        this[key],
        arguments);

    public void SetLanguage(UiLanguage language)
    {
        if (CurrentLanguage == language)
        {
            return;
        }

        CurrentLanguage = language;
        CultureInfo.CurrentUICulture = CultureInfo.GetCultureInfo(
            language == UiLanguage.Thai ? "th-TH" : "en-US");
        LanguageChanged?.Invoke(this, EventArgs.Empty);
    }

    private static IReadOnlyDictionary<string, string> Catalog(UiLanguage language) =>
        language == UiLanguage.Thai ? Thai : English;

    private static void ValidateCatalogs()
    {
        var missingEnglish = Thai.Keys.Except(English.Keys, StringComparer.Ordinal).ToArray();
        var missingThai = English.Keys.Except(Thai.Keys, StringComparer.Ordinal).ToArray();
        if (missingEnglish.Length == 0 && missingThai.Length == 0)
        {
            return;
        }

        throw new InvalidOperationException(
            $"UI language catalogs differ. Missing English: {string.Join(", ", missingEnglish)}; " +
            $"missing Thai: {string.Join(", ", missingThai)}.");
    }

    private void OnPropertyChanged([CallerMemberName] string? propertyName = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
}
