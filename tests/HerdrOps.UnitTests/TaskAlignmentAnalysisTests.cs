using HerdrOps.Domain.Activity;
using HerdrOps.Domain.Assignments;

namespace HerdrOps.UnitTests;

[TestClass]
public sealed class TaskAlignmentAnalysisTests
{
    private static readonly DateTimeOffset BaseUtc =
        new(2026, 8, 15, 2, 0, 0, TimeSpan.Zero);

    [TestMethod]
    public void AnalysisIsDeterministicAndEveryConclusionRetainsSupportingInputs()
    {
        var replay = AssignmentLifecycleReplay.Run(AssignmentLifecycleTests.CompleteTrace());
        var contract = CreateContract(replay);
        var request = new TaskAlignmentAnalysisRequest(
            replay,
            contract,
            [
                CreateAction(1, "STEP-1", TaskAlignmentActionOutcome.Completed),
                CreateAction(2, "STEP-2", TaskAlignmentActionOutcome.Started),
            ],
            [CreateFile(1, "src/backend/AuthService.cs")],
            [],
            []);

        var first = TaskAlignmentAnalyzer.Analyze(request);
        var second = TaskAlignmentAnalyzer.Analyze(request);

        Assert.AreEqual(TaskAlignmentVerdictKind.PartiallyMisaligned, first.Verdict.Kind);
        Assert.AreEqual(80, first.GoalAlignmentScore);
        Assert.AreEqual(100, first.ScopeComplianceScore);
        Assert.AreEqual(50, first.AcceptanceCriteriaScore);
        Assert.AreEqual(first.AnalysisSha256, second.AnalysisSha256);
        Assert.AreEqual(first.ContractSha256, second.ContractSha256);
        Assert.AreEqual(first.LifecycleGraphSha256, second.LifecycleGraphSha256);
        Assert.AreEqual(64, first.AnalysisSha256.Length);
        Assert.IsTrue(first.Findings.All(item => item.SupportingInputIds.Count > 0));
        Assert.IsNotEmpty(first.Verdict.SupportingInputIds);
        Assert.IsTrue(first.Verdict.SupportingInputIds.Contains("action:2"));
        Assert.IsTrue(first.Findings.Any(item =>
            item.Code == TaskAlignmentFindingCode.AcceptanceMissing &&
            item.SupportingInputIds.Contains("contract:criterion:AC-2")));
    }

    [TestMethod]
    public void MissingObservationsCannotBecomePassingScoresOrVerdict()
    {
        var assignment = AssignmentLifecycleTests.CreateEvent(
            AssignmentLifecycleEventKind.Assignment,
            sequence: 1,
            actorId: "project-manager",
            actorRole: "Project Manager",
            targetAgentId: "backend-worker-01");
        var replay = AssignmentLifecycleReplay.Run([assignment]);
        var contract = CreateContract(replay);

        var result = TaskAlignmentAnalyzer.Analyze(new TaskAlignmentAnalysisRequest(
            replay,
            contract,
            [],
            [],
            [],
            []));

        Assert.AreEqual(TaskAlignmentVerdictKind.InsufficientData, result.Verdict.Kind);
        Assert.IsNull(result.GoalAlignmentScore);
        Assert.IsNull(result.ScopeComplianceScore);
        Assert.IsNull(result.AcceptanceCriteriaScore);
        Assert.IsTrue(result.HasMissingRequiredData);
        CollectionAssert.IsSubsetOf(
            new[]
            {
                TaskAlignmentFindingCode.AcknowledgementMissing,
                TaskAlignmentFindingCode.ObservedActionsMissing,
                TaskAlignmentFindingCode.FileObservationsMissing,
                TaskAlignmentFindingCode.EvidenceMissing,
            },
            result.Findings.Select(item => item.Code).ToArray());
    }

