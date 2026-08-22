#requires -Version 5.1

Set-StrictMode -Version Latest

if (-not (Get-Command Assert-True -ErrorAction SilentlyContinue)) {
    function Assert-True {
        param(
            [Parameter(Mandatory)][bool]$Condition,
            [Parameter(Mandatory)][string]$Message
        )
        if (-not $Condition) { throw $Message }
    }
}

if (-not (Get-Command Test-ObjectHasProperty -ErrorAction SilentlyContinue)) {
    function Test-ObjectHasProperty {
        param(
            [Parameter(Mandatory)][AllowNull()]$Object,
            [Parameter(Mandatory)][string]$Name
        )
        if ($null -eq $Object) { return $false }
        return $null -ne $Object.PSObject.Properties[$Name]
    }
}

$script:V02ValidAgentStatuses = @('Unknown', 'Idle', 'Working', 'Blocked', 'Done')
$script:V02ValidMonitorStatuses = @('Starting', 'Connected', 'Reconnecting', 'Stopped')

$v02NativeType = 'HerdrOpsV02FileIdentityNative' -as [type]
if ($null -eq $v02NativeType) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class HerdrOpsV02FileIdentityNative
{
    [StructLayout(LayoutKind.Sequential)]
    public struct BY_HANDLE_FILE_INFORMATION
    {
        public uint dwFileAttributes;
        public System.Runtime.InteropServices.ComTypes.FILETIME ftCreationTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME ftLastAccessTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME ftLastWriteTime;
        public uint dwVolumeSerialNumber;
        public uint nFileSizeHigh;
        public uint nFileSizeLow;
        public uint nNumberOfLinks;
        public uint nFileIndexHigh;
        public uint nFileIndexLow;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GetFileInformationByHandle(
        SafeFileHandle hFile,
        out BY_HANDLE_FILE_INFORMATION lpFileInformation);
}
'@
}

