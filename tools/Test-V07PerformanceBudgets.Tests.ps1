# HerdrOps v0.7 Performance Budget Unit and Regression Tests
# Issue #39: Non-Runtime Preparation for Performance Budgets and 8-Hour Soak Contract

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$fixturesDirectory = Join-Path $repositoryRoot 'tests\fixtures\v0.7\budgets'
$policyPath = Join-Path $PSScriptRoot 'lib\V07PerformanceBudgetPolicy.ps1'

if (-not (Test-Path -LiteralPath $policyPath -PathType Leaf)) {
    throw "Required policy module missing: $policyPath"
}
. $policyPath

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
Write-Host "HerdrOps v0.7 Performance Budget Policy & Gate Test Suite (Issue #39)"
Write-Host "========================================================================`n"

$textHash = Get-Sha256DigestHex -Text 'HerdrOps-v0.7.0-Budget-Test'
Assert-Test -Name 'Get-Sha256DigestHex for text' -Condition ($textHash -eq '743aafac048a3c889900346359bfc7425f4a8d6e42a15d34189d0da4ea0988e0')

$passFixturePath = Join-Path $fixturesDirectory 'passing-budget-report.json'
$fileHash = Get-Sha256DigestHex -Path $passFixturePath
Assert-Test -Name 'Get-Sha256DigestHex for file' -Condition ($fileHash -match '^[0-9a-f]{64}$')

$normalizedHash = ConvertTo-NormalizedSha256Hex -Value $textHash.ToUpperInvariant()
Assert-Test -Name 'ConvertTo-NormalizedSha256Hex converts to lowercase' -Condition ($normalizedHash -eq $textHash)

# Section 2: Path Safety and Reparse Point Protections
Write-Host "`nSection 2: Path Safety and Reparse Point Protections"
$safePath = Assert-PathWithinRoot -Path (Join-Path $repositoryRoot 'tools\Test-V07PerformanceBudgets.ps1') -AllowedRoots @($repositoryRoot)
Assert-Test -Name 'Assert-PathWithinRoot accepts path inside repository root' -Condition ($safePath.StartsWith($repositoryRoot, [StringComparison]::OrdinalIgnoreCase))

$pathTraversalCaught = $false
try {
    $null = Assert-PathWithinRoot -Path (Join-Path $repositoryRoot '..\..\..\escaped-file.txt') -AllowedRoots @($repositoryRoot)
} catch {
    $pathTraversalCaught = $true
}
Assert-Test -Name 'Assert-PathWithinRoot rejects path traversal containing ..' -Condition $pathTraversalCaught

# Section 3: P95 Math Engine
Write-Host "`nSection 3: P95 Calculation Engine"
$sampleValues = [double[]]@(10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120, 130, 140, 150, 160, 170, 180, 190, 200)
$computedP95 = [HerdrOps.BudgetValidation.StrictJsonValidator]::CalculateP95($sampleValues)
Assert-Test -Name 'CalculateP95 computes correct 95th percentile' -Condition ($computedP95 -eq 190.0)

# Section 4: Strict Schema & Duplicate Key Detection
Write-Host "`nSection 4: Strict JSON Schema & Duplicate Key Detection"
$validJson = Get-BoundedUtf8FileText -Path $passFixturePath
$parsedValid = ConvertFrom-StrictPerformanceBudgetJson -JsonText $validJson -SourceDescription 'Passing report'
Assert-Test -Name 'ConvertFrom-StrictPerformanceBudgetJson parses valid report' -Condition ($parsedValid.SchemaVersion -eq 'v0.7.0')

$dupKeyJson = Get-BoundedUtf8FileText -Path (Join-Path $fixturesDirectory 'schema-duplicate-key.json')
$dupKeyCaught = $false
try {
    $null = ConvertFrom-StrictPerformanceBudgetJson -JsonText $dupKeyJson -SourceDescription 'Duplicate key fixture'
} catch {
    $dupKeyCaught = $_.Exception.Message -match 'Duplicate property'
}
Assert-Test -Name 'ConvertFrom-StrictPerformanceBudgetJson rejects duplicate property' -Condition $dupKeyCaught

