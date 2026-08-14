using HerdrOps.Core;
using HerdrOps.Domain.Herdr;
using HerdrOps.Infrastructure.Herdr;
using HerdrOps.Infrastructure.StateIpc;
using HerdrOps.Infrastructure.Storage;

namespace HerdrOps.IntegrationTests;

[TestClass]
public sealed class HerdrOpsCoreStateServiceTests
{
    [TestMethod]
    public async Task ServiceKeepsPipeAliveUntilCoreCancellation()
    {
        using var directory = new TemporaryDirectory();
        using var store = new SqliteHerdrStateStore(new HerdrStateStoreOptions(
            Path.Combine(directory.Path, "herdrops.db")));
        var coordinator = new HerdrStateProjectionCoordinator(
            store,
            new HerdrOpsStatePipeServerOptions($"herdrops-service-{Guid.NewGuid():N}"));
        var monitor = new HerdrRuntimeMonitor(
            new BlockingApiClient(),
            HerdrPipeEndpoint.FromSocketPath("herdrops-service-test"),
            reconnectDelay: new HerdrExponentialReconnectDelay());
        var service = new HerdrOpsCoreStateService(monitor, coordinator);
        using var cancellation = new CancellationTokenSource();
        var serviceTask = service.RunAsync(cancellation.Token);

        await coordinator.PipeServer.Ready.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.IsFalse(serviceTask.IsCompleted);
        cancellation.Cancel();
        await serviceTask.WaitAsync(TimeSpan.FromSeconds(5));

        Assert.AreEqual(HerdrRuntimeMonitorStatus.Stopped, monitor.Current.Status);
        Assert.IsNull(store.ReadCurrent());
    }

    [TestMethod]
    public async Task ServiceCommandRejectsMissingHerdrWithNonZeroResult()
    {
        using var directory = new TemporaryDirectory();
        var output = new StringWriter();
        var error = new StringWriter();
        var exitCode = await HerdrOpsCoreStateServiceCommand.RunAsync(
            [
                "serve-herdr-state",
                "--database",
                Path.Combine(directory.Path, "herdrops.db"),
                "--herdr",
                Path.Combine(directory.Path, "missing-herdr.exe"),
                "--socket-path",
                "must-not-connect",
            ],
            output,
            error);

        Assert.AreEqual(2, exitCode);
        StringAssert.Contains(error.ToString(), "Core state service failed", StringComparison.Ordinal);
        StringAssert.Contains(error.ToString(), "not found", StringComparison.OrdinalIgnoreCase);
    }

    [TestMethod]
    public async Task ServiceCommandRejectsIncompleteOptionBeforeRuntimeWork()
    {
        var output = new StringWriter();
        var error = new StringWriter();

        var exitCode = await HerdrOpsCoreStateServiceCommand.RunAsync(
            ["serve-herdr-state", "--database"],
            output,
            error);

        Assert.AreEqual(64, exitCode);
        StringAssert.Contains(error.ToString(), "Invalid or incomplete option", StringComparison.Ordinal);
    }

    private sealed class BlockingApiClient : IHerdrApiClient
    {
        public HerdrServerProcessIdentity? LastVerifiedServerIdentity => null;

        public async Task<HerdrSessionSnapshot> GetSnapshotAsync(
            HerdrPipeEndpoint endpoint,
            CancellationToken cancellationToken)
        {
            await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken);
            throw new InvalidOperationException("The cancellation-only test unexpectedly resumed.");
        }

        public Task<IHerdrEventSubscription> SubscribeAsync(
            HerdrPipeEndpoint endpoint,
            IReadOnlyCollection<string> paneIds,
            CancellationToken cancellationToken) =>
            throw new InvalidOperationException("The cancellation-only test must not subscribe.");
    }
}
