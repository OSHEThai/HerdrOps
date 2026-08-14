[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',

    [switch]$SkipBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$artifactRoot = Join-Path $repositoryRoot 'artifacts'
$testResultRoot = Join-Path $artifactRoot 'test-results'

if (-not $SkipBuild) {
    & (Join-Path $PSScriptRoot 'Invoke-Build.ps1') -Configuration $Configuration -VerifyFormat
    if ($LASTEXITCODE -ne 0) {
        throw "v0.2 live-pages implementation gate failed with exit code $LASTEXITCODE."
    }
}

$testResults = @(Get-ChildItem -LiteralPath $testResultRoot -Filter '*.trx' -File |
    Sort-Object LastWriteTimeUtc -Descending |
    Select-Object -First 4)
if ($testResults.Count -lt 4) {
    throw "Expected TRX output from four test projects, found $($testResults.Count)."
}

$combinedTestLog = ($testResults | ForEach-Object {
    Get-Content -LiteralPath $_.FullName -Raw
}) -join "`n"
$requiredChecks = @(
    'ProductionProjectReferencesMatchApprovedArchitecture',
    'DashboardProcessDoesNotOwnCoreLifecycle',
    'CoreSnapshotDrivesAllThreePagesWithoutInventingUnsupportedData',
    'OfflineTransitionDoesNotLeaveLastKnownWorkingStatusCurrent',
    'OrganizationSelectionUpdatesAgentDetailFromTheSameSnapshot',
    'DashboardClientCancellationLeavesCorePipeServerRunning',
    'LiveOverviewOrganizationAndAgentDetailRenderFromOneCoreSnapshot',
    'UnsupportedHerdrFieldsRenderAsUnknownAndAgentTopologyIsKeyboardSelectable'
)
foreach ($check in $requiredChecks) {
    if ($combinedTestLog -notmatch [Regex]::Escape($check)) {
        throw "Required v0.2 live-pages check is absent from the test log: $check"
    }
}

$totalTests = 0
$passedTests = 0
$failedTests = 0
foreach ($trxFile in $testResults) {
    [xml]$trx = Get-Content -LiteralPath $trxFile.FullName -Raw
    $counters = $trx.TestRun.ResultSummary.Counters
    $totalTests += [int]$counters.total
    $passedTests += [int]$counters.passed
    $failedTests += [int]$counters.failed
}
if ($totalTests -le 0 -or $failedTests -ne 0 -or $totalTests -ne $passedTests) {
    throw "Test counters are not all passing: total=$totalTests passed=$passedTests failed=$failedTests"
}

$captureDirectory = Join-Path $artifactRoot 'design-evidence\v0.2.0\issue-9\contract-backed-wpf'
$requiredCaptures = @(
    'overview-1672x941.png',
    'overview-1366x768.png',
    'live-organization-1672x941.png',
    'live-organization-1366x768.png',
    'agent-detail-1672x941.png',
    'agent-detail-1366x768.png'
)
$captureEvidence = foreach ($captureName in $requiredCaptures) {
    $capturePath = Join-Path $captureDirectory $captureName
    if (-not (Test-Path -LiteralPath $capturePath -PathType Leaf)) {
        throw "Required contract-backed WPF capture is missing: $capturePath"
    }
    if ((Get-Item -LiteralPath $capturePath).Length -le 10000) {
        throw "Contract-backed WPF capture is unexpectedly small: $capturePath"
    }

    [pscustomobject]@{
        Name = $captureName
        Sha256 = (Get-FileHash -LiteralPath $capturePath -Algorithm SHA256).Hash
    }
}

$gateDirectory = Join-Path $artifactRoot 'release-gates\v0.2.0\issue-9'
New-Item -ItemType Directory -Path $gateDirectory -Force | Out-Null
$reportPath = Join-Path $gateDirectory 'gate-report.txt'
$commit = (& git -C $repositoryRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($commit)) {
    throw 'Could not resolve the source commit for the v0.2 live-pages implementation gate.'
}

$report = @(
    'HerdrOps v0.2 Issue #9 Live Dashboard Pages Implementation Gate',
    "GeneratedUtc: $([DateTime]::UtcNow.ToString('O'))",
    "Commit: $commit",
    'Result: IMPLEMENTATION READY / PARTIAL',
    'ImplementationGate: PASS',
    'IssueAcceptance: PENDING',
    'EvidenceClass: Contract-backed Integration plus Synthetic WPF Rendering',
    'ActualHerdrRuntime: NOT OBSERVED / NOT CLAIMED',
    'IssueStateRequired: OPEN',
    "Tests: $passedTests/$totalTests PASS",
    'DashboardStateSource: per-user Core-to-App protocol v1 stream',
    'HerdrRuntimeFreshness: UNKNOWN / NOT SUPPLIED BY PROTOCOL V1',
    'UnknownDataPolicy: unsupported fields render Unknown',
    'LifecycleBoundary: Dashboard cancellation leaves Core pipe server running',
    "ContractBackedWpfCaptures: $($requiredCaptures.Count)",
    '',
    'RequiredChecks:'
) + ($requiredChecks | ForEach-Object { "PASS $_" }) + @(
    '',
    'RequiredCaptures:'
) + ($requiredCaptures | ForEach-Object { "PASS $_" }) + @(
    '',
    'CaptureHashes:'
) + ($captureEvidence | ForEach-Object { "SHA256 $($_.Sha256) $($_.Name)" }) + @(
    '',
    'EvidenceBoundary:',
    'This gate proves one normalized Core snapshot drives Overview, Live Organization and Agent Detail; unsupported Herdr fields remain Unknown; Core-offline state is fail-closed; selection stays snapshot-consistent; and closing the Dashboard subscription does not stop the Core pipe server.',
    'Protocol v1 does not carry Herdr runtime health. A connected Dashboard therefore labels state as latest accepted by Core and does not claim current Herdr runtime freshness.',
    'The WPF captures are generated from a contract-backed test snapshot and are synthetic UI evidence, not an actual Herdr runtime capture.',
    'Issue #9 must remain open until a side-by-side actual Herdr/UI snapshot, an actual runtime screen capture, and a Dashboard-close/Core-continuity lifecycle trace are independently accepted.'
)
$report | Set-Content -LiteralPath $reportPath -Encoding utf8
$report | Write-Output
Write-Output "GateReport: $reportPath"
