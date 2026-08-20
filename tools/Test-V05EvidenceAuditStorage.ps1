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
$domainContractPath = Join-Path $repositoryRoot 'src\HerdrOps.Domain\Evidence\EvidenceContracts.cs'
$storeCorePath = Join-Path $repositoryRoot 'src\HerdrOps.Infrastructure\Storage\SqliteHerdrStateStore.cs'
$storeModelsPath = Join-Path $repositoryRoot 'src\HerdrOps.Infrastructure\Storage\HerdrStateStoreModels.cs'
$storagePath = Join-Path $repositoryRoot 'src\HerdrOps.Infrastructure\Storage\SqliteHerdrStateStore.Evidence.cs'
$migrationPath = Join-Path $repositoryRoot 'src\HerdrOps.Infrastructure\Storage\SqliteHerdrStateStore.EvidenceMigration.cs'
$contractPath = Join-Path $repositoryRoot 'docs\protocol\v0.5-evidence-audit-storage-contract.md'
# The v0.5 projection pin is the original reviewed EvidenceContracts.cs bytes.
# Issue #43 extends that file with exactly four reviewed retention hunks; the
# projection strips only those hunks and must reproduce this original pin, and
# the hunks themselves are bound by their own SHA-256 below.
$expectedDomainContractProjectionSha256 = 'E6F5AE4E3AE96AF5A83B5D8C5E9FF4C432DA1CD727824B93121E8E39B79B3E06'
$expectedDomainContractExtensionSha256 = '86285594E06404570995086185CCB33E9EB2A530159EAA6B777175E312A11425'
$expectedStoreCoreV3ProjectionSha256 = '9D8CCF4690F5D1CAC445A3EC0A6CEBDEC06D9A29DAB6A608DD3AC6D75951163D'
$expectedStorageSha256 = '5A6AF41A731C4E0100F909AD3BEEA615729B422555A10FFA7AF463FC49A4D30C'
$expectedMigrationSha256 = 'EE69EA92BC458DDD61214A90CC7EEEF08BB5B2D03FFDC24FDE6103A74C5D1E47'
$expectedContractSha256 = 'F0F236D957C637509129DC05E644D99C3B0E87FDF97D3B11775ED26B254A32B3'

function Get-CleanCheckoutStatus {
    $status = @(& git -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not inspect the source working tree for the v0.5 evidence/audit gate.'
    }

    return $status
}

function Assert-CleanCommittedCheckout {
    $status = @(Get-CleanCheckoutStatus)
    if ($status.Count -ne 0) {
        throw "The v0.5 evidence/audit gate requires a clean committed checkout. Pending paths: $($status -join ', ')"
    }

    $commit = (& git -C $repositoryRoot rev-parse --verify 'HEAD^{commit}').Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($commit)) {
        throw 'The v0.5 evidence/audit gate requires a committed HEAD.'
    }

    return $commit
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

function Get-TextSha256 {
    param(
        [Parameter(Mandatory)]
        [string]$Text
    )

    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        return [BitConverter]::ToString(
            $sha256.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))).Replace('-', '')
    }
    finally {
        $sha256.Dispose()
    }
}

function Get-StoreCoreIdentity {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$V4AllowlistPattern
    )

    $source = [IO.File]::ReadAllText($Path)
    $matches = [Regex]::Matches($source, $V4AllowlistPattern)
    if ($matches.Count -ne 1) {
        throw "The StoreCore forward-extension allowlist expected exactly one v4 migration arm, found $($matches.Count)."
    }

    $projection = [Regex]::Replace($source, $V4AllowlistPattern, '')
    return [pscustomobject]@{
        ProjectionSha256 = Get-TextSha256 -Text $projection
        V4RegistrationSha256 = Get-TextSha256 -Text $matches[0].Value
    }
}

