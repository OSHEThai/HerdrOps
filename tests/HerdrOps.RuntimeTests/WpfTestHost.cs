using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Threading;

namespace HerdrOps.RuntimeTests;

/// <summary>
/// Owns one WPF application and one STA dispatcher for the test process.
///
/// Startup is deliberately represented by a per-session task rather than a
/// process-wide event. That keeps concurrent callers on the same owned
/// thread, preserves the actual startup failure, and prevents a stale ready
/// signal from making a stopped dispatcher look usable.
/// </summary>
internal static class WpfTestHost
{
    private static readonly TimeSpan StartupTimeout = TimeSpan.FromSeconds(30);
    private static readonly TimeSpan ShutdownTimeout = TimeSpan.FromSeconds(15);
    private static readonly object HostGate = new();
    private static HostSession? _session;
    private static HostSnapshot? _lastSnapshot;
    private static bool _terminalShutdown;
    private static int _nextGeneration;

    public static void Run(Action action, TimeSpan? timeout = null)
    {
        ArgumentNullException.ThrowIfNull(action);

        var session = EnsureStarted();
        Dispatcher dispatcher;
        lock (HostGate)
        {
            if (!ReferenceEquals(_session, session) ||
                session.State != HostState.Running ||
                session.Dispatcher is null)
            {
                throw CreateUnavailableException(session);
            }

            dispatcher = session.Dispatcher;
        }

        if (dispatcher.HasShutdownStarted || dispatcher.HasShutdownFinished)
        {
            throw CreateUnavailableException(session);
        }

        if (dispatcher.CheckAccess())
        {
            ThrowIfDispatcherFaultIsPending(session);
            action();
            return;
        }

        DispatcherOperation operation;
        try
        {
            operation = dispatcher.InvokeAsync(
                () =>
                {
                    ThrowIfDispatcherFaultIsPending(session);
                    action();
                },
                DispatcherPriority.Send);
        }
        catch (Exception exception)
        {
            throw new InvalidOperationException(
                "WPF test host could not queue the UI operation. " +
                GetDiagnostics(session),
                exception);
        }

        var task = operation.Task;
        var effectiveTimeout = timeout ?? TimeSpan.FromSeconds(60);
        bool completed;
        try
        {
            completed = task.Wait(effectiveTimeout);
        }
        catch (AggregateException)
        {
            task.GetAwaiter().GetResult();
            throw;
        }

        if (!completed)
        {
            operation.Abort();
            throw new TimeoutException(
                $"WPF operation exceeded {effectiveTimeout.TotalSeconds:0} seconds. " +
                GetDiagnostics(session));
        }

        task.GetAwaiter().GetResult();
    }

    /// <summary>
    /// Starts the owned thread without making assembly initialization wait on
    /// cold WPF resource loading. The first caller of <see cref="Run"/> still
    /// waits for the same readiness task and fails closed if it does not
    /// complete.
    /// </summary>
    internal static void BeginStartup()
    {
        lock (HostGate)
        {
            if (_terminalShutdown)
            {
                throw CreateTerminalShutdownException();
            }

            if (_session is { State: HostState.Running or HostState.Starting })
            {
                return;
            }

            if (_session is { State: HostState.Stopping })
            {
                throw CreateUnavailableException(_session);
            }

            if (_session is { State: HostState.Failed })
            {
                throw CreateUnavailableException(_session);
            }

            _session = CreateAndStartSessionLocked();
        }
    }

