#requires -Version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'HerdrOps.InstallAcceptance.Common.ps1')

$harnessPath = Join-Path $PSScriptRoot 'Invoke-HerdrOpsInstallAcceptance.ps1'
$implementationPaths = @(
    (Join-Path $PSScriptRoot 'HerdrOps.InstallAcceptance.Common.ps1'),
    $harnessPath)
$reportSchemaPath = Join-Path $PSScriptRoot '..\..\docs\acceptance\issue-44-install-acceptance-report.schema.json'
$liveBindingExamplePath = Join-Path $PSScriptRoot '..\..\docs\acceptance\issue-44-live-binding.example.json'

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
        [Parameter(Mandatory = $true)][ValidateSet('DryRun', 'Fixture')][string]$Mode
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

    Assert-TestExactProperties -Object $Report.preflight -Names @('status', 'checks') -Context 'report preflight'
    Assert-TestCondition -Condition ([string]$Report.preflight.status -ceq 'PASS') -Message 'Preflight did not pass.'
    Assert-TestCondition -Condition (@($Report.preflight.checks).Count -ge 5) -Message 'Preflight report is missing focused checks.'

    Assert-TestExactProperties -Object $Report.lifecycle -Names @('cleanInstall', 'upgrade', 'rollback', 'uninstall') -Context 'report lifecycle'
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
    Assert-TestCondition -Condition ([bool]$Report.cleanup.simulationRootRemoved) -Message 'Synthetic simulation root was not removed.'
    Assert-TestCondition -Condition (@($Report.cleanup.residuals).Count -eq 0) -Message 'Synthetic run left residuals.'
    Assert-TestCondition -Condition (-not (Test-Path -LiteralPath ([string]$Report.cleanup.simulationRoot))) -Message 'Synthetic simulation root still exists.'

    Assert-TestExactProperties -Object $Report.boundaries -Names @(
        'static', 'synthetic', 'contract', 'cleanMachine', 'runtime',
        'independentReview', 'release') -Context 'report boundaries'
    Assert-TestCondition -Condition ([string]$Report.boundaries.contract -like 'NOT OBSERVED*') -Message 'Contract boundary was not withheld.'
    Assert-TestCondition -Condition ([string]$Report.boundaries.cleanMachine -like 'NOT OBSERVED*') -Message 'Clean-machine boundary was not withheld.'
    Assert-TestCondition -Condition ([string]$Report.boundaries.runtime -like 'NOT OBSERVED*') -Message 'Runtime boundary was not withheld.'
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
        manifestSha256 = ((Get-FileHash -LiteralPath (Join-Path $packageRoot 'package-manifest.json') -Algorithm SHA256).Hash).ToUpperInvariant()
        archiveSha256 = ((Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash).ToUpperInvariant()
        contentSha256 = [string]$manifest.contentSha256
    }
    $artifact = Assert-AcceptanceArtifact -Expected $expected -Name "test $Name artifact"
    return [pscustomobject][ordered]@{
        Expected = $expected
        Artifact = $artifact
        Profile = $Profile
    }
}

function Copy-TestArtifactBinding {
    param([Parameter(Mandatory = $true)]$Binding)

    return ($Binding | ConvertTo-Json -Depth 20 | ConvertFrom-Json)
}

function Write-TestZipEntries {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$Names
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    $fileStream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $archive = $null
    try {
        $archive = New-Object IO.Compression.ZipArchive -ArgumentList @($fileStream, [IO.Compression.ZipArchiveMode]::Create, $true)
        foreach ($name in $Names) {
            $entry = $archive.CreateEntry($name)
            $entryStream = $entry.Open()
            try {
                $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes("test-$name")
                $entryStream.Write($bytes, 0, $bytes.Length)
            } finally {
                $entryStream.Dispose()
            }
        }
    } finally {
        if ($null -ne $archive) { $archive.Dispose() }
        $fileStream.Dispose()
    }
}

