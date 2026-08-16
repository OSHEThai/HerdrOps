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

$sourceCommitPath = Join-Path $repositoryRoot 'src\HerdrOps.App\Compliance\ComplianceQueueState.cs'
$viewPath = Join-Path $repositoryRoot 'src\HerdrOps.App\Views\ComplianceQueueView.xaml'
$viewCodeBehindPath = Join-Path $repositoryRoot 'src\HerdrOps.App\Views\ComplianceQueueView.xaml.cs'
$shellXamlPath = Join-Path $repositoryRoot 'src\HerdrOps.App\Views\ShellView.xaml'
$shellCodeBehindPath = Join-Path $repositoryRoot 'src\HerdrOps.App\Views\ShellView.xaml.cs'
$dashboardStatePath = Join-Path $repositoryRoot 'src\HerdrOps.App\Live\LiveDashboardState.cs'
$dashboardRuntimePath = Join-Path $repositoryRoot 'src\HerdrOps.App\Live\LiveDashboardRuntime.cs'
$semanticTokensPath = Join-Path $repositoryRoot 'src\HerdrOps.App\Themes\Tokens.Semantic.xaml'
$languageCatalogPath = Join-Path $repositoryRoot 'src\HerdrOps.App\Localization\UiLanguageService.cs'
$contractPath = Join-Path $repositoryRoot 'docs\protocol\v0.5-compliance-queue-presentation-contract.md'
$referencePath = Join-Path $repositoryRoot 'docs\design\reference\08-compliance-queue.png'
$contractTestSourcePath = Join-Path $repositoryRoot 'tests\HerdrOps.ContractTests\ComplianceQueuePresentationContractTests.cs'
$stateTestSourcePath = Join-Path $repositoryRoot 'tests\HerdrOps.IntegrationTests\ComplianceQueueStateTests.cs'
$languageCatalogTestSourcePath = Join-Path $repositoryRoot 'tests\HerdrOps.IntegrationTests\UiLanguageCatalogTests.cs'
$dashboardStateTestSourcePath = Join-Path $repositoryRoot 'tests\HerdrOps.IntegrationTests\LiveDashboardStateTests.cs'
$liveWidgetStateTestSourcePath = Join-Path $repositoryRoot 'tests\HerdrOps.IntegrationTests\LiveWidgetStateTests.cs'
$runtimeTestSourcePath = Join-Path $repositoryRoot 'tests\HerdrOps.RuntimeTests\ComplianceQueueRenderingTests.cs'

$contractProject = Join-Path $repositoryRoot 'tests\HerdrOps.ContractTests\HerdrOps.ContractTests.csproj'
$integrationProject = Join-Path $repositoryRoot 'tests\HerdrOps.IntegrationTests\HerdrOps.IntegrationTests.csproj'
$runtimeProject = Join-Path $repositoryRoot 'tests\HerdrOps.RuntimeTests\HerdrOps.RuntimeTests.csproj'

# These are content anchors for the stabilized, Issue #26-owned working set.
# Shared shell, localization, lifecycle, and token files evolve additively as
# later pages are integrated, so they are tracked and marker-checked separately.
$expectedHashes = [ordered]@{
    ComplianceQueueState = [ordered]@{
        Path = $sourceCommitPath
        Sha256 = '54A5BE3C3839FAE6E69CC63770B1D34BAB7A2C3AEE56CAAB033F0D34A04FCBC0'
    }
    ComplianceQueueView = [ordered]@{
        Path = $viewPath
        Sha256 = '9F08B33E35CBEBA24C9673CA9B5410849BF6E12406416B08535DE8D6E2375307'
    }
    ComplianceQueueViewCodeBehind = [ordered]@{
        Path = $viewCodeBehindPath
        Sha256 = 'C106BD54CA8E85B75BB119898523C0D26D12BA1F51894177C2EEC218D8AE0AD4'
    }
    Contract = [ordered]@{
        Path = $contractPath
        Sha256 = 'D4573C51520F8764D1C7E89DFBA7CB406C3D83DB77F59BA8F1DE29B64334AF40'
    }
    ComplianceQueuePresentationContractTest = [ordered]@{
        Path = $contractTestSourcePath
        Sha256 = 'B2AC371E511B6D393E29EEC5613F7651A9880FF63238C094ADCFC37272A6AE57'
    }
    ComplianceQueueStateTest = [ordered]@{
        Path = $stateTestSourcePath
        Sha256 = 'F83A7BF8D668B80D65F15AC527117F9893F45AE7F6C43C4D47927FAA7363AFEB'
    }
    ComplianceQueueRuntimeTest = [ordered]@{
        Path = $runtimeTestSourcePath
        Sha256 = 'E681B329A876AE8D3D1010E23ABBF7C48392FEC197FF19304C10726501A4371D'
    }
    ApprovedReference = [ordered]@{
        Path = $referencePath
        Sha256 = '685B54499D36C564A67FD74F81798825470F462FE8D5379D6C1D47E1ABABB45C'
    }
}

