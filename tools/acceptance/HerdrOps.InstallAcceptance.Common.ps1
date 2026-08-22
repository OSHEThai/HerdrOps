#requires -Version 5.1

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '..\packaging\Packaging.Common.ps1')

function Get-AcceptanceFullPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.IndexOfAny([char[]]@('*', '?')) -ge 0) {
        throw "Acceptance path must be a non-empty literal path without wildcards: $Path"
    }

    try {
        return (Normalize-ComparablePath -Path $Path)
    } catch {
        throw "Acceptance path is invalid: $Path. $($_.Exception.Message)"
    }
}

function Get-AcceptanceRequiredProperty {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Context
    )

    if ($null -eq $Object) {
        throw "$Context is null; required property '$Name' is missing."
    }

    if ($Object -is [System.Collections.IDictionary]) {
        if (-not $Object.Contains($Name) -or $null -eq $Object[$Name]) {
            throw "$Context is missing exactly one non-null '$Name' property."
        }
        return $Object[$Name]
    }

    $properties = @($Object.PSObject.Properties | Where-Object { $_.Name -ceq $Name })
    if ($properties.Count -ne 1 -or $null -eq $properties[0].Value) {
        throw "$Context is missing exactly one non-null '$Name' property."
    }

    return $properties[0].Value
}

function Assert-AcceptanceExactProperties {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string[]]$Names,
        [Parameter(Mandatory = $true)][string]$Context
    )

    if ($null -eq $Object) {
        throw "$Context is null."
    }

    if ($Object -is [System.Collections.IDictionary]) {
        $actualNames = @($Object.Keys | ForEach-Object { [string]$_ })
    } else {
        $actualNames = @($Object.PSObject.Properties | ForEach-Object { [string]$_.Name })
    }
    if ($actualNames.Count -ne $Names.Count) {
        throw "$Context has an unexpected property set: $($actualNames -join ', ')."
    }

    foreach ($name in $Names) {
        if (@($actualNames | Where-Object { $_ -ceq $name }).Count -ne 1) {
            throw "$Context is missing exact property '$name'."
        }
    }
}

function Assert-AcceptanceSha256 {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$Context
    )

    if ($Value -notmatch '^[0-9A-F]{64}$') {
        throw "$Context must be an uppercase SHA-256 value."
    }
}

function Get-AcceptanceSha256ForFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    $safePath = Get-AcceptanceFullPath -Path $Path
    if (-not (Test-Path -LiteralPath $safePath -PathType Leaf)) {
        throw "File not found for acceptance SHA-256 calculation: $safePath"
    }

    $stream = $null
    $algorithm = $null
    try {
        $stream = [IO.File]::Open($safePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $algorithm = [Security.Cryptography.SHA256]::Create()
        return ([BitConverter]::ToString($algorithm.ComputeHash($stream))).Replace('-', '').ToUpperInvariant()
    } finally {
        if ($null -ne $algorithm) { $algorithm.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Assert-AcceptanceLiveSourceCommitBinding {
    param(
        [Parameter(Mandatory = $true)][string]$AcceptedSourceCommit,
        [Parameter(Mandatory = $true)][string]$ExpectedSourceCommit,
        [Parameter(Mandatory = $true)][string]$UpgradeArtifactSourceCommit
    )

    foreach ($binding in @(
            [pscustomobject]@{ Name = 'accepted sourceCommit'; Value = $AcceptedSourceCommit },
            [pscustomobject]@{ Name = 'expected sourceCommit'; Value = $ExpectedSourceCommit },
            [pscustomobject]@{ Name = 'upgrade artifact sourceCommit'; Value = $UpgradeArtifactSourceCommit })) {
        if ([string]$binding.Value -notmatch '^[0-9a-f]{40}$') {
            throw "$($binding.Name) must be an exact 40-character lowercase commit."
        }
    }
    if ($AcceptedSourceCommit -cne $ExpectedSourceCommit -or
        $UpgradeArtifactSourceCommit -cne $AcceptedSourceCommit) {
        throw 'Accepted, independently expected, and v1.0.0 upgrade artifact source commits must be identical.'
    }
}

function Get-AcceptanceEvidenceClassForObservation {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('DryRun', 'Fixture', 'Live')][string]$Mode,
        [Parameter(Mandatory = $true)][bool]$CleanMachineFilesystemObserved
    )

    if ($Mode -ceq 'Fixture') { return 'Synthetic' }
    if ($Mode -ceq 'Live' -and $CleanMachineFilesystemObserved) { return 'CleanMachine' }
    return 'Static'
}

function Resolve-AcceptanceSafeRelativeFilePath {
    param(
        [Parameter(Mandatory = $true)][string]$RootPath,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $root = Get-AcceptanceFullPath -Path $RootPath
    if ([string]::IsNullOrWhiteSpace($RelativePath) -or
        [IO.Path]::IsPathRooted($RelativePath) -or
        $RelativePath.StartsWith('\', [StringComparison]::Ordinal) -or
        $RelativePath.StartsWith('/', [StringComparison]::Ordinal) -or
        $RelativePath.EndsWith('\', [StringComparison]::Ordinal) -or
        $RelativePath.EndsWith('/', [StringComparison]::Ordinal)) {
        throw "$Context must be a non-empty relative file path."
    }

    $normalizedRelative = $RelativePath.Replace('/', '\')
    $segments = @($normalizedRelative.Split([char]'\'))
    if ($segments.Count -eq 0) {
        throw "$Context has no file-name segment."
    }
    foreach ($segment in $segments) {
        if ([string]::IsNullOrWhiteSpace($segment) -or
            $segment -ceq '.' -or
            $segment -ceq '..' -or
            $segment.TrimEnd([char[]]@(' ', '.')) -cne $segment -or
            $segment.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or
            $segment -match '^[\x00-\x1F]+$') {
            throw "$Context contains an unsafe path segment: '$segment'."
        }
        $deviceStem = [IO.Path]::GetFileNameWithoutExtension($segment)
        if ($deviceStem -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') {
            throw "$Context contains a reserved Windows device name: '$segment'."
        }
    }

    $resolved = Get-AcceptanceFullPath -Path (Join-Path $root $normalizedRelative)
    if ($resolved.Equals($root, [StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-PathWithin -ChildPath $resolved -RootPath $root)) {
        throw "$Context must resolve to a strict descendant of its root."
    }
    return $resolved
}

function Assert-AcceptanceSafeDescendantFilePath {
    param(
        [Parameter(Mandatory = $true)][string]$RootPath,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $root = Get-AcceptanceFullPath -Path $RootPath
    $fullPath = Get-AcceptanceFullPath -Path $Path
    if ($fullPath.Equals($root, [StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-PathWithin -ChildPath $fullPath -RootPath $root)) {
        throw "$Context must be a strict descendant of its root."
    }
    $relative = $fullPath.Substring($root.TrimEnd('\').Length).TrimStart('\')
    $resolved = Resolve-AcceptanceSafeRelativeFilePath -RootPath $root -RelativePath $relative -Context $Context
    if (-not $resolved.Equals($fullPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Context changed during canonical relative-path validation."
    }
    return $fullPath
}

function New-AcceptanceRetainedDataMarker {
    param(
        [Parameter(Mandatory = $true)][string]$UserDataRoot,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedSha256
    )

    $safePath = Assert-AcceptanceSafeDescendantFilePath -RootPath $UserDataRoot -Path $Path -Context 'retained-data marker path'
    $content = "HerdrOps Issue #44 acceptance retained-data marker`n"
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($content)
    $actualSha256 = Get-Sha256ForBytes -Bytes $bytes
    if ($actualSha256 -cne $ExpectedSha256) {
        throw 'The retained-data marker content does not match its exact live binding hash.'
    }
    $parent = Split-Path -Path $safePath -Parent
    Assert-AcceptanceDirectory -Path $parent -Context 'retained-data marker parent' -Create | Out-Null
    Assert-AcceptanceNoReparsePath -Path $safePath
    $stream = $null
    $created = $false
    try {
        $stream = [IO.File]::Open($safePath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $created = $true
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    } catch {
        $writeException = $_.Exception
        if ($null -ne $stream) {
            $stream.Dispose()
            $stream = $null
        }
        if ($created -and (Test-Path -LiteralPath $safePath -PathType Leaf)) {
            Remove-Item -LiteralPath $safePath -Force
        }
        throw "Could not atomically create the owned retained-data marker: $($writeException.Message)"
    } finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }
    return $true
}

function Assert-AcceptanceNoReparsePath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $current = Get-AcceptanceFullPath -Path $Path
    while (-not [string]::IsNullOrWhiteSpace($current)) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Reparse points are not allowed in acceptance paths: $current"
            }
        }

        $parent = Split-Path -Path $current -Parent
        if ([string]::IsNullOrWhiteSpace($parent) -or
            $parent.Equals($current, [StringComparison]::OrdinalIgnoreCase)) {
            break
        }
        $current = Get-AcceptanceFullPath -Path $parent
    }
}

function Assert-AcceptanceTreeNoReparse {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $fullPath = Get-AcceptanceFullPath -Path $Path
    if (-not (Test-Path -LiteralPath $fullPath)) {
        throw "$Context was not found: $fullPath"
    }
    Assert-AcceptanceNoReparsePath -Path $fullPath
    foreach ($item in @(Get-ChildItem -LiteralPath $fullPath -Recurse -Force)) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Context contains a reparse point: $($item.FullName)"
        }
    }
}

function Assert-AcceptanceNotBroadPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $fullPath = Get-AcceptanceFullPath -Path $Path
    $root = Get-AcceptanceFullPath -Path ([IO.Path]::GetPathRoot($fullPath))
    if ($fullPath.Equals($root, [StringComparison]::OrdinalIgnoreCase) -or
        [string]::IsNullOrWhiteSpace([IO.Path]::GetFileName($fullPath))) {
        throw "$Context is a broad filesystem root: $fullPath"
    }
    return $fullPath
}

function Assert-AcceptanceDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Context,
        [switch]$Create
    )

    $fullPath = Assert-AcceptanceNotBroadPath -Path $Path -Context $Context
    Assert-AcceptanceNoReparsePath -Path $fullPath
    if (-not (Test-Path -LiteralPath $fullPath)) {
        if (-not $Create) {
            throw "$Context directory was not found: $fullPath"
        }
        New-Item -ItemType Directory -Path $fullPath -Force | Out-Null
    }

    $item = Get-Item -LiteralPath $fullPath -Force
    if (-not $item.PSIsContainer -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Context must be a non-reparse directory: $fullPath"
    }
    return $fullPath
}

function Assert-AcceptanceReportPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$UserDataRoot,
        [switch]$AllowExternalParent
    )

    $fullPath = Assert-AcceptanceNotBroadPath -Path $Path -Context 'Acceptance report path'
    if (Test-Path -LiteralPath $fullPath) {
        throw "Acceptance report destination already exists; refusing to overwrite: $fullPath"
    }
    if ((Test-PathWithin -ChildPath $fullPath -RootPath $InstallRoot) -or
        (Test-PathWithin -ChildPath $fullPath -RootPath $UserDataRoot)) {
        throw "Acceptance report must not be inside an install or retained-data path: $fullPath"
    }

    $parent = Split-Path -Path $fullPath -Parent
    if ([string]::IsNullOrWhiteSpace($parent) -or -not (Test-Path -LiteralPath $parent -PathType Container)) {
        throw "Acceptance report parent must already exist: $parent"
    }
    Assert-AcceptanceNoReparsePath -Path $parent

    if (-not $AllowExternalParent) {
        Assert-SafeDestination -Path $fullPath -AllowRepositoryChild -AllowTempChild | Out-Null
    } else {
        foreach ($protectedRoot in @(
                [Environment]::GetFolderPath([Environment+SpecialFolder]::Windows),
                [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles),
                [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFilesX86),
                [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData))) {
            if (-not [string]::IsNullOrWhiteSpace($protectedRoot) -and
                (Test-PathWithin -ChildPath $fullPath -RootPath $protectedRoot)) {
                throw "Acceptance report must not be written below a protected Windows path: $fullPath"
            }
        }
    }

    return $fullPath
}

function Get-AcceptanceMachineFingerprint {
    $machineName = [Environment]::MachineName
    $osVersion = [Environment]::OSVersion.Version.ToString()
    return Get-Sha256ForText -Text ("HerdrOps Issue 44 machine binding`n$machineName`n$osVersion`n")
}

function Test-AcceptanceIsElevated {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        return $false
    }

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } finally {
        if ($null -ne $identity) {
            $identity.Dispose()
        }
    }
}

