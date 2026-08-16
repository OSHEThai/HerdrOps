using System.Text;

namespace HerdrOps.Domain.Settings;

/// <summary>
/// The selected product language. A settings document contains exactly one value.
/// </summary>
public enum AppSettingsLanguage
{
    Thai,
    English,
}

/// <summary>
/// The seven widget variants defined by the visual contract.
/// </summary>
public enum AppSettingsWidgetVariant
{
    Compact,
    Normal,
    Expanded,
    FloatingMini,
    FloatingVertical,
    Notification,
    AgentDetailPopup,
}

/// <summary>
/// User-controlled settings that do not identify a credential or secret.
/// </summary>
public sealed record AppUserPreferences
{
    public string? SelectedProjectId { get; init; }

    public bool ShowOfflineAgents { get; init; }

    public bool ReducedMotion { get; init; }

    public int RefreshIntervalSeconds { get; init; }

    public static AppUserPreferences Defaults => new()
    {
        SelectedProjectId = null,
        ShowOfflineAgents = true,
        ReducedMotion = false,
        RefreshIntervalSeconds = 5,
    };
}

/// <summary>
/// Versioned, immutable application settings. This model intentionally has no
/// credential, token, password, API-key, or connection-secret field.
/// </summary>
public sealed record AppSettings
{
    public AppSettings(
        int schemaVersion,
        AppSettingsLanguage language,
        AppSettingsWidgetVariant widgetVariant,
        bool widgetEnabled,
        bool widgetPinned,
        AppUserPreferences userPreferences,
        string? localExportDirectory)
    {
        SchemaVersion = schemaVersion;
        Language = language;
        WidgetVariant = widgetVariant;
        WidgetEnabled = widgetEnabled;
        WidgetPinned = widgetPinned;
        UserPreferences = userPreferences ?? throw new ArgumentNullException(nameof(userPreferences));
        LocalExportDirectory = localExportDirectory;
    }

    public int SchemaVersion { get; init; }

    public AppSettingsLanguage Language { get; init; }

    public AppSettingsWidgetVariant WidgetVariant { get; init; }

    public bool WidgetEnabled { get; init; }

    public bool WidgetPinned { get; init; }

    public AppUserPreferences UserPreferences { get; init; }

    /// <summary>
    /// Optional local directory for non-secret exports. It must pass the safe
    /// absolute destination policy before admission.
    /// </summary>
    public string? LocalExportDirectory { get; init; }

    public static AppSettings Defaults => new(
        AppSettingsContract.CurrentSchemaVersion,
        AppSettingsLanguage.Thai,
        AppSettingsWidgetVariant.Normal,
        widgetEnabled: true,
        widgetPinned: false,
        AppUserPreferences.Defaults,
        localExportDirectory: null);
}

/// <summary>
/// A state that has passed validation and was admitted by the settings store.
/// The canonical JSON and digest bind restore operations to the admitted state.
/// </summary>
public sealed record AppSettingsSnapshot(
    AppSettings Settings,
    string CanonicalJson,
    string Sha256);

public sealed class SettingsValidationException : Exception
{
    public SettingsValidationException(string message)
        : base(message)
    {
    }

    public SettingsValidationException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}

/// <summary>
/// Validation and normalization rules shared by the model and the JSON store.
/// </summary>
public static class AppSettingsContract
{
    public const int CurrentSchemaVersion = 1;
    public const int MaximumDocumentUtf8Bytes = 16 * 1024;
    public const int MaximumProjectIdUtf8Bytes = 256;
    public const int MaximumDestinationUtf8Bytes = 4 * 1024;
    public const int MinimumRefreshIntervalSeconds = 1;
    public const int MaximumRefreshIntervalSeconds = 60;

