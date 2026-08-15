namespace HerdrOps.Domain.Assignments;

public sealed class AssignmentLifecycleReducer
{
    private readonly Dictionary<string, AssignmentTaskSnapshot> _tasks =
        new(StringComparer.Ordinal);
    private readonly Dictionary<Guid, ConsumedEvent> _eventsById = [];
    private readonly Dictionary<long, ConsumedEvent> _eventsBySequence = [];
    private readonly List<AssignmentLifecycleAuditEntry> _auditTrail = [];
    private readonly List<AssignmentRoleRelationship> _relationships = [];
    private readonly List<AssignmentActorRoleObservation> _roleHistory = [];
    private readonly Dictionary<string, AssignmentCurrentActorRole> _currentRoles =
        new(StringComparer.Ordinal);
    private long _processedEventCount;
    private long _consumedSequenceCount;
    private long _appliedEventCount;
    private long _duplicateEventCount;
    private long _conflictEventCount;
    private long _sequenceGapCount;
    private long _orphanEventCount;
    private long _invalidTransitionCount;
    private long _duplicateHandoffCount;
    private long _lastSequence;

    public long LastSequence => _lastSequence;

    public AssignmentLifecycleStep Process(AssignmentLifecycleEvent lifecycleEvent)
    {
        var normalized = AssignmentLifecycleContract.NormalizeAndValidate(lifecycleEvent);
        _processedEventCount++;

        if (_eventsById.TryGetValue(normalized.Event.EventId, out var sameIdentifier))
        {
            if (string.Equals(
                    sameIdentifier.NormalizedEvent.LifecycleEventSha256,
                    normalized.LifecycleEventSha256,
                    StringComparison.Ordinal))
            {
                _duplicateEventCount++;
                return CreateNonConsumingStep(
                    normalized,
                    AssignmentLifecycleDisposition.Duplicate,
                    "duplicate-event",
                    "The identical lifecycle event was already consumed.");
            }

            _conflictEventCount++;
            return CreateNonConsumingStep(
                normalized,
                AssignmentLifecycleDisposition.IdentityConflict,
                "event-id-conflict",
                "The lifecycle event identifier was already consumed with different content.");
        }

        if (_eventsBySequence.TryGetValue(normalized.Event.Sequence, out var sameSequence))
        {
            _conflictEventCount++;
            return CreateNonConsumingStep(
                normalized,
                AssignmentLifecycleDisposition.SequenceConflict,
                "sequence-conflict",
                $"Sequence {normalized.Event.Sequence} already belongs to event {sameSequence.NormalizedEvent.Event.EventId:D}.");
        }

        if (normalized.Event.Sequence < _lastSequence)
        {
            _conflictEventCount++;
            return CreateNonConsumingStep(
                normalized,
                AssignmentLifecycleDisposition.SequenceRegression,
                "sequence-regression",
                $"Sequence {normalized.Event.Sequence} regressed below the consumed sequence {_lastSequence}.");
        }

        var expectedSequence = _lastSequence == long.MaxValue ? (long?)null : _lastSequence + 1;
        if (normalized.Event.Sequence != expectedSequence)
        {
            _sequenceGapCount++;
            return Consume(
                normalized,
                new TransitionEvaluation(
                    AssignmentLifecycleDisposition.SequenceGap,
                    "sequence-gap",
                    $"Expected lifecycle sequence {expectedSequence?.ToString() ?? "none"} but observed {normalized.Event.Sequence}.",
                    NewTask: null,
                    Relationship: null));
        }

        return Consume(normalized, EvaluateTransition(normalized));
    }

