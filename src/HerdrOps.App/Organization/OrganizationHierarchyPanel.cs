using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace HerdrOps.App.Organization;

/// <summary>
/// Arranges the flat organization node source as a bounded, keyboard-friendly
/// tree of cards. The ListBox still owns selection and keyboard navigation; this
/// panel only changes the visual geometry and draws reporting connectors.
/// </summary>
public sealed class OrganizationHierarchyPanel : Panel
{
    private const double CompactWidthBreakpoint = 700;
    private const double ReferenceMinimumCardWidth = 132;

    private readonly Dictionary<string, Rect> _arrangedNodes = new(StringComparer.Ordinal);
    private double _contentHeight;

    protected override Size MeasureOverride(Size availableSize)
    {
        var width = ResolveWidth(availableSize.Width);
        var metrics = ResolveMetrics(width);
        var branchMeasureWidth = Math.Max(
            metrics.MinimumCardWidth,
            (width - (metrics.OuterPadding * 2) - (metrics.ColumnGap * 3)) / 4);
        foreach (UIElement child in InternalChildren)
        {
            child.Measure(new Size(branchMeasureWidth, metrics.CardHeight));
        }

        var layout = CalculateLayout(width, metrics, arrange: false);
        _contentHeight = layout.Height;
        return new Size(width, layout.Height);
    }

    protected override Size ArrangeOverride(Size finalSize)
    {
        var width = ResolveWidth(finalSize.Width);
        if (DesiredSize.Width > 0 && !double.IsInfinity(DesiredSize.Width))
        {
            width = Math.Min(width, DesiredSize.Width);
        }
        var metrics = ResolveMetrics(width);
        _arrangedNodes.Clear();
        var layout = CalculateLayout(width, metrics, arrange: true);
        _contentHeight = layout.Height;

        foreach (UIElement child in InternalChildren)
        {
            if (child is FrameworkElement frameworkElement &&
                frameworkElement.DataContext is OrganizationNode node &&
                _arrangedNodes.TryGetValue(node.NodeId, out var bounds))
            {
                child.Arrange(bounds);
            }
            else
            {
                child.Arrange(new Rect(0, 0, 0, 0));
            }
        }

        InvalidateVisual();
        return new Size(width, Math.Max(finalSize.Height, _contentHeight));
    }

    protected override void OnRender(DrawingContext drawingContext)
    {
        base.OnRender(drawingContext);

        var connectorBrush = TryFindResource("HerdrOps.Brush.Border") as Brush ??
                             new SolidColorBrush(Color.FromRgb(34, 102, 145));
        var connectorPen = new Pen(connectorBrush, 1.2)
        {
            StartLineCap = PenLineCap.Round,
            EndLineCap = PenLineCap.Round,
            LineJoin = PenLineJoin.Round,
        };

        foreach (var child in InternalChildren)
        {
            if (child is not FrameworkElement { DataContext: OrganizationNode node } ||
                node.ParentNodeId is not { } parentNodeId ||
                !_arrangedNodes.TryGetValue(node.NodeId, out var childBounds) ||
                !_arrangedNodes.TryGetValue(parentNodeId, out var parentBounds))
            {
                continue;
            }

            var parentPoint = new Point(parentBounds.Left + parentBounds.Width / 2, parentBounds.Bottom);
            var childPoint = new Point(childBounds.Left + childBounds.Width / 2, childBounds.Top);
            if (Math.Abs(parentPoint.X - childPoint.X) < 1)
            {
                drawingContext.DrawLine(connectorPen, parentPoint, childPoint);
                continue;
            }

            var midpoint = parentPoint.Y + Math.Max(5, (childPoint.Y - parentPoint.Y) / 2);
            drawingContext.DrawLine(connectorPen, parentPoint, new Point(parentPoint.X, midpoint));
            drawingContext.DrawLine(connectorPen, new Point(parentPoint.X, midpoint), new Point(childPoint.X, midpoint));
            drawingContext.DrawLine(connectorPen, new Point(childPoint.X, midpoint), childPoint);
        }
    }

