using HerdrOps.Domain.Herdr;
using HerdrOps.Infrastructure.Herdr;

namespace HerdrOps.Core;

public enum HerdrRuntimeMonitorStatus
{
    Starting,
    Connected,
    Reconnecting,
    Stopped,
}

public sealed record HerdrRuntimeMonitorSnapshot(
    HerdrRuntimeMonitorStatus Status,
    HerdrSessionState State,
    HerdrServerProcessIdentity? ServerIdentity,
    long BootstrapCount,
    long EventCount,
    long DisconnectCount,
    long ReconciliationCount,
    string? LastTransitionReason,
    DateTimeOffset LastTransitionUtc);

public sealed class HerdrRuntimeMonitor
{
    private readonly object _stateLock = new();
    private readonly IHerdrApiClient _apiClient;
    private readonly HerdrPipeEndpoint _endpoint;
    private readonly HerdrStateReducer _reducer;
    private readonly IHerdrReconnectDelay _reconnectDelay;
    private readonly TimeProvider _timeProvider;
    private HerdrRuntimeMonitorSnapshot _current;

    public HerdrRuntimeMonitor(
        IHerdrApiClient apiClient,
        HerdrPipeEndpoint endpoint,
        HerdrStateReducer? reducer = null,
        IHerdrReconnectDelay? reconnectDelay = null,
        TimeProvider? timeProvider = null)
    {
        _apiClient = apiClient ?? throw new ArgumentNullException(nameof(apiClient));
        _endpoint = endpoint ?? throw new ArgumentNullException(nameof(endpoint));
        _reducer = reducer ?? new HerdrStateReducer();
        _reconnectDelay = reconnectDelay ?? new HerdrExponentialReconnectDelay();
        _timeProvider = timeProvider ?? TimeProvider.System;
        _current = new HerdrRuntimeMonitorSnapshot(
            HerdrRuntimeMonitorStatus.Starting,
            HerdrSessionState.Empty,
            null,
            0,
            0,
            0,
            0,
            null,
            _timeProvider.GetUtcNow());
    }

    public event EventHandler<HerdrRuntimeMonitorSnapshot>? StateChanged;

    public HerdrServerProcessIdentity? LastVerifiedServerIdentity =>
        _apiClient.LastVerifiedServerIdentity;

    public HerdrRuntimeMonitorSnapshot Current
    {
        get
        {
            lock (_stateLock)
            {
                return _current;
            }
        }
    }

