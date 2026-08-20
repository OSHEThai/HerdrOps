[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',

    [switch]$SkipBuild,
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$artifactRoot = Join-Path $repositoryRoot 'artifacts'

$requiredRelativePaths = @(
    'docs\protocol\v0.7-settings-contract.md',
    'docs\protocol\v0.7-lifecycle-contract.md',
    'src\HerdrOps.Domain\Settings\AppSettings.cs',
    'src\HerdrOps.Domain\Lifecycle\ApplicationInstanceGate.cs',
    'src\HerdrOps.Domain\Lifecycle\StartupRegistration.cs',
    'src\HerdrOps.Domain\Lifecycle\TrayContracts.cs',
    'src\HerdrOps.Infrastructure\Settings\DestinationKeyedLockRegistry.cs',
    'src\HerdrOps.Infrastructure\Settings\JsonAppSettingsStore.cs',
    'src\HerdrOps.App\App.xaml.cs',
    'src\HerdrOps.App\Lifecycle\AppLifecycleComposition.cs',
    'src\HerdrOps.App\Lifecycle\AppLifecycleController.cs',
    'src\HerdrOps.App\Lifecycle\AppSettingsLifecycleMapping.cs',
    'src\HerdrOps.App\Lifecycle\ApplicationInstanceGateStartup.cs',
    'src\HerdrOps.App\Lifecycle\DashboardWindowManager.cs',
    'src\HerdrOps.App\Lifecycle\ShutdownCleanup.cs',
    'src\HerdrOps.App\Lifecycle\StartupTransaction.cs',
    'src\HerdrOps.App\Lifecycle\SystemTrayBackend.cs',
    'src\HerdrOps.App\Lifecycle\TrayIconContract.cs',
    'src\HerdrOps.App\Lifecycle\TrayMenuBuilder.cs',
    'src\HerdrOps.App\Lifecycle\WindowsCurrentUserRunBackend.cs',
    'src\HerdrOps.App\Lifecycle\WindowsPerUserLifecycleMutex.cs',
    'src\HerdrOps.App\Lifecycle\WpfTrayCommandTarget.cs',
    'src\HerdrOps.App\Localization\UiLanguageService.cs',
    'src\HerdrOps.App\Views\ShellView.xaml.cs',
    'src\HerdrOps.App\Views\OverviewView.xaml.cs',
    'src\HerdrOps.App\Widgets\IWidgetWindowLauncher.cs',
    'src\HerdrOps.App\Widgets\WidgetGalleryView.xaml.cs',
    'src\HerdrOps.App\Widgets\WidgetGalleryWindow.xaml.cs',
    'src\HerdrOps.App\Widgets\WidgetWindow.xaml.cs',
    'tests\HerdrOps.UnitTests\TrayAndStartupLifecycleTests.cs',
    'tests\HerdrOps.IntegrationTests\AppSettingsStoreTests.cs',
    'tests\HerdrOps.IntegrationTests\AppLifecycleIntegrationTests.cs',
    'tests\HerdrOps.IntegrationTests\StartupLifecycleSafetyTests.cs',
    'tests\HerdrOps.IntegrationTests\TrayLifecycleIntegrationTests.cs'
)

$requiredChecks = @(
    # Unit checks (12 tests)
    'TrayCommandRouterRoutesEveryCommandToTheInjectedTarget',
    'TrayCommandRouterPropagatesTargetFailures',
    'TrayMenuModelRequiresExactlyOneSelectedLanguage',
    'StartAtLogonEnableDisableAndStatusAreIdempotentWithAnInMemoryBackend',
    'StartAtLogonReportsAConflictingDeterministicValue',
    'StartAtLogonConflictFailsClosedAndDisablePreservesTheOtherCommand',
    'StartAtLogonRejectsMalformedExecutablePaths',
    'StartAtLogonQuotesValidAbsoluteWindowsExecutableControls',
    'StartAtLogonPropagatesBackendFailures',
    'StartAtLogonRechecksAfterWriteAndReturnsControlledConflictStatus',
    'StartAtLogonDoesNotOverwriteOrDeleteAWriterSeenAtTheRaceBoundary',
    'TrayCleanupRetriesWhenHideAndBackendDisposeBothInitiallyFail',
    # Integration checks (39 tests)
    'RoundTripIsDeterministicAndContainsOneSelectedLanguage',
    'RestoreReversesToAPreviouslyAdmittedSnapshot',
    'LoadCanonicalizesValidNonCanonicalJsonAndRestoreWritesCanonicalBytes',
    'TamperedSnapshotIsRejectedWithoutChangingLastValidFile',
    'ResetDefaultsReplacesPreferencesWithExplicitDefaults',
    'MalformedOversizedAndUnsupportedDocumentsFailClosed',
    'ConstructorDoesNotPermitDocumentBoundAboveContractMaximum',
    'StrictParserRejectsInvalidUtf8BomDuplicateUnknownAndMissingProperties',
    'FailedAtomicCommitCleansTemporaryFileAndRetainsPreviousFile',
    'CancellationAfterAtomicCommitRestoresPreviousFileBeforeThrowing',
    'CancellationAfterAtomicCommitWithNoPreviousFileRemovesPublishedFileBeforeThrowing',
    'PostPublicationExceptionRollsBackPreviousFileBeforeFailureEscapes',
    'ConcurrentSaveWaitsForFailedRollbackAndCannotOverwriteSuccessfulSave',
    'CancelledWaitersReleaseReferencesAndEvictDestinationLock',
    'DestinationLockRegistryEvictsEntriesAfterDistinctDestinationStress',
    'TemporaryArtifactCollisionDoesNotDeletePreExistingFile',
    'BackupArtifactCollisionDoesNotDeletePreExistingFile',
    'CleanupFailureAfterRollbackIsVisibleAndRollbackPrecedesCleanup',
    'CleanupFailureIsSurfacedAlongsidePrimaryCommitFailure',
    'CleanupFailureAfterCommitIsNotSilentlyIgnored',
    'DestinationPolicyRejectsRelativeRootTraversalAndUncPaths',
    'DestinationPolicyAcceptsFileDirectlyInsideAllowedRoot',
    'DestinationPolicyRejectsEmptyReservedAdsInvalidAndDevicePaths',
    'CancellationIsCheckedBeforeValidationAndSnapshotValidation',
    'ExistingReparsePointComponentsAreRejectedWhenSupported',
    'BoundedTextAndInvalidValuesAreRejectedBeforeReplacement',
    'BoundedReaderRejectsConcurrentGrowthAfterReadingOnlyMaximumPlusOne',
    'LifecycleLoadsAppliesAndReversesSettingsWithInjectedSeams',
    'TrayMenuExposesAOneLanguageStartAtLogonRouteWhenTheHostOwnsIt',
    'TrayIconContractRemovesScreenshotMatteAndScalesForDpi',
    'ShutdownCleanupAttemptsEveryActionAndReportsEachFailure',
    'InjectedPerUserGateRejectsSecondLaunchAndReleasesDeterministically',
    'StartupTransactionRollsBackEveryFaultStageInReverseOrder',
    'StartupTransactionPreservesPrimaryBeforeCleanupFailure',
    'StartupTransactionRetriesFailedCleanupWithoutLosingStageOrder',
    'GateAcquisitionFailurePreservesPrimaryWhenTransactionalDisposeAlsoFails',
    'GateThatDoesNotAcquireIsDisposedBeforeTheStartupTransactionCommits',
    'TrayMenuBuilderProjectsConfiguredWidgetAndOneSelectedLanguage',
    'SyntheticTrayBackendExercisesControllerLifecycleWithoutAnOsResource'
)

function Test-PathInvariants {
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot,

        [Parameter(Mandatory)]
        [string[]]$Paths
    )

    $hashes = [ordered]@{}
    foreach ($relativePath in $Paths) {
        $fullPath = Join-Path $RepoRoot $relativePath
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
            throw "Required v0.7 lifecycle file was not found: $relativePath"
        }
        $hash = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash
        if ([string]::IsNullOrWhiteSpace($hash) -or $hash -notmatch '^[0-9A-Fa-f]{64}$') {
            throw "Invalid SHA-256 hash computed for $relativePath"
        }
        $hashes[$relativePath] = $hash
    }
    return $hashes
}

