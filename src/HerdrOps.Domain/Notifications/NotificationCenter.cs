using System.Security.Cryptography;
using System.Text;
using HerdrOps.Domain.Activity;

namespace HerdrOps.Domain.Notifications;

public sealed record NotificationCenterOptions(
    int MaximumHistory,
    int MaximumRememberedIdentities,
    int MaximumVisibleGroups,
    TimeSpan UrgentGroupSuppressionWindow,
    int MaximumRememberedPresentationGroups = 512)
{
    public static NotificationCenterOptions Default { get; } = new(
        MaximumHistory: 128,
        MaximumRememberedIdentities: 512,
        MaximumVisibleGroups: 32,
        UrgentGroupSuppressionWindow: TimeSpan.FromSeconds(30),
        MaximumRememberedPresentationGroups: 512);

    public NotificationCenterOptions Validate()
    {
        ValidateBound(MaximumHistory, nameof(MaximumHistory));
        ValidateBound(MaximumRememberedIdentities, nameof(MaximumRememberedIdentities));
        ValidateBound(MaximumVisibleGroups, nameof(MaximumVisibleGroups));
        ValidateBound(
            MaximumRememberedPresentationGroups,
            nameof(MaximumRememberedPresentationGroups));
        if (UrgentGroupSuppressionWindow <= TimeSpan.Zero ||
            UrgentGroupSuppressionWindow > TimeSpan.FromHours(1))
        {
            throw new ArgumentOutOfRangeException(
                nameof(UrgentGroupSuppressionWindow),
                "The urgent notification suppression window must be greater than zero and no longer than one hour.");
        }

        return this;
    }

    private static void ValidateBound(int value, string name)
    {
        if (value <= 0 || value > 1_000_000)
        {
            throw new ArgumentOutOfRangeException(
                name,
                "Notification collection bounds must be between 1 and 1,000,000 entries.");
        }
    }
}

public enum NotificationCenterDisposition
{
    Added = 1,
    Grouped = 2,
    Duplicate = 3,
    IgnoredPipelineDisposition = 4,
}

public sealed record NotificationHistoryItem(
    string NotificationId,
    string GroupId,
    string SourceEventId,
    string EventType,
    Guid CorrelationId,
    string? AgentTerminalId,
    string? TaskId,
    string RedactedSummary,
    ActivityUrgency Urgency,
    DateTimeOffset OccurredUtc,
    DateTimeOffset ObservedUtc,
    bool WasPresentedImmediately,
    bool IsAcknowledged,
    DateTimeOffset? AcknowledgedUtc);

public sealed record NotificationGroup(
    string GroupId,
    int EventCount,
    int UnacknowledgedCount,
    ActivityUrgency HighestUrgency,
    DateTimeOffset FirstObservedUtc,
    DateTimeOffset LastObservedUtc,
    NotificationHistoryItem LatestItem);

public sealed record NotificationCenterDiagnostics(
    long AcceptedEventCount,
    long DuplicateEventCount,
    long IgnoredEventCount,
    long ImmediatePresentationCount,
    long SuppressedUrgentPresentationCount,
    long AcknowledgementCount,
    long HistoryEvictionCount,
    long IdentityEvictionCount,
    long PresentationGroupEvictionCount,
    int CurrentHistoryCount,
    int CurrentRememberedIdentityCount,
    int CurrentVisibleGroupCount,
    int CurrentRememberedPresentationGroupCount,
    int PeakHistoryCount,
    int PeakRememberedIdentityCount,
    int PeakVisibleGroupCount,
    int PeakRememberedPresentationGroupCount);

public sealed record NotificationCenterSnapshot(
    IReadOnlyList<NotificationHistoryItem> History,
    IReadOnlyList<NotificationGroup> Groups,
    NotificationCenterDiagnostics Diagnostics);

public sealed record NotificationCenterDecision(
    NotificationCenterDisposition Disposition,
    bool ShowPopup,
    NotificationHistoryItem? Item,
    NotificationGroup? Group);

/// <summary>
/// Maintains bounded notification history from accepted activity events. The center
/// stores only the activity contract's redacted summary and routing identifiers.
/// </summary>
public sealed class NotificationCenter
{
    private readonly object _sync = new();
    private readonly NotificationCenterOptions _options;
    private readonly List<NotificationHistoryItem> _history = [];
    private readonly HashSet<string> _rememberedIdentities = new(StringComparer.Ordinal);
    private readonly Queue<string> _identityOrder = new();
    private readonly Dictionary<string, DateTimeOffset> _lastUrgentPresentationByGroup =
        new(StringComparer.Ordinal);
    private readonly Queue<string> _presentationGroupOrder = new();

