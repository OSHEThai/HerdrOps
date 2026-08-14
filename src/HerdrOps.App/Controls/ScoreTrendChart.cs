using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using HerdrOps.App.Overview;

namespace HerdrOps.App.Controls;

/// <summary>
/// Lightweight score chart that keeps axes, values, and dates legible in dense cards.
/// </summary>
public sealed class ScoreTrendChart : Control
{
    public static readonly DependencyProperty ItemsSourceProperty = DependencyProperty.Register(
        nameof(ItemsSource),
        typeof(IEnumerable<OverviewScorePoint>),
        typeof(ScoreTrendChart),
        new FrameworkPropertyMetadata(null, FrameworkPropertyMetadataOptions.AffectsRender));

    public static readonly DependencyProperty LineBrushProperty = DependencyProperty.Register(
        nameof(LineBrush),
        typeof(Brush),
        typeof(ScoreTrendChart),
        new FrameworkPropertyMetadata(Brushes.Transparent, FrameworkPropertyMetadataOptions.AffectsRender));

    public static readonly DependencyProperty GridBrushProperty = DependencyProperty.Register(
        nameof(GridBrush),
        typeof(Brush),
        typeof(ScoreTrendChart),
        new FrameworkPropertyMetadata(Brushes.Transparent, FrameworkPropertyMetadataOptions.AffectsRender));

    public static readonly DependencyProperty LabelBrushProperty = DependencyProperty.Register(
        nameof(LabelBrush),
        typeof(Brush),
        typeof(ScoreTrendChart),
        new FrameworkPropertyMetadata(Brushes.Transparent, FrameworkPropertyMetadataOptions.AffectsRender));

    public IEnumerable<OverviewScorePoint>? ItemsSource
    {
        get => (IEnumerable<OverviewScorePoint>?)GetValue(ItemsSourceProperty);
        set => SetValue(ItemsSourceProperty, value);
    }

    public Brush LineBrush
    {
        get => (Brush)GetValue(LineBrushProperty);
        set => SetValue(LineBrushProperty, value);
    }

    public Brush GridBrush
    {
        get => (Brush)GetValue(GridBrushProperty);
        set => SetValue(GridBrushProperty, value);
    }

    public Brush LabelBrush
    {
        get => (Brush)GetValue(LabelBrushProperty);
        set => SetValue(LabelBrushProperty, value);
    }

    protected override void OnRender(DrawingContext drawingContext)
    {
        base.OnRender(drawingContext);

        var points = ItemsSource?.ToArray() ?? [];
        if (points.Length < 2 || ActualWidth < 120 || ActualHeight < 50)
        {
            return;
        }

        const double left = 34;
        const double right = 14;
        const double top = 20;
        const double bottom = 28;
        var plotWidth = ActualWidth - left - right;
        var plotHeight = ActualHeight - top - bottom;
        var dpi = VisualTreeHelper.GetDpi(this).PixelsPerDip;
        var gridPen = new Pen(GridBrush, 1);

        for (var score = 0; score <= 100; score += 20)
        {
            var y = top + plotHeight - (score * plotHeight / 100);
            drawingContext.DrawLine(gridPen, new Point(left, y), new Point(left + plotWidth, y));
            DrawText(drawingContext, score.ToString(CultureInfo.InvariantCulture), 10, new Point(2, y - 7), LabelBrush, dpi);
        }

        var renderedPoints = new List<Point>(points.Length);
        for (var index = 0; index < points.Length; index++)
        {
            var x = left + (index * plotWidth / (points.Length - 1));
            var y = top + plotHeight - (Math.Clamp(points[index].Score, 0, 100) * plotHeight / 100);
            renderedPoints.Add(new Point(x, y));

            DrawText(
                drawingContext,
                points[index].DateLabel,
                10,
                new Point(x - 18, top + plotHeight + 8),
                LabelBrush,
                dpi);
        }

        var geometry = new StreamGeometry();
        using (var context = geometry.Open())
        {
            context.BeginFigure(renderedPoints[0], false, false);
            foreach (var point in renderedPoints.Skip(1))
            {
                context.LineTo(point, true, false);
            }
        }

        geometry.Freeze();
        drawingContext.DrawGeometry(null, new Pen(LineBrush, 2), geometry);

        for (var index = 0; index < renderedPoints.Count; index++)
        {
            drawingContext.DrawEllipse(LineBrush, null, renderedPoints[index], 4, 4);
            DrawText(
                drawingContext,
                points[index].Score.ToString(CultureInfo.InvariantCulture),
                10,
                new Point(renderedPoints[index].X - 7, renderedPoints[index].Y - 18),
                Foreground,
                dpi);
        }
    }

    private void DrawText(
        DrawingContext drawingContext,
        string text,
        double fontSize,
        Point origin,
        Brush brush,
        double pixelsPerDip)
    {
        var formattedText = new FormattedText(
            text,
            CultureInfo.GetCultureInfo("th-TH"),
            FlowDirection.LeftToRight,
            new Typeface(FontFamily, FontStyle, FontWeight, FontStretch),
            fontSize,
            brush,
            pixelsPerDip);
        drawingContext.DrawText(formattedText, origin);
    }
}
