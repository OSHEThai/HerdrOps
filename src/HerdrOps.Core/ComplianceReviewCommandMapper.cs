using HerdrOps.Contracts.ReviewIpc;
using HerdrOps.Domain.Compliance;

namespace HerdrOps.Core;

public static class ComplianceReviewCommandMapper
{
    public static ComplianceReviewCommand MapRequest(
        HerdrOpsReviewCommandRequest request,
        DateTimeOffset occurredUtc)
    {
        ArgumentNullException.ThrowIfNull(request);
        return ComplianceReviewWorkflowContract.NormalizeCommand(
            new ComplianceReviewCommand(
                request.ContractVersion,
                request.CommandId,
                request.IncidentId,
                (ComplianceReviewState)request.ExpectedState,
                request.ExpectedSequence,
                request.ReviewerActorId,
                (ComplianceReviewDecisionKind)request.DecisionKind,
                request.Reason,
                occurredUtc,
                request.EvidenceIdentitySha256s));
    }

    public static HerdrOpsReviewCommandResult MapExecution(
        ComplianceReviewCommandExecution execution)
    {
        ArgumentNullException.ThrowIfNull(execution);
        return new HerdrOpsReviewCommandResult(
            execution.IsAccepted,
            (int)execution.RejectionCode,
            execution.Message,
            execution.Incident is null ? null : MapIncident(execution.Incident),
            execution.AuditEvent is null ? null : MapAuditEvent(execution.AuditEvent),
            execution.WasAlreadyPresent);
    }

    private static HerdrOpsComplianceReviewIncident MapIncident(
        ComplianceReviewIncident incident) =>
        new(
            incident.ContractVersion,
            incident.IncidentId,
            incident.TaskId,
            incident.SubjectActorId,
            incident.RegisteredUtc,
            incident.InitialEvidenceIdentitySha256s,
            incident.RegistrationSha256,
            (int)incident.State,
            incident.Sequence,
            incident.UpdatedUtc,
            incident.LastAuditEventId,
            incident.LastAuditSha256);

    private static HerdrOpsComplianceReviewAuditEvent MapAuditEvent(
        ComplianceReviewAuditEvent auditEvent) =>
        new(
            auditEvent.ContractVersion,
            auditEvent.AuditEventId,
            auditEvent.IncidentId,
            auditEvent.TaskId,
            auditEvent.SubjectActorId,
            auditEvent.Sequence,
            auditEvent.ReviewerActorId,
            (int)auditEvent.ReviewerRole,
            auditEvent.AuthorityProvenanceEventId,
            auditEvent.AuthorityProvenanceSequence,
            auditEvent.AuthorityProvenanceSha256,
            (int)auditEvent.DecisionKind,
            (int)auditEvent.PreviousState,
            (int)auditEvent.ResultState,
            auditEvent.Reason,
            auditEvent.OccurredUtc,
            auditEvent.EvidenceIdentitySha256s,
            auditEvent.EvidenceSetSha256,
            auditEvent.PreviousAuditSha256,
            auditEvent.AuditSha256);
}