# Later version pages legitimately extend these shared integration files. Their
# Issue #26 invariants are checked below while their observed hashes remain in
# the evidence report for auditability.
$sharedIntegrationFiles = [ordered]@{
    ShellView = $shellXamlPath
    ShellViewCodeBehind = $shellCodeBehindPath
    LiveDashboardState = $dashboardStatePath
    LiveDashboardRuntime = $dashboardRuntimePath
    SemanticTokens = $semanticTokensPath
    UiLanguageCatalog = $languageCatalogPath
    UiLanguageCatalogTest = $languageCatalogTestSourcePath
    LiveDashboardStateTest = $dashboardStateTestSourcePath
    LiveWidgetStateTest = $liveWidgetStateTestSourcePath
}

$requiredTrackedPaths = @(
    $expectedHashes.Values | ForEach-Object { $_.Path }
    $sharedIntegrationFiles.Values
)

function Get-CleanCheckoutStatus {
    $status = @(& git -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not inspect the source working tree for the v0.5 Compliance Queue gate.'
    }

    return $status
}

function Assert-CleanCommittedCheckout {
    $status = @(Get-CleanCheckoutStatus)
    if ($status.Count -ne 0) {
        throw "The v0.5 Compliance Queue gate requires a clean committed checkout. Pending paths: $($status -join ', ')"
    }

    $commit = (& git -C $repositoryRoot rev-parse --verify 'HEAD^{commit}').Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($commit)) {
        throw 'The v0.5 Compliance Queue gate requires a committed HEAD.'
    }

    return $commit
}

function Assert-RequiredFile {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Description
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required Issue #26 $Description is missing: $Path"
    }
}

function Get-RepositoryRelativePath {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $separatorChars = [char[]]@(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar)
    $normalizedRoot = [IO.Path]::GetFullPath($repositoryRoot).TrimEnd($separatorChars)
    $normalizedPath = [IO.Path]::GetFullPath($Path)
    $rootPrefix = $normalizedRoot + [IO.Path]::DirectorySeparatorChar
    if (-not $normalizedPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path is outside the repository root: $normalizedPath"
    }

    return $normalizedPath.Substring($rootPrefix.Length).Replace('\', '/')
}

function Assert-TrackedAtHead {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Description,

        [Parameter(Mandatory)]
        [string]$Commit
    )

    Assert-RequiredFile -Path $Path -Description $Description
    $relativePath = Get-RepositoryRelativePath -Path $Path
    $tracked = @(& git -C $repositoryRoot ls-files --error-unmatch -- $relativePath 2>$null)
    if ($LASTEXITCODE -ne 0 -or $tracked.Count -ne 1 -or $tracked[0] -ne $relativePath) {
        throw "Required Issue #26 $Description is not tracked in the index: $relativePath"
    }

    $headTracked = @(& git -C $repositoryRoot ls-tree -r --name-only $Commit -- $relativePath 2>$null)
    if ($LASTEXITCODE -ne 0 -or $headTracked.Count -ne 1 -or $headTracked[0] -ne $relativePath) {
        throw "Required Issue #26 $Description is not present in committed HEAD ${Commit}: $relativePath"
    }
}

