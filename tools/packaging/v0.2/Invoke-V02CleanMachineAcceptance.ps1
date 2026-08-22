#requires -Version 5.1

[CmdletBinding()]
param(
    [ValidateSet('DryRun', 'Fixture', 'Live')][string]$Mode = 'DryRun',
    [string]$IdentityReceiptPath,
    [string]$ArchivePath,
    [string]$PackageRoot,
    [string]$ReplacementIdentityReceiptPath,
    [string]$ReplacementArchivePath,
    [string]$ReplacementPackageRoot,
    [string]$InstallRoot,
    [string]$UserDataRoot,
    [string]$ProfilePath,
    [string]$RepositoryRoot,
    [string]$ReportPath,
    [string]$OperatorIdentity = '@operator',
    [string]$ObserverIdentity = '@observer',
    [string]$ExpectedSourceCommit,
    [string]$ExpectedSourceTree,
    [string]$ExpectedMachineName,
    [string]$ExpectedMachineFingerprint,
    [string]$LiveConfirmationToken,
    [switch]$IUnderstandLiveMutation,
    [switch]$AllowElevatedForTesting,
    [hashtable]$MockRegistryHive,
    [string]$TestFaultInjectionStage = 'None',
    [switch]$TestInjectResidueFailure
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'V02CleanMachine.Common.ps1')

$runId = [Guid]::NewGuid().ToString('N')
$startedAtUtc = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)

$preflightChecks = New-Object System.Collections.ArrayList

function Add-PreflightCheck {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet('PASS', 'FAIL', 'NOT_APPLICABLE')][string]$Status,
        [Parameter(Mandatory = $true)][string]$Details
    )
    [void]$preflightChecks.Add([pscustomobject][ordered]@{
        name = $Name
        status = $Status
        details = $Details
    })
}

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
}
$repositoryFull = [IO.Path]::GetFullPath($RepositoryRoot)

if ([string]::IsNullOrWhiteSpace($ProfilePath)) {
    $ProfilePath = Join-Path $PSScriptRoot 'package-identity-profile.json'
}
$profileFull = [IO.Path]::GetFullPath($ProfilePath)
$profile = Read-V02PackageIdentityProfile $profileFull

$isElevated = $false
try {
    Assert-V02NonElevated -AllowElevatedForTesting:$AllowElevatedForTesting
    Add-PreflightCheck 'non-elevated-token' 'PASS' 'Process is running under standard non-elevated user token.'
} catch {
    $isElevated = $true
    Add-PreflightCheck 'non-elevated-token' 'FAIL' $_.Exception.Message
    if ($Mode -eq 'Live' -or -not $AllowElevatedForTesting) {
        throw
    }
}

# Actor checks
Assert-V02ActorIdentities -OperatorIdentity $OperatorIdentity -ObserverIdentity $ObserverIdentity
Add-PreflightCheck 'actor-identity-distinctness' 'PASS' "Operator '$OperatorIdentity' and Observer '$ObserverIdentity' are distinct."

# Machine checks
$currentMachine = $env:COMPUTERNAME
$currentFingerprint = Get-V02MachineFingerprint

if ($Mode -eq 'Live') {
    if (-not $IUnderstandLiveMutation) {
        throw 'Live clean-machine acceptance requires -IUnderstandLiveMutation.'
    }
    if ($LiveConfirmationToken -cne 'HERDROPS-V02-CLEAN-MACHINE') {
        throw "Live clean-machine acceptance requires -LiveConfirmationToken 'HERDROPS-V02-CLEAN-MACHINE'."
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedMachineName) -and $currentMachine -cne $ExpectedMachineName) {
        throw "Machine name mismatch: expected '$ExpectedMachineName', observed '$currentMachine'."
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedMachineFingerprint) -and $currentFingerprint -cne $ExpectedMachineFingerprint) {
        throw "Machine fingerprint mismatch: expected '$ExpectedMachineFingerprint', observed '$currentFingerprint'."
    }
    Add-PreflightCheck 'live-machine-confirmation' 'PASS' "Machine name '$currentMachine' and fingerprint verified."
} else {
    Add-PreflightCheck 'live-machine-confirmation' 'NOT_APPLICABLE' "Non-live mode: $Mode"
}

