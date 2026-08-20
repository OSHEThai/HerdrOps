using System.Diagnostics;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using HerdrOps.Domain.Assignments;
using HerdrOps.Domain.Compliance;
using HerdrOps.Domain.Evidence;
using HerdrOps.Domain.Lifecycle;
using HerdrOps.Infrastructure.Storage;
using Microsoft.Data.Sqlite;

namespace HerdrOps.IntegrationTests;

[TestClass]
public sealed class EvidenceAuditStorageTests
{
    private static readonly DateTimeOffset ObservedUtc =
        new(2026, 8, 15, 8, 0, 0, TimeSpan.Zero);

    [TestMethod]
    public void SchemaVersionThreeCreatesExactImmutableEvidenceLedgers()
    {
        using var directory = new TemporaryDirectory();
        var options = CreateOptions(directory);
        var migration = SqliteHerdrStateStore.GetMigrationForTesting(3);
        Assert.AreEqual("evidence-metadata-review-retention-audit", migration.Name);
        Assert.HasCount(64, migration.ScriptSha256);

        using (var store = new SqliteHerdrStateStore(options))
        {
            Assert.AreEqual(
                HerdrStateStoreOptions.CurrentSchemaVersion,
                store.GetDiagnostics().SchemaVersion);
        }

        using var connection = Open(options.DatabasePath);
        using var command = connection.CreateCommand();
        command.CommandText = """
            SELECT COUNT(*)
            FROM sqlite_master
            WHERE type = 'table'
              AND name IN (
                  'evidence_items',
                  'review_audit_events',
                  'review_audit_evidence',
                  'evidence_retention_events');
            """;
        Assert.AreEqual(4L, Convert.ToInt64(command.ExecuteScalar()));
        command.CommandText = """
            SELECT COUNT(*)
            FROM sqlite_master
            WHERE type = 'trigger'
              AND name IN (
                  'evidence_items_reject_update',
                  'evidence_items_reject_delete',
                  'review_audit_events_reject_update',
                  'review_audit_events_reject_delete',
                  'review_audit_evidence_reject_update',
                  'review_audit_evidence_reject_delete',
                  'evidence_retention_events_reject_update',
                  'evidence_retention_events_reject_delete');
            """;
        Assert.AreEqual(8L, Convert.ToInt64(command.ExecuteScalar()));
        command.CommandText = "SELECT script_sha256 FROM schema_migrations WHERE version = 3;";
        Assert.AreEqual(migration.ScriptSha256, Convert.ToString(command.ExecuteScalar()));
        command.CommandText = "PRAGMA user_version;";
        Assert.AreEqual(
            (long)HerdrStateStoreOptions.CurrentSchemaVersion,
            Convert.ToInt64(command.ExecuteScalar()));
    }

    [TestMethod]
    public void ChangedBytesProduceDifferentIdentityAndManagedBytesStayOutsideSqlite()
    {
        using var directory = new TemporaryDirectory();
        var artifactPath = Path.Combine(directory.Path, "source", "artifact.bin");
        Directory.CreateDirectory(Path.GetDirectoryName(artifactPath)!);
        File.WriteAllBytes(artifactPath, Encoding.UTF8.GetBytes("first-content"));
        var options = CreateOptions(directory);
        using var store = new SqliteHerdrStateStore(options);

        var first = store.CaptureEvidence(CreateCaptureRequest(), artifactPath);
        File.WriteAllBytes(artifactPath, Encoding.UTF8.GetBytes("changed-content"));
        var changed = store.CaptureEvidence(CreateCaptureRequest(), artifactPath);

        Assert.AreNotEqual(
            first.StoredEvidence.Metadata.EvidenceIdentitySha256,
            changed.StoredEvidence.Metadata.EvidenceIdentitySha256);
        Assert.IsTrue(first.StoredEvidence.ManagedBytesAvailable);
        Assert.IsTrue(changed.StoredEvidence.ManagedBytesAvailable);
        Assert.AreEqual(EvidenceArtifactStorageKind.ManagedCopy, first.StoredEvidence.Metadata.StorageKind);
        Assert.IsFalse(first.WasAlreadyPresent);
        var firstManagedPath = ResolveManagedPath(options, first.StoredEvidence.Metadata);
        Assert.IsTrue(File.Exists(firstManagedPath));
        StringAssert.StartsWith(firstManagedPath, options.ManagedEvidenceRootPath!, StringComparison.OrdinalIgnoreCase);

        using var connection = Open(options.DatabasePath);
        using var command = connection.CreateCommand();
        command.CommandText = """
            SELECT COUNT(*)
            FROM pragma_table_info('evidence_items')
            WHERE upper(type) = 'BLOB';
            """;
        Assert.AreEqual(0L, Convert.ToInt64(command.ExecuteScalar()));
    }

    [TestMethod]
    public void MissingArtifactIsExplicitAndCaptureIsIdempotent()
    {
        using var directory = new TemporaryDirectory();
        var options = CreateOptions(directory);
        using var store = new SqliteHerdrStateStore(options);
        var missingPath = Path.Combine(directory.Path, "missing", "not-created.bin");
        var request = CreateCaptureRequest();

        var first = store.CaptureEvidence(request, missingPath);
        var retry = store.CaptureEvidence(request, missingPath);

        Assert.IsFalse(first.WasAlreadyPresent);
        Assert.IsTrue(retry.WasAlreadyPresent);
        Assert.AreEqual(
            first.StoredEvidence.Metadata.EvidenceIdentitySha256,
            retry.StoredEvidence.Metadata.EvidenceIdentitySha256);
        Assert.AreEqual(EvidenceArtifactAvailability.Missing, first.StoredEvidence.Metadata.Availability);
        Assert.AreEqual(EvidenceArtifactStorageKind.ExternalReference, first.StoredEvidence.Metadata.StorageKind);
        Assert.IsNull(first.StoredEvidence.Metadata.ContentSha256);
        Assert.IsFalse(first.StoredEvidence.ManagedBytesAvailable);
        Assert.IsFalse(first.StoredEvidence.RetentionCompleted);
    }

