using HerdrOps.Domain.Compliance;

namespace HerdrOps.UnitTests;

[TestClass]
public sealed class ComplianceReviewWorkflowTests
{
    private static readonly DateTimeOffset RegisteredUtc =
        new(2026, 8, 16, 1, 0, 0, TimeSpan.Zero);

    [TestMethod]
    public void ProjectManagerCanConfirmSuspectedIncidentWithAttributableAudit()
    {
        var incident = CreateIncident();
        var command = CreateCommand(
            ComplianceReviewDecisionKind.Confirm,
            ComplianceReviewState.Suspected,
            "project-manager");
        var authority = CreateAuthority(
            "project-manager",
            ComplianceReviewerRole.ProjectManager);

        var auditEvent = ComplianceReviewWorkflowContract.CreateAuditEvent(
            incident,
            command,
            authority);
        var updated = ComplianceReviewWorkflowContract.Apply(incident, auditEvent);

        Assert.AreEqual(ComplianceReviewState.Confirmed, updated.State);
        Assert.AreEqual(1L, updated.Sequence);
        Assert.AreEqual(command.CommandId, updated.LastAuditEventId);
        Assert.AreEqual("project-manager", auditEvent.ReviewerActorId);
        Assert.AreEqual(ComplianceReviewerRole.ProjectManager, auditEvent.ReviewerRole);
        Assert.AreEqual(authority.ProvenanceEventId, auditEvent.AuthorityProvenanceEventId);
        Assert.AreEqual(authority.ProvenanceSha256, auditEvent.AuthorityProvenanceSha256);
        Assert.AreEqual(64, auditEvent.EvidenceSetSha256.Length);
        Assert.AreEqual(64, auditEvent.AuditSha256.Length);
    }

    [TestMethod]
    public void LeaderAndProjectManagerDecisionsRemainSeparatelyAttributable()
    {
        var incident = CreateIncident();
        var sent = Apply(
            incident,
            CreateCommand(
                ComplianceReviewDecisionKind.SendToLeader,
                ComplianceReviewState.Suspected,
                "project-manager",
                Guid.Parse("11111111-1111-1111-1111-111111111111")),
            CreateAuthority(
                "project-manager",
                ComplianceReviewerRole.ProjectManager,
                Guid.Parse("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")));
        var escalated = Apply(
            sent.Incident,
            CreateCommand(
                ComplianceReviewDecisionKind.EscalateToProjectManager,
                ComplianceReviewState.PendingLeader,
                "backend-leader",
                Guid.Parse("22222222-2222-2222-2222-222222222222"),
                RegisteredUtc.AddMinutes(3)),
            CreateAuthority(
                "backend-leader",
                ComplianceReviewerRole.Leader,
                Guid.Parse("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")));
        var confirmed = Apply(
            escalated.Incident,
            CreateCommand(
                ComplianceReviewDecisionKind.Confirm,
                ComplianceReviewState.PendingProjectManager,
                "project-manager",
                Guid.Parse("33333333-3333-3333-3333-333333333333"),
                RegisteredUtc.AddMinutes(4)),
            CreateAuthority(
                "project-manager",
                ComplianceReviewerRole.ProjectManager,
                Guid.Parse("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")));

        Assert.AreEqual(ComplianceReviewState.PendingLeader, sent.Incident.State);
        Assert.AreEqual(ComplianceReviewState.PendingProjectManager, escalated.Incident.State);
        Assert.AreEqual(ComplianceReviewState.Confirmed, confirmed.Incident.State);
        Assert.AreEqual(ComplianceReviewerRole.ProjectManager, sent.Event.ReviewerRole);
        Assert.AreEqual(ComplianceReviewerRole.Leader, escalated.Event.ReviewerRole);
        Assert.AreEqual(ComplianceReviewerRole.ProjectManager, confirmed.Event.ReviewerRole);
        Assert.AreEqual(sent.Event.AuditSha256, escalated.Event.PreviousAuditSha256);
        Assert.AreEqual(escalated.Event.AuditSha256, confirmed.Event.PreviousAuditSha256);
        Assert.AreEqual(3L, confirmed.Event.Sequence);
    }

    [TestMethod]
    public void IncidentSubjectCannotReviewTheirOwnIncident()
    {
        var incident = CreateIncident(subjectActorId: "project-manager");
        var authorization = ComplianceReviewWorkflowContract.Authorize(
            incident,
            CreateCommand(
                ComplianceReviewDecisionKind.Confirm,
                ComplianceReviewState.Suspected,
                "project-manager"),
            CreateAuthority(
                "project-manager",
                ComplianceReviewerRole.ProjectManager));

        Assert.IsFalse(authorization.IsAuthorized);
        Assert.AreEqual(ComplianceReviewRejectionCode.SelfReview, authorization.RejectionCode);
        Assert.IsNull(authorization.ResultState);
    }

