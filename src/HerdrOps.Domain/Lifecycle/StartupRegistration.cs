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

    public bool IsConflicting => State == StartupRegistrationState.Conflicting;

    public bool CanToggle => !IsConflicting;
}

public interface ICurrentUserStartupBackend
{
    string? Read(string valueName);

    void Write(string valueName, string command);

    void Delete(string valueName);
}

/// <summary>
/// Coordinates cooperating current-user startup writers across processes.
/// The Windows Registry has no conditional set-if-absent operation for a
/// value, so this seam narrows the guarantee to writers that honor the same
/// per-user coordination primitive and requires a read/recheck around writes.
/// </summary>
public interface IStartupRegistrationCoordinator
{
    IDisposable Enter();
}

/// <summary>
/// Process-local fallback used by hermetic callers that do not supply the
/// Windows cross-process coordinator. Production composition supplies the
/// SID-scoped named-mutex implementation instead.
/// </summary>
public sealed class InProcessStartupRegistrationCoordinator : IStartupRegistrationCoordinator
{
    private static readonly object Sync = new();

    public IDisposable Enter()
    {
        Monitor.Enter(Sync);
        return new MonitorLease();
    }

    private sealed class MonitorLease : IDisposable
    {
        private bool _disposed;

        public void Dispose()
        {
            if (_disposed)
            {
                return;
            }

            _disposed = true;
            Monitor.Exit(Sync);
        }
    }
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

        if (!IsLocalDriveAbsolutePath(executablePath))
        {
            throw new StartupRegistrationException(
                "The startup executable path must be a local, fully qualified Windows path.");
        }

        if (executablePath.IndexOf(':', 2) >= 0 ||
            executablePath.IndexOfAny(['"', '<', '>', '|', '?', '*']) >= 0)
        {
            throw new StartupRegistrationException(
                "The startup executable path contains invalid Windows path syntax.");
        }

        var components = executablePath[3..].Split(['\\', '/'], StringSplitOptions.None);
        if (components.Length == 0 || components.Any(component => component.Length == 0))
        {
            throw new StartupRegistrationException("The startup executable path is malformed.");
        }

        foreach (var component in components)
        {
            if (component is "." or ".." ||
                component.EndsWith(' ') ||
                component.EndsWith('.') ||
                component.Any(IsInvalidWindowsComponentCharacter) ||
                IsReservedWindowsDeviceName(component))
            {
                throw new StartupRegistrationException(
                    "The startup executable path contains an invalid Windows path component.");
            }
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

        var normalizedComponents = normalizedPath.Split(['\\', '/'], StringSplitOptions.RemoveEmptyEntries);
        var fileName = normalizedComponents[^1];
        if (string.IsNullOrWhiteSpace(fileName) ||
            !string.Equals(Path.GetExtension(fileName), ".exe", StringComparison.OrdinalIgnoreCase) ||
            normalizedComponents.Skip(1).Any(component =>
                component.Any(IsInvalidWindowsComponentCharacter) ||
                IsReservedWindowsDeviceName(component)))
        {
            throw new StartupRegistrationException(
                "The startup executable path must name a local .exe file.");
        }

        return $"\"{normalizedPath}\"";
    }

    private static bool IsLocalDriveAbsolutePath(string path) =>
        path.Length >= 4 &&
        IsAsciiLetter(path[0]) &&
        path[1] == ':' &&
        IsWindowsSeparator(path[2]);

    private static bool IsWindowsSeparator(char character) => character is '\\' or '/';

    private static bool IsAsciiLetter(char character) =>
        character is (>= 'A' and <= 'Z') or (>= 'a' and <= 'z');

    private static bool IsInvalidWindowsComponentCharacter(char character) =>
        char.IsControl(character) ||
        character is '"' or '<' or '>' or '|' or '?' or '*' or ':';

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
    private readonly IStartupRegistrationCoordinator _coordinator;

    public StartAtLogonService(
        ICurrentUserStartupBackend backend,
        string executablePath,
        IStartupRegistrationCoordinator? coordinator = null)
    {
        _backend = backend ?? throw new ArgumentNullException(nameof(backend));
        _coordinator = coordinator ?? new InProcessStartupRegistrationCoordinator();
        ExpectedCommand = StartupRegistrationContract.QuoteExecutablePath(executablePath);
    }

    public string ValueName => StartupRegistrationContract.ValueName;

    public string ExpectedCommand { get; }

    public StartupRegistrationStatus Enable()
    {
        using var coordination = _coordinator.Enter();
        var registeredCommand = _backend.Read(ValueName);
        if (registeredCommand is not null)
        {
            return CreateStatus(registeredCommand);
        }

        registeredCommand = _backend.Read(ValueName);
        if (registeredCommand is not null)
        {
            return CreateStatus(registeredCommand);
        }

        _backend.Write(ValueName, ExpectedCommand);

        // Registry value writes are not conditional. Re-read immediately so a
        // cooperating or uncooperative writer that won the race is surfaced as
        // controlled status instead of being reported as enabled.
        return CreateStatus(_backend.Read(ValueName));
    }

    public StartupRegistrationStatus Disable()
    {
        using var coordination = _coordinator.Enter();
        var registeredCommand = _backend.Read(ValueName);
        if (!string.Equals(registeredCommand, ExpectedCommand, StringComparison.Ordinal))
        {
            return CreateStatus(registeredCommand);
        }

        registeredCommand = _backend.Read(ValueName);
        if (!string.Equals(registeredCommand, ExpectedCommand, StringComparison.Ordinal))
        {
            return CreateStatus(registeredCommand);
        }

        _backend.Delete(ValueName);
        return CreateStatus(_backend.Read(ValueName));
    }

    public StartupRegistrationStatus GetStatus()
    {
        using var coordination = _coordinator.Enter();
        return CreateStatus(_backend.Read(ValueName));
    }

    private StartupRegistrationStatus CreateStatus(string? registeredCommand)
    {
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