    /// <summary>
    /// Stops the owned dispatcher and joins its thread. This is used by
    /// assembly cleanup; it never kills an unrelated process or thread.
    /// </summary>
    internal static void Shutdown()
    {
        HostSession? session;
        lock (HostGate)
        {
            session = _session;
            if (session is null)
            {
                _terminalShutdown = true;
                return;
            }

            RequestStopLocked(session);
        }

        RequestDispatcherShutdown(session);
        if (!session.Exited.Task.Wait(ShutdownTimeout))
        {
            throw new TimeoutException(
                $"WPF test host did not stop within {ShutdownTimeout.TotalSeconds:0} seconds. " +
                GetDiagnostics(session));
        }

        lock (HostGate)
        {
            if (ReferenceEquals(_session, session))
            {
                _lastSnapshot = CaptureSnapshotLocked(session);
                _session = null;
                _terminalShutdown = true;
            }
        }

        if (session.DispatcherFault is not null)
        {
            throw CreateDispatcherFaultException(session, session.DispatcherFault);
        }

        if (session.CleanupFailure is not null)
        {
            throw new InvalidOperationException(
                "WPF test host shutdown cleanup failed. " + GetDiagnostics(session),
                session.CleanupFailure);
        }
    }

    internal static string GetDiagnosticsForTest() => GetDiagnostics(null);

    internal static Task<Exception> PostDispatcherFaultForTest(Exception exception)
    {
        ArgumentNullException.ThrowIfNull(exception);

        var session = EnsureStarted();
        Dispatcher dispatcher;
        lock (HostGate)
        {
            dispatcher = session.Dispatcher ?? throw CreateUnavailableException(session);
        }

        // Throwing an actual unhandled exception through a WPF Application can
        // start its irreversible shutdown after the event is marked handled.
        // Inject the same pending-fault channel on the owned dispatcher so the
        // hostile test remains order-independent and does not poison later UI tests.
        dispatcher.BeginInvoke(
            DispatcherPriority.Normal,
            new Action(() => CaptureDispatcherFault(session, exception)));
        return session.DispatcherFaultObserved.Task;
    }

    private static HostSession EnsureStarted()
    {
        HostSession session;
        Task readyTask;
        lock (HostGate)
        {
            if (_terminalShutdown)
            {
                throw CreateTerminalShutdownException();
            }

            if (_session is { State: HostState.Running } running)
            {
                if (running.UiThread?.IsAlive == true &&
                    running.Dispatcher is not null &&
                    !running.Dispatcher.HasShutdownStarted &&
                    !running.Dispatcher.HasShutdownFinished)
                {
                    return running;
                }

                MarkFailureLocked(
                    running,
                    new InvalidOperationException(
                        "The WPF dispatcher stopped while the host was marked running."),
                    "RunningStateValidation");
                throw CreateUnavailableException(running);
            }

            if (_session is { State: HostState.Starting } starting)
            {
                session = starting;
            }
            else if (_session is { State: HostState.Failed } failed)
            {
                throw CreateUnavailableException(failed);
            }
            else if (_session is { State: HostState.Stopping } stopping)
            {
                throw CreateUnavailableException(stopping);
            }
            else
            {
                session = CreateAndStartSessionLocked();
                _session = session;
            }

            readyTask = session.Ready.Task;
        }

        bool readyWithinTimeout;
        try
        {
            readyWithinTimeout = readyTask.Wait(StartupTimeout);
        }
        catch (AggregateException)
        {
            readyWithinTimeout = true;
        }

        if (!readyWithinTimeout)
        {
            var timeout = new TimeoutException(
                $"WPF test host startup exceeded {StartupTimeout.TotalSeconds:0} seconds.");
            FailStartupClosed(session, timeout, "StartupTimeout");
            RequestDispatcherShutdown(session);
            throw new TimeoutException(
                "WPF test host failed closed during startup. " + GetDiagnostics(session),
                timeout);
        }

        try
        {
            readyTask.GetAwaiter().GetResult();
        }
        catch (Exception exception)
        {
            throw new InvalidOperationException(
                "WPF test host failed closed during startup. " +
                GetDiagnostics(session),
                exception);
        }

        lock (HostGate)
        {
            if (!ReferenceEquals(_session, session) || session.State != HostState.Running)
            {
                throw CreateUnavailableException(session);
            }
        }

        return session;
    }

