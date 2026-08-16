using System.Windows;
using HerdrOps.App.Lifecycle;
using HerdrOps.Domain.Settings;

namespace HerdrOps.App.Widgets;

public interface IWidgetWindowLauncher
{
    void Open(WidgetVariant variant);
}

public interface IWidgetWindowLifecycle : IWidgetWindowLauncher
{
    void ApplySettings(AppSettings settings);

    void CloseAll();
}

/// <summary>
/// Opens real widget windows while preserving one shared state object.
/// </summary>
public sealed class WidgetWindowLauncher : IWidgetWindowLifecycle, IDisposable
{
    private readonly IWidgetState _state;
    private readonly IWidgetActionRouter _actionRouter;
    private readonly Dictionary<WidgetVariant, WidgetWindow> _windows = [];
    private WidgetVariant? _configuredVariant;
    private bool _disposed;

    public WidgetWindowLauncher(IWidgetState state, IWidgetActionRouter? actionRouter = null)
    {
        ArgumentNullException.ThrowIfNull(state);
        _state = state;
        _actionRouter = actionRouter ?? ApplicationWidgetActionRouter.Shared;
    }

    public void Open(WidgetVariant variant)
    {
        ThrowIfDisposed();
        if (_windows.TryGetValue(variant, out var existing))
        {
            if (existing.IsClosed)
            {
                RemoveWindow(variant, existing);
            }
            else
            {
                ShowAndActivate(existing);
                return;
            }
        }

        var window = new WidgetWindow(WidgetCatalog.Get(variant), _state, _actionRouter);
        window.Closed += OnWindowClosed;
        _windows.Add(variant, window);
        try
        {
            ShowAndActivate(window);
        }
        catch (Exception primary)
        {
            try
            {
                window.Close();
            }
            catch (Exception cleanup)
            {
                throw new AggregateException(primary, cleanup);
            }

            RemoveWindow(variant, window);
            throw;
        }
    }

    public int OpenWindowCount => _windows.Count;

    public IReadOnlyCollection<WidgetWindow> OpenWindows => _windows.Values.ToArray();

    public void ApplySettings(AppSettings settings)
    {
        ThrowIfDisposed();
        var admitted = AppSettingsContract.Admit(settings);
        if (!admitted.WidgetEnabled)
        {
            _configuredVariant = null;
            CloseAll();
            return;
        }

        var variant = AppSettingsLifecycleMapping.ToWidgetVariant(admitted.WidgetVariant);
        if (_configuredVariant is { } previous && previous != variant)
        {
            Close(previous);
        }

        _configuredVariant = variant;
        Open(variant);
    }

    public void CloseAll()
    {
        var failures = new List<ShutdownCleanupFailure>();
        foreach (var (variant, window) in _windows
                     .OrderBy(pair => pair.Key)
                     .ToArray())
        {
            try
            {
                Close(variant, window);
            }
            catch (Exception exception)
            {
                failures.Add(new ShutdownCleanupFailure($"widget:{variant}", exception));
            }
        }

        if (failures.Count > 0)
        {
            throw new ShutdownCleanupException(failures);
        }
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        CloseAll();
        _disposed = true;
    }

    private void Close(WidgetVariant variant)
    {
        if (_windows.TryGetValue(variant, out var window))
        {
            Close(variant, window);
        }
    }

    private void Close(WidgetVariant variant, WidgetWindow window)
    {
        if (!window.IsClosed)
        {
            window.Close();
        }

        if (window.IsClosed)
        {
            RemoveWindow(variant, window);
        }
    }

    private void ShowAndActivate(WidgetWindow window)
    {
        window.Show();
        if (window.WindowState == WindowState.Minimized)
        {
            window.WindowState = WindowState.Normal;
        }

        window.Activate();
    }

    private void OnWindowClosed(object? sender, EventArgs e)
    {
        if (sender is not WidgetWindow window)
        {
            return;
        }

        var pair = _windows.FirstOrDefault(candidate => ReferenceEquals(candidate.Value, window));
        if (!EqualityComparer<KeyValuePair<WidgetVariant, WidgetWindow>>.Default.Equals(pair, default))
        {
            RemoveWindow(pair.Key, pair.Value);
        }
    }

    private void RemoveWindow(WidgetVariant variant, WidgetWindow window)
    {
        window.Closed -= OnWindowClosed;
        if (_windows.TryGetValue(variant, out var current) && ReferenceEquals(current, window))
        {
            _windows.Remove(variant);
        }
    }

    private void ThrowIfDisposed() => ObjectDisposedException.ThrowIf(_disposed, this);
}
