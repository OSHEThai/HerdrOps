using System.Collections.Concurrent;
using System.IO.Pipes;
using System.Security.Principal;
using HerdrOps.Contracts.ComplianceDiagnosticExport;

namespace HerdrOps.Infrastructure.ComplianceDiagnosticExport;

public sealed record ComplianceDiagnosticExportPipeServerOptions(
    string PipeName,
    int MaximumFrameBytes = ComplianceDiagnosticExportProtocol.MaximumFrameBytes,
    int MaximumClients = 4)
{
    public static ComplianceDiagnosticExportPipeServerOptions ForCurrentUser()
    {
        var userSid = WindowsIdentity.GetCurrent().User?.Value;
        if (string.IsNullOrWhiteSpace(userSid))
        {
            throw new ComplianceDiagnosticExportProtocolException(
                "The current Windows user SID is unavailable for compliance diagnostic IPC.");
        }

        return new ComplianceDiagnosticExportPipeServerOptions(
            ComplianceDiagnosticExportPipeName.FromUserScope(userSid));
    }
}

public sealed class ComplianceDiagnosticExportPipeServer
{
    public const PipeOptions RequiredPipeOptions =
        PipeOptions.Asynchronous |
        PipeOptions.WriteThrough |
        PipeOptions.CurrentUserOnly;

    private readonly object _sync = new();
    private readonly ComplianceDiagnosticExportPipeServerOptions _options;
    private readonly Func<
        ComplianceDiagnosticExportRequest,
        CancellationToken,
        ValueTask<ComplianceDiagnosticExportResponse>> _handler;
    private readonly SemaphoreSlim _clientSlots;
    private readonly ConcurrentDictionary<long, Task> _clientTasks = new();
    private readonly TaskCompletionSource _ready = new(
        TaskCreationOptions.RunContinuationsAsynchronously);
    private long _nextClientId;
    private bool _running;

    public ComplianceDiagnosticExportPipeServer(
        ComplianceDiagnosticExportPipeServerOptions options,
        Func<
            ComplianceDiagnosticExportRequest,
            CancellationToken,
            ValueTask<ComplianceDiagnosticExportResponse>> handler)
    {
        _options = ValidateOptions(options);
        _handler = handler ?? throw new ArgumentNullException(nameof(handler));
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
                throw new InvalidOperationException(
                    "The compliance diagnostic export IPC server is already running.");
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
                            "A duplicate compliance diagnostic client identifier was allocated.");
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
            ComplianceDiagnosticExportRequest request;
            try
            {
                var frame = await ComplianceDiagnosticExportJson
                    .ReadFrameAsync(stream, cancellationToken, _options.MaximumFrameBytes)
                    .ConfigureAwait(false);
                request = ComplianceDiagnosticExportJson.DeserializeRequest(frame);
            }
            catch (EndOfStreamException)
            {
                return;
            }
            catch (ComplianceDiagnosticExportProtocolException)
            {
                return;
            }

            ComplianceDiagnosticExportResponse response;
            try
            {
                response = await _handler(request, cancellationToken).ConfigureAwait(false);
                ComplianceDiagnosticExportJson.ValidateResponse(response);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                return;
            }
            catch (Exception exception) when (
                exception is ArgumentException or
                    IOException or
                    InvalidOperationException or
                    UnauthorizedAccessException)
            {
                response = new ComplianceDiagnosticExportResponse(
                    ComplianceDiagnosticExportProtocol.Version,
                    ComplianceDiagnosticExportProtocol.MessageTypes.Rejected,
                    DateTimeOffset.UtcNow,
                    ComplianceDiagnosticExportProtocol.CoreSource,
                    request.CorrelationId,
                    Accepted: false,
                    ComplianceDiagnosticExportProtocol.ResultCodes.ExportFailed,
                    ComplianceDiagnosticExportProtocol.Messages.RejectedInternal,
                    RecordCount: null,
                    ByteCount: null,
                    OutputSha256: null);
            }

            var responseBytes = ComplianceDiagnosticExportJson.SerializeResponse(response);
            await ComplianceDiagnosticExportJson
                .WriteFrameAsync(stream, responseBytes, cancellationToken, _options.MaximumFrameBytes)
                .ConfigureAwait(false);
        }
    }

    private async Task ObserveClientAsync(long clientId, Task clientTask)
    {
        try
        {
            await clientTask.ConfigureAwait(false);
        }
        catch (Exception) when (clientTask.IsFaulted)
        {
            // The client connection is isolated; the accept loop remains available.
        }
        finally
        {
            _clientTasks.TryRemove(clientId, out _);
            _clientSlots.Release();
        }
    }

    private static ComplianceDiagnosticExportPipeServerOptions ValidateOptions(
        ComplianceDiagnosticExportPipeServerOptions options)
    {
        ArgumentNullException.ThrowIfNull(options);
        if (string.IsNullOrWhiteSpace(options.PipeName) ||
            options.PipeName.Length > 128 ||
            options.PipeName.Contains('\\', StringComparison.Ordinal) ||
            options.PipeName.Contains('/', StringComparison.Ordinal))
        {
            throw new ArgumentException(
                "The compliance diagnostic pipe name must contain 1 to 128 non-path characters.",
                nameof(options));
        }

        if (options.MaximumFrameBytes is < 1024 or > ComplianceDiagnosticExportProtocol.MaximumFrameBytes)
        {
            throw new ArgumentOutOfRangeException(nameof(options));
        }

        if (options.MaximumClients is < 1 or > 16)
        {
            throw new ArgumentOutOfRangeException(nameof(options));
        }

        return options;
    }
}
