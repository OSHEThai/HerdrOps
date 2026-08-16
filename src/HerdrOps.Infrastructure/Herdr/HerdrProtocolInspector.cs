using HerdrOps.Contracts;

namespace HerdrOps.Infrastructure.Herdr;

public sealed class HerdrProtocolInspector
{
    private readonly HerdrProtocolSupportPolicy _policy;
    private readonly IHerdrExecutableAdmissionScanner _scanner;

    public HerdrProtocolInspector(
        HerdrProtocolSupportPolicy? policy = null,
        IHerdrExecutableAdmissionScanner? scanner = null)
    {
        _policy = policy ?? HerdrProtocolContractV080Preview.Policy;
        _scanner = scanner ?? new HerdrExecutableAdmissionScanner();
    }

    public HerdrProtocolInspection Inspect(string executablePath)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(executablePath);

        var requestedPath = Path.GetFullPath(executablePath);
        if (!File.Exists(requestedPath))
        {
            return Failure(
                HerdrProtocolCompatibilityStatus.ExecutableNotFound,
                requestedPath,
                resolvedPath: null,
                releaseId: null,
                executableLength: null,
                executableSha256: null,
                message: $"Herdr executable was not found: {requestedPath}");
        }

        try
        {
            return Inspect(_scanner.Scan(
                requestedPath,
                _policy,
                captureBundledSchema: false));
        }
        catch (HerdrExecutableAdmissionScanException exception)
        {
            return InspectFailure(exception);
        }
    }

    internal HerdrProtocolInspection InspectFailure(
        HerdrExecutableAdmissionScanException exception)
    {
        ArgumentNullException.ThrowIfNull(exception);
        return Failure(
            exception.Failure == HerdrExecutableAdmissionScanFailure.NotFound
                ? HerdrProtocolCompatibilityStatus.ExecutableNotFound
                : HerdrProtocolCompatibilityStatus.ExecutableUnreadable,
            exception.RequestedPath,
            exception.FinalPath,
            exception.ReleaseId,
            exception.Length,
            executableSha256: null,
            exception.Message);
    }

    public HerdrProtocolInspection Inspect(HerdrExecutableAdmissionSnapshot snapshot)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        if (!snapshot.HasMzHeader)
        {
            return Failure(
                HerdrProtocolCompatibilityStatus.InvalidPortableExecutable,
                snapshot.RequestedPath,
                snapshot.FinalPath,
                snapshot.ReleaseId,
                snapshot.Length,
                snapshot.Sha256,
                message: "Herdr executable does not begin with a Windows PE MZ header.");
        }

        var compatibleRelease = _policy.CompatibleBinaries
            .Where(identity => string.Equals(
                identity.ReleaseId,
                snapshot.ReleaseId,
                StringComparison.Ordinal))
            .ToArray();
        if (compatibleRelease.Length == 0)
        {
            return Failure(
                HerdrProtocolCompatibilityStatus.UnsupportedRelease,
                snapshot.RequestedPath,
                snapshot.FinalPath,
                snapshot.ReleaseId,
                snapshot.Length,
                snapshot.Sha256,
                message: $"Herdr release '{snapshot.ReleaseId}' is not admitted by contract '{_policy.ContractId}'.");
        }

        if (!compatibleRelease.Any(identity => string.Equals(
                identity.Sha256,
                snapshot.Sha256,
                StringComparison.OrdinalIgnoreCase)))
        {
            return Failure(
                HerdrProtocolCompatibilityStatus.UnsupportedBinaryHash,
                snapshot.RequestedPath,
                snapshot.FinalPath,
                snapshot.ReleaseId,
                snapshot.Length,
                snapshot.Sha256,
                message: $"Herdr release '{snapshot.ReleaseId}' has an unrecognized SHA-256 and requires a successor contract review.");
        }

        var missingRpcMethods = MissingMarkers(
            snapshot.FoundAsciiMarkers,
            _policy.RequiredRpcMethods);
        var missingProtocolShapes = MissingMarkers(
            snapshot.FoundAsciiMarkers,
            _policy.RequiredShapes.Select(shape => shape.BinaryMarker));
        var missingTransportMarkers = MissingMarkers(
            snapshot.FoundAsciiMarkers,
            _policy.RequiredTransportMarkers);
        if (missingRpcMethods.Count > 0 ||
            missingProtocolShapes.Count > 0 ||
            missingTransportMarkers.Count > 0)
        {
            return new HerdrProtocolInspection(
                HerdrProtocolCompatibilityStatus.MissingProtocolMarkers,
                EvidenceClass.Contract,
                RuntimeObserved: false,
                _policy.ContractId,
                _policy.Revision,
                snapshot.RequestedPath,
                snapshot.FinalPath,
                snapshot.ReleaseId,
                snapshot.Length,
                snapshot.Sha256,
                ContractSchemaFingerprintSha256: null,
                missingRpcMethods,
                missingProtocolShapes,
                missingTransportMarkers,
                "The executable identity matched, but one or more required protocol markers were missing.");
        }

        return new HerdrProtocolInspection(
            HerdrProtocolCompatibilityStatus.Compatible,
            EvidenceClass.Contract,
            RuntimeObserved: false,
            _policy.ContractId,
            _policy.Revision,
            snapshot.RequestedPath,
            snapshot.FinalPath,
            snapshot.ReleaseId,
            snapshot.Length,
            snapshot.Sha256,
            HerdrProtocolContractFingerprint.Compute(_policy, snapshot.ReleaseId),
            Array.Empty<string>(),
            Array.Empty<string>(),
            Array.Empty<string>(),
            "Installed Herdr binary matches the admitted read-only monitoring contract. Runtime communication was not observed.");
    }

    private HerdrProtocolInspection Failure(
        HerdrProtocolCompatibilityStatus status,
        string requestedPath,
        string? resolvedPath,
        string? releaseId,
        long? executableLength,
        string? executableSha256,
        string message) =>
        new(
            status,
            EvidenceClass.Contract,
            RuntimeObserved: false,
            _policy.ContractId,
            _policy.Revision,
            requestedPath,
            resolvedPath,
            releaseId,
            executableLength,
            executableSha256,
            ContractSchemaFingerprintSha256: null,
            Array.Empty<string>(),
            Array.Empty<string>(),
            Array.Empty<string>(),
            message);

    private static IReadOnlyList<string> MissingMarkers(
        IReadOnlySet<string> foundMarkers,
        IEnumerable<string> requiredMarkers) =>
        requiredMarkers
            .Where(marker => !foundMarkers.Contains(marker))
            .ToArray();
}
