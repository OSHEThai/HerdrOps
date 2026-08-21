[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ProjectManagerTerminalId,

    [Parameter(Mandatory)]
    [string]$LeaderTerminalId,

    [Parameter(Mandatory)]
    [string]$SubjectTerminalId,

    [Parameter(Mandatory)]
    [string]$EvidencePath,

    [string]$HerdrExecutable = (Join-Path $env:LOCALAPPDATA 'Programs\Herdr\bin\herdr.exe'),

    [string]$SocketPath = $env:HERDR_SOCKET_PATH,

    [ValidateRange(20, 300)]
    [int]$DurationSeconds = 60,

    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$traceOrchestrationPath = Join-Path $PSScriptRoot 'lib\V05ComplianceRuntimeTraceOrchestration.ps1'
if (-not (Test-Path -LiteralPath $traceOrchestrationPath -PathType Leaf)) {
    throw "Compliance runtime trace orchestration helper is missing: $traceOrchestrationPath"
}
. $traceOrchestrationPath

function Get-CleanSourceCommit {
    param([Parameter(Mandatory)][string]$Root)

    $commit = (& git -C $Root rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($commit)) {
        throw 'Could not resolve the source commit for v0.5 compliance runtime acceptance.'
    }
    $changes = @(& git -C $Root status --porcelain=v1 --untracked-files=all)
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not inspect the source working tree for v0.5 compliance runtime acceptance.'
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
    throw 'The v0.5 compliance runtime harness must run inside an authorized Herdr pane with HERDR_ENV=1.'
}
if ([string]::IsNullOrWhiteSpace($SocketPath)) {
    throw 'The v0.5 compliance runtime harness requires the active HERDR_SOCKET_PATH.'
}
if (-not (Test-Path -LiteralPath $HerdrExecutable -PathType Leaf)) {
    throw "Installed Herdr executable not found: $HerdrExecutable"
}
if (-not (Test-Path -LiteralPath $EvidencePath -PathType Leaf)) {
    throw "Runtime evidence file not found: $EvidencePath"
}

$terminalIds = @(
    $ProjectManagerTerminalId,
    $LeaderTerminalId,
    $SubjectTerminalId)
$distinctTerminalIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($terminalId in $terminalIds) {
    if (-not [string]::IsNullOrWhiteSpace($terminalId)) {
        [void]$distinctTerminalIds.Add($terminalId)
    }
}
if (@($terminalIds | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -ne 0 -or
    $distinctTerminalIds.Count -ne 3) {
    throw 'Project Manager, Leader, and Subject terminal IDs must be three distinct non-blank values.'
}

$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$artifactRoot = Join-Path $repositoryRoot 'artifacts'
$sourceCommit = Get-CleanSourceCommit -Root $repositoryRoot
$resolvedEvidencePath = (Resolve-Path -LiteralPath $EvidencePath).Path
$evidenceSha256 = (Get-FileHash -LiteralPath $resolvedEvidencePath -Algorithm SHA256).Hash

& (Join-Path $PSScriptRoot 'Invoke-Build.ps1') -Configuration $Configuration -VerifyFormat
if ($LASTEXITCODE -ne 0) {
    throw 'Build and automated tests failed before v0.5 compliance runtime acceptance.'
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
$evidenceDirectory = Join-Path $artifactRoot "runtime-evidence\v0.5.0\issue-28\$runId"
$stateDatabasePath = Join-Path $evidenceDirectory 'herdr-state.db'
$herdrRuntimeReportPath = Join-Path $evidenceDirectory 'herdr-runtime.json'
$reviewTracePath = Join-Path $evidenceDirectory 'compliance-review-trace.json'
$compositeReportPath = Join-Path $evidenceDirectory 'composite-compliance-acceptance.json'
$runtimeGateReportPath = Join-Path $evidenceDirectory 'runtime-gate-report.txt'
$stateOutputPath = Join-Path $evidenceDirectory 'state-core.stdout.txt'
$stateErrorPath = Join-Path $evidenceDirectory 'state-core.stderr.txt'
New-Item -ItemType Directory -Path $evidenceDirectory -Force | Out-Null

$stateArguments = @(
    'serve-herdr-state',
    '--database', $stateDatabasePath,
    '--herdr', $HerdrExecutable,
    '--socket-path', $SocketPath,
    '--seconds', $DurationSeconds,
    '--report', $herdrRuntimeReportPath)

$stateProcess = $null
$incidentId = "INC-V05-ACCEPTANCE-$runId"
$taskId = "TASK-V05-$runId"

$registrationInput = [ordered]@{
    contractVersion = 1
    commandId = [Guid]::NewGuid().ToString('D')
    incidentId = $incidentId
    taskId = $taskId
    subjectActorId = $SubjectTerminalId
    registeredUtc = ([DateTimeOffset]::UtcNow.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ'))
    evidenceIdentitySha256s = @($evidenceSha256)
} | ConvertTo-Json -Depth 5
$registrationInputPath = Join-Path $evidenceDirectory '0-register-incident.json'
[IO.File]::WriteAllText($registrationInputPath, $registrationInput, [Text.UTF8Encoding]::new($false))
$registrationErrorPath = Join-Path $evidenceDirectory '0-register.stderr.txt'

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

    # Step 0: Register the compliance incident through the production registration
    # path once the running service has ingested the runtime evidence identity.
    # Registration requires the cited evidence to already exist in the store, so it
    # is retried with a bounded window until the runtime evidence is available.
    $registrationExit = 1
    $registrationDeadline = [DateTime]::UtcNow.AddSeconds($DurationSeconds)
    $registrationLines = $null
    while ([DateTime]::UtcNow -lt $registrationDeadline) {
        $registrationLines = @(& $coreExecutable `
            'compliance-register-incident' `
            '--database' $stateDatabasePath `
            '--input' $registrationInputPath 2> $registrationErrorPath)
        $registrationExit = $LASTEXITCODE
        if ($registrationExit -eq 0) {
            break
        }

        $registrationError = if (Test-Path -LiteralPath $registrationErrorPath) {
            Get-Content -LiteralPath $registrationErrorPath -Raw
        } else {
            ''
        }
        if ($registrationError -notmatch 'does not exist') {
            throw "Compliance incident registration failed with exit $registrationExit. $registrationError"
        }

        Start-Sleep -Milliseconds 250
    }

    if ($registrationExit -ne 0) {
        throw "Compliance incident registration timed out waiting for runtime evidence '${evidenceSha256}' to be ingested."
    }

    $registrationResult = ($registrationLines -join "`n") | ConvertFrom-Json
    if (-not $registrationResult.registered -or $registrationResult.incidentId -ne $incidentId) {
        throw 'Compliance incident registration did not report a newly registered incident.'
    }

    # Step 1: Attempt unauthorized / self-review action from Subject (Must Fail Closed)
    $selfReviewInput = [ordered]@{
        contractVersion = 1
        commandId = [Guid]::NewGuid().ToString('D')
        incidentId = $incidentId
        expectedState = 'Suspected'
        expectedSequence = 0
        decisionKind = 'Confirm'
        reason = 'Subject attempting self-review confirmation.'
        evidenceIdentitySha256s = @($evidenceSha256)
    } | ConvertTo-Json -Depth 5
    $selfReviewInputPath = Join-Path $evidenceDirectory 'self-review-attempt.json'
    [IO.File]::WriteAllText($selfReviewInputPath, $selfReviewInput, [Text.UTF8Encoding]::new($false))

    $env:HERDR_PANE_ID = $SubjectTerminalId
    $selfReviewErrorPath = Join-Path $evidenceDirectory 'self-review.stderr.txt'
    $selfReviewLines = @(& $cliExecutable review --input $selfReviewInputPath 2> $selfReviewErrorPath)
    $selfReviewExit = $LASTEXITCODE
    if ($selfReviewExit -eq 0) {
        throw 'Self-review action unexpectedly succeeded; must fail closed.'
    }

    # Step 2: PM sends incident to Leader for review
    $sendToLeaderInput = [ordered]@{
        contractVersion = 1
        commandId = [Guid]::NewGuid().ToString('D')
        incidentId = $incidentId
        expectedState = 'Suspected'
        expectedSequence = 0
        decisionKind = 'SendToLeader'
        reason = 'Project Manager routes incident to Leader.'
        evidenceIdentitySha256s = @($evidenceSha256)
    } | ConvertTo-Json -Depth 5
    $sendInputPath = Join-Path $evidenceDirectory '1-send-to-leader.json'
    [IO.File]::WriteAllText($sendInputPath, $sendToLeaderInput, [Text.UTF8Encoding]::new($false))

    $env:HERDR_PANE_ID = $ProjectManagerTerminalId
    $sendErrorPath = Join-Path $evidenceDirectory '1-send.stderr.txt'
    $sendLines = @(& $cliExecutable review --input $sendInputPath 2> $sendErrorPath)
    $sendExit = $LASTEXITCODE
    if ($sendExit -ne 0) {
        $err = if (Test-Path -LiteralPath $sendErrorPath) { Get-Content -LiteralPath $sendErrorPath -Raw } else { '' }
        throw "PM SendToLeader failed with exit $sendExit. $err"
    }

    # Step 3: Leader escalates incident to Project Manager
    $escalateInput = [ordered]@{
        contractVersion = 1
        commandId = [Guid]::NewGuid().ToString('D')
        incidentId = $incidentId
        expectedState = 'PendingLeader'
        expectedSequence = 1
        decisionKind = 'EscalateToProjectManager'
        reason = 'Leader completed technical review and escalates to PM.'
        evidenceIdentitySha256s = @($evidenceSha256)
    } | ConvertTo-Json -Depth 5
    $escalateInputPath = Join-Path $evidenceDirectory '2-escalate.json'
    [IO.File]::WriteAllText($escalateInputPath, $escalateInput, [Text.UTF8Encoding]::new($false))

    $env:HERDR_PANE_ID = $LeaderTerminalId
    $escalateErrorPath = Join-Path $evidenceDirectory '2-escalate.stderr.txt'
    $escalateLines = @(& $cliExecutable review --input $escalateInputPath 2> $escalateErrorPath)
    $escalateExit = $LASTEXITCODE
    if ($escalateExit -ne 0) {
        $err = if (Test-Path -LiteralPath $escalateErrorPath) { Get-Content -LiteralPath $escalateErrorPath -Raw } else { '' }
        throw "Leader Escalate failed with exit $escalateExit. $err"
    }

    # Step 4: PM Confirms incident
    $confirmInput = [ordered]@{
        contractVersion = 1
        commandId = [Guid]::NewGuid().ToString('D')
        incidentId = $incidentId
        expectedState = 'PendingProjectManager'
        expectedSequence = 2
        decisionKind = 'Confirm'
        reason = 'Project Manager confirms the compliance finding.'
        evidenceIdentitySha256s = @($evidenceSha256)
    } | ConvertTo-Json -Depth 5
    $confirmInputPath = Join-Path $evidenceDirectory '3-confirm.json'
    [IO.File]::WriteAllText($confirmInputPath, $confirmInput, [Text.UTF8Encoding]::new($false))

    $env:HERDR_PANE_ID = $ProjectManagerTerminalId
    $confirmErrorPath = Join-Path $evidenceDirectory '3-confirm.stderr.txt'
    $confirmLines = @(& $cliExecutable review --input $confirmInputPath 2> $confirmErrorPath)
    $confirmExit = $LASTEXITCODE
    if ($confirmExit -ne 0) {
        $err = if (Test-Path -LiteralPath $confirmErrorPath) { Get-Content -LiteralPath $confirmErrorPath -Raw } else { '' }
        throw "PM Confirm failed with exit $confirmExit. $err"
    }

    $reviewTraceResult = Invoke-V05ComplianceReviewTraceProducer `
        -CoreExecutable $coreExecutable `
        -StateDatabasePath $stateDatabasePath `
        -ReviewTracePath $reviewTracePath `
        -IncidentId $incidentId

    $waitMilliseconds = ($DurationSeconds + 20) * 1000
    if (-not $stateProcess.WaitForExit($waitMilliseconds)) {
        throw 'Core Herdr state service exceeded the bounded runtime duration.'
    }
    if ($stateProcess.ExitCode -ne 0) {
        throw "Core state service failed with exit code $($stateProcess.ExitCode)."
    }
} finally {
    Stop-StartedProcess -Process $stateProcess
}

if (-not (Test-Path -LiteralPath $herdrRuntimeReportPath -PathType Leaf)) {
    throw "Herdr runtime report is missing: $herdrRuntimeReportPath"
}

# Run composite compliance acceptance command
$compositeErrorPath = Join-Path $evidenceDirectory 'composite.stderr.txt'
$compositeLines = @(& $coreExecutable `
    'compliance-review-acceptance' `
    '--review-trace' $reviewTracePath `
    '--herdr-runtime-report' $herdrRuntimeReportPath `
    '--incident-id' $incidentId `
    '--report' $compositeReportPath 2> $compositeErrorPath)
$compositeExitCode = $LASTEXITCODE
if ($compositeExitCode -ne 0) {
    $compositeError = if (Test-Path -LiteralPath $compositeErrorPath) {
        Get-Content -LiteralPath $compositeErrorPath -Raw
    } else {
        ''
    }
    throw "Composite compliance acceptance failed with exit $compositeExitCode. $compositeError"
}

$composite = Get-Content -LiteralPath $compositeReportPath -Raw | ConvertFrom-Json -Depth 128
if ($composite.EvidenceClassification -ne 'Runtime' -or
    -not [bool]$composite.RuntimeAccepted -or
    [bool]$composite.SessionControlInvoked -or
    -not [bool]$composite.Acceptance.Passed) {
    throw 'The composite compliance report did not pass every runtime acceptance check.'
}

$compositeSha256 = (Get-FileHash -LiteralPath $compositeReportPath -Algorithm SHA256).Hash
$herdrRuntimeSha256 = (Get-FileHash -LiteralPath $herdrRuntimeReportPath -Algorithm SHA256).Hash

$runtimeGateReport = @(
    'HerdrOps v0.5 Issue #28 Compliance Privacy, Retention, and Runtime Acceptance',
    "GeneratedUtc: $([DateTime]::UtcNow.ToString('O'))",
    "SourceCommit: $sourceCommit",
    'Result: PASS',
    'EvidenceClass: Runtime',
    'RuntimeAccepted: true',
    'SessionControlInvoked: false',
    "CompositeRuntimeReportSha256: $compositeSha256",
    "HerdrRuntimeReportSha256: $herdrRuntimeSha256",
    "EvidenceFileSha256: $evidenceSha256",
    "CompositeRuntimeReport: $compositeReportPath",
    "HerdrRuntimeReport: $herdrRuntimeReportPath",
    "ProjectManagerTerminalId: $ProjectManagerTerminalId",
    "LeaderTerminalId: $LeaderTerminalId",
    "SubjectTerminalId: $SubjectTerminalId",
    '',
    'EvidenceBoundary:',
    'This report validates compliance lifecycle routing from suspicion through role-distinct Leader escalation and PM confirmation, retention protection, secret-redacted metadata, and queue consistency against an observed Herdr runtime.',
    'This runtime acceptance report is not packaged release evidence, clean-install validation, or release authorization.',
    'Current-user Named Pipe isolation provides operational attestation only.'
)
$runtimeGateReport | Set-Content -LiteralPath $runtimeGateReportPath -Encoding utf8
$runtimeGateReport | Write-Output
Write-Output "CompositeRuntimeReport: $compositeReportPath"
Write-Output "RuntimeGateReport: $runtimeGateReportPath"
