using System.Security.Cryptography;
using System.Text;
using HerdrOps.Domain.Assignments;
using HerdrOps.Domain.Compliance;
using HerdrOps.Domain.Evidence;
using HerdrOps.Infrastructure.Storage;
using Microsoft.Data.Sqlite;

namespace HerdrOps.IntegrationTests;

[TestClass]
public sealed class ComplianceReviewStorageTests
{
    private static readonly DateTimeOffset RegisteredUtc =
        new(2026, 8, 16, 2, 0, 0, TimeSpan.Zero);

    [TestMethod]
    public void SchemaVersionFourCreatesGuardedRoleReviewLedger()
    {
        using var directory = new TemporaryDirectory();
        var options = Options(directory);
        var migration = SqliteHerdrStateStore.GetMigrationForTesting(4);

        Assert.AreEqual("role-distinct-compliance-review-workflow", migration.Name);
        Assert.HasCount(64, migration.ScriptSha256);
        using (var store = new SqliteHerdrStateStore(options))
        {
            Assert.AreEqual(4, store.GetDiagnostics().SchemaVersion);
        }

        using var connection = Open(options.DatabasePath);
        using var command = connection.CreateCommand();
        command.CommandText = """
            SELECT COUNT(*)
            FROM sqlite_master
            WHERE type = 'table'
              AND name IN (
                  'compliance_review_incidents',
                  'compliance_review_incident_evidence',
                  'compliance_review_events',
                  'compliance_review_event_evidence');
            """;
        Assert.AreEqual(4L, Convert.ToInt64(command.ExecuteScalar()));
        command.CommandText = """
            SELECT COUNT(*)
            FROM sqlite_master
            WHERE type = 'trigger'
              AND name LIKE 'compliance_review_%';
            """;
        Assert.AreEqual(12L, Convert.ToInt64(command.ExecuteScalar()));
    }

