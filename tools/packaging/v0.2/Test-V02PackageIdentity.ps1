#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$IdentityPath,
    [Parameter(Mandatory = $true)][string]$ArchivePath,
    [Parameter(Mandatory = $true)][string]$PackageRoot,
    [string]$RepositoryRoot,
    [string]$ProfilePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'V02PackageIdentity.Common.ps1')

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
}
if ([string]::IsNullOrWhiteSpace($ProfilePath)) {
    $ProfilePath = Join-Path $PSScriptRoot 'package-identity-profile.json'
}

$profile = Read-V02PackageIdentityProfile -Path $ProfilePath
$receipt = Read-V02CanonicalIdentityReceipt -Path $IdentityPath -RepositoryRoot $RepositoryRoot
Assert-V02PackageIdentity -Identity $receipt.Identity -Profile $profile -ProfilePath $ProfilePath -RepositoryRoot $RepositoryRoot -ArchivePath $ArchivePath -PackageRoot $PackageRoot -ReceiptSha256 $receipt.ReceiptSha256 -CanonicalReceiptJson $receipt.CanonicalJson
