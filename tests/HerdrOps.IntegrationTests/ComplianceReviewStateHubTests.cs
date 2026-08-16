using HerdrOps.App.ReviewIpc;
using HerdrOps.Contracts.ReviewIpc;
using HerdrOps.Domain.Compliance;

namespace HerdrOps.IntegrationTests;

[TestClass]
public sealed class ComplianceReviewStateHubTests
{
    private static readonly DateTimeOffset BaseUtc =
        new(2026, 8, 16, 5, 0, 0, TimeSpan.Zero);

    [TestMethod]
    public void InitialRegistrationSameSequenceImmutableConflictThrows()
    {
        var hub = new ComplianceReviewStateHub();
        var original = CreateIncidentResult("TASK-115");
        var conflict = CreateIncidentResult("TASK-116");

        Apply(hub, original);

        var exception = Assert.ThrowsExactly<HerdrOpsReviewCommandProtocolException>(
            () => Apply(hub, conflict));

        StringAssert.Contains(
            exception.Message,
            "conflicting immutable registration");
        Assert.AreEqual("TASK-115", hub.Read("INC-HUB-REGISTRATION")!.TaskId);
        Assert.AreEqual(0L, hub.Read("INC-HUB-REGISTRATION")!.Sequence);
    }

    [TestMethod]
    public void ExactDuplicateDoesNotNotifyTwice()
    {
        var hub = new ComplianceReviewStateHub();
        var notifications = new List<ComplianceReviewStateChange>();
        hub.StateChanged += (_, args) => notifications.Add(args.Change);
        var (_, result) = CreateTransitionResult(
            CreateIncident("INC-HUB-STATE", "TASK-115"),
            ComplianceReviewDecisionKind.SendToLeader,
            ComplianceReviewerRole.ProjectManager,
            "project-manager",
            Guid.Parse("11111111-1111-1111-1111-111111111111"),
            Guid.Parse("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"),
            BaseUtc.AddMinutes(2));

        var first = Apply(hub, result);
        var duplicate = Apply(hub, result);

        Assert.IsFalse(first.WasAlreadyKnown);
        Assert.IsTrue(duplicate.WasAlreadyKnown);
        Assert.IsNotNull(duplicate.Decision);
        Assert.HasCount(1, notifications);
        Assert.AreEqual(
            ComplianceReviewState.PendingLeader,
            hub.Read("INC-HUB-STATE")!.State);
        Assert.AreEqual(1L, hub.Read("INC-HUB-STATE")!.Sequence);
    }

    [TestMethod]
    public void OlderAuditRetryDoesNotRepublishDecisionOrReplaceLatestIncident()
    {
        var hub = new ComplianceReviewStateHub();
        var notifications = new List<ComplianceReviewStateChange>();
        hub.StateChanged += (_, args) => notifications.Add(args.Change);
        var (firstIncident, firstResult) = CreateTransitionResult(
            CreateIncident("INC-HUB-STATE", "TASK-115"),
            ComplianceReviewDecisionKind.SendToLeader,
            ComplianceReviewerRole.ProjectManager,
            "project-manager",
            Guid.Parse("22222222-2222-2222-2222-222222222222"),
            Guid.Parse("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"),
            BaseUtc.AddMinutes(2));
        var (_, secondResult) = CreateTransitionResult(
            firstIncident,
            ComplianceReviewDecisionKind.EscalateToProjectManager,
            ComplianceReviewerRole.Leader,
            "backend-leader",
            Guid.Parse("33333333-3333-3333-3333-333333333333"),
            Guid.Parse("cccccccc-cccc-cccc-cccc-cccccccccccc"),
            BaseUtc.AddMinutes(3));

        Apply(hub, firstResult);
        Apply(hub, secondResult);
        var retry = Apply(hub, firstResult);

        Assert.IsTrue(retry.WasAlreadyKnown);
        Assert.IsNull(retry.Decision);
        Assert.HasCount(2, notifications);
        var latest = hub.Read("INC-HUB-STATE")!;
        Assert.AreEqual(ComplianceReviewState.PendingProjectManager, latest.State);
        Assert.AreEqual(2L, latest.Sequence);
        Assert.AreEqual(
            secondResult.Incident!.LastAuditSha256,
            latest.LastAuditSha256);
        Assert.AreEqual(
            secondResult.Incident.LastAuditEventId,
            latest.LastAuditEventId);
    }

