using System.Security.Cryptography;
using System.Text;
using HerdrOps.Domain.Activity;

namespace HerdrOps.UnitTests;

[TestClass]
public sealed class ActivityEventPipelineTests
{
    private static readonly DateTimeOffset BaseUtc =
        new(2026, 8, 15, 1, 2, 3, TimeSpan.Zero);

    private static readonly Guid CorrelationId =
        Guid.Parse("0b5fbc5e-c794-4d36-b037-6c46fa78a68d");

    [TestMethod]
    public void RepeatedReplayProducesExactSameHashAndSummary()
    {
        var duplicate = CreateEvent(
            "herdr-3",
            sourceSequence: 3,
            observedMilliseconds: 20,
            deliveryMode: ActivityDeliveryMode.Debounced,
            debounceKey: "pane-output");
        ActivityEventEnvelope[] events =
        [
            CreateEvent("herdr-1", sourceSequence: 1, observedMilliseconds: 0),
            CreateEvent(
                "herdr-2",
                sourceSequence: 2,
                observedMilliseconds: 10,
                deliveryMode: ActivityDeliveryMode.Debounced,
                debounceKey: "pane-output"),
            duplicate,
            duplicate,
            CreateEvent(
                "herdr-6",
                sourceSequence: 6,
                observedMilliseconds: 250,
                urgency: ActivityUrgency.High,
                deliveryMode: ActivityDeliveryMode.Debounced,
                debounceKey: null),
            CreateEvent(
                "file-a",
                sourceSequence: null,
                observedMilliseconds: 260,
                sourceKind: ActivitySourceKind.FileSystem,
                sourceInstanceId: "repo-root",
                deliveryMode: ActivityDeliveryMode.Debounced,
                debounceKey: "src/service.cs"),
            CreateEvent(
                "file-b",
                sourceSequence: null,
                observedMilliseconds: 270,
                sourceKind: ActivitySourceKind.FileSystem,
                sourceInstanceId: "repo-root",
                deliveryMode: ActivityDeliveryMode.Debounced,
                debounceKey: "src/service.cs"),
        ];

        var first = ActivityReplay.Run(events);
        var second = ActivityReplay.Run(events);

        Assert.AreEqual(first.ResultSha256, second.ResultSha256);
        Assert.AreEqual(first.Diagnostics, second.Diagnostics);
        CollectionAssert.AreEqual(first.Emissions.ToArray(), second.Emissions.ToArray());
        CollectionAssert.AreEqual(
            first.SequenceObservations.ToArray(),
            second.SequenceObservations.ToArray());
        Assert.AreEqual(7, first.Diagnostics.IngestedEventCount);
        Assert.AreEqual(6, first.Diagnostics.AcceptedEventCount);
        Assert.AreEqual(1, first.Diagnostics.DuplicateEventCount);
        Assert.AreEqual(1, first.Diagnostics.GapObservationCount);
        Assert.AreEqual(1, first.Diagnostics.UrgentInputEventCount);
        Assert.AreEqual(1, first.UrgentEmissionCount);
        Assert.AreEqual(
            first.Diagnostics.AcceptedEventCount,
            first.Diagnostics.EmittedSourceEventCount);
        Assert.IsTrue(first.Emissions.Any(emission =>
            emission.Kind == ActivityEmissionKind.DebouncedSummary &&
            emission.EventCount == 2));
    }

