using System.Text;
using HerdrOps.Domain.Settings;
using HerdrOps.Infrastructure.Settings;

namespace HerdrOps.IntegrationTests;

[TestClass]
[DoNotParallelize]
public sealed class AppSettingsStoreTests
{
    private string _testDirectory = null!;
    private string _settingsPath = null!;

    [TestInitialize]
    public void SetUp()
    {
        _testDirectory = Path.Combine(
            Path.GetTempPath(),
            "HerdrOps-settings-tests",
            Guid.NewGuid().ToString("N"));
        _settingsPath = Path.Combine(_testDirectory, "appsettings.json");
    }

    [TestCleanup]
    public void TearDown()
    {
        if (Directory.Exists(_testDirectory))
        {
            Directory.Delete(_testDirectory, recursive: true);
        }
    }

    [TestMethod]
    public async Task RoundTripIsDeterministicAndContainsOneSelectedLanguage()
    {
        var store = CreateStore();
        var settings = AppSettings.Defaults with
        {
            Language = AppSettingsLanguage.English,
            WidgetVariant = AppSettingsWidgetVariant.FloatingVertical,
            WidgetPinned = true,
            UserPreferences = AppSettings.Defaults.UserPreferences with
            {
                SelectedProjectId = "MyAwesomeProject",
                ReducedMotion = true,
                RefreshIntervalSeconds = 10,
            },
            LocalExportDirectory = Path.Combine(_testDirectory, "exports"),
        };

        var first = await store.SaveAsync(settings);
        var loaded = await store.LoadAsync();
        var second = await store.SaveAsync(settings);

        Assert.IsNotNull(loaded);
        Assert.AreEqual(first.Settings, loaded!.Settings);
        Assert.AreEqual(first.CanonicalJson, loaded.CanonicalJson);
        Assert.AreEqual(first.Sha256, loaded.Sha256);
        Assert.AreEqual(first.CanonicalJson, second.CanonicalJson);
        Assert.AreEqual(first.Sha256, second.Sha256);

        var json = await File.ReadAllTextAsync(_settingsPath, Encoding.UTF8);
        StringAssert.Contains(json, "\"language\": \"en\"");
        Assert.IsFalse(json.Contains("Thai", StringComparison.Ordinal));
        Assert.IsFalse(json.Contains("English", StringComparison.Ordinal));
        Assert.IsFalse(json.Contains("password", StringComparison.OrdinalIgnoreCase));
        Assert.IsFalse(json.Contains("token", StringComparison.OrdinalIgnoreCase));
        Assert.IsFalse(json.Contains("apiKey", StringComparison.OrdinalIgnoreCase));
    }

    [TestMethod]
    public async Task RestoreReversesToAPreviouslyAdmittedSnapshot()
    {
        var store = CreateStore();
        var first = await store.SaveAsync(AppSettings.Defaults with
        {
            Language = AppSettingsLanguage.Thai,
            WidgetVariant = AppSettingsWidgetVariant.Compact,
            UserPreferences = AppSettings.Defaults.UserPreferences with { SelectedProjectId = "first" },
        });
        await store.SaveAsync(AppSettings.Defaults with
        {
            Language = AppSettingsLanguage.English,
            WidgetVariant = AppSettingsWidgetVariant.Expanded,
            UserPreferences = AppSettings.Defaults.UserPreferences with { SelectedProjectId = "second" },
        });

        var restored = await store.RestoreAsync(first);
        var loaded = await store.LoadAsync();

        Assert.AreEqual(first.Settings, restored.Settings);
        Assert.AreEqual(first.Settings, loaded!.Settings);
        Assert.AreEqual(first.CanonicalJson, loaded.CanonicalJson);
    }

