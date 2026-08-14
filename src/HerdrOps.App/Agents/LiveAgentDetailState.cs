using HerdrOps.App.Live;
using HerdrOps.App.Localization;
using HerdrOps.App.Overview;
using HerdrOps.Contracts.StateIpc;

namespace HerdrOps.App.Agents;

public sealed record AgentDetailFact(
    string Label,
    string Value,
    string Source);

public sealed record AgentDetailRelatedAgent(
    string Initials,
    string Name,
    string Runtime,
    string Status,
    string AccentBrushKey);

public sealed record AgentDetailUnsupportedSection(
    string Title,
    string Value,
    string Explanation);

public sealed class LiveAgentDetailState : ObservableState
{
    private string _sourceLabel = UiLanguageService.Shared["CoreWaitingSource"];
    private string _connectionLabel = UiLanguageService.Shared["CoreNotConnected"];
    private string _initials = "?";
    private string _name = UiLanguageService.Shared["NoAgentSelected"];
    private string _runtime = UiLanguageService.Shared["UnknownRuntime"];
    private string _status = UiLanguageService.Shared["StatusOffline"];
    private string _statusBrushKey = OverviewBrushKeys.Offline;
    private string _workspace = UiLanguageService.Shared["ValueUnknown"];
    private string _tab = UiLanguageService.Shared["ValueUnknown"];
    private string _pane = UiLanguageService.Shared["ValueUnknown"];
    private string _terminal = UiLanguageService.Shared["ValueUnknown"];
    private string _title = UiLanguageService.Shared["ValueUnknown"];
    private string _currentDirectory = UiLanguageService.Shared["ValueUnknown"];
    private string _foregroundDirectory = UiLanguageService.Shared["ValueUnknown"];
    private string _terminalTitle = UiLanguageService.Shared["ValueUnknown"];
    private string _revision = "—";
    private string _stateChangeSequence = "—";
    private string _sessionSequence = "0";
    private string _connectionEpoch = "0";
    private string _interactiveReady = UiLanguageService.Shared["ValueUnknown"];
    private string _launchPending = UiLanguageService.Shared["ValueUnknown"];
    private string _screenDetectionSkipped = UiLanguageService.Shared["ValueUnknown"];
    private IReadOnlyList<AgentDetailFact> _recentFacts = [];
    private IReadOnlyList<AgentDetailRelatedAgent> _relatedAgents = [];
    private IReadOnlyList<AgentDetailUnsupportedSection> _unsupportedSections = [];

    public string SourceLabel { get => _sourceLabel; private set => Set(ref _sourceLabel, value); }

    public string ConnectionLabel { get => _connectionLabel; private set => Set(ref _connectionLabel, value); }

    public string Initials { get => _initials; private set => Set(ref _initials, value); }

    public string Name { get => _name; private set => Set(ref _name, value); }

    public string Runtime { get => _runtime; private set => Set(ref _runtime, value); }

    public string Status { get => _status; private set => Set(ref _status, value); }

    public string StatusBrushKey
    {
        get => _statusBrushKey;
        private set => Set(ref _statusBrushKey, value);
    }

    public string Workspace { get => _workspace; private set => Set(ref _workspace, value); }

    public string Tab { get => _tab; private set => Set(ref _tab, value); }

    public string Pane { get => _pane; private set => Set(ref _pane, value); }

    public string Terminal { get => _terminal; private set => Set(ref _terminal, value); }

    public string Title { get => _title; private set => Set(ref _title, value); }

    public string CurrentDirectory
    {
        get => _currentDirectory;
        private set => Set(ref _currentDirectory, value);
    }

    public string ForegroundDirectory
    {
        get => _foregroundDirectory;
        private set => Set(ref _foregroundDirectory, value);
    }

    public string TerminalTitle
    {
        get => _terminalTitle;
        private set => Set(ref _terminalTitle, value);
    }

    public string Revision { get => _revision; private set => Set(ref _revision, value); }

    public string StateChangeSequence
    {
        get => _stateChangeSequence;
        private set => Set(ref _stateChangeSequence, value);
    }

    public string SessionSequence
    {
        get => _sessionSequence;
        private set => Set(ref _sessionSequence, value);
    }

