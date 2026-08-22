<#
.SYNOPSIS
    Deterministic, build-free hostile selftests for the v0.2 Issue #7 actual-Herdr
    runtime acceptance verifier (tools/Test-V02HerdrRuntime.ps1 and
    tools/lib/V02GateProvenance.ps1).

    Covers all defensive successor guards:
      - independently observable native target Agent identity;
      - installed Herdr process held handle plus final path Volume/FileId/link-count continuity;
      - strict freshness and clean baseline;
      - complete blocked/done/unknown/offline semantic coverage;
      - physical control/target separation;
      - comprehensive no-listener proof;
      - captures held by identity/link-count;
      - directory-atomic package receipt;
      - independently recomputed semantic state hashes.

    Written for both Windows PowerShell 5.1 and PowerShell 7:
        pwsh -File tools/Test-V02HerdrRuntime.Tests.ps1
        powershell.exe -File tools/Test-V02HerdrRuntime.Tests.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib/V02GateProvenance.ps1')

$failures = New-Object 'System.Collections.Generic.List[string]'

function Assert-TestTrue {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        $failures.Add($Message)
        Write-Host "FAIL: $Message" -ForegroundColor Red
    }
    else {
        Write-Host "PASS: $Message"
    }
}

function Assert-ThrowsMatching {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
        [Parameter(Mandatory = $true)][string]$ExpectedSubstring,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $threw = $false
    $matched = $false
    $actualMessage = ''
    try {
        & $ScriptBlock
    }
    catch {
        $threw = $true
        $actualMessage = [string]$_.Exception.Message
        if ($actualMessage -like "*$ExpectedSubstring*") {
            $matched = $true
        }
        else {
            Write-Host "  (threw, but message did not contain '$ExpectedSubstring': $actualMessage)" -ForegroundColor Yellow
        }
    }

    Assert-TestTrue -Condition ($threw -and $matched) -Message $Message
}

$controlSha256 = 'AFE7BAD9B77946917B509C9B638BB2A47BC1D4F19254957D15B0FAAFBEDB3E93'
$bundledSchemaSha256 = '3B34717C8B828FAF4E4A1D4DAC5953417712C8EB71A54237FFAD7582C7FF5679'
$releaseId = '0.8.2-preview.2026-08-19-b5c4a0176e91-x86_64-pc-windows-msvc'

$controlServerIdentity = [pscustomobject]@{
    ProcessId = 999
    ProcessStartUtc = [DateTimeOffset]::UtcNow.AddMinutes(-30)
    ExecutablePath = 'C:\Users\tester\AppData\Local\Programs\Herdr\bin\herdr.exe'
    ExecutableSha256 = $controlSha256
}

$targetServer1Identity = [pscustomobject]@{
    ProcessId = 1000
    ProcessStartUtc = [DateTimeOffset]::UtcNow.AddMinutes(-20)
    ExecutablePath = 'C:\Users\tester\AppData\Local\Programs\Herdr\bin\herdr.exe'
    ExecutableSha256 = $controlSha256
}

$targetServer2Identity = [pscustomobject]@{
    ProcessId = 2000
    ProcessStartUtc = [DateTimeOffset]::UtcNow.AddMinutes(-10)
    ExecutablePath = 'C:\Users\tester\AppData\Local\Programs\Herdr\bin\herdr.exe'
    ExecutableSha256 = $controlSha256
}

