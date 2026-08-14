using HerdrOps.App.Live;
using HerdrOps.Contracts.StateIpc;

namespace HerdrOps.App.Organization;

public sealed record OrganizationSummaryCard(
    string ThaiTitle,
    string EnglishTitle,
    string Value,
    string Detail,
    string IconGlyph,
    string AccentBrushKey);

public sealed record OrganizationNode(
    string NodeId,
    int Level,
    string NodeType,
    string Initials,
    string Name,
    string Subtitle,
    string Status,
    string AccentBrushKey,
    string? AgentTerminalId)
{
    public double IndentWidth => Level * 24d;

    public bool IsAgent => AgentTerminalId is not null;
}

public sealed record OrganizationAgentDetail(
    string Initials,
    string Name,
    string Runtime,
    string Status,
    string StatusBrushKey,
    string Workspace,
    string Tab,
    string Pane,
    string Terminal,
    string CurrentDirectory,
    string Revision,
    string SourceNote);

public sealed record OrganizationAttentionItem(
    string IconGlyph,
    string Title,
    string Detail,
    string AccentBrushKey);

public sealed class LiveOrganizationState : ObservableState
{
    private bool _suppressSelection;
    private string _sourceLabel = "WAITING FOR CORE";
    private string _connectionLabel = "Core not connected";
    private IReadOnlyList<OrganizationSummaryCard> _summaryCards = [];
    private IReadOnlyList<OrganizationNode> _nodes = [];
    private OrganizationNode? _selectedNode;
    private OrganizationAgentDetail _selectedAgent = EmptyDetail(isLive: false);
    private IReadOnlyList<OrganizationAttentionItem> _attentionItems = [];
    private string _hierarchyLabel = "No Core snapshot";

    public event EventHandler<string>? AgentSelectionRequested;

    public string SourceLabel { get => _sourceLabel; private set => Set(ref _sourceLabel, value); }

    public string ConnectionLabel { get => _connectionLabel; private set => Set(ref _connectionLabel, value); }

    public IReadOnlyList<OrganizationSummaryCard> SummaryCards
    {
        get => _summaryCards;
        private set => Set(ref _summaryCards, value);
    }

    public IReadOnlyList<OrganizationNode> Nodes
    {
        get => _nodes;
        private set => Set(ref _nodes, value);
    }

    public OrganizationNode? SelectedNode
    {
        get => _selectedNode;
        set
        {
            if (!Set(ref _selectedNode, value) ||
                _suppressSelection ||
                value?.AgentTerminalId is not { } terminalId)
            {
                return;
            }

            AgentSelectionRequested?.Invoke(this, terminalId);
        }
    }

    public OrganizationAgentDetail SelectedAgent
    {
        get => _selectedAgent;
        private set => Set(ref _selectedAgent, value);
    }

    public IReadOnlyList<OrganizationAttentionItem> AttentionItems
    {
        get => _attentionItems;
        private set => Set(ref _attentionItems, value);
    }

    public string HierarchyLabel
    {
        get => _hierarchyLabel;
        private set => Set(ref _hierarchyLabel, value);
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
        SummaryCards = CreateSummaryCards(state, isLive);
        Nodes = CreateNodes(state, isLive);
        HierarchyLabel = state.LastIngestSequence == 0
            ? "Core has no admitted Herdr topology"
            : $"Herdr topology · epoch {state.ConnectionEpoch} · sequence {state.LastIngestSequence}";
        AttentionItems = CreateAttentionItems(state, isLive);
        SelectWithoutRequest(state, isLive, selectedTerminalId);
    }

    internal void SelectAgent(
        HerdrSessionStateContract state,
        bool isLive,
        string? terminalId) =>
        SelectWithoutRequest(state, isLive, terminalId);

    private void SelectWithoutRequest(
        HerdrSessionStateContract state,
        bool isLive,
        string? terminalId)
    {
        var agent = terminalId is null
            ? null
            : state.Agents.FirstOrDefault(item =>
                string.Equals(item.TerminalId, terminalId, StringComparison.Ordinal));
        var node = agent is null
            ? null
            : Nodes.FirstOrDefault(item =>
                string.Equals(item.AgentTerminalId, agent.TerminalId, StringComparison.Ordinal));
        _suppressSelection = true;
        try
        {
            SelectedNode = node;
        }
        finally
        {
            _suppressSelection = false;
        }

        SelectedAgent = agent is null
            ? EmptyDetail(isLive)
            : CreateDetail(state, agent, isLive);
    }

