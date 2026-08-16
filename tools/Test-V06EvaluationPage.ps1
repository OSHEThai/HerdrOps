[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',

    [switch]$SkipBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$artifactRoot = Join-Path $repositoryRoot 'artifacts'
$referencePath = Join-Path $repositoryRoot 'docs\design\reference\09-evaluation.png'
$expectedReferenceSha256 = '7721C24EE49887286854D07132BBFE12C52B028AAE50CE7EB8062F0877C2B23D'

$requiredSources = @(
    [ordered]@{ Name = 'EvaluationState'; Path = (Join-Path $repositoryRoot 'src\HerdrOps.App\Evaluation\EvaluationState.cs') }
    [ordered]@{ Name = 'EvaluationView'; Path = (Join-Path $repositoryRoot 'src\HerdrOps.App\Views\EvaluationView.xaml') }
    [ordered]@{ Name = 'EvaluationViewCodeBehind'; Path = (Join-Path $repositoryRoot 'src\HerdrOps.App\Views\EvaluationView.xaml.cs') }
    [ordered]@{ Name = 'EvaluationScoreDistributionChart'; Path = (Join-Path $repositoryRoot 'src\HerdrOps.App\Controls\EvaluationScoreDistributionChart.cs') }
    [ordered]@{ Name = 'EvaluationScoreTrendChart'; Path = (Join-Path $repositoryRoot 'src\HerdrOps.App\Controls\EvaluationScoreTrendChart.cs') }
    [ordered]@{ Name = 'ShellView'; Path = (Join-Path $repositoryRoot 'src\HerdrOps.App\Views\ShellView.xaml') }
    [ordered]@{ Name = 'ShellViewCodeBehind'; Path = (Join-Path $repositoryRoot 'src\HerdrOps.App\Views\ShellView.xaml.cs') }
    [ordered]@{ Name = 'UiLanguageService'; Path = (Join-Path $repositoryRoot 'src\HerdrOps.App\Localization\UiLanguageService.cs') }
)

$requiredTests = @(
    [ordered]@{ Name = 'EvaluationStateTests'; Path = (Join-Path $repositoryRoot 'tests\HerdrOps.IntegrationTests\EvaluationStateTests.cs') }
    [ordered]@{ Name = 'EvaluationPresentationContractTests'; Path = (Join-Path $repositoryRoot 'tests\HerdrOps.ContractTests\EvaluationPresentationContractTests.cs') }
    [ordered]@{ Name = 'EvaluationRenderingTests'; Path = (Join-Path $repositoryRoot 'tests\HerdrOps.RuntimeTests\EvaluationRenderingTests.cs') }
    [ordered]@{ Name = 'UiLanguageCatalogTests'; Path = (Join-Path $repositoryRoot 'tests\HerdrOps.IntegrationTests\UiLanguageCatalogTests.cs') }
)

$contractProject = Join-Path $repositoryRoot 'tests\HerdrOps.ContractTests\HerdrOps.ContractTests.csproj'
$integrationProject = Join-Path $repositoryRoot 'tests\HerdrOps.IntegrationTests\HerdrOps.IntegrationTests.csproj'
$runtimeProject = Join-Path $repositoryRoot 'tests\HerdrOps.RuntimeTests\HerdrOps.RuntimeTests.csproj'
$evidenceDirectory = Join-Path $artifactRoot 'design-evidence\v0.6.0\issue-31\evaluation'

function Assert-RequiredFile {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Description
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required Issue #31 $Description is missing: $Path"
    }
}

