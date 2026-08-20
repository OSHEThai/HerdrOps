using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using HerdrOps.App.Evaluation;

namespace HerdrOps.App.Controls;

/// <summary>
/// Lightweight seven-point Evaluation trend chart with visible missing-value gaps.
/// </summary>
public sealed class EvaluationScoreTrendChart : Control
{
    public static readonly DependencyProperty ItemsSourceProperty = DependencyProperty.Register(
        nameof(ItemsSource),
        typeof(IEnumerable<EvaluationTrendPoint>),
        typeof(EvaluationScoreTrendChart),
        new FrameworkPropertyMetadata(null, FrameworkPropertyMetadataOptions.AffectsRender));

    public static readonly DependencyProperty LineBrushProperty = DependencyProperty.Register(
        nameof(LineBrush),
        typeof(Brush),
        typeof(EvaluationScoreTrendChart),
        new FrameworkPropertyMetadata(Brushes.Transparent, FrameworkPropertyMetadataOptions.AffectsRender));

    public static readonly DependencyProperty GridBrushProperty = DependencyProperty.Register(
        nameof(GridBrush),
        typeof(Brush),
        typeof(EvaluationScoreTrendChart),
        new FrameworkPropertyMetadata(Brushes.Transparent, FrameworkPropertyMetadataOptions.AffectsRender));

    public static readonly DependencyProperty LabelBrushProperty = DependencyProperty.Register(
        nameof(LabelBrush),
        typeof(Brush),
        typeof(EvaluationScoreTrendChart),
        new FrameworkPropertyMetadata(Brushes.Transparent, FrameworkPropertyMetadataOptions.AffectsRender));

    public IEnumerable<EvaluationTrendPoint>? ItemsSource
    {
        get => (IEnumerable<EvaluationTrendPoint>?)GetValue(ItemsSourceProperty);
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
        var points = ItemsSource?.Take(7).ToArray() ?? [];
        if (points.Length < 2 || ActualWidth < 120 || ActualHeight < 80)
        {
            return;
        }

        const double left = 34;
        const double right = 14;
        const double top = 20;
        const double bottom = 30;
        var plotWidth = ActualWidth - left - right;
        var plotHeight = ActualHeight - top - bottom;
        var dpi = VisualTreeHelper.GetDpi(this).PixelsPerDip;
        var gridPen = new Pen(GridBrush, 1);

        for (var score = 0; score <= 100; score += 20)
        {
            var y = top + plotHeight - (score * plotHeight / 100d);
            drawingContext.DrawLine(gridPen, new Point(left, y), new Point(left + plotWidth, y));
            DrawText(drawingContext, score.ToString(CultureInfo.InvariantCulture), 10, new Point(2, y - 7), LabelBrush, dpi);
        }

        var rendered = new Point?[points.Length];
        for (var index = 0; index < points.Length; index++)
        {
            var x = left + (index * plotWidth / (points.Length - 1));
            DrawText(
                drawingContext,
                points[index].DateLabel,
                10,
                new Point(x - 18, top + plotHeight + 9),
                LabelBrush,
                dpi);
            if (points[index].Score is not { } score)
            {
                continue;
            }

            var y = top + plotHeight - ((double)Math.Clamp(score, 0, 100) * plotHeight / 100d);
            rendered[index] = new Point(x, y);
        }

        var linePen = new Pen(LineBrush, 2);
        for (var index = 1; index < rendered.Length; index++)
        {
            if (rendered[index - 1] is { } previous && rendered[index] is { } current)
            {
                drawingContext.DrawLine(linePen, previous, current);
            }
        }

        for (var index = 0; index < rendered.Length; index++)
        {
            if (rendered[index] is not { } point)
            {
                continue;
            }

            drawingContext.DrawEllipse(LineBrush, null, point, 4, 4);
            DrawText(
                drawingContext,
                points[index].ScoreLabel,
                10,
                new Point(point.X - 8, point.Y - 18),
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
        var formatted = new FormattedText(
            text,
            CultureInfo.GetCultureInfo("th-TH"),
            FlowDirection.LeftToRight,
            new Typeface(FontFamily, FontStyle, FontWeight, FontStretch),
            fontSize,
            brush,
            pixelsPerDip);
        drawingContext.DrawText(formatted, origin);
    }
}
