using System.Diagnostics.CodeAnalysis;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;

namespace HerdrOps.Domain.Summaries;

public enum DailySummarySourceKind
{
    ActivityEvent = 1,
    Evidence = 2,
}

public sealed record DailySummarySource(
    string SourceId,
    DailySummarySourceKind Kind,
    string SourceHashSha256,
    DateTimeOffset OccurredUtc,
    string Workstream,
    string? AgentId,
    string? TaskId,
    string Category,
    string Summary,
    bool IsAccepted,
    bool IsHighlight,
    string? IssueKey,
    string? RecommendedAction);

public sealed record DailySummarySourceReference(
    string SourceId,
    DailySummarySourceKind Kind,
    string SourceHashSha256);

public sealed record DailySummaryMetric(
    string MetricId,
    int Value,
    IReadOnlyList<string> SourceIds);

public sealed record DailySummaryWorkstream(
    string Workstream,
    int AcceptedSourceCount,
    int ActivityCount,
    int EvidenceCount,
    IReadOnlyList<string> SourceIds);

public sealed record DailySummaryTimelineEntry(
    string SourceId,
    DailySummarySourceKind Kind,
    DateTimeOffset OccurredLocal,
    string Workstream,
    string Category,
    string Summary,
    string SourceHashSha256);

public sealed record DailySummaryHighlight(
    string SourceId,
    string Workstream,
    string Summary,
    IReadOnlyList<string> SourceIds);

public sealed record DailySummaryRepeatedIssue(
    string IssueKey,
    int OccurrenceCount,
    string Workstream,
    string Description,
    IReadOnlyList<string> SourceIds);

public sealed record DailySummaryRecommendedAction(
    string ActionKey,
    string Description,
    IReadOnlyList<string> SourceIds);

public sealed record DailySummarySnapshot(
    int ContractVersion,
    string AggregatorId,
    DateOnly LocalDate,
    string TimeZoneId,
    string SourceSetSha256,
    IReadOnlyList<DailySummarySourceReference> AcceptedSources,
    IReadOnlyList<DailySummaryMetric> Metrics,
    IReadOnlyList<DailySummaryWorkstream> Workstreams,
    IReadOnlyList<DailySummaryHighlight> Highlights,
    IReadOnlyList<DailySummaryRepeatedIssue> RepeatedIssues,
    IReadOnlyList<DailySummaryRecommendedAction> RecommendedActions,
    IReadOnlyList<DailySummaryTimelineEntry> Timeline,
    string ResultSha256);

public static class DailySummaryAggregator
{
    public const int ContractVersion = 1;
    public const string AggregatorId = "HERDROPS-DAILY-SUMMARY-V1";
    public const int MaximumSourceCount = 10_000;
    public const int MaximumIdentifierLength = 256;
    public const int MaximumTextLength = 2048;

    private static readonly string[] FixedMetricIds =
    [
        "accepted-sources",
        "activity-events",
        "evidence-items",
        "workstreams",
        "timeline-items",
        "highlights",
        "repeated-issues",
        "recommended-actions",
    ];

    public static DailySummarySnapshot Aggregate(
        DateOnly localDate,
        TimeZoneInfo timeZone,
        IReadOnlyCollection<DailySummarySource> sources)
    {
        ArgumentNullException.ThrowIfNull(timeZone);
        ArgumentNullException.ThrowIfNull(sources);
        if (sources.Count > MaximumSourceCount)
        {
            throw new DailySummaryAggregationException(
                $"A Daily Summary accepts at most {MaximumSourceCount} source records.");
        }

        var normalized = sources
            .Select(NormalizeSource)
            .OrderBy(item => item.SourceId, StringComparer.Ordinal)
            .ToArray();
        EnsureUnique(normalized.Select(item => item.SourceId), "source ID");

        var selected = normalized
            .Where(item => item.IsAccepted)
            .Where(item => TimeZoneInfo.ConvertTime(item.OccurredUtc, timeZone).Date == localDate.ToDateTime(TimeOnly.MinValue).Date)
            .OrderBy(item => item.OccurredUtc)
            .ThenBy(item => item.SourceId, StringComparer.Ordinal)
            .ToArray();

        var acceptedSources = Array.AsReadOnly(selected
            .Select(item => new DailySummarySourceReference(
                item.SourceId,
                item.Kind,
                item.SourceHashSha256))
            .ToArray());
        var sourceSetSha256 = ComputeSourceSetSha256(acceptedSources);

        var workstreams = Array.AsReadOnly(selected
            .GroupBy(item => item.Workstream, StringComparer.Ordinal)
            .OrderBy(group => group.Key, StringComparer.Ordinal)
            .Select(group => new DailySummaryWorkstream(
                group.Key,
                group.Count(),
                group.Count(item => item.Kind == DailySummarySourceKind.ActivityEvent),
                group.Count(item => item.Kind == DailySummarySourceKind.Evidence),
                SourceIds(group)))
            .ToArray());

        var timeline = Array.AsReadOnly(selected
            .Select(item =>
            {
                var local = TimeZoneInfo.ConvertTime(item.OccurredUtc, timeZone);
                return new DailySummaryTimelineEntry(
                    item.SourceId,
                    item.Kind,
                    local,
                    item.Workstream,
                    item.Category,
                    item.Summary,
                    item.SourceHashSha256);
            })
            .ToArray());

        var highlights = Array.AsReadOnly(selected
            .Where(item => item.IsHighlight)
            .OrderBy(item => item.OccurredUtc)
            .ThenBy(item => item.SourceId, StringComparer.Ordinal)
            .Select(item => new DailySummaryHighlight(
                item.SourceId,
                item.Workstream,
                item.Summary,
                [item.SourceId]))
            .ToArray());

        var repeatedIssues = Array.AsReadOnly(selected
            .Where(item => item.IssueKey is not null)
            .GroupBy(item => item.IssueKey!, StringComparer.Ordinal)
            .Where(group => group.Count() >= 2)
            .OrderBy(group => group.Key, StringComparer.Ordinal)
            .Select(group => new DailySummaryRepeatedIssue(
                group.Key,
                group.Count(),
                WorkstreamLabel(group),
                group.Key,
                SourceIds(group)))
            .ToArray());

        var recommendedActions = Array.AsReadOnly(selected
            .Where(item => item.RecommendedAction is not null)
            .GroupBy(item => item.RecommendedAction!, StringComparer.Ordinal)
            .OrderBy(group => group.Key, StringComparer.Ordinal)
            .Select(group => new DailySummaryRecommendedAction(
                group.Key,
                group.Key,
                SourceIds(group)))
            .ToArray());

        var activityIds = selected
            .Where(item => item.Kind == DailySummarySourceKind.ActivityEvent)
            .Select(item => item.SourceId);
        var evidenceIds = selected
            .Where(item => item.Kind == DailySummarySourceKind.Evidence)
            .Select(item => item.SourceId);
        var metrics = Array.AsReadOnly(
        [
            new DailySummaryMetric("accepted-sources", selected.Length, SourceIds(selected)),
            new DailySummaryMetric("activity-events", activityIds.Count(), activityIds
                .OrderBy(item => item, StringComparer.Ordinal)
                .ToArray()),
            new DailySummaryMetric("evidence-items", evidenceIds.Count(), evidenceIds
                .OrderBy(item => item, StringComparer.Ordinal)
                .ToArray()),
            new DailySummaryMetric("workstreams", workstreams.Count, SourceIds(selected)),
            new DailySummaryMetric("timeline-items", timeline.Count, SourceIds(selected)),
            new DailySummaryMetric("highlights", highlights.Count, SourceIds(highlights
                .SelectMany(item => item.SourceIds))),
            new DailySummaryMetric("repeated-issues", repeatedIssues.Count, SourceIds(repeatedIssues
                .SelectMany(item => item.SourceIds))),
            new DailySummaryMetric("recommended-actions", recommendedActions.Count, SourceIds(recommendedActions
                .SelectMany(item => item.SourceIds))),
        ]);

        var candidate = new DailySummarySnapshot(
            ContractVersion,
            AggregatorId,
            localDate,
            NormalizeTimeZoneId(timeZone.Id),
            sourceSetSha256,
            acceptedSources,
            metrics,
            workstreams,
            highlights,
            repeatedIssues,
            recommendedActions,
            timeline,
            string.Empty);
        return candidate with { ResultSha256 = ComputeResultSha256(candidate) };
    }

