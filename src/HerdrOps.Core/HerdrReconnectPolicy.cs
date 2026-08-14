namespace HerdrOps.Core;

public interface IHerdrReconnectDelay
{
    ValueTask DelayAsync(int consecutiveFailureCount, CancellationToken cancellationToken);
}

public sealed record HerdrReconnectPolicy(
    TimeSpan InitialDelay,
    TimeSpan MaximumDelay,
    double JitterFraction)
{
    public static HerdrReconnectPolicy Default { get; } = new(
        TimeSpan.FromMilliseconds(100),
        TimeSpan.FromSeconds(2),
        0.2);

    public TimeSpan CalculateDelay(int consecutiveFailureCount, double jitterSample)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(consecutiveFailureCount);
        if (InitialDelay <= TimeSpan.Zero || MaximumDelay < InitialDelay)
        {
            throw new InvalidOperationException("Herdr reconnect delay bounds are invalid.");
        }

        if (JitterFraction is < 0 or > 0.5)
        {
            throw new InvalidOperationException("Herdr reconnect jitter must be between 0 and 0.5.");
        }

        if (jitterSample is < 0 or > 1)
        {
            throw new ArgumentOutOfRangeException(nameof(jitterSample));
        }

        var exponent = Math.Min(consecutiveFailureCount, 20);
        var unboundedMilliseconds = InitialDelay.TotalMilliseconds * Math.Pow(2, exponent);
        var boundedMilliseconds = Math.Min(unboundedMilliseconds, MaximumDelay.TotalMilliseconds);
        var jitterMultiplier = 1 - JitterFraction + (2 * JitterFraction * jitterSample);
        return TimeSpan.FromMilliseconds(
            Math.Min(boundedMilliseconds * jitterMultiplier, MaximumDelay.TotalMilliseconds));
    }
}

public sealed class HerdrExponentialReconnectDelay : IHerdrReconnectDelay
{
    private readonly HerdrReconnectPolicy _policy;
    private readonly Func<double> _jitterSource;

    public HerdrExponentialReconnectDelay(
        HerdrReconnectPolicy? policy = null,
        Func<double>? jitterSource = null)
    {
        _policy = policy ?? HerdrReconnectPolicy.Default;
        _jitterSource = jitterSource ?? Random.Shared.NextDouble;
    }

    public async ValueTask DelayAsync(
        int consecutiveFailureCount,
        CancellationToken cancellationToken)
    {
        var delay = _policy.CalculateDelay(consecutiveFailureCount, _jitterSource());
        await Task.Delay(delay, cancellationToken).ConfigureAwait(false);
    }
}
