using System.Globalization;
using HerdrOps.App.Live;
using HerdrOps.App.Localization;
using HerdrOps.App.Overview;
using HerdrOps.Contracts;

namespace HerdrOps.App.Activity;

public sealed record ActivityFilterOption(string Id, string Label);

public sealed record RealtimeActivitySummaryCard(
    string Id,
    string Title,
    string Value,
    string Detail,
    string IconGlyph,
    string AccentBrushKey);

public sealed record RealtimeActivityEvidence(
    string EvidenceId,
    string DisplayName,
    string Detail,
    string ObservedTime,
    string Confidence,
    string AccentBrushKey);

public sealed record RealtimeActivityEventRow(
    string EventId,
    string Time,
    string Elapsed,
    string Initials,
    string Title,
    string Description,
    string TaskId,
    string Actor,
    string Role,
    string Severity,
    string EvidenceLevel,
    string Confidence,
    string Action,
    string AccentBrushKey,
    IReadOnlyList<RealtimeActivityEvidence> EvidenceSources);

public sealed record RealtimeActivityEventDetail(
    string EventId,
    string Title,
    string Time,
    string TaskId,
    string Initials,
    string Actor,
    string Role,
    string Severity,
    string Description,
    string Action,
    string EvidenceLevel,
    string Confidence,
    string AccentBrushKey);

/// <summary>
/// Deterministic presentation state for the Realtime Activity visual slice.
/// The synthetic fixture is never represented as live runtime evidence.
/// </summary>
public sealed class RealtimeActivityState : ObservableState
{
    public const int PageSize = 7;
    public const int MaximumHistory = 32;

    private static readonly DateTimeOffset FixtureNow =
        new(2026, 8, 14, 14, 32, 24, TimeSpan.FromHours(7));

    private readonly bool _syntheticPreview;
    private readonly IReadOnlyList<RawActivityEvent> _history;
    private IReadOnlyList<RealtimeActivitySummaryCard> _summaryCards = [];
    private IReadOnlyList<ActivityFilterOption> _timeFilters = [];
    private IReadOnlyList<ActivityFilterOption> _roleFilters = [];
    private IReadOnlyList<ActivityFilterOption> _severityFilters = [];
    private IReadOnlyList<ActivityFilterOption> _taskFilters = [];
    private IReadOnlyList<ActivityFilterOption> _evidenceFilters = [];
    private ActivityFilterOption _selectedTimeFilter = new("all", string.Empty);
    private ActivityFilterOption _selectedRoleFilter = new("all", string.Empty);
    private ActivityFilterOption _selectedSeverityFilter = new("all", string.Empty);
    private ActivityFilterOption _selectedTaskFilter = new("all", string.Empty);
    private ActivityFilterOption _selectedEvidenceFilter = new("all", string.Empty);
    private IReadOnlyList<RealtimeActivityEventRow> _visibleEvents = [];
    private RealtimeActivityEventRow? _selectedEvent;
    private RealtimeActivityEventDetail? _selectedDetail;
    private IReadOnlyList<RealtimeActivityEvidence> _evidenceSources = [];
    private string _sourceLabel = string.Empty;
    private string _connectionLabel = string.Empty;
    private string _historyLabel = string.Empty;
    private int _filteredEventCount;
    private int _visibleLimit = PageSize;
    private bool _hasMore;

    private RealtimeActivityState(bool syntheticPreview)
    {
        _syntheticPreview = syntheticPreview;
        _history = syntheticPreview
            ? CreateFixture().Take(MaximumHistory).ToArray()
            : [];
        EvidenceClass = syntheticPreview ? EvidenceClass.Synthetic : EvidenceClass.Contract;
        RefreshLanguage();
    }

    public static RealtimeActivityState CreateSyntheticPreview() => new(syntheticPreview: true);

    public static RealtimeActivityState CreateUnavailable() => new(syntheticPreview: false);

    public EvidenceClass EvidenceClass { get; }

    public bool IsSyntheticPreview => _syntheticPreview;

    public IReadOnlyList<RealtimeActivitySummaryCard> SummaryCards
    {
        get => _summaryCards;
        private set => Set(ref _summaryCards, value);
    }

    public IReadOnlyList<ActivityFilterOption> TimeFilters
    {
        get => _timeFilters;
        private set => Set(ref _timeFilters, value);
    }

