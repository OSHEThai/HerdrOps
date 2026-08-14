using System.IO.Pipes;
using HerdrOps.App.StateIpc;
using HerdrOps.Contracts.StateIpc;
using HerdrOps.Infrastructure.StateIpc;

namespace HerdrOps.IntegrationTests;

[TestClass]
public sealed class StateIpcIntegrationTests
{
    [TestMethod]
    public async Task AppReceivesFullSnapshotThenOrderedDeltas()
    {
        var pipeName = $"herdrops-state-test-{Guid.NewGuid():N}";
        var server = new HerdrOpsStatePipeServer(
            new HerdrOpsStatePipeServerOptions(pipeName),
            HerdrStateTestData.Snapshot(HerdrSessionStateContract.Empty));
        var client = new HerdrOpsStatePipeClient(new HerdrOpsStatePipeClientOptions(pipeName));
        using var serverCancellation = new CancellationTokenSource();
        var serverTask = server.RunAsync(serverCancellation.Token);
        await server.Ready.WaitAsync(TimeSpan.FromSeconds(5));
        var snapshotReceived = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var updates = new List<HerdrOpsStateUpdate>();
        var clientTask = ReadThreeUpdatesAsync(client, updates, snapshotReceived);

        await snapshotReceived.Task.WaitAsync(TimeSpan.FromSeconds(5));
        var first = HerdrStateTestData.CreateState(sequence: 1);
        server.PublishDelta(
            HerdrStateTestData.Delta(HerdrSessionStateContract.Empty, first),
            HerdrStateTestData.Snapshot(first),
            Guid.NewGuid());
        var second = HerdrStateTestData.CreateState(sequence: 2, status: "Idle", revision: 2);
        server.PublishDelta(
            HerdrStateTestData.Delta(first, second),
            HerdrStateTestData.Snapshot(second),
            Guid.NewGuid());

        await clientTask.WaitAsync(TimeSpan.FromSeconds(5));
        serverCancellation.Cancel();
        await serverTask.WaitAsync(TimeSpan.FromSeconds(5));

        Assert.HasCount(3, updates);
        CollectionAssert.AreEqual(
            new[] { HerdrOpsStateUpdateKind.Snapshot, HerdrOpsStateUpdateKind.Delta, HerdrOpsStateUpdateKind.Delta },
            updates.Select(update => update.Kind).ToArray());
        CollectionAssert.AreEqual(
            new long[] { 0, 1, 2 },
            updates.Select(update => update.CurrentState.LastIngestSequence).ToArray());
        Assert.AreEqual("Idle", updates[^1].CurrentState.Agents[0].AgentStatus);
        Assert.AreEqual((ulong)2, updates[^1].CurrentState.Panes[0].Revision);
    }

    [TestMethod]
    public async Task ServerRejectsInvalidProtocolVersionBeforeSnapshot()
    {
        var error = await SendRejectedHelloAsync(
            protocolVersion: HerdrOpsStateIpcProtocol.Version + 1,
            source: HerdrOpsStateIpcProtocol.AppSource,
            role: HerdrOpsStateIpcProtocol.AppClientRole);

        Assert.AreEqual(HerdrOpsStateIpcProtocol.ErrorCodes.InvalidProtocolVersion, error.Code);
    }

