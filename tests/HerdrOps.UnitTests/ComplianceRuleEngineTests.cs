using HerdrOps.Domain.Compliance;

namespace HerdrOps.UnitTests;

[TestClass]
public sealed class ComplianceRuleEngineTests
{
    private static readonly DateTimeOffset BaseUtc =
        new(2026, 8, 15, 7, 0, 0, TimeSpan.Zero);

    [TestMethod]
    public void VersionOneRuleSetPublishesExactSeverityMappingAndStableHash()
    {
        var first = ComplianceRuleSetContract.NormalizeAndValidate(
            ComplianceRuleSetContract.Version1);
        var second = ComplianceRuleSetContract.NormalizeAndValidate(first);

        Assert.AreEqual(ComplianceRuleSetContract.RuleSetId, first.RuleSetId);
        Assert.AreEqual(ComplianceRuleSetContract.RuleSetVersion, first.RuleSetVersion);
        Assert.AreEqual(64, first.RuleSetSha256.Length);
        Assert.AreEqual(first.RuleSetSha256, second.RuleSetSha256);
        Assert.HasCount(4, first.Rules);
        Assert.AreEqual(
            ComplianceSeverity.Critical,
            first.Rules.Single(item =>
                item.RuleKind == ComplianceRuleKind.ScopeViolation).Severity);
        Assert.AreEqual(
            ComplianceSeverity.High,
            first.Rules.Single(item =>
                item.RuleKind == ComplianceRuleKind.MissingEvidence).Severity);
        Assert.AreEqual(
            ComplianceSeverity.Medium,
            first.Rules.Single(item =>
                item.RuleKind == ComplianceRuleKind.UnapprovedDeviation).Severity);
        Assert.AreEqual(
            ComplianceSeverity.High,
            first.Rules.Single(item =>
                item.RuleKind == ComplianceRuleKind.ReviewOrder).Severity);
    }

    [TestMethod]
    public void CompliantInputsPassEveryRuleWithoutCreatingIncidentCandidate()
    {
        var result = new ComplianceRuleEngine().Evaluate(CreateCompliantRequest());

        Assert.AreEqual(4, result.Diagnostics.RuleCount);
        Assert.AreEqual(4, result.Diagnostics.PassedRuleCount);
        Assert.AreEqual(0, result.Diagnostics.ProducedFindingCount);
        Assert.AreEqual(0, result.Diagnostics.ErrorRuleCount);
        Assert.AreEqual(0, result.Diagnostics.ConfirmedFindingCount);
        Assert.AreEqual(64, result.RequestSha256.Length);
        Assert.AreEqual(64, result.ResultSha256.Length);
        Assert.IsTrue(result.RuleEvaluations.All(item =>
            item.Outcome == ComplianceRuleOutcomeKind.Passed));
    }

    [TestMethod]
    public void PendingOutOfScopeDeviationCreatesTwoSuspectedExplainableFindings()
    {
        var request = CreateCompliantRequest() with
        {
            Actions =
            [
                new ComplianceActionObservation(
                    "action:outside",
                    "docs/private/operator.md",
                    BaseUtc.AddMinutes(5),
                    "DEV-PENDING"),
            ],
            Deviations =
            [
                new ComplianceDeviationDecision(
                    "deviation:pending",
                    "DEV-PENDING",
                    "docs/private",
                    ComplianceDeviationDecisionKind.Pending,
                    BaseUtc,
                    null),
            ],
        };

        var result = new ComplianceRuleEngine().Evaluate(request);

        Assert.HasCount(2, result.Findings);
        CollectionAssert.AreEquivalent(
            new[]
            {
                ComplianceRuleKind.ScopeViolation,
                ComplianceRuleKind.UnapprovedDeviation,
            },
            result.Findings.Select(item => item.RuleKind).ToArray());
        Assert.IsTrue(result.Findings.All(item =>
            item.State == ComplianceFindingState.Suspected &&
            item.SupportingFacts.Count >= 2 &&
            item.ExplainabilitySha256.Length == 64 &&
            item.RuleVersion == ComplianceRuleSetContract.RuleVersion));
        Assert.AreEqual(0, result.Diagnostics.ConfirmedFindingCount);
    }

