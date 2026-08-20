using System.Text.RegularExpressions;

namespace HerdrOps.ContractTests;

[TestClass]
public sealed class V04ImplementationGateScriptContractTests
{
    [TestMethod]
    public void ImplementationGatesDoNotUsePowerShellJsonDepthOrChildItemDepth()
    {
        foreach (var scriptName in GateScripts())
        {
            var script = ReadRepositoryFile("tools", scriptName);

            Assert.IsFalse(
                Regex.IsMatch(script, @"Get-ChildItem[^\r\n]*-Depth", RegexOptions.IgnoreCase),
                $"{scriptName} must remain runnable on Windows PowerShell 5.1.");
            Assert.IsFalse(
                Regex.IsMatch(script, @"ConvertFrom-Json[^\r\n]*-Depth", RegexOptions.IgnoreCase),
                $"{scriptName} must not use the PowerShell 7-only ConvertFrom-Json -Depth parameter.");
        }
    }

    [TestMethod]
    public void BuiltCoreExitCodesAreRefreshedBeforeValidation()
    {
        foreach (var scriptName in new[] { "Test-V04SelfReportCli.ps1", "Test-V04ExpandedWidget.ps1" })
        {
            var script = ReadRepositoryFile("tools", scriptName);
            StringAssert.Matches(
                script,
                new Regex(
                    @"WaitForExit\([^\r\n]*\)[\s\S]{0,240}\.Refresh\(\)[\s\S]{0,240}ExitCode",
                    RegexOptions.CultureInvariant),
                $"{scriptName} must refresh the Process before reading its exit code.");
            StringAssert.Contains(script, "Output:", $"{scriptName} must report captured Core output paths on failure.");
            StringAssert.Contains(script, "Error:", $"{scriptName} must report captured Core error paths on failure.");
        }
    }

    private static string[] GateScripts() =>
    [
        "Test-V04SelfReportCli.ps1",
        "Test-V04AssignmentLifecycle.ps1",
        "Test-V04DelegationGraph.ps1",
        "Test-V04TaskAlignment.ps1",
        "Test-V04ExpandedWidget.ps1",
        "Test-V04ReleaseGate.ps1",
    ];

    private static string ReadRepositoryFile(params string[] segments)
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null)
        {
            if (File.Exists(Path.Combine(directory.FullName, "HerdrOps.sln")))
            {
                var path = directory.FullName;
                foreach (var segment in segments)
                {
                    path = Path.Combine(path, segment);
                }

                return File.ReadAllText(path);
            }

            directory = directory.Parent;
        }

        Assert.Fail("Could not locate HerdrOps.sln from the test output directory.");
        return string.Empty;
    }
}
