using HerdrOps.App.Live;
using HerdrOps.App.Localization;
using HerdrOps.App.Overview;
using HerdrOps.Contracts;
using HerdrOps.Contracts.StateIpc;
using HerdrOps.Domain.Activity;
using HerdrOps.Domain.Notifications;

namespace HerdrOps.App.Widgets;

public sealed class LiveWidgetState : ObservableState, IInteractiveWidgetState
{
    private const int MaximumVisibleNotices = 4;
    private readonly WidgetUpdateTelemetry _telemetry;
    private readonly NotificationCenter _notificationCenter;
    private HerdrSessionStateContract _lastState = HerdrSessionStateContract.Empty;
    private bool _lastIsCoreConnected;
    private bool _lastIsLive;
    private DateTimeOffset _lastNoticeSnapshotAt;
    private bool _isLive;
    private string _sourceLabel = UiLanguageService.Shared["CoreWaitingSource"];
    private string _compactSourceLabel = UiLanguageService.Shared["OffCompact"];
    private string _connectionLabel = UiLanguageService.Shared["CoreNotConnected"];
    private string _compactConnectionLabel = UiLanguageService.Shared["LiveWidgetWaitingCore"];
    private string _connectionBrushKey = OverviewBrushKeys.Offline;
    private string _galleryDescription = UiLanguageService.Shared["LiveWidgetGalleryOffline"];
    private DateTimeOffset _snapshotAt;
    private long _sequence;
    private long _lastMeasuredSequence;
    private int _totalAgents;
    private int _workingCount;
    private int _blockedCount;
    private int _doneCount;
    private string _workingCountLabel = "—";
    private string _blockedCountLabel = "—";
    private string _doneCountLabel = "—";
    private string _latencyLabel = UiLanguageService.Shared["LiveWidgetLatencyEmpty"];
    private int _updateSampleCount;
    private double? _lastUpdateLatencyMilliseconds;
    private double? _p95UpdateLatencyMilliseconds;
    private IReadOnlyList<WidgetAgent> _agents = [];
    private IReadOnlyList<WidgetNotice> _notices = [];
    private IReadOnlyList<WidgetNotice> _priorityNotices = [];
    private WidgetAgent _selectedAgent = EmptyAgent();
    private IReadOnlyList<WidgetActivity> _selectedAgentActivity = [];

    public LiveWidgetState(
        WidgetUpdateTelemetry? telemetry = null,
        NotificationCenter? notificationCenter = null)
    {
        _telemetry = telemetry ?? new WidgetUpdateTelemetry();
        _notificationCenter = notificationCenter ?? new NotificationCenter();
    }

    public EvidenceClass EvidenceClass => EvidenceClass.Contract;

    public bool IsLive { get => _isLive; private set => Set(ref _isLive, value); }

    public string SourceLabel { get => _sourceLabel; private set => Set(ref _sourceLabel, value); }

    public string CompactSourceLabel
    {
        get => _compactSourceLabel;
        private set => Set(ref _compactSourceLabel, value);
    }

    public string ConnectionLabel
    {
        get => _connectionLabel;
        private set => Set(ref _connectionLabel, value);
    }

    public string CompactConnectionLabel
    {
        get => _compactConnectionLabel;
        private set => Set(ref _compactConnectionLabel, value);
    }

    public string ConnectionBrushKey
    {
        get => _connectionBrushKey;
        private set => Set(ref _connectionBrushKey, value);
    }

    public string GalleryDescription
    {
        get => _galleryDescription;
        private set => Set(ref _galleryDescription, value);
    }

    public string DashboardPreviewLabel => UiLanguageService.Shared["LiveWidgetDashboardPreview"];

    public string WindowTitleSuffix => UiLanguageService.Shared["LiveWidgetWindowSuffix"];

    public string DetailsSourceLabel => UiLanguageService.Shared["LiveWidgetDetailsSource"];

    public DateTimeOffset SnapshotAt
    {
        get => _snapshotAt;
        private set => Set(ref _snapshotAt, value);
    }

    public long Sequence { get => _sequence; private set => Set(ref _sequence, value); }

    public int TotalAgents { get => _totalAgents; private set => Set(ref _totalAgents, value); }

    public int WorkingCount { get => _workingCount; private set => Set(ref _workingCount, value); }

    public int BlockedCount { get => _blockedCount; private set => Set(ref _blockedCount, value); }

    public int DoneCount { get => _doneCount; private set => Set(ref _doneCount, value); }

