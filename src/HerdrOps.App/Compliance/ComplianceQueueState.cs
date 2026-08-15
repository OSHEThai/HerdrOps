using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using HerdrOps.App.Live;
using HerdrOps.App.Localization;
using HerdrOps.Contracts;

namespace HerdrOps.App.Compliance;

public enum ComplianceQueueIncidentState
{
    Suspected = 1,
    Confirmed = 2,
    PendingLeader = 3,
    PendingProjectManager = 4,
    Dismissed = 5,
}

public enum ComplianceQueueViewerRole
{
    ProjectManager = 1,
    Leader = 2,
    Observer = 3,
}

public enum ComplianceQueueEvidenceAvailability
{
    Present = 1,
    Missing = 2,
}

/// <summary>
/// Compliance Queue semantic brush roles. These names are deliberately separate
/// from workflow and chart brushes used by other pages.
/// </summary>
public static class ComplianceQueueBrushKeys
{
    public const string SeverityCritical = "HerdrOps.Brush.Severity.Critical";
    public const string SeverityHigh = "HerdrOps.Brush.Severity.High";
    public const string SeverityMedium = "HerdrOps.Brush.Severity.Medium";
    public const string SeverityLow = "HerdrOps.Brush.Severity.Low";

    public const string ReviewSuspected = "HerdrOps.Brush.Review.Suspected";
    public const string ReviewConfirmed = "HerdrOps.Brush.Review.Confirmed";
    public const string ReviewPendingLeader = "HerdrOps.Brush.Review.PendingLeader";
    public const string ReviewPendingProjectManager = "HerdrOps.Brush.Review.PendingProjectManager";
    public const string ReviewDismissed = "HerdrOps.Brush.Review.Dismissed";

    public const string EvidencePrimary = "HerdrOps.Brush.Chart.Primary";
    public const string EvidenceWorking = "HerdrOps.Brush.Chart.Working";
    public const string EvidenceBlocked = "HerdrOps.Brush.Chart.Blocked";
    public const string EvidenceReview = "HerdrOps.Brush.Chart.Review";
    public const string EvidenceIdle = "HerdrOps.Brush.Chart.Idle";
    public const string EvidenceUnavailable = "HerdrOps.Brush.TextMuted";
}

public sealed record ComplianceQueueSummaryCard(
    string Id,
    string Title,
    string Value,
    string Detail,
    string IconGlyph,
    string AccentBrushKey);

public sealed record ComplianceQueueFilterOption(string Id, string Label);

public sealed record ComplianceQueueSortOption(string Id, string Label);

public sealed record ComplianceQueueIncidentRow(
    string IncidentId,
    string SeverityLabel,
    string SeverityBrushKey,
    string Initials,
    string Actor,
    string TaskId,
    string Title,
    string Description,
    string StateLabel,
    string StateBrushKey,
    string Time,
    string RelativeTime,
    string ReviewerInitials,
    string Reviewer,
    string ReviewerRole,
    DateTimeOffset ObservedAt,
    int SeverityRank)
{
    public string Severity => SeverityLabel;

    public string State => StateLabel;
}

public sealed record ComplianceQueueEvidenceItem(
    string EvidenceId,
    string FileName,
    string Source,
    ComplianceQueueEvidenceAvailability Availability,
    string AvailabilityLabel,
    string? Sha256,
    string? Reference,
    string IncidentId,
    string TaskId,
    string Actor,
    string Timestamp,
    string Size,
    string TypeLabel,
    string IconGlyph,
    string AccentBrushKey,
    DateTimeOffset? ObservedAt)
{
    public bool IsAvailable => Availability == ComplianceQueueEvidenceAvailability.Present;

    public string AvailabilityState => Availability.ToString();
}

public sealed record ComplianceQueueDetail(
    string IncidentId,
    string SeverityLabel,
    string SeverityBrushKey,
    string StateLabel,
    string StateBrushKey,
    string Initials,
    string Actor,
    string ActorRole,
    string TaskId,
    string TaskTitle,
    string Description,
    string RuleId,
    string RuleLabel,
    string RuleDescription,
    string DetectedBy,
    string Timestamp,
    string RelativeTime,
    string ReviewerInitials,
    string Reviewer,
    string ReviewerRole,
    IReadOnlyList<ComplianceQueueEvidenceItem> EvidenceItems)
{
    public string ActorInitials => Initials;

    public string Rule => RuleLabel;

    public IReadOnlyList<ComplianceQueueEvidenceItem> Evidence => EvidenceItems;
}

public sealed record ComplianceQueueReviewAction(
    string Id,
    string Label,
    string IconGlyph,
    string AccentBrushKey,
    bool IsVisible,
    bool IsEnabled,
    string UnavailableReason,
    string RequiredRoleLabel,
    bool IsRoleApplicable,
    string AutomationName);

/// <summary>
/// Deterministic Compliance Queue presentation state.
///
/// The synthetic fixture reproduces the approved queue/detail hierarchy only. It
/// does not authorize, persist, or execute a review action; those boundaries belong
/// to the later role-authorized mutation slice.
/// </summary>
public sealed class ComplianceQueueState : ObservableState, IDisposable
{
    private static readonly DateTimeOffset FixtureNow =
        new(2026, 8, 15, 14, 32, 45, TimeSpan.FromHours(7));

