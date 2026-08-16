[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$artifactRoot = Join-Path $repositoryRoot 'artifacts'
$expectedBranch = 'codex/v10-issue-43-security-review'
$expectedRecoveryHead = '628a9661ac301994b4829d52f26051246feb38fd'
$runId = "$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ', [Globalization.CultureInfo]::InvariantCulture))-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
$gateDirectory = Join-Path $artifactRoot "release-gates\v1.0.0\issue-43\$runId"
$testDirectory = Join-Path $gateDirectory 'contract-tests'
$checkResults = @()
$failures = @()
$fileInventory = @()
$testReports = @()

function Record-Check {
    param(
        [Parameter(Mandatory)]
        [string]$Id,

        [Parameter(Mandatory)]
        [string]$Status,

        [Parameter(Mandatory)]
        [string]$EvidenceClass,

        [Parameter(Mandatory)]
        [string]$Detail
    )

    $script:checkResults += [pscustomobject]@{
        Id = $Id
        Status = $Status
        EvidenceClass = $EvidenceClass
        Detail = $Detail
    }
    if ($Status -eq 'FAIL') {
        $script:failures += "$Id $Detail"
    }
}

function Get-RepositoryFile {
    param(
        [Parameter(Mandatory)]
        [string]$RelativePath
    )

    $candidate = Join-Path $repositoryRoot $RelativePath
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        return $null
    }

    return (Resolve-Path -LiteralPath $candidate).Path
}

function Get-RelativeRepositoryPath {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $rootPrefix = $repositoryRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $Path.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        return $Path
    }

    return $Path.Substring($rootPrefix.Length).Replace([IO.Path]::AltDirectorySeparatorChar, [IO.Path]::DirectorySeparatorChar)
}

