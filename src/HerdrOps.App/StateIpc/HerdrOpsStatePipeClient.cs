using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Runtime.CompilerServices;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text.Json;
using HerdrOps.Contracts.StateIpc;
using Microsoft.Win32.SafeHandles;

namespace HerdrOps.App.StateIpc;

public sealed record HerdrOpsStatePipeClientOptions(
    string PipeName,
    int ConnectTimeoutMilliseconds = 5000,
    int MaximumFrameBytes = HerdrOpsStateIpcProtocol.MaximumFrameBytes,
    string? AcceptanceNonce = null,
    string? AcceptanceEvidencePath = null)
{
    public static HerdrOpsStatePipeClientOptions ForCurrentUser()
    {
        var userSid = WindowsIdentity.GetCurrent().User?.Value;
        if (string.IsNullOrWhiteSpace(userSid))
        {
            throw new HerdrOpsStateIpcProtocolException(
                "The current Windows user SID is unavailable for state IPC.");
        }

        return new HerdrOpsStatePipeClientOptions(
            HerdrOpsStatePipeName.FromUserScope(userSid),
            AcceptanceNonce: Environment.GetEnvironmentVariable(
                HerdrOpsStateIpcProtocol.Issue44AcceptanceNonceEnvironmentVariable),
            AcceptanceEvidencePath: Environment.GetEnvironmentVariable(
                HerdrOpsStateIpcProtocol.Issue44AcceptanceEvidencePathEnvironmentVariable));
    }
}

public enum HerdrOpsStateUpdateKind
{
    Snapshot,
    Delta,
    RuntimeHealth,
}

public sealed record HerdrOpsStateUpdate(
    HerdrOpsStateUpdateKind Kind,
    HerdrSessionStateContract CurrentState,
    HerdrOpsStateIpcEnvelope Envelope,
    HerdrOpsStateSnapshotPayload? Snapshot,
    HerdrOpsStateDeltaPayload? Delta,
    HerdrRuntimeHealthContract RuntimeHealth);

public interface IHerdrOpsStateUpdateSource
{
    IAsyncEnumerable<HerdrOpsStateUpdate> ReadUpdatesAsync(
        CancellationToken cancellationToken = default);
}

public sealed class HerdrOpsStatePipeClient : IHerdrOpsStateUpdateSource
{
    public const PipeOptions RequiredPipeOptions =
        PipeOptions.Asynchronous |
        PipeOptions.CurrentUserOnly;

    private readonly HerdrOpsStatePipeClientOptions _options;
    private readonly TimeProvider _timeProvider;
    private readonly string _clientInstanceId = Guid.NewGuid().ToString("N");

    public HerdrOpsStatePipeClient(
        HerdrOpsStatePipeClientOptions options,
        TimeProvider? timeProvider = null)
    {
        _options = ValidateOptions(options);
        _timeProvider = timeProvider ?? TimeProvider.System;
    }

