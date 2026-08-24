#requires -Version 5.1

Set-StrictMode -Version Latest

function Assert-V02BuiltAppFixturePathChain {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Context
    )
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $current = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    if ($current -cne $rootFull -and -not $current.StartsWith($rootFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Context escaped the exact repository root."
    }
    while ($true) {
        if (Test-Path -LiteralPath $current) {
            if (((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "$Context contains a reparse point at '$current'."
            }
        }
        if ($current -ceq $rootFull) { break }
        $parent = [IO.Path]::GetDirectoryName($current)
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent.Length -ge $current.Length) {
            throw "$Context ancestor traversal did not reach the exact repository root."
        }
        $current = $parent.TrimEnd('\', '/')
    }
}

function Resolve-V02BuiltAppFixtureDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][DateTime]$BuildStartedUtc,
        [ValidateSet('Release')][string]$Configuration = 'Release',
        [ValidateSet('net10.0-windows')][string]$TargetFramework = 'net10.0-windows',
        [ValidateSet('win-x64')][string]$RuntimeIdentifier = 'win-x64'
    )

    $root = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd('\', '/')
    if ($BuildStartedUtc.Kind -ne [DateTimeKind]::Utc) {
        throw 'BuildStartedUtc must be an exact UTC timestamp captured before the governed build.'
    }
    $projectDirectory = Join-Path $root 'src\HerdrOps.App'
    $projectPath = Join-Path $projectDirectory 'HerdrOps.App.csproj'
    if (-not (Test-Path -LiteralPath $projectPath -PathType Leaf)) {
        throw "The exact HerdrOps.App project is missing: '$projectPath'."
    }
    Assert-V02BuiltAppFixturePathChain $root $projectPath 'The exact HerdrOps.App project path'

    try {
        [xml]$project = [IO.File]::ReadAllText($projectPath)
    } catch {
        throw "The exact HerdrOps.App project could not be parsed: $($_.Exception.Message)"
    }
    $frameworks = @($project.Project.PropertyGroup.TargetFramework | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    $runtimeIdentifiers = @($project.Project.PropertyGroup.RuntimeIdentifiers | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($frameworks.Count -ne 1 -or [string]$frameworks[0] -cne $TargetFramework) {
        throw "HerdrOps.App does not declare the exact governed target framework '$TargetFramework'."
    }
    if ($runtimeIdentifiers.Count -ne 1) {
        throw 'HerdrOps.App must declare exactly one RuntimeIdentifiers property for the governed fixture.'
    }
    $declaredRuntimeIdentifiers = @(([string]$runtimeIdentifiers[0]).Split(';', [StringSplitOptions]::RemoveEmptyEntries))
    if ($declaredRuntimeIdentifiers.Count -ne 1 -or $declaredRuntimeIdentifiers[0] -cne $RuntimeIdentifier) {
        throw "HerdrOps.App does not declare the exact governed runtime identifier '$RuntimeIdentifier'."
    }

    $frameworkOutput = Join-Path $projectDirectory "bin\$Configuration\$TargetFramework"
    $supportedDirectories = @(
        (Join-Path $root "artifacts\bin\HerdrOps.App\$($Configuration.ToLowerInvariant())"),
        $frameworkOutput,
        (Join-Path $frameworkOutput $RuntimeIdentifier)
    )
    $admitted = @()
    foreach ($directory in $supportedDirectories) {
        $appPath = Join-Path $directory 'HerdrOps.App.exe'
        if (-not (Test-Path -LiteralPath $appPath -PathType Leaf)) { continue }
        Assert-V02BuiltAppFixturePathChain $root $directory "Built App fixture '$directory'"
        $complete = $true
        foreach ($requiredName in @(
                'HerdrOps.App.exe',
                'HerdrOps.App.dll',
                'HerdrOps.App.deps.json',
                'HerdrOps.App.runtimeconfig.json')) {
            $requiredPath = Join-Path $directory $requiredName
            if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
                $complete = $false
                break
            }
            Assert-V02BuiltAppFixturePathChain $root $requiredPath "Built App fixture '$requiredPath'"
            if ((Get-Item -LiteralPath $requiredPath -Force).LastWriteTimeUtc -lt $BuildStartedUtc) {
                $complete = $false
                break
            }
        }
        if (-not $complete) { continue }
        $admitted += ,([IO.Path]::GetFullPath($directory).TrimEnd('\', '/'))
    }

    if ($admitted.Count -eq 0) {
        throw "No fresh exact HerdrOps.App fixture exists for project/configuration/TFM/RID '$Configuration/$TargetFramework/$RuntimeIdentifier' after '$($BuildStartedUtc.ToString('O'))'."
    }
    if ($admitted.Count -ne 1) {
        throw "HerdrOps.App fixture output is ambiguous across the supported TFM and RID layouts: $($admitted -join ', ')."
    }
    return $admitted[0]
}
