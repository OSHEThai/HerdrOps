#requires -Version 5.1

Set-StrictMode -Version Latest

$packagingCommonPath = Join-Path $PSScriptRoot '..\packaging\Packaging.Common.ps1'
if (-not (Test-Path -LiteralPath $packagingCommonPath -PathType Leaf)) {
    throw "Packaging common library is missing: $packagingCommonPath"
}
. $packagingCommonPath

$issue44ReportCommonPath = Join-Path $PSScriptRoot '..\acceptance\HerdrOps.InstallAcceptance.Common.ps1'
if (-not (Test-Path -LiteralPath $issue44ReportCommonPath -PathType Leaf)) {
    throw "Issue #44 report schema helper is missing: $issue44ReportCommonPath"
}
. $issue44ReportCommonPath

$issue40PolicyPath = Join-Path $PSScriptRoot '..\lib\V07ReleaseGatePolicy.ps1'
if (-not (Test-Path -LiteralPath $issue40PolicyPath -PathType Leaf)) {
    throw "Issue #40 release-gate policy is missing: $issue40PolicyPath"
}
. $issue40PolicyPath

$script:V10ReleaseProfileRelativePath = 'tools/release/v1.0-package-profile.json'
$script:V10GoNoGoStatement = 'I approve publishing the exact HerdrOps v1.0.0 candidate identified by this authorization.'

function Get-V10RepositoryRoot {
    return (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
}

function Get-V10RequiredProperty {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Description,
        [switch]$AllowNull
    )

    if ($null -eq $Object -or $null -eq $Object.PSObject) {
        throw "$Description must be an object."
    }
    $properties = @($Object.PSObject.Properties | Where-Object { $_.Name -ceq $Name })
    if ($properties.Count -ne 1 -or (-not $AllowNull -and $null -eq $properties[0].Value)) {
        throw "$Description must contain exactly one non-null '$Name' property."
    }
    return $properties[0].Value
}

function Assert-V10ExactProperties {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string[]]$Names,
        [Parameter(Mandatory = $true)][string]$Description
    )

    if ($null -eq $Object -or $null -eq $Object.PSObject -or $Object -is [string] -or $Object -is [array]) {
        throw "$Description must be a JSON object."
    }
    $actual = @($Object.PSObject.Properties | ForEach-Object { [string]$_.Name })
    if ($actual.Count -ne $Names.Count) {
        throw "$Description has an unknown, missing, or duplicate property."
    }
    foreach ($name in $Names) {
        if (@($actual | Where-Object { $_ -ceq $name }).Count -ne 1) {
            throw "$Description has an unknown, missing, wrongly cased, or duplicate property: $name"
        }
    }
}

function Assert-V10Hex {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][ValidateSet(40, 64)][int]$Length,
        [Parameter(Mandatory = $true)][string]$Description,
        [switch]$Uppercase,
        [switch]$Lowercase
    )

    $pattern = if ($Uppercase) { "^[0-9A-F]{$Length}$" } elseif ($Lowercase) { "^[0-9a-f]{$Length}$" } else { "^[0-9a-fA-F]{$Length}$" }
    if ($Value -cnotmatch $pattern) {
        throw "$Description must be an exact $Length-character hexadecimal value."
    }
}

function Assert-V10UtcTimestamp {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$Description
    )

    if ($Value -cnotmatch 'Z$') {
        throw "$Description must be an ISO-8601 UTC timestamp ending in Z."
    }
    try {
        $parsed = [DateTimeOffset]::Parse(
            $Value,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal)
    } catch {
        throw "$Description is not a valid ISO-8601 UTC timestamp: $Value"
    }
    if ($parsed.Offset -ne [TimeSpan]::Zero) {
        throw "$Description must have a zero UTC offset."
    }
}

function Assert-V10Issue44NonZeroSha256 {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$Description
    )

    Assert-V10Hex -Value $Value -Length 64 -Description $Description -Uppercase
    if ($Value -ceq (('0' * 64) -join '')) {
        throw "$Description must not be the all-zero placeholder hash."
    }
}

function Assert-V10Issue44HashList {
    param(
        [Parameter(Mandatory = $true)]$Hashes,
        [Parameter(Mandatory = $true)][string]$Description
    )

    if ($null -eq $Hashes) {
        throw "$Description is missing."
    }
    $values = @($Hashes)
    if ($values.Count -eq 0) {
        throw "$Description must contain at least one installed-file hash."
    }
    $seen = @{}
    foreach ($hash in $values) {
        if ($null -eq $hash -or [string]::IsNullOrWhiteSpace([string]$hash.path)) {
            throw "$Description contains an empty hash record."
        }
        if ([string]$hash.path -match '(^|[\\/])\.\.([\\/]|$)' -or
            [string]$hash.path -match '(^|[\\/])\.([\\/]|$)') {
            throw "$Description contains a traversing path: $($hash.path)"
        }
        Assert-V10Issue44NonZeroSha256 -Value ([string]$hash.sha256) -Description "$Description '$($hash.path)' SHA-256"
        if ([int64]$hash.length -lt 0) {
            throw "$Description '$($hash.path)' has a negative length."
        }
        $key = [string]$hash.path
        if ($seen.ContainsKey($key)) {
            throw "$Description contains a duplicate path: $key"
        }
        $seen[$key] = $true
    }
}

function Assert-V10Issue44HashListsEqual {
    param(
        [Parameter(Mandatory = $true)]$Expected,
        [Parameter(Mandatory = $true)]$Observed,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $expectedValues = @($Expected)
    $observedValues = @($Observed)
    if ($expectedValues.Count -ne $observedValues.Count) {
        throw "$Description has a different hash count."
    }
    for ($index = 0; $index -lt $expectedValues.Count; $index++) {
        $expectedHash = $expectedValues[$index]
        $observedHash = $observedValues[$index]
        if ([string]$expectedHash.path -cne [string]$observedHash.path -or
            [int64]$expectedHash.length -ne [int64]$observedHash.length -or
            [string]$expectedHash.sha256 -cne [string]$observedHash.sha256) {
            throw "$Description differs at hash index $index."
        }
    }
}

function Assert-V10Issue44ArtifactSemantics {
    param(
        [Parameter(Mandatory = $true)]$Artifact,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$ExpectedPackageVersion,
        [string]$ExpectedSourceCommit,
        [string]$ExpectedArchiveSha256,
        [string]$ExpectedManifestSha256,
        [string]$ExpectedContentSha256,
        [switch]$AllowSyntheticSource
    )

    if ($null -eq $Artifact) {
        throw "Issue #44 $Name artifact is required and must not be null."
    }
    Assert-AcceptanceArtifactReportRecord -Artifact $Artifact -Context "Issue #44 $Name artifact"
    if ([string]$Artifact.name -cne $Name -or
        [string]$Artifact.packageVersion -cne $ExpectedPackageVersion -or
        [string]$Artifact.packageRoot -match '[<>]' -or
        [string]$Artifact.archivePath -match '[<>]' -or
        [string]$Artifact.manifestPath -match '[<>]') {
        throw "Issue #44 $Name artifact identity is not exact."
    }
    if ([int64]$Artifact.archiveBytes -le 0 -or [int64]$Artifact.manifestBytes -le 0) {
        throw "Issue #44 $Name artifact byte counts must be positive."
    }
    foreach ($hashName in @('archiveSha256', 'manifestSha256', 'contentSha256')) {
        Assert-V10Issue44NonZeroSha256 -Value ([string]$Artifact.$hashName) -Description "Issue #44 $Name artifact $hashName"
    }

    $sourceCommit = [string]$Artifact.sourceCommitBinding
    if ($sourceCommit -ceq 'NOT_BOUND_IN_SYNTHETIC_FIXTURE') {
        if (-not $AllowSyntheticSource) {
            throw "Issue #44 $Name artifact has no exact source-commit binding."
        }
    } else {
        Assert-V10Hex -Value $sourceCommit -Length 40 -Description "Issue #44 $Name artifact sourceCommitBinding" -Lowercase
        if (-not [string]::IsNullOrWhiteSpace($ExpectedSourceCommit) -and $sourceCommit -cne $ExpectedSourceCommit) {
            throw "Issue #44 $Name artifact sourceCommitBinding does not match the accepted source commit."
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedArchiveSha256) -and [string]$Artifact.archiveSha256 -cne $ExpectedArchiveSha256) {
        throw "Issue #44 $Name artifact archive SHA-256 does not match the accepted candidate."
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedManifestSha256) -and [string]$Artifact.manifestSha256 -cne $ExpectedManifestSha256) {
        throw "Issue #44 $Name artifact manifest SHA-256 does not match the accepted candidate."
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedContentSha256) -and [string]$Artifact.contentSha256 -cne $ExpectedContentSha256) {
        throw "Issue #44 $Name artifact content SHA-256 does not match the accepted candidate."
    }
    Assert-V10Issue44HashList -Hashes $Artifact.installedFileHashes -Description "Issue #44 $Name artifact installedFileHashes"
}

function Assert-V10Issue44LifecycleSemantics {
    param(
        [Parameter(Mandatory = $true)]$Report,
        [Parameter(Mandatory = $true)]$InitialArtifact,
        [Parameter(Mandatory = $true)]$UpgradeArtifact
    )

    $lifecycle = Get-V10RequiredProperty -Object $Report -Name 'lifecycle' -Description 'Issue #44 report'
    $initialHashes = @($InitialArtifact.installedFileHashes)
    $upgradeHashes = @($UpgradeArtifact.installedFileHashes)
    $retainedHash = $null
    $stepNames = @('cleanInstall', 'upgrade', 'rollback', 'uninstall')
    foreach ($stepName in $stepNames) {
        $step = Get-V10RequiredProperty -Object $lifecycle -Name $stepName -Description 'Issue #44 lifecycle'
        if ([string]$step.status -cne 'PASS' -or [string]$step.retainedDataStatus -cne 'PASS') {
            throw "Issue #44 lifecycle step '$stepName' is not a complete pass."
        }
        Assert-V10Issue44HashList -Hashes $step.installedFileHashes -Description "Issue #44 lifecycle $stepName installedFileHashes"
        Assert-V10Issue44NonZeroSha256 -Value ([string]$step.retainedDataSha256) -Description "Issue #44 lifecycle $stepName retainedDataSha256"
        if ($null -eq $retainedHash) {
            $retainedHash = [string]$step.retainedDataSha256
        } elseif ($retainedHash -cne [string]$step.retainedDataSha256) {
            throw "Issue #44 lifecycle retained-data hashes are not continuous."
        }
    }

    $cleanInstall = $lifecycle.cleanInstall
    $upgrade = $lifecycle.upgrade
    $rollback = $lifecycle.rollback
    $uninstall = $lifecycle.uninstall
    if ([string]$cleanInstall.expectedVersion -cne [string]$InitialArtifact.packageVersion -or
        [string]$cleanInstall.packageVersionObserved -cne [string]$InitialArtifact.packageVersion -or
        -not [bool]$cleanInstall.installRootPresent -or
        [string]$upgrade.expectedVersion -cne [string]$UpgradeArtifact.packageVersion -or
        [string]$upgrade.packageVersionObserved -cne [string]$UpgradeArtifact.packageVersion -or
        -not [bool]$upgrade.installRootPresent -or
        [string]$rollback.expectedVersion -cne [string]$InitialArtifact.packageVersion -or
        [string]$rollback.packageVersionObserved -cne [string]$InitialArtifact.packageVersion -or
        -not [bool]$rollback.installRootPresent -or
        [string]$uninstall.packageVersionObserved -cne [string]$InitialArtifact.packageVersion -or
        [bool]$uninstall.installRootPresent) {
        throw 'Issue #44 lifecycle version or install-root observations do not bind to the initial/upgrade artifacts.'
    }
    Assert-V10Issue44HashListsEqual -Expected $initialHashes -Observed $cleanInstall.installedFileHashes -Description 'Issue #44 clean-install hashes versus initial artifact'
    Assert-V10Issue44HashListsEqual -Expected $upgradeHashes -Observed $upgrade.installedFileHashes -Description 'Issue #44 upgrade hashes versus upgrade artifact'
    Assert-V10Issue44HashListsEqual -Expected $initialHashes -Observed $rollback.installedFileHashes -Description 'Issue #44 rollback hashes versus initial artifact'
    Assert-V10Issue44HashListsEqual -Expected $initialHashes -Observed $uninstall.installedFileHashes -Description 'Issue #44 uninstall hashes versus initial artifact'
}

function Assert-V10Issue44ReportSemantics {
    param(
        [Parameter(Mandatory = $true)]$Report,
        [Parameter(Mandatory = $true)][string]$SourceCommit,
        [Parameter(Mandatory = $true)][string]$ArchiveSha256,
        [string]$ManifestSha256,
        [string]$ContentSha256,
        [switch]$RequireLiveCleanMachine
    )

    Assert-V10Hex -Value $SourceCommit -Length 40 -Description 'Issue #44 accepted source commit' -Lowercase
    Assert-V10Issue44NonZeroSha256 -Value $ArchiveSha256 -Description 'Issue #44 accepted archive SHA-256'
    if (-not [string]::IsNullOrWhiteSpace($ManifestSha256)) {
        Assert-V10Issue44NonZeroSha256 -Value $ManifestSha256 -Description 'Issue #44 accepted manifest SHA-256'
    }
    if (-not [string]::IsNullOrWhiteSpace($ContentSha256)) {
        Assert-V10Issue44NonZeroSha256 -Value $ContentSha256 -Description 'Issue #44 accepted content SHA-256'
    }

    $schemaPath = Join-Path $PSScriptRoot '..\..\docs\acceptance\issue-44-install-acceptance-report.schema.json'
    Assert-AcceptanceReportMatchesSchema -Report $Report -SchemaPath $schemaPath
    if ([int]$Report.schemaVersion -ne 1 -or
        [string]$Report.reportKind -cne 'HerdrOps.InstallAcceptanceReport' -or
        [int]$Report.issue -ne 44 -or
        [string]$Report.acceptanceVersion -cne 'v1.0.0' -or
        [string]$Report.status -cne 'PASS') {
        throw 'Issue #44 report top-level identity is not a passing v1.0.0 report.'
    }
    Assert-V10UtcTimestamp -Value ([string]$Report.startedAtUtc) -Description 'Issue #44 startedAtUtc'
    Assert-V10UtcTimestamp -Value ([string]$Report.completedAtUtc) -Description 'Issue #44 completedAtUtc'

    $isLive = ([string]$Report.mode -ceq 'Live' -and [string]$Report.evidenceClass -ceq 'CleanMachine')
    $isSynthetic = ([string]$Report.mode -ceq 'Fixture' -and [string]$Report.evidenceClass -ceq 'Synthetic')
    if ($RequireLiveCleanMachine -and -not $isLive) {
        throw 'Issue #44 report is not passing Live CleanMachine evidence.'
    }
    if (-not $RequireLiveCleanMachine -and -not $isSynthetic) {
        throw 'Synthetic Issue #44 acceptance must remain Fixture/Synthetic evidence.'
    }

    $machine = Get-V10RequiredProperty -Object $Report -Name 'machine' -Description 'Issue #44 report'
    foreach ($machineName in @('name', 'expectedName', 'fingerprint', 'expectedFingerprint')) {
        if ([string]::IsNullOrWhiteSpace([string]$machine.$machineName) -or
            [string]$machine.$machineName -match '[<>]' -or
            [string]$machine.$machineName -in @('PENDING', 'UNKNOWN', 'NOT ASSIGNED')) {
            throw "Issue #44 machine $machineName is not an exact concrete binding."
        }
    }
    Assert-V10Hex -Value ([string]$machine.fingerprint) -Length 64 -Description 'Issue #44 machine fingerprint' -Uppercase
    Assert-V10Hex -Value ([string]$machine.expectedFingerprint) -Length 64 -Description 'Issue #44 expected machine fingerprint' -Uppercase
    if ([string]$machine.name -cne [string]$machine.expectedName -or
        [string]$machine.fingerprint -cne [string]$machine.expectedFingerprint -or
        [bool]$machine.elevated) {
        throw 'Issue #44 machine identity or elevation binding is not exact.'
    }

    $artifacts = Get-V10RequiredProperty -Object $Report -Name 'artifacts' -Description 'Issue #44 report'
    $initialArtifact = Get-V10RequiredProperty -Object $artifacts -Name 'initial' -Description 'Issue #44 artifacts'
    $upgradeArtifact = Get-V10RequiredProperty -Object $artifacts -Name 'upgrade' -Description 'Issue #44 artifacts'
    Assert-V10Issue44ArtifactSemantics `
        -Artifact $initialArtifact `
        -Name 'initial' `
        -ExpectedPackageVersion '0.7.0' `
        -AllowSyntheticSource:(-not $RequireLiveCleanMachine)
    Assert-V10Issue44ArtifactSemantics `
        -Artifact $upgradeArtifact `
        -Name 'upgrade' `
        -ExpectedPackageVersion '1.0.0' `
        -ExpectedSourceCommit $SourceCommit `
        -ExpectedArchiveSha256 $ArchiveSha256 `
        -ExpectedManifestSha256 $ManifestSha256 `
        -ExpectedContentSha256 $ContentSha256 `
        -AllowSyntheticSource:(-not $RequireLiveCleanMachine)
    if ([Version]$upgradeArtifact.packageVersion -le [Version]$initialArtifact.packageVersion) {
        throw 'Issue #44 upgrade artifact version must be greater than the initial artifact version.'
    }

    $targets = Get-V10RequiredProperty -Object $Report -Name 'targets' -Description 'Issue #44 report'
    foreach ($targetName in @('installRoot', 'userDataRoot')) {
        if ([string]::IsNullOrWhiteSpace([string]$targets.$targetName) -or [string]$targets.$targetName -match '[<>]') {
            throw "Issue #44 target $targetName is not bound."
        }
    }
    if ($RequireLiveCleanMachine -and [string]::IsNullOrWhiteSpace([string]$targets.reportPath)) {
        throw 'Issue #44 Live report is missing its bound reportPath.'
    }

    $preflight = Get-V10RequiredProperty -Object $Report -Name 'preflight' -Description 'Issue #44 report'
    if ([string]$preflight.status -cne 'PASS' -or @($preflight.checks).Count -eq 0 -or
        @($preflight.checks | Where-Object { [string]$_.status -eq 'FAIL' }).Count -gt 0) {
        throw 'Issue #44 preflight did not pass without failed checks.'
    }
    foreach ($checkName in @('initial-artifact-identity-hash-version', 'upgrade-artifact-identity-hash-version', 'version-order', 'v1-target-version')) {
        $matchingChecks = @($preflight.checks | Where-Object { [string]$_.name -ceq $checkName })
        if ($matchingChecks.Count -ne 1 -or [string]$matchingChecks[0].status -cne 'PASS') {
            throw "Issue #44 preflight check '$checkName' is missing or not PASS."
        }
    }

    Assert-V10Issue44LifecycleSemantics -Report $Report -InitialArtifact $initialArtifact -UpgradeArtifact $upgradeArtifact
    $cleanup = Get-V10RequiredProperty -Object $Report -Name 'cleanup' -Description 'Issue #44 report'
    if ([string]$cleanup.status -cne 'PASS' -or
        -not [bool]$cleanup.attempted -or
        -not [bool]$cleanup.ownedStageRemoved -or
        -not [bool]$cleanup.ownedBackupRemoved -or
        -not [bool]$cleanup.retainedDataLeftIntact -or
        @($cleanup.residuals).Count -ne 0 -or
        -not [string]::IsNullOrEmpty([string]$Report.failureDetails)) {
        throw 'Issue #44 cleanup contains residuals or an incomplete failure state.'
    }

    $boundaries = Get-V10RequiredProperty -Object $Report -Name 'boundaries' -Description 'Issue #44 report'
    if ([string]$boundaries.static -notlike 'PASS*' -or
        [string]$boundaries.cleanMachine -notlike 'PASS*' -and $RequireLiveCleanMachine) {
        throw 'Issue #44 static/clean-machine boundary is not passing for the selected evidence mode.'
    }
    if ($isSynthetic -and [string]$boundaries.synthetic -notlike 'PASS*') {
        throw 'Synthetic Issue #44 fixture must explicitly report Synthetic PASS evidence.'
    }
    foreach ($boundaryName in @('runtime', 'release')) {
        if ([string]$boundaries.$boundaryName -notlike 'NOT OBSERVED*') {
            throw "Issue #44 $boundaryName boundary must remain NOT OBSERVED."
        }
    }
    foreach ($boundaryName in @('contract', 'independentReview')) {
        if ([string]$boundaries.$boundaryName -notlike 'NOT OBSERVED*') {
            throw "Issue #44 $boundaryName boundary must remain NOT OBSERVED."
        }
    }
    if ($isSynthetic -and [string]$boundaries.cleanMachine -notlike 'NOT OBSERVED*') {
        throw 'Synthetic Issue #44 fixture must not claim CleanMachine evidence.'
    }
}

