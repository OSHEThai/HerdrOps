using System.Text;

namespace HerdrOps.Infrastructure.Storage.Recovery;

internal static class StateStoreRecoveryPathPolicy
{
    private static readonly byte[] SqliteHeader =
        Encoding.ASCII.GetBytes("SQLite format 3\0");

    public static string NormalizeDatabasePath(string path)
    {
        if (string.IsNullOrWhiteSpace(path) || !Path.IsPathFullyQualified(path))
        {
            throw new ArgumentException(
                "The SQLite database path must be an absolute local path.",
                nameof(path));
        }

        RejectPathSyntax(path, nameof(path));
        string fullPath;
        try
        {
            fullPath = Path.GetFullPath(path);
        }
        catch (Exception exception) when (exception is ArgumentException or NotSupportedException)
        {
            throw new ArgumentException(
                "The SQLite database path is not a valid local path.",
                nameof(path),
                exception);
        }

        if (IsUncOrExtendedPath(fullPath))
        {
            throw new ArgumentException(
                "The SQLite database path must remain on the local Windows volume.",
                nameof(path));
        }

        var parent = Path.GetDirectoryName(fullPath);
        var fileName = Path.GetFileName(fullPath);
        if (string.IsNullOrWhiteSpace(parent) || string.IsNullOrWhiteSpace(fileName))
        {
            throw new ArgumentException(
                "The SQLite database path must name a file below a local directory.",
                nameof(path));
        }

        ValidateFileName(fileName, nameof(path));
        return fullPath;
    }

    public static void EnsureDatabaseParent(string databasePath)
    {
        var parent = Path.GetDirectoryName(databasePath)
            ?? throw new ArgumentException("The database parent directory is missing.", nameof(databasePath));
        EnsureDirectoryTree(parent);
    }

    public static void EnsureDirectoryTree(string directoryPath)
    {
        var fullPath = Path.GetFullPath(directoryPath);
        RejectPathSyntax(fullPath, nameof(directoryPath));
        if (IsUncOrExtendedPath(fullPath))
        {
            throw new HerdrStateStoreException(
                $"Recovery path '{fullPath}' must remain on the local Windows volume.");
        }

        var pending = new Stack<string>();
        var cursor = fullPath;
        while (!Directory.Exists(cursor))
        {
            EnsureNoReparseComponents(cursor, includeLeaf: true);
            if (File.Exists(cursor))
            {
                throw new HerdrStateStoreException(
                    $"Recovery directory '{cursor}' is occupied by a file.");
            }

            pending.Push(cursor);
            var parent = Path.GetDirectoryName(cursor);
            if (string.IsNullOrWhiteSpace(parent) ||
                string.Equals(parent, cursor, StringComparison.OrdinalIgnoreCase))
            {
                throw new HerdrStateStoreException(
                    $"Recovery directory '{fullPath}' has no safe existing parent.");
            }

            cursor = parent;
        }

        EnsureDirectoryEntryIsSafe(cursor);
        while (pending.Count > 0)
        {
            var next = pending.Pop();
            Directory.CreateDirectory(next);
            EnsureDirectoryEntryIsSafe(next);
        }
    }

    public static void EnsureContainedPath(
        string allowedRoot,
        string candidate,
        bool allowRoot = false)
    {
        var root = Path.GetFullPath(allowedRoot)
            .TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        var fullCandidate = Path.GetFullPath(candidate);
        EnsureNoReparseComponents(root, includeLeaf: true);
        RejectPathSyntax(fullCandidate, nameof(candidate));
        if (IsUncOrExtendedPath(fullCandidate))
        {
            throw new HerdrStateStoreException(
                $"Recovery path '{fullCandidate}' must remain on the local Windows volume.");
        }

        var equal = string.Equals(root, fullCandidate, StringComparison.OrdinalIgnoreCase);
        var descendant = fullCandidate.StartsWith(
            root + Path.DirectorySeparatorChar,
            StringComparison.OrdinalIgnoreCase);
        if ((!allowRoot && equal) || (!equal && !descendant))
        {
            throw new HerdrStateStoreException(
                $"Recovery path '{fullCandidate}' escapes allowed root '{root}'.");
        }

        EnsureNoReparseComponents(fullCandidate, includeLeaf: true);
    }

    public static void ValidateExistingPrimary(string databasePath)
    {
        EnsureNoReparseComponents(databasePath, includeLeaf: true);
        if (Directory.Exists(databasePath))
        {
            throw new StateStoreCorruptionException(
                $"The state-store path '{databasePath}' is a directory, not a SQLite database.");
        }

        if (!File.Exists(databasePath))
        {
            return;
        }

        ValidateExistingCopySource(databasePath);
        var length = new FileInfo(databasePath).Length;
        if (length < SqliteHeader.Length)
        {
            throw new StateStoreCorruptionException(
                $"The existing state-store file '{databasePath}' is truncated.");
        }

        var header = new byte[SqliteHeader.Length];
        using var stream = new FileStream(
            databasePath,
            FileMode.Open,
            FileAccess.Read,
            FileShare.ReadWrite | FileShare.Delete,
            bufferSize: SqliteHeader.Length,
            FileOptions.SequentialScan);
        var read = stream.Read(header, 0, header.Length);
        if (read != header.Length || !header.AsSpan().SequenceEqual(SqliteHeader))
        {
            throw new StateStoreCorruptionException(
                $"The existing state-store file '{databasePath}' is not a SQLite database.");
        }
    }

