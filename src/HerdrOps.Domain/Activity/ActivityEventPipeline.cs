namespace HerdrOps.Domain.Activity;

public sealed record ActivityPipelineOptions(
    TimeSpan DebounceWindow,
    int MaximumOpenDebounceBuckets,
    int MaximumDeduplicationEntries,
    int MaximumTrackedSourceStreams,
    int MaximumReplayEvents)
{
    public static ActivityPipelineOptions Default { get; } = new(
        TimeSpan.FromMilliseconds(250),
        MaximumOpenDebounceBuckets: 1024,
        MaximumDeduplicationEntries: 65_536,
        MaximumTrackedSourceStreams: 4096,
        MaximumReplayEvents: 100_000);

    public ActivityPipelineOptions Validate()
    {
        if (DebounceWindow <= TimeSpan.Zero || DebounceWindow > TimeSpan.FromMinutes(1))
        {
            throw new ArgumentOutOfRangeException(
                nameof(DebounceWindow),
                "The activity debounce window must be greater than zero and no longer than one minute.");
        }

        ValidateBound(MaximumOpenDebounceBuckets, nameof(MaximumOpenDebounceBuckets));
        ValidateBound(MaximumDeduplicationEntries, nameof(MaximumDeduplicationEntries));
        ValidateBound(MaximumTrackedSourceStreams, nameof(MaximumTrackedSourceStreams));
        ValidateBound(MaximumReplayEvents, nameof(MaximumReplayEvents));
        return this;
    }

    private static void ValidateBound(int value, string name)
    {
        if (value <= 0 || value > 1_000_000)
        {
            throw new ArgumentOutOfRangeException(
                name,
                "Activity pipeline collection bounds must be between 1 and 1,000,000 entries.");
        }
    }
}

public enum ActivityPipelineDisposition
{
    AcceptedImmediate = 1,
    AcceptedBuffered = 2,
    Duplicate = 3,
    RejectedIdentityConflict = 4,
    RejectedSequenceConflict = 5,
    RejectedSequenceRegression = 6,
}

public enum ActivitySequenceObservationKind
{
    Gap = 1,
    Conflict = 2,
    Regression = 3,
    IdentityConflict = 4,
}

public enum ActivityEmissionKind
{
    Immediate = 1,
    DebouncedSummary = 2,
}

public enum ActivityEmissionReason
{
    ImmediateRequested = 1,
    UrgentBypass = 2,
    WindowElapsed = 3,
    CapacityPressure = 4,
    ReplayCompleted = 5,
}

public sealed record ActivitySequenceObservation(
    ActivitySequenceObservationKind Kind,
    ActivitySourceKind SourceKind,
    string SourceInstanceId,
    string SourceEpoch,
    long? PreviousSequence,
    long? ExpectedSequence,
    long? ObservedSequence,
    string PreviousEventIdentitySha256,
    string ObservedEventIdentitySha256,
    string Detail,
    string ObservationSha256);

public sealed record ActivityEmission(
    long EmissionSequence,
    ActivityEmissionKind Kind,
    ActivityEmissionReason Reason,
    ActivitySourceKind SourceKind,
    string SourceInstanceId,
    string SourceEpoch,
    string EventType,
    Guid CorrelationId,
    string? DebounceKey,
    ActivityConfidence Confidence,
    ActivityUrgency HighestUrgency,
    long EventCount,
    long FirstIngestSequence,
    long LastIngestSequence,
    DateTimeOffset FirstOccurredUtc,
    DateTimeOffset LastOccurredUtc,
    DateTimeOffset FirstObservedUtc,
    DateTimeOffset LastObservedUtc,
    string FirstEventIdentitySha256,
    string LastEventIdentitySha256,
    string AggregateSha256,
    string RedactedSummary,
    string EmissionSha256);

public sealed record ActivityPipelineStep(
    ActivityPipelineDisposition Disposition,
    NormalizedActivityEvent Event,
    IReadOnlyList<ActivityEmission> Emissions,
    IReadOnlyList<ActivitySequenceObservation> SequenceObservations);

