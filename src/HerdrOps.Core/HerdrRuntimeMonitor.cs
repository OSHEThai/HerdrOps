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

public sealed record HerdrAcceptedAgentStatusEvent(
    string WorkspaceId,
    string PaneId,
    HerdrAgentStatus AgentStatus,
    string? Agent,
    string? DisplayAgent,
    string? Title)
{
    public string? TabId { get; init; }

    public string? AgentName { get; init; }
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
    DateTimeOffset LastTransitionUtc)
{
    public string? AcceptedEventKind { get; init; }

    public HerdrAcceptedAgentStatusEvent? AcceptedAgentStatusEvent { get; init; }
}

public sealed record HerdrRuntimeMonitorOptions(
    TimeSpan AuthoritativeSnapshotPollInterval)
{
    public TimeSpan AgentRestoreGracePeriod { get; init; } = TimeSpan.FromSeconds(10);

    public static HerdrRuntimeMonitorOptions Default { get; } = new(
        TimeSpan.FromSeconds(1));

    public static HerdrRuntimeMonitorOptions EventOnlyForTests { get; } = new(
        Timeout.InfiniteTimeSpan)
    {
        AgentRestoreGracePeriod = TimeSpan.Zero,
    };

    public void Validate()
    {
        if (AuthoritativeSnapshotPollInterval == Timeout.InfiniteTimeSpan)
        {
            if (AgentRestoreGracePeriod < TimeSpan.Zero ||
                AgentRestoreGracePeriod > TimeSpan.FromMinutes(1))
            {
                throw new ArgumentOutOfRangeException(
                    nameof(AgentRestoreGracePeriod),
                    "The Agent restore grace period must be between zero and one minute.");
            }

            return;
        }

        if (AuthoritativeSnapshotPollInterval <= TimeSpan.Zero ||
            AuthoritativeSnapshotPollInterval > TimeSpan.FromMinutes(1))
        {
            throw new ArgumentOutOfRangeException(
                nameof(AuthoritativeSnapshotPollInterval),
                "The authoritative snapshot poll interval must be positive, no longer than one minute, or infinite for a synthetic test.");
        }

        if (AgentRestoreGracePeriod < TimeSpan.Zero ||
            AgentRestoreGracePeriod > TimeSpan.FromMinutes(1))
        {
            throw new ArgumentOutOfRangeException(
                nameof(AgentRestoreGracePeriod),
                "The Agent restore grace period must be between zero and one minute.");
        }
    }
}

public sealed class HerdrRuntimeMonitor
{
    public const string AcceptedAgentStatusEventKind =
        "pane.agent_status_changed";

    private readonly object _stateLock = new();
    private readonly IHerdrApiClient _apiClient;
    private readonly HerdrPipeEndpoint _endpoint;
    private readonly HerdrStateReducer _reducer;
    private readonly IHerdrReconnectDelay _reconnectDelay;
    private readonly TimeProvider _timeProvider;
    private readonly HerdrRuntimeMonitorOptions _options;
    private HerdrRuntimeMonitorSnapshot _current;
    private int _runActive;

