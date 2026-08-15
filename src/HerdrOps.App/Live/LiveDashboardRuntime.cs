using HerdrOps.App.StateIpc;

namespace HerdrOps.App.Live;

/// <summary>
/// Owns the single App-wide Core subscription so Dashboard and widgets share one stream.
/// </summary>
public sealed class LiveDashboardRuntime : IDisposable
{
    private readonly object _sync = new();
    private readonly LiveDashboardSession _session;
    private CancellationTokenSource? _cancellation;
    private Task? _completion;
    private bool _disposed;

    public LiveDashboardRuntime(
        IHerdrOpsStateUpdateSource source,
        LiveDashboardState state,
        ILiveDashboardUiScheduler scheduler,
        LiveDashboardSessionOptions? options = null,
        TimeProvider? timeProvider = null)
    {
        State = state ?? throw new ArgumentNullException(nameof(state));
        _session = new LiveDashboardSession(
            source,
            state,
            scheduler,
            options,
            timeProvider);
    }

    public LiveDashboardState State { get; }

    public bool IsRunning
    {
        get
        {
            lock (_sync)
            {
                return _completion is { IsCompleted: false };
            }
        }
    }

    public Task Completion
    {
        get
        {
            lock (_sync)
            {
                return _completion ?? Task.CompletedTask;
            }
        }
    }

    public void Start()
    {
        lock (_sync)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            if (_completion is { IsCompleted: false })
            {
                return;
            }

            var cancellation = new CancellationTokenSource();
            var completion = _session.RunAsync(cancellation.Token);
            _cancellation = cancellation;
            _completion = completion;
            _ = ObserveCompletionAsync(completion, cancellation);
        }
    }

    public void Stop()
    {
        lock (_sync)
        {
            _cancellation?.Cancel();
        }
    }

    public void Dispose()
    {
        lock (_sync)
        {
            if (_disposed)
            {
                return;
            }

            _disposed = true;
            _cancellation?.Cancel();
        }

        // The runtime owns the dashboard state supplied to its subscription.
        // Views consume that state but must not dispose it when unloaded.
        State.Dispose();
    }

    private async Task ObserveCompletionAsync(
        Task completion,
        CancellationTokenSource cancellation)
    {
        try
        {
            await completion.ConfigureAwait(false);
        }
        catch
        {
            // LiveDashboardSession already fails closed; observing prevents process-wide faults.
        }
        finally
        {
            lock (_sync)
            {
                if (ReferenceEquals(_completion, completion))
                {
                    _cancellation = null;
                }
            }

            cancellation.Dispose();
        }
    }
}
