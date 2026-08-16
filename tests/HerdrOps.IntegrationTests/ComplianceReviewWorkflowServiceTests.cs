using System.Security.Cryptography;
using System.Text;
using HerdrOps.Contracts.ReviewIpc;
using HerdrOps.Core;
using HerdrOps.Domain.Assignments;
using HerdrOps.Domain.Compliance;
using HerdrOps.Domain.Evidence;
using HerdrOps.Infrastructure.Storage;

namespace HerdrOps.IntegrationTests;

[TestClass]
public sealed class ComplianceReviewWorkflowServiceTests
{
    private static readonly DateTimeOffset BaseUtc =
        new(2026, 8, 16, 3, 0, 0, TimeSpan.Zero);

    [TestMethod]
    public void ServiceUsesPersistedRoleProvenanceForPmLeaderPmWorkflow()
    {
        using var directory = new TemporaryDirectory();
        using var store = CreateStore(directory);
        var roles = SeedRoles(store);
        var evidenceId = SeedIncident(store, directory);
        var service = new ComplianceReviewWorkflowService(store);

        var sent = service.Execute(Command(
            Guid.Parse("11111111-1111-1111-1111-111111111111"),
            ComplianceReviewState.Suspected,
            ComplianceReviewDecisionKind.SendToLeader,
            "project-manager",
            BaseUtc.AddMinutes(3),
            evidenceId));
        var escalated = service.Execute(Command(
            Guid.Parse("22222222-2222-2222-2222-222222222222"),
            ComplianceReviewState.PendingLeader,
            ComplianceReviewDecisionKind.EscalateToProjectManager,
            "backend-leader",
            BaseUtc.AddMinutes(4),
            evidenceId));
        var confirmed = service.Execute(Command(
            Guid.Parse("33333333-3333-3333-3333-333333333333"),
            ComplianceReviewState.PendingProjectManager,
            ComplianceReviewDecisionKind.Confirm,
            "project-manager",
            BaseUtc.AddMinutes(5),
            evidenceId));

        Assert.IsTrue(sent.IsAccepted);
        Assert.IsTrue(escalated.IsAccepted);
        Assert.IsTrue(confirmed.IsAccepted);
        Assert.AreEqual(ComplianceReviewState.Confirmed, confirmed.Incident!.State);
        Assert.AreEqual(roles.ProjectManager.EventId, sent.AuditEvent!.AuthorityProvenanceEventId);
        Assert.AreEqual(
            roles.ProjectManager.ProvenanceEventSha256,
            sent.AuditEvent.AuthorityProvenanceSha256);
        Assert.AreEqual(roles.Leader.EventId, escalated.AuditEvent!.AuthorityProvenanceEventId);
        Assert.AreEqual(
            roles.Leader.ProvenanceEventSha256,
            escalated.AuditEvent.AuthorityProvenanceSha256);
        Assert.AreEqual(ComplianceReviewerRole.ProjectManager, confirmed.AuditEvent!.ReviewerRole);
        Assert.HasCount(3, store.ReadComplianceReviewAudit("INC-27-SERVICE"));
    }

    [TestMethod]
    public void UnobservedAndNonAuthorizedRolesFailClosedWithoutAudit()
    {
        using var directory = new TemporaryDirectory();
        using var store = CreateStore(directory);
        SeedRoles(store, includeWorkerRole: true);
        var evidenceId = SeedIncident(store, directory);
        var service = new ComplianceReviewWorkflowService(store);

        var unobserved = service.Execute(Command(
            Guid.Parse("44444444-4444-4444-4444-444444444444"),
            ComplianceReviewState.Suspected,
            ComplianceReviewDecisionKind.Confirm,
            "unknown-project-manager",
            BaseUtc.AddMinutes(3),
            evidenceId));
        var worker = service.Execute(Command(
            Guid.Parse("55555555-5555-5555-5555-555555555555"),
            ComplianceReviewState.Suspected,
            ComplianceReviewDecisionKind.Confirm,
            "backend-worker-02",
            BaseUtc.AddMinutes(3),
            evidenceId));

        Assert.IsFalse(unobserved.IsAccepted);
        Assert.IsFalse(worker.IsAccepted);
        Assert.AreEqual(ComplianceReviewRejectionCode.UnknownAuthority, unobserved.RejectionCode);
        Assert.AreEqual(ComplianceReviewRejectionCode.UnknownAuthority, worker.RejectionCode);
        Assert.IsEmpty(store.ReadComplianceReviewAudit("INC-27-SERVICE"));
    }

