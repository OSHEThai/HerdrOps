using HerdrOps.Contracts.StateIpc;

namespace HerdrOps.ContractTests;

[TestClass]
public sealed class V02RuntimeAgentIdentityContractTests
{
    [TestMethod]
    public void AggregateAgentIdentityStrictnessIsDeclaredAcrossCoreAppGateAndDocs()
    {
        var coreMonitor = ReadRepositoryFile("src", "HerdrOps.Core", "HerdrRuntimeMonitor.cs");
        var coreEvidence = ReadRepositoryFile("src", "HerdrOps.Core", "HerdrRuntimeEvidence.cs");
        var appEvidence = ReadRepositoryFile(
            "src",
            "HerdrOps.App",
            "RuntimeEvidence",
            "RuntimeEvidenceRunner.cs");
        var sharedContract = ReadRepositoryFile(
            "src",
            "HerdrOps.Contracts",
            "StateIpc",
            "HerdrAgentIdentityContract.cs");
        var gate = ReadRepositoryFile("tools", "Test-V02LiveRuntimeAcceptance.ps1");
        var protocol = ReadRepositoryFile(
            "docs",
            "protocol",
            "v0.2-core-app-runtime-health-contract.md");
        var decisions = ReadRepositoryFile("Plan", "DECISIONS.md");

        StringAssert.Contains(coreMonitor, "HasAllLiveAgentIdentities");
        StringAssert.Contains(coreEvidence, "AllAgentsHaveLiveIdentity");
        StringAssert.Contains(appEvidence, "HasAllLiveAgentIdentities");
        StringAssert.Contains(coreMonitor, "HerdrAgentIdentityContract.HasAllLiveAgentIdentities");
        StringAssert.Contains(appEvidence, "HerdrAgentIdentityContract.HasAllLiveAgentIdentities");
        StringAssert.Contains(sharedContract, "state.Panes.Count != state.Agents.Count");
        StringAssert.Contains(sharedContract, "agentsByPaneId.TryAdd(agent.PaneId, agent)");
        StringAssert.Contains(gate, "Assert-AllAgentsHaveLiveIdentity");
        StringAssert.Contains(gate, "AllAgentsHaveLiveIdentity");
        StringAssert.Contains(
            gate,
            "Assert-AllAgentsHaveLiveIdentity -Transition $leadingReconciliation");
        StringAssert.Contains(protocol, "This strictness is aggregate and intentional");
        StringAssert.Contains(decisions, "Aggregate identity strictness is intentional");
        StringAssert.Contains(decisions, "unrelated Agentless or `Unknown` Agent");
    }

    [TestMethod]
    public void SharedIdentityContractRejectsMixedAndMismatchedTopology()
    {
        var valid = CreateLiveIdentityState();

        Assert.IsTrue(HerdrAgentIdentityContract.HasAllLiveAgentIdentities(valid));
        Assert.IsFalse(
            HerdrAgentIdentityContract.HasAllLiveAgentIdentities(
                valid with
                {
                    Panes =
                    [
                        valid.Panes[0],
                        valid.Panes[0] with
                        {
                            PaneId = "pane-2",
                            TerminalId = "terminal-2",
                        },
                    ],
                    Agents = [valid.Agents[0]],
                }));
        Assert.IsFalse(
            HerdrAgentIdentityContract.HasAllLiveAgentIdentities(
                valid with
                {
                    Panes =
                    [
                        valid.Panes[0],
                        valid.Panes[0] with
                        {
                            PaneId = "pane-2",
                            TerminalId = "terminal-2",
                        },
                    ],
                    Agents =
                    [
                        valid.Agents[0],
                        valid.Agents[0] with
                        {
                            TerminalId = "terminal-2",
                            PaneId = "pane-2",
                            AgentStatus = "Unknown",
                        },
                    ],
                }));
        Assert.IsFalse(
            HerdrAgentIdentityContract.HasAllLiveAgentIdentities(
                valid with
                {
                    Panes = [valid.Panes[0] with { Agent = null }],
                }));
        Assert.IsFalse(
            HerdrAgentIdentityContract.HasAllLiveAgentIdentities(
                valid with
                {
                    Agents = [valid.Agents[0] with { Agent = " " }],
                }));
        Assert.IsFalse(
            HerdrAgentIdentityContract.HasAllLiveAgentIdentities(
                valid with
                {
                    Agents = [valid.Agents[0] with { Name = " " }],
                }));
        Assert.IsFalse(
            HerdrAgentIdentityContract.HasAllLiveAgentIdentities(
                valid with
                {
                    Agents = [valid.Agents[0] with { Name = null }],
                }));
        Assert.IsFalse(
            HerdrAgentIdentityContract.HasAllLiveAgentIdentities(
                valid with
                {
                    Agents = [valid.Agents[0] with { AgentStatus = "Idle" }],
                }));
        Assert.IsFalse(
            HerdrAgentIdentityContract.HasAllLiveAgentIdentities(
                valid with
                {
                    Agents = [valid.Agents[0] with { PaneId = "orphan-pane" }],
                }));
        Assert.IsFalse(
            HerdrAgentIdentityContract.HasAllLiveAgentIdentities(
                valid with
                {
                    Panes =
                    [
                        valid.Panes[0],
                        valid.Panes[0] with
                        {
                            PaneId = "pane-2",
                            TerminalId = "terminal-1",
                        },
                    ],
                    Agents =
                    [
                        valid.Agents[0],
                        valid.Agents[0] with
                        {
                            TerminalId = "terminal-1",
                            PaneId = "pane-2",
                        },
                    ],
                }));
    }

    private static HerdrSessionStateContract CreateLiveIdentityState() => new(
        "0.8.0-preview",
        19,
        1,
        1,
        [
            new HerdrWorkspaceStateContract(
                "workspace-1",
                1,
                "HerdrOps",
                Focused: true,
                PaneCount: 1,
                TabCount: 1,
                ActiveTabId: "tab-1",
                "Working"),
        ],
        [
            new HerdrTabStateContract(
                "tab-1",
                "workspace-1",
                1,
                "Core",
                Focused: true,
                PaneCount: 1,
                "Working"),
        ],
        [
            new HerdrPaneStateContract(
                "pane-1",
                "terminal-1",
                "workspace-1",
                "tab-1",
                Focused: true,
                "Working",
                1,
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
                "Working",
                1,
                1,
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

    private static string ReadRepositoryFile(params string[] segments)
    {
        var path = segments.Aggregate(
            FindRepositoryRoot(),
            static (current, segment) => Path.Combine(current, segment));
        Assert.IsTrue(File.Exists(path), $"Required v0.2 contract file is missing: {path}");
        return File.ReadAllText(path);
    }

    private static string FindRepositoryRoot()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null)
        {
            if (File.Exists(Path.Combine(directory.FullName, "Plan", "DECISIONS.md")) &&
                File.Exists(Path.Combine(
                    directory.FullName,
                    "src",
                    "HerdrOps.Core",
                    "HerdrRuntimeMonitor.cs")))
            {
                return directory.FullName;
            }

            var gitPath = Path.Combine(directory.FullName, ".git");
            if (File.Exists(gitPath) || Directory.Exists(gitPath))
            {
                return directory.FullName;
            }

            directory = directory.Parent;
        }

        throw new DirectoryNotFoundException("Could not locate the repository root.");
    }
}
