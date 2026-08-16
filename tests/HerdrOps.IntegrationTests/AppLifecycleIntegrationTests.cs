using HerdrOps.App.Lifecycle;
using HerdrOps.Domain.Lifecycle;
using HerdrOps.Domain.Settings;

namespace HerdrOps.IntegrationTests;

[TestClass]
public sealed class AppLifecycleIntegrationTests
{
    [TestMethod]
    public async Task LifecycleLoadsAppliesAndReversesSettingsWithInjectedSeams()
    {
        var initial = AppSettings.Defaults with
        {
            Language = AppSettingsLanguage.English,
            WidgetVariant = AppSettingsWidgetVariant.FloatingVertical,
            WidgetEnabled = true,
        };
        var store = new InMemoryAppSettingsStore(initial);
        var startupBackend = new InMemoryStartupBackend();
        var applied = new List<AppSettings>();
        var lifecycle = new AppLifecycleController(
            store,
            new StartAtLogonService(startupBackend, @"C:\HerdrOps\HerdrOps.App.exe"),
            settings => applied.Add(settings));

        await lifecycle.InitializeAsync();

        Assert.IsTrue(lifecycle.IsInitialized);
        Assert.AreEqual(initial, lifecycle.Settings);
        Assert.AreEqual(AppSettingsLanguage.English, applied[^1].Language);
        Assert.AreEqual(AppSettingsWidgetVariant.FloatingVertical, applied[^1].WidgetVariant);
        Assert.AreEqual(StartupRegistrationState.Disabled, lifecycle.StartAtLogonStatus.State);

        var original = lifecycle.Snapshot;
        lifecycle.SelectLanguage(AppSettingsLanguage.Thai);
        lifecycle.SelectWidget(AppSettingsWidgetVariant.Compact);

        Assert.AreEqual(AppSettingsLanguage.Thai, lifecycle.Settings.Language);
        Assert.AreEqual(AppSettingsWidgetVariant.Compact, lifecycle.Settings.WidgetVariant);
        Assert.IsGreaterThan(1, store.SaveCount);

        lifecycle.RestoreSettings(original);

        Assert.AreEqual(initial, lifecycle.Settings);
        Assert.AreEqual(initial, applied[^1]);
        Assert.AreEqual(StartupRegistrationState.Disabled, lifecycle.StartAtLogonStatus.State);

        lifecycle.ToggleStartAtLogon();
        Assert.AreEqual(StartupRegistrationState.Enabled, lifecycle.StartAtLogonStatus.State);
        Assert.AreEqual(
            @"""C:\HerdrOps\HerdrOps.App.exe""",
            startupBackend.Values[StartupRegistrationContract.ValueName]);

        lifecycle.ToggleStartAtLogon();
        Assert.AreEqual(StartupRegistrationState.Disabled, lifecycle.StartAtLogonStatus.State);
        Assert.IsFalse(startupBackend.Values.ContainsKey(StartupRegistrationContract.ValueName));
    }

    [TestMethod]
    public void TrayMenuExposesAOneLanguageStartAtLogonRouteWhenTheHostOwnsIt()
    {
        var status = new StartupRegistrationStatus(
            StartupRegistrationState.Disabled,
            StartupRegistrationContract.ValueName,
            @"""C:\HerdrOps\HerdrOps.App.exe""",
            null);
        var menu = new TrayMenuBuilder(
            () => AppSettings.Defaults,
            startupStatusProvider: () => status).Build();

        Assert.HasCount(1, menu.Items.Where(item => item.Command == TrayCommand.ToggleStartAtLogon));
        Assert.AreEqual(
            "เริ่ม HerdrOps พร้อม Windows",
            menu.Items.Single(item => item.Command == TrayCommand.ToggleStartAtLogon).Label);
        Assert.AreEqual(
            1,
            menu.Items.Count(item =>
                (item.Command is TrayCommand.SelectThaiLanguage or TrayCommand.SelectEnglishLanguage) &&
                item.IsChecked));
    }

