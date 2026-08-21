using System.Text.Json;

namespace HerdrOps.Contracts.ReviewIpc;

public static class HerdrOpsReviewCommandProtocol
{
    public const int Version = 1;
    public const int MaximumFrameBytes = 512 * 1024;
    public const string AppClientRole = "app";
    public const string CliClientRole = "cli";
    public const string AuthorizationScope = "current-user-core-authority";
    public const string CoreSource = "HerdrOps.Core";
    public const string AppSource = "HerdrOps.App";
    public const string CliSource = "HerdrOps.Cli";

    public static class MessageTypes
    {
        public const string Hello = "hello";
        public const string HelloAccepted = "hello-accepted";
        public const string Capabilities = "get-review-capabilities";
        public const string CapabilitiesResult = "review-capabilities-result";
        public const string Execute = "execute-review-command";
        public const string Result = "review-command-result";
        public const string Error = "error";
    }

    public static class ErrorCodes
    {
        public const string InvalidProtocolVersion = "invalid-protocol-version";
        public const string UnauthorizedClient = "unauthorized-client";
        public const string InvalidHandshake = "invalid-handshake";
        public const string InvalidMessage = "invalid-message";
        public const string CoreUnavailable = "core-unavailable";
    }
}

public sealed record HerdrOpsReviewCommandEnvelope(
    int ProtocolVersion,
    string MessageType,
    DateTimeOffset SentUtc,
    string Source,
    Guid CorrelationId,
    JsonElement Payload);

public sealed record HerdrOpsReviewCommandHello(
    string ClientRole,
    string ClientInstanceId);

public sealed record HerdrOpsReviewCommandHelloAccepted(
    string ServerInstanceId,
    string AuthorizationScope);

public sealed record HerdrOpsReviewCommandError(
    string Code,
    string Message);

public sealed record HerdrOpsReviewCapabilitiesRequest(
    string ReviewerActorId,
    string IncidentId,
    DateTimeOffset ObservedUtc);

public sealed record HerdrOpsReviewCapabilitiesResult(
    bool HasCurrentAuthority,
    int? ReviewerRole,
    int? IncidentState,
    long? IncidentSequence,
    IReadOnlyList<int> AllowedDecisionKinds,
    string Message);

public sealed record HerdrOpsReviewCommandRequest(
    int ContractVersion,
    Guid CommandId,
    string IncidentId,
    int ExpectedState,
    long ExpectedSequence,
    string ReviewerActorId,
    int DecisionKind,
    string Reason,
    IReadOnlyList<string> EvidenceIdentitySha256s);

public sealed record HerdrOpsReviewCliCommandInput(
    int ContractVersion,
    Guid CommandId,
    string IncidentId,
    int ExpectedState,
    long ExpectedSequence,
    int DecisionKind,
    string Reason,
    IReadOnlyList<string> EvidenceIdentitySha256s);

/// <summary>
/// Strict, bounded production CLI/Core input for registering a compliance review incident.
/// Carries only immutable registration data; no reviewer role, occurrence timestamp, or
/// authority fields can be injected here.
/// </summary>
public sealed record HerdrOpsComplianceIncidentRegistrationInput(
    int ContractVersion,
    Guid CommandId,
    string IncidentId,
    string TaskId,
    string SubjectActorId,
    DateTimeOffset RegisteredUtc,
    IReadOnlyList<string> EvidenceIdentitySha256s);

public sealed record HerdrOpsComplianceIncidentRegistrationResult(
    bool Registered,
    bool WasAlreadyPresent,
    string IncidentId,
    string RegistrationSha256,
    int State,
    long Sequence);

public sealed record HerdrOpsReviewCommandResult(
    bool IsAccepted,
    int RejectionCode,
    string Message,
    HerdrOpsComplianceReviewIncident? Incident,
    HerdrOpsComplianceReviewAuditEvent? AuditEvent,
    bool WasAlreadyPresent);

public sealed record HerdrOpsComplianceReviewIncident(
    int ContractVersion,
    string IncidentId,
    string TaskId,
    string SubjectActorId,
    DateTimeOffset RegisteredUtc,
    IReadOnlyList<string> InitialEvidenceIdentitySha256s,
    string RegistrationSha256,
    int State,
    long Sequence,
    DateTimeOffset UpdatedUtc,
    Guid? LastAuditEventId,
    string? LastAuditSha256);

public sealed record HerdrOpsComplianceReviewAuditEvent(
    int ContractVersion,
    Guid AuditEventId,
    string IncidentId,
    string TaskId,
    string SubjectActorId,
    long Sequence,
    string ReviewerActorId,
    int ReviewerRole,
    Guid AuthorityProvenanceEventId,
    long AuthorityProvenanceSequence,
    string AuthorityProvenanceSha256,
    int DecisionKind,
    int PreviousState,
    int ResultState,
    string Reason,
    DateTimeOffset OccurredUtc,
    IReadOnlyList<string> EvidenceIdentitySha256s,
    string EvidenceSetSha256,
    string? PreviousAuditSha256,
    string AuditSha256);

public sealed class HerdrOpsReviewCommandProtocolException : IOException
{
    public HerdrOpsReviewCommandProtocolException(string message)
        : base(message)
    {
    }

    public HerdrOpsReviewCommandProtocolException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}
