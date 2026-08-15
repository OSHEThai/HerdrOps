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
$fixturePath = Join-Path $repositoryRoot 'tests\fixtures\v0.4\assignment-lifecycle-replay.json'
$contractPath = Join-Path $repositoryRoot 'docs\protocol\v0.4-assignment-lifecycle-contract.md'
$implementationPath = Join-Path $repositoryRoot 'docs\design\implementation\v0.4-issue-19-assignment-lifecycle.md'
$reviewRecordPath = Join-Path $repositoryRoot 'docs\reviews\v0.4-issue-19-independent-review.md'
$expectedInputSha256 = '03A13C69A59BC7F99D5BB3055E012A711F073EE214337E7DF6A42A1B3C2CB62C'
$expectedResultSha256 = '896D7ED38511AA038F77B8361038F4D26A90A7E713677C3A16BA1A3E87047B0F'
$expectedReportSha256 = '8496BD83780D3DB9DE38A76718942154CE5CEC68BBF1998D1793607FBD0AE5B1'

$workingTreeStatus = @(& git -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0) {
    throw 'Could not inspect the source working tree for the v0.4 assignment lifecycle gate.'
}
if ($workingTreeStatus.Count -ne 0) {
    throw "The v0.4 assignment lifecycle gate requires a clean committed checkout. Pending paths: $($workingTreeStatus -join ', ')"
}

if (-not $SkipBuild) {
    & (Join-Path $PSScriptRoot 'Invoke-Build.ps1') -Configuration $Configuration -VerifyFormat
    if ($LASTEXITCODE -ne 0) {
        throw "v0.4 assignment lifecycle build gate failed with exit code $LASTEXITCODE."
    }
}

$runId = "$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ', [Globalization.CultureInfo]::InvariantCulture))-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
$gateDirectory = Join-Path $artifactRoot "release-gates\v0.4.0\issue-19\$runId"
$testResultDirectory = Join-Path $gateDirectory 'test-results'
New-Item -ItemType Directory -Path $testResultDirectory -Force | Out-Null

$testRuns = @(
    [pscustomobject]@{
        Project = Join-Path $repositoryRoot 'tests\HerdrOps.UnitTests\HerdrOps.UnitTests.csproj'
        Filter = 'FullyQualifiedName~AssignmentLifecycleTests'
        Log = 'assignment-lifecycle-domain.trx'
    },
    [pscustomobject]@{
        Project = Join-Path $repositoryRoot 'tests\HerdrOps.IntegrationTests\HerdrOps.IntegrationTests.csproj'
        Filter = 'FullyQualifiedName~AssignmentLifecycleMappingTests|FullyQualifiedName~AssignmentLifecycleStoreTests|FullyQualifiedName~AssignmentLifecycleReplayCommandTests|FullyQualifiedName~SqliteHerdrStateStoreTests'
        Log = 'assignment-lifecycle-integration.trx'
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
        throw "v0.4 assignment lifecycle evidence tests failed: $($testRun.Project)"
    }
}

$testResults = @(Get-ChildItem -LiteralPath $testResultDirectory -Filter '*.trx' -File)
if ($testResults.Count -ne 2) {
    throw "Expected exactly 2 fresh assignment lifecycle TRX files, found $($testResults.Count)."
}

