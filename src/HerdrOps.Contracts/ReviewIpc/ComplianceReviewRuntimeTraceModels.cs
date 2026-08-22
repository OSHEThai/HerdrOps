namespace HerdrOps.Contracts.ReviewIpc;

/// <summary>
/// Defines immutable protocol constants and limits for compliance review runtime traces.
/// </summary>
public static class ComplianceReviewRuntimeTraceContract
{
    public const int Version = 1;
    public const string BuiltProcessIntegrationEvidence = "BuiltProcessIntegration";
    public const string SyntheticEvidence = "Synthetic plus local SQLite integration";
    public const string ActualRuntimeEvidence = "Actual role-distinct Herdr runtime";
    public const string ProducerProcessIdProvenanceText =
        "This process ID identifies the HerdrOps compliance-review trace producer/exporter process. It is not a Herdr process ID.";
    public const string EvidenceBoundaryText =
        "This trace proves local durable SQLite schema v4 compliance review records, audit trail integrity, authority provenance, evidence links, and retention protection observations. It does not by itself prove that reviewer identities were actual running Herdr Agents, UI rendering, or release readiness.";

    public const int MaximumIncidents = 4096;
    public const int MaximumAuditEvents = 8192;
    public const int MaximumEvidenceLinks = 16384;
    public const int MaximumReportBytes = 4 * 1024 * 1024;
    public const string RedactedMachineValue = "[REDACTED]";
}

/// <summary>
/// Records a point-in-time retention protection observation for one evidence identity referenced in a compliance review.
/// </summary>
public sealed record ComplianceReviewEvidenceRetentionObservation(
    string EvidenceIdentitySha256,
    IReadOnlyList<string> ReferencingIncidentIds,
    bool HasOpenIncident,
    bool HasTerminalIncident,
    bool IsProtectedFromPurge,
    string? StorageKind,
    string? Availability,
    DateTimeOffset? RetainUntilUtc,
    bool RetentionEventRecorded,
    int? RetentionOutcome,
    DateTimeOffset? RetentionOccurredUtc);

/// <summary>
/// Top-level fail-closed compliance-review trace report emitted from durable SQLite state.
/// The report is non-runtime evidence unless an independent runtime gate supplies a separate accepted observation.
/// </summary>
/// <param name="DatabaseFileSha256">
/// SHA-256 of the transaction-bound serialized SQLite snapshot that supplied the report rows.
/// </param>
/// <param name="ProducerProcessId">
/// PID of the HerdrOps process producing/exporting this report; never a Herdr server or Agent PID.
/// </param>
public sealed record ComplianceReviewRuntimeTraceReport(
    int ContractVersion,
    string EvidenceClassification,
    bool RuntimeObserved,
    bool SessionControlInvoked,
    bool RestartObserved,
    bool ReconnectObserved,
    bool DurableReviewEnabled,
    bool RetentionProtectedObserved,
    bool RestartConsistencyObserved,
    string DatabasePath,
    string DatabaseFileSha256,
    long DatabaseFileSizeBytes,
    int SchemaVersion,
    string ProductAssemblySha256,
    string HostName,
    string OperatingSystem,
    int ProducerProcessId,
    DateTimeOffset StartedUtc,
    DateTimeOffset FinishedUtc,
    int IncidentCount,
    int AuditEventCount,
    int EvidenceLinkCount,
    IReadOnlyList<HerdrOpsComplianceReviewIncident> Incidents,
    IReadOnlyList<HerdrOpsComplianceReviewAuditEvent> AuditEvents,
    IReadOnlyList<ComplianceReviewEvidenceRetentionObservation> RetentionObservations,
    string EvidenceBoundary);
