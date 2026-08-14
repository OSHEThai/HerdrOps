using System.Windows;

namespace HerdrOps.App.Widgets;

public partial class WidgetGalleryWindow : Window
{
    private const double NativeGalleryContentWidth = 1536;
    private bool _hasAdjustedInitialWidth;

    public WidgetGalleryWindow()
        : this(SyntheticWidgetState.Create())
    {
    }

    public WidgetGalleryWindow(IWidgetState state)
    {
        ArgumentNullException.ThrowIfNull(state);
        InitializeComponent();
        GalleryView = new WidgetGalleryView(state, launcher: null);
        GalleryHost.Content = GalleryView;
        Title = $"HerdrOps Widget Gallery — {state.WindowTitleSuffix}";
    }

    public WidgetGalleryView GalleryView { get; }

    protected override void OnContentRendered(EventArgs e)
    {
        base.OnContentRendered(e);

        if (_hasAdjustedInitialWidth || GalleryView.ActualWidth >= NativeGalleryContentWidth)
        {
            return;
        }

        _hasAdjustedInitialWidth = true;
        var nonClientWidth = Math.Max(0, ActualWidth - GalleryView.ActualWidth);
        var nativeOuterWidth = NativeGalleryContentWidth + nonClientWidth;

        if (nativeOuterWidth <= SystemParameters.WorkArea.Width)
        {
            Width = nativeOuterWidth;
        }
    }
}
