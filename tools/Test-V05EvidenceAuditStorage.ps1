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
$domainContractPath = Join-Path $repositoryRoot 'src\HerdrOps.Domain\Evidence\EvidenceContracts.cs'
$storeCorePath = Join-Path $repositoryRoot 'src\HerdrOps.Infrastructure\Storage\SqliteHerdrStateStore.cs'
$storagePath = Join-Path $repositoryRoot 'src\HerdrOps.Infrastructure\Storage\SqliteHerdrStateStore.Evidence.cs'
$migrationPath = Join-Path $repositoryRoot 'src\HerdrOps.Infrastructure\Storage\SqliteHerdrStateStore.EvidenceMigration.cs'
$contractPath = Join-Path $repositoryRoot 'docs\protocol\v0.5-evidence-audit-storage-contract.md'
$expectedDomainContractSha256 = 'E6F5AE4E3AE96AF5A83B5D8C5E9FF4C432DA1CD727824B93121E8E39B79B3E06'
$expectedStoreCoreSha256 = '5F13130BC1B9F4AAE6674DA6CC7FF7A66868E15A82E86AA15EA12D1271D079C2'
$expectedStorageSha256 = '5A6AF41A731C4E0100F909AD3BEEA615729B422555A10FFA7AF463FC49A4D30C'
$expectedMigrationSha256 = 'EE69EA92BC458DDD61214A90CC7EEEF08BB5B2D03FFDC24FDE6103A74C5D1E47'
$expectedContractSha256 = '9D3FDA5DEB53274AB70458B14C09162290788813CAC6FA67366F27E33508819E'

$workingTreeStatus = @(& git -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0) {
    throw 'Could not inspect the source working tree for the v0.5 evidence/audit gate.'
}
if ($workingTreeStatus.Count -ne 0) {
    throw "The v0.5 evidence/audit gate requires a clean committed checkout. Pending paths: $($workingTreeStatus -join ', ')"
}

if (-not $SkipBuild) {
    & (Join-Path $PSScriptRoot 'Invoke-Build.ps1') -Configuration $Configuration -VerifyFormat
    if ($LASTEXITCODE -ne 0) {
        throw "v0.5 evidence/audit build gate failed with exit code $LASTEXITCODE."
    }
}

$requiredFiles = @($domainContractPath, $storeCorePath, $storagePath, $migrationPath, $contractPath)
foreach ($requiredFile in $requiredFiles) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
        throw "Required v0.5 evidence/audit contract file was not found: $requiredFile"
    }
}

$actualHashes = [ordered]@{
    DomainContract = (Get-FileHash -LiteralPath $domainContractPath -Algorithm SHA256).Hash
    StoreCore = (Get-FileHash -LiteralPath $storeCorePath -Algorithm SHA256).Hash
    Storage = (Get-FileHash -LiteralPath $storagePath -Algorithm SHA256).Hash
    Migration = (Get-FileHash -LiteralPath $migrationPath -Algorithm SHA256).Hash
    Contract = (Get-FileHash -LiteralPath $contractPath -Algorithm SHA256).Hash
}
$expectedHashes = [ordered]@{
    DomainContract = $expectedDomainContractSha256
    StoreCore = $expectedStoreCoreSha256
    Storage = $expectedStorageSha256
    Migration = $expectedMigrationSha256
    Contract = $expectedContractSha256
}
foreach ($entry in $expectedHashes.GetEnumerator()) {
    if ($actualHashes[$entry.Key] -ne $entry.Value) {
        throw "v0.5 evidence/audit $($entry.Key) SHA-256 drifted: expected $($entry.Value) observed $($actualHashes[$entry.Key])"
    }
}

$runId = "$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ', [Globalization.CultureInfo]::InvariantCulture))-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
$gateDirectory = Join-Path $artifactRoot "release-gates\v0.5.0\issue-25\$runId"
$testResultDirectory = Join-Path $gateDirectory 'test-results'
New-Item -ItemType Directory -Path $testResultDirectory -Force | Out-Null

$testProjects = @(
    (Join-Path $repositoryRoot 'tests\HerdrOps.UnitTests\HerdrOps.UnitTests.csproj'),
    (Join-Path $repositoryRoot 'tests\HerdrOps.IntegrationTests\HerdrOps.IntegrationTests.csproj')
)
foreach ($testProject in $testProjects) {
    & dotnet test $testProject `
        --configuration $Configuration `
        --no-restore `
        --no-build `
        --artifacts-path $artifactRoot `
        --results-directory $testResultDirectory `
        --logger trx
    if ($LASTEXITCODE -ne 0) {
        throw "v0.5 evidence/audit tests failed: $testProject"
    }
}

