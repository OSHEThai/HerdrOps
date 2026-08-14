namespace HerdrOps.Contracts.StateIpc;

public static class HerdrSessionStateContractReducer
{
    private static readonly HashSet<string> AllowedAgentStatuses = new(
        ["Unknown", "Idle", "Working", "Blocked", "Done"],
        StringComparer.Ordinal);

    public static HerdrSessionStateContract NormalizeAndValidate(HerdrSessionStateContract state)
    {
        ArgumentNullException.ThrowIfNull(state);
        if (state.ConnectionEpoch < 0 || state.LastIngestSequence < 0)
        {
            throw new HerdrOpsStateIpcProtocolException(
                "State connection epoch and ingest sequence cannot be negative.");
        }

        if (state.LastIngestSequence > 0 &&
            (string.IsNullOrWhiteSpace(state.Version) || state.Protocol <= 0 || state.ConnectionEpoch <= 0))
        {
            throw new HerdrOpsStateIpcProtocolException(
                "A non-empty state requires version, protocol, and connection epoch values.");
        }

        var workspaces = Unique(state.Workspaces, item => item.WorkspaceId, "workspace");
        var tabs = Unique(state.Tabs, item => item.TabId, "tab");
        var panes = Unique(state.Panes, item => item.PaneId, "pane");
        var agents = Unique(state.Agents, item => item.TerminalId, "agent terminal");
        if (state.LastIngestSequence == 0 &&
            (state.ConnectionEpoch != 0 ||
             state.Protocol != 0 ||
             !string.IsNullOrEmpty(state.Version) ||
             workspaces.Count != 0 ||
             tabs.Count != 0 ||
             panes.Count != 0 ||
             agents.Count != 0 ||
             state.FocusedWorkspaceId is not null ||
             state.FocusedTabId is not null ||
             state.FocusedPaneId is not null))
        {
            throw new HerdrOpsStateIpcProtocolException(
                "Sequence-zero state must be the canonical empty state.");
        }

        ValidateReferences(state, workspaces, tabs, panes, agents);
        return state with
        {
            Workspaces = workspaces.Values.OrderBy(item => item.WorkspaceId, StringComparer.Ordinal).ToArray(),
            Tabs = tabs.Values.OrderBy(item => item.TabId, StringComparer.Ordinal).ToArray(),
            Panes = panes.Values.OrderBy(item => item.PaneId, StringComparer.Ordinal).ToArray(),
            Agents = agents.Values.OrderBy(item => item.TerminalId, StringComparer.Ordinal).ToArray(),
        };
    }

    public static HerdrSessionStateContract Apply(
        HerdrSessionStateContract current,
        HerdrSessionStateDeltaContract delta)
    {
        current = NormalizeAndValidate(current);
        ArgumentNullException.ThrowIfNull(delta);
        if (delta.FromSequence != current.LastIngestSequence ||
            delta.ToSequence != delta.FromSequence + 1)
        {
            throw new HerdrOpsStateIpcProtocolException(
                $"State delta sequence {delta.FromSequence}->{delta.ToSequence} does not continue from {current.LastIngestSequence}.");
        }

        if (delta.ConnectionEpoch < current.ConnectionEpoch ||
            delta.ConnectionEpoch > current.ConnectionEpoch + 1 ||
            string.IsNullOrWhiteSpace(delta.Version) ||
            delta.Protocol <= 0)
        {
            throw new HerdrOpsStateIpcProtocolException(
                "The state delta has an invalid version, protocol, or connection epoch.");
        }

        if ((delta.Protocol != current.Protocol ||
             !string.Equals(delta.Version, current.Version, StringComparison.Ordinal)) &&
            delta.ConnectionEpoch == current.ConnectionEpoch)
        {
            throw new HerdrOpsStateIpcProtocolException(
                "A Herdr version or protocol change requires a new connection epoch.");
        }

        var workspaces = current.Workspaces.ToDictionary(item => item.WorkspaceId, StringComparer.Ordinal);
        var tabs = current.Tabs.ToDictionary(item => item.TabId, StringComparer.Ordinal);
        var panes = current.Panes.ToDictionary(item => item.PaneId, StringComparer.Ordinal);
        var agents = current.Agents.ToDictionary(item => item.TerminalId, StringComparer.Ordinal);
        ApplyChanges(workspaces, delta.UpsertedWorkspaces, delta.RemovedWorkspaceIds, item => item.WorkspaceId, "workspace");
        ApplyChanges(tabs, delta.UpsertedTabs, delta.RemovedTabIds, item => item.TabId, "tab");
        ApplyChanges(panes, delta.UpsertedPanes, delta.RemovedPaneIds, item => item.PaneId, "pane");
        ApplyChanges(agents, delta.UpsertedAgents, delta.RemovedAgentTerminalIds, item => item.TerminalId, "agent terminal");

        return NormalizeAndValidate(new HerdrSessionStateContract(
            delta.Version,
            delta.Protocol,
            delta.ConnectionEpoch,
            delta.ToSequence,
            workspaces.Values.ToArray(),
            tabs.Values.ToArray(),
            panes.Values.ToArray(),
            agents.Values.ToArray(),
            delta.FocusedWorkspaceId,
            delta.FocusedTabId,
            delta.FocusedPaneId));
    }

