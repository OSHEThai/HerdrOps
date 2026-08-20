using System.Security.Cryptography;
using System.Text.Json;
using HerdrOps.Contracts.StateIpc;
using HerdrOps.Domain.Herdr;

namespace HerdrOps.Core;

internal static class HerdrRuntimeEvidence
{
    public static bool HasAcceptedAgentStatusEvent(
        IEnumerable<HerdrRuntimeTraceTransition> transitions)
    {
        ArgumentNullException.ThrowIfNull(transitions);
        return transitions.Any(transition =>
        {
            if (!string.Equals(
                    transition.AcceptedEventKind,
                    HerdrRuntimeMonitor.AcceptedAgentStatusEventKind,
                    StringComparison.Ordinal) ||
                transition.AcceptedAgentStatusEvent is not { } acceptedEvent)
            {
                return false;
            }

            return acceptedEvent.AgentStatus != HerdrAgentStatus.Unknown &&
                   transition.AllAgentsHaveLiveIdentity &&
                   !string.IsNullOrWhiteSpace(acceptedEvent.Agent) &&
                   !string.IsNullOrWhiteSpace(acceptedEvent.AgentName) &&
                   !string.IsNullOrWhiteSpace(acceptedEvent.TabId);
        });
    }

    public static HerdrRuntimeTraceTransition CreateTransition(
        HerdrRuntimeMonitorSnapshot snapshot)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        var contractState = HerdrSessionStateContractMapper.ToContract(snapshot.State);
        return new HerdrRuntimeTraceTransition(
            snapshot.LastTransitionUtc,
            snapshot.Status,
            snapshot.State.ConnectionEpoch,
            snapshot.BootstrapCount,
            snapshot.EventCount,
            snapshot.DisconnectCount,
            snapshot.ReconciliationCount,
            snapshot.State.LastIngestSequence,
            snapshot.State.Workspaces.Count,
            snapshot.State.Tabs.Count,
            snapshot.State.Panes.Count,
            snapshot.State.Agents.Count,
            HasAllLiveAgentIdentities(snapshot.State),
            ComputeStateFingerprint(snapshot.State),
            HerdrOpsStateIpcJson.ComputeSha256(contractState),
            HerdrOpsStateIpcJson.ComputeAgentTopologySha256(contractState),
            HerdrOpsStateIpcJson.ComputeAgentStatusStateSha256(contractState),
            snapshot.ServerIdentity,
            snapshot.AcceptedEventKind,
            snapshot.LastTransitionReason)
        {
            AcceptedAgentStatusEvent = snapshot.AcceptedAgentStatusEvent,
        };
    }

    private static bool HasAllLiveAgentIdentities(HerdrSessionState state) =>
        state.Agents.Count > 0 && state.Agents.Values.All(agent =>
            !string.IsNullOrWhiteSpace(agent.Agent) &&
            !string.IsNullOrWhiteSpace(agent.Name) &&
            agent.AgentStatus != HerdrAgentStatus.Unknown);

    private static string ComputeStateFingerprint(HerdrSessionState state)
    {
        var canonicalState = new
        {
            state.Version,
            state.Protocol,
            state.FocusedWorkspaceId,
            state.FocusedTabId,
            state.FocusedPaneId,
            Workspaces = state.Workspaces.Values
                .OrderBy(item => item.WorkspaceId, StringComparer.Ordinal)
                .ToArray(),
            Tabs = state.Tabs.Values
                .OrderBy(item => item.TabId, StringComparer.Ordinal)
                .ToArray(),
            Panes = state.Panes.Values
                .OrderBy(item => item.PaneId, StringComparer.Ordinal)
                .ToArray(),
            Agents = state.Agents.Values
                .OrderBy(item => item.TerminalId, StringComparer.Ordinal)
                .ToArray(),
        };
        return Convert.ToHexString(
            SHA256.HashData(JsonSerializer.SerializeToUtf8Bytes(canonicalState)));
    }
}
