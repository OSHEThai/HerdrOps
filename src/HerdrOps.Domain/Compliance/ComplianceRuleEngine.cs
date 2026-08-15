namespace HerdrOps.Domain.Compliance;

public sealed class ComplianceRuleEngine
{
    private readonly ComplianceRuleSet _ruleSet;

    public ComplianceRuleEngine(ComplianceRuleSet? ruleSet = null)
    {
        _ruleSet = ComplianceRuleSetContract.NormalizeAndValidate(
            ruleSet ?? ComplianceRuleSetContract.Version1);
    }

    public ComplianceEvaluationResult Evaluate(
        ComplianceEvaluationRequest request,
        IReadOnlyCollection<string>? knownFindingIds = null)
    {
        var normalized = ComplianceEvaluationContract.NormalizeAndValidate(request);
        var known = NormalizeKnownFindingIds(knownFindingIds);
        var observedFindingIds = new HashSet<string>(known, StringComparer.Ordinal);
        var evaluations = new List<ComplianceRuleEvaluation>(_ruleSet.Rules.Count);
        var findings = new List<ComplianceFinding>();

        foreach (var definition in _ruleSet.Rules.OrderBy(item => item.RuleKind))
        {
            try
            {
                var computation = EvaluateRule(definition.RuleKind, normalized);
                var processed = ProcessCandidates(
                    definition,
                    normalized,
                    computation,
                    observedFindingIds);
                evaluations.Add(processed.Evaluation);
                findings.AddRange(processed.Findings);
            }
            catch (ComplianceRuleEvaluationException exception)
            {
                evaluations.Add(new ComplianceRuleEvaluation(
                    definition.RuleId,
                    definition.RuleVersion,
                    definition.RuleKind,
                    definition.Severity,
                    ComplianceRuleOutcomeKind.Error,
                    Array.Empty<string>(),
                    Array.Empty<string>(),
                    Array.AsReadOnly(exception.SupportingInputIds
                        .Distinct(StringComparer.Ordinal)
                        .OrderBy(item => item, StringComparer.Ordinal)
                        .ToArray()),
                    exception.ErrorCode,
                    exception.Message));
            }
        }

        var orderedEvaluations = Array.AsReadOnly(evaluations
            .OrderBy(item => item.RuleKind)
            .ToArray());
        var orderedFindings = Array.AsReadOnly(findings
            .OrderBy(item => item.RuleKind)
            .ThenBy(item => item.FindingId, StringComparer.Ordinal)
            .ToArray());
        var diagnostics = new ComplianceEvaluationDiagnostics(
            RuleCount: orderedEvaluations.Count,
            PassedRuleCount: orderedEvaluations.Count(item =>
                item.Outcome == ComplianceRuleOutcomeKind.Passed),
            SuspectedRuleCount: orderedEvaluations.Count(item =>
                item.Outcome == ComplianceRuleOutcomeKind.Suspected),
            DuplicateSuppressedRuleCount: orderedEvaluations.Count(item =>
                item.Outcome == ComplianceRuleOutcomeKind.DuplicateSuppressed),
            ErrorRuleCount: orderedEvaluations.Count(item =>
                item.Outcome == ComplianceRuleOutcomeKind.Error),
            ProducedFindingCount: orderedFindings.Count,
            DuplicateDetectionCount: orderedEvaluations.Sum(item =>
                item.SuppressedFindingIds.Count),
            KnownFindingCount: known.Count,
            ConfirmedFindingCount: orderedFindings.Count(item =>
                item.State != ComplianceFindingState.Suspected));
        var result = new ComplianceEvaluationResult(
            ComplianceEvaluationContract.ContractVersion,
            normalized.TaskId,
            normalized.ActorId,
            _ruleSet.RuleSetSha256,
            ComplianceEvaluationContract.ComputeRequestSha256(normalized),
            ComputeKnownFindingSetSha256(known),
            orderedEvaluations,
            orderedFindings,
            diagnostics,
            string.Empty);
        return result with { ResultSha256 = ComputeResultSha256(result) };
    }

