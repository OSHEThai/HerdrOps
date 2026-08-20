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

function New-RuntimeJsonFromPassingFixture {
    param(
        [string]$CoreBinaryRelativePath = 'artifacts/bin/HerdrOps.Core/release/HerdrOps.Core.dll',
        [long]$CorePid = 41001,
        [long]$AppPid = 41002
    )

    $json = Get-BoundedUtf8FileText -Path $passFixturePath -Description 'Runtime JSON regression fixture'
    $base = $json | ConvertFrom-Json
    $head = (git -C $repositoryRoot rev-parse HEAD).Trim()
    $json = $json -replace '"SourceCommit":\s*"[0-9a-f]{40}"', ('"SourceCommit": "' + $head + '"')
    $json = $json.Replace('"EvidenceClass": "Preparation"', '"EvidenceClass": "Runtime"')
    $json = $json.Replace('"ActualHerdrRuntime": "NOT OBSERVED / NOT CLAIMED"', '"ActualHerdrRuntime": "OBSERVED"')
    $json = $json.Replace('"SoakExecution": "NOT OBSERVED / NOT CLAIMED"', '"SoakExecution": "OBSERVED"')

    $metricsInsertion = '"DashboardColdLaunchP95Ms": 1320.0,' + [Environment]::NewLine +
        '    "WidgetDeltaLatencySamplesMs": [145.2, 145.2, 145.2],' + [Environment]::NewLine +
        '    "DashboardColdLaunchSamplesMs": [1320.0, 1320.0, 1320.0],'
    $json = $json.Replace('"DashboardColdLaunchP95Ms": 1320.0,', $metricsInsertion)

    $coreBinary = @($base.Candidate.Binaries | Where-Object { $_.RelativePath -eq $CoreBinaryRelativePath })[0]
    if ($null -eq $coreBinary) { throw "Runtime regression candidate binary missing from fixture: $CoreBinaryRelativePath" }
    $appBinary = @($base.Candidate.Binaries | Where-Object { $_.RelativePath -like '*HerdrOps.App/release/HerdrOps.App.dll' })[0]
    $corePath = (Join-Path $repositoryRoot $CoreBinaryRelativePath).Replace('\', '\\')
    $appPath = (Join-Path $repositoryRoot $appBinary.RelativePath).Replace('\', '\\')
    $telemetry = @"
  "ProcessTelemetry": [
    {
      "ProcessName": "HerdrOps.Core",
      "ProcessId": $CorePid,
      "ProcessStartUtc": "2020-01-01T12:00:00Z",
      "BinaryPath": "$corePath",
      "BinarySha256": "$($coreBinary.Sha256)"
    },
    {
      "ProcessName": "HerdrOps.App",
      "ProcessId": $AppPid,
      "ProcessStartUtc": "2020-01-01T12:00:01Z",
      "BinaryPath": "$appPath",
      "BinarySha256": "$($appBinary.Sha256)"
    }
  ],
"@
    return $json.Replace('  "EvidenceBoundary":', $telemetry + '  "EvidenceBoundary":')
}

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

# Section 1: Cryptographic Hashes and Normalization
Write-Host "Section 1: Cryptographic Hashes and Normalization"
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
$evalPass = Test-PerformanceBudgetReport -ReportObject $parsedValid -CandidateDirectory (Join-Path $repositoryRoot 'artifacts\bin') -RepositoryRoot $repositoryRoot -ExpectedSourceCommit ([string]$parsedValid.Candidate.SourceCommit)
Assert-Test -Name 'Passing report passes all 8 Plan target budgets' -Condition ($evalPass.Passed -and $evalPass.OverallStatus -eq 'PASS')

$waivedJson = Get-BoundedUtf8FileText -Path (Join-Path $fixturesDirectory 'waived-budget-report.json')
$parsedWaived = ConvertFrom-StrictPerformanceBudgetJson -JsonText $waivedJson -SourceDescription 'Waived report'
$evalWaived = Test-PerformanceBudgetReport -ReportObject $parsedWaived -CandidateDirectory (Join-Path $repositoryRoot 'artifacts\bin') -RepositoryRoot $repositoryRoot -ExpectedSourceCommit ([string]$parsedWaived.Candidate.SourceCommit)
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

# Section 8: Zero-Hour Soak vs 8-Hour Soak Boundary (Preparation vs Runtime Admission)
Write-Host "`nSection 8: Zero-Hour Soak vs 8-Hour Soak Boundary"
$prep0hReport = ConvertFrom-StrictPerformanceBudgetJson -JsonText $validJson -SourceDescription 'Prep 0h'
$prep0hReport.Metrics.SoakDurationHours = 0.0
$prep0hReport.EvidenceClass = 'Preparation'
$evalPrep0h = Test-PerformanceBudgetReport -ReportObject $prep0hReport -CandidateDirectory (Join-Path $repositoryRoot 'artifacts\bin') -RepositoryRoot $repositoryRoot -ExpectedSourceCommit ([string]$prep0hReport.Candidate.SourceCommit)
$prep0hCheck = @($evalPrep0h.Checks | Where-Object Id -eq 'V07-PERF-07-SOAK')[0]
Assert-Test -Name 'Zero-hour soak in Preparation reports NOT OBSERVED (never PASS as runtime)' -Condition ($evalPrep0h.Passed -and $prep0hCheck.Status -eq 'NOT OBSERVED')

$run0hReport = ConvertFrom-StrictPerformanceBudgetJson -JsonText $validJson -SourceDescription 'Runtime 0h'
$run0hReport.Metrics.SoakDurationHours = 0.0
$run0hReport.EvidenceClass = 'Runtime'
$run0hReport.EvidenceBoundary.ActualHerdrRuntime = 'OBSERVED'
$run0hReport.EvidenceBoundary.SoakExecution = 'OBSERVED'
$evalRun0h = Test-PerformanceBudgetReport -ReportObject $run0hReport
$run0hCheck = @($evalRun0h.Checks | Where-Object Id -eq 'V07-PERF-07-SOAK')[0]
Assert-Test -Name 'Zero-hour soak in Runtime admission cannot satisfy 8-hour requirement (fails closed)' -Condition (-not $evalRun0h.Passed -and $run0hCheck.Status -eq 'FAIL')

$run8hReport = ConvertFrom-StrictPerformanceBudgetJson -JsonText $validJson -SourceDescription 'Runtime 8h'
$run8hReport.Metrics.SoakDurationHours = 8.0
$run8hReport.Metrics | Add-Member -MemberType NoteProperty -Name WidgetDeltaLatencySamplesMs -Value @([double]145.2, [double]145.2, [double]145.2) -Force
$run8hReport.Metrics | Add-Member -MemberType NoteProperty -Name DashboardColdLaunchSamplesMs -Value @([double]1320.0, [double]1320.0, [double]1320.0) -Force
$run8hReport.EvidenceClass = 'Runtime'
$run8hReport.EvidenceBoundary.ActualHerdrRuntime = 'OBSERVED'
$run8hReport.EvidenceBoundary.SoakExecution = 'OBSERVED'
$run8hReport.Candidate.SourceCommit = Test-CleanRepositoryState -RepositoryRoot $repositoryRoot -SkipCleanCheck
$run8hReport | Add-Member -MemberType NoteProperty -Name ProcessTelemetry -Value @(
    [pscustomobject]@{ ProcessName='HerdrOps.Core'; ProcessId=[int]41001; ProcessStartUtc='2020-01-01T12:00:00Z'; BinaryPath=(Join-Path $repositoryRoot 'artifacts/bin/HerdrOps.Core/release/HerdrOps.Core.dll'); BinarySha256=[string]$run8hReport.Candidate.Binaries[0].Sha256 },
    [pscustomobject]@{ ProcessName='HerdrOps.App'; ProcessId=[int]41002; ProcessStartUtc='2020-01-01T12:00:01Z'; BinaryPath=(Join-Path $repositoryRoot 'artifacts/bin/HerdrOps.App/release/HerdrOps.App.dll'); BinarySha256=[string]$run8hReport.Candidate.Binaries[1].Sha256 }
) -Force
$evalRun8h = Test-PerformanceBudgetReport -ReportObject $run8hReport -CandidateDirectory (Join-Path $repositoryRoot 'artifacts/bin') -RepositoryRoot $repositoryRoot -ExpectedSourceCommit $run8hReport.Candidate.SourceCommit
$run8hCheck = @($evalRun8h.Checks | Where-Object Id -eq 'V07-PERF-07-SOAK')[0]
Assert-Test -Name '8-hour soak in Runtime admission passes' -Condition ($evalRun8h.Passed -and $run8hCheck.Status -eq 'PASS')

# Section 9: PowerShell 5.1 & Strict JSON Regressions
Write-Host "`nSection 9: PowerShell 5.1 & Strict JSON Regressions"
$trailingContentCaught = $false
try {
    $null = ConvertFrom-StrictPerformanceBudgetJson -JsonText ($validJson + " `n{}") -SourceDescription 'Trailing content'
} catch {
    $trailingContentCaught = $_.Exception.Message -match 'Trailing content'
}
Assert-Test -Name 'Strict JSON parser rejects trailing content' -Condition $trailingContentCaught

$trailingCommaCaught = $false
try {
    $null = ConvertFrom-StrictPerformanceBudgetJson -JsonText '{"SchemaVersion":"v0.7.0",}' -SourceDescription 'Trailing comma'
} catch {
    $trailingCommaCaught = $_.Exception.Message -match 'Trailing comma'
}
Assert-Test -Name 'Strict JSON parser rejects trailing comma in object' -Condition $trailingCommaCaught

$trailingArrayCommaCaught = $false
try {
    $null = ConvertFrom-StrictPerformanceBudgetJson -JsonText '{"SchemaVersion":"v0.7.0","Waivers":[,]}' -SourceDescription 'Trailing array comma'
} catch {
    $trailingArrayCommaCaught = $true
}
Assert-Test -Name 'Strict JSON parser rejects trailing comma in array' -Condition $trailingArrayCommaCaught

# Section 10: Hostile JSON-parsed regressions (Synthetic only; no Runtime/Release credit)
Write-Host "`nSection 10: Hostile JSON-parsed regressions (Synthetic only)"
$syntheticExpectedHead = (git -C $repositoryRoot rev-parse HEAD).Trim()
$runtimeJson = New-RuntimeJsonFromPassingFixture
$runtimeReport = ConvertFrom-StrictPerformanceBudgetJson -JsonText $runtimeJson -SourceDescription 'synthetic runtime-admission JSON'
$runtimeEval = Test-PerformanceBudgetReport -ReportObject $runtimeReport -CandidateDirectory (Join-Path $repositoryRoot 'artifacts\bin') -RepositoryRoot $repositoryRoot -ExpectedSourceCommit $syntheticExpectedHead
$expectedPidType = if ($PSVersionTable.PSVersion.Major -ge 6) { 'System.Int64' } else { 'System.Int32' }
$pidTypeIsNormalized = $runtimeReport.ProcessTelemetry[0].ProcessId.GetType().FullName -eq $expectedPidType
$pidBindingCheck = @($runtimeEval.Checks | Where-Object Id -eq 'V07-PID-BINDING')[0]
$runtimeFailures = (@($runtimeEval.Checks | Where-Object Status -notin @('PASS', 'PASS (WAIVED)') | ForEach-Object { "$($_.Id):$($_.Status)" }) -join ',')
Assert-Test -Name 'Synthetic JSON positive PID normalizes PS7 Int64 / PS5 Int32 and binds' -Condition ($pidTypeIsNormalized -and $runtimeEval.Passed -and $pidBindingCheck.Status -eq 'PASS') -Message "Parsed PID type=$($runtimeReport.ProcessTelemetry[0].ProcessId.GetType().FullName); Overall=$($runtimeEval.OverallStatus); PIDCheck=$($pidBindingCheck.Status); Failures=$runtimeFailures"

$nonPositivePidObject = ConvertFrom-StrictPerformanceBudgetJson -JsonText $runtimeJson -SourceDescription 'synthetic non-positive PID source'
$nonPositivePidObject.ProcessTelemetry[0].ProcessId = -1
$nonPositivePidJson = $nonPositivePidObject | ConvertTo-Json -Depth 20 -Compress
$nonPositivePidCaught = $false
try {
    $null = ConvertFrom-StrictPerformanceBudgetJson -JsonText $nonPositivePidJson -SourceDescription 'synthetic non-positive PID'
} catch {
    $nonPositivePidCaught = $_.Exception.Message -match 'positive integer|ProcessId'
}
Assert-Test -Name 'Synthetic JSON non-positive PID fails closed' -Condition $nonPositivePidCaught

$duplicatePidJson = New-RuntimeJsonFromPassingFixture -CorePid 41001 -AppPid 41001
$duplicatePidReport = ConvertFrom-StrictPerformanceBudgetJson -JsonText $duplicatePidJson -SourceDescription 'synthetic duplicate Core/App PID'
$duplicatePidEval = Test-PerformanceBudgetReport -ReportObject $duplicatePidReport -CandidateDirectory (Join-Path $repositoryRoot 'artifacts\bin') -RepositoryRoot $repositoryRoot -ExpectedSourceCommit $syntheticExpectedHead
$duplicatePidCheck = @($duplicatePidEval.Checks | Where-Object Id -eq 'V07-RUNTIME-PID-DISTINCT')[0]
Assert-Test -Name 'Synthetic JSON rejects shared Core/App PID' -Condition (-not $duplicatePidEval.Passed -and $duplicatePidCheck.Status -eq 'FAIL')

$roleMismatchJson = New-RuntimeJsonFromPassingFixture -CoreBinaryRelativePath 'artifacts/bin/HerdrOps.CLI/release/HerdrOps.CLI.dll'
$roleMismatchReport = ConvertFrom-StrictPerformanceBudgetJson -JsonText $roleMismatchJson -SourceDescription 'synthetic role-to-binary mismatch'
$roleMismatchEval = Test-PerformanceBudgetReport -ReportObject $roleMismatchReport -CandidateDirectory (Join-Path $repositoryRoot 'artifacts\bin') -RepositoryRoot $repositoryRoot -ExpectedSourceCommit $syntheticExpectedHead
$roleMismatchCheck = @($roleMismatchEval.Checks | Where-Object Id -eq 'V07-RUNTIME-BINARY-HerdrOps.Core')[0]
Assert-Test -Name 'Synthetic JSON rejects Core process mapped to CLI binary' -Condition (-not $roleMismatchEval.Passed -and $roleMismatchCheck.Status -eq 'FAIL')

$wrongHashObject = ConvertFrom-StrictPerformanceBudgetJson -JsonText $runtimeJson -SourceDescription 'synthetic process hash source'
$wrongHashObject.ProcessTelemetry[0].BinarySha256 = '0' * 64
$wrongHashJson = $wrongHashObject | ConvertTo-Json -Depth 20 -Compress
$wrongHashReport = ConvertFrom-StrictPerformanceBudgetJson -JsonText $wrongHashJson -SourceDescription 'synthetic process hash mismatch'
$wrongHashEval = Test-PerformanceBudgetReport -ReportObject $wrongHashReport -CandidateDirectory (Join-Path $repositoryRoot 'artifacts\bin') -RepositoryRoot $repositoryRoot -ExpectedSourceCommit $syntheticExpectedHead
$wrongHashCheck = @($wrongHashEval.Checks | Where-Object Id -eq 'V07-RUNTIME-BINARY-HerdrOps.Core')[0]
Assert-Test -Name 'Synthetic JSON rejects process binary SHA mismatch' -Condition (-not $wrongHashEval.Passed -and $wrongHashCheck.Status -eq 'FAIL')

$missingEvidenceObject = ConvertFrom-StrictPerformanceBudgetJson -JsonText $runtimeJson -SourceDescription 'synthetic missing EvidenceClass source'
[void]$missingEvidenceObject.PSObject.Properties.Remove('EvidenceClass')
$missingEvidenceJson = $missingEvidenceObject | ConvertTo-Json -Depth 20 -Compress
$missingEvidenceCaught = $false
try {
    $null = ConvertFrom-StrictPerformanceBudgetJson -JsonText $missingEvidenceJson -SourceDescription 'synthetic missing EvidenceClass'
} catch {
    $missingEvidenceCaught = $_.Exception.Message -match 'EvidenceClass'
}
Assert-Test -Name 'Synthetic JSON requires EvidenceClass' -Condition $missingEvidenceCaught

$missingHostObject = ConvertFrom-StrictPerformanceBudgetJson -JsonText $runtimeJson -SourceDescription 'synthetic missing HostEnvironment source'
[void]$missingHostObject.PSObject.Properties.Remove('HostEnvironment')
$missingHostJson = $missingHostObject | ConvertTo-Json -Depth 20 -Compress
$missingHostCaught = $false
try {
    $null = ConvertFrom-StrictPerformanceBudgetJson -JsonText $missingHostJson -SourceDescription 'synthetic missing HostEnvironment'
} catch {
    $missingHostCaught = $_.Exception.Message -match 'HostEnvironment'
}
Assert-Test -Name 'Synthetic JSON requires HostEnvironment' -Condition $missingHostCaught

$negativeLatencyObject = ConvertFrom-StrictPerformanceBudgetJson -JsonText $runtimeJson -SourceDescription 'synthetic negative latency source'
$negativeLatencyObject.Metrics.WidgetDeltaLatencySamplesMs = @(-1.0, 145.2)
$negativeLatencyJson = $negativeLatencyObject | ConvertTo-Json -Depth 20 -Compress
$negativeLatencyCaught = $false
try {
    $null = ConvertFrom-StrictPerformanceBudgetJson -JsonText $negativeLatencyJson -SourceDescription 'synthetic negative latency sample'
} catch {
    $negativeLatencyCaught = $_.Exception.Message -match 'samples must be >= 0'
}
Assert-Test -Name 'Synthetic negative latency sample fails schema' -Condition $negativeLatencyCaught

$negativeLaunchObject = ConvertFrom-StrictPerformanceBudgetJson -JsonText $runtimeJson -SourceDescription 'synthetic negative launch source'
$negativeLaunchObject.Metrics.DashboardColdLaunchSamplesMs = @(-1.0, 1320.0)
$negativeLaunchJson = $negativeLaunchObject | ConvertTo-Json -Depth 20 -Compress
$negativeLaunchCaught = $false
try {
    $null = ConvertFrom-StrictPerformanceBudgetJson -JsonText $negativeLaunchJson -SourceDescription 'synthetic negative launch sample'
} catch {
    $negativeLaunchCaught = $_.Exception.Message -match 'samples must be >= 0'
}
Assert-Test -Name 'Synthetic negative launch sample fails schema' -Condition $negativeLaunchCaught

$nonFiniteJson = $runtimeJson.Replace('[145.2, 145.2, 145.2]', '[1e999, 145.2, 145.2]')
$nonFiniteCaught = $false
try {
    $null = ConvertFrom-StrictPerformanceBudgetJson -JsonText $nonFiniteJson -SourceDescription 'synthetic non-finite latency sample'
} catch {
    $nonFiniteCaught = $true
}
Assert-Test -Name 'Synthetic non-finite latency sample fails schema' -Condition $nonFiniteCaught

$hostileIdentityObject = ConvertFrom-StrictPerformanceBudgetJson -JsonText $waivedJson -SourceDescription 'synthetic arbitrary waiver identity source'
$hostileIdentityObject.Waivers[0].ApprovedBy = '@arbitrary-identity'
$hostileIdentityObject.Waivers[0].WaiverSha256 = Get-WaiverCanonicalSha256 -Waiver $hostileIdentityObject.Waivers[0]
$hostileIdentityJson = $hostileIdentityObject | ConvertTo-Json -Depth 20 -Compress
$hostileIdentityCaught = $false
try {
    $null = ConvertFrom-StrictPerformanceBudgetJson -JsonText $hostileIdentityJson -SourceDescription 'synthetic arbitrary waiver identity'
} catch {
    $hostileIdentityCaught = $_.Exception.Message -match 'ApprovedBy'
}
Assert-Test -Name 'Synthetic arbitrary waiver identity fails Plan binding' -Condition $hostileIdentityCaught

$hostileReferenceObject = ConvertFrom-StrictPerformanceBudgetJson -JsonText $waivedJson -SourceDescription 'synthetic arbitrary waiver reference source'
$hostileReferenceObject.Waivers[0].ApprovalReference = 'Plan/UNAUTHORIZED-REFERENCE'
$hostileReferenceObject.Waivers[0].WaiverSha256 = Get-WaiverCanonicalSha256 -Waiver $hostileReferenceObject.Waivers[0]
$hostileReferenceJson = $hostileReferenceObject | ConvertTo-Json -Depth 20 -Compress
$hostileReferenceCaught = $false
try {
    $null = ConvertFrom-StrictPerformanceBudgetJson -JsonText $hostileReferenceJson -SourceDescription 'synthetic arbitrary waiver reference'
} catch {
    $hostileReferenceCaught = $_.Exception.Message -match 'ApprovalReference'
}
Assert-Test -Name 'Synthetic waiver without Plan approval reference fails closed' -Condition $hostileReferenceCaught

$missingBinaryObject = ConvertFrom-StrictPerformanceBudgetJson -JsonText $validJson -SourceDescription 'synthetic missing candidate binary source'
$missingBinaryObject.Candidate.Binaries[0].RelativePath = 'artifacts/bin/missing-core.dll'
$missingBinaryJson = $missingBinaryObject | ConvertTo-Json -Depth 20 -Compress
$missingBinaryReport = ConvertFrom-StrictPerformanceBudgetJson -JsonText $missingBinaryJson -SourceDescription 'synthetic missing candidate binary'
$missingBinaryEval = Test-PerformanceBudgetReport -ReportObject $missingBinaryReport -CandidateDirectory (Join-Path $repositoryRoot 'artifacts\bin') -RepositoryRoot $repositoryRoot -ExpectedSourceCommit ([string]$missingBinaryReport.Candidate.SourceCommit)
$missingBinaryCheck = @($missingBinaryEval.Checks | Where-Object Id -eq 'V07-CANDIDATE-HASH-missing-core')[0]
$missingBinaryBinding = @($missingBinaryEval.CandidateBindings | Where-Object Path -eq 'artifacts/bin/missing-core.dll')[0]
Assert-Test -Name 'Synthetic non-runtime missing candidate binary is NOT_VERIFIED and fails' -Condition (-not $missingBinaryEval.Passed -and $missingBinaryCheck.Status -eq 'FAIL' -and $missingBinaryBinding.Status -eq 'NOT_VERIFIED')

$missingRootEval = Test-PerformanceBudgetReport -ReportObject $parsedValid -ExpectedSourceCommit ([string]$parsedValid.Candidate.SourceCommit)
$missingRootCheck = @($missingRootEval.Checks | Where-Object Id -eq 'V07-CANDIDATE-BINARY-ROOTS')[0]
Assert-Test -Name 'Synthetic declared binaries without verification roots fail and never bind' -Condition (-not $missingRootEval.Passed -and $missingRootCheck.Status -eq 'FAIL' -and @($missingRootEval.CandidateBindings).Count -eq 0)

# Section 11: Plan ApprovalReference anchor resolution (CommonMark heading hygiene)
Write-Host "`nSection 11: Plan ApprovalReference anchor resolution"
function ConvertTo-CommonMarkAnchor {
    param([Parameter(Mandatory)][string]$HeadingText)
    $slug = $HeadingText.ToLowerInvariant().Trim()
    $slug = [regex]::Replace($slug, '[^\w\- ]+', '')
    $slug = [regex]::Replace($slug, '\s+', '-')
    $slug = [regex]::Replace($slug, '-+', '-')
    $slug = [regex]::Replace($slug, '^-+|-+$', '')
    return $slug
}

$releaseGatesPath = Join-Path $repositoryRoot 'Plan\RELEASE-GATES.md'
$releaseGatesText = Get-BoundedUtf8FileText -Path $releaseGatesPath -Description 'Plan RELEASE-GATES authority record'
$planHeadingAnchors = @()
foreach ($line in ($releaseGatesText -split "`n")) {
    if ($line -match '^\s*###\s+(.+)$') {
        $planHeadingAnchors += ConvertTo-CommonMarkAnchor -HeadingText $Matches[1].Trim()
    }
}

$planHeadingText = 'v0.7 performance waiver authority'
$computedAnchor = ConvertTo-CommonMarkAnchor -HeadingText $planHeadingText
$boundReferenceFragment = 'v07-performance-waiver-authority'
$fragmentOfBoundReference = [regex]::Match($script:V07PlanWaiverAuthorityReference, '#(.+)$').Groups[1].Value
Assert-Test -Name 'Plan Performance waiver heading resolves exact bound ApprovalReference fragment' -Condition (
    $computedAnchor -eq $boundReferenceFragment -and
    $fragmentOfBoundReference -eq $boundReferenceFragment -and
    ($planHeadingAnchors -contains $boundReferenceFragment)
) -Message "computed=$computedAnchor; bound-fragment=$fragmentOfBoundReference; Plan anchors present: $($planHeadingAnchors -join ',')"

# Section 12: Deterministic Self-Test Suite Invocation
Write-Host "`nSection 12: Full Deterministic Self-Test Suite"
$selfTestResults = @(Invoke-PerformanceBudgetSelfTests -RepositoryRoot $repositoryRoot -FixturesDirectory $fixturesDirectory)
$allStPassed = @($selfTestResults | Where-Object Status -ne 'PASS').Count -eq 0
Assert-Test -Name "Invoke-PerformanceBudgetSelfTests runs all $($selfTestResults.Count) matrix cases" -Condition ($allStPassed -and $selfTestResults.Count -eq 36)

Write-Host "`n========================================================================"
Write-Host "Test Summary: $passCount passed, $failCount failed of $testCount total tests."
Write-Host "========================================================================`n"

if ($failCount -gt 0) {
    throw "Performance budget unit/regression suite failed: $failCount test(s) failed."
}
