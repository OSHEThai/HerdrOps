#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PackageRoot,
    [string]$ProfilePath,
    [AllowEmptyString()][string]$PackageVersion
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Packaging.Common.ps1')

if ([string]::IsNullOrWhiteSpace($ProfilePath)) {
    $ProfilePath = Join-Path $PSScriptRoot 'package-profile.json'
}
$profile = Read-PackageProfile -Path $ProfilePath
$resolvedVersion = Resolve-RequestedPackageVersion -Profile $profile -RequestedVersion $PackageVersion
if ($resolvedVersion -cne [string]$profile.packageVersion) {
    throw 'Manifest generation cannot create a package identity different from the profile.'
}

$safeRoot = Assert-SafeDestination -Path $PackageRoot -AllowRepositoryChild -AllowTempChild
if (-not (Test-Path -LiteralPath $safeRoot -PathType Container)) {
    throw "Package root directory was not found: $safeRoot"
}

$manifest = New-PackageManifestObject -Profile $profile -PackageRoot $safeRoot
$manifestPath = Write-PackageManifest -Manifest $manifest -PackageRoot $safeRoot
$manifestInfo = Get-Item -LiteralPath $manifestPath
[pscustomobject][ordered]@{
    EvidenceClass = 'Static'
    PackageRoot = $safeRoot
    ManifestPath = $manifestInfo.FullName
    ManifestBytes = [int64]$manifestInfo.Length
    ManifestSha256 = ((Get-FileHash -LiteralPath $manifestInfo.FullName -Algorithm SHA256).Hash).ToUpperInvariant()
    ContentSha256 = [string]$manifest.contentSha256
    FileCount = [int]$manifest.fileCount
    PackageVersion = [string]$manifest.packageVersion
}
