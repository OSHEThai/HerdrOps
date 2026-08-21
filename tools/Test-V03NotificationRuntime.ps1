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
$referencePath = Join-Path $repositoryRoot 'docs\design\reference\11-widget-concepts.png'
$expectedReferenceSha256 = '6AB57A967BE8C62A436A8F5C6DBB89616B210E66DD34AB851D148B4DCC1A904A'
$contractPath = Join-Path $repositoryRoot 'docs\protocol\v0.3-bounded-notification-runtime-contract.md'
$designRecordPath = Join-Path $repositoryRoot 'docs\design\implementation\v0.3-issue-16-notification-agent-popup.md'
$reviewRecordPath = Join-Path $repositoryRoot 'docs\reviews\v0.3-issue-16-independent-review.md'

$workingTreeStatus = @(& git -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0) {
    throw 'Could not inspect the source working tree for the v0.3 notification gate.'
}
if ($workingTreeStatus.Count -ne 0) {
    throw "The v0.3 notification gate requires a clean committed checkout. Pending paths: $($workingTreeStatus -join ', ')"
}

if (-not $SkipBuild) {
    & (Join-Path $PSScriptRoot 'Invoke-Build.ps1') -Configuration $Configuration -VerifyFormat
    if ($LASTEXITCODE -ne 0) {
        throw "v0.3 notification build gate failed with exit code $LASTEXITCODE."
    }
}

$runId = "$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ', [Globalization.CultureInfo]::InvariantCulture))-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
$gateDirectory = Join-Path $artifactRoot "release-gates\v0.3.0\issue-16\$runId"
$testResultDirectory = Join-Path $gateDirectory 'test-results'
New-Item -ItemType Directory -Path $testResultDirectory -Force | Out-Null

$testRuns = @(
    [pscustomobject]@{
        Project = Join-Path $repositoryRoot 'tests\HerdrOps.UnitTests\HerdrOps.UnitTests.csproj'
        Filter = 'FullyQualifiedName~NotificationCenterTests'
        Log = 'notification-domain.trx'
    },
    [pscustomobject]@{
        Project = Join-Path $repositoryRoot 'tests\HerdrOps.IntegrationTests\HerdrOps.IntegrationTests.csproj'
        Filter = 'FullyQualifiedName~NotificationWidgetStateTests|FullyQualifiedName~UiLanguageCatalogTests'
        Log = 'notification-integration.trx'
    },
    [pscustomobject]@{
        Project = Join-Path $repositoryRoot 'tests\HerdrOps.RuntimeTests\HerdrOps.RuntimeTests.csproj'
        Filter = 'FullyQualifiedName~NotificationWidgetRenderingTests'
        Log = 'notification-wpf-runtime.trx'
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
        throw "v0.3 notification evidence tests failed: $($testRun.Project)"
    }
}

$testResults = @(Get-ChildItem -LiteralPath $testResultDirectory -Filter '*.trx' -File)
if ($testResults.Count -ne 3) {
    throw "Expected exactly 3 fresh notification TRX files, found $($testResults.Count)."
}

$combinedTestLog = ($testResults | ForEach-Object {
    Get-Content -LiteralPath $_.FullName -Raw
}) -join "`n"
$requiredChecks = @(
    'UrgentDuplicateAppearsOnceAndRetainsExactEventAgentAndTaskRoute',
    'NoisyUrgentBurstGroupsSuppressesPopupsAndStaysWithinEveryBound',
    'AcknowledgementIsIdempotentAndRemainsInBoundedHistory',
    'GroupAcknowledgementCoversExistingItemsButNewEventBecomesUnacknowledged',
    'HiddenGroupKeepsFloodSuppressionUntilPresentationMemoryBoundEvictsIt',
    'AcceptedUrgentActivityGroupsOncePreservesRouteAndAcknowledgement',
    'NotificationFloodControlKeepsHistoryGroupsAndPresentationBounded',
    'RealtimeActivityDeepLinkSelectsOnlyAnExactKnownEvent',
    'NotificationProjectionFlattensAndBoundsAlreadyRedactedSummaryForTheWidget',
    'ThaiIsTheDefaultAndBothCatalogsContainTheSameNonEmptyKeys',
    'ActualWpfNotificationAndAgentPopupRenderAsSeparateThaiAndEnglishModes',
    'WidgetActionsAcknowledgeAndForwardExactRoutesThroughTheWindowHost',
    'ApplicationRouterSelectsExactEventThenFallsBackOnlyToAnExactAgent'
)
foreach ($check in $requiredChecks) {
    if ($combinedTestLog -notmatch [Regex]::Escape($check)) {
        throw "Required v0.3 notification check is absent from fresh test logs: $check"
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
if ($totalTests -lt $requiredChecks.Count -or $failedTests -ne 0 -or $totalTests -ne $passedTests) {
    throw "Notification test counters are not all passing: total=$totalTests passed=$passedTests failed=$failedTests"
}

if (-not (Test-Path -LiteralPath $referencePath -PathType Leaf)) {
    throw "Approved Widget reference is missing: $referencePath"
}
$referenceSha256 = (Get-FileHash -LiteralPath $referencePath -Algorithm SHA256).Hash
if ($referenceSha256 -ne $expectedReferenceSha256) {
    throw "Widget reference SHA-256 drifted: expected $expectedReferenceSha256 observed $referenceSha256"
}

$captureDirectory = Join-Path $artifactRoot 'design-evidence\v0.3.0\issue-16\contract-backed-wpf'
$requiredCaptures = @(
    'notification-th-328x410.png',
    'notification-en-328x410.png',
    'agent-detail-th-340x448.png',
    'agent-detail-en-340x448.png'
)
$captureEvidence = foreach ($captureName in $requiredCaptures) {
    $capturePath = Join-Path $captureDirectory $captureName
    if (-not (Test-Path -LiteralPath $capturePath -PathType Leaf)) {
        throw "Required actual WPF notification capture is missing: $capturePath"
    }
    if ((Get-Item -LiteralPath $capturePath).Length -le 4000) {
        throw "Actual WPF notification capture is unexpectedly small: $capturePath"
    }

    [pscustomobject]@{
        Name = $captureName
        Sha256 = (Get-FileHash -LiteralPath $capturePath -Algorithm SHA256).Hash
    }
}
if ($captureEvidence[0].Sha256 -eq $captureEvidence[1].Sha256 -or
    $captureEvidence[2].Sha256 -eq $captureEvidence[3].Sha256) {
    throw 'Thai and English notification evidence must be separately rendered bytes.'
}

foreach ($requiredFile in @($contractPath, $designRecordPath, $reviewRecordPath)) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
        throw "Required Issue #16 record is missing: $requiredFile"
    }
}