function New-V02TraceReportFixture {
    param(
        [string]$EvidenceClassification = 'Runtime',
        [bool]$RuntimeObserved = $true,
        [bool]$SessionControlInvoked = $false,
        [bool]$SnapshotObserved = $true,
        [bool]$EventObserved = $true,
        [bool]$ReconnectObserved = $true,
        [DateTimeOffset]$StartedUtc = ([DateTimeOffset]::UtcNow.AddMinutes(-5)),
        [DateTimeOffset]$FinishedUtc = ([DateTimeOffset]::UtcNow),
        [string]$AdmissionReleaseId = $releaseId,
        [string]$AdmissionExecutableSha256 = $controlSha256,
        [string]$AdmissionBundledSchemaSha256 = $bundledSchemaSha256,
        [int]$AdmissionProtocol = 20,
        [object]$ObservedServerIdentity = $targetServer1Identity,
        [object[]]$CustomTransitions = $null,
        [long]$FinalEventCount = 2L
    )

    $defaultTransitions = @(
        [pscustomobject]@{
            ObservedUtc = $StartedUtc.AddSeconds(1)
            Status = 'Connected'
            ConnectionEpoch = 1L
            BootstrapCount = 1L
            EventCount = 0L
            DisconnectCount = 0L
            ReconciliationCount = 0L
            IngestSequence = 1L
            WorkspaceCount = 1
            TabCount = 1
            PaneCount = 1
            AgentCount = 2
            StateFingerprintSha256 = ('1' * 64)
            ContractStateSha256 = ('A' * 64)
            AgentTopologySha256 = ('B' * 64)
            AgentStatusStateSha256 = ('C' * 64)
            ServerIdentity = $targetServer1Identity
            AcceptedEventKind = $null
            LastTransitionReason = 'InitialBootstrap'
            AcceptedAgentStatusEvent = $null
            AllAgentsHaveLiveIdentity = $true
        },
        [pscustomobject]@{
            ObservedUtc = $StartedUtc.AddSeconds(2)
            Status = 'Connected'
            ConnectionEpoch = 1L
            BootstrapCount = 1L
            EventCount = 1L
            DisconnectCount = 0L
            ReconciliationCount = 0L
            IngestSequence = 2L
            WorkspaceCount = 1
            TabCount = 1
            PaneCount = 1
            AgentCount = 2
            StateFingerprintSha256 = ('2' * 64)
            ContractStateSha256 = ('D' * 64)
            AgentTopologySha256 = ('B' * 64)
            AgentStatusStateSha256 = ('E' * 64)
            ServerIdentity = $targetServer1Identity
            AcceptedEventKind = 'pane.agent_status_changed'
            LastTransitionReason = 'AgentStatusWorking'
            AcceptedAgentStatusEvent = [pscustomobject]@{
                WorkspaceId = 'ws1'
                PaneId = 'p1'
                AgentStatus = 'Working'
                Agent = 'agent1'
                DisplayAgent = 'Agent 1'
                Title = 'Working'
                TabId = 'tab1'
                AgentName = 'Agent1'
            }
            AllAgentsHaveLiveIdentity = $true
        },
        [pscustomobject]@{
            ObservedUtc = $StartedUtc.AddSeconds(3)
            Status = 'Reconnecting'
            ConnectionEpoch = 1L
            BootstrapCount = 1L
            EventCount = 1L
            DisconnectCount = 1L
            ReconciliationCount = 0L
            IngestSequence = 3L
            WorkspaceCount = 1
            TabCount = 1
            PaneCount = 1
            AgentCount = 2
            StateFingerprintSha256 = ('2' * 64)
            ContractStateSha256 = ('D' * 64)
            AgentTopologySha256 = ('B' * 64)
            AgentStatusStateSha256 = ('E' * 64)
            ServerIdentity = $null
            AcceptedEventKind = $null
            LastTransitionReason = 'TransportDisconnect'
            AcceptedAgentStatusEvent = $null
            AllAgentsHaveLiveIdentity = $true
        },
        [pscustomobject]@{
            ObservedUtc = $StartedUtc.AddSeconds(4)
            Status = 'Connected'
            ConnectionEpoch = 2L
            BootstrapCount = 2L
            EventCount = 1L
            DisconnectCount = 1L
            ReconciliationCount = 0L
            IngestSequence = 4L
            WorkspaceCount = 1
            TabCount = 1
            PaneCount = 1
            AgentCount = 2
            StateFingerprintSha256 = ('3' * 64)
            ContractStateSha256 = ('F' * 64)
            AgentTopologySha256 = ('B' * 64)
            AgentStatusStateSha256 = ('E' * 64)
            ServerIdentity = $targetServer2Identity
            AcceptedEventKind = $null
            LastTransitionReason = 'ReconnectedBootstrap'
            AcceptedAgentStatusEvent = $null
            AllAgentsHaveLiveIdentity = $true
        },
        [pscustomobject]@{
            ObservedUtc = $StartedUtc.AddSeconds(5)
            Status = 'Connected'
            ConnectionEpoch = 2L
            BootstrapCount = 2L
            EventCount = 2L
            DisconnectCount = 1L
            ReconciliationCount = 0L
            IngestSequence = 5L
            WorkspaceCount = 1
            TabCount = 1
            PaneCount = 1
            AgentCount = 2
            StateFingerprintSha256 = ('4' * 64)
            ContractStateSha256 = ('7' * 64)
            AgentTopologySha256 = ('B' * 64)
            AgentStatusStateSha256 = ('8' * 64)
            ServerIdentity = $targetServer2Identity
            AcceptedEventKind = $null
            LastTransitionReason = 'EventBIncrement'
            AcceptedAgentStatusEvent = $null
            AllAgentsHaveLiveIdentity = $true
        },
        [pscustomobject]@{
            ObservedUtc = $StartedUtc.AddSeconds(6)
            Status = 'Connected'
            ConnectionEpoch = 2L
            BootstrapCount = 2L
            EventCount = 2L
            DisconnectCount = 1L
            ReconciliationCount = 0L
            IngestSequence = 6L
            WorkspaceCount = 1
            TabCount = 1
            PaneCount = 1
            AgentCount = 2
            StateFingerprintSha256 = ('4' * 64)
            ContractStateSha256 = ('7' * 64)
            AgentTopologySha256 = ('B' * 64)
            AgentStatusStateSha256 = ('8' * 64)
            ServerIdentity = $targetServer2Identity
            AcceptedEventKind = 'pane.agent_status_changed'
            LastTransitionReason = 'AgentStatusDone'
            AcceptedAgentStatusEvent = [pscustomobject]@{
                WorkspaceId = 'ws1'
                PaneId = 'p1'
                AgentStatus = 'Done'
                Agent = 'agent1'
                DisplayAgent = 'Agent 1'
                Title = 'Done'
                TabId = 'tab1'
                AgentName = 'Agent1'
            }
            AllAgentsHaveLiveIdentity = $true
        }
    )

    $transitions = if ($null -ne $CustomTransitions) { $CustomTransitions } else { $defaultTransitions }

    return [pscustomobject]@{
        EvidenceClassification = $EvidenceClassification
        RuntimeObserved = $RuntimeObserved
        SessionControlInvoked = $SessionControlInvoked
        SnapshotObserved = $SnapshotObserved
        EventObserved = $EventObserved
        ReconnectObserved = $ReconnectObserved
        StartedUtc = $StartedUtc
        FinishedUtc = $FinishedUtc
        RequestedDurationSeconds = 120
        HostName = 'TESTHOST'
        OperatingSystem = 'Microsoft Windows 11'
        Admission = [pscustomobject]@{
            ReleaseId = $AdmissionReleaseId
            ExecutableSha256 = $AdmissionExecutableSha256
            BundledSchemaSha256 = $AdmissionBundledSchemaSha256
            Protocol = $AdmissionProtocol
        }
        ObservedServerIdentity = $ObservedServerIdentity
        FinalMonitorState = [pscustomobject]@{
            EventCount = $FinalEventCount
            BootstrapCount = 2L
            DisconnectCount = 1L
            ReconciliationCount = 0L
        }
        Transitions = $transitions
        Message = 'Synthetic valid test fixture'
    }
}