# Reviewed Issue #43 forward-extension projection for the v0.5 evidence domain
# contract. Issue #43 extends EvidenceContracts.cs with exactly four retention
# hunks: a nullable RetainUntilUtc capture field, two `!.Value` dereference
# sites, and the EvidenceRetentionPolicy.ResolveRetainUntil call. The projection
# strips ONLY those hunks and must reproduce the original v0.5 bytes; each hunk
# is required exactly once and the hunks are bound by their own SHA-256, so
# unrelated drift, a substituted extension, or a duplicate hunk fails closed.
$domainContractNullableRetainUntilPattern = 'DateTimeOffset\? RetainUntilUtc,'
$domainContractNormalizedValuePattern = 'normalizedRequest\.RetainUntilUtc!\.Value,'
$domainContractResolveRetainUntilPattern = 'var retainUntilUtc = EvidenceRetentionPolicy\.ResolveRetainUntil\((\r?\n)(\s+)observedUtc,(\r?\n)(\s+)request\.RetainUntilUtc\);'
$domainContractMetadataValuePattern = 'RetainUntilUtc = request\.RetainUntilUtc!\.Value,'

function Get-EvidenceDomainContractIdentity {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $source = [IO.File]::ReadAllText($Path)
    $hunkCounts = @(
        [Regex]::Matches($source, $domainContractNullableRetainUntilPattern).Count,
        [Regex]::Matches($source, $domainContractNormalizedValuePattern).Count,
        [Regex]::Matches($source, $domainContractResolveRetainUntilPattern).Count,
        [Regex]::Matches($source, $domainContractMetadataValuePattern).Count
    )
    foreach ($count in $hunkCounts) {
        if ($count -ne 1) {
            throw "The Issue #43 retention forward-extension must contain exactly one reviewed hunk, found $count."
        }
    }

    $extensionHunks = @(
        [Regex]::Match($source, $domainContractNullableRetainUntilPattern).Value,
        [Regex]::Match($source, $domainContractNormalizedValuePattern).Value,
        [Regex]::Match($source, $domainContractResolveRetainUntilPattern).Value,
        [Regex]::Match($source, $domainContractMetadataValuePattern).Value
    )
    $projection = [Regex]::Replace($source, $domainContractNullableRetainUntilPattern, 'DateTimeOffset RetainUntilUtc,')
    $projection = [Regex]::Replace($projection, $domainContractNormalizedValuePattern, 'normalizedRequest.RetainUntilUtc,')
    $projection = [Regex]::Replace(
        $projection,
        $domainContractResolveRetainUntilPattern,
        'var retainUntilUtc = EvidenceContractNormalization.EnsureUtc($1$2request.RetainUntilUtc,$3$4nameof(request.RetainUntilUtc));')
    $projection = [Regex]::Replace($projection, $domainContractMetadataValuePattern, 'RetainUntilUtc = request.RetainUntilUtc,')

    return [pscustomobject]@{
        ProjectionSha256 = Get-TextSha256 -Text $projection
        ExtensionSha256 = Get-TextSha256 -Text ($extensionHunks -join '')
    }
}

