#requires -Version 5.1

Set-StrictMode -Version Latest

function Get-PackagingRepositoryRoot {
    return (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
}

function Get-DefaultPackageProfilePath {
    return (Join-Path $PSScriptRoot 'package-profile.json')
}

function Get-RequiredProfileProperty {
    param(
        [Parameter(Mandatory = $true)]$Profile,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $property = @($Profile.PSObject.Properties | Where-Object { $_.Name -eq $Name })
    if ($property.Count -ne 1) {
        throw "Packaging profile is missing exactly one '$Name' property."
    }

    if ($null -eq $property[0].Value) {
        throw "Packaging profile property '$Name' must not be null."
    }

    return $property[0].Value
}

function Assert-PackageVersion {
    param([Parameter(Mandatory = $true)][string]$Version)

    if ($Version -notmatch '^\d+\.\d+\.\d+$') {
        throw "Package version '$Version' must be a stable major.minor.patch version."
    }

    try {
        $parsed = [Version]$Version
    } catch {
        throw "Package version '$Version' is not a valid System.Version value."
    }

    if ($parsed.Revision -ge 0) {
        throw "Package version '$Version' must not contain a fourth numeric component."
    }
}

function Assert-PackageProfile {
    param([Parameter(Mandatory = $true)]$Profile)

    foreach ($requiredName in @(
            'schemaVersion',
            'issue',
            'productId',
            'displayName',
            'packageVersion',
            'targetFramework',
            'runtimeIdentifier',
            'configuration',
            'publishMode',
            'sourceProject',
            'deploymentModel',
            'installPathTemplate',
            'userDataPathTemplate',
            'userDataPolicy',
            'startupPolicy',
            'administratorRequired',
            'runtimeUse')) {
        Get-RequiredProfileProperty -Profile $Profile -Name $requiredName | Out-Null
    }

    if ([int]$Profile.schemaVersion -ne 1) {
        throw "Unsupported packaging profile schema: $($Profile.schemaVersion)."
    }
    if ([int]$Profile.issue -ne 38) {
        throw "Packaging profile is not bound to Issue #38: $($Profile.issue)."
    }
    if ([string]$Profile.productId -ne 'HerdrOps' -or [string]$Profile.displayName -ne 'HerdrOps') {
        throw 'Packaging profile product identity must be HerdrOps.'
    }

    Assert-PackageVersion -Version ([string]$Profile.packageVersion)
    if ([string]$Profile.targetFramework -ne 'net10.0-windows') {
        throw "Packaging profile target framework is not net10.0-windows: $($Profile.targetFramework)."
    }
    if ([string]$Profile.runtimeIdentifier -ne 'win-x64') {
        throw "Packaging profile runtime identifier is not win-x64: $($Profile.runtimeIdentifier)."
    }
    if ([string]$Profile.configuration -ne 'Release') {
        throw "Packaging profile configuration must be Release: $($Profile.configuration)."
    }
    if ([string]$Profile.publishMode -ne 'self-contained') {
        throw "Packaging profile publish mode must be self-contained: $($Profile.publishMode)."
    }
    if ([string]$Profile.deploymentModel -ne 'per-user-directory') {
        throw "Unsupported deployment model: $($Profile.deploymentModel)."
    }
    if ([string]$Profile.installPathTemplate -ne '%LOCALAPPDATA%\Programs\HerdrOps') {
        throw 'The per-user install path template has drifted.'
    }
    if ([string]$Profile.userDataPathTemplate -ne '%LOCALAPPDATA%\HerdrOps') {
        throw 'The retained user-data path template has drifted.'
    }
    if ([string]$Profile.userDataPolicy -ne 'retain-on-uninstall') {
        throw "Unsupported uninstall user-data policy: $($Profile.userDataPolicy)."
    }
    if ([string]$Profile.startupPolicy -ne 'no-startup-registration-in-preparation-slice') {
        throw 'The preparation slice must not register startup.'
    }
    if ([bool]$Profile.administratorRequired) {
        throw 'The selected per-user packaging approach must not require Administrator rights.'
    }
    if ([string]$Profile.runtimeUse -ne 'not-used') {
        throw 'Packaging preparation must not use the Herdr Runtime.'
    }

    $syntheticUpgradeProperty = @($Profile.PSObject.Properties | Where-Object { $_.Name -eq 'syntheticUpgradeVersion' })
    if ($syntheticUpgradeProperty.Count -eq 1) {
        Assert-PackageVersion -Version ([string]$syntheticUpgradeProperty[0].Value)
        if ([string]$syntheticUpgradeProperty[0].Value -eq [string]$Profile.packageVersion) {
            throw 'Synthetic upgrade version must differ from the base package version.'
        }
    }
}

function Read-PackageProfile {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = Get-FullPath -Path $Path
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "Packaging profile was not found: $fullPath"
    }

    try {
        $profile = Get-Content -LiteralPath $fullPath -Raw | ConvertFrom-Json
    } catch {
        throw "Packaging profile is not valid JSON: $fullPath. $($_.Exception.Message)"
    }

    Assert-PackageProfile -Profile $profile
    return $profile
}

function Resolve-RequestedPackageVersion {
    param(
        [Parameter(Mandatory = $true)]$Profile,
        [AllowEmptyString()][string]$RequestedVersion
    )

    $profileVersion = [string]$Profile.packageVersion
    if ([string]::IsNullOrWhiteSpace($RequestedVersion)) {
        return $profileVersion
    }

    Assert-PackageVersion -Version $RequestedVersion
    if ($RequestedVersion -cne $profileVersion) {
        throw "Requested package version '$RequestedVersion' does not match profile version '$profileVersion'."
    }

    return $RequestedVersion
}

function Get-FullPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'A path must not be empty.'
    }

    try {
        return [IO.Path]::GetFullPath($Path)
    } catch {
        throw "Path is not valid: $Path. $($_.Exception.Message)"
    }
}

