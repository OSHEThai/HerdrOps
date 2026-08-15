using HerdrOps.App.Agents;
using HerdrOps.App.Activity;
using HerdrOps.App.Alignment;
using HerdrOps.App.Compliance;
using HerdrOps.App.Delegation;
using HerdrOps.App.Localization;
using HerdrOps.App.Organization;
using HerdrOps.App.Overview;
using HerdrOps.App.StateIpc;
using HerdrOps.App.Widgets;
using HerdrOps.Contracts.StateIpc;
using HerdrOps.Domain.Activity;
using HerdrOps.Domain.Assignments;
using HerdrOps.Domain.Notifications;

namespace HerdrOps.App.Live;

public enum LiveDashboardConnectionStatus
{
    Waiting,
    Connecting,
    Live,
    HerdrConnecting,
    HerdrReconnecting,
    HerdrOffline,
    Reconnecting,
    Offline,
    Stopped,
    SyntheticPreview,
}

public sealed class LiveDashboardState : ObservableState, IDisposable
{
    private readonly List<LiveActivityRecord> _activities = [];
    private readonly bool _syntheticPreview;
    private AssignmentLifecycleReplayResult? _assignmentReplay;
    private IReadOnlyList<TaskAlignmentAnalysisResult> _taskAlignmentAnalyses = [];
    private HerdrSessionStateContract _currentState = HerdrSessionStateContract.Empty;
    private HerdrRuntimeHealthContract _currentRuntimeHealth =
        HerdrRuntimeHealthContract.Starting(DateTimeOffset.UnixEpoch);
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
    private TimeSpan? _lastUpdateLatency;
    private HerdrOpsStateUpdateKind? _lastUpdateKind;
    private string? _lastOfflineExceptionType;
    private bool _clockMismatch;
    private bool _disposed;

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
        RealtimeActivity = syntheticPreview
            ? RealtimeActivityState.CreateSyntheticPreview()
            : RealtimeActivityState.CreateUnavailable();
        DelegationGraph = syntheticPreview
            ? DelegationGraphState.CreateSyntheticPreview()
            : new DelegationGraphState();
        TaskAlignment = syntheticPreview
            ? TaskAlignmentState.CreateSyntheticPreview()
            : new TaskAlignmentState();
        ComplianceQueue = syntheticPreview
            ? ComplianceQueueState.CreateSyntheticPreview()
            : ComplianceQueueState.CreateUnavailableLiveState();
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

    public RealtimeActivityState RealtimeActivity { get; }

    public DelegationGraphState DelegationGraph { get; }

    public TaskAlignmentState TaskAlignment { get; }

    public ComplianceQueueState ComplianceQueue { get; }

    public HerdrSessionStateContract CurrentState
    {
        get => _currentState;
        private set => Set(ref _currentState, value);
    }

    public HerdrRuntimeHealthContract CurrentRuntimeHealth
    {
        get => _currentRuntimeHealth;
        private set => Set(ref _currentRuntimeHealth, value);
    }

    public LiveDashboardConnectionStatus ConnectionStatus
    {
        get => _connectionStatus;
        private set
        {
            if (Set(ref _connectionStatus, value))
            {
                Raise(nameof(IsCoreConnected));
            }
        }
    }

    public bool IsLive { get => _isLive; private set => Set(ref _isLive, value); }

    public bool IsCoreConnected => ConnectionStatus is
        LiveDashboardConnectionStatus.Live or
        LiveDashboardConnectionStatus.HerdrConnecting or
        LiveDashboardConnectionStatus.HerdrReconnecting or
        LiveDashboardConnectionStatus.HerdrOffline;

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

    public TimeSpan? LastUpdateLatency
    {
        get => _lastUpdateLatency;
        private set => Set(ref _lastUpdateLatency, value);
    }

