#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$CandidatePath,
    [string]$AttestationPath,
    [Parameter(Mandatory = $true)][string]$EvidenceRoot,
    [Parameter(Mandatory = $true)][string]$RepositoryRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'HumanVisualGo.Common.ps1')

Test-V02HumanVisualGoAttestationCore `
    -CandidatePath $CandidatePath `
    -AttestationPath $AttestationPath `
    -EvidenceRoot $EvidenceRoot `
    -RepositoryRoot $RepositoryRoot
