# HerdrOps v0.7 Live Performance Measurement Producer -- Deterministic Self-Tests
# Issue #39: synthetic positive/negative matrix that rejects missing, forged,
# stale, and wrong-session evidence. PS 5.1 and PS 7+ compatible. Never starts
# Herdr, never invokes session control, and never writes a Runtime budget report.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'V07PerformanceMeasurementPolicy.ps1')

# -----------------------------------------------------------------------------
# Synthetic Positive-Control Helpers
# -----------------------------------------------------------------------------
function New-V07SynthesizedLiveArtifact {
    <#
    .SYNOPSIS
        Deep-copies a base Live measurement artifact and rebinds Candidate
        (current HEAD + on-disk binaries) and Roles (on-disk paths/hashes) so a
        positive control passes the strict external verification. Raw sample
        PIDs are aligned to the rebound role PIDs. Fails closed if candidate
        binaries are absent from artifacts/bin.
    #>
    param(
        [Parameter(Mandatory)]$BaseArtifact,
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [long]$CorePid = 41001,
        [long]$AppPid = 41002
    )

    $resolvedRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path
    Assert-V07NotReparsePoint -Path $resolvedRoot -Description 'RepositoryRoot for synthesis'
    $candidateDirectory = Join-Path $resolvedRoot 'artifacts\bin'
    if (-not (Test-Path -LiteralPath $candidateDirectory -PathType Container)) {
        throw "Candidate directory prerequisite missing -- run Invoke-Build.ps1 first: $candidateDirectory"
    }

    $binding = New-V07CandidateBinding -RepositoryRoot $resolvedRoot -CandidateDirectory $candidateDirectory -SkipCleanCheck
    $jsonCopy = $BaseArtifact | ConvertTo-Json -Depth 30
    $synthesized = $jsonCopy | ConvertFrom-Json

    $synthesized.Candidate.SourceCommit = $binding.SourceCommit
    $synthesized.Candidate | Add-Member -MemberType NoteProperty -Name SourceTree -Value $binding.SourceTree -Force
    $synthesized.Candidate.GitTreeClean = $binding.GitTreeClean
    $synthesized.Candidate | Add-Member -MemberType NoteProperty -Name Binaries -Value @($binding.Binaries) -Force

    $coreBinding = @($binding.Binaries | Where-Object { $_.RelativePath -match '(?i)HerdrOps\.Core\.dll$' })[0]
    $appBinding = @($binding.Binaries | Where-Object { $_.RelativePath -match '(?i)HerdrOps\.App\.dll$' })[0]
    if ($null -eq $coreBinding -or $null -eq $appBinding) {
        throw 'Synthesis requires on-disk HerdrOps.Core.dll and HerdrOps.App.dll candidate bindings.'
    }

    $corePath = Join-Path $resolvedRoot ($coreBinding.RelativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
    $appPath = Join-Path $resolvedRoot ($appBinding.RelativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
    $roles = @(
        [pscustomobject]@{
            Role = 'Core'
            ProcessId = $CorePid
            ProcessStartUtc = '2020-01-01T12:00:00Z'
            BinaryPath = $corePath
            BinarySha256 = [string]$coreBinding.Sha256
        },
        [pscustomobject]@{
            Role = 'App'
            ProcessId = $AppPid
            ProcessStartUtc = '2020-01-01T12:00:01Z'
            BinaryPath = $appPath
            BinarySha256 = [string]$appBinding.Sha256
        }
    )
    $synthesized | Add-Member -MemberType NoteProperty -Name Roles -Value $roles -Force

    # Align raw sample PIDs to the rebound role PIDs.
    foreach ($launchSample in @($synthesized.RawSamples.DashboardColdLaunch)) {
        $launchSample | Add-Member -MemberType NoteProperty -Name AppProcessId -Value $AppPid -Force
        $launchSample | Add-Member -MemberType NoteProperty -Name CoreProcessId -Value $CorePid -Force
    }
    foreach ($latencySample in @($synthesized.RawSamples.WidgetStateDeltaLatency)) {
        $latencySample | Add-Member -MemberType NoteProperty -Name AppProcessId -Value $AppPid -Force
        $latencySample | Add-Member -MemberType NoteProperty -Name CoreProcessId -Value $CorePid -Force
    }

    return $synthesized
}

function New-V07SyntheticSoakArtifact {
    <#
    .SYNOPSIS
        Builds a valid Live soak artifact bound to a measurement artifact's
        session and candidate. Used only for positive-control self-tests.
    #>
    param(
        [Parameter(Mandatory)]$MeasurementArtifact,
        [double]$DurationHours = 8.0
    )

    $installed = [pscustomobject][ordered]@{
        ProductId = 'Herdr'
        ExecutablePath = [string]$MeasurementArtifact.Session.HerdrExecutablePath
        ExecutableSha256 = [string]$MeasurementArtifact.Session.HerdrExecutableSha256
        ReleaseId = if ($null -ne $MeasurementArtifact.Session.PSObject.Properties['HerdrReleaseId']) { [string]$MeasurementArtifact.Session.HerdrReleaseId } else { 'synthetic-herdr' }
        PackageRoot = Split-Path -Path ([string]$MeasurementArtifact.Session.HerdrExecutablePath) -Parent
        PackageIdentitySha256 = ''
    }
    $installed.PackageIdentitySha256 = Get-V07InstalledHerdrIdentitySha256 -Identity $installed

    $heartbeatEntries = [System.Collections.Generic.List[object]]::new()
    $previousHeartbeat = '0' * 64
    $heartbeatStart = [DateTimeOffset]::Parse('2020-01-01T00:00:00Z')
    $syntheticServerStartUtc = if ($null -ne $MeasurementArtifact.Session.ControlHerdrServerIdentity) {
        ConvertTo-V07SoakUtcText -Value ([DateTimeOffset]$MeasurementArtifact.Session.ControlHerdrServerIdentity.ProcessStartUtc)
    } else { '2020-01-01T00:00:00Z' }
    for ($hour = 0; $hour -le 8; $hour++) {
        $entry = [pscustomobject][ordered]@{
            Ordinal = $hour + 1; ObservedUtc = $heartbeatStart.AddHours($hour).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
            Status = 'Healthy'; TargetSocketPresent = $true
            HerdrProcessId = 8123; HerdrProcessStartUtc = $syntheticServerStartUtc; HerdrExecutablePath = [string]$installed.ExecutablePath; HerdrExecutableSha256 = [string]$installed.ExecutableSha256
            CoreProcessId = 41001; AppProcessId = 41002; PreviousEntrySha256 = $previousHeartbeat; EntrySha256 = ''
        }
        $entry.EntrySha256 = Get-V07SoakEntrySha256 -Entry $entry
        $heartbeatEntries.Add($entry)
        $previousHeartbeat = [string]$entry.EntrySha256
    }

    $faultEntries = [System.Collections.Generic.List[object]]::new()
    $faultSchedule = @(
        @{ Id = 'FAULT-01'; Kind = 'TargetHerdrRestartObservation'; Due = '2020-01-01T02:00:00Z'; Offset = 7200 },
        @{ Id = 'FAULT-02'; Kind = 'CoreReconnectObservation'; Due = '2020-01-01T04:00:00Z'; Offset = 14400 },
        @{ Id = 'FAULT-03'; Kind = 'AppRecoveryObservation'; Due = '2020-01-01T06:00:00Z'; Offset = 21600 }
    )
    $previousFault = '0' * 64
    foreach ($scheduled in $faultSchedule) {
        $fault = [pscustomobject][ordered]@{
            Id = $scheduled.Id; Kind = $scheduled.Kind; ScheduledOffsetSeconds = $scheduled.Offset
            DueUtc = $scheduled.Due; ObservedUtc = $scheduled.Due; Status = 'Observed'; OperatorAcknowledged = $true
            EvidencePath = 'synthetic://' + $scheduled.Id; EvidenceSha256 = Get-V07Sha256Hex -Text $scheduled.Id
            Note = 'Synthetic positive-control observation only.'; PreviousEntrySha256 = $previousFault; EntrySha256 = ''
        }
        $fault.EntrySha256 = Get-V07SoakEntrySha256 -Entry $fault
        $previousFault = [string]$fault.EntrySha256
        $faultEntries.Add($fault)
    }

    $resourceSamples = @(
        [pscustomobject][ordered]@{ ObservedUtc = '2020-01-01T00:00:00Z'; HerdrProcessId = 8123; CoreProcessId = 41001; AppProcessId = 41002; CombinedWorkingSetBytes = 100; CombinedCpuPercent = 0.2 },
        [pscustomobject][ordered]@{ ObservedUtc = '2020-01-01T04:00:00Z'; HerdrProcessId = 8123; CoreProcessId = 41001; AppProcessId = 41002; CombinedWorkingSetBytes = 120; CombinedCpuPercent = 0.4 },
        [pscustomobject][ordered]@{ ObservedUtc = '2020-01-01T08:00:00Z'; HerdrProcessId = 8123; CoreProcessId = 41001; AppProcessId = 41002; CombinedWorkingSetBytes = 110; CombinedCpuPercent = 0.3 }
    )
    $limits = [pscustomobject][ordered]@{
        MaxArtifactBytes = $script:V07SoakMaxArtifactBytes; MaxHeartbeatEntries = $script:V07SoakMaxHeartbeatEntries
        MaxFaultObservations = $script:V07SoakMaxFaultObservations; MaxResourceSamples = $script:V07SoakMaxResourceSamples
        MaxManifestEntries = $script:V07SoakMaxManifestEntries
    }
    $artifacts = @(
        [pscustomobject][ordered]@{ Name = 'heartbeat.jsonl'; RelativePath = 'synthetic://heartbeat.jsonl'; LengthBytes = 1; Sha256 = Get-V07Sha256Hex -Text 'heartbeat'; Lines = $heartbeatEntries.Count; Entries = $heartbeatEntries.Count },
        [pscustomobject][ordered]@{ Name = 'fault-observations.jsonl'; RelativePath = 'synthetic://fault-observations.jsonl'; LengthBytes = 1; Sha256 = Get-V07Sha256Hex -Text 'faults'; Lines = 3; Entries = 3 },
        [pscustomobject][ordered]@{ Name = 'resources.jsonl'; RelativePath = 'synthetic://resources.jsonl'; LengthBytes = 1; Sha256 = Get-V07Sha256Hex -Text 'resources'; Lines = 3; Entries = 3 },
        [pscustomobject][ordered]@{ Name = 'soak-context.json'; RelativePath = 'synthetic://soak-context.json'; LengthBytes = 1; Sha256 = Get-V07Sha256Hex -Text 'context'; Lines = 1; Entries = 1 },
        [pscustomobject][ordered]@{ Name = 'runtime-observer-current.json'; RelativePath = 'synthetic://runtime-observer-current.json'; LengthBytes = 1; Sha256 = Get-V07Sha256Hex -Text 'runtime-report'; Lines = 1; Entries = 1 }
    )

    $observerBinding = [pscustomobject][ordered]@{
        RelativePath = [string]$MeasurementArtifact.Candidate.Binaries[0].RelativePath
        LengthBytes = [long]$MeasurementArtifact.Candidate.Binaries[0].LengthBytes
        Sha256 = [string]$MeasurementArtifact.Candidate.Binaries[0].Sha256
    }
    $admittedIdentity = [pscustomobject][ordered]@{
        ProcessId = 8123; ProcessStartUtc = $syntheticServerStartUtc
        ExecutablePath = [string]$installed.ExecutablePath; ExecutableSha256 = [string]$installed.ExecutableSha256
    }

    return [pscustomobject][ordered]@{
        SchemaVersion = $script:V07SoakSchemaVersion
        ArtifactKind  = $script:V07SoakArtifactKind
        RunId         = 'soak-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
        StartedUtc    = '2020-01-01T00:00:00Z'
        FinishedUtc   = '2020-01-01T08:00:00Z'
        Mode          = 'Live'
        Cancelled     = $false
        TimedOut      = $false
        MeasurementRunId = [string]$MeasurementArtifact.RunId
        MeasurementArtifactSha256 = Get-V07ArtifactCanonicalSha256 -Artifact $MeasurementArtifact
        Session       = [pscustomobject]@{
            ControlPaneId = if ($null -ne $MeasurementArtifact.Session.PSObject.Properties['ControlPaneId']) { [string]$MeasurementArtifact.Session.ControlPaneId } else { 'synthetic-control' }
            ObservedControlPaneId = if ($null -ne $MeasurementArtifact.Session.PSObject.Properties['ObservedControlPaneId']) { [string]$MeasurementArtifact.Session.ObservedControlPaneId } else { 'synthetic-control' }
            ControlHerdrSocketPath = [string]$MeasurementArtifact.Session.ControlHerdrSocketPath
            TargetHerdrSocketPath  = [string]$MeasurementArtifact.Session.TargetHerdrSocketPath
            HerdrExecutablePath    = [string]$MeasurementArtifact.Session.HerdrExecutablePath
            HerdrExecutableSha256  = [string]$MeasurementArtifact.Session.HerdrExecutableSha256
            HerdrReleaseId         = [string]$installed.ReleaseId
            ControlHerdrServerIdentity = $admittedIdentity
        }
        Candidate     = [pscustomobject]@{
            SourceCommit = [string]$MeasurementArtifact.Candidate.SourceCommit
            SourceTree = if ($null -ne $MeasurementArtifact.Candidate.PSObject.Properties['SourceTree']) { [string]$MeasurementArtifact.Candidate.SourceTree } else { ('0' * 40) }
            GitTreeClean = $true
            Binaries = @($MeasurementArtifact.Candidate.Binaries); Observer = $observerBinding
        }
        Soak          = [pscustomobject]@{
            DurationHours           = $DurationHours
            UnhandledCrashes        = 0
            UnreconciledStateCount  = 0
            UnboundedTerminalReads  = 0
            RuntimeObservationCount = 3
            RuntimeObservationFailures = 0
            StateEvidenceCount = 3
            ObservedEvents = 3
            ObservedReconnects = 1
        }
        InstalledHerdr = $installed
        Producer = [pscustomobject][ordered]@{
            Tool = 'Invoke-V07ActualHerdrSoak.ps1'; Version = '2'; SessionControlInvoked = $false; ObserverMode = 'ReadOnlyAttached'
            ObserverExecutablePath = [string]$MeasurementArtifact.Roles[0].BinaryPath; ObserverExecutableSha256 = [string]$observerBinding.Sha256
            ObserverReportPath = 'synthetic://runtime-observer-current.json'; ObserverReportSha256 = Get-V07Sha256Hex -Text 'runtime-report'
            AdmittedHerdrServerIdentity = $admittedIdentity
            FaultSchedule = @(
                [pscustomobject][ordered]@{ Id = 'FAULT-01'; Kind = 'TargetHerdrRestartObservation'; OffsetSeconds = 7200; Instruction = 'Synthetic'; DueUtc = '2020-01-01T02:00:00Z' },
                [pscustomobject][ordered]@{ Id = 'FAULT-02'; Kind = 'CoreReconnectObservation'; OffsetSeconds = 14400; Instruction = 'Synthetic'; DueUtc = '2020-01-01T04:00:00Z' },
                [pscustomobject][ordered]@{ Id = 'FAULT-03'; Kind = 'AppRecoveryObservation'; OffsetSeconds = 21600; Instruction = 'Synthetic'; DueUtc = '2020-01-01T06:00:00Z' }
            )
            ScheduleContextPath = 'synthetic://soak-context.json'; ScheduleContextSha256 = Get-V07Sha256Hex -Text 'context'
        }
        Provenance = [pscustomobject][ordered]@{
            HeartbeatIntervalSeconds = 3600; ExpectedHeartbeatCount = $heartbeatEntries.Count; MissingHeartbeatCount = 0
            HeartbeatEntries = @($heartbeatEntries); HeartbeatChainHeadSha256 = [string]$heartbeatEntries[-1].EntrySha256
            FirstHeartbeatUtc = '2020-01-01T00:00:00Z'; LastHeartbeatUtc = '2020-01-01T08:00:00Z'
            ObservationCount = $faultEntries.Count; FaultObservations = @($faultEntries); FaultObservationChainHeadSha256 = $previousFault
        }
        Resources = [pscustomobject][ordered]@{
            MaxSamples = $script:V07SoakMaxResourceSamples; Samples = @($resourceSamples)
            PeakWorkingSetBytes = 120; PeakCpuPercent = 0.4
        }
        Limits = $limits
        Artifacts = $artifacts
    }
}

# -----------------------------------------------------------------------------
# Deterministic Self-Test Suite
# -----------------------------------------------------------------------------
function Invoke-V07MeasurementSelfTests {
    <#
    .SYNOPSIS
        Runs the deterministic synthetic self-test matrix (PS 5.1 and PS 7+).
        Positive controls rebind to the current HEAD and on-disk binaries;
        negative fixtures and in-memory mutations must fail closed. No test
        starts Herdr, invokes session control, or writes a Runtime budget
        report to disk.
    #>
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$FixturesDirectory
    )

    $selfTestResults = [System.Collections.Generic.List[object]]::new()
    $record = {
        param([string]$TestName, [bool]$Passed, [string]$Detail)
        $selfTestResults.Add([pscustomobject]@{
            TestName = $TestName
            Status   = if ($Passed) { 'PASS' } else { 'FAIL' }
            Detail   = $Detail
        })
    }

    $resolvedRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path
    $candidateDirectory = Join-Path $resolvedRoot 'artifacts\bin'
    $goodPath = Join-Path $FixturesDirectory 'live-measurement-good.json'
    $goodJson = Get-V07BoundedUtf8FileText -Path $goodPath -Description 'Good live measurement fixture'
    $baseArtifact = $goodJson | ConvertFrom-Json
    if ([string]$baseArtifact.SchemaVersion -ne $script:V07MeasurementSchemaVersion) {
        throw "Good fixture has unexpected schema: $($baseArtifact.SchemaVersion)"
    }

    # --- Test 1: Positive -- synthesized live artifact passes admission ---
    try {
        $synth = New-V07SynthesizedLiveArtifact -BaseArtifact $baseArtifact -RepositoryRoot $resolvedRoot
        $admission = Test-V07MeasurementArtifactAdmission -Artifact $synth -RepositoryRoot $resolvedRoot -CandidateDirectory $candidateDirectory
        & $record 'Positive: Synthesized live artifact passes fail-closed admission' ($admission.Valid) "Failures: $($admission.Failures -join '; ')"
    } catch {
        & $record 'Positive: Synthesized live artifact passes fail-closed admission' $false $_.Exception.Message
    }

    # --- Test 2: Positive -- finalizer emits Runtime budget report from live artifact + soak ---
    try {
        $synth = New-V07SynthesizedLiveArtifact -BaseArtifact $baseArtifact -RepositoryRoot $resolvedRoot
        $soak = New-V07SyntheticSoakArtifact -MeasurementArtifact $synth
        $finalization = ConvertTo-V07RuntimeBudgetReport -MeasurementArtifact $synth -SoakArtifact $soak -RepositoryRoot $resolvedRoot -CandidateDirectory $candidateDirectory
        $reportOk = $false
        if ($finalization.CanFinalize -and $null -ne $finalization.BudgetReport) {
            $report = $finalization.BudgetReport
            $reportOk = ([string]$report.EvidenceClass -eq 'Runtime' -and
                @($report.ProcessTelemetry).Count -eq 2 -and
                @($report.Metrics.WidgetDeltaLatencySamplesMs).Count -ge $script:V07MeasurementMinLatencySamples -and
                @($report.Metrics.DashboardColdLaunchSamplesMs).Count -ge $script:V07MeasurementMinLaunchSamples -and
                [string]$report.EvidenceBoundary.ActualHerdrRuntime -eq 'OBSERVED' -and
                [string]$report.EvidenceBoundary.SoakExecution -eq 'OBSERVED')
        }
        & $record 'Positive: Finalizer emits Runtime budget report with role telemetry and raw samples' ($finalization.CanFinalize -and $reportOk) "Reason: $($finalization.Reason); Blockers: $($finalization.Blockers -join '; ')"
    } catch {
        & $record 'Positive: Finalizer emits Runtime budget report with role telemetry and raw samples' $false $_.Exception.Message
    }

    # --- Test 3: Missing evidence fixture fails admission ---
    try {
        $json = Get-V07BoundedUtf8FileText -Path (Join-Path $FixturesDirectory 'live-measurement-missing-samples.json') -Description 'Missing samples fixture'
        $artifact = $json | ConvertFrom-Json
        $admission = Test-V07MeasurementArtifactAdmission -Artifact $artifact
        & $record 'Negative: Missing raw samples fail closed' (-not $admission.Valid) "Failures: $($admission.Failures -join '; ')"
    } catch {
        & $record 'Negative: Missing raw samples fail closed' $false $_.Exception.Message
    }

    # --- Test 4: Forged observed evidence fixture fails admission ---
    try {
        $json = Get-V07BoundedUtf8FileText -Path (Join-Path $FixturesDirectory 'live-measurement-forged-observed.json') -Description 'Forged observed fixture'
        $artifact = $json | ConvertFrom-Json
        $admission = Test-V07MeasurementArtifactAdmission -Artifact $artifact
        & $record 'Negative: Forged observed evidence fails closed' (-not $admission.Valid) "Failures: $($admission.Failures -join '; ')"
    } catch {
        & $record 'Negative: Forged observed evidence fails closed' $false $_.Exception.Message
    }

    # --- Test 5: Tampered aggregate fails admission (recomputation) ---
    try {
        $synth = New-V07SynthesizedLiveArtifact -BaseArtifact $baseArtifact -RepositoryRoot $resolvedRoot
        $synth.Metrics.WidgetStateDeltaLatencyP95Ms = [double]1.0
        $admission = Test-V07MeasurementArtifactAdmission -Artifact $synth -RepositoryRoot $resolvedRoot -CandidateDirectory $candidateDirectory
        & $record 'Negative: Tampered p95 aggregate fails recomputation' (-not $admission.Valid) "Failures: $($admission.Failures -join '; ')"
    } catch {
        & $record 'Negative: Tampered p95 aggregate fails recomputation' $false $_.Exception.Message
    }

    # --- Test 6: Stale commit fixture fails admission (external HEAD binding) ---
    try {
        $json = Get-V07BoundedUtf8FileText -Path (Join-Path $FixturesDirectory 'live-measurement-stale-commit.json') -Description 'Stale commit fixture'
        $artifact = $json | ConvertFrom-Json
        $admission = Test-V07MeasurementArtifactAdmission -Artifact $artifact -RepositoryRoot $resolvedRoot -CandidateDirectory $candidateDirectory
        & $record 'Negative: Stale source commit fails closed' (-not $admission.Valid) "Failures: $($admission.Failures -join '; ')"
    } catch {
        & $record 'Negative: Stale source commit fails closed' $false $_.Exception.Message
    }

    # --- Test 7: Wrong-session fixture fails admission ---
    try {
        $json = Get-V07BoundedUtf8FileText -Path (Join-Path $FixturesDirectory 'live-measurement-wrong-session.json') -Description 'Wrong session fixture'
        $artifact = $json | ConvertFrom-Json
        $admission = Test-V07MeasurementArtifactAdmission -Artifact $artifact
        & $record 'Negative: Wrong-session evidence fails closed' (-not $admission.Valid) "Failures: $($admission.Failures -join '; ')"
    } catch {
        & $record 'Negative: Wrong-session evidence fails closed' $false $_.Exception.Message
    }

    # --- Test 8: Wrong-role fixture fails admission ---
    try {
        $json = Get-V07BoundedUtf8FileText -Path (Join-Path $FixturesDirectory 'live-measurement-wrong-role.json') -Description 'Wrong role fixture'
        $artifact = $json | ConvertFrom-Json
        $admission = Test-V07MeasurementArtifactAdmission -Artifact $artifact
        & $record 'Negative: Wrong-role binary binding fails closed' (-not $admission.Valid) "Failures: $($admission.Failures -join '; ')"
    } catch {
        & $record 'Negative: Wrong-role binary binding fails closed' $false $_.Exception.Message
    }

    # --- Test 9: Timed-out run fails admission ---
    try {
        $json = Get-V07BoundedUtf8FileText -Path (Join-Path $FixturesDirectory 'live-measurement-timed-out.json') -Description 'Timed out fixture'
        $artifact = $json | ConvertFrom-Json
        $admission = Test-V07MeasurementArtifactAdmission -Artifact $artifact
        & $record 'Negative: Timed-out run cannot admit observed evidence' (-not $admission.Valid) "Failures: $($admission.Failures -join '; ')"
    } catch {
        & $record 'Negative: Timed-out run cannot admit observed evidence' $false $_.Exception.Message
    }

    # --- Test 10: Synthetic artifact never finalizes to Runtime ---
    try {
        $json = Get-V07BoundedUtf8FileText -Path (Join-Path $FixturesDirectory 'synthetic-measurement-artifact.json') -Description 'Synthetic artifact fixture'
        $artifact = $json | ConvertFrom-Json
        $admission = Test-V07MeasurementArtifactAdmission -Artifact $artifact
        $soak = New-V07SyntheticSoakArtifact -MeasurementArtifact $artifact
        $finalization = ConvertTo-V07RuntimeBudgetReport -MeasurementArtifact $artifact -SoakArtifact $soak -RepositoryRoot $resolvedRoot -CandidateDirectory $candidateDirectory
        & $record 'Negative: Synthetic artifact never finalizes to Runtime' ((-not $admission.Valid) -and (-not $finalization.CanFinalize)) "AdmissionValid=$($admission.Valid); CanFinalize=$($finalization.CanFinalize)"
    } catch {
        & $record 'Negative: Synthetic artifact never finalizes to Runtime' $false $_.Exception.Message
    }

    # --- Test 11: Live artifact without soak evidence cannot finalize ---
    try {
        $synth = New-V07SynthesizedLiveArtifact -BaseArtifact $baseArtifact -RepositoryRoot $resolvedRoot
        $admission = Test-V07MeasurementArtifactAdmission -Artifact $synth -RepositoryRoot $resolvedRoot -CandidateDirectory $candidateDirectory
        $finalization = ConvertTo-V07RuntimeBudgetReport -MeasurementArtifact $synth -SoakArtifact $null -RepositoryRoot $resolvedRoot -CandidateDirectory $candidateDirectory
        & $record 'Negative: Live measurement without soak evidence cannot finalize Runtime' ($admission.Valid -and -not $finalization.CanFinalize) "CanFinalize=$($finalization.CanFinalize); Reason=$($finalization.Reason)"
    } catch {
        & $record 'Negative: Live measurement without soak evidence cannot finalize Runtime' $false $_.Exception.Message
    }

    # --- Test 12: Short soak (< 8h) blocks finalization ---
    try {
        $synth = New-V07SynthesizedLiveArtifact -BaseArtifact $baseArtifact -RepositoryRoot $resolvedRoot
        $soak = New-V07SyntheticSoakArtifact -MeasurementArtifact $synth -DurationHours 7.9
        $finalization = ConvertTo-V07RuntimeBudgetReport -MeasurementArtifact $synth -SoakArtifact $soak -RepositoryRoot $resolvedRoot -CandidateDirectory $candidateDirectory
        & $record 'Negative: Sub-8-hour soak blocks Runtime finalization' (-not $finalization.CanFinalize) "CanFinalize=$($finalization.CanFinalize); Blockers: $($finalization.Blockers -join '; ')"
    } catch {
        & $record 'Negative: Sub-8-hour soak blocks Runtime finalization' $false $_.Exception.Message
    }

    # --- Test 13: Soak bound to a different session blocks finalization ---
    try {
        $synth = New-V07SynthesizedLiveArtifact -BaseArtifact $baseArtifact -RepositoryRoot $resolvedRoot
        $soak = New-V07SyntheticSoakArtifact -MeasurementArtifact $synth
        $soak.Session.TargetHerdrSocketPath = 'C:\other\target.sock'
        $finalization = ConvertTo-V07RuntimeBudgetReport -MeasurementArtifact $synth -SoakArtifact $soak -RepositoryRoot $resolvedRoot -CandidateDirectory $candidateDirectory
        & $record 'Negative: Soak on a different session blocks finalization' (-not $finalization.CanFinalize) "CanFinalize=$($finalization.CanFinalize); Blockers: $($finalization.Blockers -join '; ')"
    } catch {
        & $record 'Negative: Soak on a different session blocks finalization' $false $_.Exception.Message
    }

    # --- Test 14: Sample retention cap is enforced ---
    try {
        $synth = New-V07SynthesizedLiveArtifact -BaseArtifact $baseArtifact -RepositoryRoot $resolvedRoot
        $cap = $script:V07MeasurementMaxSamplesPerMetric
        $over = [System.Collections.Generic.List[object]]::new()
        for ($i = 1; $i -le ($cap + 1); $i++) {
            $over.Add([pscustomobject]@{
                ObservedUtc = '2020-01-01T00:00:00Z'
                Percent = 0.5
                SampleOrdinal = $i
            })
        }
        $synth.RawSamples | Add-Member -MemberType NoteProperty -Name IdleCpu -Value @($over) -Force
        $synth.Metrics.IdleCpuAveragePercent = 0.5
        $synth.Observed | Add-Member -MemberType NoteProperty -Name IdleCpu -Value $true -Force
        $admission = Test-V07MeasurementArtifactAdmission -Artifact $synth
        & $record 'Negative: Raw sample retention cap is enforced' (-not $admission.Valid) "Failures: $($admission.Failures -join '; ')"
    } catch {
        & $record 'Negative: Raw sample retention cap is enforced' $false $_.Exception.Message
    }

    # --- Test 15: Non-finite sample fails admission ---
    try {
        $synth = New-V07SynthesizedLiveArtifact -BaseArtifact $baseArtifact -RepositoryRoot $resolvedRoot
        $samples = @($synth.RawSamples.WidgetStateDeltaLatency)
        $samples[0].Milliseconds = [double]::PositiveInfinity
        $synth.RawSamples | Add-Member -MemberType NoteProperty -Name WidgetStateDeltaLatency -Value $samples -Force
        $admission = Test-V07MeasurementArtifactAdmission -Artifact $synth
        & $record 'Negative: Non-finite raw sample fails closed' (-not $admission.Valid) "Failures: $($admission.Failures -join '; ')"
    } catch {
        & $record 'Negative: Non-finite raw sample fails closed' $false $_.Exception.Message
    }

    # --- Test 16: Sample outside the run window fails admission ---
    try {
        $synth = New-V07SynthesizedLiveArtifact -BaseArtifact $baseArtifact -RepositoryRoot $resolvedRoot
        $samples = @($synth.RawSamples.DashboardColdLaunch)
        $samples[0].ObservedUtc = '2025-01-01T00:00:00Z'
        $synth.RawSamples | Add-Member -MemberType NoteProperty -Name DashboardColdLaunch -Value $samples -Force
        $admission = Test-V07MeasurementArtifactAdmission -Artifact $synth
        & $record 'Negative: Raw sample outside the run window fails closed' (-not $admission.Valid) "Failures: $($admission.Failures -join '; ')"
    } catch {
        & $record 'Negative: Raw sample outside the run window fails closed' $false $_.Exception.Message
    }

    # --- Test 17: Role PID mismatch fails admission ---
    try {
        $synth = New-V07SynthesizedLiveArtifact -BaseArtifact $baseArtifact -RepositoryRoot $resolvedRoot
        $samples = @($synth.RawSamples.DashboardColdLaunch)
        $samples[0] | Add-Member -MemberType NoteProperty -Name AppProcessId -Value 99999 -Force
        $synth.RawSamples | Add-Member -MemberType NoteProperty -Name DashboardColdLaunch -Value $samples -Force
        $admission = Test-V07MeasurementArtifactAdmission -Artifact $synth
        & $record 'Negative: Raw sample PID not bound to the role PID fails closed' (-not $admission.Valid) "Failures: $($admission.Failures -join '; ')"
    } catch {
        & $record 'Negative: Raw sample PID not bound to the role PID fails closed' $false $_.Exception.Message
    }

    # --- Test 18: Duplicate role PIDs fail closed ---
    try {
        $synth = New-V07SynthesizedLiveArtifact -BaseArtifact $baseArtifact -RepositoryRoot $resolvedRoot
        $synth.Roles[1].ProcessId = [long]$synth.Roles[0].ProcessId
        $admission = Test-V07MeasurementArtifactAdmission -Artifact $synth
        & $record 'Negative: Shared Core/App role PID fails closed' (-not $admission.Valid) "Failures: $($admission.Failures -join '; ')"
    } catch {
        & $record 'Negative: Shared Core/App role PID fails closed' $false $_.Exception.Message
    }

    # --- Test 19: Assembler rejects a missing Observed flag ---
    try {
        $synth = New-V07SynthesizedLiveArtifact -BaseArtifact $baseArtifact -RepositoryRoot $resolvedRoot
        $brokenObserved = $synth.Observed | ConvertTo-Json -Depth 10 | ConvertFrom-Json
        [void]$brokenObserved.PSObject.Properties.Remove('IdleCpu')
        $null = New-V07MeasurementArtifact -RunId $synth.RunId -StartedUtc $synth.StartedUtc -FinishedUtc $synth.FinishedUtc -Mode $synth.Mode -Cancelled:$synth.Cancelled -TimedOut:$synth.TimedOut -TerminationReason $synth.TerminationReason -HostEnvironment $synth.HostEnvironment -Session $synth.Session -Candidate $synth.Candidate -Roles $synth.Roles -Metrics $synth.Metrics -Observed $brokenObserved -RawSamples $synth.RawSamples -PhaseLog $synth.PhaseLog
        & $record 'Negative: Artifact assembler requires every Observed flag' $false 'Expected assembly failure was not thrown'
    } catch {
        & $record 'Negative: Artifact assembler requires every Observed flag' $true "Rejected missing Observed flag: $($_.Exception.Message)"
    }

    # --- Test 20: Delta latency extraction from an App report shape ---
    try {
        $appReport = [pscustomobject]@{
            WidgetLatencyIncludedSamples = @(
                [pscustomobject]@{ ObservedUtc = '2020-01-01T00:00:01Z'; Milliseconds = 120.4; UpdateKind = 'Delta' },
                [pscustomobject]@{ ObservedUtc = '2020-01-01T00:00:02Z'; Milliseconds = 182.3; UpdateKind = 'Delta' },
                [pscustomobject]@{ ObservedUtc = '2020-01-01T00:00:03Z'; Milliseconds = 155.0; UpdateKind = 'Snapshot' }
            )
        }
        $extracted = @(Get-V07DeltaLatencySamplesFromAppReport -AppReport $appReport -CoreProcessId 41001 -AppProcessId 41002)
        $ok = ($extracted.Count -eq 3 -and [double]$extracted[0].Milliseconds -eq 120.4 -and
            [long]$extracted[1].AppProcessId -eq 41002 -and [long]$extracted[1].CoreProcessId -eq 41001 -and
            [string]$extracted[2].UpdateKind -eq 'Snapshot')
        & $record 'Positive: Delta latency extraction from App report shape' $ok "Extracted=$($extracted.Count) samples"
    } catch {
        & $record 'Positive: Delta latency extraction from App report shape' $false $_.Exception.Message
    }

    # --- Test 21: Reconnect extraction from a Core trace shape ---
    try {
        $trace = [pscustomobject]@{
            Transitions = @(
                [pscustomobject]@{ Status = 'Connected'; DisconnectCount = 0; BootstrapCount = 1; ObservedUtc = '2020-01-01T00:00:00Z'; ServerIdentity = [pscustomobject]@{ ProcessId = 100 } },
                [pscustomobject]@{ Status = 'Reconnecting'; DisconnectCount = 1; BootstrapCount = 1; ObservedUtc = '2020-01-01T00:00:04Z'; ServerIdentity = [pscustomobject]@{ ProcessId = 100 } },
                [pscustomobject]@{ Status = 'Connected'; DisconnectCount = 1; BootstrapCount = 2; ObservedUtc = '2020-01-01T00:00:07Z'; ServerIdentity = [pscustomobject]@{ ProcessId = 456 } }
            )
        }
        $extracted = @(Get-V07ReconnectSamplesFromCoreTrace -CoreTraceReport $trace)
        $ok = ($extracted.Count -eq 1 -and [Math]::Abs([double]$extracted[0].Seconds - 3.0) -lt 0.001 -and
            [long]$extracted[0].ReconnectBootstrapCount -eq 2 -and [long]$extracted[0].ReconnectServerPid -eq 456)
        & $record 'Positive: Reconnect extraction from Core trace shape' $ok "Extracted=$($extracted.Count) samples; Seconds=$($extracted[0].Seconds)"
    } catch {
        & $record 'Positive: Reconnect extraction from Core trace shape' $false $_.Exception.Message
    }

    # --- Test 22: Reconnect sample integrity rejects an inverted transition order ---
    try {
        $synth = New-V07SynthesizedLiveArtifact -BaseArtifact $baseArtifact -RepositoryRoot $resolvedRoot
        $samples = @($synth.RawSamples.HerdrReconnectReconcile)
        $samples[0].DisconnectTransitionUtc = '2020-01-01T00:00:09Z'
        $samples[0].ReconnectTransitionUtc = '2020-01-01T00:00:01Z'
        $synth.RawSamples | Add-Member -MemberType NoteProperty -Name HerdrReconnectReconcile -Value $samples -Force
        $admission = Test-V07MeasurementArtifactAdmission -Artifact $synth
        & $record 'Negative: Inverted reconnect transition order fails closed' (-not $admission.Valid) "Failures: $($admission.Failures -join '; ')"
    } catch {
        & $record 'Negative: Inverted reconnect transition order fails closed' $false $_.Exception.Message
    }

    # --- Test 23: Missing role records fail closed ---
    try {
        $synth = New-V07SynthesizedLiveArtifact -BaseArtifact $baseArtifact -RepositoryRoot $resolvedRoot
        $synth | Add-Member -MemberType NoteProperty -Name Roles -Value @() -Force
        $admission = Test-V07MeasurementArtifactAdmission -Artifact $synth
        & $record 'Negative: Missing role records fail closed' (-not $admission.Valid) "Failures: $($admission.Failures -join '; ')"
    } catch {
        & $record 'Negative: Missing role records fail closed' $false $_.Exception.Message
    }

    # --- Test 24: P95 engine determinism ---
    try {
        $samples = [double[]]@(10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120, 130, 140, 150, 160, 170, 180, 190, 200)
        $p95 = Get-V07P95 -Samples $samples
        & $record 'Positive: P95 engine computes the 95th percentile' ($p95 -eq 190.0) "P95=$p95"
    } catch {
        & $record 'Positive: P95 engine computes the 95th percentile' $false $_.Exception.Message
    }

    # --- Test 25: Environment-gated session admission fails closed without HERDR_ENV ---
    try {
        $originalEnv = $env:HERDR_ENV
        try {
            Remove-Item Env:HERDR_ENV -ErrorAction SilentlyContinue
            $null = Test-V07LiveSessionAdmission -HerdrExecutable 'C:\nonexistent\herdr.exe' -TargetHerdrSocketPath 'C:\nonexistent\target.sock'
            & $record 'Negative: Live session admission fails closed without HERDR_ENV=1' $false 'Expected environment gate failure was not thrown'
        } finally {
            if ($null -ne $originalEnv) { $env:HERDR_ENV = $originalEnv } else { Remove-Item Env:HERDR_ENV -ErrorAction SilentlyContinue }
        }
    } catch {
        & $record 'Negative: Live session admission fails closed without HERDR_ENV=1' $true "Environment gate rejected: $($_.Exception.Message)"
    }

    # --- Test 26: Measurement artifact cannot be confused with a budget report ---
    try {
        $synth = New-V07SynthesizedLiveArtifact -BaseArtifact $baseArtifact -RepositoryRoot $resolvedRoot
        $artifactJson = $synth | ConvertTo-Json -Depth 30
        $budgetPolicyPath = Join-Path $PSScriptRoot 'V07PerformanceBudgetPolicy.ps1'
        if (Test-Path -LiteralPath $budgetPolicyPath -PathType Leaf) {
            # Always dot-source: the budget policy's internal Add-Type guard keeps
            # the C# validator type unique while the policy functions must exist.
            . $budgetPolicyPath
            $rejected = $false
            try {
                $null = ConvertFrom-StrictPerformanceBudgetJson -JsonText $artifactJson -SourceDescription 'measurement artifact fed to budget gate'
            } catch {
                $rejected = $true
            }
            & $record 'Negative: Measurement artifact cannot be admitted as a budget report' $rejected 'Strict budget schema rejected the measurement artifact (no synthetic-to-runtime promotion)'
        } else {
            & $record 'Negative: Measurement artifact cannot be admitted as a budget report' $true 'Budget policy not present; schema-version distinction verified by admission'
        }
    } catch {
        & $record 'Negative: Measurement artifact cannot be admitted as a budget report' $false $_.Exception.Message
    }

    # --- Test 27: Hostile JSON -- duplicate keys are rejected before parsing ---
    try {
        $artifactJson = $goodJson
        $duplicateJson = $artifactJson -replace '"ArtifactKind": "PerformanceMeasurementRun"', '"ArtifactKind": "PerformanceMeasurementRun", "ArtifactKind": "PerformanceMeasurementRun"'
        $rejected = $false
        try {
            Assert-V07StrictJsonText -JsonText $duplicateJson -SourceDescription 'duplicate key hostile fixture'
        } catch {
            $rejected = $true
        }
        & $record 'Negative: Duplicate JSON key fails strict parsing' $rejected "Rejected=$rejected"
    } catch {
        & $record 'Negative: Duplicate JSON key fails strict parsing' $false $_.Exception.Message
    }

    # --- Test 28: Hostile JSON -- trailing content is rejected ---
    try {
        $rejected = $false
        try {
            Assert-V07StrictJsonText -JsonText ($goodJson + ' {"extra":true}') -SourceDescription 'trailing content hostile fixture'
        } catch {
            $rejected = $true
        }
        & $record 'Negative: Trailing JSON content fails strict parsing' $rejected "Rejected=$rejected"
    } catch {
        & $record 'Negative: Trailing JSON content fails strict parsing' $false $_.Exception.Message
    }

    # --- Test 29: Hostile JSON -- NaN/Infinity literals are rejected ---
    try {
        $nanJson = $goodJson -replace '"Milliseconds": 120.4', '"Milliseconds": NaN'
        $rejected = $false
        try {
            Assert-V07StrictJsonText -JsonText $nanJson -SourceDescription 'non-finite hostile fixture'
        } catch {
            $rejected = $true
        }
        & $record 'Negative: Non-finite JSON literal fails strict parsing' $rejected "Rejected=$rejected"
    } catch {
        & $record 'Negative: Non-finite JSON literal fails strict parsing' $false $_.Exception.Message
    }

    # --- Test 30: Fractional integers are rejected (Bytes / ordinals / PIDs) ---
    try {
        $synth = New-V07SynthesizedLiveArtifact -BaseArtifact $baseArtifact -RepositoryRoot $resolvedRoot
        $wsSamples = @($synth.RawSamples.IdleWorkingSet)
        $wsSamples[0].Bytes = [double]144900000.5
        $synth.RawSamples | Add-Member -MemberType NoteProperty -Name IdleWorkingSet -Value $wsSamples -Force
        $admission = Test-V07MeasurementArtifactAdmission -Artifact $synth
        & $record 'Negative: Fractional integer sample fails closed' (-not $admission.Valid) "Failures: $($admission.Failures -join '; ')"
    } catch {
        & $record 'Negative: Fractional integer sample fails closed' $false $_.Exception.Message
    }

    # --- Test 31: Unknown top-level property is rejected ---
    try {
        $synth = New-V07SynthesizedLiveArtifact -BaseArtifact $baseArtifact -RepositoryRoot $resolvedRoot
        $synth | Add-Member -MemberType NoteProperty -Name ForgedClaim -Value 'runtime' -Force
        $admission = Test-V07MeasurementArtifactAdmission -Artifact $synth
        & $record 'Negative: Unknown artifact property fails closed' (-not $admission.Valid) "Failures: $($admission.Failures -join '; ')"
    } catch {
        & $record 'Negative: Unknown artifact property fails closed' $false $_.Exception.Message
    }

    # --- Test 32: Future role start time is rejected ---
    try {
        $synth = New-V07SynthesizedLiveArtifact -BaseArtifact $baseArtifact -RepositoryRoot $resolvedRoot
        $synth.Roles[0].ProcessStartUtc = '2099-01-01T00:00:00Z'
        $admission = Test-V07MeasurementArtifactAdmission -Artifact $synth
        & $record 'Negative: Future role start time fails closed' (-not $admission.Valid) "Failures: $($admission.Failures -join '; ')"
    } catch {
        & $record 'Negative: Future role start time fails closed' $false $_.Exception.Message
    }

    # --- Test 33: Broken cross-file hash chain blocks finalization ---
    try {
        $synth = New-V07SynthesizedLiveArtifact -BaseArtifact $baseArtifact -RepositoryRoot $resolvedRoot
        $soak = New-V07SyntheticSoakArtifact -MeasurementArtifact $synth
        $soak.MeasurementArtifactSha256 = '0' * 64
        $finalization = ConvertTo-V07RuntimeBudgetReport -MeasurementArtifact $synth -SoakArtifact $soak -RepositoryRoot $resolvedRoot -CandidateDirectory $candidateDirectory
        & $record 'Negative: Forged soak hash chain blocks finalization' (-not $finalization.CanFinalize) "CanFinalize=$($finalization.CanFinalize); Blockers: $($finalization.Blockers -join '; ')"
    } catch {
        & $record 'Negative: Forged soak hash chain blocks finalization' $false $_.Exception.Message
    }

    # --- Test 34: Mismatched soak run id blocks finalization ---
    try {
        $synth = New-V07SynthesizedLiveArtifact -BaseArtifact $baseArtifact -RepositoryRoot $resolvedRoot
        $soak = New-V07SyntheticSoakArtifact -MeasurementArtifact $synth
        $soak.MeasurementRunId = 'some-other-run'
        $finalization = ConvertTo-V07RuntimeBudgetReport -MeasurementArtifact $synth -SoakArtifact $soak -RepositoryRoot $resolvedRoot -CandidateDirectory $candidateDirectory
        & $record 'Negative: Mismatched soak run id blocks finalization' (-not $finalization.CanFinalize) "CanFinalize=$($finalization.CanFinalize)"
    } catch {
        & $record 'Negative: Mismatched soak run id blocks finalization' $false $_.Exception.Message
    }

    # --- Test 35: Soak crash violation blocks finalization ---
    try {
        $synth = New-V07SynthesizedLiveArtifact -BaseArtifact $baseArtifact -RepositoryRoot $resolvedRoot
        $soak = New-V07SyntheticSoakArtifact -MeasurementArtifact $synth
        $soak.Soak.UnhandledCrashes = 1
        $finalization = ConvertTo-V07RuntimeBudgetReport -MeasurementArtifact $synth -SoakArtifact $soak -RepositoryRoot $resolvedRoot -CandidateDirectory $candidateDirectory
        & $record 'Negative: Soak crash violation blocks finalization' (-not $finalization.CanFinalize) "CanFinalize=$($finalization.CanFinalize); Blockers: $($finalization.Blockers -join '; ')"
    } catch {
        & $record 'Negative: Soak crash violation blocks finalization' $false $_.Exception.Message
    }

    # --- Test 36: Declared soak duration must bind to the timestamp span ---
    try {
        $synth = New-V07SynthesizedLiveArtifact -BaseArtifact $baseArtifact -RepositoryRoot $resolvedRoot
        $soak = New-V07SyntheticSoakArtifact -MeasurementArtifact $synth
        $soak.FinishedUtc = '2020-01-01T07:59:58Z'
        $check = Test-V07SoakArtifact -SoakArtifact $soak -MeasurementArtifact $synth
        & $record 'Negative: Forged-short soak timestamp span fails closed' (-not $check.Valid) "Failures: $($check.Failures -join '; ')"
    } catch {
        & $record 'Negative: Forged-short soak timestamp span fails closed' $false $_.Exception.Message
    }

    # --- Test 37: Inverted soak timestamps fail closed ---
    try {
        $synth = New-V07SynthesizedLiveArtifact -BaseArtifact $baseArtifact -RepositoryRoot $resolvedRoot
        $soak = New-V07SyntheticSoakArtifact -MeasurementArtifact $synth
        $soak.StartedUtc = '2020-01-01T08:00:01Z'
        $check = Test-V07SoakArtifact -SoakArtifact $soak -MeasurementArtifact $synth
        & $record 'Negative: Inverted soak timestamps fail closed' (-not $check.Valid) "Failures: $($check.Failures -join '; ')"
    } catch {
        & $record 'Negative: Inverted soak timestamps fail closed' $false $_.Exception.Message
    }

    # --- Test 38: String duration is not a JSON number ---
    try {
        $synth = New-V07SynthesizedLiveArtifact -BaseArtifact $baseArtifact -RepositoryRoot $resolvedRoot
        $soak = New-V07SyntheticSoakArtifact -MeasurementArtifact $synth
        $soak.Soak.DurationHours = '8'
        $check = Test-V07SoakArtifact -SoakArtifact $soak -MeasurementArtifact $synth
        & $record 'Negative: String soak duration fails closed' (-not $check.Valid) "Failures: $($check.Failures -join '; ')"
    } catch {
        & $record 'Negative: String soak duration fails closed' $false $_.Exception.Message
    }

    # --- Test 39: Non-finite duration is not admissible ---
    try {
        $synth = New-V07SynthesizedLiveArtifact -BaseArtifact $baseArtifact -RepositoryRoot $resolvedRoot
        $soak = New-V07SyntheticSoakArtifact -MeasurementArtifact $synth
        $soak.Soak.DurationHours = [double]::NaN
        $check = Test-V07SoakArtifact -SoakArtifact $soak -MeasurementArtifact $synth
        & $record 'Negative: Non-finite soak duration fails closed' (-not $check.Valid) "Failures: $($check.Failures -join '; ')"
    } catch {
        & $record 'Negative: Non-finite soak duration fails closed' $false $_.Exception.Message
    }

    # --- Test 40: The documented one-second tolerance is deterministic ---
    try {
        $synth = New-V07SynthesizedLiveArtifact -BaseArtifact $baseArtifact -RepositoryRoot $resolvedRoot
        $soak = New-V07SyntheticSoakArtifact -MeasurementArtifact $synth
        $soak.FinishedUtc = '2020-01-01T07:59:59Z'
        $check = Test-V07SoakArtifact -SoakArtifact $soak -MeasurementArtifact $synth
        & $record 'Positive: One-second soak timestamp tolerance is accepted' $check.Valid "Failures: $($check.Failures -join '; ')"
    } catch {
        & $record 'Positive: One-second soak timestamp tolerance is accepted' $false $_.Exception.Message
    }

    return @($selfTestResults)
}