function Add-ReviewedFile {
    param(
        [Parameter(Mandatory)]
        [string]$RelativePath
    )

    $path = Get-RepositoryFile -RelativePath $RelativePath
    if ($null -eq $path) {
        Record-Check -Id "FILE:$RelativePath" -Status 'FAIL' -EvidenceClass 'Static' -Detail 'required reviewed file is missing'
        return
    }

    $item = Get-Item -LiteralPath $path
    $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToUpperInvariant()
    $script:fileInventory += [pscustomobject]@{
        Path = $RelativePath.Replace('\', '/')
        Bytes = [int64]$item.Length
        Sha256 = $hash
    }
}

function Get-RepositoryText {
    param(
        [Parameter(Mandatory)]
        [string]$RelativePath
    )

    $path = Get-RepositoryFile -RelativePath $RelativePath
    if ($null -eq $path) {
        return $null
    }

    return Get-Content -LiteralPath $path -Raw
}

function Test-MarkerGroup {
    param(
        [Parameter(Mandatory)]
        [string]$Id,

        [Parameter(Mandatory)]
        [ValidateSet('Static', 'Contract')]
        [string]$EvidenceClass,

        [Parameter(Mandatory)]
        [object[]]$Files
    )

    $missing = @()
    foreach ($file in $Files) {
        $text = Get-RepositoryText -RelativePath $file.Path
        if ($null -eq $text) {
            $missing += "$($file.Path) [file missing]"
            continue
        }

        foreach ($marker in $file.Markers) {
            if ($text.IndexOf([string]$marker, [StringComparison]::Ordinal) -lt 0) {
                $missing += "$($file.Path) [$marker]"
            }
        }
    }

    if ($missing.Count -eq 0) {
        Record-Check -Id $Id -Status 'PASS' -EvidenceClass $EvidenceClass -Detail "all $($Files.Count) bounded source/document surfaces matched"
        return $true
    }

    Record-Check -Id $Id -Status 'FAIL' -EvidenceClass $EvidenceClass -Detail "missing bounded markers: $($missing -join '; ')"
    return $false
}

function Get-ProductTextFiles {
    $extensions = @('.cs', '.csproj', '.json', '.xml', '.manifest', '.config', '.props', '.targets')
    return @(Get-ChildItem -LiteralPath (Join-Path $repositoryRoot 'src') -Recurse -File |
        Where-Object { $extensions -contains $_.Extension.ToLowerInvariant() } |
        Sort-Object FullName)
}

function Test-ForbiddenProductPattern {
    param(
        [Parameter(Mandatory)]
        [string]$Id,

        [Parameter(Mandatory)]
        [string]$Pattern,

        [Parameter(Mandatory)]
        [string]$Description
    )

    $hits = @()
    foreach ($file in (Get-ProductTextFiles)) {
        $hits += @(Select-String -LiteralPath $file.FullName -Pattern $Pattern)
    }

    if ($hits.Count -eq 0) {
        Record-Check -Id $Id -Status 'PASS' -EvidenceClass 'Static' -Detail "${Description}: 0 declarations across product source/config"
        return $true
    }

    $locations = $hits | ForEach-Object {
        "$(Get-RelativeRepositoryPath -Path $_.Path):$($_.LineNumber)"
    }
    Record-Check -Id $Id -Status 'FAIL' -EvidenceClass 'Static' -Detail "${Description}: unexpected declarations at $($locations -join ', ')"
    return $false
}

function Test-ContractTestSelection {
    param(
        [Parameter(Mandatory)]
        [string]$Id,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$Project,

        [Parameter(Mandatory)]
        [string]$Filter
    )

    $projectPath = Get-RepositoryFile -RelativePath $Project
    if ($null -eq $projectPath) {
        Record-Check -Id $Id -Status 'FAIL' -EvidenceClass 'Contract' -Detail "test project is missing: $Project"
        return
    }

    $trxName = "$Id-$Name.trx"
    $arguments = @(
        'test',
        $projectPath,
        '--configuration',
        $Configuration,
        '--filter',
        $Filter,
        '--logger',
        "trx;LogFileName=$trxName",
        '--results-directory',
        $testDirectory
    )
    $output = @(& dotnet @arguments 2>&1)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        Record-Check -Id $Id -Status 'FAIL' -EvidenceClass 'Contract' -Detail "$Name selected tests exited $exitCode"
        return
    }

    $trxCandidates = @(Get-ChildItem -LiteralPath $testDirectory -Recurse -File -Filter $trxName -ErrorAction SilentlyContinue)
    if ($trxCandidates.Count -ne 1) {
        Record-Check -Id $Id -Status 'FAIL' -EvidenceClass 'Contract' -Detail "$Name did not produce exactly one TRX result (found $($trxCandidates.Count))"
        return
    }

    [xml]$trx = Get-Content -LiteralPath $trxCandidates[0].FullName -Raw
    $counters = $trx.TestRun.ResultSummary.Counters
    $total = [int]$counters.total
    $passed = [int]$counters.passed
    $failed = [int]$counters.failed
    $relativeTrx = Get-RelativeRepositoryPath -Path $trxCandidates[0].FullName
    $trxHash = (Get-FileHash -LiteralPath $trxCandidates[0].FullName -Algorithm SHA256).Hash.ToUpperInvariant()
    $script:testReports += [pscustomobject]@{
        Id = $Id
        Name = $Name
        Path = $relativeTrx
        Sha256 = $trxHash
        Total = $total
        Passed = $passed
        Failed = $failed
    }

    if ($total -le 0 -or $failed -ne 0 -or $total -ne $passed) {
        Record-Check -Id $Id -Status 'FAIL' -EvidenceClass 'Contract' -Detail "$Name counters are not all passing: total=$total passed=$passed failed=$failed"
        return
    }

    Record-Check -Id $Id -Status 'PASS' -EvidenceClass 'Contract' -Detail "$Name selected tests passed: $passed/$total; TRX=$relativeTrx; SHA256=$trxHash"
}

