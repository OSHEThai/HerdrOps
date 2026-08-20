#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$OutputRoot,
    [string]$ProfilePath,
    [AllowEmptyString()][string]$PackageVersion,
    [string]$TestFaultInjectionStage = 'None',
    [string]$TestDotnetCommandPath,
    [switch]$TestInjectPrimaryFailure,
    [switch]$TestInjectCleanupFailure
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Packaging.Common.ps1')

if ([string]::IsNullOrWhiteSpace($ProfilePath)) {
    $ProfilePath = Join-Path $PSScriptRoot 'package-profile.json'
}
$profile = Read-PackageProfile -Path $ProfilePath
$null = Assert-V070PreparationProfile -Profile $profile
$resolvedVersion = Resolve-RequestedPackageVersion -Profile $profile -RequestedVersion $PackageVersion
$repositoryRoot = Get-PackagingRepositoryRoot
$null = Assert-ProjectMatchesPackageProfile -Profile $profile -RepositoryRoot $repositoryRoot

$safeOutputRoot = Assert-SafeDestination -Path $OutputRoot -AllowRepositoryChild -AllowTempChild
if (Test-Path -LiteralPath $safeOutputRoot) {
    $existingItem = Get-Item -LiteralPath $safeOutputRoot -Force
    if (($existingItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Output root must not be a reparse point: $safeOutputRoot"
    }
    if (@(Get-ChildItem -LiteralPath $safeOutputRoot -Force).Count -ne 0) {
        throw "Output root must be missing or empty; refusing to overwrite: $safeOutputRoot"
    }
}

$publishWorkRoot = New-PackagingTempDirectory -Prefix 'HerdrOps-Publish-'
$operationOutput = Invoke-PackagingOperationWithCleanup -Operation {
    if ($TestInjectPrimaryFailure) {
        throw 'Injected packaging primary operation failure.'
    }

    $publishRoot = Join-Path $publishWorkRoot 'publish'
    $restoreRoot = Join-Path $publishWorkRoot 'restore'
    $isolatedLockPath = Join-Path $restoreRoot 'packages.lock.json'
    New-Item -ItemType Directory -Path $publishRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $restoreRoot -Force | Out-Null

    $lockPaths = @(
        (Join-Path $repositoryRoot 'src\HerdrOps.App\packages.lock.json'),
        (Join-Path $repositoryRoot 'src\HerdrOps.Contracts\packages.lock.json'),
        (Join-Path $repositoryRoot 'src\HerdrOps.Domain\packages.lock.json'))
    $lockHashesBefore = @{}
    foreach ($lockPath in $lockPaths) {
        if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) {
            throw "Required source package lock file is missing: $lockPath"
        }
        $lockHashesBefore[$lockPath] = ((Get-FileHash -LiteralPath $lockPath -Algorithm SHA256).Hash).ToUpperInvariant()
    }

    $projectPath = Join-Path $repositoryRoot ([string]$profile.sourceProject)
    $publishArguments = @(
        'publish',
        $projectPath,
        '--configuration', [string]$profile.configuration,
        '--runtime', [string]$profile.runtimeIdentifier,
        '--self-contained', 'true',
        '--output', $publishRoot,
        '--nologo',
        ('-p:VersionPrefix=' + $resolvedVersion),
        '-p:VersionSuffix=',
        ('-p:Version=' + $resolvedVersion),
        ('-p:AssemblyVersion=' + $resolvedVersion + '.0'),
        ('-p:FileVersion=' + $resolvedVersion + '.0'),
        ('-p:InformationalVersion=' + $resolvedVersion),
        '-p:ContinuousIntegrationBuild=true',
        '-p:Deterministic=true',
        '-p:DebugType=None',
        '-p:RestorePackagesWithLockFile=false',
        ('-p:NuGetLockFilePath=' + $isolatedLockPath))

    $dotnetCommand = 'dotnet'
    if (-not [string]::IsNullOrWhiteSpace($TestDotnetCommandPath)) {
        $dotnetCommand = Get-FullPath -Path $TestDotnetCommandPath
        if (-not (Test-Path -LiteralPath $dotnetCommand -PathType Leaf)) {
            throw "Test dotnet command was not found: $dotnetCommand"
        }
    }
    $publishOutput = @(& $dotnetCommand @publishArguments 2>&1)
    $publishExitCode = $LASTEXITCODE
    $publishOutput | ForEach-Object { Write-Verbose ([string]$_) }
    $lockDrift = @()
    foreach ($lockPath in $lockPaths) {
        $lockHashAfter = ((Get-FileHash -LiteralPath $lockPath -Algorithm SHA256).Hash).ToUpperInvariant()
        if ($lockHashAfter -cne [string]$lockHashesBefore[$lockPath]) {
            $lockDrift += $lockPath
        }
    }
    if ($lockDrift.Count -gt 0) {
        throw "dotnet publish changed source package lock files; refusing to continue: $($lockDrift -join ', ')"
    }
    if ($publishExitCode -ne 0) {
        $publishDetails = ($publishOutput | Select-Object -Last 20) -join "`n"
        throw "dotnet publish failed with exit code $publishExitCode.`n$publishDetails"
    }

    Assert-PublishedVersionIdentity -Profile $profile -PublishRoot $publishRoot
    foreach ($item in @(Get-ChildItem -LiteralPath $publishRoot -Recurse -Force)) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Published package contains a reparse point: $($item.FullName)"
        }
    }

    $packageRoot = Join-Path $publishWorkRoot 'package'
    New-Item -ItemType Directory -Path $packageRoot -Force | Out-Null
    Copy-SafeDirectoryContents -Source $publishRoot -Destination $packageRoot
    $manifest = New-PackageManifestObject -Profile $profile -PackageRoot $packageRoot
    Write-PackageManifest -Manifest $manifest -PackageRoot $packageRoot | Out-Null
    $archivePath = Join-Path $publishWorkRoot ("HerdrOps-$($profile.packageVersion)-$($profile.runtimeIdentifier).zip")
    $hashRecordPath = Join-Path $publishWorkRoot 'package-hashes.txt'
    $archive = New-DeterministicPackageArchive -PackageRoot $packageRoot -ArchivePath $archivePath
    $record = Write-PackageHashRecord -Profile $profile -PackageRoot $packageRoot -ArchivePath $archive -Path $hashRecordPath

    $publication = Publish-PackageArtifactsAtomically `
        -Profile $profile `
        -PackageRoot $packageRoot `
        -ArchivePath $archive `
        -HashRecordPath $hashRecordPath `
        -OutputRoot $safeOutputRoot `
        -FaultInjectionStage $TestFaultInjectionStage

    [pscustomobject][ordered]@{
        EvidenceClass = 'Static'
        Issue = [int]$profile.issue
        PackageVersion = [string]$profile.packageVersion
        RuntimeIdentifier = [string]$profile.runtimeIdentifier
        GenerationRoot = $publication.GenerationRoot
        PackageRoot = $publication.PackageRoot
        ArchivePath = $publication.ArchivePath
        ArchiveBytes = $record.ArchiveBytes
        ArchiveSha256 = $record.ArchiveSha256
        ManifestPath = (Get-FullPath -Path (Join-Path $publication.PackageRoot 'package-manifest.json'))
        ManifestSha256 = $record.ManifestSha256
        ContentSha256 = $record.ContentSha256
        HashRecordPath = $publication.HashRecordPath
        PublishMode = [string]$profile.publishMode
        AdministratorRequired = [bool]$profile.administratorRequired
        RuntimeUse = [string]$profile.runtimeUse
    }
} -Cleanup {
    if ($TestInjectCleanupFailure) {
        if (Test-Path -LiteralPath $publishWorkRoot) {
            Remove-PackagingTempDirectory -Path $publishWorkRoot
        }
        throw 'Injected packaging cleanup failure.'
    }
    if (Test-Path -LiteralPath $publishWorkRoot) {
        Remove-PackagingTempDirectory -Path $publishWorkRoot
    }
}
$operationOutput