    public AssignmentTaskSnapshot? GetTask(string taskId)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(taskId);
        return _tasks.GetValueOrDefault(taskId);
    }

    public IReadOnlyList<AssignmentTaskSnapshot> GetCurrentTasks() =>
        _tasks.Values
            .OrderBy(task => task.State.TaskId, StringComparer.Ordinal)
            .ToArray();

    public IReadOnlyList<AssignmentRoleRelationship> GetRelationships() =>
        _relationships.ToArray();

    public IReadOnlyList<AssignmentActorRoleObservation> GetRoleHistory() =>
        _roleHistory.ToArray();

    public IReadOnlyList<AssignmentCurrentActorRole> GetCurrentRoles() =>
        _currentRoles.Values
            .OrderBy(role => role.ActorId, StringComparer.Ordinal)
            .ToArray();

    public IReadOnlyList<AssignmentLifecycleAuditEntry> GetAuditTrail() =>
        _auditTrail.ToArray();

    public AssignmentLifecycleDiagnostics GetDiagnostics() => new(
        _processedEventCount,
        _consumedSequenceCount,
        _appliedEventCount,
        _duplicateEventCount,
        _conflictEventCount,
        _sequenceGapCount,
        _orphanEventCount,
        _invalidTransitionCount,
        _duplicateHandoffCount,
        _tasks.Count,
        _relationships.Count,
        _roleHistory.Count,
        _lastSequence);

    private AssignmentLifecycleStep Consume(
        NormalizedAssignmentLifecycleEvent normalized,
        TransitionEvaluation transition)
    {
        var lifecycleEvent = normalized.Event;
        var priorTask = _tasks.GetValueOrDefault(lifecycleEvent.TaskId);
        AssignmentTaskSnapshot? currentTask = priorTask;
        AssignmentActorRoleObservation? roleObservation = null;
        if (transition.Disposition == AssignmentLifecycleDisposition.Applied)
        {
            currentTask = transition.NewTask ?? throw new InvalidOperationException(
                "An applied assignment transition requires a resulting task snapshot.");
            _tasks[currentTask.State.TaskId] = currentTask;
            _appliedEventCount++;
            roleObservation = AssignmentLifecycleContract.CreateRoleObservation(normalized);
            _roleHistory.Add(roleObservation);
            _currentRoles[roleObservation.ActorId] =
                AssignmentLifecycleContract.CreateCurrentRole(roleObservation);
            if (transition.Relationship is not null)
            {
                _relationships.Add(transition.Relationship);
            }
        }
        else
        {
            RecordRejectedDisposition(transition.Disposition);
        }

        var audit = AssignmentLifecycleContract.CreateAuditEntry(
            normalized,
            transition.Disposition,
            consumesSequence: true,
            transition.Code,
            transition.Message,
            priorTask?.StateSha256,
            currentTask?.StateSha256);
        var consumed = new ConsumedEvent(normalized, audit);
        _eventsById.Add(lifecycleEvent.EventId, consumed);
        _eventsBySequence.Add(lifecycleEvent.Sequence, consumed);
        _auditTrail.Add(audit);
        _consumedSequenceCount++;
        _lastSequence = lifecycleEvent.Sequence;
        return new AssignmentLifecycleStep(
            normalized,
            audit,
            currentTask,
            transition.Relationship,
            roleObservation);
    }

    private AssignmentLifecycleStep CreateNonConsumingStep(
        NormalizedAssignmentLifecycleEvent normalized,
        AssignmentLifecycleDisposition disposition,
        string code,
        string message)
    {
        var currentTask = _tasks.GetValueOrDefault(normalized.Event.TaskId);
        var audit = AssignmentLifecycleContract.CreateAuditEntry(
            normalized,
            disposition,
            consumesSequence: false,
            code,
            message,
            currentTask?.StateSha256,
            currentTask?.StateSha256);
        return new AssignmentLifecycleStep(
            normalized,
            audit,
            currentTask,
            null,
            null);
    }

    private TransitionEvaluation EvaluateTransition(
        NormalizedAssignmentLifecycleEvent normalized)
    {
        var lifecycleEvent = normalized.Event;
        if (lifecycleEvent.EventKind == AssignmentLifecycleEventKind.Assignment)
        {
            return EvaluateAssignment(normalized);
        }

        if (!_tasks.TryGetValue(lifecycleEvent.TaskId, out var currentTask))
        {
            return Rejected(
                AssignmentLifecycleDisposition.OrphanTask,
                "orphan-task",
                $"Task '{lifecycleEvent.TaskId}' has no applied assignment contract.");
        }

        var parentId = lifecycleEvent.ParentEventId!.Value;
        if (!_eventsById.TryGetValue(parentId, out var parent) ||
            parent.Audit.Disposition != AssignmentLifecycleDisposition.Applied ||
            !string.Equals(
                parent.NormalizedEvent.Event.TaskId,
                lifecycleEvent.TaskId,
                StringComparison.Ordinal))
        {
            return Rejected(
                AssignmentLifecycleDisposition.OrphanParent,
                "orphan-parent",
                $"Parent event '{parentId:D}' is not an applied event for task '{lifecycleEvent.TaskId}'.");
        }

        if (parentId != currentTask.State.LastEventId)
        {
            return Rejected(
                AssignmentLifecycleDisposition.InvalidTransition,
                "stale-parent",
                $"Parent event '{parentId:D}' is not the current task lineage tip '{currentTask.State.LastEventId:D}'.");
        }

        if (lifecycleEvent.EventKind == AssignmentLifecycleEventKind.Handoff &&
            currentTask.State.Status == AssignmentTaskStatus.HandedOff)
        {
            return Rejected(
                AssignmentLifecycleDisposition.DuplicateHandoff,
                "duplicate-handoff",
                "A second handoff was reported before the current handoff target acknowledged the task.");
        }

        if (!string.Equals(
                lifecycleEvent.ActorId,
                currentTask.State.CurrentAssigneeId,
                StringComparison.Ordinal))
        {
            return Rejected(
                AssignmentLifecycleDisposition.InvalidTransition,
                "actor-not-current-assignee",
                $"Actor '{lifecycleEvent.ActorId}' is not the current assignee '{currentTask.State.CurrentAssigneeId}'.");
        }

        return lifecycleEvent.EventKind switch
        {
            AssignmentLifecycleEventKind.Acknowledgement =>
                EvaluateAcknowledgement(normalized, currentTask),
            AssignmentLifecycleEventKind.Delegation =>
                EvaluateDelegation(normalized, currentTask),
            AssignmentLifecycleEventKind.Progress =>
                EvaluateProgress(normalized, currentTask),
            AssignmentLifecycleEventKind.Deviation =>
                EvaluateDeviation(normalized, currentTask),
            AssignmentLifecycleEventKind.Evidence =>
                EvaluateEvidence(normalized, currentTask),
            AssignmentLifecycleEventKind.Handoff =>
                EvaluateHandoff(normalized, currentTask),
            _ => throw new InvalidOperationException(
                $"Unsupported assignment lifecycle event kind: {lifecycleEvent.EventKind}"),
        };
    }

    private TransitionEvaluation EvaluateAssignment(
        NormalizedAssignmentLifecycleEvent normalized)
    {
        var lifecycleEvent = normalized.Event;
        if (_tasks.ContainsKey(lifecycleEvent.TaskId))
        {
            return Rejected(
                AssignmentLifecycleDisposition.InvalidTransition,
                "duplicate-assignment",
                $"Task '{lifecycleEvent.TaskId}' already has an assignment contract.");
        }

        var contract = new AssignmentContractState(
            AssignmentLifecycleContract.Version,
            lifecycleEvent.TaskId,
            lifecycleEvent.EventId,
            lifecycleEvent.ActorId,
            lifecycleEvent.ActorRole,
            lifecycleEvent.TargetAgentId!,
            lifecycleEvent.Summary,
            lifecycleEvent.OccurredUtc,
            lifecycleEvent.AcceptedUtc,
            lifecycleEvent.Sequence,
            lifecycleEvent.CorrelationId,
            normalized.LifecycleEventSha256);
        var state = AssignmentLifecycleContract.CreateTaskSnapshot(
            new AssignmentTaskState(
                AssignmentLifecycleContract.Version,
                lifecycleEvent.TaskId,
                contract,
                AssignmentTaskStatus.Assigned,
                lifecycleEvent.TargetAgentId!,
                null,
                ProgressPercent: 0,
                DeviationCount: 0,
                EvidenceCount: 0,
                HandoffCount: 0,
                lifecycleEvent.EventId,
                lifecycleEvent.Sequence,
                lifecycleEvent.AcceptedUtc));
        return Applied(
            "assignment-applied",
            "The assignment contract created the task lifecycle.",
            state,
            AssignmentLifecycleContract.CreateRelationship(
                normalized,
                AssignmentRelationshipKind.Assignment,
                lifecycleEvent.TargetAgentId!));
    }

    private static TransitionEvaluation EvaluateAcknowledgement(
        NormalizedAssignmentLifecycleEvent normalized,
        AssignmentTaskSnapshot currentTask)
    {
        if (currentTask.State.Status is not (
            AssignmentTaskStatus.Assigned or
            AssignmentTaskStatus.Delegated or
            AssignmentTaskStatus.HandedOff))
        {
            return Rejected(
                AssignmentLifecycleDisposition.InvalidTransition,
                "unexpected-acknowledgement",
                $"Status {currentTask.State.Status} does not accept another acknowledgement.");
        }

        return Applied(
            "acknowledgement-applied",
            "The current assignee acknowledged the task lineage tip.",
            UpdateTask(
                currentTask,
                normalized,
                AssignmentTaskStatus.Acknowledged,
                currentAssigneeRole: normalized.Event.ActorRole));
    }

    private static TransitionEvaluation EvaluateDelegation(
        NormalizedAssignmentLifecycleEvent normalized,
        AssignmentTaskSnapshot currentTask)
    {
        var lifecycleEvent = normalized.Event;
        if (!CanActOnAcknowledgedTask(currentTask.State.Status))
        {
            return MissingAcknowledgement(currentTask.State.Status, "delegation");
        }

        var task = UpdateTask(
            currentTask,
            normalized,
            AssignmentTaskStatus.Delegated,
            currentAssigneeId: lifecycleEvent.TargetAgentId!,
            currentAssigneeRole: null);
        return Applied(
            "delegation-applied",
            "The current assignee delegated the task to a new assignee.",
            task,
            AssignmentLifecycleContract.CreateRelationship(
                normalized,
                AssignmentRelationshipKind.Delegation,
                lifecycleEvent.TargetAgentId!));
    }

    private static TransitionEvaluation EvaluateProgress(
        NormalizedAssignmentLifecycleEvent normalized,
        AssignmentTaskSnapshot currentTask)
    {
        if (!CanActOnAcknowledgedTask(currentTask.State.Status))
        {
            return MissingAcknowledgement(currentTask.State.Status, "progress");
        }

        if (normalized.Event.ProgressPercent < currentTask.State.ProgressPercent)
        {
            return Rejected(
                AssignmentLifecycleDisposition.InvalidTransition,
                "progress-regression",
                $"Progress cannot regress from {currentTask.State.ProgressPercent} to {normalized.Event.ProgressPercent}.");
        }

        return Applied(
            "progress-applied",
            "The current assignee advanced task progress.",
            UpdateTask(
                currentTask,
                normalized,
                AssignmentTaskStatus.InProgress,
                progressPercent: normalized.Event.ProgressPercent));
    }

    private static TransitionEvaluation EvaluateDeviation(
        NormalizedAssignmentLifecycleEvent normalized,
        AssignmentTaskSnapshot currentTask)
    {
        if (!CanActOnAcknowledgedTask(currentTask.State.Status))
        {
            return MissingAcknowledgement(currentTask.State.Status, "deviation");
        }

        return Applied(
            "deviation-applied",
            "The current assignee reported a scoped deviation.",
            UpdateTask(
                currentTask,
                normalized,
                AssignmentTaskStatus.DeviationReported,
                deviationCount: checked(currentTask.State.DeviationCount + 1)));
    }

    private static TransitionEvaluation EvaluateEvidence(
        NormalizedAssignmentLifecycleEvent normalized,
        AssignmentTaskSnapshot currentTask)
    {
        if (!CanActOnAcknowledgedTask(currentTask.State.Status))
        {
            return MissingAcknowledgement(currentTask.State.Status, "evidence");
        }

        return Applied(
            "evidence-applied",
            "The current assignee submitted evidence for the task.",
            UpdateTask(
                currentTask,
                normalized,
                AssignmentTaskStatus.EvidenceSubmitted,
                evidenceCount: checked(currentTask.State.EvidenceCount + 1)));
    }

    private static TransitionEvaluation EvaluateHandoff(
        NormalizedAssignmentLifecycleEvent normalized,
        AssignmentTaskSnapshot currentTask)
    {
        if (currentTask.State.Status is not (
            AssignmentTaskStatus.InProgress or
            AssignmentTaskStatus.DeviationReported or
            AssignmentTaskStatus.EvidenceSubmitted))
        {
            return MissingAcknowledgement(currentTask.State.Status, "handoff");
        }

        if (currentTask.State.EvidenceCount == 0)
        {
            return Rejected(
                AssignmentLifecycleDisposition.InvalidTransition,
                "handoff-missing-evidence",
                "A task cannot be handed off before at least one evidence event is applied.");
        }

        var lifecycleEvent = normalized.Event;
        var task = UpdateTask(
            currentTask,
            normalized,
            AssignmentTaskStatus.HandedOff,
            currentAssigneeId: lifecycleEvent.TargetAgentId!,
            currentAssigneeRole: null,
            handoffCount: checked(currentTask.State.HandoffCount + 1));
        return Applied(
            "handoff-applied",
            "The task was handed off with evidence to a new assignee.",
            task,
            AssignmentLifecycleContract.CreateRelationship(
                normalized,
                AssignmentRelationshipKind.Handoff,
                lifecycleEvent.TargetAgentId!));
    }

    private static AssignmentTaskSnapshot UpdateTask(
        AssignmentTaskSnapshot current,
        NormalizedAssignmentLifecycleEvent normalized,
        AssignmentTaskStatus status,
        string? currentAssigneeId = null,
        string? currentAssigneeRole = null,
        int? progressPercent = null,
        int? deviationCount = null,
        int? evidenceCount = null,
        int? handoffCount = null) =>
        AssignmentLifecycleContract.CreateTaskSnapshot(current.State with
        {
            Status = status,
            CurrentAssigneeId = currentAssigneeId ?? current.State.CurrentAssigneeId,
            CurrentAssigneeRole = currentAssigneeId is not null
                ? currentAssigneeRole
                : currentAssigneeRole ?? current.State.CurrentAssigneeRole,
            ProgressPercent = progressPercent ?? current.State.ProgressPercent,
            DeviationCount = deviationCount ?? current.State.DeviationCount,
            EvidenceCount = evidenceCount ?? current.State.EvidenceCount,
            HandoffCount = handoffCount ?? current.State.HandoffCount,
            LastEventId = normalized.Event.EventId,
            LastSequence = normalized.Event.Sequence,
            LastTransitionUtc = normalized.Event.AcceptedUtc,
        });

    private static bool CanActOnAcknowledgedTask(AssignmentTaskStatus status) =>
        status is AssignmentTaskStatus.Acknowledged or
            AssignmentTaskStatus.InProgress or
            AssignmentTaskStatus.DeviationReported or
            AssignmentTaskStatus.EvidenceSubmitted;

    private static TransitionEvaluation MissingAcknowledgement(
        AssignmentTaskStatus status,
        string action) =>
        Rejected(
            AssignmentLifecycleDisposition.InvalidTransition,
            "missing-acknowledgement",
            $"The {action} event cannot follow status {status}; the current assignee must acknowledge first.");

    private static TransitionEvaluation Applied(
        string code,
        string message,
        AssignmentTaskSnapshot task,
        AssignmentRoleRelationship? relationship = null) => new(
        AssignmentLifecycleDisposition.Applied,
        code,
        message,
        task,
        relationship);

    private static TransitionEvaluation Rejected(
        AssignmentLifecycleDisposition disposition,
        string code,
        string message) => new(
        disposition,
        code,
        message,
        NewTask: null,
        Relationship: null);

    private void RecordRejectedDisposition(AssignmentLifecycleDisposition disposition)
    {
        switch (disposition)
        {
            case AssignmentLifecycleDisposition.SequenceGap:
                break;
            case AssignmentLifecycleDisposition.OrphanTask:
            case AssignmentLifecycleDisposition.OrphanParent:
                _orphanEventCount++;
                break;
            case AssignmentLifecycleDisposition.InvalidTransition:
                _invalidTransitionCount++;
                break;
            case AssignmentLifecycleDisposition.DuplicateHandoff:
                _duplicateHandoffCount++;
                break;
            default:
                throw new InvalidOperationException(
                    $"Disposition {disposition} is not a consumable rejected lifecycle event.");
        }
    }

    private sealed record ConsumedEvent(
        NormalizedAssignmentLifecycleEvent NormalizedEvent,
        AssignmentLifecycleAuditEntry Audit);

    private sealed record TransitionEvaluation(
        AssignmentLifecycleDisposition Disposition,
        string Code,
        string Message,
        AssignmentTaskSnapshot? NewTask,
        AssignmentRoleRelationship? Relationship);
}

