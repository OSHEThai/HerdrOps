using System.Windows;
using System.ComponentModel;
using HerdrOps.App.Live;
using HerdrOps.App.Localization;
using HerdrOps.App.Views;
using HerdrOps.App.Widgets;
using HerdrOps.Domain.Settings;

namespace HerdrOps.App;

/// <summary>
/// Hosts the shared dashboard shell. Page content is introduced by version-scoped issues.
/// </summary>
public partial class MainWindow : Window
{
    private ShellView? _shell;
    private bool _resourcesReleased;
    private bool _allowClose;
    private bool _isClosed;

    public MainWindow()
        : this(new LiveDashboardState(), null, null, null, null)
    {
    }

    public MainWindow(LiveDashboardState state)
        : this(state, null, null, null, null)
    {
    }

    public MainWindow(
        LiveDashboardState state,
        Action<UiLanguage>? languageSelector,
        Action<AppSettingsWidgetVariant>? widgetSelected,
        Action<bool>? widgetEnabled,
        IWidgetWindowLauncher? widgetLauncher)
    {
        ArgumentNullException.ThrowIfNull(state);
        InitializeComponent();
        _shell = new ShellView(
            state,
            languageSelector,
            widgetSelected,
            widgetEnabled,
            widgetLauncher);
        ShellHost.Content = _shell;
        Closing += OnClosing;
        Closed += OnClosed;
    }

    public ShellView Shell => _shell ?? throw new InvalidOperationException(
        "The Dashboard visual tree has already been released.");

    public bool DashboardResourcesReleased =>
        _shell is null && ShellHost.Content is null;

    public bool IsClosed => _isClosed;

    /// <summary>
    /// The production dashboard is hidden when a user closes it so the tray
    /// remains the owner of the process. Shutdown callers set AllowClose before
    /// closing; direct test windows retain normal WPF close behavior.
    /// </summary>
    public bool CloseToTrayOnUserClose { get; set; }

    public event EventHandler? HiddenToTray;

    public void AllowClose() => _allowClose = true;

    public void CloseForShutdown()
    {
        if (_isClosed)
        {
            return;
        }

        AllowClose();
        Close();
    }

    private void OnClosing(object? sender, CancelEventArgs e)
    {
        if (!CloseToTrayOnUserClose || _allowClose)
        {
            return;
        }

        e.Cancel = true;
        Hide();
        HiddenToTray?.Invoke(this, EventArgs.Empty);
    }

    private void OnClosed(object? sender, EventArgs e)
    {
        if (_resourcesReleased)
        {
            return;
        }

        _resourcesReleased = true;
        _isClosed = true;
        Closing -= OnClosing;
        Closed -= OnClosed;
        _shell?.ReleaseResources();
        ShellHost.Content = null;
        _shell = null;
    }
}
