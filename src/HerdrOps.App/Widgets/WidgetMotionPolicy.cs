namespace HerdrOps.App.Widgets;

/// <summary>
/// Converts user and operating-system motion preferences into a bounded transition duration.
/// </summary>
public sealed record WidgetMotionPolicy(bool ReducedMotion, TimeSpan TransitionDuration)
{
    private static readonly TimeSpan StandardDuration = TimeSpan.FromMilliseconds(150);

    public static WidgetMotionPolicy Create(
        bool reducedMotionRequested,
        bool systemAnimationsEnabled) =>
        reducedMotionRequested || !systemAnimationsEnabled
            ? new(true, TimeSpan.Zero)
            : new(false, StandardDuration);
}
