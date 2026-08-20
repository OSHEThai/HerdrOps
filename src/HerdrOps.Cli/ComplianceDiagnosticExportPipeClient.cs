using System.IO.Pipes;
using System.Security.Principal;
using HerdrOps.Contracts.ComplianceDiagnosticExport;

namespace HerdrOps.Cli;

public sealed record ComplianceDiagnosticExportPipeClientOptions(
    string PipeName,
    int ConnectTimeoutMilliseconds = 5000,
    int MaximumFrameBytes = ComplianceDiagnosticExportProtocol.MaximumFrameBytes)
{
    public static ComplianceDiagnosticExportPipeClientOptions ForCurrentUser(
        int connectTimeoutMilliseconds = 5000)
    {
        var userSid = WindowsIdentity.GetCurrent().User?.Value;
        if (string.IsNullOrWhiteSpace(userSid))
        {
            throw new ComplianceDiagnosticExportProtocolException(
                "The current Windows user SID is unavailable for compliance diagnostic IPC.");
        }

        return new ComplianceDiagnosticExportPipeClientOptions(
            ComplianceDiagnosticExportPipeName.FromUserScope(userSid),
            connectTimeoutMilliseconds);
    }
}

public sealed class ComplianceDiagnosticExportPipeClient
{
    public const PipeOptions RequiredPipeOptions =
        PipeOptions.Asynchronous |
        PipeOptions.WriteThrough |
        PipeOptions.CurrentUserOnly;

    private readonly ComplianceDiagnosticExportPipeClientOptions _options;
    private readonly TimeProvider _timeProvider;

    public ComplianceDiagnosticExportPipeClient(
        ComplianceDiagnosticExportPipeClientOptions options,
        TimeProvider? timeProvider = null)
    {
        _options = ValidateOptions(options);
        _timeProvider = timeProvider ?? TimeProvider.System;
    }

    public async Task<ComplianceDiagnosticExportResponse> ExportAsync(
        ReadOnlyMemory<byte> inputBytes,
        string outputPath,
        Guid correlationId,
        CancellationToken cancellationToken = default)
    {
        if (inputBytes.Length is < 1 or > ComplianceDiagnosticExportProtocol.MaximumInputBytes)
        {
            throw new ComplianceDiagnosticExportProtocolException(
                "The compliance diagnostic export input is outside its byte bound.");
        }

        if (string.IsNullOrWhiteSpace(outputPath) ||
            outputPath.Length > ComplianceDiagnosticExportProtocol.MaximumOutputPathLength)
        {
            throw new ArgumentException(
                "The compliance diagnostic output path is blank or outside its bound.",
                nameof(outputPath));
        }

        if (correlationId == Guid.Empty)
        {
            throw new ArgumentException(
                "The compliance diagnostic correlation identifier cannot be empty.",
                nameof(correlationId));
        }

        var inputBase64 = Convert.ToBase64String(inputBytes.Span);
        var request = new ComplianceDiagnosticExportRequest(
            ComplianceDiagnosticExportProtocol.Version,
            ComplianceDiagnosticExportProtocol.MessageTypes.Export,
            _timeProvider.GetUtcNow(),
            ComplianceDiagnosticExportProtocol.CliSource,
            correlationId,
            outputPath,
            inputBase64);
        ComplianceDiagnosticExportJson.ValidateRequest(request);

        using var operationCancellation = CancellationTokenSource.CreateLinkedTokenSource(
            cancellationToken);
        operationCancellation.CancelAfter(_options.ConnectTimeoutMilliseconds);
        await using var pipe = new NamedPipeClientStream(
            ".",
            _options.PipeName,
            PipeDirection.InOut,
            RequiredPipeOptions);
        await pipe.ConnectAsync(operationCancellation.Token).ConfigureAwait(false);
        var requestBytes = ComplianceDiagnosticExportJson.SerializeRequest(request);
        await ComplianceDiagnosticExportJson
            .WriteFrameAsync(pipe, requestBytes, operationCancellation.Token, _options.MaximumFrameBytes)
            .ConfigureAwait(false);
        var responseBytes = await ComplianceDiagnosticExportJson
            .ReadFrameAsync(pipe, operationCancellation.Token, _options.MaximumFrameBytes)
            .ConfigureAwait(false);
        var response = ComplianceDiagnosticExportJson.DeserializeResponse(responseBytes);
        if (response.CorrelationId != correlationId)
        {
            throw new ComplianceDiagnosticExportProtocolException(
                "The Core compliance diagnostic response correlation identifier does not match the request.");
        }

        return response;
    }

    private static ComplianceDiagnosticExportPipeClientOptions ValidateOptions(
        ComplianceDiagnosticExportPipeClientOptions options)
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

        if (options.ConnectTimeoutMilliseconds is < 100 or > 60_000)
        {
            throw new ArgumentOutOfRangeException(nameof(options));
        }

        if (options.MaximumFrameBytes is < 1024 or > ComplianceDiagnosticExportProtocol.MaximumFrameBytes)
        {
            throw new ArgumentOutOfRangeException(nameof(options));
        }

        return options;
    }
}