function Read-AcceptanceJsonFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $fullPath = Get-AcceptanceFullPath -Path $Path
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "$Context was not found: $fullPath"
    }
    Assert-AcceptanceNoReparsePath -Path $fullPath
    try {
        $json = [IO.File]::ReadAllText($fullPath)
        Assert-NoDuplicateJsonObjectProperties -Json $json -Description $Context
        $converter = Get-Command -Name ConvertFrom-Json -CommandType Cmdlet -ErrorAction Stop
        if ($converter.Parameters.ContainsKey('DateKind')) {
            return & $converter -InputObject $json -DateKind String
        }
        return & $converter -InputObject $json
    } catch {
        throw "$Context is not valid JSON: $fullPath. $($_.Exception.Message)"
    }
}

function Read-AcceptanceHashRecord {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = Get-AcceptanceFullPath -Path $Path
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "Package hash record was not found: $fullPath"
    }
    Assert-AcceptanceNoReparsePath -Path $fullPath

    $lines = @(Get-Content -LiteralPath $fullPath)
    if ($lines.Count -lt 2 -or [string]$lines[0] -cne 'HerdrOps package integrity record') {
        throw "Package hash record has an invalid header: $fullPath"
    }

    $allowedNames = @(
        'SchemaVersion', 'ProductId', 'PackageVersion', 'RuntimeIdentifier',
        'ArchiveFile', 'ArchiveBytes', 'ArchiveSha256', 'ManifestFile',
        'ManifestBytes', 'ManifestSha256', 'ContentSha256', 'EvidenceClass')
    $values = [ordered]@{}
    for ($index = 1; $index -lt $lines.Count; $index++) {
        if ([string]$lines[$index] -notmatch '^([^:]+): (.*)$') {
            throw "Package hash record contains a malformed line $($index + 1): $fullPath"
        }
        $name = [string]$matches[1]
        if (@($allowedNames | Where-Object { $_ -ceq $name }).Count -ne 1) {
            throw "Package hash record contains an unknown field '$name': $fullPath"
        }
        if ($values.Contains($name)) {
            throw "Package hash record contains duplicate field '$name': $fullPath"
        }
        $values[$name] = [string]$matches[2]
    }

    foreach ($name in $allowedNames) {
        if (-not $values.Contains($name)) {
            throw "Package hash record is missing field '$name': $fullPath"
        }
    }

    if ([int]$values.SchemaVersion -ne 1 -or
        [string]$values.ProductId -cne 'HerdrOps' -or
        [string]$values.ManifestFile -cne 'package-manifest.json' -or
        [string]$values.EvidenceClass -cne 'Static') {
        throw "Package hash record identity fields are invalid: $fullPath"
    }
    Assert-AcceptanceSha256 -Value ([string]$values.ArchiveSha256) -Context 'ArchiveSha256'
    Assert-AcceptanceSha256 -Value ([string]$values.ManifestSha256) -Context 'ManifestSha256'
    Assert-AcceptanceSha256 -Value ([string]$values.ContentSha256) -Context 'ContentSha256'
    if ([int64]$values.ArchiveBytes -lt 0 -or [int64]$values.ManifestBytes -lt 0) {
        throw "Package hash record contains a negative byte count: $fullPath"
    }

    return [pscustomobject][ordered]@{
        Path = $fullPath
        SchemaVersion = [int]$values.SchemaVersion
        ProductId = [string]$values.ProductId
        PackageVersion = [string]$values.PackageVersion
        RuntimeIdentifier = [string]$values.RuntimeIdentifier
        ArchiveFile = [string]$values.ArchiveFile
        ArchiveBytes = [int64]$values.ArchiveBytes
        ArchiveSha256 = [string]$values.ArchiveSha256
        ManifestFile = [string]$values.ManifestFile
        ManifestBytes = [int64]$values.ManifestBytes
        ManifestSha256 = [string]$values.ManifestSha256
        ContentSha256 = [string]$values.ContentSha256
        EvidenceClass = [string]$values.EvidenceClass
    }
}

