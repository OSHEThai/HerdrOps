namespace HerdrOps.Domain.Herdr;

public abstract record HerdrStateEvent(string EventName);

public sealed record HerdrWorkspaceChangedEvent(
    string EventName,
    HerdrWorkspaceSnapshot Workspace)
    : HerdrStateEvent(EventName);

public sealed record HerdrWorkspaceCollectionChangedEvent(
    string EventName,
    IReadOnlyList<HerdrWorkspaceSnapshot> Workspaces)
    : HerdrStateEvent(EventName);

public sealed record HerdrWorkspaceRemovedEvent(string EventName, string WorkspaceId)
    : HerdrStateEvent(EventName);

public sealed record HerdrWorkspaceRenamedEvent(
    string EventName,
    string WorkspaceId,
    string Label)
    : HerdrStateEvent(EventName);

public sealed record HerdrWorkspaceFocusedEvent(string EventName, string WorkspaceId)
    : HerdrStateEvent(EventName);

public sealed record HerdrTabChangedEvent(string EventName, HerdrTabSnapshot Tab)
    : HerdrStateEvent(EventName);

public sealed record HerdrTabCollectionChangedEvent(
    string EventName,
    IReadOnlyList<HerdrTabSnapshot> Tabs)
    : HerdrStateEvent(EventName);

public sealed record HerdrTabRemovedEvent(
    string EventName,
    string WorkspaceId,
    string TabId)
    : HerdrStateEvent(EventName);

public sealed record HerdrTabRenamedEvent(
    string EventName,
    string WorkspaceId,
    string TabId,
    string Label)
    : HerdrStateEvent(EventName);

public sealed record HerdrTabFocusedEvent(
    string EventName,
    string WorkspaceId,
    string TabId)
    : HerdrStateEvent(EventName);

public sealed record HerdrPaneChangedEvent(string EventName, HerdrPaneSnapshot Pane)
    : HerdrStateEvent(EventName);

public sealed record HerdrPaneRemovedEvent(
    string EventName,
    string WorkspaceId,
    string PaneId)
    : HerdrStateEvent(EventName);

public sealed record HerdrPaneFocusedEvent(
    string EventName,
    string WorkspaceId,
    string PaneId)
    : HerdrStateEvent(EventName);

public sealed record HerdrPaneRevisionChangedEvent(
    string EventName,
    string WorkspaceId,
    string PaneId,
    ulong Revision)
    : HerdrStateEvent(EventName);

public sealed record HerdrPaneAgentStatusChangedEvent(
    string EventName,
    string WorkspaceId,
    string PaneId,
    HerdrAgentStatus AgentStatus,
    string? Agent,
    string? DisplayAgent,
    string? Title)
    : HerdrStateEvent(EventName);

public sealed record HerdrNoStateChangeEvent(string EventName)
    : HerdrStateEvent(EventName);

public sealed record HerdrReconciliationRequestedEvent(string EventName, string Reason)
    : HerdrStateEvent(EventName);

public enum HerdrStateApplyDisposition
{
    Applied,
    Ignored,
    Duplicate,
    ReconciliationRequired,
}

public sealed record HerdrStateApplyResult(
    HerdrSessionState State,
    HerdrStateApplyDisposition Disposition,
    string? Reason = null);

public sealed class HerdrStateConsistencyException : IOException
{
    public HerdrStateConsistencyException(string message)
        : base(message)
    {
    }
}
