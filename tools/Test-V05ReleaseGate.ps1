[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$CompositeRuntimeReport,

    [Parameter(Mandatory)]
    [string]$RuntimeGateReport,

    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',

    [switch]$SkipBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

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

foreach ($path in @($CompositeRuntimeReport, $RuntimeGateReport)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required v0.5 runtime evidence is missing: $path"
    }
}
$resolvedCompositePath = (Resolve-Path -LiteralPath $CompositeRuntimeReport).Path
$resolvedRuntimeGatePath = (Resolve-Path -LiteralPath $RuntimeGateReport).Path
$composite = Get-Content -LiteralPath $resolvedCompositePath -Raw | ConvertFrom-Json -Depth 128
if ($composite.EvidenceClassification -ne 'Runtime' -or
    -not [bool]$composite.RuntimeAccepted -or
    [bool]$composite.SessionControlInvoked -or
    -not [bool]$composite.Acceptance.Passed) {
    throw 'The supplied composite report is not passing role-distinct runtime evidence.'
}
$compositeSha256 = (Get-FileHash -LiteralPath $resolvedCompositePath -Algorithm SHA256).Hash
$runtimeGateText = Get-Content -LiteralPath $resolvedRuntimeGatePath -Raw
foreach ($requiredLine in @(
        'Result: PASS',
        "SourceCommit: $sourceCommit",
        "CompositeRuntimeReportSha256: $compositeSha256")) {
    if ($runtimeGateText -notmatch "(?m)^$([Regex]::Escape($requiredLine))\s*$") {
        throw "The runtime gate report is not bound to this release source and composite report: $requiredLine"
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

Write-Host "v0.5 release gate passed against commit $sourceCommit."
