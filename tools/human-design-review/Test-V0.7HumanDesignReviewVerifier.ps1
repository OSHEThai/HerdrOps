#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ManifestPath,
    [string]$EvidenceRoot,
    [switch]$ValidateBindings
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'HumanDesignReview.Common.ps1')

$result = Test-HumanDesignReviewManifest -ManifestPath $ManifestPath -EvidenceRoot $EvidenceRoot -ValidateBindings:$ValidateBindings
$result