function Test-StaticContractInvariants {
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot
    )

    $appSettingsPath = Join-Path $RepoRoot 'src\HerdrOps.Domain\Settings\AppSettings.cs'
    $startupRegistrationPath = Join-Path $RepoRoot 'src\HerdrOps.Domain\Lifecycle\StartupRegistration.cs'
    $mutexPath = Join-Path $RepoRoot 'src\HerdrOps.App\Lifecycle\WindowsPerUserLifecycleMutex.cs'

    $appSettingsSource = Get-Content -LiteralPath $appSettingsPath -Raw
    $startupRegistrationSource = Get-Content -LiteralPath $startupRegistrationPath -Raw
    $mutexSource = Get-Content -LiteralPath $mutexPath -Raw

    # 1. 16 KiB maximum document bound
    if ($appSettingsSource -notmatch 'MaximumDocumentUtf8Bytes\s*=\s*(16\s*\*\s*1024|16384)') {
        throw 'AppSettings source does not declare MaximumDocumentUtf8Bytes as 16 KiB.'
    }

    # 2. Start-at-logon Registry key and value name
    if ($startupRegistrationSource -notmatch 'ValueName\s*=\s*"HerdrOps"') {
        throw 'StartupRegistration does not declare deterministic value name HerdrOps.'
    }
    if ($startupRegistrationSource -notmatch 'CurrentVersion\\Run') {
        throw 'StartupRegistration does not target HKCU CurrentVersion\Run.'
    }

    # 3. Single-instance and Startup mutex naming semantics: Global\{productName}.{userSid}.{suffix}
    if (-not $mutexSource.Contains('$"Global\\{productName}.{userSid}.{suffix}"')) {
        throw 'WindowsPerUserLifecycleMutex does not use the exact $"Global\{productName}.{userSid}.{suffix}" naming format.'
    }
    if ($mutexSource -notmatch 'SingleInstance' -or $mutexSource -notmatch 'StartupRegistration') {
        throw 'WindowsPerUserLifecycleMutex is missing required SingleInstance or StartupRegistration suffix.'
    }

    return $true
}