    private static RuleComputation EvaluateRule(
        ComplianceRuleKind ruleKind,
        ComplianceEvaluationRequest request) => ruleKind switch
        {
            ComplianceRuleKind.ScopeViolation => EvaluateScopeRule(request),
            ComplianceRuleKind.MissingEvidence => EvaluateMissingEvidenceRule(request),
            ComplianceRuleKind.UnapprovedDeviation => EvaluateDeviationRule(request),
            ComplianceRuleKind.ReviewOrder => EvaluateReviewOrderRule(request),
            _ => throw new ComplianceRuleEvaluationException(
                "unsupported-rule-kind",
                $"Compliance rule kind {ruleKind} is unsupported.",
                []),
        };

    private static RuleComputation EvaluateScopeRule(
        ComplianceEvaluationRequest request)
    {
        var checkedInputIds = request.ScopeBoundaries.Select(item => item.InputId)
            .Concat(request.Actions.Select(item => item.InputId))
            .Concat(request.Deviations.Select(item => item.InputId))
            .ToArray();
        if (request.Actions.Count > 0 && request.ScopeBoundaries.Count == 0)
        {
            throw new ComplianceRuleEvaluationException(
                "scope-policy-missing",
                "Scope observations cannot be evaluated because no assigned scope boundary was supplied.",
                request.Actions.Select(item => item.InputId));
        }

        var deviations = request.Deviations.ToDictionary(
            item => item.DeviationId,
            StringComparer.Ordinal);
        var candidates = new List<RuleCandidate>();
        foreach (var action in request.Actions)
        {
            if (request.ScopeBoundaries.Any(boundary =>
                    PathIsWithin(action.TargetPath, boundary.PathPrefix)))
            {
                continue;
            }

            ComplianceDeviationDecision? deviation = null;
            if (action.DeviationId is not null)
            {
                deviations.TryGetValue(action.DeviationId, out deviation);
            }

            if (deviation is not null && DeviationAuthorizes(deviation, action))
            {
                continue;
            }

            var facts = new List<ComplianceSupportingFact>
            {
                ActionFact(action),
            };
            facts.AddRange(request.ScopeBoundaries.Select(ScopeFact));
            if (deviation is not null)
            {
                facts.Add(DeviationFact(deviation));
            }

            candidates.Add(new RuleCandidate(
                $"path:{action.TargetPath}",
                facts));
        }

        return new RuleComputation(candidates, checkedInputIds);
    }

    private static RuleComputation EvaluateMissingEvidenceRule(
        ComplianceEvaluationRequest request)
    {
        var checkedInputIds = request.EvidenceRequirements.Select(item => item.InputId)
            .Concat(request.EvidenceSubmissions.Select(item => item.InputId))
            .ToArray();
        var requirements = request.EvidenceRequirements.ToDictionary(
            item => item.RequirementId,
            StringComparer.Ordinal);
        var orphanSubmissions = request.EvidenceSubmissions
            .Where(item => !requirements.ContainsKey(item.RequirementId))
            .ToArray();
        if (orphanSubmissions.Length > 0)
        {
            throw new ComplianceRuleEvaluationException(
                "orphan-evidence-submission",
                "At least one evidence submission references an unknown requirement, so the missing-evidence rule cannot produce a trustworthy incident candidate.",
                orphanSubmissions.Select(item => item.InputId));
        }

        var candidates = new List<RuleCandidate>();
        foreach (var requirement in request.EvidenceRequirements)
        {
            var submissions = request.EvidenceSubmissions
                .Where(item => string.Equals(
                    item.RequirementId,
                    requirement.RequirementId,
                    StringComparison.Ordinal))
                .ToArray();
            if (submissions.Any(item => item.IsAdmitted))
            {
                continue;
            }

            var facts = new List<ComplianceSupportingFact>
            {
                RequirementFact(requirement),
            };
            facts.AddRange(submissions.Select(SubmissionFact));
            candidates.Add(new RuleCandidate(
                $"requirement:{requirement.RequirementId}",
                facts));
        }

        return new RuleComputation(candidates, checkedInputIds);
    }

