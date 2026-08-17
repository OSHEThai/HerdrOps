using HerdrOps.Domain.Lifecycle;

namespace HerdrOps.App.Lifecycle;

/// <summary>
/// Makes a created instance gate retryable and idempotent at the application
/// transaction boundary. A failed underlying disposal deliberately leaves the
/// lease undisposed so the owning startup transaction can retry it once the
/// underlying fault is recoverable.
/// </summary>
public sealed class ApplicationInstanceGateLease : IApplicationInstanceGate
{
    private readonly IApplicationInstanceGate _inner;
    private bool _disposed;

    public ApplicationInstanceGateLease(IApplicationInstanceGate inner)
    {
        _inner = inner ?? throw new ArgumentNullException(nameof(inner));
    }

    public bool TryAcquire()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        return _inner.TryAcquire();
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        // Mark the lease disposed only after the underlying resource has been
        // released. This preserves a bounded retry path when Dispose fails.
        _inner.Dispose();
        _disposed = true;
    }
}

/// <summary>
/// Acquires the application instance gate under a startup transaction. The
/// cleanup is registered immediately after construction, before acquisition,
/// so an acquisition exception cannot displace the cleanup failure.
/// </summary>
public static class ApplicationInstanceGateStartup
{
    public static ApplicationInstanceGateLease? Acquire(
        Func<IApplicationInstanceGate> factory,
        StartupTransaction transaction)
    {
        ArgumentNullException.ThrowIfNull(factory);
        ArgumentNullException.ThrowIfNull(transaction);

        var gate = new ApplicationInstanceGateLease(factory());
        transaction.AddCleanup("single-instance", gate.Dispose);
        if (!gate.TryAcquire())
        {
            gate.Dispose();
            return null;
        }

        return gate;
    }
}