    [TestMethod]
    public void ServiceReturnsSelfReviewStaleAndExactRetryOutcomes()
    {
        using var directory = new TemporaryDirectory();
        using var store = CreateStore(directory);
        SeedRoles(store);
        var evidenceId = SeedIncident(
            store,
            directory,
            subjectActorId: "project-manager");
        var service = new ComplianceReviewWorkflowService(store);
        var selfReviewCommand = Command(
            Guid.Parse("66666666-6666-6666-6666-666666666666"),
            ComplianceReviewState.Suspected,
            ComplianceReviewDecisionKind.Confirm,
            "project-manager",
            BaseUtc.AddMinutes(3),
            evidenceId);
        var selfReview = service.Execute(selfReviewCommand);
        Assert.AreEqual(ComplianceReviewRejectionCode.SelfReview, selfReview.RejectionCode);

        using var secondDirectory = new TemporaryDirectory();
        using var secondStore = CreateStore(secondDirectory);
        SeedRoles(secondStore);
        var secondEvidence = SeedIncident(secondStore, secondDirectory);
        var secondService = new ComplianceReviewWorkflowService(secondStore);
        var acceptedCommand = Command(
            Guid.Parse("77777777-7777-7777-7777-777777777777"),
            ComplianceReviewState.Suspected,
            ComplianceReviewDecisionKind.Dismiss,
            "project-manager",
            BaseUtc.AddMinutes(3),
            secondEvidence);
        var accepted = secondService.Execute(acceptedCommand);
        var retry = secondService.Execute(acceptedCommand);
        var stale = secondService.Execute(Command(
            Guid.Parse("88888888-8888-8888-8888-888888888888"),
            ComplianceReviewState.Suspected,
            ComplianceReviewDecisionKind.Confirm,
            "project-manager",
            BaseUtc.AddMinutes(4),
            secondEvidence));

        Assert.IsTrue(accepted.IsAccepted);
        Assert.IsTrue(retry.IsAccepted);
        Assert.IsTrue(retry.WasAlreadyPresent);
        Assert.AreEqual(accepted.AuditEvent!.AuditSha256, retry.AuditEvent!.AuditSha256);
        Assert.IsFalse(stale.IsAccepted);
        Assert.AreEqual(ComplianceReviewRejectionCode.StaleState, stale.RejectionCode);
        Assert.HasCount(1, secondStore.ReadComplianceReviewAudit("INC-27-SERVICE"));
    }

    [TestMethod]
    public void CapabilitiesExposeOnlyCurrentRoleAndIncidentStateDecisions()
    {
        using var directory = new TemporaryDirectory();
        using var store = CreateStore(directory);
        SeedRoles(store);
        var evidenceId = SeedIncident(store, directory);
        var service = new ComplianceReviewWorkflowService(store);

        var projectManager = service.ReadCapabilities(
            new HerdrOpsReviewCapabilitiesRequest(
                "project-manager",
                "INC-27-SERVICE",
                BaseUtc.AddMinutes(3)));
        Assert.IsTrue(projectManager.HasCurrentAuthority);
        Assert.AreEqual((int)ComplianceReviewerRole.ProjectManager, projectManager.ReviewerRole);
        Assert.AreEqual((int)ComplianceReviewState.Suspected, projectManager.IncidentState);
        CollectionAssert.AreEquivalent(
            new[]
            {
                (int)ComplianceReviewDecisionKind.Confirm,
                (int)ComplianceReviewDecisionKind.SendToLeader,
                (int)ComplianceReviewDecisionKind.Dismiss,
            },
            projectManager.AllowedDecisionKinds.ToArray());

        var sent = service.Execute(Command(
            Guid.Parse("aaaaaaaa-1111-1111-1111-111111111111"),
            ComplianceReviewState.Suspected,
            ComplianceReviewDecisionKind.SendToLeader,
            "project-manager",
            BaseUtc.AddMinutes(3),
            evidenceId));
        Assert.IsTrue(sent.IsAccepted);

        var leader = service.ReadCapabilities(
            new HerdrOpsReviewCapabilitiesRequest(
                "backend-leader",
                "INC-27-SERVICE",
                BaseUtc.AddMinutes(4)));
        Assert.IsTrue(leader.HasCurrentAuthority);
        Assert.AreEqual((int)ComplianceReviewerRole.Leader, leader.ReviewerRole);
        Assert.AreEqual((int)ComplianceReviewState.PendingLeader, leader.IncidentState);
        CollectionAssert.AreEqual(
            new[] { (int)ComplianceReviewDecisionKind.EscalateToProjectManager },
            leader.AllowedDecisionKinds.ToArray());

        var projectManagerAtLeaderState = service.ReadCapabilities(
            new HerdrOpsReviewCapabilitiesRequest(
                "project-manager",
                "INC-27-SERVICE",
                BaseUtc.AddMinutes(4)));
        Assert.IsTrue(projectManagerAtLeaderState.HasCurrentAuthority);
        Assert.IsEmpty(projectManagerAtLeaderState.AllowedDecisionKinds);
    }