function New-MismatchedArchiveBinding {
    param(
        [Parameter(Mandatory = $true)]$ValidArtifact,
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$HashRecordPath,
        [string[]]$UnsafeEntryNames
    )

    if ($null -ne $UnsafeEntryNames -and $UnsafeEntryNames.Count -gt 0) {
        Write-TestZipEntries -Path $ArchivePath -Names $UnsafeEntryNames
    } else {
        $tamperedRoot = Join-Path (Split-Path -Path $ArchivePath -Parent) 'tampered-package'
        Copy-SafeDirectoryContents -Source $ValidArtifact.Expected.packageRoot -Destination $tamperedRoot | Out-Null
        $payload = @(Get-ChildItem -LiteralPath $tamperedRoot -Recurse -File | Where-Object { $_.Name -cne 'package-manifest.json' } | Select-Object -First 1)
        if ($payload.Count -ne 1) {
            throw 'The archive-mismatch fixture has no payload file to alter.'
        }
        [IO.File]::AppendAllText($payload[0].FullName, "`narchive-mismatch`n", (New-Object System.Text.UTF8Encoding($false)))
        New-DeterministicPackageArchive -PackageRoot $tamperedRoot -ArchivePath $ArchivePath | Out-Null
    }
    Write-PackageHashRecord -Profile $ValidArtifact.Profile -PackageRoot $ValidArtifact.Expected.packageRoot -ArchivePath $ArchivePath -Path $HashRecordPath | Out-Null
    $binding = Copy-TestArtifactBinding -Binding $ValidArtifact.Expected
    $binding.archivePath = Get-AcceptanceFullPath -Path $ArchivePath
    $binding.hashRecordPath = Get-AcceptanceFullPath -Path $HashRecordPath
    $binding.archiveSha256 = ((Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash).ToUpperInvariant()
    return $binding
}

foreach ($implementationPath in $implementationPaths) {
    $text = Get-Content -LiteralPath $implementationPath -Raw
    foreach ($forbiddenMarker in @(
            'New-ItemProperty', 'Set-ItemProperty', 'Remove-ItemProperty',
            'Registry::', 'reg.exe', 'Start-Process', 'sc.exe',
            'HERDR_SOCKET_PATH', 'herdr.exe', 'Invoke-WebRequest',
            'Invoke-RestMethod', 'dotnet')) {
        Assert-TestCondition `
            -Condition ($text.IndexOf($forbiddenMarker, [StringComparison]::OrdinalIgnoreCase) -lt 0) `
            -Message "Issue #44 acceptance implementation contains a forbidden runtime/publish marker: $forbiddenMarker"
    }
}

$reportSchema = Read-AcceptanceJsonFile -Path $reportSchemaPath -Context 'Issue #44 report schema test input'
Assert-TestCondition -Condition ([string]$reportSchema.'$schema' -like '*draft-07*') -Message 'Report JSON schema is not draft-07.'
Assert-TestCondition -Condition ($null -ne $reportSchema.definitions) -Message 'Report JSON schema definitions are missing.'
Assert-TestCondition -Condition ([string]$reportSchema.title -like '*Issue 44*') -Message 'Report JSON schema title drifted.'
Assert-TestCondition -Condition (@($reportSchema.required).Count -eq 19) -Message 'Report JSON schema top-level required set drifted.'

$testRoot = New-PackagingTempDirectory -Prefix 'HerdrOps-I44-Test-'
try {
    $broadRootRejected = $false
    try {
        Assert-AcceptanceNotBroadPath -Path ([IO.Path]::GetPathRoot((Get-Location).Path)) -Context 'focused broad-root guard' | Out-Null
    } catch {
        $broadRootRejected = ($_.Exception.Message -like '*broad filesystem root*')
    }
    Assert-TestCondition -Condition $broadRootRejected -Message 'Broad filesystem root was not rejected.'

    $utf8 = New-Object System.Text.UTF8Encoding($false)
    foreach ($invalidJsonCase in @(
            [pscustomobject]@{ Name = 'duplicate'; Text = '{"schemaVersion":1,"schemaVersion":1}' },
            [pscustomobject]@{ Name = 'trailing-comma'; Text = '{"schemaVersion":1,}' },
            [pscustomobject]@{ Name = 'trailing-content'; Text = '{"schemaVersion":1} false' })) {
        $invalidJsonPath = Join-Path $testRoot ("invalid-$($invalidJsonCase.Name).json")
        [IO.File]::WriteAllText($invalidJsonPath, [string]$invalidJsonCase.Text, $utf8)
        $strictJsonRejected = $false
        try {
            Read-AcceptanceJsonFile -Path $invalidJsonPath -Context "strict JSON $($invalidJsonCase.Name) probe" | Out-Null
        } catch {
            $strictJsonRejected = $true
        }
        Assert-TestCondition -Condition $strictJsonRejected -Message "Strict JSON reader accepted $($invalidJsonCase.Name) input."
    }

    $liveBindingExample = Read-AcceptanceJsonFile -Path $liveBindingExamplePath -Context 'Issue #44 live binding example'
    Assert-TestCondition -Condition (@($liveBindingExample.initialArtifact.PSObject.Properties | Where-Object { $_.Name -ceq 'sourceCommit' }).Count -eq 1) -Message 'Initial artifact sourceCommit binding is missing.'
    Assert-TestCondition -Condition (@($liveBindingExample.upgradeArtifact.PSObject.Properties | Where-Object { $_.Name -ceq 'sourceCommit' }).Count -eq 1) -Message 'Upgrade artifact sourceCommit binding is missing.'
    Assert-TestCondition -Condition ([string]$liveBindingExample.upgradeArtifact.sourceCommit -ceq [string]$liveBindingExample.sourceCommit) -Message 'Upgrade artifact sourceCommit is not tied to the top-level accepted source commit.'
    $sourceCommitA = 'a' * 40
    $sourceCommitB = 'b' * 40
    Assert-AcceptanceLiveSourceCommitBinding -AcceptedSourceCommit $sourceCommitA -ExpectedSourceCommit $sourceCommitA -UpgradeArtifactSourceCommit $sourceCommitA
    $sourceCommitMismatchRejected = $false
    try {
        Assert-AcceptanceLiveSourceCommitBinding -AcceptedSourceCommit $sourceCommitA -ExpectedSourceCommit $sourceCommitB -UpgradeArtifactSourceCommit $sourceCommitA
    } catch {
        $sourceCommitMismatchRejected = $true
    }
    Assert-TestCondition -Condition $sourceCommitMismatchRejected -Message 'An independently expected source-commit mismatch was accepted.'
    Assert-TestCondition -Condition ((Get-AcceptanceEvidenceClassForObservation -Mode Live -CleanMachineFilesystemObserved $false) -ceq 'Static') -Message 'Rejected Live preflight was mislabeled CleanMachine.'
    Assert-TestCondition -Condition ((Get-AcceptanceEvidenceClassForObservation -Mode Live -CleanMachineFilesystemObserved $true) -ceq 'CleanMachine') -Message 'Observed Live filesystem lifecycle was not classified CleanMachine.'

    $retainedSafetyRoot = Join-Path $testRoot 'retained-path-safety'
    foreach ($unsafeRelativePath in @('.', '..\escape.marker', 'state:stream', 'state\CON.txt', 'state\trailing.')) {
        $unsafeRelativeRejected = $false
        try {
            Resolve-AcceptanceSafeRelativeFilePath -RootPath $retainedSafetyRoot -RelativePath $unsafeRelativePath -Context 'retained path test' | Out-Null
        } catch {
            $unsafeRelativeRejected = $true
        }
        Assert-TestCondition -Condition $unsafeRelativeRejected -Message "Unsafe retained-data relative path was accepted: $unsafeRelativePath"
    }
    $safeRetainedPath = Resolve-AcceptanceSafeRelativeFilePath -RootPath $retainedSafetyRoot -RelativePath 'state\safe.marker' -Context 'safe retained path test'
    $markerText = "HerdrOps Issue #44 acceptance retained-data marker`n"
    $markerExpectedHash = Get-Sha256ForText -Text $markerText
    New-Item -ItemType Directory -Path (Split-Path -Path $safeRetainedPath -Parent) -Force | Out-Null
    [IO.File]::WriteAllText($safeRetainedPath, 'foreign-owner', $utf8)
    $foreignHashBefore = ((Get-FileHash -LiteralPath $safeRetainedPath -Algorithm SHA256).Hash).ToUpperInvariant()
    $foreignMarkerRejected = $false
    try {
        New-AcceptanceRetainedDataMarker -UserDataRoot $retainedSafetyRoot -Path $safeRetainedPath -ExpectedSha256 $markerExpectedHash | Out-Null
    } catch {
        $foreignMarkerRejected = $true
    }
    Assert-TestCondition -Condition $foreignMarkerRejected -Message 'Atomic retained-data marker creation overwrote a foreign file.'
    Assert-TestCondition -Condition (((Get-FileHash -LiteralPath $safeRetainedPath -Algorithm SHA256).Hash).ToUpperInvariant() -ceq $foreignHashBefore) -Message 'Foreign retained-data bytes changed after CreateNew rejection.'
    $ownedMarkerPath = Resolve-AcceptanceSafeRelativeFilePath -RootPath $retainedSafetyRoot -RelativePath 'state\owned.marker' -Context 'owned retained path test'
    New-AcceptanceRetainedDataMarker -UserDataRoot $retainedSafetyRoot -Path $ownedMarkerPath -ExpectedSha256 $markerExpectedHash | Out-Null
    Assert-TestCondition -Condition (((Get-FileHash -LiteralPath $ownedMarkerPath -Algorithm SHA256).Hash).ToUpperInvariant() -ceq $markerExpectedHash) -Message 'Atomic retained-data marker bytes did not match their binding.'

    $fixtureRoot = Get-AcceptanceFullPath -Path (Join-Path $PSScriptRoot '..\..\tests\fixtures\v1.0\packaging')
    $baseProfile = Read-PackageProfile -Path (Join-Path $PSScriptRoot 'issue-44-package-profile.json')
    $upgradeProfile = New-TestVersionProfile -BaseProfile $baseProfile -Version ([string]$baseProfile.syntheticUpgradeVersion)
    $artifactRoot = Join-Path $testRoot 'artifact-contracts'
    $initialTestArtifact = New-TestAcceptanceArtifact -Root $artifactRoot -Name 'initial' -FixtureSource (Join-Path $fixtureRoot 'initial') -Profile $baseProfile
    $upgradeTestArtifact = New-TestAcceptanceArtifact -Root $artifactRoot -Name 'upgrade' -FixtureSource (Join-Path $fixtureRoot 'upgrade') -Profile $upgradeProfile

    $mismatchRoot = Join-Path $testRoot 'archive-mismatch'
    New-Item -ItemType Directory -Path $mismatchRoot -Force | Out-Null
    $mismatchBinding = New-MismatchedArchiveBinding `
        -ValidArtifact $initialTestArtifact `
        -ArchivePath (Join-Path $mismatchRoot 'payload-mismatch.zip') `
        -HashRecordPath (Join-Path $mismatchRoot 'payload-mismatch-hashes.txt')
    $mismatchRejected = $false
    try {
        Assert-AcceptanceArtifact -Expected $mismatchBinding -Name 'mismatched archive probe' | Out-Null
    } catch {
        $mismatchRejected = ($_.Exception.Message -like '*exact safe representation*')
    }
    Assert-TestCondition -Condition $mismatchRejected -Message 'Archive bytes not matching the expanded package root were accepted.'

    foreach ($unsafeArchiveCase in @(
            [pscustomobject]@{ Name = 'traversal'; Entries = @('../escape.txt') },
            [pscustomobject]@{ Name = 'duplicate'; Entries = @('duplicate.txt', 'DUPLICATE.txt') })) {
        $unsafeRoot = Join-Path $testRoot ("archive-$($unsafeArchiveCase.Name)")
        New-Item -ItemType Directory -Path $unsafeRoot -Force | Out-Null
        $unsafeBinding = New-MismatchedArchiveBinding `
            -ValidArtifact $initialTestArtifact `
            -ArchivePath (Join-Path $unsafeRoot "$($unsafeArchiveCase.Name).zip") `
            -HashRecordPath (Join-Path $unsafeRoot "$($unsafeArchiveCase.Name)-hashes.txt") `
            -UnsafeEntryNames @($unsafeArchiveCase.Entries)
        $unsafeRejected = $false
        try {
            Assert-AcceptanceArtifact -Expected $unsafeBinding -Name "$($unsafeArchiveCase.Name) archive probe" | Out-Null
        } catch {
            $unsafeRejected = ($_.Exception.Message -like '*exact safe representation*')
        }
        Assert-TestCondition -Condition $unsafeRejected -Message "Unsafe $($unsafeArchiveCase.Name) ZIP entries were accepted."
    }

    $overlapSource = Join-Path $testRoot 'overlap-source'
    New-Item -ItemType Directory -Path $overlapSource -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $overlapSource 'source.txt'), 'source', $utf8)
    foreach ($overlapDestination in @(
            (Join-Path $overlapSource 'nested-destination'),
            (Split-Path -Path $overlapSource -Parent))) {
        $overlapRejected = $false
        try {
            Copy-AcceptanceDirectoryContents -Source $overlapSource -Destination $overlapDestination -Context 'overlap probe'
        } catch {
            $overlapRejected = ($_.Exception.Message -like '*must not overlap*')
        }
        Assert-TestCondition -Condition $overlapRejected -Message "Overlapping copy destination was accepted: $overlapDestination"
    }

    $fixtureOutput = @(& $harnessPath -Mode Fixture)
    Assert-TestCondition -Condition ($fixtureOutput.Count -eq 1) -Message 'Fixture harness did not return exactly one report.'
    $fixtureReport = $fixtureOutput[0]
    Assert-TestReportShape -Report $fixtureReport -EvidenceClass 'Synthetic' -Mode 'Fixture'
    foreach ($stepName in @('cleanInstall', 'upgrade', 'rollback', 'uninstall')) {
        Assert-TestCondition -Condition ([string]$fixtureReport.lifecycle.$stepName.status -ceq 'PASS') -Message "Fixture lifecycle step did not pass: $stepName"
    }
    Assert-TestCondition -Condition (@($fixtureReport.lifecycle.cleanInstall.installedFileHashes).Count -gt 0) -Message 'Clean-install hashes were not recorded.'
    Assert-TestCondition -Condition (@($fixtureReport.lifecycle.upgrade.installedFileHashes).Count -gt 0) -Message 'Upgrade hashes were not recorded.'
    Assert-TestCondition -Condition ([string]$fixtureReport.lifecycle.uninstall.retainedDataStatus -ceq 'PASS') -Message 'Retained-data assertion did not pass.'
    Assert-TestCondition -Condition ([string]$fixtureReport.targets.installPathPolicy -ceq '%LOCALAPPDATA%\Programs\HerdrOps') -Message 'Install path policy drifted.'
    Assert-TestCondition -Condition ([string]$fixtureReport.targets.userDataPathPolicy -ceq '%LOCALAPPDATA%\HerdrOps') -Message 'User-data path policy drifted.'
    Assert-TestCondition -Condition ([string]$fixtureReport.boundaries.synthetic -like 'PASS*') -Message 'Fixture synthetic boundary did not pass.'

    $dryRunOutput = @(& $harnessPath -Mode DryRun)
    Assert-TestCondition -Condition ($dryRunOutput.Count -eq 1) -Message 'Dry-run harness did not return exactly one report.'
    $dryRunReport = $dryRunOutput[0]
    Assert-TestReportShape -Report $dryRunReport -EvidenceClass 'Static' -Mode 'DryRun'
    foreach ($stepName in @('cleanInstall', 'upgrade', 'rollback', 'uninstall')) {
        Assert-TestCondition -Condition ([string]$dryRunReport.lifecycle.$stepName.status -ceq 'NOT_RUN') -Message "Dry-run unexpectedly executed lifecycle step: $stepName"
    }
    Assert-TestCondition -Condition (@($dryRunReport.transcript | Where-Object { $_.effect -ceq 'LiveFilesystem' }).Count -eq 0) -Message 'Dry-run transcript contains a live filesystem effect.'

    $phaseOrder = @('cleanInstall', 'upgrade', 'rollback', 'uninstall')
    $cancellationCases = @(
        [pscustomobject]@{ Point = 'BeforeCleanInstallCommit'; Active = 'cleanInstall'; Completed = 0 },
        [pscustomobject]@{ Point = 'BeforeUpgradeCommit'; Active = 'upgrade'; Completed = 1 },
        [pscustomobject]@{ Point = 'AfterUpgradeBackup'; Active = 'upgrade'; Completed = 1 },
        [pscustomobject]@{ Point = 'BeforeRollbackCommit'; Active = 'rollback'; Completed = 2 },
        [pscustomobject]@{ Point = 'AfterRollbackBackup'; Active = 'rollback'; Completed = 2 },
        [pscustomobject]@{ Point = 'BeforeUninstallCommit'; Active = 'uninstall'; Completed = 3 })
    foreach ($cancellationCase in $cancellationCases) {
        $cancellationReportPath = Join-Path $testRoot ("cancel-$($cancellationCase.Point).json")
        $cancellationCaught = $false
        try {
            & $harnessPath -Mode Fixture -TestCancelPoint $cancellationCase.Point -ReportPath $cancellationReportPath | Out-Null
        } catch {
            $cancellationCaught = $true
            Assert-TestCondition -Condition ($_.Exception.Message -like '*CANCELLED*') -Message "Cancellation $($cancellationCase.Point) did not fail closed."
        }
        Assert-TestCondition -Condition $cancellationCaught -Message "Cancellation $($cancellationCase.Point) unexpectedly completed."
        $cancellationReport = Read-AcceptanceJsonFile -Path $cancellationReportPath -Context "cancellation report $($cancellationCase.Point)"
        Assert-AcceptanceReportMatchesSchema -Report $cancellationReport -SchemaPath $reportSchemaPath
        Assert-TestCondition -Condition ([string]$cancellationReport.status -ceq 'CANCELLED') -Message 'Cancellation report status drifted.'
        $activeCancellationStep = Get-AcceptanceRequiredProperty -Object $cancellationReport.lifecycle -Name $cancellationCase.Active -Context 'cancellation lifecycle'
        Assert-TestCondition -Condition ([string]$activeCancellationStep.status -ceq 'CANCELLED') -Message "Active lifecycle phase was not retained for $($cancellationCase.Point)."
        for ($phaseIndex = 0; $phaseIndex -lt $phaseOrder.Count; $phaseIndex++) {
            $expectedStatus = if ($phaseIndex -lt [int]$cancellationCase.Completed) { 'PASS' } elseif ($phaseOrder[$phaseIndex] -ceq $cancellationCase.Active) { 'CANCELLED' } else { 'NOT_RUN' }
            $observedStep = Get-AcceptanceRequiredProperty -Object $cancellationReport.lifecycle -Name $phaseOrder[$phaseIndex] -Context 'cancellation lifecycle'
            Assert-TestCondition -Condition ([string]$observedStep.status -ceq $expectedStatus) -Message "Lifecycle truth drifted for $($cancellationCase.Point), $($phaseOrder[$phaseIndex])."
        }
        Assert-TestCondition -Condition ([string]$cancellationReport.cleanup.status -ceq 'PASS') -Message 'Cancellation cleanup did not pass.'
        Assert-TestCondition -Condition ([bool]$cancellationReport.cleanup.simulationRootRemoved) -Message 'Cancellation simulation root was not removed.'
        Assert-TestCondition -Condition (@($cancellationReport.cleanup.residuals).Count -eq 0) -Message 'Cancellation left residuals.'
        Assert-TestCondition -Condition ([string]$cancellationReport.boundaries.synthetic -like 'OBSERVED CANCELLED*') -Message 'Cancellation synthetic boundary was mislabeled.'
    }

    foreach ($cancelAfterCase in @(
            [pscustomobject]@{ Phase = 'CleanInstall'; Completed = 1 },
            [pscustomobject]@{ Phase = 'Upgrade'; Completed = 2 },
            [pscustomobject]@{ Phase = 'Rollback'; Completed = 3 },
            [pscustomobject]@{ Phase = 'Uninstall'; Completed = 4 })) {
        $cancelAfterReportPath = Join-Path $testRoot ("cancel-after-$($cancelAfterCase.Phase).json")
        $cancelAfterCaught = $false
        try {
            & $harnessPath -Mode Fixture -TestCancelAfter $cancelAfterCase.Phase -ReportPath $cancelAfterReportPath | Out-Null
        } catch {
            $cancelAfterCaught = $true
        }
        Assert-TestCondition -Condition $cancelAfterCaught -Message "Post-phase cancellation $($cancelAfterCase.Phase) unexpectedly completed."
        $cancelAfterReport = Read-AcceptanceJsonFile -Path $cancelAfterReportPath -Context "post-phase cancellation $($cancelAfterCase.Phase)"
        Assert-AcceptanceReportMatchesSchema -Report $cancelAfterReport -SchemaPath $reportSchemaPath
        for ($phaseIndex = 0; $phaseIndex -lt $phaseOrder.Count; $phaseIndex++) {
            $expectedStatus = if ($phaseIndex -lt [int]$cancelAfterCase.Completed) { 'PASS' } else { 'NOT_RUN' }
            $observedStep = Get-AcceptanceRequiredProperty -Object $cancelAfterReport.lifecycle -Name $phaseOrder[$phaseIndex] -Context 'post-phase cancellation lifecycle'
            Assert-TestCondition -Condition ([string]$observedStep.status -ceq $expectedStatus) -Message "Post-phase lifecycle truth drifted for $($cancelAfterCase.Phase)."
        }
    }

    $postTransitionFailurePath = Join-Path $testRoot 'post-upgrade-transition-failure.json'
    $postTransitionFailureCaught = $false
    try {
        & $harnessPath -Mode Fixture -TestFailurePoint AfterUpgradeTransition -ReportPath $postTransitionFailurePath | Out-Null
    } catch {
        $postTransitionFailureCaught = $true
    }
    Assert-TestCondition -Condition $postTransitionFailureCaught -Message 'Injected post-upgrade evidence failure unexpectedly completed.'
    $postTransitionFailureReport = Read-AcceptanceJsonFile -Path $postTransitionFailurePath -Context 'post-upgrade transition failure report'
    Assert-AcceptanceReportMatchesSchema -Report $postTransitionFailureReport -SchemaPath $reportSchemaPath
    Assert-TestCondition -Condition ([string]$postTransitionFailureReport.status -ceq 'FAIL') -Message 'Injected post-transition report did not fail.'
    Assert-TestCondition -Condition ([string]$postTransitionFailureReport.lifecycle.cleanInstall.status -ceq 'PASS') -Message 'Completed clean install lost PASS after later failure.'
    Assert-TestCondition -Condition ([string]$postTransitionFailureReport.lifecycle.upgrade.status -ceq 'FAIL') -Message 'Active upgrade phase falsely remained PASS after evidence failure.'
    Assert-TestCondition -Condition ([string]$postTransitionFailureReport.lifecycle.rollback.status -ceq 'NOT_RUN' -and [string]$postTransitionFailureReport.lifecycle.uninstall.status -ceq 'NOT_RUN') -Message 'Later phases ran after injected upgrade evidence failure.'
    Assert-TestCondition -Condition (@($postTransitionFailureReport.lifecycle.upgrade.installedFileHashes).Count -gt 0) -Message 'Interrupted upgrade observation did not retain installed hashes.'
    Assert-TestCondition -Condition ([string]$postTransitionFailureReport.boundaries.synthetic -like 'OBSERVED FAIL*') -Message 'Post-transition failure synthetic boundary was mislabeled.'

    $failureReportPath = Join-Path $testRoot 'preflight-failure-report.json'
    $failureCaught = $false
    try {
        & $harnessPath -Mode Fixture -FixtureRoot (Join-Path $fixtureRoot 'missing-fixture') -ReportPath $failureReportPath | Out-Null
    } catch {
        $failureCaught = $true
    }
    Assert-TestCondition -Condition $failureCaught -Message 'Missing fixture preflight unexpectedly completed.'
    $failureReport = Read-AcceptanceJsonFile -Path $failureReportPath -Context 'preflight failure report'
    Assert-AcceptanceReportMatchesSchema -Report $failureReport -SchemaPath $reportSchemaPath
    Assert-TestCondition -Condition ([string]$failureReport.status -ceq 'FAIL') -Message 'Failure report status drifted.'
    Assert-TestCondition -Condition ($null -eq $failureReport.artifacts.initial -and $null -eq $failureReport.artifacts.upgrade) -Message 'Unobserved failure artifacts were not represented as null.'
    Assert-TestCondition -Condition ([string]$failureReport.preflight.status -ceq 'FAIL') -Message 'Failure preflight was mislabeled PASS.'
    Assert-TestCondition -Condition ([string]$failureReport.boundaries.static -like 'OBSERVED FAIL*') -Message 'Failure static boundary was mislabeled.'
    Assert-TestCondition -Condition ([string]$failureReport.boundaries.synthetic -like 'OBSERVED FAIL*') -Message 'Failure synthetic boundary was mislabeled.'

    $atomicRoot = Join-Path $testRoot 'atomic-transitions'
    $atomicInstallParent = Join-Path $atomicRoot 'Programs'
    $atomicInstallRoot = Join-Path $atomicInstallParent 'HerdrOps'
    New-Item -ItemType Directory -Path $atomicInstallParent -Force | Out-Null

    $raceRunId = [Guid]::NewGuid().ToString('N')
    $raceHook = {
        param($targetPath, $backupPath)
        New-Item -ItemType Directory -Path $targetPath -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $targetPath 'foreign-owner.txt'), 'foreign', (New-Object System.Text.UTF8Encoding($false)))
    }
    $raceRejected = $false
    try {
        Invoke-AcceptanceDirectoryTransition `
            -Artifact $initialTestArtifact.Artifact `
            -InstallRoot $atomicInstallRoot `
            -InstallParent $atomicInstallParent `
            -Phase CleanInstall `
            -CancellationPoint None `
            -RunId $raceRunId `
            -TestOnlyBeforeCommitHook $raceHook | Out-Null
    } catch {
        $raceRejected = ($_.Exception.Message -like '*unexpectedly recreated*')
    }
    Assert-TestCondition -Condition $raceRejected -Message 'A target appearing during clean install was not rejected.'
    Assert-TestCondition -Condition (Test-Path -LiteralPath (Join-Path $atomicInstallRoot 'foreign-owner.txt') -PathType Leaf) -Message 'Failed clean-install cleanup deleted an unowned target.'
    Remove-AcceptanceDirectoryTree -Path $atomicInstallRoot -Context 'race-test target cleanup'

    $initialInstallRunId = [Guid]::NewGuid().ToString('N')
    Invoke-AcceptanceDirectoryTransition `
        -Artifact $initialTestArtifact.Artifact `
        -InstallRoot $atomicInstallRoot `
        -InstallParent $atomicInstallParent `
        -Phase CleanInstall `
        -CancellationPoint None `
        -RunId $initialInstallRunId | Out-Null
    $upgradeRetirementRunId = [Guid]::NewGuid().ToString('N')
    $damageBackupHook = {
        param($backupPath, $targetPath)
        $victim = @(Get-ChildItem -LiteralPath $backupPath -Recurse -File | Select-Object -First 1)
        if ($victim.Count -ne 1) { throw 'Injected retirement probe found no backup file.' }
        Remove-Item -LiteralPath $victim[0].FullName -Force
        throw 'Injected partial backup retirement failure.'
    }
    $upgradeRetirementFailed = $false
    try {
        Invoke-AcceptanceDirectoryTransition `
            -Artifact $upgradeTestArtifact.Artifact `
            -InstallRoot $atomicInstallRoot `
            -InstallParent $atomicInstallParent `
            -Phase Upgrade `
            -CancellationPoint None `
            -RunId $upgradeRetirementRunId `
            -TestOnlyBackupRetirementHook $damageBackupHook | Out-Null
    } catch {
        $upgradeRetirementFailed = ($_.Exception.Message -like '*remains committed*')
    }
    Assert-TestCondition -Condition $upgradeRetirementFailed -Message 'Injected upgrade backup-retirement failure did not fail acceptance.'
    Assert-AcceptanceInstalledPayload -InstallRoot $atomicInstallRoot -Artifact $upgradeTestArtifact.Artifact -Context 'validated upgrade preserved after retirement failure' | Out-Null
    $upgradeBackupPath = Join-Path $atomicInstallParent ("HerdrOps.issue-44.backup-$upgradeRetirementRunId")
    Assert-TestCondition -Condition (Test-Path -LiteralPath $upgradeBackupPath -PathType Container) -Message 'Damaged upgrade backup was not preserved as an explicit residual.'
    Remove-AcceptanceOwnedSiblingDirectory -Path $upgradeBackupPath -InstallParent $atomicInstallParent -Role backup -RunId $upgradeRetirementRunId
    Remove-AcceptanceDirectoryTree -Path $atomicInstallRoot -Context 'upgrade retirement target cleanup'

    $uninstallSetupRunId = [Guid]::NewGuid().ToString('N')
    Invoke-AcceptanceDirectoryTransition `
        -Artifact $initialTestArtifact.Artifact `
        -InstallRoot $atomicInstallRoot `
        -InstallParent $atomicInstallParent `
        -Phase CleanInstall `
        -CancellationPoint None `
        -RunId $uninstallSetupRunId | Out-Null
    $atomicDataRoot = Join-Path $atomicRoot 'Data\HerdrOps'
    $atomicDataPath = Join-Path $atomicDataRoot 'state\retained.marker'
    New-Item -ItemType Directory -Path (Split-Path -Path $atomicDataPath -Parent) -Force | Out-Null
    $atomicMarkerText = "atomic retained data`n"
    [IO.File]::WriteAllText($atomicDataPath, $atomicMarkerText, $utf8)
    $atomicMarkerHash = Get-Sha256ForText -Text $atomicMarkerText
    $uninstallRetirementRunId = [Guid]::NewGuid().ToString('N')
    $uninstallRetirementFailed = $false
    try {
        Invoke-AcceptanceUninstallTransition `
            -Artifact $initialTestArtifact.Artifact `
            -InstallRoot $atomicInstallRoot `
            -InstallParent $atomicInstallParent `
            -RetainedDataPath $atomicDataPath `
            -RetainedDataSha256 $atomicMarkerHash `
            -CancellationPoint None `
            -RunId $uninstallRetirementRunId `
            -TestOnlyBackupRetirementHook $damageBackupHook | Out-Null
    } catch {
        $uninstallRetirementFailed = ($_.Exception.Message -like '*Uninstall is committed*')
    }
    Assert-TestCondition -Condition $uninstallRetirementFailed -Message 'Injected uninstall backup-retirement failure did not fail acceptance.'
    Assert-TestCondition -Condition (-not (Test-Path -LiteralPath $atomicInstallRoot)) -Message 'Committed uninstall was incorrectly rolled back from a damaged backup.'
    Assert-TestCondition -Condition (((Get-FileHash -LiteralPath $atomicDataPath -Algorithm SHA256).Hash).ToUpperInvariant() -ceq $atomicMarkerHash) -Message 'Retained data changed during atomic uninstall failure.'
    $uninstallBackupPath = Join-Path $atomicInstallParent ("HerdrOps.issue-44.backup-$uninstallRetirementRunId")
    Assert-TestCondition -Condition (Test-Path -LiteralPath $uninstallBackupPath -PathType Container) -Message 'Damaged uninstall backup was not preserved as an explicit residual.'
    Remove-AcceptanceOwnedSiblingDirectory -Path $uninstallBackupPath -InstallParent $atomicInstallParent -Role backup -RunId $uninstallRetirementRunId

    $liveText = Get-Content -LiteralPath $harnessPath -Raw
    foreach ($requiredLiveMarker in @(
            "[ValidateSet('DryRun', 'Fixture', 'Live')]",
            'IUnderstandLiveMutation',
            'HERDROPS-ISSUE-44-LIVE-FILESYSTEM',
            'ExpectedMachineFingerprint',
            'ExpectedSourceCommit',
            'ExpectedInitialArtifactSha256',
            'ExpectedUpgradeArtifactSha256',
            'Test-AcceptanceIsElevated',
            'canonical per-user HerdrOps paths',
            'Assert-AcceptanceNotBroadPath',
            'Assert-AcceptanceNoReparsePath',
            'Assert-AcceptanceTreeNoReparse',
            'Remove-AcceptanceOwnedSiblingDirectory')) {
        Assert-TestCondition -Condition ($liveText.IndexOf($requiredLiveMarker, [StringComparison]::Ordinal) -ge 0) -Message "Live fail-closed marker is missing: $requiredLiveMarker"
    }

    [pscustomobject][ordered]@{
        EvidenceClass = 'Static/Synthetic'
        Issue = 44
        ImplementationSafetyMarkers = 'PASS'
        ExactReportShape = 'PASS'
        FixtureLifecycle = 'PASS'
        DryRunNoLifecycleEffects = 'PASS'
        StrictJsonAndArchiveBinding = 'PASS'
        ObservedEvidenceClassification = 'PASS'
        RetainedDataOwnership = 'PASS'
        AllCancellationPoints = 'PASS'
        PostTransitionFailureTruth = 'PASS'
        FailureReportSchema = 'PASS'
        FailureAtomicTransitions = 'PASS'
        LiveModeNotExecuted = 'PASS'
        CleanMachine = 'NOT OBSERVED'
        Runtime = 'NOT OBSERVED'
        Release = 'NOT OBSERVED'
    }
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-PackagingTempDirectory -Path $testRoot
    }
}
