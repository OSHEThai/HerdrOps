#requires -Version 5.1

[CmdletBinding()]
param(
    [string]$SimulationRoot,
    [switch]$KeepSimulationRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'V02Packaging.Common.ps1')

$worktree = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))

$ownedSimulationRoot = $false
if ([string]::IsNullOrWhiteSpace($SimulationRoot)) {
    $SimulationRoot = New-PackagingTempDirectory -Prefix 'HerdrOps-V02Lifecycle-'
    $ownedSimulationRoot = $true
}
$safeSimulationRoot = [IO.Path]::GetFullPath($SimulationRoot)
Assert-V02NotSystemDirectory -Path $safeSimulationRoot

$repo = Join-Path $safeSimulationRoot 'repo'
$mockInstallRoot = Join-Path $safeSimulationRoot 'Programs\HerdrOps'
$mockUserDataRoot = Join-Path $safeSimulationRoot 'HerdrOps'
$mockRegistry = @{}

try {
    # 1. Setup clean isolated Git fixture
    New-Item -ItemType Directory (Join-Path $repo 'Plan\reference-hosts') -Force | Out-Null
    New-Item -ItemType Directory (Join-Path $repo 'tools\lib') -Force | Out-Null
    New-Item -ItemType Directory (Join-Path $repo 'tools\packaging\v0.2') -Force | Out-Null

    Copy-Item (Join-Path $worktree 'Plan\reference-hosts\v0.2.json') (Join-Path $repo 'Plan\reference-hosts\v0.2.json')
    Copy-Item (Join-Path $worktree 'Plan\reference-hosts\reference-host-profile.schema.json') (Join-Path $repo 'Plan\reference-hosts\reference-host-profile.schema.json')
    Copy-Item (Join-Path $worktree 'tools\lib\V02ReferenceHostProfile.ps1') (Join-Path $repo 'tools\lib\V02ReferenceHostProfile.ps1')
    Copy-Item (Join-Path $PSScriptRoot 'package-identity-profile.json') (Join-Path $repo 'tools\packaging\v0.2\package-identity-profile.json')
    Copy-Item (Join-Path $PSScriptRoot 'package-identity-receipt.schema.json') (Join-Path $repo 'tools\packaging\v0.2\package-identity-receipt.schema.json')

    & git -C $repo init --quiet
    & git -C $repo -c user.name=HerdrOps-Test -c user.email=test@example.invalid add --all
    & git -C $repo -c user.name=HerdrOps-Test -c user.email=test@example.invalid commit --quiet -m 'fixture'
    if ($LASTEXITCODE -ne 0) { throw 'Git fixture commit failed.' }
    $global:LASTEXITCODE = 0

    $profilePath = Join-Path $repo 'tools\packaging\v0.2\package-identity-profile.json'
    $profile = Read-V02PackageIdentityProfile -Path $profilePath

    # 2. Prepare fixture package payload
    $fixturePayload = Join-Path $safeSimulationRoot 'fixture-payload'
    New-Item -ItemType Directory -Path $fixturePayload -Force | Out-Null
    $appExe = Join-Path $fixturePayload 'HerdrOps.App.exe'
    $coreExe = Join-Path $fixturePayload 'HerdrOps.Core.exe'
    $appDll = Join-Path $fixturePayload 'HerdrOps.App.dll'
    $coreDll = Join-Path $fixturePayload 'HerdrOps.Core.dll'
    $runtimeConfig = Join-Path $fixturePayload 'HerdrOps.App.runtimeconfig.json'

    [IO.File]::WriteAllBytes($appExe, [byte[]](10, 20, 30, 40, 50, 60))
    [IO.File]::WriteAllBytes($coreExe, [byte[]](11, 21, 31, 41, 51))
    [IO.File]::WriteAllBytes($appDll, [byte[]](100, 101, 102))
    [IO.File]::WriteAllBytes($coreDll, [byte[]](200, 201, 202))
    [IO.File]::WriteAllBytes($runtimeConfig, [byte[]](123, 125))

    $manifest = New-V02PackageManifestObject -Profile $profile -RepositoryRoot $repo -PackageRoot $fixturePayload
    $manifestPath = Join-Path $fixturePayload 'package-manifest.json'
    Write-V02CanonicalJsonFile -Value $manifest -Path $manifestPath -RepositoryRoot $repo

    $archivePath = Join-Path $safeSimulationRoot 'HerdrOps-0.2.0-win-x64.zip'
    $null = New-DeterministicPackageArchive -PackageRoot $fixturePayload -ArchivePath $archivePath

    $receiptObj = Build-V02PackageIdentityReceiptObject `
        -Profile $profile `
        -RepositoryRoot $repo `
        -ProfilePath $profilePath `
        -ArchivePath $archivePath `
        -PackageRoot $fixturePayload

    $receiptPath = Join-Path $safeSimulationRoot 'identity.json'
    Write-V02CanonicalJsonFile -Value $receiptObj -Path $receiptPath -RepositoryRoot $repo

    # 3. Simulated Clean Install with Startup Opt-In
    $installResult = & (Join-Path $PSScriptRoot 'Install-HerdrOpsV02Package.ps1') `
        -IdentityReceiptPath $receiptPath `
        -ArchivePath $archivePath `
        -InstallRoot $mockInstallRoot `
        -UserDataRoot $mockUserDataRoot `
        -RepositoryRoot $repo `
        -ProfilePath $profilePath `
        -RegisterStartup `
        -MockRegistryHive $mockRegistry `
        -AllowElevatedForTesting

    # 4. Simulate user data creation
    New-Item -ItemType Directory -Path $mockUserDataRoot -Force | Out-Null
    $userDataDb = Join-Path $mockUserDataRoot 'state.db'
    $userSettings = Join-Path $mockUserDataRoot 'config.json'
    [IO.File]::WriteAllBytes($userDataDb, [byte[]](1, 2, 3, 5, 8, 13, 21))
    [IO.File]::WriteAllBytes($userSettings, [byte[]](123, 34, 116, 104, 101, 109, 101, 34, 58, 34, 100, 97, 114, 107, 34, 125))

    $userDataHashes = Get-V02DirectoryHashes -Path $mockUserDataRoot

    # 5. Simulated Upgrade
    $upgradeResult = & (Join-Path $PSScriptRoot 'Install-HerdrOpsV02Package.ps1') `
        -IdentityReceiptPath $receiptPath `
        -PackageRoot $fixturePayload `
        -InstallRoot $mockInstallRoot `
        -UserDataRoot $mockUserDataRoot `
        -RepositoryRoot $repo `
        -ProfilePath $profilePath `
        -RegisterStartup `
        -MockRegistryHive $mockRegistry `
        -AllowElevatedForTesting

    # 6. Simulated Uninstall
    $uninstallResult = & (Join-Path $PSScriptRoot 'Uninstall-HerdrOpsV02Package.ps1') `
        -InstallRoot $mockInstallRoot `
        -UserDataRoot $mockUserDataRoot `
        -MockRegistryHive $mockRegistry `
        -AllowElevatedForTesting

    # 7. Verify user data was 100% retained
    Assert-V02UserDataRetained -UserDataRoot $mockUserDataRoot -ExpectedHashes $userDataHashes

    [pscustomobject][ordered]@{
        EvidenceClass = 'Synthetic/PackagedCompatibilityLifecycle'
        Status = 'PASS'
        PackageVersion = '0.2.0'
        DeploymentModel = 'per-user-directory'
        InstallRoot = $mockInstallRoot
        UserDataRoot = $mockUserDataRoot
        ReceiptSha256 = $installResult.ReceiptSha256
        CleanInstallObserved = ($installResult.Status -eq 'Installed')
        StartupOptInObserved = $installResult.StartupRegistered
        UpgradeObserved = ($upgradeResult.Status -eq 'Installed')
        UninstallObserved = ($uninstallResult.Status -eq 'Uninstalled')
        UserDataRetained = $uninstallResult.UserDataRetained
        StartupCleaned = (-not $mockRegistry.ContainsKey('HerdrOps'))
        RuntimeCredit = 'NOT CLAIMED'
        ReleaseCredit = 'NOT CLAIMED'
    }
} finally {
    if ($ownedSimulationRoot -and -not $KeepSimulationRoot -and (Test-Path -LiteralPath $safeSimulationRoot)) {
        Remove-PackagingTempDirectory -Path $safeSimulationRoot
    }
}