$testResults = @(Get-ChildItem -LiteralPath $testResultDirectory -Filter '*.trx' -File)
if ($testResults.Count -ne 2) {
    throw "Expected exactly 2 fresh evidence/audit TRX files, found $($testResults.Count)."
}

$combinedTestLog = ($testResults | ForEach-Object {
    Get-Content -LiteralPath $_.FullName -Raw
}) -join "`n"
$requiredChecks = @(
    'ChangedContentProducesDifferentEvidenceIdentity',
    'MissingArtifactHasExplicitNullContentAndExternalStorage',
    'EvidenceMetadataRejectsTamperedCanonicalHash',
    'ManagedEvidencePathRejectsControlAndReservedCharacters',
    'ReviewAuditNormalizesEvidenceOrderAndChainsHashes',
    'ReviewAuditRejectsDuplicateEvidenceIdentity',
    'SchemaVersionThreeCreatesExactImmutableEvidenceLedgers',
    'ChangedBytesProduceDifferentIdentityAndManagedBytesStayOutsideSqlite',
    'MissingArtifactIsExplicitAndCaptureIsIdempotent',
    'UnicodeTaskAndReviewIdentifiersRoundTripThroughStorage',
    'ReviewHistoryIsHashChainedAndRejectsOrdinaryMutation',
    'RetentionProtectsOpenReviewThenPurgesBytesAndPreservesHistory',
    'FailedRetentionAuditWriteLeavesRecoverableBytesAndRetryCompletes',
    'CommittedRetentionAuditWithPendingBytesRecoversCleanup',
    'ManagedEvidenceDirectoryMasqueradeFailsClosedOnRead',
    'ManagedEvidenceIntermediateFileMasqueradeFailsClosedOnRead',
    'ManagedVaultRejectsReparsePointAncestorBeforeCreatingVault',
    'ManagedByteTamperingFailsClosedOnRead',
    'VersionOneDatabaseMigratesForwardWithoutLosingHistory',
    'FailedVersionThreeMigrationRollsBackAllPartialChanges',
    'FutureSchemaFailsClosedWithoutMigration'
)
foreach ($check in $requiredChecks) {
    if ($combinedTestLog -notmatch [Regex]::Escape($check)) {
        throw "Required v0.5 evidence/audit check is absent from fresh test logs: $check"
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
    throw "Evidence/audit test counters are not all passing: total=$totalTests passed=$passedTests failed=$failedTests"
}

$sourceCommit = (& git -C $repositoryRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($sourceCommit)) {
    throw 'Could not resolve the source commit for the v0.5 evidence/audit gate.'
}

$gateReportPath = Join-Path $gateDirectory 'gate-report.txt'
$gateReport = @(
    'HerdrOps v0.5 Issue #25 Evidence Metadata and Audit Storage Gate',
    "GeneratedUtc: $([DateTime]::UtcNow.ToString('O'))",
    "SourceCommit: $sourceCommit",
    'Result: IMPLEMENTATION READY',
    'ImplementationGate: PASS',
    'IssueAcceptance: PENDING INDEPENDENT REVIEW',
    'VersionReleaseGate: PENDING',
    'EvidenceClass: Contract plus local SQLite Integration',
    'ActualHerdrRuntime: NOT OBSERVED / NOT CLAIMED',
    'RoleAuthorization: NOT IMPLEMENTED IN ISSUE #25',
    'ComplianceQueueUi: NOT IMPLEMENTED IN ISSUE #25',
    'RealDataRedaction: NOT OBSERVED / NOT CLAIMED',
    'InstalledRetentionRuntime: NOT OBSERVED / NOT CLAIMED',
    'SchemaVersion: 3',
    'ManagedArtifactBytes: OUTSIDE SQLITE',
    'ReviewAudit: APPEND-ONLY HASH CHAIN',
    'OpenReviewRetentionProtection: SYNTHETICALLY VERIFIED',
    "Tests: $passedTests/$totalTests PASS",
    "DomainContractSha256: $($actualHashes.DomainContract)",
    "StoreCoreSha256: $($actualHashes.StoreCore)",
    "StorageSha256: $($actualHashes.Storage)",
    "MigrationSha256: $($actualHashes.Migration)",
    "ContractSha256: $($actualHashes.Contract)",
    '',
    'Non-authority boundary:',
    'This gate does not authorize a reviewer, confirm or dismiss incidents, prove Compliance Queue rendering, verify source-reference redaction against real data, operate Herdr, prove installed-product retention, provide independent acceptance, or pass the v0.5 release gate.'
)
[System.IO.File]::WriteAllLines(
    $gateReportPath,
    $gateReport,
    [System.Text.UTF8Encoding]::new($false))

Write-Host "v0.5 evidence/audit implementation gate passed: $passedTests/$totalTests tests."
Write-Host "Gate report: $gateReportPath"
