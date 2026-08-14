namespace HerdrOps.Infrastructure.Herdr;

public sealed record HerdrPipeEndpoint(string SocketPath, string PipeName)
{
    public const string WindowsPipePrefix = @"\\.\pipe\";

    public static HerdrPipeEndpoint FromSocketPath(string socketPath)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(socketPath);
        var trimmed = socketPath.Trim();
        if (trimmed.Length > 1024 || trimmed.IndexOf('\0') >= 0)
        {
            throw new ArgumentException("The Herdr socket path is outside accepted bounds.", nameof(socketPath));
        }

        var pipeName = trimmed.StartsWith(WindowsPipePrefix, StringComparison.OrdinalIgnoreCase)
            ? trimmed[WindowsPipePrefix.Length..]
            : trimmed;
        if (string.IsNullOrWhiteSpace(pipeName))
        {
            throw new ArgumentException("The Herdr pipe name is empty.", nameof(socketPath));
        }

        return new HerdrPipeEndpoint(trimmed, pipeName);
    }
}

public sealed class HerdrPipeEndpointResolver
{
    public HerdrPipeEndpoint Resolve(string? explicitSocketPath = null)
    {
        var socketPath = explicitSocketPath;
        if (string.IsNullOrWhiteSpace(socketPath))
        {
            socketPath = Environment.GetEnvironmentVariable("HERDR_SOCKET_PATH");
        }

        if (string.IsNullOrWhiteSpace(socketPath))
        {
            var roamingData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
            if (string.IsNullOrWhiteSpace(roamingData))
            {
                throw new InvalidOperationException(
                    "The current-user roaming application-data directory is unavailable.");
            }

            socketPath = Path.Combine(roamingData, "herdr", "herdr.sock");
        }

        return HerdrPipeEndpoint.FromSocketPath(socketPath);
    }
}