    public static void ValidateExistingCopySource(string path)
    {
        EnsureNoReparseComponents(path, includeLeaf: true);
        if (!File.Exists(path) || Directory.Exists(path))
        {
            throw new StateStoreCorruptionException(
                $"Recovery source '{path}' is not an existing regular file.");
        }
    }

    public static void ValidateFileName(string fileName, string parameterName)
    {
        if (string.IsNullOrWhiteSpace(fileName) ||
            fileName is "." or ".." ||
            fileName[^1] is '.' or ' ' ||
            fileName.IndexOf(':') >= 0 ||
            fileName.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0)
        {
            throw new ArgumentException(
                $"The recovery file name '{fileName}' is not safe.",
                parameterName);
        }

        var stem = fileName.Split('.')[0].TrimEnd(' ', '.');
        if (IsReservedDeviceName(stem))
        {
            throw new ArgumentException(
                $"The recovery file name '{fileName}' is a reserved Windows device name.",
                parameterName);
        }
    }

    public static void EnsureNoReparseComponents(string path, bool includeLeaf)
    {
        var fullPath = Path.GetFullPath(path);
        var cursor = Path.GetDirectoryName(fullPath);
        while (!string.IsNullOrWhiteSpace(cursor) && Directory.Exists(cursor))
        {
            EnsureDirectoryEntryIsSafe(cursor);
            var parent = Path.GetDirectoryName(cursor);
            if (string.Equals(parent, cursor, StringComparison.OrdinalIgnoreCase))
            {
                break;
            }

            cursor = parent;
        }

        if (includeLeaf)
        {
            if (HasLinkTarget(fullPath))
            {
                throw new HerdrStateStoreException(
                    $"Recovery file '{fullPath}' is a reparse point.");
            }

            FileAttributes attributes;
            try
            {
                attributes = File.GetAttributes(fullPath);
            }
            catch (FileNotFoundException)
            {
                return;
            }
            catch (DirectoryNotFoundException)
            {
                return;
            }

            if ((attributes & FileAttributes.ReparsePoint) != 0)
            {
                throw new HerdrStateStoreException(
                    $"Recovery file '{fullPath}' is a reparse point.");
            }
        }
    }

    private static bool HasLinkTarget(string path)
    {
        try
        {
            if (new FileInfo(path).LinkTarget is not null)
            {
                return true;
            }
        }
        catch (FileNotFoundException)
        {
        }
        catch (DirectoryNotFoundException)
        {
        }

        try
        {
            return new DirectoryInfo(path).LinkTarget is not null;
        }
        catch (FileNotFoundException)
        {
            return false;
        }
        catch (DirectoryNotFoundException)
        {
            return false;
        }
    }

    private static void EnsureDirectoryEntryIsSafe(string path)
    {
        var attributes = File.GetAttributes(path);
        if ((attributes & FileAttributes.ReparsePoint) != 0)
        {
            throw new HerdrStateStoreException(
                $"Recovery directory '{path}' is a reparse point.");
        }
    }

    private static void RejectPathSyntax(string path, string parameterName)
    {
        if (path.IndexOf('\0') >= 0)
        {
            throw new ArgumentException("Recovery paths cannot contain NUL characters.", parameterName);
        }

        var normalized = path.Replace(
            Path.AltDirectorySeparatorChar,
            Path.DirectorySeparatorChar);
        foreach (var segment in normalized.Split(
                     Path.DirectorySeparatorChar,
                     StringSplitOptions.RemoveEmptyEntries))
        {
            if (segment is "." or "..")
            {
                throw new ArgumentException(
                    "Recovery paths cannot contain traversal segments.",
                    parameterName);
            }
        }
    }

    private static bool IsUncOrExtendedPath(string path) =>
        path.StartsWith("\\\\", StringComparison.Ordinal) ||
        path.StartsWith("//", StringComparison.Ordinal);

    private static bool IsReservedDeviceName(string value) =>
        value.Equals("CON", StringComparison.OrdinalIgnoreCase) ||
        value.Equals("PRN", StringComparison.OrdinalIgnoreCase) ||
        value.Equals("AUX", StringComparison.OrdinalIgnoreCase) ||
        value.Equals("NUL", StringComparison.OrdinalIgnoreCase) ||
        (value.Length == 4 &&
         (value.StartsWith("COM", StringComparison.OrdinalIgnoreCase) ||
          value.StartsWith("LPT", StringComparison.OrdinalIgnoreCase)) &&
         value[3] is >= '1' and <= '9');
}