    public IReadOnlyList<ActivityFilterOption> RoleFilters
    {
        get => _roleFilters;
        private set => Set(ref _roleFilters, value);
    }

    public IReadOnlyList<ActivityFilterOption> SeverityFilters
    {
        get => _severityFilters;
        private set => Set(ref _severityFilters, value);
    }

    public IReadOnlyList<ActivityFilterOption> TaskFilters
    {
        get => _taskFilters;
        private set => Set(ref _taskFilters, value);
    }

    public IReadOnlyList<ActivityFilterOption> EvidenceFilters
    {
        get => _evidenceFilters;
        private set => Set(ref _evidenceFilters, value);
    }

    public ActivityFilterOption SelectedTimeFilter
    {
        get => _selectedTimeFilter;
        set => SetFilter(ref _selectedTimeFilter, value, nameof(SelectedTimeFilter));
    }

    public ActivityFilterOption SelectedRoleFilter
    {
        get => _selectedRoleFilter;
        set => SetFilter(ref _selectedRoleFilter, value, nameof(SelectedRoleFilter));
    }

    public ActivityFilterOption SelectedSeverityFilter
    {
        get => _selectedSeverityFilter;
        set => SetFilter(ref _selectedSeverityFilter, value, nameof(SelectedSeverityFilter));
    }

    public ActivityFilterOption SelectedTaskFilter
    {
        get => _selectedTaskFilter;
        set => SetFilter(ref _selectedTaskFilter, value, nameof(SelectedTaskFilter));
    }

    public ActivityFilterOption SelectedEvidenceFilter
    {
        get => _selectedEvidenceFilter;
        set => SetFilter(ref _selectedEvidenceFilter, value, nameof(SelectedEvidenceFilter));
    }

    public IReadOnlyList<RealtimeActivityEventRow> VisibleEvents
    {
        get => _visibleEvents;
        private set => Set(ref _visibleEvents, value);
    }

    public RealtimeActivityEventRow? SelectedEvent
    {
        get => _selectedEvent;
        set
        {
            if (Set(ref _selectedEvent, value))
            {
                SynchronizeSelection();
            }
        }
    }

    public RealtimeActivityEventDetail? SelectedDetail
    {
        get => _selectedDetail;
        private set => Set(ref _selectedDetail, value);
    }

    public IReadOnlyList<RealtimeActivityEvidence> EvidenceSources
    {
        get => _evidenceSources;
        private set => Set(ref _evidenceSources, value);
    }

    public string SourceLabel { get => _sourceLabel; private set => Set(ref _sourceLabel, value); }

    public string ConnectionLabel
    {
        get => _connectionLabel;
        private set => Set(ref _connectionLabel, value);
    }

    public string HistoryLabel { get => _historyLabel; private set => Set(ref _historyLabel, value); }

    public int FilteredEventCount
    {
        get => _filteredEventCount;
        private set => Set(ref _filteredEventCount, value);
    }

    public bool HasMore { get => _hasMore; private set => Set(ref _hasMore, value); }

    public void LoadMore()
    {
        if (!HasMore)
        {
            return;
        }

        _visibleLimit = Math.Min(MaximumHistory, _visibleLimit + PageSize);
        ApplyFilters(preserveSelectedEventId: SelectedEvent?.EventId);
    }

