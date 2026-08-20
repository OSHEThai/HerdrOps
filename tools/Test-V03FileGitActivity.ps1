[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',

    [switch]$SkipBuild,

    [switch]$ImplementationOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$artifactRoot = Join-Path $repositoryRoot 'artifacts'
$referencePath = Join-Path $repositoryRoot 'docs\design\reference\07-file-activity.png'
$expectedReferenceSha256 = '2BFB03357D9FFE4D4C11582D311D45CF2CFCCBD69A63D15130FD1EEBA0537F24'
$contractPath = Join-Path $repositoryRoot 'docs\protocol\v0.3-scoped-file-git-activity-contract.md'
$designRecordPath = Join-Path $repositoryRoot 'docs\design\implementation\v0.3-issue-15-file-activity.md'
$reviewRecordPath = Join-Path $repositoryRoot 'docs\reviews\v0.3-issue-15-independent-review.md'
$runtimeTracePath = Join-Path $artifactRoot 'runtime-evidence\v0.3.0\issue-15\actual-file-git-trace-release.json'

$workingTreeStatus = @(& git -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0) {
    throw 'Could not inspect the source working tree for the v0.3 File/Git gate.'
}
if ($workingTreeStatus.Count -ne 0) {
    throw "The v0.3 File/Git gate requires a clean committed checkout. Pending paths: $($workingTreeStatus -join ', ')"
}

if (-not $SkipBuild) {
    & (Join-Path $PSScriptRoot 'Invoke-Build.ps1') -Configuration $Configuration -VerifyFormat
    if ($LASTEXITCODE -ne 0) {
        throw "v0.3 File/Git build gate failed with exit code $LASTEXITCODE."
    }
}

$runId = "$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ', [Globalization.CultureInfo]::InvariantCulture))-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
$gateParentDirectory = if ($ImplementationOnly) {
    Join-Path $artifactRoot 'implementation-gates\v0.3.0\issue-15'
}
else {
    Join-Path $artifactRoot 'release-gates\v0.3.0\issue-15'
}
$gateDirectory = Join-Path $gateParentDirectory $runId
$testResultDirectory = Join-Path $gateDirectory 'test-results'
New-Item -ItemType Directory -Path $testResultDirectory -Force | Out-Null

$testRuns = @(
    [pscustomobject]@{
        Project = Join-Path $repositoryRoot 'tests\HerdrOps.UnitTests\HerdrOps.UnitTests.csproj'
        Filter = 'FullyQualifiedName~FileActivityContractTests|FullyQualifiedName~TerminalPreviewPolicyTests'
        Log = 'file-activity-domain.trx'
    },
    [pscustomobject]@{
        Project = Join-Path $repositoryRoot 'tests\HerdrOps.IntegrationTests\HerdrOps.IntegrationTests.csproj'
        Filter = 'FullyQualifiedName~ScopedFileGitActivityTests|FullyQualifiedName~FileActivityStateTests|FullyQualifiedName~UiLanguageCatalogTests'
        Log = 'file-git-integration.trx'
    },
    [pscustomobject]@{
        Project = Join-Path $repositoryRoot 'tests\HerdrOps.RuntimeTests\HerdrOps.RuntimeTests.csproj'
        Filter = 'FullyQualifiedName~FileActivityRenderingTests'
        Log = 'file-activity-rendering.trx'
    }
)
foreach ($testRun in $testRuns) {
    & dotnet test $testRun.Project `
        --configuration $Configuration `
        --no-restore `
        --no-build `
        --artifacts-path $artifactRoot `
        --results-directory $testResultDirectory `
        --filter $testRun.Filter `
        --logger "trx;LogFileName=$($testRun.Log)"
    if ($LASTEXITCODE -ne 0) {
        throw "v0.3 File/Git evidence tests failed: $($testRun.Project)"
    }
}

$testResults = @(Get-ChildItem -LiteralPath $testResultDirectory -Filter '*.trx' -File)
if ($testResults.Count -ne 3) {
    throw "Expected exactly 3 fresh File/Git TRX files, found $($testResults.Count)."
}

$combinedTestLog = ($testResults | ForEach-Object {
    Get-Content -LiteralPath $_.FullName -Raw
}) -join "`n"
$requiredChecks = @(
    'AuthorizedObservationNormalizesSeparatorsAndKeepsProvenance',
    'BlockedObservationCannotRetainRejectedPath',
    'AuthorizedObservationRejectsParentTraversal',
    'AuthorizationOperationAndCorrelationClaimsMustAgree',
    'CorrelatorAssignsUniqueRecentWorkingDirectoryContext',
    'CorrelatorFailsClosedForAmbiguousOrExpiredContexts',
    'RedactorRemovesAssignmentsAuthorizationUriCredentialsAndKnownTokens',
    'RedactorRemovesFineGrainedGitHubPatAndColonlessUriCredentials',
    'ScopeIsSeparatorAwareAndBlocksAbsoluteEscapeWithoutRetainingIt',
    'FileSystemWatcherProducesActualScopedEventWithExplicitSourceAndConfidence',
    'FileSystemWatcherExcludesBuildMetadataBeforeQueueing',
    'FileSystemWatcherDebounceIndexRemainsHardBoundedDuringUniqueBurst',
    'GitReaderUsesReadOnlyBoundedCommandAndBlocksMaliciousStatusPath',
    'ActualGitStatusAndDiffAreReadOnlyBoundedAndSecretRedacted',
    'GitReaderRejectsRepositoryConfigIncludeBeforeProcessExecution',
    'GitReaderRejectsGitDirectoryOutsideAuthorizedRootBeforeProcessExecution',
    'GitReaderRejectsExternalCommonDirectoryBeforeProcessExecution',
    'PorcelainV2ParserPreservesSpacesAndRenamePairing',
    'TraceCommandCapturesActualWatcherAndGitWithoutMutatingRepository',
    'ExistingReparsePointCannotEscapeAuthorizedRoot',
    'SyntheticFixtureKeepsSelectionFiltersAndEvidenceBoundarySynchronized',
    'LanguageRefreshProducesSingleLanguageRowsAndDetails',
    'ThaiIsTheDefaultAndBothCatalogsContainTheSameNonEmptyKeys',
    'EveryV01XamlLanguageBindingExistsAndNoBilingualLiteralRemains',
    'SyntheticOverviewAndWidgetCopyRebuildsAsOneSelectedLanguage',
    'LiveDashboardCopyRebuildsFromThaiToEnglishWithoutRetainingThaiText',
    'ActualWpfFileActivityRendersLocalizedSynchronizedBoundedEvidence'
)
foreach ($check in $requiredChecks) {
    if ($combinedTestLog -notmatch [Regex]::Escape($check)) {
        throw "Required v0.3 File/Git check is absent from fresh test logs: $check"
    }
}

$totalTests = 0
$passedTests = 0
$failedTests = 0
foreach ($trxFile in $testResults) {
    [xml]$trx = Get-Content -LiteralPath $trxFile.FullName -Raw
    $counters = $trx.TestRun.ResultSummary.Counters
    $totalTests += [int]$counters.total
    $passedTests += [int]$counters.passed
    $failedTests += [int]$counters.failed
}
if ($totalTests -lt $requiredChecks.Count -or $failedTests -ne 0 -or $totalTests -ne $passedTests) {
    throw "File/Git test counters are not all passing: total=$totalTests passed=$passedTests failed=$failedTests"
}

if (-not (Test-Path -LiteralPath $referencePath -PathType Leaf)) {
    throw "Approved File Activity reference is missing: $referencePath"
}
$referenceSha256 = (Get-FileHash -LiteralPath $referencePath -Algorithm SHA256).Hash
if ($referenceSha256 -ne $expectedReferenceSha256) {
    throw "File Activity reference SHA-256 drifted: expected $expectedReferenceSha256 observed $referenceSha256"
}

$captureDirectory = Join-Path $artifactRoot 'design-evidence\v0.3.0\issue-15\contract-backed-wpf'
$requiredCaptures = @(
    'file-activity-th-1672x941.png',
    'file-activity-th-blocked-selected-1672x941.png',
    'file-activity-th-1366x768.png',
    'file-activity-en-1672x941.png'
)
$captureEvidence = foreach ($captureName in $requiredCaptures) {
    $capturePath = Join-Path $captureDirectory $captureName
    if (-not (Test-Path -LiteralPath $capturePath -PathType Leaf)) {
        throw "Required actual WPF File Activity capture is missing: $capturePath"
    }
    if ((Get-Item -LiteralPath $capturePath).Length -le 10000) {
        throw "Actual WPF File Activity capture is unexpectedly small: $capturePath"
    }

    [pscustomobject]@{
        Name = $captureName
        Sha256 = (Get-FileHash -LiteralPath $capturePath -Algorithm SHA256).Hash
    }
}
if ($captureEvidence[0].Sha256 -eq $captureEvidence[1].Sha256) {
    throw 'Changing the selected file event did not change the rendered WPF evidence.'
}

if (-not $ImplementationOnly) {
    if (-not (Test-Path -LiteralPath $runtimeTracePath -PathType Leaf)) {
        throw "Actual File/Git trace is missing: $runtimeTracePath"
    }
    $runtimeTrace = Get-Content -LiteralPath $runtimeTracePath -Raw | ConvertFrom-Json
    if ($runtimeTrace.contractVersion -ne 1 -or
        $runtimeTrace.runtimeObserved -ne $true -or
        $runtimeTrace.fileSystemWatcherObserved -ne $true -or
        $runtimeTrace.gitStatusObserved -ne $true -or
        $runtimeTrace.herdrAgentCorrelationObserved -ne $false -or
        $runtimeTrace.repositoryMutationInvoked -ne $false -or
        $runtimeTrace.retainedEventLimit -ne 4096) {
        throw 'Actual File/Git trace flags do not match the issue #15 evidence contract.'
    }
    $fileEvents = @($runtimeTrace.fileSystemEvents)
    $gitEvents = @($runtimeTrace.initialGitStatus) + @($runtimeTrace.finalGitStatus)
    if ($fileEvents.Count -lt 1 -or $gitEvents.Count -lt 1) {
        throw 'Actual File/Git trace must contain both watcher and Git observations.'
    }
    if (@($fileEvents | Where-Object {
                $_.sourceKind -ne 'FileSystem' -or
                $_.confidence -ne 'Observed' -or
                $_.isAuthorized -ne $true -or
                $_.scopeDecision -ne 'authorized'
            }).Count -ne 0) {
        throw 'Actual watcher trace contains an observation without scoped FileSystem provenance.'
    }
    if (@($gitEvents | Where-Object {
                $_.sourceKind -ne 'Git' -or
                $_.confidence -ne 'Observed' -or
                $_.isAuthorized -ne $true -or
                $_.scopeDecision -ne 'authorized'
            }).Count -ne 0) {
        throw 'Actual Git trace contains an observation without read-only Git provenance.'
    }
    $allTracePaths = @($fileEvents + $gitEvents | ForEach-Object { [string]$_.relativePath })
    if (@($allTracePaths | Where-Object {
                [IO.Path]::IsPathRooted($_) -or $_ -match '(^|[\\/])\.\.([\\/]|$)'
            }).Count -ne 0) {
        throw 'Actual File/Git trace retained an absolute or parent-traversing path.'
    }

    $coreAssemblyPath = Join-Path $repositoryRoot "src\HerdrOps.Core\bin\$Configuration\net10.0-windows\HerdrOps.Core.dll"
    if (-not (Test-Path -LiteralPath $coreAssemblyPath -PathType Leaf)) {
        throw "Core assembly used for the local trace is missing: $coreAssemblyPath"
    }
    $coreAssemblySha256 = (Get-FileHash -LiteralPath $coreAssemblyPath -Algorithm SHA256).Hash
    if ($runtimeTrace.productAssemblySha256 -ne $coreAssemblySha256) {
        throw "Local trace assembly hash mismatch: trace=$($runtimeTrace.productAssemblySha256) current=$coreAssemblySha256"
    }
}

$requiredFiles = @($contractPath, $designRecordPath, $reviewRecordPath)
foreach ($requiredFile in $requiredFiles) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
        throw "Required Issue #15 record is missing: $requiredFile"
    }
}