    private static RuleComputation EvaluateDeviationRule(
        ComplianceEvaluationRequest request)
    {
        var checkedInputIds = request.Actions.Select(item => item.InputId)
            .Concat(request.Deviations.Select(item => item.InputId))
            .ToArray();
        var deviations = request.Deviations.ToDictionary(
            item => item.DeviationId,
            StringComparer.Ordinal);
        var candidates = new List<RuleCandidate>();
        foreach (var action in request.Actions)
        {
            var isInsideBaseScope = request.ScopeBoundaries.Any(boundary =>
                PathIsWithin(action.TargetPath, boundary.PathPrefix));
            if (isInsideBaseScope || action.DeviationId is null)
            {
                continue;
            }

            deviations.TryGetValue(action.DeviationId, out var deviation);
            if (deviation is not null && DeviationAuthorizes(deviation, action))
            {
                continue;
            }

            var facts = new List<ComplianceSupportingFact>
            {
                ActionFact(action),
            };
            if (deviation is not null)
            {
                facts.Add(DeviationFact(deviation));
            }

            candidates.Add(new RuleCandidate(
                $"deviation:{action.DeviationId}",
                facts));
        }

        return new RuleComputation(candidates, checkedInputIds);
    }

    private static RuleComputation EvaluateReviewOrderRule(
        ComplianceEvaluationRequest request)
    {
        var reviewInputs = request.ReviewObservations
            .Select(item => item.InputId)
            .ToArray();
        var duplicateSequences = request.ReviewObservations
            .GroupBy(item => item.Sequence)
            .Where(group => group.Count() > 1)
            .SelectMany(group => group.Select(item => item.InputId))
            .ToArray();
        if (duplicateSequences.Length > 0)
        {
            throw new ComplianceRuleEvaluationException(
                "review-sequence-conflict",
                "The review-order rule cannot evaluate duplicate review sequence values.",
                duplicateSequences);
        }

        var ordered = request.ReviewObservations
            .OrderBy(item => item.Sequence)
            .ToArray();
        for (var index = 1; index < ordered.Length; index++)
        {
            if (ordered[index].OccurredUtc < ordered[index - 1].OccurredUtc)
            {
                throw new ComplianceRuleEvaluationException(
                    "review-time-regression",
                    "Review event time regressed while its sequence advanced.",
                    [ordered[index - 1].InputId, ordered[index].InputId]);
            }
        }

        var candidates = new List<RuleCandidate>();
        var state = ReviewProgress.None;
        ComplianceReviewObservation? previousAccepted = null;
        foreach (var review in ordered)
        {
            if (IsExpectedReviewAction(state, review.ActionKind))
            {
                state = AdvanceReviewState(state);
                previousAccepted = review;
                continue;
            }

            var facts = new List<ComplianceSupportingFact>
            {
                ReviewFact(review),
            };
            if (previousAccepted is not null)
            {
                facts.Add(ReviewFact(previousAccepted));
            }

            candidates.Add(new RuleCandidate(
                $"review:{review.InputId}",
                facts));
        }

        return new RuleComputation(candidates, reviewInputs);
    }

    private static ProcessedRule ProcessCandidates(
        ComplianceRuleDefinition definition,
        ComplianceEvaluationRequest request,
        RuleComputation computation,
        HashSet<string> observedFindingIds)
    {
        var produced = new List<ComplianceFinding>();
        var suppressed = new List<string>();
        var groupedCandidates = computation.Candidates
            .Select(candidate => new
            {
                Candidate = candidate,
                FindingId = ComputeFindingId(
                    definition,
                    request.TaskId,
                    request.ActorId,
                    candidate.Subject),
            })
            .GroupBy(item => item.FindingId, StringComparer.Ordinal)
            .OrderBy(group => group.Key, StringComparer.Ordinal);
        foreach (var group in groupedCandidates)
        {
            var candidates = group.ToArray();
            if (observedFindingIds.Add(group.Key))
            {
                produced.Add(CreateFinding(
                    group.Key,
                    definition,
                    request,
                    candidates[0].Candidate.Subject,
                    candidates.SelectMany(item => item.Candidate.SupportingFacts)));
                for (var index = 1; index < candidates.Length; index++)
                {
                    suppressed.Add(group.Key);
                }
            }
            else
            {
                suppressed.AddRange(Enumerable.Repeat(group.Key, candidates.Length));
            }
        }

        var producedIds = Array.AsReadOnly(produced
            .Select(item => item.FindingId)
            .OrderBy(item => item, StringComparer.Ordinal)
            .ToArray());
        var suppressedIds = Array.AsReadOnly(suppressed
            .OrderBy(item => item, StringComparer.Ordinal)
            .ToArray());
        var supportingInputIds = Array.AsReadOnly(computation.CheckedInputIds
            .Concat(computation.Candidates.SelectMany(item =>
                item.SupportingFacts.Select(fact => fact.InputId)))
            .Distinct(StringComparer.Ordinal)
            .OrderBy(item => item, StringComparer.Ordinal)
            .ToArray());
        var outcome = producedIds.Count > 0
            ? ComplianceRuleOutcomeKind.Suspected
            : suppressedIds.Count > 0
                ? ComplianceRuleOutcomeKind.DuplicateSuppressed
                : ComplianceRuleOutcomeKind.Passed;
        var evaluation = new ComplianceRuleEvaluation(
            definition.RuleId,
            definition.RuleVersion,
            definition.RuleKind,
            definition.Severity,
            outcome,
            producedIds,
            suppressedIds,
            supportingInputIds,
            null,
            null);
        return new ProcessedRule(
            evaluation,
            Array.AsReadOnly(produced
                .OrderBy(item => item.FindingId, StringComparer.Ordinal)
                .ToArray()));
    }

