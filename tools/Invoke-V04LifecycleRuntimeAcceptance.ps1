[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ProjectManagerTerminalId,

    [Parameter(Mandatory)]
    [string]$LeaderTerminalId,

    [Parameter(Mandatory)]
    [string]$WorkerTerminalId,

    [Parameter(Mandatory)]
    [string]$ReviewerTerminalId,

    [Parameter(Mandatory)]
    [string]$EvidencePath,

    [string]$HerdrExecutable = (Join-Path $env:LOCALAPPDATA 'Programs\Herdr\bin\herdr.exe'),

    [string]$SocketPath = $env:HERDR_SOCKET_PATH,

    [ValidateRange(20, 300)]
    [int]$DurationSeconds = 45,

    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

function Get-CleanSourceCommit {
    param([Parameter(Mandatory)][string]$Root)

    $commit = (& git -C $Root rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($commit)) {
        throw 'Could not resolve the source commit for v0.4 runtime acceptance.'
    }
    $changes = @(& git -C $Root status --porcelain=v1 --untracked-files=all)
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not inspect the source working tree for v0.4 runtime acceptance.'
    }
    if ($changes.Count -ne 0) {
        throw "Runtime evidence requires a clean committed checkout. Changes: $($changes -join '; ')"
    }

    return $commit
}

function Wait-ServiceReady {
    param(
        [Parameter(Mandatory)][Diagnostics.Process]$Process,
        [Parameter(Mandatory)][string]$OutputPath,
        [Parameter(Mandatory)][string]$Pattern,
        [Parameter(Mandatory)][string]$ServiceName
    )

    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while ([DateTime]::UtcNow -lt $deadline) {
        $Process.Refresh()
        if ($Process.HasExited) {
            throw "$ServiceName exited before becoming ready."
        }
        if ((Test-Path -LiteralPath $OutputPath -PathType Leaf) -and
            ((Get-Content -LiteralPath $OutputPath -Raw) -match $Pattern)) {
            return
        }
        Start-Sleep -Milliseconds 50
    }

    throw "$ServiceName did not become ready within 10 seconds."
}

function Write-Submission {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][Guid]$EventId,
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][string]$ActorId,
        [Parameter(Mandatory)][string]$ActorRole,
        [Parameter(Mandatory)][DateTimeOffset]$OccurredUtc,
        [Parameter(Mandatory)][string]$Summary,
        [AllowNull()][Nullable[Guid]]$ParentEventId,
        [AllowNull()][string]$TargetAgentId,
        [AllowNull()][Nullable[int]]$ProgressPercent,
        [AllowNull()][string]$EvidenceReference,
        [AllowNull()][string]$EvidenceSha256,
        [AllowNull()][string]$HandoffNote
    )

    $document = [ordered]@{
        contractVersion = 1
        eventId = $EventId.ToString('D')
        taskId = $TaskId
        actorId = $ActorId
        actorRole = $ActorRole
        occurredUtc = $OccurredUtc.UtcDateTime.ToString(
            'yyyy-MM-ddTHH:mm:ss.fffZ',
            [Globalization.CultureInfo]::InvariantCulture)
        summary = $Summary
        parentEventId = if ($null -eq $ParentEventId) { $null } else { $ParentEventId.ToString('D') }
        targetAgentId = if ([string]::IsNullOrEmpty($TargetAgentId)) { $null } else { $TargetAgentId }
        progressPercent = $ProgressPercent
        deviationReason = $null
        evidenceReference = if ([string]::IsNullOrEmpty($EvidenceReference)) { $null } else { $EvidenceReference }
        evidenceSha256 = if ([string]::IsNullOrEmpty($EvidenceSha256)) { $null } else { $EvidenceSha256 }
        handoffNote = if ([string]::IsNullOrEmpty($HandoffNote)) { $null } else { $HandoffNote }
    }
    [IO.File]::WriteAllText(
        $Path,
        ($document | ConvertTo-Json -Depth 8),
        [Text.UTF8Encoding]::new($false))
}

