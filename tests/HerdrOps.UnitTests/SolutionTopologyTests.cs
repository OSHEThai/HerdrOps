using System.Xml.Linq;

namespace HerdrOps.UnitTests;

[TestClass]
public sealed class SolutionTopologyTests
{
    private static readonly IReadOnlyDictionary<string, string[]> ExpectedReferences =
        new Dictionary<string, string[]>(StringComparer.Ordinal)
        {
            ["HerdrOps.App"] = ["HerdrOps.Contracts", "HerdrOps.Domain", "HerdrOps.Infrastructure"],
            ["HerdrOps.Cli"] = ["HerdrOps.Contracts"],
            ["HerdrOps.Contracts"] = [],
            ["HerdrOps.Core"] = ["HerdrOps.Contracts", "HerdrOps.Domain", "HerdrOps.Infrastructure"],
            ["HerdrOps.Domain"] = [],
            ["HerdrOps.Infrastructure"] = ["HerdrOps.Contracts", "HerdrOps.Domain"],
        };

    [TestMethod]
    public void ProductionProjectReferencesMatchApprovedArchitecture()
    {
        var repositoryRoot = FindRepositoryRoot();

        foreach (var (projectName, expectedReferences) in ExpectedReferences)
        {
            var projectPath = Path.Combine(repositoryRoot, "src", projectName, $"{projectName}.csproj");
            Assert.IsTrue(File.Exists(projectPath), $"Missing project: {projectPath}");

            var document = XDocument.Load(projectPath);
            var actualReferences = document
                .Descendants("ProjectReference")
                .Select(reference => Path.GetFileNameWithoutExtension((string?)reference.Attribute("Include")))
                .Where(reference => !string.IsNullOrWhiteSpace(reference))
                .Order(StringComparer.Ordinal)
                .ToArray();

            CollectionAssert.AreEqual(
                expectedReferences.Order(StringComparer.Ordinal).ToArray(),
                actualReferences,
                $"Unexpected project dependency for {projectName}.");
        }
    }

    [TestMethod]
    public void SQLiteProviderIsOwnedOnlyByInfrastructure()
    {
        var repositoryRoot = FindRepositoryRoot();
        var projects = Directory.GetFiles(
            Path.Combine(repositoryRoot, "src"),
            "*.csproj",
            SearchOption.AllDirectories);
        var sqliteOwners = projects
            .Where(project => XDocument.Load(project)
                .Descendants("PackageReference")
                .Any(reference =>
                    ((string?)reference.Attribute("Include"))?.Contains(
                        "Sqlite",
                        StringComparison.OrdinalIgnoreCase) == true))
            .Select(Path.GetFileNameWithoutExtension)
            .Order(StringComparer.Ordinal)
            .ToArray();

        CollectionAssert.AreEqual(
            new[] { "HerdrOps.Infrastructure" },
            sqliteOwners,
            "Only Infrastructure may own the SQLite provider or native bundle.");

        foreach (var projectName in new[] { "HerdrOps.App", "HerdrOps.Cli" })
        {
            var sourceRoot = Path.Combine(repositoryRoot, "src", projectName);
            foreach (var sourcePath in Directory.GetFiles(sourceRoot, "*.cs", SearchOption.AllDirectories))
            {
                var source = File.ReadAllText(sourcePath);
                Assert.IsFalse(
                    source.Contains("Microsoft.Data.Sqlite", StringComparison.Ordinal) ||
                    source.Contains("SqliteConnection", StringComparison.Ordinal),
                    $"{projectName} must use Core IPC instead of direct SQLite access: {sourcePath}");
            }
        }
    }

    [TestMethod]
    public void DashboardProcessDoesNotOwnCoreLifecycle()
    {
        var repositoryRoot = FindRepositoryRoot();
        var appSourceRoot = Path.Combine(repositoryRoot, "src", "HerdrOps.App");
        var forbiddenLifecycleTokens = new[]
        {
            "HerdrOps.Core",
            "Process.Start(",
            ".Kill(",
        };

        foreach (var sourcePath in Directory.GetFiles(appSourceRoot, "*.cs", SearchOption.AllDirectories))
        {
            var source = File.ReadAllText(sourcePath);
            foreach (var token in forbiddenLifecycleTokens)
            {
                Assert.IsFalse(
                    source.Contains(token, StringComparison.Ordinal),
                    $"Dashboard must subscribe to Core state without owning the Core process lifecycle: {sourcePath} contains {token}");
            }
        }
    }

