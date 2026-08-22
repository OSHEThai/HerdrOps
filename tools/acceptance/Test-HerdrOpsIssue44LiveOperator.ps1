#requires -Version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'HerdrOps.InstallAcceptance.Common.ps1')

function Get-DefaultHerdrOpsInstallRoot {
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $env:LOCALAPPDATA = Join-Path $env:USERPROFILE 'AppData\Local'
    }
    return (Join-Path $env:LOCALAPPDATA 'Programs\HerdrOps')
}

function Get-DefaultHerdrOpsUserDataRoot {
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $env:LOCALAPPDATA = Join-Path $env:USERPROFILE 'AppData\Local'
    }
    return (Join-Path $env:LOCALAPPDATA 'HerdrOps')
}

$operatorPath = Join-Path $PSScriptRoot 'Invoke-HerdrOpsIssue44LiveOperator.ps1'
$implementationPaths = @(
    (Join-Path $PSScriptRoot 'Invoke-HerdrOpsIssue44LiveOperator.ps1'),
    (Join-Path $PSScriptRoot 'HerdrOps.InstallAcceptance.Common.ps1'))
$reportSchemaPath = Join-Path $PSScriptRoot '..\..\docs\acceptance\issue-44-install-acceptance-report.schema.json'
$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$fixtureRoot = Join-Path $PSScriptRoot '..\..\tests\fixtures\v1.0\packaging'
$baseProfilePath = Join-Path $PSScriptRoot 'issue-44-package-profile.json'

# Shared global fixture state used to observe injected runner callbacks across
# the operator's script scope boundaries. Cleaned up in the test finally block.
$global:HerdrOpsIssue44FixtureState = [ordered]@{
    InstallerActions = New-Object System.Collections.ArrayList
    FirstRunInvocations = [int]0
}

function Assert-TestCondition {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-TestExactProperties {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string[]]$Names,
        [Parameter(Mandatory = $true)][string]$Context
    )

    Assert-AcceptanceExactProperties -Object $Object -Names $Names -Context $Context
}

function Assert-TestReportShape {
    param(
        [Parameter(Mandatory = $true)]$Report,
        [Parameter(Mandatory = $true)][ValidateSet('Static', 'Synthetic')][string]$EvidenceClass,
        [Parameter(Mandatory = $true)][ValidateSet('DryRun', 'Fixture', 'Live')][string]$Mode
    )

    Assert-TestExactProperties -Object $Report -Names @(
        'schemaVersion', 'reportKind', 'issue', 'acceptanceVersion', 'status',
        'mode', 'evidenceClass', 'startedAtUtc', 'completedAtUtc', 'runId',
        'machine', 'artifacts', 'targets', 'preflight', 'lifecycle', 'cleanup',
        'failureDetails', 'transcript', 'boundaries') -Context 'acceptance report'
    Assert-TestCondition -Condition ([int]$Report.schemaVersion -eq 1) -Message 'Report schemaVersion drifted.'
    Assert-TestCondition -Condition ([string]$Report.reportKind -ceq 'HerdrOps.InstallAcceptanceReport') -Message 'Report kind drifted.'
    Assert-TestCondition -Condition ([int]$Report.issue -eq 44) -Message 'Report issue binding drifted.'
    Assert-TestCondition -Condition ([string]$Report.acceptanceVersion -ceq 'v1.0.0') -Message 'Report acceptance target drifted.'
    Assert-TestCondition -Condition ([string]$Report.status -ceq 'PASS') -Message "Expected PASS report, got $($Report.status)."
    Assert-TestCondition -Condition ([string]$Report.mode -ceq $Mode) -Message 'Report mode drifted.'
    Assert-TestCondition -Condition ([string]$Report.evidenceClass -ceq $EvidenceClass) -Message 'Report evidence class drifted.'
    Assert-TestCondition -Condition ([string]$Report.preflight.status -ceq 'PASS') -Message 'Preflight did not pass.'
    Assert-TestCondition -Condition (-not [string]::IsNullOrWhiteSpace([string]$Report.targets.simulationRoot)) -Message 'Fixture targets report lacks a simulation root.'

    foreach ($stepName in @('cleanInstall', 'upgrade', 'rollback', 'uninstall')) {
        Assert-TestExactProperties -Object $Report.lifecycle.$stepName -Names @(
            'status', 'expectedVersion', 'installedFileHashes', 'installRootPresent',
            'packageVersionObserved', 'retainedDataStatus', 'retainedDataSha256',
            'details') -Context "report lifecycle $stepName"
    }

    Assert-TestExactProperties -Object $Report.cleanup -Names @(
        'status', 'attempted', 'simulationRoot', 'simulationRootRemoved',
        'ownedStageRemoved', 'ownedBackupRemoved', 'harnessSeededDataMarkerRemoved',
        'retainedDataLeftIntact', 'residuals', 'details') -Context 'report cleanup'
    Assert-TestCondition -Condition ([string]$Report.cleanup.status -ceq 'PASS') -Message 'Synthetic cleanup did not pass.'
    Assert-TestCondition -Condition (@($Report.cleanup.residuals).Count -eq 0) -Message 'Synthetic run left residuals.'
}