function Invoke-SelfReport {
    param(
        [Parameter(Mandatory)][string]$CliExecutable,
        [Parameter(Mandatory)][string]$EventType,
        [Parameter(Mandatory)][string]$InputPath,
        [Parameter(Mandatory)][string]$PipeName,
        [Parameter(Mandatory)][string]$ResultPath,
        [Parameter(Mandatory)][string]$ErrorPath
    )

    $resultLines = @(& $CliExecutable `
        $EventType `
        '--input' $InputPath `
        '--pipe-name' $PipeName `
        '--timeout-ms' '5000' 2> $ErrorPath)
    $exitCode = $LASTEXITCODE
    $resultJson = $resultLines -join [Environment]::NewLine
    [IO.File]::WriteAllText($ResultPath, $resultJson, [Text.UTF8Encoding]::new($false))
    if ($exitCode -ne 0) {
        $errorText = if (Test-Path -LiteralPath $ErrorPath) {
            Get-Content -LiteralPath $ErrorPath -Raw
        } else {
            ''
        }
        throw "Self-report $EventType failed with exit $exitCode. $errorText"
    }

    $result = $resultJson | ConvertFrom-Json
    if (-not [bool]$result.accepted -or $result.acceptedSource -ne 'HerdrOps.Core') {
        throw "Self-report $EventType did not return an accepted Core identity."
    }
    return $result
}

function Stop-StartedProcess {
    param([AllowNull()][Diagnostics.Process]$Process)

    if ($null -ne $Process) {
        $Process.Refresh()
        if (-not $Process.HasExited) {
            Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
        }
    }
}

if ($env:HERDR_ENV -ne '1') {
    throw 'The v0.4 lifecycle runtime harness must run inside an authorized Herdr pane with HERDR_ENV=1.'
}
if ([string]::IsNullOrWhiteSpace($SocketPath)) {
    throw 'The v0.4 lifecycle runtime harness requires the active HERDR_SOCKET_PATH.'
}
if (-not (Test-Path -LiteralPath $HerdrExecutable -PathType Leaf)) {
    throw "Installed Herdr executable not found: $HerdrExecutable"
}
if (-not (Test-Path -LiteralPath $EvidencePath -PathType Leaf)) {
    throw "Runtime lifecycle evidence file not found: $EvidencePath"
}

$terminalIds = @(
    $ProjectManagerTerminalId,
    $LeaderTerminalId,
    $WorkerTerminalId,
    $ReviewerTerminalId)
$distinctTerminalIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($terminalId in $terminalIds) {
    if (-not [string]::IsNullOrWhiteSpace($terminalId)) {
        [void]$distinctTerminalIds.Add($terminalId)
    }
}
if (@($terminalIds | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -ne 0 -or
    $distinctTerminalIds.Count -ne 4) {
    throw 'Project Manager, Leader, Worker, and Reviewer terminal IDs must be four distinct non-blank values.'
}

throw @'
NO_RUNTIME_CREDIT: the v0.4 lifecycle acceptance harness is disabled until the
self-report service issues server-derived, run-nonce-bound receipts for actions
executed by four distinct Herdr pane process trees. The legacy orchestrator wrote
ActorId and ActorRole into every submission from one process, so its output cannot
prove Project Manager, Leader, Worker, or Reviewer provenance. See
docs/design/implementation/v0.4-distributed-role-provenance.md.
'@

$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$artifactRoot = Join-Path $repositoryRoot 'artifacts'
$sourceCommit = Get-CleanSourceCommit -Root $repositoryRoot
$resolvedEvidencePath = (Resolve-Path -LiteralPath $EvidencePath).Path
$evidenceSha256 = (Get-FileHash -LiteralPath $resolvedEvidencePath -Algorithm SHA256).Hash

& (Join-Path $PSScriptRoot 'Invoke-Build.ps1') -Configuration $Configuration -VerifyFormat
if ($LASTEXITCODE -ne 0) {
    throw 'Build and automated tests failed before v0.4 lifecycle runtime acceptance.'
}

$configurationDirectory = $Configuration.ToLowerInvariant()
$coreExecutable = Join-Path $artifactRoot "bin\HerdrOps.Core\$configurationDirectory\HerdrOps.Core.exe"
$cliExecutable = Join-Path $artifactRoot "bin\HerdrOps.Cli\$configurationDirectory\HerdrOps.Cli.exe"
foreach ($executable in @($coreExecutable, $cliExecutable)) {
    if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
        throw "Required runtime executable not found: $executable"
    }
}

