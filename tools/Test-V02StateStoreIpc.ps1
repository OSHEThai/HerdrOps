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
$testResultRoot = Join-Path $artifactRoot 'test-results'

if (-not $SkipBuild) {
    & (Join-Path $PSScriptRoot 'Invoke-Build.ps1') -Configuration $Configuration -VerifyFormat
    if ($LASTEXITCODE -ne 0) {
        throw "v0.2 state-store/IPC build gate failed with exit code $LASTEXITCODE."
    }
}

$testResults = @(Get-ChildItem -LiteralPath $testResultRoot -Filter '*.trx' -File |
    Sort-Object LastWriteTimeUtc -Descending |
    Select-Object -First 4)
if ($testResults.Count -lt 4) {
    throw "Expected TRX output from four test projects, found $($testResults.Count)."
}

$combinedTestLog = ($testResults | ForEach-Object {
    Get-Content -LiteralPath $_.FullName -Raw
}) -join "`n"
$requiredChecks = @(
    'SQLiteProviderIsOwnedOnlyByInfrastructure',
    'LengthPrefixedEnvelopeRoundTripsWithStrictHeader',
    'StrictJsonRejectsUnmappedEnvelopeAndPayloadMembers',
    'DeltaReducerAppliesOnlyContiguousHashBoundState',
    'RestoredCountersContinueOnFirstBootstrapAfterCoreRestart',
    'WalStoreSurvivesRestartWithExactAcceptedState',
    'ExistingVersionZeroDatabaseIsBackedUpBeforeMigration',
    'FutureSchemaFailsClosedWithoutMigration',
    'EventLedgerRejectsMutation',
    'SecondCoreStoreInstanceFailsUntilOwnerDisposes',
    'CoordinatorRestoresStateAndContinuesSequenceAfterCoreRestart',
    'AppReceivesFullSnapshotThenOrderedDeltas',
    'ServerRejectsInvalidProtocolVersionBeforeSnapshot',
    'ServerRejectsUnauthorizedClientRoleBeforeSnapshot',
    'ProductionPipeEndpointsRequireCurrentUserOnly',
    'OversizedInitialSnapshotFailsBeforeServerStarts',
    'ClientLimitWaitsForCapacityWithoutStoppingServer',
    'ServiceKeepsPipeAliveUntilCoreCancellation',
    'ServiceCommandRejectsMissingHerdrWithNonZeroResult',
    'WidgetGalleryExposesKeyboardFocusAndAccessibleOpenActions'
)
foreach ($check in $requiredChecks) {
    if ($combinedTestLog -notmatch [Regex]::Escape($check)) {
        throw "Required v0.2 state-store/IPC check is absent from the test log: $check"
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
if ($totalTests -le 0 -or $failedTests -ne 0 -or $totalTests -ne $passedTests) {
    throw "Test counters are not all passing: total=$totalTests passed=$passedTests failed=$failedTests"
}

$infrastructureLockPath = Join-Path $repositoryRoot 'src\HerdrOps.Infrastructure\packages.lock.json'
$infrastructureLock = Get-Content -LiteralPath $infrastructureLockPath -Raw | ConvertFrom-Json -Depth 64
$targetFramework = @($infrastructureLock.dependencies.PSObject.Properties)[0].Value
$sqliteProvider = $targetFramework.'Microsoft.Data.Sqlite'
$sqliteBundle = $targetFramework.'SQLitePCLRaw.bundle_e_sqlite3'
$sqliteNative = $targetFramework.'SQLitePCLRaw.lib.e_sqlite3'
if ($sqliteProvider.resolved -ne '10.0.11') {
    throw "Unexpected Microsoft.Data.Sqlite version: $($sqliteProvider.resolved)"
}
if ($sqliteBundle.resolved -ne '2.1.12' -or $sqliteNative.resolved -ne '2.1.12') {
    throw "Unexpected patched SQLitePCLRaw versions: bundle=$($sqliteBundle.resolved) native=$($sqliteNative.resolved)"
}

$forbiddenProjects = @('HerdrOps.App', 'HerdrOps.Cli')
foreach ($projectName in $forbiddenProjects) {
    $projectRoot = Join-Path $repositoryRoot "src\$projectName"
    $forbiddenHits = @(Get-ChildItem -LiteralPath $projectRoot -Recurse -File -Include '*.cs', '*.csproj' |
        Select-String -SimpleMatch -Pattern 'Microsoft.Data.Sqlite', 'SqliteConnection')
    if ($forbiddenHits.Count -ne 0) {
        throw "$projectName contains forbidden direct SQLite access: $($forbiddenHits.Path -join ', ')"
    }
}

$vulnerabilityOutput = @(& dotnet list `
    (Join-Path $repositoryRoot 'src\HerdrOps.Infrastructure\HerdrOps.Infrastructure.csproj') `
    package --include-transitive --vulnerable 2>&1)
if ($LASTEXITCODE -ne 0) {
    throw "NuGet vulnerability audit failed: $($vulnerabilityOutput -join [Environment]::NewLine)"
}
if (($vulnerabilityOutput -join "`n") -notmatch 'no vulnerable packages') {
    throw "NuGet vulnerability audit did not report a clean dependency graph: $($vulnerabilityOutput -join [Environment]::NewLine)"
}

$gateDirectory = Join-Path $artifactRoot 'release-gates\v0.2.0\issue-8'
New-Item -ItemType Directory -Path $gateDirectory -Force | Out-Null
$reportPath = Join-Path $gateDirectory 'gate-report.txt'
$commit = (& git -C $repositoryRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($commit)) {
    throw 'Could not resolve the source commit for the v0.2 state-store/IPC gate.'
}

$report = @(
    'HerdrOps v0.2 Issue #8 State Store and IPC Gate',
    "GeneratedUtc: $([DateTime]::UtcNow.ToString('O'))",
    "Commit: $commit",
    'Result: PASS',
    'EvidenceClass: Contract plus Integration',
    'ActualHerdrRuntime: NOT OBSERVED / NOT CLAIMED',
    "Tests: $passedTests/$totalTests PASS",
    "Microsoft.Data.Sqlite: $($sqliteProvider.resolved)",
    "SQLitePCLRaw.bundle_e_sqlite3: $($sqliteBundle.resolved)",
    "SQLitePCLRaw.lib.e_sqlite3: $($sqliteNative.resolved)",
    'NuGetVulnerabilityAudit: PASS',
    'SQLiteOwner: HerdrOps.Infrastructure only',
    'CoreToAppPipeAuthorization: PipeOptions.CurrentUserOnly',
    'WireProtocol: v1 length-prefixed strict JSON, snapshot then contiguous deltas',
    '',
    'RequiredChecks:'
) + ($requiredChecks | ForEach-Object { "PASS $_" }) + @(
    '',
    'EvidenceBoundary:',
    'This gate proves deterministic migration/restart behavior, exact dependency locks, same-user Windows pipe transport, protocol rejection, and architecture boundaries.',
    'It does not prove cross-account runtime isolation, actual Herdr operation, package installation, or v0.2 release readiness.'
)
$report | Set-Content -LiteralPath $reportPath -Encoding utf8
$report | Write-Output
Write-Output "GateReport: $reportPath"
