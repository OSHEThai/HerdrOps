using HerdrOps.Domain.Activity;

namespace HerdrOps.Domain.Assignments;

public enum TaskAlignmentScopeRuleKind
{
    AllowPathPrefix = 1,
    DenyPathPrefix = 2,
}

public enum TaskAlignmentActionOutcome
{
    Started = 1,
    Completed = 2,
    Failed = 3,
}

public enum TaskAlignmentDeviationDecisionKind
{
    Pending = 1,
    Approved = 2,
    Rejected = 3,
}

public enum TaskAlignmentReviewDecisionKind
{
    ConfirmedViolation = 1,
    Dismissed = 2,
}

public enum TaskAlignmentDimension
{
    Acknowledgement = 1,
    Goal = 2,
    Scope = 3,
    AcceptanceCriteria = 4,
    Evidence = 5,
    Deviation = 6,
}

public enum TaskAlignmentFindingLevel
{
    Pass = 1,
    Attention = 2,
    Suspected = 3,
    Confirmed = 4,
    Missing = 5,
}

public enum TaskAlignmentFindingCode
{
    AcknowledgementConfirmed = 1,
    AcknowledgementMissing = 2,
    ObservedActionsMissing = 3,
    StepCompleted = 4,
    StepStarted = 5,
    StepFailed = 6,
    StepMissing = 7,
    FileObservationsMissing = 8,
    ScopeCompliant = 9,
    ScopeApprovedDeviation = 10,
    ScopePendingDeviation = 11,
    ScopeSuspectedViolation = 12,
    ScopeConfirmedViolation = 13,
    ScopeReviewDismissed = 14,
    EvidenceMissing = 15,
    AcceptanceSatisfied = 16,
    AcceptancePartial = 17,
    AcceptanceMissing = 18,
    DeviationUnlinked = 19,
}

public enum TaskAlignmentVerdictKind
{
    InsufficientData = 1,
    Aligned = 2,
    PartiallyMisaligned = 3,
    SuspectedViolation = 4,
    ConfirmedViolation = 5,
}

public sealed record TaskAlignmentScopeRule(
    string RuleId,
    TaskAlignmentScopeRuleKind RuleKind,
    string PathPrefix,
    string Description);

public sealed record TaskAlignmentConstraint(
    string ConstraintId,
    string Description);

public sealed record TaskAlignmentPlannedStep(
    string StepId,
    string Description,
    int WeightPercent);

public sealed record TaskAlignmentAcceptanceCriterion(
    string CriterionId,
    string Description,
    int WeightPercent,
    IReadOnlyList<string> RequiredEvidencePatterns);

public sealed record TaskAlignmentContract(
    int ContractVersion,
    string TaskId,
    Guid AssignmentEventId,
    string AssignmentEventSha256,
    string Goal,
    IReadOnlyList<TaskAlignmentScopeRule> ScopeRules,
    IReadOnlyList<TaskAlignmentConstraint> Constraints,
    IReadOnlyList<TaskAlignmentPlannedStep> PlannedSteps,
    IReadOnlyList<TaskAlignmentAcceptanceCriterion> AcceptanceCriteria,
    DateTimeOffset CreatedUtc,
    string ContractSha256);

public sealed record TaskAlignmentActionObservation(
    string InputId,
    NormalizedActivityEvent Activity,
    string StepId,
    TaskAlignmentActionOutcome Outcome);

public sealed record TaskAlignmentDeviationDecision(
    string InputId,
    Guid DeviationEventId,
    TaskAlignmentDeviationDecisionKind DecisionKind,
    string RequestedPathPrefix,
    DateTimeOffset DecidedUtc,
    string ProvenanceSha256);

public sealed record TaskAlignmentReviewDecision(
    string InputId,
    string TargetInputId,
    TaskAlignmentReviewDecisionKind DecisionKind,
    string ReviewerActorId,
    DateTimeOffset DecidedUtc,
    string ProvenanceSha256);

public sealed record TaskAlignmentAnalysisRequest(
    AssignmentLifecycleReplayResult LifecycleReplay,
    TaskAlignmentContract Contract,
    IReadOnlyList<TaskAlignmentActionObservation> Actions,
    IReadOnlyList<FileActivityObservation> FileTouches,
    IReadOnlyList<TaskAlignmentDeviationDecision> DeviationDecisions,
    IReadOnlyList<TaskAlignmentReviewDecision> ReviewDecisions);

public sealed record TaskAlignmentFinding(
    string FindingId,
    TaskAlignmentFindingCode Code,
    TaskAlignmentFindingLevel Level,
    TaskAlignmentDimension Dimension,
    string ClauseId,
    string Subject,
    int? EarnedScore,
    int? MaximumScore,
    IReadOnlyList<string> SupportingInputIds);

public sealed record TaskAlignmentVerdict(
    TaskAlignmentVerdictKind Kind,
    IReadOnlyList<string> SupportingInputIds);

public sealed record TaskAlignmentAnalysisResult(
    int ContractVersion,
    string TaskId,
    int? GoalAlignmentScore,
    int? ScopeComplianceScore,
    int? AcceptanceCriteriaScore,
    bool HasMissingRequiredData,
    TaskAlignmentVerdict Verdict,
    IReadOnlyList<TaskAlignmentFinding> Findings,
    string LifecycleGraphSha256,
    string ContractSha256,
    string AnalysisSha256);

public static class TaskAlignmentContractRules
{
    public const int Version = 1;
    public const int MaximumItemCount = 64;
    public const int MaximumIdentifierLength = 128;
    public const int MaximumDescriptionLength = 2048;

    public static TaskAlignmentContract Create(
        string taskId,
        Guid assignmentEventId,
        string assignmentEventSha256,
        string goal,
        IReadOnlyList<TaskAlignmentScopeRule> scopeRules,
        IReadOnlyList<TaskAlignmentConstraint> constraints,
        IReadOnlyList<TaskAlignmentPlannedStep> plannedSteps,
        IReadOnlyList<TaskAlignmentAcceptanceCriterion> acceptanceCriteria,
        DateTimeOffset createdUtc)
    {
        var candidate = new TaskAlignmentContract(
            Version,
            taskId,
            assignmentEventId,
            assignmentEventSha256,
            goal,
            scopeRules,
            constraints,
            plannedSteps,
            acceptanceCriteria,
            createdUtc,
            string.Empty);
        var normalized = NormalizeCore(candidate);
        return normalized with { ContractSha256 = ComputeSha256(normalized) };
    }

