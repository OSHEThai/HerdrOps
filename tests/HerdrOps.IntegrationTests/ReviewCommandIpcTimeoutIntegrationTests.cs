using System.Diagnostics;
using System.IO.Pipes;
using HerdrOps.App.ReviewIpc;
using HerdrOps.Contracts.ReviewIpc;
using HerdrOps.Infrastructure.ReviewIpc;

namespace HerdrOps.IntegrationTests;

[DoNotParallelize]
[TestClass]
public sealed class ReviewCommandIpcTimeoutIntegrationTests
{
    [TestMethod]
    public async Task HandshakeTimeoutReleasesClientSlotForLaterLegitimateClient()
    {
        var pipeName = $"herdrops-review-timeout-handshake-{Guid.NewGuid():N}";
        var handlerCalls = 0;
        var server = CreateServer(
            pipeName,
            TimeSpan.FromSeconds(1),
            TimeSpan.FromSeconds(1),
            () => Interlocked.Increment(ref handlerCalls));
        using var stop = new CancellationTokenSource();
        var serverTask = server.RunAsync(stop.Token);
        await server.Ready.WaitAsync(TimeSpan.FromSeconds(5));

        try
        {
            await using (var idleClient = CreatePipeClient(pipeName))
            {
                await idleClient.ConnectAsync(5000);
                await WaitForActiveClientCountAsync(server, 1);
                await WaitForActiveClientCountAsync(server, 0);
            }

            var result = await CreateClient(pipeName).ExecuteAsync(CreateRequest());

            Assert.IsFalse(result.IsAccepted);
            Assert.AreEqual(1, handlerCalls);
        }
        finally
        {
            stop.Cancel();
            await serverTask.WaitAsync(TimeSpan.FromSeconds(5));
        }
    }

    [TestMethod]
    public async Task OperationTimeoutReleasesClientSlotForLaterLegitimateClient()
    {
        var pipeName = $"herdrops-review-timeout-operation-{Guid.NewGuid():N}";
        var handlerCalls = 0;
        var server = CreateServer(
            pipeName,
            TimeSpan.FromSeconds(2),
            TimeSpan.FromMilliseconds(150),
            () => Interlocked.Increment(ref handlerCalls));
        using var stop = new CancellationTokenSource();
        var serverTask = server.RunAsync(stop.Token);
        await server.Ready.WaitAsync(TimeSpan.FromSeconds(5));

        try
        {
            await using (var idleOperationClient = CreatePipeClient(pipeName))
            {
                await idleOperationClient.ConnectAsync(5000);
                var helloCorrelationId = Guid.NewGuid();
                var hello = HerdrOpsReviewCommandJson.CreateEnvelope(
                    HerdrOpsReviewCommandProtocol.MessageTypes.Hello,
                    DateTimeOffset.UtcNow,
                    HerdrOpsReviewCommandProtocol.AppSource,
                    helloCorrelationId,
                    new HerdrOpsReviewCommandHello(
                        HerdrOpsReviewCommandProtocol.AppClientRole,
                        "timeout-test-client"));
                await HerdrOpsReviewCommandJson.WriteFrameAsync(
                    idleOperationClient,
                    hello,
                    CancellationToken.None);
                var helloResponse = await HerdrOpsReviewCommandJson.ReadFrameAsync(
                    idleOperationClient,
                    CancellationToken.None);

                Assert.AreEqual(
                    HerdrOpsReviewCommandProtocol.MessageTypes.HelloAccepted,
                    helloResponse.MessageType);
                await WaitForActiveClientCountAsync(server, 1);
                await WaitForActiveClientCountAsync(server, 0);
            }

            var result = await CreateClient(pipeName).ExecuteAsync(CreateRequest());

            Assert.IsFalse(result.IsAccepted);
            Assert.AreEqual(1, handlerCalls);
        }
        finally
        {
            stop.Cancel();
            await serverTask.WaitAsync(TimeSpan.FromSeconds(5));
        }
    }