$scopeSource = Get-Content -LiteralPath (Join-Path $repositoryRoot 'src\HerdrOps.Infrastructure\Activity\AuthorizedRepositoryScope.cs') -Raw
$watcherSource = Get-Content -LiteralPath (Join-Path $repositoryRoot 'src\HerdrOps.Infrastructure\Activity\ScopedFileSystemActivityCollector.cs') -Raw
$gitSource = Get-Content -LiteralPath (Join-Path $repositoryRoot 'src\HerdrOps.Infrastructure\Activity\GitRepositoryActivityReader.cs') -Raw
$correlationSource = Get-Content -LiteralPath (Join-Path $repositoryRoot 'src\HerdrOps.Domain\Activity\FileActivityContracts.cs') -Raw
if ($scopeSource -notmatch 'ResolveLinkTarget\(returnFinalTarget: true\)' -or
    $scopeSource -notmatch 'reparse-target-outside-root') {
    throw 'Canonical scope no longer resolves and blocks escaping reparse points.'
}
if ($watcherSource -notmatch 'Channel\.CreateBounded' -or
    $watcherSource -notmatch 'BoundedChannelFullMode\.DropOldest' -or
    $watcherSource -notmatch 'ShouldDebounce' -or
    $watcherSource -notmatch '_recentEventOrder' -or
    $watcherSource -match '_recentEvents\s*\.OrderBy') {
    throw 'FileSystemWatcher intake no longer exposes its queue and debounce bounds.'
}
if ($gitSource -notmatch 'UseShellExecute = false' -or
    $gitSource -notmatch 'GIT_OPTIONAL_LOCKS' -or
    $gitSource -notmatch 'GIT_CONFIG_NOSYSTEM' -or
    $gitSource -notmatch 'core\.fsmonitor=false' -or
    $gitSource -notmatch 'ContainsConfigInclude' -or
    $gitSource -notmatch 'ResolveCommonDirectory' -or
    $gitSource -notmatch '--porcelain=v2' -or
    $gitSource -notmatch 'ReadBoundedAsync' -or
    $gitSource -notmatch 'SensitiveTextRedactor') {
    throw 'Read-only Git execution no longer exposes its direct-process, output-bound, and redaction controls.'
}
if ($correlationSource -notmatch 'identities\.Length != 1' -or
    $correlationSource -notmatch 'ActivityConfidence\.Correlated' -or
    $correlationSource -notmatch 'CorrelationEvidenceSource') {
    throw 'Agent/Task correlation no longer fails closed on ambiguity.'
}

