using System.Collections.Frozen;
using HerdrOps.Contracts.StateIpc;
using HerdrOps.Domain.Herdr;

namespace HerdrOps.Core;

public static class HerdrSessionStateContractMapper
{
    public static HerdrSessionStateContract ToContract(HerdrSessionState state)
    {
        return HerdrSessionStateContractReducer.NormalizeAndValidate(ToContractUnchecked(state));
    }

    internal static HerdrSessionStateContract ToContractUnchecked(HerdrSessionState state)
    {
        ArgumentNullException.ThrowIfNull(state);
        return new HerdrSessionStateContract(
            state.Version,
            state.Protocol,
            state.ConnectionEpoch,
            state.LastIngestSequence,
            state.Workspaces.Values.Select(ToContract).ToArray(),
            state.Tabs.Values.Select(ToContract).ToArray(),
            state.Panes.Values.Select(ToContract).ToArray(),
            state.Agents.Values.Select(ToContract).ToArray(),
            state.FocusedWorkspaceId,
            state.FocusedTabId,
            state.FocusedPaneId);
    }

    public static HerdrSessionState ToDomain(HerdrSessionStateContract contract)
    {
        contract = HerdrSessionStateContractReducer.NormalizeAndValidate(contract);
        return new HerdrSessionState(
            contract.Version,
            contract.Protocol,
            contract.ConnectionEpoch,
            contract.LastIngestSequence,
            contract.Workspaces.ToFrozenDictionary(
                item => item.WorkspaceId,
                ToDomain,
                StringComparer.Ordinal),
            contract.Tabs.ToFrozenDictionary(
                item => item.TabId,
                ToDomain,
                StringComparer.Ordinal),
            contract.Panes.ToFrozenDictionary(
                item => item.PaneId,
                ToDomain,
                StringComparer.Ordinal),
            contract.Agents.ToFrozenDictionary(
                item => item.TerminalId,
                ToDomain,
                StringComparer.Ordinal),
            contract.FocusedWorkspaceId,
            contract.FocusedTabId,
            contract.FocusedPaneId);
    }

    public static HerdrSessionStateDeltaContract CreateDelta(
        HerdrSessionStateContract current,
        HerdrSessionStateContract next)
    {
        current = HerdrSessionStateContractReducer.NormalizeAndValidate(current);
        next = HerdrSessionStateContractReducer.NormalizeAndValidate(next);
        if (next.LastIngestSequence != current.LastIngestSequence + 1)
        {
            throw new HerdrOpsStateIpcProtocolException(
                $"Cannot create a state delta from sequence {current.LastIngestSequence} to {next.LastIngestSequence}.");
        }

        var currentWorkspaces = current.Workspaces.ToDictionary(item => item.WorkspaceId, StringComparer.Ordinal);
        var currentTabs = current.Tabs.ToDictionary(item => item.TabId, StringComparer.Ordinal);
        var currentPanes = current.Panes.ToDictionary(item => item.PaneId, StringComparer.Ordinal);
        var currentAgents = current.Agents.ToDictionary(item => item.TerminalId, StringComparer.Ordinal);
        var nextWorkspaceIds = next.Workspaces.Select(item => item.WorkspaceId).ToHashSet(StringComparer.Ordinal);
        var nextTabIds = next.Tabs.Select(item => item.TabId).ToHashSet(StringComparer.Ordinal);
        var nextPaneIds = next.Panes.Select(item => item.PaneId).ToHashSet(StringComparer.Ordinal);
        var nextAgentIds = next.Agents.Select(item => item.TerminalId).ToHashSet(StringComparer.Ordinal);

        return new HerdrSessionStateDeltaContract(
            current.LastIngestSequence,
            next.LastIngestSequence,
            next.Version,
            next.Protocol,
            next.ConnectionEpoch,
            Changed(next.Workspaces, currentWorkspaces, item => item.WorkspaceId),
            Removed(currentWorkspaces.Keys, nextWorkspaceIds),
            Changed(next.Tabs, currentTabs, item => item.TabId),
            Removed(currentTabs.Keys, nextTabIds),
            Changed(next.Panes, currentPanes, item => item.PaneId),
            Removed(currentPanes.Keys, nextPaneIds),
            Changed(next.Agents, currentAgents, item => item.TerminalId),
            Removed(currentAgents.Keys, nextAgentIds),
            next.FocusedWorkspaceId,
            next.FocusedTabId,
            next.FocusedPaneId);
    }

