#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PackageRoot,
    [string]$ProfilePath,
    [string]$ArchivePath,
    [string]$HashRecordPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Packaging.Common.ps1')

if ([string]::IsNullOrWhiteSpace($ProfilePath)) {
    $ProfilePath = Join-Path $PSScriptRoot 'package-profile.json'
}
$profile = Read-PackageProfile -Path $ProfilePath
$safeRoot = Assert-SafeDestination -Path $PackageRoot -AllowRepositoryChild -AllowTempChild
if (-not (Test-Path -LiteralPath $safeRoot -PathType Container)) {
    throw "Package root directory was not found: $safeRoot"
}
Assert-PackageManifestMatchesRoot -Profile $profile -PackageRoot $safeRoot | Out-Null

$parent = Split-Path -Path $safeRoot -Parent
if ([string]::IsNullOrWhiteSpace($ArchivePath)) {
    $ArchivePath = Join-Path $parent ("HerdrOps-$($profile.packageVersion)-$($profile.runtimeIdentifier).zip")
}
if ([string]::IsNullOrWhiteSpace($HashRecordPath)) {
    $HashRecordPath = Join-Path $parent 'package-hashes.txt'
}

$safeArchive = New-DeterministicPackageArchive -PackageRoot $safeRoot -ArchivePath $ArchivePath
$record = Write-PackageHashRecord -Profile $profile -PackageRoot $safeRoot -ArchivePath $safeArchive -Path $HashRecordPath
[pscustomobject][ordered]@{
    EvidenceClass = 'Static'
    PackageVersion = [string]$profile.packageVersion
    PackageRoot = $safeRoot
    ArchivePath = $record.ArchivePath
    ArchiveBytes = $record.ArchiveBytes
    ArchiveSha256 = $record.ArchiveSha256
    ManifestPath = $record.ManifestPath
    ManifestBytes = $record.ManifestBytes
    ManifestSha256 = $record.ManifestSha256
    ContentSha256 = $record.ContentSha256
    HashRecordPath = $record.HashRecordPath
}