if ($SelfTest) {
    $realSource = [IO.File]::ReadAllText($domainContractPath)
    $realIdentity = Get-EvidenceDomainContractIdentity -Path $domainContractPath
    $fixtureFailures = @()

    # Positive control: the committed file must reproduce the reviewed v0.5
    # projection and bind the reviewed Issue #43 extension identity.
    if ($realIdentity.ProjectionSha256 -cne $expectedDomainContractProjectionSha256) {
        $fixtureFailures += 'positive-control projection drift'
    }
    if ($realIdentity.ExtensionSha256 -cne $expectedDomainContractExtensionSha256) {
        $fixtureFailures += 'positive-control extension drift'
    }

    # Hostile: unrelated drift anywhere in the file must change the projection.
    $unrelatedDrift = $realSource.Replace('bool CreateManagedCopy);', 'bool CreateManagedCopy); ')
    if ($unrelatedDrift -ceq $realSource) {
        $fixtureFailures += 'hostile fixture could not inject unrelated drift'
    } else {
        $driftPath = Join-Path $env:TEMP ("evidence-drift-" + [Guid]::NewGuid().ToString('N') + '.cs')
        try {
            [IO.File]::WriteAllText($driftPath, $unrelatedDrift, [Text.UTF8Encoding]::new($false))
            $driftIdentity = Get-EvidenceDomainContractIdentity -Path $driftPath
            if ($driftIdentity.ProjectionSha256 -ceq $expectedDomainContractProjectionSha256) {
                $fixtureFailures += 'unrelated drift did not change the projection hash'
            }
        } finally {
            if (Test-Path -LiteralPath $driftPath) { Remove-Item -LiteralPath $driftPath -Force }
        }
    }

    # Hostile: removing the extension (reverting to the original v0.5 bytes)
    # must fail closed because a required reviewed hunk is missing.
    $reverted = $realSource
    $reverted = [Regex]::Replace($reverted, $domainContractNullableRetainUntilPattern, 'DateTimeOffset RetainUntilUtc,')
    $reverted = [Regex]::Replace($reverted, $domainContractNormalizedValuePattern, 'normalizedRequest.RetainUntilUtc,')
    $reverted = [Regex]::Replace(
        $reverted,
        $domainContractResolveRetainUntilPattern,
        'var retainUntilUtc = EvidenceContractNormalization.EnsureUtc($1$2request.RetainUntilUtc,$3$4nameof(request.RetainUntilUtc));')
    $reverted = [Regex]::Replace($reverted, $domainContractMetadataValuePattern, 'RetainUntilUtc = request.RetainUntilUtc,')
    $revertPath = Join-Path $env:TEMP ("evidence-revert-" + [Guid]::NewGuid().ToString('N') + '.cs')
    try {
        [IO.File]::WriteAllText($revertPath, $reverted, [Text.UTF8Encoding]::new($false))
        try {
            Get-EvidenceDomainContractIdentity -Path $revertPath | Out-Null
            $fixtureFailures += 'removed extension hunks did not fail closed'
        } catch {
            # Expected: the identity binding rejects a missing reviewed hunk.
        }
    } finally {
        if (Test-Path -LiteralPath $revertPath) { Remove-Item -LiteralPath $revertPath -Force }
    }

    # Hostile: substituting a different retention call must fail closed because
    # the exact reviewed hunk text is required.
    $altered = $realSource.Replace(
        'var retainUntilUtc = EvidenceRetentionPolicy.ResolveRetainUntil(',
        'var retainUntilUtc = EvidenceRetentionPolicy.ResolveRetainUntil2(')
    if ($altered -ceq $realSource) {
        $fixtureFailures += 'hostile fixture could not inject extension substitution'
    } else {
        $alterPath = Join-Path $env:TEMP ("evidence-alter-" + [Guid]::NewGuid().ToString('N') + '.cs')
        try {
            [IO.File]::WriteAllText($alterPath, $altered, [Text.UTF8Encoding]::new($false))
            try {
                Get-EvidenceDomainContractIdentity -Path $alterPath | Out-Null
                $fixtureFailures += 'substituted extension hunk did not fail closed'
            } catch {
                # Expected: the exact reviewed hunk text is required.
            }
        } finally {
            if (Test-Path -LiteralPath $alterPath) { Remove-Item -LiteralPath $alterPath -Force }
        }
    }

    # Hostile: duplicating an extension hunk must fail closed on the exact-one count.
    $duplicated = $realSource.Replace(
        'RetainUntilUtc = request.RetainUntilUtc!.Value,',
        'RetainUntilUtc = request.RetainUntilUtc!.Value,`r`n            RetainUntilUtc = request.RetainUntilUtc!.Value,')
    if ($duplicated -ceq $realSource) {
        $fixtureFailures += 'hostile fixture could not inject duplicate hunk'
    } else {
        $duplicatePath = Join-Path $env:TEMP ("evidence-duplicate-" + [Guid]::NewGuid().ToString('N') + '.cs')
        try {
            [IO.File]::WriteAllText($duplicatePath, $duplicated, [Text.UTF8Encoding]::new($false))
            try {
                Get-EvidenceDomainContractIdentity -Path $duplicatePath | Out-Null
                $fixtureFailures += 'duplicate extension hunk did not fail closed'
            } catch {
                # Expected: exactly one reviewed hunk is required.
            }
        } finally {
            if (Test-Path -LiteralPath $duplicatePath) { Remove-Item -LiteralPath $duplicatePath -Force }
        }
    }

    if ($fixtureFailures.Count -gt 0) {
        throw "v0.5 evidence/audit forward-extension self-tests failed: $($fixtureFailures -join '; ')"
    }
    Write-Host 'v0.5 evidence/audit forward-extension hostile self-tests: PASS'
    return
}

