using System.Security.Cryptography;
using System.Text;
using HerdrOps.Domain.Assignments;
using HerdrOps.Infrastructure.Storage;
using Microsoft.Data.Sqlite;

namespace HerdrOps.IntegrationTests;

[TestClass]
public sealed class AssignmentLifecycleStoreTests
{
    private static readonly DateTimeOffset BaseUtc =
        new(2026, 8, 15, 2, 0, 0, TimeSpan.Zero);

    [TestMethod]
    public void RestartPreservesExactReplayAndHistoricalProvenance()
    {
        using var directory = new TemporaryDirectory();
        var options = new HerdrStateStoreOptions(
            Path.Combine(directory.Path, "assignment-lifecycle.db"));
        var events = CompleteTrace();
        var expected = AssignmentLifecycleReplay.Run(events);

        using (var store = new SqliteHerdrStateStore(options))
        {
            foreach (var step in expected.Steps)
            {
                var write = store.CommitAssignmentLifecycle(step);
                Assert.IsFalse(write.WasAlreadyPresent);
                Assert.AreEqual(step.Audit.AuditSha256, write.StoredEvent.Audit.AuditSha256);
            }

            var retry = store.CommitAssignmentLifecycle(expected.Steps[0]);
            Assert.IsTrue(retry.WasAlreadyPresent);

            var diagnostics = store.GetDiagnostics();
            Assert.AreEqual(3, diagnostics.SchemaVersion);
            Assert.AreEqual(7L, diagnostics.LifecycleEventCount);
            Assert.AreEqual(1L, diagnostics.AssignmentTaskCount);
            Assert.AreEqual(3L, diagnostics.AssignmentRelationshipCount);
            Assert.AreEqual(0L, diagnostics.OrphanLifecycleEventCount);
            Assert.AreEqual(0L, diagnostics.DuplicateHandoffCount);
        }

        using var restarted = new SqliteHerdrStateStore(options);
        var persisted = restarted.ReadAssignmentLifecycleEvents();
        CollectionAssert.AreEqual(
            events.ToArray(),
            persisted.Select(item => item.NormalizedEvent.Event).ToArray());
        CollectionAssert.AreEqual(
            expected.AuditTrail.ToArray(),
            persisted.Select(item => item.Audit).ToArray());

        var replayed = AssignmentLifecycleReplay.Run(
            persisted.Select(item => item.NormalizedEvent.Event).ToArray());
        Assert.AreEqual(expected.ResultSha256, replayed.ResultSha256);
        Assert.AreEqual(expected.Diagnostics, replayed.Diagnostics);
        Assert.AreEqual(expected.CurrentTasks[0], restarted.ReadAssignmentTask("TASK-115"));
        CollectionAssert.AreEqual(
            expected.Relationships.ToArray(),
            restarted.ReadAssignmentRelationships("TASK-115").ToArray());
        CollectionAssert.AreEqual(
            expected.RoleHistory.ToArray(),
            restarted.ReadAssignmentRoleHistory().ToArray());
        CollectionAssert.AreEqual(
            expected.CurrentRoles.ToArray(),
            restarted.ReadCurrentAssignmentRoles().ToArray());
        Assert.HasCount(4, restarted.ReadAssignmentRoleHistory("backend-worker-01"));
    }