    private static HostSession CreateAndStartSessionLocked()
    {
        var session = new HostSession(++_nextGeneration);
        try
        {
            var thread = new Thread(() => RunDispatcher(session))
            {
                IsBackground = true,
                Name = "HerdrOps WPF Runtime Test Host",
            };
            thread.SetApartmentState(ApartmentState.STA);
            session.UiThread = thread;
            session.LastMilestone = "ThreadCreated";
            thread.Start();
            session.LastMilestone = "ThreadStarted";
            session.LastTransitionUtc = DateTimeOffset.UtcNow;
        }
        catch (Exception exception)
        {
            MarkFailureLocked(session, exception, "ThreadStart");
            session.Exited.TrySetResult(true);
        }

        return session;
    }

    private static void RunDispatcher(HostSession session)
    {
        HerdrOps.App.App? application = null;
        Dispatcher? dispatcher = null;
        try
        {
            SetMilestone(session, "ThreadEntered");
            application = new HerdrOps.App.App(suppressStartupForTestHost: true)
            {
                ShutdownMode = ShutdownMode.OnExplicitShutdown,
            };
            application.DispatcherUnhandledException += session.DispatcherUnhandledExceptionHandler;
            lock (HostGate)
            {
                session.Application = application;
            }

            SetMilestone(session, "ApplicationConstructed");
            application.InitializeComponent();
            SetMilestone(session, "ApplicationInitialized");

            dispatcher = Dispatcher.CurrentDispatcher;
            lock (HostGate)
            {
                session.Dispatcher = dispatcher;
                session.DispatcherThreadId = Environment.CurrentManagedThreadId;
            }

            SetMilestone(session, "DispatcherCreated");
            dispatcher.BeginInvoke(
                DispatcherPriority.Send,
                new Action(() => SignalDispatcherReady(session)));
            SetMilestone(session, "ReadinessQueued");

            if (session.StopRequested.IsCancellationRequested)
            {
                SetMilestone(session, "StartupCancellationObserved");
                ShutdownOnOwnerThread(session, application, dispatcher);
                return;
            }

            lock (HostGate)
            {
                session.DispatcherRunEntered = true;
            }

            SetMilestone(session, "DispatcherRunEntered");
            Dispatcher.Run();
            SetMilestone(session, "DispatcherRunExited");

            lock (HostGate)
            {
                if (session.State == HostState.Running && !session.ShutdownRequested)
                {
                    MarkFailureLocked(
                        session,
                        new InvalidOperationException(
                            "The WPF dispatcher exited without an owned shutdown request."),
                        "DispatcherExitedUnexpectedly");
                }
                else if (session.State == HostState.Stopping)
                {
                    session.State = HostState.Stopped;
                    session.LastTransitionUtc = DateTimeOffset.UtcNow;
                }
            }
        }
        catch (Exception exception)
        {
            FailStartupClosed(session, exception, "DispatcherThreadException");
        }
        finally
        {
            lock (HostGate)
            {
                if (!session.Ready.Task.IsCompleted)
                {
                    var failure = session.Failure ?? new InvalidOperationException(
                        "The WPF dispatcher exited before readiness was observed.");
                    MarkFailureLocked(session, failure, "DispatcherExitedBeforeReady");
                }

                if (session.State == HostState.Starting)
                {
                    session.State = HostState.Failed;
                    session.LastTransitionUtc = DateTimeOffset.UtcNow;
                }

                _lastSnapshot = CaptureSnapshotLocked(session);
                session.Exited.TrySetResult(true);
            }
        }
    }

    private static void SignalDispatcherReady(HostSession session)
    {
        var shouldStop = false;
        lock (HostGate)
        {
            if (session.ShutdownRequested || session.StopRequested.IsCancellationRequested)
            {
                shouldStop = true;
                MarkFailureLocked(
                    session,
                    session.Failure ?? new OperationCanceledException(
                        "WPF test host startup was cancelled before dispatcher readiness."),
                    "ReadinessCancelled");
            }
            else if (session.State == HostState.Starting)
            {
                session.State = HostState.Running;
                session.LastMilestone = "DispatcherReady";
                session.LastTransitionUtc = DateTimeOffset.UtcNow;
                session.Ready.TrySetResult(true);
            }
            else
            {
                shouldStop = true;
            }
        }

        if (shouldStop)
        {
            Dispatcher.CurrentDispatcher.BeginInvokeShutdown(DispatcherPriority.Send);
        }
    }

