using HerdrOps.App.Live;
using HerdrOps.App.Localization;
using HerdrOps.App.Overview;
using HerdrOps.Contracts;
using HerdrOps.Contracts.StateIpc;

namespace HerdrOps.App.Widgets;

public sealed class LiveWidgetState : ObservableState, IWidgetState
{
    private readonly WidgetUpdateTelemetry _telemetry;
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

    public LiveWidgetState(WidgetUpdateTelemetry? telemetry = null)
    {
        _telemetry = telemetry ?? new WidgetUpdateTelemetry();
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

    internal void Update(
        HerdrSessionStateContract state,
        bool isLive,
        string connectionLabel,
        DateTimeOffset snapshotAt,
        string? selectedTerminalId,
        TimeSpan? transportLatency)
    {
        ArgumentNullException.ThrowIfNull(state);
        var text = UiLanguageService.Shared;
        var hasAdmittedState = isLive && state.LastIngestSequence > 0;
        IsLive = isLive;
        SourceLabel = isLive
            ? hasAdmittedState ? text["CoreStateSource"] : text["NoHerdrStateSource"]
            : state.LastIngestSequence > 0 ? text["LastKnownSource"] : text["NoCoreDataSource"];
        CompactSourceLabel = isLive
            ? hasAdmittedState ? text["CoreCompact"] : text["EmptyCompact"]
            : state.LastIngestSequence > 0 ? text["LastCompact"] : text["OffCompact"];
        ConnectionLabel = connectionLabel;
        CompactConnectionLabel = isLive
            ? text["CoreConnected"]
            : state.LastIngestSequence > 0
                ? text["LiveWidgetCoreOfflineLastKnown"]
                : text["LiveWidgetWaitingCore"];
        ConnectionBrushKey = isLive ? OverviewBrushKeys.Working : OverviewBrushKeys.Offline;
        GalleryDescription = hasAdmittedState
            ? text["LiveWidgetGalleryLive"]
            : isLive
                ? text["LiveWidgetGalleryEmpty"]
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
        Notices = CreateNotices(state, isLive, snapshotAt);
        PriorityNotices = Notices.Take(2).ToArray();
        SelectedAgent = ResolveSelectedAgent(Agents, selectedTerminalId);
        SelectedAgentActivity = CreateSelectedAgentFacts(state, SelectedAgent, snapshotAt);
        RecordLatency(state.LastIngestSequence, isLive, transportLatency);
        Raise(nameof(DashboardPreviewLabel));
        Raise(nameof(WindowTitleSuffix));
        Raise(nameof(DetailsSourceLabel));
        Raise(nameof(DailyScoreLabel));
    }

    private void RecordLatency(long sequence, bool isLive, TimeSpan? transportLatency)
    {
        if (isLive &&
            sequence > 0 &&
            sequence != _lastMeasuredSequence &&
            transportLatency is { } latency)
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
        bool isLive,
        DateTimeOffset snapshotAt)
    {
        var text = UiLanguageService.Shared;
        var time = snapshotAt == default
            ? "—"
            : snapshotAt.ToLocalTime().ToString("HH:mm", System.Globalization.CultureInfo.InvariantCulture);
        var notices = new List<WidgetNotice>();
        if (!isLive)
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