    [TestMethod]
    public void OrphanAndDuplicateHandoffRemainQueryableWithoutChangingTaskTip()
    {
        using var directory = new TemporaryDirectory();
        using var store = new SqliteHerdrStateStore(new HerdrStateStoreOptions(
            Path.Combine(directory.Path, "assignment-audit.db")));
        var orphan = CreateEvent(
            AssignmentLifecycleEventKind.Acknowledgement,
            sequence: 1,
            taskId: "TASK-404",
            actorId: "missing-worker",
            actorRole: "Worker",
            parentEventId: GuidFor(900));
        var validTrace = CompleteTrace(startSequence: 2);
        var firstHandoff = validTrace[^1];
        var duplicateHandoff = CreateEvent(
            AssignmentLifecycleEventKind.Handoff,
            sequence: 9,
            actorId: "backend-worker-01",
            actorRole: "Backend Worker",
            parentEventId: firstHandoff.EventId,
            targetAgentId: "reviewer-02",
            handoffNote: "Duplicate handoff must remain visible.");
        var replay = AssignmentLifecycleReplay.Run(
            [orphan, .. validTrace, duplicateHandoff]);

        foreach (var step in replay.Steps)
        {
            store.CommitAssignmentLifecycle(step);
        }

        var orphanAudit = store.ReadAssignmentLifecycleEvents("TASK-404");
        Assert.HasCount(1, orphanAudit);
        Assert.AreEqual(
            AssignmentLifecycleDisposition.OrphanTask,
            orphanAudit[0].Audit.Disposition);
        var taskAudit = store.ReadAssignmentLifecycleEvents("TASK-115");
        Assert.HasCount(8, taskAudit);
        Assert.AreEqual(
            AssignmentLifecycleDisposition.DuplicateHandoff,
            taskAudit[^1].Audit.Disposition);
        var current = store.ReadAssignmentTask("TASK-115");
        Assert.IsNotNull(current);
        Assert.AreEqual(firstHandoff.EventId, current.State.LastEventId);
        Assert.AreEqual("reviewer-01", current.State.CurrentAssigneeId);
        Assert.AreEqual(1, current.State.HandoffCount);
        Assert.HasCount(3, store.ReadAssignmentRelationships("TASK-115"));

        var diagnostics = store.GetDiagnostics();
        Assert.AreEqual(1L, diagnostics.OrphanLifecycleEventCount);
        Assert.AreEqual(1L, diagnostics.DuplicateHandoffCount);
        Assert.AreEqual(9L, diagnostics.LifecycleEventCount);
    }

    [TestMethod]
    public void StoreRejectsAppliedStepFromDisconnectedTaskHistory()
    {
        using var directory = new TemporaryDirectory();
        using var store = new SqliteHerdrStateStore(new HerdrStateStoreOptions(
            Path.Combine(directory.Path, "assignment-context.db")));
        var persistedEvent = CreateEvent(
            AssignmentLifecycleEventKind.Assignment,
            sequence: 1,
            actorId: "project-manager",
            actorRole: "Project Manager",
            targetAgentId: "backend-leader");
        var persistedReducer = new AssignmentLifecycleReducer();
        store.CommitAssignmentLifecycle(persistedReducer.Process(persistedEvent));

        var disconnectedReducer = new AssignmentLifecycleReducer();
        _ = disconnectedReducer.Process(CreateEvent(
            AssignmentLifecycleEventKind.Assignment,
            sequence: 1,
            taskId: "TASK-OTHER",
            actorId: "project-manager",
            actorRole: "Project Manager",
            targetAgentId: "other-worker"));
        var disconnectedStep = disconnectedReducer.Process(CreateEvent(
            AssignmentLifecycleEventKind.Assignment,
            sequence: 2,
            actorId: "project-manager",
            actorRole: "Project Manager",
            targetAgentId: "replacement-worker"));
        Assert.AreEqual(
            AssignmentLifecycleDisposition.Applied,
            disconnectedStep.Audit.Disposition);

        var exception = Assert.Throws<HerdrStateStoreException>(() =>
            store.CommitAssignmentLifecycle(disconnectedStep));
        StringAssert.Contains(exception.Message, "prior-state provenance");
        Assert.AreEqual(1L, store.GetDiagnostics().LifecycleEventCount);
        Assert.AreEqual("backend-leader", store.ReadAssignmentTask("TASK-115")!.State.CurrentAssigneeId);
    }

