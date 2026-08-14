using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace HerdrOps.Contracts.StateIpc;

public static class HerdrOpsStateIpcJson
{
    private static readonly JsonSerializerOptions SerializerOptions = new(JsonSerializerDefaults.Web)
    {
        AllowTrailingCommas = false,
        MaxDepth = 64,
        PropertyNameCaseInsensitive = false,
        ReadCommentHandling = JsonCommentHandling.Disallow,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
        WriteIndented = false,
    };

    public static HerdrOpsStateIpcEnvelope CreateEnvelope<TPayload>(
        string messageType,
        long sequence,
        DateTimeOffset sentUtc,
        string source,
        Guid correlationId,
        TPayload payload,
        int protocolVersion = HerdrOpsStateIpcProtocol.Version)
    {
        ArgumentNullException.ThrowIfNull(payload);
        var envelope = new HerdrOpsStateIpcEnvelope(
            protocolVersion,
            messageType,
            sequence,
            sentUtc,
            source,
            correlationId,
            JsonSerializer.SerializeToElement(payload, SerializerOptions));
        ValidateEnvelope(envelope);
        return envelope;
    }

    public static byte[] SerializeEnvelope(HerdrOpsStateIpcEnvelope envelope)
    {
        ValidateEnvelope(envelope);
        return JsonSerializer.SerializeToUtf8Bytes(envelope, SerializerOptions);
    }

    public static HerdrOpsStateIpcEnvelope DeserializeEnvelope(ReadOnlySpan<byte> utf8Json)
    {
        if (utf8Json.IsEmpty)
        {
            throw new HerdrOpsStateIpcProtocolException("The state IPC JSON payload is empty.");
        }

        try
        {
            var envelope = JsonSerializer.Deserialize<HerdrOpsStateIpcEnvelope>(utf8Json, SerializerOptions)
                ?? throw new HerdrOpsStateIpcProtocolException("The state IPC envelope was null.");
            ValidateEnvelope(envelope);
            return envelope;
        }
        catch (HerdrOpsStateIpcProtocolException)
        {
            throw;
        }
        catch (JsonException exception)
        {
            throw new HerdrOpsStateIpcProtocolException(
                "The state IPC payload is not valid strict JSON.",
                exception);
        }
    }

    public static TPayload DeserializePayload<TPayload>(HerdrOpsStateIpcEnvelope envelope)
    {
        ArgumentNullException.ThrowIfNull(envelope);
        try
        {
            return envelope.Payload.Deserialize<TPayload>(SerializerOptions)
                ?? throw new HerdrOpsStateIpcProtocolException(
                    $"The '{envelope.MessageType}' payload was null.");
        }
        catch (HerdrOpsStateIpcProtocolException)
        {
            throw;
        }
        catch (JsonException exception)
        {
            throw new HerdrOpsStateIpcProtocolException(
                $"The '{envelope.MessageType}' payload does not match its contract.",
                exception);
        }
    }

    public static string SerializePayload<TPayload>(TPayload payload)
    {
        ArgumentNullException.ThrowIfNull(payload);
        return JsonSerializer.Serialize(payload, SerializerOptions);
    }

