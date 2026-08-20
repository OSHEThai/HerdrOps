[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',

    [switch]$SkipBuild
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\V06GateProvenance.ps1')

$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$artifactRoot = Join-Path $repositoryRoot 'artifacts'
$runId = "$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ', [Globalization.CultureInfo]::InvariantCulture))-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
$gateDirectory = Join-Path $artifactRoot "release-gates\v0.6.0\issue-32\$runId"
$testResultDirectory = Join-Path $gateDirectory 'test-results'
$gateReportPath = Join-Path $gateDirectory 'gate-report.txt'

$referencePath = Join-Path $repositoryRoot 'docs\design\reference\10-daily-summary.png'
$referenceManifestPath = Join-Path $repositoryRoot 'docs\design\reference\MANIFEST.md'
$contractPath = Join-Path $repositoryRoot 'docs\protocol\v0.6-daily-summary-contract.md'
$fixturePath = Join-Path $repositoryRoot 'tests\fixtures\v0.6\daily-summary-aggregation.json'
$ownedSourcePaths = [ordered]@{
    AppState = Join-Path $repositoryRoot 'src\HerdrOps.App\Summaries\DailySummaryState.cs'
    DailySummaryView = Join-Path $repositoryRoot 'src\HerdrOps.App\Views\DailySummaryView.xaml'
    DailySummaryViewCodeBehind = Join-Path $repositoryRoot 'src\HerdrOps.App\Views\DailySummaryView.xaml.cs'
    AggregationTests = Join-Path $repositoryRoot 'tests\HerdrOps.UnitTests\DailySummaryAggregationTests.cs'
    StateTests = Join-Path $repositoryRoot 'tests\HerdrOps.IntegrationTests\DailySummaryStateTests.cs'
    RenderingTests = Join-Path $repositoryRoot 'tests\HerdrOps.RuntimeTests\DailySummaryRenderingTests.cs'
}
$sharedIntegrationPaths = [ordered]@{
    DomainAggregator = Join-Path $repositoryRoot 'src\HerdrOps.Domain\Summaries\DailySummaryAggregation.cs'
    AppLocalization = Join-Path $repositoryRoot 'src\HerdrOps.App\Localization\UiLanguageService.cs'
    ShellView = Join-Path $repositoryRoot 'src\HerdrOps.App\Views\ShellView.xaml'
    ShellViewCodeBehind = Join-Path $repositoryRoot 'src\HerdrOps.App\Views\ShellView.xaml.cs'
}

$expectedReferenceSha256 = 'A44CAFDFB9A8B34694B67B6AABAD86B8B65A99A8A947C7CAB83C11FE7464F693'
$expectedReferenceBytes = 1627596
$expectedInputSha256 = [ordered]@{
    ReferenceManifest = '69443149315192A8E18D326889B085509D9C834C65F69B304E74F325B31D7315'
    ContractFile = '96114EA15834899DE156B66E5AB2B44D075F3E1D8A95959C16B2BD105D366BDD'
    FixtureFile = 'E23B9CB2AD1ADA6F603311F8F2F5D25FB45DC03C2934860C0AF8039D6591F07F'
    AppState = 'AA84CC88AC8088D91B411C9B63C08EEE96C086CF5901857370494EBE7F8D36AE'
    DailySummaryView = 'A0A7CC0FF456A19263AE4CAAE7A8623F12D81E10371AE7873803EADAA69AC71B'
    DailySummaryViewCodeBehind = '4E203E43A18041BF4BAC2A018AE4BEB0AEB0A1231B3087FC5BC2B9886F406E06'
    AggregationTests = '36304E025D3B3B22C28AC090F50F069D1A4DBA50C27A5D7F05C088CCD7F4D190'
    StateTests = 'B4E27B7E098CA063AC74E7138A9D317C91157ACF1B0FB35ED17319703A35571C'
    RenderingTests = '197BB91065B87EAAA75515E78584D5A587975314B2324C19FEFC0ABCCE20AA8D'
}

function Get-FileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    return ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash).ToUpperInvariant()
}

function Assert-ContainsText {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)][string[]]$RequiredText
    )

    $content = Get-Content -LiteralPath $Path -Raw
    foreach ($marker in $RequiredText) {
        if ($content.IndexOf($marker, [StringComparison]::Ordinal) -lt 0) {
            throw "$Description is missing required marker: $marker"
        }
    }
}

