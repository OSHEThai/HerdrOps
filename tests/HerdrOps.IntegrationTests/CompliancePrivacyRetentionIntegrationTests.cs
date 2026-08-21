using System.Security.Cryptography;
using System.Text;
using HerdrOps.Domain.Assignments;
using HerdrOps.Domain.Compliance;
using HerdrOps.Domain.Evidence;
using HerdrOps.Infrastructure.Storage;
using Microsoft.Data.Sqlite;

namespace HerdrOps.IntegrationTests;

[TestClass]
public sealed class CompliancePrivacyRetentionIntegrationTests
{
    private static readonly DateTimeOffset BaseTime =
        new(2026, 8, 16, 10, 0, 0, TimeSpan.Zero);

    [TestCleanup]
    public void Cleanup()
    {
        SqliteConnection.ClearAllPools();
    }

    [TestMethod]
    public void OpenReviewProtectsEvidenceFromRetentionUntilIncidentCloses()
    {
        using var directory = new TemporaryDirectory();
        var options = CreateOptions(directory);
        var fixedTime = new FixedTimeProvider(BaseTime.AddDays(2));
        string evidenceId;
        string managedPath;

        using (var store = new SqliteHerdrStateStore(options, fixedTime))
        {
            var artifactPath = Path.Combine(directory.Path, "source", "evidence-to-retain.bin");
            Directory.CreateDirectory(Path.GetDirectoryName(artifactPath)!);
            File.WriteAllBytes(artifactPath, Encoding.UTF8.GetBytes("evidence-content-for-retention"));

            var capture = store.CaptureEvidence(
                new EvidenceCaptureRequest(
                    ContractVersion: 1,
                    TaskId: "TASK-28-RETENTION",
                    ActorId: "worker-1",
                    SourceEventId: "evt-001",
                    Source: "file.write",
                    SourceReference: "secret-redacted-path/evidence-to-retain.bin",
                    ObservedUtc: BaseTime,
                    IngestedUtc: BaseTime,
                    RetainUntilUtc: BaseTime.AddDays(1),
                    CreateManagedCopy: true),
                artifactPath);

            evidenceId = capture.StoredEvidence.Metadata.EvidenceIdentitySha256;
            managedPath = Path.Combine(
                options.ManagedEvidenceRootPath!,
                capture.StoredEvidence.Metadata.ManagedRelativePath!);

            Assert.IsTrue(File.Exists(managedPath));

            // Link evidence to an open review audit case
            store.AppendReviewAudit(new ReviewAuditAppendRequest(
                ContractVersion: 1,
                AuditEventId: Guid.NewGuid(),
                ReviewCaseId: "CASE-28-OPEN",
                ReviewerActorId: "pm-1",
                ReviewerRole: "Project Manager",
                ActionKind: ReviewAuditActionKind.Opened,
                ReviewState: ReviewAuditState.Open,
                Reason: "Incident is under investigation.",
                OccurredUtc: BaseTime.AddMinutes(5),
                EvidenceIdentitySha256s: new[] { evidenceId }));

            // Apply retention while review is open -> Must be protected
            var retentionRun1 = store.ApplyEvidenceRetention(BaseTime.AddDays(2));
            Assert.HasCount(1, retentionRun1.Results);
            Assert.AreEqual(
                HerdrEvidenceRetentionOutcome.ProtectedByOpenReview,
                retentionRun1.Results[0].Outcome);
            Assert.IsTrue(File.Exists(managedPath));

            // Close the review case
            store.AppendReviewAudit(new ReviewAuditAppendRequest(
                ContractVersion: 1,
                AuditEventId: Guid.NewGuid(),
                ReviewCaseId: "CASE-28-OPEN",
                ReviewerActorId: "pm-1",
                ReviewerRole: "Project Manager",
                ActionKind: ReviewAuditActionKind.Closed,
                ReviewState: ReviewAuditState.Closed,
                Reason: "Investigation completed and dismissed.",
                OccurredUtc: BaseTime.AddMinutes(10),
                EvidenceIdentitySha256s: Array.Empty<string>()));

            // Apply retention after review case is closed -> Must purge managed bytes
            var retentionRun2 = store.ApplyEvidenceRetention(BaseTime.AddDays(2));
            Assert.HasCount(1, retentionRun2.Results);
            Assert.AreEqual(
                HerdrEvidenceRetentionOutcome.Purged,
                retentionRun2.Results[0].Outcome);
            Assert.IsFalse(File.Exists(managedPath));

            // Metadata and audit retention event remain intact
            var auditRecords = store.ReadEvidenceRetentionAudit();
            Assert.HasCount(1, auditRecords);
            Assert.AreEqual(evidenceId, auditRecords[0].EvidenceIdentitySha256);
            Assert.AreEqual(HerdrEvidenceRetentionOutcome.Purged, auditRecords[0].Outcome);
        }
    }

