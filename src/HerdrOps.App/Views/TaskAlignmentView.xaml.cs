using System.Windows;
using System.Windows.Controls;

namespace HerdrOps.App.Views;

public partial class TaskAlignmentView : UserControl
{
    private const double CompactHeightBreakpoint = 700;

    public TaskAlignmentView()
    {
        InitializeComponent();
    }

    private void OnViewSizeChanged(object sender, SizeChangedEventArgs e)
    {
        var compact = e.NewSize.Height < CompactHeightBreakpoint;
        AlignmentRoot.Margin = compact ? new Thickness(10) : new Thickness(14);
        SourceRow.Height = new GridLength(compact ? 22 : 26);
        VerdictRow.Height = new GridLength(compact ? 52 : 58);
        HeaderRow.Height = new GridLength(compact ? 104 : 116);
        PanelGrid.MinHeight = compact ? 420 : 470;
    }
}
