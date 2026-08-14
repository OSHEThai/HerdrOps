using System.Security.Cryptography;

namespace HerdrOps.Infrastructure.Herdr;

public sealed record HerdrServerProcessIdentity(
    int ProcessId,
    DateTimeOffset ProcessStartUtc,
    string ExecutablePath,
    string ExecutableSha256);

public sealed class HerdrConnectedStream : IAsyncDisposable
{
    public HerdrConnectedStream(
        Stream stream,
        int serverProcessId,
        DateTimeOffset serverProcessStartUtc,
        string serverExecutablePath)
    {
        Stream = stream ?? throw new ArgumentNullException(nameof(stream));
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(serverProcessId);
        ArgumentException.ThrowIfNullOrWhiteSpace(serverExecutablePath);
        ServerProcessId = serverProcessId;
        ServerProcessStartUtc = serverProcessStartUtc;
        ServerExecutablePath = Path.GetFullPath(serverExecutablePath);
    }

    public Stream Stream { get; }

    public int ServerProcessId { get; }

    public DateTimeOffset ServerProcessStartUtc { get; }

    public string ServerExecutablePath { get; }

    public ValueTask DisposeAsync() => Stream.DisposeAsync();
}

public interface IHerdrServerIdentityVerifier
{
    HerdrServerProcessIdentity? Verify(HerdrConnectedStream connection);
}

/// <summary>
/// Explicit opt-out used by synthetic transports only. Runtime evidence must use
/// <see cref="ExpectedHerdrServerIdentityVerifier"/>.
/// </summary>
public sealed class AllowUnboundHerdrServerIdentityForSyntheticTests : IHerdrServerIdentityVerifier
{
    public static AllowUnboundHerdrServerIdentityForSyntheticTests Instance { get; } = new();

    private AllowUnboundHerdrServerIdentityForSyntheticTests()
    {
    }

    public HerdrServerProcessIdentity? Verify(HerdrConnectedStream connection)
    {
        ArgumentNullException.ThrowIfNull(connection);
        return null;
    }
}

public sealed class ExpectedHerdrServerIdentityVerifier : IHerdrServerIdentityVerifier
{
    private const long MaximumExecutableBytes = 128L * 1024 * 1024;
    private readonly object _cacheLock = new();
    private readonly string _expectedExecutableSha256;
    private readonly Dictionary<ServerProcessKey, HerdrServerProcessIdentity> _verifiedProcesses = [];

    public ExpectedHerdrServerIdentityVerifier(string expectedExecutableSha256)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(expectedExecutableSha256);
        if (expectedExecutableSha256.Length != 64 ||
            expectedExecutableSha256.Any(character => !Uri.IsHexDigit(character)))
        {
            throw new ArgumentException(
                "The expected Herdr server SHA-256 must contain exactly 64 hexadecimal characters.",
                nameof(expectedExecutableSha256));
        }

        _expectedExecutableSha256 = expectedExecutableSha256.ToUpperInvariant();
    }

    public HerdrServerProcessIdentity Verify(HerdrConnectedStream connection)
    {
        ArgumentNullException.ThrowIfNull(connection);
        var key = new ServerProcessKey(
            connection.ServerProcessId,
            connection.ServerProcessStartUtc,
            connection.ServerExecutablePath);
        lock (_cacheLock)
        {
            if (_verifiedProcesses.TryGetValue(key, out var cached))
            {
                return cached;
            }

            HerdrExecutableSnapshot snapshot;
            try
            {
                snapshot = new HerdrExecutableSnapshotReader().Read(
                    connection.ServerExecutablePath,
                    MaximumExecutableBytes);
            }
            catch (Exception exception) when (
                exception is IOException or UnauthorizedAccessException or ArgumentException)
            {
                throw new HerdrServerIdentityException(
                    $"The Named Pipe server executable could not be snapshotted: {exception.Message}",
                    exception);
            }

            var actualSha256 = Convert.ToHexString(SHA256.HashData(snapshot.Bytes));
            if (!string.Equals(actualSha256, _expectedExecutableSha256, StringComparison.Ordinal))
            {
                throw new HerdrServerIdentityException(
                    $"Named Pipe server PID {connection.ServerProcessId} has executable SHA-256 {actualSha256}, " +
                    $"not admitted SHA-256 {_expectedExecutableSha256}.");
            }

            var identity = new HerdrServerProcessIdentity(
                connection.ServerProcessId,
                connection.ServerProcessStartUtc,
                snapshot.FinalPath,
                actualSha256);
            _verifiedProcesses.Add(key, identity);
            return identity;
        }
    }

    private sealed record ServerProcessKey(
        int ProcessId,
        DateTimeOffset ProcessStartUtc,
        string ExecutablePath);
}

public sealed class HerdrServerIdentityException : IOException
{
    public HerdrServerIdentityException(string message)
        : base(message)
    {
    }

    public HerdrServerIdentityException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}
