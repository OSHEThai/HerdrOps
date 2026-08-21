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

    [TestMethod]
    public void SelfReportGatePreservesExactAcceptedUtcAcrossPowerShellHostsAndTimezones()
    {
        var script = ReadRepositoryFile("tools", "Test-V04SelfReportCli.ps1");

        Assert.IsFalse(
            Regex.IsMatch(script, @"\[string\]\$acceptedResult\.acceptedUtc", RegexOptions.CultureInvariant),
            "Test-V04SelfReportCli.ps1 must not read acceptedUtc through ConvertFrom-Json, whose date coercion rewrites the exact UTC offset on PowerShell 7 and differs by host timezone.");

        StringAssert.Contains(
            script,
            "\"acceptedUtc\"\\s*:\\s*\"([^\"]+)\"",
            "Test-V04SelfReportCli.ps1 must extract acceptedUtc from the raw JSON bytes to preserve the exact UTC string and offset.");
        StringAssert.Contains(
            script,
            "$acceptedUtcText -notmatch '(Z|[+-]00:00)$'",
            "Test-V04SelfReportCli.ps1 must require an explicit UTC offset so the check behaves identically on UTC and non-UTC hosts.");
        StringAssert.Contains(
            script,
            "[Globalization.DateTimeStyles]::RoundtripKind",
            "Test-V04SelfReportCli.ps1 must parse acceptedUtc with RoundtripKind to preserve the exact offset.");
        StringAssert.Contains(
            script,
            "$acceptedUtc.Offset -ne [TimeSpan]::Zero",
            "Test-V04SelfReportCli.ps1 must reject a non-zero acceptedUtc offset.");
    }

    [TestMethod]
    public void GateScriptProcessCleanupIsPS51Compatible()
    {
        // .Kill($true) and .Kill($false) require .NET 5+ (Process.Kill(bool))
        // and are not available under Windows PowerShell 5.1 / .NET Framework.
        // All gate scripts, the shared lib, and the behavioral selftest must use
        // argument-free .Kill() only.
        foreach (var scriptName in GateScripts())
        {
            var script = ReadRepositoryFile("tools", scriptName);
            Assert.IsFalse(
                Regex.IsMatch(script, @"\.Kill\(\s*\$(?:true|false)\s*\)", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant),
                $"{scriptName} must not call .Kill($true) or .Kill($false) — the bool overload is unavailable on Windows PowerShell 5.1.");
        }

        // The shared library must exist and must be Kill(bool)-free.
        var libScript = ReadRepositoryFile("tools", "lib", "V04ProcessCleanup.ps1");
        Assert.IsFalse(
            Regex.IsMatch(libScript, @"\.Kill\(\s*\$(?:true|false)\s*\)", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant),
            "tools/lib/V04ProcessCleanup.ps1 must not use Kill(bool).");
        StringAssert.Contains(
            libScript,
            "function Stop-CoreProcessBounded",
            "tools/lib/V04ProcessCleanup.ps1 must define Stop-CoreProcessBounded.");

        // The behavioral selftest must exist and be Kill(bool)-free.
        var selfTestScript = ReadRepositoryFile("tools", "Test-V04ProcessCleanupSelfTests.ps1");
        Assert.IsFalse(
            Regex.IsMatch(selfTestScript, @"\.Kill\(\s*\$(?:true|false)\s*\)", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant),
            "Test-V04ProcessCleanupSelfTests.ps1 must not use Kill(bool).");
        // Verify the selftest exercises both required paths.
        StringAssert.Contains(
            selfTestScript,
            "AlreadyExited",
            "Test-V04ProcessCleanupSelfTests.ps1 must include the already-exited cleanup path.");
        StringAssert.Contains(
            selfTestScript,
            "TimeoutCleanup",
            "Test-V04ProcessCleanupSelfTests.ps1 must include the running/timeout cleanup path.");

        // Test-V04SelfReportCli.ps1 must dot-source the shared lib (not define inline).
        var selfReportScript = ReadRepositoryFile("tools", "Test-V04SelfReportCli.ps1");
        StringAssert.Contains(
            selfReportScript,
            ". (Join-Path $PSScriptRoot 'lib\\V04ProcessCleanup.ps1')",
            "Test-V04SelfReportCli.ps1 must dot-source lib/V04ProcessCleanup.ps1 rather than define Stop-CoreProcessBounded inline.");

        // Gate script must NOT define Stop-CoreProcessBounded inline any more.
        Assert.DoesNotContain(
            selfReportScript,
            "function Stop-CoreProcessBounded",
            "Test-V04SelfReportCli.ps1 must not define Stop-CoreProcessBounded inline - it must use the shared lib.");

        // Both the not-ready path and timeout path must delegate to Stop-CoreProcessBounded.
        var cleanupCallCount = Regex.Matches(
            selfReportScript,
            @"Stop-CoreProcessBounded",
            RegexOptions.CultureInvariant).Count;
        Assert.IsGreaterThanOrEqualTo(
            2,
            cleanupCallCount,
            $"Test-V04SelfReportCli.ps1 must call Stop-CoreProcessBounded at least twice (not-ready path and timeout path); found {cleanupCallCount} call(s).");
    }

    [TestMethod]
    public void ReleaseGateInvokesBehavioralSelftestUnderBothEngines()
    {
        // Verifies that Test-V04ReleaseGate.ps1 actually invokes the behavioral
        // selftest under both PS7 (pwsh) and PS5.1 (powershell.exe). Without this,
        // removing the invocation from the release gate would silently bypass the
        // regression coverage even though the selftest file still exists.
        var releaseGate = ReadRepositoryFile("tools", "Test-V04ReleaseGate.ps1");

        StringAssert.Contains(
            releaseGate,
            "Test-V04ProcessCleanupSelfTests.ps1",
            "Test-V04ReleaseGate.ps1 must invoke Test-V04ProcessCleanupSelfTests.ps1.");

        // Both engine invocations must be present: pwsh for PS7, powershell.exe for PS5.1.
        StringAssert.Contains(
            releaseGate,
            "pwsh",
            "Test-V04ReleaseGate.ps1 must invoke the behavioral selftest under pwsh (PS7).");
        StringAssert.Contains(
            releaseGate,
            "powershell.exe",
            "Test-V04ReleaseGate.ps1 must invoke the behavioral selftest under powershell.exe (PS5.1).");

        // Fail-closed: both engine invocations must throw on non-zero exit.
        StringAssert.Contains(
            releaseGate,
            "FAILED under PowerShell 7",
            "Test-V04ReleaseGate.ps1 must throw when the PS7 selftest fails.");
        StringAssert.Contains(
            releaseGate,
            "FAILED under Windows PowerShell 5.1",
            "Test-V04ReleaseGate.ps1 must throw when the PS5.1 selftest fails.");
    }

    private static string[] GateScripts() =>
    [
        "Test-V04SelfReportCli.ps1",
        "Test-V04AssignmentLifecycle.ps1",
        "Test-V04DelegationGraph.ps1",
        "Test-V04TaskAlignment.ps1",
        "Test-V04ExpandedWidget.ps1",
        "Test-V04ReleaseGate.ps1",
        "Test-V04ProcessCleanupSelfTests.ps1",
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
