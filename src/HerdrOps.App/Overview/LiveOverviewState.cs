using HerdrOps.App.Live;
using HerdrOps.App.Localization;
using HerdrOps.Contracts.StateIpc;

namespace HerdrOps.App.Overview;

public sealed class LiveOverviewState : ObservableState
{
    private string _sourceLabel = "WAITING FOR CORE";
    private string _connectionLabel = "Core not connected";
    private DateTimeOffset _snapshotTimestamp;
    private IReadOnlyList<OverviewSummaryCard> _summaryCards = [];
    private IReadOnlyList<OverviewActivity> _recentActivities = [];
    private IReadOnlyList<OverviewScorePoint> _scoreTrend = [];
    private IReadOnlyList<OverviewWorkstream> _workstreams = [];
    private IReadOnlyList<OverviewTopAgent> _topAgents = [];
    private IReadOnlyList<OverviewAlert> _alerts = [];
    private string _activitySourceLabel = "NO CORE DATA";
    private string _activityFooterLabel = "0 Core state events";
    private string _workDistributionTotal = "0";
    private string _scoreTrendStatus = "Unknown — no evaluation data from Herdr";
    private string _topAgentsSourceLabel = "STATUS ONLY";
    private string _agentListTitle = UiLanguageService.Shared["OverviewAgentStatus"];
    private string _alertsCountLabel = "0 state signals";

    public string SourceLabel { get => _sourceLabel; private set => Set(ref _sourceLabel, value); }

    public string ConnectionLabel { get => _connectionLabel; private set => Set(ref _connectionLabel, value); }

    public DateTimeOffset SnapshotTimestamp
    {
        get => _snapshotTimestamp;
        private set => Set(ref _snapshotTimestamp, value);
    }

    public IReadOnlyList<OverviewSummaryCard> SummaryCards
    {
        get => _summaryCards;
        private set => Set(ref _summaryCards, value);
    }

    public IReadOnlyList<OverviewActivity> RecentActivities
    {
        get => _recentActivities;
        private set => Set(ref _recentActivities, value);
    }

    public IReadOnlyList<OverviewScorePoint> ScoreTrend
    {
        get => _scoreTrend;
        private set => Set(ref _scoreTrend, value);
    }

    public IReadOnlyList<OverviewWorkstream> Workstreams
    {
        get => _workstreams;
        private set => Set(ref _workstreams, value);
    }

    public IReadOnlyList<OverviewTopAgent> TopAgents
    {
        get => _topAgents;
        private set => Set(ref _topAgents, value);
    }

    public IReadOnlyList<OverviewAlert> Alerts
    {
        get => _alerts;
        private set => Set(ref _alerts, value);
    }

    public string ActivitySourceLabel
    {
        get => _activitySourceLabel;
        private set => Set(ref _activitySourceLabel, value);
    }

    public string ActivityFooterLabel
    {
        get => _activityFooterLabel;
        private set => Set(ref _activityFooterLabel, value);
    }

    public string WorkDistributionTotal
    {
        get => _workDistributionTotal;
        private set => Set(ref _workDistributionTotal, value);
    }

    public string ScoreTrendStatus
    {
        get => _scoreTrendStatus;
        private set => Set(ref _scoreTrendStatus, value);
    }

    public string TopAgentsSourceLabel
    {
        get => _topAgentsSourceLabel;
        private set => Set(ref _topAgentsSourceLabel, value);
    }

    public string AgentListTitle
    {
        get => _agentListTitle;
        private set => Set(ref _agentListTitle, value);
    }

    public string AlertsCountLabel
    {
        get => _alertsCountLabel;
        private set => Set(ref _alertsCountLabel, value);
    }

    internal void Update(
        HerdrSessionStateContract state,
        bool isLive,
        string sourceLabel,
        string connectionLabel,
        DateTimeOffset sourceTimestamp,
        IReadOnlyList<OverviewActivity> activities)
    {
        ArgumentNullException.ThrowIfNull(state);
        SourceLabel = sourceLabel;
        ConnectionLabel = connectionLabel;
        SnapshotTimestamp = sourceTimestamp;
        RecentActivities = activities;
        ActivitySourceLabel = isLive ? "CORE STATE" : "LAST KNOWN";
        ActivityFooterLabel = $"{activities.Count} Core state events";
        SummaryCards = CreateSummaryCards(state, isLive);
        ScoreTrend = [];
        ScoreTrendStatus = "Unknown — Herdr protocol 19 does not supply evaluation scores";
        Workstreams = CreateWorkspaceDistribution(state);
        WorkDistributionTotal = state.Agents.Count.ToString(System.Globalization.CultureInfo.InvariantCulture);
        TopAgents = CreateAgentRows(state, isLive);
        TopAgentsSourceLabel = "STATUS · NO SCORE";
        AgentListTitle = UiLanguageService.Shared["OverviewAgentStatus"];
        Alerts = CreateAlerts(state, isLive, sourceTimestamp);
        AlertsCountLabel = $"{Alerts.Count} state signals";
    }

