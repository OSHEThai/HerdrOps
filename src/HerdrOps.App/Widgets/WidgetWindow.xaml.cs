using System.Windows;
using System.Windows.Input;

namespace HerdrOps.App.Widgets;

/// <summary>
/// Reversible, bounded host window for a single widget variant.
/// </summary>
public partial class WidgetWindow : Window
{
    private bool _isConstraining;

    public WidgetWindow(WidgetVariantDescriptor descriptor, SyntheticWidgetState state)
    {
        ArgumentNullException.ThrowIfNull(descriptor);
        ArgumentNullException.ThrowIfNull(state);

        Descriptor = descriptor;
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
        Title = $"HerdrOps {descriptor.DisplayName} — Synthetic Preview";

        Surface.SetState(state);
        Surface.Variant = descriptor.Variant;
        Surface.IsInteractive = true;
        Surface.CloseRequested += OnCloseRequested;
        Surface.PinToggleRequested += OnPinToggleRequested;
        Surface.ResetPositionRequested += OnResetPositionRequested;
        Surface.DragRequested += OnDragRequested;

        ResetPosition();
    }

    public WidgetVariantDescriptor Descriptor { get; }

    public WidgetMotionPolicy MotionPolicy { get; }

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
