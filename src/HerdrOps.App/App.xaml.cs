using System.IO;
using System.Windows;
using HerdrOps.App.Live;
using HerdrOps.App.RuntimeEvidence;
using HerdrOps.App.StateIpc;

namespace HerdrOps.App;

/// <summary>
/// Provides application-level design resources for the dashboard and widgets.
/// </summary>
public partial class App : Application
{
    private LiveDashboardRuntime? _runtime;

    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        if (RuntimeEvidenceOptions.IsRequested(e.Args))
        {
            await RunRuntimeEvidenceAsync(e.Args);
            return;
        }

        var state = new LiveDashboardState();
        try
        {
            _runtime = new LiveDashboardRuntime(
                new HerdrOpsStatePipeClient(HerdrOpsStatePipeClientOptions.ForCurrentUser()),
                state,
                new DispatcherLiveDashboardUiScheduler(Dispatcher));
            _runtime.Start();
        }
        catch (Exception exception) when (
            exception is IOException or InvalidOperationException or UnauthorizedAccessException)
        {
            state.MarkOffline(exception, DateTimeOffset.UtcNow);
        }

        var mainWindow = new MainWindow(state);
        MainWindow = mainWindow;
        mainWindow.Show();
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
                    "Runtime evidence mode requires HERDR_ENV=1 and HERDR_SOCKET_PATH from an authorized Herdr pane."),
                options.ProgressPath);
            Shutdown(3);
            return;
        }

        RuntimeEvidenceRunner? runner = null;
        MainWindow? mainWindow = null;
        var exitCode = 2;
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
            RuntimeEvidenceRunner.WriteFailure(
                options.ReportPath,
                startedUtc,
                exception,
                options.ProgressPath);
        }
        finally
        {
            runner?.CloseEvidenceWindows();
            _runtime?.Dispose();
            _runtime = null;
            if (mainWindow?.IsVisible == true)
            {
                mainWindow.Close();
            }
        }

        Shutdown(exitCode);
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _runtime?.Dispose();
        base.OnExit(e);
    }
}
