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
$fixturePath = Join-Path $repositoryRoot 'tests\fixtures\v0.6\scoring-golden-v1.json'
$contractPath = Join-Path $repositoryRoot 'docs\protocol\v0.6-explainable-scoring-contract.md'
$enginePath = Join-Path $repositoryRoot 'src\HerdrOps.Domain\Evaluation\ExplainableScoring.cs'
$expectedFormulaSha256 = '3CF788794C58DA11408E8D3E8F3876C88B3F48F4D19082DBCDEE4FE8B8874DFB'
$expectedInputSha256 = '574776C1E31A4A9E994AA9B19FD920453DBD6EE669F9E5516B3137FD77CFC5A1'
$expectedResultSha256 = '9A123504715F1041673FED0E801D9224EBA51A9A21517B4C89FE4CBBF6F5AFD5'

$workingTreeStatus = @(& git -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0) {
    throw 'Could not inspect the source working tree for the v0.6 scoring gate.'
}
if ($workingTreeStatus.Count -ne 0) {
    throw "The v0.6 scoring gate requires a clean committed checkout. Pending paths: $($workingTreeStatus -join ', ')"
}

foreach ($requiredPath in @($fixturePath, $contractPath, $enginePath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Required v0.6 scoring artifact was not found: $requiredPath"
    }
}

if (-not $SkipBuild) {
    & (Join-Path $PSScriptRoot 'Invoke-Build.ps1') -Configuration $Configuration -VerifyFormat
    if ($LASTEXITCODE -ne 0) {
        throw "v0.6 scoring build gate failed with exit code $LASTEXITCODE."
    }
}

$runId = "$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ', [Globalization.CultureInfo]::InvariantCulture))-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
$gateDirectory = Join-Path $artifactRoot "release-gates\v0.6.0\issue-30\$runId"
$testResultDirectory = Join-Path $gateDirectory 'test-results'
New-Item -ItemType Directory -Path $testResultDirectory -Force | Out-Null