    private static IReadOnlyList<OverviewSummaryCard> CreateSummaryCards(
        HerdrSessionStateContract state,
        bool isLive)
    {
        var text = UiLanguageService.Shared;
        var total = state.Agents.Count;
        var unknown = Count(state, "Unknown");
        return
        [
            new(
                "total-agents",
                text["OverviewTotalAgents"],
                total.ToString(System.Globalization.CultureInfo.InvariantCulture),
                isLive ? $"Observed {total}   Unknown {unknown}" : $"Last known {total}",
                isLive ? $"Latest accepted · Core sequence {state.LastIngestSequence}" : "Offline — values are not current",
                "\uE716",
                OverviewBrushKeys.Primary,
                [],
                false,
                0),
            CreateStatusCard(state, isLive, "working", text["OverviewWorking"], "Working", "\uE9D9", OverviewBrushKeys.Working),
            CreateStatusCard(state, isLive, "blocked", text["OverviewBlocked"], "Blocked", "\uEA39", OverviewBrushKeys.Blocked),
            CreateStatusCard(state, isLive, "done", text["OverviewDone"], "Done", "\uE73E", OverviewBrushKeys.Done),
            new(
                "daily-score",
                text["OverviewDailyScore"],
                "—",
                "/100",
                "Unknown — not supplied by Herdr",
                "\uE9D2",
                OverviewBrushKeys.Primary,
                [],
                true,
                0),
        ];
    }

    private static OverviewSummaryCard CreateStatusCard(
        HerdrSessionStateContract state,
        bool isLive,
        string id,
        string title,
        string status,
        string glyph,
        string brushKey)
    {
        var count = Count(state, status);
        var percentage = state.Agents.Count == 0
            ? 0
            : (int)Math.Round(100d * count / state.Agents.Count, MidpointRounding.AwayFromZero);
        return new OverviewSummaryCard(
            id,
            title,
            isLive ? count.ToString(System.Globalization.CultureInfo.InvariantCulture) : "—",
            isLive ? $"{percentage}%" : "Offline",
            isLive ? "Latest accepted Herdr state" : $"Last known count {count}",
            glyph,
            isLive ? brushKey : OverviewBrushKeys.Offline,
            [],
            false,
            0);
    }

    private static IReadOnlyList<OverviewWorkstream> CreateWorkspaceDistribution(
        HerdrSessionStateContract state)
    {
        if (state.Agents.Count == 0)
        {
            return [];
        }

        var workspaceLabels = state.Workspaces.ToDictionary(
            workspace => workspace.WorkspaceId,
            workspace => string.IsNullOrWhiteSpace(workspace.Label)
                ? workspace.WorkspaceId
                : workspace.Label,
            StringComparer.Ordinal);
        var groups = state.Agents
            .GroupBy(agent => agent.WorkspaceId, StringComparer.Ordinal)
            .Select(group => new
            {
                Id = group.Key,
                Count = group.Count(),
            })
            .OrderByDescending(group => group.Count)
            .ThenBy(group => group.Id, StringComparer.Ordinal)
            .ToArray();
        var palette = new[]
        {
            OverviewBrushKeys.Primary,
            OverviewBrushKeys.Review,
            OverviewBrushKeys.Working,
            OverviewBrushKeys.Idle,
            OverviewBrushKeys.Blocked,
        };
        var result = new List<OverviewWorkstream>();
        foreach (var group in groups.Take(5).Select((value, index) => (value, index)))
        {
            result.Add(new OverviewWorkstream(
                workspaceLabels.GetValueOrDefault(group.value.Id, group.value.Id),
                group.value.Count,
                100d * group.value.Count / state.Agents.Count,
                palette[group.index % palette.Length]));
        }

        return result;
    }

    private static IReadOnlyList<OverviewTopAgent> CreateAgentRows(
        HerdrSessionStateContract state,
        bool isLive) =>
        state.Agents
            .OrderBy(agent => StatusOrder(agent.AgentStatus))
            .ThenBy(AgentStatusPresentation.DisplayName, StringComparer.OrdinalIgnoreCase)
            .Take(5)
            .Select((agent, index) => new OverviewTopAgent(
                index + 1,
                AgentStatusPresentation.Initials(agent),
                AgentStatusPresentation.DisplayName(agent),
                0,
                0,
                AgentStatusPresentation.BrushKey(
                    AgentStatusPresentation.EffectiveStatus(agent.AgentStatus, isLive)),
                HasScore: false,
                StatusLabel: AgentStatusPresentation.EffectiveStatus(agent.AgentStatus, isLive)))
            .ToArray();

    private static IReadOnlyList<OverviewAlert> CreateAlerts(
        HerdrSessionStateContract state,
        bool isLive,
        DateTimeOffset sourceTimestamp)
    {
        var time = sourceTimestamp == default
            ? "—"
            : sourceTimestamp.ToLocalTime().ToString("HH:mm", System.Globalization.CultureInfo.InvariantCulture);
        if (!isLive)
        {
            return
            [
                new(
                    "Core connection offline",
                    "Last-known Herdr values are not treated as current",
                    time,
                    AgentStatusPresentation.Offline,
                    OverviewBrushKeys.Offline),
            ];
        }

        if (state.LastIngestSequence == 0)
        {
            return
            [
                new(
                    "Herdr state unavailable",
                    "Core is connected but has no admitted Herdr snapshot",
                    time,
                    "Unknown",
                    OverviewBrushKeys.Offline),
            ];
        }

        return state.Agents
            .Where(agent => agent.AgentStatus is "Blocked" or "Unknown")
            .Take(3)
            .Select(agent => new OverviewAlert(
                AgentStatusPresentation.DisplayName(agent),
                agent.AgentStatus == "Blocked"
                    ? "Herdr reports this Agent as blocked"
                    : "Herdr supplied an unknown Agent status",
                time,
                agent.AgentStatus,
                AgentStatusPresentation.BrushKey(agent.AgentStatus)))
            .ToArray();
    }

    private static int Count(HerdrSessionStateContract state, string status) =>
        state.Agents.Count(agent => string.Equals(agent.AgentStatus, status, StringComparison.Ordinal));

    private static int StatusOrder(string status) => status switch
    {
        "Blocked" => 0,
        "Unknown" => 1,
        "Working" => 2,
        "Idle" => 3,
        "Done" => 4,
        _ => 5,
    };
}
