using System.IO;
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
    private IWidgetWindowLauncher? _widgetLauncher;

    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        if (RuntimeEvidenceOptions.IsRequested(e.Args))
        {
            await RunRuntimeEvidenceAsync(e.Args);
            return;
        }

        var reviewState = new ComplianceReviewStateHub();
        LiveDashboardState? state = null;
        try
        {
            _reviewCommands = new ComplianceReviewCommandCoordinator(
                new HerdrOpsReviewCommandPipeClient(
                    HerdrOpsReviewCommandPipeClientOptions.ForCurrentUser()),
                reviewState,
                new DispatcherComplianceReviewStateScheduler(Dispatcher));
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

            state = new LiveDashboardState(
                reviewState,
                _reviewCommands,
                reviewerActorId);
            _runtime = new LiveDashboardRuntime(
                new HerdrOpsStatePipeClient(HerdrOpsStatePipeClientOptions.ForCurrentUser()),
                state,
                new DispatcherLiveDashboardUiScheduler(Dispatcher));
            _runtime.Start();
        }
        catch (Exception exception) when (
            exception is IOException or ArgumentException or InvalidOperationException or UnauthorizedAccessException)
        {
            state ??= new LiveDashboardState(reviewState);
            state.MarkOffline(exception, DateTimeOffset.UtcNow);
        }

        state ??= new LiveDashboardState(reviewState);
        var mainWindow = new MainWindow(state);
        MainWindow = mainWindow;
        mainWindow.Show();
        _lifecycle = AppLifecycleComposition.CreateForCurrentUser(UiLanguageService.Shared);
        await _lifecycle.InitializeAsync();
        _widgetLauncher = new WidgetWindowLauncher(state.Widgets);
        if (_lifecycle.Settings.WidgetEnabled)
        {
            _widgetLauncher.Open(
                AppSettingsLifecycleMapping.ToWidgetVariant(_lifecycle.Settings.WidgetVariant));
        }

        StartTray(state);
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
            RuntimeEvidenceRunner.WriteFailure(options.ReportPath, startedUtc, exception);
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
                            if (mainWindow?.IsVisible == true)
                            {
                                mainWindow.Close();
                            }
                        }),
                ]);
            }
            catch (Exception exception)
            {
                cleanupFailure = exception;
            }
        }

        if (cleanupFailure is not null)
        {
            RuntimeEvidenceRunner.WriteFailure(options.ReportPath, startedUtc, cleanupFailure);
            exitCode = 2;
        }

        Shutdown(exitCode);
    }

    protected override void OnExit(ExitEventArgs e)
    {
        ShutdownCleanup.Execute(
        [
            new ShutdownCleanupAction("tray", StopTray),
            new ShutdownCleanupAction("runtime", DisposeRuntime),
            new ShutdownCleanupAction("review-commands", () => _reviewCommands = null),
            new ShutdownCleanupAction("application-base", () => base.OnExit(e)),
        ]);
    }

    private void StartTray(LiveDashboardState state)
    {
        var lifecycle = _lifecycle ?? throw new InvalidOperationException(
            "The application lifecycle has not been initialized.");
        UiLanguageService.Shared.LanguageChanged += OnLanguageChanged;
        var menuBuilder = new TrayMenuBuilder(
            () => lifecycle.Settings,
            UiLanguageService.Shared,
            () => lifecycle.StartAtLogonStatus);

        _tray = new TrayLifecycleController(
            new SystemTrayBackend(),
            menuBuilder.Build,
            new WpfTrayCommandTarget(
                () => MainWindow as MainWindow,
                _widgetLauncher ?? new WidgetWindowLauncher(state.Widgets),
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
                }));
        _tray.Start();
    }

    private void StopTray()
    {
        UiLanguageService.Shared.LanguageChanged -= OnLanguageChanged;
        try
        {
            _tray?.Dispose();
        }
        finally
        {
            _tray = null;
        }
    }

    private void DisposeRuntime()
    {
        var runtime = _runtime;
        _runtime = null;
        runtime?.Dispose();
    }

    private void OnLanguageChanged(object? sender, EventArgs e) => _tray?.Refresh();
}
