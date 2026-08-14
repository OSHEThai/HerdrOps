using System.Collections.Frozen;

namespace HerdrOps.Domain.Herdr;

public sealed record HerdrSessionState(
    string Version,
    int Protocol,
    long ConnectionEpoch,
    long LastIngestSequence,
    IReadOnlyDictionary<string, HerdrWorkspaceSnapshot> Workspaces,
    IReadOnlyDictionary<string, HerdrTabSnapshot> Tabs,
    IReadOnlyDictionary<string, HerdrPaneSnapshot> Panes,
    IReadOnlyDictionary<string, HerdrAgentSnapshot> Agents,
    string? FocusedWorkspaceId,
    string? FocusedTabId,
    string? FocusedPaneId)
{
    public static HerdrSessionState Empty { get; } = new(
        string.Empty,
        0,
        0,
        0,
        Array.Empty<KeyValuePair<string, HerdrWorkspaceSnapshot>>()
            .ToFrozenDictionary(StringComparer.Ordinal),
        Array.Empty<KeyValuePair<string, HerdrTabSnapshot>>()
            .ToFrozenDictionary(StringComparer.Ordinal),
        Array.Empty<KeyValuePair<string, HerdrPaneSnapshot>>()
            .ToFrozenDictionary(StringComparer.Ordinal),
        Array.Empty<KeyValuePair<string, HerdrAgentSnapshot>>()
            .ToFrozenDictionary(StringComparer.Ordinal),
        null,
        null,
        null);
}