function ConvertTo-V02ComparablePath {
    param(
        [Parameter(Mandatory)][string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'A Herdr session socket path is required.'
    }

    try {
        $fullPath = [IO.Path]::GetFullPath($Path)
        while ($fullPath.Length -gt 3 -and
               ($fullPath.EndsWith('\') -or $fullPath.EndsWith('/'))) {
            $fullPath = $fullPath.Substring(0, $fullPath.Length - 1)
        }
        return $fullPath.ToUpperInvariant()
    }
    catch {
        throw "Could not normalize Herdr session socket path '$Path'."
    }
}

function Assert-V02AcceptanceSessionTopology {
    param(
        [Parameter(Mandatory)][string]$SessionListJson,
        [Parameter(Mandatory)][string]$ControlSocketPath,
        [Parameter(Mandatory)][string]$TargetSocketPath
    )

    if ([string]::IsNullOrWhiteSpace($SessionListJson)) {
        throw 'Herdr session list output is empty.'
    }

    try {
        $document = $SessionListJson | ConvertFrom-Json
    }
    catch {
        throw 'Herdr session list returned invalid JSON.'
    }

    $sessions = @($document.sessions)
    if ($sessions.Count -eq 0) {
        throw 'Herdr session list did not contain any named sessions.'
    }

    $controlPath = ConvertTo-V02ComparablePath -Path $ControlSocketPath
    $targetPath = ConvertTo-V02ComparablePath -Path $TargetSocketPath
    if ($controlPath -eq $targetPath) {
        throw 'Acceptance control and target Agent Lab sockets must be different.'
    }

    $controlMatches = @($sessions | Where-Object {
        $socketPath = [string]$_.socket_path
        -not [string]::IsNullOrWhiteSpace($socketPath) -and
            (ConvertTo-V02ComparablePath -Path $socketPath) -eq $controlPath
    })
    if ($controlMatches.Count -ne 1) {
        throw 'The active control socket did not resolve to exactly one named Herdr session.'
    }

    $controlSession = $controlMatches[0]
    if ([string]$controlSession.name -cne 'acceptance') {
        throw "The runtime gate must run in the isolated 'acceptance' session, not '$($controlSession.name)'."
    }
    if ([bool]$controlSession.running -ne $true) {
        throw "The isolated 'acceptance' session is not running. Start it before the human-controlled runtime phase."
    }

    $targetMatches = @($sessions | Where-Object {
        $socketPath = [string]$_.socket_path
        -not [string]::IsNullOrWhiteSpace($socketPath) -and
            (ConvertTo-V02ComparablePath -Path $socketPath) -eq $targetPath
    })
    if ($targetMatches.Count -ne 1) {
        throw 'The target Agent Lab socket did not resolve to exactly one named Herdr session.'
    }

    $targetSession = $targetMatches[0]
    if ([string]$targetSession.name -ceq 'acceptance') {
        throw 'The target Agent Lab socket must not be the isolated acceptance session socket.'
    }
    if ([bool]$targetSession.running -ne $true) {
        throw "The target Agent Lab session '$($targetSession.name)' is not running. Do not start or stop it from the gate."
    }

    return [pscustomobject]@{
        ControlSessionName = [string]$controlSession.name
        TargetSessionName  = [string]$targetSession.name
    }
}

function Assert-AllAgentsHaveLiveIdentity {
    param(
        [Parameter(Mandatory)]$Transition,
        [Parameter(Mandatory)][string]$Name
    )

    Assert-True (Test-ObjectHasProperty -Object $Transition -Name 'AllAgentsHaveLiveIdentity') "$Name Core transition omitted the aggregate Agent-identity contract flag."
    Assert-True ([bool]$Transition.AllAgentsHaveLiveIdentity) "$Name Core transition admitted an incomplete or mismatched pane/Agent mapping, Agentless pane, blank identity, or Unknown Agent in the state."
}

function Open-V02HeldFileStream {
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "HeldFileStreamTargetNotFound: $Path"
    }
    $resolvedPath = (Resolve-Path -LiteralPath $Path).Path
    return [System.IO.File]::Open($resolvedPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
}

function Get-V02FileInformation {
    param(
        [Parameter(Mandatory = $true)][System.IO.FileStream]$FileStream
    )

    $info = New-Object HerdrOpsV02FileIdentityNative+BY_HANDLE_FILE_INFORMATION
    $ok = [HerdrOpsV02FileIdentityNative]::GetFileInformationByHandle($FileStream.SafeFileHandle, [ref]$info)
    if (-not $ok) {
        $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "GetFileInformationByHandle failed with Win32 error $err."
    }

    $fileIndex = ([uint64]$info.nFileIndexHigh -shl 32) -bor [uint64]$info.nFileIndexLow
    $fileSize = ([uint64]$info.nFileSizeHigh -shl 32) -bor [uint64]$info.nFileSizeLow

    return [pscustomobject]@{
        VolumeSerialNumber = [uint32]$info.dwVolumeSerialNumber
        FileIndexHigh      = [uint32]$info.nFileIndexHigh
        FileIndexLow       = [uint32]$info.nFileIndexLow
        FileIndex          = $fileIndex
        NumberOfLinks      = [uint32]$info.nNumberOfLinks
        FileSize           = $fileSize
    }
}

function Assert-V02FileIdentityContinuity {
    param(
        [Parameter(Mandatory = $true)]$BaselineInfo,
        [Parameter(Mandatory = $true)]$CurrentInfo,
        [Parameter(Mandatory = $true)][string]$Context
    )

    if ($BaselineInfo.VolumeSerialNumber -ne $CurrentInfo.VolumeSerialNumber -or
        $BaselineInfo.FileIndex -ne $CurrentInfo.FileIndex) {
        throw "$Context Volume/FileId mismatch: baseline=($($BaselineInfo.VolumeSerialNumber),$($BaselineInfo.FileIndex)) current=($($CurrentInfo.VolumeSerialNumber),$($CurrentInfo.FileIndex))."
    }
    if ($CurrentInfo.NumberOfLinks -ne 1 -and $CurrentInfo.NumberOfLinks -ne $BaselineInfo.NumberOfLinks) {
        throw "$Context hard link count changed or non-singular: $($CurrentInfo.NumberOfLinks)."
    }
}

function Assert-V02TcpListenerInspectionCapability {
    param(
        [Parameter(Mandatory = $false)][string]$CommandName = 'Get-NetTCPConnection'
    )

    $command = Get-Command -Name $CommandName -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        throw "TcpListenerInspectionCapabilityMissing: $CommandName is required to verify that no HerdrOps process opened a TCP listener, and it is not available on this host."
    }
    try {
        $null = & $command -State Listen -ErrorAction Stop
    }
    catch {
        throw "TcpListenerInspectionCapabilityMissing: $CommandName is present but failed when invoked, so TCP-listener inspection cannot be trusted. $($_.Exception.Message)"
    }
    return $command
}

function Assert-V02NoOwnedTcpListeners {
    param(
        [Parameter(Mandatory = $false)][int[]]$ProcessIds = @([int]$PID),
        [Parameter(Mandatory = $false)][string]$CommandName = 'Get-NetTCPConnection'
    )

    $command = Assert-V02TcpListenerInspectionCapability -CommandName $CommandName
    try {
        $listeners = @(& $command -State Listen -ErrorAction Stop |
            Where-Object { $ProcessIds -contains $_.OwningProcess })
    }
    catch {
        throw "TcpListenerInspectionCapabilityMissing: $CommandName is present but failed when invoked, so TCP-listener inspection cannot be trusted. $($_.Exception.Message)"
    }
    if ($listeners.Count -gt 0) {
        $offenders = @($listeners | ForEach-Object { "$($_.OwningProcess):$($_.LocalAddress):$($_.LocalPort)" }) -join ', '
        throw "UnauthorizedTcpListenerDetected: unauthorized TCP listener opened by HerdrOps process: $offenders"
    }
}

function New-V02AtomicNoClobberEmptyFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write)
    $stream.Dispose()
}