    private long _acceptedEventCount;
    private long _duplicateEventCount;
    private long _ignoredEventCount;
    private long _immediatePresentationCount;
    private long _suppressedUrgentPresentationCount;
    private long _acknowledgementCount;
    private long _historyEvictionCount;
    private long _identityEvictionCount;
    private long _presentationGroupEvictionCount;
    private int _peakHistoryCount;
    private int _peakRememberedIdentityCount;
    private int _peakVisibleGroupCount;
    private int _peakRememberedPresentationGroupCount;

    public NotificationCenter(NotificationCenterOptions? options = null)
    {
        _options = (options ?? NotificationCenterOptions.Default).Validate();
    }

    public NotificationCenterDecision Accept(ActivityPipelineStep step)
    {
        ArgumentNullException.ThrowIfNull(step);
        if (step.Disposition is not (
            ActivityPipelineDisposition.AcceptedImmediate or
            ActivityPipelineDisposition.AcceptedBuffered))
        {
            lock (_sync)
            {
                _ignoredEventCount++;
            }

            return new NotificationCenterDecision(
                NotificationCenterDisposition.IgnoredPipelineDisposition,
                ShowPopup: false,
                Item: null,
                Group: null);
        }

        lock (_sync)
        {
            var normalized = step.Event;
            var notificationId = normalized.EventIdentitySha256;
            if (_rememberedIdentities.Contains(notificationId))
            {
                _duplicateEventCount++;
                return new NotificationCenterDecision(
                    NotificationCenterDisposition.Duplicate,
                    ShowPopup: false,
                    Item: null,
                    Group: null);
            }

            var envelope = normalized.Envelope;
            var groupId = CreateGroupId(envelope);
            var existingGroup = _history.Any(item => string.Equals(
                item.GroupId,
                groupId,
                StringComparison.Ordinal));
            var urgent = envelope.Urgency is ActivityUrgency.High or ActivityUrgency.Critical;
            _lastUrgentPresentationByGroup.TryGetValue(groupId, out var lastPresentedUtc);
            var showPopup = urgent &&
                (lastPresentedUtc == default ||
                 envelope.ObservedUtc - lastPresentedUtc >=
                 _options.UrgentGroupSuppressionWindow);
            if (showPopup)
            {
                _immediatePresentationCount++;
                RememberUrgentPresentation(groupId, envelope.ObservedUtc);
            }
            else if (urgent)
            {
                _suppressedUrgentPresentationCount++;
            }

            var item = new NotificationHistoryItem(
                notificationId,
                groupId,
                envelope.SourceEventId,
                envelope.EventType,
                envelope.CorrelationId,
                envelope.AgentTerminalId,
                envelope.TaskId,
                envelope.RedactedSummary,
                envelope.Urgency,
                envelope.OccurredUtc,
                envelope.ObservedUtc,
                showPopup,
                IsAcknowledged: false,
                AcknowledgedUtc: null);
            _history.Insert(0, item);
            _acceptedEventCount++;
            RememberIdentity(notificationId);
            while (_history.Count > _options.MaximumHistory)
            {
                _history.RemoveAt(_history.Count - 1);
                _historyEvictionCount++;
            }

            var groups = BuildGroups();
            _peakHistoryCount = Math.Max(_peakHistoryCount, _history.Count);
            _peakRememberedIdentityCount = Math.Max(
                _peakRememberedIdentityCount,
                _rememberedIdentities.Count);
            _peakVisibleGroupCount = Math.Max(_peakVisibleGroupCount, groups.Count);
            _peakRememberedPresentationGroupCount = Math.Max(
                _peakRememberedPresentationGroupCount,
                _lastUrgentPresentationByGroup.Count);
            var currentGroup = groups.Single(group =>
                string.Equals(group.GroupId, groupId, StringComparison.Ordinal));
            return new NotificationCenterDecision(
                !existingGroup
                    ? NotificationCenterDisposition.Added
                    : NotificationCenterDisposition.Grouped,
                showPopup,
                item,
                currentGroup);
        }
    }

    public bool Acknowledge(string notificationId, DateTimeOffset acknowledgedUtc)
    {
        if (string.IsNullOrWhiteSpace(notificationId))
        {
            return false;
        }

        EnsureUtc(acknowledgedUtc, nameof(acknowledgedUtc));
        lock (_sync)
        {
            var index = _history.FindIndex(item => string.Equals(
                item.NotificationId,
                notificationId,
                StringComparison.Ordinal));
            if (index < 0)
            {
                return false;
            }

            var item = _history[index];
            if (item.IsAcknowledged)
            {
                return true;
            }

            _history[index] = item with
            {
                IsAcknowledged = true,
                AcknowledgedUtc = acknowledgedUtc,
            };
            _acknowledgementCount++;
            return true;
        }
    }