    public string ConnectionEpoch
    {
        get => _connectionEpoch;
        private set => Set(ref _connectionEpoch, value);
    }

    public string InteractiveReady
    {
        get => _interactiveReady;
        private set => Set(ref _interactiveReady, value);
    }

    public string LaunchPending
    {
        get => _launchPending;
        private set => Set(ref _launchPending, value);
    }

    public string ScreenDetectionSkipped
    {
        get => _screenDetectionSkipped;
        private set => Set(ref _screenDetectionSkipped, value);
    }

    public IReadOnlyList<AgentDetailFact> RecentFacts
    {
        get => _recentFacts;
        private set => Set(ref _recentFacts, value);
    }

    public IReadOnlyList<AgentDetailRelatedAgent> RelatedAgents
    {
        get => _relatedAgents;
        private set => Set(ref _relatedAgents, value);
    }

    public IReadOnlyList<AgentDetailUnsupportedSection> UnsupportedSections
    {
        get => _unsupportedSections;
        private set => Set(ref _unsupportedSections, value);
    }

    internal void ApplySyntheticPreviewProfile()
    {
        var text = UiLanguageService.Shared;
        Initials = "PM";
        Name = text["RealtimeActorProjectManager"];
        Runtime = text["SyntheticProfile"];
        Status = text["PreviewStatus"];
        StatusBrushKey = OverviewBrushKeys.Review;
    }

    internal void Update(
        HerdrSessionStateContract state,
        bool isCoreConnected,
        bool isLive,
        string sourceLabel,
        string connectionLabel,
        string? selectedTerminalId)
    {
        ArgumentNullException.ThrowIfNull(state);
        SourceLabel = sourceLabel;
        ConnectionLabel = connectionLabel;
        SessionSequence = state.LastIngestSequence.ToString(System.Globalization.CultureInfo.InvariantCulture);
        ConnectionEpoch = state.ConnectionEpoch.ToString(System.Globalization.CultureInfo.InvariantCulture);
        var agent = selectedTerminalId is null
            ? null
            : state.Agents.FirstOrDefault(item => item.TerminalId == selectedTerminalId);
        if (agent is null)
        {
            ApplyEmpty(isLive);
            return;
        }

        Initials = AgentStatusPresentation.Initials(agent);
        Name = AgentStatusPresentation.DisplayName(agent);
        Runtime = AgentStatusPresentation.RuntimeName(agent);
        var effectiveStatus = AgentStatusPresentation.EffectiveStatus(agent.AgentStatus, isLive);
        Status = AgentStatusPresentation.DisplayStatus(effectiveStatus);
        StatusBrushKey = AgentStatusPresentation.BrushKey(effectiveStatus);
        Workspace = LabelForWorkspace(state, agent.WorkspaceId);
        Tab = LabelForTab(state, agent.TabId);
        Pane = agent.PaneId;
        Terminal = agent.TerminalId;
        Title = AgentStatusPresentation.FirstNonEmpty(agent.Title);
        CurrentDirectory = AgentStatusPresentation.FirstNonEmpty(agent.CurrentDirectory);
        ForegroundDirectory = AgentStatusPresentation.FirstNonEmpty(
            agent.ForegroundCurrentDirectory);
        TerminalTitle = AgentStatusPresentation.FirstNonEmpty(agent.TerminalTitle);
        Revision = agent.Revision.ToString(System.Globalization.CultureInfo.InvariantCulture);
        StateChangeSequence = agent.StateChangeSequence.ToString(
            System.Globalization.CultureInfo.InvariantCulture);
        InteractiveReady = AgentStatusPresentation.OptionalBoolean(agent.InteractiveReady);
        LaunchPending = AgentStatusPresentation.OptionalBoolean(agent.LaunchPending);
        ScreenDetectionSkipped = AgentStatusPresentation.OptionalBoolean(agent.ScreenDetectionSkipped);
        RecentFacts = CreateFacts(state, agent, isCoreConnected, isLive);
        RelatedAgents = state.Agents
            .Where(item => item.TerminalId != agent.TerminalId && item.WorkspaceId == agent.WorkspaceId)
            .OrderBy(AgentStatusPresentation.DisplayName, StringComparer.OrdinalIgnoreCase)
            .Take(5)
            .Select(item =>
            {
                var effectiveStatus = AgentStatusPresentation.EffectiveStatus(item.AgentStatus, isLive);
                return new AgentDetailRelatedAgent(
                    AgentStatusPresentation.Initials(item),
                    AgentStatusPresentation.DisplayName(item),
                    AgentStatusPresentation.RuntimeName(item),
                    AgentStatusPresentation.DisplayStatus(effectiveStatus),
                    AgentStatusPresentation.BrushKey(effectiveStatus));
            })
            .ToArray();
        UnsupportedSections = CreateUnsupportedSections();
    }

