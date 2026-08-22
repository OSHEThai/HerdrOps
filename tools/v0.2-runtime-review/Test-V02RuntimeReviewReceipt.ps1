#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ThaiEvidenceDirectory,
    [Parameter(Mandatory = $true)][string]$EnglishEvidenceDirectory,
    [Parameter(Mandatory = $true)][string]$MatrixCandidatePath,
    [Parameter(Mandatory = $true)][string]$PackageIdentityPath,
    [Parameter(Mandatory = $true)][string]$PackageArchivePath,
    [Parameter(Mandatory = $true)][string]$ExtractedPackageRoot,
    [Parameter(Mandatory = $true)][string]$RepositoryRoot,
    [Parameter(Mandatory = $true)][string]$ExpectedSourceCommit,
    [Parameter(Mandatory = $true)][string]$ExpectedSourceTree,
    [Parameter(Mandatory = $true)][string]$OutputPath,
    [Parameter(Mandatory = $true)][string]$BuilderIdentity,
    [Parameter(Mandatory = $true)][string]$RuntimeOperatorIdentity,
    [Parameter(Mandatory = $true)][string]$MatrixProducerIdentity,
    [Parameter(Mandatory = $true)][string]$RuntimeReviewerIdentity
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'RuntimeReview.Common.ps1')

function Get-V02RuntimeReviewGitValue {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Expression, [Parameter(Mandatory)][string]$Context)
    $value = @(& git -C ([IO.Path]::GetFullPath($Root)) $Expression 2>&1)
    $exitCode = $LASTEXITCODE
    $global:LASTEXITCODE = 0
    if ($exitCode -ne 0 -or $value.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$value[0])) { throw "Unable to resolve $Context." }
    return [string]$value[0]
}

function Assert-V02RuntimeReviewCleanSource {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$ExpectedCommit, [Parameter(Mandatory)][string]$ExpectedTree)
    $fullRoot = [IO.Path]::GetFullPath($Root)
    if (-not (Test-Path -LiteralPath (Join-Path $fullRoot '.git'))) { throw 'RepositoryRoot is not a Git worktree.' }
    $commit = Get-V02RuntimeReviewGitValue $fullRoot 'rev-parse HEAD' 'source commit'
    $tree = Get-V02RuntimeReviewGitValue $fullRoot 'rev-parse HEAD^{tree}' 'source tree'
    if ($commit -cne $ExpectedCommit -or $tree -cne $ExpectedTree) { throw "Source checkout does not match ExpectedSourceCommit/ExpectedSourceTree: $commit/$tree" }
    $status = @(& git -C $fullRoot status --porcelain=v1 --untracked-files=all 2>&1)
    $exitCode = $LASTEXITCODE
    $global:LASTEXITCODE = 0
    if ($exitCode -ne 0) { throw 'Unable to determine source checkout cleanliness.' }
    if ($status.Count -ne 0) { throw 'Production runtime-review verification requires a clean source checkout.' }
}

Assert-V02RuntimeReviewGitSha $ExpectedSourceCommit 'ExpectedSourceCommit' | Out-Null
Assert-V02RuntimeReviewGitSha $ExpectedSourceTree 'ExpectedSourceTree' | Out-Null
Assert-V02RuntimeReviewCleanSource $RepositoryRoot $ExpectedSourceCommit $ExpectedSourceTree

$result = Invoke-V02RuntimeReviewVerification `
    -ThaiEvidenceDirectory $ThaiEvidenceDirectory `
    -EnglishEvidenceDirectory $EnglishEvidenceDirectory `
    -MatrixCandidatePath $MatrixCandidatePath `
    -PackageIdentityPath $PackageIdentityPath `
    -PackageArchivePath $PackageArchivePath `
    -ExtractedPackageRoot $ExtractedPackageRoot `
    -RepositoryRoot $RepositoryRoot `
    -ExpectedSourceCommit $ExpectedSourceCommit `
    -ExpectedSourceTree $ExpectedSourceTree `
    -OutputPath $OutputPath `
    -BuilderIdentity $BuilderIdentity `
    -RuntimeOperatorIdentity $RuntimeOperatorIdentity `
    -MatrixProducerIdentity $MatrixProducerIdentity `
    -RuntimeReviewerIdentity $RuntimeReviewerIdentity

Write-Output 'EvidenceClass: IndependentReviewCandidate'
Write-Output "Result: $($result.Result)"
Write-Output "Candidate: $($result.Path)"
Write-Output "CandidateSha256: $($result.Sha256)"
Write-Output 'IndependentReview: NOT_OBSERVED'
Write-Output 'HumanVisualGo: NOT_OBSERVED'
Write-Output 'RuntimeCredit: false'
Write-Output 'ReleaseCredit: false'