    public static bool TryReconcileAcceptedSnapshot(DailySummarySnapshot? snapshot)
    {
        if (snapshot is null)
        {
            return false;
        }

        try
        {
            ReconcileAcceptedSnapshot(snapshot);
            return true;
        }
        catch (DailySummaryAggregationException)
        {
            return false;
        }
    }

    public static DailySummarySnapshot ReconcileAcceptedSnapshot(DailySummarySnapshot snapshot)
    {
        ArgumentNullException.ThrowIfNull(snapshot);

        if (snapshot.ContractVersion != ContractVersion ||
            !string.Equals(snapshot.AggregatorId, AggregatorId, StringComparison.Ordinal) ||
            snapshot.LocalDate == default ||
            !IsCanonicalText(snapshot.TimeZoneId, MaximumIdentifierLength) ||
            !IsCanonicalSha256(snapshot.SourceSetSha256) ||
            !IsCanonicalSha256(snapshot.ResultSha256) ||
            snapshot.AcceptedSources is null ||
            snapshot.AcceptedSources.Count > MaximumSourceCount ||
            snapshot.Metrics is null ||
            snapshot.Workstreams is null ||
            snapshot.Highlights is null ||
            snapshot.RepeatedIssues is null ||
            snapshot.RecommendedActions is null ||
            snapshot.Timeline is null)
        {
            RejectSnapshot("metadata or projection collections are invalid");
        }

        var accepted = new Dictionary<string, DailySummarySourceReference>(StringComparer.Ordinal);
        foreach (var source in snapshot.AcceptedSources)
        {
            if (source is null ||
                !Enum.IsDefined(source.Kind) ||
                !IsCanonicalText(source.SourceId, MaximumIdentifierLength) ||
                !IsCanonicalSha256(source.SourceHashSha256) ||
                !accepted.TryAdd(source.SourceId, source))
            {
                RejectSnapshot("accepted source references are missing, invalid, or duplicated");
            }
        }

        var timelineBySourceId = new Dictionary<string, DailySummaryTimelineEntry>(StringComparer.Ordinal);
        foreach (var entry in snapshot.Timeline)
        {
            if (entry is null ||
                !Enum.IsDefined(entry.Kind) ||
                !IsCanonicalText(entry.SourceId, MaximumIdentifierLength) ||
                !accepted.TryGetValue(entry.SourceId, out var acceptedSource) ||
                entry.Kind != acceptedSource.Kind ||
                !string.Equals(entry.SourceHashSha256, acceptedSource.SourceHashSha256, StringComparison.Ordinal) ||
                entry.OccurredLocal == default ||
                DateOnly.FromDateTime(entry.OccurredLocal.DateTime) != snapshot.LocalDate ||
                !IsCanonicalText(entry.Workstream, MaximumIdentifierLength) ||
                !IsCanonicalText(entry.Category, MaximumIdentifierLength) ||
                !IsCanonicalText(entry.Summary, MaximumTextLength) ||
                !timelineBySourceId.TryAdd(entry.SourceId, entry))
            {
                RejectSnapshot("timeline source references are missing, invalid, or duplicated");
            }
        }

        if (timelineBySourceId.Count != accepted.Count ||
            !snapshot.AcceptedSources
                .Select(item => item.SourceId)
                .SequenceEqual(snapshot.Timeline.Select(item => item.SourceId), StringComparer.Ordinal) ||
            !IsOrderedTimeline(snapshot.Timeline))
        {
            RejectSnapshot("accepted sources and timeline do not reconcile");
        }

        var expectedWorkstreams = snapshot.Timeline
            .GroupBy(item => item.Workstream, StringComparer.Ordinal)
            .OrderBy(group => group.Key, StringComparer.Ordinal)
            .ToArray();
        if (snapshot.Workstreams.Count != expectedWorkstreams.Length)
        {
            RejectSnapshot("workstream cardinality does not reconcile");
        }

        var workstreamSourceIds = new HashSet<string>(StringComparer.Ordinal);
        for (var index = 0; index < expectedWorkstreams.Length; index++)
        {
            var expected = expectedWorkstreams[index];
            var actual = snapshot.Workstreams[index];
            var expectedSourceIds = expected
                .Select(item => item.SourceId)
                .OrderBy(item => item, StringComparer.Ordinal)
                .ToArray();
            var expectedActivityCount = expected.Count(item => item.Kind == DailySummarySourceKind.ActivityEvent);
            var expectedEvidenceCount = expected.Count(item => item.Kind == DailySummarySourceKind.Evidence);
            if (actual is null ||
                !string.Equals(actual.Workstream, expected.Key, StringComparison.Ordinal) ||
                actual.AcceptedSourceCount != expectedSourceIds.Length ||
                actual.ActivityCount != expectedActivityCount ||
                actual.EvidenceCount != expectedEvidenceCount ||
                !HasCanonicalSourceIds(actual.SourceIds, accepted) ||
                !HasExactSourceIds(actual.SourceIds, expectedSourceIds) ||
                expectedSourceIds.Any(sourceId => !workstreamSourceIds.Add(sourceId)))
            {
                RejectSnapshot("workstream values or source references do not reconcile");
            }
        }

        var timelineIndex = snapshot.Timeline
            .Select((entry, index) => (entry.SourceId, Index: index))
            .ToDictionary(item => item.SourceId, item => item.Index, StringComparer.Ordinal);
        var highlightSourceIds = new HashSet<string>(StringComparer.Ordinal);
        var previousHighlightIndex = -1;
        foreach (var highlight in snapshot.Highlights)
        {
            if (highlight is null ||
                !accepted.ContainsKey(highlight.SourceId) ||
                !timelineBySourceId.TryGetValue(highlight.SourceId, out var timelineEntry) ||
                !string.Equals(highlight.Workstream, timelineEntry.Workstream, StringComparison.Ordinal) ||
                !string.Equals(highlight.Summary, timelineEntry.Summary, StringComparison.Ordinal) ||
                !HasCanonicalSourceIds(highlight.SourceIds, accepted, requireNonEmpty: true) ||
                !HasExactSourceIds(highlight.SourceIds, [highlight.SourceId]) ||
                !highlightSourceIds.Add(highlight.SourceId) ||
                timelineIndex[highlight.SourceId] <= previousHighlightIndex)
            {
                RejectSnapshot("highlight values or source references do not reconcile");
            }

            previousHighlightIndex = timelineIndex[highlight.SourceId];
        }

        var issueSourceIds = new HashSet<string>(StringComparer.Ordinal);
        string? previousIssueKey = null;
        foreach (var issue in snapshot.RepeatedIssues)
        {
            if (issue is null ||
                !IsCanonicalText(issue.IssueKey, MaximumIdentifierLength) ||
                issue.OccurrenceCount < 2 ||
                !string.Equals(issue.Description, issue.IssueKey, StringComparison.Ordinal) ||
                !HasCanonicalSourceIds(issue.SourceIds, accepted, requireNonEmpty: true) ||
                !HasExactSourceIds(issue.SourceIds, issue.SourceIds.OrderBy(item => item, StringComparer.Ordinal)) ||
                issue.OccurrenceCount != issue.SourceIds.Count ||
                !string.IsNullOrEmpty(previousIssueKey) &&
                string.CompareOrdinal(previousIssueKey, issue.IssueKey) >= 0 ||
                issue.SourceIds.Any(sourceId => !issueSourceIds.Add(sourceId)) ||
                !string.Equals(
                    issue.Workstream,
                    WorkstreamLabel(issue.SourceIds.Select(sourceId => timelineBySourceId[sourceId].Workstream)),
                    StringComparison.Ordinal))
            {
                RejectSnapshot("repeated issue values or source references do not reconcile");
            }

            previousIssueKey = issue.IssueKey;
        }

        var actionSourceIds = new HashSet<string>(StringComparer.Ordinal);
        string? previousActionKey = null;
        foreach (var action in snapshot.RecommendedActions)
        {
            if (action is null ||
                !IsCanonicalText(action.ActionKey, MaximumTextLength) ||
                !string.Equals(action.Description, action.ActionKey, StringComparison.Ordinal) ||
                !HasCanonicalSourceIds(action.SourceIds, accepted, requireNonEmpty: true) ||
                !HasExactSourceIds(action.SourceIds, action.SourceIds.OrderBy(item => item, StringComparer.Ordinal)) ||
                !string.IsNullOrEmpty(previousActionKey) &&
                string.CompareOrdinal(previousActionKey, action.ActionKey) >= 0 ||
                action.SourceIds.Any(sourceId => !actionSourceIds.Add(sourceId)))
            {
                RejectSnapshot("recommended action values or source references do not reconcile");
            }

            previousActionKey = action.ActionKey;
        }

        var acceptedSourceIds = accepted.Keys.OrderBy(item => item, StringComparer.Ordinal).ToArray();
        var activitySourceIds = accepted.Values
            .Where(item => item.Kind == DailySummarySourceKind.ActivityEvent)
            .Select(item => item.SourceId)
            .OrderBy(item => item, StringComparer.Ordinal)
            .ToArray();
        var evidenceSourceIds = accepted.Values
            .Where(item => item.Kind == DailySummarySourceKind.Evidence)
            .Select(item => item.SourceId)
            .OrderBy(item => item, StringComparer.Ordinal)
            .ToArray();
        var expectedMetrics = new[]
        {
            (MetricId: FixedMetricIds[0], Value: accepted.Count, SourceIds: acceptedSourceIds),
            (MetricId: FixedMetricIds[1], Value: activitySourceIds.Length, SourceIds: activitySourceIds),
            (MetricId: FixedMetricIds[2], Value: evidenceSourceIds.Length, SourceIds: evidenceSourceIds),
            (MetricId: FixedMetricIds[3], Value: snapshot.Workstreams.Count, SourceIds: acceptedSourceIds),
            (MetricId: FixedMetricIds[4], Value: snapshot.Timeline.Count, SourceIds: acceptedSourceIds),
            (MetricId: FixedMetricIds[5], Value: snapshot.Highlights.Count, SourceIds: SourceIds(snapshot.Highlights.SelectMany(item => item.SourceIds))),
            (MetricId: FixedMetricIds[6], Value: snapshot.RepeatedIssues.Count, SourceIds: SourceIds(snapshot.RepeatedIssues.SelectMany(item => item.SourceIds))),
            (MetricId: FixedMetricIds[7], Value: snapshot.RecommendedActions.Count, SourceIds: SourceIds(snapshot.RecommendedActions.SelectMany(item => item.SourceIds))),
        };

        if (snapshot.Metrics.Count != expectedMetrics.Length)
        {
            RejectSnapshot("fixed metric cardinality does not reconcile");
        }

        for (var index = 0; index < expectedMetrics.Length; index++)
        {
            var actual = snapshot.Metrics[index];
            var expected = expectedMetrics[index];
            if (actual is null ||
                !string.Equals(actual.MetricId, expected.MetricId, StringComparison.Ordinal) ||
                actual.Value != expected.Value ||
                !HasCanonicalSourceIds(actual.SourceIds, accepted) ||
                !HasExactSourceIds(actual.SourceIds, expected.SourceIds))
            {
                RejectSnapshot("fixed metric keys, values, or source references do not reconcile");
            }
        }

        var expectedSourceSetSha256 = ComputeSourceSetSha256(snapshot.AcceptedSources);
        if (!string.Equals(snapshot.SourceSetSha256, expectedSourceSetSha256, StringComparison.Ordinal))
        {
            RejectSnapshot("SourceSetSha256 does not match canonical accepted source bytes");
        }

        var expectedResultSha256 = ComputeResultSha256(snapshot);
        if (!string.Equals(snapshot.ResultSha256, expectedResultSha256, StringComparison.Ordinal))
        {
            RejectSnapshot("ResultSha256 does not match canonical accepted snapshot bytes");
        }

        return snapshot;
    }

