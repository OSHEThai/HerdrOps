#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PackageRoot,
    [string]$ProfilePath,
    [string]$ArchivePath,
    [string]$HashRecordPath,
    [string]$TestFaultInjectionStage = 'None',
    [switch]$TestInjectCleanupFailure
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Packaging.Common.ps1')

if ([string]::IsNullOrWhiteSpace($ProfilePath)) {
    $ProfilePath = Join-Path $PSScriptRoot 'package-profile.json'
}
$profile = Read-PackageProfile -Path $ProfilePath
Assert-V070PreparationProfile -Profile $profile
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

$record = Publish-PackageArchiveAndHashAtomically `
    -Profile $profile `
    -PackageRoot $safeRoot `
    -ArchivePath $ArchivePath `
    -HashRecordPath $HashRecordPath `
    -TestFaultInjectionStage $TestFaultInjectionStage `
    -TestInjectCleanupFailure:$TestInjectCleanupFailure
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
    CommitMarkerPath = $record.CommitMarkerPath
}