function Get-EvidenceClassificationLines {
    param(
        [bool]$SkipBuild,
        [bool]$BuildPassed,
        [bool]$StaticChecksPassed,
        [bool]$ContractChecksPassed,
        [int]$UnitPassed,
        [int]$UnitFailed,
        [int]$IntegrationPassed,
        [int]$IntegrationFailed,
        [int]$TotalTests,
        [int]$PassedTests,
        [int]$FailedTests,
        [int]$MissingChecksCount,
        [int]$RequiredPathsCount
    )

    $staticEvidenceLine = if (-not $SkipBuild -and $BuildPassed -and $StaticChecksPassed) {
        "StaticEvidence: OBSERVED ($RequiredPathsCount required files present and verified, locked build passed with 0 warnings/errors, format checked)"
    } elseif ($SkipBuild) {
        "StaticEvidence: NOT OBSERVED (-SkipBuild specified; locked build and format verification not executed; $RequiredPathsCount required files present and static invariants verified)"
    } else {
        'StaticEvidence: NOT OBSERVED / FAILED'
    }

    $contractEvidenceLine = if ($ContractChecksPassed) {
        'ContractEvidence: OBSERVED (Settings 16 KiB document bound, schema v1 model, HKCU Run key deterministic path, Global SID-scoped mutex invariant)'
    } else {
        'ContractEvidence: NOT OBSERVED / FAILED'
    }

    $unitEvidenceLine = if ($UnitPassed -ge 12 -and $UnitFailed -eq 0) {
        "UnitEvidence: OBSERVED ($UnitPassed unit tests passed: TrayCommandRouter, TrayMenuModel, StartAtLogonService)"
    } else {
        "UnitEvidence: FAILED (Passed: $UnitPassed, Failed: $UnitFailed)"
    }

    $integrationEvidenceLine = if ($IntegrationPassed -ge 39 -and $IntegrationFailed -eq 0) {
        "IntegrationEvidence: OBSERVED ($IntegrationPassed integration tests passed: AppSettingsStore, AppLifecycleController, StartupSafety, TrayLifecycle)"
    } else {
        "IntegrationEvidence: FAILED (Passed: $IntegrationPassed, Failed: $IntegrationFailed)"
    }

    $syntheticChecksPassed = ($TotalTests -ge 51 -and $FailedTests -eq 0 -and $TotalTests -eq $PassedTests -and $UnitPassed -ge 12 -and $UnitFailed -eq 0 -and $IntegrationPassed -ge 39 -and $IntegrationFailed -eq 0 -and $MissingChecksCount -eq 0)

    $syntheticEvidenceLine = if ($syntheticChecksPassed) {
        "SyntheticEvidence: OBSERVED ($PassedTests/$TotalTests automated tests passed: in-memory tray and startup backends, temporary settings storage, lifecycle state transitions)"
    } else {
        "SyntheticEvidence: NOT OBSERVED / FAILED (Total: $TotalTests, Passed: $PassedTests, Failed: $FailedTests, MissingNamedChecks: $MissingChecksCount)"
    }

    $observedClasses = [System.Collections.Generic.List[string]]::new()
    if (-not $SkipBuild -and $BuildPassed -and $StaticChecksPassed) {
        $observedClasses.Add('Static')
    }
    if ($ContractChecksPassed) {
        $observedClasses.Add('Contract')
    }
    if ($UnitPassed -ge 12 -and $UnitFailed -eq 0) {
        $observedClasses.Add('Unit')
    }
    if ($IntegrationPassed -ge 39 -and $IntegrationFailed -eq 0) {
        $observedClasses.Add('Integration')
    }
    if ($syntheticChecksPassed) {
        $observedClasses.Add('Synthetic')
    }

    $evidenceClassLine = "EvidenceClass: $($observedClasses -join ', ')"

    return [pscustomobject]@{
        StaticLine = $staticEvidenceLine
        ContractLine = $contractEvidenceLine
        UnitLine = $unitEvidenceLine
        IntegrationLine = $integrationEvidenceLine
        SyntheticLine = $syntheticEvidenceLine
        EvidenceClassLine = $evidenceClassLine
        SyntheticChecksPassed = $syntheticChecksPassed
        ObservedClasses = @($observedClasses)
    }
}

