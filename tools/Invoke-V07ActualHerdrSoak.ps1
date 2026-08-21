<#!
.SYNOPSIS
    Issue #39 actual-Herdr v0.7.0 eight-hour soak producer/operator harness.

.DESCRIPTION
    Attaches read-only to an already running Herdr/Agent Lab target. It binds the
    exact clean source commit/tree, the measurement artifact, installed Herdr
    executable/package identity, bounded heartbeat/resource/runtime-observation
    logs, and operator-confirmed scheduled fault observations. It never invokes
    Herdr control commands and never starts, stops, or restarts the product roles.

    This command is intentionally live-only. Do not run it from the preparation
    gate or from a default Herdr pane. The committed tests exercise the policy
    and fail-closed paths without invoking this command.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TargetHerdrSocketPath,
    [string]$HerdrExecutable = (Join-Path $env:LOCALAPPDATA 'Programs\Herdr\bin\herdr.exe'),
    [string]$RepositoryRoot = '',
    [string]$CandidateDirectory = '',
    [Parameter(Mandatory)][string]$MeasurementArtifactPath,
    [string]$FaultSchedulePath = '',
    [string]$OutDirectory = '',
    [double]$DurationHours = 8.0,
    [ValidateRange(10, 3600)][int]$HeartbeatSeconds = 60,
    [ValidateRange(10, 3600)][int]$ObservationWindowSeconds = 60,
    [string]$ObserverExecutable = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

if ($DurationHours -lt 8.0) { throw 'DurationHours must be at least 8.0; shorter runs cannot satisfy the v0.7 soak gate.' }
if ($ObservationWindowSeconds -gt $HeartbeatSeconds) { throw 'ObservationWindowSeconds cannot exceed HeartbeatSeconds; the heartbeat cadence must not hide an observation gap.' }
if ($env:HERDR_ENV -ne '1') { throw 'Actual-Herdr soak requires HERDR_ENV=1 from the isolated Acceptance control pane.' }
if ([string]::IsNullOrWhiteSpace($env:HERDR_SOCKET_PATH) -or [string]::IsNullOrWhiteSpace($env:HERDR_PANE_ID)) {
    throw 'Actual-Herdr soak requires HERDR_SOCKET_PATH and HERDR_PANE_ID from the isolated Acceptance control pane.'
}

$policyPath = Join-Path $PSScriptRoot 'lib\V07SoakProducerPolicy.ps1'
. $policyPath

$resolvedRoot = if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
} else { (Resolve-Path -LiteralPath $RepositoryRoot).Path }
Assert-V07NotReparsePoint -Path $resolvedRoot -Description 'Repository root'

$resolvedCandidate = if ([string]::IsNullOrWhiteSpace($CandidateDirectory)) {
    Join-Path $resolvedRoot 'artifacts\bin'
} else { (Resolve-Path -LiteralPath $CandidateDirectory).Path }
Assert-V07NotReparsePoint -Path $resolvedCandidate -Description 'Candidate directory'

$measurementText = Get-V07BoundedUtf8FileText -Path $MeasurementArtifactPath -Description 'measurement artifact'
Assert-V07StrictJsonText -JsonText $measurementText -SourceDescription 'measurement artifact'
$measurementArtifact = $measurementText | ConvertFrom-Json
if ([string]$measurementArtifact.Mode -cne 'Live') { throw 'The soak producer requires a Live v0.7 measurement artifact; synthetic preparation evidence is not eligible.' }
$measurementAdmission = Test-V07MeasurementArtifactAdmission -Artifact $measurementArtifact -RepositoryRoot $resolvedRoot -CandidateDirectory $resolvedCandidate
if (-not $measurementAdmission.Valid) { throw "Measurement artifact admission failed: $($measurementAdmission.Failures -join '; ')" }

$binding = New-V07CandidateBinding -RepositoryRoot $resolvedRoot -CandidateDirectory $resolvedCandidate
$measurementTree = if ($null -ne $measurementArtifact.Candidate.PSObject.Properties['SourceTree']) { [string]$measurementArtifact.Candidate.SourceTree } else { '' }
if ([string]$measurementArtifact.Candidate.SourceCommit -cne [string]$binding.SourceCommit) { throw 'Measurement artifact source commit does not match the current clean candidate.' }
if (-not [string]::IsNullOrWhiteSpace($measurementTree) -and $measurementTree -cne [string]$binding.SourceTree) { throw 'Measurement artifact source tree does not match the current candidate tree.' }

