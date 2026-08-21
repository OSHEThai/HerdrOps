namespace HerdrOps.Domain.Compliance;

public enum ComplianceReviewerRole
{
    ProjectManager = 1,
    Leader = 2,
}

public enum ComplianceReviewState
{
    Suspected = 1,
    PendingLeader = 2,
    PendingProjectManager = 3,
    Confirmed = 4,
    Dismissed = 5,
}

public enum ComplianceReviewDecisionKind
{
    Confirm = 1,
    SendToLeader = 2,
    EscalateToProjectManager = 3,
    Dismiss = 4,
}

public enum ComplianceReviewRejectionCode
{
    None = 0,
    UnknownAuthority = 1,
    UnauthorizedRole = 2,
    SelfReview = 3,
    StaleState = 4,
    InvalidTransition = 5,
    AuthorityNotYetEffective = 6,
    UnknownIncident = 7,
}

public sealed record ComplianceReviewAuthority(
    string ActorId,
    ComplianceReviewerRole Role,
    Guid ProvenanceEventId,
    long ProvenanceSequence,
    DateTimeOffset AcceptedUtc,
    string ProvenanceSha256);

public sealed record ComplianceReviewIncidentRegistration(
    int ContractVersion,
    string IncidentId,
    string TaskId,
    string SubjectActorId,
    DateTimeOffset RegisteredUtc,
    IReadOnlyList<string> EvidenceIdentitySha256s);

public sealed record ComplianceReviewIncident(
    int ContractVersion,
    string IncidentId,
    string TaskId,
    string SubjectActorId,
    DateTimeOffset RegisteredUtc,
    IReadOnlyList<string> InitialEvidenceIdentitySha256s,
    string RegistrationSha256,
    ComplianceReviewState State,
    long Sequence,
    DateTimeOffset UpdatedUtc,
    Guid? LastAuditEventId,
    string? LastAuditSha256);

public sealed record ComplianceReviewCommand(
    int ContractVersion,
    Guid CommandId,
    string IncidentId,
    ComplianceReviewState ExpectedState,
    long ExpectedSequence,
    string ReviewerActorId,
    ComplianceReviewDecisionKind DecisionKind,
    string Reason,
    DateTimeOffset OccurredUtc,
    IReadOnlyList<string> EvidenceIdentitySha256s);

public sealed record ComplianceReviewAuthorizationResult(
    bool IsAuthorized,
    ComplianceReviewRejectionCode RejectionCode,
    ComplianceReviewState? ResultState,
    string Message);

public sealed record ComplianceReviewAuditEvent(
    int ContractVersion,
    Guid AuditEventId,
    string IncidentId,
    string TaskId,
    string SubjectActorId,
    long Sequence,
    string ReviewerActorId,
    ComplianceReviewerRole ReviewerRole,
    Guid AuthorityProvenanceEventId,
    long AuthorityProvenanceSequence,
    string AuthorityProvenanceSha256,
    ComplianceReviewDecisionKind DecisionKind,
    ComplianceReviewState PreviousState,
    ComplianceReviewState ResultState,
    string Reason,
    DateTimeOffset OccurredUtc,
    IReadOnlyList<string> EvidenceIdentitySha256s,
    string EvidenceSetSha256,
    string? PreviousAuditSha256,
    string AuditSha256);

public static class ComplianceReviewWorkflowContract
{
    public const int ContractVersion = 1;
    public const int MaximumEvidenceLinks = 256;
    public const int MaximumReasonLength = 2048;
    public static bool IsTerminal(ComplianceReviewState state) =>
        state is ComplianceReviewState.Confirmed or ComplianceReviewState.Dismissed;

    public static bool IsOpen(ComplianceReviewState state) =>
        !IsTerminal(state);


    private static readonly HashSet<string> LeaderAssignmentRoles =
        new(StringComparer.Ordinal)
        {
            "Leader",
            "Backend Leader",
            "Frontend Leader",
            "Test Leader",
            "DevOps Leader",
            "Security Leader",
            "Data Leader",
            "Documentation Leader",
        };

    public static string NormalizeIncidentId(string incidentId) =>
        ComplianceEvaluationContract.NormalizeIdentifier(
            incidentId,
            nameof(incidentId));

    public static string NormalizeActorId(string actorId) =>
        ComplianceEvaluationContract.NormalizeIdentifier(
            actorId,
            nameof(actorId));

