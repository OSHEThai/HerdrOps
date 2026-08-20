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

    [TestMethod]
    public void RuntimeAcceptanceHarnessPreservesWindowsPowerShellCompatibilityAndFailClosedChecks()
    {
        var script = ReadRepositoryFile("tools", "Invoke-V04LifecycleRuntimeAcceptance.ps1");

        Assert.IsFalse(
            Regex.IsMatch(script, @"Get-ChildItem[^\r\n]*-Depth", RegexOptions.IgnoreCase),
            "Invoke-V04LifecycleRuntimeAcceptance.ps1 must remain runnable on Windows PowerShell 5.1.");
        Assert.IsFalse(
            Regex.IsMatch(script, @"ConvertFrom-Json[^\r\n]*-Depth", RegexOptions.IgnoreCase),
            "Invoke-V04LifecycleRuntimeAcceptance.ps1 must not use the PowerShell 7-only ConvertFrom-Json -Depth parameter.");

        StringAssert.Contains(
            script,
            "$lifecycleTrace = Get-Content -LiteralPath $lifecycleTracePath -Raw | ConvertFrom-Json",
            "Invoke-V04LifecycleRuntimeAcceptance.ps1 must parse lifecycle trace with PS5.1-compatible ConvertFrom-Json.");
        StringAssert.Contains(
            script,
            "$herdrRuntime = Get-Content -LiteralPath $herdrRuntimeReportPath -Raw | ConvertFrom-Json",
            "Invoke-V04LifecycleRuntimeAcceptance.ps1 must parse herdr runtime report with PS5.1-compatible ConvertFrom-Json.");
        StringAssert.Contains(
            script,
            "$composite = Get-Content -LiteralPath $compositeReportPath -Raw | ConvertFrom-Json",
            "Invoke-V04LifecycleRuntimeAcceptance.ps1 must parse composite report with PS5.1-compatible ConvertFrom-Json.");

        StringAssert.Contains(
            script,
            "$lifecycleTrace.evidenceClassification -ne 'BuiltProcessIntegration'",
            "Invoke-V04LifecycleRuntimeAcceptance.ps1 must enforce BuiltProcessIntegration classification check.");
        StringAssert.Contains(
            script,
            "$herdrRuntime.EvidenceClassification -ne 'Runtime'",
            "Invoke-V04LifecycleRuntimeAcceptance.ps1 must enforce Herdr runtime EvidenceClassification check.");
        StringAssert.Contains(
            script,
            "$composite.EvidenceClassification -ne 'Runtime'",
            "Invoke-V04LifecycleRuntimeAcceptance.ps1 must enforce composite EvidenceClassification check.");
        StringAssert.Contains(
            script,
            "-not [bool]$composite.Acceptance.Passed",
            "Invoke-V04LifecycleRuntimeAcceptance.ps1 must enforce composite Acceptance.Passed check.");
    }

    private static string[] GateScripts() =>
    [
        "Test-V04SelfReportCli.ps1",
        "Test-V04AssignmentLifecycle.ps1",
        "Test-V04DelegationGraph.ps1",
        "Test-V04TaskAlignment.ps1",
        "Test-V04ExpandedWidget.ps1",
        "Test-V04ReleaseGate.ps1",
        "Invoke-V04LifecycleRuntimeAcceptance.ps1",
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
