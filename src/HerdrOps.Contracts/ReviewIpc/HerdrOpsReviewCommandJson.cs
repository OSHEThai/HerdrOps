using System.Buffers.Binary;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace HerdrOps.Contracts.ReviewIpc;

public static class HerdrOpsReviewCommandJson
{
    private static readonly JsonSerializerOptions SerializerOptions =
        new(JsonSerializerDefaults.Web)
        {
            AllowDuplicateProperties = false,
            AllowTrailingCommas = false,
            MaxDepth = 64,
            PropertyNameCaseInsensitive = false,
            ReadCommentHandling = JsonCommentHandling.Disallow,
            RespectRequiredConstructorParameters = true,
            UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
            WriteIndented = false,
        };

    public static HerdrOpsReviewCommandEnvelope CreateEnvelope<TPayload>(
        string messageType,
        DateTimeOffset sentUtc,
        string source,
        Guid correlationId,
        TPayload payload,
        int protocolVersion = HerdrOpsReviewCommandProtocol.Version)
    {
        ArgumentNullException.ThrowIfNull(payload);
        var envelope = new HerdrOpsReviewCommandEnvelope(
            protocolVersion,
            messageType,
            sentUtc,
            source,
            correlationId,
            JsonSerializer.SerializeToElement(payload, SerializerOptions));
        ValidateEnvelope(envelope);
        return envelope;
    }

    public static HerdrOpsReviewCliCommandInput DeserializeCliCommandInput(
        ReadOnlySpan<byte> utf8Json)
    {
        if (utf8Json.IsEmpty)
        {
            throw new HerdrOpsReviewCommandProtocolException(
                "The review-command CLI input is empty.");
        }

        try
        {
            var input = JsonSerializer.Deserialize<HerdrOpsReviewCliCommandInput>(
                utf8Json,
                SerializerOptions)
                ?? throw new HerdrOpsReviewCommandProtocolException(
                    "The review-command CLI input was null.");
            if (input.ContractVersion <= 0 ||
                input.CommandId == Guid.Empty ||
                string.IsNullOrWhiteSpace(input.IncidentId) ||
                input.IncidentId.Length > 128 ||
                input.ExpectedState <= 0 ||
                input.ExpectedSequence < 0 ||
                input.DecisionKind <= 0 ||
                string.IsNullOrWhiteSpace(input.Reason) ||
                input.Reason.Length > 2048 ||
                input.EvidenceIdentitySha256s is null ||
                input.EvidenceIdentitySha256s.Count > 256)
            {
                throw new HerdrOpsReviewCommandProtocolException(
                    "The review-command CLI input failed its bounded contract.");
            }

            return input;
        }
        catch (HerdrOpsReviewCommandProtocolException)
        {
            throw;
        }
        catch (JsonException exception)
        {
            throw new HerdrOpsReviewCommandProtocolException(
                "The review-command CLI input is not valid strict JSON.",
                exception);
        }
    }

    public static HerdrOpsComplianceIncidentRegistrationInput DeserializeRegistrationInput(
        ReadOnlySpan<byte> utf8Json)
    {
        if (utf8Json.IsEmpty)
        {
            throw new HerdrOpsReviewCommandProtocolException(
                "The compliance incident registration CLI input is empty.");
        }

        try
        {
            var registration = JsonSerializer.Deserialize<HerdrOpsComplianceIncidentRegistrationInput>(
                utf8Json,
                SerializerOptions)
                ?? throw new HerdrOpsReviewCommandProtocolException(
                    "The compliance incident registration CLI input was null.");
            if (registration.ContractVersion <= 0 ||
                registration.CommandId == Guid.Empty ||
                string.IsNullOrWhiteSpace(registration.IncidentId) ||
                registration.IncidentId.Length > 128 ||
                string.IsNullOrWhiteSpace(registration.TaskId) ||
                registration.TaskId.Length > 128 ||
                string.IsNullOrWhiteSpace(registration.SubjectActorId) ||
                registration.SubjectActorId.Length > 128 ||
                registration.RegisteredUtc.Offset != TimeSpan.Zero ||
                registration.EvidenceIdentitySha256s is null ||
                registration.EvidenceIdentitySha256s.Count > 256 ||
                registration.EvidenceIdentitySha256s.Any(identity =>
                    string.IsNullOrWhiteSpace(identity) || identity.Length != 64))
            {
                throw new HerdrOpsReviewCommandProtocolException(
                    "The compliance incident registration CLI input failed its bounded contract.");
            }

            return registration;
        }
        catch (HerdrOpsReviewCommandProtocolException)
        {
            throw;
        }
        catch (JsonException exception)
        {
            throw new HerdrOpsReviewCommandProtocolException(
                "The compliance incident registration CLI input is not valid strict JSON.",
                exception);
        }
    }

    public static string Serialize<TValue>(TValue value)
    {
        ArgumentNullException.ThrowIfNull(value);
        return JsonSerializer.Serialize(value, SerializerOptions);
    }

    public static byte[] SerializeEnvelope(HerdrOpsReviewCommandEnvelope envelope)
    {
        ValidateEnvelope(envelope);
        return JsonSerializer.SerializeToUtf8Bytes(envelope, SerializerOptions);
    }