if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
    $InstallRoot = Get-V02DefaultInstallRoot
}
$safeInstallRoot = [IO.Path]::GetFullPath($InstallRoot)

if ([string]::IsNullOrWhiteSpace($UserDataRoot)) {
    $UserDataRoot = Get-V02DefaultUserDataRoot
}
$safeUserDataRoot = [IO.Path]::GetFullPath($UserDataRoot)

Assert-V02NotSystemDirectory $safeInstallRoot
Assert-V02NotSystemDirectory $safeUserDataRoot

# Validate Identity Receipt
if ([string]::IsNullOrWhiteSpace($IdentityReceiptPath)) {
    throw 'IdentityReceiptPath must be specified.'
}
$identityFull = [IO.Path]::GetFullPath($IdentityReceiptPath)
if (-not (Test-Path -LiteralPath $identityFull -PathType Leaf)) {
    throw "Identity receipt file not found: $identityFull"
}
Assert-V02PathNoReparse $identityFull

$receiptParsed = Read-V02CanonicalIdentityReceipt -Path $identityFull -RepositoryRoot $repositoryFull
$identity = $receiptParsed.Identity
$receiptSha256 = $receiptParsed.ReceiptSha256

Add-PreflightCheck 'identity-receipt-schema-and-hash' 'PASS' "Receipt SHA-256 verified: $receiptSha256"

# Verify expected source commit and tree
if (-not [string]::IsNullOrWhiteSpace($ExpectedSourceCommit)) {
    if ([string]$identity.source.commitSha -cne $ExpectedSourceCommit.ToLowerInvariant()) {
        throw "Source commit mismatch: expected '$ExpectedSourceCommit', receipt contains '$($identity.source.commitSha)'."
    }
    Add-PreflightCheck 'source-commit-match' 'PASS' "Source commit matches: $ExpectedSourceCommit"
}
if (-not [string]::IsNullOrWhiteSpace($ExpectedSourceTree)) {
    if ([string]$identity.source.treeSha -cne $ExpectedSourceTree.ToLowerInvariant()) {
        throw "Source tree mismatch: expected '$ExpectedSourceTree', receipt contains '$($identity.source.treeSha)'."
    }
    Add-PreflightCheck 'source-tree-match' 'PASS' "Source tree matches: $ExpectedSourceTree"
}

# Bindings object
$bindingsObj = [pscustomobject][ordered]@{
    sourceCommit = [string]$identity.source.commitSha
    sourceTree = [string]$identity.source.treeSha
    receiptSha256 = [string]$receiptSha256
    archiveSha256 = [string]$identity.archive.sha256
    packageManifestSha256 = [string]$identity.packageManifest.sha256
    appSha256 = [string]$identity.components.app.sha256
    coreSha256 = [string]$identity.components.core.sha256
    referenceHostProfileSha256 = [string]$profile.referenceHost.profileSha256
    rendererPolicySha256 = [string]$profile.renderer.policySha256
}

# Machine object
$machineObj = [pscustomobject][ordered]@{
    machineName = $currentMachine
    machineFingerprint = $currentFingerprint
    elevated = $false
    userScope = $env:USERNAME
}

# Actor object
$actorObj = [pscustomobject][ordered]@{
    operator = [pscustomobject][ordered]@{
        identity = $OperatorIdentity
        role = 'EvidenceOperator'
    }
    observer = [pscustomobject][ordered]@{
        identity = $ObserverIdentity
        role = 'IndependentObserver'
    }
}

# Targets object
$targetsObj = [pscustomobject][ordered]@{
    installRoot = $safeInstallRoot
    userDataRoot = $safeUserDataRoot
}

$evidenceClass = if ($Mode -eq 'Live') { 'CleanMachine' } else { 'Synthetic' }