function Assert-AcceptanceManifestShapeAndBytes {
    param(
        [Parameter(Mandatory = $true)][string]$PackageRoot,
        [Parameter(Mandatory = $true)]$Expected,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $root = Get-AcceptanceFullPath -Path $PackageRoot
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        throw "$Context package root was not found: $root"
    }
    Assert-AcceptanceNotBroadPath -Path $root -Context "$Context package root" | Out-Null
    Assert-AcceptanceTreeNoReparse -Path $root -Context $Context

    $manifestPath = Join-Path $root 'package-manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "$Context package manifest was not found: $manifestPath"
    }
    $manifest = Read-PackageManifest -PackageRoot $root
    $manifestNames = @(
        'schemaVersion', 'issue', 'productId', 'packageVersion',
        'targetFramework', 'runtimeIdentifier', 'deploymentModel',
        'userDataPolicy', 'contentHashAlgorithm', 'fileCount', 'totalBytes',
        'contentSha256', 'files', 'evidenceClass')
    Assert-AcceptanceExactProperties -Object $manifest -Names $manifestNames -Context "$Context package manifest"

    if ([int](Get-AcceptanceRequiredProperty -Object $manifest -Name 'schemaVersion' -Context $Context) -ne 1 -or
        [int](Get-AcceptanceRequiredProperty -Object $manifest -Name 'issue' -Context $Context) -ne [int](Get-AcceptanceRequiredProperty -Object $Expected -Name 'packagingIssue' -Context "$Context binding") -or
        [string](Get-AcceptanceRequiredProperty -Object $manifest -Name 'productId' -Context $Context) -cne [string](Get-AcceptanceRequiredProperty -Object $Expected -Name 'productId' -Context "$Context binding") -or
        [string](Get-AcceptanceRequiredProperty -Object $manifest -Name 'packageVersion' -Context $Context) -cne [string](Get-AcceptanceRequiredProperty -Object $Expected -Name 'packageVersion' -Context "$Context binding") -or
        [string](Get-AcceptanceRequiredProperty -Object $manifest -Name 'targetFramework' -Context $Context) -cne [string](Get-AcceptanceRequiredProperty -Object $Expected -Name 'targetFramework' -Context "$Context binding") -or
        [string](Get-AcceptanceRequiredProperty -Object $manifest -Name 'runtimeIdentifier' -Context $Context) -cne [string](Get-AcceptanceRequiredProperty -Object $Expected -Name 'runtimeIdentifier' -Context "$Context binding") -or
        [string](Get-AcceptanceRequiredProperty -Object $manifest -Name 'deploymentModel' -Context $Context) -cne [string](Get-AcceptanceRequiredProperty -Object $Expected -Name 'deploymentModel' -Context "$Context binding") -or
        [string](Get-AcceptanceRequiredProperty -Object $manifest -Name 'userDataPolicy' -Context $Context) -cne [string](Get-AcceptanceRequiredProperty -Object $Expected -Name 'userDataPolicy' -Context "$Context binding") -or
        [string](Get-AcceptanceRequiredProperty -Object $manifest -Name 'contentHashAlgorithm' -Context $Context) -cne 'SHA-256' -or
        [string](Get-AcceptanceRequiredProperty -Object $manifest -Name 'evidenceClass' -Context $Context) -cne 'Static') {
        throw "$Context package manifest identity does not match its exact artifact binding."
    }

    Assert-PackageVersion -Version ([string]$manifest.packageVersion)
    $actualEntries = @(Get-PackageEntries -PackageRoot $root -ExcludeRelativePath @('package-manifest.json'))
    $manifestEntries = @(Get-AcceptanceRequiredProperty -Object $manifest -Name 'files' -Context $Context)
    $actualTotalBytes = [int64]0
    foreach ($entry in $actualEntries) {
        $actualTotalBytes += [int64]$entry.Length
    }
    if ([int]$manifest.fileCount -ne $actualEntries.Count -or
        [int64]$manifest.totalBytes -ne $actualTotalBytes -or
        $manifestEntries.Count -ne $actualEntries.Count) {
        throw "$Context package manifest file count or byte total does not match the payload."
    }

    $sortableManifestEntries = @($manifestEntries | ForEach-Object {
            [pscustomobject][ordered]@{
                Path = [string]$_.path
                Original = $_
            }
        })
    $sortedManifestEntries = @(Sort-PackageEntriesOrdinal -Entries $sortableManifestEntries)
    for ($index = 0; $index -lt $actualEntries.Count; $index++) {
        $actual = $actualEntries[$index]
        $expectedEntry = $sortedManifestEntries[$index].Original
        $expectedPath = [string](Get-AcceptanceRequiredProperty -Object $expectedEntry -Name 'path' -Context "$Context manifest entry $index")
        $expectedLength = [int64](Get-AcceptanceRequiredProperty -Object $expectedEntry -Name 'length' -Context "$Context manifest entry $index")
        $expectedHash = [string](Get-AcceptanceRequiredProperty -Object $expectedEntry -Name 'sha256' -Context "$Context manifest entry $index")
        Assert-AcceptanceSha256 -Value $expectedHash -Context "$Context manifest entry $index sha256"
        if ($expectedPath -cne [string]$actual.Path -or
            $expectedLength -ne [int64]$actual.Length -or
            $expectedHash -cne [string]$actual.Sha256) {
            throw "$Context package manifest entry mismatch at index ${index}: $($actual.Path)"
        }
    }

    $canonical = Get-CanonicalPackageContentText -Entries $actualEntries
    $contentSha256 = Get-Sha256ForText -Text $canonical
    Assert-AcceptanceSha256 -Value ([string]$manifest.contentSha256) -Context "$Context contentSha256"
    if ([string]$manifest.contentSha256 -cne $contentSha256) {
        throw "$Context package contentSha256 does not match current bytes."
    }

    $manifestInfo = Get-Item -LiteralPath $manifestPath -Force
    $manifestSha256 = Get-AcceptanceSha256ForFile -Path $manifestPath
    $manifestBytes = [int64]$manifestInfo.Length
    Assert-AcceptanceSha256 -Value $manifestSha256 -Context "$Context manifest file hash"

    return [pscustomobject][ordered]@{
        Root = $root
        ManifestPath = (Get-AcceptanceFullPath -Path $manifestPath)
        Manifest = $manifest
        ManifestBytes = $manifestBytes
        ManifestSha256 = $manifestSha256
        ContentSha256 = $contentSha256
        Entries = $actualEntries
    }
}