function Write-Reports {
    param(
        [Parameter(Mandatory)]
        [string]$Result
    )

    New-Item -ItemType Directory -Path $gateDirectory -Force | Out-Null
    $schemaReportPath = Join-Path $gateDirectory 'schema-migration-report.txt'
    $schemaReport = @(
        'HerdrOps v1.0.0 Issue #43 Schema and Migration Report',
        "GeneratedUtc: $([DateTime]::UtcNow.ToString('O'))",
        "SourceCommit: $sourceCommit",
        "Branch: $branch",
        "Result: $Result",
        'EvidenceClass: Static plus Contract',
        '',
        'SchemaVersion: v3',
        'MigrationGraph: v1 initial-state-store -> v2 assignment-lifecycle-provenance -> v3 evidence-metadata-review-retention-audit',
        'ForwardOnly: PASS when S-01 is PASS',
        'FutureSchemaFailsClosed: PASS when S-01 is PASS',
        'PreMigrationBackup: PASS when S-02 is PASS',
        'TransactionalRollback: PASS when S-02 and C-04/C-05 are PASS',
        'ExplicitRollback: RESTORE_STATE_STORE plus expected source/destination identities',
        'IntegrityChecks: quick_check and integrity_check are required at admission/recovery boundaries',
        'Quarantine: damaged primary retained and copied to collision-safe tokenized evidence',
        '',
        'ReviewedMigrationFiles:'
    ) + ($fileInventory | Where-Object { $_.Path -match 'SqliteHerdrStateStore|HerdrStateStoreModels|Storage/Recovery|state-recovery-contract' } | ForEach-Object {
        "SHA256 $($_.Sha256) BYTES $($_.Bytes) $($_.Path)"
    }) + @(
        '',
        'Boundary: This is repository static/local-contract evidence. It is not live database, installed product, runtime, independent-review, or release evidence.'
    )
    $schemaReport | Set-Content -LiteralPath $schemaReportPath -Encoding utf8
    $schemaReportHash = (Get-FileHash -LiteralPath $schemaReportPath -Algorithm SHA256).Hash.ToUpperInvariant()

    $gateReportPath = Join-Path $gateDirectory 'gate-report.txt'
    $staticResult = if (@($checkResults | Where-Object { $_.EvidenceClass -eq 'Static' -and $_.Status -eq 'FAIL' }).Count -eq 0) { 'PASS' } else { 'FAIL' }
    $contractResult = if (@($checkResults | Where-Object { $_.EvidenceClass -eq 'Contract' -and $_.Status -eq 'FAIL' }).Count -eq 0) { 'PASS' } else { 'FAIL' }
    $highFindingResult = if ($failures.Count -eq 0) { 'NONE OBSERVED BY THIS STATIC/CONTRACT SLICE' } else { 'REVIEW REQUIRED; GATE FAILED' }
    $report = @(
        'HerdrOps v1.0.0 Issue #43 Security and Privacy Review Gate',
        "GeneratedUtc: $([DateTime]::UtcNow.ToString('O'))",
        "SourceCommit: $sourceCommit",
        "Branch: $branch",
        "RecoveryHead: $expectedRecoveryHead",
        'Issue: #43',
        "Result: $Result",
        'PreparationSlice: NON-RUNTIME STATIC+CONTRACT',
        "ReviewedFileCount: $($fileInventory.Count)",
        "SchemaMigrationReportSha256: $schemaReportHash",
        '',
        "StaticEvidence: $staticResult",
        "ContractEvidence: $contractResult",
        'LocalSyntheticOrIntegrationSupport: SELECTED LOCAL TESTS ONLY',
        'ActualHerdrRuntime: NOT OBSERVED / NOT CLAIMED',
        'LiveListeners: NOT OBSERVED / NOT CLAIMED',
        'LivePipeAcls: NOT OBSERVED / NOT CLAIMED',
        'LiveProcesses: NOT OBSERVED / NOT CLAIMED',
        'RegistryAppDataLiveDatabase: NOT OBSERVED / NOT TOUCHED',
        'AdministratorRuntimeProof: NOT OBSERVED / NOT CLAIMED',
        'IndependentReview: NOT OBSERVED / NOT CLAIMED',
        'ReleaseEvidence: NOT OBSERVED / NOT CLAIMED',
        'IssueAcceptance: PENDING',
        'VersionReleaseReady: false',
        "HighFindings: $highFindingResult",
        '',
        'Checks:'
    ) + ($checkResults | ForEach-Object {
        "$($_.Status) $($_.Id) evidence=$($_.EvidenceClass) $($_.Detail)"
    }) + @(
        '',
        'ReviewedFiles:'
    ) + ($fileInventory | ForEach-Object {
        "SHA256 $($_.Sha256) BYTES $($_.Bytes) $($_.Path)"
    }) + @(
        '',
        'ContractTestReports:'
    ) + ($testReports | ForEach-Object {
        "$($_.Id) $($_.Path) SHA256=$($_.Sha256) tests=$($_.Passed)/$($_.Total)"
    }) + @(
        '',
        'EvidenceBoundary:',
        'This gate statically inspects committed repository source/config/Plan/docs and runs only the selected local contract/privacy/storage tests.',
        'It does not inspect live listeners, effective Windows ACLs, processes, Registry, AppData, a live database, installed Herdr, or a non-elevated host.',
        'It does not establish independent review, Issue #43 acceptance, milestone closure, packaging, installation, upgrade, release, or human go/no-go.'
    )
    $report | Set-Content -LiteralPath $gateReportPath -Encoding utf8
    $report | Write-Output
    Write-Output "SchemaMigrationReport: $schemaReportPath"
    Write-Output "GateReport: $gateReportPath"
}

New-Item -ItemType Directory -Path $testDirectory -Force | Out-Null

$sourceCommitOutput = @(& git -C $repositoryRoot rev-parse --verify 'HEAD^{commit}' 2>&1)
$sourceCommit = ($sourceCommitOutput -join '').Trim()
if ($LASTEXITCODE -ne 0 -or $sourceCommit -notmatch '^[0-9a-f]{40}$') {
    $sourceCommit = 'UNRESOLVED'
    Record-Check -Id 'BOUND-01' -Status 'FAIL' -EvidenceClass 'Static' -Detail 'could not resolve exact source commit'
} else {
    Record-Check -Id 'BOUND-01' -Status 'PASS' -EvidenceClass 'Static' -Detail "source commit is $sourceCommit"
}

