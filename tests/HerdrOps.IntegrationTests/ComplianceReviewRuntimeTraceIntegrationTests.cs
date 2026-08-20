using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using HerdrOps.Contracts.ReviewIpc;
using HerdrOps.Core;
using HerdrOps.Domain.Assignments;
using HerdrOps.Domain.Compliance;
using HerdrOps.Domain.Evidence;
using HerdrOps.Domain.Lifecycle;
using HerdrOps.Infrastructure.Storage;
using Microsoft.Data.Sqlite;

namespace HerdrOps.IntegrationTests;

[TestClass]
public sealed class ComplianceReviewRuntimeTraceIntegrationTests
{
    private static readonly JsonSerializerOptions TraceSerializerOptions = new(JsonSerializerDefaults.Web)
    {
        AllowTrailingCommas = false,
        MaxDepth = 64,
        PropertyNameCaseInsensitive = false,
        ReadCommentHandling = JsonCommentHandling.Disallow,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
    };

    private static readonly DateTimeOffset ObservedUtc =
        new(2026, 8, 20, 10, 0, 0, TimeSpan.Zero);

    [TestMethod]
    public void EmptyDatabaseProducesCleanZeroCountTraceReport()
    {
        using var directory = new TemporaryDirectory();
        var databasePath = Path.Combine(directory.Path, "herdrops.db");
        var reportPath = Path.Combine(directory.Path, "trace-report.json");

        // Initialize state store (creates schema v4)
        using (var store = new SqliteHerdrStateStore(new HerdrStateStoreOptions(databasePath)))
        {
            Assert.AreEqual(4, store.GetDiagnostics().SchemaVersion);
        }

        using var output = new StringWriter();
        using var error = new StringWriter();

        var exitCode = ComplianceReviewRuntimeTraceCommand.Run(
            ["trace-compliance-review", "--database", databasePath, "--report", reportPath],
            output,
            error);

        Assert.AreEqual(ComplianceReviewRuntimeTraceCommand.SuccessExitCode, exitCode);
        Assert.IsTrue(File.Exists(reportPath));

        var json = File.ReadAllText(reportPath);
        var report = JsonSerializer.Deserialize<ComplianceReviewRuntimeTraceReport>(json, TraceSerializerOptions);

        Assert.IsNotNull(report);
        Assert.AreEqual(ComplianceReviewRuntimeTraceContract.Version, report.ContractVersion);
        Assert.AreEqual(4, report.SchemaVersion);
        Assert.AreEqual(0, report.IncidentCount);
        Assert.AreEqual(0, report.AuditEventCount);
        Assert.AreEqual(0, report.EvidenceLinkCount);
        Assert.IsFalse(report.RuntimeObserved);
        Assert.IsFalse(report.SessionControlInvoked);
        Assert.IsFalse(report.RestartObserved);
        Assert.IsFalse(report.ReconnectObserved);
        Assert.AreEqual(64, report.DatabaseFileSha256.Length);
        Assert.AreEqual(64, report.ProductAssemblySha256.Length);
        Assert.AreNotEqual(databasePath, report.DatabasePath);
        StringAssert.StartsWith(report.DatabasePath, "path-sha256:");
        Assert.AreEqual(ComplianceReviewRuntimeTraceContract.RedactedMachineValue, report.HostName);
        Assert.AreEqual(ComplianceReviewRuntimeTraceContract.RedactedMachineValue, report.OperatingSystem);
        StringAssert.Contains(report.EvidenceBoundary, "SQLite schema v4");
    }