    private void ApplyEmpty(bool isLive)
    {
        Initials = "?";
        var text = UiLanguageService.Shared;
        Name = text["NoAgentSelected"];
        Runtime = text["UnknownRuntime"];
        Status = AgentStatusPresentation.DisplayStatus(
            isLive ? "Unknown" : AgentStatusPresentation.Offline);
        StatusBrushKey = OverviewBrushKeys.Offline;
        Workspace = text["ValueUnknown"];
        Tab = text["ValueUnknown"];
        Pane = text["ValueUnknown"];
        Terminal = text["ValueUnknown"];
        Title = text["ValueUnknown"];
        CurrentDirectory = text["ValueUnknown"];
        ForegroundDirectory = text["ValueUnknown"];
        TerminalTitle = text["ValueUnknown"];
        Revision = "—";
        StateChangeSequence = "—";
        InteractiveReady = text["ValueUnknown"];
        LaunchPending = text["ValueUnknown"];
        ScreenDetectionSkipped = text["ValueUnknown"];
        RecentFacts = [];
        RelatedAgents = [];
        UnsupportedSections = CreateUnsupportedSections();
    }

    private static IReadOnlyList<AgentDetailFact> CreateFacts(
        HerdrSessionStateContract state,
        HerdrAgentStateContract agent,
        bool isCoreConnected,
        bool isLive)
    {
        var text = UiLanguageService.Shared;
        return
        [
            new(
                text["AgentFactFreshness"],
                isLive ? text["AgentFactLatestAccepted"] : text["AgentFactLastKnownOffline"],
                isLive
                    ? text["AgentFactCoreLive"]
                    : isCoreConnected
                        ? text["AgentFactHerdrInterrupted"]
                        : text["AgentFactCoreOffline"]),
            new(
                text["AgentFactHerdrStatus"],
                isLive
                    ? text.Format(
                        "AgentFactObservedStatusFormat",
                        AgentStatusPresentation.DisplayStatus(agent.AgentStatus))
                    : text["AgentFactUnknownOffline"],
                text["AgentFactLatestHerdrState"]),
            new(text["AgentFactPaneRevision"], agent.Revision.ToString(), text["AgentFactPaneMetadata"]),
            new(text["AgentFactStateSequence"], agent.StateChangeSequence.ToString(), text["AgentFactAgentMetadata"]),
            new(text["AgentFactSessionSequence"], state.LastIngestSequence.ToString(), "HerdrOps Core"),
        ];
    }

    private static IReadOnlyList<AgentDetailUnsupportedSection> CreateUnsupportedSections()
    {
        var text = UiLanguageService.Shared;
        return
        [
            new(text["AgentUnsupportedAssignment"], text["ValueUnknown"], text["AgentUnsupportedAssignmentReason"]),
            new(text["AgentUnsupportedEvidence"], text["ValueUnknown"], text["AgentUnsupportedEvidenceReason"]),
            new(text["AgentUnsupportedScore"], text["ValueUnknown"], text["AgentUnsupportedScoreReason"]),
            new(text["AgentUnsupportedTasks"], text["ValueUnknown"], text["AgentUnsupportedTasksReason"]),
        ];
    }

    private static string LabelForWorkspace(HerdrSessionStateContract state, string workspaceId) =>
        AgentStatusPresentation.FirstNonEmpty(
            state.Workspaces.FirstOrDefault(item => item.WorkspaceId == workspaceId)?.Label,
            workspaceId);

    private static string LabelForTab(HerdrSessionStateContract state, string tabId) =>
        AgentStatusPresentation.FirstNonEmpty(
            state.Tabs.FirstOrDefault(item => item.TabId == tabId)?.Label,
            tabId);
}
