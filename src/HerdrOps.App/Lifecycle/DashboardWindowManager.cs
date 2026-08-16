using System.Windows;

namespace HerdrOps.App.Lifecycle;

/// <summary>
/// Owns the single Dashboard window reference. A user close is handled by
/// MainWindow as hide-to-tray; an actual close clears the reference so the next
/// restore creates a fresh visual tree instead of retaining a closed window.
/// </summary>
public sealed class DashboardWindowManager : IDisposable
{
    private readonly Func<MainWindow> _factory;
    private MainWindow? _window;
    private bool _disposed;

    public DashboardWindowManager(Func<MainWindow> factory)
    {
        _factory = factory ?? throw new ArgumentNullException(nameof(factory));
    }

    public MainWindow? Current => _window is { IsClosed: false, DashboardResourcesReleased: false }
        ? _window
        : null;

    public MainWindow GetOrCreate()
    {
        ThrowIfDisposed();
        if (Current is { } current)
        {
            return current;
        }

        DetachClosedWindow();
        var created = _factory();
        created.CloseToTrayOnUserClose = true;
        created.Closed += OnWindowClosed;
        _window = created;
        if (Application.Current is { } application)
        {
            application.MainWindow = created;
        }

        return created;
    }

    public void Show()
    {
        var window = GetOrCreate();
        window.Show();
        if (window.WindowState == System.Windows.WindowState.Minimized)
        {
            window.WindowState = System.Windows.WindowState.Normal;
        }

        window.Activate();
    }

    public void Hide() => Current?.Hide();

    public void CloseForShutdown()
    {
        var window = Current;
        if (window is null)
        {
            DetachClosedWindow();
            return;
        }

        window.CloseToTrayOnUserClose = false;
        window.CloseForShutdown();
        if (window.IsClosed)
        {
            DetachClosedWindow();
        }
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        CloseForShutdown();
        _disposed = true;
    }

    private void OnWindowClosed(object? sender, EventArgs e)
    {
        if (ReferenceEquals(sender, _window))
        {
            DetachClosedWindow();
        }
    }

    private void DetachClosedWindow()
    {
        var window = _window;
        if (window is null)
        {
            return;
        }

        window.Closed -= OnWindowClosed;
        _window = null;
        if (ReferenceEquals(Application.Current?.MainWindow, window))
        {
            Application.Current.MainWindow = null;
        }
    }

    private void ThrowIfDisposed() => ObjectDisposedException.ThrowIf(_disposed, this);
}
