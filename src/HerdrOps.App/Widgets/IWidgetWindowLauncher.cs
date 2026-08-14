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
    private readonly IWidgetActionRouter _actionRouter;

    public WidgetWindowLauncher(IWidgetState state, IWidgetActionRouter? actionRouter = null)
    {
        ArgumentNullException.ThrowIfNull(state);
        _state = state;
        _actionRouter = actionRouter ?? ApplicationWidgetActionRouter.Shared;
    }

    public void Open(WidgetVariant variant)
    {
        var window = new WidgetWindow(WidgetCatalog.Get(variant), _state, _actionRouter);
        window.Show();
    }
}
