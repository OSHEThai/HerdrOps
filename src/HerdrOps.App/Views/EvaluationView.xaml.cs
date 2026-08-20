using System.Windows.Controls;
using HerdrOps.App.Evaluation;

namespace HerdrOps.App.Views;

public partial class EvaluationView : UserControl
{
    public EvaluationView()
        : this(EvaluationState.CreateSyntheticPreview())
    {
    }

    public EvaluationView(EvaluationState state)
    {
        ArgumentNullException.ThrowIfNull(state);
        InitializeComponent();
        DataContext = state;
    }
}
