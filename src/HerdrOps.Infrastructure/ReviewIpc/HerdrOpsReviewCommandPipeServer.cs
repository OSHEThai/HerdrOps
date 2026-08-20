using System.Collections.Concurrent;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.Principal;
using HerdrOps.Contracts.ReviewIpc;
using Microsoft.Data.Sqlite;

namespace HerdrOps.Infrastructure.ReviewIpc;

public sealed record HerdrOpsReviewCommandPipeServerOptions(
    string PipeName,
    int MaximumFrameBytes = HerdrOpsReviewCommandProtocol.MaximumFrameBytes,
    int MaximumClients = 8)
{
    public TimeSpan HandshakeTimeout { get; init; } = TimeSpan.FromSeconds(5);

    public TimeSpan OperationTimeout { get; init; } = TimeSpan.FromSeconds(5);

    public int MaximumDetachedDelegateConcurrency { get; init; } = 4;

    public static HerdrOpsReviewCommandPipeServerOptions ForCurrentUser()
    {
        var userSid = WindowsIdentity.GetCurrent().User?.Value;
        if (string.IsNullOrWhiteSpace(userSid))
        {
            throw new HerdrOpsReviewCommandProtocolException(
                "The current Windows user SID is unavailable for review-command IPC.");
        }

        return new HerdrOpsReviewCommandPipeServerOptions(
            HerdrOpsReviewCommandPipeName.FromUserScope(userSid));
    }
}

public sealed class HerdrOpsReviewCommandPipeServer
{
    public const PipeOptions RequiredPipeOptions =
        PipeOptions.Asynchronous |
        PipeOptions.WriteThrough |
        PipeOptions.CurrentUserOnly;

    private readonly object _sync = new();
    private readonly HerdrOpsReviewCommandPipeServerOptions _options;
    private readonly Func<
        HerdrOpsReviewCommandRequest,
        Guid,
        CancellationToken,
        ValueTask<HerdrOpsReviewCommandResult>> _handler;
    private readonly Func<
        HerdrOpsReviewCapabilitiesRequest,
        Guid,
        CancellationToken,
        ValueTask<HerdrOpsReviewCapabilitiesResult>>? _capabilitiesHandler;
    private readonly Func<string, uint, CancellationToken, ValueTask<bool>>?
        _clientActorAuthorizer;
    private readonly TimeProvider _timeProvider;
    private readonly string _serverInstanceId = Guid.NewGuid().ToString("N");
    private readonly SemaphoreSlim _clientSlots;
    private readonly SemaphoreSlim _detachedDelegateSlots;
    private readonly ConcurrentDictionary<long, Task> _clientTasks = new();
    private readonly ConcurrentDictionary<Task, byte> _detachedDelegateTasks = new();
    private readonly TaskCompletionSource _ready = new(
        TaskCreationOptions.RunContinuationsAsynchronously);
    private long _nextClientId;
    private bool _running;

    internal HerdrOpsReviewCommandPipeServer(
        HerdrOpsReviewCommandPipeServerOptions options,
        Func<
            HerdrOpsReviewCommandRequest,
            Guid,
            CancellationToken,
            ValueTask<HerdrOpsReviewCommandResult>> handler,
        TimeProvider? timeProvider = null)
    {
        _options = ValidateOptions(options);
        _handler = handler ?? throw new ArgumentNullException(nameof(handler));
        _timeProvider = timeProvider ?? TimeProvider.System;
        _clientSlots = new SemaphoreSlim(_options.MaximumClients, _options.MaximumClients);
        _detachedDelegateSlots = new SemaphoreSlim(
            _options.MaximumDetachedDelegateConcurrency,
            _options.MaximumDetachedDelegateConcurrency);
    }