    [TestMethod]
    public void CompleteIncidentsAndAuditEventsProduceAccurateTraceAndRetentionObservations()
    {
        using var directory = new TemporaryDirectory();
        var databasePath = Path.Combine(directory.Path, "herdrops.db");
        var reportPath = Path.Combine(directory.Path, "trace-report.json");
        var options = new HerdrStateStoreOptions(
            databasePath,
            ManagedEvidenceRootPath: Path.Combine(directory.Path, "managed-evidence"));

        string evidenceA;
        string evidenceB;
        string evidenceC;

        using (var store = new SqliteHerdrStateStore(options, new FixedTimeProvider(ObservedUtc)))
        {
            var lifecycle = new AssignmentLifecycleReducer();
            var pmAuthority = SeedAuthority(
                store,
                lifecycle,
                "project-manager",
                "Project Manager",
                ComplianceReviewerRole.ProjectManager,
                Guid.Parse("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"),
                sequence: 1);

            evidenceA = CaptureEvidence(store, directory, "evidenceA.bin");
            evidenceB = CaptureEvidence(store, directory, "evidenceB.bin");
            evidenceC = CaptureEvidence(store, directory, "evidenceC.bin");

            // Incident 1: INC-OPEN (Suspected -> PendingLeader) with evidenceA and evidenceB
            store.RegisterComplianceReviewIncident(new ComplianceReviewIncidentRegistration(
                ComplianceReviewWorkflowContract.ContractVersion,
                "INC-OPEN",
                "TASK-115",
                "worker-01",
                ObservedUtc.AddMinutes(1),
                [evidenceA]));

            store.ApplyComplianceReviewCommand(
                new ComplianceReviewCommand(
                    ComplianceReviewWorkflowContract.ContractVersion,
                    Guid.Parse("11111111-1111-1111-1111-111111111111"),
                    "INC-OPEN",
                    ComplianceReviewState.Suspected,
                    0,
                    "project-manager",
                    ComplianceReviewDecisionKind.SendToLeader,
                    "Send to leader for investigation.",
                    ObservedUtc.AddMinutes(2),
                    [evidenceB]),
                pmAuthority);

            // Incident 2: INC-CLOSED (Suspected -> Confirmed) with evidenceC
            store.RegisterComplianceReviewIncident(new ComplianceReviewIncidentRegistration(
                ComplianceReviewWorkflowContract.ContractVersion,
                "INC-CLOSED",
                "TASK-115",
                "worker-02",
                ObservedUtc.AddMinutes(3),
                [evidenceC]));

            store.ApplyComplianceReviewCommand(
                new ComplianceReviewCommand(
                    ComplianceReviewWorkflowContract.ContractVersion,
                    Guid.Parse("22222222-2222-2222-2222-222222222222"),
                    "INC-CLOSED",
                    ComplianceReviewState.Suspected,
                    0,
                    "project-manager",
                    ComplianceReviewDecisionKind.Confirm,
                    "Confirmed closed incident.",
                    ObservedUtc.AddMinutes(4),
                    []),
                pmAuthority);
        }

        using var output = new StringWriter();
        using var error = new StringWriter();

        var exitCode = ComplianceReviewRuntimeTraceCommand.Run(
            ["trace-compliance-review", "--database", databasePath, "--report", reportPath],
            output,
            error);

        Assert.AreEqual(ComplianceReviewRuntimeTraceCommand.SuccessExitCode, exitCode);
        Assert.IsTrue(File.Exists(reportPath));

        var json = File.ReadAllText(reportPath);
        var report = JsonSerializer.Deserialize<ComplianceReviewRuntimeTraceReport>(json, TraceSerializerOptions);

        Assert.IsNotNull(report);
        Assert.IsFalse(report.RuntimeObserved);
        Assert.IsFalse(report.SessionControlInvoked);
        Assert.IsFalse(report.RestartObserved);
        Assert.IsFalse(report.ReconnectObserved);
        Assert.AreEqual(2, report.IncidentCount);
        Assert.AreEqual(2, report.AuditEventCount);
        Assert.AreEqual(3, report.EvidenceLinkCount);

        var incOpen = report.Incidents.Single(i => i.IncidentId == "INC-OPEN");
        var incClosed = report.Incidents.Single(i => i.IncidentId == "INC-CLOSED");
        Assert.AreEqual((int)ComplianceReviewState.PendingLeader, incOpen.State);
        Assert.AreEqual((int)ComplianceReviewState.Confirmed, incClosed.State);

        var obsA = report.RetentionObservations.Single(o => o.EvidenceIdentitySha256 == evidenceA);
        var obsB = report.RetentionObservations.Single(o => o.EvidenceIdentitySha256 == evidenceB);
        var obsC = report.RetentionObservations.Single(o => o.EvidenceIdentitySha256 == evidenceC);

        Assert.IsTrue(obsA.IsProtectedFromPurge);
        Assert.IsTrue(obsA.HasOpenIncident);
        Assert.IsFalse(obsA.HasTerminalIncident);

        Assert.IsTrue(obsB.IsProtectedFromPurge);
        Assert.IsTrue(obsB.HasOpenIncident);
        Assert.IsFalse(obsB.HasTerminalIncident);

        Assert.IsFalse(obsC.IsProtectedFromPurge);
        Assert.IsFalse(obsC.HasOpenIncident);
        Assert.IsTrue(obsC.HasTerminalIncident);
    }