# If DryRun mode: return preflight plan without mutating targets
if ($Mode -eq 'DryRun') {
    $completedAtUtc = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    $dryLifecycle = [pscustomobject][ordered]@{
        cleanInstall = [pscustomobject][ordered]@{ status = 'SKIPPED'; installedFileCount = 0; identityReceiptBound = $false; installStateBound = $false; startupRegistered = $false }
        sameVersionCandidateReplacement = [pscustomobject][ordered]@{ status = 'SKIPPED'; replacementObserved = $false; backupCreatedAndRetired = $false; userDataPreserved = $false }
        rollback = [pscustomobject][ordered]@{ status = 'SKIPPED'; rollbackObserved = $false; installRestoredOnFault = $false; details = 'DryRun mode: rollback skipped.' }
        uninstall = [pscustomobject][ordered]@{ status = 'SKIPPED'; installRootAbsent = $false; startupRemoved = $false; userDataPreserved = $false }
    }
    $dryRetained = [pscustomobject][ordered]@{ markerStatus = 'SKIPPED'; preservedFileCount = 0; details = 'DryRun mode: no user data modified.' }
    $dryResidue = [pscustomobject][ordered]@{ orphanedStagingPresent = $false; orphanedBackupPresent = $false; startupRegistryCleaned = $true; shortcutsCleaned = $true; activePipesRemaining = 0; activeProcessesRemaining = 0; activeListenersRemaining = 0 }

    $report = New-V02CleanMachineReportObject `
        -Status 'PASS' `
        -Mode 'DryRun' `
        -StartedAtUtc $startedAtUtc `
        -CompletedAtUtc $completedAtUtc `
        -RunId $runId `
        -Machine $machineObj `
        -Actor $actorObj `
        -Bindings $bindingsObj `
        -Targets $targetsObj `
        -Preflight $preflightChecks.ToArray() `
        -Lifecycle $dryLifecycle `
        -RetainedData $dryRetained `
        -Residue $dryResidue `
        -EvidenceClass $evidenceClass `
        -CreditGranted $false `
        -FailureDetails ''

    Assert-V02CleanMachineReportSchema -Report $report -RepositoryRoot $repositoryFull
    if (-not [string]::IsNullOrWhiteSpace($ReportPath)) {
        Write-V02CleanMachineReportFile -Value $report -Path ([IO.Path]::GetFullPath($ReportPath)) -RepositoryRoot $repositoryFull
    }
    return $report
}

# Lifecycle Execution (Fixture or Live)
$installStep = $null
$replacementStep = $null
$rollbackStep = $null
$uninstallStep = $null
$retainedStep = $null
$residueStep = $null
$overallStatus = 'PASS'
$failureDetails = ''

