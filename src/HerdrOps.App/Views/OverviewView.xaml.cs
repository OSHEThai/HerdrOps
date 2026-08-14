using System.Windows;
using System.Windows.Controls;
using HerdrOps.App.Overview;
using HerdrOps.App.Widgets;

namespace HerdrOps.App.Views;

/// <summary>
/// Approved Overview composition. Standalone previews use the v0.1 fixture;
/// the production shell supplies the live Core-backed state adapter.
/// </summary>
public partial class OverviewView : UserControl
{
    private const double CompactHeightBreakpoint = 600;
    private WidgetGalleryWindow? _galleryWindow;

    public OverviewView()
        : this(SyntheticOverviewState.Create())
    {
    }

    public OverviewView(SyntheticOverviewState state)
    {
        InitializeComponent();
        DataContext = state;
    }

    private void OnOverviewSizeChanged(object sender, SizeChangedEventArgs e)
    {
        var compact = e.NewSize.Height < CompactHeightBreakpoint;
        OverviewRoot.Margin = compact ? new Thickness(10) : new Thickness(16);
        SourceRow.Height = new GridLength(compact ? 20 : 28);
        SummaryRow.Height = new GridLength(compact ? 130 : 160);
        SummaryGapRow.Height = new GridLength(compact ? 8 : 12);
        RecentHeaderRow.Height = new GridLength(compact ? 44 : 54);
        RecentFooterRow.Height = new GridLength(compact ? 24 : 32);
        ScoreHeaderRow.Height = new GridLength(compact ? 32 : 42);
        WorkstreamHeaderRow.Height = new GridLength(compact ? 32 : 42);
        TopAgentsHeaderRow.Height = new GridLength(compact ? 36 : 48);
        AlertsHeaderRow.Height = new GridLength(compact ? 36 : 48);
    }

    private void OnOpenWidgetGalleryClick(object sender, RoutedEventArgs e)
    {
        if (_galleryWindow is null || !_galleryWindow.IsLoaded)
        {
            _galleryWindow = new WidgetGalleryWindow
            {
                Owner = Window.GetWindow(this),
            };
            _galleryWindow.Closed += (_, _) => _galleryWindow = null;
            _galleryWindow.Show();
            return;
        }

        _galleryWindow.Activate();
    }
}
