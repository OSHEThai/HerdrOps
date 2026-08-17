using System.Runtime.ExceptionServices;

namespace HerdrOps.App.Lifecycle;

public sealed class StartupTransactionException : Exception
{
    public StartupTransactionException(Exception primaryException, ShutdownCleanupException cleanupException)
        : base(
            "Application startup failed and one or more rollback actions also failed.",
            new AggregateException(primaryException, cleanupException))
    {
        PrimaryException = primaryException ?? throw new ArgumentNullException(nameof(primaryException));
        CleanupException = cleanupException ?? throw new ArgumentNullException(nameof(cleanupException));
    }

    public Exception PrimaryException { get; }

    public ShutdownCleanupException CleanupException { get; }
}

/// <summary>
/// Registers acquired startup resources and exposes the application only after
/// the final action succeeds. Rollback runs in reverse acquisition order and
/// retains failed actions so a later shutdown pass can retry them.
/// </summary>
public sealed class StartupTransaction
{
    private readonly List<ShutdownCleanupAction> _cleanupActions = [];
    private bool _committed;

    public bool IsCommitted => _committed;

    public bool HasPendingCleanup => _cleanupActions.Count > 0;

    public void AddCleanup(string name, Action cleanup)
    {
        if (_committed)
        {
            throw new InvalidOperationException("The startup transaction has already committed.");
        }

        _cleanupActions.Add(new ShutdownCleanupAction(name, cleanup));
    }

    public void Commit(Action expose)
    {
        if (_committed)
        {
            throw new InvalidOperationException("The startup transaction has already committed.");
        }

        ArgumentNullException.ThrowIfNull(expose);
        expose();
        _committed = true;
        _cleanupActions.Clear();
    }

    public void Rollback(Exception primaryException)
    {
        ArgumentNullException.ThrowIfNull(primaryException);
        try
        {
            RetryCleanup();
        }
        catch (ShutdownCleanupException cleanupException)
        {
            throw new StartupTransactionException(primaryException, cleanupException);
        }

        ExceptionDispatchInfo.Capture(primaryException).Throw();
    }

    public void RetryCleanup()
    {
        if (_cleanupActions.Count == 0)
        {
            return;
        }

        ShutdownCleanup.Execute(_cleanupActions.AsEnumerable().Reverse());
        _cleanupActions.Clear();
    }
}
