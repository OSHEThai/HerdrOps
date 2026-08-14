using System.Windows;
using System.Windows.Controls;
using HerdrOps.App.Organization;

namespace HerdrOps.App.Views;

public partial class LiveOrganizationView : UserControl
{
    private const double CompactHeightBreakpoint = 650;

    public LiveOrganizationView()
    {
        InitializeComponent();
    }

    private void OnViewSizeChanged(object sender, SizeChangedEventArgs e)
    {
        var compact = e.NewSize.Height < CompactHeightBreakpoint;
        OrganizationRoot.Margin = compact ? new Thickness(10) : new Thickness(16);
        SourceRow.Height = new GridLength(compact ? 20 : 28);
        SummaryRow.Height = new GridLength(compact ? 96 : 118);
        AttentionRow.Height = new GridLength(compact ? 88 : 108);
    }

    private void OnNodeSelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (DataContext is LiveOrganizationState state &&
            sender is ListBox { SelectedItem: OrganizationNode node })
        {
            state.SelectedNode = node;
        }
    }
}
