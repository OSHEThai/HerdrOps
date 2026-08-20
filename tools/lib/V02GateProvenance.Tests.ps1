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
    Assert-TestThrows `
        -ScriptBlock { Assert-AllAgentsHaveLiveIdentity -Transition $missingFlagTransition -Name 'leading reconciliation' } `
        -Message 'Assert-AllAgentsHaveLiveIdentity rejects a leading-reconciliation transition that omits the aggregate Agent-identity contract flag'
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
Write-Host 'All v0.2 leading-reconciliation Agent-identity hardening assertions passed.' -ForegroundColor Green
