using HerdrOps.Contracts.StateIpc;

namespace HerdrOps.IntegrationTests;

internal static class HerdrStateTestData
{
    public static readonly DateTimeOffset ObservedUtc =
        new(2026, 8, 14, 10, 0, 0, TimeSpan.Zero);

    public static HerdrSessionStateContract CreateState(
        long sequence,
        string status = "Working",
        ulong revision = 1,
        long connectionEpoch = 1)
    {
        var state = new HerdrSessionStateContract(
            "0.8.0-preview",
            19,
            connectionEpoch,
            sequence,
            [
                new HerdrWorkspaceStateContract(
                    "workspace-1",
                    1,
                    "HerdrOps",
                    Focused: true,
                    PaneCount: 1,
                    TabCount: 1,
                    ActiveTabId: "tab-1",
                    status),
            ],
            [
                new HerdrTabStateContract(
                    "tab-1",
                    "workspace-1",
                    1,
                    "Core",
                    Focused: true,
                    PaneCount: 1,
                    status),
            ],
            [
                new HerdrPaneStateContract(
                    "pane-1",
                    "terminal-1",
                    "workspace-1",
                    "tab-1",
                    Focused: true,
                    status,
                    revision,
                    "codex",
                    "Codex",
                    "Worker",
                    "Z:\\HerdrOps",
                    "Z:\\HerdrOps",
                    "Codex"),
            ],
            [
                new HerdrAgentStateContract(
                    "terminal-1",
                    "workspace-1",
                    "tab-1",
                    "pane-1",
                    Focused: true,
                    status,
                    revision,
                    revision,
                    "codex",
                    "Codex",
                    "Worker 01",
                    "Worker",
                    "Z:\\HerdrOps",
                    "Z:\\HerdrOps",
                    "Codex",
                    InteractiveReady: true,
                    LaunchPending: false,
                    ScreenDetectionSkipped: false),
            ],
            "workspace-1",
            "tab-1",
            "pane-1");
        return HerdrSessionStateContractReducer.NormalizeAndValidate(state);
    }

    public static HerdrOpsStateSnapshotPayload Snapshot(HerdrSessionStateContract state) => new(
        state,
        HerdrOpsStateIpcJson.ComputeSha256(state));

    public static HerdrOpsStateDeltaPayload Delta(
        HerdrSessionStateContract current,
        HerdrSessionStateContract next)
    {
        var delta = HerdrOps.Core.HerdrSessionStateContractMapper.CreateDelta(current, next);
        return new HerdrOpsStateDeltaPayload(delta, HerdrOpsStateIpcJson.ComputeSha256(next));
    }

    public static HerdrOps.Infrastructure.Storage.HerdrStateStoreCommit Commit(
        HerdrSessionStateContract state,
        string payloadJson = "{\"kind\":\"test\"}") => new(
        state,
        ObservedUtc.AddSeconds(state.LastIngestSequence),
        ObservedUtc.AddSeconds(state.LastIngestSequence + 1),
        "IntegrationTest",
        "state-delta",
        Guid.NewGuid(),
        payloadJson);
}

internal sealed class TemporaryDirectory : IDisposable
{
    private readonly string _safeRoot;

    public TemporaryDirectory()
    {
        _safeRoot = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "HerdrOpsTests");
        Path = System.IO.Path.Combine(_safeRoot, Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(Path);
    }

    public string Path { get; }

    public void Dispose()
    {
        var resolved = System.IO.Path.GetFullPath(Path);
        var safeRoot = System.IO.Path.GetFullPath(_safeRoot) + System.IO.Path.DirectorySeparatorChar;
        if (resolved.StartsWith(safeRoot, StringComparison.OrdinalIgnoreCase) && Directory.Exists(resolved))
        {
            Directory.Delete(resolved, recursive: true);
        }
    }
}

internal sealed class FixedTimeProvider(DateTimeOffset utcNow) : TimeProvider
{
    public override DateTimeOffset GetUtcNow() => utcNow;
}
