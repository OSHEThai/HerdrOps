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
    if ([string]::IsNullOrWhiteSpace($env:HERDOPS_V02_LIVE_WIDGET_RUN_TOKEN)) {
        $env:HERDOPS_V02_LIVE_WIDGET_RUN_TOKEN = "$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ', [Globalization.CultureInfo]::InvariantCulture))-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
    }
    $stagingDirectory = Join-Path ([IO.Path]::GetTempPath()) ('herdrops-ci-test-staging-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stagingDirectory -Force | Out-Null
    try {
        & dotnet test $solutionPath -m:1 --configuration $Configuration --no-restore --no-build --artifacts-path $artifactRoot --results-directory $stagingDirectory --logger trx
        if ($LASTEXITCODE -ne 0) { throw 'Tests failed.' }
        . (Join-Path $PSScriptRoot 'lib\CanonicalTestManifest.ps1')
        [void](New-CanonicalTestResultsManifest -TestResultsDirectory $stagingDirectory -Configuration $Configuration -RepositoryRoot $repositoryRoot)
        [void](Assert-CanonicalTestResultsManifest -TestResultsDirectory $stagingDirectory -RepositoryRoot $repositoryRoot)

        # Atomic publish to destination results directory
        $resultsDirectory = Join-Path $artifactRoot 'test-results'
        if (-not (Test-Path -LiteralPath $resultsDirectory -PathType Container)) {
            New-Item -ItemType Directory -Path $resultsDirectory -Force | Out-Null
        } else {
            Get-ChildItem -LiteralPath $resultsDirectory -File | Remove-Item -Force
        }
        foreach ($stagedFile in (Get-ChildItem -LiteralPath $stagingDirectory -File)) {
            $destFile = Join-Path $resultsDirectory $stagedFile.Name
            Copy-Item -LiteralPath $stagedFile.FullName -Destination $destFile -Force
        }
    }
    finally {
        if (Test-Path -LiteralPath $stagingDirectory) {
            Remove-Item -LiteralPath $stagingDirectory -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Write-Host "HerdrOps $Configuration build completed. Artifacts: $artifactRoot"
