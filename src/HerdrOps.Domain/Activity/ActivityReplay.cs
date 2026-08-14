namespace HerdrOps.Domain.Activity;

public sealed record ActivityReplayResult(
    int ContractVersion,
    ActivityPipelineOptions Options,
    ActivityPipelineDiagnostics Diagnostics,
    IReadOnlyList<ActivityEmission> Emissions,
    IReadOnlyList<ActivitySequenceObservation> SequenceObservations,
    long UrgentEmissionCount,
    string ResultSha256);

public static class ActivityReplay
{
    public const int ContractVersion = 1;

    public static ActivityReplayResult Run(
        IReadOnlyList<ActivityEventEnvelope> events,
        ActivityPipelineOptions? options = null)
    {
        ArgumentNullException.ThrowIfNull(events);
        var validatedOptions = (options ?? ActivityPipelineOptions.Default).Validate();
        if (events.Count > validatedOptions.MaximumReplayEvents)
        {
            throw new ActivityReplayException(
                $"Activity replay contains {events.Count} events; the configured maximum is {validatedOptions.MaximumReplayEvents}.");
        }

        var pipeline = new ActivityEventPipeline(validatedOptions);
        var emissions = new List<ActivityEmission>();
        var observations = new List<ActivitySequenceObservation>();
        foreach (var activityEvent in events)
        {
            var step = pipeline.Process(activityEvent);
            emissions.AddRange(step.Emissions);
            observations.AddRange(step.SequenceObservations);
        }

        emissions.AddRange(pipeline.FlushAll());
        var diagnostics = pipeline.GetDiagnostics();
        var urgentEmissionCount = emissions.LongCount(emission =>
            emission.Kind == ActivityEmissionKind.Immediate &&
            emission.HighestUrgency is ActivityUrgency.High or ActivityUrgency.Critical);
        var resultSha256 = ComputeResultSha256(
            validatedOptions,
            diagnostics,
            emissions,
            observations,
            urgentEmissionCount);

        return new ActivityReplayResult(
            ContractVersion,
            validatedOptions,
            diagnostics,
            emissions,
            observations,
            urgentEmissionCount,
            resultSha256);
    }

    private static string ComputeResultSha256(
        ActivityPipelineOptions options,
        ActivityPipelineDiagnostics diagnostics,
        IReadOnlyList<ActivityEmission> emissions,
        IReadOnlyList<ActivitySequenceObservation> observations,
        long urgentEmissionCount)
    {
        using var writer = new CanonicalHashWriter("HerdrOps.ActivityReplayResult.v1");
        writer.Write(ContractVersion);
        writer.Write(options.DebounceWindow.Ticks);
        writer.Write(options.MaximumOpenDebounceBuckets);
        writer.Write(options.MaximumDeduplicationEntries);
        writer.Write(options.MaximumTrackedSourceStreams);
        writer.Write(options.MaximumReplayEvents);

        writer.Write(diagnostics.IngestedEventCount);
        writer.Write(diagnostics.AcceptedEventCount);
        writer.Write(diagnostics.DuplicateEventCount);
        writer.Write(diagnostics.RejectedEventCount);
        writer.Write(diagnostics.ImmediateInputEventCount);
        writer.Write(diagnostics.DebouncedInputEventCount);
        writer.Write(diagnostics.UrgentInputEventCount);
        writer.Write(diagnostics.EmissionCount);
        writer.Write(diagnostics.ImmediateEmissionCount);
        writer.Write(diagnostics.DebouncedEmissionCount);
        writer.Write(diagnostics.EmittedSourceEventCount);
        writer.Write(diagnostics.GapObservationCount);
        writer.Write(diagnostics.ConflictObservationCount);
        writer.Write(diagnostics.RegressionObservationCount);
        writer.Write(diagnostics.DeduplicationEvictionCount);
        writer.Write(diagnostics.SourceStreamEvictionCount);
        writer.Write(diagnostics.CapacityPressureFlushCount);
        writer.Write(diagnostics.CurrentDeduplicationEntries);
        writer.Write(diagnostics.PeakDeduplicationEntries);
        writer.Write(diagnostics.CurrentTrackedSourceStreams);
        writer.Write(diagnostics.PeakTrackedSourceStreams);
        writer.Write(diagnostics.CurrentOpenDebounceBuckets);
        writer.Write(diagnostics.PeakOpenDebounceBuckets);
        writer.Write(urgentEmissionCount);

        writer.Write(emissions.Count);
        foreach (var emission in emissions)
        {
            writer.Write(emission.EmissionSha256);
        }

        writer.Write(observations.Count);
        foreach (var observation in observations)
        {
            writer.Write(observation.ObservationSha256);
        }

        return writer.Finish();
    }
}

public sealed class ActivityReplayException : ArgumentException
{
    public ActivityReplayException(string message)
        : base(message)
    {
    }
}
