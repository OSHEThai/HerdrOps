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
        router.Execute(TrayCommand.HideDashboard);
        router.Execute(TrayCommand.ShowConfiguredWidget);
        router.Execute(TrayCommand.ToggleWidgetEnabled);
        router.Execute(TrayCommand.SelectThaiLanguage);
        router.Execute(TrayCommand.SelectEnglishLanguage);
        router.Execute(TrayCommand.Exit);

        CollectionAssert.AreEqual(
            new[] { "dashboard", "hide", "widget", "widget-enabled", "language", "language", "exit" },
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
    public void StartAtLogonConflictFailsClosedAndDisablePreservesTheOtherCommand()
    {
        var backend = new InMemoryStartupBackend();
        var service = new StartAtLogonService(
            backend,
            @"C:\HerdrOps\HerdrOps.App.exe");
        const string otherCommand = @"""C:\Other\Other.exe""";
        backend.Values[service.ValueName] = otherCommand;

        var enabled = service.Enable();
        var disabled = service.Disable();

        Assert.AreEqual(0, backend.WriteCount);
        Assert.AreEqual(0, backend.DeleteCount);
        Assert.AreEqual(otherCommand, backend.Values[service.ValueName]);
        Assert.AreEqual(StartupRegistrationState.Conflicting, enabled.State);
        Assert.AreEqual(StartupRegistrationState.Conflicting, disabled.State);
        Assert.AreEqual(StartupRegistrationState.Conflicting, service.GetStatus().State);
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
            @"C:\HerdrOps\HerdrOps.exe:alt",
            @"C:\HerdrOps?\HerdrOps.exe",
            @"C:\HerdrOps*\HerdrOps.exe",
            @"C:\HerdrOps \HerdrOps.exe",
            @"C:\HerdrOps.\HerdrOps.exe",
            @"C:\HerdrOps\HerdrOps.exe.",
            @"C:\HerdrOps\bad""name.exe",
            @"C:\HerdrOps\.\HerdrOps.exe",
            @"C:\HerdrOps\CON.exe",
            @"C:\HerdrOps\PRN.txt.exe",
            @"C:\HerdrOps\COM1.bin.exe",
            @"C:\HerdrOps\folder\NUL.exe",
            @"C:\HerdrOps\LPT9.exe",
        };

        foreach (var malformedPath in malformedPaths)
        {
            Assert.ThrowsExactly<StartupRegistrationException>(() =>
                new StartAtLogonService(new InMemoryStartupBackend(), malformedPath),
                malformedPath);
        }
    }

    [TestMethod]
    public void StartAtLogonQuotesValidAbsoluteWindowsExecutableControls()
    {
        var validPaths = new[]
        {
            @"C:\HerdrOps\HerdrOps.exe",
            @"C:\Program Files\HerdrOps\HerdrOps.App.exe",
            @"D:/Agents/HerdrOps/HerdrOps.Agent.exe",
        };

        foreach (var validPath in validPaths)
        {
            var expected = $"\"{Path.GetFullPath(validPath)}\"";
            var actual = new StartAtLogonService(
                new InMemoryStartupBackend(),
                validPath).ExpectedCommand;

            Assert.AreEqual(expected, actual, validPath);
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

    [TestMethod]
    public void StartAtLogonRechecksAfterWriteAndReturnsControlledConflictStatus()
    {
        var backend = new RacingStartupBackend();
        var coordinator = new CountingStartupCoordinator();
        var service = new StartAtLogonService(
            backend,
            @"C:\HerdrOps\HerdrOps.App.exe",
            coordinator);

        var status = service.Enable();

        Assert.AreEqual(StartupRegistrationState.Conflicting, status.State);
        Assert.AreEqual(StartupRegistrationState.Conflicting, service.GetStatus().State);
        Assert.AreEqual(1, backend.WriteCount);
        Assert.IsGreaterThanOrEqualTo(2, coordinator.EnterCount);
    }

    [TestMethod]
    public void StartAtLogonDoesNotOverwriteOrDeleteAWriterSeenAtTheRaceBoundary()
    {
        var backend = new BoundaryRaceStartupBackend();
        var service = new StartAtLogonService(
            backend,
            @"C:\HerdrOps\HerdrOps.App.exe");

        var enableStatus = service.Enable();

        Assert.AreEqual(StartupRegistrationState.Conflicting, enableStatus.State);
        Assert.AreEqual(0, backend.WriteCount);

        backend.ResetToExpected(service.ExpectedCommand);
        var disableStatus = service.Disable();

        Assert.AreEqual(StartupRegistrationState.Conflicting, disableStatus.State);
        Assert.AreEqual(0, backend.DeleteCount);
    }

    [TestMethod]
    public void TrayCleanupRetriesWhenHideAndBackendDisposeBothInitiallyFail()
    {
        var backend = new RetryableTrayBackend();
        var controller = new TrayLifecycleController(
            backend,
            () => new TrayMenuModel(
                "HerdrOps",
                [
                    new TrayMenuItem(TrayCommand.ShowDashboard, "Dashboard"),
                    new TrayMenuItem(TrayCommand.HideDashboard, "Hide"),
                    new TrayMenuItem(TrayCommand.SelectThaiLanguage, "ไทย", isChecked: true),
                    new TrayMenuItem(TrayCommand.SelectEnglishLanguage, "English"),
                ]),
            new RecordingTrayTarget());

        controller.Start();
        Assert.ThrowsExactly<TrayCleanupException>(() => controller.Dispose());
        Assert.IsTrue(controller.IsStarted);

        controller.Dispose();

        Assert.AreEqual(2, backend.HideCount);
        Assert.AreEqual(2, backend.DisposeCount);
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

        public void HideDashboard()
        {
            ThrowIfConfigured();
            Actions.Add("hide");
        }

        public void ShowConfiguredWidget()
        {
            ThrowIfConfigured();
            Actions.Add("widget");
        }

        public void ToggleWidgetEnabled()
        {
            ThrowIfConfigured();
            Actions.Add("widget-enabled");
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

    private sealed class RacingStartupBackend : ICurrentUserStartupBackend
    {
        public const string ForeignCommand = @"""C:\Other\Other.exe""";

        public Dictionary<string, string> Values { get; } = new(StringComparer.Ordinal);

        public int WriteCount { get; private set; }

        public string? Read(string valueName) =>
            Values.TryGetValue(valueName, out var value) ? value : null;

        public void Write(string valueName, string command)
        {
            WriteCount++;
            Values[valueName] = ForeignCommand;
        }

        public void Delete(string valueName) => Values.Remove(valueName);
    }

    private sealed class BoundaryRaceStartupBackend : ICurrentUserStartupBackend
    {
        private const string ForeignCommand = @"""C:\Other\Other.exe""";
        private Dictionary<string, string> _values = new(StringComparer.Ordinal);
        private int _readCount;

        public int WriteCount { get; private set; }

        public int DeleteCount { get; private set; }

        public string? Read(string valueName)
        {
            _readCount++;
            if (_readCount == 2 && !_values.ContainsKey(valueName))
            {
                _values[valueName] = ForeignCommand;
            }

            if (_readCount == 2 && _values.ContainsKey(valueName))
            {
                _values[valueName] = ForeignCommand;
                return ForeignCommand;
            }

            return _values.TryGetValue(valueName, out var value) ? value : null;
        }

        public void Write(string valueName, string command) => WriteCount++;

        public void Delete(string valueName) => DeleteCount++;

        public void ResetToExpected(string expectedCommand)
        {
            _values = new Dictionary<string, string>(StringComparer.Ordinal)
            {
                [StartupRegistrationContract.ValueName] = expectedCommand,
            };
            _readCount = 0;
        }
    }

    private sealed class CountingStartupCoordinator : IStartupRegistrationCoordinator
    {
        public int EnterCount { get; private set; }

        public IDisposable Enter()
        {
            EnterCount++;
            return new NoopLease();
        }

        private sealed class NoopLease : IDisposable
        {
            public void Dispose()
            {
            }
        }
    }

    private sealed class RetryableTrayBackend : ITrayBackend
    {
        private int _hideAttempts;
        private int _disposeAttempts;

        public int HideCount { get; private set; }

        public int DisposeCount { get; private set; }

        public void Show(TrayMenuModel menu, Action<TrayCommand> commandHandler)
        {
        }

        public void Update(TrayMenuModel menu)
        {
        }

        public void Hide()
        {
            HideCount++;
            if (Interlocked.Increment(ref _hideAttempts) == 1)
            {
                throw new IOException("Synthetic tray hide failure.");
            }
        }

        public void Dispose()
        {
            DisposeCount++;
            if (Interlocked.Increment(ref _disposeAttempts) == 1)
            {
                throw new IOException("Synthetic tray dispose failure.");
            }
        }
    }
}
