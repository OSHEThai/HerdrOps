namespace HerdrOps.Domain.Herdr;

public sealed record HerdrWorkspaceSnapshot(
    string WorkspaceId,
    int Number,
    string Label,
    bool Focused,
    int PaneCount,
    int TabCount,
    string ActiveTabId,
    HerdrAgentStatus AgentStatus);

public sealed record HerdrTabSnapshot(
    string TabId,
    string WorkspaceId,
    int Number,
    string Label,
    bool Focused,
    int PaneCount,
    HerdrAgentStatus AgentStatus);

public sealed record HerdrPaneSnapshot(
    string PaneId,
    string TerminalId,
    string WorkspaceId,
    string TabId,
    bool Focused,
    HerdrAgentStatus AgentStatus,
    ulong Revision,
    string? Agent,
    string? DisplayAgent,
    string? Title,
    string? CurrentDirectory,
    string? ForegroundCurrentDirectory,
    string? TerminalTitle);

public sealed record HerdrAgentSnapshot(
    string TerminalId,
    string WorkspaceId,
    string TabId,
    string PaneId,
    bool Focused,
    HerdrAgentStatus AgentStatus,
    ulong Revision,
    ulong StateChangeSequence,
    string? Agent,
    string? DisplayAgent,
    string? Name,
    string? Title,
    string? CurrentDirectory,
    string? ForegroundCurrentDirectory,
    string? TerminalTitle,
    bool? InteractiveReady,
    bool? LaunchPending,
    bool? ScreenDetectionSkipped);

public sealed record HerdrSessionSnapshot(
    string Version,
    int Protocol,
    IReadOnlyList<HerdrWorkspaceSnapshot> Workspaces,
    IReadOnlyList<HerdrTabSnapshot> Tabs,
    IReadOnlyList<HerdrPaneSnapshot> Panes,
    IReadOnlyList<HerdrAgentSnapshot> Agents,
    string? FocusedWorkspaceId,
    string? FocusedTabId,
    string? FocusedPaneId);