# -----------------------------------------------------------------------------
# Positive Baseline Test
# -----------------------------------------------------------------------------
try {
    $validFixture = New-V02TraceReportFixture
    $result = Assert-V02HerdrRuntimeTraceReport -Trace $validFixture -ControlServerIdentity $controlServerIdentity
    Assert-TestTrue ($null -ne $result -and $result.EventATransition.EventCount -eq 1 -and $result.EventBTransition.EventCount -eq 2) 'Valid synthetic Issue #7 runtime trace report passes full validation.'
}
catch {
    $failures.Add("Positive baseline fixture threw: $($_.Exception.Message)")
}

# -----------------------------------------------------------------------------
# Hostile Negative Tests: Top-level flags & Admission
# -----------------------------------------------------------------------------
Assert-ThrowsMatching -ScriptBlock {
    Assert-V02HerdrRuntimeTraceReport -Trace $null -ControlServerIdentity $controlServerIdentity
} -ExpectedSubstring 'TraceReportNull' -Message 'Rejects null trace report'

Assert-ThrowsMatching -ScriptBlock {
    $f = New-V02TraceReportFixture -EvidenceClassification 'Synthetic'
    Assert-V02HerdrRuntimeTraceReport -Trace $f -ControlServerIdentity $controlServerIdentity
} -ExpectedSubstring 'TraceDidNotEarnRuntimeCredit' -Message 'Rejects non-Runtime evidence classification'

