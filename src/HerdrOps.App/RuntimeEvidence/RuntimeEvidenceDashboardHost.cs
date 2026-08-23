using System.IO;
using System.Text.Json;
using System.Security.Cryptography;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using HerdrOps.App.Live;
using HerdrOps.App.StateIpc;
using HerdrOps.Contracts.StateIpc;

namespace HerdrOps.App.RuntimeEvidence;

public sealed record RuntimeDashboardDispatcherDiagnostic(
    int DashboardDispatcherThreadId,
    DateTimeOffset DashboardDispatcherStartedUtc,
    DateTimeOffset? DashboardCloseRequestedUtc,
    DateTimeOffset? DashboardDispatcherShutdownCompletedUtc,
    DateTimeOffset? DashboardDispatcherJoinedUtc,
    bool DashboardDispatcherShutdownCompleted,
    bool DashboardDispatcherThreadJoined,
    bool DashboardDispatcherAliveAfterJoin,
    bool DashboardResourcesReleased,
    long DashboardLastProjectedSequence,
    string DashboardLastProjectedStateSha256);

internal sealed record RuntimeDashboardProjection(
    HerdrSessionStateContract State,
    HerdrRuntimeHealthContract RuntimeHealth,
    DateTimeOffset ObservedUtc,
    long Sequence,
    string StateSha256)
{
    public static RuntimeDashboardProjection Capture(LiveDashboardState source)
    {
        ArgumentNullException.ThrowIfNull(source);
        var state = source.CurrentState;
        return new RuntimeDashboardProjection(
            state,
            source.CurrentRuntimeHealth,
            DateTimeOffset.UtcNow,
            state.LastIngestSequence,
            HerdrOpsStateIpcJson.ComputeSha256(state));
    }
}

internal sealed record RuntimeDashboardProjectionReceipt(
    long AppliedSequence,
    string AppliedStateSha256);

internal sealed record RuntimeDashboardCaptureResult(
    string Path,
    string Sha256,
    int PixelWidth,
    int PixelHeight,
    RuntimeDashboardProjectionReceipt ProjectionReceipt,
    WeakReference<RenderTargetBitmap> BitmapReference);

/// <summary>
/// No-credit feasibility host that confines Dashboard WPF resources to a
/// shutdownable STA Dispatcher. It never opens a Core subscription; callers
/// project exact authoritative state immediately before each render.
/// </summary>
internal sealed class RuntimeEvidenceDashboardHost : IDisposable
{
    private static readonly TimeSpan StartTimeout = TimeSpan.FromSeconds(30);
    private static readonly TimeSpan ShutdownTimeout = TimeSpan.FromSeconds(30);

    private readonly Thread _thread;
    private readonly TaskCompletionSource<bool> _started =
        new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly TaskCompletionSource<bool> _stopped =
        new(TaskCreationOptions.RunContinuationsAsynchronously);
    private Dispatcher? _dispatcher;
    private MainWindow? _window;
    private LiveDashboardState? _projectionState;
    private Exception? _threadFailure;
    private int _threadId;
    private DateTimeOffset _startedUtc;
    private DateTimeOffset? _closeRequestedUtc;
    private DateTimeOffset? _shutdownCompletedUtc;
    private DateTimeOffset? _joinedUtc;
    private bool _threadJoined;
    private bool _dashboardResourcesReleased;
    private long _lastProjectedSequence;
    private string _lastProjectedStateSha256 = string.Empty;
    private bool _disposed;

    private RuntimeEvidenceDashboardHost()
    {
        _thread = new Thread(RunDispatcher)
        {
            IsBackground = true,
            Name = "HerdrOps.RuntimeEvidence.Dashboard",
        };
        _thread.SetApartmentState(ApartmentState.STA);
    }

    public static async Task<RuntimeEvidenceDashboardHost> StartAsync(
        CancellationToken cancellationToken)
    {
        var host = new RuntimeEvidenceDashboardHost();
        host._thread.Start();
        try
        {
            await host._started.Task
                .WaitAsync(StartTimeout, cancellationToken)
                .ConfigureAwait(false);
            host.ThrowIfThreadFailed();
            return host;
        }
        catch
        {
            host.Dispose();
            throw;
        }
    }

    public Task<RuntimeDashboardProjectionReceipt> ProjectAsync(
        RuntimeDashboardProjection projection,
        CancellationToken cancellationToken)
    {
        return InvokeAsync(
            projection,
            (window, receipt) =>
            {
                window.UpdateLayout();
                return Task.FromResult(receipt);
            },
            cancellationToken);
    }