$sourceCommit = (& git -C $repositoryRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($sourceCommit)) {
    throw 'Could not resolve the source commit for the v0.3 File/Git gate.'
}
$contractSha256 = (Get-FileHash -LiteralPath $contractPath -Algorithm SHA256).Hash
$reviewRecordSha256 = (Get-FileHash -LiteralPath $reviewRecordPath -Algorithm SHA256).Hash
$gateReportPath = Join-Path $gateDirectory 'gate-report.txt'
if ($ImplementationOnly) {
    $gateReport = @(
        'HerdrOps v0.3 Issue #15 File/Git Implementation Gate',
        "GeneratedUtc: $([DateTime]::UtcNow.ToString('O'))",
        "SourceCommit: $sourceCommit",
        'Result: PASS',
        'GateKind: Implementation',
        'EvidenceClass: Contract plus Synthetic',
        'ImplementationOnly: true',
        'InstalledHerdrCommand: NOT INVOKED',
        "Tests: $passedTests/$totalTests PASS",
        "ReferenceSha256: $referenceSha256",
        "ContractSha256: $contractSha256",
        "IndependentReviewRecordSha256: $reviewRecordSha256",
        '',
        'WpfCaptures:'
    ) + ($captureEvidence | ForEach-Object { "$($_.Name): $($_.Sha256)" }) + @(
        '',
        'RequiredChecks:'
    ) + ($requiredChecks | ForEach-Object { "PASS $_" }) + @(
        '',
        'EvidenceBoundary:',
        'This implementation-only mode proves the scoped Contract and Synthetic checks, including contract-backed WPF rendering, for Issue #15.',
        'It provides no installed-Herdr evidence, no live File/Git evidence, or release evidence.',
        'It does not decide issue acceptance or publish a package.'
    )
}
else {
    $runtimeTraceSha256 = (Get-FileHash -LiteralPath $runtimeTracePath -Algorithm SHA256).Hash
    $gateReport = @(
        'HerdrOps v0.3 Issue #15 Scoped File/Git Activity Implementation Gate',
        "GeneratedUtc: $([DateTime]::UtcNow.ToString('O'))",
        "SourceCommit: $sourceCommit",
        'Result: IMPLEMENTATION READY / PARTIAL',
        'ImplementationGate: PASS',
        'IssueAcceptance: PENDING',
        'VersionReleaseGate: PENDING',
        'ActualFileSystemWatcher: OBSERVED',
        'ActualReadOnlyGitStatus: OBSERVED',
        'ActualHerdrAgentTaskCorrelation: NOT OBSERVED / NOT CLAIMED',
        'IndependentReviewVerdict: UNAVAILABLE / NOT CLAIMED',
        'FileReadInterception: NOT IMPLEMENTED / NOT CLAIMED',
        'IssueStateRequired: OPEN',
        "Tests: $passedTests/$totalTests PASS",
        "ReferenceSha256: $referenceSha256",
        "RuntimeTraceSha256: $runtimeTraceSha256",
        "ProductAssemblySha256: $coreAssemblySha256",
        "ContractSha256: $contractSha256",
        "IndependentReviewRecordSha256: $reviewRecordSha256",
        '',
        'WpfCaptures:'
    ) + ($captureEvidence | ForEach-Object { "$($_.Name): $($_.Sha256)" }) + @(
        '',
        'RequiredChecks:'
    ) + ($requiredChecks | ForEach-Object { "PASS $_" }) + @(
        '',
        'EvidenceBoundary:',
        'This gate proves canonical repository scoping, reparse-point escape rejection, bounded/debounced watcher intake, direct read-only bounded Git metadata, secret-redacted bounded diff preview, deterministic fail-closed correlation logic, separated Thai/English WPF rendering, and one actual local FileSystemWatcher plus Git trace from the hashed product assembly.',
        'RepositoryMutationInvoked=false applies to collector, Git, and source mutation. The caller-selected JSON report is the trace command output and is not concealed by that field.',
        'It does not prove file-read interception, actual Herdr Agent/Task correlation, installed-Herdr runtime behavior, or v0.3 release readiness. Issue #15 must remain open until actual Herdr correlation evidence is captured and independently reviewed.'
    )
}
$gateReport | Set-Content -LiteralPath $gateReportPath -Encoding utf8
$gateReport | Write-Output
Write-Output "GateReport: $gateReportPath"
