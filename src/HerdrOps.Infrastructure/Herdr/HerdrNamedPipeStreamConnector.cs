using System.ComponentModel;
using System.Diagnostics;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace HerdrOps.Infrastructure.Herdr;

public sealed class HerdrNamedPipeStreamConnector : IHerdrStreamConnector
{
    public async Task<HerdrConnectedStream> ConnectAsync(
        HerdrPipeEndpoint endpoint,
        TimeSpan timeout,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(endpoint);
        if (timeout <= TimeSpan.Zero || timeout.TotalMilliseconds > int.MaxValue)
        {
            throw new ArgumentOutOfRangeException(nameof(timeout));
        }

        var pipe = new NamedPipeClientStream(
            ".",
            endpoint.PipeName,
            PipeDirection.InOut,
            PipeOptions.Asynchronous | PipeOptions.WriteThrough);
        try
        {
            await pipe.ConnectAsync((int)Math.Ceiling(timeout.TotalMilliseconds), cancellationToken)
                .ConfigureAwait(false);
            if (!GetNamedPipeServerProcessId(pipe.SafePipeHandle, out var serverProcessId))
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "Could not resolve the Herdr Named Pipe server process id.");
            }

            try
            {
                using var serverProcess = Process.GetProcessById(checked((int)serverProcessId));
                var executablePath = serverProcess.MainModule?.FileName;
                if (string.IsNullOrWhiteSpace(executablePath))
                {
                    throw new IOException(
                        $"Could not resolve the executable path for Named Pipe server PID {serverProcessId}.");
                }

                return new HerdrConnectedStream(
                    pipe,
                    checked((int)serverProcessId),
                    serverProcess.StartTime.ToUniversalTime(),
                    executablePath);
            }
            catch (Exception exception) when (
                exception is ArgumentException or InvalidOperationException or Win32Exception)
            {
                throw new IOException(
                    $"Could not inspect Named Pipe server PID {serverProcessId}: {exception.Message}",
                    exception);
            }
        }
        catch
        {
            await pipe.DisposeAsync().ConfigureAwait(false);
            throw;
        }
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetNamedPipeServerProcessId(
        SafePipeHandle pipe,
        out uint serverProcessId);
}