$branchOutput = @(& git -C $repositoryRoot symbolic-ref --short HEAD 2>&1)
$branch = ($branchOutput -join '').Trim()
if ($LASTEXITCODE -ne 0 -or $branch -ne $expectedBranch) {
    Record-Check -Id 'BOUND-02' -Status 'FAIL' -EvidenceClass 'Static' -Detail "expected branch $expectedBranch but observed $branch"
} else {
    Record-Check -Id 'BOUND-02' -Status 'PASS' -EvidenceClass 'Static' -Detail "branch is $expectedBranch"
}

$initialStatus = @(& git -C $repositoryRoot status --porcelain=v1 --untracked-files=all 2>&1)
if ($LASTEXITCODE -ne 0 -or $initialStatus.Count -ne 0) {
    Record-Check -Id 'BOUND-03' -Status 'FAIL' -EvidenceClass 'Static' -Detail 'checkout is not clean and committed'
} else {
    Record-Check -Id 'BOUND-03' -Status 'PASS' -EvidenceClass 'Static' -Detail 'clean committed checkout'
}

$ancestorExit = 1
if ($sourceCommit -match '^[0-9a-f]{40}$') {
    & git -C $repositoryRoot merge-base --is-ancestor $expectedRecoveryHead $sourceCommit 2>$null
    $ancestorExit = $LASTEXITCODE
}
if ($ancestorExit -ne 0) {
    Record-Check -Id 'BOUND-04' -Status 'FAIL' -EvidenceClass 'Static' -Detail "source is not descended from recovery head $expectedRecoveryHead"
} else {
    Record-Check -Id 'BOUND-04' -Status 'PASS' -EvidenceClass 'Static' -Detail "source descends from recovery head $expectedRecoveryHead"
}

$requiredFiles = @(
    'Plan/ARCHITECTURE.md',
    'Plan/DECISIONS.md',
    'Plan/RELEASE-GATES.md',
    'Plan/ROADMAP.md',
    'docs/protocol/v0.5-evidence-audit-storage-contract.md',
    'docs/protocol/v0.6-local-export-contract.md',
    'docs/protocol/v0.7-diagnostic-bundle-contract.md',
    'docs/protocol/v0.7-state-recovery-contract.md',
    'docs/protocol/v1.0-issue-43-security-privacy-review-contract.md',
    'docs/reviews/v1.0-issue-43-security-privacy-checklist.md',
    'docs/reviews/v1.0-issue-43-security-privacy-report-template.md',
    'tools/Test-V10Issue43SecurityReview.ps1',
    'src/HerdrOps.Infrastructure/Storage/HerdrStateStoreModels.cs',
    'src/HerdrOps.Infrastructure/Storage/SqliteHerdrStateStore.cs',
    'src/HerdrOps.Infrastructure/Storage/SqliteHerdrStateStore.EvidenceMigration.cs',
    'src/HerdrOps.Infrastructure/Storage/SqliteHerdrStateStore.Evidence.cs',
    'src/HerdrOps.Infrastructure/Storage/Recovery/StateStoreRecoveryContracts.cs',
    'src/HerdrOps.Infrastructure/Storage/Recovery/StateStoreRecoveryArtifacts.cs',
    'src/HerdrOps.Infrastructure/Storage/Recovery/StateStoreRecoveryPathPolicy.cs',
    'src/HerdrOps.Infrastructure/Storage/Recovery/StateStoreRecoveryService.cs',
    'src/HerdrOps.Infrastructure/StateIpc/HerdrOpsStatePipeServer.cs',
    'src/HerdrOps.Infrastructure/StateIpc/HerdrOpsSelfReportPipeServer.cs',
    'src/HerdrOps.Contracts/StateIpc/HerdrOpsStateIpcContract.cs',
    'src/HerdrOps.Contracts/StateIpc/HerdrOpsStatePipeName.cs',
    'src/HerdrOps.Contracts/SelfReport/HerdrOpsSelfReportPipeName.cs',
    'src/HerdrOps.App/StateIpc/HerdrOpsStatePipeClient.cs',
    'src/HerdrOps.Cli/HerdrOpsSelfReportPipeClient.cs',
    'src/HerdrOps.Domain/Diagnostics/DiagnosticRedaction.cs',
    'src/HerdrOps.Domain/Diagnostics/DiagnosticBundleModels.cs',
    'src/HerdrOps.Domain/Diagnostics/DiagnosticBundleBuilder.cs',
    'src/HerdrOps.Infrastructure/Diagnostics/DiagnosticBundlePublisher.cs',
    'src/HerdrOps.Domain/Exports/DeterministicSnapshotExporter.cs',
    'src/HerdrOps.Domain/Exports/LocalSnapshotExportPublisher.cs',
    'src/HerdrOps.Domain/Activity/TerminalPreviewPolicy.cs',
    'tests/HerdrOps.ContractTests/StateIpcContractTests.cs',
    'tests/HerdrOps.ContractTests/SelfReportContractTests.cs',
    'tests/HerdrOps.ContractTests/SnapshotExportContractTests.cs',
    'tests/HerdrOps.UnitTests/TerminalPreviewPolicyTests.cs',
    'tests/HerdrOps.UnitTests/DeterministicSnapshotExporterTests.cs',
    'tests/HerdrOps.UnitTests/LocalSnapshotExportPublisherTests.cs',
    'tests/HerdrOps.IntegrationTests/SqliteHerdrStateStoreTests.cs',
    'tests/HerdrOps.IntegrationTests/StateStoreRecoveryTests.cs',
    'tests/HerdrOps.IntegrationTests/StateStoreRestoreCommandTests.cs',
    'tests/HerdrOps.IntegrationTests/EvidenceAuditStorageTests.cs',
    'tests/HerdrOps.IntegrationTests/DiagnosticBundleTests.cs'
)
foreach ($file in $requiredFiles) {
    Add-ReviewedFile -RelativePath $file
}
Record-Check -Id 'FILE-01' -Status 'PASS' -EvidenceClass 'Static' -Detail "hashed $($fileInventory.Count) required review files"

