using System.Windows;
using HerdrOps.App.Live;
using HerdrOps.App.Views;

namespace HerdrOps.App;

/// <summary>
/// Hosts the shared dashboard shell. Page content is introduced by version-scoped issues.
/// </summary>
public partial class MainWindow : Window
{
    public MainWindow()
        : this(new LiveDashboardState())
    {
    }

    public MainWindow(LiveDashboardState state)
    {
        ArgumentNullException.ThrowIfNull(state);
        InitializeComponent();
        Shell = new ShellView(state);
        ShellHost.Content = Shell;
    }

    public ShellView Shell { get; }
}
