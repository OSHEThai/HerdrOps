using HerdrOps.Domain.Activity;

namespace HerdrOps.Domain.Assignments;

public static class AssignmentLifecycleContract
{
    public const int Version = 1;
    public const string CoreSource = "HerdrOps.Core";
    public const int MaximumIdentifierLength = 128;
    public const int MaximumTaskIdentifierLength = 64;
    public const int MaximumTextLength = 2048;

    public static NormalizedAssignmentLifecycleEvent NormalizeAndValidate(
        AssignmentLifecycleEvent lifecycleEvent)
    {
        ArgumentNullException.ThrowIfNull(lifecycleEvent);
        if (lifecycleEvent.ContractVersion != Version)
        {
            throw new AssignmentLifecycleContractException(
                $"Assignment lifecycle contract v{lifecycleEvent.ContractVersion} is unsupported; expected v{Version}.");
        }

        ValidateEnum(lifecycleEvent.EventKind, nameof(lifecycleEvent.EventKind));
        if (lifecycleEvent.EventId == Guid.Empty)
        {
            throw new AssignmentLifecycleContractException("EventId cannot be empty.");
        }

        if (lifecycleEvent.Sequence <= 0)
        {
            throw new AssignmentLifecycleContractException(
                "The Core acceptance sequence must be positive.");
        }

        EnsureUtc(lifecycleEvent.OccurredUtc, nameof(lifecycleEvent.OccurredUtc));
        EnsureUtc(lifecycleEvent.AcceptedUtc, nameof(lifecycleEvent.AcceptedUtc));
        if (lifecycleEvent.AcceptedUtc < lifecycleEvent.OccurredUtc)
        {
            throw new AssignmentLifecycleContractException(
                "AcceptedUtc cannot precede OccurredUtc.");
        }

        if (!string.Equals(lifecycleEvent.Source, CoreSource, StringComparison.Ordinal))
        {
            throw new AssignmentLifecycleContractException(
                $"The assignment lifecycle source must be {CoreSource}.");
        }

        if (lifecycleEvent.CorrelationId == Guid.Empty)
        {
            throw new AssignmentLifecycleContractException("CorrelationId cannot be empty.");
        }

        var normalized = lifecycleEvent with
        {
            EventSha256 = NormalizeSha256(
                lifecycleEvent.EventSha256,
                nameof(lifecycleEvent.EventSha256)),
            TaskId = RequireIdentifier(
                lifecycleEvent.TaskId,
                nameof(lifecycleEvent.TaskId),
                MaximumTaskIdentifierLength),
            ActorId = RequireIdentifier(
                lifecycleEvent.ActorId,
                nameof(lifecycleEvent.ActorId),
                MaximumIdentifierLength),
            ActorRole = RequireText(
                lifecycleEvent.ActorRole,
                nameof(lifecycleEvent.ActorRole),
                MaximumIdentifierLength),
            Summary = RequireText(
                lifecycleEvent.Summary,
                nameof(lifecycleEvent.Summary),
                MaximumTextLength),
            TargetAgentId = NormalizeOptionalIdentifier(
                lifecycleEvent.TargetAgentId,
                nameof(lifecycleEvent.TargetAgentId)),
            DeviationReason = NormalizeOptionalText(
                lifecycleEvent.DeviationReason,
                nameof(lifecycleEvent.DeviationReason)),
            EvidenceReference = NormalizeOptionalText(
                lifecycleEvent.EvidenceReference,
                nameof(lifecycleEvent.EvidenceReference)),
            EvidenceSha256 = NormalizeOptionalSha256(
                lifecycleEvent.EvidenceSha256,
                nameof(lifecycleEvent.EvidenceSha256)),
            HandoffNote = NormalizeOptionalText(
                lifecycleEvent.HandoffNote,
                nameof(lifecycleEvent.HandoffNote)),
        };
        if (normalized.ParentEventId == Guid.Empty)
        {
            throw new AssignmentLifecycleContractException(
                "ParentEventId cannot be empty when supplied.");
        }

        if (normalized.ProgressPercent is < 0 or > 100)
        {
            throw new AssignmentLifecycleContractException(
                "ProgressPercent must be from 0 through 100.");
        }

        ValidateEventSpecificFields(normalized);
        return new NormalizedAssignmentLifecycleEvent(
            normalized,
            ComputeEventSha256(normalized));
    }

