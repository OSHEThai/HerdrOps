using System.Security.Cryptography;

namespace HerdrOps.ContractTests;

[TestClass]
public sealed class DesignReferenceIntegrityTests
{
    private static readonly IReadOnlyDictionary<string, string> ExpectedHashes =
        new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["01-overview.png"] = "2D390E965001986EB95E0C395177FC978385C98927B117AB0DE7C1C80266B90B",
            ["02-live-organization.png"] = "21531405D1BF5F8C520F60E98107C464071EB089327D35D34552486AE982C35D",
            ["03-realtime-activity.png"] = "1EFBF8A309665511E6BF330E736D2B4CE96791338DB2101B7723B1A5C987BD0F",
            ["04-delegation-graph.png"] = "61831A14CA46726C1CB5376F61957EA2CBDFAB534F3D681F02561B38CB774AA1",
            ["05-agent-detail.png"] = "6E8E8749ACC3D791CF3719DD0173E75B7BB52FA1ECD3A2319271B41F719CAF84",
            ["06-task-alignment.png"] = "0A9AEBBFB97C23F2A0593248E9FFADFD5F5B4579161ED340496E2BD3B45E832D",
            ["07-file-activity.png"] = "2BFB03357D9FFE4D4C11582D311D45CF2CFCCBD69A63D15130FD1EEBA0537F24",
            ["08-compliance-queue.png"] = "685B54499D36C564A67FD74F81798825470F462FE8D5379D6C1D47E1ABABB45C",
            ["09-evaluation.png"] = "7721C24EE49887286854D07132BBFE12C52B028AAE50CE7EB8062F0877C2B23D",
            ["10-daily-summary.png"] = "A44CAFDFB9A8B34694B67B6AABAD86B8B65A99A8A947C7CAB83C11FE7464F693",
            ["11-widget-concepts.png"] = "6AB57A967BE8C62A436A8F5C6DBB89616B210E66DD34AB851D148B4DCC1A904A",
        };

    [TestMethod]
    public void ApprovedReferenceBytesMatchTheRecordedManifest()
    {
        var repositoryRoot = FindRepositoryRoot();
        var referenceDirectory = Path.Combine(repositoryRoot, "docs", "design", "reference");

        foreach (var (fileName, expectedHash) in ExpectedHashes)
        {
            var path = Path.Combine(referenceDirectory, fileName);
            Assert.IsTrue(File.Exists(path), $"Missing approved design reference: {path}");

            var actualHash = Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(path)));
            Assert.AreEqual(expectedHash, actualHash, $"Approved reference changed: {fileName}");
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

        Assert.Fail("Could not locate HerdrOps.sln from the contract test output directory.");
        return string.Empty;
    }
}
