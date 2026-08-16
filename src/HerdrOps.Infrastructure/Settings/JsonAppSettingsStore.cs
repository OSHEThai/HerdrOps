using System.Collections.Concurrent;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Runtime.ExceptionServices;
using HerdrOps.Domain.Settings;

namespace HerdrOps.Infrastructure.Settings;

internal readonly record struct BoundedSettingsDocument(byte[] Buffer, int Length);

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

internal interface ISettingsArtifactPathFactory
{
    string CreateTemporaryPath(string destinationDirectory, string destinationFileName);

    string CreateBackupPath(string destinationDirectory, string destinationFileName);
}

internal sealed class GuidSettingsArtifactPathFactory : ISettingsArtifactPathFactory
{
    public string CreateTemporaryPath(string destinationDirectory, string destinationFileName) =>
        Path.Combine(destinationDirectory, $".{destinationFileName}.{Guid.NewGuid():N}.tmp");

    public string CreateBackupPath(string destinationDirectory, string destinationFileName) =>
        Path.Combine(destinationDirectory, $".{destinationFileName}.{Guid.NewGuid():N}.bak");
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

    private static readonly ConcurrentDictionary<string, SemaphoreSlim> DestinationLocks =
        new(OperatingSystem.IsWindows() ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal);

    private readonly string _destinationPath;
    private readonly string _destinationDirectory;
    private readonly ISettingsAtomicCommit _atomicCommit;
    private readonly ISettingsTemporaryFileCleanup _temporaryFileCleanup;
    private readonly ISettingsArtifactPathFactory _artifactPathFactory;
    private readonly int _maximumDocumentUtf8Bytes;

    public JsonAppSettingsStore(
        string destinationPath,
        string? allowedRootDirectory = null,
        ISettingsAtomicCommit? atomicCommit = null,
        int maximumDocumentUtf8Bytes = AppSettingsContract.MaximumDocumentUtf8Bytes,
        ISettingsTemporaryFileCleanup? temporaryFileCleanup = null)
        : this(
            destinationPath,
            allowedRootDirectory,
            atomicCommit,
            maximumDocumentUtf8Bytes,
            temporaryFileCleanup,
            new GuidSettingsArtifactPathFactory())
    {
    }

    internal JsonAppSettingsStore(
        string destinationPath,
        string? allowedRootDirectory,
        ISettingsAtomicCommit? atomicCommit,
        int maximumDocumentUtf8Bytes,
        ISettingsTemporaryFileCleanup? temporaryFileCleanup,
        ISettingsArtifactPathFactory artifactPathFactory)
    {
        if (maximumDocumentUtf8Bytes is <= 0 or > AppSettingsContract.MaximumDocumentUtf8Bytes)
        {
            throw new ArgumentOutOfRangeException(
                nameof(maximumDocumentUtf8Bytes),
                maximumDocumentUtf8Bytes,
                $"The document bound must be between 1 and {AppSettingsContract.MaximumDocumentUtf8Bytes} bytes.");
        }

        _destinationPath = NormalizeDestinationFile(destinationPath, allowedRootDirectory);
        _destinationDirectory = Path.GetDirectoryName(_destinationPath)
            ?? throw new SettingsValidationException("The settings file must have a destination directory.");
        _atomicCommit = atomicCommit ?? new FileSystemSettingsAtomicCommit();
        _temporaryFileCleanup = temporaryFileCleanup ?? new FileSystemSettingsTemporaryFileCleanup();
        _artifactPathFactory = artifactPathFactory ?? throw new ArgumentNullException(nameof(artifactPathFactory));
        _maximumDocumentUtf8Bytes = maximumDocumentUtf8Bytes;
    }

    public async Task<AppSettingsSnapshot?> LoadAsync(CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();

        BoundedSettingsDocument document;
        try
        {
            await using var stream = new FileStream(
                _destinationPath,
                FileMode.Open,
                FileAccess.Read,
                FileShare.ReadWrite | FileShare.Delete,
                bufferSize: 4096,
                options: FileOptions.SequentialScan | FileOptions.Asynchronous);
            document = await ReadBoundedDocumentAsync(
                stream,
                _maximumDocumentUtf8Bytes,
                cancellationToken).ConfigureAwait(false);
        }
        catch (Exception exception) when (exception is FileNotFoundException or DirectoryNotFoundException)
        {
            return null;
        }
        catch (SettingsValidationException)
        {
            throw;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            throw new SettingsValidationException("The settings document could not be read.", exception);
        }

        var json = DecodeStrictUtf8(document.Buffer.AsSpan(0, document.Length));
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
        var destinationLock = DestinationLocks.GetOrAdd(
            _destinationPath,
            static _ => new SemaphoreSlim(1, 1));
        await destinationLock.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await CommitSerializedAsync(bytes, cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            destinationLock.Release();
        }
    }