$combinedTestLog = ($testResults | ForEach-Object {
    Get-Content -LiteralPath $_.FullName -Raw
}) -join "`n"
$requiredChecks = @(
    'CompletePmLeaderWorkerReviewTraceIsDeterministicAndProvenanced',
    'MissingAcknowledgementIsAuditedWithoutAdvancingTaskTipAndCanRecover',
    'OrphanTaskAndParentRemainVisibleInAuditTrail',
    'SecondHandoffBeforeAcknowledgementIsExplicitlyVisible',
    'IdenticalRetryAndIdentityConflictDoNotConsumeSequenceTwice',
    'SequenceGapIsConsumedAsVisibleAuditWithoutMutatingTask',
    'ProgressRegressionAndStaleParentAreAuditedDeterministically',
    'ReplayRejectsInputsAboveConfiguredBound',
    'AcceptedSelfReportsMapEveryEventTypeWithoutLosingCoreIdentity',
    'MapperRejectsAcceptanceIdentityThatWasNotOwnedByCore',
    'MapperRejectsAcceptanceHashThatDoesNotBindSubmission',
    'CoreRejectsFutureOccurrenceWithoutAdvancingAcceptanceSequence',
    'RestartPreservesExactReplayAndHistoricalProvenance',
    'OrphanAndDuplicateHandoffRemainQueryableWithoutChangingTaskTip',
    'StoreRejectsAppliedStepFromDisconnectedTaskHistory',
    'StoreRejectsForgedConsumedDispositionEvenWhenHashesAreValid',
    'StoreRejectsAppliedStepThatHidesAPersistedSequenceGap',
    'LifecycleLedgersRejectMutationAndReadsDetectByteTampering',
    'CurrentTaskReadRejectsScalarProjectionDrift',
    'VersionOneDatabaseMigratesForwardWithoutLosingHistory',
    'FutureSchemaFailsClosedWithoutMigration',
    'CommittedLifecycleFixtureProducesByteIdenticalReportsAndExpectedHash',
    'UnknownInputMemberFailsClosedWithoutReplacingReport',
    'DuplicateJsonPropertyFailsClosedWithoutReport',
    'InputCannotBeOverwrittenByReport'
)
foreach ($check in $requiredChecks) {
    if ($combinedTestLog -notmatch [Regex]::Escape($check)) {
        throw "Required v0.4 assignment lifecycle check is absent from fresh test logs: $check"
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
if ($totalTests -lt $requiredChecks.Count -or
    $failedTests -ne 0 -or
    $totalTests -ne $passedTests) {
    throw "Assignment lifecycle test counters are not all passing: total=$totalTests passed=$passedTests failed=$failedTests"
}

foreach ($requiredFile in @(
        $fixturePath,
        $contractPath,
        $implementationPath,
        $reviewRecordPath)) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
        throw "Required Issue #19 evidence asset is missing: $requiredFile"
    }
}

$configurationDirectory = $Configuration.ToLowerInvariant()
$coreDll = Join-Path $artifactRoot "bin\HerdrOps.Core\$configurationDirectory\HerdrOps.Core.dll"
if (-not (Test-Path -LiteralPath $coreDll -PathType Leaf)) {
    throw "Built HerdrOps.Core product command was not found: $coreDll"
}

$firstReportPath = Join-Path $gateDirectory 'assignment-lifecycle-replay-1.json'
$secondReportPath = Join-Path $gateDirectory 'assignment-lifecycle-replay-2.json'
& dotnet $coreDll assignment-lifecycle-replay `
    --input $fixturePath `
    --report $firstReportPath | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "First product assignment lifecycle replay failed with exit code $LASTEXITCODE."
}
& dotnet $coreDll assignment-lifecycle-replay `
    --input $fixturePath `
    --report $secondReportPath | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Second product assignment lifecycle replay failed with exit code $LASTEXITCODE."
}

$firstReportBytes = [IO.File]::ReadAllBytes($firstReportPath)
$secondReportBytes = [IO.File]::ReadAllBytes($secondReportPath)
if (-not [Linq.Enumerable]::SequenceEqual($firstReportBytes, $secondReportBytes)) {
    throw 'Repeated product assignment lifecycle replay reports are not byte-identical.'
}

$fixtureSha256 = (Get-FileHash -LiteralPath $fixturePath -Algorithm SHA256).Hash
$reportSha256 = (Get-FileHash -LiteralPath $firstReportPath -Algorithm SHA256).Hash
if ($fixtureSha256 -ne $expectedInputSha256) {
    throw "Lifecycle fixture SHA-256 drifted: expected $expectedInputSha256 observed $fixtureSha256"
}
if ($reportSha256 -ne $expectedReportSha256) {
    throw "Lifecycle replay report SHA-256 drifted: expected $expectedReportSha256 observed $reportSha256"
}

$report = Get-Content -LiteralPath $firstReportPath -Raw | ConvertFrom-Json -Depth 128
if ($report.evidenceClass -ne 'Synthetic' -or $report.runtimeObserved -ne $false) {
    throw 'The lifecycle replay report must remain synthetic and cannot claim runtime observation.'
}
if ($report.inputSha256 -ne $expectedInputSha256 -or
    $report.replay.resultSha256 -ne $expectedResultSha256) {
    throw 'The lifecycle replay report does not bind the committed fixture and expected result.'
}

$diagnostics = $report.replay.diagnostics
$expectedCounters = [ordered]@{
    processedEventCount = 10
    consumedSequenceCount = 10
    appliedEventCount = 8
    orphanEventCount = 1
    duplicateHandoffCount = 1
    currentTaskCount = 1
    relationshipCount = 3
    roleObservationCount = 8
    lastSequence = 10
}
foreach ($counter in $expectedCounters.GetEnumerator()) {
    if ([long]$diagnostics.($counter.Key) -ne [long]$counter.Value) {
        throw "Unexpected lifecycle replay counter $($counter.Key): expected $($counter.Value) observed $($diagnostics.($counter.Key))"
    }
}