    public static TaskAlignmentContract NormalizeAndValidate(TaskAlignmentContract contract)
    {
        ArgumentNullException.ThrowIfNull(contract);
        var normalized = NormalizeCore(contract);
        var suppliedHash = NormalizeSha256(contract.ContractSha256, nameof(contract.ContractSha256));
        var expectedHash = ComputeSha256(normalized);
        if (!string.Equals(suppliedHash, expectedHash, StringComparison.Ordinal))
        {
            throw new TaskAlignmentContractException(
                "The Task Alignment contract SHA-256 does not match its canonical content.");
        }

        return normalized with { ContractSha256 = expectedHash };
    }

    public static string ContractInputId(string taskId) => $"contract:{taskId}";

    public static string StepInputId(string stepId) => $"contract:step:{stepId}";

    public static string CriterionInputId(string criterionId) =>
        $"contract:criterion:{criterionId}";

    public static string ScopeInputId(string ruleId) => $"contract:scope:{ruleId}";

    private static TaskAlignmentContract NormalizeCore(TaskAlignmentContract contract)
    {
        if (contract.ContractVersion != Version)
        {
            throw new TaskAlignmentContractException(
                $"Task Alignment contract v{contract.ContractVersion} is unsupported; expected v{Version}.");
        }

        if (contract.AssignmentEventId == Guid.Empty)
        {
            throw new TaskAlignmentContractException(
                "The Task Alignment assignment event identifier cannot be empty.");
        }

        EnsureUtc(contract.CreatedUtc, nameof(contract.CreatedUtc));
        var taskId = NormalizeIdentifier(contract.TaskId, nameof(contract.TaskId));
        var assignmentHash = NormalizeSha256(
            contract.AssignmentEventSha256,
            nameof(contract.AssignmentEventSha256));
        var goal = NormalizeDescription(contract.Goal, nameof(contract.Goal));
        var scopeRules = NormalizeBoundedItems(
            contract.ScopeRules,
            nameof(contract.ScopeRules),
            item =>
            {
                ArgumentNullException.ThrowIfNull(item);
                if (!Enum.IsDefined(item.RuleKind))
                {
                    throw new TaskAlignmentContractException(
                        "A Task Alignment scope rule has an unsupported kind.");
                }

                return item with
                {
                    RuleId = NormalizeIdentifier(item.RuleId, nameof(item.RuleId)),
                    PathPrefix = NormalizePathPrefix(item.PathPrefix, nameof(item.PathPrefix)),
                    Description = NormalizeDescription(item.Description, nameof(item.Description)),
                };
            });
        if (!scopeRules.Any(item => item.RuleKind == TaskAlignmentScopeRuleKind.AllowPathPrefix))
        {
            throw new TaskAlignmentContractException(
                "A Task Alignment contract requires at least one allowed path prefix.");
        }

        EnsureUnique(scopeRules.Select(item => item.RuleId), "scope rule");
        var constraints = NormalizeBoundedItems(
            contract.Constraints,
            nameof(contract.Constraints),
            item =>
            {
                ArgumentNullException.ThrowIfNull(item);
                return item with
                {
                    ConstraintId = NormalizeIdentifier(
                        item.ConstraintId,
                        nameof(item.ConstraintId)),
                    Description = NormalizeDescription(item.Description, nameof(item.Description)),
                };
            });
        EnsureUnique(constraints.Select(item => item.ConstraintId), "constraint");
        var plannedSteps = NormalizeBoundedItems(
            contract.PlannedSteps,
            nameof(contract.PlannedSteps),
            item =>
            {
                ArgumentNullException.ThrowIfNull(item);
                ValidateWeight(item.WeightPercent, nameof(item.WeightPercent));
                return item with
                {
                    StepId = NormalizeIdentifier(item.StepId, nameof(item.StepId)),
                    Description = NormalizeDescription(item.Description, nameof(item.Description)),
                };
            });
        EnsureUnique(plannedSteps.Select(item => item.StepId), "planned step");
        EnsureWeightTotal(plannedSteps.Select(item => item.WeightPercent), "planned steps");
        var criteria = NormalizeBoundedItems(
            contract.AcceptanceCriteria,
            nameof(contract.AcceptanceCriteria),
            item =>
            {
                ArgumentNullException.ThrowIfNull(item);
                ValidateWeight(item.WeightPercent, nameof(item.WeightPercent));
                var patterns = NormalizeBoundedItems(
                    item.RequiredEvidencePatterns,
                    nameof(item.RequiredEvidencePatterns),
                    value => NormalizeDescription(value, nameof(item.RequiredEvidencePatterns)));
                EnsureUnique(patterns, "evidence pattern");
                return item with
                {
                    CriterionId = NormalizeIdentifier(item.CriterionId, nameof(item.CriterionId)),
                    Description = NormalizeDescription(item.Description, nameof(item.Description)),
                    RequiredEvidencePatterns = patterns,
                };
            });
        EnsureUnique(criteria.Select(item => item.CriterionId), "acceptance criterion");
        EnsureWeightTotal(criteria.Select(item => item.WeightPercent), "acceptance criteria");

        return contract with
        {
            TaskId = taskId,
            AssignmentEventSha256 = assignmentHash,
            Goal = goal,
            ScopeRules = scopeRules,
            Constraints = constraints,
            PlannedSteps = plannedSteps,
            AcceptanceCriteria = criteria,
        };
    }

    private static IReadOnlyList<T> NormalizeBoundedItems<T>(
        IReadOnlyList<T> items,
        string name,
        Func<T, T> normalize)
    {
        ArgumentNullException.ThrowIfNull(items);
        if (items.Count is < 1 or > MaximumItemCount)
        {
            throw new TaskAlignmentContractException(
                $"Task Alignment field {name} requires between 1 and {MaximumItemCount} items.");
        }

        return items.Select(normalize).ToArray();
    }

    private static void EnsureUnique(IEnumerable<string> values, string name)
    {
        var array = values.ToArray();
        if (array.Distinct(StringComparer.Ordinal).Count() != array.Length)
        {
            throw new TaskAlignmentContractException(
                $"Task Alignment {name} identifiers must be unique.");
        }
    }

