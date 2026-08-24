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
    [string]$TestMutationPath,
    [switch]$TestConcurrentTargetAppearance,
    [switch]$TestInjectCleanupFailure
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'V02Packaging.Common.ps1')
Assert-V02NonElevated -AllowElevatedForTesting:$AllowElevatedForTesting
if([string]::IsNullOrWhiteSpace($InstallRoot)){$InstallRoot=Get-V02DefaultInstallRoot}; $safeInstallRoot=[IO.Path]::GetFullPath($InstallRoot); Assert-V02NotSystemDirectory $safeInstallRoot; Assert-V02PathNoReparse $safeInstallRoot
if([string]::IsNullOrWhiteSpace($UserDataRoot)){$UserDataRoot=Get-V02DefaultUserDataRoot}; $safeUserDataRoot=[IO.Path]::GetFullPath($UserDataRoot); Assert-V02NotSystemDirectory $safeUserDataRoot; Assert-V02PathNoReparse $safeUserDataRoot
if([string]::IsNullOrWhiteSpace($RepositoryRoot)){$RepositoryRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))}; $repositoryRoot=[IO.Path]::GetFullPath($RepositoryRoot)
if([string]::IsNullOrWhiteSpace($ProfilePath)){$ProfilePath=Join-Path $PSScriptRoot 'package-identity-profile.json'}; $profilePath=[IO.Path]::GetFullPath($ProfilePath); $profile=Read-V02PackageIdentityProfile $profilePath
$identityFullPath=[IO.Path]::GetFullPath($IdentityReceiptPath); if(-not(Test-Path -LiteralPath $identityFullPath -PathType Leaf)){throw "Package identity receipt was not found: $identityFullPath"}; Assert-V02PathNoReparse $identityFullPath
if(([string]::IsNullOrWhiteSpace($ArchivePath) -and [string]::IsNullOrWhiteSpace($PackageRoot)) -or (-not [string]::IsNullOrWhiteSpace($ArchivePath) -and -not [string]::IsNullOrWhiteSpace($PackageRoot))){throw 'Exactly one of ArchivePath or PackageRoot must be provided to install.'}
Assert-V02PackagingPathsDoNotOverlap @([pscustomobject]@{Name='install root';Path=$safeInstallRoot},[pscustomobject]@{Name='user data root';Path=$safeUserDataRoot},[pscustomobject]@{Name='identity receipt';Path=$identityFullPath})