    private async Task CommitSerializedAsync(byte[] bytes, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        SettingsPathPolicy.RejectExistingReparsePointComponentsBestEffort(_destinationDirectory);
        Directory.CreateDirectory(_destinationDirectory);
        SettingsPathPolicy.RejectExistingReparsePointComponentsBestEffort(_destinationDirectory);
        SettingsPathPolicy.RejectExistingReparsePointComponentsBestEffort(_destinationPath);
        var destinationFileName = Path.GetFileName(_destinationPath);
        var temporaryPath = _artifactPathFactory.CreateTemporaryPath(
            _destinationDirectory,
            destinationFileName);
        var destinationExisted = File.Exists(_destinationPath);
        var backupPath = destinationExisted
            ? _artifactPathFactory.CreateBackupPath(_destinationDirectory, destinationFileName)
            : null;

        Exception? primaryException = null;
        var commitInvoked = false;
        var temporaryOwned = false;
        var backupOwned = false;
        try
        {
            if (backupPath is not null)
            {
                await using var source = new FileStream(
                    _destinationPath,
                    FileMode.Open,
                    FileAccess.Read,
                    FileShare.ReadWrite | FileShare.Delete,
                    bufferSize: 4096,
                    options: FileOptions.SequentialScan | FileOptions.Asynchronous);
                await using var backup = new FileStream(
                    backupPath,
                    FileMode.CreateNew,
                    FileAccess.Write,
                    FileShare.None,
                    bufferSize: 4096,
                    options: FileOptions.SequentialScan | FileOptions.Asynchronous);
                backupOwned = true;
                await source.CopyToAsync(backup, cancellationToken).ConfigureAwait(false);
                await backup.FlushAsync(cancellationToken).ConfigureAwait(false);
                backup.Flush(flushToDisk: true);
            }

            await using (var stream = new FileStream(
                temporaryPath,
                FileMode.CreateNew,
                FileAccess.Write,
                FileShare.None,
                bufferSize: 4096,
                options: FileOptions.SequentialScan))
            {
                temporaryOwned = true;
                await stream.WriteAsync(bytes, cancellationToken).ConfigureAwait(false);
                await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
                stream.Flush(flushToDisk: true);
            }

            cancellationToken.ThrowIfCancellationRequested();
            SettingsPathPolicy.RejectExistingReparsePointComponentsBestEffort(_destinationDirectory);
            SettingsPathPolicy.RejectExistingReparsePointComponentsBestEffort(_destinationPath);
            commitInvoked = true;
            _atomicCommit.Commit(temporaryPath, _destinationPath);
            cancellationToken.ThrowIfCancellationRequested();
        }
        catch (Exception exception)
        {
            primaryException = NormalizeCommitException(exception);
        }

        if (commitInvoked && primaryException is not null)
        {
            var rollbackException = TryRollback(
                destinationExisted,
                backupPath,
                bytes);
            if (rollbackException is not null)
            {
                primaryException = new SettingsValidationException(
                    "The settings commit failed after publication, and safe rollback did not complete.",
                    new AggregateException(primaryException, rollbackException));
            }
        }

        Exception? cleanupException = null;
        if (temporaryOwned)
        {
            try
            {
                _temporaryFileCleanup.Delete(temporaryPath);
            }
            catch (Exception exception)
            {
                cleanupException = exception;
            }
        }

        if (backupPath is not null && backupOwned)
        {
            try
            {
                _temporaryFileCleanup.Delete(backupPath);
            }
            catch (Exception exception)
            {
                cleanupException = cleanupException is null
                    ? exception
                    : new AggregateException(
                        "Multiple settings temporary-file cleanup operations failed.",
                        cleanupException,
                        exception);
            }
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
                "The settings document commit completed, but temporary-file cleanup failed.",
                cleanupException);
        }
    }

    internal static async Task<BoundedSettingsDocument> ReadBoundedDocumentAsync(
        Stream source,
        int maximumDocumentUtf8Bytes,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(source);
        if (maximumDocumentUtf8Bytes is <= 0 or > AppSettingsContract.MaximumDocumentUtf8Bytes)
        {
            throw new ArgumentOutOfRangeException(nameof(maximumDocumentUtf8Bytes));
        }

        cancellationToken.ThrowIfCancellationRequested();
        var buffer = new byte[maximumDocumentUtf8Bytes + 1];
        var length = 0;
        while (length < buffer.Length)
        {
            var read = await source.ReadAsync(
                buffer.AsMemory(length, buffer.Length - length),
                cancellationToken).ConfigureAwait(false);
            if (read == 0)
            {
                return new BoundedSettingsDocument(buffer, length);
            }

            length += read;
        }

        throw new SettingsValidationException(
            $"The settings document exceeds its {maximumDocumentUtf8Bytes}-byte UTF-8 bound.");
    }

    private Exception? TryRollback(
        bool destinationExisted,
        string? backupPath,
        ReadOnlySpan<byte> expectedCommittedBytes)
    {
        try
        {
            SettingsPathPolicy.RejectExistingReparsePointComponentsBestEffort(_destinationDirectory);
            SettingsPathPolicy.RejectExistingReparsePointComponentsBestEffort(_destinationPath);

            if (!destinationExisted)
            {
                if (!File.Exists(_destinationPath))
                {
                    return null;
                }

                if (!FileMatchesBytes(_destinationPath, expectedCommittedBytes))
                {
                    return new IOException(
                        "The destination changed after commit, so the newly committed file was not removed.");
                }

                File.Delete(_destinationPath);
                return File.Exists(_destinationPath)
                    ? new IOException("The newly committed settings file could not be removed during rollback.")
                    : null;
            }

            if (backupPath is null || !File.Exists(backupPath))
            {
                return new IOException("The previous settings file backup is unavailable for rollback.");
            }

            if (FileMatchesBytes(_destinationPath, expectedCommittedBytes))
            {
                if (File.Exists(_destinationPath))
                {
                    File.Replace(
                        backupPath,
                        _destinationPath,
                        destinationBackupFileName: null,
                        ignoreMetadataErrors: true);
                }
                else
                {
                    File.Move(backupPath, _destinationPath);
                }

                return null;
            }

            return FilesEqual(_destinationPath, backupPath)
                ? null
                : new IOException(
                    "The destination changed after commit, so the previous settings file was not restored.");
        }
        catch (Exception exception)
        {
            return exception;
        }
    }

    private static bool FileMatchesBytes(string path, ReadOnlySpan<byte> expected)
    {
        try
        {
            using var stream = new FileStream(
                path,
                FileMode.Open,
                FileAccess.Read,
                FileShare.ReadWrite | FileShare.Delete,
                bufferSize: 4096,
                options: FileOptions.SequentialScan);
            if (stream.Length != expected.Length)
            {
                return false;
            }

            var buffer = new byte[Math.Min(4096, Math.Max(1, expected.Length))];
            var offset = 0;
            while (offset < expected.Length)
            {
                var read = stream.Read(buffer, 0, Math.Min(buffer.Length, expected.Length - offset));
                if (read == 0 || !expected.Slice(offset, read).SequenceEqual(buffer.AsSpan(0, read)))
                {
                    return false;
                }

                offset += read;
            }

            return stream.ReadByte() == -1;
        }
        catch (Exception exception) when (exception is FileNotFoundException or DirectoryNotFoundException)
        {
            return false;
        }
    }

    private static bool FilesEqual(string leftPath, string rightPath)
    {
        try
        {
            using var left = new FileStream(
                leftPath,
                FileMode.Open,
                FileAccess.Read,
                FileShare.ReadWrite | FileShare.Delete,
                bufferSize: 4096,
                options: FileOptions.SequentialScan);
            using var right = new FileStream(
                rightPath,
                FileMode.Open,
                FileAccess.Read,
                FileShare.ReadWrite | FileShare.Delete,
                bufferSize: 4096,
                options: FileOptions.SequentialScan);
            if (left.Length != right.Length)
            {
                return false;
            }

            var leftBuffer = new byte[4096];
            var rightBuffer = new byte[4096];
            while (true)
            {
                var leftRead = left.Read(leftBuffer, 0, leftBuffer.Length);
                var rightRead = right.Read(rightBuffer, 0, rightBuffer.Length);
                if (leftRead != rightRead)
                {
                    return false;
                }

                if (leftRead == 0)
                {
                    return true;
                }

                if (!leftBuffer.AsSpan(0, leftRead).SequenceEqual(rightBuffer.AsSpan(0, rightRead)))
                {
                    return false;
                }
            }
        }
        catch (Exception exception) when (exception is FileNotFoundException or DirectoryNotFoundException)
        {
            return false;
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

    private static string DecodeStrictUtf8(ReadOnlySpan<byte> bytes)
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
