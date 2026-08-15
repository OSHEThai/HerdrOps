using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
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

    public static readonly DependencyProperty StateProperty = DependencyProperty.Register(
        nameof(State),
        typeof(IWidgetState),
        typeof(WidgetSurface),
        new FrameworkPropertyMetadata(null, OnStateChanged));

    public WidgetSurface()
        : this(SyntheticWidgetState.Create())
    {
    }

    public WidgetSurface(IWidgetState state)
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

    public event EventHandler<WidgetNotificationEventArgs>? NotificationOpenRequested;

    public event EventHandler<WidgetNotificationEventArgs>? NotificationAcknowledged;

    public event EventHandler? NotificationHistoryRequested;

    public event EventHandler<WidgetAgentEventArgs>? AgentDetailsRequested;

    public event EventHandler<WidgetTaskEventArgs>? TaskAlignmentRequested;

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

    public IWidgetState? State
    {
        get => (IWidgetState?)GetValue(StateProperty);
        set => SetValue(StateProperty, value);
    }

    public void SetState(IWidgetState state)
    {
        ArgumentNullException.ThrowIfNull(state);
        State = state;
    }

    private static void OnStateChanged(DependencyObject dependencyObject, DependencyPropertyChangedEventArgs e)
    {
        if (dependencyObject is WidgetSurface surface && e.NewValue is IWidgetState state)
        {
            surface.SurfaceRoot.DataContext = state;
        }
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
        var isNarrowVertical = variant == WidgetVariant.FloatingVertical;
        HeaderSourceText.SetBinding(
            TextBlock.TextProperty,
            new Binding(isNarrowVertical
                ? nameof(IWidgetState.CompactSourceLabel)
                : nameof(IWidgetState.SourceLabel)));
        FooterConnectionText.SetBinding(
            TextBlock.TextProperty,
            new Binding(isNarrowVertical
                ? nameof(IWidgetState.CompactConnectionLabel)
                : nameof(IWidgetState.ConnectionLabel)));
        HeaderWordmark.FontSize = isNarrowVertical ? 11 : 14;
        HeaderStatusDot.Margin = isNarrowVertical
            ? new Thickness(4, 0, 3, 0)
            : new Thickness(9, 0, 5, 0);
        HeaderSourceText.FontSize = isNarrowVertical ? 7 : 9;
        HeaderSourceText.Foreground = (System.Windows.Media.Brush)FindResource(
            isNarrowVertical
                ? "HerdrOps.Brush.PrimaryText"
                : "HerdrOps.Brush.TextMuted");
        PinButton.Width = isNarrowVertical ? 24 : 30;
        PinButton.Height = isNarrowVertical ? 24 : 30;
        CloseButton.Width = isNarrowVertical ? 24 : 30;
        CloseButton.Height = isNarrowVertical ? 24 : 30;
    }

    private void OnCloseClick(object sender, RoutedEventArgs e) =>
        CloseRequested?.Invoke(this, EventArgs.Empty);

    private void OnPinClick(object sender, RoutedEventArgs e) =>
        PinToggleRequested?.Invoke(this, EventArgs.Empty);

    private void OnResetPositionClick(object sender, RoutedEventArgs e) =>
        ResetPositionRequested?.Invoke(this, EventArgs.Empty);

    private void OnNotificationOpenClick(object sender, RoutedEventArgs e)
    {
        if (sender is Button { CommandParameter: WidgetNotice { CanOpen: true } notice })
        {
            NotificationOpenRequested?.Invoke(this, new WidgetNotificationEventArgs(notice));
        }
    }

    private void OnNotificationAcknowledgeClick(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { CommandParameter: WidgetNotice notice } ||
            State is not IInteractiveWidgetState interactiveState ||
            !notice.CanAcknowledge ||
            !interactiveState.AcknowledgeNotificationGroup(notice.GroupId, DateTimeOffset.UtcNow))
        {
            return;
        }

        NotificationAcknowledged?.Invoke(this, new WidgetNotificationEventArgs(notice));
    }

    private void OnViewAllNotificationsClick(object sender, RoutedEventArgs e) =>
        NotificationHistoryRequested?.Invoke(this, EventArgs.Empty);

    private void OnViewSelectedAgentClick(object sender, RoutedEventArgs e)
    {
        if (State?.SelectedAgent is { TerminalId.Length: > 0 } agent)
        {
            AgentDetailsRequested?.Invoke(this, new WidgetAgentEventArgs(agent));
        }
    }

    private void OnAgentDetailsClick(object sender, RoutedEventArgs e)
    {
        if (sender is Button { CommandParameter: WidgetAgent agent })
        {
            AgentDetailsRequested?.Invoke(this, new WidgetAgentEventArgs(agent));
        }
    }

    private void OnTaskAlignmentClick(object sender, RoutedEventArgs e)
    {
        if (sender is Button
            {
                CommandParameter: WidgetAgent { CanOpenTaskAlignment: true } agent,
            })
        {
            TaskAlignmentRequested?.Invoke(this, new WidgetTaskEventArgs(agent));
        }
    }

    private void OnDragSurfaceMouseLeftButtonDown(object sender, MouseButtonEventArgs e) =>
        DragRequested?.Invoke(this, e);
}
