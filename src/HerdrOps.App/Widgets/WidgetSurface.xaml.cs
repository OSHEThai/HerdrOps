using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;

namespace HerdrOps.App.Widgets;

/// <summary>
/// Shared visual surface for every widget density. All variants consume one state model.
/// </summary>
public partial class WidgetSurface : UserControl
{
    public static readonly DependencyProperty VariantProperty = DependencyProperty.Register(
        nameof(Variant),
        typeof(WidgetVariant),
        typeof(WidgetSurface),
        new FrameworkPropertyMetadata(WidgetVariant.Compact, OnVariantChanged));

    public static readonly DependencyProperty IsInteractiveProperty = DependencyProperty.Register(
        nameof(IsInteractive),
        typeof(bool),
        typeof(WidgetSurface),
        new FrameworkPropertyMetadata(true));

    public WidgetSurface()
        : this(SyntheticWidgetState.Create())
    {
    }

    public WidgetSurface(SyntheticWidgetState state)
    {
        ArgumentNullException.ThrowIfNull(state);
        InitializeComponent();
        SetState(state);
        ApplyVariant(Variant);
    }

    public event EventHandler? CloseRequested;

    public event EventHandler? PinToggleRequested;

    public event EventHandler? ResetPositionRequested;

    public event MouseButtonEventHandler? DragRequested;

    public WidgetVariant Variant
    {
        get => (WidgetVariant)GetValue(VariantProperty);
        set => SetValue(VariantProperty, value);
    }

    public bool IsInteractive
    {
        get => (bool)GetValue(IsInteractiveProperty);
        set => SetValue(IsInteractiveProperty, value);
    }

    public void SetState(SyntheticWidgetState state)
    {
        ArgumentNullException.ThrowIfNull(state);
        SurfaceRoot.DataContext = state;
    }

    private static void OnVariantChanged(DependencyObject dependencyObject, DependencyPropertyChangedEventArgs e)
    {
        if (dependencyObject is WidgetSurface surface && e.NewValue is WidgetVariant variant)
        {
            surface.ApplyVariant(variant);
        }
    }

    private void ApplyVariant(WidgetVariant variant)
    {
        if (!IsInitialized)
        {
            return;
        }

        CompactPanel.Visibility = variant == WidgetVariant.Compact ? Visibility.Visible : Visibility.Collapsed;
        NormalPanel.Visibility = variant == WidgetVariant.Normal ? Visibility.Visible : Visibility.Collapsed;
        ExpandedPanel.Visibility = variant == WidgetVariant.Expanded ? Visibility.Visible : Visibility.Collapsed;
        FloatingMiniPanel.Visibility = variant == WidgetVariant.FloatingMini ? Visibility.Visible : Visibility.Collapsed;
        FloatingVerticalPanel.Visibility = variant == WidgetVariant.FloatingVertical ? Visibility.Visible : Visibility.Collapsed;
        NotificationPanel.Visibility = variant == WidgetVariant.Notification ? Visibility.Visible : Visibility.Collapsed;
        AgentDetailPanel.Visibility = variant == WidgetVariant.AgentDetailPopup ? Visibility.Visible : Visibility.Collapsed;
        HeaderSourceText.Text = variant == WidgetVariant.FloatingVertical
            ? "SYN"
            : "SYNTHETIC";
    }

    private void OnCloseClick(object sender, RoutedEventArgs e) =>
        CloseRequested?.Invoke(this, EventArgs.Empty);

    private void OnPinClick(object sender, RoutedEventArgs e) =>
        PinToggleRequested?.Invoke(this, EventArgs.Empty);

    private void OnResetPositionClick(object sender, RoutedEventArgs e) =>
        ResetPositionRequested?.Invoke(this, EventArgs.Empty);

    private void OnDragSurfaceMouseLeftButtonDown(object sender, MouseButtonEventArgs e) =>
        DragRequested?.Invoke(this, e);
}
