using HerdrOps.App.Live;
using HerdrOps.Contracts.StateIpc;
using HerdrOps.Domain.Assignments;

namespace HerdrOps.App.Widgets;

public enum WidgetAssignmentDiagnosticCode
{
    MissingAgent = 1,
    MissingRole = 2,
    RoleMismatch = 3,
    MultipleCurrentTasks = 4,
    AnalysisLifecycleMismatch = 5,
}

public sealed record WidgetAssignmentDiagnostic(
    WidgetAssignmentDiagnosticCode Code,
    string SubjectId,
    string Detail);

public sealed record WidgetAssignmentFact(
    string TerminalId,
    string TaskId,
    string TaskSummary,
    string ActorRole,
    string AssignedByActorId,
    string Activity,
    DateTimeOffset StartedUtc,
    int? Score,
    bool HasTaskAlignment,
    long LastSequence,
    string LifecycleProvenanceSha256,
    string? ScoreProvenanceSha256);

public sealed record WidgetAssignmentProjection(
    int ContractVersion,
    string LifecycleGraphSha256,
    IReadOnlyList<WidgetAssignmentFact> Facts,
    IReadOnlyList<WidgetAssignmentDiagnostic> Diagnostics)
{
    public static WidgetAssignmentProjection Empty { get; } = new(
        AssignmentLifecycleContract.Version,
        string.Empty,
        [],
        []);

    public bool HasAdmittedLifecycle => LifecycleGraphSha256.Length == 64;

    public WidgetAssignmentFact? FindExact(string terminalId) =>
        Facts.SingleOrDefault(item => string.Equals(
            item.TerminalId,
            terminalId,
            StringComparison.Ordinal));
}

/// <summary>
/// Joins admitted assignment state to a live Herdr Agent only when the lifecycle
/// actor identifier is the exact Herdr terminal identifier and the roles agree.
/// Missing, ambiguous, and mismatched data remains diagnostic-only.
/// </summary>
public static class WidgetAssignmentProjector
{
    public static WidgetAssignmentProjection Create(
        HerdrSessionStateContract sessionState,
        AssignmentLifecycleReplayResult replay,
        IReadOnlyList<TaskAlignmentAnalysisResult>? analyses = null)
    {
        sessionState = HerdrSessionStateContractReducer.NormalizeAndValidate(sessionState);
        ArgumentNullException.ThrowIfNull(replay);
        analyses ??= [];

        var graph = AssignmentDelegationGraphProjector.Create(replay);
        var diagnostics = new List<WidgetAssignmentDiagnostic>();
        var validAnalyses = ValidateAnalyses(graph, analyses, diagnostics);
        var tasksByAssignee = graph.Tasks
            .GroupBy(item => item.CurrentAssigneeId, StringComparer.Ordinal)
            .ToDictionary(group => group.Key, group => group.ToArray(), StringComparer.Ordinal);
        var facts = new List<WidgetAssignmentFact>();

        foreach (var (assigneeId, tasks) in tasksByAssignee.OrderBy(
                     item => item.Key,
                     StringComparer.Ordinal))
        {
            var agent = sessionState.Agents.SingleOrDefault(item => string.Equals(
                item.TerminalId,
                assigneeId,
                StringComparison.Ordinal));
            if (agent is null)
            {
                diagnostics.Add(new WidgetAssignmentDiagnostic(
                    WidgetAssignmentDiagnosticCode.MissingAgent,
                    assigneeId,
                    "The current lifecycle assignee has no exact Herdr terminal identity."));
                continue;
            }

            if (tasks.Length != 1)
            {
                diagnostics.Add(new WidgetAssignmentDiagnostic(
                    WidgetAssignmentDiagnosticCode.MultipleCurrentTasks,
                    assigneeId,
                    "The Expanded Widget cannot select one current task because the Agent has multiple lifecycle tips."));
                continue;
            }

            var task = tasks[0];
            var liveRole = AgentStatusPresentation.FirstNonEmpty(
                agent.Title,
                agent.DisplayAgent,
                agent.Agent);
            if (string.IsNullOrWhiteSpace(task.CurrentAssigneeRole))
            {
                diagnostics.Add(new WidgetAssignmentDiagnostic(
                    WidgetAssignmentDiagnosticCode.MissingRole,
                    task.TaskId,
                    "The current lifecycle assignee has not acknowledged a role at this lineage tip."));
                continue;
            }

            if (!string.Equals(task.CurrentAssigneeRole, liveRole, StringComparison.Ordinal))
            {
                diagnostics.Add(new WidgetAssignmentDiagnostic(
                    WidgetAssignmentDiagnosticCode.RoleMismatch,
                    task.TaskId,
                    $"Lifecycle role '{task.CurrentAssigneeRole}' does not exactly match Herdr role '{liveRole}'."));
                continue;
            }

            var relationship = graph.Edges
                .Where(item =>
                    string.Equals(item.TaskId, task.TaskId, StringComparison.Ordinal) &&
                    string.Equals(item.ToActorId, assigneeId, StringComparison.Ordinal))
                .OrderBy(item => item.Sequence)
                .LastOrDefault();
            if (relationship is null)
            {
                throw new InvalidOperationException(
                    $"Task '{task.TaskId}' has no relationship provenance for its current assignee.");
            }

            var activity = graph.Timeline
                .Where(item =>
                    item.Disposition == AssignmentLifecycleDisposition.Applied &&
                    string.Equals(item.TaskId, task.TaskId, StringComparison.Ordinal) &&
                    (string.Equals(item.ActorId, assigneeId, StringComparison.Ordinal) ||
                     string.Equals(item.TargetAgentId, assigneeId, StringComparison.Ordinal)))
                .OrderBy(item => item.Sequence)
                .Last();
            validAnalyses.TryGetValue(task.TaskId, out var analysis);
            facts.Add(new WidgetAssignmentFact(
                agent.TerminalId,
                task.TaskId,
                task.Summary,
                task.CurrentAssigneeRole,
                relationship.FromActorId,
                activity.Summary,
                relationship.AcceptedUtc,
                CompositeScore(analysis),
                analysis is not null,
                task.LastSequence,
                task.ProvenanceEventSha256,
                analysis?.AnalysisSha256));
        }

        return new WidgetAssignmentProjection(
            graph.ContractVersion,
            graph.GraphSha256,
            facts.OrderBy(item => item.TerminalId, StringComparer.Ordinal).ToArray(),
            diagnostics
                .OrderBy(item => item.Code)
                .ThenBy(item => item.SubjectId, StringComparer.Ordinal)
                .ToArray());
    }

