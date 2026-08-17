#requires -Version 5.1

[CmdletBinding()]
param(
    [ValidateSet('DryRun', 'Fixture', 'Live')][string]$Mode = 'DryRun',
    [string]$BindingPath,
    [string]$InitialPackageRoot,
    [string]$UpgradePackageRoot,
    [string]$InitialArchivePath,
    [string]$UpgradeArchivePath,
    [string]$InitialHashRecordPath,
    [string]$UpgradeHashRecordPath,
    [string]$FixtureRoot,
    [string]$ReportPath,
    [switch]$KeepSimulationRoot,
    [switch]$IUnderstandLiveMutation,
    [string]$LiveConfirmationToken,
    [string]$ExpectedMachineName,
    [string]$ExpectedMachineFingerprint,
    [string]$ExpectedSourceCommit,
    [string]$ExpectedInitialArtifactSha256,
    [string]$ExpectedUpgradeArtifactSha256,
    [switch]$AllowLiveRetainedDataSeed,
    [ValidateSet('None', 'BeforeCleanInstallCommit', 'BeforeUpgradeCommit', 'AfterUpgradeBackup', 'BeforeRollbackCommit', 'AfterRollbackBackup', 'BeforeUninstallCommit')][string]$TestCancelPoint = 'None',
    [ValidateSet('None', 'CleanInstall', 'Upgrade', 'Rollback', 'Uninstall')][string]$TestCancelAfter = 'None',
    [ValidateSet('None', 'AfterCleanInstallTransition', 'AfterUpgradeTransition', 'AfterRollbackTransition', 'AfterUninstallTransition')][string]$TestFailurePoint = 'None'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'HerdrOps.InstallAcceptance.Common.ps1')

$script:AcceptanceIssue = 44
$script:AcceptanceVersion = 'v1.0.0'
$script:LiveToken = 'HERDROPS-ISSUE-44-LIVE-FILESYSTEM'
$script:Transcript = New-Object System.Collections.ArrayList
$script:PreflightChecks = New-Object System.Collections.ArrayList
$script:RunId = [Guid]::NewGuid().ToString('N')
$script:StartedAtUtc = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
$script:SimulationRoot = $null
$script:ReportDestination = $null
$script:HarnessSeededDataMarker = $false
$script:HarnessDataMarkerPath = $null
$script:OwnedTransientPaths = New-Object System.Collections.ArrayList
$script:CurrentLifecyclePhase = 'Preflight'
$script:CleanMachineFilesystemObserved = $false

function Get-AcceptanceUtcNow {
    return [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
}

function Add-AcceptanceTranscript {
    param(
        [Parameter(Mandatory = $true)][string]$Phase,
        [Parameter(Mandatory = $true)][string]$Action,
        [Parameter(Mandatory = $true)][ValidateSet('PASS', 'FAIL', 'SKIPPED', 'CANCELLED', 'NOT_RUN')][string]$Status,
        [Parameter(Mandatory = $true)][ValidateSet('None', 'FixtureTempOnly', 'LiveFilesystem')][string]$Effect,
        [Parameter(Mandatory = $true)][string]$Details,
        [string]$PathBinding = ''
    )

    [void]$script:Transcript.Add([ordered]@{
            sequence = $script:Transcript.Count + 1
            phase = $Phase
            action = $Action
            status = $Status
            effect = $Effect
            details = $Details
            pathBinding = $PathBinding
        })
}

function Get-AcceptanceObservedEffect {
    if ($Mode -eq 'Fixture') { return 'FixtureTempOnly' }
    if ($Mode -eq 'Live' -and $script:CleanMachineFilesystemObserved) { return 'LiveFilesystem' }
    return 'None'
}

function Add-AcceptancePreflightCheck {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet('PASS', 'FAIL', 'NOT_APPLICABLE')][string]$Status,
        [Parameter(Mandatory = $true)][string]$Details
    )

    [void]$script:PreflightChecks.Add([ordered]@{
            name = $Name
            status = $Status
            details = $Details
        })
}

function New-AcceptanceLifecycleStep {
    param([Parameter(Mandatory = $true)][string]$ExpectedVersion)

    return [ordered]@{
        status = 'NOT_RUN'
        expectedVersion = $ExpectedVersion
        installedFileHashes = @()
        installRootPresent = $false
        packageVersionObserved = ''
        retainedDataStatus = 'NOT_RUN'
        retainedDataSha256 = ''
        details = ''
    }
}

function Convert-AcceptanceHashesForReport {
    param([Parameter(Mandatory = $true)]$Hashes)

    return @($Hashes | ForEach-Object {
            [ordered]@{
                path = [string]$_.Path
                length = [int64]$_.Length
                sha256 = [string]$_.Sha256
            }
        })
}

function New-AcceptanceReport {
    param(
        [Parameter(Mandatory = $true)][string]$Status,
        [Parameter(Mandatory = $true)][string]$EvidenceClass,
        [Parameter(Mandatory = $true)][string]$MachineName,
        [Parameter(Mandatory = $true)][string]$MachineFingerprint,
        [Parameter(Mandatory = $true)]$Artifacts,
        [Parameter(Mandatory = $true)]$Targets,
        [Parameter(Mandatory = $true)]$Lifecycle,
        [Parameter(Mandatory = $true)]$Cleanup,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$FailureDetails
    )

    $preflightPassed = ($script:PreflightChecks.Count -gt 0 -and
        @($script:PreflightChecks | Where-Object { $_.status -eq 'FAIL' }).Count -eq 0)
    $allLifecyclePassed = @(@('cleanInstall', 'upgrade', 'rollback', 'uninstall') | Where-Object {
            [string]$Lifecycle[$_].status -cne 'PASS'
        }).Count -eq 0
    $fixturePassed = ($Mode -eq 'Fixture' -and $Status -ceq 'PASS' -and $allLifecyclePassed -and [string]$Cleanup.status -ceq 'PASS')
    $cleanMachineObserved = ($EvidenceClass -ceq 'CleanMachine')
    $cleanMachinePassed = ($cleanMachineObserved -and $Status -ceq 'PASS' -and $allLifecyclePassed -and [string]$Cleanup.status -ceq 'PASS')

    return [ordered]@{
        schemaVersion = 1
        reportKind = 'HerdrOps.InstallAcceptanceReport'
        issue = $script:AcceptanceIssue
        acceptanceVersion = $script:AcceptanceVersion
        status = $Status
        mode = $Mode
        evidenceClass = $EvidenceClass
        startedAtUtc = $script:StartedAtUtc
        completedAtUtc = Get-AcceptanceUtcNow
        runId = $script:RunId
        machine = [ordered]@{
            name = $MachineName
            expectedName = $ExpectedMachineName
            fingerprint = $MachineFingerprint
            expectedFingerprint = $ExpectedMachineFingerprint
            elevated = (Test-AcceptanceIsElevated)
        }
        artifacts = $Artifacts
        targets = $Targets
        preflight = [ordered]@{
            status = if ($preflightPassed) { 'PASS' } else { 'FAIL' }
            checks = @($script:PreflightChecks.ToArray())
        }
        lifecycle = $Lifecycle
        cleanup = $Cleanup
        failureDetails = $FailureDetails
        transcript = @($script:Transcript.ToArray())
        boundaries = [ordered]@{
            static = if ($preflightPassed) { 'PASS: acceptance source, path, archive, and artifact contracts were checked.' } else { "OBSERVED $Status`: static preflight did not complete successfully." }
            synthetic = if ($fixturePassed) { 'PASS: fixture-only lifecycle transitions and retained-data assertions.' } elseif ($Mode -eq 'Fixture') { "OBSERVED $Status`: fixture lifecycle did not complete successfully." } else { 'NOT OBSERVED: no fixture lifecycle was executed.' }
            contract = 'NOT OBSERVED: no named-pipe or installed-Herdr compatibility work.'
            cleanMachine = if ($cleanMachinePassed) { 'PASS: bound clean-machine filesystem install, upgrade, rollback, uninstall, and retained-data lifecycle.' } elseif ($cleanMachineObserved) { "OBSERVED $Status`: bound clean-machine filesystem lifecycle did not complete successfully." } else { 'NOT OBSERVED: no validated clean-machine filesystem lifecycle effect was attempted.' }
            runtime = 'NOT OBSERVED: no Herdr runtime or application process was started.'
            independentReview = 'NOT OBSERVED.'
            release = 'NOT OBSERVED: no release or publication action was performed.'
        }
    }
}

