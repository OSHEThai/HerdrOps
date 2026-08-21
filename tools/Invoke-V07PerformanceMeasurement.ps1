<#
.SYNOPSIS
    HerdrOps v0.7 Issue #39 -- Live Performance Measurement Producer (operator
    harness). Captures dashboard cold-launch p95, widget state-delta latency p95,
    Herdr reconnect-and-reconcile time, idle CPU, and combined working set against
    an exact candidate/Herdr session, with exact commit/artifact/session/role
    provenance, bounded cancellation/timeouts, raw sample retention, and no
    synthetic-to-runtime promotion.

.DESCRIPTION
    The harness NEVER starts, restarts, or controls Herdr. It observes an exact
    authorized Herdr session (HERDR_ENV=1), drives the App runtime-evidence mode
    and Core runtime trace, and asks the operator to trigger genuine events and a
    target-session restart. Every phase is bounded and cancellable. Outputs:

      artifacts/runtime-evidence/v0.7/issue-39/<runId>/
        measurement-run.json          (v0.7.0-measurement artifact; live evidence)
        measurement-gate-report.txt   (human-readable result; Runtime denied unless
                                       a matching validated soak artifact finalizes)

    Use -Synthetic to run the deterministic self-test matrix and write a clearly
    synthetic artifact instead of touching any live session.

.PARAMETER TargetHerdrSocketPath
    Path of the target Agent Lab Herdr session socket (live mode).

.PARAMETER HerdrExecutable
    Path of the installed Herdr executable (defaults to the standard install).

.PARAMETER RepositoryRoot
    Repository root (defaults to the parent of this script).

.PARAMETER CandidateDirectory
    Directory containing built candidate binaries (defaults to artifacts/bin).

.PARAMETER DurationSeconds
    Bound for the App runtime-evidence phase (30-900).

.PARAMETER IdleSeconds
    Idle resource sampling window (5-120).

.PARAMETER LaunchRuns
    Number of cold dashboard launches for launch p95 (3-10).

.PARAMETER MaxRunSeconds
    Overall run deadline; the run fails closed if exceeded (default 7200).

.PARAMETER Configuration
    Build configuration to verify against (Debug or Release; default Release).

.PARAMETER SkipBuild
    Skip the pre-run build gate (binaries must already exist).

.PARAMETER SkipLaunchPhase
    Skip the launch p95 phase (for diagnostics or when App launches are not wanted).

.PARAMETER SoakEvidencePath
    Optional path to a validated v0.7.0-soak artifact. When provided and valid, the
    harness finalizes a v0.7.0 budget report with EvidenceClass Runtime. Without it
    the harness records live measurement evidence only and explicitly denies Runtime
    credit in the gate report.

.PARAMETER Synthetic
    Run the deterministic self-test matrix and write a synthetic artifact. Never
    touches Herdr and never claims runtime credit.

.PARAMETER FixtureDirectory
    Self-test fixture directory (defaults to tests/fixtures/v0.7/performance-measurement).

.PARAMETER OutDirectory
    Evidence output directory (defaults to artifacts/runtime-evidence/v0.7/issue-39/<runId>).
#>
[CmdletBinding()]
param(
    [string]$TargetHerdrSocketPath = '',

    [string]$HerdrExecutable = (Join-Path $env:LOCALAPPDATA 'Programs\Herdr\bin\herdr.exe'),

    [string]$RepositoryRoot = '',

    [string]$CandidateDirectory = '',

    [ValidateRange(30, 900)]
    [int]$DurationSeconds = 240,

    [ValidateRange(5, 120)]
    [int]$IdleSeconds = 20,

    [ValidateRange(3, 10)]
    [int]$LaunchRuns = 5,

    [ValidateRange(60, 86400)]
    [int]$MaxRunSeconds = 7200,

    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',

    [switch]$SkipBuild,

    [switch]$SkipLaunchPhase,

    [string]$SoakEvidencePath = '',

    [switch]$Synthetic,

    [string]$FixtureDirectory = '',

    [string]$OutDirectory = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

# -----------------------------------------------------------------------------
# Load policy
# -----------------------------------------------------------------------------
. (Join-Path $PSScriptRoot 'lib\V07PerformanceMeasurementPolicy.ps1')

$resolvedRepoRoot = if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
} else {
    (Resolve-Path -LiteralPath $RepositoryRoot).Path
}
Assert-V07NotReparsePoint -Path $resolvedRepoRoot -Description 'Repository root'

$artifactRoot = Join-Path $resolvedRepoRoot 'artifacts'
if ([string]::IsNullOrWhiteSpace($CandidateDirectory)) {
    $CandidateDirectory = Join-Path $artifactRoot 'bin'
}
if (-not (Test-Path -LiteralPath $CandidateDirectory -PathType Container)) {
    throw "Candidate directory does not exist: $CandidateDirectory"
}
$runId = "$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ', [Globalization.CultureInfo]::InvariantCulture))-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
$evidenceDirectory = if ([string]::IsNullOrWhiteSpace($OutDirectory)) {
    Join-Path $artifactRoot "runtime-evidence\v0.7\issue-39\$runId"
} else {
    [IO.Path]::GetFullPath($OutDirectory)
}
New-Item -ItemType Directory -Path $evidenceDirectory -Force | Out-Null

$measurementArtifactPath = Join-Path $evidenceDirectory 'measurement-run.json'
$gateReportPath = Join-Path $evidenceDirectory 'measurement-gate-report.txt'
$budgetReportPath = Join-Path $evidenceDirectory 'performance-budget-report.json'

