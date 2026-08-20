using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Runtime;
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

public sealed record RuntimeEvidenceProgress(
    int Ordinal,
    string Phase,
    DateTimeOffset ObservedUtc,
    long Sequence,
    bool IsCoreConnected,
    bool IsLive,
    string RuntimeStatus,
    DateTimeOffset LastTransitionUtc,
    DateTimeOffset? LastAcceptedStateUtc,
    long ConnectionEpoch,
    long BootstrapCount,
    long EventCount,
    long DisconnectCount,
    long ReconciliationCount,
    string StateSha256,
    string PreviousEntrySha256,
    string CanonicalPayload,
    string EntrySha256);

public sealed record RuntimeStateFingerprint(
    bool IsCoreConnected,
    bool IsLive,
    string RuntimeStatus,
    DateTimeOffset LastTransitionUtc,
    DateTimeOffset? LastAcceptedStateUtc,
    long ConnectionEpoch,
    long LastIngestSequence,
    long BootstrapCount,
    long EventCount,
    long DisconnectCount,
    long ReconciliationCount,
    string StateSha256);

public sealed record RuntimeFingerprintChange(
    DateTimeOffset ObservedUtc,
    RuntimeStateFingerprint Baseline,
    RuntimeStateFingerprint Current);

public sealed record RuntimeAgentStatusChange(
    string TerminalId,
    string WorkspaceId,
    string TabId,
    string PaneId,
    string PreviousStatus,
    string CurrentStatus,
    ulong PreviousRevision,
    ulong CurrentRevision,
    ulong PreviousStateChangeSequence,
    ulong CurrentStateChangeSequence)
{
    public string? PreviousWorkspaceId { get; init; }

    public string? PreviousTabId { get; init; }

    public string? PreviousPaneId { get; init; }

    public string? PreviousAgentKind { get; init; }

    public string? CurrentAgentKind { get; init; }

    public string? PreviousAgentName { get; init; }

    public string? CurrentAgentName { get; init; }
}

public sealed record RuntimeAgentStatusTransitionEvidence(
    DateTimeOffset PhaseEnteredUtc,
    DateTimeOffset ObservedUtc,
    string AcceptedEventKind,
    string AdmissionPath,
    long BaselineConnectionEpoch,
    bool CurrentIsCoreConnected,
    bool CurrentIsLive,
    string CurrentRuntimeStatus,
    long BaselineSequence,
    long CurrentSequence,
    long BaselineEventCount,
    long CurrentEventCount,
    long BaselineBootstrapCount,
    long CurrentBootstrapCount,
    long BaselineDisconnectCount,
    long CurrentDisconnectCount,
    long BaselineReconciliationCount,
    long CurrentReconciliationCount,
    string BaselineStateSha256,
    string CurrentStateSha256,
    string BaselineAgentTopologySha256,
    string CurrentAgentTopologySha256,
    string BaselineAgentStatusStateSha256,
    string CurrentAgentStatusStateSha256,
    long ConnectionEpoch,
    IReadOnlyList<RuntimeAgentStatusChange> Changes)
{
    public int ChangeCount => Changes.Count;
}

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
    bool ManagedCaptureCleanupAttempted,
    bool ManagedCaptureCleanupCompleted,
    int TrackedCaptureBitmapCount,
    int ReleasedCaptureBitmapCount,
    double AppWorkingSetBeforeMegabytes,
    double AppWorkingSetAfterMegabytes,
    double AppPrivateMemoryBeforeMegabytes,
    double AppPrivateMemoryAfterMegabytes,
    double ManagedHeapBeforeMegabytes,
    double ManagedHeapAfterMegabytes);

public sealed record RuntimeIdleQuiescence(
    DateTimeOffset StartedUtc,
    DateTimeOffset StableSinceUtc,
    DateTimeOffset ReachedUtc,
    int RequiredStableSeconds,
    RuntimeStateFingerprint InitialFingerprint,
    RuntimeStateFingerprint StableFingerprint,
    IReadOnlyList<RuntimeIdleQuiescenceReset> Resets)
{
    public int ResetCount => Resets.Count;

    public long InitialSequence => InitialFingerprint.LastIngestSequence;

    public long InitialEventCount => InitialFingerprint.EventCount;

    public long StableSequence => StableFingerprint.LastIngestSequence;

    public long StableEventCount => StableFingerprint.EventCount;
}

public sealed record RuntimeIdleQuiescenceReset(
    DateTimeOffset ObservedUtc,
    string Reason,
    RuntimeStateFingerprint PreviousFingerprint,
    RuntimeStateFingerprint CurrentFingerprint)
{
    public long PreviousSequence => PreviousFingerprint.LastIngestSequence;

    public long CurrentSequence => CurrentFingerprint.LastIngestSequence;

    public long PreviousEventCount => PreviousFingerprint.EventCount;

    public long CurrentEventCount => CurrentFingerprint.EventCount;
}

public sealed class RuntimeIdleQuiescenceTracker(int requiredStableSeconds)
{
    private readonly TimeSpan _requiredStableDuration = requiredStableSeconds > 0
        ? TimeSpan.FromSeconds(requiredStableSeconds)
        : throw new ArgumentOutOfRangeException(nameof(requiredStableSeconds));
    private readonly List<RuntimeIdleQuiescenceReset> _resets = [];
    private DateTimeOffset _startedUtc;
    private DateTimeOffset _stableSinceUtc;
    private RuntimeStateFingerprint? _initialFingerprint;
    private RuntimeStateFingerprint? _observedFingerprint;
    private DateTimeOffset _lastObservedUtc;
    private bool _initialized;