    [TestMethod]
    public void RoleDistinctWorkflowPersistsOneHashChainAcrossRestart()
    {
        using var directory = new TemporaryDirectory();
        var options = Options(directory);
        string evidenceId;
        ComplianceReviewAuditEvent firstEvent;
        ComplianceReviewAuditEvent secondEvent;
        ComplianceReviewAuditEvent thirdEvent;
        using (var store = new SqliteHerdrStateStore(options))
        {
            var lifecycle = new AssignmentLifecycleReducer();
            var projectManagerAuthority = SeedAuthority(
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
            evidenceId = CaptureEvidence(store, directory);
            store.RegisterComplianceReviewIncident(Registration(evidenceId));
            var sent = store.ApplyComplianceReviewCommand(
                Command(
                    Guid.Parse("11111111-1111-1111-1111-111111111111"),
                    ComplianceReviewState.Suspected,
                    ComplianceReviewDecisionKind.SendToLeader,
                    "project-manager",
                    RegisteredUtc.AddMinutes(2),
                    evidenceId),
                projectManagerAuthority);
            var escalated = store.ApplyComplianceReviewCommand(
                Command(
                    Guid.Parse("22222222-2222-2222-2222-222222222222"),
                    ComplianceReviewState.PendingLeader,
                    ComplianceReviewDecisionKind.EscalateToProjectManager,
                    "backend-leader",
                    RegisteredUtc.AddMinutes(3),
                    evidenceId),
                leaderAuthority);
            var confirmed = store.ApplyComplianceReviewCommand(
                Command(
                    Guid.Parse("33333333-3333-3333-3333-333333333333"),
                    ComplianceReviewState.PendingProjectManager,
                    ComplianceReviewDecisionKind.Confirm,
                    "project-manager",
                    RegisteredUtc.AddMinutes(4),
                    evidenceId),
                projectManagerAuthority);

            firstEvent = sent.AuditEvent;
            secondEvent = escalated.AuditEvent;
            thirdEvent = confirmed.AuditEvent;
            Assert.AreEqual(ComplianceReviewState.Confirmed, confirmed.Incident.State);
            Assert.AreEqual(3L, confirmed.Incident.Sequence);
        }

        using var restarted = new SqliteHerdrStateStore(options);
        var incident = restarted.ReadComplianceReviewIncident("INC-27");
        var audit = restarted.ReadComplianceReviewAudit("INC-27");

        Assert.IsNotNull(incident);
        Assert.AreEqual(ComplianceReviewState.Confirmed, incident.State);
        Assert.AreEqual(3L, incident.Sequence);
        Assert.HasCount(3, audit);
        Assert.AreEqual(firstEvent.AuditSha256, audit[0].AuditSha256);
        Assert.AreEqual(secondEvent.AuditSha256, audit[1].AuditSha256);
        Assert.AreEqual(thirdEvent.AuditSha256, audit[2].AuditSha256);
        CollectionAssert.AreEqual(
            firstEvent.EvidenceIdentitySha256s.ToArray(),
            audit[0].EvidenceIdentitySha256s.ToArray());
        Assert.AreEqual(ComplianceReviewerRole.ProjectManager, audit[0].ReviewerRole);
        Assert.AreEqual(ComplianceReviewerRole.Leader, audit[1].ReviewerRole);
        Assert.AreEqual(ComplianceReviewerRole.ProjectManager, audit[2].ReviewerRole);
        Assert.AreEqual(audit[0].AuditSha256, audit[1].PreviousAuditSha256);
        Assert.AreEqual(audit[1].AuditSha256, audit[2].PreviousAuditSha256);
    }

    [TestMethod]
    public void RegistrationAndCommandReplayAreExactIdempotent()
    {
        using var directory = new TemporaryDirectory();
        using var store = new SqliteHerdrStateStore(Options(directory));
        var lifecycle = new AssignmentLifecycleReducer();
        var authority = SeedAuthority(
            store,
            lifecycle,
            "project-manager",
            "Project Manager",
            ComplianceReviewerRole.ProjectManager,
            Guid.Parse("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"),
            sequence: 1);
        var evidenceId = CaptureEvidence(store, directory);
        var registration = Registration(evidenceId);
        var firstRegistration = store.RegisterComplianceReviewIncident(registration);
        var registrationRetry = store.RegisterComplianceReviewIncident(registration);
        var command = Command(
            Guid.Parse("44444444-4444-4444-4444-444444444444"),
            ComplianceReviewState.Suspected,
            ComplianceReviewDecisionKind.Dismiss,
            "project-manager",
            RegisteredUtc.AddMinutes(2),
            evidenceId);
        var first = store.ApplyComplianceReviewCommand(command, authority);
        var retry = store.ApplyComplianceReviewCommand(command, authority);

        Assert.IsFalse(firstRegistration.WasAlreadyPresent);
        Assert.IsTrue(registrationRetry.WasAlreadyPresent);
        Assert.IsFalse(first.WasAlreadyPresent);
        Assert.IsTrue(retry.WasAlreadyPresent);
        Assert.AreEqual(first.AuditEvent.AuditSha256, retry.AuditEvent.AuditSha256);
        CollectionAssert.AreEqual(
            first.AuditEvent.EvidenceIdentitySha256s.ToArray(),
            retry.AuditEvent.EvidenceIdentitySha256s.ToArray());
        Assert.HasCount(1, store.ReadComplianceReviewAudit("INC-27"));

        var conflicting = Assert.Throws<HerdrStateStoreException>(() =>
            store.ApplyComplianceReviewCommand(
                command with { Reason = "Different immutable replay payload." },
                authority));
        StringAssert.Contains(conflicting.Message, "different immutable content");
        Assert.HasCount(1, store.ReadComplianceReviewAudit("INC-27"));
    }

    [TestMethod]
    public void CorruptedReviewHistoryBlocksIdempotentRegistrationRetry()
    {
        using var directory = new TemporaryDirectory();
        var options = Options(directory);
        string declaredEvidenceId;
        string undeclaredEvidenceId;
        using (var store = new SqliteHerdrStateStore(options))
        {
            var lifecycle = new AssignmentLifecycleReducer();
            var authority = SeedAuthority(
                store,
                lifecycle,
                "project-manager",
                "Project Manager",
                ComplianceReviewerRole.ProjectManager,
                Guid.Parse("77777777-7777-7777-7777-777777777771"),
                sequence: 1);
            declaredEvidenceId = CaptureEvidence(store, directory);
            undeclaredEvidenceId = CaptureAdditionalEvidence(store, directory);
            store.RegisterComplianceReviewIncident(Registration(declaredEvidenceId));
            store.ApplyComplianceReviewCommand(
                Command(
                    Guid.Parse("77777777-7777-7777-7777-777777777772"),
                    ComplianceReviewState.Suspected,
                    ComplianceReviewDecisionKind.SendToLeader,
                    "project-manager",
                    RegisteredUtc.AddMinutes(2),
                    declaredEvidenceId),
                authority);
        }

        using (var connection = Open(options.DatabasePath))
        using (var tamper = connection.CreateCommand())
        {
            tamper.CommandText = """
                DROP TRIGGER compliance_review_event_evidence_validate_insert;
                INSERT INTO compliance_review_event_evidence(
                    audit_event_id,
                    evidence_identity_sha256)
                SELECT audit_event_id, $evidenceIdentitySha256
                FROM compliance_review_events
                WHERE incident_id = 'INC-27' AND sequence = 1;
                """;
            tamper.Parameters.AddWithValue("$evidenceIdentitySha256", undeclaredEvidenceId);
            Assert.AreEqual(1, tamper.ExecuteNonQuery());
        }

        using var reopened = new SqliteHerdrStateStore(options);
        var exception = Assert.Throws<HerdrStateStoreException>(() =>
            reopened.RegisterComplianceReviewIncident(Registration(declaredEvidenceId)));
        StringAssert.Contains(
            exception.Message,
            "columns, JSON, or evidence links disagree",
            StringComparison.OrdinalIgnoreCase);
    }

    [TestMethod]
    public void UnauthorizedSelfReviewAndStaleStateLeaveNoAuditRows()
    {
        using var directory = new TemporaryDirectory();
        using var store = new SqliteHerdrStateStore(Options(directory));
        var evidenceId = CaptureEvidence(store, directory);
        store.RegisterComplianceReviewIncident(
            Registration(evidenceId) with { SubjectActorId = "project-manager" });

        var selfReview = Assert.Throws<ComplianceReviewRejectedException>(() =>
            store.ApplyComplianceReviewCommand(
                Command(
                    Guid.Parse("55555555-5555-5555-5555-555555555555"),
                    ComplianceReviewState.Suspected,
                    ComplianceReviewDecisionKind.Confirm,
                    "project-manager",
                    RegisteredUtc.AddMinutes(2),
                    evidenceId),
                Authority(
                    "project-manager",
                    ComplianceReviewerRole.ProjectManager,
                    Guid.Parse("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"))));
        Assert.AreEqual(ComplianceReviewRejectionCode.SelfReview, selfReview.RejectionCode);

        var stale = Assert.Throws<ComplianceReviewRejectedException>(() =>
            store.ApplyComplianceReviewCommand(
                Command(
                    Guid.Parse("66666666-6666-6666-6666-666666666666"),
                    ComplianceReviewState.PendingProjectManager,
                    ComplianceReviewDecisionKind.Confirm,
                    "different-project-manager",
                    RegisteredUtc.AddMinutes(2),
                    evidenceId),
                Authority(
                    "different-project-manager",
                    ComplianceReviewerRole.ProjectManager,
                    Guid.Parse("cccccccc-cccc-cccc-cccc-cccccccccccc"))));
        Assert.AreEqual(ComplianceReviewRejectionCode.StaleState, stale.RejectionCode);

        var unauthorized = Assert.Throws<ComplianceReviewRejectedException>(() =>
            store.ApplyComplianceReviewCommand(
                Command(
                    Guid.Parse("77777777-7777-7777-7777-777777777777"),
                    ComplianceReviewState.Suspected,
                    ComplianceReviewDecisionKind.Confirm,
                    "backend-leader",
                    RegisteredUtc.AddMinutes(2),
                    evidenceId),
                Authority(
                    "backend-leader",
                    ComplianceReviewerRole.Leader,
                    Guid.Parse("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"))));
        Assert.AreEqual(
            ComplianceReviewRejectionCode.UnauthorizedRole,
            unauthorized.RejectionCode);

        Assert.IsEmpty(store.ReadComplianceReviewAudit("INC-27"));
        Assert.AreEqual(
            ComplianceReviewState.Suspected,
            store.ReadComplianceReviewIncident("INC-27")!.State);
    }

    [TestMethod]
    public void OrdinarySqlCannotRewriteOrDeleteAcceptedReviewHistory()
    {
        using var directory = new TemporaryDirectory();
        var options = Options(directory);
        using (var store = new SqliteHerdrStateStore(options))
        {
            var lifecycle = new AssignmentLifecycleReducer();
            var projectManagerAuthority = SeedAuthority(
                store,
                lifecycle,
                "project-manager",
                "Project Manager",
                ComplianceReviewerRole.ProjectManager,
                Guid.Parse("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"),
                sequence: 1);
            var evidenceId = CaptureEvidence(store, directory);
            store.RegisterComplianceReviewIncident(Registration(evidenceId));
            store.ApplyComplianceReviewCommand(
                Command(
                    Guid.Parse("88888888-8888-8888-8888-888888888888"),
                    ComplianceReviewState.Suspected,
                    ComplianceReviewDecisionKind.Confirm,
                    "project-manager",
                    RegisteredUtc.AddMinutes(2),
                    evidenceId),
                projectManagerAuthority);
        }

        using var connection = Open(options.DatabasePath);
        using var command = connection.CreateCommand();
        command.CommandText = "UPDATE compliance_review_events SET reason = 'rewritten';";
        var update = Assert.Throws<SqliteException>(() => command.ExecuteNonQuery());
        StringAssert.Contains(update.Message, "append-only", StringComparison.OrdinalIgnoreCase);
        command.CommandText = "DELETE FROM compliance_review_events;";
        var delete = Assert.Throws<SqliteException>(() => command.ExecuteNonQuery());
        StringAssert.Contains(delete.Message, "append-only", StringComparison.OrdinalIgnoreCase);
        command.CommandText = "UPDATE compliance_review_incidents SET state = 5;";
        var stateRewrite = Assert.Throws<SqliteException>(() => command.ExecuteNonQuery());
        StringAssert.Contains(
            stateRewrite.Message,
            "matching immutable audit event",
            StringComparison.OrdinalIgnoreCase);
    }

    [TestMethod]
    public void BlockedComplianceReviewOperationObservesCancellationBeforeMutation()
    {
        using var directory = new TemporaryDirectory();
        var options = Options(directory) with { BusyTimeoutSeconds = 5 };
        using var store = new SqliteHerdrStateStore(options);
        var lifecycle = new AssignmentLifecycleReducer();
        var authority = SeedAuthority(
            store,
            lifecycle,
            "project-manager",
            "Project Manager",
            ComplianceReviewerRole.ProjectManager,
            Guid.Parse("cccccccc-cccc-cccc-cccc-cccccccccccc"),
            sequence: 1);
        var evidenceId = CaptureEvidence(store, directory);
        store.RegisterComplianceReviewIncident(Registration(evidenceId));
        var command = Command(
            Guid.Parse("44444444-4444-4444-4444-444444444444"),
            ComplianceReviewState.Suspected,
            ComplianceReviewDecisionKind.SendToLeader,
            "project-manager",
            RegisteredUtc.AddMinutes(2),
            evidenceId);

        using var blocker = Open(options.DatabasePath);
        using (var beginImmediate = blocker.CreateCommand())
        {
            beginImmediate.CommandText = "BEGIN IMMEDIATE;";
            beginImmediate.ExecuteNonQuery();
        }

        using var cancellation = new CancellationTokenSource();
        using var busySliceObserved = new ManualResetEventSlim();
        using var operationStarted = new ManualResetEventSlim();
        Exception? operationException = null;
        var operationThread = new Thread(() =>
        {
            operationStarted.Set();
            try
            {
                store.ApplyComplianceReviewCommand(
                    command,
                    authority,
                    cancellation.Token);
            }
            catch (Exception exception)
            {
                operationException = exception;
            }
        })
        {
            IsBackground = true,
        };

        try
        {
            store.ComplianceReviewBusySliceObserved += () => busySliceObserved.Set();
            operationThread.Start();
            Assert.IsTrue(
                operationStarted.Wait(TimeSpan.FromSeconds(10)),
                "The review operation did not start within the probe bound.");
            Assert.IsTrue(
                busySliceObserved.Wait(TimeSpan.FromSeconds(10)),
                "The review operation did not observe a real SQLite BUSY/LOCKED slice within the probe bound.");

            var cancellationElapsed = System.Diagnostics.Stopwatch.StartNew();
            cancellation.Cancel();
            Assert.IsTrue(
                operationThread.Join(TimeSpan.FromSeconds(1)),
                "The review operation did not complete well below the total busy bound after cancellation.");
            cancellationElapsed.Stop();
            Assert.IsTrue(
                cancellationElapsed.Elapsed < TimeSpan.FromMilliseconds(500),
                $"The canceled review operation took {cancellationElapsed.Elapsed.TotalMilliseconds:F0}ms to observe cancellation; expected completion well below the 1-second busy bound.");
        }
        finally
        {
            // Release the database write lock on every path, then make sure the
            // background thread terminates so the test never leaks a thread.
            using (var rollback = blocker.CreateCommand())
            {
                rollback.CommandText = "ROLLBACK;";
                rollback.ExecuteNonQuery();
            }

            if (!operationThread.Join(TimeSpan.FromSeconds(10)))
            {
                throw new InvalidOperationException(
                    "The review operation thread did not terminate after the blocker released the database write lock.");
            }
        }

        Assert.IsNotNull(operationException);
        Assert.IsTrue(
            operationException is OperationCanceledException,
            $"Expected OperationCanceledException only, got {operationException.GetType().FullName}: {operationException.Message}");
        Assert.IsEmpty(store.ReadComplianceReviewAudit("INC-27"));
        var incident = store.ReadComplianceReviewIncident("INC-27");
        Assert.IsNotNull(incident);
        Assert.AreEqual(ComplianceReviewState.Suspected, incident.State);
        Assert.AreEqual(0L, incident.Sequence);
        Assert.IsNull(incident.LastAuditEventId);
        Assert.IsNull(incident.LastAuditSha256);
    }

    [TestMethod]
    public void BlockedComplianceReviewOperationFailsClosedAtContentionBoundWithoutCancellation()
    {
        using var directory = new TemporaryDirectory();
        var options = Options(directory) with { BusyTimeoutSeconds = 5 };
        using var store = new SqliteHerdrStateStore(options);
        var lifecycle = new AssignmentLifecycleReducer();
        var authority = SeedAuthority(
            store,
            lifecycle,
            "project-manager",
            "Project Manager",
            ComplianceReviewerRole.ProjectManager,
            Guid.Parse("cccccccc-cccc-cccc-cccc-cccccccccccc"),
            sequence: 1);
        var evidenceId = CaptureEvidence(store, directory);
        store.RegisterComplianceReviewIncident(Registration(evidenceId));
        var command = Command(
            Guid.Parse("44444444-4444-4444-4444-444444444444"),
            ComplianceReviewState.Suspected,
            ComplianceReviewDecisionKind.SendToLeader,
            "project-manager",
            RegisteredUtc.AddMinutes(2),
            evidenceId);

        using var blocker = Open(options.DatabasePath);
        using (var beginImmediate = blocker.CreateCommand())
        {
            beginImmediate.CommandText = "BEGIN IMMEDIATE;";
            beginImmediate.ExecuteNonQuery();
        }

        using var busySliceObserved = new ManualResetEventSlim();
        using var operationStarted = new ManualResetEventSlim();
        Exception? operationException = null;
        var operationThread = new Thread(() =>
        {
            operationStarted.Set();
            try
            {
                store.ApplyComplianceReviewCommand(
                    command,
                    authority,
                    CancellationToken.None);
            }
            catch (Exception exception)
            {
                operationException = exception;
            }
        })
        {
            IsBackground = true,
        };

        var elapsed = System.Diagnostics.Stopwatch.StartNew();
        try
        {
            store.ComplianceReviewBusySliceObserved += () => busySliceObserved.Set();
            operationThread.Start();
            Assert.IsTrue(
                operationStarted.Wait(TimeSpan.FromSeconds(10)),
                "The review operation did not start within the probe bound.");
            Assert.IsTrue(
                busySliceObserved.Wait(TimeSpan.FromSeconds(10)),
                "The review operation did not observe a real SQLite BUSY/LOCKED slice within the probe bound.");
            Assert.IsTrue(
                operationThread.Join(TimeSpan.FromSeconds(4)),
                "A non-canceled review operation did not fail closed at the contention bound.");
            elapsed.Stop();
            // The production ceiling is one second, reached through ~20
            // cooperative 50 ms busy slices. The lower bound proves the loop
            // actually contended to the ceiling instead of failing immediately;
            // the upper bound stays well below the 5-second option value so a
            // removed one-second cap is still detected.
            Assert.IsTrue(
                elapsed.Elapsed >= TimeSpan.FromMilliseconds(750),
                $"The non-canceled review operation failed after only {elapsed.Elapsed.TotalMilliseconds:F0}ms; expected it to contend up to the one-second production ceiling before failing closed.");
            Assert.IsTrue(
                elapsed.Elapsed < TimeSpan.FromSeconds(2),
                $"The non-canceled review operation took {elapsed.Elapsed.TotalSeconds:F2}s; expected failure closed at the one-second compliance contention bound.");
        }
        finally
        {
            using (var rollback = blocker.CreateCommand())
            {
                rollback.CommandText = "ROLLBACK;";
                rollback.ExecuteNonQuery();
            }

            if (!operationThread.Join(TimeSpan.FromSeconds(10)))
            {
                throw new InvalidOperationException(
                    "The review operation thread did not terminate after the blocker released the database write lock.");
            }
        }

        Assert.IsNotNull(operationException);
        Assert.IsInstanceOfType<HerdrStateStoreException>(operationException);
        StringAssert.Contains(
            operationException.Message,
            "contention bound");
        Assert.IsEmpty(store.ReadComplianceReviewAudit("INC-27"));
        var incident = store.ReadComplianceReviewIncident("INC-27");
        Assert.IsNotNull(incident);
        Assert.AreEqual(ComplianceReviewState.Suspected, incident.State);
        Assert.AreEqual(0L, incident.Sequence);
        Assert.IsNull(incident.LastAuditEventId);
        Assert.IsNull(incident.LastAuditSha256);
    }

    [TestMethod]
    public void OrdinarySqlCannotAppendUndeclaredEvidenceToAcceptedReviewEvent()
    {
        using var directory = new TemporaryDirectory();
        var options = Options(directory);
        Guid auditEventId;
        string declaredEvidenceId;
        string undeclaredEvidenceId;
        using (var store = new SqliteHerdrStateStore(options))
        {
            var lifecycle = new AssignmentLifecycleReducer();
            var projectManagerAuthority = SeedAuthority(
                store,
                lifecycle,
                "project-manager",
                "Project Manager",
                ComplianceReviewerRole.ProjectManager,
                Guid.Parse("88888888-8888-8888-8888-888888888881"),
                sequence: 1);
            declaredEvidenceId = CaptureEvidence(store, directory);
            undeclaredEvidenceId = CaptureAdditionalEvidence(store, directory);
            store.RegisterComplianceReviewIncident(Registration(declaredEvidenceId));
            auditEventId = store.ApplyComplianceReviewCommand(
                Command(
                    Guid.Parse("88888888-8888-8888-8888-888888888882"),
                    ComplianceReviewState.Suspected,
                    ComplianceReviewDecisionKind.SendToLeader,
                    "project-manager",
                    RegisteredUtc.AddMinutes(2),
                    declaredEvidenceId),
                projectManagerAuthority).AuditEvent.AuditEventId;
        }

        using (var connection = Open(options.DatabasePath))
        using (var insert = connection.CreateCommand())
        {
            insert.CommandText = """
                INSERT INTO compliance_review_event_evidence(
                    audit_event_id,
                    evidence_identity_sha256)
                VALUES ($auditEventId, $evidenceIdentitySha256);
                """;
            insert.Parameters.AddWithValue("$auditEventId", auditEventId.ToString("D"));
            insert.Parameters.AddWithValue("$evidenceIdentitySha256", undeclaredEvidenceId);

            var exception = Assert.Throws<SqliteException>(() => insert.ExecuteNonQuery());
            StringAssert.Contains(
                exception.Message,
                "not declared by the immutable audit JSON",
                StringComparison.OrdinalIgnoreCase);
        }

        using var reopened = new SqliteHerdrStateStore(options);
        var audit = reopened.ReadComplianceReviewAudit("INC-27");
        Assert.HasCount(1, audit);
        CollectionAssert.AreEqual(
            new[] { declaredEvidenceId },
            audit[0].EvidenceIdentitySha256s.ToArray());
    }

    [TestMethod]
    public void OrdinarySqlCannotAppendUndeclaredEvidenceToRegisteredIncident()
    {
        using var directory = new TemporaryDirectory();
        var options = Options(directory);
        string declaredEvidenceId;
        string undeclaredEvidenceId;
        using (var store = new SqliteHerdrStateStore(options))
        {
            declaredEvidenceId = CaptureEvidence(store, directory);
            undeclaredEvidenceId = CaptureAdditionalEvidence(store, directory);
            store.RegisterComplianceReviewIncident(Registration(declaredEvidenceId));
        }

        using (var connection = Open(options.DatabasePath))
        using (var insert = connection.CreateCommand())
        {
            insert.CommandText = """
                INSERT INTO compliance_review_incident_evidence(
                    incident_id,
                    evidence_identity_sha256)
                VALUES ('INC-27', $evidenceIdentitySha256);
                """;
            insert.Parameters.AddWithValue("$evidenceIdentitySha256", undeclaredEvidenceId);

            var exception = Assert.Throws<SqliteException>(() => insert.ExecuteNonQuery());
            StringAssert.Contains(
                exception.Message,
                "not declared by the immutable registration JSON",
                StringComparison.OrdinalIgnoreCase);
        }

        using var reopened = new SqliteHerdrStateStore(options);
        var incident = reopened.ReadComplianceReviewIncident("INC-27");
        Assert.IsNotNull(incident);
        CollectionAssert.AreEqual(
            new[] { declaredEvidenceId },
            incident.InitialEvidenceIdentitySha256s.ToArray());
    }

    [TestMethod]
    public void RegistrationJsonMismatchFailsClosedOnReadAndIdempotentRetry()
    {
        using var directory = new TemporaryDirectory();
        var options = Options(directory);
        string evidenceId;
        using (var store = new SqliteHerdrStateStore(options))
        {
            evidenceId = CaptureEvidence(store, directory);
            store.RegisterComplianceReviewIncident(Registration(evidenceId));
        }

        using (var connection = Open(options.DatabasePath))
        using (var tamper = connection.CreateCommand())
        {
            tamper.CommandText = """
                DROP TRIGGER compliance_review_incidents_guard_update;
                UPDATE compliance_review_incidents
                SET registration_json = json_set(
                    registration_json,
                    '$.taskId',
                    'TASK-TAMPERED')
                WHERE incident_id = 'INC-27';
                """;
            Assert.AreEqual(1, tamper.ExecuteNonQuery());
        }

        using var reopened = new SqliteHerdrStateStore(options);
        var readException = Assert.Throws<HerdrStateStoreException>(() =>
            reopened.ReadComplianceReviewIncident("INC-27"));
        StringAssert.Contains(
            readException.Message,
            "registration JSON, columns, or evidence links disagree",
            StringComparison.OrdinalIgnoreCase);

        var retryException = Assert.Throws<HerdrStateStoreException>(() =>
            reopened.RegisterComplianceReviewIncident(Registration(evidenceId)));
        StringAssert.Contains(
            retryException.Message,
            "registration JSON, columns, or evidence links disagree",
            StringComparison.OrdinalIgnoreCase);
    }

    [TestMethod]
    public void TamperedSequenceOneEvidenceLinksBlockSequenceTwoAppend()
    {
        using var directory = new TemporaryDirectory();
        var options = Options(directory);
        ComplianceReviewAuthority leaderAuthority;
        Guid firstAuditEventId;
        string declaredEvidenceId;
        string injectedEvidenceId;
        using (var store = new SqliteHerdrStateStore(options))
        {
            var lifecycle = new AssignmentLifecycleReducer();
            var projectManagerAuthority = SeedAuthority(
                store,
                lifecycle,
                "project-manager",
                "Project Manager",
                ComplianceReviewerRole.ProjectManager,
                Guid.Parse("88888888-8888-8888-8888-888888888883"),
                sequence: 1);
            leaderAuthority = SeedAuthority(
                store,
                lifecycle,
                "backend-leader",
                "Backend Leader",
                ComplianceReviewerRole.Leader,
                Guid.Parse("88888888-8888-8888-8888-888888888884"),
                sequence: 2);
            declaredEvidenceId = CaptureEvidence(store, directory);
            injectedEvidenceId = CaptureAdditionalEvidence(store, directory);
            store.RegisterComplianceReviewIncident(Registration(declaredEvidenceId));
            firstAuditEventId = store.ApplyComplianceReviewCommand(
                Command(
                    Guid.Parse("88888888-8888-8888-8888-888888888885"),
                    ComplianceReviewState.Suspected,
                    ComplianceReviewDecisionKind.SendToLeader,
                    "project-manager",
                    RegisteredUtc.AddMinutes(2),
                    declaredEvidenceId),
                projectManagerAuthority).AuditEvent.AuditEventId;
        }

        using (var connection = Open(options.DatabasePath))
        using (var tamper = connection.CreateCommand())
        {
            tamper.CommandText = """
                DROP TRIGGER compliance_review_event_evidence_validate_insert;
                INSERT INTO compliance_review_event_evidence(
                    audit_event_id,
                    evidence_identity_sha256)
                VALUES ($auditEventId, $evidenceIdentitySha256);
                """;
            tamper.Parameters.AddWithValue("$auditEventId", firstAuditEventId.ToString("D"));
            tamper.Parameters.AddWithValue("$evidenceIdentitySha256", injectedEvidenceId);
            Assert.AreEqual(1, tamper.ExecuteNonQuery());
        }

        using (var reopened = new SqliteHerdrStateStore(options))
        {
            var exception = Assert.Throws<HerdrStateStoreException>(() =>
                reopened.ApplyComplianceReviewCommand(
                    Command(
                        Guid.Parse("88888888-8888-8888-8888-888888888886"),
                        ComplianceReviewState.PendingLeader,
                        ComplianceReviewDecisionKind.EscalateToProjectManager,
                        "backend-leader",
                        RegisteredUtc.AddMinutes(3),
                        declaredEvidenceId),
                    leaderAuthority));
            StringAssert.Contains(
                exception.Message,
                "columns, JSON, or evidence links disagree",
                StringComparison.OrdinalIgnoreCase);
        }

        using var verification = Open(options.DatabasePath);
        using var verify = verification.CreateCommand();
        verify.CommandText = """
            SELECT COUNT(*)
            FROM compliance_review_events
            WHERE incident_id = 'INC-27';
            """;
        Assert.AreEqual(1L, Convert.ToInt64(verify.ExecuteScalar()));
        verify.CommandText = """
            SELECT sequence
            FROM compliance_review_incidents
            WHERE incident_id = 'INC-27';
            """;
        Assert.AreEqual(1L, Convert.ToInt64(verify.ExecuteScalar()));
    }

    [TestMethod]
    public void OrdinarySqlCannotAppendReviewWithHistoricalReviewerAuthority()
    {
        using var directory = new TemporaryDirectory();
        var options = Options(directory);
        var historicalAuthority = default(ComplianceReviewAuthority);
        var currentAuthority = default(ComplianceReviewAuthority);
        var evidenceId = string.Empty;
        using (var store = new SqliteHerdrStateStore(options))
        {
            var lifecycle = new AssignmentLifecycleReducer();
            historicalAuthority = SeedAuthority(
                store,
                lifecycle,
                "project-manager",
                "Project Manager",
                ComplianceReviewerRole.ProjectManager,
                Guid.Parse("99999999-9999-9999-9999-999999999991"),
                sequence: 1);
            currentAuthority = SeedAuthority(
                store,
                lifecycle,
                "project-manager",
                "Project Manager",
                ComplianceReviewerRole.ProjectManager,
                Guid.Parse("99999999-9999-9999-9999-999999999992"),
                sequence: 2);
            evidenceId = CaptureEvidence(store, directory);
            store.RegisterComplianceReviewIncident(Registration(evidenceId));
        }

        using (var connection = Open(options.DatabasePath))
        {
            connection.CreateFunction<int>(
                "herdrops_review_audit_valid",
                (object?[] _) => 1,
                isDeterministic: true);
            using (var currentRole = connection.CreateCommand())
            {
                currentRole.CommandText = """
                    SELECT event_id, sequence, provenance_event_sha256
                    FROM assignment_current_actor_roles
                    WHERE actor_id = $actorId;
                    """;
                currentRole.Parameters.AddWithValue("$actorId", "project-manager");
                using var reader = currentRole.ExecuteReader();
                Assert.IsTrue(reader.Read());
                Assert.AreEqual(currentAuthority.ProvenanceEventId.ToString("D"), reader.GetString(0));
                Assert.AreEqual(currentAuthority.ProvenanceSequence, reader.GetInt64(1));
                Assert.AreEqual(currentAuthority.ProvenanceSha256, reader.GetString(2));
            }

            using (var restoreHistoricalRole = connection.CreateCommand())
            {
                restoreHistoricalRole.CommandText = """
                    UPDATE assignment_current_actor_roles
                    SET event_id = $eventId,
                        sequence = $sequence,
                        provenance_event_sha256 = $provenanceSha256
                    WHERE actor_id = 'project-manager';
                    """;
                restoreHistoricalRole.Parameters.AddWithValue(
                    "$eventId",
                    historicalAuthority.ProvenanceEventId.ToString("D"));
                restoreHistoricalRole.Parameters.AddWithValue(
                    "$sequence",
                    historicalAuthority.ProvenanceSequence);
                restoreHistoricalRole.Parameters.AddWithValue(
                    "$provenanceSha256",
                    historicalAuthority.ProvenanceSha256);
                var projectionRewrite = Assert.Throws<SqliteException>(
                    () => restoreHistoricalRole.ExecuteNonQuery());
                StringAssert.Contains(
                    projectionRewrite.Message,
                    "latest immutable role observation",
                    StringComparison.OrdinalIgnoreCase);
            }

            using var insert = connection.CreateCommand();
            insert.CommandText = """
                INSERT INTO compliance_review_events(
                    audit_event_id, contract_version, incident_id, task_id,
                    subject_actor_id, sequence, reviewer_actor_id, reviewer_role,
                    authority_provenance_event_id, authority_provenance_sequence,
                    authority_provenance_sha256, decision_kind, previous_state,
                    result_state, reason, occurred_utc, evidence_set_sha256,
                    previous_audit_sha256, audit_sha256, audit_json, audit_json_sha256)
                VALUES (
                    $auditEventId, 1, 'INC-27', 'TASK-115', 'backend-worker-01', 1,
                    'project-manager', 1, $provenanceEventId, $provenanceSequence,
                    $provenanceSha256, 1, 1, 4,
                    'Historical authority must not append a review event.',
                    $occurredUtc, $evidenceSetSha256, NULL, $auditSha256,
                    '{}', $auditJsonSha256);
                """;
            insert.Parameters.AddWithValue(
                "$auditEventId",
                "99999999-9999-9999-9999-999999999993");
            insert.Parameters.AddWithValue(
                "$provenanceEventId",
                historicalAuthority.ProvenanceEventId.ToString("D"));
            insert.Parameters.AddWithValue(
                "$provenanceSequence",
                historicalAuthority.ProvenanceSequence);
            insert.Parameters.AddWithValue(
                "$provenanceSha256",
                historicalAuthority.ProvenanceSha256);
            insert.Parameters.AddWithValue(
                "$occurredUtc",
                RegisteredUtc.AddMinutes(2).ToString("O"));
            insert.Parameters.AddWithValue("$evidenceSetSha256", new string('A', 64));
            insert.Parameters.AddWithValue("$auditSha256", new string('B', 64));
            insert.Parameters.AddWithValue("$auditJsonSha256", new string('C', 64));

            var exception = Assert.Throws<SqliteException>(() => insert.ExecuteNonQuery());
            StringAssert.Contains(exception.Message, "current-authority", StringComparison.OrdinalIgnoreCase);
        }

        using var unchanged = new SqliteHerdrStateStore(options);
        Assert.IsEmpty(unchanged.ReadComplianceReviewAudit("INC-27"));
        var incident = unchanged.ReadComplianceReviewIncident("INC-27");
        Assert.IsNotNull(incident);
        Assert.AreEqual(ComplianceReviewState.Suspected, incident.State);
        Assert.AreEqual(0L, incident.Sequence);
        Assert.IsNull(incident.LastAuditEventId);
        Assert.IsNull(incident.LastAuditSha256);
    }

    [TestMethod]
    public void VersionThreeDatabaseBacksUpAndMigratesForwardWithoutLosingEvidence()
    {
        using var directory = new TemporaryDirectory();
        var databasePath = Path.Combine(directory.Path, "v3.db");
        using (var versionThree = Open(databasePath))
        {
            for (var version = 1; version <= 3; version++)
            {
                var migration = SqliteHerdrStateStore.GetMigrationForTesting(version);
                using var command = versionThree.CreateCommand();
                command.CommandText = migration.Sql;
                command.ExecuteNonQuery();
                command.CommandText = """
                    INSERT INTO schema_migrations(version, name, applied_utc, script_sha256)
                    VALUES ($version, $name, $appliedUtc, $hash);
                    """;
                command.Parameters.Clear();
                command.Parameters.AddWithValue("$version", version);
                command.Parameters.AddWithValue("$name", migration.Name);
                command.Parameters.AddWithValue(
                    "$appliedUtc",
                    $"2026-08-16T02:00:0{version}.0000000+00:00");
                command.Parameters.AddWithValue("$hash", migration.ScriptSha256);
                command.ExecuteNonQuery();
            }

            using var finalize = versionThree.CreateCommand();
            finalize.CommandText = """
                INSERT INTO evidence_items(
                    evidence_identity_sha256, contract_version, task_id, actor_id,
                    source_event_id, source, source_reference, observed_utc,
                    ingested_utc, retain_until_utc, availability, storage_kind,
                    content_length, content_sha256, managed_relative_path,
                    metadata_json, metadata_json_sha256, metadata_sha256)
                VALUES (
                    $identity, 1, 'TASK-V3', 'actor-v3', 'EVENT-V3', 'migration-test',
                    'redacted://v3', '2026-08-16T02:00:00.0000000+00:00',
                    '2026-08-16T02:00:01.0000000+00:00',
                    '2026-09-16T02:00:00.0000000+00:00', 2, 1, NULL, NULL, NULL,
                    '{}', $jsonHash, $metadataHash);
                PRAGMA user_version = 3;
                """;
            finalize.Parameters.AddWithValue("$identity", new string('A', 64));
            finalize.Parameters.AddWithValue("$jsonHash", new string('B', 64));
            finalize.Parameters.AddWithValue("$metadataHash", new string('C', 64));
            finalize.ExecuteNonQuery();
        }

        string backupPath;
        using (var migrated = new SqliteHerdrStateStore(
                   new HerdrStateStoreOptions(databasePath)))
        {
            backupPath = migrated.LastBackupPath!;
            Assert.AreEqual(4, migrated.GetDiagnostics().SchemaVersion);
            Assert.IsTrue(File.Exists(backupPath));
        }

        using var current = Open(databasePath);
        using var currentCommand = current.CreateCommand();
        currentCommand.CommandText = "SELECT COUNT(*) FROM evidence_items;";
        Assert.AreEqual(1L, Convert.ToInt64(currentCommand.ExecuteScalar()));
        currentCommand.CommandText = "SELECT COUNT(*) FROM schema_migrations;";
        Assert.AreEqual(4L, Convert.ToInt64(currentCommand.ExecuteScalar()));
        currentCommand.CommandText = "SELECT COUNT(*) FROM compliance_review_incidents;";
        Assert.AreEqual(0L, Convert.ToInt64(currentCommand.ExecuteScalar()));

        using var backup = Open(backupPath);
        using var backupCommand = backup.CreateCommand();
        backupCommand.CommandText = "PRAGMA user_version;";
        Assert.AreEqual(3L, Convert.ToInt64(backupCommand.ExecuteScalar()));
    }

    private static HerdrStateStoreOptions Options(TemporaryDirectory directory) =>
        new(Path.Combine(directory.Path, "state", "herdrops.db"));

    private static string CaptureEvidence(
        SqliteHerdrStateStore store,
        TemporaryDirectory directory)
    {
        var capture = store.CaptureEvidence(
            new EvidenceCaptureRequest(
                EvidenceMetadataContract.ContractVersion,
                "TASK-115",
                "backend-worker-01",
                "EVENT-EVIDENCE-27",
                "integration-test",
                "redacted://review/evidence.bin",
                RegisteredUtc,
                RegisteredUtc.AddSeconds(1),
                RegisteredUtc.AddDays(30),
                CreateManagedCopy: false),
            Path.Combine(directory.Path, "missing-evidence.bin"));
        return capture.StoredEvidence.Metadata.EvidenceIdentitySha256;
    }

    private static string CaptureAdditionalEvidence(
        SqliteHerdrStateStore store,
        TemporaryDirectory directory)
    {
        var capture = store.CaptureEvidence(
            new EvidenceCaptureRequest(
                EvidenceMetadataContract.ContractVersion,
                "TASK-115",
                "backend-worker-01",
                "EVENT-EVIDENCE-EXTRA-27",
                "integration-test",
                "redacted://review/extra-evidence.bin",
                RegisteredUtc.AddSeconds(2),
                RegisteredUtc.AddSeconds(3),
                RegisteredUtc.AddDays(30),
                CreateManagedCopy: false),
            Path.Combine(directory.Path, "missing-extra-evidence.bin"));
        return capture.StoredEvidence.Metadata.EvidenceIdentitySha256;
    }

    private static ComplianceReviewIncidentRegistration Registration(string evidenceId) =>
        new(
            ComplianceReviewWorkflowContract.ContractVersion,
            "INC-27",
            "TASK-115",
            "backend-worker-01",
            RegisteredUtc.AddMinutes(1),
            [evidenceId]);

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
            "INC-27",
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
            "The evidence and assignment scope were reviewed.",
            occurredUtc,
            [evidenceId]);

    private static ComplianceReviewAuthority Authority(
        string actorId,
        ComplianceReviewerRole role,
        Guid provenanceEventId) =>
        new(
            actorId,
            role,
            provenanceEventId,
            ProvenanceSequence: role == ComplianceReviewerRole.ProjectManager ? 10 : 11,
            RegisteredUtc.AddMinutes(1),
            role == ComplianceReviewerRole.ProjectManager
                ? new string('D', 64)
                : new string('E', 64));

    private static ComplianceReviewAuthority SeedAuthority(
        SqliteHerdrStateStore store,
        AssignmentLifecycleReducer reducer,
        string actorId,
        string actorRole,
        ComplianceReviewerRole reviewerRole,
        Guid eventId,
        long sequence)
    {
        var occurredUtc = RegisteredUtc.AddSeconds(sequence);
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
}
