using System.Globalization;
using System.IO;
using HerdrOps.App.Activity;
using HerdrOps.App.Live;
using HerdrOps.App.Localization;
using HerdrOps.App.Overview;
using HerdrOps.Contracts;

namespace HerdrOps.App.Files;

public sealed record FileActivitySummaryCard(
    string Id,
    string Title,
    string Value,
    string Detail,
    string IconGlyph,
    string AccentBrushKey);

public sealed record FileActivityRow(
    string EventId,
    string Time,
    string Initials,
    string Agent,
    string Action,
    string RelativePath,
    string TaskId,
    string Confidence,
    string Source,
    string AccentBrushKey,
    string ScopeLabel,
    string ScopeBrushKey);

public sealed record FileActivityDetail(
    string EventId,
    string FileName,
    string Status,
    string RelativePath,
    string Size,
    string FileType,
    string ModifiedTime,
    string Actor,
    string TaskId,
    string Confidence,
    string Source,
    string AccentBrushKey,
    IReadOnlyList<string> DiffLines);

public sealed record FileActivityChartPoint(string Label, int Value, string BrushKey);

public sealed record FileActivityRiskPath(
    string RelativePath,
    string Classification,
    string Count,
    string Trend,
    string AccentBrushKey);

/// <summary>
/// Deterministic File Activity presentation state. The fixture reproduces the approved
/// hierarchy but is always labelled synthetic; live collector wiring remains a separate gate.
/// </summary>
public sealed class FileActivityState : ObservableState
{
    private readonly bool _syntheticPreview;
    private readonly IReadOnlyList<RawFileActivity> _history;
    private IReadOnlyList<FileActivitySummaryCard> _summaryCards = [];
    private IReadOnlyList<ActivityFilterOption> _actionFilters = [];
    private IReadOnlyList<ActivityFilterOption> _taskFilters = [];
    private IReadOnlyList<ActivityFilterOption> _sourceFilters = [];
    private ActivityFilterOption _selectedActionFilter = new("all", string.Empty);
    private ActivityFilterOption _selectedTaskFilter = new("all", string.Empty);
    private ActivityFilterOption _selectedSourceFilter = new("all", string.Empty);
    private string _searchText = string.Empty;
    private IReadOnlyList<FileActivityRow> _visibleEvents = [];
    private FileActivityRow? _selectedEvent;
    private FileActivityDetail? _selectedDetail;
    private IReadOnlyList<FileActivityRiskPath> _riskPaths = [];
    private string _sourceLabel = string.Empty;
    private string _connectionLabel = string.Empty;
    private string _resultLabel = string.Empty;

    private FileActivityState(bool syntheticPreview)
    {
        _syntheticPreview = syntheticPreview;
        _history = syntheticPreview ? CreateFixture() : [];
        EvidenceClass = syntheticPreview ? EvidenceClass.Synthetic : EvidenceClass.Contract;
        ActivityOverTime = CreateActivityOverTime();
        FileTypeActivity = CreateFileTypeActivity();
        RefreshLanguage();
    }

    public static FileActivityState CreateSyntheticPreview() => new(syntheticPreview: true);

    public static FileActivityState CreateUnavailable() => new(syntheticPreview: false);

    public EvidenceClass EvidenceClass { get; }

    public bool IsSyntheticPreview => _syntheticPreview;

    public IReadOnlyList<FileActivitySummaryCard> SummaryCards
    {
        get => _summaryCards;
        private set => Set(ref _summaryCards, value);
    }

    public IReadOnlyList<ActivityFilterOption> ActionFilters
    {
        get => _actionFilters;
        private set => Set(ref _actionFilters, value);
    }

    public IReadOnlyList<ActivityFilterOption> TaskFilters
    {
        get => _taskFilters;
        private set => Set(ref _taskFilters, value);
    }

    public IReadOnlyList<ActivityFilterOption> SourceFilters
    {
        get => _sourceFilters;
        private set => Set(ref _sourceFilters, value);
    }

    public ActivityFilterOption SelectedActionFilter
    {
        get => _selectedActionFilter;
        set => SetFilter(ref _selectedActionFilter, value, nameof(SelectedActionFilter));
    }

    public ActivityFilterOption SelectedTaskFilter
    {
        get => _selectedTaskFilter;
        set => SetFilter(ref _selectedTaskFilter, value, nameof(SelectedTaskFilter));
    }

    public ActivityFilterOption SelectedSourceFilter
    {
        get => _selectedSourceFilter;
        set => SetFilter(ref _selectedSourceFilter, value, nameof(SelectedSourceFilter));
    }

    public string SearchText
    {
        get => _searchText;
        set
        {
            if (Set(ref _searchText, value ?? string.Empty))
            {
                ApplyFilters(SelectedEvent?.EventId);
            }
        }
    }