    [TestMethod]
    public void FilteringByTaskIdAndIncidentIdIsExact()
    {
        using var directory = new TemporaryDirectory();
        var databasePath = Path.Combine(directory.Path, "herdrops.db");
        var reportPath = Path.Combine(directory.Path, "trace-report.json");
        var options = new HerdrStateStoreOptions(databasePath);

        using (var store = new SqliteHerdrStateStore(options, new FixedTimeProvider(ObservedUtc)))
        {
            var evidenceA = CaptureEvidence(store, directory, "evA.bin");
            var evidenceB = CaptureEvidence(store, directory, "evB.bin");

            store.RegisterComplianceReviewIncident(new ComplianceReviewIncidentRegistration(
                ComplianceReviewWorkflowContract.ContractVersion,
                "INC-TASK-A",
                "TASK-ALPHA",
                "worker-01",
                ObservedUtc.AddMinutes(1),
                [evidenceA]));

            store.RegisterComplianceReviewIncident(new ComplianceReviewIncidentRegistration(
                ComplianceReviewWorkflowContract.ContractVersion,
                "INC-TASK-B",
                "TASK-BETA",
                "worker-02",
                ObservedUtc.AddMinutes(2),
                [evidenceB]));
        }

        // Test filter by --task-id
        using (var output = new StringWriter())
        using (var error = new StringWriter())
        {
            var exitCode = ComplianceReviewRuntimeTraceCommand.Run(
                ["trace-compliance-review", "--database", databasePath, "--report", reportPath, "--task-id", "TASK-ALPHA"],
                output,
                error);
            Assert.AreEqual(ComplianceReviewRuntimeTraceCommand.SuccessExitCode, exitCode);
            var report = JsonSerializer.Deserialize<ComplianceReviewRuntimeTraceReport>(File.ReadAllText(reportPath), TraceSerializerOptions);
            Assert.IsNotNull(report);
            Assert.AreEqual(1, report.IncidentCount);
            Assert.AreEqual("INC-TASK-A", report.Incidents[0].IncidentId);
        }

        // Test filter by --incident
        using (var output = new StringWriter())
        using (var error = new StringWriter())
        {
            var exitCode = ComplianceReviewRuntimeTraceCommand.Run(
                ["trace-compliance-review", "--database", databasePath, "--report", reportPath, "--incident", "INC-TASK-B"],
                output,
                error);
            Assert.AreEqual(ComplianceReviewRuntimeTraceCommand.SuccessExitCode, exitCode);
            var report = JsonSerializer.Deserialize<ComplianceReviewRuntimeTraceReport>(File.ReadAllText(reportPath), TraceSerializerOptions);
            Assert.IsNotNull(report);
            Assert.AreEqual(1, report.IncidentCount);
            Assert.AreEqual("INC-TASK-B", report.Incidents[0].IncidentId);
        }

        // Test requesting missing incident fails closed
        using (var output = new StringWriter())
        using (var error = new StringWriter())
        {
            var exitCode = ComplianceReviewRuntimeTraceCommand.Run(
                ["trace-compliance-review", "--database", databasePath, "--report", reportPath, "--incident", "INC-NONEXISTENT"],
                output,
                error);
            Assert.AreEqual(ComplianceReviewRuntimeTraceCommand.RuntimeFailureExitCode, exitCode);
            StringAssert.Contains(error.ToString(), "was not found in the database");
        }
    }

