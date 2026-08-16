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
using HerdrOps.App.StateIpc;
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

public sealed record RuntimeProcessResourceMeasurement(
    int ProcessId,
    DateTimeOffset ProcessStartUtc,
    string ExecutablePath,
    string ExecutableSha256,
    bool IdentityStable,
    double AverageCpuPercent,
    double AverageWorkingSetMegabytes,
    double MaximumWorkingSetMegabytes,
    double AveragePrivateMemoryMegabytes,
    double MaximumPrivateMemoryMegabytes);

public sealed record RuntimeResourcePreparation(
    DateTimeOffset ObservedUtc,
    bool DashboardResourcesReleased,
    int RetainedEvidenceWindows,
    int VisibleEvidenceWindows,
    double AppWorkingSetBeforeMegabytes,
    double AppWorkingSetAfterMegabytes,
    double AppPrivateMemoryBeforeMegabytes,
    double AppPrivateMemoryAfterMegabytes,
    double ManagedHeapBeforeMegabytes,
    double ManagedHeapAfterMegabytes);

public sealed record RuntimeResourceMeasurement(
    int DurationSeconds,
    int SampleIntervalMilliseconds,
    int SampleCount,
    int ProcessorCount,
    double CpuTargetPercent,
    double WorkingSetTargetMegabytes,
    double CombinedAverageCpuPercent,
    double CombinedAverageWorkingSetMegabytes,
    double CombinedMaximumWorkingSetMegabytes,
    RuntimeProcessResourceMeasurement App,
    RuntimeProcessResourceMeasurement Core,
    RuntimeResourcePreparation Preparation,
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
    DateTimeOffset DashboardClosedUtc,
    DateTimeOffset DisconnectObservedUtc,
    DateTimeOffset ReconnectObservedUtc,
    long InitialEventCount,
    long PreCloseEventCount,
    long PostCloseEventCount,
    long PreRestartConnectionEpoch,
    long ReconnectedConnectionEpoch,
    long PreRestartBootstrapCount,
    long ReconnectedBootstrapCount,
    long PreRestartDisconnectCount,
    long ReconnectedDisconnectCount,
    bool DisconnectObservedAfterDashboardClose,
    bool ReconnectObservedAfterDashboardClose,
    long EventBBaselineSequence,
    long EventBBaselineEventCount,
    long WidgetLatencyBaselineSequence,
    int WidgetLatencyWarmupSamplesExcluded,
    IReadOnlyList<WidgetUpdateLatencySample> WidgetLatencyWarmupExcludedSamples,
    int WidgetLatencySamples,
    int WidgetLatencyMinimumSamples,
    string WidgetLatencyMeasurement,
    double WidgetLatencyTargetMilliseconds,
    double? WidgetLatencyP95Milliseconds,
    bool WidgetLatencyTargetPassed,
    IReadOnlyList<WidgetUpdateLatencySample> WidgetLatencyIncludedSamples,
    int WidgetLatencyUnsupportedSamplesExcluded,
    IReadOnlyList<WidgetUpdateLatencySample> WidgetLatencyUnsupportedExcludedSamples,
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
    private const int ResourceSampleIntervalMilliseconds = 250;
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

        var latencyWarmup = _state.Widgets.ResetUpdateLatencyMeasurement();
        var widgetLatencyBaselineSequence = _state.CurrentState.LastIngestSequence;

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
        var preRestartConnectionEpoch = _state.CurrentState.ConnectionEpoch;
        var preRestartBootstrapCount = _state.CurrentRuntimeHealth.BootstrapCount;
        var preRestartDisconnectCount = _state.CurrentRuntimeHealth.DisconnectCount;
        _mainWindow.Close();
        var dashboardClosedUtc = DateTimeOffset.UtcNow;
        await Dispatcher.Yield(DispatcherPriority.ApplicationIdle);
        WriteProgress("dashboard-closed-waiting-for-herdr-disconnect", preCloseSequence);
        await WaitUntilAsync(
            () => _state.CurrentRuntimeHealth.LastTransitionUtc > dashboardClosedUtc &&
                  (_state.CurrentRuntimeHealth.DisconnectCount > preRestartDisconnectCount ||
                   string.Equals(
                       _state.CurrentRuntimeHealth.Status,
                       "Reconnecting",
                       StringComparison.Ordinal)),
            deadline,
            "No target Herdr disconnect was observed after the Dashboard closed.",
            cancellationToken);
        var disconnectObservedAfterDashboardClose = true;
        var disconnectObservedUtc = DateTimeOffset.UtcNow;

        WriteProgress("herdr-disconnected-waiting-for-reconnect", _state.CurrentState.LastIngestSequence);
        await WaitUntilAsync(
            () => _state.IsCoreConnected &&
                  _state.IsLive &&
                  _state.CurrentRuntimeHealth.LastTransitionUtc > dashboardClosedUtc &&
                  _state.CurrentState.ConnectionEpoch > preRestartConnectionEpoch &&
                  _state.CurrentRuntimeHealth.BootstrapCount > preRestartBootstrapCount &&
                  _state.CurrentRuntimeHealth.DisconnectCount > preRestartDisconnectCount,
            deadline,
            "The target Herdr session did not reconnect with a new connection epoch and bootstrap after the observed disconnect.",
            cancellationToken);
        var reconnectObservedAfterDashboardClose = true;
        var reconnectObservedUtc = DateTimeOffset.UtcNow;
        var reconnectedConnectionEpoch = _state.CurrentState.ConnectionEpoch;
        var reconnectedBootstrapCount = _state.CurrentRuntimeHealth.BootstrapCount;
        var reconnectedDisconnectCount = _state.CurrentRuntimeHealth.DisconnectCount;
        var eventBBaselineSequence = _state.CurrentState.LastIngestSequence;
        var eventBBaselineEventCount = _state.CurrentRuntimeHealth.EventCount;

        WriteProgress("herdr-reconnected-waiting-for-post-reconnect-update", eventBBaselineSequence);
        await WaitUntilAsync(
            () => _state.IsCoreConnected &&
                  _state.IsLive &&
                  _state.CurrentState.ConnectionEpoch >= reconnectedConnectionEpoch &&
                  _state.CurrentState.LastIngestSequence > eventBBaselineSequence &&
                  _state.CurrentRuntimeHealth.EventCount > eventBBaselineEventCount,
            deadline,
            "No genuine Agent-status update reached the App-owned Widget after the target Herdr reconnect.",
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
        var latencySnapshot = _state.Widgets.UpdateLatencySnapshot;
        var includedLatencySamples = latencySnapshot.Samples
            .Where(IsMeasuredLatencyUpdate)
            .ToArray();
        var unsupportedLatencySamples = latencySnapshot.Samples
            .Where(sample => !IsMeasuredLatencyUpdate(sample))
            .ToArray();
        var latencySamples = includedLatencySamples.Length;
        var latencyP95 = CalculateP95(includedLatencySamples);
        var latencyPassed = latencySamples >= MinimumLatencySamples &&
                            latencyP95 is not null &&
                            latencyP95 <= WidgetLatencyTargetMilliseconds;
        var checksPassed = resources.StateSequenceStable &&
                           resources.RuntimeEventCountStable &&
                           resources.HerdrConnectedThroughoutSample &&
                           resources.CpuTargetPassed &&
                           resources.WorkingSetTargetPassed &&
                           resources.App.IdentityStable &&
                           resources.Core.IdentityStable &&
                           resources.Preparation.DashboardResourcesReleased &&
                           resources.Preparation.RetainedEvidenceWindows == 1 &&
                           resources.Preparation.VisibleEvidenceWindows == 1 &&
                           preCloseEventCount > initialEventCount &&
                           disconnectObservedAfterDashboardClose &&
                           reconnectObservedAfterDashboardClose &&
                           disconnectObservedUtc >= dashboardClosedUtc &&
                           reconnectObservedUtc >= disconnectObservedUtc &&
                           postCloseEventCount > eventBBaselineEventCount &&
                           reconnectedConnectionEpoch > preRestartConnectionEpoch &&
                           reconnectedBootstrapCount > preRestartBootstrapCount &&
                           reconnectedDisconnectCount > preRestartDisconnectCount &&
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
            DashboardClosed: !_mainWindow.IsVisible &&
                             resources.Preparation.DashboardResourcesReleased,
            UpdateObservedAfterDashboardClose: postCloseSequence > preCloseSequence,
            CoreConnectedAfterDashboardClose: _state.IsCoreConnected,
            dashboardClosedUtc,
            disconnectObservedUtc,
            reconnectObservedUtc,
            initialEventCount,
            preCloseEventCount,
            postCloseEventCount,
            preRestartConnectionEpoch,
            reconnectedConnectionEpoch,
            preRestartBootstrapCount,
            reconnectedBootstrapCount,
            preRestartDisconnectCount,
            reconnectedDisconnectCount,
            disconnectObservedAfterDashboardClose,
            reconnectObservedAfterDashboardClose,
            eventBBaselineSequence,
            eventBBaselineEventCount,
            widgetLatencyBaselineSequence,
            latencyWarmup.SampleCount,
            latencyWarmup.Samples,
            latencySamples,
            MinimumLatencySamples,
            WidgetLatencyMeasurement,
            WidgetLatencyTargetMilliseconds,
            latencyP95,
            latencyPassed,
            includedLatencySamples,
            unsupportedLatencySamples.Length,
            unsupportedLatencySamples,
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
        foreach (var window in _widgetWindows.ToArray())
        {
            if (window.IsLoaded || window.IsVisible)
            {
                window.Close();
            }
        }

        _widgetWindows.Clear();
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
                await Dispatcher.Yield(DispatcherPriority.ApplicationIdle);
                _widgetWindows.Remove(window);
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
        var preparation = await PrepareForResourceMeasurementAsync(app, cancellationToken);
        var appIdentity = ObserveProcessIdentity(app);
        var coreIdentity = ObserveProcessIdentity(core);
        app.Refresh();
        core.Refresh();
        var appCpuStart = app.TotalProcessorTime;
        var coreCpuStart = core.TotalProcessorTime;
        var stopwatch = Stopwatch.StartNew();
        var timedSampleCount = checked(
            _options.IdleSeconds * 1000 / ResourceSampleIntervalMilliseconds);
        var sampleCapacity = checked(timedSampleCount + 1);
        var appWorkingSetSamples = new List<long>(sampleCapacity);
        var coreWorkingSetSamples = new List<long>(sampleCapacity);
        var appPrivateMemorySamples = new List<long>(sampleCapacity);
        var corePrivateMemorySamples = new List<long>(sampleCapacity);
        var startSequence = _state.CurrentState.LastIngestSequence;
        var startEventCount = _state.CurrentRuntimeHealth.EventCount;
        var connectedThroughout = _state.IsLive;

        CaptureResourceSample();
        for (var sample = 0; sample < timedSampleCount; sample++)
        {
            await Task.Delay(
                TimeSpan.FromMilliseconds(ResourceSampleIntervalMilliseconds),
                cancellationToken);
            app.Refresh();
            core.Refresh();
            if (app.HasExited || core.HasExited)
            {
                throw new InvalidOperationException(
                    "The App or Core process exited during the resource measurement.");
            }

            CaptureResourceSample();
        }

        stopwatch.Stop();
        app.Refresh();
        core.Refresh();
        var appCpu = ProcessCpuPercent(app.TotalProcessorTime - appCpuStart, stopwatch.Elapsed);
        var coreCpu = ProcessCpuPercent(core.TotalProcessorTime - coreCpuStart, stopwatch.Elapsed);
        var averageCpu = appCpu + coreCpu;
        var combinedWorkingSetSamples = appWorkingSetSamples
            .Zip(coreWorkingSetSamples, (appValue, coreValue) => appValue + coreValue)
            .ToArray();
        var averageWorkingSet = AverageMegabytes(combinedWorkingSetSamples);
        var maximumWorkingSet = MaximumMegabytes(combinedWorkingSetSamples);
        var finishSequence = _state.CurrentState.LastIngestSequence;
        var finishEventCount = _state.CurrentRuntimeHealth.EventCount;
        var appIdentityStable = MatchesProcessIdentity(app, appIdentity);
        var coreIdentityStable = MatchesProcessIdentity(core, coreIdentity);
        return new RuntimeResourceMeasurement(
            _options.IdleSeconds,
            ResourceSampleIntervalMilliseconds,
            appWorkingSetSamples.Count,
            Environment.ProcessorCount,
            CpuTargetPercent,
            WorkingSetTargetMegabytes,
            Math.Round(averageCpu, 3),
            Math.Round(averageWorkingSet, 3),
            Math.Round(maximumWorkingSet, 3),
            new RuntimeProcessResourceMeasurement(
                appIdentity.ProcessId,
                appIdentity.ProcessStartUtc,
                appIdentity.ExecutablePath,
                appIdentity.ExecutableSha256,
                appIdentityStable,
                Math.Round(appCpu, 3),
                Math.Round(AverageMegabytes(appWorkingSetSamples), 3),
                Math.Round(MaximumMegabytes(appWorkingSetSamples), 3),
                Math.Round(AverageMegabytes(appPrivateMemorySamples), 3),
                Math.Round(MaximumMegabytes(appPrivateMemorySamples), 3)),
            new RuntimeProcessResourceMeasurement(
                coreIdentity.ProcessId,
                coreIdentity.ProcessStartUtc,
                coreIdentity.ExecutablePath,
                coreIdentity.ExecutableSha256,
                coreIdentityStable,
                Math.Round(coreCpu, 3),
                Math.Round(AverageMegabytes(coreWorkingSetSamples), 3),
                Math.Round(MaximumMegabytes(coreWorkingSetSamples), 3),
                Math.Round(AverageMegabytes(corePrivateMemorySamples), 3),
                Math.Round(MaximumMegabytes(corePrivateMemorySamples), 3)),
            preparation,
            startSequence == finishSequence,
            startSequence,
            finishSequence,
            startEventCount == finishEventCount,
            startEventCount,
            finishEventCount,
            connectedThroughout,
            averageCpu <= CpuTargetPercent,
            maximumWorkingSet <= WorkingSetTargetMegabytes);

        void CaptureResourceSample()
        {
            appWorkingSetSamples.Add(app.WorkingSet64);
            coreWorkingSetSamples.Add(core.WorkingSet64);
            appPrivateMemorySamples.Add(app.PrivateMemorySize64);
            corePrivateMemorySamples.Add(core.PrivateMemorySize64);
            connectedThroughout &= _state.IsLive;
        }
    }

    private async Task<RuntimeResourcePreparation> PrepareForResourceMeasurementAsync(
        Process app,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        app.Refresh();
        var appWorkingSetBefore = app.WorkingSet64;
        var appPrivateMemoryBefore = app.PrivateMemorySize64;
        var managedHeapBefore = GC.GetTotalMemory(forceFullCollection: false);

        await Dispatcher.Yield(DispatcherPriority.ApplicationIdle);
        GC.Collect(GC.MaxGeneration, GCCollectionMode.Forced, blocking: true, compacting: true);
        GC.WaitForPendingFinalizers();
        GC.Collect(GC.MaxGeneration, GCCollectionMode.Forced, blocking: true, compacting: true);
        await Dispatcher.Yield(DispatcherPriority.ApplicationIdle);

        app.Refresh();
        return new RuntimeResourcePreparation(
            DateTimeOffset.UtcNow,
            _mainWindow.DashboardResourcesReleased,
            _widgetWindows.Count,
            _widgetWindows.Count(window => window.IsVisible),
            Math.Round(ToMegabytes(appWorkingSetBefore), 3),
            Math.Round(ToMegabytes(app.WorkingSet64), 3),
            Math.Round(ToMegabytes(appPrivateMemoryBefore), 3),
            Math.Round(ToMegabytes(app.PrivateMemorySize64), 3),
            Math.Round(ToMegabytes(managedHeapBefore), 3),
            Math.Round(ToMegabytes(GC.GetTotalMemory(forceFullCollection: false)), 3));
    }

    private static double ProcessCpuPercent(TimeSpan processorTime, TimeSpan elapsed) =>
        processorTime.TotalMilliseconds /
        elapsed.TotalMilliseconds /
        Environment.ProcessorCount * 100;

    private static double? CalculateP95(
        IReadOnlyCollection<WidgetUpdateLatencySample> samples)
    {
        if (samples.Count == 0)
        {
            return null;
        }

        var ordered = samples
            .Select(sample => sample.Milliseconds)
            .Order()
            .ToArray();
        var percentileIndex = Math.Max(0, (int)Math.Ceiling(ordered.Length * 0.95) - 1);
        return ordered[percentileIndex];
    }

    private static bool IsMeasuredLatencyUpdate(WidgetUpdateLatencySample sample) =>
        string.Equals(
            sample.UpdateKind,
            HerdrOpsStateUpdateKind.Snapshot.ToString(),
            StringComparison.Ordinal) ||
        string.Equals(
            sample.UpdateKind,
            HerdrOpsStateUpdateKind.Delta.ToString(),
            StringComparison.Ordinal);

    private static double AverageMegabytes(IReadOnlyCollection<long> samples) =>
        ToMegabytes(samples.Average());

    private static double MaximumMegabytes(IReadOnlyCollection<long> samples) =>
        ToMegabytes(samples.Max());

    private static double ToMegabytes(double bytes) => bytes / (1024d * 1024d);

    private static ObservedProcessIdentity ObserveProcessIdentity(Process process)
    {
        process.Refresh();
        if (process.HasExited)
        {
            throw new InvalidOperationException(
                $"Process {process.Id} exited before its resource identity was captured.");
        }

        var executablePath = Path.GetFullPath(
            process.MainModule?.FileName ?? throw new InvalidOperationException(
                $"Process {process.Id} did not expose an executable path."));
        using var executable = File.OpenRead(executablePath);
        return new ObservedProcessIdentity(
            process.Id,
            new DateTimeOffset(process.StartTime.ToUniversalTime()),
            executablePath,
            Convert.ToHexString(SHA256.HashData(executable)));
    }

    private static bool MatchesProcessIdentity(
        Process process,
        ObservedProcessIdentity expected)
    {
        var observed = ObserveProcessIdentity(process);
        return observed.ProcessId == expected.ProcessId &&
               observed.ProcessStartUtc == expected.ProcessStartUtc &&
               string.Equals(
                   observed.ExecutablePath,
                   expected.ExecutablePath,
                   StringComparison.OrdinalIgnoreCase) &&
               string.Equals(
                   observed.ExecutableSha256,
                   expected.ExecutableSha256,
                   StringComparison.Ordinal);
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
            ConnectionEpoch = _state.CurrentState.ConnectionEpoch,
            BootstrapCount = _state.CurrentRuntimeHealth.BootstrapCount,
            EventCount = _state.CurrentRuntimeHealth.EventCount,
            DisconnectCount = _state.CurrentRuntimeHealth.DisconnectCount,
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

    private sealed record ObservedProcessIdentity(
        int ProcessId,
        DateTimeOffset ProcessStartUtc,
        string ExecutablePath,
        string ExecutableSha256);
}