    [TestMethod]
    public void UnknownIncidentIsReportedWithoutConsultingClaimedRole()
    {
        using var directory = new TemporaryDirectory();
        using var store = CreateStore(directory);
        SeedRoles(store);
        var service = new ComplianceReviewWorkflowService(store);
        var execution = service.Execute(new ComplianceReviewCommand(
            ComplianceReviewWorkflowContract.ContractVersion,
            Guid.Parse("99999999-9999-9999-9999-999999999999"),
            "INC-MISSING",
            ComplianceReviewState.Suspected,
            ExpectedSequence: 0,
            "project-manager",
            ComplianceReviewDecisionKind.Confirm,
            "The incident does not exist.",
            BaseUtc.AddMinutes(3),
            Array.Empty<string>()));

        Assert.IsFalse(execution.IsAccepted);
        Assert.AreEqual(ComplianceReviewRejectionCode.UnknownIncident, execution.RejectionCode);
        Assert.IsNull(execution.Incident);
    }

    [TestMethod]
    public async Task IpcUsesCoreTimeAndExactRetryDoesNotDependOnAClientTimestamp()
    {
        using var directory = new TemporaryDirectory();
        using var store = CreateStore(directory);
        SeedRoles(store);
        var evidenceId = SeedIncident(store, directory);
        var clock = new MutableReviewTimeProvider(BaseUtc.AddMinutes(3));
        var service = new ComplianceReviewWorkflowService(store, clock);
        var commandId = Guid.Parse("abababab-abab-abab-abab-abababababab");
        var request = new HerdrOpsReviewCommandRequest(
            ComplianceReviewWorkflowContract.ContractVersion,
            commandId,
            "INC-27-SERVICE",
            (int)ComplianceReviewState.Suspected,
            ExpectedSequence: 0,
            "project-manager",
            (int)ComplianceReviewDecisionKind.Confirm,
            "Confirm the evidence-backed incident using Core time.",
            [evidenceId]);

        var accepted = await service.ExecuteAsync(request, commandId, CancellationToken.None);
        clock.Advance(TimeSpan.FromMinutes(1));
        var retry = await service.ExecuteAsync(request, commandId, CancellationToken.None);

        Assert.IsTrue(accepted.IsAccepted);
        Assert.AreEqual(BaseUtc.AddMinutes(3), accepted.AuditEvent!.OccurredUtc);
        Assert.IsTrue(retry.IsAccepted);
        Assert.IsTrue(retry.WasAlreadyPresent);
        Assert.AreEqual(accepted.AuditEvent.AuditSha256, retry.AuditEvent!.AuditSha256);
        Assert.AreEqual(accepted.AuditEvent.OccurredUtc, retry.AuditEvent.OccurredUtc);
        Assert.HasCount(1, store.ReadComplianceReviewAudit("INC-27-SERVICE"));
    }

    private static SqliteHerdrStateStore CreateStore(TemporaryDirectory directory) =>
        new(new HerdrStateStoreOptions(Path.Combine(directory.Path, "herdrops.db")));