$phaseLog = [System.Collections.Generic.List[object]]::new()
$startedUtc = [DateTime]::UtcNow
$startedUtcText = ConvertTo-V07UtcText -Value $startedUtc
$deadline = $startedUtc.AddSeconds($MaxRunSeconds)
$cancelled = $false
$timedOut = $false
$terminationReason = ''

# Shared live-mode state (initialized so the fail-closed catch can retain partials)
$session = $null
$binding = $null
$metrics = $null
$observed = $null
$rawSamples = $null
$coreRole = $null
$appRole = $null
$launchSamples = [System.Collections.Generic.List[object]]::new()
$deltaLatencySamples = [System.Collections.Generic.List[object]]::new()
$reconnectSamples = [System.Collections.Generic.List[object]]::new()
$cpuSamples = [System.Collections.Generic.List[object]]::new()
$workingSetSamples = [System.Collections.Generic.List[object]]::new()
$hostEnvironment = $null
$admission = $null
$finalization = $null

function Add-V07PhaseLog {
    param(
        [Parameter(Mandatory)][string]$Phase,
        [Parameter(Mandatory)][string]$Result,
        [string]$Detail = ''
    )
    $script:phaseLog.Add([pscustomobject]@{
        Phase       = $Phase
        StartedUtc  = $PhaseStartedUtc
        FinishedUtc = ConvertTo-V07UtcText -Value ([DateTime]::UtcNow)
        Result      = $Result
        Detail      = $Detail
    })
}

function Assert-V07WithinDeadline {
    param([string]$Phase)
    if ([DateTime]::UtcNow -gt $script:deadline) {
        throw "Phase '$Phase' exceeded the overall run deadline of $MaxRunSeconds seconds."
    }
}

# -----------------------------------------------------------------------------
# Cancellation handling (Ctrl+C / SIGINT); non-interactive runs rely on the
# bounded deadline and fail closed on timeout instead.
# -----------------------------------------------------------------------------
$cancelEvent = $null
try {
    $cancelEvent = Register-ObjectEvent -InputObject ([console]) -EventName CancelKeyPress -Action {
        $event.Sender.Cancel = $true
        $script:cancelled = $true
        $script:terminationReason = 'Operator cancellation (Ctrl+C).'
    } -ErrorAction SilentlyContinue
} catch {
    $cancelEvent = $null
}

