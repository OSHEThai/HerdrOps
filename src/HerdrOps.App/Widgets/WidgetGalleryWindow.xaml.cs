using System.Windows;
using HerdrOps.App.Localization;

namespace HerdrOps.App.Widgets;

public partial class WidgetGalleryWindow : Window
{
    private const double NativeGalleryContentWidth = 1536;
    private bool _hasAdjustedInitialWidth;
    private bool _resourcesReleased;
    private int _resourceGeneration;

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
        RefreshTitle(_resourceGeneration);
        WeakEventManager<UiLanguageService, EventArgs>.AddHandler(
            UiLanguageService.Shared,
            nameof(UiLanguageService.LanguageChanged),
            OnLanguageChanged);
        Closed += OnClosed;
    }

    public WidgetGalleryView GalleryView { get; }

    public bool ResourcesReleased => _resourcesReleased;

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
        if (_resourcesReleased)
        {
            return;
        }

        var generation = _resourceGeneration;
        if (!Dispatcher.CheckAccess())
        {
            if (!Dispatcher.HasShutdownStarted && !Dispatcher.HasShutdownFinished)
            {
                _ = Dispatcher.InvokeAsync(() => RefreshTitle(generation));
            }

            return;
        }

        RefreshTitle(generation);
    }

    private void RefreshTitle(int generation)
    {
        if (_resourcesReleased || generation != _resourceGeneration || GalleryView.ResourcesReleased)
        {
            return;
        }

        var text = UiLanguageService.Shared;
        Title = $"{text["WidgetGalleryTitle"]} — {GalleryView.SharedState.WindowTitleSuffix}";
    }

    private void OnClosed(object? sender, EventArgs e)
    {
        ReleaseResources();
    }

    internal void ReleaseResources()
    {
        if (_resourcesReleased)
        {
            return;
        }

        _resourcesReleased = true;
        _resourceGeneration++;
        WeakEventManager<UiLanguageService, EventArgs>.RemoveHandler(
            UiLanguageService.Shared,
            nameof(UiLanguageService.LanguageChanged),
            OnLanguageChanged);
        Closed -= OnClosed;
        GalleryView.ReleaseResources();
        GalleryHost.Content = null;
    }
}
