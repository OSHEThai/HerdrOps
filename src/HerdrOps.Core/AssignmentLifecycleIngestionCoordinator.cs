using HerdrOps.Domain.Assignments;
using HerdrOps.Infrastructure.Storage;

namespace HerdrOps.Core;

public sealed record AssignmentLifecycleIngestionResult(
    AssignmentLifecycleStep Step,
    HerdrAssignmentLifecycleWriteResult Persistence);

/// <summary>
/// Owns the single Core path from an accepted self-report into the durable
/// deterministic assignment reducer. An unsuccessful database commit rebuilds
/// the in-memory reducer from persisted bytes before the next request.
/// </summary>
public sealed class AssignmentLifecycleIngestionCoordinator
{
    private readonly object _sync = new();
    private readonly SqliteHerdrStateStore _store;
    private AssignmentLifecycleReducer _reducer;

    public AssignmentLifecycleIngestionCoordinator(SqliteHerdrStateStore store)
    {
        _store = store ?? throw new ArgumentNullException(nameof(store));
        _reducer = RestoreReducer(_store.ReadAssignmentLifecycleEvents());
    }

    public IReadOnlyList<HerdrOpsAcceptedSelfReport> RestoredAcceptedEvents
    {
        get
        {
            lock (_sync)
            {
                return _store.ReadAssignmentLifecycleEvents()
                    .Select(item => HerdrOpsAssignmentLifecycleMapper.RestoreAccepted(
                        item.NormalizedEvent.Event))
                    .ToArray();
            }
        }
    }

    public AssignmentLifecycleIngestionResult Commit(HerdrOpsAcceptedSelfReport accepted)
    {
        ArgumentNullException.ThrowIfNull(accepted);
        lock (_sync)
        {
            var lifecycleEvent = HerdrOpsAssignmentLifecycleMapper.Map(accepted);
            var step = _reducer.Process(lifecycleEvent);
            try
            {
                var persistence = _store.CommitAssignmentLifecycle(step);
                if (persistence.WasAlreadyPresent ||
                    persistence.StoredEvent.NormalizedEvent != step.NormalizedEvent ||
                    persistence.StoredEvent.Audit != step.Audit)
                {
                    throw new InvalidOperationException(
                        "A newly accepted self-report did not create its exact lifecycle event.");
                }

                return new AssignmentLifecycleIngestionResult(step, persistence);
            }
            catch
            {
                _reducer = RestoreReducer(_store.ReadAssignmentLifecycleEvents());
                throw;
            }
        }
    }

    public AssignmentLifecycleReplayResult Snapshot()
    {
        lock (_sync)
        {
            return AssignmentLifecycleReplay.Run(
                _store.ReadAssignmentLifecycleEvents()
                    .Select(item => item.NormalizedEvent.Event)
                    .ToArray());
        }
    }

    private static AssignmentLifecycleReducer RestoreReducer(
        IReadOnlyList<HerdrStoredAssignmentLifecycleEvent> storedEvents)
    {
        var reducer = new AssignmentLifecycleReducer();
        foreach (var stored in storedEvents.OrderBy(item =>
                     item.NormalizedEvent.Event.Sequence))
        {
            var replayed = reducer.Process(stored.NormalizedEvent.Event);
            if (replayed.NormalizedEvent != stored.NormalizedEvent ||
                replayed.Audit != stored.Audit)
            {
                throw new HerdrStateStoreException(
                    "The persisted assignment lifecycle does not reproduce its exact audit projection.");
            }
        }

        return reducer;
    }
}
