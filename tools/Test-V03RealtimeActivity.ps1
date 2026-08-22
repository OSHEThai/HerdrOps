[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',

    [switch]$SkipBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$artifactRoot = Join-Path $repositoryRoot 'artifacts'
$referencePath = Join-Path $repositoryRoot 'docs\design\reference\03-realtime-activity.png'
$expectedReferenceSha256 = '1EFBF8A309665511E6BF330E736D2B4CE96791338DB2101B7723B1A5C987BD0F'

$workingTreeStatus = @(& git -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0) {
    throw 'Could not inspect the source working tree for the v0.3 Realtime Activity gate.'
}
if ($workingTreeStatus.Count -ne 0) {
    throw "The v0.3 Realtime Activity gate requires a clean committed checkout. Pending paths: $($workingTreeStatus -join ', ')"
}

if (-not $SkipBuild) {
    & (Join-Path $PSScriptRoot 'Invoke-Build.ps1') -Configuration $Configuration -VerifyFormat
    if ($LASTEXITCODE -ne 0) {
        throw "v0.3 Realtime Activity build gate failed with exit code $LASTEXITCODE."
    }
}

$runId = "$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ', [Globalization.CultureInfo]::InvariantCulture))-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
$gateDirectory = Join-Path $artifactRoot "release-gates\v0.3.0\issue-13\$runId"
$testResultDirectory = Join-Path $gateDirectory 'test-results'
New-Item -ItemType Directory -Path $testResultDirectory -Force | Out-Null

$testRuns = @(
    [pscustomobject]@{
        Project = Join-Path $repositoryRoot 'tests\HerdrOps.IntegrationTests\HerdrOps.IntegrationTests.csproj'
        Filter = 'FullyQualifiedName~RealtimeActivityStateTests'
        Log = 'realtime-activity-state.trx'
    },
    [pscustomobject]@{
        Project = Join-Path $repositoryRoot 'tests\HerdrOps.RuntimeTests\HerdrOps.RuntimeTests.csproj'
        Filter = 'FullyQualifiedName~RealtimeActivityRenderingTests'
        Log = 'realtime-activity-rendering.trx'
    },
    [pscustomobject]@{
        Project = Join-Path $repositoryRoot 'tests\HerdrOps.IntegrationTests\HerdrOps.IntegrationTests.csproj'
        Filter = 'FullyQualifiedName~HerdrRealtimeActivityRuntimeTraceCommandTests'
        Log = 'realtime-activity-runtime-trace.trx'
    }
)
foreach ($testRun in $testRuns) {
    & dotnet test $testRun.Project `
        --configuration $Configuration `
        --no-restore `
        --no-build `
        --artifacts-path $artifactRoot `
        --results-directory $testResultDirectory `
        --filter $testRun.Filter `
        --logger "trx;LogFileName=$($testRun.Log)"
    if ($LASTEXITCODE -ne 0) {
        throw "v0.3 Realtime Activity evidence tests failed: $($testRun.Project)"
    }
}

$testResults = @(Get-ChildItem -LiteralPath $testResultDirectory -Filter '*.trx' -File)
if ($testResults.Count -ne 3) {
    throw "Expected exactly 3 fresh Realtime Activity TRX files, found $($testResults.Count)."
}

$combinedTestLog = ($testResults | ForEach-Object {
    Get-Content -LiteralPath $_.FullName -Raw
}) -join "`n"
$requiredChecks = @(
    'FiveDimensionFiltersProduceTheSameStableResultForTheSameFixture',
    'SelectedEventDetailAndEvidenceAlwaysReferenceTheSameEvent',
    'PagingIsStableAndNeverExceedsTheDeclaredHistoryBound',
    'LanguageRefreshKeepsFilterIdentityWhileReplacingAllLocalizedPresentation',
    'ProductionStateFailsClosedUntilAnActualActivityStreamIsConnected',
    'ActualWpfRealtimeActivityRendersLocalizedSynchronizedEvidence',
    'MissingReportIsRejectedBeforeRuntimeAdmission',
    'InvalidDurationIsRejectedDeterministically',
    'MissingAuthorizedHerdrEnvironmentFailsClosedWithoutWritingReport',
    'RuntimeAdmissionFailureIsReportedWithoutWritingReport',
    'TransitionKeyRetentionHasAnExplicitFifoBound',
    'OnStateChangedRetainsOnlyBoundedEventWindowForAnAdversarialStream',
    'AcceptedCountIsRetentionWindowedWhenBothDedupeCachesEvict',
    'TransitionKeyRetentionRemainsBoundedForAnAdversarialUniqueStream',
    'LatencyRetentionKeepsOnlyFirstAndMaximumForAnAdversarialStream',
    'LatencyRetentionRejectsNonFiniteAndNegativeValues',
    'RuntimeTraceRetentionBoundsAreExplicitAndAligned'
)
foreach ($check in $requiredChecks) {
    if ($combinedTestLog -notmatch [Regex]::Escape($check)) {
        throw "Required v0.3 Realtime Activity check is absent from fresh test logs: $check"
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
if ($totalTests -ne $requiredChecks.Count -or $failedTests -ne 0 -or $totalTests -ne $passedTests) {
    throw "Realtime Activity counters are not the expected all-pass set: total=$totalTests passed=$passedTests failed=$failedTests"
}

if (-not (Test-Path -LiteralPath $referencePath -PathType Leaf)) {
    throw "Approved Realtime Activity reference is missing: $referencePath"
}
$referenceSha256 = (Get-FileHash -LiteralPath $referencePath -Algorithm SHA256).Hash
if ($referenceSha256 -ne $expectedReferenceSha256) {
    throw "Realtime Activity reference SHA-256 drifted: expected $expectedReferenceSha256 observed $referenceSha256"
}

$captureDirectory = Join-Path $artifactRoot 'design-evidence\v0.3.0\issue-13\contract-backed-wpf'
$requiredCaptures = @(
    'realtime-activity-th-1672x941.png',
    'realtime-activity-th-scope-selected-1672x941.png',
    'realtime-activity-th-1366x768.png',
    'realtime-activity-en-1672x941.png'
)
$captureEvidence = foreach ($captureName in $requiredCaptures) {
    $capturePath = Join-Path $captureDirectory $captureName
    if (-not (Test-Path -LiteralPath $capturePath -PathType Leaf)) {
        throw "Required actual WPF capture is missing: $capturePath"
    }
    if ((Get-Item -LiteralPath $capturePath).Length -le 10000) {
        throw "Actual WPF capture is unexpectedly small: $capturePath"
    }

    [pscustomobject]@{
        Name = $captureName
        Sha256 = (Get-FileHash -LiteralPath $capturePath -Algorithm SHA256).Hash
    }
}
if ($captureEvidence[0].Sha256 -eq $captureEvidence[1].Sha256) {
    throw 'Changing the selected event did not change the rendered Realtime Activity evidence.'
}

$sourceCommit = (& git -C $repositoryRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($sourceCommit)) {
    throw 'Could not resolve the source commit for the v0.3 Realtime Activity gate.'
}
$sourceTree = (& git -C $repositoryRoot rev-parse 'HEAD^{tree}').Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($sourceTree)) {
    throw 'Could not resolve the source tree for the v0.3 Realtime Activity gate.'
}

$gateReportPath = Join-Path $gateDirectory 'gate-report.txt'
$gateReport = @(
    'HerdrOps v0.3 Issue #13 Realtime Activity Implementation Gate',
    "GeneratedUtc: $([DateTime]::UtcNow.ToString('O'))",
    "SourceCommit: $sourceCommit",
    "SourceTree: $sourceTree",
    'Result: IMPLEMENTATION READY / PARTIAL',
    'ImplementationGate: PASS',
    'IssueAcceptance: PENDING',
    'VersionReleaseGate: PENDING',
    'EvidenceClass: Contract plus actual WPF rendering backed by Synthetic state',
    'ActualLiveEventCapture: NOT OBSERVED / NOT CLAIMED',
    'InstalledHerdrRuntime: NOT OBSERVED / NOT CLAIMED',
    'IssueStateRequired: OPEN',
    "Tests: $passedTests/$totalTests PASS",
    "ApprovedReferenceSha256: $referenceSha256",
    "ActualWpfCaptures: $($requiredCaptures.Count)",
    'FilterDimensions: time, role, severity, task, evidence level',
    'HistoryBound: 32 events',
    'PageSize: 7 events',
    'LanguageModes: Thai-only or English-only interface copy',
    '',
    'RequiredChecks:'
) + ($requiredChecks | ForEach-Object { "PASS $_" }) + @(
    '',
    'CaptureHashes:'
) + ($captureEvidence | ForEach-Object { "SHA256 $($_.Sha256) $($_.Name)" }) + @(
    '',
    'EvidenceBoundary:',
    'This gate proves deterministic five-dimension filtering, bounded paging, stable event selection, synchronized details/evidence, language separation, approved-reference binding, and actual WPF rendering from a deterministic synthetic fixture.',
    'It does not prove an installed Herdr session, actual collector output, live event latency, actual process/file observations, actual secret redaction, Issue #13 acceptance, or v0.3 release readiness.',
    'Issue #13 must remain open until an actual live event capture from the v0.3 collectors is admitted.'
)
$gateReport | Set-Content -LiteralPath $gateReportPath -Encoding utf8
$gateReport | Write-Output
Write-Output "GateReport: $gateReportPath"