    public void RefreshLanguage()
    {
        var selectedTime = SelectedTimeFilter.Id;
        var selectedRole = SelectedRoleFilter.Id;
        var selectedSeverity = SelectedSeverityFilter.Id;
        var selectedTask = SelectedTaskFilter.Id;
        var selectedEvidence = SelectedEvidenceFilter.Id;
        var selectedEvent = SelectedEvent?.EventId;
        var text = UiLanguageService.Shared;

        SourceLabel = _syntheticPreview
            ? text["RealtimeSyntheticSource"]
            : text["RealtimeLiveSourceUnavailable"];
        ConnectionLabel = _syntheticPreview
            ? text["RealtimeSyntheticBoundary"]
            : text["RealtimeWaitingForLiveEvents"];

        TimeFilters =
        [
            new("all", text["RealtimeAll"]),
            new("today", text["RealtimeToday"]),
            new("hour", text["RealtimePastHour"]),
            new("15m", text["RealtimePast15Minutes"]),
        ];
        RoleFilters =
        [
            new("all", text["RealtimeAll"]),
            new("pm", text["RealtimeRoleProjectManagement"]),
            new("leader", text["RealtimeRoleLeader"]),
            new("worker", text["RealtimeRoleWorker"]),
            new("system", text["RealtimeRoleSystem"]),
        ];
        SeverityFilters =
        [
            new("all", text["RealtimeAll"]),
            new("info", text["RealtimeSeverityInfo"]),
            new("low", text["RealtimeSeverityLow"]),
            new("medium", text["RealtimeSeverityMedium"]),
            new("high", text["RealtimeSeverityHigh"]),
        ];
        TaskFilters =
        [
            new("all", text["RealtimeAll"]),
            .. _history.Select(item => item.TaskId)
                .Where(taskId => taskId != "—")
                .Distinct(StringComparer.Ordinal)
                .Order(StringComparer.Ordinal)
                .Select(taskId => new ActivityFilterOption(taskId, taskId)),
        ];
        EvidenceFilters =
        [
            new("all", text["RealtimeAll"]),
            new("observed", text["RealtimeEvidenceObserved"]),
            new("inferred", text["RealtimeEvidenceInferred"]),
            new("missing", text["RealtimeEvidenceMissing"]),
        ];

        ReplaceSelection(ref _selectedTimeFilter, TimeFilters, selectedTime, nameof(SelectedTimeFilter));
        ReplaceSelection(ref _selectedRoleFilter, RoleFilters, selectedRole, nameof(SelectedRoleFilter));
        ReplaceSelection(ref _selectedSeverityFilter, SeverityFilters, selectedSeverity, nameof(SelectedSeverityFilter));
        ReplaceSelection(ref _selectedTaskFilter, TaskFilters, selectedTask, nameof(SelectedTaskFilter));
        ReplaceSelection(ref _selectedEvidenceFilter, EvidenceFilters, selectedEvidence, nameof(SelectedEvidenceFilter));
        SummaryCards = CreateSummaryCards(text);
        ApplyFilters(selectedEvent);
    }

    private void SetFilter(
        ref ActivityFilterOption field,
        ActivityFilterOption value,
        string propertyName)
    {
        ArgumentNullException.ThrowIfNull(value);
        if (!Set(ref field, value, propertyName))
        {
            return;
        }

        _visibleLimit = PageSize;
        ApplyFilters(preserveSelectedEventId: null);
    }

    private void ReplaceSelection(
        ref ActivityFilterOption field,
        IReadOnlyList<ActivityFilterOption> options,
        string selectedId,
        string propertyName)
    {
        var replacement = options.FirstOrDefault(item => item.Id == selectedId) ?? options[0];
        field = replacement;
        Raise(propertyName);
    }

    private void ApplyFilters(string? preserveSelectedEventId)
    {
        var filtered = _history
            .Where(MatchesTime)
            .Where(item => SelectedRoleFilter.Id == "all" || item.RoleId == SelectedRoleFilter.Id)
            .Where(item => SelectedSeverityFilter.Id == "all" || item.SeverityId == SelectedSeverityFilter.Id)
            .Where(item => SelectedTaskFilter.Id == "all" || item.TaskId == SelectedTaskFilter.Id)
            .Where(item => SelectedEvidenceFilter.Id == "all" || item.EvidenceLevelId == SelectedEvidenceFilter.Id)
            .OrderByDescending(item => item.ObservedAt)
            .ThenBy(item => item.EventId, StringComparer.Ordinal)
            .Take(MaximumHistory)
            .Select(Render)
            .ToArray();

        FilteredEventCount = filtered.Length;
        var visible = filtered.Take(_visibleLimit).ToArray();
        VisibleEvents = visible;
        HasMore = visible.Length < filtered.Length && visible.Length < MaximumHistory;
        HistoryLabel = UiLanguageService.Shared.Format(
            "RealtimeHistoryFormat",
            visible.Length,
            filtered.Length,
            MaximumHistory);

        var selected = preserveSelectedEventId is null
            ? null
            : visible.FirstOrDefault(item => item.EventId == preserveSelectedEventId);
        SelectedEvent = selected ?? visible.FirstOrDefault();
        if (SelectedEvent is null)
        {
            SynchronizeSelection();
        }
    }

