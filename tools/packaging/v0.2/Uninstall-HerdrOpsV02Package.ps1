#requires -Version 5.1

[CmdletBinding()]
param(
    [string]$InstallRoot,
    [string]$UserDataRoot,
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

Assert-V02PackagingPathsDoNotOverlap -Paths @(
    [pscustomobject]@{ Name = 'install root'; Path = $safeInstallRoot },
    [pscustomobject]@{ Name = 'user data root'; Path = $safeUserDataRoot }
)

$userDataBeforeHashes = @{}
if (Test-Path -LiteralPath $safeUserDataRoot -PathType Container) {
    Assert-V02TreeNoReparse -Path $safeUserDataRoot
    $userDataBeforeHashes = Get-V02DirectoryHashes -Path $safeUserDataRoot
}

if (-not (Test-Path -LiteralPath $safeInstallRoot)) {
    # Unregister startup anyway if leftover
    Unregister-V02UserStartup -ValueName $StartupValueName -MockRegistryHive $MockRegistryHive

    if ($userDataBeforeHashes.Count -gt 0) {
        Assert-V02UserDataRetained -UserDataRoot $safeUserDataRoot -ExpectedHashes $userDataBeforeHashes
    }

    return [pscustomobject][ordered]@{
        EvidenceClass = 'Static/PackagedCompatibilityPreparation'
        Status = 'NotInstalled'
        InstallRoot = $safeInstallRoot
        UserDataRoot = $safeUserDataRoot
        UserDataRetained = $true
        StartupRemoved = $true
    }
}

Assert-V02TreeNoReparse -Path $safeInstallRoot

# Fencing: Ensure directory is actually a HerdrOps installation before deleting
$hasAppExe = Test-Path -LiteralPath (Join-Path $safeInstallRoot 'HerdrOps.App.exe') -PathType Leaf
$hasManifest = Test-Path -LiteralPath (Join-Path $safeInstallRoot 'package-manifest.json') -PathType Leaf
$hasIdentity = Test-Path -LiteralPath (Join-Path $safeInstallRoot 'identity.json') -PathType Leaf
$hasState = Test-Path -LiteralPath (Join-Path $safeInstallRoot 'install-state.json') -PathType Leaf

if (-not $hasAppExe -and -not $hasManifest -and -not $hasIdentity -and -not $hasState) {
    throw "Refusing to uninstall from a directory that does not contain HerdrOps installation artifacts: $safeInstallRoot"
}

# Deregister startup
Unregister-V02UserStartup -ValueName $StartupValueName -MockRegistryHive $MockRegistryHive

if ($TestFaultInjectionStage -eq 'BeforeUninstallMove') {
    throw 'Injected uninstall failure before directory move.'
}

# Safe removal via atomic staging
$installParent = Split-Path -Path $safeInstallRoot -Parent
$installName = [IO.Path]::GetFileName($safeInstallRoot)
$stagingUninstallDir = Join-Path $installParent ('.' + $installName + '.uninstall-' + [Guid]::NewGuid().ToString('N'))

[IO.Directory]::Move($safeInstallRoot, $stagingUninstallDir)

if ($TestFaultInjectionStage -eq 'AfterUninstallMove') {
    # Rollback
    [IO.Directory]::Move($stagingUninstallDir, $safeInstallRoot)
    throw 'Injected uninstall failure after directory move.'
}

Remove-Item -LiteralPath $stagingUninstallDir -Recurse -Force

# Verify that user data was strictly retained and untouched
if ($userDataBeforeHashes.Count -gt 0) {
    Assert-V02UserDataRetained -UserDataRoot $safeUserDataRoot -ExpectedHashes $userDataBeforeHashes
}

[pscustomobject][ordered]@{
    EvidenceClass = 'Static/PackagedCompatibilityPreparation'
    Status = 'Uninstalled'
    InstallRoot = $safeInstallRoot
    UserDataRoot = $safeUserDataRoot
    UserDataRetained = $true
    StartupRemoved = $true
}
