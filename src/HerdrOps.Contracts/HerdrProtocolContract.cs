namespace HerdrOps.Contracts;

/// <summary>
/// Identifies one exact Herdr executable accepted by a protocol support policy.
/// </summary>
public sealed record HerdrBinaryIdentity(
    string ReleaseId,
    string Sha256);

/// <summary>
/// Describes one serialized protocol shape marker extracted from the installed Herdr binary.
/// </summary>
public sealed record HerdrProtocolShape(
    string Name,
    int ElementCount,
    string BinaryMarker);

/// <summary>
/// Defines the exact executable identities and read-only protocol surface HerdrOps accepts.
/// </summary>
public sealed record HerdrProtocolSupportPolicy(
    string ContractId,
    int Revision,
    EvidenceClass EvidenceClass,
    IReadOnlyList<HerdrBinaryIdentity> CompatibleBinaries,
    IReadOnlyList<string> RequiredRpcMethods,
    IReadOnlyList<HerdrProtocolShape> RequiredShapes,
    IReadOnlyList<string> RequiredTransportMarkers);

/// <summary>
/// v0.2 compatibility contract extracted from the installed Herdr preview binary.
/// Exact binary binding is intentional: an update must be inspected and admitted as a successor.
/// </summary>
public static class HerdrProtocolContractV080Preview
{
    public const string ContractId = "herdr-0.8.0-preview-readonly-monitoring-v1";

    public const int Revision = 1;

    public const string SupportedReleaseId =
        "0.8.0-preview.2026-08-04-d78e3d3b5126-x86_64-pc-windows-msvc";

    public const string SupportedBinarySha256 =
        "6F470DA358D6713B6BEBAB922FFB1F5FE1D3D288CC6F374C7DCA1B4A9837A542";

    public static HerdrProtocolSupportPolicy Policy { get; } = new(
        ContractId,
        Revision,
        EvidenceClass.Contract,
        Array.AsReadOnly(
        [
            new HerdrBinaryIdentity(SupportedReleaseId, SupportedBinarySha256),
        ]),
        Array.AsReadOnly(
        [
            "session.snapshot",
            "workspace.list",
            "tab.list",
            "pane.list",
            "agent.list",
            "agent.get",
            "pane.process_info",
            "pane.read",
            "events.subscribe",
        ]),
        Array.AsReadOnly(
        [
            new HerdrProtocolShape("SessionSnapshot", 10, "struct SessionSnapshot with 10 elements"),
            new HerdrProtocolShape("WorkspaceInfo", 10, "struct WorkspaceInfo with 10 elements"),
            new HerdrProtocolShape("TabInfo", 7, "struct TabInfo with 7 elements"),
            new HerdrProtocolShape("PaneInfo", 19, "struct PaneInfo with 19 elements"),
            new HerdrProtocolShape("AgentInfo", 22, "struct AgentInfo with 22 elements"),
            new HerdrProtocolShape("PaneProcessInfo", 5, "struct PaneProcessInfo with 5 elements"),
            new HerdrProtocolShape("PaneReadParams", 5, "struct PaneReadParams with 5 elements"),
            new HerdrProtocolShape("PaneReadResult", 8, "struct PaneReadResult with 8 elements"),
            new HerdrProtocolShape("EventsSubscribeParams", 1, "struct EventsSubscribeParams with 1 element"),
            new HerdrProtocolShape(
                "Subscription.PaneAgentStatusChanged",
                2,
                "struct variant Subscription::PaneAgentStatusChanged with 2 elements"),
            new HerdrProtocolShape(
                "PaneAgentStatusChangedEvent",
                7,
                "struct PaneAgentStatusChangedEvent with 7 elements"),
            new HerdrProtocolShape(
                "SubscriptionEventEnvelope",
                2,
                "struct SubscriptionEventEnvelope with 2 elements"),
        ]),
        Array.AsReadOnly(
        [
            "HERDR_ENV",
            "HERDR_SOCKET_PATH",
            "HERDR_PANE_ID",
            "process.platform === \"win32\"",
        ]));
}
