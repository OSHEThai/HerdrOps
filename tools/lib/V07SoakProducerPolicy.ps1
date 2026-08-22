# HerdrOps v0.7 Issue #39 actual-Herdr soak producer policy.
# PS 5.1 / PS 7 compatible. This policy observes only; it never controls a
# Herdr session or starts/stops/restarts a product process.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:V07SoakMaxDurationHours = 8.0
$script:V07SoakObserverGraceSeconds = 15

$measurementPolicy = Join-Path $PSScriptRoot 'V07PerformanceMeasurementPolicy.ps1'
if (-not (Test-Path -LiteralPath $measurementPolicy -PathType Leaf)) {
    throw "Required v0.7 measurement policy is missing: $measurementPolicy"
}
. $measurementPolicy

function ConvertTo-V07SoakUtcText {
    param([Parameter(Mandatory)][DateTimeOffset]$Value)
    return $Value.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
}

function Get-V07SoakDefaultSchedule {
    param([Parameter(Mandatory)][double]$DurationHours)

    $durationSeconds = [int][Math]::Floor($DurationHours * 3600.0)
    return @(
        [pscustomobject][ordered]@{
            Id = 'FAULT-01'; Kind = 'TargetHerdrRestartObservation'; OffsetSeconds = [int][Math]::Min(7200, $durationSeconds - 1800)
            Instruction = 'Operator restarts only the target Agent Lab Herdr session; never restart the Acceptance control session.'
        },
        [pscustomobject][ordered]@{
            Id = 'FAULT-02'; Kind = 'CoreReconnectObservation'; OffsetSeconds = [int][Math]::Min(14400, $durationSeconds - 1200)
            Instruction = 'Operator observes Core disconnect/reconnect and records the retained runtime trace evidence.'
        },
        [pscustomobject][ordered]@{
            Id = 'FAULT-03'; Kind = 'AppRecoveryObservation'; OffsetSeconds = [int][Math]::Min(21600, $durationSeconds - 600)
            Instruction = 'Operator observes App recovery after the scheduled fault and records the exact evidence file.'
        }
    ) | Where-Object { [int]$_.OffsetSeconds -gt 0 -and [int]$_.OffsetSeconds -lt $durationSeconds }
}

function Test-V07SoakSchedule {
    param(
        [Parameter(Mandatory)][object[]]$Schedule,
        [Parameter(Mandatory)][double]$DurationHours
    )

    $failures = [System.Collections.Generic.List[string]]::new()
    $durationSeconds = [int][Math]::Floor($DurationHours * 3600.0)
    $ids = @{}
    if ($DurationHours -ne $script:V07SoakMaxDurationHours) {
        $failures.Add("Actual-Herdr soak duration must be exactly $($script:V07SoakMaxDurationHours) hours.")
    }
    if ($Schedule.Count -lt 3 -or $Schedule.Count -gt $script:V07SoakMaxFaultObservations) {
        $failures.Add("Fault schedule must contain 3 through $($script:V07SoakMaxFaultObservations) entries.")
    }
    foreach ($entry in $Schedule) {
        $id = [string]$entry.Id
        if ([string]::IsNullOrWhiteSpace($id) -or $ids.ContainsKey($id)) { $failures.Add('Fault schedule ids must be non-empty and unique.') } else { $ids[$id] = $true }
        $offset = 0
        try { $offset = [int]$entry.OffsetSeconds } catch { $offset = 0 }
        if ($offset -le 0 -or $offset -ge $durationSeconds) { $failures.Add("Fault schedule '$id' is outside the soak duration.") }
        if ([string]::IsNullOrWhiteSpace([string]$entry.Kind) -or [string]::IsNullOrWhiteSpace([string]$entry.Instruction)) {
            $failures.Add("Fault schedule '$id' requires Kind and an operator Instruction.")
        }
    }
    return [pscustomobject]@{ Valid = ($failures.Count -eq 0); Failures = @($failures) }
}

