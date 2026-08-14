using HerdrOps.Core;
using HerdrOps.Infrastructure.StateIpc;
using HerdrOps.Infrastructure.Storage;

namespace HerdrOps.IntegrationTests;

[TestClass]
public sealed class HerdrStateProjectionCoordinatorTests
{
    [TestMethod]
    public void CoordinatorRestoresStateAndContinuesSequenceAfterCoreRestart()
    {
        using var directory = new TemporaryDirectory();
        var databasePath = Path.Combine(directory.Path, "herdrops.db");
        var pipeName = $"herdrops-projection-{Guid.NewGuid():N}";
        var contract = HerdrStateTestData.CreateState(sequence: 1);
        var domain = HerdrSessionStateContractMapper.ToDomain(contract);

        using (var store = new SqliteHerdrStateStore(new HerdrStateStoreOptions(databasePath)))
        {
            var coordinator = new HerdrStateProjectionCoordinator(
                store,
                new HerdrOpsStatePipeServerOptions(pipeName),
                new FixedTimeProvider(HerdrStateTestData.ObservedUtc.AddMinutes(1)));
            var projected = coordinator.Project(new HerdrRuntimeMonitorSnapshot(
                HerdrRuntimeMonitorStatus.Connected,
                domain,
                null,
                BootstrapCount: 1,
                EventCount: 0,
                DisconnectCount: 0,
                ReconciliationCount: 0,
                LastTransitionReason: null,
                HerdrStateTestData.ObservedUtc.AddSeconds(1)));

            Assert.IsTrue(projected.Persisted);
            Assert.AreEqual(1, coordinator.CurrentState.LastIngestSequence);
        }

        using var restartedStore = new SqliteHerdrStateStore(new HerdrStateStoreOptions(databasePath));
        var restarted = new HerdrStateProjectionCoordinator(
            restartedStore,
            new HerdrOpsStatePipeServerOptions(pipeName),
            new FixedTimeProvider(HerdrStateTestData.ObservedUtc.AddMinutes(1)));
        Assert.AreEqual(1, restarted.CurrentState.LastIngestSequence);
        Assert.AreEqual(1, restarted.RestoredDomainState.LastIngestSequence);
        Assert.AreEqual(
            restarted.CurrentState.LastIngestSequence,
            restarted.PipeServer.CurrentSnapshot.State.LastIngestSequence);

        var nextContract = HerdrStateTestData.CreateState(sequence: 2, status: "Idle", revision: 2);
        var next = HerdrSessionStateContractMapper.ToDomain(nextContract);
        var nextResult = restarted.Project(new HerdrRuntimeMonitorSnapshot(
            HerdrRuntimeMonitorStatus.Connected,
            next,
            null,
            BootstrapCount: 1,
            EventCount: 1,
            DisconnectCount: 0,
            ReconciliationCount: 0,
            LastTransitionReason: null,
            HerdrStateTestData.ObservedUtc.AddSeconds(2)));

        Assert.IsTrue(nextResult.Persisted);
        Assert.AreEqual(2, restartedStore.ReadCurrent()!.State.LastIngestSequence);
        Assert.AreEqual("Idle", restarted.PipeServer.CurrentSnapshot.State.Agents[0].AgentStatus);
    }
}
