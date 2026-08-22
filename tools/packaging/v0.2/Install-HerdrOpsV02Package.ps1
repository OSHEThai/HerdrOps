#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$IdentityReceiptPath,
    [string]$ArchivePath,
    [string]$PackageRoot,
    [string]$InstallRoot,
    [string]$UserDataRoot,
    [string]$ProfilePath,
    [string]$RepositoryRoot,
    [switch]$RegisterStartup,
    [string]$StartupValueName = 'HerdrOps',
    [hashtable]$MockRegistryHive = $null,
    [switch]$AllowElevatedForTesting,
    [string]$TestFaultInjectionStage = 'None',
    [switch]$TestInjectCleanupFailure
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'V02Packaging.Common.ps1')

Assert-V02NonElevated -AllowElevatedForTesting:$AllowElevatedForTesting

if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
    $InstallRoot = Get-V02DefaultInstallRoot
}
$safeInstallRoot = [IO.Path]::GetFullPath($InstallRoot)
Assert-V02NotSystemDirectory -Path $safeInstallRoot

if ([string]::IsNullOrWhiteSpace($UserDataRoot)) {
    $UserDataRoot = Get-V02DefaultUserDataRoot
}
$safeUserDataRoot = [IO.Path]::GetFullPath($UserDataRoot)
Assert-V02NotSystemDirectory -Path $safeUserDataRoot

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
}
$repositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)

if ([string]::IsNullOrWhiteSpace($ProfilePath)) {
    $ProfilePath = Join-Path $PSScriptRoot 'package-identity-profile.json'
}
$profile = Read-V02PackageIdentityProfile -Path $ProfilePath

$identityFullPath = [IO.Path]::GetFullPath($IdentityReceiptPath)
if (-not (Test-Path -LiteralPath $identityFullPath -PathType Leaf)) {
    throw "Package identity receipt was not found: $identityFullPath"
}
Assert-V02PathNoReparse -Path $identityFullPath

$receiptParsed = Read-V02CanonicalIdentityReceipt -Path $identityFullPath -RepositoryRoot $repositoryRoot
$identity = $receiptParsed.Identity

# Verify receipt against schema
$null = Assert-V02ReceiptSchema -Identity $identity -CanonicalJson $receiptParsed.CanonicalJson -RepositoryRoot $repositoryRoot

if ([string]$identity.packageVersion -cne '0.2.0' -or
    [string]$identity.runtimeIdentifier -cne 'win-x64' -or
    [string]$identity.profileId -cne [string]$profile.profileId) {
    throw 'Package identity receipt does not match the authorized v0.2 package profile.'
}

# Check overlap between InstallRoot, UserDataRoot, and Receipt
Assert-V02PackagingPathsDoNotOverlap -Paths @(
    [pscustomobject]@{ Name = 'install root'; Path = $safeInstallRoot },
    [pscustomobject]@{ Name = 'user data root'; Path = $safeUserDataRoot },
    [pscustomobject]@{ Name = 'identity receipt'; Path = $identityFullPath }
)

# Extract / stage payload for verification
$tempWorkRoot = New-PackagingTempDirectory -Prefix 'HerdrOps-V02Install-'

