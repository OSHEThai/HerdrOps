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
/// Top-level fail-closed runtime trace report emitted from durable SQLite compliance review state.
/// </summary>
public sealed record ComplianceReviewRuntimeTraceReport(
    int ContractVersion,
    string EvidenceClassification,
    bool RuntimeObserved,
    bool SessionControlInvoked,
    bool RestartObserved,
    bool ReconnectObserved,
    string DatabasePath,
    string DatabaseFileSha256,
    long DatabaseFileSizeBytes,
    int SchemaVersion,
    string ProductAssemblySha256,
    string HostName,
    string OperatingSystem,
    int ProcessId,
    DateTimeOffset StartedUtc,
    DateTimeOffset FinishedUtc,
    int IncidentCount,
    int AuditEventCount,
    int EvidenceLinkCount,
    IReadOnlyList<HerdrOpsComplianceReviewIncident> Incidents,
    IReadOnlyList<HerdrOpsComplianceReviewAuditEvent> AuditEvents,
    IReadOnlyList<ComplianceReviewEvidenceRetentionObservation> RetentionObservations,
    string EvidenceBoundary);
