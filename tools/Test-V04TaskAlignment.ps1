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
$referencePath = Join-Path $repositoryRoot 'docs\design\reference\06-task-alignment.png'
$expectedReferenceSha256 = '0A9AEBBFB97C23F2A0593248E9FFADFD5F5B4579161ED340496E2BD3B45E832D'

$workingTreeStatus = @(& git -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0) {
    throw 'Could not inspect the source working tree for the v0.4 Task Alignment gate.'
}
if ($workingTreeStatus.Count -ne 0) {
    throw "The v0.4 Task Alignment gate requires a clean committed checkout. Pending paths: $($workingTreeStatus -join ', ')"
}

if (-not $SkipBuild) {
    & (Join-Path $PSScriptRoot 'Invoke-Build.ps1') -Configuration $Configuration -VerifyFormat
    if ($LASTEXITCODE -ne 0) {
        throw "v0.4 Task Alignment build gate failed with exit code $LASTEXITCODE."
    }
}

$runId = "$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ', [Globalization.CultureInfo]::InvariantCulture))-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
$gateDirectory = Join-Path $artifactRoot "release-gates\v0.4.0\issue-21\$runId"
$testResultDirectory = Join-Path $gateDirectory 'test-results'
New-Item -ItemType Directory -Path $testResultDirectory -Force | Out-Null

$testRuns = @(
    [pscustomobject]@{
        Project = Join-Path $repositoryRoot 'tests\HerdrOps.UnitTests\HerdrOps.UnitTests.csproj'
        Filter = 'FullyQualifiedName~TaskAlignmentAnalysisTests'
        Log = 'task-alignment-analysis.trx'
    },
    [pscustomobject]@{
        Project = Join-Path $repositoryRoot 'tests\HerdrOps.IntegrationTests\HerdrOps.IntegrationTests.csproj'
        Filter = 'FullyQualifiedName~TaskAlignmentStateTests|FullyQualifiedName~UiLanguageCatalogTests'
        Log = 'task-alignment-state-language.trx'
    },
    [pscustomobject]@{
        Project = Join-Path $repositoryRoot 'tests\HerdrOps.RuntimeTests\HerdrOps.RuntimeTests.csproj'
        Filter = 'FullyQualifiedName~TaskAlignmentRenderingTests'
        Log = 'task-alignment-rendering.trx'
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
        throw "v0.4 Task Alignment evidence tests failed: $($testRun.Project)"
    }
}

$testResults = @(Get-ChildItem -LiteralPath $testResultDirectory -Filter '*.trx' -File)
if ($testResults.Count -ne 3) {
    throw "Expected exactly 3 fresh Task Alignment TRX files, found $($testResults.Count)."
}

