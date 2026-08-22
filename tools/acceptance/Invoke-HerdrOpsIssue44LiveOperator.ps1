#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$BindingPath,

    [Parameter(Mandatory = $false)]
    [string]$InitialArchivePath,

    [Parameter(Mandatory = $false)]
    [long]$InitialArchiveBytes = 0,

    [Parameter(Mandatory = $false)]
    [string]$InitialArchiveSha256,

    [Parameter(Mandatory = $false)]
    [string]$InitialManifestSha256,

    [Parameter(Mandatory = $false)]
    [string]$InitialContentSha256,

    [Parameter(Mandatory = $false)]
    [string]$InitialPackageVersion = '0.7.0',

    [Parameter(Mandatory = $false)]
    [string]$InitialSourceCommit,

    [Parameter(Mandatory = $false)]
    [string]$CandidateArchivePath,

    [Parameter(Mandatory = $false)]
    [long]$CandidateArchiveBytes = 0,

    [Parameter(Mandatory = $false)]
    [string]$CandidateArchiveSha256,

    [Parameter(Mandatory = $false)]
    [string]$CandidateManifestSha256,

    [Parameter(Mandatory = $false)]
    [string]$CandidateContentSha256,

    [Parameter(Mandatory = $false)]
    [string]$CandidatePackageVersion = '1.0.0',

    [Parameter(Mandatory = $false)]
    [string]$CandidateSourceCommit,

    [Parameter(Mandatory = $false)]
    [string]$ExpectedSourceCommit,

    [Parameter(Mandatory = $false)]
    [string]$ExpectedSourceTree,

    [Parameter(Mandatory = $false)]
    [string]$ExpectedParentCommit,

    [Parameter(Mandatory = $false)]
    [string]$ExpectedMachineName,

    [Parameter(Mandatory = $false)]
    [string]$ExpectedMachineFingerprint,

    # Accepted-Beta provenance inputs
    [Parameter(Mandatory = $false)]
    [string]$BetaReportPath,

    [Parameter(Mandatory = $false)]
    [long]$BetaReportBytes = 0,

    [Parameter(Mandatory = $false)]
    [string]$BetaReportSha256,

    [Parameter(Mandatory = $false)]
    [string]$BetaReportStatus = 'ACCEPTED',

    [Parameter(Mandatory = $false)]
    [string]$BetaReportSourceCommit,

    [Parameter(Mandatory = $false)]
    [string]$BetaReportSourceTree,

    [Parameter(Mandatory = $false)]
    [string]$InstallRoot,

    [Parameter(Mandatory = $false)]
    [string]$UserDataRoot,

    [Parameter(Mandatory = $false)]
    [string]$SimulationRoot,

    [Parameter(Mandatory = $false)]
    [string]$ReportDestination,

    [Parameter(Mandatory = $false)]
    [string]$RetainedDataRelativePath = 'state\issue-44-harness.marker',

    [Parameter(Mandatory = $false)]
    [string]$RetainedDataSha256,

    [Parameter(Mandatory = $false)]
    [ValidateSet('create-test-marker', 'preseeded')]
    [string]$RetainedDataMode = 'create-test-marker',

    [Parameter(Mandatory = $false)]
    [scriptblock]$InstallerRunner,

    [Parameter(Mandatory = $false)]
    [scriptblock]$FirstRunRunner,

    [Parameter(Mandatory = $false)]
    [switch]$IUnderstandLiveMutation,

    [Parameter(Mandatory = $false)]
    [string]$LiveConfirmationToken,

    [Parameter(Mandatory = $false)]
    [switch]$AllowLiveRetainedDataSeed,

    [Parameter(Mandatory = $false)]
    [ValidateSet('Live', 'Fixture', 'DryRun')]
    [string]$Mode = 'Live'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$acceptanceCommonPath = Join-Path $PSScriptRoot 'HerdrOps.InstallAcceptance.Common.ps1'
if (-not (Test-Path -LiteralPath $acceptanceCommonPath -PathType Leaf)) {
    throw "HerdrOps acceptance common library is missing: $acceptanceCommonPath"
}
. $acceptanceCommonPath

$installerCommonPath = Join-Path $PSScriptRoot '..\installer\Installer.Common.ps1'
if (-not (Test-Path -LiteralPath $installerCommonPath -PathType Leaf)) {
    throw "Installer common library is missing: $installerCommonPath"
}
. $installerCommonPath

$processCleanupPath = Join-Path $PSScriptRoot '..\lib\V04ProcessCleanup.ps1'
if (Test-Path -LiteralPath $processCleanupPath -PathType Leaf) {
    . $processCleanupPath
}

$script:AcceptanceIssue = 44
$script:AcceptanceVersion = 'v1.0.0'
$script:LiveTokenValue = 'HERDROPS-ISSUE-44-LIVE-FILESYSTEM'
$script:RunId = [Guid]::NewGuid().ToString('N')
$script:StartedAtUtc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ', [Globalization.CultureInfo]::InvariantCulture)
$script:Transcript = New-Object System.Collections.ArrayList
$script:PreflightChecks = New-Object System.Collections.ArrayList
$script:CleanMachineFilesystemObserved = $false
$script:TranscriptSequence = 1
$script:OwnedStagingDirectory = $null
$script:OwnedSimulationDirectory = $null

function Add-OperatorTranscript {
    param(
        [Parameter(Mandatory = $true)][string]$Phase,
        [Parameter(Mandatory = $true)][string]$Action,
        [Parameter(Mandatory = $true)][ValidateSet('PASS', 'FAIL', 'SKIPPED', 'CANCELLED', 'NOT_RUN')][string]$Status,
        [Parameter(Mandatory = $true)][ValidateSet('None', 'FixtureTempOnly', 'LiveFilesystem')][string]$Effect,
        [Parameter(Mandatory = $true)][string]$Details,
        [Parameter(Mandatory = $true)][string]$PathBinding
    )

    [void]$script:Transcript.Add([ordered]@{
        sequence = $script:TranscriptSequence
        phase = $Phase
        action = $Action
        status = $Status
        effect = $Effect
        details = $Details
        pathBinding = $PathBinding
    })
    $script:TranscriptSequence++
}

function Add-OperatorPreflightCheck {
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

function Get-OperatorUtcNow {
    return [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ', [Globalization.CultureInfo]::InvariantCulture)
}

function Get-FileSha256AndBytes {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "File not found: $Path"
    }
    $bytes = [IO.File]::ReadAllBytes($Path)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha256.ComputeHash($bytes)
        $hashHex = ([BitConverter]::ToString($hashBytes)).Replace('-', '').ToUpperInvariant()
    } finally {
        $sha256.Dispose()
    }
    return [pscustomobject][ordered]@{
        Bytes = $bytes
        Length = [int64]$bytes.Length
        Sha256 = $hashHex
    }
}

function Assert-RunnerResultPass {
    param(
        $Result,
        [Parameter(Mandatory = $true)][string]$Context
    )

    if ($null -eq $Result) {
        throw "$Context runner returned null result."
    }
    if (-not ($Result.PSObject.Properties['Status'])) {
        throw "$Context runner result is missing required 'Status' property."
    }
    if ([string]$Result.Status -cne 'PASS') {
        throw "$Context runner returned non-PASS status: '$($Result.Status)'."
    }
}

