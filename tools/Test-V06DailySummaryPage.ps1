[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',

    [switch]$SkipBuild
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$artifactRoot = Join-Path $repositoryRoot 'artifacts'
$gateDirectory = Join-Path $artifactRoot 'release-gates\v0.6.0\issue-32'
$testResultDirectory = Join-Path $gateDirectory 'test-results'
$gateReportPath = Join-Path $gateDirectory 'gate-report.txt'

$referencePath = Join-Path $repositoryRoot 'docs\design\reference\10-daily-summary.png'
$referenceManifestPath = Join-Path $repositoryRoot 'docs\design\reference\MANIFEST.md'
$contractPath = Join-Path $repositoryRoot 'docs\protocol\v0.6-daily-summary-contract.md'
$fixturePath = Join-Path $repositoryRoot 'tests\fixtures\v0.6\daily-summary-aggregation.json'
$sourcePaths = [ordered]@{
    DomainAggregator = Join-Path $repositoryRoot 'src\HerdrOps.Domain\Summaries\DailySummaryAggregation.cs'
    AppState = Join-Path $repositoryRoot 'src\HerdrOps.App\Summaries\DailySummaryState.cs'
    AppLocalization = Join-Path $repositoryRoot 'src\HerdrOps.App\Localization\UiLanguageService.cs'
    DailySummaryView = Join-Path $repositoryRoot 'src\HerdrOps.App\Views\DailySummaryView.xaml'
    AggregationTests = Join-Path $repositoryRoot 'tests\HerdrOps.UnitTests\DailySummaryAggregationTests.cs'
    StateTests = Join-Path $repositoryRoot 'tests\HerdrOps.IntegrationTests\DailySummaryStateTests.cs'
    RenderingTests = Join-Path $repositoryRoot 'tests\HerdrOps.RuntimeTests\DailySummaryRenderingTests.cs'
}

$expectedReferenceSha256 = 'A44CAFDFB9A8B34694B67B6AABAD86B8B65A99A8A947C7CAB83C11FE7464F693'
$expectedReferenceBytes = 1627596
$expectedInputSha256 = [ordered]@{
    ReferenceManifest = '69443149315192A8E18D326889B085509D9C834C65F69B304E74F325B31D7315'
    ContractFile = '96114EA15834899DE156B66E5AB2B44D075F3E1D8A95959C16B2BD105D366BDD'
    FixtureFile = '1D1C01768860B3707EEF3D106ADBBC6A30B989BC652C760EFBA8B4247FB96BCD'
    DomainAggregator = 'E22D26239663F5FB56BD117C0993D0785593E9C136073E90524BDB25BD1B498C'
    AppState = 'D1328D2244206F5FF8FDC3B62CFB4CBB203377C7757EF8580D709ADC8E50189E'
    AppLocalization = '1A8278BBFD37CFEAC1A516C658EEA3D5877B66F06F4266D2B269333CB02E0EA1'
    DailySummaryView = '881A04EC1C19E530ED0E939461095AAD1C9502AA5B782BA53F1AC60244F6A1FF'
    AggregationTests = 'FFC61486DF8C47C5757C449618C52B9EC72093C8A4B7D5610983FBD7D3592FCE'
    StateTests = '662C9AB49E03FE507D9E13AD334AAB0A12BF8471E9DE2509D952E4733BD8AEAF'
    RenderingTests = '903D00A2C8C8C9B52D516FF6D5C2E191F47F7519E279BAC51DF7D4A5056EAFDC'
}

function Get-FileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    return ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash).ToUpperInvariant()
}

