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
$requiredRelativePaths = @(
    '.github\workflows\ci.yml',
    'docs\design\implementation\v0.5-issue-27-role-distinct-review.md',
    'docs\protocol\v0.5-role-distinct-review-workflow-contract.md',
    'src\HerdrOps.Domain\Compliance\ComplianceReviewWorkflow.cs',
    'src\HerdrOps.Contracts\ReviewIpc\HerdrOpsReviewCommandContract.cs',
    'src\HerdrOps.Contracts\ReviewIpc\HerdrOpsReviewCommandJson.cs',
    'src\HerdrOps.Contracts\ReviewIpc\HerdrOpsReviewCommandPipeName.cs',
    'src\HerdrOps.Contracts\ReviewIpc\HerdrOpsReviewServerProcessIdentity.cs',
    'src\HerdrOps.Infrastructure\Storage\HerdrStateStoreModels.cs',
    'src\HerdrOps.Infrastructure\Storage\SqliteHerdrStateStore.cs',
    'src\HerdrOps.Infrastructure\Storage\SqliteHerdrStateStore.ComplianceReviewMigration.cs',
    'src\HerdrOps.Infrastructure\Storage\SqliteHerdrStateStore.ComplianceReview.cs',
    'src\HerdrOps.Infrastructure\ReviewIpc\HerdrOpsReviewCommandPipeServer.cs',
    'src\HerdrOps.Infrastructure\ReviewIpc\WindowsProcessAncestryReader.cs',
    'src\HerdrOps.Core\ComplianceReviewCommandMapper.cs',
    'src\HerdrOps.Core\ComplianceReviewWorkflowService.cs',
    'src\HerdrOps.Core\HerdrReviewClientProcessAuthorizer.cs',
    'src\HerdrOps.Core\HerdrOpsCoreStateService.cs',
    'src\HerdrOps.Core\HerdrOpsCoreStateServiceCommand.cs',
    'src\HerdrOps.Cli\HerdrOpsCliCommand.cs',
    'src\HerdrOps.Cli\ComplianceReviewCliCommand.cs',
    'src\HerdrOps.Cli\HerdrOpsReviewCommandPipeClient.cs',
    'src\HerdrOps.Cli\Properties\AssemblyInfo.cs',
    'src\HerdrOps.App\App.xaml.cs',
    'src\HerdrOps.App\Properties\AssemblyInfo.cs',
    'src\HerdrOps.App\ReviewIpc\HerdrOpsReviewCommandPipeClient.cs',
    'src\HerdrOps.App\ReviewIpc\ComplianceReviewCommandCoordinator.cs',
    'src\HerdrOps.App\ReviewIpc\ComplianceReviewStateHub.cs',
    'src\HerdrOps.App\ReviewIpc\DispatcherComplianceReviewStateScheduler.cs',
    'src\HerdrOps.App\Compliance\ComplianceQueueState.cs',
    'src\HerdrOps.App\Live\LiveDashboardState.cs',
    'src\HerdrOps.App\Live\LiveDashboardRuntime.cs',
    'src\HerdrOps.App\Localization\UiLanguageService.cs',
    'src\HerdrOps.App\Views\ComplianceQueueView.xaml',
    'src\HerdrOps.App\Views\ComplianceQueueView.xaml.cs',
    'src\HerdrOps.App\Widgets\LiveWidgetState.cs',
    'src\HerdrOps.App\Widgets\WidgetActions.cs',
    'tests\HerdrOps.UnitTests\ComplianceReviewWorkflowTests.cs',
    'tests\HerdrOps.ContractTests\ReviewCommandIpcContractTests.cs',
    'tests\HerdrOps.IntegrationTests\AssignmentLifecycleStoreTests.cs',
    'tests\HerdrOps.IntegrationTests\ComplianceReviewStorageTests.cs',
    'tests\HerdrOps.IntegrationTests\ComplianceReviewWorkflowServiceTests.cs',
    'tests\HerdrOps.IntegrationTests\ReviewCommandIpcIntegrationTests.cs',
    'tests\HerdrOps.IntegrationTests\ReviewCommandIpcTimeoutIntegrationTests.cs',
    'tests\HerdrOps.IntegrationTests\ReviewCommandHandlerTimeoutIntegrationTests.cs',
    'tests\HerdrOps.IntegrationTests\ComplianceReviewCommandCoordinatorTests.cs',
    'tests\HerdrOps.IntegrationTests\ComplianceReviewStateHubTests.cs',
    'tests\HerdrOps.IntegrationTests\ComplianceQueueStateTests.cs',
    'tests\HerdrOps.IntegrationTests\EvidenceAuditStorageTests.cs',
    'tests\HerdrOps.IntegrationTests\HerdrReviewClientProcessAuthorizerTests.cs',
    'tests\HerdrOps.IntegrationTests\SqliteHerdrStateStoreTests.cs',
    'tests\HerdrOps.IntegrationTests\UiLanguageCatalogTests.cs',
    'tools\Test-V05RoleDistinctReview.ps1'
)

$workingTreeStatus = @(& git -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0) {
    throw 'Could not inspect the source working tree for the v0.5 role-distinct review gate.'
}
if ($workingTreeStatus.Count -ne 0) {
    throw "The v0.5 role-distinct review gate requires a clean committed checkout. Pending paths: $($workingTreeStatus -join ', ')"
}

$sourceCommit = (& git -C $repositoryRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($sourceCommit)) {
    throw 'Could not resolve the source commit for the v0.5 role-distinct review gate.'
}

$requiredFiles = @()
$sourceHashes = [ordered]@{}
foreach ($relativePath in $requiredRelativePaths) {
    $path = Join-Path $repositoryRoot $relativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required role-distinct review file was not found: $relativePath"
    }
    $gitRelativePath = $relativePath.Replace('\', '/')
    & git -C $repositoryRoot ls-files --error-unmatch -- $gitRelativePath *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "Required role-distinct review file is not committed: $relativePath"
    }
    $requiredFiles += $path
    $sourceHashes[$relativePath] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
}