function Invoke-WithStagedArchiveLocked {
    param(
        [Parameter(Mandatory = $true)][string]$StagedPath,
        [Parameter(Mandatory = $true)][long]$ExpectedBytes,
        [Parameter(Mandatory = $true)][string]$ExpectedSha256,
        [Parameter(Mandatory = $true)][string]$Context,
        [Parameter(Mandatory = $true)][scriptblock]$Action
    )

    if (-not (Test-Path -LiteralPath $StagedPath -PathType Leaf)) {
        throw "$Context staged archive was not found at $StagedPath."
    }

    # Open with FileAccess.Read and FileShare.Read (denies write/delete to others during execution)
    $fileStream = [System.IO.File]::Open($StagedPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    try {
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        try {
            $hashBytes = $sha256.ComputeHash($fileStream)
            $hashHex = ([BitConverter]::ToString($hashBytes)).Replace('-', '').ToUpperInvariant()
        } finally {
            $sha256.Dispose()
        }

        if ($fileStream.Length -ne $ExpectedBytes) {
            throw "$Context staged archive byte length mismatch while locked: expected $ExpectedBytes, observed $($fileStream.Length)."
        }
        if ($hashHex -cne $ExpectedSha256.ToUpperInvariant()) {
            throw "$Context staged archive SHA-256 mismatch while locked: expected '$ExpectedSha256', observed '$hashHex'."
        }
        $fileStream.Position = 0

        & $Action
    } finally {
        $fileStream.Dispose()
    }
}

function Stage-AcceptedArchiveAtomically {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$StagingDirectory,
        [Parameter(Mandatory = $true)][string]$ArtifactName,
        [long]$ExpectedBytes = 0,
        [string]$ExpectedSha256,
        [string]$ExpectedManifestSha256,
        [string]$ExpectedContentSha256
    )

    $sourceFull = Get-AcceptanceFullPath -Path $SourcePath
    if (-not (Test-Path -LiteralPath $sourceFull -PathType Leaf)) {
        throw "$ArtifactName archive was not found at $sourceFull."
    }
    Assert-AcceptanceNoReparsePath -Path $sourceFull

    # Single byte read of source archive
    $bytes = [IO.File]::ReadAllBytes($sourceFull)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha256.ComputeHash($bytes)
        $hashHex = ([BitConverter]::ToString($hashBytes)).Replace('-', '').ToUpperInvariant()
    } finally {
        $sha256.Dispose()
    }

    if ($ExpectedBytes -gt 0 -and $bytes.Length -ne $ExpectedBytes) {
        throw "$ArtifactName archive byte count mismatch: expected $ExpectedBytes, observed $($bytes.Length)."
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedSha256) -and $hashHex -cne $ExpectedSha256.ToUpperInvariant()) {
        throw "$ArtifactName archive SHA-256 mismatch: expected '$ExpectedSha256', observed '$hashHex'."
    }

    $fileName = [IO.Path]::GetFileName($sourceFull)
    $stagedPath = Join-Path $StagingDirectory $fileName
    [IO.File]::WriteAllBytes($stagedPath, $bytes)

    # Re-verify staged archive bytes
    $stagedData = Get-FileSha256AndBytes -Path $stagedPath
    if ($stagedData.Sha256 -cne $hashHex -or $stagedData.Length -ne $bytes.Length) {
        throw "Staged $ArtifactName archive failed byte integrity verification."
    }

    # Extract manifest, validate all zip entries, and compute canonical contentSha256
    $zip = [System.IO.Compression.ZipFile]::OpenRead($stagedPath)
    $manifestBytes = $null
    $manifestSha256 = ''
    $contentSha256 = ''
    $manifestJson = $null
    $contentEntries = New-Object System.Collections.ArrayList
    $stagedManifestPath = Join-Path $StagingDirectory "$ArtifactName-package-manifest.json"

    try {
        $manifestEntry = $zip.GetEntry('package/package-manifest.json')
        if ($null -eq $manifestEntry) {
            $manifestEntry = $zip.GetEntry('package-manifest.json')
        }
        if ($null -eq $manifestEntry) {
            throw "$ArtifactName archive is missing package-manifest.json."
        }
        $stream = $manifestEntry.Open()
        $ms = New-Object System.IO.MemoryStream
        try {
            $stream.CopyTo($ms)
            $manifestBytes = $ms.ToArray()
        } finally {
            $stream.Dispose()
            $ms.Dispose()
        }
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $manifestSha256 = ([BitConverter]::ToString($sha.ComputeHash($manifestBytes))).Replace('-', '').ToUpperInvariant()
        } finally {
            $sha.Dispose()
        }
        if (-not [string]::IsNullOrWhiteSpace($ExpectedManifestSha256) -and $manifestSha256 -cne $ExpectedManifestSha256.ToUpperInvariant()) {
            throw "$ArtifactName manifest SHA-256 mismatch: expected '$ExpectedManifestSha256', observed '$manifestSha256'."
        }

        $manifestRaw = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($manifestBytes)
        $manifestJson = ConvertFrom-StrictPackageJson -Json $manifestRaw -Description "$ArtifactName package manifest"
        $contentSha256 = [string]$manifestJson.contentSha256

        # Write manifest as a real staging file
        [IO.File]::WriteAllBytes($stagedManifestPath, $manifestBytes)

        # Enumerate and hash all zip entries to validate against manifest contents
        $zipEntryHashes = New-Object System.Collections.ArrayList
        if ($null -ne $manifestJson.contents) {
            foreach ($item in @($manifestJson.contents)) {
                $itemRelPath = [string]$item.path
                $itemLength = [int64]$item.length
                $itemSha256 = [string]$item.sha256

                $zipEntryName = if ($manifestEntry.FullName.StartsWith('package/')) { "package/$itemRelPath" } else { $itemRelPath }
                $entryInZip = $zip.GetEntry($zipEntryName)
                if ($null -eq $entryInZip) {
                    throw "$ArtifactName archive is missing entry '$zipEntryName' declared in manifest."
                }
                if ($entryInZip.Length -ne $itemLength) {
                    throw "$ArtifactName archive entry '$zipEntryName' length mismatch: expected $itemLength, observed $($entryInZip.Length)."
                }

                # Compute hash of entry from zip stream
                $entryStream = $entryInZip.Open()
                $entryMs = New-Object System.IO.MemoryStream
                try {
                    $entryStream.CopyTo($entryMs)
                    $entryBytes = $entryMs.ToArray()
                } finally {
                    $entryStream.Dispose()
                    $entryMs.Dispose()
                }
                $entryHash = ([BitConverter]::ToString(([System.Security.Cryptography.SHA256]::Create()).ComputeHash($entryBytes))).Replace('-', '').ToUpperInvariant()
                if ($entryHash -cne $itemSha256.ToUpperInvariant()) {
                    throw "$ArtifactName archive entry '$zipEntryName' hash mismatch: expected '$itemSha256', observed '$entryHash'."
                }

                [void]$contentEntries.Add([pscustomobject][ordered]@{
                    Path = $itemRelPath
                    Length = $itemLength
                    Sha256 = $itemSha256
                })
                [void]$zipEntryHashes.Add([pscustomobject][ordered]@{
                    Path = $itemRelPath
                    Length = $itemLength
                    Sha256 = $itemSha256
                })
            }
        }

        # Recompute canonical contentSha256
        $canonicalText = Get-CanonicalPackageContentText -Entries $zipEntryHashes
        $recomputedContentSha256 = Get-Sha256ForText -Text $canonicalText
        if ($recomputedContentSha256 -cne $contentSha256) {
            throw "$ArtifactName recomputed contentSha256 ($recomputedContentSha256) does not match manifest contentSha256 ($contentSha256)."
        }
        if (-not [string]::IsNullOrWhiteSpace($ExpectedContentSha256) -and $recomputedContentSha256 -cne $ExpectedContentSha256.ToUpperInvariant()) {
            throw "$ArtifactName contentSha256 mismatch: expected '$ExpectedContentSha256', observed '$recomputedContentSha256'."
        }
    } finally {
        $zip.Dispose()
    }

    return [pscustomobject][ordered]@{
        SourcePath = $sourceFull
        StagedPath = $stagedPath
        StagedManifestPath = $stagedManifestPath
        Length = [int64]$bytes.Length
        Sha256 = $hashHex
        ManifestBytes = [int64]$manifestBytes.Length
        ManifestSha256 = $manifestSha256
        ContentSha256 = $contentSha256
        Manifest = $manifestJson
        ContentEntries = @($contentEntries.ToArray())
    }
}

function Assert-OperatorNoReparse {
    param([Parameter(Mandatory = $true)][string]$Path)

    Assert-AcceptanceNoReparsePath -Path $Path
    Assert-AcceptanceTreeNoReparse -Path $Path -Context 'Operator path'
}

# 1. Parse JSON binding if provided
if (-not [string]::IsNullOrWhiteSpace($BindingPath)) {
    $bindingFullPath = Get-AcceptanceFullPath -Path $BindingPath
    if (-not (Test-Path -LiteralPath $bindingFullPath -PathType Leaf)) {
        throw "Live binding file was not found: $bindingFullPath"
    }
    Assert-OperatorNoReparse -Path $bindingFullPath
    $binding = Read-AcceptanceJsonFile -Path $bindingFullPath -Context 'Issue #44 live binding'
    Assert-AcceptanceExactProperties -Object $binding -Names @(
        'schemaVersion', 'issue', 'acceptanceVersion', 'mode', 'machineRole',
        'machineName', 'machineFingerprint', 'sourceCommit', 'initialArtifact',
        'upgradeArtifact', 'installRoot', 'userDataRoot', 'reportPath',
        'retainedDataRelativePath', 'retainedDataSha256', 'retainedDataMode') -Context 'Issue #44 live binding'

    if ([int]$binding.schemaVersion -ne 1 -or [int]$binding.issue -ne 44 -or [string]$binding.acceptanceVersion -cne 'v1.0.0') {
        throw 'Live binding schema version, issue, or acceptanceVersion is invalid.'
    }
    $Mode = [string]$binding.mode
    $ExpectedMachineName = [string]$binding.machineName
    $ExpectedMachineFingerprint = [string]$binding.machineFingerprint
    $ExpectedSourceCommit = [string]$binding.sourceCommit
    $CandidateSourceCommit = [string]$binding.sourceCommit

    $initialArtifactBinding = $binding.initialArtifact
    Assert-AcceptanceExactProperties -Object $initialArtifactBinding -Names @(
        'packageRoot', 'archivePath', 'hashRecordPath', 'productId', 'displayName',
        'packagingIssue', 'packageVersion', 'targetFramework', 'runtimeIdentifier',
        'deploymentModel', 'userDataPolicy', 'sourceCommit', 'manifestSha256',
        'archiveSha256', 'contentSha256') -Context 'Initial artifact binding'

    $InitialArchivePath = [string]$initialArtifactBinding.archivePath
    $InitialArchiveSha256 = [string]$initialArtifactBinding.archiveSha256
    $InitialManifestSha256 = [string]$initialArtifactBinding.manifestSha256
    $InitialContentSha256 = [string]$initialArtifactBinding.contentSha256
    $InitialPackageVersion = [string]$initialArtifactBinding.packageVersion
    $InitialSourceCommit = [string]$initialArtifactBinding.sourceCommit

    $upgradeArtifactBinding = $binding.upgradeArtifact
    Assert-AcceptanceExactProperties -Object $upgradeArtifactBinding -Names @(
        'packageRoot', 'archivePath', 'hashRecordPath', 'productId', 'displayName',
        'packagingIssue', 'packageVersion', 'targetFramework', 'runtimeIdentifier',
        'deploymentModel', 'userDataPolicy', 'sourceCommit', 'manifestSha256',
        'archiveSha256', 'contentSha256') -Context 'Upgrade artifact binding'

    $CandidateArchivePath = [string]$upgradeArtifactBinding.archivePath
    $CandidateArchiveSha256 = [string]$upgradeArtifactBinding.archiveSha256
    $CandidateManifestSha256 = [string]$upgradeArtifactBinding.manifestSha256
    $CandidateContentSha256 = [string]$upgradeArtifactBinding.contentSha256
    $CandidatePackageVersion = [string]$upgradeArtifactBinding.packageVersion
    $CandidateSourceCommit = [string]$upgradeArtifactBinding.sourceCommit

    $InstallRoot = [string]$binding.installRoot
    $UserDataRoot = [string]$binding.userDataRoot
    $ReportDestination = [string]$binding.reportPath
    $RetainedDataRelativePath = [string]$binding.retainedDataRelativePath
    $RetainedDataSha256 = [string]$binding.retainedDataSha256
    $RetainedDataMode = [string]$binding.retainedDataMode
}

