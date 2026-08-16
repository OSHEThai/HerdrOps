using HerdrOps.Domain.Lifecycle;
using HerdrOps.Domain.Settings;

namespace HerdrOps.UnitTests;

[TestClass]
public sealed class TrayAndStartupLifecycleTests
{
    [TestMethod]
    public void TrayCommandRouterRoutesEveryCommandToTheInjectedTarget()
    {
        var target = new RecordingTrayTarget();
        var router = new TrayCommandRouter(target);

        router.Execute(TrayCommand.ShowDashboard);
        router.Execute(TrayCommand.ShowConfiguredWidget);
        router.Execute(TrayCommand.SelectThaiLanguage);
        router.Execute(TrayCommand.SelectEnglishLanguage);
        router.Execute(TrayCommand.Exit);

        CollectionAssert.AreEqual(
            new[] { "dashboard", "widget", "language", "language", "exit" },
            target.Actions);
        CollectionAssert.AreEqual(
            new[] { AppSettingsLanguage.Thai, AppSettingsLanguage.English },
            target.Languages);
    }

    [TestMethod]
    public void TrayCommandRouterPropagatesTargetFailures()
    {
        var target = new RecordingTrayTarget
        {
            Failure = new InvalidOperationException("Synthetic target failure."),
        };

        var exception = Assert.ThrowsExactly<InvalidOperationException>(() =>
            new TrayCommandRouter(target).Execute(TrayCommand.ShowDashboard));

        Assert.AreEqual("Synthetic target failure.", exception.Message);
    }

    [TestMethod]
    public void TrayMenuModelRequiresExactlyOneSelectedLanguage()
    {
        var bothSelected = Assert.ThrowsExactly<ArgumentException>(() =>
            new TrayMenuModel(
                "HerdrOps",
                [
                    new TrayMenuItem(TrayCommand.SelectThaiLanguage, "ไทย", isChecked: true),
                    new TrayMenuItem(TrayCommand.SelectEnglishLanguage, "English", isChecked: true),
                ]));

        StringAssert.Contains(bothSelected.Message, "exactly one");

        Assert.ThrowsExactly<ArgumentException>(() =>
            new TrayMenuModel(
                "HerdrOps",
                [
                    new TrayMenuItem(TrayCommand.SelectThaiLanguage, "ไทย"),
                    new TrayMenuItem(TrayCommand.SelectEnglishLanguage, "English"),
                ]));
    }

    [TestMethod]
    public void StartAtLogonEnableDisableAndStatusAreIdempotentWithAnInMemoryBackend()
    {
        var backend = new InMemoryStartupBackend();
        var service = new StartAtLogonService(
            backend,
            @"C:\Program Files\HerdrOps\HerdrOps.App.exe");

        Assert.AreEqual(StartupRegistrationContract.ValueName, service.ValueName);
        Assert.AreEqual(StartupRegistrationState.Disabled, service.GetStatus().State);

        service.Enable();
        service.Enable();

        var enabled = service.GetStatus();
        Assert.AreEqual(StartupRegistrationState.Enabled, enabled.State);
        Assert.IsTrue(enabled.IsEnabled);
        Assert.AreEqual(
            @"""C:\Program Files\HerdrOps\HerdrOps.App.exe""",
            enabled.ExpectedCommand);
        Assert.AreEqual(1, backend.WriteCount);

        service.Disable();
        service.Disable();

        Assert.AreEqual(StartupRegistrationState.Disabled, service.GetStatus().State);
        Assert.AreEqual(1, backend.DeleteCount);
    }

    [TestMethod]
    public void StartAtLogonReportsAConflictingDeterministicValue()
    {
        var backend = new InMemoryStartupBackend();
        var service = new StartAtLogonService(
            backend,
            @"C:\HerdrOps\HerdrOps.App.exe");
        backend.Values[service.ValueName] = @"""C:\Other\Other.exe""";

        var status = service.GetStatus();

        Assert.AreEqual(StartupRegistrationState.Conflicting, status.State);
        Assert.IsFalse(status.IsEnabled);
        Assert.AreEqual(@"""C:\Other\Other.exe""", status.RegisteredCommand);
    }

    [TestMethod]
    public void StartAtLogonRejectsMalformedExecutablePaths()
    {
        var malformedPaths = new[]
        {
            "",
            "HerdrOps.exe",
            @"C:HerdrOps.exe",
            @"\\server\share\HerdrOps.exe",
            @"\\?\C:\HerdrOps\HerdrOps.exe",
            @"C:\HerdrOps\",
            @"C:\HerdrOps\HerdrOps.dll",
            @"C:\HerdrOps\HerdrOps.exe:startup",
            @"C:\HerdrOps\bad""name.exe",
            @"C:\HerdrOps\.\HerdrOps.exe",
        };

        foreach (var malformedPath in malformedPaths)
        {
            Assert.ThrowsExactly<StartupRegistrationException>(() =>
                new StartAtLogonService(new InMemoryStartupBackend(), malformedPath),
                malformedPath);
        }
    }

    [TestMethod]
    public void StartAtLogonPropagatesBackendFailures()
    {
        var failure = new IOException("Synthetic startup backend failure.");
        var backend = new FailingStartupBackend(failure);
        var service = new StartAtLogonService(backend, @"C:\HerdrOps\HerdrOps.App.exe");

        var exception = Assert.ThrowsExactly<IOException>(() => service.Enable());

        Assert.AreSame(failure, exception);
    }

    private sealed class RecordingTrayTarget : ITrayCommandTarget
    {
        public List<string> Actions { get; } = [];

        public List<AppSettingsLanguage> Languages { get; } = [];

        public Exception? Failure { get; init; }

        public void ShowDashboard()
        {
            ThrowIfConfigured();
            Actions.Add("dashboard");
        }

        public void ShowConfiguredWidget()
        {
            ThrowIfConfigured();
            Actions.Add("widget");
        }

        public void SelectLanguage(AppSettingsLanguage language)
        {
            ThrowIfConfigured();
            Actions.Add("language");
            Languages.Add(language);
        }

        public void Exit()
        {
            ThrowIfConfigured();
            Actions.Add("exit");
        }

        private void ThrowIfConfigured()
        {
            if (Failure is not null)
            {
                throw Failure;
            }
        }
    }

    private sealed class InMemoryStartupBackend : ICurrentUserStartupBackend
    {
        public Dictionary<string, string> Values { get; } = new(StringComparer.Ordinal);

        public int WriteCount { get; private set; }

        public int DeleteCount { get; private set; }

        public string? Read(string valueName) =>
            Values.TryGetValue(valueName, out var value) ? value : null;

        public void Write(string valueName, string command)
        {
            WriteCount++;
            Values[valueName] = command;
        }

        public void Delete(string valueName)
        {
            DeleteCount++;
            Values.Remove(valueName);
        }
    }

    private sealed class FailingStartupBackend(IOException failure) : ICurrentUserStartupBackend
    {
        public string? Read(string valueName) => throw failure;

        public void Write(string valueName, string command) => throw failure;

        public void Delete(string valueName) => throw failure;
    }
}