    public string WorkingCountLabel
    {
        get => _workingCountLabel;
        private set => Set(ref _workingCountLabel, value);
    }

    public string BlockedCountLabel
    {
        get => _blockedCountLabel;
        private set => Set(ref _blockedCountLabel, value);
    }

    public string DoneCountLabel
    {
        get => _doneCountLabel;
        private set => Set(ref _doneCountLabel, value);
    }

    public string DailyScoreLabel => UiLanguageService.Shared["ValueUnknown"];

    public string PositiveDeltaLabel => "—";

    public string NegativeDeltaLabel => "—";

    public string LatencyLabel { get => _latencyLabel; private set => Set(ref _latencyLabel, value); }

    public int UpdateSampleCount
    {
        get => _updateSampleCount;
        private set => Set(ref _updateSampleCount, value);
    }

    public double? LastUpdateLatencyMilliseconds
    {
        get => _lastUpdateLatencyMilliseconds;
        private set => Set(ref _lastUpdateLatencyMilliseconds, value);
    }

    public double? P95UpdateLatencyMilliseconds
    {
        get => _p95UpdateLatencyMilliseconds;
        private set => Set(ref _p95UpdateLatencyMilliseconds, value);
    }

    public IReadOnlyList<WidgetAgent> Agents
    {
        get => _agents;
        private set => Set(ref _agents, value);
    }

    public IReadOnlyList<WidgetNotice> Notices
    {
        get => _notices;
        private set => Set(ref _notices, value);
    }

    public IReadOnlyList<WidgetNotice> PriorityNotices
    {
        get => _priorityNotices;
        private set => Set(ref _priorityNotices, value);
    }

    public WidgetAgent SelectedAgent
    {
        get => _selectedAgent;
        private set => Set(ref _selectedAgent, value);
    }

    public IReadOnlyList<WidgetActivity> SelectedAgentActivity
    {
        get => _selectedAgentActivity;
        private set => Set(ref _selectedAgentActivity, value);
    }

    public NotificationCenterSnapshot NotificationSnapshot => _notificationCenter.Snapshot();

    internal void Update(
        HerdrSessionStateContract state,
        bool isCoreConnected,
        bool isLive,
        string connectionLabel,
        DateTimeOffset snapshotAt,
        string? selectedTerminalId,
        TimeSpan? updateLatency,
        bool recordLatency)
    {
        ArgumentNullException.ThrowIfNull(state);
        _lastState = state;
        _lastIsCoreConnected = isCoreConnected;
        _lastIsLive = isLive;
        _lastNoticeSnapshotAt = snapshotAt;
        var text = UiLanguageService.Shared;
        var hasAdmittedState = isCoreConnected && isLive && state.LastIngestSequence > 0;
        IsLive = isLive;
        SourceLabel = isCoreConnected
            ? hasAdmittedState
                ? text["CoreStateSource"]
                : state.LastIngestSequence > 0
                    ? text["LastKnownSource"]
                    : text["NoHerdrStateSource"]
            : state.LastIngestSequence > 0
                ? text["LastKnownSource"]
                : text["NoCoreDataSource"];
        CompactSourceLabel = isCoreConnected
            ? hasAdmittedState
                ? text["CoreCompact"]
                : state.LastIngestSequence > 0
                    ? text["LastCompact"]
                    : text["EmptyCompact"]
            : state.LastIngestSequence > 0
                ? text["LastCompact"]
                : text["OffCompact"];
        ConnectionLabel = connectionLabel;
        CompactConnectionLabel = isCoreConnected
            ? isLive
                ? text["CoreConnected"]
                : state.LastIngestSequence > 0
                    ? text["LiveWidgetHerdrInterruptedLastKnown"]
                    : text["LiveWidgetWaitingHerdr"]
            : state.LastIngestSequence > 0
                ? text["LiveWidgetCoreOfflineLastKnown"]
                : text["LiveWidgetWaitingCore"];
        ConnectionBrushKey = isLive
            ? OverviewBrushKeys.Working
            : isCoreConnected
                ? OverviewBrushKeys.Idle
                : OverviewBrushKeys.Offline;
        GalleryDescription = hasAdmittedState
            ? text["LiveWidgetGalleryLive"]
            : isCoreConnected
                ? state.LastIngestSequence > 0
                    ? text["LiveWidgetGalleryHerdrInterrupted"]
                    : text["LiveWidgetGalleryEmpty"]
                : text["LiveWidgetGalleryOffline"];
        SnapshotAt = snapshotAt;
        Sequence = state.LastIngestSequence;
        TotalAgents = state.Agents.Count;
        WorkingCount = Count(state, "Working");
        BlockedCount = Count(state, "Blocked");
        DoneCount = Count(state, "Done");
        WorkingCountLabel = hasAdmittedState
            ? WorkingCount.ToString(System.Globalization.CultureInfo.InvariantCulture)
            : "—";
        BlockedCountLabel = hasAdmittedState
            ? BlockedCount.ToString(System.Globalization.CultureInfo.InvariantCulture)
            : "—";
        DoneCountLabel = hasAdmittedState
            ? DoneCount.ToString(System.Globalization.CultureInfo.InvariantCulture)
            : "—";
        Agents = CreateAgents(state, hasAdmittedState);
        RefreshNotices();
        SelectedAgent = ResolveSelectedAgent(Agents, selectedTerminalId);
        SelectedAgentActivity = CreateSelectedAgentFacts(state, SelectedAgent, snapshotAt);
        RecordLatency(state.LastIngestSequence, isLive, updateLatency, recordLatency);
        Raise(nameof(DashboardPreviewLabel));
        Raise(nameof(WindowTitleSuffix));
        Raise(nameof(DetailsSourceLabel));
        Raise(nameof(DailyScoreLabel));
    }