    private readonly bool _syntheticPreview;
    private readonly IReadOnlyList<RawIncident> _history;
    private IReadOnlyList<ComplianceQueueSummaryCard> _summaryCards = [];
    private IReadOnlyList<ComplianceQueueFilterOption> _severityFilters = [];
    private IReadOnlyList<ComplianceQueueFilterOption> _stateFilters = [];
    private IReadOnlyList<ComplianceQueueFilterOption> _actorFilters = [];
    private IReadOnlyList<ComplianceQueueFilterOption> _taskFilters = [];
    private IReadOnlyList<ComplianceQueueFilterOption> _reviewerFilters = [];
    private IReadOnlyList<ComplianceQueueSortOption> _sortOptions = [];
    private ComplianceQueueFilterOption _selectedSeverityFilter = new("all", string.Empty);
    private ComplianceQueueFilterOption _selectedStateFilter = new("all", string.Empty);
    private ComplianceQueueFilterOption _selectedActorFilter = new("all", string.Empty);
    private ComplianceQueueFilterOption _selectedTaskFilter = new("all", string.Empty);
    private ComplianceQueueFilterOption _selectedReviewerFilter = new("all", string.Empty);
    private ComplianceQueueSortOption _selectedSortOption = new("severity", string.Empty);
    private IReadOnlyList<ComplianceQueueIncidentRow> _visibleIncidents = [];
    private ComplianceQueueIncidentRow? _selectedIncident;
    private ComplianceQueueDetail? _selectedDetail;
    private IReadOnlyList<ComplianceQueueReviewAction> _reviewActions = [];
    private string _connectionLabel = string.Empty;
    private string _sourceLabel = string.Empty;
    private string _viewerRoleLabel = string.Empty;
    private string _visibleRangeLabel = string.Empty;
    private bool _disposed;

    private ComplianceQueueState(
        bool syntheticPreview,
        ComplianceQueueViewerRole viewerRole)
    {
        if (!Enum.IsDefined(viewerRole))
        {
            throw new ArgumentOutOfRangeException(nameof(viewerRole), viewerRole, "Unsupported viewer role.");
        }

        _syntheticPreview = syntheticPreview;
        _history = syntheticPreview ? CreateFixture() : [];
        EvidenceClass = syntheticPreview ? EvidenceClass.Synthetic : EvidenceClass.Contract;
        ViewerRole = viewerRole;
        RefreshLanguage();
    }

    public static ComplianceQueueState CreateSyntheticPreview(
        ComplianceQueueViewerRole viewerRole = ComplianceQueueViewerRole.ProjectManager) =>
        new(syntheticPreview: true, viewerRole);

    public static ComplianceQueueState CreateUnavailableLiveState(
        ComplianceQueueViewerRole viewerRole = ComplianceQueueViewerRole.ProjectManager) =>
        new(syntheticPreview: false, viewerRole);

    public static ComplianceQueueState CreateUnavailable() => CreateUnavailableLiveState();

    public EvidenceClass EvidenceClass { get; }

    public bool IsSyntheticPreview => _syntheticPreview;

    /// <summary>
    /// Presentation context only. This is not an authorization decision and does
    /// not grant permission to execute any review action.
    /// </summary>
    public ComplianceQueueViewerRole ViewerRole { get; }

    public string ViewerRoleLabel
    {
        get => _viewerRoleLabel;
        private set => Set(ref _viewerRoleLabel, value);
    }

    public string VisibleRangeLabel
    {
        get => _visibleRangeLabel;
        private set => Set(ref _visibleRangeLabel, value);
    }

    public string ConnectionLabel
    {
        get => _connectionLabel;
        private set => Set(ref _connectionLabel, value);
    }

    public string SourceLabel
    {
        get => _sourceLabel;
        private set => Set(ref _sourceLabel, value);
    }

    public IReadOnlyList<ComplianceQueueSummaryCard> SummaryCards
    {
        get => _summaryCards;
        private set => Set(ref _summaryCards, value);
    }

    public IReadOnlyList<ComplianceQueueFilterOption> SeverityFilters
    {
        get => _severityFilters;
        private set => Set(ref _severityFilters, value);
    }

    public IReadOnlyList<ComplianceQueueFilterOption> StateFilters
    {
        get => _stateFilters;
        private set => Set(ref _stateFilters, value);
    }

    public IReadOnlyList<ComplianceQueueFilterOption> ActorFilters
    {
        get => _actorFilters;
        private set => Set(ref _actorFilters, value);
    }

    public IReadOnlyList<ComplianceQueueFilterOption> TaskFilters
    {
        get => _taskFilters;
        private set => Set(ref _taskFilters, value);
    }

    public IReadOnlyList<ComplianceQueueFilterOption> ReviewerFilters
    {
        get => _reviewerFilters;
        private set => Set(ref _reviewerFilters, value);
    }

    public IReadOnlyList<ComplianceQueueSortOption> SortOptions
    {
        get => _sortOptions;
        private set => Set(ref _sortOptions, value);
    }

    public ComplianceQueueFilterOption SelectedSeverityFilter
    {
        get => _selectedSeverityFilter;
        set => SetFilter(
            ref _selectedSeverityFilter,
            value,
            SeverityFilters,
            nameof(SelectedSeverityFilter));
    }

    public ComplianceQueueFilterOption SelectedStateFilter
    {
        get => _selectedStateFilter;
        set => SetFilter(
            ref _selectedStateFilter,
            value,
            StateFilters,
            nameof(SelectedStateFilter));
    }

    public ComplianceQueueFilterOption SelectedActorFilter
    {
        get => _selectedActorFilter;
        set => SetFilter(
            ref _selectedActorFilter,
            value,
            ActorFilters,
            nameof(SelectedActorFilter));
    }

    public ComplianceQueueFilterOption SelectedTaskFilter
    {
        get => _selectedTaskFilter;
        set => SetFilter(
            ref _selectedTaskFilter,
            value,
            TaskFilters,
            nameof(SelectedTaskFilter));
    }