    private static IReadOnlyDictionary<string, TaskAlignmentAnalysisResult> ValidateAnalyses(
        AssignmentDelegationGraph graph,
        IReadOnlyList<TaskAlignmentAnalysisResult> analyses,
        ICollection<WidgetAssignmentDiagnostic> diagnostics)
    {
        var result = new Dictionary<string, TaskAlignmentAnalysisResult>(StringComparer.Ordinal);
        foreach (var analysis in analyses)
        {
            ArgumentNullException.ThrowIfNull(analysis);
            if (!result.TryAdd(analysis.TaskId, analysis))
            {
                throw new ArgumentException(
                    $"Task Alignment contains duplicate analysis for '{analysis.TaskId}'.",
                    nameof(analyses));
            }

            if (!string.Equals(
                    analysis.LifecycleGraphSha256,
                    graph.GraphSha256,
                    StringComparison.Ordinal))
            {
                result.Remove(analysis.TaskId);
                diagnostics.Add(new WidgetAssignmentDiagnostic(
                    WidgetAssignmentDiagnosticCode.AnalysisLifecycleMismatch,
                    analysis.TaskId,
                    "The Task Alignment analysis does not bind the admitted lifecycle graph."));
            }
        }

        return result;
    }

    private static int? CompositeScore(TaskAlignmentAnalysisResult? analysis)
    {
        if (analysis is null ||
            analysis.GoalAlignmentScore is not { } goal ||
            analysis.ScopeComplianceScore is not { } scope ||
            analysis.AcceptanceCriteriaScore is not { } acceptance)
        {
            return null;
        }

        return checked((int)Math.Round(
            (goal + scope + acceptance) / 3d,
            MidpointRounding.AwayFromZero));
    }
}
