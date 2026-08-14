using HerdrOps.Domain.Herdr;

namespace HerdrOps.Infrastructure.Herdr;

public interface IHerdrApiClient
{
    HerdrServerProcessIdentity? LastVerifiedServerIdentity { get; }

    Task<HerdrSessionSnapshot> GetSnapshotAsync(
        HerdrPipeEndpoint endpoint,
        CancellationToken cancellationToken);

    Task<IHerdrEventSubscription> SubscribeAsync(
        HerdrPipeEndpoint endpoint,
        IReadOnlyCollection<string> paneIds,
        CancellationToken cancellationToken);
}

public interface IHerdrEventSubscription : IAsyncDisposable
{
    ValueTask<HerdrStateEvent> ReadNextAsync(CancellationToken cancellationToken);
}

public interface IHerdrStreamConnector
{
    Task<HerdrConnectedStream> ConnectAsync(
        HerdrPipeEndpoint endpoint,
        TimeSpan timeout,
        CancellationToken cancellationToken);
}

public sealed record HerdrNamedPipeApiClientOptions(
    TimeSpan ConnectTimeout,
    int MaximumFrameBytes)
{
    public const int DefaultMaximumFrameBytes = 4 * 1024 * 1024;

    public static HerdrNamedPipeApiClientOptions Default { get; } = new(
        TimeSpan.FromSeconds(2),
        DefaultMaximumFrameBytes);

    public void Validate()
    {
        if (ConnectTimeout <= TimeSpan.Zero || ConnectTimeout > TimeSpan.FromMinutes(1))
        {
            throw new ArgumentOutOfRangeException(
                nameof(ConnectTimeout),
                "The connection timeout must be greater than zero and no more than one minute.");
        }

        if (MaximumFrameBytes < 256 || MaximumFrameBytes > 16 * 1024 * 1024)
        {
            throw new ArgumentOutOfRangeException(
                nameof(MaximumFrameBytes),
                "The frame limit must be between 256 bytes and 16 MiB.");
        }
    }
}

public sealed class HerdrProtocolException : IOException
{
    public HerdrProtocolException(string message)
        : base(message)
    {
    }

    public HerdrProtocolException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}

public sealed class HerdrApiErrorException : Exception
{
    public HerdrApiErrorException(string code, string message)
        : base($"Herdr API error '{code}': {message}")
    {
        Code = code;
    }

    public string Code { get; }
}