function Assert-V10SafeRelativePathText {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Description
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or [IO.Path]::IsPathRooted($Path) -or
        $Path -match '(^|[\\/])\.\.([\\/]|$)' -or $Path -match '(^|[\\/])\.([\\/]|$)') {
        throw "$Description must be a non-traversing relative path: $Path"
    }
    $segments = @($Path -split '[\\/]')
    if ($segments.Count -eq 0) {
        throw "$Description is empty."
    }
    foreach ($segment in $segments) {
        if ([string]::IsNullOrWhiteSpace($segment) -or $segment -in @('.', '..') -or
            $segment -match '[<>:"|?*]' -or $segment.EndsWith('.') -or $segment.EndsWith(' ')) {
            throw "$Description contains an unsafe path segment: $Path"
        }
    }
}

function Assert-V10NoReparseComponents {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root
    )

    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $full = [IO.Path]::GetFullPath($Path)
    if (-not (Test-PathWithin -ChildPath $full -RootPath $rootFull)) {
        throw "Protected path escaped its root: $full"
    }
    $relative = $full.Substring($rootFull.Length).TrimStart('\')
    $current = $rootFull
    foreach ($segment in @($relative -split '[\\/]')) {
        if ([string]::IsNullOrWhiteSpace($segment)) {
            continue
        }
        $current = Join-Path $current $segment
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Reparse points are not allowed in release evidence paths: $current"
            }
        }
    }
}

function Resolve-V10RepositoryFile {
    param(
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$Description
    )

    Assert-V10SafeRelativePathText -Path $RelativePath -Description $Description
    $root = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd('\')
    $full = [IO.Path]::GetFullPath((Join-Path $root $RelativePath))
    if (-not (Test-PathWithin -ChildPath $full -RootPath $root) -or $full.Equals($root, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Description escaped the repository root: $RelativePath"
    }
    Assert-V10NoReparseComponents -Path $full -Root $root
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        throw "$Description was not found: $full"
    }
    return $full
}

function Get-V10FileRecord {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$RecordedPath
    )

    $item = Get-Item -LiteralPath $Path -Force
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Release file record requires an ordinary file: $Path"
    }
    return [ordered]@{
        path = $RecordedPath.Replace('\', '/')
        length = [int64]$item.Length
        sha256 = ((Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash).ToUpperInvariant()
    }
}

function Get-V10GitIdentity {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [string]$ExpectedCommit,
        [switch]$RequireClean
    )

    $commitOutput = @(& git -C $RepositoryRoot rev-parse --verify 'HEAD^{commit}' 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0 -or $commitOutput.Count -ne 1 -or $commitOutput[0].Trim() -cnotmatch '^[0-9a-f]{40}$') {
        throw 'The release checkout does not have one exact committed HEAD identity.'
    }
    $commit = $commitOutput[0].Trim()
    if (-not [string]::IsNullOrWhiteSpace($ExpectedCommit) -and $commit -cne $ExpectedCommit) {
        throw "The release checkout HEAD '$commit' does not match expected commit '$ExpectedCommit'."
    }

    $status = @(& git -C $RepositoryRoot status --porcelain=v1 --untracked-files=all 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0) {
        throw 'The release checkout status could not be inspected.'
    }
    if ($RequireClean -and $status.Count -ne 0) {
        throw "Release work requires a clean checkout. Pending paths: $($status -join '; ')"
    }
    return [pscustomobject][ordered]@{
        Commit = $commit
        WorkingTree = if ($status.Count -eq 0) { 'CLEAN' } else { 'DIRTY' }
        Status = @($status)
    }
}

function Assert-V10ReleaseProfile {
    param([Parameter(Mandatory = $true)]$Profile)

    Assert-PackageProfile -Profile $Profile
    Assert-V10ExactProperties -Object $Profile -Names @(
        'schemaVersion', 'issue', 'productId', 'displayName', 'packageVersion',
        'targetFramework', 'runtimeIdentifier', 'configuration', 'publishMode',
        'bundleLayout', 'canonicalRuntimeComponent', 'canonicalRuntimeOverlayPaths',
        'sourceProject', 'deploymentModel', 'installPathTemplate', 'userDataPathTemplate',
        'userDataPolicy', 'startupPolicy', 'administratorRequired', 'runtimeUse',
        'releaseVersion', 'repository', 'releaseTag', 'components', 'releaseDocuments') -Description 'v1 release profile'

    if ([int]$Profile.issue -ne 45 -or [string]$Profile.packageVersion -cne '1.0.0' -or
        [string]$Profile.releaseVersion -cne 'v1.0.0' -or [string]$Profile.releaseTag -cne 'v1.0.0' -or
        [string]$Profile.repository -cne 'OSHEThai/HerdrOps' -or
        [string]$Profile.runtimeUse -cne 'not-used') {
        throw 'The v1 release profile must be bound exactly to Issue #45, v1.0.0, OSHEThai/HerdrOps, and runtimeUse=not-used.'
    }

    $expectedComponents = @(
        [ordered]@{ name = 'App'; project = 'src\HerdrOps.App\HerdrOps.App.csproj'; assemblyName = 'HerdrOps.App'; outputType = 'WinExe'; useWpf = 'true' },
        [ordered]@{ name = 'Core'; project = 'src\HerdrOps.Core\HerdrOps.Core.csproj'; assemblyName = 'HerdrOps.Core'; outputType = 'Exe'; useWpf = '' },
        [ordered]@{ name = 'Cli'; project = 'src\HerdrOps.Cli\HerdrOps.Cli.csproj'; assemblyName = 'HerdrOps.Cli'; outputType = 'Exe'; useWpf = '' })
    $components = @($Profile.components)
    if ($components.Count -ne $expectedComponents.Count) {
        throw 'The v1 release profile must contain exactly App, Core, and Cli components.'
    }
    for ($index = 0; $index -lt $expectedComponents.Count; $index++) {
        $component = $components[$index]
        Assert-V10ExactProperties -Object $component -Names @('name', 'project', 'assemblyName', 'outputType', 'useWpf') -Description "v1 release component $index"
        foreach ($name in $expectedComponents[$index].Keys) {
            if ([string](Get-V10RequiredProperty -Object $component -Name $name -Description "v1 release component $index") -cne [string]$expectedComponents[$index][$name]) {
                throw "The v1 release component '$($expectedComponents[$index].name)' property '$name' has drifted."
            }
        }
    }
    if ([string]$Profile.sourceProject -cne [string]$expectedComponents[0].project) {
        throw 'The primary v1 release sourceProject must remain HerdrOps.App.'
    }

    if ([string]$Profile.bundleLayout -cne 'flat-shared-runtime' -or
        [string]$Profile.canonicalRuntimeComponent -cne 'App') {
        throw 'The v1 release bundle must use the App-owned flat shared-runtime layout.'
    }
    $expectedRuntimeOverlayPaths = @(
        'Microsoft.VisualBasic.dll',
        'System.Drawing.dll',
        'WindowsBase.dll')
    $runtimeOverlayPaths = @($Profile.canonicalRuntimeOverlayPaths | ForEach-Object { [string]$_ })
    if ($runtimeOverlayPaths.Count -ne $expectedRuntimeOverlayPaths.Count) {
        throw 'The v1 release profile must bind exactly three Windows Desktop runtime overlays.'
    }
    for ($index = 0; $index -lt $expectedRuntimeOverlayPaths.Count; $index++) {
        if ($runtimeOverlayPaths[$index] -cne $expectedRuntimeOverlayPaths[$index]) {
            throw "The v1 canonical runtime overlay binding has drifted at index $index."
        }
        Assert-V10SafeRelativePathText -Path $runtimeOverlayPaths[$index] -Description 'canonical runtime overlay path'
    }

    $expectedDocuments = @(
        'docs/release/v1.0.0/release-notes.en.md',
        'docs/release/v1.0.0/release-notes.th.md',
        'docs/release/v1.0.0/user-guide.en.md',
        'docs/release/v1.0.0/user-guide.th.md',
        'docs/release/v1.0.0/upgrade-rollback.en.md',
        'docs/release/v1.0.0/upgrade-rollback.th.md',
        'docs/release/v1.0.0/troubleshooting.en.md',
        'docs/release/v1.0.0/troubleshooting.th.md')
    $documents = @($Profile.releaseDocuments | ForEach-Object { [string]$_ })
    if ($documents.Count -ne $expectedDocuments.Count) {
        throw 'The v1 release profile must bind all eight language-separated release documents.'
    }
    for ($index = 0; $index -lt $expectedDocuments.Count; $index++) {
        if ($documents[$index] -cne $expectedDocuments[$index]) {
            throw "The v1 release document binding has drifted at index $index."
        }
        Assert-V10SafeRelativePathText -Path $documents[$index] -Description 'release document path'
    }
}

function Read-V10ReleaseProfile {
    param([string]$Path = (Join-Path $PSScriptRoot 'v1.0-package-profile.json'))

    $profile = Read-PackageProfile -Path $Path
    Assert-V10ReleaseProfile -Profile $profile
    return $profile
}

function Assert-V10ProjectMatchesComponent {
    param(
        [Parameter(Mandatory = $true)]$Profile,
        [Parameter(Mandatory = $true)]$Component,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [string]$TestDotnetCommandPath
    )

    Assert-V10ReleaseProfile -Profile $Profile
    $relativeProject = [string]$Component.project
    $projectPath = Resolve-V10RepositoryFile -RelativePath $relativeProject -RepositoryRoot $RepositoryRoot -Description "component $($Component.name) project"
    try {
        [xml]$projectXml = [IO.File]::ReadAllText($projectPath)
    } catch {
        throw "Component project is not valid XML: $projectPath. $($_.Exception.Message)"
    }
    if ([string]$projectXml.Project.Sdk -cne 'Microsoft.NET.Sdk') {
        throw "Component $($Component.name) must use Microsoft.NET.Sdk."
    }

    $staticAncestry = @(Get-PackagingProjectImportAncestry -ProjectPath $projectPath -RepositoryRoot $RepositoryRoot)
    $properties = Invoke-PackagingMSBuildPropertyEvaluation -ProjectPath $projectPath -Profile $Profile -TestDotnetCommandPath $TestDotnetCommandPath
    $projectDirectory = Normalize-ComparablePath -Path (Split-Path -Path $projectPath -Parent)
    $expectedOutput = 'bin\Release\net10.0-windows\win-x64\'
    $expected = [ordered]@{
        AssemblyName = [string]$Component.assemblyName
        TargetName = [string]$Component.assemblyName
        RootNamespace = [string]$Component.assemblyName
        TargetFramework = 'net10.0-windows'
        TargetFrameworks = ''
        OutputType = [string]$Component.outputType
        UseWPF = [string]$Component.useWpf
        TargetExt = '.dll'
        TargetFileName = ([string]$Component.assemblyName + '.dll')
        UseAppHost = 'true'
        AppHostName = ''
        PlatformTarget = 'x64'
        Platform = 'AnyCPU'
        RuntimeIdentifier = 'win-x64'
        SelfContained = 'true'
        PublishSingleFile = ''
        PublishTrimmed = ''
        PublishReadyToRun = ''
        GenerateAssemblyInfo = 'true'
        OutputPath = $expectedOutput
        PublishDir = ($expectedOutput + 'publish\')
        MSBuildProjectFullPath = (Normalize-ComparablePath -Path $projectPath)
        MSBuildProjectDirectory = $projectDirectory
    }
    foreach ($name in $expected.Keys) {
        if ([string]$properties.$name -cne [string]$expected[$name]) {
            throw "Component $($Component.name) effective MSBuild property '$name' must be '$($expected[$name])', observed '$($properties.$name)'."
        }
    }
    $trustedDotnetRoot = Get-PackagingTrustedDotnetRoot -CommandPath $TestDotnetCommandPath
    Assert-PackagingEvaluatedImportPaths -Properties $properties -StaticAncestry $staticAncestry -RepositoryRoot $RepositoryRoot -TrustedDotnetRoot $trustedDotnetRoot
    return [pscustomobject][ordered]@{
        Name = [string]$Component.name
        ProjectPath = $projectPath
        AssemblyName = [string]$Component.assemblyName
        ImportAncestry = $staticAncestry
    }
}

function Assert-V10PublishedComponent {
    param(
        [Parameter(Mandatory = $true)]$Profile,
        [Parameter(Mandatory = $true)]$Component,
        [Parameter(Mandatory = $true)][string]$PublishRoot
    )

    $root = Assert-SafeDestination -Path $PublishRoot -AllowRepositoryChild -AllowTempChild
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        throw "Published component directory was not found: $root"
    }
    Assert-NoReparsePath -Path $root
    Assert-NoReparseDescendants -Path $root
    $assemblyName = [string]$Component.assemblyName
    $dllPath = Join-Path $root ($assemblyName + '.dll')
    $exePath = Join-Path $root ($assemblyName + '.exe')
    foreach ($path in @($dllPath, $exePath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Published component $($Component.name) is missing: $path"
        }
    }

    try {
        $identity = [Reflection.AssemblyName]::GetAssemblyName($dllPath)
    } catch {
        throw "Could not read published component identity '$dllPath': $($_.Exception.Message)"
    }
    $expectedVersion = [Version]$Profile.packageVersion
    if ([string]$identity.Name -cne $assemblyName -or $null -eq $identity.Version -or
        $identity.Version.Major -ne $expectedVersion.Major -or
        $identity.Version.Minor -ne $expectedVersion.Minor -or
        $identity.Version.Build -ne $expectedVersion.Build) {
        throw "Published component $($Component.name) does not carry version $($Profile.packageVersion)."
    }
    $fileVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($dllPath).FileVersion
    try { $parsedFileVersion = [Version]$fileVersion } catch { throw "Published component $($Component.name) has an invalid file version: $fileVersion" }
    if ($parsedFileVersion.Major -ne $expectedVersion.Major -or
        $parsedFileVersion.Minor -ne $expectedVersion.Minor -or
        $parsedFileVersion.Build -ne $expectedVersion.Build) {
        throw "Published component $($Component.name) file version does not match $($Profile.packageVersion)."
    }
    return [pscustomobject][ordered]@{
        Name = [string]$Component.name
        AssemblyName = $assemblyName
        PublishRoot = $root
        DllPath = (Get-FullPath -Path $dllPath)
        ExePath = (Get-FullPath -Path $exePath)
    }
}

function Get-V10AssemblyMetadata {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = Normalize-ComparablePath -Path $Path
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "Assembly metadata input was not found: $fullPath"
    }
    try {
        $identity = [Reflection.AssemblyName]::GetAssemblyName($fullPath)
        $fileVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($fullPath).FileVersion
    } catch {
        throw "Could not inspect shared-runtime assembly '$fullPath': $($_.Exception.Message)"
    }
    $tokenBytes = @($identity.GetPublicKeyToken())
    if ($null -eq $identity.Version -or $tokenBytes.Count -eq 0 -or [string]::IsNullOrWhiteSpace($fileVersion)) {
        throw "Shared-runtime assembly metadata is incomplete: $fullPath"
    }
    $token = ($tokenBytes | ForEach-Object {
            ([byte]$_).ToString('x2', [Globalization.CultureInfo]::InvariantCulture)
        }) -join ''

    return [pscustomobject][ordered]@{
        Name = [string]$identity.Name
        AssemblyVersion = [Version]$identity.Version
        PublicKeyToken = $token
        FileVersion = [string]$fileVersion
    }
}