function Invoke-TargetedTest {
    param(
        [Parameter(Mandatory = $true)][string]$EvidenceName,
        [Parameter(Mandatory = $true)][string]$ProjectPath,
        [Parameter(Mandatory = $true)][string]$Filter,
        [Parameter(Mandatory = $true)][string]$LogFileName
    )

    $logPath = Join-Path $testResultDirectory $LogFileName
    if (Test-Path -LiteralPath $logPath -PathType Leaf) {
        Remove-Item -LiteralPath $logPath -Force
    }

    & dotnet test $ProjectPath `
        --configuration $Configuration `
        --no-restore `
        --no-build `
        --artifacts-path $artifactRoot `
        --results-directory $testResultDirectory `
        --filter $Filter `
        --logger ("trx;LogFileName=" + $LogFileName)
    if ($LASTEXITCODE -ne 0) {
        throw "$EvidenceName failed with exit code $LASTEXITCODE."
    }
    if (-not (Test-Path -LiteralPath $logPath -PathType Leaf)) {
        throw "$EvidenceName did not produce the expected TRX file: $logPath"
    }

    [xml]$testRun = Get-Content -LiteralPath $logPath -Raw
    $counters = $testRun.TestRun.ResultSummary.Counters
    if ($null -eq $counters) {
        throw "$EvidenceName TRX file has no result counters: $logPath"
    }
    $total = [int]$counters.total
    $passed = [int]$counters.passed
    $failed = [int]$counters.failed
    if ($total -le 0 -or $failed -ne 0 -or $passed -ne $total) {
        throw "$EvidenceName did not pass completely: total=$total passed=$passed failed=$failed"
    }

    return [pscustomobject]@{
        Name = $EvidenceName
        Total = $total
        Passed = $passed
        LogPath = $logPath
    }
}

$workingTreeStatus = @(& git -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0) {
    throw 'Could not inspect the source working tree for the v0.6 Daily Summary gate.'
}
if ($workingTreeStatus.Count -ne 0) {
    throw "The v0.6 Daily Summary gate requires a clean committed checkout. Pending paths: $($workingTreeStatus -join ', ')"
}

$requiredPaths = @($referencePath, $referenceManifestPath, $contractPath, $fixturePath) + @($sourcePaths.Values)
foreach ($requiredPath in $requiredPaths) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Required v0.6 Daily Summary input was not found: $requiredPath"
    }
}

if (-not $SkipBuild) {
    & (Join-Path $PSScriptRoot 'Invoke-Build.ps1') -Configuration $Configuration
    if ($LASTEXITCODE -ne 0) {
        throw "v0.6 Daily Summary build gate failed with exit code $LASTEXITCODE."
    }
}

$referenceItem = Get-Item -LiteralPath $referencePath
if ($referenceItem.Length -ne $expectedReferenceBytes) {
    throw "Daily Summary reference byte count drifted: expected $expectedReferenceBytes observed $($referenceItem.Length)"
}
$referenceSha256 = Get-FileSha256 -Path $referencePath
if ($referenceSha256 -ne $expectedReferenceSha256) {
    throw "Daily Summary reference SHA-256 drifted: expected $expectedReferenceSha256 observed $referenceSha256"
}

$manifestText = Get-Content -LiteralPath $referenceManifestPath -Raw
if ($manifestText -notmatch [Regex]::Escape('10-daily-summary.png') -or
    $manifestText -notmatch [Regex]::Escape($expectedReferenceSha256)) {
    throw 'Daily Summary reference is not pinned by the immutable design manifest.'
}

$contractText = Get-Content -LiteralPath $contractPath -Raw
$contractMarkers = @(
    'HERDROPS-DAILY-SUMMARY-V1',
    'SourceSetSha256',
    'ResultSha256',
    'accepted source set',
    'Actual Herdr Runtime',
    'NOT OBSERVED'
)
foreach ($marker in $contractMarkers) {
    if ($contractText -notmatch [Regex]::Escape($marker)) {
        throw "Daily Summary contract is missing the required marker: $marker"
    }
}

$fixture = Get-Content -LiteralPath $fixturePath -Raw | ConvertFrom-Json
if ([int]$fixture.contractVersion -ne 1 -or @($fixture.sources).Count -ne 8) {
    throw 'Daily Summary fixture must be contract version 1 with exactly eight source records.'
}
if ([int]$fixture.expected.acceptedSourceCount -ne 5 -or
    [int]$fixture.expected.activityCount -ne 4 -or
    [int]$fixture.expected.evidenceCount -ne 1 -or
    [int]$fixture.expected.workstreamCount -ne 3 -or
    [int]$fixture.expected.highlightCount -ne 2 -or
    [int]$fixture.expected.repeatedIssueCount -ne 1 -or
    [int]$fixture.expected.recommendedActionCount -ne 2 -or
    [int]$fixture.expected.timelineCount -ne 5) {
    throw 'Daily Summary fixture expected counts drifted from the accepted contract.'
}

$seenSourceIds = @{}
foreach ($source in @($fixture.sources)) {
    $sourceId = [string]$source.sourceId
    if ([string]::IsNullOrWhiteSpace($sourceId) -or $seenSourceIds.ContainsKey($sourceId)) {
        throw "Daily Summary fixture contains a missing or duplicate source ID: $sourceId"
    }
    $seenSourceIds[$sourceId] = $true
    if ([string]$source.sourceHashSha256 -notmatch '^[0-9A-Fa-f]{64}$') {
        throw "Daily Summary fixture contains an invalid source hash: $sourceId"
    }
}

$sourceCommit = (& git -C $repositoryRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($sourceCommit)) {
    throw 'Could not resolve the source commit for the v0.6 Daily Summary gate.'
}

$observedHashes = [ordered]@{
    ReferenceManifest = Get-FileSha256 -Path $referenceManifestPath
    ContractFile = Get-FileSha256 -Path $contractPath
    FixtureFile = Get-FileSha256 -Path $fixturePath
}
foreach ($sourceName in $sourcePaths.Keys) {
    $observedHashes[$sourceName] = Get-FileSha256 -Path $sourcePaths[$sourceName]
}
foreach ($hashName in $expectedInputSha256.Keys) {
    if ($observedHashes[$hashName] -ne $expectedInputSha256[$hashName]) {
        throw "Pinned Daily Summary input hash drifted for $hashName`: expected $($expectedInputSha256[$hashName]) observed $($observedHashes[$hashName])"
    }
}