    [TestMethod]
    public void UnicodeTaskAndReviewIdentifiersRoundTripThroughStorage()
    {
        using var directory = new TemporaryDirectory();
        var options = CreateOptions(directory);
        using var store = new SqliteHerdrStateStore(options);
        var request = CreateCaptureRequest(createManagedCopy: false) with
        {
            TaskId = "งาน-25",
        };
        var captured = store.CaptureEvidence(
            request,
            Path.Combine(directory.Path, "missing-unicode.bin"));
        var identity = captured.StoredEvidence.Metadata.EvidenceIdentitySha256;
        var auditRequest = CreateReviewRequest(
            Guid.Parse("55555555-5555-5555-5555-555555555555"),
            ReviewAuditActionKind.Opened,
            ReviewAuditState.Open,
            new[] { identity },
            ObservedUtc.AddMinutes(2)) with
        {
            ReviewCaseId = "ตรวจสอบ-25",
        };
        store.AppendReviewAudit(auditRequest);

        Assert.HasCount(1, store.ReadTaskEvidence("งาน-25"));
        Assert.HasCount(1, store.ReadReviewAudit("ตรวจสอบ-25"));
    }

    [TestMethod]
    public void ReviewHistoryIsHashChainedAndRejectsOrdinaryMutation()
    {
        using var directory = new TemporaryDirectory();
        var options = CreateOptions(directory);
        using var store = new SqliteHerdrStateStore(options);
        var missing = store.CaptureEvidence(
            CreateCaptureRequest(createManagedCopy: false),
            Path.Combine(directory.Path, "missing.bin"));
        var identity = missing.StoredEvidence.Metadata.EvidenceIdentitySha256;
        var openedRequest = CreateReviewRequest(
            Guid.Parse("11111111-1111-1111-1111-111111111111"),
            ReviewAuditActionKind.Opened,
            ReviewAuditState.Open,
            new[] { identity },
            ObservedUtc.AddMinutes(2));
        var opened = store.AppendReviewAudit(openedRequest);
        var retry = store.AppendReviewAudit(openedRequest);
        var note = store.AppendReviewAudit(CreateReviewRequest(
            Guid.Parse("22222222-2222-2222-2222-222222222222"),
            ReviewAuditActionKind.NoteAdded,
            ReviewAuditState.Open,
            new[] { identity },
            ObservedUtc.AddMinutes(3)));

        Assert.IsFalse(opened.WasAlreadyPresent);
        Assert.IsTrue(retry.WasAlreadyPresent);
        Assert.AreEqual(opened.StoredEvent.AuditSha256, note.StoredEvent.PreviousAuditSha256);
        var history = store.ReadReviewAudit("REVIEW-25");
        Assert.HasCount(2, history);
        Assert.AreEqual(1L, history[0].Sequence);
        Assert.AreEqual(2L, history[1].Sequence);

        using var connection = Open(options.DatabasePath);
        using var command = connection.CreateCommand();
        command.CommandText = """
            UPDATE review_audit_events
            SET reason = 'rewritten'
            WHERE audit_event_id = '11111111-1111-1111-1111-111111111111';
            """;
        var updateException = Assert.Throws<SqliteException>(() => command.ExecuteNonQuery());
        StringAssert.Contains(updateException.Message, "append-only", StringComparison.OrdinalIgnoreCase);
        command.CommandText = """
            DELETE FROM review_audit_evidence
            WHERE audit_event_id = '11111111-1111-1111-1111-111111111111';
            """;
        var deleteException = Assert.Throws<SqliteException>(() => command.ExecuteNonQuery());
        StringAssert.Contains(deleteException.Message, "append-only", StringComparison.OrdinalIgnoreCase);
        command.CommandText = """
            UPDATE evidence_items
            SET source = 'rewritten'
            WHERE evidence_identity_sha256 = $identity;
            """;
        command.Parameters.AddWithValue("$identity", identity);
        var metadataException = Assert.Throws<SqliteException>(() => command.ExecuteNonQuery());
        StringAssert.Contains(metadataException.Message, "append-only", StringComparison.OrdinalIgnoreCase);
    }

    [TestMethod]
    public void RetentionProtectsOpenReviewThenPurgesBytesAndPreservesHistory()
    {
        using var directory = new TemporaryDirectory();
        var artifactPath = Path.Combine(directory.Path, "source", "retained.bin");
        Directory.CreateDirectory(Path.GetDirectoryName(artifactPath)!);
        File.WriteAllBytes(artifactPath, Encoding.UTF8.GetBytes("retention-content"));
        var options = CreateOptions(directory);
        var fixedTime = new FixedTimeProvider(ObservedUtc.AddDays(2));
        using var store = new SqliteHerdrStateStore(options, fixedTime);
        var captured = store.CaptureEvidence(
            CreateCaptureRequest(retainUntilUtc: ObservedUtc.AddDays(1)),
            artifactPath);
        var identity = captured.StoredEvidence.Metadata.EvidenceIdentitySha256;
        var managedPath = ResolveManagedPath(options, captured.StoredEvidence.Metadata);
        store.AppendReviewAudit(CreateReviewRequest(
            Guid.Parse("33333333-3333-3333-3333-333333333333"),
            ReviewAuditActionKind.Opened,
            ReviewAuditState.Open,
            new[] { identity },
            ObservedUtc.AddMinutes(2)));

        var protectedRun = store.ApplyEvidenceRetention(ObservedUtc.AddDays(2));
        Assert.HasCount(1, protectedRun.Results);
        Assert.AreEqual(
            HerdrEvidenceRetentionOutcome.ProtectedByOpenReview,
            protectedRun.Results[0].Outcome);
        Assert.IsTrue(File.Exists(managedPath));
        Assert.IsEmpty(store.ReadEvidenceRetentionAudit());

        store.AppendReviewAudit(CreateReviewRequest(
            Guid.Parse("44444444-4444-4444-4444-444444444444"),
            ReviewAuditActionKind.Closed,
            ReviewAuditState.Closed,
            Array.Empty<string>(),
            ObservedUtc.AddMinutes(3)));
        var purgeRun = store.ApplyEvidenceRetention(ObservedUtc.AddDays(2));

        Assert.HasCount(1, purgeRun.Results);
        Assert.AreEqual(HerdrEvidenceRetentionOutcome.Purged, purgeRun.Results[0].Outcome);
        Assert.IsFalse(File.Exists(managedPath));
        var retainedMetadata = store.ReadEvidence(identity);
        Assert.IsNotNull(retainedMetadata);
        Assert.AreEqual(identity, retainedMetadata.Metadata.EvidenceIdentitySha256);
        Assert.IsFalse(retainedMetadata.ManagedBytesAvailable);
        Assert.IsTrue(retainedMetadata.RetentionCompleted);
        Assert.HasCount(2, store.ReadReviewAudit("REVIEW-25"));
        Assert.HasCount(1, store.ReadEvidenceRetentionAudit());
        Assert.IsEmpty(store.ApplyEvidenceRetention(ObservedUtc.AddDays(3)).Results);

        using var connection = Open(options.DatabasePath);
        using var command = connection.CreateCommand();
        command.CommandText = """
            DELETE FROM evidence_retention_events
            WHERE evidence_identity_sha256 = $identity;
            """;
        command.Parameters.AddWithValue("$identity", identity);
        var exception = Assert.Throws<SqliteException>(() => command.ExecuteNonQuery());
        StringAssert.Contains(exception.Message, "append-only", StringComparison.OrdinalIgnoreCase);
    }