$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$status = 'PASS'
$failureDetails = ''

$targetsReport = [ordered]@{
    installRoot = ''
    userDataRoot = ''
    reportPath = $(if ([string]::IsNullOrWhiteSpace($ReportDestination)) { 'NOT_SPECIFIED' } else { $ReportDestination })
    simulationRoot = $(if ([string]::IsNullOrWhiteSpace($SimulationRoot)) { 'NONE' } else { $SimulationRoot })
    installPathPolicy = '%LOCALAPPDATA%\Programs\HerdrOps'
    userDataPathPolicy = '%LOCALAPPDATA%\HerdrOps'
    userDataPolicy = 'retain-on-uninstall'
}

$lifecycle = [ordered]@{
    cleanInstall = [ordered]@{
        status = 'NOT_RUN'
        expectedVersion = $InitialPackageVersion
        installedFileHashes = @()
        installRootPresent = $false
        packageVersionObserved = 'NOT_OBSERVED'
        retainedDataStatus = 'NOT_RUN'
        retainedDataSha256 = 'NOT_OBSERVED'
        details = 'Not yet executed.'
    }
    upgrade = [ordered]@{
        status = 'NOT_RUN'
        expectedVersion = $CandidatePackageVersion
        installedFileHashes = @()
        installRootPresent = $false
        packageVersionObserved = 'NOT_OBSERVED'
        retainedDataStatus = 'NOT_RUN'
        retainedDataSha256 = 'NOT_OBSERVED'
        details = 'Not yet executed.'
    }
    rollback = [ordered]@{
        status = 'NOT_RUN'
        expectedVersion = $InitialPackageVersion
        installedFileHashes = @()
        installRootPresent = $false
        packageVersionObserved = 'NOT_OBSERVED'
        retainedDataStatus = 'NOT_RUN'
        retainedDataSha256 = 'NOT_OBSERVED'
        details = 'Not yet executed.'
    }
    uninstall = [ordered]@{
        status = 'NOT_RUN'
        expectedVersion = $InitialPackageVersion
        installedFileHashes = @()
        installRootPresent = $false
        packageVersionObserved = 'NOT_OBSERVED'
        retainedDataStatus = 'NOT_RUN'
        retainedDataSha256 = 'NOT_OBSERVED'
        details = 'Not yet executed.'
    }
}

$cleanup = [ordered]@{
    status = 'NOT_RUN'
    attempted = $false
    simulationRoot = $(if ([string]::IsNullOrWhiteSpace($SimulationRoot)) { 'NONE' } else { $SimulationRoot })
    simulationRootRemoved = $true
    ownedStageRemoved = $true
    ownedBackupRemoved = $true
    harnessSeededDataMarkerRemoved = $false
    retainedDataLeftIntact = $true
    residuals = @()
    details = 'Not yet executed.'
}

$initialArtifactReport = $null
$upgradeArtifactReport = $null

