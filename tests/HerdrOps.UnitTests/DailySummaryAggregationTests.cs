using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using HerdrOps.Domain.Summaries;

namespace HerdrOps.UnitTests;

[TestClass]
public sealed class DailySummaryAggregationTests
{
    private static readonly JsonSerializerOptions FixtureJsonOptions = new()
    {
        PropertyNameCaseInsensitive = true,
    };

    [TestMethod]
    public void FixtureAggregatesAcceptedSourcesAndLinksEveryMetricToSources()
    {
        var fixture = ReadFixture();
        foreach (var source in fixture.Sources)
        {
            Assert.AreEqual(
                CanonicalSourceHash(source),
                source.SourceHashSha256,
                $"Fixture source identity is not derived from its canonical synthetic bytes: {source.SourceId}");
        }

        var snapshot = DailySummaryAggregator.Aggregate(
            fixture.LocalDate,
            CreateFixedOffsetTimeZone(fixture.TimeZoneOffsetMinutes),
            fixture.Sources);

        Assert.AreEqual(fixture.Expected.AcceptedSourceCount, Metric(snapshot, "accepted-sources").Value);
        Assert.AreEqual(fixture.Expected.ActivityCount, Metric(snapshot, "activity-events").Value);
        Assert.AreEqual(fixture.Expected.EvidenceCount, Metric(snapshot, "evidence-items").Value);
        Assert.AreEqual(fixture.Expected.WorkstreamCount, Metric(snapshot, "workstreams").Value);
        Assert.AreEqual(fixture.Expected.HighlightCount, Metric(snapshot, "highlights").Value);
        Assert.AreEqual(fixture.Expected.RepeatedIssueCount, Metric(snapshot, "repeated-issues").Value);
        Assert.AreEqual(fixture.Expected.RecommendedActionCount, Metric(snapshot, "recommended-actions").Value);
        Assert.AreEqual(fixture.Expected.TimelineCount, Metric(snapshot, "timeline-items").Value);

        CollectionAssert.AreEquivalent(
            new[] { "activity-001", "activity-002", "activity-003", "activity-004", "evidence-001" },
            snapshot.AcceptedSources.Select(item => item.SourceId).ToArray());
        Assert.IsFalse(snapshot.AcceptedSources.Any(item =>
            item.SourceId is "activity-005" or "activity-006" or "evidence-002"));

        var backend = snapshot.Workstreams.Single(item => item.Workstream == "Backend");
        Assert.AreEqual(3, backend.AcceptedSourceCount);
        Assert.AreEqual(2, backend.ActivityCount);
        Assert.AreEqual(1, backend.EvidenceCount);

        var repeatedIssue = snapshot.RepeatedIssues.Single();
        Assert.AreEqual(fixture.Expected.RepeatedIssueKey, repeatedIssue.IssueKey);
        CollectionAssert.AreEquivalent(
            fixture.Expected.RepeatedIssueSourceIds,
            repeatedIssue.SourceIds.ToArray());

        Assert.AreEqual(
            new DateTimeOffset(2026, 8, 15, 0, 0, 0, TimeSpan.FromHours(7)),
            snapshot.Timeline.First().OccurredLocal);
        Assert.AreEqual(
            new DateTimeOffset(2026, 8, 15, 23, 59, 0, TimeSpan.FromHours(7)),
            snapshot.Timeline.Last().OccurredLocal);
        Assert.AreEqual(64, snapshot.SourceSetSha256.Length);
        Assert.AreEqual(64, snapshot.ResultSha256.Length);

        var acceptedIds = snapshot.AcceptedSources
            .Select(item => item.SourceId)
            .ToHashSet(StringComparer.Ordinal);
        foreach (var metric in snapshot.Metrics)
        {
            Assert.IsTrue(metric.SourceIds.All(acceptedIds.Contains), metric.MetricId);
        }
    }