    private static (AssignmentCurrentActorRole ProjectManager, AssignmentCurrentActorRole Leader) SeedRoles(
        SqliteHerdrStateStore store,
        bool includeWorkerRole = false)
    {
        var assignment = Event(
            AssignmentLifecycleEventKind.Assignment,
            sequence: 1,
            actorId: "project-manager",
            actorRole: "Project Manager",
            parentEventId: null,
            targetAgentId: "backend-leader");
        var acknowledgement = Event(
            AssignmentLifecycleEventKind.Acknowledgement,
            sequence: 2,
            actorId: "backend-leader",
            actorRole: "Backend Leader",
            parentEventId: assignment.EventId);
        var reducer = new AssignmentLifecycleReducer();
        store.CommitAssignmentLifecycle(reducer.Process(assignment));
        store.CommitAssignmentLifecycle(reducer.Process(acknowledgement));
        if (includeWorkerRole)
        {
            var delegation = Event(
                AssignmentLifecycleEventKind.Delegation,
                sequence: 3,
                actorId: "backend-leader",
                actorRole: "Backend Leader",
                parentEventId: acknowledgement.EventId,
                targetAgentId: "backend-worker-02");
            var workerAcknowledgement = Event(
                AssignmentLifecycleEventKind.Acknowledgement,
                sequence: 4,
                actorId: "backend-worker-02",
                actorRole: "Backend Worker",
                parentEventId: delegation.EventId);
            store.CommitAssignmentLifecycle(reducer.Process(delegation));
            store.CommitAssignmentLifecycle(reducer.Process(workerAcknowledgement));
        }

        var roles = store.ReadCurrentAssignmentRoles();
        return (
            roles.Single(item => item.ActorId == "project-manager"),
            roles.Single(item => item.ActorId == "backend-leader"));
    }

    private static string SeedIncident(
        SqliteHerdrStateStore store,
        TemporaryDirectory directory,
        string subjectActorId = "backend-worker-01")
    {
        var captured = store.CaptureEvidence(
            new EvidenceCaptureRequest(
                EvidenceMetadataContract.ContractVersion,
                "TASK-115",
                subjectActorId,
                "EVENT-SERVICE-EVIDENCE",
                "service-integration-test",
                "redacted://service/evidence.bin",
                BaseUtc,
                BaseUtc.AddSeconds(1),
                BaseUtc.AddDays(30),
                CreateManagedCopy: false),
            Path.Combine(directory.Path, "missing-service-evidence.bin"));
        var evidenceId = captured.StoredEvidence.Metadata.EvidenceIdentitySha256;
        store.RegisterComplianceReviewIncident(new ComplianceReviewIncidentRegistration(
            ComplianceReviewWorkflowContract.ContractVersion,
            "INC-27-SERVICE",
            "TASK-115",
            subjectActorId,
            BaseUtc.AddMinutes(2),
            [evidenceId]));
        return evidenceId;
    }

    private static ComplianceReviewCommand Command(
        Guid commandId,
        ComplianceReviewState expectedState,
        ComplianceReviewDecisionKind decision,
        string reviewerActorId,
        DateTimeOffset occurredUtc,
        string evidenceId) =>
        new(
            ComplianceReviewWorkflowContract.ContractVersion,
            commandId,
            "INC-27-SERVICE",
            expectedState,
            expectedState switch
            {
                ComplianceReviewState.Suspected => 0,
                ComplianceReviewState.PendingLeader => 1,
                ComplianceReviewState.PendingProjectManager => 2,
                _ => 0,
            },
            reviewerActorId,
            decision,
            "The current evidence and assignment scope were reviewed.",
            occurredUtc,
            [evidenceId]);

    private static AssignmentLifecycleEvent Event(
        AssignmentLifecycleEventKind kind,
        long sequence,
        string actorId,
        string actorRole,
        Guid? parentEventId,
        string? targetAgentId = null)
    {
        var occurredUtc = BaseUtc.AddSeconds(sequence);
        return new AssignmentLifecycleEvent(
            AssignmentLifecycleContract.Version,
            Guid.Parse($"00000000-0000-0000-0000-{sequence:000000000000}"),
            kind,
            sequence,
            occurredUtc,
            occurredUtc.AddMilliseconds(100),
            AssignmentLifecycleContract.CoreSource,
            Guid.Parse($"10000000-0000-0000-0000-{sequence:000000000000}"),
            Hash($"submission-{sequence}"),
            "TASK-115",
            actorId,
            actorRole,
            $"Lifecycle event {sequence}.",
            parentEventId,
            targetAgentId,
            ProgressPercent: null,
            DeviationReason: null,
            EvidenceReference: null,
            EvidenceSha256: null,
            HandoffNote: null);
    }

    private static string Hash(string value) => Convert.ToHexString(
        SHA256.HashData(Encoding.UTF8.GetBytes(value)));

    private sealed class MutableReviewTimeProvider(DateTimeOffset utcNow) : TimeProvider
    {
        private DateTimeOffset _utcNow = utcNow;

        public override DateTimeOffset GetUtcNow() => _utcNow;

        public void Advance(TimeSpan duration) => _utcNow = _utcNow.Add(duration);
    }
}