$markerGroups = @(
    [pscustomobject]@{ Id = 'S-01'; EvidenceClass = 'Static'; Files = @(
        @{ Path = 'src/HerdrOps.Infrastructure/Storage/HerdrStateStoreModels.cs'; Markers = @('CurrentSchemaVersion = 3') },
        @{ Path = 'src/HerdrOps.Infrastructure/Storage/SqliteHerdrStateStore.cs'; Markers = @('MigrationName =', 'AssignmentLifecycleMigrationName', 'ApplyMigrations', 'GetMigration', '1 => new MigrationDefinition', '2 => new MigrationDefinition', '3 => new MigrationDefinition', 'ValidateMigrationHistory', 'ComputeMigrationSha256', 'script_sha256', 'PRAGMA user_version', 'BeginTransaction', 'transaction.Commit()', 'transaction.Rollback()', 'version > HerdrStateStoreOptions.CurrentSchemaVersion') },
        @{ Path = 'src/HerdrOps.Infrastructure/Storage/SqliteHerdrStateStore.EvidenceMigration.cs'; Markers = @('EvidenceAuditMigrationName', 'CREATE TABLE evidence_items', 'CREATE TABLE review_audit_events', 'CREATE TABLE review_audit_evidence', 'CREATE TABLE evidence_retention_events', 'evidence_retention_events_reject_update', 'evidence_retention_events_reject_delete') },
        @{ Path = 'tests/HerdrOps.IntegrationTests/SqliteHerdrStateStoreTests.cs'; Markers = @('VersionOneDatabaseMigratesForwardWithoutLosingHistory', 'FailedVersionThreeMigrationRollsBackAllPartialChanges', 'FutureSchemaFailsClosedWithoutMigration') }
    ) },
    [pscustomobject]@{ Id = 'S-02'; EvidenceClass = 'Static'; Files = @(
        @{ Path = 'docs/protocol/v0.7-state-recovery-contract.md'; Markers = @('forward-only', 'BeforeBackup', 'AfterBackup', 'AfterMigrationBeforeCommit', 'RESTORE_STATE_STORE', 'quick_check', 'integrity_check', 'atomic', 'quarantine', 'NOT_OBSERVED') },
        @{ Path = 'src/HerdrOps.Infrastructure/Storage/Recovery/StateStoreRecoveryService.cs'; Markers = @('ConfirmationPhrase', 'ExpectedBackupSha256', 'RestoreBackup', 'sourceAfterRestore', 'RESTORE_STATE_STORE', 'NOT_OBSERVED') },
        @{ Path = 'src/HerdrOps.Infrastructure/Storage/Recovery/StateStoreRecoveryArtifacts.cs'; Markers = @('CreateBackup', 'RestoreBackup', 'FileMode.CreateNew', 'quick_check', 'integrity_check', 'File.Replace') },
        @{ Path = 'tests/HerdrOps.IntegrationTests/StateStoreRecoveryTests.cs'; Markers = @('InterruptedMigrationRollsBackAndBackupCanBeRestoredWithIntegrityCheck', 'DamagedDatabaseIsQuarantinedWithoutSilentReset', 'RecoveryTraceAndQuarantineMetadataTokenizePathsAndRedactFailureMessages') },
        @{ Path = 'tests/HerdrOps.IntegrationTests/StateStoreRestoreCommandTests.cs'; Markers = @('CoreRestoreCommandFailsClosedWithoutExactConfirmation') }
    ) },
    [pscustomobject]@{ Id = 'S-03'; EvidenceClass = 'Static'; Files = @(
        @{ Path = 'docs/protocol/v0.5-evidence-audit-storage-contract.md'; Markers = @('Retention evaluates only present managed copies', 'currently open', 'Purged', 'AlreadyMissing', 'Evidence metadata, review history, evidence links, and retention history remain', 'recoverable', 'Full policy defaults') },
        @{ Path = 'src/HerdrOps.Infrastructure/Storage/SqliteHerdrStateStore.Evidence.cs'; Markers = @('RetentionPendingDirectoryName', 'IsProtectedByOpenReview', 'HerdrEvidenceRetentionOutcome.Purged', 'HerdrEvidenceRetentionOutcome.AlreadyMissing', 'MoveManagedEvidenceToRetentionPending', 'RestorePendingRetentionFile', 'InsertRetentionAuditEvent', 'transaction.Commit()') },
        @{ Path = 'tests/HerdrOps.IntegrationTests/EvidenceAuditStorageTests.cs'; Markers = @('RetentionProtectsOpenReviewThenPurgesBytesAndPreservesHistory', 'FailedRetentionAuditWriteLeavesRecoverableBytesAndRetryCompletes', 'CommittedRetentionAuditWithPendingBytesRecoversCleanup') }
    ) },
    [pscustomobject]@{ Id = 'S-04'; EvidenceClass = 'Static'; Files = @(
        @{ Path = 'docs/protocol/v0.6-local-export-contract.md'; Markers = @('sourceSnapshotSha256', 'redaction', 'local', 'atomic', 'fail closed', 'credential', 'do not prove an installed Herdr') },
        @{ Path = 'src/HerdrOps.Domain/Exports/DeterministicSnapshotExporter.cs'; Markers = @('SnapshotExportContentPolicy', 'SecretOrTokenPattern', 'MaximumTotalOutputBytes', 'EnsureNoProhibitedContent', 'sourceSnapshotSha256') },
        @{ Path = 'src/HerdrOps.Domain/Exports/LocalSnapshotExportPublisher.cs'; Markers = @('FileMode.CreateNew', 'Directory.Move', 'atomic') },
        @{ Path = 'tests/HerdrOps.ContractTests/SnapshotExportContractTests.cs'; Markers = @('ExportContractUsesStableUtf8OrderingHashesAndFailClosedPolicy', 'PublisherRejectsHashConsistentForgedEnvelopeAndUnsafeDestinationWithoutPublication') },
        @{ Path = 'tests/HerdrOps.UnitTests/LocalSnapshotExportPublisherTests.cs'; Markers = @('PublishCreatesAtomicDirectoryPairWithManifestAndRereadHashes', 'PublishRejectsConflictWithoutOverwritingExistingPair', 'PublishRejectsHashConsistentForgedSensitiveEnvelopeWithoutFinalFiles') }
    ) },
    [pscustomobject]@{ Id = 'S-05'; EvidenceClass = 'Static'; Files = @(
        @{ Path = 'docs/protocol/v0.7-diagnostic-bundle-contract.md'; Markers = @('exactly three UTF-8 JSON artifacts', 'Raw environment', 'terminal-dump', 'process-dump', 'user-profile', 'configured secret', 'bounded', 'CreateNew', 'Actual Herdr Runtime') },
        @{ Path = 'src/HerdrOps.Domain/Diagnostics/DiagnosticBundleModels.cs'; Markers = @('PayloadFileName', 'DiagnosticRedactionOptions', 'MaximumInputUtf8Bytes', 'MaximumEntries', 'environment reader', 'No dump') },
        @{ Path = 'src/HerdrOps.Domain/Diagnostics/DiagnosticRedaction.cs'; Markers = @('DiagnosticTextRedactor', 'Replacement', 'UserProfileReplacement', 'SocketReplacement', 'PathReplacement') },
        @{ Path = 'src/HerdrOps.Domain/Diagnostics/DiagnosticBundleBuilder.cs'; Markers = @('DiagnosticBundleEntryKind', 'EnsureSize', 'RedactRequired', 'NormalizeMetadata', 'MaximumBundleBytes') },
        @{ Path = 'src/HerdrOps.Infrastructure/Diagnostics/DiagnosticBundlePublisher.cs'; Markers = @('FileMode.CreateNew', 'Directory.Move', 'destination already exists') },
        @{ Path = 'tests/HerdrOps.IntegrationTests/DiagnosticBundleTests.cs'; Markers = @('BuildRedactsConfiguredCommonAndNestedCredentialFormsFromEveryArtifact', 'BoundsRejectEntryCountMetadataDepthAndOversizedCanonicalArtifacts', 'PublisherUsesSafePathAtomicNoOverwriteAndOnlyContractArtifacts') }
    ) },
    [pscustomobject]@{ Id = 'S-06'; EvidenceClass = 'Contract'; Files = @(
        @{ Path = 'src/HerdrOps.Infrastructure/StateIpc/HerdrOpsStatePipeServer.cs'; Markers = @('CurrentUserOnly', 'RequiredPipeOptions', 'NamedPipeServerStream', 'HerdrOpsStatePipeName.FromUserScope') },
        @{ Path = 'src/HerdrOps.Infrastructure/StateIpc/HerdrOpsSelfReportPipeServer.cs'; Markers = @('CurrentUserOnly', 'RequiredPipeOptions', 'NamedPipeServerStream', 'HerdrOpsSelfReportPipeName.FromUserScope') },
        @{ Path = 'src/HerdrOps.App/StateIpc/HerdrOpsStatePipeClient.cs'; Markers = @('CurrentUserOnly', 'RequiredPipeOptions', 'NamedPipeClientStream', 'HerdrOpsStatePipeName.FromUserScope', 'AuthorizationScope') },
        @{ Path = 'src/HerdrOps.Cli/HerdrOpsSelfReportPipeClient.cs'; Markers = @('CurrentUserOnly', 'RequiredPipeOptions', 'NamedPipeClientStream', 'HerdrOpsSelfReportPipeName.FromUserScope') },
        @{ Path = 'src/HerdrOps.Contracts/StateIpc/HerdrOpsStatePipeName.cs'; Markers = @('SHA256.HashData', 'HerdrOps.StateIpc.v2|', 'hash[..24]') },
        @{ Path = 'src/HerdrOps.Contracts/SelfReport/HerdrOpsSelfReportPipeName.cs'; Markers = @('SHA256.HashData', 'HerdrOps.SelfReport.v1|', 'hash[..24]') },
        @{ Path = 'Plan/DECISIONS.md'; Markers = @('PipeOptions.CurrentUserOnly', 'pipe name is scoped by a non-reversible hash of the Windows user SID', 'has not yet received a separate multi-account runtime acceptance run') },
        @{ Path = 'tests/HerdrOps.ContractTests/StateIpcContractTests.cs'; Markers = @('UserScopedPipeNameIsStableAndDoesNotExposeIdentity') },
        @{ Path = 'tests/HerdrOps.ContractTests/SelfReportContractTests.cs'; Markers = @('CurrentUserPipeNameIsStableVersionedAndScopeSpecific') }
    ) },
    [pscustomobject]@{ Id = 'S-07'; EvidenceClass = 'Static'; Files = @(
        @{ Path = 'Plan/ARCHITECTURE.md'; Markers = @('No local HTTP server in v1 local mode', 'Herdr connection: Windows Named Pipe') },
        @{ Path = 'docs/protocol/v1.0-issue-43-security-privacy-review-contract.md'; Markers = @('no unexpected', 'TCP/HTTP/Web listener', 'Named Pipe server', 'live listener') }
    ) },
    [pscustomobject]@{ Id = 'S-08'; EvidenceClass = 'Static'; Files = @(
        @{ Path = 'Plan/RELEASE-GATES.md'; Markers = @('Normal-mode Administrator requirement | None') },
        @{ Path = 'Plan/ARCHITECTURE.md'; Markers = @('No Administrator requirement in normal mode') },
        @{ Path = 'docs/protocol/v1.0-issue-43-security-privacy-review-contract.md'; Markers = @('no `requireAdministrator`, `runas`, administrator role', 'non-elevated runtime proof') }
    ) },
    [pscustomobject]@{ Id = 'S-09'; EvidenceClass = 'Static'; Files = @(
        @{ Path = 'Plan/ARCHITECTURE.md'; Markers = @('Local-only data by default', 'Command lines, terminal output and files are treated as sensitive', 'Bounded reads, configurable retention and redaction before persistence/export', 'Optional elevated telemetry, remote aggregation and cloud sync are outside v1') },
        @{ Path = 'docs/protocol/v1.0-issue-43-security-privacy-review-contract.md'; Markers = @('same-user process', 'Registry', 'AppData', 'Independent review', 'Release') },
        @{ Path = 'docs/reviews/v1.0-issue-43-security-privacy-checklist.md'; Markers = @('NOT OBSERVED / NOT CLAIMED', 'Issue #43 acceptance and milestone closure: `PENDING`') }
    ) }
)