    private static void FailStartupClosed(
        HostSession session,
        Exception exception,
        string milestone)
    {
        lock (HostGate)
        {
            MarkFailureLocked(session, exception, milestone);
        }
    }

    private static void MarkFailureLocked(
        HostSession session,
        Exception exception,
        string milestone)
    {
        session.LastMilestone = milestone;
        session.FailureMilestone ??= milestone;
        session.Failure ??= exception;
        session.ShutdownRequested = true;
        session.StopRequested.Cancel();
        if (session.State is HostState.Starting or HostState.Running)
        {
            session.State = HostState.Failed;
            session.LastTransitionUtc = DateTimeOffset.UtcNow;
        }

        session.Ready.TrySetException(session.Failure);
    }

    private static void SetMilestone(HostSession session, string milestone)
    {
        lock (HostGate)
        {
            session.LastMilestone = milestone;
        }
    }

    private static void ThrowIfDispatcherFaultIsPending(HostSession session)
    {
        Exception? dispatcherFault;
        lock (HostGate)
        {
            dispatcherFault = session.DispatcherFault;
            if (dispatcherFault is not null)
            {
                session.DispatcherFault = null;
                session.LastMilestone = "DispatcherFaultObserved";
            }
        }

        if (dispatcherFault is not null)
        {
            throw CreateDispatcherFaultException(session, dispatcherFault);
        }
    }

    private static InvalidOperationException CreateDispatcherFaultException(
        HostSession session,
        Exception dispatcherFault)
    {
        return new InvalidOperationException(
            "The WPF dispatcher reported an unobserved callback exception. " +
            GetDiagnostics(session),
            dispatcherFault);
    }

    private static void HandleDispatcherUnhandledException(
        HostSession session,
        object? sender,
        DispatcherUnhandledExceptionEventArgs eventArgs)
    {
        CaptureDispatcherFault(session, eventArgs.Exception);

        // Preserve the owned dispatcher so WpfTestHost.Run can report the
        // original callback fault on the next ordered operation. This is not
        // a silent swallow: Shutdown also fails if the fault is never consumed.
        eventArgs.Handled = true;
    }

    private static void CaptureDispatcherFault(HostSession session, Exception exception)
    {
        lock (HostGate)
        {
            session.DispatcherFault ??= exception;
            session.LastMilestone = "DispatcherFaultCaptured";
            session.DispatcherFaultObserved.TrySetResult(exception);
        }
    }

    private static void RequestStopLocked(HostSession session)
    {
        session.ShutdownRequested = true;
        session.StopRequested.Cancel();
        if (session.State is HostState.Starting or HostState.Running)
        {
            session.State = HostState.Stopping;
            session.LastMilestone = "ShutdownRequested";
            session.LastTransitionUtc = DateTimeOffset.UtcNow;
        }
    }

    private static void RequestDispatcherShutdown(HostSession session)
    {
        Dispatcher? dispatcher;
        HerdrOps.App.App? application;
        lock (HostGate)
        {
            dispatcher = session.Dispatcher;
            application = session.Application;
        }

        if (dispatcher is null)
        {
            return;
        }

        try
        {
            if (dispatcher.CheckAccess())
            {
                ShutdownOnOwnerThread(session, application, dispatcher);
                return;
            }

            dispatcher.BeginInvoke(
                DispatcherPriority.Send,
                new Action(() => ShutdownOnOwnerThread(session, application, dispatcher)));
        }
        catch (Exception exception)
        {
            lock (HostGate)
            {
                session.CleanupFailure ??= exception;
                session.LastMilestone = "ShutdownRequestFailed";
            }
        }
    }

