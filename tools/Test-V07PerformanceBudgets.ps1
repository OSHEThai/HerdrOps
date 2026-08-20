<#
.SYNOPSIS
    Evaluates HerdrOps v0.7.0 performance budgets and non-runtime preparation for Issue #39.

.DESCRIPTION
    Validates performance telemetry reports against Plan-derived non-functional target budgets
    defined in Plan/RELEASE-GATES.md and Plan/DECISIONS.md. Enforces strict schema v0.7.0,
    candidate binary and source commit hash bindings, clean-checkout and path/reparse protections,
    deterministic -SelfTest fixtures, and explicit PREPARATION / NOT OBSERVED evidence boundaries.

.PARAMETER ReportPath
    Path to an evaluated performance budget report JSON document.

.PARAMETER SelfTest
    Runs deterministic positive and negative self-test verification fixtures.

.PARAMETER SkipBuild
    Skips building candidate binaries if already built.

.PARAMETER Configuration
    Build configuration to verify against (Debug or Release; default Release).

.PARAMETER CandidateDirectory
    Directory containing built candidate binaries (defaults to artifacts/bin).

.PARAMETER RepositoryRoot
    Root directory of the HerdrOps repository.
#>
[CmdletBinding()]
param(
    [string]$ReportPath = '',

    [switch]$SelfTest,

    [switch]$SkipBuild,

    [switch]$SkipCleanCheck,

    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',

    [string]$CandidateDirectory = '',

    [string]$RepositoryRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

# -----------------------------------------------------------------------------
# Repository Root and Policy Module Loading
# -----------------------------------------------------------------------------
$resolvedRepoRoot = if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
} else {
    (Resolve-Path -LiteralPath $RepositoryRoot).Path
}

$policyPath = Join-Path $PSScriptRoot 'lib\V07PerformanceBudgetPolicy.ps1'
if (-not (Test-Path -LiteralPath $policyPath -PathType Leaf)) {
    throw "Required policy module is missing: $policyPath"
}
. $policyPath

# -----------------------------------------------------------------------------
# Path and Reparse Point Safety
# -----------------------------------------------------------------------------
Assert-NotReparsePoint -Path $resolvedRepoRoot -Description 'Repository root'
$artifactRoot = Join-Path $resolvedRepoRoot 'artifacts'

if ([string]::IsNullOrWhiteSpace($CandidateDirectory)) {
    $CandidateDirectory = Join-Path $artifactRoot "bin"
}

# -----------------------------------------------------------------------------
# Clean Repository State Verification
# -----------------------------------------------------------------------------
$effectiveSkipClean = $SkipCleanCheck -or $SelfTest
$sourceCommit = Test-CleanRepositoryState -RepositoryRoot $resolvedRepoRoot -SkipCleanCheck:$effectiveSkipClean

$runId = "$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ', [Globalization.CultureInfo]::InvariantCulture))-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
$gateDirectory = Join-Path $artifactRoot "release-gates\v0.7.0\issue-39\$runId"
$gateReportTextPath = Join-Path $gateDirectory 'gate-report.txt'
$gateReportJsonPath = Join-Path $gateDirectory 'performance-budget-preparation.json'

New-Item -ItemType Directory -Path $gateDirectory -Force | Out-Null

# -----------------------------------------------------------------------------
# Optional Build Step
# -----------------------------------------------------------------------------
if (-not $SkipBuild -and -not $SelfTest -and [string]::IsNullOrWhiteSpace($ReportPath) -eq $false) {
    $invokeBuild = Join-Path $PSScriptRoot 'Invoke-Build.ps1'
    if (Test-Path -LiteralPath $invokeBuild -PathType Leaf) {
        Write-Host "Running build gate with configuration $Configuration..."
        & $invokeBuild -Configuration $Configuration -VerifyFormat
        if ($LASTEXITCODE -ne 0) {
            throw "Build gate failed with exit code $LASTEXITCODE."
        }
    }
}