    public static AppSettings Admit(AppSettings settings)
    {
        ArgumentNullException.ThrowIfNull(settings);

        if (settings.SchemaVersion != CurrentSchemaVersion)
        {
            throw new SettingsValidationException(
                $"Unsupported settings schema version: {settings.SchemaVersion}.");
        }

        if (!Enum.IsDefined(settings.Language))
        {
            throw new SettingsValidationException("The settings language is unsupported.");
        }

        if (!Enum.IsDefined(settings.WidgetVariant))
        {
            throw new SettingsValidationException("The settings widget variant is unsupported.");
        }

        var preferences = settings.UserPreferences ?? throw new SettingsValidationException(
            "User preferences are required.");

        var selectedProjectId = NormalizeBoundedText(
            preferences.SelectedProjectId,
            MaximumProjectIdUtf8Bytes,
            "selectedProjectId");

        if (preferences.RefreshIntervalSeconds is < MinimumRefreshIntervalSeconds
            or > MaximumRefreshIntervalSeconds)
        {
            throw new SettingsValidationException(
                $"refreshIntervalSeconds must be between {MinimumRefreshIntervalSeconds} and " +
                $"{MaximumRefreshIntervalSeconds}.");
        }

        var localExportDirectory = settings.LocalExportDirectory is null
            ? null
            : SettingsPathPolicy.NormalizeAbsoluteDirectory(
                settings.LocalExportDirectory,
                MaximumDestinationUtf8Bytes);

        return settings with
        {
            UserPreferences = preferences with { SelectedProjectId = selectedProjectId },
            LocalExportDirectory = localExportDirectory,
        };
    }

    private static string? NormalizeBoundedText(string? value, int maximumUtf8Bytes, string name)
    {
        if (value is null)
        {
            return null;
        }

        if (value.Length == 0 || value != value.Trim())
        {
            throw new SettingsValidationException($"{name} must be a non-empty trimmed value.");
        }

        if (value.Any(char.IsControl))
        {
            throw new SettingsValidationException($"{name} contains a control character.");
        }

        if (Encoding.UTF8.GetByteCount(value) > maximumUtf8Bytes)
        {
            throw new SettingsValidationException(
                $"{name} exceeds its {maximumUtf8Bytes}-byte UTF-8 bound.");
        }

        return value;
    }
}

