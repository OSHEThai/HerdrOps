#requires -Version 5.1

[CmdletBinding()]
param(
    [string]$ManifestPath,
    [string]$EvidenceRoot,
    [string]$ExpectedSourceCommit,
    [string]$ExpectedSourceTree,
    [string]$OutputPath,
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

. (Join-Path $PSScriptRoot 'lib\V07Issue36AcceptancePolicy.ps1')

$repositoryRoot = Get-V07Issue36RepositoryRoot

if ($SelfTest) {
    & (Join-Path $PSScriptRoot 'Test-V07Issue36AcceptanceSelftests.ps1')
    return
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    throw 'ManifestPath is required unless -SelfTest is specified.'
}
if ([string]::IsNullOrWhiteSpace($EvidenceRoot)) {
    $EvidenceRoot = Split-Path -Path ([IO.Path]::GetFullPath($ManifestPath)) -Parent
}

$currentCandidate = Get-V07ReleaseGateCurrentCandidate -RepositoryRoot $repositoryRoot
$validation = Test-V07Issue36AcceptanceManifest -ManifestPath $ManifestPath -EvidenceRoot $EvidenceRoot -RepositoryRoot $repositoryRoot -CurrentCandidate $currentCandidate -ExpectedSourceCommit $ExpectedSourceCommit -ExpectedSourceTree $ExpectedSourceTree
$currentCandidate = Assert-V07ReleaseGateCandidateUnchanged -RepositoryRoot $repositoryRoot -ExpectedCandidate $currentCandidate -Description 'Issue #36 validation'
$report = New-V07Issue36PendingGateReport -Validation $validation

if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $outputFull = [IO.Path]::GetFullPath($OutputPath)
    Assert-V07ReleaseGateNoReparseComponents -Path $outputFull -Root $EvidenceRoot
    $parent = Split-Path -Path $outputFull -Parent
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        throw "Issue #36 output parent does not exist: $parent"
    }
    if (Test-Path -LiteralPath $outputFull) {
        throw "Issue #36 refuses to overwrite an existing report: $outputFull"
    }
    $json = ($report | ConvertTo-Json -Depth 20) + "`n"
    [IO.File]::WriteAllText($outputFull, $json, (New-Object System.Text.UTF8Encoding($false)))
    $null = Assert-V07ReleaseGateCandidateUnchanged -RepositoryRoot $repositoryRoot -ExpectedCandidate $currentCandidate -Description 'Issue #36 report write'
}

$report