    [TestMethod]
    public async Task ShutdownCancelsIdleHandshakeWithoutWaitingForItsDeadline()
    {
        var pipeName = $"herdrops-review-timeout-shutdown-{Guid.NewGuid():N}";
        var server = CreateServer(
            pipeName,
            TimeSpan.FromSeconds(30),
            TimeSpan.FromSeconds(30),
            static () => { });
        using var stop = new CancellationTokenSource();
        var serverTask = server.RunAsync(stop.Token);
        await server.Ready.WaitAsync(TimeSpan.FromSeconds(5));

        try
        {
            await using var idleClient = CreatePipeClient(pipeName);
            await idleClient.ConnectAsync(5000);
            await WaitForActiveClientCountAsync(server, 1);

            stop.Cancel();
            await serverTask.WaitAsync(TimeSpan.FromSeconds(5));
        }
        finally
        {
            stop.Cancel();
            await serverTask.WaitAsync(TimeSpan.FromSeconds(5));
        }
    }

    [TestMethod]
    public async Task NonReadingClientWriteTimeoutReleasesClientSlotForLaterLegitimateClient()
    {
        var pipeName = $"herdrops-review-timeout-write-{Guid.NewGuid():N}";
        var handlerCalls = 0;
        var server = new HerdrOpsReviewCommandPipeServer(
            new HerdrOpsReviewCommandPipeServerOptions(pipeName)
            {
                MaximumClients = 1,
                HandshakeTimeout = TimeSpan.FromSeconds(2),
                OperationTimeout = TimeSpan.FromMilliseconds(200),
            },
            (request, correlationId, cancellationToken) =>
            {
                _ = request;
                _ = correlationId;
                cancellationToken.ThrowIfCancellationRequested();
                Interlocked.Increment(ref handlerCalls);
                return ValueTask.FromResult(new HerdrOpsReviewCommandResult(
                    false,
                    1,
                    new string('x', 256 * 1024),
                    null,
                    null,
                    false));
            });
        using var stop = new CancellationTokenSource();
        var serverTask = server.RunAsync(stop.Token);
        await server.Ready.WaitAsync(TimeSpan.FromSeconds(5));

        try
        {
            await using (var nonReadingClient = CreatePipeClient(pipeName))
            {
                await nonReadingClient.ConnectAsync(5000);
                var helloCorrelationId = Guid.NewGuid();
                await HerdrOpsReviewCommandJson.WriteFrameAsync(
                    nonReadingClient,
                    HerdrOpsReviewCommandJson.CreateEnvelope(
                        HerdrOpsReviewCommandProtocol.MessageTypes.Hello,
                        DateTimeOffset.UtcNow,
                        HerdrOpsReviewCommandProtocol.AppSource,
                        helloCorrelationId,
                        new HerdrOpsReviewCommandHello(
                            HerdrOpsReviewCommandProtocol.AppClientRole,
                            "non-reading-write-timeout-client")),
                    CancellationToken.None);
                var helloResponse = await HerdrOpsReviewCommandJson.ReadFrameAsync(
                    nonReadingClient,
                    CancellationToken.None);
                Assert.AreEqual(
                    HerdrOpsReviewCommandProtocol.MessageTypes.HelloAccepted,
                    helloResponse.MessageType);

                var request = CreateRequest();
                await HerdrOpsReviewCommandJson.WriteFrameAsync(
                    nonReadingClient,
                    HerdrOpsReviewCommandJson.CreateEnvelope(
                        HerdrOpsReviewCommandProtocol.MessageTypes.Execute,
                        DateTimeOffset.UtcNow,
                        HerdrOpsReviewCommandProtocol.AppSource,
                        request.CommandId,
                        request),
                    CancellationToken.None);
                await WaitForHandlerCallsAsync(() => Volatile.Read(ref handlerCalls), 1);
                await WaitForActiveClientCountAsync(server, 0);
            }

            var result = await CreateClient(pipeName).ExecuteAsync(CreateRequest());

            Assert.IsFalse(result.IsAccepted);
            Assert.AreEqual(2, handlerCalls);
        }
        finally
        {
            stop.Cancel();
            await serverTask.WaitAsync(TimeSpan.FromSeconds(5));
        }
    }