    public bool AcknowledgeNotificationGroup(string groupId, DateTimeOffset acknowledgedUtc)
    {
        var acknowledged = _notificationCenter.AcknowledgeGroup(groupId, acknowledgedUtc);
        if (acknowledged == 0)
        {
            return false;
        }

        RefreshNotices();
        return true;
    }

    public NotificationCenterDecision ApplyNotification(ActivityPipelineStep step)
    {
        var decision = _notificationCenter.Accept(step);
        if (decision.Disposition is
            NotificationCenterDisposition.Added or
            NotificationCenterDisposition.Grouped)
        {
            RefreshNotices();
        }

        return decision;
    }

    private void RefreshNotices()
    {
        var activityNotices = CreateNotificationNotices(
            _notificationCenter.Snapshot(),
            _lastState);
        var statusNotices = CreateNotices(
            _lastState,
            _lastIsCoreConnected,
            _lastIsLive,
            _lastNoticeSnapshotAt);
        Notices = activityNotices
            .Concat(statusNotices)
            .Take(MaximumVisibleNotices)
            .ToArray();
        PriorityNotices = Notices.Take(2).ToArray();
    }

    private void RecordLatency(
        long sequence,
        bool isLive,
        TimeSpan? updateLatency,
        bool recordLatency)
    {
        if (recordLatency &&
            isLive &&
            sequence > 0 &&
            sequence != _lastMeasuredSequence &&
            updateLatency is { } latency)
        {
            _telemetry.Record(latency);
            _lastMeasuredSequence = sequence;
        }

        var snapshot = _telemetry.Snapshot();
        UpdateSampleCount = snapshot.SampleCount;
        LastUpdateLatencyMilliseconds = snapshot.LastMilliseconds;
        P95UpdateLatencyMilliseconds = snapshot.P95Milliseconds;
        LatencyLabel = snapshot.P95Milliseconds is { } p95 && snapshot.LastMilliseconds is { } last
            ? UiLanguageService.Shared.Format("LiveWidgetLatencyFormat", last.ToString("0"), p95.ToString("0"))
            : UiLanguageService.Shared["LiveWidgetLatencyEmpty"];
    }

    private static IReadOnlyList<WidgetAgent> CreateAgents(
        HerdrSessionStateContract state,
        bool isLive) =>
        state.Agents
            .OrderBy(agent => StatusOrder(agent.AgentStatus))
            .ThenBy(AgentStatusPresentation.DisplayName, StringComparer.OrdinalIgnoreCase)
            .Select(agent =>
            {
                var text = UiLanguageService.Shared;
                var effectiveStatus = AgentStatusPresentation.EffectiveStatus(agent.AgentStatus, isLive);
                return new WidgetAgent(
                    agent.TerminalId,
                    AgentStatusPresentation.Initials(agent),
                    AgentStatusPresentation.DisplayName(agent),
                    AgentStatusPresentation.FirstNonEmpty(agent.Title, agent.DisplayAgent, agent.Agent),
                    text["ValueUnknown"],
                    isLive
                        ? text.Format(
                            "LiveWidgetObservedStatusFormat",
                            AgentStatusPresentation.DisplayStatus(agent.AgentStatus),
                            agent.PaneId)
                        : text.Format(
                            "LiveWidgetObservedStatusFormat",
                            AgentStatusPresentation.DisplayStatus(AgentStatusPresentation.Offline),
                            agent.PaneId),
                    text.Format("LiveWidgetSequenceFormat", agent.StateChangeSequence),
                    Score: null,
                    AgentStatusPresentation.DisplayStatus(effectiveStatus),
                    AgentStatusPresentation.BrushKey(effectiveStatus),
                    text["ValueUnknown"]);
            })
            .ToArray();

