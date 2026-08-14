namespace HerdrOps.App.Widgets;

public interface IWidgetWindowLauncher
{
    void Open(WidgetVariant variant);
}

/// <summary>
/// Opens real widget windows while preserving the shared synthetic state snapshot.
/// </summary>
public sealed class WidgetWindowLauncher : IWidgetWindowLauncher
{
    private readonly SyntheticWidgetState _state;

    public WidgetWindowLauncher(SyntheticWidgetState state)
    {
        ArgumentNullException.ThrowIfNull(state);
        _state = state;
    }

    public void Open(WidgetVariant variant)
    {
        var window = new WidgetWindow(WidgetCatalog.Get(variant), _state);
        window.Show();
    }
}
