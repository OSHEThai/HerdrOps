[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$artifactRoot = Join-Path $repositoryRoot 'artifacts'
$sourceCommit = (& git -C $repositoryRoot rev-parse --verify 'HEAD^{commit}').Trim()
if ($LASTEXITCODE -ne 0 -or $sourceCommit -notmatch '^[0-9a-f]{40}$') {
    throw 'Could not resolve the committed source for the v0.6 technical gate.'
}

$initialStatus = @(& git -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0) {
    throw 'Could not inspect the source checkout for the v0.6 technical gate.'
}
if ($initialStatus.Count -ne 0) {
    throw "The v0.6 technical gate requires a clean committed checkout. Pending paths: $($initialStatus -join '; ')"
}

. (Join-Path $PSScriptRoot 'lib\V06GateProvenance.ps1')

function Assert-ReportPath {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $separatorChars = [char[]]@(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar)
    $normalizedArtifactRoot = [IO.Path]::GetFullPath($artifactRoot).TrimEnd($separatorChars)
    $normalizedPath = [IO.Path]::GetFullPath($Path)
    $artifactPrefix = $normalizedArtifactRoot + [IO.Path]::DirectorySeparatorChar
    if (-not $normalizedPath.StartsWith($artifactPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "A child gate reported a path outside the artifact root: $normalizedPath"
    }
    if (-not (Test-Path -LiteralPath $normalizedPath -PathType Leaf)) {
        throw "A child gate report is missing: $normalizedPath"
    }

    return $normalizedPath
}

function Invoke-ChildGate {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$ScriptName,

        [Parameter(Mandatory)]
        [string[]]$RequiredLines
    )

    $scriptPath = Join-Path $PSScriptRoot $ScriptName
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        throw "Required v0.6 child gate is missing: $scriptPath"
    }

    $output = @(& $scriptPath -Configuration $Configuration -SkipBuild 2>&1)
    $output | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) {
        throw "The v0.6 $Name child gate failed with exit code $LASTEXITCODE."
    }

    $reportLines = @($output | ForEach-Object { [string]$_ } | Where-Object {
            $_ -match '^GateReport:\s*(?<path>.+?)\s*$'
        })
    if ($reportLines.Count -ne 1) {
        throw "Expected exactly one report path from the v0.6 $Name child gate; found $($reportLines.Count)."
    }
    $null = $reportLines[0] -match '^GateReport:\s*(?<path>.+?)\s*$'
    $reportPath = Assert-ReportPath -Path $Matches.path
    $reportText = Get-Content -LiteralPath $reportPath -Raw

    foreach ($requiredLine in $RequiredLines) {
        if ($reportText -notmatch "(?m)^$([Regex]::Escape($requiredLine))\r?$") {
            throw "The v0.6 $Name report is missing the required exact line: $requiredLine"
        }
    }

    [pscustomobject]@{
        Name = $Name
        ReportPath = $reportPath
        ReportRelativePath = Get-RepositoryRelativePath -RepositoryRoot $repositoryRoot -Path $reportPath
        Sha256 = ((Get-FileHash -LiteralPath $reportPath -Algorithm SHA256).Hash).ToUpperInvariant()
    }
}

& (Join-Path $PSScriptRoot 'Invoke-Build.ps1') `
    -Configuration $Configuration `
    -VerifyFormat
if ($LASTEXITCODE -ne 0) {
    throw 'The full v0.6 technical-gate build and test suite failed.'
}

