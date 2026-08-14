using System.Collections.Concurrent;
using System.IO.Pipes;
using System.Security.Principal;
using System.Threading.Channels;
using HerdrOps.Contracts.StateIpc;

namespace HerdrOps.Infrastructure.StateIpc;

public sealed record HerdrOpsStatePipeServerOptions(
    string PipeName,
    int MaximumFrameBytes = HerdrOpsStateIpcProtocol.MaximumFrameBytes,
    int MaximumPendingDeltasPerClient = 256,
    int MaximumClients = 16)
{
    public static HerdrOpsStatePipeServerOptions ForCurrentUser()
    {
        var userSid = WindowsIdentity.GetCurrent().User?.Value;
        if (string.IsNullOrWhiteSpace(userSid))
        {
            throw new HerdrOpsStateIpcProtocolException(
                "The current Windows user SID is unavailable for state IPC.");
        }

        return new HerdrOpsStatePipeServerOptions(
            HerdrOpsStatePipeName.FromUserScope(userSid));
    }
}

public sealed class HerdrOpsStatePipeServer
{
    public const PipeOptions RequiredPipeOptions =
        PipeOptions.Asynchronous |
        PipeOptions.WriteThrough |
        PipeOptions.CurrentUserOnly;

    private readonly object _sync = new();
    private readonly HerdrOpsStatePipeServerOptions _options;
    private readonly TimeProvider _timeProvider;
    private readonly string _serverInstanceId = Guid.NewGuid().ToString("N");
    private readonly ConcurrentDictionary<long, Task> _clientTasks = new();
    private readonly TaskCompletionSource _ready = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly Dictionary<long, ClientSubscription> _subscriptions = [];
    private readonly SemaphoreSlim _clientSlots;
    private HerdrOpsStateSnapshotPayload _currentSnapshot;
    private long _nextClientId;
    private bool _running;

    public HerdrOpsStatePipeServer(
        HerdrOpsStatePipeServerOptions options,
        HerdrOpsStateSnapshotPayload initialSnapshot,
        TimeProvider? timeProvider = null)
    {
        _options = ValidateOptions(options);
        _clientSlots = new SemaphoreSlim(_options.MaximumClients, _options.MaximumClients);
        _timeProvider = timeProvider ?? TimeProvider.System;
        ArgumentNullException.ThrowIfNull(initialSnapshot);
        HerdrSessionStateContractReducer.ValidateSnapshotPayload(initialSnapshot);
        _currentSnapshot = initialSnapshot with
        {
            State = HerdrSessionStateContractReducer.NormalizeAndValidate(initialSnapshot.State),
        };
        EnsureFrameFits(HerdrOpsStateIpcJson.CreateEnvelope(
            HerdrOpsStateIpcProtocol.MessageTypes.Snapshot,
            _currentSnapshot.State.LastIngestSequence,
            _timeProvider.GetUtcNow(),
            HerdrOpsStateIpcProtocol.CoreSource,
            Guid.NewGuid(),
            _currentSnapshot));
    }

    public Task Ready => _ready.Task;

    public int ConnectedClientCount
    {
        get
        {
            lock (_sync)
            {
                return _subscriptions.Count;
            }
        }
    }

    public HerdrOpsStateSnapshotPayload CurrentSnapshot
    {
        get
        {
            lock (_sync)
            {
                return _currentSnapshot;
            }
        }
    }