    [TestMethod]
    public void MissingEvidenceFindingRecordsRequirementAndRejectedSubmissionFacts()
    {
        var request = CreateCompliantRequest() with
        {
            EvidenceSubmissions =
            [
                new ComplianceEvidenceSubmission(
                    "submission:rejected",
                    "EVIDENCE-1",
                    "REQ-TEST",
                    false),
            ],
        };

        var result = new ComplianceRuleEngine().Evaluate(request);
        var finding = result.Findings.Single(item =>
            item.RuleKind == ComplianceRuleKind.MissingEvidence);

        Assert.AreEqual(ComplianceSeverity.High, finding.Severity);
        Assert.HasCount(2, finding.SupportingFacts);
        CollectionAssert.AreEquivalent(
            new[] { "requirement:test", "submission:rejected" },
            finding.SupportingFacts.Select(item => item.InputId).ToArray());
        StringAssert.StartsWith(finding.Subject, "requirement:");
    }

    [TestMethod]
    public void ReviewOrderViolationRetainsOffendingReviewFact()
    {
        var request = CreateCompliantRequest() with
        {
            ReviewObservations =
            [
                new ComplianceReviewObservation(
                    "review:pm-decision",
                    1,
                    ComplianceReviewActionKind.ProjectManagerDecision,
                    "project-manager",
                    BaseUtc.AddMinutes(10)),
            ],
        };

        var result = new ComplianceRuleEngine().Evaluate(request);
        var finding = result.Findings.Single(item =>
            item.RuleKind == ComplianceRuleKind.ReviewOrder);

        Assert.AreEqual(ComplianceFindingState.Suspected, finding.State);
        Assert.AreEqual(ComplianceSeverity.High, finding.Severity);
        Assert.AreEqual("review:pm-decision", finding.SupportingFacts.Single().InputId);
    }

    [TestMethod]
    public void RepeatedDetectionUsesStableIdentityAndSuppressesDuplicate()
    {
        var request = PendingDeviationRequest();
        var engine = new ComplianceRuleEngine();

        var first = engine.Evaluate(request);
        var second = engine.Evaluate(
            request,
            first.Findings.Select(item => item.FindingId).ToArray());

        Assert.HasCount(2, first.Findings);
        Assert.IsEmpty(second.Findings);
        Assert.AreEqual(2, second.Diagnostics.DuplicateDetectionCount);
        Assert.AreEqual(2, second.Diagnostics.DuplicateSuppressedRuleCount);
        CollectionAssert.AreEquivalent(
            first.Findings.Select(item => item.FindingId).ToArray(),
            second.RuleEvaluations
                .SelectMany(item => item.SuppressedFindingIds)
                .ToArray());
        Assert.AreNotEqual(first.ResultSha256, second.ResultSha256);
    }

    [TestMethod]
    public void SameOutOfScopeTargetWithinOneRequestIsDeduplicated()
    {
        var request = CreateCompliantRequest() with
        {
            Actions =
            [
                new ComplianceActionObservation(
                    "action:outside-1",
                    "docs/private/operator.md",
                    BaseUtc.AddMinutes(5),
                    null),
                new ComplianceActionObservation(
                    "action:outside-2",
                    "DOCS/PRIVATE/OPERATOR.MD",
                    BaseUtc.AddMinutes(6),
                    null),
            ],
            Deviations = [],
        };

        var result = new ComplianceRuleEngine().Evaluate(request);

        Assert.HasCount(1, result.Findings);
        Assert.AreEqual(1, result.Diagnostics.DuplicateDetectionCount);
        Assert.AreEqual(2, result.Findings[0].SupportingFacts.Count(item =>
            item.FactKind == ComplianceSupportingFactKind.ActionObservation));
    }

