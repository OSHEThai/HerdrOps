using HerdrOps.App.Agents;
using HerdrOps.App.Organization;
using HerdrOps.App.Overview;
using HerdrOps.App.StateIpc;
using HerdrOps.Contracts.StateIpc;

namespace HerdrOps.App.Live;

public enum LiveDashboardConnectionStatus
{
    Waiting,
    Connecting,
    Live,
    Reconnecting,
    Offline,
    Stopped,
    SyntheticPreview,
}

public sealed class LiveDashboardState : ObservableState
{
    private readonly List<OverviewActivity> _activities = [];
    private HerdrSessionStateContract _currentState = HerdrSessionStateContract.Empty;
    private LiveDashboardConnectionStatus _connectionStatus;
    private bool _isLive;
    private string _sourceLabel;
    private string _connectionLabel;
    private string _connectionBrushKey;
    private string _projectLabel;
    private string _statusSummary;
    private string _lastUpdateLabel;
    private string _latencyLabel;
    private string? _selectedTerminalId;
    private DateTimeOffset _lastSourceTimestamp;

    public LiveDashboardState()
        : this(syntheticPreview: false)
    {
    }

    private LiveDashboardState(bool syntheticPreview)
    {
        Overview = new LiveOverviewState();
        Organization = new LiveOrganizationState();
        AgentDetail = new LiveAgentDetailState();
        Organization.AgentSelectionRequested += (_, terminalId) => SelectAgent(terminalId);
        _connectionStatus = syntheticPreview
            ? LiveDashboardConnectionStatus.SyntheticPreview
            : LiveDashboardConnectionStatus.Waiting;
        _sourceLabel = syntheticPreview ? "SYNTHETIC SHELL PREVIEW" : "WAITING FOR CORE";
        _connectionLabel = syntheticPreview ? "Herdr not connected" : "Core not connected";
        _connectionBrushKey = OverviewBrushKeys.Offline;
        _projectLabel = syntheticPreview ? "Synthetic Preview" : "No active workspace";
        _statusSummary = syntheticPreview
            ? "UI preview ready"
            : "Waiting for the per-user Core state service";
        _lastUpdateLabel = "Last Core update: —";
        _latencyLabel = "— ms";
        RefreshViews();
        if (syntheticPreview)
        {
            AgentDetail.ApplySyntheticPreviewProfile();
        }
    }

    public static LiveDashboardState CreateSyntheticPreview() => new(syntheticPreview: true);

    public LiveOverviewState Overview { get; }

    public LiveOrganizationState Organization { get; }

    public LiveAgentDetailState AgentDetail { get; }

    public HerdrSessionStateContract CurrentState
    {
        get => _currentState;
        private set => Set(ref _currentState, value);
    }

    public LiveDashboardConnectionStatus ConnectionStatus
    {
        get => _connectionStatus;
        private set => Set(ref _connectionStatus, value);
    }

    public bool IsLive { get => _isLive; private set => Set(ref _isLive, value); }

    public string SourceLabel { get => _sourceLabel; private set => Set(ref _sourceLabel, value); }

    public string ConnectionLabel
    {
        get => _connectionLabel;
        private set => Set(ref _connectionLabel, value);
    }

    public string ConnectionBrushKey
    {
        get => _connectionBrushKey;
        private set => Set(ref _connectionBrushKey, value);
    }

    public string ProjectLabel { get => _projectLabel; private set => Set(ref _projectLabel, value); }

    public string StatusSummary
    {
        get => _statusSummary;
        private set => Set(ref _statusSummary, value);
    }

    public string LastUpdateLabel
    {
        get => _lastUpdateLabel;
        private set => Set(ref _lastUpdateLabel, value);
    }

    public string LatencyLabel { get => _latencyLabel; private set => Set(ref _latencyLabel, value); }

    public string? SelectedTerminalId
    {
        get => _selectedTerminalId;
        private set => Set(ref _selectedTerminalId, value);
    }

    public DateTimeOffset LastSourceTimestamp
    {
        get => _lastSourceTimestamp;
        private set => Set(ref _lastSourceTimestamp, value);
    }

