using System.Security.Cryptography;
using System.Text.RegularExpressions;
using System.Text;
using HerdrOps.App.Localization;
using HerdrOps.App.Summaries;
using HerdrOps.Contracts;
using HerdrOps.Domain.Summaries;

namespace HerdrOps.IntegrationTests;

[TestClass]
[DoNotParallelize]
public sealed class DailySummaryStateTests
{
    [TestInitialize]
    public void SetUp() => UiLanguageService.Shared.SetLanguage(UiLanguage.Thai);

    [TestCleanup]
    public void TearDown() => UiLanguageService.Shared.SetLanguage(UiLanguage.Thai);

    [TestMethod]
    public void SyntheticProjectionUsesTheCommittedAggregateAndKeepsSourceLinks()
    {
        var state = DailySummaryState.CreateSyntheticPreview();
        var snapshot = state.Snapshot;

        Assert.AreEqual(EvidenceClass.Synthetic, state.EvidenceClass);
        Assert.IsTrue(state.IsSyntheticPreview);
        Assert.IsNotNull(snapshot);
        Assert.HasCount(5, snapshot!.AcceptedSources);
        Assert.HasCount(3, snapshot.Workstreams);
        Assert.HasCount(5, state.SummaryCards);
        Assert.HasCount(2, state.Highlights);
        Assert.HasCount(1, state.RepeatedIssues);
        Assert.HasCount(2, state.RecommendedActions);
        Assert.HasCount(5, state.Timeline);
        Assert.IsTrue(state.SummaryCards.All(card => card.SourceIds.All(
            sourceId => snapshot.AcceptedSources.Any(source => source.SourceId == sourceId))));
        Assert.IsTrue(state.Highlights.All(item => item.SourceIds.Count > 0));
        Assert.IsTrue(state.RepeatedIssues.All(item => item.SourceIds.Count > 0));
        Assert.IsTrue(state.RecommendedActions.All(item => item.SourceIds.Count > 0));
        Assert.AreEqual("—", state.DailyScoreLabel);
        Assert.AreEqual(UiLanguageService.Shared["DailySummaryNoScore"], state.DailyScoreDetail);
    }

    [TestMethod]
    public void SyntheticProjectionResolvesAcceptedSourceReferencesForEveryRow()
    {
        var state = DailySummaryState.CreateSyntheticPreview();
        var snapshot = state.Snapshot!;
        var accepted = snapshot.AcceptedSources.ToDictionary(
            item => item.SourceId,
            StringComparer.Ordinal);

        var repeatedIssue = state.AreasToImprove.Single();
        Assert.AreEqual(snapshot.RepeatedIssues.Single().Description, repeatedIssue.Summary);
        CollectionAssert.AreEqual(
            snapshot.RepeatedIssues.Single().SourceIds.OrderBy(item => item, StringComparer.Ordinal).ToArray(),
            repeatedIssue.SourceIds.ToArray());

        var rows = state.SummaryCards.Select(item => (item.SourceIds, item.SourceReferences))
            .Concat(state.Highlights.Select(item => (item.SourceIds, item.SourceReferences)))
            .Concat(state.Strengths.Select(item => (item.SourceIds, item.SourceReferences)))
            .Concat(state.AreasToImprove.Select(item => (item.SourceIds, item.SourceReferences)))
            .Concat(state.RepeatedIssues.Select(item => (item.SourceIds, item.SourceReferences)))
            .Concat(state.RecommendedActions.Select(item => (item.SourceIds, item.SourceReferences)))
            .Concat(state.Timeline.Select(item => (item.SourceIds, item.SourceReferences)))
            .Concat(state.Workstreams.Select(item => (item.SourceIds, item.SourceReferences)))
            .ToArray();

        foreach (var row in rows)
        {
            CollectionAssert.AreEqual(
                row.SourceIds.ToArray(),
                row.SourceReferences.Select(item => item.SourceId).ToArray());
            Assert.IsNotEmpty(row.SourceReferences);
            foreach (var reference in row.SourceReferences)
            {
                Assert.IsTrue(accepted.TryGetValue(reference.SourceId, out var acceptedReference));
                Assert.AreEqual(acceptedReference!.Kind, reference.Kind);
                Assert.AreEqual(acceptedReference.SourceHashSha256, reference.SourceHashSha256);
            }
        }

        var repeatedIssueSources = snapshot.RepeatedIssues.Single().SourceIds.ToHashSet(StringComparer.Ordinal);
        Assert.IsTrue(repeatedIssue.SourceReferences.All(item => repeatedIssueSources.Contains(item.SourceId)));
    }

