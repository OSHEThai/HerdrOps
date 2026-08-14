using System.Text;
using System.Text.Json;
using HerdrOps.Domain.Activity;

namespace HerdrOps.UnitTests;

[TestClass]
public sealed class TerminalPreviewPolicyTests
{
    [TestMethod]
    public void RedactorRemovesAssignmentsAuthorizationUriCredentialsAndKnownTokens()
    {
        const string apiKey = "sk-abcdefghijklmnopqrstuvwxyz123456";
        const string bearer = "bearer-secret-value-123456789";
        const string password = "hunter2-super-secret";
        const string githubToken = "gho_ABCDEFGHIJKLMNOPQRSTUVWXYZ123456";
        const string statelessGitHubToken =
            "ghs_123456_eyJabcdefghijk.eyJklmnopqrst.abcdefghijklmnop";
        const string jwt = "eyJabcdefghijk.eyJklmnopqrst.abcdefghijklmnop";
        var input = string.Join(
            '\n',
            $"OPENAI_API_KEY={apiKey}",
            $"Authorization: Bearer {bearer}",
            $"https://user:{password}@example.test/repo",
            githubToken,
            statelessGitHubToken,
            jwt);

        var result = new SensitiveTextRedactor().Redact(input);

        Assert.IsGreaterThanOrEqualTo(6, result.ReplacementCount);
        StringAssert.Contains(result.RedactedText, "[REDACTED]");
        Assert.IsFalse(result.RedactedText.Contains(apiKey, StringComparison.Ordinal));
        Assert.IsFalse(result.RedactedText.Contains(bearer, StringComparison.Ordinal));
        Assert.IsFalse(result.RedactedText.Contains(password, StringComparison.Ordinal));
        Assert.IsFalse(result.RedactedText.Contains(githubToken, StringComparison.Ordinal));
        Assert.IsFalse(result.RedactedText.Contains(statelessGitHubToken, StringComparison.Ordinal));
        Assert.IsFalse(result.RedactedText.Contains(jwt, StringComparison.Ordinal));
        Assert.HasCount(64, result.OriginalSha256);
        Assert.HasCount(64, result.RedactedSha256);
        Assert.AreNotEqual(result.OriginalSha256, result.RedactedSha256);
    }

    [TestMethod]
    public void RedactorBoundsUnicodeOutputWithoutSplittingRunes()
    {
        var options = new SensitiveTextRedactorOptions(
            MaximumInputUtf8Bytes: 4096,
            MaximumOutputCharacters: 64,
            MaximumOutputUtf8Bytes: 256);
        var input = string.Concat(Enumerable.Repeat("ข้อมูล🔐", 80));

        var result = new SensitiveTextRedactor(options).Redact(input);

        Assert.IsTrue(result.WasTruncated);
        Assert.EndsWith("…", result.RedactedText, StringComparison.Ordinal);
        Assert.IsLessThanOrEqualTo(64, result.RedactedText.Length);
        Assert.IsLessThanOrEqualTo(256, Encoding.UTF8.GetByteCount(result.RedactedText));
        _ = new UTF8Encoding(false, true).GetBytes(result.RedactedText);
    }

    [TestMethod]
    public void RedactorRemovesFineGrainedGitHubPatAndColonlessUriCredentials()
    {
        const string fineGrainedPat =
            "github_pat_11ABCDEFGHIJKLMNOPQRSTUVWXYZ_abcdefghijklmnopqrstuvwxyz0123456789";
        var input = string.Join(
            '\n',
            fineGrainedPat,
            $"git clone https://{fineGrainedPat}@github.com/OSHEThai/HerdrOps.git");

        var result = new SensitiveTextRedactor().Redact(input);

        Assert.IsGreaterThanOrEqualTo(2, result.ReplacementCount);
        Assert.IsFalse(result.RedactedText.Contains(fineGrainedPat, StringComparison.Ordinal));
        StringAssert.Contains(result.RedactedText, "https://[REDACTED]@github.com");
    }

    [TestMethod]
    public void RedactorRejectsInputAboveItsExplicitByteBound()
    {
        var redactor = new SensitiveTextRedactor(new SensitiveTextRedactorOptions(256, 64, 256));

        var exception = Assert.ThrowsExactly<ArgumentOutOfRangeException>(() =>
            redactor.Redact(new string('x', 257)));

        StringAssert.Contains(exception.Message, "256-byte input bound");
    }