    [TestMethod]
    public void OutOfScopeObservationIsSuspectedUntilReviewConfirmsViolation()
    {
        var replay = AssignmentLifecycleReplay.Run(AssignmentLifecycleTests.CompleteTrace());
        var contract = CreateSingleCriterionContract(replay);
        var outOfScope = CreateFile(2, "docs/private/notes.md");
        var request = new TaskAlignmentAnalysisRequest(
            replay,
            contract,
            [
                CreateAction(1, "STEP-1", TaskAlignmentActionOutcome.Completed),
                CreateAction(2, "STEP-2", TaskAlignmentActionOutcome.Completed),
            ],
            [CreateFile(1, "src/backend/AuthService.cs"), outOfScope],
            [],
            []);

        var suspected = TaskAlignmentAnalyzer.Analyze(request);
        var fileInput = TaskAlignmentAnalyzer.FileInputId(outOfScope);
        var review = new TaskAlignmentReviewDecision(
            "review:1",
            fileInput,
            TaskAlignmentReviewDecisionKind.ConfirmedViolation,
            "project-manager",
            BaseUtc.AddMinutes(10),
            AssignmentLifecycleTests.Hash("review-1"));
        var confirmed = TaskAlignmentAnalyzer.Analyze(request with
        {
            ReviewDecisions = [review],
        });

        Assert.AreEqual(TaskAlignmentVerdictKind.SuspectedViolation, suspected.Verdict.Kind);
        Assert.AreEqual(TaskAlignmentVerdictKind.ConfirmedViolation, confirmed.Verdict.Kind);
        Assert.AreNotEqual(suspected.AnalysisSha256, confirmed.AnalysisSha256);
        var finding = confirmed.Findings.Single(item =>
            item.Code == TaskAlignmentFindingCode.ScopeConfirmedViolation);
        CollectionAssert.IsSubsetOf(
            new[] { fileInput, "review:1" },
            finding.SupportingInputIds.ToArray());
        CollectionAssert.IsSubsetOf(
            new[] { fileInput, "review:1" },
            confirmed.Verdict.SupportingInputIds.ToArray());
    }

    [TestMethod]
    public void ApprovedDeviationCanAuthorizeOnlyItsLinkedPathAndRetainsLifecycleProvenance()
    {
        var assignment = AssignmentLifecycleTests.CreateEvent(
            AssignmentLifecycleEventKind.Assignment,
            sequence: 1,
            actorId: "project-manager",
            actorRole: "Project Manager",
            targetAgentId: "backend-worker-01");
        var acknowledgement = AssignmentLifecycleTests.CreateEvent(
            AssignmentLifecycleEventKind.Acknowledgement,
            sequence: 2,
            actorId: "backend-worker-01",
            actorRole: "Backend Worker",
            parentEventId: assignment.EventId);
        var deviation = AssignmentLifecycleTests.CreateEvent(
            AssignmentLifecycleEventKind.Deviation,
            sequence: 3,
            actorId: "backend-worker-01",
            actorRole: "Backend Worker",
            parentEventId: acknowledgement.EventId,
            deviationReason: "Documentation is required for operator handoff.");
        var evidence = AssignmentLifecycleTests.CreateEvent(
            AssignmentLifecycleEventKind.Evidence,
            sequence: 4,
            actorId: "backend-worker-01",
            actorRole: "Backend Worker",
            parentEventId: deviation.EventId,
            evidenceReference: "artifacts/tests/self-report.trx",
            evidenceSha256: AssignmentLifecycleTests.Hash("approved-deviation-evidence"));
        var replay = AssignmentLifecycleReplay.Run(
            [assignment, acknowledgement, deviation, evidence]);
        var contract = CreateSingleCriterionContract(replay);
        var decision = new TaskAlignmentDeviationDecision(
            "deviation-decision:1",
            deviation.EventId,
            TaskAlignmentDeviationDecisionKind.Approved,
            "docs/private",
            BaseUtc.AddMinutes(10),
            AssignmentLifecycleTests.Hash("deviation-decision-1"));

        var result = TaskAlignmentAnalyzer.Analyze(new TaskAlignmentAnalysisRequest(
            replay,
            contract,
            [
                CreateAction(1, "STEP-1", TaskAlignmentActionOutcome.Completed),
                CreateAction(2, "STEP-2", TaskAlignmentActionOutcome.Completed),
            ],
            [CreateFile(2, "docs/private/operator-runbook.md")],
            [decision],
            []));

        Assert.AreEqual(TaskAlignmentVerdictKind.Aligned, result.Verdict.Kind);
        Assert.AreEqual(100, result.ScopeComplianceScore);
        var finding = result.Findings.Single(item =>
            item.Code == TaskAlignmentFindingCode.ScopeApprovedDeviation);
        CollectionAssert.Contains(
            finding.SupportingInputIds.ToArray(),
            "deviation-decision:1");
        CollectionAssert.Contains(
            finding.SupportingInputIds.ToArray(),
            TaskAlignmentAnalyzer.LifecycleInputId(deviation.EventId));
    }