    public async IAsyncEnumerable<HerdrOpsStateUpdate> ReadUpdatesAsync(
        [EnumeratorCancellation] CancellationToken cancellationToken = default)
    {
        await using var pipe = CreateClientStream();
        await pipe
            .ConnectAsync(_options.ConnectTimeoutMilliseconds, cancellationToken)
            .ConfigureAwait(false);
        var acceptanceServerIdentity = _options.AcceptanceNonce is null
            ? null
            : AcceptanceServerProcessIdentity.Read(pipe);

        var correlationId = Guid.NewGuid();
        var hello = HerdrOpsStateIpcJson.CreateEnvelope(
            HerdrOpsStateIpcProtocol.MessageTypes.Hello,
            sequence: 0,
            _timeProvider.GetUtcNow(),
            HerdrOpsStateIpcProtocol.AppSource,
            correlationId,
            new HerdrOpsStateIpcHello(
                HerdrOpsStateIpcProtocol.AppClientRole,
                _clientInstanceId,
                _options.AcceptanceNonce));
        await HerdrOpsStateIpcJson
            .WriteFrameAsync(pipe, hello, cancellationToken, _options.MaximumFrameBytes)
            .ConfigureAwait(false);

        var acceptedEnvelope = await HerdrOpsStateIpcJson
            .ReadFrameAsync(pipe, cancellationToken, _options.MaximumFrameBytes)
            .ConfigureAwait(false);
        ThrowIfError(acceptedEnvelope);
        ValidateServerEnvelope(
            acceptedEnvelope,
            HerdrOpsStateIpcProtocol.MessageTypes.HelloAccepted,
            correlationId);
        var accepted = HerdrOpsStateIpcJson.DeserializePayload<HerdrOpsStateIpcHelloAccepted>(
            acceptedEnvelope);
        if (string.IsNullOrWhiteSpace(accepted.ServerInstanceId) ||
            !string.Equals(
                accepted.AuthorizationScope,
                HerdrOpsStateIpcProtocol.AuthorizationScope,
                StringComparison.Ordinal))
        {
            throw new HerdrOpsStateIpcProtocolException(
                "The state IPC server did not confirm the current-user authorization scope.");
        }

        ValidateAcceptanceBinding(accepted, acceptanceServerIdentity);

        var snapshotEnvelope = await HerdrOpsStateIpcJson
            .ReadFrameAsync(pipe, cancellationToken, _options.MaximumFrameBytes)
            .ConfigureAwait(false);
        ThrowIfError(snapshotEnvelope);
        ValidateServerEnvelope(
            snapshotEnvelope,
            HerdrOpsStateIpcProtocol.MessageTypes.Snapshot,
            correlationId);
        var snapshot = HerdrOpsStateIpcJson.DeserializePayload<HerdrOpsStateSnapshotPayload>(
            snapshotEnvelope);
        HerdrSessionStateContractReducer.ValidateSnapshotPayload(snapshot);
        var current = HerdrSessionStateContractReducer.NormalizeAndValidate(snapshot.State);
        if (snapshotEnvelope.Sequence != current.LastIngestSequence ||
            acceptedEnvelope.Sequence != current.LastIngestSequence)
        {
            throw new HerdrOpsStateIpcProtocolException(
                "The state IPC handshake and snapshot sequences disagree.");
        }

        WriteAcceptanceEvidence(accepted, correlationId, snapshotEnvelope.Sequence);

        yield return new HerdrOpsStateUpdate(
            HerdrOpsStateUpdateKind.Snapshot,
            current,
            snapshotEnvelope,
            snapshot,
            null,
            snapshot.RuntimeHealth);

        while (true)
        {
            var envelope = await HerdrOpsStateIpcJson
                .ReadFrameAsync(pipe, cancellationToken, _options.MaximumFrameBytes)
                .ConfigureAwait(false);
            ThrowIfError(envelope);
            if (string.Equals(
                    envelope.MessageType,
                    HerdrOpsStateIpcProtocol.MessageTypes.RuntimeHealth,
                    StringComparison.Ordinal))
            {
                ValidateServerEnvelope(
                    envelope,
                    HerdrOpsStateIpcProtocol.MessageTypes.RuntimeHealth,
                    expectedCorrelationId: null);
                if (envelope.Sequence != current.LastIngestSequence)
                {
                    throw new HerdrOpsStateIpcProtocolException(
                        "The runtime-health envelope sequence does not match the current state.");
                }

                var health = HerdrOpsStateIpcJson
                    .DeserializePayload<HerdrOpsRuntimeHealthPayload>(envelope);
                HerdrSessionStateContractReducer.ValidateRuntimeHealthPayload(health, current);
                yield return new HerdrOpsStateUpdate(
                    HerdrOpsStateUpdateKind.RuntimeHealth,
                    current,
                    envelope,
                    null,
                    null,
                    health.RuntimeHealth);
                continue;
            }

            ValidateServerEnvelope(
                envelope,
                HerdrOpsStateIpcProtocol.MessageTypes.Delta,
                expectedCorrelationId: null);
            var delta = HerdrOpsStateIpcJson.DeserializePayload<HerdrOpsStateDeltaPayload>(envelope);
            if (envelope.Sequence != delta.Delta.ToSequence)
            {
                throw new HerdrOpsStateIpcProtocolException(
                    "The state IPC delta envelope and payload sequences disagree.");
            }

            current = HerdrSessionStateContractReducer.ApplyAndValidateDeltaPayload(current, delta);
            yield return new HerdrOpsStateUpdate(
                HerdrOpsStateUpdateKind.Delta,
                current,
                envelope,
                null,
                delta,
                delta.RuntimeHealth);
        }
    }

    internal NamedPipeClientStream CreateClientStream() => new(
        ".",
        _options.PipeName,
        PipeDirection.InOut,
        RequiredPipeOptions);

    private static void ValidateServerEnvelope(
        HerdrOpsStateIpcEnvelope envelope,
        string expectedMessageType,
        Guid? expectedCorrelationId)
    {
        if (envelope.ProtocolVersion != HerdrOpsStateIpcProtocol.Version ||
            !string.Equals(envelope.Source, HerdrOpsStateIpcProtocol.CoreSource, StringComparison.Ordinal) ||
            !string.Equals(envelope.MessageType, expectedMessageType, StringComparison.Ordinal) ||
            (expectedCorrelationId is not null && envelope.CorrelationId != expectedCorrelationId))
        {
            throw new HerdrOpsStateIpcProtocolException(
                $"The state IPC server returned an invalid '{expectedMessageType}' envelope.");
        }
    }