    [TestMethod]
    public void MissingOrMismatchedAuthorityFailsClosed()
    {
        var incident = CreateIncident();
        var command = CreateCommand(
            ComplianceReviewDecisionKind.Confirm,
            ComplianceReviewState.Suspected,
            "project-manager");

        var missing = ComplianceReviewWorkflowContract.Authorize(
            incident,
            command,
            authority: null);
        var mismatched = ComplianceReviewWorkflowContract.Authorize(
            incident,
            command,
            CreateAuthority("different-actor", ComplianceReviewerRole.ProjectManager));

        Assert.AreEqual(ComplianceReviewRejectionCode.UnknownAuthority, missing.RejectionCode);
        Assert.AreEqual(ComplianceReviewRejectionCode.UnknownAuthority, mismatched.RejectionCode);
    }

    [TestMethod]
    public void RolePermissionsAndStateTransitionsAreBothEnforced()
    {
        var incident = CreateIncident();
        var leaderConfirm = ComplianceReviewWorkflowContract.Authorize(
            incident,
            CreateCommand(
                ComplianceReviewDecisionKind.Confirm,
                ComplianceReviewState.Suspected,
                "backend-leader"),
            CreateAuthority("backend-leader", ComplianceReviewerRole.Leader));
        var projectManagerEscalation = ComplianceReviewWorkflowContract.Authorize(
            incident,
            CreateCommand(
                ComplianceReviewDecisionKind.EscalateToProjectManager,
                ComplianceReviewState.Suspected,
                "project-manager"),
            CreateAuthority("project-manager", ComplianceReviewerRole.ProjectManager));

        Assert.AreEqual(
            ComplianceReviewRejectionCode.UnauthorizedRole,
            leaderConfirm.RejectionCode);
        Assert.AreEqual(
            ComplianceReviewRejectionCode.UnauthorizedRole,
            projectManagerEscalation.RejectionCode);
    }

    [TestMethod]
    public void StaleStateAndFutureAuthorityAreRejectedBeforeMutation()
    {
        var incident = CreateIncident();
        var stale = ComplianceReviewWorkflowContract.Authorize(
            incident,
            CreateCommand(
                ComplianceReviewDecisionKind.Confirm,
                ComplianceReviewState.PendingProjectManager,
                "project-manager"),
            CreateAuthority("project-manager", ComplianceReviewerRole.ProjectManager));
        var futureAuthority = ComplianceReviewWorkflowContract.Authorize(
            incident,
            CreateCommand(
                ComplianceReviewDecisionKind.Confirm,
                ComplianceReviewState.Suspected,
                "project-manager"),
            CreateAuthority(
                "project-manager",
                ComplianceReviewerRole.ProjectManager) with
            {
                AcceptedUtc = RegisteredUtc.AddMinutes(5),
            });

        Assert.AreEqual(ComplianceReviewRejectionCode.StaleState, stale.RejectionCode);
        Assert.AreEqual(
            ComplianceReviewRejectionCode.AuthorityNotYetEffective,
            futureAuthority.RejectionCode);
    }

    [TestMethod]
    public void RepeatedStateStillRequiresTheExactIncidentSequence()
    {
        var projectManager = CreateAuthority(
            "project-manager",
            ComplianceReviewerRole.ProjectManager);
        var leader = CreateAuthority(
            "backend-leader",
            ComplianceReviewerRole.Leader);
        var firstLeaderState = Apply(
            CreateIncident(),
            CreateCommand(
                ComplianceReviewDecisionKind.SendToLeader,
                ComplianceReviewState.Suspected,
                "project-manager",
                Guid.Parse("44444444-4444-4444-4444-444444444444")),
            projectManager).Incident;
        var projectManagerState = Apply(
            firstLeaderState,
            CreateCommand(
                ComplianceReviewDecisionKind.EscalateToProjectManager,
                ComplianceReviewState.PendingLeader,
                "backend-leader",
                Guid.Parse("55555555-5555-5555-5555-555555555555"),
                RegisteredUtc.AddMinutes(3)),
            leader).Incident;
        var secondLeaderState = Apply(
            projectManagerState,
            CreateCommand(
                ComplianceReviewDecisionKind.SendToLeader,
                ComplianceReviewState.PendingProjectManager,
                "project-manager",
                Guid.Parse("66666666-6666-6666-6666-666666666666"),
                RegisteredUtc.AddMinutes(4)),
            projectManager).Incident;

        var stale = ComplianceReviewWorkflowContract.Authorize(
            secondLeaderState,
            CreateCommand(
                ComplianceReviewDecisionKind.EscalateToProjectManager,
                ComplianceReviewState.PendingLeader,
                "backend-leader",
                Guid.Parse("77777777-7777-7777-7777-777777777777"),
                RegisteredUtc.AddMinutes(5),
                expectedSequence: 1),
            leader);

        Assert.AreEqual(ComplianceReviewState.PendingLeader, secondLeaderState.State);
        Assert.AreEqual(3L, secondLeaderState.Sequence);
        Assert.IsFalse(stale.IsAuthorized);
        Assert.AreEqual(ComplianceReviewRejectionCode.StaleState, stale.RejectionCode);
    }