    private static IReadOnlyList<OrganizationSummaryCard> CreateSummaryCards(
        HerdrSessionStateContract state,
        bool isLive)
    {
        var assignedTerminalIds = state.Agents
            .Select(agent => agent.TerminalId)
            .ToHashSet(StringComparer.Ordinal);
        var unassignedPanes = state.Panes.Count(pane => !assignedTerminalIds.Contains(pane.TerminalId));
        var unknown = state.Agents.Count(agent => agent.AgentStatus == "Unknown");
        return
        [
            new("พื้นที่ทำงาน", "Workspaces", state.Workspaces.Count.ToString(), "Observed from Herdr", "\uE8B7", Overview.OverviewBrushKeys.Primary),
            new("แท็บที่พบ", "Tabs", state.Tabs.Count.ToString(), "Current topology", "\uE7C5", Overview.OverviewBrushKeys.Working),
            new("Agent ที่พบ", "Observed Agents", state.Agents.Count.ToString(), isLive ? "Latest accepted Core state" : "Last known only", "\uE716", isLive ? Overview.OverviewBrushKeys.Working : Overview.OverviewBrushKeys.Offline),
            new("Pane ที่ไม่มี Agent", "Unassigned Panes", unassignedPanes.ToString(), "No role inferred", "\uE77B", unassignedPanes == 0 ? Overview.OverviewBrushKeys.Primary : Overview.OverviewBrushKeys.Idle),
            new("สถานะไม่ทราบ", "Unknown Status", unknown.ToString(), "Never treated as success", "\uE814", unknown == 0 ? Overview.OverviewBrushKeys.Primary : Overview.OverviewBrushKeys.Offline),
        ];
    }

    private static IReadOnlyList<OrganizationNode> CreateNodes(
        HerdrSessionStateContract state,
        bool isLive)
    {
        var nodes = new List<OrganizationNode>();
        foreach (var workspace in state.Workspaces.OrderBy(item => item.Number))
        {
            nodes.Add(new OrganizationNode(
                workspace.WorkspaceId,
                0,
                "Workspace",
                "WS",
                AgentStatusPresentation.FirstNonEmpty(workspace.Label, workspace.WorkspaceId),
                $"Workspace {workspace.Number} · {workspace.TabCount} tabs · {workspace.PaneCount} panes",
                AgentStatusPresentation.EffectiveStatus(workspace.AgentStatus, isLive),
                AgentStatusPresentation.BrushKey(
                    AgentStatusPresentation.EffectiveStatus(workspace.AgentStatus, isLive)),
                null));

            foreach (var tab in state.Tabs
                         .Where(item => item.WorkspaceId == workspace.WorkspaceId)
                         .OrderBy(item => item.Number))
            {
                nodes.Add(new OrganizationNode(
                    tab.TabId,
                    1,
                    "Tab",
                    "TB",
                    AgentStatusPresentation.FirstNonEmpty(tab.Label, tab.TabId),
                    $"Tab {tab.Number} · {tab.PaneCount} panes",
                    AgentStatusPresentation.EffectiveStatus(tab.AgentStatus, isLive),
                    AgentStatusPresentation.BrushKey(
                        AgentStatusPresentation.EffectiveStatus(tab.AgentStatus, isLive)),
                    null));

                var tabAgents = state.Agents
                    .Where(item => item.TabId == tab.TabId)
                    .OrderBy(AgentStatusPresentation.DisplayName, StringComparer.OrdinalIgnoreCase)
                    .ToArray();
                foreach (var agent in tabAgents)
                {
                    var effectiveStatus = AgentStatusPresentation.EffectiveStatus(agent.AgentStatus, isLive);
                    nodes.Add(new OrganizationNode(
                        agent.TerminalId,
                        2,
                        "Agent",
                        AgentStatusPresentation.Initials(agent),
                        AgentStatusPresentation.DisplayName(agent),
                        $"{AgentStatusPresentation.RuntimeName(agent)} · {agent.PaneId}",
                        effectiveStatus,
                        AgentStatusPresentation.BrushKey(effectiveStatus),
                        agent.TerminalId));
                }

                var assignedPaneIds = tabAgents.Select(agent => agent.PaneId).ToHashSet(StringComparer.Ordinal);
                foreach (var pane in state.Panes
                             .Where(item => item.TabId == tab.TabId && !assignedPaneIds.Contains(item.PaneId))
                             .OrderBy(item => item.PaneId, StringComparer.Ordinal))
                {
                    nodes.Add(new OrganizationNode(
                        pane.PaneId,
                        2,
                        "Unassigned pane",
                        "?",
                        "Unknown Agent",
                        $"Pane {pane.PaneId} · terminal {pane.TerminalId}",
                        isLive ? "Unknown" : AgentStatusPresentation.Offline,
                        Overview.OverviewBrushKeys.Offline,
                        null));
                }
            }
        }

        return nodes;
    }