    private bool MatchesTime(RawActivityEvent item) => SelectedTimeFilter.Id switch
    {
        "today" => item.ObservedAt.Date == FixtureNow.Date,
        "hour" => item.ObservedAt >= FixtureNow.AddHours(-1),
        "15m" => item.ObservedAt >= FixtureNow.AddMinutes(-15),
        _ => true,
    };

    private void SynchronizeSelection()
    {
        if (SelectedEvent is null)
        {
            SelectedDetail = null;
            EvidenceSources = [];
            return;
        }

        var item = SelectedEvent;
        SelectedDetail = new RealtimeActivityEventDetail(
            item.EventId,
            item.Title,
            $"{item.Time} · {item.Elapsed}",
            item.TaskId,
            item.Initials,
            item.Actor,
            item.Role,
            item.Severity,
            item.Description,
            item.Action,
            item.EvidenceLevel,
            item.Confidence,
            item.AccentBrushKey);
        EvidenceSources = item.EvidenceSources;
    }

    private IReadOnlyList<RealtimeActivitySummaryCard> CreateSummaryCards(UiLanguageService text)
    {
        var activeTasks = _history
            .Select(item => item.TaskId)
            .Where(taskId => taskId.StartsWith("TASK-", StringComparison.Ordinal))
            .Distinct(StringComparer.Ordinal)
            .Count();
        return
        [
            new(
                "events",
                text["RealtimeEventsToday"],
                _history.Count.ToString(CultureInfo.InvariantCulture),
                _syntheticPreview ? text["RealtimeFixtureWindow"] : text["RealtimeNoLiveData"],
                "\uE9D9",
                OverviewBrushKeys.Primary),
            new(
                "active-tasks",
                text["RealtimeActiveTasks"],
                activeTasks.ToString(CultureInfo.InvariantCulture),
                text["RealtimeDistinctTasks"],
                "\uE73A",
                OverviewBrushKeys.Working),
            new(
                "violations",
                text["RealtimeSuspectedViolations"],
                _history.Count(item => item.CategoryId == "violation").ToString(CultureInfo.InvariantCulture),
                text["RealtimeRequiresReview"],
                "\uE7BA",
                OverviewBrushKeys.Blocked),
            new(
                "reviews",
                text["RealtimeReviewsPending"],
                _history.Count(item => item.CategoryId == "review").ToString(CultureInfo.InvariantCulture),
                text["RealtimeAwaitingDecision"],
                "\uE8B9",
                OverviewBrushKeys.Review),
        ];
    }

    private static RealtimeActivityEventRow Render(RawActivityEvent item)
    {
        var text = UiLanguageService.Shared;
        var elapsed = FixtureNow - item.ObservedAt;
        var elapsedLabel = elapsed.TotalMinutes < 1
            ? text.Format("RealtimeSecondsAgo", Math.Max(0, (int)elapsed.TotalSeconds))
            : elapsed.TotalHours < 1
                ? text.Format("RealtimeMinutesAgo", (int)elapsed.TotalMinutes)
                : text.Format("RealtimeHoursAgo", (int)elapsed.TotalHours);
        var actor = text[item.ActorKey];
        var evidence = item.Evidence.Select(source => new RealtimeActivityEvidence(
            source.EvidenceId,
            source.DisplayName,
            text[source.DetailKey],
            source.ObservedAt.ToString("HH:mm:ss", CultureInfo.InvariantCulture),
            $"{source.Confidence}%",
            EvidenceBrushKey(item.EvidenceLevelId))).ToArray();

        return new RealtimeActivityEventRow(
            item.EventId,
            item.ObservedAt.ToString("HH:mm:ss", CultureInfo.InvariantCulture),
            elapsedLabel,
            item.Initials,
            text[item.TitleKey],
            text[item.DescriptionKey],
            item.TaskId,
            actor,
            text[RoleKey(item.RoleId)],
            text[SeverityKey(item.SeverityId)],
            text[EvidenceKey(item.EvidenceLevelId)],
            $"{item.Confidence}%",
            text[item.ActionKey],
            SeverityBrushKey(item.SeverityId),
            evidence);
    }

    private static string RoleKey(string roleId) => roleId switch
    {
        "pm" => "RealtimeRoleProjectManagement",
        "leader" => "RealtimeRoleLeader",
        "system" => "RealtimeRoleSystem",
        _ => "RealtimeRoleWorker",
    };

