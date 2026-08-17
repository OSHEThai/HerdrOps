using HerdrOps.Domain.Diagnostics;

namespace HerdrOps.Infrastructure.Diagnostics;

/// <summary>
/// Publishes a previously built diagnostic package into a new directory. The publisher
/// creates only the three contract artifacts and never reads or copies arbitrary files.
/// </summary>
public sealed class DiagnosticBundlePublisher
{
    private readonly DiagnosticBundleBuilder _builder;

    public DiagnosticBundlePublisher(DiagnosticBundleBuilder? builder = null)
    {
        _builder = builder ?? new DiagnosticBundleBuilder();
    }

    public DiagnosticBundlePublishResult Publish(
        DiagnosticBundleRequest request,
        DiagnosticBundlePublishOptions options,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);
        ArgumentNullException.ThrowIfNull(options);
        cancellationToken.ThrowIfCancellationRequested();

        var package = _builder.Build(request);
        var outputRoot = ValidateOutputRoot(options.OutputRoot);
        var bundleDirectory = ValidateBundleDirectory(outputRoot, options.BundleDirectoryName);
        var temporaryDirectory = Path.Combine(
            outputRoot,
            $".{options.BundleDirectoryName}.{Guid.NewGuid():N}.tmp");
        EnsureContained(outputRoot, temporaryDirectory);

        if (PathExists(bundleDirectory))
        {
            throw new IOException($"The diagnostic bundle destination already exists: {bundleDirectory}");
        }

