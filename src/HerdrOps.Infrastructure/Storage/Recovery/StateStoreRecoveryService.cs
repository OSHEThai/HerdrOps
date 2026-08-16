using System.Text.RegularExpressions;

namespace HerdrOps.Infrastructure.Storage.Recovery;

public static class StateStoreRestoreContract
{
    public const string ConfirmationPhrase = "RESTORE_STATE_STORE";
    public const string AbsentDestinationIdentity = "ABSENT";
}

public sealed record StateStoreRestoreRequest(
    string DatabasePath,
    string BackupPath,
    string ExpectedBackupSha256,
    string ExpectedDatabaseSha256,
    string Confirmation);

public sealed record StateStoreRestoreReport(
    string DatabasePathToken,
    string BackupPathToken,
    string ExpectedBackupSha256,
    string ObservedBackupSha256,
    string ExpectedDatabaseSha256,
    string ObservedDatabaseSha256,
    bool DestinationWasPresent,
    string TracePathToken,
    string? PriorDatabasePathToken,
    string EvidenceClassification,
    string ActualHerdrRuntime,
    string Release);

public sealed class StateStoreRestoreRejectedException : IOException
{
    public StateStoreRestoreRejectedException(string message, Exception? innerException = null)
        : base(message, innerException)
    {
    }
}

/// <summary>
/// Provides the explicit, fail-closed state-store restore operation. It never chooses a
/// backup automatically and never initializes or resets a database as a side effect.
/// </summary>
public sealed class StateStoreRecoveryService
{
    private static readonly Regex Sha256Pattern = new(
        "^[0-9A-Fa-f]{64}$",
        RegexOptions.Compiled | RegexOptions.CultureInvariant | RegexOptions.NonBacktracking);

    public StateStoreRestoreReport Restore(
        StateStoreRestoreRequest request,
        TimeProvider? timeProvider = null)
    {
        ArgumentNullException.ThrowIfNull(request);

        try
        {
            if (!string.Equals(
                    request.Confirmation,
                    StateStoreRestoreContract.ConfirmationPhrase,
                    StringComparison.Ordinal))
            {
                throw new StateStoreRestoreRejectedException(
                    "Explicit restore confirmation is required.");
            }

            var databasePath = StateStoreRecoveryPathPolicy.NormalizeDatabasePath(request.DatabasePath);
            var backupPath = StateStoreRecoveryPathPolicy.NormalizeDatabasePath(request.BackupPath);
            if (string.Equals(databasePath, backupPath, StringComparison.OrdinalIgnoreCase))
            {
                throw new StateStoreRestoreRejectedException(
                    "The restore source and destination must be different files.");
            }

            var expectedBackupSha256 = NormalizeSha256(request.ExpectedBackupSha256, "source");
            var expectedDatabaseSha256 = NormalizeDestinationIdentity(request.ExpectedDatabaseSha256);
            var parent = Path.GetDirectoryName(databasePath)!;
            var backupDirectory = Path.Combine(parent, "backups");
            if (!Directory.Exists(parent))
            {
                throw new StateStoreRestoreRejectedException(
                    "The explicit restore destination parent does not exist.");
            }

            StateStoreRecoveryPathPolicy.EnsureNoReparseComponents(parent, includeLeaf: true);
            StateStoreRecoveryPathPolicy.EnsureContainedPath(backupDirectory, backupPath);
            var backupParent = Path.GetDirectoryName(backupPath)!;
            if (!string.Equals(
                    Path.TrimEndingDirectorySeparator(backupParent),
                    Path.TrimEndingDirectorySeparator(backupDirectory),
                    StringComparison.OrdinalIgnoreCase))
            {
                throw new StateStoreRestoreRejectedException(
                    "The restore source must be a direct child of the database backups directory.");
            }

            var sourceIdentity = StateStoreRecoveryArtifacts.IdentifyFile(backupPath);
            RequireHashMatch(
                "source",
                expectedBackupSha256,
                sourceIdentity.Sha256);
            var destinationWasPresent = ValidateDestinationIdentity(
                databasePath,
                expectedDatabaseSha256,
                out var destinationIdentity);

            using var ownershipLease = AcquireOwnershipLease(databasePath);

            sourceIdentity = StateStoreRecoveryArtifacts.IdentifyFile(backupPath);
            RequireHashMatch(
                "source",
                expectedBackupSha256,
                sourceIdentity.Sha256);
            var destinationAfterLockWasPresent = ValidateDestinationIdentity(
                databasePath,
                expectedDatabaseSha256,
                out var destinationAfterLockIdentity);
            if (destinationAfterLockWasPresent != destinationWasPresent ||
                !AreSameIdentity(destinationIdentity, destinationAfterLockIdentity))
            {
                throw new StateStoreRestoreRejectedException(
                    "The destination identity changed before restore; no file was replaced.");
            }

            var restored = StateStoreRecoveryArtifacts.RestoreBackup(
                databasePath,
                backupPath,
                expectedBackupSha256,
                destinationAfterLockIdentity,
                timeProvider ?? TimeProvider.System,
                new StateStoreRecoveryOptions());
            var restoredIdentity = StateStoreRecoveryArtifacts.IdentifyFile(databasePath);
            RequireHashMatch(
                "restored destination",
                expectedBackupSha256,
                restoredIdentity.Sha256);
            var sourceAfterRestore = StateStoreRecoveryArtifacts.IdentifyFile(backupPath);
            RequireHashMatch(
                "source",
                expectedBackupSha256,
                sourceAfterRestore.Sha256);

            return new StateStoreRestoreReport(
                StateStoreRecoveryDiagnostics.TokenizePath(databasePath),
                StateStoreRecoveryDiagnostics.TokenizePath(backupPath),
                expectedBackupSha256,
                sourceAfterRestore.Sha256,
                expectedDatabaseSha256,
                restoredIdentity.Sha256,
                destinationWasPresent,
                StateStoreRecoveryDiagnostics.TokenizePath(restored.TracePath),
                restored.PriorDatabasePath is null
                    ? null
                    : StateStoreRecoveryDiagnostics.TokenizePath(restored.PriorDatabasePath),
                "Static|Synthetic|Contract",
                "NOT_OBSERVED",
                "NOT_OBSERVED");
        }
        catch (StateStoreRestoreRejectedException)
        {
            throw;
        }
        catch (Exception exception)
        {
            throw new StateStoreRestoreRejectedException(
                StateStoreRecoveryDiagnostics.SanitizeMessage(exception.Message),
                exception);
        }
    }