    private static void ValidateWeight(int value, string name)
    {
        if (value is < 1 or > 100)
        {
            throw new TaskAlignmentContractException(
                $"Task Alignment field {name} must be between 1 and 100.");
        }
    }

    private static void EnsureWeightTotal(IEnumerable<int> weights, string name)
    {
        if (weights.Sum() != 100)
        {
            throw new TaskAlignmentContractException(
                $"Task Alignment {name} weights must total exactly 100 percent.");
        }
    }

    private static string NormalizeIdentifier(string value, string name)
    {
        if (string.IsNullOrWhiteSpace(value) ||
            !string.Equals(value, value.Trim(), StringComparison.Ordinal) ||
            value.Length > MaximumIdentifierLength ||
            value.Any(char.IsControl))
        {
            throw new TaskAlignmentContractException(
                $"Task Alignment field {name} must be non-blank, unpadded, bounded, and free of control characters.");
        }

        return value.Normalize();
    }

    private static string NormalizeDescription(string value, string name)
    {
        if (string.IsNullOrWhiteSpace(value) ||
            !string.Equals(value, value.Trim(), StringComparison.Ordinal) ||
            value.Length > MaximumDescriptionLength ||
            value.Any(character => char.IsControl(character) && character != '\n'))
        {
            throw new TaskAlignmentContractException(
                $"Task Alignment field {name} must be non-blank, unpadded, bounded, and free of unsupported control characters.");
        }

        return value.Replace("\r\n", "\n", StringComparison.Ordinal)
            .Replace('\r', '\n')
            .Normalize();
    }

    internal static string NormalizePathPrefix(string value, string name)
    {
        var normalized = NormalizeDescription(value, name).Replace('\\', '/');
        if (Path.IsPathRooted(normalized) ||
            normalized.StartsWith("/", StringComparison.Ordinal) ||
            normalized.Split('/', StringSplitOptions.RemoveEmptyEntries)
                .Any(segment => segment is "." or ".."))
        {
            throw new TaskAlignmentContractException(
                $"Task Alignment field {name} must be a repository-relative path prefix.");
        }

        return normalized.TrimEnd('/') + "/";
    }

    internal static string NormalizeInputId(string value, string name) =>
        NormalizeIdentifier(value, name);

    internal static string NormalizeSha256(string value, string name)
    {
        if (value is null || value.Length != 64 || !value.All(IsHexCharacter))
        {
            throw new TaskAlignmentContractException(
                $"Task Alignment field {name} must contain exactly 64 hexadecimal characters.");
        }

        return value.ToUpperInvariant();
    }

    internal static void EnsureUtc(DateTimeOffset value, string name)
    {
        if (value.Offset != TimeSpan.Zero)
        {
            throw new TaskAlignmentContractException(
                $"Task Alignment field {name} must be UTC.");
        }
    }

    private static bool IsHexCharacter(char value) =>
        value is >= '0' and <= '9' or >= 'A' and <= 'F' or >= 'a' and <= 'f';

    private static string ComputeSha256(TaskAlignmentContract contract)
    {
        using var writer = new CanonicalHashWriter("HerdrOps.TaskAlignmentContract.v1");
        writer.Write(contract.ContractVersion);
        writer.Write(contract.TaskId);
        writer.Write(contract.AssignmentEventId.ToString("D"));
        writer.Write(contract.AssignmentEventSha256);
        writer.Write(contract.Goal);
        writer.Write(contract.ScopeRules.Count);
        foreach (var rule in contract.ScopeRules)
        {
            writer.Write(rule.RuleId);
            writer.Write((int)rule.RuleKind);
            writer.Write(rule.PathPrefix);
            writer.Write(rule.Description);
        }

        writer.Write(contract.Constraints.Count);
        foreach (var constraint in contract.Constraints)
        {
            writer.Write(constraint.ConstraintId);
            writer.Write(constraint.Description);
        }

        writer.Write(contract.PlannedSteps.Count);
        foreach (var step in contract.PlannedSteps)
        {
            writer.Write(step.StepId);
            writer.Write(step.Description);
            writer.Write(step.WeightPercent);
        }

        writer.Write(contract.AcceptanceCriteria.Count);
        foreach (var criterion in contract.AcceptanceCriteria)
        {
            writer.Write(criterion.CriterionId);
            writer.Write(criterion.Description);
            writer.Write(criterion.WeightPercent);
            writer.Write(criterion.RequiredEvidencePatterns.Count);
            foreach (var pattern in criterion.RequiredEvidencePatterns)
            {
                writer.Write(pattern);
            }
        }

        writer.Write(contract.CreatedUtc);
        return writer.Finish();
    }
}

public static class TaskAlignmentAnalyzer
{
    public static TaskAlignmentAnalysisResult Analyze(TaskAlignmentAnalysisRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        var graph = AssignmentDelegationGraphProjector.Create(request.LifecycleReplay);
        var contract = TaskAlignmentContractRules.NormalizeAndValidate(request.Contract);
        var lifecycleTask = graph.Tasks.SingleOrDefault(item =>
            string.Equals(item.TaskId, contract.TaskId, StringComparison.Ordinal));
        var lifecycleSnapshot = request.LifecycleReplay.CurrentTasks.SingleOrDefault(item =>
            string.Equals(item.State.TaskId, contract.TaskId, StringComparison.Ordinal));
        if (lifecycleTask is null ||
            lifecycleSnapshot is null ||
            contract.AssignmentEventId != lifecycleSnapshot.State.Contract.AssignmentEventId ||
            !string.Equals(
                contract.AssignmentEventSha256,
                lifecycleTask.ProvenanceEventSha256,
                StringComparison.Ordinal))
        {
            throw new TaskAlignmentContractException(
                "The Task Alignment contract is not bound to the current lifecycle assignment provenance.");
        }

        var actions = NormalizeActions(request.Actions, contract);
        var files = NormalizeFiles(request.FileTouches, contract.TaskId);
        var deviationDecisions = NormalizeDeviationDecisions(
            request.DeviationDecisions,
            graph,
            contract.TaskId);
        var reviews = NormalizeReviewDecisions(request.ReviewDecisions, files);
        EnsureGlobalInputIdentity(actions, files, deviationDecisions, reviews);

        var findings = new List<TaskAlignmentFinding>();
        AddAcknowledgementFinding(graph, contract, findings);
        var goalScore = AnalyzeGoal(contract, actions, findings);
        var scopeScore = AnalyzeScope(
            contract,
            files,
            graph,
            deviationDecisions,
            reviews,
            findings);
        var acceptanceScore = AnalyzeAcceptance(contract, graph, findings);
        AddUnlinkedDeviationFindings(graph, deviationDecisions, findings);

        var hasMissing = findings.Any(item => item.Level == TaskAlignmentFindingLevel.Missing);
        var verdictKind = ResolveVerdict(
            goalScore,
            scopeScore,
            acceptanceScore,
            findings);
        var verdictSupport = ResolveVerdictSupport(verdictKind, findings, contract.TaskId);
        var verdict = new TaskAlignmentVerdict(verdictKind, verdictSupport);
        var analysisSha256 = ComputeAnalysisSha256(
            graph,
            contract,
            actions,
            files,
            deviationDecisions,
            reviews,
            goalScore,
            scopeScore,
            acceptanceScore,
            hasMissing,
            verdict,
            findings);
        return new TaskAlignmentAnalysisResult(
            TaskAlignmentContractRules.Version,
            contract.TaskId,
            goalScore,
            scopeScore,
            acceptanceScore,
            hasMissing,
            verdict,
            findings.ToArray(),
            graph.GraphSha256,
            contract.ContractSha256,
            analysisSha256);
    }