    public ComplianceQueueFilterOption SelectedReviewerFilter
    {
        get => _selectedReviewerFilter;
        set => SetFilter(
            ref _selectedReviewerFilter,
            value,
            ReviewerFilters,
            nameof(SelectedReviewerFilter));
    }

    public ComplianceQueueSortOption SelectedSortOption
    {
        get => _selectedSortOption;
        set
        {
            ArgumentNullException.ThrowIfNull(value);
            var canonical = CanonicalOption(value, SortOptions, nameof(SelectedSortOption));
            if (Set(ref _selectedSortOption, canonical))
            {
                ApplyFilters(_selectedIncident?.IncidentId);
            }
        }
    }

    public IReadOnlyList<ComplianceQueueIncidentRow> VisibleIncidents
    {
        get => _visibleIncidents;
        private set => Set(ref _visibleIncidents, value);
    }

    public ComplianceQueueIncidentRow? SelectedIncident
    {
        get => _selectedIncident;
        set
        {
            var accepted = value is null
                ? null
                : VisibleIncidents.FirstOrDefault(item =>
                    item.IncidentId == value.IncidentId);
            Set(ref _selectedIncident, accepted);
            SynchronizeSelection();
        }
    }

    public ComplianceQueueDetail? SelectedDetail
    {
        get => _selectedDetail;
        private set => Set(ref _selectedDetail, value);
    }

    public IReadOnlyList<ComplianceQueueReviewAction> ReviewActions
    {
        get => _reviewActions;
        private set => Set(ref _reviewActions, value);
    }

    public void RefreshLanguage()
    {
        if (_disposed)
        {
            return;
        }

        var text = UiLanguageService.Shared;
        var selectedIncidentId = SelectedIncident?.IncidentId;
        var selectedSeverityId = SelectedSeverityFilter.Id;
        var selectedStateId = SelectedStateFilter.Id;
        var selectedActorId = SelectedActorFilter.Id;
        var selectedTaskId = SelectedTaskFilter.Id;
        var selectedReviewerId = SelectedReviewerFilter.Id;
        var selectedSortId = SelectedSortOption.Id;

        SourceLabel = _syntheticPreview
            ? text["ComplianceQueueSyntheticSource"]
            : text["ComplianceQueueLiveSourceUnavailable"];
        ConnectionLabel = _syntheticPreview
            ? text["ComplianceQueueSyntheticBoundary"]
            : text["ComplianceQueueLiveBoundary"];
        ViewerRoleLabel = text[ViewerRoleKey(ViewerRole)];

        SeverityFilters =
        [
            new("all", text["ComplianceQueueFilterAll"]),
            new("critical", text["ComplianceQueueSeverityCritical"]),
            new("high", text["ComplianceQueueSeverityHigh"]),
            new("medium", text["ComplianceQueueSeverityMedium"]),
            new("low", text["ComplianceQueueSeverityLow"]),
        ];
        StateFilters =
        [
            new("all", text["ComplianceQueueFilterAll"]),
            new("suspected", text["ComplianceQueueStateSuspected"]),
            new("confirmed", text["ComplianceQueueStateConfirmed"]),
            new("pending-leader", text["ComplianceQueueStatePendingLeader"]),
            new("pending-pm", text["ComplianceQueueStatePendingProjectManager"]),
            new("dismissed", text["ComplianceQueueStateDismissed"]),
        ];
        ActorFilters =
        [
            new("all", text["ComplianceQueueFilterAll"]),
            .. _history
                .Select(item => item.Actor)
                .Distinct(StringComparer.Ordinal)
                .Order(StringComparer.Ordinal)
                .Select(actor => new ComplianceQueueFilterOption(actor, actor)),
        ];
        TaskFilters =
        [
            new("all", text["ComplianceQueueFilterAll"]),
            .. _history
                .Select(item => item.TaskId)
                .Distinct(StringComparer.Ordinal)
                .Order(StringComparer.Ordinal)
                .Select(task => new ComplianceQueueFilterOption(task, task)),
        ];
        ReviewerFilters =
        [
            new("all", text["ComplianceQueueFilterAll"]),
            .. _history
                .Select(item => item.Reviewer)
                .Distinct(StringComparer.Ordinal)
                .Order(StringComparer.Ordinal)
                .Select(reviewer => new ComplianceQueueFilterOption(reviewer, reviewer)),
        ];
        SortOptions =
        [
            new("severity", text["ComplianceQueueSortSeverityNewest"]),
            new("newest", text["ComplianceQueueSortNewest"]),
            new("oldest", text["ComplianceQueueSortOldest"]),
        ];

        ReplaceSelection(
            ref _selectedSeverityFilter,
            SeverityFilters,
            selectedSeverityId,
            nameof(SelectedSeverityFilter));
        ReplaceSelection(
            ref _selectedStateFilter,
            StateFilters,
            selectedStateId,
            nameof(SelectedStateFilter));
        ReplaceSelection(
            ref _selectedActorFilter,
            ActorFilters,
            selectedActorId,
            nameof(SelectedActorFilter));
        ReplaceSelection(
            ref _selectedTaskFilter,
            TaskFilters,
            selectedTaskId,
            nameof(SelectedTaskFilter));
        ReplaceSelection(
            ref _selectedReviewerFilter,
            ReviewerFilters,
            selectedReviewerId,
            nameof(SelectedReviewerFilter));
        ReplaceSortSelection(selectedSortId);

        SummaryCards = CreateSummaryCards(text);
        ApplyFilters(selectedIncidentId);
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
    }