    public int AcknowledgeGroup(string groupId, DateTimeOffset acknowledgedUtc)
    {
        if (string.IsNullOrWhiteSpace(groupId))
        {
            return 0;
        }

        EnsureUtc(acknowledgedUtc, nameof(acknowledgedUtc));
        lock (_sync)
        {
            var acknowledged = 0;
            for (var index = 0; index < _history.Count; index++)
            {
                var item = _history[index];
                if (!string.Equals(item.GroupId, groupId, StringComparison.Ordinal) ||
                    item.IsAcknowledged)
                {
                    continue;
                }

                _history[index] = item with
                {
                    IsAcknowledged = true,
                    AcknowledgedUtc = acknowledgedUtc,
                };
                acknowledged++;
            }

            _acknowledgementCount += acknowledged;
            return acknowledged;
        }
    }

    public NotificationCenterSnapshot Snapshot()
    {
        lock (_sync)
        {
            var history = _history.ToArray();
            var groups = BuildGroups();
            return new NotificationCenterSnapshot(
                history,
                groups,
                new NotificationCenterDiagnostics(
                    _acceptedEventCount,
                    _duplicateEventCount,
                    _ignoredEventCount,
                    _immediatePresentationCount,
                    _suppressedUrgentPresentationCount,
                    _acknowledgementCount,
                    _historyEvictionCount,
                    _identityEvictionCount,
                    _presentationGroupEvictionCount,
                    history.Length,
                    _rememberedIdentities.Count,
                    groups.Count,
                    _lastUrgentPresentationByGroup.Count,
                    _peakHistoryCount,
                    _peakRememberedIdentityCount,
                    _peakVisibleGroupCount,
                    _peakRememberedPresentationGroupCount));
        }
    }

    private IReadOnlyList<NotificationGroup> BuildGroups() =>
        _history
            .GroupBy(item => item.GroupId, StringComparer.Ordinal)
            .Select(group =>
            {
                var items = group.ToArray();
                var latest = items[0];
                return new NotificationGroup(
                    group.Key,
                    items.Length,
                    items.Count(item => !item.IsAcknowledged),
                    items.Max(item => item.Urgency),
                    items.Min(item => item.ObservedUtc),
                    items.Max(item => item.ObservedUtc),
                    latest);
            })
            .OrderByDescending(group => group.LatestItem.ObservedUtc)
            .ThenBy(group => group.GroupId, StringComparer.Ordinal)
            .Take(_options.MaximumVisibleGroups)
            .ToArray();

    private void RememberIdentity(string notificationId)
    {
        _rememberedIdentities.Add(notificationId);
        _identityOrder.Enqueue(notificationId);
        while (_rememberedIdentities.Count > _options.MaximumRememberedIdentities)
        {
            var oldest = _identityOrder.Dequeue();
            if (_rememberedIdentities.Remove(oldest))
            {
                _identityEvictionCount++;
            }
        }
    }

    private void RememberUrgentPresentation(string groupId, DateTimeOffset observedUtc)
    {
        if (_lastUrgentPresentationByGroup.ContainsKey(groupId))
        {
            _lastUrgentPresentationByGroup[groupId] = observedUtc;
            return;
        }

        _lastUrgentPresentationByGroup.Add(groupId, observedUtc);
        _presentationGroupOrder.Enqueue(groupId);
        while (_lastUrgentPresentationByGroup.Count >
               _options.MaximumRememberedPresentationGroups)
        {
            var oldest = _presentationGroupOrder.Dequeue();
            if (_lastUrgentPresentationByGroup.Remove(oldest))
            {
                _presentationGroupEvictionCount++;
            }
        }
    }

    private static string CreateGroupId(ActivityEventEnvelope envelope)
    {
        var correlationFallback = envelope.AgentTerminalId is null && envelope.TaskId is null
            ? envelope.CorrelationId.ToString("D")
            : string.Empty;
        var value = string.Join(
            '\u001f',
            envelope.DebounceKey ?? string.Empty,
            envelope.EventType,
            envelope.AgentTerminalId ?? string.Empty,
            envelope.TaskId ?? string.Empty,
            correlationFallback);
        return Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value)));
    }

    private static void EnsureUtc(DateTimeOffset value, string name)
    {
        if (value.Offset != TimeSpan.Zero)
        {
            throw new ArgumentException("Notification timestamps must use UTC.", name);
        }
    }
}