    [TestMethod]
    public void LanguageRefreshKeepsTheSameAggregateAndUsesOneLanguageAtATime()
    {
        var state = DailySummaryState.CreateSyntheticPreview();
        var resultHash = state.Snapshot!.ResultSha256;

        UiLanguageService.Shared.SetLanguage(UiLanguage.English);
        state.RefreshLanguage();
        Assert.AreEqual(resultHash, state.Snapshot!.ResultSha256);
        Assert.AreEqual("Daily Summary", UiLanguageService.Shared["DailySummaryPageTitle"]);
        Assert.IsTrue(state.SummaryCards.All(card => !ContainsThai(card.Title + card.Detail)));
        Assert.IsTrue(state.Highlights.All(item => !ContainsThai(item.Summary)));
        Assert.IsTrue(state.RecommendedActions.All(item => !ContainsThai(item.Description)));
        Assert.IsTrue(state.AreasToImprove.All(item => !ContainsThai(item.SourceLabel + item.SourceProvenanceLabel)));

        UiLanguageService.Shared.SetLanguage(UiLanguage.Thai);
        state.RefreshLanguage();
        Assert.AreEqual("สรุปรายวัน", UiLanguageService.Shared["DailySummaryPageTitle"]);
        Assert.IsTrue(state.SummaryCards.All(card => ContainsThai(card.Title + card.Detail)));
        Assert.IsTrue(state.SummaryCards.Any(card => ContainsThai(card.Title + card.Detail)));
        Assert.IsTrue(state.Highlights.All(item => !ContainsThai(item.Summary)));
        Assert.IsTrue(state.RecommendedActions.All(item => !ContainsThai(item.Description)));
        Assert.IsTrue(state.AreasToImprove.All(item => ContainsThai(item.SourceLabel)));
    }

    [TestMethod]
    public void GenericThaiSnapshotUsesAcceptedDescriptionsSummariesAndExactProvenance()
    {
        AssertGenericSnapshotProjection(
            UiLanguage.Thai,
            "สรุปจากแหล่งข้อมูลที่ไม่อยู่ในฟิกซ์เจอร์",
            "issue-arbitrary-42",
            "ส่งต่อให้เจ้าของระบบ");
    }

    [TestMethod]
    public void GenericEnglishSnapshotUsesAcceptedDescriptionsSummariesAndExactProvenance()
    {
        AssertGenericSnapshotProjection(
            UiLanguage.English,
            "Summary from an arbitrary accepted source",
            "issue-arbitrary-42",
            "Route to the service owner");
    }

    [TestMethod]
    public void MalformedSnapshotFailsClosedBeforeProjection()
    {
        var valid = CreateGenericSnapshot(
            "Accepted source summary",
            "issue-arbitrary-42",
            "Route to the service owner");
        var malformed = valid with
        {
            Timeline = valid.Timeline
                .Select(item => item with { SourceHashSha256 = "not-a-sha256" })
                .ToArray(),
        };

        var state = DailySummaryState.CreateSyntheticPreview(malformed);

        Assert.IsFalse(state.IsSyntheticPreview);
        Assert.AreEqual(EvidenceClass.Contract, state.EvidenceClass);
        Assert.IsNull(state.Snapshot);
        Assert.IsEmpty(state.RepeatedIssues);
        Assert.IsTrue(state.SummaryCards.All(card => card.Value == "—"));
    }