    public IReadOnlyList<FileActivityRow> VisibleEvents
    {
        get => _visibleEvents;
        private set => Set(ref _visibleEvents, value);
    }

    public FileActivityRow? SelectedEvent
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

    public FileActivityDetail? SelectedDetail
    {
        get => _selectedDetail;
        private set => Set(ref _selectedDetail, value);
    }

    public IReadOnlyList<FileActivityChartPoint> ActivityOverTime { get; }

    public IReadOnlyList<FileActivityChartPoint> FileTypeActivity { get; }

    public IReadOnlyList<FileActivityRiskPath> RiskPaths
    {
        get => _riskPaths;
        private set => Set(ref _riskPaths, value);
    }

    public string SourceLabel { get => _sourceLabel; private set => Set(ref _sourceLabel, value); }

    public string ConnectionLabel
    {
        get => _connectionLabel;
        private set => Set(ref _connectionLabel, value);
    }

    public string ResultLabel { get => _resultLabel; private set => Set(ref _resultLabel, value); }

    public void RefreshLanguage()
    {
        var text = UiLanguageService.Shared;
        var selectedEventId = SelectedEvent?.EventId;
        var actionId = SelectedActionFilter.Id;
        var taskId = SelectedTaskFilter.Id;
        var sourceId = SelectedSourceFilter.Id;
        SourceLabel = _syntheticPreview
            ? text["FileSyntheticSource"]
            : text["FileLiveSourceUnavailable"];
        ConnectionLabel = _syntheticPreview
            ? text["FileSyntheticBoundary"]
            : text["FileWaitingForCollector"];
        ActionFilters =
        [
            new("all", text["FileFilterAllActions"]),
            new("read", text["FileActionRead"]),
            new("modified", text["FileActionModified"]),
            new("created", text["FileActionCreated"]),
            new("deleted", text["FileActionDeleted"]),
            new("blocked", text["FileActionBlocked"]),
        ];
        TaskFilters =
        [
            new("all", text["FileFilterAllTasks"]),
            .. _history.Select(item => item.TaskId)
                .Distinct(StringComparer.Ordinal)
                .Order(StringComparer.Ordinal)
                .Select(item => new ActivityFilterOption(item, item)),
        ];
        SourceFilters =
        [
            new("all", text["FileFilterAllSources"]),
            new("filesystem", text["FileSourceWatcher"]),
            new("git", text["FileSourceGit"]),
            new("agent", text["FileSourceAgentReport"]),
        ];
        ReplaceSelection(ref _selectedActionFilter, ActionFilters, actionId, nameof(SelectedActionFilter));
        ReplaceSelection(ref _selectedTaskFilter, TaskFilters, taskId, nameof(SelectedTaskFilter));
        ReplaceSelection(ref _selectedSourceFilter, SourceFilters, sourceId, nameof(SelectedSourceFilter));
        SummaryCards = CreateSummaryCards(text);
        RiskPaths = CreateRiskPaths(text);
        ApplyFilters(selectedEventId);
    }

    private void SetFilter(
        ref ActivityFilterOption field,
        ActivityFilterOption value,
        string propertyName)
    {
        ArgumentNullException.ThrowIfNull(value);
        if (Set(ref field, value, propertyName))
        {
            ApplyFilters(preserveSelectedEventId: null);
        }
    }

    private void ReplaceSelection(
        ref ActivityFilterOption field,
        IReadOnlyList<ActivityFilterOption> options,
        string selectedId,
        string propertyName)
    {
        field = options.FirstOrDefault(item => item.Id == selectedId) ?? options[0];
        Raise(propertyName);
    }

    private void ApplyFilters(string? preserveSelectedEventId)
    {
        var visible = _history
            .Where(item => SelectedActionFilter.Id == "all" || item.ActionId == SelectedActionFilter.Id)
            .Where(item => SelectedTaskFilter.Id == "all" || item.TaskId == SelectedTaskFilter.Id)
            .Where(item => SelectedSourceFilter.Id == "all" || item.SourceId == SelectedSourceFilter.Id)
            .Where(MatchesSearch)
            .OrderByDescending(item => item.ObservedAt)
            .Select(Render)
            .ToArray();
        VisibleEvents = visible;
        ResultLabel = UiLanguageService.Shared.Format("FileResultFormat", visible.Length, _history.Count);
        SelectedEvent = preserveSelectedEventId is null
            ? visible.FirstOrDefault()
            : visible.FirstOrDefault(item => item.EventId == preserveSelectedEventId) ?? visible.FirstOrDefault();
        if (SelectedEvent is null)
        {
            SynchronizeSelection();
        }
    }