    private static OrganizationAgentDetail CreateDetail(
        HerdrSessionStateContract state,
        HerdrAgentStateContract agent,
        bool isLive)
    {
        var workspace = state.Workspaces.FirstOrDefault(item => item.WorkspaceId == agent.WorkspaceId);
        var tab = state.Tabs.FirstOrDefault(item => item.TabId == agent.TabId);
        var effectiveStatus = AgentStatusPresentation.EffectiveStatus(agent.AgentStatus, isLive);
        return new OrganizationAgentDetail(
            AgentStatusPresentation.Initials(agent),
            AgentStatusPresentation.DisplayName(agent),
            AgentStatusPresentation.RuntimeName(agent),
            effectiveStatus,
            AgentStatusPresentation.BrushKey(effectiveStatus),
            AgentStatusPresentation.FirstNonEmpty(workspace?.Label, agent.WorkspaceId),
            AgentStatusPresentation.FirstNonEmpty(tab?.Label, agent.TabId),
            agent.PaneId,
            agent.TerminalId,
            AgentStatusPresentation.FirstNonEmpty(
                agent.ForegroundCurrentDirectory,
                agent.CurrentDirectory,
                "Unknown"),
            agent.Revision.ToString(System.Globalization.CultureInfo.InvariantCulture),
            isLive ? "Latest accepted Core state · Herdr freshness unknown" : "Last known — Core offline");
    }

    private static OrganizationAgentDetail EmptyDetail(bool isLive) => new(
        "?",
        "No Agent selected",
        "Unknown runtime",
        isLive ? "Unknown" : AgentStatusPresentation.Offline,
        Overview.OverviewBrushKeys.Offline,
        "Unknown",
        "Unknown",
        "Unknown",
        "Unknown",
        "Unknown",
        "—",
        isLive ? "Select an observed Agent" : "Core is offline");

    private static IReadOnlyList<OrganizationAttentionItem> CreateAttentionItems(
        HerdrSessionStateContract state,
        bool isLive)
    {
        var result = new List<OrganizationAttentionItem>();
        if (!isLive)
        {
            result.Add(new OrganizationAttentionItem(
                "\uE711",
                "Core connection offline",
                "Hierarchy is last-known and no Agent status is current",
                Overview.OverviewBrushKeys.Offline));
        }

        var blocked = state.Agents.Count(agent => agent.AgentStatus == "Blocked");
        if (blocked > 0)
        {
            result.Add(new OrganizationAttentionItem(
                "\uEA39",
                $"{blocked} blocked Agents",
                "Reported directly by the accepted Core state contract",
                Overview.OverviewBrushKeys.Blocked));
        }

        var unknown = state.Agents.Count(agent => agent.AgentStatus == "Unknown");
        if (unknown > 0 || state.LastIngestSequence == 0)
        {
            result.Add(new OrganizationAttentionItem(
                "\uE814",
                state.LastIngestSequence == 0 ? "No Herdr topology snapshot" : $"{unknown} unknown Agent states",
                "Unknown values remain unknown and are not counted as healthy",
                Overview.OverviewBrushKeys.Offline));
        }

        var assignedPaneIds = state.Agents.Select(agent => agent.PaneId).ToHashSet(StringComparer.Ordinal);
        var unassigned = state.Panes.Count(pane => !assignedPaneIds.Contains(pane.PaneId));
        if (unassigned > 0)
        {
            result.Add(new OrganizationAttentionItem(
                "\uE77B",
                $"{unassigned} panes without Agent metadata",
                "HerdrOps does not invent a role or identity",
                Overview.OverviewBrushKeys.Idle));
        }

        return result;
    }
}
