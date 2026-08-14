using HerdrOps.Contracts.StateIpc;
using HerdrOps.Domain.Herdr;
using HerdrOps.Infrastructure.StateIpc;
using HerdrOps.Infrastructure.Storage;

namespace HerdrOps.Core;

public sealed record HerdrStateProjectionResult(
    HerdrSessionStateContract State,
    bool Persisted,
    Guid? CorrelationId);

public sealed class HerdrStateProjectionCoordinator
{
    private readonly object _sync = new();
    private readonly SqliteHerdrStateStore _store;
    private readonly TimeProvider _timeProvider;
    private HerdrSessionStateContract _currentState;
    private HerdrRuntimeHealthContract _currentRuntimeHealth;

    public HerdrStateProjectionCoordinator(
        SqliteHerdrStateStore store,
        HerdrOpsStatePipeServerOptions pipeOptions,
        TimeProvider? timeProvider = null)
    {
        _store = store ?? throw new ArgumentNullException(nameof(store));
        _timeProvider = timeProvider ?? TimeProvider.System;
        _currentState = store.ReadCurrent()?.State ?? HerdrSessionStateContract.Empty;
        _currentRuntimeHealth = HerdrRuntimeHealthContract.Starting(_timeProvider.GetUtcNow());
        var snapshot = CreateSnapshotPayload(_currentState, _currentRuntimeHealth);
        PipeServer = new HerdrOpsStatePipeServer(pipeOptions, snapshot, _timeProvider);
    }

    public HerdrOpsStatePipeServer PipeServer { get; }

    public HerdrSessionStateContract CurrentState
    {
        get
        {
            lock (_sync)
            {
                return _currentState;
            }
        }
    }

    public HerdrSessionState RestoredDomainState =>
        HerdrSessionStateContractMapper.ToDomain(CurrentState);

    public HerdrRuntimeHealthContract CurrentRuntimeHealth
    {
        get
        {
            lock (_sync)
            {
                return _currentRuntimeHealth;
            }
        }
    }

    public HerdrStateProjectionResult Project(HerdrRuntimeMonitorSnapshot monitorSnapshot)
    {
        ArgumentNullException.ThrowIfNull(monitorSnapshot);
        lock (_sync)
        {
            var next = HerdrSessionStateContractMapper.ToContract(monitorSnapshot.State);
            var nextHash = HerdrOpsStateIpcJson.ComputeSha256(next);
            var nextHealth = CreateRuntimeHealth(monitorSnapshot, _currentRuntimeHealth);
            if (next.LastIngestSequence == _currentState.LastIngestSequence &&
                string.Equals(
                    nextHash,
                    HerdrOpsStateIpcJson.ComputeSha256(_currentState),
                    StringComparison.Ordinal))
            {
                if (nextHealth == _currentRuntimeHealth)
                {
                    return new HerdrStateProjectionResult(
                        _currentState,
                        Persisted: false,
                        CorrelationId: null);
                }

                var healthCorrelationId = Guid.NewGuid();
                PipeServer.PublishRuntimeHealth(
                    new HerdrOpsRuntimeHealthPayload(nextHealth, nextHash),
                    healthCorrelationId);
                _currentRuntimeHealth = nextHealth;
                return new HerdrStateProjectionResult(
                    _currentState,
                    Persisted: false,
                    healthCorrelationId);
            }

            var delta = HerdrSessionStateContractMapper.CreateDelta(_currentState, next);
            var deltaPayload = new HerdrOpsStateDeltaPayload(delta, nextHash, nextHealth);
            var snapshotPayload = new HerdrOpsStateSnapshotPayload(next, nextHash, nextHealth);
            var correlationId = Guid.NewGuid();
            var ingestedUtc = _timeProvider.GetUtcNow();
            var observedUtc = monitorSnapshot.LastTransitionUtc;
            PipeServer.ValidateDelta(deltaPayload, snapshotPayload, correlationId);
            var result = _store.Commit(new HerdrStateStoreCommit(
                next,
                observedUtc,
                ingestedUtc,
                "HerdrRuntimeMonitor",
                next.ConnectionEpoch > _currentState.ConnectionEpoch ? "authoritative-snapshot" : "state-delta",
                correlationId,
                HerdrOpsStateIpcJson.SerializePayload(deltaPayload)));
            PipeServer.PublishDelta(deltaPayload, snapshotPayload, correlationId);
            _currentState = result.StoredState.State;
            _currentRuntimeHealth = nextHealth;
            return new HerdrStateProjectionResult(
                _currentState,
                Persisted: !result.WasAlreadyPresent,
                correlationId);
        }
    }

    private static HerdrOpsStateSnapshotPayload CreateSnapshotPayload(
        HerdrSessionStateContract state,
        HerdrRuntimeHealthContract runtimeHealth)
    {
        state = HerdrSessionStateContractReducer.NormalizeAndValidate(state);
        return new HerdrOpsStateSnapshotPayload(
            state,
            HerdrOpsStateIpcJson.ComputeSha256(state),
            runtimeHealth);
    }

    private static HerdrRuntimeHealthContract CreateRuntimeHealth(
        HerdrRuntimeMonitorSnapshot snapshot,
        HerdrRuntimeHealthContract current)
    {
        var acceptedUtc = snapshot.Status == HerdrRuntimeMonitorStatus.Connected
            ? snapshot.LastTransitionUtc
            : current.LastAcceptedStateUtc;
        var health = new HerdrRuntimeHealthContract(
            snapshot.Status.ToString(),
            snapshot.LastTransitionUtc,
            acceptedUtc,
            snapshot.BootstrapCount,
            snapshot.EventCount,
            snapshot.DisconnectCount,
            snapshot.ReconciliationCount);
        HerdrSessionStateContractReducer.ValidateRuntimeHealth(health);
        return health;
    }
}
