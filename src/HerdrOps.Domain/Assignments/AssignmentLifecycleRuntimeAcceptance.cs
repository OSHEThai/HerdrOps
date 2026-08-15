namespace HerdrOps.Domain.Assignments;

public sealed record AssignmentRuntimeAgentIdentity(
    string AgentId,
    string AgentRole);

public sealed record AssignmentRuntimeAcceptanceCheck(
    string CheckId,
    bool Passed,
    string Detail,
    IReadOnlyList<Guid> SupportingEventIds);

public sealed record AssignmentLifecycleRuntimeAcceptanceResult(
    int ContractVersion,
    string TaskId,
    bool CompleteLifecyclePassed,
    bool RoleDistinctAgentsPassed,
    bool OrphanDetectionPassed,
    bool MismatchDetectionPassed,
    IReadOnlyList<AssignmentRuntimeAcceptanceCheck> Checks,
    string LifecycleReplaySha256)
{
    public bool Passed => CompleteLifecyclePassed &&
                          RoleDistinctAgentsPassed &&
                          OrphanDetectionPassed &&
                          MismatchDetectionPassed;
}

public static class AssignmentLifecycleRuntimeAcceptance
{
    public static AssignmentLifecycleRuntimeAcceptanceResult Analyze(
        AssignmentLifecycleReplayResult replay,
        IReadOnlyList<AssignmentRuntimeAgentIdentity> runningAgents,
        string taskId)
    {
        ArgumentNullException.ThrowIfNull(replay);
        ArgumentNullException.ThrowIfNull(runningAgents);
        ArgumentException.ThrowIfNullOrWhiteSpace(taskId);
        _ = AssignmentDelegationGraphProjector.Create(replay);
        var agents = ValidateAgents(runningAgents);
        var applied = replay.Steps
            .Where(item =>
                item.Audit.Disposition == AssignmentLifecycleDisposition.Applied &&
                string.Equals(
                    item.NormalizedEvent.Event.TaskId,
                    taskId,
                    StringComparison.Ordinal))
            .OrderBy(item => item.NormalizedEvent.Event.Sequence)
            .ToArray();
        var checks = new List<AssignmentRuntimeAcceptanceCheck>();

        var assignment = SingleOrNull(applied, item =>
            item.NormalizedEvent.Event.EventKind == AssignmentLifecycleEventKind.Assignment);
        var leaderAcknowledgement = assignment is null
            ? null
            : SingleOrNull(applied, item =>
                IsAcknowledgementOf(
                    item,
                    assignment.NormalizedEvent.Event.TargetAgentId,
                    assignment.NormalizedEvent.Event.EventId));
        var delegation = leaderAcknowledgement is null
            ? null
            : SingleOrNull(applied, item =>
                item.NormalizedEvent.Event.EventKind == AssignmentLifecycleEventKind.Delegation &&
                string.Equals(
                    item.NormalizedEvent.Event.ActorId,
                    leaderAcknowledgement.NormalizedEvent.Event.ActorId,
                    StringComparison.Ordinal) &&
                item.NormalizedEvent.Event.ParentEventId ==
                    leaderAcknowledgement.NormalizedEvent.Event.EventId);
        var workerAcknowledgement = delegation is null
            ? null
            : SingleOrNull(applied, item =>
                IsAcknowledgementOf(
                    item,
                    delegation.NormalizedEvent.Event.TargetAgentId,
                    delegation.NormalizedEvent.Event.EventId));
        var progress = workerAcknowledgement is null
            ? null
            : applied.FirstOrDefault(item =>
                item.NormalizedEvent.Event.EventKind == AssignmentLifecycleEventKind.Progress &&
                string.Equals(
                    item.NormalizedEvent.Event.ActorId,
                    workerAcknowledgement.NormalizedEvent.Event.ActorId,
                    StringComparison.Ordinal) &&
                item.NormalizedEvent.Event.Sequence >
                    workerAcknowledgement.NormalizedEvent.Event.Sequence);
        var evidence = progress is null
            ? null
            : applied.FirstOrDefault(item =>
                item.NormalizedEvent.Event.EventKind == AssignmentLifecycleEventKind.Evidence &&
                string.Equals(
                    item.NormalizedEvent.Event.ActorId,
                    progress.NormalizedEvent.Event.ActorId,
                    StringComparison.Ordinal) &&
                item.NormalizedEvent.Event.Sequence > progress.NormalizedEvent.Event.Sequence);
        var handoff = evidence is null
            ? null
            : applied.FirstOrDefault(item =>
                item.NormalizedEvent.Event.EventKind == AssignmentLifecycleEventKind.Handoff &&
                string.Equals(
                    item.NormalizedEvent.Event.ActorId,
                    evidence.NormalizedEvent.Event.ActorId,
                    StringComparison.Ordinal) &&
                item.NormalizedEvent.Event.Sequence > evidence.NormalizedEvent.Event.Sequence);
        var reviewerAcknowledgement = handoff is null
            ? null
            : SingleOrNull(applied, item =>
                IsAcknowledgementOf(
                    item,
                    handoff.NormalizedEvent.Event.TargetAgentId,
                    handoff.NormalizedEvent.Event.EventId));

        var chain = new[]
        {
            assignment,
            leaderAcknowledgement,
            delegation,
            workerAcknowledgement,
            progress,
            evidence,
            handoff,
            reviewerAcknowledgement,
        };
        var chainComplete = chain.All(item => item is not null) &&
                            chain.Select(item => item!.NormalizedEvent.Event.Sequence)
                                .SequenceEqual(chain
                                    .Select(item => item!.NormalizedEvent.Event.Sequence)
                                    .Order());
        checks.Add(new AssignmentRuntimeAcceptanceCheck(
            "complete-pm-leader-worker-review-lifecycle",
            chainComplete,
            chainComplete
                ? "Assignment, Leader acknowledgement, delegation, Worker acknowledgement, progress, evidence, handoff, and Reviewer acknowledgement are present in order."
                : "The required PM to Leader to Worker to Review lifecycle is incomplete or out of order.",
            EventIds(chain)));

        var roleEvents = new[]
        {
            assignment,
            leaderAcknowledgement,
            workerAcknowledgement,
            reviewerAcknowledgement,
        };
        var distinctRolesPassed = chainComplete &&
                                  roleEvents
                                      .Select(item => item!.NormalizedEvent.Event.ActorId)
                                      .Distinct(StringComparer.Ordinal)
                                      .Count() == roleEvents.Length &&
                                  roleEvents
                                      .Select(item => item!.NormalizedEvent.Event.ActorRole)
                                      .Distinct(StringComparer.Ordinal)
                                      .Count() == roleEvents.Length &&
                                  roleEvents.All(item => ExactRunningAgentMatch(
                                      agents,
                                      item!.NormalizedEvent.Event));
        checks.Add(new AssignmentRuntimeAcceptanceCheck(
            "exact-role-distinct-running-agents",
            distinctRolesPassed,
            distinctRolesPassed
                ? "Every lifecycle stage binds an exact running Agent identity and exact role, with four distinct actors and roles."
                : "One or more lifecycle stages lacks an exact running Agent identity/role match or reuses an actor/role.",
            EventIds(roleEvents)));

        var orphanEvents = replay.Steps
            .Where(item => item.Audit.Disposition is
                AssignmentLifecycleDisposition.OrphanTask or
                AssignmentLifecycleDisposition.OrphanParent)
            .ToArray();
        var orphanPassed = orphanEvents.Length > 0;
        checks.Add(new AssignmentRuntimeAcceptanceCheck(
            "orphan-detection",
            orphanPassed,
            orphanPassed
                ? "At least one consumed orphan event remains in the append-only audit trail."
                : "No consumed orphan event was observed.",
            EventIds(orphanEvents)));

        var mismatchEvents = replay.Steps
            .Where(item =>
                item.Audit.Disposition == AssignmentLifecycleDisposition.InvalidTransition &&
                string.Equals(
                    item.Audit.Code,
                    "actor-not-current-assignee",
                    StringComparison.Ordinal))
            .ToArray();
        var mismatchPassed = mismatchEvents.Length > 0;
        checks.Add(new AssignmentRuntimeAcceptanceCheck(
            "actor-mismatch-detection",
            mismatchPassed,
            mismatchPassed
                ? "At least one non-current actor event was consumed as an immutable mismatch without changing the task tip."
                : "No current-assignee mismatch was observed.",
            EventIds(mismatchEvents)));

        return new AssignmentLifecycleRuntimeAcceptanceResult(
            AssignmentLifecycleContract.Version,
            taskId,
            chainComplete,
            distinctRolesPassed,
            orphanPassed,
            mismatchPassed,
            checks,
            replay.ResultSha256);
    }