    [TestMethod]
    public void BrokenAuditChainFailsClosed()
    {
        using var directory = new TemporaryDirectory();
        var databasePath = Path.Combine(directory.Path, "herdrops.db");
        var reportPath = Path.Combine(directory.Path, "trace-report.json");
        var options = new HerdrStateStoreOptions(databasePath);

        using (var store = new SqliteHerdrStateStore(options, new FixedTimeProvider(ObservedUtc)))
        {
            var lifecycle = new AssignmentLifecycleReducer();
            var pmAuthority = SeedAuthority(
                store,
                lifecycle,
                "project-manager",
                "Project Manager",
                ComplianceReviewerRole.ProjectManager,
                Guid.Parse("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"),
                sequence: 1);

            var evidence = CaptureEvidence(store, directory, "ev.bin");
            store.RegisterComplianceReviewIncident(new ComplianceReviewIncidentRegistration(
                ComplianceReviewWorkflowContract.ContractVersion,
                "INC-TAMPER",
                "TASK-115",
                "worker-01",
                ObservedUtc.AddMinutes(1),
                [evidence]));

            store.ApplyComplianceReviewCommand(
                new ComplianceReviewCommand(
                    ComplianceReviewWorkflowContract.ContractVersion,
                    Guid.Parse("33333333-3333-3333-3333-333333333333"),
                    "INC-TAMPER",
                    ComplianceReviewState.Suspected,
                    0,
                    "project-manager",
                    ComplianceReviewDecisionKind.Confirm,
                    "Confirmed decision.",
                    ObservedUtc.AddMinutes(2),
                    []),
                pmAuthority);
        }

        // Tamper audit_sha256 in compliance_review_events directly
        using (var connection = new SqliteConnection(new SqliteConnectionStringBuilder
        {
            DataSource = databasePath,
            Pooling = false,
        }.ToString()))
        {
            connection.Open();
            using var command = connection.CreateCommand();
            command.CommandText = """
                DROP TRIGGER compliance_review_events_reject_update;
                UPDATE compliance_review_events
                SET audit_sha256 = '0000000000000000000000000000000000000000000000000000000000000000'
                WHERE incident_id = 'INC-TAMPER';
                """;
            command.ExecuteNonQuery();
        }

        using var output = new StringWriter();
        using var error = new StringWriter();

        var exitCode = ComplianceReviewRuntimeTraceCommand.Run(
            ["trace-compliance-review", "--database", databasePath, "--report", reportPath],
            output,
            error);

        Assert.AreEqual(ComplianceReviewRuntimeTraceCommand.RuntimeFailureExitCode, exitCode);
        StringAssert.Contains(error.ToString(), "failed");
    }

    [TestMethod]
    public void UnsupportedOldSchemaVersionFailsClosed()
    {
        using var directory = new TemporaryDirectory();
        var databasePath = Path.Combine(directory.Path, "v3_only.db");
        var reportPath = Path.Combine(directory.Path, "trace-report.json");

        // Manually create schema v3 only
        using (var connection = new SqliteConnection(new SqliteConnectionStringBuilder
        {
            DataSource = databasePath,
            Pooling = false,
        }.ToString()))
        {
            connection.Open();
            for (var version = 1; version <= 3; version++)
            {
                var migration = SqliteHerdrStateStore.GetMigrationForTesting(version);
                using var command = connection.CreateCommand();
                command.CommandText = migration.Sql;
                command.ExecuteNonQuery();
            }

            using var versionCommand = connection.CreateCommand();
            versionCommand.CommandText = "PRAGMA user_version = 3;";
            versionCommand.ExecuteNonQuery();
        }

        using var output = new StringWriter();
        using var error = new StringWriter();

        var exitCode = ComplianceReviewRuntimeTraceCommand.Run(
            ["trace-compliance-review", "--database", databasePath, "--report", reportPath],
            output,
            error);

        Assert.AreEqual(ComplianceReviewRuntimeTraceCommand.RuntimeFailureExitCode, exitCode);
        StringAssert.Contains(error.ToString(), "unsupported");
    }

