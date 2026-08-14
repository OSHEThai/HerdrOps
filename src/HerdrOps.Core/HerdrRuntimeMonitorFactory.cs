using HerdrOps.Infrastructure.Herdr;

namespace HerdrOps.Core;

public sealed record HerdrRuntimeAdmission(
    string ExecutablePath,
    string ReleaseId,
    string ExecutableSha256,
    string ProtocolContractId,
    int ProtocolContractRevision,
    string BundledSchemaContractId,
    int BundledSchemaContractRevision,
    string BundledSchemaSha256,
    int Protocol,
    HerdrPipeEndpoint Endpoint);

public sealed record HerdrAdmittedRuntimeMonitor(
    HerdrRuntimeMonitor Monitor,
    HerdrRuntimeAdmission Admission,
    IHerdrPaneInspectionClient PaneInspectionClient);

public sealed class HerdrRuntimeAdmissionException : IOException
{
    public HerdrRuntimeAdmissionException(string message)
        : base(message)
    {
    }
}

public sealed class HerdrRuntimeMonitorFactory
{
    public HerdrAdmittedRuntimeMonitor Create(
        string? explicitExecutablePath = null,
        string? explicitSocketPath = null,
        HerdrOps.Domain.Herdr.HerdrSessionState? initialState = null)
    {
        var executablePath = HerdrInstallationLocator.FindExecutable(explicitExecutablePath);
        if (string.IsNullOrWhiteSpace(executablePath))
        {
            throw new HerdrRuntimeAdmissionException(
                "Herdr executable was not discovered for runtime admission.");
        }

        var protocolInspection = new HerdrProtocolInspector().Inspect(executablePath);
        if (!protocolInspection.IsCompatible)
        {
            throw new HerdrRuntimeAdmissionException(
                $"Herdr protocol admission failed: {protocolInspection.Message}");
        }

        var schemaInspection = new HerdrBundledSchemaExtractor().Extract(executablePath).Inspection;
        if (!schemaInspection.IsCompatible)
        {
            throw new HerdrRuntimeAdmissionException(
                $"Herdr bundled-schema admission failed: {schemaInspection.Message}");
        }

        if (!string.Equals(
                protocolInspection.ResolvedExecutablePath,
                schemaInspection.ResolvedExecutablePath,
                StringComparison.OrdinalIgnoreCase) ||
            !string.Equals(
                protocolInspection.ReleaseId,
                schemaInspection.ReleaseId,
                StringComparison.Ordinal) ||
            !string.Equals(
                protocolInspection.ExecutableSha256,
                schemaInspection.ExecutableSha256,
                StringComparison.Ordinal))
        {
            throw new HerdrRuntimeAdmissionException(
                "Herdr protocol and bundled-schema inspections did not bind to the same executable identity.");
        }

        var endpoint = new HerdrPipeEndpointResolver().Resolve(explicitSocketPath);
        var admission = new HerdrRuntimeAdmission(
            Require(protocolInspection.ResolvedExecutablePath, "resolved executable path"),
            Require(protocolInspection.ReleaseId, "release id"),
            Require(protocolInspection.ExecutableSha256, "executable SHA-256"),
            protocolInspection.ContractId,
            protocolInspection.ContractRevision,
            schemaInspection.ContractId,
            schemaInspection.ContractRevision,
            Require(schemaInspection.SchemaDocumentSha256, "bundled schema SHA-256"),
            schemaInspection.Protocol ?? throw new HerdrRuntimeAdmissionException(
                "The admitted bundled schema did not report a protocol version."),
            endpoint);
        var monitorClient = new HerdrNamedPipeApiClient(
            serverIdentityVerifier: new ExpectedHerdrServerIdentityVerifier(admission.ExecutableSha256));
        var paneInspectionClient = new HerdrNamedPipeApiClient(
            serverIdentityVerifier: new ExpectedHerdrServerIdentityVerifier(admission.ExecutableSha256));
        return new HerdrAdmittedRuntimeMonitor(
            new HerdrRuntimeMonitor(monitorClient, endpoint, initialState: initialState),
            admission,
            paneInspectionClient);
    }

    private static string Require(string? value, string description) =>
        !string.IsNullOrWhiteSpace(value)
            ? value
            : throw new HerdrRuntimeAdmissionException(
                $"The compatible Herdr inspection omitted its {description}.");
}