function Get-PngDimensions {
    param([Parameter(Mandatory = $true)][string]$Path)

    $bytes = [IO.File]::ReadAllBytes($Path)
    $signature = [byte[]](137, 80, 78, 71, 13, 10, 26, 10)
    if ($bytes.Length -lt 24) {
        throw "PNG evidence is too short: $Path"
    }
    for ($index = 0; $index -lt $signature.Length; $index++) {
        if ($bytes[$index] -ne $signature[$index]) {
            throw "PNG evidence has an invalid signature: $Path"
        }
    }
    if ([Text.Encoding]::ASCII.GetString($bytes, 12, 4) -ne 'IHDR') {
        throw "PNG evidence has no leading IHDR chunk: $Path"
    }

    $width = ([int]$bytes[16] -shl 24) -bor ([int]$bytes[17] -shl 16) -bor
        ([int]$bytes[18] -shl 8) -bor [int]$bytes[19]
    $height = ([int]$bytes[20] -shl 24) -bor ([int]$bytes[21] -shl 16) -bor
        ([int]$bytes[22] -shl 8) -bor [int]$bytes[23]
    return [pscustomobject]@{ Width = $width; Height = $height }
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
        --logger ("trx;LogFileName=" + $LogFileName) *> $null
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

$requiredPaths = @($referencePath, $referenceManifestPath, $contractPath, $fixturePath) +
    @($ownedSourcePaths.Values) + @($sharedIntegrationPaths.Values)
foreach ($requiredPath in $requiredPaths) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Required v0.6 Daily Summary input was not found: $requiredPath"
    }

    $relativePath = $requiredPath.Substring($repositoryRoot.Length).TrimStart('\').Replace('\', '/')
    & git -C $repositoryRoot ls-files --error-unmatch -- $relativePath *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "Required v0.6 Daily Summary input is not tracked by HEAD: $relativePath"
    }
}