$runId = "$([DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssZ'))-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
$evidenceDirectory = Join-Path $artifactRoot "runtime-evidence\v0.4.0\issue-22\$runId"
$submissionDirectory = Join-Path $evidenceDirectory 'submissions'
$resultDirectory = Join-Path $evidenceDirectory 'results'
$stateDatabasePath = Join-Path $evidenceDirectory 'herdr-state.db'
$lifecycleDatabasePath = Join-Path $evidenceDirectory 'assignment-lifecycle.db'
$herdrRuntimeReportPath = Join-Path $evidenceDirectory 'herdr-runtime.json'
$lifecycleTracePath = Join-Path $evidenceDirectory 'lifecycle-trace.json'
$compositeReportPath = Join-Path $evidenceDirectory 'composite-runtime-acceptance.json'
$runtimeGateReportPath = Join-Path $evidenceDirectory 'runtime-gate-report.txt'
$stateOutputPath = Join-Path $evidenceDirectory 'state-core.stdout.txt'
$stateErrorPath = Join-Path $evidenceDirectory 'state-core.stderr.txt'
$lifecycleOutputPath = Join-Path $evidenceDirectory 'lifecycle-core.stdout.txt'
$lifecycleErrorPath = Join-Path $evidenceDirectory 'lifecycle-core.stderr.txt'
$compositeOutputPath = Join-Path $evidenceDirectory 'composite.stdout.txt'
$compositeErrorPath = Join-Path $evidenceDirectory 'composite.stderr.txt'
New-Item -ItemType Directory -Path $submissionDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $resultDirectory -Force | Out-Null

$pipeName = "herdrops-v04-lifecycle-$([Guid]::NewGuid().ToString('N'))"
$stateArguments = @(
    'serve-herdr-state',
    '--database', $stateDatabasePath,
    '--herdr', $HerdrExecutable,
    '--socket-path', $SocketPath,
    '--seconds', $DurationSeconds,
    '--report', $herdrRuntimeReportPath)
$lifecycleArguments = @(
    'serve-self-reports',
    '--known-task', 'TASK-115',
    '--known-task', 'TASK-404',
    '--pipe-name', $pipeName,
    '--database', $lifecycleDatabasePath,
    '--seconds', $DurationSeconds,
    '--trace', $lifecycleTracePath)