    private static void ShutdownOnOwnerThread(
        HostSession session,
        HerdrOps.App.App? application,
        Dispatcher dispatcher)
    {
        try
        {
            SetMilestone(session, "ShutdownOnOwnedThread");
            if (!dispatcher.HasShutdownStarted && !dispatcher.HasShutdownFinished)
            {
                application?.Shutdown();
                if (!dispatcher.HasShutdownStarted && !dispatcher.HasShutdownFinished)
                {
                    dispatcher.BeginInvokeShutdown(DispatcherPriority.Send);
                }
            }
        }
        catch (Exception exception)
        {
            lock (HostGate)
            {
                session.CleanupFailure ??= exception;
                session.LastMilestone = "ShutdownCleanupFailed";
            }

            try
            {
                if (!dispatcher.HasShutdownStarted && !dispatcher.HasShutdownFinished)
                {
                    dispatcher.BeginInvokeShutdown(DispatcherPriority.Send);
                }
            }
            catch (Exception fallbackException)
            {
                lock (HostGate)
                {
                    session.CleanupFailure ??= fallbackException;
                }
            }
        }
    }

    private static InvalidOperationException CreateUnavailableException(HostSession session)
    {
        return new InvalidOperationException(
            "WPF test host is unavailable and failed closed. " + GetDiagnostics(session),
            session.Failure ?? session.CleanupFailure);
    }

    private static InvalidOperationException CreateTerminalShutdownException()
    {
        return new InvalidOperationException(
            "WPF test host was already shut down and cannot be restarted in the same AppDomain. " +
            GetDiagnostics(null));
    }

    private static string GetDiagnostics(HostSession? session)
    {
        lock (HostGate)
        {
            session ??= _session;
            if (session is null)
            {
                return _lastSnapshot is null
                    ? "State: NotStarted."
                    : FormatSnapshot(_lastSnapshot);
            }

            return FormatSnapshot(CaptureSnapshotLocked(session));
        }
    }

    private static HostSnapshot CaptureSnapshotLocked(HostSession session)
    {
        return new HostSnapshot(
            session.Generation,
            session.State,
            session.LastMilestone,
            session.FailureMilestone,
            session.UiThread,
            session.DispatcherThreadId,
            session.Dispatcher,
            session.DispatcherRunEntered,
            session.Application is not null,
            session.Ready.Task.IsCompleted,
            session.Exited.Task.IsCompleted,
            session.CreatedUtc,
            session.LastTransitionUtc,
            session.Failure,
            session.CleanupFailure,
            session.DispatcherFault);
    }