function Get-ArtifactBindingShape {
    return @(
        'packageRoot', 'archivePath', 'hashRecordPath', 'productId', 'displayName',
        'packagingIssue', 'packageVersion', 'targetFramework', 'runtimeIdentifier',
        'deploymentModel', 'userDataPolicy', 'manifestSha256', 'archiveSha256',
        'contentSha256', 'sourceCommit')
}

function Assert-LiveBinding {
    param([Parameter(Mandatory = $true)][string]$Path)

    $binding = Read-AcceptanceJsonFile -Path $Path -Context 'Issue #44 live binding'
    Assert-AcceptanceExactProperties -Object $binding -Names @(
        'schemaVersion', 'issue', 'acceptanceVersion', 'mode', 'machineRole',
        'machineName', 'machineFingerprint', 'sourceCommit', 'initialArtifact',
        'upgradeArtifact', 'installRoot', 'userDataRoot', 'reportPath',
        'retainedDataRelativePath', 'retainedDataSha256', 'retainedDataMode') `
        -Context 'Issue #44 live binding'
    if ([int]$binding.schemaVersion -ne 1 -or
        [int]$binding.issue -ne $script:AcceptanceIssue -or
        [string]$binding.acceptanceVersion -cne $script:AcceptanceVersion -or
        [string]$binding.mode -cne 'Live' -or
        [string]$binding.machineRole -cne 'clean-windows-test-machine' -or
        [string]$binding.machineName -cne $ExpectedMachineName -or
        [string]$binding.machineFingerprint -cne $ExpectedMachineFingerprint) {
        throw 'Issue #44 live binding does not match the explicitly supplied machine identity.'
    }
    if ([string]$binding.machineName -cne [Environment]::MachineName) {
        throw "Live binding machine '$($binding.machineName)' does not match this machine '$([Environment]::MachineName)'."
    }
    if ([string]$binding.machineFingerprint -cne (Get-AcceptanceMachineFingerprint)) {
        throw 'Live binding machine fingerprint does not match this Windows host.'
    }
    foreach ($artifactName in @('initialArtifact', 'upgradeArtifact')) {
        $artifactBinding = Get-AcceptanceRequiredProperty -Object $binding -Name $artifactName -Context 'Issue #44 live binding'
        Assert-AcceptanceExactProperties -Object $artifactBinding -Names (Get-ArtifactBindingShape) -Context "$artifactName binding"
        if ([string]$artifactBinding.productId -cne 'HerdrOps' -or
            [string]$artifactBinding.displayName -cne 'HerdrOps' -or
            [string]$artifactBinding.targetFramework -cne 'net10.0-windows' -or
            [string]$artifactBinding.runtimeIdentifier -cne 'win-x64' -or
            [string]$artifactBinding.deploymentModel -cne 'per-user-directory' -or
            [string]$artifactBinding.userDataPolicy -cne 'retain-on-uninstall') {
            throw "$artifactName live binding has drifted from the packaging contract."
        }
        foreach ($hashName in @('manifestSha256', 'archiveSha256', 'contentSha256')) {
            Assert-AcceptanceSha256 -Value ([string]$artifactBinding.$hashName) -Context "$artifactName $hashName binding"
        }
        if ([string]$artifactBinding.sourceCommit -notmatch '^[0-9a-f]{40}$') {
            throw "$artifactName sourceCommit must be an exact 40-character lowercase commit binding."
        }
    }
    Assert-AcceptanceLiveSourceCommitBinding `
        -AcceptedSourceCommit ([string]$binding.sourceCommit) `
        -ExpectedSourceCommit ([string]$ExpectedSourceCommit) `
        -UpgradeArtifactSourceCommit ([string]$binding.upgradeArtifact.sourceCommit)
    Assert-PackageVersion -Version ([string]$binding.initialArtifact.packageVersion)
    Assert-PackageVersion -Version ([string]$binding.upgradeArtifact.packageVersion)
    if ([Version]$binding.upgradeArtifact.packageVersion -le [Version]$binding.initialArtifact.packageVersion) {
        throw 'The live upgrade artifact version must be greater than the initial artifact version.'
    }
    if ([string]$binding.upgradeArtifact.packageVersion -cne $script:AcceptanceVersion.Substring(1)) {
        throw 'The live upgrade artifact must match the v1.0.0 acceptance target version.'
    }
    $installRoot = Get-AcceptanceFullPath -Path ([string]$binding.installRoot)
    $userDataRoot = Get-AcceptanceFullPath -Path ([string]$binding.userDataRoot)
    $expectedInstallRoot = Get-AcceptanceFullPath -Path (Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'Programs\HerdrOps')
    $expectedUserDataRoot = Get-AcceptanceFullPath -Path (Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'HerdrOps')
    if (-not $installRoot.Equals($expectedInstallRoot, [StringComparison]::OrdinalIgnoreCase) -or
        -not $userDataRoot.Equals($expectedUserDataRoot, [StringComparison]::OrdinalIgnoreCase) -or
        $installRoot.Equals($userDataRoot, [StringComparison]::OrdinalIgnoreCase) -or
        (Test-PathWithin -ChildPath $installRoot -RootPath $userDataRoot) -or
        (Test-PathWithin -ChildPath $userDataRoot -RootPath $installRoot)) {
        throw 'Live targets must be the two distinct canonical per-user HerdrOps paths.'
    }
    $reportPath = Get-AcceptanceFullPath -Path ([string]$binding.reportPath)
    $retainedRelativePath = [string]$binding.retainedDataRelativePath
    $retainedDataPath = Resolve-AcceptanceSafeRelativeFilePath `
        -RootPath $userDataRoot `
        -RelativePath $retainedRelativePath `
        -Context 'Live retainedDataRelativePath'
    Assert-AcceptanceSha256 -Value ([string]$binding.retainedDataSha256) -Context 'live retainedDataSha256 binding'
    if ([string]$binding.retainedDataMode -notin @('preseeded', 'create-test-marker')) {
        throw "Unsupported live retainedDataMode: $($binding.retainedDataMode)"
    }

    return [pscustomobject][ordered]@{
        Binding = $binding
        InitialArtifact = $binding.initialArtifact
        UpgradeArtifact = $binding.upgradeArtifact
        InstallRoot = $installRoot
        UserDataRoot = $userDataRoot
        ReportPath = $reportPath
        RetainedDataPath = $retainedDataPath
        RetainedDataSha256 = [string]$binding.retainedDataSha256
        RetainedDataMode = [string]$binding.retainedDataMode
    }
}

function New-SyntheticVersionProfileForAcceptance {
    param(
        [Parameter(Mandatory = $true)]$BaseProfile,
        [Parameter(Mandatory = $true)][string]$Version
    )

    $clone = ($BaseProfile | ConvertTo-Json -Depth 20 | ConvertFrom-Json)
    $upgradeProperty = @($clone.PSObject.Properties | Where-Object { $_.Name -ceq 'syntheticUpgradeVersion' })
    if ($upgradeProperty.Count -eq 1) {
        $clone.PSObject.Properties.Remove('syntheticUpgradeVersion')
    }
    $clone.packageVersion = $Version
    Assert-PackageProfile -Profile $clone
    return $clone
}

function New-SyntheticAcceptanceArtifacts {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$FixturePath
    )

    $fixtureInitial = Join-Path $FixturePath 'initial'
    $fixtureUpgrade = Join-Path $FixturePath 'upgrade'
    foreach ($fixture in @($fixtureInitial, $fixtureUpgrade)) {
        if (-not (Test-Path -LiteralPath $fixture -PathType Container)) {
            throw "Acceptance fixture directory was not found: $fixture"
        }
        Assert-AcceptanceTreeNoReparse -Path $fixture -Context 'acceptance fixture'
    }
    $profile = Read-PackageProfile -Path (Join-Path $PSScriptRoot '..\packaging\package-profile.json')
    $upgradeProfile = New-SyntheticVersionProfileForAcceptance -BaseProfile $profile -Version ([string]$profile.syntheticUpgradeVersion)
    $definitions = @(
        [pscustomobject][ordered]@{ Name = 'initial'; Source = $fixtureInitial; Profile = $profile },
        [pscustomobject][ordered]@{ Name = 'upgrade'; Source = $fixtureUpgrade; Profile = $upgradeProfile })
    $result = [ordered]@{}
    foreach ($definition in $definitions) {
        $artifactWorkRoot = Join-Path $Root ("artifacts\$($definition.Name)")
        $packageRoot = Join-Path $artifactWorkRoot 'package'
        New-Item -ItemType Directory -Path $artifactWorkRoot -Force | Out-Null
        Copy-SafeDirectoryContents -Source $definition.Source -Destination $packageRoot | Out-Null
        $manifest = New-PackageManifestObject -Profile $definition.Profile -PackageRoot $packageRoot
        Write-PackageManifest -Manifest $manifest -PackageRoot $packageRoot | Out-Null
        $archivePath = Join-Path $artifactWorkRoot ("HerdrOps-$($definition.Profile.packageVersion)-win-x64.zip")
        $hashRecordPath = Join-Path $artifactWorkRoot 'package-hashes.txt'
        New-DeterministicPackageArchive -PackageRoot $packageRoot -ArchivePath $archivePath | Out-Null
        Write-PackageHashRecord -Profile $definition.Profile -PackageRoot $packageRoot -ArchivePath $archivePath -Path $hashRecordPath | Out-Null
        $expected = [pscustomobject][ordered]@{
            packageRoot = (Get-AcceptanceFullPath -Path $packageRoot)
            archivePath = (Get-AcceptanceFullPath -Path $archivePath)
            hashRecordPath = (Get-AcceptanceFullPath -Path $hashRecordPath)
            productId = 'HerdrOps'
            displayName = 'HerdrOps'
            packagingIssue = [int]$definition.Profile.issue
            packageVersion = [string]$definition.Profile.packageVersion
            targetFramework = [string]$definition.Profile.targetFramework
            runtimeIdentifier = [string]$definition.Profile.runtimeIdentifier
            deploymentModel = [string]$definition.Profile.deploymentModel
            userDataPolicy = [string]$definition.Profile.userDataPolicy
            sourceCommit = 'NOT_BOUND_IN_SYNTHETIC_FIXTURE'
            manifestSha256 = ('0' * 64) -join ''
            archiveSha256 = ('0' * 64) -join ''
            contentSha256 = ('0' * 64) -join ''
        }
        $expected.manifestSha256 = ((Get-FileHash -LiteralPath (Join-Path $packageRoot 'package-manifest.json') -Algorithm SHA256).Hash).ToUpperInvariant()
        $expected.archiveSha256 = ((Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash).ToUpperInvariant()
        $expected.contentSha256 = [string]$manifest.contentSha256
        $checked = Assert-AcceptanceArtifact -Expected $expected -Name "synthetic $($definition.Name) artifact"
        $expected.manifestSha256 = $checked.ManifestSha256
        $expected.archiveSha256 = $checked.ArchiveSha256
        $expected.contentSha256 = $checked.ContentSha256
        $result[$definition.Name] = $expected
    }
    return [pscustomobject][ordered]@{
        Initial = $result.initial
        Upgrade = $result.upgrade
    }
}

function Assert-SyntheticTargets {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$UserDataRoot
    )

    $simulation = Get-AcceptanceFullPath -Path $Root
    $install = Get-AcceptanceFullPath -Path $InstallRoot
    $data = Get-AcceptanceFullPath -Path $UserDataRoot
    if (-not (Test-PathWithin -ChildPath $install -RootPath $simulation) -or
        -not (Test-PathWithin -ChildPath $data -RootPath $simulation) -or
        $install.Equals($data, [StringComparison]::OrdinalIgnoreCase) -or
        (Test-PathWithin -ChildPath $install -RootPath $data) -or
        (Test-PathWithin -ChildPath $data -RootPath $install)) {
        throw 'Synthetic targets must be distinct children of the generated simulation root.'
    }
    if ([IO.Path]::GetFileName($install) -cne 'HerdrOps' -or
        [IO.Path]::GetFileName($data) -cne 'HerdrOps') {
        throw 'Synthetic targets must use the canonical HerdrOps leaf name.'
    }
    Assert-AcceptanceNoReparsePath -Path $install
    Assert-AcceptanceNoReparsePath -Path $data
}

function Get-ArtifactReportRecord {
    param([Parameter(Mandatory = $true)]$Artifact)

    return [ordered]@{
        name = [string]$Artifact.Name
        productId = [string]$Artifact.ProductId
        displayName = 'HerdrOps'
        packagingIssue = [int]$Artifact.PackagingIssue
        packageVersion = [string]$Artifact.PackageVersion
        targetFramework = [string]$Artifact.TargetFramework
        runtimeIdentifier = [string]$Artifact.RuntimeIdentifier
        deploymentModel = [string]$Artifact.DeploymentModel
        userDataPolicy = [string]$Artifact.UserDataPolicy
        packageRoot = [string]$Artifact.PackageRoot
        archivePath = [string]$Artifact.ArchivePath
        archiveBytes = [int64]$Artifact.ArchiveBytes
        archiveSha256 = [string]$Artifact.ArchiveSha256
        manifestPath = [string]$Artifact.ManifestPath
        manifestBytes = [int64]$Artifact.ManifestBytes
        manifestSha256 = [string]$Artifact.ManifestSha256
        contentSha256 = [string]$Artifact.ContentSha256
        sourceCommitBinding = [string]$Artifact.SourceCommit
        installedFileHashes = @()
    }
}

function Get-InstalledVersionFromManifest {
    param([Parameter(Mandatory = $true)][string]$InstallRoot)

    $manifest = Read-PackageManifest -PackageRoot $InstallRoot
    return [string](Get-AcceptanceRequiredProperty -Object $manifest -Name 'packageVersion' -Context 'installed package manifest')
}

function Get-RetainedDataHash {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedSha256
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Retained-data marker was not found after uninstall: $Path"
    }
    Assert-AcceptanceNoReparsePath -Path $Path
    $hash = ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash).ToUpperInvariant()
    if ($hash -cne $ExpectedSha256) {
        throw 'Retained-data marker hash changed during lifecycle acceptance.'
    }
    return $hash
}

function Invoke-AcceptancePreflight {
    param(
        [Parameter(Mandatory = $true)]$InitialExpected,
        [Parameter(Mandatory = $true)]$UpgradeExpected,
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$UserDataRoot,
        [Parameter(Mandatory = $true)][string]$RetainedDataPath,
        [Parameter(Mandatory = $true)][string]$RetainedDataSha256,
        [Parameter(Mandatory = $true)][string]$RetainedDataMode,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ReportDestination,
        [Parameter(Mandatory = $true)]$ArtifactsReport
    )

    $installParent = Split-Path -Path $InstallRoot -Parent
    $pathSpecifications = New-Object System.Collections.ArrayList
    $artifactIndex = 0
    foreach ($artifactBinding in @($InitialExpected, $UpgradeExpected)) {
        $artifactIndex++
        foreach ($pathName in @('packageRoot', 'archivePath', 'hashRecordPath')) {
            [void]$pathSpecifications.Add([pscustomobject]@{
                    Name = "artifact-$artifactIndex-$pathName"
                    Path = Get-AcceptanceFullPath -Path ([string](Get-AcceptanceRequiredProperty -Object $artifactBinding -Name $pathName -Context 'artifact binding'))
                })
        }
    }
    foreach ($targetSpecification in @(
            [pscustomobject]@{ Name = 'install-root'; Path = $InstallRoot },
            [pscustomobject]@{ Name = 'retained-data-root'; Path = $UserDataRoot },
            [pscustomobject]@{ Name = 'owned-stage-path'; Path = (Join-Path $installParent ("HerdrOps.issue-44.stage-$($script:RunId)")) },
            [pscustomobject]@{ Name = 'owned-backup-path'; Path = (Join-Path $installParent ("HerdrOps.issue-44.backup-$($script:RunId)")) })) {
        [void]$pathSpecifications.Add($targetSpecification)
    }
    if (-not [string]::IsNullOrWhiteSpace($ReportDestination)) {
        [void]$pathSpecifications.Add([pscustomobject]@{ Name = 'report-destination'; Path = $ReportDestination })
    }
    Assert-PackagingPathsDoNotOverlap -Paths @($pathSpecifications.ToArray())
    $initialArtifact = Assert-AcceptanceArtifact -Expected $InitialExpected -Name 'initial'
    $ArtifactsReport.initial = Get-ArtifactReportRecord -Artifact $initialArtifact
    Add-AcceptancePreflightCheck -Name 'initial-artifact-identity-hash-version' -Status 'PASS' -Details ("HerdrOps $($initialArtifact.PackageVersion); manifest/archive/content SHA-256 records match.")
    $upgradeArtifact = Assert-AcceptanceArtifact -Expected $UpgradeExpected -Name 'upgrade'
    $ArtifactsReport.upgrade = Get-ArtifactReportRecord -Artifact $upgradeArtifact
    Add-AcceptancePreflightCheck -Name 'upgrade-artifact-identity-hash-version' -Status 'PASS' -Details ("HerdrOps $($upgradeArtifact.PackageVersion); manifest/archive/content SHA-256 records match.")
    if ([Version]$upgradeArtifact.PackageVersion -le [Version]$initialArtifact.PackageVersion) {
        throw 'Upgrade package version must be greater than the initial package version.'
    }
    Add-AcceptancePreflightCheck -Name 'version-order' -Status 'PASS' -Details 'Upgrade version is greater than the accepted initial version.'

    Assert-AcceptanceNotBroadPath -Path $InstallRoot -Context 'install target' | Out-Null
    Assert-AcceptanceNotBroadPath -Path $UserDataRoot -Context 'retained-data target' | Out-Null
    if ($Mode -eq 'Live') {
        if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
            throw 'Live mode requires Windows.'
        }
        if (Test-AcceptanceIsElevated) {
            throw 'Live mode requires a non-elevated PowerShell process.'
        }
        Add-AcceptancePreflightCheck -Name 'non-elevated-windows-host' -Status 'PASS' -Details 'Windows host is non-elevated for this live acceptance invocation.'
        Assert-AcceptanceNoReparsePath -Path $InstallRoot
        Assert-AcceptanceNoReparsePath -Path $UserDataRoot
        $installParent = Split-Path -Path $InstallRoot -Parent
        Assert-AcceptanceNoReparsePath -Path $installParent
        if (Test-Path -LiteralPath $InstallRoot) {
            throw "Clean install target already exists; refusing to overwrite: $InstallRoot"
        }
        Add-AcceptancePreflightCheck -Name 'canonical-clean-install-target' -Status 'PASS' -Details 'Canonical install target is absent and all existing ancestors are non-reparse paths.'
        if (Test-Path -LiteralPath $UserDataRoot) {
            if (-not (Test-Path -LiteralPath $UserDataRoot -PathType Container)) {
                throw "Retained-data target is not a directory: $UserDataRoot"
            }
        }
        Add-AcceptancePreflightCheck -Name 'retained-data-target-safety' -Status 'PASS' -Details 'Retained-data target is bounded, canonical, and reparse-safe.'
        Assert-AcceptanceReportPath -Path $ReportDestination -InstallRoot $InstallRoot -UserDataRoot $UserDataRoot -AllowExternalParent | Out-Null
        Add-AcceptancePreflightCheck -Name 'report-destination-safety' -Status 'PASS' -Details 'Live report destination is new, exact, and outside product/data targets.'
    } else {
        Assert-SyntheticTargets -Root $script:SimulationRoot -InstallRoot $InstallRoot -UserDataRoot $UserDataRoot
        if (Test-Path -LiteralPath $InstallRoot) {
            throw "Synthetic clean install target unexpectedly exists: $InstallRoot"
        }
        Add-AcceptancePreflightCheck -Name 'isolated-synthetic-targets' -Status 'PASS' -Details 'Fixture target paths are generated under one owned temporary simulation root.'
        if (-not [string]::IsNullOrWhiteSpace($ReportDestination)) {
            if (Test-PathWithin -ChildPath $ReportDestination -RootPath $script:SimulationRoot) {
                throw 'Synthetic report destination must be outside the temporary simulation root so cleanup cannot erase the report.'
            }
            Assert-AcceptanceReportPath -Path $ReportDestination -InstallRoot $InstallRoot -UserDataRoot $UserDataRoot | Out-Null
            Add-AcceptancePreflightCheck -Name 'report-destination-safety' -Status 'PASS' -Details 'Synthetic report destination is new and repository/temp scoped.'
        } else {
            Add-AcceptancePreflightCheck -Name 'report-destination-safety' -Status 'NOT_APPLICABLE' -Details 'No report file was requested; the exact report object is returned to the caller.'
        }
    }

    $markerAllowCreate = ($Mode -eq 'Fixture') -or ($Mode -eq 'Live' -and $RetainedDataMode -ceq 'create-test-marker' -and $AllowLiveRetainedDataSeed)
    Assert-AcceptanceSha256 -Value $RetainedDataSha256 -Context 'retained-data expected hash'
    $markerParent = Split-Path -Path $RetainedDataPath -Parent
    Assert-AcceptanceNoReparsePath -Path $RetainedDataPath
    Assert-AcceptanceNoReparsePath -Path $markerParent
    if ($Mode -eq 'DryRun') {
        Add-AcceptancePreflightCheck -Name 'retained-data-hash-binding' -Status 'NOT_APPLICABLE' -Details 'Dry-run does not create or inspect a retained-data marker.'
    } elseif ($Mode -eq 'Live' -and $RetainedDataMode -ceq 'create-test-marker' -and -not $AllowLiveRetainedDataSeed) {
        throw 'Live retained-data marker creation requires -AllowLiveRetainedDataSeed in addition to the live confirmation token.'
    } elseif (Test-Path -LiteralPath $RetainedDataPath) {
        $markerHash = ((Get-FileHash -LiteralPath $RetainedDataPath -Algorithm SHA256).Hash).ToUpperInvariant()
        if ($markerHash -cne $RetainedDataSha256) {
            throw 'Existing retained-data marker does not match its exact expected hash.'
        }
        Add-AcceptancePreflightCheck -Name 'retained-data-hash-binding' -Status 'PASS' -Details 'Existing retained-data marker matches the exact SHA-256 binding.'
    } elseif ($markerAllowCreate) {
        Add-AcceptancePreflightCheck -Name 'retained-data-hash-binding' -Status 'PASS' -Details 'Bounded test marker will be created only after all preflight checks pass.'
    } else {
        throw "Retained-data marker is absent and the binding does not permit its creation: $RetainedDataPath"
    }

    if ($Mode -eq 'Live' -and [string]$upgradeArtifact.PackageVersion -cne $script:AcceptanceVersion.Substring(1)) {
        throw 'Live upgrade artifact package version is not v1.0.0.'
    }
    if ($Mode -ne 'Live') {
        Add-AcceptancePreflightCheck -Name 'v1-target-version' -Status 'NOT_APPLICABLE' -Details 'Current #38 fixture bytes intentionally exercise orchestration only; they are not a v1.0.0 release artifact.'
    } else {
        Add-AcceptancePreflightCheck -Name 'v1-target-version' -Status 'PASS' -Details 'Live upgrade artifact is bound to v1.0.0.'
    }

    return [pscustomobject][ordered]@{
        InitialArtifact = $initialArtifact
        UpgradeArtifact = $upgradeArtifact
        MarkerAllowCreate = $markerAllowCreate
    }
}

function Invoke-AcceptanceTestCancellationAfter {
    param([Parameter(Mandatory = $true)][string]$Phase)

    if ($TestCancelAfter -ceq $Phase) {
        throw (New-AcceptanceCancellationException -Phase $Phase)
    }
}

function Invoke-AcceptanceTestFailureAfterTransition {
    param([Parameter(Mandatory = $true)][ValidateSet('CleanInstall', 'Upgrade', 'Rollback', 'Uninstall')][string]$Phase)

    if ($TestFailurePoint -ceq "After${Phase}Transition") {
        throw "Injected Issue #44 evidence failure after the $Phase transition."
    }
}

function Invoke-AcceptanceLifecycle {
    param(
        [Parameter(Mandatory = $true)]$InitialArtifact,
        [Parameter(Mandatory = $true)]$UpgradeArtifact,
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$UserDataRoot,
        [Parameter(Mandatory = $true)][string]$RetainedDataPath,
        [Parameter(Mandatory = $true)][string]$RetainedDataSha256,
        [Parameter(Mandatory = $true)]$Lifecycle
    )

    $effect = if ($Mode -eq 'Fixture') { 'FixtureTempOnly' } else { 'LiveFilesystem' }
    if ($Mode -eq 'Live') {
        $script:CleanMachineFilesystemObserved = $true
    }
    $installParent = Split-Path -Path $InstallRoot -Parent
    Assert-AcceptanceDirectory -Path $installParent -Context 'install parent' -Create | Out-Null

    $script:CurrentLifecyclePhase = 'CleanInstall'
    Add-AcceptanceTranscript -Phase 'CleanInstall' -Action 'install-initial-package' -Status 'NOT_RUN' -Effect $effect -Details 'Preparing exact staged directory transition.' -PathBinding 'installRoot'
    $cleanInstall = Invoke-AcceptanceDirectoryTransition `
        -Artifact $InitialArtifact `
        -InstallRoot $InstallRoot `
        -InstallParent $installParent `
        -Phase 'CleanInstall' `
        -CancellationPoint $TestCancelPoint `
        -RunId $script:RunId
    Invoke-AcceptanceTestFailureAfterTransition -Phase 'CleanInstall'
    $lifecycle.cleanInstall.installRootPresent = $true
    $lifecycle.cleanInstall.packageVersionObserved = Get-InstalledVersionFromManifest -InstallRoot $InstallRoot
    $lifecycle.cleanInstall.installedFileHashes = Convert-AcceptanceHashesForReport -Hashes $cleanInstall.InstalledFileHashes
    $lifecycle.cleanInstall.retainedDataStatus = 'PASS'
    $lifecycle.cleanInstall.retainedDataSha256 = Get-RetainedDataHash -Path $RetainedDataPath -ExpectedSha256 $RetainedDataSha256
    $lifecycle.cleanInstall.details = 'Initial package installed by a staged directory transition; no process was started.'
    Add-AcceptanceTranscript -Phase 'CleanInstall' -Action 'install-initial-package' -Status 'PASS' -Effect $effect -Details 'Installed file hashes match the exact initial artifact manifest.' -PathBinding 'installRoot'
    $lifecycle.cleanInstall.status = 'PASS'
    Invoke-AcceptanceTestCancellationAfter -Phase 'CleanInstall'

    $script:CurrentLifecyclePhase = 'Upgrade'
    Add-AcceptanceTranscript -Phase 'Upgrade' -Action 'upgrade-to-candidate-package' -Status 'NOT_RUN' -Effect $effect -Details 'Preparing exact staged directory replacement while preserving retained data.' -PathBinding 'installRoot'
    $upgrade = Invoke-AcceptanceDirectoryTransition `
        -Artifact $UpgradeArtifact `
        -InstallRoot $InstallRoot `
        -InstallParent $installParent `
        -Phase 'Upgrade' `
        -CancellationPoint $TestCancelPoint `
        -RunId $script:RunId
    Invoke-AcceptanceTestFailureAfterTransition -Phase 'Upgrade'
    $lifecycle.upgrade.installRootPresent = $true
    $lifecycle.upgrade.packageVersionObserved = Get-InstalledVersionFromManifest -InstallRoot $InstallRoot
    $lifecycle.upgrade.installedFileHashes = Convert-AcceptanceHashesForReport -Hashes $upgrade.InstalledFileHashes
    $lifecycle.upgrade.retainedDataStatus = 'PASS'
    $lifecycle.upgrade.retainedDataSha256 = Get-RetainedDataHash -Path $RetainedDataPath -ExpectedSha256 $RetainedDataSha256
    $lifecycle.upgrade.details = 'Candidate package replaced the initial package; retained-data marker remained outside install root.'
    Add-AcceptanceTranscript -Phase 'Upgrade' -Action 'upgrade-to-candidate-package' -Status 'PASS' -Effect $effect -Details 'Upgrade file hashes match the exact candidate artifact manifest.' -PathBinding 'installRoot,userDataRoot'
    $lifecycle.upgrade.status = 'PASS'
    Invoke-AcceptanceTestCancellationAfter -Phase 'Upgrade'

    $script:CurrentLifecyclePhase = 'Rollback'
    Add-AcceptanceTranscript -Phase 'Rollback' -Action 'rollback-to-initial-package' -Status 'NOT_RUN' -Effect $effect -Details 'Preparing exact staged rollback to the accepted initial artifact.' -PathBinding 'installRoot'
    $rollback = Invoke-AcceptanceDirectoryTransition `
        -Artifact $InitialArtifact `
        -InstallRoot $InstallRoot `
        -InstallParent $installParent `
        -Phase 'Rollback' `
        -CancellationPoint $TestCancelPoint `
        -RunId $script:RunId
    Invoke-AcceptanceTestFailureAfterTransition -Phase 'Rollback'
    $lifecycle.rollback.installRootPresent = $true
    $lifecycle.rollback.packageVersionObserved = Get-InstalledVersionFromManifest -InstallRoot $InstallRoot
    $lifecycle.rollback.installedFileHashes = Convert-AcceptanceHashesForReport -Hashes $rollback.InstalledFileHashes
    $lifecycle.rollback.retainedDataStatus = 'PASS'
    $lifecycle.rollback.retainedDataSha256 = Get-RetainedDataHash -Path $RetainedDataPath -ExpectedSha256 $RetainedDataSha256
    $lifecycle.rollback.details = 'Rollback restored the initial artifact bytes without touching retained data.'
    Add-AcceptanceTranscript -Phase 'Rollback' -Action 'rollback-to-initial-package' -Status 'PASS' -Effect $effect -Details 'Rollback file hashes match the exact initial artifact manifest.' -PathBinding 'installRoot,userDataRoot'
    $lifecycle.rollback.status = 'PASS'
    Invoke-AcceptanceTestCancellationAfter -Phase 'Rollback'

    $script:CurrentLifecyclePhase = 'Uninstall'
    Add-AcceptanceTranscript -Phase 'Uninstall' -Action 'remove-package-retain-data' -Status 'NOT_RUN' -Effect $effect -Details 'Atomically moving the exact install directory before validating retained data and retiring the owned backup.' -PathBinding 'installRoot,userDataRoot'
    $uninstall = Invoke-AcceptanceUninstallTransition `
        -Artifact $InitialArtifact `
        -InstallRoot $InstallRoot `
        -InstallParent $installParent `
        -RetainedDataPath $RetainedDataPath `
        -RetainedDataSha256 $RetainedDataSha256 `
        -CancellationPoint $TestCancelPoint `
        -RunId $script:RunId
    Invoke-AcceptanceTestFailureAfterTransition -Phase 'Uninstall'
    $lifecycle.uninstall.installRootPresent = $false
    $lifecycle.uninstall.packageVersionObserved = [string]$InitialArtifact.PackageVersion
    $lifecycle.uninstall.installedFileHashes = Convert-AcceptanceHashesForReport -Hashes $uninstall.RemovedFileHashes
    $lifecycle.uninstall.retainedDataStatus = 'PASS'
    $lifecycle.uninstall.details = 'Exact install directory was atomically removed; retained-data marker remains byte-identical.'
    $lifecycle.uninstall.retainedDataSha256 = [string]$uninstall.RetainedDataSha256
    Add-AcceptanceTranscript -Phase 'Uninstall' -Action 'remove-package-retain-data' -Status 'PASS' -Effect $effect -Details 'Package directory is absent and retained-data SHA-256 is unchanged.' -PathBinding 'installRoot,userDataRoot'
    $lifecycle.uninstall.status = 'PASS'
    Invoke-AcceptanceTestCancellationAfter -Phase 'Uninstall'

    $script:CurrentLifecyclePhase = 'Complete'
}