    public static void ValidateSnapshotPayload(HerdrOpsStateSnapshotPayload payload)
    {
        ArgumentNullException.ThrowIfNull(payload);
        var normalized = NormalizeAndValidate(payload.State);
        ValidateHash(payload.StateSha256, HerdrOpsStateIpcJson.ComputeSha256(normalized));
        ValidateRuntimeHealth(payload.RuntimeHealth);
    }

    public static HerdrSessionStateContract ApplyAndValidateDeltaPayload(
        HerdrSessionStateContract current,
        HerdrOpsStateDeltaPayload payload)
    {
        ArgumentNullException.ThrowIfNull(payload);
        var result = Apply(current, payload.Delta);
        ValidateHash(payload.ResultStateSha256, HerdrOpsStateIpcJson.ComputeSha256(result));
        ValidateRuntimeHealth(payload.RuntimeHealth);
        return result;
    }

    public static void ValidateRuntimeHealthPayload(
        HerdrOpsRuntimeHealthPayload payload,
        HerdrSessionStateContract current)
    {
        ArgumentNullException.ThrowIfNull(payload);
        ValidateRuntimeHealth(payload.RuntimeHealth);
        ValidateHash(
            payload.StateSha256,
            HerdrOpsStateIpcJson.ComputeSha256(NormalizeAndValidate(current)));
    }

    public static void ValidateRuntimeHealth(HerdrRuntimeHealthContract health)
    {
        ArgumentNullException.ThrowIfNull(health);
        if (health.Status is not ("Starting" or "Connected" or "Reconnecting" or "Stopped"))
        {
            throw new HerdrOpsStateIpcProtocolException(
                $"Runtime health status '{health.Status}' is unsupported.");
        }

        if (health.LastTransitionUtc.Offset != TimeSpan.Zero ||
            (health.LastAcceptedStateUtc is { } acceptedUtc &&
             acceptedUtc.Offset != TimeSpan.Zero))
        {
            throw new HerdrOpsStateIpcProtocolException(
                "Runtime health timestamps must be UTC.");
        }

        if (health.LastAcceptedStateUtc > health.LastTransitionUtc)
        {
            throw new HerdrOpsStateIpcProtocolException(
                "The last accepted-state timestamp cannot be later than the health transition.");
        }

        if (health.BootstrapCount < 0 ||
            health.EventCount < 0 ||
            health.DisconnectCount < 0 ||
            health.ReconciliationCount < 0)
        {
            throw new HerdrOpsStateIpcProtocolException(
                "Runtime health counters cannot be negative.");
        }

        if (health.Status == "Connected" &&
            (health.BootstrapCount == 0 || health.LastAcceptedStateUtc is null))
        {
            throw new HerdrOpsStateIpcProtocolException(
                "Connected runtime health requires a bootstrap and an accepted-state timestamp.");
        }
    }

    private static void ApplyChanges<T>(
        IDictionary<string, T> current,
        IReadOnlyList<T> upserts,
        IReadOnlyList<string> removals,
        Func<T, string> keySelector,
        string entityName)
    {
        var removalIds = UniqueIds(removals, $"removed {entityName}");
        var upsertValues = Unique(upserts, keySelector, $"upserted {entityName}");
        var overlap = removalIds.FirstOrDefault(upsertValues.ContainsKey);
        if (overlap is not null)
        {
            throw new HerdrOpsStateIpcProtocolException(
                $"State delta both removes and upserts {entityName} '{overlap}'.");
        }

        foreach (var id in removalIds)
        {
            current.Remove(id);
        }

        foreach (var (id, value) in upsertValues)
        {
            current[id] = value;
        }
    }