function Set-V02AtomicTextFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )

    if (Test-Path -LiteralPath $Path) {
        throw "AtomicWriteRefusedExistingFile: refusing to clobber an existing file: $Path"
    }

    $directory = [System.IO.Path]::GetDirectoryName($Path)
    if (-not [string]::IsNullOrWhiteSpace($directory) -and -not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $tempPath = Join-Path $directory (".tmp." + [Guid]::NewGuid().ToString('N') + ".tmp")
    try {
        [System.IO.File]::WriteAllText($tempPath, $Content, [System.Text.Encoding]::UTF8)
        [System.IO.File]::Move($tempPath, $Path)
    }
    finally {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Assert-V02NotReplayedTranscript {
    param(
        [Parameter(Mandatory = $true)][string]$LedgerPath,
        [Parameter(Mandatory = $true)][string]$TranscriptSha256
    )

    if ($TranscriptSha256 -notmatch '^[0-9A-F]{64}$') {
        throw "Invalid transcript SHA-256: $TranscriptSha256"
    }
    $directory = [System.IO.Path]::GetDirectoryName($LedgerPath)
    if (-not [string]::IsNullOrWhiteSpace($directory) -and -not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    if (Test-Path -LiteralPath $LedgerPath -PathType Leaf) {
        $existingHashes = @(Get-Content -LiteralPath $LedgerPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim().ToUpperInvariant() })
        if ($existingHashes -contains $TranscriptSha256.ToUpperInvariant()) {
            throw "ReplayedTranscriptDetected: transcript SHA-256 $TranscriptSha256 was already recorded in ledger $LedgerPath."
        }
    }
    $TranscriptSha256.ToUpperInvariant() | Out-File -LiteralPath $LedgerPath -Append -Encoding ascii
}

function Get-V02JsonPropertyValue {
    param(
        [Parameter(Mandatory = $true)][AllowNull()]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Object) { return $null }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

function Assert-V02AgentStatusDomain {
    param(
        [Parameter(Mandatory = $true)][string]$Status,
        [Parameter(Mandatory = $true)][string]$Context
    )

    if ($script:V02ValidAgentStatuses -notcontains $Status) {
        throw "$Context invalid agent status '$Status'; must be one of: $($script:V02ValidAgentStatuses -join ', ')."
    }
}

function Assert-V02SemanticStateHashes {
    param(
        [Parameter(Mandatory = $true)]$Transitions,
        [Parameter(Mandatory = $false)][string]$Context = 'Trace transitions'
    )

    $list = @($Transitions)
    if ($list.Count -eq 0) {
        throw "$Context contain no transitions."
    }

    for ($i = 0; $i -lt $list.Count; $i++) {
        $t = $list[$i]
        $idx = $i + 1

        $stateFingerprint = [string](Get-V02JsonPropertyValue -Object $t -Name 'StateFingerprintSha256')
        if ($stateFingerprint -notmatch '^[0-9A-F]{64}$') {
            throw "$Context transition $idx invalid StateFingerprintSha256: '$stateFingerprint'."
        }

        $contractState = [string](Get-V02JsonPropertyValue -Object $t -Name 'ContractStateSha256')
        if ($contractState -notmatch '^[0-9A-F]{64}$') {
            throw "$Context transition $idx invalid ContractStateSha256: '$contractState'."
        }

        $agentTopology = [string](Get-V02JsonPropertyValue -Object $t -Name 'AgentTopologySha256')
        if ($agentTopology -notmatch '^[0-9A-F]{64}$') {
            throw "$Context transition $idx invalid AgentTopologySha256: '$agentTopology'."
        }

        $agentStatus = [string](Get-V02JsonPropertyValue -Object $t -Name 'AgentStatusStateSha256')
        if ($agentStatus -notmatch '^[0-9A-F]{64}$') {
            throw "$Context transition $idx invalid AgentStatusStateSha256: '$agentStatus'."
        }

        $statusStr = [string](Get-V02JsonPropertyValue -Object $t -Name 'Status')
        if ($script:V02ValidMonitorStatuses -notcontains $statusStr) {
            throw "$Context transition $idx invalid monitor Status '$statusStr'."
        }
    }
}

function Assert-V02AllAgentStatusesInDomain {
    param(
        [Parameter(Mandatory = $true)][AllowNull()]$Transitions,
        [Parameter(Mandatory = $true)][AllowNull()]$FinalMonitorState,
        [Parameter(Mandatory = $false)][string]$Context = 'Trace'
    )

    $list = @($Transitions)
    for ($i = 0; $i -lt $list.Count; $i++) {
        $accepted = Get-V02JsonPropertyValue -Object $list[$i] -Name 'AcceptedAgentStatusEvent'
        if ($null -ne $accepted) {
            $status = [string](Get-V02JsonPropertyValue -Object $accepted -Name 'AgentStatus')
            Assert-V02AgentStatusDomain -Status $status -Context "$Context transition $($i + 1) AcceptedAgentStatusEvent"
        }
    }

    $finalState = Get-V02JsonPropertyValue -Object $FinalMonitorState -Name 'State'
    if ($null -eq $finalState) {
        throw "$Context FinalMonitorState is missing its final State snapshot."
    }

    foreach ($collectionName in @('Workspaces', 'Tabs', 'Panes', 'Agents')) {
        $collection = Get-V02JsonPropertyValue -Object $finalState -Name $collectionName
        if ($null -eq $collection) {
            throw "$Context final State snapshot is missing $collectionName."
        }
        foreach ($property in @($collection.PSObject.Properties)) {
            $entry = $property.Value
            $status = [string](Get-V02JsonPropertyValue -Object $entry -Name 'AgentStatus')
            Assert-V02AgentStatusDomain -Status $status -Context "$Context final $collectionName snapshot '$($property.Name)'"
        }
    }
}

function Test-SameHerdrServerProcess {
    param(
        [Parameter(Mandatory)]$Left,
        [Parameter(Mandatory)]$Right
    )

    if ($null -eq $Left -or $null -eq $Right) { return $false }
    $leftStart = ([DateTimeOffset]$Left.ProcessStartUtc).ToUniversalTime()
    $rightStart = ([DateTimeOffset]$Right.ProcessStartUtc).ToUniversalTime()
    return [int]$Left.ProcessId -eq [int]$Right.ProcessId -and
        $leftStart.UtcDateTime.Ticks -eq $rightStart.UtcDateTime.Ticks
}

function Assert-V02HerdrRuntimeTraceReport {
    param(
        [Parameter(Mandatory = $true)][AllowNull()]$Trace,
        [Parameter(Mandatory = $false)]$ControlServerIdentity,
        [Parameter(Mandatory = $false)][DateTimeOffset]$NotBeforeUtc = [DateTimeOffset]::MinValue,
        [Parameter(Mandatory = $false)][string]$ExpectedReleaseId = '0.8.2-preview.2026-08-19-b5c4a0176e91-x86_64-pc-windows-msvc',
        [Parameter(Mandatory = $false)][string]$ExpectedExecutableSha256 = 'AFE7BAD9B77946917B509C9B638BB2A47BC1D4F19254957D15B0FAAFBEDB3E93',
        [Parameter(Mandatory = $false)][string]$ExpectedBundledSchemaSha256 = '3B34717C8B828FAF4E4A1D4DAC5953417712C8EB71A54237FFAD7582C7FF5679',
        [Parameter(Mandatory = $false)][int]$ExpectedProtocol = 20
    )

    if ($null -eq $Trace) {
        throw 'TraceReportNull: the runtime trace report is null.'
    }

    if ([string]$Trace.EvidenceClassification -ne 'Runtime' -or [bool]$Trace.RuntimeObserved -ne $true) {
        throw 'TraceDidNotEarnRuntimeCredit: trace did not earn actual Herdr runtime credit.'
    }
    if ([bool]$Trace.SessionControlInvoked -ne $false) {
        throw 'SessionControlInvokedForbidden: HerdrOps runtime trace must not claim or invoke session control.'
    }
    if ([bool]$Trace.SnapshotObserved -ne $true) {
        throw 'SnapshotNotObserved: actual Herdr snapshot was not observed.'
    }
    if ([bool]$Trace.EventObserved -ne $true) {
        throw 'EventNotObserved: actual Herdr event was not observed.'
    }
    if ([bool]$Trace.ReconnectObserved -ne $true) {
        throw 'ReconnectNotObserved: actual disconnect/reconnect with a fresh snapshot was not observed.'
    }

    if ($null -eq $Trace.Admission) {
        throw 'AdmissionMetadataMissing: admission metadata is missing from the trace report.'
    }
    if ([string]$Trace.Admission.ReleaseId -ne $ExpectedReleaseId) {
        throw "UnexpectedHerdrReleaseId: expected $ExpectedReleaseId, observed $($Trace.Admission.ReleaseId)."
    }
    if ([string]$Trace.Admission.ExecutableSha256 -ne $ExpectedExecutableSha256) {
        throw "UnexpectedHerdrExecutableSha256: expected $ExpectedExecutableSha256, observed $($Trace.Admission.ExecutableSha256)."
    }
    if ([string]$Trace.Admission.BundledSchemaSha256 -ne $ExpectedBundledSchemaSha256) {
        throw "UnexpectedBundledSchemaSha256: expected $ExpectedBundledSchemaSha256, observed $($Trace.Admission.BundledSchemaSha256)."
    }
    if ([int]$Trace.Admission.Protocol -ne $ExpectedProtocol) {
        throw "UnexpectedHerdrProtocol: expected $ExpectedProtocol, observed $($Trace.Admission.Protocol)."
    }

    $observedServer = $Trace.ObservedServerIdentity
    if ($null -eq $observedServer -or [int]$observedServer.ProcessId -le 0) {
        throw 'MissingServerIdentity: runtime trace did not bind the Named Pipe to a server process.'
    }
    if ([string]$observedServer.ExecutableSha256 -ne $ExpectedExecutableSha256) {
        throw 'ServerExecutableSha256Mismatch: Named Pipe server executable hash does not match admitted Herdr executable hash.'
    }
    if ([string]::IsNullOrWhiteSpace([string]$observedServer.ExecutablePath)) {
        throw 'MissingServerExecutablePath: runtime trace did not retain verified Named Pipe server executable path.'
    }
    if ($null -eq $observedServer.ProcessStartUtc) {
        throw 'MissingServerProcessStartTime: runtime trace did not retain verified Named Pipe server process start time.'
    }

    if ($NotBeforeUtc -gt [DateTimeOffset]::MinValue) {
        if ($null -eq $Trace.StartedUtc) {
            throw 'MissingStartedUtc: runtime trace omitted StartedUtc timestamp.'
        }
        $started = [DateTimeOffset]$Trace.StartedUtc
        if ($started -lt $NotBeforeUtc.AddSeconds(-5)) {
            throw "StaleTraceReport: trace StartedUtc ($($started.ToString('O'))) predates run started window ($($NotBeforeUtc.ToString('O')))."
        }
    }
    if ($null -ne $Trace.StartedUtc -and $null -ne $Trace.FinishedUtc) {
        $started = [DateTimeOffset]$Trace.StartedUtc
        $finished = [DateTimeOffset]$Trace.FinishedUtc
        if ($finished -lt $started) {
            throw 'InvalidTraceTimestamps: FinishedUtc predates StartedUtc.'
        }
    }

    $transitions = @($Trace.Transitions)
    if ($transitions.Count -eq 0) {
        throw 'MissingTransitions: trace contains no transitions.'
    }

    Assert-V02SemanticStateHashes -Transitions $transitions -Context 'Trace transitions'
    Assert-V02AllAgentStatusesInDomain -Transitions $transitions -FinalMonitorState $Trace.FinalMonitorState -Context 'Trace'

    $uniqueBootstrapCounts = @($transitions | Where-Object {
        $_.Status -eq 'Connected' -and [long]$_.BootstrapCount -gt 0
    } | Select-Object -ExpandProperty BootstrapCount -Unique)

    if ($uniqueBootstrapCounts.Count -lt 2) {
        throw "InsufficientConnectedBootstraps: expected at least two connected snapshot bootstraps, found $($uniqueBootstrapCounts.Count)."
    }

    $connectedBootstraps = @()
    foreach ($bCount in $uniqueBootstrapCounts) {
        $match = @($transitions | Where-Object { $_.Status -eq 'Connected' -and [long]$_.BootstrapCount -eq [long]$bCount })[0]
        $identity = $match.ServerIdentity
        if ($null -eq $identity -or [int]$identity.ProcessId -le 0) {
            throw "BootstrapServerPidMissing: Bootstrap $bCount has no verified server PID."
        }
        if ($null -eq $identity.ProcessStartUtc) {
            throw "BootstrapServerStartTimeMissing: Bootstrap $bCount has no verified server process start time."
        }
        if ([string]::IsNullOrWhiteSpace($identity.ExecutablePath)) {
            throw "BootstrapServerPathMissing: Bootstrap $bCount has no verified server executable path."
        }
        if ($identity.ExecutableSha256 -ne $ExpectedExecutableSha256) {
            throw "BootstrapServerHashMismatch: Bootstrap $bCount server hash does not match admission."
        }
        Assert-AllAgentsHaveLiveIdentity -Transition $match -Name "Bootstrap $bCount"
        if ([int]$match.AgentCount -le 0) {
            throw "BootstrapAgentCountZero: Bootstrap $bCount has zero agents."
        }
        $connectedBootstraps += $match
    }

    $initialConnectedTransitionIndex = -1
    for ($index = 0; $index -lt $transitions.Count; $index++) {
        if ($transitions[$index].Status -eq 'Connected' -and $null -ne $transitions[$index].ServerIdentity) {
            $initialConnectedTransitionIndex = $index
            break
        }
    }
    if ($initialConnectedTransitionIndex -lt 0) {
        throw 'InitialConnectedTransitionMissing: runtime trace does not contain an initial connected target snapshot.'
    }
    $initialConnectedTransition = $transitions[$initialConnectedTransitionIndex]
    Assert-AllAgentsHaveLiveIdentity -Transition $initialConnectedTransition -Name 'Initial target connected state'

    if ($null -ne $ControlServerIdentity) {
        if (Test-SameHerdrServerProcess -Left $ControlServerIdentity -Right $initialConnectedTransition.ServerIdentity) {
            throw 'SameControlAndTargetServerProcess: acceptance control and target Agent Lab resolved to the same Herdr server process.'
        }
    }

    $eventATransitionIndex = -1
    for ($index = $initialConnectedTransitionIndex + 1; $index -lt $transitions.Count; $index++) {
        if ([long]$transitions[$index].EventCount -gt [long]$initialConnectedTransition.EventCount) {
            $eventATransitionIndex = $index
            break
        }
    }
    if ($eventATransitionIndex -lt 0) {
        throw 'EventANotObserved: Event A was not observed before target restart.'
    }
    $eventATransition = $transitions[$eventATransitionIndex]
    if ($null -eq $eventATransition.ServerIdentity) {
        throw 'EventAServerIdentityMissing: Event A is not bound to a verified target server identity.'
    }
    if ([long]$eventATransition.DisconnectCount -ne [long]$initialConnectedTransition.DisconnectCount) {
        throw 'EventACoincidedWithDisconnect: Event A coincided with a target transport disconnect instead of preceding it.'
    }
    if ([long]$eventATransition.BootstrapCount -ne [long]$initialConnectedTransition.BootstrapCount) {
        throw 'EventACoincidedWithBootstrap: Event A coincided with a target bootstrap instead of preceding the restart.'
    }
    if (-not (Test-SameHerdrServerProcess -Left $initialConnectedTransition.ServerIdentity -Right $eventATransition.ServerIdentity)) {
        throw 'TargetServerIdentityChangedBeforeEventA: target server identity changed before Event A.'
    }
    if ([string]$eventATransition.AcceptedEventKind -ne 'pane.agent_status_changed') {
        throw "InvalidEventAAcceptedEventKind: Event A AcceptedEventKind must be 'pane.agent_status_changed', observed '$($eventATransition.AcceptedEventKind)'."
    }
    if ($null -eq $eventATransition.AcceptedAgentStatusEvent) {
        throw 'EventAAcceptedAgentStatusEventMissing: Event A is missing AcceptedAgentStatusEvent metadata.'
    }
    Assert-AllAgentsHaveLiveIdentity -Transition $eventATransition -Name 'Event A transition'

    for ($index = $initialConnectedTransitionIndex + 1; $index -lt $eventATransitionIndex; $index++) {
        $candidate = $transitions[$index]
        if ([long]$candidate.DisconnectCount -ne [long]$initialConnectedTransition.DisconnectCount) {
            throw 'DisconnectBeforeEventA: a target transport disconnect occurred before Event A.'
        }
        if ([long]$candidate.BootstrapCount -ne [long]$initialConnectedTransition.BootstrapCount) {
            throw 'BootstrapBeforeEventA: a target bootstrap occurred before Event A.'
        }
        if ($null -ne $candidate.ServerIdentity -and
            -not (Test-SameHerdrServerProcess -Left $initialConnectedTransition.ServerIdentity -Right $candidate.ServerIdentity)) {
            throw 'TargetServerIdentityChangedBeforeEventA: target server identity changed before Event A.'
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
        throw 'NoTargetDisconnectAfterEventA: no target transport disconnect occurred after Event A.'
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
        throw 'NoReplacementTargetConnected: no replacement target Herdr server connected after the post-Event-A disconnect.'
    }
    $targetReconnectTransition = $transitions[$targetReconnectTransitionIndex]
    Assert-AllAgentsHaveLiveIdentity -Transition $targetReconnectTransition -Name 'Target reconnected state'

    if ($null -ne $ControlServerIdentity) {
        if (Test-SameHerdrServerProcess -Left $ControlServerIdentity -Right $targetReconnectTransition.ServerIdentity) {
            throw 'RestartedTargetResolvedToControlProcess: restarted target Agent Lab resolved to the Acceptance control server process.'
        }
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
        throw 'NoEventBIncrementObserved: no EventCount increment from Event B was observed after the replacement target connected.'
    }
    $eventBIncrementTransition = $transitions[$eventBIncrementTransitionIndex]

    $eventBTransitionIndex = -1
    for ($index = $eventBIncrementTransitionIndex; $index -lt $transitions.Count; $index++) {
        $candidate = $transitions[$index]
        if ($candidate.Status -eq 'Connected' -and
            [long]$candidate.EventCount -ge [long]$eventBIncrementTransition.EventCount -and
            $null -ne $candidate.ServerIdentity -and
            (Test-SameHerdrServerProcess -Left $targetReconnectTransition.ServerIdentity -Right $candidate.ServerIdentity) -and
            [string]$candidate.AcceptedEventKind -eq 'pane.agent_status_changed') {
            $eventBTransitionIndex = $index
            break
        }
    }
    if ($eventBTransitionIndex -lt $eventBIncrementTransitionIndex) {
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
    }
    if ($eventBTransitionIndex -lt $eventBIncrementTransitionIndex) {
        throw 'NoConnectedStateCarriedEventB: no connected target state carried Event B after its post-reconnect increment.'
    }
    $eventBTransition = $transitions[$eventBTransitionIndex]
    if ([string]$eventBTransition.AcceptedEventKind -ne 'pane.agent_status_changed') {
        throw "InvalidEventBAcceptedEventKind: Event B AcceptedEventKind must be 'pane.agent_status_changed', observed '$($eventBTransition.AcceptedEventKind)'."
    }
    if ($null -eq $eventBTransition.AcceptedAgentStatusEvent) {
        throw 'EventBAcceptedAgentStatusEventMissing: Event B is missing AcceptedAgentStatusEvent metadata.'
    }
    Assert-AllAgentsHaveLiveIdentity -Transition $eventBTransition -Name 'Event B transition'

    if ([long]$Trace.FinalMonitorState.EventCount -lt 2) {
        throw 'InsufficientEventCount: the collector runtime gate requires at least two genuine Agent-status events.'
    }

    return [pscustomobject]@{
        InitialConnectedTransitionIndex = $initialConnectedTransitionIndex
        InitialConnectedTransition      = $initialConnectedTransition
        EventATransitionIndex           = $eventATransitionIndex
        EventATransition                = $eventATransition
        TargetDisconnectTransitionIndex = $targetDisconnectTransitionIndex
        TargetDisconnectTransition      = $targetDisconnectTransition
        TargetReconnectTransitionIndex  = $targetReconnectTransitionIndex
        TargetReconnectTransition       = $targetReconnectTransition
        EventBIncrementTransitionIndex  = $eventBIncrementTransitionIndex
        EventBIncrementTransition       = $eventBIncrementTransition
        EventBTransitionIndex           = $eventBTransitionIndex
        EventBTransition                = $eventBTransition
        ConnectedBootstraps             = $connectedBootstraps
    }
}
