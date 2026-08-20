using System.Windows;
using System.Windows.Media;
using HerdrOps.App.Evaluation;

namespace HerdrOps.App.Controls;

/// <summary>
/// Token-driven score-distribution donut. The adjacent textual legend is the
/// accessible data equivalent; this control is presentation only.
/// </summary>
public sealed class EvaluationScoreDistributionChart : FrameworkElement
{
    public static readonly DependencyProperty ItemsSourceProperty = DependencyProperty.Register(
        nameof(ItemsSource),
        typeof(IEnumerable<EvaluationDistributionBin>),
        typeof(EvaluationScoreDistributionChart),
        new FrameworkPropertyMetadata(null, FrameworkPropertyMetadataOptions.AffectsRender));

    public static readonly DependencyProperty TrackBrushProperty = DependencyProperty.Register(
        nameof(TrackBrush),
        typeof(Brush),
        typeof(EvaluationScoreDistributionChart),
        new FrameworkPropertyMetadata(Brushes.Transparent, FrameworkPropertyMetadataOptions.AffectsRender));

    public static readonly DependencyProperty StrokeThicknessProperty = DependencyProperty.Register(
        nameof(StrokeThickness),
        typeof(double),
        typeof(EvaluationScoreDistributionChart),
        new FrameworkPropertyMetadata(22d, FrameworkPropertyMetadataOptions.AffectsRender));

    public IEnumerable<EvaluationDistributionBin>? ItemsSource
    {
        get => (IEnumerable<EvaluationDistributionBin>?)GetValue(ItemsSourceProperty);
        set => SetValue(ItemsSourceProperty, value);
    }

    public Brush TrackBrush
    {
        get => (Brush)GetValue(TrackBrushProperty);
        set => SetValue(TrackBrushProperty, value);
    }

    public double StrokeThickness
    {
        get => (double)GetValue(StrokeThicknessProperty);
        set => SetValue(StrokeThicknessProperty, value);
    }

    protected override void OnRender(DrawingContext drawingContext)
    {
        base.OnRender(drawingContext);
        var radius = Math.Max(0, (Math.Min(ActualWidth, ActualHeight) - StrokeThickness) / 2);
        if (radius <= 0)
        {
            return;
        }

        var center = new Point(ActualWidth / 2, ActualHeight / 2);
        drawingContext.DrawEllipse(
            null,
            new Pen(TrackBrush, StrokeThickness),
            center,
            radius,
            radius);

        var items = ItemsSource?.Where(item => item.Percentage > 0).ToArray() ?? [];
        var total = items.Sum(item => item.Percentage);
        if (total <= 0)
        {
            return;
        }

        var startAngle = -90d;
        foreach (var item in items)
        {
            var sweep = 360d * (double)(item.Percentage / total);
            var visibleSweep = Math.Max(0, sweep - 1.5d);
            var geometry = CreateArcGeometry(center, radius, startAngle + 0.75d, visibleSweep);
            var brush = TryFindResource(item.AccentBrushKey) as Brush ?? Brushes.Transparent;
            drawingContext.DrawGeometry(null, new Pen(brush, StrokeThickness), geometry);
            startAngle += sweep;
        }
    }

    private static Geometry CreateArcGeometry(
        Point center,
        double radius,
        double startAngle,
        double sweepAngle)
    {
        var startPoint = PointOnCircle(center, radius, startAngle);
        var endPoint = PointOnCircle(center, radius, startAngle + sweepAngle);
        var geometry = new StreamGeometry();
        using (var context = geometry.Open())
        {
            context.BeginFigure(startPoint, false, false);
            context.ArcTo(
                endPoint,
                new Size(radius, radius),
                0,
                sweepAngle > 180,
                SweepDirection.Clockwise,
                true,
                false);
        }

        geometry.Freeze();
        return geometry;
    }

    private static Point PointOnCircle(Point center, double radius, double angle)
    {
        var radians = angle * Math.PI / 180d;
        return new Point(
            center.X + (radius * Math.Cos(radians)),
            center.Y + (radius * Math.Sin(radians)));
    }
}
