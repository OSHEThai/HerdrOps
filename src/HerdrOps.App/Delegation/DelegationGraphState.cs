using System.Security.Cryptography;
using System.Text;
using HerdrOps.App.Live;
using HerdrOps.App.Localization;
using HerdrOps.App.Overview;
using HerdrOps.Domain.Assignments;

namespace HerdrOps.App.Delegation;

public sealed record DelegationSummaryCard(
    string Title,
    string Value,
    string Detail,
    string IconGlyph,
    string AccentBrushKey);

public sealed record DelegationTaskTreeItem(
    string ItemId,
    int Level,
    string Title,
    string Subtitle,
    string Count,
    string AccentBrushKey,
    string? TaskId)
{
    public double IndentWidth => Level * 18d;

    public bool IsTask => TaskId is not null;
}

public sealed record DelegationGraphNodeItem(
    string ActorId,
    string Initials,
    string Name,
    string Role,
    string Status,
    string StatusBrushKey,
    string TaskCount,
    double X,
    double Y,
    double Opacity,
    string AutomationName);

public sealed record DelegationGraphEdgeItem(
    string EdgeId,
    string FromActorId,
    string ToActorId,
    string Relationship,
    string TaskId,
    double X1,
    double Y1,
    double X2,
    double Y2,
    double LabelX,
    double LabelY,
    double Opacity,
    string AccentBrushKey,
    string AutomationName);

public sealed record DelegationTimelineItem(
    string EventId,
    string Time,
    string Kind,
    string Actor,
    string Target,
    string TaskId,
    string Summary,
    string Disposition,
    string AccentBrushKey,
    string Provenance);

public sealed record DelegationNodeDetail(
    string ActorId,
    string Initials,
    string Name,
    string Role,
    string Status,
    string StatusBrushKey,
    string TaskCount,
    string CurrentTask,
    string AssignmentSummary,
    string Progress,
    string LastObserved,
    string LastHandoff,
    string Provenance,
    IReadOnlyList<string> TaskIds);

public sealed record DelegationAccessibleItem(
    string ActorId,
    string Name,
    string Description,
    string Status,
    string StatusBrushKey);

public sealed class DelegationGraphState : ObservableState
{
    public const double GraphWidth = 920;
    public const double GraphHeight = 500;
    public const double NodeWidth = 150;
    public const double NodeHeight = 78;

    private AssignmentDelegationGraph? _graph;
    private string _projectLabel = UiLanguageService.Shared["DelegationNoProject"];
    private string _sourceLabel = UiLanguageService.Shared["DelegationWaitingSource"];
    private string _evidenceBoundary = UiLanguageService.Shared["DelegationUnavailableBoundary"];
    private IReadOnlyList<DelegationSummaryCard> _summaryCards = [];
    private IReadOnlyList<DelegationTaskTreeItem> _taskTreeItems = [];
    private IReadOnlyList<DelegationGraphNodeItem> _graphNodes = [];
    private IReadOnlyList<DelegationGraphEdgeItem> _graphEdges = [];
    private IReadOnlyList<DelegationTimelineItem> _timeline = [];
    private IReadOnlyList<DelegationAccessibleItem> _accessibleItems = [];
    private DelegationTaskTreeItem? _selectedTask;
    private DelegationGraphNodeItem? _selectedNode;
    private DelegationAccessibleItem? _selectedAccessibleItem;
    private DelegationNodeDetail _selectedDetail = EmptyDetail();
    private bool _isAccessibleView;
    private bool _suppressSelection;
    private string? _sourceLocalizationKey;
    private string? _boundaryLocalizationKey;

    public string ProjectLabel { get => _projectLabel; private set => Set(ref _projectLabel, value); }

    public string SourceLabel { get => _sourceLabel; private set => Set(ref _sourceLabel, value); }

    public string EvidenceBoundary
    {
        get => _evidenceBoundary;
        private set => Set(ref _evidenceBoundary, value);
    }

    public IReadOnlyList<DelegationSummaryCard> SummaryCards
    {
        get => _summaryCards;
        private set => Set(ref _summaryCards, value);
    }

    public IReadOnlyList<DelegationTaskTreeItem> TaskTreeItems
    {
        get => _taskTreeItems;
        private set => Set(ref _taskTreeItems, value);
    }

    public IReadOnlyList<DelegationGraphNodeItem> GraphNodes
    {
        get => _graphNodes;
        private set => Set(ref _graphNodes, value);
    }

    public IReadOnlyList<DelegationGraphEdgeItem> GraphEdges
    {
        get => _graphEdges;
        private set => Set(ref _graphEdges, value);
    }

    public IReadOnlyList<DelegationTimelineItem> Timeline
    {
        get => _timeline;
        private set => Set(ref _timeline, value);
    }

    public IReadOnlyList<DelegationAccessibleItem> AccessibleItems
    {
        get => _accessibleItems;
        private set => Set(ref _accessibleItems, value);
    }

