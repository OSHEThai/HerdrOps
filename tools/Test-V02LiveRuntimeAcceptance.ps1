[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$TargetHerdrSocketPath,

    [string]$HerdrExecutable = (Join-Path $env:LOCALAPPDATA 'Programs\Herdr\bin\herdr.exe'),

    [ValidateRange(90, 900)]
    [int]$DurationSeconds = 240,

    [ValidateRange(5, 120)]
    [int]$IdleSeconds = 20,

    [ValidateSet('Thai', 'English')]
    [string]$Language = 'Thai',

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
        throw 'Could not resolve the source commit for the v0.2 live runtime gate.'
    }
    $changes = @(& git -C $Root status --porcelain --untracked-files=all)
    if ($LASTEXITCODE -ne 0) { throw 'Could not inspect repository status.' }
    if ($changes.Count -ne 0) {
        throw "Runtime evidence requires a clean source checkout. Changes: $($changes -join '; ')"
    }

    return $commit
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
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

function Get-FreshTestCounts {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][DateTime]$StartedUtc
    )

    $trxFiles = @(Get-ChildItem -LiteralPath $Directory -Filter '*.trx' -File |
        Where-Object { $_.LastWriteTimeUtc -ge $StartedUtc.AddSeconds(-2) })
    if ($trxFiles.Count -ne 4) {
        throw "Expected four fresh TRX files, found $($trxFiles.Count)."
    }

    $total = 0
    $passed = 0
    $failed = 0
    foreach ($trxFile in $trxFiles) {
        [xml]$trx = Get-Content -LiteralPath $trxFile.FullName -Raw
        $counters = $trx.TestRun.ResultSummary.Counters
        $total += [int]$counters.total
        $passed += [int]$counters.passed
        $failed += [int]$counters.failed
    }
    if ($total -le 0 -or $failed -ne 0 -or $total -ne $passed) {
        throw "Fresh test counters are not all passing: total=$total passed=$passed failed=$failed"
    }

    return [pscustomobject]@{ Total = $total; Passed = $passed; Failed = $failed }
}

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) { throw $Message }
}

if ($env:HERDR_ENV -ne '1') {
    throw 'The composite runtime gate must run from an authorized Herdr pane with HERDR_ENV=1.'
}
if ([string]::IsNullOrWhiteSpace($env:HERDR_SOCKET_PATH)) {
    throw 'The composite runtime gate requires HERDR_SOCKET_PATH from the active Acceptance control pane.'
}
if ([string]::IsNullOrWhiteSpace($env:HERDR_PANE_ID)) {
    throw 'The composite runtime gate requires HERDR_PANE_ID from the active Acceptance control pane.'
}
if (Test-IsAdministrator) {
    throw 'Run the v0.2 runtime gate from a standard, non-elevated Herdr pane to prove Administrator is not required.'
}
if (-not (Test-Path -LiteralPath $HerdrExecutable -PathType Leaf)) {
    throw "Installed Herdr executable not found: $HerdrExecutable"
}
if (-not (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue)) {
    throw 'Get-NetTCPConnection is required to verify that Core and App open no TCP listener.'
}
if (-not (Get-Command Get-CimInstance -ErrorAction SilentlyContinue)) {
    throw 'Get-CimInstance is required to bind the gate process to its Acceptance control Herdr server.'
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

$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$artifactRoot = Join-Path $repositoryRoot 'artifacts'
$sourceCommit = Get-CleanSourceCommit -Root $repositoryRoot
$buildStartedUtc = [DateTime]::UtcNow
& (Join-Path $PSScriptRoot 'Invoke-Build.ps1') -Configuration $Configuration -VerifyFormat
if ($LASTEXITCODE -ne 0) { throw 'Build and automated tests failed before runtime acceptance.' }
$testCounts = Get-FreshTestCounts -Directory (Join-Path $artifactRoot 'test-results') -StartedUtc $buildStartedUtc

$configurationDirectory = $Configuration.ToLowerInvariant()
$coreExecutable = Join-Path $artifactRoot "bin\HerdrOps.Core\$configurationDirectory\HerdrOps.Core.exe"
$appExecutable = Join-Path $artifactRoot "bin\HerdrOps.App\$configurationDirectory\HerdrOps.App.exe"
foreach ($executable in @($coreExecutable, $appExecutable)) {
    if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
        throw "Runtime executable not found: $executable"
    }
}