public sealed record ActivityPipelineDiagnostics(
    long IngestedEventCount,
    long AcceptedEventCount,
    long DuplicateEventCount,
    long RejectedEventCount,
    long ImmediateInputEventCount,
    long DebouncedInputEventCount,
    long UrgentInputEventCount,
    long EmissionCount,
    long ImmediateEmissionCount,
    long DebouncedEmissionCount,
    long EmittedSourceEventCount,
    long GapObservationCount,
    long ConflictObservationCount,
    long RegressionObservationCount,
    long DeduplicationEvictionCount,
    long SourceStreamEvictionCount,
    long CapacityPressureFlushCount,
    int CurrentDeduplicationEntries,
    int PeakDeduplicationEntries,
    int CurrentTrackedSourceStreams,
    int PeakTrackedSourceStreams,
    int CurrentOpenDebounceBuckets,
    int PeakOpenDebounceBuckets);

public sealed class ActivityEventPipeline
{
    private readonly ActivityPipelineOptions _options;
    private readonly Dictionary<string, DeduplicationEntry> _deduplicationEntries =
        new(StringComparer.Ordinal);
    private readonly Queue<string> _deduplicationOrder = new();
    private readonly Dictionary<string, SourceStreamState> _sourceStreams =
        new(StringComparer.Ordinal);
    private readonly Queue<string> _sourceStreamOrder = new();
    private readonly Dictionary<string, DebounceBucket> _debounceBuckets =
        new(StringComparer.Ordinal);

    private long _ingestSequence;
    private long _emissionSequence;
    private DateTimeOffset? _watermarkUtc;
    private long _acceptedEventCount;
    private long _duplicateEventCount;
    private long _rejectedEventCount;
    private long _immediateInputEventCount;
    private long _debouncedInputEventCount;
    private long _urgentInputEventCount;
    private long _emissionCount;
    private long _immediateEmissionCount;
    private long _debouncedEmissionCount;
    private long _emittedSourceEventCount;
    private long _gapObservationCount;
    private long _conflictObservationCount;
    private long _regressionObservationCount;
    private long _deduplicationEvictionCount;
    private long _sourceStreamEvictionCount;
    private long _capacityPressureFlushCount;
    private int _peakDeduplicationEntries;
    private int _peakTrackedSourceStreams;
    private int _peakOpenDebounceBuckets;

    public ActivityEventPipeline(ActivityPipelineOptions? options = null)
    {
        _options = (options ?? ActivityPipelineOptions.Default).Validate();
    }

    public ActivityPipelineStep Process(ActivityEventEnvelope envelope)
    {
        ArgumentNullException.ThrowIfNull(envelope);
        var ingestSequence = checked(++_ingestSequence);
        var normalized = ActivityEventContract.NormalizeAndValidate(envelope, ingestSequence);
        AdvanceWatermark(normalized.Envelope.ObservedUtc);

        var emissions = FlushElapsedBuckets();
        var observations = new List<ActivitySequenceObservation>();

        if (_deduplicationEntries.TryGetValue(normalized.EventIdentitySha256, out var existing))
        {
            if (string.Equals(
                    existing.EnvelopeSha256,
                    normalized.EnvelopeSha256,
                    StringComparison.Ordinal))
            {
                _duplicateEventCount++;
                return new ActivityPipelineStep(
                    ActivityPipelineDisposition.Duplicate,
                    normalized,
                    emissions,
                    observations);
            }

            var identityConflict = CreateObservation(
                ActivitySequenceObservationKind.IdentityConflict,
                normalized,
                existing.SourceSequence,
                existing.SourceSequence,
                normalized.Envelope.SourceSequence,
                existing.EventIdentitySha256,
                "The same source event identity was observed with different normalized content.");
            observations.Add(identityConflict);
            RecordObservation(identityConflict.Kind);
            _rejectedEventCount++;
            return new ActivityPipelineStep(
                ActivityPipelineDisposition.RejectedIdentityConflict,
                normalized,
                emissions,
                observations);
        }

        var sequenceDisposition = ObserveSourceSequence(normalized, observations);
        if (sequenceDisposition is not null)
        {
            if (sequenceDisposition == ActivityPipelineDisposition.Duplicate)
            {
                _duplicateEventCount++;
            }
            else
            {
                _rejectedEventCount++;
            }

            return new ActivityPipelineStep(
                sequenceDisposition.Value,
                normalized,
                emissions,
                observations);
        }

        RememberIdentity(normalized);
        _acceptedEventCount++;
        if (normalized.Envelope.Urgency is ActivityUrgency.High or ActivityUrgency.Critical)
        {
            _urgentInputEventCount++;
            _immediateInputEventCount++;
            emissions.Add(CreateImmediateEmission(normalized, ActivityEmissionReason.UrgentBypass));
            return new ActivityPipelineStep(
                ActivityPipelineDisposition.AcceptedImmediate,
                normalized,
                emissions,
                observations);
        }

        if (normalized.Envelope.DeliveryMode == ActivityDeliveryMode.Immediate)
        {
            _immediateInputEventCount++;
            emissions.Add(CreateImmediateEmission(
                normalized,
                ActivityEmissionReason.ImmediateRequested));
            return new ActivityPipelineStep(
                ActivityPipelineDisposition.AcceptedImmediate,
                normalized,
                emissions,
                observations);
        }

        _debouncedInputEventCount++;
        BufferDebouncedEvent(normalized, emissions);
        return new ActivityPipelineStep(
            ActivityPipelineDisposition.AcceptedBuffered,
            normalized,
            emissions,
            observations);
    }