    public Task<RuntimeDashboardCaptureResult> CaptureDashboardPageAsync(
        RuntimeDashboardProjection projection,
        int navigationIndex,
        string path,
        CancellationToken cancellationToken)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        return InvokeAsync(
            projection,
            async (window, receipt) =>
            {
                window.Shell.Navigation.SelectedIndex = navigationIndex;
                window.UpdateLayout();
                await Dispatcher.Yield(DispatcherPriority.ApplicationIdle);
                return CaptureVisual(window.Shell, path, receipt);
            },
            cancellationToken);
    }

    private async Task<T> InvokeAsync<T>(
        RuntimeDashboardProjection projection,
        Func<MainWindow, RuntimeDashboardProjectionReceipt, Task<T>> action,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(projection);
        ArgumentNullException.ThrowIfNull(action);
        ThrowIfDisposed();
        ThrowIfThreadFailed();
        var dispatcher = _dispatcher ?? throw new InvalidOperationException(
            "The Dashboard Dispatcher was not initialized.");
        if (dispatcher.HasShutdownStarted || dispatcher.HasShutdownFinished)
        {
            throw new InvalidOperationException(
                "The Dashboard Dispatcher is unavailable after shutdown began.");
        }

        var operation = dispatcher.InvokeAsync(
            async () =>
            {
                var receipt = ApplyProjection(projection);
                var window = _window ?? throw new InvalidOperationException(
                    "The Dashboard window is unavailable.");
                return await action(window, receipt);
            },
            DispatcherPriority.Send,
            cancellationToken);
        var result = await (await operation.Task.ConfigureAwait(false)).ConfigureAwait(false);
        ThrowIfThreadFailed();
        return result;
    }

    public async Task ShutdownAsync(CancellationToken cancellationToken)
    {
        ThrowIfDisposed();
        ThrowIfThreadFailed();
        if (_threadJoined)
        {
            return;
        }

        _closeRequestedUtc = DateTimeOffset.UtcNow;
        var dispatcher = _dispatcher ?? throw new InvalidOperationException(
            "The Dashboard Dispatcher was not initialized.");
        await dispatcher.InvokeAsync(
            () =>
            {
                var window = _window;
                if (window is { IsClosed: false })
                {
                    window.CloseForShutdown();
                }

                _dashboardResourcesReleased = window?.DashboardResourcesReleased ?? true;
                dispatcher.BeginInvokeShutdown(DispatcherPriority.Send);
            },
            DispatcherPriority.Send,
            cancellationToken).Task.ConfigureAwait(false);

        await _stopped.Task
            .WaitAsync(ShutdownTimeout, cancellationToken)
            .ConfigureAwait(false);
        _threadJoined = await Task.Run(
                () => _thread.Join(ShutdownTimeout),
                cancellationToken)
            .ConfigureAwait(false);
        _joinedUtc = DateTimeOffset.UtcNow;
        if (!_threadJoined || _thread.IsAlive)
        {
            throw new TimeoutException(
                "The dedicated Dashboard Dispatcher thread did not terminate within the bounded shutdown interval.");
        }

        ThrowIfThreadFailed();
    }

    public RuntimeDashboardDispatcherDiagnostic Diagnostic => new(
        _threadId,
        _startedUtc,
        _closeRequestedUtc,
        _shutdownCompletedUtc,
        _joinedUtc,
        _shutdownCompletedUtc is not null,
        _threadJoined,
        _thread.IsAlive,
        _dashboardResourcesReleased,
        _lastProjectedSequence,
        _lastProjectedStateSha256);

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        var dispatcher = _dispatcher;
        if (_thread.IsAlive && dispatcher is not null && !dispatcher.HasShutdownStarted)
        {
            try
            {
                dispatcher.BeginInvoke(
                    DispatcherPriority.Send,
                    new Action(() =>
                    {
                        if (_window is { IsClosed: false } window)
                        {
                            window.CloseForShutdown();
                        }

                        dispatcher.BeginInvokeShutdown(DispatcherPriority.Send);
                    }));
            }
            catch (InvalidOperationException)
            {
                // The Dispatcher crossed its shutdown boundary concurrently.
            }
        }

        if (_thread.IsAlive && Thread.CurrentThread != _thread)
        {
            _ = _thread.Join(ShutdownTimeout);
        }
    }

    private void RunDispatcher()
    {
        try
        {
            _threadId = Environment.CurrentManagedThreadId;
            _startedUtc = DateTimeOffset.UtcNow;
            _dispatcher = Dispatcher.CurrentDispatcher;
            _projectionState = new LiveDashboardState();
            _window = new MainWindow(_projectionState);
            _window.Show();
            _window.UpdateLayout();
            _started.TrySetResult(true);
            Dispatcher.Run();
            _dashboardResourcesReleased = _window.DashboardResourcesReleased;
        }
        catch (Exception exception)
        {
            _threadFailure = exception;
            _started.TrySetException(exception);
        }
        finally
        {
            try
            {
                if (_window is { IsClosed: false } window)
                {
                    window.CloseForShutdown();
                }

                _dashboardResourcesReleased = _window?.DashboardResourcesReleased ?? true;
                _projectionState?.Dispose();
            }
            catch (Exception exception)
            {
                _threadFailure ??= exception;
            }

            _window = null;
            _projectionState = null;
            _shutdownCompletedUtc = DateTimeOffset.UtcNow;
            _stopped.TrySetResult(true);
        }
    }

    private RuntimeDashboardProjectionReceipt ApplyProjection(
        RuntimeDashboardProjection projection)
    {
        var state = _projectionState ?? throw new InvalidOperationException(
            "The Dashboard projection state is unavailable.");
        var snapshot = new HerdrOpsStateSnapshotPayload(
            projection.State,
            projection.StateSha256,
            projection.RuntimeHealth);
        var envelope = new HerdrOpsStateIpcEnvelope(
            HerdrOpsStateIpcProtocol.Version,
            HerdrOpsStateIpcProtocol.MessageTypes.Snapshot,
            projection.Sequence,
            projection.RuntimeHealth.LastAcceptedStateUtc ?? projection.ObservedUtc,
            HerdrOpsStateIpcProtocol.CoreSource,
            Guid.NewGuid(),
            default(JsonElement));
        state.ApplyUpdate(
            new HerdrOpsStateUpdate(
                HerdrOpsStateUpdateKind.Snapshot,
                projection.State,
                envelope,
                snapshot,
                Delta: null,
                projection.RuntimeHealth),
            projection.ObservedUtc);
        var observedHash = HerdrOpsStateIpcJson.ComputeSha256(state.CurrentState);
        if (state.CurrentState.LastIngestSequence != projection.Sequence ||
            !string.Equals(observedHash, projection.StateSha256, StringComparison.Ordinal))
        {
            throw new InvalidOperationException(
                "The dedicated Dashboard projection did not retain the exact authoritative sequence and state hash.");
        }

        _lastProjectedSequence = projection.Sequence;
        _lastProjectedStateSha256 = observedHash;
        return new RuntimeDashboardProjectionReceipt(
            state.CurrentState.LastIngestSequence,
            observedHash);
    }

    private static RuntimeDashboardCaptureResult CaptureVisual(
        FrameworkElement visual,
        string path,
        RuntimeDashboardProjectionReceipt receipt)
    {
        visual.UpdateLayout();
        var width = checked((int)Math.Ceiling(visual.ActualWidth));
        var height = checked((int)Math.Ceiling(visual.ActualHeight));
        if (width <= 0 || height <= 0)
        {
            throw new InvalidOperationException(
                $"Runtime capture '{Path.GetFileName(path)}' has no laid-out WPF surface.");
        }

        var bitmap = new RenderTargetBitmap(
            width,
            height,
            96,
            96,
            PixelFormats.Pbgra32);
        var bitmapReference = new WeakReference<RenderTargetBitmap>(bitmap);
        bitmap.Render(visual);
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using (var output = new FileStream(
                   path,
                   FileMode.Create,
                   FileAccess.Write,
                   FileShare.None))
        {
            encoder.Save(output);
            if (output.Length <= 4_000)
            {
                throw new InvalidOperationException(
                    $"Runtime capture '{Path.GetFileName(path)}' is unexpectedly small ({output.Length} bytes).");
            }
        }

        using var capture = File.OpenRead(path);
        return new RuntimeDashboardCaptureResult(
            path,
            Convert.ToHexString(SHA256.HashData(capture)),
            width,
            height,
            receipt,
            bitmapReference);
    }

    private void ThrowIfThreadFailed()
    {
        if (_threadFailure is not null)
        {
            throw new InvalidOperationException(
                "The dedicated Dashboard Dispatcher failed.",
                _threadFailure);
        }
    }

    private void ThrowIfDisposed() => ObjectDisposedException.ThrowIf(_disposed, this);
}
