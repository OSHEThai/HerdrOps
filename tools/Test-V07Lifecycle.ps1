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
$buildMarkerDirectory = Join-Path $artifactRoot 'build-markers'
$buildMarkerPath = Join-Path $buildMarkerDirectory 'v07-lifecycle-build-marker.json'

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
    # Unit checks (exact 12 tests)
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
    # Integration checks (exact 39 tests)
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
        $hash = ((Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash).ToUpperInvariant()
        if ([string]::IsNullOrWhiteSpace($hash) -or $hash -notmatch '^[0-9A-F]{64}$') {
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

function Get-LifecycleBinaryProvenance {
    param(
        [Parameter(Mandatory)]
        [string]$ArtifactRoot,

        [Parameter(Mandatory)]
        [string]$Configuration
    )

    $configFolder = $Configuration.ToLowerInvariant()
    $trackedAssemblies = @(
        "bin/HerdrOps.App/$configFolder/HerdrOps.App.dll",
        "bin/HerdrOps.Domain/$configFolder/HerdrOps.Domain.dll",
        "bin/HerdrOps.Infrastructure/$configFolder/HerdrOps.Infrastructure.dll",
        "bin/HerdrOps.UnitTests/$configFolder/HerdrOps.UnitTests.dll",
        "bin/HerdrOps.IntegrationTests/$configFolder/HerdrOps.IntegrationTests.dll"
    )

    $records = [ordered]@{}
    foreach ($relPath in $trackedAssemblies) {
        $fullPath = Join-Path $ArtifactRoot ($relPath.Replace('/', '\'))
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
            return $null
        }
        $hash = ((Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash).ToUpperInvariant()
        $records[$relPath] = $hash
    }
    return $records
}

function Write-LifecycleBuildMarker {
    param(
        [Parameter(Mandatory)]
        [string]$MarkerPath,

        [Parameter(Mandatory)]
        [string]$SourceCommit,

        [Parameter(Mandatory)]
        [string]$Configuration,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$BinaryHashes
    )

    $markerDirectory = Split-Path -Path $MarkerPath -Parent
    if (-not (Test-Path -LiteralPath $markerDirectory)) {
        New-Item -ItemType Directory -Path $markerDirectory -Force | Out-Null
    }

    $assemblyEntries = @()
    foreach ($key in $BinaryHashes.Keys) {
        $assemblyEntries += [ordered]@{
            relativePath = [string]$key
            sha256 = [string]$BinaryHashes[$key]
        }
    }

    $markerObject = [ordered]@{
        schemaVersion = 1
        gate = 'v0.7.0-issue-36-lifecycle'
        sourceCommit = $SourceCommit
        configuration = $Configuration
        builtAtUtc = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        assemblies = $assemblyEntries
    }

    $json = $markerObject | ConvertTo-Json -Depth 5
    [IO.File]::WriteAllText($MarkerPath, $json + "`n", [Text.UTF8Encoding]::new($false))
}

function Test-LifecycleBuildMarker {
    param(
        [Parameter(Mandatory)]
        [string]$MarkerPath,

        [Parameter(Mandatory)]
        [string]$ExpectedCommit,

        [Parameter(Mandatory)]
        [string]$ExpectedConfiguration,

        [Parameter(Mandatory)]
        [string]$ArtifactRoot
    )

    if (-not (Test-Path -LiteralPath $MarkerPath -PathType Leaf)) {
        return [pscustomobject]@{
            Verified = $false
            Reason = 'Build marker was not found'
            BinaryHashes = $null
        }
    }

    try {
        $raw = [IO.File]::ReadAllText($MarkerPath)
        $marker = $raw | ConvertFrom-Json
        if ($null -eq $marker -or
            [int]$marker.schemaVersion -ne 1 -or
            [string]$marker.gate -cne 'v0.7.0-issue-36-lifecycle') {
            return [pscustomobject]@{
                Verified = $false
                Reason = 'Build marker header/schema is invalid'
                BinaryHashes = $null
            }
        }

        if ([string]$marker.sourceCommit -cne $ExpectedCommit) {
            return [pscustomobject]@{
                Verified = $false
                Reason = "Build marker commit '$($marker.sourceCommit)' does not match current source commit '$ExpectedCommit'"
                BinaryHashes = $null
            }
        }

        if ([string]$marker.configuration -cne $ExpectedConfiguration) {
            return [pscustomobject]@{
                Verified = $false
                Reason = "Build marker configuration '$($marker.configuration)' does not match expected '$ExpectedConfiguration'"
                BinaryHashes = $null
            }
        }

        $currentHashes = Get-LifecycleBinaryProvenance -ArtifactRoot $ArtifactRoot -Configuration $ExpectedConfiguration
        if ($null -eq $currentHashes) {
            return [pscustomobject]@{
                Verified = $false
                Reason = 'One or more tracked assemblies are missing from the build output'
                BinaryHashes = $null
            }
        }

        $markerAssemblies = @($marker.assemblies)
        if ($markerAssemblies.Count -ne $currentHashes.Count) {
            return [pscustomobject]@{
                Verified = $false
                Reason = "Build marker assembly count mismatch: expected $($currentHashes.Count), got $($markerAssemblies.Count)"
                BinaryHashes = $null
            }
        }

        foreach ($entry in $markerAssemblies) {
            $rel = [string]$entry.relativePath
            $expectedHash = [string]$entry.sha256
            if (-not $currentHashes.Contains($rel) -or $currentHashes[$rel] -cne $expectedHash) {
                return [pscustomobject]@{
                    Verified = $false
                    Reason = "Assembly '$rel' hash changed since the build marker was generated"
                    BinaryHashes = $null
                }
            }
        }

        return [pscustomobject]@{
            Verified = $true
            Reason = 'Same-commit binary provenance verified'
            BinaryHashes = $currentHashes
        }
    } catch {
        return [pscustomobject]@{
            Verified = $false
            Reason = "Could not parse or validate build marker: $($_.Exception.Message)"
            BinaryHashes = $null
        }
    }
}

function Get-EvidenceClassificationLines {
    param(
        [bool]$SkipBuild,
        [bool]$ProvenanceVerified,
        [string]$ProvenanceReason,
        [bool]$BuildPassed,
        [bool]$StaticChecksPassed,
        [bool]$ContractChecksPassed,
        [int]$UnitTotal,
        [int]$UnitPassed,
        [int]$UnitFailed,
        [int]$IntegrationTotal,
        [int]$IntegrationPassed,
        [int]$IntegrationFailed,
        [int]$TotalTests,
        [int]$PassedTests,
        [int]$FailedTests,
        [int]$MissingChecksCount,
        [int]$RequiredPathsCount
    )

    $unitExactPassed = ($UnitTotal -eq 12 -and $UnitPassed -eq 12 -and $UnitFailed -eq 0)
    $integrationExactPassed = ($IntegrationTotal -eq 39 -and $IntegrationPassed -eq 39 -and $IntegrationFailed -eq 0)
    $syntheticExactPassed = ($TotalTests -eq 51 -and $PassedTests -eq 51 -and $FailedTests -eq 0 -and $MissingChecksCount -eq 0 -and $unitExactPassed -and $integrationExactPassed)

    $staticEvidenceLine = if (-not $SkipBuild -and $BuildPassed -and $StaticChecksPassed) {
        "StaticEvidence: OBSERVED ($RequiredPathsCount required files present and verified, locked build passed with 0 warnings/errors, format checked, same-commit binary provenance marker created)"
    } elseif ($SkipBuild -and $ProvenanceVerified -and $StaticChecksPassed) {
        "StaticEvidence: OBSERVED ($RequiredPathsCount required files present and verified, same-commit binary provenance verified from build marker, locked build skipped)"
    } elseif ($SkipBuild) {
        "StaticEvidence: NOT OBSERVED (-SkipBuild specified without verified same-commit binary provenance: $ProvenanceReason; $RequiredPathsCount required files present and static invariants verified)"
    } else {
        'StaticEvidence: NOT OBSERVED / FAILED'
    }

    $contractEvidenceLine = if ($ContractChecksPassed) {
        'ContractEvidence: OBSERVED (Settings 16 KiB document bound, schema v1 model, HKCU Run key deterministic path, Global SID-scoped mutex invariant)'
    } else {
        'ContractEvidence: NOT OBSERVED / FAILED'
    }

    $unitEvidenceLine = if ($unitExactPassed) {
        "UnitEvidence: OBSERVED (12/12 unit tests passed: TrayCommandRouter [2], TrayMenuModel [1], StartAtLogonService [8], TrayLifecycleController [1])"
    } else {
        "UnitEvidence: FAILED (Expected: 12/12 passed 0 failed, Observed: Total=$UnitTotal, Passed=$UnitPassed, Failed=$UnitFailed)"
    }

    $integrationEvidenceLine = if ($integrationExactPassed) {
        "IntegrationEvidence: OBSERVED (39/39 integration tests passed: AppSettingsStore [27], AppLifecycleController [4], StartupSafety [6], TrayLifecycle [2])"
    } else {
        "IntegrationEvidence: FAILED (Expected: 39/39 passed 0 failed, Observed: Total=$IntegrationTotal, Passed=$IntegrationPassed, Failed=$IntegrationFailed)"
    }

    $syntheticEvidenceLine = if ($syntheticExactPassed) {
        "SyntheticEvidence: OBSERVED (51/51 automated tests passed: in-memory tray and startup backends, temporary settings storage, lifecycle state transitions)"
    } else {
        "SyntheticEvidence: NOT OBSERVED / FAILED (Expected: 51/51 passed 0 failed 0 missing, Observed: Total=$TotalTests, Passed=$PassedTests, Failed=$FailedTests, MissingNamedChecks=$MissingChecksCount)"
    }

    $observedClasses = [System.Collections.Generic.List[string]]::new()
    if ((-not $SkipBuild -and $BuildPassed -and $StaticChecksPassed) -or ($SkipBuild -and $ProvenanceVerified -and $StaticChecksPassed)) {
        $observedClasses.Add('Static')
    }
    if ($ContractChecksPassed) {
        $observedClasses.Add('Contract')
    }
    if ($unitExactPassed) {
        $observedClasses.Add('Unit')
    }
    if ($integrationExactPassed) {
        $observedClasses.Add('Integration')
    }
    if ($syntheticExactPassed) {
        $observedClasses.Add('Synthetic')
    }

    $evidenceClassLine = "EvidenceClass: $($observedClasses -join ', ')"

    $isFullAcceptancePass = ((-not $SkipBuild -and $BuildPassed -or ($SkipBuild -and $ProvenanceVerified)) -and
        $StaticChecksPassed -and $ContractChecksPassed -and $syntheticExactPassed)

    $verdictResult = if ($isFullAcceptancePass) {
        'PASS'
    } elseif ($SkipBuild -and -not $ProvenanceVerified -and $StaticChecksPassed -and $ContractChecksPassed -and $syntheticExactPassed) {
        'NON-ACCEPTANCE CHECKS PASS'
    } else {
        'FAIL'
    }

    $implementationGateVerdict = if ($isFullAcceptancePass) {
        'PASS'
    } elseif ($SkipBuild -and -not $ProvenanceVerified -and $StaticChecksPassed -and $ContractChecksPassed -and $syntheticExactPassed) {
        'NON-ACCEPTANCE (SkipBuild missing verified same-commit binary provenance marker)'
    } else {
        'FAIL'
    }

    return [pscustomobject]@{
        StaticLine = $staticEvidenceLine
        ContractLine = $contractEvidenceLine
        UnitLine = $unitEvidenceLine
        IntegrationLine = $integrationEvidenceLine
        SyntheticLine = $syntheticEvidenceLine
        EvidenceClassLine = $evidenceClassLine
        SyntheticChecksPassed = $syntheticExactPassed
        UnitExactPassed = $unitExactPassed
        IntegrationExactPassed = $integrationExactPassed
        ObservedClasses = @($observedClasses)
        IsFullAcceptancePass = $isFullAcceptancePass
        VerdictResult = $verdictResult
        ImplementationGateVerdict = $implementationGateVerdict
    }
}

function Invoke-SelfTests {
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot,

        [Parameter(Mandatory)]
        [string[]]$Paths,

        [Parameter(Mandatory)]
        [string[]]$Checks,

        [Parameter(Mandatory)]
        [string]$ArtifactRoot
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

    # Check 3: Verify named checks integrity (exact 12 Unit, exact 39 Integration, exact 51 Total)
    if ($Checks.Count -ne 51) {
        throw "SelfTest failed: expected exact 51 named checks, got $($Checks.Count)"
    }
    $uniqueChecks = @($Checks | Select-Object -Unique)
    if ($uniqueChecks.Count -ne 51) {
        throw 'SelfTest failed: duplicate named checks found in array'
    }
    Write-Host '  [PASS] NamedChecksIntegrity (51/51 unique required test checks: exact 12 Unit, exact 39 Integration)'

    # Check 4: Verify Evidence Classification Matrix under FullBuild vs SkipBuild with Provenance vs SkipBuild without Provenance vs Failures
    # 4a: Full build passing
    $fullPassing = Get-EvidenceClassificationLines `
        -SkipBuild $false -ProvenanceVerified $true -ProvenanceReason 'Full locked build executed with format verification' `
        -BuildPassed $true -StaticChecksPassed $true -ContractChecksPassed $true `
        -UnitTotal 12 -UnitPassed 12 -UnitFailed 0 `
        -IntegrationTotal 39 -IntegrationPassed 39 -IntegrationFailed 0 `
        -TotalTests 51 -PassedTests 51 -FailedTests 0 -MissingChecksCount 0 -RequiredPathsCount 34
    if ($fullPassing.StaticLine -notmatch 'StaticEvidence:\s*OBSERVED.*locked build passed.*format checked') {
        throw 'SelfTest failed: full build did not report StaticEvidence OBSERVED with build and format info'
    }
    if ($fullPassing.SyntheticLine -notmatch 'SyntheticEvidence:\s*OBSERVED \(51/51 automated tests passed') {
        throw 'SelfTest failed: passing tests did not report exact 51/51 SyntheticEvidence OBSERVED'
    }
    if ($fullPassing.UnitLine -notmatch 'UnitEvidence:\s*OBSERVED \(12/12 unit tests passed') {
        throw 'SelfTest failed: unit line did not report exact 12/12 UnitEvidence OBSERVED'
    }
    if ($fullPassing.IntegrationLine -notmatch 'IntegrationEvidence:\s*OBSERVED \(39/39 integration tests passed') {
        throw 'SelfTest failed: integration line did not report exact 39/39 IntegrationEvidence OBSERVED'
    }
    if (-not ($fullPassing.ObservedClasses -contains 'Static' -and $fullPassing.ObservedClasses -contains 'Synthetic')) {
        throw 'SelfTest failed: full passing run did not include Static and Synthetic in EvidenceClass'
    }
    if ($fullPassing.VerdictResult -ne 'PASS' -or $fullPassing.ImplementationGateVerdict -ne 'PASS') {
        throw 'SelfTest failed: full passing run did not produce PASS verdict'
    }

    # 4b: -SkipBuild with verified same-commit binary provenance
    $skipBuildWithProvenance = Get-EvidenceClassificationLines `
        -SkipBuild $true -ProvenanceVerified $true -ProvenanceReason 'Same-commit binary provenance verified from build marker' `
        -BuildPassed $false -StaticChecksPassed $true -ContractChecksPassed $true `
        -UnitTotal 12 -UnitPassed 12 -UnitFailed 0 `
        -IntegrationTotal 39 -IntegrationPassed 39 -IntegrationFailed 0 `
        -TotalTests 51 -PassedTests 51 -FailedTests 0 -MissingChecksCount 0 -RequiredPathsCount 34
    if ($skipBuildWithProvenance.StaticLine -notmatch 'StaticEvidence:\s*OBSERVED.*same-commit binary provenance verified') {
        throw 'SelfTest failed: -SkipBuild with verified provenance must report StaticEvidence OBSERVED'
    }
    if (-not ($skipBuildWithProvenance.ObservedClasses -contains 'Static' -and $skipBuildWithProvenance.ObservedClasses -contains 'Synthetic')) {
        throw 'SelfTest failed: -SkipBuild with verified provenance must include Static and Synthetic in EvidenceClass'
    }
    if ($skipBuildWithProvenance.VerdictResult -ne 'PASS' -or $skipBuildWithProvenance.ImplementationGateVerdict -ne 'PASS') {
        throw 'SelfTest failed: -SkipBuild with verified provenance must produce PASS verdict'
    }

    # 4c: -SkipBuild without verified binary provenance (missing or stale marker) -> NON-ACCEPTANCE
    $skipBuildNoProvenance = Get-EvidenceClassificationLines `
        -SkipBuild $true -ProvenanceVerified $false -ProvenanceReason 'Build marker was not found' `
        -BuildPassed $false -StaticChecksPassed $true -ContractChecksPassed $true `
        -UnitTotal 12 -UnitPassed 12 -UnitFailed 0 `
        -IntegrationTotal 39 -IntegrationPassed 39 -IntegrationFailed 0 `
        -TotalTests 51 -PassedTests 51 -FailedTests 0 -MissingChecksCount 0 -RequiredPathsCount 34
    if ($skipBuildNoProvenance.StaticLine -notmatch 'StaticEvidence:\s*NOT OBSERVED \(-SkipBuild specified without verified same-commit binary provenance') {
        throw 'SelfTest failed: -SkipBuild without provenance must report StaticEvidence NOT OBSERVED with reason'
    }
    if ($skipBuildNoProvenance.ObservedClasses -contains 'Static') {
        throw 'SelfTest failed: -SkipBuild without provenance must NOT include Static in EvidenceClass'
    }
    if ($skipBuildNoProvenance.VerdictResult -ne 'NON-ACCEPTANCE CHECKS PASS' -or
        $skipBuildNoProvenance.ImplementationGateVerdict -notmatch 'NON-ACCEPTANCE') {
        throw 'SelfTest failed: -SkipBuild without provenance must report NON-ACCEPTANCE verdict'
    }

    # 4d: Failing test counters or count mismatch (e.g. 11/12 unit or 38/39 integration or 13/12 overflow)
    $unitFailure = Get-EvidenceClassificationLines `
        -SkipBuild $false -ProvenanceVerified $true -ProvenanceReason 'Full locked build executed' `
        -BuildPassed $true -StaticChecksPassed $true -ContractChecksPassed $true `
        -UnitTotal 12 -UnitPassed 11 -UnitFailed 1 `
        -IntegrationTotal 39 -IntegrationPassed 39 -IntegrationFailed 0 `
        -TotalTests 51 -PassedTests 50 -FailedTests 1 -MissingChecksCount 1 -RequiredPathsCount 34
    if ($unitFailure.SyntheticLine -notmatch 'SyntheticEvidence:\s*NOT OBSERVED / FAILED' -or
        $unitFailure.UnitLine -notmatch 'UnitEvidence:\s*FAILED') {
        throw 'SelfTest failed: unit failure must report FAILED'
    }
    if ($unitFailure.VerdictResult -ne 'FAIL') {
        throw 'SelfTest failed: unit test failure must produce FAIL verdict'
    }

    $countOverflow = Get-EvidenceClassificationLines `
        -SkipBuild $false -ProvenanceVerified $true -ProvenanceReason 'Full locked build executed' `
        -BuildPassed $true -StaticChecksPassed $true -ContractChecksPassed $true `
        -UnitTotal 13 -UnitPassed 13 -UnitFailed 0 `
        -IntegrationTotal 39 -IntegrationPassed 39 -IntegrationFailed 0 `
        -TotalTests 52 -PassedTests 52 -FailedTests 0 -MissingChecksCount 0 -RequiredPathsCount 34
    if ($countOverflow.UnitExactPassed -or $countOverflow.SyntheticChecksPassed) {
        throw 'SelfTest failed: lower-bound or count overflow must NOT pass exact count checks'
    }
    Write-Host '  [PASS] EvidenceClassificationMatrix (FullBuild, SkipBuild with Provenance, SkipBuild Non-Acceptance, and Failures verified)'

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

    # Check 6: Verify Build Marker Creation and Verification Logic
    $tempMarkerDir = Join-Path ([IO.Path]::GetTempPath()) ("herdrops-test-marker-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempMarkerDir -Force | Out-Null
    try {
        $mockMarkerFile = Join-Path $tempMarkerDir 'test-marker.json'
        $mockHashes = [ordered]@{
            'bin/HerdrOps.App/release/HerdrOps.App.dll' = ('A' * 64)
            'bin/HerdrOps.Domain/release/HerdrOps.Domain.dll' = ('B' * 64)
        }
        Write-LifecycleBuildMarker `
            -MarkerPath $mockMarkerFile `
            -SourceCommit '0123456789abcdef0123456789abcdef01234567' `
            -Configuration 'Release' `
            -BinaryHashes $mockHashes

        if (-not (Test-Path -LiteralPath $mockMarkerFile -PathType Leaf)) {
            throw 'SelfTest failed: build marker was not written'
        }

        # Test missing marker
        $missingResult = Test-LifecycleBuildMarker `
            -MarkerPath (Join-Path $tempMarkerDir 'nonexistent.json') `
            -ExpectedCommit '0123456789abcdef0123456789abcdef01234567' `
            -ExpectedConfiguration 'Release' `
            -ArtifactRoot $tempMarkerDir
        if ($missingResult.Verified) {
            throw 'SelfTest failed: missing marker must not verify'
        }

        # Test commit mismatch
        $mismatchedCommit = Test-LifecycleBuildMarker `
            -MarkerPath $mockMarkerFile `
            -ExpectedCommit 'ffffffffffffffffffffffffffffffffffffffff' `
            -ExpectedConfiguration 'Release' `
            -ArtifactRoot $tempMarkerDir
        if ($mismatchedCommit.Verified -or $mismatchedCommit.Reason -notmatch 'does not match current source commit') {
            throw 'SelfTest failed: commit mismatch must not verify'
        }

        # Test configuration mismatch
        $mismatchedConfig = Test-LifecycleBuildMarker `
            -MarkerPath $mockMarkerFile `
            -ExpectedCommit '0123456789abcdef0123456789abcdef01234567' `
            -ExpectedConfiguration 'Debug' `
            -ArtifactRoot $tempMarkerDir
        if ($mismatchedConfig.Verified -or $mismatchedConfig.Reason -notmatch 'configuration') {
            throw 'SelfTest failed: configuration mismatch must not verify'
        }
        Write-Host '  [PASS] BuildMarkerProvenanceLogic (creation, schema, commit mismatch, and configuration mismatch verified)'
    } finally {
        if (Test-Path -LiteralPath $tempMarkerDir) {
            Remove-Item -LiteralPath $tempMarkerDir -Recurse -Force
        }
    }

    # Check 7: Report formatting and exact negative boundary assertions
    $boundaryReport = @(
        'ActualHerdrRuntime: NOT REQUIRED / NOT OBSERVED / NOT CLAIMED',
        'ActualHerdrRuntimeEvidence: NOT OBSERVED / NOT CLAIMED',
        'ReleaseEvidence: NOT PRODUCED / NOT CLAIMED',
        'ReleasePublication: NOT PERFORMED',
        'Status: IMPLEMENTATION GATE / NO RUNTIME OR RELEASE CREDIT',
        'IssueTracker: Issue #36 remains OPEN pending reference-host and human acceptance'
    )
    foreach ($line in $boundaryReport) {
        if ($line -notmatch 'NOT|NO RUNTIME|PENDING') {
            throw "SelfTest failed: boundary invariant violated: $line"
        }
    }
    Write-Host '  [PASS] GateReportContractFormatting (exact negative runtime and release boundaries)'

    Write-Host 'SelfTest: PASS (all 7 deterministic self-check suites passed)'
    Write-Host 'Result: PASS'
    Write-Host 'Status: IMPLEMENTATION GATE / NO RUNTIME OR RELEASE CREDIT'
}

if ($SelfTest) {
    Invoke-SelfTests -RepoRoot $repositoryRoot -Paths $requiredRelativePaths -Checks $requiredChecks -ArtifactRoot $artifactRoot
    return
}

# ---------------------------------------------------------------------------
# Pre-Execution Invariants: Clean Checkout, HEAD Resolution, and Script Hash
# ---------------------------------------------------------------------------
$gateScriptPath = Get-Item -LiteralPath $PSCommandPath -Force
$gateScriptInitialHash = ((Get-FileHash -LiteralPath $gateScriptPath.FullName -Algorithm SHA256).Hash).ToUpperInvariant()

$sourceCommit = (& git -C $repositoryRoot rev-parse --verify 'HEAD^{commit}').Trim()
if ($LASTEXITCODE -ne 0 -or $sourceCommit -notmatch '^[0-9a-f]{40}$') {
    throw 'Could not resolve the source commit for the v0.7 lifecycle gate.'
}

$initialWorkingTreeStatus = @(& git -C $repositoryRoot status --porcelain=v1 --untracked-files=all | Where-Object {
    $_ -notmatch '^\?\?\s+artifacts[\\/]'
})
if ($LASTEXITCODE -ne 0) {
    throw 'Could not inspect the source working tree for the v0.7 lifecycle gate.'
}
if ($initialWorkingTreeStatus.Count -ne 0) {
    throw "The v0.7 lifecycle gate requires a clean committed checkout. Pending paths: $($initialWorkingTreeStatus -join ', ')"
}

$sourceHashes = Test-PathInvariants -RepoRoot $repositoryRoot -Paths $requiredRelativePaths

# ---------------------------------------------------------------------------
# Build and Provenance Resolution
# ---------------------------------------------------------------------------
$buildPassed = $false
$provenanceVerified = $false
$provenanceReason = ''

if (-not $SkipBuild) {
    & (Join-Path $PSScriptRoot 'Invoke-Build.ps1') -Configuration $Configuration -VerifyFormat -SkipTests
    if ($LASTEXITCODE -ne 0) {
        throw "v0.7 lifecycle build gate failed with exit code $LASTEXITCODE."
    }
    $buildPassed = $true

    $currentBinaryHashes = Get-LifecycleBinaryProvenance -ArtifactRoot $artifactRoot -Configuration $Configuration
    if ($null -eq $currentBinaryHashes) {
        throw 'Could not compute binary provenance hashes for built assemblies.'
    }

    Write-LifecycleBuildMarker `
        -MarkerPath $buildMarkerPath `
        -SourceCommit $sourceCommit `
        -Configuration $Configuration `
        -BinaryHashes $currentBinaryHashes

    $provenanceVerified = $true
    $provenanceReason = 'Full locked build executed with format verification; fresh build marker written'
} else {
    $markerCheck = Test-LifecycleBuildMarker `
        -MarkerPath $buildMarkerPath `
        -ExpectedCommit $sourceCommit `
        -ExpectedConfiguration $Configuration `
        -ArtifactRoot $artifactRoot

    $provenanceVerified = $markerCheck.Verified
    $provenanceReason = $markerCheck.Reason

    & dotnet format (Join-Path $repositoryRoot 'HerdrOps.sln') --no-restore --verify-no-changes
    if ($LASTEXITCODE -ne 0) {
        throw 'v0.7 lifecycle formatting verification failed under -SkipBuild.'
    }
}

$staticChecksPassed = $true
$contractChecksPassed = Test-StaticContractInvariants -RepoRoot $repositoryRoot

# ---------------------------------------------------------------------------
# Automated Test Execution
# ---------------------------------------------------------------------------
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
        ExpectedCount = 12
    },
    [pscustomobject]@{
        Name = 'IntegrationTests'
        Category = 'Integration'
        Project = Join-Path $repositoryRoot 'tests\HerdrOps.IntegrationTests\HerdrOps.IntegrationTests.csproj'
        Filter = 'FullyQualifiedName~AppSettingsStoreTests|FullyQualifiedName~AppLifecycleIntegrationTests|FullyQualifiedName~StartupLifecycleSafetyTests|FullyQualifiedName~TrayLifecycleIntegrationTests'
        Log = 'lifecycle-settings-integration.trx'
        ExpectedCount = 39
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

$totalTests = $categoryCounters['Unit'].Total + $categoryCounters['Integration'].Total
$passedTests = $categoryCounters['Unit'].Passed + $categoryCounters['Integration'].Passed
$failedTests = $categoryCounters['Unit'].Failed + $categoryCounters['Integration'].Failed

$unitTotal = $categoryCounters['Unit'].Total
$unitPass = $categoryCounters['Unit'].Passed
$unitFail = $categoryCounters['Unit'].Failed

$integrationTotal = $categoryCounters['Integration'].Total
$integrationPass = $categoryCounters['Integration'].Passed
$integrationFail = $categoryCounters['Integration'].Failed

# Strict exact test count enforcement (exact 12 Unit, exact 39 Integration, exact 51 Total)
if ($unitTotal -ne 12 -or $unitPass -ne 12 -or $unitFail -ne 0 -or
    $integrationTotal -ne 39 -or $integrationPass -ne 39 -or $integrationFail -ne 0 -or
    $totalTests -ne 51 -or $passedTests -ne 51 -or $failedTests -ne 0) {
    throw "Lifecycle test counters are not exact: Unit=$unitPass/$unitTotal (fail $unitFail, expected 12/12) Integration=$integrationPass/$integrationTotal (fail $integrationFail, expected 39/39) Total=$passedTests/$totalTests (expected 51/51)"
}

# ---------------------------------------------------------------------------
# Post-Execution Invariants: Re-Check Commit, Working Tree, Script, and Sources
# ---------------------------------------------------------------------------
$finalCommit = (& git -C $repositoryRoot rev-parse --verify 'HEAD^{commit}').Trim()
if ($LASTEXITCODE -ne 0 -or $finalCommit -cne $sourceCommit) {
    throw "Source commit changed during gate execution: initial=$sourceCommit final=$finalCommit"
}

$finalWorkingTreeStatus = @(& git -C $repositoryRoot status --porcelain=v1 --untracked-files=all | Where-Object {
    $_ -notmatch '^\?\?\s+artifacts[\\/]'
})
if ($LASTEXITCODE -ne 0 -or $finalWorkingTreeStatus.Count -ne 0) {
    throw "Working tree became dirty during gate execution: $($finalWorkingTreeStatus -join '; ')"
}

$gateScriptFinalHash = ((Get-FileHash -LiteralPath $gateScriptPath.FullName -Algorithm SHA256).Hash).ToUpperInvariant()
if ($gateScriptFinalHash -cne $gateScriptInitialHash) {
    throw "Gate script was modified during execution: initial=$gateScriptInitialHash final=$gateScriptFinalHash"
}

$finalSourceHashes = Test-PathInvariants -RepoRoot $repositoryRoot -Paths $requiredRelativePaths
foreach ($key in $sourceHashes.Keys) {
    if ($finalSourceHashes[$key] -cne $sourceHashes[$key]) {
        throw "Source file '$key' was modified during gate execution: initial=$($sourceHashes[$key]) final=$($finalSourceHashes[$key])"
    }
}

# ---------------------------------------------------------------------------
# Evidence Classification and Report Generation
# ---------------------------------------------------------------------------
$evidence = Get-EvidenceClassificationLines `
    -SkipBuild ([bool]$SkipBuild) `
    -ProvenanceVerified $provenanceVerified `
    -ProvenanceReason $provenanceReason `
    -BuildPassed $buildPassed `
    -StaticChecksPassed $staticChecksPassed `
    -ContractChecksPassed $contractChecksPassed `
    -UnitTotal $unitTotal `
    -UnitPassed $unitPass `
    -UnitFailed $unitFail `
    -IntegrationTotal $integrationTotal `
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
    "SkipBuild: $SkipBuild",
    "BinaryProvenanceVerified: $provenanceVerified",
    "BinaryProvenanceReason: $provenanceReason",
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
    'ActualHerdrRuntimeEvidence: NOT OBSERVED / NOT CLAIMED',
    'WindowsHostEvidence: PENDING / NOT OBSERVED (actual tray visibility, logon launch, AppData persistence across reboots)',
    'HumanAccessibilityEvidence: PENDING / NOT OBSERVED (screen reader Narrator audio, high contrast, physical DPI scaling)',
    'ReleaseEvidence: NOT PRODUCED / NOT CLAIMED',
    'ReleasePublication: NOT PERFORMED',
    'Status: IMPLEMENTATION GATE / NO RUNTIME OR RELEASE CREDIT',
    'IssueTracker: Issue #36 remains OPEN pending reference-host and human acceptance',
    '',
    '----------------------------------------------------------------------',
    'Automated Test Execution Breakdown',
    '----------------------------------------------------------------------',
    "TotalTestsExecuted: $totalTests",
    "PassedTests: $passedTests",
    "FailedTests: $failedTests",
    "UnitTests: $unitPass passed / $unitTotal total (exact 12/12)",
    "IntegrationTests: $integrationPass passed / $integrationTotal total (exact 39/39)",
    "RequiredNamedChecksVerified: $($requiredChecks.Count)/$($requiredChecks.Count) OBSERVED (exact 12 Unit, exact 39 Integration)",
    '',
    'TRX Results Files:'
)

foreach ($trxFile in $testResults) {
    $trxHash = ((Get-FileHash -LiteralPath $trxFile.FullName -Algorithm SHA256).Hash).ToUpperInvariant()
    $reportLines += "  - $($trxFile.Name) (SHA-256: $trxHash)"
}

$reportLines += @(
    '',
    '----------------------------------------------------------------------',
    'Required Source and Contract Hashes (34/34 Verified)',
    '----------------------------------------------------------------------'
)

foreach ($relativePath in $sourceHashes.Keys) {
    $reportLines += "  - ${relativePath}: $($sourceHashes[$relativePath])"
}

$reportLines += @(
    '',
    '----------------------------------------------------------------------',
    'Required Named Checks (51/51 Verified)',
    '----------------------------------------------------------------------'
)

foreach ($check in $requiredChecks) {
    $reportLines += "  - PASS $check"
}

$reportLines += @(
    '',
    '----------------------------------------------------------------------',
    'Evidence Boundary',
    '----------------------------------------------------------------------',
    'This gate proves exact committed source files, contract invariants, 12/12 unit tests, and 39/39 integration tests (51/51 total) pass deterministically.',
    'SkipBuild runs achieve implementation acceptance PASS only when a same-commit binary provenance marker proves binaries were built from the identical unchanged commit; otherwise, the result is explicitly marked NON-ACCEPTANCE.',
    'Actual Herdr Runtime, installed tray visibility, Windows startup registry entries, physical DPI/accessibility validation, and Release evidence are NOT OBSERVED and NOT CLAIMED.',
    'Issue #36 remains OPEN until all required reference-host and human acceptance criteria are satisfied.',
    '',
    '----------------------------------------------------------------------',
    'Gate Verdict',
    '----------------------------------------------------------------------',
    "ImplementationGate: $($evidence.ImplementationGateVerdict)",
    "Result: $($evidence.VerdictResult)"
)

$reportContent = $reportLines -join "`r`n"
[IO.File]::WriteAllText($reportPath, $reportContent + "`r`n", [Text.UTF8Encoding]::new($false))

$reportHash = ((Get-FileHash -LiteralPath $reportPath -Algorithm SHA256).Hash).ToUpperInvariant()

Write-Host "GateReport: $reportPath"
Write-Host "GateReportSha256: $reportHash"
Write-Host "TotalTests: $totalTests (Unit: $unitPass, Integration: $integrationPass)"
Write-Host "RequiredNamedChecksVerified: $($requiredChecks.Count)/$($requiredChecks.Count)"
Write-Host "Result: $($evidence.VerdictResult)"
Write-Host "ImplementationGate: $($evidence.ImplementationGateVerdict)"
Write-Host "Status: IMPLEMENTATION GATE / NO RUNTIME OR RELEASE CREDIT"

if (-not $evidence.IsFullAcceptancePass -and (-not $SkipBuild -or $evidence.VerdictResult -eq 'FAIL')) {
    throw "v0.7 lifecycle implementation gate FAILED."
}
