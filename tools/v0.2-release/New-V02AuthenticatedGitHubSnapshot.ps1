#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidateSet('Preclosure','FinalClosure')][string]$Phase,
    [Parameter(Mandatory=$true)][string]$ExpectedSourceCommit,
    [Parameter(Mandatory=$true)][string]$ExpectedSourceTree,
    [Parameter(Mandatory=$true)][string]$EvidenceRoot,
    [Parameter(Mandatory=$true)][string]$OutputPath,
    [string]$PreclosureSnapshotPath,
    [string]$GitHubTokenEnvironmentVariable='GH_TOKEN'
)
Set-StrictMode -Version Latest;$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\lib\V02ReleaseArtifactProduction.ps1')
$null=Assert-V02ReleaseArtifactSafeOutput -Path $OutputPath -AllowedRoot $EvidenceRoot
$preclosureSha=''
$preclosureLease=$null
try {
if($Phase-ceq'FinalClosure'){
    if([string]::IsNullOrWhiteSpace($PreclosureSnapshotPath)){throw 'FinalClosure requires PreclosureSnapshotPath.'}
    Assert-V02ReleaseArtifactExistingFileWithinRoot -Path $PreclosureSnapshotPath -Root $EvidenceRoot -Context 'Preclosure snapshot'|Out-Null
    $preclosureLease=Open-V02ReleaseArtifactFileLease $PreclosureSnapshotPath 'Preclosure snapshot';$preclosureSha=$preclosureLease.Sha256
}
$live=Get-V02ReleaseArtifactGitHubState -SourceCommit $ExpectedSourceCommit -TokenEnvironmentVariable $GitHubTokenEnvironmentVariable
$value=New-V02ReleaseArtifactGitHubSnapshotValue -Phase $Phase -SourceCommit $ExpectedSourceCommit -SourceTree $ExpectedSourceTree -LiveState $live -PreclosureSnapshotSha256 $preclosureSha
Assert-V02ReleaseArtifactGitHubPhaseState -Snapshot $value -Phase $Phase
Publish-V02ReleaseArtifactJsonNoClobber -Value $value -OutputPath $OutputPath -AllowedRoot $EvidenceRoot
} finally {Close-V02ReleaseArtifactLease $preclosureLease}