function Get-RepositoryRelativePath {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $separatorChars = [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $normalizedRoot = [IO.Path]::GetFullPath($repositoryRoot).TrimEnd($separatorChars)
    $normalizedPath = [IO.Path]::GetFullPath($Path)
    $rootPrefix = $normalizedRoot + [IO.Path]::DirectorySeparatorChar
    if (-not $normalizedPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path is outside the repository root: $normalizedPath"
    }

    return $normalizedPath.Substring($rootPrefix.Length).Replace('\', '/')
}

function Get-FileEvidence {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$Path
    )

    Assert-RequiredFile -Path $Path -Description "$Name file"
    $item = Get-Item -LiteralPath $Path
    if ($item.Length -le 0) {
        throw "Required Issue #31 $Name file is empty: $Path"
    }

    return [pscustomobject]@{
        Name = $Name
        Path = $Path
        RelativePath = Get-RepositoryRelativePath -Path $Path
        Length = $item.Length
        Sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
    }
}

function Get-PngDimensions {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 24 -or
        $bytes[0] -ne 137 -or $bytes[1] -ne 80 -or $bytes[2] -ne 78 -or $bytes[3] -ne 71 -or
        $bytes[4] -ne 13 -or $bytes[5] -ne 10 -or $bytes[6] -ne 26 -or $bytes[7] -ne 10) {
        throw "Evidence is not a valid PNG file: $Path"
    }

    if ([Text.Encoding]::ASCII.GetString($bytes, 12, 4) -ne 'IHDR') {
        throw "Evidence PNG does not contain an IHDR header: $Path"
    }

    $widthBytes = [byte[]]$bytes[16..19]
    $heightBytes = [byte[]]$bytes[20..23]
    [Array]::Reverse($widthBytes)
    [Array]::Reverse($heightBytes)
    return [pscustomobject]@{
        Width = [BitConverter]::ToUInt32($widthBytes, 0)
        Height = [BitConverter]::ToUInt32($heightBytes, 0)
    }
}

function Get-PngEvidence {
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Requirement,

        [Parameter(Mandatory)]
        [DateTime]$EvidenceStartedUtc
    )

    $path = Join-Path $evidenceDirectory $Requirement.FileName
    Assert-RequiredFile -Path $path -Description "$($Requirement.Name) screenshot"
    $item = Get-Item -LiteralPath $path
    if ($item.Length -le 10000) {
        throw "Issue #31 screenshot is unexpectedly small: $path"
    }

    if ($item.LastWriteTimeUtc -lt $EvidenceStartedUtc.AddSeconds(-2)) {
        throw "Issue #31 screenshot was not freshly written by this gate: $path"
    }

    $dimensions = Get-PngDimensions -Path $path
    if ($dimensions.Width -ne $Requirement.Width -or $dimensions.Height -ne $Requirement.Height) {
        throw "Issue #31 screenshot dimensions drifted for $path`: expected $($Requirement.Width)x$($Requirement.Height), observed $($dimensions.Width)x$($dimensions.Height)"
    }

    return [pscustomobject]@{
        Name = $Requirement.Name
        FileName = $Requirement.FileName
        RelativePath = Get-RepositoryRelativePath -Path $path
        Width = $dimensions.Width
        Height = $dimensions.Height
        Length = $item.Length
        Sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToUpperInvariant()
    }
}

