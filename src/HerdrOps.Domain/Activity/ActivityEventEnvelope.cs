using System.Buffers.Binary;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;

namespace HerdrOps.Domain.Activity;

public enum ActivitySourceKind
{
    Herdr = 1,
    WindowsProcess = 2,
    FileSystem = 3,
    Git = 4,
    AgentReport = 5,
    Inference = 6,
    HerdrOpsCore = 7,
}

public enum ActivityConfidence
{
    Observed = 1,
    Correlated = 2,
    Inferred = 3,
}

public enum ActivityUrgency
{
    Normal = 1,
    High = 2,
    Critical = 3,
}

public enum ActivityDeliveryMode
{
    Immediate = 1,
    Debounced = 2,
}

public sealed record ActivityEventEnvelope(
    int ContractVersion,
    string SourceEventId,
    ActivitySourceKind SourceKind,
    string SourceInstanceId,
    string SourceEpoch,
    long? SourceSequence,
    ActivityConfidence Confidence,
    ActivityUrgency Urgency,
    ActivityDeliveryMode DeliveryMode,
    string EventType,
    DateTimeOffset OccurredUtc,
    DateTimeOffset ObservedUtc,
    Guid CorrelationId,
    string? DebounceKey,
    string? AgentTerminalId,
    string? PaneId,
    string? TaskId,
    int? ProcessId,
    string RedactedSummary,
    string PayloadSha256);

public sealed record NormalizedActivityEvent(
    long IngestSequence,
    ActivityEventEnvelope Envelope,
    string EventIdentitySha256,
    string EnvelopeSha256);

public static class ActivityEventContract
{
    public const int Version = 1;
    public const int MaximumIdentifierLength = 256;
    public const int MaximumEventTypeLength = 128;
    public const int MaximumSummaryLength = 1024;

    public static NormalizedActivityEvent NormalizeAndValidate(
        ActivityEventEnvelope envelope,
        long ingestSequence)
    {
        ArgumentNullException.ThrowIfNull(envelope);
        if (ingestSequence <= 0)
        {
            throw new ActivityEventContractException(
                "The local activity ingest sequence must be positive.");
        }

        if (envelope.ContractVersion != Version)
        {
            throw new ActivityEventContractException(
                $"Activity event contract v{envelope.ContractVersion} is unsupported; expected v{Version}.");
        }

        ValidateEnum(envelope.SourceKind, nameof(envelope.SourceKind));
        ValidateEnum(envelope.Confidence, nameof(envelope.Confidence));
        ValidateEnum(envelope.Urgency, nameof(envelope.Urgency));
        ValidateEnum(envelope.DeliveryMode, nameof(envelope.DeliveryMode));
        EnsureUtc(envelope.OccurredUtc, nameof(envelope.OccurredUtc));
        EnsureUtc(envelope.ObservedUtc, nameof(envelope.ObservedUtc));
        if (envelope.SourceSequence is <= 0)
        {
            throw new ActivityEventContractException(
                "A supplied source sequence must be positive.");
        }

        if (envelope.CorrelationId == Guid.Empty)
        {
            throw new ActivityEventContractException(
                "The activity correlation identifier cannot be empty.");
        }

        if (envelope.ProcessId is <= 0)
        {
            throw new ActivityEventContractException(
                "A supplied process identifier must be positive.");
        }

        var normalized = envelope with
        {
            SourceEventId = NormalizeIdentifier(
                envelope.SourceEventId,
                nameof(envelope.SourceEventId),
                MaximumIdentifierLength),
            SourceInstanceId = NormalizeIdentifier(
                envelope.SourceInstanceId,
                nameof(envelope.SourceInstanceId),
                MaximumIdentifierLength),
            SourceEpoch = NormalizeIdentifier(
                envelope.SourceEpoch,
                nameof(envelope.SourceEpoch),
                MaximumIdentifierLength),
            EventType = NormalizeIdentifier(
                envelope.EventType,
                nameof(envelope.EventType),
                MaximumEventTypeLength),
            DebounceKey = NormalizeOptionalIdentifier(
                envelope.DebounceKey,
                nameof(envelope.DebounceKey)),
            AgentTerminalId = NormalizeOptionalIdentifier(
                envelope.AgentTerminalId,
                nameof(envelope.AgentTerminalId)),
            PaneId = NormalizeOptionalIdentifier(
                envelope.PaneId,
                nameof(envelope.PaneId)),
            TaskId = NormalizeOptionalIdentifier(
                envelope.TaskId,
                nameof(envelope.TaskId)),
            RedactedSummary = NormalizeSummary(envelope.RedactedSummary),
            PayloadSha256 = NormalizeSha256(envelope.PayloadSha256),
        };
        if (normalized.DeliveryMode == ActivityDeliveryMode.Debounced &&
            normalized.Urgency == ActivityUrgency.Normal &&
            normalized.DebounceKey is null)
        {
            throw new ActivityEventContractException(
                "A normal debounced activity event requires a debounce key.");
        }

        return new NormalizedActivityEvent(
            ingestSequence,
            normalized,
            ActivityEventCanonicalHash.ComputeIdentitySha256(normalized),
            ActivityEventCanonicalHash.ComputeEnvelopeSha256(normalized));
    }

    private static void ValidateEnum<T>(T value, string name)
        where T : struct, Enum
    {
        if (!Enum.IsDefined(value))
        {
            throw new ActivityEventContractException(
                $"Activity event field {name} has unsupported value '{value}'.");
        }
    }

