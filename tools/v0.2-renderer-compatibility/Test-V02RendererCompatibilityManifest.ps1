#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$ManifestPath,
    [Parameter(Mandatory=$true)][string]$EvidenceRoot,
    [Parameter(Mandatory=$true)][string]$RepositoryRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'RendererCompatibility.Common.ps1')

Test-RendererCompatibilityManifest -ManifestPath $ManifestPath -EvidenceRoot $EvidenceRoot -RepositoryRoot $RepositoryRoot -ValidateBindings