function Assert-TestExactBoundaries {
    param(
        [Parameter(Mandatory = $true)]$Report
    )

    $boundaries = $Report.boundaries
    Assert-TestExactProperties -Object $boundaries -Names @(
        'static', 'synthetic', 'contract', 'cleanMachine',
        'runtime', 'independentReview', 'release') -Context 'report boundaries'
    $expectedBoundaries = [ordered]@{
        static = 'PASS: acceptance operator source, paths, archive hashes, and contracts verified.'
        synthetic = 'PASS: fixture lifecycle execution.'
        contract = 'NOT OBSERVED: no named-pipe or installed-Herdr IPC compatibility assertions.'
        cleanMachine = 'NOT OBSERVED'
        runtime = 'NOT OBSERVED: no live Herdr runtime connection was evaluated.'
        independentReview = 'NOT OBSERVED.'
        release = 'NOT OBSERVED: no package publication or GitHub Release action performed.'
    }
    foreach ($boundaryName in $expectedBoundaries.Keys) {
        $actual = [string]$boundaries.$boundaryName
        if ($actual -cne $expectedBoundaries[$boundaryName]) {
            throw "Report boundary '$boundaryName' drifted: expected '$($expectedBoundaries[$boundaryName])', observed '$actual'."
        }
    }
}

function New-TestVersionProfile {
    param(
        [Parameter(Mandatory = $true)]$BaseProfile,
        [Parameter(Mandatory = $true)][string]$Version
    )

    $clone = ($BaseProfile | ConvertTo-Json -Depth 20 | ConvertFrom-Json)
    if (@($clone.PSObject.Properties | Where-Object { $_.Name -ceq 'syntheticUpgradeVersion' }).Count -eq 1) {
        $clone.PSObject.Properties.Remove('syntheticUpgradeVersion')
    }
    $clone.packageVersion = $Version
    Assert-PackageProfile -Profile $clone
    return $clone
}

function New-TestAcceptanceArtifact {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$FixtureSource,
        [Parameter(Mandatory = $true)]$Profile
    )

    $workRoot = Join-Path $Root $Name
    $packageRoot = Join-Path $workRoot 'package'
    New-Item -ItemType Directory -Path $workRoot -Force | Out-Null
    Copy-SafeDirectoryContents -Source $FixtureSource -Destination $packageRoot | Out-Null
    $manifest = New-PackageManifestObject -Profile $Profile -PackageRoot $packageRoot
    Write-PackageManifest -Manifest $manifest -PackageRoot $packageRoot | Out-Null
    $archivePath = Join-Path $workRoot ("HerdrOps-$($Profile.packageVersion)-win-x64.zip")
    $hashRecordPath = Join-Path $workRoot 'package-hashes.txt'
    New-DeterministicPackageArchive -PackageRoot $packageRoot -ArchivePath $archivePath | Out-Null
    Write-PackageHashRecord -Profile $Profile -PackageRoot $packageRoot -ArchivePath $archivePath -Path $hashRecordPath | Out-Null
    $expected = [pscustomobject][ordered]@{
        packageRoot = (Get-AcceptanceFullPath -Path $packageRoot)
        archivePath = (Get-AcceptanceFullPath -Path $archivePath)
        hashRecordPath = (Get-AcceptanceFullPath -Path $hashRecordPath)
        productId = 'HerdrOps'
        displayName = 'HerdrOps'
        packagingIssue = [int]$Profile.issue
        packageVersion = [string]$Profile.packageVersion
        targetFramework = [string]$Profile.targetFramework
        runtimeIdentifier = [string]$Profile.runtimeIdentifier
        deploymentModel = [string]$Profile.deploymentModel
        userDataPolicy = [string]$Profile.userDataPolicy
        sourceCommit = 'NOT_BOUND_IN_SYNTHETIC_FIXTURE'
        manifestSha256 = Get-AcceptanceSha256ForFile -Path (Join-Path $packageRoot 'package-manifest.json')
        archiveSha256 = Get-AcceptanceSha256ForFile -Path $archivePath
        contentSha256 = [string]$manifest.contentSha256
    }
    $artifact = Assert-AcceptanceArtifact -Expected $expected -Name "test $Name artifact"
    return [pscustomobject][ordered]@{
        Expected = $expected
        Artifact = $artifact
        Profile = $Profile
    }
}