    public static bool TryMapAssignmentRole(
        string assignmentRole,
        out ComplianceReviewerRole reviewerRole)
    {
        if (string.Equals(assignmentRole, "Project Manager", StringComparison.Ordinal))
        {
            reviewerRole = ComplianceReviewerRole.ProjectManager;
            return true;
        }

        if (LeaderAssignmentRoles.Contains(assignmentRole))
        {
            reviewerRole = ComplianceReviewerRole.Leader;
            return true;
        }

        reviewerRole = default;
        return false;
    }

    public static ComplianceReviewIncident CreateIncident(
        ComplianceReviewIncidentRegistration registration)
    {
        var normalized = NormalizeRegistration(registration);
        var registrationSha256 = ComputeRegistrationSha256(normalized);
        return new ComplianceReviewIncident(
            ContractVersion,
            normalized.IncidentId,
            normalized.TaskId,
            normalized.SubjectActorId,
            normalized.RegisteredUtc,
            normalized.EvidenceIdentitySha256s,
            registrationSha256,
            ComplianceReviewState.Suspected,
            Sequence: 0,
            normalized.RegisteredUtc,
            LastAuditEventId: null,
            LastAuditSha256: null);
    }

    public static ComplianceReviewIncident NormalizeAndValidateIncident(
        ComplianceReviewIncident incident)
    {
        ArgumentNullException.ThrowIfNull(incident);
        var registration = NormalizeRegistration(new ComplianceReviewIncidentRegistration(
            incident.ContractVersion,
            incident.IncidentId,
            incident.TaskId,
            incident.SubjectActorId,
            incident.RegisteredUtc,
            incident.InitialEvidenceIdentitySha256s));
        var registrationSha256 = ComplianceEvaluationContract.NormalizeSha256(
            incident.RegistrationSha256,
            nameof(incident.RegistrationSha256));
        if (!string.Equals(
                registrationSha256,
                ComputeRegistrationSha256(registration),
                StringComparison.Ordinal))
        {
            throw new ComplianceReviewContractException(
                "The compliance review registration SHA-256 does not match its immutable fields.");
        }

        if (!Enum.IsDefined(incident.State) || incident.Sequence < 0)
        {
            throw new ComplianceReviewContractException(
                "The compliance review incident has an unsupported state or negative sequence.");
        }

        var updatedUtc = EnsureUtc(incident.UpdatedUtc, nameof(incident.UpdatedUtc));
        if (updatedUtc < registration.RegisteredUtc ||
            (incident.Sequence == 0) != (incident.LastAuditEventId is null) ||
            (incident.Sequence == 0) != (incident.LastAuditSha256 is null) ||
            (incident.Sequence == 0 && incident.State != ComplianceReviewState.Suspected))
        {
            throw new ComplianceReviewContractException(
                "The compliance review incident sequence, state, audit pointer, or timestamps are inconsistent.");
        }

        if (incident.LastAuditEventId == Guid.Empty)
        {
            throw new ComplianceReviewContractException(
                "The last review audit event ID cannot be empty.");
        }

        var lastAuditSha256 = incident.LastAuditSha256 is null
            ? null
            : ComplianceEvaluationContract.NormalizeSha256(
                incident.LastAuditSha256,
                nameof(incident.LastAuditSha256));
        return incident with
        {
            IncidentId = registration.IncidentId,
            TaskId = registration.TaskId,
            SubjectActorId = registration.SubjectActorId,
            RegisteredUtc = registration.RegisteredUtc,
            InitialEvidenceIdentitySha256s = registration.EvidenceIdentitySha256s,
            RegistrationSha256 = registrationSha256,
            UpdatedUtc = updatedUtc,
            LastAuditSha256 = lastAuditSha256,
        };
    }

    public static ComplianceReviewAuthority NormalizeAuthority(
        ComplianceReviewAuthority authority)
    {
        ArgumentNullException.ThrowIfNull(authority);
        if (!Enum.IsDefined(authority.Role) ||
            authority.ProvenanceEventId == Guid.Empty ||
            authority.ProvenanceSequence <= 0)
        {
            throw new ComplianceReviewContractException(
                "Review authority requires a supported role and non-empty provenance.");
        }

        return authority with
        {
            ActorId = NormalizeActorId(authority.ActorId),
            AcceptedUtc = EnsureUtc(authority.AcceptedUtc, nameof(authority.AcceptedUtc)),
            ProvenanceSha256 = ComplianceEvaluationContract.NormalizeSha256(
                authority.ProvenanceSha256,
                nameof(authority.ProvenanceSha256)),
        };
    }

