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
$contractPath = Join-Path $repositoryRoot 'docs\protocol\v0.3-bounded-terminal-process-contract.md'
$reviewRecordPath = Join-Path $repositoryRoot 'docs\reviews\v0.3-issue-14-independent-review.md'

$workingTreeStatus = @(& git -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0) {
    throw 'Could not inspect the source working tree for the v0.3 terminal/process gate.'
}
if ($workingTreeStatus.Count -ne 0) {
    throw "The v0.3 terminal/process gate requires a clean committed checkout. Pending paths: $($workingTreeStatus -join ', ')"
}

if (-not $SkipBuild) {
    & (Join-Path $PSScriptRoot 'Invoke-Build.ps1') -Configuration $Configuration -VerifyFormat
    if ($LASTEXITCODE -ne 0) {
        throw "v0.3 terminal/process build gate failed with exit code $LASTEXITCODE."
    }
}

$runId = "$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ', [Globalization.CultureInfo]::InvariantCulture))-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
$gateDirectory = Join-Path $artifactRoot "release-gates\v0.3.0\issue-14\$runId"
$testResultDirectory = Join-Path $gateDirectory 'test-results'
New-Item -ItemType Directory -Path $testResultDirectory -Force | Out-Null

$testRuns = @(
    [pscustomobject]@{
        Project = Join-Path $repositoryRoot 'tests\HerdrOps.UnitTests\HerdrOps.UnitTests.csproj'
        Filter = 'FullyQualifiedName~TerminalPreviewPolicyTests'
        Log = 'terminal-preview-policy.trx'
    },
    [pscustomobject]@{
        Project = Join-Path $repositoryRoot 'tests\HerdrOps.ContractTests\HerdrOps.ContractTests.csproj'
        Filter = 'FullyQualifiedName~HerdrProtocolJsonCodecContractTests'
        Log = 'herdr-protocol-codec.trx'
    },
    [pscustomobject]@{
        Project = Join-Path $repositoryRoot 'tests\HerdrOps.IntegrationTests\HerdrOps.IntegrationTests.csproj'
        Filter = 'FullyQualifiedName~HerdrNamedPipeApiClientTests|FullyQualifiedName~WindowsProcessTelemetryTests|FullyQualifiedName~HerdrTerminalProcessCollectorTests|FullyQualifiedName~HerdrRuntimeTraceCommandTests'
        Log = 'terminal-process-integration.trx'
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
        throw "v0.3 terminal/process evidence tests failed: $($testRun.Project)"
    }
}

$testResults = @(Get-ChildItem -LiteralPath $testResultDirectory -Filter '*.trx' -File)
if ($testResults.Count -ne 3) {
    throw "Expected exactly 3 fresh terminal/process TRX files, found $($testResults.Count)."
}