function Assert-AcceptanceArtifact {
    param(
        [Parameter(Mandatory = $true)]$Expected,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $packageRoot = Get-AcceptanceFullPath -Path ([string](Get-AcceptanceRequiredProperty -Object $Expected -Name 'packageRoot' -Context "$Name binding"))
    $archivePath = Get-AcceptanceFullPath -Path ([string](Get-AcceptanceRequiredProperty -Object $Expected -Name 'archivePath' -Context "$Name binding"))
    $hashRecordPath = Get-AcceptanceFullPath -Path ([string](Get-AcceptanceRequiredProperty -Object $Expected -Name 'hashRecordPath' -Context "$Name binding"))
    foreach ($path in @($archivePath, $hashRecordPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "$Name artifact file was not found: $path"
        }
        Assert-AcceptanceNoReparsePath -Path $path
        if (Test-PathWithin -ChildPath $path -RootPath $packageRoot) {
            throw "$Name artifact sidecar must be outside its package root: $path"
        }
    }

    $manifestCheck = Assert-AcceptanceManifestShapeAndBytes `
        -PackageRoot $packageRoot `
        -Expected $Expected `
        -Context $Name
    $archiveInfo = Get-Item -LiteralPath $archivePath -Force
    $archiveSha256 = Get-AcceptanceSha256ForFile -Path $archivePath
    $record = Read-AcceptanceHashRecord -Path $hashRecordPath
    $expectedArchiveFile = [IO.Path]::GetFileName($archivePath)
    if ($record.ArchiveFile -cne $expectedArchiveFile -or
        $record.ArchiveBytes -ne [int64]$archiveInfo.Length -or
        $record.ArchiveSha256 -cne $archiveSha256 -or
        $record.ManifestBytes -ne $manifestCheck.ManifestBytes -or
        $record.ManifestSha256 -cne $manifestCheck.ManifestSha256 -or
        $record.ContentSha256 -cne $manifestCheck.ContentSha256 -or
        $record.PackageVersion -cne [string]$manifestCheck.Manifest.packageVersion -or
        $record.RuntimeIdentifier -cne [string]$manifestCheck.Manifest.runtimeIdentifier) {
        throw "$Name artifact hash record does not match its exact archive and package bytes."
    }

    $expectedManifestSha256 = [string](Get-AcceptanceRequiredProperty -Object $Expected -Name 'manifestSha256' -Context "$Name binding")
    $expectedArchiveSha256 = [string](Get-AcceptanceRequiredProperty -Object $Expected -Name 'archiveSha256' -Context "$Name binding")
    $expectedContentSha256 = [string](Get-AcceptanceRequiredProperty -Object $Expected -Name 'contentSha256' -Context "$Name binding")
    $sourceCommit = [string](Get-AcceptanceRequiredProperty -Object $Expected -Name 'sourceCommit' -Context "$Name binding")
    Assert-AcceptanceSha256 -Value $expectedManifestSha256 -Context "$Name binding manifestSha256"
    Assert-AcceptanceSha256 -Value $expectedArchiveSha256 -Context "$Name binding archiveSha256"
    Assert-AcceptanceSha256 -Value $expectedContentSha256 -Context "$Name binding contentSha256"
    if ($sourceCommit -cne 'NOT_BOUND_IN_SYNTHETIC_FIXTURE' -and
        $sourceCommit -notmatch '^[0-9a-f]{40}$') {
        throw "$Name binding sourceCommit must be an exact lowercase commit or the synthetic non-binding marker."
    }
    if ($expectedManifestSha256 -cne $manifestCheck.ManifestSha256 -or
        $expectedArchiveSha256 -cne $archiveSha256 -or
        $expectedContentSha256 -cne $manifestCheck.ContentSha256) {
        throw "$Name artifact bytes do not match the exact hash binding."
    }

    Assert-AcceptanceArchiveMatchesPackageRoot `
        -ArchivePath $archivePath `
        -ManifestCheck $manifestCheck `
        -Context $Name

    return [pscustomobject][ordered]@{
        Name = $Name
        PackageRoot = $packageRoot
        ArchivePath = $archivePath
        HashRecordPath = $hashRecordPath
        ManifestPath = $manifestCheck.ManifestPath
        Manifest = $manifestCheck.Manifest
        ManifestBytes = $manifestCheck.ManifestBytes
        ManifestSha256 = $manifestCheck.ManifestSha256
        ContentSha256 = $manifestCheck.ContentSha256
        ContentEntries = $manifestCheck.Entries
        ArchiveBytes = [int64]$archiveInfo.Length
        ArchiveSha256 = $archiveSha256
        PackageVersion = [string]$manifestCheck.Manifest.packageVersion
        ProductId = [string]$manifestCheck.Manifest.productId
        PackagingIssue = [int]$manifestCheck.Manifest.issue
        TargetFramework = [string]$manifestCheck.Manifest.targetFramework
        RuntimeIdentifier = [string]$manifestCheck.Manifest.runtimeIdentifier
        DeploymentModel = [string]$manifestCheck.Manifest.deploymentModel
        UserDataPolicy = [string]$manifestCheck.Manifest.userDataPolicy
        SourceCommit = $sourceCommit
    }
}

function Assert-AcceptanceArchiveMatchesPackageRoot {
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)]$ManifestCheck,
        [Parameter(Mandatory = $true)][string]$Context
    )

    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    } catch {
        if ($null -eq ('System.IO.Compression.ZipFile' -as [type])) {
            throw "$Context archive verification could not load ZIP support: $($_.Exception.Message)"
        }
    }

    $expectedEntries = New-Object System.Collections.ArrayList
    foreach ($entry in @($ManifestCheck.Entries)) {
        [void]$expectedEntries.Add([pscustomobject][ordered]@{
                Path = [string]$entry.Path
                Length = [int64]$entry.Length
                Sha256 = [string]$entry.Sha256
            })
    }
    [void]$expectedEntries.Add([pscustomobject][ordered]@{
            Path = 'package-manifest.json'
            Length = [int64]$ManifestCheck.ManifestBytes
            Sha256 = [string]$ManifestCheck.ManifestSha256
        })
    $expected = @(Sort-PackageEntriesOrdinal -Entries @($expectedEntries.ToArray()))

    $archive = $null
    try {
        $archive = [IO.Compression.ZipFile]::OpenRead((Get-AcceptanceFullPath -Path $ArchivePath))
        $metadata = New-Object System.Collections.ArrayList
        $seenNames = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in @($archive.Entries)) {
            $entryName = [string]$entry.FullName
            if ([string]::IsNullOrWhiteSpace($entryName) -or
                $entryName.EndsWith('/', [StringComparison]::Ordinal) -or
                $entryName.Contains('\') -or
                $entryName.StartsWith('/', [StringComparison]::Ordinal) -or
                $entryName.Contains('//') -or
                $entryName -match '(^|/)\.\.?(/|$)' -or
                $entryName -match '[\x00-\x1F<>:"|?*]' -or
                [IO.Path]::IsPathRooted($entryName)) {
                throw "$Context archive contains an unsafe or non-file entry: '$entryName'."
            }
            if (-not $seenNames.Add($entryName)) {
                throw "$Context archive contains a duplicate Windows path: '$entryName'."
            }
            [void]$metadata.Add([pscustomobject][ordered]@{
                    Path = $entryName
                    Length = [int64]$entry.Length
                    Entry = $entry
                })
        }

        $actual = @(Sort-PackageEntriesOrdinal -Entries @($metadata.ToArray()))
        if ($actual.Count -ne $expected.Count) {
            throw "$Context archive entry count does not match the expanded package root."
        }
        for ($index = 0; $index -lt $expected.Count; $index++) {
            if ([string]$actual[$index].Path -cne [string]$expected[$index].Path -or
                [int64]$actual[$index].Length -ne [int64]$expected[$index].Length) {
                throw "$Context archive metadata mismatch at index ${index}: '$($actual[$index].Path)'."
            }
        }

        for ($index = 0; $index -lt $expected.Count; $index++) {
            $stream = $null
            $algorithm = $null
            try {
                $stream = $actual[$index].Entry.Open()
                $algorithm = [Security.Cryptography.SHA256]::Create()
                $hash = ([BitConverter]::ToString($algorithm.ComputeHash($stream))).Replace('-', '').ToUpperInvariant()
            } finally {
                if ($null -ne $algorithm) { $algorithm.Dispose() }
                if ($null -ne $stream) { $stream.Dispose() }
            }
            if ($hash -cne [string]$expected[$index].Sha256) {
                throw "$Context archive bytes differ from the expanded package root at '$($expected[$index].Path)'."
            }
        }
    } catch {
        throw "$Context archive is not an exact safe representation of its expanded package root. $($_.Exception.Message)"
    } finally {
        if ($null -ne $archive) { $archive.Dispose() }
    }
}

function Get-AcceptanceInstalledFileHashes {
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $root = Get-AcceptanceFullPath -Path $InstallRoot
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        throw "$Context install directory was not found: $root"
    }
    Assert-AcceptanceTreeNoReparse -Path $root -Context $Context
    $entries = @(Get-PackageEntries -PackageRoot $root)
    return @($entries | ForEach-Object {
            [pscustomobject][ordered]@{
                Path = [string]$_.Path
                Length = [int64]$_.Length
                Sha256 = [string]$_.Sha256
            }
        })
}

function Get-AcceptanceExpectedInstalledFileHashes {
    param([Parameter(Mandatory = $true)]$Artifact)

    $entries = New-Object System.Collections.ArrayList
    foreach ($entry in @($Artifact.ContentEntries)) {
        [void]$entries.Add([pscustomobject][ordered]@{
                Path = [string]$entry.Path
                Length = [int64]$entry.Length
                Sha256 = [string]$entry.Sha256
            })
    }
    [void]$entries.Add([pscustomobject][ordered]@{
            Path = 'package-manifest.json'
            Length = [int64]$Artifact.ManifestBytes
            Sha256 = [string]$Artifact.ManifestSha256
        })
    return @(Sort-PackageEntriesOrdinal -Entries @($entries.ToArray()))
}

function Assert-AcceptanceInstalledPayload {
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)]$Artifact,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $actual = @(Get-AcceptanceInstalledFileHashes -InstallRoot $InstallRoot -Context $Context)
    $expected = @(Get-AcceptanceExpectedInstalledFileHashes -Artifact $Artifact)
    if ($actual.Count -ne $expected.Count) {
        throw "$Context installed file count mismatch: expected $($expected.Count), actual $($actual.Count)."
    }
    for ($index = 0; $index -lt $actual.Count; $index++) {
        if ([string]$actual[$index].Path -cne [string]$expected[$index].Path -or
            [int64]$actual[$index].Length -ne [int64]$expected[$index].Length -or
            [string]$actual[$index].Sha256 -cne [string]$expected[$index].Sha256) {
            throw "$Context installed hash mismatch at index ${index}: $($actual[$index].Path)."
        }
    }
    return $actual
}

function Copy-AcceptanceDirectoryContents {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $sourceRoot = Get-AcceptanceFullPath -Path $Source
    $destinationRoot = Get-AcceptanceFullPath -Path $Destination
    if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) {
        throw "$Context source directory was not found: $sourceRoot"
    }
    if ((Test-PathWithin -ChildPath $sourceRoot -RootPath $destinationRoot) -or
        (Test-PathWithin -ChildPath $destinationRoot -RootPath $sourceRoot)) {
        throw "$Context source and destination must not overlap."
    }
    Assert-AcceptanceTreeNoReparse -Path $sourceRoot -Context "$Context source"
    Assert-AcceptanceNoReparsePath -Path $destinationRoot
    if (-not (Test-Path -LiteralPath $destinationRoot)) {
        New-Item -ItemType Directory -Path $destinationRoot -Force | Out-Null
    }
    $destinationItem = Get-Item -LiteralPath $destinationRoot -Force
    if (-not $destinationItem.PSIsContainer -or
        ($destinationItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Context destination must be a non-reparse directory: $destinationRoot"
    }

    foreach ($item in @(Get-ChildItem -LiteralPath $sourceRoot -Force)) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Context source contains a reparse point: $($item.FullName)"
        }
        $destination = Join-Path $destinationRoot $item.Name
        if (Test-Path -LiteralPath $destination) {
            throw "$Context refuses to overwrite an existing destination: $destination"
        }
        if ($item.PSIsContainer) {
            Copy-AcceptanceDirectoryContents -Source $item.FullName -Destination $destination -Context $Context
        } else {
            Copy-Item -LiteralPath $item.FullName -Destination $destination | Out-Null
        }
    }
}

