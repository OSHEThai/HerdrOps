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
$parent = Split-Path -Path $safeRoot -Parent
if ([string]::IsNullOrWhiteSpace($ArchivePath)) {
    $ArchivePath = Join-Path $parent ("HerdrOps-$($profile.packageVersion)-$($profile.runtimeIdentifier).zip")
}
if ([string]::IsNullOrWhiteSpace($HashRecordPath)) {
    $HashRecordPath = Join-Path $parent 'package-hashes.txt'
}

$safeArchive = Assert-SafeDestination -Path $ArchivePath -AllowRepositoryChild -AllowTempChild
$safeHashRecord = Assert-SafeDestination -Path $HashRecordPath -AllowRepositoryChild -AllowTempChild
if ((Test-PathWithin -ChildPath $safeArchive -RootPath $safeRoot) -or
    (Test-PathWithin -ChildPath $safeHashRecord -RootPath $safeRoot)) {
    throw 'Package archive and hash record must be outside the package root.'
}
if ($safeArchive.Equals($safeHashRecord, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Package archive and hash record must use different destinations.'
}
if (Test-Path -LiteralPath $safeArchive) {
    throw "Refusing to overwrite an existing package archive: $safeArchive"
}
if (Test-Path -LiteralPath $safeHashRecord) {
    throw "Refusing to overwrite an existing package hash record: $safeHashRecord"
}

Assert-PackageManifestMatchesRoot -Profile $profile -PackageRoot $safeRoot | Out-Null
$safeArchive = New-DeterministicPackageArchive -PackageRoot $safeRoot -ArchivePath $safeArchive
$record = Write-PackageHashRecord -Profile $profile -PackageRoot $safeRoot -ArchivePath $safeArchive -Path $safeHashRecord
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
