using System.Windows;
using System.Windows.Controls;

namespace HerdrOps.App.Widgets;

/// <summary>
/// Opens all approved widget variants and presents a deterministic visual comparison board.
/// </summary>
public partial class WidgetGalleryView : UserControl
{
    private const double AdaptiveWidthBreakpoint = 1400;
    private const double AdaptiveHeightBreakpoint = 900;
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
        AdaptiveItems = WidgetCatalog.CreateAdaptiveGalleryItems();

        InitializeComponent();
        foreach (var preview in GetPreviews())
        {
            preview.SetState(state);
        }
    }

    public IReadOnlyList<WidgetVariantDescriptor> Variants => WidgetCatalog.All;

    public IReadOnlyList<WidgetGalleryItem> AdaptiveItems { get; }

    public SyntheticWidgetState SharedState => _state;

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
        if (sender is not Button { Tag: var tag })
        {
            return;
        }

        if (string.Equals(tag?.ToString(), "Dashboard", StringComparison.Ordinal))
        {
            ActivateDashboard();
            return;
        }

        if (Enum.TryParse<WidgetVariant>(tag?.ToString(), ignoreCase: false, out var variant))
        {
            OpenVariant(variant);
        }
    }

    private void OnOpenDashboardClick(object sender, RoutedEventArgs e)
    {
        ActivateDashboard();
    }

    private static void ActivateDashboard()
    {
        if (Application.Current.MainWindow is { } mainWindow)
        {
            mainWindow.Show();
            mainWindow.Activate();
        }
    }

    private void OnGallerySizeChanged(object sender, SizeChangedEventArgs e)
    {
        var useAdaptiveLayout =
            e.NewSize.Width < AdaptiveWidthBreakpoint ||
            e.NewSize.Height < AdaptiveHeightBreakpoint;
        FullGallery.Visibility = useAdaptiveLayout ? Visibility.Collapsed : Visibility.Visible;
        AdaptiveGallery.Visibility = useAdaptiveLayout ? Visibility.Visible : Visibility.Collapsed;
    }
}