    [TestMethod]
    public void StoreRejectsForgedConsumedDispositionEvenWhenHashesAreValid()
    {
        using var directory = new TemporaryDirectory();
        using var store = new SqliteHerdrStateStore(new HerdrStateStoreOptions(
            Path.Combine(directory.Path, "assignment-forged-audit.db")));
        var reducer = new AssignmentLifecycleReducer();
        var assignment = CreateEvent(
            AssignmentLifecycleEventKind.Assignment,
            sequence: 1,
            actorId: "project-manager",
            actorRole: "Project Manager",
            targetAgentId: "backend-leader");
        var assignmentStep = reducer.Process(assignment);
        store.CommitAssignmentLifecycle(assignmentStep);
        var acknowledgement = CreateEvent(
            AssignmentLifecycleEventKind.Acknowledgement,
            sequence: 2,
            actorId: "backend-leader",
            actorRole: "Backend Leader",
            parentEventId: assignment.EventId);
        var acknowledgementStep = reducer.Process(acknowledgement);
        store.CommitAssignmentLifecycle(acknowledgementStep);
        var progress = CreateEvent(
            AssignmentLifecycleEventKind.Progress,
            sequence: 3,
            actorId: "backend-leader",
            actorRole: "Backend Leader",
            parentEventId: acknowledgement.EventId,
            progressPercent: 50);
        var appliedProgress = reducer.Process(progress);
        var priorTask = acknowledgementStep.CurrentTask!;
        var forgedAudit = AssignmentLifecycleContract.CreateAuditEntry(
            appliedProgress.NormalizedEvent,
            AssignmentLifecycleDisposition.InvalidTransition,
            consumesSequence: true,
            "forged-rejection",
            "A caller cannot replace deterministic transition semantics.",
            priorTask.StateSha256,
            priorTask.StateSha256);
        var forgedStep = new AssignmentLifecycleStep(
            appliedProgress.NormalizedEvent,
            forgedAudit,
            priorTask,
            Relationship: null,
            RoleObservation: null);

        var exception = Assert.Throws<HerdrStateStoreException>(() =>
            store.CommitAssignmentLifecycle(forgedStep));
        StringAssert.Contains(exception.Message, "deterministic replay");
        Assert.AreEqual(2L, store.GetDiagnostics().LifecycleEventCount);
        Assert.AreEqual(
            acknowledgement.EventId,
            store.ReadAssignmentTask("TASK-115")!.State.LastEventId);

        store.CommitAssignmentLifecycle(appliedProgress);
        Assert.AreEqual(3L, store.GetDiagnostics().LifecycleEventCount);
        Assert.AreEqual(50, store.ReadAssignmentTask("TASK-115")!.State.ProgressPercent);
    }

