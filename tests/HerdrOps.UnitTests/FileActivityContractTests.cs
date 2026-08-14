using HerdrOps.Domain.Activity;

namespace HerdrOps.UnitTests;

[TestClass]
public sealed class FileActivityContractTests
{
    [TestMethod]
    public void AuthorizedObservationNormalizesSeparatorsAndKeepsProvenance()
    {
        var observation = FileActivityContract.NormalizeAndValidate(new FileActivityObservation(
            1,
            new DateTimeOffset(2026, 8, 15, 1, 0, 0, TimeSpan.Zero),
            FileActivityOperation.Modified,
            "src\\service.cs",
            null,
            ActivitySourceKind.FileSystem,
            "filesystem:ABCDEF0123456789",
            ActivityConfidence.Observed,
            true,
            "authorized"));

        Assert.AreEqual("src/service.cs", observation.RelativePath);
        Assert.AreEqual(ActivitySourceKind.FileSystem, observation.SourceKind);
        Assert.AreEqual(ActivityConfidence.Observed, observation.Confidence);
        Assert.IsTrue(observation.IsAuthorized);
    }

    [TestMethod]
    public void BlockedObservationCannotRetainRejectedPath()
    {
        Assert.ThrowsExactly<ArgumentException>(() =>
            FileActivityContract.NormalizeAndValidate(new FileActivityObservation(
                1,
                new DateTimeOffset(2026, 8, 15, 1, 0, 0, TimeSpan.Zero),
                FileActivityOperation.ScopeBlocked,
                "C:/secrets.txt",
                null,
                ActivitySourceKind.FileSystem,
                "filesystem:ABCDEF0123456789",
                ActivityConfidence.Observed,
                false,
                "outside-declared-root")));

        Assert.ThrowsExactly<ArgumentException>(() =>
            FileActivityContract.NormalizeAndValidate(new FileActivityObservation(
                1,
                new DateTimeOffset(2026, 8, 15, 1, 0, 0, TimeSpan.Zero),
                FileActivityOperation.ScopeBlocked,
                "[blocked]",
                "C:/previous-secret.txt",
                ActivitySourceKind.FileSystem,
                "filesystem:ABCDEF0123456789",
                ActivityConfidence.Observed,
                false,
                "previous-outside-declared-root")));
    }

    [TestMethod]
    public void AuthorizedObservationRejectsParentTraversal()
    {
        Assert.ThrowsExactly<ArgumentException>(() =>
            FileActivityContract.NormalizeAndValidate(new FileActivityObservation(
                1,
                new DateTimeOffset(2026, 8, 15, 1, 0, 0, TimeSpan.Zero),
                FileActivityOperation.Read,
                "../outside.txt",
                null,
                ActivitySourceKind.Git,
                "git:ABCDEF0123456789",
                ActivityConfidence.Observed,
                true,
                "authorized")));

        Assert.ThrowsExactly<ArgumentException>(() =>
            FileActivityContract.NormalizeAndValidate(new FileActivityObservation(
                1,
                new DateTimeOffset(2026, 8, 15, 1, 0, 0, TimeSpan.Zero),
                FileActivityOperation.Read,
                "C:drive-relative-secret.txt",
                null,
                ActivitySourceKind.Git,
                "git:ABCDEF0123456789",
                ActivityConfidence.Observed,
                true,
                "authorized")));
    }

    [TestMethod]
    public void AuthorizationOperationAndCorrelationClaimsMustAgree()
    {
        var observedUtc = new DateTimeOffset(2026, 8, 15, 1, 0, 0, TimeSpan.Zero);
        Assert.ThrowsExactly<ArgumentException>(() =>
            FileActivityContract.NormalizeAndValidate(new FileActivityObservation(
                1,
                observedUtc,
                FileActivityOperation.Modified,
                "[blocked]",
                null,
                ActivitySourceKind.FileSystem,
                "filesystem:ABCDEF0123456789",
                ActivityConfidence.Observed,
                false,
                "outside-declared-root")));
        Assert.ThrowsExactly<ArgumentException>(() =>
            FileActivityContract.NormalizeAndValidate(new FileActivityObservation(
                2,
                observedUtc,
                FileActivityOperation.Modified,
                "src/service.cs",
                null,
                ActivitySourceKind.FileSystem,
                "filesystem:ABCDEF0123456789",
                ActivityConfidence.Correlated,
                true,
                "authorized")));
    }

    [TestMethod]
    public void CorrelatorAssignsUniqueRecentWorkingDirectoryContext()
    {
        var observedUtc = new DateTimeOffset(2026, 8, 15, 1, 0, 10, TimeSpan.Zero);
        var observation = FileActivityContract.NormalizeAndValidate(new FileActivityObservation(
            1,
            observedUtc,
            FileActivityOperation.Modified,
            "src/services/AuthService.cs",
            null,
            ActivitySourceKind.FileSystem,
            "filesystem:ABCDEF0123456789",
            ActivityConfidence.Observed,
            true,
            "authorized"));
        var context = new FileActivityCorrelationContext(
            "terminal-backend-01",
            "TASK-115",
            "src/services",
            observedUtc.AddSeconds(-2),
            "Herdr pane process current directory");

        var correlated = new FileActivityCorrelator().Correlate(observation, [context]);

        Assert.AreEqual("terminal-backend-01", correlated.AgentTerminalId);
        Assert.AreEqual("TASK-115", correlated.TaskId);
        Assert.AreEqual(ActivityConfidence.Correlated, correlated.Confidence);
        Assert.AreEqual("Herdr pane process current directory", correlated.CorrelationEvidenceSource);
        Assert.AreEqual(context.ObservedUtc, correlated.CorrelationObservedUtc);
    }

    [TestMethod]
    public void CorrelatorFailsClosedForAmbiguousOrExpiredContexts()
    {
        var observedUtc = new DateTimeOffset(2026, 8, 15, 1, 0, 10, TimeSpan.Zero);
        var observation = FileActivityContract.NormalizeAndValidate(new FileActivityObservation(
            1,
            observedUtc,
            FileActivityOperation.Modified,
            "src/AuthService.cs",
            null,
            ActivitySourceKind.Git,
            "git:ABCDEF0123456789",
            ActivityConfidence.Observed,
            true,
            "authorized"));
        var contexts = new[]
        {
            new FileActivityCorrelationContext("terminal-1", "TASK-1", "src", observedUtc.AddSeconds(-1), "pane cwd"),
            new FileActivityCorrelationContext("terminal-2", "TASK-2", "src", observedUtc.AddSeconds(-2), "pane cwd"),
            new FileActivityCorrelationContext("terminal-old", "TASK-OLD", "src", observedUtc.AddMinutes(-1), "pane cwd"),
        };

        var result = new FileActivityCorrelator().Correlate(observation, contexts);

        Assert.IsNull(result.AgentTerminalId);
        Assert.IsNull(result.TaskId);
        Assert.IsNull(result.CorrelationEvidenceSource);
        Assert.IsNull(result.CorrelationObservedUtc);
        Assert.AreEqual(ActivityConfidence.Observed, result.Confidence);
    }
}