    [TestMethod]
    public void MissingLifecycleEvidenceCannotSatisfyAcceptanceCriteria()
    {
        var traceWithoutEvidence = AssignmentLifecycleTests.CompleteTrace().Take(5).ToArray();
        var replay = AssignmentLifecycleReplay.Run(traceWithoutEvidence);
        var contract = CreateSingleCriterionContract(replay);

        var result = TaskAlignmentAnalyzer.Analyze(new TaskAlignmentAnalysisRequest(
            replay,
            contract,
            [
                CreateAction(1, "STEP-1", TaskAlignmentActionOutcome.Completed),
                CreateAction(2, "STEP-2", TaskAlignmentActionOutcome.Completed),
            ],
            [CreateFile(1, "src/backend/AuthService.cs")],
            [],
            []));

        Assert.AreEqual(TaskAlignmentVerdictKind.InsufficientData, result.Verdict.Kind);
        Assert.IsNull(result.AcceptanceCriteriaScore);
        Assert.IsTrue(result.HasMissingRequiredData);
        Assert.IsTrue(result.Findings.Any(item =>
            item.Code == TaskAlignmentFindingCode.EvidenceMissing));
        Assert.IsFalse(result.Findings.Any(item =>
            item.Code == TaskAlignmentFindingCode.AcceptanceSatisfied));
    }

    [TestMethod]
    public void AnalyzerRejectsContractWhoseCanonicalBytesWereChangedAfterSigning()
    {
        var replay = AssignmentLifecycleReplay.Run(AssignmentLifecycleTests.CompleteTrace());
        var contract = CreateContract(replay) with { Goal = "Forged goal" };

        var exception = Assert.ThrowsExactly<TaskAlignmentContractException>(() =>
            TaskAlignmentAnalyzer.Analyze(new TaskAlignmentAnalysisRequest(
                replay,
                contract,
                [],
                [],
                [],
                [])));

        StringAssert.Contains(exception.Message, "SHA-256");
    }

    [TestMethod]
    public void AnalyzerRejectsContractThatTargetsAnUnknownLifecycleTask()
    {
        var replay = AssignmentLifecycleReplay.Run(AssignmentLifecycleTests.CompleteTrace());
        var current = replay.CurrentTasks.Single().State.Contract;
        var contract = TaskAlignmentContractRules.Create(
            "TASK-404",
            current.AssignmentEventId,
            current.ProvenanceEventSha256,
            "Unknown task",
            [new TaskAlignmentScopeRule(
                "SCOPE-1",
                TaskAlignmentScopeRuleKind.AllowPathPrefix,
                "src/backend",
                "Backend source")],
            [new TaskAlignmentConstraint("CONSTRAINT-1", "Stay inside the repository")],
            [new TaskAlignmentPlannedStep("STEP-1", "Implement", 100)],
            [new TaskAlignmentAcceptanceCriterion("AC-1", "Tests pass", 100, ["self-report.trx"])],
            BaseUtc);

        var exception = Assert.ThrowsExactly<TaskAlignmentContractException>(() =>
            TaskAlignmentAnalyzer.Analyze(new TaskAlignmentAnalysisRequest(
                replay,
                contract,
                [],
                [],
                [],
                [])));

        StringAssert.Contains(exception.Message, "current lifecycle assignment provenance");
    }