function Invoke-FreshTestRun {
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$TestRun,

        [Parameter(Mandatory)]
        [string]$TestResultDirectory
    )

    Assert-RequiredFile -Path $TestRun.Project -Description "$($TestRun.Name) test project"
    $logPath = Join-Path $TestResultDirectory $TestRun.Log
    & dotnet test $TestRun.Project `
        --configuration $Configuration `
        --no-restore `
        --no-build `
        --artifacts-path $artifactRoot `
        --results-directory $TestResultDirectory `
        --filter $TestRun.Filter `
        --logger "trx;LogFileName=$($TestRun.Log)" | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "Issue #31 $($TestRun.Name) tests failed with exit code $LASTEXITCODE."
    }

    Assert-RequiredFile -Path $logPath -Description "$($TestRun.Name) TRX result"
    return [pscustomobject]@{
        Name = $TestRun.Name
        Path = $logPath
        RelativePath = Get-RepositoryRelativePath -Path $logPath
        Sha256 = (Get-FileHash -LiteralPath $logPath -Algorithm SHA256).Hash.ToUpperInvariant()
        Log = Get-Content -LiteralPath $logPath -Raw
    }
}

function Assert-TestResult {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$TestResult,

        [Parameter(Mandatory)]
        [string[]]$RequiredChecks
    )

    foreach ($check in $RequiredChecks) {
        if ($TestResult.Log -notmatch [Regex]::Escape($check)) {
            throw "Required Issue #31 check is absent from the fresh $($TestResult.Name) TRX result: $check"
        }
    }

    [xml]$trx = $TestResult.Log
    $counters = $trx.TestRun.ResultSummary.Counters
    if ($null -eq $counters) {
        throw "Fresh Issue #31 $($TestResult.Name) TRX result has no counters."
    }

    $total = [int]$counters.total
    $passed = [int]$counters.passed
    $failed = [int]$counters.failed
    if ($total -le 0 -or $passed -ne $total -or $failed -ne 0) {
        throw "Issue #31 $($TestResult.Name) counters are not all passing: total=$total passed=$passed failed=$failed"
    }

    $TestResult | Add-Member -NotePropertyName Total -NotePropertyValue $total
    $TestResult | Add-Member -NotePropertyName Passed -NotePropertyValue $passed
    $TestResult | Add-Member -NotePropertyName Failed -NotePropertyValue $failed
}

function Get-CheckoutSnapshot {
    $head = (& git -C $repositoryRoot rev-parse --verify 'HEAD^{commit}').Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($head)) {
        throw 'Could not resolve HEAD for the Issue #31 checkout-integrity gate.'
    }

    $statusLines = @(& git -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not inspect working-tree status for the Issue #31 checkout-integrity gate.'
    }

    return [pscustomobject]@{
        Head = $head
        StatusLines = $statusLines
        StatusText = $statusLines -join "`n"
    }
}

function Get-TrackedPathsAtCommit {
    param(
        [Parameter(Mandatory)]
        [string]$Commit
    )

    $paths = @(& git -C $repositoryRoot ls-tree -r --name-only $Commit)
    if ($LASTEXITCODE -ne 0) {
        throw "Could not enumerate tracked paths at source commit $Commit."
    }

    return $paths
}

function Assert-CheckoutUnchanged {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Baseline,

        [Parameter(Mandatory)]
        [string]$Phase
    )

    $current = Get-CheckoutSnapshot
    if ($current.Head -cne $Baseline.Head) {
        throw "Issue #31 checkout integrity failed $Phase`: HEAD changed from $($Baseline.Head) to $($current.Head)."
    }

    if ($current.StatusText -cne $Baseline.StatusText) {
        $observed = if ([string]::IsNullOrWhiteSpace($current.StatusText)) { '(clean)' } else { $current.StatusText }
        throw "Issue #31 checkout integrity failed $Phase`: working-tree status changed. Observed: $observed"
    }

    if ($current.StatusLines.Count -ne 0) {
        throw "Issue #31 checkout integrity failed $Phase`: checkout is not clean."
    }

    return $current
}

$initialCheckout = Get-CheckoutSnapshot
if ($initialCheckout.StatusLines.Count -ne 0) {
    throw "Issue #31 gate requires a clean checkout before build/tests. Observed: $($initialCheckout.StatusText)"
}

$sourceCommit = $initialCheckout.Head
$requiredGitPaths = @(
    $requiredSources | ForEach-Object { Get-RepositoryRelativePath -Path $_.Path }
    $requiredTests | ForEach-Object { Get-RepositoryRelativePath -Path $_.Path }
    Get-RepositoryRelativePath -Path $referencePath
    Get-RepositoryRelativePath -Path (Join-Path $PSScriptRoot 'Test-V06EvaluationPage.ps1')
) | Sort-Object -Unique
$trackedPaths = Get-TrackedPathsAtCommit -Commit $sourceCommit
foreach ($requiredGitPath in $requiredGitPaths) {
    if (-not ($trackedPaths -contains $requiredGitPath)) {
        throw "Issue #31 required file is not tracked at source commit $sourceCommit`: $requiredGitPath"
    }
}

