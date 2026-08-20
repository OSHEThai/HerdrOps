using System.Windows;
using System.Windows.Input;
using HerdrOps.App.Localization;

namespace HerdrOps.App.Widgets;

/// <summary>
/// Reversible, bounded host window for a single widget variant.
/// </summary>
public partial class WidgetWindow : Window
{
    private bool _isConstraining;
    private IWidgetState? _state;
    private bool _isClosed;
    private readonly IWidgetActionRouter _actionRouter;
    private bool _resourcesReleased;

    public WidgetWindow(
        WidgetVariantDescriptor descriptor,
        IWidgetState state,
        IWidgetActionRouter? actionRouter = null)
    {
        ArgumentNullException.ThrowIfNull(descriptor);
        ArgumentNullException.ThrowIfNull(state);

        Descriptor = descriptor;
        _state = state;
        _actionRouter = actionRouter ?? ApplicationWidgetActionRouter.Shared;
        MotionPolicy = WidgetMotionPolicy.Create(
            reducedMotionRequested: false,
            systemAnimationsEnabled: SystemParameters.ClientAreaAnimation);

        InitializeComponent();
        Width = descriptor.WindowWidth;
        Height = descriptor.WindowHeight;
        MinWidth = descriptor.WindowWidth;
        MinHeight = descriptor.WindowHeight;
        MaxWidth = descriptor.WindowWidth;
        MaxHeight = descriptor.WindowHeight;
        Topmost = descriptor.DefaultTopmost;
        ShowInTaskbar = descriptor.ShowInTaskbar;
        Title = $"HerdrOps {descriptor.DisplayName} — {state.WindowTitleSuffix}";

        Surface.SetState(state);
        Surface.Variant = descriptor.Variant;
        Surface.IsInteractive = true;
        Surface.CloseRequested += OnCloseRequested;
        Surface.PinToggleRequested += OnPinToggleRequested;
        Surface.ResetPositionRequested += OnResetPositionRequested;
        Surface.DragRequested += OnDragRequested;
        Surface.NotificationOpenRequested += OnNotificationOpenRequested;
        Surface.NotificationHistoryRequested += OnNotificationHistoryRequested;
        Surface.AgentDetailsRequested += OnAgentDetailsRequested;
        Surface.TaskAlignmentRequested += OnTaskAlignmentRequested;
        WeakEventManager<UiLanguageService, EventArgs>.AddHandler(
            UiLanguageService.Shared,
            nameof(UiLanguageService.LanguageChanged),
            OnLanguageChanged);
        Closed += OnClosed;

        ResetPosition();
    }

    public WidgetVariantDescriptor Descriptor { get; }

    public WidgetMotionPolicy MotionPolicy { get; }

    public bool ResourcesReleased => _resourcesReleased;

    public bool IsClosed => _isClosed;

    public bool IsDragEnabled => true;

    public void ToggleTopmost() => Topmost = !Topmost;

    public Point ConstrainTo(Rect workArea, Point requested)
    {
        var constrained = WidgetWindowBounds.Clamp(
            requested,
            new Size(Width, Height),
            workArea);

        _isConstraining = true;
        try
        {
            Left = constrained.X;
            Top = constrained.Y;
        }
        finally
        {
            _isConstraining = false;
        }

        return constrained;
    }

    public void ResetPosition()
    {
        var workArea = SystemParameters.WorkArea;
        var requested = new Point(
            workArea.Right - Width - 24,
            workArea.Bottom - Height - 24);
        ConstrainTo(workArea, requested);
    }

    private void OnDragRequested(object? sender, MouseButtonEventArgs e)
    {
        if (e.ChangedButton != MouseButton.Left || e.ButtonState != MouseButtonState.Pressed)
        {
            return;
        }

        try
        {
            DragMove();
        }
        catch (InvalidOperationException)
        {
            // A synthetic render can raise the event before a native window handle exists.
        }
    }

    private void OnCloseRequested(object? sender, EventArgs e) => Close();

    private void OnPinToggleRequested(object? sender, EventArgs e) => ToggleTopmost();

    private void OnResetPositionRequested(object? sender, EventArgs e) => ResetPosition();

    private void OnNotificationOpenRequested(object? sender, WidgetNotificationEventArgs e)
    {
        if (e.Notice.Route is { } route)
        {
            _actionRouter.OpenNotification(route);
        }
    }

    private void OnNotificationHistoryRequested(object? sender, EventArgs e) =>
        _actionRouter.OpenNotificationHistory();

    private void OnAgentDetailsRequested(object? sender, WidgetAgentEventArgs e) =>
        _actionRouter.OpenAgent(e.Agent.TerminalId);

    private void OnTaskAlignmentRequested(object? sender, WidgetTaskEventArgs e) =>
        _actionRouter.OpenTaskAlignment(e.TaskId);

    private void OnLanguageChanged(object? sender, EventArgs e)
    {
        if (!Dispatcher.CheckAccess())
        {
            if (!Dispatcher.HasShutdownStarted && !Dispatcher.HasShutdownFinished)
            {
                _ = Dispatcher.InvokeAsync(ApplyLanguageChange);
            }

            return;
        }

        ApplyLanguageChange();
    }

    private void ApplyLanguageChange()
    {
        if (_state is null)
        {
            return;
        }

        if (_state.EvidenceClass == HerdrOps.Contracts.EvidenceClass.Synthetic)
        {
            _state = SyntheticWidgetState.Create();
            Surface.SetState(_state);
        }

        Title = $"HerdrOps {Descriptor.DisplayName} — {_state.WindowTitleSuffix}";
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
        _isClosed = true;
        Surface.CloseRequested -= OnCloseRequested;
        Surface.PinToggleRequested -= OnPinToggleRequested;
        Surface.ResetPositionRequested -= OnResetPositionRequested;
        Surface.DragRequested -= OnDragRequested;
        Surface.NotificationOpenRequested -= OnNotificationOpenRequested;
        Surface.NotificationHistoryRequested -= OnNotificationHistoryRequested;
        Surface.AgentDetailsRequested -= OnAgentDetailsRequested;
        Surface.TaskAlignmentRequested -= OnTaskAlignmentRequested;
        WeakEventManager<UiLanguageService, EventArgs>.RemoveHandler(
            UiLanguageService.Shared,
            nameof(UiLanguageService.LanguageChanged),
            OnLanguageChanged);
        LocationChanged -= OnLocationChanged;
        PreviewKeyDown -= OnPreviewKeyDown;
        Surface.ReleaseResources();
        Content = null;
        _state = null;
        Closed -= OnClosed;
    }

    private void OnLocationChanged(object? sender, EventArgs e)
    {
        if (!_isConstraining &&
            !double.IsNaN(Left) &&
            !double.IsNaN(Top))
        {
            ConstrainTo(SystemParameters.WorkArea, new Point(Left, Top));
        }
    }

    private void OnPreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Escape)
        {
            Close();
            e.Handled = true;
            return;
        }

        if (Keyboard.Modifiers == ModifierKeys.Control && e.Key == Key.T)
        {
            ToggleTopmost();
            e.Handled = true;
            return;
        }

        if (Keyboard.Modifiers == ModifierKeys.Control &&
            (e.Key == Key.D0 || e.Key == Key.NumPad0))
        {
            ResetPosition();
            e.Handled = true;
        }
    }
}
