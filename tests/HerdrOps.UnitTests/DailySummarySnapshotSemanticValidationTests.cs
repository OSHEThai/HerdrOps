using System.Reflection;
using System.Text;
using System.Text.Json;
using HerdrOps.Domain.Summaries;

namespace HerdrOps.UnitTests;

[TestClass]
public sealed class DailySummarySnapshotSemanticValidationTests
{
    private static readonly JsonSerializerOptions FixtureJsonOptions = new()
    {
        PropertyNameCaseInsensitive = true,
    };

    [TestMethod]
    public void ValidIssue32FixturePassesSemanticValidation()
    {
        var snapshot = ReadSnapshot();

        var validated = DailySummaryAggregator.Validate(snapshot);

        Assert.AreEqual(snapshot.SourceSetSha256, validated.SourceSetSha256);
        Assert.AreEqual(snapshot.ResultSha256, validated.ResultSha256);
    }

    [TestMethod]
    public void RejectsCanonicalOrderAndDuplicateIdentifiers()
    {
        var snapshot = ReadSnapshot();

        ExpectFailure(
            Rehash(snapshot with { Timeline = snapshot.Timeline.Reverse().ToArray() }),
            "accepted source and timeline order");

        var reversedMetricReferences = snapshot.Metrics[0] with
        {
            SourceIds = snapshot.Metrics[0].SourceIds.Reverse().ToArray(),
        };
        ExpectFailure(
            Rehash(WithMetric(snapshot, 0, reversedMetricReferences)),
            "metric 'accepted-sources' source references");

        var duplicateAcceptedSources = snapshot with
        {
            AcceptedSources = snapshot.AcceptedSources
                .Concat([snapshot.AcceptedSources[0]])
                .ToArray(),
        };
        ExpectFailure(duplicateAcceptedSources, "duplicate accepted source ID");

        var duplicateTimeline = snapshot with
        {
            Timeline = snapshot.Timeline
                .Concat([snapshot.Timeline[0]])
                .ToArray(),
        };
        ExpectFailure(duplicateTimeline, "duplicate timeline source ID");

        var duplicateMetric = snapshot.Metrics[1] with
        {
            MetricId = snapshot.Metrics[0].MetricId,
        };
        ExpectFailure(WithMetric(snapshot, 1, duplicateMetric), "duplicate metric ID");

        var duplicateWorkstream = snapshot.Workstreams[1] with
        {
            Workstream = snapshot.Workstreams[0].Workstream,
        };
        var workstreams = snapshot.Workstreams.ToArray();
        workstreams[1] = duplicateWorkstream;
        ExpectFailure(snapshot with { Workstreams = workstreams }, "duplicate workstream ID");

        var duplicateReference = snapshot.Metrics[0] with
        {
            SourceIds = [snapshot.AcceptedSources[0].SourceId, snapshot.AcceptedSources[0].SourceId],
        };
        ExpectFailure(WithMetric(snapshot, 0, duplicateReference), "duplicate source reference ID");
    }

    [TestMethod]
    public void RejectsUnresolvedReferencesAndSourceConsistencyDrift()
    {
        var snapshot = ReadSnapshot();

        var unresolvedMetric = snapshot.Metrics[0] with
        {
            SourceIds = ["missing-source"],
        };
        ExpectFailure(WithMetric(snapshot, 0, unresolvedMetric), "does not resolve exactly once");

        var firstTimeline = snapshot.Timeline[0];
        var kindMismatch = firstTimeline with
        {
            Kind = DailySummarySourceKind.Evidence,
        };
        ExpectFailure(WithTimeline(snapshot, 0, kindMismatch), "kind/hash");

        var hashMismatch = firstTimeline with
        {
            SourceHashSha256 = new string('A', 64),
        };
        ExpectFailure(WithTimeline(snapshot, 0, hashMismatch), "kind/hash");

        var unknownHighlight = snapshot.Highlights[0] with
        {
            SourceId = "missing-source",
            SourceIds = ["missing-source"],
        };
        var highlights = snapshot.Highlights.ToArray();
        highlights[0] = unknownHighlight;
        ExpectFailure(snapshot with { Highlights = highlights }, "accepted timeline source");
    }

