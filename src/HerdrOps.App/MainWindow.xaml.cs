using System.Windows;
using HerdrOps.App.Live;
using HerdrOps.App.Views;
using HerdrOps.App.Widgets;

namespace HerdrOps.App;

/// <summary>
/// Hosts the shared dashboard shell. Page content is introduced by version-scoped issues.
/// </summary>
public partial class MainWindow : Window
{
    private ShellView? _shell;
    private bool _resourcesReleased;

    public MainWindow()
        : this(new LiveDashboardState())
    {
    }

    public MainWindow(LiveDashboardState state)
    {
        ArgumentNullException.ThrowIfNull(state);
        InitializeComponent();
        _shell = new ShellView(state);
        ShellHost.Content = _shell;
        Closed += OnClosed;
    }

    public ShellView Shell => _shell ?? throw new InvalidOperationException(
        "The Dashboard visual tree has already been released.");

    public bool DashboardResourcesReleased =>
        _shell is null && ShellHost.Content is null;

    private void OnClosed(object? sender, EventArgs e)
    {
        if (_resourcesReleased)
        {
            return;
        }

        _resourcesReleased = true;
        Closed -= OnClosed;
        _shell?.ReleaseResources();
        ShellHost.Content = null;
        _shell = null;
    }
}