    [TestMethod]
    public void ComplianceReviewRetentionProtectsOpenIncidentEvidenceAndPurgesAfterClose()
    {
        using var directory = new TemporaryDirectory();
        var initialArtifactPath = Path.Combine(directory.Path, "source", "initial.bin");
        var eventArtifactPath = Path.Combine(directory.Path, "source", "event.bin");
        Directory.CreateDirectory(Path.GetDirectoryName(initialArtifactPath)!);
        File.WriteAllBytes(initialArtifactPath, Encoding.UTF8.GetBytes("initial-evidence-content"));
        File.WriteAllBytes(eventArtifactPath, Encoding.UTF8.GetBytes("event-evidence-content"));
        var options = CreateOptions(directory);
        var fixedTime = new FixedTimeProvider(ObservedUtc.AddDays(2));
        using var store = new SqliteHerdrStateStore(options, fixedTime);

        var capturedInitial = store.CaptureEvidence(
            CreateCaptureRequest(retainUntilUtc: ObservedUtc.AddDays(1)),
            initialArtifactPath);
        var initialId = capturedInitial.StoredEvidence.Metadata.EvidenceIdentitySha256;
        var initialManagedPath = ResolveManagedPath(options, capturedInitial.StoredEvidence.Metadata);

        var lifecycle = new AssignmentLifecycleReducer();
        var pmAuthority = SeedAuthority(
            store,
            lifecycle,
            "project-manager",
            "Project Manager",
            ComplianceReviewerRole.ProjectManager,
            Guid.Parse("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"),
            sequence: 1);
        var leaderAuthority = SeedAuthority(
            store,
            lifecycle,
            "backend-leader",
            "Backend Leader",
            ComplianceReviewerRole.Leader,
            Guid.Parse("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"),
            sequence: 2);

        // Register incident: initial state is Suspected (open)
        store.RegisterComplianceReviewIncident(new ComplianceReviewIncidentRegistration(
            ComplianceReviewWorkflowContract.ContractVersion,
            "INC-RET-01",
            "TASK-25",
            "agent-worker-01",
            ObservedUtc.AddMinutes(1),
            [initialId]));

        var suspectedRun = store.ApplyEvidenceRetention(ObservedUtc.AddDays(2));
        Assert.HasCount(1, suspectedRun.Results);
        Assert.AreEqual(HerdrEvidenceRetentionOutcome.ProtectedByOpenReview, suspectedRun.Results[0].Outcome);
        Assert.IsTrue(File.Exists(initialManagedPath));
        Assert.IsEmpty(store.ReadEvidenceRetentionAudit());

        // Capture event evidence when the event occurs
        var capturedEvent = store.CaptureEvidence(
            CreateCaptureRequest(retainUntilUtc: ObservedUtc.AddDays(1)),
            eventArtifactPath);
        var eventId = capturedEvent.StoredEvidence.Metadata.EvidenceIdentitySha256;
        var eventManagedPath = ResolveManagedPath(options, capturedEvent.StoredEvidence.Metadata);

        // Transition Suspected -> PendingLeader with additional evidence linked to event
        store.ApplyComplianceReviewCommand(
            new ComplianceReviewCommand(
                ComplianceReviewWorkflowContract.ContractVersion,
                Guid.Parse("11111111-1111-1111-1111-111111111111"),
                "INC-RET-01",
                ComplianceReviewState.Suspected,
                0,
                "project-manager",
                ComplianceReviewDecisionKind.SendToLeader,
                "Send to leader for investigation.",
                ObservedUtc.AddMinutes(2),
                [eventId]),
            pmAuthority);

        var pendingLeaderRun = store.ApplyEvidenceRetention(ObservedUtc.AddDays(2));
        Assert.HasCount(2, pendingLeaderRun.Results);
        Assert.IsTrue(pendingLeaderRun.Results.All(item => item.Outcome == HerdrEvidenceRetentionOutcome.ProtectedByOpenReview));
        Assert.IsTrue(File.Exists(initialManagedPath));
        Assert.IsTrue(File.Exists(eventManagedPath));
        Assert.IsEmpty(store.ReadEvidenceRetentionAudit());

        // Transition PendingLeader -> PendingProjectManager
        store.ApplyComplianceReviewCommand(
            new ComplianceReviewCommand(
                ComplianceReviewWorkflowContract.ContractVersion,
                Guid.Parse("22222222-2222-2222-2222-222222222222"),
                "INC-RET-01",
                ComplianceReviewState.PendingLeader,
                1,
                "backend-leader",
                ComplianceReviewDecisionKind.EscalateToProjectManager,
                "Escalate to PM.",
                ObservedUtc.AddMinutes(3),
                []),
            leaderAuthority);

        var pendingPmRun = store.ApplyEvidenceRetention(ObservedUtc.AddDays(2));
        Assert.HasCount(2, pendingPmRun.Results);
        Assert.IsTrue(pendingPmRun.Results.All(item => item.Outcome == HerdrEvidenceRetentionOutcome.ProtectedByOpenReview));
        Assert.IsTrue(File.Exists(initialManagedPath));
        Assert.IsTrue(File.Exists(eventManagedPath));

        // Transition PendingProjectManager -> Confirmed (terminal/closed)
        store.ApplyComplianceReviewCommand(
            new ComplianceReviewCommand(
                ComplianceReviewWorkflowContract.ContractVersion,
                Guid.Parse("33333333-3333-3333-3333-333333333333"),
                "INC-RET-01",
                ComplianceReviewState.PendingProjectManager,
                2,
                "project-manager",
                ComplianceReviewDecisionKind.Confirm,
                "Confirmed incident closure.",
                ObservedUtc.AddMinutes(4),
                []),
            pmAuthority);

        var confirmedRun = store.ApplyEvidenceRetention(ObservedUtc.AddDays(2));
        Assert.HasCount(2, confirmedRun.Results);
        Assert.IsTrue(confirmedRun.Results.All(item => item.Outcome == HerdrEvidenceRetentionOutcome.Purged));
        Assert.IsFalse(File.Exists(initialManagedPath));
        Assert.IsFalse(File.Exists(eventManagedPath));

        var retentionAudit = store.ReadEvidenceRetentionAudit();
        Assert.HasCount(2, retentionAudit);
        Assert.IsTrue(retentionAudit.All(item => item.Outcome == HerdrEvidenceRetentionOutcome.Purged));

        // Subsequent run produces no new items (no over-retention)
        Assert.IsEmpty(store.ApplyEvidenceRetention(ObservedUtc.AddDays(3)).Results);
    }

