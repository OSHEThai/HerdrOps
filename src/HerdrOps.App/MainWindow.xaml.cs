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

    // Kept for the existing runtime report contract. Working-set compaction is
    // intentionally not performed by the WPF process lifecycle.
    public bool DashboardWorkingSetCompactionAttempted => false;

    public bool DashboardWorkingSetCompactionSucceeded => false;

    public int? DashboardWorkingSetCompactionNativeErrorCode => null;

    public double DashboardWorkingSetBeforeMegabytes => 0;

    public double DashboardWorkingSetAfterMegabytes => 0;

    public double DashboardPrivateMemoryBeforeMegabytes => 0;

    public double DashboardPrivateMemoryAfterMegabytes => 0;

    public double DashboardManagedHeapBeforeMegabytes => 0;

    public double DashboardManagedHeapAfterMegabytes => 0;

    public Task WaitForDashboardCleanupAsync(CancellationToken cancellationToken) =>
        Task.CompletedTask.WaitAsync(cancellationToken);

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
