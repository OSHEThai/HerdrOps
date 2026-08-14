using System.Windows;

namespace HerdrOps.App.Widgets;

/// <summary>
/// Keeps draggable widgets recoverable inside the selected Windows work area.
/// </summary>
public static class WidgetWindowBounds
{
    public static Point Clamp(Point requested, Size windowSize, Rect workArea)
    {
        ArgumentOutOfRangeException.ThrowIfLessThanOrEqual(windowSize.Width, 0);
        ArgumentOutOfRangeException.ThrowIfLessThanOrEqual(windowSize.Height, 0);

        var maxLeft = Math.Max(workArea.Left, workArea.Right - windowSize.Width);
        var maxTop = Math.Max(workArea.Top, workArea.Bottom - windowSize.Height);

        return new Point(
            Math.Clamp(requested.X, workArea.Left, maxLeft),
            Math.Clamp(requested.Y, workArea.Top, maxTop));
    }
}
