using System.Diagnostics;
using HerdrOps.Contracts.ReviewIpc;
using HerdrOps.Domain.Compliance;

namespace HerdrOps.App.ReviewIpc;

public sealed record ComplianceReviewStateChange(
    ComplianceReviewIncident Incident,
    ComplianceReviewAuditEvent? Decision,
    bool WasAlreadyKnown);

public sealed class ComplianceReviewStateChangedEventArgs(
    ComplianceReviewStateChange change) : EventArgs
{
    public ComplianceReviewStateChange Change { get; } = change;
}

public sealed class ComplianceReviewStateHub
{
    private readonly object _sync = new();
    private readonly Dictionary<string, ComplianceReviewIncident> _incidents =
        new(StringComparer.Ordinal);

    public event EventHandler<ComplianceReviewStateChangedEventArgs>? StateChanged;

    public IReadOnlyList<ComplianceReviewIncident> Snapshot()
    {
        lock (_sync)
        {
            return _incidents.Values
                .OrderBy(item => item.IncidentId, StringComparer.Ordinal)
                .ToArray();
        }
    }

    public ComplianceReviewIncident? Read(string incidentId)
    {
        incidentId = ComplianceReviewWorkflowContract.NormalizeIncidentId(incidentId);
        lock (_sync)
        {
            return _incidents.GetValueOrDefault(incidentId);
        }
    }

    internal ComplianceReviewStateChange Apply(HerdrOpsReviewCommandResult result)
    {
        ArgumentNullException.ThrowIfNull(result);
        if (!Enum.IsDefined((ComplianceReviewRejectionCode)result.RejectionCode) ||
            result.IsAccepted !=
            (result.RejectionCode == (int)ComplianceReviewRejectionCode.None) ||
            (!result.IsAccepted && (result.AuditEvent is not null || result.WasAlreadyPresent)))
        {
            throw new HerdrOpsReviewCommandProtocolException(
                "The review-command result has an invalid acceptance, rejection, audit, or retry tuple.");
        }

        if (result.Incident is null)
        {
            throw new HerdrOpsReviewCommandProtocolException(
                "A review-command result cannot update shared state without an incident snapshot.");
        }

        var incident = MapIncident(result.Incident);
        var auditEvent = result.AuditEvent is null ? null : MapAuditEvent(result.AuditEvent);
        if (result.IsAccepted && auditEvent is null)
        {
            throw new HerdrOpsReviewCommandProtocolException(
                "An accepted review-command result requires an immutable audit event.");
        }

        if (auditEvent is not null &&
            (!string.Equals(auditEvent.IncidentId, incident.IncidentId, StringComparison.Ordinal) ||
             auditEvent.Sequence > incident.Sequence ||
             (auditEvent.Sequence == incident.Sequence &&
              (!string.Equals(auditEvent.AuditSha256, incident.LastAuditSha256, StringComparison.Ordinal) ||
               auditEvent.AuditEventId != incident.LastAuditEventId))))
        {
            throw new HerdrOpsReviewCommandProtocolException(
                "The review result incident and audit event do not share one authoritative state.");
        }

        ComplianceReviewStateChange change;
        EventHandler<ComplianceReviewStateChangedEventArgs>? handlers;
        lock (_sync)
        {
            var existing = _incidents.GetValueOrDefault(incident.IncidentId);
            if (existing is not null && !HasSameImmutableRegistration(existing, incident))
            {
                throw new HerdrOpsReviewCommandProtocolException(
                    "Core returned conflicting immutable registration data for one review incident.");
            }

            if (existing is not null && incident.Sequence < existing.Sequence)
            {
                return new ComplianceReviewStateChange(
                    existing,
                    Decision: null,
                    WasAlreadyKnown: true);
            }

            if (existing is not null &&
                incident.Sequence == existing.Sequence &&
                !HasSameCurrentState(existing, incident))
            {
                throw new HerdrOpsReviewCommandProtocolException(
                    "Core returned conflicting review states at the same incident sequence.");
            }

            var alreadyKnown = existing is not null &&
                incident.Sequence == existing.Sequence &&
                string.Equals(
                    incident.LastAuditSha256,
                    existing.LastAuditSha256,
                    StringComparison.Ordinal);
            _incidents[incident.IncidentId] = incident;
            change = new ComplianceReviewStateChange(
                incident,
                auditEvent?.Sequence == incident.Sequence ? auditEvent : null,
                alreadyKnown);
            handlers = alreadyKnown ? null : StateChanged;
        }

        if (handlers is not null)
        {
            NotifyStateChangedSafely(
                handlers,
                new ComplianceReviewStateChangedEventArgs(change));
        }

        return change;
    }