    [TestMethod]
    public void OrphanEvidenceSubmissionProducesObservableRuleErrorAndNoFinding()
    {
        var request = CreateCompliantRequest() with
        {
            EvidenceSubmissions =
            [
                new ComplianceEvidenceSubmission(
                    "submission:orphan",
                    "EVIDENCE-ORPHAN",
                    "REQ-UNKNOWN",
                    true),
            ],
        };

        var result = new ComplianceRuleEngine().Evaluate(request);
        var evaluation = result.RuleEvaluations.Single(item =>
            item.RuleKind == ComplianceRuleKind.MissingEvidence);

        Assert.AreEqual(ComplianceRuleOutcomeKind.Error, evaluation.Outcome);
        Assert.AreEqual("orphan-evidence-submission", evaluation.ErrorCode);
        CollectionAssert.Contains(
            evaluation.SupportingInputIds.ToArray(),
            "submission:orphan");
        Assert.IsFalse(result.Findings.Any(item =>
            item.RuleKind == ComplianceRuleKind.MissingEvidence));
        Assert.AreEqual(1, result.Diagnostics.ErrorRuleCount);
        Assert.AreEqual(0, result.Diagnostics.ConfirmedFindingCount);
    }

    [TestMethod]
    public void ReviewTimeRegressionProducesObservableRuleErrorWithoutIncident()
    {
        var request = CreateCompliantRequest() with
        {
            ReviewObservations =
            [
                new ComplianceReviewObservation(
                    "review:send",
                    1,
                    ComplianceReviewActionKind.SendToLeader,
                    "project-manager",
                    BaseUtc.AddMinutes(10)),
                new ComplianceReviewObservation(
                    "review:leader",
                    2,
                    ComplianceReviewActionKind.LeaderDecision,
                    "backend-leader",
                    BaseUtc.AddMinutes(9)),
            ],
        };

        var result = new ComplianceRuleEngine().Evaluate(request);
        var evaluation = result.RuleEvaluations.Single(item =>
            item.RuleKind == ComplianceRuleKind.ReviewOrder);

        Assert.AreEqual(ComplianceRuleOutcomeKind.Error, evaluation.Outcome);
        Assert.AreEqual("review-time-regression", evaluation.ErrorCode);
        Assert.IsFalse(result.Findings.Any(item =>
            item.RuleKind == ComplianceRuleKind.ReviewOrder));
    }

    [TestMethod]
    public void ApprovedDeviationMustExistBeforeActionAndCoverExactPrefixBoundary()
    {
        var baseline = CreateCompliantRequest();
        var action = new ComplianceActionObservation(
            "action:deviation",
            "docs/private/operator.md",
            BaseUtc.AddMinutes(5),
            "DEV-1");
        var lateDecision = new ComplianceDeviationDecision(
            "deviation:late",
            "DEV-1",
            "docs/private",
            ComplianceDeviationDecisionKind.Approved,
            BaseUtc,
            BaseUtc.AddMinutes(6));

        var lateResult = new ComplianceRuleEngine().Evaluate(baseline with
        {
            Actions = [action],
            Deviations = [lateDecision],
        });
        var onTimeResult = new ComplianceRuleEngine().Evaluate(baseline with
        {
            Actions = [action],
            Deviations = [lateDecision with { DecidedUtc = BaseUtc.AddMinutes(4) }],
        });

        Assert.HasCount(2, lateResult.Findings);
        Assert.IsEmpty(onTimeResult.Findings);
    }

    [TestMethod]
    public void ScopePrefixDoesNotMatchSiblingWithSameLeadingCharacters()
    {
        var request = CreateCompliantRequest() with
        {
            Actions =
            [
                new ComplianceActionObservation(
                    "action:sibling",
                    "src/backend-old/AuthService.cs",
                    BaseUtc.AddMinutes(1),
                    null),
            ],
            Deviations = [],
        };

        var result = new ComplianceRuleEngine().Evaluate(request);

        Assert.HasCount(1, result.Findings);
        Assert.AreEqual(ComplianceRuleKind.ScopeViolation, result.Findings[0].RuleKind);
    }

    [TestMethod]
    public void RequestCollectionOrderDoesNotChangeCanonicalResult()
    {
        var request = CreateCompliantRequest();
        var reordered = request with
        {
            ScopeBoundaries = request.ScopeBoundaries.Reverse().ToArray(),
            Actions = request.Actions.Reverse().ToArray(),
            Deviations = request.Deviations.Reverse().ToArray(),
            EvidenceRequirements = request.EvidenceRequirements.Reverse().ToArray(),
            EvidenceSubmissions = request.EvidenceSubmissions.Reverse().ToArray(),
            ReviewObservations = request.ReviewObservations.Reverse().ToArray(),
        };

        var first = new ComplianceRuleEngine().Evaluate(request);
        var second = new ComplianceRuleEngine().Evaluate(reordered);

        Assert.AreEqual(first.RequestSha256, second.RequestSha256);
        Assert.AreEqual(first.ResultSha256, second.ResultSha256);
    }