    private static IReadOnlyDictionary<string, AssignmentRuntimeAgentIdentity> ValidateAgents(
        IReadOnlyList<AssignmentRuntimeAgentIdentity> runningAgents)
    {
        var result = new Dictionary<string, AssignmentRuntimeAgentIdentity>(StringComparer.Ordinal);
        foreach (var agent in runningAgents)
        {
            ArgumentNullException.ThrowIfNull(agent);
            if (string.IsNullOrWhiteSpace(agent.AgentId) ||
                string.IsNullOrWhiteSpace(agent.AgentRole) ||
                !result.TryAdd(agent.AgentId, agent))
            {
                throw new ArgumentException(
                    "Running Agent identities and roles must be non-blank and unique.",
                    nameof(runningAgents));
            }
        }

        return result;
    }

    private static bool ExactRunningAgentMatch(
        IReadOnlyDictionary<string, AssignmentRuntimeAgentIdentity> runningAgents,
        AssignmentLifecycleEvent lifecycleEvent) =>
        runningAgents.TryGetValue(lifecycleEvent.ActorId, out var agent) &&
        string.Equals(agent.AgentRole, lifecycleEvent.ActorRole, StringComparison.Ordinal);

    private static bool IsAcknowledgementOf(
        AssignmentLifecycleStep item,
        string? actorId,
        Guid parentEventId) =>
        item.NormalizedEvent.Event.EventKind == AssignmentLifecycleEventKind.Acknowledgement &&
        string.Equals(item.NormalizedEvent.Event.ActorId, actorId, StringComparison.Ordinal) &&
        item.NormalizedEvent.Event.ParentEventId == parentEventId;

    private static AssignmentLifecycleStep? SingleOrNull(
        IEnumerable<AssignmentLifecycleStep> steps,
        Func<AssignmentLifecycleStep, bool> predicate)
    {
        var matches = steps.Where(predicate).Take(2).ToArray();
        return matches.Length == 1 ? matches[0] : null;
    }

    private static Guid[] EventIds(IEnumerable<AssignmentLifecycleStep?> steps) =>
        steps
            .Where(item => item is not null)
            .Select(item => item!.NormalizedEvent.Event.EventId)
            .ToArray();
}