$tempWorkRoot=New-PackagingTempDirectory -Prefix 'HerdrOps-V02Install-'
$script:stagingInstallDir=$null; $script:stagingIdentity=$null; $script:targetIdentity=$null; $script:backupDir=$null; $script:backupIdentity=$null; $script:backupCreated=$false; $script:backupRetired=$false; $script:committed=$false; $script:targetOwnedByTransaction=$false
$startupBefore=Get-V02UserStartupState -ValueName $StartupValueName -MockRegistryHive $MockRegistryHive
$installOutput=Invoke-PackagingOperationWithCleanup -Operation {
    $heldReceipt=Join-Path $tempWorkRoot 'identity.json'; $null=Copy-V02StableFile $identityFullPath $heldReceipt
    $receiptParsed=Read-V02CanonicalIdentityReceipt $heldReceipt $repositoryRoot; $identity=$receiptParsed.Identity
    $heldPayload=Join-Path $tempWorkRoot 'payload'; New-Item -ItemType Directory $heldPayload|Out-Null
    $heldArchive=Join-Path $tempWorkRoot ([string]$profile.archiveFileName)
    if(-not [string]::IsNullOrWhiteSpace($ArchivePath)){
        $sourceArchive=[IO.Path]::GetFullPath($ArchivePath); Assert-V02PackagingPathsDoNotOverlap @([pscustomobject]@{Name='install root';Path=$safeInstallRoot},[pscustomobject]@{Name='archive source';Path=$sourceArchive}); $null=Copy-V02StableFile $sourceArchive $heldArchive
        Extract-V02PackageArchive $heldArchive $heldPayload
    } else {
        $sourceRoot=[IO.Path]::GetFullPath($PackageRoot); if(-not(Test-Path -LiteralPath $sourceRoot -PathType Container)){throw "Package root directory was not found: $sourceRoot"}; Assert-V02TreeNoReparse $sourceRoot
        Assert-V02PackagingPathsDoNotOverlap @([pscustomobject]@{Name='install root';Path=$safeInstallRoot},[pscustomobject]@{Name='package source';Path=$sourceRoot})
        Copy-SafeDirectoryContents $sourceRoot $heldPayload
        $null=New-DeterministicPackageArchive $heldPayload $heldArchive
    }
    if($TestFaultInjectionStage -eq 'AfterSourceSnapshot' -and -not [string]::IsNullOrWhiteSpace($TestMutationPath)){[IO.File]::AppendAllText([IO.Path]::GetFullPath($TestMutationPath),'MUTATED')}
    $validated=Assert-V02PackageIdentity $identity $profile $repositoryRoot $heldArchive $heldPayload $profilePath $receiptParsed.ReceiptSha256 $receiptParsed.CanonicalJson

    $installParent=Split-Path $safeInstallRoot -Parent; if(-not(Test-Path -LiteralPath $installParent -PathType Container)){New-Item -ItemType Directory $installParent -Force|Out-Null}; Assert-V02PathNoReparse $installParent
    $installName=[IO.Path]::GetFileName($safeInstallRoot); $script:stagingInstallDir=Join-Path $installParent ('.'+$installName+'.staging-'+[Guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $script:stagingInstallDir|Out-Null; $script:stagingIdentity=Get-V02DirectoryPathIdentity $script:stagingInstallDir 'created install staging directory'
    Copy-V02StableTreeForInstall -Source $heldPayload -Destination $script:stagingInstallDir -InstallRoot $safeInstallRoot
    $null=Assert-V02OwnedStagingIdentity $script:stagingInstallDir $script:stagingIdentity 'install staging after payload copy'
    if($TestFaultInjectionStage -eq 'StageMutation'){[IO.File]::AppendAllText((Join-Path $script:stagingInstallDir ([string]$profile.components.appRelativePath)),'MUTATED')}
    $null=Copy-V02StableFile $heldReceipt (Join-Path $script:stagingInstallDir 'identity.json')
    $state=[pscustomobject][ordered]@{productId='HerdrOps';packageVersion='0.2.0';runtimeIdentifier='win-x64';receiptSha256=$receiptParsed.ReceiptSha256;installRoot=$safeInstallRoot;userDataRoot=$safeUserDataRoot;startupRegistered=[bool]$RegisterStartup;autoUpdate='disabled-by-policy'}
    $stateTempPath=Join-Path $tempWorkRoot 'install-state.json';$stateTempBinding=Write-V02CanonicalTempFileNoClobber $state $stateTempPath $repositoryRoot
    $null=Copy-V02InstallStateToOwnedStaging -SourcePath $stateTempPath -ExpectedSourceBinding $stateTempBinding `
        -DestinationPath (Join-Path $script:stagingInstallDir 'install-state.json') `
        -OwnedStagingRoot $script:stagingInstallDir `
        -ExpectedStagingIdentity $script:stagingIdentity `
        -InstallRoot $safeInstallRoot
    $null=Assert-V02OwnedStagingIdentity $script:stagingInstallDir $script:stagingIdentity 'install staging before complete binding validation'
    $stageBindingRoot=Join-Path $tempWorkRoot 'stage-binding';New-Item -ItemType Directory $stageBindingRoot|Out-Null
    $null=Assert-V02CompleteInstalledBinding -InstallRoot $script:stagingInstallDir -Profile $profile -ProfilePath $profilePath -RepositoryRoot $repositoryRoot -WorkRoot $stageBindingRoot -ExpectedInstallRoot $safeInstallRoot
    $null=Assert-V02OwnedStagingIdentity $script:stagingInstallDir $script:stagingIdentity 'install staging after complete binding validation'
    if($TestFaultInjectionStage -eq 'MidCopy'){throw 'Injected install failure during copy.'}

    if(Test-Path -LiteralPath $safeInstallRoot){
        if(-not(Test-Path -LiteralPath $safeInstallRoot -PathType Container)){throw "Existing install target is not a directory: $safeInstallRoot"}
        $bindingRoot=Join-Path $tempWorkRoot 'existing-binding'; New-Item -ItemType Directory $bindingRoot|Out-Null
        $null=Assert-V02CompleteInstalledBinding $safeInstallRoot $profile $profilePath $repositoryRoot $bindingRoot
    }
    if($TestFaultInjectionStage -eq 'BeforeCommit'){throw 'Injected install failure before atomic directory commit.'}
    if(Test-Path -LiteralPath $safeInstallRoot){
        $existingIdentity=Get-V02DirectoryPathIdentity $safeInstallRoot 'existing install before backup'
        $script:backupDir=Join-Path $installParent ('.'+$installName+'.backup-'+[Guid]::NewGuid().ToString('N'))
        [IO.Directory]::Move($safeInstallRoot,$script:backupDir)
        $script:backupIdentity=Get-V02DirectoryPathIdentity $script:backupDir 'created install backup'
        if($script:backupIdentity.VolumeSerialNumber -cne $existingIdentity.VolumeSerialNumber -or $script:backupIdentity.FileId -cne $existingIdentity.FileId -or $script:backupIdentity.LinkCount -ne $existingIdentity.LinkCount){throw 'Created backup does not equal the exact prior installed directory identity.'}
        $script:backupCreated=$true
    }
    if($TestConcurrentTargetAppearance){New-Item -ItemType Directory -Path $safeInstallRoot|Out-Null;[IO.File]::WriteAllText((Join-Path $safeInstallRoot 'unowned-race-sentinel.keep'),'UNOWNED')}
    try {
        [IO.Directory]::Move($script:stagingInstallDir,$safeInstallRoot); $script:targetIdentity=Get-V02DirectoryPathIdentity $safeInstallRoot 'committed install target'; if($script:targetIdentity.VolumeSerialNumber -cne $script:stagingIdentity.VolumeSerialNumber -or $script:targetIdentity.FileId -cne $script:stagingIdentity.FileId){throw 'Committed install target does not equal the exact owned staging identity.'}; $script:stagingInstallDir=$null; $script:targetOwnedByTransaction=$true
        if($TestFaultInjectionStage -eq 'AfterReplace'){throw 'Injected install failure after directory replace.'}
        $finalBindingRoot=Join-Path $tempWorkRoot 'final-binding';New-Item -ItemType Directory $finalBindingRoot|Out-Null
        $null=Assert-V02CompleteInstalledBinding $safeInstallRoot $profile $profilePath $repositoryRoot $finalBindingRoot
        if($RegisterStartup){Register-V02UserStartup (Join-Path $safeInstallRoot ([string]$profile.components.appRelativePath)) $StartupValueName $MockRegistryHive}else{Unregister-V02UserStartup $StartupValueName $MockRegistryHive}
        if($TestFaultInjectionStage -eq 'AfterStartup'){throw 'Injected install failure after startup mutation.'}
        $script:committed=$true
    } catch {
        Restore-V02UserStartupState -State $startupBefore -ValueName $StartupValueName -MockRegistryHive $MockRegistryHive
        if($script:targetOwnedByTransaction -and (Test-Path -LiteralPath $safeInstallRoot)){Remove-V02TransactionDirectory $safeInstallRoot $installParent $script:targetIdentity;$script:targetOwnedByTransaction=$false}
        if($null -ne $script:backupDir -and (Test-Path -LiteralPath $script:backupDir) -and -not(Test-Path -LiteralPath $safeInstallRoot)){[IO.Directory]::Move($script:backupDir,$safeInstallRoot);$restoredIdentity=Get-V02DirectoryPathIdentity $safeInstallRoot 'restored install backup';if($restoredIdentity.VolumeSerialNumber -cne $script:backupIdentity.VolumeSerialNumber -or $restoredIdentity.FileId -cne $script:backupIdentity.FileId){throw 'Rollback restored a different directory object than the exact owned backup.'};$script:backupDir=$null}
        throw
    }
    if($null -ne $script:backupDir -and (Test-Path -LiteralPath $script:backupDir)){Remove-V02TransactionDirectory $script:backupDir $installParent $script:backupIdentity;$script:backupRetired=(-not(Test-Path -LiteralPath $script:backupDir));$script:backupDir=$null}
    [pscustomobject][ordered]@{EvidenceClass='Static/PackagedCompatibilityPreparation';Status='Installed';PackageVersion='0.2.0';InstallRoot=$safeInstallRoot;UserDataRoot=$safeUserDataRoot;ReceiptSha256=$receiptParsed.ReceiptSha256;AppSha256=$validated.AppSha256;CoreSha256=$validated.CoreSha256;StartupRegistered=[bool]$RegisterStartup;UserDataRetained=$true;BackupCreated=[bool]$script:backupCreated;BackupRetired=[bool]$script:backupRetired;BackupVolumeSerialNumber=$(if($null -ne $script:backupIdentity){$script:backupIdentity.VolumeSerialNumber}else{''});BackupFileId=$(if($null -ne $script:backupIdentity){$script:backupIdentity.FileId}else{''});BackupLinkCount=$(if($null -ne $script:backupIdentity){[int]$script:backupIdentity.LinkCount}else{0});AutoUpdatePolicy='NoAutoUpdate';RuntimeCredit='NOT CLAIMED';ReleaseCredit='NOT CLAIMED'}
} -Cleanup {
    if($null -ne $script:stagingInstallDir -and (Test-Path -LiteralPath $script:stagingInstallDir)){Remove-V02TransactionDirectory $script:stagingInstallDir (Split-Path $safeInstallRoot -Parent) $script:stagingIdentity; $script:stagingInstallDir=$null}
    if($null -ne $script:backupDir -and (Test-Path -LiteralPath $script:backupDir) -and -not(Test-Path -LiteralPath $safeInstallRoot)){[IO.Directory]::Move($script:backupDir,$safeInstallRoot);$restoredIdentity=Get-V02DirectoryPathIdentity $safeInstallRoot 'cleanup-restored install backup';if($restoredIdentity.VolumeSerialNumber -cne $script:backupIdentity.VolumeSerialNumber -or $restoredIdentity.FileId -cne $script:backupIdentity.FileId){throw 'Cleanup rollback restored a different directory object than the exact owned backup.'};$script:backupDir=$null}
    if($TestInjectCleanupFailure){if(Test-Path -LiteralPath $tempWorkRoot){Remove-PackagingTempDirectory $tempWorkRoot};throw 'Injected install cleanup failure.'}
    if(Test-Path -LiteralPath $tempWorkRoot){Remove-PackagingTempDirectory $tempWorkRoot}
}
$installOutput
