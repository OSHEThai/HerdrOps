using System.Text.Json;
using System.Text.Json.Serialization;

namespace HerdrOps.Contracts.StateIpc;

public static class HerdrOpsStateIpcProtocol
{
    public const int Version = 2;
    public const int MaximumFrameBytes = 4 * 1024 * 1024;
    public const string AppClientRole = "app";
    public const string AuthorizationScope = "current-user";
    public const string CoreSource = "HerdrOps.Core";
    public const string AppSource = "HerdrOps.App";
    public const string Issue44AcceptanceNonceEnvironmentVariable =
        "HERDROPS_ISSUE44_ACCEPTANCE_NONCE";
    public const string Issue44AcceptanceEvidencePathEnvironmentVariable =
        "HERDROPS_ISSUE44_ACCEPTANCE_EVIDENCE_PATH";

    public static class MessageTypes
    {
        public const string Hello = "hello";
        public const string HelloAccepted = "hello-accepted";
        public const string Snapshot = "state-snapshot";
        public const string Delta = "state-delta";
        public const string RuntimeHealth = "runtime-health";
        public const string Error = "error";
    }

    public static class ErrorCodes
    {
        public const string InvalidProtocolVersion = "invalid-protocol-version";
        public const string UnauthorizedClient = "unauthorized-client";
        public const string InvalidHandshake = "invalid-handshake";
        public const string InvalidMessage = "invalid-message";
    }
}

public sealed record HerdrOpsStateIpcEnvelope(
    int ProtocolVersion,
    string MessageType,
    long Sequence,
    DateTimeOffset SentUtc,
    string Source,
    Guid CorrelationId,
    JsonElement Payload);

public sealed record HerdrOpsStateIpcHello(
    string ClientRole,
    string ClientInstanceId,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? AcceptanceNonce = null);

public sealed record HerdrOpsStateIpcHelloAccepted(
    string ServerInstanceId,
    string AuthorizationScope,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? AcceptanceNonce = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    int? ServerProcessId = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    long? ServerProcessStartUtcTicks = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? ServerExecutablePath = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? ServerExecutableSha256 = null);

public sealed record HerdrOpsStateIpcError(
    string Code,
    string Message);

public sealed record HerdrOpsStateSnapshotPayload(
    HerdrSessionStateContract State,
    string StateSha256,
    HerdrRuntimeHealthContract RuntimeHealth);

public sealed record HerdrOpsStateDeltaPayload(
    HerdrSessionStateDeltaContract Delta,
    string ResultStateSha256,
    HerdrRuntimeHealthContract RuntimeHealth);

public sealed record HerdrOpsRuntimeHealthPayload(
    HerdrRuntimeHealthContract RuntimeHealth,
    string StateSha256);

public sealed record HerdrRuntimeHealthContract(
    string Status,
    DateTimeOffset LastTransitionUtc,
    DateTimeOffset? LastAcceptedStateUtc,
    long BootstrapCount,
    long EventCount,
    long DisconnectCount,
    long ReconciliationCount)
{
    public static HerdrRuntimeHealthContract Starting(DateTimeOffset observedUtc) => new(
        "Starting",
        observedUtc,
        null,
        0,
        0,
        0,
        0);
}

public sealed record HerdrSessionStateContract(
    string Version,
    int Protocol,
    long ConnectionEpoch,
    long LastIngestSequence,
    IReadOnlyList<HerdrWorkspaceStateContract> Workspaces,
    IReadOnlyList<HerdrTabStateContract> Tabs,
    IReadOnlyList<HerdrPaneStateContract> Panes,
    IReadOnlyList<HerdrAgentStateContract> Agents,
    string? FocusedWorkspaceId,
    string? FocusedTabId,
    string? FocusedPaneId)
{
    public static HerdrSessionStateContract Empty { get; } = new(
        string.Empty,
        0,
        0,
        0,
        Array.Empty<HerdrWorkspaceStateContract>(),
        Array.Empty<HerdrTabStateContract>(),
        Array.Empty<HerdrPaneStateContract>(),
        Array.Empty<HerdrAgentStateContract>(),
        null,
        null,
        null);
}

public sealed record HerdrWorkspaceStateContract(
    string WorkspaceId,
    int Number,
    string Label,
    bool Focused,
    int PaneCount,
    int TabCount,
    string ActiveTabId,
    string AgentStatus);

public sealed record HerdrTabStateContract(
    string TabId,
    string WorkspaceId,
    int Number,
    string Label,
    bool Focused,
    int PaneCount,
    string AgentStatus);

public sealed record HerdrPaneStateContract(
    string PaneId,
    string TerminalId,
    string WorkspaceId,
    string TabId,
    bool Focused,
    string AgentStatus,
    ulong Revision,
    string? Agent,
    string? DisplayAgent,
    string? Title,
    string? CurrentDirectory,
    string? ForegroundCurrentDirectory,
    string? TerminalTitle);

public sealed record HerdrAgentStateContract(
    string TerminalId,
    string WorkspaceId,
    string TabId,
    string PaneId,
    bool Focused,
    string AgentStatus,
    ulong Revision,
    ulong StateChangeSequence,
    string? Agent,
    string? DisplayAgent,
    string? Name,
    string? Title,
    string? CurrentDirectory,
    string? ForegroundCurrentDirectory,
    string? TerminalTitle,
    bool? InteractiveReady,
    bool? LaunchPending,
    bool? ScreenDetectionSkipped);

public sealed record HerdrSessionStateDeltaContract(
    long FromSequence,
    long ToSequence,
    string Version,
    int Protocol,
    long ConnectionEpoch,
    IReadOnlyList<HerdrWorkspaceStateContract> UpsertedWorkspaces,
    IReadOnlyList<string> RemovedWorkspaceIds,
    IReadOnlyList<HerdrTabStateContract> UpsertedTabs,
    IReadOnlyList<string> RemovedTabIds,
    IReadOnlyList<HerdrPaneStateContract> UpsertedPanes,
    IReadOnlyList<string> RemovedPaneIds,
    IReadOnlyList<HerdrAgentStateContract> UpsertedAgents,
    IReadOnlyList<string> RemovedAgentTerminalIds,
    string? FocusedWorkspaceId,
    string? FocusedTabId,
    string? FocusedPaneId);

public sealed class HerdrOpsStateIpcProtocolException : IOException
{
    public HerdrOpsStateIpcProtocolException(string message)
        : base(message)
    {
    }

    public HerdrOpsStateIpcProtocolException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}