function Invoke-AcceptanceCleanup {
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$UserDataRoot
    )

    $cleanup = [ordered]@{
        status = 'PASS'
        attempted = $true
        simulationRoot = if ($null -eq $script:SimulationRoot) { '' } else { [string]$script:SimulationRoot }
        simulationRootRemoved = $false
        ownedStageRemoved = $true
        ownedBackupRemoved = $true
        harnessSeededDataMarkerRemoved = $false
        retainedDataLeftIntact = $true
        residuals = @()
        details = ''
    }
    $errors = New-Object System.Collections.ArrayList
    try {
        if ($Mode -eq 'Live') {
            $parent = Split-Path -Path $InstallRoot -Parent
            foreach ($role in @('stage', 'backup')) {
                $ownedPath = Join-Path $parent ("HerdrOps.issue-44.$role-$($script:RunId)")
                if (Test-Path -LiteralPath $ownedPath) {
                    if ($role -ceq 'backup') {
                        $cleanup.ownedBackupRemoved = $false
                        [void]$errors.Add("owned backup preserved for manual recovery: $ownedPath")
                        continue
                    }
                    try {
                        Remove-AcceptanceOwnedSiblingDirectory -Path $ownedPath -InstallParent $parent -Role $role -RunId $script:RunId
                    } catch {
                        [void]$errors.Add("$role cleanup failed: $($_.Exception.Message)")
                        if ($role -ceq 'stage') { $cleanup.ownedStageRemoved = $false } else { $cleanup.ownedBackupRemoved = $false }
                    }
                }
            }
            if ($script:HarnessSeededDataMarker -and $null -ne $script:HarnessDataMarkerPath -and
                (Test-Path -LiteralPath $script:HarnessDataMarkerPath)) {
                try {
                    $markerHash = ((Get-FileHash -LiteralPath $script:HarnessDataMarkerPath -Algorithm SHA256).Hash).ToUpperInvariant()
                    if ($markerHash -cne $script:HarnessDataMarkerExpectedSha256) {
                        throw 'Harness-created retained-data marker changed before cleanup.'
                    }
                    Remove-Item -LiteralPath $script:HarnessDataMarkerPath -Force
                    $cleanup.harnessSeededDataMarkerRemoved = $true
                } catch {
                    [void]$errors.Add("harness marker cleanup failed at $script:HarnessDataMarkerPath`: $($_.Exception.Message)")
                    $cleanup.retainedDataLeftIntact = $false
                }
            }
        }
        if ($Mode -ne 'Live' -and $null -ne $script:SimulationRoot) {
            if ($KeepSimulationRoot) {
                $cleanup.residuals += [string]$script:SimulationRoot
            } elseif (Test-Path -LiteralPath $script:SimulationRoot) {
                Remove-PackagingTempDirectory -Path $script:SimulationRoot
                $cleanup.simulationRootRemoved = $true
                if ($script:HarnessSeededDataMarker) {
                    $cleanup.harnessSeededDataMarkerRemoved = $true
                }
            } else {
                $cleanup.simulationRootRemoved = $true
            }
        }
    } catch {
        [void]$errors.Add($_.Exception.Message)
    }
    if ($errors.Count -gt 0) {
        $cleanup.status = 'FAIL'
        $cleanup.details = ($errors -join ' | ')
        foreach ($errorText in $errors) {
            $cleanup.residuals += [string]$errorText
        }
    } else {
        $cleanup.details = if ($Mode -eq 'Live') { 'Only owned stage/backup paths and, when explicitly seeded, the harness marker were considered for cleanup.' } else { 'Owned temporary simulation root cleanup completed.' }
    }
    if ($Mode -eq 'Live') {
        if (Test-Path -LiteralPath $InstallRoot) {
            $cleanup.residuals += $InstallRoot
        }
        if (Test-Path -LiteralPath (Join-Path (Split-Path -Path $InstallRoot -Parent) ("HerdrOps.issue-44.stage-$($script:RunId)"))) {
            $cleanup.residuals += 'owned-stage-directory'
        }
        if (Test-Path -LiteralPath (Join-Path (Split-Path -Path $InstallRoot -Parent) ("HerdrOps.issue-44.backup-$($script:RunId)"))) {
            $cleanup.residuals += 'owned-backup-directory'
        }
        if (@($cleanup.residuals).Count -gt 0) {
            $cleanup.status = 'FAIL'
            if ([string]::IsNullOrWhiteSpace([string]$cleanup.details)) {
                $cleanup.details = 'Live cleanup preserved one or more explicit recovery residuals.'
            }
        }
    }
    return $cleanup
}

