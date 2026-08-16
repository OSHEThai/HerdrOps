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

$profile = Read-PackageProfile -Path $ProfilePath
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
    Assert-ExpectedFailure -Description 'archive destination outside authorized repo/temp policy has no side effects' -Action {
        New-DeterministicPackageArchive -PackageRoot $packageOne -ArchivePath $outsideArchivePath | Out-Null
    }
    if (Test-Path -LiteralPath $outsideProbeRoot) {
        throw "Unsafe archive destination created an outside path: $outsideProbeRoot"
    }

    $hashOne = Join-Path $testRoot 'one-hashes.txt'
    Write-PackageHashRecord -Profile $profile -PackageRoot $packageOne -ArchivePath $archiveOne -Path $hashOne | Out-Null
    Assert-ExpectedFailure -Description 'hash record destination outside authorized repo/temp policy has no side effects' -Action {
        Write-PackageHashRecord -Profile $profile -PackageRoot $packageOne -ArchivePath $archiveOne -Path $outsideHashPath | Out-Null
    }
    if (Test-Path -LiteralPath $outsideProbeRoot) {
        throw "Unsafe hash-record destination created an outside path: $outsideProbeRoot"
    }

    $atomicOutputRoot = Join-Path $testRoot 'atomic-output'
    Assert-ExpectedFailureContaining -Description 'atomic publication fault injection leaves no partial output' -RequiredFragments @('Injected atomic publication failure after archive copy.') -Action {
        Publish-PackageArtifactsAtomically `
            -PackageRoot $packageOne `
            -ArchivePath $archiveOne `
            -HashRecordPath $hashOne `
            -OutputRoot $atomicOutputRoot `
            -FaultInjectionStage 'AfterArchive' | Out-Null
    } | Out-Null
    if (Test-Path -LiteralPath $atomicOutputRoot) {
        if (@(Get-ChildItem -LiteralPath $atomicOutputRoot -Force).Count -ne 0) {
            throw 'Atomic publication fault injection left partial output in the destination root.'
        }
        Remove-Item -LiteralPath $atomicOutputRoot -Force
    }
    $stagingLeftovers = @(Get-ChildItem -LiteralPath $testRoot -Force |
        Where-Object { $_.Name -like '.atomic-output.staging-*' })
    if ($stagingLeftovers.Count -ne 0) {
        throw 'Atomic publication fault injection left a staging directory behind.'
    }

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
    Assert-PackageManifestMatchesRoot -Profile $profile -PackageRoot $atomicPublication.PackageRoot | Out-Null

    $manifestOnePath = Join-Path $packageOne 'package-manifest.json'
    $manifestOriginalText = [IO.File]::ReadAllText($manifestOnePath)
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
        $tamperedManifest = $manifestOriginalText | ConvertFrom-Json
        $tamperedManifest.($tamperCase.Name) = $tamperCase.Value
        Write-DeterministicTextFile -Path $manifestOnePath -Text ($tamperedManifest | ConvertTo-Json -Depth 20)
        Assert-ExpectedFailure -Description ("manifest metadata tamper: " + $tamperCase.Name) -Action {
            Assert-PackageManifestMatchesRoot -Profile $profile -PackageRoot $packageOne | Out-Null
        }
        [IO.File]::WriteAllText($manifestOnePath, $manifestOriginalText, (New-Object System.Text.UTF8Encoding($false)))
    }
    Assert-PackageManifestMatchesRoot -Profile $profile -PackageRoot $packageOne | Out-Null

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
    Profile = 'PASS'
    ProjectIdentity = 'PASS'
    ProtectedPathGuards = 'PASS'
    OutsidePathNoSideEffects = 'PASS'
    DeterministicManifestBytes = 'PASS'
    DeterministicArchiveBytes = 'PASS'
    ManifestMetadataFailClosed = 'PASS'
    TamperAndVersionFailClosed = 'PASS'
    CleanupErrorOrdering = 'PASS'
    AtomicPublicationRetry = 'PASS'
    SyntheticLifecycle = 'PASS'
    CleanMachine = 'NOT OBSERVED'
    Runtime = 'NOT OBSERVED'
    Human = 'NOT OBSERVED'
    Release = 'NOT OBSERVED'
}