    private void SetFilter(
        ref ComplianceQueueFilterOption field,
        ComplianceQueueFilterOption value,
        IReadOnlyList<ComplianceQueueFilterOption> options,
        string propertyName)
    {
        ArgumentNullException.ThrowIfNull(value);
        var canonical = CanonicalOption(value, options, propertyName);
        if (Set(ref field, canonical, propertyName))
        {
            ApplyFilters(_selectedIncident?.IncidentId);
        }
    }

    private static ComplianceQueueFilterOption CanonicalOption(
        ComplianceQueueFilterOption value,
        IReadOnlyList<ComplianceQueueFilterOption> options,
        string propertyName)
    {
        var canonical = options.FirstOrDefault(item =>
            StringComparer.Ordinal.Equals(item.Id, value.Id));
        return canonical ?? throw new ArgumentException(
            $"Unknown {propertyName} option id '{value.Id}'.",
            nameof(value));
    }

    private static ComplianceQueueSortOption CanonicalOption(
        ComplianceQueueSortOption value,
        IReadOnlyList<ComplianceQueueSortOption> options,
        string propertyName)
    {
        var canonical = options.FirstOrDefault(item =>
            StringComparer.Ordinal.Equals(item.Id, value.Id));
        return canonical ?? throw new ArgumentException(
            $"Unknown {propertyName} option id '{value.Id}'.",
            nameof(value));
    }

    private void ReplaceSelection(
        ref ComplianceQueueFilterOption field,
        IReadOnlyList<ComplianceQueueFilterOption> options,
        string selectedId,
        string propertyName)
    {
        field = options.FirstOrDefault(item => item.Id == selectedId) ?? options[0];
        Raise(propertyName);
    }

    private void ReplaceSortSelection(string selectedId)
    {
        _selectedSortOption = SortOptions.FirstOrDefault(item => item.Id == selectedId) ?? SortOptions[0];
        Raise(nameof(SelectedSortOption));
    }

    private void ApplyFilters(string? preserveSelectedIncidentId)
    {
        var matching = _history.Where(MatchesSelectedFilters);
        var ordered = SelectedSortOption.Id switch
        {
            "severity" => matching
                .OrderByDescending(item => item.SeverityRank)
                .ThenByDescending(item => item.ObservedAt),
            "newest" => matching
                .OrderByDescending(item => item.ObservedAt),
            "oldest" => matching
                .OrderBy(item => item.ObservedAt),
            _ => throw new InvalidOperationException(
                $"Unsupported canonical Compliance Queue sort option '{SelectedSortOption.Id}'."),
        };

        var filtered = ordered
            .ThenBy(item => item.IncidentId, StringComparer.Ordinal)
            .Select(Render)
            .ToArray();

        VisibleIncidents = filtered;
        UpdatePaginationPresentation(filtered.Length);
        var selected = preserveSelectedIncidentId is null
            ? filtered.FirstOrDefault()
            : filtered.FirstOrDefault(item => item.IncidentId == preserveSelectedIncidentId) ?? filtered.FirstOrDefault();
        SelectedIncident = selected;
    }

    private void UpdatePaginationPresentation(int visibleCount)
    {
        var text = UiLanguageService.Shared;
        VisibleRangeLabel = visibleCount == 0
            ? text["ComplianceQueuePageRangeEmpty"]
            : text.Format(
                "ComplianceQueuePageRangeFormat",
                1,
                visibleCount,
                visibleCount);
    }

    private bool MatchesSelectedFilters(RawIncident item) =>
        (SelectedSeverityFilter.Id == "all" || item.SeverityId == SelectedSeverityFilter.Id) &&
        (SelectedStateFilter.Id == "all" || item.StateId == SelectedStateFilter.Id) &&
        (SelectedActorFilter.Id == "all" || item.Actor == SelectedActorFilter.Id) &&
        (SelectedTaskFilter.Id == "all" || item.TaskId == SelectedTaskFilter.Id) &&
        (SelectedReviewerFilter.Id == "all" || item.Reviewer == SelectedReviewerFilter.Id);

    private void SynchronizeSelection()
    {
        if (SelectedIncident is null)
        {
            SelectedDetail = null;
            ReviewActions = [];
            return;
        }

        var raw = _history.FirstOrDefault(item => item.IncidentId == SelectedIncident.IncidentId);
        if (raw is null)
        {
            SelectedDetail = null;
            ReviewActions = [];
            return;
        }

        SelectedDetail = RenderDetail(raw);
        ReviewActions = _syntheticPreview ? CreateReviewActions() : [];
    }

    private ComplianceQueueIncidentRow Render(RawIncident item)
    {
        var text = UiLanguageService.Shared;
        return new ComplianceQueueIncidentRow(
            item.IncidentId,
            text[item.SeverityKey],
            SeverityBrushKey(item.SeverityId),
            item.Initials,
            item.Actor,
            item.TaskId,
            text[item.TitleKey],
            text[item.DescriptionKey],
            text[item.StateKey],
            StateBrushKey(item.StateId),
            item.ObservedAt.ToString("HH:mm", CultureInfo.InvariantCulture),
            RelativeTime(item.ObservedAt, text),
            item.ReviewerInitials,
            item.Reviewer,
            text[item.ReviewerRoleKey],
            item.ObservedAt,
            item.SeverityRank);
    }