$ciSource = Get-Content -LiteralPath (Join-Path $repositoryRoot '.github\workflows\ci.yml') -Raw
$contractSource = Get-Content -LiteralPath (Join-Path $repositoryRoot 'docs\protocol\v0.5-role-distinct-review-workflow-contract.md') -Raw
$commandContractSource = Get-Content -LiteralPath (Join-Path $repositoryRoot 'src\HerdrOps.Contracts\ReviewIpc\HerdrOpsReviewCommandContract.cs') -Raw
$commandJsonSource = Get-Content -LiteralPath (Join-Path $repositoryRoot 'src\HerdrOps.Contracts\ReviewIpc\HerdrOpsReviewCommandJson.cs') -Raw
$pipeNameSource = Get-Content -LiteralPath (Join-Path $repositoryRoot 'src\HerdrOps.Contracts\ReviewIpc\HerdrOpsReviewCommandPipeName.cs') -Raw
$serverIdentitySource = Get-Content -LiteralPath (Join-Path $repositoryRoot 'src\HerdrOps.Contracts\ReviewIpc\HerdrOpsReviewServerProcessIdentity.cs') -Raw
$domainSource = Get-Content -LiteralPath (Join-Path $repositoryRoot 'src\HerdrOps.Domain\Compliance\ComplianceReviewWorkflow.cs') -Raw
$storeModelsSource = Get-Content -LiteralPath (Join-Path $repositoryRoot 'src\HerdrOps.Infrastructure\Storage\HerdrStateStoreModels.cs') -Raw
$assignmentStorageSource = Get-Content -LiteralPath (Join-Path $repositoryRoot 'src\HerdrOps.Infrastructure\Storage\SqliteHerdrStateStore.cs') -Raw
$migrationSource = Get-Content -LiteralPath (Join-Path $repositoryRoot 'src\HerdrOps.Infrastructure\Storage\SqliteHerdrStateStore.ComplianceReviewMigration.cs') -Raw
$storageSource = Get-Content -LiteralPath (Join-Path $repositoryRoot 'src\HerdrOps.Infrastructure\Storage\SqliteHerdrStateStore.ComplianceReview.cs') -Raw
$serverSource = Get-Content -LiteralPath (Join-Path $repositoryRoot 'src\HerdrOps.Infrastructure\ReviewIpc\HerdrOpsReviewCommandPipeServer.cs') -Raw
$processSource = Get-Content -LiteralPath (Join-Path $repositoryRoot 'src\HerdrOps.Infrastructure\ReviewIpc\WindowsProcessAncestryReader.cs') -Raw
$mapperSource = Get-Content -LiteralPath (Join-Path $repositoryRoot 'src\HerdrOps.Core\ComplianceReviewCommandMapper.cs') -Raw
$workflowServiceSource = Get-Content -LiteralPath (Join-Path $repositoryRoot 'src\HerdrOps.Core\ComplianceReviewWorkflowService.cs') -Raw
$authorizerSource = Get-Content -LiteralPath (Join-Path $repositoryRoot 'src\HerdrOps.Core\HerdrReviewClientProcessAuthorizer.cs') -Raw
$coreStateServiceSource = Get-Content -LiteralPath (Join-Path $repositoryRoot 'src\HerdrOps.Core\HerdrOpsCoreStateService.cs') -Raw
$coreServiceSource = Get-Content -LiteralPath (Join-Path $repositoryRoot 'src\HerdrOps.Core\HerdrOpsCoreStateServiceCommand.cs') -Raw
$cliDispatcherSource = Get-Content -LiteralPath (Join-Path $repositoryRoot 'src\HerdrOps.Cli\HerdrOpsCliCommand.cs') -Raw
$cliSource = Get-Content -LiteralPath (Join-Path $repositoryRoot 'src\HerdrOps.Cli\ComplianceReviewCliCommand.cs') -Raw
$cliPipeClientSource = Get-Content -LiteralPath (Join-Path $repositoryRoot 'src\HerdrOps.Cli\HerdrOpsReviewCommandPipeClient.cs') -Raw
$appSource = Get-Content -LiteralPath (Join-Path $repositoryRoot 'src\HerdrOps.App\App.xaml.cs') -Raw
$appPipeClientSource = Get-Content -LiteralPath (Join-Path $repositoryRoot 'src\HerdrOps.App\ReviewIpc\HerdrOpsReviewCommandPipeClient.cs') -Raw
$coordinatorSource = Get-Content -LiteralPath (Join-Path $repositoryRoot 'src\HerdrOps.App\ReviewIpc\ComplianceReviewCommandCoordinator.cs') -Raw
$stateHubSource = Get-Content -LiteralPath (Join-Path $repositoryRoot 'src\HerdrOps.App\ReviewIpc\ComplianceReviewStateHub.cs') -Raw
$schedulerSource = Get-Content -LiteralPath (Join-Path $repositoryRoot 'src\HerdrOps.App\ReviewIpc\DispatcherComplianceReviewStateScheduler.cs') -Raw
$queueSource = Get-Content -LiteralPath (Join-Path $repositoryRoot 'src\HerdrOps.App\Compliance\ComplianceQueueState.cs') -Raw
$dashboardSource = Get-Content -LiteralPath (Join-Path $repositoryRoot 'src\HerdrOps.App\Live\LiveDashboardState.cs') -Raw
$dashboardRuntimeSource = Get-Content -LiteralPath (Join-Path $repositoryRoot 'src\HerdrOps.App\Live\LiveDashboardRuntime.cs') -Raw
$languageCatalogSource = Get-Content -LiteralPath (Join-Path $repositoryRoot 'src\HerdrOps.App\Localization\UiLanguageService.cs') -Raw
$queueViewSource = Get-Content -LiteralPath (Join-Path $repositoryRoot 'src\HerdrOps.App\Views\ComplianceQueueView.xaml') -Raw
$queueViewCodeBehindSource = Get-Content -LiteralPath (Join-Path $repositoryRoot 'src\HerdrOps.App\Views\ComplianceQueueView.xaml.cs') -Raw
$widgetSource = Get-Content -LiteralPath (Join-Path $repositoryRoot 'src\HerdrOps.App\Widgets\LiveWidgetState.cs') -Raw
$widgetActionsSource = Get-Content -LiteralPath (Join-Path $repositoryRoot 'src\HerdrOps.App\Widgets\WidgetActions.cs') -Raw
$reviewIpcIntegrationTestSource = Get-Content -LiteralPath (Join-Path $repositoryRoot 'tests\HerdrOps.IntegrationTests\ReviewCommandIpcIntegrationTests.cs') -Raw
$reviewStorageTestSource = Get-Content -LiteralPath (Join-Path $repositoryRoot 'tests\HerdrOps.IntegrationTests\ComplianceReviewStorageTests.cs') -Raw
$processAuthorizerTestSource = Get-Content -LiteralPath (Join-Path $repositoryRoot 'tests\HerdrOps.IntegrationTests\HerdrReviewClientProcessAuthorizerTests.cs') -Raw
$timeoutTestSource = Get-Content -LiteralPath (Join-Path $repositoryRoot 'tests\HerdrOps.IntegrationTests\ReviewCommandIpcTimeoutIntegrationTests.cs') -Raw
$handlerTimeoutTestSource = Get-Content -LiteralPath (Join-Path $repositoryRoot 'tests\HerdrOps.IntegrationTests\ReviewCommandHandlerTimeoutIntegrationTests.cs') -Raw
$coordinatorTestSource = Get-Content -LiteralPath (Join-Path $repositoryRoot 'tests\HerdrOps.IntegrationTests\ComplianceReviewCommandCoordinatorTests.cs') -Raw
$queueStateTestSource = Get-Content -LiteralPath (Join-Path $repositoryRoot 'tests\HerdrOps.IntegrationTests\ComplianceQueueStateTests.cs') -Raw
$stateHubTestSource = Get-Content -LiteralPath (Join-Path $repositoryRoot 'tests\HerdrOps.IntegrationTests\ComplianceReviewStateHubTests.cs') -Raw
$requestRecord = [Regex]::Match(
    $commandContractSource,
    '(?s)public sealed record HerdrOpsReviewCommandRequest\(.*?\);').Value
$cliInputRecord = [Regex]::Match(
    $commandContractSource,
    '(?s)public sealed record HerdrOpsReviewCliCommandInput\(.*?\);').Value