    public IReadOnlyList<ActivityEmission> FlushAll()
    {
        var buckets = _debounceBuckets.Values
            .OrderBy(bucket => bucket.FirstIngestSequence)
            .ThenBy(bucket => bucket.Key, StringComparer.Ordinal)
            .ToArray();
        var emissions = new List<ActivityEmission>(buckets.Length);
        foreach (var bucket in buckets)
        {
            _debounceBuckets.Remove(bucket.Key);
            emissions.Add(CreateDebouncedEmission(
                bucket,
                ActivityEmissionReason.ReplayCompleted));
        }

        return emissions;
    }

    public ActivityPipelineDiagnostics GetDiagnostics() => new(
        IngestedEventCount: _ingestSequence,
        AcceptedEventCount: _acceptedEventCount,
        DuplicateEventCount: _duplicateEventCount,
        RejectedEventCount: _rejectedEventCount,
        ImmediateInputEventCount: _immediateInputEventCount,
        DebouncedInputEventCount: _debouncedInputEventCount,
        UrgentInputEventCount: _urgentInputEventCount,
        EmissionCount: _emissionCount,
        ImmediateEmissionCount: _immediateEmissionCount,
        DebouncedEmissionCount: _debouncedEmissionCount,
        EmittedSourceEventCount: _emittedSourceEventCount,
        GapObservationCount: _gapObservationCount,
        ConflictObservationCount: _conflictObservationCount,
        RegressionObservationCount: _regressionObservationCount,
        DeduplicationEvictionCount: _deduplicationEvictionCount,
        SourceStreamEvictionCount: _sourceStreamEvictionCount,
        CapacityPressureFlushCount: _capacityPressureFlushCount,
        CurrentDeduplicationEntries: _deduplicationEntries.Count,
        PeakDeduplicationEntries: _peakDeduplicationEntries,
        CurrentTrackedSourceStreams: _sourceStreams.Count,
        PeakTrackedSourceStreams: _peakTrackedSourceStreams,
        CurrentOpenDebounceBuckets: _debounceBuckets.Count,
        PeakOpenDebounceBuckets: _peakOpenDebounceBuckets);