    private static string SeverityKey(string severityId) => severityId switch
    {
        "low" => "RealtimeSeverityLow",
        "medium" => "RealtimeSeverityMedium",
        "high" => "RealtimeSeverityHigh",
        _ => "RealtimeSeverityInfo",
    };

    private static string EvidenceKey(string evidenceId) => evidenceId switch
    {
        "inferred" => "RealtimeEvidenceInferred",
        "missing" => "RealtimeEvidenceMissing",
        _ => "RealtimeEvidenceObserved",
    };

    private static string SeverityBrushKey(string severityId) => severityId switch
    {
        "low" => OverviewBrushKeys.Working,
        "medium" => OverviewBrushKeys.Idle,
        "high" => OverviewBrushKeys.Blocked,
        _ => OverviewBrushKeys.Primary,
    };

    private static string EvidenceBrushKey(string evidenceId) => evidenceId switch
    {
        "missing" => OverviewBrushKeys.Blocked,
        "inferred" => OverviewBrushKeys.Idle,
        _ => OverviewBrushKeys.Working,
    };

    private static IReadOnlyList<RawActivityEvent> CreateFixture() =>
    [
        Event("EVT-001", 14, 32, 24, "PM", "RealtimeActorProjectManager", "pm", "TASK-118", "info", "observed", 99, "review", "RealtimeEventAssignTitle", "RealtimeEventAssignDescription", "RealtimeActionRecorded", Evidence("AUD-118", "assignment-envelope.json", "RealtimeEvidenceAssignmentEnvelope", 14, 32, 23, 99)),
        Event("EVT-002", 14, 31, 55, "BL", "RealtimeActorBackendLeader", "leader", "TASK-115", "info", "observed", 98, "normal", "RealtimeEventDelegateTitle", "RealtimeEventDelegateDescription", "RealtimeActionRecorded", Evidence("AUD-115", "delegation-envelope.json", "RealtimeEvidenceDelegationEnvelope", 14, 31, 54, 98)),
        Event("EVT-003", 14, 31, 28, "BW", "RealtimeActorBackendWorker", "worker", "TASK-115", "info", "observed", 98, "normal", "RealtimeEventReceivedTitle", "RealtimeEventReceivedDescription", "RealtimeActionAcknowledged", Evidence("ACK-115", "worker-acknowledgement.json", "RealtimeEvidenceWorkerAcknowledgement", 14, 31, 28, 98)),
        Event("EVT-004", 14, 31, 10, "BW", "RealtimeActorBackendWorker", "worker", "TASK-115", "info", "observed", 96, "normal", "RealtimeEventFileReadTitle", "RealtimeEventFileReadDescription", "RealtimeActionObserved", Evidence("FILE-5013", "UnitTests_Report_0513.xlsx", "RealtimeEvidenceFileRead", 14, 31, 10, 96)),
        Event("EVT-005", 14, 30, 48, "BW", "RealtimeActorBackendWorker", "worker", "TASK-115", "low", "observed", 97, "normal", "RealtimeEventFileEditTitle", "RealtimeEventFileEditDescription", "RealtimeActionObserved", Evidence("FILE-AUTH", "AuthService.cs", "RealtimeEvidenceFileEdit", 14, 30, 48, 97)),
        Event("EVT-006", 14, 30, 22, "PS", "RealtimeActorPmSecretary", "pm", "PROJECT", "info", "inferred", 81, "normal", "RealtimeEventProjectUpdateTitle", "RealtimeEventProjectUpdateDescription", "RealtimeActionCorrelated", Evidence("LOG-PROJ", "project-state.log", "RealtimeEvidenceProjectState", 14, 30, 20, 81)),
        new RawActivityEvent(
            "EVT-007",
            At(14, 29, 54),
            "TW",
            "RealtimeActorTestWorker",
            "worker",
            "TASK-113",
            "high",
            "observed",
            94,
            "violation",
            "RealtimeEventScopeViolationTitle",
            "RealtimeEventScopeViolationDescription",
            "RealtimeActionQueuedForReview",
            [
                Evidence("SRC-AUTH", "AuthService.cs", "RealtimeEvidenceOutOfScopeEdit", 14, 29, 45, 96),
                Evidence("SRC-TEST", "UnitTests_Report_0513.xlsx", "RealtimeEvidenceRelatedReport", 14, 29, 12, 91),
                Evidence("SRC-LOG", "System Log", "RealtimeEvidenceCorrelationLog", 14, 28, 59, 88),
            ]),
        Event("EVT-008", 14, 29, 16, "PS", "RealtimeActorPmSecretary", "pm", "TASK-120", "medium", "missing", 54, "normal", "RealtimeEventOverdueTitle", "RealtimeEventOverdueDescription", "RealtimeActionAwaitingEvidence"),
        Event("EVT-009", 14, 28, 45, "BL", "RealtimeActorBackendLeader", "leader", "TASK-115", "medium", "inferred", 79, "review", "RealtimeEventReviewRequestedTitle", "RealtimeEventReviewRequestedDescription", "RealtimeActionAwaitingReview", Evidence("REVIEW-115", "review-request.json", "RealtimeEvidenceReviewRequest", 14, 28, 44, 79)),
        Event("EVT-010", 14, 28, 1, "SY", "RealtimeActorSystem", "system", "—", "info", "inferred", 76, "normal", "RealtimeEventScoreUpdatedTitle", "RealtimeEventScoreUpdatedDescription", "RealtimeActionCorrelated", Evidence("SCORE-DAILY", "score-projection.json", "RealtimeEvidenceScoreProjection", 14, 28, 0, 76)),
        Event("EVT-011", 14, 21, 16, "FW", "RealtimeActorFrontendWorker", "worker", "TASK-118", "low", "observed", 95, "normal", "RealtimeEventFileCreatedTitle", "RealtimeEventFileCreatedDescription", "RealtimeActionObserved", Evidence("FILE-LOGIN", "LoginView.xaml", "RealtimeEvidenceFileCreated", 14, 21, 16, 95)),
        Event("EVT-012", 13, 58, 5, "DW", "RealtimeActorDevOpsWorker", "worker", "TASK-120", "low", "missing", 43, "normal", "RealtimeEventIdleTitle", "RealtimeEventIdleDescription", "RealtimeActionAwaitingEvidence"),
        Event("EVT-013", 13, 15, 0, "PM", "RealtimeActorProjectManager", "pm", "TASK-113", "medium", "observed", 92, "review", "RealtimeEventComplianceReviewTitle", "RealtimeEventComplianceReviewDescription", "RealtimeActionAwaitingReview", Evidence("REVIEW-113", "compliance-review.json", "RealtimeEvidenceComplianceReview", 13, 14, 58, 92)),
        Event("EVT-014", 12, 40, 0, "BL", "RealtimeActorBackendLeader", "leader", "TASK-122", "high", "inferred", 74, "violation", "RealtimeEventDependencyBlockedTitle", "RealtimeEventDependencyBlockedDescription", "RealtimeActionQueuedForReview", Evidence("DEP-122", "dependency-state.json", "RealtimeEvidenceDependencyState", 12, 39, 58, 74)),
    ];