function Get-V07InstalledHerdrIdentity {
    param([Parameter(Mandatory)][string]$HerdrExecutable)

    $resolved = (Resolve-Path -LiteralPath $HerdrExecutable).Path
    Assert-V07NotReparsePoint -Path $resolved -Description 'Installed Herdr executable'
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) { throw "Installed Herdr executable is not a file: $resolved" }
    $sha = Get-V07Sha256Hex -Path $resolved
    $versionOutput = @(& $resolved --version 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0 -or $versionOutput.Count -eq 0) { throw "Installed Herdr --version failed for '$resolved'." }
    $releaseId = (($versionOutput -join ' ').Trim())
    if ($releaseId.Length -gt 512) { throw 'Installed Herdr release identity exceeds the bounded 512-character limit.' }
    $identity = [pscustomobject][ordered]@{
        ProductId = 'Herdr'
        ExecutablePath = $resolved
        ExecutableSha256 = $sha
        ReleaseId = $releaseId
        PackageRoot = (Split-Path -Path $resolved -Parent)
        PackageIdentitySha256 = ''
    }
    $identity.PackageIdentitySha256 = Get-V07InstalledHerdrIdentitySha256 -Identity $identity
    return $identity
}

function Get-V07SoakProcessSnapshot {
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        [Parameter(Mandatory)][string]$Role,
        [hashtable]$Previous = @{}
    )

    try {
        $process = Get-Process -Id $ProcessId -ErrorAction Stop
        $startUtc = $process.StartTime.ToUniversalTime()
        $executablePath = ''
        $executableSha256 = ''
        try {
            $executablePath = [string]$process.Path
            if (-not [string]::IsNullOrWhiteSpace($executablePath) -and (Test-Path -LiteralPath $executablePath -PathType Leaf)) {
                $executablePath = (Resolve-Path -LiteralPath $executablePath).Path
                $executableSha256 = Get-V07Sha256Hex -Path $executablePath
            }
        } catch {
            $executablePath = ''
            $executableSha256 = ''
        }
        $workingSet = [long]$process.WorkingSet64
        $totalCpuSeconds = [double]$process.TotalProcessorTime.TotalSeconds
        $cpuPercent = 0.0
        if ($Previous.ContainsKey($Role)) {
            $prior = $Previous[$Role]
            $wallSeconds = ([DateTimeOffset]::UtcNow - [DateTimeOffset]$prior.ObservedUtc).TotalSeconds
            if ($wallSeconds -gt 0) {
                $cpuPercent = (($totalCpuSeconds - [double]$prior.TotalCpuSeconds) / $wallSeconds / [Environment]::ProcessorCount) * 100.0
            }
        }
        $snapshot = [pscustomobject][ordered]@{
            ProcessId = $ProcessId
            Role = $Role
            ProcessStartUtc = ConvertTo-V07SoakUtcText -Value $startUtc
            ExecutablePath = $executablePath
            ExecutableSha256 = $executableSha256
            WorkingSetBytes = $workingSet
            TotalCpuSeconds = $totalCpuSeconds
            CpuPercent = [Math]::Max(0.0, $cpuPercent)
            ObservedUtc = ConvertTo-V07SoakUtcText -Value ([DateTimeOffset]::UtcNow)
            Present = $true
        }
        $Previous[$Role] = $snapshot
        return $snapshot
    } catch {
        return [pscustomobject][ordered]@{
            ProcessId = $ProcessId; Role = $Role; ProcessStartUtc = ''; ExecutablePath = ''; ExecutableSha256 = ''; WorkingSetBytes = 0
            TotalCpuSeconds = 0.0; CpuPercent = 0.0; ObservedUtc = ConvertTo-V07SoakUtcText -Value ([DateTimeOffset]::UtcNow)
            Present = $false; Error = $_.Exception.Message
        }
    }
}

