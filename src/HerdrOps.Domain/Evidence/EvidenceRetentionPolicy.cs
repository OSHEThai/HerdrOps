namespace HerdrOps.Domain.Evidence;

/// <summary>
/// The v1 local-only default for managed evidence bytes.
/// </summary>
public static class EvidenceRetentionPolicy
{
    public const int PolicyVersion = 1;
    public const int DefaultManagedArtifactRetentionDays = 30;
    public const int MaximumManagedArtifactRetentionDays = 365;

    public static DateTimeOffset ResolveRetainUntil(
        DateTimeOffset observedUtc,
        DateTimeOffset? requestedRetainUntilUtc)
    {
        var observed = EnsureUtc(observedUtc, nameof(observedUtc));
        var resolved = requestedRetainUntilUtc is null
            ? observed.AddDays(DefaultManagedArtifactRetentionDays)
            : EnsureUtc(requestedRetainUntilUtc.Value, nameof(requestedRetainUntilUtc));
        var maximum = observed.AddDays(MaximumManagedArtifactRetentionDays);

        if (resolved < observed || resolved > maximum)
        {
            throw new EvidenceContractException(
                $"Evidence retention must be between observedUtc and observedUtc plus {MaximumManagedArtifactRetentionDays} days.");
        }

        return resolved;
    }

    private static DateTimeOffset EnsureUtc(DateTimeOffset value, string name)
    {
        if (value == default || value.Offset != TimeSpan.Zero)
        {
            throw new EvidenceContractException($"Evidence field {name} must be a non-default UTC timestamp.");
        }

        return value;
    }
}