    [TestMethod]
    public async Task AppHandshakeDeadlineAfterConnectBecomesTimeoutException()
    {
        var pipeName = $"herdrops-review-timeout-app-handshake-{Guid.NewGuid():N}";
        await using var server = CreatePipeServer(pipeName);
        using var stop = new CancellationTokenSource();
        var serverTask = StallAfterHelloAsync(server, stop.Token);

        try
        {
            var exception = await Assert.ThrowsExactlyAsync<TimeoutException>(async () =>
                await CreateClient(pipeName, TimeSpan.FromMilliseconds(200))
                    .ExecuteAsync(CreateRequest()));

            StringAssert.Contains(exception.Message, "handshake");
        }
        finally
        {
            stop.Cancel();
            await serverTask.WaitAsync(TimeSpan.FromSeconds(5));
        }
    }

    [TestMethod]
    public async Task AppOperationDeadlineAfterHandshakeBecomesTimeoutException()
    {
        var pipeName = $"herdrops-review-timeout-app-operation-{Guid.NewGuid():N}";
        await using var server = CreatePipeServer(pipeName);
        using var stop = new CancellationTokenSource();
        var serverTask = StallAfterExecuteAsync(server, stop.Token);

        try
        {
            var exception = await Assert.ThrowsExactlyAsync<TimeoutException>(async () =>
                await CreateClient(pipeName, TimeSpan.FromMilliseconds(200))
                    .ExecuteAsync(CreateRequest()));

            StringAssert.Contains(exception.Message, "operation");
        }
        finally
        {
            stop.Cancel();
            await serverTask.WaitAsync(TimeSpan.FromSeconds(5));
        }
    }

    [TestMethod]
    public async Task AppCallerCancellationAfterConnectRemainsOperationCanceledException()
    {
        var pipeName = $"herdrops-review-timeout-app-cancellation-{Guid.NewGuid():N}";
        await using var server = CreatePipeServer(pipeName);
        using var stop = new CancellationTokenSource();
        using var callerCancellation = new CancellationTokenSource();
        var helloReceived = new TaskCompletionSource<bool>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var serverTask = StallAfterHelloAsync(server, stop.Token, helloReceived);

        try
        {
            var execution = CreateClient(pipeName, TimeSpan.FromSeconds(5))
                .ExecuteAsync(CreateRequest(), callerCancellation.Token)
                .AsTask();
            await helloReceived.Task.WaitAsync(TimeSpan.FromSeconds(5));
            callerCancellation.Cancel();

            await Assert.ThrowsExactlyAsync<OperationCanceledException>(async () =>
                await execution);
        }
        finally
        {
            stop.Cancel();
            await serverTask.WaitAsync(TimeSpan.FromSeconds(5));
        }
    }

    [TestMethod]
    public async Task AppServerProcessValidationTimeoutIsBoundedAndSendsNoHello()
    {
        var pipeName = $"herdrops-review-timeout-app-validation-{Guid.NewGuid():N}";
        await using var server = CreatePipeServer(pipeName);
        using var stop = new CancellationTokenSource();
        var connected = new TaskCompletionSource<bool>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var firstByteObserved = new TaskCompletionSource<bool>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var serverTask = ObserveConnectionWithoutHelloAsync(
            server,
            stop.Token,
            connected,
            firstByteObserved);
        var validatorEntered = new TaskCompletionSource<bool>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var releaseValidator = new TaskCompletionSource<bool>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var validatorExited = new TaskCompletionSource<bool>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var client = CreateClient(
            pipeName,
            TimeSpan.FromMilliseconds(200),
            CreateStalledValidator(
                validatorEntered,
                releaseValidator,
                validatorExited));

        try
        {
            var execution = client.ExecuteAsync(CreateRequest()).AsTask();
            await validatorEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));

