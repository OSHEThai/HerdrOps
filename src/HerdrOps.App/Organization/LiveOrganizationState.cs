using HerdrOps.App.Live;
using HerdrOps.App.Localization;
using HerdrOps.Contracts.StateIpc;

namespace HerdrOps.App.Organization;

public sealed record OrganizationSummaryCard(
    string Title,
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

    /// <summary>
    /// The direct reporting node used by the organization layout. It is optional
    /// so ordinary topology nodes remain valid when a producer has no parent data.
    /// </summary>
    public string? ParentNodeId { get; init; }

    /// <summary>
    /// A presentation row that may differ from the source topology depth. The
    /// synthetic preview uses this to keep the assistant and leader bands clear.
    /// </summary>
    public int LayoutRow { get; init; }

    /// <summary>
    /// Reserved for small, semantic layout hints that do not change node meaning.
    /// </summary>
    public string? LayoutHint { get; init; }
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
    public const string SyntheticProjectManagerTerminalId =
        "synthetic-terminal-project-manager";

    private bool _suppressSelection;
    private string _sourceLabel = UiLanguageService.Shared["CoreWaitingSource"];
    private string _connectionLabel = UiLanguageService.Shared["CoreNotConnected"];
    private IReadOnlyList<OrganizationSummaryCard> _summaryCards = [];
    private IReadOnlyList<OrganizationNode> _nodes = [];
    private OrganizationNode? _selectedNode;
    private OrganizationAgentDetail _selectedAgent = EmptyDetail(
        isCoreConnected: false,
        isLive: false);
    private IReadOnlyList<OrganizationAttentionItem> _attentionItems = [];
    private string _hierarchyLabel = UiLanguageService.Shared["OrganizationNoTopology"];

    public event EventHandler<string>? AgentSelectionRequested;

    internal string ApplySyntheticPreview(
        string sourceLabel,
        string connectionLabel,
        string? selectedTerminalId)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(sourceLabel);
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionLabel);

        var text = UiLanguageService.Shared;
        var nodes = CreateSyntheticNodes(text);
        SourceLabel = sourceLabel;
        ConnectionLabel = connectionLabel;
        SummaryCards = CreateSyntheticSummaryCards(text, nodes);
        Nodes = nodes;
        HierarchyLabel = text["SyntheticSnapshot"];
        AttentionItems = CreateSyntheticAttentionItems(text);

        var selectedNode = selectedTerminalId is null
            ? null
            : nodes.FirstOrDefault(item =>
                string.Equals(item.AgentTerminalId, selectedTerminalId, StringComparison.Ordinal));
        selectedNode ??=
            nodes.First(item => item.AgentTerminalId == SyntheticProjectManagerTerminalId);
        _suppressSelection = true;
        try
        {
            SelectedNode = selectedNode;
        }
        finally
        {
            _suppressSelection = false;
        }

        SelectedAgent = CreateSyntheticDetail(selectedNode, text);
        return selectedNode.AgentTerminalId!;
    }

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
        bool isCoreConnected,
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
        var text = UiLanguageService.Shared;
        HierarchyLabel = state.LastIngestSequence == 0
            ? text["OrganizationNoTopology"]
            : text.Format(
                "OrganizationTopologyFormat",
                state.ConnectionEpoch,
                state.LastIngestSequence);
        AttentionItems = CreateAttentionItems(state, isCoreConnected, isLive);
        SelectWithoutRequest(state, isCoreConnected, isLive, selectedTerminalId);
    }

    private static IReadOnlyList<OrganizationSummaryCard> CreateSyntheticSummaryCards(
        UiLanguageService text,
        IReadOnlyList<OrganizationNode> nodes)
    {
        var agentCount = nodes.Count(item => item.IsAgent);
        return
        [
            new(
                text["OrganizationWorkspaces"],
                "1",
                text["SyntheticSnapshot"],
                "\uE8B7",
                Overview.OverviewBrushKeys.Primary),
            new(
                text["OrganizationTabs"],
                "6",
                text["OrganizationCurrentTopology"],
                "\uE7C5",
                Overview.OverviewBrushKeys.Working),
            new(
                text["OrganizationObservedAgents"],
                agentCount.ToString(System.Globalization.CultureInfo.InvariantCulture),
                text["SyntheticRoster"],
                "\uE716",
                Overview.OverviewBrushKeys.Working),
            new(
                text["OrganizationUnassignedPanes"],
                "2",
                text["OrganizationAttentionUnassignedDetail"],
                "\uE77B",
                Overview.OverviewBrushKeys.Idle),
            new(
                text["OrganizationUnknownStatus"],
                "1",
                text["DelegationDispositionIdentityConflict"],
                "\uE814",
                Overview.OverviewBrushKeys.Review),
        ];
    }

    private static IReadOnlyList<OrganizationNode> CreateSyntheticNodes(UiLanguageService text) =>
        ApplyHierarchyMetadata(
        [
        SyntheticAgent(
            "synthetic-project-manager",
            0,
            "PM",
            "Project Manager",
            text["DelegationRoleProjectManager"],
            "Working"),
        SyntheticAgent(
            "synthetic-pm-secretary",
            1,
            "PS",
            "PM Secretary",
            text["WidgetAgentSecretaryRole"],
            "Working",
            "assistant"),
        SyntheticAgent(
            "synthetic-backend-leader",
            1,
            "BL",
            "Backend Leader",
            text["DelegationRoleBackendLeader"],
            "Working"),
        SyntheticAgent(
            "synthetic-backend-worker-01",
            2,
            "BW",
            "Backend Worker 01",
            text["DelegationRoleBackendWorker"],
            "Working"),
        SyntheticAgent(
            "synthetic-backend-worker-02",
            2,
            "BW",
            "Backend Worker 02",
            text["DelegationRoleBackendWorker"],
            "Idle"),
        SyntheticAgent(
            "synthetic-backend-worker-03",
            2,
            "BW",
            "Backend Worker 03",
            text["DelegationRoleBackendWorker"],
            "Done"),
        SyntheticAgent(
            "synthetic-frontend-leader",
            1,
            "FL",
            "Frontend Leader",
            text["DelegationRoleFrontendLeader"],
            "Working"),
        SyntheticAgent(
            "synthetic-frontend-worker-01",
            2,
            "FW",
            "Frontend Worker 01",
            text["DelegationRoleFrontendWorker"],
            "Working"),
        SyntheticAgent(
            "synthetic-frontend-worker-02",
            2,
            "FW",
            "Frontend Worker 02",
            text["DelegationRoleFrontendWorker"],
            "Blocked"),
        SyntheticAgent(
            "synthetic-test-leader",
            1,
            "TL",
            "Test Leader",
            text["DelegationRoleTestLeader"],
            "Idle"),
        SyntheticAgent(
            "synthetic-test-worker-01",
            2,
            "TW",
            "Test Worker 01",
            text["DelegationRoleTestWorker"],
            "Working"),
        SyntheticAgent(
            "synthetic-test-worker-02",
            2,
            "TW",
            "Test Worker 02",
            text["DelegationRoleTestWorker"],
            "Done"),
        SyntheticAgent(
            "synthetic-devops-leader",
            1,
            "DL",
            "DevOps Leader",
            text["WidgetAgentLeaderRole"],
            "Blocked"),
        SyntheticAgent(
            "synthetic-devops-worker-01",
            2,
            "DW",
            "DevOps Worker 01",
            text["WidgetAgentWorkerRole"],
            "Idle"),
        SyntheticAgent(
            "synthetic-devops-worker-02",
            2,
            "DW",
            "DevOps Worker 02",
            text["WidgetAgentWorkerRole"],
            "Blocked"),
        new OrganizationNode(
            "synthetic-vacant-backend-worker-04",
            2,
            text["OrganizationUnassignedPaneType"],
            "!",
            SyntheticLabel("ตำแหน่งว่าง", "Vacant role"),
            SyntheticLabel("ผู้ปฏิบัติงานระบบเบื้องหลัง", "Backend worker slot"),
            SyntheticLabel("ว่าง", "Vacant"),
            Overview.OverviewBrushKeys.Idle,
            null)
        {
            ParentNodeId = "synthetic-backend-leader",
        },
        new OrganizationNode(
            "synthetic-vacant-devops-worker-03",
            2,
            text["OrganizationUnassignedPaneType"],
            "!",
            SyntheticLabel("ตำแหน่งว่าง", "Vacant role"),
            SyntheticLabel("ผู้ปฏิบัติงานส่งมอบระบบ", "DevOps worker slot"),
            SyntheticLabel("ว่าง", "Vacant"),
            Overview.OverviewBrushKeys.Idle,
            null)
        {
            ParentNodeId = "synthetic-devops-leader",
        },
        ],
        useSyntheticBands: true);

    private static OrganizationNode SyntheticAgent(
        string nodeId,
        int level,
        string initials,
        string name,
        string role,
        string status,
        string? layoutHint = null) => new(
        nodeId,
        level,
        role,
        initials,
        name,
        role,
        AgentStatusPresentation.DisplayStatus(status),
        AgentStatusPresentation.BrushKey(status),
        $"synthetic-terminal-{nodeId["synthetic-".Length..]}")
        {
            LayoutHint = layoutHint,
        };

    private static IReadOnlyList<OrganizationAttentionItem> CreateSyntheticAttentionItems(
        UiLanguageService text) =>
    [
        new(
            "\uEA39",
            text.Format("OrganizationAttentionBlockedFormat", 3),
            text["OrganizationAttentionBlockedDetail"],
            Overview.OverviewBrushKeys.Blocked),
        new(
            "\uE77B",
            text.Format("OrganizationAttentionUnassignedFormat", 2),
            text["OrganizationAttentionUnassignedDetail"],
            Overview.OverviewBrushKeys.Idle),
        new(
            "\uE711",
            text["DelegationDispositionIdentityConflict"],
            text["DelegationDispositionSequenceConflict"],
            Overview.OverviewBrushKeys.Review),
    ];

    private static OrganizationAgentDetail CreateSyntheticDetail(
        OrganizationNode node,
        UiLanguageService text) => new(
        node.Initials,
        node.Name,
        node.Initials == "PM" ? "PM" : node.NodeType,
        node.Status,
        node.AccentBrushKey,
        "MyAwesomeProject",
        "Project Management",
        node.AgentTerminalId is null
            ? text["ValueUnknown"]
            : $"synthetic-pane-{node.NodeId["synthetic-".Length..]}",
        node.AgentTerminalId ?? text["ValueUnknown"],
        "Z:\\HerdrOps\\synthetic-preview",
        "98",
        $"{text["SyntheticData"]} · {text["SyntheticProfile"]}");

    private static string SyntheticLabel(string thai, string english) =>
        UiLanguageService.Shared.CurrentLanguage == UiLanguage.Thai ? thai : english;

    internal void SelectAgent(
        HerdrSessionStateContract state,
        bool isCoreConnected,
        bool isLive,
        string? terminalId) =>
        SelectWithoutRequest(state, isCoreConnected, isLive, terminalId);

    private void SelectWithoutRequest(
        HerdrSessionStateContract state,
        bool isCoreConnected,
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
            ? EmptyDetail(isCoreConnected, isLive)
            : CreateDetail(state, agent, isCoreConnected, isLive);
    }

    private static IReadOnlyList<OrganizationSummaryCard> CreateSummaryCards(
        HerdrSessionStateContract state,
        bool isLive)
    {
        var text = UiLanguageService.Shared;
        var assignedTerminalIds = state.Agents
            .Select(agent => agent.TerminalId)
            .ToHashSet(StringComparer.Ordinal);
        var unassignedPanes = state.Panes.Count(pane => !assignedTerminalIds.Contains(pane.TerminalId));
        var unknown = state.Agents.Count(agent => agent.AgentStatus == "Unknown");
        return
        [
            new(text["OrganizationWorkspaces"], state.Workspaces.Count.ToString(), text["OrganizationObservedFromHerdr"], "\uE8B7", Overview.OverviewBrushKeys.Primary),
            new(text["OrganizationTabs"], state.Tabs.Count.ToString(), text["OrganizationCurrentTopology"], "\uE7C5", Overview.OverviewBrushKeys.Working),
            new(text["OrganizationObservedAgents"], state.Agents.Count.ToString(), isLive ? text["OrganizationLatestAcceptedCore"] : text["OrganizationLastKnownOnly"], "\uE716", isLive ? Overview.OverviewBrushKeys.Working : Overview.OverviewBrushKeys.Offline),
            new(text["OrganizationUnassignedPanes"], unassignedPanes.ToString(), text["OrganizationNoRoleInferred"], "\uE77B", unassignedPanes == 0 ? Overview.OverviewBrushKeys.Primary : Overview.OverviewBrushKeys.Idle),
            new(text["OrganizationUnknownStatus"], unknown.ToString(), text["OrganizationUnknownNeverHealthy"], "\uE814", unknown == 0 ? Overview.OverviewBrushKeys.Primary : Overview.OverviewBrushKeys.Offline),
        ];
    }

    private static IReadOnlyList<OrganizationNode> CreateNodes(
        HerdrSessionStateContract state,
        bool isLive)
    {
        var text = UiLanguageService.Shared;
        var nodes = new List<OrganizationNode>();
        foreach (var workspace in state.Workspaces.OrderBy(item => item.Number))
        {
            nodes.Add(new OrganizationNode(
                workspace.WorkspaceId,
                0,
                text["OrganizationWorkspaceType"],
                "WS",
                AgentStatusPresentation.FirstNonEmpty(workspace.Label, workspace.WorkspaceId),
                text.Format(
                    "OrganizationWorkspaceSubtitleFormat",
                    workspace.Number,
                    workspace.TabCount,
                    workspace.PaneCount),
                AgentStatusPresentation.DisplayStatus(
                    AgentStatusPresentation.EffectiveStatus(workspace.AgentStatus, isLive)),
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
                    text["OrganizationTabType"],
                    "TB",
                    AgentStatusPresentation.FirstNonEmpty(tab.Label, tab.TabId),
                    text.Format("OrganizationTabSubtitleFormat", tab.Number, tab.PaneCount),
                    AgentStatusPresentation.DisplayStatus(
                        AgentStatusPresentation.EffectiveStatus(tab.AgentStatus, isLive)),
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
                        text["OrganizationAgentType"],
                        AgentStatusPresentation.Initials(agent),
                        AgentStatusPresentation.DisplayName(agent),
                        $"{AgentStatusPresentation.RuntimeName(agent)} · {agent.PaneId}",
                        AgentStatusPresentation.DisplayStatus(effectiveStatus),
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
                        text["OrganizationUnassignedPaneType"],
                        "?",
                        text["OrganizationUnknownAgent"],
                        text.Format("OrganizationPaneTerminalFormat", pane.PaneId, pane.TerminalId),
                        AgentStatusPresentation.DisplayStatus(
                            isLive ? "Unknown" : AgentStatusPresentation.Offline),
                        Overview.OverviewBrushKeys.Offline,
                        null));
                }
            }
        }

        return ApplyHierarchyMetadata(nodes);
    }

    private static IReadOnlyList<OrganizationNode> ApplyHierarchyMetadata(
        IReadOnlyList<OrganizationNode> nodes,
        bool useSyntheticBands = false)
    {
        var lastByLevel = new Dictionary<int, OrganizationNode>();
        var result = new List<OrganizationNode>(nodes.Count);

        foreach (var node in nodes)
        {
            if (node.Level == 0)
            {
                lastByLevel.Clear();
            }
            else
            {
                foreach (var level in lastByLevel.Keys.Where(level => level >= node.Level).ToArray())
                {
                    lastByLevel.Remove(level);
                }
            }

            OrganizationNode? parent = null;
            for (var parentLevel = node.Level - 1; parentLevel >= 0; parentLevel--)
            {
                if (lastByLevel.TryGetValue(parentLevel, out parent))
                {
                    break;
                }
            }

            var layoutRow = node.Level;
            if (useSyntheticBands)
            {
                layoutRow = node.LayoutHint == "assistant"
                    ? 1
                    : node.Level == 0
                        ? 0
                        : node.Level == 1
                            ? 2
                            : 3;
            }

            var linked = node with
            {
                ParentNodeId = node.ParentNodeId ?? parent?.NodeId,
                LayoutRow = layoutRow,
            };
            result.Add(linked);
            lastByLevel[node.Level] = linked;
        }

        return result;
    }

    private static OrganizationAgentDetail CreateDetail(
        HerdrSessionStateContract state,
        HerdrAgentStateContract agent,
        bool isCoreConnected,
        bool isLive)
    {
        var workspace = state.Workspaces.FirstOrDefault(item => item.WorkspaceId == agent.WorkspaceId);
        var tab = state.Tabs.FirstOrDefault(item => item.TabId == agent.TabId);
        var effectiveStatus = AgentStatusPresentation.EffectiveStatus(agent.AgentStatus, isLive);
        return new OrganizationAgentDetail(
            AgentStatusPresentation.Initials(agent),
            AgentStatusPresentation.DisplayName(agent),
            AgentStatusPresentation.RuntimeName(agent),
            AgentStatusPresentation.DisplayStatus(effectiveStatus),
            AgentStatusPresentation.BrushKey(effectiveStatus),
            AgentStatusPresentation.FirstNonEmpty(workspace?.Label, agent.WorkspaceId),
            AgentStatusPresentation.FirstNonEmpty(tab?.Label, agent.TabId),
            agent.PaneId,
            agent.TerminalId,
            AgentStatusPresentation.FirstNonEmpty(
                agent.ForegroundCurrentDirectory,
                agent.CurrentDirectory,
                UiLanguageService.Shared["ValueUnknown"]),
            agent.Revision.ToString(System.Globalization.CultureInfo.InvariantCulture),
            isLive
                ? UiLanguageService.Shared["OrganizationDetailSourceLive"]
                : isCoreConnected
                    ? UiLanguageService.Shared["OrganizationDetailSourceHerdrInterrupted"]
                    : UiLanguageService.Shared["OrganizationDetailSourceOffline"]);
    }

    private static OrganizationAgentDetail EmptyDetail(bool isCoreConnected, bool isLive) => new(
        "?",
        UiLanguageService.Shared["NoAgentSelected"],
        UiLanguageService.Shared["UnknownRuntime"],
        AgentStatusPresentation.DisplayStatus(isLive ? "Unknown" : AgentStatusPresentation.Offline),
        Overview.OverviewBrushKeys.Offline,
        UiLanguageService.Shared["ValueUnknown"],
        UiLanguageService.Shared["ValueUnknown"],
        UiLanguageService.Shared["ValueUnknown"],
        UiLanguageService.Shared["ValueUnknown"],
        UiLanguageService.Shared["ValueUnknown"],
        "—",
        isLive
            ? UiLanguageService.Shared["OrganizationSelectAgent"]
            : isCoreConnected
                ? UiLanguageService.Shared["LiveWidgetHerdrInterruptedNotice"]
                : UiLanguageService.Shared["LiveWidgetCoreOfflineNotice"]);

    private static IReadOnlyList<OrganizationAttentionItem> CreateAttentionItems(
        HerdrSessionStateContract state,
        bool isCoreConnected,
        bool isLive)
    {
        var text = UiLanguageService.Shared;
        var result = new List<OrganizationAttentionItem>();
        if (!isCoreConnected)
        {
            result.Add(new OrganizationAttentionItem(
                "\uE711",
                text["OrganizationAttentionCoreOfflineTitle"],
                text["OrganizationAttentionCoreOfflineDetail"],
                Overview.OverviewBrushKeys.Offline));
        }
        else if (!isLive)
        {
            result.Add(new OrganizationAttentionItem(
                "\uE895",
                text["OrganizationAttentionHerdrInterruptedTitle"],
                text["OrganizationAttentionHerdrInterruptedDetail"],
                Overview.OverviewBrushKeys.Idle));
        }

        if (!isLive)
        {
            return result;
        }

        var blocked = state.Agents.Count(agent => agent.AgentStatus == "Blocked");
        if (blocked > 0)
        {
            result.Add(new OrganizationAttentionItem(
                "\uEA39",
                text.Format("OrganizationAttentionBlockedFormat", blocked),
                text["OrganizationAttentionBlockedDetail"],
                Overview.OverviewBrushKeys.Blocked));
        }

        var unknown = state.Agents.Count(agent => agent.AgentStatus == "Unknown");
        if (unknown > 0 || state.LastIngestSequence == 0)
        {
            result.Add(new OrganizationAttentionItem(
                "\uE814",
                state.LastIngestSequence == 0
                    ? text["OrganizationAttentionNoSnapshot"]
                    : text.Format("OrganizationAttentionUnknownFormat", unknown),
                text["OrganizationAttentionUnknownDetail"],
                Overview.OverviewBrushKeys.Offline));
        }

        var assignedPaneIds = state.Agents.Select(agent => agent.PaneId).ToHashSet(StringComparer.Ordinal);
        var unassigned = state.Panes.Count(pane => !assignedPaneIds.Contains(pane.PaneId));
        if (unassigned > 0)
        {
            result.Add(new OrganizationAttentionItem(
                "\uE77B",
                text.Format("OrganizationAttentionUnassignedFormat", unassigned),
                text["OrganizationAttentionUnassignedDetail"],
                Overview.OverviewBrushKeys.Idle));
        }

        return result;
    }
}