    public static string FileInputId(FileActivityObservation observation) =>
        $"file:{observation.SourceKind}:{observation.SourceInstanceId}:{observation.SourceSequence}";

    public static string LifecycleInputId(Guid eventId) => $"lifecycle:{eventId:D}";

    private static TaskAlignmentActionObservation[] NormalizeActions(
        IReadOnlyList<TaskAlignmentActionObservation> actions,
        TaskAlignmentContract contract)
    {
        ArgumentNullException.ThrowIfNull(actions);
        if (actions.Count > TaskAlignmentContractRules.MaximumItemCount)
        {
            throw new TaskAlignmentContractException("Task Alignment has too many action observations.");
        }

        var stepIds = contract.PlannedSteps
            .Select(item => item.StepId)
            .ToHashSet(StringComparer.Ordinal);
        var result = actions.Select(item =>
        {
            ArgumentNullException.ThrowIfNull(item);
            if (!Enum.IsDefined(item.Outcome))
            {
                throw new TaskAlignmentContractException(
                    "A Task Alignment action has an unsupported outcome.");
            }

            var normalizedActivity = ActivityEventContract.NormalizeAndValidate(
                item.Activity.Envelope,
                item.Activity.IngestSequence);
            if (normalizedActivity != item.Activity ||
                !string.Equals(
                    normalizedActivity.Envelope.TaskId,
                    contract.TaskId,
                    StringComparison.Ordinal))
            {
                throw new TaskAlignmentContractException(
                    "A Task Alignment action is not an exact normalized event for the selected task.");
            }

            var stepId = TaskAlignmentContractRules.NormalizeInputId(item.StepId, nameof(item.StepId));
            if (!stepIds.Contains(stepId))
            {
                throw new TaskAlignmentContractException(
                    $"Task Alignment action references unknown planned step '{stepId}'.");
            }

            return item with
            {
                InputId = TaskAlignmentContractRules.NormalizeInputId(
                    item.InputId,
                    nameof(item.InputId)),
                Activity = normalizedActivity,
                StepId = stepId,
            };
        }).ToArray();
        EnsureUnique(result.Select(item => item.InputId), "action input");
        EnsureUnique(
            result.Select(item => item.Activity.EventIdentitySha256),
            "action event identity");
        return result;
    }

    private static FileActivityObservation[] NormalizeFiles(
        IReadOnlyList<FileActivityObservation> files,
        string taskId)
    {
        ArgumentNullException.ThrowIfNull(files);
        if (files.Count > TaskAlignmentContractRules.MaximumItemCount)
        {
            throw new TaskAlignmentContractException("Task Alignment has too many file observations.");
        }

        var result = files.Select(FileActivityContract.NormalizeAndValidate).ToArray();
        if (result.Any(item =>
                !item.IsAuthorized ||
                item.Confidence != ActivityConfidence.Correlated ||
                !string.Equals(item.TaskId, taskId, StringComparison.Ordinal)))
        {
            throw new TaskAlignmentContractException(
                "Task Alignment file inputs must be authorized, correlated observations for the selected task.");
        }

        EnsureUnique(result.Select(FileInputId), "file input");
        return result;
    }

    private static TaskAlignmentDeviationDecision[] NormalizeDeviationDecisions(
        IReadOnlyList<TaskAlignmentDeviationDecision> decisions,
        AssignmentDelegationGraph graph,
        string taskId)
    {
        ArgumentNullException.ThrowIfNull(decisions);
        if (decisions.Count > TaskAlignmentContractRules.MaximumItemCount)
        {
            throw new TaskAlignmentContractException("Task Alignment has too many deviation decisions.");
        }

        var deviations = graph.Timeline
            .Where(item =>
                item.EventKind == AssignmentLifecycleEventKind.Deviation &&
                item.Disposition == AssignmentLifecycleDisposition.Applied &&
                string.Equals(item.TaskId, taskId, StringComparison.Ordinal))
            .ToDictionary(item => item.EventId);
        var result = decisions.Select(item =>
        {
            ArgumentNullException.ThrowIfNull(item);
            if (!Enum.IsDefined(item.DecisionKind) ||
                !deviations.ContainsKey(item.DeviationEventId))
            {
                throw new TaskAlignmentContractException(
                    "A Task Alignment deviation decision does not reference an applied deviation event.");
            }

            TaskAlignmentContractRules.EnsureUtc(item.DecidedUtc, nameof(item.DecidedUtc));
            return item with
            {
                InputId = TaskAlignmentContractRules.NormalizeInputId(
                    item.InputId,
                    nameof(item.InputId)),
                RequestedPathPrefix = TaskAlignmentContractRules.NormalizePathPrefix(
                    item.RequestedPathPrefix,
                    nameof(item.RequestedPathPrefix)),
                ProvenanceSha256 = TaskAlignmentContractRules.NormalizeSha256(
                    item.ProvenanceSha256,
                    nameof(item.ProvenanceSha256)),
            };
        }).ToArray();
        EnsureUnique(result.Select(item => item.InputId), "deviation decision input");
        EnsureUnique(result.Select(item => item.DeviationEventId.ToString("D")), "deviation event");
        return result;
    }