$sourceCommit = (& git -C $repositoryRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($sourceCommit)) {
    throw 'Could not resolve the source commit for the v0.3 notification gate.'
}
$sourceTree = (& git -C $repositoryRoot rev-parse 'HEAD^{tree}').Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($sourceTree)) {
    throw 'Could not resolve the source tree for the v0.3 notification gate.'
}
$contractSha256 = (Get-FileHash -LiteralPath $contractPath -Algorithm SHA256).Hash
$reviewRecordSha256 = (Get-FileHash -LiteralPath $reviewRecordPath -Algorithm SHA256).Hash
$gateReportPath = Join-Path $gateDirectory 'gate-report.txt'
$gateReport = @(
    'HerdrOps v0.3 Issue #16 Notification and Agent Popup Implementation Gate',
    "GeneratedUtc: $([DateTime]::UtcNow.ToString('O'))",
    "SourceCommit: $sourceCommit",
    "SourceTree: $sourceTree",
    'Result: IMPLEMENTATION READY / PARTIAL',
    'ImplementationGate: PASS',
    'IssueAcceptance: PENDING',
    'VersionReleaseGate: PENDING',
    'ContractBackedWpfRuntime: OBSERVED',
    'ActualHerdrNotificationDelivery: NOT OBSERVED / NOT CLAIMED',
    'ActualHerdrAgentTaskCorrelation: NOT OBSERVED / NOT CLAIMED',
    'RestartPersistence: NOT IMPLEMENTED / NOT CLAIMED',
    'IssueStateRequired: OPEN',
    "Tests: $passedTests/$totalTests PASS",
    "ReferenceSha256: $referenceSha256",
    "ContractSha256: $contractSha256",
    "IndependentReviewRecordSha256: $reviewRecordSha256",
    'HistoryBound: 128 notifications',
    'IdentityBound: 512 exact identities',
    'VisibleGroupBound: 32 groups',
    'PresentationGroupMemoryBound: 512 groups',
    'WidgetRowBound: 4 groups',
    'UrgentSuppressionWindow: 30 seconds per group',
    'LanguageModes: Thai-only or English-only interface copy',
    '',
    'WpfCaptures:'
) + ($captureEvidence | ForEach-Object { "$($_.Name): $($_.Sha256)" }) + @(
    '',
    'RequiredChecks:'
) + ($requiredChecks | ForEach-Object { "PASS $_" }) + @(
    '',
    'EvidenceBoundary:',
    'This gate proves bounded in-process history and identity memory, deterministic grouping, urgent popup suppression, monotonic acknowledgement, exact event/Agent route forwarding, fail-closed target selection, separated Thai/English interface rendering, keyboard-accessible actions, and actual WPF rendering/interaction from contract-backed synthetic inputs.',
    'It does not prove notification delivery from an installed Herdr session, actual end-to-end latency, actual Herdr Agent/Task correlation, redaction against live terminal or file bytes, durable acknowledgement across restart, Issue #16 acceptance, or v0.3 release readiness.'
)
$gateReport | Set-Content -LiteralPath $gateReportPath -Encoding utf8
$gateReport | Write-Output
Write-Output "GateReport: $gateReportPath"
