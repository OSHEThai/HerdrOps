using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using HerdrOps.App.Live;
using HerdrOps.App.Localization;
using HerdrOps.App.Overview;
using HerdrOps.Domain.Activity;
using HerdrOps.Domain.Assignments;

namespace HerdrOps.App.Alignment;

public sealed record TaskAlignmentHeader(
    string TaskId,
    string Goal,
    string AssigneeInitials,
    string AssigneeName,
    string AssignmentTime,
    string GoalScore,
    string ScopeScore,
    string AcceptanceScore,
    string Verdict,
    string VerdictDetail,
    string VerdictBrushKey,
    string VerdictGlyph);

public sealed record TaskAlignmentPanelItem(
    string ItemId,
    string Marker,
    string Title,
    string Detail,
    string Status,
    string StatusBrushKey,
    string Provenance);

public sealed class TaskAlignmentState : ObservableState
{
    private readonly bool _syntheticPreview;
    private TaskAlignmentAnalysisRequest? _request;
    private TaskAlignmentAnalysisResult? _analysis;
    private string _projectLabel = UiLanguageService.Shared["AlignmentNoProject"];
    private string _sourceLabel = UiLanguageService.Shared["AlignmentWaitingSource"];
    private string _evidenceBoundary = UiLanguageService.Shared["AlignmentUnavailableBoundary"];
    private string _traceLabel = UiLanguageService.Shared["AlignmentNoTrace"];
    private TaskAlignmentHeader _header = EmptyHeader();
    private IReadOnlyList<TaskAlignmentPanelItem> _contractItems = [];
    private IReadOnlyList<TaskAlignmentPanelItem> _acknowledgementItems = [];
    private IReadOnlyList<TaskAlignmentPanelItem> _plannedSteps = [];
    private IReadOnlyList<TaskAlignmentPanelItem> _acceptanceCriteria = [];
    private IReadOnlyList<TaskAlignmentPanelItem> _filesTouched = [];
    private IReadOnlyList<TaskAlignmentPanelItem> _observedActions = [];
    private IReadOnlyList<TaskAlignmentPanelItem> _deviationRequests = [];
    private IReadOnlyList<TaskAlignmentPanelItem> _evidenceItems = [];
    private string? _sourceLocalizationKey = "AlignmentWaitingSource";
    private string? _boundaryLocalizationKey = "AlignmentUnavailableBoundary";

    public TaskAlignmentState()
        : this(syntheticPreview: false)
    {
    }

    private TaskAlignmentState(bool syntheticPreview)
    {
        _syntheticPreview = syntheticPreview;
        if (syntheticPreview)
        {
            ApplySyntheticFixture();
        }
    }

    public static TaskAlignmentState CreateSyntheticPreview() => new(syntheticPreview: true);

    public string ProjectLabel { get => _projectLabel; private set => Set(ref _projectLabel, value); }

    public string SourceLabel { get => _sourceLabel; private set => Set(ref _sourceLabel, value); }

    public string EvidenceBoundary
    {
        get => _evidenceBoundary;
        private set => Set(ref _evidenceBoundary, value);
    }

    public string TraceLabel { get => _traceLabel; private set => Set(ref _traceLabel, value); }

    public TaskAlignmentHeader Header { get => _header; private set => Set(ref _header, value); }

    public IReadOnlyList<TaskAlignmentPanelItem> ContractItems
    {
        get => _contractItems;
        private set => Set(ref _contractItems, value);
    }

    public IReadOnlyList<TaskAlignmentPanelItem> AcknowledgementItems
    {
        get => _acknowledgementItems;
        private set => Set(ref _acknowledgementItems, value);
    }

    public IReadOnlyList<TaskAlignmentPanelItem> PlannedSteps
    {
        get => _plannedSteps;
        private set => Set(ref _plannedSteps, value);
    }

    public IReadOnlyList<TaskAlignmentPanelItem> AcceptanceCriteria
    {
        get => _acceptanceCriteria;
        private set => Set(ref _acceptanceCriteria, value);
    }

    public IReadOnlyList<TaskAlignmentPanelItem> FilesTouched
    {
        get => _filesTouched;
        private set => Set(ref _filesTouched, value);
    }

    public IReadOnlyList<TaskAlignmentPanelItem> ObservedActions
    {
        get => _observedActions;
        private set => Set(ref _observedActions, value);
    }