    private static TaskAlignmentReviewDecision[] NormalizeReviewDecisions(
        IReadOnlyList<TaskAlignmentReviewDecision> reviews,
        IReadOnlyList<FileActivityObservation> files)
    {
        ArgumentNullException.ThrowIfNull(reviews);
        if (reviews.Count > TaskAlignmentContractRules.MaximumItemCount)
        {
            throw new TaskAlignmentContractException("Task Alignment has too many review decisions.");
        }

        var fileIds = files.Select(FileInputId).ToHashSet(StringComparer.Ordinal);
        var result = reviews.Select(item =>
        {
            ArgumentNullException.ThrowIfNull(item);
            if (!Enum.IsDefined(item.DecisionKind))
            {
                throw new TaskAlignmentContractException(
                    "A Task Alignment review has an unsupported decision.");
            }

            TaskAlignmentContractRules.EnsureUtc(item.DecidedUtc, nameof(item.DecidedUtc));
            var target = TaskAlignmentContractRules.NormalizeInputId(
                item.TargetInputId,
                nameof(item.TargetInputId));
            if (!fileIds.Contains(target))
            {
                throw new TaskAlignmentContractException(
                    "A Task Alignment review must target an admitted file observation.");
            }

            return item with
            {
                InputId = TaskAlignmentContractRules.NormalizeInputId(
                    item.InputId,
                    nameof(item.InputId)),
                TargetInputId = target,
                ReviewerActorId = TaskAlignmentContractRules.NormalizeInputId(
                    item.ReviewerActorId,
                    nameof(item.ReviewerActorId)),
                ProvenanceSha256 = TaskAlignmentContractRules.NormalizeSha256(
                    item.ProvenanceSha256,
                    nameof(item.ProvenanceSha256)),
            };
        }).ToArray();
        EnsureUnique(result.Select(item => item.InputId), "review decision input");
        EnsureUnique(result.Select(item => item.TargetInputId), "review target");
        return result;
    }

    private static void EnsureGlobalInputIdentity(
        IReadOnlyList<TaskAlignmentActionObservation> actions,
        IReadOnlyList<FileActivityObservation> files,
        IReadOnlyList<TaskAlignmentDeviationDecision> deviations,
        IReadOnlyList<TaskAlignmentReviewDecision> reviews)
    {
        var ids = actions.Select(item => item.InputId)
            .Concat(files.Select(FileInputId))
            .Concat(deviations.Select(item => item.InputId))
            .Concat(reviews.Select(item => item.InputId))
            .ToArray();
        EnsureUnique(ids, "global analysis input");
    }

    private static void AddAcknowledgementFinding(
        AssignmentDelegationGraph graph,
        TaskAlignmentContract contract,
        ICollection<TaskAlignmentFinding> findings)
    {
        var acknowledgement = graph.Timeline
            .Where(item =>
                item.EventKind == AssignmentLifecycleEventKind.Acknowledgement &&
                item.Disposition == AssignmentLifecycleDisposition.Applied &&
                string.Equals(item.TaskId, contract.TaskId, StringComparison.Ordinal))
            .OrderBy(item => item.Sequence)
            .FirstOrDefault();
        var contractInput = TaskAlignmentContractRules.ContractInputId(contract.TaskId);
        findings.Add(acknowledgement is null
            ? Finding(
                "finding:acknowledgement:missing",
                TaskAlignmentFindingCode.AcknowledgementMissing,
                TaskAlignmentFindingLevel.Missing,
                TaskAlignmentDimension.Acknowledgement,
                contractInput,
                contract.TaskId,
                null,
                null,
                contractInput)
            : Finding(
                "finding:acknowledgement:confirmed",
                TaskAlignmentFindingCode.AcknowledgementConfirmed,
                TaskAlignmentFindingLevel.Pass,
                TaskAlignmentDimension.Acknowledgement,
                contractInput,
                acknowledgement.ActorId,
                null,
                null,
                contractInput,
                LifecycleInputId(acknowledgement.EventId)));
    }

    private static int? AnalyzeGoal(
        TaskAlignmentContract contract,
        IReadOnlyList<TaskAlignmentActionObservation> actions,
        ICollection<TaskAlignmentFinding> findings)
    {
        if (actions.Count == 0)
        {
            findings.Add(Finding(
                "finding:actions:missing",
                TaskAlignmentFindingCode.ObservedActionsMissing,
                TaskAlignmentFindingLevel.Missing,
                TaskAlignmentDimension.Goal,
                TaskAlignmentContractRules.ContractInputId(contract.TaskId),
                contract.TaskId,
                null,
                100,
                TaskAlignmentContractRules.ContractInputId(contract.TaskId)));
        }

        var score = 0;
        foreach (var step in contract.PlannedSteps)
        {
            var matches = actions
                .Where(item => string.Equals(item.StepId, step.StepId, StringComparison.Ordinal))
                .OrderBy(item => item.Activity.IngestSequence)
                .ToArray();
            var best = matches.Any(item => item.Outcome == TaskAlignmentActionOutcome.Completed)
                ? TaskAlignmentActionOutcome.Completed
                : matches.Any(item => item.Outcome == TaskAlignmentActionOutcome.Started)
                    ? TaskAlignmentActionOutcome.Started
                    : matches.Any(item => item.Outcome == TaskAlignmentActionOutcome.Failed)
                        ? TaskAlignmentActionOutcome.Failed
                        : (TaskAlignmentActionOutcome?)null;
            var earned = best switch
            {
                TaskAlignmentActionOutcome.Completed => step.WeightPercent,
                TaskAlignmentActionOutcome.Started => step.WeightPercent / 2,
                _ => 0,
            };
            score += earned;
            var code = best switch
            {
                TaskAlignmentActionOutcome.Completed => TaskAlignmentFindingCode.StepCompleted,
                TaskAlignmentActionOutcome.Started => TaskAlignmentFindingCode.StepStarted,
                TaskAlignmentActionOutcome.Failed => TaskAlignmentFindingCode.StepFailed,
                _ => TaskAlignmentFindingCode.StepMissing,
            };
            var level = best switch
            {
                TaskAlignmentActionOutcome.Completed => TaskAlignmentFindingLevel.Pass,
                TaskAlignmentActionOutcome.Started => TaskAlignmentFindingLevel.Attention,
                TaskAlignmentActionOutcome.Failed => TaskAlignmentFindingLevel.Attention,
                _ => TaskAlignmentFindingLevel.Missing,
            };
            findings.Add(Finding(
                $"finding:step:{step.StepId}",
                code,
                level,
                TaskAlignmentDimension.Goal,
                TaskAlignmentContractRules.StepInputId(step.StepId),
                step.StepId,
                earned,
                step.WeightPercent,
                [
                    TaskAlignmentContractRules.StepInputId(step.StepId),
                    .. matches.Select(item => item.InputId),
                ]));
        }

        return actions.Count == 0 ? null : score;
    }