    public void ApplyUpdate(HerdrOpsStateUpdate update, DateTimeOffset receivedUtc)
    {
        ArgumentNullException.ThrowIfNull(update);
        EnsureUtc(receivedUtc, nameof(receivedUtc));
        var normalized = HerdrSessionStateContractReducer.NormalizeAndValidate(update.CurrentState);
        CurrentState = normalized;
        ConnectionStatus = LiveDashboardConnectionStatus.Live;
        IsLive = true;
        SourceLabel = update.Kind == HerdrOpsStateUpdateKind.Snapshot
            ? "CORE SNAPSHOT"
            : "CORE DELTA";
        ConnectionLabel = normalized.LastIngestSequence == 0
            ? "Core connected · Herdr state unavailable"
            : "Core connected · Herdr runtime freshness unknown";
        ConnectionBrushKey = OverviewBrushKeys.Working;
        LastSourceTimestamp = update.Envelope.SentUtc;
        LastUpdateLabel = $"Core update {update.Envelope.SentUtc.ToLocalTime():HH:mm:ss} · sequence {normalized.LastIngestSequence}";
        var latency = receivedUtc - update.Envelope.SentUtc;
        LatencyLabel = latency < TimeSpan.Zero
            ? "clock mismatch"
            : $"{Math.Round(latency.TotalMilliseconds, MidpointRounding.AwayFromZero):0} ms";
        ProjectLabel = ResolveProjectLabel(normalized);
        StatusSummary = normalized.LastIngestSequence == 0
            ? "Core link is live; no admitted Herdr snapshot is available"
            : $"Latest accepted Herdr state via Core · epoch {normalized.ConnectionEpoch} · sequence {normalized.LastIngestSequence}";
        UpdateActivities(update);
        SelectedTerminalId = ResolveSelection(normalized, SelectedTerminalId);
        RefreshViews();
    }

    public void MarkConnecting(bool reconnecting)
    {
        ConnectionStatus = reconnecting
            ? LiveDashboardConnectionStatus.Reconnecting
            : LiveDashboardConnectionStatus.Connecting;
        IsLive = false;
        SourceLabel = CurrentState.LastIngestSequence > 0 ? "LAST KNOWN" : "WAITING FOR CORE";
        ConnectionLabel = reconnecting ? "Reconnecting to Core" : "Connecting to Core";
        ConnectionBrushKey = OverviewBrushKeys.Idle;
        StatusSummary = reconnecting
            ? "Core connection interrupted; displayed Herdr state is last-known"
            : "Connecting to the per-user Core state service";
        LatencyLabel = "— ms";
        RefreshViews();
    }

    public void MarkOffline(Exception exception, DateTimeOffset observedUtc)
    {
        ArgumentNullException.ThrowIfNull(exception);
        EnsureUtc(observedUtc, nameof(observedUtc));
        var wasOffline = ConnectionStatus == LiveDashboardConnectionStatus.Offline;
        ConnectionStatus = LiveDashboardConnectionStatus.Offline;
        IsLive = false;
        SourceLabel = CurrentState.LastIngestSequence > 0 ? "LAST KNOWN" : "NO CORE DATA";
        ConnectionLabel = $"Core offline · {exception.GetType().Name}";
        ConnectionBrushKey = OverviewBrushKeys.Offline;
        StatusSummary = "Core is offline; no last-known Agent status is treated as current";
        LatencyLabel = "— ms";
        if (!wasOffline)
        {
            AddActivity(new OverviewActivity(
                observedUtc.ToLocalTime().ToString("HH:mm", System.Globalization.CultureInfo.InvariantCulture),
                "!",
                "HerdrOps App",
                "Core state IPC disconnected; status changed to Offline",
                "IPC",
                OverviewBrushKeys.Offline));
        }

        RefreshViews();
    }

    public void MarkStopped(DateTimeOffset observedUtc)
    {
        EnsureUtc(observedUtc, nameof(observedUtc));
        ConnectionStatus = LiveDashboardConnectionStatus.Stopped;
        IsLive = false;
        SourceLabel = CurrentState.LastIngestSequence > 0 ? "LAST KNOWN" : "NO CORE DATA";
        ConnectionLabel = "Dashboard state client stopped";
        ConnectionBrushKey = OverviewBrushKeys.Offline;
        StatusSummary = "Dashboard closed its read-only Core subscription";
        LatencyLabel = "— ms";
        RefreshViews();
    }