public static class AssignmentLifecycleReplay
{
    public const int ContractVersion = 1;
    public const int MaximumReplayEvents = 100_000;

    public static AssignmentLifecycleReplayResult Run(
        IReadOnlyList<AssignmentLifecycleEvent> events,
        int maximumReplayEvents = MaximumReplayEvents)
    {
        ArgumentNullException.ThrowIfNull(events);
        if (maximumReplayEvents is < 1 or > MaximumReplayEvents)
        {
            throw new ArgumentOutOfRangeException(
                nameof(maximumReplayEvents),
                $"The assignment replay limit must be from 1 through {MaximumReplayEvents}.");
        }

        if (events.Count > maximumReplayEvents)
        {
            throw new AssignmentLifecycleReplayException(
                $"Assignment lifecycle replay contains {events.Count} events; the configured maximum is {maximumReplayEvents}.");
        }

        var reducer = new AssignmentLifecycleReducer();
        var steps = new List<AssignmentLifecycleStep>(events.Count);
        foreach (var lifecycleEvent in events)
        {
            steps.Add(reducer.Process(lifecycleEvent));
        }

        var auditTrail = reducer.GetAuditTrail();
        var tasks = reducer.GetCurrentTasks();
        var relationships = reducer.GetRelationships();
        var roleHistory = reducer.GetRoleHistory();
        var currentRoles = reducer.GetCurrentRoles();
        var diagnostics = reducer.GetDiagnostics();
        var resultSha256 = AssignmentLifecycleContract.ComputeReplayResultSha256(
            steps,
            auditTrail,
            tasks,
            relationships,
            roleHistory,
            currentRoles,
            diagnostics);
        return new AssignmentLifecycleReplayResult(
            ContractVersion,
            steps,
            auditTrail,
            tasks,
            relationships,
            roleHistory,
            currentRoles,
            diagnostics,
            resultSha256);
    }
}
