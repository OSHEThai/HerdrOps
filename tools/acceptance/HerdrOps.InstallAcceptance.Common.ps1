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
        return Get-Content -LiteralPath $fullPath -Raw | ConvertFrom-Json
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
    $manifestSha256 = ((Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash).ToUpperInvariant()
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
    $archiveSha256 = ((Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash).ToUpperInvariant()
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
    Assert-AcceptanceSha256 -Value $expectedManifestSha256 -Context "$Name binding manifestSha256"
    Assert-AcceptanceSha256 -Value $expectedArchiveSha256 -Context "$Name binding archiveSha256"
    Assert-AcceptanceSha256 -Value $expectedContentSha256 -Context "$Name binding contentSha256"
    if ($expectedManifestSha256 -cne $manifestCheck.ManifestSha256 -or
        $expectedArchiveSha256 -cne $archiveSha256 -or
        $expectedContentSha256 -cne $manifestCheck.ContentSha256) {
        throw "$Name artifact bytes do not match the exact hash binding."
    }

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
    if ($sourceRoot.Equals($destinationRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Context source and destination must differ."
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
        [Parameter(Mandatory = $true)][ValidateSet('None', 'BeforeCleanInstallCommit', 'AfterCleanInstallBackup', 'BeforeUpgradeCommit', 'AfterUpgradeBackup', 'BeforeRollbackCommit', 'AfterRollbackBackup')][string]$CancellationPoint,
        [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{32}$')][string]$RunId
    )

    $target = Get-AcceptanceFullPath -Path $InstallRoot
    $parent = Get-AcceptanceFullPath -Path $InstallParent
    $stage = $null
    $backup = $null
    $oldPresent = Test-Path -LiteralPath $target
    $oldMoved = $false
    $committed = $false
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

        if (Test-Path -LiteralPath $target) {
            throw "$Phase install target was unexpectedly recreated before commit: $target"
        }
        Move-Item -LiteralPath $stage -Destination $target
        $stage = $null
        $committed = $true
        $installedHashes = Assert-AcceptanceInstalledPayload -InstallRoot $target -Artifact $Artifact -Context "$Phase installed package"

        if ($null -ne $backup -and (Test-Path -LiteralPath $backup)) {
            Remove-AcceptanceOwnedSiblingDirectory -Path $backup -InstallParent $parent -Role 'backup' -RunId $RunId
            $backup = $null
        }

        return [pscustomobject][ordered]@{
            InstalledFileHashes = $installedHashes
            WasUpgrade = $oldPresent
            Committed = $committed
        }
    } catch {
        $primaryException = $_.Exception
        $cleanupException = $null
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
            } elseif (-not $oldPresent -and (Test-Path -LiteralPath $target)) {
                Remove-AcceptanceDirectoryTree -Path $target -Context "$Phase failed clean-install rollback"
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