    private static RawActivityEvent Event(
        string eventId,
        int hour,
        int minute,
        int second,
        string initials,
        string actorKey,
        string roleId,
        string taskId,
        string severityId,
        string evidenceLevelId,
        int confidence,
        string categoryId,
        string titleKey,
        string descriptionKey,
        string actionKey,
        params RawEvidence[] evidence) =>
        new(
            eventId,
            At(hour, minute, second),
            initials,
            actorKey,
            roleId,
            taskId,
            severityId,
            evidenceLevelId,
            confidence,
            categoryId,
            titleKey,
            descriptionKey,
            actionKey,
            evidence);

    private static RawEvidence Evidence(
        string evidenceId,
        string displayName,
        string detailKey,
        int hour,
        int minute,
        int second,
        int confidence) =>
        new(evidenceId, displayName, detailKey, At(hour, minute, second), confidence);

    private static DateTimeOffset At(int hour, int minute, int second) =>
        new(2026, 8, 14, hour, minute, second, TimeSpan.FromHours(7));

    private sealed record RawActivityEvent(
        string EventId,
        DateTimeOffset ObservedAt,
        string Initials,
        string ActorKey,
        string RoleId,
        string TaskId,
        string SeverityId,
        string EvidenceLevelId,
        int Confidence,
        string CategoryId,
        string TitleKey,
        string DescriptionKey,
        string ActionKey,
        IReadOnlyList<RawEvidence> Evidence);

    private sealed record RawEvidence(
        string EvidenceId,
        string DisplayName,
        string DetailKey,
        DateTimeOffset ObservedAt,
        int Confidence);
}