function Get-V10CanonicalRuntimeOverlayPaths {
    param(
        [Parameter(Mandatory = $true)]$Profile,
        [Parameter(Mandatory = $true)][object[]]$Components
    )

    Assert-V10ReleaseProfile -Profile $Profile
    $componentList = @($Components)
    $expectedComponentNames = @($Profile.components | ForEach-Object { [string]$_.name })
    if ($componentList.Count -ne $expectedComponentNames.Count) {
        throw 'Shared-runtime composition requires exactly the App, Core, and Cli publish outputs.'
    }

    $recordsByPath = @{}
    for ($index = 0; $index -lt $componentList.Count; $index++) {
        $component = $componentList[$index]
        $componentName = [string]$component.Name
        if ($componentName -cne $expectedComponentNames[$index]) {
            throw "Shared-runtime component order has drifted at index $index."
        }
        $sourceRoot = Normalize-ComparablePath -Path ([string]$component.PublishRoot)
        if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) {
            throw "Published shared-runtime component is missing: $sourceRoot"
        }
        Assert-NoReparsePath -Path $sourceRoot
        Assert-NoReparseDescendants -Path $sourceRoot

        foreach ($file in @(Get-ChildItem -LiteralPath $sourceRoot -Recurse -Force -File | Sort-Object FullName)) {
            $relative = Get-SafeRelativePath -RootPath $sourceRoot -Path $file.FullName
            if ($recordsByPath.ContainsKey($relative)) {
                $existingGroup = $recordsByPath[$relative]
                if ([string]$existingGroup.Relative -cne $relative) {
                    throw "Component outputs contain a case-ambiguous Windows path: '$relative' and '$($existingGroup.Relative)'."
                }
            } else {
                $existingGroup = [pscustomobject][ordered]@{
                    Relative = $relative
                    Entries = (New-Object System.Collections.ArrayList)
                }
                $recordsByPath[$relative] = $existingGroup
            }
            [void]$existingGroup.Entries.Add([pscustomobject][ordered]@{
                    Component = $componentName
                    Path = $file.FullName
                    Sha256 = ((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash).ToUpperInvariant()
                })
        }
    }

    $conflictPaths = New-Object System.Collections.ArrayList
    foreach ($group in @($recordsByPath.Values)) {
        $hashes = @($group.Entries | ForEach-Object { [string]$_.Sha256 } | Sort-Object -Unique)
        if ($hashes.Count -gt 1) {
            [void]$conflictPaths.Add([string]$group.Relative)
        }
    }

    $expectedPaths = @($Profile.canonicalRuntimeOverlayPaths | ForEach-Object { [string]$_ })
    if ($conflictPaths.Count -ne $expectedPaths.Count) {
        throw "Shared-runtime conflicts have drifted: expected $($expectedPaths.Count), observed $($conflictPaths.Count)."
    }
    foreach ($expectedPath in $expectedPaths) {
        if (-not (@($conflictPaths.ToArray()) -ccontains $expectedPath)) {
            throw "Shared-runtime conflicts do not contain the exact approved App overlay '$expectedPath'."
        }

        $entries = @($recordsByPath[$expectedPath].Entries)
        if ($entries.Count -ne $expectedComponentNames.Count) {
            throw "Canonical runtime overlay '$expectedPath' must exist in App, Core, and Cli outputs."
        }
        $app = @($entries | Where-Object { [string]$_.Component -ceq 'App' })
        $core = @($entries | Where-Object { [string]$_.Component -ceq 'Core' })
        $cli = @($entries | Where-Object { [string]$_.Component -ceq 'Cli' })
        if ($app.Count -ne 1 -or $core.Count -ne 1 -or $cli.Count -ne 1 -or
            [string]$core[0].Sha256 -cne [string]$cli[0].Sha256 -or
            [string]$app[0].Sha256 -ceq [string]$core[0].Sha256) {
            throw "Canonical runtime overlay '$expectedPath' does not have the approved App-versus-console byte pattern."
        }

        $appMetadata = Get-V10AssemblyMetadata -Path ([string]$app[0].Path)
        $coreMetadata = Get-V10AssemblyMetadata -Path ([string]$core[0].Path)
        $cliMetadata = Get-V10AssemblyMetadata -Path ([string]$cli[0].Path)
        $expectedAssemblyName = [IO.Path]::GetFileNameWithoutExtension($expectedPath)
        if ([string]$appMetadata.Name -cne $expectedAssemblyName -or
            [string]$coreMetadata.Name -cne $expectedAssemblyName -or
            [string]$cliMetadata.Name -cne $expectedAssemblyName -or
            [string]$appMetadata.PublicKeyToken -cne [string]$coreMetadata.PublicKeyToken -or
            [string]$coreMetadata.PublicKeyToken -cne [string]$cliMetadata.PublicKeyToken -or
            [string]$coreMetadata.AssemblyVersion -cne [string]$cliMetadata.AssemblyVersion -or
            $appMetadata.AssemblyVersion.CompareTo($coreMetadata.AssemblyVersion) -lt 0 -or
            [string]$appMetadata.FileVersion -cne [string]$coreMetadata.FileVersion -or
            [string]$coreMetadata.FileVersion -cne [string]$cliMetadata.FileVersion) {
            throw "Canonical runtime overlay '$expectedPath' failed assembly identity or SDK file-version validation."
        }
    }

    return @($expectedPaths)
}

function Merge-V10PublishedComponents {
    param(
        [Parameter(Mandatory = $true)][object[]]$Components,
        [Parameter(Mandatory = $true)][string]$DestinationRoot,
        [string]$CanonicalComponentName,
        [string[]]$AllowedCanonicalConflictRelativePath = @()
    )

    $destination = Assert-SafeDestination -Path $DestinationRoot -AllowRepositoryChild -AllowTempChild
    if (-not (Test-Path -LiteralPath $destination -PathType Container)) {
        throw "Release bundle destination was not found: $destination"
    }
    if (@(Get-ChildItem -LiteralPath $destination -Force).Count -ne 0) {
        throw "Release bundle destination must be empty: $destination"
    }
    Assert-NoReparsePath -Path $destination

    $componentList = @($Components)
    $allowedConflicts = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($allowedPath in @($AllowedCanonicalConflictRelativePath)) {
        Assert-V10SafeRelativePathText -Path $allowedPath -Description 'allowed canonical conflict path'
        if (-not $allowedConflicts.Add($allowedPath)) {
            throw "Allowed canonical conflict path is duplicated: $allowedPath"
        }
    }
    if ($allowedConflicts.Count -gt 0 -and
        ([string]::IsNullOrWhiteSpace($CanonicalComponentName) -or
            $componentList.Count -eq 0 -or
            [string]$componentList[0].Name -cne $CanonicalComponentName)) {
        throw 'The canonical shared-runtime component must be the first merge input.'
    }

    $seen = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
    $owners = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
    $observedCanonicalConflicts = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $entrypoints = New-Object System.Collections.ArrayList
    foreach ($component in $componentList) {
        $sourceRoot = Normalize-ComparablePath -Path ([string]$component.PublishRoot)
        if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) {
            throw "Published component source is missing: $sourceRoot"
        }
        Assert-NoReparsePath -Path $sourceRoot
        Assert-NoReparseDescendants -Path $sourceRoot
        foreach ($file in @(Get-ChildItem -LiteralPath $sourceRoot -Recurse -Force -File | Sort-Object FullName)) {
            $relative = Get-SafeRelativePath -RootPath $sourceRoot -Path $file.FullName
            if ($seen.ContainsKey($relative) -and [string]$seen[$relative] -cne $relative) {
                throw "Component outputs contain a case-ambiguous Windows path: '$relative' and '$($seen[$relative])'."
            }
            if (-not $seen.ContainsKey($relative)) {
                $seen.Add($relative, $relative)
                $owners.Add($relative, [string]$component.Name)
            }
            $destinationPath = Join-Path $destination $relative.Replace('/', '\')
            $parent = Split-Path -Path $destinationPath -Parent
            if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
            }
            if (Test-Path -LiteralPath $destinationPath) {
                $existing = Get-Item -LiteralPath $destinationPath -Force
                $bytesMatch = -not $existing.PSIsContainer -and
                    [int64]$existing.Length -eq [int64]$file.Length -and
                    ((Get-FileHash -LiteralPath $existing.FullName -Algorithm SHA256).Hash) -ceq
                    ((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash)
                if (-not $bytesMatch -and
                    -not ($allowedConflicts.Contains($relative) -and
                        $owners.ContainsKey($relative) -and
                        [string]$owners[$relative] -ceq $CanonicalComponentName)) {
                    throw "Component outputs conflict at '$relative'; duplicate bundle paths must be byte-identical."
                }
                if (-not $bytesMatch) {
                    [void]$observedCanonicalConflicts.Add($relative)
                }
            } else {
                Copy-PackagingFileDurably -Source $file.FullName -Destination $destinationPath | Out-Null
            }
        }

        foreach ($extension in @('dll', 'exe')) {
            $name = [string]$component.AssemblyName + '.' + $extension
            $path = Join-Path $destination $name
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                throw "Merged release bundle is missing component entry point '$name'."
            }
            [void]$entrypoints.Add((Get-V10FileRecord -Path $path -RecordedPath $name))
        }
    }

    if ($allowedConflicts.Count -ne $observedCanonicalConflicts.Count) {
        throw 'The declared canonical shared-runtime conflict set was not observed exactly.'
    }
    foreach ($allowedPath in $allowedConflicts) {
        if (-not $observedCanonicalConflicts.Contains($allowedPath)) {
            throw "The declared canonical shared-runtime conflict was not observed: $allowedPath"
        }
    }

    return [pscustomobject][ordered]@{
        DestinationRoot = $destination
        FileCount = @(Get-ChildItem -LiteralPath $destination -Recurse -Force -File).Count
        EntryPoints = @($entrypoints.ToArray())
        CanonicalConflictPaths = @($observedCanonicalConflicts | ForEach-Object { [string]$_ } | Sort-Object)
    }
}

function Read-V10StrictJsonFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Description
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Description was not found: $Path"
    }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Description must not be a reparse point: $Path"
    }
    $raw = [IO.File]::ReadAllText($item.FullName)
    $value = ConvertFrom-StrictPackageJson -Json $raw -Description $Description
    return [pscustomobject][ordered]@{
        Value = $value
        Raw = $raw
        Path = $item.FullName
        Length = [int64]$item.Length
        Sha256 = ((Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash).ToUpperInvariant()
    }
}

function Write-V10NewJsonFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value
    )

    $fullPath = Assert-SafeDestination -Path $Path -AllowRepositoryChild -AllowTempChild
    if (Test-Path -LiteralPath $fullPath) {
        throw "Refusing to overwrite release evidence: $fullPath"
    }
    $parent = Split-Path -Path $fullPath -Parent
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    Assert-NoReparsePath -Path $parent
    $json = ($Value | ConvertTo-Json -Depth 30) + "`n"
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($json)
    return (Invoke-PackagingAtomicFileWrite -DestinationPath $fullPath -OperationName 'v1 release evidence' -WriteStagedFile {
            param($stagingPath, $faultStage)
            Write-PackagingBytesToStagingFile -Path $stagingPath -Bytes $bytes -OperationName 'v1 release evidence'
        })
}

function New-V10CandidateRecord {
    param(
        [Parameter(Mandatory = $true)]$Profile,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$ProfilePath,
        [Parameter(Mandatory = $true)][string]$SourceCommit,
        [Parameter(Mandatory = $true)]$Generation,
        [string]$GeneratedAtUtc = ([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ', [Globalization.CultureInfo]::InvariantCulture))
    )

    Assert-V10ReleaseProfile -Profile $Profile
    Assert-V10Hex -Value $SourceCommit -Length 40 -Description 'candidate source commit' -Lowercase
    Assert-V10UtcTimestamp -Value $GeneratedAtUtc -Description 'candidate generatedAtUtc'
    $generationRoot = Normalize-ComparablePath -Path ([string]$Generation.GenerationRoot)
    $packageRoot = Normalize-ComparablePath -Path ([string]$Generation.PackageRoot)
    if (-not (Test-PathWithin -ChildPath $packageRoot -RootPath $generationRoot)) {
        throw 'Candidate package root escaped its committed generation.'
    }

    $components = New-Object System.Collections.ArrayList
    foreach ($component in @($Profile.components)) {
        $entrypoints = New-Object System.Collections.ArrayList
        foreach ($extension in @('dll', 'exe')) {
            $fileName = [string]$component.assemblyName + '.' + $extension
            $path = Join-Path $packageRoot $fileName
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                throw "Candidate package is missing '$fileName'."
            }
            [void]$entrypoints.Add((Get-V10FileRecord -Path $path -RecordedPath $fileName))
        }
        [void]$components.Add([ordered]@{
                name = [string]$component.name
                assemblyName = [string]$component.assemblyName
                entryPoints = @($entrypoints.ToArray())
            })
    }

    $documents = New-Object System.Collections.ArrayList
    foreach ($relativePath in @($Profile.releaseDocuments)) {
        $fullPath = Resolve-V10RepositoryFile -RelativePath ([string]$relativePath) -RepositoryRoot $RepositoryRoot -Description 'release document'
        [void]$documents.Add((Get-V10FileRecord -Path $fullPath -RecordedPath ([string]$relativePath)))
    }
    $profileRelative = $script:V10ReleaseProfileRelativePath
    $profileFull = Resolve-V10RepositoryFile -RelativePath $profileRelative -RepositoryRoot $RepositoryRoot -Description 'v1 release profile'
    if (-not ([IO.Path]::GetFullPath($profileFull).Equals([IO.Path]::GetFullPath($ProfilePath), [StringComparison]::OrdinalIgnoreCase))) {
        throw 'Candidate profile path is not the canonical v1 release profile.'
    }

    return [ordered]@{
        schemaVersion = 1
        reportKind = 'HerdrOps.ReleaseCandidate'
        issue = 45
        evidenceClass = 'Static'
        repository = 'OSHEThai/HerdrOps'
        releaseVersion = 'v1.0.0'
        releaseTag = 'v1.0.0'
        packageVersion = '1.0.0'
        sourceCommit = $SourceCommit
        workingTree = 'CLEAN'
        generatedAtUtc = $GeneratedAtUtc
        profile = Get-V10FileRecord -Path $profileFull -RecordedPath $profileRelative
        generation = [ordered]@{
            packageDirectory = 'package'
            archiveFile = [IO.Path]::GetFileName([string]$Generation.ArchivePath)
            archiveBytes = [int64]$Generation.ArchiveBytes
            archiveSha256 = [string]$Generation.ArchiveSha256
            manifestFile = 'package/package-manifest.json'
            manifestBytes = [int64]$Generation.ManifestBytes
            manifestSha256 = [string]$Generation.ManifestSha256
            contentSha256 = [string]$Generation.ContentSha256
            hashRecordFile = [IO.Path]::GetFileName([string]$Generation.HashRecordPath)
            hashRecordSha256 = ((Get-FileHash -LiteralPath ([string]$Generation.HashRecordPath) -Algorithm SHA256).Hash).ToUpperInvariant()
            metadataFile = 'generation.metadata'
            metadataSha256 = ((Get-FileHash -LiteralPath ([string]$Generation.MetadataPath) -Algorithm SHA256).Hash).ToUpperInvariant()
            commitMarkerFile = 'commit.marker'
            commitMarkerSha256 = ((Get-FileHash -LiteralPath ([string]$Generation.CommitMarkerPath) -Algorithm SHA256).Hash).ToUpperInvariant()
        }
        components = @($components.ToArray())
        documents = @($documents.ToArray())
        boundaries = [ordered]@{
            static = 'PASS'
            synthetic = 'NOT OBSERVED'
            contract = 'NOT OBSERVED'
            cleanMachine = 'NOT OBSERVED'
            runtime = 'NOT OBSERVED'
            independentReview = 'NOT OBSERVED'
            human = 'NOT OBSERVED'
            release = 'NOT OBSERVED'
        }
    }
}

function Assert-V10CandidateRecord {
    param(
        [Parameter(Mandatory = $true)][string]$CandidateRecordPath,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [string]$ExpectedSourceCommit,
        [string]$ProfilePath = (Join-Path $PSScriptRoot 'v1.0-package-profile.json')
    )

    $profile = Read-V10ReleaseProfile -Path $ProfilePath
    $recordFile = Read-V10StrictJsonFile -Path $CandidateRecordPath -Description 'v1 release candidate record'
    $record = $recordFile.Value
    Assert-V10ExactProperties -Object $record -Names @(
        'schemaVersion', 'reportKind', 'issue', 'evidenceClass', 'repository',
        'releaseVersion', 'releaseTag', 'packageVersion', 'sourceCommit',
        'workingTree', 'generatedAtUtc', 'profile', 'generation', 'components', 'documents', 'boundaries') -Description 'v1 release candidate record'
    if ([int]$record.schemaVersion -ne 1 -or [string]$record.reportKind -cne 'HerdrOps.ReleaseCandidate' -or
        [int]$record.issue -ne 45 -or [string]$record.evidenceClass -cne 'Static' -or
        [string]$record.repository -cne 'OSHEThai/HerdrOps' -or [string]$record.releaseVersion -cne 'v1.0.0' -or
        [string]$record.releaseTag -cne 'v1.0.0' -or [string]$record.packageVersion -cne '1.0.0' -or
        [string]$record.workingTree -cne 'CLEAN') {
        throw 'The v1 release candidate identity is not exact.'
    }
    $sourceCommit = [string]$record.sourceCommit
    Assert-V10Hex -Value $sourceCommit -Length 40 -Description 'candidate source commit' -Lowercase
    if (-not [string]::IsNullOrWhiteSpace($ExpectedSourceCommit) -and $sourceCommit -cne $ExpectedSourceCommit) {
        throw 'Candidate record source commit does not match the expected accepted commit.'
    }
    Assert-V10UtcTimestamp -Value ([string]$record.generatedAtUtc) -Description 'candidate generatedAtUtc'

    Assert-V10ExactProperties -Object $record.profile -Names @('path', 'length', 'sha256') -Description 'candidate profile record'
    $profileRelative = [string]$record.profile.path
    if ($profileRelative -cne $script:V10ReleaseProfileRelativePath.Replace('\', '/')) {
        throw 'Candidate record does not bind the canonical v1 release profile.'
    }
    $profileFull = Resolve-V10RepositoryFile -RelativePath $profileRelative -RepositoryRoot $RepositoryRoot -Description 'candidate profile'
    $profileInfo = Get-Item -LiteralPath $profileFull
    if ([string]$record.profile.length -cne [string][int64]$profileInfo.Length -or
        [string]$record.profile.sha256 -cne ((Get-FileHash -LiteralPath $profileFull -Algorithm SHA256).Hash).ToUpperInvariant()) {
        throw 'Candidate release profile bytes do not match the record.'
    }

    $generationRoot = Normalize-ComparablePath -Path (Split-Path -Path $recordFile.Path -Parent)
    $generation = Assert-PackagedGenerationCommitted -Profile $profile -GenerationRoot $generationRoot -ExpectedGenerationKind 'FullPackage'
    Assert-V10ExactProperties -Object $record.generation -Names @(
        'packageDirectory', 'archiveFile', 'archiveBytes', 'archiveSha256',
        'manifestFile', 'manifestBytes', 'manifestSha256', 'contentSha256',
        'hashRecordFile', 'hashRecordSha256', 'metadataFile', 'metadataSha256',
        'commitMarkerFile', 'commitMarkerSha256') -Description 'candidate generation record'
    $expectedGeneration = [ordered]@{
        packageDirectory = 'package'
        archiveFile = [IO.Path]::GetFileName([string]$generation.ArchivePath)
        archiveBytes = [string][int64]$generation.ArchiveBytes
        archiveSha256 = [string]$generation.ArchiveSha256
        manifestFile = 'package/package-manifest.json'
        manifestBytes = [string][int64]$generation.ManifestBytes
        manifestSha256 = [string]$generation.ManifestSha256
        contentSha256 = [string]$generation.ContentSha256
        hashRecordFile = [IO.Path]::GetFileName([string]$generation.HashRecordPath)
        hashRecordSha256 = ((Get-FileHash -LiteralPath ([string]$generation.HashRecordPath) -Algorithm SHA256).Hash).ToUpperInvariant()
        metadataFile = 'generation.metadata'
        metadataSha256 = ((Get-FileHash -LiteralPath ([string]$generation.MetadataPath) -Algorithm SHA256).Hash).ToUpperInvariant()
        commitMarkerFile = 'commit.marker'
        commitMarkerSha256 = ((Get-FileHash -LiteralPath ([string]$generation.CommitMarkerPath) -Algorithm SHA256).Hash).ToUpperInvariant()
    }
    foreach ($name in $expectedGeneration.Keys) {
        if ([string]$record.generation.$name -cne [string]$expectedGeneration[$name]) {
            throw "Candidate generation field '$name' does not match independently observed bytes."
        }
    }

    $components = @($record.components)
    if ($components.Count -ne @($profile.components).Count) {
        throw 'Candidate component record count is not exact.'
    }
    for ($index = 0; $index -lt $components.Count; $index++) {
        $component = $components[$index]
        $expectedComponent = @($profile.components)[$index]
        Assert-V10ExactProperties -Object $component -Names @('name', 'assemblyName', 'entryPoints') -Description "candidate component $index"
        if ([string]$component.name -cne [string]$expectedComponent.name -or
            [string]$component.assemblyName -cne [string]$expectedComponent.assemblyName) {
            throw "Candidate component identity has drifted at index $index."
        }
        $entryPoints = @($component.entryPoints)
        if ($entryPoints.Count -ne 2) {
            throw "Candidate component '$($component.name)' must bind its DLL and EXE."
        }
        foreach ($extensionIndex in 0..1) {
            $extension = @('dll', 'exe')[$extensionIndex]
            $expectedName = [string]$expectedComponent.assemblyName + '.' + $extension
            $entry = $entryPoints[$extensionIndex]
            Assert-V10ExactProperties -Object $entry -Names @('path', 'length', 'sha256') -Description "candidate entry point $expectedName"
            if ([string]$entry.path -cne $expectedName) {
                throw "Candidate entry-point order or identity is not exact: $expectedName"
            }
            $path = Join-Path ([string]$generation.PackageRoot) $expectedName
            $item = Get-Item -LiteralPath $path -Force
            if ([string]$entry.length -cne [string][int64]$item.Length -or
                [string]$entry.sha256 -cne ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash).ToUpperInvariant()) {
                throw "Candidate entry-point bytes do not match: $expectedName"
            }
        }
    }

    $documents = @($record.documents)
    if ($documents.Count -ne @($profile.releaseDocuments).Count) {
        throw 'Candidate release-document record count is not exact.'
    }
    for ($index = 0; $index -lt $documents.Count; $index++) {
        $document = $documents[$index]
        Assert-V10ExactProperties -Object $document -Names @('path', 'length', 'sha256') -Description "candidate release document $index"
        $expectedPath = ([string]@($profile.releaseDocuments)[$index]).Replace('\', '/')
        if ([string]$document.path -cne $expectedPath) {
            throw "Candidate release-document order or identity has drifted at index $index."
        }
        $full = Resolve-V10RepositoryFile -RelativePath $expectedPath -RepositoryRoot $RepositoryRoot -Description 'candidate release document'
        $item = Get-Item -LiteralPath $full
        if ([string]$document.length -cne [string][int64]$item.Length -or
            [string]$document.sha256 -cne ((Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash).ToUpperInvariant()) {
            throw "Candidate release-document bytes do not match: $expectedPath"
        }
    }

    Assert-V10ExactProperties -Object $record.boundaries -Names @(
        'static', 'synthetic', 'contract', 'cleanMachine', 'runtime',
        'independentReview', 'human', 'release') -Description 'candidate evidence boundaries'
    if ([string]$record.boundaries.static -cne 'PASS') {
        throw 'Candidate record must classify only its Static evidence as PASS.'
    }
    foreach ($name in @('synthetic', 'contract', 'cleanMachine', 'runtime', 'independentReview', 'human', 'release')) {
        if ([string]$record.boundaries.$name -cne 'NOT OBSERVED') {
            throw "Candidate record must keep evidence boundary '$name' as NOT OBSERVED."
        }
    }

    return [pscustomobject][ordered]@{
        RecordPath = $recordFile.Path
        RecordBytes = $recordFile.Length
        RecordSha256 = $recordFile.Sha256
        SourceCommit = $sourceCommit
        ArchivePath = $generation.ArchivePath
        ArchiveBytes = $generation.ArchiveBytes
        ArchiveSha256 = $generation.ArchiveSha256
        HashRecordPath = $generation.HashRecordPath
        Generation = $generation
        Record = $record
    }
}

function Assert-V10ClrStringValue {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string]$Description,
        [switch]$AllowEmpty
    )

    if ($null -eq $Value -or -not ($Value -is [string]) -or
        (-not $AllowEmpty -and [string]::IsNullOrWhiteSpace([string]$Value))) {
        throw "$Description must be a strict CLR string."
    }
}

function Assert-V10ClrBooleanValue {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string]$Description
    )

    if ($null -eq $Value -or -not ($Value -is [bool])) {
        throw "$Description must be a strict CLR Boolean."
    }
}

