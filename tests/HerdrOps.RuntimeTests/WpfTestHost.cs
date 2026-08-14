using System.Threading;
using System.Windows;
using System.Windows.Threading;

namespace HerdrOps.RuntimeTests;

/// <summary>
/// Owns the single WPF Application allowed per test process and serializes UI work on its STA dispatcher.
/// </summary>
internal static class WpfTestHost
{
    private static readonly ManualResetEventSlim Ready = new(initialState: false);
    private static readonly object StartGate = new();
    private static Thread? _uiThread;
    private static Dispatcher? _dispatcher;
    private static Exception? _startupFailure;
    private static bool _started;

    public static void Run(Action action, TimeSpan? timeout = null)
    {
        ArgumentNullException.ThrowIfNull(action);
        EnsureStarted();
        var dispatcher = _dispatcher ?? throw new InvalidOperationException("WPF dispatcher is unavailable.");
        var operation = dispatcher.InvokeAsync(action, DispatcherPriority.Send);
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
            throw new TimeoutException($"WPF operation exceeded {effectiveTimeout.TotalSeconds:0} seconds.");
        }

        task.GetAwaiter().GetResult();
    }

    private static void EnsureStarted()
    {
        lock (StartGate)
        {
            if (_started)
            {
                return;
            }

            _uiThread = new Thread(StartDispatcher)
            {
                IsBackground = true,
                Name = "HerdrOps WPF Runtime Test Host",
            };
            _uiThread.SetApartmentState(ApartmentState.STA);
            _uiThread.Start();

            if (!Ready.Wait(TimeSpan.FromSeconds(10)))
            {
                throw new TimeoutException("WPF test host did not start within 10 seconds.");
            }

            if (_startupFailure is not null)
            {
                throw new InvalidOperationException("WPF test host failed to initialize.", _startupFailure);
            }

            _started = true;
        }
    }

    private static void StartDispatcher()
    {
        try
        {
            var application = new HerdrOps.App.App
            {
                ShutdownMode = ShutdownMode.OnExplicitShutdown,
            };
            application.InitializeComponent();
            _dispatcher = Dispatcher.CurrentDispatcher;
        }
        catch (Exception exception)
        {
            _startupFailure = exception;
        }
        finally
        {
            Ready.Set();
        }

        if (_startupFailure is null)
        {
            Dispatcher.Run();
        }
    }
}