$sourceCommit = Assert-CleanCommittedCheckout

if (-not $SkipBuild) {
    & (Join-Path $PSScriptRoot 'Invoke-Build.ps1') -Configuration $Configuration -VerifyFormat
    if ($LASTEXITCODE -ne 0) {
        throw "v0.5 evidence/audit build gate failed with exit code $LASTEXITCODE."
    }
}

$retentionPolicyPath = Join-Path $repositoryRoot 'src\HerdrOps.Domain\Evidence\EvidenceRetentionPolicy.cs'
$requiredFiles = @($domainContractPath, $storeCorePath, $storeModelsPath, $storagePath, $migrationPath, $contractPath, $retentionPolicyPath)
foreach ($requiredFile in $requiredFiles) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
        throw "Required v0.5 evidence/audit contract file was not found: $requiredFile"
    }
}

$v4AllowlistPattern = '(?ms)^        4 => new MigrationDefinition\(\r?\n            4,\r?\n            ComplianceReviewMigrationName,\r?\n            ComplianceReviewMigrationSql,\r?\n            ComputeMigrationSha256\(ComplianceReviewMigrationSql\)\),\r?\n'
$storeCoreIdentity = Get-StoreCoreIdentity -Path $storeCorePath -V4AllowlistPattern $v4AllowlistPattern
$storeCoreV3ProjectionSha256 = $storeCoreIdentity.ProjectionSha256
$v4RegistrationSha256 = $storeCoreIdentity.V4RegistrationSha256

$domainContractIdentity = Get-EvidenceDomainContractIdentity -Path $domainContractPath
$actualHashes = [ordered]@{
    DomainContractProjection = $domainContractIdentity.ProjectionSha256
    DomainContractExtension = $domainContractIdentity.ExtensionSha256
    StoreCore = (Get-FileHash -LiteralPath $storeCorePath -Algorithm SHA256).Hash
    StoreCoreV3Projection = $storeCoreV3ProjectionSha256
    Storage = (Get-FileHash -LiteralPath $storagePath -Algorithm SHA256).Hash
    Migration = (Get-FileHash -LiteralPath $migrationPath -Algorithm SHA256).Hash
    Contract = (Get-FileHash -LiteralPath $contractPath -Algorithm SHA256).Hash
}
$expectedHashes = [ordered]@{
    DomainContractProjection = $expectedDomainContractProjectionSha256
    DomainContractExtension = $expectedDomainContractExtensionSha256
    StoreCoreV3Projection = $expectedStoreCoreV3ProjectionSha256
    Storage = $expectedStorageSha256
    Migration = $expectedMigrationSha256
    Contract = $expectedContractSha256
}

$storeModelsSource = Get-Content -LiteralPath $storeModelsPath -Raw
$schemaMatch = [Regex]::Match(
    $storeModelsSource,
    'CurrentSchemaVersion\s*=\s*(?<version>\d+)')
