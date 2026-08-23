using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
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
    private readonly bool _suppressStartupForTestHost;
    private readonly Issue10PerformanceTelemetryOptions? _performanceTelemetryOptions;
    private readonly string? _performanceTelemetryOptionError;
    private Issue10PerformanceTelemetryProducer? _performanceTelemetry;
    private LiveDashboardState? _dashboardState;

    public App()
        : this(() => new WindowsPerUserApplicationInstanceGate(), false)
    {
    }

    public App(Func<IApplicationInstanceGate> instanceGateFactory)
        : this(instanceGateFactory, false)
    {
    }

    internal App(bool suppressStartupForTestHost)
        : this(() => new WindowsPerUserApplicationInstanceGate(), suppressStartupForTestHost)
    {
    }

    private App(
        Func<IApplicationInstanceGate> instanceGateFactory,
        bool suppressStartupForTestHost)
    {
        var processArgs = Environment.GetCommandLineArgs().Skip(1).ToArray();
        _ = Issue10PerformanceTelemetryOptions.TryParseInvocation(
            processArgs,
            out _performanceTelemetryOptions,
            out _performanceTelemetryOptionError);
        try
        {
            _performanceTelemetryOptions?.PackageLease.Revalidate("before renderer policy selection");
            RuntimeRenderPolicy.EnforceBeforeFirstWpfComposition(
                _performanceTelemetryOptions?.RendererMode);
            _performanceTelemetryOptions?.PackageLease.Revalidate("after renderer policy selection");
        }
        catch { _performanceTelemetryOptions?.PackageLease.Dispose(); throw; }
        _instanceGateFactory = instanceGateFactory ?? throw new ArgumentNullException(nameof(instanceGateFactory));
        _suppressStartupForTestHost = suppressStartupForTestHost;
    }

    internal bool IsTestHostStartupSuppressed => _suppressStartupForTestHost;

    protected override async void OnStartup(StartupEventArgs e)
    {
        _ = RuntimeRenderPolicy.ObserveAndRequireConfiguredMode(
            "app-on-startup-before-base");
        base.OnStartup(e);
        ShutdownMode = ShutdownMode.OnExplicitShutdown;
        if (_suppressStartupForTestHost)
        {
            return;
        }

        if (_performanceTelemetryOptionError is not null)
        {
            Shutdown(64);
            return;
        }

        if (_performanceTelemetryOptions is not null)
        {
            await RunIssue10PerformanceTelemetryAsync(_performanceTelemetryOptions);
            return;
        }

        if (Issue10WidgetEvidenceProducer.IsFinalizationRequested(e.Args))
        {
            Shutdown(Issue10WidgetEvidenceProducer.FinalizeFromCommandLine(e.Args));
            return;
        }

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
            _dashboardState = state;
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

    private async Task RunIssue10PerformanceTelemetryAsync(
        Issue10PerformanceTelemetryOptions options)
    {
        var telemetryOwnsLease = false;
        try
        {
            await StartNormalAsync();
            if (_dashboardState is null)
            {
                throw new InvalidOperationException(
                    "Issue #10 performance telemetry requires initialized production dashboard state.");
            }

            await using var telemetry = new Issue10PerformanceTelemetryProducer(
                options,
                Dispatcher,
                _dashboardState.Widgets,
                RuntimeRenderPolicy.StartupObservation);
            telemetryOwnsLease = true;
            _performanceTelemetry = telemetry;
            await telemetry.RunAsync(CancellationToken.None);
            _performanceTelemetry = null;
            Shutdown(0);
        }
        catch (Exception exception)
        {
            _startupFailure = exception;
            Shutdown(2);
        }
        finally { if (!telemetryOwnsLease) options.PackageLease.Dispose(); }
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
        if (options.Issue10WidgetReportPath is not null)
        {
            RuntimeEvidenceRunner.WriteFailure(
                options.ReportPath,
                startedUtc,
                new InvalidOperationException(
                    "Issue #10 widget evidence must be finalized by the composite gate after the same-run Gate/Core/App reports are sealed."),
                options.ProgressPath);
            Shutdown(64);
            return;
        }
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
                    "Runtime evidence mode requires HERDR_ENV=1 and HERDR_SOCKET_PATH from an authorized Herdr pane."),
                options.ProgressPath);
            Shutdown(3);
            return;
        }

        RuntimeEvidenceRunner? runner = null;
        RuntimeEvidenceProducerBinding? producerBinding = null;
        RendererTargetObservationProducer? rendererObservation = null;
        MainWindow? mainWindow = null;
        var exitCode = 2;
        Exception? primaryFailure = null;
        Exception? cleanupFailure = null;
        using var rendererDeadline = new CancellationTokenSource();
        var rendererRemaining = startedUtc.AddSeconds(options.TimeoutSeconds) - DateTimeOffset.UtcNow;
        rendererDeadline.CancelAfter(rendererRemaining > TimeSpan.Zero ? rendererRemaining : TimeSpan.Zero);
        var rendererCancellation = rendererDeadline.Token;
        try
        {
            producerBinding = RuntimeEvidenceProducerBinding.ObserveBeforeFirstWindow(
                options);
            if (options.RendererObservation is not null)
            {
                rendererObservation = new RendererTargetObservationProducer(
                    options.RendererObservation);
                rendererObservation.Start();
                await rendererObservation.WaitForFirstWindowPermissionAsync(
                    rendererCancellation);
            }

            var state = new LiveDashboardState();
            _runtime = new LiveDashboardRuntime(
                new HerdrOpsStatePipeClient(HerdrOpsStatePipeClientOptions.ForCurrentUser()),
                state,
                new DispatcherLiveDashboardUiScheduler(Dispatcher));
            _runtime.Start();
            mainWindow = new MainWindow(state);
            MainWindow = mainWindow;
            mainWindow.Show();
            rendererObservation?.AttachFirstWindow(mainWindow);
            runner = new RuntimeEvidenceRunner(
                state,
                mainWindow,
                options,
                producerBinding,
                rendererObservation);
            var report = await runner.RunAsync();
            if (rendererObservation is not null)
            {
                await rendererObservation.WaitForThaiCapturePermissionAsync(rendererCancellation);
                await runner.CaptureRendererCompatibilitySetAsync(
                    rendererObservation,
                    UiLanguage.Thai,
                    rendererCancellation);
                await rendererObservation.WaitForEnglishCapturePermissionAsync(rendererCancellation);
                await runner.CaptureRendererCompatibilitySetAsync(
                    rendererObservation,
                    UiLanguage.English,
                    rendererCancellation);
                await rendererObservation.Completion.WaitAsync(rendererCancellation);
            }
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

        try
        {
            if (primaryFailure is not null && cleanupFailure is ShutdownCleanupException cleanupException)
            {
                RuntimeEvidenceRunner.WriteFailure(
                    options.ReportPath,
                    startedUtc,
                    new StartupTransactionException(primaryFailure, cleanupException),
                    options.ProgressPath);
                exitCode = 2;
            }
            else if (primaryFailure is not null)
            {
                RuntimeEvidenceRunner.WriteFailure(
                    options.ReportPath,
                    startedUtc,
                    primaryFailure,
                    options.ProgressPath);
                exitCode = 2;
            }
            else if (cleanupFailure is not null)
            {
                RuntimeEvidenceRunner.WriteFailure(
                    options.ReportPath,
                    startedUtc,
                    cleanupFailure,
                    options.ProgressPath);
                exitCode = 2;
            }
        }
        finally
        {
            producerBinding?.LanguageChangeTracker?.Dispose();
            if (rendererObservation is not null)
            {
                try
                {
                    await rendererObservation.DisposeAsync();
                }
                catch (Exception exception)
                {
                    RuntimeEvidenceRunner.WriteFailure(
                        options.ReportPath,
                        startedUtc,
                        exception,
                        options.ProgressPath);
                    exitCode = 2;
                }
            }
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
        _dashboardState = null;
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

internal static class RuntimeRenderPolicy
{
    internal const string PolicyId = "software-only-process-wide";
    internal const string ExpectedProcessRenderMode = "SoftwareOnly";
    internal const string StartupPhase = "app-constructor-before-initialize-component";
    internal const string PreFirstWindowPhase = "runtime-evidence-pre-first-window";
    private static readonly object Sync = new();
    private static RuntimeRenderPolicyObservation? _startupObservation;
    private static string _configuredMode = ExpectedProcessRenderMode;

    internal static RuntimeRenderPolicyObservation StartupObservation
    {
        get
        {
            lock (Sync)
            {
                return _startupObservation ?? throw new InvalidOperationException(
                    "The process-wide WPF render policy was not enforced before application composition.");
            }
        }
    }

    internal static void EnforceBeforeFirstWpfComposition(string? requestedMode = null)
    {
        lock (Sync)
        {
            if (_startupObservation is not null)
            {
                _ = ObserveAndRequireConfiguredModeLocked(
                    StartupPhase);
                return;
            }

            _configuredMode = string.Equals(requestedMode, "Hardware", StringComparison.Ordinal)
                ? "Hardware"
                : ExpectedProcessRenderMode;
            RenderOptions.ProcessRenderMode = _configuredMode == "Hardware"
                ? RenderMode.Default
                : RenderMode.SoftwareOnly;
            _startupObservation = ObserveAndRequireConfiguredModeLocked(
                StartupPhase);
        }
    }

    internal static RuntimeRenderPolicyObservation ObserveAndRequireSoftwareOnly(
        string phase)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(phase);
        lock (Sync)
        {
            if (_startupObservation is null)
            {
                throw new InvalidOperationException(
                    "The process-wide WPF render policy was observed before its pre-composition enforcement.");
            }

            if (!string.Equals(_configuredMode, ExpectedProcessRenderMode, StringComparison.Ordinal))
            {
                throw new InvalidOperationException(
                    "SoftwareOnly production observation cannot run in the acceptance-only Hardware comparator process.");
            }

            return ObserveAndRequireConfiguredModeLocked(phase);
        }
    }

    internal static RuntimeRenderPolicyObservation ObserveAndRequireConfiguredMode(string phase)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(phase);
        lock (Sync)
        {
            if (_startupObservation is null)
            {
                throw new InvalidOperationException(
                    "The process-wide WPF render policy was observed before its pre-composition enforcement.");
            }

            return ObserveAndRequireConfiguredModeLocked(phase);
        }
    }

    private static RuntimeRenderPolicyObservation ObserveAndRequireConfiguredModeLocked(
        string phase)
    {
        var observedMode = RenderOptions.ProcessRenderMode;
        var nativeTier = RenderCapability.Tier >> 16;
        var confirmed = _configuredMode == "Hardware"
            ? observedMode == RenderMode.Default && nativeTier > 0 && !Issue10PerformanceTelemetryProducer.IsRemoteSession
            : observedMode == RenderMode.SoftwareOnly;
        var observation = new RuntimeRenderPolicyObservation(
            phase,
            DateTimeOffset.UtcNow,
            observedMode.ToString(),
            nativeTier,
            confirmed);
        if (!confirmed)
        {
            throw new InvalidOperationException(
                $"The process-wide WPF render policy changed during '{phase}': expected {_configuredMode}, observed {observedMode}, tier {nativeTier}, remote={Issue10PerformanceTelemetryProducer.IsRemoteSession}.");
        }

        return observation;
    }
}
