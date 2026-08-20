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
        var gate = ReadRepositoryFile("tools", "Test-V02LiveRuntimeAcceptance.ps1");
        var protocol = ReadRepositoryFile(
            "docs",
            "protocol",
            "v0.2-core-app-runtime-health-contract.md");
        var decisions = ReadRepositoryFile("Plan", "DECISIONS.md");

        StringAssert.Contains(coreMonitor, "HasAllLiveAgentIdentities");
        StringAssert.Contains(coreEvidence, "AllAgentsHaveLiveIdentity");
        StringAssert.Contains(appEvidence, "HasAllLiveAgentIdentities");
        StringAssert.Contains(gate, "Assert-AllAgentsHaveLiveIdentity");
        StringAssert.Contains(gate, "AllAgentsHaveLiveIdentity");
        StringAssert.Contains(
            gate,
            "Assert-AllAgentsHaveLiveIdentity -Transition $leadingReconciliation");
        StringAssert.Contains(protocol, "This strictness is aggregate and intentional");
        StringAssert.Contains(decisions, "Aggregate identity strictness is intentional");
        StringAssert.Contains(decisions, "unrelated Agentless or `Unknown` Agent");
    }

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