    private static string NormalizeIdentifier(
        string value,
        string name,
        int maximumLength)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            throw new ActivityEventContractException(
                $"Activity event field {name} must be a non-blank, unpadded identifier of at most {maximumLength} characters without control characters.");
        }

        var normalized = value.Normalize(NormalizationForm.FormC);
        if (!string.Equals(normalized, normalized.Trim(), StringComparison.Ordinal) ||
            normalized.Length > maximumLength ||
            normalized.Any(char.IsControl))
        {
            throw new ActivityEventContractException(
                $"Activity event field {name} must be a non-blank, unpadded identifier of at most {maximumLength} characters without control characters.");
        }

        return normalized;
    }

    private static string? NormalizeOptionalIdentifier(string? value, string name) =>
        value is null
            ? null
            : NormalizeIdentifier(value, name, MaximumIdentifierLength);

    private static string NormalizeSummary(string value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            throw new ActivityEventContractException(
                "The already-redacted activity summary cannot be blank.");
        }

        var normalized = value
            .Replace("\r\n", "\n", StringComparison.Ordinal)
            .Replace('\r', '\n')
            .Normalize(NormalizationForm.FormC);
        if (normalized.Length > MaximumSummaryLength ||
            normalized.Any(character =>
                char.IsControl(character) && character is not ('\n' or '\t')))
        {
            throw new ActivityEventContractException(
                $"The already-redacted activity summary must be at most {MaximumSummaryLength} characters and cannot contain unsupported control characters.");
        }

        return normalized;
    }

    private static string NormalizeSha256(string value)
    {
        if (value is null || value.Length != 64 || !value.All(IsHexCharacter))
        {
            throw new ActivityEventContractException(
                "The activity payload SHA-256 must contain exactly 64 hexadecimal characters.");
        }

        return value.ToUpperInvariant();
    }

    private static bool IsHexCharacter(char value) =>
        value is >= '0' and <= '9' or >= 'A' and <= 'F' or >= 'a' and <= 'f';

    private static void EnsureUtc(DateTimeOffset value, string name)
    {
        if (value.Offset != TimeSpan.Zero)
        {
            throw new ActivityEventContractException(
                $"Activity event field {name} must be UTC.");
        }
    }
}

public static class ActivityEventCanonicalHash
{
    public static string ComputeIdentitySha256(ActivityEventEnvelope envelope)
    {
        ArgumentNullException.ThrowIfNull(envelope);
        using var writer = new CanonicalHashWriter("HerdrOps.ActivityIdentity.v1");
        writer.Write((int)envelope.SourceKind);
        writer.Write(envelope.SourceInstanceId);
        writer.Write(envelope.SourceEpoch);
        writer.Write(envelope.SourceEventId);
        return writer.Finish();
    }

    public static string ComputeEnvelopeSha256(ActivityEventEnvelope envelope)
    {
        ArgumentNullException.ThrowIfNull(envelope);
        using var writer = new CanonicalHashWriter("HerdrOps.ActivityEnvelope.v1");
        writer.Write(envelope.ContractVersion);
        writer.Write(envelope.SourceEventId);
        writer.Write((int)envelope.SourceKind);
        writer.Write(envelope.SourceInstanceId);
        writer.Write(envelope.SourceEpoch);
        writer.Write(envelope.SourceSequence);
        writer.Write((int)envelope.Confidence);
        writer.Write((int)envelope.Urgency);
        writer.Write((int)envelope.DeliveryMode);
        writer.Write(envelope.EventType);
        writer.Write(envelope.OccurredUtc);
        writer.Write(envelope.ObservedUtc);
        writer.Write(envelope.CorrelationId.ToString("D"));
        writer.Write(envelope.DebounceKey);
        writer.Write(envelope.AgentTerminalId);
        writer.Write(envelope.PaneId);
        writer.Write(envelope.TaskId);
        writer.Write(envelope.ProcessId);
        writer.Write(envelope.RedactedSummary);
        writer.Write(envelope.PayloadSha256);
        return writer.Finish();
    }
}

internal sealed class CanonicalHashWriter : IDisposable
{
    private readonly IncrementalHash _hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
    private bool _finished;

    public CanonicalHashWriter(string domain)
    {
        Write(domain);
    }

    public void Write(string? value)
    {
        if (value is null)
        {
            WriteLength(-1);
            return;
        }

        var bytes = Encoding.UTF8.GetBytes(value);
        WriteLength(bytes.Length);
        _hash.AppendData(bytes);
    }

    public void Write(int value)
    {
        Span<byte> bytes = stackalloc byte[sizeof(int)];
        BinaryPrimitives.WriteInt32LittleEndian(bytes, value);
        _hash.AppendData(bytes);
    }

    public void Write(int? value)
    {
        Write(value.HasValue ? 1 : 0);
        if (value.HasValue)
        {
            Write(value.Value);
        }
    }

    public void Write(long value)
    {
        Span<byte> bytes = stackalloc byte[sizeof(long)];
        BinaryPrimitives.WriteInt64LittleEndian(bytes, value);
        _hash.AppendData(bytes);
    }

    public void Write(long? value)
    {
        Write(value.HasValue ? 1 : 0);
        if (value.HasValue)
        {
            Write(value.Value);
        }
    }

    public void Write(bool value) => Write(value ? 1 : 0);

    public void Write(DateTimeOffset value) =>
        Write(value.ToString("O", CultureInfo.InvariantCulture));

    public string Finish()
    {
        ObjectDisposedException.ThrowIf(_finished, this);
        _finished = true;
        return Convert.ToHexString(_hash.GetHashAndReset());
    }

    public void Dispose()
    {
        _hash.Dispose();
        _finished = true;
    }

    private void WriteLength(int value)
    {
        Span<byte> length = stackalloc byte[sizeof(int)];
        BinaryPrimitives.WriteInt32LittleEndian(length, value);
        _hash.AppendData(length);
    }
}

public sealed class ActivityEventContractException : ArgumentException
{
    public ActivityEventContractException(string message)
        : base(message)
    {
    }
}