    public void ApplyUpdate(HerdrOpsStateUpdate update, DateTimeOffset receivedUtc)
    {
        ArgumentNullException.ThrowIfNull(update);
        EnsureUtc(receivedUtc, nameof(receivedUtc));
        var normalized = HerdrSessionStateContractReducer.NormalizeAndValidate(update.CurrentState);
        HerdrSessionStateContractReducer.ValidateRuntimeHealth(update.RuntimeHealth);
        CurrentState = normalized;
        CurrentRuntimeHealth = update.RuntimeHealth;
        ApplyRuntimeHealth(update.RuntimeHealth);
        _lastUpdateKind = update.Kind;
        _lastOfflineExceptionType = null;
        LastSourceTimestamp = update.RuntimeHealth.LastAcceptedStateUtc ??
            (LastSourceTimestamp == default ? update.Envelope.SentUtc : LastSourceTimestamp);
        if (update.Kind != HerdrOpsStateUpdateKind.RuntimeHealth)
        {
            var acceptedStateUtc = update.RuntimeHealth.LastAcceptedStateUtc ??
                update.Envelope.SentUtc;
            var latency = receivedUtc - acceptedStateUtc;
            _clockMismatch = latency < TimeSpan.Zero;
            LastUpdateLatency = latency < TimeSpan.Zero ? null : latency;
        }
        if (update.Kind != HerdrOpsStateUpdateKind.RuntimeHealth)
        {
            UpdateActivities(update);
        }
        SelectedTerminalId = ResolveSelection(normalized, SelectedTerminalId);
        RefreshPresentation();
        RefreshViews(recordWidgetLatency: update.Kind is
            HerdrOpsStateUpdateKind.Snapshot or
            HerdrOpsStateUpdateKind.Delta);
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
        Organization.SelectAgent(CurrentState, IsCoreConnected, IsLive, resolved);
        AgentDetail.Update(CurrentState, IsCoreConnected, IsLive, SourceLabel, ConnectionLabel, resolved);
        Widgets.Update(
            CurrentState,
            IsCoreConnected,
            IsLive,
            ConnectionLabel,
            LastSourceTimestamp,
            resolved,
            LastUpdateLatency,
            recordLatency: false,
            CreateWidgetAssignmentProjection());
    }

    public void ApplyAssignmentWorkspace(
        AssignmentLifecycleReplayResult replay,
        TaskAlignmentAnalysisRequest? alignmentRequest,
        string projectLabel,
        string sourceLabel,
        string evidenceBoundary)
    {
        ArgumentNullException.ThrowIfNull(replay);
        ArgumentException.ThrowIfNullOrWhiteSpace(projectLabel);
        ArgumentException.ThrowIfNullOrWhiteSpace(sourceLabel);
        ArgumentException.ThrowIfNullOrWhiteSpace(evidenceBoundary);
        var graph = AssignmentDelegationGraphProjector.Create(replay);
        TaskAlignmentAnalysisResult? analysis = null;
        if (alignmentRequest is not null)
        {
            if (!string.Equals(
                    alignmentRequest.LifecycleReplay.ResultSha256,
                    replay.ResultSha256,
                    StringComparison.Ordinal))
            {
                throw new ArgumentException(
                    "Task Alignment and Delegation must bind the same lifecycle replay.",
                    nameof(alignmentRequest));
            }

            analysis = TaskAlignmentAnalyzer.Analyze(alignmentRequest);
        }

        _assignmentReplay = replay;
        _taskAlignmentAnalyses = analysis is null ? [] : [analysis];
        DelegationGraph.ApplyGraph(graph, projectLabel, sourceLabel, evidenceBoundary);
        if (alignmentRequest is null)
        {
            TaskAlignment.MarkUnavailable(
                projectLabel,
                sourceLabel,
                evidenceBoundary);
        }
        else
        {
            TaskAlignment.ApplyAnalysis(
                alignmentRequest,
                projectLabel,
                sourceLabel,
                evidenceBoundary);
        }

        RefreshViews();
    }

    public NotificationCenterDecision ApplyActivity(ActivityPipelineStep step)
    {
        ArgumentNullException.ThrowIfNull(step);
        return Widgets.ApplyNotification(step);
    }

    public void RefreshLanguage()
    {
        if (_disposed)
        {
            return;
        }

        RefreshPresentation();
        RefreshViews();
        RealtimeActivity.RefreshLanguage();
        DelegationGraph.RefreshLanguage();
        TaskAlignment.RefreshLanguage();
        ComplianceQueue.RefreshLanguage();
        if (_syntheticPreview)
        {
            AgentDetail.ApplySyntheticPreviewProfile();
        }
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        // ComplianceQueue is owned by this dashboard state. Shell views can be
        // unloaded and reloaded without ending the App-wide state lifetime.
        ComplianceQueue.Dispose();
    }