        Directory.CreateDirectory(temporaryDirectory);
        try
        {
            EnsureDirectoryIsRegular(temporaryDirectory, "temporary diagnostic bundle directory");
            foreach (var artifact in package.Artifacts)
            {
                cancellationToken.ThrowIfCancellationRequested();
                WriteNewFile(temporaryDirectory, artifact);
            }

            cancellationToken.ThrowIfCancellationRequested();
            EnsureDirectoryIsRegular(outputRoot, "diagnostic output root");
            if (PathExists(bundleDirectory))
            {
                throw new IOException($"The diagnostic bundle destination already exists: {bundleDirectory}");
            }

            Directory.Move(temporaryDirectory, bundleDirectory);
            var artifactPaths = package.Artifacts
                .Select(artifact => Path.Combine(bundleDirectory, artifact.FileName))
                .ToArray();
            return new DiagnosticBundlePublishResult(
                bundleDirectory,
                artifactPaths,
                package.ManifestSha256,
                package.TotalBytes);
        }
        catch (Exception publishException)
        {
            if (!Directory.Exists(temporaryDirectory))
            {
                throw;
            }

            try
            {
                EnsureDirectoryIsRegular(temporaryDirectory, "temporary diagnostic bundle directory");
                Directory.Delete(temporaryDirectory, recursive: true);
            }
            catch (Exception cleanupException)
            {
                throw new AggregateException(
                    "Diagnostic bundle publication failed and its temporary directory could not be removed.",
                    publishException,
                    cleanupException);
            }

            throw;
        }
    }

    private static string ValidateOutputRoot(string outputRoot)
    {
        if (string.IsNullOrWhiteSpace(outputRoot) || !Path.IsPathFullyQualified(outputRoot))
        {
            throw new ArgumentException("The diagnostic output root must be an absolute path.", nameof(outputRoot));
        }

        string fullPath;
        try
        {
            fullPath = Path.TrimEndingDirectorySeparator(Path.GetFullPath(outputRoot));
        }
        catch (Exception exception) when (exception is ArgumentException or NotSupportedException or PathTooLongException)
        {
            throw new ArgumentException("The diagnostic output root is not a valid path.", nameof(outputRoot), exception);
        }

        if (!Directory.Exists(fullPath))
        {
            throw new DirectoryNotFoundException($"The diagnostic output root does not exist: {fullPath}");
        }

        EnsureNoReparseComponents(fullPath);
        EnsureDirectoryIsRegular(fullPath, "diagnostic output root");
        return fullPath;
    }

    private static string ValidateBundleDirectory(string outputRoot, string bundleDirectoryName)
    {
        if (string.IsNullOrWhiteSpace(bundleDirectoryName) ||
            bundleDirectoryName.Length > 64 ||
            bundleDirectoryName is "." or ".." ||
            bundleDirectoryName.EndsWith(".", StringComparison.Ordinal) ||
            bundleDirectoryName.EndsWith(" ", StringComparison.Ordinal) ||
            bundleDirectoryName.Any(char.IsControl) ||
            bundleDirectoryName.Any(character => !char.IsLetterOrDigit(character) && character is not '-' and not '_' and not '.'))
        {
            throw new ArgumentException(
                "The diagnostic bundle directory name must be a single safe path component.",
                nameof(bundleDirectoryName));
        }

        if (OperatingSystem.IsWindows() && IsReservedWindowsName(bundleDirectoryName))
        {
            throw new ArgumentException(
                "The diagnostic bundle directory name is reserved by Windows.",
                nameof(bundleDirectoryName));
        }

        var destination = Path.GetFullPath(Path.Combine(outputRoot, bundleDirectoryName));
        EnsureContained(outputRoot, destination);
        return destination;
    }

    private static bool IsReservedWindowsName(string value)
    {
        var stem = value.TrimEnd('.', ' ');
        var dot = stem.IndexOf('.', StringComparison.Ordinal);
        if (dot >= 0)
        {
            stem = stem[..dot];
        }

        return stem.Equals("CON", StringComparison.OrdinalIgnoreCase) ||
            stem.Equals("PRN", StringComparison.OrdinalIgnoreCase) ||
            stem.Equals("AUX", StringComparison.OrdinalIgnoreCase) ||
            stem.Equals("NUL", StringComparison.OrdinalIgnoreCase) ||
            (stem.Length == 4 &&
                (stem.StartsWith("COM", StringComparison.OrdinalIgnoreCase) ||
                 stem.StartsWith("LPT", StringComparison.OrdinalIgnoreCase)) &&
                stem[3] is >= '1' and <= '9');
    }

    private static void WriteNewFile(string temporaryDirectory, DiagnosticBundleArtifact artifact)
    {
        if (artifact.FileName is not (
            DiagnosticBundleSchema.ManifestFileName or
            DiagnosticBundleSchema.PayloadFileName or
            DiagnosticBundleSchema.CrashMetadataFileName))
        {
            throw new InvalidDataException($"The artifact name '{artifact.FileName}' is not allowlisted.");
        }

        var path = Path.Combine(temporaryDirectory, artifact.FileName);
        EnsureContained(temporaryDirectory, path);
        using var stream = new FileStream(
            path,
            FileMode.CreateNew,
            FileAccess.Write,
            FileShare.None,
            bufferSize: 16 * 1024,
            FileOptions.SequentialScan | FileOptions.WriteThrough);
        stream.Write(artifact.Content, 0, artifact.Content.Length);
        stream.Flush(flushToDisk: true);
    }

    private static void EnsureContained(string root, string candidate)
    {
        var normalizedRoot = Path.TrimEndingDirectorySeparator(Path.GetFullPath(root));
        var normalizedCandidate = Path.GetFullPath(candidate);
        var comparison = OperatingSystem.IsWindows()
            ? StringComparison.OrdinalIgnoreCase
            : StringComparison.Ordinal;
        if (!string.Equals(normalizedRoot, normalizedCandidate, comparison) &&
            !normalizedCandidate.StartsWith(normalizedRoot + Path.DirectorySeparatorChar, comparison) &&
            !normalizedCandidate.StartsWith(normalizedRoot + Path.AltDirectorySeparatorChar, comparison))
        {
            throw new UnauthorizedAccessException(
                $"The diagnostic path escapes its allowed root: {normalizedCandidate}");
        }
    }

    private static void EnsureNoReparseComponents(string path)
    {
        var current = new DirectoryInfo(Path.GetFullPath(path));
        while (current is not null)
        {
            if (current.Exists && current.Attributes.HasFlag(FileAttributes.ReparsePoint))
            {
                throw new UnauthorizedAccessException(
                    $"The diagnostic path contains a reparse-point component: {current.FullName}");
            }

            current = current.Parent;
        }
    }

    private static void EnsureDirectoryIsRegular(string path, string description)
    {
        var info = new DirectoryInfo(path);
        if (!info.Exists || info.Attributes.HasFlag(FileAttributes.ReparsePoint))
        {
            throw new UnauthorizedAccessException($"The {description} is not a regular non-reparse directory.");
        }
    }

    private static bool PathExists(string path)
    {
        try
        {
            _ = File.GetAttributes(path);
            return true;
        }
        catch (Exception exception) when (
            exception is FileNotFoundException or DirectoryNotFoundException or IOException)
        {
            return false;
        }
    }
}
