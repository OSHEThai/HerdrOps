namespace HerdrOps.Infrastructure.Storage.Recovery;

internal enum StateStoreRecoveryPhase
{
    BeforeBackup,
    AfterBackup,
    BeforeMigration,
    AfterMigrationBeforeCommit,
    AfterMigrationCommit,
    BeforeRollback,
    AfterRollback,
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
    Func<Guid>? GuidFactory = null)
{
    public IStateStoreRecoveryFaultInjector EffectiveFaultInjector =>
        FaultInjector ?? NoopStateStoreRecoveryFaultInjector.Instance;

    public Func<Guid> EffectiveGuidFactory =>
        GuidFactory ?? Guid.NewGuid;
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
