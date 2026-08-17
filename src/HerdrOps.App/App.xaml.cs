using System.Windows;
using HerdrOps.App.Lifecycle;
using HerdrOps.App.Live;
using HerdrOps.App.Localization;
using HerdrOps.App.ReviewIpc;
using HerdrOps.App.RuntimeEvidence;
using HerdrOps.App.StateIpc;
using HerdrOps.App.Widgets;
using HerdrOps.Domain.Compliance;
using HerdrOps.Domain.Lifecycle;
using HerdrOps.Domain.Settings;

namespace HerdrOps.App;

/// <summary>
/// Provides application-level design resources for the dashboard and widgets.
/// </summary>
public partial class App : Application
{
    private LiveDashboardRuntime? _runtime;
    private ComplianceReviewCommandCoordinator? _reviewCommands;
    private TrayLifecycleController? _tray;
    private AppLifecycleController? _lifecycle;
    private WidgetWindowLauncher? _widgetLauncher;
    private DashboardWindowManager? _dashboardWindows;
    private ApplicationInstanceGateLease? _instanceGate;
    private StartupTransaction? _startupTransaction;
    private Exception? _startupFailure;
    private readonly Func<IApplicationInstanceGate> _instanceGateFactory;

    public App()
        : this(() => new WindowsPerUserApplicationInstanceGate())
    {
    }

    public App(Func<IApplicationInstanceGate> instanceGateFactory)
    {
        _instanceGateFactory = instanceGateFactory ?? throw new ArgumentNullException(nameof(instanceGateFactory));
    }

    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        ShutdownMode = ShutdownMode.OnExplicitShutdown;
        if (RuntimeEvidenceOptions.IsRequested(e.Args))
        {
            await RunRuntimeEvidenceAsync(e.Args);
            return;
        }