    private void NotifyStateChangedSafely(
        EventHandler<ComplianceReviewStateChangedEventArgs> handlers,
        ComplianceReviewStateChangedEventArgs eventArgs)
    {
        foreach (EventHandler<ComplianceReviewStateChangedEventArgs> handler in
                 handlers.GetInvocationList())
        {
            try
            {
                handler(this, eventArgs);
            }
            catch (Exception exception) when (!IsFatal(exception))
            {
                Trace.TraceError(
                    "Compliance review state observer failed after authoritative state publication; type={0}.",
                    exception.GetType().FullName);
            }
        }
    }

    private static bool IsFatal(Exception exception) => exception is
        OutOfMemoryException or
        AccessViolationException or
        AppDomainUnloadedException or
        BadImageFormatException;

    private static bool HasSameImmutableRegistration(
        ComplianceReviewIncident first,
        ComplianceReviewIncident second) =>
        string.Equals(first.TaskId, second.TaskId, StringComparison.Ordinal) &&
        string.Equals(first.SubjectActorId, second.SubjectActorId, StringComparison.Ordinal) &&
        first.RegisteredUtc == second.RegisteredUtc &&
        first.InitialEvidenceIdentitySha256s.SequenceEqual(
            second.InitialEvidenceIdentitySha256s,
            StringComparer.Ordinal) &&
        string.Equals(
            first.RegistrationSha256,
            second.RegistrationSha256,
            StringComparison.Ordinal);

    private static bool HasSameCurrentState(
        ComplianceReviewIncident first,
        ComplianceReviewIncident second) =>
        first.State == second.State &&
        first.UpdatedUtc == second.UpdatedUtc &&
        first.LastAuditEventId == second.LastAuditEventId &&
        string.Equals(
            first.LastAuditSha256,
            second.LastAuditSha256,
            StringComparison.Ordinal);

    private static ComplianceReviewIncident MapIncident(
        HerdrOpsComplianceReviewIncident incident)
    {
        try
        {
            return ComplianceReviewWorkflowContract.NormalizeAndValidateIncident(
                new ComplianceReviewIncident(
                    incident.ContractVersion,
                    incident.IncidentId,
                    incident.TaskId,
                    incident.SubjectActorId,
                    incident.RegisteredUtc,
                    incident.InitialEvidenceIdentitySha256s,
                    incident.RegistrationSha256,
                    (ComplianceReviewState)incident.State,
                    incident.Sequence,
                    incident.UpdatedUtc,
                    incident.LastAuditEventId,
                    incident.LastAuditSha256));
        }
        catch (ComplianceReviewContractException exception)
        {
            throw new HerdrOpsReviewCommandProtocolException(
                "The review-command incident snapshot failed domain validation.",
                exception);
        }
    }

    private static ComplianceReviewAuditEvent MapAuditEvent(
        HerdrOpsComplianceReviewAuditEvent auditEvent)
    {
        try
        {
            return ComplianceReviewWorkflowContract.NormalizeAndValidateAuditEvent(
                new ComplianceReviewAuditEvent(
                    auditEvent.ContractVersion,
                    auditEvent.AuditEventId,
                    auditEvent.IncidentId,
                    auditEvent.TaskId,
                    auditEvent.SubjectActorId,
                    auditEvent.Sequence,
                    auditEvent.ReviewerActorId,
                    (ComplianceReviewerRole)auditEvent.ReviewerRole,
                    auditEvent.AuthorityProvenanceEventId,
                    auditEvent.AuthorityProvenanceSequence,
                    auditEvent.AuthorityProvenanceSha256,
                    (ComplianceReviewDecisionKind)auditEvent.DecisionKind,
                    (ComplianceReviewState)auditEvent.PreviousState,
                    (ComplianceReviewState)auditEvent.ResultState,
                    auditEvent.Reason,
                    auditEvent.OccurredUtc,
                    auditEvent.EvidenceIdentitySha256s,
                    auditEvent.EvidenceSetSha256,
                    auditEvent.PreviousAuditSha256,
                    auditEvent.AuditSha256));
        }
        catch (ComplianceReviewContractException exception)
        {
            throw new HerdrOpsReviewCommandProtocolException(
                "The review-command audit event failed domain validation.",
                exception);
        }
    }
}
