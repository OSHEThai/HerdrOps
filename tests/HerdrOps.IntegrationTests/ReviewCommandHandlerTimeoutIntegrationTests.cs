using System.Diagnostics;
using System.IO.Pipes;
using HerdrOps.Contracts.ReviewIpc;
using HerdrOps.Infrastructure.ReviewIpc;
using Microsoft.Data.Sqlite;

namespace HerdrOps.IntegrationTests;

[TestClass]
public sealed class ReviewCommandHandlerTimeoutIntegrationTests
{
    [TestMethod]
    public async Task OperationDeadlineStartsBeforeOperationFrameAndDoesNotReset()
    {
        var pipeName = $"herdrops-review-operation-frame-deadline-{Guid.NewGuid():N}";
        var handlerCalls = 0;
        var server = new HerdrOpsReviewCommandPipeServer(
            new HerdrOpsReviewCommandPipeServerOptions(pipeName)
            {
                MaximumClients = 1,
                HandshakeTimeout = TimeSpan.FromSeconds(5),
                OperationTimeout = TimeSpan.FromMilliseconds(250),
            },
            (request, correlationId, cancellationToken) =>
            {
                _ = request;
                _ = correlationId;
                _ = cancellationToken;
                Interlocked.Increment(ref handlerCalls);
                return ValueTask.FromResult(CreateCommandResult());
            });
        using var stop = new CancellationTokenSource();
        var serverTask = server.RunAsync(stop.Token);
        await server.Ready.WaitAsync(TimeSpan.FromSeconds(5));

        try
        {
            await using var client = CreatePipeClient(pipeName);
            await client.ConnectAsync(5000);
            await SendHelloAsync(client, HerdrOpsReviewCommandProtocol.AppSource);

            // No operation frame is sent. The operation deadline must already
            // be running while the server waits for that frame.
            await Task.Delay(TimeSpan.FromMilliseconds(750));
            Assert.AreEqual(0, server.ActiveClientCount);
            Assert.AreEqual(0, Volatile.Read(ref handlerCalls));
        }
        finally
        {
            stop.Cancel();
            await serverTask.WaitAsync(TimeSpan.FromSeconds(5));
        }
    }

    [TestMethod]
    public async Task RunAsyncWaitsForTimedOutDetachedHandlerBeforeCompletingShutdown()
    {
        var pipeName = $"herdrops-review-detached-shutdown-{Guid.NewGuid():N}";
        var handlerStarted = NewSignal();
        var handlerExited = NewSignal();
        var releaseHandler = NewSignal();
        var server = new HerdrOpsReviewCommandPipeServer(
            new HerdrOpsReviewCommandPipeServerOptions(pipeName)
            {
                MaximumClients = 1,
                MaximumDetachedDelegateConcurrency = 1,
                HandshakeTimeout = TimeSpan.FromSeconds(5),
                OperationTimeout = TimeSpan.FromMilliseconds(150),
            },
            (request, correlationId, cancellationToken) =>
            {
                _ = request;
                _ = correlationId;
                _ = cancellationToken;
                handlerStarted.TrySetResult(true);
                try
                {
                    releaseHandler.Task.GetAwaiter().GetResult();
                    return ValueTask.FromResult(CreateCommandResult());
                }
                finally
                {
                    handlerExited.TrySetResult(true);
                }
            });
        using var stop = new CancellationTokenSource();
        var serverTask = server.RunAsync(stop.Token);
        await server.Ready.WaitAsync(TimeSpan.FromSeconds(5));

        try
        {
            var clientTask = ExpectCommandDisconnectAsync(
                pipeName,
                CreateCommandRequest());
            await handlerStarted.Task.WaitAsync(TimeSpan.FromSeconds(5));
            await clientTask;

            stop.Cancel();
            await Task.Delay(TimeSpan.FromMilliseconds(250));
            Assert.IsFalse(
                serverTask.IsCompleted,
                "RunAsync completed while its timed-out detached handler was still running.");

            releaseHandler.TrySetResult(true);
            await handlerExited.Task.WaitAsync(TimeSpan.FromSeconds(5));
            await serverTask.WaitAsync(TimeSpan.FromSeconds(5));
        }
        finally
        {
            releaseHandler.TrySetResult(true);
            if (handlerStarted.Task.IsCompleted)
            {
                await handlerExited.Task.WaitAsync(TimeSpan.FromSeconds(5));
            }

            stop.Cancel();
            await serverTask.WaitAsync(TimeSpan.FromSeconds(5));
        }
    }

