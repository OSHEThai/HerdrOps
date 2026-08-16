using HerdrOps.App.ReviewIpc;
using HerdrOps.Contracts.ReviewIpc;
using HerdrOps.Domain.Compliance;

namespace HerdrOps.IntegrationTests;

[TestClass]
public sealed class ComplianceReviewCommandCoordinatorTests
{
    private static readonly DateTimeOffset BaseUtc =
        new(2026, 8, 15, 7, 0, 0, TimeSpan.Zero);

    [TestMethod]
    public async Task AuthoritativeResponsePublishesAfterCallerCancellation()
    {
        using var callerCancellation = new CancellationTokenSource();
        var request = CreateRequest("INC-COORDINATOR-COMMIT");
        var result = CreateAuthoritativeResponse(request);
        var client = new ResponseThenCancelClient(result, callerCancellation);
        var scheduler = new CancellationRejectingScheduler();
        var stateHub = new ComplianceReviewStateHub();
        var stateChanges = 0;
        stateHub.StateChanged += (_, _) => stateChanges++;
        var coordinator = new ComplianceReviewCommandCoordinator(
            client,
            stateHub,
            scheduler);

        var returned = await coordinator.ExecuteAsync(request, callerCancellation.Token);

        Assert.AreSame(result, returned);
        Assert.IsTrue(callerCancellation.IsCancellationRequested);
        Assert.IsTrue(scheduler.Invoked);
        Assert.IsFalse(scheduler.ReceivedToken.CanBeCanceled);
        Assert.AreEqual(1, stateChanges);
        Assert.IsNotNull(stateHub.Read(result.Incident!.IncidentId));
        Assert.IsFalse(coordinator.IsPending(request.CommandId));
    }

    [TestMethod]
    public async Task CallerCancellationStillCancelsTransportBeforeResponse()
    {
        using var callerCancellation = new CancellationTokenSource();
        var client = new BlockingCancelableClient();
        var scheduler = new RecordingScheduler();
        var stateHub = new ComplianceReviewStateHub();
        var coordinator = new ComplianceReviewCommandCoordinator(
            client,
            stateHub,
            scheduler);
        var request = CreateRequest("INC-COORDINATOR-CANCEL");
        var execution = coordinator.ExecuteAsync(request, callerCancellation.Token).AsTask();

        await client.Started.Task.WaitAsync(TimeSpan.FromSeconds(5));
        callerCancellation.Cancel();

        await Assert.ThrowsAsync<OperationCanceledException>(
            async () => await execution);
        Assert.IsFalse(scheduler.Invoked);
        Assert.IsNull(stateHub.Read(request.IncidentId));
        Assert.IsFalse(coordinator.IsPending(request.CommandId));
    }

    [TestMethod]
    public async Task ValidAcceptedResponsePublishesRequestBoundAuditEvent()
    {
        var request = CreateRequest("INC-COORDINATOR-ACCEPT");
        var result = CreateAcceptedResponse(request);
        var stateHub = new ComplianceReviewStateHub();
        var client = new ResultClient(result);
        var coordinator = new ComplianceReviewCommandCoordinator(client, stateHub);

        var returned = await coordinator.ExecuteAsync(request);

        Assert.AreSame(result, returned);
        var incident = stateHub.Read(request.IncidentId);
        Assert.IsNotNull(incident);
        Assert.AreEqual(1L, incident.Sequence);
        Assert.AreEqual(request.CommandId, incident.LastAuditEventId);
        Assert.IsFalse(coordinator.IsPending(request.CommandId));
    }

    [TestMethod]
    public async Task AlreadyPresentAcceptedRetryPublishesItsRequestBoundAuditEvent()
    {
        var request = CreateRequest("INC-COORDINATOR-RETRY");
        var result = CreateAcceptedResponse(request, wasAlreadyPresent: true);
        var stateHub = new ComplianceReviewStateHub();
        var coordinator = new ComplianceReviewCommandCoordinator(
            new ResultClient(result),
            stateHub);

        var returned = await coordinator.ExecuteAsync(request);

        Assert.IsTrue(returned.IsAccepted);
        Assert.IsTrue(returned.WasAlreadyPresent);
        Assert.AreEqual(
            request.CommandId,
            stateHub.Read(request.IncidentId)!.LastAuditEventId);
    }

