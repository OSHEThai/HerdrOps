using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace HerdrOps.Contracts.ComplianceDiagnosticExport;

public static class ComplianceDiagnosticExportProtocol
{
    public const int Version = 1;
    public const int MaximumInputBytes = 512 * 1024;
    public const int MaximumFrameBytes = 768 * 1024;
    public const int MaximumOutputPathLength = 1024;
    public const string AuthorizationScope = "current-user";
    public const string CliSource = "HerdrOps.Cli";
    public const string CoreSource = "HerdrOps.Core";

    public static class MessageTypes
    {
        public const string Export = "compliance-diagnostic-export";
        public const string Accepted = "compliance-diagnostic-accepted";
        public const string Rejected = "compliance-diagnostic-rejected";
    }

    public static class ResultCodes
    {
        public const string Accepted = "accepted";
        public const string InvalidProtocolVersion = "invalid-protocol-version";
        public const string UnauthorizedClient = "unauthorized-client";
        public const string InvalidMessage = "invalid-message";
        public const string InvalidSchema = "invalid-schema";
        public const string ExportFailed = "export-failed";
        public const string CoreUnavailable = "core-unavailable";
        public const string InvalidCoreResponse = "invalid-core-response";
        public const string InvalidArguments = "invalid-arguments";
    }

    public static class Messages
    {
        public const string Accepted = "The compliance diagnostic export was written.";
        public const string RejectedInput = "Core rejected the compliance diagnostic export input or output path.";
        public const string RejectedPublication = "Core could not safely publish the compliance diagnostic export.";
        public const string RejectedInternal = "Core could not safely process the compliance diagnostic export.";
    }

    public static bool IsKnownResultCode(string value) =>
        value is ResultCodes.Accepted or
            ResultCodes.InvalidProtocolVersion or
            ResultCodes.UnauthorizedClient or
            ResultCodes.InvalidMessage or
            ResultCodes.InvalidSchema or
            ResultCodes.ExportFailed or
            ResultCodes.CoreUnavailable or
            ResultCodes.InvalidCoreResponse or
            ResultCodes.InvalidArguments;
}

public static class ComplianceDiagnosticExportPipeName
{
    public static string FromUserScope(string userScopeIdentifier)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(userScopeIdentifier);
        var hash = Convert.ToHexString(SHA256.HashData(
            Encoding.UTF8.GetBytes($"HerdrOps.ComplianceDiagnosticExport.v1|{userScopeIdentifier}")));
        return $"herdrops-compliance-diagnostic-v1-{hash[..24].ToLowerInvariant()}";
    }
}

public sealed record ComplianceDiagnosticExportRequest(
    int ProtocolVersion,
    string MessageType,
    DateTimeOffset SentUtc,
    string Source,
    Guid CorrelationId,
    string OutputPath,
    string InputBase64);

public sealed record ComplianceDiagnosticExportResponse(
    int ProtocolVersion,
    string MessageType,
    DateTimeOffset RespondedUtc,
    string Source,
    Guid CorrelationId,
    bool Accepted,
    string Code,
    string Message,
    int? RecordCount,
    int? ByteCount,
    string? OutputSha256);

public sealed class ComplianceDiagnosticExportProtocolException : IOException
{
    public ComplianceDiagnosticExportProtocolException(string message)
        : base(message)
    {
    }

    public ComplianceDiagnosticExportProtocolException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}

public static class ComplianceDiagnosticExportJson
{
    private static readonly JsonSerializerOptions SerializerOptions = new()
    {
        AllowDuplicateProperties = false,
        AllowTrailingCommas = false,
        MaxDepth = 12,
        PropertyNameCaseInsensitive = false,
        ReadCommentHandling = JsonCommentHandling.Disallow,
        RespectRequiredConstructorParameters = true,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
        WriteIndented = false,
    };

    private static readonly Encoding StrictUtf8 = new UTF8Encoding(
        encoderShouldEmitUTF8Identifier: false,
        throwOnInvalidBytes: true);

    public static byte[] SerializeRequest(ComplianceDiagnosticExportRequest request)
    {
        ValidateRequest(request);
        return JsonSerializer.SerializeToUtf8Bytes(request, SerializerOptions);
    }