    [TestMethod]
    public void TrayIconContractRemovesScreenshotMatteAndScalesForDpi()
    {
        Assert.AreEqual(16, TrayIconContract.PixelSizeForDpi(1.0));
        Assert.AreEqual(20, TrayIconContract.PixelSizeForDpi(1.25));
        Assert.AreEqual(32, TrayIconContract.PixelSizeForDpi(2.0));
        Assert.AreEqual(64, TrayIconContract.PixelSizeForDpi(8.0));
        Assert.ThrowsExactly<ArgumentOutOfRangeException>(() => TrayIconContract.PixelSizeForDpi(0));

        var pixels = new byte[]
        {
            24, 11, 0, 255,
            235, 129, 12, 255,
        };

        var converted = TrayIconContract.ToTransparentPbgra32(pixels, width: 2, height: 1);

        Assert.AreEqual(0, converted[3]);
        Assert.AreEqual(255, converted[7]);
        Assert.AreEqual(235, converted[4]);
        Assert.AreEqual(129, converted[5]);
        Assert.AreEqual(12, converted[6]);
    }

    [TestMethod]
    public void ShutdownCleanupAttemptsEveryActionAndReportsEachFailure()
    {
        var attempts = new List<string>();

        var exception = Assert.ThrowsExactly<ShutdownCleanupException>(() =>
            ShutdownCleanup.Execute(
            [
                new ShutdownCleanupAction("tray", () =>
                {
                    attempts.Add("tray");
                    throw new InvalidOperationException("Tray failure.");
                }),
                new ShutdownCleanupAction("runtime", () => attempts.Add("runtime")),
                new ShutdownCleanupAction("base", () =>
                {
                    attempts.Add("base");
                    throw new IOException("Base failure.");
                }),
            ]));

        CollectionAssert.AreEqual(new[] { "tray", "runtime", "base" }, attempts);
        CollectionAssert.AreEqual(
            new[] { "tray", "base" },
            exception.Failures.Select(failure => failure.Name).ToArray());
        Assert.IsInstanceOfType<AggregateException>(exception.InnerException);
        Assert.HasCount(2, ((AggregateException)exception.InnerException!).InnerExceptions);
    }

    private sealed class InMemoryAppSettingsStore(AppSettings initial) : IAppSettingsStore
    {
        private AppSettingsSnapshot _snapshot = CreateSnapshot(initial);

        public int SaveCount { get; private set; }

        public Task<AppSettingsSnapshot?> LoadAsync(CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            return Task.FromResult<AppSettingsSnapshot?>(_snapshot);
        }

        public Task<AppSettingsSnapshot> SaveAsync(
            AppSettings settings,
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            SaveCount++;
            _snapshot = CreateSnapshot(settings);
            return Task.FromResult(_snapshot);
        }

        public Task<AppSettingsSnapshot> RestoreAsync(
            AppSettingsSnapshot snapshot,
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            _snapshot = CreateSnapshot(snapshot.Settings);
            return Task.FromResult(_snapshot);
        }

        public Task<AppSettingsSnapshot> ResetToDefaultsAsync(CancellationToken cancellationToken = default) =>
            SaveAsync(AppSettings.Defaults, cancellationToken);

        private static AppSettingsSnapshot CreateSnapshot(AppSettings settings)
        {
            var admitted = AppSettingsContract.Admit(settings);
            var canonical = $"synthetic:{admitted.Language}:{admitted.WidgetVariant}:{admitted.WidgetEnabled}";
            return new AppSettingsSnapshot(admitted, canonical, canonical);
        }
    }

    private sealed class InMemoryStartupBackend : ICurrentUserStartupBackend
    {
        public Dictionary<string, string> Values { get; } = new(StringComparer.Ordinal);

        public string? Read(string valueName) => Values.TryGetValue(valueName, out var value) ? value : null;

        public void Write(string valueName, string command) => Values[valueName] = command;

        public void Delete(string valueName) => Values.Remove(valueName);
    }
}
