using HerdrOps.Domain.Settings;

namespace HerdrOps.Domain.Lifecycle;

/// <summary>
/// Commands exposed by the HerdrOps notification-area menu.
/// </summary>
public enum TrayCommand
{
    ShowDashboard,
    ShowConfiguredWidget,
    SelectThaiLanguage,
    SelectEnglishLanguage,
    Exit,
}

public sealed record TrayMenuItem
{
    public TrayMenuItem(TrayCommand command, string label, bool isChecked = false)
    {
        if (string.IsNullOrWhiteSpace(label))
        {
            throw new ArgumentException("A tray menu label is required.", nameof(label));
        }

        Command = command;
        Label = label;
        IsChecked = isChecked;
    }

    public TrayCommand Command { get; }

    public string Label { get; }

    public bool IsChecked { get; }
}

/// <summary>
/// Immutable menu data passed to an OS-specific tray backend.
/// The model itself enforces the one-selected-language invariant.
/// </summary>
public sealed class TrayMenuModel
{
    public TrayMenuModel(string toolTipText, IReadOnlyList<TrayMenuItem> items)
    {
        if (string.IsNullOrWhiteSpace(toolTipText))
        {
            throw new ArgumentException("A tray tooltip is required.", nameof(toolTipText));
        }

        ArgumentNullException.ThrowIfNull(items);
        var materializedItems = items.ToArray();
        if (materializedItems.Length == 0)
        {
            throw new ArgumentException("At least one tray menu item is required.", nameof(items));
        }

        if (materializedItems
            .GroupBy(item => item.Command)
            .Any(group => group.Count() != 1))
        {
            throw new ArgumentException("Tray menu commands must be unique.", nameof(items));
        }

        var languageItems = materializedItems
            .Where(item => item.Command is
                TrayCommand.SelectThaiLanguage or TrayCommand.SelectEnglishLanguage)
            .ToArray();
        if (languageItems.Length != 2 || languageItems.Count(item => item.IsChecked) != 1)
        {
            throw new ArgumentException(
                "A tray menu must expose exactly one selected Thai or English language.",
                nameof(items));
        }

        ToolTipText = toolTipText;
        Items = Array.AsReadOnly(materializedItems);
    }

    public string ToolTipText { get; }

    public IReadOnlyList<TrayMenuItem> Items { get; }
}

public interface ITrayBackend : IDisposable
{
    void Show(TrayMenuModel menu, Action<TrayCommand> commandHandler);

    void Update(TrayMenuModel menu);

    void Hide();
}

public interface ITrayCommandTarget
{
    void ShowDashboard();

    void ShowConfiguredWidget();

    void SelectLanguage(AppSettingsLanguage language);

    void Exit();
}

public interface ITrayController : IDisposable
{
    bool IsStarted { get; }

    void Start();

    void Refresh();

    void Stop();
}

/// <summary>
/// Routes menu commands without knowing whether the target is WPF, synthetic,
/// or another host. Target exceptions intentionally propagate to the caller.
/// </summary>
public sealed class TrayCommandRouter
{
    private readonly ITrayCommandTarget _target;

    public TrayCommandRouter(ITrayCommandTarget target)
    {
        _target = target ?? throw new ArgumentNullException(nameof(target));
    }

    public void Execute(TrayCommand command)
    {
        switch (command)
        {
            case TrayCommand.ShowDashboard:
                _target.ShowDashboard();
                break;
            case TrayCommand.ShowConfiguredWidget:
                _target.ShowConfiguredWidget();
                break;
            case TrayCommand.SelectThaiLanguage:
                _target.SelectLanguage(AppSettingsLanguage.Thai);
                break;
            case TrayCommand.SelectEnglishLanguage:
                _target.SelectLanguage(AppSettingsLanguage.English);
                break;
            case TrayCommand.Exit:
                _target.Exit();
                break;
            default:
                throw new ArgumentOutOfRangeException(nameof(command), command, "Unknown tray command.");
        }
    }
}

/// <summary>
/// Owns the lifecycle of a tray backend while keeping menu creation and command
/// targets injectable. It never creates an OS resource until Start is called.
/// </summary>
public sealed class TrayLifecycleController : ITrayController
{
    private readonly ITrayBackend _backend;
    private readonly Func<TrayMenuModel> _menuFactory;
    private readonly TrayCommandRouter _router;
    private bool _disposed;

    public TrayLifecycleController(
        ITrayBackend backend,
        Func<TrayMenuModel> menuFactory,
        ITrayCommandTarget target)
    {
        _backend = backend ?? throw new ArgumentNullException(nameof(backend));
        _menuFactory = menuFactory ?? throw new ArgumentNullException(nameof(menuFactory));
        _router = new TrayCommandRouter(target);
    }

    public bool IsStarted { get; private set; }

    public void Start()
    {
        ThrowIfDisposed();
        if (IsStarted)
        {
            return;
        }

        _backend.Show(_menuFactory(), _router.Execute);
        IsStarted = true;
    }

    public void Refresh()
    {
        ThrowIfDisposed();
        if (IsStarted)
        {
            _backend.Update(_menuFactory());
        }
    }

    public void Stop()
    {
        if (!IsStarted)
        {
            return;
        }

        IsStarted = false;
        _backend.Hide();
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        try
        {
            Stop();
        }
        finally
        {
            _disposed = true;
            _backend.Dispose();
        }
    }

    private void ThrowIfDisposed()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
    }
}