$childGates = @(
    Invoke-ChildGate `
        -Name 'ExplainableScoring' `
        -ScriptName 'Test-V06ScoringEngine.ps1' `
        -RequiredLines @(
            "SourceCommit: $sourceCommit",
            'Result: PASS',
            'IssueAcceptance: PASS',
            'ActualHerdrRuntime: NOT REQUIRED / NOT OBSERVED / NOT CLAIMED')
    Invoke-ChildGate `
        -Name 'EvaluationPage' `
        -ScriptName 'Test-V06EvaluationPage.ps1' `
        -RequiredLines @(
            "SourceCommit: $sourceCommit",
            'Result: PASS',
            'ImplementationGate: PASS',
            'StaticEvidence: OBSERVED (source, immutable reference, exact hashes)',
            'ContractEvidence: OBSERVED (presentation contract tests)',
            'SyntheticEvidence: OBSERVED (deterministic state, language, and WPF rendering)',
            'ActualHerdrRuntime: NOT OBSERVED / NOT CLAIMED')
    Invoke-ChildGate `
        -Name 'DailySummary' `
        -ScriptName 'Test-V06DailySummaryPage.ps1' `
        -RequiredLines @(
            "SourceCommit: $sourceCommit",
            'Result: PASS',
            'StaticEvidence: PASS',
            'SyntheticEvidence: PASS',
            'ContractEvidence: PASS',
            'Actual Herdr Runtime: NOT OBSERVED')
    Invoke-ChildGate `
        -Name 'LocalExport' `
        -ScriptName 'Test-V06LocalExport.ps1' `
        -RequiredLines @(
            "SourceCommit: $sourceCommit",
            'Result: NON-ACCEPTANCE CHECKS PASS',
            'AcceptedUiQuerySnapshotMatch: PASS',
            'SensitiveDataRedactionPolicy: PASS',
            'SkipBuild: True',
            'Static: PASS',
            'Synthetic: PASS',
            'Contract: PASS',
            'ActualHerdrRuntime: NOT OBSERVED / NOT CLAIMED')
)

$finalCommit = (& git -C $repositoryRoot rev-parse --verify 'HEAD^{commit}').Trim()
$finalStatus = @(& git -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or
    $finalCommit -cne $sourceCommit -or
    $finalStatus.Count -ne 0) {
    throw 'The source commit or clean-checkout state changed during the v0.6 technical gate.'
}

$runId = "$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ', [Globalization.CultureInfo]::InvariantCulture))-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
$gateDirectory = Join-Path $artifactRoot "release-gates\v0.6.0\technical\$runId"
New-Item -ItemType Directory -Path $gateDirectory -Force | Out-Null
$gateReportPath = Join-Path $gateDirectory 'gate-report.txt'
$childReportLines = $childGates | ForEach-Object {
    "PASS $($_.Name) sha256=$($_.Sha256) path=$($_.ReportRelativePath)"
}
$report = @(
    'HerdrOps v0.6.0 Version-Local Technical Gate',
    "GeneratedUtc: $([DateTime]::UtcNow.ToString('O'))",
    "SourceCommit: $sourceCommit",
    'Result: TECHNICAL GATE PASS',
    'VersionLocalTechnicalGates: 4/4 PASS',
    'FullBuildExecuted: True',
    '',
    'StaticEvidence: PASS',
    'SyntheticEvidence: PASS',
    'ContractEvidence: PASS',
    'ActualHerdrRuntime: NOT OBSERVED / NOT CLAIMED',
    'IndependentReview: NOT CONSOLIDATED BY THIS TOOL',
    'PredecessorRuntimeGates: NOT EVALUATED',
    'GitHubReleaseTracker: PENDING',
    'VersionReleaseReady: false',
    'ReleasePublication: NOT PERFORMED',
    '',
    'ChildGateReports:'
) + $childReportLines + @(
    '',
    'EvidenceBoundary:',
    'This gate proves one clean committed source passed a full build/test/format run and all four v0.6 version-local Static, Synthetic, and Contract child gates.',
    'The Local Export child uses SkipBuild only after this parent completed the full build at the same unchanged commit; its report remains non-acceptance evidence when used independently.',
    'This report does not prove actual Herdr Runtime, installed-product behavior, predecessor-version runtime gates, independent review, milestone closure, package installation, or release publication.'
)
[IO.File]::WriteAllLines($gateReportPath, $report, [Text.UTF8Encoding]::new($false))
$report | Write-Output
Write-Output "GateReport: $gateReportPath"