    [TestMethod]
    public async Task LoadCanonicalizesValidNonCanonicalJsonAndRestoreWritesCanonicalBytes()
    {
        var store = CreateStore();
        var expected = await store.SaveAsync(AppSettings.Defaults);
        var nonCanonical = """
        {
          "localExportDirectory": null,
          "userPreferences": {
            "refreshIntervalSeconds": 5,
            "reducedMotion": false,
            "showOfflineAgents": true,
            "selectedProjectId": null
          },
          "widgetPinned": false,
          "widgetEnabled": true,
          "widgetVariant": "normal",
          "language": "th",
          "schemaVersion": 1
        }
        """;

        await File.WriteAllTextAsync(_settingsPath, nonCanonical, new UTF8Encoding(false));
        var loaded = await store.LoadAsync();

        Assert.IsNotNull(loaded);
        Assert.AreEqual(expected.Settings, loaded!.Settings);
        Assert.AreEqual(expected.CanonicalJson, loaded.CanonicalJson);
        Assert.AreEqual(expected.Sha256, loaded.Sha256);
        CollectionAssert.AreEqual(
            Encoding.UTF8.GetBytes(nonCanonical),
            await File.ReadAllBytesAsync(_settingsPath));

        await store.RestoreAsync(loaded);
        CollectionAssert.AreEqual(
            Encoding.UTF8.GetBytes(expected.CanonicalJson),
            await File.ReadAllBytesAsync(_settingsPath));
    }

    [TestMethod]
    public async Task TamperedSnapshotIsRejectedWithoutChangingLastValidFile()
    {
        var store = CreateStore();
        var admitted = await store.SaveAsync(AppSettings.Defaults);
        var tampered = admitted with
        {
            Settings = admitted.Settings with { Language = AppSettingsLanguage.English },
        };

        await Assert.ThrowsExactlyAsync<SettingsValidationException>(
            () => store.RestoreAsync(tampered));

        var loaded = await store.LoadAsync();
        Assert.AreEqual(admitted.Settings, loaded!.Settings);
    }

    [TestMethod]
    public async Task ResetDefaultsReplacesPreferencesWithExplicitDefaults()
    {
        var store = CreateStore();
        await store.SaveAsync(AppSettings.Defaults with
        {
            Language = AppSettingsLanguage.English,
            WidgetVariant = AppSettingsWidgetVariant.Notification,
            WidgetPinned = true,
            UserPreferences = new AppUserPreferences
            {
                SelectedProjectId = "changed",
                ShowOfflineAgents = false,
                ReducedMotion = true,
                RefreshIntervalSeconds = 30,
            },
            LocalExportDirectory = Path.Combine(_testDirectory, "exports"),
        });

        var reset = await store.ResetToDefaultsAsync();
        var loaded = await store.LoadAsync();

        Assert.AreEqual(AppSettings.Defaults, reset.Settings);
        Assert.AreEqual(AppSettings.Defaults, loaded!.Settings);
    }

    [TestMethod]
    public async Task MalformedOversizedAndUnsupportedDocumentsFailClosed()
    {
        var store = CreateStore();
        var admitted = await store.SaveAsync(AppSettings.Defaults);
        var originalBytes = await File.ReadAllBytesAsync(_settingsPath);
        var invalidDocuments = new[]
        {
            "{\"schemaVersion\":1",
            "{\"schemaVersion\":2,\"language\":\"th\",\"widgetVariant\":\"normal\",\"widgetEnabled\":true,\"widgetPinned\":false,\"userPreferences\":{\"selectedProjectId\":null,\"showOfflineAgents\":true,\"reducedMotion\":false,\"refreshIntervalSeconds\":5},\"localExportDirectory\":null}",
            "{\"schemaVersion\":1,\"language\":\"th\",\"widgetVariant\":\"unknown\",\"widgetEnabled\":true,\"widgetPinned\":false,\"userPreferences\":{\"selectedProjectId\":null,\"showOfflineAgents\":true,\"reducedMotion\":false,\"refreshIntervalSeconds\":5},\"localExportDirectory\":null}",
        };

        foreach (var invalidDocument in invalidDocuments)
        {
            await File.WriteAllTextAsync(_settingsPath, invalidDocument, new UTF8Encoding(false));
            await Assert.ThrowsExactlyAsync<SettingsValidationException>(() => store.LoadAsync());
            CollectionAssert.AreEqual(
                Encoding.UTF8.GetBytes(invalidDocument),
                await File.ReadAllBytesAsync(_settingsPath));
        }

        await File.WriteAllBytesAsync(
            _settingsPath,
            Encoding.UTF8.GetBytes(new string('x', AppSettingsContract.MaximumDocumentUtf8Bytes + 1)));
        await Assert.ThrowsExactlyAsync<SettingsValidationException>(() => store.LoadAsync());

        await File.WriteAllBytesAsync(_settingsPath, originalBytes);
        var loaded = await store.LoadAsync();
        Assert.AreEqual(admitted.Settings, loaded!.Settings);
    }

