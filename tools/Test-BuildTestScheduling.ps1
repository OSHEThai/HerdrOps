# HerdrOps Solution Test Scheduling and CI Partitioned Workflow Policy Verifier
# Issue #135: Canonical single-run solution testhost and 7-job partitioned CI architecture

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$buildScript = Join-Path $PSScriptRoot 'Invoke-Build.ps1'
$ciWorkflowPath = Join-Path $repositoryRoot '.github\workflows\ci.yml'

function Test-BuildScriptScheduling {
    param(
        [Parameter(Mandatory)]
        [string]$ScriptPath
    )

    if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
        throw "Build script not found: $ScriptPath"
    }

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $ScriptPath,
        [ref]$tokens,
        [ref]$parseErrors)

    if ($parseErrors.Count -ne 0) {
        throw "Build script does not parse cleanly: $ScriptPath"
    }

    # Verify solution variable definition if assigned
    $solutionAssignments = @($ast.FindAll({
        param($node)
        if ($node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
            $node.Left.VariablePath.UserPath -ceq 'solutionPath') {
            return $true
        }
        return $false
    }, $true))

    foreach ($assign in $solutionAssignments) {
        $rightText = $assign.Right.Extent.Text
        if ($rightText -notmatch "Join-Path\s+\`$repositoryRoot\s+['""]HerdrOps\.sln['""]" -and
            $rightText -notmatch "['""]HerdrOps\.sln['""]") {
            throw "solutionPath must be anchored to repositoryRoot and HerdrOps.sln; found: $rightText"
        }
    }

    $testCommands = @($ast.FindAll({
        param($node)

        if ($node -isnot [System.Management.Automation.Language.CommandAst] -or
            $node.GetCommandName() -cne 'dotnet' -or
            $node.CommandElements.Count -lt 2) {
            return $false
        }

        return $node.CommandElements[1].Extent.Text -ceq 'test'
    }, $true))

    if ($testCommands.Count -ne 1) {
        throw "Invoke-Build.ps1 must contain exactly one canonical dotnet test command; found $($testCommands.Count)."
    }

    $commandElements = @($testCommands[0].CommandElements)
    if ($commandElements.Count -lt 3) {
        throw 'The canonical dotnet test command must specify a target solution argument.'
    }

    # Verify the target solution argument is strictly $solutionPath or HerdrOps.sln at repo root
    $targetArgument = $commandElements[2].Extent.Text
    if ($targetArgument -cne '$solutionPath' -and $targetArgument -cne '"$solutionPath"' -and $targetArgument -cne "'HerdrOps.sln'" -and $targetArgument -cne '"HerdrOps.sln"') {
        if ($targetArgument -match '[:\\/]' -or $targetArgument -notmatch '^(\$solutionPath|["'']?HerdrOps\.sln["'']?)$') {
            throw "The canonical dotnet test command must target `$solutionPath or HerdrOps.sln at repo root; found: $targetArgument"
        }
    }

    $arguments = @($commandElements |
        Select-Object -Skip 2 |
        ForEach-Object { $_.Extent.Text })

    # Check for any concurrency arguments across the entire command
    $concurrencyArgs = @($arguments | Where-Object { $_ -match '^(?:[-/]|--)(?:m|maxcpucount)(?::.*)?$' })

    if ($concurrencyArgs.Count -ne 1) {
        throw "The canonical solution test command must contain exactly one concurrency argument; found $($concurrencyArgs.Count): $($concurrencyArgs -join ', ')"
    }

    $concurrencyArg = $concurrencyArgs[0]
    if ($concurrencyArg -notmatch '^(?:-m:1|--maxcpucount:1|/m:1|/maxcpucount:1)$') {
        throw "The canonical solution test command must serialize project scheduling with exactly one -m:1 or --maxcpucount:1 argument; found: $concurrencyArg"
    }

    return
}