    private static ComplianceFinding CreateFinding(
        string findingId,
        ComplianceRuleDefinition definition,
        ComplianceEvaluationRequest request,
        string subject,
        IEnumerable<ComplianceSupportingFact> supportingFacts)
    {
        var facts = Array.AsReadOnly(supportingFacts
            .Distinct()
            .OrderBy(item => item.InputId, StringComparer.Ordinal)
            .ThenBy(item => item.FactKind)
            .ThenBy(item => item.Detail, StringComparer.Ordinal)
            .ToArray());
        if (facts.Count == 0)
        {
            throw new ComplianceRuleEvaluationException(
                "finding-without-supporting-facts",
                "A compliance finding cannot be emitted without supporting facts.",
                []);
        }

        var finding = new ComplianceFinding(
            findingId,
            ComplianceFindingState.Suspected,
            definition.RuleId,
            definition.RuleVersion,
            definition.RuleKind,
            definition.Severity,
            request.TaskId,
            request.ActorId,
            subject,
            facts,
            string.Empty);
        return finding with
        {
            ExplainabilitySha256 = ComputeExplainabilitySha256(finding),
        };
    }

    private static string ComputeFindingId(
        ComplianceRuleDefinition definition,
        string taskId,
        string actorId,
        string subject)
    {
        using var writer = new ComplianceCanonicalHashWriter(
            "HerdrOps.ComplianceFindingIdentity.v1");
        writer.Write(definition.RuleId);
        writer.Write(definition.RuleVersion);
        writer.Write((int)definition.RuleKind);
        writer.Write(taskId);
        writer.Write(actorId);
        writer.Write(subject.ToUpperInvariant());
        return writer.Finish();
    }

    private static string ComputeExplainabilitySha256(ComplianceFinding finding)
    {
        using var writer = new ComplianceCanonicalHashWriter(
            "HerdrOps.ComplianceFindingExplainability.v1");
        writer.Write(finding.FindingId);
        writer.Write((int)finding.State);
        writer.Write(finding.RuleId);
        writer.Write(finding.RuleVersion);
        writer.Write((int)finding.RuleKind);
        writer.Write((int)finding.Severity);
        writer.Write(finding.TaskId);
        writer.Write(finding.ActorId);
        writer.Write(finding.Subject);
        writer.Write(finding.SupportingFacts.Count);
        foreach (var fact in finding.SupportingFacts)
        {
            WriteFact(writer, fact);
        }

        return writer.Finish();
    }

    private static string ComputeKnownFindingSetSha256(IReadOnlyList<string> findingIds)
    {
        using var writer = new ComplianceCanonicalHashWriter(
            "HerdrOps.ComplianceKnownFindingSet.v1");
        writer.Write(findingIds.Count);
        foreach (var findingId in findingIds)
        {
            writer.Write(findingId);
        }

        return writer.Finish();
    }

