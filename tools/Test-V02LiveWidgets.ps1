[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',

    [switch]$SkipBuild,

    [string]$RunToken = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$artifactRoot = Join-Path $repositoryRoot 'artifacts'
$testResultRoot = Join-Path $artifactRoot 'test-results'
$gateDirectory = Join-Path $artifactRoot 'release-gates\v0.2.0\issue-10'
. (Join-Path $PSScriptRoot 'lib\V02LiveWidgetsProvenance.ps1')

$sourceCommit = Get-V02LiveWidgetsSourceCommit -RepositoryRoot $repositoryRoot

if ([string]::IsNullOrWhiteSpace($RunToken)) {
    $RunToken = [string]$env:HERDOPS_V02_LIVE_WIDGET_RUN_TOKEN
}

if (-not $SkipBuild) {
    if ([string]::IsNullOrWhiteSpace($RunToken)) {
        $RunToken = [guid]::NewGuid().ToString('N')
    }
    if ($RunToken -notmatch '^[A-Za-z0-9._-]{8,128}$') {
        throw 'RunToken must be an explicit safe token of 8-128 characters.'
    }
    $env:HERDOPS_V02_LIVE_WIDGET_RUN_TOKEN = $RunToken
    $env:HERDOPS_V02_LIVE_WIDGET_SOURCE_COMMIT = $sourceCommit

    $buildStartedUtc = [DateTimeOffset]::UtcNow

    & (Join-Path $PSScriptRoot 'Invoke-Build.ps1') -Configuration $Configuration -VerifyFormat
    if ($LASTEXITCODE -ne 0) {
        throw "v0.2 live-widgets implementation gate failed with exit code $LASTEXITCODE."
    }

    $buildFinishedUtc = [DateTimeOffset]::UtcNow
    if ($buildFinishedUtc -le $buildStartedUtc) {
        $buildFinishedUtc = $buildStartedUtc.AddSeconds(1)
    }

    $null = New-V02LiveWidgetsRunManifest `
        -ArtifactRoot $artifactRoot `
        -SourceCommit $sourceCommit `
        -RunToken $RunToken `
        -StartedUtc $buildStartedUtc `
        -FinishedUtc $buildFinishedUtc
}
else {
    $captureMetadataPath = Join-Path $gateDirectory 'live-widget-captures.json'
    $measurementMetadataPath = Join-Path $gateDirectory 'live-widget-measurement.json'

    if (-not (Test-Path -LiteralPath $captureMetadataPath -PathType Leaf)) {
        throw "Required captures metadata is missing: $captureMetadataPath"
    }
    if (-not (Test-Path -LiteralPath $measurementMetadataPath -PathType Leaf)) {
        throw "Required measurement metadata is missing: $measurementMetadataPath"
    }

    $capturesMetadata = Read-V02LiveWidgetsJson -Path $captureMetadataPath
    $measurementMetadata = Read-V02LiveWidgetsJson -Path $measurementMetadataPath

    if ([string]$capturesMetadata.SourceCommit -cne $sourceCommit) {
        throw "Evidence metadata source commit does not match HEAD: captures"
    }
    if ([string]$measurementMetadata.SourceCommit -cne $sourceCommit) {
        throw "Evidence metadata source commit does not match HEAD: measurement"
    }

    if ([string]::IsNullOrWhiteSpace($RunToken)) {
        $RunToken = [string]$capturesMetadata.RunToken
    }

    if ($RunToken -notmatch '^[A-Za-z0-9._-]{8,128}$') {
        throw 'RunToken must be an explicit safe token of 8-128 characters.'
    }

    if ([string]$capturesMetadata.RunToken -cne $RunToken) {
        throw "Evidence metadata token does not match the requested run: captures"
    }
    if ([string]$measurementMetadata.RunToken -cne $RunToken) {
        throw "Evidence metadata token does not match the requested run: measurement"
    }

    $captureTimestamp = Convert-ToV02UtcDateTimeOffset -Value $capturesMetadata.GeneratedUtc
    $measurementTimestamp = Convert-ToV02UtcDateTimeOffset -Value $measurementMetadata.GeneratedUtc

    $invocationWindow = Get-V02LiveWidgetsInvocationWindow `
        -TestResultDirectory $testResultRoot `
        -EvidenceTimestamps @($captureTimestamp, $measurementTimestamp)

    $null = New-V02LiveWidgetsRunManifest `
        -ArtifactRoot $artifactRoot `
        -SourceCommit $sourceCommit `
        -RunToken $RunToken `
        -StartedUtc $invocationWindow.StartedUtc `
        -FinishedUtc $invocationWindow.FinishedUtc
}

$manifestPath = Get-V02LiveWidgetsRunManifestPath -ArtifactRoot $artifactRoot
$manifest = Read-V02LiveWidgetsJson -Path $manifestPath
$runWindow = Assert-V02LiveWidgetsRunManifest -Manifest $manifest -ExpectedCommit $sourceCommit -ExpectedToken $RunToken
$runStartedUtc = $runWindow.StartedUtc
$runFinishedUtc = $runWindow.FinishedUtc

$testResults = @(Get-V02LiveWidgetsTrxSet -Directory $testResultRoot -StartedUtc $runStartedUtc -FinishedUtc $runFinishedUtc)

$combinedTestLog = ($testResults | ForEach-Object {
    Get-Content -LiteralPath $_.FullName -Raw
}) -join "`n"
$requiredChecks = @(
    'AppOwnsCoreSubscriptionInsteadOfDashboardShell',
    'NormalModeDeclaresNoHttpServerOrAdministratorRequirement',
    'DashboardAndWidgetsUseTheSameSnapshotSelectionAndLatency',
    'CoreOfflineMakesWidgetCountsAndAgentStatusesFailClosed',
    'HerdrReconnectHealthFailsClosedWithoutDiscardingLastKnownState',
    'ConnectedCoreWithoutAdmittedHerdrStateKeepsWidgetCountsUnknown',
    'BlockedAndDoneAttentionBadgesRemainDistinct',
    'WidgetTelemetryKeepsBoundedSamplesAndComputesP95',
    'AppRuntimeOwnsSubscriptionWithoutDashboardWindowLifetime',
    'LiveCompactNormalAndFloatingVerticalRenderFromSharedCoreState',
    'LiveWidgetBindingsRefreshWhenSameStateReceivesLaterSnapshot',
    'ContractBackedWidgetAdapterP95StaysWithinReleaseTarget',
    'WidgetWindowsUseBoundedAndReversibleBehavior',
    'CriticalWidgetFidelityActionsRemainVisible',
    'RuntimeEvidenceOptionsRequireExplicitOutputsAndCoreProcess',
    'RuntimeEvidenceOptionsRejectUnknownOrUnsafeValues'
)
foreach ($check in $requiredChecks) {
    if ($combinedTestLog -notmatch [Regex]::Escape($check)) {
        throw "Required v0.2 live-widgets check is absent from the test log: $check"
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

$captureDirectory = Join-Path $artifactRoot 'design-evidence\v0.2.0\issue-10\contract-backed-wpf'
$gateDirectory = Join-Path $artifactRoot 'release-gates\v0.2.0\issue-10'
$captureMetadata = Read-V02LiveWidgetsJson -Path (Join-Path $gateDirectory 'live-widget-captures.json')
Assert-V02LiveWidgetsEvidenceMetadata `
    -Metadata $captureMetadata `
    -ExpectedKind 'captures' `
    -ExpectedCommit $sourceCommit `
    -ExpectedToken $RunToken `
    -EvidenceDirectory $captureDirectory `
    -ExpectedNames @('compact.png', 'normal.png', 'floating-vertical.png') `
    -StartedUtc $runStartedUtc `
    -FinishedUtc $runFinishedUtc
$requiredCaptures = @(
    'compact.png',
    'normal.png',
    'floating-vertical.png'
)
$captureEvidence = foreach ($captureName in $requiredCaptures) {
    $capturePath = Join-Path $captureDirectory $captureName
    if (-not (Test-Path -LiteralPath $capturePath -PathType Leaf)) {
        throw "Required contract-backed WPF capture is missing: $capturePath"
    }
    if ((Get-Item -LiteralPath $capturePath).Length -le 4000) {
        throw "Contract-backed WPF capture is unexpectedly small: $capturePath"
    }

    [pscustomobject]@{
        Name = $captureName
        Sha256 = (Get-FileHash -LiteralPath $capturePath -Algorithm SHA256).Hash
    }
}

$measurementPath = Join-Path $artifactRoot 'performance-evidence\v0.2.0\issue-10\contract-backed-widget-measurement.txt'
if (-not (Test-Path -LiteralPath $measurementPath -PathType Leaf)) {
    throw "Required contract-backed widget measurement is missing: $measurementPath"
}
$measurement = Get-Content -LiteralPath $measurementPath -Raw
$measurementMetadata = Read-V02LiveWidgetsJson -Path (Join-Path $gateDirectory 'live-widget-measurement.json')
Assert-V02LiveWidgetsEvidenceMetadata `
    -Metadata $measurementMetadata `
    -ExpectedKind 'measurement' `
    -ExpectedCommit $sourceCommit `
    -ExpectedToken $RunToken `
    -EvidenceDirectory (Split-Path -Parent $measurementPath) `
    -ExpectedNames @('contract-backed-widget-measurement.txt') `
    -StartedUtc $runStartedUtc `
    -FinishedUtc $runFinishedUtc
$requiredMeasurementMarkers = @(
    'EvidenceClass: Synthetic',
    'Samples: 200',
    'SyntheticTargetResult: PASS',
    'ActualHerdrRuntime: NOT OBSERVED / NOT CLAIMED',
    'ReferenceHostLatency: PENDING',
    'CorePlusAppResourceBudget: PENDING',
    'ActualRuntimeGate: PENDING'
)
foreach ($marker in $requiredMeasurementMarkers) {
    if ($measurement -notmatch [Regex]::Escape($marker)) {
        throw "Required measurement boundary is absent: $marker"
    }
}
$p95Match = [Regex]::Match($measurement, '(?m)^P95Ms: (?<value>[0-9]+(?:\.[0-9]+)?)\r?$')
if (-not $p95Match.Success) {
    throw 'The contract-backed widget measurement does not contain a parseable P95Ms value.'
}
$p95Milliseconds = [double]::Parse(
    $p95Match.Groups['value'].Value,
    [Globalization.CultureInfo]::InvariantCulture)
if ($p95Milliseconds -gt 250) {
    throw "Contract-backed widget adapter p95 exceeds 250 ms: $p95Milliseconds"
}
$measurementHash = (Get-FileHash -LiteralPath $measurementPath -Algorithm SHA256).Hash

New-Item -ItemType Directory -Path $gateDirectory -Force | Out-Null
$reportPath = Join-Path $gateDirectory 'gate-report.txt'
$commit = $sourceCommit

$report = @(
    'HerdrOps v0.2 Issue #10 Live Widgets Implementation Gate',
    "GeneratedUtc: $([DateTime]::UtcNow.ToString('O'))",
    "Commit: $commit",
    "RunToken: $RunToken",
    "RunStartedUtc: $($runStartedUtc.ToString('O'))",
    "RunFinishedUtc: $($runFinishedUtc.ToString('O'))",
    'Result: IMPLEMENTATION READY / PARTIAL',
    'ImplementationGate: PASS',
    'IssueAcceptance: PENDING',
    'EvidenceClass: Contract-backed Integration plus Synthetic WPF Rendering and Measurement',
    'ActualHerdrRuntime: NOT OBSERVED / NOT CLAIMED',
    'ActualLiveWidgetCapture: PENDING',
    'ReferenceHostLatency: PENDING',
    'CorePlusAppResourceBudget: PENDING',
    'ActualRuntimeGate: PENDING',
    'IssueStateRequired: OPEN',
    "Tests: $passedTests/$totalTests PASS",
    'WidgetStateSource: one App-owned per-user Core-to-App protocol v2 subscription',
    'DashboardWidgetConsistency: Dashboard and Widgets share one LiveDashboardState snapshot and selection',
    'RequiredLiveVariants: Compact, Normal, Floating Vertical',
    'NoSnapshotPolicy: a connected Core with no admitted Herdr state renders counts Unknown',
    'OfflinePolicy: counts, status notices and current Agent status fail closed while identity remains last-known',
    'AttentionPolicy: Blocked and Done retain distinct glyphs and semantic brushes',
    'HerdrRuntimeFreshness: explicit Core-projected Connected/Reconnecting/Stopped health',
    "ContractBackedWidgetAdapterP95Ms: $($p95Milliseconds.ToString('0.000', [Globalization.CultureInfo]::InvariantCulture))",
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
    "SHA256 $measurementHash contract-backed-widget-measurement.txt",
    '',
    'EvidenceBoundary:',
    'This gate proves Compact, Normal and Floating Vertical consume the exact same App-owned Core state as Dashboard, update on the same state object, fail closed when Core disconnects, keep Blocked and Done attention distinct, expose all Agents through scrolling, and preserve bounded window behavior.',
    'The latency value measures synchronous in-process contract-to-widget adapter work only. It is not end-to-end Herdr-to-screen latency and does not measure Core plus App resource usage.',
    'The WPF captures and timing report are contract-backed Synthetic evidence, not captures from an actual Herdr runtime or the reference Windows host.',
    'Issue #10 must remain open until an actual live-widget capture, end-to-end reference-host latency, Core-plus-App resource measurements and the version-local runtime gate are independently accepted.'
)
$report | Set-Content -LiteralPath $reportPath -Encoding utf8
$report | Write-Output
Write-Output "GateReport: $reportPath"
