using HerdrOps.Contracts.SelfReport;

namespace HerdrOps.Core;

public interface IHerdrOpsTaskRegistry
{
    bool Contains(string taskId);
}

public sealed class InMemoryHerdrOpsTaskRegistry : IHerdrOpsTaskRegistry
{
    private readonly HashSet<string> _taskIds;

    public InMemoryHerdrOpsTaskRegistry(IEnumerable<string> taskIds)
    {
        ArgumentNullException.ThrowIfNull(taskIds);
        _taskIds = new HashSet<string>(
            taskIds.Select(taskId =>
            {
                ArgumentException.ThrowIfNullOrWhiteSpace(taskId);
                return taskId;
            }),
            StringComparer.Ordinal);
        if (_taskIds.Count == 0)
        {
            throw new ArgumentException(
                "At least one known task identifier is required.",
                nameof(taskIds));
        }
    }

    public bool Contains(string taskId) => _taskIds.Contains(taskId);
}

public sealed record HerdrOpsAcceptedSelfReport(
    long Sequence,
    DateTimeOffset AcceptedUtc,
    string Source,
    Guid CorrelationId,
    string EventSha256,
    HerdrOpsSelfReportSubmission Submission);

public sealed class HerdrOpsSelfReportAcceptanceService
{
    private readonly object _sync = new();
    private readonly IHerdrOpsTaskRegistry _taskRegistry;
    private readonly TimeProvider _timeProvider;
    private readonly int _maximumAcceptedEvents;
    private readonly Action<HerdrOpsAcceptedSelfReport>? _acceptanceCommit;
    private readonly Dictionary<Guid, HerdrOpsAcceptedSelfReport> _acceptedByEventId = [];
    private readonly List<HerdrOpsAcceptedSelfReport> _acceptedEvents = [];
    private long _lastSequence;

    public HerdrOpsSelfReportAcceptanceService(
        IHerdrOpsTaskRegistry taskRegistry,
        TimeProvider? timeProvider = null,
        int maximumAcceptedEvents = 4096,
        long initialSequence = 0,
        IEnumerable<HerdrOpsAcceptedSelfReport>? restoredAcceptedEvents = null,
        Action<HerdrOpsAcceptedSelfReport>? acceptanceCommit = null)
    {
        _taskRegistry = taskRegistry ?? throw new ArgumentNullException(nameof(taskRegistry));
        _timeProvider = timeProvider ?? TimeProvider.System;
        if (maximumAcceptedEvents is < 1 or > 100_000)
        {
            throw new ArgumentOutOfRangeException(
                nameof(maximumAcceptedEvents),
                "The accepted self-report capacity must be from 1 through 100000.");
        }

        ArgumentOutOfRangeException.ThrowIfNegative(initialSequence);
        _maximumAcceptedEvents = maximumAcceptedEvents;
        _acceptanceCommit = acceptanceCommit;
        Restore(restoredAcceptedEvents ?? [], initialSequence);
    }

    public long LastSequence
    {
        get
        {
            lock (_sync)
            {
                return _lastSequence;
            }
        }
    }

    public IReadOnlyList<HerdrOpsAcceptedSelfReport> AcceptedEvents
    {
        get
        {
            lock (_sync)
            {
                return _acceptedEvents.ToArray();
            }
        }
    }

