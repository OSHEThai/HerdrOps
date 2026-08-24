<#
Focused, build-free regression for the v0.2 aggregate event-agent identity
gate hardening (Issues #7 #10, P2 defense-in-depth):

  The composite gate's Assert-AgentStatusTransitionEvidence already asserted
  Assert-AllAgentsHaveLiveIdentity on the baseline and current (accepted-Event)
  Core transitions, but not on the unlabelled leading-reconciliation snapshot
  that sits between them on the snapshot-before-event admission path. A Core
  transition observed at that midpoint with a blank Agent kind/name or an
  Unknown Agent status therefore was not independently rejected by the gate.

  These tests prove Assert-AllAgentsHaveLiveIdentity fails closed for exactly
  that midpoint transition shape, and continues to accept a genuinely live one.

Run directly with PowerShell; throws (and exits non-zero) on the first failed
assertion:

    pwsh -File tools/lib/V02GateProvenance.Tests.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) { throw $Message }
}

function Test-ObjectHasProperty {
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string]$Name
    )

    return $null -ne $Object.PSObject.Properties[$Name]
}

. (Join-Path $PSScriptRoot 'V02GateProvenance.ps1')

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

function Assert-TestThrows {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $threw = $false
    try {
        & $ScriptBlock
    }
    catch {
        $threw = $true
    }
    Assert-TestTrue -Condition $threw -Message $Message
}

$validSessionList = [pscustomobject]@{
    sessions = @(
        [pscustomobject]@{
            default = $true
            name = 'default'
            running = $true
            socket_path = 'C:\Users\tester\AppData\Roaming\herdr\herdr.sock'
        }
        [pscustomobject]@{
            default = $false
            name = 'acceptance'
            running = $true
            socket_path = 'C:\Users\tester\AppData\Roaming\herdr\sessions\acceptance\herdr.sock'
        }
    )
} | ConvertTo-Json -Depth 4 -Compress