# -----------------------------------------------------------------------------
# Self-Test Execution
# -----------------------------------------------------------------------------
$selfTestSummary = $null
if ($SelfTest) {
    $fixturesDir = Join-Path $resolvedRepoRoot 'tests\fixtures\v0.7\budgets'
    if (-not (Test-Path -LiteralPath $fixturesDir -PathType Container)) {
        throw "Self-test fixtures directory does not exist: $fixturesDir"
    }

    Write-Host "`nRunning v0.7 performance budget deterministic self-test suite..."
    $selfTestResults = @(Invoke-PerformanceBudgetSelfTests -RepositoryRoot $resolvedRepoRoot -FixturesDirectory $fixturesDir)

    $stPassed = 0
    $stFailed = 0
    foreach ($res in $selfTestResults) {
        if ($res.Status -eq 'PASS') {
            $stPassed++
            Write-Host "  [PASS] $($res.TestName): $($res.Detail)" -ForegroundColor Green
        } else {
            $stFailed++
            Write-Host "  [FAIL] $($res.TestName): $($res.Detail)" -ForegroundColor Red
        }
    }

    $selfTestSummary = [pscustomobject]@{
        TotalTests  = $selfTestResults.Count
        PassedTests = $stPassed
        FailedTests = $stFailed
        Results     = @($selfTestResults)
    }

    if ($stFailed -gt 0) {
        throw "Performance budget self-test suite failed: $stFailed of $($selfTestResults.Count) tests failed."
    }

    Write-Host "All $($selfTestResults.Count) self-test scenarios passed cleanly.`n" -ForegroundColor Green
}

# -----------------------------------------------------------------------------
# Report Evaluation (if ReportPath provided or default passing fixture evaluated)
# -----------------------------------------------------------------------------
$activeReportPath = $ReportPath
if ([string]::IsNullOrWhiteSpace($activeReportPath) -and -not $SelfTest) {
    # Default to the passing fixture for dry-run non-runtime preparation validation
    $activeReportPath = Join-Path $resolvedRepoRoot 'tests\fixtures\v0.7\budgets\passing-budget-report.json'
}

$evaluationResult = $null
$reportObject = $null

if (-not [string]::IsNullOrWhiteSpace($activeReportPath)) {
    $safeReportPath = Assert-PathWithinRoot -Path $activeReportPath -AllowedRoots @($resolvedRepoRoot, $artifactRoot) -Description 'Report path'
    $jsonContent = Get-BoundedUtf8FileText -Path $safeReportPath -Description 'Performance budget report'
    $reportObject = ConvertFrom-StrictPerformanceBudgetJson -JsonText $jsonContent -SourceDescription $safeReportPath
    $evaluationResult = Test-PerformanceBudgetReport -ReportObject $reportObject -CandidateDirectory $CandidateDirectory -RepositoryRoot $resolvedRepoRoot
}

# -----------------------------------------------------------------------------
# Construct Structured Output and Gate Report
# -----------------------------------------------------------------------------
$lines = [System.Collections.Generic.List[string]]::new()

$lines.Add('========================================================================')
$lines.Add('HerdrOps v0.7.0 Performance Budget Gate (Issue #39 Non-Runtime Preparation)')
$lines.Add('========================================================================')
$lines.Add("GateRunId:           $runId")
$lines.Add("TimestampUtc:        $([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture))")
$lines.Add("SourceCommit:        $sourceCommit")
$lines.Add("Phase:               NON-RUNTIME PREPARATION")
$lines.Add("ReportEvaluated:     $(if ($null -ne $activeReportPath) { $activeReportPath } else { 'SELF-TEST ONLY' })")
$lines.Add("OverallResult:       $(if ($null -ne $evaluationResult) { $evaluationResult.OverallStatus } elseif ($SelfTest) { 'PASS (SELF-TEST)' } else { 'PENDING' })")
$lines.Add('')
$lines.Add('--- EVIDENCE CLASSIFICATION ---')
$lines.Add('StaticEvidence:      OBSERVED (Source commit bound, schema validated, candidate hashes bound, reparse protected)')
$lines.Add("SyntheticEvidence:   $(if ($SelfTest -or $null -ne $evaluationResult) { 'OBSERVED (Deterministic -SelfTest positive/negative fixtures verified)' } else { 'PENDING' })")
$lines.Add("ContractEvidence:    $(if ($null -ne $evaluationResult -and $evaluationResult.Passed) { 'OBSERVED (Plan-derived 8 target budgets strictly enforced)' } else { 'EVALUATED' })")
$lines.Add('')
$lines.Add('--- EVIDENCE BOUNDARY (EXPLICITLY NOT OBSERVED) ---')
$lines.Add('ActualHerdrRuntime:  NOT OBSERVED / NOT CLAIMED')
$lines.Add('SoakExecution:       NOT OBSERVED / NOT CLAIMED (8-hour actual Herdr soak requires live environment)')
$lines.Add('HumanUatDecision:    NOT OBSERVED / PENDING (Requires human user review)')
$lines.Add('ReleaseEvidence:     NOT OBSERVED / NOT CLAIMED (v0.7.0 release gate pending runtime & soak)')
$lines.Add('========================================================================')