    [TestMethod]
    public void PlannerReadsOnlyChangedRevisionsAndRetriesFailuresAfterDebounce()
    {
        var planner = new TerminalReadPlanner(new TerminalReadPlannerOptions(
            MaximumLines: 40,
            MaximumTrackedPanes: 4,
            MinimumReadInterval: TimeSpan.FromSeconds(2)));
        var start = new DateTimeOffset(2026, 8, 14, 12, 0, 0, TimeSpan.Zero);

        var first = planner.Evaluate("pane-1", revision: 5, start);
        var duplicateAttempt = planner.Evaluate("pane-1", revision: 5, start.AddSeconds(1));
        var retry = planner.Evaluate("pane-1", revision: 5, start.AddSeconds(2));
        planner.RecordSuccess("pane-1", revision: 5, start.AddSeconds(2));
        var unchanged = planner.Evaluate("pane-1", revision: 5, start.AddSeconds(3));
        var regression = planner.Evaluate("pane-1", revision: 4, start.AddSeconds(3.25));
        var debouncedChange = planner.Evaluate("pane-1", revision: 6, start.AddSeconds(3.5));
        var changed = planner.Evaluate("pane-1", revision: 6, start.AddSeconds(4));

        Assert.AreEqual(TerminalReadDecisionKind.Read, first.Kind);
        Assert.AreEqual(40, first.MaximumLines);
        Assert.AreEqual(TerminalReadDecisionKind.Debounced, duplicateAttempt.Kind);
        Assert.AreEqual(TerminalReadDecisionKind.Read, retry.Kind);
        Assert.AreEqual(TerminalReadDecisionKind.RevisionUnchanged, unchanged.Kind);
        Assert.AreEqual(TerminalReadDecisionKind.RevisionRegressed, regression.Kind);
        Assert.AreEqual(TerminalReadDecisionKind.Debounced, debouncedChange.Kind);
        Assert.AreEqual(TerminalReadDecisionKind.Read, changed.Kind);
        Assert.AreEqual(3L, planner.AttemptCount);
        Assert.AreEqual(1L, planner.SuccessCount);
    }

    [TestMethod]
    public void PlannerEvictsOldestPaneAtTheConfiguredBound()
    {
        var planner = new TerminalReadPlanner(new TerminalReadPlannerOptions(
            MaximumLines: 20,
            MaximumTrackedPanes: 2,
            MinimumReadInterval: TimeSpan.FromSeconds(1)));
        var start = new DateTimeOffset(2026, 8, 14, 12, 0, 0, TimeSpan.Zero);

        _ = planner.Evaluate("pane-b", 1, start);
        _ = planner.Evaluate("pane-a", 1, start);
        _ = planner.Evaluate("pane-c", 1, start.AddSeconds(1));

        Assert.AreEqual(2, planner.TrackedPaneCount);
        Assert.AreEqual(1L, planner.EvictionCount);
        var evictedPaneCanBePlannedAgain = planner.Evaluate("pane-a", 1, start.AddSeconds(2));
        Assert.IsTrue(evictedPaneCanBePlannedAgain.ShouldRead);
        Assert.AreEqual(2L, planner.EvictionCount);
    }

    [TestMethod]
    public void PlannerAcceptsAReadRevisionThatAdvancedAfterTheReadWasPlanned()
    {
        var planner = new TerminalReadPlanner(new TerminalReadPlannerOptions(
            MaximumLines: 20,
            MaximumTrackedPanes: 2,
            MinimumReadInterval: TimeSpan.FromSeconds(1)));
        var start = new DateTimeOffset(2026, 8, 14, 12, 0, 0, TimeSpan.Zero);

        var decision = planner.Evaluate("pane-1", revision: 7, start);
        planner.RecordSuccess("pane-1", revision: 8, start.AddMilliseconds(50));
        var unchanged = planner.Evaluate("pane-1", revision: 8, start.AddSeconds(1));

        Assert.IsTrue(decision.ShouldRead);
        Assert.AreEqual(TerminalReadDecisionKind.RevisionUnchanged, unchanged.Kind);
        Assert.AreEqual(1L, planner.SuccessCount);
    }

    [TestMethod]
    public void SanitizedObservationSerializesNoRawSecret()
    {
        const string secret = "must-never-enter-an-activity-record";
        var payload = new TerminalPreviewPayload(
            "pane-1",
            "terminal-1",
            Revision: 9,
            SourceTruncated: false,
            Text: $"PASSWORD={secret}\r\nbuild completed",
            ObservedUtc: new DateTimeOffset(2026, 8, 14, 12, 0, 0, TimeSpan.Zero));

        var observation = TerminalPreviewSanitizer.Sanitize(payload, new SensitiveTextRedactor());
        var serialized = JsonSerializer.Serialize(observation);

        Assert.IsFalse(serialized.Contains(secret, StringComparison.Ordinal));
        StringAssert.Contains(observation.RedactedSummary, "PASSWORD=[REDACTED]");
        Assert.AreEqual(1, observation.RedactionCount);
        Assert.HasCount(64, observation.RawPayloadSha256);
        Assert.IsFalse(observation.SummaryTruncated);
    }
}