    private void RefreshViews(bool recordWidgetLatency = false)
    {
        Overview.Update(
            CurrentState,
            IsCoreConnected,
            IsLive,
            SourceLabel,
            ConnectionLabel,
            LastSourceTimestamp,
            _activities.Select(RenderActivity).ToArray());
        Organization.Update(
            CurrentState,
            IsCoreConnected,
            IsLive,
            SourceLabel,
            ConnectionLabel,
            SelectedTerminalId);
        AgentDetail.Update(
            CurrentState,
            IsCoreConnected,
            IsLive,
            SourceLabel,
            ConnectionLabel,
            SelectedTerminalId);
        Widgets.Update(
            CurrentState,
            IsCoreConnected,
            IsLive,
            ConnectionLabel,
            LastSourceTimestamp,
            SelectedTerminalId,
            LastUpdateLatency,
            recordWidgetLatency,
            CreateWidgetAssignmentProjection());
        if (!DelegationGraph.HasGraph)
        {
            DelegationGraph.MarkUnavailableFromCatalog(
                ProjectLabel,
                "DelegationWaitingSource",
                "DelegationUnavailableBoundary");
        }

        if (!TaskAlignment.HasAnalysis)
        {
            TaskAlignment.MarkUnavailableFromCatalog(
                ProjectLabel,
                "AlignmentWaitingSource",
                "AlignmentUnavailableBoundary");
        }
    }

    private WidgetAssignmentProjection CreateWidgetAssignmentProjection() =>
        _assignmentReplay is null || CurrentState.LastIngestSequence == 0
            ? WidgetAssignmentProjection.Empty
            : WidgetAssignmentProjector.Create(
                CurrentState,
                _assignmentReplay,
                _taskAlignmentAnalyses);

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
                SourceLabel = _lastUpdateKind switch
                {
                    HerdrOpsStateUpdateKind.Delta => text["CoreDeltaSource"],
                    HerdrOpsStateUpdateKind.RuntimeHealth => text["CoreRuntimeHealthSource"],
                    _ => text["CoreSnapshotSource"],
                };
                ConnectionLabel = CurrentState.LastIngestSequence == 0
                    ? text["CoreConnectedNoSnapshot"]
                    : text["HerdrConnectedLive"];
                ConnectionBrushKey = OverviewBrushKeys.Working;
                StatusSummary = CurrentState.LastIngestSequence == 0
                    ? text["CoreLiveNoSnapshot"]
                    : text.Format(
                        "LatestAcceptedStateFormat",
                        CurrentState.ConnectionEpoch,
                        CurrentState.LastIngestSequence);
                LatencyLabel = _clockMismatch
                    ? text["ClockMismatch"]
                    : LastUpdateLatency is { } latency
                        ? $"{Math.Round(latency.TotalMilliseconds, MidpointRounding.AwayFromZero):0} ms"
                        : "— ms";
                break;
            case LiveDashboardConnectionStatus.HerdrConnecting:
            case LiveDashboardConnectionStatus.HerdrReconnecting:
                SourceLabel = CurrentState.LastIngestSequence > 0
                    ? text["LastKnownSource"]
                    : text["CoreWaitingSource"];
                ConnectionLabel = ConnectionStatus == LiveDashboardConnectionStatus.HerdrReconnecting
                    ? text["HerdrReconnecting"]
                    : text["HerdrConnecting"];
                ConnectionBrushKey = OverviewBrushKeys.Idle;
                StatusSummary = CurrentState.LastIngestSequence > 0
                    ? text["HerdrInterruptedLastKnown"]
                    : text["WaitingForHerdrSnapshot"];
                LatencyLabel = _clockMismatch
                    ? text["ClockMismatch"]
                    : LastUpdateLatency is { } herdrLatency
                        ? $"{Math.Round(herdrLatency.TotalMilliseconds, MidpointRounding.AwayFromZero):0} ms"
                        : "— ms";
                break;
            case LiveDashboardConnectionStatus.HerdrOffline:
                SourceLabel = CurrentState.LastIngestSequence > 0
                    ? text["LastKnownSource"]
                    : text["NoCoreDataSource"];
                ConnectionLabel = text["HerdrRuntimeStopped"];
                ConnectionBrushKey = OverviewBrushKeys.Offline;
                StatusSummary = text["HerdrStoppedLastKnown"];
                LatencyLabel = "— ms";
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

    private void ApplyRuntimeHealth(HerdrRuntimeHealthContract health)
    {
        switch (health.Status)
        {
            case "Connected":
                ConnectionStatus = LiveDashboardConnectionStatus.Live;
                IsLive = true;
                break;
            case "Starting":
                ConnectionStatus = LiveDashboardConnectionStatus.HerdrConnecting;
                IsLive = false;
                break;
            case "Reconnecting":
                ConnectionStatus = LiveDashboardConnectionStatus.HerdrReconnecting;
                IsLive = false;
                break;
            case "Stopped":
                ConnectionStatus = LiveDashboardConnectionStatus.HerdrOffline;
                IsLive = false;
                break;
            default:
                throw new HerdrOpsStateIpcProtocolException(
                    $"Unsupported runtime health status '{health.Status}'.");
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
