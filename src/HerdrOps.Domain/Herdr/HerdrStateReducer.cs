using System.Collections.Frozen;

namespace HerdrOps.Domain.Herdr;

public sealed class HerdrStateReducer
{
    public HerdrSessionState Reconcile(
        HerdrSessionSnapshot snapshot,
        long connectionEpoch,
        long ingestSequence)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(connectionEpoch);
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(ingestSequence);

        var workspaces = ToUniqueDictionary(
            snapshot.Workspaces,
            item => item.WorkspaceId,
            "workspace");
        var tabs = ToUniqueDictionary(snapshot.Tabs, item => item.TabId, "tab");
        var panes = ToUniqueDictionary(snapshot.Panes, item => item.PaneId, "pane");
        var agents = ToUniqueDictionary(snapshot.Agents, item => item.TerminalId, "agent terminal");

        ValidateReferences(snapshot, workspaces, tabs, panes, agents);

        return new HerdrSessionState(
            snapshot.Version,
            snapshot.Protocol,
            connectionEpoch,
            ingestSequence,
            workspaces.ToFrozenDictionary(StringComparer.Ordinal),
            tabs.ToFrozenDictionary(StringComparer.Ordinal),
            panes.ToFrozenDictionary(StringComparer.Ordinal),
            agents.ToFrozenDictionary(StringComparer.Ordinal),
            snapshot.FocusedWorkspaceId,
            snapshot.FocusedTabId,
            snapshot.FocusedPaneId);
    }

    public HerdrStateApplyResult Apply(
        HerdrSessionState state,
        HerdrStateEvent stateEvent,
        long ingestSequence)
    {
        ArgumentNullException.ThrowIfNull(state);
        ArgumentNullException.ThrowIfNull(stateEvent);
        if (ingestSequence <= state.LastIngestSequence)
        {
            throw new ArgumentOutOfRangeException(
                nameof(ingestSequence),
                "The local ingest sequence must increase monotonically.");
        }

        return stateEvent switch
        {
            HerdrWorkspaceChangedEvent changed => ApplyWorkspaceChanged(state, changed, ingestSequence),
            HerdrWorkspaceCollectionChangedEvent changed => ApplyWorkspaceCollectionChanged(state, changed, ingestSequence),
            HerdrWorkspaceRemovedEvent removed => ApplyWorkspaceRemoved(state, removed, ingestSequence),
            HerdrWorkspaceRenamedEvent renamed => ApplyWorkspaceRenamed(state, renamed, ingestSequence),
            HerdrWorkspaceFocusedEvent focused => ApplyWorkspaceFocused(state, focused, ingestSequence),
            HerdrTabChangedEvent changed => ApplyTabChanged(state, changed, ingestSequence),
            HerdrTabCollectionChangedEvent changed => ApplyTabCollectionChanged(state, changed, ingestSequence),
            HerdrTabRemovedEvent removed => ApplyTabRemoved(state, removed, ingestSequence),
            HerdrTabRenamedEvent renamed => ApplyTabRenamed(state, renamed, ingestSequence),
            HerdrTabFocusedEvent focused => ApplyTabFocused(state, focused, ingestSequence),
            HerdrPaneChangedEvent changed => ApplyPaneChanged(state, changed, ingestSequence),
            HerdrPaneRemovedEvent removed => ApplyPaneRemoved(state, removed, ingestSequence),
            HerdrPaneFocusedEvent focused => ApplyPaneFocused(state, focused, ingestSequence),
            HerdrPaneRevisionChangedEvent changed => ApplyPaneRevisionChanged(state, changed, ingestSequence),
            HerdrPaneAgentStatusChangedEvent changed => ApplyPaneAgentStatusChanged(state, changed, ingestSequence),
            HerdrPaneAgentDetectedEvent detected => ApplyPaneAgentDetected(state, detected, ingestSequence),
            HerdrNoStateChangeEvent => Result(
                state with { LastIngestSequence = ingestSequence },
                HerdrStateApplyDisposition.Ignored),
            HerdrReconciliationRequestedEvent requested => Result(
                state,
                HerdrStateApplyDisposition.ReconciliationRequired,
                requested.Reason),
            _ => Result(
                state,
                HerdrStateApplyDisposition.ReconciliationRequired,
                $"Unsupported state event '{stateEvent.EventName}'."),
        };
    }

    private static HerdrStateApplyResult ApplyWorkspaceChanged(
        HerdrSessionState state,
        HerdrWorkspaceChangedEvent changed,
        long ingestSequence)
    {
        var workspaces = new Dictionary<string, HerdrWorkspaceSnapshot>(state.Workspaces, StringComparer.Ordinal)
        {
            [changed.Workspace.WorkspaceId] = changed.Workspace,
        };
        return Applied(state with
        {
            Workspaces = Freeze(workspaces),
            LastIngestSequence = ingestSequence,
        });
    }

    private static HerdrStateApplyResult ApplyWorkspaceCollectionChanged(
        HerdrSessionState state,
        HerdrWorkspaceCollectionChangedEvent changed,
        long ingestSequence)
    {
        var workspaces = new Dictionary<string, HerdrWorkspaceSnapshot>(state.Workspaces, StringComparer.Ordinal);
        foreach (var workspace in changed.Workspaces)
        {
            workspaces[workspace.WorkspaceId] = workspace;
        }

        return Applied(state with
        {
            Workspaces = Freeze(workspaces),
            LastIngestSequence = ingestSequence,
        });
    }

    private static HerdrStateApplyResult ApplyWorkspaceRemoved(
        HerdrSessionState state,
        HerdrWorkspaceRemovedEvent removed,
        long ingestSequence)
    {
        if (!state.Workspaces.ContainsKey(removed.WorkspaceId))
        {
            return Duplicate(state with { LastIngestSequence = ingestSequence });
        }

        var workspaces = state.Workspaces
            .Where(item => !string.Equals(item.Key, removed.WorkspaceId, StringComparison.Ordinal))
            .ToFrozenDictionary(item => item.Key, item => item.Value, StringComparer.Ordinal);
        var tabs = state.Tabs
            .Where(item => !string.Equals(item.Value.WorkspaceId, removed.WorkspaceId, StringComparison.Ordinal))
            .ToFrozenDictionary(item => item.Key, item => item.Value, StringComparer.Ordinal);
        var panes = state.Panes
            .Where(item => !string.Equals(item.Value.WorkspaceId, removed.WorkspaceId, StringComparison.Ordinal))
            .ToFrozenDictionary(item => item.Key, item => item.Value, StringComparer.Ordinal);
        var agents = state.Agents
            .Where(item => !string.Equals(item.Value.WorkspaceId, removed.WorkspaceId, StringComparison.Ordinal))
            .ToFrozenDictionary(item => item.Key, item => item.Value, StringComparer.Ordinal);

        return Applied(state with
        {
            Workspaces = workspaces,
            Tabs = tabs,
            Panes = panes,
            Agents = agents,
            FocusedWorkspaceId = Equal(state.FocusedWorkspaceId, removed.WorkspaceId) ? null : state.FocusedWorkspaceId,
            FocusedTabId = tabs.ContainsKey(state.FocusedTabId ?? string.Empty) ? state.FocusedTabId : null,
            FocusedPaneId = panes.ContainsKey(state.FocusedPaneId ?? string.Empty) ? state.FocusedPaneId : null,
            LastIngestSequence = ingestSequence,
        });
    }

    private static HerdrStateApplyResult ApplyWorkspaceRenamed(
        HerdrSessionState state,
        HerdrWorkspaceRenamedEvent renamed,
        long ingestSequence)
    {
        if (!state.Workspaces.TryGetValue(renamed.WorkspaceId, out var workspace))
        {
            return Reconcile(state, $"Workspace '{renamed.WorkspaceId}' was renamed before it was known.");
        }

        if (string.Equals(workspace.Label, renamed.Label, StringComparison.Ordinal))
        {
            return Duplicate(state with { LastIngestSequence = ingestSequence });
        }

        return ApplyWorkspaceChanged(
            state,
            new HerdrWorkspaceChangedEvent(renamed.EventName, workspace with { Label = renamed.Label }),
            ingestSequence);
    }

    private static HerdrStateApplyResult ApplyWorkspaceFocused(
        HerdrSessionState state,
        HerdrWorkspaceFocusedEvent focused,
        long ingestSequence)
    {
        if (!state.Workspaces.TryGetValue(focused.WorkspaceId, out var workspace))
        {
            return Reconcile(state, $"Workspace '{focused.WorkspaceId}' was focused before it was known.");
        }

        var activeTabId = string.IsNullOrEmpty(workspace.ActiveTabId)
            ? null
            : workspace.ActiveTabId;
        var preservedPaneId = FindFocusedPaneInTab(state, focused.WorkspaceId, activeTabId);
        return ApplyFocus(
            state,
            focused.WorkspaceId,
            activeTabId,
            preservedPaneId,
            ingestSequence);
    }

    private static HerdrStateApplyResult ApplyTabChanged(
        HerdrSessionState state,
        HerdrTabChangedEvent changed,
        long ingestSequence)
    {
        if (!state.Workspaces.ContainsKey(changed.Tab.WorkspaceId))
        {
            return Reconcile(state, $"Tab '{changed.Tab.TabId}' references an unknown workspace.");
        }

        var tabs = new Dictionary<string, HerdrTabSnapshot>(state.Tabs, StringComparer.Ordinal)
        {
            [changed.Tab.TabId] = changed.Tab,
        };
        return Applied(state with
        {
            Tabs = Freeze(tabs),
            LastIngestSequence = ingestSequence,
        });
    }

    private static HerdrStateApplyResult ApplyTabCollectionChanged(
        HerdrSessionState state,
        HerdrTabCollectionChangedEvent changed,
        long ingestSequence)
    {
        var tabs = new Dictionary<string, HerdrTabSnapshot>(state.Tabs, StringComparer.Ordinal);
        foreach (var tab in changed.Tabs)
        {
            if (!state.Workspaces.ContainsKey(tab.WorkspaceId))
            {
                return Reconcile(state, $"Tab '{tab.TabId}' references an unknown workspace.");
            }

            tabs[tab.TabId] = tab;
        }

        return Applied(state with
        {
            Tabs = Freeze(tabs),
            LastIngestSequence = ingestSequence,
        });
    }

    private static HerdrStateApplyResult ApplyTabRemoved(
        HerdrSessionState state,
        HerdrTabRemovedEvent removed,
        long ingestSequence)
    {
        if (!state.Tabs.TryGetValue(removed.TabId, out var tab))
        {
            return Duplicate(state with { LastIngestSequence = ingestSequence });
        }

        if (!Equal(tab.WorkspaceId, removed.WorkspaceId))
        {
            return Reconcile(state, $"Tab '{removed.TabId}' was closed under a different workspace.");
        }

        var tabs = state.Tabs
            .Where(item => !Equal(item.Key, removed.TabId))
            .ToFrozenDictionary(item => item.Key, item => item.Value, StringComparer.Ordinal);
        var panes = state.Panes
            .Where(item => !Equal(item.Value.TabId, removed.TabId))
            .ToFrozenDictionary(item => item.Key, item => item.Value, StringComparer.Ordinal);
        var agents = state.Agents
            .Where(item => !Equal(item.Value.TabId, removed.TabId))
            .ToFrozenDictionary(item => item.Key, item => item.Value, StringComparer.Ordinal);
        return Applied(state with
        {
            Tabs = tabs,
            Panes = panes,
            Agents = agents,
            FocusedTabId = Equal(state.FocusedTabId, removed.TabId) ? null : state.FocusedTabId,
            FocusedPaneId = panes.ContainsKey(state.FocusedPaneId ?? string.Empty) ? state.FocusedPaneId : null,
            LastIngestSequence = ingestSequence,
        });
    }

    private static HerdrStateApplyResult ApplyTabRenamed(
        HerdrSessionState state,
        HerdrTabRenamedEvent renamed,
        long ingestSequence)
    {
        if (!state.Tabs.TryGetValue(renamed.TabId, out var tab) || !Equal(tab.WorkspaceId, renamed.WorkspaceId))
        {
            return Reconcile(state, $"Tab '{renamed.TabId}' was renamed before it was known in the workspace.");
        }

        if (Equal(tab.Label, renamed.Label))
        {
            return Duplicate(state with { LastIngestSequence = ingestSequence });
        }

        return ApplyTabChanged(
            state,
            new HerdrTabChangedEvent(renamed.EventName, tab with { Label = renamed.Label }),
            ingestSequence);
    }

    private static HerdrStateApplyResult ApplyTabFocused(
        HerdrSessionState state,
        HerdrTabFocusedEvent focused,
        long ingestSequence)
    {
        if (!state.Tabs.TryGetValue(focused.TabId, out var focusedTab) ||
            !Equal(focusedTab.WorkspaceId, focused.WorkspaceId))
        {
            return Reconcile(state, $"Tab '{focused.TabId}' was focused before it was known in the workspace.");
        }

        var preservedPaneId = FindFocusedPaneInTab(state, focused.WorkspaceId, focused.TabId);
        return ApplyFocus(
            state,
            focused.WorkspaceId,
            focused.TabId,
            preservedPaneId,
            ingestSequence);
    }

    private static HerdrStateApplyResult ApplyPaneChanged(
        HerdrSessionState state,
        HerdrPaneChangedEvent changed,
        long ingestSequence)
    {
        var pane = changed.Pane;
        if (!state.Workspaces.ContainsKey(pane.WorkspaceId) ||
            !state.Tabs.TryGetValue(pane.TabId, out var tab) ||
            !Equal(tab.WorkspaceId, pane.WorkspaceId))
        {
            return Reconcile(state, $"Pane '{pane.PaneId}' references an unknown workspace or tab.");
        }

        if (state.Panes.TryGetValue(pane.PaneId, out var current))
        {
            if (pane.Revision < current.Revision)
            {
                return Duplicate(state with { LastIngestSequence = ingestSequence });
            }

            if (pane.Revision == current.Revision)
            {
                if (current == pane)
                {
                    return Duplicate(state with { LastIngestSequence = ingestSequence });
                }

                return Reconcile(
                    state,
                    $"Pane '{pane.PaneId}' changed without advancing revision {pane.Revision}.");
            }

            if (pane.Revision - current.Revision > 1)
            {
                return Reconcile(
                    state,
                    $"Pane '{pane.PaneId}' revision jumped from {current.Revision} to {pane.Revision}.");
            }
        }

        var panes = new Dictionary<string, HerdrPaneSnapshot>(state.Panes, StringComparer.Ordinal)
        {
            [pane.PaneId] = pane,
        };
        var agents = UpdateAgentsFromPane(state.Agents, pane);
        return Applied(state with
        {
            Panes = Freeze(panes),
            Agents = Freeze(agents),
            LastIngestSequence = ingestSequence,
        });
    }

    private static HerdrStateApplyResult ApplyPaneRemoved(
        HerdrSessionState state,
        HerdrPaneRemovedEvent removed,
        long ingestSequence)
    {
        if (!state.Panes.TryGetValue(removed.PaneId, out var pane))
        {
            return Duplicate(state with { LastIngestSequence = ingestSequence });
        }

        if (!Equal(pane.WorkspaceId, removed.WorkspaceId))
        {
            return Reconcile(state, $"Pane '{removed.PaneId}' was closed under a different workspace.");
        }

        var panes = state.Panes
            .Where(item => !Equal(item.Key, removed.PaneId))
            .ToFrozenDictionary(item => item.Key, item => item.Value, StringComparer.Ordinal);
        var agents = state.Agents
            .Where(item => !Equal(item.Value.PaneId, removed.PaneId))
            .ToFrozenDictionary(item => item.Key, item => item.Value, StringComparer.Ordinal);
        return Applied(state with
        {
            Panes = panes,
            Agents = agents,
            FocusedPaneId = Equal(state.FocusedPaneId, removed.PaneId) ? null : state.FocusedPaneId,
            LastIngestSequence = ingestSequence,
        });
    }

    private static HerdrStateApplyResult ApplyPaneFocused(
        HerdrSessionState state,
        HerdrPaneFocusedEvent focused,
        long ingestSequence)
    {
        if (!state.Panes.TryGetValue(focused.PaneId, out var focusedPane) ||
            !Equal(focusedPane.WorkspaceId, focused.WorkspaceId))
        {
            return Reconcile(state, $"Pane '{focused.PaneId}' was focused before it was known in the workspace.");
        }

        return ApplyFocus(
            state,
            focusedPane.WorkspaceId,
            focusedPane.TabId,
            focused.PaneId,
            ingestSequence);
    }

    private static HerdrStateApplyResult ApplyFocus(
        HerdrSessionState state,
        string workspaceId,
        string? tabId,
        string? paneId,
        long ingestSequence)
    {
        var workspaces = state.Workspaces.Values.ToDictionary(
            workspace => workspace.WorkspaceId,
            workspace => workspace with
            {
                Focused = Equal(workspace.WorkspaceId, workspaceId),
                ActiveTabId = Equal(workspace.WorkspaceId, workspaceId) && tabId is not null
                    ? tabId
                    : workspace.ActiveTabId,
            },
            StringComparer.Ordinal);
        var tabs = state.Tabs.Values.ToDictionary(
            tab => tab.TabId,
            tab => tab with { Focused = tabId is not null && Equal(tab.TabId, tabId) },
            StringComparer.Ordinal);
        var panes = state.Panes.Values.ToDictionary(
            pane => pane.PaneId,
            pane => pane with { Focused = paneId is not null && Equal(pane.PaneId, paneId) },
            StringComparer.Ordinal);
        var agents = state.Agents.Values.ToDictionary(
            agent => agent.TerminalId,
            agent => agent with { Focused = paneId is not null && Equal(agent.PaneId, paneId) },
            StringComparer.Ordinal);
        return Applied(state with
        {
            Workspaces = Freeze(workspaces),
            Tabs = Freeze(tabs),
            Panes = Freeze(panes),
            Agents = Freeze(agents),
            FocusedWorkspaceId = workspaceId,
            FocusedTabId = tabId,
            FocusedPaneId = paneId,
            LastIngestSequence = ingestSequence,
        });
    }

    private static string? FindFocusedPaneInTab(
        HerdrSessionState state,
        string workspaceId,
        string? tabId)
    {
        if (tabId is null || state.FocusedPaneId is null)
        {
            return null;
        }

        return state.Panes.TryGetValue(state.FocusedPaneId, out var pane) &&
               Equal(pane.WorkspaceId, workspaceId) &&
               Equal(pane.TabId, tabId)
            ? pane.PaneId
            : null;
    }

    private static HerdrStateApplyResult ApplyPaneRevisionChanged(
        HerdrSessionState state,
        HerdrPaneRevisionChangedEvent changed,
        long ingestSequence)
    {
        if (!state.Panes.TryGetValue(changed.PaneId, out var pane) ||
            !Equal(pane.WorkspaceId, changed.WorkspaceId))
        {
            return Reconcile(state, $"Pane revision arrived for unknown pane '{changed.PaneId}'.");
        }

        var disposition = CompareRevision(pane.Revision, changed.Revision);
        if (disposition == HerdrStateApplyDisposition.Duplicate)
        {
            return Duplicate(state with { LastIngestSequence = ingestSequence });
        }

        if (disposition == HerdrStateApplyDisposition.ReconciliationRequired)
        {
            return Reconcile(
                state,
                $"Pane '{changed.PaneId}' revision jumped from {pane.Revision} to {changed.Revision}.");
        }

        var panes = new Dictionary<string, HerdrPaneSnapshot>(state.Panes, StringComparer.Ordinal)
        {
            [pane.PaneId] = pane with { Revision = changed.Revision },
        };
        return Applied(state with
        {
            Panes = Freeze(panes),
            LastIngestSequence = ingestSequence,
        });
    }

    private static HerdrStateApplyResult ApplyPaneAgentStatusChanged(
        HerdrSessionState state,
        HerdrPaneAgentStatusChangedEvent changed,
        long ingestSequence)
    {
        if (!state.Panes.TryGetValue(changed.PaneId, out var pane) ||
            !Equal(pane.WorkspaceId, changed.WorkspaceId))
        {
            return Reconcile(state, $"Agent status arrived for unknown pane '{changed.PaneId}'.");
        }

        var updatedPane = pane with
        {
            AgentStatus = changed.AgentStatus,
            Agent = changed.Agent ?? pane.Agent,
            DisplayAgent = changed.DisplayAgent ?? pane.DisplayAgent,
            Title = changed.Title ?? pane.Title,
        };
        var panes = new Dictionary<string, HerdrPaneSnapshot>(state.Panes, StringComparer.Ordinal)
        {
            [pane.PaneId] = updatedPane,
        };
        var matchingAgents = state.Agents
            .Where(item => Equal(item.Value.PaneId, pane.PaneId))
            .ToArray();
        if (matchingAgents.Length == 0)
        {
            if (IsAgentFreeUnknownStatus(pane, changed))
            {
                var agentFreeState = state with
                {
                    Panes = Freeze(panes),
                    LastIngestSequence = ingestSequence,
                };
                return updatedPane != pane ? Applied(agentFreeState) : Duplicate(agentFreeState);
            }

            return Reconcile(
                state,
                $"Agent status for pane '{pane.PaneId}' has no matching agent record.");
        }

        var agents = new Dictionary<string, HerdrAgentSnapshot>(state.Agents, StringComparer.Ordinal);
        var changedAnyValue = updatedPane != pane;
        foreach (var item in matchingAgents)
        {
            var updatedAgent = item.Value with
            {
                AgentStatus = changed.AgentStatus,
                Agent = changed.Agent ?? item.Value.Agent,
                DisplayAgent = changed.DisplayAgent ?? item.Value.DisplayAgent,
                Title = changed.Title ?? item.Value.Title,
            };
            agents[item.Key] = updatedAgent;
            changedAnyValue |= updatedAgent != item.Value;
        }

        var nextState = state with
        {
            Panes = Freeze(panes),
            Agents = Freeze(agents),
            LastIngestSequence = ingestSequence,
        };
        return changedAnyValue ? Applied(nextState) : Duplicate(nextState);
    }

    private static HerdrStateApplyResult ApplyPaneAgentDetected(
        HerdrSessionState state,
        HerdrPaneAgentDetectedEvent detected,
        long ingestSequence)
    {
        if (!state.Panes.TryGetValue(detected.PaneId, out var pane) ||
            !Equal(pane.WorkspaceId, detected.WorkspaceId))
        {
            return Reconcile(state, $"Agent detection arrived for unknown pane '{detected.PaneId}'.");
        }

        var matchingAgents = state.Agents.Values
            .Where(agent => Equal(agent.PaneId, pane.PaneId))
            .ToArray();
        var paneHasNoAgent = string.IsNullOrEmpty(pane.Agent) &&
                             string.IsNullOrEmpty(pane.DisplayAgent) &&
                             matchingAgents.Length == 0;
        if (detected.Released == true && paneHasNoAgent)
        {
            return Duplicate(state with { LastIngestSequence = ingestSequence });
        }

        if (detected.Released != true &&
            string.IsNullOrEmpty(detected.Agent) &&
            paneHasNoAgent &&
            detected.FinalStatus is null or HerdrAgentStatus.Unknown)
        {
            return Duplicate(state with { LastIngestSequence = ingestSequence });
        }

        var matchingDetection = detected.Released != true &&
                                !string.IsNullOrEmpty(detected.Agent) &&
                                Equal(pane.Agent, detected.Agent) &&
                                matchingAgents.Length > 0 &&
                                matchingAgents.All(agent => Equal(agent.Agent, detected.Agent)) &&
                                (detected.FinalStatus is null ||
                                 (pane.AgentStatus == detected.FinalStatus &&
                                  matchingAgents.All(agent => agent.AgentStatus == detected.FinalStatus)));
        if (matchingDetection)
        {
            return Duplicate(state with { LastIngestSequence = ingestSequence });
        }

        return Reconcile(
            state,
            $"Agent detection for pane '{detected.PaneId}' is not reflected by the authoritative state.");
    }

    private static bool IsAgentFreeUnknownStatus(
        HerdrPaneSnapshot pane,
        HerdrPaneAgentStatusChangedEvent changed) =>
        changed.AgentStatus == HerdrAgentStatus.Unknown &&
        string.IsNullOrEmpty(changed.Agent) &&
        string.IsNullOrEmpty(changed.DisplayAgent) &&
        string.IsNullOrEmpty(pane.Agent) &&
        string.IsNullOrEmpty(pane.DisplayAgent);

    private static Dictionary<string, HerdrAgentSnapshot> UpdateAgentsFromPane(
        IReadOnlyDictionary<string, HerdrAgentSnapshot> currentAgents,
        HerdrPaneSnapshot pane)
    {
        var agents = new Dictionary<string, HerdrAgentSnapshot>(currentAgents, StringComparer.Ordinal);
        foreach (var item in currentAgents.Where(item => Equal(item.Value.PaneId, pane.PaneId)))
        {
            agents[item.Key] = item.Value with
            {
                WorkspaceId = pane.WorkspaceId,
                TabId = pane.TabId,
                Focused = pane.Focused,
                AgentStatus = pane.AgentStatus,
                Revision = pane.Revision,
                Agent = pane.Agent ?? item.Value.Agent,
                DisplayAgent = pane.DisplayAgent ?? item.Value.DisplayAgent,
                Title = pane.Title ?? item.Value.Title,
                CurrentDirectory = pane.CurrentDirectory ?? item.Value.CurrentDirectory,
                ForegroundCurrentDirectory = pane.ForegroundCurrentDirectory ?? item.Value.ForegroundCurrentDirectory,
                TerminalTitle = pane.TerminalTitle ?? item.Value.TerminalTitle,
            };
        }

        return agents;
    }

    private static HerdrStateApplyDisposition CompareRevision(ulong current, ulong incoming)
    {
        if (incoming <= current)
        {
            return HerdrStateApplyDisposition.Duplicate;
        }

        return incoming - current == 1
            ? HerdrStateApplyDisposition.Applied
            : HerdrStateApplyDisposition.ReconciliationRequired;
    }

    private static void ValidateReferences(
        HerdrSessionSnapshot snapshot,
        IReadOnlyDictionary<string, HerdrWorkspaceSnapshot> workspaces,
        IReadOnlyDictionary<string, HerdrTabSnapshot> tabs,
        IReadOnlyDictionary<string, HerdrPaneSnapshot> panes,
        IReadOnlyDictionary<string, HerdrAgentSnapshot> agents)
    {
        foreach (var workspace in workspaces.Values)
        {
            var actualTabCount = tabs.Values.Count(tab => Equal(tab.WorkspaceId, workspace.WorkspaceId));
            var actualPaneCount = panes.Values.Count(pane => Equal(pane.WorkspaceId, workspace.WorkspaceId));
            if (workspace.TabCount != actualTabCount || workspace.PaneCount != actualPaneCount)
            {
                throw new HerdrStateConsistencyException(
                    $"Workspace '{workspace.WorkspaceId}' counts disagree with the snapshot collections.");
            }

            if (!string.IsNullOrEmpty(workspace.ActiveTabId) &&
                (!tabs.TryGetValue(workspace.ActiveTabId, out var activeTab) ||
                 !Equal(activeTab.WorkspaceId, workspace.WorkspaceId)))
            {
                throw new HerdrStateConsistencyException(
                    $"Workspace '{workspace.WorkspaceId}' references missing active tab '{workspace.ActiveTabId}'.");
            }
        }

        foreach (var tab in tabs.Values)
        {
            if (!workspaces.ContainsKey(tab.WorkspaceId))
            {
                throw new HerdrStateConsistencyException(
                    $"Tab '{tab.TabId}' references missing workspace '{tab.WorkspaceId}'.");
            }

            var actualPaneCount = panes.Values.Count(pane => Equal(pane.TabId, tab.TabId));
            if (tab.PaneCount != actualPaneCount)
            {
                throw new HerdrStateConsistencyException(
                    $"Tab '{tab.TabId}' pane count disagrees with the snapshot collection.");
            }
        }

        foreach (var pane in panes.Values)
        {
            if (!workspaces.ContainsKey(pane.WorkspaceId) ||
                !tabs.TryGetValue(pane.TabId, out var tab) ||
                !Equal(tab.WorkspaceId, pane.WorkspaceId))
            {
                throw new HerdrStateConsistencyException(
                    $"Pane '{pane.PaneId}' has inconsistent workspace or tab references.");
            }
        }

        foreach (var agent in agents.Values)
        {
            if (!workspaces.ContainsKey(agent.WorkspaceId) ||
                !tabs.TryGetValue(agent.TabId, out var tab) ||
                !panes.TryGetValue(agent.PaneId, out var pane) ||
                !Equal(tab.WorkspaceId, agent.WorkspaceId) ||
                !Equal(pane.WorkspaceId, agent.WorkspaceId) ||
                !Equal(pane.TabId, agent.TabId) ||
                !Equal(pane.TerminalId, agent.TerminalId))
            {
                throw new HerdrStateConsistencyException(
                    $"Agent terminal '{agent.TerminalId}' has inconsistent workspace, tab, or pane references.");
            }
        }

        ValidateFocusedId(snapshot.FocusedWorkspaceId, workspaces, "workspace");
        ValidateFocusedId(snapshot.FocusedTabId, tabs, "tab");
        ValidateFocusedId(snapshot.FocusedPaneId, panes, "pane");

        if (snapshot.FocusedTabId is not null &&
            (!tabs.TryGetValue(snapshot.FocusedTabId, out var focusedTab) ||
             !Equal(focusedTab.WorkspaceId, snapshot.FocusedWorkspaceId)))
        {
            throw new HerdrStateConsistencyException(
                "The focused tab does not belong to the focused workspace.");
        }

        if (snapshot.FocusedPaneId is not null &&
            (!panes.TryGetValue(snapshot.FocusedPaneId, out var focusedPane) ||
             !Equal(focusedPane.WorkspaceId, snapshot.FocusedWorkspaceId) ||
             !Equal(focusedPane.TabId, snapshot.FocusedTabId)))
        {
            throw new HerdrStateConsistencyException(
                "The focused pane does not belong to the focused workspace and tab.");
        }

        if (snapshot.FocusedWorkspaceId is not null &&
            snapshot.FocusedTabId is not null &&
            workspaces.TryGetValue(snapshot.FocusedWorkspaceId, out var focusedWorkspace) &&
            !Equal(focusedWorkspace.ActiveTabId, snapshot.FocusedTabId))
        {
            throw new HerdrStateConsistencyException(
                "The focused workspace active tab does not match the focused tab.");
        }

        foreach (var workspace in workspaces.Values)
        {
            if (workspace.Focused != Equal(workspace.WorkspaceId, snapshot.FocusedWorkspaceId))
            {
                throw new HerdrStateConsistencyException(
                    $"Workspace '{workspace.WorkspaceId}' focus flag disagrees with the focused workspace.");
            }
        }

        foreach (var tab in tabs.Values)
        {
            if (tab.Focused != Equal(tab.TabId, snapshot.FocusedTabId))
            {
                throw new HerdrStateConsistencyException(
                    $"Tab '{tab.TabId}' focus flag disagrees with the focused tab.");
            }
        }

        foreach (var pane in panes.Values)
        {
            if (pane.Focused != Equal(pane.PaneId, snapshot.FocusedPaneId))
            {
                throw new HerdrStateConsistencyException(
                    $"Pane '{pane.PaneId}' focus flag disagrees with the focused pane.");
            }
        }

        foreach (var agent in agents.Values)
        {
            if (agent.Focused != Equal(agent.PaneId, snapshot.FocusedPaneId))
            {
                throw new HerdrStateConsistencyException(
                    $"Agent terminal '{agent.TerminalId}' focus flag disagrees with the focused pane.");
            }
        }
    }

    private static void ValidateFocusedId<T>(
        string? focusedId,
        IReadOnlyDictionary<string, T> values,
        string entityName)
    {
        if (!string.IsNullOrEmpty(focusedId) && !values.ContainsKey(focusedId))
        {
            throw new HerdrStateConsistencyException(
                $"Focused {entityName} '{focusedId}' is absent from the snapshot.");
        }
    }

    private static Dictionary<string, T> ToUniqueDictionary<T>(
        IReadOnlyList<T> items,
        Func<T, string> keySelector,
        string entityName)
    {
        var result = new Dictionary<string, T>(StringComparer.Ordinal);
        foreach (var item in items)
        {
            var key = keySelector(item);
            if (string.IsNullOrWhiteSpace(key))
            {
                throw new HerdrStateConsistencyException($"A {entityName} identifier is empty.");
            }

            if (!result.TryAdd(key, item))
            {
                throw new HerdrStateConsistencyException(
                    $"Duplicate {entityName} identifier '{key}' was present in the snapshot.");
            }
        }

        return result;
    }

    private static FrozenDictionary<string, T> Freeze<T>(IDictionary<string, T> values) =>
        values.ToFrozenDictionary(StringComparer.Ordinal);

    private static HerdrStateApplyResult Applied(HerdrSessionState state)
    {
        ValidateLiveState(state);
        return Result(state, HerdrStateApplyDisposition.Applied);
    }

    private static HerdrStateApplyResult Duplicate(HerdrSessionState state) =>
        Result(state, HerdrStateApplyDisposition.Duplicate);

    private static HerdrStateApplyResult Reconcile(HerdrSessionState state, string reason) =>
        Result(state, HerdrStateApplyDisposition.ReconciliationRequired, reason);

    private static HerdrStateApplyResult Result(
        HerdrSessionState state,
        HerdrStateApplyDisposition disposition,
        string? reason = null) => new(state, disposition, reason);

    private static bool Equal(string? first, string? second) =>
        string.Equals(first, second, StringComparison.Ordinal);

    private static void ValidateLiveState(HerdrSessionState state)
    {
        ValidateReferences(
            new HerdrSessionSnapshot(
                state.Version,
                state.Protocol,
                state.Workspaces.Values.ToArray(),
                state.Tabs.Values.ToArray(),
                state.Panes.Values.ToArray(),
                state.Agents.Values.ToArray(),
                state.FocusedWorkspaceId,
                state.FocusedTabId,
                state.FocusedPaneId),
            state.Workspaces,
            state.Tabs,
            state.Panes,
            state.Agents);
    }
}
