using System.IO.Pipes;
using System.Security.Principal;
using HerdrOps.Contracts.ReviewIpc;

namespace HerdrOps.App.ReviewIpc;

public sealed record HerdrOpsReviewCommandPipeClientOptions(
    string PipeName,
    TimeSpan ConnectTimeout)
{
    public static HerdrOpsReviewCommandPipeClientOptions ForCurrentUser()
    {
        var userSid = WindowsIdentity.GetCurrent().User?.Value;
        if (string.IsNullOrWhiteSpace(userSid))
        {
            throw new HerdrOpsReviewCommandProtocolException(
                "The current Windows user SID is unavailable for review-command IPC.");
        }

        return new HerdrOpsReviewCommandPipeClientOptions(
            HerdrOpsReviewCommandPipeName.FromUserScope(userSid),
            TimeSpan.FromSeconds(5));
    }
}

public interface IHerdrOpsReviewCommandClient
{
    ValueTask<HerdrOpsReviewCommandResult> ExecuteAsync(
        HerdrOpsReviewCommandRequest request,
        CancellationToken cancellationToken = default);

    ValueTask<HerdrOpsReviewCapabilitiesResult> ReadCapabilitiesAsync(
        HerdrOpsReviewCapabilitiesRequest request,
        CancellationToken cancellationToken = default);
}

public sealed class HerdrOpsReviewCommandPipeClient : IHerdrOpsReviewCommandClient
{
    public const PipeOptions RequiredPipeOptions =
        PipeOptions.Asynchronous |
        PipeOptions.CurrentUserOnly;

    internal const int ServerProcessValidationConcurrencyLimit = 4;

    private static readonly SemaphoreSlim ServerProcessValidationBudget =
        new(
            ServerProcessValidationConcurrencyLimit,
            ServerProcessValidationConcurrencyLimit);

    private readonly HerdrOpsReviewCommandPipeClientOptions _options;
    private readonly TimeProvider _timeProvider;
    private readonly Action<NamedPipeClientStream> _serverProcessValidator;
    private readonly string _clientInstanceId = Guid.NewGuid().ToString("N");

    public HerdrOpsReviewCommandPipeClient(
        HerdrOpsReviewCommandPipeClientOptions options,
        TimeProvider? timeProvider = null)
        : this(
            options,
            timeProvider,
            pipe => HerdrOpsReviewServerProcessIdentityReader.ReadAndValidate(pipe))
    {
    }

    internal HerdrOpsReviewCommandPipeClient(
        HerdrOpsReviewCommandPipeClientOptions options,
        TimeProvider? timeProvider,
        Action<NamedPipeClientStream> serverProcessValidator)
    {
        _options = ValidateOptions(options);
        _timeProvider = timeProvider ?? TimeProvider.System;
        _serverProcessValidator = serverProcessValidator ??
            throw new ArgumentNullException(nameof(serverProcessValidator));
    }

    public async ValueTask<HerdrOpsReviewCommandResult> ExecuteAsync(
        HerdrOpsReviewCommandRequest request,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (request.CommandId == Guid.Empty)
        {
            throw new ArgumentException(
                "The review command ID cannot be empty.",
                nameof(request));
        }

        return await ExchangeAsync<
                HerdrOpsReviewCommandRequest,
                HerdrOpsReviewCommandResult>(
                request,
                request.CommandId,
                HerdrOpsReviewCommandProtocol.MessageTypes.Execute,
                HerdrOpsReviewCommandProtocol.MessageTypes.Result,
                cancellationToken)
            .ConfigureAwait(false);
    }

