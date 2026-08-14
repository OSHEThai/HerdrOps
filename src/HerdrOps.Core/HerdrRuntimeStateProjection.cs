namespace HerdrOps.Core;

public sealed class HerdrRuntimeStateProjection : IDisposable
{
    private readonly HerdrRuntimeMonitor _monitor;
    private readonly HerdrStateProjectionCoordinator _coordinator;
    private readonly TaskCompletionSource<Exception> _faulted = new(
        TaskCreationOptions.RunContinuationsAsynchronously);
    private Exception? _fault;
    private bool _disposed;

    public HerdrRuntimeStateProjection(
        HerdrRuntimeMonitor monitor,
        HerdrStateProjectionCoordinator coordinator)
    {
        _monitor = monitor ?? throw new ArgumentNullException(nameof(monitor));
        _coordinator = coordinator ?? throw new ArgumentNullException(nameof(coordinator));
        _monitor.StateChanged += OnStateChanged;
    }

    public Exception? Fault => Volatile.Read(ref _fault);

    public bool IsHealthy => Fault is null;

    public Task<Exception> Faulted => _faulted.Task;

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _monitor.StateChanged -= OnStateChanged;
        _disposed = true;
    }

    private void OnStateChanged(object? sender, HerdrRuntimeMonitorSnapshot snapshot)
    {
        if (Fault is not null)
        {
            return;
        }

        try
        {
            _coordinator.Project(snapshot);
        }
        catch (Exception exception) when (
            exception is IOException or InvalidOperationException or ArgumentException)
        {
            if (Interlocked.CompareExchange(ref _fault, exception, null) is null)
            {
                _faulted.TrySetResult(exception);
            }
        }
    }
}