foreach ($group in $markerGroups) {
    Test-MarkerGroup -Id $group.Id -EvidenceClass $group.EvidenceClass -Files $group.Files | Out-Null
}

$listenerPattern = '(?i)\b(?:TcpListener|HttpListener|Kestrel|WebApplication|ListenOptions)\b|\b(?:UseUrls|ListenAsync)\s*\(|\bSystem\.Net\.HttpListener\b'
$loopbackEndpointPattern = '(?i)\b(?:https?|wss?)://(?:localhost|127\.0\.0\.1|\[?::1\]?)(?::\d+)?(?:/|\b)'
Test-ForbiddenProductPattern -Id 'S-07-LISTENER' -Pattern $listenerPattern -Description 'unexpected network listener declarations' | Out-Null
Test-ForbiddenProductPattern -Id 'S-07-LOOPBACK' -Pattern $loopbackEndpointPattern -Description 'loopback HTTP/Web endpoints' | Out-Null

$administratorPattern = '(?i)requestedExecutionLevel|requireAdministrator|uiAccess\s*=\s*["'']?true|verb\s*=\s*["'']?runas|WindowsBuiltInRole\s*\.\s*Administrator|PrincipalPermission|IsInRole\s*\([^)]*\bAdministrator\b|\bAdministrator\b'
Test-ForbiddenProductPattern -Id 'S-08-ADMIN' -Pattern $administratorPattern -Description 'Administrator/elevation declarations' | Out-Null