    [TestMethod]
    public void CanonicalEvidenceOrderingProducesStableRegistrationAndAuditHashes()
    {
        var first = CreateIncident([new string('B', 64), new string('A', 64)]);
        var second = CreateIncident([new string('A', 64), new string('B', 64)]);
        var command = CreateCommand(
            ComplianceReviewDecisionKind.Dismiss,
            ComplianceReviewState.Suspected,
            "project-manager",
            evidence: [new string('B', 64), new string('A', 64)]);
        var authority = CreateAuthority(
            "project-manager",
            ComplianceReviewerRole.ProjectManager);

        var firstAudit = ComplianceReviewWorkflowContract.CreateAuditEvent(
            first,
            command,
            authority);
        var secondAudit = ComplianceReviewWorkflowContract.CreateAuditEvent(
            second,
            command,
            authority);

        Assert.AreEqual(first.RegistrationSha256, second.RegistrationSha256);
        Assert.AreEqual(firstAudit.AuditSha256, secondAudit.AuditSha256);
        CollectionAssert.AreEqual(
            new[] { new string('A', 64), new string('B', 64) },
            firstAudit.EvidenceIdentitySha256s.ToArray());
    }

    [TestMethod]
    public void TamperedAuditHashDoesNotValidateOrApply()
    {
        var incident = CreateIncident();
        var auditEvent = ComplianceReviewWorkflowContract.CreateAuditEvent(
            incident,
            CreateCommand(
                ComplianceReviewDecisionKind.Confirm,
                ComplianceReviewState.Suspected,
                "project-manager"),
            CreateAuthority("project-manager", ComplianceReviewerRole.ProjectManager));

        Assert.ThrowsExactly<ComplianceReviewContractException>(() =>
            ComplianceReviewWorkflowContract.Apply(
                incident,
                auditEvent with { AuditSha256 = new string('0', 64) }));
    }

    private static ComplianceReviewIncident CreateIncident(
        IReadOnlyList<string>? evidence = null,
        string subjectActorId = "backend-worker-01") =>
        ComplianceReviewWorkflowContract.CreateIncident(
            new ComplianceReviewIncidentRegistration(
                ComplianceReviewWorkflowContract.ContractVersion,
                "INC-2026-0001",
                "TASK-115",
                subjectActorId,
                RegisteredUtc,
                evidence ?? [new string('A', 64)]));

    private static ComplianceReviewCommand CreateCommand(
        ComplianceReviewDecisionKind decision,
        ComplianceReviewState expectedState,
        string reviewerActorId,
        Guid? commandId = null,
        DateTimeOffset? occurredUtc = null,
        IReadOnlyList<string>? evidence = null,
        long? expectedSequence = null) =>
        new(
            ComplianceReviewWorkflowContract.ContractVersion,
            commandId ?? Guid.Parse("99999999-9999-9999-9999-999999999999"),
            "INC-2026-0001",
            expectedState,
            expectedSequence ?? expectedState switch
            {
                ComplianceReviewState.Suspected => 0,
                ComplianceReviewState.PendingLeader => 1,
                ComplianceReviewState.PendingProjectManager => 2,
                _ => 0,
            },
            reviewerActorId,
            decision,
            "The evidence and assigned scope were reviewed.",
            occurredUtc ?? RegisteredUtc.AddMinutes(2),
            evidence ?? [new string('A', 64)]);

    private static ComplianceReviewAuthority CreateAuthority(
        string actorId,
        ComplianceReviewerRole role,
        Guid? provenanceEventId = null) =>
        new(
            actorId,
            role,
            provenanceEventId ?? Guid.Parse("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"),
            ProvenanceSequence: 10,
            RegisteredUtc.AddMinutes(1),
            new string('C', 64));

    private static (ComplianceReviewIncident Incident, ComplianceReviewAuditEvent Event) Apply(
        ComplianceReviewIncident incident,
        ComplianceReviewCommand command,
        ComplianceReviewAuthority authority)
    {
        var auditEvent = ComplianceReviewWorkflowContract.CreateAuditEvent(
            incident,
            command,
            authority);
        return (
            ComplianceReviewWorkflowContract.Apply(incident, auditEvent),
            auditEvent);
    }
}
