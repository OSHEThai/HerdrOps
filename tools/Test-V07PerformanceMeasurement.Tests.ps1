# HerdrOps v0.7 Performance Measurement Producer -- Deterministic Unit and
# Regression Tests (PS 5.1 and PS 7+). Issue #39.
#
# Verifies that the fail-closed admission and finalization logic rejects missing,
# forged, stale, and wrong-session evidence, and that a finalized Runtime budget
# report produced from synthetic-but-valid evidence is admitted by the existing
# budget gate (cross-validation). No test starts Herdr, invokes session control,
# or writes a Runtime budget report to disk.

[CmdletBinding()]
param(
    [string]$RepositoryRoot = '',
    [string]$FixtureDirectory = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$repositoryRoot = if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
} else {
    (Resolve-Path -LiteralPath $RepositoryRoot).Path
}
$fixturesDirectory = if ([string]::IsNullOrWhiteSpace($FixtureDirectory)) {
    Join-Path $repositoryRoot 'tests\fixtures\v0.7\performance-measurement'
} else {
    (Resolve-Path -LiteralPath $FixtureDirectory).Path
}

# Hermeticity: deterministic tests must never be influenced by an ambient
# authorized Herdr session in the operator shell.
Remove-Item Env:HERDR_ENV -ErrorAction SilentlyContinue
Remove-Item Env:HERDR_SOCKET_PATH -ErrorAction SilentlyContinue
Remove-Item Env:HERDR_PANE_ID -ErrorAction SilentlyContinue
$policyPath = Join-Path $PSScriptRoot 'lib\V07PerformanceMeasurementPolicy.ps1'
$selfTestsPath = Join-Path $PSScriptRoot 'lib\V07MeasurementSelfTests.ps1'
$budgetPolicyPath = Join-Path $PSScriptRoot 'lib\V07PerformanceBudgetPolicy.ps1'

if (-not (Test-Path -LiteralPath $policyPath -PathType Leaf)) {
    throw "Required policy module missing: $policyPath"
}
if (-not (Test-Path -LiteralPath $selfTestsPath -PathType Leaf)) {
    throw "Required self-test module missing: $selfTestsPath"
}
. $policyPath
. $selfTestsPath

$testCount = 0
$passCount = 0
$failCount = 0

function Assert-Test {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$Condition,
        [string]$Message = ''
    )

    $script:testCount++
    if ($Condition) {
        $script:passCount++
        Write-Host "  [PASS] $Name $(if ($Message) { "($Message)" })" -ForegroundColor Green
    } else {
        $script:failCount++
        Write-Host "  [FAIL] $Name $(if ($Message) { "($Message)" })" -ForegroundColor Red
    }
}

Write-Host "`n========================================================================"
Write-Host "HerdrOps v0.7 Performance Measurement Producer Test Suite (Issue #39)"
Write-Host "========================================================================`n"

$candidateDirectory = Join-Path $repositoryRoot 'artifacts\bin'
$goodFixturePath = Join-Path $fixturesDirectory 'live-measurement-good.json'

# -----------------------------------------------------------------------------
# Section 1: Deterministic Self-Test Matrix (synthetic; PS7/PS5 compatible)
# -----------------------------------------------------------------------------
Write-Host "Section 1: Full Deterministic Self-Test Matrix"
$selfTestResults = @(Invoke-V07MeasurementSelfTests -RepositoryRoot $repositoryRoot -FixturesDirectory $fixturesDirectory)
$allStPassed = @($selfTestResults | Where-Object Status -ne 'PASS').Count -eq 0
Assert-Test -Name "Invoke-V07MeasurementSelfTests runs all $($selfTestResults.Count) matrix cases" -Condition ($allStPassed -and $selfTestResults.Count -eq 35) -Message "Statuses: $(($selfTestResults | Where-Object Status -ne 'PASS' | ForEach-Object { $_.TestName }) -join '; ')"