$session = Test-V07LiveSessionAdmission -HerdrExecutable $HerdrExecutable -TargetHerdrSocketPath $TargetHerdrSocketPath
$installedHerdr = Get-V07InstalledHerdrIdentity -HerdrExecutable $session.HerdrExecutablePath
if ([string]$installedHerdr.ExecutableSha256 -ine [string]$session.HerdrExecutableSha256 -or
    [string]$installedHerdr.ExecutableSha256 -ine [string]$measurementArtifact.Session.HerdrExecutableSha256) {
    throw 'Installed Herdr identity does not match the admitted measurement/control session.'
}

$schedule = if ([string]::IsNullOrWhiteSpace($FaultSchedulePath)) {
    @(Get-V07SoakDefaultSchedule -DurationHours $DurationHours)
} else {
    $scheduleText = Get-V07BoundedUtf8FileText -Path $FaultSchedulePath -MaxBytes 65536 -Description 'fault schedule'
    Assert-V07StrictJsonText -JsonText $scheduleText -SourceDescription 'fault schedule'
    $parsedSchedule = $scheduleText | ConvertFrom-Json
    if ($parsedSchedule -isnot [Array]) { throw 'Fault schedule JSON root must be an array.' }
    @($parsedSchedule)
}
$scheduleCheck = Test-V07SoakSchedule -Schedule $schedule -DurationHours $DurationHours
if (-not $scheduleCheck.Valid) { throw "Fault schedule is invalid: $($scheduleCheck.Failures -join '; ')" }

$coreRole = @($measurementArtifact.Roles | Where-Object { [string]$_.Role -ceq 'Core' })[0]
$appRole = @($measurementArtifact.Roles | Where-Object { [string]$_.Role -ceq 'App' })[0]
if ($null -eq $coreRole -or $null -eq $appRole) { throw 'Measurement artifact must retain both Core and App role identities.' }
$coreProcessId = [int]$coreRole.ProcessId
$appProcessId = [int]$appRole.ProcessId
$herdrProcessId = [int]$session.ControlHerdrServerIdentity.ProcessId

$observer = if ([string]::IsNullOrWhiteSpace($ObserverExecutable)) {
    Join-Path $resolvedRoot 'artifacts\bin\HerdrOps.Core\release\HerdrOps.Core.exe'
} else { $ObserverExecutable }
$observer = (Resolve-Path -LiteralPath $observer).Path
Assert-V07NotReparsePoint -Path $observer -Description 'HerdrOps.Core observer executable'

$runId = "$([DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssfffZ', [Globalization.CultureInfo]::InvariantCulture))-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
$outRoot = if ([string]::IsNullOrWhiteSpace($OutDirectory)) {
    Join-Path $resolvedRoot "artifacts\runtime-evidence\v0.7\issue-39\soak-$runId"
} else { [IO.Path]::GetFullPath($OutDirectory) }
$outRoot = Assert-V07PathWithinRoot -Path $outRoot -AllowedRoots @($resolvedRoot) -Description 'soak output directory'
if (Test-Path -LiteralPath $outRoot) {
    if (@(Get-ChildItem -LiteralPath $outRoot -Force).Count -gt 0) { throw "Soak output directory already exists and is not empty: $outRoot" }
} else {
    New-Item -ItemType Directory -Path $outRoot -Force | Out-Null
}
Assert-V07NotReparsePoint -Path $outRoot -Description 'soak output directory'
$operatorRoot = Join-Path $outRoot 'operator-observations'
New-Item -ItemType Directory -Path $operatorRoot -Force | Out-Null

$heartbeatLogPath = Join-Path $outRoot 'heartbeat.jsonl'
$faultLogPath = Join-Path $outRoot 'fault-observations.jsonl'
$resourceLogPath = Join-Path $outRoot 'resources.jsonl'
$runtimeLogPath = Join-Path $outRoot 'runtime-observations.jsonl'
$runtimeReportPath = Join-Path $outRoot 'runtime-observer-current.json'
$artifactPath = Join-Path $outRoot 'soak-artifact.json'
$gateReportPath = Join-Path $outRoot 'soak-gate-report.txt'
foreach ($path in @($heartbeatLogPath, $faultLogPath, $resourceLogPath, $runtimeLogPath)) { [IO.File]::WriteAllText($path, '', (New-Object System.Text.UTF8Encoding($false))) }
[IO.File]::WriteAllText($runtimeReportPath, '', (New-Object System.Text.UTF8Encoding($false)))

