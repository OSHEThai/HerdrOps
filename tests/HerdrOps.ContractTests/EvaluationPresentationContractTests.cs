using System.Security.Cryptography;
using System.Text.RegularExpressions;

namespace HerdrOps.ContractTests;

[TestClass]
public sealed class EvaluationPresentationContractTests
{
    private const string ApprovedReferenceSha256 =
        "7721C24EE49887286854D07132BBFE12C52B028AAE50CE7EB8062F0877C2B23D";

    [TestMethod]
    public void ViewPreservesApprovedHierarchyAndAccessibleTextEquivalents()
    {
        var xaml = ReadRepositoryFile("src", "HerdrOps.App", "Views", "EvaluationView.xaml");
        foreach (var region in new[]
                 {
                     "EvaluationEvidenceBoundary",
                     "EvaluationSummaryRegion",
                     "EvaluationDistributionRegion",
                     "EvaluationTrendRegion",
                     "EvaluationDimensionRegion",
                     "EvaluationComparisonRegion",
                     "EvaluationTopAgentsRegion",
                     "EvaluationLowAgentsRegion",
                 })
        {
            StringAssert.Contains(xaml, $"x:Name=\"{region}\"");
        }

        foreach (var binding in new[]
                 {
                     "LeaderScoreLabel",
                     "LeaderProvenanceId",
                     "LeaderEvidenceIdentitySha256",
                     "ProjectManagerScoreLabel",
                     "ProjectManagerProvenanceId",
                     "ProjectManagerEvidenceIdentitySha256",
                     "ObjectiveEvidenceScoreLabel",
                     "ObjectiveEvidenceProvenanceId",
                     "ObjectiveEvidenceIdentitySha256",
                     "WeightedScoreLabel",
                     "ComparisonSnapshotSha256",
                 })
        {
            StringAssert.Contains(xaml, $"{{Binding {binding}}}");
        }

        StringAssert.Contains(xaml, "EvaluationScoreDistributionChart");
        StringAssert.Contains(xaml, "EvaluationScoreTrendChart");
        StringAssert.Contains(xaml, "automation:AutomationProperties.Name");
        StringAssert.Contains(xaml, "ItemsSource=\"{Binding DistributionBins}\"");
        StringAssert.Contains(xaml, "ItemsSource=\"{Binding TrendPoints}\"");
        StringAssert.Contains(xaml, "ItemsSource=\"{Binding DimensionRows}\"");
        StringAssert.Contains(xaml, "ItemsSource=\"{Binding ComparisonRows}\"");
        Assert.IsFalse(
            Regex.IsMatch(xaml, @"#[0-9A-Fa-f]{6,8}\b", RegexOptions.CultureInvariant),
            "Evaluation must use shared semantic resources instead of page-local colors.");
        Assert.IsFalse(xaml.Contains(" Click=\"", StringComparison.Ordinal));
        Assert.IsFalse(
            Regex.IsMatch(
                xaml,
                @"(?:Text|Content|AutomationProperties\.Name)=""[^""{]*[ก-๙]",
                RegexOptions.CultureInvariant),
            "Evaluation XAML must not hard-code Thai UI copy.");
    }

    [TestMethod]
    public void StateUsesOneSnapshotAndExposesSixDimensionRowsWithMissingAndTieSemantics()
    {
        var state = ReadRepositoryFile("src", "HerdrOps.App", "Evaluation", "EvaluationState.cs");

        StringAssert.Contains(state, "private readonly EvaluationSnapshot _snapshot;");
        StringAssert.Contains(state, "Enum.GetValues<EvaluationDimension>()");
        StringAssert.Contains(state, "EvidenceIdentitySha256");
        StringAssert.Contains(state, "EvaluationDimensionScoreStatus.Missing");
        StringAssert.Contains(state, "EvaluationTieLabel");
        StringAssert.Contains(state, ".ThenBy(item => item.AgentId, StringComparer.Ordinal)");
        StringAssert.Contains(state, ".ThenBy(item => item.EvaluationId, StringComparer.Ordinal)");
        foreach (var prohibited in new[]
                 {
                     "HerdrRuntimeMonitor",
                     "SqliteHerdrStateStore",
                     "NamedPipe",
                     "Process.Start",
                 })
        {
            Assert.IsFalse(
                state.Contains(prohibited, StringComparison.Ordinal),
                $"Synthetic Evaluation presentation acquired runtime authority: {prohibited}");
        }
    }

    [TestMethod]
    public void ApprovedEvaluationReferenceBytesRemainImmutable()
    {
        var path = RepositoryPath("docs", "design", "reference", "09-evaluation.png");
        Assert.IsTrue(File.Exists(path), $"Approved Evaluation reference is missing: {path}");
        Assert.AreEqual(
            ApprovedReferenceSha256,
            Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(path))));
    }

    private static string ReadRepositoryFile(params string[] segments)
    {
        var path = RepositoryPath(segments);
        Assert.IsTrue(File.Exists(path), $"Required Issue #31 file is missing: {path}");
        return File.ReadAllText(path);
    }

    private static string RepositoryPath(params string[] segments) =>
        segments.Aggregate(
            FindRepositoryRoot(),
            static (current, segment) => Path.Combine(current, segment));

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
