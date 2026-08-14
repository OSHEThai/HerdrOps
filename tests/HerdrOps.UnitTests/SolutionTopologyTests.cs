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
