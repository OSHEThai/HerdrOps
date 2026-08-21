namespace HerdrOps.Contracts.StateIpc;

public static class HerdrAgentIdentityContract
{
    public static bool HasLiveAgentIdentity(HerdrAgentStateContract agent)
    {
        ArgumentNullException.ThrowIfNull(agent);
        return HasValue(agent.Agent) &&
               HasValue(agent.Name) &&
               IsLiveStatus(agent.AgentStatus);
    }

    public static bool HasAllLiveAgentIdentities(HerdrSessionStateContract state)
    {
        ArgumentNullException.ThrowIfNull(state);

        if (state.Panes is null ||
            state.Agents is null ||
            state.Panes.Count == 0 ||
            state.Panes.Count != state.Agents.Count)
        {
            return false;
        }

        var panesById = new Dictionary<string, HerdrPaneStateContract>(StringComparer.Ordinal);
        var panesByTerminalId = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var pane in state.Panes)
        {
            if (pane is null ||
                !HasValue(pane.PaneId) ||
                !HasValue(pane.TerminalId) ||
                !HasValue(pane.WorkspaceId) ||
                !HasValue(pane.TabId) ||
                !HasValue(pane.Agent) ||
                !IsLiveStatus(pane.AgentStatus) ||
                !panesById.TryAdd(pane.PaneId, pane) ||
                !panesByTerminalId.TryAdd(pane.TerminalId, pane.PaneId))
            {
                return false;
            }
        }

        var agentsByTerminalId = new Dictionary<string, HerdrAgentStateContract>(StringComparer.Ordinal);
        var agentsByPaneId = new Dictionary<string, HerdrAgentStateContract>(StringComparer.Ordinal);
        foreach (var agent in state.Agents)
        {
            if (agent is null ||
                !HasValue(agent.TerminalId) ||
                !HasValue(agent.PaneId) ||
                !HasValue(agent.WorkspaceId) ||
                !HasValue(agent.TabId) ||
                !HasLiveAgentIdentity(agent) ||
                !agentsByTerminalId.TryAdd(agent.TerminalId, agent) ||
                !agentsByPaneId.TryAdd(agent.PaneId, agent) ||
                !panesById.TryGetValue(agent.PaneId, out var pane) ||
                !string.Equals(pane.TerminalId, agent.TerminalId, StringComparison.Ordinal) ||
                !string.Equals(pane.WorkspaceId, agent.WorkspaceId, StringComparison.Ordinal) ||
                !string.Equals(pane.TabId, agent.TabId, StringComparison.Ordinal) ||
                !string.Equals(pane.Agent, agent.Agent, StringComparison.Ordinal) ||
                !string.Equals(pane.AgentStatus, agent.AgentStatus, StringComparison.Ordinal))
            {
                return false;
            }
        }

        return panesById.Keys.All(agentsByPaneId.ContainsKey) &&
               agentsByPaneId.Keys.All(panesById.ContainsKey);
    }

    private static bool HasValue(string? value) => !string.IsNullOrWhiteSpace(value);

    private static bool IsLiveStatus(string? status) => status is
        "Idle" or
        "Working" or
        "Blocked" or
        "Done";
}