function Write-TestZipFromContents {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][hashtable]$EntryContents
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    $fileStream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $archive = $null
    try {
        $archive = New-Object -TypeName IO.Compression.ZipArchive -ArgumentList @($fileStream, [IO.Compression.ZipArchiveMode]::Create, $true)
        foreach ($entry in $EntryContents.GetEnumerator()) {
            $zipEntry = $archive.CreateEntry([string]$entry.Key)
            $stream = $zipEntry.Open()
            try {
                $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes([string]$entry.Value)
                $stream.Write($bytes, 0, $bytes.Length)
            } finally {
                $stream.Dispose()
            }
        }
    } finally {
        if ($null -ne $archive) { $archive.Dispose() }
        $fileStream.Dispose()
    }
}

function Test-OperatorFailClosed {
    param(
        [Parameter(Mandatory = $true)][string]$CaseName,
        [Parameter(Mandatory = $true)][hashtable]$Arguments,
        [string]$ExpectedMessageFragment,
        [bool]$ExpectReportFile = $false
    )

    $caught = $null
    $output = $null
    try {
        $output = @(& $operatorPath @Arguments)
    } catch {
        $caught = $_
    }
    if ($null -eq $caught) {
        throw "$CaseName unexpectedly completed with $($output.Count) output object(s)."
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedMessageFragment)) {
        Assert-TestCondition `
            -Condition ($caught.Exception.Message -like "*$ExpectedMessageFragment*") `
            -Message "$CaseName did not fail closed with the expected cause. Message: $($caught.Exception.Message)"
    }
    $reportPath = [string]$Arguments['ReportDestination']
    if ($ExpectReportFile -and -not [string]::IsNullOrWhiteSpace($reportPath) -and (Test-Path -LiteralPath $reportPath -PathType Leaf)) {
        $report = Read-AcceptanceJsonFile -Path $reportPath -Context "$CaseName fail report"
        Assert-AcceptanceReportMatchesSchema -Report $report -SchemaPath $reportSchemaPath
        Assert-TestCondition -Condition ([string]$report.status -ceq 'FAIL') -Message "$CaseName fail report status was not FAIL."
        return $report
    }
    return $null
}

foreach ($implementationPath in $implementationPaths) {
    $text = Get-Content -LiteralPath $implementationPath -Raw
    foreach ($forbiddenMarker in @(
            'New-ItemProperty', 'Set-ItemProperty', 'Remove-ItemProperty',
            'Registry::', 'reg.exe', 'sc.exe', 'Start-Process',
            'HERDR_SOCKET_PATH', 'herdr.exe', 'Invoke-WebRequest',
            'Invoke-RestMethod', 'dotnet', '$env:USERPROFILE')) {
        Assert-TestCondition `
            -Condition ($text.IndexOf($forbiddenMarker, [StringComparison]::OrdinalIgnoreCase) -lt 0) `
            -Message "Issue #44 live operator implementation '$(Split-Path $implementationPath -Leaf)' contains a forbidden runtime/publish marker: $forbiddenMarker"
    }
}

$reportSchema = Read-AcceptanceJsonFile -Path $reportSchemaPath -Context 'Issue #44 report schema test input'
Assert-TestCondition -Condition ([string]$reportSchema.'$schema' -like '*draft-07*') -Message 'Report JSON schema is not draft-07.'
Assert-TestCondition -Condition ([string]$reportSchema.title -like '*Issue 44*') -Message 'Report JSON schema title drifted.'