    [TestMethod]
    public async Task AcceptedResponseWithWrongIncidentFailsClosedBeforePublication()
    {
        var request = CreateRequest("INC-COORDINATOR-REQUEST");
        var result = CreateAcceptedResponse(request, "INC-COORDINATOR-OTHER");
        var stateHub = new ComplianceReviewStateHub();
        var scheduler = new RecordingScheduler();
        var coordinator = new ComplianceReviewCommandCoordinator(
            new ResultClient(result),
            stateHub,
            scheduler);

        await Assert.ThrowsExactlyAsync<HerdrOpsReviewCommandProtocolException>(
            () => coordinator.ExecuteAsync(request).AsTask());

        Assert.IsFalse(scheduler.Invoked);
        Assert.IsNull(stateHub.Read(request.IncidentId));
        Assert.IsNull(stateHub.Read("INC-COORDINATOR-OTHER"));
        Assert.IsFalse(coordinator.IsPending(request.CommandId));
    }

    [TestMethod]
    public async Task AcceptedResponseWithWrongAuditCommandIdFailsClosedBeforePublication()
    {
        var request = CreateRequest("INC-COORDINATOR-AUDIT");
        var valid = CreateAcceptedResponse(request);
        var result = valid with
        {
            AuditEvent = valid.AuditEvent! with
            {
                AuditEventId = Guid.Parse("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"),
            },
        };
        var stateHub = new ComplianceReviewStateHub();
        var scheduler = new RecordingScheduler();
        var coordinator = new ComplianceReviewCommandCoordinator(
            new ResultClient(result),
            stateHub,
            scheduler);

        await Assert.ThrowsExactlyAsync<HerdrOpsReviewCommandProtocolException>(
            () => coordinator.ExecuteAsync(request).AsTask());

        Assert.IsFalse(scheduler.Invoked);
        Assert.IsNull(stateHub.Read(request.IncidentId));
        Assert.IsFalse(coordinator.IsPending(request.CommandId));
    }

    [TestMethod]
    public async Task RejectedResponseWithSameIncidentIdButUnrelatedIncidentTupleFailsClosedBeforePublication()
    {
        var request = CreateRequest("INC-COORDINATOR-REJECTED-TUPLE");
        var unrelatedIncident = ComplianceReviewWorkflowContract.CreateIncident(
            new ComplianceReviewIncidentRegistration(
                ComplianceReviewWorkflowContract.ContractVersion,
                request.IncidentId,
                "TASK-UNRELATED",
                "unrelated-worker",
                BaseUtc.AddMinutes(1),
                [new string('B', 64)]));
        var result = new HerdrOpsReviewCommandResult(
            IsAccepted: false,
            RejectionCode: (int)ComplianceReviewRejectionCode.StaleState,
            Message: "The command was rejected with an unrelated incident tuple.",
            Incident: ToContract(unrelatedIncident),
            AuditEvent: null,
            WasAlreadyPresent: false);
        var stateHub = new ComplianceReviewStateHub();
        var scheduler = new RecordingScheduler();
        var coordinator = new ComplianceReviewCommandCoordinator(
            new ResultClient(result),
            stateHub,
            scheduler);

        await Assert.ThrowsExactlyAsync<HerdrOpsReviewCommandProtocolException>(
            () => coordinator.ExecuteAsync(request).AsTask());

        Assert.IsFalse(scheduler.Invoked);
        Assert.IsNull(stateHub.Read(request.IncidentId));
        Assert.IsFalse(coordinator.IsPending(request.CommandId));
    }

