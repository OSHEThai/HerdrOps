# HerdrOps Solution Test Scheduling and CI Partitioned Workflow Regression and Hostile Tests
# Issue #135: Validates single testhost canonical scheduling and 5-job partitioned CI invariants

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

try {
    # 1. Baseline positive control: current repository passes all scheduler checks
    Assert-Passes -TestName 'Baseline Positive Control: current repo passes all scheduling and partitioned workflow checks' -ScriptBlock {
        & $schedulerScript
    }

    # 2. Hostile CI Test: Missing clean-runner build prerequisite is rejected
    Assert-Throws -TestName 'Hostile CI: Missing v0.2 clean-runner build prerequisite is rejected' `
        -ExpectedMessagePattern 'must have exactly one canonical clean-runner build prerequisite' `
        -ScriptBlock {
            $ciContent = Get-Content -LiteralPath (Join-Path $repositoryRoot '.github\workflows\ci.yml') -Raw
            $tamperedCi = $ciContent -replace '(?ms)      - name: Run v0\.2 canonical Release build prerequisite \(clean runner\)\r?\n        shell: pwsh\r?\n        run: \./tools/Invoke-Build\.ps1 -Configuration Release -VerifyFormat\r?\n', ''
            $tamperedCiPath = Join-Path $tempRoot 'tampered-ci-missing-build-prerequisite.yml'
            Set-Content -LiteralPath $tamperedCiPath -Value $tamperedCi -Encoding utf8

            . $schedulerScript
            Test-CiWorkflowScheduling -WorkflowPath $tamperedCiPath
        }

    # 3. Hostile CI Test: Build prerequisite after a SkipBuild gate is rejected
    Assert-Throws -TestName 'Hostile CI: Clean-runner build prerequisite after SkipBuild is rejected' `
        -ExpectedMessagePattern 'must precede every -SkipBuild gate' `
        -ScriptBlock {
            $ciContent = Get-Content -LiteralPath (Join-Path $repositoryRoot '.github\workflows\ci.yml') -Raw
            $buildStepPattern = '(?ms)      - name: Run v0\.2 canonical Release build prerequisite \(clean runner\)\r?\n        shell: pwsh\r?\n        run: \./tools/Invoke-Build\.ps1 -Configuration Release -VerifyFormat\r?\n'
            $buildStep = [Regex]::Match($ciContent, $buildStepPattern).Value
            if ([string]::IsNullOrWhiteSpace($buildStep)) {
                throw 'Test fixture could not locate the v0.2 build prerequisite.'
            }
            $tamperedCi = [Regex]::Replace($ciContent, $buildStepPattern, '')
            $tamperedCi = $tamperedCi -replace '(        run: \./tools/Test-V02StateStoreIpc\.ps1[^\r\n]*\r?\n)', ('$1' + $buildStep)
            $tamperedCiPath = Join-Path $tempRoot 'tampered-ci-build-after-skipbuild.yml'
            Set-Content -LiteralPath $tamperedCiPath -Value $tamperedCi -Encoding utf8

            . $schedulerScript
            Test-CiWorkflowScheduling -WorkflowPath $tamperedCiPath
        }

    # 4. Hostile CI Test: Cross-runner artifact download is rejected
    Assert-Throws -TestName 'Hostile CI: Cross-runner artifact download is rejected' `
        -ExpectedMessagePattern 'must not download artifacts from another runner' `
        -ScriptBlock {
            $ciContent = Get-Content -LiteralPath (Join-Path $repositoryRoot '.github\workflows\ci.yml') -Raw
            $tamperedCi = $ciContent.Replace(
                '      - name: Run v0.2 state store and IPC gate',
                "      - uses: actions/download-artifact@0000000000000000000000000000000000000000`r`n      - name: Run v0.2 state store and IPC gate")
            $tamperedCiPath = Join-Path $tempRoot 'tampered-ci-download-artifact.yml'
            Set-Content -LiteralPath $tamperedCiPath -Value $tamperedCi -Encoding utf8

            . $schedulerScript
            Test-CiWorkflowScheduling -WorkflowPath $tamperedCiPath
        }

    # 5. Hostile CI Test: SkipTests is rejected
    Assert-Throws -TestName 'Hostile CI: SkipTests is rejected' `
        -ExpectedMessagePattern 'must not use -SkipTests' `
        -ScriptBlock {
            $ciContent = Get-Content -LiteralPath (Join-Path $repositoryRoot '.github\workflows\ci.yml') -Raw
            $tamperedCi = $ciContent.Replace(
                './tools/Invoke-Build.ps1 -Configuration Release -VerifyFormat',
                './tools/Invoke-Build.ps1 -Configuration Release -VerifyFormat -SkipTests')
            $tamperedCiPath = Join-Path $tempRoot 'tampered-ci-skip-tests.yml'
            Set-Content -LiteralPath $tamperedCiPath -Value $tamperedCi -Encoding utf8

            . $schedulerScript
            Test-CiWorkflowScheduling -WorkflowPath $tamperedCiPath
        }

    # 6. Hostile CI Test: Aggregator without always() is rejected
    Assert-Throws -TestName 'Hostile CI: Aggregator without if always is rejected' `
        -ExpectedMessagePattern "must use if: always\(\)" `
        -ScriptBlock {
            $ciContent = Get-Content -LiteralPath (Join-Path $repositoryRoot '.github\workflows\ci.yml') -Raw
            $tamperedCi = $ciContent -replace '(?m)^    if: always\(\)\r?\n(?=    runs-on: windows-latest\r?\n    needs:)', ''
            $tamperedCiPath = Join-Path $tempRoot 'tampered-ci-aggregator-no-always.yml'
            Set-Content -LiteralPath $tamperedCiPath -Value $tamperedCi -Encoding utf8

            . $schedulerScript
            Test-CiWorkflowScheduling -WorkflowPath $tamperedCiPath
        }

    # 7. Hostile CI Test: Aggregator with one missing dependency result is rejected
    Assert-Throws -TestName 'Hostile CI: Aggregator missing a dependency result binding is rejected' `
        -ExpectedMessagePattern 'result expression.*v05-v06-gates.*found 0' `
        -ScriptBlock {
            $ciContent = Get-Content -LiteralPath (Join-Path $repositoryRoot '.github\workflows\ci.yml') -Raw
            $tamperedCi = $ciContent.Replace(
                '${{ needs.v05-v06-gates.result }}',
                '${{ needs.v05-v06-gates.outputs.result }}')
            $tamperedCiPath = Join-Path $tempRoot 'tampered-ci-aggregator-missing-result.yml'
            Set-Content -LiteralPath $tamperedCiPath -Value $tamperedCi -Encoding utf8

            . $schedulerScript
            Test-CiWorkflowScheduling -WorkflowPath $tamperedCiPath
        }

    # 8. Hostile CI Test: Aggregator failure result fails closed
    Assert-Throws -TestName 'Hostile CI: Aggregator failure result fails closed' `
        -ExpectedMessagePattern 'must fail closed; non-success dependency results:.*v05-v06-gates=failure' `
        -ScriptBlock {
            . $schedulerScript
            Assert-CiAggregatorResults -Results @{
                'build-and-v01' = 'success'
                'v02-gates' = 'success'
                'v03-v04-gates' = 'success'
                'v05-v06-gates' = 'failure'
                'v07-v10-gates' = 'success'
            } | Out-Null
        }

    # 9. Hostile CI Test: Aggregator skipped result fails closed
    Assert-Throws -TestName 'Hostile CI: Aggregator skipped result fails closed' `
        -ExpectedMessagePattern 'must fail closed; non-success dependency results:.*v05-v06-gates=skipped' `
        -ScriptBlock {
            . $schedulerScript
            Assert-CiAggregatorResults -Results @{
                'build-and-v01' = 'success'
                'v02-gates' = 'success'
                'v03-v04-gates' = 'success'
                'v05-v06-gates' = 'skipped'
                'v07-v10-gates' = 'success'
            } | Out-Null
        }

    # 10. Hostile CI Test: Aggregator cancelled result fails closed
    Assert-Throws -TestName 'Hostile CI: Aggregator cancelled result fails closed' `
        -ExpectedMessagePattern 'must fail closed; non-success dependency results:.*v05-v06-gates=cancelled' `
        -ScriptBlock {
            . $schedulerScript
            Assert-CiAggregatorResults -Results @{
                'build-and-v01' = 'success'
                'v02-gates' = 'success'
                'v03-v04-gates' = 'success'
                'v05-v06-gates' = 'cancelled'
                'v07-v10-gates' = 'success'
            } | Out-Null
        }

    # 11. Hostile CI Test: Cancellation policy disabled is rejected
    Assert-Throws -TestName 'Hostile CI: Disabled concurrency cancellation is rejected' `
        -ExpectedMessagePattern 'must cancel superseded runs' `
        -ScriptBlock {
            $ciContent = Get-Content -LiteralPath (Join-Path $repositoryRoot '.github\workflows\ci.yml') -Raw
            $tamperedCi = $ciContent.Replace('cancel-in-progress: true', 'cancel-in-progress: false')
            $tamperedCiPath = Join-Path $tempRoot 'tampered-ci-no-cancel.yml'
            Set-Content -LiteralPath $tamperedCiPath -Value $tamperedCi -Encoding utf8

            . $schedulerScript
            Test-CiWorkflowScheduling -WorkflowPath $tamperedCiPath
        }

    # 12. Hostile CI Test: Missing required partitioned job (e.g. v02-gates)
    Assert-Throws -TestName 'Hostile CI: Missing required partitioned job is rejected' `
        -ExpectedMessagePattern 'missing required partitioned job' `
        -ScriptBlock {
            $ciContent = Get-Content -LiteralPath (Join-Path $repositoryRoot '.github\workflows\ci.yml') -Raw
            $tamperedCi = $ciContent -replace '  v02-gates:', '  # v02-gates:'
            $tamperedCiPath = Join-Path $tempRoot 'tampered-ci-missing-job.yml'
            Set-Content -LiteralPath $tamperedCiPath -Value $tamperedCi -Encoding utf8

            . $schedulerScript
            Test-CiWorkflowScheduling -WorkflowPath $tamperedCiPath
        }

    # 13. Hostile CI Test: Missing governed gate command
    Assert-Throws -TestName 'Hostile CI: Missing governed gate command is rejected' `
        -ExpectedMessagePattern 'was not found in CI workflow' `
        -ScriptBlock {
            $ciContent = Get-Content -LiteralPath (Join-Path $repositoryRoot '.github\workflows\ci.yml') -Raw
            $tamperedCi = $ciContent -replace 'Test-V05RoleDistinctReview\.ps1', 'Commented-V05RoleDistinctReview.ps1'
            $tamperedCiPath = Join-Path $tempRoot 'tampered-ci-missing-cmd.yml'
            Set-Content -LiteralPath $tamperedCiPath -Value $tamperedCi -Encoding utf8

            . $schedulerScript
            Test-CiWorkflowScheduling -WorkflowPath $tamperedCiPath
        }

    # 14. Hostile CI Test: Governed step in wrong job
    Assert-Throws -TestName 'Hostile CI: Governed step in wrong job is rejected' `
        -ExpectedMessagePattern 'expected in job' `
        -ScriptBlock {
            $ciContent = Get-Content -LiteralPath (Join-Path $repositoryRoot '.github\workflows\ci.yml') -Raw
            # Move Test-V04SelfReportCli.ps1 from v03-v04-gates to v02-gates
            $tamperedCi = $ciContent -replace '(\s+- name: Run v0.4 CLI self-report implementation gate\s+shell: pwsh\s+run: \./tools/Test-V04SelfReportCli\.ps1 -Configuration Release -SkipBuild)', ''
            $tamperedCi = $tamperedCi -replace '(  v02-gates:\s+name: v0.2 Milestone Gates\s+runs-on: windows-latest\s+timeout-minutes: 30\s+steps:)', "`$1`n      - name: Misplaced v0.4 gate`n        shell: pwsh`n        run: ./tools/Test-V04SelfReportCli.ps1 -Configuration Release -SkipBuild"
            $tamperedCiPath = Join-Path $tempRoot 'tampered-ci-wrong-job.yml'
            Set-Content -LiteralPath $tamperedCiPath -Value $tamperedCi -Encoding utf8

            . $schedulerScript
            Test-CiWorkflowScheduling -WorkflowPath $tamperedCiPath
        }

    # 15. Hostile CI Test: Governed step with wrong shell
    Assert-Throws -TestName 'Hostile CI: Governed step with wrong shell is rejected' `
        -ExpectedMessagePattern 'appears 2 times in CI workflow|was not found in CI workflow' `
        -ScriptBlock {
            $ciContent = Get-Content -LiteralPath (Join-Path $repositoryRoot '.github\workflows\ci.yml') -Raw
            # Change shell of Windows PowerShell 5.1 step to pwsh
            $tamperedCi = $ciContent -replace '(- name: Run v0.2 exact binding static tests \(Windows PowerShell 5\.1\)\s+)shell: powershell', '$1shell: pwsh'
            $tamperedCiPath = Join-Path $tempRoot 'tampered-ci-wrong-shell.yml'
            Set-Content -LiteralPath $tamperedCiPath -Value $tamperedCi -Encoding utf8

            . $schedulerScript
            Test-CiWorkflowScheduling -WorkflowPath $tamperedCiPath
        }

    # 16. Hostile CI Test: Duplicate governed step across jobs
    Assert-Throws -TestName 'Hostile CI: Duplicate governed step is rejected' `
        -ExpectedMessagePattern 'appears 2 times in CI workflow; expected exactly 1' `
        -ScriptBlock {
            $ciContent = Get-Content -LiteralPath (Join-Path $repositoryRoot '.github\workflows\ci.yml') -Raw
            $tamperedCi = $ciContent -replace '(  v05-v06-gates:\s+name: v0.5 & v0.6 Milestone Gates\s+runs-on: windows-latest\s+timeout-minutes: 30\s+steps:)', "`$1`n      - name: Dup v0.1 gate`n        shell: pwsh`n        run: ./tools/Test-V01ReleaseGate.ps1"
            $tamperedCiPath = Join-Path $tempRoot 'tampered-ci-dup-step.yml'
            Set-Content -LiteralPath $tamperedCiPath -Value $tamperedCi -Encoding utf8

            . $schedulerScript
            Test-CiWorkflowScheduling -WorkflowPath $tamperedCiPath
        }

    # 17. Hostile CI Test: Direct dotnet test in single-line CI step
    Assert-Throws -TestName 'Hostile CI: Direct dotnet test in CI workflow step is rejected' `
        -ExpectedMessagePattern 'Direct ''dotnet test'' execution found in workflow step' `
        -ScriptBlock {
            $ciContent = Get-Content -LiteralPath (Join-Path $repositoryRoot '.github\workflows\ci.yml') -Raw
            $tamperedCi = $ciContent -replace '(  v02-gates:\s+name: v0.2 Milestone Gates\s+runs-on: windows-latest\s+timeout-minutes: 30\s+steps:)', "`$1`n      - name: Illegal direct test`n        shell: pwsh`n        run: dotnet test HerdrOps.sln"
            $tamperedCiPath = Join-Path $tempRoot 'tampered-ci-direct-test.yml'
            Set-Content -LiteralPath $tamperedCiPath -Value $tamperedCi -Encoding utf8

            . $schedulerScript
            Test-CiWorkflowScheduling -WorkflowPath $tamperedCiPath
        }

    # 18. Hostile CI Test: Direct dotnet test in multiline block scalar (run: |)
    Assert-Throws -TestName 'Hostile CI: Direct dotnet test in multiline run: | block is rejected' `
        -ExpectedMessagePattern 'Direct ''dotnet test'' execution found in workflow step' `
        -ScriptBlock {
            $ciContent = Get-Content -LiteralPath (Join-Path $repositoryRoot '.github\workflows\ci.yml') -Raw
            $multilineStep = "`n      - name: Multiline test`n        shell: pwsh`n        run: |`n          Write-Host 'testing'`n          dotnet test HerdrOps.sln"
            $tamperedCi = $ciContent -replace '(  v02-gates:\s+name: v0.2 Milestone Gates\s+runs-on: windows-latest\s+timeout-minutes: 30\s+steps:)', "`$1$multilineStep"
            $tamperedCiPath = Join-Path $tempRoot 'tampered-ci-multiline-1.yml'
            Set-Content -LiteralPath $tamperedCiPath -Value $tamperedCi -Encoding utf8

            . $schedulerScript
            Test-CiWorkflowScheduling -WorkflowPath $tamperedCiPath
        }

    # 19. Hostile CI Test: Direct dotnet test in multiline block scalar (run: >)
    Assert-Throws -TestName 'Hostile CI: Direct dotnet test in multiline run: > block is rejected' `
        -ExpectedMessagePattern 'Direct ''dotnet test'' execution found in workflow step' `
        -ScriptBlock {
            $ciContent = Get-Content -LiteralPath (Join-Path $repositoryRoot '.github\workflows\ci.yml') -Raw
            $multilineStep = "`n      - name: Multiline test fold`n        shell: pwsh`n        run: >`n          dotnet test HerdrOps.sln"
            $tamperedCi = $ciContent -replace '(  v02-gates:\s+name: v0.2 Milestone Gates\s+runs-on: windows-latest\s+timeout-minutes: 30\s+steps:)', "`$1$multilineStep"
            $tamperedCiPath = Join-Path $tempRoot 'tampered-ci-multiline-2.yml'
            Set-Content -LiteralPath $tamperedCiPath -Value $tamperedCi -Encoding utf8

            . $schedulerScript
            Test-CiWorkflowScheduling -WorkflowPath $tamperedCiPath
        }

    # 20. Hostile CI Test: Direct dotnet test split across folded lines (run: >)
    Assert-Throws -TestName 'Hostile CI: Direct dotnet test split across folded lines in run: > block is rejected' `
        -ExpectedMessagePattern 'Direct ''dotnet test'' execution found in workflow step' `
        -ScriptBlock {
            $ciContent = Get-Content -LiteralPath (Join-Path $repositoryRoot '.github\workflows\ci.yml') -Raw
            $multilineStep = "`n      - name: Split test fold`n        shell: pwsh`n        run: >`n          dotnet`n          test HerdrOps.sln"
            $tamperedCi = $ciContent -replace '(  v02-gates:\s+name: v0.2 Milestone Gates\s+runs-on: windows-latest\s+timeout-minutes: 30\s+steps:)', "`$1$multilineStep"
            $tamperedCiPath = Join-Path $tempRoot 'tampered-ci-multiline-split.yml'
            Set-Content -LiteralPath $tamperedCiPath -Value $tamperedCi -Encoding utf8

            . $schedulerScript
            Test-CiWorkflowScheduling -WorkflowPath $tamperedCiPath
        }

    # 21. Hostile CI Test: Direct dotnet test in run: >- block modifier
    Assert-Throws -TestName 'Hostile CI: Direct dotnet test in run: >- block modifier is rejected' `
        -ExpectedMessagePattern 'Direct ''dotnet test'' execution found in workflow step' `
        -ScriptBlock {
            $ciContent = Get-Content -LiteralPath (Join-Path $repositoryRoot '.github\workflows\ci.yml') -Raw
            $multilineStep = "`n      - name: Stripped fold test`n        shell: pwsh`n        run: >-`n          dotnet test HerdrOps.sln"
            $tamperedCi = $ciContent -replace '(  v02-gates:\s+name: v0.2 Milestone Gates\s+runs-on: windows-latest\s+timeout-minutes: 30\s+steps:)', "`$1$multilineStep"
            $tamperedCiPath = Join-Path $tempRoot 'tampered-ci-multiline-mod.yml'
            Set-Content -LiteralPath $tamperedCiPath -Value $tamperedCi -Encoding utf8

            . $schedulerScript
            Test-CiWorkflowScheduling -WorkflowPath $tamperedCiPath
        }

    # 22. Hostile Build Script Test: Unbounded concurrency (-m:2 or missing -m:1)
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

    # 23. Hostile Build Script Test: Duplicate concurrency flags (-m:1 -m:4)
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

    # 24. Hostile Build Script Test: Target is not solution ($solutionPath / HerdrOps.sln)
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

    # 25. Hostile Build Script Test: Attacker external path target (e.g. C:/attacker/HerdrOps.sln)
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

    # 26. Hostile Build Script Test: Duplicate dotnet test commands
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

    # 27. Hostile Build Script Test: Zero dotnet test commands
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

    # 28. Hostile CI Test: Aggregator renamed away from the required branch-protection context is rejected
    Assert-Throws -TestName 'Hostile CI: Aggregator renamed compatibility display name is rejected' `
        -ExpectedMessagePattern "must expose compatibility display name 'build-test'" `
        -ScriptBlock {
            $ciContent = Get-Content -LiteralPath (Join-Path $repositoryRoot '.github\workflows\ci.yml') -Raw
            $tamperedCi = $ciContent.Replace('    name: build-test', '    name: renamed-build-test')
            $tamperedCiPath = Join-Path $tempRoot 'tampered-ci-aggregator-renamed-display-name.yml'
            Set-Content -LiteralPath $tamperedCiPath -Value $tamperedCi -Encoding utf8

            . $schedulerScript
            Test-CiWorkflowScheduling -WorkflowPath $tamperedCiPath
        }

    # 29. Hostile CI Test: Aggregator without the required compatibility display name is rejected
    Assert-Throws -TestName 'Hostile CI: Aggregator missing compatibility display name is rejected' `
        -ExpectedMessagePattern "must expose compatibility display name 'build-test'" `
        -ScriptBlock {
            $ciContent = Get-Content -LiteralPath (Join-Path $repositoryRoot '.github\workflows\ci.yml') -Raw
            $tamperedCi = [Regex]::Replace($ciContent, '(?m)^    name: build-test\r?\n', '')
            $tamperedCiPath = Join-Path $tempRoot 'tampered-ci-aggregator-missing-display-name.yml'
            Set-Content -LiteralPath $tamperedCiPath -Value $tamperedCi -Encoding utf8

            . $schedulerScript
            Test-CiWorkflowScheduling -WorkflowPath $tamperedCiPath
        }

    Write-Host "`nAll $passCount/$testCount solution test scheduling and partitioned workflow regression tests PASSED.`n"
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
