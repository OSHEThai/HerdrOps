namespace HerdrOps.Domain.Assignments;

public enum AssignmentLifecycleEventKind
{
    Assignment = 1,
    Acknowledgement = 2,
    Delegation = 3,
    Progress = 4,
    Deviation = 5,
    Evidence = 6,
    Handoff = 7,
}

public enum AssignmentTaskStatus
{
    Assigned = 1,
    Acknowledged = 2,
    Delegated = 3,
    InProgress = 4,
    DeviationReported = 5,
    EvidenceSubmitted = 6,
    HandedOff = 7,
}

public enum AssignmentRelationshipKind
{
    Assignment = 1,
    Delegation = 2,
    Handoff = 3,
}

public enum AssignmentLifecycleDisposition
{
    Applied = 1,
    Duplicate = 2,
    IdentityConflict = 3,
    SequenceConflict = 4,
    SequenceRegression = 5,
    SequenceGap = 6,
    OrphanTask = 7,
    OrphanParent = 8,
    InvalidTransition = 9,
    DuplicateHandoff = 10,
}

public sealed record AssignmentLifecycleEvent(
    int ContractVersion,
    Guid EventId,
    AssignmentLifecycleEventKind EventKind,
    long Sequence,
    DateTimeOffset OccurredUtc,
    DateTimeOffset AcceptedUtc,
    string Source,
    Guid CorrelationId,
    string EventSha256,
    string TaskId,
    string ActorId,
    string ActorRole,
    string Summary,
    Guid? ParentEventId,
    string? TargetAgentId,
    int? ProgressPercent,
    string? DeviationReason,
    string? EvidenceReference,
    string? EvidenceSha256,
    string? HandoffNote);

public sealed record NormalizedAssignmentLifecycleEvent(
    AssignmentLifecycleEvent Event,
    string LifecycleEventSha256);

public sealed record AssignmentContractState(
    int ContractVersion,
    string TaskId,
    Guid AssignmentEventId,
    string AssignorActorId,
    string AssignorRole,
    string InitialAssigneeId,
    string Summary,
    DateTimeOffset CreatedUtc,
    DateTimeOffset AcceptedUtc,
    long CreatedSequence,
    Guid CorrelationId,
    string ProvenanceEventSha256);

public sealed record AssignmentTaskState(
    int ContractVersion,
    string TaskId,
    AssignmentContractState Contract,
    AssignmentTaskStatus Status,
    string CurrentAssigneeId,
    string? CurrentAssigneeRole,
    int ProgressPercent,
    int DeviationCount,
    int EvidenceCount,
    int HandoffCount,
    Guid LastEventId,
    long LastSequence,
    DateTimeOffset LastTransitionUtc);

public sealed record AssignmentTaskSnapshot(
    AssignmentTaskState State,
    string StateSha256);

public sealed record AssignmentRoleRelationship(
    int ContractVersion,
    Guid RelationshipId,
    AssignmentRelationshipKind RelationshipKind,
    string TaskId,
    string FromActorId,
    string FromActorRole,
    string ToActorId,
    Guid EventId,
    long Sequence,
    DateTimeOffset OccurredUtc,
    DateTimeOffset AcceptedUtc,
    string ProvenanceEventSha256,
    string RelationshipSha256);

public sealed record AssignmentActorRoleObservation(
    int ContractVersion,
    string ActorId,
    string ActorRole,
    string TaskId,
    Guid EventId,
    long Sequence,
    DateTimeOffset AcceptedUtc,
    string ProvenanceEventSha256,
    string ObservationSha256);

public sealed record AssignmentCurrentActorRole(
    int ContractVersion,
    string ActorId,
    string ActorRole,
    string TaskId,
    Guid EventId,
    long Sequence,
    DateTimeOffset AcceptedUtc,
    string ProvenanceEventSha256,
    string StateSha256);

public sealed record AssignmentLifecycleAuditEntry(
    int ContractVersion,
    Guid EventId,
    AssignmentLifecycleEventKind EventKind,
    long Sequence,
    string TaskId,
    AssignmentLifecycleDisposition Disposition,
    bool ConsumesSequence,
    string Code,
    string Message,
    DateTimeOffset AcceptedUtc,
    string LifecycleEventSha256,
    string? PriorTaskStateSha256,
    string? ResultTaskStateSha256,
    string AuditSha256);

public sealed record AssignmentLifecycleStep(
    NormalizedAssignmentLifecycleEvent NormalizedEvent,
    AssignmentLifecycleAuditEntry Audit,
    AssignmentTaskSnapshot? CurrentTask,
    AssignmentRoleRelationship? Relationship,
    AssignmentActorRoleObservation? RoleObservation);

public sealed record AssignmentLifecycleDiagnostics(
    long ProcessedEventCount,
    long ConsumedSequenceCount,
    long AppliedEventCount,
    long DuplicateEventCount,
    long ConflictEventCount,
    long SequenceGapCount,
    long OrphanEventCount,
    long InvalidTransitionCount,
    long DuplicateHandoffCount,
    int CurrentTaskCount,
    int RelationshipCount,
    int RoleObservationCount,
    long LastSequence);

public sealed record AssignmentLifecycleReplayResult(
    int ContractVersion,
    IReadOnlyList<AssignmentLifecycleStep> Steps,
    IReadOnlyList<AssignmentLifecycleAuditEntry> AuditTrail,
    IReadOnlyList<AssignmentTaskSnapshot> CurrentTasks,
    IReadOnlyList<AssignmentRoleRelationship> Relationships,
    IReadOnlyList<AssignmentActorRoleObservation> RoleHistory,
    IReadOnlyList<AssignmentCurrentActorRole> CurrentRoles,
    AssignmentLifecycleDiagnostics Diagnostics,
    string ResultSha256);

public sealed class AssignmentLifecycleContractException : ArgumentException
{
    public AssignmentLifecycleContractException(string message)
        : base(message)
    {
    }
}

public sealed class AssignmentLifecycleReplayException : ArgumentException
{
    public AssignmentLifecycleReplayException(string message)
        : base(message)
    {
    }
}