$requiredMarkers = [ordered]@{
    CiRunsRoleDistinctReviewGate =
        $ciSource.Contains('Run v0.5 role-distinct review implementation gate', [StringComparison]::Ordinal) -and
        $ciSource.Contains('./tools/Test-V05RoleDistinctReview.ps1 -Configuration Release -SkipBuild', [StringComparison]::Ordinal)
    ContractNoRuntimeCredit = $contractSource.Contains('NoRuntimeCredit', [StringComparison]::Ordinal)
    ContractSameUserBoundary =
        $contractSource.Contains('operational identity continuity and correlation only', [StringComparison]::Ordinal) -and
        $contractSource.Contains('not cryptographic publisher authentication, code-signing proof, or cryptographic process provenance', [StringComparison]::Ordinal) -and
        $contractSource.Contains('PROC_THREAD_ATTRIBUTE_PARENT_PROCESS', [StringComparison]::Ordinal) -and
        $contractSource.Contains('root PIDs but not their creation identities', [StringComparison]::Ordinal) -and
        $contractSource.Contains('compromised same-user Herdr descendant', [StringComparison]::Ordinal)
    ContractExpectedSequence = $requestRecord.Contains('long ExpectedSequence', [StringComparison]::Ordinal) -and
        $cliInputRecord.Contains('long ExpectedSequence', [StringComparison]::Ordinal)
    ExternalRequestRejectsOccurredUtc =
        -not [string]::IsNullOrWhiteSpace($requestRecord) -and
        -not $requestRecord.Contains('OccurredUtc', [StringComparison]::Ordinal)
    ExternalCliRejectsOccurredUtc =
        -not [string]::IsNullOrWhiteSpace($cliInputRecord) -and
        -not $cliInputRecord.Contains('OccurredUtc', [StringComparison]::Ordinal)
    StrictCliInputRejectsUnknownFields = $commandJsonSource.Contains(
        'UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow',
        [StringComparison]::Ordinal)
    DedicatedCurrentUserPipeName =
        $pipeNameSource.Contains('HerdrOps.ReviewCommandIpc.v1|', [StringComparison]::Ordinal) -and
        $pipeNameSource.Contains('herdrops-review-v1-', [StringComparison]::Ordinal)
    CoreOwnsReviewTime =
        $workflowServiceSource.Contains('private readonly TimeProvider _timeProvider', [StringComparison]::Ordinal) -and
        $workflowServiceSource.Contains('_timeProvider = timeProvider ?? TimeProvider.System', [StringComparison]::Ordinal) -and
        $workflowServiceSource.Contains('ComplianceReviewCommandMapper.MapRequest', [StringComparison]::Ordinal) -and
        $workflowServiceSource.Contains('_timeProvider.GetUtcNow()', [StringComparison]::Ordinal)
    MapperCarriesCoreOccurredUtc =
        $mapperSource.Contains('DateTimeOffset occurredUtc', [StringComparison]::Ordinal) -and
        $mapperSource.Contains('occurredUtc,', [StringComparison]::Ordinal)
    DomainRequiresExactIncidentRevision =
        $domainSource.Contains('normalizedCommand.ExpectedState != normalizedIncident.State', [StringComparison]::Ordinal) -and
        $domainSource.Contains('normalizedCommand.ExpectedSequence != normalizedIncident.Sequence', [StringComparison]::Ordinal)
    DomainSelfReview = $domainSource.Contains('ComplianceReviewRejectionCode.SelfReview', [StringComparison]::Ordinal)
    DomainStaleState = $domainSource.Contains('ComplianceReviewRejectionCode.StaleState', [StringComparison]::Ordinal)
    StorageImmediateTransaction = $storageSource.Contains('BeginTransaction(deferred: false)', [StringComparison]::Ordinal)
    SchemaVersionFourIsCurrent = $storeModelsSource.Contains('CurrentSchemaVersion = 4', [StringComparison]::Ordinal)
    StorageCurrentAuthority = $storageSource.Contains('ReadCurrentAssignmentRoleCore', [StringComparison]::Ordinal)
    RoleHistoryAppendOnly =
        $assignmentStorageSource.Contains('assignment_actor_role_history_reject_update', [StringComparison]::Ordinal) -and
        $assignmentStorageSource.Contains('assignment_actor_role_history_reject_delete', [StringComparison]::Ordinal) -and
        $assignmentStorageSource.Contains('assignment_actor_role_history is append-only', [StringComparison]::Ordinal)
    LatestRoleProjectionGuards =
        $migrationSource.Contains('assignment_current_actor_roles_v4_validate_insert', [StringComparison]::Ordinal) -and
        $migrationSource.Contains('assignment_current_actor_roles_v4_validate_update', [StringComparison]::Ordinal) -and
        $migrationSource.Contains('assignment_current_actor_roles_v4_reject_delete', [StringComparison]::Ordinal) -and
        $migrationSource.Contains('latest immutable role observation', [StringComparison]::Ordinal) -and
        $storageSource.Contains('SELECT MAX(sequence)', [StringComparison]::Ordinal)
    SqlAuditHashTriggerValidation =
        $storageSource.Contains('CreateFunction<int>', [StringComparison]::Ordinal) -and
        $storageSource.Contains('herdrops_review_audit_valid', [StringComparison]::Ordinal) -and
        $migrationSource.Contains('compliance_review_events_validate_insert', [StringComparison]::Ordinal) -and
        $migrationSource.Contains('herdrops_review_audit_valid(', [StringComparison]::Ordinal) -and
        $migrationSource.Contains('NEW.audit_json_sha256', [StringComparison]::Ordinal)
    SqlIncidentAndEventEvidenceMembershipAndReplayValidation =
        $migrationSource.Contains('registration_json TEXT NOT NULL', [StringComparison]::Ordinal) -and
        $migrationSource.Contains('compliance_review_incident_evidence_validate_insert', [StringComparison]::Ordinal) -and
        $migrationSource.Contains("json_each(incident.registration_json, '$.initialEvidenceIdentitySha256s')", [StringComparison]::Ordinal) -and
        $migrationSource.Contains('compliance_review_event_evidence_validate_insert', [StringComparison]::Ordinal) -and
        $migrationSource.Contains("json_each(event.audit_json, '$.evidenceIdentitySha256s')", [StringComparison]::Ordinal) -and
        $migrationSource.Contains('declared.value = NEW.evidence_identity_sha256', [StringComparison]::Ordinal) -and
        $storageSource.Contains('SerializeComplianceReviewRegistration(candidate)', [StringComparison]::Ordinal) -and
        $storageSource.Contains('SerializeComplianceReviewRegistration(normalized)', [StringComparison]::Ordinal) -and
        $storageSource.Contains('registration JSON, columns, or evidence links disagree', [StringComparison]::Ordinal) -and
        $storageSource.Contains('EnsureSameRegistration(candidate, existing);', [StringComparison]::Ordinal) -and
        $storageSource.Contains('ValidateComplianceReviewHistory(existing, transaction);', [StringComparison]::Ordinal) -and
        $storageSource.Contains('private HerdrComplianceReviewWriteResult AppendComplianceReviewCommand', [StringComparison]::Ordinal) -and
        $storageSource.Contains('private void ValidateComplianceReviewHistory(', [StringComparison]::Ordinal) -and
        $storageSource.Contains('private IReadOnlyList<ComplianceReviewAuditEvent> ReadComplianceReviewAuditCore(', [StringComparison]::Ordinal)
    SqlTriggerCurrentAuthority =
        $migrationSource.Contains('FROM assignment_current_actor_roles authority', [StringComparison]::Ordinal) -and
        $migrationSource.Contains('FROM assignment_actor_role_history history', [StringComparison]::Ordinal)
    PipeClientProcessId = $serverSource.Contains('GetNamedPipeClientProcessId', [StringComparison]::Ordinal)
    UnattestedServerConstructorIsInternal = $serverSource.Contains('internal HerdrOpsReviewCommandPipeServer(', [StringComparison]::Ordinal)
    ServerHandshakeDeadline =
        $serverSource.Contains('HandshakeTimeout', [StringComparison]::Ordinal) -and
        $serverSource.Contains('_options.HandshakeTimeout', [StringComparison]::Ordinal)
    ServerOperationDeadline =
        $serverSource.Contains('OperationTimeout', [StringComparison]::Ordinal) -and
        $serverSource.Contains('_options.OperationTimeout', [StringComparison]::Ordinal)
    ServerDeadlineUsesLinkedCancellation =
        $serverSource.Contains('CreateLinkedTokenSource', [StringComparison]::Ordinal) -and
        $serverSource.Contains('readCancellation.CancelAfter(timeout)', [StringComparison]::Ordinal) -and
        $serverSource.Contains('serverCancellationToken.IsCancellationRequested', [StringComparison]::Ordinal)
    ServerDeadlineBounds = $serverSource.Contains('ValidateReadDeadline', [StringComparison]::Ordinal)
    ServerResponseWriteDeadlines =
        [Regex]::Matches($serverSource, 'WriteFrameWithDeadlineAsync\(').Count -ge 3 -and
        [Regex]::Matches($serverSource, 'WriteFrameWithOperationDeadlineAsync\(').Count -ge 4 -and
        $serverSource.Contains('accepted,', [StringComparison]::Ordinal) -and
        $serverSource.Contains('resultEnvelope,', [StringComparison]::Ordinal) -and
        $serverSource.Contains('envelope,', [StringComparison]::Ordinal) -and
        $serverSource.Contains('WriteFrameAsync', [StringComparison]::Ordinal)
    ServerWriteDeadlineUsesLinkedCancellation =
        $serverSource.Contains('using var writeCancellation = CancellationTokenSource.CreateLinkedTokenSource', [StringComparison]::Ordinal) -and
        $serverSource.Contains('writeCancellation.CancelAfter(timeout)', [StringComparison]::Ordinal) -and
        $serverSource.Contains('writeCancellation.Token', [StringComparison]::Ordinal)
    ServerOperationDeadlineSpansAuthorizationHandlerAndWrite =
        [Regex]::Matches(
            $serverSource,
            'using var operationDeadline = CreateOperationDeadline\(cancellationToken\);').Count -eq 1 -and
        $serverSource.Contains('ReadFrameWithOperationDeadlineAsync(', [StringComparison]::Ordinal) -and
        $serverSource.Contains('IsClientActorAuthorizedAsync(', [StringComparison]::Ordinal) -and
        $serverSource.Contains('InvokeHandlerWithOperationDeadlineAsync(', [StringComparison]::Ordinal) -and
        $serverSource.Contains('WriteFrameWithOperationDeadlineAsync(', [StringComparison]::Ordinal) -and
        $serverSource.Contains('operationDeadline.Token', [StringComparison]::Ordinal)
    ServerDetachedDelegateBudgetRetainsPermitUntilCompletion =
        $serverSource.Contains('MaximumDetachedDelegateConcurrency', [StringComparison]::Ordinal) -and
        $serverSource.Contains('_detachedDelegateSlots', [StringComparison]::Ordinal) -and
        $serverSource.Contains('.WaitAsync(operationDeadline.Token)', [StringComparison]::Ordinal) -and
        $serverSource.Contains('handlerTask = Task.Run(', [StringComparison]::Ordinal) -and
        $serverSource.Contains('_detachedDelegateTasks.TryAdd(handlerTask, 0)', [StringComparison]::Ordinal) -and
        $serverSource.Contains('_detachedDelegateTasks.TryRemove(completedTask, out _)', [StringComparison]::Ordinal) -and
        $serverSource.Contains('operationDeadline.RetainDetachedTask(handlerTask)', [StringComparison]::Ordinal) -and
        $serverSource.Contains('await AwaitDetachedDelegatesAsync()', [StringComparison]::Ordinal)
    WorkflowAndStorageCancellationBoundaries =
        $workflowServiceSource.Contains('Monitor.TryEnter(_sync, TimeSpan.FromMilliseconds(25))', [StringComparison]::Ordinal) -and
        $workflowServiceSource.Contains('cancellationToken.ThrowIfCancellationRequested()', [StringComparison]::Ordinal) -and
        $storageSource.Contains('Monitor.TryEnter(_sync, TimeSpan.FromMilliseconds(25))', [StringComparison]::Ordinal) -and
        $storageSource.Contains('ComplianceReviewBusyTimeoutCeilingSeconds = 1', [StringComparison]::Ordinal) -and
        $storageSource.Contains('ComplianceReviewBusySliceMilliseconds = 50', [StringComparison]::Ordinal) -and
        $storageSource.Contains('command.CommandTimeout = Math.Min(', [StringComparison]::Ordinal) -and
        $storageSource.Contains('BeginComplianceReviewWriteTransaction(', [StringComparison]::Ordinal) -and
        $storageSource.Contains('INSERT OR IGNORE INTO compliance_review_incidents(', [StringComparison]::Ordinal) -and
        $storageSource.Contains('ExecuteComplianceReviewWriteLockSlice(', [StringComparison]::Ordinal) -and
        $storageSource.Contains('sqlite3_busy_timeout(', [StringComparison]::Ordinal) -and
        $storageSource.Contains('sqlite3_step(', [StringComparison]::Ordinal) -and
        $storageSource.Contains('ComplianceReviewBusySliceObserved', [StringComparison]::Ordinal) -and
        $storageSource.Contains('OperationCanceledException', [StringComparison]::Ordinal) -and
        $serverSource.Contains('SqliteException', [StringComparison]::Ordinal)
    ServerUsesCurrentUserPipe = $serverSource.Contains('PipeOptions.CurrentUserOnly', [StringComparison]::Ordinal)
    ServerProcessIdentityUsesOsPid = $serverIdentitySource.Contains('GetNamedPipeServerProcessId', [StringComparison]::Ordinal)
    ServerProcessIdentityChecksCoreImage =
        $serverIdentitySource.Contains('HerdrOps.Core.exe', [StringComparison]::Ordinal) -and
        $serverIdentitySource.Contains('HerdrOps.Core.dll', [StringComparison]::Ordinal) -and
        $serverIdentitySource.Contains('HerdrOps.Core', [StringComparison]::Ordinal) -and
        $serverIdentitySource.Contains('FileVersionInfo.GetVersionInfo', [StringComparison]::Ordinal)
    ServerProcessIdentityChecksHashAndStart =
        $serverIdentitySource.Contains('ComputeFileSha256', [StringComparison]::Ordinal) -and
        $serverIdentitySource.Contains('StartedUtc', [StringComparison]::Ordinal) -and
        $serverIdentitySource.Contains('startedUtcAfter != startedUtcBefore', [StringComparison]::Ordinal) -and
        $serverIdentitySource.Contains('before.LastWriteTimeUtc', [StringComparison]::Ordinal)
    WindowsProcessAncestry = $processSource.Contains('IsSameOrDescendant', [StringComparison]::Ordinal)
    WindowsProcessHeldIdentityAndRunningCheck =
        $processSource.Contains('OpenProcess(', [StringComparison]::Ordinal) -and
        $processSource.Contains('ProcessQueryLimitedInformation | Synchronize', [StringComparison]::Ordinal) -and
        $processSource.Contains('GetProcessTimes(', [StringComparison]::Ordinal) -and
        $processSource.Contains('WaitForSingleObject(', [StringComparison]::Ordinal) -and
        $processSource.Contains('IsProcessRunning(handle)', [StringComparison]::Ordinal) -and
        $processSource.Contains('HeldProcessIdentity', [StringComparison]::Ordinal)
    WindowsProcessStableIdentityParentRecaptureAndStrictOrdering =
        $processSource.Contains('identity.ProcessId == processId', [StringComparison]::Ordinal) -and
        $processSource.Contains('parent.CreationTimeUtcFileTime >=', [StringComparison]::Ordinal) -and
        $processSource.Contains('TryRefreshParentRelationships', [StringComparison]::Ordinal) -and
        $processSource.Contains('heldChain.Select(item => item.ProcessId)', [StringComparison]::Ordinal) -and
        $processSource.Contains('heldChain[index + 1].CreationTimeUtcFileTime >=', [StringComparison]::Ordinal) -and
        $processSource.Contains('current != expected', [StringComparison]::Ordinal) -and
        $processSource.Contains('IsHeldChainStillValid', [StringComparison]::Ordinal) -and
        $processSource.Contains('MaximumHeldProcessCount', [StringComparison]::Ordinal)
    WindowsProcessHeldHandleLifetime =
        $processSource.Contains('using var snapshot = _snapshotFactory.Capture', [StringComparison]::Ordinal) -and
        $processSource.Contains('heldProcess.Handle.Dispose()', [StringComparison]::Ordinal) -and
        $processSource.Contains('_heldProcesses.Clear()', [StringComparison]::Ordinal)
    HerdrPaneProcessInspection = $authorizerSource.Contains('GetPaneProcessInfoAsync', [StringComparison]::Ordinal)
    ProductionProcessAuthorizer = $coreServiceSource.Contains('reviewClientAuthorizer.AuthorizeAsync', [StringComparison]::Ordinal)
    CoreServiceOwnsReviewServerLifetime =
        $coreStateServiceSource.Contains('_reviewCommandServer?.RunAsync', [StringComparison]::Ordinal) -and
        $coreStateServiceSource.Contains('Task.WhenAny', [StringComparison]::Ordinal) -and
        $coreStateServiceSource.Contains('ObserveShutdownAsync(reviewCommandTask)', [StringComparison]::Ordinal)
    AppServerProcessValidation =
        $appPipeClientSource.Contains('ValidateServerProcessAsync(', [StringComparison]::Ordinal) -and
        $appPipeClientSource.Contains('() => _serverProcessValidator(pipe)', [StringComparison]::Ordinal) -and
        $appPipeClientSource.Contains('.WaitAsync(phaseCancellationToken)', [StringComparison]::Ordinal) -and
        $appPipeClientSource.Contains('ServerProcessValidationConcurrencyLimit = 4', [StringComparison]::Ordinal) -and
        $appPipeClientSource.Contains('TaskCreationOptions.DenyChildAttach | TaskCreationOptions.LongRunning', [StringComparison]::Ordinal) -and
        $appPipeClientSource.Contains('ObserveValidationCompletion(validationTask)', [StringComparison]::Ordinal) -and
        $appPipeClientSource.Contains('ServerProcessValidationBudget.Release()', [StringComparison]::Ordinal)
    CliServerProcessValidation =
        $cliPipeClientSource.Contains('ValidateServerProcessAsync(', [StringComparison]::Ordinal) -and
        $cliPipeClientSource.Contains('() => _serverProcessValidator(pipe)', [StringComparison]::Ordinal) -and
        $cliPipeClientSource.Contains('.WaitAsync(phaseCancellationToken)', [StringComparison]::Ordinal) -and
        $cliPipeClientSource.Contains('ServerProcessValidationConcurrencyLimit = 2', [StringComparison]::Ordinal) -and
        $cliPipeClientSource.Contains('TaskCreationOptions.DenyChildAttach | TaskCreationOptions.LongRunning', [StringComparison]::Ordinal) -and
        $cliPipeClientSource.Contains('ObserveValidationCompletion(validationTask)', [StringComparison]::Ordinal) -and
        $cliPipeClientSource.Contains('ServerProcessValidationBudget.Release()', [StringComparison]::Ordinal)
    AppPhaseTimeoutClassification =
        $appPipeClientSource.Contains('connectDeadline = CreatePhaseDeadline(cancellationToken)', [StringComparison]::Ordinal) -and
        $appPipeClientSource.Contains('handshakeDeadline = CreatePhaseDeadline(cancellationToken)', [StringComparison]::Ordinal) -and
        $appPipeClientSource.Contains('operationDeadline = CreatePhaseDeadline(cancellationToken)', [StringComparison]::Ordinal) -and
        $appPipeClientSource.Contains('!cancellationToken.IsCancellationRequested', [StringComparison]::Ordinal) -and
        $appPipeClientSource.Contains('Timed out connecting to the HerdrOps Core review-command service.', [StringComparison]::Ordinal) -and
        $appPipeClientSource.Contains('Timed out during the HerdrOps Core review-command handshake.', [StringComparison]::Ordinal) -and
        $appPipeClientSource.Contains('Timed out waiting for the HerdrOps Core review-command operation.', [StringComparison]::Ordinal) -and
        $appPipeClientSource.Contains('phaseDeadline.CancelAfter(_options.ConnectTimeout)', [StringComparison]::Ordinal)
    CliPhaseTimeoutClassification =
        $cliPipeClientSource.Contains('connectDeadline = CreatePhaseDeadline(cancellationToken)', [StringComparison]::Ordinal) -and
        $cliPipeClientSource.Contains('handshakeDeadline = CreatePhaseDeadline(cancellationToken)', [StringComparison]::Ordinal) -and
        $cliPipeClientSource.Contains('operationDeadline = CreatePhaseDeadline(cancellationToken)', [StringComparison]::Ordinal) -and
        $cliPipeClientSource.Contains('!cancellationToken.IsCancellationRequested', [StringComparison]::Ordinal) -and
        $cliPipeClientSource.Contains('Timed out connecting to the HerdrOps Core review-command service.', [StringComparison]::Ordinal) -and
        $cliPipeClientSource.Contains('Timed out during the HerdrOps Core review-command handshake.', [StringComparison]::Ordinal) -and
        $cliPipeClientSource.Contains('Timed out waiting for the HerdrOps Core review-command operation.', [StringComparison]::Ordinal) -and
        $cliPipeClientSource.Contains('phaseDeadline.CancelAfter(_options.Timeout)', [StringComparison]::Ordinal)
    CliHerdrEnvironment = $cliSource.Contains('HERDR_ENV', [StringComparison]::Ordinal)
    CliPaneIdentity = $cliSource.Contains('HERDR_PANE_ID', [StringComparison]::Ordinal)
    CliHasNoPipeOverride = -not $cliSource.Contains('--pipe-name', [StringComparison]::Ordinal)
    PublicCliDispatcherRoutesReview =
        $cliDispatcherSource.Contains('ComplianceReviewCliCommand.CommandName', [StringComparison]::Ordinal) -and
        $cliDispatcherSource.Contains('return await ComplianceReviewCliCommand.RunAsync', [StringComparison]::Ordinal)
    DispatcherSuccessTestUsesPublicDispatcher =
        $reviewIpcIntegrationTestSource.Contains(
            'CliDerivesReviewerIdentityFromHerdrPaneAndCorePersistsThatAuthority',
            [StringComparison]::Ordinal) -and
        $reviewIpcIntegrationTestSource.Contains(
            'HerdrOps.Cli.HerdrOpsCliCommand.RunAsync',
            [StringComparison]::Ordinal) -and
        $reviewIpcIntegrationTestSource.Contains(
            'HerdrOps.Cli.HerdrOpsCliCommand.SuccessExitCode',
            [StringComparison]::Ordinal)
    AppUsesCurrentUserReviewPipe = $appSource.Contains('HerdrOpsReviewCommandPipeClientOptions.ForCurrentUser()', [StringComparison]::Ordinal)
    AppUsesHerdrPaneIdentity = $appSource.Contains('HERDR_PANE_ID', [StringComparison]::Ordinal)
    LiveCoreCapabilities = $queueSource.Contains('ReadCapabilitiesAsync', [StringComparison]::Ordinal)
    LiveReviewExecution = $queueSource.Contains('ExecuteReviewActionAsync', [StringComparison]::Ordinal)
    UiGenerationGuard =
        $queueSource.Contains('_reviewCapabilityRequestVersion', [StringComparison]::Ordinal) -and
        $queueSource.Contains('_reviewCommandRequestVersion', [StringComparison]::Ordinal) -and
        $queueSource.Contains('_authoritativeIncidentGenerations', [StringComparison]::Ordinal) -and
        $queueSource.Contains('ReviewCommandGuard', [StringComparison]::Ordinal) -and
        $queueSource.Contains('generation != NextAuthoritativeGeneration(guard.IncidentGeneration)', [StringComparison]::Ordinal) -and
        $queueSource.Contains('current.LastAuditEventId != guard.CommandId', [StringComparison]::Ordinal) -and
        $queueSource.Contains('HasSameAuthoritativeIncident(existing, incident)', [StringComparison]::Ordinal) -and
        $queueSource.Contains('Interlocked.Increment', [StringComparison]::Ordinal) -and
        $queueSource.Contains('Volatile.Read', [StringComparison]::Ordinal)
    UiReviewCommandSingleFlight =
        $queueSource.Contains('_reviewCommandInFlight', [StringComparison]::Ordinal) -and
        $queueSource.Contains('Interlocked.CompareExchange(ref _reviewCommandInFlight, 1, 0)', [StringComparison]::Ordinal) -and
        $queueSource.Contains('Volatile.Write(ref _reviewCommandInFlight, 0)', [StringComparison]::Ordinal)
    UiSelectionGuard =
        $queueSource.Contains('SelectedIncident?.IncidentId', [StringComparison]::Ordinal) -and
        $queueSource.Contains('IsCurrentCapabilityRequest', [StringComparison]::Ordinal) -and
        $queueSource.Contains('HasCurrentReviewCapabilities', [StringComparison]::Ordinal)
    UiDisposalGuard =
        $queueSource.Contains('public void Dispose()', [StringComparison]::Ordinal) -and
        $queueSource.Contains('if (_disposed)', [StringComparison]::Ordinal) -and
        $queueSource.Contains('Interlocked.Increment(ref _reviewCommandRequestVersion)', [StringComparison]::Ordinal)
    UiCancellationGuard =
        $queueSource.Contains('catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)', [StringComparison]::Ordinal) -and
        $queueSource.Contains('return false;', [StringComparison]::Ordinal)
    UiSchedulerUsesCancellation =
        $schedulerSource.Contains('InvokeAsync(action, DispatcherPriority.DataBind, cancellationToken)', [StringComparison]::Ordinal)
    CoordinatorPublishesAfterTransportCancellation =
        $coordinatorSource.Contains('CancellationToken.None', [StringComparison]::Ordinal) -and
        $coordinatorSource.Contains('_stateHub.Apply(result)', [StringComparison]::Ordinal)
    CoordinatorBindsAcceptedResultToOriginatingRequest =
        $coordinatorSource.Contains('ValidateResultBinding(request, result)', [StringComparison]::Ordinal) -and
        $coordinatorSource.Contains('result.IsAccepted && result.Incident is not null', [StringComparison]::Ordinal) -and
        $coordinatorSource.Contains('A rejected review-command result cannot carry an unbound incident snapshot.', [StringComparison]::Ordinal) -and
        $coordinatorSource.Contains('result.Incident.IncidentId', [StringComparison]::Ordinal) -and
        $coordinatorSource.Contains('auditEvent.AuditEventId != request.CommandId', [StringComparison]::Ordinal) -and
        $coordinatorSource.Contains('auditEvent.ReviewerActorId', [StringComparison]::Ordinal) -and
        $coordinatorSource.Contains('auditEvent.DecisionKind != request.DecisionKind', [StringComparison]::Ordinal) -and
        $coordinatorSource.Contains('auditEvent.PreviousState != request.ExpectedState', [StringComparison]::Ordinal) -and
        $coordinatorSource.Contains('auditEvent.Sequence != request.ExpectedSequence + 1', [StringComparison]::Ordinal) -and
        $coordinatorSource.Contains('request.Reason.Trim()', [StringComparison]::Ordinal) -and
        $coordinatorSource.Contains('request.EvidenceIdentitySha256s', [StringComparison]::Ordinal) -and
        $coordinatorSource.Contains('result.WasAlreadyPresent', [StringComparison]::Ordinal)
    StateHubIsolatesNonfatalSubscriberFailures =
        $stateHubSource.Contains('handlers.GetInvocationList()', [StringComparison]::Ordinal) -and
        $stateHubSource.Contains('catch (Exception exception) when (!IsFatal(exception))', [StringComparison]::Ordinal) -and
        $stateHubSource.Contains('handler(this, eventArgs)', [StringComparison]::Ordinal) -and
        $stateHubSource.Contains('exception.GetType().FullName', [StringComparison]::Ordinal)
    RemediationTestsArePresentInSource =
        $reviewStorageTestSource.Contains('CorruptedReviewHistoryBlocksIdempotentRegistrationRetry', [StringComparison]::Ordinal) -and
        $reviewStorageTestSource.Contains('OrdinarySqlCannotAppendUndeclaredEvidenceToRegisteredIncident', [StringComparison]::Ordinal) -and
        $reviewStorageTestSource.Contains('RegistrationJsonMismatchFailsClosedOnReadAndIdempotentRetry', [StringComparison]::Ordinal) -and
        $reviewStorageTestSource.Contains('OrdinarySqlCannotAppendUndeclaredEvidenceToAcceptedReviewEvent', [StringComparison]::Ordinal) -and
        $reviewStorageTestSource.Contains('TamperedSequenceOneEvidenceLinksBlockSequenceTwoAppend', [StringComparison]::Ordinal) -and
        $reviewStorageTestSource.Contains('BlockedComplianceReviewOperationObservesCancellationBeforeMutation', [StringComparison]::Ordinal) -and
        $processAuthorizerTestSource.Contains('ExactAdmittedProcessRequiresAStableHeldIdentity', [StringComparison]::Ordinal) -and
        $processAuthorizerTestSource.Contains('DescendantWithMonotonicCreationTimesIsAccepted', [StringComparison]::Ordinal) -and
        $processAuthorizerTestSource.Contains('CreationTimeInversionNearAdmittedRootRejectsPidReuseSimulation', [StringComparison]::Ordinal) -and
        $processAuthorizerTestSource.Contains('IdentityChangeDuringAuthorizationRejectsPidReuseSimulation', [StringComparison]::Ordinal) -and
        $processAuthorizerTestSource.Contains('InaccessibleOrExitedAncestorIsRejectedAndHeldIdentitiesAreDisposed', [StringComparison]::Ordinal) -and
        $processAuthorizerTestSource.Contains('IntermediatePidReuseAfterInitialParentSnapshotIsRejected', [StringComparison]::Ordinal) -and
        $processAuthorizerTestSource.Contains('ChangedIntermediateParentageAfterInitialParentSnapshotIsRejected', [StringComparison]::Ordinal) -and
        $processAuthorizerTestSource.Contains('ParentRecaptureFailureRejectsAndDisposesEveryHeldIdentity', [StringComparison]::Ordinal) -and
        $processAuthorizerTestSource.Contains('MalformedRecapturedSnapshotRejectsAndDisposesEveryHeldIdentity', [StringComparison]::Ordinal) -and
        $processAuthorizerTestSource.Contains('CancellationRequestedAfterPaneInspectionIsObservedBeforeProcessAncestry', [StringComparison]::Ordinal) -and
        $timeoutTestSource.Contains('NonReadingClientWriteTimeoutReleasesClientSlotForLaterLegitimateClient', [StringComparison]::Ordinal) -and
        $timeoutTestSource.Contains('AppHandshakeDeadlineAfterConnectBecomesTimeoutException', [StringComparison]::Ordinal) -and
        $timeoutTestSource.Contains('AppOperationDeadlineAfterHandshakeBecomesTimeoutException', [StringComparison]::Ordinal) -and
        $timeoutTestSource.Contains('AppCallerCancellationAfterConnectRemainsOperationCanceledException', [StringComparison]::Ordinal) -and
        $timeoutTestSource.Contains('AppServerProcessValidationTimeoutIsBoundedAndSendsNoHello', [StringComparison]::Ordinal) -and
        $timeoutTestSource.Contains('AppCallerCancellationDuringServerProcessValidationRemainsOperationCanceledException', [StringComparison]::Ordinal) -and
        $timeoutTestSource.Contains('CliServerProcessValidationTimeoutIsBoundedAndSendsNoHello', [StringComparison]::Ordinal) -and
        $timeoutTestSource.Contains('CliCallerCancellationDuringServerProcessValidationRemainsOperationCanceledException', [StringComparison]::Ordinal) -and
        $timeoutTestSource.Contains('AppServerProcessValidationBudgetCapsStalledValidatorsAndRecovers', [StringComparison]::Ordinal) -and
        $timeoutTestSource.Contains('CliServerProcessValidationBudgetCapsStalledValidatorsAndRecovers', [StringComparison]::Ordinal) -and
        $handlerTimeoutTestSource.Contains('NonCooperativeMutationHandlerTimeoutReleasesClientSlotForLaterClient', [StringComparison]::Ordinal) -and
        $handlerTimeoutTestSource.Contains('CooperativeCapabilitiesHandlerTimeoutReleasesClientSlotForLaterClient', [StringComparison]::Ordinal) -and
        $handlerTimeoutTestSource.Contains('SynchronousMutationHandlerTimeoutReleasesSlotButRetainsDelegatePermit', [StringComparison]::Ordinal) -and
        $handlerTimeoutTestSource.Contains('SynchronousAuthorizerTimeoutReleasesClientSlotForLaterClient', [StringComparison]::Ordinal) -and
        $handlerTimeoutTestSource.Contains('SynchronousDetachedDelegatesStayWithinConfiguredConcurrencyBudget', [StringComparison]::Ordinal) -and
        $handlerTimeoutTestSource.Contains('OperationDeadlineStartsBeforeOperationFrameAndDoesNotReset', [StringComparison]::Ordinal) -and
        $handlerTimeoutTestSource.Contains('RunAsyncWaitsForTimedOutDetachedHandlerBeforeCompletingShutdown', [StringComparison]::Ordinal) -and
        $handlerTimeoutTestSource.Contains('SqliteExceptionFromHandlerProducesStructuredCoreUnavailableError', [StringComparison]::Ordinal) -and
        $queueStateTestSource.Contains('SameIncidentSequenceAdvanceInvalidatesLateRejectedUiResult', [StringComparison]::Ordinal) -and
        $queueStateTestSource.Contains('StaleLateAcceptedResultCannotOverwriteAdvancedSameIncidentUiState', [StringComparison]::Ordinal) -and
        $queueStateTestSource.Contains('SameIncidentReplacementInvalidatesLateUiResult', [StringComparison]::Ordinal) -and
        $queueStateTestSource.Contains('SameSequenceLateRejectedResponseCannotReplaceNewerIncidentAfterGenerationAdvance', [StringComparison]::Ordinal) -and
        $queueStateTestSource.Contains('ConcurrentReviewActionsAreSingleFlightAndDoNotOverwritePendingState', [StringComparison]::Ordinal) -and
        $coordinatorTestSource.Contains('AcceptedResponseWithWrongIncidentFailsClosedBeforePublication', [StringComparison]::Ordinal) -and
        $coordinatorTestSource.Contains('AcceptedResponseWithWrongAuditCommandIdFailsClosedBeforePublication', [StringComparison]::Ordinal) -and
        $coordinatorTestSource.Contains('RejectedResponseWithSameIncidentIdButUnrelatedIncidentTupleFailsClosedBeforePublication', [StringComparison]::Ordinal) -and
        $coordinatorTestSource.Contains('AcceptedResponseWithMismatchedIncidentAndAuditEvidenceFailsClosedBeforePublication', [StringComparison]::Ordinal) -and
        $stateHubTestSource.Contains('ThrowingSubscriberDoesNotStarveLaterConsumersOrReplayNotification', [StringComparison]::Ordinal)
    StateHubRejectsOlderProjection =
        $stateHubSource.Contains('incident.Sequence < existing.Sequence', [StringComparison]::Ordinal) -and
        $stateHubSource.Contains('HasSameCurrentState', [StringComparison]::Ordinal)
    LiveReviewButtonClick = $queueViewSource.Contains('Click="OnReviewActionClick"', [StringComparison]::Ordinal) -and
        $queueViewCodeBehindSource.Contains('ExecuteReviewActionAsync(action)', [StringComparison]::Ordinal)
    UiLiveSetting = $queueViewSource.Contains('AutomationProperties.LiveSetting="Polite"', [StringComparison]::Ordinal)
    WidgetComplianceReviewRoute =
        $widgetSource.Contains('WidgetNotificationRoute', [StringComparison]::Ordinal) -and
        $widgetSource.Contains('compliance-review:', [StringComparison]::Ordinal) -and
        $widgetSource.Contains('WidgetOpenComplianceReviewAutomationFormat', [StringComparison]::Ordinal) -and
        $widgetActionsSource.Contains('ComplianceReviewRoutePrefix', [StringComparison]::Ordinal) -and
        $widgetActionsSource.Contains('TrySelectIncident(incidentId)', [StringComparison]::Ordinal) -and
        $widgetActionsSource.Contains('NavigateTo("compliance-queue")', [StringComparison]::Ordinal)
    WidgetRouteHasBothLanguageEntries =
        [Regex]::Matches(
            $languageCatalogSource,
            '\["WidgetOpenComplianceReviewAutomationFormat"\]').Count -eq 2
    DashboardDisposesReviewState =
        $dashboardSource.Contains('StateChanged -= OnComplianceReviewStateChanged', [StringComparison]::Ordinal) -and
        $dashboardSource.Contains('ComplianceQueue.Dispose()', [StringComparison]::Ordinal)
}
foreach ($marker in $requiredMarkers.GetEnumerator()) {
    if (-not $marker.Value) {
        throw "Required v0.5 role-distinct review source marker is absent: $($marker.Key)"
    }
}

