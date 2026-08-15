using HerdrOps.Contracts.SelfReport;
using HerdrOps.Core;
using HerdrOps.Domain.Assignments;

namespace HerdrOps.IntegrationTests;

[TestClass]
public sealed class AssignmentLifecycleMappingTests
{
    private static readonly DateTimeOffset BaseUtc =
        new(2026, 8, 15, 4, 0, 0, TimeSpan.Zero);

    [TestMethod]
    public void AcceptedSelfReportsMapEveryEventTypeWithoutLosingCoreIdentity()
    {
        var submissions = CompleteTrace();
        var acceptance = new HerdrOpsSelfReportAcceptanceService(
            new InMemoryHerdrOpsTaskRegistry(["TASK-115"]),
            new FixedTimeProvider(BaseUtc.AddMinutes(1)));
        for (var index = 0; index < submissions.Count; index++)
        {
            var result = acceptance.Accept(submissions[index], GuidFor(100 + index));
            Assert.IsTrue(result.Accepted, result.Message);
        }

        var mapped = acceptance.AcceptedEvents
            .Select(HerdrOpsAssignmentLifecycleMapper.Map)
            .ToArray();
        var replay = AssignmentLifecycleReplay.Run(mapped);

        CollectionAssert.AreEquivalent(
            Enum.GetValues<AssignmentLifecycleEventKind>(),
            mapped.Select(item => item.EventKind).Distinct().ToArray());
        Assert.AreEqual(8L, replay.Diagnostics.AppliedEventCount);
        Assert.AreEqual(3, replay.Diagnostics.RelationshipCount);
        Assert.AreEqual(8, replay.Diagnostics.RoleObservationCount);
        Assert.AreEqual(AssignmentTaskStatus.HandedOff, replay.CurrentTasks[0].State.Status);
        for (var index = 0; index < mapped.Length; index++)
        {
            var accepted = acceptance.AcceptedEvents[index];
            var lifecycle = mapped[index];
            Assert.AreEqual(accepted.Sequence, lifecycle.Sequence);
            Assert.AreEqual(accepted.AcceptedUtc, lifecycle.AcceptedUtc);
            Assert.AreEqual(accepted.Source, lifecycle.Source);
            Assert.AreEqual(accepted.CorrelationId, lifecycle.CorrelationId);
            Assert.AreEqual(accepted.EventSha256, lifecycle.EventSha256);
            Assert.AreEqual(accepted.Submission.EventId, lifecycle.EventId);
        }
    }

    [TestMethod]
    public void MapperRejectsAcceptanceIdentityThatWasNotOwnedByCore()
    {
        var submission = CompleteTrace()[0];
        var accepted = new HerdrOpsAcceptedSelfReport(
            Sequence: 1,
            AcceptedUtc: BaseUtc.AddMinutes(1),
            Source: "Untrusted.Source",
            CorrelationId: GuidFor(100),
            EventSha256: HerdrOpsSelfReportJson.ComputeSha256(submission),
            Submission: submission);

        var exception = Assert.Throws<AssignmentLifecycleContractException>(() =>
            HerdrOpsAssignmentLifecycleMapper.Map(accepted));
        StringAssert.Contains(exception.Message, "source must be HerdrOps.Core");
    }

    [TestMethod]
    public void MapperRejectsAcceptanceHashThatDoesNotBindSubmission()
    {
        var submission = CompleteTrace()[0];
        var accepted = new HerdrOpsAcceptedSelfReport(
            Sequence: 1,
            AcceptedUtc: BaseUtc.AddMinutes(1),
            Source: HerdrOpsSelfReportProtocol.CoreSource,
            CorrelationId: GuidFor(100),
            EventSha256: new string('A', 64),
            Submission: submission);

        var exception = Assert.Throws<AssignmentLifecycleContractException>(() =>
            HerdrOpsAssignmentLifecycleMapper.Map(accepted));
        StringAssert.Contains(exception.Message, "does not match its submission content");
    }

