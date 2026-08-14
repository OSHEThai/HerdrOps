using System.Collections.Concurrent;
using System.IO.Pipes;
using System.Security.Principal;
using HerdrOps.Contracts.SelfReport;

namespace HerdrOps.Infrastructure.StateIpc;

public sealed record HerdrOpsSelfReportPipeServerOptions(
    string PipeName,
    int MaximumFrameBytes = HerdrOpsSelfReportProtocol.MaximumFrameBytes,
    int MaximumClients = 16)
{
    public static HerdrOpsSelfReportPipeServerOptions ForCurrentUser()
    {
        var userSid = WindowsIdentity.GetCurrent().User?.Value;
        if (string.IsNullOrWhiteSpace(userSid))
        {
            throw new HerdrOpsSelfReportProtocolException(
                "The current Windows user SID is unavailable for self-report IPC.");
        }

        return new HerdrOpsSelfReportPipeServerOptions(
            HerdrOpsSelfReportPipeName.FromUserScope(userSid));
    }
}

public sealed class HerdrOpsSelfReportPipeServer
{
    public const PipeOptions RequiredPipeOptions =
        PipeOptions.Asynchronous |
        PipeOptions.WriteThrough |
        PipeOptions.CurrentUserOnly;

    private readonly object _sync = new();
    private readonly HerdrOpsSelfReportPipeServerOptions _options;
    private readonly Func<
        HerdrOpsSelfReportSubmission,
        Guid,
        CancellationToken,
        ValueTask<HerdrOpsSelfReportResult>> _handler;
    private readonly TimeProvider _timeProvider;
    private readonly SemaphoreSlim _clientSlots;
    private readonly ConcurrentDictionary<long, Task> _clientTasks = new();
    private readonly TaskCompletionSource _ready = new(
        TaskCreationOptions.RunContinuationsAsynchronously);
    private long _nextClientId;
    private bool _running;

    public HerdrOpsSelfReportPipeServer(
        HerdrOpsSelfReportPipeServerOptions options,
        Func<
            HerdrOpsSelfReportSubmission,
            Guid,
            CancellationToken,
            ValueTask<HerdrOpsSelfReportResult>> handler,
        TimeProvider? timeProvider = null)
    {
        _options = ValidateOptions(options);
        _handler = handler ?? throw new ArgumentNullException(nameof(handler));
        _timeProvider = timeProvider ?? TimeProvider.System;
        _clientSlots = new SemaphoreSlim(_options.MaximumClients, _options.MaximumClients);
    }

    public Task Ready => _ready.Task;

    public int ActiveClientCount => _clientTasks.Count;

