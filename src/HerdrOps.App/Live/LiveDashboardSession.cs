using System.IO;
using System.Windows.Threading;
using HerdrOps.App.StateIpc;

namespace HerdrOps.App.Live;

public interface ILiveDashboardUiScheduler
{
    ValueTask InvokeAsync(Action action, CancellationToken cancellationToken);
}

public sealed class DispatcherLiveDashboardUiScheduler(Dispatcher dispatcher)
    : ILiveDashboardUiScheduler
{
    private readonly Dispatcher _dispatcher = dispatcher ??
        throw new ArgumentNullException(nameof(dispatcher));

    public async ValueTask InvokeAsync(Action action, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(action);
        if (_dispatcher.CheckAccess())
        {
            cancellationToken.ThrowIfCancellationRequested();
            action();
            return;
        }

        await _dispatcher
            .InvokeAsync(action, DispatcherPriority.DataBind, cancellationToken)
            .Task
            .ConfigureAwait(false);
    }
}

public sealed record LiveDashboardSessionOptions(
    TimeSpan InitialReconnectDelay,
    TimeSpan MaximumReconnectDelay)
{
    public static LiveDashboardSessionOptions Default { get; } = new(
        TimeSpan.FromMilliseconds(100),
        TimeSpan.FromSeconds(2));
}

public sealed class LiveDashboardSession
{
    private readonly IHerdrOpsStateUpdateSource _source;
    private readonly LiveDashboardState _state;
    private readonly ILiveDashboardUiScheduler _scheduler;
    private readonly LiveDashboardSessionOptions _options;
    private readonly TimeProvider _timeProvider;

    public LiveDashboardSession(
        IHerdrOpsStateUpdateSource source,
        LiveDashboardState state,
        ILiveDashboardUiScheduler scheduler,
        LiveDashboardSessionOptions? options = null,
        TimeProvider? timeProvider = null)
    {
        _source = source ?? throw new ArgumentNullException(nameof(source));
        _state = state ?? throw new ArgumentNullException(nameof(state));
        _scheduler = scheduler ?? throw new ArgumentNullException(nameof(scheduler));
        _options = ValidateOptions(options ?? LiveDashboardSessionOptions.Default);
        _timeProvider = timeProvider ?? TimeProvider.System;
    }

    public async Task RunAsync(CancellationToken cancellationToken)
    {
        var attempt = 0;
        try
        {
            while (true)
            {
                cancellationToken.ThrowIfCancellationRequested();
                await _scheduler.InvokeAsync(
                    () => _state.MarkConnecting(reconnecting: attempt > 0),
                    cancellationToken).ConfigureAwait(false);
                try
                {
                    var receivedAnyUpdate = false;
                    await foreach (var update in _source
                                       .ReadUpdatesAsync(cancellationToken)
                                       .ConfigureAwait(false))
                    {
                        receivedAnyUpdate = true;
                        attempt = 0;
                        var receivedUtc = _timeProvider.GetUtcNow();
                        await _scheduler.InvokeAsync(
                            () => _state.ApplyUpdate(update, receivedUtc),
                            cancellationToken).ConfigureAwait(false);
                    }

                    throw new EndOfStreamException(
                        receivedAnyUpdate
                            ? "The Core state IPC stream ended after delivering state."
                            : "The Core state IPC stream ended before delivering a snapshot.");
                }
                catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
                {
                    throw;
                }
                catch (Exception exception) when (IsRecoverable(exception))
                {
                    var observedUtc = _timeProvider.GetUtcNow();
                    await _scheduler.InvokeAsync(
                        () => _state.MarkOffline(exception, observedUtc),
                        cancellationToken).ConfigureAwait(false);
                    var delay = CalculateDelay(attempt++);
                    await Task.Delay(delay, _timeProvider, cancellationToken).ConfigureAwait(false);
                }
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
        }
        finally
        {
            var stoppedUtc = _timeProvider.GetUtcNow();
            await _scheduler.InvokeAsync(
                () => _state.MarkStopped(stoppedUtc),
                CancellationToken.None).ConfigureAwait(false);
        }
    }

    private TimeSpan CalculateDelay(int attempt)
    {
        var exponent = Math.Min(attempt, 20);
        var milliseconds = Math.Min(
            _options.MaximumReconnectDelay.TotalMilliseconds,
            _options.InitialReconnectDelay.TotalMilliseconds * Math.Pow(2, exponent));
        return TimeSpan.FromMilliseconds(milliseconds);
    }

    private static bool IsRecoverable(Exception exception) =>
        exception is IOException or TimeoutException or UnauthorizedAccessException or InvalidOperationException;

    private static LiveDashboardSessionOptions ValidateOptions(LiveDashboardSessionOptions options)
    {
        ArgumentNullException.ThrowIfNull(options);
        if (options.InitialReconnectDelay < TimeSpan.Zero ||
            options.MaximumReconnectDelay < options.InitialReconnectDelay ||
            options.MaximumReconnectDelay > TimeSpan.FromSeconds(30))
        {
            throw new ArgumentOutOfRangeException(
                nameof(options),
                "Dashboard reconnect delays must be non-negative, ordered, and at most 30 seconds.");
        }

        return options;
    }
}