function Assert-ExactSha256 {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Anchor
    )

    Assert-RequiredFile -Path $Anchor.Path -Description "$Name file"
    if ([string]::IsNullOrWhiteSpace([string]$Anchor.Sha256) -or
        [string]$Anchor.Sha256 -notmatch '^[0-9A-Fa-f]{64}$') {
        throw "Issue #26 exact SHA-256 anchor is not recorded for $Name. Wait for the file to stabilize, then record its committed SHA-256 in this gate: $($Anchor.Path)"
    }

    $actual = (Get-FileHash -LiteralPath $Anchor.Path -Algorithm SHA256).Hash.ToUpperInvariant()
    $expected = ([string]$Anchor.Sha256).ToUpperInvariant()
    if ($actual -ne $expected) {
        throw "Issue #26 $Name SHA-256 drifted: expected $expected observed $actual ($($Anchor.Path))"
    }

    return $actual
}

function Assert-ContainsText {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string[]]$RequiredText,

        [Parameter(Mandatory)]
        [string]$Description
    )

    Assert-RequiredFile -Path $Path -Description $Description
    $content = Get-Content -LiteralPath $Path -Raw
    foreach ($text in $RequiredText) {
        if ($content.IndexOf($text, [StringComparison]::Ordinal) -lt 0) {
            throw "Issue #26 $Description is missing required static marker: $text ($Path)"
        }
    }
}

