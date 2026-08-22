# HerdrOps Solution Test Scheduling and Gate Execution Policy Verifier
# Issue #9, #10, #135: Canonical single-run solution testhost and safe -SkipTests scheduling

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

    $targetArgument = $commandElements[2].Extent.Text
    if ($targetArgument -cne '$solutionPath' -and $targetArgument -notmatch 'HerdrOps\.sln') {
        throw "The canonical dotnet test command must target `$solutionPath or HerdrOps.sln; found: $targetArgument"
    }

    $arguments = @($commandElements |
        Select-Object -Skip 2 |
        ForEach-Object { $_.Extent.Text })
    $boundedSchedulers = @($arguments | Where-Object { $_ -cmatch '^(?:-m|--maxcpucount):1$' })

    if ($boundedSchedulers.Count -ne 1) {
        throw 'The canonical solution test command must serialize project scheduling with exactly one -m:1 or --maxcpucount:1 argument.'
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

    # 1. Ensure Invoke-Build.ps1 runs in CI
    if ($content -notmatch '(?m)^\s*run:\s*\./tools/Invoke-Build\.ps1\s+-Configuration\s+Release\s*$') {
        throw 'CI workflow must contain the canonical Invoke-Build.ps1 -Configuration Release step.'
    }

    # 2. Ensure NO step runs `dotnet test` directly in CI workflow (including multiline run: | or run: > blocks)
    $lines = $content -split "`r?`n"
    $inRunBlock = $false
    $runBlockIndent = 0
    $offending = New-Object System.Collections.ArrayList

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        $trimmed = $line.Trim()

        if ($trimmed.StartsWith('#')) {
            continue
        }

        if ($line -match '^\s*run:\s*(?:\||>|>-|\|-|\+\||>+)') {
            $inRunBlock = $true
            $runBlockIndent = $line.Length - $line.TrimStart().Length
            continue
        }

        if ($line -match '^\s*run:\s*(.*)$') {
            $cmd = $Matches[1]
            if ($cmd -match '^(.*?)(?<!\$)(?:#.*)$') { $cmd = $Matches[1] }
            if ($cmd -match '\bdotnet\s+test\b') {
                [void]$offending.Add("line $($i+1): $($line.Trim())")
            }
            continue
        }

        if ($inRunBlock) {
            $lineIndent = $line.Length - $line.TrimStart().Length
            if ($trimmed.Length -gt 0 -and $lineIndent -le $runBlockIndent) {
                $inRunBlock = $false
            } else {
                $strippedLine = $line
                if ($strippedLine -match '^(.*?)(?<!\$)(?:#.*)$') { $strippedLine = $Matches[1] }
                if ($strippedLine -match '\bdotnet\s+test\b') {
                    [void]$offending.Add("line $($i+1): $($line.Trim())")
                }
            }
        }
    }

    if ($offending.Count -gt 0) {
        throw "CI workflow must not execute 'dotnet test' directly in workflow steps. Offending lines: $($offending -join '; ')"
    }

    # 3. Enumerate all CI-invoked Test-V*.ps1 gates and verify -SkipTests is passed
    $requiredGates = @(
        'Test-V01ReleaseGate.ps1',
        'Test-V02StateStoreIpc.ps1',
        'Test-V02LivePages.ps1',
        'Test-V02LiveWidgets.ps1',
        'Test-V02LanguageModes.ps1',
        'Test-V03ImplementationGate.ps1',
        'Test-V04SelfReportCli.ps1',
        'Test-V04AssignmentLifecycle.ps1',
        'Test-V04DelegationGraph.ps1',
        'Test-V04TaskAlignment.ps1',
        'Test-V04ExpandedWidget.ps1',
        'Test-V05ComplianceRuleEngine.ps1',
        'Test-V05EvidenceAuditStorage.ps1',
        'Test-V05ComplianceQueue.ps1',
        'Test-V06ScoringEngine.ps1',
        'Test-V05RoleDistinctReview.ps1'
    )

    foreach ($gate in $requiredGates) {
        $gatePattern = [Regex]::Escape($gate)
        $matches = [Regex]::Matches($content, "(?m)^\s*run:\s*.*?$gatePattern.*$")
        if ($matches.Count -eq 0) {
            throw "Required release/implementation gate is omitted from CI workflow: $gate"
        }

        foreach ($m in $matches) {
            $line = $m.Value.Trim()
            if ($line -match '-SelfTest') {
                continue
            }
            if ($line -notmatch '-SkipTests') {
                throw "CI-invoked gate '$gate' must include -SkipTests to prevent duplicate testhost execution: $line"
            }
            if ($line -notmatch '-SkipBuild') {
                throw "CI-invoked gate '$gate' must include -SkipBuild: $line"
            }
        }
    }

    return
}

function Test-GateScriptSkipTestsSupport {
    param(
        [Parameter(Mandatory)]
        [string]$ToolsDirectory
    )

    $gateScripts = @(
        'Test-V01ReleaseGate.ps1',
        'Test-V02StateStoreIpc.ps1',
        'Test-V02LivePages.ps1',
        'Test-V02LiveWidgets.ps1',
        'Test-V02LanguageModes.ps1',
        'Test-V03ActivityPipeline.ps1',
        'Test-V03RealtimeActivity.ps1',
        'Test-V03TerminalProcess.ps1',
        'Test-V03FileGitActivity.ps1',
        'Test-V03NotificationRuntime.ps1',
        'Test-V03ImplementationGate.ps1',
        'Test-V04SelfReportCli.ps1',
        'Test-V04AssignmentLifecycle.ps1',
        'Test-V04DelegationGraph.ps1',
        'Test-V04TaskAlignment.ps1',
        'Test-V04ExpandedWidget.ps1',
        'Test-V04ReleaseGate.ps1',
        'Test-V05ComplianceRuleEngine.ps1',
        'Test-V05EvidenceAuditStorage.ps1',
        'Test-V05ComplianceQueue.ps1',
        'Test-V05RoleDistinctReview.ps1',
        'Test-V05ReleaseGate.ps1',
        'Test-V06ScoringEngine.ps1'
    )

    if ($gateScripts.Count -ne 23) {
        throw "Expected exactly 23 gate scripts; found $($gateScripts.Count)."
    }

    foreach ($scriptName in $gateScripts) {
        $path = Join-Path $ToolsDirectory $scriptName
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Required gate script missing from tools directory: $scriptName"
        }

        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $path,
            [ref]$tokens,
            [ref]$parseErrors)

        if ($parseErrors.Count -ne 0) {
            throw "Gate script does not parse cleanly: $scriptName"
        }

        if ($null -eq $ast.ParamBlock) {
            throw "Gate script '$scriptName' must declare a param block."
        }

        $paramNames = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        if ($paramNames -notcontains 'SkipTests') {
            throw "Gate script '$scriptName' is missing required [switch]`$SkipTests parameter."
        }
    }

    return
}

# Run the verifications
Test-BuildScriptScheduling -ScriptPath $buildScript
Test-CiWorkflowScheduling -WorkflowPath $ciWorkflowPath
Test-GateScriptSkipTestsSupport -ToolsDirectory $PSScriptRoot

Write-Output 'Canonical solution test-project scheduling: PASS (max concurrency 1, AST solution target pinned)'
Write-Output 'CI workflow test scheduling and -SkipTests gate configuration: PASS (single-line and multiline scan)'
Write-Output 'Gate script -SkipTests parameter interface compliance: PASS (all 23 gates)'