$stateProcess = $null
$lifecycleProcess = $null
try {
    $stateProcess = Start-Process `
        -FilePath $coreExecutable `
        -ArgumentList $stateArguments `
        -RedirectStandardOutput $stateOutputPath `
        -RedirectStandardError $stateErrorPath `
        -WindowStyle Hidden `
        -PassThru
    Wait-ServiceReady `
        -Process $stateProcess `
        -OutputPath $stateOutputPath `
        -Pattern 'Core state service starting' `
        -ServiceName 'Core Herdr state service'

    $lifecycleProcess = Start-Process `
        -FilePath $coreExecutable `
        -ArgumentList $lifecycleArguments `
        -RedirectStandardOutput $lifecycleOutputPath `
        -RedirectStandardError $lifecycleErrorPath `
        -WindowStyle Hidden `
        -PassThru
    Wait-ServiceReady `
        -Process $lifecycleProcess `
        -OutputPath $lifecycleOutputPath `
        -Pattern 'self-report service ready' `
        -ServiceName 'Core self-report service'

    $ids = 1..10 | ForEach-Object { [Guid]::NewGuid() }
    $baseOccurredUtc = [DateTimeOffset]::UtcNow.AddSeconds(-20)
    $submissions = @(
        [pscustomobject]@{ Type = 'acknowledgement'; EventId = $ids[0]; Task = 'TASK-404'; Actor = "orphan-$runId"; Role = 'Worker'; Summary = 'Retain one orphan acknowledgement for runtime acceptance.'; Parent = [Guid]::NewGuid(); Target = $null; Progress = $null; Evidence = $null; EvidenceHash = $null; Handoff = $null },
        [pscustomobject]@{ Type = 'assignment'; EventId = $ids[1]; Task = 'TASK-115'; Actor = $ProjectManagerTerminalId; Role = 'Project Manager'; Summary = 'Assign the runtime acceptance task to the Backend Leader.'; Parent = $null; Target = $LeaderTerminalId; Progress = $null; Evidence = $null; EvidenceHash = $null; Handoff = $null },
        [pscustomobject]@{ Type = 'acknowledgement'; EventId = $ids[2]; Task = 'TASK-115'; Actor = $LeaderTerminalId; Role = 'Backend Leader'; Summary = 'The Backend Leader acknowledges the assignment.'; Parent = $ids[1]; Target = $null; Progress = $null; Evidence = $null; EvidenceHash = $null; Handoff = $null },
        [pscustomobject]@{ Type = 'delegation'; EventId = $ids[3]; Task = 'TASK-115'; Actor = $LeaderTerminalId; Role = 'Backend Leader'; Summary = 'Delegate runtime acceptance work to the Backend Worker.'; Parent = $ids[2]; Target = $WorkerTerminalId; Progress = $null; Evidence = $null; EvidenceHash = $null; Handoff = $null },
        [pscustomobject]@{ Type = 'acknowledgement'; EventId = $ids[4]; Task = 'TASK-115'; Actor = $WorkerTerminalId; Role = 'Backend Worker'; Summary = 'The Backend Worker acknowledges the delegated task.'; Parent = $ids[3]; Target = $null; Progress = $null; Evidence = $null; EvidenceHash = $null; Handoff = $null },
        [pscustomobject]@{ Type = 'progress'; EventId = $ids[5]; Task = 'TASK-115'; Actor = $WorkerTerminalId; Role = 'Backend Worker'; Summary = 'The implementation reaches one hundred percent.'; Parent = $ids[4]; Target = $null; Progress = 100; Evidence = $null; EvidenceHash = $null; Handoff = $null },
        [pscustomobject]@{ Type = 'evidence'; EventId = $ids[6]; Task = 'TASK-115'; Actor = $WorkerTerminalId; Role = 'Backend Worker'; Summary = 'Submit the runtime verification evidence.'; Parent = $ids[5]; Target = $null; Progress = $null; Evidence = $resolvedEvidencePath; EvidenceHash = $evidenceSha256; Handoff = $null },
        [pscustomobject]@{ Type = 'handoff'; EventId = $ids[7]; Task = 'TASK-115'; Actor = $WorkerTerminalId; Role = 'Backend Worker'; Summary = 'Hand off completed implementation and evidence to the Reviewer.'; Parent = $ids[6]; Target = $ReviewerTerminalId; Progress = $null; Evidence = $null; EvidenceHash = $null; Handoff = 'Implementation and evidence are ready for independent review.' },
        [pscustomobject]@{ Type = 'acknowledgement'; EventId = $ids[8]; Task = 'TASK-115'; Actor = $ReviewerTerminalId; Role = 'Reviewer'; Summary = 'The Reviewer acknowledges the handoff.'; Parent = $ids[7]; Target = $null; Progress = $null; Evidence = $null; EvidenceHash = $null; Handoff = $null },
        [pscustomobject]@{ Type = 'progress'; EventId = $ids[9]; Task = 'TASK-115'; Actor = "mismatch-$runId"; Role = 'Worker'; Summary = 'Retain one current-assignee mismatch for runtime acceptance.'; Parent = $ids[8]; Target = $null; Progress = 100; Evidence = $null; EvidenceHash = $null; Handoff = $null })

    $acceptedResults = @()
    for ($index = 0; $index -lt $submissions.Count; $index++) {
        $submission = $submissions[$index]
        $inputPath = Join-Path $submissionDirectory "$($index + 1)-$($submission.Type).json"
        $resultPath = Join-Path $resultDirectory "$($index + 1)-$($submission.Type).json"
        $errorPath = Join-Path $resultDirectory "$($index + 1)-$($submission.Type).stderr.txt"
        Write-Submission `
            -Path $inputPath `
            -EventId $submission.EventId `
            -TaskId $submission.Task `
            -ActorId $submission.Actor `
            -ActorRole $submission.Role `
            -OccurredUtc $baseOccurredUtc.AddSeconds($index) `
            -Summary $submission.Summary `
            -ParentEventId $submission.Parent `
            -TargetAgentId $submission.Target `
            -ProgressPercent $submission.Progress `
            -EvidenceReference $submission.Evidence `
            -EvidenceSha256 $submission.EvidenceHash `
            -HandoffNote $submission.Handoff
        $acceptedResults += Invoke-SelfReport `
            -CliExecutable $cliExecutable `
            -EventType $submission.Type `
            -InputPath $inputPath `
            -PipeName $pipeName `
            -ResultPath $resultPath `
            -ErrorPath $errorPath
    }

    if ($acceptedResults.Count -ne 10) {
        throw "Expected ten accepted CLI results, observed $($acceptedResults.Count)."
    }

    $waitMilliseconds = ($DurationSeconds + 20) * 1000
    if (-not $stateProcess.WaitForExit($waitMilliseconds)) {
        throw 'Core Herdr state service exceeded the bounded runtime duration.'
    }
    if (-not $lifecycleProcess.WaitForExit($waitMilliseconds)) {
        throw 'Core self-report service exceeded the bounded runtime duration.'
    }
    if ($stateProcess.ExitCode -ne 0 -or $lifecycleProcess.ExitCode -ne 0) {
        throw "A Core runtime service failed: state=$($stateProcess.ExitCode) lifecycle=$($lifecycleProcess.ExitCode)."
    }
} finally {
    Stop-StartedProcess -Process $lifecycleProcess
    Stop-StartedProcess -Process $stateProcess
}

foreach ($errorFile in @($stateErrorPath, $lifecycleErrorPath)) {
    if ((Test-Path -LiteralPath $errorFile -PathType Leaf) -and
        (Get-Item -LiteralPath $errorFile).Length -ne 0) {
        throw "A Core runtime service wrote stderr: $(Get-Content -LiteralPath $errorFile -Raw)"
    }
}
foreach ($requiredReport in @($herdrRuntimeReportPath, $lifecycleTracePath)) {
    if (-not (Test-Path -LiteralPath $requiredReport -PathType Leaf)) {
        throw "Required runtime report is missing: $requiredReport"
    }
}

$compositeLines = @(& $coreExecutable `
    'assignment-lifecycle-acceptance' `
    '--lifecycle-trace' $lifecycleTracePath `
    '--herdr-runtime-report' $herdrRuntimeReportPath `
    '--task-id' 'TASK-115' `
    '--report' $compositeReportPath 2> $compositeErrorPath)
$compositeExitCode = $LASTEXITCODE
[IO.File]::WriteAllText(
    $compositeOutputPath,
    ($compositeLines -join [Environment]::NewLine),
    [Text.UTF8Encoding]::new($false))
if ($compositeExitCode -ne 0) {
    $compositeError = if (Test-Path -LiteralPath $compositeErrorPath) {
        Get-Content -LiteralPath $compositeErrorPath -Raw
    } else {
        ''
    }
    throw "Composite lifecycle acceptance failed with exit $compositeExitCode. $compositeError"
}

$lifecycleTrace = Get-Content -LiteralPath $lifecycleTracePath -Raw | ConvertFrom-Json
$herdrRuntime = Get-Content -LiteralPath $herdrRuntimeReportPath -Raw | ConvertFrom-Json
$composite = Get-Content -LiteralPath $compositeReportPath -Raw | ConvertFrom-Json
if ($lifecycleTrace.evidenceClassification -ne 'BuiltProcessIntegration' -or
    -not [bool]$lifecycleTrace.durableLifecycleEnabled -or
    @($lifecycleTrace.acceptedEvents).Count -ne 10 -or
    [long]$lifecycleTrace.lifecycleReplay.diagnostics.orphanEventCount -lt 1 -or
    [long]$lifecycleTrace.lifecycleReplay.diagnostics.invalidTransitionCount -lt 1) {
    throw 'The durable lifecycle trace does not contain the required ten-event runtime corpus.'
}
if ($herdrRuntime.EvidenceClassification -ne 'Runtime' -or
    -not [bool]$herdrRuntime.RuntimeObserved -or
    [bool]$herdrRuntime.SessionControlInvoked) {
    throw 'The exact Herdr runtime report did not earn runtime credit without session control.'
}
if ($composite.EvidenceClassification -ne 'Runtime' -or
    -not [bool]$composite.RuntimeAccepted -or
    [bool]$composite.SessionControlInvoked -or
    -not [bool]$composite.Acceptance.Passed) {
    throw 'The composite lifecycle report did not pass every runtime acceptance check.'
}

$expectedAgents = [ordered]@{
    $ProjectManagerTerminalId = 'Project Manager'
    $LeaderTerminalId = 'Backend Leader'
    $WorkerTerminalId = 'Backend Worker'
    $ReviewerTerminalId = 'Reviewer'
}
$actualAgents = @($herdrRuntime.FinalProjectedState.Agents)
foreach ($expectedAgent in $expectedAgents.GetEnumerator()) {
    $matches = @($actualAgents | Where-Object {
        $_.TerminalId -ceq $expectedAgent.Key -and $_.Title -ceq $expectedAgent.Value
    })
    if ($matches.Count -ne 1) {
        throw "Exact running Agent identity and role not observed once: $($expectedAgent.Key) / $($expectedAgent.Value)"
    }
}

$verifiedSourceCommit = Get-CleanSourceCommit -Root $repositoryRoot
if ($verifiedSourceCommit -ne $sourceCommit) {
    throw "Source commit changed during runtime acceptance: started=$sourceCommit finished=$verifiedSourceCommit"
}

$lifecycleTraceSha256 = (Get-FileHash -LiteralPath $lifecycleTracePath -Algorithm SHA256).Hash
$herdrRuntimeSha256 = (Get-FileHash -LiteralPath $herdrRuntimeReportPath -Algorithm SHA256).Hash
$compositeSha256 = (Get-FileHash -LiteralPath $compositeReportPath -Algorithm SHA256).Hash
$runtimeGateReport = @(
    'HerdrOps v0.4 Issue #22 Role-distinct Lifecycle Runtime Acceptance',
    "GeneratedUtc: $([DateTime]::UtcNow.ToString('O'))",
    "SourceCommit: $sourceCommit",
    'Result: PASS',
    'EvidenceClass: Runtime',
    'RuntimeAccepted: true',
    'SessionControlInvoked: false',
    'AcceptedEvents: 10',
    'RoleDistinctAgents: 4',
    "LifecycleTraceSha256: $lifecycleTraceSha256",
    "HerdrRuntimeReportSha256: $herdrRuntimeSha256",
    "CompositeRuntimeReportSha256: $compositeSha256",
    "EvidenceFileSha256: $evidenceSha256",
    "ProjectManagerTerminalId: $ProjectManagerTerminalId",
    "LeaderTerminalId: $LeaderTerminalId",
    "WorkerTerminalId: $WorkerTerminalId",
    "ReviewerTerminalId: $ReviewerTerminalId",
    '',
    'EvidenceBoundary:',
    'This report binds a durable Core lifecycle to exact Project Manager, Backend Leader, Backend Worker, and Reviewer identities and roles observed in one overlapping exact-Herdr runtime. It also proves visible orphan and actor-mismatch handling.',
    'The harness did not create, close, or control Herdr Agent panes. Current-user Named Pipe isolation does not authenticate which same-user process submitted each event.'
)
$runtimeGateReport | Set-Content -LiteralPath $runtimeGateReportPath -Encoding utf8
$runtimeGateReport | Write-Output
Write-Output "CompositeRuntimeReport: $compositeReportPath"
Write-Output "RuntimeGateReport: $runtimeGateReportPath"