    private bool MatchesSearch(RawFileActivity item)
    {
        if (string.IsNullOrWhiteSpace(SearchText))
        {
            return true;
        }

        return item.RelativePath.Contains(SearchText, StringComparison.OrdinalIgnoreCase) ||
            item.TaskId.Contains(SearchText, StringComparison.OrdinalIgnoreCase) ||
            UiLanguageService.Shared[item.AgentKey].Contains(SearchText, StringComparison.CurrentCultureIgnoreCase);
    }

    private void SynchronizeSelection()
    {
        if (SelectedEvent is null)
        {
            SelectedDetail = null;
            return;
        }

        var raw = _history.Single(item => item.EventId == SelectedEvent.EventId);
        var text = UiLanguageService.Shared;
        SelectedDetail = new FileActivityDetail(
            raw.EventId,
            raw.IsInScope ? Path.GetFileName(raw.RelativePath) : text["FileBlockedPathPlaceholder"],
            text[ActionKey(raw.ActionId)],
            raw.IsInScope ? raw.RelativePath : text["FileBlockedPathPlaceholder"],
            raw.SizeLabel,
            raw.TypeLabel,
            raw.ObservedAt.ToString(
                "dd MMM yyyy HH:mm:ss",
                CultureInfo.GetCultureInfo(text.IsThai ? "th-TH" : "en-US")),
            text[raw.AgentKey],
            raw.TaskId,
            $"{raw.Confidence}%",
            text[SourceKey(raw.SourceId)],
            ActionBrushKey(raw.ActionId),
            raw.DiffLines
                .Select(line => line.StartsWith("@loc:", StringComparison.Ordinal)
                    ? text[line[5..]]
                    : line)
                .ToArray());
    }

    private static FileActivityRow Render(RawFileActivity item)
    {
        var text = UiLanguageService.Shared;
        return new FileActivityRow(
            item.EventId,
            item.ObservedAt.ToString("HH:mm:ss", CultureInfo.InvariantCulture),
            item.Initials,
            text[item.AgentKey],
            text[ActionKey(item.ActionId)],
            item.IsInScope ? item.RelativePath : text["FileBlockedPathPlaceholder"],
            item.TaskId,
            $"{item.Confidence}%",
            text[SourceKey(item.SourceId)],
            ActionBrushKey(item.ActionId),
            item.IsInScope ? text["FileScopeAuthorized"] : text["FileScopeBlocked"],
            item.IsInScope ? OverviewBrushKeys.Working : OverviewBrushKeys.Blocked);
    }

    private static IReadOnlyList<FileActivitySummaryCard> CreateSummaryCards(UiLanguageService text) =>
    [
        new("read", text["FileSummaryRead"], "5,842", text["FileSummaryReadTrend"], "\uE736", OverviewBrushKeys.Primary),
        new("modified", text["FileSummaryModified"], "1,243", text["FileSummaryModifiedTrend"], "\uE70F", OverviewBrushKeys.Working),
        new("created", text["FileSummaryCreated"], "678", text["FileSummaryCreatedTrend"], "\uE8B7", OverviewBrushKeys.Review),
        new("deleted", text["FileSummaryDeleted"], "129", text["FileSummaryDeletedTrend"], "\uE74D", OverviewBrushKeys.Blocked),
        new("blocked", text["FileSummarySuspicious"], "23", text["FileSummarySuspiciousTrend"], "\uE7BA", OverviewBrushKeys.Idle),
    ];

    private static string ActionKey(string actionId) => actionId switch
    {
        "read" => "FileActionRead",
        "created" => "FileActionCreated",
        "deleted" => "FileActionDeleted",
        "blocked" => "FileActionBlocked",
        _ => "FileActionModified",
    };

    private static string SourceKey(string sourceId) => sourceId switch
    {
        "git" => "FileSourceGit",
        "agent" => "FileSourceAgentReport",
        _ => "FileSourceWatcher",
    };

    private static string ActionBrushKey(string actionId) => actionId switch
    {
        "created" => OverviewBrushKeys.Review,
        "deleted" or "blocked" => OverviewBrushKeys.Blocked,
        "modified" => OverviewBrushKeys.Working,
        _ => OverviewBrushKeys.Primary,
    };

