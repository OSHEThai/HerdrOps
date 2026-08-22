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

$tempRoot = Join-Path $env:TEMP "HerdrOps-TestSchedulingTests-$([Guid]::NewGuid().ToString('N'))"
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

    # 4. Hostile CI Test: Direct dotnet test in CI step
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

    # 5. Hostile CI Test: Omission of a required version gate
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

    # 6. Hostile Build Script Test: Unbounded concurrency (-m:2 or missing -m:1)
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

    # 7. Hostile Build Script Test: Duplicate dotnet test commands
    Assert-Throws -TestName 'Hostile Build: Duplicate dotnet test commands in Invoke-Build are rejected' `
        -ExpectedMessagePattern 'must contain exactly one canonical dotnet test command' `
        -ScriptBlock {
            $buildContent = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Invoke-Build.ps1') -Raw
            $tamperedBuild = $buildContent + [Environment]::NewLine + "& dotnet test HerdrOps.sln -m:1"
            $tamperedBuildPath = Join-Path $tempRoot 'tampered-build-2.ps1'
            Set-Content -LiteralPath $tamperedBuildPath -Value $tamperedBuild -Encoding utf8

            . $schedulerScript
            Test-BuildScriptScheduling -ScriptPath $tamperedBuildPath
        }

    # 8. Hostile Build Script Test: Zero dotnet test commands
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

    # 9. Hostile Gate Param Test: Gate script missing [switch]$SkipTests
    Assert-Throws -TestName 'Hostile Gate: Gate script missing -SkipTests parameter is rejected' `
        -ExpectedMessagePattern 'is missing required \[switch\]\$SkipTests parameter' `
        -ScriptBlock {
            $dummyToolsDir = Join-Path $tempRoot 'dummy-tools'
            New-Item -ItemType Directory -Path $dummyToolsDir -Force | Out-Null
            Copy-Item -Path (Join-Path $PSScriptRoot 'Test-V*.ps1') -Destination $dummyToolsDir -Force
            # Strip [switch]$SkipTests from one gate cleanly
            $target = Join-Path $dummyToolsDir 'Test-V06ScoringEngine.ps1'
            $content = Get-Content -LiteralPath $target -Raw
            $tampered = $content -replace ',\s*\[switch\]\$SkipTests', ''
            Set-Content -LiteralPath $target -Value $tampered -Encoding utf8

            . $schedulerScript
            Test-GateScriptSkipTestsSupport -ToolsDirectory $dummyToolsDir
        }

    # 10. Hostile Gate Execution: Gate with -SkipTests fails when canonical TRX is missing
    Assert-Throws -TestName 'Hostile Execution: Gate with -SkipTests fails when canonical TRX is missing' `
        -ExpectedMessagePattern 'Expected fresh canonical TRX output' `
        -ScriptBlock {
            $emptyTrxGate = Join-Path $tempRoot 'Test-EmptyTrxGate.ps1'
            $script = 'param([switch]$SkipTests)' + [Environment]::NewLine +
                '$artifactRoot = Join-Path $PSScriptRoot ''artifacts''' + [Environment]::NewLine +
                '$canonicalTestResultRoot = Join-Path $artifactRoot ''test-results''' + [Environment]::NewLine +
                '$canonicalTrxFiles = @(if (Test-Path $canonicalTestResultRoot) { Get-ChildItem -LiteralPath $canonicalTestResultRoot -Filter ''*.trx'' -File } else { @() })' + [Environment]::NewLine +
                'if ($canonicalTrxFiles.Count -lt 4) {' + [Environment]::NewLine +
                '    throw "Expected fresh canonical TRX output from four test projects in $canonicalTestResultRoot, found $($canonicalTrxFiles.Count)."' + [Environment]::NewLine +
                '}'
            Set-Content -LiteralPath $emptyTrxGate -Value $script -Encoding utf8
            & $emptyTrxGate -SkipTests
        }

    Write-Host "`nAll $passCount/$testCount solution test scheduling regression tests PASSED.`n"
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