    [TestMethod]
    public void TamperedCanonicalSnapshotBecomesExplicitlyUnavailableWithoutTrustedCards()
    {
        var valid = CreateGenericSnapshot(
            "Accepted source summary",
            "issue-arbitrary-42",
            "Route to the service owner");
        var metrics = valid.Metrics.ToArray();
        var tamperedSnapshots = new[]
        {
            valid with { SourceSetSha256 = Hash("tampered-source-set") },
            valid with { ResultSha256 = Hash("tampered-result") },
            valid with
            {
                Metrics = metrics
                    .Select(item => item.MetricId == "accepted-sources" ? item with { Value = item.Value + 1 } : item)
                    .ToArray(),
            },
            valid with { Metrics = metrics.Skip(1).ToArray() },
            valid with { Metrics = metrics.Take(7).Append(metrics[0]).ToArray() },
            valid with { Timeline = valid.Timeline.Skip(1).ToArray() },
        };

        foreach (var tampered in tamperedSnapshots)
        {
            var state = DailySummaryState.CreateSyntheticPreview(tampered);

            Assert.IsFalse(state.IsSyntheticPreview);
            Assert.AreEqual(EvidenceClass.Contract, state.EvidenceClass);
            Assert.IsNull(state.Snapshot);
            Assert.AreEqual("—", state.SourceSetLabel);
            Assert.AreEqual("—", state.ResultLabel);
            Assert.HasCount(5, state.SummaryCards);
            Assert.IsTrue(state.SummaryCards.All(card => card.Value == "—"));
            Assert.IsTrue(state.SummaryCards.All(card => card.SourceReferences.Count == 0));
            Assert.IsEmpty(state.Highlights);
            Assert.IsEmpty(state.RepeatedIssues);
            Assert.IsEmpty(state.RecommendedActions);
            Assert.IsEmpty(state.Timeline);
            Assert.IsEmpty(state.Workstreams);
        }
    }

    [TestMethod]
    public void UnavailableProjectionFailsClosedWithExplicitMissingValues()
    {
        var state = DailySummaryState.CreateUnavailable();

        Assert.AreEqual(EvidenceClass.Contract, state.EvidenceClass);
        Assert.IsFalse(state.IsSyntheticPreview);
        Assert.IsNull(state.Snapshot);
        Assert.HasCount(5, state.SummaryCards);
        Assert.IsTrue(state.SummaryCards.All(card => card.Value == "—"));
        Assert.IsTrue(state.SummaryCards.All(card => card.SourceReferences.Count == 0));
        Assert.IsTrue(state.SummaryCards.All(card =>
            card.SourceProvenanceLabel == UiLanguageService.Shared["DailySummaryNoRecords"]));
        Assert.IsEmpty(state.Highlights);
        Assert.IsEmpty(state.Workstreams);
        StringAssert.Contains(state.BoundaryLabel, "สแนปช็อต");
    }

    private static bool ContainsThai(string value) =>
        Regex.IsMatch(value, "[ก-๙]", RegexOptions.CultureInvariant);