function Normalize-ComparablePath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = Get-FullPath -Path $Path
    if ($fullPath.Length -gt 3) {
        return $fullPath.TrimEnd('\')
    }

    return $fullPath
}

function Test-PathWithin {
    param(
        [Parameter(Mandatory = $true)][string]$ChildPath,
        [Parameter(Mandatory = $true)][string]$RootPath
    )

    $child = Normalize-ComparablePath -Path $ChildPath
    $root = Normalize-ComparablePath -Path $RootPath
    if ($child.Equals($root, [StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    $prefix = $root.TrimEnd('\') + '\'
    return $child.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-NoReparsePath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $current = Normalize-ComparablePath -Path $Path
    while (-not [string]::IsNullOrWhiteSpace($current)) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Reparse points are not allowed in packaging paths: $current"
            }
        }

        $parent = Split-Path -Path $current -Parent
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent.Equals($current, [StringComparison]::OrdinalIgnoreCase)) {
            break
        }
        $current = Normalize-ComparablePath -Path $parent
    }
}

function Assert-SafeDestination {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$AllowRepositoryChild,
        [switch]$AllowTempChild
    )

    $fullPath = Normalize-ComparablePath -Path $Path
    $repositoryRoot = Normalize-ComparablePath -Path (Get-PackagingRepositoryRoot)
    $tempRoot = Normalize-ComparablePath -Path ([IO.Path]::GetTempPath())
    $isRepositoryPath = Test-PathWithin -ChildPath $fullPath -RootPath $repositoryRoot
    $isRepositoryChild = $isRepositoryPath -and
        -not $fullPath.Equals($repositoryRoot, [StringComparison]::OrdinalIgnoreCase)
    $isTempPath = Test-PathWithin -ChildPath $fullPath -RootPath $tempRoot
    $isTempChild = $isTempPath -and
        -not $fullPath.Equals($tempRoot, [StringComparison]::OrdinalIgnoreCase)

    if ((-not $AllowRepositoryChild -or -not $isRepositoryChild) -and
        (-not $AllowTempChild -or -not $isTempChild)) {
        throw "Unsafe packaging destination '$fullPath'. Only a repository child or generated temp child is allowed."
    }

    if ($isTempChild -and $AllowTempChild) {
        Assert-NoReparsePath -Path $fullPath
        return $fullPath
    }

    foreach ($protectedRoot in @(
            [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles),
            [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFilesX86),
            [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData),
            [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData),
            [Environment]::GetFolderPath([Environment+SpecialFolder]::ApplicationData),
            [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile),
            [Environment]::GetFolderPath([Environment+SpecialFolder]::Windows))) {
        if (-not [string]::IsNullOrWhiteSpace($protectedRoot) -and
            (Test-PathWithin -ChildPath $fullPath -RootPath $protectedRoot)) {
            throw "Packaging destination is inside a protected live Windows path: $fullPath"
        }
    }

    Assert-NoReparsePath -Path $fullPath
    return $fullPath
}