    private static IReadOnlyList<WidgetNotice> CreateNotices(
        HerdrSessionStateContract state,
        bool isCoreConnected,
        bool isLive,
        DateTimeOffset snapshotAt)
    {
        var text = UiLanguageService.Shared;
        var time = snapshotAt == default
            ? "—"
            : snapshotAt.ToLocalTime().ToString("HH:mm", System.Globalization.CultureInfo.InvariantCulture);
        var notices = new List<WidgetNotice>();
        if (!isCoreConnected)
        {
            notices.Add(new WidgetNotice(
                text["LiveWidgetCoreOfflineNotice"],
                text["LiveWidgetCoreOfflineNoticeDetail"],
                time,
                "\uE711",
                OverviewBrushKeys.Offline,
                text["StatusOffline"]));
            if (state.LastIngestSequence > 0)
            {
                return notices;
            }
        }

        if (isCoreConnected && !isLive)
        {
            notices.Add(new WidgetNotice(
                text["LiveWidgetHerdrInterruptedNotice"],
                state.LastIngestSequence > 0
                    ? text["LiveWidgetHerdrInterruptedNoticeDetail"]
                    : text["LiveWidgetWaitingHerdrNoticeDetail"],
                time,
                "\uE895",
                OverviewBrushKeys.Idle,
                state.LastIngestSequence > 0
                    ? text["StatusOffline"]
                    : text["StatusUnknown"]));
            return notices;
        }

        if (state.LastIngestSequence == 0)
        {
            notices.Add(new WidgetNotice(
                text["LiveWidgetHerdrUnavailableNotice"],
                text["LiveWidgetHerdrUnavailableNoticeDetail"],
                time,
                "\uE814",
                OverviewBrushKeys.Offline,
                text["StatusUnknown"]));
            return notices;
        }

        AddStatusNotice(notices, state, "Blocked", "\uEA39", OverviewBrushKeys.Blocked, time);
        AddStatusNotice(notices, state, "Done", "\uE73E", OverviewBrushKeys.Done, time);
        AddStatusNotice(notices, state, "Unknown", "\uE814", OverviewBrushKeys.Offline, time);
        return notices;
    }

    private static IReadOnlyList<WidgetNotice> CreateNotificationNotices(
        NotificationCenterSnapshot snapshot,
        HerdrSessionStateContract state)
    {
        var text = UiLanguageService.Shared;
        return snapshot.Groups
            .Select(group =>
            {
                var latest = group.LatestItem;
                var agent = latest.AgentTerminalId is null
                    ? null
                    : state.Agents.FirstOrDefault(candidate => string.Equals(
                        candidate.TerminalId,
                        latest.AgentTerminalId,
                        StringComparison.Ordinal));
                var agentName = agent is null
                    ? latest.AgentTerminalId ?? text["WidgetNotificationSystemActor"]
                    : AgentStatusPresentation.DisplayName(agent);
                var severityKey = group.HighestUrgency switch
                {
                    ActivityUrgency.Critical => "WidgetNotificationCritical",
                    ActivityUrgency.High => "WidgetNotificationHigh",
                    _ => "WidgetNotificationNormal",
                };
                var brushKey = group.HighestUrgency switch
                {
                    ActivityUrgency.Critical => OverviewBrushKeys.Blocked,
                    ActivityUrgency.High => OverviewBrushKeys.Idle,
                    _ => OverviewBrushKeys.Primary,
                };
                var glyph = group.HighestUrgency switch
                {
                    ActivityUrgency.Critical => "\uEA39",
                    ActivityUrgency.High => "\uE7BA",
                    _ => "\uE946",
                };
                var acknowledged = group.UnacknowledgedCount == 0;
                return new WidgetNotice(
                    agentName,
                    CreateNotificationDisplaySummary(latest.RedactedSummary),
                    latest.ObservedUtc.ToLocalTime().ToString(
                        "HH:mm",
                        System.Globalization.CultureInfo.InvariantCulture),
                    glyph,
                    brushKey,
                    text[severityKey],
                    group.GroupId,
                    group.EventCount,
                    group.UnacknowledgedCount,
                    acknowledged,
                    group.EventCount > 1
                        ? text.Format("WidgetNotificationGroupCountFormat", group.EventCount)
                        : string.Empty,
                    acknowledged
                        ? text["WidgetNotificationAcknowledged"]
                        : text.Format(
                            "WidgetNotificationUnacknowledgedFormat",
                            group.UnacknowledgedCount),
                    text.Format("WidgetOpenNotificationAutomationFormat", latest.SourceEventId),
                    text.Format("WidgetAcknowledgeNotificationAutomationFormat", agentName),
                    new WidgetNotificationRoute(
                        latest.SourceEventId,
                        latest.CorrelationId,
                        latest.NotificationId,
                        latest.AgentTerminalId,
                        latest.TaskId));
            })
            .ToArray();
    }