    private static Dictionary<string, T> Unique<T>(
        IReadOnlyList<T> values,
        Func<T, string> keySelector,
        string entityName)
    {
        ArgumentNullException.ThrowIfNull(values);
        var result = new Dictionary<string, T>(StringComparer.Ordinal);
        foreach (var value in values)
        {
            if (value is null)
            {
                throw new HerdrOpsStateIpcProtocolException(
                    $"The {entityName} collection contains a null item.");
            }

            var id = keySelector(value);
            if (string.IsNullOrWhiteSpace(id) || !result.TryAdd(id, value))
            {
                throw new HerdrOpsStateIpcProtocolException(
                    $"The {entityName} collection contains an empty or duplicate identifier '{id}'.");
            }
        }

        return result;
    }

    private static HashSet<string> UniqueIds(IReadOnlyList<string> values, string entityName)
    {
        ArgumentNullException.ThrowIfNull(values);
        var result = new HashSet<string>(StringComparer.Ordinal);
        foreach (var value in values)
        {
            if (string.IsNullOrWhiteSpace(value) || !result.Add(value))
            {
                throw new HerdrOpsStateIpcProtocolException(
                    $"The {entityName} collection contains an empty or duplicate identifier '{value}'.");
            }
        }

        return result;
    }

    private static void ValidateReferences(
        HerdrSessionStateContract state,
        IReadOnlyDictionary<string, HerdrWorkspaceStateContract> workspaces,
        IReadOnlyDictionary<string, HerdrTabStateContract> tabs,
        IReadOnlyDictionary<string, HerdrPaneStateContract> panes,
        IReadOnlyDictionary<string, HerdrAgentStateContract> agents)
    {
        foreach (var workspace in workspaces.Values)
        {
            ValidateAgentStatus(workspace.AgentStatus, $"workspace '{workspace.WorkspaceId}'");
            if (workspace.Number <= 0 || workspace.PaneCount < 0 || workspace.TabCount < 0)
            {
                throw new HerdrOpsStateIpcProtocolException(
                    $"Workspace '{workspace.WorkspaceId}' has invalid numeric metadata.");
            }

            var tabCount = tabs.Values.Count(tab => Equal(tab.WorkspaceId, workspace.WorkspaceId));
            var paneCount = panes.Values.Count(pane => Equal(pane.WorkspaceId, workspace.WorkspaceId));
            if (workspace.TabCount != tabCount || workspace.PaneCount != paneCount)
            {
                throw new HerdrOpsStateIpcProtocolException(
                    $"Workspace '{workspace.WorkspaceId}' counts do not match its state collections.");
            }

            if (!string.IsNullOrEmpty(workspace.ActiveTabId) &&
                (!tabs.TryGetValue(workspace.ActiveTabId, out var activeTab) ||
                 !Equal(activeTab.WorkspaceId, workspace.WorkspaceId)))
            {
                throw new HerdrOpsStateIpcProtocolException(
                    $"Workspace '{workspace.WorkspaceId}' references a missing active tab.");
            }
        }

        foreach (var tab in tabs.Values)
        {
            ValidateAgentStatus(tab.AgentStatus, $"tab '{tab.TabId}'");
            if (tab.Number <= 0 || tab.PaneCount < 0)
            {
                throw new HerdrOpsStateIpcProtocolException(
                    $"Tab '{tab.TabId}' has invalid numeric metadata.");
            }

            if (!workspaces.ContainsKey(tab.WorkspaceId) ||
                tab.PaneCount != panes.Values.Count(pane => Equal(pane.TabId, tab.TabId)))
            {
                throw new HerdrOpsStateIpcProtocolException(
                    $"Tab '{tab.TabId}' has inconsistent workspace or pane references.");
            }
        }

        foreach (var pane in panes.Values)
        {
            ValidateAgentStatus(pane.AgentStatus, $"pane '{pane.PaneId}'");
            if (!workspaces.ContainsKey(pane.WorkspaceId) ||
                !tabs.TryGetValue(pane.TabId, out var tab) ||
                !Equal(tab.WorkspaceId, pane.WorkspaceId))
            {
                throw new HerdrOpsStateIpcProtocolException(
                    $"Pane '{pane.PaneId}' has inconsistent workspace or tab references.");
            }
        }

        foreach (var agent in agents.Values)
        {
            ValidateAgentStatus(agent.AgentStatus, $"agent terminal '{agent.TerminalId}'");
            if (!workspaces.ContainsKey(agent.WorkspaceId) ||
                !tabs.TryGetValue(agent.TabId, out var tab) ||
                !panes.TryGetValue(agent.PaneId, out var pane) ||
                !Equal(tab.WorkspaceId, agent.WorkspaceId) ||
                !Equal(pane.WorkspaceId, agent.WorkspaceId) ||
                !Equal(pane.TabId, agent.TabId) ||
                !Equal(pane.TerminalId, agent.TerminalId))
            {
                throw new HerdrOpsStateIpcProtocolException(
                    $"Agent terminal '{agent.TerminalId}' has inconsistent state references.");
            }
        }

        ValidateFocus(state.FocusedWorkspaceId, workspaces, "workspace");
        ValidateFocus(state.FocusedTabId, tabs, "tab");
        ValidateFocus(state.FocusedPaneId, panes, "pane");
        if (state.FocusedTabId is not null &&
            (!tabs.TryGetValue(state.FocusedTabId, out var focusedTab) ||
             !Equal(focusedTab.WorkspaceId, state.FocusedWorkspaceId)))
        {
            throw new HerdrOpsStateIpcProtocolException(
                "The focused tab does not belong to the focused workspace.");
        }

        if (state.FocusedPaneId is not null &&
            (!panes.TryGetValue(state.FocusedPaneId, out var focusedPane) ||
             !Equal(focusedPane.WorkspaceId, state.FocusedWorkspaceId) ||
             !Equal(focusedPane.TabId, state.FocusedTabId)))
        {
            throw new HerdrOpsStateIpcProtocolException(
                "The focused pane does not belong to the focused workspace and tab.");
        }

        if (state.FocusedWorkspaceId is not null &&
            state.FocusedTabId is not null &&
            workspaces.TryGetValue(state.FocusedWorkspaceId, out var focusedWorkspace) &&
            !Equal(focusedWorkspace.ActiveTabId, state.FocusedTabId))
        {
            throw new HerdrOpsStateIpcProtocolException(
                "The focused workspace active tab does not match the focused tab.");
        }

        foreach (var workspace in workspaces.Values)
        {
            if (workspace.Focused != Equal(workspace.WorkspaceId, state.FocusedWorkspaceId))
            {
                throw new HerdrOpsStateIpcProtocolException(
                    $"Workspace '{workspace.WorkspaceId}' has an inconsistent focus flag.");
            }
        }

        foreach (var tab in tabs.Values)
        {
            if (tab.Focused != Equal(tab.TabId, state.FocusedTabId))
            {
                throw new HerdrOpsStateIpcProtocolException(
                    $"Tab '{tab.TabId}' has an inconsistent focus flag.");
            }
        }

        foreach (var pane in panes.Values)
        {
            if (pane.Focused != Equal(pane.PaneId, state.FocusedPaneId))
            {
                throw new HerdrOpsStateIpcProtocolException(
                    $"Pane '{pane.PaneId}' has an inconsistent focus flag.");
            }
        }

        foreach (var agent in agents.Values)
        {
            if (agent.Focused != Equal(agent.PaneId, state.FocusedPaneId))
            {
                throw new HerdrOpsStateIpcProtocolException(
                    $"Agent terminal '{agent.TerminalId}' has an inconsistent focus flag.");
            }
        }
    }

    private static void ValidateFocus<T>(
        string? focusedId,
        IReadOnlyDictionary<string, T> values,
        string entityName)
    {
        if (focusedId is not null && !values.ContainsKey(focusedId))
        {
            throw new HerdrOpsStateIpcProtocolException(
                $"The focused {entityName} '{focusedId}' is absent from state.");
        }
    }

    private static void ValidateHash(string supplied, string actual)
    {
        if (string.IsNullOrEmpty(supplied) ||
            supplied.Length != 64 ||
            !string.Equals(supplied, actual, StringComparison.Ordinal))
        {
            throw new HerdrOpsStateIpcProtocolException(
                "The state payload SHA-256 does not match its normalized content.");
        }
    }

    private static void ValidateAgentStatus(string status, string entity)
    {
        if (!AllowedAgentStatuses.Contains(status))
        {
            throw new HerdrOpsStateIpcProtocolException(
                $"The {entity} uses unsupported agent status '{status}'.");
        }
    }

    private static bool Equal(string? first, string? second) =>
        string.Equals(first, second, StringComparison.Ordinal);
}