    public DelegationTaskTreeItem? SelectedTask
    {
        get => _selectedTask;
        set
        {
            if (!Set(ref _selectedTask, value) || _suppressSelection)
            {
                return;
            }

            RefreshProjection(preferredActorId: SelectedNode?.ActorId);
        }
    }

    public DelegationGraphNodeItem? SelectedNode
    {
        get => _selectedNode;
        set
        {
            if (!Set(ref _selectedNode, value) || _suppressSelection)
            {
                return;
            }

            ApplyNodeSelection(value?.ActorId);
        }
    }

    public DelegationAccessibleItem? SelectedAccessibleItem
    {
        get => _selectedAccessibleItem;
        set
        {
            if (!Set(ref _selectedAccessibleItem, value) || _suppressSelection)
            {
                return;
            }

            ApplyNodeSelection(value?.ActorId);
        }
    }

    public DelegationNodeDetail SelectedDetail
    {
        get => _selectedDetail;
        private set => Set(ref _selectedDetail, value);
    }

    public bool IsAccessibleView
    {
        get => _isAccessibleView;
        set => Set(ref _isAccessibleView, value);
    }

    public bool HasGraph => _graph is not null;

    public static DelegationGraphState CreateSyntheticPreview()
    {
        var state = new DelegationGraphState();
        state.ApplyGraph(
            AssignmentDelegationGraphProjector.Create(
                AssignmentLifecycleReplay.Run(CreateSyntheticEvents())),
            "HerdrOps",
            UiLanguageService.Shared["DelegationSyntheticSource"],
            UiLanguageService.Shared["DelegationSyntheticBoundary"]);
        state._sourceLocalizationKey = "DelegationSyntheticSource";
        state._boundaryLocalizationKey = "DelegationSyntheticBoundary";
        return state;
    }

    public void ApplyGraph(
        AssignmentDelegationGraph graph,
        string projectLabel,
        string sourceLabel,
        string evidenceBoundary)
    {
        ArgumentNullException.ThrowIfNull(graph);
        ArgumentException.ThrowIfNullOrWhiteSpace(projectLabel);
        ArgumentException.ThrowIfNullOrWhiteSpace(sourceLabel);
        ArgumentException.ThrowIfNullOrWhiteSpace(evidenceBoundary);
        _graph = graph;
        _sourceLocalizationKey = null;
        _boundaryLocalizationKey = null;
        ProjectLabel = projectLabel;
        SourceLabel = sourceLabel;
        EvidenceBoundary = evidenceBoundary;
        Raise(nameof(HasGraph));
        RefreshProjection(preferredActorId: null);
    }

