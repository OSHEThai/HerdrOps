namespace HerdrOps.App.Widgets;

public interface IWidgetWindowLauncher
{
    void Open(WidgetVariant variant);
}

/// <summary>
/// Opens real widget windows while preserving one shared state object.
/// </summary>
public sealed class WidgetWindowLauncher : IWidgetWindowLauncher
{
    private readonly IWidgetState _state;

    public WidgetWindowLauncher(IWidgetState state)
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
