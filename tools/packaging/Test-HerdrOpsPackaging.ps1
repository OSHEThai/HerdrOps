#requires -Version 5.1

[CmdletBinding()]
param(
    [string]$ProfilePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Packaging.Common.ps1')

if ([string]::IsNullOrWhiteSpace($ProfilePath)) {
    $ProfilePath = Join-Path $PSScriptRoot 'package-profile.json'
}

function Assert-ExpectedFailure {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $failed = $false
    try {
        & $Action
    } catch {
        $failed = $true
    }
    if (-not $failed) {
        throw "Fail-closed check unexpectedly succeeded: $Description"
    }
}

function Assert-ExpectedFailureContaining {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)][string[]]$RequiredFragments
    )

    $message = $null
    try {
        & $Action | Out-Null
    } catch {
        $message = [string]$_.Exception.Message
    }
    if ([string]::IsNullOrWhiteSpace($message)) {
        throw "Fail-closed check unexpectedly succeeded: $Description"
    }
    foreach ($fragment in $RequiredFragments) {
        if ($message.IndexOf($fragment, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
            throw "Failure for '$Description' did not contain required context '$fragment': $message"
        }
    }

    return $message
}

function Assert-NoPackagingStagingFiles {
    param(
        [Parameter(Mandatory = $true)][string]$Parent,
        [Parameter(Mandatory = $true)][string]$Description
    )

    if (-not (Test-Path -LiteralPath $Parent -PathType Container)) {
        return
    }
    $leftovers = @(Get-ChildItem -LiteralPath $Parent -Force |
        Where-Object { $_.Name -like '.*.staging-*' -or $_.Name -like '.*.backup-*' })
    if ($leftovers.Count -ne 0) {
        throw "Atomic $Description left owned transient files: $($leftovers.Name -join ', ')"
    }
}

$profile = Read-PackageProfile -Path $ProfilePath
$null = Assert-V070PreparationProfile -Profile $profile
$repositoryRoot = Get-PackagingRepositoryRoot
Assert-ProjectMatchesPackageProfile -Profile $profile -RepositoryRoot $repositoryRoot

$implementationFiles = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -File |
    Where-Object { $_.Name -ne 'Test-HerdrOpsPackaging.ps1' })
