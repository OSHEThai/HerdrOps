#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$InstallRoot,
    [string]$UserDataRoot,
    [string]$ProfilePath,
    [string]$RepositoryRoot,
    [string]$StartupValueName='HerdrOps',
    [hashtable]$MockRegistryHive=$null,
    [switch]$AllowElevatedForTesting,
    [string]$TestFaultInjectionStage='None',
    [switch]$TestInjectCleanupFailure
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'V02Packaging.Common.ps1')
Assert-V02NonElevated -AllowElevatedForTesting:$AllowElevatedForTesting
if([string]::IsNullOrWhiteSpace($InstallRoot)){$InstallRoot=Get-V02DefaultInstallRoot};$safeInstallRoot=[IO.Path]::GetFullPath($InstallRoot);Assert-V02NotSystemDirectory $safeInstallRoot;Assert-V02PathNoReparse $safeInstallRoot
if([string]::IsNullOrWhiteSpace($UserDataRoot)){$UserDataRoot=Get-V02DefaultUserDataRoot};$safeUserDataRoot=[IO.Path]::GetFullPath($UserDataRoot);Assert-V02NotSystemDirectory $safeUserDataRoot;Assert-V02PathNoReparse $safeUserDataRoot
if([string]::IsNullOrWhiteSpace($RepositoryRoot)){$RepositoryRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))};$repositoryRoot=[IO.Path]::GetFullPath($RepositoryRoot)
if([string]::IsNullOrWhiteSpace($ProfilePath)){$ProfilePath=Join-Path $PSScriptRoot 'package-identity-profile.json'};$profilePath=[IO.Path]::GetFullPath($ProfilePath);$profile=Read-V02PackageIdentityProfile $profilePath
Assert-V02PackagingPathsDoNotOverlap @([pscustomobject]@{Name='install root';Path=$safeInstallRoot},[pscustomobject]@{Name='user data root';Path=$safeUserDataRoot})
$userDataBefore=@{};if(Test-Path -LiteralPath $safeUserDataRoot -PathType Container){Assert-V02TreeNoReparse $safeUserDataRoot;$userDataBefore=Get-V02DirectoryHashes $safeUserDataRoot}
if(-not(Test-Path -LiteralPath $safeInstallRoot)){
    Unregister-V02UserStartup $StartupValueName $MockRegistryHive
    Assert-V02UserDataRetained $safeUserDataRoot $userDataBefore
    return [pscustomobject][ordered]@{EvidenceClass='Static/PackagedCompatibilityPreparation';Status='NotInstalled';InstallRoot=$safeInstallRoot;UserDataRoot=$safeUserDataRoot;UserDataRetained=$true;StartupRemoved=$true}
}
if(-not(Test-Path -LiteralPath $safeInstallRoot -PathType Container)){throw "Install target is not a directory: $safeInstallRoot"}
$workRoot=New-PackagingTempDirectory -Prefix 'HerdrOps-V02Uninstall-'
$staging=$null;$hadStartup=$false;$oldStartup=$null
if($null -ne $MockRegistryHive){$hadStartup=$MockRegistryHive.ContainsKey($StartupValueName);if($hadStartup){$oldStartup=$MockRegistryHive[$StartupValueName]}}
$result=Invoke-PackagingOperationWithCleanup -Operation {
    $bindingRoot=Join-Path $workRoot 'binding';New-Item -ItemType Directory $bindingRoot|Out-Null
    $null=Assert-V02CompleteInstalledBinding $safeInstallRoot $profile $profilePath $repositoryRoot $bindingRoot
    if($TestFaultInjectionStage -eq 'BeforeUninstallMove'){throw 'Injected uninstall failure before directory move.'}
    $parent=Split-Path $safeInstallRoot -Parent;$name=[IO.Path]::GetFileName($safeInstallRoot);$staging=Join-Path $parent ('.'+$name+'.uninstall-'+[Guid]::NewGuid().ToString('N'))
    [IO.Directory]::Move($safeInstallRoot,$staging)
    try {
        Unregister-V02UserStartup $StartupValueName $MockRegistryHive
        if($TestFaultInjectionStage -eq 'AfterUninstallMove'){throw 'Injected uninstall failure after directory move.'}
        Remove-V02TransactionDirectory $staging $parent;$staging=$null
    } catch {
        if($null -ne $staging -and (Test-Path -LiteralPath $staging) -and -not(Test-Path -LiteralPath $safeInstallRoot)){[IO.Directory]::Move($staging,$safeInstallRoot);$staging=$null}
        if($hadStartup -and $null -ne $MockRegistryHive){$MockRegistryHive[$StartupValueName]=$oldStartup}
        throw
    }
    Assert-V02UserDataRetained $safeUserDataRoot $userDataBefore
    [pscustomobject][ordered]@{EvidenceClass='Static/PackagedCompatibilityPreparation';Status='Uninstalled';InstallRoot=$safeInstallRoot;UserDataRoot=$safeUserDataRoot;UserDataRetained=$true;StartupRemoved=$true}
} -Cleanup {
    if($null -ne $staging -and (Test-Path -LiteralPath $staging) -and -not(Test-Path -LiteralPath $safeInstallRoot)){[IO.Directory]::Move($staging,$safeInstallRoot);$staging=$null}
    if($TestInjectCleanupFailure){if(Test-Path -LiteralPath $workRoot){Remove-PackagingTempDirectory $workRoot};throw 'Injected uninstall cleanup failure.'}
    if(Test-Path -LiteralPath $workRoot){Remove-PackagingTempDirectory $workRoot}
}
$result