Assert-RequiredFile -Path $referencePath -Description 'immutable Evaluation reference'
$referenceHash = (Get-FileHash -LiteralPath $referencePath -Algorithm SHA256).Hash.ToUpperInvariant()
if ($referenceHash -ne $expectedReferenceSha256) {
    throw "Immutable Evaluation reference SHA-256 drifted: expected $expectedReferenceSha256 observed $referenceHash"
}
$referenceDimensions = Get-PngDimensions -Path $referencePath
if ($referenceDimensions.Width -ne 1672 -or $referenceDimensions.Height -ne 941) {
    throw "Immutable Evaluation reference dimensions drifted: expected 1672x941, observed $($referenceDimensions.Width)x$($referenceDimensions.Height)"
}

$sourceEvidence = @($requiredSources | ForEach-Object { Get-FileEvidence -Name $_.Name -Path $_.Path })
$testEvidence = @($requiredTests | ForEach-Object { Get-FileEvidence -Name $_.Name -Path $_.Path })

if (-not $SkipBuild) {
    & (Join-Path $PSScriptRoot 'Invoke-Build.ps1') -Configuration $Configuration
    if ($LASTEXITCODE -ne 0) {
        throw "Issue #31 build failed with exit code $LASTEXITCODE."
    }
}

$runId = "$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ', [Globalization.CultureInfo]::InvariantCulture))-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
$gateDirectory = Join-Path $artifactRoot "release-gates\v0.6.0\issue-31\$runId"
$testResultDirectory = Join-Path $gateDirectory 'test-results'
New-Item -ItemType Directory -Path $testResultDirectory -Force | Out-Null
$evidenceStartedUtc = [DateTime]::UtcNow

$testRuns = @(
    [ordered]@{
        Name = 'Contract'
        Project = $contractProject
        Filter = 'FullyQualifiedName~EvaluationPresentationContractTests'
        Log = 'evaluation-contract.trx'
    }
    [ordered]@{
        Name = 'Integration'
        Project = $integrationProject
        Filter = 'FullyQualifiedName~EvaluationStateTests|FullyQualifiedName~UiLanguageCatalogTests'
        Log = 'evaluation-integration.trx'
    }
    [ordered]@{
        Name = 'Synthetic UI'
        Project = $runtimeProject
        Filter = 'FullyQualifiedName~EvaluationRenderingTests'
        Log = 'evaluation-rendering.trx'
    }
)

$testResults = @()
foreach ($testRun in $testRuns) {
    $testResults += Invoke-FreshTestRun -TestRun $testRun -TestResultDirectory $testResultDirectory
}

Assert-TestResult -TestResult $testResults[0] -RequiredChecks @(
    'ViewPreservesApprovedHierarchyAndAccessibleTextEquivalents',
    'StateUsesOneSnapshotAndExposesSixDimensionRowsWithMissingAndTieSemantics',
    'ApprovedEvaluationReferenceBytesRemainImmutable')
Assert-TestResult -TestResult $testResults[1] -RequiredChecks @(
    'SyntheticPreview_UsesOneSnapshotForEveryPresentationSurface',
    'MissingScorePreview_IsExplicitAndExcludedFromPassAndRanking',
    'Rankings_MakeEqualScoresDeterministicAndExplicit',
    'RefreshLanguage_RendersExactlyOneSelectedLanguage',
    'UnavailablePreview_ReportsUnavailableWithoutRankingData',
    'ThaiIsTheDefaultAndBothCatalogsContainTheSameNonEmptyKeys',
    'EveryV01XamlLanguageBindingExistsAndNoBilingualLiteralRemains')
Assert-TestResult -TestResult $testResults[2] -RequiredChecks @(
    'SyntheticWpfEvaluationRendersLocalizedReferenceHierarchyAndMissingScore')

$captureRequirements = @(
    [ordered]@{ Name = 'EvaluationThai1672x941'; FileName = 'evaluation-th-1672x941.png'; Width = 1672; Height = 941 }
    [ordered]@{ Name = 'EvaluationThai1366x768'; FileName = 'evaluation-th-1366x768.png'; Width = 1366; Height = 768 }
    [ordered]@{ Name = 'EvaluationThaiMissingScore1672x941'; FileName = 'evaluation-th-missing-score-1672x941.png'; Width = 1672; Height = 941 }
    [ordered]@{ Name = 'EvaluationEnglish1672x941'; FileName = 'evaluation-en-1672x941.png'; Width = 1672; Height = 941 }
    [ordered]@{ Name = 'EvaluationEnglish1366x768'; FileName = 'evaluation-en-1366x768.png'; Width = 1366; Height = 768 }
)
$captureEvidence = @($captureRequirements | ForEach-Object {
    Get-PngEvidence -Requirement $_ -EvidenceStartedUtc $evidenceStartedUtc
})