    [TestMethod]
    public void StoreRejectsAppliedStepThatHidesAPersistedSequenceGap()
    {
        using var directory = new TemporaryDirectory();
        using var store = new SqliteHerdrStateStore(new HerdrStateStoreOptions(
            Path.Combine(directory.Path, "assignment-hidden-gap.db")));
        var persistedReducer = new AssignmentLifecycleReducer();
        var orphan = CreateEvent(
            AssignmentLifecycleEventKind.Acknowledgement,
            sequence: 1,
            taskId: "TASK-404",
            actorId: "missing-worker",
            actorRole: "Worker",
            parentEventId: GuidFor(900));
        store.CommitAssignmentLifecycle(persistedReducer.Process(orphan));

        var disconnectedReducer = new AssignmentLifecycleReducer();
        _ = disconnectedReducer.Process(CreateEvent(
            AssignmentLifecycleEventKind.Assignment,
            sequence: 1,
            taskId: "TASK-HIDDEN-1",
            actorId: "project-manager",
            actorRole: "Project Manager",
            targetAgentId: "worker-01"));
        _ = disconnectedReducer.Process(CreateEvent(
            AssignmentLifecycleEventKind.Assignment,
            sequence: 2,
            taskId: "TASK-HIDDEN-2",
            actorId: "project-manager",
            actorRole: "Project Manager",
            targetAgentId: "worker-02"));
        var hiddenGapStep = disconnectedReducer.Process(CreateEvent(
            AssignmentLifecycleEventKind.Assignment,
            sequence: 3,
            actorId: "project-manager",
            actorRole: "Project Manager",
            targetAgentId: "backend-leader"));
        Assert.AreEqual(
            AssignmentLifecycleDisposition.Applied,
            hiddenGapStep.Audit.Disposition);

        var exception = Assert.Throws<HerdrStateStoreException>(() =>
            store.CommitAssignmentLifecycle(hiddenGapStep));
        StringAssert.Contains(exception.Message, "deterministic replay");
        Assert.AreEqual(1L, store.GetDiagnostics().LifecycleEventCount);
        Assert.IsNull(store.ReadAssignmentTask("TASK-115"));

        var visibleGap = persistedReducer.Process(hiddenGapStep.NormalizedEvent.Event);
        Assert.AreEqual(
            AssignmentLifecycleDisposition.SequenceGap,
            visibleGap.Audit.Disposition);
        store.CommitAssignmentLifecycle(visibleGap);
        Assert.AreEqual(2L, store.GetDiagnostics().LifecycleEventCount);
        Assert.IsNull(store.ReadAssignmentTask("TASK-115"));
    }

    [TestMethod]
    public void LifecycleLedgersRejectMutationAndReadsDetectByteTampering()
    {
        using var directory = new TemporaryDirectory();
        var databasePath = Path.Combine(directory.Path, "assignment-tamper.db");
        var replay = AssignmentLifecycleReplay.Run([CompleteTrace()[0]]);
        using (var store = new SqliteHerdrStateStore(
                   new HerdrStateStoreOptions(databasePath)))
        {
            store.CommitAssignmentLifecycle(replay.Steps[0]);
        }

        using (var connection = Open(databasePath))
        {
            using var command = connection.CreateCommand();
            command.CommandText =
                "UPDATE assignment_lifecycle_events SET source = 'tampered' WHERE sequence = 1;";
            var eventMutation = Assert.Throws<SqliteException>(() => command.ExecuteNonQuery());
            StringAssert.Contains(eventMutation.Message, "append-only", StringComparison.OrdinalIgnoreCase);

            command.CommandText =
                "UPDATE assignment_relationships SET to_actor_id = 'tampered' WHERE sequence = 1;";
            var relationshipMutation = Assert.Throws<SqliteException>(() => command.ExecuteNonQuery());
            StringAssert.Contains(
                relationshipMutation.Message,
                "append-only",
                StringComparison.OrdinalIgnoreCase);

            command.CommandText = """
                DROP TRIGGER assignment_lifecycle_events_reject_update;
                UPDATE assignment_lifecycle_events
                SET event_json = '{}'
                WHERE sequence = 1;
                """;
            command.ExecuteNonQuery();
        }

        var exception = Assert.Throws<HerdrStateStoreException>(() =>
            new SqliteHerdrStateStore(new HerdrStateStoreOptions(databasePath)));
        StringAssert.Contains(exception.Message, "JSON hash");
    }

    [TestMethod]
    public void CurrentTaskReadRejectsScalarProjectionDrift()
    {
        using var directory = new TemporaryDirectory();
        var databasePath = Path.Combine(directory.Path, "assignment-projection-drift.db");
        var replay = AssignmentLifecycleReplay.Run([CompleteTrace()[0]]);
        using (var store = new SqliteHerdrStateStore(
                   new HerdrStateStoreOptions(databasePath)))
        {
            store.CommitAssignmentLifecycle(replay.Steps[0]);
        }

        using (var connection = Open(databasePath))
        {
            using var command = connection.CreateCommand();
            command.CommandText = """
                UPDATE assignment_tasks
                SET progress_percent = 99
                WHERE task_id = 'TASK-115';
                """;
            Assert.AreEqual(1, command.ExecuteNonQuery());
        }

        using var drifted = new SqliteHerdrStateStore(
            new HerdrStateStoreOptions(databasePath));
        var exception = Assert.Throws<HerdrStateStoreException>(() =>
            drifted.ReadAssignmentTask("TASK-115"));
        StringAssert.Contains(exception.Message, "scalar projection");
    }

