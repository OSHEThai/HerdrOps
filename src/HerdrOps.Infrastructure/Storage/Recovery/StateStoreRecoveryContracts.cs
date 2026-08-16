using System.Security.Cryptography;
using System.Text;
using System.Globalization;
using HerdrOps.Domain.Diagnostics;

namespace HerdrOps.Infrastructure.Storage.Recovery;

internal enum StateStoreRecoveryPhase
{
    BeforeBackup,
    AfterBackup,
    BeforeMigration,
    AfterBackupTemporaryCreated,
    AfterMigrationBeforeCommit,
    AfterMigrationCommit,
    BeforeRollback,
    AfterRestoreReplacement,
    AfterRollback,
    AfterOwnershipLock,
    AfterDatabaseLeafInspection,
    BeforeRestoreRollback,
    AfterRestoreRollbackOperation,
    AfterTraceTemporaryCreated,
    BeforeQuarantineMove,
}

internal sealed record StateStoreRecoveryPhaseContext(
    StateStoreRecoveryPhase Phase,
    int FromSchemaVersion,
    int? TargetSchemaVersion,
    string? ArtifactPath);

internal interface IStateStoreRecoveryFaultInjector
{
    void OnPhase(StateStoreRecoveryPhaseContext context);
}

internal interface IStateStoreRecoveryCleanup
{
    void DeleteFile(string path);

    void DeleteDirectoryTree(string path);
}

internal sealed class FileSystemStateStoreRecoveryCleanup : IStateStoreRecoveryCleanup
{
    public static FileSystemStateStoreRecoveryCleanup Instance { get; } = new();

    public void DeleteFile(string path)
    {
        try
        {
            File.Delete(path);
        }
        catch (FileNotFoundException)
        {
        }
        catch (DirectoryNotFoundException)
        {
        }
    }

    public void DeleteDirectoryTree(string path)
    {
        try
        {
            Directory.Delete(path, recursive: true);
        }
        catch (DirectoryNotFoundException)
        {
        }
    }
}

internal sealed class NoopStateStoreRecoveryFaultInjector : IStateStoreRecoveryFaultInjector
{
    public static NoopStateStoreRecoveryFaultInjector Instance { get; } = new();

    public void OnPhase(StateStoreRecoveryPhaseContext context)
    {
    }
}

internal sealed class DelegateStateStoreRecoveryFaultInjector(
    Action<StateStoreRecoveryPhaseContext> callback) : IStateStoreRecoveryFaultInjector
{
    private readonly Action<StateStoreRecoveryPhaseContext> _callback =
        callback ?? throw new ArgumentNullException(nameof(callback));

    public void OnPhase(StateStoreRecoveryPhaseContext context) => _callback(context);
}

internal sealed record StateStoreRecoveryOptions(
    IStateStoreRecoveryFaultInjector? FaultInjector = null,
    Func<Guid>? GuidFactory = null,
    IStateStoreRecoveryCleanup? Cleanup = null)
{
    public IStateStoreRecoveryFaultInjector EffectiveFaultInjector =>
        FaultInjector ?? NoopStateStoreRecoveryFaultInjector.Instance;

    public Func<Guid> EffectiveGuidFactory =>
        GuidFactory ?? Guid.NewGuid;

    public IStateStoreRecoveryCleanup EffectiveCleanup =>
        Cleanup ?? FileSystemStateStoreRecoveryCleanup.Instance;
}

internal sealed class StateStoreRecoveryInterruptionException : IOException
{
    public StateStoreRecoveryInterruptionException(StateStoreRecoveryPhaseContext context)
        : base(
            $"Fault-injected state-store recovery interruption at phase '{context.Phase}' " +
            $"from schema v{context.FromSchemaVersion} " +
            $"to '{context.TargetSchemaVersion?.ToString() ?? "none"}'.")
    {
        Context = context;
    }

    public StateStoreRecoveryPhaseContext Context { get; }
}

internal sealed class StateStoreCorruptionException : IOException
{
    public StateStoreCorruptionException(string message)
        : base(message)
    {
    }

    public StateStoreCorruptionException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}

internal sealed record StateStoreRecoveryFileIdentity(
    string FileName,
    long Length,
    string Sha256);

internal sealed record StateStoreRecoveryTrace(
    int ContractVersion,
    string Operation,
    string Outcome,
    string EvidenceClassification,
    string[] EvidenceClasses,
    string ActualHerdrRuntime,
    string Release,
    string DatabaseFileName,
    int? FromSchemaVersion,
    int? ToSchemaVersion,
    StateStoreRecoveryFileIdentity? Primary,
    StateStoreRecoveryFileIdentity? Backup,
    StateStoreRecoveryFileIdentity[]? Sidecars,
    string? QuarantineDirectory,
    string? Phase,
    string? FailureType,
    string? FailureMessage,
    string ObservedUtc);

internal sealed record StateStoreRecoveryBackupResult(
    string BackupPath,
    string TracePath,
    StateStoreRecoveryFileIdentity BackupIdentity);