    public RuntimeIdleQuiescence? Observe(
        DateTimeOffset observedUtc,
        RuntimeStateFingerprint fingerprint)
    {
        ArgumentNullException.ThrowIfNull(fingerprint);
        if (!_initialized)
        {
            _initialized = true;
            _startedUtc = observedUtc;
            _stableSinceUtc = observedUtc;
            _initialFingerprint = fingerprint;
            _observedFingerprint = fingerprint;
            _lastObservedUtc = observedUtc;
            return null;
        }

        if (observedUtc < _lastObservedUtc)
        {
            throw new ArgumentOutOfRangeException(
                nameof(observedUtc),
                "Quiescence observations cannot move backward in time.");
        }

        _lastObservedUtc = observedUtc;

        if (!fingerprint.IsCoreConnected || !fingerprint.IsLive)
        {
            if (_observedFingerprint!.IsCoreConnected && _observedFingerprint.IsLive)
            {
                Reset(observedUtc, "LiveStateLost", fingerprint);
            }
            else if (!_observedFingerprint.Equals(fingerprint))
            {
                Reset(observedUtc, "NonLiveFingerprintChanged", fingerprint);
            }

            return null;
        }

        if (!_observedFingerprint!.IsCoreConnected || !_observedFingerprint.IsLive)
        {
            Reset(observedUtc, "LiveStateRestored", fingerprint);
            return null;
        }

        if (!_observedFingerprint.Equals(fingerprint))
        {
            Reset(observedUtc, "RuntimeFingerprintChanged", fingerprint);
            return null;
        }

        if (observedUtc - _stableSinceUtc < _requiredStableDuration)
        {
            return null;
        }

        return new RuntimeIdleQuiescence(
            _startedUtc,
            _stableSinceUtc,
            observedUtc,
            (int)_requiredStableDuration.TotalSeconds,
            _initialFingerprint!,
            _observedFingerprint,
            _resets.ToArray());
    }