    public static ComplianceDiagnosticExportRequest DeserializeRequest(ReadOnlySpan<byte> utf8Json)
    {
        try
        {
            var request = JsonSerializer.Deserialize<ComplianceDiagnosticExportRequest>(
                utf8Json,
                SerializerOptions) ?? throw new ComplianceDiagnosticExportProtocolException(
                "The compliance diagnostic export request cannot be JSON null.");
            ValidateRequest(request);
            return request;
        }
        catch (ComplianceDiagnosticExportProtocolException)
        {
            throw;
        }
        catch (JsonException exception)
        {
            throw new ComplianceDiagnosticExportProtocolException(
                "The compliance diagnostic export request does not match its contract.",
                exception);
        }
    }

    public static byte[] SerializeResponse(ComplianceDiagnosticExportResponse response)
    {
        ValidateResponse(response);
        return JsonSerializer.SerializeToUtf8Bytes(response, SerializerOptions);
    }

    public static ComplianceDiagnosticExportResponse DeserializeResponse(ReadOnlySpan<byte> utf8Json)
    {
        try
        {
            var response = JsonSerializer.Deserialize<ComplianceDiagnosticExportResponse>(
                utf8Json,
                SerializerOptions) ?? throw new ComplianceDiagnosticExportProtocolException(
                "The compliance diagnostic export response cannot be JSON null.");
            ValidateResponse(response);
            return response;
        }
        catch (ComplianceDiagnosticExportProtocolException)
        {
            throw;
        }
        catch (JsonException exception)
        {
            throw new ComplianceDiagnosticExportProtocolException(
                "The compliance diagnostic export response does not match its contract.",
                exception);
        }
    }

    public static byte[] GetInputBytes(ComplianceDiagnosticExportRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        ValidateRequest(request);
        try
        {
            var bytes = Convert.FromBase64String(request.InputBase64);
            if (bytes.Length is < 1 or > ComplianceDiagnosticExportProtocol.MaximumInputBytes)
            {
                throw new ComplianceDiagnosticExportProtocolException(
                    "The compliance diagnostic export input is outside its byte bound.");
            }

            if (!string.Equals(
                    Convert.ToBase64String(bytes),
                    request.InputBase64,
                    StringComparison.Ordinal))
            {
                throw new ComplianceDiagnosticExportProtocolException(
                    "The compliance diagnostic export input is not canonical Base64.");
            }

            return bytes;
        }
        catch (FormatException exception)
        {
            throw new ComplianceDiagnosticExportProtocolException(
                "The compliance diagnostic export input is not valid Base64.",
                exception);
        }
    }

    public static async Task WriteFrameAsync(
        Stream stream,
        ReadOnlyMemory<byte> utf8Json,
        CancellationToken cancellationToken,
        int maximumFrameBytes = ComplianceDiagnosticExportProtocol.MaximumFrameBytes)
    {
        ArgumentNullException.ThrowIfNull(stream);
        if (utf8Json.Length < 1 ||
            utf8Json.Length > maximumFrameBytes - 1 ||
            utf8Json.Span.Contains((byte)'\n'))
        {
            throw new ComplianceDiagnosticExportProtocolException(
                "The compliance diagnostic export frame is outside its byte bound.");
        }

        await stream.WriteAsync(utf8Json, cancellationToken).ConfigureAwait(false);
        await stream.WriteAsync("\n"u8.ToArray(), cancellationToken).ConfigureAwait(false);
        await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
    }

    public static async Task<byte[]> ReadFrameAsync(
        Stream stream,
        CancellationToken cancellationToken,
        int maximumFrameBytes = ComplianceDiagnosticExportProtocol.MaximumFrameBytes)
    {
        ArgumentNullException.ThrowIfNull(stream);
        if (maximumFrameBytes < 1024 || maximumFrameBytes > ComplianceDiagnosticExportProtocol.MaximumFrameBytes)
        {
            throw new ArgumentOutOfRangeException(nameof(maximumFrameBytes));
        }

        var frame = new byte[maximumFrameBytes];
        var length = 0;
        var oneByte = new byte[1];
        while (true)
        {
            var read = await stream.ReadAsync(oneByte, cancellationToken).ConfigureAwait(false);
            if (read == 0)
            {
                throw new EndOfStreamException(
                    "The compliance diagnostic export frame ended before its newline.");
            }

            if (oneByte[0] == (byte)'\n')
            {
                if (length == 0)
                {
                    throw new ComplianceDiagnosticExportProtocolException(
                        "The compliance diagnostic export frame cannot be empty.");
                }

                return frame[..length];
            }

            if (oneByte[0] == (byte)'\r' || length == frame.Length - 1)
            {
                throw new ComplianceDiagnosticExportProtocolException(
                    "The compliance diagnostic export frame is outside its byte bound.");
            }

            frame[length++] = oneByte[0];
        }
    }