    public IReadOnlyList<TaskAlignmentPanelItem> DeviationRequests
    {
        get => _deviationRequests;
        private set => Set(ref _deviationRequests, value);
    }

    public IReadOnlyList<TaskAlignmentPanelItem> EvidenceItems
    {
        get => _evidenceItems;
        private set => Set(ref _evidenceItems, value);
    }

    public bool HasAnalysis => _analysis is not null;

    public bool HasExactTask(string taskId) =>
        _analysis is not null &&
        !string.IsNullOrWhiteSpace(taskId) &&
        string.Equals(_analysis.TaskId, taskId, StringComparison.Ordinal);

    public void ApplyAnalysis(
        TaskAlignmentAnalysisRequest request,
        string projectLabel,
        string sourceLabel,
        string evidenceBoundary)
    {
        ArgumentNullException.ThrowIfNull(request);
        ArgumentException.ThrowIfNullOrWhiteSpace(projectLabel);
        ArgumentException.ThrowIfNullOrWhiteSpace(sourceLabel);
        ArgumentException.ThrowIfNullOrWhiteSpace(evidenceBoundary);
        _request = request;
        _analysis = TaskAlignmentAnalyzer.Analyze(request);
        _sourceLocalizationKey = null;
        _boundaryLocalizationKey = null;
        ProjectLabel = projectLabel;
        SourceLabel = sourceLabel;
        EvidenceBoundary = evidenceBoundary;
        Raise(nameof(HasAnalysis));
        RefreshProjection();
    }