    [TestMethod]
    public async Task SqliteExceptionFromHandlerProducesStructuredCoreUnavailableError()
    {
        var pipeName = $"herdrops-review-sqlite-handler-error-{Guid.NewGuid():N}";
        var server = new HerdrOpsReviewCommandPipeServer(
            new HerdrOpsReviewCommandPipeServerOptions(pipeName)
            {
                MaximumClients = 1,
                HandshakeTimeout = TimeSpan.FromSeconds(5),
                OperationTimeout = TimeSpan.FromSeconds(5),
            },
            static (request, correlationId, cancellationToken) =>
            {
                _ = request;
                _ = correlationId;
                _ = cancellationToken;
                throw new SqliteException(
                    "The test handler simulated a SQLite provider failure.",
                    1);
            });
        using var stop = new CancellationTokenSource();
        var serverTask = server.RunAsync(stop.Token);
        await server.Ready.WaitAsync(TimeSpan.FromSeconds(5));

        try
        {
            await using var client = CreatePipeClient(pipeName);
            await client.ConnectAsync(5000);
            await SendHelloAsync(client, HerdrOpsReviewCommandProtocol.AppSource);
            var request = CreateCommandRequest();
            await SendExecuteAsync(client, request);

            var response = await HerdrOpsReviewCommandJson.ReadFrameAsync(
                client,
                CancellationToken.None);
            Assert.AreEqual(
                HerdrOpsReviewCommandProtocol.MessageTypes.Error,
                response.MessageType);
            Assert.AreEqual(request.CommandId, response.CorrelationId);
            var error = HerdrOpsReviewCommandJson
                .DeserializePayload<HerdrOpsReviewCommandError>(response);
            Assert.AreEqual(
                HerdrOpsReviewCommandProtocol.ErrorCodes.CoreUnavailable,
                error.Code);
            Assert.IsFalse(string.IsNullOrWhiteSpace(error.Message));
        }
        finally
        {
            stop.Cancel();
            await serverTask.WaitAsync(TimeSpan.FromSeconds(5));
        }
    }

    [TestMethod]
    public async Task NonCooperativeMutationHandlerTimeoutReleasesClientSlotForLaterClient()
    {
        var pipeName = $"herdrops-review-handler-timeout-mutation-{Guid.NewGuid():N}";
        var handlerCalls = 0;
        var handlerStarted = NewSignal();
        var operationCanceled = NewSignal();
        var releaseStalledHandler = NewResultSignal<HerdrOpsReviewCommandResult>();
        var server = new HerdrOpsReviewCommandPipeServer(
            new HerdrOpsReviewCommandPipeServerOptions(pipeName)
            {
                MaximumClients = 1,
                HandshakeTimeout = TimeSpan.FromSeconds(5),
                OperationTimeout = TimeSpan.FromMilliseconds(150),
            },
            (request, correlationId, cancellationToken) =>
            {
                _ = request;
                _ = correlationId;
                var call = Interlocked.Increment(ref handlerCalls);
                if (call == 1)
                {
                    handlerStarted.TrySetResult(true);
                    cancellationToken.Register(() => operationCanceled.TrySetResult(true));
                    return new ValueTask<HerdrOpsReviewCommandResult>(
                        releaseStalledHandler.Task);
                }

                cancellationToken.ThrowIfCancellationRequested();
                return ValueTask.FromResult(CreateCommandResult());
            });
        using var stop = new CancellationTokenSource();
        var serverTask = server.RunAsync(stop.Token);
        await server.Ready.WaitAsync(TimeSpan.FromSeconds(5));

        try
        {
            await using (var stalledClient = CreatePipeClient(pipeName))
            {
                await stalledClient.ConnectAsync(5000);
                await SendHelloAsync(stalledClient, HerdrOpsReviewCommandProtocol.AppSource);
                await SendExecuteAsync(stalledClient, CreateCommandRequest());

                await handlerStarted.Task.WaitAsync(TimeSpan.FromSeconds(5));
                await operationCanceled.Task.WaitAsync(TimeSpan.FromSeconds(5));
                await Assert.ThrowsExactlyAsync<EndOfStreamException>(async () =>
                {
                    await HerdrOpsReviewCommandJson
                        .ReadFrameAsync(stalledClient, CancellationToken.None)
                        .AsTask()
                        .WaitAsync(TimeSpan.FromSeconds(5));
                });
            }

            var result = await ExecuteCommandAsync(pipeName);

            Assert.IsFalse(result.IsAccepted);
            Assert.AreEqual(2, Volatile.Read(ref handlerCalls));
        }
        finally
        {
            releaseStalledHandler.TrySetResult(CreateCommandResult());
            stop.Cancel();
            await serverTask.WaitAsync(TimeSpan.FromSeconds(5));
        }
    }