    [TestMethod]
    public void ChangedRuleDefinitionAndUnsafePathFailClosed()
    {
        var ruleSet = ComplianceRuleSetContract.Version1;
        var changedRules = ruleSet.Rules
            .Select(item => item.RuleKind == ComplianceRuleKind.ScopeViolation
                ? item with { Severity = ComplianceSeverity.Low }
                : item)
            .ToArray();
        var changedRuleSet = ruleSet with { Rules = changedRules };

        Assert.Throws<ComplianceRuleContractException>(() =>
            _ = new ComplianceRuleEngine(changedRuleSet));
        Assert.Throws<ComplianceRuleContractException>(() =>
            _ = new ComplianceRuleEngine().Evaluate(CreateCompliantRequest() with
            {
                Actions =
                [
                    new ComplianceActionObservation(
                        "action:unsafe",
                        "src/../secret.txt",
                        BaseUtc,
                        null),
                ],
            }));
    }

    [TestMethod]
    public void CompliancePathsRejectAllControlCharacters()
    {
        var controls = new[]
        {
            "\t",
            "\r",
            "\n",
            "\0",
            "\u0001",
            "\u001F",
            "\u007F",
            "\u0085",
        };

        foreach (var control in controls)
        {
            AssertPathRejected($"src/backend/Auth{control}Service.cs");
        }
    }

    [TestMethod]
    public void CompliancePathsRejectInvalidWindowsProjectRelativeForms()
    {
        var invalidPaths = new[]
        {
            @"\rooted\file.txt",
            "/rooted/file.txt",
            @"\\server\share\file.txt",
            "//server/share/file.txt",
            @"\\?\C:\device\file.txt",
            @"\\.\PIPE\device",
            @"C:\project\file.txt",
            "C:/project/file.txt",
            "C:project/file.txt",
            "src/invalid./file.txt",
            "src/invalid /file.txt",
            "src//file.txt",
            "src/./file.txt",
            @"src\..\file.txt",
        };

        foreach (var path in invalidPaths)
        {
            AssertPathRejected(path);
        }
    }

    [TestMethod]
    public void CompliancePathsRejectWindowsReservedDeviceNamesAndInvalidCharacters()
    {
        var invalidPaths = new[]
        {
            "src/CON",
            "src/con.txt",
            "src/PRN.log",
            "src/AUX",
            "src/NUL.json",
            "src/CLOCK$",
            "src/CONIN$",
            "src/CONOUT$",
            "src/COM1.txt",
            "src/com9",
            "src/COM¹.txt",
            "src/LPT1",
            "src/lpt9.md",
            "src/LPT³.log",
            "src/file?.txt",
            "src/file*.txt",
            "src/file<name>.txt",
            "src/file>name.txt",
            "src/file|name.txt",
            "src/file\"name.txt",
        };

        foreach (var path in invalidPaths)
        {
            AssertPathRejected(path);
        }
    }

    [TestMethod]
    public void LegitimateWindowsProjectPathsNormalizeSeparatorsAndRemainAccepted()
    {
        var normalized = ComplianceEvaluationContract.NormalizeAndValidate(
            CreateCompliantRequest() with
            {
                ScopeBoundaries =
                [
                    new ComplianceScopeBoundary("scope:backend", @"src\backend"),
                    new ComplianceScopeBoundary("scope:tests", @"tests\backend"),
                ],
                Actions =
                [
                    new ComplianceActionObservation(
                        "action:implementation",
                        @"src\backend\AuthService.cs",
                        BaseUtc.AddMinutes(1),
                        null),
                    new ComplianceActionObservation(
                        "action:runbook",
                        @"docs\runbook.md",
                        BaseUtc.AddMinutes(2),
                        "DEV-APPROVED"),
                    new ComplianceActionObservation(
                        "action:device-lookalike",
                        @"src\CONTEXT\COM10.txt",
                        BaseUtc.AddMinutes(3),
                        null),
                ],
                Deviations =
                [
                    new ComplianceDeviationDecision(
                        "deviation:approved",
                        "DEV-APPROVED",
                        @"docs",
                        ComplianceDeviationDecisionKind.Approved,
                        BaseUtc.AddMinutes(-10),
                        BaseUtc.AddMinutes(-1)),
                ],
            });

        Assert.AreEqual(
            "src/backend",
            normalized.ScopeBoundaries.Single(item => item.InputId == "scope:backend").PathPrefix);
        Assert.AreEqual(
            "tests/backend",
            normalized.ScopeBoundaries.Single(item => item.InputId == "scope:tests").PathPrefix);
        Assert.AreEqual(
            "src/backend/AuthService.cs",
            normalized.Actions.Single(item => item.InputId == "action:implementation").TargetPath);
        Assert.AreEqual(
            "docs/runbook.md",
            normalized.Actions.Single(item => item.InputId == "action:runbook").TargetPath);
        Assert.AreEqual(
            "src/CONTEXT/COM10.txt",
            normalized.Actions.Single(item => item.InputId == "action:device-lookalike").TargetPath);
        Assert.AreEqual("docs", normalized.Deviations.Single().PathPrefix);
    }

