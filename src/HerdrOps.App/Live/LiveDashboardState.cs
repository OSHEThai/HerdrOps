using HerdrOps.App.Agents;
using HerdrOps.App.Localization;
using HerdrOps.App.Organization;
using HerdrOps.App.Overview;
using HerdrOps.App.StateIpc;
using HerdrOps.App.Widgets;
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
    private readonly List<LiveActivityRecord> _activities = [];
    private readonly bool _syntheticPreview;
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
    private TimeSpan? _lastTransportLatency;
    private HerdrOpsStateUpdateKind? _lastUpdateKind;
    private string? _lastOfflineExceptionType;
    private bool _clockMismatch;

    public LiveDashboardState()
        : this(syntheticPreview: false)
    {
    }

    private LiveDashboardState(bool syntheticPreview)
    {
        _syntheticPreview = syntheticPreview;
        var text = UiLanguageService.Shared;
        Overview = new LiveOverviewState();
        Organization = new LiveOrganizationState();
        AgentDetail = new LiveAgentDetailState();
        Widgets = new LiveWidgetState();
        Organization.AgentSelectionRequested += (_, terminalId) => SelectAgent(terminalId);
        _connectionStatus = syntheticPreview
            ? LiveDashboardConnectionStatus.SyntheticPreview
            : LiveDashboardConnectionStatus.Waiting;
        _sourceLabel = syntheticPreview ? text["SyntheticShellPreview"] : text["CoreWaitingSource"];
        _connectionLabel = syntheticPreview ? text["HerdrNotConnected"] : text["CoreNotConnected"];
        _connectionBrushKey = OverviewBrushKeys.Offline;
        _projectLabel = syntheticPreview ? text["SyntheticPreview"] : text["NoActiveWorkspace"];
        _statusSummary = syntheticPreview
            ? text["UiPreviewReady"]
            : text["WaitingForCore"];
        _lastUpdateLabel = text["LastCoreUpdateEmpty"];
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

    public LiveWidgetState Widgets { get; }

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

    public TimeSpan? LastTransportLatency
    {
        get => _lastTransportLatency;
        private set => Set(ref _lastTransportLatency, value);
    }

    public void ApplyUpdate(HerdrOpsStateUpdate update, DateTimeOffset receivedUtc)
    {
        ArgumentNullException.ThrowIfNull(update);
        EnsureUtc(receivedUtc, nameof(receivedUtc));
        var normalized = HerdrSessionStateContractReducer.NormalizeAndValidate(update.CurrentState);
        CurrentState = normalized;
        ConnectionStatus = LiveDashboardConnectionStatus.Live;
        IsLive = true;
        _lastUpdateKind = update.Kind;
        _lastOfflineExceptionType = null;
        LastSourceTimestamp = update.Envelope.SentUtc;
        var latency = receivedUtc - update.Envelope.SentUtc;
        _clockMismatch = latency < TimeSpan.Zero;
        LastTransportLatency = latency < TimeSpan.Zero ? null : latency;
        UpdateActivities(update);
        SelectedTerminalId = ResolveSelection(normalized, SelectedTerminalId);
        RefreshPresentation();
        RefreshViews();
    }

    public void MarkConnecting(bool reconnecting)
    {
        ConnectionStatus = reconnecting
            ? LiveDashboardConnectionStatus.Reconnecting
            : LiveDashboardConnectionStatus.Connecting;
        IsLive = false;
        _clockMismatch = false;
        RefreshPresentation();
        RefreshViews();
    }

    public void MarkOffline(Exception exception, DateTimeOffset observedUtc)
    {
        ArgumentNullException.ThrowIfNull(exception);
        EnsureUtc(observedUtc, nameof(observedUtc));
        var wasOffline = ConnectionStatus == LiveDashboardConnectionStatus.Offline;
        ConnectionStatus = LiveDashboardConnectionStatus.Offline;
        IsLive = false;
        _lastOfflineExceptionType = exception.GetType().Name;
        _clockMismatch = false;
        if (!wasOffline)
        {
            AddActivity(new LiveActivityRecord(
                observedUtc.ToLocalTime().ToString("HH:mm", System.Globalization.CultureInfo.InvariantCulture),
                "!",
                "HerdrOps App",
                "ActivityCoreDisconnected",
                [],
                "IPC",
                OverviewBrushKeys.Offline));
        }

        RefreshPresentation();
        RefreshViews();
    }

    public void MarkStopped(DateTimeOffset observedUtc)
    {
        EnsureUtc(observedUtc, nameof(observedUtc));
        ConnectionStatus = LiveDashboardConnectionStatus.Stopped;
        IsLive = false;
        _clockMismatch = false;
        RefreshPresentation();
        RefreshViews();
    }

    public void SelectAgent(string? terminalId)
    {
        var resolved = ResolveSelection(CurrentState, terminalId);
        SelectedTerminalId = resolved;
        Organization.SelectAgent(CurrentState, IsLive, resolved);
        AgentDetail.Update(CurrentState, IsLive, SourceLabel, ConnectionLabel, resolved);
        Widgets.Update(
            CurrentState,
            IsLive,
            ConnectionLabel,
            LastSourceTimestamp,
            resolved,
            LastTransportLatency);
    }

    public void RefreshLanguage()
    {
        RefreshPresentation();
        RefreshViews();
        if (_syntheticPreview)
        {
            AgentDetail.ApplySyntheticPreviewProfile();
        }
    }

    private void RefreshViews()
    {
        Overview.Update(
            CurrentState,
            IsLive,
            SourceLabel,
            ConnectionLabel,
            LastSourceTimestamp,
            _activities.Select(RenderActivity).ToArray());
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
        Widgets.Update(
            CurrentState,
            IsLive,
            ConnectionLabel,
            LastSourceTimestamp,
            SelectedTerminalId,
            LastTransportLatency);
    }

    private void UpdateActivities(HerdrOpsStateUpdate update)
    {
        var time = update.Envelope.SentUtc.ToLocalTime().ToString(
            "HH:mm",
            System.Globalization.CultureInfo.InvariantCulture);
        if (update.Kind == HerdrOpsStateUpdateKind.Snapshot)
        {
            AddActivity(new LiveActivityRecord(
                time,
                "SN",
                "HerdrOps Core",
                CurrentState.LastIngestSequence == 0
                    ? "ActivitySnapshotEmpty"
                    : "ActivitySnapshotAgentsFormat",
                CurrentState.LastIngestSequence == 0
                    ? []
                    : [CurrentState.Agents.Count],
                $"SEQ-{CurrentState.LastIngestSequence}",
                CurrentState.LastIngestSequence == 0
                    ? OverviewBrushKeys.Offline
                    : OverviewBrushKeys.Primary));
            return;
        }

        var changedAgents = update.Delta?.Delta.UpsertedAgents ?? [];
        if (changedAgents.Count == 0)
        {
            AddActivity(new LiveActivityRecord(
                time,
                "Δ",
                "HerdrOps Core",
                "ActivityDeltaNoAgentChanges",
                [],
                $"SEQ-{CurrentState.LastIngestSequence}",
                OverviewBrushKeys.Primary));
            return;
        }

        foreach (var agent in changedAgents.Take(6).Reverse())
        {
            AddActivity(new LiveActivityRecord(
                time,
                AgentStatusPresentation.Initials(agent),
                AgentStatusPresentation.DisplayName(agent),
                "ActivityAgentStatusFormat",
                [new LocalizedStatusArgument(agent.AgentStatus), agent.Revision],
                agent.PaneId,
                AgentStatusPresentation.BrushKey(agent.AgentStatus)));
        }
    }

    private void AddActivity(LiveActivityRecord activity)
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
            ? UiLanguageService.Shared["NoActiveWorkspace"]
            : AgentStatusPresentation.FirstNonEmpty(workspace.Label, workspace.WorkspaceId);
    }

    private void RefreshPresentation()
    {
        var text = UiLanguageService.Shared;
        ProjectLabel = _syntheticPreview
            ? text["SyntheticPreview"]
            : ResolveProjectLabel(CurrentState);
        LastUpdateLabel = LastSourceTimestamp == default
            ? text["LastCoreUpdateEmpty"]
            : text.Format(
                "CoreUpdateFormat",
                LastSourceTimestamp.ToLocalTime().ToString("HH:mm:ss", System.Globalization.CultureInfo.InvariantCulture),
                CurrentState.LastIngestSequence);

        switch (ConnectionStatus)
        {
            case LiveDashboardConnectionStatus.SyntheticPreview:
                SourceLabel = text["SyntheticShellPreview"];
                ConnectionLabel = text["HerdrNotConnected"];
                ConnectionBrushKey = OverviewBrushKeys.Offline;
                StatusSummary = text["UiPreviewReady"];
                LatencyLabel = "— ms";
                break;
            case LiveDashboardConnectionStatus.Live:
                SourceLabel = _lastUpdateKind == HerdrOpsStateUpdateKind.Delta
                    ? text["CoreDeltaSource"]
                    : text["CoreSnapshotSource"];
                ConnectionLabel = CurrentState.LastIngestSequence == 0
                    ? text["CoreConnectedNoSnapshot"]
                    : text["CoreConnectedFreshnessUnknown"];
                ConnectionBrushKey = OverviewBrushKeys.Working;
                StatusSummary = CurrentState.LastIngestSequence == 0
                    ? text["CoreLiveNoSnapshot"]
                    : text.Format(
                        "LatestAcceptedStateFormat",
                        CurrentState.ConnectionEpoch,
                        CurrentState.LastIngestSequence);
                LatencyLabel = _clockMismatch
                    ? text["ClockMismatch"]
                    : LastTransportLatency is { } latency
                        ? $"{Math.Round(latency.TotalMilliseconds, MidpointRounding.AwayFromZero):0} ms"
                        : "— ms";
                break;
            case LiveDashboardConnectionStatus.Connecting:
            case LiveDashboardConnectionStatus.Reconnecting:
                SourceLabel = CurrentState.LastIngestSequence > 0
                    ? text["LastKnownSource"]
                    : text["CoreWaitingSource"];
                ConnectionLabel = ConnectionStatus == LiveDashboardConnectionStatus.Reconnecting
                    ? text["ReconnectingToCore"]
                    : text["ConnectingToCore"];
                ConnectionBrushKey = OverviewBrushKeys.Idle;
                StatusSummary = ConnectionStatus == LiveDashboardConnectionStatus.Reconnecting
                    ? text["CoreInterruptedLastKnown"]
                    : text["ConnectingCoreStateService"];
                LatencyLabel = "— ms";
                break;
            case LiveDashboardConnectionStatus.Offline:
                SourceLabel = CurrentState.LastIngestSequence > 0
                    ? text["LastKnownSource"]
                    : text["NoCoreDataSource"];
                ConnectionLabel = text.Format(
                    "CoreOfflineFormat",
                    _lastOfflineExceptionType ?? text["ValueUnknown"]);
                ConnectionBrushKey = OverviewBrushKeys.Offline;
                StatusSummary = text["CoreOfflineSummary"];
                LatencyLabel = "— ms";
                break;
            case LiveDashboardConnectionStatus.Stopped:
                SourceLabel = CurrentState.LastIngestSequence > 0
                    ? text["LastKnownSource"]
                    : text["NoCoreDataSource"];
                ConnectionLabel = text["AppStateClientStopped"];
                ConnectionBrushKey = OverviewBrushKeys.Offline;
                StatusSummary = text["AppSubscriptionClosed"];
                LatencyLabel = "— ms";
                break;
            default:
                SourceLabel = text["CoreWaitingSource"];
                ConnectionLabel = text["CoreNotConnected"];
                ConnectionBrushKey = OverviewBrushKeys.Offline;
                StatusSummary = text["WaitingForCore"];
                LatencyLabel = "— ms";
                break;
        }
    }

    private static OverviewActivity RenderActivity(LiveActivityRecord activity)
    {
        var arguments = activity.DescriptionArguments
            .Select(argument => argument is LocalizedStatusArgument status
                ? AgentStatusPresentation.DisplayStatus(status.StatusCode)
                : argument)
            .ToArray();
        return new OverviewActivity(
            activity.Time,
            activity.Initials,
            activity.Agent,
            arguments.Length == 0
                ? UiLanguageService.Shared[activity.DescriptionKey]
                : UiLanguageService.Shared.Format(activity.DescriptionKey, arguments),
            activity.Reference,
            activity.AccentBrushKey);
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

    private sealed record LiveActivityRecord(
        string Time,
        string Initials,
        string Agent,
        string DescriptionKey,
        object[] DescriptionArguments,
        string Reference,
        string AccentBrushKey);

    private sealed record LocalizedStatusArgument(string StatusCode);
}