Assert-ContainsText `
    -Path $sharedIntegrationPaths.DomainAggregator `
    -Description 'shared Daily Summary aggregation contract' `
    -RequiredText @(
        'public static class DailySummaryAggregator',
        'public static DailySummarySnapshot Aggregate(',
        'SourceSetSha256',
        'AcceptedSources',
        'ResultSha256')
$shellXaml = Get-Content -LiteralPath $sharedIntegrationPaths.ShellView -Raw
$shellCodeBehind = Get-Content -LiteralPath $sharedIntegrationPaths.ShellViewCodeBehind -Raw
$usesStaticPageHost =
    $shellXaml.IndexOf('<views:DailySummaryView', [StringComparison]::Ordinal) -ge 0 -and
    $shellXaml.IndexOf('x:Name="DailySummaryPage"', [StringComparison]::Ordinal) -ge 0
$usesLazyPageHost =
    $shellXaml.IndexOf('<ContentControl x:Name="PageHost"', [StringComparison]::Ordinal) -ge 0 -and
    $shellCodeBehind.IndexOf('case "daily-summary":', [StringComparison]::Ordinal) -ge 0 -and
    $shellCodeBehind.IndexOf('new DailySummaryView', [StringComparison]::Ordinal) -ge 0 -and
    $shellCodeBehind.IndexOf('DataContext = _syntheticPreview', [StringComparison]::Ordinal) -ge 0 -and
    $shellCodeBehind.IndexOf('PageHost.Content = page.Value.Page', [StringComparison]::Ordinal) -ge 0

if (-not $usesStaticPageHost -and -not $usesLazyPageHost) {
    throw 'shared Shell does not expose Daily Summary through a recognized static or lazy page host'
}

if ($usesStaticPageHost) {
    Assert-ContainsText `
        -Path $sharedIntegrationPaths.ShellViewCodeBehind `
        -Description 'shared Shell static-page code-behind' `
        -RequiredText @(
            'DailySummaryPage.DataContext = syntheticPreview',
            '"daily-summary"',
            'DailySummaryPage.Visibility')
}
Assert-ContainsText `
    -Path $sharedIntegrationPaths.AppLocalization `
    -Description 'shared UI language catalog' `
    -RequiredText @(
        '["DailySummaryPageTitle"]',
        '["DailySummaryPageAutomation"]',
        '["DailySummarySyntheticBoundary"]')

if (-not $SkipBuild) {
    & (Join-Path $PSScriptRoot 'Invoke-Build.ps1') -Configuration $Configuration -SkipTests
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
foreach ($sourceName in $ownedSourcePaths.Keys) {
    $observedHashes[$sourceName] = Get-FileSha256 -Path $ownedSourcePaths[$sourceName]
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

$evidenceCaptureStartedUtc = [DateTime]::UtcNow
$syntheticTests = @(
    Invoke-TargetedTest -EvidenceName 'Daily Summary aggregation synthetic tests' -ProjectPath $unitProject -Filter 'FullyQualifiedName~DailySummaryAggregationTests' -LogFileName 'daily-summary-aggregation.trx'
    Invoke-TargetedTest -EvidenceName 'Daily Summary state synthetic tests' -ProjectPath $integrationProject -Filter 'FullyQualifiedName~DailySummaryStateTests' -LogFileName 'daily-summary-state.trx'
    Invoke-TargetedTest -EvidenceName 'Daily Summary WPF synthetic rendering tests' -ProjectPath $runtimeProject -Filter 'FullyQualifiedName~DailySummaryRenderingTests' -LogFileName 'daily-summary-rendering.trx'
)
$contractTests = @(
    Invoke-TargetedTest -EvidenceName 'Immutable design reference contract tests' -ProjectPath $contractProject -Filter 'FullyQualifiedName~DesignReferenceIntegrityTests' -LogFileName 'daily-summary-reference-contract.trx'
)

$captureDirectory = Join-Path $artifactRoot 'design-evidence\v0.6.0\issue-32\daily-summary'
$evidenceStaleAfterUtc = $evidenceCaptureStartedUtc.AddSeconds(-2)
$captureSpecifications = @(
    [pscustomobject]@{ FileName = 'daily-summary-th-1672x941.png'; Width = 1672; Height = 941; Mode = 'Thai reference' }
    [pscustomobject]@{ FileName = 'daily-summary-en-1672x941.png'; Width = 1672; Height = 941; Mode = 'English reference' }
    [pscustomobject]@{ FileName = 'daily-summary-th-1366x768.png'; Width = 1366; Height = 768; Mode = 'Thai compact' }
    [pscustomobject]@{ FileName = 'daily-summary-th-missing-1672x941.png'; Width = 1672; Height = 941; Mode = 'Thai missing-score' }
)
$captureEvidence = foreach ($capture in $captureSpecifications) {
    $capturePath = Join-Path $captureDirectory $capture.FileName
    if (-not (Test-Path -LiteralPath $capturePath -PathType Leaf)) {
        throw "Daily Summary WPF test did not produce required PNG evidence: $capturePath"
    }
    $dimensions = Get-PngDimensions -Path $capturePath
    if ($dimensions.Width -ne $capture.Width -or $dimensions.Height -ne $capture.Height) {
        throw "Daily Summary PNG dimensions drifted for $($capture.FileName): expected $($capture.Width)x$($capture.Height) observed $($dimensions.Width)x$($dimensions.Height)"
    }
    $captureItem = Get-Item -LiteralPath $capturePath
    if ($captureItem.Length -le 0) {
        throw "Daily Summary PNG evidence is empty: $capturePath"
    }
    Assert-FreshEvidence -Path $capturePath -NotBeforeUtc $evidenceStaleAfterUtc -Description 'Daily Summary PNG evidence'
    [pscustomobject]@{
        FileName = $capture.FileName
        Width = $dimensions.Width
        Height = $dimensions.Height
        Mode = $capture.Mode
        Bytes = $captureItem.Length
        Sha256 = Get-FileSha256 -Path $capturePath
        RelativePath = $capturePath.Substring($repositoryRoot.Length).TrimStart('\').Replace('\', '/')
    }
}

$hashLines = @(
    "ReferenceFileSha256: $referenceSha256"
    "ReferenceManifestSha256: $($observedHashes.ReferenceManifest)"
    "ContractFileSha256: $($observedHashes.ContractFile)"
    "FixtureFileSha256: $($observedHashes.FixtureFile)"
)
foreach ($sourceName in $ownedSourcePaths.Keys) {
    $hashLines += "${sourceName}Sha256: $($observedHashes[$sourceName])"
}
$sharedHashLines = foreach ($sourceName in $sharedIntegrationPaths.Keys) {
    "${sourceName}ObservedSha256: $(Get-FileSha256 -Path $sharedIntegrationPaths[$sourceName])"
}
$captureLines = $captureEvidence | ForEach-Object {
    "PNG $($_.FileName) mode=$($_.Mode) dimensions=$($_.Width)x$($_.Height) bytes=$($_.Bytes) sha256=$($_.Sha256) path=$($_.RelativePath)"
}

$report = @(
    'HerdrOps v0.6 Issue #32 Daily Summary Page Gate'
    "SourceCommit: $sourceCommit"
    'Result: PASS'
    'IssueAcceptance: IMPLEMENTATION EVIDENCE ONLY'
    'VersionReleaseGate: PENDING'
    ''
    'StaticEvidence: PASS'
    'StaticChecks: clean committed checkout; tracked owned/shared integration inputs; exact Issue #32-owned hashes; shared Shell/localization markers; fixture shape and expected counts; exact reference bytes and manifest pin'
    ''
    'SyntheticEvidence: PASS'
    ('SyntheticTests: ' + (($syntheticTests | ForEach-Object { "$($_.Name) $($_.Passed)/$($_.Total) PASS" }) -join '; '))
    'SyntheticBoundary: Deterministic fixture, state projection and in-process WPF rendering only; PNG dimensions and hashes are recorded below'
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
    'ObservedSharedIntegrationHashes:'
) + $sharedHashLines + @(
    ''
    'FreshDesignEvidence:'
) + $captureLines + @(
    ''
    'EvidenceBoundary:'
    'This gate proves only committed Static, Synthetic and Contract checks for Issue #32. It does not prove an installed Herdr session, live Agent events, runtime resource usage, independent acceptance, packaging, release readiness or v0.6 completion.'
)
$report | Set-Content -LiteralPath $gateReportPath -Encoding UTF8
$report | Write-Output
Write-Output "GateReport: $gateReportPath"