    public static ComplianceReviewCommand NormalizeCommand(
        ComplianceReviewCommand command)
    {
        ArgumentNullException.ThrowIfNull(command);
        if (command.ContractVersion != ContractVersion ||
            command.CommandId == Guid.Empty ||
            command.ExpectedSequence < 0 ||
            !Enum.IsDefined(command.ExpectedState) ||
            !Enum.IsDefined(command.DecisionKind))
        {
            throw new ComplianceReviewContractException(
                "Review command has an unsupported contract, empty ID, state, or decision.");
        }

        return command with
        {
            IncidentId = ComplianceEvaluationContract.NormalizeIdentifier(
                command.IncidentId,
                nameof(command.IncidentId)),
            ReviewerActorId = NormalizeActorId(command.ReviewerActorId),
            Reason = NormalizeReason(command.Reason),
            OccurredUtc = EnsureUtc(command.OccurredUtc, nameof(command.OccurredUtc)),
            EvidenceIdentitySha256s = NormalizeEvidenceSet(command.EvidenceIdentitySha256s),
        };
    }

    public static ComplianceReviewAuthorizationResult Authorize(
        ComplianceReviewIncident incident,
        ComplianceReviewCommand command,
        ComplianceReviewAuthority? authority)
    {
        var normalizedIncident = NormalizeAndValidateIncident(incident);
        var normalizedCommand = NormalizeCommand(command);
        if (!string.Equals(
                normalizedIncident.IncidentId,
                normalizedCommand.IncidentId,
                StringComparison.Ordinal))
        {
            throw new ComplianceReviewContractException(
                "The review command targets a different incident.");
        }

        if (authority is null)
        {
            return Rejected(
                ComplianceReviewRejectionCode.UnknownAuthority,
                "No authoritative reviewer role is available.");
        }

        var normalizedAuthority = NormalizeAuthority(authority);
        if (!string.Equals(
                normalizedAuthority.ActorId,
                normalizedCommand.ReviewerActorId,
                StringComparison.Ordinal))
        {
            return Rejected(
                ComplianceReviewRejectionCode.UnknownAuthority,
                "The command reviewer does not match the authoritative actor identity.");
        }

        if (string.Equals(
                normalizedIncident.SubjectActorId,
                normalizedCommand.ReviewerActorId,
                StringComparison.Ordinal))
        {
            return Rejected(
                ComplianceReviewRejectionCode.SelfReview,
                "An incident subject cannot review their own incident.");
        }

        if (normalizedCommand.ExpectedState != normalizedIncident.State ||
            normalizedCommand.ExpectedSequence != normalizedIncident.Sequence)
        {
            return Rejected(
                ComplianceReviewRejectionCode.StaleState,
                "The expected incident state or sequence is stale.");
        }

        if (normalizedAuthority.AcceptedUtc > normalizedCommand.OccurredUtc)
        {
            return Rejected(
                ComplianceReviewRejectionCode.AuthorityNotYetEffective,
                "Reviewer authority was accepted after the requested decision time.");
        }

        var resultState = ResolveTransition(
            normalizedIncident.State,
            normalizedAuthority.Role,
            normalizedCommand.DecisionKind);
        return resultState is null
            ? Rejected(
                IsActionAllowedForRole(normalizedAuthority.Role, normalizedCommand.DecisionKind)
                    ? ComplianceReviewRejectionCode.InvalidTransition
                    : ComplianceReviewRejectionCode.UnauthorizedRole,
                IsActionAllowedForRole(normalizedAuthority.Role, normalizedCommand.DecisionKind)
                    ? "The requested review decision is invalid from the current incident state."
                    : "The authoritative reviewer role is not allowed to perform this decision.")
            : new ComplianceReviewAuthorizationResult(
                IsAuthorized: true,
                ComplianceReviewRejectionCode.None,
                resultState,
                "The review decision is authorized.");
    }