    public static TPayload DeserializePayload<TPayload>(string json)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(json);
        try
        {
            return JsonSerializer.Deserialize<TPayload>(json, SerializerOptions)
                ?? throw new HerdrOpsStateIpcProtocolException("The stored JSON payload was null.");
        }
        catch (HerdrOpsStateIpcProtocolException)
        {
            throw;
        }
        catch (JsonException exception)
        {
            throw new HerdrOpsStateIpcProtocolException(
                "The stored JSON payload does not match its contract.",
                exception);
        }
    }

    public static string ComputeSha256<TPayload>(TPayload payload)
    {
        ArgumentNullException.ThrowIfNull(payload);
        return Convert.ToHexString(SHA256.HashData(
            JsonSerializer.SerializeToUtf8Bytes(payload, SerializerOptions)));
    }

    public static async ValueTask WriteFrameAsync(
        Stream stream,
        HerdrOpsStateIpcEnvelope envelope,
        CancellationToken cancellationToken,
        int maximumFrameBytes = HerdrOpsStateIpcProtocol.MaximumFrameBytes)
    {
        ArgumentNullException.ThrowIfNull(stream);
        ArgumentOutOfRangeException.ThrowIfLessThan(maximumFrameBytes, 1);
        var payload = SerializeEnvelope(envelope);
        if (payload.Length > maximumFrameBytes)
        {
            throw new HerdrOpsStateIpcProtocolException(
                $"The outgoing state IPC frame exceeded the {maximumFrameBytes}-byte limit.");
        }

        var prefix = new byte[sizeof(int)];
        BinaryPrimitives.WriteInt32LittleEndian(prefix, payload.Length);
        await stream.WriteAsync(prefix, cancellationToken).ConfigureAwait(false);
        await stream.WriteAsync(payload, cancellationToken).ConfigureAwait(false);
        await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
    }

    public static async ValueTask<HerdrOpsStateIpcEnvelope> ReadFrameAsync(
        Stream stream,
        CancellationToken cancellationToken,
        int maximumFrameBytes = HerdrOpsStateIpcProtocol.MaximumFrameBytes)
    {
        ArgumentNullException.ThrowIfNull(stream);
        ArgumentOutOfRangeException.ThrowIfLessThan(maximumFrameBytes, 1);
        var prefix = new byte[sizeof(int)];
        await ReadExactlyAsync(stream, prefix, "length prefix", cancellationToken).ConfigureAwait(false);
        var length = BinaryPrimitives.ReadInt32LittleEndian(prefix);
        if (length <= 0 || length > maximumFrameBytes)
        {
            throw new HerdrOpsStateIpcProtocolException(
                $"The incoming state IPC frame length must be between 1 and {maximumFrameBytes} bytes.");
        }

        var payload = new byte[length];
        await ReadExactlyAsync(stream, payload, "JSON payload", cancellationToken).ConfigureAwait(false);
        return DeserializeEnvelope(payload);
    }

    private static async ValueTask ReadExactlyAsync(
        Stream stream,
        Memory<byte> destination,
        string part,
        CancellationToken cancellationToken)
    {
        var offset = 0;
        while (offset < destination.Length)
        {
            var count = await stream
                .ReadAsync(destination[offset..], cancellationToken)
                .ConfigureAwait(false);
            if (count == 0)
            {
                throw new EndOfStreamException(
                    $"The state IPC stream ended before the complete {part} arrived.");
            }

            offset += count;
        }
    }

    private static void ValidateEnvelope(HerdrOpsStateIpcEnvelope envelope)
    {
        ArgumentNullException.ThrowIfNull(envelope);
        if (envelope.ProtocolVersion <= 0)
        {
            throw new HerdrOpsStateIpcProtocolException("The state IPC protocol version must be positive.");
        }

        if (string.IsNullOrWhiteSpace(envelope.MessageType) || envelope.MessageType.Length > 64)
        {
            throw new HerdrOpsStateIpcProtocolException(
                "The state IPC message type must contain 1 to 64 characters.");
        }

        if (envelope.Sequence < 0)
        {
            throw new HerdrOpsStateIpcProtocolException("The state IPC sequence cannot be negative.");
        }

        if (envelope.SentUtc.Offset != TimeSpan.Zero)
        {
            throw new HerdrOpsStateIpcProtocolException("The state IPC timestamp must be UTC.");
        }

        if (string.IsNullOrWhiteSpace(envelope.Source) || envelope.Source.Length > 64)
        {
            throw new HerdrOpsStateIpcProtocolException(
                "The state IPC source must contain 1 to 64 characters.");
        }

        if (envelope.CorrelationId == Guid.Empty)
        {
            throw new HerdrOpsStateIpcProtocolException(
                "The state IPC correlation identifier cannot be empty.");
        }

        if (envelope.Payload.ValueKind is JsonValueKind.Undefined or JsonValueKind.Null)
        {
            throw new HerdrOpsStateIpcProtocolException("The state IPC payload cannot be null.");
        }
    }
}
