using System.Windows;
using HerdrOps.App.Localization;
using HerdrOps.Domain.Settings;

namespace HerdrOps.App.Widgets;

public partial class WidgetGalleryWindow : Window
{
    private const double NativeGalleryContentWidth = 1536;
    private bool _hasAdjustedInitialWidth;

    public WidgetGalleryWindow()
        : this(SyntheticWidgetState.Create(), null, null, null)
    {
    }

    public WidgetGalleryWindow(IWidgetState state)
        : this(state, null, null, null)
    {
    }

    public WidgetGalleryWindow(
        IWidgetState state,
        IWidgetWindowLauncher? launcher,
        Action<AppSettingsWidgetVariant>? widgetSelected,
        Action<bool>? widgetEnabled)
    {
        ArgumentNullException.ThrowIfNull(state);
        InitializeComponent();
        GalleryView = new WidgetGalleryView(
            state,
            launcher,
            widgetSelected,
            widgetEnabled);
        GalleryHost.Content = GalleryView;
        RefreshTitle();
        WeakEventManager<UiLanguageService, EventArgs>.AddHandler(
            UiLanguageService.Shared,
            nameof(UiLanguageService.LanguageChanged),
            OnLanguageChanged);
        Closed += OnClosed;
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

    private void OnLanguageChanged(object? sender, EventArgs e)
    {
        if (!Dispatcher.CheckAccess())
        {
            if (!Dispatcher.HasShutdownStarted && !Dispatcher.HasShutdownFinished)
            {
                _ = Dispatcher.InvokeAsync(RefreshTitle);
            }

            return;
        }

        RefreshTitle();
    }

    private void RefreshTitle()
    {
        var text = UiLanguageService.Shared;
        Title = $"{text["WidgetGalleryTitle"]} — {GalleryView.SharedState.WindowTitleSuffix}";
    }

    private void OnClosed(object? sender, EventArgs e)
    {
        WeakEventManager<UiLanguageService, EventArgs>.RemoveHandler(
            UiLanguageService.Shared,
            nameof(UiLanguageService.LanguageChanged),
            OnLanguageChanged);
        Closed -= OnClosed;
    }
}