function Test-V07SoakProcessIdentityMatch {
    param(
        [Parameter(Mandatory)]$Snapshot,
        [Parameter(Mandatory)]$Identity
    )

    if (-not [bool]$Snapshot.Present -or $null -eq $Identity) { return $false }
    try {
        $expectedStart = ConvertTo-V07SoakUtcText -Value ([DateTimeOffset]$Identity.ProcessStartUtc)
        return ([int]$Snapshot.ProcessId -eq [int]$Identity.ProcessId) -and
            ([string]$Snapshot.ProcessStartUtc -ceq $expectedStart) -and
            ([string]$Snapshot.ExecutablePath -ieq [string]$Identity.ExecutablePath) -and
            ([string]$Snapshot.ExecutableSha256 -ceq [string]$Identity.ExecutableSha256)
    } catch {
        return $false
    }
}

function New-V07SoakHeartbeatEntry {
    param(
        [Parameter(Mandatory)][int]$Ordinal,
        [Parameter(Mandatory)][string]$TargetHerdrSocketPath,
        [Parameter(Mandatory)]$InstalledHerdr,
        [Parameter(Mandatory)][int]$HerdrProcessId,
        [Parameter(Mandatory)][int]$CoreProcessId,
        [Parameter(Mandatory)][int]$AppProcessId,
        [Parameter(Mandatory)]$AdmittedHerdrServerIdentity,
        [Parameter(Mandatory)][hashtable]$AdmittedRoleIdentities,
        [Parameter(Mandatory)][hashtable]$PreviousSnapshots,
        [Parameter(Mandatory)][string]$PreviousEntrySha256
    )

    $herdr = Get-V07SoakProcessSnapshot -ProcessId $HerdrProcessId -Role 'Herdr' -Previous $PreviousSnapshots
    $core = Get-V07SoakProcessSnapshot -ProcessId $CoreProcessId -Role 'Core' -Previous $PreviousSnapshots
    $app = Get-V07SoakProcessSnapshot -ProcessId $AppProcessId -Role 'App' -Previous $PreviousSnapshots
    $targetPresent = Test-Path -LiteralPath $TargetHerdrSocketPath -PathType Leaf
    $identityMatch = Test-V07SoakProcessIdentityMatch -Snapshot $herdr -Identity $AdmittedHerdrServerIdentity
    $coreIdentityMatch = Test-V07SoakProcessIdentityMatch -Snapshot $core -Identity $AdmittedRoleIdentities['Core']
    $appIdentityMatch = Test-V07SoakProcessIdentityMatch -Snapshot $app -Identity $AdmittedRoleIdentities['App']
    $healthy = $targetPresent -and $herdr.Present -and $core.Present -and $app.Present -and
        $identityMatch -and $coreIdentityMatch -and $appIdentityMatch
    $entry = [pscustomobject][ordered]@{
        Ordinal = $Ordinal
        ObservedUtc = ConvertTo-V07SoakUtcText -Value ([DateTimeOffset]::UtcNow)
        Status = if ($healthy) { 'Healthy' } else { 'Fault' }
        TargetSocketPresent = [bool]$targetPresent
        HerdrProcessId = [int]$herdr.ProcessId
        HerdrProcessStartUtc = [string]$herdr.ProcessStartUtc
        HerdrExecutablePath = [string]$herdr.ExecutablePath
        HerdrExecutableSha256 = [string]$herdr.ExecutableSha256
        CoreProcessId = [int]$core.ProcessId
        CoreProcessStartUtc = [string]$core.ProcessStartUtc
        CoreExecutablePath = [string]$core.ExecutablePath
        CoreExecutableSha256 = [string]$core.ExecutableSha256
        AppProcessId = [int]$app.ProcessId
        AppProcessStartUtc = [string]$app.ProcessStartUtc
        AppExecutablePath = [string]$app.ExecutablePath
        AppExecutableSha256 = [string]$app.ExecutableSha256
        PreviousEntrySha256 = $PreviousEntrySha256
        EntrySha256 = ''
    }
    $entry.EntrySha256 = Get-V07SoakEntrySha256 -Entry $entry
    return [pscustomobject][ordered]@{ Entry = $entry; Herdr = $herdr; Core = $core; App = $app; Healthy = $healthy }
}

