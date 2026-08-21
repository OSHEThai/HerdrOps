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
$fixturePath = Join-Path $repositoryRoot 'tests\fixtures\v0.3\activity-replay.json'
$reviewRecordPath = Join-Path $repositoryRoot 'docs\reviews\v0.3-issue-12-independent-review.md'
$expectedInputSha256 = '8A7276170438360238803DD057BB6FB81F2745EC888C1A9DD2CF304B824633E1'
$expectedResultSha256 = '9FC1E4E87291608DE338361E31315ABB01A73ACF4457F55EC2E263A734D3D82E'
$expectedReportSha256 = '775938CADB509FD94329B4349A35E49DB5E728F76DB1C2258F83A1ED92D1D06A'
$expectedReviewRecordSha256 = '3D168CEB6639E6135BC9BCDAA735073F871C33731A56310DF26184379ADDC917'

$workingTreeStatus = @(& git -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0) {
    throw 'Could not inspect the source working tree for the v0.3 activity-pipeline gate.'
}
if ($workingTreeStatus.Count -ne 0) {
    throw "The v0.3 activity-pipeline gate requires a clean committed checkout. Pending paths: $($workingTreeStatus -join ', ')"
}

if (-not $SkipBuild) {
    & (Join-Path $PSScriptRoot 'Invoke-Build.ps1') -Configuration $Configuration -VerifyFormat
    if ($LASTEXITCODE -ne 0) {
        throw "v0.3 activity-pipeline build gate failed with exit code $LASTEXITCODE."
    }
}

$runId = "$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ', [Globalization.CultureInfo]::InvariantCulture))-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
$gateDirectory = Join-Path $artifactRoot "release-gates\v0.3.0\issue-12\$runId"
$testResultDirectory = Join-Path $gateDirectory 'test-results'
New-Item -ItemType Directory -Path $testResultDirectory -Force | Out-Null

$testProjects = @(
    (Join-Path $repositoryRoot 'tests\HerdrOps.UnitTests\HerdrOps.UnitTests.csproj'),
    (Join-Path $repositoryRoot 'tests\HerdrOps.IntegrationTests\HerdrOps.IntegrationTests.csproj')
)
foreach ($testProject in $testProjects) {
    & dotnet test $testProject `
        --configuration $Configuration `
        --no-restore `
        --no-build `
        --artifacts-path $artifactRoot `
        --results-directory $testResultDirectory `
        --logger trx
    if ($LASTEXITCODE -ne 0) {
        throw "v0.3 activity-pipeline evidence tests failed: $testProject"
    }
}

$testResults = @(Get-ChildItem -LiteralPath $testResultDirectory -Filter '*.trx' -File)
if ($testResults.Count -ne 2) {
    throw "Expected exactly 2 fresh activity-pipeline TRX files, found $($testResults.Count)."
}

$combinedTestLog = ($testResults | ForEach-Object {
    Get-Content -LiteralPath $_.FullName -Raw
}) -join "`n"
$requiredChecks = @(
    'RepeatedReplayProducesExactSameHashAndSummary',
    'DuplicateAndNoisyEventsStayBoundedWithoutLosingUrgentEvents',
    'SequenceGapIsObservableWhileUnsequencedSourcesInventNoGap',
    'SameSourceIdentityWithChangedContentIsRejectedAndObserved',
    'LatestSequencedDuplicateRemainsDuplicateAfterDeduplicationEviction',
    'MaximumSourceSequenceDoesNotWrapARegressionIntoAGap',
    'ContractNormalizesStableFieldsAndRequiresDebounceKeyForNormalNoise',
    'ReplayRejectsInputsAboveConfiguredBound',
    'CommittedReplayFixtureProducesByteIdenticalReportsAndExpectedHash',
    'UnknownInputMemberFailsClosedWithoutReplacingReport',
    'DuplicateJsonPropertyFailsClosedWithoutReport',
    'MissingRequiredReportOptionReturnsUsageFailure',
    'InputCannotBeOverwrittenByReport'
)
foreach ($check in $requiredChecks) {
    if ($combinedTestLog -notmatch [Regex]::Escape($check)) {
        throw "Required v0.3 activity-pipeline check is absent from the fresh test logs: $check"
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
    throw "Activity-pipeline test counters are not all passing: total=$totalTests passed=$passedTests failed=$failedTests"
}

$coreDll = Join-Path $artifactRoot "bin\HerdrOps.Core\$($Configuration.ToLowerInvariant())\HerdrOps.Core.dll"
if (-not (Test-Path -LiteralPath $coreDll -PathType Leaf)) {
    throw "Built HerdrOps.Core product command was not found: $coreDll"
}
if (-not (Test-Path -LiteralPath $fixturePath -PathType Leaf)) {
    throw "Committed v0.3 replay fixture was not found: $fixturePath"
}
if (-not (Test-Path -LiteralPath $reviewRecordPath -PathType Leaf)) {
    throw "Committed v0.3 independent review record was not found: $reviewRecordPath"
}

$firstReportPath = Join-Path $gateDirectory 'activity-replay-1.json'
$secondReportPath = Join-Path $gateDirectory 'activity-replay-2.json'
& dotnet $coreDll activity-replay --input $fixturePath --report $firstReportPath | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "First product activity replay failed with exit code $LASTEXITCODE."
}
& dotnet $coreDll activity-replay --input $fixturePath --report $secondReportPath | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Second product activity replay failed with exit code $LASTEXITCODE."
}