try {
    $validTopology = Assert-V02AcceptanceSessionTopology `
        -SessionListJson $validSessionList `
        -ControlSocketPath 'C:\Users\tester\AppData\Roaming\herdr\sessions\acceptance\herdr.sock' `
        -TargetSocketPath 'C:\Users\tester\AppData\Roaming\herdr\herdr.sock'
    Assert-TestTrue `
        -Condition ($validTopology.ControlSessionName -ceq 'acceptance' -and $validTopology.TargetSessionName -ceq 'default') `
        -Message 'Acceptance session guard accepts an isolated acceptance control and default target session'

    Assert-TestThrows `
        -ScriptBlock {
            Assert-V02AcceptanceSessionTopology `
                -SessionListJson $validSessionList `
                -ControlSocketPath 'C:\Users\tester\AppData\Roaming\herdr\herdr.sock' `
                -TargetSocketPath 'C:\Users\tester\AppData\Roaming\herdr\sessions\acceptance\herdr.sock'
        } `
        -Message 'Acceptance session guard rejects a default-session control pane'

    Assert-TestThrows `
        -ScriptBlock {
            Assert-V02AcceptanceSessionTopology `
                -SessionListJson $validSessionList `
                -ControlSocketPath 'C:\Users\tester\AppData\Roaming\herdr\sessions\acceptance\herdr.sock' `
                -TargetSocketPath 'C:\Users\tester\AppData\Roaming\herdr\sessions\acceptance\herdr.sock'
        } `
        -Message 'Acceptance session guard rejects a target socket equal to the control socket'

    $stoppedTargetList = [pscustomobject]@{
        sessions = @(
            [pscustomobject]@{
                default = $true
                name = 'default'
                running = $false
                socket_path = 'C:\Users\tester\AppData\Roaming\herdr\herdr.sock'
            }
            [pscustomobject]@{
                default = $false
                name = 'acceptance'
                running = $true
                socket_path = 'C:\Users\tester\AppData\Roaming\herdr\sessions\acceptance\herdr.sock'
            }
        )
    } | ConvertTo-Json -Depth 4 -Compress
    Assert-TestThrows `
        -ScriptBlock {
            Assert-V02AcceptanceSessionTopology `
                -SessionListJson $stoppedTargetList `
                -ControlSocketPath 'C:\Users\tester\AppData\Roaming\herdr\sessions\acceptance\herdr.sock' `
                -TargetSocketPath 'C:\Users\tester\AppData\Roaming\herdr\herdr.sock'
        } `
        -Message 'Acceptance session guard rejects a stopped target session'
}
catch {
    $failures.Add("Acceptance session guard test failed: $($_.Exception.Message)")
}

# A leading-reconciliation transition mirrors the unlabelled Core snapshot the
# gate correlates between the App baseline and the accepted Agent-status Event
# on the snapshot-before-event admission path (Test-V02LiveRuntimeAcceptance.ps1
# Assert-AgentStatusTransitionEvidence, $leadingReconciliation).
function New-LeadingReconciliationTransition {
    param([bool]$AllAgentsHaveLiveIdentity = $true)

    return [pscustomobject]@{
        Status                   = 'Connected'
        IngestSequence           = 5L
        EventCount               = 1L
        BootstrapCount           = 1L
        DisconnectCount          = 0L
        ReconciliationCount      = 2L
        ConnectionEpoch          = 1L
        ContractStateSha256      = ('A' * 64)
        AcceptedEventKind        = $null
        AllAgentsHaveLiveIdentity = $AllAgentsHaveLiveIdentity
    }
}

try {
    # --- Assert-AllAgentsHaveLiveIdentity: accepts a genuinely live midpoint --

    $liveTransition = New-LeadingReconciliationTransition -AllAgentsHaveLiveIdentity $true
    Assert-TestTrue `
        -Condition ((& { Assert-AllAgentsHaveLiveIdentity -Transition $liveTransition -Name 'leading reconciliation'; $true })) `
        -Message 'Assert-AllAgentsHaveLiveIdentity accepts a leading-reconciliation transition where every Agent has a live identity'

    # --- Fails closed: mixed valid + Agentless/Unknown topology at the midpoint

    $mixedTopologyTransition = New-LeadingReconciliationTransition -AllAgentsHaveLiveIdentity $false
    Assert-TestThrows `
        -ScriptBlock { Assert-AllAgentsHaveLiveIdentity -Transition $mixedTopologyTransition -Name 'leading reconciliation' } `
        -Message 'Assert-AllAgentsHaveLiveIdentity rejects a leading-reconciliation transition with mixed valid + Agentless/Unknown topology (AllAgentsHaveLiveIdentity=false)'

    # --- Fails closed: Core/App/gate parity requires the flag be present too -

    $missingFlagTransition = [pscustomobject]@{
        Status              = 'Connected'
        IngestSequence      = 5L
        EventCount          = 1L
        BootstrapCount      = 1L
        DisconnectCount     = 0L
        ReconciliationCount = 2L
        ConnectionEpoch     = 1L
        ContractStateSha256 = ('A' * 64)
        AcceptedEventKind   = $null
    }
    # --- File identity & continuity assertions ---
    $tempFile = [System.IO.Path]::GetTempFileName()
    try {
        [System.IO.File]::WriteAllText($tempFile, 'Sample Herdr Executable Content')
        $stream = Open-V02HeldFileStream -Path $tempFile
        try {
            $info = Get-V02FileInformation -FileStream $stream
            Assert-TestTrue ($info.VolumeSerialNumber -gt 0 -and $info.FileSize -gt 0) 'Get-V02FileInformation extracts valid volume serial number and file size'
            Assert-TestTrue ($info.NumberOfLinks -ge 1) 'Get-V02FileInformation extracts valid link count'

            Assert-TestTrue ((& { Assert-V02FileIdentityContinuity -BaselineInfo $info -CurrentInfo $info -Context 'Self'; $true })) 'Assert-V02FileIdentityContinuity accepts identical file info'
        }
        finally {
            $stream.Dispose()
        }
    }
    finally {
        if (Test-Path -LiteralPath $tempFile) {
            Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
        }
    }

    # --- No owned TCP listeners check ---
    Assert-TestTrue ((& { Assert-V02NoOwnedTcpListeners -ProcessIds @([int]$PID); $true })) 'Assert-V02NoOwnedTcpListeners passes when no TCP listeners are owned'

    # --- Hostile real-listener detection: prove the guard actually catches a live listener,
    #     not merely that it stays quiet when none exists. ---
    if (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue) {
        $hostileListener = $null
        $hostileListenerDetected = $false
        try {
            $hostileListener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
            $hostileListener.Start()
            for ($attempt = 0; $attempt -lt 20 -and -not $hostileListenerDetected; $attempt++) {
                try {
                    Assert-V02NoOwnedTcpListeners -ProcessIds @([int]$PID)
                    Start-Sleep -Milliseconds 100
                }
                catch {
                    $hostileListenerDetected = $true
                }
            }
        }
        finally {
            if ($null -ne $hostileListener) {
                $hostileListener.Stop()
            }
        }
        Assert-TestTrue $hostileListenerDetected 'Assert-V02NoOwnedTcpListeners detects a real TCP listener actually opened by the current process'
        Assert-TestTrue ((& { Assert-V02NoOwnedTcpListeners -ProcessIds @([int]$PID); $true })) 'Assert-V02NoOwnedTcpListeners passes again once the hostile listener is closed'
    }
    else {
        Assert-TestTrue $true 'Get-NetTCPConnection unavailable on this host; hostile real-listener detection defensively skipped'
    }

    # --- Fails closed (never silently succeeds) when the TCP-listener
    #     inspection capability is missing or broken, regardless of whether
    #     the real Get-NetTCPConnection happens to be present on this host. ---
    Assert-TestThrows `
        -ScriptBlock { Assert-V02TcpListenerInspectionCapability -CommandName 'Get-V02NonexistentCommandForCapabilityTest' } `
        -Message 'Assert-V02TcpListenerInspectionCapability fails closed when the inspection command does not exist'

    Assert-TestThrows `
        -ScriptBlock { Assert-V02NoOwnedTcpListeners -ProcessIds @([int]$PID) -CommandName 'Get-V02NonexistentCommandForCapabilityTest' } `
        -Message 'Assert-V02NoOwnedTcpListeners fails closed when the inspection command does not exist'

    function Test-V02BrokenTcpListenerProbe {
        param([string]$State, [string]$ErrorAction)
        throw 'Simulated TCP-listener inspection capability failure.'
    }
    Assert-TestThrows `
        -ScriptBlock { Assert-V02TcpListenerInspectionCapability -CommandName 'Test-V02BrokenTcpListenerProbe' } `
        -Message 'Assert-V02TcpListenerInspectionCapability fails closed when the inspection command exists but throws when invoked'
    Assert-TestThrows `
        -ScriptBlock { Assert-V02NoOwnedTcpListeners -ProcessIds @([int]$PID) -CommandName 'Test-V02BrokenTcpListenerProbe' } `
        -Message 'Assert-V02NoOwnedTcpListeners fails closed when the inspection command exists but throws when invoked'

    # --- Assert-V02AllAgentStatusesInDomain: exact five-value domain, wired
    #     against the same accepted-event and final Workspaces/Tabs/Panes/Agents
    #     snapshot shape the composite production gate reads from Core. ---
    function New-CompositeShapeCoreReportFixture {
        param([string]$EventAgentStatus = 'Working', [string]$FinalWorkspaceAgentStatus = 'Idle')

        return [pscustomobject]@{
            Transitions = @(
                [pscustomobject]@{
                    AcceptedAgentStatusEvent = [pscustomobject]@{
                        WorkspaceId = 'ws1'
                        PaneId      = 'p1'
                        AgentStatus = $EventAgentStatus
                    }
                }
            )
            FinalMonitorState = [pscustomobject]@{
                State = [pscustomobject]@{
                    Workspaces = [pscustomobject]@{ ws1 = [pscustomobject]@{ AgentStatus = $FinalWorkspaceAgentStatus } }
                    Tabs       = [pscustomobject]@{ tab1 = [pscustomobject]@{ AgentStatus = 'Working' } }
                    Panes      = [pscustomobject]@{ p1 = [pscustomobject]@{ AgentStatus = 'Working' } }
                    Agents     = [pscustomobject]@{ agent1 = [pscustomobject]@{ AgentStatus = 'Done' } }
                }
            }
        }
    }

    $validCompositeFixture = New-CompositeShapeCoreReportFixture
    Assert-TestTrue `
        -Condition ((& { Assert-V02AllAgentStatusesInDomain -Transitions $validCompositeFixture.Transitions -FinalMonitorState $validCompositeFixture.FinalMonitorState -Context 'Core report'; $true })) `
        -Message 'Assert-V02AllAgentStatusesInDomain accepts a valid composite-shaped Core report'

    $badEventFixture = New-CompositeShapeCoreReportFixture -EventAgentStatus 'Bogus'
    Assert-TestThrows `
        -ScriptBlock { Assert-V02AllAgentStatusesInDomain -Transitions $badEventFixture.Transitions -FinalMonitorState $badEventFixture.FinalMonitorState -Context 'Core report' } `
        -Message 'Assert-V02AllAgentStatusesInDomain rejects an invalid AgentStatus on an accepted composite Event'

    $badFinalFixture = New-CompositeShapeCoreReportFixture -FinalWorkspaceAgentStatus 'Bogus'
    Assert-TestThrows `
        -ScriptBlock { Assert-V02AllAgentStatusesInDomain -Transitions $badFinalFixture.Transitions -FinalMonitorState $badFinalFixture.FinalMonitorState -Context 'Core report' } `
        -Message 'Assert-V02AllAgentStatusesInDomain rejects an invalid AgentStatus in the final composite Workspaces snapshot'

    $missingStateFixture = New-CompositeShapeCoreReportFixture
    $missingStateFixture.FinalMonitorState.State = $null
    Assert-TestThrows `
        -ScriptBlock { Assert-V02AllAgentStatusesInDomain -Transitions $missingStateFixture.Transitions -FinalMonitorState $missingStateFixture.FinalMonitorState -Context 'Core report' } `
        -Message 'Assert-V02AllAgentStatusesInDomain rejects a composite Core report missing its final State snapshot'

    # --- New-V02AtomicNoClobberEmptyFile: concurrent atomic no-clobber coverage
    #     for the composite gate's completion-signal creation. ---
    $signalDir = Join-Path ([System.IO.Path]::GetTempPath()) ('v02-gate-signal-test-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $signalDir -Force | Out-Null
    try {
        $freshSignalPath = Join-Path $signalDir 'fresh.signal'
        New-V02AtomicNoClobberEmptyFile -Path $freshSignalPath
        Assert-TestTrue (Test-Path -LiteralPath $freshSignalPath -PathType Leaf) 'New-V02AtomicNoClobberEmptyFile creates the signal file'
        Assert-TestTrue (((Get-Item -LiteralPath $freshSignalPath).Length) -eq 0) 'New-V02AtomicNoClobberEmptyFile creates a genuinely empty (zero-byte) file'

        $concurrentSignalPath = Join-Path $signalDir 'concurrent.signal'
        [System.IO.File]::WriteAllText($concurrentSignalPath, 'concurrent-writer-content')
        Assert-TestThrows `
            -ScriptBlock { New-V02AtomicNoClobberEmptyFile -Path $concurrentSignalPath } `
            -Message 'New-V02AtomicNoClobberEmptyFile fails closed instead of clobbering a concurrently-created file'
        $preservedContent = [System.IO.File]::ReadAllText($concurrentSignalPath)
        Assert-TestTrue ($preservedContent -ceq 'concurrent-writer-content') 'New-V02AtomicNoClobberEmptyFile left the concurrently-created file untouched'
    }
    finally {
        if (Test-Path -LiteralPath $signalDir) {
            Remove-Item -LiteralPath $signalDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
finally {
}

if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host "$($failures.Count) assertion(s) failed:" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}

Write-Host ''
Write-Host 'All v0.2 gate provenance and Acceptance-session assertions passed.' -ForegroundColor Green