    [TestMethod]
    public void CoreRejectsFutureOccurrenceWithoutAdvancingAcceptanceSequence()
    {
        var acceptance = new HerdrOpsSelfReportAcceptanceService(
            new InMemoryHerdrOpsTaskRegistry(["TASK-115"]),
            new FixedTimeProvider(BaseUtc));
        var future = CompleteTrace()[0] with
        {
            OccurredUtc = BaseUtc.AddSeconds(1),
        };

        var result = acceptance.Accept(future, GuidFor(100));

        Assert.IsFalse(result.Accepted);
        Assert.AreEqual(HerdrOpsSelfReportProtocol.ResultCodes.InvalidSchema, result.Code);
        Assert.AreEqual(0L, acceptance.LastSequence);
        Assert.IsEmpty(acceptance.AcceptedEvents);
    }

    private static IReadOnlyList<HerdrOpsSelfReportSubmission> CompleteTrace()
    {
        var assignment = CreateSubmission(
            HerdrOpsSelfReportProtocol.EventTypes.Assignment,
            1,
            "project-manager",
            "Project Manager",
            targetAgentId: "backend-leader");
        var leaderAcknowledgement = CreateSubmission(
            HerdrOpsSelfReportProtocol.EventTypes.Acknowledgement,
            2,
            "backend-leader",
            "Backend Leader",
            parentEventId: assignment.EventId);
        var delegation = CreateSubmission(
            HerdrOpsSelfReportProtocol.EventTypes.Delegation,
            3,
            "backend-leader",
            "Backend Leader",
            parentEventId: leaderAcknowledgement.EventId,
            targetAgentId: "backend-worker-01");
        var workerAcknowledgement = CreateSubmission(
            HerdrOpsSelfReportProtocol.EventTypes.Acknowledgement,
            4,
            "backend-worker-01",
            "Backend Worker",
            parentEventId: delegation.EventId);
        var progress = CreateSubmission(
            HerdrOpsSelfReportProtocol.EventTypes.Progress,
            5,
            "backend-worker-01",
            "Backend Worker",
            parentEventId: workerAcknowledgement.EventId,
            progressPercent: 75);
        var deviation = CreateSubmission(
            HerdrOpsSelfReportProtocol.EventTypes.Deviation,
            6,
            "backend-worker-01",
            "Backend Worker",
            parentEventId: progress.EventId,
            deviationReason: "A scoped deviation was approved for review.");
        var evidence = CreateSubmission(
            HerdrOpsSelfReportProtocol.EventTypes.Evidence,
            7,
            "backend-worker-01",
            "Backend Worker",
            parentEventId: deviation.EventId,
            evidenceReference: "artifacts/tests/mapping.trx",
            evidenceSha256: new string('B', 64));
        var handoff = CreateSubmission(
            HerdrOpsSelfReportProtocol.EventTypes.Handoff,
            8,
            "backend-worker-01",
            "Backend Worker",
            parentEventId: evidence.EventId,
            targetAgentId: "reviewer-01",
            handoffNote: "Ready for review.");
        return
        [
            assignment,
            leaderAcknowledgement,
            delegation,
            workerAcknowledgement,
            progress,
            deviation,
            evidence,
            handoff,
        ];
    }

    private static HerdrOpsSelfReportSubmission CreateSubmission(
        string eventType,
        int sequence,
        string actorId,
        string actorRole,
        Guid? parentEventId = null,
        string? targetAgentId = null,
        int? progressPercent = null,
        string? deviationReason = null,
        string? evidenceReference = null,
        string? evidenceSha256 = null,
        string? handoffNote = null) => new(
        HerdrOpsSelfReportProtocol.Version,
        GuidFor(sequence),
        eventType,
        "TASK-115",
        actorId,
        actorRole,
        BaseUtc.AddSeconds(sequence),
        $"Mapped lifecycle event {sequence}.",
        parentEventId,
        targetAgentId,
        progressPercent,
        deviationReason,
        evidenceReference,
        evidenceSha256,
        handoffNote);

    private static Guid GuidFor(int value) =>
        Guid.Parse($"00000000-0000-0000-0000-{value:000000000000}");
}