$firstReportBytes = [System.IO.File]::ReadAllBytes($firstReportPath)
$secondReportBytes = [System.IO.File]::ReadAllBytes($secondReportPath)
if (-not [System.Linq.Enumerable]::SequenceEqual($firstReportBytes, $secondReportBytes)) {
    throw 'Repeated product activity replay reports are not byte-identical.'
}

$fixtureSha256 = (Get-FileHash -LiteralPath $fixturePath -Algorithm SHA256).Hash
$reviewRecordSha256 = (Get-FileHash -LiteralPath $reviewRecordPath -Algorithm SHA256).Hash
$reportSha256 = (Get-FileHash -LiteralPath $firstReportPath -Algorithm SHA256).Hash
if ($fixtureSha256 -ne $expectedInputSha256) {
    throw "Replay fixture SHA-256 drifted: expected $expectedInputSha256 observed $fixtureSha256"
}
if ($reportSha256 -ne $expectedReportSha256) {
    throw "Replay report SHA-256 drifted: expected $expectedReportSha256 observed $reportSha256"
}
if ($reviewRecordSha256 -ne $expectedReviewRecordSha256) {
    throw "Independent review record SHA-256 drifted: expected $expectedReviewRecordSha256 observed $reviewRecordSha256"
}

$report = Get-Content -LiteralPath $firstReportPath -Raw | ConvertFrom-Json -Depth 128
if ($report.contractVersion -ne 1) { throw "Unexpected replay report contract: $($report.contractVersion)" }
if ($report.evidenceClass -ne 'Synthetic') { throw "Unexpected evidence class: $($report.evidenceClass)" }
if ($report.runtimeObserved -ne $false) { throw 'Deterministic replay must not claim runtime observation.' }
if ($report.inputSha256 -ne $expectedInputSha256) { throw 'Replay report input hash does not bind the committed fixture.' }
if ($report.replay.resultSha256 -ne $expectedResultSha256) {
    throw "Unexpected deterministic replay result: $($report.replay.resultSha256)"
}

$diagnostics = $report.replay.diagnostics
$expectedCounters = [ordered]@{
    ingestedEventCount = 12
    acceptedEventCount = 11
    duplicateEventCount = 1
    rejectedEventCount = 0
    urgentInputEventCount = 2
    emissionCount = 7
    immediateEmissionCount = 4
    debouncedEmissionCount = 3
    emittedSourceEventCount = 11
    gapObservationCount = 1
    conflictObservationCount = 0
    regressionObservationCount = 0
    deduplicationEvictionCount = 3
    sourceStreamEvictionCount = 0
    capacityPressureFlushCount = 0
    peakDeduplicationEntries = 8
    peakTrackedSourceStreams = 1
    peakOpenDebounceBuckets = 3
}
foreach ($counter in $expectedCounters.GetEnumerator()) {
    if ([long]$diagnostics.($counter.Key) -ne [long]$counter.Value) {
        throw "Unexpected replay counter $($counter.Key): expected $($counter.Value) observed $($diagnostics.($counter.Key))"
    }
}
if ([long]$report.replay.urgentEmissionCount -ne [long]$diagnostics.urgentInputEventCount) {
    throw 'At least one urgent fixture event did not produce an immediate urgent emission.'
}
if ([long]$diagnostics.emittedSourceEventCount -ne [long]$diagnostics.acceptedEventCount) {
    throw 'At least one accepted fixture event was not represented by an emission.'
}
if ([int]$diagnostics.peakDeduplicationEntries -gt [int]$report.replay.options.maximumDeduplicationEntries -or
    [int]$diagnostics.peakTrackedSourceStreams -gt [int]$report.replay.options.maximumTrackedSourceStreams -or
    [int]$diagnostics.peakOpenDebounceBuckets -gt [int]$report.replay.options.maximumOpenDebounceBuckets) {
    throw 'Activity pipeline exceeded at least one configured collection bound.'
}