    private static void AssertGenericSnapshotProjection(
        UiLanguage language,
        string sourceSummary,
        string issueDescription,
        string actionDescription)
    {
        UiLanguageService.Shared.SetLanguage(language);
        var snapshot = CreateGenericSnapshot(sourceSummary, issueDescription, actionDescription);
        var state = DailySummaryState.CreateSyntheticPreview(snapshot);
        var accepted = snapshot.AcceptedSources.ToDictionary(item => item.SourceId, StringComparer.Ordinal);
        var sourceId = "source-arbitrary-88";
        var source = accepted[sourceId];

        Assert.IsTrue(state.IsSyntheticPreview);
        Assert.AreEqual(snapshot.ResultSha256, state.Snapshot!.ResultSha256);
        Assert.AreEqual(issueDescription, state.RepeatedIssues.Single().Description);
        Assert.AreNotEqual("Unrelated first source summary", state.RepeatedIssues.Single().Description);
        Assert.AreEqual(actionDescription, state.RecommendedActions.Single().Description);
        Assert.AreEqual(sourceSummary, state.Highlights.Single().Summary);
        Assert.AreEqual(sourceSummary, state.Timeline.Single(item => item.SourceIds.Contains(sourceId)).Summary);
        Assert.IsTrue(state.Strengths.Any(item => item.Summary == sourceSummary));
        Assert.IsFalse(state.Timeline.Any(item => item.Summary == UiLanguageService.Shared["DailySummaryNoSummary"]));
        Assert.IsFalse(state.RepeatedIssues.Single().Description.Contains("API latency", StringComparison.OrdinalIgnoreCase));
        Assert.IsFalse(state.RecommendedActions.Single().Description.Contains("Login", StringComparison.OrdinalIgnoreCase));

        var timelineRow = state.Timeline.Single(item => item.SourceIds.Contains(sourceId));
        CollectionAssert.AreEqual(new[] { sourceId }, timelineRow.SourceIds.ToArray());
        Assert.AreEqual(source.SourceHashSha256, timelineRow.SourceReferences.Single().SourceHashSha256);
        StringAssert.Contains(timelineRow.SourceProvenanceLabel, $"{sourceId}#{source.SourceHashSha256}");
        var pageTitle = UiLanguageService.Shared["DailySummaryPageTitle"];
        if (language == UiLanguage.Thai)
        {
            Assert.IsTrue(ContainsThai(state.SourceLabel + pageTitle));
        }
        else
        {
            Assert.IsFalse(ContainsThai(pageTitle));
        }
    }

    private static DailySummarySnapshot CreateGenericSnapshot(
        string sourceSummary,
        string issueDescription,
        string actionDescription)
    {
        var sources = new[]
        {
            GenericSource(
                "source-arbitrary-77",
                new DateTimeOffset(2026, 8, 15, 1, 0, 0, TimeSpan.Zero),
                "Unmapped Workstream",
                "Unrelated first source summary",
                isHighlight: false,
                issueKey: "issue-arbitrary-42",
                recommendedAction: actionDescription),
            GenericSource(
                "source-arbitrary-88",
                new DateTimeOffset(2026, 8, 15, 2, 0, 0, TimeSpan.Zero),
                "Unmapped Workstream",
                sourceSummary,
                isHighlight: true,
                issueKey: issueDescription,
                recommendedAction: actionDescription),
            GenericSource(
                "source-arbitrary-99",
                new DateTimeOffset(2026, 8, 15, 3, 0, 0, TimeSpan.Zero),
                "Another Workstream",
                "Another accepted arbitrary summary",
                isHighlight: false,
                issueKey: null,
                recommendedAction: null),
        };

        var snapshot = DailySummaryAggregator.Aggregate(
            new DateOnly(2026, 8, 15),
            TimeZoneInfo.Utc,
            sources);
        return snapshot;
    }

    private static DailySummarySource GenericSource(
        string sourceId,
        DateTimeOffset occurredUtc,
        string workstream,
        string summary,
        bool isHighlight,
        string? issueKey,
        string? recommendedAction) =>
        new(
            sourceId,
            DailySummarySourceKind.ActivityEvent,
            Hash(sourceId + summary),
            occurredUtc,
            workstream,
            "arbitrary-agent",
            "arbitrary-task",
            "ArbitraryCategory",
            summary,
            IsAccepted: true,
            IsHighlight: isHighlight,
            IssueKey: issueKey,
            RecommendedAction: recommendedAction);

    private static string Hash(string value) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value)));
}