function ConvertFrom-CiWorkflowYaml {
    param(
        [Parameter(Mandatory)]
        [string]$YamlContent
    )

    $lines = $YamlContent -split "`r?`n"
    $jobs = [ordered]@{}
    $currentJobKey = $null
    $currentJob = $null
    $currentStep = $null
    $inJobsSection = $false
    $inStepsSection = $false
    $inRunScalar = $false
    $runScalarType = ''
    $runScalarIndent = 0
    $runScalarLines = New-Object System.Collections.ArrayList

    $i = 0
    while ($i -lt $lines.Count) {
        $line = $lines[$i]
        $trimmed = $line.Trim()

        if ($inRunScalar) {
            $lineIndent = $line.Length - $line.TrimStart().Length
            if ($trimmed.Length -gt 0 -and $lineIndent -le $runScalarIndent) {
                # End of block scalar
                $inRunScalar = $false
                if ($null -ne $currentStep) {
                    if ($runScalarType.StartsWith('>')) {
                        $currentStep.Run = ($runScalarLines.ToArray() -join ' ')
                    } else {
                        $currentStep.Run = ($runScalarLines.ToArray() -join "`n")
                    }
                }
            } else {
                if ($trimmed.Length -gt 0) {
                    $stripped = $line
                    if ($stripped -match '^(.*?)(?<!\$)(?:#.*)$') { $stripped = $Matches[1] }
                    [void]$runScalarLines.Add($stripped.Trim())
                }
                $i++
                continue
            }
        }

        if ($trimmed.StartsWith('#') -or [string]::IsNullOrWhiteSpace($trimmed)) {
            $i++
            continue
        }

        if ($line -match '^jobs:\s*$') {
            $inJobsSection = $true
            $i++
            continue
        }

        if ($inJobsSection) {
            # Job declaration: 2 spaces indent
            if ($line -match '^  ([a-zA-Z0-9_\-]+):\s*$') {
                $currentJobKey = $Matches[1]
                $currentJob = [pscustomobject]@{
                    Key = $currentJobKey
                    Name = ''
                    If = ''
                    Needs = @()
                    Steps = New-Object System.Collections.ArrayList
                }
                $jobs[$currentJobKey] = $currentJob
                $inStepsSection = $false
                $currentStep = $null
                $i++
                continue
            }

            if ($null -ne $currentJob) {
                # Job properties (4 spaces indent)
                if ($line -match '^    name:\s*(.*)$') {
                    $currentJob.Name = $Matches[1].Trim()
                    $i++
                    continue
                }

                if ($line -match '^    if:\s*(.*)$') {
                    $currentJob.If = $Matches[1].Trim()
                    $i++
                    continue
                }

                if ($line -match '^    needs:\s*$') {
                    $i++
                    while ($i -lt $lines.Count) {
                        $needsLine = $lines[$i]
                        if ($needsLine -match '^      -\s*([a-zA-Z0-9_\-]+)\s*$') {
                            $currentJob.Needs += $Matches[1]
                            $i++
                        } else {
                            break
                        }
                    }
                    continue
                }

                if ($line -match '^    needs:\s*\[(.*)\]\s*$') {
                    $tokens = $Matches[1] -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_.Length -gt 0 }
                    $currentJob.Needs += $tokens
                    $i++
                    continue
                }

                if ($line -match '^    steps:\s*$') {
                    $inStepsSection = $true
                    $i++
                    continue
                }

                if ($inStepsSection) {
                    # Step declaration: 6 spaces indent with - name: or - uses:
                    if ($line -match '^      -\s*(name|uses|run):\s*(.*)$') {
                        $currentStep = [pscustomobject]@{
                            Name = ''
                            Shell = ''
                            Run = ''
                            Uses = ''
                            If = ''
                            RawLines = New-Object System.Collections.ArrayList
                        }
                        [void]$currentJob.Steps.Add($currentStep)
                        $prop = $Matches[1]
                        $val = $Matches[2].Trim()
                        if ($prop -eq 'name') { $currentStep.Name = $val }
                        elseif ($prop -eq 'uses') { $currentStep.Uses = $val }
                        elseif ($prop -eq 'run') {
                            if ($val -match '^([|>][\-+]?)\s*(?:#.*)?$') {
                                $inRunScalar = $true
                                $runScalarType = $Matches[1]
                                $runScalarIndent = $line.Length - $line.TrimStart().Length
                                $runScalarLines = New-Object System.Collections.ArrayList
                            } else {
                                $currentStep.Run = $val
                            }
                        }
                        $i++
                        continue
                    }

                    if ($null -ne $currentStep) {
                        if ($line -match '^        name:\s*(.*)$') {
                            $currentStep.Name = $Matches[1].Trim()
                            $i++
                            continue
                        }
                        if ($line -match '^        shell:\s*(.*)$') {
                            $currentStep.Shell = $Matches[1].Trim()
                            $i++
                            continue
                        }
                        if ($line -match '^        if:\s*(.*)$') {
                            $currentStep.If = $Matches[1].Trim()
                            $i++
                            continue
                        }
                        if ($line -match '^        uses:\s*(.*)$') {
                            $currentStep.Uses = $Matches[1].Trim()
                            $i++
                            continue
                        }
                        if ($line -match '^        run:\s*(.*)$') {
                            $val = $Matches[1].Trim()
                            if ($val -match '^([|>][\-+]?)\s*(?:#.*)?$') {
                                $inRunScalar = $true
                                $runScalarType = $Matches[1]
                                $runScalarIndent = 8
                                $runScalarLines = New-Object System.Collections.ArrayList
                            } else {
                                $currentStep.Run = $val
                            }
                            $i++
                            continue
                        }
                    }
                }
            }
        }

        $i++
    }

    if ($inRunScalar -and $null -ne $currentStep) {
        if ($runScalarType.StartsWith('>')) {
            $currentStep.Run = ($runScalarLines.ToArray() -join ' ')
        } else {
            $currentStep.Run = ($runScalarLines.ToArray() -join "`n")
        }
    }

    return $jobs
}