    public static ComplianceReviewAuditEvent CreateAuditEvent(
        ComplianceReviewIncident incident,
        ComplianceReviewCommand command,
        ComplianceReviewAuthority authority)
    {
        var normalizedIncident = NormalizeAndValidateIncident(incident);
        var normalizedCommand = NormalizeCommand(command);
        var normalizedAuthority = NormalizeAuthority(authority);
        var authorization = Authorize(
            normalizedIncident,
            normalizedCommand,
            normalizedAuthority);
        if (!authorization.IsAuthorized || authorization.ResultState is null)
        {
            throw new ComplianceReviewRejectedException(
                authorization.RejectionCode,
                authorization.Message);
        }

        var evidenceSetSha256 = ComputeEvidenceSetSha256(
            normalizedCommand.EvidenceIdentitySha256s);
        var candidate = new ComplianceReviewAuditEvent(
            ContractVersion,
            normalizedCommand.CommandId,
            normalizedIncident.IncidentId,
            normalizedIncident.TaskId,
            normalizedIncident.SubjectActorId,
            normalizedIncident.Sequence + 1,
            normalizedCommand.ReviewerActorId,
            normalizedAuthority.Role,
            normalizedAuthority.ProvenanceEventId,
            normalizedAuthority.ProvenanceSequence,
            normalizedAuthority.ProvenanceSha256,
            normalizedCommand.DecisionKind,
            normalizedIncident.State,
            authorization.ResultState.Value,
            normalizedCommand.Reason,
            normalizedCommand.OccurredUtc,
            normalizedCommand.EvidenceIdentitySha256s,
            evidenceSetSha256,
            normalizedIncident.LastAuditSha256,
            string.Empty);
        return candidate with { AuditSha256 = ComputeAuditSha256(candidate) };
    }

    public static ComplianceReviewAuditEvent NormalizeAndValidateAuditEvent(
        ComplianceReviewAuditEvent auditEvent)
    {
        ArgumentNullException.ThrowIfNull(auditEvent);
        var priorIncident = new ComplianceReviewIncident(
            ContractVersion,
            auditEvent.IncidentId,
            auditEvent.TaskId,
            auditEvent.SubjectActorId,
            auditEvent.OccurredUtc,
            Array.Empty<string>(),
            ComputeRegistrationSha256(new ComplianceReviewIncidentRegistration(
                ContractVersion,
                auditEvent.IncidentId,
                auditEvent.TaskId,
                auditEvent.SubjectActorId,
                auditEvent.OccurredUtc,
                Array.Empty<string>())),
            auditEvent.PreviousState,
            auditEvent.Sequence - 1,
            auditEvent.OccurredUtc,
            auditEvent.Sequence == 1 ? null : auditEvent.AuditEventId,
            auditEvent.PreviousAuditSha256);
        var command = new ComplianceReviewCommand(
            auditEvent.ContractVersion,
            auditEvent.AuditEventId,
            auditEvent.IncidentId,
            auditEvent.PreviousState,
            auditEvent.Sequence - 1,
            auditEvent.ReviewerActorId,
            auditEvent.DecisionKind,
            auditEvent.Reason,
            auditEvent.OccurredUtc,
            auditEvent.EvidenceIdentitySha256s);
        var authority = new ComplianceReviewAuthority(
            auditEvent.ReviewerActorId,
            auditEvent.ReviewerRole,
            auditEvent.AuthorityProvenanceEventId,
            auditEvent.AuthorityProvenanceSequence,
            auditEvent.OccurredUtc,
            auditEvent.AuthorityProvenanceSha256);
        var expected = CreateAuditEvent(priorIncident, command, authority);
        var evidenceSetSha256 = ComplianceEvaluationContract.NormalizeSha256(
            auditEvent.EvidenceSetSha256,
            nameof(auditEvent.EvidenceSetSha256));
        var auditSha256 = ComplianceEvaluationContract.NormalizeSha256(
            auditEvent.AuditSha256,
            nameof(auditEvent.AuditSha256));
        if (auditEvent.Sequence <= 0 ||
            auditEvent.ResultState != expected.ResultState ||
            !string.Equals(evidenceSetSha256, expected.EvidenceSetSha256, StringComparison.Ordinal) ||
            !string.Equals(auditSha256, expected.AuditSha256, StringComparison.Ordinal))
        {
            throw new ComplianceReviewContractException(
                "The compliance review audit event does not match its canonical transition or hashes.");
        }

        return expected;
    }