function New-PackagingTempDirectory {
    param([Parameter(Mandatory = $true)][string]$Prefix)

    if ($Prefix -notmatch '^HerdrOps-[A-Za-z0-9-]+-$') {
        throw "Invalid temporary directory prefix: $Prefix"
    }

    $tempRoot = Normalize-ComparablePath -Path ([IO.Path]::GetTempPath())
    for ($attempt = 0; $attempt -lt 10; $attempt++) {
        $candidate = Join-Path $tempRoot ($Prefix + [Guid]::NewGuid().ToString('N'))
        Assert-SafeDestination -Path $candidate -AllowTempChild | Out-Null
        if (-not (Test-Path -LiteralPath $candidate)) {
            New-Item -ItemType Directory -Path $candidate -Force | Out-Null
            return (Normalize-ComparablePath -Path $candidate)
        }
    }

    throw 'Could not create a unique packaging temp directory.'
}

function Remove-PackagingTempDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = Normalize-ComparablePath -Path $Path
    $tempRoot = Normalize-ComparablePath -Path ([IO.Path]::GetTempPath())
    if (-not (Test-PathWithin -ChildPath $fullPath -RootPath $tempRoot) -or
        $fullPath.Equals($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
        ([IO.Path]::GetFileName($fullPath) -notmatch '^HerdrOps-[A-Za-z0-9-]+-[0-9a-f]{32}$')) {
        throw "Refusing to remove a non-owned packaging temp directory: $fullPath"
    }
    if (Test-Path -LiteralPath $fullPath) {
        Assert-NoReparsePath -Path $fullPath
        Remove-Item -LiteralPath $fullPath -Recurse -Force
    }
}

function Write-DeterministicTextFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text
    )

    $normalized = $Text -replace "`r`n", "`n"
    $normalized = $normalized -replace "`r", "`n"
    if (-not $normalized.EndsWith("`n", [StringComparison]::Ordinal)) {
        $normalized += "`n"
    }

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText((Get-FullPath -Path $Path), $normalized, $encoding)
}

function Get-Sha256ForBytes {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($algorithm.ComputeHash($Bytes))).Replace('-', '').ToUpperInvariant()
    } finally {
        $algorithm.Dispose()
    }
}

function Get-Sha256ForText {
    param([Parameter(Mandatory = $true)][string]$Text)

    $encoding = New-Object System.Text.UTF8Encoding($false)
    return Get-Sha256ForBytes -Bytes $encoding.GetBytes($Text)
}

