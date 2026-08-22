#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$OutputRoot,
    [string]$ProfilePath,
    [string]$RepositoryRoot,
    [AllowEmptyString()][string]$PackageVersion = '0.2.0',
    [string]$TestFaultInjectionStage = 'None',
    [string]$TestDotnetCommandPath,
    [switch]$TestInjectPrimaryFailure,
    [switch]$TestInjectCleanupFailure
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'V02Packaging.Common.ps1')

if ([string]::IsNullOrWhiteSpace($ProfilePath)) {
    $ProfilePath = Join-Path $PSScriptRoot 'package-identity-profile.json'
}
$profile = Read-V02PackageIdentityProfile -Path $ProfilePath

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
}
$repositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)
Assert-V02PathNoReparse -Path $repositoryRoot

if (-not [string]::IsNullOrWhiteSpace($PackageVersion) -and $PackageVersion -cne '0.2.0') {
    throw "v0.2 packaging wrapper is pinned to version 0.2.0: $PackageVersion"
}

$safeOutputRoot = Assert-SafeDestination -Path $OutputRoot -AllowRepositoryChild -AllowTempChild
Assert-V02PackagingPathsDoNotOverlap -Paths @(
    [pscustomobject]@{ Name = 'repository root'; Path = $repositoryRoot },
    [pscustomobject]@{ Name = 'output root'; Path = $safeOutputRoot }
)