    private static string FormatSnapshot(HostSnapshot snapshot)
    {
        var builder = new StringBuilder();
        builder.Append("Generation: ").AppendLine(snapshot.Generation.ToString());
        builder.Append("State: ").AppendLine(snapshot.State.ToString());
        builder.Append("LastMilestone: ").AppendLine(snapshot.LastMilestone);
        builder.Append("FailureMilestone: ").AppendLine(snapshot.FailureMilestone ?? "NOT OBSERVED");
        builder.Append("OwnedThreadId: ").AppendLine(snapshot.UiThread?.ManagedThreadId.ToString() ?? "NOT OBSERVED");
        builder.Append("OwnedThreadState: ").AppendLine(snapshot.UiThread?.ThreadState.ToString() ?? "NOT OBSERVED");
        builder.Append("OwnedThreadAlive: ").AppendLine((snapshot.UiThread?.IsAlive == true).ToString());
        builder.Append("OwnedThreadApartment: ").AppendLine(GetApartmentState(snapshot.UiThread));
        builder.Append("DispatcherThreadId: ").AppendLine(snapshot.DispatcherThreadId?.ToString() ?? "NOT OBSERVED");
        builder.Append("DispatcherAvailable: ").AppendLine((snapshot.Dispatcher is not null).ToString());
        builder.Append("DispatcherRunEntered: ").AppendLine(snapshot.DispatcherRunEntered.ToString());
        builder.Append("DispatcherShutdownStarted: ").AppendLine(snapshot.Dispatcher?.HasShutdownStarted.ToString() ?? "NOT OBSERVED");
        builder.Append("DispatcherShutdownFinished: ").AppendLine(snapshot.Dispatcher?.HasShutdownFinished.ToString() ?? "NOT OBSERVED");
        builder.Append("ApplicationOwned: ").AppendLine(snapshot.ApplicationOwned.ToString());
        builder.Append("ReadyCompleted: ").AppendLine(snapshot.ReadyCompleted.ToString());
        builder.Append("ExitedCompleted: ").AppendLine(snapshot.ExitedCompleted.ToString());
        builder.Append("CreatedUtc: ").AppendLine(snapshot.CreatedUtc.ToString("O"));
        builder.Append("LastTransitionUtc: ").AppendLine(snapshot.LastTransitionUtc.ToString("O"));
        builder.Append("StartupFailure: ").AppendLine(FormatException(snapshot.Failure));
        builder.Append("CleanupFailure: ").AppendLine(FormatException(snapshot.CleanupFailure));
        builder.Append("DispatcherFault: ").AppendLine(FormatException(snapshot.DispatcherFault));
        return builder.ToString().TrimEnd();
    }

    private static string GetApartmentState(Thread? thread)
    {
        if (thread is null)
        {
            return "NOT OBSERVED";
        }

        try
        {
            return thread.GetApartmentState().ToString();
        }
        catch (Exception exception)
        {
            return $"ERROR:{exception.GetType().Name}";
        }
    }

    private static string FormatException(Exception? exception)
    {
        return exception is null
            ? "NOT OBSERVED"
            : $"{exception.GetType().FullName}: {exception.Message}";
    }

    private enum HostState
    {
        Starting,
        Running,
        Stopping,
        Stopped,
        Failed,
    }

    private sealed class HostSession
    {
        public HostSession(int generation)
        {
            Generation = generation;
            DispatcherUnhandledExceptionHandler =
                (sender, eventArgs) => HandleDispatcherUnhandledException(this, sender, eventArgs);
        }

        public int Generation { get; }
        public HostState State { get; set; } = HostState.Starting;
        public Thread? UiThread { get; set; }
        public Dispatcher? Dispatcher { get; set; }
        public HerdrOps.App.App? Application { get; set; }
        public int? DispatcherThreadId { get; set; }
        public bool DispatcherRunEntered { get; set; }
        public bool ShutdownRequested { get; set; }
        public string LastMilestone { get; set; } = "SessionCreated";
        public string? FailureMilestone { get; set; }
        public Exception? Failure { get; set; }
        public Exception? CleanupFailure { get; set; }
        public Exception? DispatcherFault { get; set; }
        public DispatcherUnhandledExceptionEventHandler DispatcherUnhandledExceptionHandler { get; }
        public TaskCompletionSource<Exception> DispatcherFaultObserved { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);
        public DateTimeOffset CreatedUtc { get; } = DateTimeOffset.UtcNow;
        public DateTimeOffset LastTransitionUtc { get; set; } = DateTimeOffset.UtcNow;
        public CancellationTokenSource StopRequested { get; } = new();
        public TaskCompletionSource<bool> Ready { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public TaskCompletionSource<bool> Exited { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
    }

    private sealed record HostSnapshot(
        int Generation,
        HostState State,
        string LastMilestone,
        string? FailureMilestone,
        Thread? UiThread,
        int? DispatcherThreadId,
        Dispatcher? Dispatcher,
        bool DispatcherRunEntered,
        bool ApplicationOwned,
        bool ReadyCompleted,
        bool ExitedCompleted,
        DateTimeOffset CreatedUtc,
        DateTimeOffset LastTransitionUtc,
        Exception? Failure,
        Exception? CleanupFailure,
        Exception? DispatcherFault);
}
