using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using HerdrOps.App.Delegation;

namespace HerdrOps.App.Views;

public partial class DelegationGraphView : UserControl
{
    private const double CompactHeightBreakpoint = 700;
    private const double CompactWidthBreakpoint = 1160;
    private const double MinimumScale = 0.56;
    private const double MaximumScale = 1.8;
    private bool _isPanning;
    private bool _hasInitialFit;
    private Point _panStart;
    private double _translateStartX;
    private double _translateStartY;

    public DelegationGraphView()
    {
        InitializeComponent();
    }

    public double CurrentScale => GraphScale.ScaleX;

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        if (!_hasInitialFit)
        {
            FitGraph();
            _hasInitialFit = true;
        }
    }

    private void OnViewSizeChanged(object sender, SizeChangedEventArgs e)
    {
        var compactHeight = e.NewSize.Height < CompactHeightBreakpoint;
        var compactWidth = e.NewSize.Width < CompactWidthBreakpoint;
        DelegationRoot.Margin = compactHeight ? new Thickness(10) : new Thickness(14);
        SourceRow.Height = new GridLength(compactHeight ? 22 : 26);
        SummaryRow.Height = new GridLength(compactHeight ? 92 : 104);
        TimelineRow.Height = new GridLength(compactHeight ? 148 : 176);
        TaskTreeColumn.Width = new GridLength(compactWidth ? 205 : 238);
        DetailColumn.Width = new GridLength(compactWidth ? 260 : 300);
    }

    private void OnGraphNodeSelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (DataContext is DelegationGraphState state &&
            sender is ListBox { SelectedItem: DelegationGraphNodeItem node })
        {
            state.SelectedNode = node;
        }
    }

    private void OnAccessibleNodeSelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (DataContext is DelegationGraphState state &&
            sender is ListBox { SelectedItem: DelegationAccessibleItem item })
        {
            state.SelectedAccessibleItem = item;
        }
    }

    private void OnAccessibleViewClick(object sender, RoutedEventArgs e)
    {
        if (DataContext is not DelegationGraphState state)
        {
            return;
        }

        state.IsAccessibleView = !state.IsAccessibleView;
        _ = Dispatcher.InvokeAsync(() =>
        {
            if (state.IsAccessibleView)
            {
                AccessibleNodeList.Focus();
                AccessibleNodeList.ScrollIntoView(state.SelectedAccessibleItem);
            }
            else
            {
                GraphNodeList.Focus();
                GraphNodeList.ScrollIntoView(state.SelectedNode);
            }
        });
    }

    private void OnFitClick(object sender, RoutedEventArgs e) => FitGraph();

    private void OnZoomOutClick(object sender, RoutedEventArgs e) =>
        ZoomAt(0.88, new Point(GraphViewport.ActualWidth / 2d, GraphViewport.ActualHeight / 2d));

    private void OnZoomInClick(object sender, RoutedEventArgs e) =>
        ZoomAt(1.12, new Point(GraphViewport.ActualWidth / 2d, GraphViewport.ActualHeight / 2d));

    private void OnGraphMouseWheel(object sender, MouseWheelEventArgs e)
    {
        ZoomAt(e.Delta > 0 ? 1.1 : 0.9, e.GetPosition(GraphViewport));
        e.Handled = true;
    }

    private void OnGraphMouseDown(object sender, MouseButtonEventArgs e)
    {
        if (FindAncestor<ListBoxItem>(e.OriginalSource as DependencyObject) is not null)
        {
            return;
        }

        _isPanning = true;
        _panStart = e.GetPosition(GraphViewport);
        _translateStartX = GraphTranslate.X;
        _translateStartY = GraphTranslate.Y;
        GraphViewport.CaptureMouse();
        GraphViewport.Cursor = Cursors.Hand;
        e.Handled = true;
    }

    private void OnGraphMouseMove(object sender, MouseEventArgs e)
    {
        if (!_isPanning || e.LeftButton != MouseButtonState.Pressed)
        {
            return;
        }

        var current = e.GetPosition(GraphViewport);
        GraphTranslate.X = _translateStartX + current.X - _panStart.X;
        GraphTranslate.Y = _translateStartY + current.Y - _panStart.Y;
        e.Handled = true;
    }

    private void OnGraphMouseUp(object sender, MouseButtonEventArgs e) => StopPanning();

    private void OnGraphLostMouseCapture(object sender, MouseEventArgs e) => StopPanning();

    private void StopPanning()
    {
        if (!_isPanning)
        {
            return;
        }

        _isPanning = false;
        GraphViewport.ReleaseMouseCapture();
        GraphViewport.Cursor = Cursors.SizeAll;
    }

    private void FitGraph()
    {
        if (GraphViewport.ActualWidth <= 0 || GraphViewport.ActualHeight <= 0)
        {
            return;
        }

        const double margin = 24;
        var availableWidth = Math.Max(GraphViewport.ActualWidth - (margin * 2d), 1d);
        var availableHeight = Math.Max(GraphViewport.ActualHeight - (margin * 2d), 1d);
        var scale = Math.Clamp(
            Math.Min(
                availableWidth / DelegationGraphState.GraphWidth,
                availableHeight / DelegationGraphState.GraphHeight),
            MinimumScale,
            1d);
        GraphScale.ScaleX = scale;
        GraphScale.ScaleY = scale;
        GraphTranslate.X = (GraphViewport.ActualWidth - (DelegationGraphState.GraphWidth * scale)) / 2d;
        GraphTranslate.Y = (GraphViewport.ActualHeight - (DelegationGraphState.GraphHeight * scale)) / 2d;
        UpdateZoomLabel();
    }

    private void ZoomAt(double factor, Point viewportPoint)
    {
        var oldScale = GraphScale.ScaleX;
        var newScale = Math.Clamp(oldScale * factor, MinimumScale, MaximumScale);
        if (Math.Abs(newScale - oldScale) < 0.0001)
        {
            return;
        }

        var graphX = (viewportPoint.X - GraphTranslate.X) / oldScale;
        var graphY = (viewportPoint.Y - GraphTranslate.Y) / oldScale;
        GraphScale.ScaleX = newScale;
        GraphScale.ScaleY = newScale;
        GraphTranslate.X = viewportPoint.X - (graphX * newScale);
        GraphTranslate.Y = viewportPoint.Y - (graphY * newScale);
        UpdateZoomLabel();
    }

    private void UpdateZoomLabel() =>
        ZoomLabel.Text = $"{Math.Round(GraphScale.ScaleX * 100d):0}%";

    private static T? FindAncestor<T>(DependencyObject? current)
        where T : DependencyObject
    {
        while (current is not null)
        {
            if (current is T match)
            {
                return match;
            }

            current = VisualTreeHelper.GetParent(current);
        }

        return null;
    }
}