    private static int? AnalyzeScope(
        TaskAlignmentContract contract,
        IReadOnlyList<FileActivityObservation> files,
        AssignmentDelegationGraph graph,
        IReadOnlyList<TaskAlignmentDeviationDecision> deviations,
        IReadOnlyList<TaskAlignmentReviewDecision> reviews,
        ICollection<TaskAlignmentFinding> findings)
    {
        if (files.Count == 0)
        {
            findings.Add(Finding(
                "finding:files:missing",
                TaskAlignmentFindingCode.FileObservationsMissing,
                TaskAlignmentFindingLevel.Missing,
                TaskAlignmentDimension.Scope,
                TaskAlignmentContractRules.ContractInputId(contract.TaskId),
                contract.TaskId,
                null,
                100,
                TaskAlignmentContractRules.ContractInputId(contract.TaskId)));
            return null;
        }

        var scores = new List<int>();
        foreach (var file in files)
        {
            var inputId = FileInputId(file);
            var path = file.RelativePath.Replace('\\', '/');
            var matchingRules = contract.ScopeRules
                .Where(item => IsWithinPrefix(path, item.PathPrefix))
                .ToArray();
            var denied = matchingRules.Any(item =>
                item.RuleKind == TaskAlignmentScopeRuleKind.DenyPathPrefix);
            var allowed = !denied && matchingRules.Any(item =>
                item.RuleKind == TaskAlignmentScopeRuleKind.AllowPathPrefix);
            var supportingRules = matchingRules
                .Select(item => TaskAlignmentContractRules.ScopeInputId(item.RuleId))
                .DefaultIfEmpty(TaskAlignmentContractRules.ContractInputId(contract.TaskId))
                .ToArray();
            if (allowed)
            {
                scores.Add(100);
                findings.Add(Finding(
                    $"finding:scope:{inputId}",
                    TaskAlignmentFindingCode.ScopeCompliant,
                    TaskAlignmentFindingLevel.Pass,
                    TaskAlignmentDimension.Scope,
                    supportingRules[0],
                    path,
                    100,
                    100,
                    [inputId, .. supportingRules]));
                continue;
            }

            var deviation = deviations
                .Where(item => IsWithinPrefix(path, item.RequestedPathPrefix))
                .OrderByDescending(item => item.RequestedPathPrefix.Length)
                .ThenBy(item => item.DecidedUtc)
                .FirstOrDefault();
            var review = reviews.SingleOrDefault(item =>
                string.Equals(item.TargetInputId, inputId, StringComparison.Ordinal));
            var deviationEvent = deviation is null
                ? null
                : graph.Timeline.Single(item => item.EventId == deviation.DeviationEventId);
            var supporting = new List<string> { inputId };
            supporting.AddRange(supportingRules);
            if (deviation is not null)
            {
                supporting.Add(deviation.InputId);
                supporting.Add(LifecycleInputId(deviation.DeviationEventId));
            }

            if (review is not null)
            {
                supporting.Add(review.InputId);
            }

            if (review?.DecisionKind == TaskAlignmentReviewDecisionKind.ConfirmedViolation)
            {
                scores.Add(0);
                findings.Add(Finding(
                    $"finding:scope:{inputId}",
                    TaskAlignmentFindingCode.ScopeConfirmedViolation,
                    TaskAlignmentFindingLevel.Confirmed,
                    TaskAlignmentDimension.Scope,
                    supportingRules[0],
                    path,
                    0,
                    100,
                    supporting));
            }
            else if (review?.DecisionKind == TaskAlignmentReviewDecisionKind.Dismissed)
            {
                scores.Add(100);
                findings.Add(Finding(
                    $"finding:scope:{inputId}",
                    TaskAlignmentFindingCode.ScopeReviewDismissed,
                    TaskAlignmentFindingLevel.Pass,
                    TaskAlignmentDimension.Scope,
                    supportingRules[0],
                    path,
                    100,
                    100,
                    supporting));
            }
            else if (deviation?.DecisionKind == TaskAlignmentDeviationDecisionKind.Approved)
            {
                scores.Add(100);
                findings.Add(Finding(
                    $"finding:scope:{inputId}",
                    TaskAlignmentFindingCode.ScopeApprovedDeviation,
                    TaskAlignmentFindingLevel.Pass,
                    TaskAlignmentDimension.Deviation,
                    supportingRules[0],
                    deviationEvent?.DeviationReason ?? path,
                    100,
                    100,
                    supporting));
            }
            else if (deviation?.DecisionKind == TaskAlignmentDeviationDecisionKind.Pending)
            {
                scores.Add(50);
                findings.Add(Finding(
                    $"finding:scope:{inputId}",
                    TaskAlignmentFindingCode.ScopePendingDeviation,
                    TaskAlignmentFindingLevel.Attention,
                    TaskAlignmentDimension.Deviation,
                    supportingRules[0],
                    deviationEvent?.DeviationReason ?? path,
                    50,
                    100,
                    supporting));
            }
            else
            {
                scores.Add(0);
                findings.Add(Finding(
                    $"finding:scope:{inputId}",
                    TaskAlignmentFindingCode.ScopeSuspectedViolation,
                    TaskAlignmentFindingLevel.Suspected,
                    TaskAlignmentDimension.Scope,
                    supportingRules[0],
                    path,
                    0,
                    100,
                    supporting));
            }
        }

        return (int)Math.Round(scores.Average(), MidpointRounding.AwayFromZero);
    }