function New-V07SoakResourceSample {
    param(
        [Parameter(Mandatory)]$HerdrSnapshot,
        [Parameter(Mandatory)]$CoreSnapshot,
        [Parameter(Mandatory)]$AppSnapshot
    )
    $cpu = [double]$CoreSnapshot.CpuPercent + [double]$AppSnapshot.CpuPercent
    $workingSet = [long]$CoreSnapshot.WorkingSetBytes + [long]$AppSnapshot.WorkingSetBytes
    return [pscustomobject][ordered]@{
        ObservedUtc = ConvertTo-V07SoakUtcText -Value ([DateTimeOffset]::UtcNow)
        HerdrProcessId = [int]$HerdrSnapshot.ProcessId
        CoreProcessId = [int]$CoreSnapshot.ProcessId
        AppProcessId = [int]$AppSnapshot.ProcessId
        CombinedWorkingSetBytes = $workingSet
        CombinedCpuPercent = [Math]::Round([Math]::Max(0.0, $cpu), 4)
    }
}

function Add-V07SoakJsonLine {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][int]$MaxEntries,
        [Parameter(Mandatory)][long]$MaxBytes
    )

    if ([int]$State.EntryCount -ge $MaxEntries) { throw "Bounded log entry limit reached for '$Path'." }
    $line = ($Entry | ConvertTo-Json -Depth 20 -Compress) + "`n"
    $encoding = New-Object System.Text.UTF8Encoding($false)
    $bytes = $encoding.GetBytes($line)
    if ([long]$State.ByteCount + $bytes.Length -gt $MaxBytes) { throw "Bounded log byte limit reached for '$Path'." }
    [IO.File]::AppendAllText($Path, $line, $encoding)
    $State.EntryCount = [int]$State.EntryCount + 1
    $State.ByteCount = [long]$State.ByteCount + $bytes.Length
}

function Get-V07SoakLogManifest {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][int]$Entries
    )
    $full = Assert-V07PathWithinRoot -Path (Join-Path $Root $RelativePath) -AllowedRoots @($Root) -Description "Soak log $RelativePath"
    Assert-V07NotReparsePoint -Path $full -Description "Soak log $RelativePath"
    $info = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    $lines = @(Get-Content -LiteralPath $full -Encoding UTF8).Count
    return [pscustomobject][ordered]@{
        Name = [IO.Path]::GetFileName($RelativePath)
        RelativePath = $RelativePath.Replace('\', '/')
        LengthBytes = [long]$info.Length
        Sha256 = Get-V07Sha256Hex -Path $full
        Lines = [int]$lines
        Entries = [int]$Entries
    }
}

