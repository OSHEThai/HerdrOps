#requires -Version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'V10Release.Common.ps1')

function Write-TestText {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text
    )

    $parent = Split-Path -Path $Path -Parent
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Assert-ExpectedFailure {
    param(
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [string[]]$RequiredFragments = @()
    )

    $failure = $null
    try {
        & $Action
    } catch {
        $failure = $_
    }
    if ($null -eq $failure) {
        throw "Expected failure was not observed: $Description"
    }
    foreach ($fragment in $RequiredFragments) {
        if ($failure.Exception.Message.IndexOf($fragment, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
            throw "Expected failure '$Description' did not contain '$fragment': $($failure.Exception.Message)"
        }
    }
}

function Copy-TestJsonObject {
    param([Parameter(Mandatory = $true)]$Value)

    $json = $Value | ConvertTo-Json -Depth 30
    return (ConvertFrom-StrictPackageJson -Json $json -Description 'synthetic release fixture clone')
}

function Get-TestRelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root
    )

    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $full = [IO.Path]::GetFullPath($Path)
    $prefix = $rootFull + '\'
    if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Synthetic fixture path escaped the repository: $full"
    }
    return $full.Substring($prefix.Length).Replace('\', '/')
}

function New-TestHex64 {
    param([Parameter(Mandatory = $true)][string]$Character)

    return (($Character * 64) -join '')
}

function New-TestIssue44Report {
    param(
        [Parameter(Mandatory = $true)][string]$SourceCommit,
        [Parameter(Mandatory = $true)][string]$ArchiveSha256,
        [Parameter(Mandatory = $true)][string]$ManifestSha256,
        [Parameter(Mandatory = $true)][string]$ContentSha256,
        [switch]$LiveShape
    )

    $initialSourceCommit = if ($LiveShape) { $SourceCommit } else { 'NOT_BOUND_IN_SYNTHETIC_FIXTURE' }
    $mode = if ($LiveShape) { 'Live' } else { 'Fixture' }
    $evidenceClass = if ($LiveShape) { 'CleanMachine' } else { 'Synthetic' }
    $effect = if ($LiveShape) { 'LiveFilesystem' } else { 'FixtureTempOnly' }
    $machineName = if ($LiveShape) { 'SYNTHETIC-LIVE-HOST' } else { 'SYNTHETIC-FIXTURE-HOST' }
    $machineFingerprint = New-TestHex64 -Character 'A'
    $retainedDataSha256 = New-TestHex64 -Character 'B'
    $initialInstalledHashes = @([ordered]@{
            path = 'HerdrOps.App.dll'
            length = [int64]10
            sha256 = (New-TestHex64 -Character 'C')
        })
    $upgradeInstalledHashes = @([ordered]@{
            path = 'HerdrOps.App.dll'
            length = [int64]11
            sha256 = (New-TestHex64 -Character 'D')
        })
    $initialArtifact = [ordered]@{
        name = 'initial'
        productId = 'HerdrOps'
        displayName = 'HerdrOps'
        packagingIssue = 38
        packageVersion = '0.7.0'
        targetFramework = 'net10.0-windows'
        runtimeIdentifier = 'win-x64'
        deploymentModel = 'per-user-directory'
        userDataPolicy = 'retain-on-uninstall'
        packageRoot = 'C:\synthetic\issue-44\initial\package'
        archivePath = 'C:\synthetic\issue-44\initial\HerdrOps-0.7.0-win-x64.zip'
        archiveBytes = [int64]128
        archiveSha256 = (New-TestHex64 -Character 'E')
        manifestPath = 'C:\synthetic\issue-44\initial\package\package-manifest.json'
        manifestBytes = [int64]64
        manifestSha256 = (New-TestHex64 -Character 'F')
        contentSha256 = (New-TestHex64 -Character '1')
        sourceCommitBinding = $initialSourceCommit
        installedFileHashes = $initialInstalledHashes
    }
    $upgradeArtifact = [ordered]@{
        name = 'upgrade'
        productId = 'HerdrOps'
        displayName = 'HerdrOps'
        packagingIssue = 38
        packageVersion = '1.0.0'
        targetFramework = 'net10.0-windows'
        runtimeIdentifier = 'win-x64'
        deploymentModel = 'per-user-directory'
        userDataPolicy = 'retain-on-uninstall'
        packageRoot = 'C:\synthetic\issue-44\upgrade\package'
        archivePath = 'C:\synthetic\issue-44\upgrade\HerdrOps-1.0.0-win-x64.zip'
        archiveBytes = [int64]256
        archiveSha256 = $ArchiveSha256
        manifestPath = 'C:\synthetic\issue-44\upgrade\package\package-manifest.json'
        manifestBytes = [int64]96
        manifestSha256 = $ManifestSha256
        contentSha256 = $ContentSha256
        sourceCommitBinding = $(if ($LiveShape) { $SourceCommit } else { 'NOT_BOUND_IN_SYNTHETIC_FIXTURE' })
        installedFileHashes = $upgradeInstalledHashes
    }
    $targets = [ordered]@{
        installRoot = 'C:\synthetic\issue-44\targets\install\HerdrOps'
        userDataRoot = 'C:\synthetic\issue-44\targets\data\HerdrOps'
        reportPath = if ($LiveShape) { 'C:\synthetic\issue-44\evidence\issue-44-live-shape.json' } else { '' }
        simulationRoot = if ($LiveShape) { '' } else { 'C:\synthetic\issue-44\simulation' }
        installPathPolicy = '%LOCALAPPDATA%\Programs\HerdrOps'
        userDataPathPolicy = '%LOCALAPPDATA%\HerdrOps'
        userDataPolicy = 'retain-on-uninstall'
    }
    $lifecycle = [ordered]@{
        cleanInstall = [ordered]@{
            status = 'PASS'; expectedVersion = '0.7.0'; installedFileHashes = $initialInstalledHashes
            installRootPresent = $true; packageVersionObserved = '0.7.0'; retainedDataStatus = 'PASS'
            retainedDataSha256 = $retainedDataSha256; details = 'Synthetic initial package lifecycle.'
        }
        upgrade = [ordered]@{
            status = 'PASS'; expectedVersion = '1.0.0'; installedFileHashes = $upgradeInstalledHashes
            installRootPresent = $true; packageVersionObserved = '1.0.0'; retainedDataStatus = 'PASS'
            retainedDataSha256 = $retainedDataSha256; details = 'Synthetic upgrade package lifecycle.'
        }
        rollback = [ordered]@{
            status = 'PASS'; expectedVersion = '0.7.0'; installedFileHashes = $initialInstalledHashes
            installRootPresent = $true; packageVersionObserved = '0.7.0'; retainedDataStatus = 'PASS'
            retainedDataSha256 = $retainedDataSha256; details = 'Synthetic rollback to initial package.'
        }
        uninstall = [ordered]@{
            status = 'PASS'; expectedVersion = 'none'; installedFileHashes = $initialInstalledHashes
            installRootPresent = $false; packageVersionObserved = '0.7.0'; retainedDataStatus = 'PASS'
            retainedDataSha256 = $retainedDataSha256; details = 'Synthetic uninstall retained user data.'
        }
    }
    $boundaries = if ($LiveShape) {
        [ordered]@{
            static = 'PASS: exact acceptance report shape and bindings checked.'
            synthetic = 'NOT OBSERVED: no fixture lifecycle credit.'
            contract = 'NOT OBSERVED: no named-pipe or installed-Herdr compatibility work.'
            cleanMachine = 'PASS: bound clean-machine filesystem lifecycle.'
            runtime = 'NOT OBSERVED: no Herdr runtime or application process was started.'
            independentReview = 'NOT OBSERVED.'
            release = 'NOT OBSERVED: no release or publication action was performed.'
        }
    } else {
        [ordered]@{
            static = 'PASS: exact synthetic acceptance report shape and bindings checked.'
            synthetic = 'PASS: fixture-only lifecycle transitions and retained-data assertions.'
            contract = 'NOT OBSERVED: no named-pipe or installed-Herdr compatibility work.'
            cleanMachine = 'NOT OBSERVED: no validated clean-machine filesystem effect.'
            runtime = 'NOT OBSERVED: no Herdr runtime or application process was started.'
            independentReview = 'NOT OBSERVED.'
            release = 'NOT OBSERVED: no release or publication action was performed.'
        }
    }

    return [ordered]@{
        schemaVersion = 1
        reportKind = 'HerdrOps.InstallAcceptanceReport'
        issue = 44
        acceptanceVersion = 'v1.0.0'
        status = 'PASS'
        mode = $mode
        evidenceClass = $evidenceClass
        startedAtUtc = '2026-08-17T00:35:00.0000000Z'
        completedAtUtc = '2026-08-17T00:40:00.0000000Z'
        runId = (('a' * 32) -join '')
        machine = [ordered]@{
            name = $machineName
            expectedName = $machineName
            fingerprint = $machineFingerprint
            expectedFingerprint = $machineFingerprint
            elevated = $false
        }
        artifacts = [ordered]@{ initial = $initialArtifact; upgrade = $upgradeArtifact }
        targets = $targets
        preflight = [ordered]@{
            status = 'PASS'
            checks = @(
                [ordered]@{ name = 'initial-artifact-identity-hash-version'; status = 'PASS'; details = 'Initial artifact identity and hashes are bound.' },
                [ordered]@{ name = 'upgrade-artifact-identity-hash-version'; status = 'PASS'; details = 'Upgrade artifact identity and hashes are bound.' },
                [ordered]@{ name = 'version-order'; status = 'PASS'; details = 'Upgrade is newer than initial.' },
                [ordered]@{ name = 'v1-target-version'; status = 'PASS'; details = 'Upgrade artifact is v1.0.0.' })
        }
        lifecycle = $lifecycle
        cleanup = [ordered]@{
            status = 'PASS'
            attempted = $true
            simulationRoot = [string]$targets.simulationRoot
            simulationRootRemoved = (-not $LiveShape)
            ownedStageRemoved = $true
            ownedBackupRemoved = $true
            harnessSeededDataMarkerRemoved = $false
            retainedDataLeftIntact = $true
            residuals = @()
            details = 'Synthetic cleanup completed with zero residuals.'
        }
        failureDetails = ''
        transcript = @([ordered]@{
                sequence = 1
                phase = 'Complete'
                action = 'complete-lifecycle'
                status = 'PASS'
                effect = $effect
                details = 'Synthetic report shape only; no runtime or release evidence.'
                pathBinding = 'all'
            })
        boundaries = $boundaries
    }
}