    [TestMethod]
    public void ComplianceReviewRetentionProtectsUntilDismissed()
    {
        using var directory = new TemporaryDirectory();
        var artifactPath = Path.Combine(directory.Path, "source", "dismiss.bin");
        Directory.CreateDirectory(Path.GetDirectoryName(artifactPath)!);
        File.WriteAllBytes(artifactPath, Encoding.UTF8.GetBytes("dismiss-evidence-content"));
        var options = CreateOptions(directory);
        var fixedTime = new FixedTimeProvider(ObservedUtc.AddDays(2));
        using var store = new SqliteHerdrStateStore(options, fixedTime);

        var captured = store.CaptureEvidence(
            CreateCaptureRequest(retainUntilUtc: ObservedUtc.AddDays(1)),
            artifactPath);
        var evidenceId = captured.StoredEvidence.Metadata.EvidenceIdentitySha256;
        var managedPath = ResolveManagedPath(options, captured.StoredEvidence.Metadata);

        var lifecycle = new AssignmentLifecycleReducer();
        var pmAuthority = SeedAuthority(
            store,
            lifecycle,
            "project-manager",
            "Project Manager",
            ComplianceReviewerRole.ProjectManager,
            Guid.Parse("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"),
            sequence: 1);

        store.RegisterComplianceReviewIncident(new ComplianceReviewIncidentRegistration(
            ComplianceReviewWorkflowContract.ContractVersion,
            "INC-DISMISS",
            "TASK-25",
            "agent-worker-01",
            ObservedUtc.AddMinutes(1),
            [evidenceId]));

        var protectedRun = store.ApplyEvidenceRetention(ObservedUtc.AddDays(2));
        Assert.HasCount(1, protectedRun.Results);
        Assert.AreEqual(HerdrEvidenceRetentionOutcome.ProtectedByOpenReview, protectedRun.Results[0].Outcome);
        Assert.IsTrue(File.Exists(managedPath));

        // Dismiss incident
        store.ApplyComplianceReviewCommand(
            new ComplianceReviewCommand(
                ComplianceReviewWorkflowContract.ContractVersion,
                Guid.Parse("44444444-4444-4444-4444-444444444444"),
                "INC-DISMISS",
                ComplianceReviewState.Suspected,
                0,
                "project-manager",
                ComplianceReviewDecisionKind.Dismiss,
                "Dismissed false positive.",
                ObservedUtc.AddMinutes(2),
                []),
            pmAuthority);

        var purgedRun = store.ApplyEvidenceRetention(ObservedUtc.AddDays(2));
        Assert.HasCount(1, purgedRun.Results);
        Assert.AreEqual(HerdrEvidenceRetentionOutcome.Purged, purgedRun.Results[0].Outcome);
        Assert.IsFalse(File.Exists(managedPath));
        Assert.HasCount(1, store.ReadEvidenceRetentionAudit());
    }