    public void MarkUnavailable(string projectLabel, string sourceLabel, string evidenceBoundary)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(projectLabel);
        ArgumentException.ThrowIfNullOrWhiteSpace(sourceLabel);
        ArgumentException.ThrowIfNullOrWhiteSpace(evidenceBoundary);
        _graph = null;
        _sourceLocalizationKey = null;
        _boundaryLocalizationKey = null;
        ProjectLabel = projectLabel;
        SourceLabel = sourceLabel;
        EvidenceBoundary = evidenceBoundary;
        Raise(nameof(HasGraph));
        RefreshProjection(preferredActorId: null);
    }

    public void MarkUnavailableFromCatalog(
        string projectLabel,
        string sourceLocalizationKey,
        string boundaryLocalizationKey)
    {
        MarkUnavailable(
            projectLabel,
            UiLanguageService.Shared[sourceLocalizationKey],
            UiLanguageService.Shared[boundaryLocalizationKey]);
        _sourceLocalizationKey = sourceLocalizationKey;
        _boundaryLocalizationKey = boundaryLocalizationKey;
    }

    public void RefreshLanguage()
    {
        if (_sourceLocalizationKey is { } sourceKey)
        {
            SourceLabel = UiLanguageService.Shared[sourceKey];
        }

        if (_boundaryLocalizationKey is { } boundaryKey)
        {
            EvidenceBoundary = UiLanguageService.Shared[boundaryKey];
        }

        RefreshProjection(SelectedNode?.ActorId);
    }

    private void RefreshProjection(string? preferredActorId)
    {
        var graph = _graph;
        if (graph is null)
        {
            SummaryCards = EmptySummaryCards();
            TaskTreeItems = [];
            GraphNodes = [];
            GraphEdges = [];
            Timeline = [];
            AccessibleItems = [];
            SetSelections(null, null, null);
            SelectedDetail = EmptyDetail();
            return;
        }

        var selectedTaskId = SelectedTask?.TaskId;
        SummaryCards = CreateSummaryCards(graph);
        TaskTreeItems = CreateTaskTree(graph, ProjectLabel);
        var selectedTask = selectedTaskId is null
            ? TaskTreeItems.FirstOrDefault()
            : TaskTreeItems.FirstOrDefault(item =>
                string.Equals(item.TaskId, selectedTaskId, StringComparison.Ordinal));
        var layout = CreateLayout(graph);
        var initialNodes = CreateGraphNodes(graph, layout, selectedTask?.TaskId);
        var initialEdges = CreateGraphEdges(graph, layout, selectedTask?.TaskId);
        var initialTimeline = CreateTimeline(graph, selectedTask?.TaskId);
        var selectedNode = preferredActorId is null
            ? initialNodes.FirstOrDefault(item => item.Opacity >= 1d) ?? initialNodes.FirstOrDefault()
            : initialNodes.FirstOrDefault(item =>
                string.Equals(item.ActorId, preferredActorId, StringComparison.Ordinal));
        var resolvedSelectedTaskId = ResolveSelection(
            graph!,
            selectedNode?.ActorId,
            selectedTask?.TaskId,
            TaskTreeItems);
        var projectedNodes = resolvedSelectedTaskId == selectedTask?.TaskId
            ? initialNodes
            : CreateGraphNodes(graph, layout, resolvedSelectedTaskId);
        var projectedEdges = resolvedSelectedTaskId == selectedTask?.TaskId
            ? initialEdges
            : CreateGraphEdges(graph, layout, resolvedSelectedTaskId);
        var projectedTimeline = resolvedSelectedTaskId == selectedTask?.TaskId
            ? initialTimeline
            : CreateTimeline(graph, resolvedSelectedTaskId);
        if (resolvedSelectedTaskId != selectedTask?.TaskId && selectedNode is not null)
        {
            selectedNode = preferredActorId is null
                ? projectedNodes.FirstOrDefault(item => item.Opacity >= 1d) ?? projectedNodes.FirstOrDefault()
                : projectedNodes.FirstOrDefault(item =>
                    string.Equals(item.ActorId, preferredActorId, StringComparison.Ordinal));
        }
        GraphNodes = projectedNodes;
        GraphEdges = projectedEdges;
        Timeline = projectedTimeline;
        AccessibleItems = CreateAccessibleItems(GraphNodes, GraphEdges);
        selectedTask = resolvedSelectedTaskId is null
            ? null
            : TaskTreeItems.FirstOrDefault(item =>
                string.Equals(item.TaskId, resolvedSelectedTaskId, StringComparison.Ordinal));
        var selectedAccessible = selectedNode is null
            ? null
            : AccessibleItems.FirstOrDefault(item =>
                string.Equals(item.ActorId, selectedNode.ActorId, StringComparison.Ordinal));
        SetSelections(selectedTask, selectedNode, selectedAccessible);
        SelectedDetail = selectedNode is null
            ? EmptyDetail()
            : CreateDetail(graph, selectedNode.ActorId, selectedTask?.TaskId);
    }

    private void ApplyNodeSelection(string? actorId)
    {
        var node = actorId is null
            ? null
            : GraphNodes.FirstOrDefault(item =>
                string.Equals(item.ActorId, actorId, StringComparison.Ordinal));
        var accessible = actorId is null
            ? null
            : AccessibleItems.FirstOrDefault(item =>
                string.Equals(item.ActorId, actorId, StringComparison.Ordinal));
        if (node is null || _graph is null)
        {
            SelectedDetail = EmptyDetail();
            return;
        }

        var graph = _graph;
        var resolvedSelectedTaskId = ResolveSelection(
            graph,
            actorId,
            SelectedTask?.TaskId,
            TaskTreeItems);
        SetSelections(
            resolvedSelectedTaskId is null
                ? null
                : TaskTreeItems.SingleOrDefault(item =>
                    string.Equals(item.TaskId, resolvedSelectedTaskId, StringComparison.Ordinal)),
            node,
            accessible);

        RefreshProjection(actorId);
    }

    private void SetSelections(
        DelegationTaskTreeItem? task,
        DelegationGraphNodeItem? node,
        DelegationAccessibleItem? accessible)
    {
        _suppressSelection = true;
        try
        {
            SelectedTask = task;
            SelectedNode = node;
            SelectedAccessibleItem = accessible;
        }
        finally
        {
            _suppressSelection = false;
        }
    }

    private static IReadOnlyList<DelegationSummaryCard> CreateSummaryCards(
        AssignmentDelegationGraph graph)
    {
        var text = UiLanguageService.Shared;
        var delegatedTasks = graph.Edges
            .Where(item => item.RelationshipKind == AssignmentRelationshipKind.Delegation)
            .Select(item => item.TaskId)
            .Distinct(StringComparer.Ordinal)
            .Count();
        var activeTasks = graph.Tasks.Count(item => item.Status is
            AssignmentTaskStatus.Acknowledged or
            AssignmentTaskStatus.InProgress);
        var blockedTasks = graph.Tasks.Count(item =>
            item.Status == AssignmentTaskStatus.DeviationReported);
        var reviewTasks = graph.Tasks.Count(item => item.Status is
            AssignmentTaskStatus.EvidenceSubmitted or
            AssignmentTaskStatus.HandedOff);
        var findings = graph.Diagnostics.OrphanEventCount +
                       graph.Diagnostics.DuplicateHandoffCount +
                       graph.Diagnostics.InvalidTransitionCount;
        return
        [
            new(text["DelegationTotalTasks"], graph.Tasks.Count.ToString(), text["DelegationCurrentProjection"], "\uE8B7", OverviewBrushKeys.Primary),
            new(text["DelegationDelegatedTasks"], delegatedTasks.ToString(), text["DelegationTypedEdges"], "\uE8FA", OverviewBrushKeys.Primary),
            new(text["DelegationActiveTasks"], activeTasks.ToString(), text["DelegationAcknowledgedOrProgress"], "\uE95E", OverviewBrushKeys.Working),
            new(text["DelegationBlockedTasks"], blockedTasks.ToString(), text["DelegationDeviationReported"], "\uEA39", OverviewBrushKeys.Blocked),
            new(text["DelegationReviewTasks"], reviewTasks.ToString(), findings == 0 ? text["DelegationNoAuditFindings"] : text.Format("DelegationAuditFindingsFormat", findings), "\uE8D4", OverviewBrushKeys.Review),
        ];
    }

    private static IReadOnlyList<DelegationSummaryCard> EmptySummaryCards()
    {
        var text = UiLanguageService.Shared;
        return
        [
            new(text["DelegationTotalTasks"], "—", text["DelegationWaitingForLifecycle"], "\uE8B7", OverviewBrushKeys.Offline),
            new(text["DelegationDelegatedTasks"], "—", text["DelegationWaitingForLifecycle"], "\uE8FA", OverviewBrushKeys.Offline),
            new(text["DelegationActiveTasks"], "—", text["DelegationWaitingForLifecycle"], "\uE95E", OverviewBrushKeys.Offline),
            new(text["DelegationBlockedTasks"], "—", text["DelegationWaitingForLifecycle"], "\uEA39", OverviewBrushKeys.Offline),
            new(text["DelegationReviewTasks"], "—", text["DelegationWaitingForLifecycle"], "\uE8D4", OverviewBrushKeys.Offline),
        ];
    }

    private static DelegationTaskTreeItem[] CreateTaskTree(
        AssignmentDelegationGraph graph,
        string projectLabel)
    {
        var items = new List<DelegationTaskTreeItem>
        {
            new(
                "project-root",
                0,
                projectLabel,
                UiLanguageService.Shared["DelegationTaskTreeProject"],
                graph.Tasks.Count.ToString(),
                OverviewBrushKeys.Primary,
                null),
        };
        items.AddRange(graph.Tasks.Select(task => new DelegationTaskTreeItem(
            $"task-{task.TaskId}",
            1,
            task.TaskId,
            DisplaySummary(task.Summary, task.TaskId, AssignmentLifecycleEventKind.Assignment),
            $"{task.ProgressPercent}%",
            BrushKey(MapStatus(task.Status)),
            task.TaskId)));
        return items.ToArray();
    }

    private static IReadOnlyDictionary<string, (double X, double Y)> CreateLayout(
        AssignmentDelegationGraph graph)
    {
        var incoming = graph.Nodes.ToDictionary(item => item.ActorId, _ => 0, StringComparer.Ordinal);
        var outgoing = graph.Nodes.ToDictionary(
            item => item.ActorId,
            _ => new List<string>(),
            StringComparer.Ordinal);
        foreach (var edge in graph.Edges)
        {
            if (!incoming.ContainsKey(edge.ToActorId) || !outgoing.ContainsKey(edge.FromActorId))
            {
                continue;
            }

            incoming[edge.ToActorId]++;
            outgoing[edge.FromActorId].Add(edge.ToActorId);
        }

        var levels = new Dictionary<string, int>(StringComparer.Ordinal);
        var queue = new Queue<string>(incoming
            .Where(item => item.Value == 0)
            .Select(item => item.Key)
            .Order(StringComparer.Ordinal));
        foreach (var root in queue)
        {
            levels[root] = 0;
        }

        while (queue.Count > 0)
        {
            var actorId = queue.Dequeue();
            var nextLevel = Math.Min(levels[actorId] + 1, 3);
            foreach (var target in outgoing[actorId].Distinct(StringComparer.Ordinal))
            {
                if (!levels.TryGetValue(target, out var currentLevel) || nextLevel > currentLevel)
                {
                    levels[target] = nextLevel;
                }

                incoming[target]--;
                if (incoming[target] == 0)
                {
                    queue.Enqueue(target);
                }
            }
        }

        var fallbackLevel = levels.Count == 0 ? 0 : Math.Min(levels.Values.Max() + 1, 3);
        foreach (var node in graph.Nodes)
        {
            levels.TryAdd(node.ActorId, fallbackLevel);
        }

        var result = new Dictionary<string, (double X, double Y)>(StringComparer.Ordinal);
        foreach (var group in levels
                     .GroupBy(item => item.Value)
                     .OrderBy(item => item.Key))
        {
            var actorIds = group
                .Select(item => item.Key)
                .Order(StringComparer.Ordinal)
                .ToArray();
            var availableWidth = GraphWidth - 80d;
            var slotWidth = availableWidth / Math.Max(actorIds.Length, 1);
            for (var index = 0; index < actorIds.Length; index++)
            {
                var x = 40d + (slotWidth * index) + ((slotWidth - NodeWidth) / 2d);
                var y = 42d + (group.Key * 112d);
                result[actorIds[index]] = (x, y);
            }
        }

        return result;
    }

    private static DelegationGraphNodeItem[] CreateGraphNodes(
        AssignmentDelegationGraph graph,
        IReadOnlyDictionary<string, (double X, double Y)> layout,
        string? selectedTaskId)
    {
        return graph.Nodes
            .Select(node =>
            {
                var status = ResolveNodeStatus(graph, node.ActorId);
                var taskCount = node.TaskIds.Count;
                var related = selectedTaskId is null || node.TaskIds.Contains(selectedTaskId, StringComparer.Ordinal);
                var position = layout[node.ActorId];
                var name = DisplayActor(node.ActorId);
                var role = DisplayRole(node.ActorRole);
                var statusLabel = DisplayStatus(status);
                return new DelegationGraphNodeItem(
                    node.ActorId,
                    Initials(name),
                    name,
                    role,
                    statusLabel,
                    BrushKey(status),
                    UiLanguageService.Shared.Format("DelegationTaskCountFormat", taskCount),
                    position.X,
                    position.Y,
                    related ? 1d : 0.34d,
                    UiLanguageService.Shared.Format(
                        "DelegationNodeAutomationFormat",
                        name,
                        role,
                        statusLabel,
                        taskCount));
            })
            .OrderBy(item => item.Y)
            .ThenBy(item => item.X)
            .ToArray();
    }

    private static DelegationGraphEdgeItem[] CreateGraphEdges(
        AssignmentDelegationGraph graph,
        IReadOnlyDictionary<string, (double X, double Y)> layout,
        string? selectedTaskId)
    {
        return graph.Edges
            .Where(edge => layout.ContainsKey(edge.FromActorId) && layout.ContainsKey(edge.ToActorId))
            .Select(edge =>
            {
                var from = layout[edge.FromActorId];
                var to = layout[edge.ToActorId];
                var relationship = DisplayRelationship(edge.RelationshipKind);
                var related = selectedTaskId is null ||
                              string.Equals(edge.TaskId, selectedTaskId, StringComparison.Ordinal);
                var x1 = from.X + (NodeWidth / 2d);
                var y1 = from.Y + NodeHeight;
                var x2 = to.X + (NodeWidth / 2d);
                var y2 = to.Y;
                return new DelegationGraphEdgeItem(
                    edge.RelationshipId.ToString("D"),
                    edge.FromActorId,
                    edge.ToActorId,
                    relationship,
                    edge.TaskId,
                    x1,
                    y1,
                    x2,
                    y2,
                    ((x1 + x2) / 2d) - 42d,
                    ((y1 + y2) / 2d) - 9d,
                    related ? 0.9d : 0.18d,
                    edge.RelationshipKind == AssignmentRelationshipKind.Handoff
                        ? OverviewBrushKeys.Review
                        : OverviewBrushKeys.Primary,
                    UiLanguageService.Shared.Format(
                        "DelegationEdgeAutomationFormat",
                        DisplayActor(edge.FromActorId),
                        relationship,
                        DisplayActor(edge.ToActorId),
                        edge.TaskId));
            })
            .ToArray();
    }

    private static DelegationTimelineItem[] CreateTimeline(
        AssignmentDelegationGraph graph,
        string? selectedTaskId)
    {
        return graph.Timeline
            .Where(item => selectedTaskId is null ||
                           string.Equals(item.TaskId, selectedTaskId, StringComparison.Ordinal))
            .OrderByDescending(item => item.Sequence)
            .Take(12)
            .Select(item => new DelegationTimelineItem(
                item.EventId.ToString("D"),
                item.AcceptedUtc.ToLocalTime().ToString("HH:mm:ss", System.Globalization.CultureInfo.InvariantCulture),
                DisplayEventKind(item.EventKind),
                DisplayActor(item.ActorId),
                item.TargetAgentId is null ? "—" : DisplayActor(item.TargetAgentId),
                item.TaskId,
                DisplaySummary(item.Summary, item.TaskId, item.EventKind),
                DisplayDisposition(item.Disposition),
                item.Disposition == AssignmentLifecycleDisposition.Applied
                    ? EventBrushKey(item.EventKind)
                    : OverviewBrushKeys.Blocked,
                item.LifecycleEventSha256))
            .ToArray();
    }

    private static DelegationAccessibleItem[] CreateAccessibleItems(
        IReadOnlyList<DelegationGraphNodeItem> nodes,
        IReadOnlyList<DelegationGraphEdgeItem> edges)
    {
        return nodes.Select(node =>
        {
            var outgoing = edges
                .Where(edge => string.Equals(edge.FromActorId, node.ActorId, StringComparison.Ordinal))
                .Select(edge => $"{edge.Relationship} → {DisplayActor(edge.ToActorId)} ({edge.TaskId})")
                .ToArray();
            var incoming = edges
                .Where(edge => string.Equals(edge.ToActorId, node.ActorId, StringComparison.Ordinal))
                .Select(edge => $"{edge.Relationship} ← {DisplayActor(edge.FromActorId)} ({edge.TaskId})")
                .ToArray();
            var relationships = incoming.Concat(outgoing).ToArray();
            var description = relationships.Length == 0
                ? UiLanguageService.Shared["DelegationNoRelationships"]
                : string.Join(" · ", relationships);
            return new DelegationAccessibleItem(
                node.ActorId,
                node.Name,
                $"{node.Role} · {node.TaskCount} · {description}",
                node.Status,
                node.StatusBrushKey);
        }).ToArray();
    }

    private static DelegationNodeDetail CreateDetail(
        AssignmentDelegationGraph graph,
        string actorId,
        string? selectedTaskId)
    {
        var node = graph.Nodes.Single(item =>
            string.Equals(item.ActorId, actorId, StringComparison.Ordinal));
        var status = ResolveNodeStatus(graph, actorId);
        var currentTask = graph.Tasks.FirstOrDefault(item =>
            string.Equals(item.CurrentAssigneeId, actorId, StringComparison.Ordinal));
        var task = selectedTaskId is null
            ? graph.Tasks.FirstOrDefault(item =>
                string.Equals(item.CurrentAssigneeId, actorId, StringComparison.Ordinal)) ??
              graph.Tasks.FirstOrDefault(item => node.TaskIds.Contains(item.TaskId, StringComparer.Ordinal))
            : graph.Tasks.FirstOrDefault(item =>
                string.Equals(item.TaskId, selectedTaskId, StringComparison.Ordinal));
        var handoff = graph.Timeline
            .Where(item => item.EventKind == AssignmentLifecycleEventKind.Handoff &&
                           (string.Equals(item.ActorId, actorId, StringComparison.Ordinal) ||
                            string.Equals(item.TargetAgentId, actorId, StringComparison.Ordinal)))
            .OrderByDescending(item => item.Sequence)
            .FirstOrDefault();
        var name = DisplayActor(actorId);
        return new DelegationNodeDetail(
            actorId,
            Initials(name),
            name,
            DisplayRole(node.ActorRole),
            DisplayStatus(status),
            BrushKey(status),
            UiLanguageService.Shared.Format("DelegationTaskCountFormat", node.TaskIds.Count),
            currentTask?.TaskId ?? "—",
            task is null
                ? UiLanguageService.Shared["DelegationNoAssignmentSummary"]
                : DisplaySummary(
                    task.Summary,
                    task.TaskId,
                    AssignmentLifecycleEventKind.Assignment),
            currentTask is null ? "—" : $"{currentTask.ProgressPercent}%",
            node.LastObservedUtc.ToLocalTime().ToString("dd MMM yyyy HH:mm:ss", System.Globalization.CultureInfo.CurrentUICulture),
            handoff is null
                ? UiLanguageService.Shared["DelegationNoHandoff"]
                : DisplaySummary(handoff.Summary, handoff.TaskId, handoff.EventKind),
            node.ProvenanceEventSha256,
            node.TaskIds);
    }

    private static DelegationNodeDetail EmptyDetail() => new(
        "—",
        "?",
        UiLanguageService.Shared["DelegationNoNodeSelected"],
        UiLanguageService.Shared["ValueUnknown"],
        UiLanguageService.Shared["StatusOffline"],
        OverviewBrushKeys.Offline,
        UiLanguageService.Shared.Format("DelegationTaskCountFormat", 0),
        "—",
        UiLanguageService.Shared["DelegationNoAssignmentSummary"],
        "—",
        "—",
        UiLanguageService.Shared["DelegationNoHandoff"],
        "—",
        []);

    private static string ResolveNodeStatus(
        AssignmentDelegationGraph graph,
        string actorId)
    {
        var currentTasks = graph.Tasks
            .Where(item => string.Equals(item.CurrentAssigneeId, actorId, StringComparison.Ordinal))
            .ToArray();
        if (currentTasks.Any(item => item.Status == AssignmentTaskStatus.DeviationReported))
        {
            return "Blocked";
        }

        if (currentTasks.Any(item => item.Status is
                AssignmentTaskStatus.EvidenceSubmitted or
                AssignmentTaskStatus.HandedOff))
        {
            return "Review";
        }

        if (currentTasks.Any(item => item.Status is
                AssignmentTaskStatus.Acknowledged or
                AssignmentTaskStatus.InProgress))
        {
            return "Working";
        }

        if (currentTasks.Length > 0)
        {
            return "Idle";
        }

        return graph.Edges.Any(item =>
            string.Equals(item.FromActorId, actorId, StringComparison.Ordinal) ||
            string.Equals(item.ToActorId, actorId, StringComparison.Ordinal))
            ? "Done"
            : "Offline";
    }

    private static string DisplayStatus(string status) => status switch
    {
        "Working" => UiLanguageService.Shared["StatusWorking"],
        "Idle" => UiLanguageService.Shared["StatusIdle"],
        "Blocked" => UiLanguageService.Shared["StatusBlocked"],
        "Review" => UiLanguageService.Shared["StatusReview"],
        "Done" => UiLanguageService.Shared["StatusDone"],
        _ => UiLanguageService.Shared["StatusOffline"],
    };

    private static string BrushKey(string status) => status switch
    {
        "Working" => OverviewBrushKeys.Working,
        "Idle" => OverviewBrushKeys.Idle,
        "Blocked" => OverviewBrushKeys.Blocked,
        "Review" => OverviewBrushKeys.Review,
        "Done" => OverviewBrushKeys.Primary,
        _ => OverviewBrushKeys.Offline,
    };

    private static string MapStatus(AssignmentTaskStatus status) => status switch
    {
        AssignmentTaskStatus.DeviationReported => "Blocked",
        AssignmentTaskStatus.EvidenceSubmitted or AssignmentTaskStatus.HandedOff => "Review",
        AssignmentTaskStatus.Acknowledged or AssignmentTaskStatus.InProgress => "Working",
        AssignmentTaskStatus.Assigned or AssignmentTaskStatus.Delegated => "Idle",
        _ => "Offline",
    };

    private static string EventBrushKey(AssignmentLifecycleEventKind kind) => kind switch
    {
        AssignmentLifecycleEventKind.Deviation => OverviewBrushKeys.Blocked,
        AssignmentLifecycleEventKind.Evidence or AssignmentLifecycleEventKind.Handoff => OverviewBrushKeys.Review,
        AssignmentLifecycleEventKind.Progress or AssignmentLifecycleEventKind.Acknowledgement => OverviewBrushKeys.Working,
        _ => OverviewBrushKeys.Primary,
    };

    private static string DisplayRelationship(AssignmentRelationshipKind kind) =>
        UiLanguageService.Shared[$"DelegationRelationship{kind}"];

    private static string DisplayEventKind(AssignmentLifecycleEventKind kind) =>
        UiLanguageService.Shared[$"DelegationEvent{kind}"];

    private static string DisplayDisposition(AssignmentLifecycleDisposition disposition) =>
        UiLanguageService.Shared[$"DelegationDisposition{disposition}"];

    private static string DisplayRole(string role) => role switch
    {
        "Project Manager" => UiLanguageService.Shared["DelegationRoleProjectManager"],
        "Backend Leader" => UiLanguageService.Shared["DelegationRoleBackendLeader"],
        "Frontend Leader" => UiLanguageService.Shared["DelegationRoleFrontendLeader"],
        "Test Leader" => UiLanguageService.Shared["DelegationRoleTestLeader"],
        "Backend Worker" => UiLanguageService.Shared["DelegationRoleBackendWorker"],
        "Frontend Worker" => UiLanguageService.Shared["DelegationRoleFrontendWorker"],
        "Test Worker" => UiLanguageService.Shared["DelegationRoleTestWorker"],
        "Reviewer" => UiLanguageService.Shared["DelegationRoleReviewer"],
        "Unknown" => UiLanguageService.Shared["ValueUnknown"],
        _ => role,
    };

    private static string DisplayActor(string actorId) => actorId switch
    {
        "project-manager" => UiLanguageService.Shared["DelegationActorProjectManager"],
        "backend-leader" => UiLanguageService.Shared["DelegationActorBackendLeader"],
        "frontend-leader" => UiLanguageService.Shared["DelegationActorFrontendLeader"],
        "test-leader" => UiLanguageService.Shared["DelegationActorTestLeader"],
        "backend-worker-01" => UiLanguageService.Shared["DelegationActorBackendWorker01"],
        "backend-worker-02" => UiLanguageService.Shared["DelegationActorBackendWorker02"],
        "frontend-worker-01" => UiLanguageService.Shared["DelegationActorFrontendWorker01"],
        "reviewer-01" => UiLanguageService.Shared["DelegationActorReviewer01"],
        _ => actorId,
    };

    private static string Initials(string value)
    {
        var words = value.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (words.Length == 0)
        {
            return "?";
        }

        return string.Concat(words.Take(2).Select(word => char.ToUpperInvariant(word[0])));
    }

    private static string DisplaySummary(
        string summary,
        string taskId,
        AssignmentLifecycleEventKind kind)
    {
        if (string.Equals(summary, SyntheticSummary(kind, taskId), StringComparison.Ordinal))
        {
            return UiLanguageService.Shared.Format(
                "DelegationSyntheticEventSummaryFormat",
                DisplayEventKind(kind),
                taskId);
        }

        if (kind == AssignmentLifecycleEventKind.Handoff &&
            string.Equals(
                summary,
                "Implementation and evidence are ready for review.",
                StringComparison.Ordinal))
        {
            return UiLanguageService.Shared["DelegationSyntheticHandoffReady"];
        }

        return summary;
    }

    private static string? ResolveSelection(
        AssignmentDelegationGraph graph,
        string? actorId,
        string? selectedTaskId,
        IReadOnlyList<DelegationTaskTreeItem> taskTreeItems)
    {
        if (actorId is null)
        {
            return selectedTaskId;
        }

        var taskId = AssignmentDelegationGraphProjector.ResolveSelectedTaskIdForActor(graph, actorId, selectedTaskId);
        if (taskId is null)
        {
            return null;
        }

        return taskTreeItems.Any(item => string.Equals(item.TaskId, taskId, StringComparison.Ordinal))
            ? taskId
            : null;
    }

    private static IReadOnlyList<AssignmentLifecycleEvent> CreateSyntheticEvents()
    {
        var events = new List<AssignmentLifecycleEvent>();
        var assignment115 = Add(AssignmentLifecycleEventKind.Assignment, "TASK-115", "project-manager", "Project Manager", target: "backend-leader");
        var leader115 = Add(AssignmentLifecycleEventKind.Acknowledgement, "TASK-115", "backend-leader", "Backend Leader", parent: assignment115.EventId);
        var delegate115 = Add(AssignmentLifecycleEventKind.Delegation, "TASK-115", "backend-leader", "Backend Leader", parent: leader115.EventId, target: "backend-worker-01");
        var worker115 = Add(AssignmentLifecycleEventKind.Acknowledgement, "TASK-115", "backend-worker-01", "Backend Worker", parent: delegate115.EventId);
        var progress115 = Add(AssignmentLifecycleEventKind.Progress, "TASK-115", "backend-worker-01", "Backend Worker", parent: worker115.EventId, progress: 70);
        var evidence115 = Add(AssignmentLifecycleEventKind.Evidence, "TASK-115", "backend-worker-01", "Backend Worker", parent: progress115.EventId, evidence: "artifacts/tests/task-115.trx");
        _ = Add(AssignmentLifecycleEventKind.Handoff, "TASK-115", "backend-worker-01", "Backend Worker", parent: evidence115.EventId, target: "reviewer-01", handoff: "Implementation and evidence are ready for review.");

        var assignment118 = Add(AssignmentLifecycleEventKind.Assignment, "TASK-118", "project-manager", "Project Manager", target: "frontend-leader");
        var leader118 = Add(AssignmentLifecycleEventKind.Acknowledgement, "TASK-118", "frontend-leader", "Frontend Leader", parent: assignment118.EventId);
        var delegate118 = Add(AssignmentLifecycleEventKind.Delegation, "TASK-118", "frontend-leader", "Frontend Leader", parent: leader118.EventId, target: "frontend-worker-01");
        var worker118 = Add(AssignmentLifecycleEventKind.Acknowledgement, "TASK-118", "frontend-worker-01", "Frontend Worker", parent: delegate118.EventId);
        _ = Add(AssignmentLifecycleEventKind.Progress, "TASK-118", "frontend-worker-01", "Frontend Worker", parent: worker118.EventId, progress: 45);

        _ = Add(AssignmentLifecycleEventKind.Assignment, "TASK-120", "project-manager", "Project Manager", target: "test-leader");

        var assignment122 = Add(AssignmentLifecycleEventKind.Assignment, "TASK-122", "project-manager", "Project Manager", target: "backend-worker-02");
        var worker122 = Add(AssignmentLifecycleEventKind.Acknowledgement, "TASK-122", "backend-worker-02", "Backend Worker", parent: assignment122.EventId);
        _ = Add(AssignmentLifecycleEventKind.Deviation, "TASK-122", "backend-worker-02", "Backend Worker", parent: worker122.EventId, deviation: "A dependency is unavailable.");
        return events;

        AssignmentLifecycleEvent Add(
            AssignmentLifecycleEventKind kind,
            string taskId,
            string actorId,
            string role,
            Guid? parent = null,
            string? target = null,
            int? progress = null,
            string? deviation = null,
            string? evidence = null,
            string? handoff = null)
        {
            var sequence = events.Count + 1;
            var occurredUtc = new DateTimeOffset(2026, 8, 15, 0, 0, 0, TimeSpan.Zero)
                .AddMinutes(sequence);
            var value = new AssignmentLifecycleEvent(
                AssignmentLifecycleContract.Version,
                Guid.Parse($"00000000-0000-0000-0000-{sequence:000000000000}"),
                kind,
                sequence,
                occurredUtc,
                occurredUtc.AddSeconds(1),
                AssignmentLifecycleContract.CoreSource,
                Guid.Parse($"00000000-0000-0000-0001-{sequence:000000000000}"),
                Hash($"synthetic-source-{sequence}-{kind}"),
                taskId,
                actorId,
                role,
                SyntheticSummary(kind, taskId),
                parent,
                target,
                progress,
                deviation,
                evidence,
                evidence is null ? null : Hash(evidence),
                handoff);
            events.Add(value);
            return value;
        }
    }

    private static string SyntheticSummary(AssignmentLifecycleEventKind kind, string taskId) =>
        $"{kind} recorded for {taskId}.";

    private static string Hash(string value) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value)));
}