    public HerdrRuntimeMonitor(
        IHerdrApiClient apiClient,
        HerdrPipeEndpoint endpoint,
        HerdrStateReducer? reducer = null,
        IHerdrReconnectDelay? reconnectDelay = null,
        TimeProvider? timeProvider = null,
        HerdrSessionState? initialState = null,
        HerdrRuntimeMonitorOptions? options = null)
    {
        _apiClient = apiClient ?? throw new ArgumentNullException(nameof(apiClient));
        _endpoint = endpoint ?? throw new ArgumentNullException(nameof(endpoint));
        _reducer = reducer ?? new HerdrStateReducer();
        _reconnectDelay = reconnectDelay ?? new HerdrExponentialReconnectDelay();
        _timeProvider = timeProvider ?? TimeProvider.System;
        _options = options ?? HerdrRuntimeMonitorOptions.Default;
        _options.Validate();
        initialState ??= HerdrSessionState.Empty;
        if (initialState.ConnectionEpoch < 0 || initialState.LastIngestSequence < 0)
        {
            throw new ArgumentException(
                "The initial Herdr state cannot contain negative counters.",
                nameof(initialState));
        }

        _current = new HerdrRuntimeMonitorSnapshot(
            HerdrRuntimeMonitorStatus.Starting,
            initialState,
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
        if (Interlocked.CompareExchange(ref _runActive, 1, 0) != 0)
        {
            throw new InvalidOperationException("The Herdr runtime monitor is already running.");
        }

        var connectionEpoch = Current.State.ConnectionEpoch;
        var ingestSequence = Current.State.LastIngestSequence;
        var consecutiveFailures = 0;
        var consecutiveImmediateReconciliations = 0;
        var hasBootstrapped = Current.BootstrapCount > 0;
        var awaitAgentRestoreAfterReconnect = false;
        DateTimeOffset? agentRestoreDeadlineUtc = null;

        try
        {
            while (true)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var immediateReconciliation = false;
                var cycleBootstrapped = false;
                {
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
                        var snapshotReceivedUtc = _timeProvider.GetUtcNow();
                        var authoritativeServerIdentity = _apiClient.LastVerifiedServerIdentity;
                        var bootstrapServerIdentity = ValidateBootstrapServerIdentities(
                            discoveryServerIdentity,
                            subscriptionServerIdentity,
                            authoritativeServerIdentity);
                        if (awaitAgentRestoreAfterReconnect &&
                            _options.AgentRestoreGracePeriod > TimeSpan.Zero)
                        {
                            var now = _timeProvider.GetUtcNow();
                            agentRestoreDeadlineUtc ??= now.Add(_options.AgentRestoreGracePeriod);
                            if (now < agentRestoreDeadlineUtc.Value &&
                                !HasRestoredAgentTopology(Current.State, authoritativeSnapshot))
                            {
                                immediateReconciliation = true;
                                consecutiveFailures = 0;
                            }
                            else
                            {
                                awaitAgentRestoreAfterReconnect = false;
                                agentRestoreDeadlineUtc = null;
                            }
                        }

                        if (!immediateReconciliation)
                        {
                            connectionEpoch++;
                            ingestSequence++;
                            var state = _reducer.Reconcile(
                                authoritativeSnapshot,
                                connectionEpoch,
                                ingestSequence);
                            var authoritativePaneIds = authoritativeSnapshot.Panes
                                .Select(pane => pane.PaneId)
                                .ToHashSet(StringComparer.Ordinal);
                            var paneSetChanged = !subscribedPaneIds.SetEquals(authoritativePaneIds);
                            var current = Current;
                            Publish(
                                current with
                                {
                                    Status = paneSetChanged
                                    ? HerdrRuntimeMonitorStatus.Reconnecting
                                    : HerdrRuntimeMonitorStatus.Connected,
                                    State = state,
                                    ServerIdentity = bootstrapServerIdentity,
                                    BootstrapCount = current.BootstrapCount + 1,
                                    ReconciliationCount = current.ReconciliationCount + (paneSetChanged ? 1 : 0),
                                    LastTransitionReason = paneSetChanged
                                    ? "Pane set changed while the subscription was being bootstrapped."
                                    : null,
                                    LastTransitionUtc = snapshotReceivedUtc,
                                });
                            hasBootstrapped = true;
                            cycleBootstrapped = true;
                            consecutiveFailures = 0;
                            immediateReconciliation = paneSetChanged;

                            if (!immediateReconciliation)
                            {
                                var connectedResult = await MonitorConnectedCycleAsync(
                                        subscriptionScope.Subscription,
                                        subscribedPaneIds,
                                        bootstrapServerIdentity,
                                        connectionEpoch,
                                        ingestSequence,
                                        cancellationToken)
                                    .ConfigureAwait(false);
                                ingestSequence = connectedResult.IngestSequence;
                                immediateReconciliation = connectedResult.ImmediateReconciliation;
                                if (connectedResult.StableProgressObserved)
                                {
                                    consecutiveImmediateReconciliations = 0;
                                }
                            }
                        }
                    }
                    catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
                    {
                        throw;
                    }
                    catch (Exception exception) when (IsRecoverable(exception))
                    {
                        ingestSequence = Current.State.LastIngestSequence;
                        var transportDisconnected = cycleBootstrapped && IsTransportDisconnect(exception);
                        if (transportDisconnected &&
                            Current.State.Agents.Count > 0 &&
                            _options.AgentRestoreGracePeriod > TimeSpan.Zero)
                        {
                            awaitAgentRestoreAfterReconnect = true;
                            agentRestoreDeadlineUtc = null;
                        }
                        if (hasBootstrapped)
                        {
                            RecordReconciliation(
                                exception.Message,
                                ingestSequence,
                                incrementDisconnectCount: transportDisconnected);
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
            try
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
            finally
            {
                Volatile.Write(ref _runActive, 0);
            }
        }
    }

    private static bool HasRestoredAgentTopology(
        HerdrSessionState previousState,
        HerdrSessionSnapshot snapshot)
    {
        if (previousState.Agents.Count == 0)
        {
            return true;
        }

        if (snapshot.Agents.Count != previousState.Agents.Count)
        {
            return false;
        }

        return previousState.Agents.Values.All(expected =>
            snapshot.Agents.Any(observed =>
                string.Equals(observed.PaneId, expected.PaneId, StringComparison.Ordinal) &&
                string.Equals(observed.Agent, expected.Agent, StringComparison.Ordinal) &&
                string.Equals(observed.Name, expected.Name, StringComparison.Ordinal)));
    }

    private static bool IsAcceptedAgentStatusEvent(
        HerdrSessionState previousState,
        HerdrSessionState candidateState,
        HerdrPaneAgentStatusChangedEvent statusChanged)
    {
        if (string.IsNullOrWhiteSpace(statusChanged.Agent) ||
            statusChanged.AgentStatus == HerdrAgentStatus.Unknown ||
            !HasAllLiveAgentIdentities(previousState) ||
            !HasAllLiveAgentIdentities(candidateState) ||
            !TryGetSingleAgentForPane(previousState, statusChanged.PaneId, out var previousAgent) ||
            !TryGetSingleAgentForPane(candidateState, statusChanged.PaneId, out var candidateAgent) ||
            !HasLiveAgentIdentity(previousAgent) ||
            !HasLiveAgentIdentity(candidateAgent) ||
            previousAgent.AgentStatus == HerdrAgentStatus.Unknown ||
            candidateAgent.AgentStatus == HerdrAgentStatus.Unknown ||
            previousAgent.AgentStatus == statusChanged.AgentStatus ||
            !string.Equals(previousAgent.Agent, candidateAgent.Agent, StringComparison.Ordinal) ||
            !string.Equals(previousAgent.Name, candidateAgent.Name, StringComparison.Ordinal) ||
            !HasSameAgentTopology(previousAgent, candidateAgent) ||
            !string.Equals(statusChanged.Agent, previousAgent.Agent, StringComparison.Ordinal) ||
            !string.Equals(statusChanged.Agent, candidateAgent.Agent, StringComparison.Ordinal) ||
            !candidateState.Panes.TryGetValue(statusChanged.PaneId, out var candidatePane) ||
            !previousState.Panes.TryGetValue(statusChanged.PaneId, out var previousPane) ||
            !HasMatchingPaneAgent(previousPane, previousAgent) ||
            !HasMatchingPaneAgent(candidatePane, candidateAgent) ||
            !string.Equals(statusChanged.WorkspaceId, previousAgent.WorkspaceId, StringComparison.Ordinal) ||
            !string.Equals(statusChanged.WorkspaceId, candidateAgent.WorkspaceId, StringComparison.Ordinal) ||
            candidatePane.AgentStatus != statusChanged.AgentStatus ||
            candidateAgent.AgentStatus != statusChanged.AgentStatus ||
            (!string.IsNullOrWhiteSpace(statusChanged.DisplayAgent) &&
             !string.Equals(statusChanged.DisplayAgent, candidateAgent.DisplayAgent, StringComparison.Ordinal)))
        {
            return false;
        }

        return true;
    }

    private static bool TryGetSingleAgentForPane(
        HerdrSessionState state,
        string paneId,
        out HerdrAgentSnapshot agent)
    {
        var matches = state.Agents.Values
            .Where(item => string.Equals(item.PaneId, paneId, StringComparison.Ordinal))
            .ToArray();
        if (matches.Length != 1)
        {
            agent = null!;
            return false;
        }

        agent = matches[0];
        return true;
    }

    private static bool HasAllLiveAgentIdentities(HerdrSessionState state) =>
        state.Agents.Count > 0 && state.Agents.Values.All(HasLiveAgentIdentity);

    private static bool HasLiveAgentIdentity(HerdrAgentSnapshot agent) =>
        !string.IsNullOrWhiteSpace(agent.Agent) &&
        !string.IsNullOrWhiteSpace(agent.Name) &&
        agent.AgentStatus != HerdrAgentStatus.Unknown;

    private static bool HasSameAgentTopology(
        HerdrAgentSnapshot previous,
        HerdrAgentSnapshot current) =>
        string.Equals(previous.WorkspaceId, current.WorkspaceId, StringComparison.Ordinal) &&
        string.Equals(previous.TabId, current.TabId, StringComparison.Ordinal) &&
        string.Equals(previous.PaneId, current.PaneId, StringComparison.Ordinal);

    private static bool HasMatchingPaneAgent(
        HerdrPaneSnapshot pane,
        HerdrAgentSnapshot agent) =>
        string.Equals(pane.WorkspaceId, agent.WorkspaceId, StringComparison.Ordinal) &&
        string.Equals(pane.TabId, agent.TabId, StringComparison.Ordinal) &&
        string.Equals(pane.PaneId, agent.PaneId, StringComparison.Ordinal) &&
        pane.AgentStatus == agent.AgentStatus &&
        !string.IsNullOrWhiteSpace(pane.Agent) &&
        string.Equals(pane.Agent, agent.Agent, StringComparison.Ordinal);

    private void RecordReconciliation(
        string reason,
        long consumedIngestSequence,
        bool incrementEventCount = false,
        bool incrementDisconnectCount = false)
    {
        var current = Current;
        if (consumedIngestSequence < current.State.LastIngestSequence ||
            consumedIngestSequence > current.State.LastIngestSequence + 1)
        {
            throw new InvalidOperationException(
                $"The reconciliation sequence must remain contiguous: current={current.State.LastIngestSequence}, consumed={consumedIngestSequence}.");
        }

        Publish(current with
        {
            Status = HerdrRuntimeMonitorStatus.Reconnecting,
            State = current.State with { LastIngestSequence = consumedIngestSequence },
            EventCount = current.EventCount + (incrementEventCount ? 1 : 0),
            DisconnectCount = current.DisconnectCount + (incrementDisconnectCount ? 1 : 0),
            ReconciliationCount = current.ReconciliationCount + 1,
            LastTransitionReason = reason,
            LastTransitionUtc = _timeProvider.GetUtcNow(),
        });
    }

    private async Task<ConnectedCycleResult> MonitorConnectedCycleAsync(
        IHerdrEventSubscription subscription,
        IReadOnlySet<string> subscribedPaneIds,
        HerdrServerProcessIdentity? bootstrapServerIdentity,
        long connectionEpoch,
        long ingestSequence,
        CancellationToken cancellationToken)
    {
        using var cycleCancellation = CancellationTokenSource.CreateLinkedTokenSource(
            cancellationToken);
        var (readCancellation, eventTask) = StartSubscriptionRead(
            subscription,
            cycleCancellation.Token);
        var pollDelayTask = CreateSnapshotPollDelayAsync(cycleCancellation.Token);
        var stableProgressObserved = false;

        try
        {
            while (true)
            {
                var completedTask = await Task
                    .WhenAny(eventTask, pollDelayTask)
                    .ConfigureAwait(false);

                // Prefer an already-buffered live event when the poll timer and
                // subscription complete together. Status payloads do not expose
                // an ordering sequence, so a fresh authoritative snapshot is
                // fetched after every admitted live status event before state is
                // published.
                if (eventTask.IsCompleted || ReferenceEquals(completedTask, eventTask))
                {
                    var stateEvent = await eventTask.ConfigureAwait(false);
                    var eventReceivedUtc = _timeProvider.GetUtcNow();
                    var nextIngestSequence = checked(ingestSequence + 1);

                    if (stateEvent is HerdrPaneAgentStatusChangedEvent statusChanged &&
                        string.Equals(
                            stateEvent.EventName,
                            "pane.agent_status_changed",
                            StringComparison.Ordinal))
                    {
                        if (!Current.State.Panes.TryGetValue(statusChanged.PaneId, out var pane) ||
                            !string.Equals(
                                pane.WorkspaceId,
                                statusChanged.WorkspaceId,
                                StringComparison.Ordinal))
                        {
                            ingestSequence = nextIngestSequence;
                            RecordReconciliation(
                                $"Live Agent status referenced unknown pane '{statusChanged.PaneId}'.",
                                ingestSequence,
                                incrementEventCount: true);
                            return new ConnectedCycleResult(
                                ingestSequence,
                                ImmediateReconciliation: true,
                                stableProgressObserved);
                        }

                        ingestSequence = nextIngestSequence;
                        HerdrSessionState candidate;
                        DateTimeOffset statusSnapshotReceivedUtc;
                        try
                        {
                            var snapshot = await _apiClient
                                .GetSnapshotAsync(_endpoint, cycleCancellation.Token)
                                .ConfigureAwait(false);
                            statusSnapshotReceivedUtc = _timeProvider.GetUtcNow();
                            ValidateConnectedServerIdentity(bootstrapServerIdentity);
                            candidate = _reducer.Reconcile(
                                snapshot,
                                connectionEpoch,
                                ingestSequence);
                        }
                        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
                        {
                            RecordReconciliation(
                                "Monitoring was cancelled after a live Agent status was consumed but before its authoritative snapshot completed.",
                                ingestSequence,
                                incrementEventCount: true);
                            throw;
                        }
                        catch (Exception exception) when (IsRecoverable(exception))
                        {
                            RecordReconciliation(
                                exception.Message,
                                ingestSequence,
                                incrementEventCount: true,
                                incrementDisconnectCount: IsTransportDisconnect(exception));
                            return new ConnectedCycleResult(
                                ingestSequence,
                                ImmediateReconciliation: true,
                                stableProgressObserved);
                        }

                        var current = Current;
                        var stateChanged = !HasSameAuthoritativeContent(current.State, candidate);
                        var paneSetChanged = !subscribedPaneIds.SetEquals(candidate.Panes.Keys);
                        var acceptedStatusEvent =
                            !paneSetChanged &&
                            candidate.Panes.TryGetValue(statusChanged.PaneId, out var acceptedPane) &&
                            string.Equals(
                                acceptedPane.WorkspaceId,
                                statusChanged.WorkspaceId,
                                StringComparison.Ordinal) &&
                            acceptedPane.AgentStatus == statusChanged.AgentStatus &&
                            IsAcceptedAgentStatusEvent(current.State, candidate, statusChanged)
                                ? statusChanged
                                : null;
                        Publish(
                            current with
                            {
                                Status = paneSetChanged
                                    ? HerdrRuntimeMonitorStatus.Reconnecting
                                    : HerdrRuntimeMonitorStatus.Connected,
                                State = candidate,
                                EventCount = current.EventCount + 1,
                                ReconciliationCount = current.ReconciliationCount + (stateChanged ? 1 : 0),
                                LastTransitionReason = paneSetChanged
                                    ? "Pane set changed while reconciling an observed live Agent status."
                                    : null,
                                LastTransitionUtc = statusSnapshotReceivedUtc,
                            },
                            acceptedStatusEvent);

                        if (paneSetChanged)
                        {
                            return new ConnectedCycleResult(
                                ingestSequence,
                                ImmediateReconciliation: true,
                                stableProgressObserved);
                        }

                        stableProgressObserved = true;
                        if (pollDelayTask.IsCompleted)
                        {
                            // The post-event authoritative snapshot also
                            // satisfies a due topology poll.
                            pollDelayTask = CreateSnapshotPollDelayAsync(cycleCancellation.Token);
                        }

                        readCancellation.Dispose();
                        (readCancellation, eventTask) = StartSubscriptionRead(
                            subscription,
                            cycleCancellation.Token);
                        continue;
                    }

                    ingestSequence = nextIngestSequence;
                    RecordReconciliation(
                        $"Unexpected subscription event '{stateEvent.EventName}' requires an authoritative snapshot and refreshed live filters.",
                        ingestSequence);
                    return new ConnectedCycleResult(
                        ingestSequence,
                        ImmediateReconciliation: true,
                        stableProgressObserved);
                }

                await pollDelayTask.ConfigureAwait(false);
                if (!eventTask.IsCompleted)
                {
                    readCancellation.Cancel();
                }

                try
                {
                    _ = await eventTask.ConfigureAwait(false);
                    // A frame won the cancellation race. Process that exact
                    // task at the top of the loop before polling.
                    continue;
                }
                catch (OperationCanceledException) when (
                    readCancellation.IsCancellationRequested &&
                    !cycleCancellation.IsCancellationRequested)
                {
                    // No frame was consumed. The JSON-line reader retains any
                    // partial bytes for the next read on this subscription.
                }

                var polledSnapshot = await _apiClient
                    .GetSnapshotAsync(_endpoint, cycleCancellation.Token)
                    .ConfigureAwait(false);
                var snapshotReceivedUtc = _timeProvider.GetUtcNow();
                ValidateConnectedServerIdentity(bootstrapServerIdentity);

                var candidateSequence = checked(ingestSequence + 1);
                var polledCandidate = _reducer.Reconcile(
                    polledSnapshot,
                    connectionEpoch,
                    candidateSequence);
                var pollCurrent = Current;
                if (HasSameAuthoritativeContent(pollCurrent.State, polledCandidate))
                {
                    stableProgressObserved = true;
                    readCancellation.Dispose();
                    (readCancellation, eventTask) = StartSubscriptionRead(
                        subscription,
                        cycleCancellation.Token);
                    pollDelayTask = CreateSnapshotPollDelayAsync(cycleCancellation.Token);
                    continue;
                }

                var polledPaneSetChanged = !subscribedPaneIds.SetEquals(polledCandidate.Panes.Keys);
                ingestSequence = candidateSequence;
                Publish(pollCurrent with
                {
                    Status = polledPaneSetChanged
                        ? HerdrRuntimeMonitorStatus.Reconnecting
                        : HerdrRuntimeMonitorStatus.Connected,
                    State = polledCandidate,
                    ReconciliationCount = pollCurrent.ReconciliationCount + 1,
                    LastTransitionReason = polledPaneSetChanged
                        ? "Pane set changed during authoritative snapshot polling; refreshing live status filters."
                        : null,
                    LastTransitionUtc = snapshotReceivedUtc,
                });

                if (polledPaneSetChanged)
                {
                    return new ConnectedCycleResult(
                        ingestSequence,
                        ImmediateReconciliation: true,
                        stableProgressObserved);
                }

                stableProgressObserved = true;
                readCancellation.Dispose();
                (readCancellation, eventTask) = StartSubscriptionRead(
                    subscription,
                    cycleCancellation.Token);
                pollDelayTask = CreateSnapshotPollDelayAsync(cycleCancellation.Token);
            }
        }
        finally
        {
            cycleCancellation.Cancel();
            readCancellation.Cancel();
            await ObserveTaskCompletionAsync(eventTask).ConfigureAwait(false);
            await ObserveTaskCompletionAsync(pollDelayTask).ConfigureAwait(false);
            readCancellation.Dispose();
        }
    }

    private static (CancellationTokenSource Cancellation, Task<HerdrStateEvent> ReadTask)
        StartSubscriptionRead(
            IHerdrEventSubscription subscription,
            CancellationToken cycleCancellationToken)
    {
        var readCancellation = CancellationTokenSource.CreateLinkedTokenSource(
            cycleCancellationToken);
        return (
            readCancellation,
            subscription.ReadNextAsync(readCancellation.Token).AsTask());
    }

    private Task CreateSnapshotPollDelayAsync(CancellationToken cancellationToken) =>
        Task.Delay(
            _options.AuthoritativeSnapshotPollInterval,
            _timeProvider,
            cancellationToken);

    private void ValidateConnectedServerIdentity(HerdrServerProcessIdentity? expected)
    {
        var observed = _apiClient.LastVerifiedServerIdentity;
        if (expected is null && observed is null)
        {
            return;
        }

        if (expected is null || observed is null || !SameServerProcess(expected, observed))
        {
            throw new HerdrServerIdentityException(
                "Herdr server process changed while the live subscription was connected.");
        }
    }

    private static bool HasSameAuthoritativeContent(
        HerdrSessionState first,
        HerdrSessionState second) =>
        string.Equals(first.Version, second.Version, StringComparison.Ordinal) &&
        first.Protocol == second.Protocol &&
        first.ConnectionEpoch == second.ConnectionEpoch &&
        DictionariesEqual(first.Workspaces, second.Workspaces) &&
        DictionariesEqual(first.Tabs, second.Tabs) &&
        DictionariesEqual(first.Panes, second.Panes) &&
        DictionariesEqual(first.Agents, second.Agents) &&
        string.Equals(first.FocusedWorkspaceId, second.FocusedWorkspaceId, StringComparison.Ordinal) &&
        string.Equals(first.FocusedTabId, second.FocusedTabId, StringComparison.Ordinal) &&
        string.Equals(first.FocusedPaneId, second.FocusedPaneId, StringComparison.Ordinal);

    private static bool DictionariesEqual<T>(
        IReadOnlyDictionary<string, T> first,
        IReadOnlyDictionary<string, T> second)
    {
        if (first.Count != second.Count)
        {
            return false;
        }

        foreach (var item in first)
        {
            if (!second.TryGetValue(item.Key, out var candidate) ||
                !EqualityComparer<T>.Default.Equals(item.Value, candidate))
            {
                return false;
            }
        }

        return true;
    }

    private static async Task ObserveTaskCompletionAsync(Task task)
    {
        try
        {
            await task.ConfigureAwait(false);
        }
        catch
        {
            // The connected-cycle result or its primary exception owns the
            // transition. This await only observes a losing/cancelled task.
        }
    }

    private void Publish(
        HerdrRuntimeMonitorSnapshot snapshot,
        HerdrPaneAgentStatusChangedEvent? acceptedAgentStatusEvent = null)
    {
        lock (_stateLock)
        {
            if (acceptedAgentStatusEvent is not null &&
                (!string.Equals(
                     acceptedAgentStatusEvent.EventName,
                     AcceptedAgentStatusEventKind,
                     StringComparison.Ordinal) ||
                 snapshot.Status != HerdrRuntimeMonitorStatus.Connected ||
                 snapshot.EventCount != _current.EventCount + 1 ||
                 !snapshot.State.Panes.TryGetValue(
                     acceptedAgentStatusEvent.PaneId,
                     out var acceptedPane) ||
                 !string.Equals(
                     acceptedPane.WorkspaceId,
                     acceptedAgentStatusEvent.WorkspaceId,
                     StringComparison.Ordinal) ||
                 acceptedPane.AgentStatus != acceptedAgentStatusEvent.AgentStatus ||
                 !IsAcceptedAgentStatusEvent(
                     _current.State,
                     snapshot.State,
                     acceptedAgentStatusEvent)))
            {
                throw new InvalidOperationException(
                    "An accepted runtime event must be a connected transition with exactly one Event-count increment and a matching live Agent identity.");
            }

            HerdrAgentSnapshot? acceptedAgent = null;
            HerdrPaneSnapshot? acceptedPaneSnapshot = null;
            if (acceptedAgentStatusEvent is not null)
            {
                acceptedPaneSnapshot = snapshot.State.Panes[acceptedAgentStatusEvent.PaneId];
                acceptedAgent = snapshot.State.Agents.Values.Single(
                    item => string.Equals(
                        item.PaneId,
                        acceptedAgentStatusEvent.PaneId,
                        StringComparison.Ordinal));
            }

            snapshot = snapshot with
            {
                AcceptedEventKind = acceptedAgentStatusEvent?.EventName,
                AcceptedAgentStatusEvent = acceptedAgentStatusEvent is null
                    ? null
                    : new HerdrAcceptedAgentStatusEvent(
                        acceptedAgentStatusEvent.WorkspaceId,
                        acceptedAgentStatusEvent.PaneId,
                        acceptedAgentStatusEvent.AgentStatus,
                        acceptedAgentStatusEvent.Agent,
                        acceptedAgentStatusEvent.DisplayAgent,
                        acceptedAgentStatusEvent.Title)
                    {
                        TabId = acceptedPaneSnapshot!.TabId,
                        AgentName = acceptedAgent!.Name,
                    },
            };
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
        (exception is HerdrApiErrorException apiError &&
         string.Equals(
             apiError.Code,
             "server_unavailable",
             StringComparison.Ordinal)) ||
        (exception is IOException &&
         exception is not HerdrProtocolException &&
         exception is not HerdrStateConsistencyException);

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

    private sealed record ConnectedCycleResult(
        long IngestSequence,
        bool ImmediateReconciliation,
        bool StableProgressObserved);

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
