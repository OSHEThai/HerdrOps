namespace HerdrOps.Domain.Lifecycle;

public enum StartupRegistrationState
{
    Disabled,
    Enabled,
    Conflicting,
}

public sealed record StartupRegistrationStatus(
    StartupRegistrationState State,
    string ValueName,
    string ExpectedCommand,
    string? RegisteredCommand)
{
    public bool IsEnabled => State == StartupRegistrationState.Enabled;
}

public interface ICurrentUserStartupBackend
{
    string? Read(string valueName);

    void Write(string valueName, string command);

    void Delete(string valueName);
}

public sealed class StartupRegistrationException : Exception
{
    public StartupRegistrationException(string message)
        : base(message)
    {
    }

    public StartupRegistrationException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}

/// <summary>
/// Contract constants and validation for a current-user Run registration.
/// The command intentionally contains only one quoted executable path.
/// </summary>
public static class StartupRegistrationContract
{
    public const string CurrentUserRunKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
    public const string ValueName = "HerdrOps";

    public static string QuoteExecutablePath(string executablePath)
    {
        if (string.IsNullOrWhiteSpace(executablePath))
        {
            throw new StartupRegistrationException("The startup executable path is required.");
        }

        if (!string.Equals(executablePath, executablePath.Trim(), StringComparison.Ordinal))
        {
            throw new StartupRegistrationException(
                "The startup executable path must not have leading or trailing whitespace.");
        }

        if (executablePath.Length > 32767 || executablePath.Any(char.IsControl))
        {
            throw new StartupRegistrationException("The startup executable path is malformed.");
        }

        if (executablePath.IndexOf('"') >= 0 ||
            executablePath.IndexOfAny(Path.GetInvalidPathChars()) >= 0)
        {
            throw new StartupRegistrationException("The startup executable path contains invalid characters.");
        }

        if (IsUnsupportedNamespace(executablePath) ||
            executablePath.StartsWith(@"\\", StringComparison.Ordinal) ||
            !Path.IsPathFullyQualified(executablePath))
        {
            throw new StartupRegistrationException(
                "The startup executable path must be a local, fully qualified Windows path.");
        }

        if (ContainsTraversalSegment(executablePath) ||
            executablePath.EndsWith(Path.DirectorySeparatorChar) ||
            executablePath.EndsWith(Path.AltDirectorySeparatorChar))
        {
            throw new StartupRegistrationException("The startup executable path must identify an executable file.");
        }

        string normalizedPath;
        try
        {
            normalizedPath = Path.GetFullPath(executablePath);
        }
        catch (Exception exception) when (
            exception is ArgumentException or IOException or NotSupportedException)
        {
            throw new StartupRegistrationException("The startup executable path is malformed.", exception);
        }

        var fileName = Path.GetFileName(normalizedPath);
        if (string.IsNullOrWhiteSpace(fileName) ||
            !string.Equals(Path.GetExtension(fileName), ".exe", StringComparison.OrdinalIgnoreCase) ||
            fileName.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0 ||
            fileName.IndexOf(':') >= 0 ||
            normalizedPath
                .Split(['\\', '/'], StringSplitOptions.RemoveEmptyEntries)
                .Any(IsReservedWindowsDeviceName))
        {
            throw new StartupRegistrationException(
                "The startup executable path must name a local .exe file.");
        }

        return $"\"{normalizedPath}\"";
    }

    private static bool IsUnsupportedNamespace(string path) =>
        path.StartsWith(@"\\?\", StringComparison.OrdinalIgnoreCase) ||
        path.StartsWith(@"\\.\", StringComparison.OrdinalIgnoreCase) ||
        path.StartsWith(@"\??\", StringComparison.OrdinalIgnoreCase) ||
        path.StartsWith(@"\Device\", StringComparison.OrdinalIgnoreCase);

    private static bool ContainsTraversalSegment(string path) =>
        path.Split(['\\', '/'], StringSplitOptions.RemoveEmptyEntries)
            .Any(segment => segment is "." or "..");

    private static bool IsReservedWindowsDeviceName(string component)
    {
        var extensionIndex = component.IndexOf('.', StringComparison.Ordinal);
        var stem = (extensionIndex < 0 ? component : component[..extensionIndex])
            .TrimEnd(' ', '.');

        if (stem.Equals("CON", StringComparison.OrdinalIgnoreCase) ||
            stem.Equals("PRN", StringComparison.OrdinalIgnoreCase) ||
            stem.Equals("AUX", StringComparison.OrdinalIgnoreCase) ||
            stem.Equals("NUL", StringComparison.OrdinalIgnoreCase) ||
            stem.Equals("CLOCK$", StringComparison.OrdinalIgnoreCase) ||
            stem.Equals("CONIN$", StringComparison.OrdinalIgnoreCase) ||
            stem.Equals("CONOUT$", StringComparison.OrdinalIgnoreCase))
        {
            return true;
        }

        return stem.Length == 4 &&
            (stem.StartsWith("COM", StringComparison.OrdinalIgnoreCase) ||
             stem.StartsWith("LPT", StringComparison.OrdinalIgnoreCase)) &&
            (stem[3] is (>= '1' and <= '9') or '¹' or '²' or '³');
    }
}

/// <summary>
/// Idempotent enable/disable/status operations for one deterministic current-user
/// startup value. The backend is deliberately injected so tests cannot reach the
/// real Registry Run key.
/// </summary>
public sealed class StartAtLogonService
{
    private readonly ICurrentUserStartupBackend _backend;

    public StartAtLogonService(ICurrentUserStartupBackend backend, string executablePath)
    {
        _backend = backend ?? throw new ArgumentNullException(nameof(backend));
        ExpectedCommand = StartupRegistrationContract.QuoteExecutablePath(executablePath);
    }

    public string ValueName => StartupRegistrationContract.ValueName;

    public string ExpectedCommand { get; }

    public void Enable()
    {
        var registeredCommand = _backend.Read(ValueName);
        if (string.Equals(registeredCommand, ExpectedCommand, StringComparison.Ordinal))
        {
            return;
        }

        if (registeredCommand is not null)
        {
            throw new StartupRegistrationException(
                $"The current-user startup value '{ValueName}' is owned by another command.");
        }

        _backend.Write(ValueName, ExpectedCommand);
    }

    public void Disable()
    {
        var registeredCommand = _backend.Read(ValueName);
        if (!string.Equals(registeredCommand, ExpectedCommand, StringComparison.Ordinal))
        {
            return;
        }

        _backend.Delete(ValueName);
    }

    public StartupRegistrationStatus GetStatus()
    {
        var registeredCommand = _backend.Read(ValueName);
        var state = registeredCommand switch
        {
            null => StartupRegistrationState.Disabled,
            _ when string.Equals(registeredCommand, ExpectedCommand, StringComparison.Ordinal) =>
                StartupRegistrationState.Enabled,
            _ => StartupRegistrationState.Conflicting,
        };
        return new StartupRegistrationStatus(state, ValueName, ExpectedCommand, registeredCommand);
    }
}