    public HerdrOpsReviewCommandPipeServer(
        HerdrOpsReviewCommandPipeServerOptions options,
        Func<
            HerdrOpsReviewCommandRequest,
            Guid,
            CancellationToken,
            ValueTask<HerdrOpsReviewCommandResult>> handler,
        Func<
            HerdrOpsReviewCapabilitiesRequest,
            Guid,
            CancellationToken,
            ValueTask<HerdrOpsReviewCapabilitiesResult>> capabilitiesHandler,
        Func<string, uint, CancellationToken, ValueTask<bool>> clientActorAuthorizer,
        TimeProvider? timeProvider = null)
    {
        _options = ValidateOptions(options);
        _handler = handler ?? throw new ArgumentNullException(nameof(handler));
        _capabilitiesHandler = capabilitiesHandler ??
            throw new ArgumentNullException(nameof(capabilitiesHandler));
        _clientActorAuthorizer = clientActorAuthorizer ??
            throw new ArgumentNullException(nameof(clientActorAuthorizer));
        _timeProvider = timeProvider ?? TimeProvider.System;
        _clientSlots = new SemaphoreSlim(_options.MaximumClients, _options.MaximumClients);
        _detachedDelegateSlots = new SemaphoreSlim(
            _options.MaximumDetachedDelegateConcurrency,
            _options.MaximumDetachedDelegateConcurrency);
    }

    public Task Ready => _ready.Task;

    public int ActiveClientCount => _clientTasks.Count;