if (-not $SkipBuild) {
    & (Join-Path $PSScriptRoot 'Invoke-Build.ps1') -Configuration $Configuration -VerifyFormat
    if ($LASTEXITCODE -ne 0) {
        throw "v0.5 role-distinct review build gate failed with exit code $LASTEXITCODE."
    }
} else {
    & dotnet format (Join-Path $repositoryRoot 'HerdrOps.sln') --no-restore --verify-no-changes
    if ($LASTEXITCODE -ne 0) {
        throw 'v0.5 role-distinct review formatting verification failed.'
    }
}

$cliAssembly = Join-Path $artifactRoot "bin\HerdrOps.Cli\$($Configuration.ToLowerInvariant())\HerdrOps.Cli.dll"
if (-not (Test-Path -LiteralPath $cliAssembly -PathType Leaf)) {
    throw "The built HerdrOps CLI is missing: $cliAssembly"
}
$pipeOverrideOutput = @(& dotnet $cliAssembly review --input - --pipe-name same-user-fake-server 2>&1)
$pipeOverrideExitCode = $LASTEXITCODE
if ($pipeOverrideExitCode -ne 64 -or
    ($pipeOverrideOutput -join "`n") -notmatch 'invalid-arguments' -or
    ($pipeOverrideOutput -join "`n") -notmatch '\-\-pipe-name') {
    throw "The built review CLI did not reject a public pipe override: exit=$pipeOverrideExitCode output=$($pipeOverrideOutput -join ' | ')"
}