    [TestMethod]
    public void DuplicateAndNoisyEventsStayBoundedWithoutLosingUrgentEvents()
    {
        var options = new ActivityPipelineOptions(
            TimeSpan.FromMilliseconds(250),
            MaximumOpenDebounceBuckets: 2,
            MaximumDeduplicationEntries: 3,
            MaximumTrackedSourceStreams: 2,
            MaximumReplayEvents: 100);
        var pipeline = new ActivityEventPipeline(options);
        var emissions = new List<ActivityEmission>();

        for (var index = 0; index < 12; index++)
        {
            var noisy = CreateEvent(
                $"noise-{index}",
                sourceSequence: null,
                observedMilliseconds: index,
                sourceKind: ActivitySourceKind.WindowsProcess,
                sourceInstanceId: "process-sampler",
                deliveryMode: ActivityDeliveryMode.Debounced,
                debounceKey: $"pid-{index}");
            emissions.AddRange(pipeline.Process(noisy).Emissions);
            emissions.AddRange(pipeline.Process(noisy).Emissions);
        }

        var urgent = CreateEvent(
            "urgent",
            sourceSequence: null,
            observedMilliseconds: 20,
            urgency: ActivityUrgency.Critical,
            deliveryMode: ActivityDeliveryMode.Debounced,
            debounceKey: null);
        emissions.AddRange(pipeline.Process(urgent).Emissions);
        emissions.AddRange(pipeline.FlushAll());

        var diagnostics = pipeline.GetDiagnostics();
        Assert.AreEqual(12, diagnostics.DuplicateEventCount);
        Assert.AreEqual(13, diagnostics.AcceptedEventCount);
        Assert.AreEqual(1, diagnostics.UrgentInputEventCount);
        Assert.AreEqual(1, emissions.LongCount(emission =>
            emission.Reason == ActivityEmissionReason.UrgentBypass &&
            emission.HighestUrgency == ActivityUrgency.Critical));
        Assert.AreEqual(
            diagnostics.AcceptedEventCount,
            diagnostics.EmittedSourceEventCount);
        Assert.IsLessThanOrEqualTo(3, diagnostics.PeakDeduplicationEntries);
        Assert.IsLessThanOrEqualTo(2, diagnostics.PeakOpenDebounceBuckets);
        Assert.IsLessThanOrEqualTo(2, diagnostics.CurrentOpenDebounceBuckets);
        Assert.AreEqual(10, diagnostics.CapacityPressureFlushCount);
    }

    [TestMethod]
    public void SequenceGapIsObservableWhileUnsequencedSourcesInventNoGap()
    {
        var pipeline = new ActivityEventPipeline();
        var observations = new List<ActivitySequenceObservation>();

        observations.AddRange(pipeline.Process(CreateEvent(
            "sequence-10",
            sourceSequence: 10,
            observedMilliseconds: 0)).SequenceObservations);
        var gap = pipeline.Process(CreateEvent(
            "sequence-12",
            sourceSequence: 12,
            observedMilliseconds: 1));
        observations.AddRange(gap.SequenceObservations);
        var exactDuplicate = pipeline.Process(CreateEvent(
            "sequence-12",
            sourceSequence: 12,
            observedMilliseconds: 1));
        observations.AddRange(exactDuplicate.SequenceObservations);
        var conflict = pipeline.Process(CreateEvent(
            "other-sequence-12",
            sourceSequence: 12,
            observedMilliseconds: 2));
        observations.AddRange(conflict.SequenceObservations);
        var regression = pipeline.Process(CreateEvent(
            "sequence-11",
            sourceSequence: 11,
            observedMilliseconds: 3));
        observations.AddRange(regression.SequenceObservations);

        observations.AddRange(pipeline.Process(CreateEvent(
            "unsequenced-a",
            sourceSequence: null,
            observedMilliseconds: 4,
            sourceKind: ActivitySourceKind.FileSystem,
            sourceInstanceId: "watcher")).SequenceObservations);
        observations.AddRange(pipeline.Process(CreateEvent(
            "unsequenced-b",
            sourceSequence: null,
            observedMilliseconds: 5_000,
            sourceKind: ActivitySourceKind.FileSystem,
            sourceInstanceId: "watcher")).SequenceObservations);

        Assert.AreEqual(ActivityPipelineDisposition.Duplicate, exactDuplicate.Disposition);
        Assert.AreEqual(
            ActivityPipelineDisposition.RejectedSequenceConflict,
            conflict.Disposition);
        Assert.AreEqual(
            ActivityPipelineDisposition.RejectedSequenceRegression,
            regression.Disposition);
        Assert.HasCount(3, observations);
        Assert.AreEqual(ActivitySequenceObservationKind.Gap, observations[0].Kind);
        Assert.AreEqual(11L, observations[0].ExpectedSequence);
        Assert.AreEqual(12L, observations[0].ObservedSequence);
        Assert.AreEqual(ActivitySequenceObservationKind.Conflict, observations[1].Kind);
        Assert.AreEqual(ActivitySequenceObservationKind.Regression, observations[2].Kind);
    }