Test-ContractTestSelection -Id 'C-01' -Name 'ipc' -Project 'tests/HerdrOps.ContractTests/HerdrOps.ContractTests.csproj' -Filter 'FullyQualifiedName~StateIpcContractTests|FullyQualifiedName~SelfReportContractTests'
Test-ContractTestSelection -Id 'C-02' -Name 'export' -Project 'tests/HerdrOps.ContractTests/HerdrOps.ContractTests.csproj' -Filter 'FullyQualifiedName~SnapshotExportContractTests'
Test-ContractTestSelection -Id 'C-03' -Name 'redaction' -Project 'tests/HerdrOps.UnitTests/HerdrOps.UnitTests.csproj' -Filter 'FullyQualifiedName~TerminalPreviewPolicyTests|FullyQualifiedName~DeterministicSnapshotExporterTests|FullyQualifiedName~LocalSnapshotExportPublisherTests'
Test-ContractTestSelection -Id 'C-04' -Name 'schema' -Project 'tests/HerdrOps.IntegrationTests/HerdrOps.IntegrationTests.csproj' -Filter 'FullyQualifiedName~SqliteHerdrStateStoreTests'
Test-ContractTestSelection -Id 'C-05' -Name 'recovery' -Project 'tests/HerdrOps.IntegrationTests/HerdrOps.IntegrationTests.csproj' -Filter 'FullyQualifiedName~StateStoreRecoveryTests|FullyQualifiedName~StateStoreRestoreCommandTests'
Test-ContractTestSelection -Id 'C-06' -Name 'retention' -Project 'tests/HerdrOps.IntegrationTests/HerdrOps.IntegrationTests.csproj' -Filter 'FullyQualifiedName~EvidenceAuditStorageTests'
Test-ContractTestSelection -Id 'C-07' -Name 'diagnostic' -Project 'tests/HerdrOps.IntegrationTests/HerdrOps.IntegrationTests.csproj' -Filter 'FullyQualifiedName~DiagnosticBundleTests'

$finalCommitOutput = @(& git -C $repositoryRoot rev-parse --verify 'HEAD^{commit}' 2>&1)
$finalCommit = ($finalCommitOutput -join '').Trim()
$finalStatus = @(& git -C $repositoryRoot status --porcelain=v1 --untracked-files=all 2>&1)
if ($finalCommit -ne $sourceCommit -or $finalStatus.Count -ne 0) {
    Record-Check -Id 'BOUND-05' -Status 'FAIL' -EvidenceClass 'Static' -Detail 'source commit or clean checkout changed during the gate'
} else {
    Record-Check -Id 'BOUND-05' -Status 'PASS' -EvidenceClass 'Static' -Detail 'source commit and clean checkout remained unchanged'
}

$result = if ($failures.Count -eq 0) { 'PASS' } else { 'FAIL' }
Write-Reports -Result $result
if ($result -ne 'PASS') {
    throw "Issue #43 static/contract gate failed: $($failures -join '; ')"
}