    public async ValueTask<HerdrOpsReviewCapabilitiesResult> ReadCapabilitiesAsync(
        HerdrOpsReviewCapabilitiesRequest request,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);
        return await ExchangeAsync<
                HerdrOpsReviewCapabilitiesRequest,
                HerdrOpsReviewCapabilitiesResult>(
                request,
                Guid.NewGuid(),
                HerdrOpsReviewCommandProtocol.MessageTypes.Capabilities,
                HerdrOpsReviewCommandProtocol.MessageTypes.CapabilitiesResult,
                cancellationToken)
            .ConfigureAwait(false);
    }

    private async ValueTask<TResponse> ExchangeAsync<TRequest, TResponse>(
        TRequest request,
        Guid correlationId,
        string requestMessageType,
        string responseMessageType,
        CancellationToken cancellationToken)
        where TRequest : class
        where TResponse : class
    {
        ArgumentNullException.ThrowIfNull(request);
        if (correlationId == Guid.Empty)
        {
            throw new ArgumentException(
                "The review-command correlation ID cannot be empty.",
                nameof(correlationId));
        }

        await using var pipe = CreateClientStream();
        using (var connectDeadline = CreatePhaseDeadline(cancellationToken))
        {
            try
            {
                await pipe.ConnectAsync(connectDeadline.Token).ConfigureAwait(false);
                await ValidateServerProcessAsync(
                        pipe,
                        connectDeadline.Token)
                    .ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                throw new OperationCanceledException(
                    "The review-command request was canceled by the caller.",
                    cancellationToken);
            }
            catch (OperationCanceledException exception) when (
                !cancellationToken.IsCancellationRequested &&
                connectDeadline.IsCancellationRequested)
            {
                throw new TimeoutException(
                    "Timed out connecting to the HerdrOps Core review-command service.",
                    exception);
            }
        }

        var helloCorrelationId = Guid.NewGuid();
        var hello = HerdrOpsReviewCommandJson.CreateEnvelope(
            HerdrOpsReviewCommandProtocol.MessageTypes.Hello,
            _timeProvider.GetUtcNow(),
            HerdrOpsReviewCommandProtocol.AppSource,
            helloCorrelationId,
            new HerdrOpsReviewCommandHello(
                HerdrOpsReviewCommandProtocol.AppClientRole,
                _clientInstanceId));
        HerdrOpsReviewCommandEnvelope helloResponse;
        using (var handshakeDeadline = CreatePhaseDeadline(cancellationToken))
        {
            try
            {
                await HerdrOpsReviewCommandJson
                    .WriteFrameAsync(pipe, hello, handshakeDeadline.Token)
                    .ConfigureAwait(false);
                helloResponse = await HerdrOpsReviewCommandJson
                    .ReadFrameAsync(pipe, handshakeDeadline.Token)
                    .ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                throw new OperationCanceledException(
                    "The review-command request was canceled by the caller.",
                    cancellationToken);
            }
            catch (OperationCanceledException exception) when (
                !cancellationToken.IsCancellationRequested &&
                handshakeDeadline.IsCancellationRequested)
            {
                throw new TimeoutException(
                    "Timed out during the HerdrOps Core review-command handshake.",
                    exception);
            }
        }

        ThrowIfError(helloResponse);
        ValidateServerEnvelope(
            helloResponse,
            HerdrOpsReviewCommandProtocol.MessageTypes.HelloAccepted,
            helloCorrelationId);
        var accepted = HerdrOpsReviewCommandJson
            .DeserializePayload<HerdrOpsReviewCommandHelloAccepted>(helloResponse);
        if (string.IsNullOrWhiteSpace(accepted.ServerInstanceId) ||
            !string.Equals(
                accepted.AuthorizationScope,
                HerdrOpsReviewCommandProtocol.AuthorizationScope,
                StringComparison.Ordinal))
        {
            throw new HerdrOpsReviewCommandProtocolException(
                "Core returned an invalid review-command authorization scope.");
        }

        var execute = HerdrOpsReviewCommandJson.CreateEnvelope(
            requestMessageType,
            _timeProvider.GetUtcNow(),
            HerdrOpsReviewCommandProtocol.AppSource,
            correlationId,
            request);
        HerdrOpsReviewCommandEnvelope resultEnvelope;
        using (var operationDeadline = CreatePhaseDeadline(cancellationToken))
        {
            try
            {
                await HerdrOpsReviewCommandJson
                    .WriteFrameAsync(pipe, execute, operationDeadline.Token)
                    .ConfigureAwait(false);
                resultEnvelope = await HerdrOpsReviewCommandJson
                    .ReadFrameAsync(pipe, operationDeadline.Token)
                    .ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                throw new OperationCanceledException(
                    "The review-command request was canceled by the caller.",
                    cancellationToken);
            }
            catch (OperationCanceledException exception) when (
                !cancellationToken.IsCancellationRequested &&
                operationDeadline.IsCancellationRequested)
            {
                throw new TimeoutException(
                    "Timed out waiting for the HerdrOps Core review-command operation.",
                    exception);
            }
        }

        ThrowIfError(resultEnvelope);
        ValidateServerEnvelope(
            resultEnvelope,
            responseMessageType,
            correlationId);
        return HerdrOpsReviewCommandJson
            .DeserializePayload<TResponse>(resultEnvelope);
    }

    private async Task ValidateServerProcessAsync(
        NamedPipeClientStream pipe,
        CancellationToken phaseCancellationToken)
    {
        await ServerProcessValidationBudget
            .WaitAsync(phaseCancellationToken)
            .ConfigureAwait(false);

        if (phaseCancellationToken.IsCancellationRequested)
        {
            ServerProcessValidationBudget.Release();
            phaseCancellationToken.ThrowIfCancellationRequested();
        }

        Task validationTask;
        try
        {
            // The validator is synchronous and cannot be force-cancelled. Keep it isolated
            // from the shared thread pool, while the process-wide budget bounds the number
            // of dedicated workers and retained pipe references.
            validationTask = Task.Factory.StartNew(
                () => _serverProcessValidator(pipe),
                CancellationToken.None,
                TaskCreationOptions.DenyChildAttach | TaskCreationOptions.LongRunning,
                TaskScheduler.Default);
        }
        catch
        {
            ServerProcessValidationBudget.Release();
            throw;
        }

        ObserveValidationCompletion(validationTask);
        await validationTask
            .WaitAsync(phaseCancellationToken)
            .ConfigureAwait(false);
    }

    private static void ObserveValidationCompletion(Task validationTask)
    {
        _ = validationTask.ContinueWith(
            static completedTask =>
            {
                try
                {
                    _ = completedTask.Exception;
                }
                finally
                {
                    ServerProcessValidationBudget.Release();
                }
            },
            CancellationToken.None,
            TaskContinuationOptions.ExecuteSynchronously,
            TaskScheduler.Default);
    }

    private CancellationTokenSource CreatePhaseDeadline(CancellationToken cancellationToken)
    {
        var phaseDeadline = CancellationTokenSource.CreateLinkedTokenSource(
            cancellationToken);
        phaseDeadline.CancelAfter(_options.ConnectTimeout);
        return phaseDeadline;
    }

    internal NamedPipeClientStream CreateClientStream() => new(
        ".",
        _options.PipeName,
        PipeDirection.InOut,
        RequiredPipeOptions);

    private static void ValidateServerEnvelope(
        HerdrOpsReviewCommandEnvelope envelope,
        string expectedMessageType,
        Guid expectedCorrelationId)
    {
        if (envelope.ProtocolVersion != HerdrOpsReviewCommandProtocol.Version ||
            !string.Equals(
                envelope.Source,
                HerdrOpsReviewCommandProtocol.CoreSource,
                StringComparison.Ordinal) ||
            !string.Equals(envelope.MessageType, expectedMessageType, StringComparison.Ordinal) ||
            envelope.CorrelationId != expectedCorrelationId)
        {
            throw new HerdrOpsReviewCommandProtocolException(
                $"The review-command server returned an invalid '{expectedMessageType}' envelope.");
        }
    }

    private static void ThrowIfError(HerdrOpsReviewCommandEnvelope envelope)
    {
        if (!string.Equals(
                envelope.MessageType,
                HerdrOpsReviewCommandProtocol.MessageTypes.Error,
                StringComparison.Ordinal))
        {
            return;
        }

        var error = HerdrOpsReviewCommandJson
            .DeserializePayload<HerdrOpsReviewCommandError>(envelope);
        throw new HerdrOpsReviewCommandProtocolException(
            $"Core rejected review-command IPC ({error.Code}): {error.Message}");
    }

    private static HerdrOpsReviewCommandPipeClientOptions ValidateOptions(
        HerdrOpsReviewCommandPipeClientOptions options)
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

        if (options.ConnectTimeout <= TimeSpan.Zero ||
            options.ConnectTimeout > TimeSpan.FromMinutes(1))
        {
            throw new ArgumentOutOfRangeException(
                nameof(options),
                "The review-command connection timeout must be between zero and one minute.");
        }

        return options;
    }
}