    [TestMethod]
    public void LocalDayBoundaryUsesExplicitTimezoneAndNotMachineLocalTime()
    {
        var beforeBoundary = CreateSource(
            "before-boundary",
            DailySummarySourceKind.ActivityEvent,
            new DateTimeOffset(2026, 8, 15, 16, 59, 59, 999, TimeSpan.Zero));
        var atBoundary = CreateSource(
            "at-boundary",
            DailySummarySourceKind.Evidence,
            new DateTimeOffset(2026, 8, 15, 17, 0, 0, TimeSpan.Zero));

        var Bangkok = DailySummaryAggregator.Aggregate(
            new DateOnly(2026, 8, 15),
            CreateFixedOffsetTimeZone(420),
            [beforeBoundary, atBoundary]);
        var utc = DailySummaryAggregator.Aggregate(
            new DateOnly(2026, 8, 15),
            TimeZoneInfo.Utc,
            [beforeBoundary, atBoundary]);

        CollectionAssert.AreEquivalent(
            new[] { "before-boundary" },
            Bangkok.AcceptedSources.Select(item => item.SourceId).ToArray());
        CollectionAssert.AreEquivalent(
            new[] { "before-boundary", "at-boundary" },
            utc.AcceptedSources.Select(item => item.SourceId).ToArray());
    }

    [TestMethod]
    public void ReorderingSourcesDoesNotChangeCanonicalSnapshot()
    {
        var fixture = ReadFixture();
        var timeZone = CreateFixedOffsetTimeZone(fixture.TimeZoneOffsetMinutes);

        var first = DailySummaryAggregator.Aggregate(fixture.LocalDate, timeZone, fixture.Sources);
        var second = DailySummaryAggregator.Aggregate(
            fixture.LocalDate,
            timeZone,
            fixture.Sources.Reverse().ToArray());

        Assert.AreEqual(first.SourceSetSha256, second.SourceSetSha256);
        Assert.AreEqual(first.ResultSha256, second.ResultSha256);
        Assert.AreEqual(
            JsonSerializer.Serialize(first, FixtureJsonOptions),
            JsonSerializer.Serialize(second, FixtureJsonOptions));
    }

    [TestMethod]
    public void EmptyAcceptedLocalDayEmitsCompleteZeroedContract()
    {
        var outsideLocalDay = CreateSource(
            "outside-local-day",
            DailySummarySourceKind.Evidence,
            new DateTimeOffset(2026, 8, 15, 17, 0, 0, TimeSpan.Zero));
        var rejected = CreateSource(
            "rejected",
            DailySummarySourceKind.ActivityEvent,
            new DateTimeOffset(2026, 8, 15, 8, 0, 0, TimeSpan.Zero)) with
        {
            IsAccepted = false,
        };
        var timeZone = CreateFixedOffsetTimeZone(420);

        var first = DailySummaryAggregator.Aggregate(
            new DateOnly(2026, 8, 15),
            timeZone,
            [outsideLocalDay, rejected]);
        var second = DailySummaryAggregator.Aggregate(
            new DateOnly(2026, 8, 15),
            timeZone,
            [rejected, outsideLocalDay]);

        CollectionAssert.AreEqual(
            new[]
            {
                "accepted-sources",
                "activity-events",
                "evidence-items",
                "workstreams",
                "timeline-items",
                "highlights",
                "repeated-issues",
                "recommended-actions",
            },
            first.Metrics.Select(item => item.MetricId).ToArray());
        Assert.IsEmpty(first.AcceptedSources);
        Assert.IsEmpty(first.Workstreams);
        Assert.IsEmpty(first.Highlights);
        Assert.IsEmpty(first.RepeatedIssues);
        Assert.IsEmpty(first.RecommendedActions);
        Assert.IsEmpty(first.Timeline);
        foreach (var metric in first.Metrics)
        {
            Assert.AreEqual(0, metric.Value, metric.MetricId);
            Assert.IsEmpty(metric.SourceIds, metric.MetricId);
        }

        Assert.AreEqual(first.SourceSetSha256, second.SourceSetSha256);
        Assert.AreEqual(first.ResultSha256, second.ResultSha256);
        Assert.AreEqual(64, first.SourceSetSha256.Length);
        Assert.AreEqual(64, first.ResultSha256.Length);
    }