# -----------------------------------------------------------------------------
# Section 2: Budget-Gate Cross-Validation of the Finalized Runtime Report
# -----------------------------------------------------------------------------
Write-Host "`nSection 2: Budget-Gate Cross-Validation"
if (Test-Path -LiteralPath $budgetPolicyPath -PathType Leaf) {
    # Always dot-source: the budget policy's internal Add-Type guard keeps the
    # C# validator type unique while the policy functions must exist for
    # cross-validation of the finalized report.
    . $budgetPolicyPath

    $goodJson = Get-V07BoundedUtf8FileText -Path $goodFixturePath -Description 'Good fixture'
    Assert-V07StrictJsonText -JsonText $goodJson -SourceDescription 'Good fixture'
    $baseArtifact = $goodJson | ConvertFrom-Json
    $synth = New-V07SynthesizedLiveArtifact -BaseArtifact $baseArtifact -RepositoryRoot $repositoryRoot
    $soak = New-V07SyntheticSoakArtifact -MeasurementArtifact $synth
    $finalization = ConvertTo-V07RuntimeBudgetReport -MeasurementArtifact $synth -SoakArtifact $soak -RepositoryRoot $repositoryRoot -CandidateDirectory $candidateDirectory
    Assert-Test -Name 'Finalizer admits synthesized live artifact plus matching soak' -Condition ($finalization.CanFinalize -and $null -ne $finalization.BudgetReport) -Message "Blockers: $($finalization.Blockers -join '; ')"

    if ($finalization.CanFinalize -and $null -ne $finalization.BudgetReport) {
        $budgetJson = $finalization.BudgetReport | ConvertTo-Json -Depth 20
        $strictOk = $false
        $strictError = ''
        try {
            $null = ConvertFrom-StrictPerformanceBudgetJson -JsonText $budgetJson -SourceDescription 'finalized budget report'
            $strictOk = $true
        } catch {
            $strictOk = $false
            $strictError = $_.Exception.Message
        }
        Assert-Test -Name 'Finalized budget report passes the strict v0.7.0 schema' -Condition $strictOk -Message $strictError

        $parsedReport = ConvertFrom-StrictPerformanceBudgetJson -JsonText $budgetJson -SourceDescription 'finalized budget report'
        $gateEval = Test-PerformanceBudgetReport -ReportObject $parsedReport -CandidateDirectory $candidateDirectory -RepositoryRoot $repositoryRoot -ExpectedSourceCommit ([string]$synth.Candidate.SourceCommit)
        Assert-Test -Name 'Finalized budget report passes the existing budget gate (Runtime admission)' -Condition ($gateEval.Passed -and $gateEval.OverallStatus -eq 'PASS') -Message "OverallStatus=$($gateEval.OverallStatus); Failures=$(($gateEval.Checks | Where-Object Status -notin @('PASS','PASS (WAIVED)') | ForEach-Object { "$($_.Id):$($_.Status)" }) -join ',')"
    }
} else {
    Assert-Test -Name 'Budget-gate cross-validation available' -Condition $false -Message "Budget policy not found: $budgetPolicyPath"
}

# -----------------------------------------------------------------------------
# Section 3: Negative Fixture Rejection (missing/forged/stale/wrong-session)
# -----------------------------------------------------------------------------
Write-Host "`nSection 3: Negative Fixture Rejection"
$negativeFixtures = @(
    'live-measurement-missing-samples.json',
    'live-measurement-forged-observed.json',
    'live-measurement-wrong-session.json',
    'live-measurement-wrong-role.json',
    'live-measurement-timed-out.json',
    'synthetic-measurement-artifact.json'
)
foreach ($fixtureName in $negativeFixtures) {
    $json = Get-V07BoundedUtf8FileText -Path (Join-Path $fixturesDirectory $fixtureName) -Description $fixtureName
    Assert-V07StrictJsonText -JsonText $json -SourceDescription $fixtureName
    $artifact = $json | ConvertFrom-Json
    $admission = Test-V07MeasurementArtifactAdmission -Artifact $artifact
    Assert-Test -Name "Internal admission rejects '$fixtureName'" -Condition (-not $admission.Valid) -Message "Failures: $($admission.Failures -join '; ')"
}

# Stale-commit requires the external HEAD binding.
$staleJson = Get-V07BoundedUtf8FileText -Path (Join-Path $fixturesDirectory 'live-measurement-stale-commit.json') -Description 'Stale commit fixture'
Assert-V07StrictJsonText -JsonText $staleJson -SourceDescription 'Stale commit fixture'
$staleArtifact = $staleJson | ConvertFrom-Json
$staleAdmission = Test-V07MeasurementArtifactAdmission -Artifact $staleArtifact -RepositoryRoot $repositoryRoot -CandidateDirectory $candidateDirectory
Assert-Test -Name 'External admission rejects stale source commit and binary hashes' -Condition (-not $staleAdmission.Valid) -Message "Failures: $($staleAdmission.Failures -join '; ')"