    private static TaskAlignmentContract CreateContract(AssignmentLifecycleReplayResult replay)
    {
        var taskContract = replay.CurrentTasks.Single().State.Contract;
        return TaskAlignmentContractRules.Create(
            taskContract.TaskId,
            taskContract.AssignmentEventId,
            taskContract.ProvenanceEventSha256,
            "Implement the backend authentication service with contract-backed evidence.",
            [
                new TaskAlignmentScopeRule(
                    "SCOPE-BACKEND",
                    TaskAlignmentScopeRuleKind.AllowPathPrefix,
                    "src/backend",
                    "Backend source files"),
                new TaskAlignmentScopeRule(
                    "SCOPE-GENERATED",
                    TaskAlignmentScopeRuleKind.DenyPathPrefix,
                    "src/backend/generated",
                    "Generated files are read-only"),
            ],
            [new TaskAlignmentConstraint("CONSTRAINT-1", "Do not change the database schema")],
            [
                new TaskAlignmentPlannedStep("STEP-1", "Implement the service", 60),
                new TaskAlignmentPlannedStep("STEP-2", "Run verification", 40),
            ],
            [
                new TaskAlignmentAcceptanceCriterion(
                    "AC-1",
                    "Unit test evidence is attached",
                    50,
                    ["self-report.trx"]),
                new TaskAlignmentAcceptanceCriterion(
                    "AC-2",
                    "Coverage evidence is attached",
                    50,
                    ["coverage.xml"]),
            ],
            BaseUtc);
    }

    private static TaskAlignmentContract CreateSingleCriterionContract(
        AssignmentLifecycleReplayResult replay)
    {
        var taskContract = replay.CurrentTasks.Single().State.Contract;
        return TaskAlignmentContractRules.Create(
            taskContract.TaskId,
            taskContract.AssignmentEventId,
            taskContract.ProvenanceEventSha256,
            "Implement the backend authentication service with contract-backed evidence.",
            [new TaskAlignmentScopeRule(
                "SCOPE-BACKEND",
                TaskAlignmentScopeRuleKind.AllowPathPrefix,
                "src/backend",
                "Backend source files")],
            [new TaskAlignmentConstraint("CONSTRAINT-1", "Do not change the database schema")],
            [
                new TaskAlignmentPlannedStep("STEP-1", "Implement the service", 60),
                new TaskAlignmentPlannedStep("STEP-2", "Run verification", 40),
            ],
            [new TaskAlignmentAcceptanceCriterion(
                "AC-1",
                "Unit test evidence is attached",
                100,
                ["self-report.trx"])],
            BaseUtc);
    }

    private static TaskAlignmentActionObservation CreateAction(
        long sequence,
        string stepId,
        TaskAlignmentActionOutcome outcome)
    {
        var envelope = new ActivityEventEnvelope(
            ActivityEventContract.Version,
            $"alignment-action-{sequence}",
            ActivitySourceKind.Herdr,
            "herdr:alignment-tests",
            "epoch-1",
            sequence,
            ActivityConfidence.Observed,
            ActivityUrgency.Normal,
            ActivityDeliveryMode.Immediate,
            "task.step.observed",
            BaseUtc.AddSeconds(sequence),
            BaseUtc.AddSeconds(sequence + 1),
            AssignmentLifecycleTests.GuidFor(500 + (int)sequence),
            null,
            "backend-worker-01",
            "pane-1",
            "TASK-115",
            null,
            $"Observed {stepId} as {outcome}.",
            AssignmentLifecycleTests.Hash($"action-{sequence}"));
        return new TaskAlignmentActionObservation(
            $"action:{sequence}",
            ActivityEventContract.NormalizeAndValidate(envelope, sequence),
            stepId,
            outcome);
    }

    private static FileActivityObservation CreateFile(long sequence, string relativePath) =>
        new(
            sequence,
            BaseUtc.AddMinutes(sequence),
            FileActivityOperation.Modified,
            relativePath,
            null,
            ActivitySourceKind.FileSystem,
            "filesystem:alignment-tests",
            ActivityConfidence.Correlated,
            true,
            "authorized-repository-root",
            "backend-worker-01",
            "TASK-115",
            "Herdr pane working-directory correlation",
            BaseUtc.AddMinutes(sequence).AddSeconds(-1));
}
