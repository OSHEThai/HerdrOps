using System.IO.Pipes;
using System.Security.Principal;
using HerdrOps.Contracts.SelfReport;

namespace HerdrOps.Cli;

public sealed record HerdrOpsSelfReportPipeClientOptions(
    string PipeName,
    int ConnectTimeoutMilliseconds = 5000,
    int MaximumFrameBytes = HerdrOpsSelfReportProtocol.MaximumFrameBytes)
{
    public static HerdrOpsSelfReportPipeClientOptions ForCurrentUser(
        int connectTimeoutMilliseconds = 5000)
    {
        var userSid = WindowsIdentity.GetCurrent().User?.Value;
        if (string.IsNullOrWhiteSpace(userSid))
        {
            throw new HerdrOpsSelfReportProtocolException(
                "The current Windows user SID is unavailable for self-report IPC.");
        }

        return new HerdrOpsSelfReportPipeClientOptions(
            HerdrOpsSelfReportPipeName.FromUserScope(userSid),
            connectTimeoutMilliseconds);
    }
}

public sealed class HerdrOpsSelfReportPipeClient
{
    public const PipeOptions RequiredPipeOptions =
        PipeOptions.Asynchronous |
        PipeOptions.WriteThrough |
        PipeOptions.CurrentUserOnly;

    private readonly HerdrOpsSelfReportPipeClientOptions _options;
    private readonly TimeProvider _timeProvider;

    public HerdrOpsSelfReportPipeClient(
        HerdrOpsSelfReportPipeClientOptions options,
        TimeProvider? timeProvider = null)
    {
        _options = ValidateOptions(options);
        _timeProvider = timeProvider ?? TimeProvider.System;
    }

    public async Task<HerdrOpsSelfReportResult> SubmitAsync(
        HerdrOpsSelfReportSubmission submission,
        Guid correlationId,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(submission);
        HerdrOpsSelfReportJson.ValidateSubmission(submission);
        if (correlationId == Guid.Empty)
        {
            throw new ArgumentException(
                "The self-report correlation identifier cannot be empty.",
                nameof(correlationId));
        }

        using var operationCancellation = CancellationTokenSource.CreateLinkedTokenSource(
            cancellationToken);
        operationCancellation.CancelAfter(_options.ConnectTimeoutMilliseconds);
        await using var pipe = new NamedPipeClientStream(
            ".",
            _options.PipeName,
            PipeDirection.InOut,
            RequiredPipeOptions);
        await pipe.ConnectAsync(operationCancellation.Token).ConfigureAwait(false);

        var request = HerdrOpsSelfReportJson.CreateEnvelope(
            HerdrOpsSelfReportProtocol.MessageTypes.Submit,
            0,
            _timeProvider.GetUtcNow(),
            HerdrOpsSelfReportProtocol.CliSource,
            correlationId,
            submission);
        await HerdrOpsSelfReportJson
            .WriteFrameAsync(pipe, request, operationCancellation.Token, _options.MaximumFrameBytes)
            .ConfigureAwait(false);
        var response = await HerdrOpsSelfReportJson
            .ReadFrameAsync(pipe, operationCancellation.Token, _options.MaximumFrameBytes)
            .ConfigureAwait(false);
        ValidateResponseEnvelope(response, correlationId);
        var result = HerdrOpsSelfReportJson.DeserializeResult(response);
        if (result.CorrelationId != correlationId)
        {
            throw new HerdrOpsSelfReportProtocolException(
                "The Core result correlation identifier does not match the request.");
        }

        var expectedMessageType = result.Accepted
            ? HerdrOpsSelfReportProtocol.MessageTypes.Accepted
            : HerdrOpsSelfReportProtocol.MessageTypes.Rejected;
        if (!string.Equals(response.MessageType, expectedMessageType, StringComparison.Ordinal))
        {
            throw new HerdrOpsSelfReportProtocolException(
                "The Core response message type does not match its result payload.");
        }

        if ((result.Accepted && response.Sequence != result.Sequence) ||
            (!result.Accepted && response.Sequence != 0))
        {
            throw new HerdrOpsSelfReportProtocolException(
                "The Core response sequence does not match its result payload.");
        }

        return result;
    }

    private static void ValidateResponseEnvelope(
        HerdrOpsSelfReportEnvelope response,
        Guid correlationId)
    {
        if (response.ProtocolVersion != HerdrOpsSelfReportProtocol.Version)
        {
            throw new HerdrOpsSelfReportProtocolException(
                $"Core returned unsupported protocol version {response.ProtocolVersion}.");
        }

        if (!string.Equals(
                response.Source,
                HerdrOpsSelfReportProtocol.CoreSource,
                StringComparison.Ordinal))
        {
            throw new HerdrOpsSelfReportProtocolException(
                "The self-report response source is not HerdrOps Core.");
        }

        if (response.CorrelationId != correlationId)
        {
            throw new HerdrOpsSelfReportProtocolException(
                "The self-report response correlation identifier does not match the request.");
        }

        if (!string.Equals(
                response.MessageType,
                HerdrOpsSelfReportProtocol.MessageTypes.Accepted,
                StringComparison.Ordinal) &&
            !string.Equals(
                response.MessageType,
                HerdrOpsSelfReportProtocol.MessageTypes.Rejected,
                StringComparison.Ordinal))
        {
            throw new HerdrOpsSelfReportProtocolException(
                "Core returned an unsupported self-report response message type.");
        }
    }

    private static HerdrOpsSelfReportPipeClientOptions ValidateOptions(
        HerdrOpsSelfReportPipeClientOptions options)
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

        if (options.ConnectTimeoutMilliseconds is < 100 or > 60_000)
        {
            throw new ArgumentOutOfRangeException(
                nameof(options),
                "The self-report connection timeout must be from 100 through 60000 milliseconds.");
        }

        if (options.MaximumFrameBytes is < 1024 or > HerdrOpsSelfReportProtocol.MaximumFrameBytes)
        {
            throw new ArgumentOutOfRangeException(
                nameof(options),
                $"The maximum self-report frame must be between 1024 and {HerdrOpsSelfReportProtocol.MaximumFrameBytes} bytes.");
        }

        return options;
    }
}
