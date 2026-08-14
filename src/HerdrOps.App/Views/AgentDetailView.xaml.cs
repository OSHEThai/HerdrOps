using System.Windows;
using System.Windows.Controls;

namespace HerdrOps.App.Views;

public partial class AgentDetailView : UserControl
{
    private const double CompactHeightBreakpoint = 650;

    public AgentDetailView()
    {
        InitializeComponent();
    }

    private void OnViewSizeChanged(object sender, SizeChangedEventArgs e)
    {
        var compact = e.NewSize.Height < CompactHeightBreakpoint;
        AgentDetailRoot.Margin = compact ? new Thickness(10) : new Thickness(16);
        SourceRow.Height = new GridLength(compact ? 20 : 28);
        IdentityRow.Height = new GridLength(compact ? 154 : 184);
    }
}