    private ComplianceQueueDetail RenderDetail(RawIncident item)
    {
        var text = UiLanguageService.Shared;
        return new ComplianceQueueDetail(
            item.IncidentId,
            text[item.SeverityKey],
            SeverityBrushKey(item.SeverityId),
            text[item.StateKey],
            StateBrushKey(item.StateId),
            item.Initials,
            item.Actor,
            text[item.ActorRoleKey],
            item.TaskId,
            text[item.TaskTitleKey],
            text[item.DescriptionKey],
            item.RuleId,
            text[item.RuleLabelKey],
            text[item.RuleDescriptionKey],
            text[item.DetectedByKey],
            item.ObservedAt.ToString(
                "dd MMM yyyy HH:mm:ss",
                CultureInfo.GetCultureInfo(text.IsThai ? "th-TH" : "en-US")),
            RelativeTime(item.ObservedAt, text),
            item.ReviewerInitials,
            item.Reviewer,
            text[item.ReviewerRoleKey],
            item.Evidence
                .Select(evidence => new ComplianceQueueEvidenceItem(
                    evidence.EvidenceId,
                    evidence.FileName,
                    text[evidence.SourceKey],
                    evidence.Availability,
                    text[evidence.Availability == ComplianceQueueEvidenceAvailability.Present
                        ? "ComplianceQueueEvidenceAvailable"
                        : "ComplianceQueueEvidenceMissing"],
                    evidence.Sha256,
                    evidence.Reference,
                    item.IncidentId,
                    item.TaskId,
                    item.Actor,
                    evidence.ObservedAt is null
                        ? "—"
                        : evidence.ObservedAt.Value.ToString(
                            "dd MMM yyyy HH:mm",
                            CultureInfo.GetCultureInfo(text.IsThai ? "th-TH" : "en-US")),
                    evidence.Size,
                    text[evidence.TypeKey],
                    evidence.IconGlyph,
                    evidence.AccentBrushKey,
                    evidence.ObservedAt))
                .ToArray());
    }

    private IReadOnlyList<ComplianceQueueReviewAction> CreateReviewActions()
    {
        var text = UiLanguageService.Shared;
        var reason = text["ComplianceQueueActionUnavailablePreview"];
        return
        [
            Action("confirm", "ComplianceQueueActionConfirm", "\uE73E", ComplianceQueueBrushKeys.ReviewConfirmed, "ComplianceQueueRoleProjectManager", ComplianceQueueViewerRole.ProjectManager, reason, text),
            Action("send-to-leader", "ComplianceQueueActionSendToLeader", "\uE8FA", ComplianceQueueBrushKeys.ReviewPendingLeader, "ComplianceQueueRoleProjectManager", ComplianceQueueViewerRole.ProjectManager, reason, text),
            Action("escalate-to-pm", "ComplianceQueueActionEscalateToProjectManager", "\uE8A7", ComplianceQueueBrushKeys.ReviewPendingProjectManager, "ComplianceQueueRoleLeader", ComplianceQueueViewerRole.Leader, reason, text),
            Action("dismiss", "ComplianceQueueActionDismiss", "\uE711", ComplianceQueueBrushKeys.ReviewDismissed, "ComplianceQueueRoleProjectManager", ComplianceQueueViewerRole.ProjectManager, reason, text),
        ];
    }

    private ComplianceQueueReviewAction Action(
        string id,
        string labelKey,
        string iconGlyph,
        string accentBrushKey,
        string roleKey,
        ComplianceQueueViewerRole requiredRole,
        string unavailableReason,
        UiLanguageService text) =>
        new(
            id,
            text[labelKey],
            iconGlyph,
            accentBrushKey,
            IsVisible: true,
            IsEnabled: false,
            unavailableReason,
            text[roleKey],
            IsRoleApplicable: ViewerRole == requiredRole,
            text.Format("ComplianceQueueActionAutomationFormat", text[labelKey]));

    private IReadOnlyList<ComplianceQueueSummaryCard> CreateSummaryCards(UiLanguageService text)
    {
        if (!_syntheticPreview)
        {
            return
            [
                new("suspected", text["ComplianceQueueSummarySuspected"], "—", text["ComplianceQueueLiveBoundary"], "\uE7BA", ComplianceQueueBrushKeys.EvidenceUnavailable),
                new("confirmed", text["ComplianceQueueSummaryConfirmed"], "—", text["ComplianceQueueLiveBoundary"], "\uE8FB", ComplianceQueueBrushKeys.EvidenceUnavailable),
                new("pending-leader", text["ComplianceQueueSummaryPendingLeader"], "—", text["ComplianceQueueLiveBoundary"], "\uE77B", ComplianceQueueBrushKeys.EvidenceUnavailable),
                new("pending-pm", text["ComplianceQueueSummaryPendingProjectManager"], "—", text["ComplianceQueueLiveBoundary"], "\uE716", ComplianceQueueBrushKeys.EvidenceUnavailable),
            ];
        }

        return
        [
            Summary("suspected", "ComplianceQueueSummarySuspected", "suspected", "\uE7BA", ComplianceQueueBrushKeys.ReviewSuspected, text),
            Summary("confirmed", "ComplianceQueueSummaryConfirmed", "confirmed", "\uE8FB", ComplianceQueueBrushKeys.ReviewConfirmed, text),
            Summary("pending-leader", "ComplianceQueueSummaryPendingLeader", "pending-leader", "\uE77B", ComplianceQueueBrushKeys.ReviewPendingLeader, text),
            Summary("pending-pm", "ComplianceQueueSummaryPendingProjectManager", "pending-pm", "\uE716", ComplianceQueueBrushKeys.ReviewPendingProjectManager, text),
        ];
    }

    private ComplianceQueueSummaryCard Summary(
        string id,
        string titleKey,
        string stateId,
        string iconGlyph,
        string brushKey,
        UiLanguageService text)
    {
        var count = _history.Count(item => item.StateId == stateId);
        return new(
            id,
            text[titleKey],
            count.ToString(CultureInfo.InvariantCulture),
            text["ComplianceQueueSummarySyntheticDetail"],
            iconGlyph,
            brushKey);
    }

