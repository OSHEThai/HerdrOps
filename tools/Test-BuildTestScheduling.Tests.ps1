# HerdrOps Solution Test Scheduling Regression and Hostile Edge-Case Tests
# Issue #9, #10, #135: Validates single testhost canonical scheduling and -SkipTests invariants

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$schedulerScript = Join-Path $PSScriptRoot 'Test-BuildTestScheduling.ps1'

if (-not (Test-Path -LiteralPath $schedulerScript -PathType Leaf)) {
    throw "Scheduler script not found: $schedulerScript"
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) "HerdrOps-TestSchedulingTests-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

$testCount = 0
$passCount = 0

function Assert-Throws {
    param(
        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,

        [Parameter(Mandatory)]
        [string]$ExpectedMessagePattern,

        [Parameter(Mandatory)]
        [string]$TestName
    )

    $script:testCount++
    $threw = $false
    $actualMessage = ''

    try {
        & $ScriptBlock
    }
    catch {
        $threw = $true
        $actualMessage = $_.Exception.Message
    }

    if (-not $threw) {
        throw "TEST FAILED: '$TestName' expected to throw matching '$ExpectedMessagePattern', but succeeded."
    }

    if ($actualMessage -notmatch $ExpectedMessagePattern) {
        throw "TEST FAILED: '$TestName' threw unexpected message: '$actualMessage' (expected pattern: '$ExpectedMessagePattern')"
    }

    $script:passCount++
    Write-Host "PASS: $TestName"
}

function Assert-Passes {
    param(
        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,

        [Parameter(Mandatory)]
        [string]$TestName
    )

    $script:testCount++
    try {
        & $ScriptBlock
    }
    catch {
        throw "TEST FAILED: '$TestName' unexpectedly threw: $($_.Exception.Message)"
    }

    $script:passCount++
    Write-Host "PASS: $TestName"
}

function New-ValidTrxXml {
    param(
        [string]$ProjectName,
        [int]$Count
    )
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<?xml version="1.0" encoding="utf-8"?>')
    [void]$sb.AppendLine("<TestRun id=""$([Guid]::NewGuid())"" name=""$ProjectName"">")
    [void]$sb.AppendLine("  <Times creation=""2026-08-22T12:00:00.000Z"" start=""2026-08-22T12:00:01.000Z"" finish=""2026-08-22T12:00:05.000Z"" />")
    [void]$sb.AppendLine("  <Results>")
    for ($k = 1; $k -le $Count; $k++) {
        $tId = [Guid]::NewGuid().ToString()
        $eId = [Guid]::NewGuid().ToString()
        [void]$sb.AppendLine("    <UnitTestResult executionId=""$eId"" testId=""$tId"" testName=""Test_$k"" outcome=""Passed"" />")
    }
    [void]$sb.AppendLine("  </Results>")
    [void]$sb.AppendLine("  <TestDefinitions>")
    for ($k = 1; $k -le $Count; $k++) {
        $tId = [Guid]::NewGuid().ToString()
        [void]$sb.AppendLine("    <UnitTest name=""Test_$k"" storage=""bin/release/net8.0/$ProjectName.dll"" id=""$tId"">")
        [void]$sb.AppendLine("      <TestMethod codeBase=""bin/release/net8.0/$ProjectName.dll"" className=""$ProjectName.Tests.Class_$k"" name=""Test_$k"" />")
        [void]$sb.AppendLine("    </UnitTest>")
    }
    [void]$sb.AppendLine("  </TestDefinitions>")
    [void]$sb.AppendLine("  <ResultSummary outcome=""Completed"">")
    [void]$sb.AppendLine("    <Counters total=""$Count"" passed=""$Count"" failed=""0"" notExecuted=""0"" />")
    [void]$sb.AppendLine("  </ResultSummary>")
    [void]$sb.AppendLine("</TestRun>")
    return $sb.ToString()
}

