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
                group.OrderBy(item => item.SourceId, StringComparer.Ordinal).First().Summary,
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

    private static string WorkstreamLabel(IEnumerable<DailySummarySource> sources)
    {
        var labels = sources
            .Select(item => item.Workstream)
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