    [TestMethod]
    public void ComplianceReviewRetentionUnknownOrMalformedStateFailsClosed()
    {
        using var directory = new TemporaryDirectory();
        var artifactPath = Path.Combine(directory.Path, "source", "malformed.bin");
        Directory.CreateDirectory(Path.GetDirectoryName(artifactPath)!);
        File.WriteAllBytes(artifactPath, Encoding.UTF8.GetBytes("malformed-state-content"));
        var options = CreateOptions(directory);
        var fixedTime = new FixedTimeProvider(ObservedUtc.AddDays(2));
        using var store = new SqliteHerdrStateStore(options, fixedTime);

        var captured = store.CaptureEvidence(
            CreateCaptureRequest(retainUntilUtc: ObservedUtc.AddDays(1)),
            artifactPath);
        var evidenceId = captured.StoredEvidence.Metadata.EvidenceIdentitySha256;
        var managedPath = ResolveManagedPath(options, captured.StoredEvidence.Metadata);

        store.RegisterComplianceReviewIncident(new ComplianceReviewIncidentRegistration(
            ComplianceReviewWorkflowContract.ContractVersion,
            "INC-MALFORMED",
            "TASK-25",
            "agent-worker-01",
            ObservedUtc.AddMinutes(1),
            [evidenceId]));

        // Tamper incident state to invalid value 99 in database by recreating without check constraint
        using (var connection = Open(options.DatabasePath))
        {
            using var tamper = connection.CreateCommand();
            tamper.CommandText = """
                PRAGMA foreign_keys = OFF;
                CREATE TABLE temp_incidents AS SELECT * FROM compliance_review_incidents;
                DROP TABLE compliance_review_incidents;
                CREATE TABLE compliance_review_incidents (
                    incident_id TEXT NOT NULL PRIMARY KEY,
                    contract_version INTEGER NOT NULL,
                    task_id TEXT NOT NULL,
                    subject_actor_id TEXT NOT NULL,
                    registered_utc TEXT NOT NULL,
                    registration_sha256 TEXT NOT NULL,
                    registration_json TEXT NOT NULL,
                    state INTEGER NOT NULL,
                    sequence INTEGER NOT NULL,
                    updated_utc TEXT NOT NULL,
                    last_audit_event_id TEXT NULL,
                    last_audit_sha256 TEXT NULL
                );
                INSERT INTO compliance_review_incidents SELECT * FROM temp_incidents;
                UPDATE compliance_review_incidents SET state = 99 WHERE incident_id = 'INC-MALFORMED';
                """;
            tamper.ExecuteNonQuery();
        }

        // Fail-closed: invalid state is treated as open, protecting evidence from purge
        var protectedRun = store.ApplyEvidenceRetention(ObservedUtc.AddDays(2));
        Assert.HasCount(1, protectedRun.Results);
        Assert.AreEqual(HerdrEvidenceRetentionOutcome.ProtectedByOpenReview, protectedRun.Results[0].Outcome);
        Assert.IsTrue(File.Exists(managedPath));
        Assert.IsEmpty(store.ReadEvidenceRetentionAudit());

        // Test orphaned evidence link: incident row dropped
        using (var connection = Open(options.DatabasePath))
        {
            using var tamper = connection.CreateCommand();
            tamper.CommandText = """
                PRAGMA foreign_keys = OFF;
                DELETE FROM compliance_review_incidents WHERE incident_id = 'INC-MALFORMED';
                """;
            tamper.ExecuteNonQuery();
        }

        var orphanRun = store.ApplyEvidenceRetention(ObservedUtc.AddDays(2));
        Assert.HasCount(1, orphanRun.Results);
        Assert.AreEqual(HerdrEvidenceRetentionOutcome.ProtectedByOpenReview, orphanRun.Results[0].Outcome);
        Assert.IsTrue(File.Exists(managedPath));
    }

    [TestMethod]
    public void ComplianceReviewRetentionCrossIncidentIsolation()
    {
        using var directory = new TemporaryDirectory();
        var pathA = Path.Combine(directory.Path, "source", "evidenceA.bin");
        var pathB = Path.Combine(directory.Path, "source", "evidenceB.bin");
        var pathShared = Path.Combine(directory.Path, "source", "evidenceShared.bin");
        Directory.CreateDirectory(Path.GetDirectoryName(pathA)!);
        File.WriteAllBytes(pathA, Encoding.UTF8.GetBytes("evidence-A-content"));
        File.WriteAllBytes(pathB, Encoding.UTF8.GetBytes("evidence-B-content"));
        File.WriteAllBytes(pathShared, Encoding.UTF8.GetBytes("evidence-Shared-content"));
        var options = CreateOptions(directory);
        var fixedTime = new FixedTimeProvider(ObservedUtc.AddDays(2));
        using var store = new SqliteHerdrStateStore(options, fixedTime);

        var capturedA = store.CaptureEvidence(CreateCaptureRequest(retainUntilUtc: ObservedUtc.AddDays(1)), pathA);
        var capturedB = store.CaptureEvidence(CreateCaptureRequest(retainUntilUtc: ObservedUtc.AddDays(1)), pathB);
        var capturedShared = store.CaptureEvidence(CreateCaptureRequest(retainUntilUtc: ObservedUtc.AddDays(1)), pathShared);

        var idA = capturedA.StoredEvidence.Metadata.EvidenceIdentitySha256;
        var idB = capturedB.StoredEvidence.Metadata.EvidenceIdentitySha256;
        var idShared = capturedShared.StoredEvidence.Metadata.EvidenceIdentitySha256;

        var managedPathA = ResolveManagedPath(options, capturedA.StoredEvidence.Metadata);
        var managedPathB = ResolveManagedPath(options, capturedB.StoredEvidence.Metadata);
        var managedPathShared = ResolveManagedPath(options, capturedShared.StoredEvidence.Metadata);

        var lifecycle = new AssignmentLifecycleReducer();
        var pmAuthority = SeedAuthority(
            store,
            lifecycle,
            "project-manager",
            "Project Manager",
            ComplianceReviewerRole.ProjectManager,
            Guid.Parse("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"),
            sequence: 1);

        // Incident A has [idA, idShared]
        store.RegisterComplianceReviewIncident(new ComplianceReviewIncidentRegistration(
            ComplianceReviewWorkflowContract.ContractVersion,
            "INC-A",
            "TASK-25",
            "agent-worker-01",
            ObservedUtc.AddMinutes(1),
            [idA, idShared]));

        // Incident B has [idB, idShared]
        store.RegisterComplianceReviewIncident(new ComplianceReviewIncidentRegistration(
            ComplianceReviewWorkflowContract.ContractVersion,
            "INC-B",
            "TASK-25",
            "agent-worker-01",
            ObservedUtc.AddMinutes(2),
            [idB, idShared]));

        // Close Incident A (Confirmed) while Incident B remains Suspected (Open)
        store.ApplyComplianceReviewCommand(
            new ComplianceReviewCommand(
                ComplianceReviewWorkflowContract.ContractVersion,
                Guid.Parse("55555555-5555-5555-5555-555555555555"),
                "INC-A",
                ComplianceReviewState.Suspected,
                0,
                "project-manager",
                ComplianceReviewDecisionKind.Confirm,
                "Confirmed incident A.",
                ObservedUtc.AddMinutes(3),
                []),
            pmAuthority);

        var firstRun = store.ApplyEvidenceRetention(ObservedUtc.AddDays(2));
        var resultA = firstRun.Results.Single(item => item.EvidenceIdentitySha256 == idA);
        var resultB = firstRun.Results.Single(item => item.EvidenceIdentitySha256 == idB);
        var resultShared = firstRun.Results.Single(item => item.EvidenceIdentitySha256 == idShared);

        Assert.AreEqual(HerdrEvidenceRetentionOutcome.Purged, resultA.Outcome);
        Assert.AreEqual(HerdrEvidenceRetentionOutcome.ProtectedByOpenReview, resultB.Outcome);
        Assert.AreEqual(HerdrEvidenceRetentionOutcome.ProtectedByOpenReview, resultShared.Outcome);

        Assert.IsFalse(File.Exists(managedPathA));
        Assert.IsTrue(File.Exists(managedPathB));
        Assert.IsTrue(File.Exists(managedPathShared));

        // Close Incident B (Dismissed)
        store.ApplyComplianceReviewCommand(
            new ComplianceReviewCommand(
                ComplianceReviewWorkflowContract.ContractVersion,
                Guid.Parse("66666666-6666-6666-6666-666666666666"),
                "INC-B",
                ComplianceReviewState.Suspected,
                0,
                "project-manager",
                ComplianceReviewDecisionKind.Dismiss,
                "Dismissed incident B.",
                ObservedUtc.AddMinutes(4),
                []),
            pmAuthority);

        var secondRun = store.ApplyEvidenceRetention(ObservedUtc.AddDays(2));
        var secondResultB = secondRun.Results.Single(item => item.EvidenceIdentitySha256 == idB);
        var secondResultShared = secondRun.Results.Single(item => item.EvidenceIdentitySha256 == idShared);

        Assert.AreEqual(HerdrEvidenceRetentionOutcome.Purged, secondResultB.Outcome);
        Assert.AreEqual(HerdrEvidenceRetentionOutcome.Purged, secondResultShared.Outcome);

        Assert.IsFalse(File.Exists(managedPathB));
        Assert.IsFalse(File.Exists(managedPathShared));
    }