try {
    # -------------------------------------------------------------------------
    # Synthetic mode: deterministic self-tests only; no live session ever touched
    # -------------------------------------------------------------------------
    if ($Synthetic) {
        $fixturesDir = if ([string]::IsNullOrWhiteSpace($FixtureDirectory)) {
            Join-Path $resolvedRepoRoot 'tests\fixtures\v0.7\performance-measurement'
        } else {
            (Resolve-Path -LiteralPath $FixtureDirectory).Path
        }
        if (-not (Test-Path -LiteralPath $fixturesDir -PathType Container)) {
            throw "Self-test fixture directory does not exist: $fixturesDir"
        }

        # Hermeticity: the synthetic self-test matrix must never be influenced by
        # an ambient authorized Herdr session in the operator shell.
        Remove-Item Env:HERDR_ENV -ErrorAction SilentlyContinue
        Remove-Item Env:HERDR_SOCKET_PATH -ErrorAction SilentlyContinue
        Remove-Item Env:HERDR_PANE_ID -ErrorAction SilentlyContinue

        Write-Host "`nRunning v0.7 performance measurement deterministic self-test suite..."
        . (Join-Path $PSScriptRoot 'lib\V07MeasurementSelfTests.ps1')
        $selfTestResults = @(Invoke-V07MeasurementSelfTests -RepositoryRoot $resolvedRepoRoot -FixturesDirectory $fixturesDir)
        $stPassed = @($selfTestResults | Where-Object Status -eq 'PASS').Count
        $stFailed = @($selfTestResults | Where-Object Status -ne 'PASS').Count
        foreach ($res in $selfTestResults) {
            if ($res.Status -eq 'PASS') {
                Write-Host "  [PASS] $($res.TestName): $($res.Detail)" -ForegroundColor Green
            } else {
                Write-Host "  [FAIL] $($res.TestName): $($res.Detail)" -ForegroundColor Red
            }
        }
        if ($stFailed -gt 0) {
            throw "Performance measurement self-test suite failed: $stFailed of $($selfTestResults.Count) tests failed."
        }
        Write-Host "All $($selfTestResults.Count) self-test scenarios passed cleanly.`n" -ForegroundColor Green

        # Write a clearly-synthetic artifact (Mode: Synthetic) as the trace record.
        $syntheticSession = [pscustomobject]@{
            ControlPaneId = 'synthetic-selftest'
            ObservedControlPaneId = 'synthetic-selftest'
            ControlHerdrSocketPath = 'C:\synthetic\control.sock'
            TargetHerdrSocketPath = 'C:\synthetic\target.sock'
            SeparateSessions = $true
            HerdrExecutablePath = 'C:\synthetic\herdr.exe'
            HerdrExecutableSha256 = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
            HerdrReleaseId = 'synthetic'
            ControlHerdrServerIdentity = [pscustomobject]@{
                ProcessId = 1
                ProcessStartUtc = ConvertTo-V07UtcText -Value $startedUtc
                ExecutablePath = 'C:\synthetic\herdr.exe'
                ExecutableSha256 = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
            }
        }
        $binding = New-V07CandidateBinding -RepositoryRoot $resolvedRepoRoot -CandidateDirectory $CandidateDirectory -SkipCleanCheck
        $syntheticCandidate = [pscustomobject]@{
            SourceCommit = $binding.SourceCommit
            GitTreeClean = $binding.GitTreeClean
            Binaries = @($binding.Binaries)
        }
        $syntheticMetrics = [pscustomobject]@{
            DashboardColdLaunchP95Ms = 0.0
            WidgetStateDeltaLatencyP95Ms = 0.0
            HerdrReconnectReconcileSeconds = 0.0
            IdleCpuAveragePercent = 0.0
            IdleWorkingSetCombinedBytes = 0
            UnboundedTerminalReads = 0
            UnhandledCrashesDuringSoak = 0
            SoakDurationHours = 0.0
            AdministratorRequired = $false
        }
        $syntheticObserved = [pscustomobject]@{
            DashboardColdLaunch = $false
            WidgetStateDeltaLatency = $false
            HerdrReconnectReconcile = $false
            IdleCpu = $false
            IdleWorkingSet = $false
        }
        $syntheticRawSamples = [pscustomobject]@{
            DashboardColdLaunch = @()
            WidgetStateDeltaLatency = @()
            HerdrReconnectReconcile = @()
            IdleCpu = @()
            IdleWorkingSet = @()
        }
        $finishedUtcText = ConvertTo-V07UtcText -Value ([DateTime]::UtcNow)
        $artifact = New-V07MeasurementArtifact -RunId $runId -StartedUtc $startedUtcText -FinishedUtc $finishedUtcText `
            -Mode 'Synthetic' -TerminationReason 'Synthetic self-test run; no live Herdr session was observed.' `
            -HostEnvironment ([pscustomobject]@{
                Os = [System.Environment]::OSVersion.VersionString
                Architecture = [System.Environment]::Is64BitOperatingSystem.ToString()
                LogicalProcessors = [Environment]::ProcessorCount
                ReferenceHostConfirmed = $false
            }) -Session $syntheticSession -Candidate $syntheticCandidate `
            -Roles @() -Metrics $syntheticMetrics -Observed $syntheticObserved -RawSamples $syntheticRawSamples `
            -PhaseLog @($phaseLog)

        $artifact | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $measurementArtifactPath -Encoding UTF8
        $lines = @(
            'HerdrOps v0.7 Issue #39 Performance Measurement Producer',
            "GeneratedUtc: $([DateTimeOffset]::UtcNow.ToString('O'))",
            "RunId: $runId",
            "SourceCommit: $($binding.SourceCommit)",
            'Mode: SYNTHETIC',
            'Result: PASS (SELF-TEST ONLY)',
            'EvidenceClass: Synthetic',
            'ActualHerdrRuntime: NOT OBSERVED / NOT CLAIMED',
            "SelfTests: $($stPassed)/$($selfTestResults.Count) PASS",
            "MeasurementArtifact: $measurementArtifactPath",
            '',
            'This run only verified the deterministic producer machinery. It observed no live',
            'Herdr session and cannot be promoted to Runtime evidence.'
        )
        $lines | Set-Content -LiteralPath $gateReportPath -Encoding UTF8
        $lines | ForEach-Object { Write-Host $_ }
        Write-Host "`nMeasurementArtifactJson: $measurementArtifactPath"
        exit 0
    }

    # -------------------------------------------------------------------------
    # Live mode: strict session admission
    # -------------------------------------------------------------------------
    $phaseStartedUtc = ConvertTo-V07UtcText -Value ([DateTime]::UtcNow)
    if ([string]::IsNullOrWhiteSpace($TargetHerdrSocketPath)) {
        throw 'Live mode requires -TargetHerdrSocketPath pointing at the target Agent Lab session socket.'
    }
    $session = Test-V07LiveSessionAdmission -HerdrExecutable $HerdrExecutable -TargetHerdrSocketPath $TargetHerdrSocketPath
    Add-V07PhaseLog -Phase 'admission' -Result 'OK' -Detail "Control pane $($session.ControlPaneId); target $($session.TargetHerdrSocketPath)"

    $phaseStartedUtc = ConvertTo-V07UtcText -Value ([DateTime]::UtcNow)
    if (-not $SkipBuild) {
        $invokeBuild = Join-Path $PSScriptRoot 'Invoke-Build.ps1'
        if (Test-Path -LiteralPath $invokeBuild -PathType Leaf) {
            Write-Host "Running build gate with configuration $Configuration..."
            & $invokeBuild -Configuration $Configuration -VerifyFormat
            if ($LASTEXITCODE -ne 0) {
                throw 'Build gate failed.'
            }
        }
    }
    Add-V07PhaseLog -Phase 'build' -Result 'OK' -Detail "Configuration $Configuration"

    $binding = New-V07CandidateBinding -RepositoryRoot $resolvedRepoRoot -CandidateDirectory $CandidateDirectory
    Write-Host "SourceCommit: $($binding.SourceCommit)"

    # -------------------------------------------------------------------------
    # Evidence phase: App runtime-evidence run + Core state serve
    # -------------------------------------------------------------------------
    $phaseStartedUtc = ConvertTo-V07UtcText -Value ([DateTime]::UtcNow)
    $coreExecutable = Join-Path $artifactRoot "bin\HerdrOps.Core\$($Configuration.ToLowerInvariant())\HerdrOps.Core.exe"
    $appExecutable = Join-Path $artifactRoot "bin\HerdrOps.App\$($Configuration.ToLowerInvariant())\HerdrOps.App.exe"
    foreach ($executable in @($coreExecutable, $appExecutable)) {
        if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
            throw "Runtime executable not found: $executable"
        }
    }

    $databasePath = Join-Path $evidenceDirectory 'herdrops-measurement.db'
    $coreReportPath = Join-Path $evidenceDirectory 'core-runtime.json'
    $appReportPath = Join-Path $evidenceDirectory 'app-runtime.json'
    $progressPath = Join-Path $evidenceDirectory 'app-progress.json'
    $captureDirectory = Join-Path $evidenceDirectory 'captures'
    $coreOutputPath = Join-Path $evidenceDirectory 'core.stdout.log'
    $coreErrorPath = Join-Path $evidenceDirectory 'core.stderr.log'
    $completionSignalPath = Join-Path $evidenceDirectory "core-completion-$([Guid]::NewGuid().ToString('N')).signal"
    New-Item -ItemType Directory -Path $captureDirectory -Force | Out-Null

    $coreDurationSeconds = [Math]::Min(3600, $DurationSeconds + $IdleSeconds + 30)
    $coreArguments = @(
        'serve-herdr-state',
        '--database', $databasePath,
        '--herdr', $session.HerdrExecutablePath,
        '--socket-path', $session.TargetHerdrSocketPath,
        '--seconds', $coreDurationSeconds,
        '--report', $coreReportPath,
        '--completion-signal', $completionSignalPath
    )
    $appArguments = @(
        '--runtime-evidence-report', $appReportPath,
        '--capture-directory', $captureDirectory,
        '--progress-report', $progressPath,
        '--core-pid', '0',
        '--timeout-seconds', $DurationSeconds,
        '--idle-seconds', $IdleSeconds,
        '--language', 'Thai'
    )

    $coreProcess = $null
    $appProcess = $null
    try {
        Write-Host 'Starting Core state service for the exact target session...'
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

        Write-Host 'Starting App runtime-evidence mode. Follow the phase instructions printed below.'
        $appProcess = Start-Process `
            -FilePath $appExecutable `
            -ArgumentList $appArguments `
            -WindowStyle Normal `
            -PassThru

        $lastPhase = ''
        $appDeadlineUtc = [DateTime]::UtcNow.AddSeconds($DurationSeconds + 30)
        while (-not $appProcess.HasExited -and [DateTime]::UtcNow -lt $appDeadlineUtc -and -not $cancelled) {
            Assert-V07WithinDeadline -Phase 'App runtime evidence'
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
                                Write-Host 'Event A: trigger one genuine Agent-status transition in the target Agent Lab. Focus, workspace, tab, and pane changes do not count.'
                            }
                            'dashboard-closed-waiting-for-herdr-disconnect' {
                                Write-Host 'Dashboard closed; the Floating Vertical Widget remains. Restart only the target Agent Lab Herdr session now. Never restart the Acceptance control session. Do not trigger Event B yet.'
                            }
                            'herdr-disconnected-waiting-for-reconnect' {
                                Write-Host 'The target Agent Lab is disconnected. Wait for the Floating Vertical Widget to return to LIVE. Do not trigger Event B until the reconnect phase appears.'
                            }
                            'herdr-reconnected-waiting-for-post-reconnect-update' {
                                Write-Host 'The target Agent Lab has reconnected and the Widget is LIVE. Now trigger Event B with a second genuine Agent-status transition.'
                            }
                            'waiting-for-idle-stability' {
                                Write-Host 'Event B arrived. Leave Herdr, Core, and App untouched while the gate waits for stable live state.'
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
            Start-Sleep -Milliseconds 500
            $appProcess.Refresh()
        }

        $appProcess.Refresh()
        if (-not $appProcess.HasExited) {
            throw 'The App runtime-evidence process exceeded the bounded gate duration.'
        }

        # Raw sample extraction from the App and Core evidence reports.
        if (-not (Test-Path -LiteralPath $appReportPath -PathType Leaf)) {
            throw 'App runtime-evidence report was not produced.'
        }
        if (-not (Test-Path -LiteralPath $coreReportPath -PathType Leaf)) {
            throw 'Core runtime trace report was not produced.'
        }
        $appReport = Get-Content -LiteralPath $appReportPath -Raw | ConvertFrom-Json
        $coreTrace = Get-Content -LiteralPath $coreReportPath -Raw | ConvertFrom-Json

        $coreRole = [pscustomobject]@{
            Role = 'Core'
            ProcessId = [long]$coreProcess.Id
            ProcessStartUtc = ConvertTo-V07UtcText -Value $coreProcess.StartTime.ToUniversalTime()
            BinaryPath = (Resolve-Path -LiteralPath $coreExecutable).Path
            BinarySha256 = Get-V07Sha256Hex -Path $coreExecutable
        }
        $appRole = [pscustomobject]@{
            Role = 'App'
            ProcessId = [long]$appProcess.Id
            ProcessStartUtc = ConvertTo-V07UtcText -Value $appProcess.StartTime.ToUniversalTime()
            BinaryPath = (Resolve-Path -LiteralPath $appExecutable).Path
            BinarySha256 = Get-V07Sha256Hex -Path $appExecutable
        }

        $deltaLatencySamples = [System.Collections.Generic.List[object]]::new()
        foreach ($extracted in @(Get-V07DeltaLatencySamplesFromAppReport -AppReport $appReport -CoreProcessId $coreRole.ProcessId -AppProcessId $appRole.ProcessId)) {
            $deltaLatencySamples.Add($extracted)
        }
        $reconnectSamples = [System.Collections.Generic.List[object]]::new()
        foreach ($extracted in @(Get-V07ReconnectSamplesFromCoreTrace -CoreTraceReport $coreTrace)) {
            $reconnectSamples.Add($extracted)
        }

        # Idle resource sampling: the harness samples the bound Core and App
        # processes during the App-reported idle window.
        Write-Host "Sampling idle CPU and combined working set for $IdleSeconds seconds..."
        $sampleIntervalMs = 500
        $sampleCount = [int]([Math]::Floor(($IdleSeconds * 1000) / $sampleIntervalMs))
        $appProc = Get-Process -Id ([int]$appRole.ProcessId) -ErrorAction Stop
        $coreProc = Get-Process -Id ([int]$coreRole.ProcessId) -ErrorAction Stop
        $appCpuStart = $appProc.TotalProcessorTime
        $coreCpuStart = $coreProc.TotalProcessorTime
        $samplingWatch = [System.Diagnostics.Stopwatch]::StartNew()
        $ordinal = 0
        while ($samplingWatch.Elapsed.TotalSeconds -lt $IdleSeconds -and $ordinal -lt $sampleCount -and -not $cancelled) {
            Assert-V07WithinDeadline -Phase 'Idle resource sampling'
            Start-Sleep -Milliseconds $sampleIntervalMs
            $appProc.Refresh()
            $coreProc.Refresh()
            if ($appProc.HasExited -or $coreProc.HasExited) {
                throw 'The App or Core process exited during idle resource sampling.'
            }
            $ordinal++
            $observedUtc = ConvertTo-V07UtcText -Value ([DateTime]::UtcNow)
            $elapsedSeconds = $samplingWatch.Elapsed.TotalSeconds
            $cpuPercent = ([Math]::Max(0.0, ($appProc.TotalProcessorTime - $appCpuStart).TotalMilliseconds) +
                [Math]::Max(0.0, ($coreProc.TotalProcessorTime - $coreCpuStart).TotalMilliseconds)) /
                $elapsedSeconds / 1000 / [Environment]::ProcessorCount * 100
            $cpuPercent = [Math]::Min(100.0, [Math]::Round($cpuPercent, 3))
            $combinedBytes = [long]($appProc.WorkingSet64 + $coreProc.WorkingSet64)
            $cpuSamples.Add([pscustomobject]@{ ObservedUtc = $observedUtc; Percent = $cpuPercent; SampleOrdinal = $ordinal })
            $workingSetSamples.Add([pscustomobject]@{ ObservedUtc = $observedUtc; Bytes = $combinedBytes; SampleOrdinal = $ordinal })
        }
        $samplingWatch.Stop()

        Add-V07PhaseLog -Phase 'latency-reconnect-idle' -Result 'OK' -Detail "Latency samples: $($deltaLatencySamples.Count); reconnect samples: $($reconnectSamples.Count); cpu samples: $($cpuSamples.Count); working-set samples: $($workingSetSamples.Count)"
    } catch {
        if ($cancelled) {
            $timedOut = $false
            $terminationReason = 'Operator cancellation (Ctrl+C).'
        } else {
            $terminationReason = $_.Exception.Message
        }
        throw
    } finally {
        if ($null -ne $appProcess) {
            if (-not $appProcess.HasExited) {
                try { $appProcess.CloseMainWindow() | Out-Null } catch { }
                Start-Sleep -Milliseconds 500
                $appProcess.Refresh()
                if (-not $appProcess.HasExited) {
                    $appProcess.Kill()
                }
            }
            $appProcess.Dispose()
        }
        if ($null -ne $coreProcess) {
            if (-not $coreProcess.HasExited) {
                try { $coreProcess.Kill() } catch { }
            }
            $coreProcess.Dispose()
        }
    }

    # -------------------------------------------------------------------------
    # Launch p95 phase: N cold dashboard launches, spawn -> initial live state
    # -------------------------------------------------------------------------
    if (-not $SkipLaunchPhase) {
        $phaseStartedUtc = ConvertTo-V07UtcText -Value ([DateTime]::UtcNow)
        for ($runIndex = 1; $runIndex -le $LaunchRuns; $runIndex++) {
            if ($cancelled) { break }
            Assert-V07WithinDeadline -Phase 'Launch p95 sampling'
            $launchReportPath = Join-Path $evidenceDirectory "app-launch-$runIndex.json"
            $launchProgressPath = Join-Path $evidenceDirectory "app-launch-$runIndex-progress.json"
            $launchArgs = @(
                '--runtime-evidence-report', $launchReportPath,
                '--capture-directory', (Join-Path $evidenceDirectory "launch-captures-$runIndex"),
                '--progress-report', $launchProgressPath,
                '--core-pid', $coreRole.ProcessId.ToString([Globalization.CultureInfo]::InvariantCulture),
                '--timeout-seconds', 60,
                '--idle-seconds', 5,
                '--language', 'Thai'
            )
            $spawnUtc = [DateTime]::UtcNow
            $launchProcess = Start-Process -FilePath $appExecutable -ArgumentList $launchArgs -WindowStyle Hidden -PassThru
            $liveUtc = $null
            $liveOffset = $null
            $termination = 'Kill'
            $launchDeadlineUtc = $spawnUtc.AddSeconds(60)
            while (-not $launchProcess.HasExited -and [DateTime]::UtcNow -lt $launchDeadlineUtc -and -not $cancelled) {
                if (Test-Path -LiteralPath $launchProgressPath -PathType Leaf) {
                    try {
                        $launchProgress = Get-Content -LiteralPath $launchProgressPath -Raw | ConvertFrom-Json
                        if ([string]$launchProgress.Phase -eq 'capturing-live-dashboard-and-widgets') {
                            $liveOffset = [DateTimeOffset]$launchProgress.ObservedUtc
                            $liveUtc = ConvertTo-V07UtcText -Value $liveOffset
                            break
                        }
                    } catch {
                        # atomic write in progress; retry
                    }
                }
                Start-Sleep -Milliseconds 100
                $launchProcess.Refresh()
            }
            if ($null -eq $liveUtc) {
                if (-not $cancelled) {
                    Write-Warning "Launch run $runIndex did not reach live state within 60 s; the sample is not retained."
                }
            } else {
                $elapsedMs = [Math]::Round(($liveOffset - [DateTimeOffset]$spawnUtc.ToUniversalTime()).TotalMilliseconds, 1)
                try {
                    $launchProcess.CloseMainWindow() | Out-Null
                    Start-Sleep -Milliseconds 300
                    $launchProcess.Refresh()
                    if ($launchProcess.HasExited) { $termination = 'Graceful' }
                } catch { }
                if (-not $launchProcess.HasExited) {
                    $launchProcess.Kill()
                    $termination = 'Kill'
                }
                $launchSamples.Add([pscustomobject]@{
                    RunOrdinal = $runIndex
                    ObservedUtc = $liveUtc
                    Milliseconds = $elapsedMs
                    AppProcessId = [long]$appRole.ProcessId
                    CoreProcessId = [long]$coreRole.ProcessId
                    Termination = $termination
                })
                Write-Host "Launch run ${runIndex}: $elapsedMs ms ($termination)"
            }
            $launchProcess.Dispose()
        }
        Add-V07PhaseLog -Phase 'launch-p95' -Result 'OK' -Detail "Retained launch samples: $($launchSamples.Count)"
    }

    # -------------------------------------------------------------------------
    # Assembly + admission + budget-target evaluation + finalization
    # -------------------------------------------------------------------------
    $phaseStartedUtc = ConvertTo-V07UtcText -Value ([DateTime]::UtcNow)
    $finishedUtcText = ConvertTo-V07UtcText -Value ([DateTime]::UtcNow)

    $metrics = [pscustomobject]@{
        DashboardColdLaunchP95Ms = if ($launchSamples.Count -gt 0) {
            [Math]::Round((Get-V07P95 -Samples ([double[]]@($launchSamples | ForEach-Object { [double]$_.Milliseconds }))), 1)
        } else { 0.0 }
        WidgetStateDeltaLatencyP95Ms = if ($deltaLatencySamples.Count -gt 0) {
            [Math]::Round((Get-V07P95 -Samples ([double[]]@($deltaLatencySamples | ForEach-Object { [double]$_.Milliseconds }))), 1)
        } else { 0.0 }
        HerdrReconnectReconcileSeconds = if ($reconnectSamples.Count -gt 0) {
            [Math]::Round(([double[]]@($reconnectSamples | ForEach-Object { [double]$_.Seconds }) | Measure-Object -Maximum).Maximum, 3)
        } else { 0.0 }
        IdleCpuAveragePercent = if ($cpuSamples.Count -gt 0) {
            [Math]::Round(([double[]]@($cpuSamples | ForEach-Object { [double]$_.Percent }) | Measure-Object -Average).Average, 3)
        } else { 0.0 }
        IdleWorkingSetCombinedBytes = if ($workingSetSamples.Count -gt 0) {
            [long][Math]::Round(([double[]]@($workingSetSamples | ForEach-Object { [double]$_.Bytes }) | Measure-Object -Average).Average)
        } else { 0 }
        UnboundedTerminalReads = 0
        UnhandledCrashesDuringSoak = 0
        SoakDurationHours = 0.0
        AdministratorRequired = $false
    }
    $observed = [pscustomobject]@{
        DashboardColdLaunch = ($launchSamples.Count -ge $script:V07MeasurementMinLaunchSamples)
        WidgetStateDeltaLatency = ($deltaLatencySamples.Count -ge $script:V07MeasurementMinLatencySamples)
        HerdrReconnectReconcile = ($reconnectSamples.Count -ge $script:V07MeasurementMinReconnectSamples)
        IdleCpu = ($cpuSamples.Count -ge $script:V07MeasurementMinCpuSamples)
        IdleWorkingSet = ($workingSetSamples.Count -ge $script:V07MeasurementMinWorkingSetSamples)
    }
    $rawSamples = [pscustomobject]@{
        DashboardColdLaunch = @($launchSamples)
        WidgetStateDeltaLatency = @($deltaLatencySamples)
        HerdrReconnectReconcile = @($reconnectSamples)
        IdleCpu = @($cpuSamples)
        IdleWorkingSet = @($workingSetSamples)
    }
    $hostEnvironment = [pscustomobject]@{
        Os = [System.Environment]::OSVersion.VersionString
        Architecture = if ([System.Environment]::Is64BitOperatingSystem) { 'x64' } else { 'x86' }
        LogicalProcessors = [Environment]::ProcessorCount
        ReferenceHostConfirmed = $true
    }

    $artifact = New-V07MeasurementArtifact -RunId $runId -StartedUtc $startedUtcText -FinishedUtc $finishedUtcText `
        -Mode 'Live' -Cancelled:$cancelled -TimedOut:$timedOut -TerminationReason $terminationReason `
        -HostEnvironment $hostEnvironment -Session $session -Candidate $binding `
        -Roles @($coreRole, $appRole) -Metrics $metrics -Observed $observed -RawSamples $rawSamples `
        -PhaseLog @($phaseLog)

    $artifact | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $measurementArtifactPath -Encoding UTF8

    $admission = Test-V07MeasurementArtifactAdmission -Artifact $artifact -RepositoryRoot $resolvedRepoRoot -CandidateDirectory $CandidateDirectory
    $budgetChecks = Test-V07MeasurementBudgetTargets -Metrics $metrics

    # Finalization (requires a validated matching soak artifact).
    $finalization = $null
    if (-not [string]::IsNullOrWhiteSpace($SoakEvidencePath)) {
        $soakJson = Get-V07BoundedUtf8FileText -Path $SoakEvidencePath -Description 'Soak evidence'
        Assert-V07StrictJsonText -JsonText $soakJson -SourceDescription 'Soak evidence'
        $soakArtifact = $soakJson | ConvertFrom-Json
        $finalization = ConvertTo-V07RuntimeBudgetReport -MeasurementArtifact $artifact -SoakArtifact $soakArtifact -RepositoryRoot $resolvedRepoRoot -CandidateDirectory $CandidateDirectory
        if ($finalization.CanFinalize -and $null -ne $finalization.BudgetReport) {
            $finalization.BudgetReport | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $budgetReportPath -Encoding UTF8
        }
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('========================================================================')
    $lines.Add('HerdrOps v0.7.0 Performance Measurement Producer (Issue #39)')
    $lines.Add('========================================================================')
    $lines.Add("RunId:               $runId")
    $lines.Add("TimestampUtc:        $finishedUtcText")
    $lines.Add("SourceCommit:        $($binding.SourceCommit)")
    $lines.Add("Mode:                LIVE")
    $lines.Add("Cancelled:           $cancelled")
    $lines.Add("TimedOut:            $timedOut")
    $lines.Add("SessionControlInvoked: false")
    $lines.Add("ControlPaneId:       $($session.ControlPaneId)")
    $lines.Add("TargetHerdrSocket:   $($session.TargetHerdrSocketPath)")
    $lines.Add("HerdrExecutableSha256: $($session.HerdrExecutableSha256)")
    $lines.Add("ArtifactAdmission:   $(if ($admission.Valid) { 'PASS' } else { 'FAIL' })")
    if (-not $admission.Valid) {
        foreach ($failure in $admission.Failures) { $lines.Add("  - $failure") }
    }
    $lines.Add('')
    $lines.Add('--- OBSERVED METRICS (raw samples retained in measurement-run.json) ---')
    foreach ($check in $budgetChecks) {
        $lines.Add(("[{0,-13}] {1,-28} | Target: {2,-28} | Observed: {3}" -f $(if ($check.Passed) { 'PASS' } else { 'FAIL' }), $check.Id, $check.Target, $check.Observed))
    }
    $lines.Add("LaunchSamples:        $($launchSamples.Count)")
    $lines.Add("DeltaLatencySamples:  $($deltaLatencySamples.Count)")
    $lines.Add("ReconnectSamples:     $($reconnectSamples.Count)")
    $lines.Add("IdleCpuSamples:       $($cpuSamples.Count)")
    $lines.Add("WorkingSetSamples:    $($workingSetSamples.Count)")
    $lines.Add('')
    $lines.Add('--- EVIDENCE BOUNDARY ---')
    $lines.Add("ActualHerdrRuntime:   $(if ($admission.Valid -and $null -ne $finalization -and $finalization.CanFinalize) { 'OBSERVED (finalized)' } else { 'NOT OBSERVED / NOT CLAIMED' })")
    $lines.Add("SoakExecution:        $(if ($null -ne $finalization -and $finalization.CanFinalize) { 'OBSERVED (validated soak artifact)' } else { 'NOT OBSERVED / NOT CLAIMED' })")
    $lines.Add("HumanUatDecision:     NOT OBSERVED / PENDING")
    $lines.Add("ReleaseEvidence:      NOT OBSERVED / NOT CLAIMED")
    if ($null -ne $finalization -and -not $finalization.CanFinalize) {
        $lines.Add('')
        $lines.Add('--- FINALIZATION BLOCKED ---')
        $lines.Add("Reason: $($finalization.Reason)")
        foreach ($blocker in $finalization.Blockers) { $lines.Add("  - $blocker") }
    }
    $lines.Add('')
    $lines.Add("MeasurementArtifact: $measurementArtifactPath")
    if (Test-Path -LiteralPath $budgetReportPath -PathType Leaf) {
        $lines.Add("BudgetReport:         $budgetReportPath")
    }
    $lines.Add('========================================================================')
    $lines | Set-Content -LiteralPath $gateReportPath -Encoding UTF8
    $lines | ForEach-Object { Write-Host $_ }

    if (-not $admission.Valid) {
        Write-Host "`nMeasurement artifact failed admission; see $gateReportPath" -ForegroundColor Red
        exit 2
    }
    if ($cancelled -or $timedOut) {
        Write-Host "`nRun was cancelled or timed out; Runtime credit denied by design. See $gateReportPath" -ForegroundColor Yellow
        exit 3
    }
    Write-Host "`nMeasurementArtifactJson: $measurementArtifactPath"
    Write-Host "GateReport: $gateReportPath"
} catch {
    # -------------------------------------------------------------------------
    # Bounded fail-closed exit: retain the phase log and any partial raw
    # samples, mark cancellation/timeout explicitly, deny runtime credit, and
    # never write a Runtime budget report.
    # -------------------------------------------------------------------------
    $failureMessage = $_.Exception.Message
    if (-not $cancelled -and ([DateTime]::UtcNow -gt $deadline)) {
        $timedOut = $true
    }
    $terminationReason = if ($cancelled) {
        'Operator cancellation (Ctrl+C).'
    } elseif ($timedOut) {
        "Overall run deadline ($MaxRunSeconds s) exceeded."
    } else {
        $failureMessage
    }

    try {
        $finishedUtcText = ConvertTo-V07UtcText -Value ([DateTime]::UtcNow)
        $metrics = [pscustomobject]@{
            DashboardColdLaunchP95Ms = if ($launchSamples.Count -gt 0) { [Math]::Round((Get-V07P95 -Samples ([double[]]@($launchSamples | ForEach-Object { [double]$_.Milliseconds }))), 1) } else { 0.0 }
            WidgetStateDeltaLatencyP95Ms = if ($deltaLatencySamples.Count -gt 0) { [Math]::Round((Get-V07P95 -Samples ([double[]]@($deltaLatencySamples | ForEach-Object { [double]$_.Milliseconds }))), 1) } else { 0.0 }
            HerdrReconnectReconcileSeconds = if ($reconnectSamples.Count -gt 0) { [Math]::Round(([double[]]@($reconnectSamples | ForEach-Object { [double]$_.Seconds }) | Measure-Object -Maximum).Maximum, 3) } else { 0.0 }
            IdleCpuAveragePercent = if ($cpuSamples.Count -gt 0) { [Math]::Round(([double[]]@($cpuSamples | ForEach-Object { [double]$_.Percent }) | Measure-Object -Average).Average, 3) } else { 0.0 }
            IdleWorkingSetCombinedBytes = if ($workingSetSamples.Count -gt 0) { [long][Math]::Round(([double[]]@($workingSetSamples | ForEach-Object { [double]$_.Bytes }) | Measure-Object -Average).Average) } else { 0 }
            UnboundedTerminalReads = 0
            UnhandledCrashesDuringSoak = 0
            SoakDurationHours = 0.0
            AdministratorRequired = $false
        }
        $observed = [pscustomobject]@{
            DashboardColdLaunch = ($launchSamples.Count -ge $script:V07MeasurementMinLaunchSamples)
            WidgetStateDeltaLatency = ($deltaLatencySamples.Count -ge $script:V07MeasurementMinLatencySamples)
            HerdrReconnectReconcile = ($reconnectSamples.Count -ge $script:V07MeasurementMinReconnectSamples)
            IdleCpu = ($cpuSamples.Count -ge $script:V07MeasurementMinCpuSamples)
            IdleWorkingSet = ($workingSetSamples.Count -ge $script:V07MeasurementMinWorkingSetSamples)
        }
        $rawSamples = [pscustomobject]@{
            DashboardColdLaunch = @($launchSamples)
            WidgetStateDeltaLatency = @($deltaLatencySamples)
            HerdrReconnectReconcile = @($reconnectSamples)
            IdleCpu = @($cpuSamples)
            IdleWorkingSet = @($workingSetSamples)
        }
        $partialHost = if ($null -eq $hostEnvironment) {
            [pscustomobject]@{
                Os = [System.Environment]::OSVersion.VersionString
                Architecture = if ([System.Environment]::Is64BitOperatingSystem) { 'x64' } else { 'x86' }
                LogicalProcessors = [Environment]::ProcessorCount
                ReferenceHostConfirmed = $false
            }
        } else { $hostEnvironment }
        $partialSession = if ($null -eq $session) {
            [pscustomobject]@{
                ControlPaneId = ''
                ObservedControlPaneId = ''
                ControlHerdrSocketPath = ''
                TargetHerdrSocketPath = ''
                SeparateSessions = $false
                HerdrExecutablePath = ''
                HerdrExecutableSha256 = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
                HerdrReleaseId = ''
                ControlHerdrServerIdentity = [pscustomobject]@{
                    ProcessId = 0
                    ProcessStartUtc = $startedUtcText
                    ExecutablePath = ''
                    ExecutableSha256 = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
                }
            }
        } else { $session }
        $partialBinding = if ($null -eq $binding) {
            $sourceCommit = ''
            try { $sourceCommit = Test-V07CleanRepositoryState -RepositoryRoot $resolvedRepoRoot -SkipCleanCheck } catch { }
            [pscustomobject]@{
                SourceCommit = $sourceCommit
                GitTreeClean = $false
                Binaries = @()
            }
        } else { $binding }
        $partialRoles = if ($null -ne $coreRole -or $null -ne $appRole) {
            @(@($coreRole) + @($appRole) | Where-Object { $null -ne $_ })
        } else { @() }

        $artifact = New-V07MeasurementArtifact -RunId $runId -StartedUtc $startedUtcText -FinishedUtc $finishedUtcText `
            -Mode 'Live' -Cancelled:$cancelled -TimedOut:$timedOut -TerminationReason $terminationReason `
            -HostEnvironment $partialHost -Session $partialSession -Candidate $partialBinding `
            -Roles $partialRoles -Metrics $metrics -Observed $observed -RawSamples $rawSamples `
            -PhaseLog @($phaseLog)
        $artifact | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $measurementArtifactPath -Encoding UTF8
    } catch {
        Write-Warning "Could not retain a partial measurement artifact: $($_.Exception.Message)"
    }

    try {
        $lines = @(
            'HerdrOps v0.7.0 Performance Measurement Producer (Issue #39)',
            "GeneratedUtc: $([DateTimeOffset]::UtcNow.ToString('O'))",
            "RunId: $runId",
            'Result: FAIL (FAILED CLOSED)',
            'EvidenceClass: NoRuntimeCredit',
            'SessionControlInvoked: false',
            "Cancelled: $cancelled",
            "TimedOut: $timedOut",
            "TerminationReason: $terminationReason",
            "Failure: $failureMessage",
            '',
            'This run observed no admitted complete evidence set. Runtime credit is denied.',
            "MeasurementArtifact: $measurementArtifactPath",
            "GateReport: $gateReportPath"
        )
        $lines | Set-Content -LiteralPath $gateReportPath -Encoding UTF8
        $lines | ForEach-Object { Write-Host $_ }
    } catch {
        Write-Warning "Could not write the failure gate report: $($_.Exception.Message)"
    }
    Write-Error "Performance measurement run failed closed: $failureMessage"
    exit 4
} finally {
    if ($null -ne $cancelEvent) {
        try { Unregister-Event -SubscriptionId $cancelEvent.Id -ErrorAction SilentlyContinue } catch { }
    }
}