function Assert-V10ClrIntegerValue {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string]$Description,
        [long]$Minimum = [long]::MinValue
    )

    if ($null -eq $Value -or $Value -is [bool] -or
        -not ($Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or
            $Value -is [uint16] -or $Value -is [int32] -or $Value -is [uint32] -or
            $Value -is [int64] -or $Value -is [uint64]) -or
        [decimal]$Value -lt [decimal]$Minimum) {
        throw "$Description must be a strict CLR integer at least $Minimum."
    }
}

function Assert-V10ClrNumberValue {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string]$Description,
        [double]$Minimum = [double]::NegativeInfinity
    )

    if ($null -eq $Value -or $Value -is [bool] -or
        -not ($Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or
            $Value -is [uint16] -or $Value -is [int32] -or $Value -is [uint32] -or
            $Value -is [int64] -or $Value -is [uint64] -or $Value -is [single] -or
            $Value -is [double] -or $Value -is [decimal]) -or
        [double]$Value -lt $Minimum -or [double]::IsNaN([double]$Value) -or
        [double]::IsInfinity([double]$Value)) {
        throw "$Description must be a strict finite CLR number at least $Minimum."
    }
}

function Assert-V10ClrArrayValue {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string]$Description,
        [int]$MinimumCount = 0
    )

    if ($null -eq $Value -or -not ($Value -is [array]) -or $Value.Count -lt $MinimumCount) {
        throw "$Description must be a CLR array with at least $MinimumCount item(s)."
    }
}

function Get-V10Sha256TextUpper {
    param([Parameter(Mandatory = $true)][string]$Text)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        return (($sha.ComputeHash($utf8.GetBytes($Text)) | ForEach-Object { $_.ToString('x2') }) -join '').ToUpperInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Get-V10RelativeFileSha256 {
    param(
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $root = Get-V10RepositoryRoot
    $path = Resolve-V10RepositoryFile -RelativePath $RelativePath -RepositoryRoot $root -Description $Description
    return ((Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash).ToUpperInvariant()
}

function Assert-V10Issue41Sha256 {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string]$Description
    )

    Assert-V10ClrStringValue -Value $Value -Description $Description
    Assert-V10Hex -Value ([string]$Value) -Length 64 -Description $Description -Uppercase
    if ([string]$Value -ceq (('0' * 64) -join '')) {
        throw "$Description must not be an all-zero placeholder hash."
    }
}

function Assert-V10Issue42Boundaries {
    param(
        [Parameter(Mandatory = $true)]$Boundaries,
        [Parameter(Mandatory = $true)][bool]$RequireRuntime
    )

    Assert-V10ExactProperties -Object $Boundaries -Names @('static', 'synthetic', 'contract', 'runtime', 'release') -Description 'Issue #42 evidence boundaries'
    foreach ($name in @('static', 'synthetic', 'contract', 'runtime', 'release')) {
        Assert-V10ClrStringValue -Value $Boundaries.$name -Description "Issue #42 boundary '$name'"
    }
    if ([string]$Boundaries.static -notlike 'PASS*' -or [string]$Boundaries.contract -notlike 'PASS*') {
        throw 'Issue #42 static and contract boundaries must pass.'
    }
    if ($RequireRuntime) {
        if ([string]$Boundaries.synthetic -notlike 'NOT OBSERVED*' -or
            [string]$Boundaries.runtime -notlike 'PASS*' -or
            [string]$Boundaries.release -notlike 'NOT OBSERVED*') {
            throw 'Issue #42 Runtime acceptance has an invalid evidence boundary.'
        }
    } else {
        if ([string]$Boundaries.synthetic -notlike 'PASS*' -or
            [string]$Boundaries.runtime -notlike 'NOT OBSERVED*' -or
            [string]$Boundaries.release -notlike 'NOT OBSERVED*') {
            throw 'Synthetic Issue #42 evidence must not claim Runtime or Release.'
        }
    }
}

function Assert-V10Issue42ReportSemantics {
    param(
        [Parameter(Mandatory = $true)]$Report,
        [Parameter(Mandatory = $true)][string]$SourceCommit,
        [Parameter(Mandatory = $true)][string]$ArchiveSha256,
        [Parameter(Mandatory = $true)][long]$ArchiveBytes,
        [string]$ExpectedSourceTree,
        [string]$ExpectedParentCommit,
        [string]$ExpectedBranch,
        [switch]$RequireRuntime
    )

    Assert-V10ExactProperties -Object $Report -Names @(
        'schemaVersion', 'reportKind', 'issue', 'acceptanceVersion', 'status', 'evidenceClass',
        'sourceCommit', 'sourceTree', 'candidateCommit', 'directParentCommit', 'branch',
        'candidateHeadMatch', 'directParentMatch', 'candidateArchiveSha256', 'candidateArchiveBytes',
        'policySha256', 'contractSha256', 'fixtureSha256', 'gateReportPath', 'gateReportSha256',
        'provenanceSha256', 'durationHours', 'actualHerdrObserved', 'unhandledCrashes',
        'unreconciledStates', 'reconnectResult', 'faultInjectionResult', 'databaseIntegrityResult',
        'alertConsistencyResult', 'soakArtifact', 'boundaries', 'completedAtUtc') -Description 'Issue #42 canonical report'

    Assert-V10ClrIntegerValue -Value $Report.schemaVersion -Description 'Issue #42 schemaVersion' -Minimum 1
    Assert-V10ClrIntegerValue -Value $Report.issue -Description 'Issue #42 issue' -Minimum 42
    if ([int64]$Report.schemaVersion -ne 1 -or [int64]$Report.issue -ne 42) {
        throw 'Issue #42 canonical report identity is not exact.'
    }
    Assert-V10ClrStringValue -Value $Report.reportKind -Description 'Issue #42 reportKind'
    Assert-V10ClrStringValue -Value $Report.acceptanceVersion -Description 'Issue #42 acceptanceVersion'
    Assert-V10ClrStringValue -Value $Report.status -Description 'Issue #42 status'
    Assert-V10ClrStringValue -Value $Report.evidenceClass -Description 'Issue #42 evidenceClass'
    if ([string]$Report.reportKind -cne 'HerdrOps.V10SoakAcceptanceReport' -or
        [string]$Report.acceptanceVersion -cne 'v1.0.0' -or [string]$Report.status -cne 'PASS' -or
        ([bool]$RequireRuntime -and [string]$Report.evidenceClass -cne 'Runtime') -or
        (-not [bool]$RequireRuntime -and [string]$Report.evidenceClass -cne 'Synthetic')) {
        throw 'Issue #42 canonical report is not a permitted passing evidence shape.'
    }

    foreach ($name in @('sourceCommit', 'sourceTree', 'candidateCommit', 'directParentCommit')) {
        Assert-V10ClrStringValue -Value $Report.$name -Description "Issue #42 $name"
    }
    Assert-V10Hex -Value ([string]$Report.sourceCommit) -Length 40 -Description 'Issue #42 sourceCommit' -Lowercase
    Assert-V10Hex -Value ([string]$Report.sourceTree) -Length 40 -Description 'Issue #42 sourceTree' -Lowercase
    Assert-V10Hex -Value ([string]$Report.candidateCommit) -Length 40 -Description 'Issue #42 candidateCommit' -Lowercase
    Assert-V10Hex -Value ([string]$Report.directParentCommit) -Length 40 -Description 'Issue #42 directParentCommit' -Lowercase
    if ([string]$Report.sourceCommit -cne $SourceCommit -or [string]$Report.candidateCommit -cne $SourceCommit) {
        throw 'Issue #42 source/candidate commit binding is not exact.'
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedSourceTree) -and [string]$Report.sourceTree -cne $ExpectedSourceTree) {
        throw 'Issue #42 source tree binding does not match the accepted commit.'
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedParentCommit) -and [string]$Report.directParentCommit -cne $ExpectedParentCommit) {
        throw 'Issue #42 direct-parent binding does not match the accepted commit.'
    }
    Assert-V10ClrStringValue -Value $Report.branch -Description 'Issue #42 branch'
    if ([string]$Report.branch -match '[<>]' -or [string]$Report.branch -in @('PENDING', 'NOT ASSIGNED')) {
        throw 'Issue #42 branch binding is not concrete.'
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedBranch) -and [string]$Report.branch -cne $ExpectedBranch) {
        throw 'Issue #42 branch binding does not match the reviewed checkout.'
    }
    foreach ($name in @('candidateHeadMatch', 'directParentMatch')) {
        Assert-V10ClrStringValue -Value $Report.$name -Description "Issue #42 $name"
        if ([string]$Report.$name -cne 'PASS') {
            throw "Issue #42 $name must be PASS."
        }
    }

    Assert-V10ClrStringValue -Value $Report.candidateArchiveSha256 -Description 'Issue #42 candidateArchiveSha256'
    Assert-V10Hex -Value ([string]$Report.candidateArchiveSha256) -Length 64 -Description 'Issue #42 candidateArchiveSha256' -Uppercase
    if ([string]$Report.candidateArchiveSha256 -cne $ArchiveSha256) {
        throw 'Issue #42 candidate archive SHA-256 does not match the accepted candidate.'
    }
    Assert-V10ClrIntegerValue -Value $Report.candidateArchiveBytes -Description 'Issue #42 candidateArchiveBytes' -Minimum 1
    if ([int64]$Report.candidateArchiveBytes -ne $ArchiveBytes) {
        throw 'Issue #42 candidate archive byte count does not match the accepted candidate.'
    }

    foreach ($name in @('policySha256', 'contractSha256', 'fixtureSha256', 'gateReportSha256', 'provenanceSha256')) {
        Assert-V10ClrStringValue -Value $Report.$name -Description "Issue #42 $name"
        Assert-V10Hex -Value ([string]$Report.$name) -Length 64 -Description "Issue #42 $name" -Uppercase
        if ([string]$Report.$name -ceq (('0' * 64) -join '')) {
            throw "Issue #42 $name cannot be an all-zero placeholder."
        }
    }
    $expectedPolicy = Get-V10RelativeFileSha256 -RelativePath 'tools/SoakContractPolicy.ps1' -Description 'Issue #42 policy'
    $expectedContract = Get-V10RelativeFileSha256 -RelativePath 'docs/protocol/v1.0-issue-42-soak-fault-injection-contract.md' -Description 'Issue #42 contract'
    $expectedFixture = Get-V10RelativeFileSha256 -RelativePath 'tests/fixtures/v1.0/issue-42/soak-alert-consistency.json' -Description 'Issue #42 fixture'
    if ([string]$Report.policySha256 -cne $expectedPolicy -or
        [string]$Report.contractSha256 -cne $expectedContract -or
        [string]$Report.fixtureSha256 -cne $expectedFixture) {
        throw 'Issue #42 policy, contract, or fixture hash is not bound to the committed bytes.'
    }

    Assert-V10ClrStringValue -Value $Report.gateReportPath -Description 'Issue #42 gateReportPath'
    $gatePath = Resolve-V10RepositoryFile -RelativePath ([string]$Report.gateReportPath) -RepositoryRoot (Get-V10RepositoryRoot) -Description 'Issue #42 gate report'
    $gateHash = ((Get-FileHash -LiteralPath $gatePath -Algorithm SHA256 -ErrorAction Stop).Hash).ToUpperInvariant()
    if ($gateHash -cne [string]$Report.gateReportSha256) {
        throw 'Issue #42 gate-report hash does not match its exact bytes.'
    }
    $gateText = [IO.File]::ReadAllText($gatePath)
    foreach ($marker in @(
        'Issue: #42',
        "SourceCommit: $($Report.sourceCommit)",
        "Branch: $($Report.branch)",
        "CandidateArchiveSha256: $($Report.candidateArchiveSha256)",
        "PolicySha256: $($Report.policySha256)",
        "ContractSha256: $($Report.contractSha256)",
        "FixtureSha256: $($Report.fixtureSha256)")) {
        if ($gateText.IndexOf($marker, [StringComparison]::Ordinal) -lt 0) {
            throw "Issue #42 gate report is missing canonical marker: $marker"
        }
    }
    $provenanceState = ''
    foreach ($item in @(
        [pscustomobject]@{ Name = 'policy'; Sha256 = [string]$Report.policySha256 },
        [pscustomobject]@{ Name = 'contract'; Sha256 = [string]$Report.contractSha256 },
        [pscustomobject]@{ Name = 'fixture'; Sha256 = [string]$Report.fixtureSha256 },
        [pscustomobject]@{ Name = 'gate-report'; Sha256 = [string]$Report.gateReportSha256 })) {
        $provenanceState = Get-V10Sha256TextUpper -Text ($provenanceState + '|' + $item.Name + '|' + $item.Sha256)
    }
    if ([string]$Report.provenanceSha256 -cne $provenanceState) {
        throw 'Issue #42 provenance root does not match the ordered policy/contract/fixture/gate chain.'
    }

    Assert-V10ClrNumberValue -Value $Report.durationHours -Description 'Issue #42 24-hour durationHours' -Minimum 24.0
    Assert-V10ClrBooleanValue -Value $Report.actualHerdrObserved -Description 'Issue #42 actualHerdrObserved'
    if (-not [bool]$Report.actualHerdrObserved) {
        throw 'Issue #42 actualHerdrObserved must be true for Runtime acceptance.'
    }
    foreach ($name in @('unhandledCrashes', 'unreconciledStates')) {
        Assert-V10ClrIntegerValue -Value $Report.$name -Description "Issue #42 $name" -Minimum 0
        if ([int64]$Report.$name -ne 0) { throw "Issue #42 $name must be zero." }
    }
    foreach ($name in @('reconnectResult', 'faultInjectionResult', 'databaseIntegrityResult', 'alertConsistencyResult')) {
        Assert-V10ClrStringValue -Value $Report.$name -Description "Issue #42 $name"
        if ([string]$Report.$name -cne 'PASS') { throw "Issue #42 $name must be PASS." }
    }

    $soak = $Report.soakArtifact
    Assert-V10ExactProperties -Object $soak -Names @(
        'SchemaVersion', 'ArtifactKind', 'RunId', 'Mode', 'MeasurementRunId',
        'MeasurementArtifactSha256', 'Candidate', 'Soak', 'InstalledHerdr', 'Producer',
        'Provenance', 'Limits', 'Artifacts') -Description 'Issue #42 soakArtifact'
    foreach ($name in @('SchemaVersion', 'ArtifactKind', 'RunId', 'Mode', 'MeasurementRunId', 'MeasurementArtifactSha256')) {
        Assert-V10ClrStringValue -Value $soak.$name -Description "Issue #42 soakArtifact.$name"
    }
    if ([string]$soak.SchemaVersion -cne 'v0.7.0-soak' -or [string]$soak.ArtifactKind -cne 'SoakRun' -or
        [string]$soak.Mode -cne 'Live') {
        throw 'Issue #42 soak artifact identity or Live mode is not exact.'
    }
    Assert-V10Hex -Value ([string]$soak.MeasurementArtifactSha256) -Length 64 -Description 'Issue #42 measurement artifact SHA-256' -Uppercase

    Assert-V10ExactProperties -Object $soak.Candidate -Names @('SourceCommit', 'SourceTree', 'GitTreeClean') -Description 'Issue #42 soak candidate'
    Assert-V10ClrStringValue -Value $soak.Candidate.SourceCommit -Description 'Issue #42 soak candidate SourceCommit'
    Assert-V10ClrStringValue -Value $soak.Candidate.SourceTree -Description 'Issue #42 soak candidate SourceTree'
    Assert-V10ClrBooleanValue -Value $soak.Candidate.GitTreeClean -Description 'Issue #42 soak candidate GitTreeClean'
    Assert-V10Hex -Value ([string]$soak.Candidate.SourceCommit) -Length 40 -Description 'Issue #42 soak candidate SourceCommit' -Lowercase
    Assert-V10Hex -Value ([string]$soak.Candidate.SourceTree) -Length 40 -Description 'Issue #42 soak candidate SourceTree' -Lowercase
    if ([string]$soak.Candidate.SourceCommit -cne [string]$Report.sourceCommit -or
        [string]$soak.Candidate.SourceTree -cne [string]$Report.sourceTree -or
        -not [bool]$soak.Candidate.GitTreeClean) {
        throw 'Issue #42 soak candidate identity is not bound to the report source.'
    }

    Assert-V10ExactProperties -Object $soak.Soak -Names @(
        'DurationHours', 'UnhandledCrashes', 'UnreconciledStateCount', 'UnboundedTerminalReads',
        'RuntimeObservationFailures', 'ObservedReconnects') -Description 'Issue #42 soak measurements'
    Assert-V10ClrNumberValue -Value $soak.Soak.DurationHours -Description 'Issue #42 soak DurationHours' -Minimum 24.0
    if ([double]$soak.Soak.DurationHours -ne [double]$Report.durationHours) { throw 'Issue #42 report and soak duration differ.' }
    foreach ($name in @('UnhandledCrashes', 'UnreconciledStateCount', 'UnboundedTerminalReads', 'RuntimeObservationFailures')) {
        Assert-V10ClrIntegerValue -Value $soak.Soak.$name -Description "Issue #42 soak $name" -Minimum 0
        if ([int64]$soak.Soak.$name -ne 0) { throw "Issue #42 soak $name must be zero." }
    }
    Assert-V10ClrIntegerValue -Value $soak.Soak.ObservedReconnects -Description 'Issue #42 soak ObservedReconnects' -Minimum 1

    Assert-V10ExactProperties -Object $soak.InstalledHerdr -Names @('ProductId', 'ExecutablePath', 'ExecutableSha256', 'ReleaseId', 'PackageRoot', 'PackageIdentitySha256') -Description 'Issue #42 InstalledHerdr'
    if ([string]$soak.InstalledHerdr.ProductId -cne 'Herdr') { throw 'Issue #42 installed product identity is not Herdr.' }
    foreach ($name in @('ExecutablePath', 'ReleaseId', 'PackageRoot')) { Assert-V10ClrStringValue -Value $soak.InstalledHerdr.$name -Description "Issue #42 InstalledHerdr.$name" }
    foreach ($name in @('ExecutableSha256', 'PackageIdentitySha256')) { Assert-V10ClrStringValue -Value $soak.InstalledHerdr.$name -Description "Issue #42 InstalledHerdr.$name"; Assert-V10Hex -Value ([string]$soak.InstalledHerdr.$name) -Length 64 -Description "Issue #42 InstalledHerdr.$name" -Uppercase }

    Assert-V10ExactProperties -Object $soak.Producer -Names @('Tool', 'Version', 'SessionControlInvoked', 'ObserverMode', 'ObserverExecutableSha256', 'ObserverReportSha256', 'ScheduleContextSha256') -Description 'Issue #42 soak Producer'
    foreach ($name in @('Tool', 'Version', 'ObserverMode')) { Assert-V10ClrStringValue -Value $soak.Producer.$name -Description "Issue #42 soak Producer.$name" }
    Assert-V10ClrBooleanValue -Value $soak.Producer.SessionControlInvoked -Description 'Issue #42 soak Producer.SessionControlInvoked'
    if ([string]$soak.Producer.Tool -cne 'Invoke-V07ActualHerdrSoak.ps1' -or [string]$soak.Producer.Version -cne '2' -or
        [bool]$soak.Producer.SessionControlInvoked -or [string]$soak.Producer.ObserverMode -cne 'ReadOnlyAttached') {
        throw 'Issue #42 soak producer identity or session-control boundary is not exact.'
    }
    foreach ($name in @('ObserverExecutableSha256', 'ObserverReportSha256', 'ScheduleContextSha256')) { Assert-V10ClrStringValue -Value $soak.Producer.$name -Description "Issue #42 soak Producer.$name"; Assert-V10Hex -Value ([string]$soak.Producer.$name) -Length 64 -Description "Issue #42 soak Producer.$name" -Uppercase }

    Assert-V10ExactProperties -Object $soak.Provenance -Names @('HeartbeatIntervalSeconds', 'ExpectedHeartbeatCount', 'MissingHeartbeatCount', 'HeartbeatChainHeadSha256', 'ObservationCount', 'FaultObservationChainHeadSha256') -Description 'Issue #42 soak Provenance'
    Assert-V10ClrIntegerValue -Value $soak.Provenance.HeartbeatIntervalSeconds -Description 'Issue #42 heartbeat interval' -Minimum 1
    Assert-V10ClrIntegerValue -Value $soak.Provenance.ExpectedHeartbeatCount -Description 'Issue #42 expected heartbeat count' -Minimum 1
    Assert-V10ClrIntegerValue -Value $soak.Provenance.MissingHeartbeatCount -Description 'Issue #42 missing heartbeat count' -Minimum 0
    if ([int64]$soak.Provenance.MissingHeartbeatCount -ne 0) { throw 'Issue #42 missing heartbeat count must be zero.' }
    Assert-V10ClrIntegerValue -Value $soak.Provenance.ObservationCount -Description 'Issue #42 fault observation count' -Minimum 1
    foreach ($name in @('HeartbeatChainHeadSha256', 'FaultObservationChainHeadSha256')) { Assert-V10ClrStringValue -Value $soak.Provenance.$name -Description "Issue #42 provenance $name"; Assert-V10Hex -Value ([string]$soak.Provenance.$name) -Length 64 -Description "Issue #42 provenance $name" -Uppercase }

    Assert-V10ExactProperties -Object $soak.Limits -Names @('MaxArtifactBytes', 'MaxHeartbeatEntries', 'MaxFaultObservations', 'MaxResourceSamples', 'MaxManifestEntries') -Description 'Issue #42 soak Limits'
    foreach ($name in @('MaxArtifactBytes', 'MaxHeartbeatEntries', 'MaxFaultObservations', 'MaxResourceSamples', 'MaxManifestEntries')) { Assert-V10ClrIntegerValue -Value $soak.Limits.$name -Description "Issue #42 soak limit $name" -Minimum 1 }
    if ([int64]$soak.Limits.MaxArtifactBytes -gt 4194304 -or [int64]$soak.Limits.MaxHeartbeatEntries -gt 10000 -or
        [int64]$soak.Limits.MaxFaultObservations -gt 64 -or [int64]$soak.Limits.MaxResourceSamples -gt 10000 -or
        [int64]$soak.Limits.MaxManifestEntries -gt 32) {
        throw 'Issue #42 soak limits exceed the producer policy bounds.'
    }
    Assert-V10ClrArrayValue -Value $soak.Artifacts -Description 'Issue #42 soak Artifacts' -MinimumCount 1
    $artifactNames = @{}
    foreach ($artifact in @($soak.Artifacts)) {
        Assert-V10ExactProperties -Object $artifact -Names @('Name', 'LengthBytes', 'Sha256', 'Lines', 'Entries') -Description 'Issue #42 soak artifact manifest entry'
        Assert-V10ClrStringValue -Value $artifact.Name -Description 'Issue #42 artifact Name'
        if ($artifactNames.ContainsKey([string]$artifact.Name)) { throw "Issue #42 artifact manifest contains duplicate name: $($artifact.Name)" }
        $artifactNames[[string]$artifact.Name] = $true
        foreach ($name in @('LengthBytes', 'Lines', 'Entries')) { Assert-V10ClrIntegerValue -Value $artifact.$name -Description "Issue #42 artifact $name" -Minimum 0 }
        Assert-V10ClrStringValue -Value $artifact.Sha256 -Description 'Issue #42 artifact Sha256'
        Assert-V10Hex -Value ([string]$artifact.Sha256) -Length 64 -Description 'Issue #42 artifact Sha256' -Uppercase
    }

    Assert-V10Issue42Boundaries -Boundaries $Report.boundaries -RequireRuntime ([bool]$RequireRuntime)
    Assert-V10ClrStringValue -Value $Report.completedAtUtc -Description 'Issue #42 completedAtUtc'
    Assert-V10UtcTimestamp -Value ([string]$Report.completedAtUtc) -Description 'Issue #42 completedAtUtc'
}