    [TestMethod]
    public async Task CooperativeCapabilitiesHandlerTimeoutReleasesClientSlotForLaterClient()
    {
        var pipeName = $"herdrops-review-handler-timeout-capabilities-{Guid.NewGuid():N}";
        var handlerCalls = 0;
        var handlerStarted = NewSignal();
        var handlerCanceled = NewSignal();
        var server = new HerdrOpsReviewCommandPipeServer(
            new HerdrOpsReviewCommandPipeServerOptions(pipeName)
            {
                MaximumClients = 1,
                HandshakeTimeout = TimeSpan.FromSeconds(5),
                OperationTimeout = TimeSpan.FromMilliseconds(150),
            },
            static (_, _, cancellationToken) =>
            {
                cancellationToken.ThrowIfCancellationRequested();
                return ValueTask.FromResult(CreateCommandResult());
            },
            (request, correlationId, cancellationToken) =>
            {
                _ = request;
                _ = correlationId;
                var call = Interlocked.Increment(ref handlerCalls);
                if (call == 1)
                {
                    handlerStarted.TrySetResult(true);
                    return new ValueTask<HerdrOpsReviewCapabilitiesResult>(
                        WaitForCapabilityCancellationAsync(
                            cancellationToken,
                            handlerCanceled));
                }

                cancellationToken.ThrowIfCancellationRequested();
                return ValueTask.FromResult(CreateCapabilitiesResult());
            },
            static (_, _, cancellationToken) =>
            {
                cancellationToken.ThrowIfCancellationRequested();
                return ValueTask.FromResult(true);
            });
        using var stop = new CancellationTokenSource();
        var serverTask = server.RunAsync(stop.Token);
        await server.Ready.WaitAsync(TimeSpan.FromSeconds(5));

        try
        {
            await using (var stalledClient = CreatePipeClient(pipeName))
            {
                await stalledClient.ConnectAsync(5000);
                await SendHelloAsync(stalledClient, HerdrOpsReviewCommandProtocol.AppSource);
                await SendCapabilitiesAsync(stalledClient, CreateCapabilitiesRequest());

                await handlerStarted.Task.WaitAsync(TimeSpan.FromSeconds(5));
                await handlerCanceled.Task.WaitAsync(TimeSpan.FromSeconds(5));
                await Assert.ThrowsExactlyAsync<EndOfStreamException>(async () =>
                {
                    await HerdrOpsReviewCommandJson
                        .ReadFrameAsync(stalledClient, CancellationToken.None)
                        .AsTask()
                        .WaitAsync(TimeSpan.FromSeconds(5));
                });
            }

            var result = await ReadCapabilitiesAsync(pipeName);

            Assert.IsTrue(result.HasCurrentAuthority);
            Assert.AreEqual(2, Volatile.Read(ref handlerCalls));
        }
        finally
        {
            stop.Cancel();
            await serverTask.WaitAsync(TimeSpan.FromSeconds(5));
        }
    }