# -----------------------------------------------------------------------------
# Section 4: Soak Artifact Validation
# -----------------------------------------------------------------------------
Write-Host "`nSection 4: Soak Artifact Validation"
$goodSoakJson = Get-V07BoundedUtf8FileText -Path (Join-Path $fixturesDirectory 'soak-evidence-good.json') -Description 'Good soak fixture'
Assert-V07StrictJsonText -JsonText $goodSoakJson -SourceDescription 'Good soak fixture'
$goodSoak = $goodSoakJson | ConvertFrom-Json
$baseArtifact = (Get-V07BoundedUtf8FileText -Path $goodFixturePath -Description 'Good fixture') | ConvertFrom-Json
$soakCheck = Test-V07SoakArtifact -SoakArtifact $goodSoak -MeasurementArtifact $baseArtifact
Assert-Test -Name 'Committed good soak fixture validates against the good session' -Condition $soakCheck.Valid -Message "Failures: $($soakCheck.Failures -join '; ')"

$cancelledSoakJson = Get-V07BoundedUtf8FileText -Path (Join-Path $fixturesDirectory 'soak-evidence-cancelled.json') -Description 'Cancelled soak fixture'
Assert-V07StrictJsonText -JsonText $cancelledSoakJson -SourceDescription 'Cancelled soak fixture'
$cancelledSoak = $cancelledSoakJson | ConvertFrom-Json
$cancelledSoakCheck = Test-V07SoakArtifact -SoakArtifact $cancelledSoak -MeasurementArtifact $baseArtifact
Assert-Test -Name 'Cancelled soak artifact is rejected' -Condition (-not $cancelledSoakCheck.Valid) -Message "Failures: $($cancelledSoakCheck.Failures -join '; ')"

# -----------------------------------------------------------------------------
# Section 5: Provenance and Session Hardening
# -----------------------------------------------------------------------------
Write-Host "`nSection 5: Provenance and Session Hardening"
$goodJson = Get-V07BoundedUtf8FileText -Path $goodFixturePath -Description 'Good fixture'
$baseArtifact = $goodJson | ConvertFrom-Json

# 5a: A measurement artifact is never admitted as a budget report (schema isolation).
$artifactJson = $baseArtifact | ConvertTo-Json -Depth 30
$budgetRejected = $false
try {
    $null = ConvertFrom-StrictPerformanceBudgetJson -JsonText $artifactJson -SourceDescription 'measurement artifact as budget report'
} catch {
    $budgetRejected = $true
}
Assert-Test -Name 'Measurement artifact schema is isolated from the budget report schema' -Condition $budgetRejected

# 5b: Session socket collision fails closed internally.
$collision = New-V07SynthesizedLiveArtifact -BaseArtifact $baseArtifact -RepositoryRoot $repositoryRoot
$collision.Session.ControlHerdrSocketPath = $collision.Session.TargetHerdrSocketPath
$collisionAdmission = Test-V07MeasurementArtifactAdmission -Artifact $collision
Assert-Test -Name 'Control/target socket collision fails closed' -Condition (-not $collisionAdmission.Valid) -Message "Failures: $($collisionAdmission.Failures -join '; ')"

# 5c: Control pane id mismatch fails closed.
$paneMismatch = New-V07SynthesizedLiveArtifact -BaseArtifact $baseArtifact -RepositoryRoot $repositoryRoot
$paneMismatch.Session.ObservedControlPaneId = 'pane-other-999'
$paneMismatchAdmission = Test-V07MeasurementArtifactAdmission -Artifact $paneMismatch
Assert-Test -Name 'Control pane id mismatch fails closed' -Condition (-not $paneMismatchAdmission.Valid) -Message "Failures: $($paneMismatchAdmission.Failures -join '; ')"

# 5d: Herdr executable hash mismatch fails closed.
$herdrHashMismatch = New-V07SynthesizedLiveArtifact -BaseArtifact $baseArtifact -RepositoryRoot $repositoryRoot
$herdrHashMismatch.Session.HerdrExecutableSha256 = '0' * 64
$herdrHashAdmission = Test-V07MeasurementArtifactAdmission -Artifact $herdrHashMismatch
Assert-Test -Name 'Herdr executable hash mismatch fails closed' -Condition (-not $herdrHashAdmission.Valid) -Message "Failures: $($herdrHashAdmission.Failures -join '; ')"

# 5e: Source commit mismatch with current HEAD fails closed (stale).
$staleHead = New-V07SynthesizedLiveArtifact -BaseArtifact $baseArtifact -RepositoryRoot $repositoryRoot
$staleHead.Candidate.SourceCommit = ('0' * 40)
$staleHeadAdmission = Test-V07MeasurementArtifactAdmission -Artifact $staleHead -RepositoryRoot $repositoryRoot -CandidateDirectory $candidateDirectory
Assert-Test -Name 'Stale source commit fails closed against current HEAD' -Condition (-not $staleHeadAdmission.Valid) -Message "Failures: $($staleHeadAdmission.Failures -join '; ')"