    public async Task RunAsync(CancellationToken cancellationToken)
    {
        lock (_sync)
        {
            if (_running)
            {
                throw new InvalidOperationException(
                    "The review-command IPC server is already running.");
            }

            _running = true;
        }

        try
        {
            while (true)
            {
                cancellationToken.ThrowIfCancellationRequested();
                await _clientSlots.WaitAsync(cancellationToken).ConfigureAwait(false);
                var slotTransferred = false;
                NamedPipeServerStream? listener = null;
                try
                {
                    listener = CreateServerStream();
                    _ready.TrySetResult();
                    await listener.WaitForConnectionAsync(cancellationToken).ConfigureAwait(false);
                    var clientId = Interlocked.Increment(ref _nextClientId);
                    var clientStream = listener;
                    listener = null;
                    var clientTask = HandleClientAsync(clientStream, cancellationToken);
                    if (!_clientTasks.TryAdd(clientId, clientTask))
                    {
                        await clientStream.DisposeAsync().ConfigureAwait(false);
                        throw new InvalidOperationException(
                            "A duplicate review-command client identifier was allocated.");
                    }

                    slotTransferred = true;
                    _ = ObserveClientAsync(clientId, clientTask);
                }
                finally
                {
                    if (listener is not null)
                    {
                        await listener.DisposeAsync().ConfigureAwait(false);
                    }

                    if (!slotTransferred)
                    {
                        _clientSlots.Release();
                    }
                }
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
        }
        finally
        {
            lock (_sync)
            {
                _running = false;
            }

            await Task.WhenAll(_clientTasks.Values).ConfigureAwait(false);
            await AwaitDetachedDelegatesAsync().ConfigureAwait(false);
        }
    }

    internal NamedPipeServerStream CreateServerStream() => new(
        _options.PipeName,
        PipeDirection.InOut,
        _options.MaximumClients,
        PipeTransmissionMode.Byte,
        RequiredPipeOptions,
        inBufferSize: 16 * 1024,
        outBufferSize: 16 * 1024);

    private async Task HandleClientAsync(
        NamedPipeServerStream stream,
        CancellationToken cancellationToken)
    {
        try
        {
            await HandleClientCoreAsync(stream, cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
        }
    }

    private async Task HandleClientCoreAsync(
        NamedPipeServerStream stream,
        CancellationToken cancellationToken)
    {
        await using (stream.ConfigureAwait(false))
        {
            HerdrOpsReviewCommandEnvelope helloEnvelope;
            try
            {
                var hello = await ReadFrameWithDeadlineAsync(
                        stream,
                        cancellationToken,
                        _options.HandshakeTimeout)
                    .ConfigureAwait(false);
                if (hello is null)
                {
                    return;
                }

                helloEnvelope = hello;
            }
            catch (EndOfStreamException)
            {
                return;
            }
            catch (HerdrOpsReviewCommandProtocolException)
            {
                return;
            }

            var handshakeError = ValidateHello(helloEnvelope);
            if (handshakeError is not null)
            {
                await SendErrorAsync(
                        stream,
                        helloEnvelope.CorrelationId,
                        handshakeError,
                        _options.HandshakeTimeout,
                        cancellationToken)
                    .ConfigureAwait(false);
                return;
            }

            var accepted = HerdrOpsReviewCommandJson.CreateEnvelope(
                HerdrOpsReviewCommandProtocol.MessageTypes.HelloAccepted,
                _timeProvider.GetUtcNow(),
                HerdrOpsReviewCommandProtocol.CoreSource,
                helloEnvelope.CorrelationId,
                new HerdrOpsReviewCommandHelloAccepted(
                    _serverInstanceId,
                    HerdrOpsReviewCommandProtocol.AuthorizationScope));
            await WriteFrameWithDeadlineAsync(
                    stream,
                    accepted,
                    _options.HandshakeTimeout,
                    cancellationToken,
                    _options.MaximumFrameBytes)
                .ConfigureAwait(false);

            using var operationDeadline = CreateOperationDeadline(cancellationToken);
            HerdrOpsReviewCommandEnvelope executeEnvelope;
            try
            {
                var execute = await ReadFrameWithOperationDeadlineAsync(
                        stream,
                        operationDeadline)
                    .ConfigureAwait(false);
                if (execute is null)
                {
                    return;
                }

                executeEnvelope = execute;
            }
            catch (EndOfStreamException)
            {
                return;
            }
            catch (HerdrOpsReviewCommandProtocolException exception)
            {
                await SendErrorAsync(
                        stream,
                        helloEnvelope.CorrelationId,
                        Error(
                            HerdrOpsReviewCommandProtocol.ErrorCodes.InvalidMessage,
                            exception.Message),
                        operationDeadline)
                    .ConfigureAwait(false);
                return;
            }

            var executeError = ValidateOperation(executeEnvelope, helloEnvelope.Source);
            if (executeError is not null)
            {
                await SendErrorAsync(
                        stream,
                        executeEnvelope.CorrelationId,
                        executeError,
                        operationDeadline)
                    .ConfigureAwait(false);
                return;
            }

            if (string.Equals(
                    executeEnvelope.MessageType,
                    HerdrOpsReviewCommandProtocol.MessageTypes.Capabilities,
                    StringComparison.Ordinal))
            {
                await HandleCapabilitiesAsync(
                        stream,
                        executeEnvelope,
                        ReadClientProcessId(stream),
                        operationDeadline)
                    .ConfigureAwait(false);
                return;
            }

            HerdrOpsReviewCommandRequest request;
            try
            {
                request = HerdrOpsReviewCommandJson
                    .DeserializePayload<HerdrOpsReviewCommandRequest>(executeEnvelope);
                if (request.CommandId == Guid.Empty ||
                    request.CommandId != executeEnvelope.CorrelationId)
                {
                    throw new HerdrOpsReviewCommandProtocolException(
                        "The review command ID must be non-empty and equal the envelope correlation ID.");
                }
            }
            catch (HerdrOpsReviewCommandProtocolException exception)
            {
                await SendErrorAsync(
                        stream,
                        executeEnvelope.CorrelationId,
                        Error(
                            HerdrOpsReviewCommandProtocol.ErrorCodes.InvalidMessage,
                            exception.Message),
                        operationDeadline)
                    .ConfigureAwait(false);
                return;
            }

            bool isAuthorized;
            try
            {
                isAuthorized = await IsClientActorAuthorizedAsync(
                        request.ReviewerActorId,
                        ReadClientProcessId(stream),
                        operationDeadline)
                    .ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (operationDeadline.IsCancellationRequested)
            {
                return;
            }

            if (!isAuthorized)
            {
                await SendErrorAsync(
                        stream,
                        executeEnvelope.CorrelationId,
                        Error(
                            HerdrOpsReviewCommandProtocol.ErrorCodes.UnauthorizedClient,
                            "The review actor is not bound to the connected Herdr pane process."),
                        operationDeadline)
                    .ConfigureAwait(false);
                return;
            }

            HerdrOpsReviewCommandResult result;
            try
            {
                result = await InvokeHandlerWithOperationDeadlineAsync(
                        operationDeadline,
                        token => _handler(
                            request,
                            executeEnvelope.CorrelationId,
                            token))
                    .ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (operationDeadline.IsCancellationRequested)
            {
                return;
            }
            catch (Exception exception) when (
                exception is ArgumentException or
                    InvalidOperationException or
                    IOException or
                    SqliteException)
            {
                await SendErrorAsync(
                        stream,
                        executeEnvelope.CorrelationId,
                        Error(
                            HerdrOpsReviewCommandProtocol.ErrorCodes.CoreUnavailable,
                            "Core could not evaluate the review command."),
                        operationDeadline)
                    .ConfigureAwait(false);
                return;
            }

            var resultEnvelope = HerdrOpsReviewCommandJson.CreateEnvelope(
                HerdrOpsReviewCommandProtocol.MessageTypes.Result,
                _timeProvider.GetUtcNow(),
                HerdrOpsReviewCommandProtocol.CoreSource,
                executeEnvelope.CorrelationId,
                result);
            await WriteFrameWithOperationDeadlineAsync(
                    stream,
                    resultEnvelope,
                    operationDeadline,
                    _options.MaximumFrameBytes)
                .ConfigureAwait(false);
        }
    }

    private async Task<HerdrOpsReviewCommandEnvelope?> ReadFrameWithDeadlineAsync(
        Stream stream,
        CancellationToken serverCancellationToken,
        TimeSpan timeout)
    {
        using var readCancellation = CancellationTokenSource.CreateLinkedTokenSource(
            serverCancellationToken);
        readCancellation.CancelAfter(timeout);
        try
        {
            return await HerdrOpsReviewCommandJson
                .ReadFrameAsync(stream, readCancellation.Token, _options.MaximumFrameBytes)
                .ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (serverCancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (OperationCanceledException) when (readCancellation.IsCancellationRequested)
        {
            return null;
        }
    }

    private async Task<HerdrOpsReviewCommandEnvelope?> ReadFrameWithOperationDeadlineAsync(
        Stream stream,
        OperationDeadline operationDeadline)
    {
        try
        {
            return await HerdrOpsReviewCommandJson
                .ReadFrameAsync(
                    stream,
                    operationDeadline.Token,
                    _options.MaximumFrameBytes)
                .ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (operationDeadline.IsCancellationRequested)
        {
            return null;
        }
    }

    private static HerdrOpsReviewCommandError? ValidateHello(
        HerdrOpsReviewCommandEnvelope envelope)
    {
        var envelopeError = ValidateClientEnvelope(
            envelope,
            HerdrOpsReviewCommandProtocol.MessageTypes.Hello);
        if (envelopeError is not null)
        {
            return envelopeError;
        }

        try
        {
            var hello = HerdrOpsReviewCommandJson
                .DeserializePayload<HerdrOpsReviewCommandHello>(envelope);
            if (!IsAuthorizedClient(hello.ClientRole, envelope.Source) ||
                string.IsNullOrWhiteSpace(hello.ClientInstanceId) ||
                hello.ClientInstanceId.Length > 128)
            {
                return Error(
                    HerdrOpsReviewCommandProtocol.ErrorCodes.UnauthorizedClient,
                    "Only a named HerdrOps App or CLI client is authorized for review commands.");
            }
        }
        catch (HerdrOpsReviewCommandProtocolException exception)
        {
            return Error(
                HerdrOpsReviewCommandProtocol.ErrorCodes.InvalidHandshake,
                exception.Message);
        }

        return null;
    }

    private static HerdrOpsReviewCommandError? ValidateOperation(
        HerdrOpsReviewCommandEnvelope envelope,
        string expectedSource)
    {
        if (!string.Equals(
                envelope.MessageType,
                HerdrOpsReviewCommandProtocol.MessageTypes.Execute,
                StringComparison.Ordinal) &&
            !string.Equals(
                envelope.MessageType,
                HerdrOpsReviewCommandProtocol.MessageTypes.Capabilities,
                StringComparison.Ordinal))
        {
            return Error(
                HerdrOpsReviewCommandProtocol.ErrorCodes.InvalidMessage,
                "Expected a review command or capability request.");
        }

        var error = ValidateClientEnvelope(envelope, envelope.MessageType);
        return error ?? (!string.Equals(envelope.Source, expectedSource, StringComparison.Ordinal)
            ? Error(
                HerdrOpsReviewCommandProtocol.ErrorCodes.UnauthorizedClient,
                "The review-command source changed after the handshake.")
            : null);
    }

    private async Task HandleCapabilitiesAsync(
        Stream stream,
        HerdrOpsReviewCommandEnvelope envelope,
        uint clientProcessId,
        OperationDeadline operationDeadline)
    {
        if (_capabilitiesHandler is null)
        {
            await SendErrorAsync(
                    stream,
                    envelope.CorrelationId,
                    Error(
                        HerdrOpsReviewCommandProtocol.ErrorCodes.CoreUnavailable,
                        "Core review capabilities are unavailable."),
                    operationDeadline)
                .ConfigureAwait(false);
            return;
        }

        HerdrOpsReviewCapabilitiesRequest request;
        try
        {
            request = HerdrOpsReviewCommandJson
                .DeserializePayload<HerdrOpsReviewCapabilitiesRequest>(envelope);
        }
        catch (HerdrOpsReviewCommandProtocolException exception)
        {
            await SendErrorAsync(
                    stream,
                    envelope.CorrelationId,
                    Error(
                        HerdrOpsReviewCommandProtocol.ErrorCodes.InvalidMessage,
                        exception.Message),
                    operationDeadline)
                .ConfigureAwait(false);
            return;
        }

        bool isAuthorized;
        try
        {
            isAuthorized = await IsClientActorAuthorizedAsync(
                    request.ReviewerActorId,
                    clientProcessId,
                    operationDeadline)
                .ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (operationDeadline.IsCancellationRequested)
        {
            return;
        }

        if (!isAuthorized)
        {
            await SendErrorAsync(
                    stream,
                    envelope.CorrelationId,
                    Error(
                        HerdrOpsReviewCommandProtocol.ErrorCodes.UnauthorizedClient,
                        "The review actor is not bound to the connected Herdr pane process."),
                    operationDeadline)
                .ConfigureAwait(false);
            return;
        }

        HerdrOpsReviewCapabilitiesResult result;
        try
        {
            result = await InvokeHandlerWithOperationDeadlineAsync(
                    operationDeadline,
                    token => _capabilitiesHandler(
                        request,
                        envelope.CorrelationId,
                        token))
                .ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (operationDeadline.IsCancellationRequested)
        {
            return;
        }
        catch (Exception exception) when (
                exception is ArgumentException or
                    InvalidOperationException or
                    IOException or
                    SqliteException)
        {
            await SendErrorAsync(
                    stream,
                    envelope.CorrelationId,
                    Error(
                        HerdrOpsReviewCommandProtocol.ErrorCodes.CoreUnavailable,
                        "Core could not evaluate review capabilities."),
                    operationDeadline)
                .ConfigureAwait(false);
            return;
        }

        var resultEnvelope = HerdrOpsReviewCommandJson.CreateEnvelope(
            HerdrOpsReviewCommandProtocol.MessageTypes.CapabilitiesResult,
            _timeProvider.GetUtcNow(),
            HerdrOpsReviewCommandProtocol.CoreSource,
            envelope.CorrelationId,
            result);
        await WriteFrameWithOperationDeadlineAsync(
                stream,
                resultEnvelope,
                operationDeadline,
                _options.MaximumFrameBytes)
            .ConfigureAwait(false);
    }

    private ValueTask<bool> IsClientActorAuthorizedAsync(
        string reviewerActorId,
        uint clientProcessId,
        OperationDeadline operationDeadline) =>
        _clientActorAuthorizer is null
            ? ValueTask.FromResult(true)
            : InvokeHandlerWithOperationDeadlineAsync(
                operationDeadline,
                token => _clientActorAuthorizer(
                    reviewerActorId,
                    clientProcessId,
                    token));

    private OperationDeadline CreateOperationDeadline(
        CancellationToken serverCancellationToken) =>
        new(serverCancellationToken, _options.OperationTimeout);

    private async ValueTask<TResult> InvokeHandlerWithOperationDeadlineAsync<TResult>(
        OperationDeadline operationDeadline,
        Func<CancellationToken, ValueTask<TResult>> handler)
    {
        await _detachedDelegateSlots
            .WaitAsync(operationDeadline.Token)
            .ConfigureAwait(false);

        Task<TResult> handlerTask;
        try
        {
            // ValueTask delegates are allowed to execute synchronously. Start the
            // invocation on the default scheduler so that a blocking delegate
            // cannot retain the client-serving continuation or its slot.
            handlerTask = Task.Run(
                async () => await handler(operationDeadline.Token).ConfigureAwait(false));
        }
        catch
        {
            _detachedDelegateSlots.Release();
            throw;
        }

        if (!_detachedDelegateTasks.TryAdd(handlerTask, 0))
        {
            _detachedDelegateSlots.Release();
            throw new InvalidOperationException(
                "The review-command delegate task could not be tracked.");
        }

        _ = handlerTask.ContinueWith(
            static (completedTask, state) =>
            {
                _ = completedTask.Exception;
                var server = (HerdrOpsReviewCommandPipeServer)state!;
                server._detachedDelegateTasks.TryRemove(completedTask, out _);
                server._detachedDelegateSlots.Release();
            },
            this,
            CancellationToken.None,
            TaskContinuationOptions.ExecuteSynchronously,
            TaskScheduler.Default);

        try
        {
            return await handlerTask
                .WaitAsync(operationDeadline.Token)
                .ConfigureAwait(false);
        }
        catch
        {
            operationDeadline.RetainDetachedTask(handlerTask);
            throw;
        }
    }

    private async Task AwaitDetachedDelegatesAsync()
    {
        while (!_detachedDelegateTasks.IsEmpty)
        {
            var tasks = _detachedDelegateTasks.Keys.ToArray();
            if (tasks.Length == 0)
            {
                continue;
            }

            try
            {
                await Task.WhenAll(tasks).ConfigureAwait(false);
            }
            catch
            {
                foreach (var task in tasks)
                {
                    _ = task.Exception;
                }
            }
        }
    }

    private sealed class OperationDeadline : IDisposable
    {
        private readonly CancellationTokenSource _source;
        private int _detachedTaskCount;
        private int _disposeRequested;
        private int _sourceDisposed;

        public OperationDeadline(
            CancellationToken serverCancellationToken,
            TimeSpan timeout)
        {
            _source = CancellationTokenSource.CreateLinkedTokenSource(
                serverCancellationToken);
            _source.CancelAfter(timeout);
        }

        public CancellationToken Token => _source.Token;

        public bool IsCancellationRequested => _source.IsCancellationRequested;

        public void RetainDetachedTask(Task task)
        {
            ArgumentNullException.ThrowIfNull(task);
            Interlocked.Increment(ref _detachedTaskCount);
            _ = task.ContinueWith(
                static (completedTask, state) =>
                {
                    _ = completedTask.Exception;
                    ((OperationDeadline)state!).DetachedTaskCompleted();
                },
                this,
                CancellationToken.None,
                TaskContinuationOptions.ExecuteSynchronously,
                TaskScheduler.Default);
        }

        public void Dispose()
        {
            Interlocked.Exchange(ref _disposeRequested, 1);
            TryDisposeSource();
        }

        private void DetachedTaskCompleted()
        {
            Interlocked.Decrement(ref _detachedTaskCount);
            TryDisposeSource();
        }

        private void TryDisposeSource()
        {
            if (Volatile.Read(ref _disposeRequested) == 0 ||
                Volatile.Read(ref _detachedTaskCount) != 0 ||
                Interlocked.Exchange(ref _sourceDisposed, 1) != 0)
            {
                return;
            }

            _source.Dispose();
        }
    }

    private static uint ReadClientProcessId(NamedPipeServerStream stream)
    {
        if (!GetNamedPipeClientProcessId(stream.SafePipeHandle, out var processId) ||
            processId == 0)
        {
            throw new IOException(
                "The review-command server could not resolve the connected client process.");
        }

        return processId;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetNamedPipeClientProcessId(
        Microsoft.Win32.SafeHandles.SafePipeHandle pipe,
        out uint clientProcessId);

    private static HerdrOpsReviewCommandError? ValidateClientEnvelope(
        HerdrOpsReviewCommandEnvelope envelope,
        string expectedMessageType)
    {
        if (envelope.ProtocolVersion != HerdrOpsReviewCommandProtocol.Version)
        {
            return Error(
                HerdrOpsReviewCommandProtocol.ErrorCodes.InvalidProtocolVersion,
                $"Protocol {envelope.ProtocolVersion} is unsupported; expected {HerdrOpsReviewCommandProtocol.Version}.");
        }

        if (!IsKnownClientSource(envelope.Source))
        {
            return Error(
                HerdrOpsReviewCommandProtocol.ErrorCodes.UnauthorizedClient,
                "Only the HerdrOps App or CLI source is authorized for review commands.");
        }

        if (!string.Equals(
                envelope.MessageType,
                expectedMessageType,
                StringComparison.Ordinal))
        {
            return Error(
                HerdrOpsReviewCommandProtocol.ErrorCodes.InvalidMessage,
                $"Expected review-command message '{expectedMessageType}'.");
        }

        return null;
    }

    private static bool IsAuthorizedClient(string clientRole, string source) =>
        (string.Equals(
             clientRole,
             HerdrOpsReviewCommandProtocol.AppClientRole,
             StringComparison.Ordinal) &&
         string.Equals(
             source,
             HerdrOpsReviewCommandProtocol.AppSource,
             StringComparison.Ordinal)) ||
        (string.Equals(
             clientRole,
             HerdrOpsReviewCommandProtocol.CliClientRole,
             StringComparison.Ordinal) &&
         string.Equals(
             source,
             HerdrOpsReviewCommandProtocol.CliSource,
             StringComparison.Ordinal));

    private static bool IsKnownClientSource(string source) =>
        string.Equals(
            source,
            HerdrOpsReviewCommandProtocol.AppSource,
            StringComparison.Ordinal) ||
        string.Equals(
            source,
            HerdrOpsReviewCommandProtocol.CliSource,
            StringComparison.Ordinal);

    private async ValueTask SendErrorAsync(
        Stream stream,
        Guid correlationId,
        HerdrOpsReviewCommandError error,
        TimeSpan timeout,
        CancellationToken cancellationToken)
    {
        var envelope = HerdrOpsReviewCommandJson.CreateEnvelope(
            HerdrOpsReviewCommandProtocol.MessageTypes.Error,
            _timeProvider.GetUtcNow(),
            HerdrOpsReviewCommandProtocol.CoreSource,
            correlationId,
            error);
        await WriteFrameWithDeadlineAsync(
                stream,
                envelope,
                timeout,
                cancellationToken,
                _options.MaximumFrameBytes)
            .ConfigureAwait(false);
    }

    private ValueTask SendErrorAsync(
        Stream stream,
        Guid correlationId,
        HerdrOpsReviewCommandError error,
        OperationDeadline operationDeadline)
    {
        var envelope = HerdrOpsReviewCommandJson.CreateEnvelope(
            HerdrOpsReviewCommandProtocol.MessageTypes.Error,
            _timeProvider.GetUtcNow(),
            HerdrOpsReviewCommandProtocol.CoreSource,
            correlationId,
            error);
        return WriteFrameWithOperationDeadlineAsync(
            stream,
            envelope,
            operationDeadline,
            _options.MaximumFrameBytes);
    }

    private static async ValueTask WriteFrameWithDeadlineAsync(
        Stream stream,
        HerdrOpsReviewCommandEnvelope envelope,
        TimeSpan timeout,
        CancellationToken serverCancellationToken,
        int maximumFrameBytes)
    {
        using var writeCancellation = CancellationTokenSource.CreateLinkedTokenSource(
            serverCancellationToken);
        writeCancellation.CancelAfter(timeout);
        try
        {
            await HerdrOpsReviewCommandJson
                .WriteFrameAsync(
                    stream,
                    envelope,
                    writeCancellation.Token,
                    maximumFrameBytes)
                .ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (serverCancellationToken.IsCancellationRequested)
        {
            throw;
        }
    }

    private static ValueTask WriteFrameWithOperationDeadlineAsync(
        Stream stream,
        HerdrOpsReviewCommandEnvelope envelope,
        OperationDeadline operationDeadline,
        int maximumFrameBytes) =>
        HerdrOpsReviewCommandJson.WriteFrameAsync(
            stream,
            envelope,
            operationDeadline.Token,
            maximumFrameBytes);

    private static HerdrOpsReviewCommandError Error(string code, string message) =>
        new(code, message);

    private async Task ObserveClientAsync(long clientId, Task clientTask)
    {
        try
        {
            await clientTask.ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
        }
        catch (IOException)
        {
        }
        finally
        {
            _clientTasks.TryRemove(clientId, out _);
            _clientSlots.Release();
        }
    }

    private static HerdrOpsReviewCommandPipeServerOptions ValidateOptions(
        HerdrOpsReviewCommandPipeServerOptions options)
    {
        ArgumentNullException.ThrowIfNull(options);
        if (string.IsNullOrWhiteSpace(options.PipeName) ||
            options.PipeName.Length > 128 ||
            options.PipeName.Contains('\\', StringComparison.Ordinal) ||
            options.PipeName.Contains('/', StringComparison.Ordinal))
        {
            throw new ArgumentException(
                "The review-command pipe name must contain 1 to 128 non-path characters.",
                nameof(options));
        }

        if (options.MaximumFrameBytes is < 1024 or
            > HerdrOpsReviewCommandProtocol.MaximumFrameBytes)
        {
            throw new ArgumentOutOfRangeException(
                nameof(options),
                $"The maximum review-command frame must be between 1024 and {HerdrOpsReviewCommandProtocol.MaximumFrameBytes} bytes.");
        }

        if (options.MaximumClients is < 1 or > 32)
        {
            throw new ArgumentOutOfRangeException(
                nameof(options),
                "The review-command client limit must be between 1 and 32.");
        }

        if (options.MaximumDetachedDelegateConcurrency is < 1 or > 32)
        {
            throw new ArgumentOutOfRangeException(
                nameof(options),
                "The detached review delegate limit must be between 1 and 32.");
        }

        ValidateReadDeadline(options.HandshakeTimeout, nameof(options.HandshakeTimeout));
        ValidateReadDeadline(options.OperationTimeout, nameof(options.OperationTimeout));

        return options;
    }

    private static void ValidateReadDeadline(TimeSpan timeout, string parameterName)
    {
        if (timeout <= TimeSpan.Zero || timeout > TimeSpan.FromMinutes(1))
        {
            throw new ArgumentOutOfRangeException(
                parameterName,
                "The review-command read deadline must be greater than zero and no more than one minute.");
        }
    }
}