function Get-SafeRelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$RootPath,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $root = Normalize-ComparablePath -Path $RootPath
    $fullPath = Normalize-ComparablePath -Path $Path
    if (-not (Test-PathWithin -ChildPath $fullPath -RootPath $root) -or
        $fullPath.Equals($root, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path is outside the package root: $fullPath"
    }

    $relative = $fullPath.Substring($root.TrimEnd('\').Length).TrimStart('\').Replace('\', '/')
    if ([string]::IsNullOrWhiteSpace($relative) -or
        $relative.StartsWith('/', [StringComparison]::Ordinal) -or
        $relative -match '(^|/)\.\.(/|$)' -or
        [IO.Path]::IsPathRooted($relative)) {
        throw "Unsafe relative package path: $relative"
    }

    return $relative
}

function Sort-PackageEntriesOrdinal {
    param([Parameter(Mandatory = $true)]$Entries)

    $sorted = New-Object System.Collections.ArrayList
    foreach ($entry in @($Entries)) {
        $insertIndex = $sorted.Count
        for ($index = 0; $index -lt $sorted.Count; $index++) {
            if ([StringComparer]::Ordinal.Compare([string]$entry.Path, [string]$sorted[$index].Path) -lt 0) {
                $insertIndex = $index
                break
            }
        }
        [void]$sorted.Insert($insertIndex, $entry)
    }

    return @($sorted.ToArray())
}

function Get-PackageEntries {
    param(
        [Parameter(Mandatory = $true)][string]$PackageRoot,
        [string[]]$ExcludeRelativePath = @()
    )

    $root = Normalize-ComparablePath -Path $PackageRoot
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        throw "Package root directory was not found: $root"
    }
    Assert-NoReparsePath -Path $root

    $entries = @()
    foreach ($item in @(Get-ChildItem -LiteralPath $root -Recurse -Force)) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Reparse points are not allowed in package content: $($item.FullName)"
        }
        if ($item.PSIsContainer) {
            continue
        }

        $relative = Get-SafeRelativePath -RootPath $root -Path $item.FullName
        $excluded = @($ExcludeRelativePath | Where-Object {
                $_ -and $_.Replace('\', '/').Equals($relative, [StringComparison]::OrdinalIgnoreCase)
            })
        if ($excluded.Count -gt 0) {
            continue
        }

        $entries += [pscustomobject][ordered]@{
            Path = $relative
            Length = [int64]$item.Length
            Sha256 = ((Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash).ToUpperInvariant()
        }
    }

    return @(Sort-PackageEntriesOrdinal -Entries $entries)
}

function Get-CanonicalPackageContentText {
    param([Parameter(Mandatory = $true)]$Entries)

    $builder = New-Object System.Text.StringBuilder
    foreach ($entry in @(Sort-PackageEntriesOrdinal -Entries $Entries)) {
        [void]$builder.Append([string]$entry.Path)
        [void]$builder.Append("`t")
        [void]$builder.Append([string]$entry.Length)
        [void]$builder.Append("`t")
        [void]$builder.Append([string]$entry.Sha256)
        [void]$builder.Append("`n")
    }

    return $builder.ToString()
}

function New-PackageManifestObject {
    param(
        [Parameter(Mandatory = $true)]$Profile,
        [Parameter(Mandatory = $true)][string]$PackageRoot
    )

    Assert-PackageProfile -Profile $Profile
    $entries = @(Get-PackageEntries -PackageRoot $PackageRoot -ExcludeRelativePath @('package-manifest.json'))
    $canonical = Get-CanonicalPackageContentText -Entries $entries
    $manifestFiles = @($entries | ForEach-Object {
            [ordered]@{
                path = [string]$_.Path
                length = [int64]$_.Length
                sha256 = [string]$_.Sha256
            }
        })

    return [ordered]@{
        schemaVersion = 1
        issue = [int]$Profile.issue
        productId = [string]$Profile.productId
        packageVersion = [string]$Profile.packageVersion
        targetFramework = [string]$Profile.targetFramework
        runtimeIdentifier = [string]$Profile.runtimeIdentifier
        deploymentModel = [string]$Profile.deploymentModel
        userDataPolicy = [string]$Profile.userDataPolicy
        contentHashAlgorithm = 'SHA-256'
        fileCount = $manifestFiles.Count
        totalBytes = [int64](($entries | Measure-Object -Property Length -Sum).Sum)
        contentSha256 = Get-Sha256ForText -Text $canonical
        files = $manifestFiles
        evidenceClass = 'Static'
    }
}

function ConvertTo-JsonStringLiteral {
    param([Parameter(Mandatory = $true)][string]$Value)

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    foreach ($character in $Value.ToCharArray()) {
        $code = [int][char]$character
        switch ($code) {
            8 { [void]$builder.Append('\b'); continue }
            9 { [void]$builder.Append('\t'); continue }
            10 { [void]$builder.Append('\n'); continue }
            12 { [void]$builder.Append('\f'); continue }
            13 { [void]$builder.Append('\r'); continue }
            34 { [void]$builder.Append('\"'); continue }
            92 { [void]$builder.Append('\\'); continue }
            default {
                if ($code -lt 32) {
                    [void]$builder.Append(('\u{0:X4}' -f $code))
                } else {
                    [void]$builder.Append($character)
                }
            }
        }
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function ConvertTo-CanonicalPackageManifestJson {
    param([Parameter(Mandatory = $true)]$Manifest)

    $lines = @()
    $lines += '{'
    $lines += ('  "schemaVersion": ' + [int]$Manifest.schemaVersion + ',')
    $lines += ('  "issue": ' + [int]$Manifest.issue + ',')
    $lines += ('  "productId": ' + (ConvertTo-JsonStringLiteral -Value ([string]$Manifest.productId)) + ',')
    $lines += ('  "packageVersion": ' + (ConvertTo-JsonStringLiteral -Value ([string]$Manifest.packageVersion)) + ',')
    $lines += ('  "targetFramework": ' + (ConvertTo-JsonStringLiteral -Value ([string]$Manifest.targetFramework)) + ',')
    $lines += ('  "runtimeIdentifier": ' + (ConvertTo-JsonStringLiteral -Value ([string]$Manifest.runtimeIdentifier)) + ',')
    $lines += ('  "deploymentModel": ' + (ConvertTo-JsonStringLiteral -Value ([string]$Manifest.deploymentModel)) + ',')
    $lines += ('  "userDataPolicy": ' + (ConvertTo-JsonStringLiteral -Value ([string]$Manifest.userDataPolicy)) + ',')
    $lines += ('  "contentHashAlgorithm": ' + (ConvertTo-JsonStringLiteral -Value ([string]$Manifest.contentHashAlgorithm)) + ',')
    $lines += ('  "fileCount": ' + [int]$Manifest.fileCount + ',')
    $lines += ('  "totalBytes": ' + [int64]$Manifest.totalBytes + ',')
    $lines += ('  "contentSha256": ' + (ConvertTo-JsonStringLiteral -Value ([string]$Manifest.contentSha256)) + ',')
    $lines += '  "files": ['

    $files = @($Manifest.files)
    for ($index = 0; $index -lt $files.Count; $index++) {
        $file = $files[$index]
        $suffix = ''
        if ($index -lt ($files.Count - 1)) {
            $suffix = ','
        }
        $lines += '    {'
        $lines += ('      "path": ' + (ConvertTo-JsonStringLiteral -Value ([string]$file.path)) + ',')
        $lines += ('      "length": ' + [int64]$file.length + ',')
        $lines += ('      "sha256": ' + (ConvertTo-JsonStringLiteral -Value ([string]$file.sha256)))
        $lines += ('    }' + $suffix)
    }

    $lines += '  ],'
    $lines += ('  "evidenceClass": ' + (ConvertTo-JsonStringLiteral -Value ([string]$Manifest.evidenceClass)))
    $lines += '}'
    return ($lines -join "`n")
}

function Write-PackageManifest {
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)][string]$PackageRoot
    )

    $manifestPath = Join-Path (Normalize-ComparablePath -Path $PackageRoot) 'package-manifest.json'
    if (Test-Path -LiteralPath $manifestPath) {
        throw "Refusing to overwrite an existing package manifest: $manifestPath"
    }

    $json = ConvertTo-CanonicalPackageManifestJson -Manifest $Manifest
    Write-DeterministicTextFile -Path $manifestPath -Text $json
    return $manifestPath
}