    private static string ComputeResultSha256(ComplianceEvaluationResult result)
    {
        using var writer = new ComplianceCanonicalHashWriter(
            "HerdrOps.ComplianceEvaluationResult.v1");
        writer.Write(result.ContractVersion);
        writer.Write(result.TaskId);
        writer.Write(result.ActorId);
        writer.Write(result.RuleSetSha256);
        writer.Write(result.RequestSha256);
        writer.Write(result.KnownFindingSetSha256);
        writer.Write(result.RuleEvaluations.Count);
        foreach (var evaluation in result.RuleEvaluations)
        {
            writer.Write(evaluation.RuleId);
            writer.Write(evaluation.RuleVersion);
            writer.Write((int)evaluation.RuleKind);
            writer.Write((int)evaluation.Severity);
            writer.Write((int)evaluation.Outcome);
            WriteStrings(writer, evaluation.ProducedFindingIds);
            WriteStrings(writer, evaluation.SuppressedFindingIds);
            WriteStrings(writer, evaluation.SupportingInputIds);
            writer.Write(evaluation.ErrorCode);
            writer.Write(evaluation.ErrorMessage);
        }

        writer.Write(result.Findings.Count);
        foreach (var finding in result.Findings)
        {
            writer.Write(finding.FindingId);
            writer.Write((int)finding.State);
            writer.Write(finding.RuleId);
            writer.Write(finding.RuleVersion);
            writer.Write((int)finding.RuleKind);
            writer.Write((int)finding.Severity);
            writer.Write(finding.TaskId);
            writer.Write(finding.ActorId);
            writer.Write(finding.Subject);
            writer.Write(finding.SupportingFacts.Count);
            foreach (var fact in finding.SupportingFacts)
            {
                WriteFact(writer, fact);
            }

            writer.Write(finding.ExplainabilitySha256);
        }

        writer.Write(result.Diagnostics.RuleCount);
        writer.Write(result.Diagnostics.PassedRuleCount);
        writer.Write(result.Diagnostics.SuspectedRuleCount);
        writer.Write(result.Diagnostics.DuplicateSuppressedRuleCount);
        writer.Write(result.Diagnostics.ErrorRuleCount);
        writer.Write(result.Diagnostics.ProducedFindingCount);
        writer.Write(result.Diagnostics.DuplicateDetectionCount);
        writer.Write(result.Diagnostics.KnownFindingCount);
        writer.Write(result.Diagnostics.ConfirmedFindingCount);
        return writer.Finish();
    }

    private static IReadOnlyList<string> NormalizeKnownFindingIds(
        IReadOnlyCollection<string>? findingIds)
    {
        if (findingIds is null)
        {
            return Array.Empty<string>();
        }

        if (findingIds.Count > ComplianceEvaluationContract.MaximumItemCount)
        {
            throw new ComplianceRuleContractException(
                $"Known compliance findings cannot exceed {ComplianceEvaluationContract.MaximumItemCount} identities.");
        }

        return Array.AsReadOnly(findingIds
            .Select(item => ComplianceEvaluationContract.NormalizeSha256(
                item,
                "knownFindingId"))
            .Distinct(StringComparer.Ordinal)
            .OrderBy(item => item, StringComparer.Ordinal)
            .ToArray());
    }

    private static bool PathIsWithin(string path, string prefix) =>
        string.Equals(path, prefix, StringComparison.OrdinalIgnoreCase) ||
        path.StartsWith(prefix + "/", StringComparison.OrdinalIgnoreCase);

    private static bool DeviationAuthorizes(
        ComplianceDeviationDecision deviation,
        ComplianceActionObservation action) =>
        deviation.DecisionKind == ComplianceDeviationDecisionKind.Approved &&
        deviation.DecidedUtc is { } decidedUtc &&
        decidedUtc <= action.OccurredUtc &&
        PathIsWithin(action.TargetPath, deviation.PathPrefix);

    private static bool IsExpectedReviewAction(
        ReviewProgress state,
        ComplianceReviewActionKind action) => (state, action) switch
        {
            (ReviewProgress.None, ComplianceReviewActionKind.SendToLeader) => true,
            (ReviewProgress.LeaderPending, ComplianceReviewActionKind.LeaderDecision) => true,
            (ReviewProgress.LeaderDecided, ComplianceReviewActionKind.EscalateToProjectManager) => true,
            (ReviewProgress.ProjectManagerPending, ComplianceReviewActionKind.ProjectManagerDecision) => true,
            _ => false,
        };