$repositoryRoot = Get-V10RepositoryRoot
$profilePath = Join-Path $PSScriptRoot 'v1.0-package-profile.json'
$profile = Read-V10ReleaseProfile -Path $profilePath
$ownedParent = Normalize-ComparablePath -Path (Join-Path $repositoryRoot 'artifacts\release-readiness-tests')
$runId = [Guid]::NewGuid().ToString('N')
$testRoot = Join-Path $ownedParent $runId
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

$assertions = New-Object System.Collections.ArrayList
try {
    $componentRoots = [ordered]@{}
    foreach ($component in @($profile.components)) {
        $root = Join-Path $testRoot ('component-' + [string]$component.name)
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        Write-TestText -Path (Join-Path $root 'shared-runtime.bin') -Text 'identical-shared-runtime'
        Write-TestText -Path (Join-Path $root ([string]$component.assemblyName + '.dll')) -Text ("synthetic-$($component.name)-dll")
        Write-TestText -Path (Join-Path $root ([string]$component.assemblyName + '.exe')) -Text ("synthetic-$($component.name)-exe")
        Write-TestText -Path (Join-Path $root ([string]$component.assemblyName + '.deps.json')) -Text ("synthetic-$($component.name)-deps")
        $componentRoots[[string]$component.name] = [pscustomobject][ordered]@{
            Name = [string]$component.name
            AssemblyName = [string]$component.assemblyName
            PublishRoot = $root
        }
    }

    $packageSource = Join-Path $testRoot 'package-source'
    New-Item -ItemType Directory -Path $packageSource -Force | Out-Null
    $merge = Merge-V10PublishedComponents -Components @($componentRoots.Values) -DestinationRoot $packageSource
    if ($merge.FileCount -ne 10 -or @($merge.EntryPoints).Count -ne 6) {
        throw "Synthetic bundle merge returned an unexpected inventory: files=$($merge.FileCount), entryPoints=$(@($merge.EntryPoints).Count)"
    }
    [void]$assertions.Add('ThreeComponentExactMerge')

    $conflictApp = Join-Path $testRoot 'conflict-app'
    $conflictCore = Join-Path $testRoot 'conflict-core'
    $conflictDestination = Join-Path $testRoot 'conflict-destination'
    foreach ($root in @($conflictApp, $conflictCore, $conflictDestination)) {
        New-Item -ItemType Directory -Path $root -Force | Out-Null
    }
    Write-TestText -Path (Join-Path $conflictApp 'HerdrOps.App.dll') -Text 'app-dll'
    Write-TestText -Path (Join-Path $conflictApp 'HerdrOps.App.exe') -Text 'app-exe'
    Write-TestText -Path (Join-Path $conflictApp 'shared.bin') -Text 'first'
    Write-TestText -Path (Join-Path $conflictCore 'HerdrOps.Core.dll') -Text 'core-dll'
    Write-TestText -Path (Join-Path $conflictCore 'HerdrOps.Core.exe') -Text 'core-exe'
    Write-TestText -Path (Join-Path $conflictCore 'shared.bin') -Text 'second'
    Assert-ExpectedFailure -Description 'conflicting duplicate component bytes' -RequiredFragments @('byte-identical') -Action {
        Merge-V10PublishedComponents -Components @(
            [pscustomobject]@{ Name = 'App'; AssemblyName = 'HerdrOps.App'; PublishRoot = $conflictApp },
            [pscustomobject]@{ Name = 'Core'; AssemblyName = 'HerdrOps.Core'; PublishRoot = $conflictCore }) -DestinationRoot $conflictDestination | Out-Null
    }
    [void]$assertions.Add('ConflictingDuplicateRejected')

    $overlayRoots = [ordered]@{}
    foreach ($component in @($profile.components)) {
        $root = Join-Path $testRoot ('overlay-' + [string]$component.name)
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        Write-TestText -Path (Join-Path $root ([string]$component.assemblyName + '.dll')) -Text ("overlay-$($component.name)-dll")
        Write-TestText -Path (Join-Path $root ([string]$component.assemblyName + '.exe')) -Text ("overlay-$($component.name)-exe")
        Write-TestText `
            -Path (Join-Path $root 'Microsoft.VisualBasic.dll') `
            -Text $(if ([string]$component.name -ceq 'App') { 'canonical-windows-desktop-facade' } else { 'console-facade' })
        $overlayRoots[[string]$component.name] = [pscustomobject][ordered]@{
            Name = [string]$component.name
            AssemblyName = [string]$component.assemblyName
            PublishRoot = $root
        }
    }
    $overlayDestination = Join-Path $testRoot 'overlay-destination'
    New-Item -ItemType Directory -Path $overlayDestination -Force | Out-Null
    $overlayMerge = Merge-V10PublishedComponents `
        -Components @($overlayRoots.Values) `
        -DestinationRoot $overlayDestination `
        -CanonicalComponentName 'App' `
        -AllowedCanonicalConflictRelativePath @('Microsoft.VisualBasic.dll')
    if (@($overlayMerge.CanonicalConflictPaths).Count -ne 1 -or
        [IO.File]::ReadAllText((Join-Path $overlayDestination 'Microsoft.VisualBasic.dll')) -cne 'canonical-windows-desktop-facade') {
        throw 'The synthetic App-owned Windows Desktop runtime overlay was not preserved exactly.'
    }
    [void]$assertions.Add('CanonicalDesktopRuntimeOverlay')

    $wrongOrderDestination = Join-Path $testRoot 'overlay-wrong-order-destination'
    New-Item -ItemType Directory -Path $wrongOrderDestination -Force | Out-Null
    Assert-ExpectedFailure -Description 'canonical runtime component order' -RequiredFragments @('first merge input') -Action {
        Merge-V10PublishedComponents `
            -Components @($overlayRoots.Core, $overlayRoots.App, $overlayRoots.Cli) `
            -DestinationRoot $wrongOrderDestination `
            -CanonicalComponentName 'App' `
            -AllowedCanonicalConflictRelativePath @('Microsoft.VisualBasic.dll') | Out-Null
    }
    [void]$assertions.Add('CanonicalRuntimeOwnerRequired')

    $manifest = New-PackageManifestObject -Profile $profile -PackageRoot $packageSource
    Write-PackageManifest -Manifest $manifest -PackageRoot $packageSource | Out-Null
    $archiveSource = Join-Path $testRoot 'HerdrOps-1.0.0-win-x64.zip'
    $hashSource = Join-Path $testRoot 'package-hashes.txt'
    New-DeterministicPackageArchive -PackageRoot $packageSource -ArchivePath $archiveSource | Out-Null
    Write-PackageHashRecord -Profile $profile -PackageRoot $packageSource -ArchivePath $archiveSource -Path $hashSource | Out-Null
    $candidateRoot = Join-Path $testRoot 'candidate'
    $generation = Publish-PackageArtifactsAtomically `
        -Profile $profile `
        -PackageRoot $packageSource `
        -ArchivePath $archiveSource `
        -HashRecordPath $hashSource `
        -OutputRoot $candidateRoot

$sourceCommit = ('a' * 40) # Synthetic fixture identity; production verification reads the real commit.
    $candidateRecord = New-V10CandidateRecord `
        -Profile $profile `
        -RepositoryRoot $repositoryRoot `
        -ProfilePath $profilePath `
        -SourceCommit $sourceCommit `
        -Generation $generation `
        -GeneratedAtUtc '2026-08-17T00:00:00.0000000Z'
    $candidateRecordPath = Join-Path $candidateRoot 'release-candidate.json'
    Write-V10NewJsonFile -Path $candidateRecordPath -Value $candidateRecord | Out-Null
    $candidate = Assert-V10CandidateRecord `
        -CandidateRecordPath $candidateRecordPath `
        -RepositoryRoot $repositoryRoot `
        -ExpectedSourceCommit $sourceCommit `
        -ProfilePath $profilePath
    [void]$assertions.Add('CandidateExactBytes')

    $originalArchiveBytes = [IO.File]::ReadAllBytes($candidate.ArchivePath)
    try {
        $tamperedArchiveBytes = New-Object byte[] ($originalArchiveBytes.Length + 1)
        [Array]::Copy($originalArchiveBytes, $tamperedArchiveBytes, $originalArchiveBytes.Length)
        $tamperedArchiveBytes[$tamperedArchiveBytes.Length - 1] = 1
        [IO.File]::WriteAllBytes($candidate.ArchivePath, $tamperedArchiveBytes)
        Assert-ExpectedFailure -Description 'candidate archive byte tamper' -RequiredFragments @('metadata', 'bytes') -Action {
            Assert-V10CandidateRecord -CandidateRecordPath $candidateRecordPath -RepositoryRoot $repositoryRoot -ExpectedSourceCommit $sourceCommit -ProfilePath $profilePath | Out-Null
        }
    } finally {
        [IO.File]::WriteAllBytes($candidate.ArchivePath, $originalArchiveBytes)
    }
    $candidate = Assert-V10CandidateRecord -CandidateRecordPath $candidateRecordPath -RepositoryRoot $repositoryRoot -ExpectedSourceCommit $sourceCommit -ProfilePath $profilePath
    [void]$assertions.Add('CandidateTamperRejected')

    $evidenceRoot = Join-Path $testRoot 'evidence'
    New-Item -ItemType Directory -Path $evidenceRoot -Force | Out-Null
    $issue41Path = Join-Path $evidenceRoot 'issue-41.json'
    $issue42Path = Join-Path $evidenceRoot 'issue-42.json'
    $issue43Path = Join-Path $evidenceRoot 'issue-43.json'
    $issue44Path = Join-Path $evidenceRoot 'issue-44.json'
    $issue44LiveShapePath = Join-Path $evidenceRoot 'issue-44-live-shape.json'
    Write-V10NewJsonFile -Path $issue41Path -Value ([ordered]@{
            SchemaVersion = 1
            AuditId = 'V100-01'
            SourceCommit = $sourceCommit
            WorkingTree = 'CLEAN'
            Decision = 'READY'
            ReleaseCandidate = [ordered]@{ Status = 'RECORDED'; Commit = $sourceCommit }
            Query = [ordered]@{ Source = 'GitHub gh api (read-only)' }
            Blockers = @()
        }) | Out-Null
    Write-V10NewJsonFile -Path $issue42Path -Value ([ordered]@{
            schemaVersion = 1
            reportKind = 'HerdrOps.V10SoakAcceptanceReport'
            issue = 42
            acceptanceVersion = 'v1.0.0'
            status = 'PASS'
            evidenceClass = 'Runtime'
            sourceCommit = $sourceCommit
            candidateArchiveSha256 = $candidate.ArchiveSha256
            durationHours = 24
            actualHerdrObserved = $true
            unhandledCrashes = 0
            unreconciledStates = 0
            reconnectResult = 'PASS'
            faultInjectionResult = 'PASS'
            databaseIntegrityResult = 'PASS'
            alertConsistencyResult = 'PASS'
            completedAtUtc = '2026-08-17T00:20:00.0000000Z'
        }) | Out-Null
    Write-V10NewJsonFile -Path $issue43Path -Value ([ordered]@{
            schemaVersion = 1
            reportKind = 'HerdrOps.V10SecurityPrivacyReviewReport'
            issue = 43
            reviewVersion = 'v1.0.0'
            status = 'PASS'
            evidenceClass = 'IndependentReview'
            sourceCommit = $sourceCommit
            candidateArchiveSha256 = $candidate.ArchiveSha256
            verdict = 'PASS'
            unresolvedHighFindings = 0
            reviewer = 'Synthetic Reviewer Fixture'
            completedAtUtc = '2026-08-17T00:30:00.0000000Z'
        }) | Out-Null
    $issue44SyntheticValue = New-TestIssue44Report `
        -SourceCommit $sourceCommit `
        -ArchiveSha256 ([string]$candidate.Record.generation.archiveSha256) `
        -ManifestSha256 ([string]$candidate.Record.generation.manifestSha256) `
        -ContentSha256 ([string]$candidate.Record.generation.contentSha256)
    Write-V10NewJsonFile -Path $issue44Path -Value $issue44SyntheticValue | Out-Null
    $issue44SyntheticReport = Read-V10StrictJsonFile -Path $issue44Path -Description 'Issue #44 complete synthetic report'
    Assert-V10Issue44ReportSemantics `
        -Report $issue44SyntheticReport.Value `
        -SourceCommit $sourceCommit `
        -ArchiveSha256 ([string]$candidate.Record.generation.archiveSha256) `
        -ManifestSha256 ([string]$candidate.Record.generation.manifestSha256) `
        -ContentSha256 ([string]$candidate.Record.generation.contentSha256)
    [void]$assertions.Add('Issue44FullSyntheticSchemaAndSemantics')
    Assert-ExpectedFailure -Description 'synthetic Issue #44 cannot claim CleanMachine' -RequiredFragments @('Live CleanMachine') -Action {
        Assert-V10GateReport `
            -Issue 44 `
            -EvidenceClass 'CleanMachine' `
            -Report $issue44SyntheticReport `
            -SourceCommit $sourceCommit `
            -ArchiveSha256 ([string]$candidate.Record.generation.archiveSha256) `
            -ManifestSha256 ([string]$candidate.Record.generation.manifestSha256) `
            -ContentSha256 ([string]$candidate.Record.generation.contentSha256)
    }
    [void]$assertions.Add('SyntheticIssue44NeverGrantedCleanMachine')
    $minimalIssue44Report = [pscustomobject]@{
        Value = [pscustomobject][ordered]@{
            schemaVersion = 1
            reportKind = 'HerdrOps.InstallAcceptanceReport'
            issue = 44
            acceptanceVersion = 'v1.0.0'
            status = 'PASS'
            mode = 'Live'
            evidenceClass = 'CleanMachine'
        }
    }
    Assert-ExpectedFailure -Description 'minimal forged Issue #44 report' -RequiredFragments @('acceptance report') -Action {
        Assert-V10GateReport `
            -Issue 44 `
            -EvidenceClass 'CleanMachine' `
            -Report $minimalIssue44Report `
            -SourceCommit $sourceCommit `
            -ArchiveSha256 ([string]$candidate.Record.generation.archiveSha256) `
            -ManifestSha256 ([string]$candidate.Record.generation.manifestSha256) `
            -ContentSha256 ([string]$candidate.Record.generation.contentSha256)
    }
    [void]$assertions.Add('Issue44MinimalForgedReportRejected')
    $issue44LiveShapeValue = New-TestIssue44Report `
        -SourceCommit $sourceCommit `
        -ArchiveSha256 ([string]$candidate.Record.generation.archiveSha256) `
        -ManifestSha256 ([string]$candidate.Record.generation.manifestSha256) `
        -ContentSha256 ([string]$candidate.Record.generation.contentSha256) `
        -LiveShape
    Write-V10NewJsonFile -Path $issue44LiveShapePath -Value $issue44LiveShapeValue | Out-Null
    $issue44LiveShapeReport = Read-V10StrictJsonFile -Path $issue44LiveShapePath -Description 'Issue #44 complete live report shape'
    Assert-V10GateReport `
        -Issue 44 `
        -EvidenceClass 'CleanMachine' `
        -Report $issue44LiveShapeReport `
        -SourceCommit $sourceCommit `
        -ArchiveSha256 ([string]$candidate.Record.generation.archiveSha256) `
        -ManifestSha256 ([string]$candidate.Record.generation.manifestSha256) `
        -ContentSha256 ([string]$candidate.Record.generation.contentSha256)
    [void]$assertions.Add('Issue44CompleteLiveShapeAcceptedSynthetically')

    $missingInitialArtifact = Copy-TestJsonObject -Value $issue44LiveShapeValue
    $missingInitialArtifact.artifacts.initial = $null
    Assert-ExpectedFailure -Description 'Issue #44 missing initial artifact' -RequiredFragments @('artifacts') -Action {
        Assert-V10Issue44ReportSemantics `
            -Report $missingInitialArtifact `
            -SourceCommit $sourceCommit `
            -ArchiveSha256 ([string]$candidate.Record.generation.archiveSha256) `
            -ManifestSha256 ([string]$candidate.Record.generation.manifestSha256) `
            -ContentSha256 ([string]$candidate.Record.generation.contentSha256) `
            -RequireLiveCleanMachine
    }
    [void]$assertions.Add('Issue44MissingInitialArtifactRejected')

    $wrongInitialArtifact = Copy-TestJsonObject -Value $issue44LiveShapeValue
    $wrongInitialArtifact.artifacts.initial.packageVersion = '9.9.9'
    Assert-ExpectedFailure -Description 'Issue #44 wrong initial artifact identity' -RequiredFragments @('initial artifact identity') -Action {
        Assert-V10Issue44ReportSemantics `
            -Report $wrongInitialArtifact `
            -SourceCommit $sourceCommit `
            -ArchiveSha256 ([string]$candidate.Record.generation.archiveSha256) `
            -ManifestSha256 ([string]$candidate.Record.generation.manifestSha256) `
            -ContentSha256 ([string]$candidate.Record.generation.contentSha256) `
            -RequireLiveCleanMachine
    }
    [void]$assertions.Add('Issue44WrongInitialArtifactRejected')

    $failedPreflight = Copy-TestJsonObject -Value $issue44LiveShapeValue
    $failedPreflight.preflight.status = 'FAIL'
    Assert-ExpectedFailure -Description 'Issue #44 failed preflight' -RequiredFragments @('preflight') -Action {
        Assert-V10Issue44ReportSemantics `
            -Report $failedPreflight `
            -SourceCommit $sourceCommit `
            -ArchiveSha256 ([string]$candidate.Record.generation.archiveSha256) `
            -ManifestSha256 ([string]$candidate.Record.generation.manifestSha256) `
            -ContentSha256 ([string]$candidate.Record.generation.contentSha256) `
            -RequireLiveCleanMachine
    }
    [void]$assertions.Add('Issue44FailedPreflightRejected')

    $failedBoundary = Copy-TestJsonObject -Value $issue44LiveShapeValue
    $failedBoundary.boundaries.cleanMachine = 'NOT OBSERVED: synthetic only.'
    Assert-ExpectedFailure -Description 'Issue #44 failed CleanMachine boundary' -RequiredFragments @('boundary') -Action {
        Assert-V10Issue44ReportSemantics `
            -Report $failedBoundary `
            -SourceCommit $sourceCommit `
            -ArchiveSha256 ([string]$candidate.Record.generation.archiveSha256) `
            -ManifestSha256 ([string]$candidate.Record.generation.manifestSha256) `
            -ContentSha256 ([string]$candidate.Record.generation.contentSha256) `
            -RequireLiveCleanMachine
    }
    [void]$assertions.Add('Issue44FailedBoundaryRejected')

    $residuals = Copy-TestJsonObject -Value $issue44LiveShapeValue
    $residuals.cleanup.residuals = @('owned-backup-directory')
    Assert-ExpectedFailure -Description 'Issue #44 cleanup residual' -RequiredFragments @('residuals') -Action {
        Assert-V10Issue44ReportSemantics `
            -Report $residuals `
            -SourceCommit $sourceCommit `
            -ArchiveSha256 ([string]$candidate.Record.generation.archiveSha256) `
            -ManifestSha256 ([string]$candidate.Record.generation.manifestSha256) `
            -ContentSha256 ([string]$candidate.Record.generation.contentSha256) `
            -RequireLiveCleanMachine
    }
    [void]$assertions.Add('Issue44CleanupResidualRejected')

    $emptyHashes = Copy-TestJsonObject -Value $issue44LiveShapeValue
    $emptyHashes.artifacts.upgrade.installedFileHashes = @()
    Assert-ExpectedFailure -Description 'Issue #44 empty installed hashes' -RequiredFragments @('installedFileHashes') -Action {
        Assert-V10Issue44ReportSemantics `
            -Report $emptyHashes `
            -SourceCommit $sourceCommit `
            -ArchiveSha256 ([string]$candidate.Record.generation.archiveSha256) `
            -ManifestSha256 ([string]$candidate.Record.generation.manifestSha256) `
            -ContentSha256 ([string]$candidate.Record.generation.contentSha256) `
            -RequireLiveCleanMachine
    }
    [void]$assertions.Add('Issue44EmptyInstalledHashesRejected')

    $wrongHash = Copy-TestJsonObject -Value $issue44LiveShapeValue
    $wrongHash.artifacts.upgrade.archiveSha256 = New-TestHex64 -Character '0'
    Assert-ExpectedFailure -Description 'Issue #44 wrong artifact hash' -RequiredFragments @('all-zero') -Action {
        Assert-V10Issue44ReportSemantics `
            -Report $wrongHash `
            -SourceCommit $sourceCommit `
            -ArchiveSha256 ([string]$candidate.Record.generation.archiveSha256) `
            -ManifestSha256 ([string]$candidate.Record.generation.manifestSha256) `
            -ContentSha256 ([string]$candidate.Record.generation.contentSha256) `
            -RequireLiveCleanMachine
    }
    [void]$assertions.Add('Issue44WrongArtifactHashRejected')

    $wrongMachineBinding = Copy-TestJsonObject -Value $issue44LiveShapeValue
    $wrongMachineBinding.machine.expectedName = 'OTHER-HOST'
    Assert-ExpectedFailure -Description 'Issue #44 wrong machine binding' -RequiredFragments @('machine identity') -Action {
        Assert-V10Issue44ReportSemantics `
            -Report $wrongMachineBinding `
            -SourceCommit $sourceCommit `
            -ArchiveSha256 ([string]$candidate.Record.generation.archiveSha256) `
            -ManifestSha256 ([string]$candidate.Record.generation.manifestSha256) `
            -ContentSha256 ([string]$candidate.Record.generation.contentSha256) `
            -RequireLiveCleanMachine
    }
    [void]$assertions.Add('Issue44WrongMachineBindingRejected')

    $wrongSourceBinding = Copy-TestJsonObject -Value $issue44LiveShapeValue
    $wrongSourceBinding.artifacts.upgrade.sourceCommitBinding = (('b' * 40) -join '')
    Assert-ExpectedFailure -Description 'Issue #44 wrong source binding' -RequiredFragments @('sourceCommitBinding') -Action {
        Assert-V10Issue44ReportSemantics `
            -Report $wrongSourceBinding `
            -SourceCommit $sourceCommit `
            -ArchiveSha256 ([string]$candidate.Record.generation.archiveSha256) `
            -ManifestSha256 ([string]$candidate.Record.generation.manifestSha256) `
            -ContentSha256 ([string]$candidate.Record.generation.contentSha256) `
            -RequireLiveCleanMachine
    }
    [void]$assertions.Add('Issue44WrongSourceBindingRejected')

    $candidateRelative = Get-TestRelativePath -Path $candidateRecordPath -Root $repositoryRoot
    $releaseNotesPath = Join-Path $repositoryRoot 'docs\release\v1.0.0\release-notes.en.md'
    $authorization = [ordered]@{
        schemaVersion = 1
        reportKind = 'HerdrOps.ReleaseAuthorization'
        issue = 45
        repository = 'OSHEThai/HerdrOps'
        releaseVersion = 'v1.0.0'
        releaseTag = 'v1.0.0'
        acceptedCommit = $sourceCommit
        candidateRecord = [ordered]@{
            path = $candidateRelative
            sha256 = $candidate.RecordSha256
            archiveSha256 = $candidate.ArchiveSha256
        }
        gates = @(
            [ordered]@{ issue = 41; evidenceClass = 'ReleaseAudit'; status = 'PASS'; reportPath = (Get-TestRelativePath -Path $issue41Path -Root $repositoryRoot); reportSha256 = ((Get-FileHash $issue41Path -Algorithm SHA256).Hash); sourceCommit = $sourceCommit; archiveSha256 = $candidate.ArchiveSha256; authority = 'Synthetic PM Fixture'; observedAtUtc = '2026-08-17T00:10:00.0000000Z' },
            [ordered]@{ issue = 42; evidenceClass = 'Runtime'; status = 'PASS'; reportPath = (Get-TestRelativePath -Path $issue42Path -Root $repositoryRoot); reportSha256 = ((Get-FileHash $issue42Path -Algorithm SHA256).Hash); sourceCommit = $sourceCommit; archiveSha256 = $candidate.ArchiveSha256; authority = 'Synthetic Runtime Fixture'; observedAtUtc = '2026-08-17T00:20:00.0000000Z' },
            [ordered]@{ issue = 43; evidenceClass = 'IndependentReview'; status = 'PASS'; reportPath = (Get-TestRelativePath -Path $issue43Path -Root $repositoryRoot); reportSha256 = ((Get-FileHash $issue43Path -Algorithm SHA256).Hash); sourceCommit = $sourceCommit; archiveSha256 = $candidate.ArchiveSha256; authority = 'Synthetic Reviewer Fixture'; observedAtUtc = '2026-08-17T00:30:00.0000000Z' },
            [ordered]@{ issue = 44; evidenceClass = 'CleanMachine'; status = 'PASS'; reportPath = (Get-TestRelativePath -Path $issue44LiveShapePath -Root $repositoryRoot); reportSha256 = ((Get-FileHash $issue44LiveShapePath -Algorithm SHA256).Hash); sourceCommit = $sourceCommit; archiveSha256 = $candidate.ArchiveSha256; authority = 'Synthetic Acceptance Fixture'; observedAtUtc = '2026-08-17T00:40:00.0000000Z' })
        goNoGo = [ordered]@{
            decision = 'GO'
            approver = 'Synthetic Product Owner Fixture'
            approvedAtUtc = '2026-08-17T00:50:00.0000000Z'
            statement = $script:V10GoNoGoStatement
            acceptedCommit = $sourceCommit
            archiveSha256 = $candidate.ArchiveSha256
        }
        releaseNotes = [ordered]@{
            path = 'docs/release/v1.0.0/release-notes.en.md'
            sha256 = ((Get-FileHash -LiteralPath $releaseNotesPath -Algorithm SHA256).Hash).ToUpperInvariant()
        }
        publication = [ordered]@{
            status = 'NOT_PUBLISHED'
            releaseUrl = ''
            publishedArchiveSha256 = ''
            publishedHashRecordSha256 = ''
        }
    }
    $authorizationPath = Join-Path $testRoot 'authorization.json'
    Write-V10NewJsonFile -Path $authorizationPath -Value $authorization | Out-Null
    $authorizationResult = Assert-V10ReleaseAuthorization `
        -AuthorizationPath $authorizationPath `
        -RepositoryRoot $repositoryRoot `
        -ExpectedSourceCommit $sourceCommit `
        -ProfilePath $profilePath
    if ($authorizationResult.Status -cne 'READY_TO_PUBLISH' -or
        $authorizationResult.Decision -cne 'GO' -or
        $authorizationResult.Release -cne 'NOT OBSERVED') {
        throw 'Synthetic complete authorization did not return the expected pre-publication boundary.'
    }
    [void]$assertions.Add('CompleteBindingAcceptedSynthetically')

    $pendingAuthorization = Copy-TestJsonObject -Value $authorization
    $pendingAuthorization.goNoGo.decision = 'NO-GO'
    $pendingPath = Join-Path $testRoot 'authorization-pending.json'
    Write-V10NewJsonFile -Path $pendingPath -Value $pendingAuthorization | Out-Null
    Assert-ExpectedFailure -Description 'NO-GO cannot publish' -RequiredFragments @('go/no-go') -Action {
        Assert-V10ReleaseAuthorization -AuthorizationPath $pendingPath -RepositoryRoot $repositoryRoot -ExpectedSourceCommit $sourceCommit -ProfilePath $profilePath | Out-Null
    }
    [void]$assertions.Add('NoGoRejected')

    $hashMismatch = Copy-TestJsonObject -Value $authorization
    $hashMismatch.candidateRecord.archiveSha256 = (('0' * 64) -join '')
    $hashMismatchPath = Join-Path $testRoot 'authorization-hash-mismatch.json'
    Write-V10NewJsonFile -Path $hashMismatchPath -Value $hashMismatch | Out-Null
    Assert-ExpectedFailure -Description 'candidate hash mismatch' -RequiredFragments @('hash') -Action {
        Assert-V10ReleaseAuthorization -AuthorizationPath $hashMismatchPath -RepositoryRoot $repositoryRoot -ExpectedSourceCommit $sourceCommit -ProfilePath $profilePath | Out-Null
    }
    [void]$assertions.Add('AuthorizationHashMismatchRejected')

    $shortSoakReport = Copy-TestJsonObject -Value (Read-V10StrictJsonFile -Path $issue42Path -Description 'Issue #42 synthetic source').Value
    $shortSoakReport.durationHours = [decimal]23.99
    $shortSoakPath = Join-Path $evidenceRoot 'issue-42-short.json'
    Write-V10NewJsonFile -Path $shortSoakPath -Value $shortSoakReport | Out-Null
    $shortSoakAuthorization = Copy-TestJsonObject -Value $authorization
    $shortSoakAuthorization.gates[1].reportPath = Get-TestRelativePath -Path $shortSoakPath -Root $repositoryRoot
    $shortSoakAuthorization.gates[1].reportSha256 = ((Get-FileHash -LiteralPath $shortSoakPath -Algorithm SHA256).Hash).ToUpperInvariant()
    $shortSoakAuthorizationPath = Join-Path $testRoot 'authorization-short-soak.json'
    Write-V10NewJsonFile -Path $shortSoakAuthorizationPath -Value $shortSoakAuthorization | Out-Null
    Assert-ExpectedFailure -Description 'short soak cannot authorize release' -RequiredFragments @('24-hour') -Action {
        Assert-V10ReleaseAuthorization -AuthorizationPath $shortSoakAuthorizationPath -RepositoryRoot $repositoryRoot -ExpectedSourceCommit $sourceCommit -ProfilePath $profilePath | Out-Null
    }
    [void]$assertions.Add('ShortRuntimeSoakRejected')

    $fixtureInstallReport = Copy-TestJsonObject -Value (Read-V10StrictJsonFile -Path $issue44Path -Description 'Issue #44 synthetic source').Value
    $fixtureInstallReport.mode = 'Fixture'
    $fixtureInstallPath = Join-Path $evidenceRoot 'issue-44-fixture.json'
    Write-V10NewJsonFile -Path $fixtureInstallPath -Value $fixtureInstallReport | Out-Null
    $fixtureInstallAuthorization = Copy-TestJsonObject -Value $authorization
    $fixtureInstallAuthorization.gates[3].reportPath = Get-TestRelativePath -Path $fixtureInstallPath -Root $repositoryRoot
    $fixtureInstallAuthorization.gates[3].reportSha256 = ((Get-FileHash -LiteralPath $fixtureInstallPath -Algorithm SHA256).Hash).ToUpperInvariant()
    $fixtureInstallAuthorizationPath = Join-Path $testRoot 'authorization-fixture-install.json'
    Write-V10NewJsonFile -Path $fixtureInstallAuthorizationPath -Value $fixtureInstallAuthorization | Out-Null
    Assert-ExpectedFailure -Description 'fixture install cannot authorize release' -RequiredFragments @('Live CleanMachine') -Action {
        Assert-V10ReleaseAuthorization -AuthorizationPath $fixtureInstallAuthorizationPath -RepositoryRoot $repositoryRoot -ExpectedSourceCommit $sourceCommit -ProfilePath $profilePath | Out-Null
    }
    [void]$assertions.Add('FixtureInstallRejected')

    $duplicateJsonPath = Join-Path $testRoot 'authorization-duplicate.json'
    Write-TestText -Path $duplicateJsonPath -Text '{"schemaVersion":1,"schemaVersion":1}'
    Assert-ExpectedFailure -Description 'duplicate authorization property' -RequiredFragments @('Duplicate') -Action {
        Read-V10StrictJsonFile -Path $duplicateJsonPath -Description 'duplicate authorization fixture' | Out-Null
    }
    [void]$assertions.Add('DuplicateJsonRejected')

    $englishDocuments = @(Get-ChildItem -LiteralPath (Join-Path $repositoryRoot 'docs\release\v1.0.0') -Filter '*.en.md')
    $thaiDocuments = @(Get-ChildItem -LiteralPath (Join-Path $repositoryRoot 'docs\release\v1.0.0') -Filter '*.th.md')
    if ($englishDocuments.Count -ne 4 -or $thaiDocuments.Count -ne 4) {
        throw "Release documentation must contain exactly four English and four Thai files; observed English=$($englishDocuments.Count), Thai=$($thaiDocuments.Count)."
    }
    foreach ($englishDocument in $englishDocuments) {
        if ([IO.File]::ReadAllText($englishDocument.FullName) -match '[\u0E00-\u0E7F]') {
            throw "English release document contains Thai text: $($englishDocument.FullName)"
        }
    }
    foreach ($thaiDocument in $thaiDocuments) {
        if ([IO.File]::ReadAllText($thaiDocument.FullName) -notmatch '[\u0E00-\u0E7F]') {
            throw "Thai release document contains no Thai text: $($thaiDocument.FullName)"
        }
    }
    [void]$assertions.Add('LanguageFilesSeparated')

    $authorizationSchemaPath = Join-Path $repositoryRoot 'docs\release\v1.0.0\release-authorization.schema.json'
    $authorizationExamplePath = Join-Path $repositoryRoot 'docs\release\v1.0.0\release-authorization.example.json'
    $authorizationSchema = Read-V10StrictJsonFile -Path $authorizationSchemaPath -Description 'release authorization schema'
    $authorizationExample = Read-V10StrictJsonFile -Path $authorizationExamplePath -Description 'release authorization example'
    if ($null -ne (Get-Command Test-Json -ErrorAction SilentlyContinue)) {
        if (-not ($authorizationExample.Raw | Test-Json -SchemaFile $authorizationSchema.Path -ErrorAction Stop)) {
            throw 'Release authorization example does not satisfy its Draft-07 schema.'
        }
    }
    [void]$assertions.Add('AuthorizationSchemaAndPendingExample')

    $readinessSource = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Invoke-V10ReleaseReadiness.ps1'))
    foreach ($forbidden in @('gh release', 'git tag', 'git push', 'dotnet publish', 'Start-Process')) {
        if ($readinessSource.IndexOf($forbidden, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            throw "Readiness verifier contains a forbidden mutation/build command: $forbidden"
        }
    }
    [void]$assertions.Add('ReadinessHasNoPublicationOrBuild')

    $ciWorkflowPath = Join-Path $repositoryRoot '.github\workflows\ci.yml'
    $ciWorkflow = [IO.File]::ReadAllText($ciWorkflowPath)
    $ciWorkflowNormalized = $ciWorkflow.Replace("`r`n", "`n")
    $authorizedReportPath = 'artifacts/release-gates/v1.0.0/issue-45'
    foreach ($legacyReportRoot in @('artifacts/release-readiness-gates', 'artifacts\release-readiness-gates')) {
        if ($ciWorkflow.IndexOf($legacyReportRoot, [StringComparison]::Ordinal) -ge 0) {
            throw "CI still contains the unauthorized legacy Issue #45 report path: $legacyReportRoot"
        }
    }
    if ([regex]::Matches($ciWorkflow, [regex]::Escape($authorizedReportPath)).Count -ne 3) {
        throw 'CI must contain the authorized Issue #45 report path exactly three times (two report roots and one upload path).'
    }
    [void]$assertions.Add('CiUsesAuthorizedReleaseGatePath')

    $ps7ReadinessStep = "      - name: 'Run v1.0 release-readiness preparation gate (Issue #45) - Static/Synthetic - PowerShell 7 (pwsh)'`n        if: always()"
    $ps5ReadinessStep = "      - name: 'Run v1.0 release-readiness preparation gate (Issue #45) - Static/Synthetic - Windows PowerShell 5.1'`n        if: always()"
    foreach ($stepMarker in @($ps7ReadinessStep, $ps5ReadinessStep)) {
        if ($ciWorkflowNormalized.IndexOf($stepMarker, [StringComparison]::Ordinal) -lt 0) {
            throw 'Both Issue #45 readiness steps must use equivalent fail-closed if: always() semantics.'
        }
    }
    [void]$assertions.Add('CiReadinessStepsAlways')

    $toolsReadme = [IO.File]::ReadAllText((Join-Path $repositoryRoot 'tools\README.md'))
    foreach ($requiredEntry in @(
        './tools/Test-V03ImplementationGateTests.ps1',
        './tools/Test-V03ImplementationGate.ps1 -Configuration Release'
    )) {
        if ($toolsReadme.IndexOf($requiredEntry, [StringComparison]::Ordinal) -lt 0) {
            throw "tools/README.md is missing the Issue #17 implementation gate entry: $requiredEntry"
        }
    }
    [void]$assertions.Add('ToolsReadmeRestoresIssue17')

    foreach ($requiredEntry in @(
        './tools/Test-V10Issue42SoakContract.ps1',
        '-CandidateArchivePath ''<candidate-archive>''',
        '-CandidateArchiveSha256 ''<64-hex>''',
        '-CandidateArchiveBytes <bytes>'
    )) {
        if ($toolsReadme.IndexOf($requiredEntry, [StringComparison]::Ordinal) -lt 0) {
            throw "tools/README.md is missing the Issue #42 soak-contract entry: $requiredEntry"
        }
    }
    [void]$assertions.Add('ToolsReadmeRestoresIssue42')
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        $fullTestRoot = Normalize-ComparablePath -Path $testRoot
        if (-not (Test-PathWithin -ChildPath $fullTestRoot -RootPath $ownedParent) -or
            $fullTestRoot.Equals($ownedParent, [StringComparison]::OrdinalIgnoreCase) -or
            [IO.Path]::GetFileName($fullTestRoot) -cnotmatch '^[0-9a-f]{32}$') {
            throw "Refusing to remove an unsafe release-readiness test root: $fullTestRoot"
        }
        Assert-NoReparsePath -Path $fullTestRoot
        Assert-NoReparseDescendants -Path $fullTestRoot
        Remove-Item -LiteralPath $fullTestRoot -Recurse -Force
    }
}

[pscustomobject][ordered]@{
    EvidenceClass = 'Static/Synthetic'
    Issue = 45
    PowerShellEdition = [string]$PSVersionTable.PSEdition
    PowerShellVersion = [string]$PSVersionTable.PSVersion
    Assertions = @($assertions.ToArray())
    AssertionCount = $assertions.Count
    Profile = 'PASS'
    ThreeComponentBundle = 'PASS'
    ExactCandidateBytes = 'PASS'
    FailClosedAuthorization = 'PASS'
    LanguageSeparation = 'PASS'
    PublicationMutation = 'NOT PERFORMED'
    Contract = 'NOT OBSERVED'
    CleanMachine = 'NOT OBSERVED'
    Runtime = 'NOT OBSERVED'
    IndependentReview = 'NOT OBSERVED'
    Human = 'NOT OBSERVED'
    Release = 'NOT OBSERVED'
}
