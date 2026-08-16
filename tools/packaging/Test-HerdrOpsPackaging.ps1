#requires -Version 5.1

[CmdletBinding()]
param(
    [string]$ProfilePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Packaging.Common.ps1')

if ([string]::IsNullOrWhiteSpace($ProfilePath)) {
    $ProfilePath = Join-Path $PSScriptRoot 'package-profile.json'
}

function Assert-ExpectedFailure {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $failed = $false
    try {
        & $Action
    } catch {
        $failed = $true
    }
    if (-not $failed) {
        throw "Fail-closed check unexpectedly succeeded: $Description"
    }
}

$profile = Read-PackageProfile -Path $ProfilePath
$repositoryRoot = Get-PackagingRepositoryRoot
Assert-ProjectMatchesPackageProfile -Profile $profile -RepositoryRoot $repositoryRoot

$implementationFiles = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -File |
    Where-Object { $_.Name -ne 'Test-HerdrOpsPackaging.ps1' })
$toolText = ($implementationFiles | Get-Content -Raw) -join "`n"
foreach ($forbiddenMarker in @(
        'New-ItemProperty',
        'Set-ItemProperty',
        'Remove-ItemProperty',
        'Registry::',
        'reg.exe',
        'Start-Process',
        'HERDR_SOCKET_PATH',
        'herdr.exe')) {
    if ($toolText.IndexOf($forbiddenMarker, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
        throw "Packaging preparation tool contains a forbidden runtime or registry marker: $forbiddenMarker"
    }
}
if ($toolText.IndexOf('RestorePackagesWithLockFile=false', [StringComparison]::Ordinal) -lt 0 -or
    $toolText.IndexOf('NuGetLockFilePath=', [StringComparison]::Ordinal) -lt 0) {
    throw 'Publish tooling is missing its isolated restore-lock safety boundary.'
}

$realLocalAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
Assert-ExpectedFailure -Description 'real LocalAppData destination guard' -Action {
    Assert-SafeDestination -Path (Join-Path $realLocalAppData 'Programs\HerdrOps') -AllowRepositoryChild -AllowTempChild | Out-Null
}

$testRoot = New-PackagingTempDirectory -Prefix 'HerdrOps-Test-'
try {
    $packageOne = Join-Path $testRoot 'package-one'
    $packageTwo = Join-Path $testRoot 'package-two'
    $fixture = Join-Path $repositoryRoot 'tests\fixtures\v0.7\packaging\initial'
    Copy-SafeDirectoryContents -Source $fixture -Destination $packageOne
    Copy-SafeDirectoryContents -Source $fixture -Destination $packageTwo

    $manifestOne = New-PackageManifestObject -Profile $profile -PackageRoot $packageOne
    $manifestTwo = New-PackageManifestObject -Profile $profile -PackageRoot $packageTwo
    Write-PackageManifest -Manifest $manifestOne -PackageRoot $packageOne | Out-Null
    Write-PackageManifest -Manifest $manifestTwo -PackageRoot $packageTwo | Out-Null
    Assert-PackageManifestMatchesRoot -Profile $profile -PackageRoot $packageOne | Out-Null
    Assert-PackageManifestMatchesRoot -Profile $profile -PackageRoot $packageTwo | Out-Null

    $manifestOnePath = Join-Path $packageOne 'package-manifest.json'
    $manifestTwoPath = Join-Path $packageTwo 'package-manifest.json'
    $manifestOneBytes = [IO.File]::ReadAllBytes($manifestOnePath)
    $manifestTwoBytes = [IO.File]::ReadAllBytes($manifestTwoPath)
    if (-not ([System.Linq.Enumerable]::SequenceEqual($manifestOneBytes, $manifestTwoBytes))) {
        throw 'Repeated manifest generation was not byte-identical.'
    }

    $archiveOne = Join-Path $testRoot 'one.zip'
    $archiveTwo = Join-Path $testRoot 'two.zip'
    New-DeterministicPackageArchive -PackageRoot $packageOne -ArchivePath $archiveOne | Out-Null
    New-DeterministicPackageArchive -PackageRoot $packageTwo -ArchivePath $archiveTwo | Out-Null
    $archiveHashOne = ((Get-FileHash -LiteralPath $archiveOne -Algorithm SHA256).Hash).ToUpperInvariant()
    $archiveHashTwo = ((Get-FileHash -LiteralPath $archiveTwo -Algorithm SHA256).Hash).ToUpperInvariant()
    if ($archiveHashOne -cne $archiveHashTwo) {
        throw "Repeated deterministic archive generation drifted: $archiveHashOne vs $archiveHashTwo"
    }

    Write-DeterministicTextFile -Path (Join-Path $packageOne 'tampered.txt') -Text 'tamper'
    Assert-ExpectedFailure -Description 'tampered package manifest guard' -Action {
        Assert-PackageManifestMatchesRoot -Profile $profile -PackageRoot $packageOne | Out-Null
    }
    Assert-ExpectedFailure -Description 'profile version mismatch guard' -Action {
        Resolve-RequestedPackageVersion -Profile $profile -RequestedVersion '0.7.1' | Out-Null
    }
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-PackagingTempDirectory -Path $testRoot
    }
}

$lifecycle = @(& (Join-Path $PSScriptRoot 'Invoke-SyntheticPackagingLifecycle.ps1') -ProfilePath $ProfilePath)
if ($lifecycle.Count -ne 1 -or [string]$lifecycle[0].EvidenceClass -cne 'Synthetic') {
    throw 'Synthetic packaging lifecycle harness did not return one successful Synthetic report.'
}
foreach ($boundary in @('CleanMachine', 'Runtime', 'Human', 'Release')) {
    if ([string]$lifecycle[0].$boundary -cne 'NOT OBSERVED') {
        throw "Synthetic lifecycle boundary '$boundary' was not explicitly NOT OBSERVED."
    }
}

[pscustomobject][ordered]@{
    EvidenceClass = 'Static/Synthetic'
    Issue = [int]$profile.issue
    Profile = 'PASS'
    ProjectIdentity = 'PASS'
    ProtectedPathGuards = 'PASS'
    DeterministicManifestBytes = 'PASS'
    DeterministicArchiveBytes = 'PASS'
    TamperAndVersionFailClosed = 'PASS'
    SyntheticLifecycle = 'PASS'
    CleanMachine = 'NOT OBSERVED'
    Runtime = 'NOT OBSERVED'
    Human = 'NOT OBSERVED'
    Release = 'NOT OBSERVED'
}
