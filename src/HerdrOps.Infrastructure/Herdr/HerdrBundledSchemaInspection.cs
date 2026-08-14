using HerdrOps.Contracts;

namespace HerdrOps.Infrastructure.Herdr;

public sealed record HerdrBundledSchemaGroupSummary(
    string Name,
    int DefinitionCount);

/// <summary>
/// Contract evidence produced by extracting the bundled JSON Schema from an admitted executable.
/// No Herdr process, session, or Named Pipe is invoked by this inspection.
/// </summary>
public sealed record HerdrBundledSchemaInspection(
    HerdrBundledSchemaStatus Status,
    EvidenceClass EvidenceClass,
    bool RuntimeObserved,
    bool SessionControlInvoked,
    string ContractId,
    int ContractRevision,
    string RequestedExecutablePath,
    string? ResolvedExecutablePath,
    string? ReleaseId,
    string? ExecutableSha256,
    long? SchemaStartOffset,
    int? SchemaDocumentLength,
    string? SchemaDocumentSha256,
    string? JsonSchemaDraft,
    int? Protocol,
    int? SchemaVersion,
    IReadOnlyList<HerdrBundledSchemaGroupSummary> SchemaGroups,
    IReadOnlyList<string> MissingSchemaGroups,
    IReadOnlyList<string> MissingSchemaDefinitions,
    IReadOnlyList<string> DefinitionCountMismatches,
    IReadOnlyList<string> MissingRequestMethods,
    IReadOnlyList<string> MissingResponseTypes,
    IReadOnlyList<string> MissingSubscriptionEventKinds,
    string Message)
{
    public bool IsCompatible => Status == HerdrBundledSchemaStatus.Compatible;
}

public sealed record HerdrBundledSchemaExtraction(
    HerdrBundledSchemaInspection Inspection,
    byte[]? SchemaDocumentBytes)
{
    public bool IsCompatible => Inspection.IsCompatible;
}