    private static void ThrowIfError(HerdrOpsStateIpcEnvelope envelope)
    {
        if (!string.Equals(
                envelope.MessageType,
                HerdrOpsStateIpcProtocol.MessageTypes.Error,
                StringComparison.Ordinal))
        {
            return;
        }

        var error = HerdrOpsStateIpcJson.DeserializePayload<HerdrOpsStateIpcError>(envelope);
        throw new HerdrOpsStateIpcProtocolException(
            $"State IPC server rejected the client ({error.Code}): {error.Message}");
    }

    private static HerdrOpsStatePipeClientOptions ValidateOptions(
        HerdrOpsStatePipeClientOptions options)
    {
        ArgumentNullException.ThrowIfNull(options);
        if (string.IsNullOrWhiteSpace(options.PipeName) ||
            options.PipeName.Length > 128 ||
            options.PipeName.Contains('\\', StringComparison.Ordinal) ||
            options.PipeName.Contains('/', StringComparison.Ordinal))
        {
            throw new ArgumentException(
                "The state IPC pipe name must contain 1 to 128 non-path characters.",
                nameof(options));
        }

        if (options.ConnectTimeoutMilliseconds is < 100 or > 60_000)
        {
            throw new ArgumentOutOfRangeException(
                nameof(options),
                "The state IPC connection timeout must be between 100 and 60000 milliseconds.");
        }

        if (options.MaximumFrameBytes is < 1024 or > HerdrOpsStateIpcProtocol.MaximumFrameBytes)
        {
            throw new ArgumentOutOfRangeException(
                nameof(options),
                $"The maximum state IPC frame must be between 1024 and {HerdrOpsStateIpcProtocol.MaximumFrameBytes} bytes.");
        }

        var nonce = NormalizeAcceptanceNonce(options.AcceptanceNonce);
        var evidencePath = string.IsNullOrWhiteSpace(options.AcceptanceEvidencePath)
            ? null
            : Path.GetFullPath(options.AcceptanceEvidencePath);
        if ((nonce is null) != (evidencePath is null))
        {
            throw new ArgumentException(
                "Issue #44 acceptance nonce and evidence path must be supplied together.",
                nameof(options));
        }

        return options with
        {
            AcceptanceNonce = nonce,
            AcceptanceEvidencePath = evidencePath,
        };
    }

    private void ValidateAcceptanceBinding(
        HerdrOpsStateIpcHelloAccepted accepted,
        AcceptanceServerProcessIdentity? serverIdentity)
    {
        if (_options.AcceptanceNonce is null)
        {
            if (accepted.AcceptanceNonce is not null ||
                accepted.ServerProcessId is not null ||
                accepted.ServerProcessStartUtcTicks is not null ||
                accepted.ServerExecutablePath is not null ||
                accepted.ServerExecutableSha256 is not null)
            {
                throw new HerdrOpsStateIpcProtocolException(
                    "The state IPC server returned unsolicited Issue #44 acceptance identity fields.");
            }

            return;
        }

        if (!string.Equals(accepted.AcceptanceNonce, _options.AcceptanceNonce, StringComparison.Ordinal) ||
            accepted.ServerProcessId is null or <= 0 ||
            accepted.ServerProcessStartUtcTicks is null or <= 0 ||
            string.IsNullOrWhiteSpace(accepted.ServerExecutablePath) ||
            string.IsNullOrWhiteSpace(accepted.ServerExecutableSha256) ||
            accepted.ServerExecutableSha256.Length != 64)
        {
            throw new HerdrOpsStateIpcProtocolException(
                "The state IPC server did not return the exact Issue #44 acceptance binding.");
        }

        if (serverIdentity is null ||
            accepted.ServerProcessId != serverIdentity.ProcessId ||
            accepted.ServerProcessStartUtcTicks != serverIdentity.StartUtcTicks ||
            !string.Equals(
                accepted.ServerExecutablePath,
                serverIdentity.ExecutablePath,
                StringComparison.OrdinalIgnoreCase) ||
            !string.Equals(
                accepted.ServerExecutableSha256,
                serverIdentity.ExecutableSha256,
                StringComparison.Ordinal))
        {
            throw new HerdrOpsStateIpcProtocolException(
                "The state IPC acceptance response is not owned by the connected named-pipe server process.");
        }
    }