function Remove-AcceptanceDirectoryTree {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $fullPath = Assert-AcceptanceNotBroadPath -Path $Path -Context $Context
    if (-not (Test-Path -LiteralPath $fullPath)) {
        return
    }
    $item = Get-Item -LiteralPath $fullPath -Force
    if (-not $item.PSIsContainer -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Context target must be a non-reparse directory: $fullPath"
    }
    Assert-AcceptanceTreeNoReparse -Path $fullPath -Context $Context
    Remove-Item -LiteralPath $fullPath -Recurse -Force
}

function New-AcceptanceOwnedSiblingDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$InstallParent,
        [Parameter(Mandatory = $true)][ValidateSet('stage', 'backup')][string]$Role,
        [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{32}$')][string]$RunId
    )

    $parent = Assert-AcceptanceDirectory -Path $InstallParent -Context 'Acceptance install parent' -Create
    $path = Join-Path $parent ("HerdrOps.issue-44.$Role-$RunId")
    if (Test-Path -LiteralPath $path) {
        throw "Owned acceptance $Role directory already exists: $path"
    }
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    Assert-AcceptanceNoReparsePath -Path $path
    return (Get-AcceptanceFullPath -Path $path)
}

function Remove-AcceptanceOwnedSiblingDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$InstallParent,
        [Parameter(Mandatory = $true)][ValidateSet('stage', 'backup')][string]$Role,
        [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{32}$')][string]$RunId
    )

    $fullPath = Get-AcceptanceFullPath -Path $Path
    $parent = Get-AcceptanceFullPath -Path $InstallParent
    $expectedName = "HerdrOps.issue-44.$Role-$RunId"
    if (-not $fullPath.Equals((Join-Path $parent $expectedName), [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove an unrecognized acceptance $Role directory: $fullPath"
    }
    Remove-AcceptanceDirectoryTree -Path $fullPath -Context "owned acceptance $Role cleanup"
}

function New-AcceptanceCancellationException {
    param([Parameter(Mandatory = $true)][string]$Phase)

    $exception = New-Object System.OperationCanceledException -ArgumentList ("Issue #44 acceptance was cancelled during $Phase.")
    $exception.Data['HerdrOpsAcceptanceCancellation'] = $true
    $exception.Data['HerdrOpsAcceptancePhase'] = $Phase
    return $exception
}

function Test-AcceptanceCancellationException {
    param([Parameter(Mandatory = $true)][System.Exception]$Exception)

    return ($Exception -is [System.OperationCanceledException] -or
        ($Exception.Data.Contains('HerdrOpsAcceptanceCancellation') -and
         [bool]$Exception.Data['HerdrOpsAcceptanceCancellation']))
}

function Invoke-AcceptanceDirectoryTransition {
    param(
        [Parameter(Mandatory = $true)]$Artifact,
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$InstallParent,
        [Parameter(Mandatory = $true)][ValidateSet('CleanInstall', 'Upgrade', 'Rollback')][string]$Phase,
        [Parameter(Mandatory = $true)][ValidateSet('None', 'BeforeCleanInstallCommit', 'BeforeUpgradeCommit', 'AfterUpgradeBackup', 'BeforeRollbackCommit', 'AfterRollbackBackup', 'BeforeUninstallCommit')][string]$CancellationPoint,
        [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{32}$')][string]$RunId,
        [scriptblock]$TestOnlyBeforeCommitHook,
        [scriptblock]$TestOnlyBackupRetirementHook
    )

    $target = Get-AcceptanceFullPath -Path $InstallRoot
    $parent = Get-AcceptanceFullPath -Path $InstallParent
    $stage = $null
    $backup = $null
    $oldPresent = Test-Path -LiteralPath $target
    $oldMoved = $false
    $committed = $false
    $validatedCommit = $false
    $preserveTransient = $false
    try {
        $stage = New-AcceptanceOwnedSiblingDirectory -InstallParent $parent -Role 'stage' -RunId $RunId
        Copy-AcceptanceDirectoryContents -Source $Artifact.PackageRoot -Destination $stage -Context "$Phase staged package"

        $beforeCommitPoint = "Before${Phase}Commit"
        if ($CancellationPoint -ceq $beforeCommitPoint) {
            throw (New-AcceptanceCancellationException -Phase $Phase)
        }

        if ($oldPresent) {
            if (-not (Test-Path -LiteralPath $target -PathType Container)) {
                throw "$Phase existing install target is not a directory: $target"
            }
            Assert-AcceptanceTreeNoReparse -Path $target -Context "$Phase existing install"
            $backup = New-AcceptanceOwnedSiblingDirectory -InstallParent $parent -Role 'backup' -RunId $RunId
            Remove-AcceptanceDirectoryTree -Path $backup -Context "$Phase empty backup preparation"
            Move-Item -LiteralPath $target -Destination $backup
            $oldMoved = $true
            $afterBackupPoint = "After${Phase}Backup"
            if ($CancellationPoint -ceq $afterBackupPoint) {
                throw (New-AcceptanceCancellationException -Phase $Phase)
            }
        }

        if ($null -ne $TestOnlyBeforeCommitHook) {
            & $TestOnlyBeforeCommitHook $target $backup | Out-Null
        }
        if (Test-Path -LiteralPath $target) {
            throw "$Phase install target was unexpectedly recreated before commit: $target"
        }
        Move-Item -LiteralPath $stage -Destination $target
        $stage = $null
        $committed = $true
        $installedHashes = Assert-AcceptanceInstalledPayload -InstallRoot $target -Artifact $Artifact -Context "$Phase installed package"
        $validatedCommit = $true

        if ($null -ne $backup -and (Test-Path -LiteralPath $backup)) {
            try {
                if ($null -ne $TestOnlyBackupRetirementHook) {
                    & $TestOnlyBackupRetirementHook $backup $target | Out-Null
                }
                Remove-AcceptanceOwnedSiblingDirectory -Path $backup -InstallParent $parent -Role 'backup' -RunId $RunId
                $backup = $null
            } catch {
                $preserveTransient = $true
                throw "$Phase installed payload is valid and remains committed, but owned backup retirement failed: $($_.Exception.Message)"
            }
        }

        return [pscustomobject][ordered]@{
            InstalledFileHashes = $installedHashes
            WasUpgrade = $oldPresent
            Committed = $committed
        }
    } catch {
        $primaryException = $_.Exception
        $cleanupException = $null
        if ($validatedCommit) {
            $preserveTransient = $true
            throw $primaryException
        }
        try {
            if ($null -ne $stage -and (Test-Path -LiteralPath $stage)) {
                Remove-AcceptanceOwnedSiblingDirectory -Path $stage -InstallParent $parent -Role 'stage' -RunId $RunId
                $stage = $null
            }
            if ($committed -and (Test-Path -LiteralPath $target)) {
                Remove-AcceptanceDirectoryTree -Path $target -Context "$Phase failed transition rollback"
            }
            if ($oldMoved -and $null -ne $backup -and (Test-Path -LiteralPath $backup)) {
                if (Test-Path -LiteralPath $target) {
                    throw "$Phase rollback target was not empty before backup restore: $target"
                }
                Move-Item -LiteralPath $backup -Destination $target
                $backup = $null
            } elseif ($null -ne $backup -and (Test-Path -LiteralPath $backup)) {
                Remove-AcceptanceOwnedSiblingDirectory -Path $backup -InstallParent $parent -Role 'backup' -RunId $RunId
                $backup = $null
            }
        } catch {
            $cleanupException = $_.Exception
        }

        if ($null -ne $cleanupException) {
            $preserveTransient = $true
            throw (New-Object System.Exception -ArgumentList @(
                    ("$($primaryException.Message) Cleanup also failed: $($cleanupException.Message)"),
                    $primaryException))
        }
        throw $primaryException
    } finally {
        if (-not $preserveTransient -and $null -ne $stage -and (Test-Path -LiteralPath $stage)) {
            Remove-AcceptanceOwnedSiblingDirectory -Path $stage -InstallParent $parent -Role 'stage' -RunId $RunId
        }
        if (-not $preserveTransient -and $null -ne $backup -and (Test-Path -LiteralPath $backup)) {
            Remove-AcceptanceOwnedSiblingDirectory -Path $backup -InstallParent $parent -Role 'backup' -RunId $RunId
        }
    }
}

function Invoke-AcceptanceUninstallTransition {
    param(
        [Parameter(Mandatory = $true)]$Artifact,
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$InstallParent,
        [Parameter(Mandatory = $true)][string]$RetainedDataPath,
        [Parameter(Mandatory = $true)][string]$RetainedDataSha256,
        [Parameter(Mandatory = $true)][ValidateSet('None', 'BeforeCleanInstallCommit', 'BeforeUpgradeCommit', 'AfterUpgradeBackup', 'BeforeRollbackCommit', 'AfterRollbackBackup', 'BeforeUninstallCommit')][string]$CancellationPoint,
        [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{32}$')][string]$RunId,
        [scriptblock]$TestOnlyBackupRetirementHook
    )

    $target = Get-AcceptanceFullPath -Path $InstallRoot
    $parent = Get-AcceptanceFullPath -Path $InstallParent
    $retainedPath = Get-AcceptanceFullPath -Path $RetainedDataPath
    Assert-AcceptanceSha256 -Value $RetainedDataSha256 -Context 'uninstall retained-data SHA-256'
    $backup = $null
    $oldMoved = $false
    $validatedCommit = $false
    $preserveTransient = $false
    try {
        $installedHashes = Assert-AcceptanceInstalledPayload -InstallRoot $target -Artifact $Artifact -Context 'Uninstall source package'
        if ($CancellationPoint -ceq 'BeforeUninstallCommit') {
            throw (New-AcceptanceCancellationException -Phase 'Uninstall')
        }

        $backup = New-AcceptanceOwnedSiblingDirectory -InstallParent $parent -Role 'backup' -RunId $RunId
        Remove-AcceptanceDirectoryTree -Path $backup -Context 'Uninstall empty backup preparation'
        Move-Item -LiteralPath $target -Destination $backup
        $oldMoved = $true
        if (Test-Path -LiteralPath $target) {
            throw 'Uninstall target remained after the atomic directory move.'
        }
        if (-not (Test-Path -LiteralPath $retainedPath -PathType Leaf)) {
            throw "Retained-data marker was not found after uninstall: $retainedPath"
        }
        Assert-AcceptanceNoReparsePath -Path $retainedPath
        $retainedHash = Get-AcceptanceSha256ForFile -Path $retainedPath
        if ($retainedHash -cne $RetainedDataSha256) {
            throw 'Retained-data marker hash changed during uninstall.'
        }
        $validatedCommit = $true

        try {
            if ($null -ne $TestOnlyBackupRetirementHook) {
                & $TestOnlyBackupRetirementHook $backup $target | Out-Null
            }
            Remove-AcceptanceOwnedSiblingDirectory -Path $backup -InstallParent $parent -Role 'backup' -RunId $RunId
            $backup = $null
        } catch {
            $preserveTransient = $true
            throw "Uninstall is committed and retained data is valid, but owned backup retirement failed: $($_.Exception.Message)"
        }

        return [pscustomobject][ordered]@{
            RemovedFileHashes = $installedHashes
            RetainedDataSha256 = $retainedHash
            Committed = $true
        }
    } catch {
        $primaryException = $_.Exception
        if ($validatedCommit) {
            $preserveTransient = $true
            throw $primaryException
        }

        $cleanupException = $null
        try {
            if ($oldMoved -and $null -ne $backup -and (Test-Path -LiteralPath $backup)) {
                if (Test-Path -LiteralPath $target) {
                    throw 'Uninstall rollback target was not empty before backup restore.'
                }
                Move-Item -LiteralPath $backup -Destination $target
                $backup = $null
            } elseif ($null -ne $backup -and (Test-Path -LiteralPath $backup)) {
                Remove-AcceptanceOwnedSiblingDirectory -Path $backup -InstallParent $parent -Role 'backup' -RunId $RunId
                $backup = $null
            }
        } catch {
            $cleanupException = $_.Exception
        }
        if ($null -ne $cleanupException) {
            $preserveTransient = $true
            throw (New-Object System.Exception -ArgumentList @(
                    ("$($primaryException.Message) Uninstall rollback also failed: $($cleanupException.Message)"),
                    $primaryException))
        }
        throw $primaryException
    } finally {
        if (-not $preserveTransient -and $null -ne $backup -and (Test-Path -LiteralPath $backup)) {
            Remove-AcceptanceOwnedSiblingDirectory -Path $backup -InstallParent $parent -Role 'backup' -RunId $RunId
        }
    }
}

function Write-AcceptanceReportAtomically {
    param(
        [Parameter(Mandatory = $true)]$Report,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$UserDataRoot,
        [switch]$AllowExternalParent
    )

    $destination = Assert-AcceptanceReportPath `
        -Path $Path `
        -InstallRoot $InstallRoot `
        -UserDataRoot $UserDataRoot `
        -AllowExternalParent:$AllowExternalParent
    $parent = Split-Path -Path $destination -Parent
    $stage = Join-Path $parent ('.herdrops-issue-44-report.staging-' + [Guid]::NewGuid().ToString('N'))
    Assert-AcceptanceNoReparsePath -Path $parent
    if (Test-Path -LiteralPath $stage) {
        throw "Acceptance report staging path already exists: $stage"
    }

    $json = ($Report | ConvertTo-Json -Depth 50) + "`n"
    $encoding = New-Object System.Text.UTF8Encoding($false)
    $bytes = $encoding.GetBytes($json)
    $stream = $null
    try {
        $stream = [IO.File]::Open($stage, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
        $stream.Dispose()
        $stream = $null
        Move-Item -LiteralPath $stage -Destination $destination
    } catch {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
        if (Test-Path -LiteralPath $stage) {
            Remove-Item -LiteralPath $stage -Force
        }
        throw
    }

    return $destination
}

function Assert-AcceptanceReportStringValue {
    param(
        [AllowNull()]$Value,
        [Parameter(Mandatory = $true)][string]$Context
    )

    if ($null -eq $Value -or $Value -isnot [string]) {
        throw "$Context must be a JSON string."
    }
}

function Assert-AcceptanceReportHashList {
    param(
        [Parameter(Mandatory = $true)]$Hashes,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $index = 0
    foreach ($hash in @($Hashes)) {
        Assert-AcceptanceExactProperties -Object $hash -Names @('path', 'length', 'sha256') -Context "$Context hash $index"
        Assert-AcceptanceReportStringValue -Value $hash.path -Context "$Context hash $index path"
        Assert-JsonIntegerValue -Value $hash.length -Name "$Context hash $index length"
        Assert-AcceptanceReportStringValue -Value $hash.sha256 -Context "$Context hash $index sha256"
        if ([string]::IsNullOrWhiteSpace([string]$hash.path) -or
            [int64]$hash.length -lt 0 -or
            [string]$hash.sha256 -notmatch '^[0-9A-F]{64}$') {
            throw "$Context hash $index is invalid."
        }
        $index++
    }
}

function Assert-AcceptanceArtifactReportRecord {
    param(
        [AllowNull()]$Artifact,
        [Parameter(Mandatory = $true)][string]$Context
    )

    if ($null -eq $Artifact) {
        return
    }
    Assert-AcceptanceExactProperties -Object $Artifact -Names @(
        'name', 'productId', 'displayName', 'packagingIssue', 'packageVersion',
        'targetFramework', 'runtimeIdentifier', 'deploymentModel', 'userDataPolicy',
        'packageRoot', 'archivePath', 'archiveBytes', 'archiveSha256', 'manifestPath',
        'manifestBytes', 'manifestSha256', 'contentSha256', 'sourceCommitBinding',
        'installedFileHashes') -Context $Context
    foreach ($stringName in @(
            'name', 'productId', 'displayName', 'packageVersion', 'targetFramework',
            'runtimeIdentifier', 'deploymentModel', 'userDataPolicy', 'packageRoot',
            'archivePath', 'archiveSha256', 'manifestPath', 'manifestSha256',
            'contentSha256', 'sourceCommitBinding')) {
        Assert-AcceptanceReportStringValue -Value (Get-AcceptanceRequiredProperty -Object $Artifact -Name $stringName -Context $Context) -Context "$Context $stringName"
    }
    Assert-JsonIntegerValue -Value $Artifact.packagingIssue -Name "$Context packagingIssue"
    Assert-JsonIntegerValue -Value $Artifact.archiveBytes -Name "$Context archiveBytes"
    Assert-JsonIntegerValue -Value $Artifact.manifestBytes -Name "$Context manifestBytes"
    if ([string]$Artifact.productId -cne 'HerdrOps' -or
        [string]$Artifact.displayName -cne 'HerdrOps' -or
        [int]$Artifact.packagingIssue -lt 1 -or
        [string]$Artifact.packageVersion -notmatch '^\d+\.\d+\.\d+$' -or
        [string]$Artifact.targetFramework -cne 'net10.0-windows' -or
        [string]$Artifact.runtimeIdentifier -cne 'win-x64' -or
        [string]$Artifact.deploymentModel -cne 'per-user-directory' -or
        [string]$Artifact.userDataPolicy -cne 'retain-on-uninstall' -or
        [int64]$Artifact.archiveBytes -lt 0 -or
        [int64]$Artifact.manifestBytes -lt 0) {
        throw "$Context identity or byte-count fields are invalid."
    }
    foreach ($hashName in @('archiveSha256', 'manifestSha256', 'contentSha256')) {
        Assert-AcceptanceSha256 -Value ([string](Get-AcceptanceRequiredProperty -Object $Artifact -Name $hashName -Context $Context)) -Context "$Context $hashName"
    }
    if ([string]$Artifact.sourceCommitBinding -cne 'NOT_BOUND_IN_SYNTHETIC_FIXTURE' -and
        [string]$Artifact.sourceCommitBinding -notmatch '^[0-9a-f]{40}$') {
        throw "$Context sourceCommitBinding is invalid."
    }
    Assert-AcceptanceReportHashList -Hashes $Artifact.installedFileHashes -Context "$Context installed files"
}

function Assert-AcceptanceReportMatchesSchema {
    param(
        [Parameter(Mandatory = $true)]$Report,
        [Parameter(Mandatory = $true)][string]$SchemaPath
    )

    $schemaFullPath = Get-AcceptanceFullPath -Path $SchemaPath
    $schema = Read-AcceptanceJsonFile -Path $schemaFullPath -Context 'Issue #44 acceptance report schema'
    if ([string]$schema.'$schema' -notlike '*draft-07*' -or
        [string]$schema.title -notlike '*Issue 44*') {
        throw 'Issue #44 acceptance report schema identity is invalid.'
    }

    Assert-AcceptanceExactProperties -Object $Report -Names @(
        'schemaVersion', 'reportKind', 'issue', 'acceptanceVersion', 'status',
        'mode', 'evidenceClass', 'startedAtUtc', 'completedAtUtc', 'runId',
        'machine', 'artifacts', 'targets', 'preflight', 'lifecycle', 'semanticReadiness', 'cleanup',
        'failureDetails', 'transcript', 'boundaries') -Context 'Issue #44 acceptance report'
    Assert-JsonIntegerValue -Value $Report.schemaVersion -Name 'acceptance report schemaVersion'
    Assert-JsonIntegerValue -Value $Report.issue -Name 'acceptance report issue'
    foreach ($topStringName in @(
            'reportKind', 'acceptanceVersion', 'status', 'mode', 'evidenceClass',
            'startedAtUtc', 'completedAtUtc', 'runId', 'failureDetails')) {
        Assert-AcceptanceReportStringValue -Value (Get-AcceptanceRequiredProperty -Object $Report -Name $topStringName -Context 'acceptance report') -Context "acceptance report $topStringName"
    }
    if ([int]$Report.schemaVersion -ne 1 -or
        [string]$Report.reportKind -cne 'HerdrOps.InstallAcceptanceReport' -or
        [int]$Report.issue -ne 44 -or
        [string]$Report.acceptanceVersion -cne 'v1.0.0' -or
        [string]$Report.status -notin @('PASS', 'FAIL', 'CANCELLED') -or
        [string]$Report.mode -notin @('DryRun', 'Fixture', 'Live') -or
        [string]$Report.evidenceClass -notin @('Static', 'Synthetic', 'CleanMachine') -or
        [string]$Report.runId -notmatch '^[0-9a-f]{32}$') {
        throw 'Issue #44 acceptance report top-level identity is invalid.'
    }
    try {
        [void][DateTimeOffset]::Parse([string]$Report.startedAtUtc, [Globalization.CultureInfo]::InvariantCulture)
        [void][DateTimeOffset]::Parse([string]$Report.completedAtUtc, [Globalization.CultureInfo]::InvariantCulture)
    } catch {
        throw "Issue #44 acceptance report contains an invalid timestamp. $($_.Exception.Message)"
    }

    Assert-AcceptanceExactProperties -Object $Report.machine -Names @('name', 'expectedName', 'fingerprint', 'expectedFingerprint', 'elevated') -Context 'acceptance report machine'
    foreach ($machineStringName in @('name', 'expectedName', 'fingerprint', 'expectedFingerprint')) {
        Assert-AcceptanceReportStringValue -Value (Get-AcceptanceRequiredProperty -Object $Report.machine -Name $machineStringName -Context 'acceptance report machine') -Context "acceptance report machine $machineStringName"
    }
    Assert-AcceptanceSha256 -Value ([string]$Report.machine.fingerprint) -Context 'acceptance report machine fingerprint'
    if ($Report.machine.elevated -isnot [bool]) {
        throw 'Acceptance report machine elevated must be a JSON boolean.'
    }

    Assert-AcceptanceExactProperties -Object $Report.artifacts -Names @('initial', 'upgrade') -Context 'acceptance report artifacts'
    Assert-AcceptanceArtifactReportRecord -Artifact $Report.artifacts.initial -Context 'acceptance report initial artifact'
    Assert-AcceptanceArtifactReportRecord -Artifact $Report.artifacts.upgrade -Context 'acceptance report upgrade artifact'

    Assert-AcceptanceExactProperties -Object $Report.targets -Names @(
        'installRoot', 'userDataRoot', 'reportPath', 'simulationRoot',
        'installPathPolicy', 'userDataPathPolicy', 'userDataPolicy') -Context 'acceptance report targets'
    foreach ($targetStringName in @('installRoot', 'userDataRoot', 'reportPath', 'simulationRoot', 'installPathPolicy', 'userDataPathPolicy', 'userDataPolicy')) {
        Assert-AcceptanceReportStringValue -Value (Get-AcceptanceRequiredProperty -Object $Report.targets -Name $targetStringName -Context 'acceptance report targets') -Context "acceptance report target $targetStringName"
    }
    if ([string]$Report.targets.installPathPolicy -cne '%LOCALAPPDATA%\Programs\HerdrOps' -or
        [string]$Report.targets.userDataPathPolicy -cne '%LOCALAPPDATA%\HerdrOps' -or
        [string]$Report.targets.userDataPolicy -cne 'retain-on-uninstall') {
        throw 'Acceptance report target policies are invalid.'
    }

    Assert-AcceptanceExactProperties -Object $Report.preflight -Names @('status', 'checks') -Context 'acceptance report preflight'
    if ([string]$Report.preflight.status -notin @('PASS', 'FAIL')) {
        throw 'Acceptance report preflight status is invalid.'
    }
    $checkIndex = 0
    foreach ($check in @($Report.preflight.checks)) {
        Assert-AcceptanceExactProperties -Object $check -Names @('name', 'status', 'details') -Context "acceptance report preflight check $checkIndex"
        foreach ($checkStringName in @('name', 'status', 'details')) {
            Assert-AcceptanceReportStringValue -Value (Get-AcceptanceRequiredProperty -Object $check -Name $checkStringName -Context "acceptance report preflight check $checkIndex") -Context "acceptance report preflight check $checkIndex $checkStringName"
        }
        if ([string]$check.status -notin @('PASS', 'FAIL', 'NOT_APPLICABLE')) {
            throw "Acceptance report preflight check $checkIndex status is invalid."
        }
        $checkIndex++
    }

    Assert-AcceptanceExactProperties -Object $Report.lifecycle -Names @('cleanInstall', 'upgrade', 'rollback', 'uninstall') -Context 'acceptance report lifecycle'
    foreach ($stepName in @('cleanInstall', 'upgrade', 'rollback', 'uninstall')) {
        $step = Get-AcceptanceRequiredProperty -Object $Report.lifecycle -Name $stepName -Context 'acceptance report lifecycle'
        Assert-AcceptanceExactProperties -Object $step -Names @(
            'status', 'expectedVersion', 'installedFileHashes', 'installRootPresent',
            'packageVersionObserved', 'retainedDataStatus', 'retainedDataSha256',
            'details') -Context "acceptance report lifecycle $stepName"
        foreach ($stepStringName in @('status', 'expectedVersion', 'packageVersionObserved', 'retainedDataStatus', 'retainedDataSha256', 'details')) {
            Assert-AcceptanceReportStringValue -Value (Get-AcceptanceRequiredProperty -Object $step -Name $stepStringName -Context "acceptance report lifecycle $stepName") -Context "acceptance report lifecycle $stepName $stepStringName"
        }
        if ([string]$step.status -notin @('PASS', 'FAIL', 'CANCELLED', 'NOT_RUN') -or
            [string]$step.retainedDataStatus -notin @('PASS', 'FAIL', 'NOT_RUN', 'NOT_APPLICABLE') -or
            $step.installRootPresent -isnot [bool]) {
            throw "Acceptance report lifecycle $stepName state is invalid."
        }
        Assert-AcceptanceReportHashList -Hashes $step.installedFileHashes -Context "acceptance report lifecycle $stepName"
    }

    Assert-AcceptanceExactProperties -Object $Report.semanticReadiness -Names @(
        'status', 'details', 'binding') -Context 'acceptance report semanticReadiness'
    foreach ($semanticStringName in @('status', 'details')) {
        Assert-AcceptanceReportStringValue -Value (Get-AcceptanceRequiredProperty -Object $Report.semanticReadiness -Name $semanticStringName -Context 'acceptance report semanticReadiness') -Context "acceptance report semanticReadiness $semanticStringName"
    }
    $semanticStatus = [string]$Report.semanticReadiness.status
    if ($semanticStatus -notin @('PASS', 'SYNTHETIC', 'NOT_OBSERVED')) {
        throw 'Acceptance report semanticReadiness status is invalid.'
    }
    $semanticBinding = $Report.semanticReadiness.binding
    if ($semanticStatus -ceq 'PASS') {
        if ($null -eq $semanticBinding) {
            throw 'Acceptance report semanticReadiness PASS requires a non-null binding.'
        }
        $semanticBindingFields = @(
            'schemaVersion', 'acceptanceNonceSha256', 'clientInstanceId', 'correlationId',
            'serverInstanceId', 'coreProcessId', 'coreProcessStartUtcTicks', 'coreExecutablePath',
            'coreExecutableSha256', 'appProcessId', 'appProcessStartUtcTicks', 'appExecutablePath',
            'appExecutableSha256', 'snapshotSequence', 'rawEvidenceBytes', 'rawEvidenceSha256')
        Assert-AcceptanceExactProperties -Object $semanticBinding -Names $semanticBindingFields -Context 'acceptance report semanticReadiness binding'
        foreach ($integerName in @(
                'schemaVersion', 'coreProcessId', 'coreProcessStartUtcTicks', 'appProcessId',
                'appProcessStartUtcTicks', 'snapshotSequence', 'rawEvidenceBytes')) {
            Assert-JsonIntegerValue -Value (Get-AcceptanceRequiredProperty -Object $semanticBinding -Name $integerName -Context 'acceptance report semanticReadiness binding') -Name "semanticReadiness binding $integerName"
        }
        foreach ($stringName in @(
                'acceptanceNonceSha256', 'clientInstanceId', 'correlationId', 'serverInstanceId',
                'coreExecutablePath', 'coreExecutableSha256', 'appExecutablePath',
                'appExecutableSha256', 'rawEvidenceSha256')) {
            Assert-AcceptanceReportStringValue -Value (Get-AcceptanceRequiredProperty -Object $semanticBinding -Name $stringName -Context 'acceptance report semanticReadiness binding') -Context "semanticReadiness binding $stringName"
        }
        foreach ($hashName in @('acceptanceNonceSha256', 'coreExecutableSha256', 'appExecutableSha256', 'rawEvidenceSha256')) {
            Assert-AcceptanceSha256 -Value ([string]$semanticBinding.$hashName) -Context "semanticReadiness binding $hashName"
        }
        if ([int]$semanticBinding.schemaVersion -ne 1 -or
            [string]$semanticBinding.clientInstanceId -notmatch '^[0-9a-f]{32}$' -or
            [string]$semanticBinding.correlationId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' -or
            [string]$semanticBinding.serverInstanceId -notmatch '^[0-9a-f]{32}$' -or
            [int]$semanticBinding.coreProcessId -lt 1 -or
            [long]$semanticBinding.coreProcessStartUtcTicks -lt 1 -or
            [string]::IsNullOrWhiteSpace([string]$semanticBinding.coreExecutablePath) -or
            [int]$semanticBinding.appProcessId -lt 1 -or
            [long]$semanticBinding.appProcessStartUtcTicks -lt 1 -or
            [string]::IsNullOrWhiteSpace([string]$semanticBinding.appExecutablePath) -or
            [long]$semanticBinding.snapshotSequence -lt 0 -or
            [long]$semanticBinding.rawEvidenceBytes -lt 1 -or
            [long]$semanticBinding.rawEvidenceBytes -gt 32768) {
            throw 'Acceptance report semanticReadiness binding contains invalid values.'
        }
    } elseif ($null -ne $semanticBinding) {
        throw 'Acceptance report non-PASS semanticReadiness requires a null binding.'
    }

    Assert-AcceptanceExactProperties -Object $Report.cleanup -Names @(
        'status', 'attempted', 'simulationRoot', 'simulationRootRemoved',
        'ownedStageRemoved', 'ownedBackupRemoved', 'harnessSeededDataMarkerRemoved',
        'retainedDataLeftIntact', 'residuals', 'details') -Context 'acceptance report cleanup'
    foreach ($cleanupStringName in @('simulationRoot', 'details')) {
        Assert-AcceptanceReportStringValue -Value (Get-AcceptanceRequiredProperty -Object $Report.cleanup -Name $cleanupStringName -Context 'acceptance report cleanup') -Context "acceptance report cleanup $cleanupStringName"
    }
    foreach ($residual in @($Report.cleanup.residuals)) {
        Assert-AcceptanceReportStringValue -Value $residual -Context 'acceptance report cleanup residual'
    }
    if ([string]$Report.cleanup.status -notin @('PASS', 'FAIL', 'NOT_RUN', 'NOT_APPLICABLE')) {
        throw 'Acceptance report cleanup status is invalid.'
    }
    foreach ($booleanName in @('attempted', 'simulationRootRemoved', 'ownedStageRemoved', 'ownedBackupRemoved', 'harnessSeededDataMarkerRemoved', 'retainedDataLeftIntact')) {
        $booleanValue = Get-AcceptanceRequiredProperty -Object $Report.cleanup -Name $booleanName -Context 'acceptance report cleanup'
        if ($booleanValue -isnot [bool]) {
            throw "Acceptance report cleanup $booleanName must be a JSON boolean."
        }
    }

    $transcriptIndex = 0
    foreach ($entry in @($Report.transcript)) {
        Assert-AcceptanceExactProperties -Object $entry -Names @('sequence', 'phase', 'action', 'status', 'effect', 'details', 'pathBinding') -Context "acceptance report transcript $transcriptIndex"
        Assert-JsonIntegerValue -Value $entry.sequence -Name "acceptance report transcript $transcriptIndex sequence"
        foreach ($entryStringName in @('phase', 'action', 'status', 'effect', 'details', 'pathBinding')) {
            Assert-AcceptanceReportStringValue -Value (Get-AcceptanceRequiredProperty -Object $entry -Name $entryStringName -Context "acceptance report transcript $transcriptIndex") -Context "acceptance report transcript $transcriptIndex $entryStringName"
        }
        if ([int]$entry.sequence -lt 1 -or
            [string]$entry.status -notin @('PASS', 'FAIL', 'SKIPPED', 'CANCELLED', 'NOT_RUN') -or
            [string]$entry.effect -notin @('None', 'FixtureTempOnly', 'LiveFilesystem')) {
            throw "Acceptance report transcript $transcriptIndex is invalid."
        }
        $transcriptIndex++
    }
    Assert-AcceptanceExactProperties -Object $Report.boundaries -Names @(
        'static', 'synthetic', 'contract', 'cleanMachine', 'runtime',
        'independentReview', 'release') -Context 'acceptance report boundaries'
    foreach ($boundaryName in @('static', 'synthetic', 'contract', 'cleanMachine', 'runtime', 'independentReview', 'release')) {
        Assert-AcceptanceReportStringValue -Value (Get-AcceptanceRequiredProperty -Object $Report.boundaries -Name $boundaryName -Context 'acceptance report boundaries') -Context "acceptance report boundary $boundaryName"
    }

    $json = ($Report | ConvertTo-Json -Depth 50)
    [void](ConvertFrom-StrictPackageJson -Json $json -Description 'serialized Issue #44 acceptance report')
    $testJsonCommand = Get-Command -Name Test-Json -CommandType Cmdlet -ErrorAction SilentlyContinue
    if ($null -ne $testJsonCommand) {
        try {
            $schemaPassed = & $testJsonCommand -Json $json -SchemaFile $schemaFullPath -ErrorAction Stop
        } catch {
            throw "Issue #44 acceptance report failed JSON Schema validation. $($_.Exception.Message)"
        }
        if (-not $schemaPassed) {
            throw 'Issue #44 acceptance report failed JSON Schema validation.'
        }
    }
}
