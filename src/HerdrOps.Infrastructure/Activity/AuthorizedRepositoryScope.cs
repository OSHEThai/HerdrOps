using System.Security.Cryptography;
using System.Text;

namespace HerdrOps.Infrastructure.Activity;

public sealed record RepositoryPathDecision(
    bool IsAuthorized,
    string? CanonicalPath,
    string? RelativePath,
    string Reason);

/// <summary>
/// Authorizes paths against one existing repository root. The check is separator-aware,
/// case-insensitive on Windows, and resolves every existing reparse-point component so a
/// junction or symbolic link cannot silently escape the authorized root.
/// </summary>
public sealed class AuthorizedRepositoryScope
{
    private static readonly StringComparison PathComparison = OperatingSystem.IsWindows()
        ? StringComparison.OrdinalIgnoreCase
        : StringComparison.Ordinal;

    public AuthorizedRepositoryScope(string repositoryRoot)
    {
        if (string.IsNullOrWhiteSpace(repositoryRoot) ||
            !Path.IsPathFullyQualified(repositoryRoot))
        {
            throw new ArgumentException(
                "An authorized repository root must be an absolute path.",
                nameof(repositoryRoot));
        }

        DeclaredRoot = TrimRoot(Path.GetFullPath(repositoryRoot));
        if (!Directory.Exists(DeclaredRoot))
        {
            throw new DirectoryNotFoundException(
                $"The authorized repository root does not exist: {DeclaredRoot}");
        }

        CanonicalRoot = ResolveFinalTarget(new DirectoryInfo(DeclaredRoot));
        RootIdentity = Convert.ToHexString(
            SHA256.HashData(Encoding.UTF8.GetBytes(CanonicalRoot)))[..16];
    }

    public string DeclaredRoot { get; }

    public string CanonicalRoot { get; }

    public string RootIdentity { get; }

    public RepositoryPathDecision Evaluate(string candidatePath)
    {
        if (string.IsNullOrWhiteSpace(candidatePath) ||
            !Path.IsPathFullyQualified(candidatePath))
        {
            return Block("path-not-absolute");
        }

        string fullPath;
        try
        {
            fullPath = Path.GetFullPath(candidatePath);
        }
        catch (Exception exception) when (
            exception is ArgumentException or NotSupportedException or PathTooLongException)
        {
            return Block("path-invalid");
        }

        if (!IsWithin(DeclaredRoot, fullPath))
        {
            return Block("outside-declared-root");
        }

        var relativePath = Path.GetRelativePath(DeclaredRoot, fullPath);
        if (relativePath == ".")
        {
            return Block("repository-root-is-not-a-file");
        }

        try
        {
            var canonicalPath = ResolvePhysicalPath(relativePath);
            if (!IsWithin(CanonicalRoot, canonicalPath))
            {
                return Block("reparse-target-outside-root");
            }

            return new RepositoryPathDecision(
                true,
                canonicalPath,
                relativePath.Replace('\\', '/'),
                "authorized");
        }
        catch (UnauthorizedAccessException)
        {
            return Block("path-access-denied");
        }
        catch (IOException)
        {
            return Block("path-resolution-failed");
        }
    }

    private string ResolvePhysicalPath(string relativePath)
    {
        var segments = relativePath.Split(
            [Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar],
            StringSplitOptions.RemoveEmptyEntries);
        var current = CanonicalRoot;
        for (var index = 0; index < segments.Length; index++)
        {
            current = Path.Combine(current, segments[index]);
            var info = TryGetExistingInfo(current);
            if (info is null)
            {
                for (var remaining = index + 1; remaining < segments.Length; remaining++)
                {
                    current = Path.Combine(current, segments[remaining]);
                }

                return Path.GetFullPath(current);
            }

            if ((info.Attributes & FileAttributes.ReparsePoint) != 0)
            {
                current = ResolveFinalTarget(info);
                if (!IsWithin(CanonicalRoot, current))
                {
                    return current;
                }
            }

            if (index < segments.Length - 1 &&
                info is FileInfo &&
                (info.Attributes & FileAttributes.Directory) == 0)
            {
                throw new IOException("A file appeared before the end of the candidate path.");
            }
        }

        return Path.GetFullPath(current);
    }

    private static FileSystemInfo? TryGetExistingInfo(string path)
    {
        if (Directory.Exists(path))
        {
            return new DirectoryInfo(path);
        }

        if (File.Exists(path))
        {
            return new FileInfo(path);
        }

        return null;
    }

    private static string ResolveFinalTarget(FileSystemInfo info)
    {
        if ((info.Attributes & FileAttributes.ReparsePoint) == 0)
        {
            return TrimRoot(Path.GetFullPath(info.FullName));
        }

        var target = info.ResolveLinkTarget(returnFinalTarget: true)
            ?? throw new IOException("The reparse-point target could not be resolved.");
        return TrimRoot(Path.GetFullPath(target.FullName));
    }

    private static bool IsWithin(string root, string candidate)
    {
        if (string.Equals(root, candidate, PathComparison))
        {
            return true;
        }

        var rootWithSeparator = root.EndsWith(Path.DirectorySeparatorChar)
            ? root
            : root + Path.DirectorySeparatorChar;
        return candidate.StartsWith(rootWithSeparator, PathComparison);
    }

    private static string TrimRoot(string path) =>
        Path.TrimEndingDirectorySeparator(Path.GetFullPath(path));

    private static RepositoryPathDecision Block(string reason) =>
        new(false, null, null, reason);
}
