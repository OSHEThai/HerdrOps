using System.Text.Json;
using System.Text.Json.Serialization;
using HerdrOps.Contracts.ReviewIpc;

namespace HerdrOps.ContractTests;

[TestClass]
public sealed class ComplianceReviewRuntimeTraceContractTests
{
    private static readonly DateTimeOffset BaseUtc =
        new(2026, 8, 20, 12, 0, 0, TimeSpan.Zero);

    private static readonly JsonSerializerOptions SerializerOptions = new(JsonSerializerDefaults.Web)
    {
        AllowTrailingCommas = false,
        MaxDepth = 64,
        PropertyNameCaseInsensitive = false,
        ReadCommentHandling = JsonCommentHandling.Disallow,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter() },
    };

    [TestMethod]
    public void ContractConstantsAndEvidenceBoundaryAreExact()
    {
        var boundaryField = typeof(ComplianceReviewRuntimeTraceContract).GetField(
            nameof(ComplianceReviewRuntimeTraceContract.EvidenceBoundaryText));
        Assert.IsNotNull(boundaryField);
        Assert.AreEqual(
            "This trace proves local durable SQLite schema v4 compliance review records, audit trail integrity, authority provenance, evidence links, and retention protection observations. It does not by itself prove that reviewer identities were actual running Herdr Agents, UI rendering, or release readiness.",
            boundaryField.GetRawConstantValue());
        var provenanceField = typeof(ComplianceReviewRuntimeTraceContract).GetField(
            nameof(ComplianceReviewRuntimeTraceContract.ProducerProcessIdProvenanceText));
        Assert.IsNotNull(provenanceField);
        Assert.AreEqual(
            "This process ID identifies the HerdrOps compliance-review trace producer/exporter process. It is not a Herdr process ID.",
            provenanceField.GetRawConstantValue());
    }

    [TestMethod]
    public void ReportRoundTripsThroughJsonWithDeterministicContent()
    {
        var incident = new HerdrOpsComplianceReviewIncident(
            ContractVersion: 1,
            IncidentId: "INC-28-01",
            TaskId: "TASK-115",
            SubjectActorId: "worker-01",
            RegisteredUtc: BaseUtc,
            InitialEvidenceIdentitySha256s: [new string('A', 64)],
            RegistrationSha256: new string('B', 64),
            State: 1,
            Sequence: 0,
            UpdatedUtc: BaseUtc,
            LastAuditEventId: null,
            LastAuditSha256: null);

        var auditEvent = new HerdrOpsComplianceReviewAuditEvent(
            ContractVersion: 1,
            AuditEventId: Guid.Parse("11111111-1111-1111-1111-111111111111"),
            IncidentId: "INC-28-01",
            TaskId: "TASK-115",
            SubjectActorId: "worker-01",
            Sequence: 1,
            ReviewerActorId: "project-manager",
            ReviewerRole: 1,
            AuthorityProvenanceEventId: Guid.Parse("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"),
            AuthorityProvenanceSequence: 1,
            AuthorityProvenanceSha256: new string('C', 64),
            DecisionKind: 2,
            PreviousState: 1,
            ResultState: 2,
            Reason: "Send to leader for investigation.",
            OccurredUtc: BaseUtc.AddMinutes(2),
            EvidenceIdentitySha256s: [new string('A', 64), new string('D', 64)],
            EvidenceSetSha256: new string('E', 64),
            PreviousAuditSha256: null,
            AuditSha256: new string('F', 64));

        var observation = new ComplianceReviewEvidenceRetentionObservation(
            EvidenceIdentitySha256: new string('A', 64),
            ReferencingIncidentIds: ["INC-28-01"],
            HasOpenIncident: true,
            HasTerminalIncident: false,
            IsProtectedFromPurge: true,
            StorageKind: "ManagedObject",
            Availability: "Present",
            RetainUntilUtc: BaseUtc.AddDays(30),
            RetentionEventRecorded: false,
            RetentionOutcome: null,
            RetentionOccurredUtc: null);

        var report = new ComplianceReviewRuntimeTraceReport(
            ContractVersion: 1,
            EvidenceClassification: ComplianceReviewRuntimeTraceContract.BuiltProcessIntegrationEvidence,
            RuntimeObserved: true,
            SessionControlInvoked: false,
            RestartObserved: false,
            ReconnectObserved: false,
            DurableReviewEnabled: true,
            RetentionProtectedObserved: true,
            RestartConsistencyObserved: true,
            DatabasePath: "C:\\data\\herdrops.db",
            DatabaseFileSha256: new string('1', 64),
            DatabaseFileSizeBytes: 123456,
            SchemaVersion: 4,
            ProductAssemblySha256: new string('2', 64),
            HostName: "TEST-HOST",
            OperatingSystem: "Windows 11",
            ProducerProcessId: 4321,
            StartedUtc: BaseUtc,
            FinishedUtc: BaseUtc.AddSeconds(1),
            IncidentCount: 1,
            AuditEventCount: 1,
            EvidenceLinkCount: 2,
            Incidents: [incident],
            AuditEvents: [auditEvent],
            RetentionObservations: [observation],
            EvidenceBoundary: ComplianceReviewRuntimeTraceContract.EvidenceBoundaryText);

        var json = JsonSerializer.Serialize(report, SerializerOptions);
        var restored = JsonSerializer.Deserialize<ComplianceReviewRuntimeTraceReport>(json, SerializerOptions);

        Assert.IsNotNull(restored);
        Assert.AreEqual(1, restored.ContractVersion);
        Assert.AreEqual(ComplianceReviewRuntimeTraceContract.BuiltProcessIntegrationEvidence, restored.EvidenceClassification);
        Assert.IsTrue(restored.RuntimeObserved);
        Assert.IsFalse(restored.SessionControlInvoked);
        Assert.AreEqual(4321, restored.ProducerProcessId);
        StringAssert.Contains(json, "\"producerProcessId\"");
        Assert.IsFalse(json.Contains("\"processId\"", StringComparison.Ordinal));
        Assert.AreEqual("INC-28-01", restored.Incidents[0].IncidentId);
        Assert.AreEqual(Guid.Parse("11111111-1111-1111-1111-111111111111"), restored.AuditEvents[0].AuditEventId);
        Assert.IsTrue(restored.RetentionObservations[0].IsProtectedFromPurge);
        Assert.AreEqual(1, restored.IncidentCount);
        Assert.AreEqual(1, restored.AuditEventCount);
        Assert.IsTrue(restored.DurableReviewEnabled);
        Assert.IsTrue(restored.RetentionProtectedObserved);
        Assert.IsTrue(restored.RestartConsistencyObserved);
        StringAssert.Contains(json, "\"durableReviewEnabled\"");
        StringAssert.Contains(json, "\"retentionProtectedObserved\"");
        StringAssert.Contains(json, "\"restartConsistencyObserved\"");
    }
}
