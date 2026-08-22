#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$OutputRoot,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-f]{40}$')]
    [string]$ExpectedSourceCommit,

    [string]$ProfilePath,

    [string]$TestDotnetCommandPath,

    [string]$GeneratedAtUtc,

    [switch]$TestInjectPrimaryFailure,

    [switch]$TestInjectCleanupFailure
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'V10Release.Common.ps1')

if ([string]::IsNullOrWhiteSpace($ProfilePath)) {
    $ProfilePath = Join-Path $PSScriptRoot 'v1.0-package-profile.json'
}
$profile = Read-V10ReleaseProfile -Path $ProfilePath
$repositoryRoot = Get-V10RepositoryRoot
$initialGit = Get-V10GitIdentity -RepositoryRoot $repositoryRoot -ExpectedCommit $ExpectedSourceCommit -RequireClean

$safeOutputRoot = Assert-SafeDestination -Path $OutputRoot -AllowRepositoryChild -AllowTempChild
$requiredCandidateRoot = Normalize-ComparablePath -Path (Join-Path $repositoryRoot 'artifacts\release-candidate')
if (-not (Test-PathWithin -ChildPath $safeOutputRoot -RootPath $requiredCandidateRoot) -or
    $safeOutputRoot.Equals($requiredCandidateRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "v1 release-candidate output must be a versioned child below '$requiredCandidateRoot'."
}
if (Test-Path -LiteralPath $safeOutputRoot) {
    $existing = Get-Item -LiteralPath $safeOutputRoot -Force
    if (-not $existing.PSIsContainer -or ($existing.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Release-candidate output must be a non-reparse directory: $safeOutputRoot"
    }
    if (@(Get-ChildItem -LiteralPath $safeOutputRoot -Force).Count -ne 0) {
        throw "Release-candidate output must be missing or empty: $safeOutputRoot"
    }
}

$expectedLockFiles = @(
    'src/HerdrOps.App/packages.lock.json',
    'src/HerdrOps.Cli/packages.lock.json',
    'src/HerdrOps.Contracts/packages.lock.json',
    'src/HerdrOps.Core/packages.lock.json',
    'src/HerdrOps.Domain/packages.lock.json',
    'src/HerdrOps.Infrastructure/packages.lock.json')
$lockHashes = [ordered]@{}
foreach ($relativeLock in $expectedLockFiles) {
    $lockPath = Resolve-V10RepositoryFile -RelativePath $relativeLock -RepositoryRoot $repositoryRoot -Description 'release package lock file'
    $lockHashes[$lockPath] = ((Get-FileHash -LiteralPath $lockPath -Algorithm SHA256).Hash).ToUpperInvariant()
}

function Assert-ReleaseLocksUnchanged {
    foreach ($lockPath in $lockHashes.Keys) {
        if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) {
            throw "Release publish removed a package lock file: $lockPath"
        }
        $after = ((Get-FileHash -LiteralPath $lockPath -Algorithm SHA256).Hash).ToUpperInvariant()
        if ($after -cne [string]$lockHashes[$lockPath]) {
            throw "Release publish changed a package lock file: $lockPath"
        }
    }
}

$dotnetCommand = 'dotnet'
if (-not [string]::IsNullOrWhiteSpace($TestDotnetCommandPath)) {
    if ([IO.Path]::IsPathRooted($TestDotnetCommandPath)) {
        $dotnetCommand = Get-FullPath -Path $TestDotnetCommandPath
    } else {
        $resolvedCommand = Get-Command -Name $TestDotnetCommandPath -CommandType Application -ErrorAction Stop | Select-Object -First 1
        $dotnetCommand = [string]$resolvedCommand.Source
    }
    if (-not (Test-Path -LiteralPath $dotnetCommand -PathType Leaf)) {
        throw "Release dotnet command was not found: $dotnetCommand"
    }
}

function Expand-CommittedReleaseSource {
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$DestinationRoot
    )

    if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) {
        throw "Committed source archive was not found: $ArchivePath"
    }
    if (Test-Path -LiteralPath $DestinationRoot) {
        throw "Committed source destination must be absent: $DestinationRoot"
    }
    New-Item -ItemType Directory -Path $DestinationRoot | Out-Null
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $root = Normalize-ComparablePath -Path $DestinationRoot
    $seen = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
    $stream = [IO.File]::Open($ArchivePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $zip = $null
    try {
        $zip = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Read, $false)
        foreach ($entry in @($zip.Entries)) {
            $name = [string]$entry.FullName
            if ([string]::IsNullOrWhiteSpace($name) -or $name.IndexOf([char]0) -ge 0 -or
                $name.StartsWith('/', [StringComparison]::Ordinal) -or
                $name.StartsWith('\', [StringComparison]::Ordinal) -or
                $name -match '^[A-Za-z]:' -or $name -match '(^|/)\.\.(/|$)' -or
                $name -match '(^|/)\.(/|$)' -or $name.Contains('\')) {
                throw "Committed source archive contains an unsafe entry path: $name"
            }
            $isDirectory = $name.EndsWith('/', [StringComparison]::Ordinal)
            $trimmed = $name.TrimEnd('/')
            if ([string]::IsNullOrWhiteSpace($trimmed)) {
                throw 'Committed source archive contains an empty root entry.'
            }
            Assert-V10SafeRelativePathText -Path $trimmed -Description 'committed source archive entry'
            if ($seen.ContainsKey($trimmed)) {
                throw "Committed source archive contains a duplicate Windows path: $trimmed"
            }
            $seen.Add($trimmed, $trimmed)

            $unixMode = ($entry.ExternalAttributes -shr 16) -band 0xF000
            if ($unixMode -eq 0xA000) {
                throw "Committed source archive contains a symbolic link: $trimmed"
            }
            $destination = [IO.Path]::GetFullPath((Join-Path $root $trimmed.Replace('/', '\')))
            if (-not (Test-PathWithin -ChildPath $destination -RootPath $root) -or
                $destination.Equals($root, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Committed source archive entry escaped the destination: $trimmed"
            }
            if ($isDirectory) {
                if (-not (Test-Path -LiteralPath $destination -PathType Container)) {
                    New-Item -ItemType Directory -Path $destination -Force | Out-Null
                }
                continue
            }
            $parent = Split-Path -Path $destination -Parent
            if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
            }
            $input = $entry.Open()
            $output = $null
            try {
                $output = New-Object IO.FileStream($destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                $input.CopyTo($output)
                $output.Flush($true)
            } finally {
                if ($null -ne $output) { $output.Dispose() }
                $input.Dispose()
            }
        }
    } finally {
        if ($null -ne $zip) { $zip.Dispose() }
        $stream.Dispose()
    }
    Assert-NoReparsePath -Path $root
    Assert-NoReparseDescendants -Path $root
    return $root
}

$workRoot = New-PackagingTempDirectory -Prefix 'HerdrOps-V10-Candidate-'
$operationOutput = Invoke-PackagingOperationWithCleanup -Operation {
    if ($TestInjectPrimaryFailure) {
        throw 'Injected v1 release-candidate primary failure.'
    }

    $sourceArchivePath = Join-Path $workRoot 'committed-source.zip'
    $archiveOutput = @(& git -C $repositoryRoot archive --format=zip --output=$sourceArchivePath $ExpectedSourceCommit 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $sourceArchivePath -PathType Leaf)) {
        throw "Could not export the exact committed source tree: $($archiveOutput -join '; ')"
    }
    $buildRepositoryRoot = Expand-CommittedReleaseSource -ArchivePath $sourceArchivePath -DestinationRoot (Join-Path $workRoot 'source')
    $exportedProfilePath = Resolve-V10RepositoryFile -RelativePath $script:V10ReleaseProfileRelativePath -RepositoryRoot $buildRepositoryRoot -Description 'exported v1 release profile'
    if (((Get-FileHash -LiteralPath $exportedProfilePath -Algorithm SHA256).Hash) -cne
        ((Get-FileHash -LiteralPath $ProfilePath -Algorithm SHA256).Hash)) {
        throw 'Exported release profile does not match the clean source checkout.'
    }
    $exportedLockHashes = [ordered]@{}
    foreach ($relativeLock in $expectedLockFiles) {
        $exportedLockPath = Resolve-V10RepositoryFile -RelativePath $relativeLock -RepositoryRoot $buildRepositoryRoot -Description 'exported release package lock file'
        $exportedLockHashes[$exportedLockPath] = ((Get-FileHash -LiteralPath $exportedLockPath -Algorithm SHA256).Hash).ToUpperInvariant()
    }

    $componentPreflight = New-Object System.Collections.ArrayList
    foreach ($component in @($profile.components)) {
        [void]$componentPreflight.Add((Assert-V10ProjectMatchesComponent `
                -Profile $profile `
                -Component $component `
                -RepositoryRoot $buildRepositoryRoot `
                -TestDotnetCommandPath $TestDotnetCommandPath))
    }

    $publishedComponents = New-Object System.Collections.ArrayList
    $publishFailure = $null
    try {
        foreach ($component in @($profile.components)) {
            $restoreProjectPath = Resolve-V10RepositoryFile `
                -RelativePath ([string]$component.project) `
                -RepositoryRoot $buildRepositoryRoot `
                -Description "release component $($component.name) restore project"
            $restoreArguments = @(
                'restore',
                $restoreProjectPath,
                '--runtime', 'win-x64',
                '--locked-mode',
                '--nologo',
                '-p:SelfContained=true')
            $restoreOutput = @(& $dotnetCommand @restoreArguments 2>&1)
            $restoreExitCode = $LASTEXITCODE
            $restoreOutput | ForEach-Object { Write-Verbose ([string]$_) }
            if ($restoreExitCode -ne 0) {
                $details = ($restoreOutput | Select-Object -Last 30 | ForEach-Object { [string]$_ }) -join "`n"
                throw "dotnet locked restore failed for $($component.name) with exit code $restoreExitCode.`n$details"
            }
        }

        foreach ($component in @($profile.components)) {
            $publishRoot = Join-Path $workRoot ('published\' + [string]$component.name)
            New-Item -ItemType Directory -Path $publishRoot -Force | Out-Null
            $projectPath = Resolve-V10RepositoryFile `
                -RelativePath ([string]$component.project) `
                -RepositoryRoot $buildRepositoryRoot `
                -Description "release component $($component.name) project"
            $packageVersion = [string]$profile.packageVersion
            $arguments = @(
                'publish',
                $projectPath,
                '--configuration', ([string]$profile.configuration),
                '--runtime', ([string]$profile.runtimeIdentifier),
                '--self-contained', 'true',
                '--output', $publishRoot,
                '--nologo',
                '--no-restore',
                ('-p:VersionPrefix=' + $packageVersion),
                '-p:VersionSuffix=',
                ('-p:Version=' + $packageVersion),
                ('-p:AssemblyVersion=' + $packageVersion + '.0'),
                ('-p:FileVersion=' + $packageVersion + '.0'),
                ('-p:InformationalVersion=' + $packageVersion),
                '-p:ContinuousIntegrationBuild=true',
                '-p:Deterministic=true',
                '-p:DebugType=None')
            $publishOutput = @(& $dotnetCommand @arguments 2>&1)
            $exitCode = $LASTEXITCODE
            $publishOutput | ForEach-Object { Write-Verbose ([string]$_) }
            if ($exitCode -ne 0) {
                $details = ($publishOutput | Select-Object -Last 30 | ForEach-Object { [string]$_ }) -join "`n"
                throw "dotnet publish failed for $($component.name) with exit code $exitCode.`n$details"
            }
            $published = Assert-V10PublishedComponent -Profile $profile -Component $component -PublishRoot $publishRoot
            [void]$publishedComponents.Add($published)
        }
    } catch {
        $publishFailure = $_
    }
    $lockFailure = $null
    try {
        Assert-ReleaseLocksUnchanged
        foreach ($exportedLockPath in $exportedLockHashes.Keys) {
            if (-not (Test-Path -LiteralPath $exportedLockPath -PathType Leaf) -or
                ((Get-FileHash -LiteralPath $exportedLockPath -Algorithm SHA256).Hash).ToUpperInvariant() -cne [string]$exportedLockHashes[$exportedLockPath]) {
                throw "Release publish changed an exported package lock file: $exportedLockPath"
            }
        }
    } catch {
        $lockFailure = $_
    }
    if ($null -ne $publishFailure -or $null -ne $lockFailure) {
        Throw-PackagingFailure -PrimaryError $publishFailure -CleanupError $lockFailure
    }

    $packageRoot = Join-Path $workRoot 'package'
    New-Item -ItemType Directory -Path $packageRoot -Force | Out-Null
    $runtimeOverlayPaths = Get-V10CanonicalRuntimeOverlayPaths `
        -Profile $profile `
        -Components @($publishedComponents.ToArray())
    $merge = Merge-V10PublishedComponents `
        -Components @($publishedComponents.ToArray()) `
        -DestinationRoot $packageRoot `
        -CanonicalComponentName ([string]$profile.canonicalRuntimeComponent) `
        -AllowedCanonicalConflictRelativePath $runtimeOverlayPaths

    $manifest = New-PackageManifestObject -Profile $profile -PackageRoot $packageRoot
    Write-PackageManifest -Manifest $manifest -PackageRoot $packageRoot | Out-Null
    $archivePath = Join-Path $workRoot ("HerdrOps-{0}-{1}.zip" -f $profile.packageVersion, $profile.runtimeIdentifier)
    $hashRecordPath = Join-Path $workRoot 'package-hashes.txt'
    $archive = New-DeterministicPackageArchive -PackageRoot $packageRoot -ArchivePath $archivePath
    Write-PackageHashRecord -Profile $profile -PackageRoot $packageRoot -ArchivePath $archive -Path $hashRecordPath | Out-Null
    $generation = Publish-PackageArtifactsAtomically `
        -Profile $profile `
        -PackageRoot $packageRoot `
        -ArchivePath $archive `
        -HashRecordPath $hashRecordPath `
        -OutputRoot $safeOutputRoot

    $finalGit = Get-V10GitIdentity -RepositoryRoot $repositoryRoot -ExpectedCommit $ExpectedSourceCommit -RequireClean
    if ($initialGit.Commit -cne $finalGit.Commit) {
        throw 'Source commit changed while the v1 release candidate was being built.'
    }
    Assert-ReleaseLocksUnchanged

    $candidateArguments = @{
        Profile = $profile
        RepositoryRoot = $repositoryRoot
        ProfilePath = $ProfilePath
        SourceCommit = $ExpectedSourceCommit
        Generation = $generation
    }
    if (-not [string]::IsNullOrWhiteSpace($GeneratedAtUtc)) {
        $candidateArguments.GeneratedAtUtc = $GeneratedAtUtc
    }
    $candidateRecord = New-V10CandidateRecord @candidateArguments
    $candidateRecordPath = Join-Path $safeOutputRoot 'release-candidate.json'
    Write-V10NewJsonFile -Path $candidateRecordPath -Value $candidateRecord | Out-Null
    $candidate = Assert-V10CandidateRecord `
        -CandidateRecordPath $candidateRecordPath `
        -RepositoryRoot $repositoryRoot `
        -ExpectedSourceCommit $ExpectedSourceCommit `
        -ProfilePath $ProfilePath

    [pscustomobject][ordered]@{
        EvidenceClass = 'Static'
        Issue = 45
        ReleaseVersion = 'v1.0.0'
        SourceCommit = $ExpectedSourceCommit
        WorkingTree = 'CLEAN'
        GenerationRoot = $generation.GenerationRoot
        CandidateRecordPath = $candidate.RecordPath
        CandidateRecordSha256 = $candidate.RecordSha256
        ArchivePath = $candidate.ArchivePath
        ArchiveBytes = $candidate.ArchiveBytes
        ArchiveSha256 = $candidate.ArchiveSha256
        HashRecordPath = $candidate.HashRecordPath
        ComponentCount = @($publishedComponents.ToArray()).Count
        BundleFileCount = $merge.FileCount
        CanonicalRuntimeOverlayCount = @($merge.CanonicalConflictPaths).Count
        Static = 'PASS'
        Synthetic = 'NOT OBSERVED'
        Contract = 'NOT OBSERVED'
        CleanMachine = 'NOT OBSERVED'
        Runtime = 'NOT OBSERVED'
        IndependentReview = 'NOT OBSERVED'
        Human = 'NOT OBSERVED'
        Release = 'NOT OBSERVED'
    }
} -Cleanup {
    if ($TestInjectCleanupFailure) {
        if (Test-Path -LiteralPath $workRoot) {
            Remove-PackagingTempDirectory -Path $workRoot
        }
        throw 'Injected v1 release-candidate cleanup failure.'
    }
    if (Test-Path -LiteralPath $workRoot) {
        Remove-PackagingTempDirectory -Path $workRoot
    }
}
$operationOutput