            var exception = await Assert.ThrowsExactlyAsync<TimeoutException>(async () =>
                await execution);

            StringAssert.Contains(exception.Message, "connecting");
            Assert.IsTrue(await connected.Task.WaitAsync(TimeSpan.FromSeconds(5)));
            Assert.IsFalse(await firstByteObserved.Task.WaitAsync(TimeSpan.FromSeconds(5)));
        }
        finally
        {
            // The legacy synchronous validator cannot be force-cancelled. Release the test
            // delegate after the client call has returned so its background task can finish.
            releaseValidator.TrySetResult(true);
            await validatorExited.Task.WaitAsync(TimeSpan.FromSeconds(5));
            stop.Cancel();
            await serverTask.WaitAsync(TimeSpan.FromSeconds(5));
        }
    }

    [TestMethod]
    public async Task AppCallerCancellationDuringServerProcessValidationRemainsOperationCanceledException()
    {
        var pipeName = $"herdrops-review-timeout-app-validation-cancellation-{Guid.NewGuid():N}";
        await using var server = CreatePipeServer(pipeName);
        using var stop = new CancellationTokenSource();
        using var callerCancellation = new CancellationTokenSource();
        var connected = new TaskCompletionSource<bool>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var firstByteObserved = new TaskCompletionSource<bool>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var serverTask = ObserveConnectionWithoutHelloAsync(
            server,
            stop.Token,
            connected,
            firstByteObserved);
        var validatorEntered = new TaskCompletionSource<bool>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var releaseValidator = new TaskCompletionSource<bool>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var validatorExited = new TaskCompletionSource<bool>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var client = CreateClient(
            pipeName,
            TimeSpan.FromSeconds(5),
            CreateStalledValidator(
                validatorEntered,
                releaseValidator,
                validatorExited));

        try
        {
            var execution = client
                .ExecuteAsync(CreateRequest(), callerCancellation.Token)
                .AsTask();
            await validatorEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));
            callerCancellation.Cancel();

            await Assert.ThrowsExactlyAsync<OperationCanceledException>(async () =>
                await execution);

            Assert.IsTrue(await connected.Task.WaitAsync(TimeSpan.FromSeconds(5)));
            Assert.IsFalse(await firstByteObserved.Task.WaitAsync(TimeSpan.FromSeconds(5)));
        }
        finally
        {
            releaseValidator.TrySetResult(true);
            await validatorExited.Task.WaitAsync(TimeSpan.FromSeconds(5));
            stop.Cancel();
            await serverTask.WaitAsync(TimeSpan.FromSeconds(5));
        }
    }

    [TestMethod]
    public async Task CliServerProcessValidationTimeoutIsBoundedAndSendsNoHello()
    {
        var pipeName = $"herdrops-review-timeout-cli-validation-{Guid.NewGuid():N}";
        await using var server = CreatePipeServer(pipeName);
        using var stop = new CancellationTokenSource();
        var connected = new TaskCompletionSource<bool>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var firstByteObserved = new TaskCompletionSource<bool>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var serverTask = ObserveConnectionWithoutHelloAsync(
            server,
            stop.Token,
            connected,
            firstByteObserved);
        var validatorEntered = new TaskCompletionSource<bool>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var releaseValidator = new TaskCompletionSource<bool>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var validatorExited = new TaskCompletionSource<bool>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var client = CreateCliClient(
            pipeName,
            TimeSpan.FromMilliseconds(200),
            CreateStalledValidator(
                validatorEntered,
                releaseValidator,
                validatorExited));

        try
        {
            var execution = client.ExecuteAsync(CreateRequest()).AsTask();
            await validatorEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));

            var exception = await Assert.ThrowsExactlyAsync<TimeoutException>(async () =>
                await execution);

            StringAssert.Contains(exception.Message, "connecting");
            Assert.IsTrue(await connected.Task.WaitAsync(TimeSpan.FromSeconds(5)));
            Assert.IsFalse(await firstByteObserved.Task.WaitAsync(TimeSpan.FromSeconds(5)));
        }
        finally
        {
            releaseValidator.TrySetResult(true);
            await validatorExited.Task.WaitAsync(TimeSpan.FromSeconds(5));
            stop.Cancel();
            await serverTask.WaitAsync(TimeSpan.FromSeconds(5));
        }
    }

    [TestMethod]
    public async Task CliCallerCancellationDuringServerProcessValidationRemainsOperationCanceledException()
    {
        var pipeName = $"herdrops-review-timeout-cli-validation-cancellation-{Guid.NewGuid():N}";
        await using var server = CreatePipeServer(pipeName);
        using var stop = new CancellationTokenSource();
        using var callerCancellation = new CancellationTokenSource();
        var connected = new TaskCompletionSource<bool>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var firstByteObserved = new TaskCompletionSource<bool>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var serverTask = ObserveConnectionWithoutHelloAsync(
            server,
            stop.Token,
            connected,
            firstByteObserved);
        var validatorEntered = new TaskCompletionSource<bool>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var releaseValidator = new TaskCompletionSource<bool>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var validatorExited = new TaskCompletionSource<bool>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var client = CreateCliClient(
            pipeName,
            TimeSpan.FromSeconds(5),
            CreateStalledValidator(
                validatorEntered,
                releaseValidator,
                validatorExited));

        try
        {
            var execution = client
                .ExecuteAsync(CreateRequest(), callerCancellation.Token)
                .AsTask();
            await validatorEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));
            callerCancellation.Cancel();

            await Assert.ThrowsExactlyAsync<OperationCanceledException>(async () =>
                await execution);

            Assert.IsTrue(await connected.Task.WaitAsync(TimeSpan.FromSeconds(5)));
            Assert.IsFalse(await firstByteObserved.Task.WaitAsync(TimeSpan.FromSeconds(5)));
        }
        finally
        {
            releaseValidator.TrySetResult(true);
            await validatorExited.Task.WaitAsync(TimeSpan.FromSeconds(5));
            stop.Cancel();
            await serverTask.WaitAsync(TimeSpan.FromSeconds(5));
        }
    }

    [TestMethod]
    public async Task AppServerProcessValidationBudgetCapsStalledValidatorsAndRecovers()
    {
        await AssertServerProcessValidationBudgetAsync(
            $"herdrops-review-timeout-app-validation-budget-{Guid.NewGuid():N}",
            HerdrOpsReviewCommandPipeClient.ServerProcessValidationConcurrencyLimit,
            (pipeName, timeout, validator) =>
                CreateClient(pipeName, timeout, validator)
                    .ExecuteAsync(CreateRequest())
                    .AsTask());
    }

    [TestMethod]
    public async Task CliServerProcessValidationBudgetCapsStalledValidatorsAndRecovers()
    {
        await AssertServerProcessValidationBudgetAsync(
            $"herdrops-review-timeout-cli-validation-budget-{Guid.NewGuid():N}",
            HerdrOps.Cli.HerdrOpsReviewCommandPipeClient
                .ServerProcessValidationConcurrencyLimit,
            (pipeName, timeout, validator) =>
                CreateCliClient(pipeName, timeout, validator)
                    .ExecuteAsync(CreateRequest())
                    .AsTask());
    }

    private static async Task AssertServerProcessValidationBudgetAsync(
        string pipeNamePrefix,
        int concurrencyLimit,
        Func<
            string,
            TimeSpan,
            Action<NamedPipeClientStream>,
            Task<HerdrOpsReviewCommandResult>> startExecution)
    {
        var stalledValidatorCount = concurrencyLimit + 2;
        var phaseTimeout = TimeSpan.FromMilliseconds(250);
        using var stop = new CancellationTokenSource();
        var releaseValidators = new TaskCompletionSource<bool>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var validatorStarts = 0;
        var validatorExits = 0;
        var servers = new List<NamedPipeServerStream>(stalledValidatorCount + 1);
        var serverTasks = new List<Task>(stalledValidatorCount + 1);
        var executions = new List<Task<HerdrOpsReviewCommandResult>>(
            stalledValidatorCount + 1);
        var connected = new TaskCompletionSource<bool>[stalledValidatorCount];
        var firstByteObserved = new TaskCompletionSource<bool>[stalledValidatorCount];

        try
        {
            for (var index = 0; index < stalledValidatorCount; index++)
            {
                var pipeName = $"{pipeNamePrefix}-{index}";
                var server = CreatePipeServer(pipeName);
                servers.Add(server);
                connected[index] = new TaskCompletionSource<bool>(
                    TaskCreationOptions.RunContinuationsAsynchronously);
                firstByteObserved[index] = new TaskCompletionSource<bool>(
                    TaskCreationOptions.RunContinuationsAsynchronously);
                serverTasks.Add(ObserveConnectionWithoutHelloAsync(
                    server,
                    stop.Token,
                    connected[index],
                    firstByteObserved[index]));

                executions.Add(startExecution(
                    pipeName,
                    phaseTimeout,
                    CreateStalledValidator(
                        releaseValidators,
                        () => Interlocked.Increment(ref validatorStarts),
                        () => Interlocked.Increment(ref validatorExits))));
            }

            await Task.WhenAll(
                    connected.Select(signal => signal.Task.WaitAsync(TimeSpan.FromSeconds(5))))
                .WaitAsync(TimeSpan.FromSeconds(5));
            await WaitForCountAsync(
                () => Volatile.Read(ref validatorStarts),
                concurrencyLimit,
                "server-process validation worker starts");

            var callerAssertions = executions.Select(async execution =>
            {
                var exception = await Assert.ThrowsExactlyAsync<TimeoutException>(async () =>
                    await execution);
                StringAssert.Contains(exception.Message, "connecting");
            });
            await Task.WhenAll(callerAssertions).WaitAsync(TimeSpan.FromSeconds(2));

            Assert.AreEqual(
                concurrencyLimit,
                Volatile.Read(ref validatorStarts),
                "Only the process-wide validation budget may start stalled workers.");
            foreach (var signal in firstByteObserved)
            {
                Assert.IsFalse(
                    await signal.Task.WaitAsync(TimeSpan.FromSeconds(5)),
                    "A stalled validator must not permit a hello frame.");
            }

            releaseValidators.TrySetResult(true);
            await WaitForCountAsync(
                () => Volatile.Read(ref validatorExits),
                concurrencyLimit,
                "server-process validation worker exits");

            var recoveryPipeName = $"{pipeNamePrefix}-recovery";
            var recoveryServer = CreatePipeServer(recoveryPipeName);
            servers.Add(recoveryServer);
            var recoveryConnected = new TaskCompletionSource<bool>(
                TaskCreationOptions.RunContinuationsAsynchronously);
            var recoveryFirstByteObserved = new TaskCompletionSource<bool>(
                TaskCreationOptions.RunContinuationsAsynchronously);
            serverTasks.Add(ObserveConnectionWithoutHelloAsync(
                recoveryServer,
                stop.Token,
                recoveryConnected,
                recoveryFirstByteObserved));
            var recoveryStarted = new TaskCompletionSource<bool>(
                TaskCreationOptions.RunContinuationsAsynchronously);
            var recoveryExecution = startExecution(
                recoveryPipeName,
                TimeSpan.FromSeconds(2),
                _ => recoveryStarted.TrySetResult(true));
            executions.Add(recoveryExecution);

            await recoveryStarted.Task.WaitAsync(TimeSpan.FromSeconds(5));
            Assert.IsTrue(await recoveryConnected.Task.WaitAsync(TimeSpan.FromSeconds(5)));
            Assert.IsTrue(await recoveryFirstByteObserved.Task.WaitAsync(TimeSpan.FromSeconds(5)));
            var recoveryException = await Assert.ThrowsExactlyAsync<TimeoutException>(async () =>
                await recoveryExecution);
            StringAssert.Contains(recoveryException.Message, "handshake");
        }
        finally
        {
            releaseValidators.TrySetResult(true);
            try
            {
                await Task.WhenAll(executions).WaitAsync(TimeSpan.FromSeconds(5));
            }
            catch
            {
                // The caller assertions above own the expected timeout outcomes.
            }

            stop.Cancel();
            try
            {
                await Task.WhenAll(serverTasks).WaitAsync(TimeSpan.FromSeconds(5));
            }
            catch
            {
                // Cancellation and pipe closure are cleanup paths for this test.
            }

            foreach (var server in servers)
            {
                await server.DisposeAsync();
            }
        }
    }

    private static HerdrOpsReviewCommandPipeServer CreateServer(
        string pipeName,
        TimeSpan handshakeTimeout,
        TimeSpan operationTimeout,
        Action onExecute) =>
        new(
            new HerdrOpsReviewCommandPipeServerOptions(pipeName)
            {
                MaximumClients = 1,
                HandshakeTimeout = handshakeTimeout,
                OperationTimeout = operationTimeout,
            },
            (request, correlationId, cancellationToken) =>
            {
                _ = request;
                _ = correlationId;
                cancellationToken.ThrowIfCancellationRequested();
                onExecute();
                return ValueTask.FromResult(new HerdrOpsReviewCommandResult(
                    false,
                    1,
                    "timeout-test-handler",
                    null,
                    null,
                    false));
            });

    private static NamedPipeClientStream CreatePipeClient(string pipeName) => new(
        ".",
        pipeName,
        PipeDirection.InOut,
        PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);

    private static HerdrOpsReviewCommandPipeClient CreateClient(
        string pipeName,
        TimeSpan? timeout = null,
        Action<NamedPipeClientStream>? serverProcessValidator = null) =>
        new(new HerdrOpsReviewCommandPipeClientOptions(
            pipeName,
            timeout ?? TimeSpan.FromSeconds(5)),
            timeProvider: null,
            serverProcessValidator ?? (static _ => { }));

    private static HerdrOps.Cli.HerdrOpsReviewCommandPipeClient CreateCliClient(
        string pipeName,
        TimeSpan timeout,
        Action<NamedPipeClientStream> serverProcessValidator) =>
        new(
            new HerdrOps.Cli.HerdrOpsReviewCommandCliPipeOptions(pipeName, timeout),
            timeProvider: null,
            serverProcessValidator);

    private static Action<NamedPipeClientStream> CreateStalledValidator(
        TaskCompletionSource<bool> entered,
        TaskCompletionSource<bool> release,
        TaskCompletionSource<bool> exited) =>
        CreateStalledValidator(
            release,
            () => entered.TrySetResult(true),
            () => exited.TrySetResult(true));

    private static Action<NamedPipeClientStream> CreateStalledValidator(
        TaskCompletionSource<bool> release,
        Action onEntered,
        Action onExited) =>
        _ =>
        {
            try
            {
                onEntered();
                release.Task.GetAwaiter().GetResult();
            }
            finally
            {
                onExited();
            }
        };

    private static HerdrOpsReviewCommandRequest CreateRequest() => new(
        1,
        Guid.NewGuid(),
        "INC-TIMEOUT",
        1,
        ExpectedSequence: 0,
        "project-manager",
        1,
        "timeout test",
        []);

    private static NamedPipeServerStream CreatePipeServer(string pipeName) => new(
        pipeName,
        PipeDirection.InOut,
        1,
        PipeTransmissionMode.Byte,
        PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly,
        16 * 1024,
        16 * 1024);

    private static async Task StallAfterHelloAsync(
        NamedPipeServerStream server,
        CancellationToken cancellationToken,
        TaskCompletionSource<bool>? helloReceived = null)
    {
        try
        {
            await server.WaitForConnectionAsync(cancellationToken);
            _ = await HerdrOpsReviewCommandJson.ReadFrameAsync(
                server,
                cancellationToken);
            helloReceived?.TrySetResult(true);
            await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
        }
    }

    private static async Task StallAfterExecuteAsync(
        NamedPipeServerStream server,
        CancellationToken cancellationToken)
    {
        try
        {
            await server.WaitForConnectionAsync(cancellationToken);
            var hello = await HerdrOpsReviewCommandJson.ReadFrameAsync(
                server,
                cancellationToken);
            await HerdrOpsReviewCommandJson.WriteFrameAsync(
                server,
                HerdrOpsReviewCommandJson.CreateEnvelope(
                    HerdrOpsReviewCommandProtocol.MessageTypes.HelloAccepted,
                    DateTimeOffset.UtcNow,
                    HerdrOpsReviewCommandProtocol.CoreSource,
                    hello.CorrelationId,
                    new HerdrOpsReviewCommandHelloAccepted(
                        "stalled-test-server",
                        HerdrOpsReviewCommandProtocol.AuthorizationScope)),
                cancellationToken);
            _ = await HerdrOpsReviewCommandJson.ReadFrameAsync(
                server,
                cancellationToken);
            await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
        }
    }

    private static async Task ObserveConnectionWithoutHelloAsync(
        NamedPipeServerStream server,
        CancellationToken cancellationToken,
        TaskCompletionSource<bool> connected,
        TaskCompletionSource<bool> firstByteObserved)
    {
        try
        {
            await server.WaitForConnectionAsync(cancellationToken);
            connected.TrySetResult(true);
            using var readTimeout = CancellationTokenSource.CreateLinkedTokenSource(
                cancellationToken);
            readTimeout.CancelAfter(TimeSpan.FromSeconds(1));
            var buffer = new byte[1];
            var bytesRead = await server.ReadAsync(
                buffer.AsMemory(0, 1),
                readTimeout.Token);
            firstByteObserved.TrySetResult(bytesRead > 0);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
        }
        catch (OperationCanceledException)
        {
            firstByteObserved.TrySetResult(false);
        }
        catch (IOException)
        {
            firstByteObserved.TrySetResult(false);
        }
    }

    private static async Task WaitForHandlerCallsAsync(
        Func<int> observedCalls,
        int expectedCalls)
    {
        var started = Stopwatch.GetTimestamp();
        while (observedCalls() < expectedCalls)
        {
            if (Stopwatch.GetElapsedTime(started) >= TimeSpan.FromSeconds(5))
            {
                Assert.Fail(
                    $"Expected at least {expectedCalls} handler call(s), found {observedCalls()}.");
            }

            await Task.Delay(TimeSpan.FromMilliseconds(10));
        }
    }

    private static async Task WaitForCountAsync(
        Func<int> observedCount,
        int expectedCount,
        string description)
    {
        var started = Stopwatch.GetTimestamp();
        while (observedCount() < expectedCount)
        {
            if (Stopwatch.GetElapsedTime(started) >= TimeSpan.FromSeconds(5))
            {
                Assert.Fail(
                    $"Expected {expectedCount} {description}, found {observedCount()}.");
            }

            await Task.Delay(TimeSpan.FromMilliseconds(10));
        }
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
}
