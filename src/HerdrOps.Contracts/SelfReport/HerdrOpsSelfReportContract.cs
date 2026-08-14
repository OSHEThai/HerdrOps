using System.Text.Json;

namespace HerdrOps.Contracts.SelfReport;

public static class HerdrOpsSelfReportProtocol
{
    public const int Version = 1;
    public const int MaximumFrameBytes = 64 * 1024;
    public const string AuthorizationScope = "current-user";
    public const string CliSource = "HerdrOps.Cli";
    public const string CoreSource = "HerdrOps.Core";

    public static class MessageTypes
    {
        public const string Submit = "self-report-submit";
        public const string Accepted = "self-report-accepted";
        public const string Rejected = "self-report-rejected";
    }

    public static class EventTypes
    {
        public const string Assignment = "assignment";
        public const string Acknowledgement = "acknowledgement";
        public const string Delegation = "delegation";
        public const string Progress = "progress";
        public const string Deviation = "deviation";
        public const string Evidence = "evidence";
        public const string Handoff = "handoff";

        public static IReadOnlyList<string> All { get; } =
        [
            Assignment,
            Acknowledgement,
            Delegation,
            Progress,
            Deviation,
            Evidence,
            Handoff,
        ];

        public static bool IsSupported(string value) =>
            All.Contains(value, StringComparer.Ordinal);
    }

    public static class ResultCodes
    {
        public const string Accepted = "accepted";
        public const string AcceptedIdempotent = "accepted-idempotent";
        public const string InvalidProtocolVersion = "invalid-protocol-version";
        public const string UnauthorizedClient = "unauthorized-client";
        public const string InvalidMessage = "invalid-message";
        public const string InvalidSchema = "invalid-schema";
        public const string UnknownTask = "unknown-task";
        public const string EventIdConflict = "event-id-conflict";
        public const string CapacityExceeded = "capacity-exceeded";
        public const string InternalError = "internal-error";
        public const string CoreUnavailable = "core-unavailable";
        public const string InvalidCoreResponse = "invalid-core-response";
        public const string InvalidArguments = "invalid-arguments";

        public static IReadOnlyList<string> All { get; } =
        [
            Accepted,
            AcceptedIdempotent,
            InvalidProtocolVersion,
            UnauthorizedClient,
            InvalidMessage,
            InvalidSchema,
            UnknownTask,
            EventIdConflict,
            CapacityExceeded,
            InternalError,
            CoreUnavailable,
            InvalidCoreResponse,
            InvalidArguments,
        ];

        public static bool IsKnown(string value) =>
            All.Contains(value, StringComparer.Ordinal);
    }
}

public sealed record HerdrOpsSelfReportCommandInput(
    int ContractVersion,
    Guid EventId,
    string TaskId,
    string ActorId,
    string ActorRole,
    DateTimeOffset OccurredUtc,
    string Summary,
    Guid? ParentEventId,
    string? TargetAgentId,
    int? ProgressPercent,
    string? DeviationReason,
    string? EvidenceReference,
    string? EvidenceSha256,
    string? HandoffNote);

public sealed record HerdrOpsSelfReportSubmission(
    int ContractVersion,
    Guid EventId,
    string EventType,
    string TaskId,
    string ActorId,
    string ActorRole,
    DateTimeOffset OccurredUtc,
    string Summary,
    Guid? ParentEventId,
    string? TargetAgentId,
    int? ProgressPercent,
    string? DeviationReason,
    string? EvidenceReference,
    string? EvidenceSha256,
    string? HandoffNote);

public sealed record HerdrOpsSelfReportEnvelope(
    int ProtocolVersion,
    string MessageType,
    long Sequence,
    DateTimeOffset SentUtc,
    string Source,
    Guid CorrelationId,
    JsonElement Payload);

public sealed record HerdrOpsSelfReportResult(
    bool Accepted,
    string Code,
    string Message,
    Guid? EventId,
    string? EventType,
    string? TaskId,
    Guid? CorrelationId,
    long? Sequence,
    DateTimeOffset? AcceptedUtc,
    string? AcceptedSource,
    string? EventSha256);

public sealed record HerdrOpsSelfReportClientError(
    string Code,
    string Message);

public sealed class HerdrOpsSelfReportProtocolException : IOException
{
    public HerdrOpsSelfReportProtocolException(string message)
        : base(message)
    {
    }

    public HerdrOpsSelfReportProtocolException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}