    public async Task RunAsync(CancellationToken cancellationToken)
    {
        var connectionEpoch = Current.State.ConnectionEpoch;
        var ingestSequence = Current.State.LastIngestSequence;
        var consecutiveFailures = 0;
        var consecutiveImmediateReconciliations = 0;
        var hasBootstrapped = Current.BootstrapCount > 0;

        try
        {
            while (true)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var immediateReconciliation = false;
                var cycleBootstrapped = false;
                await using var subscriptionScope = new DeferredSubscriptionScope();
                try
                {
                    var discoverySnapshot = await _apiClient
                        .GetSnapshotAsync(_endpoint, cancellationToken)
                        .ConfigureAwait(false);
                    var discoveryServerIdentity = _apiClient.LastVerifiedServerIdentity;
                    var subscribedPaneIds = discoverySnapshot.Panes
                        .Select(pane => pane.PaneId)
                        .ToHashSet(StringComparer.Ordinal);
                    subscriptionScope.Subscription = await _apiClient
                        .SubscribeAsync(_endpoint, subscribedPaneIds, cancellationToken)
                        .ConfigureAwait(false);
                    var subscriptionServerIdentity = _apiClient.LastVerifiedServerIdentity;

                    var authoritativeSnapshot = await _apiClient
                        .GetSnapshotAsync(_endpoint, cancellationToken)
                        .ConfigureAwait(false);
                    var authoritativeServerIdentity = _apiClient.LastVerifiedServerIdentity;
                    var bootstrapServerIdentity = ValidateBootstrapServerIdentities(
                        discoveryServerIdentity,
                        subscriptionServerIdentity,
                        authoritativeServerIdentity);
                    connectionEpoch++;
                    ingestSequence++;
                    var state = _reducer.Reconcile(
                        authoritativeSnapshot,
                        connectionEpoch,
                        ingestSequence);
                    var current = Current;
                    Publish(current with
                    {
                        Status = HerdrRuntimeMonitorStatus.Connected,
                        State = state,
                        ServerIdentity = bootstrapServerIdentity,
                        BootstrapCount = current.BootstrapCount + 1,
                        LastTransitionReason = null,
                        LastTransitionUtc = _timeProvider.GetUtcNow(),
                    });
                    hasBootstrapped = true;
                    cycleBootstrapped = true;
                    consecutiveFailures = 0;

                    var authoritativePaneIds = authoritativeSnapshot.Panes
                        .Select(pane => pane.PaneId)
                        .ToHashSet(StringComparer.Ordinal);
                    if (!subscribedPaneIds.SetEquals(authoritativePaneIds))
                    {
                        RecordReconciliation(
                            "Pane set changed while the subscription was being bootstrapped.");
                        immediateReconciliation = true;
                    }

                    while (!immediateReconciliation)
                    {
                        var stateEvent = await subscriptionScope.Subscription
                            .ReadNextAsync(cancellationToken)
                            .ConfigureAwait(false);
                        ingestSequence++;
                        if (RequiresTopologyReconciliation(stateEvent.EventName))
                        {
                            RecordReconciliation(
                                $"Topology event '{stateEvent.EventName}' requires an authoritative snapshot.",
                                incrementEventCount: true);
                            immediateReconciliation = true;
                            break;
                        }

                        var result = _reducer.Apply(Current.State, stateEvent, ingestSequence);
                        if (result.Disposition == HerdrStateApplyDisposition.ReconciliationRequired)
                        {
                            RecordReconciliation(
                                result.Reason ?? $"Event '{stateEvent.EventName}' requested reconciliation.",
                                incrementEventCount: true);
                            immediateReconciliation = true;
                            break;
                        }

                        current = Current;
                        Publish(current with
                        {
                            Status = HerdrRuntimeMonitorStatus.Connected,
                            State = result.State,
                            EventCount = current.EventCount + 1,
                            LastTransitionReason = null,
                            LastTransitionUtc = _timeProvider.GetUtcNow(),
                        });
                        consecutiveImmediateReconciliations = 0;

                    }
                }
                catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
                {
                    throw;
                }
                catch (Exception exception) when (IsRecoverable(exception))
                {
                    if (hasBootstrapped)
                    {
                        RecordReconciliation(
                            exception.Message,
                            incrementDisconnectCount: cycleBootstrapped && IsTransportDisconnect(exception));
                    }
                    else
                    {
                        var current = Current;
                        Publish(current with
                        {
                            Status = HerdrRuntimeMonitorStatus.Reconnecting,
                            LastTransitionReason = exception.Message,
                            LastTransitionUtc = _timeProvider.GetUtcNow(),
                        });
                    }

                    consecutiveFailures++;
                }

                if (immediateReconciliation)
                {
                    await _reconnectDelay
                        .DelayAsync(consecutiveImmediateReconciliations, cancellationToken)
                        .ConfigureAwait(false);
                    consecutiveImmediateReconciliations++;
                }
                else
                {
                    consecutiveImmediateReconciliations = 0;
                    await _reconnectDelay
                        .DelayAsync(Math.Max(0, consecutiveFailures - 1), cancellationToken)
                        .ConfigureAwait(false);
                }
            }
        }
        finally
        {
            var current = Current;
            Publish(current with
            {
                Status = HerdrRuntimeMonitorStatus.Stopped,
                LastTransitionReason = cancellationToken.IsCancellationRequested
                    ? "Monitoring was cancelled."
                    : current.LastTransitionReason,
                LastTransitionUtc = _timeProvider.GetUtcNow(),
            });
        }
    }

    private void RecordReconciliation(
        string reason,
        bool incrementEventCount = false,
        bool incrementDisconnectCount = false)
    {
        var current = Current;
        Publish(current with
        {
            Status = HerdrRuntimeMonitorStatus.Reconnecting,
            EventCount = current.EventCount + (incrementEventCount ? 1 : 0),
            DisconnectCount = current.DisconnectCount + (incrementDisconnectCount ? 1 : 0),
            ReconciliationCount = current.ReconciliationCount + 1,
            LastTransitionReason = reason,
            LastTransitionUtc = _timeProvider.GetUtcNow(),
        });
    }

    private void Publish(HerdrRuntimeMonitorSnapshot snapshot)
    {
        lock (_stateLock)
        {
            _current = snapshot;
        }

        var handlers = StateChanged;
        if (handlers is null)
        {
            return;
        }

        foreach (EventHandler<HerdrRuntimeMonitorSnapshot> handler in handlers.GetInvocationList())
        {
            try
            {
                handler(this, snapshot);
            }
            catch
            {
                // Monitoring must remain independent from observers such as UI projections.
            }
        }
    }

    private static bool IsRecoverable(Exception exception) =>
        exception is IOException or TimeoutException or HerdrApiErrorException;

    private static bool IsTransportDisconnect(Exception exception) =>
        exception is EndOfStreamException ||
        (exception is IOException &&
         exception is not HerdrProtocolException &&
         exception is not HerdrStateConsistencyException);

    private static bool RequiresTopologyReconciliation(string eventName) => eventName is
        "workspace_created" or
        "workspace_closed" or
        "worktree_created" or
        "worktree_opened" or
        "worktree_removed" or
        "tab_created" or
        "tab_closed" or
        "tab_moved" or
        "pane_created" or
        "pane_closed" or
        "pane_moved" or
        "pane_exited" or
        "pane_agent_detected";

    private static HerdrServerProcessIdentity? ValidateBootstrapServerIdentities(
        HerdrServerProcessIdentity? discovery,
        HerdrServerProcessIdentity? subscription,
        HerdrServerProcessIdentity? authoritative)
    {
        if (discovery is null && subscription is null && authoritative is null)
        {
            return null;
        }

        if (discovery is null || subscription is null || authoritative is null)
        {
            throw new HerdrServerIdentityException(
                "Herdr server identity was not retained for every bootstrap connection.");
        }

        if (!SameServerProcess(discovery, subscription) ||
            !SameServerProcess(discovery, authoritative))
        {
            throw new HerdrServerIdentityException(
                "Herdr server process changed during discovery, subscription, and authoritative snapshot bootstrap.");
        }

        return authoritative;
    }

    private static bool SameServerProcess(
        HerdrServerProcessIdentity first,
        HerdrServerProcessIdentity second) =>
        first.ProcessId == second.ProcessId &&
        first.ProcessStartUtc == second.ProcessStartUtc &&
        string.Equals(first.ExecutablePath, second.ExecutablePath, StringComparison.OrdinalIgnoreCase) &&
        string.Equals(first.ExecutableSha256, second.ExecutableSha256, StringComparison.Ordinal);

    private sealed class DeferredSubscriptionScope : IAsyncDisposable
    {
        public IHerdrEventSubscription Subscription { get; set; } = NullSubscription.Instance;

        public ValueTask DisposeAsync() => Subscription.DisposeAsync();
    }

    private sealed class NullSubscription : IHerdrEventSubscription
    {
        public static NullSubscription Instance { get; } = new();

        public ValueTask<HerdrStateEvent> ReadNextAsync(CancellationToken cancellationToken) =>
            ValueTask.FromException<HerdrStateEvent>(
                new InvalidOperationException("The Herdr subscription has not started."));

        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }
}