    private static int? AnalyzeAcceptance(
        TaskAlignmentContract contract,
        AssignmentDelegationGraph graph,
        ICollection<TaskAlignmentFinding> findings)
    {
        var evidence = graph.Timeline
            .Where(item =>
                item.EventKind == AssignmentLifecycleEventKind.Evidence &&
                item.Disposition == AssignmentLifecycleDisposition.Applied &&
                item.EvidenceReference is not null &&
                string.Equals(item.TaskId, contract.TaskId, StringComparison.Ordinal))
            .OrderBy(item => item.Sequence)
            .ToArray();
        if (evidence.Length == 0)
        {
            findings.Add(Finding(
                "finding:evidence:missing",
                TaskAlignmentFindingCode.EvidenceMissing,
                TaskAlignmentFindingLevel.Missing,
                TaskAlignmentDimension.Evidence,
                TaskAlignmentContractRules.ContractInputId(contract.TaskId),
                contract.TaskId,
                null,
                100,
                TaskAlignmentContractRules.ContractInputId(contract.TaskId)));
        }

        var score = 0;
        foreach (var criterion in contract.AcceptanceCriteria)
        {
            var matchesByPattern = criterion.RequiredEvidencePatterns.Select(pattern =>
                evidence.Where(item =>
                        item.EvidenceReference!.Contains(pattern, StringComparison.OrdinalIgnoreCase))
                    .ToArray()).ToArray();
            var matchedPatternCount = matchesByPattern.Count(matches => matches.Length > 0);
            var earned = matchedPatternCount == criterion.RequiredEvidencePatterns.Count
                ? criterion.WeightPercent
                : matchedPatternCount > 0
                    ? criterion.WeightPercent / 2
                    : 0;
            score += earned;
            var code = matchedPatternCount == criterion.RequiredEvidencePatterns.Count
                ? TaskAlignmentFindingCode.AcceptanceSatisfied
                : matchedPatternCount > 0
                    ? TaskAlignmentFindingCode.AcceptancePartial
                    : TaskAlignmentFindingCode.AcceptanceMissing;
            var level = matchedPatternCount == criterion.RequiredEvidencePatterns.Count
                ? TaskAlignmentFindingLevel.Pass
                : matchedPatternCount > 0
                    ? TaskAlignmentFindingLevel.Attention
                    : TaskAlignmentFindingLevel.Missing;
            var matchingEvidence = matchesByPattern
                .SelectMany(item => item)
                .DistinctBy(item => item.EventId)
                .Select(item => LifecycleInputId(item.EventId));
            findings.Add(Finding(
                $"finding:criterion:{criterion.CriterionId}",
                code,
                level,
                TaskAlignmentDimension.AcceptanceCriteria,
                TaskAlignmentContractRules.CriterionInputId(criterion.CriterionId),
                criterion.CriterionId,
                earned,
                criterion.WeightPercent,
                [
                    TaskAlignmentContractRules.CriterionInputId(criterion.CriterionId),
                    .. matchingEvidence,
                ]));
        }

        return evidence.Length == 0 ? null : score;
    }

    private static void AddUnlinkedDeviationFindings(
        AssignmentDelegationGraph graph,
        IReadOnlyList<TaskAlignmentDeviationDecision> decisions,
        ICollection<TaskAlignmentFinding> findings)
    {
        var linkedDecisionIds = findings
            .SelectMany(item => item.SupportingInputIds)
            .ToHashSet(StringComparer.Ordinal);
        foreach (var decision in decisions.Where(item => !linkedDecisionIds.Contains(item.InputId)))
        {
            var lifecycle = graph.Timeline.Single(item => item.EventId == decision.DeviationEventId);
            findings.Add(Finding(
                $"finding:deviation:{decision.InputId}",
                TaskAlignmentFindingCode.DeviationUnlinked,
                TaskAlignmentFindingLevel.Attention,
                TaskAlignmentDimension.Deviation,
                TaskAlignmentContractRules.ContractInputId(lifecycle.TaskId),
                lifecycle.DeviationReason ?? decision.RequestedPathPrefix,
                null,
                null,
                decision.InputId,
                LifecycleInputId(decision.DeviationEventId)));
        }
    }

    private static TaskAlignmentVerdictKind ResolveVerdict(
        int? goalScore,
        int? scopeScore,
        int? acceptanceScore,
        IReadOnlyList<TaskAlignmentFinding> findings)
    {
        if (findings.Any(item => item.Level == TaskAlignmentFindingLevel.Confirmed))
        {
            return TaskAlignmentVerdictKind.ConfirmedViolation;
        }

        if (findings.Any(item => item.Level == TaskAlignmentFindingLevel.Suspected))
        {
            return TaskAlignmentVerdictKind.SuspectedViolation;
        }

        if (goalScore is null || scopeScore is null || acceptanceScore is null ||
            findings.Any(item => item.Code == TaskAlignmentFindingCode.AcknowledgementMissing))
        {
            return TaskAlignmentVerdictKind.InsufficientData;
        }

        if (goalScore < 100 || scopeScore < 100 || acceptanceScore < 100 ||
            findings.Any(item => item.Level is
                TaskAlignmentFindingLevel.Attention or
                TaskAlignmentFindingLevel.Missing))
        {
            return TaskAlignmentVerdictKind.PartiallyMisaligned;
        }

        return TaskAlignmentVerdictKind.Aligned;
    }

    private static IReadOnlyList<string> ResolveVerdictSupport(
        TaskAlignmentVerdictKind kind,
        IReadOnlyList<TaskAlignmentFinding> findings,
        string taskId)
    {
        var levels = kind switch
        {
            TaskAlignmentVerdictKind.ConfirmedViolation =>
                new[] { TaskAlignmentFindingLevel.Confirmed },
            TaskAlignmentVerdictKind.SuspectedViolation =>
                new[] { TaskAlignmentFindingLevel.Suspected },
            TaskAlignmentVerdictKind.InsufficientData =>
                new[] { TaskAlignmentFindingLevel.Missing },
            TaskAlignmentVerdictKind.PartiallyMisaligned =>
                new[] { TaskAlignmentFindingLevel.Attention, TaskAlignmentFindingLevel.Missing },
            _ => new[] { TaskAlignmentFindingLevel.Pass },
        };
        var support = findings
            .Where(item => levels.Contains(item.Level))
            .SelectMany(item => item.SupportingInputIds)
            .Distinct(StringComparer.Ordinal)
            .Order(StringComparer.Ordinal)
            .ToArray();
        return support.Length == 0
            ? [TaskAlignmentContractRules.ContractInputId(taskId)]
            : support;
    }

