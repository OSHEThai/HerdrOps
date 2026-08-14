using HerdrOps.Contracts;

namespace HerdrOps.Infrastructure.Herdr;

/// <summary>
/// Contract evidence produced by static inspection of an installed Herdr executable.
/// It does not prove a running Herdr session or successful Named Pipe communication.
/// </summary>
public sealed record HerdrProtocolInspection(
    HerdrProtocolCompatibilityStatus Status,
    EvidenceClass EvidenceClass,
    bool RuntimeObserved,
    string ContractId,
    int ContractRevision,
    string RequestedExecutablePath,
    string? ResolvedExecutablePath,
    string? ReleaseId,
    long? ExecutableLength,
    string? ExecutableSha256,
    string? ContractSchemaFingerprintSha256,
    IReadOnlyList<string> MissingRpcMethods,
    IReadOnlyList<string> MissingProtocolShapes,
    IReadOnlyList<string> MissingTransportMarkers,
    string Message)
{
    public bool IsCompatible => Status == HerdrProtocolCompatibilityStatus.Compatible;
}