if (Test-Path -LiteralPath $safeOutputRoot) {
    $existingItem = Get-Item -LiteralPath $safeOutputRoot -Force
    if (($existingItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Output root must not be a reparse point: $safeOutputRoot"
    }
    if (@(Get-ChildItem -LiteralPath $safeOutputRoot -Force).Count -ne 0) {
        throw "Output root must be missing or empty; refusing to overwrite: $safeOutputRoot"
    }
}

$publishWorkRoot = New-PackagingTempDirectory -Prefix 'HerdrOps-V02Publish-'
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
        (Join-Path $repositoryRoot 'src\HerdrOps.Domain\packages.lock.json')
    )
    $lockHashesBefore = @{}
    foreach ($lockPath in $lockPaths) {
        if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) {
            throw "Required source package lock file is missing: $lockPath"
        }
        $lockHashesBefore[$lockPath] = ((Get-FileHash -LiteralPath $lockPath -Algorithm SHA256).Hash).ToUpperInvariant()
    }

    $appProjectPath = Join-Path $repositoryRoot 'src\HerdrOps.App\HerdrOps.App.csproj'
    if (-not (Test-Path -LiteralPath $appProjectPath -PathType Leaf)) {
        throw "App source project was not found: $appProjectPath"
    }

    $publishArguments = @(
        'publish',
        $appProjectPath,
        '--configuration', 'Release',
        '--runtime', [string]$profile.runtimeIdentifier,
        '--self-contained', 'true',
        '--output', $publishRoot,
        '--nologo',
        '-p:VersionPrefix=0.2.0',
        '-p:VersionSuffix=',
        '-p:Version=0.2.0',
        '-p:AssemblyVersion=0.2.0.0',
        '-p:FileVersion=0.2.0.0',
        '-p:InformationalVersion=0.2.0',
        '-p:ContinuousIntegrationBuild=true',
        '-p:Deterministic=true',
        '-p:DebugType=None',
        '-p:RestorePackagesWithLockFile=false',
        ('-p:NuGetLockFilePath=' + $isolatedLockPath)
    )

    $dotnetCommand = 'dotnet'
    if (-not [string]::IsNullOrWhiteSpace($TestDotnetCommandPath)) {
        $dotnetCommand = [IO.Path]::GetFullPath($TestDotnetCommandPath)
        if (-not (Test-Path -LiteralPath $dotnetCommand -PathType Leaf)) {
            throw "Test dotnet command was not found: $dotnetCommand"
        }
    }

    $publishOutput = @(& $dotnetCommand @publishArguments 2>&1)
    $publishExitCode = $LASTEXITCODE
    $global:LASTEXITCODE = 0

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

    Assert-V02TreeNoReparse -Path $publishRoot

    $appExe = Join-Path $publishRoot ([string]$profile.components.appRelativePath)
    $coreExe = Join-Path $publishRoot ([string]$profile.components.coreRelativePath)
    if (-not (Test-Path -LiteralPath $appExe -PathType Leaf)) {
        throw "Published package is missing required App executable: $appExe"
    }
    if (-not (Test-Path -LiteralPath $coreExe -PathType Leaf)) {
        throw "Published package is missing required Core executable: $coreExe"
    }

    $packageRoot = Join-Path $publishWorkRoot 'package'
    New-Item -ItemType Directory -Path $packageRoot -Force | Out-Null
    Copy-SafeDirectoryContents -Source $publishRoot -Destination $packageRoot

    $manifest = New-V02PackageManifestObject -Profile $profile -RepositoryRoot $repositoryRoot -PackageRoot $packageRoot
    $manifestPath = Join-Path $packageRoot ([string]$profile.packageManifestFileName)
    Write-V02CanonicalJsonFile -Value $manifest -Path $manifestPath -RepositoryRoot $repositoryRoot

    $archivePath = Join-Path $publishWorkRoot ([string]$profile.archiveFileName)
    $null = New-DeterministicPackageArchive -PackageRoot $packageRoot -ArchivePath $archivePath

    $receipt = Build-V02PackageIdentityReceiptObject `
        -Profile $profile `
        -RepositoryRoot $repositoryRoot `
        -ProfilePath $ProfilePath `
        -ArchivePath $archivePath `
        -PackageRoot $packageRoot

    $receiptPath = Join-Path $publishWorkRoot 'identity.json'
    Write-V02CanonicalJsonFile -Value $receipt -Path $receiptPath -RepositoryRoot $repositoryRoot

    $receiptParsed = Read-V02CanonicalIdentityReceipt -Path $receiptPath -RepositoryRoot $repositoryRoot
    $validatedIdentity = Assert-V02PackageIdentity `
        -Identity $receiptParsed.Identity `
        -Profile $profile `
        -RepositoryRoot $repositoryRoot `
        -ArchivePath $archivePath `
        -PackageRoot $packageRoot `
        -ProfilePath $ProfilePath `
        -ReceiptSha256 $receiptParsed.ReceiptSha256 `
        -CanonicalReceiptJson $receiptParsed.CanonicalJson

    # Atomically stage into output
    $parent = Split-Path -Path $safeOutputRoot -Parent
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    Assert-V02PathNoReparse -Path $parent

    $stagingOutput = Join-Path $parent ('.' + [IO.Path]::GetFileName($safeOutputRoot) + '.staging-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stagingOutput -Force | Out-Null

    $stagedPackageRoot = Join-Path $stagingOutput 'package'
    New-Item -ItemType Directory -Path $stagedPackageRoot -Force | Out-Null
    Copy-SafeDirectoryContents -Source $packageRoot -Destination $stagedPackageRoot

    $stagedArchive = Join-Path $stagingOutput ([string]$profile.archiveFileName)
    Copy-Item -LiteralPath $archivePath -Destination $stagedArchive -Force

    $stagedReceipt = Join-Path $stagingOutput 'identity.json'
    Copy-Item -LiteralPath $receiptPath -Destination $stagedReceipt -Force

    $stagedReceiptInPackage = Join-Path $stagedPackageRoot 'identity.json'
    Copy-Item -LiteralPath $receiptPath -Destination $stagedReceiptInPackage -Force

    $metadataPath = Join-Path $stagingOutput 'generation.metadata'
    $metadataContent = @"
HerdrOps v0.2 package generation metadata
SchemaVersion: 1
ProfileId: $($profile.profileId)
PackageVersion: 0.2.0
RuntimeIdentifier: win-x64
ReceiptSha256: $($receiptParsed.ReceiptSha256)
ArchiveSha256: $($validatedIdentity.ArchiveSha256)
AppSha256: $($validatedIdentity.AppSha256)
CoreSha256: $($validatedIdentity.CoreSha256)
EvidenceClass: Static/PackagedCompatibilityPreparation
"@
    [IO.File]::WriteAllText($metadataPath, $metadataContent.Replace("`r`n", "`n") + "`n", (New-Object Text.UTF8Encoding($false)))

    $markerPath = Join-Path $stagingOutput 'commit.marker'
    $markerContent = @"
HerdrOps v0.2 package generation commit marker
SchemaVersion: 1
ReceiptSha256: $($receiptParsed.ReceiptSha256)
CommittedUtc: $([DateTime]::UtcNow.ToString('o'))
"@
    [IO.File]::WriteAllText($markerPath, $markerContent.Replace("`r`n", "`n") + "`n", (New-Object Text.UTF8Encoding($false)))

    if ($TestFaultInjectionStage -eq 'BeforeCommit') {
        throw 'Injected v0.2 packaging failure before commit.'
    }

    [IO.Directory]::Move($stagingOutput, $safeOutputRoot)

    [pscustomobject][ordered]@{
        EvidenceClass = 'Static/PackagedCompatibilityPreparation'
        Issue = 149
        PackageVersion = '0.2.0'
        RuntimeIdentifier = 'win-x64'
        OutputRoot = $safeOutputRoot
        PackageRoot = (Join-Path $safeOutputRoot 'package')
        ArchivePath = (Join-Path $safeOutputRoot ([string]$profile.archiveFileName))
        IdentityPath = (Join-Path $safeOutputRoot 'identity.json')
        ReceiptSha256 = $receiptParsed.ReceiptSha256
        ArchiveSha256 = [string]$validatedIdentity.ArchiveSha256
        AppSha256 = [string]$validatedIdentity.AppSha256
        CoreSha256 = [string]$validatedIdentity.CoreSha256
        SourceCommit = [string]$validatedIdentity.SourceCommit
        SourceTree = [string]$validatedIdentity.SourceTree
        RuntimeUse = 'not-used'
        RuntimeCredit = 'NOT CLAIMED'
        ReleaseCredit = 'NOT CLAIMED'
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
