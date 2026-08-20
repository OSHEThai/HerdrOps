namespace HerdrOps.Contracts;

/// <summary>
/// Describes one required schema group and the definitions admitted within it.
/// </summary>
public sealed record HerdrBundledSchemaGroupRequirement(
    string Name,
    int ExpectedDefinitionCount,
    IReadOnlyList<string> RequiredDefinitions);

/// <summary>
/// Defines the exact bundled JSON Schema document accepted by HerdrOps.
/// </summary>
public sealed record HerdrBundledSchemaSupportPolicy(
    string ContractId,
    int Revision,
    string JsonSchemaDraft,
    int Protocol,
    int SchemaVersion,
    int ExpectedDocumentLength,
    string ExpectedDocumentSha256,
    IReadOnlyList<HerdrBundledSchemaGroupRequirement> RequiredGroups,
    IReadOnlyList<string> RequiredRequestMethods,
    IReadOnlyList<string> RequiredResponseTypes,
    IReadOnlyList<string> RequiredSubscriptionEventKinds);

/// <summary>
/// Successor contract for the full JSON Schema bundled in the exact Herdr binary admitted by
/// <see cref="HerdrProtocolContractV082Preview"/>.
/// </summary>
public static class HerdrBundledSchemaContractV20
{
    public const string ContractId = "herdr-0.8.2-preview-bundled-schema-v2";

    public const int Revision = 2;

    public const string JsonSchemaDraft = "https://json-schema.org/draft/2020-12/schema";

    public const int Protocol = 20;

    public const int SchemaVersion = 1;

    public const int DocumentLength = 265_595;

    public const string DocumentSha256 =
        "3B34717C8B828FAF4E4A1D4DAC5953417712C8EB71A54237FFAD7582C7FF5679";

    public static HerdrBundledSchemaSupportPolicy Policy { get; } = new(
        ContractId,
        Revision,
        JsonSchemaDraft,
        Protocol,
        SchemaVersion,
        DocumentLength,
        DocumentSha256,
        Array.AsReadOnly(
        [
            new HerdrBundledSchemaGroupRequirement(
                "error_response",
                1,
                Array.AsReadOnly(["ErrorBody"])),
            new HerdrBundledSchemaGroupRequirement(
                "event",
                16,
                Array.AsReadOnly(["EventData", "EventKind"])),
            new HerdrBundledSchemaGroupRequirement(
                "request",
                107,
                Array.AsReadOnly(["EventsSubscribeParams", "Subscription"])),
            new HerdrBundledSchemaGroupRequirement(
                "subscription_event",
                10,
                Array.AsReadOnly(
                [
                    "PaneAgentStatusChangedEvent",
                    "SubscriptionEventData",
                    "SubscriptionEventKind",
                ])),
            new HerdrBundledSchemaGroupRequirement(
                "success_response",
                67,
                Array.AsReadOnly(["ResponseResult", "SessionSnapshot"])),
        ]),
        Array.AsReadOnly(["session.snapshot", "events.subscribe"]),
        Array.AsReadOnly(["session_snapshot", "subscription_started"]),
        Array.AsReadOnly(["pane.agent_status_changed"]));
}