    [TestMethod]
    public async Task StrictParserRejectsInvalidUtf8BomDuplicateUnknownAndMissingProperties()
    {
        var store = CreateStore();
        var admitted = await store.SaveAsync(AppSettings.Defaults);
        var canonicalJson = admitted.CanonicalJson.Replace("\r\n", "\n", StringComparison.Ordinal);
        var canonicalBytes = Encoding.UTF8.GetBytes(canonicalJson);
        var bomBytes = new byte[canonicalBytes.Length + 3];
        bomBytes[0] = 0xEF;
        bomBytes[1] = 0xBB;
        bomBytes[2] = 0xBF;
        Buffer.BlockCopy(canonicalBytes, 0, bomBytes, 3, canonicalBytes.Length);

        var invalidDocuments = new (string Name, byte[] Bytes)[]
        {
            ("invalid UTF-8", [0xC3, 0x28]),
            ("BOM", bomBytes),
            (
                "duplicate property",
                Encoding.UTF8.GetBytes(canonicalJson.Replace(
                    "  \"language\": \"th\",\n",
                    "  \"schemaVersion\": 1,\n  \"language\": \"th\",\n",
                    StringComparison.Ordinal))),
            (
                "unknown property",
                Encoding.UTF8.GetBytes(canonicalJson.Replace(
                    "{\n",
                    "{\n  \"unknown\": true,\n",
                    StringComparison.Ordinal))),
            (
                "missing property",
                Encoding.UTF8.GetBytes(canonicalJson.Replace(
                    "  \"localExportDirectory\": null\n",
                    string.Empty,
                    StringComparison.Ordinal))),
        };

        foreach (var invalidDocument in invalidDocuments)
        {
            await File.WriteAllBytesAsync(_settingsPath, invalidDocument.Bytes);
            var rejected = false;
            try
            {
                await store.LoadAsync();
            }
            catch (SettingsValidationException)
            {
                rejected = true;
            }

            Assert.IsTrue(rejected, $"The parser accepted {invalidDocument.Name}.");
            CollectionAssert.AreEqual(invalidDocument.Bytes, await File.ReadAllBytesAsync(_settingsPath));
        }
    }

    [TestMethod]
    public async Task FailedAtomicCommitCleansTemporaryFileAndRetainsPreviousFile()
    {
        var firstStore = CreateStore();
        var admitted = await firstStore.SaveAsync(AppSettings.Defaults);
        var previousBytes = await File.ReadAllBytesAsync(_settingsPath);
        var failingCommit = new FailingAtomicCommit();
        var failingStore = CreateStore(failingCommit);

        await Assert.ThrowsExactlyAsync<SettingsValidationException>(() =>
            failingStore.SaveAsync(AppSettings.Defaults with
            {
                Language = AppSettingsLanguage.English,
                WidgetVariant = AppSettingsWidgetVariant.Compact,
            }));

        CollectionAssert.AreEqual(previousBytes, await File.ReadAllBytesAsync(_settingsPath));
        Assert.IsNotNull(failingCommit.TemporaryPath);
        Assert.IsFalse(File.Exists(failingCommit.TemporaryPath));
        var loaded = await firstStore.LoadAsync();
        Assert.AreEqual(admitted.Settings, loaded!.Settings);
    }

    [TestMethod]
    public async Task CleanupFailureIsSurfacedAlongsidePrimaryCommitFailure()
    {
        var failingCommit = new FailingAtomicCommit();
        var failingCleanup = new FailingTemporaryFileCleanup();
        var store = CreateStore(failingCommit, failingCleanup);

        var exception = await Assert.ThrowsExactlyAsync<AggregateException>(() =>
            store.SaveAsync(AppSettings.Defaults with { Language = AppSettingsLanguage.English }));

        Assert.HasCount(2, exception.InnerExceptions);
        Assert.IsInstanceOfType<SettingsValidationException>(exception.InnerExceptions[0]);
        Assert.IsInstanceOfType<IOException>(exception.InnerExceptions[1]);
        Assert.IsNotNull(failingCommit.TemporaryPath);
        Assert.IsTrue(File.Exists(failingCommit.TemporaryPath));
    }