$sourceCommit = (& git -C $repositoryRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($sourceCommit)) {
    throw 'Could not resolve the source commit for the v0.3 activity-pipeline gate.'
}
$sourceTree = (& git -C $repositoryRoot rev-parse 'HEAD^{tree}').Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($sourceTree)) {
    throw 'Could not resolve the source tree for the v0.3 activity-pipeline gate.'
}
$gateReportPath = Join-Path $gateDirectory 'gate-report.txt'
$gateReport = @(
    'HerdrOps v0.3 Issue #12 Deterministic Activity Pipeline Gate',
    "GeneratedUtc: $([DateTime]::UtcNow.ToString('O'))",
    "SourceCommit: $sourceCommit",
    "SourceTree: $sourceTree",
    'Result: PASS',
    'IssueAcceptance: PASS',
    'VersionReleaseGate: PENDING',
    'EvidenceClass: Contract plus Synthetic',
    'ActualHerdrRuntime: NOT OBSERVED / NOT CLAIMED',
    'WindowsProcessTelemetry: NOT OBSERVED / NOT CLAIMED',
    'FileCollectionRuntime: NOT OBSERVED / NOT CLAIMED',
    "Tests: $passedTests/$totalTests PASS",
    "FixtureSha256: $fixtureSha256",
    "ReplayResultSha256: $($report.replay.resultSha256)",
    "ReplayReportSha256: $reportSha256",
    'IndependentReviewRun: 20260814T183917Z-19459ff0',
    'IndependentDeltaReviewRun: 20260814T185236Z-0077badf',
    'IndependentReviewVerdict: NO ACTIONABLE P0-P3 FINDINGS',
    "IndependentReviewRecordSha256: $reviewRecordSha256",
    'RepeatedReplayReports: BYTE IDENTICAL',
    "AcceptedEvents: $($diagnostics.acceptedEventCount)",
    "DuplicateEvents: $($diagnostics.duplicateEventCount)",
    "GapObservations: $($diagnostics.gapObservationCount)",
    "UrgentInputsAndEmissions: $($diagnostics.urgentInputEventCount)/$($report.replay.urgentEmissionCount)",
    "EmittedSourceEvents: $($diagnostics.emittedSourceEventCount)/$($diagnostics.acceptedEventCount)",
    "PeakDedupEntries: $($diagnostics.peakDeduplicationEntries)/$($report.replay.options.maximumDeduplicationEntries)",
    "PeakSourceStreams: $($diagnostics.peakTrackedSourceStreams)/$($report.replay.options.maximumTrackedSourceStreams)",
    "PeakDebounceBuckets: $($diagnostics.peakOpenDebounceBuckets)/$($report.replay.options.maximumOpenDebounceBuckets)",
    '',
    'RequiredChecks:'
) + ($requiredChecks | ForEach-Object { "PASS $_" }) + @(
    '',
    'EvidenceBoundary:',
    'This gate proves the committed event envelope, normalization, exact identity deduplication, bounded fixed-window debounce, urgent bypass, observable source-sequence gaps and deterministic fixture replay.',
    'It proves strict product-command input handling and exact output hashes against committed synthetic data.',
    'It does not prove an installed Herdr session, live activity latency, bounded pane.read behavior, Windows process telemetry, scoped file/Git collection, secret redaction against real data, or v0.3 release readiness.'
)
$gateReport | Set-Content -LiteralPath $gateReportPath -Encoding utf8
$gateReport | Write-Output
Write-Output "ReplayReport: $firstReportPath"
Write-Output "GateReport: $gateReportPath"