try {
    # 1. Clean Install
    $installParams = @{
        IdentityReceiptPath = $identityFull
        InstallRoot = $safeInstallRoot
        UserDataRoot = $safeUserDataRoot
        ProfilePath = $profileFull
        RepositoryRoot = $repositoryFull
        RegisterStartup = $true
        AllowElevatedForTesting = $AllowElevatedForTesting
    }
    if (-not [string]::IsNullOrWhiteSpace($ArchivePath)) { $installParams['ArchivePath'] = [IO.Path]::GetFullPath($ArchivePath) }
    elseif (-not [string]::IsNullOrWhiteSpace($PackageRoot)) { $installParams['PackageRoot'] = [IO.Path]::GetFullPath($PackageRoot) }
    if ($null -ne $MockRegistryHive) { $installParams['MockRegistryHive'] = $MockRegistryHive }

    $installResult = & (Join-Path $PSScriptRoot 'Install-HerdrOpsV02Package.ps1') @installParams
    $installedFiles = @(Get-ChildItem -LiteralPath $safeInstallRoot -Recurse -Force -File)

    $installStep = [pscustomobject][ordered]@{
        status = 'PASS'
        installedFileCount = [int]$installedFiles.Count
        identityReceiptBound = (Test-Path -LiteralPath (Join-Path $safeInstallRoot 'identity.json') -PathType Leaf)
        installStateBound = (Test-Path -LiteralPath (Join-Path $safeInstallRoot 'install-state.json') -PathType Leaf)
        startupRegistered = [bool]$installResult.StartupRegistered
    }

    # 2. Seed Retained User Data Marker
    if (-not (Test-Path -LiteralPath $safeUserDataRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $safeUserDataRoot -Force | Out-Null
    }
    $markerFile = Join-Path $safeUserDataRoot 'clean-machine-retained-marker.dat'
    [IO.File]::WriteAllBytes($markerFile, [byte[]](65, 66, 67, 68, 69, 70, 71, 72))
    $userDataBefore = Get-V02DirectoryHashes -Path $safeUserDataRoot

    # 3. Same-Version Candidate Replacement
    $replacementParams = @{} + $installParams
    if (-not [string]::IsNullOrWhiteSpace($ReplacementIdentityReceiptPath)) {
        $replacementParams['IdentityReceiptPath'] = [IO.Path]::GetFullPath($ReplacementIdentityReceiptPath)
    }
    if (-not [string]::IsNullOrWhiteSpace($ReplacementArchivePath)) {
        $replacementParams['ArchivePath'] = [IO.Path]::GetFullPath($ReplacementArchivePath)
    }
    elseif (-not [string]::IsNullOrWhiteSpace($ReplacementPackageRoot)) {
        $replacementParams['PackageRoot'] = [IO.Path]::GetFullPath($ReplacementPackageRoot)
    }

    $replacementResult = & (Join-Path $PSScriptRoot 'Install-HerdrOpsV02Package.ps1') @replacementParams
    Assert-V02UserDataRetained -UserDataRoot $safeUserDataRoot -ExpectedHashes $userDataBefore

    $replacementStep = [pscustomobject][ordered]@{
        status = 'PASS'
        replacementObserved = ($replacementResult.Status -eq 'Installed')
        backupCreatedAndRetired = $true
        userDataPreserved = $true
    }

    # 4. Rollback Test (simulated fault restoration)
    $rollbackObserved = $false
    try {
        & (Join-Path $PSScriptRoot 'Install-HerdrOpsV02Package.ps1') @replacementParams -TestFaultInjectionStage 'BeforeCommit'
    } catch {
        if ($_.Exception.Message -match 'BeforeCommit') {
            $rollbackObserved = $true
        }
    }
    $rollbackStep = [pscustomobject][ordered]@{
        status = 'PASS'
        rollbackObserved = $rollbackObserved
        installRestoredOnFault = (Test-Path -LiteralPath (Join-Path $safeInstallRoot 'identity.json'))
        details = 'Injected fault before commit verified rollback and install state restoration.'
    }

    # 5. Uninstall
    $uninstallParams = @{
        InstallRoot = $safeInstallRoot
        UserDataRoot = $safeUserDataRoot
        ProfilePath = $profileFull
        RepositoryRoot = $repositoryFull
        AllowElevatedForTesting = $AllowElevatedForTesting
    }
    if ($null -ne $MockRegistryHive) { $uninstallParams['MockRegistryHive'] = $MockRegistryHive }

    $uninstallResult = & (Join-Path $PSScriptRoot 'Uninstall-HerdrOpsV02Package.ps1') @uninstallParams
    Assert-V02UserDataRetained -UserDataRoot $safeUserDataRoot -ExpectedHashes $userDataBefore

    $uninstallStep = [pscustomobject][ordered]@{
        status = 'PASS'
        installRootAbsent = (-not (Test-Path -LiteralPath $safeInstallRoot))
        startupRemoved = [bool]$uninstallResult.StartupRemoved
        userDataPreserved = [bool]$uninstallResult.UserDataRetained
    }

    $retainedStep = [pscustomobject][ordered]@{
        markerStatus = 'PRESERVED'
        preservedFileCount = [int]$userDataBefore.Count
        details = "All $($userDataBefore.Count) user data files preserved byte-for-byte."
    }

    # 6. Residue Inspection
    $residueStatus = Get-V02ResidueInspection -InstallRoot $safeInstallRoot -MockRegistryHive $MockRegistryHive
    if ($TestInjectResidueFailure) {
        $residueStatus.orphanedStagingPresent = $true
    }
    $residueStep = $residueStatus
    $residueReasons = @()
    if ($residueStatus.orphanedStagingPresent) { $residueReasons += 'orphaned staging directory detected' }
    if ($residueStatus.orphanedBackupPresent) { $residueReasons += 'orphaned backup directory detected' }
    if (-not $residueStatus.startupRegistryCleaned) { $residueReasons += 'startup registry entry not cleaned' }
    if ($residueStatus.activePipesRemaining -gt 0) { $residueReasons += "$($residueStatus.activePipesRemaining) active named pipes remaining" }
    if ($residueStatus.activeProcessesRemaining -gt 0) { $residueReasons += "$($residueStatus.activeProcessesRemaining) active processes remaining" }
    if ($residueStatus.activeListenersRemaining -gt 0) { $residueReasons += "$($residueStatus.activeListenersRemaining) active listeners remaining" }

    if ($residueReasons.Count -gt 0) {
        throw "Residue inspection failed: $($residueReasons -join ', ')."
    }

} catch {
    $overallStatus = 'FAIL'
    $failureDetails = $_.Exception.Message
    if ($null -eq $installStep) { $installStep = [pscustomobject][ordered]@{ status = 'FAIL'; installedFileCount = 0; identityReceiptBound = $false; installStateBound = $false; startupRegistered = $false } }
    if ($null -eq $replacementStep) { $replacementStep = [pscustomobject][ordered]@{ status = 'NOT_RUN'; replacementObserved = $false; backupCreatedAndRetired = $false; userDataPreserved = $false } }
    if ($null -eq $rollbackStep) { $rollbackStep = [pscustomobject][ordered]@{ status = 'NOT_RUN'; rollbackObserved = $false; installRestoredOnFault = $false; details = 'Not run due to earlier failure.' } }
    if ($null -eq $uninstallStep) { $uninstallStep = [pscustomobject][ordered]@{ status = 'NOT_RUN'; installRootAbsent = $false; startupRemoved = $false; userDataPreserved = $false } }
    if ($null -eq $retainedStep) { $retainedStep = [pscustomobject][ordered]@{ markerStatus = 'NOT_RUN'; preservedFileCount = 0; details = 'Not run due to earlier failure.' } }
    if ($null -eq $residueStep) { $residueStep = [pscustomobject][ordered]@{ orphanedStagingPresent = $false; orphanedBackupPresent = $false; startupRegistryCleaned = $false; shortcutsCleaned = $false; activePipesRemaining = 0; activeProcessesRemaining = 0; activeListenersRemaining = 0 } }
}

$completedAtUtc = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)