    [TestMethod]
    public async Task AcceptedResponseWithMismatchedIncidentAndAuditEvidenceFailsClosedBeforePublication()
    {
        var request = CreateRequest("INC-COORDINATOR-EVIDENCE");
        var result = CreateAcceptedResponse(
            request,
            incidentEvidenceIdentitySha256s: [new string('B', 64)],
            auditEvidenceIdentitySha256s: [new string('C', 64)]);
        var stateHub = new ComplianceReviewStateHub();
        var scheduler = new RecordingScheduler();
        var coordinator = new ComplianceReviewCommandCoordinator(
            new ResultClient(result),
            stateHub,
            scheduler);

        await Assert.ThrowsExactlyAsync<HerdrOpsReviewCommandProtocolException>(
            () => coordinator.ExecuteAsync(request).AsTask());

        Assert.IsFalse(scheduler.Invoked);
        Assert.IsNull(stateHub.Read(request.IncidentId));
        Assert.IsFalse(coordinator.IsPending(request.CommandId));
    }

    [TestMethod]
    public async Task RejectedResponseWithAuditEventFailsClosed()
    {
        var request = CreateRequest("INC-COORDINATOR-REJECTED-AUDIT");
        var accepted = CreateAcceptedResponse(request);
        var result = accepted with
        {
            IsAccepted = false,
            RejectionCode = (int)ComplianceReviewRejectionCode.StaleState,
        };
        var stateHub = new ComplianceReviewStateHub();
        var scheduler = new RecordingScheduler();
        var coordinator = new ComplianceReviewCommandCoordinator(
            new ResultClient(result),
            stateHub,
            scheduler);

        await Assert.ThrowsExactlyAsync<HerdrOpsReviewCommandProtocolException>(
            () => coordinator.ExecuteAsync(request).AsTask());

        Assert.IsFalse(scheduler.Invoked);
        Assert.IsNull(stateHub.Read(request.IncidentId));
        Assert.IsFalse(coordinator.IsPending(request.CommandId));
    }

    private static HerdrOpsReviewCommandRequest CreateRequest(string incidentId) =>
        new(
            ComplianceReviewWorkflowContract.ContractVersion,
            Guid.Parse("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"),
            incidentId,
            (int)ComplianceReviewState.Suspected,
            ExpectedSequence: 0,
            "project-manager",
            (int)ComplianceReviewDecisionKind.Confirm,
            "Review the evidence-backed incident.",
            [new string('A', 64)]);

    private static HerdrOpsReviewCommandResult CreateAcceptedResponse(
        HerdrOpsReviewCommandRequest request,
        string? responseIncidentId = null,
        bool wasAlreadyPresent = false,
        IReadOnlyList<string>? incidentEvidenceIdentitySha256s = null,
        IReadOnlyList<string>? auditEvidenceIdentitySha256s = null)
    {
        var incidentId = responseIncidentId ?? request.IncidentId;
        var incidentEvidence = incidentEvidenceIdentitySha256s ?? request.EvidenceIdentitySha256s;
        var auditEvidence = auditEvidenceIdentitySha256s ?? incidentEvidence;
        var incident = ComplianceReviewWorkflowContract.CreateIncident(
            new ComplianceReviewIncidentRegistration(
                ComplianceReviewWorkflowContract.ContractVersion,
                incidentId,
                "TASK-COORDINATOR-ACCEPT",
                "backend-worker-01",
                BaseUtc,
                incidentEvidence));
        var command = new ComplianceReviewCommand(
            request.ContractVersion,
            request.CommandId,
            incidentId,
            (ComplianceReviewState)request.ExpectedState,
            request.ExpectedSequence,
            request.ReviewerActorId,
            (ComplianceReviewDecisionKind)request.DecisionKind,
            request.Reason,
            BaseUtc.AddMinutes(2),
            auditEvidence);
        var authority = new ComplianceReviewAuthority(
            request.ReviewerActorId,
            ComplianceReviewerRole.ProjectManager,
            Guid.Parse("cccccccc-cccc-cccc-cccc-cccccccccccc"),
            ProvenanceSequence: 10,
            BaseUtc.AddMinutes(1),
            new string('C', 64));
        var auditEvent = ComplianceReviewWorkflowContract.CreateAuditEvent(
            incident,
            command,
            authority);
        var updated = ComplianceReviewWorkflowContract.Apply(incident, auditEvent);
        return new(
            IsAccepted: true,
            RejectionCode: (int)ComplianceReviewRejectionCode.None,
            Message: wasAlreadyPresent
                ? "The exact review decision was already accepted."
                : "The review decision was accepted and persisted.",
            Incident: ToContract(updated),
            AuditEvent: ToContract(auditEvent),
            WasAlreadyPresent: wasAlreadyPresent);
    }

