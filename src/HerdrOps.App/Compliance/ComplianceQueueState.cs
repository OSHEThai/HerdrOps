using System.Globalization;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using HerdrOps.App.Live;
using HerdrOps.App.Localization;
using HerdrOps.App.ReviewIpc;
using HerdrOps.Contracts;
using HerdrOps.Contracts.ReviewIpc;
using HerdrOps.Domain.Compliance;

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
    private readonly List<RawIncident> _history;
    private readonly Dictionary<string, ComplianceReviewIncident> _authoritativeIncidents =
        new(StringComparer.Ordinal);
    private readonly Dictionary<string, long> _authoritativeIncidentGenerations =
        new(StringComparer.Ordinal);
    private readonly ComplianceReviewCommandCoordinator? _reviewCommands;
    private readonly string? _reviewerActorId;
    private readonly TimeProvider _timeProvider;
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
    private string _reviewReason = string.Empty;
    private string _reviewStatus = string.Empty;
    private string? _reviewStatusKey;
    private HerdrOpsReviewCapabilitiesResult? _reviewCapabilities;
    private bool _isReviewCapabilityLoading;
    private bool _isReviewCommandPending;
    private long _reviewCapabilityRequestVersion;
    private long _reviewCommandRequestVersion;
    private int _reviewCommandInFlight;
    private ReviewCommandGuard? _reviewCommandGuard;
    private bool _disposed;

    private sealed record ReviewCommandGuard(
        long RequestVersion,
        Guid CommandId,
        string IncidentId,
        ComplianceReviewState ExpectedState,
        long ExpectedSequence,
        long IncidentGeneration);

    private ComplianceQueueState(
        bool syntheticPreview,
        ComplianceQueueViewerRole viewerRole,
        ComplianceReviewCommandCoordinator? reviewCommands,
        string? reviewerActorId,
        TimeProvider? timeProvider)
    {
        if (!Enum.IsDefined(viewerRole))
        {
            throw new ArgumentOutOfRangeException(nameof(viewerRole), viewerRole, "Unsupported viewer role.");
        }

        _syntheticPreview = syntheticPreview;
        _history = syntheticPreview ? [.. CreateFixture()] : [];
        _reviewCommands = reviewCommands;
        _reviewerActorId = string.IsNullOrWhiteSpace(reviewerActorId)
            ? null
            : ComplianceReviewWorkflowContract.NormalizeActorId(reviewerActorId);
        _timeProvider = timeProvider ?? TimeProvider.System;
        EvidenceClass = syntheticPreview ? EvidenceClass.Synthetic : EvidenceClass.Contract;
        ViewerRole = viewerRole;
        RefreshLanguage();
    }

    public static ComplianceQueueState CreateSyntheticPreview(
        ComplianceQueueViewerRole viewerRole = ComplianceQueueViewerRole.ProjectManager) =>
        new(
            syntheticPreview: true,
            viewerRole,
            reviewCommands: null,
            reviewerActorId: null,
            timeProvider: null);

    public static ComplianceQueueState CreateUnavailableLiveState(
        ComplianceReviewCommandCoordinator? reviewCommands = null,
        string? reviewerActorId = null,
        ComplianceQueueViewerRole viewerRole = ComplianceQueueViewerRole.ProjectManager,
        TimeProvider? timeProvider = null) =>
        new(
            syntheticPreview: false,
            viewerRole,
            reviewCommands,
            reviewerActorId,
            timeProvider);

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
            var previousIncidentId = _selectedIncident?.IncidentId;
            var accepted = value is null
                ? null
                : VisibleIncidents.FirstOrDefault(item =>
                    item.IncidentId == value.IncidentId);
            var changed = Set(ref _selectedIncident, accepted);
            if (changed && !string.Equals(
                    previousIncidentId,
                    accepted?.IncidentId,
                    StringComparison.Ordinal))
            {
                Interlocked.Increment(ref _reviewCommandRequestVersion);
                _reviewCapabilities = null;
                _reviewReason = string.Empty;
                Raise(nameof(ReviewReason));
            }

            Raise(nameof(CanEditReviewReason));
            SynchronizeSelection();
            if (changed && !_syntheticPreview)
            {
                _ = RefreshReviewCapabilitiesAsync();
            }
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

    public bool IsLiveReview => !_syntheticPreview;

    public string ReviewReason
    {
        get => _reviewReason;
        set
        {
            var normalized = value ?? string.Empty;
            if (normalized.Length > ComplianceReviewWorkflowContract.MaximumReasonLength)
            {
                normalized = normalized[..ComplianceReviewWorkflowContract.MaximumReasonLength];
            }

            if (Set(ref _reviewReason, normalized))
            {
                SynchronizeSelection();
            }
        }
    }

    public string ReviewStatus
    {
        get => _reviewStatus;
        private set => Set(ref _reviewStatus, value);
    }

    public bool IsReviewCommandPending
    {
        get => _isReviewCommandPending;
        private set
        {
            if (Set(ref _isReviewCommandPending, value))
            {
                Raise(nameof(CanEditReviewReason));
            }
        }
    }

    public bool CanEditReviewReason =>
        IsLiveReview &&
        !IsReviewCommandPending &&
        !_isReviewCapabilityLoading &&
        SelectedIncident is { } selected &&
        _reviewCommands is not null &&
        _reviewerActorId is not null &&
        HasCurrentReviewCapabilities(selected);

    public int AuthoritativeIncidentCount => _syntheticPreview ? 0 : _history.Count;

    public void ApplyAuthoritativeReviewChange(ComplianceReviewStateChange change)
    {
        ArgumentNullException.ThrowIfNull(change);
        if (_syntheticPreview)
        {
            throw new InvalidOperationException(
                "Authoritative review state cannot mutate the synthetic Compliance Queue preview.");
        }

        var incident = ComplianceReviewWorkflowContract.NormalizeAndValidateIncident(
            change.Incident);
        var existing = _authoritativeIncidents.GetValueOrDefault(incident.IncidentId);
        var generation = _authoritativeIncidentGenerations.GetValueOrDefault(
            incident.IncidentId);
        if (existing is not null && incident.Sequence < existing.Sequence)
        {
            return;
        }

        if (existing is not null &&
            HasSameAuthoritativeIncident(existing, incident))
        {
            return;
        }

        // Once a different authoritative generation has been observed for the
        // same incident, a response from the older in-flight command cannot
        // replace it merely because its sequence is equal.
        if (_reviewCommandGuard is { } guard &&
            string.Equals(
                guard.IncidentId,
                incident.IncidentId,
                StringComparison.Ordinal) &&
            guard.IncidentGeneration != generation &&
            change.Decision?.AuditEventId == guard.CommandId)
        {
            return;
        }

        var affectsSelection = SelectedIncident is null || string.Equals(
            SelectedIncident.IncidentId,
            incident.IncidentId,
            StringComparison.Ordinal);
        _authoritativeIncidents[incident.IncidentId] = incident;
        _authoritativeIncidentGenerations[incident.IncidentId] =
            NextAuthoritativeGeneration(generation);
        if (affectsSelection)
        {
            _reviewCapabilities = null;
            Raise(nameof(CanEditReviewReason));
        }
        var replacement = CreateAuthoritativeIncident(incident, change.Decision);
        var index = _history.FindIndex(item => string.Equals(
            item.IncidentId,
            replacement.IncidentId,
            StringComparison.Ordinal));
        if (index < 0)
        {
            _history.Add(replacement);
        }
        else if (_history[index].ObservedAt <= replacement.ObservedAt)
        {
            _history[index] = replacement;
        }

        Raise(nameof(AuthoritativeIncidentCount));
        RefreshLanguage();
    }

    public async ValueTask RefreshReviewCapabilitiesAsync(
        CancellationToken cancellationToken = default)
    {
        if (_disposed || _syntheticPreview)
        {
            return;
        }

        var requestVersion = Interlocked.Increment(
            ref _reviewCapabilityRequestVersion);
        var selectedIncidentId = SelectedIncident?.IncidentId;
        if (selectedIncidentId is null ||
            !_authoritativeIncidents.TryGetValue(selectedIncidentId, out var incident))
        {
            _reviewCapabilities = null;
            _isReviewCapabilityLoading = false;
            Raise(nameof(CanEditReviewReason));
            SetReviewStatus(null);
            SynchronizeSelection();
            return;
        }

        var text = UiLanguageService.Shared;
        if (_reviewCommands is null || _reviewerActorId is null)
        {
            _reviewCapabilities = null;
            _isReviewCapabilityLoading = false;
            Raise(nameof(CanEditReviewReason));
            SetReviewStatus("ComplianceReviewIdentityUnavailable", text);
            SynchronizeSelection();
            return;
        }

        _isReviewCapabilityLoading = true;
        Raise(nameof(CanEditReviewReason));
        SetReviewStatus("ComplianceReviewCapabilitiesPending", text);
        SynchronizeSelection();
        try
        {
            var result = await _reviewCommands.ReadCapabilitiesAsync(
                new HerdrOpsReviewCapabilitiesRequest(
                    _reviewerActorId,
                    incident.IncidentId,
                    _timeProvider.GetUtcNow()),
                cancellationToken);
            ValidateCapabilitiesResult(result);
            if (!IsCurrentCapabilityRequest(
                    requestVersion,
                    selectedIncidentId,
                    incident.Sequence))
            {
                return;
            }

            _reviewCapabilities = result;
            Raise(nameof(CanEditReviewReason));
            SetReviewStatus(
                result.IncidentState is null
                    ? "ComplianceReviewRejectedUnknownIncident"
                    : !result.HasCurrentAuthority
                        ? "ComplianceReviewRejectedUnknownAuthority"
                        : result.IncidentState != (int)incident.State ||
                          result.IncidentSequence != incident.Sequence
                            ? "ComplianceReviewRejectedStaleState"
                            : result.AllowedDecisionKinds.Count == 0 &&
                              incident.State is not (
                                  ComplianceReviewState.Confirmed or
                                  ComplianceReviewState.Dismissed)
                                ? "ComplianceReviewActionNotAuthorized"
                            : "ComplianceReviewStatusReady",
                text);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            if (IsCurrentCapabilityRequest(
                    requestVersion,
                    selectedIncidentId,
                    incident.Sequence))
            {
                _reviewCapabilities = null;
                SetReviewStatus("ComplianceReviewCapabilitiesCancelled", text);
            }
        }
        catch (Exception exception) when (
            exception is IOException or TimeoutException or ArgumentException or InvalidOperationException)
        {
            _ = exception;
            if (IsCurrentCapabilityRequest(
                    requestVersion,
                    selectedIncidentId,
                    incident.Sequence))
            {
                _reviewCapabilities = null;
                SetReviewStatus("ComplianceReviewCoreUnavailable", text);
            }
        }
        finally
        {
            if (requestVersion == Volatile.Read(
                    ref _reviewCapabilityRequestVersion))
            {
                _isReviewCapabilityLoading = false;
                Raise(nameof(CanEditReviewReason));
                SynchronizeSelection();
            }
        }
    }

    private bool IsCurrentCapabilityRequest(
        long requestVersion,
        string incidentId,
        long incidentSequence) =>
        !_disposed &&
        requestVersion == Volatile.Read(ref _reviewCapabilityRequestVersion) &&
        string.Equals(
            SelectedIncident?.IncidentId,
            incidentId,
            StringComparison.Ordinal) &&
        _authoritativeIncidents.TryGetValue(incidentId, out var current) &&
        current.Sequence == incidentSequence;

    public async ValueTask<bool> ExecuteReviewActionAsync(
        ComplianceQueueReviewAction action,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(action);
        if (_disposed || _syntheticPreview || _reviewCommands is null ||
            _reviewerActorId is null || IsReviewCommandPending)
        {
            return false;
        }

        var canonicalAction = ReviewActions.FirstOrDefault(item =>
            string.Equals(item.Id, action.Id, StringComparison.Ordinal));
        var selectedIncidentId = SelectedIncident?.IncidentId;
        if (canonicalAction is null || !canonicalAction.IsEnabled ||
            selectedIncidentId is null ||
            !_authoritativeIncidents.TryGetValue(selectedIncidentId, out var incident))
        {
            return false;
        }

        var text = UiLanguageService.Shared;
        var reason = ReviewReason.Trim();
        if (reason.Length == 0)
        {
            SetReviewStatus("ComplianceReviewReasonRequired", text);
            SynchronizeSelection();
            return false;
        }

        if (Interlocked.CompareExchange(ref _reviewCommandInFlight, 1, 0) != 0)
        {
            return false;
        }

        try
        {
            var requestVersion = Interlocked.Increment(ref _reviewCommandRequestVersion);
            var request = new HerdrOpsReviewCommandRequest(
                ComplianceReviewWorkflowContract.ContractVersion,
                Guid.NewGuid(),
                incident.IncidentId,
                (int)incident.State,
                incident.Sequence,
                _reviewerActorId,
                (int)DecisionForAction(canonicalAction.Id),
                reason,
                incident.InitialEvidenceIdentitySha256s);
            var commandGuard = new ReviewCommandGuard(
                requestVersion,
                request.CommandId,
                incident.IncidentId,
                incident.State,
                incident.Sequence,
                _authoritativeIncidentGenerations.GetValueOrDefault(
                    incident.IncidentId));
            _reviewCommandGuard = commandGuard;
            IsReviewCommandPending = true;
            SetReviewStatus("ComplianceReviewStatusPending", text);
            SynchronizeSelection();
            try
            {
                var result = await _reviewCommands.ExecuteAsync(
                    request,
                    cancellationToken);
                if (IsCurrentReviewCommand(commandGuard, result))
                {
                    SetReviewStatus(
                        result.IsAccepted
                            ? result.WasAlreadyPresent
                                ? "ComplianceReviewStatusAlreadyAccepted"
                                : "ComplianceReviewStatusAccepted"
                            : RejectionStatusKey(result.RejectionCode),
                        text);
                    if (result.IsAccepted)
                    {
                        _reviewReason = string.Empty;
                        Raise(nameof(ReviewReason));
                    }
                }

                return result.IsAccepted;
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                if (IsCurrentReviewCommand(commandGuard))
                {
                    SetReviewStatus("ComplianceReviewCapabilitiesCancelled", text);
                }

                return false;
            }
            catch (Exception exception) when (
                exception is IOException or TimeoutException or ArgumentException or InvalidOperationException)
            {
                _ = exception;
                if (IsCurrentReviewCommand(commandGuard))
                {
                    SetReviewStatus("ComplianceReviewCoreUnavailable", text);
                }

                return false;
            }
            finally
            {
                if (ReferenceEquals(_reviewCommandGuard, commandGuard))
                {
                    _reviewCommandGuard = null;
                }

                IsReviewCommandPending = false;
                SynchronizeSelection();
            }
        }
        finally
        {
            Volatile.Write(ref _reviewCommandInFlight, 0);
        }
    }

    public bool TrySelectIncident(string incidentId)
    {
        if (_disposed || string.IsNullOrWhiteSpace(incidentId))
        {
            return false;
        }

        var incident = VisibleIncidents.FirstOrDefault(item => string.Equals(
            item.IncidentId,
            incidentId,
            StringComparison.Ordinal));
        if (incident is null)
        {
            return false;
        }

        SelectedIncident = incident;
        return string.Equals(
            SelectedIncident?.IncidentId,
            incidentId,
            StringComparison.Ordinal);
    }

    private void SetReviewStatus(
        string? key,
        UiLanguageService? text = null)
    {
        _reviewStatusKey = key;
        ReviewStatus = key is null
            ? string.Empty
            : (text ?? UiLanguageService.Shared)[key];
    }

    public void RefreshLanguage()
    {
        if (_disposed)
        {
            return;
        }

        var text = UiLanguageService.Shared;
        if (_reviewStatusKey is not null)
        {
            ReviewStatus = text[_reviewStatusKey];
        }

        var selectedIncidentId = SelectedIncident?.IncidentId;
        var selectedSeverityId = SelectedSeverityFilter.Id;
        var selectedStateId = SelectedStateFilter.Id;
        var selectedActorId = SelectedActorFilter.Id;
        var selectedTaskId = SelectedTaskFilter.Id;
        var selectedReviewerId = SelectedReviewerFilter.Id;
        var selectedSortId = SelectedSortOption.Id;

        SourceLabel = _syntheticPreview
            ? text["ComplianceQueueSyntheticSource"]
            : _history.Count == 0
                ? text["ComplianceQueueLiveSourceUnavailable"]
                : text["ComplianceQueueCoreReviewSource"];
        ConnectionLabel = _syntheticPreview
            ? text["ComplianceQueueSyntheticBoundary"]
            : _history.Count == 0
                ? text["ComplianceQueueLiveBoundary"]
                : text["ComplianceQueueCoreReviewBoundary"];
        ViewerRoleLabel = text[ViewerRoleKey(ViewerRole)];

        SeverityFilters =
        [
            new("all", text["ComplianceQueueFilterAll"]),
            new("critical", text["ComplianceQueueSeverityCritical"]),
            new("high", text["ComplianceQueueSeverityHigh"]),
            new("medium", text["ComplianceQueueSeverityMedium"]),
            new("low", text["ComplianceQueueSeverityLow"]),
            .. _history.Any(item => item.SeverityId == "unavailable")
                ? [new ComplianceQueueFilterOption(
                    "unavailable",
                    text["ComplianceQueueSeverityUnavailable"])]
                : Array.Empty<ComplianceQueueFilterOption>(),
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
        Interlocked.Increment(ref _reviewCapabilityRequestVersion);
        Interlocked.Increment(ref _reviewCommandRequestVersion);
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
        ReviewActions = _syntheticPreview
            ? CreateReviewActions()
            : CreateLiveReviewActions(raw);
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
            Action("confirm", "ComplianceQueueActionConfirm", "\uE73E", ComplianceQueueBrushKeys.ReviewConfirmed, "ComplianceQueueRoleProjectManager", isEnabled: false, reason, ViewerRole == ComplianceQueueViewerRole.ProjectManager, text),
            Action("send-to-leader", "ComplianceQueueActionSendToLeader", "\uE8FA", ComplianceQueueBrushKeys.ReviewPendingLeader, "ComplianceQueueRoleProjectManager", isEnabled: false, reason, ViewerRole == ComplianceQueueViewerRole.ProjectManager, text),
            Action("escalate-to-pm", "ComplianceQueueActionEscalateToProjectManager", "\uE8A7", ComplianceQueueBrushKeys.ReviewPendingProjectManager, "ComplianceQueueRoleLeader", isEnabled: false, reason, ViewerRole == ComplianceQueueViewerRole.Leader, text),
            Action("dismiss", "ComplianceQueueActionDismiss", "\uE711", ComplianceQueueBrushKeys.ReviewDismissed, "ComplianceQueueRoleProjectManager", isEnabled: false, reason, ViewerRole == ComplianceQueueViewerRole.ProjectManager, text),
        ];
    }

    private IReadOnlyList<ComplianceQueueReviewAction> CreateLiveReviewActions(
        RawIncident raw)
    {
        var text = UiLanguageService.Shared;
        if (!_authoritativeIncidents.TryGetValue(raw.IncidentId, out var incident))
        {
            return [];
        }

        var capabilitiesCurrent = _reviewCapabilities is not null &&
            _reviewCapabilities.IncidentState == (int)incident.State &&
            _reviewCapabilities.IncidentSequence == incident.Sequence;
        var reviewerRole = capabilitiesCurrent && _reviewCapabilities!.ReviewerRole is int roleValue &&
            Enum.IsDefined((ComplianceReviewerRole)roleValue)
                ? (ComplianceReviewerRole?)roleValue
                : null;
        var reasonPresent = !string.IsNullOrWhiteSpace(ReviewReason);
        return
        [
            LiveAction("confirm", "ComplianceQueueActionConfirm", "\uE73E", ComplianceQueueBrushKeys.ReviewConfirmed, "ComplianceQueueRoleProjectManager", ComplianceReviewerRole.ProjectManager, ComplianceReviewDecisionKind.Confirm),
            LiveAction("send-to-leader", "ComplianceQueueActionSendToLeader", "\uE8FA", ComplianceQueueBrushKeys.ReviewPendingLeader, "ComplianceQueueRoleProjectManager", ComplianceReviewerRole.ProjectManager, ComplianceReviewDecisionKind.SendToLeader),
            LiveAction("escalate-to-pm", "ComplianceQueueActionEscalateToProjectManager", "\uE8A7", ComplianceQueueBrushKeys.ReviewPendingProjectManager, "ComplianceQueueRoleLeader", ComplianceReviewerRole.Leader, ComplianceReviewDecisionKind.EscalateToProjectManager),
            LiveAction("dismiss", "ComplianceQueueActionDismiss", "\uE711", ComplianceQueueBrushKeys.ReviewDismissed, "ComplianceQueueRoleProjectManager", ComplianceReviewerRole.ProjectManager, ComplianceReviewDecisionKind.Dismiss),
        ];

        ComplianceQueueReviewAction LiveAction(
            string id,
            string labelKey,
            string iconGlyph,
            string accentBrushKey,
            string roleKey,
            ComplianceReviewerRole requiredRole,
            ComplianceReviewDecisionKind decision)
        {
            var roleApplicable = reviewerRole == requiredRole;
            var allowed = capabilitiesCurrent &&
                _reviewCapabilities!.AllowedDecisionKinds.Contains((int)decision);
            var enabled = allowed && reasonPresent &&
                !_isReviewCapabilityLoading && !IsReviewCommandPending;
            var unavailableReason = enabled
                ? text["ComplianceReviewActionReady"]
                : _reviewCommands is null || _reviewerActorId is null
                    ? text["ComplianceReviewIdentityUnavailable"]
                    : _isReviewCapabilityLoading
                        ? text["ComplianceReviewCapabilitiesPending"]
                        : !capabilitiesCurrent
                            ? text["ComplianceReviewCapabilitiesUnavailable"]
                            : !allowed
                                ? text["ComplianceReviewActionNotAuthorized"]
                                : !reasonPresent
                                    ? text["ComplianceReviewReasonRequired"]
                                    : text["ComplianceReviewStatusPending"];
            return Action(
                id,
                labelKey,
                iconGlyph,
                accentBrushKey,
                roleKey,
                enabled,
                unavailableReason,
                roleApplicable,
                text);
        }
    }

    private ComplianceQueueReviewAction Action(
        string id,
        string labelKey,
        string iconGlyph,
        string accentBrushKey,
        string roleKey,
        bool isEnabled,
        string unavailableReason,
        bool isRoleApplicable,
        UiLanguageService text) =>
        new(
            id,
            text[labelKey],
            iconGlyph,
            accentBrushKey,
            IsVisible: true,
            isEnabled,
            unavailableReason,
            text[roleKey],
            isRoleApplicable,
            text.Format("ComplianceQueueActionAutomationFormat", text[labelKey]));

    private static ComplianceReviewDecisionKind DecisionForAction(string actionId) =>
        actionId switch
        {
            "confirm" => ComplianceReviewDecisionKind.Confirm,
            "send-to-leader" => ComplianceReviewDecisionKind.SendToLeader,
            "escalate-to-pm" => ComplianceReviewDecisionKind.EscalateToProjectManager,
            "dismiss" => ComplianceReviewDecisionKind.Dismiss,
            _ => throw new ArgumentOutOfRangeException(
                nameof(actionId),
                actionId,
                "Unsupported Compliance Queue review action."),
        };

    private static string RejectionStatusKey(int rejectionCode) =>
        (ComplianceReviewRejectionCode)rejectionCode switch
        {
            ComplianceReviewRejectionCode.UnknownIncident =>
                "ComplianceReviewRejectedUnknownIncident",
            ComplianceReviewRejectionCode.UnknownAuthority =>
                "ComplianceReviewRejectedUnknownAuthority",
            ComplianceReviewRejectionCode.UnauthorizedRole =>
                "ComplianceReviewRejectedUnauthorizedRole",
            ComplianceReviewRejectionCode.SelfReview =>
                "ComplianceReviewRejectedSelfReview",
            ComplianceReviewRejectionCode.StaleState =>
                "ComplianceReviewRejectedStaleState",
            ComplianceReviewRejectionCode.InvalidTransition =>
                "ComplianceReviewRejectedInvalidTransition",
            ComplianceReviewRejectionCode.AuthorityNotYetEffective =>
                "ComplianceReviewRejectedAuthorityNotEffective",
            _ => "ComplianceReviewCoreUnavailable",
        };

    private static void ValidateCapabilitiesResult(
        HerdrOpsReviewCapabilitiesResult result)
    {
        ArgumentNullException.ThrowIfNull(result);
        if (result.AllowedDecisionKinds is null ||
            result.HasCurrentAuthority != result.ReviewerRole.HasValue ||
            result.IncidentState.HasValue != result.IncidentSequence.HasValue ||
            (result.IncidentSequence.HasValue && result.IncidentSequence.Value < 0) ||
            (result.ReviewerRole.HasValue &&
             !Enum.IsDefined((ComplianceReviewerRole)result.ReviewerRole.Value)) ||
            (result.IncidentState.HasValue &&
             !Enum.IsDefined((ComplianceReviewState)result.IncidentState.Value)) ||
            result.AllowedDecisionKinds.Distinct().Count() !=
            result.AllowedDecisionKinds.Count ||
            result.AllowedDecisionKinds.Any(item =>
                !Enum.IsDefined((ComplianceReviewDecisionKind)item)) ||
            ((!result.HasCurrentAuthority || !result.IncidentState.HasValue) &&
             result.AllowedDecisionKinds.Count != 0) ||
            result.AllowedDecisionKinds.Any(item => !IsCapabilityTupleValid(
                (ComplianceReviewerRole)result.ReviewerRole!.Value,
                (ComplianceReviewState)result.IncidentState!.Value,
                (ComplianceReviewDecisionKind)item)))
        {
            throw new HerdrOpsReviewCommandProtocolException(
                "Core returned an invalid review-capability result.");
        }
    }

    private static bool IsCapabilityTupleValid(
        ComplianceReviewerRole role,
        ComplianceReviewState state,
        ComplianceReviewDecisionKind decision) =>
        (state, role, decision) switch
        {
            (ComplianceReviewState.Suspected, ComplianceReviewerRole.ProjectManager,
                ComplianceReviewDecisionKind.Confirm or
                ComplianceReviewDecisionKind.SendToLeader or
                ComplianceReviewDecisionKind.Dismiss) => true,
            (ComplianceReviewState.PendingLeader, ComplianceReviewerRole.Leader,
                ComplianceReviewDecisionKind.EscalateToProjectManager) => true,
            (ComplianceReviewState.PendingProjectManager, ComplianceReviewerRole.ProjectManager,
                ComplianceReviewDecisionKind.Confirm or
                ComplianceReviewDecisionKind.SendToLeader or
                ComplianceReviewDecisionKind.Dismiss) => true,
            _ => false,
        };

    private IReadOnlyList<ComplianceQueueSummaryCard> CreateSummaryCards(UiLanguageService text)
    {
        if (!_syntheticPreview)
        {
            if (_history.Count > 0)
            {
                return
                [
                    AuthoritativeSummary("suspected", "ComplianceQueueSummarySuspected", "suspected", "\uE7BA", ComplianceQueueBrushKeys.ReviewSuspected, text),
                    AuthoritativeSummary("confirmed", "ComplianceQueueSummaryConfirmed", "confirmed", "\uE8FB", ComplianceQueueBrushKeys.ReviewConfirmed, text),
                    AuthoritativeSummary("pending-leader", "ComplianceQueueSummaryPendingLeader", "pending-leader", "\uE77B", ComplianceQueueBrushKeys.ReviewPendingLeader, text),
                    AuthoritativeSummary("pending-pm", "ComplianceQueueSummaryPendingProjectManager", "pending-pm", "\uE716", ComplianceQueueBrushKeys.ReviewPendingProjectManager, text),
                ];
            }

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

    private ComplianceQueueSummaryCard AuthoritativeSummary(
        string id,
        string titleKey,
        string stateId,
        string glyph,
        string brushKey,
        UiLanguageService text) =>
        new(
            id,
            text[titleKey],
            _history.Count(item => item.StateId == stateId)
                .ToString(CultureInfo.InvariantCulture),
            text["ComplianceQueueCoreReviewBoundary"],
            glyph,
            brushKey);

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

    private string RelativeTime(DateTimeOffset observedAt, UiLanguageService text)
    {
        var elapsed = (_syntheticPreview ? FixtureNow : _timeProvider.GetUtcNow()) - observedAt;
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

    private bool IsCurrentReviewCommand(
        ReviewCommandGuard guard,
        HerdrOpsReviewCommandResult? result = null)
    {
        if (_disposed ||
            guard.RequestVersion != Volatile.Read(ref _reviewCommandRequestVersion) ||
            !string.Equals(
                SelectedIncident?.IncidentId,
                guard.IncidentId,
                StringComparison.Ordinal) ||
            !_authoritativeIncidents.TryGetValue(guard.IncidentId, out var current))
        {
            return false;
        }

        var generation = _authoritativeIncidentGenerations.GetValueOrDefault(
            guard.IncidentId);
        if (generation == guard.IncidentGeneration &&
            current.State == guard.ExpectedState &&
            current.Sequence == guard.ExpectedSequence)
        {
            return true;
        }

        if (result?.IsAccepted != true ||
            result.Incident is not { } resultIncident ||
            resultIncident.Sequence < 0 ||
            !Enum.IsDefined((ComplianceReviewState)resultIncident.State) ||
            current.Sequence != resultIncident.Sequence ||
            current.State != (ComplianceReviewState)resultIncident.State ||
            current.LastAuditEventId != guard.CommandId ||
            generation != NextAuthoritativeGeneration(guard.IncidentGeneration))
        {
            return false;
        }

        return true;
    }

    private static bool HasSameAuthoritativeIncident(
        ComplianceReviewIncident first,
        ComplianceReviewIncident second) =>
        first.ContractVersion == second.ContractVersion &&
        string.Equals(first.IncidentId, second.IncidentId, StringComparison.Ordinal) &&
        string.Equals(first.TaskId, second.TaskId, StringComparison.Ordinal) &&
        string.Equals(first.SubjectActorId, second.SubjectActorId, StringComparison.Ordinal) &&
        first.RegisteredUtc == second.RegisteredUtc &&
        first.InitialEvidenceIdentitySha256s.SequenceEqual(
            second.InitialEvidenceIdentitySha256s,
            StringComparer.Ordinal) &&
        string.Equals(first.RegistrationSha256, second.RegistrationSha256, StringComparison.Ordinal) &&
        first.State == second.State &&
        first.Sequence == second.Sequence &&
        first.UpdatedUtc == second.UpdatedUtc &&
        first.LastAuditEventId == second.LastAuditEventId &&
        string.Equals(first.LastAuditSha256, second.LastAuditSha256, StringComparison.Ordinal);

    private static long NextAuthoritativeGeneration(long generation) =>
        generation == long.MaxValue ? long.MaxValue : generation + 1;

    private bool HasCurrentReviewCapabilities(ComplianceQueueIncidentRow incident) =>
        _reviewCapabilities is { HasCurrentAuthority: true } capabilities &&
        _authoritativeIncidents.TryGetValue(incident.IncidentId, out var current) &&
        capabilities.IncidentState == (int)current.State &&
        capabilities.IncidentSequence == current.Sequence &&
        capabilities.AllowedDecisionKinds.Count > 0;

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
        "unavailable" => "ComplianceQueueSeverityUnavailable",
        _ => throw new ArgumentOutOfRangeException(nameof(severityId), severityId, "Unsupported fixture severity."),
    };

    private static RawIncident CreateAuthoritativeIncident(
        ComplianceReviewIncident incident,
        ComplianceReviewAuditEvent? auditEvent)
    {
        var stateId = incident.State switch
        {
            ComplianceReviewState.Suspected => "suspected",
            ComplianceReviewState.PendingLeader => "pending-leader",
            ComplianceReviewState.PendingProjectManager => "pending-pm",
            ComplianceReviewState.Confirmed => "confirmed",
            ComplianceReviewState.Dismissed => "dismissed",
            _ => throw new ArgumentOutOfRangeException(
                nameof(incident),
                incident.State,
                "Unsupported authoritative review state."),
        };
        var evidence = incident.InitialEvidenceIdentitySha256s
            .Concat(auditEvent?.EvidenceIdentitySha256s ?? [])
            .Distinct(StringComparer.Ordinal)
            .Order(StringComparer.Ordinal)
            .Select(identity => new RawEvidence(
                identity,
                $"EVID-{identity[..12]}",
                auditEvent?.OccurredUtc ?? incident.RegisteredUtc,
                "—",
                "ComplianceQueueEvidenceTypeIdentity",
                "ComplianceQueueEvidenceSourceCoreReview",
                identity,
                Reference: null,
                ComplianceQueueEvidenceAvailability.Present,
                "\uE8A5",
                ComplianceQueueBrushKeys.EvidenceReview))
            .ToArray();
        var reviewerRoleKey = auditEvent?.ReviewerRole switch
        {
            ComplianceReviewerRole.ProjectManager => "ComplianceQueueRoleProjectManager",
            ComplianceReviewerRole.Leader => "ComplianceQueueRoleLeader",
            _ => "ComplianceQueueRoleObserver",
        };
        var reviewer = auditEvent?.ReviewerActorId ?? "—";
        return new RawIncident(
            incident.IncidentId,
            "unavailable",
            SeverityRank: 0,
            "ComplianceQueueSeverityUnavailable",
            Initials(incident.SubjectActorId),
            incident.SubjectActorId,
            "ComplianceQueueRoleWorker",
            incident.TaskId,
            "ComplianceQueueTaskCoreReview",
            "ComplianceQueueTitleCoreReview",
            "ComplianceQueueDescriptionCoreReview",
            stateId,
            StateKeyFor((ComplianceQueueIncidentState)(incident.State switch
            {
                ComplianceReviewState.Suspected => 1,
                ComplianceReviewState.Confirmed => 2,
                ComplianceReviewState.PendingLeader => 3,
                ComplianceReviewState.PendingProjectManager => 4,
                ComplianceReviewState.Dismissed => 5,
                _ => throw new ArgumentOutOfRangeException(nameof(incident)),
            })),
            incident.UpdatedUtc,
            "HERDROPS-REVIEW-V1",
            "ComplianceQueueRuleCoreReview",
            "ComplianceQueueRuleCoreReviewDetail",
            "ComplianceQueueDetectorCore",
            Initials(reviewer),
            reviewer,
            reviewerRoleKey,
            evidence);
    }

    private static string Initials(string value)
    {
        var characters = value
            .Where(char.IsLetterOrDigit)
            .Take(2)
            .Select(char.ToUpperInvariant)
            .ToArray();
        return characters.Length == 0 ? "—" : new string(characters);
    }

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