        try
        {
            await StartNormalAsync();
        }
        catch (Exception exception)
        {
            _startupFailure = exception;
            Shutdown(1);
        }
    }

    private async Task StartNormalAsync()
    {
        var transaction = new StartupTransaction();
        _startupTransaction = transaction;
        try
        {
            var gate = ApplicationInstanceGateStartup.Acquire(_instanceGateFactory, transaction);
            if (gate is null)
            {
                transaction.Commit(static () => { });
                _startupTransaction = null;
                Shutdown(0);
                return;
            }

            _instanceGate = gate;

            var reviewState = new ComplianceReviewStateHub();
            _reviewCommands = new ComplianceReviewCommandCoordinator(
                new HerdrOpsReviewCommandPipeClient(
                    HerdrOpsReviewCommandPipeClientOptions.ForCurrentUser()),
                reviewState,
                new DispatcherComplianceReviewStateScheduler(Dispatcher));
            transaction.AddCleanup("review-commands", ClearReviewCommands);
            var reviewerActorId = string.Equals(
                    Environment.GetEnvironmentVariable("HERDR_ENV"),
                    "1",
                    StringComparison.Ordinal)
                ? Environment.GetEnvironmentVariable("HERDR_PANE_ID")
                : null;
            if (!string.IsNullOrWhiteSpace(reviewerActorId))
            {
                try
                {
                    reviewerActorId = ComplianceReviewWorkflowContract.NormalizeActorId(
                        reviewerActorId);
                }
                catch (ComplianceReviewContractException)
                {
                    reviewerActorId = null;
                }
            }

            var state = new LiveDashboardState(
                reviewState,
                _reviewCommands,
                reviewerActorId);
            _runtime = new LiveDashboardRuntime(
                new HerdrOpsStatePipeClient(HerdrOpsStatePipeClientOptions.ForCurrentUser()),
                state,
                new DispatcherLiveDashboardUiScheduler(Dispatcher));
            transaction.AddCleanup("runtime", DisposeRuntime);
            _runtime.Start();

            _widgetLauncher = new WidgetWindowLauncher(state.Widgets);
            transaction.AddCleanup("widgets", DisposeWidgets);

            _lifecycle = AppLifecycleComposition.CreateForCurrentUser(
                UiLanguageService.Shared,
                ApplySettings);
            transaction.AddCleanup("lifecycle", () => _lifecycle = null);
            await _lifecycle.InitializeAsync();

            var lifecycle = _lifecycle;
            _dashboardWindows = new DashboardWindowManager(() => new MainWindow(
                state,
                language => lifecycle.SelectLanguage(
                    AppSettingsLifecycleMapping.ToAppSettingsLanguage(language)),
                widget => lifecycle.SelectWidget(widget),
                enabled => lifecycle.SetWidgetEnabled(enabled),
                _widgetLauncher));
            transaction.AddCleanup("dashboard", CloseDashboard);
            _ = _dashboardWindows.GetOrCreate();

            var tray = CreateTray(state, _dashboardWindows);
            _tray = tray;
            transaction.AddCleanup("tray", StopTray);
            UiLanguageService.Shared.LanguageChanged += OnLanguageChanged;
            tray.Start();

            transaction.Commit(_dashboardWindows.Show);
            _startupTransaction = null;
        }
        catch (Exception primaryException)
        {
            try
            {
                transaction.Rollback(primaryException);
            }
            catch
            {
                if (!transaction.HasPendingCleanup)
                {
                    _startupTransaction = null;
                }

                throw;
            }
        }
    }

    private async Task RunRuntimeEvidenceAsync(IReadOnlyList<string> args)
    {
        var startedUtc = DateTimeOffset.UtcNow;
        if (!RuntimeEvidenceOptions.TryParse(args, out var parsedOptions, out _))
        {
            Shutdown(64);
            return;
        }

        var options = parsedOptions!;
        ShutdownMode = ShutdownMode.OnExplicitShutdown;
        if (!string.Equals(
                Environment.GetEnvironmentVariable("HERDR_ENV"),
                "1",
                StringComparison.Ordinal) ||
            string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable("HERDR_SOCKET_PATH")))
        {
            RuntimeEvidenceRunner.WriteFailure(
                options.ReportPath,
                startedUtc,
                new UnauthorizedAccessException(
                    "Runtime evidence mode requires HERDR_ENV=1 and HERDR_SOCKET_PATH from an authorized Herdr pane."));
            Shutdown(3);
            return;
        }

        RuntimeEvidenceRunner? runner = null;
        MainWindow? mainWindow = null;
        var exitCode = 2;
        Exception? primaryFailure = null;
        Exception? cleanupFailure = null;
        try
        {
            var state = new LiveDashboardState();
            _runtime = new LiveDashboardRuntime(
                new HerdrOpsStatePipeClient(HerdrOpsStatePipeClientOptions.ForCurrentUser()),
                state,
                new DispatcherLiveDashboardUiScheduler(Dispatcher));
            _runtime.Start();
            mainWindow = new MainWindow(state);
            MainWindow = mainWindow;
            mainWindow.Show();
            runner = new RuntimeEvidenceRunner(state, mainWindow, options);
            var report = await runner.RunAsync();
            exitCode = report.CompositeCandidateChecksPassed ? 0 : 2;
        }
        catch (Exception exception)
        {
            primaryFailure = exception;
        }
        finally
        {
            try
            {
                ShutdownCleanup.Execute(
                [
                    new ShutdownCleanupAction(
                        "runtime-evidence-windows",
                        () => runner?.CloseEvidenceWindows()),
                    new ShutdownCleanupAction("runtime", DisposeRuntime),
                    new ShutdownCleanupAction(
                        "dashboard",
                        () =>
                        {
                            if (mainWindow is { IsClosed: false })
                            {
                                mainWindow.CloseForShutdown();
                            }
                        }),
                ]);
            }
            catch (Exception exception)
            {
                cleanupFailure = exception;
            }
        }

        if (primaryFailure is not null && cleanupFailure is ShutdownCleanupException cleanupException)
        {
            RuntimeEvidenceRunner.WriteFailure(
                options.ReportPath,
                startedUtc,
                new StartupTransactionException(primaryFailure, cleanupException));
            exitCode = 2;
        }
        else if (primaryFailure is not null)
        {
            RuntimeEvidenceRunner.WriteFailure(options.ReportPath, startedUtc, primaryFailure);
            exitCode = 2;
        }
        else if (cleanupFailure is not null)
        {
            RuntimeEvidenceRunner.WriteFailure(options.ReportPath, startedUtc, cleanupFailure);
            exitCode = 2;
        }

        Shutdown(exitCode);
    }

    protected override void OnExit(ExitEventArgs e)
    {
        try
        {
            ShutdownCleanup.Execute(
            [
                new ShutdownCleanupAction(
                    "startup-rollback",
                    () => _startupTransaction?.RetryCleanup()),
                new ShutdownCleanupAction("tray", StopTray),
                new ShutdownCleanupAction("dashboard", CloseDashboard),
                new ShutdownCleanupAction("widgets", DisposeWidgets),
                new ShutdownCleanupAction("runtime", DisposeRuntime),
                new ShutdownCleanupAction("review-commands", ClearReviewCommands),
                new ShutdownCleanupAction("single-instance", ReleaseInstanceGate),
                new ShutdownCleanupAction("application-base", () => base.OnExit(e)),
            ]);
        }
        catch (ShutdownCleanupException cleanupException) when (_startupFailure is not null)
        {
            throw new StartupTransactionException(_startupFailure, cleanupException);
        }
    }

    private TrayLifecycleController CreateTray(
        LiveDashboardState state,
        DashboardWindowManager dashboardWindows)
    {
        var lifecycle = _lifecycle ?? throw new InvalidOperationException(
            "The application lifecycle has not been initialized.");
        var menuBuilder = new TrayMenuBuilder(
            () => lifecycle.Settings,
            UiLanguageService.Shared,
            () => lifecycle.StartAtLogonStatus);

        return new TrayLifecycleController(
            new SystemTrayBackend(),
            menuBuilder.Build,
            new WpfTrayCommandTarget(
                dashboardWindows.GetOrCreate,
                _widgetLauncher ?? throw new InvalidOperationException(
                    "The widget launcher has not been composed."),
                () => lifecycle.Settings,
                language =>
                {
                    lifecycle.SelectLanguage(language);
                },
                Shutdown,
                UiLanguageService.Shared,
                () =>
                {
                    lifecycle.ToggleStartAtLogon();
                    _tray?.Refresh();
                },
                () =>
                {
                    lifecycle.SetWidgetEnabled(!lifecycle.Settings.WidgetEnabled);
                    _tray?.Refresh();
                },
                dashboardWindows.Hide,
                 () => dashboardWindows.Current));
    }

    private void StopTray()
    {
        UiLanguageService.Shared.LanguageChanged -= OnLanguageChanged;
        var tray = _tray;
        if (tray is null)
        {
            return;
        }

        tray.Dispose();
        _tray = null;
    }

    private void DisposeRuntime()
    {
        var runtime = _runtime;
        if (runtime is null)
        {
            return;
        }

        runtime.Dispose();
        _runtime = null;
    }

    private void ClearReviewCommands() => _reviewCommands = null;

    private void DisposeWidgets()
    {
        var launcher = _widgetLauncher;
        if (launcher is null)
        {
            return;
        }

        launcher.Dispose();
        _widgetLauncher = null;
    }

    private void CloseDashboard()
    {
        var dashboard = _dashboardWindows;
        if (dashboard is null)
        {
            return;
        }

        dashboard.Dispose();
        _dashboardWindows = null;
        MainWindow = null;
    }

    private void ReleaseInstanceGate()
    {
        var gate = _instanceGate;
        if (gate is null)
        {
            return;
        }

        gate.Dispose();
        _instanceGate = null;
    }

    private void ApplySettings(AppSettings settings)
    {
        UiLanguageService.Shared.SetLanguage(
            AppSettingsLifecycleMapping.ToUiLanguage(settings.Language));
        _widgetLauncher?.ApplySettings(settings);
    }

    private void OnLanguageChanged(object? sender, EventArgs e) => _tray?.Refresh();
}