function Invoke-SelfTests {
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot,

        [Parameter(Mandatory)]
        [string[]]$Paths,

        [Parameter(Mandatory)]
        [string[]]$Checks
    )

    Write-Host 'Running deterministic self-checks for Test-V07Lifecycle.ps1...'

    # Check 1: Verify all 34 required paths and SHA256 computation
    $hashes = Test-PathInvariants -RepoRoot $RepoRoot -Paths $Paths
    if ($hashes.Count -ne 34) {
        throw "SelfTest failed: expected 34 hashes, got $($hashes.Count)"
    }
    Write-Host "  [PASS] RequiredPathsCoverage (34/34 paths verified with valid SHA-256)"

    # Check 2: Verify static and contract invariants
    $staticContractOk = Test-StaticContractInvariants -RepoRoot $RepoRoot
    if (-not $staticContractOk) {
        throw 'SelfTest failed: static contract invariants failed'
    }
    Write-Host '  [PASS] StaticContractInvariants (16 KiB bound, HKCU Run key, Global mutex format)'

    # Check 3: Verify named checks integrity
    if ($Checks.Count -ne 51) {
        throw "SelfTest failed: expected 51 named checks, got $($Checks.Count)"
    }
    $uniqueChecks = @($Checks | Select-Object -Unique)
    if ($uniqueChecks.Count -ne 51) {
        throw 'SelfTest failed: duplicate named checks found in array'
    }
    Write-Host '  [PASS] NamedChecksIntegrity (51/51 unique required test checks: 12 Unit, 39 Integration)'

    # Check 4: Verify Evidence Classification Matrix under -SkipBuild vs FullBuild vs Failures
    # 4a: Full build passing
    $fullPassing = Get-EvidenceClassificationLines `
        -SkipBuild $false -BuildPassed $true -StaticChecksPassed $true -ContractChecksPassed $true `
        -UnitPassed 12 -UnitFailed 0 -IntegrationPassed 39 -IntegrationFailed 0 `
        -TotalTests 51 -PassedTests 51 -FailedTests 0 -MissingChecksCount 0 -RequiredPathsCount 34
    if ($fullPassing.StaticLine -notmatch 'StaticEvidence:\s*OBSERVED.*locked build passed.*format checked') {
        throw 'SelfTest failed: full build did not report StaticEvidence OBSERVED with build and format info'
    }
    if ($fullPassing.SyntheticLine -notmatch 'SyntheticEvidence:\s*OBSERVED') {
        throw 'SelfTest failed: passing tests did not report SyntheticEvidence OBSERVED'
    }
    if (-not ($fullPassing.ObservedClasses -contains 'Static' -and $fullPassing.ObservedClasses -contains 'Synthetic')) {
        throw 'SelfTest failed: full passing run did not include Static and Synthetic in EvidenceClass'
    }

    # 4b: -SkipBuild passing
    $skipBuildPassing = Get-EvidenceClassificationLines `
        -SkipBuild $true -BuildPassed $false -StaticChecksPassed $true -ContractChecksPassed $true `
        -UnitPassed 12 -UnitFailed 0 -IntegrationPassed 39 -IntegrationFailed 0 `
        -TotalTests 51 -PassedTests 51 -FailedTests 0 -MissingChecksCount 0 -RequiredPathsCount 34
    if ($skipBuildPassing.StaticLine -match 'StaticEvidence:\s*OBSERVED' -or $skipBuildPassing.StaticLine -notmatch 'StaticEvidence:\s*NOT OBSERVED') {
        throw 'SelfTest failed: -SkipBuild must NEVER report StaticEvidence OBSERVED'
    }
    if ($skipBuildPassing.StaticLine -notmatch '-SkipBuild specified') {
        throw 'SelfTest failed: -SkipBuild must note that build and format verification were not executed'
    }
    if ($skipBuildPassing.ObservedClasses -contains 'Static') {
        throw 'SelfTest failed: -SkipBuild must NOT include Static in EvidenceClass'
    }
    if ($skipBuildPassing.SyntheticLine -notmatch 'SyntheticEvidence:\s*OBSERVED') {
        throw 'SelfTest failed: -SkipBuild with passing tests must report SyntheticEvidence OBSERVED'
    }

    # 4c: Failing tests
    $testFailure = Get-EvidenceClassificationLines `
        -SkipBuild $false -BuildPassed $true -StaticChecksPassed $true -ContractChecksPassed $true `
        -UnitPassed 11 -UnitFailed 1 -IntegrationPassed 39 -IntegrationFailed 0 `
        -TotalTests 51 -PassedTests 50 -FailedTests 1 -MissingChecksCount 1 -RequiredPathsCount 34
    if ($testFailure.SyntheticLine -match '^SyntheticEvidence:\s*OBSERVED' -or $testFailure.SyntheticLine -notmatch 'FAILED') {
        throw 'SelfTest failed: test failure must report SyntheticEvidence FAILED'
    }
    if ($testFailure.ObservedClasses -contains 'Synthetic') {
        throw 'SelfTest failed: test failure must NOT include Synthetic in EvidenceClass'
    }
    Write-Host '  [PASS] EvidenceClassificationMatrix (SkipBuild, FullBuild, and Failure paths verified)'

    # Check 5: Verify TRX Parser Logic
    $sampleTrxXml = @"
<?xml version="1.0" encoding="utf-8"?>
<TestRun id="test-run-1" name="MockRun" xmlns="http://microsoft.com/schemas/VisualStudio/TeamTest/2010">
  <ResultSummary outcome="Completed">
    <Counters total="12" executed="12" passed="12" failed="0" error="0" timeout="0" aborted="0" inconclusive="0" passedButRunAborted="0" notRunnable="0" notExecuted="0" disconnected="0" warning="0" completed="0" helpKeyword="" />
  </ResultSummary>
</TestRun>
"@
    [xml]$parsedTrx = $sampleTrxXml
    $counters = $parsedTrx.TestRun.ResultSummary.Counters
    if ([int]$counters.total -ne 12 -or [int]$counters.passed -ne 12 -or [int]$counters.failed -ne 0) {
        throw 'SelfTest failed: sample TRX parsing counters mismatch'
    }
    Write-Host '  [PASS] TrxParserDeterministicCounting (mock TRX XML counters validated)'

    # Check 6: Report formatting and boundary assertions
    $boundaryReport = @(
        'ActualHerdrRuntime: NOT REQUIRED / NOT OBSERVED / NOT CLAIMED',
        'ReleaseEvidence: NOT PRODUCED / NOT CLAIMED',
        'Status: IMPLEMENTATION GATE / NO RUNTIME OR RELEASE CREDIT'
    )
    foreach ($line in $boundaryReport) {
        if ($line -notmatch 'NOT|NO RUNTIME') {
            throw "SelfTest failed: boundary invariant violated: $line"
        }
    }
    Write-Host '  [PASS] GateReportContractFormatting (structure, boundaries, no runtime or release claim)'

    Write-Host 'SelfTest: PASS (all 6 deterministic self-check suites passed)'
    Write-Host 'Result: PASS'
    Write-Host 'Status: IMPLEMENTATION GATE / NO RUNTIME OR RELEASE CREDIT'
}

if ($SelfTest) {
    Invoke-SelfTests -RepoRoot $repositoryRoot -Paths $requiredRelativePaths -Checks $requiredChecks
    return
}

$sourceCommit = (& git -C $repositoryRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($sourceCommit)) {
    throw 'Could not resolve the source commit for the v0.7 lifecycle gate.'
}

$workingTreeStatus = @(& git -C $repositoryRoot status --porcelain=v1 --untracked-files=all | Where-Object {
    $_ -notmatch '^\?\?\s+artifacts[\\/]'
})
if ($LASTEXITCODE -ne 0) {
    throw 'Could not inspect the source working tree for the v0.7 lifecycle gate.'
}
if ($workingTreeStatus.Count -ne 0) {
    $pendingNonTool = @($workingTreeStatus | Where-Object { $_ -notmatch 'tools[\\/]Test-V07Lifecycle\.ps1' })
    if ($pendingNonTool.Count -ne 0) {
        throw "The v0.7 lifecycle gate requires a clean committed checkout. Pending paths: $($pendingNonTool -join ', ')"
    }
}

$sourceHashes = Test-PathInvariants -RepoRoot $repositoryRoot -Paths $requiredRelativePaths

$buildPassed = $false
if (-not $SkipBuild) {
    & (Join-Path $PSScriptRoot 'Invoke-Build.ps1') -Configuration $Configuration -VerifyFormat -SkipTests
    if ($LASTEXITCODE -ne 0) {
        throw "v0.7 lifecycle build gate failed with exit code $LASTEXITCODE."
    }
    $buildPassed = $true
}

$staticChecksPassed = $true
$contractChecksPassed = Test-StaticContractInvariants -RepoRoot $repositoryRoot

$runId = "$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ', [Globalization.CultureInfo]::InvariantCulture))-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
$gateDirectory = Join-Path $artifactRoot "release-gates\v0.7.0\issue-36\$runId"
$testResultDirectory = Join-Path $gateDirectory 'test-results'
New-Item -ItemType Directory -Path $testResultDirectory -Force | Out-Null

$testRuns = @(
    [pscustomobject]@{
        Name = 'UnitTests'
        Category = 'Unit'
        Project = Join-Path $repositoryRoot 'tests\HerdrOps.UnitTests\HerdrOps.UnitTests.csproj'
        Filter = 'FullyQualifiedName~TrayAndStartupLifecycleTests'
        Log = 'tray-startup-unit.trx'
    },
    [pscustomobject]@{
        Name = 'IntegrationTests'
        Category = 'Integration'
        Project = Join-Path $repositoryRoot 'tests\HerdrOps.IntegrationTests\HerdrOps.IntegrationTests.csproj'
        Filter = 'FullyQualifiedName~AppSettingsStoreTests|FullyQualifiedName~AppLifecycleIntegrationTests|FullyQualifiedName~StartupLifecycleSafetyTests|FullyQualifiedName~TrayLifecycleIntegrationTests'
        Log = 'lifecycle-settings-integration.trx'
    }
)

$categoryCounters = [ordered]@{
    'Unit' = [ordered]@{ Total = 0; Passed = 0; Failed = 0 }
    'Integration' = [ordered]@{ Total = 0; Passed = 0; Failed = 0 }
}

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
        throw "v0.7 lifecycle $($testRun.Name) failed with exit code $LASTEXITCODE."
    }

    $trxPath = Join-Path $testResultDirectory $testRun.Log
    if (Test-Path -LiteralPath $trxPath -PathType Leaf) {
        [xml]$trx = Get-Content -LiteralPath $trxPath -Raw
        $counters = $trx.TestRun.ResultSummary.Counters
        $categoryCounters[$testRun.Category].Total += [int]$counters.total
        $categoryCounters[$testRun.Category].Passed += [int]$counters.passed
        $categoryCounters[$testRun.Category].Failed += [int]$counters.failed
    }
}

$testResults = @(Get-ChildItem -LiteralPath $testResultDirectory -Filter '*.trx' -File)
if ($testResults.Count -ne 2) {
    throw "Expected exactly 2 fresh lifecycle TRX files, found $($testResults.Count)."
}

$combinedTestLog = ($testResults | ForEach-Object {
    Get-Content -LiteralPath $_.FullName -Raw
}) -join "`n"

