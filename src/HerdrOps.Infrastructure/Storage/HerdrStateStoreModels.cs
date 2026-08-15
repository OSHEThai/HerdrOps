using HerdrOps.Contracts.StateIpc;
using HerdrOps.Domain.Assignments;

namespace HerdrOps.Infrastructure.Storage;

public sealed record HerdrStateStoreOptions(
    string DatabasePath,
    int BusyTimeoutSeconds = 5)
{
    public const int CurrentSchemaVersion = 2;

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