try {
    Add-OperatorTranscript -Phase 'Preflight' -Action 'initialize-operator' -Status 'PASS' -Effect 'None' -Details "Issue #44 live operator initialized in mode '$Mode'." -PathBinding 'none'

    # Preflight Check 1: OS Platform
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'Issue #44 acceptance operator requires a Windows NT host.'
    }
    Add-OperatorPreflightCheck -Name 'operating-system-platform' -Status 'PASS' -Details 'Host is Windows NT.'

    # Preflight Check 2: Elevation Policy (Live mode requires non-elevated standard process)
    $isElevated = Test-AcceptanceIsElevated
    if ($Mode -eq 'Live' -and $isElevated) {
        throw 'Issue #44 live acceptance must run under a standard, non-elevated user account.'
    }
    Add-OperatorPreflightCheck -Name 'process-elevation-policy' -Status 'PASS' -Details "Elevation check passed (Elevated=$isElevated)."

    # Preflight Check 3: Designated Clean Machine Identity & Fingerprint
    $machineName = [string]$env:COMPUTERNAME
    $machineFingerprint = Get-AcceptanceMachineFingerprint
    if ($Mode -eq 'Live') {
        if ([string]::IsNullOrWhiteSpace($ExpectedMachineName)) {
            throw 'Live mode requires non-empty exact -ExpectedMachineName.'
        }
        if ([string]::IsNullOrWhiteSpace($ExpectedMachineFingerprint)) {
            throw 'Live mode requires non-empty exact -ExpectedMachineFingerprint.'
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedMachineName) -and $machineName -cne $ExpectedMachineName) {
        throw "Designated clean machine name mismatch: expected '$ExpectedMachineName', observed '$machineName'."
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedMachineFingerprint) -and $machineFingerprint -cne $ExpectedMachineFingerprint) {
        throw "Designated clean machine fingerprint mismatch: expected '$ExpectedMachineFingerprint', observed '$machineFingerprint'."
    }
    Add-OperatorPreflightCheck -Name 'designated-machine-fingerprint' -Status 'PASS' -Details "Machine '$machineName' fingerprint '$machineFingerprint' verified."

    # Preflight Check 4: Git Source Commit, Tree, Parent & Working Tree Verification
    $gitCommitOutput = @(& git -C $repositoryRoot rev-parse --verify 'HEAD^{commit}' 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0 -or $gitCommitOutput.Count -ne 1 -or $gitCommitOutput[0].Trim() -cnotmatch '^[0-9a-f]{40}$') {
        throw 'Could not resolve exact repository HEAD commit SHA.'
    }
    $actualHeadCommit = $gitCommitOutput[0].Trim().ToLowerInvariant()

    if ($Mode -eq 'Live' -and [string]::IsNullOrWhiteSpace($ExpectedSourceCommit)) {
        throw 'Live mode requires non-empty exact -ExpectedSourceCommit.'
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedSourceCommit) -and $actualHeadCommit -cne $ExpectedSourceCommit.ToLowerInvariant()) {
        throw "Repository HEAD commit '$actualHeadCommit' does not match expected source commit '$ExpectedSourceCommit'."
    }
    if (-not [string]::IsNullOrWhiteSpace($CandidateSourceCommit) -and $CandidateSourceCommit.ToLowerInvariant() -cne $actualHeadCommit) {
        throw "Candidate source commit '$CandidateSourceCommit' does not match repository HEAD commit '$actualHeadCommit'."
    }

    $gitTreeOutput = @(& git -C $repositoryRoot rev-parse --verify "$actualHeadCommit^{tree}" 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0 -or $gitTreeOutput.Count -ne 1 -or $gitTreeOutput[0].Trim() -cnotmatch '^[0-9a-f]{40}$') {
        throw 'Could not resolve exact repository source tree SHA.'
    }
    $actualHeadTree = $gitTreeOutput[0].Trim().ToLowerInvariant()
    if ($Mode -eq 'Live' -and [string]::IsNullOrWhiteSpace($ExpectedSourceTree)) {
        throw 'Live mode requires non-empty exact -ExpectedSourceTree.'
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedSourceTree) -and $actualHeadTree -cne $ExpectedSourceTree.ToLowerInvariant()) {
        throw "Repository source tree '$actualHeadTree' does not match expected source tree '$ExpectedSourceTree'."
    }

    $gitParentOutput = @(& git -C $repositoryRoot rev-parse --verify "$actualHeadCommit^1" 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -eq 0 -and $gitParentOutput.Count -eq 1 -and $gitParentOutput[0].Trim() -cmatch '^[0-9a-f]{40}$') {
        $actualParentCommit = $gitParentOutput[0].Trim().ToLowerInvariant()
        if (-not [string]::IsNullOrWhiteSpace($ExpectedParentCommit) -and $actualParentCommit -cne $ExpectedParentCommit.ToLowerInvariant()) {
            throw "Repository parent commit '$actualParentCommit' does not match expected parent commit '$ExpectedParentCommit'."
        }
    }

    $gitStatusOutput = @(& git -C $repositoryRoot status --porcelain=v1 --untracked-files=all 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0 -or $gitStatusOutput.Count -ne 0) {
        throw "Release work requires a clean checkout. Pending status: $($gitStatusOutput -join '; ')"
    }
    Add-OperatorPreflightCheck -Name 'repository-source-commit-clean' -Status 'PASS' -Details "Clean repository HEAD $actualHeadCommit tree $actualHeadTree verified."

    # Preflight Check 5: Mode & Runner Restrictions (Live rejects injected runners, Fixture requires both)
    if ($Mode -eq 'Live') {
        if ($null -ne $InstallerRunner -or $null -ne $FirstRunRunner) {
            throw 'Live mode MUST NOT use injected -InstallerRunner or -FirstRunRunner. Only production paths can grant CleanMachine evidence.'
        }
        if (-not $IUnderstandLiveMutation) {
            throw 'Live mode requires explicit -IUnderstandLiveMutation switch.'
        }
        if ($LiveConfirmationToken -cne $script:LiveTokenValue) {
            throw "Live mode requires exact -LiveConfirmationToken '$($script:LiveTokenValue)'."
        }
        if ($RetainedDataMode -eq 'create-test-marker' -and -not $AllowLiveRetainedDataSeed) {
            throw 'Live mode with create-test-marker requires explicit -AllowLiveRetainedDataSeed switch.'
        }
        Add-OperatorPreflightCheck -Name 'live-filesystem-safeguards' -Status 'PASS' -Details 'Live mutation confirmation token verified and injected runners rejected.'
    } else {
        if ($Mode -eq 'Fixture') {
            if ($null -eq $InstallerRunner -or $null -eq $FirstRunRunner) {
                throw 'Fixture mode requires both an injected -InstallerRunner and -FirstRunRunner.'
            }
        }
        Add-OperatorPreflightCheck -Name 'live-filesystem-safeguards' -Status 'NOT_APPLICABLE' -Details "Running in non-live mode ($Mode)."
    }

    # Preflight Check 6: Accepted-Beta Provenance Verification
    if ($Mode -eq 'Live') {
        if ([string]::IsNullOrWhiteSpace($BetaReportPath)) {
            throw 'Live mode requires non-empty -BetaReportPath pointing to accepted-Beta evidence.'
        }
        if ($BetaReportBytes -le 0) {
            throw 'Live mode requires non-empty -BetaReportBytes (>0).'
        }
        if ([string]::IsNullOrWhiteSpace($BetaReportSha256)) {
            throw 'Live mode requires non-empty -BetaReportSha256.'
        }
        if ([string]::IsNullOrWhiteSpace($BetaReportSourceCommit)) {
            throw 'Live mode requires non-empty -BetaReportSourceCommit.'
        }
        if ([string]::IsNullOrWhiteSpace($BetaReportSourceTree)) {
            throw 'Live mode requires non-empty -BetaReportSourceTree.'
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($BetaReportPath)) {
        $betaReportFull = Get-AcceptanceFullPath -Path $BetaReportPath
        if (-not (Test-Path -LiteralPath $betaReportFull -PathType Leaf)) {
            throw "Accepted-Beta provenance report was not found: $betaReportFull"
        }
        Assert-AcceptanceNoReparsePath -Path $betaReportFull
        $betaReportData = Get-FileSha256AndBytes -Path $betaReportFull
        if ($BetaReportBytes -gt 0 -and $betaReportData.Length -ne $BetaReportBytes) {
            throw "Accepted-Beta provenance report byte count mismatch: expected $BetaReportBytes, observed $($betaReportData.Length)."
        }
        if (-not [string]::IsNullOrWhiteSpace($BetaReportSha256) -and $betaReportData.Sha256 -cne $BetaReportSha256.ToUpperInvariant()) {
            throw "Accepted-Beta provenance report SHA-256 mismatch: expected '$BetaReportSha256', observed '$($betaReportData.Sha256)'."
        }
        $betaReportJson = Read-AcceptanceJsonFile -Path $betaReportFull -Context 'Accepted-Beta provenance report'
        if (-not [string]::IsNullOrWhiteSpace($BetaReportStatus) -and [string]$betaReportJson.status -cne $BetaReportStatus) {
            throw "Accepted-Beta provenance report status mismatch: expected '$BetaReportStatus', observed '$($betaReportJson.status)'."
        }
        if (-not [string]::IsNullOrWhiteSpace($BetaReportSourceCommit)) {
            $betaCommit = if ($betaReportJson.PSObject.Properties['sourceCommit']) { [string]$betaReportJson.sourceCommit } else { [string]$betaReportJson.artifacts.upgrade.sourceCommitBinding }
            if ($betaCommit -cne $BetaReportSourceCommit) {
                throw "Accepted-Beta provenance report sourceCommit mismatch: expected '$BetaReportSourceCommit', observed '$betaCommit'."
            }
        }
        Add-OperatorPreflightCheck -Name 'accepted-beta-provenance' -Status 'PASS' -Details "Beta report verified at '$betaReportFull'."
    } else {
        Add-OperatorPreflightCheck -Name 'accepted-beta-provenance' -Status 'NOT_APPLICABLE' -Details 'No external Beta report path specified.'
    }

    # Preflight Check 7: Target Path Policies and Reparse Safety (Simulation root containment in Fixture)
    if ($Mode -eq 'Live') {
        if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
            $InstallRoot = Get-DefaultHerdrOpsInstallRoot
        }
        if ([string]::IsNullOrWhiteSpace($UserDataRoot)) {
            $UserDataRoot = Get-DefaultHerdrOpsUserDataRoot
        }
        $installRootFull = Get-AcceptanceFullPath -Path $InstallRoot
        $userDataRootFull = Get-AcceptanceFullPath -Path $UserDataRoot
    } else {
        if ([string]::IsNullOrWhiteSpace($SimulationRoot)) {
            $SimulationRoot = Join-Path $env:TEMP "HerdrOps.simulation-$($script:RunId)"
            New-Item -ItemType Directory -Path $SimulationRoot -Force | Out-Null
            $script:OwnedSimulationDirectory = $SimulationRoot
        }
        $simRootFull = Get-AcceptanceFullPath -Path $SimulationRoot
        Assert-AcceptanceNoReparsePath -Path $simRootFull
        $targetsReport.simulationRoot = $simRootFull
        $cleanup.simulationRoot = $simRootFull

        if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
            $InstallRoot = Join-Path $simRootFull 'Programs\HerdrOps'
        }
        if ([string]::IsNullOrWhiteSpace($UserDataRoot)) {
            $UserDataRoot = Join-Path $simRootFull 'HerdrOps'
        }

        $installRootFull = Get-AcceptanceFullPath -Path $InstallRoot
        $userDataRootFull = Get-AcceptanceFullPath -Path $UserDataRoot

        # Fixture / non-live mode must strictly contain paths inside SimulationRoot
        if (-not (Test-PathWithin -ChildPath $installRootFull -RootPath $simRootFull)) {
            throw "Non-live InstallRoot '$installRootFull' must be contained inside SimulationRoot '$simRootFull'."
        }
        if (-not (Test-PathWithin -ChildPath $userDataRootFull -RootPath $simRootFull)) {
            throw "Non-live UserDataRoot '$userDataRootFull' must be contained inside SimulationRoot '$simRootFull'."
        }

        $canonicalInstall = Get-DefaultHerdrOpsInstallRoot
        $canonicalUserData = Get-DefaultHerdrOpsUserDataRoot
        if ($installRootFull.Equals((Get-AcceptanceFullPath $canonicalInstall), [StringComparison]::OrdinalIgnoreCase) -or
            $userDataRootFull.Equals((Get-AcceptanceFullPath $canonicalUserData), [StringComparison]::OrdinalIgnoreCase)) {
            throw "Non-live mode ($Mode) must not target production AppData paths ($canonicalInstall, $canonicalUserData)."
        }
    }

    if ($installRootFull.Equals($userDataRootFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'InstallRoot and UserDataRoot must be distinct non-overlapping paths.'
    }
    if ((Test-PathWithin -ChildPath $installRootFull -RootPath $userDataRootFull -AllowEqual:$false) -or
        (Test-PathWithin -ChildPath $userDataRootFull -RootPath $installRootFull -AllowEqual:$false)) {
        throw 'InstallRoot and UserDataRoot cannot nest within each other.'
    }
    Assert-OperatorNoReparse -Path $installRootFull
    Assert-OperatorNoReparse -Path $userDataRootFull

    $targetsReport.installRoot = $installRootFull
    $targetsReport.userDataRoot = $userDataRootFull
    Add-OperatorPreflightCheck -Name 'target-paths-reparse-clean' -Status 'PASS' -Details "InstallRoot '$installRootFull' and UserDataRoot '$userDataRootFull' verified."

    # Preflight Check 8: Clean-Machine Precondition - Install Root Absent and No Stale Residuals
    if (Test-Path -LiteralPath $installRootFull) {
        throw "Clean-machine precondition failed: InstallRoot already exists at '$installRootFull'."
    }
    $installParent = Split-Path -Path $installRootFull -Parent
    if (Test-Path -LiteralPath $installParent) {
        $staleDirs = @(Get-ChildItem -LiteralPath $installParent -Directory -Force | Where-Object {
            $_.Name -match '^HerdrOps\.(staging|backup|harness)-'
        })
        if ($staleDirs.Count -gt 0) {
            throw "Clean-machine precondition failed: leftover residuals detected in '$installParent': $($staleDirs.FullName -join '; ')."
        }
    }
    Add-OperatorPreflightCheck -Name 'clean-machine-precondition' -Status 'PASS' -Details 'Install root is absent and parent directory is clean of residuals.'

    # Preflight Check 9: Archive Validation, Manifest Extraction, Entry Hashing, and Staging
    if ($Mode -eq 'Live') {
        if ($InitialArchiveBytes -le 0 -or [string]::IsNullOrWhiteSpace($InitialArchiveSha256)) {
            throw 'Live mode requires non-empty InitialArchiveBytes (>0) and InitialArchiveSha256.'
        }
        if ($CandidateArchiveBytes -le 0 -or [string]::IsNullOrWhiteSpace($CandidateArchiveSha256)) {
            throw 'Live mode requires non-empty CandidateArchiveBytes (>0) and CandidateArchiveSha256.'
        }
    }

    if ([string]::IsNullOrWhiteSpace($InitialArchivePath) -or -not (Test-Path -LiteralPath $InitialArchivePath -PathType Leaf)) {
        throw "Initial package archive was not found: $InitialArchivePath"
    }
    if ([string]::IsNullOrWhiteSpace($CandidateArchivePath) -or -not (Test-Path -LiteralPath $CandidateArchivePath -PathType Leaf)) {
        throw "Candidate package archive was not found: $CandidateArchivePath"
    }

    if ([string]$CandidatePackageVersion -cne '1.0.0') {
        throw "Candidate package version must be exactly '1.0.0'; observed '$CandidatePackageVersion'."
    }
    if ([string]$InitialPackageVersion -cne '0.7.0' -and [string]$InitialPackageVersion -ge [string]$CandidatePackageVersion) {
        throw "Initial package version ($InitialPackageVersion) must be lower than candidate package version ($CandidatePackageVersion)."
    }

    # Create operator-owned staging directory
    $stagingParent = if ($Mode -eq 'Live') { $env:TEMP } else { $targetsReport.simulationRoot }
    $script:OwnedStagingDirectory = Join-Path $stagingParent "HerdrOps.operator-stage-$($script:RunId)"
    New-Item -ItemType Directory -Path $script:OwnedStagingDirectory -Force | Out-Null
    Assert-OperatorNoReparse -Path $script:OwnedStagingDirectory

    $stagedInitial = Stage-AcceptedArchiveAtomically `
        -SourcePath $InitialArchivePath `
        -StagingDirectory $script:OwnedStagingDirectory `
        -ArtifactName 'Initial' `
        -ExpectedBytes $InitialArchiveBytes `
        -ExpectedSha256 $InitialArchiveSha256 `
        -ExpectedManifestSha256 $InitialManifestSha256 `
        -ExpectedContentSha256 $InitialContentSha256

    $stagedCandidate = Stage-AcceptedArchiveAtomically `
        -SourcePath $CandidateArchivePath `
        -StagingDirectory $script:OwnedStagingDirectory `
        -ArtifactName 'Candidate' `
        -ExpectedBytes $CandidateArchiveBytes `
        -ExpectedSha256 $CandidateArchiveSha256 `
        -ExpectedManifestSha256 $CandidateManifestSha256 `
        -ExpectedContentSha256 $CandidateContentSha256

    Add-OperatorPreflightCheck -Name 'v1-target-version' -Status 'PASS' -Details "Initial version '$InitialPackageVersion' and upgrade target version '$CandidatePackageVersion' validated."
    Add-OperatorPreflightCheck -Name 'archive-hashes-and-bytes' -Status 'PASS' -Details 'Initial and Candidate archive bytes, manifests, entries, and SHA-256 verified and staged.'

    # Construct Artifact Report Records referencing durable accepted inputs
    $initialArchiveDurable = Get-AcceptanceFullPath -Path $InitialArchivePath
    $candidateArchiveDurable = Get-AcceptanceFullPath -Path $CandidateArchivePath

    $initialArtifactReport = [ordered]@{
        name = 'initial'
        productId = 'HerdrOps'
        displayName = 'HerdrOps'
        packagingIssue = 38
        packageVersion = $InitialPackageVersion
        targetFramework = 'net10.0-windows'
        runtimeIdentifier = 'win-x64'
        deploymentModel = 'per-user-directory'
        userDataPolicy = 'retain-on-uninstall'
        packageRoot = (Split-Path -Path $initialArchiveDurable -Parent)
        archivePath = $initialArchiveDurable
        archiveBytes = [int64]$stagedInitial.Length
        archiveSha256 = $stagedInitial.Sha256
        manifestPath = (Join-Path (Split-Path -Path $initialArchiveDurable -Parent) 'package-manifest.json')
        manifestBytes = [int64]$stagedInitial.ManifestBytes
        manifestSha256 = $stagedInitial.ManifestSha256
        contentSha256 = $stagedInitial.ContentSha256
        sourceCommitBinding = $(if (-not [string]::IsNullOrWhiteSpace($InitialSourceCommit)) { $InitialSourceCommit } else { 'NOT_BOUND_IN_SYNTHETIC_FIXTURE' })
        installedFileHashes = @()
    }

    $upgradeArtifactReport = [ordered]@{
        name = 'upgrade'
        productId = 'HerdrOps'
        displayName = 'HerdrOps'
        packagingIssue = 44
        packageVersion = $CandidatePackageVersion
        targetFramework = 'net10.0-windows'
        runtimeIdentifier = 'win-x64'
        deploymentModel = 'per-user-directory'
        userDataPolicy = 'retain-on-uninstall'
        packageRoot = (Split-Path -Path $candidateArchiveDurable -Parent)
        archivePath = $candidateArchiveDurable
        archiveBytes = [int64]$stagedCandidate.Length
        archiveSha256 = $stagedCandidate.Sha256
        manifestPath = (Join-Path (Split-Path -Path $candidateArchiveDurable -Parent) 'package-manifest.json')
        manifestBytes = [int64]$stagedCandidate.ManifestBytes
        manifestSha256 = $stagedCandidate.ManifestSha256
        contentSha256 = $stagedCandidate.ContentSha256
        sourceCommitBinding = $actualHeadCommit
        installedFileHashes = @()
    }

    # Artifact objects for Assert-AcceptanceInstalledPayload helper
    $initialArtifactHelper = [pscustomobject][ordered]@{
        Name = 'initial'
        ProductId = 'HerdrOps'
        DisplayName = 'HerdrOps'
        PackagingIssue = 38
        PackageVersion = $InitialPackageVersion
        TargetFramework = 'net10.0-windows'
        RuntimeIdentifier = 'win-x64'
        DeploymentModel = 'per-user-directory'
        UserDataPolicy = 'retain-on-uninstall'
        PackageRoot = (Split-Path -Path $stagedInitial.StagedPath -Parent)
        ArchivePath = $stagedInitial.StagedPath
        ArchiveBytes = $stagedInitial.Length
        ArchiveSha256 = $stagedInitial.Sha256
        ManifestPath = $stagedInitial.StagedManifestPath
        ManifestBytes = $stagedInitial.ManifestBytes
        ManifestSha256 = $stagedInitial.ManifestSha256
        ContentSha256 = $stagedInitial.ContentSha256
        SourceCommitBinding = $InitialSourceCommit
        ContentEntries = $stagedInitial.ContentEntries
    }

    $upgradeArtifactHelper = [pscustomobject][ordered]@{
        Name = 'upgrade'
        ProductId = 'HerdrOps'
        DisplayName = 'HerdrOps'
        PackagingIssue = 44
        PackageVersion = $CandidatePackageVersion
        TargetFramework = 'net10.0-windows'
        RuntimeIdentifier = 'win-x64'
        DeploymentModel = 'per-user-directory'
        UserDataPolicy = 'retain-on-uninstall'
        PackageRoot = (Split-Path -Path $stagedCandidate.StagedPath -Parent)
        ArchivePath = $stagedCandidate.StagedPath
        ArchiveBytes = $stagedCandidate.Length
        ArchiveSha256 = $stagedCandidate.Sha256
        ManifestPath = $stagedCandidate.StagedManifestPath
        ManifestBytes = $stagedCandidate.ManifestBytes
        ManifestSha256 = $stagedCandidate.ManifestSha256
        ContentSha256 = $stagedCandidate.ContentSha256
        SourceCommitBinding = $actualHeadCommit
        ContentEntries = $stagedCandidate.ContentEntries
    }

    # Setup Runners: Default installer runs bounded child powershell process
    $effectiveInstallerRunner = if ($null -ne $InstallerRunner) {
        $InstallerRunner
    } else {
        {
            param(
                [Parameter(Mandatory = $true)][ValidateSet('Install', 'Uninstall')][string]$Action,
                [string]$ArchivePath,
                [Parameter(Mandatory = $true)][string]$InstallRoot,
                [Parameter(Mandatory = $true)][string]$UserDataRoot,
                [switch]$RemoveUserData,
                [int]$TimeoutSeconds = 120
            )
            $installerDir = Join-Path $repositoryRoot 'tools\installer'
            $scriptPath = if ($Action -eq 'Install') {
                Join-Path $installerDir 'Install-HerdrOps.ps1'
            } else {
                Join-Path $installerDir 'Uninstall-HerdrOps.ps1'
            }

            $pwshExe = (Get-Process -Id $PID).Path
            if (-not (Test-Path -LiteralPath $pwshExe -PathType Leaf)) {
                $pwshExe = 'powershell.exe'
            }

            $argList = New-Object System.Collections.ArrayList
            [void]$argList.Add('-NoProfile')
            [void]$argList.Add('-NonInteractive')
            [void]$argList.Add('-ExecutionPolicy')
            [void]$argList.Add('Bypass')
            [void]$argList.Add('-File')
            [void]$argList.Add($scriptPath)

            if ($Action -eq 'Install') {
                [void]$argList.Add('-ArchivePath')
                [void]$argList.Add($ArchivePath)
                [void]$argList.Add('-InstallRoot')
                [void]$argList.Add($InstallRoot)
                [void]$argList.Add('-UserDataRoot')
                [void]$argList.Add($UserDataRoot)
            } else {
                [void]$argList.Add('-InstallRoot')
                [void]$argList.Add($InstallRoot)
                [void]$argList.Add('-UserDataRoot')
                [void]$argList.Add($UserDataRoot)
                if ($RemoveUserData) {
                    [void]$argList.Add('-RemoveUserData')
                }
            }

            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $pwshExe
            $psi.Arguments = ($argList | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } }) -join ' '
            $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.CreateNoWindow = $true

            $proc = [System.Diagnostics.Process]::Start($psi)
            if ($null -eq $proc) {
                throw "Failed to start installer child process: $pwshExe"
            }

            $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
            $stderrTask = $proc.StandardError.ReadToEndAsync()

            if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
                try { $proc.Kill() } catch { }
                throw "Installer child process timed out after $TimeoutSeconds seconds."
            }

            $stdout = $stdoutTask.GetAwaiter().GetResult()
            $stderr = $stderrTask.GetAwaiter().GetResult()

            if ($proc.ExitCode -ne 0) {
                throw "Installer ($Action) failed with exit code $($proc.ExitCode). Stderr: $stderr. Stdout: $stdout"
            }

            return [pscustomobject][ordered]@{
                Status = 'PASS'
                Action = $Action
                ExitCode = $proc.ExitCode
                Details = "Installer ($Action) completed successfully."
            }
        }
    }

    $effectiveFirstRunRunner = if ($null -ne $FirstRunRunner) {
        $FirstRunRunner
    } else {
        {
            param(
                [Parameter(Mandatory = $true)][string]$InstallRoot,
                [Parameter(Mandatory = $true)][string]$UserDataRoot,
                [int]$TimeoutMilliseconds = 5000
            )
            $appExe = Join-Path $InstallRoot 'HerdrOps.App.exe'
            $coreExe = Join-Path $InstallRoot 'HerdrOps.Core.exe'
            if (-not (Test-Path -LiteralPath $coreExe -PathType Leaf)) {
                throw "HerdrOps.Core.exe not found in $InstallRoot."
            }
            if (-not (Test-Path -LiteralPath $appExe -PathType Leaf)) {
                throw "HerdrOps.App.exe not found in $InstallRoot."
            }

            $coreData = Get-FileSha256AndBytes -Path $coreExe
            $appData = Get-FileSha256AndBytes -Path $appExe

            $admittedPids = New-Object 'System.Collections.Generic.HashSet[int]'
            $coreProc = $null
            $appProc = $null

            try {
                # 1. Start Core with exact argument 'serve-herdr-state'
                $corePsi = New-Object System.Diagnostics.ProcessStartInfo
                $corePsi.FileName = $coreExe
                $corePsi.Arguments = 'serve-herdr-state'
                $corePsi.WorkingDirectory = $InstallRoot
                $corePsi.UseShellExecute = $false
                $corePsi.CreateNoWindow = $true
                $coreProc = [System.Diagnostics.Process]::Start($corePsi)
                if ($null -eq $coreProc) {
                    throw "Failed to start Core process: $coreExe serve-herdr-state"
                }
                [void]$admittedPids.Add($coreProc.Id)

                # 2. Start App with NO invented arguments
                $appPsi = New-Object System.Diagnostics.ProcessStartInfo
                $appPsi.FileName = $appExe
                $appPsi.Arguments = ''
                $appPsi.WorkingDirectory = $InstallRoot
                $appPsi.UseShellExecute = $false
                $appPsi.CreateNoWindow = $true
                $appProc = [System.Diagnostics.Process]::Start($appPsi)
                if ($null -eq $appProc) {
                    throw "Failed to start App process: $appExe"
                }
                [void]$admittedPids.Add($appProc.Id)

                # 3. Bounded stable dwell and health observation
                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                $observedHealthy = $false
                while ($sw.ElapsedMilliseconds -lt $TimeoutMilliseconds) {
                    Start-Sleep -Milliseconds 200
                    if (-not $coreProc.HasExited -and -not $appProc.HasExited) {
                        $observedHealthy = $true
                        break
                    }
                }

                if (-not $observedHealthy) {
                    if ($coreProc.HasExited) { throw "Core process exited unexpectedly with code $($coreProc.ExitCode)." }
                    if ($appProc.HasExited) { throw "App process exited unexpectedly with code $($appProc.ExitCode)." }
                }

                # 4. Discover recursive descendants of admitted PIDs only
                $queue = New-Object 'System.Collections.Generic.Queue[int]'
                foreach ($p in $admittedPids) { $queue.Enqueue($p) }
                while ($queue.Count -gt 0) {
                    $curr = $queue.Dequeue()
                    try {
                        $children = @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $curr" -ErrorAction SilentlyContinue)
                        foreach ($c in $children) {
                            $cPid = [int]$c.ProcessId
                            if (-not $admittedPids.Contains($cPid)) {
                                [void]$admittedPids.Add($cPid)
                                $queue.Enqueue($cPid)
                            }
                        }
                    } catch { }
                }
            } finally {
                # Kill ONLY admitted PIDs and direct descendants
                if ($null -ne $appProc -and -not $appProc.HasExited) {
                    try {
                        if (Get-Command -Name Stop-CoreProcessBounded -ErrorAction SilentlyContinue) {
                            Stop-CoreProcessBounded -Process $appProc -DrainMilliseconds 2000
                        } else {
                            $appProc.Kill()
                            $appProc.WaitForExit(2000)
                        }
                    } catch { }
                }
                if ($null -ne $coreProc -and -not $coreProc.HasExited) {
                    try {
                        if (Get-Command -Name Stop-CoreProcessBounded -ErrorAction SilentlyContinue) {
                            Stop-CoreProcessBounded -Process $coreProc -DrainMilliseconds 2000
                        } else {
                            $coreProc.Kill()
                            $coreProc.WaitForExit(2000)
                        }
                    } catch { }
                }
                foreach ($pidToKill in @($admittedPids)) {
                    try {
                        $proc = [System.Diagnostics.Process]::GetProcessById($pidToKill)
                        if ($null -ne $proc -and -not $proc.HasExited) {
                            $proc.Kill()
                            $proc.WaitForExit(1000)
                        }
                    } catch { }
                }
            }

            foreach ($pidToCheck in @($admittedPids)) {
                try {
                    $proc = [System.Diagnostics.Process]::GetProcessById($pidToCheck)
                    if ($null -ne $proc -and -not $proc.HasExited) {
                        throw "Admitted process $pidToCheck failed to exit."
                    }
                } catch [ArgumentException] {
                    # Process has exited cleanly
                }
            }

            return [pscustomobject][ordered]@{
                Status = 'PASS'
                CorePid = $coreProc.Id
                AppPid = $appProc.Id
                CorePath = $coreExe
                AppPath = $appExe
                CoreSha256 = $coreData.Sha256
                AppSha256 = $appData.Sha256
                AdmittedPids = @($admittedPids)
                Details = 'Core serve-herdr-state and App launched cleanly, observed healthy, and all admitted PIDs terminated cleanly.'
            }
        }
    }

    # Setup Retained Data Target
    $retainedDataFullPath = Get-AcceptanceFullPath -Path (Join-Path $userDataRootFull $RetainedDataRelativePath)
    Assert-AcceptanceSafeDescendantFilePath -Path $retainedDataFullPath -Root $userDataRootFull -Context 'Retained data marker'

    $effect = if ($Mode -eq 'Live') { 'LiveFilesystem' } else { 'FixtureTempOnly' }

    if ($Mode -eq 'DryRun') {
        foreach ($phase in @('cleanInstall', 'upgrade', 'rollback', 'uninstall')) {
            $lifecycle[$phase].status = 'SKIPPED'
            $lifecycle[$phase].details = 'Dry-run execution only; no filesystem mutation.'
            Add-OperatorTranscript -Phase $phase -Action 'dry-run-transition' -Status 'SKIPPED' -Effect 'None' -Details 'Dry-run preflight passed.' -PathBinding 'none'
        }
    } else {
        # LIFECYCLE STEP 1: Clean Install (Initial 0.7.0)
        Add-OperatorTranscript -Phase 'CleanInstall' -Action 'invoke-production-install' -Status 'PASS' -Effect $effect -Details "Installing initial version $InitialPackageVersion via Install-HerdrOps.ps1 (staged SHA-256 $($stagedInitial.Sha256))." -PathBinding 'installRoot,userDataRoot'

        Invoke-WithStagedArchiveLocked -StagedPath $stagedInitial.StagedPath -ExpectedBytes $stagedInitial.Length -ExpectedSha256 $stagedInitial.Sha256 -Context 'CleanInstall' -Action {
            $runnerResult = & $effectiveInstallerRunner -Action 'Install' -ArchivePath $stagedInitial.StagedPath -InstallRoot $installRootFull -UserDataRoot $userDataRootFull
            Assert-RunnerResultPass -Result $runnerResult -Context 'Clean install'
        }

        if (-not (Test-Path -LiteralPath $installRootFull -PathType Container)) {
            throw "Clean install failed: InstallRoot does not exist after installation: $installRootFull"
        }

        # Assert installed payload matches artifact shape exactly
        $initialInstalledHashes = Assert-AcceptanceInstalledPayload -InstallRoot $installRootFull -Artifact $initialArtifactHelper -Context 'Clean install'
        $initialArtifactReport.installedFileHashes = $initialInstalledHashes
        $script:CleanMachineFilesystemObserved = ($Mode -eq 'Live')

        # Establish / Verify Retained Data Marker
        if ($RetainedDataMode -eq 'create-test-marker') {
            $createdMarker = New-AcceptanceRetainedDataMarker -UserDataRoot $userDataRootFull -Path $retainedDataFullPath -ExpectedSha256 $RetainedDataSha256
            $retainedDataMarkerData = Get-FileSha256AndBytes -Path $retainedDataFullPath
            $activeRetainedSha256 = $retainedDataMarkerData.Sha256
        } else {
            if (-not (Test-Path -LiteralPath $retainedDataFullPath -PathType Leaf)) {
                throw "Preseeded retained data marker was not found at $retainedDataFullPath."
            }
            $retainedDataMarkerData = Get-FileSha256AndBytes -Path $retainedDataFullPath
            $activeRetainedSha256 = $retainedDataMarkerData.Sha256
            if (-not [string]::IsNullOrWhiteSpace($RetainedDataSha256) -and $activeRetainedSha256 -cne $RetainedDataSha256.ToUpperInvariant()) {
                throw "Preseeded retained data marker SHA-256 mismatch: expected '$RetainedDataSha256', observed '$activeRetainedSha256'."
            }
        }

        $lifecycle.cleanInstall.status = 'PASS'
        $lifecycle.cleanInstall.installedFileHashes = $initialInstalledHashes
        $lifecycle.cleanInstall.installRootPresent = $true
        $lifecycle.cleanInstall.packageVersionObserved = $InitialPackageVersion
        $lifecycle.cleanInstall.retainedDataStatus = 'PASS'
        $lifecycle.cleanInstall.retainedDataSha256 = $activeRetainedSha256
        $lifecycle.cleanInstall.details = "Clean install of version $InitialPackageVersion succeeded with $($initialInstalledHashes.Count) files."
        Add-OperatorTranscript -Phase 'CleanInstall' -Action 'verify-clean-install' -Status 'PASS' -Effect $effect -Details "Clean install payload and retained-data marker verified (executed staged SHA-256 $($stagedInitial.Sha256))." -PathBinding 'installRoot,userDataRoot'

        # LIFECYCLE STEP 2: Bounded First-Run with Process-Tree Cleanup
        Add-OperatorTranscript -Phase 'FirstRun' -Action 'invoke-bounded-first-run' -Status 'PASS' -Effect $effect -Details 'Executing bounded first-run verification and process-tree cleanup.' -PathBinding 'installRoot'
        $firstRunResult = & $effectiveFirstRunRunner -InstallRoot $installRootFull -UserDataRoot $userDataRootFull
        Assert-RunnerResultPass -Result $firstRunResult -Context 'First-run'

        $postFirstRunData = Get-FileSha256AndBytes -Path $retainedDataFullPath
        if ($postFirstRunData.Sha256 -cne $activeRetainedSha256) {
            throw 'Retained data marker was modified or corrupted during first-run.'
        }
        Add-OperatorTranscript -Phase 'FirstRun' -Action 'verify-first-run-quiescence' -Status 'PASS' -Effect $effect -Details 'First-run completed with admitted PIDs terminated and retained data intact.' -PathBinding 'installRoot,userDataRoot'

        # LIFECYCLE STEP 3: Candidate Upgrade (1.0.0)
        Add-OperatorTranscript -Phase 'Upgrade' -Action 'invoke-production-upgrade' -Status 'PASS' -Effect $effect -Details "Upgrading to candidate version $CandidatePackageVersion via Install-HerdrOps.ps1 (staged SHA-256 $($stagedCandidate.Sha256))." -PathBinding 'installRoot,userDataRoot'

        Invoke-WithStagedArchiveLocked -StagedPath $stagedCandidate.StagedPath -ExpectedBytes $stagedCandidate.Length -ExpectedSha256 $stagedCandidate.Sha256 -Context 'Upgrade' -Action {
            $runnerResult = & $effectiveInstallerRunner -Action 'Install' -ArchivePath $stagedCandidate.StagedPath -InstallRoot $installRootFull -UserDataRoot $userDataRootFull
            Assert-RunnerResultPass -Result $runnerResult -Context 'Upgrade'
        }

        if (-not (Test-Path -LiteralPath $installRootFull -PathType Container)) {
            throw "Upgrade failed: InstallRoot does not exist after upgrade: $installRootFull"
        }

        # Assert upgrade payload matches artifact shape exactly
        $upgradeInstalledHashes = Assert-AcceptanceInstalledPayload -InstallRoot $installRootFull -Artifact $upgradeArtifactHelper -Context 'Candidate upgrade'
        $upgradeArtifactReport.installedFileHashes = $upgradeInstalledHashes

        # Verify Retained Data Persistence Across Upgrade
        $postUpgradeData = Get-FileSha256AndBytes -Path $retainedDataFullPath
        if ($postUpgradeData.Sha256 -cne $activeRetainedSha256) {
            throw "Retained data marker SHA-256 changed across upgrade: expected '$activeRetainedSha256', observed '$($postUpgradeData.Sha256)'."
        }

        $lifecycle.upgrade.status = 'PASS'
        $lifecycle.upgrade.installedFileHashes = $upgradeInstalledHashes
        $lifecycle.upgrade.installRootPresent = $true
        $lifecycle.upgrade.packageVersionObserved = $CandidatePackageVersion
        $lifecycle.upgrade.retainedDataStatus = 'PASS'
        $lifecycle.upgrade.retainedDataSha256 = $activeRetainedSha256
        $lifecycle.upgrade.details = "Candidate upgrade to $CandidatePackageVersion succeeded with $($upgradeInstalledHashes.Count) files and preserved user data."
        Add-OperatorTranscript -Phase 'Upgrade' -Action 'verify-upgrade' -Status 'PASS' -Effect $effect -Details "Upgrade payload and retained data verified (executed staged SHA-256 $($stagedCandidate.Sha256))." -PathBinding 'installRoot,userDataRoot'

        # LIFECYCLE STEP 4: Rollback by Accepted-Beta Reinstall (0.7.0)
        Add-OperatorTranscript -Phase 'Rollback' -Action 'invoke-production-rollback' -Status 'PASS' -Effect $effect -Details "Rolling back to version $InitialPackageVersion via Install-HerdrOps.ps1 (staged SHA-256 $($stagedInitial.Sha256))." -PathBinding 'installRoot,userDataRoot'

        Invoke-WithStagedArchiveLocked -StagedPath $stagedInitial.StagedPath -ExpectedBytes $stagedInitial.Length -ExpectedSha256 $stagedInitial.Sha256 -Context 'Rollback' -Action {
            $runnerResult = & $effectiveInstallerRunner -Action 'Install' -ArchivePath $stagedInitial.StagedPath -InstallRoot $installRootFull -UserDataRoot $userDataRootFull
            Assert-RunnerResultPass -Result $runnerResult -Context 'Rollback'
        }

        if (-not (Test-Path -LiteralPath $installRootFull -PathType Container)) {
            throw "Rollback failed: InstallRoot does not exist after rollback: $installRootFull"
        }

        # Assert rollback payload matches initial artifact shape
        $rollbackInstalledHashes = Assert-AcceptanceInstalledPayload -InstallRoot $installRootFull -Artifact $initialArtifactHelper -Context 'Rollback'
        if ($rollbackInstalledHashes.Count -ne $initialInstalledHashes.Count) {
            throw "Rollback installed file count ($($rollbackInstalledHashes.Count)) differs from initial install ($($initialInstalledHashes.Count))."
        }
        for ($i = 0; $i -lt $initialInstalledHashes.Count; $i++) {
            if ([string]$rollbackInstalledHashes[$i].Path -cne [string]$initialInstalledHashes[$i].Path -or
                [int64]$rollbackInstalledHashes[$i].Length -ne [int64]$initialInstalledHashes[$i].Length -or
                [string]$rollbackInstalledHashes[$i].Sha256 -cne [string]$initialInstalledHashes[$i].Sha256) {
                throw "Rollback hash mismatch at index $i ($($initialInstalledHashes[$i].Path))."
            }
        }
        $postRollbackData = Get-FileSha256AndBytes -Path $retainedDataFullPath
        if ($postRollbackData.Sha256 -cne $activeRetainedSha256) {
            throw "Retained data marker SHA-256 changed across rollback: expected '$activeRetainedSha256', observed '$($postRollbackData.Sha256)'."
        }

        $lifecycle.rollback.status = 'PASS'
        $lifecycle.rollback.installedFileHashes = $rollbackInstalledHashes
        $lifecycle.rollback.installRootPresent = $true
        $lifecycle.rollback.packageVersionObserved = $InitialPackageVersion
        $lifecycle.rollback.retainedDataStatus = 'PASS'
        $lifecycle.rollback.retainedDataSha256 = $activeRetainedSha256
        $lifecycle.rollback.details = "Rollback to version $InitialPackageVersion succeeded with byte-identical payload restoration."
        Add-OperatorTranscript -Phase 'Rollback' -Action 'verify-rollback' -Status 'PASS' -Effect $effect -Details "Rollback payload and retained data verified (executed staged SHA-256 $($stagedInitial.Sha256))." -PathBinding 'installRoot,userDataRoot'

        # LIFECYCLE STEP 5: Uninstall without RemoveUserData
        Add-OperatorTranscript -Phase 'Uninstall' -Action 'invoke-production-uninstall' -Status 'PASS' -Effect $effect -Details 'Uninstalling HerdrOps via Uninstall-HerdrOps.ps1 without RemoveUserData.' -PathBinding 'installRoot,userDataRoot'
        $runnerResult = & $effectiveInstallerRunner -Action 'Uninstall' -InstallRoot $installRootFull -UserDataRoot $userDataRootFull -RemoveUserData:$false
        Assert-RunnerResultPass -Result $runnerResult -Context 'Uninstall'

        if (Test-Path -LiteralPath $installRootFull) {
            throw "Uninstall failed: InstallRoot still exists at $installRootFull."
        }
        if (-not (Test-Path -LiteralPath $userDataRootFull -PathType Container)) {
            throw "Uninstall policy violated: UserDataRoot was deleted: $userDataRootFull"
        }
        $postUninstallData = Get-FileSha256AndBytes -Path $retainedDataFullPath
        if ($postUninstallData.Sha256 -cne $activeRetainedSha256) {
            throw "Retained data marker was damaged during uninstall: expected '$activeRetainedSha256', observed '$($postUninstallData.Sha256)'."
        }

        $lifecycle.uninstall.status = 'PASS'
        $lifecycle.uninstall.installedFileHashes = @()
        $lifecycle.uninstall.installRootPresent = $false
        $lifecycle.uninstall.packageVersionObserved = $InitialPackageVersion
        $lifecycle.uninstall.retainedDataStatus = 'PASS'
        $lifecycle.uninstall.retainedDataSha256 = $activeRetainedSha256
        $lifecycle.uninstall.details = 'Uninstall succeeded; install root removed and retained user data left intact.'
        Add-OperatorTranscript -Phase 'Uninstall' -Action 'verify-uninstall' -Status 'PASS' -Effect $effect -Details 'Install root removed and retained data verified.' -PathBinding 'userDataRoot'
    }

    # Residuals & Cleanup Verification
    $residuals = New-Object System.Collections.ArrayList
    if (Test-Path -LiteralPath $installParent) {
        $staleDirs = @(Get-ChildItem -LiteralPath $installParent -Directory -Force | Where-Object {
            $_.Name -match '^HerdrOps\.(staging|backup|harness)-'
        })
        foreach ($d in $staleDirs) {
            [void]$residuals.Add($d.FullName)
        }
    }
    $cleanup.status = if ($residuals.Count -eq 0) { 'PASS' } else { 'FAIL' }
    $cleanup.attempted = $true
    $cleanup.residuals = @($residuals.ToArray())
    $cleanup.details = if ($residuals.Count -eq 0) { 'Zero leftover installer transients observed.' } else { "Residuals observed: $($residuals -join '; ')" }
    if ($residuals.Count -gt 0) {
        throw "Cleanup residual check failed: $($residuals -join '; ')"
    }

} catch {
    $status = 'FAIL'
    $failureDetails = $_.Exception.Message
    Add-OperatorTranscript -Phase 'Failure' -Action 'fail-closed' -Status 'FAIL' -Effect 'None' -Details $failureDetails -PathBinding 'none'
} finally {
    if ($null -ne $script:OwnedStagingDirectory -and (Test-Path -LiteralPath $script:OwnedStagingDirectory)) {
        try {
            Remove-Item -LiteralPath $script:OwnedStagingDirectory -Recurse -Force -ErrorAction SilentlyContinue
            $cleanup.ownedStageRemoved = $true
        } catch {
            $cleanup.ownedStageRemoved = $false
        }
    }
    if ($null -ne $script:OwnedSimulationDirectory -and (Test-Path -LiteralPath $script:OwnedSimulationDirectory)) {
        try {
            Remove-Item -LiteralPath $script:OwnedSimulationDirectory -Recurse -Force -ErrorAction SilentlyContinue
            $cleanup.simulationRootRemoved = $true
        } catch {
            $cleanup.simulationRootRemoved = $false
        }
    }
}