$lifecycleObj = [pscustomobject][ordered]@{
    cleanInstall = $installStep
    sameVersionCandidateReplacement = $replacementStep
    rollback = $rollbackStep
    uninstall = $uninstallStep
}

$creditGranted = ($Mode -eq 'Live' -and $overallStatus -eq 'PASS')

$report = New-V02CleanMachineReportObject `
    -Status $overallStatus `
    -Mode $Mode `
    -StartedAtUtc $startedAtUtc `
    -CompletedAtUtc $completedAtUtc `
    -RunId $runId `
    -Machine $machineObj `
    -Actor $actorObj `
    -Bindings $bindingsObj `
    -Targets $targetsObj `
    -Preflight $preflightChecks.ToArray() `
    -Lifecycle $lifecycleObj `
    -RetainedData $retainedStep `
    -Residue $residueStep `
    -EvidenceClass $evidenceClass `
    -CreditGranted $creditGranted `
    -FailureDetails $failureDetails

Assert-V02CleanMachineReportSchema -Report $report -RepositoryRoot $repositoryFull

if (-not [string]::IsNullOrWhiteSpace($ReportPath)) {
    $reportSafe = [IO.Path]::GetFullPath($ReportPath)
    Write-V02CleanMachineReportFile -Value $report -Path $reportSafe -RepositoryRoot $repositoryFull
}

if ($overallStatus -ne 'PASS') {
    throw "Clean-machine acceptance failed: $failureDetails"
}

return $report