$logStates = @{
    heartbeat = @{ EntryCount = 0; ByteCount = 0L }
    fault = @{ EntryCount = 0; ByteCount = 0L }
    resource = @{ EntryCount = 0; ByteCount = 0L }
    runtime = @{ EntryCount = 0; ByteCount = 0L }
}
$heartbeatEntries = [System.Collections.Generic.List[object]]::new()
$faultEntries = [System.Collections.Generic.List[object]]::new()
$resourceSamples = [System.Collections.Generic.List[object]]::new()
$runtimeSummaries = [System.Collections.Generic.List[object]]::new()
$previousSnapshots = @{}
$previousHeartbeatSha = '0' * 64
$previousFaultSha = '0' * 64
$resolvedFaults = @{}
$announcedFaults = @{}
$runtimeObservationFailures = 0
$stateEvidenceCount = 0
$observedEvents = 0
$observedReconnects = 0
$unhandledCrashes = 0
$terminationReason = ''
$cancelled = $false
$timedOut = $false
$started = [DateTimeOffset]::UtcNow
$deadline = $started.AddHours($DurationHours)

function Invoke-V07RuntimeObserver {
    param([Parameter(Mandatory)][int]$Seconds)

    $arguments = @(
        'trace-herdr-runtime', '--seconds', [string]$Seconds,
        '--herdr', [string]$installedHerdr.ExecutablePath,
        '--socket-path', [string]$session.TargetHerdrSocketPath,
        '--report', [string]$runtimeReportPath
    )
    try {
        $process = Start-Process -FilePath $observer -ArgumentList $arguments -WorkingDirectory $resolvedRoot -NoNewWindow -PassThru -Wait
        if ($process.ExitCode -ne 0) { throw "observer exited with code $($process.ExitCode)" }
        $json = Get-V07BoundedUtf8FileText -Path $runtimeReportPath -Description 'runtime observer report'
        Assert-V07StrictJsonText -JsonText $json -SourceDescription 'runtime observer report'
        $report = $json | ConvertFrom-Json
        if ([bool]$report.SessionControlInvoked) { throw 'runtime observer reported SessionControlInvoked=true' }
        if (-not [bool]$report.RuntimeObserved -or -not [bool]$report.SnapshotObserved) { throw 'runtime observer did not retain actual Herdr snapshot evidence' }
        $state = $report.FinalMonitorState
        if ($null -eq $state) { throw 'runtime observer omitted FinalMonitorState' }
        return [pscustomobject][ordered]@{
            ObservedUtc = ConvertTo-V07SoakUtcText -Value ([DateTimeOffset]::UtcNow)
            RuntimeObserved = [bool]$report.RuntimeObserved
            SnapshotObserved = [bool]$report.SnapshotObserved
            EventObserved = [bool]$report.EventObserved
            ReconnectObserved = [bool]$report.ReconnectObserved
            TransitionCount = @($report.Transitions).Count
            FinalStateSha256 = [string]$report.FinalProjectedStateSha256
            Status = 'Observed'
            Detail = [string]$report.Message
        }
    } catch {
        return [pscustomobject][ordered]@{
            ObservedUtc = ConvertTo-V07SoakUtcText -Value ([DateTimeOffset]::UtcNow)
            RuntimeObserved = $false; SnapshotObserved = $false; EventObserved = $false; ReconnectObserved = $false
            TransitionCount = 0; FinalStateSha256 = ''; Status = 'Fault'; Detail = $_.Exception.Message
        }
    }
}