    private static string RelativeTime(DateTimeOffset observedAt, UiLanguageService text)
    {
        var elapsed = FixtureNow - observedAt;
        if (elapsed.TotalSeconds < 60)
        {
            return text.Format(
                "ComplianceQueueSecondsAgoFormat",
                Math.Max(0, (int)Math.Floor(elapsed.TotalSeconds)));
        }

        return text.Format(
            "ComplianceQueueMinutesAgoFormat",
            Math.Max(1, (int)Math.Floor(elapsed.TotalMinutes)));
    }

    private static string SeverityBrushKey(string severityId) => severityId switch
    {
        "critical" => ComplianceQueueBrushKeys.SeverityCritical,
        "high" => ComplianceQueueBrushKeys.SeverityHigh,
        "medium" => ComplianceQueueBrushKeys.SeverityMedium,
        _ => ComplianceQueueBrushKeys.SeverityLow,
    };

    private static string StateBrushKey(string stateId) => stateId switch
    {
        "suspected" => ComplianceQueueBrushKeys.ReviewSuspected,
        "confirmed" => ComplianceQueueBrushKeys.ReviewConfirmed,
        "pending-leader" => ComplianceQueueBrushKeys.ReviewPendingLeader,
        "pending-pm" => ComplianceQueueBrushKeys.ReviewPendingProjectManager,
        _ => ComplianceQueueBrushKeys.ReviewDismissed,
    };

    private static string ViewerRoleKey(ComplianceQueueViewerRole role) => role switch
    {
        ComplianceQueueViewerRole.ProjectManager => "ComplianceQueueRoleProjectManager",
        ComplianceQueueViewerRole.Leader => "ComplianceQueueRoleLeader",
        ComplianceQueueViewerRole.Observer => "ComplianceQueueRoleObserver",
        _ => throw new ArgumentOutOfRangeException(nameof(role), role, "Unsupported viewer role."),
    };