function Read-PackageManifest {
    param([Parameter(Mandatory = $true)][string]$PackageRoot)

    $manifestPath = Join-Path (Normalize-ComparablePath -Path $PackageRoot) 'package-manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Package manifest was not found: $manifestPath"
    }

    try {
        return Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    } catch {
        throw "Package manifest is not valid JSON: $manifestPath. $($_.Exception.Message)"
    }
}

function Assert-PackageManifestMatchesRoot {
    param(
        [Parameter(Mandatory = $true)]$Profile,
        [Parameter(Mandatory = $true)][string]$PackageRoot
    )

    $manifest = Read-PackageManifest -PackageRoot $PackageRoot
    Assert-PackageProfile -Profile $Profile
    if ([string]$manifest.productId -cne [string]$Profile.productId -or
        [string]$manifest.packageVersion -cne [string]$Profile.packageVersion -or
        [string]$manifest.runtimeIdentifier -cne [string]$Profile.runtimeIdentifier) {
        throw 'Package manifest identity does not match its profile.'
    }

    $actualEntries = @(Get-PackageEntries -PackageRoot $PackageRoot -ExcludeRelativePath @('package-manifest.json'))
    $manifestEntries = @(Sort-PackageEntriesOrdinal -Entries @($manifest.files))
    if ($actualEntries.Count -ne $manifestEntries.Count -or
        [int]$manifest.fileCount -ne $manifestEntries.Count) {
        throw "Package manifest file count mismatch: manifest=$($manifestEntries.Count), actual=$($actualEntries.Count)."
    }

    for ($index = 0; $index -lt $actualEntries.Count; $index++) {
        $actual = $actualEntries[$index]
        $expected = $manifestEntries[$index]
        if ([string]$expected.path -cne [string]$actual.Path -or
            [int64]$expected.length -ne [int64]$actual.Length -or
            [string]$expected.sha256 -cne [string]$actual.Sha256) {
            throw "Package manifest entry mismatch at index $($index): $($actual.Path)."
        }
    }

    $canonical = Get-CanonicalPackageContentText -Entries $actualEntries
    $contentHash = Get-Sha256ForText -Text $canonical
    if ([string]$manifest.contentSha256 -cne $contentHash) {
        throw 'Package manifest contentSha256 does not match the current package bytes.'
    }
    return $manifest
}

