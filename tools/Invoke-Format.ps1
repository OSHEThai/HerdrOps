[CmdletBinding()]
param(
    [switch]$Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$solutionPath = Join-Path $repositoryRoot 'HerdrOps.sln'
$restoreArguments = @('restore', $solutionPath, '--locked-mode')
& dotnet @restoreArguments
if ($LASTEXITCODE -ne 0) {
    throw "dotnet restore for formatting failed with exit code $LASTEXITCODE."
}

$arguments = @('format', $solutionPath, '--no-restore')
if (-not $Apply) {
    $arguments += '--verify-no-changes'
}

& dotnet @arguments
if ($LASTEXITCODE -ne 0) {
    throw "dotnet format failed with exit code $LASTEXITCODE."
}