function Set-AcceptanceInterruptedLifecycleState {
    param(
        [Parameter(Mandatory = $true)]$Lifecycle,
        [Parameter(Mandatory = $true)][string]$Phase,
        [Parameter(Mandatory = $true)][ValidateSet('FAIL', 'CANCELLED')][string]$Status,
        [Parameter(Mandatory = $true)][string]$Details,
        [AllowNull()][string]$InstallRoot,
        [AllowNull()][string]$RetainedDataPath,
        [AllowNull()][string]$RetainedDataSha256
    )

    $stepName = switch ($Phase) {
        'CleanInstall' { 'cleanInstall' }
        'Upgrade' { 'upgrade' }
        'Rollback' { 'rollback' }
        'Uninstall' { 'uninstall' }
        default { $null }
    }
    if ($null -eq $stepName -or [string]$Lifecycle[$stepName].status -cne 'NOT_RUN') {
        return
    }

    $step = $Lifecycle[$stepName]
    $step.status = $Status
    $step.details = $Details
    if (-not [string]::IsNullOrWhiteSpace($InstallRoot)) {
        $step.installRootPresent = Test-Path -LiteralPath $InstallRoot -PathType Container
        if ($step.installRootPresent) {
            try {
                $step.installedFileHashes = Convert-AcceptanceHashesForReport -Hashes (Get-AcceptanceInstalledFileHashes -InstallRoot $InstallRoot -Context "$Phase interrupted install observation")
                $step.packageVersionObserved = Get-InstalledVersionFromManifest -InstallRoot $InstallRoot
            } catch {
                $step.packageVersionObserved = 'UNREADABLE'
                $step.details = "$Details Observing the interrupted install failed: $($_.Exception.Message)"
            }
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($RetainedDataPath) -and
        -not [string]::IsNullOrWhiteSpace($RetainedDataSha256)) {
        try {
            $step.retainedDataSha256 = Get-RetainedDataHash -Path $RetainedDataPath -ExpectedSha256 $RetainedDataSha256
            $step.retainedDataStatus = 'PASS'
        } catch {
            $step.retainedDataStatus = 'FAIL'
            $step.details = "$($step.details) Retained-data observation failed: $($_.Exception.Message)"
        }
    }
}

function Get-DefaultFixtureRootForAcceptance {
    return Get-AcceptanceFullPath -Path (Join-Path $PSScriptRoot '..\..\tests\fixtures\v0.7\packaging')
}

$status = 'PASS'
$failureDetails = ''
$machineName = [Environment]::MachineName
$machineFingerprint = Get-AcceptanceMachineFingerprint
$initialExpected = $null
$upgradeExpected = $null
$installRoot = $null
$userDataRoot = $null
$retainedDataPath = $null
$retainedDataSha256 = $null
$retainedDataMode = 'preseeded'
$initialArtifact = $null
$upgradeArtifact = $null
$lifecycle = [ordered]@{
    cleanInstall = New-AcceptanceLifecycleStep -ExpectedVersion 'unknown'
    upgrade = New-AcceptanceLifecycleStep -ExpectedVersion 'unknown'
    rollback = New-AcceptanceLifecycleStep -ExpectedVersion 'unknown'
    uninstall = New-AcceptanceLifecycleStep -ExpectedVersion 'none'
}
$cleanup = [ordered]@{
    status = 'NOT_RUN'
    attempted = $false
    simulationRoot = ''
    simulationRootRemoved = $false
    ownedStageRemoved = $true
    ownedBackupRemoved = $true
    harnessSeededDataMarkerRemoved = $false
    retainedDataLeftIntact = $true
    residuals = @()
    details = ''
}
$artifactsReport = [ordered]@{
    initial = $null
    upgrade = $null
}
$targetsReport = [ordered]@{
    installRoot = ''
    userDataRoot = ''
    reportPath = ''
    simulationRoot = ''
    installPathPolicy = '%LOCALAPPDATA%\Programs\HerdrOps'
    userDataPathPolicy = '%LOCALAPPDATA%\HerdrOps'
    userDataPolicy = 'retain-on-uninstall'
}

try {
    if ($Mode -eq 'Live') {
        if (-not $IUnderstandLiveMutation -or $LiveConfirmationToken -cne $script:LiveToken) {
            throw "Live mode is blocked. Require -IUnderstandLiveMutation and exact token '$script:LiveToken'."
        }
        if ([string]::IsNullOrWhiteSpace($BindingPath) -or
            [string]::IsNullOrWhiteSpace($ExpectedMachineName) -or
            [string]::IsNullOrWhiteSpace($ExpectedMachineFingerprint) -or
            [string]::IsNullOrWhiteSpace($ExpectedSourceCommit) -or
            [string]::IsNullOrWhiteSpace($ExpectedInitialArtifactSha256) -or
            [string]::IsNullOrWhiteSpace($ExpectedUpgradeArtifactSha256)) {
            throw 'Live mode requires the exact binding path, machine values, source commit, and both artifact SHA-256 values.'
        }
        if ($KeepSimulationRoot -or $TestCancelPoint -ne 'None' -or $TestCancelAfter -ne 'None' -or $TestFailurePoint -ne 'None') {
            throw 'Fixture cleanup, cancellation, and failure-injection controls are not accepted in Live mode.'
        }
        $liveBinding = Assert-LiveBinding -Path $BindingPath
        if ([string]$liveBinding.InitialArtifact.archiveSha256 -cne $ExpectedInitialArtifactSha256 -or
            [string]$liveBinding.UpgradeArtifact.archiveSha256 -cne $ExpectedUpgradeArtifactSha256) {
            throw 'Supplied live artifact SHA-256 values do not match the exact binding file.'
        }
        $initialExpected = $liveBinding.InitialArtifact
        $upgradeExpected = $liveBinding.UpgradeArtifact
        $installRoot = $liveBinding.InstallRoot
        $userDataRoot = $liveBinding.UserDataRoot
        $ReportDestination = $liveBinding.ReportPath
        $retainedDataPath = $liveBinding.RetainedDataPath
        $retainedDataSha256 = $liveBinding.RetainedDataSha256
        $retainedDataMode = $liveBinding.RetainedDataMode
        $targetsReport.installRoot = $installRoot
        $targetsReport.userDataRoot = $userDataRoot
        $targetsReport.reportPath = $ReportDestination
        if (-not [string]::IsNullOrWhiteSpace($ReportPath) -and
            -not (Get-AcceptanceFullPath -Path $ReportPath).Equals($ReportDestination, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Explicit ReportPath does not match the exact live binding report path.'
        }
        Add-AcceptancePreflightCheck -Name 'explicit-live-opt-in' -Status 'PASS' -Details 'Live filesystem mode was explicitly requested with the exact confirmation token.'
        Add-AcceptanceTranscript -Phase 'Preflight' -Action 'bind-live-machine-and-artifacts' -Status 'PASS' -Effect 'None' -Details 'Exact machine, target, artifact, and report bindings loaded; no effects performed.' -PathBinding 'machine,artifacts,targets,report'
    } else {
        if ($KeepSimulationRoot -and $Mode -eq 'DryRun') {
            throw 'KeepSimulationRoot is only accepted for Fixture mode.'
        }
        if (-not [string]::IsNullOrWhiteSpace($BindingPath) -or
            -not [string]::IsNullOrWhiteSpace($InitialPackageRoot) -or
            -not [string]::IsNullOrWhiteSpace($UpgradePackageRoot) -or
            -not [string]::IsNullOrWhiteSpace($InitialArchivePath) -or
            -not [string]::IsNullOrWhiteSpace($UpgradeArchivePath) -or
            -not [string]::IsNullOrWhiteSpace($InitialHashRecordPath) -or
            -not [string]::IsNullOrWhiteSpace($UpgradeHashRecordPath)) {
            throw 'Non-live modes use the committed fixture set and reject external artifact/path bindings.'
        }
        if ([string]::IsNullOrWhiteSpace($FixtureRoot)) {
            $FixtureRoot = Get-DefaultFixtureRootForAcceptance
        }
        $FixtureRoot = Get-AcceptanceFullPath -Path $FixtureRoot
        $repositoryRoot = Get-PackagingRepositoryRoot
        if (-not (Test-PathWithin -ChildPath $FixtureRoot -RootPath $repositoryRoot)) {
            throw 'Synthetic fixtures must remain inside the authorized repository root.'
        }
        $script:SimulationRoot = New-PackagingTempDirectory -Prefix 'HerdrOps-I44-'
        $installRoot = Get-AcceptanceFullPath -Path (Join-Path $script:SimulationRoot 'targets\install\HerdrOps')
        $userDataRoot = Get-AcceptanceFullPath -Path (Join-Path $script:SimulationRoot 'targets\data\HerdrOps')
        $ReportDestination = if ([string]::IsNullOrWhiteSpace($ReportPath)) { '' } else { Get-AcceptanceFullPath -Path $ReportPath }
        $retainedDataPath = Resolve-AcceptanceSafeRelativeFilePath -RootPath $userDataRoot -RelativePath 'state\issue-44-harness.marker' -Context 'synthetic retained-data marker path'
        $markerContent = "HerdrOps Issue #44 acceptance retained-data marker`n"
        $retainedDataSha256 = Get-Sha256ForText -Text $markerContent
        $retainedDataMode = 'create-test-marker'
        $targetsReport.installRoot = $installRoot
        $targetsReport.userDataRoot = $userDataRoot
        $targetsReport.reportPath = $ReportDestination
        $targetsReport.simulationRoot = [string]$script:SimulationRoot
        $syntheticExpected = New-SyntheticAcceptanceArtifacts -Root $script:SimulationRoot -FixturePath $FixtureRoot
        $initialExpected = $syntheticExpected.Initial
        $upgradeExpected = $syntheticExpected.Upgrade
        Add-AcceptanceTranscript -Phase 'Preflight' -Action 'bind-fixture-artifacts-and-targets' -Status 'PASS' -Effect 'FixtureTempOnly' -Details 'Committed #38 fixture bytes copied into one owned temporary artifact root; no host target was used.' -PathBinding 'fixture,simulationRoot'
    }

    $preflight = Invoke-AcceptancePreflight `
        -InitialExpected $initialExpected `
        -UpgradeExpected $upgradeExpected `
        -InstallRoot $installRoot `
        -UserDataRoot $userDataRoot `
        -RetainedDataPath $retainedDataPath `
        -RetainedDataSha256 $retainedDataSha256 `
        -RetainedDataMode $retainedDataMode `
        -ReportDestination $ReportDestination `
        -ArtifactsReport $artifactsReport
    $initialArtifact = $preflight.InitialArtifact
    $upgradeArtifact = $preflight.UpgradeArtifact
    $lifecycle.cleanInstall.expectedVersion = [string]$initialArtifact.PackageVersion
    $lifecycle.upgrade.expectedVersion = [string]$upgradeArtifact.PackageVersion
    $lifecycle.rollback.expectedVersion = [string]$initialArtifact.PackageVersion
    Add-AcceptanceTranscript -Phase 'Preflight' -Action 'validate-identity-paths-and-hashes' -Status 'PASS' -Effect 'None' -Details 'All fail-closed identity, version, hash, target, reparse, report, and retained-data checks passed.' -PathBinding 'artifacts,targets,data,report'

    if ($Mode -eq 'DryRun') {
        foreach ($phase in @('CleanInstall', 'Upgrade', 'Rollback', 'Uninstall')) {
            Add-AcceptanceTranscript -Phase $phase -Action 'planned-lifecycle-transition' -Status 'SKIPPED' -Effect 'None' -Details 'Dry-run materialized fixture artifact copies under the owned temporary root for hash preflight, but created no install or retained-data target lifecycle.' -PathBinding 'simulationRoot'
        }
        $lifecycle.cleanInstall.details = 'Dry-run only.'
        $lifecycle.upgrade.details = 'Dry-run only.'
        $lifecycle.rollback.details = 'Dry-run only.'
        $lifecycle.uninstall.details = 'Dry-run only.'
    } else {
        $markerCreated = $false
        if ($Mode -eq 'Fixture' -or $retainedDataMode -ceq 'create-test-marker') {
            $markerCreated = New-AcceptanceRetainedDataMarker -UserDataRoot $userDataRoot -Path $retainedDataPath -ExpectedSha256 $retainedDataSha256
            if ($markerCreated) {
                $script:HarnessSeededDataMarker = $true
                $script:HarnessDataMarkerPath = $retainedDataPath
                $script:HarnessDataMarkerExpectedSha256 = $retainedDataSha256
            }
        } else {
            Add-AcceptanceTranscript -Phase 'RetainedData' -Action 'bind-preseeded-retained-data' -Status 'PASS' -Effect 'None' -Details 'Pre-existing retained-data marker matched the exact binding and will not be modified.' -PathBinding 'userDataRoot'
        }
        if ($markerCreated) {
            if ($Mode -eq 'Live') {
                $script:CleanMachineFilesystemObserved = $true
            }
            Add-AcceptanceTranscript -Phase 'RetainedData' -Action 'seed-controlled-retained-data-marker' -Status 'PASS' -Effect $(if ($Mode -eq 'Fixture') { 'FixtureTempOnly' } else { 'LiveFilesystem' }) -Details 'A deterministic marker was created only after preflight and remains outside the package directory.' -PathBinding 'userDataRoot'
        }
        Invoke-AcceptanceLifecycle `
            -InitialArtifact $initialArtifact `
            -UpgradeArtifact $upgradeArtifact `
            -InstallRoot $installRoot `
            -UserDataRoot $userDataRoot `
            -RetainedDataPath $retainedDataPath `
            -RetainedDataSha256 $retainedDataSha256 `
            -Lifecycle $lifecycle
        $artifactsReport.initial.installedFileHashes = $lifecycle.cleanInstall.installedFileHashes
        $artifactsReport.upgrade.installedFileHashes = $lifecycle.upgrade.installedFileHashes
        Add-AcceptanceTranscript -Phase 'Acceptance' -Action 'complete-lifecycle' -Status 'PASS' -Effect $(if ($Mode -eq 'Fixture') { 'FixtureTempOnly' } else { 'LiveFilesystem' }) -Details 'Clean install, upgrade, rollback, uninstall, installed hashes, and retained-data assertions completed.' -PathBinding 'all'
    }
} catch {
    $exception = $_.Exception
    if (Test-AcceptanceCancellationException -Exception $exception) {
        $status = 'CANCELLED'
        $failureDetails = $exception.Message
        Set-AcceptanceInterruptedLifecycleState -Lifecycle $lifecycle -Phase $script:CurrentLifecyclePhase -Status 'CANCELLED' -Details $failureDetails -InstallRoot $installRoot -RetainedDataPath $retainedDataPath -RetainedDataSha256 $retainedDataSha256
        Add-AcceptanceTranscript -Phase 'Cancellation' -Action 'stop-and-clean-owned-transients' -Status 'CANCELLED' -Effect (Get-AcceptanceObservedEffect) -Details $failureDetails -PathBinding 'owned-stage,owned-backup,simulationRoot'
    } else {
        $status = 'FAIL'
        $failureDetails = $exception.Message
        if ($script:CurrentLifecyclePhase -ceq 'Preflight') {
            Add-AcceptancePreflightCheck -Name 'fail-closed-preflight-error' -Status 'FAIL' -Details $failureDetails
        }
        Set-AcceptanceInterruptedLifecycleState -Lifecycle $lifecycle -Phase $script:CurrentLifecyclePhase -Status 'FAIL' -Details $failureDetails -InstallRoot $installRoot -RetainedDataPath $retainedDataPath -RetainedDataSha256 $retainedDataSha256
        Add-AcceptanceTranscript -Phase 'Failure' -Action 'fail-closed' -Status 'FAIL' -Effect (Get-AcceptanceObservedEffect) -Details $failureDetails -PathBinding 'none'
    }
}

if ($null -ne $artifactsReport.initial -and @($lifecycle.cleanInstall.installedFileHashes).Count -gt 0) {
    $artifactsReport.initial.installedFileHashes = $lifecycle.cleanInstall.installedFileHashes
}
if ($null -ne $artifactsReport.upgrade -and @($lifecycle.upgrade.installedFileHashes).Count -gt 0) {
    $artifactsReport.upgrade.installedFileHashes = $lifecycle.upgrade.installedFileHashes
}

if ($null -ne $installRoot -and $null -ne $userDataRoot) {
    $cleanup = Invoke-AcceptanceCleanup -InstallRoot $installRoot -UserDataRoot $userDataRoot
    if ($cleanup.status -eq 'FAIL' -and $status -eq 'PASS') {
        $status = 'FAIL'
        $failureDetails = "Cleanup failed: $($cleanup.details)"
        Add-AcceptanceTranscript -Phase 'Cleanup' -Action 'cleanup-owned-paths' -Status 'FAIL' -Effect (Get-AcceptanceObservedEffect) -Details $cleanup.details -PathBinding 'owned-transients'
    }
} else {
    $cleanup.status = 'NOT_APPLICABLE'
    $cleanup.attempted = $false
    $cleanup.details = 'No target paths were established before fail-closed preflight rejection.'
}

$machineFingerprint = Get-AcceptanceMachineFingerprint
$report = New-AcceptanceReport `
    -Status $status `
    -EvidenceClass (Get-AcceptanceEvidenceClassForObservation -Mode $Mode -CleanMachineFilesystemObserved $script:CleanMachineFilesystemObserved) `
    -MachineName $machineName `
    -MachineFingerprint $machineFingerprint `
    -Artifacts $artifactsReport `
    -Targets $targetsReport `
    -Lifecycle $lifecycle `
    -Cleanup $cleanup `
    -FailureDetails $failureDetails

$reportSchemaPath = Join-Path $PSScriptRoot '..\..\docs\acceptance\issue-44-install-acceptance-report.schema.json'
Assert-AcceptanceReportMatchesSchema -Report $report -SchemaPath $reportSchemaPath

if (-not [string]::IsNullOrWhiteSpace($ReportDestination) -and $null -ne $installRoot -and $null -ne $userDataRoot) {
    $allowExternal = ($Mode -eq 'Live')
    $script:ReportDestination = Write-AcceptanceReportAtomically `
        -Report $report `
        -Path $ReportDestination `
        -InstallRoot $installRoot `
        -UserDataRoot $userDataRoot `
        -AllowExternalParent:$allowExternal
}

if ($status -ne 'PASS') {
    Write-Output $report
    throw "Issue #44 install acceptance ${status}: $failureDetails"
}

Write-Output $report