    public static DailySummarySnapshot Validate(DailySummarySnapshot snapshot)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        if (snapshot.ContractVersion != ContractVersion)
        {
            throw new DailySummaryAggregationException(
                $"Unsupported Daily Summary contract v{snapshot.ContractVersion}.");
        }

        if (!string.Equals(snapshot.AggregatorId, AggregatorId, StringComparison.Ordinal))
        {
            throw new DailySummaryAggregationException(
                "Daily Summary aggregator identity does not match the accepted contract.");
        }

        _ = RequireCanonicalText(snapshot.TimeZoneId, nameof(snapshot.TimeZoneId), MaximumIdentifierLength);
        ValidateSnapshotCollections(snapshot);

        _ = RequireCanonicalSha256(snapshot.SourceSetSha256, nameof(snapshot.SourceSetSha256));
        var expectedSourceSet = ComputeSourceSetSha256(snapshot.AcceptedSources);
        if (!string.Equals(expectedSourceSet, snapshot.SourceSetSha256, StringComparison.Ordinal))
        {
            throw new DailySummaryAggregationException(
                "Daily Summary source-set SHA-256 does not match its accepted sources.");
        }

        _ = RequireCanonicalSha256(snapshot.ResultSha256, nameof(snapshot.ResultSha256));
        var expectedResult = ComputeResultSha256(snapshot);
        if (!string.Equals(expectedResult, snapshot.ResultSha256, StringComparison.Ordinal))
        {
            throw new DailySummaryAggregationException(
                "Daily Summary result SHA-256 does not match its accepted values.");
        }

