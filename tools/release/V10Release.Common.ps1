#requires -Version 5.1

Set-StrictMode -Version Latest

$packagingCommonPath = Join-Path $PSScriptRoot '..\packaging\Packaging.Common.ps1'
if (-not (Test-Path -LiteralPath $packagingCommonPath -PathType Leaf)) {
    throw "Packaging common library is missing: $packagingCommonPath"
}
. $packagingCommonPath

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
        [string]$Profile.repository -cne 'OSHEThai/HerdrOps') {
        throw 'The v1 release profile must be bound exactly to Issue #45, v1.0.0, and OSHEThai/HerdrOps.'
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

function Assert-V10GateReport {
    param(
        [Parameter(Mandatory = $true)][int]$Issue,
        [Parameter(Mandatory = $true)][string]$EvidenceClass,
        [Parameter(Mandatory = $true)]$Report,
        [Parameter(Mandatory = $true)][string]$SourceCommit,
        [Parameter(Mandatory = $true)][string]$ArchiveSha256
    )

    $value = $Report.Value
    switch ($Issue) {
        41 {
            if ([int](Get-V10RequiredProperty -Object $value -Name 'SchemaVersion' -Description 'Issue #41 report') -ne 1 -or
                [string](Get-V10RequiredProperty -Object $value -Name 'AuditId' -Description 'Issue #41 report') -cne 'V100-01' -or
                [string](Get-V10RequiredProperty -Object $value -Name 'SourceCommit' -Description 'Issue #41 report') -cne $SourceCommit -or
                [string](Get-V10RequiredProperty -Object $value -Name 'WorkingTree' -Description 'Issue #41 report') -cne 'CLEAN' -or
                [string](Get-V10RequiredProperty -Object $value -Name 'Decision' -Description 'Issue #41 report') -cne 'READY') {
                throw 'Issue #41 dependency audit is not READY for the accepted commit.'
            }
            $candidate = Get-V10RequiredProperty -Object $value -Name 'ReleaseCandidate' -Description 'Issue #41 report'
            if ([string](Get-V10RequiredProperty -Object $candidate -Name 'Status' -Description 'Issue #41 release candidate') -cne 'RECORDED' -or
                [string](Get-V10RequiredProperty -Object $candidate -Name 'Commit' -Description 'Issue #41 release candidate') -cne $SourceCommit) {
                throw 'Issue #41 did not record the exact accepted release-candidate commit.'
            }
            $query = Get-V10RequiredProperty -Object $value -Name 'Query' -Description 'Issue #41 report'
            if ([string](Get-V10RequiredProperty -Object $query -Name 'Source' -Description 'Issue #41 query') -cne 'GitHub gh api (read-only)' -or
                @(Get-V10RequiredProperty -Object $value -Name 'Blockers' -Description 'Issue #41 report').Count -ne 0) {
                throw 'Issue #41 dependency audit must be GitHub-backed and contain zero blockers.'
            }
        }
        42 {
            if ([int](Get-V10RequiredProperty -Object $value -Name 'schemaVersion' -Description 'Issue #42 report') -ne 1 -or
                [string](Get-V10RequiredProperty -Object $value -Name 'reportKind' -Description 'Issue #42 report') -cne 'HerdrOps.V10SoakAcceptanceReport' -or
                [int](Get-V10RequiredProperty -Object $value -Name 'issue' -Description 'Issue #42 report') -ne 42 -or
                [string](Get-V10RequiredProperty -Object $value -Name 'acceptanceVersion' -Description 'Issue #42 report') -cne 'v1.0.0' -or
                [string](Get-V10RequiredProperty -Object $value -Name 'status' -Description 'Issue #42 report') -cne 'PASS' -or
                [string](Get-V10RequiredProperty -Object $value -Name 'evidenceClass' -Description 'Issue #42 report') -cne 'Runtime' -or
                [string](Get-V10RequiredProperty -Object $value -Name 'sourceCommit' -Description 'Issue #42 report') -cne $SourceCommit -or
                [string](Get-V10RequiredProperty -Object $value -Name 'candidateArchiveSha256' -Description 'Issue #42 report') -cne $ArchiveSha256 -or
                [decimal](Get-V10RequiredProperty -Object $value -Name 'durationHours' -Description 'Issue #42 report') -lt [decimal]24 -or
                -not [bool](Get-V10RequiredProperty -Object $value -Name 'actualHerdrObserved' -Description 'Issue #42 report') -or
                [int](Get-V10RequiredProperty -Object $value -Name 'unhandledCrashes' -Description 'Issue #42 report') -ne 0 -or
                [int](Get-V10RequiredProperty -Object $value -Name 'unreconciledStates' -Description 'Issue #42 report') -ne 0 -or
                [string](Get-V10RequiredProperty -Object $value -Name 'reconnectResult' -Description 'Issue #42 report') -cne 'PASS' -or
                [string](Get-V10RequiredProperty -Object $value -Name 'faultInjectionResult' -Description 'Issue #42 report') -cne 'PASS' -or
                [string](Get-V10RequiredProperty -Object $value -Name 'databaseIntegrityResult' -Description 'Issue #42 report') -cne 'PASS' -or
                [string](Get-V10RequiredProperty -Object $value -Name 'alertConsistencyResult' -Description 'Issue #42 report') -cne 'PASS') {
                throw 'Issue #42 report does not prove the exact 24-hour actual-Herdr candidate acceptance.'
            }
            Assert-V10UtcTimestamp -Value ([string](Get-V10RequiredProperty -Object $value -Name 'completedAtUtc' -Description 'Issue #42 report')) -Description 'Issue #42 completedAtUtc'
        }
        43 {
            if ([int](Get-V10RequiredProperty -Object $value -Name 'schemaVersion' -Description 'Issue #43 report') -ne 1 -or
                [string](Get-V10RequiredProperty -Object $value -Name 'reportKind' -Description 'Issue #43 report') -cne 'HerdrOps.V10SecurityPrivacyReviewReport' -or
                [int](Get-V10RequiredProperty -Object $value -Name 'issue' -Description 'Issue #43 report') -ne 43 -or
                [string](Get-V10RequiredProperty -Object $value -Name 'reviewVersion' -Description 'Issue #43 report') -cne 'v1.0.0' -or
                [string](Get-V10RequiredProperty -Object $value -Name 'status' -Description 'Issue #43 report') -cne 'PASS' -or
                [string](Get-V10RequiredProperty -Object $value -Name 'evidenceClass' -Description 'Issue #43 report') -cne 'IndependentReview' -or
                [string](Get-V10RequiredProperty -Object $value -Name 'sourceCommit' -Description 'Issue #43 report') -cne $SourceCommit -or
                [string](Get-V10RequiredProperty -Object $value -Name 'candidateArchiveSha256' -Description 'Issue #43 report') -cne $ArchiveSha256 -or
                [string](Get-V10RequiredProperty -Object $value -Name 'verdict' -Description 'Issue #43 report') -cne 'PASS' -or
                [int](Get-V10RequiredProperty -Object $value -Name 'unresolvedHighFindings' -Description 'Issue #43 report') -ne 0 -or
                [string]::IsNullOrWhiteSpace([string](Get-V10RequiredProperty -Object $value -Name 'reviewer' -Description 'Issue #43 report'))) {
                throw 'Issue #43 report does not contain a passing role-distinct final review for the exact candidate.'
            }
            Assert-V10UtcTimestamp -Value ([string](Get-V10RequiredProperty -Object $value -Name 'completedAtUtc' -Description 'Issue #43 report')) -Description 'Issue #43 completedAtUtc'
        }
        44 {
            if ([int](Get-V10RequiredProperty -Object $value -Name 'schemaVersion' -Description 'Issue #44 report') -ne 1 -or
                [string](Get-V10RequiredProperty -Object $value -Name 'reportKind' -Description 'Issue #44 report') -cne 'HerdrOps.InstallAcceptanceReport' -or
                [int](Get-V10RequiredProperty -Object $value -Name 'issue' -Description 'Issue #44 report') -ne 44 -or
                [string](Get-V10RequiredProperty -Object $value -Name 'acceptanceVersion' -Description 'Issue #44 report') -cne 'v1.0.0' -or
                [string](Get-V10RequiredProperty -Object $value -Name 'status' -Description 'Issue #44 report') -cne 'PASS' -or
                [string](Get-V10RequiredProperty -Object $value -Name 'mode' -Description 'Issue #44 report') -cne 'Live' -or
                [string](Get-V10RequiredProperty -Object $value -Name 'evidenceClass' -Description 'Issue #44 report') -cne 'CleanMachine') {
                throw 'Issue #44 report is not passing Live CleanMachine evidence.'
            }
            $machine = Get-V10RequiredProperty -Object $value -Name 'machine' -Description 'Issue #44 report'
            if ([bool](Get-V10RequiredProperty -Object $machine -Name 'elevated' -Description 'Issue #44 machine')) {
                throw 'Issue #44 clean-machine acceptance was elevated.'
            }
            $artifacts = Get-V10RequiredProperty -Object $value -Name 'artifacts' -Description 'Issue #44 report'
            $upgrade = Get-V10RequiredProperty -Object $artifacts -Name 'upgrade' -Description 'Issue #44 artifacts'
            if ([string](Get-V10RequiredProperty -Object $upgrade -Name 'packageVersion' -Description 'Issue #44 upgrade artifact') -cne '1.0.0' -or
                [string](Get-V10RequiredProperty -Object $upgrade -Name 'sourceCommitBinding' -Description 'Issue #44 upgrade artifact') -cne $SourceCommit -or
                [string](Get-V10RequiredProperty -Object $upgrade -Name 'archiveSha256' -Description 'Issue #44 upgrade artifact') -cne $ArchiveSha256) {
                throw 'Issue #44 accepted a different source commit or archive.'
            }
            $lifecycle = Get-V10RequiredProperty -Object $value -Name 'lifecycle' -Description 'Issue #44 report'
            foreach ($step in @('cleanInstall', 'upgrade', 'rollback', 'uninstall')) {
                $stepValue = Get-V10RequiredProperty -Object $lifecycle -Name $step -Description 'Issue #44 lifecycle'
                if ([string](Get-V10RequiredProperty -Object $stepValue -Name 'status' -Description "Issue #44 $step") -cne 'PASS') {
                    throw "Issue #44 lifecycle step '$step' did not pass."
                }
            }
            $cleanup = Get-V10RequiredProperty -Object $value -Name 'cleanup' -Description 'Issue #44 report'
            if ([string](Get-V10RequiredProperty -Object $cleanup -Name 'status' -Description 'Issue #44 cleanup') -cne 'PASS' -or
                -not [string]::IsNullOrEmpty([string](Get-V10RequiredProperty -Object $value -Name 'failureDetails' -Description 'Issue #44 report' -AllowNull))) {
                throw 'Issue #44 cleanup or failure state is not a complete pass.'
            }
            Assert-V10UtcTimestamp -Value ([string](Get-V10RequiredProperty -Object $value -Name 'completedAtUtc' -Description 'Issue #44 report')) -Description 'Issue #44 completedAtUtc'
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
        Assert-V10GateReport -Issue ([int]$gate.issue) -EvidenceClass ([string]$gate.evidenceClass) -Report $report -SourceCommit $acceptedCommit -ArchiveSha256 $candidate.ArchiveSha256
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
        ReleaseNotesPath = $releaseNotesPath
        ReleaseNotesSha256 = $releaseNotesHash
        Status = 'READY_TO_PUBLISH'
        EvidenceClass = 'Static'
        Release = 'NOT OBSERVED'
    }
}