    public static AssignmentTaskSnapshot CreateTaskSnapshot(AssignmentTaskState state)
    {
        ArgumentNullException.ThrowIfNull(state);
        ValidateTaskState(state);
        using var writer = new CanonicalHashWriter("HerdrOps.AssignmentTaskState.v1");
        WriteTaskState(writer, state);
        return new AssignmentTaskSnapshot(state, writer.Finish());
    }

    public static void ValidateTaskSnapshot(AssignmentTaskSnapshot snapshot)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        var expected = CreateTaskSnapshot(snapshot.State);
        if (!string.Equals(expected.StateSha256, snapshot.StateSha256, StringComparison.Ordinal))
        {
            throw new AssignmentLifecycleContractException(
                "The assignment task state hash does not match its fields.");
        }
    }

    public static AssignmentRoleRelationship CreateRelationship(
        NormalizedAssignmentLifecycleEvent normalizedEvent,
        AssignmentRelationshipKind relationshipKind,
        string targetActorId)
    {
        ArgumentNullException.ThrowIfNull(normalizedEvent);
        ValidateEnum(relationshipKind, nameof(relationshipKind));
        var lifecycleEvent = normalizedEvent.Event;
        var normalizedTarget = RequireIdentifier(
            targetActorId,
            nameof(targetActorId),
            MaximumIdentifierLength);
        using var writer = new CanonicalHashWriter("HerdrOps.AssignmentRelationship.v1");
        writer.Write(Version);
        writer.Write(lifecycleEvent.EventId.ToString("D"));
        writer.Write((int)relationshipKind);
        writer.Write(lifecycleEvent.TaskId);
        writer.Write(lifecycleEvent.ActorId);
        writer.Write(lifecycleEvent.ActorRole);
        writer.Write(normalizedTarget);
        writer.Write(lifecycleEvent.EventId.ToString("D"));
        writer.Write(lifecycleEvent.Sequence);
        writer.Write(lifecycleEvent.OccurredUtc);
        writer.Write(lifecycleEvent.AcceptedUtc);
        writer.Write(normalizedEvent.LifecycleEventSha256);
        var hash = writer.Finish();
        return new AssignmentRoleRelationship(
            Version,
            lifecycleEvent.EventId,
            relationshipKind,
            lifecycleEvent.TaskId,
            lifecycleEvent.ActorId,
            lifecycleEvent.ActorRole,
            normalizedTarget,
            lifecycleEvent.EventId,
            lifecycleEvent.Sequence,
            lifecycleEvent.OccurredUtc,
            lifecycleEvent.AcceptedUtc,
            normalizedEvent.LifecycleEventSha256,
            hash);
    }

    public static AssignmentActorRoleObservation CreateRoleObservation(
        NormalizedAssignmentLifecycleEvent normalizedEvent)
    {
        ArgumentNullException.ThrowIfNull(normalizedEvent);
        var lifecycleEvent = normalizedEvent.Event;
        using var writer = new CanonicalHashWriter("HerdrOps.AssignmentActorRoleObservation.v1");
        writer.Write(Version);
        writer.Write(lifecycleEvent.ActorId);
        writer.Write(lifecycleEvent.ActorRole);
        writer.Write(lifecycleEvent.TaskId);
        writer.Write(lifecycleEvent.EventId.ToString("D"));
        writer.Write(lifecycleEvent.Sequence);
        writer.Write(lifecycleEvent.AcceptedUtc);
        writer.Write(normalizedEvent.LifecycleEventSha256);
        var hash = writer.Finish();
        return new AssignmentActorRoleObservation(
            Version,
            lifecycleEvent.ActorId,
            lifecycleEvent.ActorRole,
            lifecycleEvent.TaskId,
            lifecycleEvent.EventId,
            lifecycleEvent.Sequence,
            lifecycleEvent.AcceptedUtc,
            normalizedEvent.LifecycleEventSha256,
            hash);
    }

    public static void ValidateRelationship(
        AssignmentRoleRelationship relationship,
        NormalizedAssignmentLifecycleEvent normalizedEvent)
    {
        ArgumentNullException.ThrowIfNull(relationship);
        ArgumentNullException.ThrowIfNull(normalizedEvent);
        var expected = CreateRelationship(
            normalizedEvent,
            relationship.RelationshipKind,
            relationship.ToActorId);
        if (expected != relationship)
        {
            throw new AssignmentLifecycleContractException(
                "The assignment relationship does not match its event provenance.");
        }
    }

    public static void ValidateRoleObservation(
        AssignmentActorRoleObservation observation,
        NormalizedAssignmentLifecycleEvent normalizedEvent)
    {
        ArgumentNullException.ThrowIfNull(observation);
        ArgumentNullException.ThrowIfNull(normalizedEvent);
        var expected = CreateRoleObservation(normalizedEvent);
        if (expected != observation)
        {
            throw new AssignmentLifecycleContractException(
                "The assignment role observation does not match its event provenance.");
        }
    }

    public static AssignmentCurrentActorRole CreateCurrentRole(
        AssignmentActorRoleObservation observation)
    {
        ArgumentNullException.ThrowIfNull(observation);
        using var writer = new CanonicalHashWriter("HerdrOps.AssignmentCurrentActorRole.v1");
        writer.Write(Version);
        writer.Write(observation.ActorId);
        writer.Write(observation.ActorRole);
        writer.Write(observation.TaskId);
        writer.Write(observation.EventId.ToString("D"));
        writer.Write(observation.Sequence);
        writer.Write(observation.AcceptedUtc);
        writer.Write(observation.ProvenanceEventSha256);
        var hash = writer.Finish();
        return new AssignmentCurrentActorRole(
            Version,
            observation.ActorId,
            observation.ActorRole,
            observation.TaskId,
            observation.EventId,
            observation.Sequence,
            observation.AcceptedUtc,
            observation.ProvenanceEventSha256,
            hash);
    }

    public static void ValidateCurrentRole(
        AssignmentCurrentActorRole currentRole,
        AssignmentActorRoleObservation observation)
    {
        ArgumentNullException.ThrowIfNull(currentRole);
        ArgumentNullException.ThrowIfNull(observation);
        var expected = CreateCurrentRole(observation);
        if (expected != currentRole)
        {
            throw new AssignmentLifecycleContractException(
                "The current assignment actor role does not match its provenance observation.");
        }
    }

    public static AssignmentLifecycleAuditEntry CreateAuditEntry(
        NormalizedAssignmentLifecycleEvent normalizedEvent,
        AssignmentLifecycleDisposition disposition,
        bool consumesSequence,
        string code,
        string message,
        string? priorTaskStateSha256,
        string? resultTaskStateSha256)
    {
        ArgumentNullException.ThrowIfNull(normalizedEvent);
        ValidateEnum(disposition, nameof(disposition));
        var normalizedCode = RequireIdentifier(code, nameof(code), 64);
        var normalizedMessage = RequireText(message, nameof(message), MaximumTextLength);
        var priorHash = NormalizeOptionalSha256(
            priorTaskStateSha256,
            nameof(priorTaskStateSha256));
        var resultHash = NormalizeOptionalSha256(
            resultTaskStateSha256,
            nameof(resultTaskStateSha256));
        var lifecycleEvent = normalizedEvent.Event;
        using var writer = new CanonicalHashWriter("HerdrOps.AssignmentLifecycleAudit.v1");
        writer.Write(Version);
        writer.Write(lifecycleEvent.EventId.ToString("D"));
        writer.Write((int)lifecycleEvent.EventKind);
        writer.Write(lifecycleEvent.Sequence);
        writer.Write(lifecycleEvent.TaskId);
        writer.Write((int)disposition);
        writer.Write(consumesSequence);
        writer.Write(normalizedCode);
        writer.Write(normalizedMessage);
        writer.Write(lifecycleEvent.AcceptedUtc);
        writer.Write(normalizedEvent.LifecycleEventSha256);
        writer.Write(priorHash);
        writer.Write(resultHash);
        var hash = writer.Finish();
        return new AssignmentLifecycleAuditEntry(
            Version,
            lifecycleEvent.EventId,
            lifecycleEvent.EventKind,
            lifecycleEvent.Sequence,
            lifecycleEvent.TaskId,
            disposition,
            consumesSequence,
            normalizedCode,
            normalizedMessage,
            lifecycleEvent.AcceptedUtc,
            normalizedEvent.LifecycleEventSha256,
            priorHash,
            resultHash,
            hash);
    }

    public static void ValidateAuditEntry(AssignmentLifecycleAuditEntry audit)
    {
        ArgumentNullException.ThrowIfNull(audit);
        if (audit.ContractVersion != Version ||
            audit.EventId == Guid.Empty ||
            audit.Sequence <= 0)
        {
            throw new AssignmentLifecycleContractException(
                "The assignment lifecycle audit identity is invalid.");
        }

        ValidateEnum(audit.EventKind, nameof(audit.EventKind));
        ValidateEnum(audit.Disposition, nameof(audit.Disposition));
        var placeholderEvent = new AssignmentLifecycleEvent(
            Version,
            audit.EventId,
            audit.EventKind,
            audit.Sequence,
            audit.AcceptedUtc,
            audit.AcceptedUtc,
            CoreSource,
            Guid.Parse("00000000-0000-0000-0000-000000000001"),
            new string('0', 64),
            audit.TaskId,
            "audit-validator",
            "Audit Validator",
            "Validate persisted audit identity.",
            audit.EventKind == AssignmentLifecycleEventKind.Assignment
                ? null
                : Guid.Parse("00000000-0000-0000-0000-000000000002"),
            audit.EventKind is AssignmentLifecycleEventKind.Assignment or
                AssignmentLifecycleEventKind.Delegation or
                AssignmentLifecycleEventKind.Handoff
                    ? "audit-target"
                    : null,
            audit.EventKind == AssignmentLifecycleEventKind.Progress ? 0 : null,
            audit.EventKind == AssignmentLifecycleEventKind.Deviation ? "Audit reason." : null,
            audit.EventKind == AssignmentLifecycleEventKind.Evidence ? "audit/evidence" : null,
            audit.EventKind == AssignmentLifecycleEventKind.Evidence ? new string('0', 64) : null,
            audit.EventKind == AssignmentLifecycleEventKind.Handoff ? "Audit handoff." : null);
        var normalizedPlaceholder = new NormalizedAssignmentLifecycleEvent(
            placeholderEvent,
            NormalizeSha256(audit.LifecycleEventSha256, nameof(audit.LifecycleEventSha256)));
        var expected = CreateAuditEntry(
            normalizedPlaceholder,
            audit.Disposition,
            audit.ConsumesSequence,
            audit.Code,
            audit.Message,
            audit.PriorTaskStateSha256,
            audit.ResultTaskStateSha256);
        if (!string.Equals(expected.AuditSha256, audit.AuditSha256, StringComparison.Ordinal))
        {
            throw new AssignmentLifecycleContractException(
                "The assignment lifecycle audit hash does not match its fields.");
        }
    }

    internal static string ComputeReplayResultSha256(
        IReadOnlyList<AssignmentLifecycleStep> steps,
        IReadOnlyList<AssignmentLifecycleAuditEntry> auditTrail,
        IReadOnlyList<AssignmentTaskSnapshot> tasks,
        IReadOnlyList<AssignmentRoleRelationship> relationships,
        IReadOnlyList<AssignmentActorRoleObservation> roleHistory,
        IReadOnlyList<AssignmentCurrentActorRole> currentRoles,
        AssignmentLifecycleDiagnostics diagnostics)
    {
        using var writer = new CanonicalHashWriter("HerdrOps.AssignmentLifecycleReplay.v1");
        writer.Write(Version);
        writer.Write(steps.Count);
        foreach (var step in steps)
        {
            writer.Write(step.Audit.AuditSha256);
        }

        writer.Write(auditTrail.Count);
        foreach (var audit in auditTrail)
        {
            writer.Write(audit.AuditSha256);
        }

        writer.Write(tasks.Count);
        foreach (var task in tasks)
        {
            writer.Write(task.StateSha256);
        }

        writer.Write(relationships.Count);
        foreach (var relationship in relationships)
        {
            writer.Write(relationship.RelationshipSha256);
        }

        writer.Write(roleHistory.Count);
        foreach (var observation in roleHistory)
        {
            writer.Write(observation.ObservationSha256);
        }

        writer.Write(currentRoles.Count);
        foreach (var role in currentRoles)
        {
            writer.Write(role.StateSha256);
        }

        writer.Write(diagnostics.ProcessedEventCount);
        writer.Write(diagnostics.ConsumedSequenceCount);
        writer.Write(diagnostics.AppliedEventCount);
        writer.Write(diagnostics.DuplicateEventCount);
        writer.Write(diagnostics.ConflictEventCount);
        writer.Write(diagnostics.SequenceGapCount);
        writer.Write(diagnostics.OrphanEventCount);
        writer.Write(diagnostics.InvalidTransitionCount);
        writer.Write(diagnostics.DuplicateHandoffCount);
        writer.Write(diagnostics.CurrentTaskCount);
        writer.Write(diagnostics.RelationshipCount);
        writer.Write(diagnostics.RoleObservationCount);
        writer.Write(diagnostics.LastSequence);
        return writer.Finish();
    }

    private static string ComputeEventSha256(AssignmentLifecycleEvent lifecycleEvent)
    {
        using var writer = new CanonicalHashWriter("HerdrOps.AssignmentLifecycleEvent.v1");
        writer.Write(lifecycleEvent.ContractVersion);
        writer.Write(lifecycleEvent.EventId.ToString("D"));
        writer.Write((int)lifecycleEvent.EventKind);
        writer.Write(lifecycleEvent.Sequence);
        writer.Write(lifecycleEvent.OccurredUtc);
        writer.Write(lifecycleEvent.AcceptedUtc);
        writer.Write(lifecycleEvent.Source);
        writer.Write(lifecycleEvent.CorrelationId.ToString("D"));
        writer.Write(lifecycleEvent.EventSha256);
        writer.Write(lifecycleEvent.TaskId);
        writer.Write(lifecycleEvent.ActorId);
        writer.Write(lifecycleEvent.ActorRole);
        writer.Write(lifecycleEvent.Summary);
        writer.Write(lifecycleEvent.ParentEventId?.ToString("D"));
        writer.Write(lifecycleEvent.TargetAgentId);
        writer.Write(lifecycleEvent.ProgressPercent);
        writer.Write(lifecycleEvent.DeviationReason);
        writer.Write(lifecycleEvent.EvidenceReference);
        writer.Write(lifecycleEvent.EvidenceSha256);
        writer.Write(lifecycleEvent.HandoffNote);
        return writer.Finish();
    }

    private static void WriteTaskState(CanonicalHashWriter writer, AssignmentTaskState state)
    {
        writer.Write(state.ContractVersion);
        writer.Write(state.TaskId);
        writer.Write(state.Contract.ContractVersion);
        writer.Write(state.Contract.TaskId);
        writer.Write(state.Contract.AssignmentEventId.ToString("D"));
        writer.Write(state.Contract.AssignorActorId);
        writer.Write(state.Contract.AssignorRole);
        writer.Write(state.Contract.InitialAssigneeId);
        writer.Write(state.Contract.Summary);
        writer.Write(state.Contract.CreatedUtc);
        writer.Write(state.Contract.AcceptedUtc);
        writer.Write(state.Contract.CreatedSequence);
        writer.Write(state.Contract.CorrelationId.ToString("D"));
        writer.Write(state.Contract.ProvenanceEventSha256);
        writer.Write((int)state.Status);
        writer.Write(state.CurrentAssigneeId);
        writer.Write(state.CurrentAssigneeRole);
        writer.Write(state.ProgressPercent);
        writer.Write(state.DeviationCount);
        writer.Write(state.EvidenceCount);
        writer.Write(state.HandoffCount);
        writer.Write(state.LastEventId.ToString("D"));
        writer.Write(state.LastSequence);
        writer.Write(state.LastTransitionUtc);
    }

    private static void ValidateTaskState(AssignmentTaskState state)
    {
        if (state.ContractVersion != Version || state.Contract.ContractVersion != Version)
        {
            throw new AssignmentLifecycleContractException(
                "The task and assignment contract versions must match the lifecycle contract.");
        }

        RequireIdentifier(state.TaskId, nameof(state.TaskId), MaximumTaskIdentifierLength);
        if (!string.Equals(state.TaskId, state.Contract.TaskId, StringComparison.Ordinal))
        {
            throw new AssignmentLifecycleContractException(
                "The assignment contract task does not match the task state.");
        }

        ValidateEnum(state.Status, nameof(state.Status));
        RequireIdentifier(
            state.CurrentAssigneeId,
            nameof(state.CurrentAssigneeId),
            MaximumIdentifierLength);
        if (state.CurrentAssigneeRole is not null)
        {
            RequireText(
                state.CurrentAssigneeRole,
                nameof(state.CurrentAssigneeRole),
                MaximumIdentifierLength);
        }

        if (state.ProgressPercent is < 0 or > 100 ||
            state.DeviationCount < 0 ||
            state.EvidenceCount < 0 ||
            state.HandoffCount < 0 ||
            state.LastEventId == Guid.Empty ||
            state.LastSequence <= 0)
        {
            throw new AssignmentLifecycleContractException(
                "The assignment task counters or last-event identity are invalid.");
        }

        EnsureUtc(state.LastTransitionUtc, nameof(state.LastTransitionUtc));
        if (state.Contract.AssignmentEventId == Guid.Empty ||
            state.Contract.CorrelationId == Guid.Empty ||
            state.Contract.CreatedSequence <= 0)
        {
            throw new AssignmentLifecycleContractException(
                "The assignment contract provenance identity is invalid.");
        }

        RequireIdentifier(
            state.Contract.AssignorActorId,
            nameof(state.Contract.AssignorActorId),
            MaximumIdentifierLength);
        RequireText(
            state.Contract.AssignorRole,
            nameof(state.Contract.AssignorRole),
            MaximumIdentifierLength);
        RequireIdentifier(
            state.Contract.InitialAssigneeId,
            nameof(state.Contract.InitialAssigneeId),
            MaximumIdentifierLength);
        RequireText(
            state.Contract.Summary,
            nameof(state.Contract.Summary),
            MaximumTextLength);
        EnsureUtc(state.Contract.CreatedUtc, nameof(state.Contract.CreatedUtc));
        EnsureUtc(state.Contract.AcceptedUtc, nameof(state.Contract.AcceptedUtc));
        if (state.Contract.AcceptedUtc < state.Contract.CreatedUtc ||
            state.LastTransitionUtc < state.Contract.AcceptedUtc ||
            state.Contract.CreatedSequence > state.LastSequence)
        {
            throw new AssignmentLifecycleContractException(
                "The assignment task timeline or sequence lineage is invalid.");
        }

        _ = NormalizeSha256(
            state.Contract.ProvenanceEventSha256,
            nameof(state.Contract.ProvenanceEventSha256));
    }

    private static void ValidateEventSpecificFields(AssignmentLifecycleEvent lifecycleEvent)
    {
        switch (lifecycleEvent.EventKind)
        {
            case AssignmentLifecycleEventKind.Assignment:
                RequireTarget(lifecycleEvent);
                if (lifecycleEvent.ParentEventId is not null)
                {
                    throw new AssignmentLifecycleContractException(
                        "An assignment starts a lifecycle and cannot contain ParentEventId.");
                }

                RequireAbsent(lifecycleEvent, progress: true, deviation: true, evidence: true, handoff: true);
                break;
            case AssignmentLifecycleEventKind.Acknowledgement:
                RequireParent(lifecycleEvent);
                RequireAbsent(lifecycleEvent, target: true, progress: true, deviation: true, evidence: true, handoff: true);
                break;
            case AssignmentLifecycleEventKind.Delegation:
                RequireParent(lifecycleEvent);
                RequireTarget(lifecycleEvent);
                RequireAbsent(lifecycleEvent, progress: true, deviation: true, evidence: true, handoff: true);
                break;
            case AssignmentLifecycleEventKind.Progress:
                RequireParent(lifecycleEvent);
                if (lifecycleEvent.ProgressPercent is null)
                {
                    throw new AssignmentLifecycleContractException(
                        "A progress event requires ProgressPercent.");
                }

                RequireAbsent(lifecycleEvent, target: true, deviation: true, evidence: true, handoff: true);
                break;
            case AssignmentLifecycleEventKind.Deviation:
                RequireParent(lifecycleEvent);
                if (lifecycleEvent.DeviationReason is null)
                {
                    throw new AssignmentLifecycleContractException(
                        "A deviation event requires DeviationReason.");
                }

                RequireAbsent(lifecycleEvent, target: true, progress: true, evidence: true, handoff: true);
                break;
            case AssignmentLifecycleEventKind.Evidence:
                RequireParent(lifecycleEvent);
                if (lifecycleEvent.EvidenceReference is null || lifecycleEvent.EvidenceSha256 is null)
                {
                    throw new AssignmentLifecycleContractException(
                        "An evidence event requires EvidenceReference and EvidenceSha256.");
                }

                RequireAbsent(lifecycleEvent, target: true, progress: true, deviation: true, handoff: true);
                break;
            case AssignmentLifecycleEventKind.Handoff:
                RequireParent(lifecycleEvent);
                RequireTarget(lifecycleEvent);
                if (lifecycleEvent.HandoffNote is null)
                {
                    throw new AssignmentLifecycleContractException(
                        "A handoff event requires HandoffNote.");
                }

                RequireAbsent(lifecycleEvent, progress: true, deviation: true, evidence: true);
                break;
            default:
                throw new AssignmentLifecycleContractException(
                    $"Unsupported assignment lifecycle event kind: {lifecycleEvent.EventKind}");
        }
    }

    private static void RequireParent(AssignmentLifecycleEvent lifecycleEvent)
    {
        if (lifecycleEvent.ParentEventId is null)
        {
            throw new AssignmentLifecycleContractException(
                $"A {lifecycleEvent.EventKind} event requires ParentEventId.");
        }
    }

    private static void RequireTarget(AssignmentLifecycleEvent lifecycleEvent)
    {
        if (lifecycleEvent.TargetAgentId is null)
        {
            throw new AssignmentLifecycleContractException(
                $"A {lifecycleEvent.EventKind} event requires TargetAgentId.");
        }
    }

    private static void RequireAbsent(
        AssignmentLifecycleEvent lifecycleEvent,
        bool target = false,
        bool progress = false,
        bool deviation = false,
        bool evidence = false,
        bool handoff = false)
    {
        if ((target && lifecycleEvent.TargetAgentId is not null) ||
            (progress && lifecycleEvent.ProgressPercent is not null) ||
            (deviation && lifecycleEvent.DeviationReason is not null) ||
            (evidence && (lifecycleEvent.EvidenceReference is not null || lifecycleEvent.EvidenceSha256 is not null)) ||
            (handoff && lifecycleEvent.HandoffNote is not null))
        {
            throw new AssignmentLifecycleContractException(
                $"The {lifecycleEvent.EventKind} event contains a field reserved for another event kind.");
        }
    }

    private static void ValidateEnum<T>(T value, string name)
        where T : struct, Enum
    {
        if (!Enum.IsDefined(value))
        {
            throw new AssignmentLifecycleContractException(
                $"Assignment lifecycle field {name} has unsupported value '{value}'.");
        }
    }

    private static string RequireIdentifier(string? value, string name, int maximumLength)
    {
        var normalized = RequireText(value, name, maximumLength);
        if (normalized.Any(character =>
                !(char.IsAsciiLetterOrDigit(character) || character is '-' or '_' or '.' or ':' or '/')))
        {
            throw new AssignmentLifecycleContractException(
                $"{name} contains a character outside the identifier allowlist.");
        }

        return normalized;
    }

    private static string? NormalizeOptionalIdentifier(string? value, string name) =>
        value is null
            ? null
            : RequireIdentifier(value, name, MaximumIdentifierLength);

    private static string RequireText(string? value, string name, int maximumLength)
    {
        if (string.IsNullOrWhiteSpace(value) ||
            value.Length > maximumLength ||
            !string.Equals(value, value.Trim(), StringComparison.Ordinal) ||
            value.Any(char.IsControl))
        {
            throw new AssignmentLifecycleContractException(
                $"{name} must contain 1 to {maximumLength} trimmed, non-control characters.");
        }

        return value;
    }

    private static string? NormalizeOptionalText(string? value, string name) =>
        value is null ? null : RequireText(value, name, MaximumTextLength);

    private static string NormalizeSha256(string? value, string name)
    {
        if (string.IsNullOrWhiteSpace(value) ||
            value.Length != 64 ||
            value.Any(character => !Uri.IsHexDigit(character)))
        {
            throw new AssignmentLifecycleContractException(
                $"{name} must contain exactly 64 hexadecimal characters.");
        }

        return value.ToUpperInvariant();
    }

    private static string? NormalizeOptionalSha256(string? value, string name) =>
        value is null ? null : NormalizeSha256(value, name);

    private static void EnsureUtc(DateTimeOffset value, string name)
    {
        if (value == default || value.Offset != TimeSpan.Zero)
        {
            throw new AssignmentLifecycleContractException(
                $"{name} must be a non-default UTC timestamp.");
        }
    }
}