$unknownPropJson = Get-BoundedUtf8FileText -Path (Join-Path $fixturesDirectory 'schema-unknown-property.json')
$unknownPropCaught = $false
try {
    $null = ConvertFrom-StrictPerformanceBudgetJson -JsonText $unknownPropJson -SourceDescription 'Unknown prop fixture'
} catch {
    $unknownPropCaught = $_.Exception.Message -match 'Disallowed unknown'
}
Assert-Test -Name 'ConvertFrom-StrictPerformanceBudgetJson rejects unknown property' -Condition $unknownPropCaught

$negMetricJson = Get-BoundedUtf8FileText -Path (Join-Path $fixturesDirectory 'schema-negative-metric.json')
$negMetricCaught = $false
try {
    $null = ConvertFrom-StrictPerformanceBudgetJson -JsonText $negMetricJson -SourceDescription 'Negative metric fixture'
} catch {
    $negMetricCaught = $_.Exception.Message -match 'must be >= 0'
}
Assert-Test -Name 'ConvertFrom-StrictPerformanceBudgetJson rejects negative metric' -Condition $negMetricCaught

# Section 5: Budget Evaluations and Waivers
Write-Host "`nSection 5: Budget Evaluations and Waivers"
$evalPass = Test-PerformanceBudgetReport -ReportObject $parsedValid
Assert-Test -Name 'Passing report passes all 8 Plan target budgets' -Condition ($evalPass.Passed -and $evalPass.OverallStatus -eq 'PASS')

$waivedJson = Get-BoundedUtf8FileText -Path (Join-Path $fixturesDirectory 'waived-budget-report.json')
$parsedWaived = ConvertFrom-StrictPerformanceBudgetJson -JsonText $waivedJson -SourceDescription 'Waived report'
$evalWaived = Test-PerformanceBudgetReport -ReportObject $parsedWaived
Assert-Test -Name 'Valid waiver transitions failing metric to PASS (WAIVED)' -Condition ($evalWaived.Passed -and $evalWaived.OverallStatus -eq 'PASS (WITH WAIVER)')

$trimWaiverJson = Get-BoundedUtf8FileText -Path (Join-Path $fixturesDirectory 'disallowed-native-trim-waiver-fail.json')
$parsedTrimWaiver = ConvertFrom-StrictPerformanceBudgetJson -JsonText $trimWaiverJson -SourceDescription 'Trim waiver report'
$evalTrimWaiver = Test-PerformanceBudgetReport -ReportObject $parsedTrimWaiver
Assert-Test -Name 'Disallowed native trim waiver is rejected' -Condition (-not $evalTrimWaiver.Passed)

# Section 6: Exact Boundary and +Epsilon Failures
Write-Host "`nSection 6: Exact Boundaries and +Epsilon Failures"
$exactBoundaryJson = Get-BoundedUtf8FileText -Path (Join-Path $fixturesDirectory 'boundary-exact-pass.json')
$parsedExact = ConvertFrom-StrictPerformanceBudgetJson -JsonText $exactBoundaryJson -SourceDescription 'Exact boundary report'
$evalExact = Test-PerformanceBudgetReport -ReportObject $parsedExact
Assert-Test -Name 'Exact boundary thresholds pass without waiver' -Condition ($evalExact.Passed -and $evalExact.OverallStatus -eq 'PASS')

$cpuEpsJson = Get-BoundedUtf8FileText -Path (Join-Path $fixturesDirectory 'boundary-cpu-plus-epsilon-fail.json')
$parsedCpuEps = ConvertFrom-StrictPerformanceBudgetJson -JsonText $cpuEpsJson -SourceDescription 'CPU epsilon report'
$evalCpuEps = Test-PerformanceBudgetReport -ReportObject $parsedCpuEps
Assert-Test -Name 'CPU 1.001% (+epsilon) fails closed' -Condition (-not $evalCpuEps.Passed)

$wsEpsJson = Get-BoundedUtf8FileText -Path (Join-Path $fixturesDirectory 'boundary-ws-plus-epsilon-fail.json')
$parsedWsEps = ConvertFrom-StrictPerformanceBudgetJson -JsonText $wsEpsJson -SourceDescription 'WS epsilon report'
$evalWsEps = Test-PerformanceBudgetReport -ReportObject $parsedWsEps
Assert-Test -Name 'Working set 188,743,681 bytes (+1 byte) fails closed' -Condition (-not $evalWsEps.Passed)