function Read-V07SoakOperatorObservation {
    param(
        [Parameter(Mandatory)][string]$ObservationPath,
        [Parameter(Mandatory)][string]$ExpectedId,
        [Parameter(Mandatory)][string]$EvidenceRoot,
        [Parameter(Mandatory)]$ExpectedSchedule,
        [Parameter(Mandatory)][DateTimeOffset]$SoakStartedUtc
    )

    if (-not (Test-Path -LiteralPath $ObservationPath -PathType Leaf)) { return $null }
    $json = Get-V07BoundedUtf8FileText -Path $ObservationPath -MaxBytes 65536 -Description 'operator observation'
    Assert-V07StrictJsonText -JsonText $json -SourceDescription 'operator observation'
    $marker = $json | ConvertFrom-Json
    foreach ($property in @('SchemaVersion', 'ScheduleId', 'Kind', 'ScheduledOffsetSeconds', 'DueUtc', 'ObservedUtc', 'OperatorAcknowledged', 'EvidencePath', 'EvidenceSha256', 'Note', 'ScheduleContextSha256')) {
        if ($null -eq $marker.PSObject.Properties[$property]) { throw "Operator observation '$ExpectedId' is missing required property '$property'." }
    }
    if (@($marker.PSObject.Properties | Where-Object { $_.Name -notin @('SchemaVersion', 'ScheduleId', 'Kind', 'ScheduledOffsetSeconds', 'DueUtc', 'ObservedUtc', 'OperatorAcknowledged', 'EvidencePath', 'EvidenceSha256', 'Note', 'ScheduleContextSha256') }).Count -gt 0) {
        throw "Operator observation '$ExpectedId' contains an unknown property."
    }
    if ([string]$marker.SchemaVersion -cne 'v0.7.0-soak-operator-observation' -or
        [string]$marker.ScheduleId -cne $ExpectedId -or
        [string]$marker.Kind -cne [string]$ExpectedSchedule.Kind -or
        [int]$marker.ScheduledOffsetSeconds -ne [int]$ExpectedSchedule.OffsetSeconds -or
        -not [bool]$marker.OperatorAcknowledged) {
        throw "Operator observation '$ExpectedId' has an invalid schedule binding or acknowledgement."
    }
    $expectedDue = ConvertTo-V07SoakUtcText -Value $SoakStartedUtc.AddSeconds([int]$ExpectedSchedule.OffsetSeconds)
    if ([string]$marker.DueUtc -cne $expectedDue) { throw "Operator observation '$ExpectedId' DueUtc does not match the immutable soak schedule context." }
    if (-not (Test-V07UtcTimestampText -Text ([string]$marker.ObservedUtc))) { throw "Operator observation '$ExpectedId' has an invalid timestamp." }
    $observedUtc = [DateTimeOffset]$marker.ObservedUtc
    $dueUtc = [DateTimeOffset]$marker.DueUtc
    if ($observedUtc -lt $dueUtc) { throw "Operator observation '$ExpectedId' is early: ObservedUtc must be at or after DueUtc." }
    if ($observedUtc -gt [DateTimeOffset]::UtcNow) { throw "Operator observation '$ExpectedId' is in the future: ObservedUtc cannot exceed finalization time." }
    $contextPath = Join-Path $EvidenceRoot 'soak-context.json'
    if (-not (Test-Path -LiteralPath $contextPath -PathType Leaf)) { throw "Operator observation '$ExpectedId' is missing the immutable soak context." }
    $contextSha = Get-V07Sha256Hex -Path $contextPath
    if ((ConvertTo-V07NormalizedSha256 -Value ([string]$marker.ScheduleContextSha256)) -cne $contextSha) { throw "Operator observation '$ExpectedId' is not bound to the retained soak context bytes." }
    $evidence = [string]$marker.EvidencePath
    if ([string]::IsNullOrWhiteSpace($evidence)) { throw "Operator observation '$ExpectedId' is missing EvidencePath." }
    $resolvedEvidence = Assert-V07PathWithinRoot -Path $evidence -AllowedRoots @($EvidenceRoot) -Description "operator evidence '$ExpectedId'"
    Assert-V07NotReparsePoint -Path $resolvedEvidence -Description "operator evidence '$ExpectedId'"
    $evidenceSha = Get-V07Sha256Hex -Path $resolvedEvidence
    $declaredSha = ConvertTo-V07NormalizedSha256 -Value ([string]$marker.EvidenceSha256)
    if ($evidenceSha -ne $declaredSha) { throw "Operator observation '$ExpectedId' evidence SHA-256 does not match its bytes." }
    return [pscustomobject][ordered]@{
        Id = $ExpectedId
        Kind = [string]$marker.Kind
        ScheduledOffsetSeconds = [int]$marker.ScheduledOffsetSeconds
        DueUtc = [string]$marker.DueUtc
        ObservedUtc = [string]$marker.ObservedUtc
        Status = 'Observed'
        OperatorAcknowledged = $true
        EvidencePath = $evidence
        EvidenceSha256 = $declaredSha
        Note = [string]$marker.Note
        ScheduleContextSha256 = $contextSha
    }
}