    private void WriteAcceptanceEvidence(
        HerdrOpsStateIpcHelloAccepted accepted,
        Guid correlationId,
        long snapshotSequence)
    {
        if (_options.AcceptanceNonce is null || _options.AcceptanceEvidencePath is null)
        {
            return;
        }

        using var process = System.Diagnostics.Process.GetCurrentProcess();
        var executablePath = Environment.ProcessPath;
        if (string.IsNullOrWhiteSpace(executablePath) || !File.Exists(executablePath))
        {
            throw new HerdrOpsStateIpcProtocolException(
                "The App executable path is unavailable for Issue #44 acceptance evidence.");
        }

        executablePath = Path.GetFullPath(executablePath);
        var evidence = new Issue44AcceptanceEvidence(
            SchemaVersion: 1,
            AcceptanceNonce: _options.AcceptanceNonce,
            ClientInstanceId: _clientInstanceId,
            CorrelationId: correlationId,
            ServerInstanceId: accepted.ServerInstanceId,
            CoreProcessId: accepted.ServerProcessId!.Value,
            CoreProcessStartUtcTicks: accepted.ServerProcessStartUtcTicks!.Value,
            CoreExecutablePath: accepted.ServerExecutablePath!,
            CoreExecutableSha256: accepted.ServerExecutableSha256!,
            AppProcessId: process.Id,
            AppProcessStartUtcTicks: process.StartTime.ToUniversalTime().Ticks,
            AppExecutablePath: executablePath,
            AppExecutableSha256: Convert.ToHexString(
                SHA256.HashData(File.ReadAllBytes(executablePath))),
            SnapshotSequence: snapshotSequence);
        var destination = _options.AcceptanceEvidencePath;
        var directory = Path.GetDirectoryName(destination);
        if (string.IsNullOrWhiteSpace(directory) || !Directory.Exists(directory))
        {
            throw new HerdrOpsStateIpcProtocolException(
                "The Issue #44 acceptance evidence directory does not exist.");
        }

        var temporary = destination + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            var bytes = JsonSerializer.SerializeToUtf8Bytes(evidence);
            using (var stream = new FileStream(
                       temporary,
                       FileMode.CreateNew,
                       FileAccess.Write,
                       FileShare.None))
            {
                stream.Write(bytes);
                stream.Flush(flushToDisk: true);
            }
            File.Move(temporary, destination, overwrite: false);
        }
        finally
        {
            File.Delete(temporary);
        }
    }

    private static string? NormalizeAcceptanceNonce(string? nonce)
    {
        if (string.IsNullOrWhiteSpace(nonce))
        {
            return null;
        }

        if (nonce.Length != 64 || nonce.Any(character =>
                !char.IsAsciiHexDigit(character) || char.IsLower(character)))
        {
            throw new ArgumentException(
                "The Issue #44 acceptance nonce must be exactly 64 uppercase hexadecimal characters.",
                nameof(nonce));
        }

        return nonce;
    }

    private sealed record Issue44AcceptanceEvidence(
        int SchemaVersion,
        string AcceptanceNonce,
        string ClientInstanceId,
        Guid CorrelationId,
        string ServerInstanceId,
        int CoreProcessId,
        long CoreProcessStartUtcTicks,
        string CoreExecutablePath,
        string CoreExecutableSha256,
        int AppProcessId,
        long AppProcessStartUtcTicks,
        string AppExecutablePath,
        string AppExecutableSha256,
        long SnapshotSequence);

    private sealed record AcceptanceServerProcessIdentity(
        int ProcessId,
        long StartUtcTicks,
        string ExecutablePath,
        string ExecutableSha256)
    {
        public static AcceptanceServerProcessIdentity Read(NamedPipeClientStream pipe)
        {
            if (!OperatingSystem.IsWindows() || !pipe.IsConnected ||
                !GetNamedPipeServerProcessId(pipe.SafePipeHandle, out var processId) ||
                processId == 0)
            {
                throw new HerdrOpsStateIpcProtocolException(
                    $"The connected state IPC server process ID is unavailable (Win32 {Marshal.GetLastWin32Error()}).");
            }

            try
            {
                using var process = Process.GetProcessById(checked((int)processId));
                var startBefore = process.StartTime.ToUniversalTime().Ticks;
                var path = Path.GetFullPath(
                    process.MainModule?.FileName ?? throw new InvalidOperationException(
                        "The state IPC server executable path is unavailable."));
                var sha256 = Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(path)));
                var startAfter = process.StartTime.ToUniversalTime().Ticks;
                if (process.HasExited || startBefore != startAfter)
                {
                    throw new InvalidOperationException(
                        "The state IPC server process identity changed during verification.");
                }

                return new AcceptanceServerProcessIdentity(
                    checked((int)processId),
                    startBefore,
                    path,
                    sha256);
            }
            catch (Exception exception) when (
                exception is ArgumentException or InvalidOperationException or IOException or
                Win32Exception or OverflowException)
            {
                throw new HerdrOpsStateIpcProtocolException(
                    "The connected state IPC server process identity could not be verified.",
                    exception);
            }
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetNamedPipeServerProcessId(
            SafePipeHandle pipe,
            out uint serverProcessId);
    }
}