internal sealed record StateStoreRecoveryRestoreResult(
    string DatabasePath,
    string BackupPath,
    string TracePath,
    string? PriorDatabasePath,
    StateStoreRecoveryFileIdentity RestoredIdentity);

internal static class StateStoreRecoveryDiagnostics
{
    private const int MaximumSafeMessageUtf8Bytes = 16 * 1024;
    private const int MaximumHashMaterialCharacters = 8 * 1024;
    private const int MaximumCleanupContextUtf8Bytes = 16 * 1024;
    private static readonly DiagnosticTextRedactor Redactor = new(
        new DiagnosticRedactionOptions
        {
            MaximumInputUtf8Bytes = 64 * 1024,
            MaximumStringUtf8Bytes = MaximumSafeMessageUtf8Bytes,
            MaximumCrashMessageUtf8Bytes = MaximumSafeMessageUtf8Bytes,
            MaximumCrashStackUtf8Bytes = MaximumSafeMessageUtf8Bytes,
        });

    public static string SanitizeMessage(string? message)
    {
        if (string.IsNullOrWhiteSpace(message))
        {
            return "[RECOVERY_MESSAGE_EMPTY]";
        }

        if (Encoding.UTF8.GetByteCount(message) > MaximumSafeMessageUtf8Bytes)
        {
            return "[RECOVERY_MESSAGE_OMITTED:" + HashToken(message) + "]";
        }

        try
        {
            return Redactor.Redact(message, MaximumSafeMessageUtf8Bytes).Text;
        }
        catch (Exception)
        {
            return "[RECOVERY_MESSAGE_OMITTED:" + HashToken(message) + "]";
        }
    }

    public static string TokenizePath(string path) =>
        "[RECOVERY_PATH:" + HashToken(path) + "]";

    public static string TokenizeArtifactName(string name) =>
        "[RECOVERY_ARTIFACT:" + HashToken(name) + "]";

    public static StateStoreRecoveryFileIdentity SafeIdentity(
        StateStoreRecoveryFileIdentity identity) =>
        identity with { FileName = TokenizeArtifactName(identity.FileName) };

    public static void AttachCleanupFailure(
        Exception primary,
        string operation,
        string path,
        Exception cleanupFailure)
    {
        AppendFailureContext(
            primary,
            "HerdrOps.RecoveryCleanupFailures",
            "HerdrOps.RecoveryCleanupFailure",
            operation,
            path,
            cleanupFailure);
        primary.Data["HerdrOps.RecoveryCleanupEvidence"] =
            "Primary exception retained; cleanup failure prevented removal of one or more recovery artifacts.";
    }

    public static void AttachRollbackStateFailure(
        Exception primary,
        string path,
        Exception rollbackStateFailure)
    {
        AppendFailureContext(
            primary,
            "HerdrOps.RecoveryRollbackStateFailures",
            "HerdrOps.RecoveryRollbackStateFailure",
            "restore-rollback-state",
            path,
            rollbackStateFailure);
        primary.Data["HerdrOps.RecoveryRollbackStateEvidence"] =
            "The original destination identity or absence could not be proven after rollback.";
    }

    private static void AppendFailureContext(
        Exception primary,
        string collectionKey,
        string summaryKey,
        string operation,
        string path,
        Exception failure)
    {
        var entry = BoundFailureContext(
            operation + ":" + TokenizePath(path) + ":" + SanitizeMessage(failure.Message));
        var existing = primary.Data[collectionKey] switch
        {
            string[] entries => entries,
            string entryValue => new[] { entryValue },
            _ => Array.Empty<string>(),
        };
        var updated = new string[existing.Length + 1];
        Array.Copy(existing, updated, existing.Length);
        updated[^1] = entry;
        primary.Data[collectionKey] = updated;

        var combined = string.Join(" | ", updated);
        primary.Data[summaryKey] =
            Encoding.UTF8.GetByteCount(combined) <= MaximumCleanupContextUtf8Bytes
                ? combined
                : "[RECOVERY_CLEANUP_CONTEXT_OMITTED:" + HashToken(combined) + "]";
    }

    private static string BoundFailureContext(string value) =>
        Encoding.UTF8.GetByteCount(value) <= MaximumCleanupContextUtf8Bytes
            ? value
            : "[RECOVERY_CLEANUP_CONTEXT_OMITTED:" + HashToken(value) + "]";

    private static string HashToken(string value)
    {
        var materialLength = Math.Min(value.Length, MaximumHashMaterialCharacters);
        var normalized = value[..materialLength]
            .Replace('\\', '/')
            .ToUpperInvariant();
        if (value.Length > materialLength)
        {
            normalized += "|TRUNCATED|" + value.Length.ToString(CultureInfo.InvariantCulture);
        }

        var hash = SHA256.HashData(Encoding.UTF8.GetBytes(normalized));
        return Convert.ToHexString(hash.AsSpan(0, 12));
    }
}
