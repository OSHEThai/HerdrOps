using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using HerdrOps.App.Live;
using HerdrOps.App.Localization;
using HerdrOps.App.Widgets;
using HerdrOps.Contracts.StateIpc;

namespace HerdrOps.App.RuntimeEvidence;

public sealed record RuntimeEvidenceCapture(
    string Name,
    string Path,
    string Sha256,
    int PixelWidth,
    int PixelHeight,
    long StateSequence,
    string StateSha256);

public sealed record RuntimeResourceMeasurement(
    int DurationSeconds,
    int ProcessorCount,
    double CombinedAverageCpuPercent,
    double CombinedAverageWorkingSetMegabytes,
    double CombinedMaximumWorkingSetMegabytes,
    bool StateSequenceStable,
    long StartSequence,
    long FinishSequence,
    bool RuntimeEventCountStable,
    long StartEventCount,
    long FinishEventCount,
    bool HerdrConnectedThroughoutSample,
    bool CpuTargetPassed,
    bool WorkingSetTargetPassed);

public sealed record AppRuntimeEvidenceReport(
    string EvidenceClassification,
    bool CoreStateObserved,
    bool SessionControlInvoked,
    DateTimeOffset StartedUtc,
    DateTimeOffset FinishedUtc,
    string HostName,
    string OperatingSystem,
    int AppProcessId,
    int CoreProcessId,
    string Language,
    TimeSpan TimeToInitialLiveState,
    long InitialSequence,
    string InitialStateSha256,
    long PreCloseSequence,
    string PreCloseStateSha256,
    long PostCloseSequence,
    string PostCloseStateSha256,
    bool UpdateObservedBeforeDashboardClose,
    bool DashboardClosed,
    bool UpdateObservedAfterDashboardClose,
    bool CoreConnectedAfterDashboardClose,
    long InitialEventCount,
    long PreCloseEventCount,
    long PostCloseEventCount,
    int WidgetLatencySamples,
    string WidgetLatencyMeasurement,
    double? WidgetLatencyP95Milliseconds,
    bool WidgetLatencyTargetPassed,
    RuntimeResourceMeasurement ResourceMeasurement,
    IReadOnlyList<RuntimeEvidenceCapture> Captures,
    HerdrRuntimeHealthContract FinalRuntimeHealth,
    HerdrSessionStateContract FinalState,
    bool CompositeCandidateChecksPassed,
    string Message);