$latEpsJson = Get-BoundedUtf8FileText -Path (Join-Path $fixturesDirectory 'boundary-latency-plus-epsilon-fail.json')
$parsedLatEps = ConvertFrom-StrictPerformanceBudgetJson -JsonText $latEpsJson -SourceDescription 'Latency epsilon report'
$evalLatEps = Test-PerformanceBudgetReport -ReportObject $parsedLatEps
Assert-Test -Name 'Latency 250.1 ms (+epsilon) fails closed' -Condition (-not $evalLatEps.Passed)

$launchEpsJson = Get-BoundedUtf8FileText -Path (Join-Path $fixturesDirectory 'boundary-launch-plus-epsilon-fail.json')
$parsedLaunchEps = ConvertFrom-StrictPerformanceBudgetJson -JsonText $launchEpsJson -SourceDescription 'Launch epsilon report'
$evalLaunchEps = Test-PerformanceBudgetReport -ReportObject $parsedLaunchEps
Assert-Test -Name 'Cold launch 2000.1 ms (+epsilon) fails closed' -Condition (-not $evalLaunchEps.Passed)

$recEpsJson = Get-BoundedUtf8FileText -Path (Join-Path $fixturesDirectory 'boundary-reconnect-plus-epsilon-fail.json')
$parsedRecEps = ConvertFrom-StrictPerformanceBudgetJson -JsonText $recEpsJson -SourceDescription 'Reconnect epsilon report'
$evalRecEps = Test-PerformanceBudgetReport -ReportObject $parsedRecEps
Assert-Test -Name 'Reconnect 5.001 s (+epsilon) fails closed' -Condition (-not $evalRecEps.Passed)

# Section 7: Advanced Negative Verifications (P95 Tamper, PID Reuse, Faults)
Write-Host "`nSection 7: Advanced Negative Verifications (P95 Tamper, PID Reuse, Faults)"
$p95TamperJson = Get-BoundedUtf8FileText -Path (Join-Path $fixturesDirectory 'p95-tampered-sample-fail.json')
$parsedP95Tamper = ConvertFrom-StrictPerformanceBudgetJson -JsonText $p95TamperJson -SourceDescription 'p95 tamper report'
$evalP95Tamper = Test-PerformanceBudgetReport -ReportObject $parsedP95Tamper
Assert-Test -Name 'P95 recomputation discrepancy fails closed' -Condition (-not $evalP95Tamper.Passed)

$pidReuseJson = Get-BoundedUtf8FileText -Path (Join-Path $fixturesDirectory 'pid-reuse-tampered-fail.json')
$parsedPidReuse = ConvertFrom-StrictPerformanceBudgetJson -JsonText $pidReuseJson -SourceDescription 'PID reuse report'
$evalPidReuse = Test-PerformanceBudgetReport -ReportObject $parsedPidReuse
Assert-Test -Name 'PID reuse with altered start time fails closed' -Condition (-not $evalPidReuse.Passed)

$unrecJson = Get-BoundedUtf8FileText -Path (Join-Path $fixturesDirectory 'unreconciled-state-fail.json')
$parsedUnrec = ConvertFrom-StrictPerformanceBudgetJson -JsonText $unrecJson -SourceDescription 'Unreconciled report'
$evalUnrec = Test-PerformanceBudgetReport -ReportObject $parsedUnrec
Assert-Test -Name 'Unreconciled state fails closed' -Condition (-not $evalUnrec.Passed)

# Section 8: Deterministic Self-Test Suite Invocation
Write-Host "`nSection 8: Full Deterministic Self-Test Suite"
$selfTestResults = @(Invoke-PerformanceBudgetSelfTests -RepositoryRoot $repositoryRoot -FixturesDirectory $fixturesDirectory)
$allStPassed = @($selfTestResults | Where-Object Status -ne 'PASS').Count -eq 0
Assert-Test -Name "Invoke-PerformanceBudgetSelfTests runs all $($selfTestResults.Count) fixtures" -Condition ($allStPassed -and $selfTestResults.Count -eq 27)
Write-Host "`n========================================================================"
Write-Host "Test Summary: $passCount passed, $failCount failed of $testCount total tests."
Write-Host "========================================================================`n"

if ($failCount -gt 0) {
    throw "Performance budget unit/regression suite failed: $failCount test(s) failed."
}
