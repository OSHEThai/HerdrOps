#requires -Version 5.1

[CmdletBinding()]
param(
    [string]$ProfilePath,
    [string]$FixtureRoot,
    [switch]$KeepSimulationRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Packaging.Common.ps1')

if ([string]::IsNullOrWhiteSpace($ProfilePath)) {
    $ProfilePath = Join-Path $PSScriptRoot 'package-profile.json'
}
if ([string]::IsNullOrWhiteSpace($FixtureRoot)) {
    $FixtureRoot = Join-Path $PSScriptRoot '..\..\tests\fixtures\v0.7\packaging'
}

function New-SyntheticVersionProfile {
    param(
        [Parameter(Mandatory = $true)]$BaseProfile,
        [Parameter(Mandatory = $true)][string]$Version
    )

    $clone = ($BaseProfile | ConvertTo-Json -Depth 20 | ConvertFrom-Json)
    $upgradeProperty = @($clone.PSObject.Properties | Where-Object { $_.Name -eq 'syntheticUpgradeVersion' })
    if ($upgradeProperty.Count -eq 1) {
        $clone.PSObject.Properties.Remove('syntheticUpgradeVersion')
    }
    $clone.packageVersion = $Version
    Assert-PackageProfile -Profile $clone
    return $clone
}

$profile = Read-PackageProfile -Path $ProfilePath
$repositoryRoot = Get-PackagingRepositoryRoot
$fixtureRootFull = Normalize-ComparablePath -Path $FixtureRoot
if (-not (Test-Path -LiteralPath $fixtureRootFull -PathType Container)) {
    throw "Synthetic packaging fixture root was not found: $fixtureRootFull"
}
if (-not (Test-PathWithin -ChildPath $fixtureRootFull -RootPath $repositoryRoot)) {
    throw 'Synthetic fixtures must remain inside the authorized repository root.'
}

$initialVersion = [string]$profile.packageVersion
$upgradeVersion = [string]$profile.syntheticUpgradeVersion
$initialFixture = Join-Path $fixtureRootFull 'initial'
$upgradeFixture = Join-Path $fixtureRootFull 'upgrade'
foreach ($fixture in @($initialFixture, $upgradeFixture)) {
    if (-not (Test-Path -LiteralPath $fixture -PathType Container)) {
        throw "Synthetic packaging fixture is missing: $fixture"
    }
    Assert-NoReparsePath -Path $fixture
}

$upgradeProfile = New-SyntheticVersionProfile -BaseProfile $profile -Version $upgradeVersion
$simulationRoot = New-PackagingTempDirectory -Prefix 'HerdrOps-Synthetic-'
try {
    $initialPackageRoot = Join-Path $simulationRoot ('packages\' + $initialVersion)
    $upgradePackageRoot = Join-Path $simulationRoot ('packages\' + $upgradeVersion)
    $installRoot = Join-Path $simulationRoot 'install\HerdrOps'
    $userDataRoot = Join-Path $simulationRoot 'user-data\HerdrOps'
    $userDataStateRoot = Join-Path $userDataRoot 'state'

    Copy-SafeDirectoryContents -Source $initialFixture -Destination $initialPackageRoot
    Copy-SafeDirectoryContents -Source $upgradeFixture -Destination $upgradePackageRoot
    $initialManifest = New-PackageManifestObject -Profile $profile -PackageRoot $initialPackageRoot
    Write-PackageManifest -Manifest $initialManifest -PackageRoot $initialPackageRoot | Out-Null
    $upgradeManifest = New-PackageManifestObject -Profile $upgradeProfile -PackageRoot $upgradePackageRoot
    Write-PackageManifest -Manifest $upgradeManifest -PackageRoot $upgradePackageRoot | Out-Null
    Assert-PackageManifestMatchesRoot -Profile $profile -PackageRoot $initialPackageRoot | Out-Null
    Assert-PackageManifestMatchesRoot -Profile $upgradeProfile -PackageRoot $upgradePackageRoot | Out-Null

    New-Item -ItemType Directory -Path $userDataStateRoot -Force | Out-Null
    $retainedDataPath = Join-Path $userDataStateRoot 'herdrops.db'
    Write-DeterministicTextFile -Path $retainedDataPath -Text 'synthetic retained user data; never opened by HerdrOps.'
    $retainedDataHashBefore = ((Get-FileHash -LiteralPath $retainedDataPath -Algorithm SHA256).Hash).ToUpperInvariant()

    Copy-SafeDirectoryContents -Source $initialPackageRoot -Destination $installRoot
    $installedVersionPath = Join-Path $installRoot 'payload-version.txt'
    if (-not (Test-Path -LiteralPath $installedVersionPath -PathType Leaf) -or
        (Get-Content -LiteralPath $installedVersionPath -Raw).Trim() -ne $initialVersion) {
        throw 'Synthetic clean install did not produce the initial package payload.'
    }

    Copy-SafeDirectoryContents -Source $upgradePackageRoot -Destination $installRoot -Overwrite
    if (-not (Test-Path -LiteralPath (Join-Path $installRoot 'upgrade-marker.txt') -PathType Leaf) -or
        (Get-Content -LiteralPath $installedVersionPath -Raw).Trim() -ne $upgradeVersion) {
        throw 'Synthetic in-place upgrade did not replace the package payload.'
    }
    if (-not (Test-Path -LiteralPath $retainedDataPath -PathType Leaf)) {
        throw 'Synthetic upgrade removed retained user data.'
    }

    Assert-SafeDestination -Path $installRoot -AllowTempChild | Out-Null
    Remove-Item -LiteralPath $installRoot -Recurse -Force
    if (Test-Path -LiteralPath $installRoot) {
        throw 'Synthetic uninstall did not remove the package directory.'
    }
    if (-not (Test-Path -LiteralPath $retainedDataPath -PathType Leaf)) {
        throw 'Synthetic uninstall removed retained user data.'
    }
    $retainedDataHashAfter = ((Get-FileHash -LiteralPath $retainedDataPath -Algorithm SHA256).Hash).ToUpperInvariant()
    if ($retainedDataHashBefore -cne $retainedDataHashAfter) {
        throw 'Retained synthetic user-data bytes changed during uninstall.'
    }

    $startupSimulationPath = Join-Path $simulationRoot 'startup-registration'
    if (Test-Path -LiteralPath $startupSimulationPath) {
        throw 'Synthetic lifecycle unexpectedly created a startup-registration path.'
    }

    $report = [ordered]@{
        EvidenceClass = 'Synthetic'
        Issue = [int]$profile.issue
        BasePackageVersion = $initialVersion
        UpgradePackageVersion = $upgradeVersion
        DeploymentModel = [string]$profile.deploymentModel
        AdministratorRequired = [bool]$profile.administratorRequired
        CleanInstall = 'PASS'
        InPlaceUpgrade = 'PASS'
        Uninstall = 'PASS'
        RetainedUserData = 'PASS'
        StartupRegistration = 'NOT USED'
        ActualHerdrUsed = $false
        AppExecuted = $false
        SimulationRoot = $simulationRoot
        SimulationRootRemoved = (-not $KeepSimulationRoot)
        Static = 'Package manifests and fixture bytes were checked before lifecycle transitions.'
        CleanMachine = 'NOT OBSERVED'
        Runtime = 'NOT OBSERVED'
        Human = 'NOT OBSERVED'
        Release = 'NOT OBSERVED'
    }
    $reportPath = Join-Path $simulationRoot 'synthetic-lifecycle-report.json'
    Write-DeterministicTextFile -Path $reportPath -Text ($report | ConvertTo-Json -Depth 20)
    [pscustomobject]$report
} finally {
    if (-not $KeepSimulationRoot -and (Test-Path -LiteralPath $simulationRoot)) {
        Remove-PackagingTempDirectory -Path $simulationRoot
    }
}