$combinedTestLog = ($testResults | ForEach-Object {
    Get-Content -LiteralPath $_.FullName -Raw
}) -join "`n"
$requiredChecks = @(
    'AnalysisIsDeterministicAndEveryConclusionRetainsSupportingInputs',
    'MissingObservationsCannotBecomePassingScoresOrVerdict',
    'OutOfScopeObservationIsSuspectedUntilReviewConfirmsViolation',
    'ApprovedDeviationCanAuthorizeOnlyItsLinkedPathAndRetainsLifecycleProvenance',
    'MissingLifecycleEvidenceCannotSatisfyAcceptanceCriteria',
    'AnalyzerRejectsContractWhoseCanonicalBytesWereChangedAfterSigning',
    'AnalyzerRejectsContractThatTargetsAnUnknownLifecycleTask',
    'SyntheticProjectionUsesAnalyzerResultsAndPopulatesAllReferencePanels',
    'LanguageRefreshRebuildsAllSyntheticCopyWithoutRetainingThaiText',
    'ProductionDashboardFailsClosedUntilAllAdmittedAnalysisInputsExist',
    'ThaiIsTheDefaultAndBothCatalogsContainTheSameNonEmptyKeys',
    'ThaiCatalogUsesThaiCoreTerminologyWithoutEnglishLabel',
    'EveryV01XamlLanguageBindingExistsAndNoBilingualLiteralRemains',
    'SyntheticOverviewAndWidgetCopyRebuildsAsOneSelectedLanguage',
    'LiveDashboardCopyRebuildsFromThaiToEnglishWithoutRetainingThaiText',
    'ActualWpfTaskAlignmentRendersLocalizedTraceableReferenceRegions',
    'RenderedProjectionExposesAnalyzerVerdictScoresAndEvidenceBoundary'
)
foreach ($check in $requiredChecks) {
    if ($combinedTestLog -notmatch [Regex]::Escape($check)) {
        throw "Required v0.4 Task Alignment check is absent from fresh test logs: $check"
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
    throw "Task Alignment counters are not the expected all-pass set: total=$totalTests passed=$passedTests failed=$failedTests"
}

if (-not (Test-Path -LiteralPath $referencePath -PathType Leaf)) {
    throw "Approved Task Alignment reference is missing: $referencePath"
}
$referenceSha256 = (Get-FileHash -LiteralPath $referencePath -Algorithm SHA256).Hash
if ($referenceSha256 -ne $expectedReferenceSha256) {
    throw "Task Alignment reference SHA-256 drifted: expected $expectedReferenceSha256 observed $referenceSha256"
}

$captureDirectory = Join-Path $artifactRoot 'design-evidence\v0.4.0\issue-21\contract-backed-wpf'
$requiredCaptures = @(
    'task-alignment-th-1672x941.png',
    'task-alignment-th-1366x768.png',
    'task-alignment-en-1672x941.png'
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
if ($captureEvidence[0].Sha256 -eq $captureEvidence[2].Sha256) {
    throw 'Thai and English Task Alignment evidence rendered identically.'
}

$sourceCommit = (& git -C $repositoryRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($sourceCommit)) {
    throw 'Could not resolve the source commit for the v0.4 Task Alignment gate.'
}

$gateReportPath = Join-Path $gateDirectory 'gate-report.txt'
$gateReport = @(
    'HerdrOps v0.4 Issue #21 Task Alignment Implementation Gate',
    "GeneratedUtc: $([DateTime]::UtcNow.ToString('O'))",
    "SourceCommit: $sourceCommit",
    'Result: IMPLEMENTATION READY / PARTIAL',
    'ImplementationGate: PASS',
    'IssueAcceptance: PENDING INDEPENDENT REVIEW',
    'VersionReleaseGate: PENDING',
    'EvidenceClass: Contract plus deterministic analysis plus actual WPF rendering',
    'ActualHerdrLifecycleFeed: NOT OBSERVED / NOT CLAIMED',
    'InstalledHerdrRuntime: NOT OBSERVED / NOT CLAIMED',
    'IssueStateRequired: OPEN UNTIL INDEPENDENT REVIEW',
    "Tests: $passedTests/$totalTests PASS",
    "ApprovedReferenceSha256: $referenceSha256",
    "ActualWpfCaptures: $($requiredCaptures.Count)",
    'VerdictModes: Insufficient Data, Aligned, Partially Misaligned, Suspected Violation, Confirmed Violation',
    'MissingDataPolicy: no missing acknowledgement, action, file, or evidence input can become a passing score',
    'ReviewBoundary: automated out-of-scope signals remain suspected until a distinct review decision confirms them',
    'LanguageModes: Thai-only or English-only interface copy',
    '',
    'RequiredChecks:'
) + ($requiredChecks | ForEach-Object { "PASS $_" }) + @(
    '',
    'CaptureHashes:'
) + ($captureEvidence | ForEach-Object { "SHA256 $($_.Sha256) $($_.Name)" }) + @(
    '',
    'EvidenceBoundary:',
    'This gate proves canonical contract hashing, lifecycle-provenance binding, traceable goal/scope/acceptance findings, missing-data fail-closed behavior, suspected-versus-confirmed separation, approved deviation linkage, language separation, approved-reference binding, and actual WPF rendering from a deterministic contract-backed fixture.',
    'It does not prove an installed Herdr session, actual Core delivery of alignment inputs, actual Agent file activity, independent Issue #21 acceptance, Issue #22 runtime acceptance, or v0.4 release readiness.',
    'Issue #21 must remain open until an independent reviewer accepts the committed implementation and evidence.'
)
$gateReport | Set-Content -LiteralPath $gateReportPath -Encoding utf8
$gateReport | Write-Output
Write-Output "GateReport: $gateReportPath"