function Get-PngDimensions {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 24 -or
        $bytes[0] -ne 137 -or
        $bytes[1] -ne 80 -or
        $bytes[2] -ne 78 -or
        $bytes[3] -ne 71 -or
        $bytes[4] -ne 13 -or
        $bytes[5] -ne 10 -or
        $bytes[6] -ne 26 -or
        $bytes[7] -ne 10) {
        throw "Required PNG evidence is not a valid PNG file: $Path"
    }

    $chunkType = [Text.Encoding]::ASCII.GetString($bytes, 12, 4)
    if ($chunkType -ne 'IHDR') {
        throw "Required PNG evidence does not start with an IHDR chunk: $Path"
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

function Get-TrxCounter {
    param(
        [Parameter(Mandatory)]
        [System.Xml.XmlElement]$Counters,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if (-not $Counters.HasAttribute($Name)) {
        throw "TRX result is missing required counter '$Name'."
    }

    $rawValue = $Counters.GetAttribute($Name)
    if ([string]::IsNullOrWhiteSpace($rawValue) -or $rawValue -notmatch '^(0|[1-9][0-9]*)$') {
        throw "TRX counter '$Name' is missing or malformed: '$rawValue'."
    }

    try {
        return [Int64]$rawValue
    }
    catch {
        throw "TRX counter '$Name' is outside the supported numeric range: '$rawValue'."
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
    & dotnet test $TestRun.Project `
        --configuration $Configuration `
        --no-restore `
        --no-build `
        --artifacts-path $artifactRoot `
        --results-directory $TestResultDirectory `
        --filter $TestRun.Filter `
        --logger "trx;LogFileName=$($TestRun.Log)"
    if ($LASTEXITCODE -ne 0) {
        throw "Issue #26 $($TestRun.Name) tests failed with exit code $LASTEXITCODE."
    }
}

$sourceCommit = Assert-CleanCommittedCheckout

foreach ($requiredTrackedPath in $requiredTrackedPaths) {
    $relativeRequiredPath = Get-RepositoryRelativePath -Path $requiredTrackedPath
    [void](Assert-TrackedAtHead `
        -Path $requiredTrackedPath `
        -Description $relativeRequiredPath `
        -Commit $sourceCommit)
}

foreach ($entry in $expectedHashes.GetEnumerator()) {
    [void](Assert-ExactSha256 -Name $entry.Key -Anchor $entry.Value)
}

Assert-ContainsText `
    -Path $shellXamlPath `
    -Description 'shared shell XAML' `
    -RequiredText @(
        '<views:ComplianceQueueView',
        'x:Name="ComplianceQueuePage"')
Assert-ContainsText `
    -Path $shellCodeBehindPath `
    -Description 'shared shell code-behind' `
    -RequiredText @(
        'ComplianceQueuePage.DataContext = LiveDashboard.ComplianceQueue;',
        '"compliance-queue"',
        'ComplianceQueuePage.Visibility')
Assert-ContainsText `
    -Path $dashboardStatePath `
    -Description 'shared dashboard state' `
    -RequiredText @(
        'ComplianceQueueState.CreateSyntheticPreview()',
        'ComplianceQueueState.CreateUnavailableLiveState(',
        'ComplianceQueue.RefreshLanguage();',
        'ComplianceQueue.Dispose();')
Assert-ContainsText `
    -Path $dashboardRuntimePath `
    -Description 'shared dashboard runtime' `
    -RequiredText @(
        'Owns the single App-wide Core subscription',
        'LiveDashboardSession')
Assert-ContainsText `
    -Path $semanticTokensPath `
    -Description 'shared semantic tokens' `
    -RequiredText @(
        'HerdrOps.Brush.Severity.Critical',
        'HerdrOps.Brush.Severity.High',
        'HerdrOps.Brush.Review.Suspected',
        'HerdrOps.Brush.Review.Confirmed',
        'HerdrOps.Brush.Review.PendingLeader',
        'HerdrOps.Brush.Review.PendingProjectManager',
        'HerdrOps.Brush.Review.MissingEvidence')
Assert-ContainsText `
    -Path $languageCatalogPath `
    -Description 'shared UI language catalog' `
    -RequiredText @(
        '["ComplianceQueuePageTitle"]',
        '["ComplianceQueuePageAutomation"]',
        '["ComplianceQueueSyntheticBoundary"]')
Assert-ContainsText `
    -Path $contractTestSourcePath `
    -Description 'contract test source' `
    -RequiredText @(
        'ViewDefinesApprovedHierarchyAndAccessibleReadOnlyActions',
        'PresentationStateHasNoCommandStorageOrTransitionAuthority',
        'WrittenContractKeepsSyntheticUiSeparateFromAuthorizationAndRuntime')
Assert-ContainsText `
    -Path $stateTestSourcePath `
    -Description 'state test source' `
    -RequiredText @(
        'LocalizedPaginationRangeTracksFilteredVisibleCount',
        'SyntheticPreviewCoversEveryIncidentStateAndKeepsDetailEvidenceAndActionsAligned',
        'SyntheticReviewActionsRejectDirectExecutionWithoutIpc',
        'SeverityAndReviewPresentationUseDedicatedSemanticBrushKeys',
        'EvidenceProjectionCarriesIssue25ProvenanceAndOneExplicitMissingItem',
        'SelectionRejectsRowsOutsideVisibleIncidentsAndFailsClosed',
        'EachStateFilterReturnsOnlyItsOwnStateAndPreservesAValidSelection',
         'SeverityActorTaskAndReviewerFiltersComposeDeterministically',
         'DefaultSortUsesSeverityThenNewestAndAlternativeSortsRemainStable',
        'SelectionSynchronizesDetailEvidenceAndActionsWhenFiltersChange',
        'FilterAndSortSettersUseCurrentCatalogAndRejectUnknownIds',
        'ComposedFiltersWithNoResultsClearIncidentDetailEvidenceAndActions',
        'EqualSeverityAndEqualObservedTimeUseIncidentIdAsStableTieBreaker',
        'LanguageRefreshKeepsTechnicalIdentityAndRendersOneCatalogAtATime',
        'ThaiComplianceQueueTaskCopyDoesNotRetainUnapprovedEnglishFragments',
        'BackgroundLanguageChangeWaitsForTheUiOwnedRefresh',
        'DisposedStateStopsWeakLanguageRefreshAndDisposeIsIdempotent',
        'PreviewActionsExposeRoleRequirementsButNeverEnableMutation',
        'UnavailableLiveStateDoesNotInventIncidentsOrActions')
Assert-ContainsText `
    -Path $languageCatalogTestSourcePath `
    -Description 'language catalog test source' `
    -RequiredText @(
        'ThaiIsTheDefaultAndBothCatalogsContainTheSameNonEmptyKeys',
        'ThaiCatalogUsesThaiCoreTerminologyWithoutEnglishLabel',
        'EveryV01XamlLanguageBindingExistsAndNoBilingualLiteralRemains')
Assert-ContainsText `
    -Path $dashboardStateTestSourcePath `
    -Description 'dashboard lifecycle test source' `
    -RequiredText @('DashboardDisposeDisposesComplianceQueueAndIsIdempotent')
Assert-ContainsText `
    -Path $liveWidgetStateTestSourcePath `
    -Description 'App runtime lifecycle test source' `
    -RequiredText @('AppRuntimeOwnsSubscriptionWithoutDashboardWindowLifetime')
Assert-ContainsText `
    -Path $runtimeTestSourcePath `
    -Description 'runtime rendering test source' `
    -RequiredText @(
         'ActualWpfComplianceQueueRendersAuditedReadOnlyEvidence',
         'RenderTargetBitmap',
        '1672',
        '941',
        '1366',
        '768',
        'compliance-queue-th-1672x941.png',
        'compliance-queue-en-1672x941.png',
        'compliance-queue-th-1366x768.png',
        'compliance-queue-th-missing-1672x941.png',
        'compliance-queue-en-missing-1672x941.png',
        'RenderMissingEvidencePng',
        'AssertMissingEvidenceVisible')

if (-not $SkipBuild) {
    & (Join-Path $PSScriptRoot 'Invoke-Build.ps1') -Configuration $Configuration -VerifyFormat
    if ($LASTEXITCODE -ne 0) {
        throw "v0.5 Compliance Queue build gate failed with exit code $LASTEXITCODE."
    }
}

if ((@(Get-CleanCheckoutStatus)).Count -ne 0) {
    throw 'The source checkout became dirty before the Issue #26 evidence run.'
}

$runId = "$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ', [Globalization.CultureInfo]::InvariantCulture))-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
$gateDirectory = Join-Path $artifactRoot "release-gates\v0.5.0\issue-26\$runId"
$testResultDirectory = Join-Path $gateDirectory 'test-results'
New-Item -ItemType Directory -Path $testResultDirectory -Force | Out-Null

$testRuns = @(
    [ordered]@{
        Name = 'Contract'
        Project = $contractProject
        Filter = 'FullyQualifiedName~ComplianceQueuePresentationContractTests'
        Log = 'compliance-queue-contract.trx'
    }
    [ordered]@{
        Name = 'Integration'
        Project = $integrationProject
        Filter = 'FullyQualifiedName~ComplianceQueueStateTests|FullyQualifiedName~UiLanguageCatalogTests|FullyQualifiedName=HerdrOps.IntegrationTests.LiveDashboardStateTests.DashboardDisposeDisposesComplianceQueueAndIsIdempotent|FullyQualifiedName=HerdrOps.IntegrationTests.LiveWidgetStateTests.AppRuntimeOwnsSubscriptionWithoutDashboardWindowLifetime'
        Log = 'compliance-queue-integration.trx'
    }
     [ordered]@{
         Name = 'Synthetic UI'
         Project = $runtimeProject
         Filter = 'FullyQualifiedName~ComplianceQueueRenderingTests'
        Log = 'compliance-queue-runtime.trx'
    }
)

$evidenceStartedUtc = [DateTime]::UtcNow
foreach ($testRun in $testRuns) {
    Invoke-FreshTestRun -TestRun $testRun -TestResultDirectory $testResultDirectory
}

$testResults = @($testRuns | ForEach-Object {
    $path = Join-Path $testResultDirectory $_.Log
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Fresh Issue #26 $($_.Name) TRX result is missing: $path"
    }

    [pscustomobject]@{
        Name = $_.Name
        Path = $path
        Log = $_.Log
    }
})
$allTrx = @(Get-ChildItem -LiteralPath $testResultDirectory -Filter '*.trx' -File)
if ($allTrx.Count -ne $testResults.Count) {
    throw "Expected exactly $($testResults.Count) fresh Issue #26 TRX files, found $($allTrx.Count)."
}

$requiredChecks = @(
    'ViewDefinesApprovedHierarchyAndAccessibleReadOnlyActions',
    'PresentationStateHasNoCommandStorageOrTransitionAuthority',
    'WrittenContractKeepsSyntheticUiSeparateFromAuthorizationAndRuntime',
    'LocalizedPaginationRangeTracksFilteredVisibleCount',
    'SyntheticPreviewCoversEveryIncidentStateAndKeepsDetailEvidenceAndActionsAligned',
    'SyntheticReviewActionsRejectDirectExecutionWithoutIpc',
    'SeverityAndReviewPresentationUseDedicatedSemanticBrushKeys',
    'EvidenceProjectionCarriesIssue25ProvenanceAndOneExplicitMissingItem',
    'SelectionRejectsRowsOutsideVisibleIncidentsAndFailsClosed',
    'EachStateFilterReturnsOnlyItsOwnStateAndPreservesAValidSelection',
     'SeverityActorTaskAndReviewerFiltersComposeDeterministically',
     'DefaultSortUsesSeverityThenNewestAndAlternativeSortsRemainStable',
     'SelectionSynchronizesDetailEvidenceAndActionsWhenFiltersChange',
     'FilterAndSortSettersUseCurrentCatalogAndRejectUnknownIds',
     'ComposedFiltersWithNoResultsClearIncidentDetailEvidenceAndActions',
     'EqualSeverityAndEqualObservedTimeUseIncidentIdAsStableTieBreaker',
     'LanguageRefreshKeepsTechnicalIdentityAndRendersOneCatalogAtATime',
     'ThaiComplianceQueueTaskCopyDoesNotRetainUnapprovedEnglishFragments',
     'BackgroundLanguageChangeWaitsForTheUiOwnedRefresh',
     'DisposedStateStopsWeakLanguageRefreshAndDisposeIsIdempotent',
     'PreviewActionsExposeRoleRequirementsButNeverEnableMutation',
     'UnavailableLiveStateDoesNotInventIncidentsOrActions',
     'ThaiIsTheDefaultAndBothCatalogsContainTheSameNonEmptyKeys',
     'ThaiCatalogUsesThaiCoreTerminologyWithoutEnglishLabel',
     'EveryV01XamlLanguageBindingExistsAndNoBilingualLiteralRemains',
     'DashboardDisposeDisposesComplianceQueueAndIsIdempotent',
     'AppRuntimeOwnsSubscriptionWithoutDashboardWindowLifetime',
     'ActualWpfComplianceQueueRendersAuditedReadOnlyEvidence')
$combinedTestLog = ($testResults | ForEach-Object {
    Get-Content -LiteralPath $_.Path -Raw
}) -join "`n"
foreach ($check in $requiredChecks) {
    if ($combinedTestLog -notmatch [Regex]::Escape($check)) {
        throw "Required Issue #26 check is absent from fresh test logs: $check"
    }
}

$counterNames = @(
    'total',
    'executed',
    'passed',
    'failed',
    'error',
    'timeout',
    'aborted',
    'inconclusive',
    'notExecuted',
    'completed',
    'notRunnable',
    'disconnected',
    'warning')
$aggregateCounters = [ordered]@{}
foreach ($counterName in $counterNames) {
    $aggregateCounters[$counterName] = 0
}
$testCounterEvidence = @()
foreach ($testResult in $testResults) {
    [xml]$trx = Get-Content -LiteralPath $testResult.Path -Raw
    $counters = $trx.TestRun.ResultSummary.Counters
    if ($null -eq $counters) {
        throw "TRX result has no ResultSummary.Counters element: $($testResult.Path)"
    }

    $values = [ordered]@{}
    foreach ($counterName in $counterNames) {
        $value = Get-TrxCounter -Counters $counters -Name $counterName
        $values[$counterName] = $value
        $aggregateCounters[$counterName] += $value
    }
    if ($values.total -le 0 -or
        $values.completed -ne 0 -or
        $values.failed -ne 0 -or
        $values.error -ne 0 -or
        $values.timeout -ne 0 -or
        $values.aborted -ne 0 -or
        $values.inconclusive -ne 0 -or
        $values.notExecuted -ne 0 -or
        $values.notRunnable -ne 0 -or
        $values.disconnected -ne 0 -or
        $values.warning -ne 0 -or
        $values.passed -ne $values.total -or
        $values.executed -ne $values.total) {
        throw "Issue #26 $($testResult.Name) TRX counters are not an exact all-pass result: $($values | Out-String)"
    }

    $testCounterEvidence += [pscustomobject]@{
        Name = $testResult.Name
        Path = $testResult.Path
        Counters = $values
    }
}
if ($aggregateCounters.total -le 0 -or
    $aggregateCounters.completed -ne 0 -or
    $aggregateCounters.failed -ne 0 -or
    $aggregateCounters.error -ne 0 -or
    $aggregateCounters.timeout -ne 0 -or
    $aggregateCounters.aborted -ne 0 -or
    $aggregateCounters.inconclusive -ne 0 -or
    $aggregateCounters.notExecuted -ne 0 -or
    $aggregateCounters.notRunnable -ne 0 -or
    $aggregateCounters.disconnected -ne 0 -or
    $aggregateCounters.warning -ne 0 -or
    $aggregateCounters.passed -ne $aggregateCounters.total -or
    $aggregateCounters.executed -ne $aggregateCounters.total) {
    throw "Issue #26 aggregate TRX counters are not an exact all-pass result: $($aggregateCounters | Out-String)"
}

$captureDirectory = Join-Path $artifactRoot 'design-evidence\v0.5.0\issue-26\compliance-queue'
$captureRequirements = @(
    [ordered]@{ Name = 'ComplianceQueueThai1672x941'; FileName = 'compliance-queue-th-1672x941.png'; Width = 1672; Height = 941 }
    [ordered]@{ Name = 'ComplianceQueueEnglish1672x941'; FileName = 'compliance-queue-en-1672x941.png'; Width = 1672; Height = 941 }
    [ordered]@{ Name = 'ComplianceQueueThai1366x768'; FileName = 'compliance-queue-th-1366x768.png'; Width = 1366; Height = 768 }
    [ordered]@{ Name = 'ComplianceQueueThaiMissing1672x941'; FileName = 'compliance-queue-th-missing-1672x941.png'; Width = 1672; Height = 941 }
    [ordered]@{ Name = 'ComplianceQueueEnglishMissing1672x941'; FileName = 'compliance-queue-en-missing-1672x941.png'; Width = 1672; Height = 941 }
)
$captureEvidence = foreach ($capture in $captureRequirements) {
    $capturePath = Join-Path $captureDirectory $capture.FileName
    Assert-RequiredFile -Path $capturePath -Description "$($capture.Name) actual WPF PNG evidence"
    $captureItem = Get-Item -LiteralPath $capturePath
    if ($captureItem.Length -le 4000) {
        throw "Actual WPF PNG evidence is unexpectedly small: $capturePath"
    }
    if ($captureItem.LastWriteTimeUtc -lt $evidenceStartedUtc.AddSeconds(-2)) {
        throw "Actual WPF PNG evidence was not freshly written by the Issue #26 runtime test: $capturePath"
    }

    $dimensions = Get-PngDimensions -Path $capturePath
    if ($dimensions.Width -ne $capture.Width -or $dimensions.Height -ne $capture.Height) {
        throw "Actual WPF PNG dimensions drifted for $capturePath`: expected $($capture.Width)x$($capture.Height), observed $($dimensions.Width)x$($dimensions.Height)"
    }

    [pscustomobject]@{
        Name = $capture.Name
        FileName = $capture.FileName
        Path = $capturePath
        Width = $dimensions.Width
        Height = $dimensions.Height
        Length = $captureItem.Length
        Sha256 = (Get-FileHash -LiteralPath $capturePath -Algorithm SHA256).Hash
    }
}
if (($captureEvidence | Where-Object { $_.Name -eq 'ComplianceQueueThai1672x941' }).Sha256 -eq
    ($captureEvidence | Where-Object { $_.Name -eq 'ComplianceQueueEnglish1672x941' }).Sha256) {
    throw 'Thai and English 1672x941 Compliance Queue PNG evidence rendered identical bytes.'
}

$finalCommit = (& git -C $repositoryRoot rev-parse --verify 'HEAD^{commit}').Trim()
$finalStatus = @(Get-CleanCheckoutStatus)
if ($LASTEXITCODE -ne 0 -or $finalCommit -ne $sourceCommit -or $finalStatus.Count -ne 0) {
    throw 'The source commit or clean-checkout state changed while the Issue #26 gate ran.'
}

$gateReportPath = Join-Path $gateDirectory 'gate-report.txt'
$hashReport = $expectedHashes.GetEnumerator() | ForEach-Object {
    $hashEntry = $_
    $hashValue = ([string]$hashEntry.Value.Sha256).ToUpperInvariant()
    "SHA256 $hashValue $($hashEntry.Key) $(Get-RepositoryRelativePath -Path $hashEntry.Value.Path)"
}
$sharedHashReport = $sharedIntegrationFiles.GetEnumerator() | ForEach-Object {
    $hashValue = (Get-FileHash -LiteralPath $_.Value -Algorithm SHA256).Hash.ToUpperInvariant()
    "SHA256 $hashValue $($_.Key) $(Get-RepositoryRelativePath -Path $_.Value)"
}
$counterReport = $testCounterEvidence | ForEach-Object {
    $values = $_.Counters
    "TRX $($_.Name) total=$($values.total) executed=$($values.executed) passed=$($values.passed) failed=$($values.failed) error=$($values.error) timeout=$($values.timeout) aborted=$($values.aborted) inconclusive=$($values.inconclusive) notExecuted=$($values.notExecuted) completed=$($values.completed) notRunnable=$($values.notRunnable) disconnected=$($values.disconnected) warning=$($values.warning)"
}
$captureReport = $captureEvidence | ForEach-Object {
    "PNG $($_.FileName) $($_.Width)x$($_.Height) bytes=$($_.Length) sha256=$($_.Sha256)"
}
$gateReport = @(
    'HerdrOps v0.5 Issue #26 Compliance Queue Implementation Gate',
    "GeneratedUtc: $([DateTime]::UtcNow.ToString('O'))",
    "SourceCommit: $sourceCommit",
    'Result: IMPLEMENTATION READY / PARTIAL',
    'ImplementationGate: PASS',
    'IssueAcceptance: PENDING INDEPENDENT REVIEW',
    'VersionReleaseGate: PENDING',
    'ContractEvidence: OBSERVED',
    'IntegrationEvidence: OBSERVED',
    'SyntheticUIEvidence: OBSERVED AGAINST SYNTHETIC STATE',
    'WpfRendering: OBSERVED AGAINST SYNTHETIC PREVIEW ONLY',
    'ReviewActions: VISIBLE BUT DISABLED / READ-ONLY',
    'ActualHerdrRuntime: NOT OBSERVED / NOT CLAIMED',
    'RoleAuthorization: NOT OBSERVED / NOT CLAIMED',
    'ReviewMutation: NOT IMPLEMENTED IN ISSUE #26 / NOT CLAIMED',
    'IndependentReview: NOT OBSERVED / NOT CLAIMED',
    'ReleaseEvidence: NOT OBSERVED / NOT CLAIMED',
    "TestsAggregate: total=$($aggregateCounters.total) executed=$($aggregateCounters.executed) passed=$($aggregateCounters.passed) failed=$($aggregateCounters.failed) error=$($aggregateCounters.error) timeout=$($aggregateCounters.timeout) aborted=$($aggregateCounters.aborted) inconclusive=$($aggregateCounters.inconclusive) notExecuted=$($aggregateCounters.notExecuted) completed=$($aggregateCounters.completed) notRunnable=$($aggregateCounters.notRunnable) disconnected=$($aggregateCounters.disconnected) warning=$($aggregateCounters.warning)",
    '',
    'ExactSourceSha256Anchors:',
    $hashReport,
    '',
    'ObservedSharedIntegrationSha256:',
    $sharedHashReport,
    '',
    'FreshTrxCounters:',
    $counterReport,
    '',
    'ActualWpfPngEvidence:',
    $captureReport,
    '',
    'RequiredIssue26Checks:'
) + ($requiredChecks | ForEach-Object { "PASS $_" }) + @(
    '',
    'EvidenceBoundary:',
    'Contract evidence covers the presentation contract and source markers. Integration evidence covers deterministic presentation-state and language-catalog checks. Synthetic UI evidence covers actual WPF rendering of the synthetic read-only Compliance Queue in Thai and English at the required sizes, including explicit Missing-evidence captures.',
    'It does not prove an actual Herdr instance, role authorization, review mutation, persisted audit transition, independent acceptance, privacy or retention acceptance, package installation, or v0.5 release readiness.',
    'The displayed Confirm, Send to Leader, Escalate to Project Manager, and Dismiss affordances remain disabled and are not authorization evidence.'
)
[IO.File]::WriteAllLines(
    $gateReportPath,
    $gateReport,
    [Text.UTF8Encoding]::new($false))

Write-Host "v0.5 Issue #26 Compliance Queue implementation gate passed: $($aggregateCounters.passed)/$($aggregateCounters.total) tests."
Write-Host "Gate report: $gateReportPath"