    private ActivityPipelineDisposition? ObserveSourceSequence(
        NormalizedActivityEvent activityEvent,
        ICollection<ActivitySequenceObservation> observations)
    {
        var sourceSequence = activityEvent.Envelope.SourceSequence;
        if (sourceSequence is null)
        {
            return null;
        }

        var streamKey = CreateSourceStreamKey(activityEvent.Envelope);
        if (!_sourceStreams.TryGetValue(streamKey, out var stream))
        {
            EnsureSourceStreamCapacity();
            _sourceStreams.Add(
                streamKey,
                new SourceStreamState(
                    sourceSequence.Value,
                    activityEvent.EventIdentitySha256,
                    activityEvent.EnvelopeSha256));
            _sourceStreamOrder.Enqueue(streamKey);
            _peakTrackedSourceStreams = Math.Max(_peakTrackedSourceStreams, _sourceStreams.Count);
            return null;
        }

        var expectedSequence = stream.LastSequence == long.MaxValue
            ? (long?)null
            : stream.LastSequence + 1;
        if (sourceSequence == expectedSequence)
        {
            _sourceStreams[streamKey] =
                new SourceStreamState(
                    sourceSequence.Value,
                    activityEvent.EventIdentitySha256,
                    activityEvent.EnvelopeSha256);
            return null;
        }

        if (sourceSequence.Value > stream.LastSequence)
        {
            var observation = CreateObservation(
                ActivitySequenceObservationKind.Gap,
                activityEvent,
                stream.LastSequence,
                expectedSequence,
                sourceSequence,
                stream.LastEventIdentitySha256,
                $"Source sequence gap: expected {expectedSequence} but observed {sourceSequence.Value}.");
            observations.Add(observation);
            RecordObservation(observation.Kind);
            _sourceStreams[streamKey] =
                new SourceStreamState(
                    sourceSequence.Value,
                    activityEvent.EventIdentitySha256,
                    activityEvent.EnvelopeSha256);
            return null;
        }

        if (sourceSequence.Value == stream.LastSequence)
        {
            if (string.Equals(
                    activityEvent.EventIdentitySha256,
                    stream.LastEventIdentitySha256,
                    StringComparison.Ordinal))
            {
                if (string.Equals(
                        activityEvent.EnvelopeSha256,
                        stream.LastEnvelopeSha256,
                        StringComparison.Ordinal))
                {
                    return ActivityPipelineDisposition.Duplicate;
                }

                var identityConflict = CreateObservation(
                    ActivitySequenceObservationKind.IdentityConflict,
                    activityEvent,
                    stream.LastSequence,
                    stream.LastSequence,
                    sourceSequence,
                    stream.LastEventIdentitySha256,
                    "The latest source event identity was repeated with different normalized content after deduplication-cache eviction.");
                observations.Add(identityConflict);
                RecordObservation(identityConflict.Kind);
                return ActivityPipelineDisposition.RejectedIdentityConflict;
            }

            var observation = CreateObservation(
                ActivitySequenceObservationKind.Conflict,
                activityEvent,
                stream.LastSequence,
                expectedSequence,
                sourceSequence,
                stream.LastEventIdentitySha256,
                "Two distinct source events claimed the same source sequence.");
            observations.Add(observation);
            RecordObservation(observation.Kind);
            return ActivityPipelineDisposition.RejectedSequenceConflict;
        }

        var regression = CreateObservation(
            ActivitySequenceObservationKind.Regression,
            activityEvent,
            stream.LastSequence,
            expectedSequence,
            sourceSequence,
            stream.LastEventIdentitySha256,
            $"Source sequence regressed from {stream.LastSequence} to {sourceSequence.Value}.");
        observations.Add(regression);
        RecordObservation(regression.Kind);
        return ActivityPipelineDisposition.RejectedSequenceRegression;
    }

    private void BufferDebouncedEvent(
        NormalizedActivityEvent activityEvent,
        ICollection<ActivityEmission> emissions)
    {
        var key = CreateDebounceBucketKey(activityEvent.Envelope);
        if (_debounceBuckets.TryGetValue(key, out var existing))
        {
            existing.Add(activityEvent);
            return;
        }

        if (_debounceBuckets.Count >= _options.MaximumOpenDebounceBuckets)
        {
            var oldest = _debounceBuckets.Values
                .OrderBy(bucket => bucket.FirstIngestSequence)
                .ThenBy(bucket => bucket.Key, StringComparer.Ordinal)
                .First();
            _debounceBuckets.Remove(oldest.Key);
            _capacityPressureFlushCount++;
            emissions.Add(CreateDebouncedEmission(
                oldest,
                ActivityEmissionReason.CapacityPressure));
        }

        _debounceBuckets.Add(
            key,
            new DebounceBucket(key, activityEvent, _options.DebounceWindow));
        _peakOpenDebounceBuckets = Math.Max(_peakOpenDebounceBuckets, _debounceBuckets.Count);
    }