$currentTask = @($report.replay.currentTasks)[0].state
if ($currentTask.status -ne 'HandedOff' -or
    $currentTask.currentAssigneeId -ne 'reviewer-01' -or
    [int]$currentTask.deviationCount -ne 1 -or
    [int]$currentTask.evidenceCount -ne 1 -or
    [int]$currentTask.handoffCount -ne 1) {
    throw 'The lifecycle replay current task does not preserve the accepted handoff state.'
}

$reviewText = Get-Content -LiteralPath $reviewRecordPath -Raw
$reviewPassed = $reviewText -match '(?m)^Verdict: PASS\s*$'
$reviewVerdict = if ($reviewPassed) { 'PASS' } else { 'UNAVAILABLE OR PENDING' }
$issueAcceptance = if ($reviewPassed) { 'PASS' } else { 'PENDING' }
$sourceCommit = (& git -C $repositoryRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($sourceCommit)) {
    throw 'Could not resolve the source commit for the v0.4 assignment lifecycle gate.'
}

$contractSha256 = (Get-FileHash -LiteralPath $contractPath -Algorithm SHA256).Hash
$implementationSha256 = (Get-FileHash -LiteralPath $implementationPath -Algorithm SHA256).Hash
$reviewRecordSha256 = (Get-FileHash -LiteralPath $reviewRecordPath -Algorithm SHA256).Hash
$domainSourceSha256 = (Get-FileHash `
    -LiteralPath (Join-Path $repositoryRoot 'src\HerdrOps.Domain\Assignments\AssignmentLifecycleReducer.cs') `
    -Algorithm SHA256).Hash
$migrationSourceSha256 = (Get-FileHash `
    -LiteralPath (Join-Path $repositoryRoot 'src\HerdrOps.Infrastructure\Storage\SqliteHerdrStateStore.cs') `
    -Algorithm SHA256).Hash
$gateReportPath = Join-Path $gateDirectory 'gate-report.txt'
$gateReport = @(
    'HerdrOps v0.4 Issue #19 Assignment Lifecycle and Provenance Gate',
    "GeneratedUtc: $([DateTime]::UtcNow.ToString('O'))",
    "SourceCommit: $sourceCommit",
    'Result: IMPLEMENTATION READY',
    'ImplementationGate: PASS',
    "IssueAcceptance: $issueAcceptance",
    'VersionReleaseGate: PENDING',
    'EvidenceClass: Contract plus Synthetic plus local SQLite integration',
    'ActualHerdrAgentRuntime: NOT OBSERVED / NOT CLAIMED',
    'DelegationGraphRendering: NOT OBSERVED / NOT CLAIMED',
    'TaskAlignmentRendering: NOT OBSERVED / NOT CLAIMED',
    "IndependentReviewVerdict: $reviewVerdict",
    "Tests: $passedTests/$totalTests PASS",
    "FixtureSha256: $fixtureSha256",
    "ReplayResultSha256: $($report.replay.resultSha256)",
    "ReplayReportSha256: $reportSha256",
    "ContractSha256: $contractSha256",
    "ImplementationRecordSha256: $implementationSha256",
    "IndependentReviewRecordSha256: $reviewRecordSha256",
    "DomainSourceSha256: $domainSourceSha256",
    "MigrationSourceSha256: $migrationSourceSha256",
    'RepeatedReplayReports: BYTE IDENTICAL',
    "AppliedEvents: $($diagnostics.appliedEventCount)",
    "OrphanEvents: $($diagnostics.orphanEventCount)",
    "DuplicateHandoffs: $($diagnostics.duplicateHandoffCount)",
    "HistoricalRelationships: $($diagnostics.relationshipCount)",
    "RoleObservations: $($diagnostics.roleObservationCount)",
    '',
    'RequiredChecks:'
) + ($requiredChecks | ForEach-Object { "PASS $_" }) + @(
    '',
    'EvidenceBoundary:',
    'This gate proves strict versioned lifecycle transitions, deterministic audit and replay, Core-acceptance mapping, SQLite migration v1 to v2, append-only provenance, restart restoration, and persisted orphan and duplicate-handoff visibility against committed synthetic input.',
    'It does not prove an installed Herdr session, actual role-distinct agents, live acceptance-to-database wiring, Delegation Graph or Task Alignment rendering, v0.4 acceptance, or release readiness.'
)
$gateReport | Set-Content -LiteralPath $gateReportPath -Encoding utf8
$gateReport | Write-Output
Write-Output "ReplayReport: $firstReportPath"
Write-Output "GateReport: $gateReportPath"