$toolText = ($implementationFiles | Get-Content -Raw) -join "`n"
foreach ($forbiddenMarker in @(
        'New-ItemProperty',
        'Set-ItemProperty',
        'Remove-ItemProperty',
        'Registry::',
        'reg.exe',
        'Start-Process',
        'HERDR_SOCKET_PATH',
        'herdr.exe')) {
    if ($toolText.IndexOf($forbiddenMarker, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
        throw "Packaging preparation tool contains a forbidden runtime or registry marker: $forbiddenMarker"
    }
}
if ($toolText.IndexOf('RestorePackagesWithLockFile=false', [StringComparison]::Ordinal) -lt 0 -or
    $toolText.IndexOf('NuGetLockFilePath=', [StringComparison]::Ordinal) -lt 0) {
    throw 'Publish tooling is missing its isolated restore-lock safety boundary.'
}

$realLocalAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
Assert-ExpectedFailure -Description 'real LocalAppData destination guard' -Action {
    Assert-SafeDestination -Path (Join-Path $realLocalAppData 'Programs\HerdrOps') -AllowRepositoryChild -AllowTempChild | Out-Null
}

$testRoot = New-PackagingTempDirectory -Prefix 'HerdrOps-Test-'
try {
    $packageOne = Join-Path $testRoot 'package-one'
    $packageTwo = Join-Path $testRoot 'package-two'
    $fixture = Join-Path $repositoryRoot 'tests\fixtures\v0.7\packaging\initial'
    Copy-SafeDirectoryContents -Source $fixture -Destination $packageOne
    Copy-SafeDirectoryContents -Source $fixture -Destination $packageTwo

    $manifestOne = New-PackageManifestObject -Profile $profile -PackageRoot $packageOne
    $manifestTwo = New-PackageManifestObject -Profile $profile -PackageRoot $packageTwo
    Write-PackageManifest -Manifest $manifestOne -PackageRoot $packageOne | Out-Null
    Write-PackageManifest -Manifest $manifestTwo -PackageRoot $packageTwo | Out-Null
    Assert-PackageManifestMatchesRoot -Profile $profile -PackageRoot $packageOne | Out-Null
    Assert-PackageManifestMatchesRoot -Profile $profile -PackageRoot $packageTwo | Out-Null

    $singlePackageRoot = Join-Path $testRoot 'single-file-package'
    Copy-SafeDirectoryContents -Source $fixture -Destination $singlePackageRoot
    [IO.File]::Delete((Join-Path $singlePackageRoot 'HerdrOps.App.payload'))
    [IO.File]::Delete((Join-Path $singlePackageRoot 'HerdrOps.Core.payload'))
    $singleManifest = New-PackageManifestObject -Profile $profile -PackageRoot $singlePackageRoot
    Write-PackageManifest -Manifest $singleManifest -PackageRoot $singlePackageRoot | Out-Null
    Assert-PackageManifestMatchesRoot -Profile $profile -PackageRoot $singlePackageRoot | Out-Null

    $manifestEntryRoot = Join-Path $testRoot 'manifest-entry-point'
    Copy-SafeDirectoryContents -Source $fixture -Destination $manifestEntryRoot
    $manifestEntryResult = @(& (Join-Path $PSScriptRoot 'New-PackageManifest.ps1') `
        -PackageRoot $manifestEntryRoot `
        -ProfilePath $ProfilePath)
    if ($manifestEntryResult.Count -ne 1 -or
        [string]$manifestEntryResult[0].EvidenceClass -cne 'Static' -or
        -not (Test-Path -LiteralPath (Join-Path $manifestEntryRoot 'package-manifest.json') -PathType Leaf)) {
        throw 'New-PackageManifest entry point did not produce one static manifest result.'
    }

    $manifestOnePath = Join-Path $packageOne 'package-manifest.json'
    $manifestTwoPath = Join-Path $packageTwo 'package-manifest.json'
    $manifestOneBytes = [IO.File]::ReadAllBytes($manifestOnePath)
    $manifestTwoBytes = [IO.File]::ReadAllBytes($manifestTwoPath)
    if (-not ([System.Linq.Enumerable]::SequenceEqual($manifestOneBytes, $manifestTwoBytes))) {
        throw 'Repeated manifest generation was not byte-identical.'
    }

    $archiveOne = Join-Path $testRoot 'one.zip'
    $archiveTwo = Join-Path $testRoot 'two.zip'
    New-DeterministicPackageArchive -PackageRoot $packageOne -ArchivePath $archiveOne | Out-Null
    New-DeterministicPackageArchive -PackageRoot $packageTwo -ArchivePath $archiveTwo | Out-Null
    $archiveHashOne = ((Get-FileHash -LiteralPath $archiveOne -Algorithm SHA256).Hash).ToUpperInvariant()
    $archiveHashTwo = ((Get-FileHash -LiteralPath $archiveTwo -Algorithm SHA256).Hash).ToUpperInvariant()
    if ($archiveHashOne -cne $archiveHashTwo) {
        throw "Repeated deterministic archive generation drifted: $archiveHashOne vs $archiveHashTwo"
    }

    $outsideProbeRoot = Join-Path (Split-Path -Path (Normalize-ComparablePath -Path ([IO.Path]::GetTempPath())) -Parent) `
        ('HerdrOps-Packaging-OutOfScope-' + [Guid]::NewGuid().ToString('N'))
    $outsideArchivePath = Join-Path $outsideProbeRoot 'archive.zip'
    $outsideHashPath = Join-Path $outsideProbeRoot 'package-hashes.txt'
    $entryPointArchive = Join-Path $testRoot 'entry-point.zip'
    $entryPointHash = Join-Path $testRoot 'entry-point-hashes.txt'
    $overlapOutputUnderPackage = Join-Path $packageOne 'output'
    Assert-ExpectedFailure -Description 'publication rejects output nested under package root before side effects' -Action {
        Publish-PackageArtifactsAtomically `
            -PackageRoot $packageOne `
            -ArchivePath $archiveOne `
            -HashRecordPath (Join-Path $testRoot 'one-overlap-hashes.txt') `
            -OutputRoot $overlapOutputUnderPackage | Out-Null
    }
    if (Test-Path -LiteralPath $overlapOutputUnderPackage) {
        throw 'Nested output overlap validation created an output path.'
    }
    $overlapReverseRoot = Join-Path $testRoot 'overlap-reverse'
    $overlapReversePackage = Join-Path $overlapReverseRoot 'package'
    $overlapCases = @(
        @{ Name = 'output under package'; LeftName = 'package'; Left = $packageOne; RightName = 'output'; Right = $overlapOutputUnderPackage },
        @{ Name = 'package under output'; LeftName = 'package'; Left = $overlapReversePackage; RightName = 'output'; Right = $overlapReverseRoot },
        @{ Name = 'equivalent package/output'; LeftName = 'package'; Left = $packageOne; RightName = 'output'; Right = $packageOne },
        @{ Name = 'nested archive/hash'; LeftName = 'archive'; Left = (Join-Path $testRoot 'nested'); RightName = 'hash'; Right = (Join-Path $testRoot 'nested\hash.txt') })
    foreach ($overlapCase in $overlapCases) {
        Assert-ExpectedFailure -Description $overlapCase.Name -Action {
            Assert-PackagingPathsDoNotOverlap -Paths @(
                [pscustomobject]@{ Name = $overlapCase.LeftName; Path = $overlapCase.Left },
                [pscustomobject]@{ Name = $overlapCase.RightName; Path = $overlapCase.Right },
                [pscustomobject]@{ Name = 'staging'; Path = (Get-PackagingStagingProbePath -DestinationPath $overlapCase.Right -Directory) })
        }
    }
    if (Test-Path -LiteralPath $overlapReverseRoot) {
        throw 'Reverse overlap validation created a path.'
    }
    Assert-ExpectedFailure -Description 'New-PackageArchive validates hash destination before archive side effects' -Action {
        & (Join-Path $PSScriptRoot 'New-PackageArchive.ps1') `
            -PackageRoot $packageOne `
            -ProfilePath $ProfilePath `
            -ArchivePath $entryPointArchive `
            -HashRecordPath $outsideHashPath | Out-Null
    }
    if (Test-Path -LiteralPath $entryPointArchive) {
        throw 'Unsafe hash destination validation left an archive behind.'
    }
    if (Test-Path -LiteralPath $outsideProbeRoot) {
        throw "Unsafe hash destination validation created an outside path: $outsideProbeRoot"
    }

    foreach ($pairStage in @('Archive', 'Hash', 'AfterArchive', 'AfterHash', 'Verify', 'BeforeCommit', 'AfterArchiveMove', 'AfterHashMove', 'CommitMarker')) {
        $pairFaultArchive = Join-Path $testRoot ("entry-point-fault-$pairStage.zip")
        $pairFaultHash = Join-Path $testRoot ("entry-point-fault-$pairStage-hashes.txt")
        Assert-ExpectedFailureContaining -Description ("New-PackageArchive pair fault stage $pairStage") -RequiredFragments @(
            'Injected package') -Action {
            & (Join-Path $PSScriptRoot 'New-PackageArchive.ps1') `
                -PackageRoot $packageOne `
                -ProfilePath $ProfilePath `
                -ArchivePath $pairFaultArchive `
                -HashRecordPath $pairFaultHash `
                -TestFaultInjectionStage $pairStage | Out-Null
        } | Out-Null
        if ((Test-Path -LiteralPath $pairFaultArchive) -or (Test-Path -LiteralPath $pairFaultHash)) {
            throw "Archive pair fault stage $pairStage left a final file."
        }
        $pairFaultMarker = Get-PackagingPairCommitMarkerPath -ArchivePath $pairFaultArchive -HashRecordPath $pairFaultHash
        if (Test-Path -LiteralPath $pairFaultMarker) {
            throw "Archive pair fault stage $pairStage left a visible committed marker."
        }
        Assert-NoPackagingStagingFiles -Parent $testRoot -Description ("archive pair fault stage $pairStage")
        & (Join-Path $PSScriptRoot 'New-PackageArchive.ps1') `
            -PackageRoot $packageOne `
            -ProfilePath $ProfilePath `
            -ArchivePath $pairFaultArchive `
            -HashRecordPath $pairFaultHash | Out-Null
        if (-not (Test-Path -LiteralPath $pairFaultArchive -PathType Leaf) -or
            -not (Test-Path -LiteralPath $pairFaultHash -PathType Leaf)) {
            throw "Archive pair retry failed after fault stage $pairStage."
        }
        if (-not (Test-Path -LiteralPath $pairFaultMarker -PathType Leaf)) {
            throw "Archive pair retry after fault stage $pairStage did not publish one commit marker."
        }
        Assert-PackageArchiveHashPairCommitted -Profile $profile -PackageRoot $packageOne -ArchivePath $pairFaultArchive -HashRecordPath $pairFaultHash | Out-Null
        Assert-NoPackagingStagingFiles -Parent $testRoot -Description ("archive pair retry after $pairStage")
    }
    Assert-ExpectedFailureContaining -Description 'New-PackageArchive pair cleanup error ordering' -RequiredFragments @(
        'Injected package archive pair failure after archive staging.',
        'Cleanup also failed: Injected package archive pair cleanup failure.') -Action {
        & (Join-Path $PSScriptRoot 'New-PackageArchive.ps1') `
            -PackageRoot $packageOne `
            -ProfilePath $ProfilePath `
            -ArchivePath (Join-Path $testRoot 'entry-point-cleanup.zip') `
            -HashRecordPath (Join-Path $testRoot 'entry-point-cleanup-hashes.txt') `
            -TestFaultInjectionStage 'AfterArchive' `
            -TestInjectCleanupFailure | Out-Null
    } | Out-Null
    Assert-NoPackagingStagingFiles -Parent $testRoot -Description 'archive pair cleanup error ordering'
    & (Join-Path $PSScriptRoot 'New-PackageArchive.ps1') `
        -PackageRoot $packageOne `
        -ProfilePath $ProfilePath `
        -ArchivePath $entryPointArchive `
        -HashRecordPath $entryPointHash | Out-Null
    if (-not (Test-Path -LiteralPath $entryPointArchive -PathType Leaf) -or
        -not (Test-Path -LiteralPath $entryPointHash -PathType Leaf)) {
        throw 'New-PackageArchive retry did not create archive and hash record.'
    }
    if ((Get-Content -LiteralPath $entryPointHash -Raw).IndexOf('ArchiveFile: entry-point.zip', [StringComparison]::Ordinal) -lt 0) {
        throw 'New-PackageArchive hash record did not bind to the final archive name.'
    }
    $entryPointMarker = Get-PackagingPairCommitMarkerPath -ArchivePath $entryPointArchive -HashRecordPath $entryPointHash
    if (-not (Test-Path -LiteralPath $entryPointMarker -PathType Leaf)) {
        throw 'New-PackageArchive did not publish a single commit marker for the archive/hash pair.'
    }
    Assert-PackageArchiveHashPairCommitted -Profile $profile -PackageRoot $packageOne -ArchivePath $entryPointArchive -HashRecordPath $entryPointHash | Out-Null
    Assert-NoPackagingStagingFiles -Parent $testRoot -Description 'entry-point retry'

    Assert-ExpectedFailure -Description 'archive destination outside authorized repo/temp policy has no side effects' -Action {
        New-DeterministicPackageArchive -PackageRoot $packageOne -ArchivePath $outsideArchivePath | Out-Null
    }
    if (Test-Path -LiteralPath $outsideProbeRoot) {
        throw "Unsafe archive destination created an outside path: $outsideProbeRoot"
    }

    $hashOne = Join-Path $testRoot 'one-hashes.txt'
    Write-PackageHashRecord -Profile $profile -PackageRoot $packageOne -ArchivePath $archiveOne -Path $hashOne | Out-Null
    Assert-ExpectedFailure -Description 'uncommitted archive/hash pair is not readable' -Action {
        Assert-PackageArchiveHashPairCommitted -Profile $profile -PackageRoot $packageOne -ArchivePath $archiveOne -HashRecordPath $hashOne | Out-Null
    }
    $hashOneOriginalText = [IO.File]::ReadAllText($hashOne)
    $tamperedHashOneText = [Text.RegularExpressions.Regex]::Replace(
        $hashOneOriginalText,
        '(?m)^ArchiveSha256: [0-9A-F]{64}$',
        ('ArchiveSha256: ' + ('0' * 64)))
    Write-DeterministicTextFile -Path $hashOne -Text $tamperedHashOneText
    Assert-ExpectedFailureContaining -Description 'hash record independent archive-byte binding' -RequiredFragments @(
        'independently computed archive bytes') -Action {
        Assert-PackageHashRecordMatchesArchive -Profile $profile -PackageRoot $packageOne -ArchivePath $archiveOne -HashRecordPath $hashOne | Out-Null
    } | Out-Null
    [IO.File]::WriteAllText($hashOne, $hashOneOriginalText, (New-Object System.Text.UTF8Encoding($false)))
    Assert-PackageHashRecordMatchesArchive -Profile $profile -PackageRoot $packageOne -ArchivePath $archiveOne -HashRecordPath $hashOne | Out-Null
    Assert-ExpectedFailure -Description 'hash record destination outside authorized repo/temp policy has no side effects' -Action {
        Write-PackageHashRecord -Profile $profile -PackageRoot $packageOne -ArchivePath $archiveOne -Path $outsideHashPath | Out-Null
    }
    if (Test-Path -LiteralPath $outsideProbeRoot) {
        throw "Unsafe hash-record destination created an outside path: $outsideProbeRoot"
    }

    $manifestFaultRoot = Join-Path $testRoot 'manifest-fault'
    Copy-SafeDirectoryContents -Source $fixture -Destination $manifestFaultRoot
    $manifestFault = New-PackageManifestObject -Profile $profile -PackageRoot $manifestFaultRoot
    $manifestFaultPath = Join-Path $manifestFaultRoot 'package-manifest.json'
    Assert-ExpectedFailureContaining -Description 'manifest mid-write rollback' -RequiredFragments @(
        'Injected package manifest failure during staged write.') -Action {
        Write-PackageManifest `
            -Manifest $manifestFault `
            -PackageRoot $manifestFaultRoot `
            -TestFaultInjectionStage 'MidWrite' | Out-Null
    } | Out-Null
    if (Test-Path -LiteralPath $manifestFaultPath) {
        throw 'Manifest mid-write fault left a partial destination.'
    }
    Assert-NoPackagingStagingFiles -Parent $manifestFaultRoot -Description 'manifest mid-write failure'
    Write-PackageManifest -Manifest $manifestFault -PackageRoot $manifestFaultRoot | Out-Null
    Assert-PackageManifestMatchesRoot -Profile $profile -PackageRoot $manifestFaultRoot | Out-Null

    $manifestBeforeCommitRoot = Join-Path $testRoot 'manifest-before-commit-fault'
    Copy-SafeDirectoryContents -Source $fixture -Destination $manifestBeforeCommitRoot
    $manifestBeforeCommit = New-PackageManifestObject -Profile $profile -PackageRoot $manifestBeforeCommitRoot
    $manifestBeforeCommitPath = Join-Path $manifestBeforeCommitRoot 'package-manifest.json'
    Assert-ExpectedFailureContaining -Description 'manifest before-commit rollback' -RequiredFragments @(
        'Injected package manifest failure before atomic commit.') -Action {
        Write-PackageManifest `
            -Manifest $manifestBeforeCommit `
            -PackageRoot $manifestBeforeCommitRoot `
            -TestFaultInjectionStage 'BeforeCommit' | Out-Null
    } | Out-Null
    if (Test-Path -LiteralPath $manifestBeforeCommitPath) {
        throw 'Manifest before-commit fault left a final destination.'
    }
    Assert-NoPackagingStagingFiles -Parent $manifestBeforeCommitRoot -Description 'manifest before-commit failure'
    Write-PackageManifest -Manifest $manifestBeforeCommit -PackageRoot $manifestBeforeCommitRoot | Out-Null
    Assert-PackageManifestMatchesRoot -Profile $profile -PackageRoot $manifestBeforeCommitRoot | Out-Null

    $manifestCleanupRoot = Join-Path $testRoot 'manifest-cleanup-fault'
    Copy-SafeDirectoryContents -Source $fixture -Destination $manifestCleanupRoot
    $manifestCleanup = New-PackageManifestObject -Profile $profile -PackageRoot $manifestCleanupRoot
    $manifestCleanupPath = Join-Path $manifestCleanupRoot 'package-manifest.json'
    Assert-ExpectedFailureContaining -Description 'manifest cleanup error ordering' -RequiredFragments @(
        'Injected package manifest failure during staged write.',
        'Cleanup also failed: Injected package manifest cleanup failure.') -Action {
        Write-PackageManifest `
            -Manifest $manifestCleanup `
            -PackageRoot $manifestCleanupRoot `
            -TestFaultInjectionStage 'MidWrite' `
            -TestInjectCleanupFailure | Out-Null
    } | Out-Null
    if (Test-Path -LiteralPath $manifestCleanupPath) {
        throw 'Manifest cleanup fault left a partial destination.'
    }
    Assert-NoPackagingStagingFiles -Parent $manifestCleanupRoot -Description 'manifest cleanup failure'
    Write-PackageManifest -Manifest $manifestCleanup -PackageRoot $manifestCleanupRoot | Out-Null
    Assert-PackageManifestMatchesRoot -Profile $profile -PackageRoot $manifestCleanupRoot | Out-Null

    $archiveFault = Join-Path $testRoot 'archive-fault.zip'
    Assert-ExpectedFailureContaining -Description 'archive mid-write rollback' -RequiredFragments @(
        'Injected package archive failure during staged write.') -Action {
        New-DeterministicPackageArchive `
            -PackageRoot $packageOne `
            -ArchivePath $archiveFault `
            -TestFaultInjectionStage 'MidWrite' | Out-Null
    } | Out-Null
    if (Test-Path -LiteralPath $archiveFault) {
        throw 'Archive mid-write fault left a partial destination.'
    }
    Assert-NoPackagingStagingFiles -Parent $testRoot -Description 'archive mid-write failure'
    New-DeterministicPackageArchive -PackageRoot $packageOne -ArchivePath $archiveFault | Out-Null
    if (-not (Test-Path -LiteralPath $archiveFault -PathType Leaf)) {
        throw 'Archive retry did not create the destination.'
    }

    $archiveBeforeCommitFault = Join-Path $testRoot 'archive-before-commit-fault.zip'
    Assert-ExpectedFailureContaining -Description 'archive before-commit rollback' -RequiredFragments @(
        'Injected package archive failure before atomic commit.') -Action {
        New-DeterministicPackageArchive `
            -PackageRoot $packageOne `
            -ArchivePath $archiveBeforeCommitFault `
            -TestFaultInjectionStage 'BeforeCommit' | Out-Null
    } | Out-Null
    if (Test-Path -LiteralPath $archiveBeforeCommitFault) {
        throw 'Archive before-commit fault left a final destination.'
    }
    Assert-NoPackagingStagingFiles -Parent $testRoot -Description 'archive before-commit failure'
    New-DeterministicPackageArchive -PackageRoot $packageOne -ArchivePath $archiveBeforeCommitFault | Out-Null

    $hashFault = Join-Path $testRoot 'hash-fault.txt'
    Assert-ExpectedFailureContaining -Description 'hash-record mid-write rollback' -RequiredFragments @(
        'Injected package hash record failure during staged write.') -Action {
        Write-PackageHashRecord `
            -Profile $profile `
            -PackageRoot $packageOne `
            -ArchivePath $archiveOne `
            -Path $hashFault `
            -TestFaultInjectionStage 'MidWrite' | Out-Null
    } | Out-Null
    if (Test-Path -LiteralPath $hashFault) {
        throw 'Hash-record mid-write fault left a partial destination.'
    }
    Assert-NoPackagingStagingFiles -Parent $testRoot -Description 'hash-record mid-write failure'
    Write-PackageHashRecord -Profile $profile -PackageRoot $packageOne -ArchivePath $archiveOne -Path $hashFault | Out-Null
    if (-not (Test-Path -LiteralPath $hashFault -PathType Leaf)) {
        throw 'Hash-record retry did not create the destination.'
    }

    $hashBeforeCommitFault = Join-Path $testRoot 'hash-before-commit-fault.txt'
    Assert-ExpectedFailureContaining -Description 'hash-record before-commit rollback' -RequiredFragments @(
        'Injected package hash record failure before atomic commit.') -Action {
        Write-PackageHashRecord `
            -Profile $profile `
            -PackageRoot $packageOne `
            -ArchivePath $archiveOne `
            -Path $hashBeforeCommitFault `
            -TestFaultInjectionStage 'BeforeCommit' | Out-Null
    } | Out-Null
    if (Test-Path -LiteralPath $hashBeforeCommitFault) {
        throw 'Hash-record before-commit fault left a final destination.'
    }
    Assert-NoPackagingStagingFiles -Parent $testRoot -Description 'hash-record before-commit failure'
    Write-PackageHashRecord -Profile $profile -PackageRoot $packageOne -ArchivePath $archiveOne -Path $hashBeforeCommitFault | Out-Null

    $copyRollbackRoot = Join-Path $testRoot 'copy-rollback'
    New-Item -ItemType Directory -Path $copyRollbackRoot -Force | Out-Null
    $copySource = Join-Path $packageOne 'HerdrOps.App.payload'
    $copyDestination = Join-Path $copyRollbackRoot 'HerdrOps.App.payload'
    $copyOriginalText = 'original destination bytes'
    foreach ($copyStage in @('Write', 'Verify', 'Replace', 'AfterReplace')) {
        Write-DeterministicTextFile -Path $copyDestination -Text $copyOriginalText
        $copyOriginalHash = ((Get-FileHash -LiteralPath $copyDestination -Algorithm SHA256).Hash).ToUpperInvariant()
        Assert-ExpectedFailureContaining -Description ("overwrite rollback stage " + $copyStage) -RequiredFragments @(
            'Injected durable copy') -Action {
            Copy-PackagingFileDurably -Source $copySource -Destination $copyDestination -Overwrite -TestFaultInjectionStage $copyStage | Out-Null
        } | Out-Null
        if (-not (Test-Path -LiteralPath $copyDestination -PathType Leaf) -or
            ((Get-FileHash -LiteralPath $copyDestination -Algorithm SHA256).Hash).ToUpperInvariant() -cne $copyOriginalHash) {
            throw "Overwrite rollback stage $copyStage did not restore the original destination bytes."
        }
        Assert-NoPackagingStagingFiles -Parent $copyRollbackRoot -Description ("overwrite rollback stage " + $copyStage)
    }
    Write-DeterministicTextFile -Path $copyDestination -Text $copyOriginalText
    $copyOriginalHash = ((Get-FileHash -LiteralPath $copyDestination -Algorithm SHA256).Hash).ToUpperInvariant()
    Assert-ExpectedFailureContaining -Description 'overwrite rollback delete failure' -RequiredFragments @(
        'Injected durable copy backup delete failure') -Action {
        Copy-PackagingFileDurably -Source $copySource -Destination $copyDestination -Overwrite -TestFaultInjectionStage 'Delete' | Out-Null
    } | Out-Null
    if (-not (Test-Path -LiteralPath $copyDestination -PathType Leaf) -or
        ((Get-FileHash -LiteralPath $copyDestination -Algorithm SHA256).Hash).ToUpperInvariant() -cne $copyOriginalHash) {
        throw 'Overwrite rollback delete failure did not restore the original destination bytes.'
    }
    Assert-NoPackagingStagingFiles -Parent $copyRollbackRoot -Description 'overwrite rollback delete failure'

    Write-DeterministicTextFile -Path $copyDestination -Text $copyOriginalText
    Assert-ExpectedFailureContaining -Description 'overwrite rollback cleanup context' -RequiredFragments @(
        'Injected durable copy verification failure.',
        'Cleanup also failed: Injected durable copy cleanup failure.') -Action {
        Copy-PackagingFileDurably -Source $copySource -Destination $copyDestination -Overwrite -TestFaultInjectionStage 'Verify' -TestInjectCleanupFailure | Out-Null
    } | Out-Null
    Copy-PackagingFileDurably -Source $copySource -Destination $copyDestination -Overwrite | Out-Null
    Assert-PackagingFileMatchesSource -Source $copySource -Destination $copyDestination -Description 'overwrite rollback successful retry'
    Assert-NoPackagingStagingFiles -Parent $copyRollbackRoot -Description 'overwrite rollback successful retry'

    foreach ($publicationStage in @('AfterPackage', 'AfterArchive', 'AfterHash', 'BeforeCommit')) {
        $faultOutputRoot = Join-Path $testRoot ("atomic-output-$publicationStage")
        Assert-ExpectedFailureContaining -Description ("atomic publication fault stage $publicationStage") -RequiredFragments @(
            'Injected atomic publication failure') -Action {
            Publish-PackageArtifactsAtomically `
                -PackageRoot $packageOne `
                -ArchivePath $archiveOne `
                -HashRecordPath $hashOne `
                -OutputRoot $faultOutputRoot `
                -FaultInjectionStage $publicationStage | Out-Null
        } | Out-Null
        if (Test-Path -LiteralPath $faultOutputRoot) {
            throw "Atomic publication fault stage $publicationStage left an output root."
        }
        Assert-NoPackagingStagingFiles -Parent $testRoot -Description ("publication fault stage $publicationStage")
    }

    $atomicOutputRoot = Join-Path $testRoot 'atomic-output'

    $atomicPublication = Publish-PackageArtifactsAtomically `
        -PackageRoot $packageOne `
        -ArchivePath $archiveOne `
        -HashRecordPath $hashOne `
        -OutputRoot $atomicOutputRoot
    if (-not (Test-Path -LiteralPath $atomicPublication.PackageRoot -PathType Container) -or
        -not (Test-Path -LiteralPath $atomicPublication.ArchivePath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $atomicPublication.HashRecordPath -PathType Leaf)) {
        throw 'Atomic publication retry did not produce one coherent package output.'
    }
    if (@(Get-ChildItem -LiteralPath $atomicOutputRoot -Force).Count -ne 3) {
        throw 'Atomic publication output did not contain exactly package, archive, and hash record.'
    }
    if (((Get-FileHash -LiteralPath $atomicPublication.ArchivePath -Algorithm SHA256).Hash).ToUpperInvariant() -cne
        ((Get-FileHash -LiteralPath $archiveOne -Algorithm SHA256).Hash).ToUpperInvariant() -or
        ((Get-FileHash -LiteralPath $atomicPublication.HashRecordPath -Algorithm SHA256).Hash).ToUpperInvariant() -cne
        ((Get-FileHash -LiteralPath $hashOne -Algorithm SHA256).Hash).ToUpperInvariant()) {
        throw 'Atomic publication output hashes did not match the staged source bytes.'
    }
    Assert-PackageManifestMatchesRoot -Profile $profile -PackageRoot $atomicPublication.PackageRoot | Out-Null

    $manifestOnePath = Join-Path $packageOne 'package-manifest.json'
    $manifestOriginalText = [IO.File]::ReadAllText($manifestOnePath)
    $duplicateJsonCases = @(
        @{ Name = 'root exact duplicate'; Text = '{"name":1,"name":2}' },
        @{ Name = 'root case-variant duplicate'; Text = '{"name":1,"Name":2}' },
        @{ Name = 'nested exact duplicate'; Text = '{"outer":{"name":1,"name":2}}' },
        @{ Name = 'nested case-variant file-entry duplicate'; Text = '{"files":[{"path":"a","Path":"b"}]}' })
    foreach ($duplicateJsonCase in $duplicateJsonCases) {
        Assert-ExpectedFailureContaining -Description $duplicateJsonCase.Name -RequiredFragments @(
            'Duplicate JSON object property',
            'case-insensitive') -Action {
            ConvertFrom-StrictPackageJson -Json $duplicateJsonCase.Text -Description $duplicateJsonCase.Name | Out-Null
        } | Out-Null
    }

    $duplicateProfileText = [IO.File]::ReadAllText((Get-FullPath -Path $ProfilePath))
    $duplicateProfileText = $duplicateProfileText.Replace(
        '"productId": "HerdrOps",',
        [string]::Concat('"productId": "HerdrOps",', [char]10, '  "ProductId": "HerdrOps",'))
    $duplicateProfilePath = Join-Path $testRoot 'duplicate-profile.json'
    Write-DeterministicTextFile -Path $duplicateProfilePath -Text $duplicateProfileText
    Assert-ExpectedFailureContaining -Description 'profile raw duplicate property rejection' -RequiredFragments @(
        'Duplicate JSON object property',
        'case-insensitive') -Action {
        Read-PackageProfile -Path $duplicateProfilePath | Out-Null
    } | Out-Null

    $duplicateRootManifestText = $manifestOriginalText.Replace(
        '"productId": "HerdrOps",',
        [string]::Concat('"productId": "HerdrOps",', [char]10, '  "ProductId": "HerdrOps",'))
    Write-DeterministicTextFile -Path $manifestOnePath -Text $duplicateRootManifestText
    Assert-ExpectedFailureContaining -Description 'manifest raw root duplicate property rejection' -RequiredFragments @(
        'Duplicate JSON object property',
        'case-insensitive') -Action {
        Assert-PackageManifestMatchesRoot -Profile $profile -PackageRoot $packageOne | Out-Null
    } | Out-Null
    [IO.File]::WriteAllText($manifestOnePath, $manifestOriginalText, (New-Object System.Text.UTF8Encoding($false)))

    $pathMatch = [Text.RegularExpressions.Regex]::Match($manifestOriginalText, '"path": "([^"]+)"')
    if (-not $pathMatch.Success) {
        throw 'Could not locate a manifest file entry for the nested duplicate probe.'
    }
    $pathValue = $pathMatch.Groups[1].Value
    $nestedDuplicateManifestText = $manifestOriginalText.Replace(
        ('      "path": "' + $pathValue + '",'),
        [string]::Concat(
            '      "path": "', $pathValue, '",', [char]10,
            '      "Path": "', $pathValue, '",'))
    Write-DeterministicTextFile -Path $manifestOnePath -Text $nestedDuplicateManifestText
    Assert-ExpectedFailureContaining -Description 'manifest raw nested file-entry duplicate property rejection' -RequiredFragments @(
        'Duplicate JSON object property',
        'case-insensitive') -Action {
        Assert-PackageManifestMatchesRoot -Profile $profile -PackageRoot $packageOne | Out-Null
    } | Out-Null
    [IO.File]::WriteAllText($manifestOnePath, $manifestOriginalText, (New-Object System.Text.UTF8Encoding($false)))

    $metadataTamperCases = @(
        @{ Name = 'schemaVersion'; Value = 999 },
        @{ Name = 'issue'; Value = 999 },
        @{ Name = 'productId'; Value = 'TamperedProduct' },
        @{ Name = 'packageVersion'; Value = '0.7.99' },
        @{ Name = 'targetFramework'; Value = 'net9.0-windows' },
        @{ Name = 'runtimeIdentifier'; Value = 'win-arm64' },
        @{ Name = 'deploymentModel'; Value = 'machine-wide' },
        @{ Name = 'userDataPolicy'; Value = 'delete-on-uninstall' },
        @{ Name = 'contentHashAlgorithm'; Value = 'MD5' },
        @{ Name = 'fileCount'; Value = 999 },
        @{ Name = 'totalBytes'; Value = 999999 },
        @{ Name = 'contentSha256'; Value = ('0' * 64) -join '' },
        @{ Name = 'evidenceClass'; Value = 'Runtime' })
    foreach ($tamperCase in $metadataTamperCases) {
        $tamperedManifest = ConvertFrom-StrictPackageJson -Json $manifestOriginalText -Description 'tamper fixture manifest'
        $tamperedManifest.($tamperCase.Name) = $tamperCase.Value
        Write-DeterministicTextFile -Path $manifestOnePath -Text ($tamperedManifest | ConvertTo-Json -Depth 20)
        Assert-ExpectedFailure -Description ("manifest metadata tamper: " + $tamperCase.Name) -Action {
            Assert-PackageManifestMatchesRoot -Profile $profile -PackageRoot $packageOne | Out-Null
        }
        [IO.File]::WriteAllText($manifestOnePath, $manifestOriginalText, (New-Object System.Text.UTF8Encoding($false)))
    }
    Assert-PackageManifestMatchesRoot -Profile $profile -PackageRoot $packageOne | Out-Null

    foreach ($numericName in @('schemaVersion', 'issue', 'fileCount', 'totalBytes')) {
        $numericStringManifest = ConvertFrom-StrictPackageJson -Json $manifestOriginalText -Description 'numeric fixture manifest'
        $numericStringManifest.($numericName) = [string]$numericStringManifest.($numericName)
        Write-DeterministicTextFile -Path $manifestOnePath -Text ($numericStringManifest | ConvertTo-Json -Depth 20)
        Assert-ExpectedFailure -Description ("manifest numeric string rejected: " + $numericName) -Action {
            Assert-PackageManifestMatchesRoot -Profile $profile -PackageRoot $packageOne | Out-Null
        }
        [IO.File]::WriteAllText($manifestOnePath, $manifestOriginalText, (New-Object System.Text.UTF8Encoding($false)))
    }

    $nestedNumericStringManifest = ConvertFrom-StrictPackageJson -Json $manifestOriginalText -Description 'nested numeric fixture manifest'
    $nestedNumericStringManifest.files[0].length = [string]$nestedNumericStringManifest.files[0].length
    Write-DeterministicTextFile -Path $manifestOnePath -Text ($nestedNumericStringManifest | ConvertTo-Json -Depth 20)
    Assert-ExpectedFailure -Description 'manifest file length numeric string rejected' -Action {
        Assert-PackageManifestMatchesRoot -Profile $profile -PackageRoot $packageOne | Out-Null
    }
    [IO.File]::WriteAllText($manifestOnePath, $manifestOriginalText, (New-Object System.Text.UTF8Encoding($false)))

    $unknownPropertyManifest = ConvertFrom-StrictPackageJson -Json $manifestOriginalText -Description 'unknown-property fixture manifest'
    Add-Member -InputObject $unknownPropertyManifest -MemberType NoteProperty -Name unknownProperty -Value 'must reject'
    Write-DeterministicTextFile -Path $manifestOnePath -Text ($unknownPropertyManifest | ConvertTo-Json -Depth 20)
    Assert-ExpectedFailure -Description 'manifest unknown property rejected' -Action {
        Assert-PackageManifestMatchesRoot -Profile $profile -PackageRoot $packageOne | Out-Null
    }
    [IO.File]::WriteAllText($manifestOnePath, $manifestOriginalText, (New-Object System.Text.UTF8Encoding($false)))

    $reorderedFilesManifest = ConvertFrom-StrictPackageJson -Json $manifestOriginalText -Description 'reordered-files fixture manifest'
    $reorderedFiles = @($reorderedFilesManifest.files)
    [array]::Reverse($reorderedFiles)
    $reorderedFilesManifest.files = $reorderedFiles
    Write-DeterministicTextFile -Path $manifestOnePath -Text ($reorderedFilesManifest | ConvertTo-Json -Depth 20)
    Assert-ExpectedFailure -Description 'manifest reordered files rejected' -Action {
        Assert-PackageManifestMatchesRoot -Profile $profile -PackageRoot $packageOne | Out-Null
    }
    [IO.File]::WriteAllText($manifestOnePath, $manifestOriginalText, (New-Object System.Text.UTF8Encoding($false)))
    Assert-PackageManifestMatchesRoot -Profile $profile -PackageRoot $packageOne | Out-Null

    $customVersionProfile = ConvertFrom-StrictPackageJson -Json ($profile | ConvertTo-Json -Depth 20) -Description 'custom version profile'
    $customVersionProfile.packageVersion = '0.7.1'
    $customVersionProfile.syntheticUpgradeVersion = '0.7.2'
    $customVersionProfilePath = Join-Path $testRoot 'custom-version-profile.json'
    Write-DeterministicTextFile -Path $customVersionProfilePath -Text ($customVersionProfile | ConvertTo-Json -Depth 20)
    $customVersionOutput = Join-Path $testRoot 'custom-version-output'
    Assert-ExpectedFailure -Description 'custom profile version fence before publish effects' -Action {
        & (Join-Path $PSScriptRoot 'Publish-HerdrOpsPackage.ps1') `
            -OutputRoot $customVersionOutput `
            -ProfilePath $customVersionProfilePath `
            -TestInjectPrimaryFailure | Out-Null
    }
    if (Test-Path -LiteralPath $customVersionOutput) {
        throw 'A non-v0.7.0 custom profile created a publish output path.'
    }

    $customProjectProfile = ConvertFrom-StrictPackageJson -Json ($profile | ConvertTo-Json -Depth 20) -Description 'custom project profile'
    $customProjectProfile.sourceProject = '..\outside\HerdrOps.App.csproj'
    $customProjectProfilePath = Join-Path $testRoot 'custom-project-profile.json'
    Write-DeterministicTextFile -Path $customProjectProfilePath -Text ($customProjectProfile | ConvertTo-Json -Depth 20)
    $customProjectOutput = Join-Path $testRoot 'custom-project-output'
    Assert-ExpectedFailure -Description 'custom profile project fence before publish effects' -Action {
        & (Join-Path $PSScriptRoot 'Publish-HerdrOpsPackage.ps1') `
            -OutputRoot $customProjectOutput `
            -ProfilePath $customProjectProfilePath `
            -TestInjectPrimaryFailure | Out-Null
    }
    if (Test-Path -LiteralPath $customProjectOutput) {
        throw 'An outside sourceProject custom profile created a publish output path.'
    }

    $projectPath = Join-Path $repositoryRoot 'src\HerdrOps.App\HerdrOps.App.csproj'
    $projectOriginalBytes = [IO.File]::ReadAllBytes($projectPath)
    $dotnetProbeCommand = Join-Path $testRoot 'dotnet-probe.cmd'
    $dotnetProbeMarker = Join-Path $testRoot 'dotnet-reached.marker'
    Write-DeterministicTextFile -Path $dotnetProbeCommand -Text ('@echo DOTNET_REACHED>"' + $dotnetProbeMarker + '"')
    $maliciousProjectText = [Text.Encoding]::UTF8.GetString($projectOriginalBytes)
    $maliciousProjectText = $maliciousProjectText.Replace(
        '<PropertyGroup>',
        '<PropertyGroup><AssemblyName>Malicious.Product</AssemblyName>')
    try {
        [IO.File]::WriteAllText($projectPath, $maliciousProjectText, (New-Object System.Text.UTF8Encoding($false)))
        Assert-ExpectedFailureContaining -Description 'malicious AssemblyName rejected before dotnet' -RequiredFragments @(
            'AssemblyName',
            'exactly HerdrOps.App') -Action {
            & (Join-Path $PSScriptRoot 'Publish-HerdrOpsPackage.ps1') -OutputRoot (Join-Path $testRoot 'malicious-assembly-output') -ProfilePath $ProfilePath -TestDotnetCommandPath $dotnetProbeCommand | Out-Null
        } | Out-Null
        if (Test-Path -LiteralPath $dotnetProbeMarker) {
            throw 'The malicious AssemblyName probe reached the dotnet command.'
        }
    } finally {
        [IO.File]::WriteAllBytes($projectPath, $projectOriginalBytes)
        if (Test-Path -LiteralPath $dotnetProbeMarker) {
            Remove-Item -LiteralPath $dotnetProbeMarker -Force
        }
    }

    $projectDirectory = Split-Path -Path $projectPath -Parent
    $reparseTarget = Join-Path (Split-Path -Path $projectDirectory -Parent) ('HerdrOps.App.reparse-target-' + [Guid]::NewGuid().ToString('N'))
    try {
        Move-Item -LiteralPath $projectDirectory -Destination $reparseTarget
        New-Item -ItemType Junction -Path $projectDirectory -Target $reparseTarget | Out-Null
        Assert-ExpectedFailureContaining -Description 'reparse source-project component rejected before dotnet' -RequiredFragments @(
            'Reparse points are not allowed') -Action {
            & (Join-Path $PSScriptRoot 'Publish-HerdrOpsPackage.ps1') -OutputRoot (Join-Path $testRoot 'reparse-project-output') -ProfilePath $ProfilePath -TestDotnetCommandPath $dotnetProbeCommand | Out-Null
        } | Out-Null
        if (Test-Path -LiteralPath $dotnetProbeMarker) {
            throw 'The reparse source-project probe reached the dotnet command.'
        }
    } finally {
        if (Test-Path -LiteralPath $projectDirectory) {
            $projectDirectoryItem = Get-Item -LiteralPath $projectDirectory -Force
            if (($projectDirectoryItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                [IO.Directory]::Delete($projectDirectory)
            }
        }
        if (Test-Path -LiteralPath $reparseTarget -PathType Container) {
            Move-Item -LiteralPath $reparseTarget -Destination $projectDirectory
        }
        if (Test-Path -LiteralPath $dotnetProbeMarker) {
            Remove-Item -LiteralPath $dotnetProbeMarker -Force
        }
    }

    $syntheticOrderingError = Assert-ExpectedFailureContaining -Description 'synthetic cleanup error ordering' -RequiredFragments @(
        'Injected synthetic lifecycle primary operation failure.',
        'Cleanup also failed: Injected synthetic lifecycle cleanup failure.') -Action {
        & (Join-Path $PSScriptRoot 'Invoke-SyntheticPackagingLifecycle.ps1') `
            -ProfilePath $ProfilePath `
            -TestInjectPrimaryFailure `
            -TestInjectCleanupFailure | Out-Null
    }
    $publishOutputProbe = Join-Path $testRoot 'publish-output-probe'
    $publishOrderingError = Assert-ExpectedFailureContaining -Description 'publish cleanup error ordering' -RequiredFragments @(
        'Injected packaging primary operation failure.',
        'Cleanup also failed: Injected packaging cleanup failure.') -Action {
        & (Join-Path $PSScriptRoot 'Publish-HerdrOpsPackage.ps1') `
            -OutputRoot $publishOutputProbe `
            -ProfilePath $ProfilePath `
            -TestInjectPrimaryFailure `
            -TestInjectCleanupFailure | Out-Null
    }
    if (Test-Path -LiteralPath $publishOutputProbe) {
        throw 'Injected publish failure created an output destination.'
    }

    Write-DeterministicTextFile -Path (Join-Path $packageOne 'tampered.txt') -Text 'tamper'
    Assert-ExpectedFailure -Description 'tampered package manifest guard' -Action {
        Assert-PackageManifestMatchesRoot -Profile $profile -PackageRoot $packageOne | Out-Null
    }
    Assert-ExpectedFailure -Description 'profile version mismatch guard' -Action {
        Resolve-RequestedPackageVersion -Profile $profile -RequestedVersion '0.7.1' | Out-Null
    }
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-PackagingTempDirectory -Path $testRoot
    }
}