    public static void ValidateRequest(ComplianceDiagnosticExportRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (request.ProtocolVersion != ComplianceDiagnosticExportProtocol.Version ||
            !string.Equals(request.MessageType, ComplianceDiagnosticExportProtocol.MessageTypes.Export, StringComparison.Ordinal) ||
            !string.Equals(request.Source, ComplianceDiagnosticExportProtocol.CliSource, StringComparison.Ordinal) ||
            request.CorrelationId == Guid.Empty)
        {
            throw new ComplianceDiagnosticExportProtocolException(
                "The compliance diagnostic export request has an unsupported protocol, message, source, or correlation ID.");
        }

        if (request.SentUtc.Offset != TimeSpan.Zero ||
            string.IsNullOrWhiteSpace(request.OutputPath) ||
            request.OutputPath.Length > ComplianceDiagnosticExportProtocol.MaximumOutputPathLength ||
            request.InputBase64 is null)
        {
            throw new ComplianceDiagnosticExportProtocolException(
                "The compliance diagnostic export request contains an invalid timestamp, output path, or input.");
        }

        if (request.InputBase64.Length > ((ComplianceDiagnosticExportProtocol.MaximumInputBytes + 2) / 3) * 4)
        {
            throw new ComplianceDiagnosticExportProtocolException(
                "The compliance diagnostic export input exceeds its encoded byte bound.");
        }
    }

    public static void ValidateResponse(ComplianceDiagnosticExportResponse response)
    {
        ArgumentNullException.ThrowIfNull(response);
        var expectedMessageType = response.Accepted
            ? ComplianceDiagnosticExportProtocol.MessageTypes.Accepted
            : ComplianceDiagnosticExportProtocol.MessageTypes.Rejected;
        if (response.ProtocolVersion != ComplianceDiagnosticExportProtocol.Version ||
            !string.Equals(response.MessageType, expectedMessageType, StringComparison.Ordinal) ||
            !string.Equals(response.Source, ComplianceDiagnosticExportProtocol.CoreSource, StringComparison.Ordinal) ||
            response.CorrelationId == Guid.Empty ||
            !ComplianceDiagnosticExportProtocol.IsKnownResultCode(response.Code) ||
            string.IsNullOrWhiteSpace(response.Message) ||
            response.Message.Any(char.IsControl) ||
            response.Message.Length > 512 ||
            response.Message is not
                ComplianceDiagnosticExportProtocol.Messages.Accepted and not
                ComplianceDiagnosticExportProtocol.Messages.RejectedInput and not
                ComplianceDiagnosticExportProtocol.Messages.RejectedPublication and not
                ComplianceDiagnosticExportProtocol.Messages.RejectedInternal ||
            response.RespondedUtc.Offset != TimeSpan.Zero)
        {
            throw new ComplianceDiagnosticExportProtocolException(
                "The compliance diagnostic export response is invalid.");
        }

        if (response.Accepted)
        {
            if (!string.Equals(response.Code, ComplianceDiagnosticExportProtocol.ResultCodes.Accepted, StringComparison.Ordinal) ||
                response.RecordCount is < 1 or > 256 ||
                response.ByteCount is < 1 or > 256 * 1024 ||
                response.OutputSha256 is not { Length: 64 } hash ||
                hash.Any(character =>
                    !(character is >= '0' and <= '9' or >= 'A' and <= 'F')))
            {
                throw new ComplianceDiagnosticExportProtocolException(
                    "The accepted compliance diagnostic export response is incomplete.");
            }
        }
        else if (response.Code == ComplianceDiagnosticExportProtocol.ResultCodes.Accepted ||
                 response.RecordCount is not null ||
                 response.ByteCount is not null ||
                 response.OutputSha256 is not null)
        {
            throw new ComplianceDiagnosticExportProtocolException(
                "The rejected compliance diagnostic export response contains acceptance fields.");
        }
    }

    public static string Serialize<T>(T value)
    {
        ArgumentNullException.ThrowIfNull(value);
        return StrictUtf8.GetString(JsonSerializer.SerializeToUtf8Bytes(value, SerializerOptions));
    }
}
