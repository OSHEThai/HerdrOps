#requires -Version 5.1
<#
.SYNOPSIS
Builds the fail-closed HerdrOps v0.2 package preparation output.

.PARAMETER OutputRoot
Exact destination directory for the atomic package generation. The path must not
already exist, including as an empty directory; this preserves caller-owned paths
and allows the validated staging directory to be committed with one directory move.
#>
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

if ([string]::IsNullOrWhiteSpace($ProfilePath)) { $ProfilePath = Join-Path $PSScriptRoot 'package-identity-profile.json' }
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) { $RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..')) }
$repositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)
$profilePath = [IO.Path]::GetFullPath($ProfilePath)
$profile = Read-V02PackageIdentityProfile -Path $profilePath
Assert-V02TreeNoReparse -Path $repositoryRoot
if (-not [string]::IsNullOrWhiteSpace($PackageVersion) -and $PackageVersion -cne '0.2.0') { throw "v0.2 packaging wrapper is pinned to version 0.2.0: $PackageVersion" }
$safeOutputRoot = Assert-SafeDestination -Path $OutputRoot -AllowRepositoryChild -AllowTempChild
Assert-V02PackagingPathsDoNotOverlap -Paths @([pscustomobject]@{Name='repository root';Path=$repositoryRoot},[pscustomobject]@{Name='output root';Path=$safeOutputRoot})
$outputRootExistedBefore = Test-Path -LiteralPath $safeOutputRoot
if ($outputRootExistedBefore) {
    throw "OutputRoot must not already exist, including as an empty directory; refusing to modify caller-owned path: $safeOutputRoot"
}
$sourceBefore = Get-V02GitIdentity -RepositoryRoot $repositoryRoot -RequireClean
$publishWorkRoot = New-PackagingTempDirectory -Prefix 'HerdrOps-V02Publish-'
$stagingOutput = $null
$committedOutput = $false
$operationOutput = Invoke-PackagingOperationWithCleanup -Operation {
    if ($TestInjectPrimaryFailure) { throw 'Injected packaging primary operation failure.' }
    $appProject = Join-Path $repositoryRoot 'src\HerdrOps.App\HerdrOps.App.csproj'
    $coreProject = Join-Path $repositoryRoot 'src\HerdrOps.Core\HerdrOps.Core.csproj'
    foreach ($project in @($appProject,$coreProject)) { if (-not (Test-Path -LiteralPath $project -PathType Leaf)) { throw "Required publish project is missing: $project" } }
    $lockPaths = @('src\HerdrOps.App\packages.lock.json','src\HerdrOps.Core\packages.lock.json','src\HerdrOps.Infrastructure\packages.lock.json','src\HerdrOps.Contracts\packages.lock.json','src\HerdrOps.Domain\packages.lock.json') | ForEach-Object { Join-Path $repositoryRoot $_ }
    $lockHashes = @{}
    foreach ($lockPath in $lockPaths) { if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) { throw "Required source package lock file is missing: $lockPath" }; $lockHashes[$lockPath]=(Get-V02StableFileIdentity $lockPath).Sha256 }
    $dotnetCommand='dotnet'
    if (-not [string]::IsNullOrWhiteSpace($TestDotnetCommandPath)) { $dotnetCommand=[IO.Path]::GetFullPath($TestDotnetCommandPath); if (-not(Test-Path -LiteralPath $dotnetCommand -PathType Leaf)){throw "Test dotnet command was not found: $dotnetCommand"} }
    foreach ($project in @($appProject,$coreProject)) {
        $restoreOutput=@(& $dotnetCommand restore $project --runtime win-x64 --locked-mode --nologo 2>&1); $restoreExit=$LASTEXITCODE; $global:LASTEXITCODE=0
        if($restoreExit -ne 0){throw "Locked win-x64 restore failed for '$project' ($restoreExit).`n$(($restoreOutput|Select-Object -Last 20)-join "`n")"}
    }
    foreach($lockPath in $lockPaths){if((Get-V02StableFileIdentity $lockPath).Sha256 -cne $lockHashes[$lockPath]){throw "Locked restore changed source lock file: $lockPath"}}
    $common=@('--configuration','Release','--runtime','win-x64','--self-contained','true','--no-restore','--nologo','-p:VersionPrefix=0.2.0','-p:VersionSuffix=','-p:Version=0.2.0','-p:AssemblyVersion=0.2.0.0','-p:FileVersion=0.2.0.0','-p:InformationalVersion=0.2.0','-p:ContinuousIntegrationBuild=true','-p:Deterministic=true','-p:DebugType=None')
    $mergedRoots=@()
    foreach($pass in 1..2){
        $appOut=Join-Path $publishWorkRoot "app-$pass"; $coreOut=Join-Path $publishWorkRoot "core-$pass"
        foreach($spec in @([pscustomobject]@{Project=$appProject;Out=$appOut},[pscustomobject]@{Project=$coreProject;Out=$coreOut})){
            $publishOutput=@(& $dotnetCommand publish $spec.Project @common --output $spec.Out 2>&1); $publishExit=$LASTEXITCODE; $global:LASTEXITCODE=0
            if($publishExit -ne 0){throw "Deterministic publish failed for '$($spec.Project)' ($publishExit).`n$(($publishOutput|Select-Object -Last 20)-join "`n")"}
        }
        $merged=Join-Path $publishWorkRoot "merged-$pass"; Merge-V02PublishedTrees -SourceRoots @($appOut) -DestinationRoot $merged
        foreach($coreLeaf in @('HerdrOps.Core.exe','HerdrOps.Core.dll','HerdrOps.Core.deps.json','HerdrOps.Core.runtimeconfig.json')){
            $coreSource=Join-Path $coreOut $coreLeaf
            if(-not(Test-Path -LiteralPath $coreSource -PathType Leaf)){throw "Real Core publish is missing required output: $coreLeaf"}
            $null=Copy-V02StableFile $coreSource (Join-Path $merged $coreLeaf)
        }
        foreach($component in @($profile.components.appRelativePath,$profile.components.coreRelativePath)){if(-not(Test-Path -LiteralPath (Join-Path $merged ([string]$component)) -PathType Leaf)){throw "Merged real publish is missing exact component: $component"}}
        $mergedRoots += $merged
    }
    $firstInventory=Get-V02PackageRootInventory $mergedRoots[0]; $secondInventory=Get-V02PackageRootInventory $mergedRoots[1]
    Assert-V02InventoryEqual $firstInventory.Entries $secondInventory.Entries 'repeated deterministic App/Core publishes'
    foreach($lockPath in $lockPaths){if((Get-V02StableFileIdentity $lockPath).Sha256 -cne $lockHashes[$lockPath]){throw "Publish changed source lock file: $lockPath"}}
    $sourceAfter=Get-V02GitIdentity -RepositoryRoot $repositoryRoot -RequireClean
    if($sourceAfter.CommitSha -cne $sourceBefore.CommitSha -or $sourceAfter.TreeSha -cne $sourceBefore.TreeSha){throw 'Source changed during deterministic publish.'}

    $packageRoot=Join-Path $publishWorkRoot 'package'; Copy-SafeDirectoryContents $mergedRoots[0] $packageRoot
    $manifest=New-V02PackageManifestObject -Profile $profile -RepositoryRoot $repositoryRoot -PackageRoot $packageRoot
    Write-V02CanonicalJsonFile $manifest (Join-Path $packageRoot ([string]$profile.packageManifestFileName)) $repositoryRoot
    $archivePath=Join-Path $publishWorkRoot ([string]$profile.archiveFileName); $null=New-DeterministicPackageArchive $packageRoot $archivePath
    $receipt=Build-V02PackageIdentityReceiptObject $profile $repositoryRoot $profilePath $archivePath $packageRoot
    $receiptPath=Join-Path $publishWorkRoot 'identity.json'; Write-V02CanonicalJsonFile $receipt $receiptPath $repositoryRoot
    $receiptParsed=Read-V02CanonicalIdentityReceipt $receiptPath $repositoryRoot
    $null=Assert-V02PackageIdentity $receiptParsed.Identity $profile $repositoryRoot $archivePath $packageRoot $profilePath $receiptParsed.ReceiptSha256 $receiptParsed.CanonicalJson

    $parent=Split-Path $safeOutputRoot -Parent; if(-not(Test-Path -LiteralPath $parent -PathType Container)){New-Item -ItemType Directory $parent -Force|Out-Null}; Assert-V02PathNoReparse $parent
    $stagingOutput=Join-Path $parent ('.'+[IO.Path]::GetFileName($safeOutputRoot)+'.staging-'+[Guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $stagingOutput|Out-Null
    Copy-SafeDirectoryContents $packageRoot (Join-Path $stagingOutput 'package')
    $null=Copy-V02StableFile $archivePath (Join-Path $stagingOutput ([string]$profile.archiveFileName)); $null=Copy-V02StableFile $receiptPath (Join-Path $stagingOutput 'identity.json')
    $staged=Read-V02CanonicalIdentityReceipt (Join-Path $stagingOutput 'identity.json') $repositoryRoot
    $null=Assert-V02PackageIdentity $staged.Identity $profile $repositoryRoot (Join-Path $stagingOutput ([string]$profile.archiveFileName)) (Join-Path $stagingOutput 'package') $profilePath $staged.ReceiptSha256 $staged.CanonicalJson
    if($TestFaultInjectionStage -eq 'BeforeCommit'){throw 'Injected v0.2 packaging failure before commit.'}
    [IO.Directory]::Move($stagingOutput,$safeOutputRoot); $stagingOutput=$null; $committedOutput=$true
    $finalParsed=Read-V02CanonicalIdentityReceipt (Join-Path $safeOutputRoot 'identity.json') $repositoryRoot
    $final=Assert-V02PackageIdentity $finalParsed.Identity $profile $repositoryRoot (Join-Path $safeOutputRoot ([string]$profile.archiveFileName)) (Join-Path $safeOutputRoot 'package') $profilePath $finalParsed.ReceiptSha256 $finalParsed.CanonicalJson
    [pscustomobject][ordered]@{EvidenceClass='Static/PackagedCompatibilityPreparation';Issue=149;PackageVersion='0.2.0';RuntimeIdentifier='win-x64';OutputRoot=$safeOutputRoot;PackageRoot=(Join-Path $safeOutputRoot 'package');ArchivePath=(Join-Path $safeOutputRoot ([string]$profile.archiveFileName));IdentityPath=(Join-Path $safeOutputRoot 'identity.json');ReceiptSha256=$finalParsed.ReceiptSha256;ArchiveSha256=$final.ArchiveSha256;AppSha256=$final.AppSha256;CoreSha256=$final.CoreSha256;SourceCommit=$final.SourceCommit;SourceTree=$final.SourceTree;RepeatedPublishFileCount=$firstInventory.FileCount;RuntimeUse='not-used';RuntimeCredit='NOT CLAIMED';ReleaseCredit='NOT CLAIMED'}
} -Cleanup {
    if($null -ne $stagingOutput -and (Test-Path -LiteralPath $stagingOutput)){Remove-V02TransactionDirectory $stagingOutput (Split-Path $safeOutputRoot -Parent)}
    if($TestInjectCleanupFailure){if(Test-Path -LiteralPath $publishWorkRoot){Remove-PackagingTempDirectory $publishWorkRoot};throw 'Injected packaging cleanup failure.'}
    if(Test-Path -LiteralPath $publishWorkRoot){Remove-PackagingTempDirectory $publishWorkRoot}
    if(-not $committedOutput -and -not $outputRootExistedBefore -and (Test-Path -LiteralPath $safeOutputRoot) -and @(Get-ChildItem -LiteralPath $safeOutputRoot -Force).Count -eq 0){Remove-V02TransactionDirectory $safeOutputRoot (Split-Path $safeOutputRoot -Parent)}
}
$operationOutput