$combinedTestLog = ($testResults | ForEach-Object {
    Get-Content -LiteralPath $_.FullName -Raw
}) -join "`n"
$requiredChecks = @(
    'RedactorRemovesAssignmentsAuthorizationUriCredentialsAndKnownTokens',
    'RedactorRemovesFineGrainedGitHubPatAndColonlessUriCredentials',
    'RedactorBoundsUnicodeOutputWithoutSplittingRunes',
    'RedactorRejectsInputAboveItsExplicitByteBound',
    'PlannerReadsOnlyChangedRevisionsAndRetriesFailuresAfterDebounce',
    'PlannerEvictsOldestPaneAtTheConfiguredBound',
    'PlannerAcceptsAReadRevisionThatAdvancedAfterTheReadWasPlanned',
    'SanitizedObservationSerializesNoRawSecret',
    'PaneReadRequestIsAlwaysBoundedRecentUnwrappedPlainText',
    'PaneReadRequestRejectsEveryUnboundedLineValue',
    'PaneReadResponseRequiresMatchingPaneSourceAndFormat',
    'PaneProcessInfoPreservesReportedPidSourceMetadata',
    'PaneReadRoundTripSerializesANonOptionalBoundAndFixedSource',
    'PaneProcessInfoRoundTripCorrelatesTheRequestedPaneAndPid',
    'CorrelationReadsOnlyHerdrReportedPidsAndRedactsCommandMetadata',
    'CpuUsesPidAndStartTimeAndPidReuseStartsWithNoBaseline',
    'TelemetryExpiresAtItsExplicitTimeToLive',
    'WindowsReaderSamplesTheCurrentProcessWithStableIdentity',
    'ConnectedCycleReadsBoundedTerminalAndCorrelatesRedactedProcessTelemetry',
    'RevisionsAndPollIntervalsPreventContinuousTerminalAndProcessReads',
    'DisconnectedMonitorProducesNoInspectionCalls',
    'ZeroPaneRevisionIsCollectedWithoutInventingAPositiveSourceSequence',
    'TerminalProcessTraceRejectsAnUnboundedLineRequest',
    'TerminalProcessTraceRequiresAuthorizedHerdrEnvironmentWithoutWritingReport'
)
foreach ($check in $requiredChecks) {
    if ($combinedTestLog -notmatch [Regex]::Escape($check)) {
        throw "Required v0.3 terminal/process check is absent from fresh test logs: $check"
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
    throw "Terminal/process test counters are not all passing: total=$totalTests passed=$passedTests failed=$failedTests"
}

$codecPath = Join-Path $repositoryRoot 'src\HerdrOps.Infrastructure\Herdr\HerdrProtocolJsonCodec.cs'
$clientPath = Join-Path $repositoryRoot 'src\HerdrOps.Infrastructure\Herdr\HerdrNamedPipeApiClient.cs'
$collectorPath = Join-Path $repositoryRoot 'src\HerdrOps.Core\HerdrTerminalProcessCollector.cs'
$codec = Get-Content -LiteralPath $codecPath -Raw
$client = Get-Content -LiteralPath $clientPath -Raw
$collector = Get-Content -LiteralPath $collectorPath -Raw
if ($codec -notmatch 'writer\.WriteNumber\("lines", maximumLines\)' -or
    $codec -notmatch 'writer\.WriteString\("source", "recent_unwrapped"\)' -or
    $codec -notmatch 'writer\.WriteString\("format", "text"\)' -or
    $codec -notmatch 'writer\.WriteBoolean\("strip_ansi", true\)') {
    throw 'The sole product pane.read codec no longer fixes every bounded request field.'
}
if ($client -notmatch 'CreateBoundedPaneReadRequest' -or
    $collector -notmatch 'ReadRecentUnwrappedAsync') {
    throw 'The collector-to-client bounded pane.read path is incomplete.'
}
$productionPaneReadWriters = @(& rg 'WriteString\("method", "pane\.read"\)' (Join-Path $repositoryRoot 'src') --glob '*.cs')
if ($LASTEXITCODE -ne 0 -or $productionPaneReadWriters.Count -ne 1) {
    throw "Expected exactly one product pane.read request writer, found $($productionPaneReadWriters.Count)."
}

if (-not (Test-Path -LiteralPath $contractPath -PathType Leaf)) {
    throw "The v0.3 terminal/process contract is missing: $contractPath"
}
if (-not (Test-Path -LiteralPath $reviewRecordPath -PathType Leaf)) {
    throw "The v0.3 terminal/process independent review record is missing: $reviewRecordPath"
}
$contractSha256 = (Get-FileHash -LiteralPath $contractPath -Algorithm SHA256).Hash
$reviewRecordSha256 = (Get-FileHash -LiteralPath $reviewRecordPath -Algorithm SHA256).Hash
$sourceCommit = (& git -C $repositoryRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($sourceCommit)) {
    throw 'Could not resolve the source commit for the v0.3 terminal/process gate.'
}

$gateReportPath = Join-Path $gateDirectory 'gate-report.txt'
$gateReport = @(
    'HerdrOps v0.3 Issue #14 Bounded Terminal and Windows Process Implementation Gate',
    "GeneratedUtc: $([DateTime]::UtcNow.ToString('O'))",
    "SourceCommit: $sourceCommit",
    'Result: IMPLEMENTATION READY / PARTIAL',
    'ImplementationGate: PASS',
    'IssueAcceptance: PENDING',
    'VersionReleaseGate: PENDING',
    'EvidenceClass: Contract plus Synthetic plus local Windows process sample',
    'ActualHerdrPaneRead: NOT OBSERVED / NOT CLAIMED',
    'ActualHerdrPidCorrelation: NOT OBSERVED / NOT CLAIMED',
    'IssueStateRequired: OPEN',
    "Tests: $passedTests/$totalTests PASS",
    'PaneReadSource: recent_unwrapped',
    'PaneReadFormat: text',
    'PaneReadLineBound: 1-200 required',
    'UnboundedProductPaneReadWriters: 0',
    'DefaultProcessTelemetryTtlSeconds: 15',
    'ProcessIdentity: PID plus process-start UTC',
    "ContractSha256: $contractSha256",
    'IndependentReviewFinding: github_pat and URI user-info credential bypass',
    'IndependentRemediationVerdict: NO ACTIONABLE FINDINGS',
    "IndependentReviewRecordSha256: $reviewRecordSha256",
    '',
    'RequiredChecks:'
) + ($requiredChecks | ForEach-Object { "PASS $_" }) + @(
    '',
    'EvidenceBoundary:',
    'This gate proves the fixed bounded pane.read contract, strict response correlation, redaction and Unicode bounds, revision/debounce behavior, PID/source tracking, PID-reuse protection, CPU/memory calculation, expiry, collector fail-closed behavior, and one actual local Windows process sample.',
    'It does not prove that an installed Herdr server returned terminal bytes or that a PID reported by an actual Herdr pane correlated with Windows.',
    'Issue #14 and the v0.3 release gate remain open until the authorized runtime command produces both required traces and they are independently reviewed.'
)
$gateReport | Set-Content -LiteralPath $gateReportPath -Encoding utf8
$gateReport | Write-Output
Write-Output "GateReport: $gateReportPath"