function Add-V07ScheduledFault {
    param([Parameter(Mandatory)]$Scheduled, $OperatorObservation)

    $fault = [pscustomobject][ordered]@{
        Id = [string]$Scheduled.Id
        Kind = [string]$Scheduled.Kind
        ScheduledOffsetSeconds = [int]$Scheduled.OffsetSeconds
        DueUtc = ConvertTo-V07SoakUtcText -Value $started.AddSeconds([int]$Scheduled.OffsetSeconds)
        ObservedUtc = if ($null -ne $OperatorObservation) { [string]$OperatorObservation.ObservedUtc } else { ConvertTo-V07SoakUtcText -Value ([DateTimeOffset]::UtcNow) }
        Status = if ($null -ne $OperatorObservation) { 'Observed' } else { 'Missing' }
        OperatorAcknowledged = if ($null -ne $OperatorObservation) { [bool]$OperatorObservation.OperatorAcknowledged } else { $false }
        EvidencePath = if ($null -ne $OperatorObservation) { [string]$OperatorObservation.EvidencePath } else { '' }
        EvidenceSha256 = if ($null -ne $OperatorObservation) { [string]$OperatorObservation.EvidenceSha256 } else { '0' * 64 }
        Note = if ($null -ne $OperatorObservation) { [string]$OperatorObservation.Note } else { 'No operator observation marker was supplied before the soak ended.' }
        PreviousEntrySha256 = $script:previousFaultSha
        EntrySha256 = ''
    }
    $fault.EntrySha256 = Get-V07SoakEntrySha256 -Entry $fault
    $script:previousFaultSha = [string]$fault.EntrySha256
    $faultEntries.Add($fault)
    Add-V07SoakJsonLine -Path $faultLogPath -Entry $fault -State $logStates.fault -MaxEntries $script:V07SoakMaxFaultObservations -MaxBytes $script:V07SoakMaxArtifactBytes
}

function Test-V07DueFaults {
    param([Parameter(Mandatory)][DateTimeOffset]$Now)

    foreach ($scheduled in $schedule) {
        $due = $started.AddSeconds([int]$scheduled.OffsetSeconds)
        if ($Now -lt $due -or $resolvedFaults.ContainsKey([string]$scheduled.Id)) { continue }
        $id = [string]$scheduled.Id
        $markerPath = Join-Path $operatorRoot ($id + '.json')
        if (-not $announcedFaults.ContainsKey($id)) {
            $announcedFaults[$id] = $true
            Write-Host "SCHEDULED OBSERVATION DUE [$id] $($scheduled.Kind): $($scheduled.Instruction)"
            Write-Host "Write the operator marker only after the target-session action/observation: $markerPath"
        }
        if (Test-Path -LiteralPath $markerPath -PathType Leaf) {
            $operatorObservation = Read-V07SoakOperatorObservation -ObservationPath $markerPath -ExpectedId $id -EvidenceRoot $outRoot
            Add-V07ScheduledFault -Scheduled $scheduled -OperatorObservation $operatorObservation
            $resolvedFaults[$id] = $true
        } elseif ($Now -ge $deadline) {
            Add-V07ScheduledFault -Scheduled $scheduled -OperatorObservation $null
            $resolvedFaults[$id] = $true
        }
    }
}