$testProject = Join-Path $repositoryRoot 'tests\HerdrOps.UnitTests\HerdrOps.UnitTests.csproj'
& dotnet test $testProject `
    --configuration $Configuration `
    --no-restore `
    --no-build `
    --artifacts-path $artifactRoot `
    --results-directory $testResultDirectory `
    --filter 'FullyQualifiedName~ExplainableScoringTests' `
    --logger trx
if ($LASTEXITCODE -ne 0) {
    throw 'v0.6 explainable-scoring evidence tests failed.'
}

$testResults = @(Get-ChildItem -LiteralPath $testResultDirectory -Filter '*.trx' -File)
if ($testResults.Count -ne 1) {
    throw "Expected exactly one fresh scoring TRX file, found $($testResults.Count)."
}

$testLog = Get-Content -LiteralPath $testResults[0].FullName -Raw
$requiredChecks = @(
    'GoldenVersion1FixtureIsDeterministicAndExplainable',
    'MissingScoreRemainsVisibleAndCannotProduceAnOverallPass',
    'InvalidScoreAndProvenanceRemainVisibleAndCannotProduceAResult',
    'MissingAndDuplicateDimensionsFailClosed',
    'HistoricalResultRecalculatesFromItsFrozenFormulaAfterCatalogChanges',
    'HistoricalRecalculationRejectsTamperedResultAndInputProvenance',
    'FormulaRejectsMissingDimensionsWeightDriftAndHashTampering'
)
foreach ($check in $requiredChecks) {
    if ($testLog -notmatch [Regex]::Escape($check)) {
        throw "Required v0.6 scoring check is absent from the fresh test log: $check"
    }
}

[xml]$trx = $testLog
$counters = $trx.TestRun.ResultSummary.Counters
$totalTests = [int]$counters.total
$passedTests = [int]$counters.passed
$failedTests = [int]$counters.failed
if ($totalTests -ne $requiredChecks.Count -or $failedTests -ne 0 -or $passedTests -ne $totalTests) {
    throw "Scoring test counters are not all passing: total=$totalTests passed=$passedTests failed=$failedTests"
}

$fixture = Get-Content -LiteralPath $fixturePath -Raw | ConvertFrom-Json
if (@($fixture.input.dimensions).Count -ne 6) {
    throw 'The golden scoring fixture must contain exactly six dimensions.'
}
if ([decimal]$fixture.expectedTotalScore -ne [decimal]82.23) {
    throw "Unexpected golden total score: $($fixture.expectedTotalScore)"
}
if ($fixture.expectedFormulaSha256 -ne $expectedFormulaSha256 -or
    $fixture.expectedInputSnapshotSha256 -ne $expectedInputSha256 -or
    $fixture.expectedResultSha256 -ne $expectedResultSha256) {
    throw 'Golden scoring fixture hashes drifted from the accepted v1 contract.'
}

$scoreCount = 0
foreach ($dimension in @($fixture.input.dimensions)) {
    foreach ($sourceName in @('leader', 'projectManager', 'objectiveEvidence')) {
        $source = $dimension.$sourceName
        if ($null -eq $source -or
            [int]$source.score -lt 0 -or
            [int]$source.score -gt 100 -or
            [string]::IsNullOrWhiteSpace([string]$source.provenanceId) -or
            [string]$source.provenanceSha256 -notmatch '^[0-9A-F]{64}$') {
            throw "Golden scoring fixture contains an invalid source: $($dimension.dimension)/$sourceName"
        }
        $scoreCount++
    }
}
if ($scoreCount -ne 18) {
    throw "Expected exactly 18 source scores, found $scoreCount."
}

$sourceCommit = (& git -C $repositoryRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($sourceCommit)) {
    throw 'Could not resolve the source commit for the v0.6 scoring gate.'
}
$fixtureSha256 = (Get-FileHash -LiteralPath $fixturePath -Algorithm SHA256).Hash
$contractSha256 = (Get-FileHash -LiteralPath $contractPath -Algorithm SHA256).Hash
$engineSha256 = (Get-FileHash -LiteralPath $enginePath -Algorithm SHA256).Hash
$gateReportPath = Join-Path $gateDirectory 'gate-report.txt'
$gateReport = @(
    'HerdrOps v0.6 Issue #30 Versioned Explainable Scoring Engine Gate',
    "GeneratedUtc: $([DateTime]::UtcNow.ToString('O'))",
    "SourceCommit: $sourceCommit",
    'Result: PASS',
    'IssueAcceptance: PASS',
    'VersionReleaseGate: PENDING',
    'EvidenceClass: Contract plus Synthetic plus Unit',
    'IndependentReview: NOT OBSERVED / NOT CLAIMED',
    'ActualHerdrRuntime: NOT REQUIRED / NOT OBSERVED / NOT CLAIMED',
    'ProductionScoreIngestion: NOT OBSERVED / NOT CLAIMED',
    'EvaluationUi: NOT IMPLEMENTED IN ISSUE #30',
    "Tests: $passedTests/$totalTests PASS",
    'Dimensions: 6',
    'SourceScores: 18',
    'GoldenTotalScore: 82.23',
    "FormulaSha256: $expectedFormulaSha256",
    "InputSnapshotSha256: $expectedInputSha256",
    "ResultSha256: $expectedResultSha256",
    "FixtureFileSha256: $fixtureSha256",
    "ContractFileSha256: $contractSha256",
    "EngineFileSha256: $engineSha256",
    '',
    'RequiredChecks:'
) + ($requiredChecks | ForEach-Object { "PASS $_" }) + @(
    '',
    'EvidenceBoundary:',
    'This gate proves deterministic versioned scoring against a committed golden fixture, source-distinct weighted inputs, fail-closed missing and invalid data, hash-bound provenance, tamper rejection, and historical recalculation from the retained formula and input snapshot.',
    'It does not prove production ingestion, reviewer authority, Evaluation or Daily Summary rendering, actual Herdr operation, independent acceptance, or v0.6 release readiness.'
)
$gateReport | Set-Content -LiteralPath $gateReportPath -Encoding utf8
$gateReport | Write-Output
Write-Output "GateReport: $gateReportPath"
