using System.Security.Cryptography;
using System.Text;
using HerdrOps.Contracts;

namespace HerdrOps.Infrastructure.Herdr;

public sealed class HerdrProtocolInspector
{
    private const long MaximumExecutableBytes = 128L * 1024 * 1024;
    private readonly HerdrProtocolSupportPolicy _policy;

    public HerdrProtocolInspector(HerdrProtocolSupportPolicy? policy = null)
    {
        _policy = policy ?? HerdrProtocolContractV080Preview.Policy;
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

        string resolvedPath;
        try
        {
            resolvedPath = ResolveExecutablePath(requestedPath);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            return Failure(
                HerdrProtocolCompatibilityStatus.ExecutableUnreadable,
                requestedPath,
                resolvedPath: null,
                releaseId: null,
                executableLength: null,
                executableSha256: null,
                message: $"Herdr executable path could not be resolved: {exception.Message}");
        }

        FileInfo file;
        try
        {
            file = new FileInfo(resolvedPath);
            if (file.Length is < 2 or > MaximumExecutableBytes)
            {
                return Failure(
                    HerdrProtocolCompatibilityStatus.ExecutableUnreadable,
                    requestedPath,
                    resolvedPath,
                    file.Directory?.Name,
                    file.Length,
                    executableSha256: null,
                    message: $"Herdr executable length {file.Length} is outside the accepted inspection bounds.");
            }
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            return Failure(
                HerdrProtocolCompatibilityStatus.ExecutableUnreadable,
                requestedPath,
                resolvedPath,
                releaseId: null,
                executableLength: null,
                executableSha256: null,
                message: $"Herdr executable metadata could not be read: {exception.Message}");
        }

        byte[] executableBytes;
        string executableSha256;
        try
        {
            executableBytes = File.ReadAllBytes(resolvedPath);
            executableSha256 = Convert.ToHexString(SHA256.HashData(executableBytes));
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            return Failure(
                HerdrProtocolCompatibilityStatus.ExecutableUnreadable,
                requestedPath,
                resolvedPath,
                file.Directory?.Name,
                file.Length,
                executableSha256: null,
                message: $"Herdr executable bytes could not be read: {exception.Message}");
        }

        var releaseId = file.Directory?.Name ?? string.Empty;
        if (executableBytes[0] != (byte)'M' || executableBytes[1] != (byte)'Z')
        {
            return Failure(
                HerdrProtocolCompatibilityStatus.InvalidPortableExecutable,
                requestedPath,
                resolvedPath,
                releaseId,
                file.Length,
                executableSha256,
                message: "Herdr executable does not begin with a Windows PE MZ header.");
        }

        var compatibleRelease = _policy.CompatibleBinaries
            .Where(identity => string.Equals(identity.ReleaseId, releaseId, StringComparison.Ordinal))
            .ToArray();
        if (compatibleRelease.Length == 0)
        {
            return Failure(
                HerdrProtocolCompatibilityStatus.UnsupportedRelease,
                requestedPath,
                resolvedPath,
                releaseId,
                file.Length,
                executableSha256,
                message: $"Herdr release '{releaseId}' is not admitted by contract '{_policy.ContractId}'.");
        }

        if (!compatibleRelease.Any(
                identity => string.Equals(identity.Sha256, executableSha256, StringComparison.OrdinalIgnoreCase)))
        {
            return Failure(
                HerdrProtocolCompatibilityStatus.UnsupportedBinaryHash,
                requestedPath,
                resolvedPath,
                releaseId,
                file.Length,
                executableSha256,
                message: $"Herdr release '{releaseId}' has an unrecognized SHA-256 and requires a successor contract review.");
        }

        var missingRpcMethods = MissingMarkers(executableBytes, _policy.RequiredRpcMethods);
        var missingProtocolShapes = MissingMarkers(
            executableBytes,
            _policy.RequiredShapes.Select(shape => shape.BinaryMarker));
        var missingTransportMarkers = MissingMarkers(executableBytes, _policy.RequiredTransportMarkers);

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
                requestedPath,
                resolvedPath,
                releaseId,
                file.Length,
                executableSha256,
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
            requestedPath,
            resolvedPath,
            releaseId,
            file.Length,
            executableSha256,
            HerdrProtocolContractFingerprint.Compute(_policy, releaseId),
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
        byte[] executableBytes,
        IEnumerable<string> requiredMarkers) =>
        requiredMarkers
            .Where(marker => executableBytes.AsSpan().IndexOf(Encoding.ASCII.GetBytes(marker)) < 0)
            .ToArray();

    private static string ResolveExecutablePath(string requestedPath)
    {
        var file = new FileInfo(requestedPath);
        var containingDirectory = file.Directory;
        if (containingDirectory is null ||
            (containingDirectory.Attributes & FileAttributes.ReparsePoint) == 0)
        {
            return file.FullName;
        }

        var targetDirectory = containingDirectory.ResolveLinkTarget(returnFinalTarget: true);
        return targetDirectory is null
            ? file.FullName
            : Path.Combine(targetDirectory.FullName, file.Name);
    }
}