    private static IReadOnlyList<AssignmentLifecycleEvent> CompleteTrace(
        int startSequence = 1)
    {
        var assignment = CreateEvent(
            AssignmentLifecycleEventKind.Assignment,
            startSequence,
            "project-manager",
            "Project Manager",
            targetAgentId: "backend-leader");
        var leaderAcknowledgement = CreateEvent(
            AssignmentLifecycleEventKind.Acknowledgement,
            startSequence + 1,
            "backend-leader",
            "Backend Leader",
            parentEventId: assignment.EventId);
        var delegation = CreateEvent(
            AssignmentLifecycleEventKind.Delegation,
            startSequence + 2,
            "backend-leader",
            "Backend Leader",
            parentEventId: leaderAcknowledgement.EventId,
            targetAgentId: "backend-worker-01");
        var workerAcknowledgement = CreateEvent(
            AssignmentLifecycleEventKind.Acknowledgement,
            startSequence + 3,
            "backend-worker-01",
            "Backend Worker",
            parentEventId: delegation.EventId);
        var progress = CreateEvent(
            AssignmentLifecycleEventKind.Progress,
            startSequence + 4,
            "backend-worker-01",
            "Backend Worker",
            parentEventId: workerAcknowledgement.EventId,
            progressPercent: 50);
        var evidence = CreateEvent(
            AssignmentLifecycleEventKind.Evidence,
            startSequence + 5,
            "backend-worker-01",
            "Backend Worker",
            parentEventId: progress.EventId,
            evidenceReference: "artifacts/tests/self-report.trx",
            evidenceSha256: Hash("evidence"));
        var handoff = CreateEvent(
            AssignmentLifecycleEventKind.Handoff,
            startSequence + 6,
            "backend-worker-01",
            "Backend Worker",
            parentEventId: evidence.EventId,
            targetAgentId: "reviewer-01",
            handoffNote: "Implementation and evidence are ready for review.");
        return
        [
            assignment,
            leaderAcknowledgement,
            delegation,
            workerAcknowledgement,
            progress,
            evidence,
            handoff,
        ];
    }

    private static AssignmentLifecycleEvent CreateEvent(
        AssignmentLifecycleEventKind eventKind,
        int sequence,
        string actorId,
        string actorRole,
        string taskId = "TASK-115",
        Guid? parentEventId = null,
        string? targetAgentId = null,
        int? progressPercent = null,
        string? deviationReason = null,
        string? evidenceReference = null,
        string? evidenceSha256 = null,
        string? handoffNote = null) => new(
        AssignmentLifecycleContract.Version,
        GuidFor(sequence),
        eventKind,
        sequence,
        BaseUtc.AddSeconds(sequence - 1),
        BaseUtc.AddSeconds(sequence),
        AssignmentLifecycleContract.CoreSource,
        GuidFor(100 + sequence),
        Hash($"self-report-{sequence}-{eventKind}"),
        taskId,
        actorId,
        actorRole,
        $"Lifecycle event {sequence}: {eventKind}.",
        parentEventId,
        targetAgentId,
        progressPercent,
        deviationReason,
        evidenceReference,
        evidenceSha256,
        handoffNote);

    private static Guid GuidFor(int value) =>
        Guid.Parse($"00000000-0000-0000-0000-{value:000000000000}");

    private static string Hash(string value) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value)));

    private static SqliteConnection Open(string path)
    {
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
