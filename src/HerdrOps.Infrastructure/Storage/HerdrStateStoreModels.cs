using HerdrOps.Contracts.StateIpc;
using HerdrOps.Domain.Assignments;
using HerdrOps.Domain.Evidence;

namespace HerdrOps.Infrastructure.Storage;

public sealed record HerdrStateStoreOptions(
    string DatabasePath,
    int BusyTimeoutSeconds = 5,
    string? ManagedEvidenceRootPath = null)
{
    public const int CurrentSchemaVersion = 4;

    public static HerdrStateStoreOptions ForCurrentUser()
    {
        var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        if (string.IsNullOrWhiteSpace(localAppData))
        {
            throw new HerdrStateStoreException(
                "The current user's local application-data directory is unavailable.");
        }

        return new HerdrStateStoreOptions(
            Path.Combine(localAppData, "HerdrOps", "state", "herdrops.db"));
    }
}

public sealed record HerdrStateStoreCommit(
    HerdrSessionStateContract State,
    DateTimeOffset ObservedUtc,
    DateTimeOffset IngestedUtc,
    string Source,
    string EventType,
    Guid CorrelationId,
    string PayloadJson);

public sealed record HerdrStoredState(
    HerdrSessionStateContract State,
    DateTimeOffset ObservedUtc,
    DateTimeOffset IngestedUtc,
    string Source,
    string StateSha256);

public sealed record HerdrStateStoreWriteResult(
    HerdrStoredState StoredState,
    bool WasAlreadyPresent);

public sealed record HerdrStateStoreDiagnostics(
    int SchemaVersion,
    string JournalMode,
    int SynchronousMode,
    bool ForeignKeysEnabled,
    string IntegrityResult,
    long EventCount,
    long LifecycleEventCount,
    long AssignmentTaskCount,
    long AssignmentRelationshipCount,
    long OrphanLifecycleEventCount,
    long DuplicateHandoffCount,
    string? LastBackupPath);

public sealed record HerdrStoredAssignmentLifecycleEvent(
    NormalizedAssignmentLifecycleEvent NormalizedEvent,
    AssignmentLifecycleAuditEntry Audit,
    string EventJsonSha256);

public sealed record HerdrAssignmentLifecycleWriteResult(
    HerdrStoredAssignmentLifecycleEvent StoredEvent,
    bool WasAlreadyPresent);

public sealed record HerdrStoredEvidence(
    EvidenceMetadata Metadata,
    bool ManagedBytesAvailable,
    bool RetentionCompleted);

public sealed record HerdrEvidenceWriteResult(
    HerdrStoredEvidence StoredEvidence,
    bool WasAlreadyPresent);

public sealed record HerdrReviewAuditWriteResult(
    ReviewAuditEvent StoredEvent,
    bool WasAlreadyPresent);

public sealed record HerdrComplianceReviewRegistrationResult(
    HerdrOps.Domain.Compliance.ComplianceReviewIncident Incident,
    bool WasAlreadyPresent);

public sealed record HerdrComplianceReviewWriteResult(
    HerdrOps.Domain.Compliance.ComplianceReviewIncident Incident,
    HerdrOps.Domain.Compliance.ComplianceReviewAuditEvent AuditEvent,
    bool WasAlreadyPresent);

public sealed record HerdrComplianceReviewCapabilities(
    HerdrOps.Domain.Compliance.ComplianceReviewIncident? Incident,
    HerdrOps.Domain.Compliance.ComplianceReviewerRole? ReviewerRole,
    IReadOnlyList<HerdrOps.Domain.Compliance.ComplianceReviewDecisionKind> AllowedDecisions);

public enum HerdrEvidenceRetentionOutcome
{
    Purged = 1,
    AlreadyMissing = 2,
    ProtectedByOpenReview = 3,
}

public sealed record HerdrEvidenceRetentionResult(
    string EvidenceIdentitySha256,
    HerdrEvidenceRetentionOutcome Outcome,
    DateTimeOffset EvaluatedUtc,
    Guid? RetentionEventId,
    string? RetentionAuditSha256);

public sealed record HerdrEvidenceRetentionAuditEvent(
    Guid RetentionEventId,
    string EvidenceIdentitySha256,
    DateTimeOffset OccurredUtc,
    HerdrEvidenceRetentionOutcome Outcome,
    string ManagedRelativePath,
    long ExpectedContentLength,
    string ExpectedContentSha256,
    string RetentionAuditSha256);

public sealed record HerdrEvidenceRetentionBatchResult(
    DateTimeOffset AsOfUtc,
    IReadOnlyList<HerdrEvidenceRetentionResult> Results);

public sealed class HerdrStateStoreException : IOException
{
    public HerdrStateStoreException(string message)
        : base(message)
    {
    }

    public HerdrStateStoreException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}
