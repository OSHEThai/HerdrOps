using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Runtime.ExceptionServices;
using HerdrOps.Domain.Settings;

namespace HerdrOps.Infrastructure.Settings;

public interface ISettingsAtomicCommit
{
    void Commit(string temporaryPath, string destinationPath);
}

public interface ISettingsTemporaryFileCleanup
{
    void Delete(string temporaryPath);
}

public sealed class FileSystemSettingsTemporaryFileCleanup : ISettingsTemporaryFileCleanup
{
    public void Delete(string temporaryPath)
    {
        File.Delete(temporaryPath);
    }
}

public sealed class FileSystemSettingsAtomicCommit : ISettingsAtomicCommit
{
    public void Commit(string temporaryPath, string destinationPath)
    {
        if (File.Exists(destinationPath))
        {
            File.Replace(temporaryPath, destinationPath, destinationBackupFileName: null, ignoreMetadataErrors: true);
        }
        else
        {
            File.Move(temporaryPath, destinationPath);
        }
    }
}

public sealed class JsonAppSettingsStore : IAppSettingsStore
{
    private static readonly UTF8Encoding StrictUtf8 = new(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true);
    private static readonly JsonSerializerOptions SerializerOptions = new()
    {
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.Default,
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DictionaryKeyPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.Never,
    };

    private static readonly HashSet<string> RootPropertyNames =
    [
        "schemaVersion",
        "language",
        "widgetVariant",
        "widgetEnabled",
        "widgetPinned",
        "userPreferences",
        "localExportDirectory",
    ];

    private static readonly HashSet<string> PreferencePropertyNames =
    [
        "selectedProjectId",
        "showOfflineAgents",
        "reducedMotion",
        "refreshIntervalSeconds",
    ];

    private readonly string _destinationPath;
    private readonly string _destinationDirectory;
    private readonly ISettingsAtomicCommit _atomicCommit;
    private readonly ISettingsTemporaryFileCleanup _temporaryFileCleanup;
    private readonly int _maximumDocumentUtf8Bytes;

    public JsonAppSettingsStore(
        string destinationPath,
        string? allowedRootDirectory = null,
        ISettingsAtomicCommit? atomicCommit = null,
        int maximumDocumentUtf8Bytes = AppSettingsContract.MaximumDocumentUtf8Bytes,
        ISettingsTemporaryFileCleanup? temporaryFileCleanup = null)
    {
        if (maximumDocumentUtf8Bytes <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(maximumDocumentUtf8Bytes));
        }