try {
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        $runtime = Invoke-V07RuntimeObserver -Seconds $ObservationWindowSeconds
        $runtimeSummaries.Add($runtime)
        Add-V07SoakJsonLine -Path $runtimeLogPath -Entry $runtime -State $logStates.runtime -MaxEntries $script:V07SoakMaxHeartbeatEntries -MaxBytes $script:V07SoakMaxArtifactBytes
        $runtimeObservationCount = $runtimeSummaries.Count
        if ([string]$runtime.Status -ne 'Observed') { $runtimeObservationFailures++ } else {
            $stateEvidenceCount++
            if ([bool]$runtime.EventObserved) { $observedEvents++ }
            if ([bool]$runtime.ReconnectObserved) { $observedReconnects++ }
        }
        if ([string]$runtime.Status -ne 'Observed') { $unhandledCrashes++ }

        Test-V07DueFaults -Now ([DateTimeOffset]::UtcNow)
        $heartbeat = New-V07SoakHeartbeatEntry -Ordinal ($heartbeatEntries.Count + 1) -TargetHerdrSocketPath $session.TargetHerdrSocketPath `
            -InstalledHerdr $installedHerdr -HerdrProcessId $herdrProcessId -CoreProcessId $coreProcessId -AppProcessId $appProcessId `
            -PreviousSnapshots $previousSnapshots -PreviousEntrySha256 $previousHeartbeatSha
        $heartbeatEntries.Add($heartbeat.Entry)
        $previousHeartbeatSha = [string]$heartbeat.Entry.EntrySha256
        Add-V07SoakJsonLine -Path $heartbeatLogPath -Entry $heartbeat.Entry -State $logStates.heartbeat -MaxEntries $script:V07SoakMaxHeartbeatEntries -MaxBytes $script:V07SoakMaxArtifactBytes
        if (-not $heartbeat.Healthy) { $unhandledCrashes++ }
        $resource = New-V07SoakResourceSample -HerdrSnapshot $heartbeat.Herdr -CoreSnapshot $heartbeat.Core -AppSnapshot $heartbeat.App
        $resourceSamples.Add($resource)
        Add-V07SoakJsonLine -Path $resourceLogPath -Entry $resource -State $logStates.resource -MaxEntries $script:V07SoakMaxResourceSamples -MaxBytes $script:V07SoakMaxArtifactBytes

        $remaining = ($deadline - [DateTimeOffset]::UtcNow).TotalSeconds
        if ($remaining -gt 0) { Start-Sleep -Seconds ([int][Math]::Max(1, [Math]::Min($HeartbeatSeconds, $remaining))) }
    }
    Test-V07DueFaults -Now $deadline
} catch [System.Management.Automation.PipelineStoppedException] {
    $cancelled = $true
    $terminationReason = 'Operator cancellation stopped the bounded soak; Runtime credit is denied.'
} catch {
    $terminationReason = $_.Exception.Message
} finally {
    if ([string]::IsNullOrWhiteSpace($terminationReason)) { $terminationReason = 'Eight-hour observation window completed.' }
    $finished = [DateTimeOffset]::UtcNow
    foreach ($scheduled in $schedule) {
        $id = [string]$scheduled.Id
        if (-not $resolvedFaults.ContainsKey($id)) { Add-V07ScheduledFault -Scheduled $scheduled -OperatorObservation $null; $resolvedFaults[$id] = $true }
    }

    $missingHeartbeats = 0
    for ($index = 1; $index -lt $heartbeatEntries.Count; $index++) {
        $delta = ([DateTimeOffset]$heartbeatEntries[$index].ObservedUtc - [DateTimeOffset]$heartbeatEntries[$index - 1].ObservedUtc).TotalSeconds
        if ($delta -gt $HeartbeatSeconds) { $missingHeartbeats += [Math]::Max(0, [int][Math]::Floor($delta / $HeartbeatSeconds) - 1) }
    }
    $peakWorkingSet = 0L
    $peakCpu = 0.0
    foreach ($sample in $resourceSamples) {
        if ([long]$sample.CombinedWorkingSetBytes -gt $peakWorkingSet) { $peakWorkingSet = [long]$sample.CombinedWorkingSetBytes }
        if ([double]$sample.CombinedCpuPercent -gt $peakCpu) { $peakCpu = [double]$sample.CombinedCpuPercent }
    }
    $artifactManifests = @(
        Get-V07SoakLogManifest -Root $outRoot -RelativePath 'heartbeat.jsonl' -Entries $heartbeatEntries.Count
        Get-V07SoakLogManifest -Root $outRoot -RelativePath 'fault-observations.jsonl' -Entries $faultEntries.Count
        Get-V07SoakLogManifest -Root $outRoot -RelativePath 'resources.jsonl' -Entries $resourceSamples.Count
        Get-V07SoakLogManifest -Root $outRoot -RelativePath 'runtime-observations.jsonl' -Entries $runtimeSummaries.Count
        Get-V07SoakLogManifest -Root $outRoot -RelativePath 'runtime-observer-current.json' -Entries 1
    )
    $artifact = [pscustomobject][ordered]@{
        SchemaVersion = 'v0.7.0-soak'
        ArtifactKind = 'SoakRun'
        RunId = $runId
        StartedUtc = ConvertTo-V07SoakUtcText -Value $started
        FinishedUtc = ConvertTo-V07SoakUtcText -Value $finished
        Mode = 'Live'
        Cancelled = [bool]$cancelled
        TimedOut = [bool]($finished -lt $deadline -and -not $cancelled -and $runtimeObservationFailures -gt 0)
        MeasurementRunId = [string]$measurementArtifact.RunId
        MeasurementArtifactSha256 = Get-V07ArtifactCanonicalSha256 -Artifact $measurementArtifact
        Session = [pscustomobject][ordered]@{
            ControlPaneId = [string]$session.ControlPaneId; ObservedControlPaneId = [string]$session.ObservedControlPaneId
            ControlHerdrSocketPath = [string]$session.ControlHerdrSocketPath; TargetHerdrSocketPath = [string]$session.TargetHerdrSocketPath
            HerdrExecutablePath = [string]$installedHerdr.ExecutablePath; HerdrExecutableSha256 = [string]$installedHerdr.ExecutableSha256
            HerdrReleaseId = [string]$installedHerdr.ReleaseId
        }
        Candidate = [pscustomobject][ordered]@{
            SourceCommit = [string]$binding.SourceCommit; SourceTree = [string]$binding.SourceTree; GitTreeClean = [bool]$binding.GitTreeClean
            Binaries = @($binding.Binaries)
        }
        Soak = [pscustomobject][ordered]@{
            DurationHours = [Math]::Round(($finished - $started).TotalHours, 6)
            UnhandledCrashes = [int]$unhandledCrashes
            UnreconciledStateCount = [int]$runtimeObservationFailures
            UnboundedTerminalReads = [int]$measurementArtifact.Metrics.UnboundedTerminalReads
            RuntimeObservationCount = [int]$runtimeSummaries.Count; RuntimeObservationFailures = [int]$runtimeObservationFailures
            StateEvidenceCount = [int]$stateEvidenceCount; ObservedEvents = [int]$observedEvents; ObservedReconnects = [int]$observedReconnects
        }
        InstalledHerdr = $installedHerdr
        Producer = [pscustomobject][ordered]@{ Tool = 'Invoke-V07ActualHerdrSoak.ps1'; Version = '1'; SessionControlInvoked = $false; ObserverMode = 'ReadOnlyAttached' }
        Provenance = [pscustomobject][ordered]@{
            HeartbeatIntervalSeconds = $HeartbeatSeconds; ExpectedHeartbeatCount = $heartbeatEntries.Count; MissingHeartbeatCount = $missingHeartbeats
            HeartbeatEntries = @($heartbeatEntries); HeartbeatChainHeadSha256 = if ($heartbeatEntries.Count -gt 0) { [string]$heartbeatEntries[-1].EntrySha256 } else { '0' * 64 }
            FirstHeartbeatUtc = if ($heartbeatEntries.Count -gt 0) { [string]$heartbeatEntries[0].ObservedUtc } else { '' }
            LastHeartbeatUtc = if ($heartbeatEntries.Count -gt 0) { [string]$heartbeatEntries[-1].ObservedUtc } else { '' }
            ObservationCount = $faultEntries.Count; FaultObservations = @($faultEntries)
            FaultObservationChainHeadSha256 = if ($faultEntries.Count -gt 0) { [string]$faultEntries[-1].EntrySha256 } else { '0' * 64 }
        }
        Resources = [pscustomobject][ordered]@{ MaxSamples = $script:V07SoakMaxResourceSamples; Samples = @($resourceSamples); PeakWorkingSetBytes = $peakWorkingSet; PeakCpuPercent = $peakCpu }
        Limits = [pscustomobject][ordered]@{
            MaxArtifactBytes = $script:V07SoakMaxArtifactBytes; MaxHeartbeatEntries = $script:V07SoakMaxHeartbeatEntries
            MaxFaultObservations = $script:V07SoakMaxFaultObservations; MaxResourceSamples = $script:V07SoakMaxResourceSamples
            MaxManifestEntries = $script:V07SoakMaxManifestEntries
        }
        Artifacts = $artifactManifests
    }
    $artifact | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $artifactPath -Encoding UTF8

    $validation = Test-V07SoakArtifact -SoakArtifact $artifact -MeasurementArtifact $measurementArtifact -RepositoryRoot $resolvedRoot -EvidenceRoot $outRoot -ValidateExternalBindings
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('HerdrOps v0.7.0 Actual-Herdr Soak Producer (Issue #39)')
    $lines.Add("RunId: $runId")
    $lines.Add("SourceCommit: $($binding.SourceCommit)")
    $lines.Add("SourceTree: $($binding.SourceTree)")
    $lines.Add("InstalledHerdrSha256: $($installedHerdr.ExecutableSha256)")
    $lines.Add("InstalledHerdrReleaseId: $($installedHerdr.ReleaseId)")
    $lines.Add("DurationHours: $([Math]::Round(($finished - $started).TotalHours, 6))")
    $lines.Add("ArtifactValidation: $(if ($validation.Valid) { 'PASS' } else { 'FAIL' })")
    if (-not $validation.Valid) { foreach ($failure in $validation.Failures) { $lines.Add("  - $failure") } }
    $lines.Add('SessionControlInvoked: false')
    $lines.Add('HumanUatDecision: NOT OBSERVED / PENDING')
    $lines.Add('ReleaseEvidence: NOT OBSERVED / NOT CLAIMED')
    $lines.Add("SoakArtifact: $artifactPath")
    $lines | Set-Content -LiteralPath $gateReportPath -Encoding UTF8
    $lines | ForEach-Object { Write-Host $_ }
    if (-not $validation.Valid -or $cancelled -or $timedOut) { exit 2 }
}