function Get-CiRequiredPartitionJobKeys {
    return @(
        'build-and-v01'
        'v02-gates'
        'v02-package-gates'
        'v02-acceptance-gates'
        'v02-composer-ps5-gate'
        'v03-v04-gates'
        'v05-v06-gates'
        'v07-v10-gates'
    )
}

function Assert-CiAggregatorResults {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Results
    )

    $violations = @()
    foreach ($requiredJob in (Get-CiRequiredPartitionJobKeys)) {
        if (-not $Results.ContainsKey($requiredJob)) {
            $violations += "$requiredJob=missing"
            continue
        }

        $observedResult = [string]$Results[$requiredJob]
        if ($observedResult -cne 'success') {
            $violations += "$requiredJob=$observedResult"
        }
    }

    if ($violations.Count -ne 0) {
        throw "CI aggregator must fail closed; non-success dependency results: $($violations -join ', ')"
    }

    return $true
}

function Get-CiGovernedCommandInventory {
    <#
    Each entry is an explicit workflow command contract.  RequiresReleaseBuild
    is intentionally opt-in: it identifies commands whose implementation reads
    the current runner's Release binaries even when the command has no
    -SkipBuild switch.
    #>
    return @(
        @{ Pattern = 'Test-V07Issue37ManifestIntegrity\.ps1\s+-SelfTest'; Job = 'build-and-v01'; Shell = 'pwsh' },
        @{ Pattern = 'Test-BuildTestScheduling\.ps1'; Job = 'build-and-v01'; Shell = 'pwsh' },
        @{ Pattern = 'Test-BuildTestScheduling\.ps1'; Job = 'build-and-v01'; Shell = 'powershell' },
        @{ Pattern = 'Test-BuildTestScheduling\.Tests\.ps1'; Job = 'build-and-v01'; Shell = 'pwsh' },
        @{ Pattern = 'Test-BuildTestScheduling\.Tests\.ps1'; Job = 'build-and-v01'; Shell = 'powershell' },
        @{ Pattern = 'Test-HerdrOpsPackaging\.ps1'; Job = 'build-and-v01'; Shell = 'pwsh' },
        @{ Pattern = 'Test-HerdrOpsPackaging\.ps1'; Job = 'build-and-v01'; Shell = 'powershell' },
        @{ Pattern = 'Test-V01ReleaseGate\.ps1'; Job = 'build-and-v01'; Shell = 'pwsh' },

        @{ Pattern = 'Test-V02StateStoreIpc\.ps1'; Job = 'v02-gates'; Shell = 'pwsh' },
        @{ Pattern = 'Test-V02LivePages\.ps1'; Job = 'v02-gates'; Shell = 'pwsh' },
        @{ Pattern = 'Test-V02LiveWidgetsProvenance\.Tests\.ps1'; Job = 'v02-gates'; Shell = 'pwsh' },
        @{ Pattern = 'Test-V02LiveWidgetsProvenance\.Tests\.ps1'; Job = 'v02-gates'; Shell = 'powershell' },
        @{ Pattern = 'V02ResourceStageCheckpoints\.Tests\.ps1'; Job = 'v02-gates'; Shell = 'pwsh' },
        @{ Pattern = 'V02ResourceStageCheckpoints\.Tests\.ps1'; Job = 'v02-gates'; Shell = 'powershell' },
        @{ Pattern = 'V02ReferenceHostProfile\.Tests\.ps1'; Job = 'v02-gates'; Shell = 'pwsh' },
        @{ Pattern = 'V02ReferenceHostProfile\.Tests\.ps1'; Job = 'v02-gates'; Shell = 'powershell' },
        @{ Pattern = 'Test-V02WorkingSetBudget\.Tests\.ps1'; Job = 'v02-gates'; Shell = 'pwsh' },
        @{ Pattern = 'Test-V02WorkingSetBudget\.Tests\.ps1'; Job = 'v02-gates'; Shell = 'powershell' },
        @{ Pattern = 'V02RendererEvidence\.Tests\.ps1'; Job = 'v02-gates'; Shell = 'pwsh' },
        @{ Pattern = 'V02RendererEvidence\.Tests\.ps1'; Job = 'v02-gates'; Shell = 'powershell' },
        @{ Pattern = 'Test-V02PackageIdentity\.Tests\.ps1'; Job = 'v02-package-gates'; Shell = 'pwsh' },
        @{ Pattern = 'Test-V02PackageIdentity\.Tests\.ps1'; Job = 'v02-package-gates'; Shell = 'powershell' },
        @{ Pattern = 'Test-V02RendererCompatibilityManifest\.SelfTests\.ps1'; Job = 'v02-package-gates'; Shell = 'pwsh' },
        @{ Pattern = 'Test-V02RendererCompatibilityManifest\.SelfTests\.ps1'; Job = 'v02-package-gates'; Shell = 'powershell' },
        @{ Pattern = 'Test-V02ExactBinding\.Tests\.ps1'; Job = 'v02-package-gates'; Shell = 'pwsh' },
        @{ Pattern = 'Test-V02ExactBinding\.Tests\.ps1'; Job = 'v02-package-gates'; Shell = 'powershell' },
        @{ Pattern = 'V02RuntimePackageBinding\.Tests\.ps1'; Job = 'v02-acceptance-gates'; Shell = 'pwsh' },
        @{ Pattern = 'V02RuntimePackageBinding\.Tests\.ps1'; Job = 'v02-acceptance-gates'; Shell = 'powershell' },
        @{ Pattern = 'V02RuntimeSemanticBinding\.Tests\.ps1'; Job = 'v02-acceptance-gates'; Shell = 'pwsh' },
        @{ Pattern = 'V02RuntimeSemanticBinding\.Tests\.ps1'; Job = 'v02-acceptance-gates'; Shell = 'powershell' },
        @{ Pattern = 'Test-V02LanguageMatrixAcceptance\.Tests\.ps1'; Job = 'v02-acceptance-gates'; Shell = 'pwsh' },
        @{ Pattern = 'Test-V02LanguageMatrixAcceptance\.Tests\.ps1'; Job = 'v02-acceptance-gates'; Shell = 'powershell' },
        @{ Pattern = 'Test-V02LiveWidgets\.ps1'; Job = 'v02-acceptance-gates'; Shell = 'pwsh' },
        @{ Pattern = 'Test-V02LanguageModes\.ps1'; Job = 'v02-acceptance-gates'; Shell = 'pwsh' },
        @{ Pattern = 'Test-V02Issue10SameRunCausality\.Tests\.ps1'; Job = 'v02-acceptance-gates'; Shell = 'pwsh' },
        @{ Pattern = 'Test-V02Issue10SameRunCausality\.Tests\.ps1'; Job = 'v02-acceptance-gates'; Shell = 'powershell' },
        @{ Pattern = 'New-V02PerformanceEvidenceReceipt\.SelfTests\.ps1'; Job = 'v02-acceptance-gates'; Shell = 'pwsh' },
        @{ Pattern = 'New-V02PerformanceEvidenceReceipt\.SelfTests\.ps1'; Job = 'v02-composer-ps5-gate'; Shell = 'powershell' },

        @{ Pattern = 'Test-V03ImplementationGateTests\.ps1'; Job = 'v03-v04-gates'; Shell = 'pwsh' },
        @{ Pattern = 'Test-V03RuntimeCaptureProvenanceTests\.ps1'; Job = 'v03-v04-gates'; Shell = 'pwsh' },
        @{ Pattern = 'Test-V03RuntimeCaptureProvenanceTests\.ps1'; Job = 'v03-v04-gates'; Shell = 'powershell' },
        @{ Pattern = 'Test-V03ImplementationGate\.ps1'; Job = 'v03-v04-gates'; Shell = 'pwsh' },
        @{ Pattern = 'Test-V04SelfReportCli\.ps1'; Job = 'v03-v04-gates'; Shell = 'pwsh' },
        @{ Pattern = 'Test-V04AssignmentLifecycle\.ps1'; Job = 'v03-v04-gates'; Shell = 'pwsh' },
        @{ Pattern = 'Test-V04DelegationGraph\.ps1'; Job = 'v03-v04-gates'; Shell = 'pwsh' },
        @{ Pattern = 'Test-V04TaskAlignment\.ps1'; Job = 'v03-v04-gates'; Shell = 'pwsh' },
        @{ Pattern = 'Test-V04ExpandedWidget\.ps1'; Job = 'v03-v04-gates'; Shell = 'pwsh' },

        @{ Pattern = 'Test-V05ComplianceRuleEngine\.ps1'; Job = 'v05-v06-gates'; Shell = 'pwsh' },
        @{ Pattern = 'Test-V05EvidenceAuditStorage\.ps1\s+-Configuration'; Job = 'v05-v06-gates'; Shell = 'pwsh' },
        @{ Pattern = 'Test-V05EvidenceAuditStorage\.ps1\s+-SelfTest'; Job = 'v05-v06-gates'; Shell = 'pwsh' },
        @{ Pattern = 'Test-V05EvidenceAuditStorage\.ps1\s+-SelfTest'; Job = 'v05-v06-gates'; Shell = 'powershell' },
        @{ Pattern = 'Test-V05ComplianceQueue\.ps1'; Job = 'v05-v06-gates'; Shell = 'pwsh' },
        @{ Pattern = 'Test-V06ScoringEngine\.ps1'; Job = 'v05-v06-gates'; Shell = 'pwsh' },
        @{ Pattern = 'Test-V05RoleDistinctReview\.ps1'; Job = 'v05-v06-gates'; Shell = 'pwsh' },

        @{ Pattern = 'Test-V10Issue43SecurityReviewFixtures\.ps1'; Job = 'v07-v10-gates'; Shell = 'pwsh' },
        @{ Pattern = 'Test-V10Issue43SecurityReviewFixtures\.ps1'; Job = 'v07-v10-gates'; Shell = 'powershell' },
        @{ Pattern = 'Test-V10Issue43SecurityReview\.ps1'; Job = 'v07-v10-gates'; Shell = 'pwsh' },
        @{ Pattern = 'Test-V10Issue43SecurityReview\.ps1'; Job = 'v07-v10-gates'; Shell = 'powershell' },
        @{ Pattern = 'Test-V07Lifecycle\.ps1\s+-SelfTest'; Job = 'v07-v10-gates'; Shell = 'pwsh' },
        @{ Pattern = 'Test-V07Lifecycle\.ps1\s+-SelfTest'; Job = 'v07-v10-gates'; Shell = 'powershell' },
        @{ Pattern = 'Test-V07PerformanceBudgets\.Tests\.ps1'; Job = 'v07-v10-gates'; Shell = 'pwsh'; RequiresReleaseBuild = $true },
        @{ Pattern = 'Test-V07PerformanceBudgets\.Tests\.ps1'; Job = 'v07-v10-gates'; Shell = 'powershell'; RequiresReleaseBuild = $true },
        @{ Pattern = 'Test-V07PerformanceMeasurement\.Tests\.ps1'; Job = 'v07-v10-gates'; Shell = 'pwsh'; RequiresReleaseBuild = $true },
        @{ Pattern = 'Test-V07PerformanceMeasurement\.Tests\.ps1'; Job = 'v07-v10-gates'; Shell = 'powershell'; RequiresReleaseBuild = $true },
        @{ Pattern = 'Test-HerdrOpsInstallAcceptance\.ps1'; Job = 'v07-v10-gates'; Shell = 'pwsh' },
        @{ Pattern = 'Test-HerdrOpsInstallAcceptance\.ps1'; Job = 'v07-v10-gates'; Shell = 'powershell' },
        @{ Pattern = 'Invoke-HerdrOpsInstallAcceptance\.ps1\s+-Mode\s+DryRun'; Job = 'v07-v10-gates'; Shell = 'pwsh' },
        @{ Pattern = 'Invoke-HerdrOpsInstallAcceptance\.ps1\s+-Mode\s+Fixture'; Job = 'v07-v10-gates'; Shell = 'pwsh' },
        @{ Pattern = 'Test-V07Issue37ManifestIntegrity\.ps1$'; Job = 'v07-v10-gates'; Shell = 'pwsh' }
    )
}