    [TestMethod]
    public void DuplicateSourceAndNonUtcTimestampFailClosed()
    {
        var first = CreateSource(
            "duplicate",
            DailySummarySourceKind.ActivityEvent,
            new DateTimeOffset(2026, 8, 15, 0, 0, 0, TimeSpan.Zero));
        var duplicate = first with { SourceHashSha256 = Hash("duplicate-2") };
        var duplicateException = Assert.ThrowsExactly<DailySummaryAggregationException>(() =>
            DailySummaryAggregator.Aggregate(
                new DateOnly(2026, 8, 15),
                TimeZoneInfo.Utc,
                [first, duplicate]));
        StringAssert.Contains(duplicateException.Message, "duplicate source ID");

        var nonUtc = first with
        {
            SourceId = "non-utc",
            OccurredUtc = new DateTimeOffset(2026, 8, 15, 7, 0, 0, TimeSpan.FromHours(7)),
        };
        var timestampException = Assert.ThrowsExactly<DailySummaryAggregationException>(() =>
            DailySummaryAggregator.Aggregate(
                new DateOnly(2026, 8, 15),
                TimeZoneInfo.Utc,
                [nonUtc]));
        StringAssert.Contains(timestampException.Message, "timestamps must be UTC");
    }

    [TestMethod]
    public void InvalidSourceHashIsRejectedBeforeAggregation()
    {
        var invalid = CreateSource(
            "invalid-hash",
            DailySummarySourceKind.Evidence,
            new DateTimeOffset(2026, 8, 15, 0, 0, 0, TimeSpan.Zero)) with
        {
            SourceHashSha256 = "not-a-sha256",
        };

        Assert.ThrowsExactly<DailySummaryAggregationException>(() =>
            DailySummaryAggregator.Aggregate(
                new DateOnly(2026, 8, 15),
                TimeZoneInfo.Utc,
                [invalid]));
    }

    private static DailySummaryMetric Metric(DailySummarySnapshot snapshot, string metricId) =>
        snapshot.Metrics.Single(item => item.MetricId == metricId);

    private static Fixture ReadFixture()
    {
        var json = File.ReadAllText(FindFixturePath(), Encoding.UTF8);
        return JsonSerializer.Deserialize<Fixture>(json, FixtureJsonOptions)
            ?? throw new AssertFailedException("Daily Summary fixture was empty.");
    }

    private static string FindFixturePath() => Path.Combine(
        FindRepositoryRoot(),
        "tests",
        "fixtures",
        "v0.6",
        "daily-summary-aggregation.json");

    private static string FindRepositoryRoot()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null)
        {
            if (File.Exists(Path.Combine(directory.FullName, "HerdrOps.sln")))
            {
                return directory.FullName;
            }

            directory = directory.Parent;
        }

        Assert.Fail("Could not locate HerdrOps.sln from the test output directory.");
        return string.Empty;
    }

    private static TimeZoneInfo CreateFixedOffsetTimeZone(int offsetMinutes) =>
        TimeZoneInfo.CreateCustomTimeZone(
            $"fixture-utc-{offsetMinutes:+#;-#;0}",
            TimeSpan.FromMinutes(offsetMinutes),
            "Daily Summary fixture",
            "Daily Summary fixture");

    private static DailySummarySource CreateSource(
        string sourceId,
        DailySummarySourceKind kind,
        DateTimeOffset occurredUtc) => new(
        sourceId,
        kind,
        Hash(sourceId),
        occurredUtc,
        "Backend",
        "agent-1",
        "TASK-1",
        "Synthetic",
        "Synthetic accepted source",
        true,
        false,
        null,
        null);

    private static string Hash(string value) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value)));

    private static string CanonicalSourceHash(DailySummarySource source)
    {
        var canonical = string.Join(
            '\u001F',
            source.SourceId,
            ((int)source.Kind).ToString(CultureInfo.InvariantCulture),
            source.OccurredUtc.ToUniversalTime().ToString("O", CultureInfo.InvariantCulture),
            source.Workstream,
            source.AgentId,
            source.TaskId,
            source.Category,
            source.Summary,
            source.IsAccepted ? "1" : "0",
            source.IsHighlight ? "1" : "0",
            source.IssueKey ?? string.Empty,
            source.RecommendedAction ?? string.Empty);
        return Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(canonical)));
    }

    private sealed record Fixture(
        int ContractVersion,
        DateOnly LocalDate,
        int TimeZoneOffsetMinutes,
        DailySummarySource[] Sources,
        ExpectedCounts Expected);

    private sealed record ExpectedCounts(
        int AcceptedSourceCount,
        int ActivityCount,
        int EvidenceCount,
        int WorkstreamCount,
        int HighlightCount,
        int RepeatedIssueCount,
        int RecommendedActionCount,
        int TimelineCount,
        string RepeatedIssueKey,
        string[] RepeatedIssueSourceIds);
}