$finalCheckout = Assert-CheckoutUnchanged -Baseline $initialCheckout -Phase 'after evidence capture'

$sourceReport = $sourceEvidence | ForEach-Object {
    "SHA256 $($_.Sha256) $($_.Name) $($_.RelativePath) bytes=$($_.Length)"
}
$testSourceReport = $testEvidence | ForEach-Object {
    "SHA256 $($_.Sha256) $($_.Name) $($_.RelativePath) bytes=$($_.Length)"
}
$testReport = $testResults | ForEach-Object {
    "TRX $($_.Name) total=$($_.Total) passed=$($_.Passed) failed=$($_.Failed) sha256=$($_.Sha256) path=$($_.RelativePath)"
}
$captureReport = $captureEvidence | ForEach-Object {
    "PNG $($_.FileName) $($_.Width)x$($_.Height) bytes=$($_.Length) sha256=$($_.Sha256) path=$($_.RelativePath)"
}
$statusReport = if ($finalCheckout.StatusLines.Count -eq 0) { '(clean)' } else { $finalCheckout.StatusText }

$gateReportPath = Join-Path $gateDirectory 'gate-report.txt'
$gateReport = @(
    'HerdrOps v0.6 Issue #31 Evaluation Page Implementation Gate',
    "GeneratedUtc: $([DateTime]::UtcNow.ToString('O'))",
    "SourceCommit: $sourceCommit",
    "WorkingTreeStatus: $statusReport",
    'CheckoutIntegrity: PASS (HEAD and clean status unchanged after evidence)',
    'RequiredFilesTrackedAtSourceCommit: PASS',
    'Result: PASS',
    'ImplementationGate: PASS',
    'IssueAcceptance: PENDING UI/INDEPENDENT REVIEW',
    'VersionReleaseGate: PENDING',
    'StaticEvidence: OBSERVED (source, immutable reference, exact hashes)',
    'ContractEvidence: OBSERVED (presentation contract tests)',
    'SyntheticEvidence: OBSERVED (deterministic state, language, and WPF rendering)',
    'RuntimeEvidence: NOT OBSERVED',
    'ActualHerdrRuntime: NOT OBSERVED / NOT CLAIMED',
    'IndependentReview: NOT OBSERVED / NOT CLAIMED',
    'ReleaseEvidence: NOT OBSERVED / NOT CLAIMED',
    "Reference09EvaluationSha256: $referenceHash",
    "Reference09EvaluationDimensions: $($referenceDimensions.Width)x$($referenceDimensions.Height)",
    '',
    'ExactSourceSha256Anchors:',
    $sourceReport,
    '',
    'ExactTestSourceSha256Anchors:',
    $testSourceReport,
    '',
    'FreshTestResults:',
    $testReport,
    '',
    'FreshDesignEvidence:',
    $captureReport,
    '',
    'EvidenceBoundary:',
    'Static evidence covers source existence, immutable-reference identity, PNG structure and exact hashes.',
    'Contract evidence covers the Issue #31 presentation contract and source markers.',
    'Synthetic evidence covers deterministic Evaluation state, language isolation, missing-score behavior, and WPF rendering from synthetic state.',
    'Actual Herdr Runtime is NOT OBSERVED and is NOT CLAIMED. This gate does not prove installed Herdr compatibility, live ingestion, independent acceptance, or v0.6 release readiness.'
)
[IO.File]::WriteAllLines($gateReportPath, $gateReport, [Text.UTF8Encoding]::new($false))
$gateReport | Write-Output
Write-Output "GateReport: $gateReportPath"