function Test-CiWorkflowCleanRunnerIndependence {
    param(
        [Parameter(Mandatory)]
        [string]$WorkflowPath,

        [Parameter(Mandatory)]
        $Jobs
    )

    $content = Get-Content -LiteralPath $WorkflowPath -Raw

    if ([Regex]::IsMatch($content, '(?im)^\s*-\s*uses:\s*actions/download-artifact@')) {
        throw 'CI workflow must not download artifacts from another runner.'
    }
    if ([Regex]::IsMatch($content, '(?im)(?:^|\s)-SkipTests(?:\s|$)')) {
        throw 'CI workflow must not use -SkipTests; the canonical full solution test must remain enabled.'
    }
    if ([Regex]::IsMatch($content, '(?im)\b(?:shared[- ]manifest|CI_SHARED_MANIFEST)\b')) {
        throw 'CI workflow must not use a shared manifest between runners.'
    }
    if ([Regex]::IsMatch($content, '(?im)(?:^|[\\/])(?:bin|obj)[\\/]')) {
        throw 'CI workflow must not consume cross-runner bin/obj paths.'
    }

    foreach ($requiredJob in (Get-CiRequiredPartitionJobKeys)) {
        if (-not $Jobs.Contains($requiredJob)) {
            throw "CI workflow is missing required partitioned job: $requiredJob"
        }

        $job = $Jobs[$requiredJob]
        if (@($job.Needs).Count -ne 0) {
            throw "Partitioned job '$requiredJob' must not depend on another runner through needs."
        }

        $checkoutSteps = @($job.Steps | Where-Object { $_.Name -ceq 'Checkout' })
        if ($checkoutSteps.Count -ne 1) {
            throw "Partitioned job '$requiredJob' must have exactly one Checkout step."
        }

        $dotnetSetupSteps = @($job.Steps | Where-Object { $_.Name -ceq 'Set up .NET' })
        if ($dotnetSetupSteps.Count -ne 1) {
            throw "Partitioned job '$requiredJob' must have exactly one Set up .NET step."
        }

        $skipBuildIndexes = @()
        $buildPrerequisiteIndexes = @()
        $buildRequiredIndexes = @()
        for ($index = 0; $index -lt $job.Steps.Count; $index++) {
            $step = $job.Steps[$index]
            $stepRun = ([string]$job.Steps[$index].Run).Trim()
            if ($stepRun -match '(?i)(^|\s)-SkipBuild(\s|$)') {
                $skipBuildIndexes += $index
            }

            if ($stepRun -ceq './tools/Invoke-Build.ps1 -Configuration Release -VerifyFormat') {
                if ($step.Shell -cne 'pwsh') {
                    throw "Partitioned job '$requiredJob' clean-runner build prerequisite must use shell pwsh."
                }
                $buildPrerequisiteIndexes += $index
            }

            foreach ($entry in @(Get-CiGovernedCommandInventory | Where-Object {
                        $_.Job -ceq $requiredJob -and
                        $_.ContainsKey('RequiresReleaseBuild') -and
                        $_['RequiresReleaseBuild'] -eq $true
                    })) {
                if ($stepRun -match $entry.Pattern -and $step.Shell -ceq $entry.Shell) {
                    $buildRequiredIndexes += $index
                    break
                }
            }
        }

        # Each v0.2 partition must rebuild from its own checkout. This preserves
        # clean-runner independence after the former monolithic job is split.
        $requiresReleaseBuild = ($requiredJob -like 'v02-*' -or
            $skipBuildIndexes.Count -gt 0 -or
            $buildRequiredIndexes.Count -gt 0)
        if ($requiresReleaseBuild) {
            if ($buildPrerequisiteIndexes.Count -ne 1) {
                throw "Partitioned job '$requiredJob' must have exactly one canonical clean-runner build prerequisite before -SkipBuild or build-required governed gates."
            }

            foreach ($requiredIndex in @($skipBuildIndexes + $buildRequiredIndexes)) {
                if ($buildPrerequisiteIndexes[0] -ge $requiredIndex) {
                    if ($buildRequiredIndexes.Count -eq 0) {
                        throw "Partitioned job '$requiredJob' clean-runner build prerequisite must precede every -SkipBuild gate."
                    }
                    throw "Partitioned job '$requiredJob' clean-runner build prerequisite must precede every -SkipBuild or build-required governed gate."
                }
            }
        }
    }

    return
}