    [TestMethod]
    public void SameSourceIdentityWithChangedContentIsRejectedAndObserved()
    {
        var pipeline = new ActivityEventPipeline();
        var original = CreateEvent(
            "same-identity",
            sourceSequence: 1,
            observedMilliseconds: 0);
        var changed = original with
        {
            RedactedSummary = "Changed redacted summary",
            PayloadSha256 = Hash("changed"),
        };

        var accepted = pipeline.Process(original);
        var rejected = pipeline.Process(changed);

        Assert.AreEqual(
            ActivityPipelineDisposition.AcceptedImmediate,
            accepted.Disposition);
        Assert.AreEqual(
            ActivityPipelineDisposition.RejectedIdentityConflict,
            rejected.Disposition);
        Assert.HasCount(1, rejected.SequenceObservations);
        Assert.AreEqual(
            ActivitySequenceObservationKind.IdentityConflict,
            rejected.SequenceObservations[0].Kind);
        Assert.AreEqual(1, pipeline.GetDiagnostics().ConflictObservationCount);
    }

    [TestMethod]
    public void LatestSequencedDuplicateRemainsDuplicateAfterDeduplicationEviction()
    {
        var options = ActivityPipelineOptions.Default with
        {
            MaximumDeduplicationEntries = 1,
        };
        var pipeline = new ActivityEventPipeline(options);
        var sequenced = CreateEvent(
            "sequenced",
            sourceSequence: 1,
            observedMilliseconds: 0);
        pipeline.Process(sequenced);
        pipeline.Process(CreateEvent(
            "cache-pressure",
            sourceSequence: null,
            observedMilliseconds: 1,
            sourceKind: ActivitySourceKind.FileSystem,
            sourceInstanceId: "watcher"));

        var duplicate = pipeline.Process(sequenced);
        var changed = pipeline.Process(sequenced with
        {
            RedactedSummary = "Changed after eviction",
            PayloadSha256 = Hash("changed-after-eviction"),
        });

        Assert.AreEqual(ActivityPipelineDisposition.Duplicate, duplicate.Disposition);
        Assert.AreEqual(
            ActivityPipelineDisposition.RejectedIdentityConflict,
            changed.Disposition);
        Assert.HasCount(1, changed.SequenceObservations);
        Assert.AreEqual(
            ActivitySequenceObservationKind.IdentityConflict,
            changed.SequenceObservations[0].Kind);
    }

    [TestMethod]
    public void MaximumSourceSequenceDoesNotWrapARegressionIntoAGap()
    {
        var pipeline = new ActivityEventPipeline();
        pipeline.Process(CreateEvent(
            "maximum",
            sourceSequence: long.MaxValue,
            observedMilliseconds: 0));

        var conflict = pipeline.Process(CreateEvent(
            "other-maximum",
            sourceSequence: long.MaxValue,
            observedMilliseconds: 1));
        var regression = pipeline.Process(CreateEvent(
            "below-maximum",
            sourceSequence: long.MaxValue - 1,
            observedMilliseconds: 2));

        Assert.AreEqual(
            ActivityPipelineDisposition.RejectedSequenceConflict,
            conflict.Disposition);
        Assert.AreEqual(
            ActivitySequenceObservationKind.Conflict,
            conflict.SequenceObservations[0].Kind);
        Assert.IsNull(conflict.SequenceObservations[0].ExpectedSequence);
        Assert.AreEqual(
            ActivityPipelineDisposition.RejectedSequenceRegression,
            regression.Disposition);
        Assert.AreEqual(
            ActivitySequenceObservationKind.Regression,
            regression.SequenceObservations[0].Kind);
        Assert.IsNull(regression.SequenceObservations[0].ExpectedSequence);
        Assert.AreEqual(0, pipeline.GetDiagnostics().GapObservationCount);
    }