    [TestMethod]
    public void ComplianceReviewRetentionNoOverRetentionWhenEligible()
    {
        using var directory = new TemporaryDirectory();
        var artifactPath = Path.Combine(directory.Path, "source", "future.bin");
        Directory.CreateDirectory(Path.GetDirectoryName(artifactPath)!);
        File.WriteAllBytes(artifactPath, Encoding.UTF8.GetBytes("future-retention-content"));
        var options = CreateOptions(directory);
        var fixedTime = new FixedTimeProvider(ObservedUtc.AddDays(2));
        using var store = new SqliteHerdrStateStore(options, fixedTime);

        // retain_until_utc is Day 10
        var captured = store.CaptureEvidence(
            CreateCaptureRequest(retainUntilUtc: ObservedUtc.AddDays(10)),
            artifactPath);
        var evidenceId = captured.StoredEvidence.Metadata.EvidenceIdentitySha256;
        var managedPath = ResolveManagedPath(options, captured.StoredEvidence.Metadata);

        var lifecycle = new AssignmentLifecycleReducer();
        var pmAuthority = SeedAuthority(
            store,
            lifecycle,
            "project-manager",
            "Project Manager",
            ComplianceReviewerRole.ProjectManager,
            Guid.Parse("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"),
            sequence: 1);

        store.RegisterComplianceReviewIncident(new ComplianceReviewIncidentRegistration(
            ComplianceReviewWorkflowContract.ContractVersion,
            "INC-FUTURE",
            "TASK-25",
            "agent-worker-01",
            ObservedUtc.AddMinutes(1),
            [evidenceId]));

        // Confirm incident closure
        store.ApplyComplianceReviewCommand(
            new ComplianceReviewCommand(
                ComplianceReviewWorkflowContract.ContractVersion,
                Guid.Parse("77777777-7777-7777-7777-777777777777"),
                "INC-FUTURE",
                ComplianceReviewState.Suspected,
                0,
                "project-manager",
                ComplianceReviewDecisionKind.Confirm,
                "Confirmed incident.",
                ObservedUtc.AddMinutes(2),
                []),
            pmAuthority);

        // As of Day 2: not due yet because retain_until_utc is Day 10
        var notDueRun = store.ApplyEvidenceRetention(ObservedUtc.AddDays(2));
        Assert.IsEmpty(notDueRun.Results);
        Assert.IsTrue(File.Exists(managedPath));

        // As of Day 10: now due and incident is closed -> purged immediately without over-retention
        var dueRun = store.ApplyEvidenceRetention(ObservedUtc.AddDays(10));
        Assert.HasCount(1, dueRun.Results);
        Assert.AreEqual(HerdrEvidenceRetentionOutcome.Purged, dueRun.Results[0].Outcome);
        Assert.IsFalse(File.Exists(managedPath));
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
        var occurredUtc = ObservedUtc.AddSeconds(sequence);
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

    private static string Hash(string value) => Convert.ToHexString(
        SHA256.HashData(Encoding.UTF8.GetBytes(value)));

    [TestMethod]
    public void FailedRetentionAuditWriteLeavesRecoverableBytesAndRetryCompletes()
    {
        using var directory = new TemporaryDirectory();
        var artifactPath = Path.Combine(directory.Path, "source", "recoverable.bin");
        Directory.CreateDirectory(Path.GetDirectoryName(artifactPath)!);
        File.WriteAllBytes(artifactPath, Encoding.UTF8.GetBytes("recoverable-retention-content"));
        var options = CreateOptions(directory);
        using var store = new SqliteHerdrStateStore(
            options,
            new FixedTimeProvider(ObservedUtc.AddDays(2)));
        var captured = store.CaptureEvidence(
            CreateCaptureRequest(retainUntilUtc: ObservedUtc.AddDays(1)),
            artifactPath);
        var identity = captured.StoredEvidence.Metadata.EvidenceIdentitySha256;
        var managedPath = ResolveManagedPath(options, captured.StoredEvidence.Metadata);
        var pendingPath = Path.Combine(
            options.ManagedEvidenceRootPath!,
            ".retention",
            identity + ".pending");

        using var connection = Open(options.DatabasePath);
        using var command = connection.CreateCommand();
        command.CommandText = """
            CREATE TRIGGER test_reject_retention_insert
            BEFORE INSERT ON evidence_retention_events
            BEGIN
                SELECT RAISE(ABORT, 'forced retention audit failure');
            END;
            """;
        command.ExecuteNonQuery();

        var failed = Assert.Throws<SqliteException>(() =>
            store.ApplyEvidenceRetention(ObservedUtc.AddDays(2)));
        StringAssert.Contains(failed.Message, "forced retention audit failure", StringComparison.Ordinal);
        Assert.IsFalse(File.Exists(managedPath));
        Assert.IsTrue(File.Exists(pendingPath));
        Assert.IsEmpty(store.ReadEvidenceRetentionAudit());
        var pendingRead = Assert.Throws<HerdrStateStoreException>(() =>
            store.ReadEvidence(identity));
        StringAssert.Contains(pendingRead.Message, "incomplete retention", StringComparison.Ordinal);

        command.CommandText = "DROP TRIGGER test_reject_retention_insert;";
        command.ExecuteNonQuery();
        var recovered = store.ApplyEvidenceRetention(ObservedUtc.AddDays(2));

        Assert.HasCount(1, recovered.Results);
        Assert.AreEqual(HerdrEvidenceRetentionOutcome.Purged, recovered.Results[0].Outcome);
        Assert.IsFalse(File.Exists(managedPath));
        Assert.IsFalse(File.Exists(pendingPath));
        Assert.HasCount(1, store.ReadEvidenceRetentionAudit());
        var stored = store.ReadEvidence(identity);
        Assert.IsNotNull(stored);
        Assert.IsFalse(stored.ManagedBytesAvailable);
        Assert.IsTrue(stored.RetentionCompleted);
    }

    [TestMethod]
    public void CommittedRetentionAuditWithPendingBytesRecoversCleanup()
    {
        using var directory = new TemporaryDirectory();
        var artifactPath = Path.Combine(directory.Path, "source", "committed-pending.bin");
        Directory.CreateDirectory(Path.GetDirectoryName(artifactPath)!);
        File.WriteAllBytes(artifactPath, Encoding.UTF8.GetBytes("committed-pending-content"));
        var options = CreateOptions(directory);
        using var store = new SqliteHerdrStateStore(
            options,
            new FixedTimeProvider(ObservedUtc.AddDays(2)));
        var captured = store.CaptureEvidence(
            CreateCaptureRequest(retainUntilUtc: ObservedUtc.AddDays(1)),
            artifactPath);
        var metadata = captured.StoredEvidence.Metadata;
        var managedPath = ResolveManagedPath(options, metadata);

        var pendingPath = Assert.IsInstanceOfType<string>(InvokePrivate(
            store,
            "MoveManagedEvidenceToRetentionPending",
            metadata));
        var auditEvent = Assert.IsInstanceOfType<HerdrEvidenceRetentionAuditEvent>(InvokePrivate(
            store,
            "CreateRetentionAuditEvent",
            metadata,
            HerdrEvidenceRetentionOutcome.Purged));
        _ = InvokePrivate(store, "InsertRetentionAuditEvent", auditEvent);

        Assert.IsFalse(File.Exists(managedPath));
        Assert.IsTrue(File.Exists(pendingPath));
        Assert.HasCount(1, store.ReadEvidenceRetentionAudit());
        var pendingRead = Assert.Throws<HerdrStateStoreException>(() =>
            store.ReadEvidence(metadata.EvidenceIdentitySha256));
        StringAssert.Contains(pendingRead.Message, "incomplete retention", StringComparison.Ordinal);

        var recovered = store.ApplyEvidenceRetention(ObservedUtc.AddDays(2));

        Assert.HasCount(1, recovered.Results);
        Assert.AreEqual(auditEvent.RetentionEventId, recovered.Results[0].RetentionEventId);
        Assert.AreEqual(HerdrEvidenceRetentionOutcome.Purged, recovered.Results[0].Outcome);
        Assert.IsFalse(File.Exists(pendingPath));
        Assert.HasCount(1, store.ReadEvidenceRetentionAudit());
    }

    [TestMethod]
    public void ManagedEvidenceDirectoryMasqueradeFailsClosedOnRead()
    {
        using var directory = new TemporaryDirectory();
        var artifactPath = Path.Combine(directory.Path, "source.bin");
        File.WriteAllBytes(artifactPath, Encoding.UTF8.GetBytes("authentic"));
        var options = CreateOptions(directory);
        using var store = new SqliteHerdrStateStore(options);
        var captured = store.CaptureEvidence(CreateCaptureRequest(), artifactPath);
        var identity = captured.StoredEvidence.Metadata.EvidenceIdentitySha256;
        var managedPath = ResolveManagedPath(options, captured.StoredEvidence.Metadata);
        File.Delete(managedPath);
        Directory.CreateDirectory(managedPath);

        var exception = Assert.Throws<HerdrStateStoreException>(() =>
            store.ReadEvidence(identity));
        StringAssert.Contains(exception.Message, "not a regular", StringComparison.Ordinal);
    }

    [TestMethod]
    public void ManagedEvidenceIntermediateFileMasqueradeFailsClosedOnRead()
    {
        using var directory = new TemporaryDirectory();
        var artifactPath = Path.Combine(directory.Path, "source.bin");
        File.WriteAllBytes(artifactPath, Encoding.UTF8.GetBytes("authentic"));
        var options = CreateOptions(directory);
        using var store = new SqliteHerdrStateStore(options);
        var captured = store.CaptureEvidence(CreateCaptureRequest(), artifactPath);
        var identity = captured.StoredEvidence.Metadata.EvidenceIdentitySha256;
        var managedPath = ResolveManagedPath(options, captured.StoredEvidence.Metadata);
        var objectsPath = Path.Combine(options.ManagedEvidenceRootPath!, "objects");
        Directory.Delete(objectsPath, recursive: true);
        File.WriteAllText(objectsPath, "not-a-directory", Encoding.UTF8);

        var exception = Assert.Throws<HerdrStateStoreException>(() =>
            store.ReadEvidence(identity));
        StringAssert.Contains(exception.Message, "not a directory", StringComparison.Ordinal);
        Assert.IsFalse(File.Exists(managedPath));
    }

    [TestMethod]
    public void ManagedVaultRejectsReparsePointAncestorBeforeCreatingVault()
    {
        using var directory = new TemporaryDirectory();
        var targetParent = Path.Combine(directory.Path, "actual-parent");
        var junctionParent = Path.Combine(directory.Path, "junction-parent");
        Directory.CreateDirectory(targetParent);
        CreateDirectoryJunction(junctionParent, targetParent);
        try
        {
            var options = new HerdrStateStoreOptions(
                Path.Combine(directory.Path, "state", "herdrops.db"),
                ManagedEvidenceRootPath: Path.Combine(junctionParent, "vault"));

            var exception = Assert.Throws<HerdrStateStoreException>(() =>
                new SqliteHerdrStateStore(options));
            StringAssert.Contains(exception.Message, "reparse point", StringComparison.Ordinal);
            Assert.IsFalse(Directory.Exists(Path.Combine(targetParent, "vault")));
        }
        finally
        {
            if (Directory.Exists(junctionParent))
            {
                Directory.Delete(junctionParent);
            }
        }
    }

    [TestMethod]
    public void ManagedByteTamperingFailsClosedOnRead()
    {
        using var directory = new TemporaryDirectory();
        var artifactPath = Path.Combine(directory.Path, "source.bin");
        File.WriteAllBytes(artifactPath, Encoding.UTF8.GetBytes("authentic"));
        var options = CreateOptions(directory);
        using var store = new SqliteHerdrStateStore(options);
        var captured = store.CaptureEvidence(CreateCaptureRequest(), artifactPath);
        var identity = captured.StoredEvidence.Metadata.EvidenceIdentitySha256;
        var managedPath = ResolveManagedPath(options, captured.StoredEvidence.Metadata);
        File.WriteAllBytes(managedPath, Encoding.UTF8.GetBytes("tampered"));

        var exception = Assert.Throws<HerdrStateStoreException>(() =>
            store.ReadEvidence(identity));
        StringAssert.Contains(exception.Message, "length/SHA-256", StringComparison.Ordinal);
    }

    private static HerdrStateStoreOptions CreateOptions(TemporaryDirectory directory) =>
        new(
            Path.Combine(directory.Path, "state", "herdrops.db"),
            ManagedEvidenceRootPath: Path.Combine(directory.Path, "managed-evidence"));

    private static EvidenceCaptureRequest CreateCaptureRequest(
        bool createManagedCopy = true,
        DateTimeOffset? retainUntilUtc = null) =>
        new(
            EvidenceMetadataContract.ContractVersion,
            "TASK-25",
            "agent-worker-01",
            "EVENT-25-01",
            "integration-test",
            "redacted://evidence/artifact.bin",
            ObservedUtc,
            ObservedUtc.AddMinutes(1),
            retainUntilUtc ?? ObservedUtc.AddDays(30),
            createManagedCopy);

    private static ReviewAuditAppendRequest CreateReviewRequest(
        Guid eventId,
        ReviewAuditActionKind action,
        ReviewAuditState state,
        IReadOnlyList<string> evidenceIdentities,
        DateTimeOffset occurredUtc) =>
        new(
            ReviewAuditContract.ContractVersion,
            eventId,
            "REVIEW-25",
            "reviewer-01",
            "Independent Reviewer",
            action,
            state,
            "Immutable review history test.",
            occurredUtc,
            evidenceIdentities);

    private static string ResolveManagedPath(
        HerdrStateStoreOptions options,
        EvidenceMetadata metadata) =>
        Path.GetFullPath(Path.Combine(
            options.ManagedEvidenceRootPath!,
            metadata.ManagedRelativePath!.Replace('/', Path.DirectorySeparatorChar)));

    private static SqliteConnection Open(string databasePath)
    {
        var connection = new SqliteConnection(new SqliteConnectionStringBuilder
        {
            DataSource = databasePath,
            Mode = SqliteOpenMode.ReadWrite,
            Pooling = false,
        }.ToString());
        connection.Open();
        return connection;
    }

    private static void CreateDirectoryJunction(string junctionPath, string targetPath)
    {
        var commandInterpreter = Environment.GetEnvironmentVariable("ComSpec");
        Assert.IsFalse(
            string.IsNullOrWhiteSpace(commandInterpreter),
            "The Windows command interpreter is required to create a local test junction.");
        var startInfo = new ProcessStartInfo
        {
            FileName = commandInterpreter,
            CreateNoWindow = true,
            RedirectStandardError = true,
            RedirectStandardOutput = true,
            UseShellExecute = false,
        };
        startInfo.ArgumentList.Add("/d");
        startInfo.ArgumentList.Add("/c");
        startInfo.ArgumentList.Add("mklink");
        startInfo.ArgumentList.Add("/J");
        startInfo.ArgumentList.Add(junctionPath);
        startInfo.ArgumentList.Add(targetPath);
        using var process = Process.Start(startInfo)
            ?? throw new AssertFailedException("The junction helper process did not start.");
        var standardOutput = process.StandardOutput.ReadToEnd();
        var standardError = process.StandardError.ReadToEnd();
        process.WaitForExit();
        Assert.AreEqual(
            0,
            process.ExitCode,
            $"Could not create test junction. Output: {standardOutput} Error: {standardError}");
    }

    private static object? InvokePrivate(
        SqliteHerdrStateStore store,
        string methodName,
        params object[] arguments)
    {
        var method = typeof(SqliteHerdrStateStore).GetMethod(
            methodName,
            BindingFlags.Instance | BindingFlags.NonPublic)
            ?? throw new AssertFailedException($"Private method '{methodName}' was not found.");
        return method.Invoke(store, arguments);
    }
}