    public async Task RunAsync(CancellationToken cancellationToken)
    {
        lock (_sync)
        {
            if (_running)
            {
                throw new InvalidOperationException("The state IPC server is already running.");
            }

            _running = true;
        }

        try
        {
            while (true)
            {
                cancellationToken.ThrowIfCancellationRequested();
                await _clientSlots.WaitAsync(cancellationToken).ConfigureAwait(false);
                var slotTransferredToClient = false;
                NamedPipeServerStream? listener = null;
                try
                {
                    listener = CreateServerStream();
                    _ready.TrySetResult();
                    await listener.WaitForConnectionAsync(cancellationToken).ConfigureAwait(false);
                    var clientId = Interlocked.Increment(ref _nextClientId);
                    var clientStream = listener;
                    listener = null;
                    var clientTask = HandleClientAsync(clientId, clientStream, cancellationToken);
                    if (!_clientTasks.TryAdd(clientId, clientTask))
                    {
                        await clientStream.DisposeAsync().ConfigureAwait(false);
                        throw new InvalidOperationException(
                            "A duplicate state IPC client identifier was allocated.");
                    }

                    slotTransferredToClient = true;
                    _ = ObserveClientAsync(clientId, clientTask);
                }
                finally
                {
                    if (listener is not null)
                    {
                        await listener.DisposeAsync().ConfigureAwait(false);
                    }

                    if (!slotTransferredToClient)
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
            ClientSubscription[] subscriptions;
            lock (_sync)
            {
                _running = false;
                subscriptions = _subscriptions.Values.ToArray();
                _subscriptions.Clear();
            }

            foreach (var subscription in subscriptions)
            {
                subscription.Channel.Writer.TryComplete(
                    new OperationCanceledException("The state IPC server stopped."));
            }

            await Task.WhenAll(_clientTasks.Values).ConfigureAwait(false);
        }
    }

    public void PublishDelta(
        HerdrOpsStateDeltaPayload deltaPayload,
        HerdrOpsStateSnapshotPayload resultingSnapshot,
        Guid correlationId)
    {
        ArgumentNullException.ThrowIfNull(deltaPayload);
        ArgumentNullException.ThrowIfNull(resultingSnapshot);
        if (correlationId == Guid.Empty)
        {
            throw new ArgumentException(
                "The state delta correlation identifier cannot be empty.",
                nameof(correlationId));
        }

        ClientSubscription[] overflowed;
        lock (_sync)
        {
            var publication = ValidatePublicationLocked(
                deltaPayload,
                resultingSnapshot,
                correlationId);
            _currentSnapshot = resultingSnapshot with { State = publication.ExpectedState };
            overflowed = _subscriptions.Values
                .Where(subscription => !subscription.Channel.Writer.TryWrite(publication.DeltaEnvelope))
                .ToArray();
            foreach (var subscription in overflowed)
            {
                _subscriptions.Remove(subscription.ClientId);
            }
        }

        foreach (var subscription in overflowed)
        {
            subscription.Channel.Writer.TryComplete(
                new HerdrOpsStateIpcProtocolException(
                    "The state IPC client fell behind the bounded delta queue."));
        }
    }

    public void ValidateDelta(
        HerdrOpsStateDeltaPayload deltaPayload,
        HerdrOpsStateSnapshotPayload resultingSnapshot,
        Guid correlationId)
    {
        ArgumentNullException.ThrowIfNull(deltaPayload);
        ArgumentNullException.ThrowIfNull(resultingSnapshot);
        if (correlationId == Guid.Empty)
        {
            throw new ArgumentException(
                "The state delta correlation identifier cannot be empty.",
                nameof(correlationId));
        }

        lock (_sync)
        {
            _ = ValidatePublicationLocked(deltaPayload, resultingSnapshot, correlationId);
        }
    }

    public void PublishRuntimeHealth(
        HerdrOpsRuntimeHealthPayload payload,
        Guid correlationId)
    {
        ArgumentNullException.ThrowIfNull(payload);
        if (correlationId == Guid.Empty)
        {
            throw new ArgumentException(
                "The runtime-health correlation identifier cannot be empty.",
                nameof(correlationId));
        }

        ClientSubscription[] overflowed;
        lock (_sync)
        {
            HerdrSessionStateContractReducer.ValidateRuntimeHealthPayload(
                payload,
                _currentSnapshot.State);
            var envelope = HerdrOpsStateIpcJson.CreateEnvelope(
                HerdrOpsStateIpcProtocol.MessageTypes.RuntimeHealth,
                _currentSnapshot.State.LastIngestSequence,
                _timeProvider.GetUtcNow(),
                HerdrOpsStateIpcProtocol.CoreSource,
                correlationId,
                payload);
            EnsureFrameFits(envelope);
            _currentSnapshot = _currentSnapshot with
            {
                RuntimeHealth = payload.RuntimeHealth,
            };
            overflowed = _subscriptions.Values
                .Where(subscription => !subscription.Channel.Writer.TryWrite(envelope))
                .ToArray();
            foreach (var subscription in overflowed)
            {
                _subscriptions.Remove(subscription.ClientId);
            }
        }

        foreach (var subscription in overflowed)
        {
            subscription.Channel.Writer.TryComplete(
                new HerdrOpsStateIpcProtocolException(
                    "The state IPC client fell behind the bounded update queue."));
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
        long clientId,
        NamedPipeServerStream stream,
        CancellationToken cancellationToken)
    {
        await using (stream.ConfigureAwait(false))
        {
            HerdrOpsStateIpcEnvelope helloEnvelope;
            try
            {
                helloEnvelope = await HerdrOpsStateIpcJson
                    .ReadFrameAsync(stream, cancellationToken, _options.MaximumFrameBytes)
                    .ConfigureAwait(false);
            }
            catch (EndOfStreamException)
            {
                return;
            }

            if (!await ValidateHandshakeAsync(stream, helloEnvelope, cancellationToken).ConfigureAwait(false))
            {
                return;
            }

            var registration = RegisterClient(clientId);
            try
            {
                var accepted = HerdrOpsStateIpcJson.CreateEnvelope(
                    HerdrOpsStateIpcProtocol.MessageTypes.HelloAccepted,
                    registration.Snapshot.State.LastIngestSequence,
                    _timeProvider.GetUtcNow(),
                    HerdrOpsStateIpcProtocol.CoreSource,
                    helloEnvelope.CorrelationId,
                    new HerdrOpsStateIpcHelloAccepted(
                        _serverInstanceId,
                        HerdrOpsStateIpcProtocol.AuthorizationScope));
                await HerdrOpsStateIpcJson
                    .WriteFrameAsync(stream, accepted, cancellationToken, _options.MaximumFrameBytes)
                    .ConfigureAwait(false);

                var snapshot = HerdrOpsStateIpcJson.CreateEnvelope(
                    HerdrOpsStateIpcProtocol.MessageTypes.Snapshot,
                    registration.Snapshot.State.LastIngestSequence,
                    _timeProvider.GetUtcNow(),
                    HerdrOpsStateIpcProtocol.CoreSource,
                    helloEnvelope.CorrelationId,
                    registration.Snapshot);
                await HerdrOpsStateIpcJson
                    .WriteFrameAsync(stream, snapshot, cancellationToken, _options.MaximumFrameBytes)
                    .ConfigureAwait(false);

                using var clientLifetime = CancellationTokenSource.CreateLinkedTokenSource(
                    cancellationToken);
                var writeTask = WriteDeltasAsync(
                    stream,
                    registration.Subscription,
                    clientLifetime.Token);
                var disconnectTask = WaitForClientDisconnectAsync(
                    stream,
                    clientLifetime.Token);
                var completed = await Task.WhenAny(writeTask, disconnectTask).ConfigureAwait(false);
                try
                {
                    await completed.ConfigureAwait(false);
                }
                finally
                {
                    clientLifetime.Cancel();
                    await ObserveClientOperationAsync(writeTask).ConfigureAwait(false);
                    await ObserveClientOperationAsync(disconnectTask).ConfigureAwait(false);
                }
            }
            catch (OperationCanceledException)
            {
            }
            catch (IOException)
            {
                // A disconnected App is expected; a new connection receives a fresh snapshot.
            }
            finally
            {
                UnregisterClient(registration.Subscription);
            }
        }
    }

    private async Task WriteDeltasAsync(
        Stream stream,
        ClientSubscription subscription,
        CancellationToken cancellationToken)
    {
        await foreach (var delta in subscription.Channel.Reader
                           .ReadAllAsync(cancellationToken)
                           .ConfigureAwait(false))
        {
            await HerdrOpsStateIpcJson
                .WriteFrameAsync(stream, delta, cancellationToken, _options.MaximumFrameBytes)
                .ConfigureAwait(false);
        }
    }

    private static async Task WaitForClientDisconnectAsync(
        Stream stream,
        CancellationToken cancellationToken)
    {
        var buffer = new byte[1];
        var count = await stream.ReadAsync(buffer, cancellationToken).ConfigureAwait(false);
        if (count != 0)
        {
            throw new HerdrOpsStateIpcProtocolException(
                "The App sent an unexpected message after its state IPC handshake.");
        }
    }

    private static async Task ObserveClientOperationAsync(Task task)
    {
        try
        {
            await task.ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
        }
        catch (IOException)
        {
        }
    }

    private async ValueTask<bool> ValidateHandshakeAsync(
        Stream stream,
        HerdrOpsStateIpcEnvelope envelope,
        CancellationToken cancellationToken)
    {
        if (envelope.ProtocolVersion != HerdrOpsStateIpcProtocol.Version)
        {
            await SendErrorAsync(
                stream,
                envelope.CorrelationId,
                HerdrOpsStateIpcProtocol.ErrorCodes.InvalidProtocolVersion,
                $"Protocol {envelope.ProtocolVersion} is unsupported; expected {HerdrOpsStateIpcProtocol.Version}.",
                cancellationToken).ConfigureAwait(false);
            return false;
        }

        if (!string.Equals(envelope.Source, HerdrOpsStateIpcProtocol.AppSource, StringComparison.Ordinal))
        {
            await SendErrorAsync(
                stream,
                envelope.CorrelationId,
                HerdrOpsStateIpcProtocol.ErrorCodes.UnauthorizedClient,
                "Only the HerdrOps App client source is authorized.",
                cancellationToken).ConfigureAwait(false);
            return false;
        }

        if (!string.Equals(
                envelope.MessageType,
                HerdrOpsStateIpcProtocol.MessageTypes.Hello,
                StringComparison.Ordinal) ||
            envelope.Sequence != 0)
        {
            await SendErrorAsync(
                stream,
                envelope.CorrelationId,
                HerdrOpsStateIpcProtocol.ErrorCodes.InvalidHandshake,
                "The first state IPC message must be a sequence-zero hello.",
                cancellationToken).ConfigureAwait(false);
            return false;
        }

        HerdrOpsStateIpcHello hello;
        try
        {
            hello = HerdrOpsStateIpcJson.DeserializePayload<HerdrOpsStateIpcHello>(envelope);
        }
        catch (HerdrOpsStateIpcProtocolException exception)
        {
            await SendErrorAsync(
                stream,
                envelope.CorrelationId,
                HerdrOpsStateIpcProtocol.ErrorCodes.InvalidHandshake,
                exception.Message,
                cancellationToken).ConfigureAwait(false);
            return false;
        }

        if (!string.Equals(hello.ClientRole, HerdrOpsStateIpcProtocol.AppClientRole, StringComparison.Ordinal) ||
            string.IsNullOrWhiteSpace(hello.ClientInstanceId) ||
            hello.ClientInstanceId.Length > 128)
        {
            await SendErrorAsync(
                stream,
                envelope.CorrelationId,
                HerdrOpsStateIpcProtocol.ErrorCodes.UnauthorizedClient,
                "The state IPC client role or instance identifier is unauthorized.",
                cancellationToken).ConfigureAwait(false);
            return false;
        }

        return true;
    }

    private async ValueTask SendErrorAsync(
        Stream stream,
        Guid correlationId,
        string code,
        string message,
        CancellationToken cancellationToken)
    {
        var currentSequence = CurrentSnapshot.State.LastIngestSequence;
        var error = HerdrOpsStateIpcJson.CreateEnvelope(
            HerdrOpsStateIpcProtocol.MessageTypes.Error,
            currentSequence,
            _timeProvider.GetUtcNow(),
            HerdrOpsStateIpcProtocol.CoreSource,
            correlationId,
            new HerdrOpsStateIpcError(code, message));
        await HerdrOpsStateIpcJson
            .WriteFrameAsync(stream, error, cancellationToken, _options.MaximumFrameBytes)
            .ConfigureAwait(false);
    }

    private ClientRegistration RegisterClient(long clientId)
    {
        lock (_sync)
        {
            var channel = Channel.CreateBounded<HerdrOpsStateIpcEnvelope>(
                new BoundedChannelOptions(_options.MaximumPendingDeltasPerClient)
                {
                    AllowSynchronousContinuations = false,
                    FullMode = BoundedChannelFullMode.Wait,
                    SingleReader = true,
                    SingleWriter = false,
                });
            var subscription = new ClientSubscription(clientId, channel);
            _subscriptions.Add(clientId, subscription);
            return new ClientRegistration(_currentSnapshot, subscription);
        }
    }

    private void UnregisterClient(ClientSubscription subscription)
    {
        lock (_sync)
        {
            _subscriptions.Remove(subscription.ClientId);
        }

        subscription.Channel.Writer.TryComplete();
    }

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

    private ValidatedPublication ValidatePublicationLocked(
        HerdrOpsStateDeltaPayload deltaPayload,
        HerdrOpsStateSnapshotPayload resultingSnapshot,
        Guid correlationId)
    {
        var expectedState = HerdrSessionStateContractReducer.ApplyAndValidateDeltaPayload(
            _currentSnapshot.State,
            deltaPayload);
        HerdrSessionStateContractReducer.ValidateSnapshotPayload(resultingSnapshot);
        if (expectedState.LastIngestSequence != resultingSnapshot.State.LastIngestSequence ||
            !string.Equals(
                deltaPayload.ResultStateSha256,
                resultingSnapshot.StateSha256,
                StringComparison.Ordinal) ||
            deltaPayload.RuntimeHealth != resultingSnapshot.RuntimeHealth)
        {
            throw new HerdrOpsStateIpcProtocolException(
                "The resulting snapshot does not match the published state delta.");
        }

        var now = _timeProvider.GetUtcNow();
        var deltaEnvelope = HerdrOpsStateIpcJson.CreateEnvelope(
            HerdrOpsStateIpcProtocol.MessageTypes.Delta,
            deltaPayload.Delta.ToSequence,
            now,
            HerdrOpsStateIpcProtocol.CoreSource,
            correlationId,
            deltaPayload);
        EnsureFrameFits(deltaEnvelope);
        EnsureFrameFits(HerdrOpsStateIpcJson.CreateEnvelope(
            HerdrOpsStateIpcProtocol.MessageTypes.Snapshot,
            expectedState.LastIngestSequence,
            now,
            HerdrOpsStateIpcProtocol.CoreSource,
            correlationId,
            resultingSnapshot with { State = expectedState }));
        return new ValidatedPublication(expectedState, deltaEnvelope);
    }

    private void EnsureFrameFits(HerdrOpsStateIpcEnvelope envelope)
    {
        var bytes = HerdrOpsStateIpcJson.SerializeEnvelope(envelope);
        if (bytes.Length > _options.MaximumFrameBytes)
        {
            throw new HerdrOpsStateIpcProtocolException(
                $"The state IPC '{envelope.MessageType}' frame exceeded the {_options.MaximumFrameBytes}-byte limit.");
        }
    }

    private static HerdrOpsStatePipeServerOptions ValidateOptions(
        HerdrOpsStatePipeServerOptions options)
    {
        ArgumentNullException.ThrowIfNull(options);
        if (string.IsNullOrWhiteSpace(options.PipeName) ||
            options.PipeName.Length > 128 ||
            options.PipeName.Contains('\\', StringComparison.Ordinal) ||
            options.PipeName.Contains('/', StringComparison.Ordinal))
        {
            throw new ArgumentException(
                "The state IPC pipe name must contain 1 to 128 non-path characters.",
                nameof(options));
        }

        if (options.MaximumFrameBytes is < 1024 or > HerdrOpsStateIpcProtocol.MaximumFrameBytes)
        {
            throw new ArgumentOutOfRangeException(
                nameof(options),
                $"The maximum state IPC frame must be between 1024 and {HerdrOpsStateIpcProtocol.MaximumFrameBytes} bytes.");
        }

        if (options.MaximumPendingDeltasPerClient is < 1 or > 4096)
        {
            throw new ArgumentOutOfRangeException(
                nameof(options),
                "The pending state IPC delta limit must be between 1 and 4096.");
        }

        if (options.MaximumClients is < 1 or > 64)
        {
            throw new ArgumentOutOfRangeException(
                nameof(options),
                "The state IPC client limit must be between 1 and 64.");
        }

        return options;
    }

    private sealed record ClientSubscription(
        long ClientId,
        Channel<HerdrOpsStateIpcEnvelope> Channel);

    private sealed record ClientRegistration(
        HerdrOpsStateSnapshotPayload Snapshot,
        ClientSubscription Subscription);

    private sealed record ValidatedPublication(
        HerdrSessionStateContract ExpectedState,
        HerdrOpsStateIpcEnvelope DeltaEnvelope);
}
