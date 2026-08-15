using System.Text.RegularExpressions;

namespace HerdrOps.ContractTests;

[TestClass]
public sealed class ComplianceQueuePresentationContractTests
{
    [TestMethod]
    public void ViewDefinesApprovedHierarchyAndAccessibleReadOnlyActions()
    {
        var xaml = ReadRepositoryFile("src", "HerdrOps.App", "Views", "ComplianceQueueView.xaml");
        var requiredRegions = new[]
        {
            "ComplianceSummaryCardsRegion",
            "ComplianceFiltersRegion",
            "ComplianceIncidentTableRegion",
            "ComplianceQueueFooter",
            "ComplianceDetailsRegion",
            "ComplianceDetailsEvidenceViewport",
            "ComplianceEvidenceRegion",
            "ComplianceActionsRegion",
        };

        foreach (var region in requiredRegions)
        {
            StringAssert.Contains(xaml, $"x:Name=\"{region}\"");
        }

        Assert.IsGreaterThanOrEqualTo(5, Regex.Matches(xaml, "<ComboBox\\b").Count);
        StringAssert.Contains(xaml, "<ListBox");
        StringAssert.Contains(xaml, "<Button");
        StringAssert.Contains(xaml, "Width=\"3.1*\"");
        StringAssert.Contains(xaml, "Width=\"1.2*\"");
        StringAssert.Contains(xaml, "x:Name=\"ComplianceQueueMainColumn\"");
        StringAssert.Contains(xaml, "x:Name=\"ComplianceQueueDetailColumn\"");
        StringAssert.Contains(xaml, "x:Name=\"ComplianceDetailsEvidenceViewport\"");
        StringAssert.Contains(xaml, "ToolTipService.ShowOnDisabled=\"True\"");
        StringAssert.Contains(xaml, "AutomationProperties.HelpText=\"{Binding UnavailableReason}\"");
        Assert.IsFalse(xaml.Contains(" Click=\"", StringComparison.Ordinal));
        var commands = Regex.Matches(xaml, @"\bCommand\s*=\s*""([^""]+)""", RegexOptions.CultureInvariant)
            .Select(match => match.Groups[1].Value)
            .ToArray();
        Assert.IsNotEmpty(commands, "The compact scrollbar template must retain WPF navigation commands.");
        Assert.IsTrue(
            commands.All(command => command is "{x:Static ScrollBar.PageUpCommand}" or "{x:Static ScrollBar.PageDownCommand}"),
            $"Only ScrollBar navigation commands are permitted in the presentation view: {string.Join(" | ", commands)}");
        StringAssert.Contains(xaml, "Style TargetType=\"ScrollBar\"");
        StringAssert.Contains(xaml, "<Setter Property=\"Width\" Value=\"8\" />");
        StringAssert.Contains(xaml, "Tag=\"ComplianceNavigationFirst\"");
        StringAssert.Contains(xaml, "Tag=\"ComplianceNavigationCurrent\"");
        StringAssert.Contains(xaml, "Tag=\"ComplianceNavigationNext\"");
        StringAssert.Contains(xaml, "Text=\"{Binding VisibleRangeLabel}\"");
        StringAssert.Contains(xaml, "ComplianceQueuePaginationPreviousName");
        StringAssert.Contains(xaml, "ComplianceQueuePaginationPreviousHelp");
        StringAssert.Contains(xaml, "ComplianceQueuePaginationCurrentName");
        StringAssert.Contains(xaml, "ComplianceQueuePaginationCurrentHelp");
        StringAssert.Contains(xaml, "ComplianceQueuePaginationNextName");
        StringAssert.Contains(xaml, "ComplianceQueuePaginationNextHelp");
        StringAssert.Contains(xaml, "MinHeight=\"245\"");
        Assert.IsFalse(
            Regex.IsMatch(xaml, "FontSize=\"9\"[^>]*Text=\"\\{Binding (?!Initials)[^\"]+\\}\"", RegexOptions.CultureInvariant),
            "Normal Compliance Queue text must not use the former 9px dense typography.");
        Assert.IsFalse(
            Regex.IsMatch(xaml, @"#[0-9A-Fa-f]{6,8}\b", RegexOptions.CultureInvariant),
            "Compliance Queue must use shared semantic resources instead of page-local colors.");
    }

    [TestMethod]
    public void PresentationStateHasNoCommandStorageOrTransitionAuthority()
    {
        var state = ReadRepositoryFile("src", "HerdrOps.App", "Compliance", "ComplianceQueueState.cs");

        foreach (var prohibited in new[]
                 {
                     "ICommand",
                     "RelayCommand",
                     "SqliteHerdrStateStore",
                     "AppendReview",
                     "TransitionIncident",
                 })
        {
            Assert.IsFalse(
                state.Contains(prohibited, StringComparison.Ordinal),
                $"Issue #26 presentation state contains prohibited authority: {prohibited}");
        }
    }

    [TestMethod]
    public void WrittenContractKeepsSyntheticUiSeparateFromAuthorizationAndRuntime()
    {
        var contract = ReadRepositoryFile(
            "docs",
            "protocol",
            "v0.5-compliance-queue-presentation-contract.md");

        StringAssert.Contains(contract, "Issue #27");
        StringAssert.Contains(contract, "every action is disabled");
        StringAssert.Contains(contract, "does not authorize a reviewer");
        StringAssert.Contains(contract, "does not");
        StringAssert.Contains(contract, "actual Herdr");
        StringAssert.Contains(contract, "Thai and English are separate complete modes");
    }

    private static string ReadRepositoryFile(params string[] segments)
    {
        var path = segments.Aggregate(
            FindRepositoryRoot(),
            static (current, segment) => Path.Combine(current, segment));
        Assert.IsTrue(File.Exists(path), $"Required Issue #26 file is missing: {path}");
        return File.ReadAllText(path);
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