function Test-CiAggregatorContract {
    param(
        [Parameter(Mandatory)]
        $Jobs
    )

    if (-not $Jobs.Contains('ci-success')) {
        throw "CI workflow is missing aggregator job 'ci-success'."
    }

    $aggregator = $Jobs['ci-success']
    $aggregatorName = [string]$aggregator.Name
    if ($aggregatorName -cne 'build-test') {
        throw "CI aggregator job 'ci-success' must expose compatibility display name 'build-test'; observed '$aggregatorName'."
    }

    if ([string]$aggregator.If -cne 'always()') {
        throw "CI aggregator job 'ci-success' must use if: always() so failed, skipped, and cancelled dependencies are inspected."
    }

    foreach ($requiredJob in (Get-CiRequiredPartitionJobKeys)) {
        if ($aggregator.Needs -notcontains $requiredJob) {
            throw "CI aggregator job 'ci-success' must depend on required job: $requiredJob"
        }
    }

    $confirmationSteps = @($aggregator.Steps | Where-Object { $_.Name -ceq 'Confirm all partitioned jobs succeeded' })
    if ($confirmationSteps.Count -ne 1) {
        throw "CI aggregator job 'ci-success' must have exactly one result assertion step."
    }

    $run = [string]$confirmationSteps[0].Run
    foreach ($requiredJob in (Get-CiRequiredPartitionJobKeys)) {
        $expression = '${{ needs.' + $requiredJob + '.result }}'
        $expressionCount = ([Regex]::Matches($run, [Regex]::Escape($expression))).Count
        if ($expressionCount -ne 1) {
            throw "CI aggregator result assertion must bind exactly one result expression for '$requiredJob'; found $expressionCount."
        }
    }

    if (-not $run.Contains('$nonSuccess') -or
        -not $run.Contains("-cne 'success'") -or
        -not $run.Contains('$nonSuccess.Count -ne 0')) {
        throw "CI aggregator must fail closed by rejecting every dependency result that is not exactly 'success'."
    }

    Assert-CiAggregatorResults -Results @{
        'build-and-v01' = 'success'
        'v02-gates' = 'success'
        'v02-package-gates' = 'success'
        'v02-acceptance-gates' = 'success'
        'v02-composer-ps5-gate' = 'success'
        'v03-v04-gates' = 'success'
        'v05-v06-gates' = 'success'
        'v07-v10-gates' = 'success'
    } | Out-Null

    return
}