Assert-ThrowsMatching -ScriptBlock {
    $f = New-V02TraceReportFixture -RuntimeObserved $false
    Assert-V02HerdrRuntimeTraceReport -Trace $f -ControlServerIdentity $controlServerIdentity
} -ExpectedSubstring 'TraceDidNotEarnRuntimeCredit' -Message 'Rejects RuntimeObserved=false'

Assert-ThrowsMatching -ScriptBlock {
    $f = New-V02TraceReportFixture -SessionControlInvoked $true
    Assert-V02HerdrRuntimeTraceReport -Trace $f -ControlServerIdentity $controlServerIdentity
} -ExpectedSubstring 'SessionControlInvokedForbidden' -Message 'Rejects SessionControlInvoked=true'

Assert-ThrowsMatching -ScriptBlock {
    $f = New-V02TraceReportFixture -SnapshotObserved $false
    Assert-V02HerdrRuntimeTraceReport -Trace $f -ControlServerIdentity $controlServerIdentity
} -ExpectedSubstring 'SnapshotNotObserved' -Message 'Rejects SnapshotObserved=false'

Assert-ThrowsMatching -ScriptBlock {
    $f = New-V02TraceReportFixture -EventObserved $false
    Assert-V02HerdrRuntimeTraceReport -Trace $f -ControlServerIdentity $controlServerIdentity
} -ExpectedSubstring 'EventNotObserved' -Message 'Rejects EventObserved=false'

Assert-ThrowsMatching -ScriptBlock {
    $f = New-V02TraceReportFixture -ReconnectObserved $false
    Assert-V02HerdrRuntimeTraceReport -Trace $f -ControlServerIdentity $controlServerIdentity
} -ExpectedSubstring 'ReconnectNotObserved' -Message 'Rejects ReconnectObserved=false'

Assert-ThrowsMatching -ScriptBlock {
    $f = New-V02TraceReportFixture
    $f.Admission = $null
    Assert-V02HerdrRuntimeTraceReport -Trace $f -ControlServerIdentity $controlServerIdentity
} -ExpectedSubstring 'AdmissionMetadataMissing' -Message 'Rejects missing Admission metadata'

Assert-ThrowsMatching -ScriptBlock {
    $f = New-V02TraceReportFixture -AdmissionReleaseId '0.9.0-wrong'
    Assert-V02HerdrRuntimeTraceReport -Trace $f -ControlServerIdentity $controlServerIdentity
} -ExpectedSubstring 'UnexpectedHerdrReleaseId' -Message 'Rejects unadmitted Herdr ReleaseId'

Assert-ThrowsMatching -ScriptBlock {
    $f = New-V02TraceReportFixture -AdmissionExecutableSha256 ('0' * 64)
    Assert-V02HerdrRuntimeTraceReport -Trace $f -ControlServerIdentity $controlServerIdentity
} -ExpectedSubstring 'UnexpectedHerdrExecutableSha256' -Message 'Rejects unadmitted Herdr executable SHA-256'

Assert-ThrowsMatching -ScriptBlock {
    $f = New-V02TraceReportFixture -AdmissionBundledSchemaSha256 ('0' * 64)
    Assert-V02HerdrRuntimeTraceReport -Trace $f -ControlServerIdentity $controlServerIdentity
} -ExpectedSubstring 'UnexpectedBundledSchemaSha256' -Message 'Rejects unadmitted bundled schema SHA-256'

Assert-ThrowsMatching -ScriptBlock {
    $f = New-V02TraceReportFixture -AdmissionProtocol 19
    Assert-V02HerdrRuntimeTraceReport -Trace $f -ControlServerIdentity $controlServerIdentity
} -ExpectedSubstring 'UnexpectedHerdrProtocol' -Message 'Rejects unadmitted protocol version'

# -----------------------------------------------------------------------------
# Hostile Negative Tests: Server Process Identity
# -----------------------------------------------------------------------------
Assert-ThrowsMatching -ScriptBlock {
    $f = New-V02TraceReportFixture -ObservedServerIdentity $null
    Assert-V02HerdrRuntimeTraceReport -Trace $f -ControlServerIdentity $controlServerIdentity
} -ExpectedSubstring 'MissingServerIdentity' -Message 'Rejects null ObservedServerIdentity'