$testRoot = New-PackagingTempDirectory -Prefix 'HerdrOps-I44LiveOp-'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$resultSummary = $null
try {
    $reportsDir = Join-Path $testRoot 'reports'
    New-Item -ItemType Directory -Path $reportsDir -Force | Out-Null
    $simRoot = Join-Path $testRoot 'sim'

    $canonicalInstall = Get-DefaultHerdrOpsInstallRoot
    $canonicalUserData = Get-DefaultHerdrOpsUserDataRoot
    $canonicalMarker = Join-Path $canonicalUserData 'state\issue-44-harness.marker'
    Assert-TestCondition -Condition (-not (Test-Path -LiteralPath $canonicalMarker -PathType Leaf)) -Message 'Real AppData already carries an Issue #44 harness marker.'
    Assert-TestCondition -Condition (-not (Test-Path -LiteralPath $canonicalInstall)) -Message 'Real AppData already carries a HerdrOps install root.'

    $markerText = "HerdrOps Issue #44 acceptance retained-data marker`n"
    $markerExpectedHash = Get-Sha256ForText -Text $markerText

    $baseProfile = Read-PackageProfile -Path $baseProfilePath
    $upgradeProfile = New-TestVersionProfile -BaseProfile $baseProfile -Version ([string]$baseProfile.syntheticUpgradeVersion)
    $artifactRoot = Join-Path $testRoot 'artifact-contracts'
    $initialArtifact = New-TestAcceptanceArtifact `
        -Root $artifactRoot `
        -Name 'initial' `
        -FixtureSource (Join-Path $fixtureRoot 'initial') `
        -Profile $baseProfile
    $upgradeArtifact = New-TestAcceptanceArtifact `
        -Root $artifactRoot `
        -Name 'upgrade' `
        -FixtureSource (Join-Path $fixtureRoot 'upgrade') `
        -Profile $upgradeProfile
    Assert-TestCondition -Condition ([string]$initialArtifact.Artifact.PackageVersion -ceq '0.7.0') -Message 'Initial artifact package version drifted.'
    Assert-TestCondition -Condition ([string]$upgradeArtifact.Artifact.PackageVersion -ceq '1.0.0') -Message 'Upgrade artifact package version drifted.'

    $syntheticInstallerRunner = {
        param(
            [Parameter(Mandatory = $true)][ValidateSet('Install', 'Uninstall')][string]$Action,
            [string]$ArchivePath,
            [Parameter(Mandatory = $true)][string]$InstallRoot,
            [Parameter(Mandatory = $true)][string]$UserDataRoot,
            [switch]$RemoveUserData,
            [int]$TimeoutSeconds = 60
        )
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue | Out-Null
        [void]$global:HerdrOpsIssue44FixtureState.InstallerActions.Add([string]$Action)
        if ($Action -eq 'Uninstall') {
            if (Test-Path -LiteralPath $InstallRoot) {
                Remove-Item -LiteralPath $InstallRoot -Recurse -Force
            }
            return [pscustomobject]@{ Status = 'PASS'; Action = $Action }
        }
        if ([string]::IsNullOrWhiteSpace($ArchivePath) -or -not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) {
            throw "Synthetic installer runner archive was not found: $ArchivePath"
        }
        if (Test-Path -LiteralPath $InstallRoot) {
            Remove-Item -LiteralPath $InstallRoot -Recurse -Force
        }
        New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
        $zip = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
        try {
            foreach ($entry in @($zip.Entries)) {
                if ($entry.FullName.EndsWith('/', [StringComparison]::Ordinal)) {
                    continue
                }
                $entryName = ([string]$entry.FullName).TrimEnd('/')
                if ([string]::IsNullOrWhiteSpace($entryName)) {
                    continue
                }
                $dest = Join-Path $InstallRoot $entryName
                $parent = Split-Path -Path $dest -Parent
                if (-not (Test-Path -LiteralPath $parent)) {
                    New-Item -ItemType Directory -Path $parent -Force | Out-Null
                }
                [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $dest)
            }
        } finally {
            $zip.Dispose()
        }
        return [pscustomobject]@{ Status = 'PASS'; Action = $Action }
    }

    $syntheticFirstRunRunner = {
        param(
            [Parameter(Mandatory = $true)][string]$InstallRoot,
            [Parameter(Mandatory = $true)][string]$UserDataRoot,
            [int]$TimeoutMilliseconds = 5000
        )
        $global:HerdrOpsIssue44FixtureState.FirstRunInvocations = 1 + [int]$global:HerdrOpsIssue44FixtureState.FirstRunInvocations
        if (-not (Test-Path -LiteralPath $InstallRoot -PathType Container)) {
            return [pscustomobject]@{ Status = 'FAIL'; Details = 'Synthetic first-run: install root missing.' }
        }
        return [pscustomobject]@{ Status = 'PASS'; Details = 'Synthetic first-run quiescence.' }
    }

    $greenArgs = [ordered]@{
        Mode = 'Fixture'
        InstallerRunner = $syntheticInstallerRunner
        FirstRunRunner = $syntheticFirstRunRunner
        InitialArchivePath = [string]$initialArtifact.Artifact.ArchivePath
        InitialArchiveBytes = [long]$initialArtifact.Artifact.ArchiveBytes
        InitialArchiveSha256 = [string]$initialArtifact.Artifact.ArchiveSha256
        InitialManifestSha256 = [string]$initialArtifact.Artifact.ManifestSha256
        InitialContentSha256 = [string]$initialArtifact.Artifact.ContentSha256
        InitialPackageVersion = '0.7.0'
        CandidateArchivePath = [string]$upgradeArtifact.Artifact.ArchivePath
        CandidateArchiveBytes = [long]$upgradeArtifact.Artifact.ArchiveBytes
        CandidateArchiveSha256 = [string]$upgradeArtifact.Artifact.ArchiveSha256
        CandidateManifestSha256 = [string]$upgradeArtifact.Artifact.ManifestSha256
        CandidateContentSha256 = [string]$upgradeArtifact.Artifact.ContentSha256
        CandidatePackageVersion = '1.0.0'
        InstallRoot = (Get-AcceptanceFullPath -Path (Join-Path $simRoot 'Programs\HerdrOps'))
        UserDataRoot = (Get-AcceptanceFullPath -Path (Join-Path $simRoot 'HerdrOps'))
        SimulationRoot = (Get-AcceptanceFullPath -Path $simRoot)
        ReportDestination = (Join-Path $reportsDir 'green.json')
        RetainedDataRelativePath = 'state\issue-44-harness.marker'
        RetainedDataSha256 = $markerExpectedHash
        RetainedDataMode = 'create-test-marker'
    }

    $greenOutput = @(& $operatorPath @greenArgs)
    Assert-TestCondition -Condition ($greenOutput.Count -eq 1) -Message 'Fixture operator returned an unexpected number of objects.'
    $greenReport = $greenOutput[0]
    Assert-TestReportShape -Report $greenReport -EvidenceClass 'Synthetic' -Mode 'Fixture'
    Assert-TestCondition -Condition ([string]$greenReport.mode -ceq 'Fixture') -Message 'Green report mode drifted.'
    foreach ($stepName in @('cleanInstall', 'upgrade', 'rollback', 'uninstall')) {
        Assert-TestCondition -Condition ([string]$greenReport.lifecycle.$stepName.status -ceq 'PASS') -Message "Green lifecycle step did not pass: $stepName"
        Assert-TestCondition -Condition ([string]$greenReport.lifecycle.$stepName.retainedDataStatus -ceq 'PASS') -Message "Green retained data did not pass: $stepName"
        Assert-TestCondition -Condition (@($greenReport.lifecycle.$stepName.installedFileHashes).Count -gt 0) -Message "Green installed hashes missing: $stepName"
    }
    Assert-TestCondition -Condition ([string]$greenReport.cleanup.status -ceq 'PASS') -Message 'Green cleanup did not pass.'
    Assert-TestCondition -Condition (@($greenReport.cleanup.residuals).Count -eq 0) -Message 'Green run left residuals.'
    Assert-TestCondition -Condition ([string]$greenReport.targets.installPathPolicy -ceq '%LOCALAPPDATA%\Programs\HerdrOps') -Message 'Install path policy drifted.'
    Assert-TestCondition -Condition ([string]$greenReport.targets.userDataPathPolicy -ceq '%LOCALAPPDATA%\HerdrOps') -Message 'User-data path policy drifted.'
    Assert-TestCondition -Condition ([string]$greenReport.boundaries.contract -like 'NOT OBSERVED*') -Message 'Contract boundary was not withheld.'
    Assert-TestCondition -Condition ([string]$greenReport.boundaries.cleanMachine -like 'NOT OBSERVED*') -Message 'Clean-machine boundary was not withheld.'
    Assert-TestCondition -Condition ([string]$greenReport.boundaries.runtime -like 'NOT OBSERVED*') -Message 'Runtime boundary was not withheld.'
    Assert-TestCondition -Condition ([string]$greenReport.boundaries.release -like 'NOT OBSERVED*') -Message 'Release boundary was not withheld.'
    Assert-TestCondition -Condition ([string]$greenReport.boundaries.synthetic -like 'PASS*') -Message 'Synthetic boundary did not pass.'
    Assert-TestExactBoundaries -Report $greenReport
    Assert-TestCondition -Condition (-not (Test-Path -LiteralPath $canonicalInstall)) -Message 'Green run touched the real AppData install root.'
    Assert-TestCondition -Condition (-not (Test-Path -LiteralPath $canonicalMarker -PathType Leaf)) -Message 'Green run touched the real AppData retained marker.'

    $expectedActionOrder = @('Install', 'Install', 'Install', 'Uninstall')
    $observedActions = @($global:HerdrOpsIssue44FixtureState.InstallerActions.ToArray() | ForEach-Object { [string]$_ })
    Assert-TestCondition -Condition ($observedActions.Count -eq $expectedActionOrder.Count) -Message "Green installer action count drifted: $($observedActions -join ', ')."
    for ($i = 0; $i -lt $expectedActionOrder.Count; $i++) {
        Assert-TestCondition -Condition ($observedActions[$i] -ceq $expectedActionOrder[$i]) -Message "Green installer action order drifted at index $i."
    }
    Assert-TestCondition -Condition ([int]$global:HerdrOpsIssue44FixtureState.FirstRunInvocations -eq 1) -Message "Green first-run invocation count drifted: $($global:HerdrOpsIssue44FixtureState.FirstRunInvocations)."
    Assert-TestCondition -Condition ([string]$greenReport.evidenceClass -ceq 'Synthetic') -Message 'Green evidence class was not Synthetic.'

    $greenReportOnDisk = Read-AcceptanceJsonFile -Path (Join-Path $reportsDir 'green.json') -Context 'green report on disk'
    Assert-AcceptanceReportMatchesSchema -Report $greenReportOnDisk -SchemaPath $reportSchemaPath
    Assert-TestCondition -Condition ([string]$greenReportOnDisk.status -ceq 'PASS') -Message 'Green report persisted with non-PASS status.'

    # Hostile case: wrong initial archive SHA must fail closed at preflight staging.
    $wrongShaArgs = $greenArgs.Clone()
    $wrongShaArgs['InitialArchiveSha256'] = '0' * 64
    $wrongShaArgs['ReportDestination'] = (Join-Path $reportsDir 'wrong-sha.json')
    Test-OperatorFailClosed -CaseName 'wrong-initial-sha' -Arguments $wrongShaArgs -ExpectedMessageFragment 'SHA-256 mismatch'

    # Hostile case: missing candidate manifest entry must fail closed during staging.
    $missingManifestZip = Join-Path $testRoot 'missing-manifest.zip'
    Write-TestZipFromContents -Path $missingManifestZip -EntryContents @{ 'stray.txt' = 'stray' }
    $missingManifestArgs = $greenArgs.Clone()
    $missingManifestArgs['CandidateArchivePath'] = $missingManifestZip
    $missingManifestArgs.Remove('CandidateArchiveSha256')
    $missingManifestArgs.Remove('CandidateArchiveBytes')
    $missingManifestArgs['ReportDestination'] = (Join-Path $reportsDir 'missing-manifest.json')
    Test-OperatorFailClosed -CaseName 'missing-candidate-manifest' -Arguments $missingManifestArgs -ExpectedMessageFragment 'missing package-manifest.json'

    # Hostile case: duplicate JSON keys in a candidate manifest must fail closed.
    $duplicateManifestJson = '{"schemaVersion":1,"schemaVersion":1,"packageVersion":"1.0.0"}'
    $duplicateManifestZip = Join-Path $testRoot 'duplicate-manifest.zip'
    Write-TestZipFromContents -Path $duplicateManifestZip -EntryContents @{ 'package-manifest.json' = $duplicateManifestJson }
    $duplicateManifestArgs = $greenArgs.Clone()
    $duplicateManifestArgs['CandidateArchivePath'] = $duplicateManifestZip
    $duplicateManifestArgs.Remove('CandidateArchiveSha256')
    $duplicateManifestArgs.Remove('CandidateArchiveBytes')
    $duplicateManifestArgs['ReportDestination'] = (Join-Path $reportsDir 'duplicate-manifest.json')
    Test-OperatorFailClosed -CaseName 'duplicate-manifest-key' -Arguments $duplicateManifestArgs

    # Hostile case: installer runner reports failure -> fail closed in lifecycle.
    $failInstallerRunner = {
        param($Action, $ArchivePath, $InstallRoot, $UserDataRoot, [switch]$RemoveUserData, [int]$TimeoutSeconds = 60)
        return [pscustomobject]@{ Status = 'FAIL'; Action = $Action; Details = 'Injected installer runner failure.' }
    }
    $failInstallerArgs = $greenArgs.Clone()
    $failInstallerArgs['InstallerRunner'] = $failInstallerRunner
    $failInstallerArgs['FirstRunRunner'] = $syntheticFirstRunRunner
    $failInstallerArgs['ReportDestination'] = (Join-Path $reportsDir 'installer-runner-fail.json')
    $failInstallerReport = Test-OperatorFailClosed -CaseName 'installer-runner-fail' -Arguments $failInstallerArgs -ExpectedMessageFragment 'Installer runner reported failure' -ExpectReportFile $true
    if ($null -ne $failInstallerReport) {
        Assert-TestCondition -Condition ([string]$failInstallerReport.lifecycle.cleanInstall.status -ceq 'NOT_RUN') -Message 'Failed installer run was mislabeled as clean-install PASS.'
    }

    # Hostile case: first-run runner reports failure -> fail closed after clean install PASS.
    $failFirstRunRunner = {
        param($InstallRoot, $UserDataRoot, [int]$TimeoutMilliseconds = 5000)
        return [pscustomobject]@{ Status = 'FAIL'; Details = 'Injected first-run runner failure.' }
    }
    $failFirstRunArgs = $greenArgs.Clone()
    $failFirstRunArgs['InstallerRunner'] = $syntheticInstallerRunner
    $failFirstRunArgs['FirstRunRunner'] = $failFirstRunRunner
    $failFirstRunArgs['ReportDestination'] = (Join-Path $reportsDir 'first-runner-fail.json')
    $failFirstRunReport = Test-OperatorFailClosed -CaseName 'first-runner-fail' -Arguments $failFirstRunArgs -ExpectedMessageFragment 'First-run runner reported failure' -ExpectReportFile $true
    if ($null -ne $failFirstRunReport) {
        Assert-TestCondition -Condition ([string]$failFirstRunReport.lifecycle.cleanInstall.status -ceq 'PASS') -Message 'Completed clean install lost PASS after first-run failure.'
        Assert-TestCondition -Condition ([string]$failFirstRunReport.lifecycle.upgrade.status -ceq 'NOT_RUN') -Message 'Later phases ran after first-run failure.'
    }

    # Hostile case: first-run corrupts retained marker -> integrity fail after clean install.
    $corruptFirstRunRunner = {
        param($InstallRoot, $UserDataRoot, [int]$TimeoutMilliseconds = 5000)
        $marker = Join-Path $UserDataRoot 'state\issue-44-harness.marker'
        [IO.File]::AppendAllText($marker, 'corrupted', (New-Object System.Text.UTF8Encoding($false)))
        return [pscustomobject]@{ Status = 'PASS'; Details = 'Injected retained-data corruption.' }
    }
    $corruptFirstRunArgs = $greenArgs.Clone()
    $corruptFirstRunArgs['InstallerRunner'] = $syntheticInstallerRunner
    $corruptFirstRunArgs['FirstRunRunner'] = $corruptFirstRunRunner
    $corruptFirstRunArgs['ReportDestination'] = (Join-Path $reportsDir 'first-runner-corrupt.json')
    Test-OperatorFailClosed -CaseName 'first-runner-corrupt-retained-data' -Arguments $corruptFirstRunArgs -ExpectedMessageFragment 'Retained data marker'

    # Hostile case: accepted-Beta provenance SHA mismatch -> preflight fail.
    $betaReportPath = Join-Path $testRoot 'beta-report.json'
    [IO.File]::WriteAllText($betaReportPath, '{"status":"Accepted","sourceCommit":"' + ('a' * 40) + '"}', $utf8)
    $betaMismatchArgs = $greenArgs.Clone()
    $betaMismatchArgs['BetaReportPath'] = $betaReportPath
    $betaMismatchArgs['BetaReportSha256'] = '0' * 64
    $betaMismatchArgs['ReportDestination'] = (Join-Path $reportsDir 'beta-provenance-mismatch.json')
    Test-OperatorFailClosed -CaseName 'accepted-beta-provenance-mismatch' -Arguments $betaMismatchArgs -ExpectedMessageFragment 'SHA-256 mismatch'

    # Hostile case: report destination nested inside retained-data root must fail closed.
    $nestedReportArgs = $greenArgs.Clone()
    $nestedReportArgs['ReportDestination'] = (Get-AcceptanceFullPath -Path (Join-Path $simRoot 'HerdrOps\invalid-report.json'))
    Test-OperatorFailClosed -CaseName 'nested-report-destination' -Arguments $nestedReportArgs -ExpectedMessageFragment 'must not be inside'

    # Hostile case: pre-existing InstallRoot must fail closed at clean-machine precondition.
    $simPrograms = Join-Path $simRoot 'Programs'
    New-Item -ItemType Directory -Path $simPrograms -Force | Out-Null
    $preExistingInstallRoot = Join-Path $simPrograms 'HerdrOps'
    New-Item -ItemType Directory -Path $preExistingInstallRoot -Force | Out-Null
    $preExistingArgs = $greenArgs.Clone()
    $preExistingArgs['InstallRoot'] = (Get-AcceptanceFullPath -Path $preExistingInstallRoot)
    $preExistingArgs['ReportDestination'] = (Join-Path $reportsDir 'pre-existing-install-root.json')
    Test-OperatorFailClosed -CaseName 'pre-existing-install-root' -Arguments $preExistingArgs -ExpectedMessageFragment 'InstallRoot already exists'
    Remove-Item -LiteralPath $preExistingInstallRoot -Recurse -Force

    # Hostile case: leftover staging/backup residuals next to a missing InstallRoot must fail closed.
    foreach ($residualName in @('HerdrOps.staging-abandoned', 'HerdrOps.backup-abandoned')) {
        $residualDir = Join-Path $simPrograms $residualName
        New-Item -ItemType Directory -Path $residualDir -Force | Out-Null
        $residualArgs = $greenArgs.Clone()
        $residualArgs['ReportDestination'] = (Join-Path $reportsDir ('residual-' + $residualName.Replace('.', '-') + '.json'))
        Test-OperatorFailClosed -CaseName "residual-$residualName" -Arguments $residualArgs -ExpectedMessageFragment 'leftover residuals detected'
        Remove-Item -LiteralPath $residualDir -Recurse -Force
    }

    # Hostile case: Live mode with injected runners must fail closed at the live safeguard.
    $liveRunHead = @(& git -C $repositoryRoot rev-parse --verify 'HEAD^{commit}' 2>&1 | ForEach-Object { [string]$_ })
    Assert-TestCondition -Condition ($liveRunHead.Count -eq 1 -and $liveRunHead[0].Trim() -cmatch '^[0-9a-f]{40}$') -Message 'Could not resolve exact repository HEAD commit for the Live injected-runner hostile case.'
    $liveRunHead = $liveRunHead[0].Trim().ToLowerInvariant()
    $liveRunTree = @(& git -C $repositoryRoot rev-parse --verify "$liveRunHead^{tree}" 2>&1 | ForEach-Object { [string]$_ })
    Assert-TestCondition -Condition ($liveRunTree.Count -eq 1 -and $liveRunTree[0].Trim() -cmatch '^[0-9a-f]{40}$') -Message 'Could not resolve exact repository source tree for the Live injected-runner hostile case.'
    $liveRunTree = $liveRunTree[0].Trim().ToLowerInvariant()
    $liveMachineName = [Environment]::MachineName
    if ([string]::IsNullOrWhiteSpace($liveMachineName)) { $liveMachineName = 'NOT_OBSERVED' }
    $liveMachineFingerprint = Get-AcceptanceMachineFingerprint

    $liveBinding = [ordered]@{
        schemaVersion = 1
        issue = 44
        acceptanceVersion = 'v1.0.0'
        mode = 'Live'
        machineRole = 'clean-install-host'
        machineName = $liveMachineName
        machineFingerprint = $liveMachineFingerprint
        sourceCommit = $liveRunHead
        initialArtifact = [ordered]@{
            packageRoot = [string]$initialArtifact.Expected.PackageRoot
            archivePath = [string]$initialArtifact.Expected.ArchivePath
            hashRecordPath = [string]$initialArtifact.Expected.HashRecordPath
            productId = 'HerdrOps'
            displayName = 'HerdrOps'
            packagingIssue = 38
            packageVersion = '0.7.0'
            targetFramework = 'net10.0-windows'
            runtimeIdentifier = 'win-x64'
            deploymentModel = 'per-user-directory'
            userDataPolicy = 'retain-on-uninstall'
            sourceCommit = $liveRunHead
            manifestSha256 = [string]$initialArtifact.Expected.ManifestSha256
            archiveSha256 = [string]$initialArtifact.Expected.ArchiveSha256
            contentSha256 = [string]$initialArtifact.Expected.ContentSha256
        }
        upgradeArtifact = [ordered]@{
            packageRoot = [string]$upgradeArtifact.Expected.PackageRoot
            archivePath = [string]$upgradeArtifact.Expected.ArchivePath
            hashRecordPath = [string]$upgradeArtifact.Expected.HashRecordPath
            productId = 'HerdrOps'
            displayName = 'HerdrOps'
            packagingIssue = 44
            packageVersion = '1.0.0'
            targetFramework = 'net10.0-windows'
            runtimeIdentifier = 'win-x64'
            deploymentModel = 'per-user-directory'
            userDataPolicy = 'retain-on-uninstall'
            sourceCommit = $liveRunHead
            manifestSha256 = [string]$upgradeArtifact.Expected.ManifestSha256
            archiveSha256 = [string]$upgradeArtifact.Expected.ArchiveSha256
            contentSha256 = [string]$upgradeArtifact.Expected.ContentSha256
        }
        installRoot = (Get-AcceptanceFullPath -Path (Join-Path $simRoot 'Programs\HerdrOps'))
        userDataRoot = (Get-AcceptanceFullPath -Path (Join-Path $simRoot 'HerdrOps'))
        reportPath = (Join-Path $reportsDir 'live-injected-runners.json')
        retainedDataRelativePath = 'state\issue-44-harness.marker'
        retainedDataSha256 = $markerExpectedHash
        retainedDataMode = 'create-test-marker'
    }
    $liveBindingPath = Join-Path $testRoot 'live-injected-runners.binding.json'
    [IO.File]::WriteAllText($liveBindingPath, ($liveBinding | ConvertTo-Json -Depth 30), $utf8)
    $liveInjectedArgs = [ordered]@{
        BindingPath = $liveBindingPath
        ExpectedSourceTree = $liveRunTree
        InstallerRunner = $syntheticInstallerRunner
        FirstRunRunner = $syntheticFirstRunRunner
        ReportDestination = (Join-Path $reportsDir 'live-injected-runners.json')
    }
    Test-OperatorFailClosed -CaseName 'live-injected-runners' -Arguments $liveInjectedArgs -ExpectedMessageFragment 'MUST NOT use injected'

    $resultSummary = [pscustomobject][ordered]@{
        EvidenceClass = 'Synthetic'
        Issue = 44
        InjectedRunners = 'PASS'
        ExactOperatorContract = 'PASS'
        FixtureLifecyclePass = 'PASS'
        RetainedDataPersistence = 'PASS'
        ExactProductionActionOrder = 'PASS'
        FailClosedHostileCases = 'PASS'
        ReportSchemaPersisted = 'PASS'
        CleanMachine = 'NOT OBSERVED'
        Runtime = 'NOT OBSERVED'
        Release = 'NOT OBSERVED'
    }
} finally {
    if ($null -ne $global:HerdrOpsIssue44FixtureState) {
        Remove-Variable -Scope Global -Name HerdrOpsIssue44FixtureState -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $testRoot) {
        Remove-PackagingTempDirectory -Path $testRoot
    }
}

if ($null -ne $resultSummary) {
    $resultSummary
}