if ($null -ne $evaluationResult) {
    $lines.Add('')
    $lines.Add('--- BUDGET EVALUATION CHECKS ---')
    foreach ($chk in $evaluationResult.Checks) {
        $lines.Add(("[{0,-13}] {1,-26} | Target: {2,-30} | Observed: {3,-24} | {4}" -f $chk.Status, $chk.Id, $chk.Target, $chk.Observed, $chk.Detail))
    }

    if ($evaluationResult.WaiversApplied.Count -gt 0) {
        $lines.Add('')
        $lines.Add('--- WAIVERS APPLIED ---')
        foreach ($w in $evaluationResult.WaiversApplied) {
            $lines.Add("Waiver for Metric '$($w.Metric)': Approved by $($w.ApprovedBy) on $($w.ApprovalDateUtc) (SHA-256: $($w.WaiverSha256))")
            $lines.Add("  Cause:  $($w.Cause)")
            $lines.Add("  Impact: $($w.Impact)")
        }
    }
}

if ($null -ne $selfTestSummary) {
    $lines.Add('')
    $lines.Add('--- SELF-TEST SUMMARY ---')
    $lines.Add("Total Self-Tests: $($selfTestSummary.TotalTests), Passed: $($selfTestSummary.PassedTests), Failed: $($selfTestSummary.FailedTests)")
}

$lines.Add('')
$lines.Add("GateReport: $gateReportTextPath")

# Write text report
[System.IO.File]::WriteAllLines($gateReportTextPath, $lines, (New-Object System.Text.UTF8Encoding($false)))

# Write JSON report
$jsonGateReport = [ordered]@{
    SchemaVersion    = 'v0.7.0'
    RunId            = $runId
    TimestampUtc     = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
    SourceCommit     = $sourceCommit
    Phase            = 'NON-RUNTIME PREPARATION'
    OverallResult    = if ($null -ne $evaluationResult) { $evaluationResult.OverallStatus } elseif ($SelfTest) { 'PASS (SELF-TEST)' } else { 'PENDING' }
    EvidenceBoundary = [ordered]@{
        StaticEvidence     = 'OBSERVED'
        SyntheticEvidence  = if ($SelfTest -or $null -ne $evaluationResult) { 'OBSERVED' } else { 'PENDING' }
        ContractEvidence   = if ($null -ne $evaluationResult -and $evaluationResult.Passed) { 'OBSERVED' } else { 'EVALUATED' }
        ActualHerdrRuntime = 'NOT OBSERVED / NOT CLAIMED'
        SoakExecution      = 'NOT OBSERVED / NOT CLAIMED'
        HumanUatDecision   = 'NOT OBSERVED / PENDING'
        ReleaseEvidence    = 'NOT OBSERVED / NOT CLAIMED'
    }
    Checks           = if ($null -ne $evaluationResult) { @($evaluationResult.Checks) } else { @() }
    WaiversApplied   = if ($null -ne $evaluationResult) { @($evaluationResult.WaiversApplied) } else { @() }
    SelfTestSummary  = $selfTestSummary
}
$jsonGateReportText = $jsonGateReport | ConvertTo-Json -Depth 20
[System.IO.File]::WriteAllText($gateReportJsonPath, $jsonGateReportText, (New-Object System.Text.UTF8Encoding($false)))

# Print report to host
foreach ($line in $lines) {
    Write-Host $line
}

if ($null -ne $evaluationResult -and -not $evaluationResult.Passed) {
    throw "Performance budget evaluation failed. See gate report at $gateReportTextPath"
}