    [TestMethod]
    public void RejectsTimelineDateMetricAndWorkstreamReconciliationDrift()
    {
        var snapshot = ReadSnapshot();

        var outsideDate = snapshot.Timeline[0] with
        {
            OccurredLocal = snapshot.Timeline[0].OccurredLocal.AddDays(1),
        };
        ExpectFailure(WithTimeline(snapshot, 0, outsideDate), "falls outside local date");

        var wrongMetricValue = snapshot.Metrics[1] with
        {
            Value = snapshot.Metrics[1].Value + 1,
        };
        ExpectFailure(
            Rehash(WithMetric(snapshot, 1, wrongMetricValue)),
            "metric 'activity-events' value");

        var wrongMetricSources = snapshot.Metrics[1] with
        {
            SourceIds = [snapshot.AcceptedSources[0].SourceId],
        };
        ExpectFailure(
            Rehash(WithMetric(snapshot, 1, wrongMetricSources)),
            "metric 'activity-events' source set");

        var backendIndex = Array.FindIndex(
            snapshot.Workstreams.ToArray(),
            item => item.Workstream == "Backend");
        var backend = snapshot.Workstreams[backendIndex] with
        {
            AcceptedSourceCount = snapshot.Workstreams[backendIndex].AcceptedSourceCount + 1,
        };
        var wrongWorkstreamCounts = snapshot.Workstreams.ToArray();
        wrongWorkstreamCounts[backendIndex] = backend;
        ExpectFailure(
            Rehash(snapshot with { Workstreams = wrongWorkstreamCounts }),
            "workstream 'Backend' accepted source count");

        var wrongWorkstreamSources = snapshot.Workstreams[backendIndex] with
        {
            SourceIds = [snapshot.AcceptedSources[0].SourceId],
        };
        var wrongWorkstreamSet = snapshot.Workstreams.ToArray();
        wrongWorkstreamSet[backendIndex] = wrongWorkstreamSources;
        ExpectFailure(
            Rehash(snapshot with { Workstreams = wrongWorkstreamSet }),
            "workstream 'Backend' source set");
    }

    [TestMethod]
    public void RejectsIssueAndActionSourceSetDrift()
    {
        var snapshot = ReadSnapshot();

        var issue = snapshot.RepeatedIssues[0] with
        {
            SourceIds = [],
        };
        var issues = snapshot.RepeatedIssues.ToArray();
        issues[0] = issue;
        ExpectFailure(snapshot with { RepeatedIssues = issues }, "Repeated issue 'api-latency' must reference");

        var wrongDescription = snapshot.RepeatedIssues[0] with
        {
            Description = snapshot.Timeline[0].Summary,
        };
        var issuesWithWrongDescription = snapshot.RepeatedIssues.ToArray();
        issuesWithWrongDescription[0] = wrongDescription;
        ExpectFailure(
            snapshot with { RepeatedIssues = issuesWithWrongDescription },
            "canonical issue key");

        var action = snapshot.RecommendedActions[0] with
        {
            SourceIds = [],
        };
        var actions = snapshot.RecommendedActions.ToArray();
        actions[0] = action;
        ExpectFailure(snapshot with { RecommendedActions = actions }, "Recommended action");
    }

    [TestMethod]
    public void RejectsSourceAndResultHashDrift()
    {
        var snapshot = ReadSnapshot();

        ExpectFailure(
            snapshot with { SourceSetSha256 = new string('0', 64) },
            "source-set SHA-256");
        ExpectFailure(
            snapshot with { ResultSha256 = new string('0', 64) },
            "result SHA-256");
    }

    private static DailySummarySnapshot ReadSnapshot()
    {
        var fixture = ReadFixture();
        return DailySummaryAggregator.Aggregate(
            fixture.LocalDate,
            TimeZoneInfo.CreateCustomTimeZone(
                $"fixture-utc-{fixture.TimeZoneOffsetMinutes:+#;-#;0}",
                TimeSpan.FromMinutes(fixture.TimeZoneOffsetMinutes),
                "Daily Summary fixture",
                "Daily Summary fixture"),
            fixture.Sources);
    }

    private static DailySummarySnapshot WithMetric(
        DailySummarySnapshot snapshot,
        int index,
        DailySummaryMetric metric)
    {
        var metrics = snapshot.Metrics.ToArray();
        metrics[index] = metric;
        return snapshot with { Metrics = metrics };
    }

    private static DailySummarySnapshot WithTimeline(
        DailySummarySnapshot snapshot,
        int index,
        DailySummaryTimelineEntry entry)
    {
        var timeline = snapshot.Timeline.ToArray();
        timeline[index] = entry;
        return snapshot with { Timeline = timeline };
    }

    private static void ExpectFailure(DailySummarySnapshot snapshot, string messageFragment)
    {
        var exception = Assert.ThrowsExactly<DailySummaryAggregationException>(() =>
            DailySummaryAggregator.Validate(snapshot));
        StringAssert.Contains(exception.Message, messageFragment);
    }

    private static DailySummarySnapshot Rehash(DailySummarySnapshot snapshot)
    {
        var sourceSetHash = InvokePrivateHash("ComputeSourceSetSha256", snapshot.AcceptedSources);
        var withSourceSetHash = snapshot with { SourceSetSha256 = sourceSetHash };
        var resultHash = InvokePrivateHash("ComputeResultSha256", withSourceSetHash);
        return withSourceSetHash with { ResultSha256 = resultHash };
    }

    private static string InvokePrivateHash(string methodName, object argument)
    {
        var method = typeof(DailySummaryAggregator).GetMethod(
            methodName,
            BindingFlags.NonPublic | BindingFlags.Static)
            ?? throw new AssertFailedException($"Could not find {methodName}.");
        return (string)(method.Invoke(null, [argument])
            ?? throw new AssertFailedException($"{methodName} returned null."));
    }

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

    private sealed record Fixture(
        DateOnly LocalDate,
        int TimeZoneOffsetMinutes,
        DailySummarySource[] Sources);
}
