using System.Windows;
using System.Windows.Controls;
using HerdrOps.App.Files;

namespace HerdrOps.App.Views;

public partial class FileActivityView : UserControl
{
    private const double CompactHeightBreakpoint = 720;

    public FileActivityView()
        : this(FileActivityState.CreateSyntheticPreview())
    {
    }

    public FileActivityView(FileActivityState state)
    {
        ArgumentNullException.ThrowIfNull(state);
        InitializeComponent();
        DataContext = state;
    }

    private void OnViewSizeChanged(object sender, SizeChangedEventArgs e)
    {
        var compact = e.NewSize.Height < CompactHeightBreakpoint;
        FileRoot.Margin = compact ? new Thickness(10) : new Thickness(14);
        SourceRow.Height = new GridLength(compact ? 22 : 25);
        SummaryRow.Height = new GridLength(compact ? 90 : 104);
        FilterRow.Height = new GridLength(compact ? 42 : 48);
        AnalyticsRow.Height = new GridLength(compact ? 132 : 164);
    }
}
