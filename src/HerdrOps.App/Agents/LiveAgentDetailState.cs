using HerdrOps.App.Live;
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
    string ThaiTitle,
    string EnglishTitle,
    string Value,
    string Explanation);

public sealed class LiveAgentDetailState : ObservableState
{
    private string _sourceLabel = "WAITING FOR CORE";
    private string _connectionLabel = "Core not connected";
    private string _initials = "?";
    private string _name = "No Agent selected";
    private string _runtime = "Unknown runtime";
    private string _status = "Offline";
    private string _statusBrushKey = OverviewBrushKeys.Offline;
    private string _workspace = "Unknown";
    private string _tab = "Unknown";
    private string _pane = "Unknown";
    private string _terminal = "Unknown";
    private string _title = "Unknown";
    private string _currentDirectory = "Unknown";
    private string _foregroundDirectory = "Unknown";
    private string _terminalTitle = "Unknown";
    private string _revision = "—";
    private string _stateChangeSequence = "—";
    private string _sessionSequence = "0";
    private string _connectionEpoch = "0";
    private string _interactiveReady = "Unknown";
    private string _launchPending = "Unknown";
    private string _screenDetectionSkipped = "Unknown";
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
        Initials = "PM";
        Name = "Project Manager";
        Runtime = "Synthetic profile";
        Status = "Preview";
        StatusBrushKey = OverviewBrushKeys.Review;
    }

    internal void Update(
        HerdrSessionStateContract state,
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
        Status = AgentStatusPresentation.EffectiveStatus(agent.AgentStatus, isLive);
        StatusBrushKey = AgentStatusPresentation.BrushKey(Status);
        Workspace = LabelForWorkspace(state, agent.WorkspaceId);
        Tab = LabelForTab(state, agent.TabId);
        Pane = agent.PaneId;
        Terminal = agent.TerminalId;
        Title = AgentStatusPresentation.FirstNonEmpty(agent.Title, "Unknown");
        CurrentDirectory = AgentStatusPresentation.FirstNonEmpty(agent.CurrentDirectory, "Unknown");
        ForegroundDirectory = AgentStatusPresentation.FirstNonEmpty(
            agent.ForegroundCurrentDirectory,
            "Unknown");
        TerminalTitle = AgentStatusPresentation.FirstNonEmpty(agent.TerminalTitle, "Unknown");
        Revision = agent.Revision.ToString(System.Globalization.CultureInfo.InvariantCulture);
        StateChangeSequence = agent.StateChangeSequence.ToString(
            System.Globalization.CultureInfo.InvariantCulture);
        InteractiveReady = AgentStatusPresentation.OptionalBoolean(agent.InteractiveReady);
        LaunchPending = AgentStatusPresentation.OptionalBoolean(agent.LaunchPending);
        ScreenDetectionSkipped = AgentStatusPresentation.OptionalBoolean(agent.ScreenDetectionSkipped);
        RecentFacts = CreateFacts(state, agent, isLive);
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
                    effectiveStatus,
                    AgentStatusPresentation.BrushKey(effectiveStatus));
            })
            .ToArray();
        UnsupportedSections = CreateUnsupportedSections();
    }

    private void ApplyEmpty(bool isLive)
    {
        Initials = "?";
        Name = "No Agent selected";
        Runtime = "Unknown runtime";
        Status = isLive ? "Unknown" : AgentStatusPresentation.Offline;
        StatusBrushKey = OverviewBrushKeys.Offline;
        Workspace = "Unknown";
        Tab = "Unknown";
        Pane = "Unknown";
        Terminal = "Unknown";
        Title = "Unknown";
        CurrentDirectory = "Unknown";
        ForegroundDirectory = "Unknown";
        TerminalTitle = "Unknown";
        Revision = "—";
        StateChangeSequence = "—";
        InteractiveReady = "Unknown";
        LaunchPending = "Unknown";
        ScreenDetectionSkipped = "Unknown";
        RecentFacts = [];
        RelatedAgents = [];
        UnsupportedSections = CreateUnsupportedSections();
    }

    private static IReadOnlyList<AgentDetailFact> CreateFacts(
        HerdrSessionStateContract state,
        HerdrAgentStateContract agent,
        bool isLive) =>
    [
        new("State freshness", isLive ? "Latest accepted" : "Last known / offline", isLive ? "Core stream live · Herdr runtime freshness unknown" : "Core-to-App IPC offline"),
        new("Herdr status", isLive ? $"Observed {agent.AgentStatus}" : "Unknown while offline", "Latest accepted Herdr session state"),
        new("Pane revision", agent.Revision.ToString(), "Herdr pane metadata"),
        new("State change sequence", agent.StateChangeSequence.ToString(), "Herdr agent metadata"),
        new("Session sequence", state.LastIngestSequence.ToString(), "HerdrOps Core"),
    ];

    private static IReadOnlyList<AgentDetailUnsupportedSection> CreateUnsupportedSections() =>
    [
        new("งานที่ได้รับมอบหมาย", "Current Assignment", "Unknown", "Not supplied by Herdr protocol 19"),
        new("หลักฐานที่ส่งแล้ว", "Evidence Submitted", "Unknown", "Evidence collection starts in a later version"),
        new("คะแนนรายมิติ", "Score by Dimension", "Unknown", "Evaluation is outside v0.2 state"),
        new("งานที่เปิดอยู่", "Open Tasks", "Unknown", "Task contracts are introduced in v0.4"),
    ];

    private static string LabelForWorkspace(HerdrSessionStateContract state, string workspaceId) =>
        AgentStatusPresentation.FirstNonEmpty(
            state.Workspaces.FirstOrDefault(item => item.WorkspaceId == workspaceId)?.Label,
            workspaceId);

    private static string LabelForTab(HerdrSessionStateContract state, string tabId) =>
        AgentStatusPresentation.FirstNonEmpty(
            state.Tabs.FirstOrDefault(item => item.TabId == tabId)?.Label,
            tabId);
}