    public static ComplianceReviewIncident Apply(
        ComplianceReviewIncident incident,
        ComplianceReviewAuditEvent auditEvent)
    {
        var normalizedIncident = NormalizeAndValidateIncident(incident);
        var normalizedEvent = NormalizeAndValidateAuditEvent(auditEvent);
        if (!string.Equals(normalizedIncident.IncidentId, normalizedEvent.IncidentId, StringComparison.Ordinal) ||
            !string.Equals(normalizedIncident.TaskId, normalizedEvent.TaskId, StringComparison.Ordinal) ||
            !string.Equals(normalizedIncident.SubjectActorId, normalizedEvent.SubjectActorId, StringComparison.Ordinal) ||
            normalizedEvent.Sequence != normalizedIncident.Sequence + 1 ||
            normalizedEvent.PreviousState != normalizedIncident.State ||
            normalizedEvent.OccurredUtc < normalizedIncident.UpdatedUtc ||
            !string.Equals(
                normalizedEvent.PreviousAuditSha256,
                normalizedIncident.LastAuditSha256,
                StringComparison.Ordinal))
        {
            throw new ComplianceReviewContractException(
                "The compliance review audit event is not the next event for this incident.");
        }

        return normalizedIncident with
        {
            State = normalizedEvent.ResultState,
            Sequence = normalizedEvent.Sequence,
            UpdatedUtc = normalizedEvent.OccurredUtc,
            LastAuditEventId = normalizedEvent.AuditEventId,
            LastAuditSha256 = normalizedEvent.AuditSha256,
        };
    }

    private static ComplianceReviewIncidentRegistration NormalizeRegistration(
        ComplianceReviewIncidentRegistration registration)
    {
        ArgumentNullException.ThrowIfNull(registration);
        if (registration.ContractVersion != ContractVersion)
        {
            throw new ComplianceReviewContractException(
                $"Unsupported compliance review contract v{registration.ContractVersion}; expected v{ContractVersion}.");
        }

        return registration with
        {
            IncidentId = ComplianceEvaluationContract.NormalizeIdentifier(
                registration.IncidentId,
                nameof(registration.IncidentId)),
            TaskId = ComplianceEvaluationContract.NormalizeIdentifier(
                registration.TaskId,
                nameof(registration.TaskId)),
            SubjectActorId = NormalizeActorId(registration.SubjectActorId),
            RegisteredUtc = EnsureUtc(registration.RegisteredUtc, nameof(registration.RegisteredUtc)),
            EvidenceIdentitySha256s = NormalizeEvidenceSet(
                registration.EvidenceIdentitySha256s),
        };
    }

    private static IReadOnlyList<string> NormalizeEvidenceSet(
        IReadOnlyList<string>? evidenceIdentitySha256s)
    {
        if (evidenceIdentitySha256s is null ||
            evidenceIdentitySha256s.Count > MaximumEvidenceLinks)
        {
            throw new ComplianceReviewContractException(
                $"A compliance review can link at most {MaximumEvidenceLinks} evidence identities.");
        }

        var normalized = evidenceIdentitySha256s
            .Select(item => ComplianceEvaluationContract.NormalizeSha256(item, "EvidenceIdentitySha256"))
            .OrderBy(item => item, StringComparer.Ordinal)
            .ToArray();
        if (normalized.Distinct(StringComparer.Ordinal).Count() != normalized.Length)
        {
            throw new ComplianceReviewContractException(
                "A compliance review evidence set cannot contain duplicate identities.");
        }

        return Array.AsReadOnly(normalized);
    }

    private static string NormalizeReason(string reason)
    {
        var normalized = ComplianceEvaluationContract.NormalizeDetail(reason, nameof(reason));
        if (normalized.Length > MaximumReasonLength)
        {
            throw new ComplianceReviewContractException(
                $"A compliance review reason cannot exceed {MaximumReasonLength} characters.");
        }

        return normalized;
    }

    private static DateTimeOffset EnsureUtc(DateTimeOffset value, string name)
    {
        if (value.Offset != TimeSpan.Zero)
        {
            throw new ComplianceReviewContractException(
                $"Compliance review field {name} must be UTC.");
        }

        return value;
    }