    private LayoutResult CalculateLayout(double width, LayoutMetrics metrics, bool arrange)
    {
        var entries = InternalChildren
            .OfType<FrameworkElement>()
            .Select(element => (Element: element, Node: element.DataContext as OrganizationNode))
            .Where(entry => entry.Node is not null)
            .Select(entry => (entry.Element, Node: entry.Node!))
            .ToArray();

        if (entries.Length == 0)
        {
            return new LayoutResult(0);
        }

        var byId = entries.ToDictionary(entry => entry.Node.NodeId, StringComparer.Ordinal);
        var childrenByParent = entries
            .Where(entry => entry.Node.ParentNodeId is not null && byId.ContainsKey(entry.Node.ParentNodeId))
            .GroupBy(entry => entry.Node.ParentNodeId!, StringComparer.Ordinal)
            .ToDictionary(
                group => group.Key,
                group => group.OrderBy(entry => entry.Node.LayoutRow).ToArray(),
                StringComparer.Ordinal);
        var roots = entries
            .Where(entry => entry.Node.ParentNodeId is null || !byId.ContainsKey(entry.Node.ParentNodeId))
            .OrderBy(entry => entry.Node.LayoutRow)
            .ToArray();

        var left = metrics.OuterPadding;
        var usableWidth = Math.Max(metrics.MinimumCardWidth, width - (metrics.OuterPadding * 2));
        var y = metrics.OuterPadding;

        if (roots.Length == 1)
        {
            var root = roots[0];
            var rootWidth = FitCardWidth(usableWidth, metrics.RootWidth, metrics.MinimumCardWidth);
            Place(root, CenteredX(usableWidth, rootWidth), y, rootWidth, arrange);
            y += metrics.CardHeight + metrics.BranchGap;

            var directChildren = ChildrenOf(root.Node.NodeId, childrenByParent);
            var assistant = directChildren.FirstOrDefault(entry =>
                string.Equals(entry.Node.LayoutHint, "assistant", StringComparison.OrdinalIgnoreCase));
            if (assistant.Element is not null)
            {
                var assistantWidth = FitCardWidth(usableWidth, metrics.RootWidth, metrics.MinimumCardWidth);
                Place(assistant, CenteredX(usableWidth, assistantWidth), y, assistantWidth, arrange);
                y += metrics.CardHeight + metrics.BranchGap;
                directChildren = directChildren
                    .Where(entry => !string.Equals(entry.Node.NodeId, assistant.Node.NodeId, StringComparison.Ordinal))
                    .ToArray();
            }

            if (directChildren.Count > 0)
            {
                y += ArrangeColumns(directChildren, childrenByParent, left, usableWidth, y, metrics, arrange);
            }

            return new LayoutResult(Math.Max(y + metrics.OuterPadding, metrics.CardHeight + (metrics.OuterPadding * 2)));
        }

        if (roots.Length > 0)
        {
            y += ArrangeColumns(roots, childrenByParent, left, usableWidth, y, metrics, arrange);
        }

        return new LayoutResult(Math.Max(y + metrics.OuterPadding, metrics.CardHeight + (metrics.OuterPadding * 2)));

        void Place(
            (FrameworkElement Element, OrganizationNode Node) entry,
            double x,
            double top,
            double cardWidth,
            bool shouldArrange)
        {
            if (!shouldArrange)
            {
                return;
            }

            var bounds = new Rect(x, top, cardWidth, metrics.CardHeight);
            _arrangedNodes[entry.Node.NodeId] = bounds;
        }

        double ArrangeColumns(
            IReadOnlyList<(FrameworkElement Element, OrganizationNode Node)> branches,
            IReadOnlyDictionary<string, (FrameworkElement Element, OrganizationNode Node)[]> childMap,
            double originX,
            double availableWidth,
            double originY,
            LayoutMetrics layoutMetrics,
            bool shouldArrange)
        {
            var gapTotal = layoutMetrics.ColumnGap * Math.Max(0, branches.Count - 1);
            var cardWidth = Math.Min(
                layoutMetrics.MaximumCardWidth,
                Math.Max(layoutMetrics.MinimumCardWidth, (availableWidth - gapTotal) / Math.Max(1, branches.Count)));
            var actualWidth = (cardWidth * branches.Count) + gapTotal;
            var startX = originX + Math.Max(0, (availableWidth - actualWidth) / 2);
            var maxHeight = 0d;

            for (var index = 0; index < branches.Count; index++)
            {
                var branchX = startX + (index * (cardWidth + layoutMetrics.ColumnGap));
                var branchHeight = SubtreeHeight(branches[index].Node.NodeId, childMap);
                maxHeight = Math.Max(maxHeight, branchHeight);
                ArrangeSubtree(branches[index], branchX, originY, cardWidth, childMap, layoutMetrics, shouldArrange);
            }

            return maxHeight;
        }

        double ArrangeSubtree(
            (FrameworkElement Element, OrganizationNode Node) entry,
            double x,
            double top,
            double cardWidth,
            IReadOnlyDictionary<string, (FrameworkElement Element, OrganizationNode Node)[]> childMap,
            LayoutMetrics layoutMetrics,
            bool shouldArrange)
        {
            Place(entry, x, top, cardWidth, shouldArrange);
            var nextTop = top + layoutMetrics.CardHeight;
            foreach (var child in ChildrenOf(entry.Node.NodeId, childMap))
            {
                nextTop += layoutMetrics.CardGap;
                nextTop += ArrangeSubtree(child, x, nextTop, cardWidth, childMap, layoutMetrics, shouldArrange);
            }

            return nextTop - top;
        }

        double SubtreeHeight(
            string nodeId,
            IReadOnlyDictionary<string, (FrameworkElement Element, OrganizationNode Node)[]> childMap)
        {
            var height = metrics.CardHeight;
            foreach (var child in ChildrenOf(nodeId, childMap))
            {
                height += metrics.CardGap + SubtreeHeight(child.Node.NodeId, childMap);
            }

            return height;
        }

        static IReadOnlyList<(FrameworkElement Element, OrganizationNode Node)> ChildrenOf(
            string nodeId,
            IReadOnlyDictionary<string, (FrameworkElement Element, OrganizationNode Node)[]> childMap) =>
            childMap.TryGetValue(nodeId, out var children) ? children : [];

        double CenteredX(double available, double cardWidth) => metrics.OuterPadding + Math.Max(0, (available - cardWidth) / 2);

        static double FitCardWidth(double available, double preferred, double minimum) =>
            Math.Min(preferred, Math.Max(minimum, available));
    }