    private List<ActivityEmission> FlushElapsedBuckets()
    {
        if (_watermarkUtc is null || _debounceBuckets.Count == 0)
        {
            return [];
        }

        var due = _debounceBuckets.Values
            .Where(bucket => bucket.DueUtc <= _watermarkUtc.Value)
            .OrderBy(bucket => bucket.DueUtc)
            .ThenBy(bucket => bucket.FirstIngestSequence)
            .ThenBy(bucket => bucket.Key, StringComparer.Ordinal)
            .ToArray();
        var emissions = new List<ActivityEmission>(due.Length);
        foreach (var bucket in due)
        {
            _debounceBuckets.Remove(bucket.Key);
            emissions.Add(CreateDebouncedEmission(
                bucket,
                ActivityEmissionReason.WindowElapsed));
        }

        return emissions;
    }

    private ActivityEmission CreateImmediateEmission(
        NormalizedActivityEvent activityEvent,
        ActivityEmissionReason reason)
    {
        var aggregateSha256 = ComputeAggregateSha256(null, activityEvent.EnvelopeSha256);
        return RecordEmission(
            ActivityEmissionKind.Immediate,
            reason,
            activityEvent.Envelope,
            eventCount: 1,
            activityEvent.IngestSequence,
            activityEvent.IngestSequence,
            activityEvent.Envelope.OccurredUtc,
            activityEvent.Envelope.OccurredUtc,
            activityEvent.Envelope.ObservedUtc,
            activityEvent.Envelope.ObservedUtc,
            activityEvent.EventIdentitySha256,
            activityEvent.EventIdentitySha256,
            aggregateSha256,
            activityEvent.Envelope.RedactedSummary);
    }

    private ActivityEmission CreateDebouncedEmission(
        DebounceBucket bucket,
        ActivityEmissionReason reason) =>
        RecordEmission(
            ActivityEmissionKind.DebouncedSummary,
            reason,
            bucket.Template,
            bucket.EventCount,
            bucket.FirstIngestSequence,
            bucket.LastIngestSequence,
            bucket.FirstOccurredUtc,
            bucket.LastOccurredUtc,
            bucket.FirstObservedUtc,
            bucket.LastObservedUtc,
            bucket.FirstEventIdentitySha256,
            bucket.LastEventIdentitySha256,
            bucket.AggregateSha256,
            bucket.RedactedSummary);

    private ActivityEmission RecordEmission(
        ActivityEmissionKind kind,
        ActivityEmissionReason reason,
        ActivityEventEnvelope template,
        long eventCount,
        long firstIngestSequence,
        long lastIngestSequence,
        DateTimeOffset firstOccurredUtc,
        DateTimeOffset lastOccurredUtc,
        DateTimeOffset firstObservedUtc,
        DateTimeOffset lastObservedUtc,
        string firstEventIdentitySha256,
        string lastEventIdentitySha256,
        string aggregateSha256,
        string redactedSummary)
    {
        var emissionSequence = checked(++_emissionSequence);
        using var writer = new CanonicalHashWriter("HerdrOps.ActivityEmission.v1");
        writer.Write(emissionSequence);
        writer.Write((int)kind);
        writer.Write((int)reason);
        writer.Write((int)template.SourceKind);
        writer.Write(template.SourceInstanceId);
        writer.Write(template.SourceEpoch);
        writer.Write(template.EventType);
        writer.Write(template.CorrelationId.ToString("D"));
        writer.Write(template.DebounceKey);
        writer.Write((int)template.Confidence);
        writer.Write((int)template.Urgency);
        writer.Write(eventCount);
        writer.Write(firstIngestSequence);
        writer.Write(lastIngestSequence);
        writer.Write(firstOccurredUtc);
        writer.Write(lastOccurredUtc);
        writer.Write(firstObservedUtc);
        writer.Write(lastObservedUtc);
        writer.Write(firstEventIdentitySha256);
        writer.Write(lastEventIdentitySha256);
        writer.Write(aggregateSha256);
        writer.Write(redactedSummary);
        var emissionSha256 = writer.Finish();

        _emissionCount++;
        _emittedSourceEventCount += eventCount;
        if (kind == ActivityEmissionKind.Immediate)
        {
            _immediateEmissionCount++;
        }
        else
        {
            _debouncedEmissionCount++;
        }

        return new ActivityEmission(
            emissionSequence,
            kind,
            reason,
            template.SourceKind,
            template.SourceInstanceId,
            template.SourceEpoch,
            template.EventType,
            template.CorrelationId,
            template.DebounceKey,
            template.Confidence,
            template.Urgency,
            eventCount,
            firstIngestSequence,
            lastIngestSequence,
            firstOccurredUtc,
            lastOccurredUtc,
            firstObservedUtc,
            lastObservedUtc,
            firstEventIdentitySha256,
            lastEventIdentitySha256,
            aggregateSha256,
            redactedSummary,
            emissionSha256);
    }