    public HerdrOpsSelfReportResult Accept(
        HerdrOpsSelfReportSubmission submission,
        Guid correlationId)
    {
        ArgumentNullException.ThrowIfNull(submission);
        if (correlationId == Guid.Empty)
        {
            throw new ArgumentException(
                "The self-report correlation identifier cannot be empty.",
                nameof(correlationId));
        }

        try
        {
            HerdrOpsSelfReportJson.ValidateSubmission(submission);
        }
        catch (HerdrOpsSelfReportProtocolException exception)
        {
            return Reject(
                HerdrOpsSelfReportProtocol.ResultCodes.InvalidSchema,
                exception.Message,
                submission,
                correlationId);
        }

        if (!_taskRegistry.Contains(submission.TaskId))
        {
            return Reject(
                HerdrOpsSelfReportProtocol.ResultCodes.UnknownTask,
                $"Task '{submission.TaskId}' is not registered by Core.",
                submission,
                correlationId);
        }

        var eventSha256 = HerdrOpsSelfReportJson.ComputeSha256(submission);
        lock (_sync)
        {
            if (_acceptedByEventId.TryGetValue(submission.EventId, out var existing))
            {
                if (!string.Equals(existing.EventSha256, eventSha256, StringComparison.Ordinal))
                {
                    return Reject(
                        HerdrOpsSelfReportProtocol.ResultCodes.EventIdConflict,
                        $"Event '{submission.EventId:D}' was already accepted with different content.",
                        submission,
                        correlationId);
                }

                return AcceptedResult(
                    existing,
                    correlationId,
                    HerdrOpsSelfReportProtocol.ResultCodes.AcceptedIdempotent,
                    "The identical event was already accepted; the original Core identity is returned.");
            }

            if (_acceptedEvents.Count >= _maximumAcceptedEvents)
            {
                return Reject(
                    HerdrOpsSelfReportProtocol.ResultCodes.CapacityExceeded,
                    "The bounded in-memory self-report acceptance ledger is full.",
                    submission,
                    correlationId);
            }

            var acceptedUtc = _timeProvider.GetUtcNow().ToUniversalTime();
            if (acceptedUtc < submission.OccurredUtc)
            {
                return Reject(
                    HerdrOpsSelfReportProtocol.ResultCodes.InvalidSchema,
                    "The self-report occurrence time cannot be after the Core acceptance time.",
                    submission,
                    correlationId);
            }

            var accepted = new HerdrOpsAcceptedSelfReport(
                checked(_lastSequence + 1),
                acceptedUtc,
                HerdrOpsSelfReportProtocol.CoreSource,
                correlationId,
                eventSha256,
                submission);
            _acceptanceCommit?.Invoke(accepted);
            _acceptedByEventId.Add(submission.EventId, accepted);
            _acceptedEvents.Add(accepted);
            _lastSequence = accepted.Sequence;
            return AcceptedResult(
                accepted,
                correlationId,
                HerdrOpsSelfReportProtocol.ResultCodes.Accepted,
                "The self-report event was accepted by Core.");
        }
    }

    private void Restore(
        IEnumerable<HerdrOpsAcceptedSelfReport> restoredAcceptedEvents,
        long initialSequence)
    {
        ArgumentNullException.ThrowIfNull(restoredAcceptedEvents);
        var restored = restoredAcceptedEvents
            .OrderBy(item => item.Sequence)
            .ToArray();
        if (restored.Length > _maximumAcceptedEvents)
        {
            throw new ArgumentException(
                "The restored self-report ledger exceeds the configured capacity.",
                nameof(restoredAcceptedEvents));
        }

        long priorSequence = 0;
        foreach (var accepted in restored)
        {
            ArgumentNullException.ThrowIfNull(accepted);
            HerdrOpsSelfReportJson.ValidateSubmission(accepted.Submission);
            if (accepted.Sequence <= priorSequence ||
                accepted.AcceptedUtc.Offset != TimeSpan.Zero ||
                accepted.AcceptedUtc < accepted.Submission.OccurredUtc ||
                accepted.CorrelationId == Guid.Empty ||
                !string.Equals(
                    accepted.Source,
                    HerdrOpsSelfReportProtocol.CoreSource,
                    StringComparison.Ordinal) ||
                !string.Equals(
                    accepted.EventSha256,
                    HerdrOpsSelfReportJson.ComputeSha256(accepted.Submission),
                    StringComparison.Ordinal) ||
                !_taskRegistry.Contains(accepted.Submission.TaskId) ||
                !_acceptedByEventId.TryAdd(accepted.Submission.EventId, accepted))
            {
                throw new ArgumentException(
                    "The restored self-report ledger contains invalid identity or ordering.",
                    nameof(restoredAcceptedEvents));
            }

            _acceptedEvents.Add(accepted);
            priorSequence = accepted.Sequence;
        }

        if (restored.Length > 0 && initialSequence != 0 && initialSequence != priorSequence)
        {
            throw new ArgumentException(
                "The restored self-report sequence does not match the requested initial sequence.",
                nameof(initialSequence));
        }

        _lastSequence = restored.Length == 0 ? initialSequence : priorSequence;
    }

    private static HerdrOpsSelfReportResult AcceptedResult(
        HerdrOpsAcceptedSelfReport accepted,
        Guid responseCorrelationId,
        string code,
        string message) => new(
        true,
        code,
        message,
        accepted.Submission.EventId,
        accepted.Submission.EventType,
        accepted.Submission.TaskId,
        responseCorrelationId,
        accepted.Sequence,
        accepted.AcceptedUtc,
        accepted.Source,
        accepted.EventSha256);

    private static HerdrOpsSelfReportResult Reject(
        string code,
        string message,
        HerdrOpsSelfReportSubmission? submission = null,
        Guid? correlationId = null) => new(
        false,
        code,
        message,
        submission?.EventId,
        submission?.EventType,
        submission?.TaskId,
        correlationId,
        null,
        null,
        null,
        null);
}