$runId = "$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ', [Globalization.CultureInfo]::InvariantCulture))-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
$gateDirectory = Join-Path $artifactRoot "release-gates\v0.5.0\issue-27\$runId"
$testResultDirectory = Join-Path $gateDirectory 'test-results'
[IO.Directory]::CreateDirectory($testResultDirectory) | Out-Null

$testRuns = @(
    [pscustomobject]@{
        Project = Join-Path $repositoryRoot 'tests\HerdrOps.UnitTests\HerdrOps.UnitTests.csproj'
        Filter = 'FullyQualifiedName=HerdrOps.UnitTests.ComplianceReviewWorkflowTests.RepeatedStateStillRequiresTheExactIncidentSequence|FullyQualifiedName~ComplianceReviewWorkflowTests'
    },
    [pscustomobject]@{
        Project = Join-Path $repositoryRoot 'tests\HerdrOps.ContractTests\HerdrOps.ContractTests.csproj'
        Filter = 'FullyQualifiedName~ReviewCommandIpcContractTests'
    },
    [pscustomobject]@{
        Project = Join-Path $repositoryRoot 'tests\HerdrOps.IntegrationTests\HerdrOps.IntegrationTests.csproj'
        Filter = 'FullyQualifiedName=HerdrOps.IntegrationTests.ComplianceReviewWorkflowServiceTests.IpcUsesCoreTimeAndExactRetryDoesNotDependOnAClientTimestamp|FullyQualifiedName=HerdrOps.IntegrationTests.ReviewCommandIpcIntegrationTests.AppRejectsSameUserPipeServerWhoseProcessIsNotHerdrOpsCore|FullyQualifiedName=HerdrOps.IntegrationTests.ReviewCommandIpcIntegrationTests.CliDerivesReviewerIdentityFromHerdrPaneAndCorePersistsThatAuthority|FullyQualifiedName~ComplianceReviewStorageTests|FullyQualifiedName~ComplianceReviewWorkflowServiceTests|FullyQualifiedName~ReviewCommandIpcIntegrationTests|FullyQualifiedName~ReviewCommandIpcTimeoutIntegrationTests|FullyQualifiedName~ReviewCommandHandlerTimeoutIntegrationTests|FullyQualifiedName~ComplianceReviewCommandCoordinatorTests|FullyQualifiedName~HerdrReviewClientProcessAuthorizerTests|FullyQualifiedName~ComplianceReviewStateHubTests|FullyQualifiedName~ComplianceQueueStateTests|FullyQualifiedName~AssignmentLifecycleStoreTests|FullyQualifiedName~EvidenceAuditStorageTests|FullyQualifiedName~SqliteHerdrStateStoreTests|FullyQualifiedName~UiLanguageCatalogTests'
    }
)
for ($index = 0; $index -lt $testRuns.Count; $index++) {
    $run = $testRuns[$index]
    $logName = "issue-27-$($index + 1).trx"
    & dotnet test $run.Project `
        --configuration $Configuration `
        --no-restore `
        --no-build `
        --artifacts-path $artifactRoot `
        --results-directory $testResultDirectory `
        --logger "trx;LogFileName=$logName" `
        --filter $run.Filter
    if ($LASTEXITCODE -ne 0) {
        throw "v0.5 role-distinct review tests failed: $($run.Project)"
    }
}

$testResults = @(Get-ChildItem -LiteralPath $testResultDirectory -Filter '*.trx' -File)
if ($testResults.Count -ne 3) {
    throw "Expected exactly 3 fresh role-distinct review TRX files, found $($testResults.Count)."
}
$combinedTestLog = ($testResults | ForEach-Object {
    Get-Content -LiteralPath $_.FullName -Raw
}) -join "`n"
$requiredChecks = @(
    'LeaderAndProjectManagerDecisionsRemainSeparatelyAttributable',
    'IncidentSubjectCannotReviewTheirOwnIncident',
    'RolePermissionsAndStateTransitionsAreBothEnforced',
    'RepeatedStateStillRequiresTheExactIncidentSequence',
    'TamperedAuditHashDoesNotValidateOrApply',
    'CliInputIsStrictAndCannotClaimAReviewerIdentity',
    'CapabilitiesEnvelopeRoundTripsWithoutCallerSuppliedRole',
    'SchemaVersionFourCreatesGuardedRoleReviewLedger',
    'RoleDistinctWorkflowPersistsOneHashChainAcrossRestart',
    'UnauthorizedSelfReviewAndStaleStateLeaveNoAuditRows',
    'OrdinarySqlCannotRewriteOrDeleteAcceptedReviewHistory',
    'CorruptedReviewHistoryBlocksIdempotentRegistrationRetry',
    'OrdinarySqlCannotAppendUndeclaredEvidenceToRegisteredIncident',
    'RegistrationJsonMismatchFailsClosedOnReadAndIdempotentRetry',
    'OrdinarySqlCannotAppendUndeclaredEvidenceToAcceptedReviewEvent',
    'TamperedSequenceOneEvidenceLinksBlockSequenceTwoAppend',
    'OrdinarySqlCannotAppendReviewWithHistoricalReviewerAuthority',
    'VersionThreeDatabaseBacksUpAndMigratesForwardWithoutLosingEvidence',
    'SchemaVersionThreeCreatesExactImmutableEvidenceLedgers',
    'FutureSchemaFailsClosedWithoutMigration',
    'ServiceUsesPersistedRoleProvenanceForPmLeaderPmWorkflow',
    'IpcUsesCoreTimeAndExactRetryDoesNotDependOnAClientTimestamp',
    'CapabilitiesExposeOnlyCurrentRoleAndIncidentStateDecisions',
    'UnobservedAndNonAuthorizedRolesFailClosedWithoutAudit',
    'AppCommandTravelsThroughCurrentUserPipeAndCoreAuthorityOnce',
    'LiveQueueUsesCoreCapabilitiesAndLeaderActionUpdatesQueueAndWidget',
    'AppRejectsSameUserPipeServerWhoseProcessIsNotHerdrOpsCore',
    'ClientProcessAuthorizationRejectsBeforeCoreHandlerRuns',
    'CliDerivesReviewerIdentityFromHerdrPaneAndCorePersistsThatAuthority',
    'CliFailsBeforeCoreWhenHerdrPaneIdentityIsUnavailable',
    'CliRejectsPublicReviewPipeOverride',
    'ExactPaneAcceptsClientProcessThatIsAnAdmittedDescendant',
    'MismatchedReturnedPaneIsRejectedBeforeProcessAncestryIsChecked',
    'ExactAdmittedProcessRequiresAStableHeldIdentity',
    'DescendantWithMonotonicCreationTimesIsAccepted',
    'CreationTimeInversionNearAdmittedRootRejectsPidReuseSimulation',
    'IdentityChangeDuringAuthorizationRejectsPidReuseSimulation',
    'InaccessibleOrExitedAncestorIsRejectedAndHeldIdentitiesAreDisposed',
    'IntermediatePidReuseAfterInitialParentSnapshotIsRejected',
    'ChangedIntermediateParentageAfterInitialParentSnapshotIsRejected',
    'ParentRecaptureFailureRejectsAndDisposesEveryHeldIdentity',
    'MalformedRecapturedSnapshotRejectsAndDisposesEveryHeldIdentity',
    'CancellationRequestedAfterPaneInspectionIsObservedBeforeProcessAncestry',
    'InitialRegistrationSameSequenceImmutableConflictThrows',
    'OlderAuditRetryDoesNotRepublishDecisionOrReplaceLatestIncident',
    'HandshakeTimeoutReleasesClientSlotForLaterLegitimateClient',
    'OperationTimeoutReleasesClientSlotForLaterLegitimateClient',
    'NonReadingClientWriteTimeoutReleasesClientSlotForLaterLegitimateClient',
    'AppHandshakeDeadlineAfterConnectBecomesTimeoutException',
    'AppOperationDeadlineAfterHandshakeBecomesTimeoutException',
    'AppCallerCancellationAfterConnectRemainsOperationCanceledException',
    'AppServerProcessValidationTimeoutIsBoundedAndSendsNoHello',
    'AppCallerCancellationDuringServerProcessValidationRemainsOperationCanceledException',
    'CliServerProcessValidationTimeoutIsBoundedAndSendsNoHello',
    'CliCallerCancellationDuringServerProcessValidationRemainsOperationCanceledException',
    'AppServerProcessValidationBudgetCapsStalledValidatorsAndRecovers',
    'CliServerProcessValidationBudgetCapsStalledValidatorsAndRecovers',
    'NonCooperativeMutationHandlerTimeoutReleasesClientSlotForLaterClient',
    'CooperativeCapabilitiesHandlerTimeoutReleasesClientSlotForLaterClient',
    'SynchronousMutationHandlerTimeoutReleasesSlotButRetainsDelegatePermit',
    'SynchronousAuthorizerTimeoutReleasesClientSlotForLaterClient',
    'SynchronousDetachedDelegatesStayWithinConfiguredConcurrencyBudget',
    'OperationDeadlineStartsBeforeOperationFrameAndDoesNotReset',
    'RunAsyncWaitsForTimedOutDetachedHandlerBeforeCompletingShutdown',
    'SqliteExceptionFromHandlerProducesStructuredCoreUnavailableError',
    'BlockedComplianceReviewOperationObservesCancellationBeforeMutation',
    'ShutdownCancelsIdleHandshakeWithoutWaitingForItsDeadline',
    'AuthoritativeResponsePublishesAfterCallerCancellation',
    'CallerCancellationStillCancelsTransportBeforeResponse',
    'AcceptedResponseWithWrongIncidentFailsClosedBeforePublication',
    'AcceptedResponseWithWrongAuditCommandIdFailsClosedBeforePublication',
    'RejectedResponseWithSameIncidentIdButUnrelatedIncidentTupleFailsClosedBeforePublication',
    'AcceptedResponseWithMismatchedIncidentAndAuditEvidenceFailsClosedBeforePublication',
    'SameIncidentSequenceAdvanceInvalidatesLateRejectedUiResult',
    'StaleLateAcceptedResultCannotOverwriteAdvancedSameIncidentUiState',
    'SameIncidentReplacementInvalidatesLateUiResult',
    'SameSequenceLateRejectedResponseCannotReplaceNewerIncidentAfterGenerationAdvance',
    'ConcurrentReviewActionsAreSingleFlightAndDoNotOverwritePendingState',
    'ThrowingSubscriberDoesNotStarveLaterConsumersOrReplayNotification',
    'DisposedStateStopsWeakLanguageRefreshAndDisposeIsIdempotent',
    'SelectionRejectsRowsOutsideVisibleIncidentsAndFailsClosed',
    'SelectionSynchronizesDetailEvidenceAndActionsWhenFiltersChange',
    'SyntheticReviewActionsRejectDirectExecutionWithoutIpc',
    'ThaiIsTheDefaultAndBothCatalogsContainTheSameNonEmptyKeys'
)
foreach ($check in $requiredChecks) {
    if ($combinedTestLog -notmatch [Regex]::Escape($check)) {
        throw "Required v0.5 role-distinct review check is absent from fresh test logs: $check"
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
    'passedButRunAborted',
    'notRunnable',
    'notExecuted',
    'disconnected',
    'warning',
    'completed',
    'inProgress',
    'pending')
$aggregateCounters = [ordered]@{}
foreach ($counterName in $counterNames) {
    $aggregateCounters[$counterName] = [int64]0
}
$aggregateCounters['skipped'] = [int64]0
$testCounterEvidence = @()
foreach ($trxFile in $testResults) {
    [xml]$trx = Get-Content -LiteralPath $trxFile.FullName -Raw
    if ($null -eq $trx.TestRun -or $null -eq $trx.TestRun.ResultSummary) {
        throw "TRX result has no complete ResultSummary: $($trxFile.FullName)"
    }
    $counters = $trx.TestRun.ResultSummary.Counters
    if ($null -eq $counters) {
        throw "TRX result has no complete ResultSummary.Counters element: $($trxFile.FullName)"
    }

    $values = [ordered]@{}
    foreach ($counterName in $counterNames) {
        if (-not $counters.HasAttribute($counterName)) {
            throw "TRX result is missing counter '$counterName': $($trxFile.FullName)"
        }

        $rawValue = $counters.GetAttribute($counterName)
        if ([string]::IsNullOrWhiteSpace($rawValue) -or
            $rawValue -notmatch '^(0|[1-9][0-9]*)$') {
            throw "TRX counter '$counterName' is malformed: '$rawValue' in $($trxFile.FullName)"
        }

        try {
            $values[$counterName] = [int64]$rawValue
        }
        catch {
            throw "TRX counter '$counterName' is outside the supported range: '$rawValue' in $($trxFile.FullName)"
        }

        $aggregateCounters[$counterName] += $values[$counterName]
    }

    $values['skipped'] = $values['notExecuted']
    $aggregateCounters['skipped'] += $values['skipped']
    $nonPassCount = $values['failed'] +
        $values['error'] +
        $values['timeout'] +
        $values['aborted'] +
        $values['inconclusive'] +
        $values['passedButRunAborted'] +
        $values['notRunnable'] +
        $values['notExecuted'] +
        $values['disconnected'] +
        $values['warning']
    if ($values['total'] -le 0 -or
        $values['executed'] -ne $values['total'] -or
        $values['passed'] -ne $values['total'] -or
        $nonPassCount -ne 0 -or
        $values['completed'] -ne 0 -or
        $values['inProgress'] -ne 0 -or
        $values['pending'] -ne 0) {
        throw "Role-distinct review TRX counters are not a complete all-pass result: $($values | Out-String)"
    }

    $testCounterEvidence += [pscustomobject]@{
        Name = $trxFile.Name
        Path = $trxFile.FullName
        Counters = $values
    }
}
if ($aggregateCounters['total'] -le 0 -or
    $aggregateCounters['executed'] -ne $aggregateCounters['total'] -or
    $aggregateCounters['passed'] -ne $aggregateCounters['total'] -or
    $aggregateCounters['failed'] -ne 0 -or
    $aggregateCounters['skipped'] -ne 0 -or
    $aggregateCounters['error'] -ne 0 -or
    $aggregateCounters['timeout'] -ne 0 -or
    $aggregateCounters['aborted'] -ne 0 -or
    $aggregateCounters['inconclusive'] -ne 0 -or
    $aggregateCounters['passedButRunAborted'] -ne 0 -or
    $aggregateCounters['notRunnable'] -ne 0 -or
    $aggregateCounters['notExecuted'] -ne 0 -or
    $aggregateCounters['disconnected'] -ne 0 -or
    $aggregateCounters['warning'] -ne 0 -or
    $aggregateCounters['completed'] -ne 0 -or
    $aggregateCounters['inProgress'] -ne 0 -or
    $aggregateCounters['pending'] -ne 0) {
    throw "Role-distinct review aggregate TRX counters are not a complete all-pass result: $($aggregateCounters | Out-String)"
}

$finalSourceHashes = [ordered]@{}
foreach ($relativePath in $requiredRelativePaths) {
    $path = Join-Path $repositoryRoot $relativePath
    $finalHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    $finalSourceHashes[$relativePath] = $finalHash
    if (-not [string]::Equals(
            $sourceHashes[$relativePath],
            $finalHash,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "A bound role-distinct review file changed during the gate: $relativePath"
    }
}

$verifiedCommit = (& git -C $repositoryRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $verifiedCommit -ne $sourceCommit) {
    throw "Source commit changed during the role-distinct review gate: started=$sourceCommit finished=$verifiedCommit"
}

$finalWorkingTreeStatus = @(& git -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $finalWorkingTreeStatus.Count -ne 0) {
    throw "The source checkout became dirty during the role-distinct review gate. Pending paths: $($finalWorkingTreeStatus -join ', ')"
}

$counterReport = $testCounterEvidence | ForEach-Object {
    $values = $_.Counters
    "TRX $($_.Name) total=$($values['total']) executed=$($values['executed']) passed=$($values['passed']) failed=$($values['failed']) skipped=$($values['skipped']) error=$($values['error']) timeout=$($values['timeout']) aborted=$($values['aborted']) inconclusive=$($values['inconclusive']) passedButRunAborted=$($values['passedButRunAborted']) notRunnable=$($values['notRunnable']) notExecuted=$($values['notExecuted']) disconnected=$($values['disconnected']) warning=$($values['warning']) completed=$($values['completed']) inProgress=$($values['inProgress']) pending=$($values['pending'])"
}

$gateReportPath = Join-Path $gateDirectory 'gate-report.txt'
$gateReport = @(
    'HerdrOps v0.5 Issue #27 Role-distinct Review Implementation Gate',
    "GeneratedUtc: $([DateTime]::UtcNow.ToString('O'))",
    "SourceCommit: $sourceCommit",
    'Result: IMPLEMENTATION READY',
    'ImplementationGate: PASS',
    'IssueAcceptance: PENDING ROLE-DISTINCT HERDR RUNTIME AND INDEPENDENT REVIEW',
    'VersionReleaseGate: PENDING',
    'EvidenceClass: Contract plus BuiltProcess Integration plus local SQLite Integration',
    'RuntimeEvidenceClass: NoRuntimeCredit',
    'ActualHerdrRuntime: NOT OBSERVED / NOT CLAIMED',
    'CoreOwnedAuthorization: VERIFIED BY AUTOMATED TEST',
    'SelfReviewAndUnauthorizedTransitions: REJECTED',
    'ImmutableRoleAttribution: VERIFIED BY AUTOMATED TEST',
    'CliReviewerIdentity: DERIVED FROM HERDR_PANE_ID; PUBLIC PIPE OVERRIDE REJECTED',
    "BuiltCliPipeOverrideExitCode: $pipeOverrideExitCode",
    'OperationalServerAttestation: OS-reported named-pipe server PID; HerdrOps.Core image metadata; executable SHA256; process start-time and file-stability checks',
    'OperationalClientAttestation: OS-reported named-pipe client PID to admitted Herdr pane process tree with complete held process identities, parent recapture, running-state, and creation-time continuity checks; Herdr root PIDs lack creation identities',
    'OperationalIdentityContinuity: Complete held process chain, recaptured parent relationships, running checks, and strictly ordered parent/child creation times are enforced; this is operational identity continuity only, not cryptographic parent provenance',
    'SameUserForgedParentResidual: A same-user process may still forge a parent relationship through Windows process-creation mechanisms; no cryptographic parent provenance or signer proof is claimed',
    'HerdrRootPidResidual: Herdr protocol 19 does not bind reported pane root PIDs to creation identities, so PID recycling before the held-process snapshot is not cryptographically excluded',
    'EvidenceMembershipAndReplay: Immutable registration/audit JSON evidence membership, registration-retry validation, and pre-append full-history replay validation are verified',
    'ResponseDeadlineClassification: One server deadline spans operation-frame read, authorization, handler, and response; shutdown drains tracked detached delegates; bounded delegate and validator budgets retain permits until actual completion',
    'StorageCancellationBoundary: Workflow/store monitor waits are cancellation-aware; compliance SQLite commands use a one-second command/provider/PRAGMA lock-wait ceiling, and write-lock acquisition is a cooperative 50 ms raw-SQLite busy-slice retry loop with the operation token checked between slices; immediate provider interruption, transaction-acquisition cancellation, and rollback of already-running synchronous mutation are not claimed',
    'UiResultBinding: Accepted-only publication, single-flight, same-incident generations, and exact command, reviewer, decision, state, sequence, reason, evidence, task, subject, and audit-hash binding reject stale or mismatched results',
    'StateHubObserverIsolation: Nonfatal subscriber failures are isolated per handler so later consumers continue and duplicate replay remains suppressed',
    'PublisherOrCodeSigningProof: NOT PROVIDED / NOT CLAIMED',
    'ComplianceQueueAndWidgetProjection: VERIFIED FROM CORE CAPABILITY AND RESULT STATE',
    "TestsAggregate: total=$($aggregateCounters['total']) executed=$($aggregateCounters['executed']) passed=$($aggregateCounters['passed']) failed=$($aggregateCounters['failed']) skipped=$($aggregateCounters['skipped'])",
    'PostTestBoundFileRehash: PASS',
    '',
    'SourceSha256AfterTests:'
)
foreach ($entry in $finalSourceHashes.GetEnumerator()) {
    $gateReport += "$($entry.Key): $($entry.Value)"
}
$gateReport += @(
    '',
    'FreshTrxCounters:',
    $counterReport,
    '',
    'Non-authority boundary:',
    'This gate reports operational PID/image/hash/start-time and process-identity continuity attestation only. It does not provide cryptographic parent provenance, cryptographic publisher or code-signing proof, prove distinct running Herdr reviewers, provide actual-Herdr runtime credit, prove complete live incident ingestion or reconnect replay, prove real-data privacy or retention behavior, establish independent acceptance, or prove v0.5 release readiness.'
)
[IO.File]::WriteAllLines(
    $gateReportPath,
    $gateReport,
    [Text.UTF8Encoding]::new($false))

Write-Host "v0.5 Issue #27 role-distinct review implementation gate passed: $($aggregateCounters['passed'])/$($aggregateCounters['total']) tests."
Write-Host "Gate report: $gateReportPath"