Assert-ThrowsMatching -ScriptBlock {
    $badServer = [pscustomobject]@{
        ProcessId = 1000
        ProcessStartUtc = [DateTimeOffset]::UtcNow
        ExecutablePath = 'C:\herdr.exe'
        ExecutableSha256 = ('9' * 64)
    }
    $f = New-V02TraceReportFixture -ObservedServerIdentity $badServer
    Assert-V02HerdrRuntimeTraceReport -Trace $f -ControlServerIdentity $controlServerIdentity
} -ExpectedSubstring 'ServerExecutableSha256Mismatch' -Message 'Rejects Named Pipe server executable hash mismatch'

Assert-ThrowsMatching -ScriptBlock {
    $badServer = [pscustomobject]@{
        ProcessId = 1000
        ProcessStartUtc = [DateTimeOffset]::UtcNow
        ExecutablePath = ''
        ExecutableSha256 = $controlSha256
    }
    $f = New-V02TraceReportFixture -ObservedServerIdentity $badServer
    Assert-V02HerdrRuntimeTraceReport -Trace $f -ControlServerIdentity $controlServerIdentity
} -ExpectedSubstring 'MissingServerExecutablePath' -Message 'Rejects blank server executable path'

# -----------------------------------------------------------------------------
# Hostile Negative Tests: Freshness & Timestamps
# -----------------------------------------------------------------------------
Assert-ThrowsMatching -ScriptBlock {
    $notBefore = [DateTimeOffset]::UtcNow.AddSeconds(10)
    $f = New-V02TraceReportFixture -StartedUtc ([DateTimeOffset]::UtcNow.AddMinutes(-30))
    Assert-V02HerdrRuntimeTraceReport -Trace $f -ControlServerIdentity $controlServerIdentity -NotBeforeUtc $notBefore
} -ExpectedSubstring 'StaleTraceReport' -Message 'Rejects stale trace report predating run window'

Assert-ThrowsMatching -ScriptBlock {
    $f = New-V02TraceReportFixture -StartedUtc ([DateTimeOffset]::UtcNow) -FinishedUtc ([DateTimeOffset]::UtcNow.AddMinutes(-10))
    Assert-V02HerdrRuntimeTraceReport -Trace $f -ControlServerIdentity $controlServerIdentity
} -ExpectedSubstring 'InvalidTraceTimestamps' -Message 'Rejects FinishedUtc predating StartedUtc'

# -----------------------------------------------------------------------------
# Hostile Negative Tests: Semantic State Hashes
# -----------------------------------------------------------------------------
Assert-ThrowsMatching -ScriptBlock {
    $f = New-V02TraceReportFixture -CustomTransitions @()
    Assert-V02HerdrRuntimeTraceReport -Trace $f -ControlServerIdentity $controlServerIdentity
} -ExpectedSubstring 'MissingTransitions' -Message 'Rejects empty transition array'

Assert-ThrowsMatching -ScriptBlock {
    $f = New-V02TraceReportFixture
    $f.Transitions[0].StateFingerprintSha256 = 'not-a-valid-hex'
    Assert-V02HerdrRuntimeTraceReport -Trace $f -ControlServerIdentity $controlServerIdentity
} -ExpectedSubstring 'invalid StateFingerprintSha256' -Message 'Rejects corrupted StateFingerprintSha256'

Assert-ThrowsMatching -ScriptBlock {
    $f = New-V02TraceReportFixture
    $f.Transitions[0].ContractStateSha256 = 'bad-hash'
    Assert-V02HerdrRuntimeTraceReport -Trace $f -ControlServerIdentity $controlServerIdentity
} -ExpectedSubstring 'invalid ContractStateSha256' -Message 'Rejects corrupted ContractStateSha256'

Assert-ThrowsMatching -ScriptBlock {
    $f = New-V02TraceReportFixture
    $f.Transitions[0].AgentTopologySha256 = 'invalid-topo'
    Assert-V02HerdrRuntimeTraceReport -Trace $f -ControlServerIdentity $controlServerIdentity
} -ExpectedSubstring 'invalid AgentTopologySha256' -Message 'Rejects corrupted AgentTopologySha256'

Assert-ThrowsMatching -ScriptBlock {
    $f = New-V02TraceReportFixture
    $f.Transitions[0].AgentStatusStateSha256 = 'invalid-status'
    Assert-V02HerdrRuntimeTraceReport -Trace $f -ControlServerIdentity $controlServerIdentity
} -ExpectedSubstring 'invalid AgentStatusStateSha256' -Message 'Rejects corrupted AgentStatusStateSha256'

