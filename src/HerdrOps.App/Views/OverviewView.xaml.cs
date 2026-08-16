using System.Windows;
using System.Windows.Controls;
using HerdrOps.App.Overview;
using HerdrOps.App.Widgets;

namespace HerdrOps.App.Views;

/// <summary>
/// Approved Overview composition. Standalone previews use the v0.1 fixture;
/// the production shell supplies the live Core-backed state adapter.
/// </summary>
public partial class OverviewView : UserControl, IPageResourceOwner
{
    private const double CompactHeightBreakpoint = 600;
    private WidgetGalleryWindow? _galleryWindow;
    private IWidgetState? _widgetState = SyntheticWidgetState.Create();
    private bool _resourcesReleased;

    public OverviewView()
        : this(SyntheticOverviewState.Create())
    {
    }

    public OverviewView(SyntheticOverviewState state)
    {
        InitializeComponent();
        DataContext = state;
    }

    public void UseWidgetState(IWidgetState state)
    {
        ArgumentNullException.ThrowIfNull(state);
        ObjectDisposedException.ThrowIf(_resourcesReleased, this);
        _widgetState = state;
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
        if (_resourcesReleased || _widgetState is null)
        {
            return;
        }

        if (_galleryWindow is null || !_galleryWindow.IsLoaded)
        {
            _galleryWindow = new WidgetGalleryWindow(_widgetState)
            {
                Owner = Window.GetWindow(this),
            };
            _galleryWindow.Closed += OnGalleryClosed;
            _galleryWindow.Show();
            return;
        }

        _galleryWindow.Activate();
    }

    public void ReleaseResources()
    {
        if (_resourcesReleased)
        {
            return;
        }

        _resourcesReleased = true;
        if (_galleryWindow is { } galleryWindow)
        {
            galleryWindow.Closed -= OnGalleryClosed;
            galleryWindow.ReleaseResources();
            if (galleryWindow.IsLoaded)
            {
                galleryWindow.Close();
            }

            _galleryWindow = null;
        }

        _widgetState = null;
        DataContext = null;
    }

    private void OnGalleryClosed(object? sender, EventArgs e)
    {
        if (ReferenceEquals(sender, _galleryWindow))
        {
            _galleryWindow = null;
        }
    }
}
