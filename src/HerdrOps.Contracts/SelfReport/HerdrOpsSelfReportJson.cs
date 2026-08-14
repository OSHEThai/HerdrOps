using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace HerdrOps.Contracts.SelfReport;

public static class HerdrOpsSelfReportJson
{
    private static readonly JsonSerializerOptions SerializerOptions = new(JsonSerializerDefaults.Web)
    {
        AllowTrailingCommas = false,
        MaxDepth = 32,
        PropertyNameCaseInsensitive = false,
        ReadCommentHandling = JsonCommentHandling.Disallow,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
        WriteIndented = false,
    };

    public static HerdrOpsSelfReportCommandInput DeserializeCommandInput(ReadOnlySpan<byte> utf8Json)
    {
        var input = DeserializeStrict<HerdrOpsSelfReportCommandInput>(
            utf8Json,
            "The self-report command input");
        ValidateCommandInput(input);
        return input;
    }

    public static HerdrOpsSelfReportSubmission CreateSubmission(
        string eventType,
        HerdrOpsSelfReportCommandInput input)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(eventType);
        ArgumentNullException.ThrowIfNull(input);
        var submission = new HerdrOpsSelfReportSubmission(
            input.ContractVersion,
            input.EventId,
            eventType,
            input.TaskId,
            input.ActorId,
            input.ActorRole,
            input.OccurredUtc,
            input.Summary,
            input.ParentEventId,
            input.TargetAgentId,
            input.ProgressPercent,
            input.DeviationReason,
            input.EvidenceReference,
            input.EvidenceSha256,
            input.HandoffNote);
        ValidateSubmission(submission);
        return submission;
    }

    public static HerdrOpsSelfReportEnvelope CreateEnvelope<TPayload>(
        string messageType,
        long sequence,
        DateTimeOffset sentUtc,
        string source,
        Guid correlationId,
        TPayload payload,
        int protocolVersion = HerdrOpsSelfReportProtocol.Version)
    {
        ArgumentNullException.ThrowIfNull(payload);
        var envelope = new HerdrOpsSelfReportEnvelope(
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

    public static byte[] SerializeEnvelope(HerdrOpsSelfReportEnvelope envelope)
    {
        ValidateEnvelope(envelope);
        return JsonSerializer.SerializeToUtf8Bytes(envelope, SerializerOptions);
    }

    public static HerdrOpsSelfReportEnvelope DeserializeEnvelope(ReadOnlySpan<byte> utf8Json)
    {
        var envelope = DeserializeStrict<HerdrOpsSelfReportEnvelope>(
            utf8Json,
            "The self-report envelope");
        ValidateEnvelope(envelope);
        return envelope;
    }

    public static TPayload DeserializePayload<TPayload>(HerdrOpsSelfReportEnvelope envelope)
    {
        ArgumentNullException.ThrowIfNull(envelope);
        try
        {
            return envelope.Payload.Deserialize<TPayload>(SerializerOptions)
                ?? throw new HerdrOpsSelfReportProtocolException(
                    $"The '{envelope.MessageType}' payload was null.");
        }
        catch (HerdrOpsSelfReportProtocolException)
        {
            throw;
        }
        catch (JsonException exception)
        {
            throw new HerdrOpsSelfReportProtocolException(
                $"The '{envelope.MessageType}' payload does not match its contract.",
                exception);
        }
    }

    public static HerdrOpsSelfReportSubmission DeserializeSubmission(
        HerdrOpsSelfReportEnvelope envelope)
    {
        var submission = DeserializePayload<HerdrOpsSelfReportSubmission>(envelope);
        ValidateSubmission(submission);
        return submission;
    }

    public static HerdrOpsSelfReportResult DeserializeResult(
        HerdrOpsSelfReportEnvelope envelope)
    {
        var result = DeserializePayload<HerdrOpsSelfReportResult>(envelope);
        ValidateResult(result);
        return result;
    }

    public static string Serialize<TPayload>(TPayload payload)
    {
        ArgumentNullException.ThrowIfNull(payload);
        return JsonSerializer.Serialize(payload, SerializerOptions);
    }

    public static string ComputeSha256<TPayload>(TPayload payload)
    {
        ArgumentNullException.ThrowIfNull(payload);
        return Convert.ToHexString(SHA256.HashData(
            JsonSerializer.SerializeToUtf8Bytes(payload, SerializerOptions)));
    }

    public static void ValidateSubmission(HerdrOpsSelfReportSubmission submission)
    {
        ArgumentNullException.ThrowIfNull(submission);
        ValidateCommandInput(new HerdrOpsSelfReportCommandInput(
            submission.ContractVersion,
            submission.EventId,
            submission.TaskId,
            submission.ActorId,
            submission.ActorRole,
            submission.OccurredUtc,
            submission.Summary,
            submission.ParentEventId,
            submission.TargetAgentId,
            submission.ProgressPercent,
            submission.DeviationReason,
            submission.EvidenceReference,
            submission.EvidenceSha256,
            submission.HandoffNote));

        if (!HerdrOpsSelfReportProtocol.EventTypes.IsSupported(submission.EventType))
        {
            throw new HerdrOpsSelfReportProtocolException(
                $"Unsupported self-report event type: {submission.EventType}");
        }

        switch (submission.EventType)
        {
            case HerdrOpsSelfReportProtocol.EventTypes.Assignment:
                RequireTarget(submission);
                RequireNoParent(submission);
                RequireAbsent(submission, progress: true, deviation: true, evidence: true, handoff: true);
                break;
            case HerdrOpsSelfReportProtocol.EventTypes.Acknowledgement:
                RequireParent(submission);
                RequireAbsent(submission, target: true, progress: true, deviation: true, evidence: true, handoff: true);
                break;
            case HerdrOpsSelfReportProtocol.EventTypes.Delegation:
                RequireParent(submission);
                RequireTarget(submission);
                RequireAbsent(submission, progress: true, deviation: true, evidence: true, handoff: true);
                break;
            case HerdrOpsSelfReportProtocol.EventTypes.Progress:
                RequireParent(submission);
                if (submission.ProgressPercent is null)
                {
                    throw new HerdrOpsSelfReportProtocolException(
                        "A progress event requires progressPercent.");
                }

                RequireAbsent(submission, target: true, deviation: true, evidence: true, handoff: true);
                break;
            case HerdrOpsSelfReportProtocol.EventTypes.Deviation:
                RequireParent(submission);
                RequireText(submission.DeviationReason, nameof(submission.DeviationReason), 2048);
                RequireAbsent(submission, target: true, progress: true, evidence: true, handoff: true);
                break;
            case HerdrOpsSelfReportProtocol.EventTypes.Evidence:
                RequireParent(submission);
                RequireText(submission.EvidenceReference, nameof(submission.EvidenceReference), 2048);
                if (string.IsNullOrWhiteSpace(submission.EvidenceSha256) ||
                    submission.EvidenceSha256.Length != 64 ||
                    submission.EvidenceSha256.Any(character => !Uri.IsHexDigit(character)))
                {
                    throw new HerdrOpsSelfReportProtocolException(
                        "An evidence event requires a 64-character hexadecimal evidenceSha256.");
                }

                RequireAbsent(submission, target: true, progress: true, deviation: true, handoff: true);
                break;
            case HerdrOpsSelfReportProtocol.EventTypes.Handoff:
                RequireParent(submission);
                RequireTarget(submission);
                RequireText(submission.HandoffNote, nameof(submission.HandoffNote), 2048);
                RequireAbsent(submission, progress: true, deviation: true, evidence: true);
                break;
        }
    }

    public static void ValidateResult(HerdrOpsSelfReportResult result)
    {
        ArgumentNullException.ThrowIfNull(result);
        RequireText(result.Code, nameof(result.Code), 64);
        RequireText(result.Message, nameof(result.Message), 2048);
        if (!HerdrOpsSelfReportProtocol.ResultCodes.IsKnown(result.Code))
        {
            throw new HerdrOpsSelfReportProtocolException(
                $"Unsupported self-report result code: {result.Code}");
        }

        if (result.Accepted)
        {
            if (result.EventId is null ||
                result.EventId == Guid.Empty ||
                result.EventType is null ||
                !HerdrOpsSelfReportProtocol.EventTypes.IsSupported(result.EventType) ||
                result.TaskId is null ||
                result.CorrelationId is null ||
                result.CorrelationId == Guid.Empty ||
                result.Sequence is null or <= 0 ||
                result.AcceptedUtc is null ||
                result.AcceptedUtc.Value == default ||
                result.AcceptedUtc.Value.Offset != TimeSpan.Zero ||
                !string.Equals(
                    result.AcceptedSource,
                    HerdrOpsSelfReportProtocol.CoreSource,
                    StringComparison.Ordinal) ||
                string.IsNullOrWhiteSpace(result.EventSha256) ||
                result.EventSha256.Length != 64 ||
                result.EventSha256.Any(character => !Uri.IsHexDigit(character)))
            {
                throw new HerdrOpsSelfReportProtocolException(
                    "An accepted self-report result is missing Core acceptance identity fields.");
            }

            RequireIdentifier(result.TaskId, nameof(result.TaskId), 64);
            if (result.Code is not HerdrOpsSelfReportProtocol.ResultCodes.Accepted and
                not HerdrOpsSelfReportProtocol.ResultCodes.AcceptedIdempotent)
            {
                throw new HerdrOpsSelfReportProtocolException(
                    "An accepted self-report result has a rejection-only result code.");
            }
        }
        else if (result.Code is HerdrOpsSelfReportProtocol.ResultCodes.Accepted or
                 HerdrOpsSelfReportProtocol.ResultCodes.AcceptedIdempotent)
        {
            throw new HerdrOpsSelfReportProtocolException(
                "A rejected self-report result has an acceptance-only result code.");
        }
        else if (result.CorrelationId == Guid.Empty || result.EventId == Guid.Empty)
        {
            throw new HerdrOpsSelfReportProtocolException(
                "A supplied rejection event or correlation identifier cannot be empty.");
        }
        else if (result.Sequence is not null ||
                 result.AcceptedUtc is not null ||
                 result.AcceptedSource is not null ||
                 result.EventSha256 is not null)
        {
            throw new HerdrOpsSelfReportProtocolException(
                "A rejected self-report result cannot contain Core acceptance identity fields.");
        }

        if (result.EventType is not null &&
            !HerdrOpsSelfReportProtocol.EventTypes.IsSupported(result.EventType))
        {
            throw new HerdrOpsSelfReportProtocolException(
                "A self-report result contains an unsupported event type.");
        }

        if (result.TaskId is not null)
        {
            RequireIdentifier(result.TaskId, nameof(result.TaskId), 64);
        }
    }

    public static async ValueTask WriteFrameAsync(
        Stream stream,
        HerdrOpsSelfReportEnvelope envelope,
        CancellationToken cancellationToken,
        int maximumFrameBytes = HerdrOpsSelfReportProtocol.MaximumFrameBytes)
    {
        ArgumentNullException.ThrowIfNull(stream);
        ValidateMaximumFrameBytes(maximumFrameBytes);
        var payload = SerializeEnvelope(envelope);
        if (payload.Length > maximumFrameBytes)
        {
            throw new HerdrOpsSelfReportProtocolException(
                $"The outgoing self-report frame exceeded the {maximumFrameBytes}-byte limit.");
        }

        var prefix = new byte[sizeof(int)];
        BinaryPrimitives.WriteInt32LittleEndian(prefix, payload.Length);
        await stream.WriteAsync(prefix, cancellationToken).ConfigureAwait(false);
        await stream.WriteAsync(payload, cancellationToken).ConfigureAwait(false);
        await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
    }

    public static async ValueTask<HerdrOpsSelfReportEnvelope> ReadFrameAsync(
        Stream stream,
        CancellationToken cancellationToken,
        int maximumFrameBytes = HerdrOpsSelfReportProtocol.MaximumFrameBytes)
    {
        ArgumentNullException.ThrowIfNull(stream);
        ValidateMaximumFrameBytes(maximumFrameBytes);
        var prefix = new byte[sizeof(int)];
        await ReadExactlyAsync(stream, prefix, "length prefix", cancellationToken).ConfigureAwait(false);
        var length = BinaryPrimitives.ReadInt32LittleEndian(prefix);
        if (length <= 0 || length > maximumFrameBytes)
        {
            throw new HerdrOpsSelfReportProtocolException(
                $"The incoming self-report frame length must be between 1 and {maximumFrameBytes} bytes.");
        }

        var payload = new byte[length];
        await ReadExactlyAsync(stream, payload, "JSON payload", cancellationToken).ConfigureAwait(false);
        return DeserializeEnvelope(payload);
    }

    private static TPayload DeserializeStrict<TPayload>(
        ReadOnlySpan<byte> utf8Json,
        string description)
    {
        if (utf8Json.IsEmpty)
        {
            throw new HerdrOpsSelfReportProtocolException($"{description} is empty.");
        }

        try
        {
            return JsonSerializer.Deserialize<TPayload>(utf8Json, SerializerOptions)
                ?? throw new HerdrOpsSelfReportProtocolException($"{description} was null.");
        }
        catch (HerdrOpsSelfReportProtocolException)
        {
            throw;
        }
        catch (JsonException exception)
        {
            throw new HerdrOpsSelfReportProtocolException(
                $"{description} is not valid strict JSON.",
                exception);
        }
    }

    private static void ValidateCommandInput(HerdrOpsSelfReportCommandInput input)
    {
        ArgumentNullException.ThrowIfNull(input);
        if (input.ContractVersion != HerdrOpsSelfReportProtocol.Version)
        {
            throw new HerdrOpsSelfReportProtocolException(
                $"Contract version {input.ContractVersion} is unsupported; expected {HerdrOpsSelfReportProtocol.Version}.");
        }

        if (input.EventId == Guid.Empty)
        {
            throw new HerdrOpsSelfReportProtocolException("eventId cannot be empty.");
        }

        RequireIdentifier(input.TaskId, nameof(input.TaskId), 64);
        RequireIdentifier(input.ActorId, nameof(input.ActorId), 128);
        RequireText(input.ActorRole, nameof(input.ActorRole), 128);
        if (input.OccurredUtc == default || input.OccurredUtc.Offset != TimeSpan.Zero)
        {
            throw new HerdrOpsSelfReportProtocolException("occurredUtc must be a non-default UTC timestamp.");
        }

        RequireText(input.Summary, nameof(input.Summary), 2048);
        if (input.ParentEventId == Guid.Empty)
        {
            throw new HerdrOpsSelfReportProtocolException("parentEventId cannot be empty when supplied.");
        }

        if (input.TargetAgentId is not null)
        {
            RequireIdentifier(input.TargetAgentId, nameof(input.TargetAgentId), 128);
        }

        if (input.ProgressPercent is < 0 or > 100)
        {
            throw new HerdrOpsSelfReportProtocolException("progressPercent must be from 0 through 100.");
        }

        ValidateOptionalText(input.DeviationReason, nameof(input.DeviationReason), 2048);
        ValidateOptionalText(input.EvidenceReference, nameof(input.EvidenceReference), 2048);
        ValidateOptionalText(input.HandoffNote, nameof(input.HandoffNote), 2048);
    }

    private static void ValidateEnvelope(HerdrOpsSelfReportEnvelope envelope)
    {
        ArgumentNullException.ThrowIfNull(envelope);
        if (envelope.ProtocolVersion <= 0)
        {
            throw new HerdrOpsSelfReportProtocolException(
                "The self-report protocol version must be positive.");
        }

        RequireText(envelope.MessageType, nameof(envelope.MessageType), 64);
        if (envelope.Sequence < 0)
        {
            throw new HerdrOpsSelfReportProtocolException(
                "The self-report sequence cannot be negative.");
        }

        if (envelope.SentUtc == default || envelope.SentUtc.Offset != TimeSpan.Zero)
        {
            throw new HerdrOpsSelfReportProtocolException(
                "The self-report envelope timestamp must be UTC.");
        }

        RequireText(envelope.Source, nameof(envelope.Source), 64);
        if (envelope.CorrelationId == Guid.Empty)
        {
            throw new HerdrOpsSelfReportProtocolException(
                "The self-report correlation identifier cannot be empty.");
        }

        if (envelope.Payload.ValueKind is JsonValueKind.Undefined or JsonValueKind.Null)
        {
            throw new HerdrOpsSelfReportProtocolException(
                "The self-report payload cannot be null.");
        }
    }

    private static void RequireIdentifier(string? value, string name, int maximumLength)
    {
        RequireText(value, name, maximumLength);
        if (value!.Any(character =>
                !(char.IsAsciiLetterOrDigit(character) || character is '-' or '_' or '.' or ':' or '/')))
        {
            throw new HerdrOpsSelfReportProtocolException(
                $"{name} contains a character outside the identifier allowlist.");
        }
    }

    private static void RequireText(string? value, string name, int maximumLength)
    {
        if (string.IsNullOrWhiteSpace(value) ||
            value.Length > maximumLength ||
            !string.Equals(value, value.Trim(), StringComparison.Ordinal) ||
            value.Any(char.IsControl))
        {
            throw new HerdrOpsSelfReportProtocolException(
                $"{name} must contain 1 to {maximumLength} trimmed, non-control characters.");
        }
    }

    private static void ValidateOptionalText(string? value, string name, int maximumLength)
    {
        if (value is not null)
        {
            RequireText(value, name, maximumLength);
        }
    }

    private static void RequireParent(HerdrOpsSelfReportSubmission submission)
    {
        if (submission.ParentEventId is null)
        {
            throw new HerdrOpsSelfReportProtocolException(
                $"A {submission.EventType} event requires parentEventId.");
        }
    }

    private static void RequireNoParent(HerdrOpsSelfReportSubmission submission)
    {
        if (submission.ParentEventId is not null)
        {
            throw new HerdrOpsSelfReportProtocolException(
                "An assignment event starts a lifecycle and cannot contain parentEventId.");
        }
    }

    private static void RequireTarget(HerdrOpsSelfReportSubmission submission)
    {
        if (submission.TargetAgentId is null)
        {
            throw new HerdrOpsSelfReportProtocolException(
                $"A {submission.EventType} event requires targetAgentId.");
        }
    }

    private static void RequireAbsent(
        HerdrOpsSelfReportSubmission submission,
        bool target = false,
        bool progress = false,
        bool deviation = false,
        bool evidence = false,
        bool handoff = false)
    {
        if ((target && submission.TargetAgentId is not null) ||
            (progress && submission.ProgressPercent is not null) ||
            (deviation && submission.DeviationReason is not null) ||
            (evidence && (submission.EvidenceReference is not null || submission.EvidenceSha256 is not null)) ||
            (handoff && submission.HandoffNote is not null))
        {
            throw new HerdrOpsSelfReportProtocolException(
                $"The {submission.EventType} event contains a field reserved for another event type.");
        }
    }

    private static void ValidateMaximumFrameBytes(int maximumFrameBytes)
    {
        if (maximumFrameBytes is < 1024 or > HerdrOpsSelfReportProtocol.MaximumFrameBytes)
        {
            throw new ArgumentOutOfRangeException(
                nameof(maximumFrameBytes),
                $"The self-report frame limit must be between 1024 and {HerdrOpsSelfReportProtocol.MaximumFrameBytes} bytes.");
        }
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
                    $"The self-report stream ended before the complete {part} arrived.");
            }

            offset += count;
        }
    }
}