    [TestMethod]
    public async Task AppReceivesRuntimeHealthWithoutAdvancingStateSequence()
    {
        var pipeName = $"herdrops-state-health-{Guid.NewGuid():N}";
        var state = HerdrStateTestData.CreateState(sequence: 1);
        var server = new HerdrOpsStatePipeServer(
            new HerdrOpsStatePipeServerOptions(pipeName),
            HerdrStateTestData.Snapshot(state));
        using var serverCancellation = new CancellationTokenSource();
        var serverTask = server.RunAsync(serverCancellation.Token);
        await server.Ready.WaitAsync(TimeSpan.FromSeconds(5));
        var client = new HerdrOpsStatePipeClient(new HerdrOpsStatePipeClientOptions(pipeName));
        await using var updates = client.ReadUpdatesAsync().GetAsyncEnumerator();
        try
        {
            Assert.IsTrue(await updates.MoveNextAsync().AsTask().WaitAsync(TimeSpan.FromSeconds(5)));
            Assert.AreEqual(HerdrOpsStateUpdateKind.Snapshot, updates.Current.Kind);
            var connected = updates.Current.RuntimeHealth;
            var reconnecting = connected with
            {
                Status = "Reconnecting",
                LastTransitionUtc = connected.LastTransitionUtc.AddSeconds(1),
                DisconnectCount = 1,
                ReconciliationCount = 1,
            };
            server.PublishRuntimeHealth(
                new HerdrOpsRuntimeHealthPayload(
                    reconnecting,
                    HerdrOpsStateIpcJson.ComputeSha256(state)),
                Guid.NewGuid());

            Assert.IsTrue(await updates.MoveNextAsync().AsTask().WaitAsync(TimeSpan.FromSeconds(5)));
            Assert.AreEqual(HerdrOpsStateUpdateKind.RuntimeHealth, updates.Current.Kind);
            Assert.AreEqual(1L, updates.Current.CurrentState.LastIngestSequence);
            Assert.AreEqual("Reconnecting", updates.Current.RuntimeHealth.Status);
            Assert.AreEqual(1L, updates.Current.RuntimeHealth.DisconnectCount);
        }
        finally
        {
            serverCancellation.Cancel();
            await serverTask.WaitAsync(TimeSpan.FromSeconds(5));
        }
    }

    [TestMethod]
    public async Task ServerRejectsUnauthorizedClientRoleBeforeSnapshot()
    {
        var error = await SendRejectedHelloAsync(
            protocolVersion: HerdrOpsStateIpcProtocol.Version,
            source: HerdrOpsStateIpcProtocol.AppSource,
            role: "cli");

        Assert.AreEqual(HerdrOpsStateIpcProtocol.ErrorCodes.UnauthorizedClient, error.Code);
    }

    [TestMethod]
    public void ProductionPipeEndpointsRequireCurrentUserOnly()
    {
        Assert.IsTrue(HerdrOpsStatePipeServer.RequiredPipeOptions.HasFlag(PipeOptions.CurrentUserOnly));
        Assert.IsTrue(HerdrOpsStatePipeClient.RequiredPipeOptions.HasFlag(PipeOptions.CurrentUserOnly));
        Assert.IsTrue(HerdrOpsStatePipeServer.RequiredPipeOptions.HasFlag(PipeOptions.WriteThrough));
        var serverOptions = HerdrOpsStatePipeServerOptions.ForCurrentUser();
        var clientOptions = HerdrOpsStatePipeClientOptions.ForCurrentUser();
        Assert.AreEqual(serverOptions.PipeName, clientOptions.PipeName);
        Assert.StartsWith("herdrops-state-v2-", serverOptions.PipeName, StringComparison.Ordinal);
    }

    [TestMethod]
    public void OversizedInitialSnapshotFailsBeforeServerStarts()
    {
        var state = HerdrStateTestData.CreateState(sequence: 1);
        state = HerdrSessionStateContractReducer.NormalizeAndValidate(state with
        {
            Workspaces =
            [
                state.Workspaces[0] with { Label = new string('x', 4096) },
            ],
        });
        var snapshot = HerdrStateTestData.Snapshot(state);

        Assert.Throws<HerdrOpsStateIpcProtocolException>(() =>
            new HerdrOpsStatePipeServer(
                new HerdrOpsStatePipeServerOptions(
                    $"herdrops-state-oversized-{Guid.NewGuid():N}",
                    MaximumFrameBytes: 1024),
                snapshot));
    }