    [TestMethod]
    public async Task SynchronousMutationHandlerTimeoutReleasesSlotButRetainsDelegatePermit()
    {
        var pipeName = $"herdrops-review-sync-handler-timeout-{Guid.NewGuid():N}";
        var handlerCalls = 0;
        var handlerStarted = NewSignal();
        var handlerExited = NewSignal();
        var releaseHandler = NewSignal();
        var unobservedExceptions = 0;
        EventHandler<UnobservedTaskExceptionEventArgs> unobservedHandler = (_, args) =>
        {
            Interlocked.Increment(ref unobservedExceptions);
            args.SetObserved();
        };
        TaskScheduler.UnobservedTaskException += unobservedHandler;

        var server = new HerdrOpsReviewCommandPipeServer(
            new HerdrOpsReviewCommandPipeServerOptions(pipeName)
            {
                MaximumClients = 1,
                MaximumDetachedDelegateConcurrency = 1,
                HandshakeTimeout = TimeSpan.FromSeconds(5),
                OperationTimeout = TimeSpan.FromMilliseconds(150),
            },
            (request, correlationId, cancellationToken) =>
            {
                _ = request;
                _ = correlationId;
                var call = Interlocked.Increment(ref handlerCalls);
                if (call == 1)
                {
                    handlerStarted.TrySetResult(true);
                    try
                    {
                        releaseHandler.Task.GetAwaiter().GetResult();
                        throw new InvalidOperationException(
                            "The detached synchronous handler failed after the client deadline.");
                    }
                    finally
                    {
                        handlerExited.TrySetResult(true);
                    }
                }

                cancellationToken.ThrowIfCancellationRequested();
                return ValueTask.FromResult(CreateCommandResult());
            });
        using var stop = new CancellationTokenSource();
        var serverTask = server.RunAsync(stop.Token);
        await server.Ready.WaitAsync(TimeSpan.FromSeconds(5));

        try
        {
            var firstClientTask = ExpectCommandDisconnectAsync(
                pipeName,
                CreateCommandRequest());
            await handlerStarted.Task.WaitAsync(TimeSpan.FromSeconds(5));

            var slotWait = Stopwatch.StartNew();
            await WaitForActiveClientCountAsync(server, 0);
            Assert.IsTrue(
                slotWait.Elapsed < TimeSpan.FromSeconds(2),
                $"The client slot was not released promptly: {slotWait.Elapsed}.");
            await firstClientTask;

            var secondClientTask = ExpectCommandDisconnectAsync(
                pipeName,
                CreateCommandRequest());
            await secondClientTask;
            await WaitForActiveClientCountAsync(server, 0);
            Assert.AreEqual(1, Volatile.Read(ref handlerCalls));

            releaseHandler.TrySetResult(true);
            await handlerExited.Task.WaitAsync(TimeSpan.FromSeconds(5));

            var result = await ExecuteCommandAsync(pipeName);
            Assert.IsFalse(result.IsAccepted);
            Assert.AreEqual(2, Volatile.Read(ref handlerCalls));
        }
        finally
        {
            releaseHandler.TrySetResult(true);
            await handlerExited.Task.WaitAsync(TimeSpan.FromSeconds(5));
            stop.Cancel();
            await serverTask.WaitAsync(TimeSpan.FromSeconds(5));

            GC.Collect();
            GC.WaitForPendingFinalizers();
            GC.Collect();
            await Task.Delay(TimeSpan.FromMilliseconds(100));
            TaskScheduler.UnobservedTaskException -= unobservedHandler;
        }

        Assert.AreEqual(0, Volatile.Read(ref unobservedExceptions));
    }