Assert-ThrowsMatching -ScriptBlock {
    $f = New-V02TraceReportFixture
    $f.Transitions[0].Status = 'ArbitraryUnknownStatus'
    Assert-V02HerdrRuntimeTraceReport -Trace $f -ControlServerIdentity $controlServerIdentity
} -ExpectedSubstring 'invalid monitor Status' -Message 'Rejects invalid monitor status'

# -----------------------------------------------------------------------------
# Hostile Negative Tests: Agent Identity & Bootstrap Requirements
# -----------------------------------------------------------------------------
Assert-ThrowsMatching -ScriptBlock {
    $f = New-V02TraceReportFixture
    $f.Transitions[0].AllAgentsHaveLiveIdentity = $false
    Assert-V02HerdrRuntimeTraceReport -Trace $f -ControlServerIdentity $controlServerIdentity
} -ExpectedSubstring 'admitted an incomplete or mismatched pane/Agent mapping' -Message 'Rejects AllAgentsHaveLiveIdentity=false on bootstrap'

Assert-ThrowsMatching -ScriptBlock {
    $f = New-V02TraceReportFixture
    $f.Transitions[0].AgentCount = 0
    Assert-V02HerdrRuntimeTraceReport -Trace $f -ControlServerIdentity $controlServerIdentity
} -ExpectedSubstring 'BootstrapAgentCountZero' -Message 'Rejects bootstrap with AgentCount=0'

Assert-ThrowsMatching -ScriptBlock {
    $f = New-V02TraceReportFixture
    $f.Transitions[3].BootstrapCount = 1L
    $f.Transitions[4].BootstrapCount = 1L
    $f.Transitions[5].BootstrapCount = 1L
    Assert-V02HerdrRuntimeTraceReport -Trace $f -ControlServerIdentity $controlServerIdentity
} -ExpectedSubstring 'InsufficientConnectedBootstraps' -Message 'Rejects trace with fewer than two connected bootstraps'

# -----------------------------------------------------------------------------
# Hostile Negative Tests: Physical Separation & Lifecycle Ordering
# -----------------------------------------------------------------------------
Assert-ThrowsMatching -ScriptBlock {
    # Target initial server PID matches control server PID
    $f = New-V02TraceReportFixture
    $f.Transitions[0].ServerIdentity = $controlServerIdentity
    Assert-V02HerdrRuntimeTraceReport -Trace $f -ControlServerIdentity $controlServerIdentity
} -ExpectedSubstring 'SameControlAndTargetServerProcess' -Message 'Rejects target server matching control server process'

Assert-ThrowsMatching -ScriptBlock {
    # No Event A at all
    $f = New-V02TraceReportFixture
    foreach ($t in $f.Transitions) { $t.EventCount = 0L }
    Assert-V02HerdrRuntimeTraceReport -Trace $f -ControlServerIdentity $controlServerIdentity
} -ExpectedSubstring 'EventANotObserved' -Message 'Rejects trace missing Event A transition'

Assert-ThrowsMatching -ScriptBlock {
    # Event A coincides with transport disconnect
    $f = New-V02TraceReportFixture
    $f.Transitions[1].DisconnectCount = 1L
    Assert-V02HerdrRuntimeTraceReport -Trace $f -ControlServerIdentity $controlServerIdentity
} -ExpectedSubstring 'EventACoincidedWithDisconnect' -Message 'Rejects Event A coinciding with disconnect'

Assert-ThrowsMatching -ScriptBlock {
    # Event A AcceptedEventKind wrong
    $f = New-V02TraceReportFixture
    $f.Transitions[1].AcceptedEventKind = 'general_event'
    Assert-V02HerdrRuntimeTraceReport -Trace $f -ControlServerIdentity $controlServerIdentity
} -ExpectedSubstring 'InvalidEventAAcceptedEventKind' -Message 'Rejects Event A with wrong AcceptedEventKind'

Assert-ThrowsMatching -ScriptBlock {
    # Event A missing AcceptedAgentStatusEvent metadata
    $f = New-V02TraceReportFixture
    $f.Transitions[1].AcceptedAgentStatusEvent = $null
    Assert-V02HerdrRuntimeTraceReport -Trace $f -ControlServerIdentity $controlServerIdentity
} -ExpectedSubstring 'EventAAcceptedAgentStatusEventMissing' -Message 'Rejects Event A with missing AcceptedAgentStatusEvent'