    private static IReadOnlyList<RawIncident> CreateFixture() =>
    [
        Incident(
            "INC-2025-00073", "critical", 4, "TW", "Test Worker", "ComplianceQueueRoleWorker", "TASK-56", "ComplianceQueueTaskClientAnalytics", "ComplianceQueueTitleScopeViolation", "ComplianceQueueDescriptionScopeViolation", "suspected", "14:29:18", "RULE-02", "ComplianceQueueRuleScopeViolation", "ComplianceQueueRuleScopeViolationDetail", "ComplianceQueueDetectorRuleEngine", "PM", "Project Manager", "ComplianceQueueRoleProjectManager", [
                Evidence("commit_8f3c7a1.diff", "14:27:00", "89 KB", "ComplianceQueueEvidenceTypeDiff", "\uE8A5", ComplianceQueueBrushKeys.EvidenceBlocked),
                Evidence("api_clientanalytics_spec.yaml", "14:27:18", "12 KB", "ComplianceQueueEvidenceTypeArtifact", "\uE8A5", ComplianceQueueBrushKeys.EvidencePrimary),
                MissingEvidence("EVID-INC-2025-00073-REQUIRED-REVIEW", "ComplianceQueueEvidenceTypeArtifact", "\uE8A5"),
            ]),
        Incident(
            "INC-2025-00072", "high", 3, "BW", "Backend Worker 01", "ComplianceQueueRoleWorker", "TASK-113", "ComplianceQueueTaskAuthService", "ComplianceQueueTitleMissingEvidence", "ComplianceQueueDescriptionMissingEvidence", "confirmed", "14:26:10", "RULE-03", "ComplianceQueueRuleMissingEvidence", "ComplianceQueueRuleMissingEvidenceDetail", "ComplianceQueueDetectorRuleEngine", "BL", "Backend Leader", "ComplianceQueueRoleLeader", [
                Evidence("AuthService.cs", "14:25:20", "4.2 KB", "ComplianceQueueEvidenceTypeDiff", "\uE943", ComplianceQueueBrushKeys.EvidencePrimary),
                Evidence("UnitTest_Report_0513.xlsx", "14:25:44", "16 KB", "ComplianceQueueEvidenceTypeArtifact", "\uE8A5", ComplianceQueueBrushKeys.EvidenceWorking),
                MissingEvidence("EVID-INC-2025-00072-REQUIRED-TEST", "ComplianceQueueEvidenceTypeArtifact", "\uE8A5"),
            ]),
        Incident(
            "INC-2025-00074", "high", 3, "SW", "Security Worker", "ComplianceQueueRoleWorker", "TASK-120", "ComplianceQueueTaskUnitTests", "ComplianceQueueTitleMissingEvidence", "ComplianceQueueDescriptionMissingEvidence", "confirmed", "14:26:10", "RULE-03", "ComplianceQueueRuleMissingEvidence", "ComplianceQueueRuleMissingEvidenceDetail", "ComplianceQueueDetectorRuleEngine", "SL", "Security Lead", "ComplianceQueueRoleLeader", [
                Evidence("security-review.json", "14:25:50", "2.7 KB", "ComplianceQueueEvidenceTypeArtifact", "\uE8A5", ComplianceQueueBrushKeys.EvidenceReview),
            ]),
        Incident(
            "INC-2025-00071", "high", 3, "FW", "Frontend Worker 01", "ComplianceQueueRoleWorker", "TASK-97", "ComplianceQueueTaskLoginUi", "ComplianceQueueTitleReviewOrder", "ComplianceQueueDescriptionReviewOrder", "pending-leader", "14:24:30", "RULE-04", "ComplianceQueueRuleReviewOrder", "ComplianceQueueRuleReviewOrderDetail", "ComplianceQueueDetectorRuleEngine", "BL", "Backend Leader", "ComplianceQueueRoleLeader", [
                Evidence("review_request.json", "14:23:59", "2.1 KB", "ComplianceQueueEvidenceTypeArtifact", "\uE8A5", ComplianceQueueBrushKeys.EvidenceReview),
            ]),
        Incident(
            "INC-2025-00070", "medium", 2, "DW", "DevOps Worker", "ComplianceQueueRoleWorker", "TASK-78", "ComplianceQueueTaskDeployment", "ComplianceQueueTitleUnapprovedDeviation", "ComplianceQueueDescriptionUnapprovedDeviation", "pending-pm", "14:22:12", "RULE-05", "ComplianceQueueRuleUnapprovedDeviation", "ComplianceQueueRuleUnapprovedDeviationDetail", "ComplianceQueueDetectorRuleEngine", "PM", "Project Manager", "ComplianceQueueRoleProjectManager", [
                Evidence("deployment-plan.yml", "14:21:40", "6.8 KB", "ComplianceQueueEvidenceTypeArtifact", "\uE8A5", ComplianceQueueBrushKeys.EvidenceIdle),
            ]),
        Incident(
            "INC-2025-00069", "high", 3, "BW", "Backend Worker 02", "ComplianceQueueRoleWorker", "TASK-115", "ComplianceQueueTaskAuthService", "ComplianceQueueTitleMissingEvidence", "ComplianceQueueDescriptionMissingEvidence", "confirmed", "14:20:48", "RULE-03", "ComplianceQueueRuleMissingEvidence", "ComplianceQueueRuleMissingEvidenceDetail", "ComplianceQueueDetectorRuleEngine", "BL", "Backend Leader", "ComplianceQueueRoleLeader", [
                Evidence("AuthServiceTests.cs", "14:19:58", "3.1 KB", "ComplianceQueueEvidenceTypeDiff", "\uE943", ComplianceQueueBrushKeys.EvidencePrimary),
            ]),
        Incident(
            "INC-2025-00068", "medium", 2, "TW", "Test Worker", "ComplianceQueueRoleWorker", "TASK-120", "ComplianceQueueTaskUnitTests", "ComplianceQueueTitleMissingEvidence", "ComplianceQueueDescriptionMissingEvidence", "pending-pm", "14:18:04", "RULE-03", "ComplianceQueueRuleMissingEvidence", "ComplianceQueueRuleMissingEvidenceDetail", "ComplianceQueueDetectorRuleEngine", "PM", "Project Manager", "ComplianceQueueRoleProjectManager", [
                Evidence("UnitTest_Report_0513.xlsx", "14:17:12", "16 KB", "ComplianceQueueEvidenceTypeArtifact", "\uE8A5", ComplianceQueueBrushKeys.EvidenceWorking),
            ]),
        Incident(
            "INC-2025-00067", "low", 1, "PS", "PM Secretary", "ComplianceQueueRoleSecretary", "TASK-64", "ComplianceQueueTaskReportModule", "ComplianceQueueTitleUnapprovedDeviation", "ComplianceQueueDescriptionUnapprovedDeviation", "pending-leader", "14:15:36", "RULE-05", "ComplianceQueueRuleUnapprovedDeviation", "ComplianceQueueRuleUnapprovedDeviationDetail", "ComplianceQueueDetectorRuleEngine", "BL", "Backend Leader", "ComplianceQueueRoleLeader", [
                Evidence("deviation-request.md", "14:14:52", "1.4 KB", "ComplianceQueueEvidenceTypeArtifact", "\uE8A5", ComplianceQueueBrushKeys.EvidenceIdle),
            ]),
        Incident(
            "INC-2025-00066", "low", 1, "FW", "Frontend Worker 02", "ComplianceQueueRoleWorker", "TASK-83", "ComplianceQueueTaskLoginUi", "ComplianceQueueTitleScopeViolation", "ComplianceQueueDescriptionScopeViolation", "dismissed", "14:10:18", "RULE-02", "ComplianceQueueRuleScopeViolation", "ComplianceQueueRuleScopeViolationDetail", "ComplianceQueueDetectorRuleEngine", "PM", "Project Manager", "ComplianceQueueRoleProjectManager", [
                Evidence("scope-boundary.json", "14:09:47", "1.8 KB", "ComplianceQueueEvidenceTypeArtifact", "\uE8A5", ComplianceQueueBrushKeys.EvidenceUnavailable),
            ]),
    ];

    private static RawIncident Incident(
        string incidentId,
        string severityId,
        int severityRank,
        string initials,
        string actor,
        string actorRoleKey,
        string taskId,
        string taskTitleKey,
        string titleKey,
        string descriptionKey,
        string stateId,
        string time,
        string ruleId,
        string ruleLabelKey,
        string ruleDescriptionKey,
        string detectedByKey,
        string reviewerInitials,
        string reviewer,
        string reviewerRoleKey,
        IReadOnlyList<RawEvidence> evidence)
    {
        var timeParts = time.Split(':').Select(int.Parse).ToArray();
        var state = stateId switch
        {
            "suspected" => ComplianceQueueIncidentState.Suspected,
            "confirmed" => ComplianceQueueIncidentState.Confirmed,
            "pending-leader" => ComplianceQueueIncidentState.PendingLeader,
            "pending-pm" => ComplianceQueueIncidentState.PendingProjectManager,
            "dismissed" => ComplianceQueueIncidentState.Dismissed,
            _ => throw new ArgumentOutOfRangeException(nameof(stateId), stateId, "Unsupported fixture state."),
        };

        var linkedEvidence = evidence
            .Select(item => item with
            {
                EvidenceId = $"{incidentId}:{item.EvidenceId}",
                Reference = item.Reference is null
                    ? null
                    : $"synthetic://herdrops/evidence/{incidentId}/{item.EvidenceId}",
            })
            .ToArray();

        return new RawIncident(
            incidentId,
            severityId,
            severityRank,
            SeverityKeyFor(severityId),
            initials,
            actor,
            actorRoleKey,
            taskId,
            taskTitleKey,
            titleKey,
            descriptionKey,
            stateId,
            StateKeyFor(state),
            new DateTimeOffset(2026, 8, 15, timeParts[0], timeParts[1], timeParts[2], TimeSpan.FromHours(7)),
            ruleId,
            ruleLabelKey,
            ruleDescriptionKey,
            detectedByKey,
            reviewerInitials,
            reviewer,
            reviewerRoleKey,
            linkedEvidence);
    }

