using System.ComponentModel;
using System.Diagnostics;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using Microsoft.Win32.SafeHandles;

namespace HerdrOps.Contracts.ReviewIpc;

public sealed record HerdrOpsReviewServerProcessIdentity(
    uint ProcessId,
    DateTimeOffset StartedUtc,
    string ExecutablePath,
    string ExecutableSha256);

public static class HerdrOpsReviewServerProcessIdentityReader
{
    private const string ExpectedExecutableName = "HerdrOps.Core.exe";
    private const string ExpectedOriginalFilename = "HerdrOps.Core.dll";
    private const string ExpectedProductName = "HerdrOps.Core";

    public static HerdrOpsReviewServerProcessIdentity ReadAndValidate(
        NamedPipeClientStream pipe)
    {
        ArgumentNullException.ThrowIfNull(pipe);
        if (!OperatingSystem.IsWindows() || !pipe.IsConnected)
        {
            throw new HerdrOpsReviewCommandProtocolException(
                "Review-command server process identity requires a connected Windows named pipe.");
        }

        var processId = ReadServerProcessId(pipe.SafePipeHandle);
        try
        {
            using var process = Process.GetProcessById(checked((int)processId));
            var startedUtcBefore = new DateTimeOffset(process.StartTime.ToUniversalTime(), TimeSpan.Zero);
            var executablePath = Path.GetFullPath(
                process.MainModule?.FileName ?? throw new InvalidOperationException(
                    "The review-command server executable path is unavailable."));
            var version = FileVersionInfo.GetVersionInfo(executablePath);
            if (!string.Equals(
                    Path.GetFileName(executablePath),
                    ExpectedExecutableName,
                    StringComparison.OrdinalIgnoreCase) ||
                !string.Equals(
                    version.OriginalFilename,
                    ExpectedOriginalFilename,
                    StringComparison.OrdinalIgnoreCase) ||
                !string.Equals(
                    version.ProductName,
                    ExpectedProductName,
                    StringComparison.Ordinal))
            {
                throw new HerdrOpsReviewCommandProtocolException(
                    "The connected review-command server is not a HerdrOps Core executable.");
            }

            var before = new FileInfo(executablePath);
            var lengthBefore = before.Length;
            var lastWriteUtcBefore = before.LastWriteTimeUtc;
            var executableSha256 = ComputeFileSha256(executablePath);
            before.Refresh();
            var startedUtcAfter = new DateTimeOffset(process.StartTime.ToUniversalTime(), TimeSpan.Zero);
            if (process.HasExited ||
                startedUtcAfter != startedUtcBefore ||
                lengthBefore <= 0 ||
                before.Length != lengthBefore ||
                before.LastWriteTimeUtc != lastWriteUtcBefore ||
                before.LastWriteTimeUtc > startedUtcBefore.UtcDateTime)
            {
                throw new HerdrOpsReviewCommandProtocolException(
                    "The review-command server process identity changed or its executable is newer than the running process.");
            }

            return new HerdrOpsReviewServerProcessIdentity(
                processId,
                startedUtcBefore,
                executablePath,
                executableSha256);
        }
        catch (HerdrOpsReviewCommandProtocolException)
        {
            throw;
        }
        catch (Exception exception) when (
            exception is ArgumentException or InvalidOperationException or IOException or Win32Exception)
        {
            throw new HerdrOpsReviewCommandProtocolException(
                "The review-command server process identity could not be verified.",
                exception);
        }
    }

    private static uint ReadServerProcessId(SafePipeHandle pipeHandle)
    {
        if (!GetNamedPipeServerProcessId(pipeHandle, out var processId) || processId == 0)
        {
            throw new HerdrOpsReviewCommandProtocolException(
                $"The review-command server process ID is unavailable (Win32 {Marshal.GetLastWin32Error()}).");
        }

        return processId;
    }

    private static string ComputeFileSha256(string path)
    {
        using var stream = new FileStream(
            path,
            FileMode.Open,
            FileAccess.Read,
            FileShare.Read | FileShare.Delete);
        return Convert.ToHexString(SHA256.HashData(stream));
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetNamedPipeServerProcessId(
        SafePipeHandle pipe,
        out uint serverProcessId);
}