    [TestMethod]
    public async Task CleanupFailureAfterCommitIsNotSilentlyIgnored()
    {
        var failingCleanup = new FailingTemporaryFileCleanup();
        var store = CreateStore(temporaryFileCleanup: failingCleanup);

        var exception = await Assert.ThrowsExactlyAsync<SettingsValidationException>(() =>
            store.SaveAsync(AppSettings.Defaults));

        StringAssert.Contains(exception.Message, "cleanup failed");
        Assert.IsInstanceOfType<IOException>(exception.InnerException);
        var loaded = await CreateStore().LoadAsync();
        Assert.AreEqual(AppSettings.Defaults, loaded!.Settings);
    }

    [TestMethod]
    public void DestinationPolicyRejectsRelativeRootTraversalAndUncPaths()
    {
        Assert.ThrowsExactly<SettingsValidationException>(() =>
            new JsonAppSettingsStore(Path.Combine("relative", "settings.json")));
        Assert.ThrowsExactly<SettingsValidationException>(() =>
            new JsonAppSettingsStore(Path.GetPathRoot(Environment.SystemDirectory)!));
        Assert.ThrowsExactly<SettingsValidationException>(() =>
            new JsonAppSettingsStore(Path.Combine(_testDirectory, "..", "settings.json")));
        Assert.ThrowsExactly<SettingsValidationException>(() =>
            new JsonAppSettingsStore(@"\\server\share\settings.json"));

        var outside = Path.Combine(Path.GetTempPath(), "outside-settings.json");
        Assert.ThrowsExactly<SettingsValidationException>(() =>
            new JsonAppSettingsStore(
                Path.Combine(_testDirectory, "settings.json"),
                allowedRootDirectory: outside));

        var valid = new JsonAppSettingsStore(
            _settingsPath,
            allowedRootDirectory: Path.GetTempPath().TrimEnd(Path.DirectorySeparatorChar));
        Assert.IsNotNull(valid);
    }

    [TestMethod]
    public async Task DestinationPolicyAcceptsFileDirectlyInsideAllowedRoot()
    {
        Directory.CreateDirectory(_testDirectory);
        var store = new JsonAppSettingsStore(_settingsPath, allowedRootDirectory: _testDirectory);

        var saved = await store.SaveAsync(AppSettings.Defaults);

        Assert.AreEqual(AppSettings.Defaults, saved.Settings);
        Assert.IsTrue(File.Exists(_settingsPath));
    }

    [TestMethod]
    public void DestinationPolicyRejectsEmptyReservedAdsInvalidAndDevicePaths()
    {
        var invalidPaths = new[]
        {
            _testDirectory + Path.DirectorySeparatorChar,
            Path.Combine(_testDirectory, "."),
            Path.Combine(_testDirectory, "CON.json"),
            Path.Combine(_testDirectory, "COM1.txt"),
            Path.Combine(_testDirectory, "bad:stream.json"),
            Path.Combine(_testDirectory, "bad?.json"),
            Path.Combine(_testDirectory, "bad\u0001.json"),
            "C:settings.json",
            @"\\?\C:\settings.json",
            @"\\.\C:\settings.json",
            @"\??\C:\settings.json",
            @"\Device\HarddiskVolume1\settings.json",
        };

        foreach (var invalidPath in invalidPaths)
        {
            Assert.ThrowsExactly<SettingsValidationException>(() => new JsonAppSettingsStore(invalidPath));
        }
    }

    [TestMethod]
    public async Task CancellationIsCheckedBeforeValidationAndSnapshotValidation()
    {
        var store = CreateStore();
        Directory.CreateDirectory(_testDirectory);
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();

        await Assert.ThrowsExactlyAsync<OperationCanceledException>(() =>
            store.SaveAsync(AppSettings.Defaults with { SchemaVersion = 99 }, cancellation.Token));

        await File.WriteAllTextAsync(_settingsPath, "{", new UTF8Encoding(false));
        await Assert.ThrowsExactlyAsync<OperationCanceledException>(() =>
            store.LoadAsync(cancellation.Token));

        var invalidSnapshot = new AppSettingsSnapshot(
            AppSettings.Defaults with { SchemaVersion = 99 },
            "not-canonical",
            "not-a-hash");
        await Assert.ThrowsExactlyAsync<OperationCanceledException>(() =>
            store.RestoreAsync(invalidSnapshot, cancellation.Token));
    }