    [TestMethod]
    public void AppOwnsCoreSubscriptionInsteadOfDashboardShell()
    {
        var repositoryRoot = FindRepositoryRoot();
        var appSource = File.ReadAllText(Path.Combine(
            repositoryRoot,
            "src",
            "HerdrOps.App",
            "App.xaml.cs"));
        var appXaml = File.ReadAllText(Path.Combine(
            repositoryRoot,
            "src",
            "HerdrOps.App",
            "App.xaml"));
        var shellSource = File.ReadAllText(Path.Combine(
            repositoryRoot,
            "src",
            "HerdrOps.App",
            "Views",
            "ShellView.xaml.cs"));

        StringAssert.Contains(appSource, "LiveDashboardRuntime");
        StringAssert.Contains(appSource, "new MainWindow(state)");
        Assert.IsFalse(appXaml.Contains("StartupUri", StringComparison.Ordinal));
        Assert.IsFalse(shellSource.Contains("LiveDashboardSession", StringComparison.Ordinal));
        Assert.IsFalse(shellSource.Contains("HerdrOpsStatePipeClient", StringComparison.Ordinal));
    }

    [TestMethod]
    public void NormalModeDeclaresNoHttpServerOrAdministratorRequirement()
    {
        var repositoryRoot = FindRepositoryRoot();
        var sourceRoot = Path.Combine(repositoryRoot, "src");
        var inspectedFiles = Directory.GetFiles(sourceRoot, "*", SearchOption.AllDirectories)
            .Where(path => path.EndsWith(".cs", StringComparison.OrdinalIgnoreCase) ||
                           path.EndsWith(".csproj", StringComparison.OrdinalIgnoreCase) ||
                           path.EndsWith(".manifest", StringComparison.OrdinalIgnoreCase) ||
                           path.EndsWith(".xaml", StringComparison.OrdinalIgnoreCase));
        var forbiddenTokens = new[]
        {
            "HttpListener",
            "Microsoft.AspNetCore.Server.Kestrel",
            "UseKestrel(",
            "UseUrls(",
            "requireAdministrator",
        };

        foreach (var path in inspectedFiles)
        {
            var content = File.ReadAllText(path);
            foreach (var token in forbiddenTokens)
            {
                Assert.IsFalse(
                    content.Contains(token, StringComparison.OrdinalIgnoreCase),
                    $"Normal mode must not declare a localhost HTTP server or Administrator requirement: {path} contains {token}");
            }
        }

        AssertPlanDocumentsPreserveSingleLanguageAndAuthorityInvariants();
    }