function Assert-V10Issue43Boundaries {
    param([Parameter(Mandatory = $true)]$Boundaries)

    Assert-V10ExactProperties -Object $Boundaries -Names @('static', 'synthetic', 'contract', 'cleanMachine', 'runtime', 'independentReview', 'human', 'release') -Description 'Issue #43 evidence boundaries'
    foreach ($name in @('static', 'synthetic', 'contract', 'cleanMachine', 'runtime', 'independentReview', 'human', 'release')) {
        Assert-V10ClrStringValue -Value $Boundaries.$name -Description "Issue #43 boundary '$name'"
    }
    if ([string]$Boundaries.static -notlike 'PASS*' -or
        [string]$Boundaries.synthetic -notlike 'PASS*' -or
        [string]$Boundaries.contract -notlike 'PASS*' -or
        [string]$Boundaries.cleanMachine -notlike 'NOT OBSERVED*' -or
        [string]$Boundaries.runtime -notlike 'NOT OBSERVED*' -or
        [string]$Boundaries.independentReview -notlike 'PASS*' -or
        [string]$Boundaries.human -notlike 'NOT OBSERVED*' -or
        [string]$Boundaries.release -notlike 'NOT OBSERVED*') {
        throw 'Issue #43 evidence boundaries do not preserve the independent-review boundary.'
    }
}

function Assert-V10Issue43ReportSemantics {
    param(
        [Parameter(Mandatory = $true)]$Report,
        [Parameter(Mandatory = $true)][string]$SourceCommit,
        [Parameter(Mandatory = $true)][string]$ArchiveSha256,
        [Parameter(Mandatory = $true)][long]$ArchiveBytes,
        [string]$ExpectedSourceTree,
        [string]$ExpectedParentCommit,
        [string]$ExpectedBranch
    )

    Assert-V10ExactProperties -Object $Report -Names @(
        'schemaVersion', 'reportKind', 'issue', 'reviewVersion', 'status', 'evidenceClass',
        'sourceCommit', 'sourceTree', 'candidateCommit', 'directParentCommit', 'branch',
        'candidateHeadMatch', 'directParentMatch', 'candidateArchiveSha256', 'candidateArchiveBytes',
        'reviewedManifestPath', 'reviewedManifestSha256', 'schemaMigrationReportPath',
        'schemaMigrationReportSha256', 'gateReportPath', 'gateReportSha256', 'provenanceSha256',
        'verdict', 'unresolvedHighFindings', 'reviewer', 'checks', 'boundaries', 'completedAtUtc') -Description 'Issue #43 canonical report'

    Assert-V10ClrIntegerValue -Value $Report.schemaVersion -Description 'Issue #43 schemaVersion' -Minimum 1
    Assert-V10ClrIntegerValue -Value $Report.issue -Description 'Issue #43 issue' -Minimum 43
    if ([int64]$Report.schemaVersion -ne 1 -or [int64]$Report.issue -ne 43) { throw 'Issue #43 canonical report identity is not exact.' }
    foreach ($name in @('reportKind', 'reviewVersion', 'status', 'evidenceClass', 'verdict')) { Assert-V10ClrStringValue -Value $Report.$name -Description "Issue #43 $name" }
    if ([string]$Report.reportKind -cne 'HerdrOps.V10SecurityPrivacyReviewReport' -or
        [string]$Report.reviewVersion -cne 'v1.0.0' -or [string]$Report.status -cne 'PASS' -or
        [string]$Report.evidenceClass -cne 'IndependentReview' -or [string]$Report.verdict -cne 'PASS') {
        throw 'Issue #43 canonical report is not a passing independent-review shape.'
    }

    foreach ($name in @('sourceCommit', 'sourceTree', 'candidateCommit', 'directParentCommit')) { Assert-V10ClrStringValue -Value $Report.$name -Description "Issue #43 $name" }
    Assert-V10Hex -Value ([string]$Report.sourceCommit) -Length 40 -Description 'Issue #43 sourceCommit' -Lowercase
    Assert-V10Hex -Value ([string]$Report.sourceTree) -Length 40 -Description 'Issue #43 sourceTree' -Lowercase
    Assert-V10Hex -Value ([string]$Report.candidateCommit) -Length 40 -Description 'Issue #43 candidateCommit' -Lowercase
    Assert-V10Hex -Value ([string]$Report.directParentCommit) -Length 40 -Description 'Issue #43 directParentCommit' -Lowercase
    if ([string]$Report.sourceCommit -cne $SourceCommit -or [string]$Report.candidateCommit -cne $SourceCommit) { throw 'Issue #43 source/candidate commit binding is not exact.' }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedSourceTree) -and [string]$Report.sourceTree -cne $ExpectedSourceTree) { throw 'Issue #43 source tree binding does not match the accepted commit.' }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedParentCommit) -and [string]$Report.directParentCommit -cne $ExpectedParentCommit) { throw 'Issue #43 direct-parent binding does not match the accepted commit.' }
    Assert-V10ClrStringValue -Value $Report.branch -Description 'Issue #43 branch'
    if ([string]$Report.branch -match '[<>]' -or [string]$Report.branch -in @('PENDING', 'NOT ASSIGNED')) { throw 'Issue #43 branch binding is not concrete.' }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedBranch) -and [string]$Report.branch -cne $ExpectedBranch) { throw 'Issue #43 branch binding does not match the reviewed checkout.' }
    foreach ($name in @('candidateHeadMatch', 'directParentMatch')) { Assert-V10ClrStringValue -Value $Report.$name -Description "Issue #43 $name"; if ([string]$Report.$name -cne 'PASS') { throw "Issue #43 $name must be PASS." } }

    Assert-V10ClrStringValue -Value $Report.candidateArchiveSha256 -Description 'Issue #43 candidateArchiveSha256'
    Assert-V10Hex -Value ([string]$Report.candidateArchiveSha256) -Length 64 -Description 'Issue #43 candidateArchiveSha256' -Uppercase
    if ([string]$Report.candidateArchiveSha256 -cne $ArchiveSha256) { throw 'Issue #43 candidate archive SHA-256 does not match the accepted candidate.' }
    Assert-V10ClrIntegerValue -Value $Report.candidateArchiveBytes -Description 'Issue #43 candidateArchiveBytes' -Minimum 1
    if ([int64]$Report.candidateArchiveBytes -ne $ArchiveBytes) { throw 'Issue #43 candidate archive byte count does not match the accepted candidate.' }

    foreach ($name in @('reviewedManifestSha256', 'schemaMigrationReportSha256', 'gateReportSha256', 'provenanceSha256')) {
        Assert-V10ClrStringValue -Value $Report.$name -Description "Issue #43 $name"
        Assert-V10Hex -Value ([string]$Report.$name) -Length 64 -Description "Issue #43 $name" -Uppercase
        if ([string]$Report.$name -ceq (('0' * 64) -join '')) { throw "Issue #43 $name cannot be an all-zero placeholder." }
    }
    $root = Get-V10RepositoryRoot
    $manifestPath = Resolve-V10RepositoryFile -RelativePath ([string]$Report.reviewedManifestPath) -RepositoryRoot $root -Description 'Issue #43 reviewed manifest'
    $schemaPath = Resolve-V10RepositoryFile -RelativePath ([string]$Report.schemaMigrationReportPath) -RepositoryRoot $root -Description 'Issue #43 schema migration report'
    $gatePath = Resolve-V10RepositoryFile -RelativePath ([string]$Report.gateReportPath) -RepositoryRoot $root -Description 'Issue #43 gate report'
    $manifestHash = ((Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256 -ErrorAction Stop).Hash).ToUpperInvariant()
    $schemaHash = ((Get-FileHash -LiteralPath $schemaPath -Algorithm SHA256 -ErrorAction Stop).Hash).ToUpperInvariant()
    $gateHash = ((Get-FileHash -LiteralPath $gatePath -Algorithm SHA256 -ErrorAction Stop).Hash).ToUpperInvariant()
    if ($manifestHash -cne [string]$Report.reviewedManifestSha256 -or $schemaHash -cne [string]$Report.schemaMigrationReportSha256 -or $gateHash -cne [string]$Report.gateReportSha256) {
        throw 'Issue #43 reviewed manifest, schema migration, or gate hash does not match exact bytes.'
    }
    $manifestText = [IO.File]::ReadAllText($manifestPath)
    foreach ($marker in @(
        'Issue: #43', 'Version: v1.0.0', "CandidateCommit: $($Report.candidateCommit)",
        "DirectParentCommit: $($Report.directParentCommit)", "CandidateHeadMatch: $($Report.candidateHeadMatch)",
        "DirectParentMatch: $($Report.directParentMatch)", "Branch: $($Report.branch)", 'ReviewedFiles:')) {
        if ($manifestText.IndexOf($marker, [StringComparison]::Ordinal) -lt 0) { throw "Issue #43 reviewed manifest is missing canonical marker: $marker" }
    }
    $schemaText = [IO.File]::ReadAllText($schemaPath)
    foreach ($marker in @(
        'SchemaVersion: v4',
        'MigrationGraph: v1 initial-state-store -> v2 assignment-lifecycle-provenance -> v3 evidence-metadata-review-retention-audit -> v4 role-distinct-compliance-review-workflow',
        "SourceCommit: $($Report.sourceCommit)", "CandidateCommit: $($Report.candidateCommit)",
        "DirectParentCommit: $($Report.directParentCommit)", "Branch: $($Report.branch)",
        "ReviewedManifestSha256: $($Report.reviewedManifestSha256)")) {
        if ($schemaText.IndexOf($marker, [StringComparison]::Ordinal) -lt 0) { throw "Issue #43 schema migration report is missing canonical marker: $marker" }
    }
    $gateText = [IO.File]::ReadAllText($gatePath)
    foreach ($marker in @(
        'Issue: #43', "SourceCommit: $($Report.sourceCommit)", "CandidateCommit: $($Report.candidateCommit)",
        "DirectParentCommit: $($Report.directParentCommit)", "Branch: $($Report.branch)",
        "ReviewedManifestSha256: $($Report.reviewedManifestSha256)",
        "SchemaMigrationReportSha256: $($Report.schemaMigrationReportSha256)")) {
        if ($gateText.IndexOf($marker, [StringComparison]::Ordinal) -lt 0) { throw "Issue #43 gate report is missing canonical marker: $marker" }
    }
    $provenance = ''
    foreach ($item in @(
        [pscustomobject]@{ Name = 'reviewed-manifest'; Sha256 = [string]$Report.reviewedManifestSha256 },
        [pscustomobject]@{ Name = 'schema-migration-report'; Sha256 = [string]$Report.schemaMigrationReportSha256 },
        [pscustomobject]@{ Name = 'gate-report'; Sha256 = [string]$Report.gateReportSha256 })) {
        $provenance = Get-V10Sha256TextUpper -Text ($provenance + '|' + $item.Name + '|' + $item.Sha256)
    }
    if ([string]$Report.provenanceSha256 -cne $provenance) { throw 'Issue #43 provenance root does not match the ordered review artifact chain.' }

    Assert-V10ExactProperties -Object $Report.reviewer -Names @('name', 'role') -Description 'Issue #43 reviewer'
    foreach ($name in @('name', 'role')) { Assert-V10ClrStringValue -Value $Report.reviewer.$name -Description "Issue #43 reviewer.$name" }
    if ([string]$Report.reviewer.name -match '[<>]' -or [string]$Report.reviewer.role -match '[<>]' -or
        [string]$Report.reviewer.name -in @('PENDING', 'NOT ASSIGNED') -or [string]$Report.reviewer.role -in @('PENDING', 'NOT ASSIGNED')) {
        throw 'Issue #43 reviewer identity must be concrete and role-distinct.'
    }
    Assert-V10ClrIntegerValue -Value $Report.unresolvedHighFindings -Description 'Issue #43 unresolvedHighFindings' -Minimum 0
    if ([int64]$Report.unresolvedHighFindings -ne 0) { throw 'Issue #43 unresolvedHighFindings must be zero.' }

    Assert-V10ClrArrayValue -Value $Report.checks -Description 'Issue #43 checks' -MinimumCount 18
    $expectedChecks = [ordered]@{
        'S-01' = 'Static'; 'S-02' = 'Static'; 'S-03' = 'Static'; 'S-04' = 'Static'; 'S-05' = 'Static';
        'S-06' = 'Contract'; 'S-07' = 'Static'; 'S-08' = 'Static'; 'S-09' = 'Static'; 'S-10' = 'Static'; 'S-11' = 'Static';
        'C-01' = 'Contract'; 'C-02' = 'Contract'; 'C-03' = 'Synthetic'; 'C-04' = 'LocalSQLiteIntegration';
        'C-05' = 'LocalSQLiteIntegration'; 'C-06' = 'LocalSQLiteIntegration'; 'C-07' = 'Synthetic'
    }
    if (@($Report.checks).Count -ne $expectedChecks.Count) { throw 'Issue #43 checks must contain the complete canonical S/C inventory exactly once.' }
    $checkIndex = 0
    foreach ($expectedId in @($expectedChecks.Keys)) {
        $check = @($Report.checks)[$checkIndex]
        Assert-V10ExactProperties -Object $check -Names @('id', 'status', 'evidenceClass', 'detail') -Description "Issue #43 check $expectedId"
        foreach ($name in @('id', 'status', 'evidenceClass', 'detail')) { Assert-V10ClrStringValue -Value $check.$name -Description "Issue #43 check $expectedId $name" }
        if ([string]$check.id -cne $expectedId -or [string]$check.status -cne 'PASS' -or [string]$check.evidenceClass -cne [string]$expectedChecks[$expectedId]) {
            throw "Issue #43 check $expectedId is missing, duplicated, reordered, or has the wrong evidence class."
        }
        $checkIndex++
    }
    Assert-V10Issue43Boundaries -Boundaries $Report.boundaries
    Assert-V10ClrStringValue -Value $Report.completedAtUtc -Description 'Issue #43 completedAtUtc'
    Assert-V10UtcTimestamp -Value ([string]$Report.completedAtUtc) -Description 'Issue #43 completedAtUtc'
}