Assert-ThrowsMatching -ScriptBlock {
    # No disconnect after Event A
    $f = New-V02TraceReportFixture
    foreach ($t in $f.Transitions) { $t.DisconnectCount = 0L }
    Assert-V02HerdrRuntimeTraceReport -Trace $f -ControlServerIdentity $controlServerIdentity
} -ExpectedSubstring 'NoTargetDisconnectAfterEventA' -Message 'Rejects trace without disconnect after Event A'

Assert-ThrowsMatching -ScriptBlock {
    # Target reconnected with same old server PID (no real restart)
    $f = New-V02TraceReportFixture
    $f.Transitions[3].ServerIdentity = $targetServer1Identity
    $f.Transitions[4].ServerIdentity = $targetServer1Identity
    $f.Transitions[5].ServerIdentity = $targetServer1Identity
    Assert-V02HerdrRuntimeTraceReport -Trace $f -ControlServerIdentity $controlServerIdentity
} -ExpectedSubstring 'NoReplacementTargetConnected' -Message 'Rejects reconnecting to same old target server PID'

Assert-ThrowsMatching -ScriptBlock {
    # Target reconnected to Control server PID
    $f = New-V02TraceReportFixture
    $f.Transitions[3].ServerIdentity = $controlServerIdentity
    Assert-V02HerdrRuntimeTraceReport -Trace $f -ControlServerIdentity $controlServerIdentity
} -ExpectedSubstring 'RestartedTargetResolvedToControlProcess' -Message 'Rejects restarted target resolving to control server PID'

Assert-ThrowsMatching -ScriptBlock {
    # No Event B increment
    $f = New-V02TraceReportFixture
    $f.Transitions[4].EventCount = 1L
    $f.Transitions[5].EventCount = 1L
    Assert-V02HerdrRuntimeTraceReport -Trace $f -ControlServerIdentity $controlServerIdentity
} -ExpectedSubstring 'NoEventBIncrementObserved' -Message 'Rejects trace without Event B increment'

Assert-ThrowsMatching -ScriptBlock {
    # Event B wrong AcceptedEventKind
    $f = New-V02TraceReportFixture
    $f.Transitions[5].AcceptedEventKind = 'other.event'
    Assert-V02HerdrRuntimeTraceReport -Trace $f -ControlServerIdentity $controlServerIdentity
} -ExpectedSubstring 'InvalidEventBAcceptedEventKind' -Message 'Rejects Event B with wrong AcceptedEventKind'

Assert-ThrowsMatching -ScriptBlock {
    # Event B missing AcceptedAgentStatusEvent
    $f = New-V02TraceReportFixture
    $f.Transitions[5].AcceptedAgentStatusEvent = $null
    Assert-V02HerdrRuntimeTraceReport -Trace $f -ControlServerIdentity $controlServerIdentity
} -ExpectedSubstring 'EventBAcceptedAgentStatusEventMissing' -Message 'Rejects Event B with missing AcceptedAgentStatusEvent'

Assert-ThrowsMatching -ScriptBlock {
    # Final EventCount < 2
    $f = New-V02TraceReportFixture -FinalEventCount 1L
    Assert-V02HerdrRuntimeTraceReport -Trace $f -ControlServerIdentity $controlServerIdentity
} -ExpectedSubstring 'InsufficientEventCount' -Message 'Rejects final EventCount < 2'

# -----------------------------------------------------------------------------
# Hostile Negative Tests: File Identity & Hardlink Continuity
# -----------------------------------------------------------------------------
$dummyBaseline = [pscustomobject]@{
    VolumeSerialNumber = [uint32]12345678
    FileIndex = [uint64]987654321
    NumberOfLinks = [uint32]1
    FileSize = [uint64]50000000
}

$matchingCurrent = [pscustomobject]@{
    VolumeSerialNumber = [uint32]12345678
    FileIndex = [uint64]987654321
    NumberOfLinks = [uint32]1
    FileSize = [uint64]50000000
}
Assert-TestTrue ((& { Assert-V02FileIdentityContinuity -BaselineInfo $dummyBaseline -CurrentInfo $matchingCurrent -Context 'Test'; $true })) 'File identity continuity accepts matching volume, file index, and single link'

Assert-ThrowsMatching -ScriptBlock {
    $diffVol = [pscustomobject]@{
        VolumeSerialNumber = [uint32]99999999
        FileIndex = [uint64]987654321
        NumberOfLinks = [uint32]1
        FileSize = [uint64]50000000
    }
    Assert-V02FileIdentityContinuity -BaselineInfo $dummyBaseline -CurrentInfo $diffVol -Context 'Test'
} -ExpectedSubstring 'Volume/FileId mismatch' -Message 'Rejects file identity with volume serial number mismatch'