    private static IReadOnlyList<T> Changed<T>(
        IReadOnlyList<T> next,
        IReadOnlyDictionary<string, T> current,
        Func<T, string> keySelector)
        where T : notnull =>
        next.Where(item =>
                !current.TryGetValue(keySelector(item), out var existing) ||
                !EqualityComparer<T>.Default.Equals(existing, item))
            .OrderBy(keySelector, StringComparer.Ordinal)
            .ToArray();

    private static IReadOnlyList<string> Removed(
        IEnumerable<string> currentIds,
        IReadOnlySet<string> nextIds) =>
        currentIds.Where(id => !nextIds.Contains(id))
            .Order(StringComparer.Ordinal)
            .ToArray();

    private static HerdrWorkspaceStateContract ToContract(HerdrWorkspaceSnapshot item) => new(
        item.WorkspaceId,
        item.Number,
        item.Label,
        item.Focused,
        item.PaneCount,
        item.TabCount,
        item.ActiveTabId,
        item.AgentStatus.ToString());

    private static HerdrTabStateContract ToContract(HerdrTabSnapshot item) => new(
        item.TabId,
        item.WorkspaceId,
        item.Number,
        item.Label,
        item.Focused,
        item.PaneCount,
        item.AgentStatus.ToString());

    private static HerdrPaneStateContract ToContract(HerdrPaneSnapshot item) => new(
        item.PaneId,
        item.TerminalId,
        item.WorkspaceId,
        item.TabId,
        item.Focused,
        item.AgentStatus.ToString(),
        item.Revision,
        item.Agent,
        item.DisplayAgent,
        item.Title,
        item.CurrentDirectory,
        item.ForegroundCurrentDirectory,
        item.TerminalTitle);

    private static HerdrAgentStateContract ToContract(HerdrAgentSnapshot item) => new(
        item.TerminalId,
        item.WorkspaceId,
        item.TabId,
        item.PaneId,
        item.Focused,
        item.AgentStatus.ToString(),
        item.Revision,
        item.StateChangeSequence,
        item.Agent,
        item.DisplayAgent,
        item.Name,
        item.Title,
        item.CurrentDirectory,
        item.ForegroundCurrentDirectory,
        item.TerminalTitle,
        item.InteractiveReady,
        item.LaunchPending,
        item.ScreenDetectionSkipped);

    private static HerdrWorkspaceSnapshot ToDomain(HerdrWorkspaceStateContract item) => new(
        item.WorkspaceId,
        item.Number,
        item.Label,
        item.Focused,
        item.PaneCount,
        item.TabCount,
        item.ActiveTabId,
        ParseStatus(item.AgentStatus));

    private static HerdrTabSnapshot ToDomain(HerdrTabStateContract item) => new(
        item.TabId,
        item.WorkspaceId,
        item.Number,
        item.Label,
        item.Focused,
        item.PaneCount,
        ParseStatus(item.AgentStatus));

    private static HerdrPaneSnapshot ToDomain(HerdrPaneStateContract item) => new(
        item.PaneId,
        item.TerminalId,
        item.WorkspaceId,
        item.TabId,
        item.Focused,
        ParseStatus(item.AgentStatus),
        item.Revision,
        item.Agent,
        item.DisplayAgent,
        item.Title,
        item.CurrentDirectory,
        item.ForegroundCurrentDirectory,
        item.TerminalTitle);

    private static HerdrAgentSnapshot ToDomain(HerdrAgentStateContract item) => new(
        item.TerminalId,
        item.WorkspaceId,
        item.TabId,
        item.PaneId,
        item.Focused,
        ParseStatus(item.AgentStatus),
        item.Revision,
        item.StateChangeSequence,
        item.Agent,
        item.DisplayAgent,
        item.Name,
        item.Title,
        item.CurrentDirectory,
        item.ForegroundCurrentDirectory,
        item.TerminalTitle,
        item.InteractiveReady,
        item.LaunchPending,
        item.ScreenDetectionSkipped);

    private static HerdrAgentStatus ParseStatus(string value)
    {
        if (!Enum.TryParse<HerdrAgentStatus>(value, ignoreCase: false, out var status) ||
            !Enum.IsDefined(status))
        {
            throw new HerdrOpsStateIpcProtocolException(
                $"Agent status '{value}' is not supported by this executable.");
        }

        return status;
    }
}