try {
    # 1. Baseline positive control: current repository passes all scheduler checks
    Assert-Passes -TestName 'Baseline Positive Control: current repo passes all scheduling checks' -ScriptBlock {
        & $schedulerScript
    }

    # 2. Hostile CI Test: Missing -SkipTests on gate step
    Assert-Throws -TestName 'Hostile CI: Gate invocation missing -SkipTests is rejected' `
        -ExpectedMessagePattern 'must include -SkipTests' `
        -ScriptBlock {
            $ciContent = Get-Content -LiteralPath (Join-Path $repositoryRoot '.github\workflows\ci.yml') -Raw
            # Tamper one gate step to remove -SkipTests
            $tamperedCi = $ciContent -replace 'Test-V04SelfReportCli\.ps1 -Configuration Release -SkipBuild -SkipTests', 'Test-V04SelfReportCli.ps1 -Configuration Release -SkipBuild'
            $tamperedCiPath = Join-Path $tempRoot 'tampered-ci-1.yml'
            Set-Content -LiteralPath $tamperedCiPath -Value $tamperedCi -Encoding utf8

            . $schedulerScript
            Test-CiWorkflowScheduling -WorkflowPath $tamperedCiPath
        }

    # 3. Hostile CI Test: Missing -SkipBuild on gate step
    Assert-Throws -TestName 'Hostile CI: Gate invocation missing -SkipBuild is rejected' `
        -ExpectedMessagePattern 'must include -SkipBuild' `
        -ScriptBlock {
            $ciContent = Get-Content -LiteralPath (Join-Path $repositoryRoot '.github\workflows\ci.yml') -Raw
            $tamperedCi = $ciContent -replace 'Test-V03ImplementationGate\.ps1 -Configuration Release -SkipBuild -SkipTests', 'Test-V03ImplementationGate.ps1 -Configuration Release -SkipTests'
            $tamperedCiPath = Join-Path $tempRoot 'tampered-ci-2.yml'
            Set-Content -LiteralPath $tamperedCiPath -Value $tamperedCi -Encoding utf8

            . $schedulerScript
            Test-CiWorkflowScheduling -WorkflowPath $tamperedCiPath
        }

    # 4. Hostile CI Test: Direct dotnet test in single-line CI step
    Assert-Throws -TestName 'Hostile CI: Direct dotnet test in CI workflow step is rejected' `
        -ExpectedMessagePattern 'must not execute ''dotnet test'' directly' `
        -ScriptBlock {
            $ciContent = Get-Content -LiteralPath (Join-Path $repositoryRoot '.github\workflows\ci.yml') -Raw
            $tamperedCi = $ciContent + [Environment]::NewLine + "      - name: Illegal direct test" + [Environment]::NewLine + "        run: dotnet test HerdrOps.sln"
            $tamperedCiPath = Join-Path $tempRoot 'tampered-ci-3.yml'
            Set-Content -LiteralPath $tamperedCiPath -Value $tamperedCi -Encoding utf8

            . $schedulerScript
            Test-CiWorkflowScheduling -WorkflowPath $tamperedCiPath
        }

    # 5. Hostile CI Test: Direct dotnet test in multiline block scalar (run: |)
    Assert-Throws -TestName 'Hostile CI: Direct dotnet test in multiline run: | block is rejected' `
        -ExpectedMessagePattern 'must not execute ''dotnet test'' directly' `
        -ScriptBlock {
            $ciContent = Get-Content -LiteralPath (Join-Path $repositoryRoot '.github\workflows\ci.yml') -Raw
            $multilineStep = [Environment]::NewLine + "      - name: Multiline test" + [Environment]::NewLine + "        run: |" + [Environment]::NewLine + "          Write-Host 'testing'" + [Environment]::NewLine + "          dotnet test HerdrOps.sln"
            $tamperedCi = $ciContent + $multilineStep
            $tamperedCiPath = Join-Path $tempRoot 'tampered-ci-multiline-1.yml'
            Set-Content -LiteralPath $tamperedCiPath -Value $tamperedCi -Encoding utf8

            . $schedulerScript
            Test-CiWorkflowScheduling -WorkflowPath $tamperedCiPath
        }

    # 6. Hostile CI Test: Direct dotnet test in multiline block scalar (run: >)
    Assert-Throws -TestName 'Hostile CI: Direct dotnet test in multiline run: > block is rejected' `
        -ExpectedMessagePattern 'must not execute ''dotnet test'' directly' `
        -ScriptBlock {
            $ciContent = Get-Content -LiteralPath (Join-Path $repositoryRoot '.github\workflows\ci.yml') -Raw
            $multilineStep = [Environment]::NewLine + "      - name: Multiline test fold" + [Environment]::NewLine + "        run: >" + [Environment]::NewLine + "          dotnet test HerdrOps.sln"
            $tamperedCi = $ciContent + $multilineStep
            $tamperedCiPath = Join-Path $tempRoot 'tampered-ci-multiline-2.yml'
            Set-Content -LiteralPath $tamperedCiPath -Value $tamperedCi -Encoding utf8

            . $schedulerScript
            Test-CiWorkflowScheduling -WorkflowPath $tamperedCiPath
        }

    # 7. Hostile CI Test: Direct dotnet test split across folded lines (run: >)
    Assert-Throws -TestName 'Hostile CI: Direct dotnet test split across folded lines in run: > block is rejected' `
        -ExpectedMessagePattern 'must not execute ''dotnet test'' directly' `
        -ScriptBlock {
            $ciContent = Get-Content -LiteralPath (Join-Path $repositoryRoot '.github\workflows\ci.yml') -Raw
            $multilineStep = [Environment]::NewLine + "      - name: Split test fold" + [Environment]::NewLine + "        run: >" + [Environment]::NewLine + "          dotnet" + [Environment]::NewLine + "          test HerdrOps.sln"
            $tamperedCi = $ciContent + $multilineStep
            $tamperedCiPath = Join-Path $tempRoot 'tampered-ci-multiline-split.yml'
            Set-Content -LiteralPath $tamperedCiPath -Value $tamperedCi -Encoding utf8

            . $schedulerScript
            Test-CiWorkflowScheduling -WorkflowPath $tamperedCiPath
        }

    # 8. Hostile CI Test: Direct dotnet test in run: >- block modifier
    Assert-Throws -TestName 'Hostile CI: Direct dotnet test in run: >- block modifier is rejected' `
        -ExpectedMessagePattern 'must not execute ''dotnet test'' directly' `
        -ScriptBlock {
            $ciContent = Get-Content -LiteralPath (Join-Path $repositoryRoot '.github\workflows\ci.yml') -Raw
            $multilineStep = [Environment]::NewLine + "      - name: Stripped fold test" + [Environment]::NewLine + "        run: >-" + [Environment]::NewLine + "          dotnet test HerdrOps.sln"
            $tamperedCi = $ciContent + $multilineStep
            $tamperedCiPath = Join-Path $tempRoot 'tampered-ci-multiline-mod.yml'
            Set-Content -LiteralPath $tamperedCiPath -Value $tamperedCi -Encoding utf8

            . $schedulerScript
            Test-CiWorkflowScheduling -WorkflowPath $tamperedCiPath
        }

    # 9. Hostile CI Test: Omission of a required version gate
    Assert-Throws -TestName 'Hostile CI: Omission of required gate is rejected' `
        -ExpectedMessagePattern 'Required release/implementation gate is omitted from CI workflow' `
        -ScriptBlock {
            $ciContent = Get-Content -LiteralPath (Join-Path $repositoryRoot '.github\workflows\ci.yml') -Raw
            $tamperedCi = $ciContent -replace 'Test-V05RoleDistinctReview\.ps1', 'Commented-V05RoleDistinctReview.ps1'
            $tamperedCiPath = Join-Path $tempRoot 'tampered-ci-4.yml'
            Set-Content -LiteralPath $tamperedCiPath -Value $tamperedCi -Encoding utf8

            . $schedulerScript
            Test-CiWorkflowScheduling -WorkflowPath $tamperedCiPath
        }

    # 10. Hostile Build Script Test: Unbounded concurrency (-m:2 or missing -m:1)
    Assert-Throws -TestName 'Hostile Build: Concurrency without -m:1 is rejected' `
        -ExpectedMessagePattern 'must serialize project scheduling with exactly one -m:1 or --maxcpucount:1' `
        -ScriptBlock {
            $buildContent = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Invoke-Build.ps1') -Raw
            $tamperedBuild = $buildContent -replace '-m:1', '-m:4'
            $tamperedBuildPath = Join-Path $tempRoot 'tampered-build-1.ps1'
            Set-Content -LiteralPath $tamperedBuildPath -Value $tamperedBuild -Encoding utf8

            . $schedulerScript
            Test-BuildScriptScheduling -ScriptPath $tamperedBuildPath
        }

    # 11. Hostile Build Script Test: Duplicate concurrency flags (-m:1 -m:4)
    Assert-Throws -TestName 'Hostile Build: Duplicate concurrency arguments -m:1 -m:4 are rejected' `
        -ExpectedMessagePattern 'must contain exactly one concurrency argument' `
        -ScriptBlock {
            $buildContent = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Invoke-Build.ps1') -Raw
            $tamperedBuild = $buildContent -replace '-m:1', '-m:1 -m:4'
            $tamperedBuildPath = Join-Path $tempRoot 'tampered-build-dup-m.ps1'
            Set-Content -LiteralPath $tamperedBuildPath -Value $tamperedBuild -Encoding utf8

            . $schedulerScript
            Test-BuildScriptScheduling -ScriptPath $tamperedBuildPath
        }

    # 12. Hostile Build Script Test: Target is not solution ($solutionPath / HerdrOps.sln)
    Assert-Throws -TestName 'Hostile Build: Non-solution target passed to dotnet test is rejected' `
        -ExpectedMessagePattern 'must target \$solutionPath or HerdrOps\.sln at repo root' `
        -ScriptBlock {
            $buildContent = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Invoke-Build.ps1') -Raw
            $tamperedBuild = $buildContent -replace '\$solutionPath -m:1', 'tests\HerdrOps.UnitTests\HerdrOps.UnitTests.csproj -m:1'
            $tamperedBuildPath = Join-Path $tempRoot 'tampered-build-nonsln.ps1'
            Set-Content -LiteralPath $tamperedBuildPath -Value $tamperedBuild -Encoding utf8

            . $schedulerScript
            Test-BuildScriptScheduling -ScriptPath $tamperedBuildPath
        }

    # 13. Hostile Build Script Test: Attacker external path target (e.g. C:/attacker/HerdrOps.sln)
    Assert-Throws -TestName 'Hostile Build: Attacker external path target is rejected' `
        -ExpectedMessagePattern 'must target \$solutionPath or HerdrOps\.sln at repo root' `
        -ScriptBlock {
            $buildContent = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Invoke-Build.ps1') -Raw
            $tamperedBuild = $buildContent -replace '\$solutionPath -m:1', '"C:\attacker\HerdrOps.sln" -m:1'
            $tamperedBuildPath = Join-Path $tempRoot 'tampered-build-attacker-target.ps1'
            Set-Content -LiteralPath $tamperedBuildPath -Value $tamperedBuild -Encoding utf8

            . $schedulerScript
            Test-BuildScriptScheduling -ScriptPath $tamperedBuildPath
        }

    # 14. Hostile Build Script Test: Duplicate dotnet test commands
    Assert-Throws -TestName 'Hostile Build: Duplicate dotnet test commands in Invoke-Build are rejected' `
        -ExpectedMessagePattern 'must contain exactly one canonical dotnet test command' `
        -ScriptBlock {
            $buildContent = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Invoke-Build.ps1') -Raw
            $tamperedBuild = $buildContent + [Environment]::NewLine + "& dotnet test `$solutionPath -m:1"
            $tamperedBuildPath = Join-Path $tempRoot 'tampered-build-2.ps1'
            Set-Content -LiteralPath $tamperedBuildPath -Value $tamperedBuild -Encoding utf8

            . $schedulerScript
            Test-BuildScriptScheduling -ScriptPath $tamperedBuildPath
        }

    # 15. Hostile Build Script Test: Zero dotnet test commands
    Assert-Throws -TestName 'Hostile Build: Zero dotnet test commands in Invoke-Build are rejected' `
        -ExpectedMessagePattern 'must contain exactly one canonical dotnet test command' `
        -ScriptBlock {
            $buildContent = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Invoke-Build.ps1') -Raw
            $tamperedBuild = $buildContent -replace 'dotnet test', 'dotnet build'
            $tamperedBuildPath = Join-Path $tempRoot 'tampered-build-3.ps1'
            Set-Content -LiteralPath $tamperedBuildPath -Value $tamperedBuild -Encoding utf8

            . $schedulerScript
            Test-BuildScriptScheduling -ScriptPath $tamperedBuildPath
        }

    # 16. Hostile Gate Param Test: Gate script missing [switch]$SkipTests
    Assert-Throws -TestName 'Hostile Gate: Gate script missing -SkipTests parameter is rejected' `
        -ExpectedMessagePattern 'is missing required \[switch\]\$SkipTests parameter' `
        -ScriptBlock {
            $dummyToolsDir = Join-Path $tempRoot 'dummy-tools'
            New-Item -ItemType Directory -Path $dummyToolsDir -Force | Out-Null
            Copy-Item -Path (Join-Path $PSScriptRoot 'Test-V*.ps1') -Destination $dummyToolsDir -Force
            $target = Join-Path $dummyToolsDir 'Test-V06ScoringEngine.ps1'
            $content = Get-Content -LiteralPath $target -Raw
            $tampered = $content -replace ',\s*\[switch\]\$SkipTests', ''
            Set-Content -LiteralPath $target -Value $tampered -Encoding utf8

            . $schedulerScript
            Test-GateScriptSkipTestsSupport -ToolsDirectory $dummyToolsDir
        }

    # 17. Hostile Gate Behavioral Test: Gate script declaring [switch]$SkipTests but not referencing it in body
    Assert-Throws -TestName 'Hostile Gate: Gate script declaring -SkipTests but not referencing in body is rejected' `
        -ExpectedMessagePattern 'does not reference or honor it in script body' `
        -ScriptBlock {
            $dummyToolsDir = Join-Path $tempRoot 'dummy-tools-behavioral'
            New-Item -ItemType Directory -Path $dummyToolsDir -Force | Out-Null
            Copy-Item -Path (Join-Path $PSScriptRoot 'Test-V*.ps1') -Destination $dummyToolsDir -Force
            $target = Join-Path $dummyToolsDir 'Test-V06ScoringEngine.ps1'
            $content = Get-Content -LiteralPath $target -Raw
            $tokens = $null
            $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($target, [ref]$tokens, [ref]$errors)
            $paramExtentEnd = $ast.ParamBlock.Extent.EndOffset
            $paramText = $content.Substring(0, $paramExtentEnd)
            $bodyText = $content.Substring($paramExtentEnd)
            $tampered = $paramText + ($bodyText -replace '\$SkipTests', '$dummyVar')
            Set-Content -LiteralPath $target -Value $tampered -Encoding utf8

            . $schedulerScript
            Test-GateScriptSkipTestsSupport -ToolsDirectory $dummyToolsDir
        }

    # 18. Canonical Test Manifest Library Hostile Tests
    . (Join-Path $PSScriptRoot 'lib\CanonicalTestManifest.ps1')

    # Setup valid dummy test result fixture
    $fixtureDir = Join-Path $tempRoot 'valid-fixture'
    New-Item -ItemType Directory -Path $fixtureDir -Force | Out-Null
    $projects = @('HerdrOps.ContractTests', 'HerdrOps.IntegrationTests', 'HerdrOps.RuntimeTests', 'HerdrOps.UnitTests')
    $counts = @(191, 97, 116, 484)
    for ($i = 0; $i -lt 4; $i++) {
        $p = $projects[$i]
        $c = $counts[$i]
        $trxXml = New-ValidTrxXml -ProjectName $p -Count $c
        [IO.File]::WriteAllText((Join-Path $fixtureDir "$p.trx"), $trxXml, [Text.Encoding]::UTF8)
    }

    # Positive generation
    $manifestRecord = New-CanonicalTestResultsManifest -TestResultsDirectory $fixtureDir -RepositoryRoot $repositoryRoot
    Assert-Passes -TestName 'Canonical Manifest: Valid fixture generates passing manifest' -ScriptBlock {
        $validated = Assert-CanonicalTestResultsManifest -TestResultsDirectory $fixtureDir -RepositoryRoot $repositoryRoot
        if ($validated.TotalTests -ne 888 -or $validated.PassedTests -ne 888) {
            throw "Expected 888 tests, got $($validated.TotalTests)"
        }
    }

    # 19. Hostile Manifest: Missing manifest file fails closed
    Assert-Throws -TestName 'Hostile Manifest: Missing manifest fails closed' `
        -ExpectedMessagePattern 'Canonical test results manifest missing' `
        -ScriptBlock {
            $missingDir = Join-Path $tempRoot 'missing-manifest'
            New-Item -ItemType Directory -Path $missingDir -Force | Out-Null
            Assert-CanonicalTestResultsManifest -TestResultsDirectory $missingDir -RepositoryRoot $repositoryRoot
        }

    # 20. Hostile Manifest: Stale commit hash in manifest fails closed
    Assert-Throws -TestName 'Hostile Manifest: Stale SourceCommit fails closed' `
        -ExpectedMessagePattern 'SourceCommit mismatch' `
        -ScriptBlock {
            $staleCommitDir = Join-Path $tempRoot 'stale-commit'
            Copy-Item -Path $fixtureDir -Destination $staleCommitDir -Recurse -Force
            $mPath = Join-Path $staleCommitDir 'test-results-manifest.json'
            $raw = Get-Content -LiteralPath $mPath -Raw
            $tampered = $raw -replace '"SourceCommit":\s*"[0-9a-f]{40}"', '"SourceCommit": "0000000000000000000000000000000000000000"'
            [IO.File]::WriteAllText($mPath, $tampered, [Text.Encoding]::UTF8)
            Assert-CanonicalTestResultsManifest -TestResultsDirectory $staleCommitDir -RepositoryRoot $repositoryRoot
        }

    # 21. Hostile Manifest: Stale tree hash in manifest fails closed
    Assert-Throws -TestName 'Hostile Manifest: Stale SourceTree fails closed' `
        -ExpectedMessagePattern 'SourceTree mismatch' `
        -ScriptBlock {
            $staleTreeDir = Join-Path $tempRoot 'stale-tree'
            Copy-Item -Path $fixtureDir -Destination $staleTreeDir -Recurse -Force
            $mPath = Join-Path $staleTreeDir 'test-results-manifest.json'
            $raw = Get-Content -LiteralPath $mPath -Raw
            $tampered = $raw -replace '"SourceTree":\s*"[0-9a-f]{40}"', '"SourceTree": "0000000000000000000000000000000000000000"'
            [IO.File]::WriteAllText($mPath, $tampered, [Text.Encoding]::UTF8)
            Assert-CanonicalTestResultsManifest -TestResultsDirectory $staleTreeDir -RepositoryRoot $repositoryRoot
        }

    # 22. Hostile Manifest: Extra / Duplicate / Stale TRX files (e.g. 5 TRX files instead of 4) fails closed
    Assert-Throws -TestName 'Hostile Manifest: Extra/duplicate TRX files fail closed' `
        -ExpectedMessagePattern 'expected exactly 4 authenticated TRX files' `
        -ScriptBlock {
            $extraTrxDir = Join-Path $tempRoot 'extra-trx'
            Copy-Item -Path $fixtureDir -Destination $extraTrxDir -Recurse -Force
            [IO.File]::WriteAllText((Join-Path $extraTrxDir 'stale_extra.trx'), '<TestRun />', [Text.Encoding]::UTF8)
            Assert-CanonicalTestResultsManifest -TestResultsDirectory $extraTrxDir -RepositoryRoot $repositoryRoot
        }

    # 23. Hostile Manifest: Wrong aggregate test count (e.g. 885 instead of 888) fails closed
    Assert-Throws -TestName 'Hostile Manifest: Wrong test count fails closed' `
        -ExpectedMessagePattern 'counters mismatch' `
        -ScriptBlock {
            $wrongCountDir = Join-Path $tempRoot 'wrong-count'
            Copy-Item -Path $fixtureDir -Destination $wrongCountDir -Recurse -Force
            $mPath = Join-Path $wrongCountDir 'test-results-manifest.json'
            $raw = Get-Content -LiteralPath $mPath -Raw
            $tampered = $raw -replace '"TotalTests":\s*888', '"TotalTests": 885'
            [IO.File]::WriteAllText($mPath, $tampered, [Text.Encoding]::UTF8)
            Assert-CanonicalTestResultsManifest -TestResultsDirectory $wrongCountDir -RepositoryRoot $repositoryRoot
        }

    # 24. Hostile Manifest: Tampered TRX file content / hash mismatch fails closed
    Assert-Throws -TestName 'Hostile Manifest: Tampered TRX hash fails closed' `
        -ExpectedMessagePattern 'TRX file hash mismatch' `
        -ScriptBlock {
            $tamperedHashDir = Join-Path $tempRoot 'tampered-hash'
            Copy-Item -Path $fixtureDir -Destination $tamperedHashDir -Recurse -Force
            $targetTrx = Join-Path $tamperedHashDir 'HerdrOps.UnitTests.trx'
            [IO.File]::WriteAllText($targetTrx, '<?xml version="1.0"?><TestRun modified="true" />', [Text.Encoding]::UTF8)
            Assert-CanonicalTestResultsManifest -TestResultsDirectory $tamperedHashDir -RepositoryRoot $repositoryRoot
        }

    # 25. Hostile Manifest: Duplicate ProjectName in manifest is rejected
    Assert-Throws -TestName 'Hostile Manifest: Duplicate ProjectName in manifest is rejected' `
        -ExpectedMessagePattern 'Duplicate ProjectName in manifest' `
        -ScriptBlock {
            $dupProjectDir = Join-Path $tempRoot 'dup-project-manifest'
            Copy-Item -Path $fixtureDir -Destination $dupProjectDir -Recurse -Force
            $mPath = Join-Path $dupProjectDir 'test-results-manifest.json'
            $mObj = Get-Content -LiteralPath $mPath -Raw | ConvertFrom-Json
            $mObj.Projects[1].ProjectName = $mObj.Projects[0].ProjectName
            $mJson = $mObj | ConvertTo-Json -Depth 5
            [IO.File]::WriteAllText($mPath, $mJson, [Text.Encoding]::UTF8)
            Assert-CanonicalTestResultsManifest -TestResultsDirectory $dupProjectDir -RepositoryRoot $repositoryRoot
        }

    # 26. Hostile Manifest: Non-passing outcome in result row fails closed
    Assert-Throws -TestName 'Hostile Manifest: Non-passing outcome in result row fails closed' `
        -ExpectedMessagePattern 'Result row outcomes do not match Counters|contains non-passing result row outcome|non-passing test results' `
        -ScriptBlock {
            $failedRowDir = Join-Path $tempRoot 'failed-row'
            New-Item -ItemType Directory -Path $failedRowDir -Force | Out-Null
            for ($i = 0; $i -lt 4; $i++) {
                $p = $projects[$i]
                $c = $counts[$i]
                $trxXml = New-ValidTrxXml -ProjectName $p -Count $c
                if ($p -eq 'HerdrOps.UnitTests') {
                    $trxXml = $trxXml -replace 'outcome="Passed"', 'outcome="Failed"'
                }
                [IO.File]::WriteAllText((Join-Path $failedRowDir "$p.trx"), $trxXml, [Text.Encoding]::UTF8)
            }
            New-CanonicalTestResultsManifest -TestResultsDirectory $failedRowDir -RepositoryRoot $repositoryRoot
        }

    # 27. Hostile Manifest: Result row count mismatch vs Counters total fails closed
    Assert-Throws -TestName 'Hostile Manifest: Result row count mismatch vs Counters total fails closed' `
        -ExpectedMessagePattern 'Result row count.*does not match Counters\.total|result row count' `
        -ScriptBlock {
            $mismatchRowDir = Join-Path $tempRoot 'mismatch-row'
            New-Item -ItemType Directory -Path $mismatchRowDir -Force | Out-Null
            for ($i = 0; $i -lt 4; $i++) {
                $p = $projects[$i]
                $c = $counts[$i]
                $trxXml = New-ValidTrxXml -ProjectName $p -Count $c
                if ($p -eq 'HerdrOps.UnitTests') {
                    # Inject an extra UnitTestResult row without incrementing counter
                    $extraRow = '<UnitTestResult executionId="' + [Guid]::NewGuid() + '" testId="' + [Guid]::NewGuid() + '" testName="FakeExtra" outcome="Passed" />'
                    $trxXml = $trxXml -replace '</Results>', "$extraRow`n  </Results>"
                }
                [IO.File]::WriteAllText((Join-Path $mismatchRowDir "$p.trx"), $trxXml, [Text.Encoding]::UTF8)
            }
            New-CanonicalTestResultsManifest -TestResultsDirectory $mismatchRowDir -RepositoryRoot $repositoryRoot
        }

    Write-Host "`nAll $passCount/$testCount solution test scheduling regression tests PASSED.`n"
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
