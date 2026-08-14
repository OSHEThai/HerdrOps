using HerdrOps.Contracts;
using HerdrOps.App.Localization;

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

    public string SourceLabel => UiLanguageService.Shared["SyntheticData"];

    public string CompactSourceLabel => UiLanguageService.Shared["SyntheticCompact"];

    public string ConnectionLabel => UiLanguageService.Shared["HerdrNotConnected"];

    public string CompactConnectionLabel => UiLanguageService.Shared["SyntheticPreview"];

    public string ConnectionBrushKey => "HerdrOps.Brush.Status.Working";

    public string GalleryDescription => UiLanguageService.Shared["WidgetGalleryDescription"];

    public string DashboardPreviewLabel => UiLanguageService.Shared["WidgetDashboardPreview"];

    public string WindowTitleSuffix => UiLanguageService.Shared["WidgetWindowSuffix"];

    public string DetailsSourceLabel => UiLanguageService.Shared["WidgetDetailsSource"];

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

    public string LatencyLabel => UiLanguageService.Shared["SyntheticSnapshot"];

    public int UpdateSampleCount => 0;

    public double? LastUpdateLatencyMilliseconds => null;

    public double? P95UpdateLatencyMilliseconds => null;

    public IReadOnlyList<WidgetAgent> Agents { get; }

    public IReadOnlyList<WidgetNotice> Notices { get; }

    public IReadOnlyList<WidgetNotice> PriorityNotices => Notices.Take(2).ToArray();

    public WidgetAgent SelectedAgent => Agents[3];

    public IReadOnlyList<WidgetActivity> SelectedAgentActivity { get; }

    public static SyntheticWidgetState Create()
    {
        var text = UiLanguageService.Shared;
        return new(
            [
                new("pm", "PM", "Project Manager", text["WidgetAgentPmRole"], text["WidgetAssignedSystem"], text["WidgetActivityPlan"], "02:14", 95, text["StatusWorking"], "HerdrOps.Brush.Status.Working", "14:20"),
                new("ps", "PS", "PM Secretary", text["WidgetAgentSecretaryRole"], "Project Manager", text["WidgetActivityRegistry"], "00:38", 98, text["StatusReview"], "HerdrOps.Brush.Status.Review", "14:20"),
                new("bl", "BL", "Backend Leader", text["WidgetAgentLeaderRole"], "Project Manager", text["WidgetActivityWaiting"], "05:42", 72, text["StatusBlocked"], "HerdrOps.Brush.Status.Blocked", "14:20"),
                new("bw", "BW", "Backend Worker 01", text["WidgetAgentWorkerRole"], "Backend Leader", text["WidgetActivityEditing"], "01:27", 88, text["StatusWorking"], "HerdrOps.Brush.Status.Working", "14:20"),
                new("w2", "W2", "Backend Worker 02", text["WidgetAgentWorkerRole"], "Backend Leader", text["WidgetActivityTask"], "00:44", 100, text["StatusDone"], "HerdrOps.Brush.Status.Done", "14:20"),
                new("w3", "W3", "Backend Worker 03", text["WidgetAgentWorkerRole"], "Backend Leader", text["WidgetActivityReading"], "02:31", 80, text["StatusIdle"], "HerdrOps.Brush.Status.Idle", "14:20"),
                new("tw", "TW", "Test Worker", text["WidgetAgentWorkerRole"], "Test Leader", text["WidgetActivityTesting"], "03:16", 90, text["StatusWorking"], "HerdrOps.Brush.Status.Working", "14:20"),
                new("dw", "DW", "DevOps Worker", text["WidgetAgentWorkerRole"], "DevOps Leader", text["WidgetActivityDeploy"], "01:02", 85, text["StatusWorking"], "HerdrOps.Brush.Status.Working", "14:20"),
            ],
            [
                new("Backend Leader", text["WidgetNoticeCommand"], "14:32", "\uE7BA", "HerdrOps.Brush.Status.Blocked", text["StatusBlocked"]),
                new("Worker 02", text["WidgetNoticeDone"], "14:30", "\uE73E", "HerdrOps.Brush.Status.Done", text["StatusDone"]),
                new("PM Secretary", text["WidgetNoticeUpdated"], "14:30", "\uE946", "HerdrOps.Brush.Status.Review", text["StatusReview"]),
                new("Project Manager", text["WidgetNoticeApproved"], "14:28", "\uE73E", "HerdrOps.Brush.Status.Done", text["StatusDone"]),
            ],
            [
                new("14:20", text["WidgetFactReceived"]),
                new("14:21", text["WidgetFactOpened"]),
                new("14:22", text["WidgetFactEdited"]),
                new("14:25", text["WidgetFactSaved"]),
            ]);
    }
}
