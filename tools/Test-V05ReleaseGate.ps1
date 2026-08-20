[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$CompositeRuntimeReport,

    [Parameter(Mandatory)]
    [string]$RuntimeGateReport,

    [string]$HerdrRuntimeReport,

    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',

    [switch]$SkipBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

function Assert-ValidLeafPath {
    param(
        [string]$Path,
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "The $Name path must not be null or whitespace."
    }
    if ($Path.IndexOfAny([IO.Path]::GetInvalidPathChars()) -ge 0) {
        throw "The $Name path contains invalid path characters: $Path"
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required v0.5 runtime evidence is missing or not a leaf file ($Name): $Path"
    }
    return (Resolve-Path -LiteralPath $Path).Path
}

$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$artifactRoot = Join-Path $repositoryRoot 'artifacts'
$sourceCommit = (& git -C $repositoryRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($sourceCommit)) {
    throw 'Could not resolve the source commit for the v0.5 release gate.'
}
$workingTreeStatus = @(& git -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0) {
    throw 'Could not inspect the source working tree for the v0.5 release gate.'
}
if ($workingTreeStatus.Count -ne 0) {
    throw "The v0.5 release gate requires a clean committed checkout. Pending paths: $($workingTreeStatus -join ', ')"
}

$resolvedCompositePath = Assert-ValidLeafPath -Path $CompositeRuntimeReport -Name 'composite runtime report'
$resolvedRuntimeGatePath = Assert-ValidLeafPath -Path $RuntimeGateReport -Name 'runtime gate report'

$candidateHerdrReport = if ([string]::IsNullOrWhiteSpace($HerdrRuntimeReport)) {
    Join-Path (Split-Path -Parent $resolvedCompositePath) 'herdr-runtime.json'
} else {
    $HerdrRuntimeReport
}
$resolvedHerdrReportPath = Assert-ValidLeafPath -Path $candidateHerdrReport -Name 'Herdr runtime report'

$composite = Get-Content -LiteralPath $resolvedCompositePath -Raw | ConvertFrom-Json -Depth 128
if ($composite.EvidenceClassification -ne 'Runtime' -or
    -not [bool]$composite.RuntimeAccepted -or
    [bool]$composite.SessionControlInvoked -or
    -not [bool]$composite.Acceptance.Passed) {
    throw 'The supplied composite report is not passing role-distinct runtime evidence.'
}

$compositeSha256 = (Get-FileHash -LiteralPath $resolvedCompositePath -Algorithm SHA256).Hash
$herdrRuntimeSha256 = (Get-FileHash -LiteralPath $resolvedHerdrReportPath -Algorithm SHA256).Hash

if ($composite.HerdrRuntimeReportSha256 -ne $herdrRuntimeSha256) {
    throw "Composite runtime report HerdrRuntimeReportSha256 ($($composite.HerdrRuntimeReportSha256)) does not match actual Herdr runtime report hash ($herdrRuntimeSha256)."
}

$runtimeGateText = Get-Content -LiteralPath $resolvedRuntimeGatePath -Raw
foreach ($requiredLine in @(
        'Result: PASS',
        "SourceCommit: $sourceCommit",
        "CompositeRuntimeReportSha256: $compositeSha256",
        "HerdrRuntimeReportSha256: $herdrRuntimeSha256")) {
    if ($runtimeGateText -notmatch "(?m)^$([Regex]::Escape($requiredLine))\s*$") {
        throw "The runtime gate report is not bound to this release source and runtime evidence: $requiredLine"
    }
}

$reviewRecords = 24..28 | ForEach-Object {
    Join-Path $repositoryRoot "docs\reviews\v0.5-issue-$($_)-independent-review.md"
}
foreach ($reviewRecord in $reviewRecords) {
    if (-not (Test-Path -LiteralPath $reviewRecord -PathType Leaf)) {
        throw "Independent v0.5 review record is missing: $reviewRecord"
    }
    $reviewText = Get-Content -LiteralPath $reviewRecord -Raw
    if ($reviewText -notmatch '(?m)^Verdict:\s*PASS\s*$') {
        throw "Independent v0.5 review is not PASS: $reviewRecord"
    }
}

if (-not $SkipBuild) {
    & (Join-Path $PSScriptRoot 'Invoke-Build.ps1') -Configuration $Configuration -VerifyFormat
    if ($LASTEXITCODE -ne 0) {
        throw 'The v0.5 release build and test suite failed.'
    }
}

$implementationGates = @(
    'Test-V05ComplianceRuleEngine.ps1',
    'Test-V05EvidenceAuditStorage.ps1',
    'Test-V05ComplianceQueue.ps1',
    'Test-V05RoleDistinctReview.ps1')
foreach ($implementationGate in $implementationGates) {
    & (Join-Path $PSScriptRoot $implementationGate) `
        -Configuration $Configuration `
        -SkipBuild | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "The v0.5 implementation gate failed: $implementationGate"
    }
}

$finalSourceCommit = (& git -C $repositoryRoot rev-parse HEAD).Trim()
$finalWorkingTreeStatus = @(& git -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or
    $finalSourceCommit -ne $sourceCommit -or
    $finalWorkingTreeStatus.Count -ne 0) {
    throw 'The source commit or clean-checkout state changed while the v0.5 release gate ran.'
}

$runId = "$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ', [Globalization.CultureInfo]::InvariantCulture))-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
$gateDirectory = Join-Path $artifactRoot "release-gates\v0.5.0\release\$runId"
New-Item -ItemType Directory -Path $gateDirectory -Force | Out-Null
$runtimeGateSha256 = (Get-FileHash -LiteralPath $resolvedRuntimeGatePath -Algorithm SHA256).Hash
$reviewHashes = $reviewRecords | ForEach-Object {
    "SHA256 $((Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash) $([IO.Path]::GetFileName($_))"
}
$gateReportPath = Join-Path $gateDirectory 'gate-report.txt'
$gateReport = @(
    'HerdrOps v0.5.0 Release Gate',
    "GeneratedUtc: $([DateTime]::UtcNow.ToString('O'))",
    "SourceCommit: $sourceCommit",
    'Result: PASS',
    'ReleaseReady: true',
    'ImplementationGates: 4/4 PASS',
    'IndependentReviews: 5/5 PASS',
    'RoleDistinctRuntimeAcceptance: PASS',
    'SessionControlInvoked: false',
    "CompositeRuntimeReportSha256: $compositeSha256",
    "HerdrRuntimeReportSha256: $herdrRuntimeSha256",
    "RuntimeGateReportSha256: $runtimeGateSha256",
    "HerdrRuntimeReport: $resolvedHerdrReportPath",
    '',
    'IndependentReviewHashes:'
) + $reviewHashes + @(
    '',
    'EvidenceBoundary:',
    'This gate requires all four v0.5 implementation gates, five explicit independent PASS records, and one exact-source role-distinct composite Herdr runtime report with exact bound Herdr runtime report.',
    'A passing local report is release-gate evidence for the bound source commit. GitHub issue closure, tag creation, package publication, and release publication remain separate actions.'
)
$gateReport | Set-Content -LiteralPath $gateReportPath -Encoding utf8
$gateReport | Write-Output
Write-Output "GateReport: $gateReportPath"