    public void MarkUnavailable(
        string projectLabel,
        string sourceLabel,
        string evidenceBoundary)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(projectLabel);
        ArgumentException.ThrowIfNullOrWhiteSpace(sourceLabel);
        ArgumentException.ThrowIfNullOrWhiteSpace(evidenceBoundary);
        _request = null;
        _analysis = null;
        _sourceLocalizationKey = null;
        _boundaryLocalizationKey = null;
        ProjectLabel = projectLabel;
        SourceLabel = sourceLabel;
        EvidenceBoundary = evidenceBoundary;
        TraceLabel = UiLanguageService.Shared["AlignmentNoTrace"];
        Header = EmptyHeader();
        ContractItems = [];
        AcknowledgementItems = [];
        PlannedSteps = [];
        AcceptanceCriteria = [];
        FilesTouched = [];
        ObservedActions = [];
        DeviationRequests = [];
        EvidenceItems = [];
        Raise(nameof(HasAnalysis));
    }

    public void MarkUnavailableFromCatalog(
        string projectLabel,
        string sourceLocalizationKey,
        string boundaryLocalizationKey)
    {
        MarkUnavailable(
            projectLabel,
            UiLanguageService.Shared[sourceLocalizationKey],
            UiLanguageService.Shared[boundaryLocalizationKey]);
        _sourceLocalizationKey = sourceLocalizationKey;
        _boundaryLocalizationKey = boundaryLocalizationKey;
    }

    public void RefreshLanguage()
    {
        if (_syntheticPreview)
        {
            ApplySyntheticFixture();
            return;
        }

        if (_sourceLocalizationKey is { } sourceKey)
        {
            SourceLabel = UiLanguageService.Shared[sourceKey];
        }

        if (_boundaryLocalizationKey is { } boundaryKey)
        {
            EvidenceBoundary = UiLanguageService.Shared[boundaryKey];
        }

        RefreshProjection();
    }

    private void RefreshProjection()
    {
        if (_request is null || _analysis is null)
        {
            return;
        }

        var text = UiLanguageService.Shared;
        var graph = AssignmentDelegationGraphProjector.Create(_request.LifecycleReplay);
        var task = graph.Tasks.Single(item =>
            string.Equals(item.TaskId, _analysis.TaskId, StringComparison.Ordinal));
        var assignment = graph.Timeline.Single(item =>
            item.EventId == _request.Contract.AssignmentEventId);
        var verdictBrush = BrushForVerdict(_analysis.Verdict.Kind);
        Header = new TaskAlignmentHeader(
            _analysis.TaskId,
            _request.Contract.Goal,
            Initials(DisplayActor(task.CurrentAssigneeId)),
            DisplayActor(task.CurrentAssigneeId),
            assignment.AcceptedUtc.ToLocalTime().ToString("g", CurrentUiCulture()),
            Score(_analysis.GoalAlignmentScore),
            Score(_analysis.ScopeComplianceScore),
            Score(_analysis.AcceptanceCriteriaScore),
            DisplayVerdict(_analysis.Verdict.Kind),
            DisplayVerdictDetail(_analysis.Verdict.Kind),
            verdictBrush,
            _analysis.Verdict.Kind == TaskAlignmentVerdictKind.Aligned ? "\uE73E" : "\uE7BA");
        TraceLabel = text.Format(
            "AlignmentTraceFormat",
            ShortHash(_analysis.AnalysisSha256),
            ShortHash(_analysis.ContractSha256),
            ShortHash(_analysis.LifecycleGraphSha256));
        ContractItems = CreateContractItems(_request.Contract);
        AcknowledgementItems = CreateAcknowledgementItems(graph, _request.Contract.TaskId);
        PlannedSteps = CreatePlannedStepItems(_request.Contract, _analysis);
        AcceptanceCriteria = CreateCriterionItems(_request.Contract, _analysis);
        FilesTouched = CreateFileItems(_request.FileTouches, _analysis);
        ObservedActions = CreateActionItems(_request.Actions);
        DeviationRequests = CreateDeviationItems(_request.DeviationDecisions, graph);
        EvidenceItems = CreateEvidenceItems(graph, _request.Contract.TaskId);
    }

    private static IReadOnlyList<TaskAlignmentPanelItem> CreateContractItems(
        TaskAlignmentContract contract)
    {
        var text = UiLanguageService.Shared;
        var result = new List<TaskAlignmentPanelItem>
        {
            new(
                "contract-goal",
                "◎",
                text["AlignmentGoal"],
                contract.Goal,
                text["AlignmentContractBound"],
                OverviewBrushKeys.Primary,
                TaskAlignmentContractRules.ContractInputId(contract.TaskId)),
        };
        result.AddRange(contract.ScopeRules.Select(rule => new TaskAlignmentPanelItem(
            $"scope-{rule.RuleId}",
            rule.RuleKind == TaskAlignmentScopeRuleKind.AllowPathPrefix ? "+" : "−",
            rule.PathPrefix,
            rule.Description,
            rule.RuleKind == TaskAlignmentScopeRuleKind.AllowPathPrefix
                ? text["AlignmentScopeAllowed"]
                : text["AlignmentScopeDenied"],
            rule.RuleKind == TaskAlignmentScopeRuleKind.AllowPathPrefix
                ? OverviewBrushKeys.Working
                : OverviewBrushKeys.Blocked,
            TaskAlignmentContractRules.ScopeInputId(rule.RuleId))));
        result.AddRange(contract.Constraints.Select(constraint => new TaskAlignmentPanelItem(
            $"constraint-{constraint.ConstraintId}",
            "!",
            text["AlignmentConstraint"],
            constraint.Description,
            text["AlignmentRequired"],
            OverviewBrushKeys.Idle,
            $"contract:constraint:{constraint.ConstraintId}")));
        return result;
    }

    private static IReadOnlyList<TaskAlignmentPanelItem> CreateAcknowledgementItems(
        AssignmentDelegationGraph graph,
        string taskId)
    {
        var text = UiLanguageService.Shared;
        var acknowledgement = graph.Timeline.FirstOrDefault(item =>
            item.EventKind == AssignmentLifecycleEventKind.Acknowledgement &&
            item.Disposition == AssignmentLifecycleDisposition.Applied &&
            string.Equals(item.TaskId, taskId, StringComparison.Ordinal));
        return acknowledgement is null
            ? [new(
                "acknowledgement-missing",
                "!",
                text["AlignmentAcknowledgementMissing"],
                text["AlignmentRequiredDataMissing"],
                text["AlignmentStatusMissing"],
                OverviewBrushKeys.Offline,
                TaskAlignmentContractRules.ContractInputId(taskId))]
            : [new(
                $"acknowledgement-{acknowledgement.EventId:D}",
                Initials(DisplayActor(acknowledgement.ActorId)),
                DisplayActor(acknowledgement.ActorId),
                acknowledgement.AcceptedUtc.ToLocalTime().ToString("g", CurrentUiCulture()),
                text["AlignmentAcknowledged"],
                OverviewBrushKeys.Working,
                TaskAlignmentAnalyzer.LifecycleInputId(acknowledgement.EventId))];
    }

    private static IReadOnlyList<TaskAlignmentPanelItem> CreatePlannedStepItems(
        TaskAlignmentContract contract,
        TaskAlignmentAnalysisResult analysis) =>
        contract.PlannedSteps.Select((step, index) =>
        {
            var finding = analysis.Findings.Single(item =>
                string.Equals(
                    item.ClauseId,
                    TaskAlignmentContractRules.StepInputId(step.StepId),
                    StringComparison.Ordinal));
            return new TaskAlignmentPanelItem(
                $"step-{step.StepId}",
                (index + 1).ToString(CultureInfo.InvariantCulture),
                step.Description,
                UiLanguageService.Shared.Format("AlignmentWeightFormat", step.WeightPercent),
                DisplayFinding(finding.Code),
                BrushForLevel(finding.Level),
                string.Join(" · ", finding.SupportingInputIds));
        }).ToArray();

    private static IReadOnlyList<TaskAlignmentPanelItem> CreateCriterionItems(
        TaskAlignmentContract contract,
        TaskAlignmentAnalysisResult analysis) =>
        contract.AcceptanceCriteria.Select((criterion, index) =>
        {
            var finding = analysis.Findings.Single(item =>
                string.Equals(
                    item.ClauseId,
                    TaskAlignmentContractRules.CriterionInputId(criterion.CriterionId),
                    StringComparison.Ordinal));
            return new TaskAlignmentPanelItem(
                $"criterion-{criterion.CriterionId}",
                (index + 1).ToString(CultureInfo.InvariantCulture),
                criterion.Description,
                string.Join(" · ", criterion.RequiredEvidencePatterns),
                DisplayFinding(finding.Code),
                BrushForLevel(finding.Level),
                string.Join(" · ", finding.SupportingInputIds));
        }).ToArray();

    private static IReadOnlyList<TaskAlignmentPanelItem> CreateFileItems(
        IReadOnlyList<FileActivityObservation> files,
        TaskAlignmentAnalysisResult analysis)
    {
        var text = UiLanguageService.Shared;
        return files.Select(file =>
        {
            var inputId = TaskAlignmentAnalyzer.FileInputId(file);
            var finding = analysis.Findings.Single(item =>
                item.SupportingInputIds.Contains(inputId, StringComparer.Ordinal) &&
                item.Dimension is TaskAlignmentDimension.Scope or TaskAlignmentDimension.Deviation);
            return new TaskAlignmentPanelItem(
                inputId,
                "▧",
                file.RelativePath,
                text.Format(
                    "AlignmentFileDetailFormat",
                    DisplayFileOperation(file.Operation),
                    file.ObservedUtc.ToLocalTime().ToString("t", CurrentUiCulture())),
                DisplayFinding(finding.Code),
                BrushForLevel(finding.Level),
                inputId);
        }).ToArray();
    }

    private static IReadOnlyList<TaskAlignmentPanelItem> CreateActionItems(
        IReadOnlyList<TaskAlignmentActionObservation> actions) =>
        actions.Select(action => new TaskAlignmentPanelItem(
            action.InputId,
            "↳",
            action.Activity.Envelope.RedactedSummary,
            UiLanguageService.Shared.Format(
                "AlignmentActionDetailFormat",
                action.StepId,
                action.Activity.Envelope.ObservedUtc.ToLocalTime().ToString(
                    "t",
                    CurrentUiCulture())),
            DisplayOutcome(action.Outcome),
            action.Outcome switch
            {
                TaskAlignmentActionOutcome.Completed => OverviewBrushKeys.Working,
                TaskAlignmentActionOutcome.Started => OverviewBrushKeys.Idle,
                _ => OverviewBrushKeys.Blocked,
            },
            action.InputId)).ToArray();

    private static IReadOnlyList<TaskAlignmentPanelItem> CreateDeviationItems(
        IReadOnlyList<TaskAlignmentDeviationDecision> decisions,
        AssignmentDelegationGraph graph)
    {
        var text = UiLanguageService.Shared;
        return decisions.Count == 0
            ? [new(
                "deviation-none",
                "—",
                text["AlignmentNoDeviation"],
                text["AlignmentNoDeviationDetail"],
                text["AlignmentNotApplicable"],
                OverviewBrushKeys.Offline,
                text["AlignmentNoTrace"])]
            : decisions.Select(decision =>
            {
                var lifecycle = graph.Timeline.Single(item =>
                    item.EventId == decision.DeviationEventId);
                return new TaskAlignmentPanelItem(
                    decision.InputId,
                    "Δ",
                    decision.RequestedPathPrefix,
                    lifecycle.DeviationReason ?? text["AlignmentDeviationNoReason"],
                    DisplayDeviation(decision.DecisionKind),
                    decision.DecisionKind switch
                    {
                        TaskAlignmentDeviationDecisionKind.Approved => OverviewBrushKeys.Working,
                        TaskAlignmentDeviationDecisionKind.Pending => OverviewBrushKeys.Idle,
                        _ => OverviewBrushKeys.Blocked,
                    },
                    $"{decision.InputId} · {TaskAlignmentAnalyzer.LifecycleInputId(decision.DeviationEventId)}");
            }).ToArray();
    }

    private static IReadOnlyList<TaskAlignmentPanelItem> CreateEvidenceItems(
        AssignmentDelegationGraph graph,
        string taskId)
    {
        var text = UiLanguageService.Shared;
        var evidence = graph.Timeline.Where(item =>
                item.EventKind == AssignmentLifecycleEventKind.Evidence &&
                item.Disposition == AssignmentLifecycleDisposition.Applied &&
                string.Equals(item.TaskId, taskId, StringComparison.Ordinal))
            .ToArray();
        return evidence.Length == 0
            ? [new(
                "evidence-missing",
                "!",
                text["AlignmentEvidenceMissing"],
                text["AlignmentRequiredDataMissing"],
                text["AlignmentStatusMissing"],
                OverviewBrushKeys.Offline,
                TaskAlignmentContractRules.ContractInputId(taskId))]
            : evidence.Select(item => new TaskAlignmentPanelItem(
                $"evidence-{item.EventId:D}",
                "✓",
                item.EvidenceReference!,
                item.AcceptedUtc.ToLocalTime().ToString("g", CurrentUiCulture()),
                text["AlignmentEvidenceAccepted"],
                OverviewBrushKeys.Working,
                $"{TaskAlignmentAnalyzer.LifecycleInputId(item.EventId)} · {ShortHash(item.EvidenceSha256!)}"))
                .ToArray();
    }

    private void ApplySyntheticFixture()
    {
        var text = UiLanguageService.Shared;
        var request = CreateSyntheticPreviewRequest();
        ApplyAnalysis(
            request,
            "HerdrOps",
            text["AlignmentSyntheticSource"],
            text["AlignmentSyntheticBoundary"]);
        _sourceLocalizationKey = "AlignmentSyntheticSource";
        _boundaryLocalizationKey = "AlignmentSyntheticBoundary";
    }

    public static TaskAlignmentAnalysisRequest CreateSyntheticPreviewRequest()
    {
        var text = UiLanguageService.Shared;
        var events = CreateSyntheticLifecycle();
        var replay = AssignmentLifecycleReplay.Run(events);
        var lifecycleContract = replay.CurrentTasks.Single().State.Contract;
        var contract = TaskAlignmentContractRules.Create(
            lifecycleContract.TaskId,
            lifecycleContract.AssignmentEventId,
            lifecycleContract.ProvenanceEventSha256,
            text["AlignmentFixtureGoal"],
            [
                new("SCOPE-SOURCE", TaskAlignmentScopeRuleKind.AllowPathPrefix, "src/backend", text["AlignmentFixtureScopeSource"]),
                new("SCOPE-TESTS", TaskAlignmentScopeRuleKind.AllowPathPrefix, "tests", text["AlignmentFixtureScopeTests"]),
                new("SCOPE-GENERATED", TaskAlignmentScopeRuleKind.DenyPathPrefix, "src/backend/generated", text["AlignmentFixtureScopeGenerated"]),
            ],
            [
                new("CONSTRAINT-RUNTIME", text["AlignmentFixtureConstraintRuntime"]),
                new("CONSTRAINT-DEADLINE", text["AlignmentFixtureConstraintDeadline"]),
            ],
            [
                new("STEP-1", text["AlignmentFixtureStep1"], 18),
                new("STEP-2", text["AlignmentFixtureStep2"], 18),
                new("STEP-3", text["AlignmentFixtureStep3"], 16),
                new("STEP-4", text["AlignmentFixtureStep4"], 16),
                new("STEP-5", text["AlignmentFixtureStep5"], 16),
                new("STEP-6", text["AlignmentFixtureStep6"], 16),
            ],
            [
                new("AC-1", text["AlignmentFixtureCriterion1"], 20, ["commit_8f3a1c2.png"]),
                new("AC-2", text["AlignmentFixtureCriterion2"], 20, ["unittest_result.png"]),
                new("AC-3", text["AlignmentFixtureCriterion3"], 20, ["report_preview.png"]),
                new("AC-4", text["AlignmentFixtureCriterion4"], 20, ["code-review.approval"]),
                new("AC-5", text["AlignmentFixtureCriterion5"], 20, ["regression.trx"]),
            ],
            SyntheticUtc);
        var actions = new[]
        {
            CreateSyntheticAction(1, "STEP-1", TaskAlignmentActionOutcome.Completed, "AlignmentFixtureAction1"),
            CreateSyntheticAction(2, "STEP-2", TaskAlignmentActionOutcome.Completed, "AlignmentFixtureAction2"),
            CreateSyntheticAction(3, "STEP-3", TaskAlignmentActionOutcome.Completed, "AlignmentFixtureAction3"),
            CreateSyntheticAction(4, "STEP-4", TaskAlignmentActionOutcome.Completed, "AlignmentFixtureAction4"),
            CreateSyntheticAction(5, "STEP-5", TaskAlignmentActionOutcome.Started, "AlignmentFixtureAction5"),
        };
        var files = new[]
        {
            CreateSyntheticFile(1, "src/backend/ResourceService.cs", FileActivityOperation.Modified),
            CreateSyntheticFile(2, "src/backend/ReportController.cs", FileActivityOperation.Modified),
            CreateSyntheticFile(3, "tests/ResourceServiceTests.cs", FileActivityOperation.Created),
            CreateSyntheticFile(4, "src/reporting/ResourceReport.cshtml", FileActivityOperation.Created),
        };
        var deviationEvent = events.Single(item =>
            item.EventKind == AssignmentLifecycleEventKind.Deviation);
        var deviation = new TaskAlignmentDeviationDecision(
            "deviation-decision:fixture-1",
            deviationEvent.EventId,
            TaskAlignmentDeviationDecisionKind.Pending,
            "src/reporting",
            SyntheticUtc.AddMinutes(10),
            Hash("synthetic-deviation-decision"));
        return new TaskAlignmentAnalysisRequest(replay, contract, actions, files, [deviation], []);
    }

    private static readonly DateTimeOffset SyntheticUtc =
        new(2026, 8, 15, 2, 15, 0, TimeSpan.Zero);

    private static AssignmentLifecycleEvent[] CreateSyntheticLifecycle()
    {
        var text = UiLanguageService.Shared;
        var assignment = CreateLifecycle(
            AssignmentLifecycleEventKind.Assignment,
            1,
            "project-manager",
            "Project Manager",
            text["AlignmentFixtureAssignment"],
            targetAgentId: "backend-worker-01");
        var acknowledgement = CreateLifecycle(
            AssignmentLifecycleEventKind.Acknowledgement,
            2,
            "backend-worker-01",
            "Backend Worker",
            text["AlignmentFixtureAcknowledgement"],
            parentEventId: assignment.EventId);
        var progress = CreateLifecycle(
            AssignmentLifecycleEventKind.Progress,
            3,
            "backend-worker-01",
            "Backend Worker",
            text["AlignmentFixtureProgress"],
            parentEventId: acknowledgement.EventId,
            progressPercent: 64);
        var deviation = CreateLifecycle(
            AssignmentLifecycleEventKind.Deviation,
            4,
            "backend-worker-01",
            "Backend Worker",
            text["AlignmentFixtureDeviationSummary"],
            parentEventId: progress.EventId,
            deviationReason: text["AlignmentFixtureDeviationReason"]);
        var commit = CreateLifecycle(
            AssignmentLifecycleEventKind.Evidence,
            5,
            "backend-worker-01",
            "Backend Worker",
            text["AlignmentFixtureEvidenceCommit"],
            parentEventId: deviation.EventId,
            evidenceReference: "commit_8f3a1c2.png",
            evidenceSha256: Hash("commit_8f3a1c2.png"));
        var tests = CreateLifecycle(
            AssignmentLifecycleEventKind.Evidence,
            6,
            "backend-worker-01",
            "Backend Worker",
            text["AlignmentFixtureEvidenceTests"],
            parentEventId: commit.EventId,
            evidenceReference: "unittest_result.png",
            evidenceSha256: Hash("unittest_result.png"));
        return [assignment, acknowledgement, progress, deviation, commit, tests];
    }

    private static AssignmentLifecycleEvent CreateLifecycle(
        AssignmentLifecycleEventKind kind,
        int sequence,
        string actorId,
        string actorRole,
        string summary,
        Guid? parentEventId = null,
        string? targetAgentId = null,
        int? progressPercent = null,
        string? deviationReason = null,
        string? evidenceReference = null,
        string? evidenceSha256 = null) =>
        new(
            AssignmentLifecycleContract.Version,
            GuidFor(sequence),
            kind,
            sequence,
            SyntheticUtc.AddMinutes(sequence - 1),
            SyntheticUtc.AddMinutes(sequence),
            AssignmentLifecycleContract.CoreSource,
            GuidFor(100 + sequence),
            Hash($"alignment-lifecycle-{sequence}-{kind}"),
            "TASK-120",
            actorId,
            actorRole,
            summary,
            parentEventId,
            targetAgentId,
            progressPercent,
            deviationReason,
            evidenceReference,
            evidenceSha256,
            null);

    private static TaskAlignmentActionObservation CreateSyntheticAction(
        long sequence,
        string stepId,
        TaskAlignmentActionOutcome outcome,
        string summaryKey)
    {
        var envelope = new ActivityEventEnvelope(
            ActivityEventContract.Version,
            $"alignment-fixture-action-{sequence}",
            ActivitySourceKind.Herdr,
            "herdr:alignment-fixture",
            "fixture-epoch-1",
            sequence,
            ActivityConfidence.Observed,
            ActivityUrgency.Normal,
            ActivityDeliveryMode.Immediate,
            "task.step.observed",
            SyntheticUtc.AddMinutes(sequence + 6),
            SyntheticUtc.AddMinutes(sequence + 6).AddSeconds(1),
            GuidFor(200 + (int)sequence),
            null,
            "backend-worker-01",
            "pane-fixture-1",
            "TASK-120",
            null,
            UiLanguageService.Shared[summaryKey],
            Hash($"alignment-action-{sequence}"));
        return new TaskAlignmentActionObservation(
            $"action:fixture-{sequence}",
            ActivityEventContract.NormalizeAndValidate(envelope, sequence),
            stepId,
            outcome);
    }

    private static FileActivityObservation CreateSyntheticFile(
        long sequence,
        string path,
        FileActivityOperation operation) =>
        new(
            sequence,
            SyntheticUtc.AddMinutes(sequence + 12),
            operation,
            path,
            null,
            ActivitySourceKind.FileSystem,
            "filesystem:alignment-fixture",
            ActivityConfidence.Correlated,
            true,
            "authorized-repository-root",
            "backend-worker-01",
            "TASK-120",
            "Herdr pane working-directory correlation",
            SyntheticUtc.AddMinutes(sequence + 12).AddSeconds(-1));

    private static TaskAlignmentHeader EmptyHeader()
    {
        var text = UiLanguageService.Shared;
        return new TaskAlignmentHeader(
            "—",
            text["AlignmentNoAnalysis"],
            "?",
            text["AlignmentNoAssignee"],
            "—",
            "—/100",
            "—/100",
            "—/100",
            text["AlignmentVerdictInsufficient"],
            text["AlignmentRequiredDataMissing"],
            OverviewBrushKeys.Offline,
            "\uE7BA");
    }

    private static string Score(int? score) => $"{score?.ToString(CultureInfo.InvariantCulture) ?? "—"}/100";

    private static CultureInfo CurrentUiCulture() => CultureInfo.GetCultureInfo(
        UiLanguageService.Shared.CurrentLanguage == UiLanguage.Thai ? "th-TH" : "en-US");

    private static string ShortHash(string hash) => hash.Length <= 12 ? hash : hash[..12];

    private static Guid GuidFor(int value) =>
        Guid.Parse($"00000000-0000-0000-0000-{value:000000000000}");

    private static string Hash(string value) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value)));

    private static string Initials(string value)
    {
        var words = value.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        return words.Length == 0
            ? "?"
            : string.Concat(words.Take(2).Select(item => char.ToUpperInvariant(item[0])));
    }

    private static string DisplayActor(string actorId) => actorId switch
    {
        "project-manager" => UiLanguageService.Shared["AlignmentActorProjectManager"],
        "backend-worker-01" => UiLanguageService.Shared["AlignmentActorBackendWorker"],
        _ => actorId,
    };

    private static string DisplayVerdict(TaskAlignmentVerdictKind verdict) =>
        UiLanguageService.Shared[verdict switch
        {
            TaskAlignmentVerdictKind.Aligned => "AlignmentVerdictAligned",
            TaskAlignmentVerdictKind.PartiallyMisaligned => "AlignmentVerdictPartial",
            TaskAlignmentVerdictKind.SuspectedViolation => "AlignmentVerdictSuspected",
            TaskAlignmentVerdictKind.ConfirmedViolation => "AlignmentVerdictConfirmed",
            _ => "AlignmentVerdictInsufficient",
        }];

    private static string DisplayVerdictDetail(TaskAlignmentVerdictKind verdict) =>
        UiLanguageService.Shared[verdict switch
        {
            TaskAlignmentVerdictKind.Aligned => "AlignmentVerdictAlignedDetail",
            TaskAlignmentVerdictKind.PartiallyMisaligned => "AlignmentVerdictPartialDetail",
            TaskAlignmentVerdictKind.SuspectedViolation => "AlignmentVerdictSuspectedDetail",
            TaskAlignmentVerdictKind.ConfirmedViolation => "AlignmentVerdictConfirmedDetail",
            _ => "AlignmentVerdictInsufficientDetail",
        }];

    private static string BrushForVerdict(TaskAlignmentVerdictKind verdict) => verdict switch
    {
        TaskAlignmentVerdictKind.Aligned => OverviewBrushKeys.Working,
        TaskAlignmentVerdictKind.PartiallyMisaligned => OverviewBrushKeys.Idle,
        TaskAlignmentVerdictKind.SuspectedViolation or
            TaskAlignmentVerdictKind.ConfirmedViolation => OverviewBrushKeys.Blocked,
        _ => OverviewBrushKeys.Offline,
    };

    private static string BrushForLevel(TaskAlignmentFindingLevel level) => level switch
    {
        TaskAlignmentFindingLevel.Pass => OverviewBrushKeys.Working,
        TaskAlignmentFindingLevel.Attention => OverviewBrushKeys.Idle,
        TaskAlignmentFindingLevel.Suspected or
            TaskAlignmentFindingLevel.Confirmed => OverviewBrushKeys.Blocked,
        _ => OverviewBrushKeys.Offline,
    };

    private static string DisplayFinding(TaskAlignmentFindingCode code) =>
        UiLanguageService.Shared[$"AlignmentFinding{code}"];

    private static string DisplayOutcome(TaskAlignmentActionOutcome outcome) =>
        UiLanguageService.Shared[outcome switch
        {
            TaskAlignmentActionOutcome.Completed => "AlignmentOutcomeCompleted",
            TaskAlignmentActionOutcome.Started => "AlignmentOutcomeStarted",
            _ => "AlignmentOutcomeFailed",
        }];

    private static string DisplayDeviation(TaskAlignmentDeviationDecisionKind decision) =>
        UiLanguageService.Shared[decision switch
        {
            TaskAlignmentDeviationDecisionKind.Approved => "AlignmentDeviationApproved",
            TaskAlignmentDeviationDecisionKind.Pending => "AlignmentDeviationPending",
            _ => "AlignmentDeviationRejected",
        }];

    private static string DisplayFileOperation(FileActivityOperation operation) =>
        UiLanguageService.Shared[operation switch
        {
            FileActivityOperation.Read => "FileActionRead",
            FileActivityOperation.Modified => "FileActionModified",
            FileActivityOperation.Created => "FileActionCreated",
            FileActivityOperation.Deleted => "FileActionDeleted",
            _ => "AlignmentFileChanged",
        }];
}
