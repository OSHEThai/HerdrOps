using HerdrOps.Contracts.ReviewIpc;
using HerdrOps.Domain.Compliance;

namespace HerdrOps.App.ReviewIpc;

public interface IComplianceReviewStateScheduler
{
    ValueTask InvokeAsync(Action action, CancellationToken cancellationToken);
}

public sealed class InlineComplianceReviewStateScheduler : IComplianceReviewStateScheduler
{
    public ValueTask InvokeAsync(Action action, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(action);
        cancellationToken.ThrowIfCancellationRequested();
        action();
        return ValueTask.CompletedTask;
    }
}

public sealed class ComplianceReviewCommandCoordinator
{
    private readonly object _sync = new();
    private readonly IHerdrOpsReviewCommandClient _client;
    private readonly ComplianceReviewStateHub _stateHub;
    private readonly IComplianceReviewStateScheduler _scheduler;
    private readonly HashSet<Guid> _pendingCommands = [];

    public ComplianceReviewCommandCoordinator(
        IHerdrOpsReviewCommandClient client,
        ComplianceReviewStateHub stateHub,
        IComplianceReviewStateScheduler? scheduler = null)
    {
        _client = client ?? throw new ArgumentNullException(nameof(client));
        _stateHub = stateHub ?? throw new ArgumentNullException(nameof(stateHub));
        _scheduler = scheduler ?? new InlineComplianceReviewStateScheduler();
    }

    public bool IsPending(Guid commandId)
    {
        if (commandId == Guid.Empty)
        {
            return false;
        }

        lock (_sync)
        {
            return _pendingCommands.Contains(commandId);
        }
    }

    public ValueTask<HerdrOpsReviewCapabilitiesResult> ReadCapabilitiesAsync(
        HerdrOpsReviewCapabilitiesRequest request,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);
        return _client.ReadCapabilitiesAsync(request, cancellationToken);
    }

    public async ValueTask<HerdrOpsReviewCommandResult> ExecuteAsync(
        HerdrOpsReviewCommandRequest request,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (request.CommandId == Guid.Empty)
        {
            throw new ArgumentException(
                "The review command ID cannot be empty.",
                nameof(request));
        }

        lock (_sync)
        {
            if (!_pendingCommands.Add(request.CommandId))
            {
                throw new InvalidOperationException(
                    $"Review command '{request.CommandId:D}' is already pending.");
            }
        }

        try
        {
            var result = await _client
                .ExecuteAsync(request, cancellationToken)
                .ConfigureAwait(false);

            ValidateResultBinding(request, result);
            if (result.IsAccepted && result.Incident is not null)
            {
                await _scheduler
                    .InvokeAsync(
                        () =>
                        {
                            // Cancellation after Core has returned an authoritative
                            // response must not suppress publication, but a scheduler
                            // that invokes after the request has left the in-flight
                            // set must fail closed.
                            if (IsPending(request.CommandId))
                            {
                                _stateHub.Apply(result);
                            }
                        },
                        CancellationToken.None)
                    .ConfigureAwait(false);
            }

            return result;
        }
        finally
        {
            lock (_sync)
            {
                _pendingCommands.Remove(request.CommandId);
            }
        }
    }

    private static void ValidateResultBinding(
        HerdrOpsReviewCommandRequest request,
        HerdrOpsReviewCommandResult result)
    {
        ArgumentNullException.ThrowIfNull(result);

        var rejectionCode = (ComplianceReviewRejectionCode)result.RejectionCode;
        if (!Enum.IsDefined(rejectionCode) ||
            result.IsAccepted !=
            (rejectionCode == ComplianceReviewRejectionCode.None) ||
            (!result.IsAccepted &&
             (result.AuditEvent is not null || result.WasAlreadyPresent)))
        {
            throw new HerdrOpsReviewCommandProtocolException(
                "The review-command result has an invalid acceptance, rejection, audit, or retry tuple.");
        }

        if (!result.IsAccepted)
        {
            if (result.Incident is not null)
            {
                throw new HerdrOpsReviewCommandProtocolException(
                    "A rejected review-command result cannot carry an unbound incident snapshot.");
            }

            return;
        }

        if (result.Incident is null)
        {
            throw new HerdrOpsReviewCommandProtocolException(
                "An accepted review-command result requires an incident snapshot.");
        }

        if (!string.Equals(
                result.Incident.IncidentId,
                request.IncidentId,
                StringComparison.Ordinal))
        {
            throw new HerdrOpsReviewCommandProtocolException(
                "The review-command result incident does not match the request incident.");
        }

        var auditEvent = result.AuditEvent;
        if (auditEvent is null ||
            request.ExpectedSequence < 0 ||
            request.ExpectedSequence == long.MaxValue ||
            !Enum.IsDefined((ComplianceReviewState)request.ExpectedState) ||
            !Enum.IsDefined((ComplianceReviewDecisionKind)request.DecisionKind) ||
            auditEvent.ContractVersion != request.ContractVersion ||
            result.Incident.ContractVersion != request.ContractVersion ||
            auditEvent.AuditEventId != request.CommandId ||
            !string.Equals(
                auditEvent.IncidentId,
                request.IncidentId,
                StringComparison.Ordinal) ||
            !string.Equals(
                auditEvent.IncidentId,
                result.Incident.IncidentId,
                StringComparison.Ordinal) ||
            !string.Equals(
                auditEvent.TaskId,
                result.Incident.TaskId,
                StringComparison.Ordinal) ||
            !string.Equals(
                auditEvent.SubjectActorId,
                result.Incident.SubjectActorId,
                StringComparison.Ordinal) ||
            !string.Equals(
                auditEvent.ReviewerActorId,
                request.ReviewerActorId,
                StringComparison.Ordinal) ||
            auditEvent.DecisionKind != request.DecisionKind ||
            auditEvent.PreviousState != request.ExpectedState ||
            auditEvent.Sequence != request.ExpectedSequence + 1 ||
            !string.Equals(
                auditEvent.Reason,
                request.Reason.Trim(),
                StringComparison.Ordinal) ||
            !request.EvidenceIdentitySha256s
                .OrderBy(identity => identity, StringComparer.Ordinal)
                .SequenceEqual(
                    auditEvent.EvidenceIdentitySha256s,
                    StringComparer.Ordinal))
        {
            throw new HerdrOpsReviewCommandProtocolException(
                "The accepted review-command result is not bound to its originating request.");
        }

        var incidentIsAuditTip =
            result.Incident.Sequence == auditEvent.Sequence &&
            result.Incident.State == auditEvent.ResultState &&
            result.Incident.LastAuditEventId == auditEvent.AuditEventId &&
            string.Equals(
                result.Incident.LastAuditSha256,
                auditEvent.AuditSha256,
                StringComparison.Ordinal);
        if ((!result.WasAlreadyPresent && !incidentIsAuditTip) ||
            (result.WasAlreadyPresent && result.Incident.Sequence < auditEvent.Sequence) ||
            (result.WasAlreadyPresent &&
             result.Incident.Sequence == auditEvent.Sequence &&
             !incidentIsAuditTip))
        {
            throw new HerdrOpsReviewCommandProtocolException(
                "The accepted review-command incident is not an authoritative result for its originating request.");
        }
    }
}