    [TestMethod]
    public async Task ClientLimitWaitsForCapacityWithoutStoppingServer()
    {
        var pipeName = $"herdrops-state-capacity-{Guid.NewGuid():N}";
        var server = new HerdrOpsStatePipeServer(
            new HerdrOpsStatePipeServerOptions(pipeName, MaximumClients: 1),
            HerdrStateTestData.Snapshot(HerdrSessionStateContract.Empty));
        using var serverCancellation = new CancellationTokenSource();
        var serverTask = server.RunAsync(serverCancellation.Token);
        await server.Ready.WaitAsync(TimeSpan.FromSeconds(5));
        var firstClient = new HerdrOpsStatePipeClient(new HerdrOpsStatePipeClientOptions(pipeName));
        var firstUpdates = firstClient.ReadUpdatesAsync().GetAsyncEnumerator();
        try
        {
            Assert.IsTrue(await firstUpdates.MoveNextAsync());
            Assert.AreEqual(1, server.ConnectedClientCount);
            await using (var rejectedWhileFull = new NamedPipeClientStream(
                             ".",
                             pipeName,
                             PipeDirection.InOut,
                             PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly))
            {
                await Assert.ThrowsAsync<TimeoutException>(async () =>
                    await rejectedWhileFull.ConnectAsync(150, CancellationToken.None));
            }

            await firstUpdates.DisposeAsync();
            await WaitForClientCountAsync(server, 0);
            var nextClient = new HerdrOpsStatePipeClient(new HerdrOpsStatePipeClientOptions(pipeName));
            await using var nextUpdates = nextClient.ReadUpdatesAsync().GetAsyncEnumerator();
            Assert.IsTrue(await nextUpdates.MoveNextAsync().AsTask().WaitAsync(TimeSpan.FromSeconds(5)));
            Assert.AreEqual(HerdrOpsStateUpdateKind.Snapshot, nextUpdates.Current.Kind);
            Assert.IsFalse(serverTask.IsCompleted);
        }
        finally
        {
            await firstUpdates.DisposeAsync();
            serverCancellation.Cancel();
            await serverTask.WaitAsync(TimeSpan.FromSeconds(5));
        }
    }

    private static async Task ReadThreeUpdatesAsync(
        HerdrOpsStatePipeClient client,
        ICollection<HerdrOpsStateUpdate> updates,
        TaskCompletionSource snapshotReceived)
    {
        await foreach (var update in client.ReadUpdatesAsync())
        {
            updates.Add(update);
            if (update.Kind == HerdrOpsStateUpdateKind.Snapshot)
            {
                snapshotReceived.TrySetResult();
            }

            if (updates.Count == 3)
            {
                return;
            }
        }
    }

    private static async Task<HerdrOpsStateIpcError> SendRejectedHelloAsync(
        int protocolVersion,
        string source,
        string role)
    {
        var pipeName = $"herdrops-state-reject-{Guid.NewGuid():N}";
        var server = new HerdrOpsStatePipeServer(
            new HerdrOpsStatePipeServerOptions(pipeName),
            HerdrStateTestData.Snapshot(HerdrSessionStateContract.Empty));
        using var serverCancellation = new CancellationTokenSource();
        var serverTask = server.RunAsync(serverCancellation.Token);
        await server.Ready.WaitAsync(TimeSpan.FromSeconds(5));
        await using var client = new NamedPipeClientStream(
            ".",
            pipeName,
            PipeDirection.InOut,
            PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
        await client.ConnectAsync(5000, CancellationToken.None);
        var correlationId = Guid.NewGuid();
        var hello = HerdrOpsStateIpcJson.CreateEnvelope(
            HerdrOpsStateIpcProtocol.MessageTypes.Hello,
            0,
            DateTimeOffset.UtcNow,
            source,
            correlationId,
            new HerdrOpsStateIpcHello(role, "rejected-test"),
            protocolVersion);
        await HerdrOpsStateIpcJson.WriteFrameAsync(client, hello, CancellationToken.None);

        var response = await HerdrOpsStateIpcJson.ReadFrameAsync(client, CancellationToken.None);
        Assert.AreEqual(HerdrOpsStateIpcProtocol.MessageTypes.Error, response.MessageType);
        Assert.AreEqual(correlationId, response.CorrelationId);
        var error = HerdrOpsStateIpcJson.DeserializePayload<HerdrOpsStateIpcError>(response);
        serverCancellation.Cancel();
        await serverTask.WaitAsync(TimeSpan.FromSeconds(5));
        return error;
    }

    private static async Task WaitForClientCountAsync(
        HerdrOpsStatePipeServer server,
        int expected)
    {
        var deadline = DateTime.UtcNow.AddSeconds(5);
        while (server.ConnectedClientCount != expected && DateTime.UtcNow < deadline)
        {
            await Task.Delay(10);
        }

        Assert.AreEqual(expected, server.ConnectedClientCount);
    }
}
