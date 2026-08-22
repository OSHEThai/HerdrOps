#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ThaiRuntimeEvidenceDirectory,
    [Parameter(Mandatory)][string]$EnglishRuntimeEvidenceDirectory,
    [Parameter(Mandatory)][string]$ThaiUiEvidenceDirectory,
    [Parameter(Mandatory)][string]$EnglishUiEvidenceDirectory,
    [Parameter(Mandatory)][string]$MatrixCandidatePath,
    [Parameter(Mandatory)][string]$PackageIdentityPath,
    [Parameter(Mandatory)][string]$PackageArchivePath,
    [Parameter(Mandatory)][string]$ExtractedPackageRoot,
    [Parameter(Mandatory)][string]$RepositoryRoot,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$ExpectedSourceCommit,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$ExpectedSourceTree,
    [Parameter(Mandatory)][string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Issue9LiveUi.Common.ps1')

$result = Invoke-I9LiveUiVerification `
    -ThaiRuntimeEvidenceDirectory $ThaiRuntimeEvidenceDirectory `
    -EnglishRuntimeEvidenceDirectory $EnglishRuntimeEvidenceDirectory `
    -ThaiUiEvidenceDirectory $ThaiUiEvidenceDirectory `
    -EnglishUiEvidenceDirectory $EnglishUiEvidenceDirectory `
    -MatrixCandidatePath $MatrixCandidatePath `
    -PackageIdentityPath $PackageIdentityPath `
    -PackageArchivePath $PackageArchivePath `
    -ExtractedPackageRoot $ExtractedPackageRoot `
    -RepositoryRoot $RepositoryRoot `
    -ExpectedSourceCommit $ExpectedSourceCommit `
    -ExpectedSourceTree $ExpectedSourceTree `
    -OutputPath $OutputPath

Write-Output 'EvidenceClass: RuntimeCandidate'
Write-Output 'Result: PASS'
Write-Output "Candidate: $($result.Path)"
Write-Output "CandidateSha256: $($result.Sha256)"
Write-Output 'Runtime: NOT_OBSERVED'
Write-Output 'HumanVisual: NOT_OBSERVED'
Write-Output 'ReleaseCredit: false'
