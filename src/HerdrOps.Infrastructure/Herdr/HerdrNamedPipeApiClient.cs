using HerdrOps.Domain.Herdr;

namespace HerdrOps.Infrastructure.Herdr;

public sealed class HerdrNamedPipeApiClient : IHerdrApiClient
{
    private readonly IHerdrStreamConnector _connector;
    private readonly IHerdrServerIdentityVerifier _serverIdentityVerifier;
    private readonly HerdrNamedPipeApiClientOptions _options;
    private HerdrServerProcessIdentity? _lastVerifiedServerIdentity;

    public HerdrNamedPipeApiClient(
        IHerdrStreamConnector? connector = null,
        IHerdrServerIdentityVerifier? serverIdentityVerifier = null,
        HerdrNamedPipeApiClientOptions? options = null)
    {
        _connector = connector ?? new HerdrNamedPipeStreamConnector();
        _serverIdentityVerifier = serverIdentityVerifier ?? throw new ArgumentNullException(
            nameof(serverIdentityVerifier),
            "A server identity verifier is required. Use the explicitly named synthetic verifier only in tests.");
        _options = options ?? HerdrNamedPipeApiClientOptions.Default;
        _options.Validate();
    }

    public HerdrServerProcessIdentity? LastVerifiedServerIdentity =>
        Volatile.Read(ref _lastVerifiedServerIdentity);

    public async Task<HerdrSessionSnapshot> GetSnapshotAsync(
        HerdrPipeEndpoint endpoint,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(endpoint);
        var requestId = CreateRequestId("snapshot");
        var request = HerdrProtocolJsonCodec.CreateSnapshotRequest(requestId);
        await using var connection = await _connector
            .ConnectAsync(endpoint, _options.ConnectTimeout, cancellationToken)
            .ConfigureAwait(false);
        RecordVerifiedIdentity(_serverIdentityVerifier.Verify(connection));
        var reader = new HerdrJsonLineReader(connection.Stream, _options.MaximumFrameBytes);
        await HerdrJsonLineWriter
            .WriteAsync(connection.Stream, request, _options.MaximumFrameBytes, cancellationToken)
            .ConfigureAwait(false);
        var response = await reader.ReadAsync(cancellationToken).ConfigureAwait(false);
        return HerdrProtocolJsonCodec.ParseSnapshotResponse(response, requestId);
    }

    public async Task<IHerdrEventSubscription> SubscribeAsync(
        HerdrPipeEndpoint endpoint,
        IReadOnlyCollection<string> paneIds,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(endpoint);
        ArgumentNullException.ThrowIfNull(paneIds);
        var requestId = CreateRequestId("subscribe");
        var request = HerdrProtocolJsonCodec.CreateSubscriptionRequest(requestId, paneIds);
        var connection = await _connector
            .ConnectAsync(endpoint, _options.ConnectTimeout, cancellationToken)
            .ConfigureAwait(false);
        try
        {
            RecordVerifiedIdentity(_serverIdentityVerifier.Verify(connection));
            var reader = new HerdrJsonLineReader(connection.Stream, _options.MaximumFrameBytes);
            await HerdrJsonLineWriter
                .WriteAsync(connection.Stream, request, _options.MaximumFrameBytes, cancellationToken)
                .ConfigureAwait(false);
            var response = await reader.ReadAsync(cancellationToken).ConfigureAwait(false);
            HerdrProtocolJsonCodec.ValidateSubscriptionStarted(response, requestId);
            return new HerdrNamedPipeEventSubscription(connection, reader);
        }
        catch
        {
            await connection.DisposeAsync().ConfigureAwait(false);
            throw;
        }
    }

    private void RecordVerifiedIdentity(HerdrServerProcessIdentity? identity)
    {
        if (identity is not null)
        {
            Volatile.Write(ref _lastVerifiedServerIdentity, identity);
        }
    }

    private static string CreateRequestId(string operation) =>
        $"herdrops:{operation}:{Guid.NewGuid():N}";

    private sealed class HerdrNamedPipeEventSubscription : IHerdrEventSubscription
    {
        private readonly HerdrConnectedStream _connection;
        private readonly HerdrJsonLineReader _reader;
        private int _readActive;
        private int _disposed;

        public HerdrNamedPipeEventSubscription(
            HerdrConnectedStream connection,
            HerdrJsonLineReader reader)
        {
            _connection = connection;
            _reader = reader;
        }

        public async ValueTask<HerdrStateEvent> ReadNextAsync(CancellationToken cancellationToken)
        {
            ObjectDisposedException.ThrowIf(Volatile.Read(ref _disposed) != 0, this);
            if (Interlocked.Exchange(ref _readActive, 1) != 0)
            {
                throw new InvalidOperationException("Concurrent Herdr subscription reads are not supported.");
            }

            try
            {
                var frame = await _reader.ReadAsync(cancellationToken).ConfigureAwait(false);
                return HerdrProtocolJsonCodec.ParseEvent(frame);
            }
            finally
            {
                Volatile.Write(ref _readActive, 0);
            }
        }

        public async ValueTask DisposeAsync()
        {
            if (Interlocked.Exchange(ref _disposed, 1) == 0)
            {
                await _connection.DisposeAsync().ConfigureAwait(false);
            }
        }
    }
}