function Assert-V10Issue40Handoff {
    param(
        [Parameter(Mandatory = $true)]$Handoff,
        [Parameter(Mandatory = $true)][string]$SourceCommit,
        [Parameter(Mandatory = $true)][string]$SourceTree,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot
    )

    Assert-V10ExactProperties -Object $Handoff -Names @(
        'ReportPath', 'ReportBytes', 'ReportSha256', 'HumanUatPath', 'HumanUatBytes', 'HumanUatSha256') -Description 'Issue #40 handoff'
    foreach ($name in @('ReportPath', 'HumanUatPath')) {
        Assert-V10ClrStringValue -Value $Handoff.$name -Description "Issue #40 handoff.$name"
        Assert-V10SafeRelativePathText -Path ([string]$Handoff.$name) -Description "Issue #40 handoff.$name"
    }
    foreach ($name in @('ReportBytes', 'HumanUatBytes')) {
        Assert-V10ClrIntegerValue -Value $Handoff.$name -Description "Issue #40 handoff.$name" -Minimum 1
    }
    Assert-V10Issue41Sha256 -Value $Handoff.ReportSha256 -Description 'Issue #40 handoff.ReportSha256'
    Assert-V10Issue41Sha256 -Value $Handoff.HumanUatSha256 -Description 'Issue #40 handoff.HumanUatSha256'

    $reportPath = Resolve-V10RepositoryFile -RelativePath ([string]$Handoff.ReportPath) -RepositoryRoot $RepositoryRoot -Description 'Issue #40 release-gate report'
    $humanPath = Resolve-V10RepositoryFile -RelativePath ([string]$Handoff.HumanUatPath) -RepositoryRoot $RepositoryRoot -Description 'Issue #40 human UAT record'
    if ([IO.Path]::GetFullPath($reportPath).Equals([IO.Path]::GetFullPath($humanPath), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Issue #40 release-gate report and human UAT record must be separate files.'
    }
    foreach ($item in @(
            [pscustomobject]@{ Name = 'report'; Path = $reportPath; Bytes = $Handoff.ReportBytes; Sha256 = $Handoff.ReportSha256 },
            [pscustomobject]@{ Name = 'human UAT'; Path = $humanPath; Bytes = $Handoff.HumanUatBytes; Sha256 = $Handoff.HumanUatSha256 })) {
        $file = Get-Item -LiteralPath $item.Path -Force
        if ([int64]$file.Length -ne [int64]$item.Bytes) {
            throw "Issue #40 $($item.Name) byte count does not match the handoff: $($item.Path)"
        }
        $observedHash = ((Get-FileHash -LiteralPath $item.Path -Algorithm SHA256 -ErrorAction Stop).Hash).ToUpperInvariant()
        if ($observedHash -cne [string]$item.Sha256) {
            throw "Issue #40 $($item.Name) SHA-256 does not match the handoff: $($item.Path)"
        }
    }

    $currentCandidate = [pscustomobject][ordered]@{
        Commit = $SourceCommit
        Tree = $SourceTree
        WorkingTree = 'CLEAN'
        Status = @()
    }
    $reportFile = Read-V10StrictJsonFile -Path $reportPath -Description 'Issue #40 release-gate report'
    Assert-V07ReleaseGateExactProperties -Object $reportFile.Value -Names @(
        'schemaVersion', 'reportKind', 'issue', 'status', 'generatedAtUtc', 'candidate', 'input',
        'dependencyEvidence', 'checks', 'humanUat', 'historyPolicy', 'evidenceBoundary', 'publication') -Description 'Issue #40 release-gate report'
    $issue40Report = $reportFile.Value
    if ((Assert-V07ReleaseGateInteger -Value (Get-V07ReleaseGateProperty -Object $issue40Report -Name 'schemaVersion' -Description 'Issue #40 release-gate report') -Description 'Issue #40 report.schemaVersion' -Minimum 1 -Maximum 1) -ne 1 -or
        (Get-V07ReleaseGateProperty -Object $issue40Report -Name 'reportKind' -Description 'Issue #40 release-gate report') -cne 'HerdrOps.V07ReleaseGateReport' -or
        (Assert-V07ReleaseGateInteger -Value (Get-V07ReleaseGateProperty -Object $issue40Report -Name 'issue' -Description 'Issue #40 release-gate report') -Description 'Issue #40 report.issue' -Minimum 40 -Maximum 40) -ne 40 -or
        (Get-V07ReleaseGateProperty -Object $issue40Report -Name 'status' -Description 'Issue #40 release-gate report') -cne 'PENDING') {
        throw 'Issue #40 handoff requires the canonical automation-generated PENDING report.'
    }
    Assert-V07ReleaseGateUtcTimestamp -Value (Get-V07ReleaseGateProperty -Object $issue40Report -Name 'generatedAtUtc' -Description 'Issue #40 release-gate report') -Description 'Issue #40 report.generatedAtUtc'
    Assert-V07ReleaseGateCandidateObject `
        -Candidate (Get-V07ReleaseGateProperty -Object $issue40Report -Name 'candidate' -Description 'Issue #40 release-gate report') `
        -Description 'Issue #40 report.candidate' `
        -CurrentCandidate $currentCandidate

    $reportInput = Get-V07ReleaseGateProperty -Object $issue40Report -Name 'input' -Description 'Issue #40 release-gate report'
    Assert-V07ReleaseGateExactProperties -Object $reportInput -Names @('path', 'sha256') -Description 'Issue #40 report.input'
    $inputPathText = Get-V07ReleaseGateProperty -Object $reportInput -Name 'path' -Description 'Issue #40 report.input'
    Assert-V07ReleaseGateString -Value $inputPathText -Description 'Issue #40 report.input.path'
    $inputSha = Get-V07ReleaseGateProperty -Object $reportInput -Name 'sha256' -Description 'Issue #40 report.input'
    Assert-V07ReleaseGateHex -Value $inputSha -Length 64 -Description 'Issue #40 report.input.sha256' -Case Upper
    $inputPath = if ([IO.Path]::IsPathRooted([string]$inputPathText)) {
        [IO.Path]::GetFullPath([string]$inputPathText)
    } else {
        [IO.Path]::GetFullPath((Join-Path (Split-Path -Path $reportPath -Parent) ([string]$inputPathText)))
    }
    $evidenceRoot = [IO.Path]::GetFullPath((Split-Path -Path $reportPath -Parent))
    if (-not (Test-PathWithin -ChildPath $inputPath -RootPath $evidenceRoot)) {
        throw 'Issue #40 report.input.path escaped the report evidence root.'
    }
    Assert-V07ReleaseGateNoReparseComponents -Path $inputPath -Root $evidenceRoot
    $inputFile = Get-Item -LiteralPath $inputPath -Force
    $observedInputSha = ((Get-FileHash -LiteralPath $inputPath -Algorithm SHA256 -ErrorAction Stop).Hash).ToUpperInvariant()
    if ($observedInputSha -cne [string]$inputSha) {
        throw 'Issue #40 report.input.sha256 does not match the exact input bytes.'
    }
    $validatedInput = Test-V07ReleaseGateInput -InputPath $inputPath -EvidenceRoot $evidenceRoot -CurrentCandidate $currentCandidate
    if ([string]$validatedInput.InputSha256 -cne [string]$inputSha -or [int64]$inputFile.Length -le 0) {
        throw 'Issue #40 canonical input validation did not preserve the bound input identity.'
    }

    $dependencyEvidence = Get-V07ReleaseGateProperty -Object $issue40Report -Name 'dependencyEvidence' -Description 'Issue #40 release-gate report'
    if ($dependencyEvidence -isnot [array] -or @($dependencyEvidence).Count -ne 5) {
        throw 'Issue #40 report must contain exactly five dependency-evidence entries for #35-#39.'
    }
    $seenDependencyIssues = [Collections.Generic.HashSet[int]]::new()
    foreach ($dependency in @($dependencyEvidence)) {
        Assert-V07ReleaseGateExactProperties -Object $dependency -Names @('issue', 'status', 'evidenceClass', 'manifestPath', 'manifestSha256', 'evidenceCount') -Description 'Issue #40 report dependencyEvidence entry'
        $issue = Assert-V07ReleaseGateInteger -Value (Get-V07ReleaseGateProperty -Object $dependency -Name 'issue' -Description 'Issue #40 report dependencyEvidence') -Description 'Issue #40 report dependencyEvidence.issue' -Minimum 35 -Maximum 39
        if (-not $seenDependencyIssues.Add([int]$issue)) {
            throw "Issue #40 report contains a duplicate dependency-evidence issue: #$issue"
        }
        Assert-V07ReleaseGateString -Value (Get-V07ReleaseGateProperty -Object $dependency -Name 'status' -Description 'Issue #40 report dependencyEvidence') -Description 'Issue #40 report dependencyEvidence.status' -AllowPending
        Assert-V07ReleaseGateString -Value (Get-V07ReleaseGateProperty -Object $dependency -Name 'evidenceClass' -Description 'Issue #40 report dependencyEvidence') -Description 'Issue #40 report dependencyEvidence.evidenceClass'
        Assert-V07ReleaseGateString -Value (Get-V07ReleaseGateProperty -Object $dependency -Name 'manifestPath' -Description 'Issue #40 report dependencyEvidence') -Description 'Issue #40 report dependencyEvidence.manifestPath'
        Assert-V07ReleaseGateHex -Value (Get-V07ReleaseGateProperty -Object $dependency -Name 'manifestSha256' -Description 'Issue #40 report dependencyEvidence') -Length 64 -Description 'Issue #40 report dependencyEvidence.manifestSha256' -Case Upper
        $validatedDependency = @($validatedInput.Dependencies | Where-Object { [int]$_.Issue -eq [int]$issue })
        if ($validatedDependency.Count -ne 1 -or [string]$dependency.status -cne [string]$validatedDependency[0].Status -or
            [string]$dependency.manifestPath -cne [string]$validatedDependency[0].ManifestPath -or
            [string]$dependency.manifestSha256 -cne [string]$validatedDependency[0].ManifestSha256) {
            throw "Issue #40 report dependencyEvidence is not bound to canonical #$issue validation."
        }
        Assert-V07ReleaseGateInteger -Value (Get-V07ReleaseGateProperty -Object $dependency -Name 'evidenceCount' -Description 'Issue #40 report dependencyEvidence') -Description 'Issue #40 report dependencyEvidence.evidenceCount' -Minimum 1 | Out-Null
    }
    foreach ($issue in @(35, 36, 37, 38, 39)) {
        if (-not $seenDependencyIssues.Contains($issue)) {
            throw "Issue #40 report is missing dependency-evidence issue #$issue."
        }
    }

    $checks = Get-V07ReleaseGateProperty -Object $issue40Report -Name 'checks' -Description 'Issue #40 release-gate report'
    Assert-V07ReleaseGateExactProperties -Object $checks -Names @(
        'candidateCommitAndTree', 'cleanCheckout', 'dependencyManifests', 'dependencyHashes',
        'strictJsonAndBounds', 'containmentAndReparse', 'duplicateAndUnknownFieldRejection', 'humanUat') -Description 'Issue #40 report.checks'
    foreach ($name in @('candidateCommitAndTree', 'cleanCheckout', 'dependencyManifests', 'dependencyHashes', 'strictJsonAndBounds', 'containmentAndReparse', 'duplicateAndUnknownFieldRejection')) {
        if ((Get-V07ReleaseGateProperty -Object $checks -Name $name -Description 'Issue #40 report.checks') -cne 'PASS') {
            throw "Issue #40 report.checks.$name must be PASS."
        }
    }
    $humanCheck = [string](Get-V07ReleaseGateProperty -Object $checks -Name 'humanUat' -Description 'Issue #40 report.checks')
    if ($humanCheck -notin @('VALIDATED_INPUT / PENDING', 'PENDING / NOT PROVIDED')) {
        throw 'Issue #40 report.checks.humanUat must preserve the automation PENDING boundary.'
    }

    $reportHuman = Get-V07ReleaseGateProperty -Object $issue40Report -Name 'humanUat' -Description 'Issue #40 release-gate report'
    Assert-V07ReleaseGateExactProperties -Object $reportHuman -Names @('decision', 'signer', 'role', 'signedAtUtc', 'signature') -Description 'Issue #40 report.humanUat'
    foreach ($name in @('decision', 'signer', 'role', 'signedAtUtc', 'signature')) {
        if ((Get-V07ReleaseGateProperty -Object $reportHuman -Name $name -Description 'Issue #40 report.humanUat') -cne 'PENDING') {
            throw 'Issue #40 report.humanUat must remain entirely PENDING; automation cannot forge approval.'
        }
    }
    Assert-V07ReleaseGateHistoryPolicy -HistoryPolicy (Get-V07ReleaseGateProperty -Object $issue40Report -Name 'historyPolicy' -Description 'Issue #40 release-gate report')

    $boundary = Get-V07ReleaseGateProperty -Object $issue40Report -Name 'evidenceBoundary' -Description 'Issue #40 release-gate report'
    Assert-V07ReleaseGateExactProperties -Object $boundary -Names @('static', 'synthetic', 'contract', 'runtime', 'human', 'release') -Description 'Issue #40 report.evidenceBoundary'
    foreach ($name in @('static', 'synthetic', 'contract', 'runtime', 'human', 'release')) {
        $boundaryValue = Get-V07ReleaseGateProperty -Object $boundary -Name $name -Description 'Issue #40 report.evidenceBoundary'
        if ($name -ceq 'human') {
            Assert-V07ReleaseGateString -Value $boundaryValue -Description "Issue #40 report.evidenceBoundary.$name" -AllowPending
        } else {
            Assert-V07ReleaseGateString -Value $boundaryValue -Description "Issue #40 report.evidenceBoundary.$name"
        }
    }
    if ([string]$boundary.runtime -notlike 'NOT OBSERVED*' -or [string]$boundary.release -notlike 'NOT OBSERVED*' -or
        [string]$boundary.human -notlike 'PENDING*') {
        throw 'Issue #40 report evidence boundaries contain a forged Runtime, Human, or Release claim.'
    }

    $publication = Get-V07ReleaseGateProperty -Object $issue40Report -Name 'publication' -Description 'Issue #40 release-gate report'
    Assert-V07ReleaseGateExactProperties -Object $publication -Names @('status', 'tag', 'release') -Description 'Issue #40 report.publication'
    if ([string]$publication.status -cne 'PENDING' -or [string]$publication.tag -cne 'NOT CREATED' -or [string]$publication.release -cne 'NOT PUBLISHED') {
        throw 'Issue #40 report publication boundary is not fail-closed.'
    }

    $humanFile = Read-V10StrictJsonFile -Path $humanPath -Description 'Issue #40 human UAT record'
    $humanValidation = Read-V07ReleaseGateHumanUat -Path $humanPath -EvidenceRoot $evidenceRoot -CurrentCandidate $currentCandidate
    if ([string]$humanValidation.Data.Decision -cne 'ACCEPTED' -or
        [string]$humanFile.Sha256 -cne [string]$Handoff.HumanUatSha256 -or
        [int64]$humanFile.Length -ne [int64]$Handoff.HumanUatBytes) {
        throw 'Issue #40 handoff requires a separately hashed, accepted human UAT record.'
    }

    return [pscustomobject][ordered]@{
        ReportPath = $reportPath
        ReportBytes = [int64]$reportFile.Length
        ReportSha256 = [string]$reportFile.Sha256
        HumanUatPath = $humanPath
        HumanUatBytes = [int64]$humanFile.Length
        HumanUatSha256 = [string]$humanFile.Sha256
        InputPath = $inputPath
        InputSha256 = [string]$validatedInput.InputSha256
        HumanDecision = [string]$humanValidation.Data.Decision
    }
}

function Assert-V10Issue41ReportSemantics {
    param(
        [Parameter(Mandatory = $true)]$Report,
        [Parameter(Mandatory = $true)][string]$SourceCommit,
        [Parameter(Mandatory = $true)][string]$ExpectedSourceTree,
        [string]$RepositoryRoot = (Get-V10RepositoryRoot),
        [switch]$RequireReady
    )

    Assert-V10ExactProperties -Object $Report -Names @(
        'SchemaVersion', 'AuditId', 'TargetIssue', 'GeneratedUtc', 'SourceCommit', 'SourceTree', 'WorkingTree',
        'Query', 'PlanTruth', 'Decision', 'ReleaseCandidate', 'EvidenceStatus', 'EvidenceManifest',
        'DependencyMap', 'Blockers', 'EvidenceBoundary', 'Issue40Handoff') -Description 'Issue #41 canonical report'

    Assert-V10ClrIntegerValue -Value $Report.SchemaVersion -Description 'Issue #41 SchemaVersion' -Minimum 1
    if ([int64]$Report.SchemaVersion -ne 1) {
        throw 'Issue #41 SchemaVersion must be exactly 1.'
    }
    Assert-V10ClrStringValue -Value $Report.AuditId -Description 'Issue #41 AuditId'
    Assert-V10ClrStringValue -Value $Report.SourceCommit -Description 'Issue #41 SourceCommit'
    Assert-V10Hex -Value ([string]$Report.SourceCommit) -Length 40 -Description 'Issue #41 SourceCommit' -Lowercase
    if ([string]$Report.AuditId -cne 'V100-01' -or [string]$Report.SourceCommit -cne $SourceCommit) {
        throw 'Issue #41 report identity is not bound to the accepted source commit.'
    }
    Assert-V10ClrStringValue -Value $Report.SourceTree -Description 'Issue #41 SourceTree'
    Assert-V10Hex -Value ([string]$Report.SourceTree) -Length 40 -Description 'Issue #41 SourceTree' -Lowercase
    Assert-V10Hex -Value $ExpectedSourceTree -Length 40 -Description 'Issue #41 expected SourceTree' -Lowercase
    if ([string]$Report.SourceTree -cne $ExpectedSourceTree) {
        throw 'Issue #41 SourceTree does not match the accepted candidate tree.'
    }
    Assert-V10ClrStringValue -Value $Report.GeneratedUtc -Description 'Issue #41 GeneratedUtc'
    Assert-V10UtcTimestamp -Value ([string]$Report.GeneratedUtc) -Description 'Issue #41 GeneratedUtc'
    Assert-V10ClrStringValue -Value $Report.WorkingTree -Description 'Issue #41 WorkingTree'
    if ([string]$Report.WorkingTree -cne 'CLEAN') {
        throw 'Issue #41 report must bind a CLEAN working tree.'
    }

    $target = $Report.TargetIssue
    Assert-V10ExactProperties -Object $target -Names @('Number', 'Title', 'Version', 'MilestoneNumber', 'State', 'Url') -Description 'Issue #41 TargetIssue'
    Assert-V10ClrIntegerValue -Value $target.Number -Description 'Issue #41 TargetIssue.Number' -Minimum 41
    Assert-V10ClrStringValue -Value $target.Title -Description 'Issue #41 TargetIssue.Title'
    Assert-V10ClrStringValue -Value $target.Version -Description 'Issue #41 TargetIssue.Version'
    Assert-V10ClrIntegerValue -Value $target.MilestoneNumber -Description 'Issue #41 TargetIssue.MilestoneNumber' -Minimum 1
    Assert-V10ClrStringValue -Value $target.State -Description 'Issue #41 TargetIssue.State'
    Assert-V10ClrStringValue -Value $target.Url -Description 'Issue #41 TargetIssue.Url'
    if ([int64]$target.Number -ne 41 -or
        [string]$target.Title -cne '[v1.0.0] Close release blockers and audit all dependency evidence' -or
        [string]$target.Version -cne 'v1.0.0' -or [int64]$target.MilestoneNumber -ne 8 -or
        [string]::IsNullOrWhiteSpace([string]$target.Url)) {
        throw 'Issue #41 TargetIssue is not the exact v1.0.0 issue #41 record.'
    }
    if ([string]$target.State -cnotin @('OPEN', 'CLOSED')) {
        throw 'Issue #41 TargetIssue.State must be OPEN or CLOSED.'
    }

    $query = $Report.Query
    Assert-V10ExactProperties -Object $query -Names @('Source', 'FixturePath', 'FixtureSha256', 'Endpoint', 'ResponseSha256') -Description 'Issue #41 Query'
    foreach ($name in @('Source', 'FixturePath', 'FixtureSha256')) {
        Assert-V10ClrStringValue -Value $query.$name -Description "Issue #41 Query.$name" -AllowEmpty
    }
    if ([string]$query.Source -eq 'GitHub gh api (read-only)') {
        Assert-V10ClrArrayValue -Value $query.Endpoint -Description 'Issue #41 Query.Endpoint' -MinimumCount 2
        Assert-V10ClrArrayValue -Value $query.ResponseSha256 -Description 'Issue #41 Query.ResponseSha256' -MinimumCount 2
        if (@($query.Endpoint).Count -ne @($query.ResponseSha256).Count) {
            throw 'Issue #41 Query endpoint and response-hash inventories must have equal counts.'
        }
        $seenEndpoints = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        for ($index = 0; $index -lt @($query.Endpoint).Count; $index++) {
            Assert-V10ClrStringValue -Value $query.Endpoint[$index] -Description "Issue #41 Query.Endpoint[$index]"
            Assert-V10Issue41Sha256 -Value $query.ResponseSha256[$index] -Description "Issue #41 Query.ResponseSha256[$index]"
            if (-not $seenEndpoints.Add([string]$query.Endpoint[$index])) {
                throw "Issue #41 Query contains a duplicate page endpoint: $($query.Endpoint[$index])"
            }
            if ([string]$query.Endpoint[$index] -notlike 'repos/OSHEThai/HerdrOps/*') {
                throw "Issue #41 Query endpoint is not bound to OSHEThai/HerdrOps: $($query.Endpoint[$index])"
            }
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$query.FixturePath) -or
            -not [string]::IsNullOrWhiteSpace([string]$query.FixtureSha256)) {
            throw 'GitHub-backed Issue #41 queries must not carry offline fixture identity.'
        }
    } elseif ([string]$query.Source -eq 'OfflineFixture') {
        Assert-V10Issue41Sha256 -Value $query.FixtureSha256 -Description 'Issue #41 Query.FixtureSha256'
        Assert-V10ClrStringValue -Value $query.FixturePath -Description 'Issue #41 Query.FixturePath'
        Assert-V10ClrStringValue -Value $query.Endpoint -Description 'Issue #41 Query.Endpoint'
        Assert-V10Issue41Sha256 -Value $query.ResponseSha256 -Description 'Issue #41 Query.ResponseSha256'
    } else {
        throw "Issue #41 Query.Source is unsupported: $($query.Source)"
    }

    $plan = $Report.PlanTruth
    Assert-V10ExactProperties -Object $plan -Names @('Files', 'Hashes', 'ReleaseGatesTextSha256') -Description 'Issue #41 PlanTruth'
    Assert-V10ExactProperties -Object $plan.Files -Names @('Roadmap', 'Tracking', 'ReleaseGates') -Description 'Issue #41 PlanTruth.Files'
    Assert-V10ExactProperties -Object $plan.Hashes -Names @('Plan/github-roadmap.json', 'Plan/GITHUB-TRACKING.md', 'Plan/RELEASE-GATES.md') -Description 'Issue #41 PlanTruth.Hashes'
    $planPaths = [ordered]@{
        Roadmap = 'Plan/github-roadmap.json'
        Tracking = 'Plan/GITHUB-TRACKING.md'
        ReleaseGates = 'Plan/RELEASE-GATES.md'
    }
    foreach ($name in $planPaths.Keys) {
        Assert-V10ClrStringValue -Value $plan.Files.$name -Description "Issue #41 PlanTruth.Files.$name"
        if ([string]$plan.Files.$name -cne $planPaths[$name]) {
            throw "Issue #41 PlanTruth.Files.$name is not canonical."
        }
        $hash = $plan.Hashes.($planPaths[$name])
        Assert-V10Issue41Sha256 -Value $hash -Description "Issue #41 PlanTruth.Hashes.$($planPaths[$name])"
        $observedHash = Get-V10RelativeFileSha256 -RelativePath $planPaths[$name] -Description "Issue #41 PlanTruth file $($planPaths[$name])"
        if ([string]$hash -cne $observedHash) {
            throw "Issue #41 PlanTruth hash does not match committed bytes: $($planPaths[$name])"
        }
    }
    Assert-V10Issue41Sha256 -Value $plan.ReleaseGatesTextSha256 -Description 'Issue #41 PlanTruth.ReleaseGatesTextSha256'
    $releaseGatesText = [IO.File]::ReadAllText((Resolve-V10RepositoryFile -RelativePath 'Plan/RELEASE-GATES.md' -RepositoryRoot $RepositoryRoot -Description 'Issue #41 release-gates Plan truth'))
    if ([string]$plan.ReleaseGatesTextSha256 -cne (Get-V10Sha256TextUpper -Text $releaseGatesText)) {
        throw 'Issue #41 PlanTruth.ReleaseGatesTextSha256 does not match the committed text.'
    }

    $candidate = $Report.ReleaseCandidate
    Assert-V10ExactProperties -Object $candidate -Names @('Status', 'Commit', 'Reason') -Description 'Issue #41 ReleaseCandidate'
    Assert-V10ClrStringValue -Value $candidate.Status -Description 'Issue #41 ReleaseCandidate.Status'
    Assert-V10ClrStringValue -Value $candidate.Commit -Description 'Issue #41 ReleaseCandidate.Commit' -AllowEmpty
    Assert-V10ClrStringValue -Value $candidate.Reason -Description 'Issue #41 ReleaseCandidate.Reason'
    if ([string]$candidate.Status -notin @('RECORDED', 'NOT_RECORDED')) {
        throw 'Issue #41 ReleaseCandidate.Status must be RECORDED or NOT_RECORDED.'
    }
    if ([string]$candidate.Status -eq 'RECORDED') {
        Assert-V10Hex -Value ([string]$candidate.Commit) -Length 40 -Description 'Issue #41 ReleaseCandidate.Commit' -Lowercase
        if ([string]$candidate.Commit -cne $SourceCommit) {
            throw 'Issue #41 ReleaseCandidate.Commit does not match SourceCommit.'
        }
    } elseif (-not [string]::IsNullOrWhiteSpace([string]$candidate.Commit)) {
        throw 'An unrecorded Issue #41 release candidate must not carry a commit identity.'
    }

    $classes = @('Static', 'Synthetic', 'Contract', 'Integration', 'Runtime', 'Independent', 'Human', 'Release')
    $versions = @('v0.1.0', 'v0.2.0', 'v0.3.0', 'v0.4.0', 'v0.5.0', 'v0.6.0', 'v0.7.0')
    Assert-V10ExactProperties -Object $Report.EvidenceStatus -Names $classes -Description 'Issue #41 EvidenceStatus'
    foreach ($className in $classes) {
        $status = $Report.EvidenceStatus.$className
        Assert-V10ExactProperties -Object $status -Names @('Status', 'RequiredByVersions', 'ObservedVersions', 'NotObservedVersions') -Description "Issue #41 EvidenceStatus.$className"
        Assert-V10ClrStringValue -Value $status.Status -Description "Issue #41 EvidenceStatus.$className.Status"
        if ([string]$status.Status -notin @('PASS', 'NOT_OBSERVED', 'BLOCKED', 'FAIL', 'NOT_APPLICABLE')) {
            throw "Issue #41 EvidenceStatus.$className.Status is invalid."
        }
        foreach ($arrayName in @('RequiredByVersions', 'ObservedVersions', 'NotObservedVersions')) {
            Assert-V10ClrArrayValue -Value $status.$arrayName -Description "Issue #41 EvidenceStatus.$className.$arrayName"
            $seenVersions = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            foreach ($version in @($status.$arrayName)) {
                Assert-V10ClrStringValue -Value $version -Description "Issue #41 EvidenceStatus.$className.$arrayName entry"
                if ($versions -notcontains [string]$version -or -not $seenVersions.Add([string]$version)) {
                    throw "Issue #41 EvidenceStatus.$className.$arrayName contains an invalid or duplicate version."
                }
            }
        }
        $required = @($status.RequiredByVersions)
        $observed = @($status.ObservedVersions)
        $notObserved = @($status.NotObservedVersions)
        if (@($observed | Where-Object { $notObserved -contains $_ }).Count -ne 0) {
            throw "Issue #41 EvidenceStatus.$className overlaps observed and not-observed versions."
        }
        if ([string]$status.Status -eq 'PASS' -and ($notObserved.Count -ne 0 -or $observed.Count -ne $required.Count)) {
            throw "Issue #41 EvidenceStatus.$className PASS is incomplete."
        }
        if ([string]$status.Status -eq 'NOT_APPLICABLE' -and ($required.Count -ne 0 -or $observed.Count -ne 0 -or $notObserved.Count -ne 0)) {
            throw "Issue #41 EvidenceStatus.$className NOT_APPLICABLE has an inventory."
        }
    }

    $manifest = $Report.EvidenceManifest
    Assert-V10ExactProperties -Object $manifest -Names @('Source', 'Path', 'Sha256', 'EntryCount') -Description 'Issue #41 EvidenceManifest'
    foreach ($name in @('Source', 'Path', 'Sha256')) {
        Assert-V10ClrStringValue -Value $manifest.$name -Description "Issue #41 EvidenceManifest.$name" -AllowEmpty
    }
    Assert-V10ClrIntegerValue -Value $manifest.EntryCount -Description 'Issue #41 EvidenceManifest.EntryCount' -Minimum 0
    if ([string]$manifest.Source -eq 'EvidenceManifest') {
        if ([int64]$manifest.EntryCount -lt 7 -or [string]::IsNullOrWhiteSpace([string]$manifest.Path)) {
            throw 'Issue #41 EvidenceManifest must identify the complete v0.1-v0.7 manifest.'
        }
        Assert-V10Issue41Sha256 -Value $manifest.Sha256 -Description 'Issue #41 EvidenceManifest.Sha256'
    } elseif ([string]$manifest.Source -eq 'No manifest; no evidence admitted') {
        if ([int64]$manifest.EntryCount -ne 0 -or -not [string]::IsNullOrWhiteSpace([string]$manifest.Path) -or
            -not [string]::IsNullOrWhiteSpace([string]$manifest.Sha256)) {
            throw 'Issue #41 empty EvidenceManifest identity is inconsistent.'
        }
    } else {
        throw "Issue #41 EvidenceManifest.Source is unsupported: $($manifest.Source)"
    }

    [void](Assert-V10Issue40Handoff `
        -Handoff $Report.Issue40Handoff `
        -SourceCommit $SourceCommit `
        -SourceTree $ExpectedSourceTree `
        -RepositoryRoot $RepositoryRoot)

    $map = $Report.DependencyMap
    Assert-V10ClrArrayValue -Value $map -Description 'Issue #41 DependencyMap' -MinimumCount 7
    $seenMapKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $seenIssueNumbers = [Collections.Generic.HashSet[int]]::new()
    $seenVersions = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($entry in @($map)) {
        Assert-V10ExactProperties -Object $entry -Names @(
            'Version', 'MilestoneNumber', 'MilestoneTitle', 'IssueNumber', 'Title', 'State', 'IsReleaseTracker',
            'RoadmapKey', 'RoadmapMapping', 'ReleaseTrackerIssue', 'ReleaseTrackerUrl', 'LocalReleaseTracker',
            'LocalGatePlan', 'LocalGateVerifier', 'LocalGateScripts', 'GitHubUrl') -Description 'Issue #41 DependencyMap entry'
        Assert-V10ClrStringValue -Value $entry.Version -Description 'Issue #41 DependencyMap.Version'
        Assert-V10ClrIntegerValue -Value $entry.MilestoneNumber -Description 'Issue #41 DependencyMap.MilestoneNumber' -Minimum 1
        Assert-V10ClrStringValue -Value $entry.MilestoneTitle -Description 'Issue #41 DependencyMap.MilestoneTitle'
        Assert-V10ClrIntegerValue -Value $entry.IssueNumber -Description 'Issue #41 DependencyMap.IssueNumber' -Minimum 1
        Assert-V10ClrStringValue -Value $entry.Title -Description 'Issue #41 DependencyMap.Title'
        Assert-V10ClrStringValue -Value $entry.State -Description 'Issue #41 DependencyMap.State'
        Assert-V10ClrBooleanValue -Value $entry.IsReleaseTracker -Description 'Issue #41 DependencyMap.IsReleaseTracker'
        Assert-V10ClrStringValue -Value $entry.RoadmapKey -Description 'Issue #41 DependencyMap.RoadmapKey' -AllowEmpty
        Assert-V10ClrStringValue -Value $entry.RoadmapMapping -Description 'Issue #41 DependencyMap.RoadmapMapping'
        Assert-V10ClrIntegerValue -Value $entry.ReleaseTrackerIssue -Description 'Issue #41 DependencyMap.ReleaseTrackerIssue' -Minimum 1
        foreach ($name in @('ReleaseTrackerUrl', 'LocalReleaseTracker', 'LocalGatePlan', 'LocalGateVerifier', 'GitHubUrl')) {
            Assert-V10ClrStringValue -Value $entry.$name -Description "Issue #41 DependencyMap.$name"
        }
        Assert-V10ClrArrayValue -Value $entry.LocalGateScripts -Description 'Issue #41 DependencyMap.LocalGateScripts' -MinimumCount 1
        foreach ($path in @($entry.LocalGateScripts)) {
            Assert-V10ClrStringValue -Value $path -Description 'Issue #41 DependencyMap.LocalGateScripts entry'
            Assert-V10SafeRelativePathText -Path ([string]$path) -Description 'Issue #41 DependencyMap.LocalGateScripts entry'
            [void](Resolve-V10RepositoryFile -RelativePath ([string]$path) -RepositoryRoot $RepositoryRoot -Description 'Issue #41 local gate script')
        }
        if ($versions -notcontains [string]$entry.Version -or
            -not $seenMapKeys.Add("$($entry.Version)|$($entry.IssueNumber)") -or
            -not $seenIssueNumbers.Add([int]$entry.IssueNumber)) {
            throw 'Issue #41 DependencyMap contains an invalid or duplicate dependency record.'
        }
        [void]$seenVersions.Add([string]$entry.Version)
        if ([string]$entry.State -cnotin @('OPEN', 'CLOSED', 'UNKNOWN')) {
            throw 'Issue #41 DependencyMap.State is invalid.'
        }
        if ([string]$entry.LocalReleaseTracker -cne 'Plan/GITHUB-TRACKING.md' -or
            [string]$entry.LocalGatePlan -cne 'Plan/RELEASE-GATES.md' -or
            [string]$entry.LocalGateVerifier -cne 'tools/Test-VersionMilestone.ps1') {
            throw 'Issue #41 DependencyMap local gate bindings are not canonical.'
        }
    }
    foreach ($version in $versions) {
        if (-not $seenVersions.Contains($version)) {
            throw "Issue #41 DependencyMap is missing complete version inventory: $version"
        }
    }
    $issue40 = @($map | Where-Object { [int]$_.IssueNumber -eq 40 })
    if ($issue40.Count -ne 1 -or [string]$issue40[0].Version -cne 'v0.7.0' -or -not [bool]$issue40[0].IsReleaseTracker -or
        [int]$issue40[0].ReleaseTrackerIssue -ne 40) {
        throw 'Issue #41 DependencyMap must contain exactly one v0.7.0 Issue #40 release-tracker record.'
    }

    $blockers = $Report.Blockers
    Assert-V10ClrArrayValue -Value $blockers -Description 'Issue #41 Blockers'
    $seenBlockers = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($blocker in @($blockers)) {
        Assert-V10ExactProperties -Object $blocker -Names @('Code', 'Version', 'IssueNumber', 'Detail') -Description 'Issue #41 blocker'
        foreach ($name in @('Code', 'Version', 'Detail')) {
            Assert-V10ClrStringValue -Value $blocker.$name -Description "Issue #41 blocker.$name" -AllowEmpty
        }
        Assert-V10ClrIntegerValue -Value $blocker.IssueNumber -Description 'Issue #41 blocker.IssueNumber' -Minimum 0
        if (-not $seenBlockers.Add("$($blocker.Code)|$($blocker.Version)|$($blocker.IssueNumber)|$($blocker.Detail)")) {
            throw 'Issue #41 Blockers contains a duplicate record.'
        }
    }

    $boundaries = $Report.EvidenceBoundary
    Assert-V10ExactProperties -Object $boundaries -Names @(
        'RuntimeTestsProject', 'ActualHerdrRuntime', 'RegistryAppDataLiveDatabase', 'ReleaseCandidateFreeze',
        'PackagePublication', 'ReleasePublication', 'HumanAcceptance') -Description 'Issue #41 EvidenceBoundary'
    foreach ($name in @('RuntimeTestsProject', 'ActualHerdrRuntime', 'RegistryAppDataLiveDatabase', 'ReleaseCandidateFreeze', 'PackagePublication', 'ReleasePublication', 'HumanAcceptance')) {
        Assert-V10ClrStringValue -Value $boundaries.$name -Description "Issue #41 EvidenceBoundary.$name"
    }
    if ([string]$boundaries.RuntimeTestsProject -notlike '*Synthetic*' -or
        [string]$boundaries.ActualHerdrRuntime -notlike 'NOT OBSERVED*' -or
        [string]$boundaries.RegistryAppDataLiveDatabase -notlike 'NOT OBSERVED*' -or
        [string]$boundaries.PackagePublication -cne 'NOT PERFORMED' -or
        [string]$boundaries.ReleasePublication -cne 'NOT PERFORMED') {
        throw 'Issue #41 EvidenceBoundary contains a forged Runtime or Release claim.'
    }

    Assert-V10ClrStringValue -Value $Report.Decision -Description 'Issue #41 Decision'
    if ([string]$Report.Decision -notin @('READY', 'NOT_READY')) {
        throw 'Issue #41 Decision must be READY or NOT_READY.'
    }
    if ([string]$Report.Decision -eq 'READY') {
        if (@($blockers).Count -ne 0 -or [string]$candidate.Status -cne 'RECORDED' -or
            [string]$boundaries.ReleaseCandidateFreeze -cne 'RECORDED' -or
            [string]$boundaries.HumanAcceptance -notlike 'OBSERVED_IN_INPUT*') {
            throw 'Issue #41 READY decision has unresolved blockers or missing human-boundary evidence.'
        }
        if ([string]$query.Source -ne 'GitHub gh api (read-only)') {
            throw 'An offline Issue #41 audit cannot be READY.'
        }
        foreach ($className in $classes) {
            if ([string]$Report.EvidenceStatus.$className.Status -notin @('PASS', 'NOT_APPLICABLE')) {
                throw "Issue #41 READY decision has non-passing $className evidence."
            }
        }
    } elseif ([string]$candidate.Status -ne 'NOT_RECORDED' -or @($blockers).Count -eq 0 -or
        [string]$boundaries.ReleaseCandidateFreeze -cne 'NOT RECORDED') {
        throw 'Issue #41 NOT_READY decision must preserve blockers and an unfrozen candidate.'
    }

    return [pscustomobject][ordered]@{
        Status = [string]$Report.Decision
        SourceCommit = [string]$Report.SourceCommit
        WorkingTree = [string]$Report.WorkingTree
        DependencyCount = @($map).Count
        BlockerCount = @($blockers).Count
        Runtime = 'NOT OBSERVED'
        Release = 'NOT OBSERVED'
    }
}

function Assert-V10GateReport {
    param(
        [Parameter(Mandatory = $true)][int]$Issue,
        [Parameter(Mandatory = $true)][string]$EvidenceClass,
        [Parameter(Mandatory = $true)]$Report,
        [Parameter(Mandatory = $true)][string]$SourceCommit,
        [Parameter(Mandatory = $true)][string]$ArchiveSha256,
        [long]$ArchiveBytes = 0,
        [string]$ExpectedSourceTree,
        [string]$ExpectedParentCommit,
        [string]$ExpectedBranch,
        [string]$ManifestSha256,
        [string]$ContentSha256
    )

    $value = $Report.Value
    switch ($Issue) {
        41 {
            Assert-V10Issue41ReportSemantics -Report $value -SourceCommit $SourceCommit -ExpectedSourceTree $ExpectedSourceTree -RequireReady | Out-Null
        }
        42 {
            Assert-V10Issue42ReportSemantics `
                -Report $value `
                -SourceCommit $SourceCommit `
                -ArchiveSha256 $ArchiveSha256 `
                -ArchiveBytes $ArchiveBytes `
                -ExpectedSourceTree $ExpectedSourceTree `
                -ExpectedParentCommit $ExpectedParentCommit `
                -ExpectedBranch $ExpectedBranch `
                -RequireRuntime
        }
        43 {
            Assert-V10Issue43ReportSemantics `
                -Report $value `
                -SourceCommit $SourceCommit `
                -ArchiveSha256 $ArchiveSha256 `
                -ArchiveBytes $ArchiveBytes `
                -ExpectedSourceTree $ExpectedSourceTree `
                -ExpectedParentCommit $ExpectedParentCommit `
                -ExpectedBranch $ExpectedBranch
        }
        44 {
            Assert-V10Issue44ReportSemantics `
                -Report $value `
                -SourceCommit $SourceCommit `
                -ArchiveSha256 $ArchiveSha256 `
                -ManifestSha256 $ManifestSha256 `
                -ContentSha256 $ContentSha256 `
                -RequireLiveCleanMachine
        }
        default { throw "Unsupported v1 release gate issue: $Issue" }
    }
    if ($EvidenceClass -cne @{ 41 = 'ReleaseAudit'; 42 = 'Runtime'; 43 = 'IndependentReview'; 44 = 'CleanMachine' }[$Issue]) {
        throw "Issue #$Issue evidence class is not exact: $EvidenceClass"
    }
}