    public void SelectAgent(string? terminalId)
    {
        var resolved = ResolveSelection(CurrentState, terminalId);
        SelectedTerminalId = resolved;
        Organization.SelectAgent(CurrentState, IsLive, resolved);
        AgentDetail.Update(CurrentState, IsLive, SourceLabel, ConnectionLabel, resolved);
    }

    private void RefreshViews()
    {
        Overview.Update(
            CurrentState,
            IsLive,
            SourceLabel,
            ConnectionLabel,
            LastSourceTimestamp,
            _activities.ToArray());
        Organization.Update(
            CurrentState,
            IsLive,
            SourceLabel,
            ConnectionLabel,
            SelectedTerminalId);
        AgentDetail.Update(
            CurrentState,
            IsLive,
            SourceLabel,
            ConnectionLabel,
            SelectedTerminalId);
    }

    private void UpdateActivities(HerdrOpsStateUpdate update)
    {
        var time = update.Envelope.SentUtc.ToLocalTime().ToString(
            "HH:mm",
            System.Globalization.CultureInfo.InvariantCulture);
        if (update.Kind == HerdrOpsStateUpdateKind.Snapshot)
        {
            AddActivity(new OverviewActivity(
                time,
                "SN",
                "HerdrOps Core",
                CurrentState.LastIngestSequence == 0
                    ? "Core snapshot contains no admitted Herdr state"
                    : $"Full state snapshot received for {CurrentState.Agents.Count} Agents",
                $"SEQ-{CurrentState.LastIngestSequence}",
                CurrentState.LastIngestSequence == 0
                    ? OverviewBrushKeys.Offline
                    : OverviewBrushKeys.Primary));
            return;
        }

        var changedAgents = update.Delta?.Delta.UpsertedAgents ?? [];
        if (changedAgents.Count == 0)
        {
            AddActivity(new OverviewActivity(
                time,
                "Δ",
                "HerdrOps Core",
                "State delta applied without Agent field changes",
                $"SEQ-{CurrentState.LastIngestSequence}",
                OverviewBrushKeys.Primary));
            return;
        }

        foreach (var agent in changedAgents.Take(6).Reverse())
        {
            AddActivity(new OverviewActivity(
                time,
                AgentStatusPresentation.Initials(agent),
                AgentStatusPresentation.DisplayName(agent),
                $"Herdr status: {agent.AgentStatus} · pane revision {agent.Revision}",
                agent.PaneId,
                AgentStatusPresentation.BrushKey(agent.AgentStatus)));
        }
    }

    private void AddActivity(OverviewActivity activity)
    {
        _activities.Insert(0, activity);
        if (_activities.Count > 6)
        {
            _activities.RemoveRange(6, _activities.Count - 6);
        }
    }

    private static string ResolveProjectLabel(HerdrSessionStateContract state)
    {
        var focused = state.FocusedWorkspaceId is null
            ? null
            : state.Workspaces.FirstOrDefault(item => item.WorkspaceId == state.FocusedWorkspaceId);
        var workspace = focused ?? state.Workspaces.FirstOrDefault();
        return workspace is null
            ? "No active workspace"
            : AgentStatusPresentation.FirstNonEmpty(workspace.Label, workspace.WorkspaceId);
    }

    private static string? ResolveSelection(
        HerdrSessionStateContract state,
        string? requestedTerminalId)
    {
        if (requestedTerminalId is not null &&
            state.Agents.Any(agent => agent.TerminalId == requestedTerminalId))
        {
            return requestedTerminalId;
        }

        var focused = state.FocusedPaneId is null
            ? null
            : state.Agents.FirstOrDefault(agent => agent.PaneId == state.FocusedPaneId);
        return focused?.TerminalId ?? state.Agents.FirstOrDefault()?.TerminalId;
    }

    private static void EnsureUtc(DateTimeOffset value, string name)
    {
        if (value.Offset != TimeSpan.Zero)
        {
            throw new ArgumentException("Dashboard state timestamps must be UTC.", name);
        }
    }
}