    [TestMethod]
    public void ContractNormalizesStableFieldsAndRequiresDebounceKeyForNormalNoise()
    {
        var lowerHash = Hash("payload").ToLowerInvariant();
        var envelope = CreateEvent(
            "normalized",
            sourceSequence: null,
            observedMilliseconds: 0) with
        {
            RedactedSummary = "Line one\r\nLine two",
            PayloadSha256 = lowerHash,
        };

        var normalized = ActivityEventContract.NormalizeAndValidate(envelope, 1);

        Assert.AreEqual("Line one\nLine two", normalized.Envelope.RedactedSummary);
        Assert.AreEqual(lowerHash.ToUpperInvariant(), normalized.Envelope.PayloadSha256);
        Assert.AreEqual(64, normalized.EventIdentitySha256.Length);
        Assert.AreEqual(64, normalized.EnvelopeSha256.Length);

        var invalid = envelope with
        {
            DeliveryMode = ActivityDeliveryMode.Debounced,
            DebounceKey = null,
        };
        var exception = Assert.ThrowsExactly<ActivityEventContractException>(() =>
            ActivityEventContract.NormalizeAndValidate(invalid, 2));
        StringAssert.Contains(exception.Message, "requires a debounce key");
    }

    [TestMethod]
    public void ReplayRejectsInputsAboveConfiguredBound()
    {
        var options = ActivityPipelineOptions.Default with { MaximumReplayEvents = 1 };
        var events = new[]
        {
            CreateEvent("one", sourceSequence: null, observedMilliseconds: 0),
            CreateEvent("two", sourceSequence: null, observedMilliseconds: 1),
        };

        var exception = Assert.ThrowsExactly<ActivityReplayException>(() =>
            ActivityReplay.Run(events, options));

        StringAssert.Contains(exception.Message, "configured maximum is 1");
    }

    private static ActivityEventEnvelope CreateEvent(
        string sourceEventId,
        long? sourceSequence,
        int observedMilliseconds,
        ActivitySourceKind sourceKind = ActivitySourceKind.Herdr,
        string sourceInstanceId = "herdr-pipe",
        ActivityUrgency urgency = ActivityUrgency.Normal,
        ActivityDeliveryMode deliveryMode = ActivityDeliveryMode.Immediate,
        string? debounceKey = null) =>
        new(
            ActivityEventContract.Version,
            sourceEventId,
            sourceKind,
            sourceInstanceId,
            SourceEpoch: "epoch-1",
            sourceSequence,
            ActivityConfidence.Observed,
            urgency,
            deliveryMode,
            EventType: sourceKind == ActivitySourceKind.FileSystem
                ? "file.changed"
                : "agent.activity",
            OccurredUtc: BaseUtc.AddMilliseconds(observedMilliseconds - 1),
            ObservedUtc: BaseUtc.AddMilliseconds(observedMilliseconds),
            CorrelationId,
            debounceKey,
            AgentTerminalId: sourceKind == ActivitySourceKind.Herdr ? "agent-1" : null,
            PaneId: sourceKind == ActivitySourceKind.Herdr ? "pane-1" : null,
            TaskId: "TASK-12",
            ProcessId: sourceKind == ActivitySourceKind.WindowsProcess ? 4242 : null,
            RedactedSummary: $"Redacted event {sourceEventId}",
            PayloadSha256: Hash(sourceEventId));

    private static string Hash(string value) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value)));
}
