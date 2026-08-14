[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',

    [switch]$SkipTests,
    [switch]$VerifyFormat,
    [switch]$UpdateLockFiles
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$solutionPath = Join-Path $repositoryRoot 'HerdrOps.sln'
$artifactRoot = Join-Path $repositoryRoot 'artifacts'

if (-not (Test-Path -LiteralPath $solutionPath)) {
    throw "Solution not found: $solutionPath"
}

$restoreArguments = @('restore', $solutionPath, '--artifacts-path', $artifactRoot)
if ($UpdateLockFiles) {
    $restoreArguments += '--force-evaluate'
} else {
    $restoreArguments += '--locked-mode'
}

& dotnet @restoreArguments
if ($LASTEXITCODE -ne 0) { throw 'Restore failed.' }

& dotnet build $solutionPath --configuration $Configuration --no-restore --artifacts-path $artifactRoot
if ($LASTEXITCODE -ne 0) { throw 'Build failed.' }

if ($VerifyFormat) {
    & (Join-Path $PSScriptRoot 'Invoke-Format.ps1')
}

if (-not $SkipTests) {
    $resultsDirectory = Join-Path $artifactRoot 'test-results'
    & dotnet test $solutionPath --configuration $Configuration --no-restore --no-build --artifacts-path $artifactRoot --results-directory $resultsDirectory --logger trx
    if ($LASTEXITCODE -ne 0) { throw 'Tests failed.' }
}

Write-Host "HerdrOps $Configuration build completed. Artifacts: $artifactRoot"