    private static ComplianceReviewState? ResolveTransition(
        ComplianceReviewState state,
        ComplianceReviewerRole role,
        ComplianceReviewDecisionKind decision) => (state, role, decision) switch
        {
            (ComplianceReviewState.Suspected, ComplianceReviewerRole.ProjectManager, ComplianceReviewDecisionKind.Confirm) => ComplianceReviewState.Confirmed,
            (ComplianceReviewState.Suspected, ComplianceReviewerRole.ProjectManager, ComplianceReviewDecisionKind.SendToLeader) => ComplianceReviewState.PendingLeader,
            (ComplianceReviewState.Suspected, ComplianceReviewerRole.ProjectManager, ComplianceReviewDecisionKind.Dismiss) => ComplianceReviewState.Dismissed,
            (ComplianceReviewState.PendingLeader, ComplianceReviewerRole.Leader, ComplianceReviewDecisionKind.EscalateToProjectManager) => ComplianceReviewState.PendingProjectManager,
            (ComplianceReviewState.PendingProjectManager, ComplianceReviewerRole.ProjectManager, ComplianceReviewDecisionKind.Confirm) => ComplianceReviewState.Confirmed,
            (ComplianceReviewState.PendingProjectManager, ComplianceReviewerRole.ProjectManager, ComplianceReviewDecisionKind.SendToLeader) => ComplianceReviewState.PendingLeader,
            (ComplianceReviewState.PendingProjectManager, ComplianceReviewerRole.ProjectManager, ComplianceReviewDecisionKind.Dismiss) => ComplianceReviewState.Dismissed,
            _ => null,
        };

    private static bool IsActionAllowedForRole(
        ComplianceReviewerRole role,
        ComplianceReviewDecisionKind decision) => role switch
        {
            ComplianceReviewerRole.ProjectManager => decision is
                ComplianceReviewDecisionKind.Confirm or
                ComplianceReviewDecisionKind.SendToLeader or
                ComplianceReviewDecisionKind.Dismiss,
            ComplianceReviewerRole.Leader =>
                decision == ComplianceReviewDecisionKind.EscalateToProjectManager,
            _ => false,
        };

    private static ComplianceReviewAuthorizationResult Rejected(
        ComplianceReviewRejectionCode code,
        string message) => new(
            IsAuthorized: false,
            code,
            ResultState: null,
            message);

    private static string ComputeRegistrationSha256(
        ComplianceReviewIncidentRegistration registration)
    {
        using var writer = new ComplianceCanonicalHashWriter(
            "HerdrOps.ComplianceReviewRegistration.v1");
        writer.Write(registration.ContractVersion);
        writer.Write(registration.IncidentId);
        writer.Write(registration.TaskId);
        writer.Write(registration.SubjectActorId);
        writer.Write(registration.RegisteredUtc);
        writer.Write(registration.EvidenceIdentitySha256s.Count);
        foreach (var evidence in registration.EvidenceIdentitySha256s)
        {
            writer.Write(evidence);
        }

        return writer.Finish();
    }

    private static string ComputeEvidenceSetSha256(IReadOnlyList<string> evidence)
    {
        using var writer = new ComplianceCanonicalHashWriter(
            "HerdrOps.ComplianceReviewEvidenceSet.v1");
        writer.Write(evidence.Count);
        foreach (var identity in evidence)
        {
            writer.Write(identity);
        }

        return writer.Finish();
    }

    private static string ComputeAuditSha256(ComplianceReviewAuditEvent auditEvent)
    {
        using var writer = new ComplianceCanonicalHashWriter(
            "HerdrOps.ComplianceReviewAuditEvent.v1");
        writer.Write(auditEvent.ContractVersion);
        writer.Write(auditEvent.AuditEventId.ToString("D"));
        writer.Write(auditEvent.IncidentId);
        writer.Write(auditEvent.TaskId);
        writer.Write(auditEvent.SubjectActorId);
        writer.Write(auditEvent.Sequence);
        writer.Write(auditEvent.ReviewerActorId);
        writer.Write((int)auditEvent.ReviewerRole);
        writer.Write(auditEvent.AuthorityProvenanceEventId.ToString("D"));
        writer.Write(auditEvent.AuthorityProvenanceSequence);
        writer.Write(auditEvent.AuthorityProvenanceSha256);
        writer.Write((int)auditEvent.DecisionKind);
        writer.Write((int)auditEvent.PreviousState);
        writer.Write((int)auditEvent.ResultState);
        writer.Write(auditEvent.Reason);
        writer.Write(auditEvent.OccurredUtc);
        writer.Write(auditEvent.EvidenceSetSha256);
        writer.Write(auditEvent.PreviousAuditSha256);
        return writer.Finish();
    }
}

public sealed class ComplianceReviewContractException : ArgumentException
{
    public ComplianceReviewContractException(string message)
        : base(message)
    {
    }
}

public sealed class ComplianceReviewRejectedException : InvalidOperationException
{
    public ComplianceReviewRejectedException(
        ComplianceReviewRejectionCode rejectionCode,
        string message)
        : base(message)
    {
        RejectionCode = rejectionCode;
    }

    public ComplianceReviewRejectionCode RejectionCode { get; }
}