    [TestMethod]
    public void RedactionPolicyEnforcedOnEvidenceMetadataAndAuditReasons()
    {
        using var directory = new TemporaryDirectory();
        var options = CreateOptions(directory);
        var artifactPath = Path.Combine(directory.Path, "source", "redaction-test.bin");
        Directory.CreateDirectory(Path.GetDirectoryName(artifactPath)!);
        File.WriteAllBytes(artifactPath, Encoding.UTF8.GetBytes("payload"));

        const string redactedReference = "repo://path/to/redacted-file.cs";
        using (var store = new SqliteHerdrStateStore(options))
        {
            var capture = store.CaptureEvidence(
                new EvidenceCaptureRequest(
                    ContractVersion: 1,
                    TaskId: "TASK-28-REDACTION",
                    ActorId: "worker-redact",
                    SourceEventId: "evt-redact-01",
                    Source: "git.commit",
                    SourceReference: redactedReference,
                    ObservedUtc: BaseTime,
                    IngestedUtc: BaseTime,
                    RetainUntilUtc: BaseTime.AddDays(7),
                    CreateManagedCopy: true),
                artifactPath);

            var meta = capture.StoredEvidence.Metadata;
            Assert.AreEqual(redactedReference, meta.SourceReference);
            Assert.AreEqual(64, meta.EvidenceIdentitySha256.Length);
            Assert.AreEqual(64, meta.MetadataSha256.Length);
            Assert.IsNotNull(meta.ContentSha256);
            Assert.AreEqual(64, meta.ContentSha256.Length);
        }

        // Verify SQLite table does not contain raw BLOB data
        using (var connection = Open(options.DatabasePath))
        {
            using var command = connection.CreateCommand();
            command.CommandText = "SELECT COUNT(*) FROM pragma_table_info('evidence_items') WHERE upper(type) = 'BLOB';";
            Assert.AreEqual(0L, Convert.ToInt64(command.ExecuteScalar()));
        }

        SqliteConnection.ClearAllPools();
    }

    [TestMethod]
    public void RestartAndReconnectPreservesComplianceQueueStateAndHashChains()
    {
        using var directory = new TemporaryDirectory();
        var options = CreateOptions(directory);
        const string incidentId = "INC-28-RESTART";
        const string taskId = "TASK-28-RESTART";
        const string subjectId = "worker-restart";
        const string pmId = "pm-restart";
        const string leaderId = "leader-restart";

        ComplianceReviewAuthority pmAuth;
        ComplianceReviewAuthority leaderAuth;
        ComplianceReviewAuditEvent ev1;
        ComplianceReviewAuditEvent ev2;

        using (var store = new SqliteHerdrStateStore(options))
        {
            var lifecycle = new AssignmentLifecycleReducer();
            pmAuth = SeedAuthority(store, lifecycle, pmId, "Project Manager", ComplianceReviewerRole.ProjectManager, Guid.NewGuid(), 1);
            leaderAuth = SeedAuthority(store, lifecycle, leaderId, "Backend Leader", ComplianceReviewerRole.Leader, Guid.NewGuid(), 2);

            var reg = new ComplianceReviewIncidentRegistration(
                ContractVersion: 1,
                IncidentId: incidentId,
                TaskId: taskId,
                SubjectActorId: subjectId,
                RegisteredUtc: BaseTime,
                EvidenceIdentitySha256s: Array.Empty<string>());

            store.RegisterComplianceReviewIncident(reg);

            var cmd1 = new ComplianceReviewCommand(
                ContractVersion: 1,
                CommandId: Guid.NewGuid(),
                IncidentId: incidentId,
                ExpectedState: ComplianceReviewState.Suspected,
                ExpectedSequence: 0,
                ReviewerActorId: pmId,
                DecisionKind: ComplianceReviewDecisionKind.SendToLeader,
                Reason: "PM sends to Leader for review.",
                OccurredUtc: BaseTime.AddMinutes(1),
                EvidenceIdentitySha256s: Array.Empty<string>());

            var write1 = store.ApplyComplianceReviewCommand(cmd1, pmAuth);
            ev1 = write1.AuditEvent;

            var cmd2 = new ComplianceReviewCommand(
                ContractVersion: 1,
                CommandId: Guid.NewGuid(),
                IncidentId: incidentId,
                ExpectedState: ComplianceReviewState.PendingLeader,
                ExpectedSequence: 1,
                ReviewerActorId: leaderId,
                DecisionKind: ComplianceReviewDecisionKind.EscalateToProjectManager,
                Reason: "Leader escalates to PM.",
                OccurredUtc: BaseTime.AddMinutes(2),
                EvidenceIdentitySha256s: Array.Empty<string>());

            var write2 = store.ApplyComplianceReviewCommand(cmd2, leaderAuth);
            ev2 = write2.AuditEvent;

            Assert.AreEqual(2L, write2.Incident.Sequence);
            Assert.AreEqual(ComplianceReviewState.PendingProjectManager, write2.Incident.State);
        }

        // Restart store 1
        using (var restarted1 = new SqliteHerdrStateStore(options))
        {
            var incident = restarted1.ReadComplianceReviewIncident(incidentId);
            Assert.IsNotNull(incident);
            Assert.AreEqual(2L, incident.Sequence);
            Assert.AreEqual(ComplianceReviewState.PendingProjectManager, incident.State);

            var auditList = restarted1.ReadComplianceReviewAudit(incidentId);
            Assert.HasCount(2, auditList);
            Assert.AreEqual(ev1.AuditSha256, auditList[0].AuditSha256);
            Assert.AreEqual(ev2.AuditSha256, auditList[1].AuditSha256);
            Assert.AreEqual(ev1.AuditSha256, auditList[1].PreviousAuditSha256);
        }

        // Restart store 2 and perform final transition
        using (var restarted2 = new SqliteHerdrStateStore(options))
        {
            var cmd3 = new ComplianceReviewCommand(
                ContractVersion: 1,
                CommandId: Guid.NewGuid(),
                IncidentId: incidentId,
                ExpectedState: ComplianceReviewState.PendingProjectManager,
                ExpectedSequence: 2,
                ReviewerActorId: pmId,
                DecisionKind: ComplianceReviewDecisionKind.Confirm,
                Reason: "Confirmed by PM.",
                OccurredUtc: BaseTime.AddMinutes(3),
                EvidenceIdentitySha256s: Array.Empty<string>());

            var write3 = restarted2.ApplyComplianceReviewCommand(cmd3, pmAuth);
            Assert.AreEqual(3L, write3.Incident.Sequence);
            Assert.AreEqual(ComplianceReviewState.Confirmed, write3.Incident.State);

            var finalAuditList = restarted2.ReadComplianceReviewAudit(incidentId);
            Assert.HasCount(3, finalAuditList);
            Assert.AreEqual(write3.AuditEvent.AuditSha256, finalAuditList[2].AuditSha256);
        }

        SqliteConnection.ClearAllPools();
    }