        return snapshot;
    }

    private static void ValidateSnapshotCollections(DailySummarySnapshot snapshot)
    {
        RequireCollection(snapshot.AcceptedSources, nameof(snapshot.AcceptedSources));
        RequireCollection(snapshot.Metrics, nameof(snapshot.Metrics));
        RequireCollection(snapshot.Workstreams, nameof(snapshot.Workstreams));
        RequireCollection(snapshot.Highlights, nameof(snapshot.Highlights));
        RequireCollection(snapshot.RepeatedIssues, nameof(snapshot.RepeatedIssues));
        RequireCollection(snapshot.RecommendedActions, nameof(snapshot.RecommendedActions));
        RequireCollection(snapshot.Timeline, nameof(snapshot.Timeline));
        if (snapshot.AcceptedSources.Count > MaximumSourceCount)
        {
            throw new DailySummaryAggregationException(
                $"Daily Summary contains {snapshot.AcceptedSources.Count} accepted sources; the maximum is {MaximumSourceCount}.");
        }

        var acceptedById = new Dictionary<string, DailySummarySourceReference>(StringComparer.Ordinal);
        foreach (var source in snapshot.AcceptedSources)
        {
            if (source is null)
            {
                throw new DailySummaryAggregationException(
                    "Daily Summary accepted source collection contains a null record.");
            }

            var sourceId = RequireCanonicalText(source.SourceId, nameof(source.SourceId), MaximumIdentifierLength);
            if (!Enum.IsDefined(source.Kind))
            {
                throw new DailySummaryAggregationException(
                    $"Daily Summary accepted source '{sourceId}' contains an unsupported source kind.");
            }

            var sourceHash = RequireCanonicalSha256(source.SourceHashSha256, nameof(source.SourceHashSha256));
            if (!acceptedById.TryAdd(sourceId, source))
            {
                throw new DailySummaryAggregationException(
                    $"Daily Summary contains a duplicate accepted source ID '{sourceId}'.");
            }

            if (!string.Equals(sourceHash, source.SourceHashSha256, StringComparison.Ordinal))
            {
                throw new DailySummaryAggregationException(
                    $"Daily Summary accepted source '{sourceId}' is not canonically normalized.");
            }
        }

        var timelineById = new Dictionary<string, DailySummaryTimelineEntry>(StringComparer.Ordinal);
        foreach (var entry in snapshot.Timeline)
        {
            if (entry is null)
            {
                throw new DailySummaryAggregationException(
                    "Daily Summary timeline collection contains a null record.");
            }

            var sourceId = RequireCanonicalText(entry.SourceId, nameof(entry.SourceId), MaximumIdentifierLength);
            if (!Enum.IsDefined(entry.Kind))
            {
                throw new DailySummaryAggregationException(
                    $"Daily Summary timeline entry '{sourceId}' contains an unsupported source kind.");
            }

            if (entry.OccurredLocal.Date != snapshot.LocalDate.ToDateTime(TimeOnly.MinValue).Date)
            {
                throw new DailySummaryAggregationException(
                    $"Daily Summary timeline entry '{sourceId}' falls outside local date {snapshot.LocalDate:yyyy-MM-dd}.");
            }

            _ = RequireCanonicalText(entry.Workstream, nameof(entry.Workstream), MaximumIdentifierLength);
            _ = RequireCanonicalText(entry.Category, nameof(entry.Category), MaximumIdentifierLength);
            _ = RequireCanonicalText(entry.Summary, nameof(entry.Summary), MaximumTextLength);
            _ = RequireCanonicalSha256(entry.SourceHashSha256, nameof(entry.SourceHashSha256));
            if (!timelineById.TryAdd(sourceId, entry))
            {
                throw new DailySummaryAggregationException(
                    $"Daily Summary contains a duplicate timeline source ID '{sourceId}'.");
            }
        }

        if (timelineById.Count != acceptedById.Count)
        {
            throw new DailySummaryAggregationException(
                $"Daily Summary timeline count {timelineById.Count} does not match accepted source count {acceptedById.Count}.");
        }

        foreach (var source in snapshot.AcceptedSources)
        {
            if (!timelineById.TryGetValue(source.SourceId, out var entry))
            {
                throw new DailySummaryAggregationException(
                    $"Accepted source '{source.SourceId}' has no timeline reference.");
            }

            if (entry.Kind != source.Kind ||
                !string.Equals(entry.SourceHashSha256, source.SourceHashSha256, StringComparison.Ordinal))
            {
                throw new DailySummaryAggregationException(
                    $"Timeline reference '{source.SourceId}' does not match its accepted source kind/hash.");
            }
        }

        foreach (var entry in snapshot.Timeline)
        {
            if (!acceptedById.ContainsKey(entry.SourceId))
            {
                throw new DailySummaryAggregationException(
                    $"Timeline source reference '{entry.SourceId}' does not resolve to an accepted source.");
            }
        }

        var acceptedIds = snapshot.AcceptedSources.Select(item => item.SourceId).ToArray();
        var timelineIds = snapshot.Timeline.Select(item => item.SourceId).ToArray();
        EnsureSequenceEqual(acceptedIds, timelineIds, "accepted source and timeline order");
        EnsureSequenceEqual(
            timelineIds,
            snapshot.Timeline
                .OrderBy(item => item.OccurredLocal)
                .ThenBy(item => item.SourceId, StringComparer.Ordinal)
                .Select(item => item.SourceId),
            "timeline");

        var metrics = ValidateMetrics(snapshot.Metrics, acceptedById);
        ValidateWorkstreams(snapshot.Workstreams, acceptedById, snapshot.Timeline);
        ValidateHighlights(snapshot.Highlights, acceptedById, timelineById, timelineIds);
        ValidateRepeatedIssues(snapshot.RepeatedIssues, acceptedById, timelineById);
        ValidateRecommendedActions(snapshot.RecommendedActions, acceptedById);

        var expectedActivityIds = acceptedById.Values
            .Where(item => item.Kind == DailySummarySourceKind.ActivityEvent)
            .Select(item => item.SourceId)
            .OrderBy(item => item, StringComparer.Ordinal)
            .ToArray();
        var expectedEvidenceIds = acceptedById.Values
            .Where(item => item.Kind == DailySummarySourceKind.Evidence)
            .Select(item => item.SourceId)
            .OrderBy(item => item, StringComparer.Ordinal)
            .ToArray();
        EnsureMetric(metrics, "accepted-sources", acceptedById.Count, acceptedIds);
        EnsureMetric(metrics, "activity-events", expectedActivityIds.Length, expectedActivityIds);
        EnsureMetric(metrics, "evidence-items", expectedEvidenceIds.Length, expectedEvidenceIds);
        EnsureMetric(metrics, "workstreams", snapshot.Workstreams.Count, acceptedIds);
        EnsureMetric(metrics, "timeline-items", snapshot.Timeline.Count, acceptedIds);
        EnsureMetric(
            metrics,
            "highlights",
            snapshot.Highlights.Count,
            snapshot.Highlights.SelectMany(item => item.SourceIds));
        EnsureMetric(
            metrics,
            "repeated-issues",
            snapshot.RepeatedIssues.Count,
            snapshot.RepeatedIssues.SelectMany(item => item.SourceIds));
        EnsureMetric(
            metrics,
            "recommended-actions",
            snapshot.RecommendedActions.Count,
            snapshot.RecommendedActions.SelectMany(item => item.SourceIds));
    }

    private static IReadOnlyDictionary<string, (DailySummaryMetric Metric, string[] SourceIds)> ValidateMetrics(
        IReadOnlyList<DailySummaryMetric> metrics,
        IReadOnlyDictionary<string, DailySummarySourceReference> acceptedById)
    {
        if (metrics.Count != FixedMetricIds.Length)
        {
            throw new DailySummaryAggregationException(
                $"Daily Summary must contain exactly {FixedMetricIds.Length} metrics; found {metrics.Count}.");
        }

        var normalized = new Dictionary<string, (DailySummaryMetric Metric, string[] SourceIds)>(StringComparer.Ordinal);
        var seen = new HashSet<string>(StringComparer.Ordinal);
        for (var index = 0; index < metrics.Count; index++)
        {
            var metric = metrics[index];
            if (metric is null)
            {
                throw new DailySummaryAggregationException(
                    $"Daily Summary metric index {index} is null.");
            }

            var metricId = RequireCanonicalText(metric.MetricId, nameof(metric.MetricId), MaximumIdentifierLength);
            if (!seen.Add(metricId))
            {
                throw new DailySummaryAggregationException(
                    $"Daily Summary contains a duplicate metric ID '{metricId}'.");
            }

            if (!string.Equals(metricId, FixedMetricIds[index], StringComparison.Ordinal))
            {
                throw new DailySummaryAggregationException(
                    $"Daily Summary metric '{metricId}' is not in canonical position {index}.");
            }

            var sourceIds = ValidateSourceIds(metric.SourceIds, $"metric '{metricId}'", acceptedById);
            normalized.Add(metricId, (metric, sourceIds));
        }

        return normalized;
    }

    private static void ValidateWorkstreams(
        IReadOnlyList<DailySummaryWorkstream> workstreams,
        IReadOnlyDictionary<string, DailySummarySourceReference> acceptedById,
        IReadOnlyList<DailySummaryTimelineEntry> timeline)
    {
        var expectedNames = timeline
            .Select(item => item.Workstream)
            .Distinct(StringComparer.Ordinal)
            .OrderBy(item => item, StringComparer.Ordinal)
            .ToArray();
        if (workstreams.Count != expectedNames.Length)
        {
            throw new DailySummaryAggregationException(
                $"Daily Summary workstream count {workstreams.Count} does not match timeline workstream count {expectedNames.Length}.");
        }

        var seen = new HashSet<string>(StringComparer.Ordinal);
        for (var index = 0; index < workstreams.Count; index++)
        {
            var workstream = workstreams[index];
            if (workstream is null)
            {
                throw new DailySummaryAggregationException(
                    $"Daily Summary workstream index {index} is null.");
            }

            var name = RequireCanonicalText(workstream.Workstream, nameof(workstream.Workstream), MaximumIdentifierLength);
            if (!seen.Add(name))
            {
                throw new DailySummaryAggregationException(
                    $"Daily Summary contains a duplicate workstream ID '{name}'.");
            }

            if (!string.Equals(name, expectedNames[index], StringComparison.Ordinal))
            {
                throw new DailySummaryAggregationException(
                    $"Daily Summary workstream '{name}' is not in canonical position {index}.");
            }

            var sourceIds = ValidateSourceIds(
                workstream.SourceIds,
                $"workstream '{name}'",
                acceptedById);
            var expectedIds = timeline
                .Where(item => string.Equals(item.Workstream, name, StringComparison.Ordinal))
                .Select(item => item.SourceId)
                .OrderBy(item => item, StringComparer.Ordinal)
                .ToArray();
            EnsureIdsEqual(sourceIds, expectedIds, $"workstream '{name}' source set");

            EnsureValue(
                workstream.AcceptedSourceCount,
                expectedIds.Length,
                $"workstream '{name}' accepted source count");
            EnsureValue(
                workstream.ActivityCount,
                expectedIds.Count(item => acceptedById[item].Kind == DailySummarySourceKind.ActivityEvent),
                $"workstream '{name}' activity count");
            EnsureValue(
                workstream.EvidenceCount,
                expectedIds.Count(item => acceptedById[item].Kind == DailySummarySourceKind.Evidence),
                $"workstream '{name}' evidence count");
        }
    }

    private static void ValidateHighlights(
        IReadOnlyList<DailySummaryHighlight> highlights,
        IReadOnlyDictionary<string, DailySummarySourceReference> acceptedById,
        IReadOnlyDictionary<string, DailySummaryTimelineEntry> timelineById,
        IReadOnlyList<string> timelineIds)
    {
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var highlight in highlights)
        {
            if (highlight is null)
            {
                throw new DailySummaryAggregationException(
                    "Daily Summary highlight collection contains a null record.");
            }

            var sourceId = RequireCanonicalText(highlight.SourceId, nameof(highlight.SourceId), MaximumIdentifierLength);
            if (!seen.Add(sourceId))
            {
                throw new DailySummaryAggregationException(
                    $"Daily Summary contains a duplicate highlight source ID '{sourceId}'.");
            }

            if (!timelineById.ContainsKey(sourceId))
            {
                throw new DailySummaryAggregationException(
                    $"Highlight '{sourceId}' does not resolve to an accepted timeline source.");
            }

            var sourceIds = ValidateSourceIds(highlight.SourceIds, $"highlight '{sourceId}'", acceptedById);
            if (sourceIds.Length != 1 || !string.Equals(sourceIds[0], sourceId, StringComparison.Ordinal))
            {
                throw new DailySummaryAggregationException(
                    $"Highlight '{sourceId}' must reference itself exactly once.");
            }

            var timeline = timelineById[sourceId];
            if (!string.Equals(highlight.Workstream, timeline.Workstream, StringComparison.Ordinal) ||
                !string.Equals(highlight.Summary, timeline.Summary, StringComparison.Ordinal))
            {
                throw new DailySummaryAggregationException(
                    $"Highlight '{sourceId}' does not match its timeline workstream/summary.");
            }

            _ = RequireCanonicalText(highlight.Workstream, nameof(highlight.Workstream), MaximumIdentifierLength);
            _ = RequireCanonicalText(highlight.Summary, nameof(highlight.Summary), MaximumTextLength);
        }

        EnsureSequenceEqual(
            highlights.Select(item => item.SourceId),
            timelineIds.Where(seen.Contains),
            "highlight");
    }

    private static void ValidateRepeatedIssues(
        IReadOnlyList<DailySummaryRepeatedIssue> issues,
        IReadOnlyDictionary<string, DailySummarySourceReference> acceptedById,
        IReadOnlyDictionary<string, DailySummaryTimelineEntry> timelineById)
    {
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var keys = new List<string>(issues.Count);
        foreach (var issue in issues)
        {
            if (issue is null)
            {
                throw new DailySummaryAggregationException(
                    "Daily Summary repeated-issue collection contains a null record.");
            }

            var key = RequireCanonicalText(issue.IssueKey, nameof(issue.IssueKey), MaximumIdentifierLength);
            if (!seen.Add(key))
            {
                throw new DailySummaryAggregationException(
                    $"Daily Summary contains a duplicate repeated-issue ID '{key}'.");
            }

            var sourceIds = ValidateSourceIds(
                issue.SourceIds,
                $"repeated issue '{key}'",
                acceptedById);
            if (sourceIds.Length == 0)
            {
                throw new DailySummaryAggregationException(
                    $"Repeated issue '{key}' must reference at least one source.");
            }

            EnsureValue(issue.OccurrenceCount, sourceIds.Length, $"repeated issue '{key}' occurrence count");
            EnsureReferenceWorkstream(
                issue.Workstream,
                sourceIds,
                timelineById,
                $"repeated issue '{key}'");
            var expectedDescription = timelineById[sourceIds[0]].Summary;
            if (!string.Equals(issue.Description, expectedDescription, StringComparison.Ordinal))
            {
                throw new DailySummaryAggregationException(
                    $"Repeated issue '{key}' description does not match its canonical first source summary.");
            }

            _ = RequireCanonicalText(issue.Workstream, nameof(issue.Workstream), MaximumIdentifierLength);
            _ = RequireCanonicalText(issue.Description, nameof(issue.Description), MaximumTextLength);
            keys.Add(key);
        }

        EnsureSequenceEqual(keys, keys.OrderBy(item => item, StringComparer.Ordinal), "repeated issue");
    }

    private static void ValidateRecommendedActions(
        IReadOnlyList<DailySummaryRecommendedAction> actions,
        IReadOnlyDictionary<string, DailySummarySourceReference> acceptedById)
    {
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var keys = new List<string>(actions.Count);
        foreach (var action in actions)
        {
            if (action is null)
            {
                throw new DailySummaryAggregationException(
                    "Daily Summary recommended-action collection contains a null record.");
            }

            var key = RequireCanonicalText(action.ActionKey, nameof(action.ActionKey), MaximumIdentifierLength);
            if (!seen.Add(key))
            {
                throw new DailySummaryAggregationException(
                    $"Daily Summary contains a duplicate recommended-action ID '{key}'.");
            }

            var sourceIds = ValidateSourceIds(action.SourceIds, $"recommended action '{key}'", acceptedById);
            if (sourceIds.Length == 0)
            {
                throw new DailySummaryAggregationException(
                    $"Recommended action '{key}' must reference at least one source.");
            }
            if (!string.Equals(action.Description, key, StringComparison.Ordinal))
            {
                throw new DailySummaryAggregationException(
                    $"Recommended action '{key}' description does not match its canonical action ID.");
            }

            _ = RequireCanonicalText(action.Description, nameof(action.Description), MaximumTextLength);
            keys.Add(key);
        }

        EnsureSequenceEqual(keys, keys.OrderBy(item => item, StringComparer.Ordinal), "recommended action");
    }

    private static string[] ValidateSourceIds(
        IReadOnlyList<string> ids,
        string label,
        IReadOnlyDictionary<string, DailySummarySourceReference> acceptedById)
    {
        if (ids is null)
        {
            throw new DailySummaryAggregationException(
                $"Daily Summary {label} source reference collection is null.");
        }

        var normalized = new string[ids.Count];
        var seen = new HashSet<string>(StringComparer.Ordinal);
        for (var index = 0; index < ids.Count; index++)
        {
            var id = RequireCanonicalText(ids[index], $"{label} source ID", MaximumIdentifierLength);
            if (!seen.Add(id))
            {
                throw new DailySummaryAggregationException(
                    $"Daily Summary {label} contains a duplicate source reference ID '{id}'.");
            }

            if (!acceptedById.ContainsKey(id))
            {
                throw new DailySummaryAggregationException(
                    $"Daily Summary {label} source reference '{id}' does not resolve exactly once to an accepted source.");
            }

            normalized[index] = id;
        }

        EnsureSequenceEqual(
            normalized,
            normalized.OrderBy(item => item, StringComparer.Ordinal),
            $"{label} source references");
        return normalized;
    }

    private static void EnsureReferenceWorkstream(
        string workstream,
        IReadOnlyList<string> sourceIds,
        IReadOnlyDictionary<string, DailySummaryTimelineEntry> timelineById,
        string label)
    {
        var expected = sourceIds
            .Select(item => timelineById[item].Workstream)
            .Distinct(StringComparer.Ordinal)
            .OrderBy(item => item, StringComparer.Ordinal)
            .ToArray();
        var expectedLabel = expected.Length == 1 ? expected[0] : "Multiple";
        var normalized = RequireCanonicalText(workstream, $"{label} workstream", MaximumIdentifierLength);
        if (!string.Equals(normalized, expectedLabel, StringComparison.Ordinal))
        {
            throw new DailySummaryAggregationException(
                $"{label} workstream '{normalized}' does not reconcile with its source set.");
        }
    }

    private static void EnsureMetric(
        IReadOnlyDictionary<string, (DailySummaryMetric Metric, string[] SourceIds)> metrics,
        string metricId,
        int expectedValue,
        IEnumerable<string> expectedSourceIds)
    {
        var metric = metrics[metricId];
        EnsureValue(metric.Metric.Value, expectedValue, $"metric '{metricId}' value");
        EnsureIdsEqual(
            metric.SourceIds,
            expectedSourceIds.OrderBy(item => item, StringComparer.Ordinal),
            $"metric '{metricId}' source set");
    }

    private static void EnsureValue(int actual, int expected, string label)
    {
        if (actual != expected)
        {
            throw new DailySummaryAggregationException(
                $"Daily Summary {label} {actual} does not reconcile with expected value {expected}.");
        }
    }

    private static void EnsureIdsEqual(
        IReadOnlyList<string> actual,
        IEnumerable<string> expected,
        string label) =>
        EnsureSequenceEqual(actual, expected, label);

    private static void EnsureSequenceEqual(
        IEnumerable<string> actual,
        IEnumerable<string> expected,
        string label)
    {
        var actualArray = actual.ToArray();
        var expectedArray = expected.ToArray();
        if (!actualArray.SequenceEqual(expectedArray, StringComparer.Ordinal))
        {
            throw new DailySummaryAggregationException(
                $"Daily Summary {label} is not canonical or does not reconcile.");
        }
    }

    private static void RequireCollection<T>(IReadOnlyList<T> collection, string name)
    {
        if (collection is null)
        {
            throw new DailySummaryAggregationException(
                $"Daily Summary collection {name} is null.");
        }
    }

    private static string RequireCanonicalText(string? value, string name, int maximumLength)
    {
        var normalized = NormalizeText(value!, name, maximumLength);
        if (!string.Equals(value, normalized, StringComparison.Ordinal))
        {
            throw new DailySummaryAggregationException(
                $"Daily Summary field {name} is not in canonical normalized form.");
        }

        return normalized;
    }

    private static string RequireCanonicalSha256(string? value, string name)
    {
        var normalized = NormalizeSha256(value!, name);
        if (!string.Equals(value, normalized, StringComparison.Ordinal))
        {
            throw new DailySummaryAggregationException(
                $"Daily Summary field {name} must use uppercase canonical SHA-256.");
        }

        return normalized;
    }

    private static DailySummarySource NormalizeSource(DailySummarySource source)
    {
        ArgumentNullException.ThrowIfNull(source);
        if (!Enum.IsDefined(source.Kind))
        {
            throw new DailySummaryAggregationException(
                "A Daily Summary source contains an unsupported source kind.");
        }

        if (source.OccurredUtc.Offset != TimeSpan.Zero)
        {
            throw new DailySummaryAggregationException(
                "Daily Summary source timestamps must be UTC.");
        }

        return source with
        {
            SourceId = NormalizeText(source.SourceId, nameof(source.SourceId), MaximumIdentifierLength),
            SourceHashSha256 = NormalizeSha256(source.SourceHashSha256, nameof(source.SourceHashSha256)),
            Workstream = NormalizeText(source.Workstream, nameof(source.Workstream), MaximumIdentifierLength),
            AgentId = NormalizeOptionalText(source.AgentId, nameof(source.AgentId), MaximumIdentifierLength),
            TaskId = NormalizeOptionalText(source.TaskId, nameof(source.TaskId), MaximumIdentifierLength),
            Category = NormalizeText(source.Category, nameof(source.Category), MaximumIdentifierLength),
            Summary = NormalizeText(source.Summary, nameof(source.Summary), MaximumTextLength),
            IssueKey = NormalizeOptionalText(source.IssueKey, nameof(source.IssueKey), MaximumIdentifierLength),
            RecommendedAction = NormalizeOptionalText(
                source.RecommendedAction,
                nameof(source.RecommendedAction),
                MaximumTextLength),
        };
    }

    private static string WorkstreamLabel(IEnumerable<DailySummarySource> sources) =>
        WorkstreamLabel(sources.Select(item => item.Workstream));

    private static string WorkstreamLabel(IEnumerable<string> workstreams)
    {
        var labels = workstreams
            .Distinct(StringComparer.Ordinal)
            .OrderBy(item => item, StringComparer.Ordinal)
            .ToArray();
        return labels.Length == 1 ? labels[0] : "Multiple";
    }

    private static string[] SourceIds(IEnumerable<DailySummarySource> sources) =>
        sources
            .Select(item => item.SourceId)
            .OrderBy(item => item, StringComparer.Ordinal)
            .ToArray();

    private static string[] SourceIds(IEnumerable<string> sourceIds) =>
        sourceIds
            .OrderBy(item => item, StringComparer.Ordinal)
            .ToArray();

    private static string[] SourceIds(IEnumerable<DailySummarySourceReference> sources) =>
        sources
            .Select(item => item.SourceId)
            .OrderBy(item => item, StringComparer.Ordinal)
            .ToArray();

    private static string[] SourceIds(IEnumerable<DailySummaryHighlight> highlights) =>
        highlights
            .SelectMany(item => item.SourceIds)
            .OrderBy(item => item, StringComparer.Ordinal)
            .ToArray();

    private static string[] SourceIds(IEnumerable<DailySummaryRepeatedIssue> issues) =>
        issues
            .SelectMany(item => item.SourceIds)
            .OrderBy(item => item, StringComparer.Ordinal)
            .ToArray();

    private static string[] SourceIds(IEnumerable<DailySummaryRecommendedAction> actions) =>
        actions
            .SelectMany(item => item.SourceIds)
            .OrderBy(item => item, StringComparer.Ordinal)
            .ToArray();

    private static bool HasCanonicalSourceIds(
        IReadOnlyList<string>? sourceIds,
        IReadOnlyDictionary<string, DailySummarySourceReference> accepted,
        bool requireNonEmpty = false)
    {
        if (sourceIds is null || (requireNonEmpty && sourceIds.Count == 0))
        {
            return false;
        }

        var seen = new HashSet<string>(StringComparer.Ordinal);
        return sourceIds.All(sourceId =>
            IsCanonicalText(sourceId, MaximumIdentifierLength) &&
            accepted.ContainsKey(sourceId) &&
            seen.Add(sourceId));
    }

    private static bool HasExactSourceIds(
        IReadOnlyList<string>? actual,
        IEnumerable<string> expected)
    {
        if (actual is null)
        {
            return false;
        }

        var expectedArray = expected.ToArray();
        return actual.Count == expectedArray.Length &&
               actual.SequenceEqual(expectedArray, StringComparer.Ordinal);
    }

    private static bool IsOrderedTimeline(IReadOnlyList<DailySummaryTimelineEntry> timeline)
    {
        for (var index = 1; index < timeline.Count; index++)
        {
            var previous = timeline[index - 1];
            var current = timeline[index];
            var occurrenceComparison = previous.OccurredLocal.CompareTo(current.OccurredLocal);
            if (occurrenceComparison > 0 ||
                occurrenceComparison == 0 && string.CompareOrdinal(previous.SourceId, current.SourceId) >= 0)
            {
                return false;
            }
        }

        return true;
    }

    private static void EnsureUnique(IEnumerable<string> values, string label)
    {
        var duplicate = values
            .GroupBy(item => item, StringComparer.Ordinal)
            .FirstOrDefault(group => group.Count() > 1);
        if (duplicate is not null)
        {
            throw new DailySummaryAggregationException(
                $"Daily Summary contains a duplicate {label} '{duplicate.Key}'.");
        }
    }

    private static string NormalizeText(string value, string name, int maximumLength)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            throw new DailySummaryAggregationException(
                $"Daily Summary field {name} must be non-blank.");
        }

        var normalized = value.Normalize(NormalizationForm.FormC);
        if (!string.Equals(normalized, normalized.Trim(), StringComparison.Ordinal) ||
            normalized.Length > maximumLength ||
            normalized.Any(char.IsControl))
        {
            throw new DailySummaryAggregationException(
                $"Daily Summary field {name} must be unpadded, at most {maximumLength} characters, and contain no control characters.");
        }

        return normalized;
    }

    private static string? NormalizeOptionalText(
        string? value,
        string name,
        int maximumLength) =>
        value is null ? null : NormalizeText(value, name, maximumLength);

    private static string NormalizeSha256(string value, string name)
    {
        if (value is null || value.Length != 64 || !value.All(IsHexCharacter))
        {
            throw new DailySummaryAggregationException(
                $"Daily Summary field {name} must contain exactly 64 hexadecimal characters.");
        }

        return value.ToUpperInvariant();
    }

    private static string NormalizeTimeZoneId(string value) =>
        NormalizeText(value, nameof(TimeZoneInfo.Id), MaximumIdentifierLength);

    private static bool IsCanonicalText(string? value, int maximumLength) =>
        !string.IsNullOrWhiteSpace(value) &&
        value == value.Trim() &&
        value == value.Normalize(NormalizationForm.FormC) &&
        value.Length <= maximumLength &&
        value.All(character => !char.IsControl(character));

    private static bool IsCanonicalSha256(string? value) =>
        value is not null &&
        value.Length == 64 &&
        value.All(IsHexCharacter) &&
        value == value.ToUpperInvariant();

    [DoesNotReturn]
    private static void RejectSnapshot(string reason) =>
        throw new DailySummaryAggregationException(
            $"Daily Summary snapshot reconciliation failed: {reason}.");

    private static string ComputeSourceSetSha256(
        IReadOnlyList<DailySummarySourceReference> sources)
    {
        using var canonical = new CanonicalTextWriter("HerdrOps.DailySummarySourceSet.v1");
        canonical.Write(sources.Count);
        foreach (var source in sources.OrderBy(item => item.SourceId, StringComparer.Ordinal))
        {
            canonical.Write(source.SourceId);
            canonical.Write((int)source.Kind);
            canonical.Write(source.SourceHashSha256);
        }

        return canonical.Finish();
    }

    private static string ComputeResultSha256(DailySummarySnapshot snapshot)
    {
        using var canonical = new CanonicalTextWriter("HerdrOps.DailySummaryResult.v1");
        canonical.Write(snapshot.ContractVersion);
        canonical.Write(snapshot.AggregatorId);
        canonical.Write(snapshot.LocalDate.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture));
        canonical.Write(snapshot.TimeZoneId);
        canonical.Write(snapshot.SourceSetSha256);
        canonical.Write(snapshot.AcceptedSources.Count);
        foreach (var source in snapshot.AcceptedSources)
        {
            canonical.Write(source.SourceId);
            canonical.Write((int)source.Kind);
            canonical.Write(source.SourceHashSha256);
        }

        canonical.Write(snapshot.Metrics.Count);
        foreach (var metric in snapshot.Metrics)
        {
            canonical.Write(metric.MetricId);
            canonical.Write(metric.Value);
            WriteIds(canonical, metric.SourceIds);
        }

        canonical.Write(snapshot.Workstreams.Count);
        foreach (var workstream in snapshot.Workstreams)
        {
            canonical.Write(workstream.Workstream);
            canonical.Write(workstream.AcceptedSourceCount);
            canonical.Write(workstream.ActivityCount);
            canonical.Write(workstream.EvidenceCount);
            WriteIds(canonical, workstream.SourceIds);
        }

        canonical.Write(snapshot.Highlights.Count);
        foreach (var highlight in snapshot.Highlights)
        {
            canonical.Write(highlight.SourceId);
            canonical.Write(highlight.Workstream);
            canonical.Write(highlight.Summary);
            WriteIds(canonical, highlight.SourceIds);
        }

        canonical.Write(snapshot.RepeatedIssues.Count);
        foreach (var issue in snapshot.RepeatedIssues)
        {
            canonical.Write(issue.IssueKey);
            canonical.Write(issue.OccurrenceCount);
            canonical.Write(issue.Workstream);
            canonical.Write(issue.Description);
            WriteIds(canonical, issue.SourceIds);
        }

        canonical.Write(snapshot.RecommendedActions.Count);
        foreach (var action in snapshot.RecommendedActions)
        {
            canonical.Write(action.ActionKey);
            canonical.Write(action.Description);
            WriteIds(canonical, action.SourceIds);
        }

        canonical.Write(snapshot.Timeline.Count);
        foreach (var entry in snapshot.Timeline)
        {
            canonical.Write(entry.SourceId);
            canonical.Write((int)entry.Kind);
            canonical.Write(entry.OccurredLocal);
            canonical.Write(entry.Workstream);
            canonical.Write(entry.Category);
            canonical.Write(entry.Summary);
            canonical.Write(entry.SourceHashSha256);
        }

        return canonical.Finish();
    }

    private static void WriteIds(CanonicalTextWriter canonical, IEnumerable<string> ids)
    {
        var ordered = ids.OrderBy(item => item, StringComparer.Ordinal).ToArray();
        canonical.Write(ordered.Length);
        foreach (var id in ordered)
        {
            canonical.Write(id);
        }
    }

    private static bool IsHexCharacter(char value) =>
        value is >= '0' and <= '9' or >= 'A' and <= 'F' or >= 'a' and <= 'f';

    private sealed class CanonicalTextWriter : IDisposable
    {
        private readonly StringBuilder _builder = new();
        private bool _finished;

        public CanonicalTextWriter(string domain) => Write(domain);

        public void Write(string? value)
        {
            if (value is null)
            {
                _builder.Append("-1:");
            }
            else
            {
                _builder.Append(value.Length.ToString(CultureInfo.InvariantCulture));
                _builder.Append(':');
                _builder.Append(value);
            }

            _builder.Append('|');
        }

        public void Write(int value) => Write(value.ToString(CultureInfo.InvariantCulture));

        public void Write(DateTimeOffset value) => Write(value.ToString("O", CultureInfo.InvariantCulture));

        public string Finish()
        {
            ObjectDisposedException.ThrowIf(_finished, this);
            _finished = true;
            return Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(_builder.ToString())));
        }

        public void Dispose() => _finished = true;
    }
}

public sealed class DailySummaryAggregationException : ArgumentException
{
    public DailySummaryAggregationException(string message)
        : base(message)
    {
    }
}