function Test-CiWorkflowConcurrency {
    param(
        [Parameter(Mandatory)]
        [string]$WorkflowContent
    )

    if (-not [Regex]::IsMatch($WorkflowContent, '(?m)^concurrency:\s*$')) {
        throw 'CI workflow must declare a top-level concurrency policy.'
    }
    if (-not [Regex]::IsMatch($WorkflowContent, '(?m)^  group:\s*\$\{\{\s*github\.workflow\s*\}\}-\$\{\{\s*github\.ref\s*\}\}\s*$')) {
        throw 'CI workflow concurrency group must be scoped to workflow and ref.'
    }
    if (-not [Regex]::IsMatch($WorkflowContent, '(?m)^  cancel-in-progress:\s*true\s*$')) {
        throw 'CI workflow concurrency must cancel superseded runs.'
    }

    return
}

function Test-CiWorkflowScheduling {
    param(
        [Parameter(Mandatory)]
        [string]$WorkflowPath
    )

    if (-not (Test-Path -LiteralPath $WorkflowPath -PathType Leaf)) {
        throw "CI workflow not found: $WorkflowPath"
    }

    $content = Get-Content -LiteralPath $WorkflowPath -Raw
    $jobs = ConvertFrom-CiWorkflowYaml -YamlContent $content

    $requiredJobs = @(Get-CiRequiredPartitionJobKeys)

    foreach ($rj in $requiredJobs) {
        if (-not $jobs.Contains($rj)) {
            throw "CI workflow is missing required partitioned job: $rj"
        }
    }

    # Scan all steps in all jobs for direct `dotnet test` invocations or folded splits
    $allSteps = New-Object System.Collections.ArrayList
    foreach ($jobKey in $jobs.Keys) {
        $job = $jobs[$jobKey]
        foreach ($step in $job.Steps) {
            [void]$allSteps.Add([pscustomobject]@{
                JobKey = $jobKey
                Step = $step
            })

            $run = [string]$step.Run
            if (-not [string]::IsNullOrWhiteSpace($run)) {
                $collapsed = ($run -replace '\s+', ' ').Trim()
                if ($collapsed -match '\bdotnet(\.exe)?\s+test\b') {
                    throw "Direct 'dotnet test' execution found in workflow step '$($step.Name)' in job '$jobKey': $collapsed"
                }
            }
        }
    }

    $governedInventory = @(Get-CiGovernedCommandInventory)

    foreach ($entry in $governedInventory) {
        $pat = $entry.Pattern
        $expectedJob = $entry.Job
        $expectedShell = $entry.Shell

        $matchingSteps = @($allSteps | Where-Object {
            $_.Step.Run -match $pat -and $_.Step.Shell -eq $expectedShell
        })

        if ($matchingSteps.Count -eq 0) {
            throw "Governed gate command '$pat' (shell: $expectedShell) was not found in CI workflow."
        }

        if ($matchingSteps.Count -gt 1) {
            throw "Governed gate command '$pat' (shell: $expectedShell) appears $($matchingSteps.Count) times in CI workflow; expected exactly 1."
        }

        $actualJob = $matchingSteps[0].JobKey
        if ($actualJob -ne $expectedJob) {
            throw "Governed gate command '$pat' (shell: $expectedShell) found in job '$actualJob'; expected in job '$expectedJob'."
        }
    }

    Test-CiWorkflowCleanRunnerIndependence -WorkflowPath $WorkflowPath -Jobs $jobs
    Test-CiAggregatorContract -Jobs $jobs
    Test-CiWorkflowConcurrency -WorkflowContent $content

    return
}

# Run the verifications
Test-BuildScriptScheduling -ScriptPath $buildScript
Test-CiWorkflowScheduling -WorkflowPath $ciWorkflowPath

Write-Output 'Canonical solution test-project scheduling: PASS (max concurrency 1, AST solution target pinned)'
Write-Output 'CI workflow partitioned job and governed step scheduling: PASS (8 parallel jobs, exact inventory)'