public sealed class RuntimeEvidenceRunner(
    LiveDashboardState state,
    MainWindow mainWindow,
    RuntimeEvidenceOptions options)
{
    private const double CpuTargetPercent = 1;
    private const double WorkingSetTargetMegabytes = 180;
    private const double WidgetLatencyTargetMilliseconds = 250;
    private const int MinimumLatencySamples = 3;
    private const string WidgetLatencyMeasurement =
        "CoreAcceptedStateUtcToWpfStateApplied";

    private static readonly JsonSerializerOptions SerializerOptions = new()
    {
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter() },
    };

    private readonly LiveDashboardState _state = state ?? throw new ArgumentNullException(nameof(state));
    private readonly MainWindow _mainWindow = mainWindow ?? throw new ArgumentNullException(nameof(mainWindow));
    private readonly RuntimeEvidenceOptions _options = options ?? throw new ArgumentNullException(nameof(options));
    private readonly List<RuntimeEvidenceCapture> _captures = [];
    private readonly List<WidgetWindow> _widgetWindows = [];

    public async Task<AppRuntimeEvidenceReport> RunAsync(CancellationToken cancellationToken = default)
    {
        var startedUtc = DateTimeOffset.UtcNow;
        var deadline = startedUtc.AddSeconds(_options.TimeoutSeconds);
        Directory.CreateDirectory(_options.CaptureDirectory);
        UiLanguageService.Shared.SetLanguage(_options.Language);
        _state.RefreshLanguage();
        WriteProgress("waiting-for-live-state", _state.CurrentState.LastIngestSequence);
        await WaitUntilAsync(
            () => _state.IsCoreConnected &&
                  _state.IsLive &&
                  _state.CurrentState.LastIngestSequence > 0,
            deadline,
            "No live Herdr state reached the App before the runtime-evidence timeout.",
            cancellationToken);

        var initialLiveUtc = DateTimeOffset.UtcNow;
        var initialSequence = _state.CurrentState.LastIngestSequence;
        var initialEventCount = _state.CurrentRuntimeHealth.EventCount;
        var initialStateHash = CurrentStateHash();
        WriteProgress("capturing-live-dashboard-and-widgets", initialSequence);
        await CaptureInitialSurfacesAsync(initialStateHash, cancellationToken);
        if (!string.Equals(initialStateHash, CurrentStateHash(), StringComparison.Ordinal))
        {
            throw new InvalidOperationException(
                "The live state changed while the initial Dashboard and Widget captures were being rendered; rerun for one coherent snapshot.");
        }

        WriteProgress("waiting-for-pre-close-update", initialSequence);
        await WaitUntilAsync(
            () => _state.IsLive &&
                  _state.CurrentState.LastIngestSequence > initialSequence &&
                  _state.CurrentRuntimeHealth.EventCount > initialEventCount,
            deadline,
            "No live state update was observed before closing the Dashboard.",
            cancellationToken);
        var preCloseSequence = _state.CurrentState.LastIngestSequence;
        var preCloseEventCount = _state.CurrentRuntimeHealth.EventCount;
        var preCloseStateHash = CurrentStateHash();
        await CaptureDashboardPageAsync(
            index: 0,
            "dashboard-overview-after-event.png",
            cancellationToken);

        var verticalWidget = _widgetWindows.Single(window =>
            window.Descriptor.Variant == WidgetVariant.FloatingVertical);
        _mainWindow.Close();
        await Dispatcher.Yield(DispatcherPriority.ApplicationIdle);
        WriteProgress("dashboard-closed-waiting-for-next-update", preCloseSequence);
        await WaitUntilAsync(
            () => _state.IsCoreConnected &&
                  _state.IsLive &&
                  _state.CurrentState.LastIngestSequence > preCloseSequence &&
                  _state.CurrentRuntimeHealth.EventCount > preCloseEventCount,
            deadline,
            "No live state update reached the App-owned Widget after the Dashboard closed.",
            cancellationToken);
        var postCloseSequence = _state.CurrentState.LastIngestSequence;
        var postCloseEventCount = _state.CurrentRuntimeHealth.EventCount;
        var postCloseStateHash = CurrentStateHash();
        await CaptureWindowAsync(
            verticalWidget,
            "widget-floating-vertical-after-dashboard-close.png",
            cancellationToken);

        WriteProgress("measuring-idle-resources", postCloseSequence);
        var resources = await MeasureResourcesAsync(cancellationToken);
        var latencySamples = _state.Widgets.UpdateSampleCount;
        var latencyP95 = _state.Widgets.P95UpdateLatencyMilliseconds;
        var latencyPassed = latencySamples >= MinimumLatencySamples &&
                            latencyP95 is not null &&
                            latencyP95 <= WidgetLatencyTargetMilliseconds;
        var checksPassed = resources.StateSequenceStable &&
                           resources.RuntimeEventCountStable &&
                           resources.HerdrConnectedThroughoutSample &&
                           resources.CpuTargetPassed &&
                           resources.WorkingSetTargetPassed &&
                           preCloseEventCount > initialEventCount &&
                           postCloseEventCount > preCloseEventCount &&
                           latencyPassed &&
                           _captures.Count >= 8;
        var report = new AppRuntimeEvidenceReport(
            "RuntimeCandidate",
            CoreStateObserved: true,
            SessionControlInvoked: false,
            startedUtc,
            DateTimeOffset.UtcNow,
            Environment.MachineName,
            Environment.OSVersion.VersionString,
            Environment.ProcessId,
            _options.CoreProcessId,
            _options.Language.ToString(),
            initialLiveUtc - startedUtc,
            initialSequence,
            initialStateHash,
            preCloseSequence,
            preCloseStateHash,
            postCloseSequence,
            postCloseStateHash,
            UpdateObservedBeforeDashboardClose: preCloseSequence > initialSequence,
            DashboardClosed: !_mainWindow.IsVisible,
            UpdateObservedAfterDashboardClose: postCloseSequence > preCloseSequence,
            CoreConnectedAfterDashboardClose: _state.IsCoreConnected,
            initialEventCount,
            preCloseEventCount,
            postCloseEventCount,
            latencySamples,
            WidgetLatencyMeasurement,
            latencyP95,
            latencyPassed,
            resources,
            _captures.ToArray(),
            _state.CurrentRuntimeHealth,
            _state.CurrentState,
            checksPassed,
            checksPassed
                ? "The production WPF views and Widgets consumed actual Core state through the App-wide subscription. Composite Runtime credit still requires the matching exact-Herdr Core report."
                : "One or more App runtime candidate checks failed; this report does not independently earn Runtime credit.");
        WriteJsonAtomically(_options.ReportPath, report);
        WriteProgress("complete", postCloseSequence);
        return report;
    }

    public void CloseEvidenceWindows()
    {
        foreach (var window in _widgetWindows.Where(window => window.IsVisible).ToArray())
        {
            window.Close();
        }
    }

    public static void WriteFailure(
        string reportPath,
        DateTimeOffset startedUtc,
        Exception exception)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(reportPath);
        ArgumentNullException.ThrowIfNull(exception);
        WriteJsonAtomically(reportPath, new
        {
            EvidenceClassification = "NoRuntimeCredit",
            CoreStateObserved = false,
            SessionControlInvoked = false,
            StartedUtc = startedUtc,
            FinishedUtc = DateTimeOffset.UtcNow,
            ErrorType = exception.GetType().Name,
            exception.Message,
        });
    }

    private async Task CaptureInitialSurfacesAsync(
        string expectedStateHash,
        CancellationToken cancellationToken)
    {
        await CaptureDashboardPageAsync(0, "dashboard-overview.png", cancellationToken);
        await CaptureDashboardPageAsync(1, "dashboard-live-organization.png", cancellationToken);
        await CaptureDashboardPageAsync(4, "dashboard-agent-detail.png", cancellationToken);

        foreach (var variant in new[]
                 {
                     WidgetVariant.Compact,
                     WidgetVariant.Normal,
                     WidgetVariant.FloatingVertical,
                 })
        {
            var descriptor = WidgetCatalog.Get(variant);
            var window = new WidgetWindow(descriptor, _state.Widgets)
            {
                ShowActivated = false,
            };
            _widgetWindows.Add(window);
            window.Show();
            await Dispatcher.Yield(DispatcherPriority.ApplicationIdle);
            var fileName = variant switch
            {
                WidgetVariant.Compact => "widget-compact.png",
                WidgetVariant.Normal => "widget-normal.png",
                WidgetVariant.FloatingVertical => "widget-floating-vertical.png",
                _ => throw new InvalidOperationException("Unexpected runtime Widget variant."),
            };
            await CaptureWindowAsync(window, fileName, cancellationToken);
            if (variant != WidgetVariant.FloatingVertical)
            {
                window.Close();
            }
        }

        if (!string.Equals(expectedStateHash, CurrentStateHash(), StringComparison.Ordinal))
        {
            throw new InvalidOperationException(
                "Initial WPF captures did not remain bound to one coherent Core state hash.");
        }
    }

    private async Task CaptureDashboardPageAsync(
        int index,
        string fileName,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        _mainWindow.Shell.Navigation.SelectedIndex = index;
        _mainWindow.UpdateLayout();
        await Dispatcher.Yield(DispatcherPriority.ApplicationIdle);
        SaveVisual(_mainWindow.Shell, fileName);
    }

    private async Task CaptureWindowAsync(
        Window window,
        string fileName,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        window.UpdateLayout();
        await Dispatcher.Yield(DispatcherPriority.ApplicationIdle);
        var visual = window.Content as FrameworkElement ?? window;
        SaveVisual(visual, fileName);
    }

    private void SaveVisual(FrameworkElement visual, string fileName)
    {
        visual.UpdateLayout();
        var width = checked((int)Math.Ceiling(visual.ActualWidth));
        var height = checked((int)Math.Ceiling(visual.ActualHeight));
        if (width <= 0 || height <= 0)
        {
            throw new InvalidOperationException(
                $"Runtime capture '{fileName}' has no laid-out WPF surface.");
        }

        var bitmap = new RenderTargetBitmap(width, height, 96, 96, PixelFormats.Pbgra32);
        bitmap.Render(visual);
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        var path = Path.Combine(_options.CaptureDirectory, fileName);
        using (var output = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.None))
        {
            encoder.Save(output);
            if (output.Length <= 4_000)
            {
                throw new InvalidOperationException(
                    $"Runtime capture '{fileName}' is unexpectedly small ({output.Length} bytes).");
            }
        }

        _captures.Add(new RuntimeEvidenceCapture(
            Path.GetFileNameWithoutExtension(fileName),
            path,
            Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(path))),
            width,
            height,
            _state.CurrentState.LastIngestSequence,
            CurrentStateHash()));
    }

    private async Task<RuntimeResourceMeasurement> MeasureResourcesAsync(
        CancellationToken cancellationToken)
    {
        using var app = Process.GetCurrentProcess();
        using var core = Process.GetProcessById(_options.CoreProcessId);
        app.Refresh();
        core.Refresh();
        var appCpuStart = app.TotalProcessorTime;
        var coreCpuStart = core.TotalProcessorTime;
        var stopwatch = Stopwatch.StartNew();
        var workingSetSamples = new List<long>(_options.IdleSeconds);
        var startSequence = _state.CurrentState.LastIngestSequence;
        var startEventCount = _state.CurrentRuntimeHealth.EventCount;
        var connectedThroughout = _state.IsLive;
        for (var second = 0; second < _options.IdleSeconds; second++)
        {
            await Task.Delay(TimeSpan.FromSeconds(1), cancellationToken);
            app.Refresh();
            core.Refresh();
            if (app.HasExited || core.HasExited)
            {
                throw new InvalidOperationException(
                    "The App or Core process exited during the resource measurement.");
            }

            workingSetSamples.Add(app.WorkingSet64 + core.WorkingSet64);
            connectedThroughout &= _state.IsLive;
        }

        stopwatch.Stop();
        app.Refresh();
        core.Refresh();
        var cpu = (app.TotalProcessorTime - appCpuStart) +
                  (core.TotalProcessorTime - coreCpuStart);
        var averageCpu = cpu.TotalMilliseconds /
                         stopwatch.Elapsed.TotalMilliseconds /
                         Environment.ProcessorCount * 100;
        var megabyte = 1024d * 1024d;
        var averageWorkingSet = workingSetSamples.Average() / megabyte;
        var maximumWorkingSet = workingSetSamples.Max() / megabyte;
        var finishSequence = _state.CurrentState.LastIngestSequence;
        var finishEventCount = _state.CurrentRuntimeHealth.EventCount;
        return new RuntimeResourceMeasurement(
            _options.IdleSeconds,
            Environment.ProcessorCount,
            Math.Round(averageCpu, 3),
            Math.Round(averageWorkingSet, 3),
            Math.Round(maximumWorkingSet, 3),
            startSequence == finishSequence,
            startSequence,
            finishSequence,
            startEventCount == finishEventCount,
            startEventCount,
            finishEventCount,
            connectedThroughout,
            averageCpu <= CpuTargetPercent,
            maximumWorkingSet <= WorkingSetTargetMegabytes);
    }

    private async Task WaitUntilAsync(
        Func<bool> predicate,
        DateTimeOffset deadline,
        string timeoutMessage,
        CancellationToken cancellationToken)
    {
        while (!predicate())
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (DateTimeOffset.UtcNow >= deadline)
            {
                throw new TimeoutException(timeoutMessage);
            }

            await Task.Delay(100, cancellationToken);
        }
    }

    private string CurrentStateHash() =>
        HerdrOpsStateIpcJson.ComputeSha256(_state.CurrentState);

    private void WriteProgress(string phase, long sequence) =>
        WriteJsonAtomically(_options.ProgressPath, new
        {
            Phase = phase,
            ObservedUtc = DateTimeOffset.UtcNow,
            Sequence = sequence,
            RuntimeStatus = _state.CurrentRuntimeHealth.Status,
        });

    private static void WriteJsonAtomically<T>(string path, T value)
    {
        var directory = Path.GetDirectoryName(Path.GetFullPath(path)) ??
            throw new InvalidOperationException("Runtime evidence output has no parent directory.");
        Directory.CreateDirectory(directory);
        var temporaryPath = Path.Combine(
            directory,
            $".{Path.GetFileName(path)}.{Guid.NewGuid():N}.tmp");
        try
        {
            var json = JsonSerializer.Serialize(value, SerializerOptions) + Environment.NewLine;
            File.WriteAllText(temporaryPath, json, new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
            File.Move(temporaryPath, path, overwrite: true);
        }
        finally
        {
            if (File.Exists(temporaryPath))
            {
                File.Delete(temporaryPath);
            }
        }
    }
}