    public async Task RunAsync(CancellationToken cancellationToken)
    {
        lock (_sync)
        {
            if (_running)
            {
                throw new InvalidOperationException("The self-report IPC server is already running.");
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
                    var clientTask = HandleClientAsync(clientStream, cancellationToken);
                    if (!_clientTasks.TryAdd(clientId, clientTask))
                    {
                        await clientStream.DisposeAsync().ConfigureAwait(false);
                        throw new InvalidOperationException(
                            "A duplicate self-report client identifier was allocated.");
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
            lock (_sync)
            {
                _running = false;
            }

            await Task.WhenAll(_clientTasks.Values).ConfigureAwait(false);
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
        await using (stream.ConfigureAwait(false))
        {
            HerdrOpsSelfReportEnvelope request;
            try
            {
                request = await HerdrOpsSelfReportJson
                    .ReadFrameAsync(stream, cancellationToken, _options.MaximumFrameBytes)
                    .ConfigureAwait(false);
            }
            catch (EndOfStreamException)
            {
                return;
            }
            catch (HerdrOpsSelfReportProtocolException)
            {
                return;
            }

            var rejection = ValidateRequestEnvelope(request);
            if (rejection is not null)
            {
                await SendResultAsync(stream, request.CorrelationId, rejection, cancellationToken)
                    .ConfigureAwait(false);
                return;
            }

            HerdrOpsSelfReportSubmission submission;
            try
            {
                submission = HerdrOpsSelfReportJson.DeserializeSubmission(request);
            }
            catch (HerdrOpsSelfReportProtocolException exception)
            {
                var invalidSchema = Rejected(
                    HerdrOpsSelfReportProtocol.ResultCodes.InvalidSchema,
                    exception.Message);
                await SendResultAsync(stream, request.CorrelationId, invalidSchema, cancellationToken)
                    .ConfigureAwait(false);
                return;
            }

            HerdrOpsSelfReportResult result;
            try
            {
                result = await _handler(submission, request.CorrelationId, cancellationToken)
                    .ConfigureAwait(false);
                HerdrOpsSelfReportJson.ValidateResult(result);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                return;
            }
            catch (Exception exception) when (
                exception is ArgumentException or InvalidOperationException or IOException)
            {
                result = Rejected(
                    HerdrOpsSelfReportProtocol.ResultCodes.InternalError,
                    "Core could not accept the self-report event.");
            }

            await SendResultAsync(stream, request.CorrelationId, result, cancellationToken)
                .ConfigureAwait(false);
        }
    }

    private HerdrOpsSelfReportResult? ValidateRequestEnvelope(
        HerdrOpsSelfReportEnvelope request)
    {
        if (request.ProtocolVersion != HerdrOpsSelfReportProtocol.Version)
        {
            return Rejected(
                HerdrOpsSelfReportProtocol.ResultCodes.InvalidProtocolVersion,
                $"Protocol {request.ProtocolVersion} is unsupported; expected {HerdrOpsSelfReportProtocol.Version}.");
        }

        if (!string.Equals(
                request.Source,
                HerdrOpsSelfReportProtocol.CliSource,
                StringComparison.Ordinal))
        {
            return Rejected(
                HerdrOpsSelfReportProtocol.ResultCodes.UnauthorizedClient,
                "Only the HerdrOps CLI source is authorized for self-report submission.");
        }

        if (!string.Equals(
                request.MessageType,
                HerdrOpsSelfReportProtocol.MessageTypes.Submit,
                StringComparison.Ordinal) ||
            request.Sequence != 0)
        {
            return Rejected(
                HerdrOpsSelfReportProtocol.ResultCodes.InvalidMessage,
                "A self-report request must be a sequence-zero submit message.");
        }

        return null;
    }

    private async ValueTask SendResultAsync(
        Stream stream,
        Guid correlationId,
        HerdrOpsSelfReportResult result,
        CancellationToken cancellationToken)
    {
        result = result with { CorrelationId = correlationId };
        HerdrOpsSelfReportJson.ValidateResult(result);
        var envelope = HerdrOpsSelfReportJson.CreateEnvelope(
            result.Accepted
                ? HerdrOpsSelfReportProtocol.MessageTypes.Accepted
                : HerdrOpsSelfReportProtocol.MessageTypes.Rejected,
            result.Sequence ?? 0,
            _timeProvider.GetUtcNow(),
            HerdrOpsSelfReportProtocol.CoreSource,
            correlationId,
            result);
        await HerdrOpsSelfReportJson
            .WriteFrameAsync(stream, envelope, cancellationToken, _options.MaximumFrameBytes)
            .ConfigureAwait(false);
    }

    private static HerdrOpsSelfReportResult Rejected(string code, string message) => new(
        false,
        code,
        message,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null);

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

    private static HerdrOpsSelfReportPipeServerOptions ValidateOptions(
        HerdrOpsSelfReportPipeServerOptions options)
    {
        ArgumentNullException.ThrowIfNull(options);
        if (string.IsNullOrWhiteSpace(options.PipeName) ||
            options.PipeName.Length > 128 ||
            options.PipeName.Contains('\\', StringComparison.Ordinal) ||
            options.PipeName.Contains('/', StringComparison.Ordinal))
        {
            throw new ArgumentException(
                "The self-report pipe name must contain 1 to 128 non-path characters.",
                nameof(options));
        }

        if (options.MaximumFrameBytes is < 1024 or > HerdrOpsSelfReportProtocol.MaximumFrameBytes)
        {
            throw new ArgumentOutOfRangeException(
                nameof(options),
                $"The maximum self-report frame must be between 1024 and {HerdrOpsSelfReportProtocol.MaximumFrameBytes} bytes.");
        }

        if (options.MaximumClients is < 1 or > 64)
        {
            throw new ArgumentOutOfRangeException(
                nameof(options),
                "The self-report client limit must be between 1 and 64.");
        }

        return options;
    }
}