if (-not $schemaMatch.Success) {
    throw 'Could not resolve the current forward SQLite schema version.'
}
$currentSchemaVersion = [int]$schemaMatch.Groups['version'].Value
if ($currentSchemaVersion -lt 3) {
    throw "The current schema v$currentSchemaVersion regressed below the Issue #25 evidence foundation v3."
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
foreach ($trxFile in $testResults) {
    [xml]$trx = Get-Content -LiteralPath $trxFile.FullName -Raw
    $counters = $trx.TestRun.ResultSummary.Counters
    if ($null -eq $counters) {
        throw "TRX result has no ResultSummary.Counters element: $($trxFile.FullName)"
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
        throw "Evidence/audit $($trxFile.Name) TRX counters are not an exact all-pass result: $($values | Out-String)"
    }

    $testCounterEvidence += [pscustomobject]@{
        Name = $trxFile.Name
        Path = $trxFile.FullName
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
    throw "Evidence/audit aggregate TRX counters are not an exact all-pass result: $($aggregateCounters | Out-String)"
}

$finalStatus = @(Get-CleanCheckoutStatus)
$finalCommit = (& git -C $repositoryRoot rev-parse --verify 'HEAD^{commit}').Trim()
if ($LASTEXITCODE -ne 0 -or $finalCommit -ne $sourceCommit -or $finalStatus.Count -ne 0) {
    throw 'The source commit or clean-checkout state changed while the v0.5 evidence/audit gate ran.'
}

$finalStoreCoreIdentity = Get-StoreCoreIdentity -Path $storeCorePath -V4AllowlistPattern $v4AllowlistPattern
$finalDomainContractIdentity = Get-EvidenceDomainContractIdentity -Path $domainContractPath
$finalHashes = [ordered]@{
    DomainContractProjection = $finalDomainContractIdentity.ProjectionSha256
    DomainContractExtension = $finalDomainContractIdentity.ExtensionSha256
    StoreCore = (Get-FileHash -LiteralPath $storeCorePath -Algorithm SHA256).Hash
    StoreCoreV3Projection = $finalStoreCoreIdentity.ProjectionSha256
    Storage = (Get-FileHash -LiteralPath $storagePath -Algorithm SHA256).Hash
    Migration = (Get-FileHash -LiteralPath $migrationPath -Algorithm SHA256).Hash
    Contract = (Get-FileHash -LiteralPath $contractPath -Algorithm SHA256).Hash
}
foreach ($entry in $actualHashes.GetEnumerator()) {
    if ($finalHashes[$entry.Key] -cne $entry.Value) {
        throw "Evidence/audit bound file changed during the gate: $($entry.Key) initial=$($entry.Value) final=$($finalHashes[$entry.Key])"
    }
}
if ($finalStoreCoreIdentity.V4RegistrationSha256 -cne $v4RegistrationSha256) {
    throw "The allowed v4 extension identity changed during the gate: initial=$v4RegistrationSha256 final=$($finalStoreCoreIdentity.V4RegistrationSha256)"
}

$gateReportPath = Join-Path $gateDirectory 'gate-report.txt'
$counterReport = $testCounterEvidence | ForEach-Object {
    $values = $_.Counters
    "TRX $($_.Name) total=$($values.total) executed=$($values.executed) passed=$($values.passed) failed=$($values.failed) error=$($values.error) timeout=$($values.timeout) aborted=$($values.aborted) inconclusive=$($values.inconclusive) notExecuted=$($values.notExecuted) completed=$($values.completed) notRunnable=$($values.notRunnable) disconnected=$($values.disconnected) warning=$($values.warning)"
}
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
    'EvidenceFoundationSchemaVersion: 3',
    "CurrentForwardSchemaVersion: $currentSchemaVersion",
    'ManagedArtifactBytes: OUTSIDE SQLITE',
    'ReviewAudit: APPEND-ONLY HASH CHAIN',
    'OpenReviewRetentionProtection: SYNTHETICALLY VERIFIED',
    "TestsAggregate: total=$($aggregateCounters.total) executed=$($aggregateCounters.executed) passed=$($aggregateCounters.passed) failed=$($aggregateCounters.failed) error=$($aggregateCounters.error) timeout=$($aggregateCounters.timeout) aborted=$($aggregateCounters.aborted) inconclusive=$($aggregateCounters.inconclusive) notExecuted=$($aggregateCounters.notExecuted) completed=$($aggregateCounters.completed) notRunnable=$($aggregateCounters.notRunnable) disconnected=$($aggregateCounters.disconnected) warning=$($aggregateCounters.warning)",
    'FreshTrxCounters:',
    $counterReport,
    "DomainContractProjectionSha256: $($actualHashes.DomainContractProjection)",
    "DomainContractExtensionSha256: $($actualHashes.DomainContractExtension)",
    "StoreCoreSha256: $($actualHashes.StoreCore)",
    "StoreCoreV3ProjectionSha256: $($actualHashes.StoreCoreV3Projection)",
    "AllowedV4ExtensionIdentity: schema=4;registrationSha256=$v4RegistrationSha256",
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

Write-Host "v0.5 evidence/audit implementation gate passed: $($aggregateCounters.passed)/$($aggregateCounters.total) tests."
Write-Host "Gate report: $gateReportPath"
