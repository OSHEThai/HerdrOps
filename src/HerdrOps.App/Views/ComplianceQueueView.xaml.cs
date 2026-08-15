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
}
