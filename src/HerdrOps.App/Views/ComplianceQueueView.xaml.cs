using System.Windows;
using System.Windows.Controls;
using HerdrOps.App.Compliance;

namespace HerdrOps.App.Views;

public partial class ComplianceQueueView : UserControl
{
    public ComplianceQueueView()
        : this(ComplianceQueueState.CreateSyntheticPreview())
    {
    }

    public ComplianceQueueView(ComplianceQueueState state)
    {
        ArgumentNullException.ThrowIfNull(state);
        InitializeComponent();
        DataContext = state;
    }

    private async void OnReviewActionClick(object sender, RoutedEventArgs e)
    {
        if (sender is Button { DataContext: ComplianceQueueReviewAction action } &&
            DataContext is ComplianceQueueState state)
        {
            await state.ExecuteReviewActionAsync(action);
        }
    }

}