    private static string NormalizeSha256(string value, string identityName)
    {
        if (string.IsNullOrWhiteSpace(value) || !Sha256Pattern.IsMatch(value))
        {
            throw new StateStoreRestoreRejectedException(
                $"The expected {identityName} SHA-256 identity must contain exactly 64 hexadecimal characters.");
        }

        return value.ToUpperInvariant();
    }

    private static string NormalizeDestinationIdentity(string value)
    {
        if (string.Equals(
                value,
                StateStoreRestoreContract.AbsentDestinationIdentity,
                StringComparison.OrdinalIgnoreCase))
        {
            return StateStoreRestoreContract.AbsentDestinationIdentity;
        }

        return NormalizeSha256(value, "destination");
    }

    private static bool ValidateDestinationIdentity(
        string databasePath,
        string expectedIdentity,
        out StateStoreRecoveryFileIdentity? actualIdentity)
    {
        if (Directory.Exists(databasePath))
        {
            throw new StateStoreRestoreRejectedException(
                "The restore destination is a directory, not a state-store file.");
        }

        if (!File.Exists(databasePath))
        {
            actualIdentity = null;
            if (!string.Equals(
                    expectedIdentity,
                    StateStoreRestoreContract.AbsentDestinationIdentity,
                    StringComparison.Ordinal))
            {
                throw new StateStoreRestoreRejectedException(
                    "The expected destination identity requires an existing destination file.");
            }

            return false;
        }

        actualIdentity = StateStoreRecoveryArtifacts.IdentifyFile(databasePath);
        if (string.Equals(
                expectedIdentity,
                StateStoreRestoreContract.AbsentDestinationIdentity,
                StringComparison.Ordinal) ||
            !string.Equals(actualIdentity.Sha256, expectedIdentity, StringComparison.OrdinalIgnoreCase))
        {
            throw new StateStoreRestoreRejectedException(
                "The destination file identity did not match the explicit precondition.");
        }

        return true;
    }

    private static void RequireHashMatch(string label, string expected, string observed)
    {
        if (!string.Equals(expected, observed, StringComparison.OrdinalIgnoreCase))
        {
            throw new StateStoreRestoreRejectedException(
                $"The {label} file identity did not match the explicit SHA-256 precondition.");
        }
    }

    private static bool AreSameIdentity(
        StateStoreRecoveryFileIdentity? left,
        StateStoreRecoveryFileIdentity? right) =>
        left is null && right is null ||
        left is not null && right is not null &&
        left.Length == right.Length &&
        string.Equals(left.Sha256, right.Sha256, StringComparison.OrdinalIgnoreCase);

    private static FileStream AcquireOwnershipLease(string databasePath)
    {
        var lockPath = databasePath + ".core.lock";
        StateStoreRecoveryPathPolicy.EnsureNoReparseComponents(
            Path.GetDirectoryName(lockPath)!,
            includeLeaf: true);
        StateStoreRecoveryPathPolicy.EnsureNoReparseComponents(
            lockPath,
            includeLeaf: true);
        try
        {
            return new FileStream(
                lockPath,
                FileMode.OpenOrCreate,
                FileAccess.ReadWrite,
                FileShare.None,
                bufferSize: 1,
                FileOptions.None);
        }
        catch (Exception exception) when (
            exception is IOException or UnauthorizedAccessException)
        {
            throw new StateStoreRestoreRejectedException(
                "The state store is currently owned by another process or the ownership lock is unavailable.",
                exception);
        }
    }
}