    private static ReviewProgress AdvanceReviewState(ReviewProgress state) => state switch
    {
        ReviewProgress.None => ReviewProgress.LeaderPending,
        ReviewProgress.LeaderPending => ReviewProgress.LeaderDecided,
        ReviewProgress.LeaderDecided => ReviewProgress.ProjectManagerPending,
        ReviewProgress.ProjectManagerPending => ReviewProgress.Complete,
        _ => ReviewProgress.Complete,
    };

    private static ComplianceSupportingFact ScopeFact(ComplianceScopeBoundary item) => new(
        item.InputId,
        ComplianceSupportingFactKind.ScopeBoundary,
        item.PathPrefix,
        $"allowed-prefix:{item.PathPrefix}",
        null);

    private static ComplianceSupportingFact ActionFact(ComplianceActionObservation item) => new(
        item.InputId,
        ComplianceSupportingFactKind.ActionObservation,
        item.TargetPath,
        item.DeviationId is null
            ? $"target:{item.TargetPath};deviation:none"
            : $"target:{item.TargetPath};deviation:{item.DeviationId}",
        item.OccurredUtc);

    private static ComplianceSupportingFact DeviationFact(ComplianceDeviationDecision item) => new(
        item.InputId,
        ComplianceSupportingFactKind.DeviationDecision,
        item.DeviationId,
        $"path-prefix:{item.PathPrefix};decision:{item.DecisionKind}",
        item.DecidedUtc ?? item.RequestedUtc);

    private static ComplianceSupportingFact RequirementFact(ComplianceEvidenceRequirement item) => new(
        item.InputId,
        ComplianceSupportingFactKind.EvidenceRequirement,
        item.RequirementId,
        $"evidence-type:{item.EvidenceType}",
        null);

    private static ComplianceSupportingFact SubmissionFact(ComplianceEvidenceSubmission item) => new(
        item.InputId,
        ComplianceSupportingFactKind.EvidenceSubmission,
        item.RequirementId,
        $"submission:{item.SubmissionId};admitted:{item.IsAdmitted}",
        null);

    private static ComplianceSupportingFact ReviewFact(ComplianceReviewObservation item) => new(
        item.InputId,
        ComplianceSupportingFactKind.ReviewObservation,
        item.ReviewerActorId,
        $"sequence:{item.Sequence};action:{item.ActionKind}",
        item.OccurredUtc);

    private static void WriteFact(
        ComplianceCanonicalHashWriter writer,
        ComplianceSupportingFact fact)
    {
        writer.Write(fact.InputId);
        writer.Write((int)fact.FactKind);
        writer.Write(fact.Subject);
        writer.Write(fact.Detail);
        writer.Write(fact.OccurredUtc);
    }

    private static void WriteStrings(
        ComplianceCanonicalHashWriter writer,
        IReadOnlyList<string> values)
    {
        writer.Write(values.Count);
        foreach (var value in values)
        {
            writer.Write(value);
        }
    }

    private sealed record RuleCandidate(
        string Subject,
        IReadOnlyList<ComplianceSupportingFact> SupportingFacts);

    private sealed record RuleComputation(
        IReadOnlyList<RuleCandidate> Candidates,
        IReadOnlyList<string> CheckedInputIds);

    private sealed record ProcessedRule(
        ComplianceRuleEvaluation Evaluation,
        IReadOnlyList<ComplianceFinding> Findings);

    private enum ReviewProgress
    {
        None = 0,
        LeaderPending = 1,
        LeaderDecided = 2,
        ProjectManagerPending = 3,
        Complete = 4,
    }
}

internal sealed class ComplianceRuleEvaluationException : Exception
{
    public ComplianceRuleEvaluationException(
        string errorCode,
        string message,
        IEnumerable<string> supportingInputIds)
        : base(message)
    {
        ErrorCode = errorCode;
        SupportingInputIds = supportingInputIds.ToArray();
    }

    public string ErrorCode { get; }

    public IReadOnlyList<string> SupportingInputIds { get; }
}