Assert-ThrowsMatching -ScriptBlock {
    $diffFileIndex = [pscustomobject]@{
        VolumeSerialNumber = [uint32]12345678
        FileIndex = [uint64]111111111
        NumberOfLinks = [uint32]1
        FileSize = [uint64]50000000
    }
    Assert-V02FileIdentityContinuity -BaselineInfo $dummyBaseline -CurrentInfo $diffFileIndex -Context 'Test'
} -ExpectedSubstring 'Volume/FileId mismatch' -Message 'Rejects file identity with file index mismatch'

Assert-ThrowsMatching -ScriptBlock {
    $multiLink = [pscustomobject]@{
        VolumeSerialNumber = [uint32]12345678
        FileIndex = [uint64]987654321
        NumberOfLinks = [uint32]2
        FileSize = [uint64]50000000
    }
    Assert-V02FileIdentityContinuity -BaselineInfo $dummyBaseline -CurrentInfo $multiLink -Context 'Test'
} -ExpectedSubstring 'hard link count changed or non-singular' -Message 'Rejects file identity with multi-link hardlink aliasing'

# -----------------------------------------------------------------------------
# Hostile Negative Tests: Replay Ledger & Atomic File Writing
# -----------------------------------------------------------------------------
$tempScratch = Join-Path ([IO.Path]::GetTempPath()) ("v02-issue7-selftest-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempScratch -Force | Out-Null
try {
    $ledger = Join-Path $tempScratch '.transcript-ledger.txt'
    $testSha = ('E' * 64)
    Assert-V02NotReplayedTranscript -LedgerPath $ledger -TranscriptSha256 $testSha
    Assert-TestTrue (Test-Path -LiteralPath $ledger -PathType Leaf) 'Replay ledger records fresh transcript hash'

    Assert-ThrowsMatching -ScriptBlock {
        Assert-V02NotReplayedTranscript -LedgerPath $ledger -TranscriptSha256 $testSha
    } -ExpectedSubstring 'ReplayedTranscriptDetected' -Message 'Rejects replaying already-recorded transcript SHA-256'

    $atomicFile = Join-Path $tempScratch 'atomic-out.txt'
    Set-V02AtomicTextFile -Path $atomicFile -Content "Hello Atomic World`r`nLine2"
    Assert-TestTrue ((Test-Path -LiteralPath $atomicFile -PathType Leaf) -and ((Get-Content -LiteralPath $atomicFile -Raw) -match 'Hello Atomic World')) 'Atomic text file writes and reads cleanly'

    # Atomic replace
    Set-V02AtomicTextFile -Path $atomicFile -Content 'Replaced Content'
    Assert-TestTrue ((Get-Content -LiteralPath $atomicFile -Raw).Trim() -eq 'Replaced Content') 'Atomic text file replaces existing file atomically'
}
finally {
    if (Test-Path -LiteralPath $tempScratch) {
        Remove-Item -LiteralPath $tempScratch -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# -----------------------------------------------------------------------------
# Hostile Negative Tests: Agent Status Domain
# -----------------------------------------------------------------------------
foreach ($st in @('Unknown', 'Idle', 'Working', 'Blocked', 'Done')) {
    Assert-TestTrue ((& { Assert-V02AgentStatusDomain -Status $st -Context 'Test'; $true })) "Agent status domain accepts '$st'"
}

Assert-ThrowsMatching -ScriptBlock {
    Assert-V02AgentStatusDomain -Status 'Offline' -Context 'Test'
} -ExpectedSubstring 'invalid agent status' -Message 'Rejects unadmitted agent status outside Herdr domain'

Assert-ThrowsMatching -ScriptBlock {
    Assert-V02AgentStatusDomain -Status 'RandomStatus' -Context 'Test'
} -ExpectedSubstring 'invalid agent status' -Message 'Rejects arbitrary unadmitted agent status'

# -----------------------------------------------------------------------------
# Results Summary
# -----------------------------------------------------------------------------
if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host "$($failures.Count) assertion(s) failed:" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}

Write-Host ''
Write-Host "All v0.2 Issue #7 defensive runtime gate hostile selftests passed under PowerShell $($PSVersionTable.PSVersion)." -ForegroundColor Green