    private static IReadOnlyList<RawFileActivity> CreateFixture() =>
    [
        Item("FILE-001", 14, 31, 22, "PM", "FileAgentProjectManager", "modified", "src/app/auth/service.cs", "TASK-115", 92, "git", true, "12.45 KB", "C#", ["@@ -42,7 +42,11 @@", "- return AuthResult.Failed();", "+ if (user.IsActive)", "+     return AuthResult.Success();"]),
        Item("FILE-002", 14, 29, 47, "BW", "FileAgentBackendWorker", "created", "tests/auth/AuthServiceTests.cs", "TASK-115", 89, "filesystem", true, "4.20 KB", "C#", ["+ [TestMethod]", "+ public void DisabledUserIsRejected()"]),
        Item("FILE-003", 14, 29, 3, "PM", "FileAgentProjectManager", "read", "docs/API_Design.md", "TASK-118", 100, "agent", true, "18.10 KB", "Markdown", ["@loc:FileDiffReadNotRetained"]),
        Item("FILE-004", 14, 28, 19, "TW", "FileAgentTestWorker", "modified", "src/app/controllers/UserController.cs", "TASK-115", 90, "git", true, "9.82 KB", "C#", ["@@ -18,3 +18,4 @@", "+ ValidateRequest(request);"]),
        Item("FILE-005", 14, 27, 55, "BW", "FileAgentBackendWorker", "deleted", "logs/debug_old.log", "TASK-120", 95, "filesystem", true, "0 B", "Log", ["@loc:FileDiffDeletedNotRetained"]),
        Item("FILE-006", 14, 27, 12, "TW", "FileAgentTestWorker", "blocked", "[blocked]", "TASK-120", 38, "filesystem", false, "—", "—", ["@loc:FileDiffBlockedWithheld"]),
        Item("FILE-007", 14, 26, 41, "PS", "FileAgentProjectSecretary", "created", "scripts/deploy.ps1", "PROJECT", 87, "git", true, "3.50 KB", "PowerShell", ["+ param([string] $Environment)"]),
        Item("FILE-008", 14, 26, 5, "DW", "FileAgentDevOpsWorker", "modified", ".github/workflows/ci.yml", "PROJECT", 90, "git", true, "5.16 KB", "YAML", ["+ timeout-minutes: 20"]),
        Item("FILE-009", 14, 25, 39, "BW", "FileAgentBackendWorker", "modified", "src/app/config/appsettings.json", "TASK-115", 91, "filesystem", true, "2.14 KB", "JSON", ["- \"retry\": 2", "+ \"retry\": 3"]),
        Item("FILE-010", 14, 25, 2, "PM", "FileAgentProjectManager", "read", "README.md", "PROJECT", 100, "agent", true, "7.80 KB", "Markdown", ["@loc:FileDiffReadNotRetained"]),
    ];

    private static RawFileActivity Item(
        string eventId,
        int hour,
        int minute,
        int second,
        string initials,
        string agentKey,
        string actionId,
        string relativePath,
        string taskId,
        int confidence,
        string sourceId,
        bool isInScope,
        string sizeLabel,
        string typeLabel,
        IReadOnlyList<string> diffLines) =>
        new(
            eventId,
            new DateTimeOffset(2026, 8, 15, hour, minute, second, TimeSpan.FromHours(7)),
            initials,
            agentKey,
            actionId,
            relativePath,
            taskId,
            confidence,
            sourceId,
            isInScope,
            sizeLabel,
            typeLabel,
            diffLines);

    private static IReadOnlyList<FileActivityChartPoint> CreateActivityOverTime() =>
    [
        new("00", 24, OverviewBrushKeys.Primary), new("04", 46, OverviewBrushKeys.Primary),
        new("08", 58, OverviewBrushKeys.Primary), new("12", 82, OverviewBrushKeys.Primary),
        new("16", 70, OverviewBrushKeys.Primary), new("20", 42, OverviewBrushKeys.Primary),
        new("22", 29, OverviewBrushKeys.Primary),
    ];

    private static IReadOnlyList<FileActivityChartPoint> CreateFileTypeActivity() =>
    [
        new(".cs", 100, OverviewBrushKeys.Primary), new(".json", 67, OverviewBrushKeys.Primary),
        new(".md", 42, OverviewBrushKeys.Primary), new(".yml", 31, OverviewBrushKeys.Primary),
        new(".ps1", 22, OverviewBrushKeys.Primary),
    ];

    private static IReadOnlyList<FileActivityRiskPath> CreateRiskPaths(UiLanguageService text) =>
    [
        new(text["FileBlockedPathPlaceholder"], text["FileRiskOutOfScope"], "18", "+45%", OverviewBrushKeys.Blocked),
        new("AppData/Roaming", text["FileRiskOutOfScope"], "12", "+33%", OverviewBrushKeys.Blocked),
        new("Program Files", text["FileRiskHigh"], "9", "+29%", OverviewBrushKeys.Idle),
    ];

    private sealed record RawFileActivity(
        string EventId,
        DateTimeOffset ObservedAt,
        string Initials,
        string AgentKey,
        string ActionId,
        string RelativePath,
        string TaskId,
        int Confidence,
        string SourceId,
        bool IsInScope,
        string SizeLabel,
        string TypeLabel,
        IReadOnlyList<string> DiffLines);
}