    [TestMethod]
    public async Task SynchronousAuthorizerTimeoutReleasesClientSlotForLaterClient()
    {
        var pipeName = $"herdrops-review-sync-authorizer-timeout-{Guid.NewGuid():N}";
        var authorizationCalls = 0;
        var handlerCalls = 0;
        var authorizerStarted = NewSignal();
        var authorizerExited = NewSignal();
        var releaseAuthorizer = NewSignal();
        var server = new HerdrOpsReviewCommandPipeServer(
            new HerdrOpsReviewCommandPipeServerOptions(pipeName)
            {
                MaximumClients = 1,
                MaximumDetachedDelegateConcurrency = 2,
                HandshakeTimeout = TimeSpan.FromSeconds(5),
                OperationTimeout = TimeSpan.FromMilliseconds(150),
            },
            (request, correlationId, cancellationToken) =>
            {
                _ = request;
                _ = correlationId;
                cancellationToken.ThrowIfCancellationRequested();
                Interlocked.Increment(ref handlerCalls);
                return ValueTask.FromResult(CreateCommandResult());
            },
            static (request, correlationId, cancellationToken) =>
            {
                _ = request;
                _ = correlationId;
                cancellationToken.ThrowIfCancellationRequested();
                return ValueTask.FromResult(CreateCapabilitiesResult());
            },
            (reviewerActorId, clientProcessId, cancellationToken) =>
            {
                _ = reviewerActorId;
                _ = clientProcessId;
                var call = Interlocked.Increment(ref authorizationCalls);
                if (call == 1)
                {
                    authorizerStarted.TrySetResult(true);
                    try
                    {
                        releaseAuthorizer.Task.GetAwaiter().GetResult();
                        return ValueTask.FromResult(true);
                    }
                    finally
                    {
                        authorizerExited.TrySetResult(true);
                    }
                }

                cancellationToken.ThrowIfCancellationRequested();
                return ValueTask.FromResult(true);
            });
        using var stop = new CancellationTokenSource();
        var serverTask = server.RunAsync(stop.Token);
        await server.Ready.WaitAsync(TimeSpan.FromSeconds(5));

        try
        {
            var firstClientTask = ExpectCommandDisconnectAsync(
                pipeName,
                CreateCommandRequest());
            await authorizerStarted.Task.WaitAsync(TimeSpan.FromSeconds(5));

            var slotWait = Stopwatch.StartNew();
            await WaitForActiveClientCountAsync(server, 0);
            Assert.IsTrue(
                slotWait.Elapsed < TimeSpan.FromSeconds(2),
                $"The client slot was not released promptly: {slotWait.Elapsed}.");
            await firstClientTask;

            var result = await ExecuteCommandAsync(pipeName);
            Assert.IsFalse(result.IsAccepted);
            Assert.AreEqual(2, Volatile.Read(ref authorizationCalls));
            Assert.AreEqual(1, Volatile.Read(ref handlerCalls));
        }
        finally
        {
            releaseAuthorizer.TrySetResult(true);
            await authorizerExited.Task.WaitAsync(TimeSpan.FromSeconds(5));
            stop.Cancel();
            await serverTask.WaitAsync(TimeSpan.FromSeconds(5));
        }
    }

    [TestMethod]
    public async Task SynchronousDetachedDelegatesStayWithinConfiguredConcurrencyBudget()
    {
        var pipeName = $"herdrops-review-sync-concurrency-{Guid.NewGuid():N}";
        var handlerCalls = 0;
        var activeHandlers = 0;
        var maximumActiveHandlers = 0;
        var secondHandlerStarted = NewSignal();
        var releaseHandlers = NewSignal();
        var exitedHandlers = 0;
        var server = new HerdrOpsReviewCommandPipeServer(
            new HerdrOpsReviewCommandPipeServerOptions(pipeName)
            {
                MaximumClients = 4,
                MaximumDetachedDelegateConcurrency = 2,
                HandshakeTimeout = TimeSpan.FromSeconds(5),
                OperationTimeout = TimeSpan.FromMilliseconds(200),
            },
            (request, correlationId, cancellationToken) =>
            {
                _ = request;
                _ = correlationId;
                _ = cancellationToken;
                Interlocked.Increment(ref handlerCalls);
                var active = Interlocked.Increment(ref activeHandlers);
                UpdateMaximum(ref maximumActiveHandlers, active);
                if (active == 2)
                {
                    secondHandlerStarted.TrySetResult(true);
                }

                try
                {
                    releaseHandlers.Task.GetAwaiter().GetResult();
                    return ValueTask.FromResult(CreateCommandResult());
                }
                finally
                {
                    Interlocked.Decrement(ref activeHandlers);
                    Interlocked.Increment(ref exitedHandlers);
                }
            });
        using var stop = new CancellationTokenSource();
        var serverTask = server.RunAsync(stop.Token);
        await server.Ready.WaitAsync(TimeSpan.FromSeconds(5));

        try
        {
            var clients = Enumerable.Range(0, 4)
                .Select(_ => ExpectCommandDisconnectAsync(
                    pipeName,
                    CreateCommandRequest()))
                .ToArray();
            await secondHandlerStarted.Task.WaitAsync(TimeSpan.FromSeconds(5));
            await Task.WhenAll(clients);
            await WaitForActiveClientCountAsync(server, 0);

            Assert.AreEqual(2, Volatile.Read(ref handlerCalls));
            Assert.AreEqual(2, Volatile.Read(ref maximumActiveHandlers));
            Assert.AreEqual(2, Volatile.Read(ref activeHandlers));

            releaseHandlers.TrySetResult(true);
            var started = Stopwatch.GetTimestamp();
            while (Volatile.Read(ref exitedHandlers) != 2)
            {
                if (Stopwatch.GetElapsedTime(started) >= TimeSpan.FromSeconds(5))
                {
                    Assert.Fail("The detached handlers did not complete after release.");
                }

                await Task.Delay(TimeSpan.FromMilliseconds(10));
            }
        }
        finally
        {
            releaseHandlers.TrySetResult(true);
            stop.Cancel();
            await serverTask.WaitAsync(TimeSpan.FromSeconds(5));
        }
    }