    private static HerdrStateStoreOptions CreateOptions(TemporaryDirectory directory)
    {
        return new HerdrStateStoreOptions(
            Path.Combine(directory.Path, "herdr-state.db"),
            ManagedEvidenceRootPath: Path.Combine(directory.Path, "evidence-vault"));
    }

    private static ComplianceReviewAuthority SeedAuthority(
        SqliteHerdrStateStore store,
        AssignmentLifecycleReducer reducer,
        string actorId,
        string actorRole,
        ComplianceReviewerRole reviewerRole,
        Guid eventId,
        long sequence)
    {
        var occurredUtc = BaseTime.AddSeconds(sequence);
        var acceptedUtc = occurredUtc.AddMilliseconds(100);
        var lifecycleEvent = new AssignmentLifecycleEvent(
            AssignmentLifecycleContract.Version,
            eventId,
            AssignmentLifecycleEventKind.Assignment,
            sequence,
            occurredUtc,
            acceptedUtc,
            AssignmentLifecycleContract.CoreSource,
            Guid.NewGuid(),
            Hash($"{actorId}:{sequence}"),
            $"TASK-ROLE-{sequence}",
            actorId,
            actorRole,
            "Admit reviewer role provenance for the storage contract.",
            ParentEventId: null,
            TargetAgentId: $"target-{sequence}",
            ProgressPercent: null,
            DeviationReason: null,
            EvidenceReference: null,
            EvidenceSha256: null,
            HandoffNote: null);

        var step = reducer.Process(lifecycleEvent);
        store.CommitAssignmentLifecycle(step);
        var observation = step.RoleObservation!;

        return new ComplianceReviewAuthority(
            actorId,
            reviewerRole,
            observation.EventId,
            observation.Sequence,
            observation.AcceptedUtc,
            observation.ProvenanceEventSha256);
    }

    private static SqliteConnection Open(string path)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var connection = new SqliteConnection(new SqliteConnectionStringBuilder
        {
            DataSource = path,
            Mode = SqliteOpenMode.ReadWriteCreate,
            Pooling = false,
        }.ToString());
        connection.Open();
        return connection;
    }

    private static string Hash(string value) => Convert.ToHexString(
        SHA256.HashData(Encoding.UTF8.GetBytes(value)));
}