    private static RawEvidence Evidence(
        string fileName,
        string time,
        string size,
        string typeKey,
        string iconGlyph,
        string accentBrushKey)
    {
        var timeParts = time.Split(':').Select(int.Parse).ToArray();
        var observedAt = new DateTimeOffset(
            2026,
            8,
            15,
            timeParts[0],
            timeParts[1],
            timeParts[2],
            TimeSpan.FromHours(7));
        var sourceKey = EvidenceSourceKeyFor(typeKey);
        var metadataTuple = string.Join(
            "\u001F",
            fileName,
            observedAt.ToString("O", CultureInfo.InvariantCulture),
            size,
            typeKey,
            sourceKey,
            iconGlyph,
            accentBrushKey);
        var evidenceId = "EVID-" + Convert.ToHexString(
            SHA256.HashData(Encoding.UTF8.GetBytes(metadataTuple)))[..12];
        return new RawEvidence(
            evidenceId,
            fileName,
            observedAt,
            size,
            typeKey,
            sourceKey,
            SyntheticHash(metadataTuple),
            $"synthetic://herdrops/evidence/{evidenceId}",
            ComplianceQueueEvidenceAvailability.Present,
            iconGlyph,
            accentBrushKey);
    }

    private static RawEvidence MissingEvidence(
        string evidenceId,
        string typeKey,
        string iconGlyph) =>
        new(
            evidenceId,
            "—",
            null,
            "—",
            typeKey,
            "ComplianceQueueEvidenceSourceRuleEngine",
            null,
            null,
            ComplianceQueueEvidenceAvailability.Missing,
            iconGlyph,
            ComplianceQueueBrushKeys.EvidenceUnavailable);

    private static string EvidenceSourceKeyFor(string typeKey) => typeKey switch
    {
        "ComplianceQueueEvidenceTypeDiff" => "ComplianceQueueEvidenceSourceGit",
        "ComplianceQueueEvidenceTypeScreenshot" => "ComplianceQueueEvidenceSourceAgentReport",
        _ => "ComplianceQueueEvidenceSourceAgentReport",
    };

    // This is a deterministic synthetic provenance hash, not a claim about the
    // bytes of a real artifact. Real content hashes may legitimately repeat when
    // two evidence records contain identical bytes; the fixture has no artifact
    // bytes, so it binds the complete synthetic metadata tuple to prevent
    // different fixture tuples from accidentally sharing a hash.
    private static string SyntheticHash(string metadataTuple) => Convert.ToHexString(
        SHA256.HashData(Encoding.UTF8.GetBytes(
            $"HerdrOps.ComplianceQueue.SyntheticEvidence.v2|{metadataTuple}")));

    private static string SeverityKeyFor(string severityId) => severityId switch
    {
        "critical" => "ComplianceQueueSeverityCritical",
        "high" => "ComplianceQueueSeverityHigh",
        "medium" => "ComplianceQueueSeverityMedium",
        "low" => "ComplianceQueueSeverityLow",
        _ => throw new ArgumentOutOfRangeException(nameof(severityId), severityId, "Unsupported fixture severity."),
    };

    private static string StateKeyFor(ComplianceQueueIncidentState state) => state switch
    {
        ComplianceQueueIncidentState.Suspected => "ComplianceQueueStateSuspected",
        ComplianceQueueIncidentState.Confirmed => "ComplianceQueueStateConfirmed",
        ComplianceQueueIncidentState.PendingLeader => "ComplianceQueueStatePendingLeader",
        ComplianceQueueIncidentState.PendingProjectManager => "ComplianceQueueStatePendingProjectManager",
        ComplianceQueueIncidentState.Dismissed => "ComplianceQueueStateDismissed",
        _ => throw new ArgumentOutOfRangeException(nameof(state), state, "Unsupported fixture state."),
    };

    private sealed record RawIncident(
        string IncidentId,
        string SeverityId,
        int SeverityRank,
        string SeverityKey,
        string Initials,
        string Actor,
        string ActorRoleKey,
        string TaskId,
        string TaskTitleKey,
        string TitleKey,
        string DescriptionKey,
        string StateId,
        string StateKey,
        DateTimeOffset ObservedAt,
        string RuleId,
        string RuleLabelKey,
        string RuleDescriptionKey,
        string DetectedByKey,
        string ReviewerInitials,
        string Reviewer,
        string ReviewerRoleKey,
        IReadOnlyList<RawEvidence> Evidence);

    private sealed record RawEvidence(
        string EvidenceId,
        string FileName,
        DateTimeOffset? ObservedAt,
        string Size,
        string TypeKey,
        string SourceKey,
        string? Sha256,
        string? Reference,
        ComplianceQueueEvidenceAvailability Availability,
        string IconGlyph,
        string AccentBrushKey);
}