$runId = [DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssZ')
$evidenceDirectory = Join-Path $artifactRoot "runtime-evidence\v0.2\issues-7-9-10\$runId"
$captureDirectory = Join-Path $evidenceDirectory 'captures'
$databasePath = Join-Path $evidenceDirectory 'herdrops-runtime.db'
$coreReportPath = Join-Path $evidenceDirectory 'core-runtime.json'
$appReportPath = Join-Path $evidenceDirectory 'app-runtime.json'
$progressPath = Join-Path $evidenceDirectory 'app-progress.json'
$coreOutputPath = Join-Path $evidenceDirectory 'core.stdout.log'
$coreErrorPath = Join-Path $evidenceDirectory 'core.stderr.log'
$gateReportPath = Join-Path $evidenceDirectory 'gate-report.txt'
New-Item -ItemType Directory -Path $captureDirectory -Force | Out-Null

$coreDurationSeconds = [Math]::Min(3600, $DurationSeconds + $IdleSeconds + 30)
$coreArguments = @(
    'serve-herdr-state',
    '--database', $databasePath,
    '--herdr', $HerdrExecutable,
    '--socket-path', $targetHerdrSocketPath,
    '--seconds', $coreDurationSeconds,
    '--report', $coreReportPath
)
$appArguments = @(
    '--runtime-evidence-report', $appReportPath,
    '--capture-directory', $captureDirectory,
    '--progress-report', $progressPath,
    '--core-pid', '0',
    '--timeout-seconds', $DurationSeconds,
    '--idle-seconds', $IdleSeconds,
    '--language', $Language
)

$coreProcess = $null
$appProcess = $null
$tcpListeners = @{}
try {
    $coreProcess = Start-Process `
        -FilePath $coreExecutable `
        -ArgumentList $coreArguments `
        -RedirectStandardOutput $coreOutputPath `
        -RedirectStandardError $coreErrorPath `
        -WindowStyle Hidden `
        -PassThru
    $appArguments[7] = $coreProcess.Id.ToString([Globalization.CultureInfo]::InvariantCulture)
    Start-Sleep -Milliseconds 750
    if ($coreProcess.HasExited) {
        throw "Core exited before the App started. See $coreErrorPath"
    }

    Write-Host "Acceptance control socket: $controlHerdrSocketPath"
    Write-Host "Target Agent Lab socket: $targetHerdrSocketPath"
    Write-Host 'Runtime acceptance started. Follow the phase instructions shown below.'
    $appProcess = Start-Process `
        -FilePath $appExecutable `
        -ArgumentList $appArguments `
        -WindowStyle Normal `
        -PassThru

    $lastPhase = ''
    $deadlineUtc = [DateTime]::UtcNow.AddSeconds($coreDurationSeconds + 20)
    while (-not $appProcess.HasExited -and [DateTime]::UtcNow -lt $deadlineUtc) {
        if (Test-Path -LiteralPath $progressPath -PathType Leaf) {
            try {
                $progress = Get-Content -LiteralPath $progressPath -Raw | ConvertFrom-Json
                if ($progress.Phase -ne $lastPhase) {
                    $lastPhase = $progress.Phase
                    switch ($lastPhase) {
                        'waiting-for-live-state' {
                            Write-Host 'Waiting for the exact admitted Agent Lab snapshot. Do not restart either Herdr session yet.'
                        }
                        'capturing-live-dashboard-and-widgets' {
                            Write-Host 'Capturing the three live pages and three live Widgets. Keep Herdr state steady.'
                        }
                        'waiting-for-pre-close-update' {
                            Write-Host 'Event A: trigger one genuine Agent-status transition in the target Agent Lab. Focus, workspace, tab, and pane changes do not count. The Dashboard will close after the status event arrives.'
                        }
                        'dashboard-closed-waiting-for-next-update' {
                            Write-Host 'Dashboard closed; the Floating Vertical Widget remains. Restart only the target Agent Lab Herdr session, never the Acceptance control session. Wait for the Widget to return to LIVE, then trigger Event B with a second genuine Agent-status transition.'
                        }
                        'measuring-idle-resources' {
                            Write-Host "Leave Herdr, Core, and App untouched for the $IdleSeconds-second idle measurement."
                        }
                    }
                }
            } catch {
                # The App replaces the progress file atomically; a later poll will retry.
            }
        }

        $runtimeProcessIds = @($coreProcess.Id, $appProcess.Id)
        $listeners = @(Get-NetTCPConnection -State Listen -ErrorAction Stop |
            Where-Object { $runtimeProcessIds -contains $_.OwningProcess })
        foreach ($listener in $listeners) {
            $key = "$($listener.OwningProcess)|$($listener.LocalAddress)|$($listener.LocalPort)"
            $tcpListeners[$key] = $listener
        }

        Start-Sleep -Milliseconds 500
        $appProcess.Refresh()
    }

    if (-not $appProcess.HasExited) {
        throw 'The App runtime-evidence process exceeded the bounded gate duration.'
    }
    if ($appProcess.ExitCode -ne 0) {
        throw "The App runtime-evidence process failed with exit code $($appProcess.ExitCode)."
    }

    $remainingSeconds = [Math]::Max(1, [int]($deadlineUtc - [DateTime]::UtcNow).TotalSeconds)
    Wait-Process -Id $coreProcess.Id -Timeout $remainingSeconds
    $coreProcess.Refresh()
    if (-not $coreProcess.HasExited -or $coreProcess.ExitCode -ne 0) {
        throw "The Core runtime-evidence process did not exit cleanly. Exit=$($coreProcess.ExitCode)"
    }
} finally {
    if ($appProcess -and -not $appProcess.HasExited) {
        Stop-Process -Id $appProcess.Id -Force -ErrorAction SilentlyContinue
    }
    if ($coreProcess -and -not $coreProcess.HasExited) {
        Stop-Process -Id $coreProcess.Id -Force -ErrorAction SilentlyContinue
    }
}

foreach ($requiredReport in @($coreReportPath, $appReportPath)) {
    if (-not (Test-Path -LiteralPath $requiredReport -PathType Leaf)) {
        throw "Required runtime report is missing: $requiredReport"
    }
}
$coreReport = Get-Content -LiteralPath $coreReportPath -Raw | ConvertFrom-Json
$appReport = Get-Content -LiteralPath $appReportPath -Raw | ConvertFrom-Json

Assert-True ($coreReport.EvidenceClassification -eq 'Runtime') 'Core report did not earn Runtime classification.'
Assert-True ([bool]$coreReport.RuntimeObserved) 'Actual Herdr runtime was not observed by Core.'
Assert-True (-not [bool]$coreReport.SessionControlInvoked) 'Core must not invoke Herdr session control.'
Assert-True ([bool]$coreReport.SnapshotObserved) 'Actual Herdr snapshot was not observed.'
Assert-True ([bool]$coreReport.EventObserved) 'Actual Herdr Agent-status event was not observed.'
Assert-True ([bool]$coreReport.ReconnectObserved) 'Actual Herdr disconnect/reconnect was not observed.'
Assert-True ($coreReport.Admission.ReleaseId -eq '0.8.0-preview.2026-08-04-d78e3d3b5126-x86_64-pc-windows-msvc') 'Unexpected Herdr release.'
Assert-True ($coreReport.Admission.ExecutableSha256 -eq '6F470DA358D6713B6BEBAB922FFB1F5FE1D3D288CC6F374C7DCA1B4A9837A542') 'Unexpected Herdr executable hash.'
Assert-True ($coreReport.Admission.BundledSchemaSha256 -eq '9449368D54BBECD4D4D0696EFFB9E9C002ECD63A5B8A48BBD901A305AF842982') 'Unexpected bundled schema hash.'
Assert-True ([int]$coreReport.Admission.Protocol -eq 19) 'Unexpected Herdr protocol.'

Assert-True ($appReport.EvidenceClassification -eq 'RuntimeCandidate') 'App report is not a Runtime candidate.'
Assert-True ([bool]$appReport.CoreStateObserved) 'App did not observe Core state.'
Assert-True (-not [bool]$appReport.SessionControlInvoked) 'App must not invoke Herdr session control.'
Assert-True ([bool]$appReport.UpdateObservedBeforeDashboardClose) 'No App update was observed before Dashboard close.'
Assert-True ([bool]$appReport.DashboardClosed) 'Dashboard did not close during lifecycle acceptance.'
Assert-True ([bool]$appReport.UpdateObservedAfterDashboardClose) 'No App-owned Widget update was observed after Dashboard close.'
Assert-True ([bool]$appReport.CoreConnectedAfterDashboardClose) 'Core was not connected after Dashboard close.'
Assert-True ([long]$appReport.PreCloseEventCount -gt [long]$appReport.InitialEventCount) 'The pre-close App update was not caused by a real Herdr Agent-status event.'
Assert-True ([long]$appReport.PostCloseEventCount -gt [long]$appReport.PreCloseEventCount) 'The post-close Widget update was not caused by a second real Herdr Agent-status event.'
Assert-True ($appReport.WidgetLatencyMeasurement -eq 'CoreAcceptedStateUtcToWpfStateApplied') 'Unexpected Widget latency measurement boundary.'
Assert-True ([bool]$appReport.WidgetLatencyTargetPassed) 'Actual Widget latency target failed or had too few samples.'
Assert-True ([bool]$appReport.ResourceMeasurement.StateSequenceStable) 'State changed during the idle resource sample.'
Assert-True ([bool]$appReport.ResourceMeasurement.RuntimeEventCountStable) 'A Herdr event occurred during the idle resource sample.'
Assert-True ([bool]$appReport.ResourceMeasurement.HerdrConnectedThroughoutSample) 'Herdr was not connected throughout the idle resource sample.'
Assert-True ([bool]$appReport.ResourceMeasurement.CpuTargetPassed) 'Combined Core + App idle CPU target failed.'
Assert-True ([bool]$appReport.ResourceMeasurement.WorkingSetTargetPassed) 'Combined Core + App working-set target failed.'
Assert-True ([bool]$appReport.CompositeCandidateChecksPassed) 'App runtime candidate checks did not all pass.'
Assert-True ([long]$coreReport.FinalMonitorState.EventCount -ge 2) 'The Core trace requires at least two real Herdr events.'
Assert-True ($tcpListeners.Count -eq 0) 'Core or App opened a TCP listener during normal runtime acceptance.'

Assert-True ($controlServerIdentity.ExecutableSha256 -eq $coreReport.Admission.ExecutableSha256) 'Acceptance control server executable hash does not match the admitted Herdr executable.'
$coreTransitions = @($coreReport.Transitions)
Assert-True ($coreTransitions.Count -gt 0) 'Core runtime report contains no transitions.'

$eventATransitionIndex = -1
for ($index = 0; $index -lt $coreTransitions.Count; $index++) {
    if ([long]$coreTransitions[$index].EventCount -ge [long]$appReport.PreCloseEventCount) {
        $eventATransitionIndex = $index
        break
    }
}
Assert-True ($eventATransitionIndex -ge 0) 'Core trace does not contain the Event A count rendered before Dashboard closure.'
$eventATransition = $coreTransitions[$eventATransitionIndex]
Assert-True ($null -ne $eventATransition.ServerIdentity) 'Event A is not bound to a verified target server identity.'
Assert-True (-not (Test-SameHerdrServerProcess -Left $controlServerIdentity -Right $eventATransition.ServerIdentity)) 'Acceptance control and target Agent Lab resolved to the same Herdr server process.'

$initialTargetTransitionIndex = -1
for ($index = 0; $index -lt $eventATransitionIndex; $index++) {
    if ($coreTransitions[$index].Status -eq 'Connected' -and $null -ne $coreTransitions[$index].ServerIdentity) {
        $initialTargetTransitionIndex = $index
        break
    }
}
Assert-True ($initialTargetTransitionIndex -ge 0) 'Core trace has no initial connected target baseline before Event A.'
$initialTargetTransition = $coreTransitions[$initialTargetTransitionIndex]
Assert-True ([long]$eventATransition.EventCount -gt [long]$initialTargetTransition.EventCount) 'Event A did not increase EventCount from the initial target baseline.'
Assert-True ([long]$eventATransition.DisconnectCount -eq [long]$initialTargetTransition.DisconnectCount) 'Event A coincided with a target transport disconnect instead of preceding it.'
Assert-True ([long]$eventATransition.BootstrapCount -eq [long]$initialTargetTransition.BootstrapCount) 'Event A coincided with a target bootstrap instead of preceding the restart.'
Assert-True (Test-SameHerdrServerProcess -Left $initialTargetTransition.ServerIdentity -Right $eventATransition.ServerIdentity) 'Target server identity changed before Event A.'
for ($index = $initialTargetTransitionIndex + 1; $index -lt $eventATransitionIndex; $index++) {
    $candidate = $coreTransitions[$index]
    Assert-True ([long]$candidate.DisconnectCount -eq [long]$initialTargetTransition.DisconnectCount) 'A target transport disconnect occurred before Event A.'
    Assert-True ([long]$candidate.BootstrapCount -eq [long]$initialTargetTransition.BootstrapCount) 'A target bootstrap occurred before Event A.'
    if ($null -ne $candidate.ServerIdentity) {
        Assert-True (Test-SameHerdrServerProcess -Left $initialTargetTransition.ServerIdentity -Right $candidate.ServerIdentity) 'Target server identity changed before Event A.'
    }
}

$targetDisconnectTransitionIndex = -1
for ($index = $eventATransitionIndex + 1; $index -lt $coreTransitions.Count; $index++) {
    if ([long]$coreTransitions[$index].DisconnectCount -gt [long]$eventATransition.DisconnectCount) {
        $targetDisconnectTransitionIndex = $index
        break
    }
}
Assert-True ($targetDisconnectTransitionIndex -gt $eventATransitionIndex) 'No target transport disconnect occurred after Event A.'
$targetDisconnectTransition = $coreTransitions[$targetDisconnectTransitionIndex]

$targetReconnectTransitionIndex = -1
for ($index = $targetDisconnectTransitionIndex + 1; $index -lt $coreTransitions.Count; $index++) {
    $candidate = $coreTransitions[$index]
    if ($candidate.Status -eq 'Connected' -and
        [long]$candidate.BootstrapCount -gt [long]$eventATransition.BootstrapCount -and
        $null -ne $candidate.ServerIdentity -and
        -not (Test-SameHerdrServerProcess -Left $eventATransition.ServerIdentity -Right $candidate.ServerIdentity)) {
        $targetReconnectTransitionIndex = $index
        break
    }
}
Assert-True ($targetReconnectTransitionIndex -gt $targetDisconnectTransitionIndex) 'No replacement target Herdr server connected after the post-Event-A disconnect.'
$targetReconnectTransition = $coreTransitions[$targetReconnectTransitionIndex]
Assert-True (-not (Test-SameHerdrServerProcess -Left $controlServerIdentity -Right $targetReconnectTransition.ServerIdentity)) 'Restarted target Agent Lab resolved to the Acceptance control server process.'

$eventBIncrementTransitionIndex = -1
for ($index = $targetReconnectTransitionIndex + 1; $index -lt $coreTransitions.Count; $index++) {
    $candidate = $coreTransitions[$index]
    $previous = $coreTransitions[$index - 1]
    if ([long]$candidate.EventCount -gt [long]$previous.EventCount -and
        [long]$candidate.EventCount -ge [long]$appReport.PostCloseEventCount -and
        $null -ne $candidate.ServerIdentity -and
        (Test-SameHerdrServerProcess -Left $targetReconnectTransition.ServerIdentity -Right $candidate.ServerIdentity)) {
        $eventBIncrementTransitionIndex = $index
        break
    }
}
Assert-True ($eventBIncrementTransitionIndex -gt $targetReconnectTransitionIndex) 'No EventCount increment from Event B was observed after the replacement target connected.'
$eventBIncrementTransition = $coreTransitions[$eventBIncrementTransitionIndex]

$eventBTransitionIndex = -1
for ($index = $eventBIncrementTransitionIndex; $index -lt $coreTransitions.Count; $index++) {
    $candidate = $coreTransitions[$index]
    if ($candidate.Status -eq 'Connected' -and
        [long]$candidate.EventCount -ge [long]$eventBIncrementTransition.EventCount -and
        $null -ne $candidate.ServerIdentity -and
        (Test-SameHerdrServerProcess -Left $targetReconnectTransition.ServerIdentity -Right $candidate.ServerIdentity)) {
        $eventBTransitionIndex = $index
        break
    }
}
Assert-True ($eventBTransitionIndex -ge $eventBIncrementTransitionIndex) 'No connected target state carried Event B after its post-reconnect increment.'
$eventBTransition = $coreTransitions[$eventBTransitionIndex]

$controlProcessAfter = Get-Process -Id ([int]$controlServerIdentity.ProcessId) -ErrorAction SilentlyContinue
Assert-True ($null -ne $controlProcessAfter) 'Acceptance control Herdr server did not survive the target restart.'
$controlIdentityAfter = [pscustomobject]@{
    ProcessId = [int]$controlServerIdentity.ProcessId
    ProcessStartUtc = $controlProcessAfter.StartTime.ToUniversalTime()
}
Assert-True (Test-SameHerdrServerProcess -Left $controlServerIdentity -Right $controlIdentityAfter) 'Acceptance control Herdr server identity changed during the target restart.'

$coreStateHashes = @($coreReport.Transitions | ForEach-Object { $_.ContractStateSha256 })
foreach ($appStateHash in @(
    $appReport.InitialStateSha256,
    $appReport.PreCloseStateSha256,
    $appReport.PostCloseStateSha256)) {
    Assert-True ($coreStateHashes -contains $appStateHash) "App state hash $appStateHash was not observed in the exact-Herdr Core trace."
}

$captures = @($appReport.Captures)
Assert-True ($captures.Count -ge 8) "Expected at least eight runtime WPF captures, found $($captures.Count)."
foreach ($capture in $captures) {
    Assert-True (Test-Path -LiteralPath $capture.Path -PathType Leaf) "Runtime capture is missing: $($capture.Path)"
    $actualHash = (Get-FileHash -LiteralPath $capture.Path -Algorithm SHA256).Hash
    Assert-True ($actualHash -eq $capture.Sha256) "Runtime capture hash mismatch: $($capture.Name)"
}

$finalSourceCommit = Get-CleanSourceCommit -Root $repositoryRoot
if ($finalSourceCommit -ne $sourceCommit) {
    throw "Source commit changed during runtime acceptance: $sourceCommit -> $finalSourceCommit"
}
$coreExecutableHash = (Get-FileHash -LiteralPath $coreExecutable -Algorithm SHA256).Hash
$appExecutableHash = (Get-FileHash -LiteralPath $appExecutable -Algorithm SHA256).Hash
$coreReportHash = (Get-FileHash -LiteralPath $coreReportPath -Algorithm SHA256).Hash
$appReportHash = (Get-FileHash -LiteralPath $appReportPath -Algorithm SHA256).Hash

$reportLines = @(
    'HerdrOps v0.2 Composite Actual Herdr Runtime Acceptance',
    "GeneratedUtc: $([DateTimeOffset]::UtcNow.ToString('O'))",
    "SourceCommit: $sourceCommit",
    'Result: PASS',
    'EvidenceClass: Runtime',
    'SessionControlInvoked: false',
    "AcceptanceControlPaneEnvironmentId: $($env:HERDR_PANE_ID)",
    "AcceptanceControlPaneObservedId: $observedControlPaneId",
    "AcceptanceControlSocketPath: $controlHerdrSocketPath",
    "AcceptanceControlServerIdentity: pid=$($controlServerIdentity.ProcessId) start=$($controlServerIdentity.ProcessStartUtc.ToString('O')) path=$($controlServerIdentity.ExecutablePath) sha256=$($controlServerIdentity.ExecutableSha256)",
    "TargetAgentLabSocketPath: $targetHerdrSocketPath",
    'SeparateSessionSockets: true',
    "InitialTargetTransition: index=$initialTargetTransitionIndex utc=$($initialTargetTransition.ObservedUtc) eventCount=$($initialTargetTransition.EventCount) bootstrapCount=$($initialTargetTransition.BootstrapCount) disconnectCount=$($initialTargetTransition.DisconnectCount) targetPid=$($initialTargetTransition.ServerIdentity.ProcessId) targetStart=$($initialTargetTransition.ServerIdentity.ProcessStartUtc)",
    "EventATransition: index=$eventATransitionIndex utc=$($eventATransition.ObservedUtc) eventCount=$($eventATransition.EventCount) targetPid=$($eventATransition.ServerIdentity.ProcessId) targetStart=$($eventATransition.ServerIdentity.ProcessStartUtc)",
    "TargetDisconnectTransition: index=$targetDisconnectTransitionIndex utc=$($targetDisconnectTransition.ObservedUtc) disconnectCount=$($targetDisconnectTransition.DisconnectCount)",
    "TargetReconnectTransition: index=$targetReconnectTransitionIndex utc=$($targetReconnectTransition.ObservedUtc) bootstrapCount=$($targetReconnectTransition.BootstrapCount) targetPid=$($targetReconnectTransition.ServerIdentity.ProcessId) targetStart=$($targetReconnectTransition.ServerIdentity.ProcessStartUtc)",
    "EventBIncrementTransition: index=$eventBIncrementTransitionIndex utc=$($eventBIncrementTransition.ObservedUtc) eventCount=$($eventBIncrementTransition.EventCount)",
    "EventBTransition: index=$eventBTransitionIndex utc=$($eventBTransition.ObservedUtc) eventCount=$($eventBTransition.EventCount)",
    "AutomatedTests: $($testCounts.Passed)/$($testCounts.Total) PASS",
    "HerdrReleaseId: $($coreReport.Admission.ReleaseId)",
    "HerdrExecutableSha256: $($coreReport.Admission.ExecutableSha256)",
    "HerdrOpsCoreExecutableSha256: $coreExecutableHash",
    "HerdrOpsAppExecutableSha256: $appExecutableHash",
    "CoreRuntimeReportSha256: $coreReportHash",
    "AppRuntimeReportSha256: $appReportHash",
    "BundledSchemaSha256: $($coreReport.Admission.BundledSchemaSha256)",
    "HerdrProtocol: $($coreReport.Admission.Protocol)",
    "SnapshotObserved: $($coreReport.SnapshotObserved)",
    "EventObserved: $($coreReport.EventObserved)",
    "ReconnectObserved: $($coreReport.ReconnectObserved)",
    "DisconnectCount: $($coreReport.FinalMonitorState.DisconnectCount)",
    "BootstrapCount: $($coreReport.FinalMonitorState.BootstrapCount)",
    "DashboardClosed: $($appReport.DashboardClosed)",
    "UpdateAfterDashboardClose: $($appReport.UpdateObservedAfterDashboardClose)",
    "InitialEventCount: $($appReport.InitialEventCount)",
    "PreCloseEventCount: $($appReport.PreCloseEventCount)",
    "PostCloseEventCount: $($appReport.PostCloseEventCount)",
    "WidgetLatencySamples: $($appReport.WidgetLatencySamples)",
    "WidgetLatencyMeasurement: $($appReport.WidgetLatencyMeasurement)",
    "WidgetLatencyP95Ms: $($appReport.WidgetLatencyP95Milliseconds)",
    "CombinedIdleCpuPercent: $($appReport.ResourceMeasurement.CombinedAverageCpuPercent)",
    "CombinedAverageWorkingSetMB: $($appReport.ResourceMeasurement.CombinedAverageWorkingSetMegabytes)",
    "CombinedMaximumWorkingSetMB: $($appReport.ResourceMeasurement.CombinedMaximumWorkingSetMegabytes)",
    "IdleStateSequence: $($appReport.ResourceMeasurement.StartSequence)",
    "IdleEventCount: $($appReport.ResourceMeasurement.StartEventCount)",
    "RuntimeWpfCaptures: $($captures.Count)",
    'TcpListenersOwnedByCoreOrApp: 0',
    'AdministratorRequired: false',
    '',
    'StateHashChain:'
    "Initial: $($appReport.InitialSequence) $($appReport.InitialStateSha256)",
    "BeforeDashboardClose: $($appReport.PreCloseSequence) $($appReport.PreCloseStateSha256)",
    "AfterDashboardClose: $($appReport.PostCloseSequence) $($appReport.PostCloseStateSha256)",
    '',
    'CaptureHashes:'
) + ($captures | ForEach-Object { "SHA256 $($_.Sha256) $($_.Name)" }) + @(
    '',
    'EvidenceBoundary:',
    'This gate proves exact-hash-bound actual Herdr snapshot/Agent-status-event/reconnect behavior, separate Acceptance-control and Agent-Lab target sessions, Core-to-App runtime-health propagation, live production WPF page and Widget rendering, Dashboard-close continuity, state-hash correspondence, measured latency/resources, no owned TCP listener, and non-elevated operation for this host and run.',
    'It does not prove packaging, clean-machine installation, later-version features, independent human review, or future Herdr releases.'
)
$reportLines | Set-Content -LiteralPath $gateReportPath -Encoding utf8
$gateHash = (Get-FileHash -LiteralPath $gateReportPath -Algorithm SHA256).Hash

$reportLines | Write-Output
Write-Output "GateReport: $gateReportPath"
Write-Output "GateReportSha256: $gateHash"
Write-Output "CoreRuntimeReport: $coreReportPath"
Write-Output "AppRuntimeReport: $appReportPath"