function Assert-V10ReleaseAuthorization {
    param(
        [Parameter(Mandatory = $true)][string]$AuthorizationPath,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [string]$ExpectedSourceCommit,
        [string]$ProfilePath = (Join-Path $PSScriptRoot 'v1.0-package-profile.json')
    )

    $authorizationFullPath = Normalize-ComparablePath -Path $AuthorizationPath
    $repositoryFullPath = Normalize-ComparablePath -Path $RepositoryRoot
    if (-not (Test-PathWithin -ChildPath $authorizationFullPath -RootPath $repositoryFullPath) -or
        $authorizationFullPath.Equals($repositoryFullPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The v1 release authorization must remain inside the authorized repository.'
    }
    Assert-V10NoReparseComponents -Path $authorizationFullPath -Root $repositoryFullPath
    $authorizationFile = Read-V10StrictJsonFile -Path $authorizationFullPath -Description 'v1 release authorization'
    $authorization = $authorizationFile.Value
    Assert-V10ExactProperties -Object $authorization -Names @(
        'schemaVersion', 'reportKind', 'issue', 'repository', 'releaseVersion',
        'releaseTag', 'acceptedCommit', 'candidateRecord', 'gates', 'goNoGo',
        'releaseNotes', 'publication') -Description 'v1 release authorization'
    if ([int]$authorization.schemaVersion -ne 1 -or [string]$authorization.reportKind -cne 'HerdrOps.ReleaseAuthorization' -or
        [int]$authorization.issue -ne 45 -or [string]$authorization.repository -cne 'OSHEThai/HerdrOps' -or
        [string]$authorization.releaseVersion -cne 'v1.0.0' -or [string]$authorization.releaseTag -cne 'v1.0.0') {
        throw 'The v1 release authorization identity is not exact.'
    }
    $acceptedCommit = [string]$authorization.acceptedCommit
    Assert-V10Hex -Value $acceptedCommit -Length 40 -Description 'accepted release commit' -Lowercase
    if (-not [string]::IsNullOrWhiteSpace($ExpectedSourceCommit) -and $acceptedCommit -cne $ExpectedSourceCommit) {
        throw 'Release authorization does not bind the expected accepted commit.'
    }

    Assert-V10ExactProperties -Object $authorization.candidateRecord -Names @('path', 'sha256', 'archiveSha256') -Description 'authorization candidate record'
    $candidatePath = Resolve-V10RepositoryFile -RelativePath ([string]$authorization.candidateRecord.path) -RepositoryRoot $RepositoryRoot -Description 'authorization candidate record'
    $candidate = Assert-V10CandidateRecord -CandidateRecordPath $candidatePath -RepositoryRoot $RepositoryRoot -ExpectedSourceCommit $acceptedCommit -ProfilePath $ProfilePath
    if ([string]$authorization.candidateRecord.sha256 -cne $candidate.RecordSha256 -or
        [string]$authorization.candidateRecord.archiveSha256 -cne $candidate.ArchiveSha256) {
        throw 'Release authorization candidate record or archive hash does not match independently observed bytes.'
    }
    $acceptedGit = Get-V10GitIdentity -RepositoryRoot $RepositoryRoot -ExpectedCommit $acceptedCommit -RequireClean
    $treeOutput = @(& git -C $RepositoryRoot rev-parse --verify "$acceptedCommit^{tree}" 2>&1 | ForEach-Object { [string]$_ })
    $treeExit = $LASTEXITCODE
    $expectedSourceTree = if ($treeOutput.Count -eq 1) { $treeOutput[0].Trim().ToLowerInvariant() } else { '' }
    $parentOutput = @(& git -C $RepositoryRoot rev-parse --verify "$acceptedCommit^1" 2>&1 | ForEach-Object { [string]$_ })
    $parentExit = $LASTEXITCODE
    $expectedParentCommit = if ($parentOutput.Count -eq 1) { $parentOutput[0].Trim().ToLowerInvariant() } else { '' }
    $branchOutput = @(& git -C $RepositoryRoot symbolic-ref --short HEAD 2>&1 | ForEach-Object { [string]$_ })
    $branchExit = $LASTEXITCODE
    $expectedBranch = if ($branchOutput.Count -eq 1) { $branchOutput[0].Trim() } else { '' }
    if ($treeExit -ne 0 -or $parentExit -ne 0 -or $branchExit -ne 0 -or
        $expectedSourceTree -notmatch '^[0-9a-f]{40}$' -or
        $expectedParentCommit -notmatch '^[0-9a-f]{40}$' -or
        [string]::IsNullOrWhiteSpace($expectedBranch)) {
        throw 'Release authorization could not resolve exact accepted source tree, direct parent, and branch bindings.'
    }

    $expectedGates = @(
        [ordered]@{ issue = 41; evidenceClass = 'ReleaseAudit' },
        [ordered]@{ issue = 42; evidenceClass = 'Runtime' },
        [ordered]@{ issue = 43; evidenceClass = 'IndependentReview' },
        [ordered]@{ issue = 44; evidenceClass = 'CleanMachine' })
    $gates = @($authorization.gates)
    if ($gates.Count -ne $expectedGates.Count) {
        throw 'Release authorization must bind exactly Issues #41 through #44.'
    }
    $gateRecords = New-Object System.Collections.ArrayList
    for ($index = 0; $index -lt $gates.Count; $index++) {
        $gate = $gates[$index]
        Assert-V10ExactProperties -Object $gate -Names @(
            'issue', 'evidenceClass', 'status', 'reportPath', 'reportSha256',
            'sourceCommit', 'archiveSha256', 'authority', 'observedAtUtc') -Description "authorization gate $index"
        $expected = $expectedGates[$index]
        if ([int]$gate.issue -ne [int]$expected.issue -or [string]$gate.evidenceClass -cne [string]$expected.evidenceClass -or
            [string]$gate.status -cne 'PASS' -or [string]$gate.sourceCommit -cne $acceptedCommit -or
            [string]$gate.archiveSha256 -cne $candidate.ArchiveSha256) {
            throw "Release authorization gate at index $index does not bind the exact accepted candidate."
        }
        $authority = [string]$gate.authority
        if ([string]::IsNullOrWhiteSpace($authority) -or $authority -match '[<>]' -or $authority -in @('PENDING', 'NOT ASSIGNED')) {
            throw "Release authorization gate #$($gate.issue) has no concrete authority."
        }
        Assert-V10UtcTimestamp -Value ([string]$gate.observedAtUtc) -Description "Issue #$($gate.issue) observedAtUtc"
        $reportPath = Resolve-V10RepositoryFile -RelativePath ([string]$gate.reportPath) -RepositoryRoot $RepositoryRoot -Description "Issue #$($gate.issue) report"
        $report = Read-V10StrictJsonFile -Path $reportPath -Description "Issue #$($gate.issue) report"
        if ([string]$gate.reportSha256 -cne $report.Sha256) {
            throw "Issue #$($gate.issue) report hash does not match its exact bytes."
        }
        Assert-V10GateReport `
            -Issue ([int]$gate.issue) `
            -EvidenceClass ([string]$gate.evidenceClass) `
            -Report $report `
            -SourceCommit $acceptedCommit `
            -ArchiveSha256 $candidate.ArchiveSha256 `
            -ArchiveBytes $candidate.ArchiveBytes `
            -ExpectedSourceTree $expectedSourceTree `
            -ExpectedParentCommit $expectedParentCommit `
            -ExpectedBranch $expectedBranch `
            -ManifestSha256 ([string]$candidate.Record.generation.manifestSha256) `
            -ContentSha256 ([string]$candidate.Record.generation.contentSha256)
        [void]$gateRecords.Add([pscustomobject][ordered]@{
                Issue = [int]$gate.issue
                EvidenceClass = [string]$gate.evidenceClass
                ReportPath = $report.Path
                ReportSha256 = $report.Sha256
            })
    }

    Assert-V10ExactProperties -Object $authorization.goNoGo -Names @(
        'decision', 'approver', 'approvedAtUtc', 'statement', 'acceptedCommit', 'archiveSha256') -Description 'human go/no-go record'
    if ([string]$authorization.goNoGo.decision -cne 'GO' -or
        [string]$authorization.goNoGo.statement -cne $script:V10GoNoGoStatement -or
        [string]$authorization.goNoGo.acceptedCommit -cne $acceptedCommit -or
        [string]$authorization.goNoGo.archiveSha256 -cne $candidate.ArchiveSha256) {
        throw 'Human go/no-go does not explicitly approve the exact accepted candidate.'
    }
    $approver = [string]$authorization.goNoGo.approver
    if ([string]::IsNullOrWhiteSpace($approver) -or $approver -match '[<>]' -or $approver -in @('PENDING', 'NOT ASSIGNED')) {
        throw 'Human go/no-go must name the concrete approver.'
    }
    Assert-V10UtcTimestamp -Value ([string]$authorization.goNoGo.approvedAtUtc) -Description 'go/no-go approvedAtUtc'

    Assert-V10ExactProperties -Object $authorization.releaseNotes -Names @('path', 'sha256') -Description 'release notes binding'
    if ([string]$authorization.releaseNotes.path -cne 'docs/release/v1.0.0/release-notes.en.md') {
        throw 'GitHub Release notes must use the exact English release-notes document.'
    }
    $releaseNotesPath = Resolve-V10RepositoryFile -RelativePath ([string]$authorization.releaseNotes.path) -RepositoryRoot $RepositoryRoot -Description 'GitHub Release notes'
    $releaseNotesHash = ((Get-FileHash -LiteralPath $releaseNotesPath -Algorithm SHA256).Hash).ToUpperInvariant()
    if ([string]$authorization.releaseNotes.sha256 -cne $releaseNotesHash) {
        throw 'Release notes binding does not match the accepted document bytes.'
    }
    $candidateReleaseDocument = @($candidate.Record.documents | Where-Object { [string]$_.path -ceq [string]$authorization.releaseNotes.path })
    if ($candidateReleaseDocument.Count -ne 1 -or [string]$candidateReleaseDocument[0].sha256 -cne $releaseNotesHash) {
        throw 'Release notes were changed after the candidate record was created.'
    }

    Assert-V10ExactProperties -Object $authorization.publication -Names @(
        'status', 'releaseUrl', 'publishedArchiveSha256', 'publishedHashRecordSha256') -Description 'pre-publication record'
    if ([string]$authorization.publication.status -cne 'NOT_PUBLISHED' -or
        -not [string]::IsNullOrEmpty([string]$authorization.publication.releaseUrl) -or
        -not [string]::IsNullOrEmpty([string]$authorization.publication.publishedArchiveSha256) -or
        -not [string]::IsNullOrEmpty([string]$authorization.publication.publishedHashRecordSha256)) {
        throw 'Pre-publication authorization must not claim a GitHub Release or published hashes.'
    }

    return [pscustomobject][ordered]@{
        AuthorizationPath = $authorizationFile.Path
        AuthorizationSha256 = $authorizationFile.Sha256
        AcceptedCommit = $acceptedCommit
        Candidate = $candidate
        Gates = @($gateRecords.ToArray())
        Approver = $approver
        ApprovedAtUtc = [string]$authorization.goNoGo.approvedAtUtc
        Decision = [string]$authorization.goNoGo.decision
        ReleaseNotesPath = $releaseNotesPath
        ReleaseNotesSha256 = $releaseNotesHash
        Status = 'READY_TO_PUBLISH'
        EvidenceClass = 'Static'
        Release = 'NOT OBSERVED'
    }
}
