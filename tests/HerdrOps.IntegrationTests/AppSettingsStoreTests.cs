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
    public void ConstructorDoesNotPermitDocumentBoundAboveContractMaximum()
    {
        Assert.ThrowsExactly<ArgumentOutOfRangeException>(() =>
            new JsonAppSettingsStore(
                _settingsPath,
                maximumDocumentUtf8Bytes: AppSettingsContract.MaximumDocumentUtf8Bytes + 1));

        var smallBoundStore = new JsonAppSettingsStore(
            _settingsPath,
            maximumDocumentUtf8Bytes: 1024);
        Assert.IsNotNull(smallBoundStore);
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
    public async Task CancellationAfterAtomicCommitRestoresPreviousFileBeforeThrowing()
    {
        var initialStore = CreateStore();
        await initialStore.SaveAsync(AppSettings.Defaults);
        var previousBytes = await File.ReadAllBytesAsync(_settingsPath);
        using var cancellation = new CancellationTokenSource();
        var cancellingCommit = new CancellingAtomicCommit(cancellation);
        var store = CreateStore(cancellingCommit);

        await Assert.ThrowsExactlyAsync<OperationCanceledException>(() =>
            store.SaveAsync(
                AppSettings.Defaults with { Language = AppSettingsLanguage.English },
                cancellation.Token));

        CollectionAssert.AreEqual(previousBytes, await File.ReadAllBytesAsync(_settingsPath));
        Assert.AreEqual(1, cancellingCommit.CommitCount);
        Assert.IsFalse(Directory.EnumerateFiles(_testDirectory, "*.tmp").Any());
        Assert.IsFalse(Directory.EnumerateFiles(_testDirectory, "*.bak").Any());
    }

    [TestMethod]
    public async Task CancellationAfterAtomicCommitWithNoPreviousFileRemovesPublishedFileBeforeThrowing()
    {
        using var cancellation = new CancellationTokenSource();
        var cancellingCommit = new CancellingAtomicCommit(cancellation);
        var store = CreateStore(cancellingCommit);

        await Assert.ThrowsExactlyAsync<OperationCanceledException>(() =>
            store.SaveAsync(
                AppSettings.Defaults with { Language = AppSettingsLanguage.English },
                cancellation.Token));

        Assert.IsFalse(File.Exists(_settingsPath));
        Assert.AreEqual(1, cancellingCommit.CommitCount);
        Assert.IsFalse(Directory.EnumerateFiles(_testDirectory, "*.tmp").Any());
        Assert.IsFalse(Directory.EnumerateFiles(_testDirectory, "*.bak").Any());
    }

    [TestMethod]
    public async Task PostPublicationExceptionRollsBackPreviousFileBeforeFailureEscapes()
    {
        var initialStore = CreateStore();
        await initialStore.SaveAsync(AppSettings.Defaults);
        var previousBytes = await File.ReadAllBytesAsync(_settingsPath);
        var throwingCommit = new PublishThenThrowAtomicCommit();
        var store = CreateStore(throwingCommit);

        await Assert.ThrowsExactlyAsync<SettingsValidationException>(() =>
            store.SaveAsync(AppSettings.Defaults with
            {
                Language = AppSettingsLanguage.English,
                WidgetVariant = AppSettingsWidgetVariant.Compact,
            }));

        Assert.IsTrue(throwingCommit.Published);
        CollectionAssert.AreEqual(previousBytes, await File.ReadAllBytesAsync(_settingsPath));
        Assert.IsFalse(Directory.EnumerateFiles(_testDirectory, "*.tmp").Any());
        Assert.IsFalse(Directory.EnumerateFiles(_testDirectory, "*.bak").Any());
    }

    [TestMethod]
    public async Task ConcurrentSaveWaitsForFailedRollbackAndCannotOverwriteSuccessfulSave()
    {
        var initialStore = CreateStore();
        await initialStore.SaveAsync(AppSettings.Defaults);
        var commit = new BlockingPublishThenThrowAtomicCommit();
        var firstStore = CreateStore(commit);
        var secondStore = CreateStore(commit);

        var firstTask = Task.Run(() => firstStore.SaveAsync(AppSettings.Defaults with
        {
            Language = AppSettingsLanguage.English,
            WidgetVariant = AppSettingsWidgetVariant.Compact,
        }));
        Assert.IsTrue(commit.FirstPublished.Wait(TimeSpan.FromSeconds(5)));

        var secondTask = Task.Run(() => secondStore.SaveAsync(AppSettings.Defaults with
        {
            Language = AppSettingsLanguage.Thai,
            WidgetVariant = AppSettingsWidgetVariant.Expanded,
        }));
        await Task.Delay(TimeSpan.FromMilliseconds(100));
        Assert.IsFalse(secondTask.IsCompleted, "The second save must wait for the first rollback.");

        commit.ReleaseFirstFailure.Set();
        try
        {
            await Assert.ThrowsExactlyAsync<SettingsValidationException>(async () => await firstTask);
        }
        finally
        {
            commit.ReleaseFirstFailure.Set();
        }

        var second = await secondTask;
        var loaded = await CreateStore().LoadAsync();

        Assert.AreEqual(AppSettingsLanguage.Thai, second.Settings.Language);
        Assert.AreEqual(AppSettingsWidgetVariant.Expanded, loaded!.Settings.WidgetVariant);
        Assert.AreEqual(AppSettingsLanguage.Thai, loaded.Settings.Language);
        Assert.IsFalse(Directory.EnumerateFiles(_testDirectory, "*.tmp").Any());
        Assert.IsFalse(Directory.EnumerateFiles(_testDirectory, "*.bak").Any());
    }

    [TestMethod]
    public async Task TemporaryArtifactCollisionDoesNotDeletePreExistingFile()
    {
        Directory.CreateDirectory(_testDirectory);
        var temporaryPath = Path.Combine(_testDirectory, "fixed.tmp");
        var sentinel = Encoding.UTF8.GetBytes("pre-existing temporary artifact");
        await File.WriteAllBytesAsync(temporaryPath, sentinel);
        var store = CreateStore(
            artifactPathFactory: new FixedArtifactPathFactory(
                temporaryPath,
                Path.Combine(_testDirectory, "fixed.bak")));

        await Assert.ThrowsExactlyAsync<SettingsValidationException>(() =>
            store.SaveAsync(AppSettings.Defaults));

        CollectionAssert.AreEqual(sentinel, await File.ReadAllBytesAsync(temporaryPath));
        Assert.IsFalse(File.Exists(_settingsPath));
    }

    [TestMethod]
    public async Task BackupArtifactCollisionDoesNotDeletePreExistingFile()
    {
        var initialStore = CreateStore();
        await initialStore.SaveAsync(AppSettings.Defaults);
        var previousBytes = await File.ReadAllBytesAsync(_settingsPath);
        Directory.CreateDirectory(_testDirectory);
        var backupPath = Path.Combine(_testDirectory, "fixed.bak");
        var sentinel = Encoding.UTF8.GetBytes("pre-existing backup artifact");
        await File.WriteAllBytesAsync(backupPath, sentinel);
        var store = CreateStore(
            artifactPathFactory: new FixedArtifactPathFactory(
                Path.Combine(_testDirectory, "fixed.tmp"),
                backupPath));

        await Assert.ThrowsExactlyAsync<SettingsValidationException>(() =>
            store.SaveAsync(AppSettings.Defaults with { Language = AppSettingsLanguage.English }));

        CollectionAssert.AreEqual(previousBytes, await File.ReadAllBytesAsync(_settingsPath));
        CollectionAssert.AreEqual(sentinel, await File.ReadAllBytesAsync(backupPath));
        Assert.IsFalse(File.Exists(Path.Combine(_testDirectory, "fixed.tmp")));
    }

    [TestMethod]
    public async Task CleanupFailureAfterRollbackIsVisibleAndRollbackPrecedesCleanup()
    {
        var initialStore = CreateStore();
        await initialStore.SaveAsync(AppSettings.Defaults);
        var previousBytes = await File.ReadAllBytesAsync(_settingsPath);
        var cleanup = new ObserveRollbackThenFailBackupCleanup(_settingsPath, previousBytes);
        var store = CreateStore(new PublishThenThrowAtomicCommit(), cleanup);

        var exception = await Assert.ThrowsExactlyAsync<AggregateException>(() =>
            store.SaveAsync(AppSettings.Defaults with { Language = AppSettingsLanguage.English }));

        Assert.HasCount(2, exception.InnerExceptions);
        Assert.IsTrue(cleanup.SawBackupArtifact);
        Assert.IsTrue(cleanup.DestinationWasRestoredBeforeBackupCleanup);
        CollectionAssert.AreEqual(previousBytes, await File.ReadAllBytesAsync(_settingsPath));
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

    [TestMethod]
    public async Task BoundedReaderRejectsConcurrentGrowthAfterReadingOnlyMaximumPlusOne()
    {
        var source = new GrowingChunkStream(
        [
            Encoding.UTF8.GetBytes("12345678"),
            Encoding.UTF8.GetBytes("9"),
            Encoding.UTF8.GetBytes("more bytes that must not be read"),
        ]);

        await Assert.ThrowsExactlyAsync<SettingsValidationException>(() =>
            JsonAppSettingsStore.ReadBoundedDocumentAsync(source, maximumDocumentUtf8Bytes: 8));

        Assert.AreEqual(9, source.BytesReturned);
    }

    private JsonAppSettingsStore CreateStore(
        ISettingsAtomicCommit? atomicCommit = null,
        ISettingsTemporaryFileCleanup? temporaryFileCleanup = null,
        ISettingsArtifactPathFactory? artifactPathFactory = null) =>
        artifactPathFactory is null
            ? new(
                _settingsPath,
                allowedRootDirectory: Path.GetTempPath().TrimEnd(Path.DirectorySeparatorChar),
                atomicCommit,
                temporaryFileCleanup: temporaryFileCleanup)
            : new JsonAppSettingsStore(
                _settingsPath,
                allowedRootDirectory: Path.GetTempPath().TrimEnd(Path.DirectorySeparatorChar),
                atomicCommit,
                AppSettingsContract.MaximumDocumentUtf8Bytes,
                temporaryFileCleanup,
                artifactPathFactory);

    private sealed class FailingAtomicCommit : ISettingsAtomicCommit
    {
        public string? TemporaryPath { get; private set; }

        public void Commit(string temporaryPath, string destinationPath)
        {
            TemporaryPath = temporaryPath;
            throw new IOException("Synthetic atomic commit failure.");
        }
    }

    private sealed class CancellingAtomicCommit : ISettingsAtomicCommit
    {
        private readonly CancellationTokenSource _cancellation;

        public CancellingAtomicCommit(CancellationTokenSource cancellation)
        {
            _cancellation = cancellation;
        }

        public int CommitCount { get; private set; }

        public void Commit(string temporaryPath, string destinationPath)
        {
            CommitCount++;
            new FileSystemSettingsAtomicCommit().Commit(temporaryPath, destinationPath);
            _cancellation.Cancel();
        }
    }

    private sealed class PublishThenThrowAtomicCommit : ISettingsAtomicCommit
    {
        public bool Published { get; private set; }

        public void Commit(string temporaryPath, string destinationPath)
        {
            new FileSystemSettingsAtomicCommit().Commit(temporaryPath, destinationPath);
            Published = true;
            throw new IOException("Synthetic post-publication failure.");
        }
    }

    private sealed class BlockingPublishThenThrowAtomicCommit : ISettingsAtomicCommit
    {
        private int _commitCount;

        public ManualResetEventSlim FirstPublished { get; } = new();

        public ManualResetEventSlim ReleaseFirstFailure { get; } = new();

        public void Commit(string temporaryPath, string destinationPath)
        {
            var commitNumber = Interlocked.Increment(ref _commitCount);
            new FileSystemSettingsAtomicCommit().Commit(temporaryPath, destinationPath);
            if (commitNumber == 1)
            {
                FirstPublished.Set();
                ReleaseFirstFailure.Wait(TimeSpan.FromSeconds(5));
                throw new IOException("Synthetic concurrent post-publication failure.");
            }
        }
    }

    private sealed class FixedArtifactPathFactory : ISettingsArtifactPathFactory
    {
        private readonly string _temporaryPath;
        private readonly string _backupPath;

        public FixedArtifactPathFactory(string temporaryPath, string backupPath)
        {
            _temporaryPath = temporaryPath;
            _backupPath = backupPath;
        }

        public string CreateTemporaryPath(string destinationDirectory, string destinationFileName) => _temporaryPath;

        public string CreateBackupPath(string destinationDirectory, string destinationFileName) => _backupPath;
    }

    private sealed class ObserveRollbackThenFailBackupCleanup : ISettingsTemporaryFileCleanup
    {
        private readonly string _destinationPath;
        private readonly byte[] _previousBytes;

        public ObserveRollbackThenFailBackupCleanup(string destinationPath, byte[] previousBytes)
        {
            _destinationPath = destinationPath;
            _previousBytes = previousBytes;
        }

        public bool SawBackupArtifact { get; private set; }

        public bool DestinationWasRestoredBeforeBackupCleanup { get; private set; }

        public void Delete(string temporaryPath)
        {
            if (temporaryPath.EndsWith(".bak", StringComparison.OrdinalIgnoreCase))
            {
                SawBackupArtifact = true;
                DestinationWasRestoredBeforeBackupCleanup =
                    File.Exists(_destinationPath)
                    && _previousBytes.AsSpan().SequenceEqual(File.ReadAllBytes(_destinationPath));
                throw new UnauthorizedAccessException("Synthetic inaccessible backup cleanup.");
            }

            File.Delete(temporaryPath);
        }
    }

    private sealed class FailingTemporaryFileCleanup : ISettingsTemporaryFileCleanup
    {
        public void Delete(string temporaryPath)
        {
            throw new IOException("Synthetic temporary-file cleanup failure.");
        }
    }

    private sealed class GrowingChunkStream : Stream
    {
        private readonly byte[][] _chunks;
        private int _chunkIndex;
        private int _chunkOffset;

        public GrowingChunkStream(byte[][] chunks)
        {
            _chunks = chunks;
        }

        public int BytesReturned { get; private set; }

        public override bool CanRead => true;

        public override bool CanSeek => false;

        public override bool CanWrite => false;

        public override long Length => throw new NotSupportedException();

        public override long Position
        {
            get => throw new NotSupportedException();
            set => throw new NotSupportedException();
        }

        public override void Flush() => throw new NotSupportedException();

        public override int Read(byte[] buffer, int offset, int count) =>
            Read(buffer.AsSpan(offset, count));

        public override int Read(Span<byte> buffer)
        {
            if (buffer.Length == 0)
            {
                return 0;
            }

            while (_chunkIndex < _chunks.Length && _chunkOffset == _chunks[_chunkIndex].Length)
            {
                _chunkIndex++;
                _chunkOffset = 0;
            }

            if (_chunkIndex == _chunks.Length)
            {
                return 0;
            }

            var chunk = _chunks[_chunkIndex];
            var count = Math.Min(buffer.Length, chunk.Length - _chunkOffset);
            chunk.AsSpan(_chunkOffset, count).CopyTo(buffer);
            _chunkOffset += count;
            BytesReturned += count;
            return count;
        }

        public override ValueTask<int> ReadAsync(
            Memory<byte> buffer,
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            return ValueTask.FromResult(Read(buffer.Span));
        }

        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();

        public override void SetLength(long value) => throw new NotSupportedException();

        public override void Write(byte[] buffer, int offset, int count) =>
            throw new NotSupportedException();
    }
}