$evidenceClass = if ($Mode -eq 'Live' -and $status -eq 'PASS') {
    'CleanMachine'
} elseif ($Mode -eq 'Fixture') {
    'Synthetic'
} else {
    'Static'
}

$preflightPassed = ($script:PreflightChecks.Count -gt 0 -and
    @($script:PreflightChecks | Where-Object { $_.status -eq 'FAIL' }).Count -eq 0)
$allLifecyclePassed = @(@('cleanInstall', 'upgrade', 'rollback', 'uninstall') | Where-Object {
        [string]$lifecycle[$_].status -cne 'PASS'
    }).Count -eq 0
$cleanMachinePassed = ($evidenceClass -ceq 'CleanMachine' -and $status -ceq 'PASS' -and $allLifecyclePassed -and [string]$cleanup.status -ceq 'PASS')

$report = [ordered]@{
    schemaVersion = 1
    reportKind = 'HerdrOps.InstallAcceptanceReport'
    issue = $script:AcceptanceIssue
    acceptanceVersion = $script:AcceptanceVersion
    status = $status
    mode = $Mode
    evidenceClass = $evidenceClass
    startedAtUtc = $script:StartedAtUtc
    completedAtUtc = Get-OperatorUtcNow
    runId = $script:RunId
    machine = [ordered]@{
        name = $(if ([string]::IsNullOrWhiteSpace($machineName)) { [string]$env:COMPUTERNAME } else { $machineName })
        expectedName = $(if ([string]::IsNullOrWhiteSpace($ExpectedMachineName)) { [string]$env:COMPUTERNAME } else { $ExpectedMachineName })
        fingerprint = $(if ([string]::IsNullOrWhiteSpace($machineFingerprint)) { Get-AcceptanceMachineFingerprint } else { $machineFingerprint })
        expectedFingerprint = $(if ([string]::IsNullOrWhiteSpace($ExpectedMachineFingerprint)) { Get-AcceptanceMachineFingerprint } else { $ExpectedMachineFingerprint })
        elevated = $isElevated
    }
    artifacts = [ordered]@{
        initial = $initialArtifactReport
        upgrade = $upgradeArtifactReport
    }
    targets = $targetsReport
    preflight = [ordered]@{
        status = if ($preflightPassed) { 'PASS' } else { 'FAIL' }
        checks = @($script:PreflightChecks.ToArray())
    }
    lifecycle = $lifecycle
    cleanup = $cleanup
    failureDetails = $failureDetails
    transcript = @($script:Transcript.ToArray())
    boundaries = [ordered]@{
        static = if ($preflightPassed) { 'PASS: acceptance operator source, paths, archive hashes, and contracts verified.' } else { "OBSERVED $status`: static preflight failed." }
        synthetic = if ($Mode -eq 'Fixture') { 'PASS: fixture lifecycle execution.' } else { 'NOT OBSERVED BY THIS LIVE INVOCATION' }
        contract = 'NOT OBSERVED: no named-pipe or installed-Herdr IPC compatibility assertions.'
        cleanMachine = if ($cleanMachinePassed) { 'PASS: live clean-machine filesystem install, upgrade, rollback, uninstall, and settings retention lifecycle.' } else { 'NOT OBSERVED' }
        runtime = 'NOT OBSERVED: no live Herdr runtime connection was evaluated.'
        independentReview = 'NOT OBSERVED.'
        release = 'NOT OBSERVED: no package publication or GitHub Release action performed.'
    }
}

$reportSchemaPath = Join-Path $PSScriptRoot '..\..\docs\acceptance\issue-44-install-acceptance-report.schema.json'
if (Test-Path -LiteralPath $reportSchemaPath -PathType Leaf) {
    Assert-AcceptanceReportMatchesSchema -Report $report -SchemaPath $reportSchemaPath
}

if (-not [string]::IsNullOrWhiteSpace($ReportDestination) -and $null -ne $targetsReport.installRoot) {
    $script:ReportDestination = Write-AcceptanceReportAtomically `
        -Report $report `
        -Path $ReportDestination `
        -InstallRoot $targetsReport.installRoot `
        -UserDataRoot $targetsReport.userDataRoot `
        -AllowExternalParent:($Mode -eq 'Live')
}

if ($status -ne 'PASS') {
    Write-Output $report
    throw "Issue #44 live operator failed: $failureDetails"
}

Write-Output $report