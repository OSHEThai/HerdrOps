using HerdrOps.Contracts;
using HerdrOps.App.Localization;

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
    public string ActivitySourceLabel => UiLanguageService.Shared["OverviewActivitySource"];

    public string ActivityFooterLabel => UiLanguageService.Shared.Format(
        "OverviewActivityFooterFormat",
        RecentActivities.Count);

    public string WorkDistributionTotal => Workstreams.Sum(workstream => workstream.Count)
        .ToString(System.Globalization.CultureInfo.InvariantCulture);

    public string ScoreTrendStatus => UiLanguageService.Shared["OverviewScoreFixture"];

    public string TopAgentsSourceLabel => UiLanguageService.Shared["OverviewTopAgentsSource"];

    public string AgentListTitle => UiLanguageService.Shared["OverviewTopAgents"];

    public string AlertsCountLabel => UiLanguageService.Shared.Format("OverviewItemsFormat", Alerts.Count);

    public static SyntheticOverviewState Create()
    {
        var text = UiLanguageService.Shared;
        return new SyntheticOverviewState(
            EvidenceClass.Synthetic,
            text["SyntheticData"],
            text["HerdrNotConnected"],
            new DateTimeOffset(2026, 8, 14, 14, 32, 0, TimeSpan.FromHours(7)),
            CreateSummaryCards(text),
            CreateActivities(text),
            CreateScoreTrend(text.CurrentLanguage),
            CreateWorkstreams(text.CurrentLanguage),
            CreateTopAgents(),
            CreateAlerts(text));
    }

    private static IReadOnlyList<OverviewSummaryCard> CreateSummaryCards(UiLanguageService text) =>
    [
        new(
            "total-agents",
            text["OverviewTotalAgents"],
            "12",
            text["OverviewOnlineOffline"],
            text["SyntheticRoster"],
            "\uE716",
            OverviewBrushKeys.Primary,
            [4, 5, 5, 7, 6, 8, 7],
            false,
            0),
        new(
            "working",
            text["OverviewWorking"],
            "7",
            "58%",
            text["OverviewFromBaseline"],
            "\uE9D9",
            OverviewBrushKeys.Working,
            [3, 4, 6, 5, 7, 9, 7],
            false,
            0),
        new(
            "blocked",
            text["OverviewBlocked"],
            "2",
            "17%",
            text["OverviewNoChange"],
            "\uEA39",
            OverviewBrushKeys.Blocked,
            [1, 1, 2, 1, 2, 2, 2],
            false,
            0),
        new(
            "done",
            text["OverviewDone"],
            "3",
            "25%",
            text["OverviewTodayDelta"],
            "\uE73E",
            OverviewBrushKeys.Done,
            [0, 1, 1, 2, 1, 2, 3],
            false,
            0),
        new(
            "daily-score",
            text["OverviewDailyScore"],
            "86",
            "/100",
            text["OverviewYesterdayDelta"],
            "\uE9D2",
            OverviewBrushKeys.Working,
            [],
            true,
            86),
    ];

    private static IReadOnlyList<OverviewActivity> CreateActivities(UiLanguageService text) =>
    [
        new("14:32", "PM", "Project Manager", text["OverviewActivityPmAssign"], "TASK-118", OverviewBrushKeys.Review),
        new("14:31", "BL", "Backend Leader", text["OverviewActivityLeaderAssign"], "TASK-115", OverviewBrushKeys.Working),
        new("14:30", "BW", "Backend Worker 01", text["OverviewActivityWorkerStart"], "TASK-115", OverviewBrushKeys.Primary),
        new("14:29", "PS", "PM Secretary", text["OverviewActivitySecretaryUpdate"], "PROJECT", OverviewBrushKeys.Review),
        new("14:28", "PM", "Project Manager", text["OverviewActivityPmTest"], "TASK-120", OverviewBrushKeys.Review),
        new("14:27", "TW", "Test Worker", text["OverviewActivityUpload"], "FILE", OverviewBrushKeys.Working),
    ];

    private static IReadOnlyList<OverviewScorePoint> CreateScoreTrend(UiLanguage language) =>
        language == UiLanguage.Thai
            ?
            [
                new("7 พ.ค.", 62),
                new("8 พ.ค.", 72),
                new("9 พ.ค.", 65),
                new("10 พ.ค.", 78),
                new("11 พ.ค.", 71),
                new("12 พ.ค.", 81),
                new("13 พ.ค.", 86),
            ]
            :
            [
                new("May 7", 62),
                new("May 8", 72),
                new("May 9", 65),
                new("May 10", 78),
                new("May 11", 71),
                new("May 12", 81),
                new("May 13", 86),
            ];

    private static IReadOnlyList<OverviewWorkstream> CreateWorkstreams(UiLanguage language) =>
        language == UiLanguage.Thai
            ?
            [
                new("ส่วนหลัง", 5, 42, OverviewBrushKeys.Primary),
                new("ส่วนหน้า", 3, 25, OverviewBrushKeys.Review),
                new("ทดสอบ", 2, 15, OverviewBrushKeys.Working),
                new("ส่งมอบระบบ", 1, 10, OverviewBrushKeys.Idle),
                new("ความปลอดภัย", 1, 8, OverviewBrushKeys.Blocked),
            ]
            :
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

    private static IReadOnlyList<OverviewAlert> CreateAlerts(UiLanguageService text) =>
    [
        new(text["OverviewAlertUploadTitle"], text["OverviewAlertUploadText"], "14:31", text["StatusBlocked"], OverviewBrushKeys.Blocked),
        new(text["OverviewAlertScopeTitle"], text["OverviewAlertScopeText"], "14:29", text["StateSuspected"], OverviewBrushKeys.Idle),
        new(text["OverviewAlertSecretaryTitle"], text["OverviewAlertSecretaryText"], "14:28", text["StatePending"], OverviewBrushKeys.Idle),
    ];
}

public sealed record OverviewSummaryCard(
    string Id,
    string Title,
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
    string AccentBrushKey)
{
    public string DeltaLabel => Delta switch
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
}