    private void Reset(
        DateTimeOffset observedUtc,
        string reason,
        RuntimeStateFingerprint fingerprint)
    {
        _resets.Add(new RuntimeIdleQuiescenceReset(
            observedUtc,
            reason,
            _observedFingerprint!,
            fingerprint));
        _observedFingerprint = fingerprint;
        _stableSinceUtc = observedUtc;
    }
}

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
    RuntimeStateFingerprint StartFingerprint,
    RuntimeStateFingerprint FinishFingerprint,
    bool RuntimeFingerprintStable,
    RuntimeFingerprintChange? FirstFingerprintChange,
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
    RuntimeAgentStatusTransitionEvidence EventA,
    RuntimeAgentStatusTransitionEvidence EventB,
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
    RuntimeIdleQuiescence IdleQuiescence,
    RuntimeResourceMeasurement ResourceMeasurement,
    IReadOnlyList<RuntimeEvidenceCapture> Captures,
    HerdrRuntimeHealthContract FinalRuntimeHealth,
    HerdrSessionStateContract FinalState,
    IReadOnlyList<string> FailedCandidateChecks,
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
    private const int IdleQuiescenceSeconds = 5;
    private const int IdleQuiescencePollMilliseconds = 100;
    private const int ResourceSampleIntervalMilliseconds = 250;
    private const string EmptySha256 =
        "0000000000000000000000000000000000000000000000000000000000000000";
    private const string WidgetLatencyMeasurement =
        "CoreAcceptedStateUtcToWpfStateApplied";
    private const string AcceptedAgentStatusEventKind =
        "pane.agent_status_changed";
    public const string DirectEventAdmissionPath = "direct-event";
    public const string SnapshotBeforeEventAdmissionPath = "snapshot-before-event";

    private static readonly JsonSerializerOptions SerializerOptions = new()
    {
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter() },
    };
    private static readonly JsonSerializerOptions CompactSerializerOptions = new(SerializerOptions)
    {
        WriteIndented = false,
    };

    private readonly LiveDashboardState _state = state ?? throw new ArgumentNullException(nameof(state));
    private readonly MainWindow _mainWindow = mainWindow ?? throw new ArgumentNullException(nameof(mainWindow));
    private readonly RuntimeEvidenceOptions _options = options ?? throw new ArgumentNullException(nameof(options));
    private readonly List<RuntimeEvidenceCapture> _captures = [];
    private readonly List<WeakReference<RenderTargetBitmap>> _captureBitmapReferences = [];
    private readonly List<RuntimeEvidenceProgress> _progressHistory = [];
    private readonly List<WidgetWindow> _widgetWindows = [];

    public async Task<AppRuntimeEvidenceReport> RunAsync(CancellationToken cancellationToken = default)
    {
        var startedUtc = DateTimeOffset.UtcNow;
        var deadline = startedUtc.AddSeconds(_options.TimeoutSeconds);
        Directory.CreateDirectory(_options.CaptureDirectory);
        Directory.CreateDirectory(
            Path.GetDirectoryName(Path.GetFullPath(_options.ProgressPath)) ??
            throw new InvalidOperationException(
                "Runtime progress output has no parent directory."));
        if (File.Exists(ProgressHistoryPath))
        {
            throw new InvalidOperationException(
                $"Runtime progress history already exists: {ProgressHistoryPath}");
        }
        UiLanguageService.Shared.SetLanguage(_options.Language);
        _state.RefreshLanguage();
        _ = WriteProgress("waiting-for-live-state");
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
        _ = WriteProgress("capturing-live-dashboard-and-widgets");
        await CaptureInitialSurfacesAsync(initialStateHash, cancellationToken);
        if (!string.Equals(initialStateHash, CurrentStateHash(), StringComparison.Ordinal))
        {
            throw new InvalidOperationException(
                "The live state changed while the initial Dashboard and Widget captures were being rendered; rerun for one coherent snapshot.");
        }

        var latencyWarmup = _state.Widgets.ResetUpdateLatencyMeasurement();
        var widgetLatencyBaselineSequence = _state.CurrentState.LastIngestSequence;

        var eventAProgress = WriteProgress(
            "waiting-for-pre-close-update");
        var eventABaselineState = _state.CurrentState;
        var eventA = await WaitForAgentStatusTransitionAsync(
            eventABaselineState,
            eventAProgress,
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
        _ = WriteProgress("dashboard-closed-waiting-for-herdr-disconnect");
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

        _ = WriteProgress("herdr-disconnected-waiting-for-reconnect");
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
        var eventBProgress = WriteProgress(
            "herdr-reconnected-waiting-for-post-reconnect-update");
        var eventBBaselineState = _state.CurrentState;
        var eventBBaselineSequence = eventBBaselineState.LastIngestSequence;
        var eventBBaselineEventCount = eventBProgress.EventCount;
        var eventB = await WaitForAgentStatusTransitionAsync(
            eventBBaselineState,
            eventBProgress,
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

        _ = WriteProgress("waiting-for-idle-stability");
        var idleQuiescence = await WaitForIdleQuiescenceAsync(deadline, cancellationToken);
        _ = WriteProgress("measuring-idle-resources");
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
        var candidateChecks = new (string Name, bool Passed)[]
        {
            ("IdleStateSequenceStable", resources.StateSequenceStable),
            ("IdleRuntimeEventCountStable", resources.RuntimeEventCountStable),
            ("IdleRuntimeFingerprintStable", resources.RuntimeFingerprintStable),
            ("HerdrConnectedThroughoutIdleSample", resources.HerdrConnectedThroughoutSample),
            ("IdleCpuTargetPassed", resources.CpuTargetPassed),
            ("IdleWorkingSetTargetPassed", resources.WorkingSetTargetPassed),
            ("AppProcessIdentityStable", resources.App.IdentityStable),
            ("CoreProcessIdentityStable", resources.Core.IdentityStable),
            ("DashboardResourcesReleased", resources.Preparation.DashboardResourcesReleased),
            ("OneEvidenceWindowRetained", resources.Preparation.RetainedEvidenceWindows == 1),
            ("OneEvidenceWindowVisible", resources.Preparation.VisibleEvidenceWindows == 1),
            ("ManagedCaptureCleanupAttempted", resources.Preparation.ManagedCaptureCleanupAttempted),
            ("ManagedCaptureCleanupCompleted", resources.Preparation.ManagedCaptureCleanupCompleted),
            ("IdleSequenceMatchesQuiescence", resources.StartSequence == idleQuiescence.StableSequence),
            ("IdleEventCountMatchesQuiescence", resources.StartEventCount == idleQuiescence.StableEventCount),
            ("IdleFingerprintMatchesQuiescence", resources.StartFingerprint == idleQuiescence.StableFingerprint),
            ("EventAObserved", eventA.ChangeCount > 0),
            ("EventAIsOneAcceptedAgentStatusEvent", IsExactAgentStatusEvent(eventA)),
            ("DisconnectObservedAfterDashboardClose", disconnectObservedAfterDashboardClose),
            ("ReconnectObservedAfterDashboardClose", reconnectObservedAfterDashboardClose),
            ("DisconnectTimestampOrdered", disconnectObservedUtc >= dashboardClosedUtc),
            ("ReconnectTimestampOrdered", reconnectObservedUtc >= disconnectObservedUtc),
            ("EventBObserved", eventB.ChangeCount > 0),
            ("EventBIsOneAcceptedAgentStatusEvent", IsExactAgentStatusEvent(eventB)),
            ("ConnectionEpochAdvanced", reconnectedConnectionEpoch > preRestartConnectionEpoch),
            ("BootstrapCountAdvanced", reconnectedBootstrapCount > preRestartBootstrapCount),
            ("DisconnectCountAdvanced", reconnectedDisconnectCount > preRestartDisconnectCount),
            ("WidgetLatencyTargetPassed", latencyPassed),
            ("RequiredCapturesPresent", _captures.Count >= 8),
        };
        var failedCandidateChecks = candidateChecks
            .Where(check => !check.Passed)
            .Select(check => check.Name)
            .ToArray();
        var checksPassed = failedCandidateChecks.Length == 0;
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
            eventA,
            eventB,
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
            idleQuiescence,
            resources,
            _captures.ToArray(),
            _state.CurrentRuntimeHealth,
            _state.CurrentState,
            failedCandidateChecks,
            checksPassed,
            checksPassed
                ? "The production WPF views and Widgets consumed actual Core state through the App-wide subscription. Composite Runtime credit still requires the matching exact-Herdr Core report."
                : "One or more App runtime candidate checks failed; this report does not independently earn Runtime credit.");
        WriteJsonAtomically(_options.ReportPath, report);
        _ = WriteProgress("complete");
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
        Exception exception,
        string? progressPath = null)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(reportPath);
        ArgumentNullException.ThrowIfNull(exception);
        var progressEvidence = CaptureFailureProgress(progressPath);
        WriteJsonAtomically(reportPath, new
        {
            EvidenceClassification = "NoRuntimeCredit",
            progressEvidence.CoreStateObserved,
            SessionControlInvoked = false,
            StartedUtc = startedUtc,
            FinishedUtc = DateTimeOffset.UtcNow,
            ErrorType = exception.GetType().Name,
            exception.Message,
            PartialProgress = progressEvidence,
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
        _captureBitmapReferences.Add(new WeakReference<RenderTargetBitmap>(bitmap));
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

        using var capture = File.OpenRead(path);
        _captures.Add(new RuntimeEvidenceCapture(
            Path.GetFileNameWithoutExtension(fileName),
            path,
            Convert.ToHexString(SHA256.HashData(capture)),
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
        var startFingerprint = CurrentFingerprint();
        RuntimeFingerprintChange? firstFingerprintChange = null;
        var connectedThroughout =
            startFingerprint.IsCoreConnected && startFingerprint.IsLive;

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
        var finishFingerprint = CurrentFingerprint();
        if (firstFingerprintChange is null &&
            !finishFingerprint.Equals(startFingerprint))
        {
            firstFingerprintChange = new RuntimeFingerprintChange(
                DateTimeOffset.UtcNow,
                startFingerprint,
                finishFingerprint);
        }

        var runtimeFingerprintStable = firstFingerprintChange is null;
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
            startFingerprint.LastIngestSequence == finishFingerprint.LastIngestSequence,
            startFingerprint.LastIngestSequence,
            finishFingerprint.LastIngestSequence,
            startFingerprint.EventCount == finishFingerprint.EventCount,
            startFingerprint.EventCount,
            finishFingerprint.EventCount,
            startFingerprint,
            finishFingerprint,
            runtimeFingerprintStable,
            firstFingerprintChange,
            connectedThroughout,
            averageCpu <= CpuTargetPercent,
            maximumWorkingSet <= WorkingSetTargetMegabytes);

        void CaptureResourceSample()
        {
            appWorkingSetSamples.Add(app.WorkingSet64);
            coreWorkingSetSamples.Add(core.WorkingSet64);
            appPrivateMemorySamples.Add(app.PrivateMemorySize64);
            corePrivateMemorySamples.Add(core.PrivateMemorySize64);
            var observedUtc = DateTimeOffset.UtcNow;
            var fingerprint = CurrentFingerprint();
            connectedThroughout &=
                fingerprint.IsCoreConnected && fingerprint.IsLive;
            if (firstFingerprintChange is null &&
                !fingerprint.Equals(startFingerprint))
            {
                firstFingerprintChange = new RuntimeFingerprintChange(
                    observedUtc,
                    startFingerprint,
                    fingerprint);
            }
        }
    }

    private async Task<RuntimeResourcePreparation> PrepareForResourceMeasurementAsync(
        Process app,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        app.Refresh();
        var workingSetBefore = app.WorkingSet64;
        var privateMemoryBefore = app.PrivateMemorySize64;
        var managedHeapBefore = GC.GetTotalMemory(forceFullCollection: false);
        var trackedCaptureBitmapCount = _captureBitmapReferences.Count;

        // Runtime evidence renders several large bitmaps that normal Widget mode
        // never creates. Release those managed capture buffers before measuring
        // the production Dashboard-closed/Widget-visible state. No native
        // working-set trim is used; the following sample observes natural pages.
        await Dispatcher.Yield(DispatcherPriority.ApplicationIdle);
        GCSettings.LargeObjectHeapCompactionMode =
            GCLargeObjectHeapCompactionMode.CompactOnce;
        GC.Collect(
            GC.MaxGeneration,
            GCCollectionMode.Forced,
            blocking: true,
            compacting: true);
        GC.WaitForPendingFinalizers();
        GC.Collect(
            GC.MaxGeneration,
            GCCollectionMode.Forced,
            blocking: true,
            compacting: true);
        await Dispatcher.Yield(DispatcherPriority.ApplicationIdle);

        var retainedCaptureBitmapCount = _captureBitmapReferences.Count(reference =>
            reference.TryGetTarget(out _));
        var releasedCaptureBitmapCount =
            trackedCaptureBitmapCount - retainedCaptureBitmapCount;
        var managedCaptureCleanupCompleted =
            trackedCaptureBitmapCount > 0 && retainedCaptureBitmapCount == 0;
        _captureBitmapReferences.Clear();

        var dashboardResourcesReleased = _mainWindow.DashboardResourcesReleased;
        var retainedEvidenceWindows = _widgetWindows.Count;
        var visibleEvidenceWindows = _widgetWindows.Count(window => window.IsVisible);
        app.Refresh();
        return new RuntimeResourcePreparation(
            DateTimeOffset.UtcNow,
            dashboardResourcesReleased,
            retainedEvidenceWindows,
            visibleEvidenceWindows,
            ManagedCaptureCleanupAttempted: trackedCaptureBitmapCount > 0,
            ManagedCaptureCleanupCompleted: managedCaptureCleanupCompleted,
            trackedCaptureBitmapCount,
            releasedCaptureBitmapCount,
            Math.Round(ToMegabytes(workingSetBefore), 3),
            Math.Round(ToMegabytes(app.WorkingSet64), 3),
            Math.Round(ToMegabytes(privateMemoryBefore), 3),
            Math.Round(ToMegabytes(app.PrivateMemorySize64), 3),
            Math.Round(ToMegabytes(managedHeapBefore), 3),
            Math.Round(ToMegabytes(GC.GetTotalMemory(forceFullCollection: false)), 3));
    }

    private async Task<RuntimeIdleQuiescence> WaitForIdleQuiescenceAsync(
        DateTimeOffset deadline,
        CancellationToken cancellationToken)
    {
        var tracker = new RuntimeIdleQuiescenceTracker(IdleQuiescenceSeconds);

        while (true)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var observedUtc = DateTimeOffset.UtcNow;
            if (observedUtc >= deadline)
            {
                throw new TimeoutException(
                    $"The live state did not remain unchanged for {IdleQuiescenceSeconds} seconds before the runtime-evidence timeout.");
            }

            var quiescence = tracker.Observe(observedUtc, CurrentFingerprint());
            if (quiescence is not null)
            {
                return quiescence;
            }

            await Task.Delay(
                TimeSpan.FromMilliseconds(IdleQuiescencePollMilliseconds),
                cancellationToken);
        }
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

    public static bool IsExactAgentStatusEvent(
        RuntimeAgentStatusTransitionEvidence evidence) =>
        string.Equals(
            evidence.AcceptedEventKind,
            AcceptedAgentStatusEventKind,
            StringComparison.Ordinal) &&
        evidence.CurrentEventCount == evidence.BaselineEventCount + 1 &&
        evidence.ConnectionEpoch == evidence.BaselineConnectionEpoch &&
        evidence.CurrentIsCoreConnected &&
        evidence.CurrentIsLive &&
        string.Equals(evidence.CurrentRuntimeStatus, "Connected", StringComparison.Ordinal) &&
        evidence.CurrentBootstrapCount == evidence.BaselineBootstrapCount &&
        evidence.CurrentDisconnectCount == evidence.BaselineDisconnectCount &&
        HasSupportedEventAdmissionPath(evidence) &&
        evidence.ChangeCount == 1 &&
        HasExactAgentStateBinding(evidence);

    private static bool HasExactAgentStateBinding(
        RuntimeAgentStatusTransitionEvidence evidence)
    {
        if (!IsSha256(evidence.BaselineAgentTopologySha256) ||
            !IsSha256(evidence.CurrentAgentTopologySha256) ||
            !IsSha256(evidence.BaselineAgentStatusStateSha256) ||
            !IsSha256(evidence.CurrentAgentStatusStateSha256) ||
            !string.Equals(
                evidence.BaselineAgentTopologySha256,
                evidence.CurrentAgentTopologySha256,
                StringComparison.Ordinal) ||
            string.Equals(
                evidence.BaselineAgentStatusStateSha256,
                evidence.CurrentAgentStatusStateSha256,
                StringComparison.Ordinal) ||
            evidence.Changes.Count != 1)
        {
            return false;
        }

        var change = evidence.Changes[0];
        return HasLiveAgentIdentity(change) &&
               change.CurrentStateChangeSequence > change.PreviousStateChangeSequence &&
               change.CurrentStateChangeSequence - change.PreviousStateChangeSequence == 1;
    }

    private static bool HasLiveAgentIdentity(RuntimeAgentStatusChange change) =>
        !string.IsNullOrWhiteSpace(change.WorkspaceId) &&
        !string.IsNullOrWhiteSpace(change.TabId) &&
        !string.IsNullOrWhiteSpace(change.PaneId) &&
        !string.IsNullOrWhiteSpace(change.PreviousWorkspaceId) &&
        !string.IsNullOrWhiteSpace(change.PreviousTabId) &&
        !string.IsNullOrWhiteSpace(change.PreviousPaneId) &&
        string.Equals(
            change.PreviousWorkspaceId,
            change.WorkspaceId,
            StringComparison.Ordinal) &&
        string.Equals(
            change.PreviousTabId,
            change.TabId,
            StringComparison.Ordinal) &&
        string.Equals(
            change.PreviousPaneId,
            change.PaneId,
            StringComparison.Ordinal) &&
        !string.IsNullOrWhiteSpace(change.PreviousAgentKind) &&
        !string.IsNullOrWhiteSpace(change.CurrentAgentKind) &&
        !string.IsNullOrWhiteSpace(change.PreviousAgentName) &&
        !string.IsNullOrWhiteSpace(change.CurrentAgentName) &&
        string.Equals(
            change.PreviousAgentKind,
            change.CurrentAgentKind,
            StringComparison.Ordinal) &&
        string.Equals(
            change.PreviousAgentName,
            change.CurrentAgentName,
            StringComparison.Ordinal) &&
        !string.Equals(change.PreviousStatus, "Unknown", StringComparison.OrdinalIgnoreCase) &&
        !string.Equals(change.CurrentStatus, "Unknown", StringComparison.OrdinalIgnoreCase) &&
        !(string.Equals(change.PreviousStatus, "Idle", StringComparison.OrdinalIgnoreCase) &&
          string.Equals(change.CurrentStatus, "Unknown", StringComparison.OrdinalIgnoreCase));

    private static bool IsSha256(string value) =>
        value is { Length: 64 } && value.All(Uri.IsHexDigit);

    private static bool HasSupportedEventAdmissionPath(
        RuntimeAgentStatusTransitionEvidence evidence)
    {
        var sequenceDelta = evidence.CurrentSequence - evidence.BaselineSequence;
        var reconciliationDelta =
            evidence.CurrentReconciliationCount - evidence.BaselineReconciliationCount;
        return evidence.AdmissionPath switch
        {
            DirectEventAdmissionPath =>
                sequenceDelta == 1 && reconciliationDelta == 1,
            SnapshotBeforeEventAdmissionPath =>
                sequenceDelta == 2 && reconciliationDelta is >= 1 and <= 2,
            _ => false,
        };
    }

    private async Task<RuntimeAgentStatusTransitionEvidence> WaitForAgentStatusTransitionAsync(
        HerdrSessionStateContract baselineState,
        RuntimeEvidenceProgress baselineProgress,
        DateTimeOffset deadline,
        string timeoutMessage,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(baselineState);
        ArgumentNullException.ThrowIfNull(baselineProgress);
        var baselineStateSha256 = HerdrOpsStateIpcJson.ComputeSha256(baselineState);
        var recordedBaselineFingerprint = new RuntimeStateFingerprint(
            baselineProgress.IsCoreConnected,
            baselineProgress.IsLive,
            baselineProgress.RuntimeStatus,
            baselineProgress.LastTransitionUtc,
            baselineProgress.LastAcceptedStateUtc,
            baselineProgress.ConnectionEpoch,
            baselineProgress.Sequence,
            baselineProgress.BootstrapCount,
            baselineProgress.EventCount,
            baselineProgress.DisconnectCount,
            baselineProgress.ReconciliationCount,
            baselineProgress.StateSha256);
        if (!CurrentFingerprint().Equals(recordedBaselineFingerprint) ||
            baselineProgress.Sequence != baselineState.LastIngestSequence ||
            baselineProgress.ConnectionEpoch != baselineState.ConnectionEpoch ||
            !string.Equals(
                baselineProgress.StateSha256,
                baselineStateSha256,
                StringComparison.Ordinal))
        {
            throw new InvalidOperationException(
                "The Agent-status phase baseline changed before it could be bound to its progress record.");
        }

        while (true)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var currentState = _state.CurrentState;
            var currentHealth = _state.CurrentRuntimeHealth;
            var sequenceDelta =
                currentState.LastIngestSequence - baselineState.LastIngestSequence;
            var reconciliationDelta =
                currentHealth.ReconciliationCount - baselineProgress.ReconciliationCount;
            var admissionPath = sequenceDelta switch
            {
                1 when reconciliationDelta == 1 =>
                    DirectEventAdmissionPath,
                2 when reconciliationDelta is >= 1 and <= 2 =>
                    SnapshotBeforeEventAdmissionPath,
                _ => null,
            };
            if (_state.IsCoreConnected &&
                _state.IsLive &&
                currentState.ConnectionEpoch == baselineState.ConnectionEpoch &&
                admissionPath is not null &&
                currentHealth.EventCount == baselineProgress.EventCount + 1 &&
                currentHealth.BootstrapCount == baselineProgress.BootstrapCount &&
                currentHealth.DisconnectCount == baselineProgress.DisconnectCount &&
                currentHealth.LastTransitionUtc >= baselineProgress.ObservedUtc &&
                string.Equals(currentHealth.Status, "Connected", StringComparison.Ordinal))
            {
                var changes = FindCorrelatedAgentStatusChanges(baselineState, currentState);
                if (changes.Count == 1)
                {
                    return new RuntimeAgentStatusTransitionEvidence(
                        baselineProgress.ObservedUtc,
                        DateTimeOffset.UtcNow,
                        AcceptedAgentStatusEventKind,
                        admissionPath,
                        baselineState.ConnectionEpoch,
                        _state.IsCoreConnected,
                        _state.IsLive,
                        currentHealth.Status,
                        baselineState.LastIngestSequence,
                        currentState.LastIngestSequence,
                        baselineProgress.EventCount,
                        currentHealth.EventCount,
                        baselineProgress.BootstrapCount,
                        currentHealth.BootstrapCount,
                        baselineProgress.DisconnectCount,
                        currentHealth.DisconnectCount,
                        baselineProgress.ReconciliationCount,
                        currentHealth.ReconciliationCount,
                        baselineStateSha256,
                        HerdrOpsStateIpcJson.ComputeSha256(currentState),
                        HerdrOpsStateIpcJson.ComputeAgentTopologySha256(baselineState),
                        HerdrOpsStateIpcJson.ComputeAgentTopologySha256(currentState),
                        HerdrOpsStateIpcJson.ComputeAgentStatusStateSha256(baselineState),
                        HerdrOpsStateIpcJson.ComputeAgentStatusStateSha256(currentState),
                        currentState.ConnectionEpoch,
                        changes);
                }
            }

            if (DateTimeOffset.UtcNow >= deadline)
            {
                throw new TimeoutException(timeoutMessage);
            }

            await Task.Delay(100, cancellationToken);
        }
    }

    private static IReadOnlyList<RuntimeAgentStatusChange> FindCorrelatedAgentStatusChanges(
        HerdrSessionStateContract baseline,
        HerdrSessionStateContract current)
    {
        if (!string.Equals(
                HerdrOpsStateIpcJson.ComputeAgentTopologySha256(baseline),
                HerdrOpsStateIpcJson.ComputeAgentTopologySha256(current),
                StringComparison.Ordinal))
        {
            return [];
        }

        if (!HasAllLiveAgentIdentities(baseline) ||
            !HasAllLiveAgentIdentities(current))
        {
            return [];
        }

        var baselineAgents = baseline.Agents.ToDictionary(
            agent => agent.TerminalId,
            StringComparer.Ordinal);
        var baselinePanes = baseline.Panes.ToDictionary(
            pane => pane.PaneId,
            StringComparer.Ordinal);
        var currentPanes = current.Panes.ToDictionary(
            pane => pane.PaneId,
            StringComparer.Ordinal);
        if (baseline.Agents.Any(agent => !HasMatchingPaneIdentity(baselinePanes, agent)) ||
            current.Agents.Any(agent => !HasMatchingPaneIdentity(currentPanes, agent)))
        {
            return [];
        }
        if (current.Agents.Any(agent =>
                !baselineAgents.TryGetValue(agent.TerminalId, out var previous) ||
                (string.Equals(previous.AgentStatus, agent.AgentStatus, StringComparison.Ordinal) &&
                 previous.StateChangeSequence != agent.StateChangeSequence)))
        {
            return [];
        }

        return current.Agents
            .Where(agent =>
                baselineAgents.TryGetValue(agent.TerminalId, out var previous) &&
                string.Equals(previous.WorkspaceId, agent.WorkspaceId, StringComparison.Ordinal) &&
                string.Equals(previous.TabId, agent.TabId, StringComparison.Ordinal) &&
                string.Equals(previous.PaneId, agent.PaneId, StringComparison.Ordinal) &&
                string.Equals(previous.Agent, agent.Agent, StringComparison.Ordinal) &&
                string.Equals(previous.Name, agent.Name, StringComparison.Ordinal) &&
                !string.Equals(previous.AgentStatus, agent.AgentStatus, StringComparison.Ordinal) &&
                agent.StateChangeSequence > previous.StateChangeSequence &&
                agent.StateChangeSequence - previous.StateChangeSequence == 1 &&
                baselinePanes.TryGetValue(previous.PaneId, out var previousPane) &&
                currentPanes.TryGetValue(agent.PaneId, out var currentPane) &&
                string.Equals(previousPane.AgentStatus, previous.AgentStatus, StringComparison.Ordinal) &&
                string.Equals(currentPane.AgentStatus, agent.AgentStatus, StringComparison.Ordinal))
            .Select(agent =>
            {
                var previous = baselineAgents[agent.TerminalId];
                return new RuntimeAgentStatusChange(
                    agent.TerminalId,
                    agent.WorkspaceId,
                    agent.TabId,
                    agent.PaneId,
                    previous.AgentStatus,
                    agent.AgentStatus,
                    previous.Revision,
                    agent.Revision,
                    previous.StateChangeSequence,
                    agent.StateChangeSequence)
                {
                    PreviousWorkspaceId = previous.WorkspaceId,
                    PreviousTabId = previous.TabId,
                    PreviousPaneId = previous.PaneId,
                    PreviousAgentKind = previous.Agent,
                    CurrentAgentKind = agent.Agent,
                    PreviousAgentName = previous.Name,
                    CurrentAgentName = agent.Name,
                };
            })
            .OrderBy(change => change.TerminalId, StringComparer.Ordinal)
            .ToArray();
    }

    internal static bool HasAllLiveAgentIdentities(HerdrSessionStateContract state) =>
        state.Agents.Count > 0 && state.Agents.All(HasLiveAgentIdentity);

    private static bool HasLiveAgentIdentity(HerdrAgentStateContract agent) =>
        !string.IsNullOrWhiteSpace(agent.Agent) &&
        !string.IsNullOrWhiteSpace(agent.Name) &&
        !string.Equals(agent.AgentStatus, "Unknown", StringComparison.OrdinalIgnoreCase);

    private static bool HasMatchingPaneIdentity(
        IReadOnlyDictionary<string, HerdrPaneStateContract> panes,
        HerdrAgentStateContract agent) =>
        panes.TryGetValue(agent.PaneId, out var pane) &&
        string.Equals(pane.TerminalId, agent.TerminalId, StringComparison.Ordinal) &&
        string.Equals(pane.WorkspaceId, agent.WorkspaceId, StringComparison.Ordinal) &&
        string.Equals(pane.TabId, agent.TabId, StringComparison.Ordinal) &&
        pane.AgentStatus == agent.AgentStatus &&
        !string.IsNullOrWhiteSpace(pane.Agent) &&
        string.Equals(pane.Agent, agent.Agent, StringComparison.Ordinal);

    private RuntimeStateFingerprint CurrentFingerprint()
    {
        var state = _state.CurrentState;
        var health = _state.CurrentRuntimeHealth;
        return new RuntimeStateFingerprint(
            _state.IsCoreConnected,
            _state.IsLive,
            health.Status,
            health.LastTransitionUtc,
            health.LastAcceptedStateUtc,
            state.ConnectionEpoch,
            state.LastIngestSequence,
            health.BootstrapCount,
            health.EventCount,
            health.DisconnectCount,
            health.ReconciliationCount,
            HerdrOpsStateIpcJson.ComputeSha256(state));
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

    private string ProgressHistoryPath => _options.ProgressPath + ".history.jsonl";

    private RuntimeEvidenceProgress WriteProgress(string phase)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(phase);
        var fingerprint = CurrentFingerprint();
        var ordinal = _progressHistory.Count + 1;
        var observedUtc = DateTimeOffset.UtcNow;
        var previousEntrySha256 = _progressHistory.Count == 0
            ? EmptySha256
            : _progressHistory[^1].EntrySha256;
        var progress = new RuntimeEvidenceProgress(
            ordinal,
            phase,
            observedUtc,
            fingerprint.LastIngestSequence,
            fingerprint.IsCoreConnected,
            fingerprint.IsLive,
            fingerprint.RuntimeStatus,
            fingerprint.LastTransitionUtc,
            fingerprint.LastAcceptedStateUtc,
            fingerprint.ConnectionEpoch,
            fingerprint.BootstrapCount,
            fingerprint.EventCount,
            fingerprint.DisconnectCount,
            fingerprint.ReconciliationCount,
            fingerprint.StateSha256,
            previousEntrySha256,
            CanonicalPayload: string.Empty,
            EntrySha256: string.Empty);
        var canonicalPayload = BuildProgressCanonicalPayload(progress);
        progress = progress with
        {
            CanonicalPayload = canonicalPayload,
            EntrySha256 = ComputeProgressEntrySha256(canonicalPayload),
        };
        _progressHistory.Add(progress);
        File.AppendAllText(
            ProgressHistoryPath,
            JsonSerializer.Serialize(progress, CompactSerializerOptions) + Environment.NewLine,
            new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
        WriteJsonAtomically(_options.ProgressPath, new
        {
            progress.Ordinal,
            progress.Phase,
            progress.ObservedUtc,
            progress.Sequence,
            progress.IsCoreConnected,
            progress.IsLive,
            progress.RuntimeStatus,
            progress.LastTransitionUtc,
            progress.LastAcceptedStateUtc,
            progress.ConnectionEpoch,
            progress.BootstrapCount,
            progress.EventCount,
            progress.DisconnectCount,
            progress.ReconciliationCount,
            progress.StateSha256,
            progress.PreviousEntrySha256,
            progress.CanonicalPayload,
            progress.EntrySha256,
            ProgressHistoryPath,
            History = _progressHistory.ToArray(),
        });
        return progress;
    }

    public static string BuildProgressCanonicalPayload(RuntimeEvidenceProgress progress)
    {
        ArgumentNullException.ThrowIfNull(progress);
        return string.Join(
            '|',
            progress.Ordinal.ToString(CultureInfo.InvariantCulture),
            progress.Phase,
            progress.ObservedUtc.ToUniversalTime().ToString("O", CultureInfo.InvariantCulture),
            progress.Sequence.ToString(CultureInfo.InvariantCulture),
            progress.IsCoreConnected.ToString(CultureInfo.InvariantCulture),
            progress.IsLive.ToString(CultureInfo.InvariantCulture),
            progress.RuntimeStatus,
            progress.LastTransitionUtc.ToUniversalTime().ToString("O", CultureInfo.InvariantCulture),
            progress.LastAcceptedStateUtc?.ToUniversalTime().ToString("O", CultureInfo.InvariantCulture) ?? string.Empty,
            progress.ConnectionEpoch.ToString(CultureInfo.InvariantCulture),
            progress.BootstrapCount.ToString(CultureInfo.InvariantCulture),
            progress.EventCount.ToString(CultureInfo.InvariantCulture),
            progress.DisconnectCount.ToString(CultureInfo.InvariantCulture),
            progress.ReconciliationCount.ToString(CultureInfo.InvariantCulture),
            progress.StateSha256,
            progress.PreviousEntrySha256);
    }

    public static string ComputeProgressEntrySha256(string canonicalPayload)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(canonicalPayload);
        return Convert.ToHexString(
            SHA256.HashData(Encoding.UTF8.GetBytes(canonicalPayload)));
    }

    private static RuntimeFailureProgressEvidence CaptureFailureProgress(
        string? progressPath)
    {
        if (string.IsNullOrWhiteSpace(progressPath))
        {
            return new RuntimeFailureProgressEvidence(
                null,
                false,
                null,
                null,
                false,
                null,
                0,
                false,
                null,
                null);
        }

        var fullProgressPath = Path.GetFullPath(progressPath);
        var historyPath = fullProgressPath + ".history.jsonl";
        JsonElement? lastProgress = null;
        string? progressReadError = null;
        var coreStateObserved = false;
        try
        {
            if (File.Exists(fullProgressPath))
            {
                using var document = JsonDocument.Parse(
                    File.ReadAllText(fullProgressPath, Encoding.UTF8));
                lastProgress = document.RootElement.Clone();
                if (document.RootElement.TryGetProperty("History", out var history) &&
                    history.ValueKind == JsonValueKind.Array)
                {
                    coreStateObserved = history.EnumerateArray().Any(entry =>
                        entry.TryGetProperty("IsCoreConnected", out var connected) &&
                        connected.ValueKind == JsonValueKind.True);
                }
            }
        }
        catch (Exception readException) when (
            readException is IOException or UnauthorizedAccessException or JsonException)
        {
            progressReadError = $"{readException.GetType().Name}: {readException.Message}";
        }

        var historyEntryCount = 0;
        try
        {
            if (File.Exists(historyPath))
            {
                historyEntryCount = File.ReadLines(historyPath, Encoding.UTF8)
                    .Count(line => !string.IsNullOrWhiteSpace(line));
            }
        }
        catch (Exception readException) when (
            readException is IOException or UnauthorizedAccessException)
        {
            progressReadError ??=
                $"{readException.GetType().Name}: {readException.Message}";
        }

        return new RuntimeFailureProgressEvidence(
            fullProgressPath,
            File.Exists(fullProgressPath),
            TryComputeFileSha256(fullProgressPath),
            historyPath,
            File.Exists(historyPath),
            TryComputeFileSha256(historyPath),
            historyEntryCount,
            coreStateObserved,
            lastProgress,
            progressReadError);
    }

    private static string? TryComputeFileSha256(string path)
    {
        try
        {
            if (!File.Exists(path))
            {
                return null;
            }

            using var input = File.OpenRead(path);
            return Convert.ToHexString(SHA256.HashData(input));
        }
        catch (Exception exception) when (
            exception is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

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

    private sealed record RuntimeFailureProgressEvidence(
        string? ProgressPath,
        bool ProgressReportPresent,
        string? ProgressReportSha256,
        string? ProgressHistoryPath,
        bool ProgressHistoryPresent,
        string? ProgressHistorySha256,
        int ProgressHistoryEntryCount,
        bool CoreStateObserved,
        JsonElement? LastProgress,
        string? ProgressReadError);

}