    private static string CreateNotificationDisplaySummary(string value)
    {
        const int maximumDisplayLength = 180;
        var singleLine = value
            .Replace('\r', ' ')
            .Replace('\n', ' ')
            .Replace('\t', ' ')
            .Trim();
        while (singleLine.Contains("  ", StringComparison.Ordinal))
        {
            singleLine = singleLine.Replace("  ", " ", StringComparison.Ordinal);
        }

        return singleLine.Length <= maximumDisplayLength
            ? singleLine
            : $"{singleLine[..(maximumDisplayLength - 1)]}…";
    }

    private static void AddStatusNotice(
        ICollection<WidgetNotice> notices,
        HerdrSessionStateContract state,
        string status,
        string glyph,
        string brushKey,
        string time)
    {
        var matching = state.Agents.Where(agent => agent.AgentStatus == status).ToArray();
        if (matching.Length == 0)
        {
            return;
        }

        notices.Add(new WidgetNotice(
            UiLanguageService.Shared.Format(
                "LiveWidgetStatusNoticeFormat",
                matching.Length,
                AgentStatusPresentation.DisplayStatus(status)),
            string.Join(", ", matching.Take(2).Select(AgentStatusPresentation.DisplayName)),
            time,
            glyph,
            brushKey,
            AgentStatusPresentation.DisplayStatus(status)));
    }

    private static WidgetAgent ResolveSelectedAgent(
        IReadOnlyList<WidgetAgent> agents,
        string? terminalId) =>
        terminalId is null
            ? agents.FirstOrDefault() ?? EmptyAgent()
            : agents.FirstOrDefault(agent => agent.TerminalId == terminalId) ??
              agents.FirstOrDefault() ??
              EmptyAgent();

    private static IReadOnlyList<WidgetActivity> CreateSelectedAgentFacts(
        HerdrSessionStateContract state,
        WidgetAgent selectedAgent,
        DateTimeOffset snapshotAt)
    {
        if (selectedAgent.TerminalId.Length == 0)
        {
            return [];
        }

        var time = snapshotAt == default
            ? "—"
            : snapshotAt.ToLocalTime().ToString("HH:mm", System.Globalization.CultureInfo.InvariantCulture);
        return
        [
            new WidgetActivity(
                time,
                UiLanguageService.Shared.Format(
                    "LiveWidgetAcceptedSequenceFormat",
                    state.LastIngestSequence)),
            new WidgetActivity("—", selectedAgent.Activity),
            new WidgetActivity("—", UiLanguageService.Shared["LiveWidgetUnknownHistory"]),
        ];
    }

    private static WidgetAgent EmptyAgent() => new(
        string.Empty,
        "?",
        UiLanguageService.Shared["NoAgentSelected"],
        UiLanguageService.Shared["ValueUnknown"],
        UiLanguageService.Shared["ValueUnknown"],
        UiLanguageService.Shared["LiveWidgetHerdrUnavailableNoticeDetail"],
        "—",
        Score: null,
        UiLanguageService.Shared["StatusUnknown"],
        OverviewBrushKeys.Offline,
        UiLanguageService.Shared["ValueUnknown"]);

    private static int Count(HerdrSessionStateContract state, string status) =>
        state.Agents.Count(agent => agent.AgentStatus == status);

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