function Copy-SafeDirectoryContents {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [switch]$Overwrite
    )

    $sourceRoot = Normalize-ComparablePath -Path $Source
    $destinationRoot = Normalize-ComparablePath -Path $Destination
    if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) {
        throw "Copy source directory was not found: $sourceRoot"
    }
    Assert-NoReparsePath -Path $sourceRoot
    Assert-SafeDestination -Path $destinationRoot -AllowRepositoryChild -AllowTempChild | Out-Null
    if (-not (Test-Path -LiteralPath $destinationRoot)) {
        New-Item -ItemType Directory -Path $destinationRoot -Force | Out-Null
    }

    foreach ($item in @(Get-ChildItem -LiteralPath $sourceRoot -Force)) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Reparse points are not allowed during package copy: $($item.FullName)"
        }
        $destination = Join-Path $destinationRoot $item.Name
        if ($item.PSIsContainer) {
            Copy-SafeDirectoryContents -Source $item.FullName -Destination $destination -Overwrite:$Overwrite
            continue
        }

        if ((Test-Path -LiteralPath $destination) -and -not $Overwrite) {
            throw "Refusing to overwrite package destination file: $destination"
        }
        Copy-Item -LiteralPath $item.FullName -Destination $destination -Force:$Overwrite
    }
}

function Assert-ProjectMatchesPackageProfile {
    param(
        [Parameter(Mandatory = $true)]$Profile,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot
    )

    $relativeProject = ([string]$Profile.sourceProject).Replace('/', '\')
    $projectPath = Join-Path (Normalize-ComparablePath -Path $RepositoryRoot) $relativeProject
    if (-not (Test-Path -LiteralPath $projectPath -PathType Leaf)) {
        throw "Profile source project was not found: $projectPath"
    }

    try {
        [xml]$project = Get-Content -LiteralPath $projectPath -Raw
    } catch {
        throw "Source project is not valid XML: $projectPath. $($_.Exception.Message)"
    }

    $frameworks = @($project.Project.PropertyGroup.TargetFramework | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($frameworks.Count -ne 1 -or [string]$frameworks[0] -cne [string]$Profile.targetFramework) {
        throw "Source project target framework does not match packaging profile: $($frameworks -join ', ')."
    }
    $outputTypes = @($project.Project.PropertyGroup.OutputType | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($outputTypes.Count -ne 1 -or [string]$outputTypes[0] -cne 'WinExe') {
        throw 'The packaging source project must remain a WPF WinExe.'
    }
    $wpfValues = @($project.Project.PropertyGroup.UseWPF | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($wpfValues.Count -ne 1 -or [string]$wpfValues[0] -cne 'true') {
        throw 'The packaging source project must keep UseWPF=true.'
    }
}

function Assert-PublishedVersionIdentity {
    param(
        [Parameter(Mandatory = $true)]$Profile,
        [Parameter(Mandatory = $true)][string]$PublishRoot
    )

    $assemblyPath = Join-Path (Normalize-ComparablePath -Path $PublishRoot) 'HerdrOps.App.dll'
    if (-not (Test-Path -LiteralPath $assemblyPath -PathType Leaf)) {
        throw "Published WPF assembly was not found: $assemblyPath"
    }

    $expected = [Version]$Profile.packageVersion
    try {
        $assemblyVersion = [Reflection.AssemblyName]::GetAssemblyName($assemblyPath).Version
    } catch {
        throw "Could not read the published assembly identity: $assemblyPath. $($_.Exception.Message)"
    }
    if ($null -eq $assemblyVersion -or
        $assemblyVersion.Major -ne $expected.Major -or
        $assemblyVersion.Minor -ne $expected.Minor -or
        $assemblyVersion.Build -ne $expected.Build) {
        throw "Published assembly version '$assemblyVersion' does not match package version '$($Profile.packageVersion)'."
    }

    $fileVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($assemblyPath).FileVersion
    if ([string]::IsNullOrWhiteSpace($fileVersion) -or $fileVersion -notmatch '^\d+\.\d+\.\d+\.\d+$') {
        throw "Published assembly file version is missing or malformed: '$fileVersion'."
    }
    $fileVersionParsed = [Version]$fileVersion
    if ($fileVersionParsed.Major -ne $expected.Major -or
        $fileVersionParsed.Minor -ne $expected.Minor -or
        $fileVersionParsed.Build -ne $expected.Build) {
        throw "Published file version '$fileVersion' does not match package version '$($Profile.packageVersion)'."
    }
}

function Get-PackageCrc32 {
    param([Parameter(Mandatory = $true)][string]$Path)

    $crcType = 'HerdrOpsPackagingCrc32' -as [type]
    if ($null -eq $crcType) {
        Add-Type -TypeDefinition @'
using System;
using System.IO;

public static class HerdrOpsPackagingCrc32
{
    private static readonly uint[] Table = CreateTable();

    private static uint[] CreateTable()
    {
        var table = new uint[256];
        for (uint index = 0; index < table.Length; index++)
        {
            var value = index;
            for (var bit = 0; bit < 8; bit++)
            {
                value = (value & 1) == 1 ? (value >> 1) ^ 0xEDB88320u : value >> 1;
            }
            table[index] = value;
        }
        return table;
    }

    public static uint ComputeFile(string path)
    {
        var crc = 0xFFFFFFFFu;
        using (var stream = File.OpenRead(path))
        {
            var value = stream.ReadByte();
            while (value >= 0)
            {
                crc = (crc >> 8) ^ Table[(crc ^ (byte)value) & 0xFF];
                value = stream.ReadByte();
            }
        }
        return crc ^ 0xFFFFFFFFu;
    }
}
'@
        $crcType = 'HerdrOpsPackagingCrc32' -as [type]
    }
    if ($null -eq $crcType) {
        throw 'Could not load the deterministic CRC-32 helper.'
    }

    return [uint32]$crcType.GetMethod('ComputeFile').Invoke($null, [object[]]@((Get-FullPath -Path $Path)))
}

function New-DeterministicPackageArchive {
    param(
        [Parameter(Mandatory = $true)][string]$PackageRoot,
        [Parameter(Mandatory = $true)][string]$ArchivePath
    )

    $root = Normalize-ComparablePath -Path $PackageRoot
    $archive = Normalize-ComparablePath -Path $ArchivePath
    if (Test-Path -LiteralPath $archive) {
        throw "Refusing to overwrite an existing package archive: $archive"
    }
    if (Test-PathWithin -ChildPath $archive -RootPath $root) {
        throw 'The package archive must be outside the package root.'
    }

    $archiveParent = Split-Path -Path $archive -Parent
    if (-not (Test-Path -LiteralPath $archiveParent)) {
        New-Item -ItemType Directory -Path $archiveParent -Force | Out-Null
    }
    Assert-SafeDestination -Path $archive -AllowRepositoryChild -AllowTempChild | Out-Null
    $entries = @(Get-PackageEntries -PackageRoot $root)

    $archiveStream = [IO.File]::Open(
        $archive,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::ReadWrite,
        [IO.FileShare]::None)
    $writer = $null
    try {
        $writer = New-Object -TypeName System.IO.BinaryWriter -ArgumentList $archiveStream
        $centralRecords = @()
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        $fixedFlags = [uint16]0x0800
        $fixedDosTime = [uint16]0
        $fixedDosDate = [uint16]0x0021
        $copyBuffer = New-Object byte[] 1048576

        foreach ($entry in $entries) {
            $entryPath = Join-Path $root ($entry.Path.Replace('/', '\'))
            $nameBytes = $utf8.GetBytes([string]$entry.Path)
            if ($nameBytes.Length -gt [uint16]::MaxValue) {
                throw "Package entry name is too long for a ZIP archive: $($entry.Path)"
            }
            if ([int64]$entry.Length -gt [uint32]::MaxValue) {
                throw "Package entry is too large for a ZIP archive: $($entry.Path)"
            }

            $localOffset = [uint32]$writer.BaseStream.Position
            $crc32 = Get-PackageCrc32 -Path $entryPath
            $writer.Write([uint32]0x04034b50)
            $writer.Write([uint16]20)
            $writer.Write($fixedFlags)
            $writer.Write([uint16]0)
            $writer.Write($fixedDosTime)
            $writer.Write($fixedDosDate)
            $writer.Write($crc32)
            $writer.Write([uint32]$entry.Length)
            $writer.Write([uint32]$entry.Length)
            $writer.Write([uint16]$nameBytes.Length)
            $writer.Write([uint16]0)
            $writer.Write($nameBytes)

            $sourceStream = [IO.File]::OpenRead($entryPath)
            try {
                $read = $sourceStream.Read($copyBuffer, 0, $copyBuffer.Length)
                while ($read -gt 0) {
                    $writer.Write($copyBuffer, 0, $read)
                    $read = $sourceStream.Read($copyBuffer, 0, $copyBuffer.Length)
                }
            } finally {
                $sourceStream.Dispose()
            }

            $centralRecords += [pscustomobject][ordered]@{
                NameBytes = $nameBytes
                Crc32 = $crc32
                Length = [uint32]$entry.Length
                LocalOffset = $localOffset
            }
        }

        $centralOffset = [uint32]$writer.BaseStream.Position
        foreach ($record in $centralRecords) {
            $writer.Write([uint32]0x02014b50)
            $writer.Write([uint16]20)
            $writer.Write([uint16]20)
            $writer.Write($fixedFlags)
            $writer.Write([uint16]0)
            $writer.Write($fixedDosTime)
            $writer.Write($fixedDosDate)
            $writer.Write([uint32]$record.Crc32)
            $writer.Write([uint32]$record.Length)
            $writer.Write([uint32]$record.Length)
            $writer.Write([uint16]$record.NameBytes.Length)
            $writer.Write([uint16]0)
            $writer.Write([uint16]0)
            $writer.Write([uint16]0)
            $writer.Write([uint16]0)
            $writer.Write([uint32]0)
            $writer.Write([uint32]$record.LocalOffset)
            $writer.Write($record.NameBytes)
        }

        $centralSize = [uint32]($writer.BaseStream.Position - $centralOffset)
        if ($centralRecords.Count -gt [uint16]::MaxValue) {
            throw 'The package has too many entries for a classic ZIP archive.'
        }
        $writer.Write([uint32]0x06054b50)
        $writer.Write([uint16]0)
        $writer.Write([uint16]0)
        $writer.Write([uint16]$centralRecords.Count)
        $writer.Write([uint16]$centralRecords.Count)
        $writer.Write($centralSize)
        $writer.Write($centralOffset)
        $writer.Write([uint16]0)
        $writer.Flush()
    } finally {
        if ($null -ne $writer) {
            $writer.Dispose()
        } else {
            $archiveStream.Dispose()
        }
    }

    return $archive
}

function Write-PackageHashRecord {
    param(
        [Parameter(Mandatory = $true)]$Profile,
        [Parameter(Mandatory = $true)][string]$PackageRoot,
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $hashPath = Normalize-ComparablePath -Path $Path
    if (Test-Path -LiteralPath $hashPath) {
        throw "Refusing to overwrite an existing package hash record: $hashPath"
    }
    Assert-PackageManifestMatchesRoot -Profile $Profile -PackageRoot $PackageRoot | Out-Null
    $manifestPath = Join-Path (Normalize-ComparablePath -Path $PackageRoot) 'package-manifest.json'
    $manifest = Read-PackageManifest -PackageRoot $PackageRoot
    $archiveInfo = Get-Item -LiteralPath (Normalize-ComparablePath -Path $ArchivePath)
    $archiveHash = ((Get-FileHash -LiteralPath $archiveInfo.FullName -Algorithm SHA256).Hash).ToUpperInvariant()
    $manifestHash = ((Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash).ToUpperInvariant()

    $lines = @(
        'HerdrOps package integrity record',
        'SchemaVersion: 1',
        "ProductId: $($Profile.productId)",
        "PackageVersion: $($Profile.packageVersion)",
        "RuntimeIdentifier: $($Profile.runtimeIdentifier)",
        "ArchiveFile: $($archiveInfo.Name)",
        "ArchiveBytes: $($archiveInfo.Length)",
        "ArchiveSha256: $archiveHash",
        'ManifestFile: package-manifest.json',
        "ManifestBytes: $((Get-Item -LiteralPath $manifestPath).Length)",
        "ManifestSha256: $manifestHash",
        "ContentSha256: $($manifest.contentSha256)",
        'EvidenceClass: Static')
    Write-DeterministicTextFile -Path $hashPath -Text ($lines -join "`n")

    return [pscustomobject][ordered]@{
        ArchivePath = $archiveInfo.FullName
        ArchiveBytes = [int64]$archiveInfo.Length
        ArchiveSha256 = $archiveHash
        ManifestPath = (Get-FullPath -Path $manifestPath)
        ManifestBytes = [int64](Get-Item -LiteralPath $manifestPath).Length
        ManifestSha256 = $manifestHash
        ContentSha256 = [string]$manifest.contentSha256
        HashRecordPath = $hashPath
    }
}