    private static async Task<HerdrOpsReviewCommandResult> ExecuteCommandAsync(
        string pipeName)
    {
        await using var client = CreatePipeClient(pipeName);
        await client.ConnectAsync(5000);
        await SendHelloAsync(client, HerdrOpsReviewCommandProtocol.AppSource);
        var request = CreateCommandRequest();
        await SendExecuteAsync(client, request);
        var response = await HerdrOpsReviewCommandJson.ReadFrameAsync(
            client,
            CancellationToken.None);

        Assert.AreEqual(
            HerdrOpsReviewCommandProtocol.MessageTypes.Result,
            response.MessageType);
        return HerdrOpsReviewCommandJson
            .DeserializePayload<HerdrOpsReviewCommandResult>(response);
    }

    private static async Task<HerdrOpsReviewCapabilitiesResult> ReadCapabilitiesAsync(
        string pipeName)
    {
        await using var client = CreatePipeClient(pipeName);
        await client.ConnectAsync(5000);
        await SendHelloAsync(client, HerdrOpsReviewCommandProtocol.AppSource);
        await SendCapabilitiesAsync(client, CreateCapabilitiesRequest());
        var response = await HerdrOpsReviewCommandJson.ReadFrameAsync(
            client,
            CancellationToken.None);

        Assert.AreEqual(
            HerdrOpsReviewCommandProtocol.MessageTypes.CapabilitiesResult,
            response.MessageType);
        return HerdrOpsReviewCommandJson
            .DeserializePayload<HerdrOpsReviewCapabilitiesResult>(response);
    }

    private static async Task ExpectCommandDisconnectAsync(
        string pipeName,
        HerdrOpsReviewCommandRequest request)
    {
        await using var client = CreatePipeClient(pipeName);
        await client.ConnectAsync(5000);
        await SendHelloAsync(client, HerdrOpsReviewCommandProtocol.AppSource);
        await SendExecuteAsync(client, request);
        await Assert.ThrowsExactlyAsync<EndOfStreamException>(async () =>
        {
            await HerdrOpsReviewCommandJson
                .ReadFrameAsync(client, CancellationToken.None)
                .AsTask()
                .WaitAsync(TimeSpan.FromSeconds(5));
        });
    }

    private static async Task WaitForActiveClientCountAsync(
        HerdrOpsReviewCommandPipeServer server,
        int expectedCount)
    {
        var started = Stopwatch.GetTimestamp();
        while (server.ActiveClientCount != expectedCount)
        {
            if (Stopwatch.GetElapsedTime(started) >= TimeSpan.FromSeconds(5))
            {
                Assert.Fail(
                    $"Expected {expectedCount} active review client(s), found {server.ActiveClientCount}.");
            }

            await Task.Delay(TimeSpan.FromMilliseconds(10));
        }
    }