    public static HerdrOpsReviewCommandEnvelope DeserializeEnvelope(
        ReadOnlySpan<byte> utf8Json)
    {
        if (utf8Json.IsEmpty)
        {
            throw new HerdrOpsReviewCommandProtocolException(
                "The review-command IPC JSON payload is empty.");
        }

        try
        {
            var envelope = JsonSerializer.Deserialize<HerdrOpsReviewCommandEnvelope>(
                utf8Json,
                SerializerOptions)
                ?? throw new HerdrOpsReviewCommandProtocolException(
                    "The review-command IPC envelope was null.");
            ValidateEnvelope(envelope);
            return envelope;
        }
        catch (HerdrOpsReviewCommandProtocolException)
        {
            throw;
        }
        catch (JsonException exception)
        {
            throw new HerdrOpsReviewCommandProtocolException(
                "The review-command IPC payload is not valid strict JSON.",
                exception);
        }
    }

    public static TPayload DeserializePayload<TPayload>(
        HerdrOpsReviewCommandEnvelope envelope)
    {
        ArgumentNullException.ThrowIfNull(envelope);
        try
        {
            return envelope.Payload.Deserialize<TPayload>(SerializerOptions)
                ?? throw new HerdrOpsReviewCommandProtocolException(
                    $"The '{envelope.MessageType}' payload was null.");
        }
        catch (HerdrOpsReviewCommandProtocolException)
        {
            throw;
        }
        catch (JsonException exception)
        {
            throw new HerdrOpsReviewCommandProtocolException(
                $"The '{envelope.MessageType}' payload does not match its contract.",
                exception);
        }
    }

    public static async ValueTask WriteFrameAsync(
        Stream stream,
        HerdrOpsReviewCommandEnvelope envelope,
        CancellationToken cancellationToken,
        int maximumFrameBytes = HerdrOpsReviewCommandProtocol.MaximumFrameBytes)
    {
        ArgumentNullException.ThrowIfNull(stream);
        ArgumentOutOfRangeException.ThrowIfLessThan(maximumFrameBytes, 1);
        var payload = SerializeEnvelope(envelope);
        if (payload.Length > maximumFrameBytes)
        {
            throw new HerdrOpsReviewCommandProtocolException(
                $"The outgoing review-command IPC frame exceeded the {maximumFrameBytes}-byte limit.");
        }

        var prefix = new byte[sizeof(int)];
        BinaryPrimitives.WriteInt32LittleEndian(prefix, payload.Length);
        await stream.WriteAsync(prefix, cancellationToken).ConfigureAwait(false);
        await stream.WriteAsync(payload, cancellationToken).ConfigureAwait(false);
        await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
    }

    public static async ValueTask<HerdrOpsReviewCommandEnvelope> ReadFrameAsync(
        Stream stream,
        CancellationToken cancellationToken,
        int maximumFrameBytes = HerdrOpsReviewCommandProtocol.MaximumFrameBytes)
    {
        ArgumentNullException.ThrowIfNull(stream);
        ArgumentOutOfRangeException.ThrowIfLessThan(maximumFrameBytes, 1);
        var prefix = new byte[sizeof(int)];
        await ReadExactlyAsync(
                stream,
                prefix,
                "length prefix",
                cancellationToken)
            .ConfigureAwait(false);
        var length = BinaryPrimitives.ReadInt32LittleEndian(prefix);
        if (length <= 0 || length > maximumFrameBytes)
        {
            throw new HerdrOpsReviewCommandProtocolException(
                $"The incoming review-command IPC frame length must be between 1 and {maximumFrameBytes} bytes.");
        }

        var payload = new byte[length];
        await ReadExactlyAsync(
                stream,
                payload,
                "JSON payload",
                cancellationToken)
            .ConfigureAwait(false);
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
                    $"The review-command IPC stream ended before the complete {part} arrived.");
            }

            offset += count;
        }
    }

    private static void ValidateEnvelope(HerdrOpsReviewCommandEnvelope envelope)
    {
        ArgumentNullException.ThrowIfNull(envelope);
        if (envelope.ProtocolVersion <= 0)
        {
            throw new HerdrOpsReviewCommandProtocolException(
                "The review-command IPC protocol version must be positive.");
        }

        if (string.IsNullOrWhiteSpace(envelope.MessageType) ||
            envelope.MessageType.Length > 64)
        {
            throw new HerdrOpsReviewCommandProtocolException(
                "The review-command IPC message type must contain 1 to 64 characters.");
        }

        if (envelope.SentUtc.Offset != TimeSpan.Zero)
        {
            throw new HerdrOpsReviewCommandProtocolException(
                "The review-command IPC timestamp must be UTC.");
        }

        if (string.IsNullOrWhiteSpace(envelope.Source) ||
            envelope.Source.Length > 64)
        {
            throw new HerdrOpsReviewCommandProtocolException(
                "The review-command IPC source must contain 1 to 64 characters.");
        }

        if (envelope.CorrelationId == Guid.Empty)
        {
            throw new HerdrOpsReviewCommandProtocolException(
                "The review-command IPC correlation identifier cannot be empty.");
        }

        if (envelope.Payload.ValueKind is JsonValueKind.Undefined or JsonValueKind.Null)
        {
            throw new HerdrOpsReviewCommandProtocolException(
                "The review-command IPC payload cannot be null.");
        }
    }
}