# 5f: Budget-target evaluation mirrors the Plan budgets.
$synth = New-V07SynthesizedLiveArtifact -BaseArtifact $baseArtifact -RepositoryRoot $repositoryRoot
$budgetChecks = Test-V07MeasurementBudgetTargets -Metrics $synth.Metrics
Assert-Test -Name 'Budget-target evaluation reports all Plan budgets' -Condition ($budgetChecks.Count -eq 8 -and @($budgetChecks | Where-Object { -not $_.Passed }).Count -eq 0) -Message "Checks: $(($budgetChecks | ForEach-Object { "$($_.Id)=$($_.Passed)" }) -join '; ')"

# 5g: Hostile JSON rejection at the runner level (duplicate/trailing/NaN).
$goodJsonText = Get-V07BoundedUtf8FileText -Path $goodFixturePath -Description 'Good fixture'
$duplicateCaught = $false
$duplicateText = $goodJsonText -replace '"ArtifactKind": "PerformanceMeasurementRun"', '"ArtifactKind": "PerformanceMeasurementRun", "ArtifactKind": "PerformanceMeasurementRun"'
try { Assert-V07StrictJsonText -JsonText $duplicateText -SourceDescription 'duplicate key hostile test' } catch { $duplicateCaught = $true }
Assert-Test -Name 'Hostile duplicate JSON key is rejected' -Condition $duplicateCaught

$trailingCaught = $false
try { Assert-V07StrictJsonText -JsonText ($goodJsonText + ' {}') -SourceDescription 'trailing content hostile test' } catch { $trailingCaught = $true }
Assert-Test -Name 'Hostile trailing JSON content is rejected' -Condition $trailingCaught

$nonFiniteCaught = $false
$nonFiniteText = $goodJsonText -replace '"Milliseconds": 120.4', '"Milliseconds": NaN'
try { Assert-V07StrictJsonText -JsonText $nonFiniteText -SourceDescription 'non-finite hostile test' } catch { $nonFiniteCaught = $true }
Assert-Test -Name 'Hostile non-finite JSON numeric is rejected' -Condition $nonFiniteCaught

# 5h: Cross-file hash chain integrity.
$synth = New-V07SynthesizedLiveArtifact -BaseArtifact $baseArtifact -RepositoryRoot $repositoryRoot
$soak = New-V07SyntheticSoakArtifact -MeasurementArtifact $synth
$chainCheck = Test-V07SoakArtifact -SoakArtifact $soak -MeasurementArtifact $synth
$brokenSoak = New-V07SyntheticSoakArtifact -MeasurementArtifact $synth
$brokenSoak.MeasurementArtifactSha256 = '0' * 64
$brokenChainCheck = Test-V07SoakArtifact -SoakArtifact $brokenSoak -MeasurementArtifact $synth
Assert-Test -Name 'Cross-file run-id/hash chain binds soak to measurement run' -Condition ($chainCheck.Valid -and -not $brokenChainCheck.Valid) -Message "ChainValid=$($chainCheck.Valid); BrokenChainValid=$($brokenChainCheck.Valid); Failures: $($brokenChainCheck.Failures -join '; ')"

# -----------------------------------------------------------------------------
# Section 6: Fail-Closed Timeout Path (no Runtime credit on partial runs)
# -----------------------------------------------------------------------------
Write-Host "`nSection 6: Fail-Closed Timeout Path"
$timedOutArtifact = New-V07SynthesizedLiveArtifact -BaseArtifact $baseArtifact -RepositoryRoot $repositoryRoot
$timedOutArtifact.TimedOut = $true
$timedOutArtifact.TerminationReason = 'Idle resource sampling exceeded its bounded window.'
$timedOutAdmission = Test-V07MeasurementArtifactAdmission -Artifact $timedOutArtifact
$timedOutFinalization = ConvertTo-V07RuntimeBudgetReport -MeasurementArtifact $timedOutArtifact -SoakArtifact (New-V07SyntheticSoakArtifact -MeasurementArtifact $timedOutArtifact) -RepositoryRoot $repositoryRoot -CandidateDirectory $candidateDirectory
Assert-Test -Name 'Timed-out run admits no evidence and cannot finalize' -Condition ((-not $timedOutAdmission.Valid) -and (-not $timedOutFinalization.CanFinalize))

Write-Host "`n========================================================================"
Write-Host "Test Summary: $passCount passed, $failCount failed of $testCount total tests."
Write-Host "========================================================================`n"

if ($failCount -gt 0) {
    throw "Performance measurement producer suite failed: $failCount test(s) failed."
}
