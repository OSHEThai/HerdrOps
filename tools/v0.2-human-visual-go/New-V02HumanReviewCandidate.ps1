#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RendererManifestPath,
    [Parameter(Mandatory = $true)][string]$HumanReviewEvidencePath,
    [Parameter(Mandatory = $true)][string]$EvidenceRoot,
    [Parameter(Mandatory = $true)][string]$RepositoryRoot,
    [Parameter(Mandatory = $true)][string]$BuilderIdentity,
    [Parameter(Mandatory = $true)][string]$RuntimeOperatorIdentity,
    [Parameter(Mandatory = $true)][string]$IndependentValidatorIdentity,
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'HumanVisualGo.Common.ps1')

$candidate = New-V02HumanVisualGoCandidateCore `
    -RendererManifestPath $RendererManifestPath `
    -HumanReviewEvidencePath $HumanReviewEvidencePath `
    -EvidenceRoot $EvidenceRoot `
    -RepositoryRoot $RepositoryRoot `
    -BuilderIdentity $BuilderIdentity `
    -RuntimeOperatorIdentity $RuntimeOperatorIdentity `
    -IndependentValidatorIdentity $IndependentValidatorIdentity

if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    [void](Write-V02HumanVisualGoCandidate -Candidate $candidate -OutputPath $OutputPath -RepositoryRoot $RepositoryRoot -EvidenceRoot $EvidenceRoot)
}

Get-HumanVisualGoCanonicalText -Value $candidate -RepositoryRoot ([IO.Path]::GetFullPath($RepositoryRoot))
