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
$script:stagingInstallDir=$null; $script:backupDir=$null; $script:committed=$false; $script:targetOwnedByTransaction=$false
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
    $installName=[IO.Path]::GetFileName($safeInstallRoot); $script:stagingInstallDir=Join-Path $installParent ('.'+$installName+'.staging-'+[Guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $script:stagingInstallDir|Out-Null
    Copy-V02StableTreeForInstall -Source $heldPayload -Destination $script:stagingInstallDir -InstallRoot $safeInstallRoot
    $stageArchiveRoot=Join-Path $tempWorkRoot 'stage-archive';New-Item -ItemType Directory $stageArchiveRoot|Out-Null
    $stageArchive=Join-Path $stageArchiveRoot ([string]$profile.archiveFileName); $null=New-DeterministicPackageArchive $script:stagingInstallDir $stageArchive
    if($TestFaultInjectionStage -eq 'StageMutation'){[IO.File]::AppendAllText((Join-Path $script:stagingInstallDir ([string]$profile.components.appRelativePath)),'MUTATED')}
    $null=Assert-V02PackageIdentity $identity $profile $repositoryRoot $stageArchive $script:stagingInstallDir $profilePath $receiptParsed.ReceiptSha256 $receiptParsed.CanonicalJson
    $null=Copy-V02StableFile $heldReceipt (Join-Path $script:stagingInstallDir 'identity.json')
    $state=[pscustomobject][ordered]@{productId='HerdrOps';packageVersion='0.2.0';runtimeIdentifier='win-x64';receiptSha256=$receiptParsed.ReceiptSha256;installRoot=$safeInstallRoot;userDataRoot=$safeUserDataRoot;startupRegistered=[bool]$RegisterStartup;autoUpdate='disabled-by-policy'}
    Write-V02CanonicalJsonFile $state (Join-Path $script:stagingInstallDir 'install-state.json') $repositoryRoot
    if($TestFaultInjectionStage -eq 'MidCopy'){throw 'Injected install failure during copy.'}

    if(Test-Path -LiteralPath $safeInstallRoot){
        if(-not(Test-Path -LiteralPath $safeInstallRoot -PathType Container)){throw "Existing install target is not a directory: $safeInstallRoot"}
        $bindingRoot=Join-Path $tempWorkRoot 'existing-binding'; New-Item -ItemType Directory $bindingRoot|Out-Null
        $null=Assert-V02CompleteInstalledBinding $safeInstallRoot $profile $profilePath $repositoryRoot $bindingRoot
    }
    if($TestFaultInjectionStage -eq 'BeforeCommit'){throw 'Injected install failure before atomic directory commit.'}
    if(Test-Path -LiteralPath $safeInstallRoot){$script:backupDir=Join-Path $installParent ('.'+$installName+'.backup-'+[Guid]::NewGuid().ToString('N'));[IO.Directory]::Move($safeInstallRoot,$script:backupDir)}
    if($TestConcurrentTargetAppearance){New-Item -ItemType Directory -Path $safeInstallRoot|Out-Null;[IO.File]::WriteAllText((Join-Path $safeInstallRoot 'unowned-race-sentinel.keep'),'UNOWNED')}
    try {
        [IO.Directory]::Move($script:stagingInstallDir,$safeInstallRoot); $script:stagingInstallDir=$null; $script:targetOwnedByTransaction=$true
        if($TestFaultInjectionStage -eq 'AfterReplace'){throw 'Injected install failure after directory replace.'}
        $finalBindingRoot=Join-Path $tempWorkRoot 'final-binding';New-Item -ItemType Directory $finalBindingRoot|Out-Null
        $null=Assert-V02CompleteInstalledBinding $safeInstallRoot $profile $profilePath $repositoryRoot $finalBindingRoot
        if($RegisterStartup){Register-V02UserStartup (Join-Path $safeInstallRoot ([string]$profile.components.appRelativePath)) $StartupValueName $MockRegistryHive}else{Unregister-V02UserStartup $StartupValueName $MockRegistryHive}
        if($TestFaultInjectionStage -eq 'AfterStartup'){throw 'Injected install failure after startup mutation.'}
        $script:committed=$true
    } catch {
        Restore-V02UserStartupState -State $startupBefore -ValueName $StartupValueName -MockRegistryHive $MockRegistryHive
        if($script:targetOwnedByTransaction -and (Test-Path -LiteralPath $safeInstallRoot)){Remove-V02TransactionDirectory $safeInstallRoot $installParent;$script:targetOwnedByTransaction=$false}
        if($null -ne $script:backupDir -and (Test-Path -LiteralPath $script:backupDir) -and -not(Test-Path -LiteralPath $safeInstallRoot)){[IO.Directory]::Move($script:backupDir,$safeInstallRoot);$script:backupDir=$null}
        throw
    }
    if($null -ne $script:backupDir -and (Test-Path -LiteralPath $script:backupDir)){Remove-V02TransactionDirectory $script:backupDir $installParent;$script:backupDir=$null}
    [pscustomobject][ordered]@{EvidenceClass='Static/PackagedCompatibilityPreparation';Status='Installed';PackageVersion='0.2.0';InstallRoot=$safeInstallRoot;UserDataRoot=$safeUserDataRoot;ReceiptSha256=$receiptParsed.ReceiptSha256;AppSha256=$validated.AppSha256;CoreSha256=$validated.CoreSha256;StartupRegistered=[bool]$RegisterStartup;UserDataRetained=$true;AutoUpdatePolicy='NoAutoUpdate';RuntimeCredit='NOT CLAIMED';ReleaseCredit='NOT CLAIMED'}
} -Cleanup {
    if($null -ne $script:stagingInstallDir -and (Test-Path -LiteralPath $script:stagingInstallDir)){Remove-V02TransactionDirectory $script:stagingInstallDir (Split-Path $safeInstallRoot -Parent); $script:stagingInstallDir=$null}
    if($null -ne $script:backupDir -and (Test-Path -LiteralPath $script:backupDir) -and -not(Test-Path -LiteralPath $safeInstallRoot)){[IO.Directory]::Move($script:backupDir,$safeInstallRoot);$script:backupDir=$null}
    if($TestInjectCleanupFailure){if(Test-Path -LiteralPath $tempWorkRoot){Remove-PackagingTempDirectory $tempWorkRoot};throw 'Injected install cleanup failure.'}
    if(Test-Path -LiteralPath $tempWorkRoot){Remove-PackagingTempDirectory $tempWorkRoot}
}
$installOutput
