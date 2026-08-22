[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$EvidenceRoot,
    [Parameter(Mandatory = $true)][string]$ThaiWidgetReportPath,
    [Parameter(Mandatory = $true)][string]$EnglishWidgetReportPath,
    [Parameter(Mandatory = $true)][string]$ThaiRuntimeGatePath,
    [Parameter(Mandatory = $true)][string]$EnglishRuntimeGatePath,
    [Parameter(Mandatory = $true)][string]$PerformanceReceiptPath,
    [Parameter(Mandatory = $true)][string]$SoakReceiptPath,
    [Parameter(Mandatory = $true)][string]$PackageIdentityPath,
    [Parameter(Mandatory = $true)][string]$PackageArchivePath,
    [Parameter(Mandatory = $true)][string]$ExtractedPackageRoot,
    [Parameter(Mandatory = $true)][string]$PackageProfilePath,
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{40}$')][string]$ExpectedSourceCommit,
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{40}$')][string]$ExpectedSourceTree,
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{32}$')][string]$RunNonce,
    [Parameter(Mandatory = $true)][DateTimeOffset]$EvidenceStartedUtc,
    [Parameter(Mandatory = $true)][string]$RepositoryRoot,
    [Parameter(Mandatory = $true)][string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'V02Issue10Acceptance.Common.ps1')

$repositoryRootFull = [IO.Path]::GetFullPath($RepositoryRoot)
$commit = @(& git -C $repositoryRootFull rev-parse HEAD 2>&1)
if ($LASTEXITCODE -ne 0 -or $commit.Count -ne 1 -or [string]$commit[0] -cne $ExpectedSourceCommit) { throw 'Issue #10 verifier must run from the exact expected source commit.' }
$tree = @(& git -C $repositoryRootFull rev-parse 'HEAD^{tree}' 2>&1)
if ($LASTEXITCODE -ne 0 -or $tree.Count -ne 1 -or [string]$tree[0] -cne $ExpectedSourceTree) { throw 'Issue #10 verifier must run from the exact expected source tree.' }
$status = @(& git -C $repositoryRootFull status --porcelain=v1 --untracked-files=all 2>&1)
if ($LASTEXITCODE -ne 0 -or $status.Count -ne 0) { throw 'Issue #10 verifier requires a clean source checkout.' }

$bindingPath = Join-Path $repositoryRootFull 'tools\lib\V02RuntimePackageBinding.ps1'
if (-not (Test-Path -LiteralPath $bindingPath -PathType Leaf)) { throw "Committed v0.2 runtime package binding helper is missing: $bindingPath" }
. $bindingPath

$packageBinding = Resolve-V02RuntimePackageBinding `
    -IdentityPath $PackageIdentityPath `
    -ArchivePath $PackageArchivePath `
    -PackageRoot $ExtractedPackageRoot `
    -RepositoryRoot $repositoryRootFull `
    -ProfilePath $PackageProfilePath `
    -ExpectedSourceCommit $ExpectedSourceCommit `
    -ExpectedSourceTree $ExpectedSourceTree

$result = Invoke-I10Issue10Acceptance `
    -EvidenceRoot $EvidenceRoot `
    -ThaiWidgetReportPath $ThaiWidgetReportPath `
    -EnglishWidgetReportPath $EnglishWidgetReportPath `
    -ThaiRuntimeGatePath $ThaiRuntimeGatePath `
    -EnglishRuntimeGatePath $EnglishRuntimeGatePath `
    -PerformanceReceiptPath $PerformanceReceiptPath `
    -SoakReceiptPath $SoakReceiptPath `
    -ExpectedSourceCommit $ExpectedSourceCommit `
    -ExpectedSourceTree $ExpectedSourceTree `
    -RunNonce $RunNonce `
    -EvidenceStartedUtc $EvidenceStartedUtc `
    -PackageBinding $packageBinding `
    -OutputPath $OutputPath

if ([string]$result.Candidate.EvidenceClassification -cne 'Issue10RuntimeCandidate' -or
    [string]$result.Candidate.EvidenceBoundary.Runtime -cne 'NOT_OBSERVED' -or
    [string]$result.Candidate.EvidenceBoundary.Human -cne 'NOT_OBSERVED' -or
    [string]$result.Candidate.EvidenceBoundary.Release -cne 'NOT_OBSERVED' -or
    [bool]$result.Candidate.EvidenceBoundary.CreditGranted) {
    throw 'Issue #10 verifier attempted to grant Runtime, Human, Release, or credit.'
}

$result | ConvertTo-Json -Depth 20 -Compress | Write-Output
