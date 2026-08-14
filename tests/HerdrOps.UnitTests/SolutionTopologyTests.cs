using System.Xml.Linq;

namespace HerdrOps.UnitTests;

[TestClass]
public sealed class SolutionTopologyTests
{
    private static readonly IReadOnlyDictionary<string, string[]> ExpectedReferences =
        new Dictionary<string, string[]>(StringComparer.Ordinal)
        {
            ["HerdrOps.App"] = ["HerdrOps.Contracts", "HerdrOps.Domain"],
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
            "HerdrOps.Infrastructure",
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