    private static void UpdateMaximum(ref int maximum, int candidate)
    {
        while (true)
        {
            var current = Volatile.Read(ref maximum);
            if (candidate <= current ||
                Interlocked.CompareExchange(ref maximum, candidate, current) == current)
            {
                return;
            }
        }
    }

    private static async Task SendHelloAsync(
        NamedPipeClientStream client,
        string source)
    {
        var correlationId = Guid.NewGuid();
        await HerdrOpsReviewCommandJson.WriteFrameAsync(
            client,
            HerdrOpsReviewCommandJson.CreateEnvelope(
                HerdrOpsReviewCommandProtocol.MessageTypes.Hello,
                DateTimeOffset.UtcNow,
                source,
                correlationId,
                new HerdrOpsReviewCommandHello(
                    HerdrOpsReviewCommandProtocol.AppClientRole,
                    $"handler-timeout-client-{Guid.NewGuid():N}")),
            CancellationToken.None);
        var response = await HerdrOpsReviewCommandJson.ReadFrameAsync(
            client,
            CancellationToken.None);

        Assert.AreEqual(
            HerdrOpsReviewCommandProtocol.MessageTypes.HelloAccepted,
            response.MessageType);
        Assert.AreEqual(correlationId, response.CorrelationId);
    }

    private static Task SendExecuteAsync(
        NamedPipeClientStream client,
        HerdrOpsReviewCommandRequest request) =>
        HerdrOpsReviewCommandJson.WriteFrameAsync(
                client,
                HerdrOpsReviewCommandJson.CreateEnvelope(
                    HerdrOpsReviewCommandProtocol.MessageTypes.Execute,
                    DateTimeOffset.UtcNow,
                    HerdrOpsReviewCommandProtocol.AppSource,
                    request.CommandId,
                    request),
                CancellationToken.None)
            .AsTask();

    private static Task SendCapabilitiesAsync(
        NamedPipeClientStream client,
        HerdrOpsReviewCapabilitiesRequest request)
    {
        var correlationId = Guid.NewGuid();
        return HerdrOpsReviewCommandJson.WriteFrameAsync(
                client,
                HerdrOpsReviewCommandJson.CreateEnvelope(
                    HerdrOpsReviewCommandProtocol.MessageTypes.Capabilities,
                    DateTimeOffset.UtcNow,
                    HerdrOpsReviewCommandProtocol.AppSource,
                    correlationId,
                    request),
                CancellationToken.None)
            .AsTask();
    }

    private static NamedPipeClientStream CreatePipeClient(string pipeName) => new(
        ".",
        pipeName,
        PipeDirection.InOut,
        PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);

    private static HerdrOpsReviewCommandRequest CreateCommandRequest() => new(
        1,
        Guid.NewGuid(),
        "INC-HANDLER-TIMEOUT",
        1,
        ExpectedSequence: 0,
        "project-manager",
        1,
        "handler timeout test",
        []);

    private static HerdrOpsReviewCapabilitiesRequest CreateCapabilitiesRequest() => new(
        "project-manager",
        "INC-HANDLER-TIMEOUT",
        DateTimeOffset.UtcNow);

    private static HerdrOpsReviewCommandResult CreateCommandResult() => new(
        false,
        1,
        "handler-timeout-test",
        null,
        null,
        false);

    private static HerdrOpsReviewCapabilitiesResult CreateCapabilitiesResult() => new(
        true,
        1,
        1,
        0,
        [],
        "capabilities-timeout-test");

    private static async Task<HerdrOpsReviewCapabilitiesResult> WaitForCapabilityCancellationAsync(
        CancellationToken cancellationToken,
        TaskCompletionSource<bool> handlerCanceled)
    {
        try
        {
            await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            handlerCanceled.TrySetResult(true);
            throw;
        }

        throw new InvalidOperationException(
            "The cooperative capability handler should not complete without cancellation.");
    }

    private static TaskCompletionSource<bool> NewSignal() =>
        new(TaskCreationOptions.RunContinuationsAsynchronously);

    private static TaskCompletionSource<TResult> NewResultSignal<TResult>() =>
        new(TaskCreationOptions.RunContinuationsAsynchronously);
}
