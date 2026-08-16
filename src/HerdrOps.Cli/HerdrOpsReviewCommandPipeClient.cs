using System.IO.Pipes;
using System.Security.Principal;
using HerdrOps.Contracts.ReviewIpc;

namespace HerdrOps.Cli;

public sealed record HerdrOpsReviewCommandCliPipeOptions(
    string PipeName,
    TimeSpan Timeout)
{
    public static HerdrOpsReviewCommandCliPipeOptions ForCurrentUser(
        TimeSpan timeout)
    {
        var userSid = WindowsIdentity.GetCurrent().User?.Value;
        if (string.IsNullOrWhiteSpace(userSid))
        {
            throw new HerdrOpsReviewCommandProtocolException(
                "The current Windows user SID is unavailable for review-command IPC.");
        }

        return new HerdrOpsReviewCommandCliPipeOptions(
            HerdrOpsReviewCommandPipeName.FromUserScope(userSid),
            timeout);
    }
}

public sealed class HerdrOpsReviewCommandPipeClient
{
    public const PipeOptions RequiredPipeOptions =
        PipeOptions.Asynchronous |
        PipeOptions.CurrentUserOnly;

    internal const int ServerProcessValidationConcurrencyLimit = 2;

    private static readonly SemaphoreSlim ServerProcessValidationBudget =
        new(
            ServerProcessValidationConcurrencyLimit,
            ServerProcessValidationConcurrencyLimit);

    private readonly HerdrOpsReviewCommandCliPipeOptions _options;
    private readonly TimeProvider _timeProvider;
    private readonly Action<NamedPipeClientStream> _serverProcessValidator;
    private readonly string _clientInstanceId = Guid.NewGuid().ToString("N");

    public HerdrOpsReviewCommandPipeClient(
        HerdrOpsReviewCommandCliPipeOptions options,
        TimeProvider? timeProvider = null)
        : this(
            options,
            timeProvider,
            pipe => HerdrOpsReviewServerProcessIdentityReader.ReadAndValidate(pipe))
    {
    }

    internal HerdrOpsReviewCommandPipeClient(
        HerdrOpsReviewCommandCliPipeOptions options,
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
            HerdrOpsReviewCommandProtocol.CliSource,
            helloCorrelationId,
            new HerdrOpsReviewCommandHello(
                HerdrOpsReviewCommandProtocol.CliClientRole,
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
            HerdrOpsReviewCommandProtocol.MessageTypes.Execute,
            _timeProvider.GetUtcNow(),
            HerdrOpsReviewCommandProtocol.CliSource,
            request.CommandId,
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
            HerdrOpsReviewCommandProtocol.MessageTypes.Result,
            request.CommandId);
        return HerdrOpsReviewCommandJson
            .DeserializePayload<HerdrOpsReviewCommandResult>(resultEnvelope);
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
        phaseDeadline.CancelAfter(_options.Timeout);
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

    private static HerdrOpsReviewCommandCliPipeOptions ValidateOptions(
        HerdrOpsReviewCommandCliPipeOptions options)
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

        if (options.Timeout < TimeSpan.FromMilliseconds(100) ||
            options.Timeout > TimeSpan.FromMinutes(1))
        {
            throw new ArgumentOutOfRangeException(
                nameof(options),
                "The review-command timeout must be from 100 milliseconds through one minute.");
        }

        return options;
    }
}
