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
    if ([int]$Profile.issue -notin @(38, 45)) {
        throw "Packaging profile is not bound to an approved packaging issue (38 or 45): $($Profile.issue)."
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

function Assert-V070PreparationProfile {
    param([Parameter(Mandatory = $true)]$Profile)

    Assert-PackageProfile -Profile $Profile
    if ([int]$Profile.issue -ne 38 -or [string]$Profile.packageVersion -cne '0.7.0') {
        throw "Packaging preparation profiles are fenced to Issue #38 and v0.7.0: issue=$($Profile.issue), version=$($Profile.packageVersion)."
    }
}

function Skip-JsonWhitespace {
    param(
        [Parameter(Mandatory = $true)][string]$Json,
        [Parameter(Mandatory = $true)][ref]$Index
    )

    while ($Index.Value -lt $Json.Length) {
        $code = [int][char]$Json[$Index.Value]
        if ($code -ne 32 -and $code -ne 9 -and $code -ne 10 -and $code -ne 13) {
            break
        }
        $Index.Value = $Index.Value + 1
    }
}

function Read-JsonStringToken {
    param(
        [Parameter(Mandatory = $true)][string]$Json,
        [Parameter(Mandatory = $true)][ref]$Index
    )

    if ($Index.Value -ge $Json.Length -or $Json[$Index.Value] -ne '"') {
        throw 'JSON property names and string values must start with a quote.'
    }

    $builder = New-Object System.Text.StringBuilder
    $Index.Value = $Index.Value + 1
    while ($Index.Value -lt $Json.Length) {
        $character = [char]$Json[$Index.Value]
        $Index.Value = $Index.Value + 1
        if ($character -eq '"') {
            return $builder.ToString()
        }
        if ($character -eq '\') {
            if ($Index.Value -ge $Json.Length) {
                throw 'JSON string ended after an escape character.'
            }
            $escape = [char]$Json[$Index.Value]
            $Index.Value = $Index.Value + 1
            switch ($escape) {
                '"' { [void]$builder.Append('"') }
                '\' { [void]$builder.Append('\') }
                '/' { [void]$builder.Append('/') }
                'b' { [void]$builder.Append([char]8) }
                'f' { [void]$builder.Append([char]12) }
                'n' { [void]$builder.Append([char]10) }
                'r' { [void]$builder.Append([char]13) }
                't' { [void]$builder.Append([char]9) }
                'u' {
                    if ($Index.Value + 4 -gt $Json.Length) {
                        throw 'JSON Unicode escape is truncated.'
                    }
                    $hex = $Json.Substring($Index.Value, 4)
                    if ($hex -notmatch '^[0-9A-Fa-f]{4}$') {
                        throw "JSON Unicode escape is invalid: $hex"
                    }
                    [void]$builder.Append([char][Convert]::ToInt32($hex, 16))
                    $Index.Value = $Index.Value + 4
                }
                default {
                    throw "JSON string contains an invalid escape sequence: \$escape"
                }
            }
            continue
        }
        if ([int][char]$character -lt 32) {
            throw 'JSON strings must not contain unescaped control characters.'
        }
        [void]$builder.Append($character)
    }

    throw 'JSON string was not terminated.'
}

function Read-JsonValueForDuplicateScan {
    param(
        [Parameter(Mandatory = $true)][string]$Json,
        [Parameter(Mandatory = $true)][ref]$Index,
        [Parameter(Mandatory = $true)][string]$Description
    )

    Skip-JsonWhitespace -Json $Json -Index $Index
    if ($Index.Value -ge $Json.Length) {
        throw "$Description ended before a JSON value."
    }

    switch ([char]$Json[$Index.Value]) {
        '{' {
            Read-JsonObjectForDuplicateScan -Json $Json -Index $Index -Description $Description
            return
        }
        '[' {
            Read-JsonArrayForDuplicateScan -Json $Json -Index $Index -Description $Description
            return
        }
        '"' {
            [void](Read-JsonStringToken -Json $Json -Index $Index)
            return
        }
        default {
            $start = $Index.Value
            while ($Index.Value -lt $Json.Length) {
                $character = [char]$Json[$Index.Value]
                if ($character -eq ',' -or $character -eq ']' -or $character -eq '}' -or
                    [int][char]$character -eq 32 -or [int][char]$character -eq 9 -or
                    [int][char]$character -eq 10 -or [int][char]$character -eq 13) {
                    break
                }
                $Index.Value = $Index.Value + 1
            }
            if ($Index.Value -eq $start) {
                throw "$Description contains an invalid JSON value."
            }
            $token = $Json.Substring($start, $Index.Value - $start)
            if ($token -notmatch '^(true|false|null|-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?)$') {
                throw "$Description contains an invalid JSON token: $token"
            }
        }
    }
}

function Read-JsonArrayForDuplicateScan {
    param(
        [Parameter(Mandatory = $true)][string]$Json,
        [Parameter(Mandatory = $true)][ref]$Index,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $Index.Value = $Index.Value + 1
    Skip-JsonWhitespace -Json $Json -Index $Index
    if ($Index.Value -lt $Json.Length -and $Json[$Index.Value] -eq ']') {
        $Index.Value = $Index.Value + 1
        return
    }

    while ($true) {
        Read-JsonValueForDuplicateScan -Json $Json -Index $Index -Description $Description
        Skip-JsonWhitespace -Json $Json -Index $Index
        if ($Index.Value -ge $Json.Length) {
            throw "$Description array was not terminated."
        }
        if ($Json[$Index.Value] -eq ']') {
            $Index.Value = $Index.Value + 1
            return
        }
        if ($Json[$Index.Value] -ne ',') {
            throw "$Description array requires a comma or closing bracket."
        }
        $Index.Value = $Index.Value + 1
        Skip-JsonWhitespace -Json $Json -Index $Index
        if ($Index.Value -lt $Json.Length -and $Json[$Index.Value] -eq ']') {
            throw "$Description array contains a trailing comma."
        }
    }
}

function Read-JsonObjectForDuplicateScan {
    param(
        [Parameter(Mandatory = $true)][string]$Json,
        [Parameter(Mandatory = $true)][ref]$Index,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $Index.Value = $Index.Value + 1
    $propertyNames = @()
    Skip-JsonWhitespace -Json $Json -Index $Index
    if ($Index.Value -lt $Json.Length -and $Json[$Index.Value] -eq '}') {
        $Index.Value = $Index.Value + 1
        return
    }

    while ($true) {
        Skip-JsonWhitespace -Json $Json -Index $Index
        if ($Index.Value -ge $Json.Length -or $Json[$Index.Value] -ne '"') {
            throw "$Description object requires a quoted property name."
        }
        $propertyName = Read-JsonStringToken -Json $Json -Index $Index
        foreach ($existingName in @($propertyNames)) {
            if ([StringComparer]::OrdinalIgnoreCase.Equals([string]$existingName, [string]$propertyName)) {
                throw "Duplicate JSON object property '$propertyName' detected in $Description (property names are case-insensitive)."
            }
        }
        $propertyNames += $propertyName
        Skip-JsonWhitespace -Json $Json -Index $Index
        if ($Index.Value -ge $Json.Length -or $Json[$Index.Value] -ne ':') {
            throw "$Description property '$propertyName' is missing a colon."
        }
        $Index.Value = $Index.Value + 1
        Read-JsonValueForDuplicateScan -Json $Json -Index $Index -Description "$Description property '$propertyName'"
        Skip-JsonWhitespace -Json $Json -Index $Index
        if ($Index.Value -ge $Json.Length) {
            throw "$Description object was not terminated."
        }
        if ($Json[$Index.Value] -eq '}') {
            $Index.Value = $Index.Value + 1
            return
        }
        if ($Json[$Index.Value] -ne ',') {
            throw "$Description object requires a comma or closing brace."
        }
        $Index.Value = $Index.Value + 1
        Skip-JsonWhitespace -Json $Json -Index $Index
        if ($Index.Value -lt $Json.Length -and $Json[$Index.Value] -eq '}') {
            throw "$Description object contains a trailing comma."
        }
    }
}

function Assert-NoDuplicateJsonObjectProperties {
    param(
        [Parameter(Mandatory = $true)][string]$Json,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $index = 0
    Read-JsonValueForDuplicateScan -Json $Json -Index ([ref]$index) -Description $Description
    Skip-JsonWhitespace -Json $Json -Index ([ref]$index)
    if ($index -ne $Json.Length) {
        throw "$Description contains trailing JSON content."
    }
}

function ConvertFrom-StrictPackageJson {
    param(
        [Parameter(Mandatory = $true)][string]$Json,
        [Parameter(Mandatory = $true)][string]$Description
    )

    Assert-NoDuplicateJsonObjectProperties -Json $Json -Description $Description
    try {
        $convertFromJson = Get-Command ConvertFrom-Json -CommandType Cmdlet -ErrorAction Stop
        if ($convertFromJson.Parameters.ContainsKey('DateKind')) {
            return ($Json | ConvertFrom-Json -DateKind String)
        }
        return ($Json | ConvertFrom-Json)
    } catch {
        throw "$Description is not valid JSON: $($_.Exception.Message)"
    }
}

function Read-PackageProfile {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = Get-FullPath -Path $Path
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "Packaging profile was not found: $fullPath"
    }

    $profileText = [IO.File]::ReadAllText($fullPath)
    $profile = ConvertFrom-StrictPackageJson -Json $profileText -Description "Packaging profile '$fullPath'"

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

function Assert-PackagingPathsDoNotOverlap {
    param(
        [Parameter(Mandatory = $true)][object[]]$Paths
    )

    $normalizedPaths = @()
    foreach ($pathSpec in @($Paths)) {
        if ($null -eq $pathSpec) {
            throw 'A packaging path specification must not be null.'
        }
        $name = [string]$pathSpec.Name
        $path = [string]$pathSpec.Path
        if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($path)) {
            throw 'Packaging path specifications require a name and path.'
        }
        $normalizedPaths += [pscustomobject][ordered]@{
            Name = $name
            Path = Normalize-ComparablePath -Path $path
        }
    }

    for ($leftIndex = 0; $leftIndex -lt $normalizedPaths.Count; $leftIndex++) {
        for ($rightIndex = $leftIndex + 1; $rightIndex -lt $normalizedPaths.Count; $rightIndex++) {
            $left = $normalizedPaths[$leftIndex]
            $right = $normalizedPaths[$rightIndex]
            if ((Test-PathWithin -ChildPath $left.Path -RootPath $right.Path) -or
                (Test-PathWithin -ChildPath $right.Path -RootPath $left.Path)) {
                throw "Packaging paths overlap: $($left.Name) '$($left.Path)' and $($right.Name) '$($right.Path)'."
            }
        }
    }
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

function Assert-NoReparseDescendants {
    param([Parameter(Mandatory = $true)][string]$Path)

    $root = Normalize-ComparablePath -Path $Path
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        return
    }
    foreach ($item in @(Get-ChildItem -LiteralPath $root -Recurse -Force)) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Reparse points are not allowed inside packaging generations: $($item.FullName)"
        }
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
        Assert-NoReparseDescendants -Path $fullPath
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

function Get-PackagingFileLength {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = Get-FullPath -Path $Path
    if (-not [IO.File]::Exists($fullPath)) {
        throw "Packaging file was not found: $fullPath"
    }
    $stream = [IO.File]::OpenRead($fullPath)
    try {
        return [int64]$stream.Length
    } finally {
        $stream.Dispose()
    }
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
        [Parameter(Mandatory = $true)][string]$PackageRoot,
        [string]$TestFaultInjectionStage = 'None',
        [switch]$TestInjectCleanupFailure
    )

    $safePackageRoot = Assert-SafeDestination -Path $PackageRoot -AllowRepositoryChild -AllowTempChild
    if (-not (Test-Path -LiteralPath $safePackageRoot -PathType Container)) {
        throw "Package root directory was not found: $safePackageRoot"
    }
    $manifestPath = Join-Path $safePackageRoot 'package-manifest.json'
    $json = ConvertTo-CanonicalPackageManifestJson -Manifest $Manifest
    $encoding = New-Object System.Text.UTF8Encoding($false)
    $bytes = $encoding.GetBytes(($json + "`n"))
    return Invoke-PackagingAtomicFileWrite `
        -DestinationPath $manifestPath `
        -OperationName 'package manifest' `
        -TestFaultInjectionStage $TestFaultInjectionStage `
        -TestInjectCleanupFailure:$TestInjectCleanupFailure `
        -WriteStagedFile {
            param($stagingPath, $faultStage)
            Write-PackagingBytesToStagingFile `
                -Path $stagingPath `
                -Bytes $bytes `
                -OperationName 'package manifest' `
                -TestFaultInjectionStage $faultStage
        }
}

function Read-PackageManifest {
    param([Parameter(Mandatory = $true)][string]$PackageRoot)

    $manifestPath = Join-Path (Normalize-ComparablePath -Path $PackageRoot) 'package-manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Package manifest was not found: $manifestPath"
    }

    $manifestText = [IO.File]::ReadAllText($manifestPath)
    return (ConvertFrom-StrictPackageJson -Json $manifestText -Description "Package manifest '$manifestPath'")
}

function Get-RequiredManifestProperty {
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $property = @($Manifest.PSObject.Properties | Where-Object { $_.Name -eq $Name })
    if ($property.Count -ne 1 -or $null -eq $property[0].Value) {
        throw "Package manifest is missing exactly one non-null '$Name' property."
    }

    return $property[0].Value
}

function Assert-ExactJsonPropertyOrder {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string[]]$ExpectedNames,
        [Parameter(Mandatory = $true)][string]$Description
    )

    if ($null -eq $Object -or $Object -is [string] -or $Object -is [array]) {
        throw "$Description must be a JSON object."
    }
    $actualNames = @($Object.PSObject.Properties | ForEach-Object { [string]$_.Name })
    if ($actualNames.Count -ne $ExpectedNames.Count) {
        throw "$Description has an unknown, missing, or duplicate property."
    }
    for ($index = 0; $index -lt $ExpectedNames.Count; $index++) {
        if ($actualNames[$index] -cne $ExpectedNames[$index]) {
            throw "$Description property order or names are not canonical at index $index."
        }
    }
}

function Assert-JsonIntegerValue {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Value -or $Value -is [string] -or $Value -is [bool]) {
        $typeName = if ($null -eq $Value) { 'null' } else { $Value.GetType().Name }
        throw "Package manifest property '$Name' must be a JSON integer, not $typeName."
    }
    $typeName = $Value.GetType().FullName
    if ($typeName -notin @(
            'System.Byte',
            'System.SByte',
            'System.Int16',
            'System.UInt16',
            'System.Int32',
            'System.UInt32',
            'System.Int64',
            'System.UInt64')) {
        throw "Package manifest property '$Name' must be a JSON integer, not $typeName."
    }
}

function Assert-JsonStringValue {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Value -or $Value -isnot [string]) {
        $typeName = if ($null -eq $Value) { 'null' } else { $Value.GetType().Name }
        throw "Package manifest property '$Name' must be a JSON string, not $typeName."
    }
    if ([string]::IsNullOrWhiteSpace([string]$Value)) {
        throw "Package manifest property '$Name' must not be empty."
    }
}

function Assert-PackageManifestMatchesRoot {
    param(
        [Parameter(Mandatory = $true)]$Profile,
        [Parameter(Mandatory = $true)][string]$PackageRoot
    )

    $manifest = Read-PackageManifest -PackageRoot $PackageRoot
    Assert-PackageProfile -Profile $Profile
    $manifestPath = Join-Path (Normalize-ComparablePath -Path $PackageRoot) 'package-manifest.json'
    $manifestText = [IO.File]::ReadAllText($manifestPath)
    Assert-ExactJsonPropertyOrder -Object $manifest -ExpectedNames @(
        'schemaVersion',
        'issue',
        'productId',
        'packageVersion',
        'targetFramework',
        'runtimeIdentifier',
        'deploymentModel',
        'userDataPolicy',
        'contentHashAlgorithm',
        'fileCount',
        'totalBytes',
        'contentSha256',
        'files',
        'evidenceClass') -Description 'Package manifest'

    $manifestSchemaVersion = Get-RequiredManifestProperty -Manifest $manifest -Name 'schemaVersion'
    $manifestIssue = Get-RequiredManifestProperty -Manifest $manifest -Name 'issue'
    $manifestProductId = Get-RequiredManifestProperty -Manifest $manifest -Name 'productId'
    $manifestPackageVersion = Get-RequiredManifestProperty -Manifest $manifest -Name 'packageVersion'
    $manifestTargetFramework = Get-RequiredManifestProperty -Manifest $manifest -Name 'targetFramework'
    $manifestRuntimeIdentifier = Get-RequiredManifestProperty -Manifest $manifest -Name 'runtimeIdentifier'
    $manifestDeploymentModel = Get-RequiredManifestProperty -Manifest $manifest -Name 'deploymentModel'
    $manifestUserDataPolicy = Get-RequiredManifestProperty -Manifest $manifest -Name 'userDataPolicy'
    $manifestContentHashAlgorithm = Get-RequiredManifestProperty -Manifest $manifest -Name 'contentHashAlgorithm'
    $manifestFileCount = Get-RequiredManifestProperty -Manifest $manifest -Name 'fileCount'
    $manifestTotalBytes = Get-RequiredManifestProperty -Manifest $manifest -Name 'totalBytes'
    $manifestContentSha256 = Get-RequiredManifestProperty -Manifest $manifest -Name 'contentSha256'
    $manifestFiles = Get-RequiredManifestProperty -Manifest $manifest -Name 'files'
    $manifestEvidenceClass = Get-RequiredManifestProperty -Manifest $manifest -Name 'evidenceClass'

    foreach ($numericProperty in @(
            @{ Name = 'schemaVersion'; Value = $manifestSchemaVersion },
            @{ Name = 'issue'; Value = $manifestIssue },
            @{ Name = 'fileCount'; Value = $manifestFileCount },
            @{ Name = 'totalBytes'; Value = $manifestTotalBytes })) {
        Assert-JsonIntegerValue -Value $numericProperty.Value -Name $numericProperty.Name
    }
    foreach ($stringProperty in @(
            @{ Name = 'productId'; Value = $manifestProductId },
            @{ Name = 'packageVersion'; Value = $manifestPackageVersion },
            @{ Name = 'targetFramework'; Value = $manifestTargetFramework },
            @{ Name = 'runtimeIdentifier'; Value = $manifestRuntimeIdentifier },
            @{ Name = 'deploymentModel'; Value = $manifestDeploymentModel },
            @{ Name = 'userDataPolicy'; Value = $manifestUserDataPolicy },
            @{ Name = 'contentHashAlgorithm'; Value = $manifestContentHashAlgorithm },
            @{ Name = 'contentSha256'; Value = $manifestContentSha256 },
            @{ Name = 'evidenceClass'; Value = $manifestEvidenceClass })) {
        Assert-JsonStringValue -Value $stringProperty.Value -Name $stringProperty.Name
    }
    if ($manifestText -notmatch '"files"\s*:\s*\[') {
        throw 'Package manifest files must be a JSON array.'
    }
    $manifestFiles = @($manifestFiles)

    if ([int64]$manifestSchemaVersion -ne 1 -or
        [int64]$manifestIssue -ne [int64]$Profile.issue -or
        [string]$manifestProductId -cne [string]$Profile.productId -or
        [string]$manifestPackageVersion -cne [string]$Profile.packageVersion -or
        [string]$manifestTargetFramework -cne [string]$Profile.targetFramework -or
        [string]$manifestRuntimeIdentifier -cne [string]$Profile.runtimeIdentifier -or
        [string]$manifestDeploymentModel -cne [string]$Profile.deploymentModel -or
        [string]$manifestUserDataPolicy -cne [string]$Profile.userDataPolicy -or
        [string]$manifestContentHashAlgorithm -cne 'SHA-256' -or
        [string]$manifestEvidenceClass -cne 'Static') {
        throw 'Package manifest metadata does not match the authorized package profile.'
    }

    $actualEntries = @(Get-PackageEntries -PackageRoot $PackageRoot -ExcludeRelativePath @('package-manifest.json'))
    $manifestEntries = @($manifestFiles)
    for ($index = 0; $index -lt $manifestEntries.Count; $index++) {
        $manifestEntry = $manifestEntries[$index]
        Assert-ExactJsonPropertyOrder -Object $manifestEntry -ExpectedNames @('path', 'length', 'sha256') -Description "Package manifest file entry $index"
        $manifestPath = Get-RequiredManifestProperty -Manifest $manifestEntry -Name 'path'
        $manifestLength = Get-RequiredManifestProperty -Manifest $manifestEntry -Name 'length'
        $manifestSha256 = Get-RequiredManifestProperty -Manifest $manifestEntry -Name 'sha256'
        Assert-JsonStringValue -Value $manifestPath -Name "files[$index].path"
        Assert-JsonIntegerValue -Value $manifestLength -Name "files[$index].length"
        Assert-JsonStringValue -Value $manifestSha256 -Name "files[$index].sha256"
        if ([int64]$manifestLength -lt 0 -or [string]$manifestSha256 -notmatch '^[0-9A-Fa-f]{64}$') {
            throw "Package manifest file entry $index has invalid length or SHA-256."
        }
    }
    $actualTotalBytes = [int64](($actualEntries | Measure-Object -Property Length -Sum).Sum)
    if ($actualEntries.Count -ne $manifestEntries.Count -or
        [int64]$manifestFileCount -ne [int64]$manifestEntries.Count -or
        [int64]$manifestTotalBytes -ne $actualTotalBytes) {
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
    if ([string]$manifestContentSha256 -cne $contentHash) {
        throw 'Package manifest contentSha256 does not match the current package bytes.'
    }
    return $manifest
}

function Copy-PackagingFileDurably {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [switch]$Overwrite,
        [string]$TestFaultInjectionStage = 'None',
        [switch]$TestInjectCleanupFailure
    )

    if ($TestFaultInjectionStage -notin @(
            'None',
            'Write',
            'Verify',
            'Replace',
            'AfterReplace',
            'Delete')) {
        throw "Unsupported durable copy fault-injection stage: $TestFaultInjectionStage"
    }

    $sourcePath = Normalize-ComparablePath -Path $Source
    $destinationPath = Normalize-ComparablePath -Path $Destination
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw "Copy source file was not found: $sourcePath"
    }
    Assert-NoReparsePath -Path $sourcePath
    Assert-PackagingPathsDoNotOverlap -Paths @(
        [pscustomobject]@{ Name = 'copy source'; Path = $sourcePath },
        [pscustomobject]@{ Name = 'copy destination'; Path = $destinationPath })

    $destinationExistsAtStart = Test-Path -LiteralPath $destinationPath -PathType Leaf
    if ((Test-Path -LiteralPath $destinationPath) -and -not $destinationExistsAtStart) {
        throw "Copy destination is not a file: $destinationPath"
    }
    if ($destinationExistsAtStart -and -not $Overwrite) {
        throw "Refusing to overwrite package destination file: $destinationPath"
    }
    $destinationParent = Split-Path -Path $destinationPath -Parent
    if (-not (Test-Path -LiteralPath $destinationParent -PathType Container)) {
        throw "Copy destination parent was not found: $destinationParent"
    }
    Assert-NoReparsePath -Path $destinationParent

    $stagingPath = New-PackagingStagingFilePath -DestinationPath $destinationPath
    $backupPath = $null
    if ($destinationExistsAtStart) {
        $backupPath = New-PackagingBackupFilePath -DestinationPath $destinationPath
    }
    $pathSpecs = @(
        [pscustomobject]@{ Name = 'copy source'; Path = $sourcePath },
        [pscustomobject]@{ Name = 'copy destination'; Path = $destinationPath },
        [pscustomobject]@{ Name = 'copy staging'; Path = $stagingPath })
    if ($null -ne $backupPath) {
        $pathSpecs += [pscustomobject]@{ Name = 'copy backup'; Path = $backupPath }
    }
    Assert-PackagingPathsDoNotOverlap -Paths $pathSpecs

    $sourceHashBefore = ((Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash).ToUpperInvariant()
    $sourceLengthBefore = Get-PackagingFileLength -Path $sourcePath
    $sourceStream = $null
    $stagingStream = $null
    $primaryError = $null
    $cleanupErrors = @()
    $destinationReplaced = $false
    $destinationMoved = $false
    $committed = $false
    $rollbackPath = $null
    try {
        try {
            $sourceStream = [IO.File]::Open(
                $sourcePath,
                [IO.FileMode]::Open,
                [IO.FileAccess]::Read,
                [IO.FileShare]::Read)
            $stagingStream = [IO.File]::Open(
                $stagingPath,
                [IO.FileMode]::CreateNew,
                [IO.FileAccess]::Write,
                [IO.FileShare]::None)
            $buffer = New-Object byte[] 1048576
            $read = $sourceStream.Read($buffer, 0, $buffer.Length)
            while ($read -gt 0) {
                $stagingStream.Write($buffer, 0, $read)
                if ($TestFaultInjectionStage -eq 'Write') {
                    throw 'Injected durable copy write failure.'
                }
                $read = $sourceStream.Read($buffer, 0, $buffer.Length)
            }
            $stagingStream.Flush($true)
        } catch {
            $primaryError = $_
        }

        $disposeErrors = @()
        if ($null -ne $stagingStream) {
            try {
                $stagingStream.Dispose()
            } catch {
                $disposeErrors += $_
            }
            $stagingStream = $null
        }
        if ($null -ne $sourceStream) {
            try {
                $sourceStream.Dispose()
            } catch {
                $disposeErrors += $_
            }
            $sourceStream = $null
        }
        if ($disposeErrors.Count -gt 0) {
            if ($null -eq $primaryError) {
                $primaryError = $disposeErrors[0]
                if ($disposeErrors.Count -gt 1) {
                    $cleanupErrors += @($disposeErrors | Select-Object -Skip 1)
                }
            } else {
                $cleanupErrors += $disposeErrors
            }
        }

        if ($null -eq $primaryError) {
            if (-not (Test-Path -LiteralPath $stagingPath -PathType Leaf)) {
                throw "Durable copy writer did not create its staging file: $stagingPath"
            }
            $sourceHashAfter = ((Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash).ToUpperInvariant()
            $sourceLengthAfter = Get-PackagingFileLength -Path $sourcePath
            $stagingLength = Get-PackagingFileLength -Path $stagingPath
            $stagingHash = ((Get-FileHash -LiteralPath $stagingPath -Algorithm SHA256).Hash).ToUpperInvariant()
            if ($TestFaultInjectionStage -eq 'Verify') {
                throw 'Injected durable copy verification failure.'
            }
            if ($sourceHashBefore -cne $sourceHashAfter -or $sourceLengthBefore -ne $sourceLengthAfter) {
                throw "Copy source changed during durable copy: $sourcePath"
            }
            if ([int64]$stagingLength -ne $sourceLengthBefore -or
                $stagingHash -cne $sourceHashBefore) {
                throw "Durable staged copy verification failed for '$stagingPath'."
            }

            if (Test-Path -LiteralPath $destinationPath -PathType Leaf) {
                if (-not $destinationExistsAtStart -or -not $Overwrite) {
                    throw "Refusing to overwrite a package destination file that appeared during copy: $destinationPath"
                }
            } elseif (Test-Path -LiteralPath $destinationPath) {
                throw "Copy destination changed into a non-file: $destinationPath"
            }

            if ($TestFaultInjectionStage -eq 'Replace') {
                throw 'Injected durable copy replace failure.'
            }
            if ($destinationExistsAtStart) {
                [IO.File]::Replace($stagingPath, $destinationPath, $backupPath, $true)
                $destinationReplaced = $true
            } else {
                [IO.File]::Move($stagingPath, $destinationPath)
                $destinationMoved = $true
            }
            if ($TestFaultInjectionStage -eq 'AfterReplace') {
                throw 'Injected durable copy post-replace failure.'
            }

            Assert-PackagingFileMatchesSource -Source $sourcePath -Destination $destinationPath -Description 'durable copy destination'
            if ($TestFaultInjectionStage -eq 'Delete') {
                if (-not $destinationExistsAtStart) {
                    throw 'Injected durable copy delete failure requires an overwrite destination.'
                }
                throw 'Injected durable copy backup delete failure.'
            }
            if ($destinationExistsAtStart -and (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
                [IO.File]::Delete($backupPath)
            }
            $committed = $true
        }
    } catch {
        if ($null -eq $primaryError) {
            $primaryError = $_
        } else {
            $cleanupErrors += $_
        }
    }

    if (-not $destinationReplaced -and $destinationExistsAtStart -and
        (Test-Path -LiteralPath $backupPath -PathType Leaf) -and
        (Test-Path -LiteralPath $destinationPath -PathType Leaf)) {
        $destinationReplaced = $true
    }
    if (-not $destinationMoved -and -not $destinationExistsAtStart -and
        -not (Test-Path -LiteralPath $stagingPath) -and
        (Test-Path -LiteralPath $destinationPath -PathType Leaf)) {
        $destinationMoved = $true
    }

    if ($null -ne $primaryError -and -not $committed) {
        try {
            if ($destinationReplaced -and (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
                $rollbackPath = New-PackagingBackupFilePath -DestinationPath $destinationPath
                [IO.File]::Replace($backupPath, $destinationPath, $rollbackPath, $true)
                if (Test-Path -LiteralPath $rollbackPath -PathType Leaf) {
                    [IO.File]::Delete($rollbackPath)
                }
            } elseif ($destinationMoved -and -not $destinationExistsAtStart -and
                (Test-Path -LiteralPath $destinationPath -PathType Leaf)) {
                $rollbackPath = New-PackagingBackupFilePath -DestinationPath $destinationPath
                [IO.File]::Move($destinationPath, $rollbackPath)
                if (Test-Path -LiteralPath $rollbackPath -PathType Leaf) {
                    [IO.File]::Delete($rollbackPath)
                }
            }
        } catch {
            $cleanupErrors += $_
        }
    }

    try {
        if (Test-Path -LiteralPath $stagingPath -PathType Leaf) {
            Remove-PackagingStagingFile -Path $stagingPath
        }
    } catch {
        $cleanupErrors += $_
    }
    try {
        if ($TestInjectCleanupFailure) {
            throw 'Injected durable copy cleanup failure.'
        }
    } catch {
        $cleanupErrors += $_
    }

    if ($null -ne $primaryError -or $cleanupErrors.Count -gt 0) {
        Throw-PackagingFailure -PrimaryError $primaryError -CleanupErrors $cleanupErrors
    }

    return $destinationPath
}

function Assert-PackagingFileMatchesSource {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $sourcePath = Normalize-ComparablePath -Path $Source
    $destinationPath = Normalize-ComparablePath -Path $Destination
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $destinationPath -PathType Leaf)) {
        throw "Post-copy verification file is missing for $Description."
    }
    $sourceLength = Get-PackagingFileLength -Path $sourcePath
    $destinationLength = Get-PackagingFileLength -Path $destinationPath
    $sourceHash = ((Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash).ToUpperInvariant()
    $destinationHash = ((Get-FileHash -LiteralPath $destinationPath -Algorithm SHA256).Hash).ToUpperInvariant()
    if ([int64]$sourceLength -ne [int64]$destinationLength -or
        $sourceHash -cne $destinationHash) {
        throw "Post-copy hash verification failed for $Description."
    }
}

function Assert-PackagingDirectoryMatchesSource {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $sourceEntries = @(Get-PackageEntries -PackageRoot $Source)
    $destinationEntries = @(Get-PackageEntries -PackageRoot $Destination)
    if ($sourceEntries.Count -ne $destinationEntries.Count) {
        throw "Post-copy file count verification failed for $Description."
    }
    for ($index = 0; $index -lt $sourceEntries.Count; $index++) {
        $sourceEntry = $sourceEntries[$index]
        $destinationEntry = $destinationEntries[$index]
        if ([string]$sourceEntry.Path -cne [string]$destinationEntry.Path -or
            [int64]$sourceEntry.Length -ne [int64]$destinationEntry.Length -or
            [string]$sourceEntry.Sha256 -cne [string]$destinationEntry.Sha256) {
            throw "Post-copy hash verification failed for $Description at '$($sourceEntry.Path)'."
        }
    }
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
    Assert-PackagingPathsDoNotOverlap -Paths @(
        [pscustomobject]@{ Name = 'copy source'; Path = $sourceRoot },
        [pscustomobject]@{ Name = 'copy destination'; Path = $destinationRoot })
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
        Copy-PackagingFileDurably -Source $item.FullName -Destination $destination -Overwrite:$Overwrite | Out-Null
    }
}

function Throw-PackagingFailure {
    param(
        [AllowNull()][System.Management.Automation.ErrorRecord]$PrimaryError,
        [AllowNull()][System.Management.Automation.ErrorRecord]$CleanupError,
        [AllowNull()][object[]]$CleanupErrors
    )

    $allCleanupErrors = @()
    if ($null -ne $CleanupError) {
        $allCleanupErrors += $CleanupError
    }
    if ($null -ne $CleanupErrors) {
        $allCleanupErrors += @($CleanupErrors)
    }

    $cleanupExceptions = @()
    foreach ($cleanupRecord in @($allCleanupErrors)) {
        if ($cleanupRecord -is [System.Management.Automation.ErrorRecord]) {
            $cleanupExceptions += $cleanupRecord.Exception
        } elseif ($cleanupRecord -is [System.Exception]) {
            $cleanupExceptions += $cleanupRecord
        } else {
            $cleanupExceptions += (New-Object System.Exception -ArgumentList ([string]$cleanupRecord))
        }
    }

    if ($null -ne $PrimaryError) {
        if ($cleanupExceptions.Count -gt 0) {
            $primaryMessage = [string]$PrimaryError.Exception.Message
            $cleanupMessage = (($cleanupExceptions | ForEach-Object { [string]$_.Message }) -join ' | ')
            $combined = New-Object System.Exception -ArgumentList @(
                ("$primaryMessage Cleanup also failed: $cleanupMessage"),
                $PrimaryError.Exception)
            $combined.Data['PrimaryExceptionType'] = $PrimaryError.Exception.GetType().FullName
            $combined.Data['CleanupExceptionTypes'] = (($cleanupExceptions | ForEach-Object {
                    $_.GetType().FullName
                }) -join ' | ')
            throw $combined
        }

        throw $PrimaryError.Exception
    }

    if ($cleanupExceptions.Count -gt 0) {
        $cleanupMessage = (($cleanupExceptions | ForEach-Object { [string]$_.Message }) -join ' | ')
        $combined = New-Object System.Exception -ArgumentList ("Packaging cleanup failed: $cleanupMessage")
        $combined.Data['CleanupExceptionTypes'] = (($cleanupExceptions | ForEach-Object {
                $_.GetType().FullName
            }) -join ' | ')
        throw $combined
    }
}

function Invoke-PackagingOperationWithCleanup {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Operation,
        [Parameter(Mandatory = $true)][scriptblock]$Cleanup
    )

    $operationOutput = @()
    $primaryError = $null
    try {
        $operationOutput = @(& $Operation)
    } catch {
        $primaryError = $_
    }

    $cleanupError = $null
    try {
        & $Cleanup | Out-Null
    } catch {
        $cleanupError = $_
    }

    if ($null -ne $primaryError -or $null -ne $cleanupError) {
        Throw-PackagingFailure -PrimaryError $primaryError -CleanupError $cleanupError
    }

    return $operationOutput
}

function New-PackagingStagingFilePath {
    param(
        [Parameter(Mandatory = $true)][string]$DestinationPath
    )

    $destination = Normalize-ComparablePath -Path $DestinationPath
    $parent = Split-Path -Path $destination -Parent
    $name = [IO.Path]::GetFileName($destination)
    if ([string]::IsNullOrWhiteSpace($parent) -or [string]::IsNullOrWhiteSpace($name)) {
        throw "Could not derive an atomic staging path from destination: $destination"
    }

    $candidate = Join-Path $parent ('.' + $name + '.staging-' + [Guid]::NewGuid().ToString('N'))
    Assert-SafeDestination -Path $candidate -AllowRepositoryChild -AllowTempChild | Out-Null
    return $candidate
}

function New-PackagingBackupFilePath {
    param(
        [Parameter(Mandatory = $true)][string]$DestinationPath
    )

    $destination = Normalize-ComparablePath -Path $DestinationPath
    $parent = Split-Path -Path $destination -Parent
    $name = [IO.Path]::GetFileName($destination)
    if ([string]::IsNullOrWhiteSpace($parent) -or [string]::IsNullOrWhiteSpace($name)) {
        throw "Could not derive an atomic backup path from destination: $destination"
    }

    $candidate = Join-Path $parent ('.' + $name + '.backup-' + [Guid]::NewGuid().ToString('N'))
    Assert-SafeDestination -Path $candidate -AllowRepositoryChild -AllowTempChild | Out-Null
    return $candidate
}

function Get-PackagingStagingProbePath {
    param(
        [Parameter(Mandatory = $true)][string]$DestinationPath,
        [switch]$Directory
    )

    $destination = Normalize-ComparablePath -Path $DestinationPath
    $parent = Split-Path -Path $destination -Parent
    $name = [IO.Path]::GetFileName($destination)
    if ([string]::IsNullOrWhiteSpace($parent) -or [string]::IsNullOrWhiteSpace($name)) {
        throw "Could not derive a staging overlap probe from destination: $destination"
    }
    return (Join-Path $parent ('.' + $name + '.staging-' + ('0' * 32)))
}

function Remove-PackagingStagingFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    $fullPath = Normalize-ComparablePath -Path $Path
    $name = [IO.Path]::GetFileName($fullPath)
    if ($name -notmatch '^\.[^\\]+\.staging-[0-9a-f]{32}$') {
        throw "Refusing to remove a non-owned packaging staging file: $fullPath"
    }
    Assert-SafeDestination -Path $fullPath -AllowRepositoryChild -AllowTempChild | Out-Null
    [IO.File]::Delete($fullPath)
}

function Invoke-PackagingAtomicFileWrite {
    param(
        [Parameter(Mandatory = $true)][string]$DestinationPath,
        [Parameter(Mandatory = $true)][scriptblock]$WriteStagedFile,
        [Parameter(Mandatory = $true)][string]$OperationName,
        [string]$TestFaultInjectionStage = 'None',
        [switch]$TestInjectCleanupFailure
    )

    if ($TestFaultInjectionStage -notin @(
            'None',
            'MidWrite',
            'Verify',
            'BeforeCommit',
            'Replace',
            'AfterReplace',
            'Delete')) {
        throw "Unsupported $OperationName fault-injection stage: $TestFaultInjectionStage"
    }

    $destination = Assert-SafeDestination -Path $DestinationPath -AllowRepositoryChild -AllowTempChild
    if (Test-Path -LiteralPath $destination) {
        throw "Refusing to overwrite an existing $OperationName destination: $destination"
    }

    $parent = Split-Path -Path $destination -Parent
    $stagingPath = New-PackagingStagingFilePath -DestinationPath $destination
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    Assert-NoReparsePath -Path $parent

    $committed = $false
    $destinationMoved = $false
    $primaryError = $null
    $cleanupErrors = @()
    try {
        & $WriteStagedFile $stagingPath $TestFaultInjectionStage | Out-Null
        if (-not [IO.File]::Exists($stagingPath)) {
            throw "$OperationName writer did not create its staging file: $stagingPath"
        }
        $stagingLength = Get-PackagingFileLength -Path $stagingPath
        $stagingHash = ((Get-FileHash -LiteralPath $stagingPath -Algorithm SHA256).Hash).ToUpperInvariant()
        if ($TestFaultInjectionStage -eq 'Verify') {
            throw "Injected $OperationName verification failure."
        }
        if ($TestFaultInjectionStage -eq 'BeforeCommit') {
            throw "Injected $OperationName failure before atomic commit."
        }
        if ($TestFaultInjectionStage -eq 'Replace') {
            throw "Injected $OperationName replace failure."
        }
        if (Test-Path -LiteralPath $destination) {
            throw "Refusing to overwrite an existing $OperationName destination: $destination"
        }
        [IO.File]::Move($stagingPath, $destination)
        $destinationMoved = $true
        if ($TestFaultInjectionStage -eq 'AfterReplace') {
            throw "Injected $OperationName post-replace failure."
        }
        if ($TestFaultInjectionStage -eq 'Delete') {
            throw "Injected $OperationName delete failure."
        }
        $destinationLength = Get-PackagingFileLength -Path $destination
        $destinationHash = ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash).ToUpperInvariant()
        if ([int64]$destinationLength -ne [int64]$stagingLength -or
            $destinationHash -cne $stagingHash) {
            throw "$OperationName post-commit hash verification failed."
        }
        $committed = $true
    } catch {
        $primaryError = $_
    }

    if (-not $destinationMoved -and
        -not (Test-Path -LiteralPath $stagingPath) -and
        (Test-Path -LiteralPath $destination -PathType Leaf)) {
        $destinationMoved = $true
    }

    try {
        if (-not $committed -and $destinationMoved -and (Test-Path -LiteralPath $destination -PathType Leaf)) {
            [IO.File]::Delete($destination)
        }
    } catch {
        $cleanupErrors += $_
    }
    try {
        if (-not $committed -and (Test-Path -LiteralPath $stagingPath -PathType Leaf)) {
            Remove-PackagingStagingFile -Path $stagingPath
        }
    } catch {
        $cleanupErrors += $_
    }
    try {
        if (-not $committed -and $TestInjectCleanupFailure) {
            throw "Injected $OperationName cleanup failure."
        }
    } catch {
        $cleanupErrors += $_
    }

    if ($null -ne $primaryError -or $cleanupErrors.Count -gt 0) {
        Throw-PackagingFailure -PrimaryError $primaryError -CleanupErrors $cleanupErrors
    }

    return $destination
}
function Write-PackagingBytesToStagingFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][string]$OperationName,
        [string]$TestFaultInjectionStage = 'None'
    )

    $stream = $null
    $writeError = $null
    try {
        $stream = [IO.File]::Open(
            $Path,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None)
        $split = 0
        if ($Bytes.Length -gt 1) {
            $split = [Math]::Max(1, [Math]::Min($Bytes.Length - 1, [int][Math]::Ceiling($Bytes.Length / 2.0)))
        }
        if ($split -gt 0) {
            $stream.Write($Bytes, 0, $split)
            if ($TestFaultInjectionStage -eq 'MidWrite') {
                throw "Injected $OperationName failure during staged write."
            }
            $stream.Write($Bytes, $split, $Bytes.Length - $split)
        } elseif ($Bytes.Length -gt 0) {
            $stream.Write($Bytes, 0, $Bytes.Length)
            if ($TestFaultInjectionStage -eq 'MidWrite') {
                throw "Injected $OperationName failure during staged write."
            }
        }
        $stream.Flush($true)
    } catch {
        $writeError = $_
    }

    $disposeError = $null
    if ($null -ne $stream) {
        try {
            $stream.Dispose()
        } catch {
            $disposeError = $_
        }
    }
    if ($null -ne $writeError -or $null -ne $disposeError) {
        Throw-PackagingFailure -PrimaryError $writeError -CleanupError $disposeError
    }
}

function New-PackagingStagingDirectory {
    param([Parameter(Mandatory = $true)][string]$OutputRoot)

    $output = Normalize-ComparablePath -Path $OutputRoot
    $parent = Split-Path -Path $output -Parent
    $name = [IO.Path]::GetFileName($output)
    if ([string]::IsNullOrWhiteSpace($name)) {
        throw "Could not derive an atomic staging name from output root: $output"
    }
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        throw "Output root parent does not exist: $parent"
    }

    for ($attempt = 0; $attempt -lt 10; $attempt++) {
        $candidate = Join-Path $parent ('.' + $name + '.staging-' + [Guid]::NewGuid().ToString('N'))
        Assert-SafeDestination -Path $candidate -AllowRepositoryChild -AllowTempChild | Out-Null
        if (-not (Test-Path -LiteralPath $candidate)) {
            New-Item -ItemType Directory -Path $candidate -Force | Out-Null
            return (Normalize-ComparablePath -Path $candidate)
        }
    }

    throw 'Could not create a unique atomic packaging staging directory.'
}

function Remove-PackagingStagingDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = Normalize-ComparablePath -Path $Path
    $name = [IO.Path]::GetFileName($fullPath)
    if ($name -notmatch '^\.[^\\]+\.staging-[0-9a-f]{32}$') {
        throw "Refusing to remove a non-owned packaging staging directory: $fullPath"
    }
    Assert-SafeDestination -Path $fullPath -AllowRepositoryChild -AllowTempChild | Out-Null
    if (Test-Path -LiteralPath $fullPath) {
        Assert-NoReparsePath -Path $fullPath
        Remove-Item -LiteralPath $fullPath -Recurse -Force
    }
}

function Remove-PackagingUncommittedGenerationDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $fullPath = Normalize-ComparablePath -Path $Path
    Assert-SafeDestination -Path $fullPath -AllowRepositoryChild -AllowTempChild | Out-Null
    if (-not (Test-Path -LiteralPath $fullPath)) {
        return
    }
    $item = Get-Item -LiteralPath $fullPath -Force
    if (-not $item.PSIsContainer -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing to clean an unsafe ${Description}: $fullPath"
    }
    $markerPath = Join-Path $fullPath 'commit.marker'
    if (Test-Path -LiteralPath $markerPath -PathType Leaf) {
        throw "Refusing to overwrite a committed ${Description}: $fullPath"
    }
    Assert-NoReparsePath -Path $fullPath
    Assert-NoReparseDescendants -Path $fullPath
    Remove-Item -LiteralPath $fullPath -Recurse -Force
}

function Remove-PackagingOrphanedStagingDirectories {
    param(
        [Parameter(Mandatory = $true)][string]$Parent,
        [Parameter(Mandatory = $true)][string]$DestinationName,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $parentPath = Normalize-ComparablePath -Path $Parent
    Assert-SafeDestination -Path $parentPath -AllowRepositoryChild -AllowTempChild | Out-Null
    if (-not (Test-Path -LiteralPath $parentPath -PathType Container)) {
        return
    }
    Assert-NoReparsePath -Path $parentPath
    $pattern = '^\.' + [Text.RegularExpressions.Regex]::Escape($DestinationName) + '\.staging-[0-9a-f]{32}$'
    foreach ($candidate in @(Get-ChildItem -LiteralPath $parentPath -Directory -Force |
            Where-Object { $_.Name -match $pattern })) {
        Remove-PackagingStagingDirectory -Path $candidate.FullName
    }
}

function Publish-PackageArtifactsAtomically {
    param(
        [AllowNull()]$Profile,
        [Parameter(Mandatory = $true)][string]$PackageRoot,
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$HashRecordPath,
        [Parameter(Mandatory = $true)][string]$OutputRoot,
        [string]$FaultInjectionStage = 'None'
    )

    if ($FaultInjectionStage -notin @(
            'None',
            'AfterPackage',
            'AfterArchive',
            'AfterHash',
            'AfterMetadata',
            'BeforeCommit',
            'DestinationMoveTransientFailure',
            'DestinationMoveRetryExhaustedFailure',
            'DestinationMoveDiskFullFailure',
            'DestinationMoveUnauthorizedFailure',
            'DestinationMovePostExhaustSuccess',
            'AfterRenameBeforeReturn')) {
        throw "Unsupported packaging publication fault-injection stage: $FaultInjectionStage"
    }

    $safePackageRoot = Assert-SafeDestination -Path $PackageRoot -AllowRepositoryChild -AllowTempChild
    if (-not (Test-Path -LiteralPath $safePackageRoot -PathType Container)) {
        throw "Package root directory was not found: $safePackageRoot"
    }
    Assert-NoReparsePath -Path $safePackageRoot

    $safeArchive = Assert-SafeDestination -Path $ArchivePath -AllowRepositoryChild -AllowTempChild
    if (-not (Test-Path -LiteralPath $safeArchive -PathType Leaf)) {
        throw "Package archive was not found: $safeArchive"
    }
    $safeHashRecord = Assert-SafeDestination -Path $HashRecordPath -AllowRepositoryChild -AllowTempChild
    if (-not (Test-Path -LiteralPath $safeHashRecord -PathType Leaf)) {
        throw "Package hash record was not found: $safeHashRecord"
    }
    Assert-PackageHashRecordMatchesArchive -Profile $Profile -PackageRoot $safePackageRoot -ArchivePath $safeArchive -HashRecordPath $safeHashRecord -ArchiveFileName ([IO.Path]::GetFileName($safeArchive)) | Out-Null

    $safeOutputRoot = Assert-SafeDestination -Path $OutputRoot -AllowRepositoryChild -AllowTempChild
    Assert-PackagingPathsDoNotOverlap -Paths @(
        [pscustomobject]@{ Name = 'package root'; Path = $safePackageRoot },
        [pscustomobject]@{ Name = 'archive source'; Path = $safeArchive },
        [pscustomobject]@{ Name = 'hash-record source'; Path = $safeHashRecord },
        [pscustomobject]@{ Name = 'output root'; Path = $safeOutputRoot },
        [pscustomobject]@{ Name = 'publication staging probe'; Path = (Get-PackagingStagingProbePath -DestinationPath $safeOutputRoot -Directory) })
    $outputParent = Split-Path -Path $safeOutputRoot -Parent
    if (-not (Test-Path -LiteralPath $outputParent -PathType Container)) {
        New-Item -ItemType Directory -Path $outputParent -Force | Out-Null
    }
    Assert-NoReparsePath -Path $outputParent

    $outputName = [IO.Path]::GetFileName($safeOutputRoot)
    Remove-PackagingOrphanedStagingDirectories `
        -Parent $outputParent `
        -DestinationName $outputName `
        -Description 'full-package publication'

    if (Test-Path -LiteralPath $safeOutputRoot) {
        $existingOutput = Get-Item -LiteralPath $safeOutputRoot -Force
        if (-not $existingOutput.PSIsContainer -or
            ($existingOutput.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Atomic package output root must be a non-reparse directory: $safeOutputRoot"
        }
        $existingMarker = Join-Path $safeOutputRoot 'commit.marker'
        if (Test-Path -LiteralPath $existingMarker -PathType Leaf) {
            return (Assert-PackagedGenerationCommitted `
                -Profile $Profile `
                -GenerationRoot $safeOutputRoot `
                -ExpectedGenerationKind 'FullPackage')
        }
        Remove-PackagingUncommittedGenerationDirectory `
            -Path $safeOutputRoot `
            -Description 'full-package generation'
    }

    $stagingRoot = $null
    $committed = $false
    $primaryError = $null
    try {
        $stagingRoot = New-PackagingStagingDirectory -OutputRoot $safeOutputRoot
        $stagingPackageRoot = Join-Path $stagingRoot 'package'
        New-Item -ItemType Directory -Path $stagingPackageRoot -Force | Out-Null
        Copy-SafeDirectoryContents -Source $safePackageRoot -Destination $stagingPackageRoot
        Assert-PackagingDirectoryMatchesSource `
            -Source $safePackageRoot `
            -Destination $stagingPackageRoot `
            -Description 'published package payload'
        if ($FaultInjectionStage -eq 'AfterPackage') {
            throw 'Injected atomic publication failure after package copy.'
        }

        $stagingArchivePath = Join-Path $stagingRoot ([IO.Path]::GetFileName($safeArchive))
        Copy-PackagingFileDurably -Source $safeArchive -Destination $stagingArchivePath | Out-Null
        if ($FaultInjectionStage -eq 'AfterArchive') {
            throw 'Injected atomic publication failure after archive copy.'
        }

        $stagingHashPath = Join-Path $stagingRoot 'package-hashes.txt'
        Copy-PackagingFileDurably -Source $safeHashRecord -Destination $stagingHashPath | Out-Null
        if ($FaultInjectionStage -eq 'AfterHash') {
            throw 'Injected atomic publication failure after hash-record copy.'
        }
        Assert-PackagingDirectoryMatchesSource `
            -Source $safePackageRoot `
            -Destination $stagingPackageRoot `
            -Description 'published package payload before commit'
        Assert-PackagingFileMatchesSource `
            -Source $safeArchive `
            -Destination $stagingArchivePath `
            -Description 'published archive before commit'
        Assert-PackagingFileMatchesSource `
            -Source $safeHashRecord `
            -Destination $stagingHashPath `
            -Description 'published hash record before commit'
        Assert-PackageHashRecordMatchesArchive -Profile $Profile -PackageRoot $stagingPackageRoot -ArchivePath $stagingArchivePath -HashRecordPath $stagingHashPath -ArchiveFileName ([IO.Path]::GetFileName($safeArchive)) | Out-Null
        $metadataPath = Join-Path $stagingRoot 'generation.metadata'
        $metadataText = New-PackagingGenerationMetadataText `
            -GenerationKind 'FullPackage' `
            -PackageDirectory 'package' `
            -ArchivePath $stagingArchivePath `
            -HashRecordPath $stagingHashPath
        $metadataBytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($metadataText)
        Write-PackagingBytesToStagingFile `
            -Path $metadataPath `
            -Bytes $metadataBytes `
            -OperationName 'full-package generation metadata'
        if ($FaultInjectionStage -eq 'AfterMetadata') {
            throw 'Injected atomic publication failure after generation metadata.'
        }
        $markerPath = Join-Path $stagingRoot 'commit.marker'
        $markerText = New-PackagingGenerationCommitMarkerText `
            -GenerationRoot $stagingRoot `
            -GenerationKind 'FullPackage' `
            -PackageDirectory 'package' `
            -ArchivePath $stagingArchivePath `
            -HashRecordPath $stagingHashPath
        $markerBytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($markerText)
        Write-PackagingBytesToStagingFile `
            -Path $markerPath `
            -Bytes $markerBytes `
            -OperationName 'full-package generation commit marker'
        if ($FaultInjectionStage -eq 'BeforeCommit') {
            throw 'Injected atomic publication failure before directory commit.'
        }

        if (Test-Path -LiteralPath $safeOutputRoot) {
            throw "Refusing to overwrite a full-package generation that appeared during staging: $safeOutputRoot"
        }

        $moveAttempts = 5
        $moveDelayMs = 200
        $moveSuccess = $false
        $moveError = $null
        $attemptCount = 0

        for ($i = 0; $i -lt $moveAttempts; $i++) {
            $attemptCount++
            try {
                if ($FaultInjectionStage -eq 'DestinationMoveTransientFailure' -and $i -eq 0) {
                    throw [System.IO.IOException]::new("Injected transient move failure.")
                }
                if ($FaultInjectionStage -eq 'DestinationMoveRetryExhaustedFailure') {
                    throw [System.IO.IOException]::new("Injected retry-exhaustion move failure.")
                }
                if ($FaultInjectionStage -eq 'DestinationMoveDiskFullFailure') {
                    throw [System.IO.IOException]::new("Injected disk-full failure.")
                }
                if ($FaultInjectionStage -eq 'DestinationMoveUnauthorizedFailure') {
                    throw [System.UnauthorizedAccessException]::new("Injected non-transient access-denied failure.")
                }
                if ($FaultInjectionStage -eq 'DestinationMovePostExhaustSuccess') {
                    if ($i -lt $moveAttempts - 1) {
                        throw [System.IO.IOException]::new("Injected transient move failure.")
                    } else {
                        New-Item -ItemType Directory -Path $safeOutputRoot -Force | Out-Null
                        Copy-SafeDirectoryContents -Source $stagingRoot -Destination $safeOutputRoot
                        throw [System.IO.IOException]::new("Injected transient move failure.")
                    }
                }
                [IO.Directory]::Move($stagingRoot, $safeOutputRoot)
                $moveSuccess = $true
                break
            } catch [System.IO.IOException], [System.UnauthorizedAccessException] {
                $moveError = $_

                $isTransient = $false
                if ($_.Exception.Message -match 'Injected transient move failure' -or $_.Exception.Message -match 'Injected retry-exhaustion move failure') {
                    $isTransient = $true
                } else {
                    $hr = $_.Exception.HResult -band 0xFFFF
                    if ($hr -eq 32 -or $hr -eq 33) {
                        $isTransient = $true
                    }
                }

                if (-not $isTransient) {
                    break
                }

                if ($i -lt $moveAttempts - 1) {
                    Start-Sleep -Milliseconds $moveDelayMs
                }
            } catch {
                $moveError = $_
                break
            }
        }

        if (-not $moveSuccess) {
            $destinationRecovered = $false
            if (Test-Path -LiteralPath (Join-Path $safeOutputRoot 'commit.marker') -PathType Leaf) {
                try {
                    $null = Assert-PackagedGenerationCommitted -Profile $Profile -GenerationRoot $safeOutputRoot -ExpectedGenerationKind 'FullPackage'
                    $destinationRecovered = $true
                } catch {
                }
            }
            if ($destinationRecovered) {
                if ($null -ne $stagingRoot -and (Test-Path -LiteralPath $stagingRoot)) {
                    Remove-PackagingStagingDirectory -Path $stagingRoot
                    $stagingRoot = $null
                }
                $moveSuccess = $true
            } else {
                throw [System.InvalidOperationException]::new("Atomic publication failed to move staging to output after $attemptCount attempts. Primary error: $($moveError.Exception.Message)", $moveError.Exception)
            }
        }

        $committed = $true
        $stagingRoot = $null
        if ($FaultInjectionStage -eq 'AfterRenameBeforeReturn') {
            throw 'Injected atomic publication failure after generation rename before caller return.'
        }
    } catch {
        $primaryError = $_
    }

    $cleanupError = $null
    try {
        if (-not $committed -and $null -ne $stagingRoot -and (Test-Path -LiteralPath $stagingRoot)) {
            Remove-PackagingStagingDirectory -Path $stagingRoot
        }
    } catch {
        $cleanupError = $_
    }

    if ($null -ne $primaryError -or $null -ne $cleanupError) {
        Throw-PackagingFailure -PrimaryError $primaryError -CleanupError $cleanupError
    }

    return (Assert-PackagedGenerationCommitted `
        -Profile $Profile `
        -GenerationRoot $safeOutputRoot `
        -ExpectedGenerationKind 'FullPackage')
}

function Resolve-PackagingProjectImportPath {
    param(
        [Parameter(Mandatory = $true)][string]$ImportReference,
        [Parameter(Mandatory = $true)][string]$ImportingFile,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot
    )

    if ([string]::IsNullOrWhiteSpace($ImportReference) -or
        $ImportReference.IndexOf('$(', [StringComparison]::Ordinal) -ge 0 -or
        $ImportReference.IndexOf('*', [StringComparison]::Ordinal) -ge 0 -or
        $ImportReference.IndexOf('?', [StringComparison]::Ordinal) -ge 0) {
        throw "Project import reference must be a concrete, non-wildcard path: '$ImportReference' in $ImportingFile"
    }

    $candidate = $ImportReference
    if (-not [IO.Path]::IsPathRooted($candidate)) {
        $candidate = Join-Path (Split-Path -Path $ImportingFile -Parent) $candidate
    }
    $resolved = Normalize-ComparablePath -Path $candidate
    if (-not (Test-PathWithin -ChildPath $resolved -RootPath $RepositoryRoot)) {
        throw "Project import is outside the authorized repository: $resolved"
    }
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw "Project import was not found: $resolved"
    }
    Assert-NoReparsePath -Path $resolved
    return $resolved
}

function Get-PackagingProjectImportAncestry {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectPath,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot
    )

    $queue = New-Object System.Collections.Queue
    $queue.Enqueue((Normalize-ComparablePath -Path $ProjectPath))
    $projectDirectory = Normalize-ComparablePath -Path (Split-Path -Path $ProjectPath -Parent)
    $directory = $projectDirectory
    while ($true) {
        foreach ($directoryBuildName in @('Directory.Build.props', 'Directory.Build.targets')) {
            $directoryBuildPath = Join-Path $directory $directoryBuildName
            if (Test-Path -LiteralPath $directoryBuildPath -PathType Leaf) {
                $queue.Enqueue((Normalize-ComparablePath -Path $directoryBuildPath))
            }
        }
        if ($directory.Equals($RepositoryRoot, [StringComparison]::OrdinalIgnoreCase)) {
            break
        }
        $parent = Split-Path -Path $directory -Parent
        if ([string]::IsNullOrWhiteSpace($parent) -or
            $parent.Equals($directory, [StringComparison]::OrdinalIgnoreCase) -or
            -not (Test-PathWithin -ChildPath $parent -RootPath $RepositoryRoot)) {
            break
        }
        $directory = Normalize-ComparablePath -Path $parent
    }

    $visited = @{}
    $ancestry = @()
    while ($queue.Count -gt 0) {
        $current = Normalize-ComparablePath -Path ([string]$queue.Dequeue())
        if ($visited.ContainsKey($current)) {
            continue
        }
        $visited[$current] = $true
        if (-not (Test-PathWithin -ChildPath $current -RootPath $RepositoryRoot)) {
            throw "Project import ancestry escaped the authorized repository: $current"
        }
        if (-not (Test-Path -LiteralPath $current -PathType Leaf)) {
            throw "Project import ancestry file was not found: $current"
        }
        Assert-NoReparsePath -Path $current
        $ancestry += $current

        try {
            [xml]$document = Get-Content -LiteralPath $current -Raw
        } catch {
            throw "Project import ancestry file is not valid XML: $current. $($_.Exception.Message)"
        }

        foreach ($importNode in @($document.SelectNodes('//*[local-name()="Import"]'))) {
            if ($importNode.HasAttribute('Sdk')) {
                $sdk = [string]$importNode.GetAttribute('Sdk')
                if ($sdk -notmatch '^Microsoft\.NET\.Sdk(?:\.|$)') {
                    throw "Only the trusted Microsoft.NET.Sdk import family is allowed: '$sdk' in $current"
                }
                continue
            }
            $reference = [string]$importNode.GetAttribute('Project')
            $importedPath = Resolve-PackagingProjectImportPath `
                -ImportReference $reference `
                -ImportingFile $current `
                -RepositoryRoot $RepositoryRoot
            $queue.Enqueue($importedPath)
        }
    }

    return @($ancestry | Sort-Object)
}

function Get-PackagingTrustedDotnetRoot {
    param([string]$CommandPath)

    $source = $CommandPath
    if ([string]::IsNullOrWhiteSpace($source)) {
        $command = Get-Command -Name 'dotnet' -CommandType Application -ErrorAction Stop | Select-Object -First 1
        $source = [string]$command.Source
    } elseif (-not [IO.Path]::IsPathRooted($source)) {
        $command = Get-Command -Name $source -CommandType Application -ErrorAction Stop | Select-Object -First 1
        $source = [string]$command.Source
    }

    if ([string]::IsNullOrWhiteSpace($source)) {
        throw 'Could not resolve the dotnet command for trusted SDK import fencing.'
    }
    $source = Normalize-ComparablePath -Path $source
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "The dotnet command was not found: $source"
    }
    Assert-NoReparsePath -Path $source
    return (Normalize-ComparablePath -Path (Split-Path -Path $source -Parent))
}

function ConvertFrom-StrictMSBuildPropertyJson {
    param(
        [Parameter(Mandatory = $true)][string]$Json,
        [Parameter(Mandatory = $true)][string[]]$ExpectedPropertyNames
    )

    $document = ConvertFrom-StrictPackageJson -Json $Json -Description 'MSBuild property evaluation output'
    $topNames = @($document.PSObject.Properties | ForEach-Object { [string]$_.Name })
    if ($topNames.Count -ne 1 -or $topNames[0] -cne 'Properties') {
        throw 'MSBuild property evaluation output must contain exactly one top-level Properties object.'
    }
    if ($null -eq $document.Properties) {
        throw 'MSBuild property evaluation output Properties object must not be null.'
    }

    $propertyNames = @($document.Properties.PSObject.Properties | ForEach-Object { [string]$_.Name })
    $missing = @($ExpectedPropertyNames | Where-Object { $propertyNames -notcontains $_ })
    $unexpected = @($propertyNames | Where-Object { $ExpectedPropertyNames -notcontains $_ })
    if ($missing.Count -gt 0 -or $unexpected.Count -gt 0 -or
        $propertyNames.Count -ne $ExpectedPropertyNames.Count) {
        throw "MSBuild property evaluation output schema drifted. Missing: $($missing -join ', '). Unexpected: $($unexpected -join ', ')."
    }
    foreach ($name in $ExpectedPropertyNames) {
        $matches = @($document.Properties.PSObject.Properties | Where-Object { [string]$_.Name -ceq $name })
        if ($matches.Count -ne 1) {
            throw "MSBuild property evaluation output must contain exactly one '$name' property."
        }
    }
    return $document.Properties
}

function Invoke-PackagingMSBuildPropertyEvaluation {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectPath,
        [Parameter(Mandatory = $true)]$Profile,
        [string]$TestDotnetCommandPath,
        [ValidateRange(1000, 120000)]
        [int]$TimeoutMilliseconds = 60000
    )

    $propertyNames = @(
        'AssemblyName',
        'TargetName',
        'RootNamespace',
        'TargetFramework',
        'TargetFrameworks',
        'OutputType',
        'UseWPF',
        'TargetExt',
        'TargetFileName',
        'UseAppHost',
        'AppHostName',
        'PlatformTarget',
        'Platform',
        'RuntimeIdentifier',
        'SelfContained',
        'PublishSingleFile',
        'PublishTrimmed',
        'PublishReadyToRun',
        'GenerateAssemblyInfo',
        'OutputPath',
        'PublishDir',
        'MSBuildProjectFullPath',
        'MSBuildProjectDirectory',
        'MSBuildAllProjects')

    $commandPath = $TestDotnetCommandPath
    if ([string]::IsNullOrWhiteSpace($commandPath)) {
        $commandPath = 'dotnet'
    } elseif ([IO.Path]::IsPathRooted($commandPath)) {
        $commandPath = Normalize-ComparablePath -Path $commandPath
        if (-not (Test-Path -LiteralPath $commandPath -PathType Leaf)) {
            throw "The MSBuild evaluation command was not found: $commandPath"
        }
    }

    $evaluationRoot = New-PackagingTempDirectory -Prefix 'HerdrOps-MSBuild-Evaluation-'
    try {
        $isolatedExtensionsPath = $evaluationRoot.Replace('\', '/') + '/'
        $propertyRequest = '-getProperty:' + ($propertyNames -join ',')
        $arguments = @(
            'msbuild',
            $ProjectPath,
            $propertyRequest,
            '-p:Configuration=Release',
            ('-p:RuntimeIdentifier=' + [string]$Profile.runtimeIdentifier),
            '-p:SelfContained=true',
            ('-p:MSBuildProjectExtensionsPath=' + $isolatedExtensionsPath),
            '-nologo',
            '-verbosity:quiet')
        $quotedArguments = @($arguments | ForEach-Object {
                '"' + ([string]$_).Replace('"', '\"') + '"'
            }) -join ' '

        $startInfo = New-Object Diagnostics.ProcessStartInfo
        $startInfo.FileName = $commandPath
        $startInfo.Arguments = $quotedArguments
        $startInfo.WorkingDirectory = Split-Path -Path $ProjectPath -Parent
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $process = New-Object Diagnostics.Process
        $process.StartInfo = $startInfo
        $stdoutTask = $null
        $stderrTask = $null
        try {
            if (-not $process.Start()) {
                throw 'MSBuild property evaluation process could not be started.'
            }
            $stdoutTask = $process.StandardOutput.ReadToEndAsync()
            $stderrTask = $process.StandardError.ReadToEndAsync()
            if (-not $process.WaitForExit($TimeoutMilliseconds)) {
                try { $process.Kill() } catch { }
                throw "MSBuild property evaluation exceeded the $TimeoutMilliseconds ms timeout."
            }
            $process.WaitForExit()
            $stdout = $stdoutTask.GetAwaiter().GetResult()
            $stderr = $stderrTask.GetAwaiter().GetResult()
            if ($process.ExitCode -ne 0) {
                throw "MSBuild property evaluation failed with exit code $($process.ExitCode): $stderr"
            }
            if (-not [string]::IsNullOrWhiteSpace($stderr)) {
                throw "MSBuild property evaluation wrote unexpected stderr: $stderr"
            }
            return (ConvertFrom-StrictMSBuildPropertyJson -Json $stdout -ExpectedPropertyNames $propertyNames)
        } finally {
            $process.Dispose()
        }
    } finally {
        Remove-PackagingTempDirectory -Path $evaluationRoot
    }
}

function Assert-PackagingEvaluatedImportPaths {
    param(
        [Parameter(Mandatory = $true)]$Properties,
        [Parameter(Mandatory = $true)][string[]]$StaticAncestry,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$TrustedDotnetRoot
    )

    $reported = @([string]$Properties.MSBuildAllProjects -split ';' |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($reported.Count -eq 0) {
        throw 'MSBuild property evaluation did not report an import ancestry.'
    }
    foreach ($reportedPath in $reported) {
        if (-not [IO.Path]::IsPathRooted($reportedPath)) {
            throw "MSBuild reported a non-rooted import ancestry path: $reportedPath"
        }
        $path = Normalize-ComparablePath -Path $reportedPath
        if (Test-PathWithin -ChildPath $path -RootPath $RepositoryRoot) {
            Assert-NoReparsePath -Path $path
            if (@($StaticAncestry | Where-Object { $_.Equals($path, [StringComparison]::OrdinalIgnoreCase) }).Count -eq 0) {
                throw "MSBuild reported an unverified repository import ancestry path: $path"
            }
            continue
        }
        if (Test-PathWithin -ChildPath $path -RootPath $TrustedDotnetRoot) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                throw "MSBuild reported a missing trusted SDK import path: $path"
            }
            Assert-NoReparsePath -Path $path
            continue
        }
        throw "MSBuild reported an import ancestry path outside the authorized repository or trusted SDK root: $path"
    }
}

function Assert-PackagingEvaluatedIdentity {
    param(
        [Parameter(Mandatory = $true)]$Properties,
        [Parameter(Mandatory = $true)]$Profile,
        [Parameter(Mandatory = $true)][string]$ProjectPath,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot
    )

    $projectDirectory = Normalize-ComparablePath -Path (Split-Path -Path $ProjectPath -Parent)
    $targetFramework = [string]$Profile.targetFramework
    $expectedOutputPath = 'bin\Release\' + $targetFramework + '\' + [string]$Profile.runtimeIdentifier + '\'
    $expectedPublishPath = $expectedOutputPath + 'publish\'
    $expected = [ordered]@{
        AssemblyName = 'HerdrOps.App'
        TargetName = 'HerdrOps.App'
        RootNamespace = 'HerdrOps.App'
        TargetFramework = $targetFramework
        TargetFrameworks = ''
        OutputType = 'WinExe'
        UseWPF = 'true'
        TargetExt = '.dll'
        TargetFileName = 'HerdrOps.App.dll'
        UseAppHost = 'true'
        AppHostName = ''
        PlatformTarget = 'x64'
        Platform = 'AnyCPU'
        RuntimeIdentifier = [string]$Profile.runtimeIdentifier
        SelfContained = 'true'
        PublishSingleFile = ''
        PublishTrimmed = ''
        PublishReadyToRun = ''
        GenerateAssemblyInfo = 'true'
        OutputPath = $expectedOutputPath
        PublishDir = $expectedPublishPath
        MSBuildProjectFullPath = (Normalize-ComparablePath -Path $ProjectPath)
        MSBuildProjectDirectory = $projectDirectory
    }
    foreach ($name in $expected.Keys) {
        if ([string]$Properties.$name -cne [string]$expected[$name]) {
            throw "Effective MSBuild property '$name' must be exactly '$($expected[$name])': '$($Properties.$name)'"
        }
    }
    if (-not (Test-PathWithin -ChildPath (Normalize-ComparablePath -Path $projectDirectory) -RootPath $RepositoryRoot)) {
        throw "Effective MSBuild project directory escaped the authorized repository: $projectDirectory"
    }
}

function Assert-ProjectMatchesPackageProfile {
    param(
        [Parameter(Mandatory = $true)]$Profile,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [string]$TestDotnetCommandPath
    )

    $repositoryPath = Normalize-ComparablePath -Path $RepositoryRoot
    Assert-NoReparsePath -Path $repositoryPath
    $relativeProject = ([string]$Profile.sourceProject).Replace('/', '\')
    $expectedRelativeProject = 'src\HerdrOps.App\HerdrOps.App.csproj'
    if ($relativeProject -cne $expectedRelativeProject -or
        [IO.Path]::IsPathRooted($relativeProject)) {
        throw "Packaging source project must be the canonical v0.7.0 project path '$expectedRelativeProject'."
    }

    $projectPath = Normalize-ComparablePath -Path (Join-Path $repositoryPath $relativeProject)
    if (-not (Test-PathWithin -ChildPath $projectPath -RootPath $repositoryPath) -or
        $projectPath.Equals($repositoryPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Profile source project is outside the authorized repository: $projectPath"
    }
    $expectedProjectPath = Normalize-ComparablePath -Path (Join-Path $repositoryPath $expectedRelativeProject)
    if (-not $projectPath.Equals($expectedProjectPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Profile source project does not identify the expected HerdrOps.App project: $projectPath"
    }
    if (-not (Test-Path -LiteralPath $projectPath -PathType Leaf)) {
        throw "Profile source project was not found: $projectPath"
    }
    Assert-NoReparsePath -Path $projectPath

    try {
        [xml]$project = Get-Content -LiteralPath $projectPath -Raw
    } catch {
        throw "Source project is not valid XML: $projectPath. $($_.Exception.Message)"
    }
    if ([string]$project.Project.Sdk -cne 'Microsoft.NET.Sdk') {
        throw 'The packaging source project must use Microsoft.NET.Sdk.'
    }

    $staticAncestry = @(Get-PackagingProjectImportAncestry -ProjectPath $projectPath -RepositoryRoot $repositoryPath)
    $properties = Invoke-PackagingMSBuildPropertyEvaluation `
        -ProjectPath $projectPath `
        -Profile $Profile `
        -TestDotnetCommandPath $TestDotnetCommandPath
    Assert-PackagingEvaluatedIdentity `
        -Properties $properties `
        -Profile $Profile `
        -ProjectPath $projectPath `
        -RepositoryRoot $repositoryPath
    $trustedDotnetRoot = Get-PackagingTrustedDotnetRoot -CommandPath $TestDotnetCommandPath
    Assert-PackagingEvaluatedImportPaths `
        -Properties $properties `
        -StaticAncestry $staticAncestry `
        -RepositoryRoot $repositoryPath `
        -TrustedDotnetRoot $trustedDotnetRoot

    return [pscustomobject][ordered]@{
        ProjectPath = $projectPath
        ImportAncestry = $staticAncestry
        Properties = $properties
    }
}

function Assert-PublishedVersionIdentity {
    param(
        [Parameter(Mandatory = $true)]$Profile,
        [Parameter(Mandatory = $true)][string]$PublishRoot
    )

    Assert-StagedExecutableFileIdentities -Profile $Profile -PublishRoot $PublishRoot
    $assemblyPath = Join-Path (Normalize-ComparablePath -Path $PublishRoot) 'HerdrOps.App.dll'
    if (-not (Test-Path -LiteralPath $assemblyPath -PathType Leaf)) {
        throw "Published WPF assembly was not found: $assemblyPath"
    }

    $expected = [Version]$Profile.packageVersion
    try {
        $assemblyIdentity = [Reflection.AssemblyName]::GetAssemblyName($assemblyPath)
        $assemblyVersion = $assemblyIdentity.Version
    } catch {
        throw "Could not read the published assembly identity: $assemblyPath. $($_.Exception.Message)"
    }
    if ([string]$assemblyIdentity.Name -cne 'HerdrOps.App') {
        throw "Published assembly identity must be exactly HerdrOps.App: $($assemblyIdentity.Name)"
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

function Assert-StagedExecutableFileIdentities {
    param(
        [Parameter(Mandatory = $true)]$Profile,
        [Parameter(Mandatory = $true)][string]$PublishRoot
    )

    $root = Assert-SafeDestination -Path $PublishRoot -AllowRepositoryChild -AllowTempChild
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        throw "Synthetic or published package root was not found: $root"
    }
    Assert-NoReparsePath -Path $root
    Assert-NoReparseDescendants -Path $root
    $expectedAssemblyName = 'HerdrOps.App'
    $expectedFiles = @(
        [string]::Concat($expectedAssemblyName, '.dll'),
        [string]::Concat($expectedAssemblyName, '.exe'))
    foreach ($expectedFile in $expectedFiles) {
        $path = Join-Path $root $expectedFile
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Staged package is missing the exact executable identity file: $expectedFile"
        }
        Assert-NoReparsePath -Path $path
    }
    $unexpectedIdentityFiles = @(Get-ChildItem -LiteralPath $root -Recurse -Force -File |
        Where-Object {
            $_.Name -match '^HerdrOps\.App\..+\.(?:dll|exe)$'
        })
    if ($unexpectedIdentityFiles.Count -gt 0) {
        throw "Staged package contains unexpected HerdrOps executable identity files: $($unexpectedIdentityFiles.Name -join ', ')"
    }
    return [pscustomobject][ordered]@{
        AssemblyName = $expectedAssemblyName
        AssemblyPath = (Get-FullPath -Path (Join-Path $root ($expectedAssemblyName + '.dll')))
        ExecutablePath = (Get-FullPath -Path (Join-Path $root ($expectedAssemblyName + '.exe')))
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
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [string]$TestFaultInjectionStage = 'None',
        [switch]$TestInjectCleanupFailure
    )

    $root = Assert-SafeDestination -Path $PackageRoot -AllowRepositoryChild -AllowTempChild
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        throw "Package root directory was not found: $root"
    }
    Assert-NoReparsePath -Path $root
    $archive = Assert-SafeDestination -Path $ArchivePath -AllowRepositoryChild -AllowTempChild
    Assert-PackagingPathsDoNotOverlap -Paths @(
        [pscustomobject]@{ Name = 'package root'; Path = $root },
        [pscustomobject]@{ Name = 'archive destination'; Path = $archive },
        [pscustomobject]@{ Name = 'archive staging probe'; Path = (Get-PackagingStagingProbePath -DestinationPath $archive) })
    if (Test-Path -LiteralPath $archive) {
        throw "Refusing to overwrite an existing package archive: $archive"
    }

    $entries = @(Get-PackageEntries -PackageRoot $root)

    return Invoke-PackagingAtomicFileWrite `
        -DestinationPath $archive `
        -OperationName 'package archive' `
        -TestFaultInjectionStage $TestFaultInjectionStage `
        -TestInjectCleanupFailure:$TestInjectCleanupFailure `
        -WriteStagedFile {
            param($stagingPath, $faultStage)

            $archiveStream = $null
            $writer = $null
            $writeError = $null
            try {
                $archiveStream = [IO.File]::Open(
                    $stagingPath,
                    [IO.FileMode]::CreateNew,
                    [IO.FileAccess]::ReadWrite,
                    [IO.FileShare]::None)
                $writer = New-Object -TypeName System.IO.BinaryWriter -ArgumentList $archiveStream
                $centralRecords = @()
                $utf8 = New-Object System.Text.UTF8Encoding($false)
                $fixedFlags = [uint16]0x0800
                $fixedDosTime = [uint16]0
                $fixedDosDate = [uint16]0x0021
                $copyBuffer = New-Object byte[] 1048576
                $injectedMidWrite = $false

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

                    if ($faultStage -eq 'MidWrite' -and -not $injectedMidWrite) {
                        $injectedMidWrite = $true
                        throw 'Injected package archive failure during staged write.'
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
                $archiveStream.Flush($true)
            } catch {
                $writeError = $_
            }

            $disposeError = $null
            if ($null -ne $writer) {
                try {
                    $writer.Dispose()
                } catch {
                    $disposeError = $_
                }
                $writer = $null
            }
            if ($null -ne $archiveStream) {
                try {
                    $archiveStream.Dispose()
                } catch {
                    if ($null -eq $disposeError) {
                        $disposeError = $_
                    }
                }
            }
            if ($null -ne $writeError -or $null -ne $disposeError) {
                Throw-PackagingFailure -PrimaryError $writeError -CleanupError $disposeError
            }
        }
}

function Write-PackageHashRecord {
    param(
        [Parameter(Mandatory = $true)]$Profile,
        [Parameter(Mandatory = $true)][string]$PackageRoot,
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$ArchiveFileName,
        [string]$TestFaultInjectionStage = 'None',
        [switch]$TestInjectCleanupFailure
    )

    $safePackageRoot = Assert-SafeDestination -Path $PackageRoot -AllowRepositoryChild -AllowTempChild
    if (-not (Test-Path -LiteralPath $safePackageRoot -PathType Container)) {
        throw "Package root directory was not found: $safePackageRoot"
    }
    $hashPath = Assert-SafeDestination -Path $Path -AllowRepositoryChild -AllowTempChild
    if (Test-Path -LiteralPath $hashPath) {
        throw "Refusing to overwrite an existing package hash record: $hashPath"
    }
    $safeArchive = Assert-SafeDestination -Path $ArchivePath -AllowRepositoryChild -AllowTempChild
    if (-not (Test-Path -LiteralPath $safeArchive -PathType Leaf)) {
        throw "Package archive was not found: $safeArchive"
    }
    Assert-PackagingPathsDoNotOverlap -Paths @(
        [pscustomobject]@{ Name = 'package root'; Path = $safePackageRoot },
        [pscustomobject]@{ Name = 'archive source'; Path = $safeArchive },
        [pscustomobject]@{ Name = 'hash-record destination'; Path = $hashPath },
        [pscustomobject]@{ Name = 'hash-record staging probe'; Path = (Get-PackagingStagingProbePath -DestinationPath $hashPath) })
    Assert-PackageManifestMatchesRoot -Profile $Profile -PackageRoot $safePackageRoot | Out-Null
    $manifestPath = Join-Path $safePackageRoot 'package-manifest.json'
    $manifest = Read-PackageManifest -PackageRoot $safePackageRoot
    $archivePath = Get-FullPath -Path $safeArchive
    $manifestFullPath = Get-FullPath -Path $manifestPath
    $archiveName = [IO.Path]::GetFileName($archivePath)
    $archiveBytes = Get-PackagingFileLength -Path $archivePath
    $manifestBytes = Get-PackagingFileLength -Path $manifestFullPath
    $archiveHash = ((Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash).ToUpperInvariant()
    $manifestHash = ((Get-FileHash -LiteralPath $manifestFullPath -Algorithm SHA256).Hash).ToUpperInvariant()

    if ([string]::IsNullOrWhiteSpace($ArchiveFileName)) {
        $ArchiveFileName = $archiveName
    }
    if ($ArchiveFileName -match '[\\/]') {
        throw 'Package hash record archive file name must be a single file name.'
    }
    $lines = @(
        'HerdrOps package integrity record',
        'SchemaVersion: 1',
        "ProductId: $($Profile.productId)",
        "PackageVersion: $($Profile.packageVersion)",
        "RuntimeIdentifier: $($Profile.runtimeIdentifier)",
        "ArchiveFile: $ArchiveFileName",
        "ArchiveBytes: $archiveBytes",
        "ArchiveSha256: $archiveHash",
        'ManifestFile: package-manifest.json',
        "ManifestBytes: $manifestBytes",
        "ManifestSha256: $manifestHash",
        "ContentSha256: $($manifest.contentSha256)",
        'EvidenceClass: Static')
    $encoding = New-Object System.Text.UTF8Encoding($false)
    $bytes = $encoding.GetBytes(($lines -join "`n") + "`n")
    $writtenHashPath = Invoke-PackagingAtomicFileWrite `
        -DestinationPath $hashPath `
        -OperationName 'package hash record' `
        -TestFaultInjectionStage $TestFaultInjectionStage `
        -TestInjectCleanupFailure:$TestInjectCleanupFailure `
        -WriteStagedFile {
            param($stagingPath, $faultStage)
            Write-PackagingBytesToStagingFile `
                -Path $stagingPath `
                -Bytes $bytes `
                -OperationName 'package hash record' `
                -TestFaultInjectionStage $faultStage
        }

    Assert-PackageHashRecordMatchesArchive -Profile $Profile -PackageRoot $safePackageRoot -ArchivePath $safeArchive -HashRecordPath $writtenHashPath -ArchiveFileName $ArchiveFileName | Out-Null
    return [pscustomobject][ordered]@{
        ArchivePath = $archivePath
        ArchiveBytes = [int64]$archiveBytes
        ArchiveSha256 = $archiveHash
        ManifestPath = $manifestFullPath
        ManifestBytes = [int64]$manifestBytes
        ManifestSha256 = $manifestHash
        ContentSha256 = [string]$manifest.contentSha256
        HashRecordPath = $writtenHashPath
    }
}

function Read-PackageKeyValueRecord {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedHeader,
        [Parameter(Mandatory = $true)][string[]]$ExpectedKeys,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $fullPath = Assert-SafeDestination -Path $Path -AllowRepositoryChild -AllowTempChild
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "$Description was not found: $fullPath"
    }
    $text = [IO.File]::ReadAllText($fullPath)
    $normalized = $text.Replace(([string][char]13 + [string][char]10), [string][char]10).Replace([string][char]13, [string][char]10)
    if (-not $normalized.EndsWith([string][char]10, [StringComparison]::Ordinal)) {
        throw "$Description must end with one newline."
    }
    $lines = @($normalized.Substring(0, $normalized.Length - 1).Split([char]10))
    if ($lines.Count -ne ($ExpectedKeys.Count + 1) -or
        [string]$lines[0] -cne $ExpectedHeader) {
        throw "$Description has an unexpected header or line count."
    }

    $record = [ordered]@{}
    for ($index = 0; $index -lt $ExpectedKeys.Count; $index++) {
        $line = [string]$lines[$index + 1]
        $separator = $line.IndexOf([char]58)
        if ($separator -le 0 -or $separator + 1 -ge $line.Length -or
            $line[$separator + 1] -cne ' ') {
            throw "$Description line $($index + 1) is not a key-value line."
        }
        $key = $line.Substring(0, $separator)
        if ($key -cne $ExpectedKeys[$index]) {
            throw "$Description key order is not canonical at line $($index + 1)."
        }
        $record[$key] = $line.Substring($separator + 2)
    }

    return [pscustomobject]$record
}

function Read-PackageHashRecord {
    param([Parameter(Mandatory = $true)][string]$Path)

    return (Read-PackageKeyValueRecord -Path $Path -ExpectedHeader 'HerdrOps package integrity record' -ExpectedKeys @(
            'SchemaVersion',
            'ProductId',
            'PackageVersion',
            'RuntimeIdentifier',
            'ArchiveFile',
            'ArchiveBytes',
            'ArchiveSha256',
            'ManifestFile',
            'ManifestBytes',
            'ManifestSha256',
            'ContentSha256',
            'EvidenceClass') -Description 'Package hash record')
}

function Assert-PackageHashRecordMatchesArchive {
    param(
        [AllowNull()]$Profile,
        [Parameter(Mandatory = $true)][string]$PackageRoot,
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$HashRecordPath,
        [string]$ArchiveFileName
    )

    $safePackageRoot = Assert-SafeDestination -Path $PackageRoot -AllowRepositoryChild -AllowTempChild
    $safeArchive = Assert-SafeDestination -Path $ArchivePath -AllowRepositoryChild -AllowTempChild
    $safeHashRecord = Assert-SafeDestination -Path $HashRecordPath -AllowRepositoryChild -AllowTempChild
    if (-not (Test-Path -LiteralPath $safeArchive -PathType Leaf)) {
        throw "Package archive was not found: $safeArchive"
    }
    if (-not (Test-Path -LiteralPath $safeHashRecord -PathType Leaf)) {
        throw "Package hash record was not found: $safeHashRecord"
    }
    Assert-NoReparsePath -Path $safeArchive
    Assert-NoReparsePath -Path $safeHashRecord
    Assert-PackagingPathsDoNotOverlap -Paths @(
        [pscustomobject]@{ Name = 'package root'; Path = $safePackageRoot },
        [pscustomobject]@{ Name = 'archive'; Path = $safeArchive },
        [pscustomobject]@{ Name = 'hash record'; Path = $safeHashRecord })

    $archiveBytes = Get-PackagingFileLength -Path $safeArchive
    if ([string]::IsNullOrWhiteSpace($ArchiveFileName)) {
        $ArchiveFileName = [IO.Path]::GetFileName($safeArchive)
    }
    if ($ArchiveFileName -match '[\\/]') {
        throw 'Package hash record archive file name must be a single file name.'
    }

    $record = Read-PackageHashRecord -Path $safeHashRecord
    if ([string]$record.SchemaVersion -cne '1' -or
        [string]$record.ArchiveFile -cne $ArchiveFileName -or
        [string]$record.ManifestFile -cne 'package-manifest.json' -or
        [string]$record.EvidenceClass -cne 'Static') {
        throw 'Package hash record metadata is not bound to the expected package pair.'
    }
    if ([string]$record.ArchiveBytes -notmatch '^[0-9]+$' -or
        [string]$record.ManifestBytes -notmatch '^[0-9]+$') {
        throw 'Package hash record byte lengths are not unsigned decimal integers.'
    }
    if ([string]$record.ArchiveSha256 -notmatch '^[0-9A-F]{64}$' -or
        [string]$record.ManifestSha256 -notmatch '^[0-9A-F]{64}$' -or
        [string]$record.ContentSha256 -notmatch '^[0-9A-F]{64}$') {
        throw 'Package hash record SHA-256 values must be uppercase 64-character values.'
    }

    if ($null -ne $Profile) {
        Assert-PackageProfile -Profile $Profile
        if ([string]$record.ProductId -cne [string]$Profile.productId -or
            [string]$record.PackageVersion -cne [string]$Profile.packageVersion -or
            [string]$record.RuntimeIdentifier -cne [string]$Profile.runtimeIdentifier) {
            throw 'Package hash record product identity does not match the authorized profile.'
        }
    }

    $actualArchiveHash = ((Get-FileHash -LiteralPath $safeArchive -Algorithm SHA256).Hash).ToUpperInvariant()
    $actualArchiveBytes = [int64]$archiveBytes
    if ([int64]$record.ArchiveBytes -ne $actualArchiveBytes -or
        [string]$record.ArchiveSha256 -cne $actualArchiveHash) {
        throw 'Package hash record does not match independently computed archive bytes.'
    }

    $manifestPath = Join-Path $safePackageRoot 'package-manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Package manifest was not found for hash-record verification: $manifestPath"
    }
    if ($null -ne $Profile) {
        Assert-PackageManifestMatchesRoot -Profile $Profile -PackageRoot $safePackageRoot | Out-Null
    }
    $manifest = Read-PackageManifest -PackageRoot $safePackageRoot
    $manifestBytes = Get-PackagingFileLength -Path $manifestPath
    $actualManifestHash = ((Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash).ToUpperInvariant()
    if ([int64]$record.ManifestBytes -ne [int64]$manifestBytes -or
        [string]$record.ManifestSha256 -cne $actualManifestHash -or
        [string]$record.ContentSha256 -cne [string]$manifest.contentSha256) {
        throw 'Package hash record is not coherent with the independently verified package manifest.'
    }

    return [pscustomobject][ordered]@{
        ArchivePath = $safeArchive
        ArchiveBytes = $actualArchiveBytes
        ArchiveSha256 = $actualArchiveHash
        HashRecordPath = $safeHashRecord
        ManifestPath = (Get-FullPath -Path $manifestPath)
        ManifestBytes = [int64]$manifestBytes
        ManifestSha256 = $actualManifestHash
        ContentSha256 = [string]$manifest.contentSha256
    }
}

function Get-PackagingPairGenerationPath {
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$HashRecordPath
    )

    $archive = Normalize-ComparablePath -Path $ArchivePath
    $hashRecord = Normalize-ComparablePath -Path $HashRecordPath
    $archiveParent = Normalize-ComparablePath -Path (Split-Path -Path $archive -Parent)
    $hashParent = Normalize-ComparablePath -Path (Split-Path -Path $hashRecord -Parent)
    if (-not $archiveParent.Equals($hashParent, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Archive and hash record must share one parent for a single committed generation.'
    }

    $identity = [string]::Concat(
        ([IO.Path]::GetFileName($archive)).ToUpperInvariant(),
        [char]0,
        ([IO.Path]::GetFileName($hashRecord)).ToUpperInvariant())
    $token = (Get-Sha256ForText -Text $identity).Substring(0, 32)
    $generation = Join-Path $archiveParent ('.herdrops-package-pair-' + $token + '.generation')
    Assert-SafeDestination -Path $generation -AllowRepositoryChild -AllowTempChild | Out-Null
    return $generation
}

function Get-PackagingPairMetadataPath {
    param([Parameter(Mandatory = $true)][string]$ArchivePath, [Parameter(Mandatory = $true)][string]$HashRecordPath)

    return (Join-Path (Get-PackagingPairGenerationPath -ArchivePath $ArchivePath -HashRecordPath $HashRecordPath) 'generation.metadata')
}

function Get-PackagingPairCommitMarkerPath {
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$HashRecordPath
    )

    return (Join-Path (Get-PackagingPairGenerationPath -ArchivePath $ArchivePath -HashRecordPath $HashRecordPath) 'commit.marker')
}

function New-PackagingGenerationMetadataText {
    param(
        [Parameter(Mandatory = $true)][string]$GenerationKind,
        [Parameter(Mandatory = $true)][string]$PackageDirectory,
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$HashRecordPath
    )

    $archive = Normalize-ComparablePath -Path $ArchivePath
    $hashRecord = Normalize-ComparablePath -Path $HashRecordPath
    $archiveName = [IO.Path]::GetFileName($archive)
    $hashRecordName = [IO.Path]::GetFileName($hashRecord)
    $archiveBytes = Get-PackagingFileLength -Path $archive
    $hashRecordBytes = Get-PackagingFileLength -Path $hashRecord
    $archiveHash = ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash).ToUpperInvariant()
    $hashRecordHash = ((Get-FileHash -LiteralPath $hashRecord -Algorithm SHA256).Hash).ToUpperInvariant()
    $lines = @(
        'HerdrOps package committed generation metadata',
        'SchemaVersion: 1',
        "GenerationKind: $GenerationKind",
        "PackageDirectory: $PackageDirectory",
        "ArchiveFile: $archiveName",
        "HashRecordFile: $hashRecordName",
        "ArchiveBytes: $archiveBytes",
        "ArchiveSha256: $archiveHash",
        "HashRecordBytes: $hashRecordBytes",
        "HashRecordSha256: $hashRecordHash",
        'EvidenceClass: Static')
    return (($lines -join [char]10) + [char]10)
}

function Read-PackagingGenerationMetadata {
    param([Parameter(Mandatory = $true)][string]$Path)

    return (Read-PackageKeyValueRecord -Path $Path -ExpectedHeader 'HerdrOps package committed generation metadata' -ExpectedKeys @(
            'SchemaVersion',
            'GenerationKind',
            'PackageDirectory',
            'ArchiveFile',
            'HashRecordFile',
            'ArchiveBytes',
            'ArchiveSha256',
            'HashRecordBytes',
            'HashRecordSha256',
            'EvidenceClass') -Description 'Package generation metadata')
}

function New-PackagingGenerationCommitMarkerText {
    param(
        [Parameter(Mandatory = $true)][string]$GenerationRoot,
        [Parameter(Mandatory = $true)][string]$GenerationKind,
        [Parameter(Mandatory = $true)][string]$PackageDirectory,
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$HashRecordPath
    )

    $root = Normalize-ComparablePath -Path $GenerationRoot
    $archive = Normalize-ComparablePath -Path $ArchivePath
    $hashRecord = Normalize-ComparablePath -Path $HashRecordPath
    $metadataPath = Join-Path $root 'generation.metadata'
    if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
        throw "Package generation metadata must be closed before its commit marker: $metadataPath"
    }
    $archiveName = [IO.Path]::GetFileName($archive)
    $hashRecordName = [IO.Path]::GetFileName($hashRecord)
    $archiveBytes = Get-PackagingFileLength -Path $archive
    $hashRecordBytes = Get-PackagingFileLength -Path $hashRecord
    $archiveHash = ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash).ToUpperInvariant()
    $hashRecordHash = ((Get-FileHash -LiteralPath $hashRecord -Algorithm SHA256).Hash).ToUpperInvariant()
    $metadataBytes = Get-PackagingFileLength -Path $metadataPath
    $metadataHash = ((Get-FileHash -LiteralPath $metadataPath -Algorithm SHA256).Hash).ToUpperInvariant()
    $lines = @(
        'HerdrOps package generation commit marker',
        'SchemaVersion: 1',
        "GenerationKind: $GenerationKind",
        'MetadataFile: generation.metadata',
        "MetadataBytes: $metadataBytes",
        "MetadataSha256: $metadataHash",
        "PackageDirectory: $PackageDirectory",
        "ArchiveFile: $archiveName",
        "HashRecordFile: $hashRecordName",
        "ArchiveBytes: $archiveBytes",
        "ArchiveSha256: $archiveHash",
        "HashRecordBytes: $hashRecordBytes",
        "HashRecordSha256: $hashRecordHash",
        'EvidenceClass: Static')
    return (($lines -join [char]10) + [char]10)
}

function Read-PackagingGenerationCommitMarker {
    param([Parameter(Mandatory = $true)][string]$Path)

    return (Read-PackageKeyValueRecord -Path $Path -ExpectedHeader 'HerdrOps package generation commit marker' -ExpectedKeys @(
            'SchemaVersion',
            'GenerationKind',
            'MetadataFile',
            'MetadataBytes',
            'MetadataSha256',
            'PackageDirectory',
            'ArchiveFile',
            'HashRecordFile',
            'ArchiveBytes',
            'ArchiveSha256',
            'HashRecordBytes',
            'HashRecordSha256',
            'EvidenceClass') -Description 'Package generation commit marker')
}

function Read-PackagePairCommitMarker {
    param([Parameter(Mandatory = $true)][string]$Path)

    return (Read-PackagingGenerationCommitMarker -Path $Path)
}

function Assert-PackagingGenerationCommitted {
    param(
        [AllowNull()]$Profile,
        [Parameter(Mandatory = $true)][string]$GenerationRoot,
        [Parameter(Mandatory = $true)][string]$ExpectedGenerationKind,
        [Parameter(Mandatory = $true)][string]$ExpectedPackageDirectory,
        [AllowNull()][string]$PackageRoot
    )

    $root = Assert-SafeDestination -Path $GenerationRoot -AllowRepositoryChild -AllowTempChild
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        throw "Package generation directory was not found: $root"
    }
    Assert-NoReparsePath -Path $root
    Assert-NoReparseDescendants -Path $root
    $metadataPath = Join-Path $root 'generation.metadata'
    $markerPath = Join-Path $root 'commit.marker'
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
        throw "Package generation has no committed marker: $markerPath"
    }
    if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
        throw "Package generation has no committed metadata: $metadataPath"
    }

    $metadata = Read-PackagingGenerationMetadata -Path $metadataPath
    $marker = Read-PackagingGenerationCommitMarker -Path $markerPath
    if ([string]$metadata.SchemaVersion -cne '1' -or
        [string]$metadata.GenerationKind -cne $ExpectedGenerationKind -or
        [string]$metadata.PackageDirectory -cne $ExpectedPackageDirectory -or
        [string]$metadata.EvidenceClass -cne 'Static' -or
        [string]$marker.SchemaVersion -cne '1' -or
        [string]$marker.GenerationKind -cne $ExpectedGenerationKind -or
        [string]$marker.MetadataFile -cne 'generation.metadata' -or
        [string]$marker.PackageDirectory -cne $ExpectedPackageDirectory -or
        [string]$marker.EvidenceClass -cne 'Static') {
        throw 'Package generation metadata or commit marker identity is not exact.'
    }
    if ([string]::IsNullOrWhiteSpace([string]$metadata.ArchiveFile) -or
        [string]::IsNullOrWhiteSpace([string]$metadata.HashRecordFile) -or
        [string]$metadata.ArchiveFile -in @('.', '..') -or
        [string]$metadata.HashRecordFile -in @('.', '..') -or
        [string]$metadata.ArchiveFile -match '[\\/:*?"<>|]' -or
        [string]$metadata.HashRecordFile -match '[\\/:*?"<>|]' -or
        [string]$marker.ArchiveFile -cne [string]$metadata.ArchiveFile -or
        [string]$marker.HashRecordFile -cne [string]$metadata.HashRecordFile) {
        throw 'Package generation file identities are not exact single-file names.'
    }

    $archivePath = Join-Path $root ([string]$metadata.ArchiveFile)
    $hashRecordPath = Join-Path $root ([string]$metadata.HashRecordFile)
    if (-not (Test-PathWithin -ChildPath $archivePath -RootPath $root) -or
        -not (Test-PathWithin -ChildPath $hashRecordPath -RootPath $root)) {
        throw 'Package generation file identities escaped the committed generation directory.'
    }
    if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $hashRecordPath -PathType Leaf)) {
        throw 'Committed package generation is missing its archive or hash record.'
    }
    Assert-NoReparsePath -Path $archivePath
    Assert-NoReparsePath -Path $hashRecordPath
    $archiveBytes = Get-PackagingFileLength -Path $archivePath
    $hashRecordBytes = Get-PackagingFileLength -Path $hashRecordPath
    $archiveHash = ((Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash).ToUpperInvariant()
    $hashRecordHash = ((Get-FileHash -LiteralPath $hashRecordPath -Algorithm SHA256).Hash).ToUpperInvariant()
    $metadataBytes = Get-PackagingFileLength -Path $metadataPath
    $metadataHash = ((Get-FileHash -LiteralPath $metadataPath -Algorithm SHA256).Hash).ToUpperInvariant()
    if ([string]$metadata.ArchiveBytes -cne [string]$archiveBytes -or
        [string]$metadata.ArchiveSha256 -cne $archiveHash -or
        [string]$metadata.HashRecordBytes -cne [string]$hashRecordBytes -or
        [string]$metadata.HashRecordSha256 -cne $hashRecordHash -or
        [string]$marker.MetadataBytes -cne [string]$metadataBytes -or
        [string]$marker.MetadataSha256 -cne $metadataHash -or
        [string]$marker.ArchiveBytes -cne [string]$archiveBytes -or
        [string]$marker.ArchiveSha256 -cne $archiveHash -or
        [string]$marker.HashRecordBytes -cne [string]$hashRecordBytes -or
        [string]$marker.HashRecordSha256 -cne $hashRecordHash) {
        throw 'Package generation metadata or commit marker does not match independently computed bytes.'
    }

    $packageDirectoryPath = $null
    if ($ExpectedPackageDirectory -ne '-') {
        $packageDirectoryPath = Join-Path $root $ExpectedPackageDirectory
        if (-not (Test-Path -LiteralPath $packageDirectoryPath -PathType Container)) {
            throw "Committed package generation is missing its package directory: $packageDirectoryPath"
        }
        Assert-NoReparsePath -Path $packageDirectoryPath
    }
    if (-not [string]::IsNullOrWhiteSpace($PackageRoot)) {
        $pair = Assert-PackageHashRecordMatchesArchive `
            -Profile $Profile `
            -PackageRoot $PackageRoot `
            -ArchivePath $archivePath `
            -HashRecordPath $hashRecordPath `
            -ArchiveFileName ([IO.Path]::GetFileName($archivePath))
    } else {
        $pair = Assert-PackageHashRecordMatchesArchive `
            -Profile $Profile `
            -PackageRoot $packageDirectoryPath `
            -ArchivePath $archivePath `
            -HashRecordPath $hashRecordPath `
            -ArchiveFileName ([IO.Path]::GetFileName($archivePath))
    }

    return [pscustomobject][ordered]@{
        GenerationRoot = (Get-FullPath -Path $root)
        PackageRoot = if ($null -ne $packageDirectoryPath) { Get-FullPath -Path $packageDirectoryPath } else { $null }
        ArchivePath = $pair.ArchivePath
        HashRecordPath = $pair.HashRecordPath
        MetadataPath = (Get-FullPath -Path $metadataPath)
        CommitMarkerPath = (Get-FullPath -Path $markerPath)
        ArchiveBytes = $pair.ArchiveBytes
        ArchiveSha256 = $pair.ArchiveSha256
        ManifestPath = $pair.ManifestPath
        ManifestBytes = $pair.ManifestBytes
        ManifestSha256 = $pair.ManifestSha256
        ContentSha256 = $pair.ContentSha256
    }
}

function Assert-PackagedGenerationCommitted {
    param(
        [Parameter(Mandatory = $true)]$Profile,
        [Parameter(Mandatory = $true)][string]$GenerationRoot,
        [Parameter(Mandatory = $true)][string]$ExpectedGenerationKind
    )

    return (Assert-PackagingGenerationCommitted `
        -Profile $Profile `
        -GenerationRoot $GenerationRoot `
        -ExpectedGenerationKind $ExpectedGenerationKind `
        -ExpectedPackageDirectory 'package')
}

function Assert-PackageArchiveHashPairCommitted {
    param(
        [AllowNull()]$Profile,
        [Parameter(Mandatory = $true)][string]$PackageRoot,
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$HashRecordPath
    )

    $safeArchive = Assert-SafeDestination -Path $ArchivePath -AllowRepositoryChild -AllowTempChild
    $safeHashRecord = Assert-SafeDestination -Path $HashRecordPath -AllowRepositoryChild -AllowTempChild
    $generationPath = Get-PackagingPairGenerationPath -ArchivePath $safeArchive -HashRecordPath $safeHashRecord
    return (Assert-PackagingGenerationCommitted `
        -Profile $Profile `
        -GenerationRoot $generationPath `
        -ExpectedGenerationKind 'ArchiveHashPair' `
        -ExpectedPackageDirectory '-' `
        -PackageRoot $PackageRoot)
}

function Publish-PackageArchiveAndHashAtomically {
    param(
        [Parameter(Mandatory = $true)]$Profile,
        [Parameter(Mandatory = $true)][string]$PackageRoot,
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$HashRecordPath,
        [string]$TestFaultInjectionStage = 'None',
        [switch]$TestInjectCleanupFailure
    )

    if ($TestFaultInjectionStage -notin @(
            'None',
            'Archive',
            'Hash',
            'AfterArchive',
            'AfterHash',
            'AfterMetadata',
            'Verify',
            'BeforeCommit',
            'AfterArchiveMove',
            'AfterHashMove',
            'AfterArchiveCommit',
            'AfterHashCommit',
            'CommitMarker',
            'AfterRenameBeforeReturn')) {
        throw "Unsupported package archive pair fault-injection stage: $TestFaultInjectionStage"
    }

    Assert-V070PreparationProfile -Profile $Profile
    $safePackageRoot = Assert-SafeDestination -Path $PackageRoot -AllowRepositoryChild -AllowTempChild
    if (-not (Test-Path -LiteralPath $safePackageRoot -PathType Container)) {
        throw "Package root directory was not found: $safePackageRoot"
    }
    Assert-NoReparsePath -Path $safePackageRoot
    $safeArchive = Assert-SafeDestination -Path $ArchivePath -AllowRepositoryChild -AllowTempChild
    $safeHashRecord = Assert-SafeDestination -Path $HashRecordPath -AllowRepositoryChild -AllowTempChild
    $generationPath = Get-PackagingPairGenerationPath -ArchivePath $safeArchive -HashRecordPath $safeHashRecord
    $pairParent = Split-Path -Path $safeArchive -Parent
    if (-not (Test-Path -LiteralPath $pairParent -PathType Container)) {
        New-Item -ItemType Directory -Path $pairParent -Force | Out-Null
    }
    Assert-NoReparsePath -Path $pairParent
    Assert-PackagingPathsDoNotOverlap -Paths @(
        [pscustomobject]@{ Name = 'package root'; Path = $safePackageRoot },
        [pscustomobject]@{ Name = 'archive destination'; Path = $safeArchive },
        [pscustomobject]@{ Name = 'hash-record destination'; Path = $safeHashRecord },
        [pscustomobject]@{ Name = 'committed generation'; Path = $generationPath },
        [pscustomobject]@{ Name = 'pair staging probe'; Path = (Get-PackagingStagingProbePath -DestinationPath $generationPath -Directory) })

    $generationName = [IO.Path]::GetFileName($generationPath)
    Remove-PackagingOrphanedStagingDirectories `
        -Parent $pairParent `
        -DestinationName $generationName `
        -Description 'archive/hash pair generation'
    if (Test-Path -LiteralPath $generationPath) {
        $existingGeneration = Get-Item -LiteralPath $generationPath -Force
        if (-not $existingGeneration.PSIsContainer -or
            ($existingGeneration.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Committed archive/hash generation path is not a safe directory: $generationPath"
        }
        if (Test-Path -LiteralPath (Join-Path $generationPath 'commit.marker') -PathType Leaf) {
            return (Assert-PackageArchiveHashPairCommitted `
                -Profile $Profile `
                -PackageRoot $safePackageRoot `
                -ArchivePath $safeArchive `
                -HashRecordPath $safeHashRecord)
        }
        Remove-PackagingUncommittedGenerationDirectory `
            -Path $generationPath `
            -Description 'archive/hash pair generation'
    }
    foreach ($legacyPath in @($safeArchive, $safeHashRecord)) {
        if (Test-Path -LiteralPath $legacyPath) {
            throw "Refusing to overwrite an existing flat archive/hash path; use the committed generation lookup: $legacyPath"
        }
    }

    $stagingRoot = $null
    $committed = $false
    $primaryError = $null
    $cleanupErrors = @()
    try {
        $stagingRoot = New-PackagingStagingDirectory -OutputRoot $generationPath
        $stagingArchive = Join-Path $stagingRoot ([IO.Path]::GetFileName($safeArchive))
        $stagingHashRecord = Join-Path $stagingRoot ([IO.Path]::GetFileName($safeHashRecord))

        $archiveStage = if ($TestFaultInjectionStage -eq 'Archive') { 'MidWrite' } else { 'None' }
        New-DeterministicPackageArchive `
            -PackageRoot $safePackageRoot `
            -ArchivePath $stagingArchive `
            -TestFaultInjectionStage $archiveStage | Out-Null
        if ($TestFaultInjectionStage -eq 'AfterArchive') {
            throw 'Injected package archive pair failure after archive staging.'
        }

        $hashStage = if ($TestFaultInjectionStage -eq 'Hash') { 'MidWrite' } else { 'None' }
        Write-PackageHashRecord `
            -Profile $Profile `
            -PackageRoot $safePackageRoot `
            -ArchivePath $stagingArchive `
            -ArchiveFileName ([IO.Path]::GetFileName($safeArchive)) `
            -Path $stagingHashRecord `
            -TestFaultInjectionStage $hashStage | Out-Null
        if ($TestFaultInjectionStage -eq 'AfterHash') {
            throw 'Injected package archive pair failure after hash-record staging.'
        }

        Assert-PackageHashRecordMatchesArchive `
            -Profile $Profile `
            -PackageRoot $safePackageRoot `
            -ArchivePath $stagingArchive `
            -HashRecordPath $stagingHashRecord `
            -ArchiveFileName ([IO.Path]::GetFileName($safeArchive)) | Out-Null
        if ($TestFaultInjectionStage -eq 'Verify') {
            throw 'Injected package archive pair verification failure.'
        }

        $metadataPath = Join-Path $stagingRoot 'generation.metadata'
        $metadataText = New-PackagingGenerationMetadataText `
            -GenerationKind 'ArchiveHashPair' `
            -PackageDirectory '-' `
            -ArchivePath $stagingArchive `
            -HashRecordPath $stagingHashRecord
        Write-PackagingBytesToStagingFile `
            -Path $metadataPath `
            -Bytes (New-Object System.Text.UTF8Encoding($false)).GetBytes($metadataText) `
            -OperationName 'package archive/hash generation metadata'
        if ($TestFaultInjectionStage -eq 'AfterMetadata') {
            throw 'Injected package archive pair failure after generation metadata.'
        }
        $markerPath = Join-Path $stagingRoot 'commit.marker'
        $markerText = New-PackagingGenerationCommitMarkerText `
            -GenerationRoot $stagingRoot `
            -GenerationKind 'ArchiveHashPair' `
            -PackageDirectory '-' `
            -ArchivePath $stagingArchive `
            -HashRecordPath $stagingHashRecord
        Write-PackagingBytesToStagingFile `
            -Path $markerPath `
            -Bytes (New-Object System.Text.UTF8Encoding($false)).GetBytes($markerText) `
            -OperationName 'package archive/hash generation commit marker'
        if ($TestFaultInjectionStage -in @('BeforeCommit', 'AfterArchiveMove', 'AfterHashMove', 'AfterArchiveCommit', 'AfterHashCommit', 'CommitMarker')) {
            throw 'Injected package archive pair failure before atomic generation rename.'
        }

        if (Test-Path -LiteralPath $generationPath) {
            throw "Refusing to overwrite an archive/hash generation that appeared during staging: $generationPath"
        }
        [IO.Directory]::Move($stagingRoot, $generationPath)
        $committed = $true
        $stagingRoot = $null
        if ($TestFaultInjectionStage -eq 'AfterRenameBeforeReturn') {
            throw 'Injected package archive pair failure after generation rename before caller return.'
        }
    } catch {
        $primaryError = $_
    }

    try {
        if (-not $committed -and $null -ne $stagingRoot -and (Test-Path -LiteralPath $stagingRoot)) {
            Remove-PackagingStagingDirectory -Path $stagingRoot
        }
    } catch {
        $cleanupErrors += $_
    }
    try {
        if (-not $committed -and $TestInjectCleanupFailure) {
            throw 'Injected package archive pair cleanup failure.'
        }
    } catch {
        $cleanupErrors += $_
    }

    if ($null -ne $primaryError -or $cleanupErrors.Count -gt 0) {
        Throw-PackagingFailure -PrimaryError $primaryError -CleanupErrors $cleanupErrors
    }

    return (Assert-PackageArchiveHashPairCommitted `
        -Profile $Profile `
        -PackageRoot $safePackageRoot `
        -ArchivePath $safeArchive `
        -HashRecordPath $safeHashRecord)
}