    [TestMethod]
    public void ThrowingSubscriberDoesNotStarveLaterConsumersOrReplayNotification()
    {
        var hub = new ComplianceReviewStateHub();
        var laterNotifications = new List<ComplianceReviewStateChange>();
        hub.StateChanged += (_, _) => throw new InvalidOperationException(
            "Simulated projection failure.");
        hub.StateChanged += (_, args) => laterNotifications.Add(args.Change);
        var (_, result) = CreateTransitionResult(
            CreateIncident("INC-HUB-OBSERVER", "TASK-115"),
            ComplianceReviewDecisionKind.SendToLeader,
            ComplianceReviewerRole.ProjectManager,
            "project-manager",
            Guid.Parse("44444444-4444-4444-4444-444444444444"),
            Guid.Parse("dddddddd-dddd-dddd-dddd-dddddddddddd"),
            BaseUtc.AddMinutes(2));

        var first = Apply(hub, result);
        var retry = Apply(hub, result);

        Assert.IsFalse(first.WasAlreadyKnown);
        Assert.IsTrue(retry.WasAlreadyKnown);
        Assert.HasCount(1, laterNotifications);
        Assert.AreEqual(
            ComplianceReviewState.PendingLeader,
            laterNotifications[0].Incident.State);
        Assert.AreEqual(
            ComplianceReviewState.PendingLeader,
            hub.Read("INC-HUB-OBSERVER")!.State);
    }

    private static ComplianceReviewStateChange Apply(
        ComplianceReviewStateHub hub,
        HerdrOpsReviewCommandResult result) =>
        hub.Apply(result);

    private static HerdrOpsReviewCommandResult CreateIncidentResult(string taskId)
    {
        var incident = CreateIncident(taskId);
        return new(
            IsAccepted: false,
            RejectionCode: (int)ComplianceReviewRejectionCode.UnknownAuthority,
            Message: "The command was rejected with the current incident snapshot.",
            Incident: ToContract(incident),
            AuditEvent: null,
            WasAlreadyPresent: false);
    }

    private static (ComplianceReviewIncident Incident, HerdrOpsReviewCommandResult Result)
        CreateTransitionResult(
        ComplianceReviewIncident incident,
        ComplianceReviewDecisionKind decision,
        ComplianceReviewerRole role,
        string reviewerActorId,
        Guid commandId,
        Guid provenanceEventId,
        DateTimeOffset occurredUtc)
    {
        var auditEvent = CreateAuditEvent(
            incident,
            decision,
            role,
            reviewerActorId,
            commandId,
            provenanceEventId,
            occurredUtc);
        var updated = ComplianceReviewWorkflowContract.Apply(incident, auditEvent);
        var result = new HerdrOpsReviewCommandResult(
            IsAccepted: true,
            RejectionCode: (int)ComplianceReviewRejectionCode.None,
            Message: "Review decision accepted.",
            Incident: ToContract(updated),
            AuditEvent: ToContract(auditEvent),
            WasAlreadyPresent: false);
        return (updated, result);
    }

    private static ComplianceReviewAuditEvent CreateAuditEvent(
        ComplianceReviewIncident incident,
        ComplianceReviewDecisionKind decision,
        ComplianceReviewerRole role,
        string reviewerActorId,
        Guid commandId,
        Guid provenanceEventId,
        DateTimeOffset occurredUtc)
    {
        var command = new ComplianceReviewCommand(
            ComplianceReviewWorkflowContract.ContractVersion,
            commandId,
            incident.IncidentId,
            incident.State,
            incident.Sequence,
            reviewerActorId,
            decision,
            "The evidence and assigned scope were reviewed.",
            occurredUtc,
            incident.InitialEvidenceIdentitySha256s);
        var authority = new ComplianceReviewAuthority(
            reviewerActorId,
            role,
            provenanceEventId,
            ProvenanceSequence: 10 + incident.Sequence,
            BaseUtc.AddMinutes(1),
            new string('C', 64));
        return ComplianceReviewWorkflowContract.CreateAuditEvent(
            incident,
            command,
            authority);
    }

    private static ComplianceReviewIncident CreateIncident(string taskId) =>
        CreateIncident("INC-HUB-REGISTRATION", taskId);

    private static ComplianceReviewIncident CreateIncident(
        string incidentId,
        string taskId) =>
        ComplianceReviewWorkflowContract.CreateIncident(
            new ComplianceReviewIncidentRegistration(
                ComplianceReviewWorkflowContract.ContractVersion,
                incidentId,
                taskId,
                "backend-worker-01",
                BaseUtc,
                [new string('A', 64)]));

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
}
