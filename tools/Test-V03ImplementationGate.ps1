[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',

    [switch]$SkipBuild,

    # Test seam for deterministic child-failure tests. Production callers use
    # the committed child gates in this tools directory.
    [string]$ChildGateRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

Import-Module (Join-Path $PSScriptRoot 'V03ImplementationGate.psm1') -Force

$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$artifactRoot = Join-Path $repositoryRoot 'artifacts'
$implementationArtifactRoot = Join-Path $artifactRoot 'implementation-gates\v0.3.0\issue-17'
$sourceCommit = (& git -C $repositoryRoot rev-parse --verify 'HEAD^{commit}').Trim()
if ($LASTEXITCODE -ne 0 -or $sourceCommit -notmatch '^[0-9a-f]{40}$') {
    throw 'Could not resolve the committed source for the v0.3 implementation gate.'
}

$initialStatus = @(& git -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0) {
    throw 'Could not inspect the source checkout for the v0.3 implementation gate.'
}

if ([string]::IsNullOrWhiteSpace($ChildGateRoot)) {
    $ChildGateRoot = $PSScriptRoot
}
$resolvedChildGateRoot = (Resolve-Path -LiteralPath $ChildGateRoot).Path
$normalizedToolsRoot = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd([char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar))
$normalizedFixtureRoot = [IO.Path]::GetFullPath((Join-Path $artifactRoot 'implementation-gate-test-fixtures')).TrimEnd([char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar))
$childRootIsAllowed = $resolvedChildGateRoot.Equals($normalizedToolsRoot, [StringComparison]::OrdinalIgnoreCase) -or
    $resolvedChildGateRoot.StartsWith($normalizedFixtureRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
if (-not $childRootIsAllowed) {
    throw 'The child gate root must be the committed tools directory or its bounded implementation-gate test fixture directory.'
}

if ($env:HERDR_ENV -eq '1' -or -not [string]::IsNullOrWhiteSpace($env:HERDR_SOCKET_PATH)) {
    throw 'The v0.3 implementation gate refuses an authorized Herdr environment.'
}

$childResults = @()
$result = 'FAIL'
$failureCode = ''
$stopAfterFailure = $false

try {
    if ($initialStatus.Count -ne 0) {
        throw [InvalidOperationException]::new('WorkingTreeDirty')
    }

    if (-not $SkipBuild) {
        & (Join-Path $PSScriptRoot 'Invoke-Build.ps1') `
            -Configuration $Configuration `
            -VerifyFormat | Out-Host
        if ($LASTEXITCODE -ne 0) {
            throw [InvalidOperationException]::new('BuildFailed')
        }
    }

    foreach ($definition in Get-V03ImplementationChildGateDefinitions) {
        $scriptPath = Join-Path $resolvedChildGateRoot $definition.ScriptName
        if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
            throw [InvalidOperationException]::new("ChildGateMissing:$($definition.Issue)")
        }

        $childArguments = @('-Configuration', $Configuration, '-SkipBuild')
        if ($definition.ImplementationOnly) {
            $childArguments += '-ImplementationOnly'
        }

        $childOutput = @()
        $childExitCode = 1
        try {
            $childOutput = @(& $scriptPath @childArguments 2>&1)
            $childExitCode = $LASTEXITCODE
        }
        catch {
            $childOutput = @()
            $childExitCode = 1
        }

        if ($childExitCode -ne 0) {
            throw [InvalidOperationException]::new("ChildGateFailed:$($definition.Issue)")
        }

        try {
            $reportPath = Resolve-V03ImplementationReportPath `
                -Output $childOutput `
                -ArtifactRoot $artifactRoot
            $reportText = Get-Content -LiteralPath $reportPath -Raw
            Assert-V03ImplementationChildReport `
                -Name $definition.Name `
                -ReportText $reportText `
                -SourceCommit $sourceCommit
        }
        catch {
            throw [InvalidOperationException]::new("ChildReportInvalid:$($definition.Issue)")
        }

        $childResults += [pscustomobject]@{
            Issue = $definition.Issue
            Name = $definition.Name
            Status = 'PASS'
            ReportSha256 = ((Get-FileHash -LiteralPath $reportPath -Algorithm SHA256).Hash).ToUpperInvariant()
        }
    }

    $result = 'PASS'
}
catch {
    $failureCode = $_.Exception.Message
    if ([string]::IsNullOrWhiteSpace($failureCode)) {
        $failureCode = 'ImplementationGateFailed'
    }
}
finally {
    $finalCommit = (& git -C $repositoryRoot rev-parse --verify 'HEAD^{commit}').Trim()
    $finalStatus = @(& git -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
    if ($finalCommit -ne $sourceCommit -or $finalStatus.Count -ne 0) {
        $result = 'FAIL'
        $failureCode = 'SourceChangedDuringGate'
    }

    New-Item -ItemType Directory -Path $implementationArtifactRoot -Force | Out-Null
    $runId = "$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ', [Globalization.CultureInfo]::InvariantCulture))-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
    $runDirectory = Join-Path $implementationArtifactRoot $runId
    New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
    $reportPath = Join-Path $runDirectory 'gate-report.txt'
    $report = New-V03ImplementationGateReport `
        -SourceCommit $sourceCommit `
        -ChildResults $childResults `
        -Result $result `
        -FailureCode $failureCode `
        -GeneratedUtc ([DateTime]::UtcNow)
    $report | Set-Content -LiteralPath $reportPath -Encoding utf8
}

$report | ForEach-Object { Write-Output $_ }
Write-Output "ImplementationGateReport: $reportPath"

if ($result -ne 'PASS') {
    Write-Error "The v0.3 implementation gate failed: $failureCode"
    exit 1
}