    private ActivitySequenceObservation CreateObservation(
        ActivitySequenceObservationKind kind,
        NormalizedActivityEvent activityEvent,
        long? previousSequence,
        long? expectedSequence,
        long? observedSequence,
        string previousEventIdentitySha256,
        string detail)
    {
        using var writer = new CanonicalHashWriter("HerdrOps.ActivitySequenceObservation.v1");
        writer.Write((int)kind);
        writer.Write((int)activityEvent.Envelope.SourceKind);
        writer.Write(activityEvent.Envelope.SourceInstanceId);
        writer.Write(activityEvent.Envelope.SourceEpoch);
        writer.Write(previousSequence);
        writer.Write(expectedSequence);
        writer.Write(observedSequence);
        writer.Write(previousEventIdentitySha256);
        writer.Write(activityEvent.EventIdentitySha256);
        writer.Write(detail);
        var hash = writer.Finish();
        return new ActivitySequenceObservation(
            kind,
            activityEvent.Envelope.SourceKind,
            activityEvent.Envelope.SourceInstanceId,
            activityEvent.Envelope.SourceEpoch,
            previousSequence,
            expectedSequence,
            observedSequence,
            previousEventIdentitySha256,
            activityEvent.EventIdentitySha256,
            detail,
            hash);
    }

    private void RememberIdentity(NormalizedActivityEvent activityEvent)
    {
        while (_deduplicationEntries.Count >= _options.MaximumDeduplicationEntries)
        {
            var evicted = _deduplicationOrder.Dequeue();
            if (_deduplicationEntries.Remove(evicted))
            {
                _deduplicationEvictionCount++;
            }
        }

        _deduplicationEntries.Add(
            activityEvent.EventIdentitySha256,
            new DeduplicationEntry(
                activityEvent.EventIdentitySha256,
                activityEvent.EnvelopeSha256,
                activityEvent.Envelope.SourceSequence));
        _deduplicationOrder.Enqueue(activityEvent.EventIdentitySha256);
        _peakDeduplicationEntries = Math.Max(
            _peakDeduplicationEntries,
            _deduplicationEntries.Count);
    }

    private void EnsureSourceStreamCapacity()
    {
        while (_sourceStreams.Count >= _options.MaximumTrackedSourceStreams)
        {
            var evicted = _sourceStreamOrder.Dequeue();
            if (_sourceStreams.Remove(evicted))
            {
                _sourceStreamEvictionCount++;
            }
        }
    }

    private void AdvanceWatermark(DateTimeOffset observedUtc)
    {
        if (_watermarkUtc is null || observedUtc > _watermarkUtc.Value)
        {
            _watermarkUtc = observedUtc;
        }
    }

    private void RecordObservation(ActivitySequenceObservationKind kind)
    {
        switch (kind)
        {
            case ActivitySequenceObservationKind.Gap:
                _gapObservationCount++;
                break;
            case ActivitySequenceObservationKind.Regression:
                _regressionObservationCount++;
                break;
            case ActivitySequenceObservationKind.Conflict:
            case ActivitySequenceObservationKind.IdentityConflict:
                _conflictObservationCount++;
                break;
            default:
                throw new ArgumentOutOfRangeException(nameof(kind), kind, null);
        }
    }