    [TestMethod]
    public void EmptyDatabaseFileFailsClosed()
    {
        using var directory = new TemporaryDirectory();
        var databasePath = Path.Combine(directory.Path, "empty.db");
        var reportPath = Path.Combine(directory.Path, "trace-report.json");
        File.WriteAllBytes(databasePath, []);

        using var output = new StringWriter();
        using var error = new StringWriter();

        var exitCode = ComplianceReviewRuntimeTraceCommand.Run(
            ["trace-compliance-review", "--database", databasePath, "--report", reportPath],
            output,
            error);

        Assert.AreEqual(ComplianceReviewRuntimeTraceCommand.RuntimeFailureExitCode, exitCode);
        StringAssert.Contains(error.ToString(), "is empty");
    }

    [TestMethod]
    public void SensitiveCredentialsInAuditReasonAreRedactedInOutputReport()
    {
        using var directory = new TemporaryDirectory();
        var databasePath = Path.Combine(directory.Path, "herdrops.db");
        var reportPath = Path.Combine(directory.Path, "trace-report.json");
        var options = new HerdrStateStoreOptions(databasePath);

        const string secretToken = "ghp_123456789012345678901234567890123456";

        using (var store = new SqliteHerdrStateStore(options, new FixedTimeProvider(ObservedUtc)))
        {
            var lifecycle = new AssignmentLifecycleReducer();
            var pmAuthority = SeedAuthority(
                store,
                lifecycle,
                "project-manager",
                "Project Manager",
                ComplianceReviewerRole.ProjectManager,
                Guid.Parse("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"),
                sequence: 1);

            var evidence = CaptureEvidence(store, directory, "ev.bin");
            store.RegisterComplianceReviewIncident(new ComplianceReviewIncidentRegistration(
                ComplianceReviewWorkflowContract.ContractVersion,
                "INC-SECRET",
                "TASK-115",
                "worker-01",
                ObservedUtc.AddMinutes(1),
                [evidence]));

            store.ApplyComplianceReviewCommand(
                new ComplianceReviewCommand(
                    ComplianceReviewWorkflowContract.ContractVersion,
                    Guid.Parse("44444444-4444-4444-4444-444444444444"),
                    "INC-SECRET",
                    ComplianceReviewState.Suspected,
                    0,
                    "project-manager",
                    ComplianceReviewDecisionKind.Confirm,
                    $"Confirmed leak of secret token {secretToken} during audit.",
                    ObservedUtc.AddMinutes(2),
                    []),
                pmAuthority);
        }

        using var output = new StringWriter();
        using var error = new StringWriter();

        var exitCode = ComplianceReviewRuntimeTraceCommand.Run(
            ["trace-compliance-review", "--database", databasePath, "--report", reportPath],
            output,
            error);

        Assert.AreEqual(ComplianceReviewRuntimeTraceCommand.SuccessExitCode, exitCode);
        var reportContent = File.ReadAllText(reportPath);
        Assert.IsFalse(reportContent.Contains(secretToken, StringComparison.Ordinal));
        StringAssert.Contains(reportContent, "[REDACTED]");
    }

    private static string CaptureEvidence(
        SqliteHerdrStateStore store,
        TemporaryDirectory directory,
        string fileName)
    {
        var artifactPath = Path.Combine(directory.Path, "source", fileName);
        Directory.CreateDirectory(Path.GetDirectoryName(artifactPath)!);
        File.WriteAllBytes(artifactPath, Encoding.UTF8.GetBytes($"content-{fileName}"));
        var capture = store.CaptureEvidence(
            new EvidenceCaptureRequest(
                EvidenceMetadataContract.ContractVersion,
                "TASK-115",
                "worker-01",
                $"EVENT-{fileName}",
                "integration-test",
                $"redacted://evidence/{fileName}",
                ObservedUtc,
                ObservedUtc.AddSeconds(1),
                ObservedUtc.AddDays(30),
                CreateManagedCopy: true),
            artifactPath);
        return capture.StoredEvidence.Metadata.EvidenceIdentitySha256;
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
}
