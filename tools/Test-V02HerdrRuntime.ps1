[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$TargetHerdrSocketPath,

    [string]$HerdrExecutable = (Join-Path $env:LOCALAPPDATA 'Programs\Herdr\bin\herdr.exe'),

    [ValidateRange(10, 3600)]
    [int]$DurationSeconds = 120,

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
        throw 'Could not resolve the source commit for the Herdr runtime gate.'
    }
    $changes = @(& git -C $Root status --porcelain --untracked-files=all)
    if ($LASTEXITCODE -ne 0) { throw 'Could not inspect repository status.' }
    if ($changes.Count -ne 0) {
        throw "Herdr runtime evidence requires a clean source checkout. Changes: $($changes -join '; ')"
    }

    return $commit
}

function Get-ControlHerdrServerIdentity {
    param([Parameter(Mandatory)][string]$ExpectedExecutablePath)

    $expectedPath = (Resolve-Path -LiteralPath $ExpectedExecutablePath).Path
    $currentProcessId = [int]$PID
    for ($depth = 0; $depth -lt 32; $depth++) {
        $processInfo = @(Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $currentProcessId")
        if ($processInfo.Count -ne 1) { break }

        $candidate = $processInfo[0]
        $candidatePath = [string]$candidate.ExecutablePath
        $candidateCommandLine = [string]$candidate.CommandLine
        if (-not [string]::IsNullOrWhiteSpace($candidatePath) -and
            [IO.Path]::GetFileName($candidatePath) -eq 'herdr.exe' -and
            $candidateCommandLine -match '(?:^|\s)server(?:\s|$)') {
            $resolvedCandidatePath = (Resolve-Path -LiteralPath $candidatePath).Path
            if (-not [StringComparer]::OrdinalIgnoreCase.Equals($resolvedCandidatePath, $expectedPath)) {
                throw "The Acceptance control pane belongs to an unexpected Herdr executable: $resolvedCandidatePath"
            }

            $runtimeProcess = Get-Process -Id ([int]$candidate.ProcessId) -ErrorAction Stop
            return [pscustomobject]@{
                ProcessId = [int]$candidate.ProcessId
                ProcessStartUtc = $runtimeProcess.StartTime.ToUniversalTime()
                ExecutablePath = $resolvedCandidatePath
                ExecutableSha256 = (Get-FileHash -LiteralPath $resolvedCandidatePath -Algorithm SHA256).Hash
            }
        }

        $parentProcessId = [int]$candidate.ParentProcessId
        if ($parentProcessId -le 0 -or $parentProcessId -eq $currentProcessId) { break }
        $currentProcessId = $parentProcessId
    }

    throw 'The gate process is not descended from a live Herdr server. Run it directly in a fresh Acceptance session pane.'
}

function Test-SameHerdrServerProcess {
    param(
        [Parameter(Mandatory)]$Left,
        [Parameter(Mandatory)]$Right
    )

    $leftStart = ([DateTimeOffset]$Left.ProcessStartUtc).ToUniversalTime()
    $rightStart = ([DateTimeOffset]$Right.ProcessStartUtc).ToUniversalTime()
    return [int]$Left.ProcessId -eq [int]$Right.ProcessId -and
        $leftStart.UtcDateTime.Ticks -eq $rightStart.UtcDateTime.Ticks
}

if ($env:HERDR_ENV -ne '1') {
    throw 'Runtime gate requires an authorized Herdr environment with HERDR_ENV=1.'
}
if ([string]::IsNullOrWhiteSpace($env:HERDR_SOCKET_PATH)) {
    throw 'Runtime gate requires HERDR_SOCKET_PATH from the active Acceptance control pane.'
}
if ([string]::IsNullOrWhiteSpace($env:HERDR_PANE_ID)) {
    throw 'Runtime gate requires HERDR_PANE_ID from the active Acceptance control pane.'
}
if (-not (Get-Command Get-CimInstance -ErrorAction SilentlyContinue)) {
    throw 'Get-CimInstance is required to bind the gate process to its Acceptance control Herdr server.'
}

$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$solutionPath = Join-Path $repositoryRoot 'HerdrOps.sln'
$artifactRoot = Join-Path $repositoryRoot 'artifacts'
$runId = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
$evidenceDirectory = Join-Path $artifactRoot "runtime-evidence\v0.2\issue-7\$runId"
$testResultsDirectory = Join-Path $evidenceDirectory 'test-results'
$tracePath = Join-Path $evidenceDirectory 'actual-herdr-runtime-trace.json'
$gateReportPath = Join-Path $evidenceDirectory 'gate-report.txt'
$sourceCommit = Get-CleanSourceCommit -Root $repositoryRoot

if (-not (Test-Path -LiteralPath $HerdrExecutable -PathType Leaf)) {
    throw "Installed Herdr executable not found: $HerdrExecutable"
}
if (-not (Test-Path -LiteralPath $env:HERDR_SOCKET_PATH -PathType Leaf)) {
    throw "The Acceptance control socket does not exist: $($env:HERDR_SOCKET_PATH)"
}
if (-not (Test-Path -LiteralPath $TargetHerdrSocketPath -PathType Leaf)) {
    throw "The target Agent Lab socket does not exist: $TargetHerdrSocketPath"
}
$controlHerdrSocketPath = (Resolve-Path -LiteralPath $env:HERDR_SOCKET_PATH).Path
$targetHerdrSocketPath = (Resolve-Path -LiteralPath $TargetHerdrSocketPath).Path
if ([StringComparer]::OrdinalIgnoreCase.Equals($controlHerdrSocketPath, $targetHerdrSocketPath)) {
    throw 'Acceptance control and target Agent Lab sockets must be different. Restarting the control session would terminate the gate process.'
}
$controlPaneOutput = @(& $HerdrExecutable pane current --current)
if ($LASTEXITCODE -ne 0 -or $controlPaneOutput.Count -eq 0) {
    throw 'Could not verify the active Acceptance control pane through its Herdr socket.'
}
try {
    $controlPane = ($controlPaneOutput -join [Environment]::NewLine) | ConvertFrom-Json
} catch {
    throw 'The active Acceptance control pane returned invalid JSON.'
}
$observedControlPaneId = [string]$controlPane.result.pane.pane_id
if ([string]::IsNullOrWhiteSpace($observedControlPaneId)) {
    throw 'The active Acceptance control pane response did not contain a pane ID.'
}
if ($observedControlPaneId -ne $env:HERDR_PANE_ID) {
    throw 'Use a fresh, unmoved Acceptance control pane so HERDR_PANE_ID exactly matches pane current --current.'
}
$controlServerIdentity = Get-ControlHerdrServerIdentity -ExpectedExecutablePath $HerdrExecutable
New-Item -ItemType Directory -Path $testResultsDirectory -Force | Out-Null

& dotnet restore $solutionPath --locked-mode --artifacts-path $artifactRoot
if ($LASTEXITCODE -ne 0) { throw 'Locked restore failed.' }
& dotnet build $solutionPath --configuration $Configuration --no-restore --artifacts-path $artifactRoot
if ($LASTEXITCODE -ne 0) { throw 'Build failed.' }

$testProjects = @(
    (Join-Path $repositoryRoot 'tests\HerdrOps.UnitTests\HerdrOps.UnitTests.csproj'),
    (Join-Path $repositoryRoot 'tests\HerdrOps.ContractTests\HerdrOps.ContractTests.csproj'),
    (Join-Path $repositoryRoot 'tests\HerdrOps.IntegrationTests\HerdrOps.IntegrationTests.csproj')
)
foreach ($testProject in $testProjects) {
    & dotnet test $testProject `
        --configuration $Configuration `
        --no-restore `
        --no-build `
        --artifacts-path $artifactRoot `
        --results-directory $testResultsDirectory `
        --logger trx
    if ($LASTEXITCODE -ne 0) { throw "Pre-runtime tests failed: $testProject" }
}

Write-Host "Acceptance control socket: $controlHerdrSocketPath"
Write-Host "Target Agent Lab socket: $targetHerdrSocketPath"
Write-Host 'Runtime trace started. Trigger a genuine Agent-status transition, restart only the target Agent Lab session, wait for reconnect, and trigger another genuine Agent-status transition.'
$coreDll = Join-Path $artifactRoot "bin\HerdrOps.Core\$($Configuration.ToLowerInvariant())\HerdrOps.Core.dll"
& dotnet $coreDll trace-herdr-runtime `
    --herdr $HerdrExecutable `
    --socket-path $targetHerdrSocketPath `
    --seconds $DurationSeconds `
    --report $tracePath
if ($LASTEXITCODE -ne 0) { throw 'Actual Herdr runtime trace command failed.' }

$trace = Get-Content -LiteralPath $tracePath -Raw | ConvertFrom-Json
if ($trace.EvidenceClassification -ne 'Runtime' -or $trace.RuntimeObserved -ne $true) {
    throw 'Trace did not earn actual Herdr runtime credit.'
}
if ($trace.SessionControlInvoked -ne $false) {
    throw 'HerdrOps runtime trace must not claim or invoke session control.'
}
if ($trace.SnapshotObserved -ne $true) { throw 'Actual Herdr snapshot was not observed.' }
if ($trace.EventObserved -ne $true) { throw 'Actual Herdr event was not observed.' }
if ($trace.ReconnectObserved -ne $true) {
    throw 'Actual disconnect/reconnect with a fresh snapshot was not observed.'
}
if ($trace.Admission.ReleaseId -ne '0.8.0-preview.2026-08-04-d78e3d3b5126-x86_64-pc-windows-msvc') {
    throw "Unexpected Herdr release: $($trace.Admission.ReleaseId)"
}
if ($trace.Admission.ExecutableSha256 -ne '6F470DA358D6713B6BEBAB922FFB1F5FE1D3D288CC6F374C7DCA1B4A9837A542') {
    throw "Unexpected Herdr executable SHA-256: $($trace.Admission.ExecutableSha256)"
}
if ($trace.Admission.BundledSchemaSha256 -ne '9449368D54BBECD4D4D0696EFFB9E9C002ECD63A5B8A48BBD901A305AF842982') {
    throw "Unexpected bundled schema SHA-256: $($trace.Admission.BundledSchemaSha256)"
}
if ([int]$trace.Admission.Protocol -ne 19) {
    throw "Unexpected runtime protocol: $($trace.Admission.Protocol)"
}
if ($null -eq $trace.ObservedServerIdentity -or [int]$trace.ObservedServerIdentity.ProcessId -le 0) {
    throw 'Runtime trace did not bind the Named Pipe to a server process.'
}
if ($trace.ObservedServerIdentity.ExecutableSha256 -ne $trace.Admission.ExecutableSha256) {
    throw 'Named Pipe server executable hash does not match the admitted Herdr executable hash.'
}
if ([string]::IsNullOrWhiteSpace($trace.ObservedServerIdentity.ExecutablePath)) {
    throw 'Runtime trace did not retain the verified Named Pipe server executable path.'
}
if ($null -eq $trace.ObservedServerIdentity.ProcessStartUtc) {
    throw 'Runtime trace did not retain the verified Named Pipe server process start time.'
}

$connectedBootstraps = @($trace.Transitions | Where-Object {
    $_.Status -eq 'Connected' -and [long]$_.BootstrapCount -gt 0
} | Sort-Object BootstrapCount -Unique)
if ($connectedBootstraps.Count -lt 2) {
    throw "Expected at least two connected snapshot bootstraps, found $($connectedBootstraps.Count)."
}
foreach ($connectedBootstrap in $connectedBootstraps) {
    $identity = $connectedBootstrap.ServerIdentity
    if ($null -eq $identity -or [int]$identity.ProcessId -le 0) {
        throw "Bootstrap $($connectedBootstrap.BootstrapCount) has no verified server PID."
    }
    if ($null -eq $identity.ProcessStartUtc) {
        throw "Bootstrap $($connectedBootstrap.BootstrapCount) has no verified server process start time."
    }
    if ([string]::IsNullOrWhiteSpace($identity.ExecutablePath)) {
        throw "Bootstrap $($connectedBootstrap.BootstrapCount) has no verified server executable path."
    }
    if ($identity.ExecutableSha256 -ne $trace.Admission.ExecutableSha256) {
        throw "Bootstrap $($connectedBootstrap.BootstrapCount) server hash does not match admission."
    }
}

if ($controlServerIdentity.ExecutableSha256 -ne $trace.Admission.ExecutableSha256) {
    throw 'Acceptance control server executable hash does not match the admitted Herdr executable.'
}
$transitions = @($trace.Transitions)
$initialConnectedTransitionIndex = -1
for ($index = 0; $index -lt $transitions.Count; $index++) {
    if ($transitions[$index].Status -eq 'Connected' -and $null -ne $transitions[$index].ServerIdentity) {
        $initialConnectedTransitionIndex = $index
        break
    }
}
if ($initialConnectedTransitionIndex -lt 0) {
    throw 'Runtime trace does not contain an initial connected target snapshot.'
}
$initialConnectedTransition = $transitions[$initialConnectedTransitionIndex]
if (Test-SameHerdrServerProcess -Left $controlServerIdentity -Right $initialConnectedTransition.ServerIdentity) {
    throw 'Acceptance control and target Agent Lab resolved to the same Herdr server process.'
}

$eventATransitionIndex = -1
for ($index = $initialConnectedTransitionIndex + 1; $index -lt $transitions.Count; $index++) {
    if ([long]$transitions[$index].EventCount -gt [long]$initialConnectedTransition.EventCount) {
        $eventATransitionIndex = $index
        break
    }
}
if ($eventATransitionIndex -lt 0) { throw 'Event A was not observed before target restart.' }
$eventATransition = $transitions[$eventATransitionIndex]
if ($null -eq $eventATransition.ServerIdentity) {
    throw 'Event A is not bound to a verified target server identity.'
}
if ([long]$eventATransition.DisconnectCount -ne [long]$initialConnectedTransition.DisconnectCount) {
    throw 'Event A coincided with a target transport disconnect instead of preceding it.'
}
if ([long]$eventATransition.BootstrapCount -ne [long]$initialConnectedTransition.BootstrapCount) {
    throw 'Event A coincided with a target bootstrap instead of preceding the restart.'
}
if (-not (Test-SameHerdrServerProcess -Left $initialConnectedTransition.ServerIdentity -Right $eventATransition.ServerIdentity)) {
    throw 'Target server identity changed before Event A.'
}
for ($index = $initialConnectedTransitionIndex + 1; $index -lt $eventATransitionIndex; $index++) {
    $candidate = $transitions[$index]
    if ([long]$candidate.DisconnectCount -ne [long]$initialConnectedTransition.DisconnectCount) {
        throw 'A target transport disconnect occurred before Event A.'
    }
    if ([long]$candidate.BootstrapCount -ne [long]$initialConnectedTransition.BootstrapCount) {
        throw 'A target bootstrap occurred before Event A.'
    }
    if ($null -ne $candidate.ServerIdentity -and
        -not (Test-SameHerdrServerProcess -Left $initialConnectedTransition.ServerIdentity -Right $candidate.ServerIdentity)) {
        throw 'Target server identity changed before Event A.'
    }
}

$targetDisconnectTransitionIndex = -1
for ($index = $eventATransitionIndex + 1; $index -lt $transitions.Count; $index++) {
    if ([long]$transitions[$index].DisconnectCount -gt [long]$eventATransition.DisconnectCount) {
        $targetDisconnectTransitionIndex = $index
        break
    }
}
if ($targetDisconnectTransitionIndex -lt 0) {
    throw 'No target transport disconnect occurred after Event A.'
}
$targetDisconnectTransition = $transitions[$targetDisconnectTransitionIndex]

$targetReconnectTransitionIndex = -1
for ($index = $targetDisconnectTransitionIndex + 1; $index -lt $transitions.Count; $index++) {
    $candidate = $transitions[$index]
    if ($candidate.Status -eq 'Connected' -and
        [long]$candidate.BootstrapCount -gt [long]$eventATransition.BootstrapCount -and
        $null -ne $candidate.ServerIdentity -and
        -not (Test-SameHerdrServerProcess -Left $eventATransition.ServerIdentity -Right $candidate.ServerIdentity)) {
        $targetReconnectTransitionIndex = $index
        break
    }
}
if ($targetReconnectTransitionIndex -lt 0) {
    throw 'No replacement target Herdr server connected after the post-Event-A disconnect.'
}
$targetReconnectTransition = $transitions[$targetReconnectTransitionIndex]
if (Test-SameHerdrServerProcess -Left $controlServerIdentity -Right $targetReconnectTransition.ServerIdentity) {
    throw 'Restarted target Agent Lab resolved to the Acceptance control server process.'
}

$eventBIncrementTransitionIndex = -1
for ($index = $targetReconnectTransitionIndex + 1; $index -lt $transitions.Count; $index++) {
    $candidate = $transitions[$index]
    $previous = $transitions[$index - 1]
    if ([long]$candidate.EventCount -gt [long]$previous.EventCount -and
        $null -ne $candidate.ServerIdentity -and
        (Test-SameHerdrServerProcess -Left $targetReconnectTransition.ServerIdentity -Right $candidate.ServerIdentity)) {
        $eventBIncrementTransitionIndex = $index
        break
    }
}
if ($eventBIncrementTransitionIndex -lt 0) {
    throw 'No EventCount increment from Event B was observed after the replacement target connected.'
}
$eventBIncrementTransition = $transitions[$eventBIncrementTransitionIndex]

$eventBTransitionIndex = -1
for ($index = $eventBIncrementTransitionIndex; $index -lt $transitions.Count; $index++) {
    $candidate = $transitions[$index]
    if ($candidate.Status -eq 'Connected' -and
        [long]$candidate.EventCount -ge [long]$eventBIncrementTransition.EventCount -and
        $null -ne $candidate.ServerIdentity -and
        (Test-SameHerdrServerProcess -Left $targetReconnectTransition.ServerIdentity -Right $candidate.ServerIdentity)) {
        $eventBTransitionIndex = $index
        break
    }
}
if ($eventBTransitionIndex -lt $eventBIncrementTransitionIndex) {
    throw 'No connected target state carried Event B after its post-reconnect increment.'
}
$eventBTransition = $transitions[$eventBTransitionIndex]
if ([long]$trace.FinalMonitorState.EventCount -lt 2) {
    throw 'The collector runtime gate requires at least two genuine Agent-status events.'
}

$controlProcessAfter = Get-Process -Id ([int]$controlServerIdentity.ProcessId) -ErrorAction SilentlyContinue
if ($null -eq $controlProcessAfter) {
    throw 'Acceptance control Herdr server did not survive the target restart.'
}
$controlIdentityAfter = [pscustomobject]@{
    ProcessId = [int]$controlServerIdentity.ProcessId
    ProcessStartUtc = $controlProcessAfter.StartTime.ToUniversalTime()
}
if (-not (Test-SameHerdrServerProcess -Left $controlServerIdentity -Right $controlIdentityAfter)) {
    throw 'Acceptance control Herdr server identity changed during the target restart.'
}

$firstState = $initialConnectedTransition
$finalState = $targetReconnectTransition
foreach ($stateFingerprint in @($firstState.StateFingerprintSha256, $finalState.StateFingerprintSha256)) {
    if ($stateFingerprint -notmatch '^[0-9A-F]{64}$') {
        throw "Invalid state fingerprint: $stateFingerprint"
    }
}
foreach ($contractStateHash in @($firstState.ContractStateSha256, $finalState.ContractStateSha256)) {
    if ($contractStateHash -notmatch '^[0-9A-F]{64}$') {
        throw "Invalid normalized contract-state hash: $contractStateHash"
    }
}

$trxFiles = @(Get-ChildItem -LiteralPath $testResultsDirectory -Filter '*.trx' -File)
if ($trxFiles.Count -ne 3) { throw "Expected 3 fresh TRX files, found $($trxFiles.Count)." }
$totalTests = 0
$passedTests = 0
$failedTests = 0
foreach ($trxFile in $trxFiles) {
    [xml]$trx = Get-Content -LiteralPath $trxFile.FullName -Raw
    $counters = $trx.TestRun.ResultSummary.Counters
    $totalTests += [int]$counters.total
    $passedTests += [int]$counters.passed
    $failedTests += [int]$counters.failed
}
if ($totalTests -le 0 -or $failedTests -ne 0 -or $totalTests -ne $passedTests) {
    throw "Pre-runtime test counters are not all passing: total=$totalTests passed=$passedTests failed=$failedTests"
}

$finalSourceCommit = Get-CleanSourceCommit -Root $repositoryRoot
if ($finalSourceCommit -ne $sourceCommit) {
    throw "Source commit changed during the runtime gate: $sourceCommit -> $finalSourceCommit"
}

$reportLines = @(
    'HerdrOps v0.2 Issue #7 Actual Herdr Runtime Gate',
    "GeneratedUtc: $((Get-Date).ToUniversalTime().ToString('O'))",
    "SourceCommit: $sourceCommit",
    'Result: PASS',
    'EvidenceClass: Runtime',
    'RuntimeObserved: true',
    'SessionControlInvoked: false',
    'SnapshotObserved: true',
    'EventObserved: true',
    'ReconnectObserved: true',
    "AcceptanceControlPaneEnvironmentId: $($env:HERDR_PANE_ID)",
    "AcceptanceControlPaneObservedId: $observedControlPaneId",
    "AcceptanceControlSocketPath: $controlHerdrSocketPath",
    "AcceptanceControlServerIdentity: pid=$($controlServerIdentity.ProcessId) start=$($controlServerIdentity.ProcessStartUtc.ToString('O')) path=$($controlServerIdentity.ExecutablePath) sha256=$($controlServerIdentity.ExecutableSha256)",
    "TargetAgentLabSocketPath: $targetHerdrSocketPath",
    'SeparateSessionSockets: true',
    "InitialTargetTransition: index=$initialConnectedTransitionIndex utc=$($initialConnectedTransition.ObservedUtc) eventCount=$($initialConnectedTransition.EventCount) bootstrapCount=$($initialConnectedTransition.BootstrapCount) disconnectCount=$($initialConnectedTransition.DisconnectCount) targetPid=$($initialConnectedTransition.ServerIdentity.ProcessId) targetStart=$($initialConnectedTransition.ServerIdentity.ProcessStartUtc)",
    "EventATransition: index=$eventATransitionIndex utc=$($eventATransition.ObservedUtc) eventCount=$($eventATransition.EventCount) targetPid=$($eventATransition.ServerIdentity.ProcessId) targetStart=$($eventATransition.ServerIdentity.ProcessStartUtc)",
    "TargetDisconnectTransition: index=$targetDisconnectTransitionIndex utc=$($targetDisconnectTransition.ObservedUtc) disconnectCount=$($targetDisconnectTransition.DisconnectCount)",
    "TargetReconnectTransition: index=$targetReconnectTransitionIndex utc=$($targetReconnectTransition.ObservedUtc) bootstrapCount=$($targetReconnectTransition.BootstrapCount) targetPid=$($targetReconnectTransition.ServerIdentity.ProcessId) targetStart=$($targetReconnectTransition.ServerIdentity.ProcessStartUtc)",
    "EventBIncrementTransition: index=$eventBIncrementTransitionIndex utc=$($eventBIncrementTransition.ObservedUtc) eventCount=$($eventBIncrementTransition.EventCount)",
    "EventBTransition: index=$eventBTransitionIndex utc=$($eventBTransition.ObservedUtc) eventCount=$($eventBTransition.EventCount)",
    "ObservedDisconnectCount: $($trace.FinalMonitorState.DisconnectCount)",
    "HerdrReleaseId: $($trace.Admission.ReleaseId)",
    "HerdrExecutableSha256: $($trace.Admission.ExecutableSha256)",
    "ObservedHerdrServerPid: $($trace.ObservedServerIdentity.ProcessId)",
    "ObservedHerdrServerProcessStartUtc: $($trace.ObservedServerIdentity.ProcessStartUtc)",
    "ObservedHerdrServerExecutablePath: $($trace.ObservedServerIdentity.ExecutablePath)",
    "ObservedHerdrServerExecutableSha256: $($trace.ObservedServerIdentity.ExecutableSha256)",
    "BundledSchemaSha256: $($trace.Admission.BundledSchemaSha256)",
    "Protocol: $($trace.Admission.Protocol)",
    "PreRuntimeTests: $passedTests/$totalTests PASS",
    "FirstBootstrapCount: $($firstState.BootstrapCount)",
    "FirstBootstrapServerIdentity: pid=$($firstState.ServerIdentity.ProcessId) start=$($firstState.ServerIdentity.ProcessStartUtc) path=$($firstState.ServerIdentity.ExecutablePath) sha256=$($firstState.ServerIdentity.ExecutableSha256)",
    "FirstStateFingerprintSha256: $($firstState.StateFingerprintSha256)",
    "FirstContractStateSha256: $($firstState.ContractStateSha256)",
    "FirstStateCounts: workspaces=$($firstState.WorkspaceCount) tabs=$($firstState.TabCount) panes=$($firstState.PaneCount) agents=$($firstState.AgentCount)",
    "FinalBootstrapCount: $($finalState.BootstrapCount)",
    "FinalBootstrapServerIdentity: pid=$($finalState.ServerIdentity.ProcessId) start=$($finalState.ServerIdentity.ProcessStartUtc) path=$($finalState.ServerIdentity.ExecutablePath) sha256=$($finalState.ServerIdentity.ExecutableSha256)",
    "FinalStateFingerprintSha256: $($finalState.StateFingerprintSha256)",
    "FinalContractStateSha256: $($finalState.ContractStateSha256)",
    "FinalStateCounts: workspaces=$($finalState.WorkspaceCount) tabs=$($finalState.TabCount) panes=$($finalState.PaneCount) agents=$($finalState.AgentCount)",
    '',
    'EvidenceBoundary:',
    'This gate proves an actual admitted Herdr snapshot, event observation, disconnect/reconnect, and fresh-snapshot reconciliation on this host and run.',
    'It does not prove package installation, release readiness, or future Herdr versions.'
)
$reportLines | Set-Content -LiteralPath $gateReportPath -Encoding utf8

Get-Content -LiteralPath $gateReportPath
Write-Host "RuntimeTraceJson: $tracePath"
Write-Host "RuntimeGateReport: $gateReportPath"