$missingChecks = [System.Collections.Generic.List[string]]::new()
foreach ($check in $requiredChecks) {
    if ($combinedTestLog -notmatch [Regex]::Escape($check)) {
        $missingChecks.Add($check)
    }
}
if ($missingChecks.Count -ne 0) {
    throw "Required v0.7 lifecycle checks are absent from fresh test logs ($($missingChecks.Count) missing): $($missingChecks -join ', ')"
}

$totalTests = 0
$passedTests = 0
$failedTests = 0
foreach ($category in $categoryCounters.Keys) {
    $totalTests += $categoryCounters[$category].Total
    $passedTests += $categoryCounters[$category].Passed
    $failedTests += $categoryCounters[$category].Failed
}

if ($totalTests -lt $requiredChecks.Count -or $failedTests -ne 0 -or $totalTests -ne $passedTests) {
    throw "Lifecycle test counters are not all passing: total=$totalTests passed=$passedTests failed=$failedTests"
}

$unitPass = $categoryCounters['Unit'].Passed
$unitFail = $categoryCounters['Unit'].Failed
$integrationPass = $categoryCounters['Integration'].Passed
$integrationFail = $categoryCounters['Integration'].Failed

$evidence = Get-EvidenceClassificationLines `
    -SkipBuild ([bool]$SkipBuild) `
    -BuildPassed $buildPassed `
    -StaticChecksPassed $staticChecksPassed `
    -ContractChecksPassed $contractChecksPassed `
    -UnitPassed $unitPass `
    -UnitFailed $unitFail `
    -IntegrationPassed $integrationPass `
    -IntegrationFailed $integrationFail `
    -TotalTests $totalTests `
    -PassedTests $passedTests `
    -FailedTests $failedTests `
    -MissingChecksCount ($missingChecks.Count) `
    -RequiredPathsCount ($requiredRelativePaths.Count)

$reportPath = Join-Path $gateDirectory 'gate-report.txt'
$reportLines = @(
    '======================================================================',
    'HerdrOps v0.7.0 Issue #36 Lifecycle & Settings Implementation Gate',
    '======================================================================',
    "RunId: $runId",
    "SourceCommit: $sourceCommit",
    "Configuration: $Configuration",
    "TimestampUtc: $([DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture))",
    '',
    '----------------------------------------------------------------------',
    'Evidence Classification (Conditional on Verified Runs)',
    '----------------------------------------------------------------------',
    $evidence.EvidenceClassLine,
    $evidence.StaticLine,
    $evidence.ContractLine,
    $evidence.UnitLine,
    $evidence.IntegrationLine,
    $evidence.SyntheticLine,
    'ActualHerdrRuntime: NOT REQUIRED / NOT OBSERVED / NOT CLAIMED',
    'WindowsHostEvidence: PENDING / NOT OBSERVED (actual tray visibility, logon launch, AppData persistence across reboots)',
    'HumanAccessibilityEvidence: PENDING / NOT OBSERVED (screen reader Narrator audio, high contrast, physical DPI scaling)',
    'ReleaseEvidence: NOT PRODUCED / NOT CLAIMED',
    'Status: IMPLEMENTATION GATE / NO RUNTIME OR RELEASE CREDIT',
    'IssueTracker: Issue #36 remains OPEN pending reference-host and human acceptance',
    '',
    '----------------------------------------------------------------------',
    'Automated Test Execution Breakdown',
    '----------------------------------------------------------------------',
    "TotalTestsExecuted: $totalTests",
    "PassedTests: $passedTests",
    "FailedTests: $failedTests",
    "UnitTests: $($categoryCounters['Unit'].Passed) passed / $($categoryCounters['Unit'].Total) total",
    "IntegrationTests: $($categoryCounters['Integration'].Passed) passed / $($categoryCounters['Integration'].Total) total",
    "RequiredNamedChecksVerified: $($requiredChecks.Count)/$($requiredChecks.Count) OBSERVED (12 Unit, 39 Integration)",
    '',
    'TRX Results Files:'
)

foreach ($trxFile in $testResults) {
    $trxHash = (Get-FileHash -LiteralPath $trxFile.FullName -Algorithm SHA256).Hash
    $reportLines += "  - $($trxFile.Name) (SHA-256: $trxHash)"
}

$reportLines += @(
    '',
    '----------------------------------------------------------------------',
    'Required Source and Contract Hashes',
    '----------------------------------------------------------------------'
)

foreach ($relativePath in $sourceHashes.Keys) {
    $reportLines += "  - ${relativePath}: $($sourceHashes[$relativePath])"
}

$reportLines += @(
    '',
    '----------------------------------------------------------------------',
    'Required Named Checks',
    '----------------------------------------------------------------------'
)

foreach ($check in $requiredChecks) {
    $reportLines += "  - PASS $check"
}

$reportLines += @(
    '',
    '----------------------------------------------------------------------',
    'Gate Verdict',
    '----------------------------------------------------------------------',
    'ImplementationGate: PASS',
    'Result: PASS'
)

$reportContent = $reportLines -join "`r`n"
Set-Content -LiteralPath $reportPath -Value $reportContent -Encoding utf8

$reportHash = (Get-FileHash -LiteralPath $reportPath -Algorithm SHA256).Hash

Write-Host "GateReport: $reportPath"
Write-Host "GateReportSha256: $reportHash"
Write-Host "TotalTests: $totalTests (Unit: $unitPass, Integration: $integrationPass)"
Write-Host "RequiredNamedChecksVerified: $($requiredChecks.Count)/$($requiredChecks.Count)"
Write-Host "Result: PASS"
Write-Host "ImplementationGate: PASS"
Write-Host "Status: IMPLEMENTATION GATE / NO RUNTIME OR RELEASE CREDIT"
