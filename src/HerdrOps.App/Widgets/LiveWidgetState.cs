using HerdrOps.App.Live;
using HerdrOps.App.Overview;
using HerdrOps.Contracts;
using HerdrOps.Contracts.StateIpc;

namespace HerdrOps.App.Widgets;

public sealed class LiveWidgetState : ObservableState, IWidgetState
{
    private readonly WidgetUpdateTelemetry _telemetry;
    private bool _isLive;
    private string _sourceLabel = "WAITING FOR CORE";
    private string _compactSourceLabel = "WAIT";
    private string _connectionLabel = "Core not connected";
    private string _compactConnectionLabel = "Waiting for Core";
    private string _connectionBrushKey = OverviewBrushKeys.Offline;
    private string _galleryDescription = "รอข้อมูลจาก Core · ยังไม่อ้างสถานะ Herdr runtime";
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
    private string _latencyLabel = "Latency: —";
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

    public string DashboardPreviewLabel => "DASHBOARD UI PREVIEW";

    public string WindowTitleSuffix => "Core State";

    public string DetailsSourceLabel => "Latest accepted Core state · unsupported fields remain Unknown";

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

    public string DailyScoreLabel => "Unknown";

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
        var hasAdmittedState = isLive && state.LastIngestSequence > 0;
        IsLive = isLive;
        SourceLabel = isLive
            ? hasAdmittedState ? "CORE STATE" : "NO HERDR STATE"
            : state.LastIngestSequence > 0 ? "LAST KNOWN" : "NO CORE DATA";
        CompactSourceLabel = isLive
            ? hasAdmittedState ? "CORE" : "EMPTY"
            : state.LastIngestSequence > 0 ? "LAST" : "OFF";
        ConnectionLabel = connectionLabel;
        CompactConnectionLabel = isLive
            ? "Core connected"
            : state.LastIngestSequence > 0
                ? "Core offline · last known"
                : "Waiting for Core";
        ConnectionBrushKey = isLive ? OverviewBrushKeys.Working : OverviewBrushKeys.Offline;
        GalleryDescription = hasAdmittedState
            ? "สถานะล่าสุดจาก Core ชุดเดียวกับ Dashboard · Herdr runtime freshness ยังไม่ทราบ"
            : isLive
                ? "Core เชื่อมต่อแล้ว · ยังไม่มี Herdr snapshot ที่รับรอง"
            : "Core offline · แสดง identity ล่าสุดเพื่อการวินิจฉัยเท่านั้น";
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
            ? $"Last {last:0} ms · p95 {p95:0} ms"
            : "Latency: —";
    }

    private static IReadOnlyList<WidgetAgent> CreateAgents(
        HerdrSessionStateContract state,
        bool isLive) =>
        state.Agents
            .OrderBy(agent => StatusOrder(agent.AgentStatus))
            .ThenBy(AgentStatusPresentation.DisplayName, StringComparer.OrdinalIgnoreCase)
            .Select(agent =>
            {
                var effectiveStatus = AgentStatusPresentation.EffectiveStatus(agent.AgentStatus, isLive);
                return new WidgetAgent(
                    agent.TerminalId,
                    AgentStatusPresentation.Initials(agent),
                    AgentStatusPresentation.DisplayName(agent),
                    AgentStatusPresentation.FirstNonEmpty(agent.Title, agent.DisplayAgent, agent.Agent),
                    "Unknown",
                    isLive
                        ? $"Observed {agent.AgentStatus} · pane {agent.PaneId}"
                        : $"Last known {agent.AgentStatus} · Core offline",
                    $"seq {agent.StateChangeSequence}",
                    Score: null,
                    effectiveStatus,
                    AgentStatusPresentation.BrushKey(effectiveStatus),
                    "Unknown");
            })
            .ToArray();

    private static IReadOnlyList<WidgetNotice> CreateNotices(
        HerdrSessionStateContract state,
        bool isLive,
        DateTimeOffset snapshotAt)
    {
        var time = snapshotAt == default
            ? "—"
            : snapshotAt.ToLocalTime().ToString("HH:mm", System.Globalization.CultureInfo.InvariantCulture);
        var notices = new List<WidgetNotice>();
        if (!isLive)
        {
            notices.Add(new WidgetNotice(
                "Core offline",
                "Agent status is last-known and not current",
                time,
                "\uE711",
                OverviewBrushKeys.Offline,
                "Offline"));
            if (state.LastIngestSequence > 0)
            {
                return notices;
            }
        }

        if (state.LastIngestSequence == 0)
        {
            notices.Add(new WidgetNotice(
                "Herdr state unavailable",
                "Core has no admitted Herdr snapshot",
                time,
                "\uE814",
                OverviewBrushKeys.Offline,
                "Unknown"));
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
            $"{matching.Length} {status} Agent{(matching.Length == 1 ? string.Empty : "s")}",
            string.Join(", ", matching.Take(2).Select(AgentStatusPresentation.DisplayName)),
            time,
            glyph,
            brushKey,
            status));
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
            new WidgetActivity(time, $"Latest accepted Core sequence {state.LastIngestSequence}"),
            new WidgetActivity("—", selectedAgent.Activity),
            new WidgetActivity("—", "Assignment, score, and activity history are Unknown"),
        ];
    }

    private static WidgetAgent EmptyAgent() => new(
        string.Empty,
        "?",
        "No Agent selected",
        "Unknown",
        "Unknown",
        "No admitted Agent state",
        "—",
        Score: null,
        "Unknown",
        OverviewBrushKeys.Offline,
        "Unknown");

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