        _destinationPath = NormalizeDestinationFile(destinationPath, allowedRootDirectory);
        _destinationDirectory = Path.GetDirectoryName(_destinationPath)
            ?? throw new SettingsValidationException("The settings file must have a destination directory.");
        _atomicCommit = atomicCommit ?? new FileSystemSettingsAtomicCommit();
        _temporaryFileCleanup = temporaryFileCleanup ?? new FileSystemSettingsTemporaryFileCleanup();
        _maximumDocumentUtf8Bytes = maximumDocumentUtf8Bytes;
    }

    public async Task<AppSettingsSnapshot?> LoadAsync(CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (!File.Exists(_destinationPath))
        {
            return null;
        }

        byte[] bytes;
        try
        {
            var fileInfo = new FileInfo(_destinationPath);
            if (fileInfo.Length > _maximumDocumentUtf8Bytes)
            {
                throw new SettingsValidationException(
                    $"The settings document exceeds its {_maximumDocumentUtf8Bytes}-byte UTF-8 bound.");
            }

            bytes = await File.ReadAllBytesAsync(_destinationPath, cancellationToken).ConfigureAwait(false);
        }
        catch (SettingsValidationException)
        {
            throw;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            throw new SettingsValidationException("The settings document could not be read.", exception);
        }

        if (bytes.Length > _maximumDocumentUtf8Bytes)
        {
            throw new SettingsValidationException(
                $"The settings document exceeds its {_maximumDocumentUtf8Bytes}-byte UTF-8 bound.");
        }

        var json = DecodeStrictUtf8(bytes);
        cancellationToken.ThrowIfCancellationRequested();
        var settings = ParseAndValidate(json);
        cancellationToken.ThrowIfCancellationRequested();
        var canonicalJson = SerializeCanonical(settings);
        EnsureDocumentBound(StrictUtf8.GetBytes(canonicalJson));
        return CreateSnapshot(settings, canonicalJson);
    }

    public async Task<AppSettingsSnapshot> SaveAsync(
        AppSettings settings,
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var admitted = AppSettingsContract.Admit(settings);
        cancellationToken.ThrowIfCancellationRequested();
        var json = SerializeCanonical(admitted);
        var bytes = StrictUtf8.GetBytes(json);
        EnsureDocumentBound(bytes);
        cancellationToken.ThrowIfCancellationRequested();
        await CommitAsync(bytes, cancellationToken).ConfigureAwait(false);
        return CreateSnapshot(admitted, json);
    }

    public Task<AppSettingsSnapshot> RestoreAsync(
        AppSettingsSnapshot snapshot,
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        ArgumentNullException.ThrowIfNull(snapshot);
        cancellationToken.ThrowIfCancellationRequested();
        var admitted = AppSettingsContract.Admit(snapshot.Settings);
        cancellationToken.ThrowIfCancellationRequested();
        var canonicalJson = SerializeCanonical(admitted);
        var expectedSha256 = ComputeSha256(canonicalJson);

        if (!string.Equals(snapshot.CanonicalJson, canonicalJson, StringComparison.Ordinal)
            || !string.Equals(snapshot.Sha256, expectedSha256, StringComparison.OrdinalIgnoreCase))
        {
            throw new SettingsValidationException("The settings snapshot failed its integrity check.");
        }

        cancellationToken.ThrowIfCancellationRequested();
        return SaveAsync(admitted, cancellationToken);
    }

    public Task<AppSettingsSnapshot> ResetToDefaultsAsync(CancellationToken cancellationToken = default) =>
        SaveAsync(AppSettings.Defaults, cancellationToken);

    private async Task CommitAsync(byte[] bytes, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        SettingsPathPolicy.EnsureNoExistingReparsePointComponents(_destinationDirectory);
        Directory.CreateDirectory(_destinationDirectory);
        SettingsPathPolicy.EnsureNoExistingReparsePointComponents(_destinationDirectory);
        SettingsPathPolicy.EnsureNoExistingReparsePointComponents(_destinationPath);
        var temporaryPath = Path.Combine(
            _destinationDirectory,
            $".{Path.GetFileName(_destinationPath)}.{Guid.NewGuid():N}.tmp");

        Exception? primaryException = null;
        try
        {
            await using (var stream = new FileStream(
                temporaryPath,
                FileMode.CreateNew,
                FileAccess.Write,
                FileShare.None,
                bufferSize: 4096,
                options: FileOptions.SequentialScan))
            {
                await stream.WriteAsync(bytes, cancellationToken).ConfigureAwait(false);
                await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
                stream.Flush(flushToDisk: true);
            }

            cancellationToken.ThrowIfCancellationRequested();
            SettingsPathPolicy.EnsureNoExistingReparsePointComponents(_destinationDirectory);
            SettingsPathPolicy.EnsureNoExistingReparsePointComponents(_destinationPath);
            _atomicCommit.Commit(temporaryPath, _destinationPath);
        }
        catch (Exception exception)
        {
            primaryException = NormalizeCommitException(exception);
        }

        Exception? cleanupException = null;
        try
        {
            _temporaryFileCleanup.Delete(temporaryPath);
        }
        catch (Exception exception)
        {
            cleanupException = exception;
        }

        if (primaryException is not null && cleanupException is not null)
        {
            throw new AggregateException(
                "The settings commit and temporary-file cleanup both failed.",
                primaryException,
                cleanupException);
        }

        if (primaryException is not null)
        {
            ExceptionDispatchInfo.Capture(primaryException).Throw();
        }

        if (cleanupException is not null)
        {
            throw new SettingsValidationException(
                "The settings document was committed, but temporary-file cleanup failed.",
                cleanupException);
        }
    }

    private string NormalizeDestinationFile(string destinationPath, string? allowedRootDirectory)
    {
        var fullPath = SettingsPathPolicy.NormalizeAbsoluteFile(
            destinationPath,
            AppSettingsContract.MaximumDestinationUtf8Bytes);

        var directory = Path.GetDirectoryName(fullPath);
        if (directory is null)
        {
            throw new SettingsValidationException("The settings file must have a destination directory.");
        }

        if (allowedRootDirectory is not null)
        {
            SettingsPathPolicy.EnsureContainedByRoot(directory, allowedRootDirectory);
        }

        return fullPath;
    }

    private AppSettings ParseAndValidate(string json)
    {
        try
        {
            using var document = JsonDocument.Parse(
                json,
                new JsonDocumentOptions
                {
                    AllowTrailingCommas = false,
                    CommentHandling = JsonCommentHandling.Disallow,
                    MaxDepth = 8,
                });

            var root = document.RootElement;
            EnsureObject(root, "settings");
            EnsureExactProperties(root, RootPropertyNames, "settings");

            var schemaVersion = ReadStrictInt32(root, "schemaVersion");
            var language = ParseLanguage(ReadString(root, "language"));
            var widgetVariant = ParseWidgetVariant(ReadString(root, "widgetVariant"));
            var widgetEnabled = ReadBoolean(root, "widgetEnabled");
            var widgetPinned = ReadBoolean(root, "widgetPinned");
            var preferencesElement = ReadProperty(root, "userPreferences");
            EnsureObject(preferencesElement, "userPreferences");
            EnsureExactProperties(preferencesElement, PreferencePropertyNames, "userPreferences");

            var selectedProjectId = ReadNullableString(preferencesElement, "selectedProjectId");
            var showOfflineAgents = ReadBoolean(preferencesElement, "showOfflineAgents");
            var reducedMotion = ReadBoolean(preferencesElement, "reducedMotion");
            var refreshIntervalSeconds = ReadStrictInt32(preferencesElement, "refreshIntervalSeconds");
            var localExportDirectory = ReadNullableString(root, "localExportDirectory");

            return AppSettingsContract.Admit(new AppSettings(
                schemaVersion,
                language,
                widgetVariant,
                widgetEnabled,
                widgetPinned,
                new AppUserPreferences
                {
                    SelectedProjectId = selectedProjectId,
                    ShowOfflineAgents = showOfflineAgents,
                    ReducedMotion = reducedMotion,
                    RefreshIntervalSeconds = refreshIntervalSeconds,
                },
                localExportDirectory));
        }
        catch (SettingsValidationException)
        {
            throw;
        }
        catch (JsonException exception)
        {
            throw new SettingsValidationException("The settings JSON is malformed.", exception);
        }
        catch (InvalidOperationException exception)
        {
            throw new SettingsValidationException("The settings JSON contains a malformed value.", exception);
        }
    }

    private static AppSettingsSnapshot CreateSnapshot(AppSettings settings, string canonicalJson) =>
        new(settings, canonicalJson, ComputeSha256(canonicalJson));

    private static string SerializeCanonical(AppSettings settings)
    {
        var document = new SettingsFileDocument(
            settings.SchemaVersion,
            ToLanguageValue(settings.Language),
            ToWidgetValue(settings.WidgetVariant),
            settings.WidgetEnabled,
            settings.WidgetPinned,
            new SettingsPreferencesDocument(
                settings.UserPreferences.SelectedProjectId,
                settings.UserPreferences.ShowOfflineAgents,
                settings.UserPreferences.ReducedMotion,
                settings.UserPreferences.RefreshIntervalSeconds),
            settings.LocalExportDirectory);
        return JsonSerializer.Serialize(document, SerializerOptions) + "\n";
    }

    private void EnsureDocumentBound(byte[] bytes)
    {
        if (bytes.Length > _maximumDocumentUtf8Bytes)
        {
            throw new SettingsValidationException(
                $"The settings document exceeds its {_maximumDocumentUtf8Bytes}-byte UTF-8 bound.");
        }
    }

    private static string DecodeStrictUtf8(byte[] bytes)
    {
        if (bytes.Length >= 3
            && bytes[0] == 0xEF
            && bytes[1] == 0xBB
            && bytes[2] == 0xBF)
        {
            throw new SettingsValidationException("The settings document must be UTF-8 without a BOM.");
        }

        try
        {
            return StrictUtf8.GetString(bytes);
        }
        catch (DecoderFallbackException exception)
        {
            throw new SettingsValidationException("The settings document is not valid UTF-8.", exception);
        }
    }

    private static void EnsureObject(JsonElement element, string name)
    {
        if (element.ValueKind != JsonValueKind.Object)
        {
            throw new SettingsValidationException($"{name} must be a JSON object.");
        }
    }

    private static void EnsureExactProperties(
        JsonElement element,
        HashSet<string> expected,
        string name)
    {
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var property in element.EnumerateObject())
        {
            if (!expected.Contains(property.Name) || !seen.Add(property.Name))
            {
                throw new SettingsValidationException(
                    $"{name} contains an unknown or duplicate property: {property.Name}.");
            }
        }

        if (seen.Count != expected.Count)
        {
            throw new SettingsValidationException($"{name} is missing a required property.");
        }
    }

    private static JsonElement ReadProperty(JsonElement element, string name)
    {
        if (!element.TryGetProperty(name, out var property))
        {
            throw new SettingsValidationException($"The required property '{name}' is missing.");
        }

        return property;
    }

    private static string ReadString(JsonElement element, string name)
    {
        var property = ReadProperty(element, name);
        if (property.ValueKind != JsonValueKind.String || property.GetString() is not { } value)
        {
            throw new SettingsValidationException($"The property '{name}' must be a string.");
        }

        return value;
    }

    private static string? ReadNullableString(JsonElement element, string name)
    {
        var property = ReadProperty(element, name);
        if (property.ValueKind == JsonValueKind.Null)
        {
            return null;
        }

        if (property.ValueKind != JsonValueKind.String || property.GetString() is not { } value)
        {
            throw new SettingsValidationException($"The property '{name}' must be a string or null.");
        }

        return value;
    }

    private static bool ReadBoolean(JsonElement element, string name)
    {
        var property = ReadProperty(element, name);
        if (property.ValueKind is not (JsonValueKind.True or JsonValueKind.False))
        {
            throw new SettingsValidationException($"The property '{name}' must be a JSON boolean.");
        }

        return property.GetBoolean();
    }

    private static int ReadStrictInt32(JsonElement element, string name)
    {
        var property = ReadProperty(element, name);
        if (property.ValueKind != JsonValueKind.Number
            || !property.GetRawText().All(character => character is >= '0' and <= '9')
            || !property.TryGetInt32(out var value))
        {
            throw new SettingsValidationException($"The property '{name}' must be an integer.");
        }

        return value;
    }

    private static AppSettingsLanguage ParseLanguage(string value) => value switch
    {
        "th" => AppSettingsLanguage.Thai,
        "en" => AppSettingsLanguage.English,
        _ => throw new SettingsValidationException("The settings language value is unsupported."),
    };

    private static AppSettingsWidgetVariant ParseWidgetVariant(string value) => value switch
    {
        "compact" => AppSettingsWidgetVariant.Compact,
        "normal" => AppSettingsWidgetVariant.Normal,
        "expanded" => AppSettingsWidgetVariant.Expanded,
        "floating-mini" => AppSettingsWidgetVariant.FloatingMini,
        "floating-vertical" => AppSettingsWidgetVariant.FloatingVertical,
        "notification" => AppSettingsWidgetVariant.Notification,
        "agent-detail-popup" => AppSettingsWidgetVariant.AgentDetailPopup,
        _ => throw new SettingsValidationException("The widget variant value is unsupported."),
    };

    private static string ToLanguageValue(AppSettingsLanguage language) => language switch
    {
        AppSettingsLanguage.Thai => "th",
        AppSettingsLanguage.English => "en",
        _ => throw new SettingsValidationException("The settings language value is unsupported."),
    };

    private static string ToWidgetValue(AppSettingsWidgetVariant variant) => variant switch
    {
        AppSettingsWidgetVariant.Compact => "compact",
        AppSettingsWidgetVariant.Normal => "normal",
        AppSettingsWidgetVariant.Expanded => "expanded",
        AppSettingsWidgetVariant.FloatingMini => "floating-mini",
        AppSettingsWidgetVariant.FloatingVertical => "floating-vertical",
        AppSettingsWidgetVariant.Notification => "notification",
        AppSettingsWidgetVariant.AgentDetailPopup => "agent-detail-popup",
        _ => throw new SettingsValidationException("The widget variant value is unsupported."),
    };

    private static string ComputeSha256(string value) =>
        Convert.ToHexString(SHA256.HashData(StrictUtf8.GetBytes(value)));

    private static Exception NormalizeCommitException(Exception exception) =>
        exception is IOException or UnauthorizedAccessException
            ? new SettingsValidationException(
                "The settings document was not atomically committed; the previous file was retained.",
                exception)
            : exception;

    private sealed record SettingsFileDocument(
        int SchemaVersion,
        string Language,
        string WidgetVariant,
        bool WidgetEnabled,
        bool WidgetPinned,
        SettingsPreferencesDocument UserPreferences,
        string? LocalExportDirectory);

    private sealed record SettingsPreferencesDocument(
        string? SelectedProjectId,
        bool ShowOfflineAgents,
        bool ReducedMotion,
        int RefreshIntervalSeconds);
}
