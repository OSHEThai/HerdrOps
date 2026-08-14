using System.IO.Pipes;
using System.Runtime.CompilerServices;
using System.Security.Principal;
using HerdrOps.Contracts.StateIpc;

namespace HerdrOps.App.StateIpc;

public sealed record HerdrOpsStatePipeClientOptions(
    string PipeName,
    int ConnectTimeoutMilliseconds = 5000,
    int MaximumFrameBytes = HerdrOpsStateIpcProtocol.MaximumFrameBytes)
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
            HerdrOpsStatePipeName.FromUserScope(userSid));
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

        var correlationId = Guid.NewGuid();
        var hello = HerdrOpsStateIpcJson.CreateEnvelope(
            HerdrOpsStateIpcProtocol.MessageTypes.Hello,
            sequence: 0,
            _timeProvider.GetUtcNow(),
            HerdrOpsStateIpcProtocol.AppSource,
            correlationId,
            new HerdrOpsStateIpcHello(
                HerdrOpsStateIpcProtocol.AppClientRole,
                _clientInstanceId));
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

        return options;
    }
}