    private static void AssertPlanDocumentsPreserveSingleLanguageAndAuthorityInvariants()
    {
        var repositoryRoot = FindRepositoryRoot();
        var designContract = File.ReadAllText(Path.Combine(repositoryRoot, "Plan", "DESIGN-CONTRACT.md"));
        var roadmap = File.ReadAllText(Path.Combine(repositoryRoot, "Plan", "ROADMAP.md"));
        var releaseGates = File.ReadAllText(Path.Combine(repositoryRoot, "Plan", "RELEASE-GATES.md"));
        var architecture = File.ReadAllText(Path.Combine(repositoryRoot, "Plan", "ARCHITECTURE.md"));
        var githubRoadmap = File.ReadAllText(Path.Combine(repositoryRoot, "Plan", "github-roadmap.json"));
        var decisions = File.ReadAllText(Path.Combine(repositoryRoot, "Plan", "DECISIONS.md"));

        foreach (var authorityDocument in new[]
                 {
                     designContract,
                     roadmap,
                     releaseGates,
                     architecture,
                     githubRoadmap,
                     decisions,
                 })
        {
            Assert.IsFalse(
                authorityDocument.Contains("during v0.1 visual implementation", StringComparison.Ordinal),
                "Plan authority documents must not describe the approved and released v0.1 baseline as future implementation work.");
        }

        Assert.IsFalse(
            designContract.Contains("Thai primary labels with English supporting labels", StringComparison.Ordinal),
            "DESIGN-CONTRACT must not permit stacked dual-language labels.");
        StringAssert.Contains(designContract, "Render exactly one selected UI language at a time");

        StringAssert.Contains(architecture, "Status: Approved baseline; v0.2 implementation active");

        StringAssert.Contains(releaseGates, "atomic packaged compatibility, automated reference-host rendering/accessibility coverage");
        StringAssert.Contains(releaseGates, "UI-stall p95 <=50 ms and maximum <=100 ms");
        StringAssert.Contains(releaseGates, "v0.2 release-first v4 authority and gates");
        StringAssert.Contains(releaseGates, "six off-screen viewport configurations");
        StringAssert.Contains(releaseGates, "automated no-soak AB/BA performance/resource checks");
        StringAssert.Contains(releaseGates, "role-distinct independent Agent review");
        StringAssert.Contains(releaseGates, "Do not require or admit soak fields");
        StringAssert.Contains(releaseGates, "Human visual attestation");
        Assert.IsFalse(
            releaseGates.Contains("Until the atomic producer/validator implementation lands", StringComparison.Ordinal),
            "RELEASE-GATES must not retain stale pre-implementation phrasing.");

        StringAssert.Contains(roadmap, "Disconnect/reconnect แล้ว state กลับมาตรงกับ snapshot");
        StringAssert.Contains(roadmap, "Atomic package identity validation");
        StringAssert.Contains(roadmap, "Renderer compatibility และ visual parity");
        StringAssert.Contains(roadmap, "Atomic Thai/English language matrix reports");
        StringAssert.Contains(roadmap, "UI-stall p95 <=50 ms max <=100 ms");

        StringAssert.Contains(githubRoadmap, "Disconnect and reconnect restore state matching snapshot.");
        StringAssert.Contains(githubRoadmap, "Atomic package identity and process-wide SoftwareOnly renderer policy validation pass.");
        StringAssert.Contains(githubRoadmap, "Renderer compatibility and visual parity pass");
        StringAssert.Contains(githubRoadmap, "Atomic Thai/English language matrix reports");
        StringAssert.Contains(githubRoadmap, "UI-stall p95 <=50 ms max <=100 ms");

        StringAssert.Contains(decisions, "D-026 — v0.2 release-first v4 uses agent-collectable automated acceptance");
        StringAssert.Contains(decisions, "D-027 — v0.2 install lifecycle is automated and Agent-reviewed");
        StringAssert.Contains(decisions, "automated performance/resource checks without soak");
        StringAssert.Contains(decisions, "role-distinct Agent review");
        StringAssert.Contains(decisions, "No physical monitor, desktop-DPI, power-source, thermal, Narrator");
        StringAssert.Contains(decisions, "no ProductOwner test action is required");
        StringAssert.Contains(releaseGates, "AutomatedLiveLifecycle");
        StringAssert.Contains(githubRoadmap, "no clean-host certificate or manual observer is required");

        var v02Gate = File.ReadAllText(Path.Combine(root, "tools", "Test-V02ReleaseGate.ps1"));
        StringAssert.Contains(v02Gate, "AutomatedLifecycleReportPath");
        Assert.IsFalse(v02Gate.Contains("CleanHostAuthorizationPath", StringComparison.Ordinal));
        Assert.IsFalse(v02Gate.Contains("CleanHostAcceptanceReceiptPath", StringComparison.Ordinal));
    }

    private static string FindRepositoryRoot()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null)
        {
            if (File.Exists(Path.Combine(directory.FullName, "HerdrOps.sln")))
            {
                return directory.FullName;
            }

            directory = directory.Parent;
        }

        Assert.Fail("Could not locate HerdrOps.sln from the test output directory.");
        return string.Empty;
    }
}