    private static string CreateSourceStreamKey(ActivityEventEnvelope envelope)
    {
        using var writer = new CanonicalHashWriter("HerdrOps.ActivitySourceStream.v1");
        writer.Write((int)envelope.SourceKind);
        writer.Write(envelope.SourceInstanceId);
        writer.Write(envelope.SourceEpoch);
        return writer.Finish();
    }

    private static string CreateDebounceBucketKey(ActivityEventEnvelope envelope)
    {
        using var writer = new CanonicalHashWriter("HerdrOps.ActivityDebounceBucket.v1");
        writer.Write((int)envelope.SourceKind);
        writer.Write(envelope.SourceInstanceId);
        writer.Write(envelope.SourceEpoch);
        writer.Write(envelope.EventType);
        writer.Write(envelope.CorrelationId.ToString("D"));
        writer.Write(envelope.DebounceKey);
        writer.Write((int)envelope.Confidence);
        writer.Write(envelope.AgentTerminalId);
        writer.Write(envelope.PaneId);
        writer.Write(envelope.TaskId);
        writer.Write(envelope.ProcessId);
        return writer.Finish();
    }

    private static string ComputeAggregateSha256(string? previousHash, string eventHash)
    {
        using var writer = new CanonicalHashWriter("HerdrOps.ActivityAggregate.v1");
        writer.Write(previousHash);
        writer.Write(eventHash);
        return writer.Finish();
    }

    private sealed record DeduplicationEntry(
        string EventIdentitySha256,
        string EnvelopeSha256,
        long? SourceSequence);

    private sealed record SourceStreamState(
        long LastSequence,
        string LastEventIdentitySha256,
        string LastEnvelopeSha256);

    private sealed class DebounceBucket
    {
        public DebounceBucket(
            string key,
            NormalizedActivityEvent activityEvent,
            TimeSpan window)
        {
            Key = key;
            Template = activityEvent.Envelope;
            DueUtc = activityEvent.Envelope.ObservedUtc > DateTimeOffset.MaxValue - window
                ? DateTimeOffset.MaxValue
                : activityEvent.Envelope.ObservedUtc + window;
            EventCount = 1;
            FirstIngestSequence = activityEvent.IngestSequence;
            LastIngestSequence = activityEvent.IngestSequence;
            FirstOccurredUtc = activityEvent.Envelope.OccurredUtc;
            LastOccurredUtc = activityEvent.Envelope.OccurredUtc;
            FirstObservedUtc = activityEvent.Envelope.ObservedUtc;
            LastObservedUtc = activityEvent.Envelope.ObservedUtc;
            FirstEventIdentitySha256 = activityEvent.EventIdentitySha256;
            LastEventIdentitySha256 = activityEvent.EventIdentitySha256;
            AggregateSha256 = ComputeAggregateSha256(null, activityEvent.EnvelopeSha256);
            RedactedSummary = activityEvent.Envelope.RedactedSummary;
        }

        public string Key { get; }

        public ActivityEventEnvelope Template { get; }

        public DateTimeOffset DueUtc { get; }

        public long EventCount { get; private set; }

        public long FirstIngestSequence { get; }

        public long LastIngestSequence { get; private set; }

        public DateTimeOffset FirstOccurredUtc { get; }

        public DateTimeOffset LastOccurredUtc { get; private set; }

        public DateTimeOffset FirstObservedUtc { get; }

        public DateTimeOffset LastObservedUtc { get; private set; }

        public string FirstEventIdentitySha256 { get; }

        public string LastEventIdentitySha256 { get; private set; }

        public string AggregateSha256 { get; private set; }

        public string RedactedSummary { get; private set; }

        public void Add(NormalizedActivityEvent activityEvent)
        {
            EventCount = checked(EventCount + 1);
            LastIngestSequence = activityEvent.IngestSequence;
            LastOccurredUtc = activityEvent.Envelope.OccurredUtc;
            LastObservedUtc = activityEvent.Envelope.ObservedUtc;
            LastEventIdentitySha256 = activityEvent.EventIdentitySha256;
            AggregateSha256 = ComputeAggregateSha256(
                AggregateSha256,
                activityEvent.EnvelopeSha256);
            RedactedSummary = activityEvent.Envelope.RedactedSummary;
        }
    }
}
