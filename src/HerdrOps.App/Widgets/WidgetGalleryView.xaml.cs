using System.Windows;
using System.Windows.Controls;

namespace HerdrOps.App.Widgets;

/// <summary>
/// Opens all approved widget variants and presents a deterministic visual comparison board.
/// </summary>
public partial class WidgetGalleryView : UserControl
{
    private readonly IWidgetWindowLauncher _launcher;
    private readonly SyntheticWidgetState _state;

    public WidgetGalleryView()
        : this(SyntheticWidgetState.Create(), launcher: null)
    {
    }

    public WidgetGalleryView(
        SyntheticWidgetState state,
        IWidgetWindowLauncher? launcher)
    {
        ArgumentNullException.ThrowIfNull(state);
        _state = state;
        _launcher = launcher ?? new WidgetWindowLauncher(state);

        InitializeComponent();
        foreach (var preview in GetPreviews())
        {
            preview.SetState(state);
        }
    }

    public IReadOnlyList<WidgetVariantDescriptor> Variants => WidgetCatalog.All;

    public void OpenVariant(WidgetVariant variant) => _launcher.Open(variant);

    private IEnumerable<WidgetSurface> GetPreviews()
    {
        yield return CompactPreview;
        yield return NormalPreview;
        yield return ExpandedPreview;
        yield return MiniPreview;
        yield return VerticalPreview;
        yield return NotificationPreview;
        yield return AgentDetailPreview;
    }

    private void OnOpenWidgetClick(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: string value } &&
            Enum.TryParse<WidgetVariant>(value, ignoreCase: false, out var variant))
        {
            OpenVariant(variant);
        }
    }

    private void OnOpenDashboardClick(object sender, RoutedEventArgs e)
    {
        if (Application.Current.MainWindow is { } mainWindow)
        {
            mainWindow.Show();
            mainWindow.Activate();
        }
    }
}