$installOutput = Invoke-PackagingOperationWithCleanup -Operation {
    $payloadRoot = $null

    if (-not [string]::IsNullOrWhiteSpace($ArchivePath)) {
        $safeArchive = [IO.Path]::GetFullPath($ArchivePath)
        if (-not (Test-Path -LiteralPath $safeArchive -PathType Leaf)) {
            throw "Package archive was not found: $safeArchive"
        }
        Assert-V02PathNoReparse -Path $safeArchive
        Assert-V02PackagingPathsDoNotOverlap -Paths @(
            [pscustomobject]@{ Name = 'install root'; Path = $safeInstallRoot },
            [pscustomobject]@{ Name = 'archive source'; Path = $safeArchive }
        )

        $archiveStable = Get-V02StableFileIdentity -Path $safeArchive
        if ($archiveStable.Length -ne [int64]$identity.archive.bytes -or
            $archiveStable.Sha256 -cne [string]$identity.archive.sha256) {
            throw 'Package archive SHA-256 or byte length does not match identity receipt (tamper detected).'
        }

        $extractedRoot = Join-Path $tempWorkRoot 'extracted'
        Extract-V02PackageArchive -ArchivePath $safeArchive -DestinationPath $extractedRoot
        $payloadRoot = $extractedRoot
    } elseif (-not [string]::IsNullOrWhiteSpace($PackageRoot)) {
        $safePackageRoot = [IO.Path]::GetFullPath($PackageRoot)
        if (-not (Test-Path -LiteralPath $safePackageRoot -PathType Container)) {
            throw "Package root directory was not found: $safePackageRoot"
        }
        Assert-V02TreeNoReparse -Path $safePackageRoot
        Assert-V02PackagingPathsDoNotOverlap -Paths @(
            [pscustomobject]@{ Name = 'install root'; Path = $safeInstallRoot },
            [pscustomobject]@{ Name = 'package source root'; Path = $safePackageRoot }
        )
        $payloadRoot = $safePackageRoot
    } else {
        throw 'Either ArchivePath or PackageRoot must be provided to install.'
    }

    # Verify payload against unsigned local SHA policy
    $null = Assert-V02UnsignedLocalShaPolicy `
        -PackageRoot $payloadRoot `
        -Identity $identity `
        -Profile $profile `
        -RepositoryRoot $repositoryRoot

    # Target parent directory
    $installParent = Split-Path -Path $safeInstallRoot -Parent
    if (-not (Test-Path -LiteralPath $installParent -PathType Container)) {
        New-Item -ItemType Directory -Path $installParent -Force | Out-Null
    }
    Assert-V02PathNoReparse -Path $installParent

    # Create atomic staging directory
    $installName = [IO.Path]::GetFileName($safeInstallRoot)
    $stagingInstallDir = Join-Path $installParent ('.' + $installName + '.staging-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stagingInstallDir -Force | Out-Null

    Copy-SafeDirectoryContents -Source $payloadRoot -Destination $stagingInstallDir

    # Copy identity receipt into installation directory
    $installedReceiptPath = Join-Path $stagingInstallDir 'identity.json'
    Copy-Item -LiteralPath $identityFullPath -Destination $installedReceiptPath -Force

    $installRecord = [ordered]@{
        productId = 'HerdrOps'
        packageVersion = '0.2.0'
        runtimeIdentifier = 'win-x64'
        receiptSha256 = [string]$receiptParsed.ReceiptSha256
        installedUtc = [DateTime]::UtcNow.ToString('o')
        installRoot = $safeInstallRoot
        userDataRoot = $safeUserDataRoot
        startupRegistered = [bool]$RegisterStartup
        autoUpdate = 'disabled-by-policy'
    }
    $recordJson = $installRecord | ConvertTo-Json -Depth 5
    [IO.File]::WriteAllText((Join-Path $stagingInstallDir 'install-state.json'), $recordJson + "`n", (New-Object Text.UTF8Encoding($false)))

    if ($TestFaultInjectionStage -eq 'MidCopy') {
        throw 'Injected install failure during copy.'
    }

    # Verify staging install directory
    Assert-V02TreeNoReparse -Path $stagingInstallDir

    if ($TestFaultInjectionStage -eq 'BeforeCommit') {
        throw 'Injected install failure before atomic directory commit.'
    }

    # Atomic move with backup / rollback
    $backupDir = $null
    $existingPresent = Test-Path -LiteralPath $safeInstallRoot
    if ($existingPresent) {
        Assert-V02TreeNoReparse -Path $safeInstallRoot
        $backupDir = Join-Path $installParent ('.' + $installName + '.backup-' + [Guid]::NewGuid().ToString('N'))
        [IO.Directory]::Move($safeInstallRoot, $backupDir)
    }

    $moveSucceeded = $false
    try {
        [IO.Directory]::Move($stagingInstallDir, $safeInstallRoot)
        $moveSucceeded = $true

        if ($TestFaultInjectionStage -eq 'AfterReplace') {
            throw 'Injected install failure after directory replace.'
        }
    } finally {
        if (-not $moveSucceeded -or $TestFaultInjectionStage -eq 'AfterReplace') {
            # Rollback
            if (Test-Path -LiteralPath $safeInstallRoot) {
                Remove-Item -LiteralPath $safeInstallRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
            if ($null -ne $backupDir -and (Test-Path -LiteralPath $backupDir)) {
                [IO.Directory]::Move($backupDir, $safeInstallRoot)
                $backupDir = $null
            }
        }
    }

    # Cleanup backup after successful replacement
    if ($null -ne $backupDir -and (Test-Path -LiteralPath $backupDir)) {
        Remove-Item -LiteralPath $backupDir -Recurse -Force
    }

    # Handle startup opt-in
    $appInstalledExe = Join-Path $safeInstallRoot ([string]$profile.components.appRelativePath)
    if ($RegisterStartup) {
        Register-V02UserStartup `
            -ExecutablePath $appInstalledExe `
            -ValueName $StartupValueName `
            -MockRegistryHive $MockRegistryHive
    } else {
        Unregister-V02UserStartup `
            -ValueName $StartupValueName `
            -MockRegistryHive $MockRegistryHive
    }

    [pscustomobject][ordered]@{
        EvidenceClass = 'Static/PackagedCompatibilityPreparation'
        Status = 'Installed'
        PackageVersion = '0.2.0'
        InstallRoot = $safeInstallRoot
        UserDataRoot = $safeUserDataRoot
        ReceiptSha256 = [string]$receiptParsed.ReceiptSha256
        AppSha256 = [string]$identity.components.app.sha256
        CoreSha256 = [string]$identity.components.core.sha256
        StartupRegistered = [bool]$RegisterStartup
        UserDataRetained = $true
        AutoUpdatePolicy = 'NoAutoUpdate'
        RuntimeCredit = 'NOT CLAIMED'
        ReleaseCredit = 'NOT CLAIMED'
    }
} -Cleanup {
    if ($TestInjectCleanupFailure) {
        if (Test-Path -LiteralPath $tempWorkRoot) {
            Remove-PackagingTempDirectory -Path $tempWorkRoot
        }
        throw 'Injected install cleanup failure.'
    }
    if (Test-Path -LiteralPath $tempWorkRoot) {
        Remove-PackagingTempDirectory -Path $tempWorkRoot
    }
}

$installOutput
