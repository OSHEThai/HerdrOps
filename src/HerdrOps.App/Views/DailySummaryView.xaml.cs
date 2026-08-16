using System.Windows;
using System.Windows.Controls;

namespace HerdrOps.App.Views;

public partial class DailySummaryView : UserControl
{
    public DailySummaryView()
    {
        InitializeComponent();
    }

    private void OnSizeChanged(object sender, SizeChangedEventArgs e)
    {
        DailySummaryScrollViewer.Padding = e.NewSize.Width < 1200
            ? new Thickness(10, 10, 10, 14)
            : new Thickness(16, 14, 16, 18);
    }
}
