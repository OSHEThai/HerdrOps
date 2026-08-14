[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',

    [switch]$SkipBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$artifactRoot = Join-Path $repositoryRoot 'artifacts'
$testResultRoot = Join-Path $artifactRoot 'test-results'

if (-not $SkipBuild) {
    & (Join-Path $PSScriptRoot 'Invoke-Build.ps1') -Configuration $Configuration -VerifyFormat
    if ($LASTEXITCODE -ne 0) {
        throw "v0.2 language-mode gate failed with exit code $LASTEXITCODE."
    }
}

$testResults = @(Get-ChildItem -LiteralPath $testResultRoot -Filter '*.trx' -File |
    Sort-Object LastWriteTimeUtc -Descending |
    Select-Object -First 4)
if ($testResults.Count -lt 4) {
    throw "Expected TRX output from four test projects, found $($testResults.Count)."
}

$combinedTestLog = ($testResults | ForEach-Object {
    Get-Content -LiteralPath $_.FullName -Raw
}) -join "`n"
$requiredChecks = @(
    'ThaiIsTheDefaultAndBothCatalogsContainTheSameNonEmptyKeys',
    'EveryV01XamlLanguageBindingExistsAndNoBilingualLiteralRemains',
    'SyntheticOverviewAndWidgetCopyRebuildsAsOneSelectedLanguage',
    'LiveDashboardCopyRebuildsFromThaiToEnglishWithoutRetainingThaiText',
    'ShellOverviewAndWidgetsRenderOneSelectedLanguageAtATime',
    'LivePagesRenderThaiAndEnglishAsSeparateModes',
    'AllLiveWidgetVariantsRenderThaiAndEnglishAsSeparateModes'
)
foreach ($check in $requiredChecks) {
    if ($combinedTestLog -notmatch [Regex]::Escape($check)) {
        throw "Required v0.2 language-mode check is absent from the test log: $check"
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

$captureDirectory = Join-Path $artifactRoot 'design-evidence\v0.2.0\issue-63\contract-backed-wpf'
$pageNames = @('overview', 'live-organization', 'agent-detail')
$widgetNames = @(
    'compact',
    'normal',
    'expanded',
    'floatingmini',
    'floatingvertical',
    'notification',
    'agentdetailpopup'
)
$requiredCaptures = @(
    foreach ($language in @('thai', 'english')) {
        foreach ($page in $pageNames) {
            "$language-$page.png"
        }
        foreach ($widget in $widgetNames) {
            "$language-widget-$widget.png"
        }
    }
)
$captureEvidence = foreach ($captureName in $requiredCaptures) {
    $capturePath = Join-Path $captureDirectory $captureName
    if (-not (Test-Path -LiteralPath $capturePath -PathType Leaf)) {
        throw "Required language-mode WPF capture is missing: $capturePath"
    }
    if ((Get-Item -LiteralPath $capturePath).Length -le 4000) {
        throw "Language-mode WPF capture is unexpectedly small: $capturePath"
    }

    [pscustomobject]@{
        Name = $captureName
        Sha256 = (Get-FileHash -LiteralPath $capturePath -Algorithm SHA256).Hash
    }
}

$gateDirectory = Join-Path $artifactRoot 'release-gates\v0.2.0\issue-63'
New-Item -ItemType Directory -Path $gateDirectory -Force | Out-Null
$reportPath = Join-Path $gateDirectory 'gate-report.txt'
$commit = (& git -C $repositoryRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($commit)) {
    throw 'Could not resolve the source commit for the v0.2 language-mode gate.'
}

$report = @(
    'HerdrOps v0.2 Issue #63 Thai and English Language-Mode Gate',
    "GeneratedUtc: $([DateTime]::UtcNow.ToString('O'))",
    "Commit: $commit",
    'Result: PASS',
    'IssueAcceptance: PASS',
    'VersionReleaseGate: PENDING',
    'EvidenceClass: Contract-backed Integration plus Synthetic WPF Rendering',
    'ActualHerdrRuntime: NOT OBSERVED / NOT CLAIMED',
    "Tests: $passedTests/$totalTests PASS",
    'DefaultLanguage: Thai',
    'ModePolicy: exactly one selected UI language; technical identifiers, product names and source data remain literal',
    'DynamicStatePolicy: live copy is regenerated from raw state after every language change',
    'BilingualFieldPolicy: ThaiTitle and EnglishTitle presentation fields are prohibited',
    "ContractBackedWpfCaptures: $($requiredCaptures.Count)",
    '',
    'RequiredChecks:'
) + ($requiredChecks | ForEach-Object { "PASS $_" }) + @(
    '',
    'CaptureHashes:'
) + ($captureEvidence | ForEach-Object { "SHA256 $($_.Sha256) $($_.Name)" }) + @(
    '',
    'EvidenceBoundary:',
    'This gate proves the implemented shell, Overview, Live Organization, Agent Detail and all seven live Widget variants render one selected language at a time from a contract-backed state fixture.',
    'English-mode visible-tree checks reject retained Thai UI copy. Catalog parity and XAML checks reject missing keys, hard-coded localized copy and paired ThaiTitle/EnglishTitle fields.',
    'Agent names, workspace labels, product names, identifiers and paths are source data and remain literal rather than being silently translated.',
    'These captures are deterministic WPF evidence from a contract fixture. They are not actual Herdr runtime evidence and do not satisfy the v0.2 release runtime gate.'
)
$report | Set-Content -LiteralPath $reportPath -Encoding utf8
$report | Write-Output
Write-Output "GateReport: $reportPath"