$lifecycle = @(& (Join-Path $PSScriptRoot 'Invoke-SyntheticPackagingLifecycle.ps1') -ProfilePath $ProfilePath)
if ($lifecycle.Count -ne 1 -or [string]$lifecycle[0].EvidenceClass -cne 'Synthetic') {
    throw 'Synthetic packaging lifecycle harness did not return one successful Synthetic report.'
}
foreach ($boundary in @('CleanMachine', 'Runtime', 'Human', 'Release')) {
    if ([string]$lifecycle[0].$boundary -cne 'NOT OBSERVED') {
        throw "Synthetic lifecycle boundary '$boundary' was not explicitly NOT OBSERVED."
    }
}

[pscustomobject][ordered]@{
    EvidenceClass = 'Static/Synthetic'
    Issue = [int]$profile.issue
    PowerShellEdition = [string]$PSVersionTable.PSEdition
    PowerShellVersion = [string]$PSVersionTable.PSVersion
    Profile = 'PASS'
    ProjectIdentity = 'PASS'
    ProtectedPathGuards = 'PASS'
    OutsidePathNoSideEffects = 'PASS'
    DeterministicManifestBytes = 'PASS'
    DeterministicArchiveBytes = 'PASS'
    ManifestMetadataFailClosed = 'PASS'
    DuplicateJsonPropertiesFailClosed = 'PASS'
    SourceIdentityAndReparsePreflight = 'PASS'
    OverwriteRollback = 'PASS'
    ArchiveHashCoherence = 'PASS'
    AtomicPairCommitMarker = 'PASS'
    TamperAndVersionFailClosed = 'PASS'
    CleanupErrorOrdering = 'PASS'
    AtomicPublicationRetry = 'PASS'
    SyntheticLifecycle = 'PASS'
    CleanMachine = 'NOT OBSERVED'
    Runtime = 'NOT OBSERVED'
    Human = 'NOT OBSERVED'
    Release = 'NOT OBSERVED'
}
