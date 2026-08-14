using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace HerdrOps.Infrastructure.Herdr;

public sealed record HerdrExecutableSnapshot(
    string FinalPath,
    byte[] Bytes);

public interface IHerdrExecutableSnapshotReader
{
    HerdrExecutableSnapshot Read(string requestedPath, long maximumBytes);
}

/// <summary>
/// Opens the originally requested path and binds the final target name and bytes to one handle.
/// This detects a Windows junction retarget between initial admission and the extraction snapshot.
/// </summary>
public sealed class HerdrExecutableSnapshotReader : IHerdrExecutableSnapshotReader
{
    public HerdrExecutableSnapshot Read(string requestedPath, long maximumBytes)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(requestedPath);
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(maximumBytes);

        var fullRequestedPath = Path.GetFullPath(requestedPath);
        using var stream = new FileStream(
            fullRequestedPath,
            FileMode.Open,
            FileAccess.Read,
            FileShare.Read,
            bufferSize: 81920,
            FileOptions.SequentialScan);
        var length = stream.Length;
        if (length is < 2 || length > maximumBytes || length > int.MaxValue)
        {
            throw new IOException(
                $"Herdr executable length {length} is outside the accepted snapshot bounds.");
        }

        var finalPath = GetFinalDosPath(stream.SafeFileHandle);
        var bytes = new byte[(int)length];
        stream.ReadExactly(bytes);
        if (stream.Length != length)
        {
            throw new IOException("Herdr executable length changed while the snapshot handle was open.");
        }

        return new HerdrExecutableSnapshot(finalPath, bytes);
    }

    private static string GetFinalDosPath(SafeFileHandle fileHandle)
    {
        var capacity = 512;
        while (true)
        {
            var buffer = new StringBuilder(capacity);
            var result = GetFinalPathNameByHandle(
                fileHandle,
                buffer,
                (uint)buffer.Capacity,
                flags: 0);
            if (result == 0)
            {
                throw new IOException(
                    "The final Herdr executable path could not be resolved from its open handle.",
                    new Win32Exception(Marshal.GetLastWin32Error()));
            }

            if (result < buffer.Capacity)
            {
                return Path.GetFullPath(RemoveExtendedPathPrefix(buffer.ToString()));
            }

            capacity = checked((int)result + 1);
        }
    }

    private static string RemoveExtendedPathPrefix(string path)
    {
        const string uncPrefix = @"\\?\UNC\";
        const string localPrefix = @"\\?\";
        if (path.StartsWith(uncPrefix, StringComparison.OrdinalIgnoreCase))
        {
            return @"\\" + path[uncPrefix.Length..];
        }

        return path.StartsWith(localPrefix, StringComparison.OrdinalIgnoreCase)
            ? path[localPrefix.Length..]
            : path;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetFinalPathNameByHandle(
        SafeFileHandle fileHandle,
        StringBuilder filePath,
        uint filePathLength,
        uint flags);
}
