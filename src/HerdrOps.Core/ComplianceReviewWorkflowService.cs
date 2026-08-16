using HerdrOps.Domain.Assignments;
using HerdrOps.Domain.Compliance;
using HerdrOps.Contracts.ReviewIpc;
using HerdrOps.Infrastructure.Storage;

namespace HerdrOps.Core;

public sealed record ComplianceReviewCommandExecution(
    bool IsAccepted,
    ComplianceReviewRejectionCode RejectionCode,
    string Message,
    ComplianceReviewIncident? Incident,
    ComplianceReviewAuditEvent? AuditEvent,
    bool WasAlreadyPresent);

public sealed class ComplianceReviewWorkflowService
{
    private readonly object _sync = new();
    private readonly SqliteHerdrStateStore _store;
    private readonly TimeProvider _timeProvider;

    public ComplianceReviewWorkflowService(
        SqliteHerdrStateStore store,
        TimeProvider? timeProvider = null)
    {
        _store = store ?? throw new ArgumentNullException(nameof(store));
        _timeProvider = timeProvider ?? TimeProvider.System;
    }

    public ComplianceReviewCommandExecution Execute(
        ComplianceReviewCommand command,
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var normalized = ComplianceReviewWorkflowContract.NormalizeCommand(command);
        EnterOperationLock(cancellationToken);
        try
        {
            cancellationToken.ThrowIfCancellationRequested();
            var incident = _store.ReadComplianceReviewIncident(
                normalized.IncidentId,
                cancellationToken);
            if (incident is null)
            {
                return Rejected(
                    ComplianceReviewRejectionCode.UnknownIncident,
                    $"Compliance review incident '{normalized.IncidentId}' does not exist.");
            }

            try
            {
                var write = _store.ApplyComplianceReviewCommandWithCurrentAuthority(
                    normalized,
                    MapAuthority,
                    cancellationToken);
                return new ComplianceReviewCommandExecution(
                    IsAccepted: true,
                    ComplianceReviewRejectionCode.None,
                    write.WasAlreadyPresent
                        ? "The exact review decision was already accepted."
                        : "The review decision was accepted and persisted.",
                    write.Incident,
                    write.AuditEvent,
                    write.WasAlreadyPresent);
            }
            catch (ComplianceReviewRejectedException exception)
            {
                cancellationToken.ThrowIfCancellationRequested();
                return Rejected(
                    exception.RejectionCode,
                    exception.Message);
            }
        }
        finally
        {
            Monitor.Exit(_sync);
        }
    }

    public ValueTask<HerdrOpsReviewCommandResult> ExecuteAsync(
        HerdrOpsReviewCommandRequest request,
        Guid correlationId,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        ArgumentNullException.ThrowIfNull(request);
        if (correlationId == Guid.Empty || correlationId != request.CommandId)
        {
            throw new ArgumentException(
                "The review-command correlation ID must equal the command ID.",
                nameof(correlationId));
        }

        var execution = Execute(ComplianceReviewCommandMapper.MapRequest(
            request,
            _timeProvider.GetUtcNow()),
            cancellationToken);
        return ValueTask.FromResult(
            ComplianceReviewCommandMapper.MapExecution(execution));
    }

    public HerdrOpsReviewCapabilitiesResult ReadCapabilities(
        HerdrOpsReviewCapabilitiesRequest request,
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        ArgumentNullException.ThrowIfNull(request);
        var reviewerActorId = ComplianceReviewWorkflowContract.NormalizeActorId(
            request.ReviewerActorId);
        var incidentId = ComplianceReviewWorkflowContract.NormalizeIncidentId(
            request.IncidentId);
        if (request.ObservedUtc.Offset != TimeSpan.Zero)
        {
            throw new ArgumentException(
                "The review-capability observation time must be UTC.",
                nameof(request));
        }

        var capabilities = _store.ReadComplianceReviewCapabilities(
            reviewerActorId,
            incidentId,
            request.ObservedUtc,
            MapAuthority,
            cancellationToken);
        return new HerdrOpsReviewCapabilitiesResult(
            capabilities.ReviewerRole is not null,
            capabilities.ReviewerRole is null
                ? null
                : (int)capabilities.ReviewerRole.Value,
            capabilities.Incident is null
                ? null
                : (int)capabilities.Incident.State,
            capabilities.Incident?.Sequence,
            capabilities.AllowedDecisions
                .Select(item => (int)item)
                .ToArray(),
            capabilities.Incident is null
                ? $"Compliance review incident '{incidentId}' does not exist."
                : capabilities.ReviewerRole is null
                    ? "The reviewer has no current admitted Project Manager or Leader role provenance."
                    : "Core evaluated the current reviewer role and incident state.");
    }

    public ValueTask<HerdrOpsReviewCapabilitiesResult> ReadCapabilitiesAsync(
        HerdrOpsReviewCapabilitiesRequest request,
        Guid correlationId,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (correlationId == Guid.Empty)
        {
            throw new ArgumentException(
                "The review-capability correlation ID cannot be empty.",
                nameof(correlationId));
        }

        return ValueTask.FromResult(ReadCapabilities(request, cancellationToken));
    }

    internal static ComplianceReviewAuthority? MapAuthority(
        AssignmentCurrentActorRole? role)
    {
        if (role is null || !TryMapReviewerRole(role, out var reviewerRole))
        {
            return null;
        }

        return new ComplianceReviewAuthority(
            role.ActorId,
            reviewerRole,
            role.EventId,
            role.Sequence,
            role.AcceptedUtc,
            role.ProvenanceEventSha256);
    }

    internal static bool TryMapReviewerRole(
        AssignmentCurrentActorRole role,
        out ComplianceReviewerRole reviewerRole)
    {
        ArgumentNullException.ThrowIfNull(role);
        return ComplianceReviewWorkflowContract.TryMapAssignmentRole(
            role.ActorRole,
            out reviewerRole);
    }

    private static ComplianceReviewCommandExecution Rejected(
        ComplianceReviewRejectionCode code,
        string message) =>
        new(
            IsAccepted: false,
            code,
            message,
            Incident: null,
            AuditEvent: null,
            WasAlreadyPresent: false);

    private void EnterOperationLock(CancellationToken cancellationToken)
    {
        while (!Monitor.TryEnter(_sync, TimeSpan.FromMilliseconds(25)))
        {
            cancellationToken.ThrowIfCancellationRequested();
        }
    }
}