New-Item -ItemType Directory -Path $testResultDirectory -Force | Out-Null
$unitProject = Join-Path $repositoryRoot 'tests\HerdrOps.UnitTests\HerdrOps.UnitTests.csproj'
$integrationProject = Join-Path $repositoryRoot 'tests\HerdrOps.IntegrationTests\HerdrOps.IntegrationTests.csproj'
$runtimeProject = Join-Path $repositoryRoot 'tests\HerdrOps.RuntimeTests\HerdrOps.RuntimeTests.csproj'
$contractProject = Join-Path $repositoryRoot 'tests\HerdrOps.ContractTests\HerdrOps.ContractTests.csproj'

$syntheticTests = @(
    Invoke-TargetedTest -EvidenceName 'Daily Summary aggregation synthetic tests' -ProjectPath $unitProject -Filter 'FullyQualifiedName~DailySummaryAggregationTests' -LogFileName 'daily-summary-aggregation.trx'
    Invoke-TargetedTest -EvidenceName 'Daily Summary state synthetic tests' -ProjectPath $integrationProject -Filter 'FullyQualifiedName~DailySummaryStateTests' -LogFileName 'daily-summary-state.trx'
    Invoke-TargetedTest -EvidenceName 'Daily Summary WPF synthetic rendering tests' -ProjectPath $runtimeProject -Filter 'FullyQualifiedName~DailySummaryRenderingTests' -LogFileName 'daily-summary-rendering.trx'
)
$contractTests = @(
    Invoke-TargetedTest -EvidenceName 'Immutable design reference contract tests' -ProjectPath $contractProject -Filter 'FullyQualifiedName~DesignReferenceIntegrityTests' -LogFileName 'daily-summary-reference-contract.trx'
)

$hashLines = @(
    "ReferenceFileSha256: $referenceSha256"
    "ReferenceManifestSha256: $($observedHashes.ReferenceManifest)"
    "ContractFileSha256: $($observedHashes.ContractFile)"
    "FixtureFileSha256: $($observedHashes.FixtureFile)"
)
foreach ($sourceName in $sourcePaths.Keys) {
    $hashLines += "${sourceName}Sha256: $($observedHashes[$sourceName])"
}

$report = @(
    'HerdrOps v0.6 Issue #32 Daily Summary Page Gate'
    "SourceCommit: $sourceCommit"
    'Result: PASS'
    'IssueAcceptance: IMPLEMENTATION EVIDENCE ONLY'
    'VersionReleaseGate: PENDING'
    ''
    'StaticEvidence: PASS'
    'StaticChecks: clean committed checkout; required source, fixture, contract and immutable reference inputs; fixture shape and expected counts; exact reference bytes and manifest pin'
    ''
    'SyntheticEvidence: PASS'
    ('SyntheticTests: ' + (($syntheticTests | ForEach-Object { "$($_.Name) $($_.Passed)/$($_.Total) PASS" }) -join '; '))
    'SyntheticBoundary: Deterministic fixture, state projection and in-process WPF rendering only'
    ''
    'ContractEvidence: PASS'
    ('ContractTests: ' + (($contractTests | ForEach-Object { "$($_.Name) $($_.Passed)/$($_.Total) PASS" }) -join '; '))
    'ContractBoundary: Contract document markers and immutable reference manifest are validated; no Herdr transport is exercised'
    ''
    'Actual Herdr Runtime: NOT OBSERVED'
    'Independent Review: NOT OBSERVED'
    'Release Evidence: NOT OBSERVED'
    'Production ingestion, event/evidence admission, reviewer authority and local export: NOT OBSERVED / NOT CLAIMED'
    ''
    'PinnedHashes:'
) + $hashLines + @(
    ''
    'EvidenceBoundary:'
    'This gate proves only committed Static, Synthetic and Contract checks for Issue #32. It does not prove an installed Herdr session, live Agent events, runtime resource usage, independent acceptance, packaging, release readiness or v0.6 completion.'
    "GateReport: $gateReportPath"
)
$report | Set-Content -LiteralPath $gateReportPath -Encoding UTF8
$report | Write-Output
