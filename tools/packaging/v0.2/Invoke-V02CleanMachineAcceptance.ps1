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
    [string]$ExpectedReplacementSourceCommit,
    [string]$ExpectedReplacementSourceTree,
    [string]$ExpectedMachineName,
    [string]$ExpectedMachineFingerprint,
    [string]$FixtureRoot,
    [string]$CleanHostAuthorizationPath,
    [string]$CleanHostAuthorizationSignaturePath,
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
$currentMachine = [Environment]::MachineName
$currentFingerprint = Get-V02MachineFingerprint
$principalSid = Get-V02ExecutingPrincipalSid

if ($Mode -eq 'Live') {
    if (-not $IUnderstandLiveMutation) {
        throw 'Live clean-machine acceptance requires -IUnderstandLiveMutation.'
    }
    if ($LiveConfirmationToken -cne 'HERDROPS-V02-CLEAN-MACHINE') {
        throw "Live clean-machine acceptance requires -LiveConfirmationToken 'HERDROPS-V02-CLEAN-MACHINE'."
    }
    if ([string]::IsNullOrWhiteSpace($ExpectedMachineName) -or [string]::IsNullOrWhiteSpace($ExpectedMachineFingerprint)) {
        throw 'Live clean-machine acceptance requires explicit ExpectedMachineName and ExpectedMachineFingerprint bindings.'
    }
    if ($currentMachine -cne $ExpectedMachineName) {
        throw "Machine name mismatch: expected '$ExpectedMachineName', observed '$currentMachine'."
    }
    if ($currentFingerprint -cne $ExpectedMachineFingerprint) {
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

if ($Mode -eq 'Fixture') {
    if ([string]::IsNullOrWhiteSpace($FixtureRoot) -or $null -eq $MockRegistryHive) {
        throw 'Fixture mode requires an explicit FixtureRoot and MockRegistryHive before any lifecycle operation.'
    }
    $fixtureFull = [IO.Path]::GetFullPath($FixtureRoot)
    $tempFull = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
    if (-not $fixtureFull.StartsWith($tempFull + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) {
        throw 'FixtureRoot must be an isolated child of the OS temporary directory.'
    }
    Assert-V02PathWithinRoot $safeInstallRoot $fixtureFull 'Fixture InstallRoot' | Out-Null
    Assert-V02PathWithinRoot $safeUserDataRoot $fixtureFull 'Fixture UserDataRoot' | Out-Null
}
if ($Mode -eq 'Live') {
    if ($null -ne $MockRegistryHive -or $AllowElevatedForTesting -or $TestFaultInjectionStage -cne 'None' -or $TestInjectResidueFailure) {
        throw 'Live mode rejects mock registry and all test-only controls.'
    }
    $defaultInstall = [IO.Path]::GetFullPath((Get-V02DefaultInstallRoot))
    $defaultUserData = [IO.Path]::GetFullPath((Get-V02DefaultUserDataRoot))
    if (-not [StringComparer]::OrdinalIgnoreCase.Equals($safeInstallRoot,$defaultInstall) -or -not [StringComparer]::OrdinalIgnoreCase.Equals($safeUserDataRoot,$defaultUserData)) {
        throw 'Live mode requires the exact per-user HerdrOps install and user-data roots; test/custom roots are forbidden.'
    }
    foreach ($externalPath in @($CleanHostAuthorizationPath,$CleanHostAuthorizationSignaturePath)) {
        if (-not [string]::IsNullOrWhiteSpace($externalPath)) {
            Assert-V02PathOutsideRoot $externalPath $repositoryFull 'Clean-host authorization'
            Assert-V02PathOutsideRoot $externalPath $safeInstallRoot 'Clean-host authorization'
            Assert-V02PathOutsideRoot $externalPath $safeUserDataRoot 'Clean-host authorization'
            if (-not [string]::IsNullOrWhiteSpace($ReportPath)) {
                Assert-V02PathOutsideRoot $externalPath ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($ReportPath))) 'Clean-host authorization'
            }
        }
    }
}

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

if ($Mode -ne 'DryRun') {
    foreach ($requiredValue in @($ExpectedSourceCommit,$ExpectedSourceTree,$ExpectedReplacementSourceCommit,$ExpectedReplacementSourceTree,$ReplacementIdentityReceiptPath)) {
        if ([string]::IsNullOrWhiteSpace([string]$requiredValue)) { throw 'Fixture/Live lifecycle requires exact initial and replacement source/tree/receipt bindings.' }
    }
}

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

$replacementParsed = $null
$replacementIdentity = $null
if ($Mode -ne 'DryRun') {
    $replacementReceiptFull = [IO.Path]::GetFullPath($ReplacementIdentityReceiptPath)
    Assert-V02PathNoReparse $replacementReceiptFull
    $replacementParsed = Read-V02CanonicalIdentityReceipt -Path $replacementReceiptFull -RepositoryRoot $repositoryFull
    $replacementIdentity = $replacementParsed.Identity
    if ([string]$replacementIdentity.packageVersion -cne '0.2.0') { throw 'Replacement must be SameVersionCandidateReplacement for v0.2.0.' }
    if ([string]$replacementIdentity.source.commitSha -cne $ExpectedReplacementSourceCommit.ToLowerInvariant() -or [string]$replacementIdentity.source.treeSha -cne $ExpectedReplacementSourceTree.ToLowerInvariant()) {
        throw 'Replacement source commit/tree does not equal the exact expected final candidate.'
    }
    if ($replacementParsed.ReceiptSha256 -ceq $receiptSha256) { throw 'SameVersionCandidateReplacement requires a distinct final candidate receipt.' }
}

# Bindings object
$initialBinding = [pscustomobject][ordered]@{ sourceCommit=[string]$identity.source.commitSha;sourceTree=[string]$identity.source.treeSha;receiptSha256=[string]$receiptSha256;archiveSha256=[string]$identity.archive.sha256;packageManifestSha256=[string]$identity.packageManifest.sha256;appSha256=[string]$identity.components.app.sha256;coreSha256=[string]$identity.components.core.sha256 }
$finalBinding = if ($null -ne $replacementIdentity) { [pscustomobject][ordered]@{ sourceCommit=[string]$replacementIdentity.source.commitSha;sourceTree=[string]$replacementIdentity.source.treeSha;receiptSha256=[string]$replacementParsed.ReceiptSha256;archiveSha256=[string]$replacementIdentity.archive.sha256;packageManifestSha256=[string]$replacementIdentity.packageManifest.sha256;appSha256=[string]$replacementIdentity.components.app.sha256;coreSha256=[string]$replacementIdentity.components.core.sha256 } } else { $initialBinding }
$bindingsObj = [pscustomobject][ordered]@{ initial=$initialBinding;final=$finalBinding;referenceHostProfileSha256=[string]$profile.referenceHost.profileSha256;rendererPolicySha256=[string]$profile.renderer.policySha256 }

# Machine object
$machineObj = [pscustomobject][ordered]@{
    machineName = $currentMachine
    machineFingerprint = $currentFingerprint
    elevated = [bool]$isElevated
    userScope = $principalSid
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
    authorization = [pscustomobject][ordered]@{
        status = 'NOT_APPLICABLE'
        signerThumbprint = ''
        authorizationSha256 = ''
        signatureSha256 = ''
        nonce = ''
    }
}

if ($Mode -eq 'Live') {
    if ([string]::IsNullOrWhiteSpace($CleanHostAuthorizationPath) -or [string]::IsNullOrWhiteSpace($CleanHostAuthorizationSignaturePath)) { throw 'Live mode requires detached externally signed clean-host authorization.' }
    $authorization = Read-V02CleanHostAuthorization -AuthorizationPath $CleanHostAuthorizationPath -SignaturePath $CleanHostAuthorizationSignaturePath -MachineName $currentMachine -MachineFingerprint $currentFingerprint -PrincipalSid $principalSid -InitialBinding $initialBinding -FinalBinding $finalBinding
    $actorObj.operator.identity = $principalSid
    $actorObj.observer.identity = [string]$authorization.Value.observerIdentity
    $actorObj.authorization.status = 'VERIFIED'
    $actorObj.authorization.signerThumbprint = [string]$authorization.SignerThumbprint
    $actorObj.authorization.authorizationSha256 = [string]$authorization.AuthorizationSha256
    $actorObj.authorization.signatureSha256 = [string]$authorization.SignatureSha256
    $actorObj.authorization.nonce = [string]$authorization.Value.nonce
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
    # A clean-install run starts with no owned installation, startup entry,
    # product process/pipe/listener, shortcut, or transaction sibling.
    if (Test-Path -LiteralPath $safeInstallRoot) { throw 'Clean-machine preflight requires the install root to be absent.' }
    $initialResidue = Get-V02ResidueInspection -InstallRoot $safeInstallRoot -MockRegistryHive $MockRegistryHive -FixtureIsolation:($Mode -eq 'Fixture')
    if (-not $initialResidue.startupRegistryCleaned -or -not $initialResidue.shortcutsCleaned -or $initialResidue.orphanedStagingPresent -or $initialResidue.orphanedBackupPresent -or $initialResidue.activePipesRemaining -ne 0 -or $initialResidue.activeProcessesRemaining -ne 0 -or $initialResidue.activeListenersRemaining -ne 0) { throw 'Clean-machine preflight detected existing HerdrOps state.' }
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
    $initialBindingWork = New-PackagingTempDirectory -Prefix 'HerdrOps-V02InitialBinding-'
    try { $observedInitial = Assert-V02CompleteInstalledBinding $safeInstallRoot $profile $profileFull $repositoryFull $initialBindingWork } finally { if (Test-Path -LiteralPath $initialBindingWork) { Remove-PackagingTempDirectory $initialBindingWork } }
    if ($installResult.ReceiptSha256 -cne $initialBinding.receiptSha256 -or $observedInitial.AppSha256 -cne $initialBinding.appSha256 -or $observedInitial.CoreSha256 -cne $initialBinding.coreSha256) { throw 'Clean install did not observe the exact initial candidate binding.' }

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
    $markerFile = Join-Path $safeUserDataRoot ("clean-machine-retained-$runId.dat")
    $markerStream=[IO.File]::Open($markerFile,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);try{$markerBytes=[byte[]](65,66,67,68,69,70,71,72);$markerStream.Write($markerBytes,0,$markerBytes.Length);$markerStream.Flush($true)}finally{$markerStream.Dispose()}
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
    $finalBindingWork = New-PackagingTempDirectory -Prefix 'HerdrOps-V02FinalBinding-'
    try { $observedFinal = Assert-V02CompleteInstalledBinding $safeInstallRoot $profile $profileFull $repositoryFull $finalBindingWork } finally { if (Test-Path -LiteralPath $finalBindingWork) { Remove-PackagingTempDirectory $finalBindingWork } }

    $replacementObserved = ($replacementResult.Status -eq 'Installed' -and $replacementResult.ReceiptSha256 -ceq $finalBinding.receiptSha256 -and $observedFinal.AppSha256 -ceq $finalBinding.appSha256 -and $observedFinal.CoreSha256 -ceq $finalBinding.coreSha256)
    $backupRetired = (@(Get-ChildItem -LiteralPath (Split-Path $safeInstallRoot -Parent) -Directory -Force | Where-Object { $_.Name -match ('^\.'+[regex]::Escape([IO.Path]::GetFileName($safeInstallRoot))+'\.backup-[0-9a-f]{32}$') }).Count -eq 0)
    if (-not $replacementObserved -or -not $backupRetired) { throw 'SameVersionCandidateReplacement was not exactly observed and retired.' }
    $replacementStep = [pscustomobject][ordered]@{
        status = 'PASS'
        replacementObserved = $replacementObserved
        backupCreatedAndRetired = $backupRetired
        userDataPreserved = $true
    }

    # 4. Rollback Test (simulated fault restoration)
    $rollbackObserved = $false
    try {
        & (Join-Path $PSScriptRoot 'Install-HerdrOpsV02Package.ps1') @replacementParams -TestFaultInjectionStage 'BeforeCommit'
    } catch {
        if ($_.Exception.Message -ceq 'Injected install failure before atomic directory commit.') {
            $rollbackObserved = $true
        }
    }
    if (-not $rollbackObserved) { throw 'Rollback fault did not reach the production BeforeCommit guard.' }
    $rollbackBindingWork = New-PackagingTempDirectory -Prefix 'HerdrOps-V02RollbackBinding-'
    try { $observedRollback = Assert-V02CompleteInstalledBinding $safeInstallRoot $profile $profileFull $repositoryFull $rollbackBindingWork } finally { if (Test-Path -LiteralPath $rollbackBindingWork) { Remove-PackagingTempDirectory $rollbackBindingWork } }
    $installRestoredOnFault = ($observedRollback.AppSha256 -ceq $finalBinding.appSha256 -and $observedRollback.CoreSha256 -ceq $finalBinding.coreSha256)
    if (-not $installRestoredOnFault) { throw 'Rollback did not preserve the exact final installed candidate.' }
    $rollbackStep = [pscustomobject][ordered]@{
        status = 'PASS'
        rollbackObserved = $rollbackObserved
        installRestoredOnFault = $installRestoredOnFault
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
    if (-not $uninstallStep.installRootAbsent -or -not $uninstallStep.startupRemoved -or -not $uninstallStep.userDataPreserved) { throw 'Uninstall did not satisfy all observed retirement conditions.' }

    $retainedStep = [pscustomobject][ordered]@{
        markerStatus = 'PRESERVED'
        preservedFileCount = [int]$userDataBefore.Count
        details = "All $($userDataBefore.Count) user data files preserved byte-for-byte."
    }

    # 6. Residue Inspection
    $residueStatus = Get-V02ResidueInspection -InstallRoot $safeInstallRoot -MockRegistryHive $MockRegistryHive -FixtureIsolation:($Mode -eq 'Fixture')
    if ($TestInjectResidueFailure) {
        $residueStatus.orphanedStagingPresent = $true
    }
    $residueStep = $residueStatus
    $residueReasons = @()
    if ($residueStatus.orphanedStagingPresent) { $residueReasons += 'orphaned staging directory detected' }
    if ($residueStatus.orphanedBackupPresent) { $residueReasons += 'orphaned backup directory detected' }
    if (-not $residueStatus.startupRegistryCleaned) { $residueReasons += 'startup registry entry not cleaned' }
    if (-not $residueStatus.shortcutsCleaned) { $residueReasons += 'shortcut residue detected' }
    if ($residueStatus.activePipesRemaining -gt 0) { $residueReasons += "$($residueStatus.activePipesRemaining) active named pipes remaining" }
    if ($residueStatus.activeProcessesRemaining -gt 0) { $residueReasons += "$($residueStatus.activeProcessesRemaining) active processes remaining" }
    if ($residueStatus.activeListenersRemaining -gt 0) { $residueReasons += "$($residueStatus.activeListenersRemaining) active listeners remaining" }

    if ($residueReasons.Count -gt 0) {
        throw "Residue inspection failed: $($residueReasons -join ', ')."
    }

} catch {
    $overallStatus = 'FAIL'
    $failureDetails = $_.Exception.Message
    # The recorder owns any install created during this run.  A failed
    # acceptance must retire that owned install and startup entry before it can
    # emit evidence; it never deletes an unbound/pre-existing target because
    # the clean preflight rejected one before lifecycle work began.
    try {
        if (Test-Path -LiteralPath $safeInstallRoot) {
            $failureUninstallParams = @{
                InstallRoot = $safeInstallRoot
                UserDataRoot = $safeUserDataRoot
                ProfilePath = $profileFull
                RepositoryRoot = $repositoryFull
                AllowElevatedForTesting = $AllowElevatedForTesting
            }
            if ($null -ne $MockRegistryHive) { $failureUninstallParams.MockRegistryHive = $MockRegistryHive }
            $failureUninstall = & (Join-Path $PSScriptRoot 'Uninstall-HerdrOpsV02Package.ps1') @failureUninstallParams
            if ($null -eq $uninstallStep) {
                $uninstallStep = [pscustomobject][ordered]@{
                    status = 'PASS'
                    installRootAbsent = (-not (Test-Path -LiteralPath $safeInstallRoot))
                    startupRemoved = [bool]$failureUninstall.StartupRemoved
                    userDataPreserved = [bool]$failureUninstall.UserDataRetained
                }
            }
        } elseif ($null -ne $MockRegistryHive) {
            Unregister-V02UserStartup -MockRegistryHive $MockRegistryHive
        }
    } catch {
        $failureDetails += " | Failure cleanup did not complete: $($_.Exception.Message)"
    }
    if ($null -eq $installStep) { $installStep = [pscustomobject][ordered]@{ status = 'FAIL'; installedFileCount = 0; identityReceiptBound = $false; installStateBound = $false; startupRegistered = $false } }
    if ($null -eq $replacementStep) { $replacementStep = [pscustomobject][ordered]@{ status = 'NOT_RUN'; replacementObserved = $false; backupCreatedAndRetired = $false; userDataPreserved = $false } }
    if ($null -eq $rollbackStep) { $rollbackStep = [pscustomobject][ordered]@{ status = 'NOT_RUN'; rollbackObserved = $false; installRestoredOnFault = $false; details = 'Not run due to earlier failure.' } }
    if ($null -eq $uninstallStep) { $uninstallStep = [pscustomobject][ordered]@{ status = 'NOT_RUN'; installRootAbsent = $false; startupRemoved = $false; userDataPreserved = $false } }
    if ($null -eq $retainedStep) { $retainedStep = [pscustomobject][ordered]@{ markerStatus = 'NOT_RUN'; preservedFileCount = 0; details = 'Not run due to earlier failure.' } }
    if ($null -eq $residueStep) {
        try {
            $residueStep = Get-V02ResidueInspection -InstallRoot $safeInstallRoot -MockRegistryHive $MockRegistryHive -FixtureIsolation:($Mode -eq 'Fixture')
        } catch {
            $failureDetails += " | Post-failure residue inspection failed closed: $($_.Exception.Message)"
            $residueStep = [pscustomobject][ordered]@{ orphanedStagingPresent = $true; orphanedBackupPresent = $true; startupRegistryCleaned = $false; shortcutsCleaned = $false; activePipesRemaining = 1; activeProcessesRemaining = 1; activeListenersRemaining = 1 }
        }
    }
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