    private static TaskAlignmentFinding Finding(
        string findingId,
        TaskAlignmentFindingCode code,
        TaskAlignmentFindingLevel level,
        TaskAlignmentDimension dimension,
        string clauseId,
        string subject,
        int? earned,
        int? maximum,
        params string[] supportingInputIds) =>
        Finding(
            findingId,
            code,
            level,
            dimension,
            clauseId,
            subject,
            earned,
            maximum,
            (IEnumerable<string>)supportingInputIds);

    private static TaskAlignmentFinding Finding(
        string findingId,
        TaskAlignmentFindingCode code,
        TaskAlignmentFindingLevel level,
        TaskAlignmentDimension dimension,
        string clauseId,
        string subject,
        int? earned,
        int? maximum,
        IEnumerable<string> supportingInputIds)
    {
        var support = supportingInputIds
            .Distinct(StringComparer.Ordinal)
            .Order(StringComparer.Ordinal)
            .ToArray();
        if (support.Length == 0)
        {
            throw new TaskAlignmentContractException(
                "Every Task Alignment finding must retain at least one supporting input.");
        }

        return new TaskAlignmentFinding(
            findingId,
            code,
            level,
            dimension,
            clauseId,
            subject,
            earned,
            maximum,
            support);
    }

    private static bool IsWithinPrefix(string path, string prefix)
    {
        var normalizedPath = path.Replace('\\', '/').TrimStart('/');
        var normalizedPrefix = prefix.Replace('\\', '/').TrimStart('/');
        return normalizedPath.StartsWith(normalizedPrefix, StringComparison.OrdinalIgnoreCase) ||
               string.Equals(
                   normalizedPath,
                   normalizedPrefix.TrimEnd('/'),
                   StringComparison.OrdinalIgnoreCase);
    }

    private static void EnsureUnique(IEnumerable<string> values, string name)
    {
        var array = values.ToArray();
        if (array.Distinct(StringComparer.Ordinal).Count() != array.Length)
        {
            throw new TaskAlignmentContractException(
                $"Task Alignment {name} values must be unique.");
        }
    }

    private static string ComputeAnalysisSha256(
        AssignmentDelegationGraph graph,
        TaskAlignmentContract contract,
        IReadOnlyList<TaskAlignmentActionObservation> actions,
        IReadOnlyList<FileActivityObservation> files,
        IReadOnlyList<TaskAlignmentDeviationDecision> deviations,
        IReadOnlyList<TaskAlignmentReviewDecision> reviews,
        int? goalScore,
        int? scopeScore,
        int? acceptanceScore,
        bool hasMissing,
        TaskAlignmentVerdict verdict,
        IReadOnlyList<TaskAlignmentFinding> findings)
    {
        using var writer = new CanonicalHashWriter("HerdrOps.TaskAlignmentAnalysis.v1");
        writer.Write(graph.GraphSha256);
        writer.Write(contract.ContractSha256);
        writer.Write(actions.Count);
        foreach (var action in actions.OrderBy(item => item.InputId, StringComparer.Ordinal))
        {
            writer.Write(action.InputId);
            writer.Write(action.Activity.EnvelopeSha256);
            writer.Write(action.StepId);
            writer.Write((int)action.Outcome);
        }

        writer.Write(files.Count);
        foreach (var file in files.OrderBy(FileInputId, StringComparer.Ordinal))
        {
            writer.Write(FileInputId(file));
            writer.Write(file.ObservedUtc);
            writer.Write((int)file.Operation);
            writer.Write(file.RelativePath);
            writer.Write((int)file.SourceKind);
            writer.Write((int)file.Confidence);
            writer.Write(file.TaskId);
        }

        writer.Write(deviations.Count);
        foreach (var deviation in deviations.OrderBy(item => item.InputId, StringComparer.Ordinal))
        {
            writer.Write(deviation.InputId);
            writer.Write(deviation.DeviationEventId.ToString("D"));
            writer.Write((int)deviation.DecisionKind);
            writer.Write(deviation.RequestedPathPrefix);
            writer.Write(deviation.DecidedUtc);
            writer.Write(deviation.ProvenanceSha256);
        }

        writer.Write(reviews.Count);
        foreach (var review in reviews.OrderBy(item => item.InputId, StringComparer.Ordinal))
        {
            writer.Write(review.InputId);
            writer.Write(review.TargetInputId);
            writer.Write((int)review.DecisionKind);
            writer.Write(review.ReviewerActorId);
            writer.Write(review.DecidedUtc);
            writer.Write(review.ProvenanceSha256);
        }

        writer.Write(goalScore ?? -1);
        writer.Write(scopeScore ?? -1);
        writer.Write(acceptanceScore ?? -1);
        writer.Write(hasMissing);
        writer.Write((int)verdict.Kind);
        writer.Write(verdict.SupportingInputIds.Count);
        foreach (var inputId in verdict.SupportingInputIds)
        {
            writer.Write(inputId);
        }

        writer.Write(findings.Count);
        foreach (var finding in findings.OrderBy(item => item.FindingId, StringComparer.Ordinal))
        {
            writer.Write(finding.FindingId);
            writer.Write((int)finding.Code);
            writer.Write((int)finding.Level);
            writer.Write((int)finding.Dimension);
            writer.Write(finding.ClauseId);
            writer.Write(finding.Subject);
            writer.Write(finding.EarnedScore ?? -1);
            writer.Write(finding.MaximumScore ?? -1);
            writer.Write(finding.SupportingInputIds.Count);
            foreach (var inputId in finding.SupportingInputIds)
            {
                writer.Write(inputId);
            }
        }

        return writer.Finish();
    }
}

public sealed class TaskAlignmentContractException : ArgumentException
{
    public TaskAlignmentContractException(string message)
        : base(message)
    {
    }
}
