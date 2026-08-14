using System.Windows;
using System.Windows.Controls;
using HerdrOps.App.Activity;

namespace HerdrOps.App.Views;

public partial class RealtimeActivityView : UserControl
{
    private const double CompactHeightBreakpoint = 700;

    public RealtimeActivityView()
        : this(RealtimeActivityState.CreateSyntheticPreview())
    {
    }

    public RealtimeActivityView(RealtimeActivityState state)
    {
        ArgumentNullException.ThrowIfNull(state);
        InitializeComponent();
        DataContext = state;
    }

    private void OnLoadMoreClick(object sender, RoutedEventArgs e)
    {
        if (DataContext is RealtimeActivityState state)
        {
            state.LoadMore();
        }
    }

    private void OnViewSizeChanged(object sender, SizeChangedEventArgs e)
    {
        var compact = e.NewSize.Height < CompactHeightBreakpoint;
        ActivityRoot.Margin = compact ? new Thickness(10) : new Thickness(14);
        SourceRow.Height = new GridLength(compact ? 22 : 26);
        SummaryRow.Height = new GridLength(compact ? 92 : 104);
        FiltersRow.Height = new GridLength(compact ? 62 : 68);
    }
}