/// <summary>
/// Safe local destination policy. Paths must be absolute, local, non-root,
/// traversal-free, and optionally contained by a caller-supplied local root.
/// </summary>
public static class SettingsPathPolicy
{
    public static string NormalizeAbsoluteDirectory(string path, int maximumUtf8Bytes)
    {
        var fullPath = NormalizeAbsoluteLocalPath(
            path,
            maximumUtf8Bytes,
            "destination directory",
            allowTrailingSeparators: true);

        var root = Path.GetPathRoot(fullPath);
        if (string.IsNullOrWhiteSpace(root)
            || string.Equals(
                fullPath.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar),
                root.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar),
                StringComparison.OrdinalIgnoreCase))
        {
            throw new SettingsValidationException("The destination directory cannot be a filesystem root.");
        }

        var normalized = fullPath.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        EnsureNoExistingReparsePointComponents(normalized);
        return normalized;
    }

    public static string NormalizeAbsoluteFile(string path, int maximumUtf8Bytes)
    {
        var fullPath = NormalizeAbsoluteLocalPath(
            path,
            maximumUtf8Bytes,
            "settings file path",
            allowTrailingSeparators: false);

        var directory = Path.GetDirectoryName(fullPath);
        var root = Path.GetPathRoot(fullPath);
        var fileName = Path.GetFileName(fullPath);
        if (string.IsNullOrWhiteSpace(directory)
            || string.IsNullOrWhiteSpace(root)
            || string.IsNullOrWhiteSpace(fileName)
            || string.Equals(
                directory.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar),
                root.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar),
                StringComparison.OrdinalIgnoreCase))
        {
            throw new SettingsValidationException("The settings file cannot be placed at a filesystem root.");
        }

        EnsureNoExistingReparsePointComponents(fullPath);
        return fullPath;
    }

    public static void EnsureContainedByRoot(string destination, string allowedRoot)
    {
        var normalizedDestination = NormalizeAbsoluteDirectory(
            destination,
            AppSettingsContract.MaximumDestinationUtf8Bytes);
        var normalizedRoot = NormalizeAbsoluteDirectory(
            allowedRoot,
            AppSettingsContract.MaximumDestinationUtf8Bytes);

        if (!IsSameOrDescendant(normalizedDestination, normalizedRoot))
        {
            throw new SettingsValidationException(
                "The destination directory must be contained by the configured local root.");
        }
    }

    public static void EnsureNoExistingReparsePointComponents(string path)
    {
        var fullPath = Path.GetFullPath(path);
        var root = Path.GetPathRoot(fullPath);
        if (string.IsNullOrWhiteSpace(root))
        {
            throw new SettingsValidationException("The path has no filesystem root.");
        }

        var current = root;
        EnsureComponentIsNotReparsePoint(current);

        var relative = fullPath[root.Length..];
        foreach (var segment in relative.Split(
                     ['\\', '/'],
                     StringSplitOptions.RemoveEmptyEntries))
        {
            current = Path.Combine(current, segment);
            if (!TryGetAttributes(current, out var attributes))
            {
                break;
            }

            if ((attributes & FileAttributes.ReparsePoint) != 0)
            {
                throw new SettingsValidationException(
                    $"The path contains an existing reparse-point component: {current}.");
            }
        }
    }

    private static string NormalizeAbsoluteLocalPath(
        string path,
        int maximumUtf8Bytes,
        string name,
        bool allowTrailingSeparators)
    {
        if (string.IsNullOrWhiteSpace(path) || path != path.Trim())
        {
            throw new SettingsValidationException($"The {name} must be a trimmed value.");
        }

        if (path.Any(char.IsControl))
        {
            throw new SettingsValidationException($"The {name} contains a control character.");
        }

        if (Encoding.UTF8.GetByteCount(path) > maximumUtf8Bytes)
        {
            throw new SettingsValidationException(
                $"The {name} exceeds its {maximumUtf8Bytes}-byte UTF-8 bound.");
        }

        if (!Path.IsPathFullyQualified(path))
        {
            throw new SettingsValidationException($"The {name} must be absolute.");
        }

        if (IsDeviceOrNamespacePath(path))
        {
            throw new SettingsValidationException($"The {name} must be a local non-device path.");
        }

        if (!allowTrailingSeparators
            && (path.EndsWith('\\') || path.EndsWith('/')))
        {
            throw new SettingsValidationException($"The {name} must contain a file name.");
        }

        ValidateRawComponents(path, name, allowTrailingSeparators);

        try
        {
            return Path.GetFullPath(path);
        }
        catch (Exception exception) when (exception is ArgumentException or IOException or NotSupportedException)
        {
            throw new SettingsValidationException($"The {name} is not a valid path.", exception);
        }
    }

    private static void ValidateRawComponents(string path, string name, bool allowTrailingSeparators)
    {
        var root = Path.GetPathRoot(path);
        if (string.IsNullOrWhiteSpace(root))
        {
            throw new SettingsValidationException($"The {name} has no filesystem root.");
        }

        var relative = path[root.Length..];
        if (allowTrailingSeparators)
        {
            relative = relative.TrimEnd('\\', '/');
        }

        if (relative.Length == 0)
        {
            return;
        }

        var components = relative.Split(['\\', '/'], StringSplitOptions.None);
        if (components.Any(string.IsNullOrEmpty))
        {
            throw new SettingsValidationException($"The {name} contains an empty path component.");
        }

        foreach (var component in components)
        {
            if (component is "." or ".."
                || component.EndsWith('.')
                || component.EndsWith(' ')
                || component.Contains(':', StringComparison.Ordinal)
                || component.Any(IsInvalidWindowsPathCharacter)
                || IsReservedWindowsDeviceName(component))
            {
                throw new SettingsValidationException(
                    $"The {name} contains an invalid, reserved, or device path component.");
            }
        }
    }

    private static bool IsInvalidWindowsPathCharacter(char character) =>
        char.IsControl(character)
        || character is '<' or '>' or '"' or '|' or '?' or '*';

    private static bool IsReservedWindowsDeviceName(string component)
    {
        var extensionIndex = component.IndexOf('.', StringComparison.Ordinal);
        var stem = (extensionIndex < 0 ? component : component[..extensionIndex])
            .TrimEnd(' ', '.');
        if (stem.Equals("CON", StringComparison.OrdinalIgnoreCase)
            || stem.Equals("PRN", StringComparison.OrdinalIgnoreCase)
            || stem.Equals("AUX", StringComparison.OrdinalIgnoreCase)
            || stem.Equals("NUL", StringComparison.OrdinalIgnoreCase)
            || stem.Equals("CLOCK$", StringComparison.OrdinalIgnoreCase)
            || stem.Equals("CONIN$", StringComparison.OrdinalIgnoreCase)
            || stem.Equals("CONOUT$", StringComparison.OrdinalIgnoreCase))
        {
            return true;
        }

        return stem.Length == 4
            && (stem.StartsWith("COM", StringComparison.OrdinalIgnoreCase)
                || stem.StartsWith("LPT", StringComparison.OrdinalIgnoreCase))
            && stem[3] is (>= '1' and <= '9') or '¹' or '²' or '³';
    }

    private static bool IsDeviceOrNamespacePath(string path) =>
        path.StartsWith("\\\\", StringComparison.Ordinal)
        || path.StartsWith("//", StringComparison.Ordinal)
        || path.StartsWith("\\??\\", StringComparison.OrdinalIgnoreCase)
        || path.StartsWith("/??/", StringComparison.OrdinalIgnoreCase)
        || path.StartsWith("\\Device\\", StringComparison.OrdinalIgnoreCase)
        || path.StartsWith("/Device/", StringComparison.OrdinalIgnoreCase);

    private static bool IsSameOrDescendant(string candidate, string root)
    {
        if (string.Equals(candidate, root, StringComparison.OrdinalIgnoreCase))
        {
            return true;
        }

        var prefix = root.EndsWith(Path.DirectorySeparatorChar)
            ? root
            : root + Path.DirectorySeparatorChar;
        return candidate.StartsWith(prefix, StringComparison.OrdinalIgnoreCase);
    }

    private static void EnsureComponentIsNotReparsePoint(string path)
    {
        if (TryGetAttributes(path, out var attributes)
            && (attributes & FileAttributes.ReparsePoint) != 0)
        {
            throw new SettingsValidationException(
                $"The path contains an existing reparse-point component: {path}.");
        }
    }

    private static bool TryGetAttributes(string path, out FileAttributes attributes)
    {
        try
        {
            attributes = File.GetAttributes(path);
            return true;
        }
        catch (Exception exception) when (exception is FileNotFoundException or DirectoryNotFoundException)
        {
            attributes = default;
            return false;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            throw new SettingsValidationException(
                $"The path could not be inspected safely: {path}.",
                exception);
        }
    }
}

public interface IAppSettingsStore
{
    Task<AppSettingsSnapshot?> LoadAsync(CancellationToken cancellationToken = default);

    Task<AppSettingsSnapshot> SaveAsync(
        AppSettings settings,
        CancellationToken cancellationToken = default);

    Task<AppSettingsSnapshot> RestoreAsync(
        AppSettingsSnapshot snapshot,
        CancellationToken cancellationToken = default);

    Task<AppSettingsSnapshot> ResetToDefaultsAsync(CancellationToken cancellationToken = default);
}