    private double ResolveWidth(double width)
    {
        var resolved = double.IsInfinity(width) || double.IsNaN(width) || width <= 0
            ? 760
            : Math.Max(ReferenceMinimumCardWidth + (ResolveMetrics(width).OuterPadding * 2), width);
        return !double.IsNaN(Width) && !double.IsInfinity(Width) && Width > 0
            ? Math.Min(resolved, Width)
            : resolved;
    }

    private sealed record LayoutResult(double Height);

    private static LayoutMetrics ResolveMetrics(double width) =>
        width < CompactWidthBreakpoint
            ? new(
                CardHeight: 38,
                CardGap: 1,
                ColumnGap: 8,
                OuterPadding: 2,
                RootWidth: 236,
                MinimumCardWidth: 132,
                MaximumCardWidth: 210,
                BranchGap: 3)
            : new(
                CardHeight: 52,
                CardGap: 5,
                ColumnGap: 12,
                OuterPadding: 10,
                RootWidth: 276,
                MinimumCardWidth: ReferenceMinimumCardWidth,
                MaximumCardWidth: 230,
                BranchGap: 12);

    private sealed record LayoutMetrics(
        double CardHeight,
        double CardGap,
        double ColumnGap,
        double OuterPadding,
        double RootWidth,
        double MinimumCardWidth,
        double MaximumCardWidth,
        double BranchGap);
}