    [TestMethod]
    public void ExistingReparsePointComponentsAreRejectedWhenSupported()
    {
        if (!OperatingSystem.IsWindows())
        {
            Assert.Inconclusive("The release target is Windows.");
        }

        Directory.CreateDirectory(_testDirectory);
        var outside = Directory.CreateDirectory(Path.Combine(
            Path.GetTempPath(),
            "HerdrOps-settings-reparse-target-" + Guid.NewGuid().ToString("N")));
        var linkPath = Path.Combine(_testDirectory, "reparse-link");
        try
        {
            _ = Directory.CreateSymbolicLink(linkPath, outside.FullName);
        }
        catch (Exception exception) when (exception is UnauthorizedAccessException or IOException or PlatformNotSupportedException)
        {
            Directory.Delete(outside.FullName, recursive: true);
            Assert.Inconclusive($"Symbolic-link creation is unavailable on this Windows host: {exception.GetType().Name}");
        }

        try
        {
            Assert.ThrowsExactly<SettingsValidationException>(() =>
                new JsonAppSettingsStore(
                    Path.Combine(linkPath, "appsettings.json"),
                    allowedRootDirectory: _testDirectory));

            Assert.ThrowsExactly<SettingsValidationException>(() =>
                new JsonAppSettingsStore(
                    _settingsPath,
                    allowedRootDirectory: linkPath));
        }
        finally
        {
            try
            {
                Directory.Delete(linkPath);
            }
            catch (DirectoryNotFoundException)
            {
            }

            if (Directory.Exists(linkPath))
            {
                File.Delete(linkPath);
            }

            Directory.Delete(outside.FullName, recursive: true);
        }
    }

    [TestMethod]
    public async Task BoundedTextAndInvalidValuesAreRejectedBeforeReplacement()
    {
        var store = CreateStore();
        var admitted = await store.SaveAsync(AppSettings.Defaults);
        var previousBytes = await File.ReadAllBytesAsync(_settingsPath);
        var invalidSettings = new[]
        {
            AppSettings.Defaults with { SchemaVersion = 99 },
            AppSettings.Defaults with { Language = (AppSettingsLanguage)99 },
            AppSettings.Defaults with { WidgetVariant = (AppSettingsWidgetVariant)99 },
            AppSettings.Defaults with
            {
                UserPreferences = AppSettings.Defaults.UserPreferences with
                {
                    SelectedProjectId = new string('ก', 200),
                },
            },
            AppSettings.Defaults with
            {
                UserPreferences = AppSettings.Defaults.UserPreferences with { RefreshIntervalSeconds = 0 },
            },
            AppSettings.Defaults with { LocalExportDirectory = "relative-export" },
        };

        foreach (var invalid in invalidSettings)
        {
            await Assert.ThrowsExactlyAsync<SettingsValidationException>(() => store.SaveAsync(invalid));
            CollectionAssert.AreEqual(previousBytes, await File.ReadAllBytesAsync(_settingsPath));
        }

        var loaded = await store.LoadAsync();
        Assert.AreEqual(admitted.Settings, loaded!.Settings);
    }

    private JsonAppSettingsStore CreateStore(
        ISettingsAtomicCommit? atomicCommit = null,
        ISettingsTemporaryFileCleanup? temporaryFileCleanup = null) =>
        new(
            _settingsPath,
            allowedRootDirectory: Path.GetTempPath().TrimEnd(Path.DirectorySeparatorChar),
            atomicCommit,
            temporaryFileCleanup: temporaryFileCleanup);

    private sealed class FailingAtomicCommit : ISettingsAtomicCommit
    {
        public string? TemporaryPath { get; private set; }

        public void Commit(string temporaryPath, string destinationPath)
        {
            TemporaryPath = temporaryPath;
            throw new IOException("Synthetic atomic commit failure.");
        }
    }

    private sealed class FailingTemporaryFileCleanup : ISettingsTemporaryFileCleanup
    {
        public void Delete(string temporaryPath)
        {
            throw new IOException("Synthetic temporary-file cleanup failure.");
        }
    }
}