    private static HerdrOpsReviewCommandResult CreateAuthoritativeResponse(
        HerdrOpsReviewCommandRequest request) =>
        CreateAcceptedResponse(request);

    private static HerdrOpsComplianceReviewIncident ToContract(
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

    private static HerdrOpsComplianceReviewAuditEvent ToContract(
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

    private sealed class ResponseThenCancelClient(
        HerdrOpsReviewCommandResult result,
        CancellationTokenSource callerCancellation) : IHerdrOpsReviewCommandClient
    {
        public ValueTask<HerdrOpsReviewCommandResult> ExecuteAsync(
            HerdrOpsReviewCommandRequest request,
            CancellationToken cancellationToken)
        {
            _ = request;
            _ = cancellationToken;
            callerCancellation.Cancel();
            return ValueTask.FromResult(result);
        }

        public ValueTask<HerdrOpsReviewCapabilitiesResult> ReadCapabilitiesAsync(
            HerdrOpsReviewCapabilitiesRequest request,
            CancellationToken cancellationToken) =>
            ValueTask.FromException<HerdrOpsReviewCapabilitiesResult>(
                new NotSupportedException());
    }

    private sealed class ResultClient(HerdrOpsReviewCommandResult result) : IHerdrOpsReviewCommandClient
    {
        public ValueTask<HerdrOpsReviewCommandResult> ExecuteAsync(
            HerdrOpsReviewCommandRequest request,
            CancellationToken cancellationToken)
        {
            _ = request;
            cancellationToken.ThrowIfCancellationRequested();
            return ValueTask.FromResult(result);
        }

        public ValueTask<HerdrOpsReviewCapabilitiesResult> ReadCapabilitiesAsync(
            HerdrOpsReviewCapabilitiesRequest request,
            CancellationToken cancellationToken) =>
            ValueTask.FromException<HerdrOpsReviewCapabilitiesResult>(
                new NotSupportedException());
    }

    private sealed class BlockingCancelableClient : IHerdrOpsReviewCommandClient
    {
        public TaskCompletionSource Started { get; } = new(
            TaskCreationOptions.RunContinuationsAsynchronously);

        public async ValueTask<HerdrOpsReviewCommandResult> ExecuteAsync(
            HerdrOpsReviewCommandRequest request,
            CancellationToken cancellationToken)
        {
            _ = request;
            Started.TrySetResult();
            await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken);
            throw new InvalidOperationException("The transport should be cancelled before a response.");
        }

        public ValueTask<HerdrOpsReviewCapabilitiesResult> ReadCapabilitiesAsync(
            HerdrOpsReviewCapabilitiesRequest request,
            CancellationToken cancellationToken) =>
            ValueTask.FromException<HerdrOpsReviewCapabilitiesResult>(
                new NotSupportedException());
    }

    private sealed class CancellationRejectingScheduler : IComplianceReviewStateScheduler
    {
        public bool Invoked { get; private set; }

        public CancellationToken ReceivedToken { get; private set; }

        public ValueTask InvokeAsync(Action action, CancellationToken cancellationToken)
        {
            Invoked = true;
            ReceivedToken = cancellationToken;
            cancellationToken.ThrowIfCancellationRequested();
            action();
            return ValueTask.CompletedTask;
        }
    }

    private sealed class RecordingScheduler : IComplianceReviewStateScheduler
    {
        public bool Invoked { get; private set; }

        public ValueTask InvokeAsync(Action action, CancellationToken cancellationToken)
        {
            _ = action;
            _ = cancellationToken;
            Invoked = true;
            return ValueTask.CompletedTask;
        }
    }
}