    private static void AssertPathRejected(string path)
    {
        Assert.ThrowsExactly<ComplianceRuleContractException>(() =>
            _ = ComplianceEvaluationContract.NormalizeAndValidate(
                CreateCompliantRequest() with
                {
                    Actions =
                    [
                        new ComplianceActionObservation(
                            "action:unsafe-path",
                            path,
                            BaseUtc,
                            null),
                    ],
                }));
    }

    private static ComplianceEvaluationRequest PendingDeviationRequest()
    {
        var request = CreateCompliantRequest();
        return request with
        {
            Actions =
            [
                new ComplianceActionObservation(
                    "action:outside",
                    "docs/private/operator.md",
                    BaseUtc.AddMinutes(5),
                    "DEV-PENDING"),
            ],
            Deviations =
            [
                new ComplianceDeviationDecision(
                    "deviation:pending",
                    "DEV-PENDING",
                    "docs/private",
                    ComplianceDeviationDecisionKind.Pending,
                    BaseUtc,
                    null),
            ],
        };
    }

    private static ComplianceEvaluationRequest CreateCompliantRequest() => new(
        ComplianceEvaluationContract.ContractVersion,
        "TASK-501",
        "backend-worker-01",
        [
            new ComplianceScopeBoundary("scope:backend", "src/backend"),
            new ComplianceScopeBoundary("scope:tests", "tests/backend"),
        ],
        [
            new ComplianceActionObservation(
                "action:implementation",
                "src/backend/AuthService.cs",
                BaseUtc.AddMinutes(1),
                null),
            new ComplianceActionObservation(
                "action:runbook",
                "docs/runbook.md",
                BaseUtc.AddMinutes(2),
                "DEV-APPROVED"),
        ],
        [
            new ComplianceDeviationDecision(
                "deviation:approved",
                "DEV-APPROVED",
                "docs",
                ComplianceDeviationDecisionKind.Approved,
                BaseUtc.AddMinutes(-10),
                BaseUtc.AddMinutes(-1)),
        ],
        [
            new ComplianceEvidenceRequirement(
                "requirement:test",
                "REQ-TEST",
                "test-result"),
        ],
        [
            new ComplianceEvidenceSubmission(
                "submission:test",
                "EVIDENCE-TEST-1",
                "REQ-TEST",
                true),
        ],
        [
            new ComplianceReviewObservation(
                "review:send-leader",
                1,
                ComplianceReviewActionKind.SendToLeader,
                "project-manager",
                BaseUtc.AddMinutes(10)),
            new ComplianceReviewObservation(
                "review:leader-decision",
                2,
                ComplianceReviewActionKind.LeaderDecision,
                "backend-leader",
                BaseUtc.AddMinutes(11)),
            new ComplianceReviewObservation(
                "review:escalate-pm",
                3,
                ComplianceReviewActionKind.EscalateToProjectManager,
                "backend-leader",
                BaseUtc.AddMinutes(12)),
            new ComplianceReviewObservation(
                "review:pm-decision",
                4,
                ComplianceReviewActionKind.ProjectManagerDecision,
                "project-manager",
                BaseUtc.AddMinutes(13)),
        ]);
}
