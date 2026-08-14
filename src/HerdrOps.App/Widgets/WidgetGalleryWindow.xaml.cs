using System.Windows;
using HerdrOps.App.Localization;

namespace HerdrOps.App.Widgets;

public partial class WidgetGalleryWindow : Window
{
    private const double NativeGalleryContentWidth = 1536;
    private bool _hasAdjustedInitialWidth;

    public WidgetGalleryWindow()
    {
        InitializeComponent();
        RefreshTitle();
        UiLanguageService.Shared.LanguageChanged += OnLanguageChanged;
        Closed += OnClosed;
    }

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

    private void OnLanguageChanged(object? sender, EventArgs e) => RefreshTitle();

    private void RefreshTitle()
    {
        var text = UiLanguageService.Shared;
        Title = $"{text["WidgetGalleryTitle"]} — {GalleryView.SharedState.WindowTitleSuffix}";
    }

    private void OnClosed(object? sender, EventArgs e)
    {
        UiLanguageService.Shared.LanguageChanged -= OnLanguageChanged;
        Closed -= OnClosed;
    }
}
