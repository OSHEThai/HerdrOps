[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$helperPath = Join-Path $PSScriptRoot 'lib\V05DistributedRoleProvenance.ps1'
$wrapperPath = Join-Path $PSScriptRoot 'Invoke-V05ComplianceRuntimeAcceptance.ps1'
. $helperPath

$passed = 0
function Assert-Pass {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][bool]$Condition)
    if (-not $Condition) { throw "FAILED: $Name" }
    $script:passed++
    Write-Output "PASS: $Name"
}

function Assert-Rejected {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Prefix,
        [Parameter(Mandatory)][scriptblock]$Action)
    $message = ''
    try { & $Action | Out-Null } catch { $message = $_.Exception.Message }
    if ($message -notlike "$Prefix*") { Write-Output "UNEXPECTED: $message" }
    Assert-Pass -Name $Name -Condition ($message -like "$Prefix*")
}

function New-Action {
    param(
        [int]$Sequence,
        [string]$Action,
        [string]$Outcome,
        [string]$Role,
        [string]$Pane,
        [int]$ProcessId,
        [int]$PaneRootProcessId,
        [string]$PaneRootProcessStartedUtc,
        [string]$StartedUtc,
        [string]$ObservedUtc,
        [string]$RunNonce,
        [string]$CommandId)
    $result = [pscustomobject][ordered]@{
        schemaVersion = 1
        runNonce = $RunNonce
        sequence = $Sequence
        action = $Action
        outcome = $Outcome
        actorRole = $Role
        actorPaneId = $Pane
        requestCommandId = $CommandId
        clientProcessId = $ProcessId
        clientProcessStartedUtc = $StartedUtc
        observedUtc = $ObservedUtc
        authorizedPaneId = $Pane
        authorizedClientProcessId = $ProcessId
        authorizedClientProcessStartedUtc = $StartedUtc
        authorizingServerInstanceId = $script:serverInstanceId
        paneRootProcessId = $PaneRootProcessId
        paneRootProcessStartedUtc = $PaneRootProcessStartedUtc
        serverAuthorizationObserved = $true
        processAncestry = @(
            [pscustomobject][ordered]@{ processId = $PaneRootProcessId; processStartedUtc = $PaneRootProcessStartedUtc },
            [pscustomobject][ordered]@{ processId = $ProcessId; processStartedUtc = $StartedUtc })
        processAncestrySha256 = ''
        receiptSha256 = ''
    }
    $result.processAncestrySha256 = Get-V05CanonicalAncestrySha256 -ProcessAncestry @($result.processAncestry)
    $result.receiptSha256 = Get-V05CanonicalReceiptSha256 -Action $result
    return $result
}

function Copy-Actions {
    param([object[]]$Actions)
    return @($Actions | ForEach-Object {
            $copy = [ordered]@{}
            foreach ($property in $_.PSObject.Properties) {
                if ($property.Name -ceq 'processAncestry') {
                    $copy[$property.Name] = @($property.Value | ForEach-Object {
                            [pscustomobject][ordered]@{
                                processId = $_.processId
                                processStartedUtc = [string]$_.processStartedUtc
                            }
                        })
                } else {
                    $copy[$property.Name] = $property.Value
                }
            }
            [pscustomobject]$copy
        })
}

$nonce = 'A' * 64
$serverInstanceId = '20000000-0000-0000-0000-000000000001'
$pm = 'pane-pm'
$leader = 'pane-leader'
$subject = 'pane-subject'
$actions = @(
    (New-Action 0 'self-review-denied' 'REJECTED_SELF_REVIEW' 'Subject' $subject 4101 3101 '2026-08-21T23:59:00.000Z' '2026-08-22T00:00:00.000Z' '2026-08-22T00:00:01.000Z' $nonce '10000000-0000-0000-0000-000000000001'),
    (New-Action 1 'send-to-leader' 'ACCEPTED' 'ProjectManager' $pm 4102 3102 '2026-08-21T23:59:01.000Z' '2026-08-22T00:00:02.000Z' '2026-08-22T00:00:03.000Z' $nonce '10000000-0000-0000-0000-000000000002'),
    (New-Action 2 'escalate-to-project-manager' 'ACCEPTED' 'Leader' $leader 4103 3103 '2026-08-21T23:59:02.000Z' '2026-08-22T00:00:04.000Z' '2026-08-22T00:00:05.000Z' $nonce '10000000-0000-0000-0000-000000000003'),
    (New-Action 3 'confirm' 'ACCEPTED' 'ProjectManager' $pm 4104 3102 '2026-08-21T23:59:01.000Z' '2026-08-22T00:00:06.000Z' '2026-08-22T00:00:07.000Z' $nonce '10000000-0000-0000-0000-000000000004'))

$valid = Assert-V05DistributedRoleActionSet -Actions $actions -RunNonce $nonce -AuthorizingServerInstanceId $serverInstanceId -ProjectManagerPaneId $pm -LeaderPaneId $leader -SubjectPaneId $subject
Assert-Pass -Name 'valid distributed action set binds three panes and grants no Runtime credit' -Condition (
    $valid.Valid -and $valid.DistinctPaneCount -eq 3 -and $valid.RuntimeCredit -ceq 'NOT GRANTED')

$wrongPane = Copy-Actions $actions
$wrongPane[2].authorizedPaneId = $pm
Assert-Rejected -Name 'wrong-pane authorization fails closed' -Prefix 'DistributedRoleProvenanceWrongPane' -Action {
    Assert-V05DistributedRoleActionSet -Actions $wrongPane -RunNonce $nonce -AuthorizingServerInstanceId $serverInstanceId -ProjectManagerPaneId $pm -LeaderPaneId $leader -SubjectPaneId $subject
}

$wrongProcess = Copy-Actions $actions
$wrongProcess[1].authorizedClientProcessId = 9999
Assert-Rejected -Name 'wrong connected client PID fails closed' -Prefix 'DistributedRoleProvenanceWrongProcess' -Action {
    Assert-V05DistributedRoleActionSet -Actions $wrongProcess -RunNonce $nonce -AuthorizingServerInstanceId $serverInstanceId -ProjectManagerPaneId $pm -LeaderPaneId $leader -SubjectPaneId $subject
}

$pidReuse = Copy-Actions $actions
$pidReuse[2].clientProcessId = 4102
$pidReuse[2].authorizedClientProcessId = 4102
Assert-Rejected -Name 'reused PID with a different creation identity fails closed' -Prefix 'DistributedRoleProvenancePidReuse' -Action {
    Assert-V05DistributedRoleActionSet -Actions $pidReuse -RunNonce $nonce -AuthorizingServerInstanceId $serverInstanceId -ProjectManagerPaneId $pm -LeaderPaneId $leader -SubjectPaneId $subject
}

$roleSpoof = Copy-Actions $actions
$roleSpoof[1].actorRole = 'Leader'
Assert-Rejected -Name 'role spoof fails closed' -Prefix 'DistributedRoleProvenanceRoleSpoof' -Action {
    Assert-V05DistributedRoleActionSet -Actions $roleSpoof -RunNonce $nonce -AuthorizingServerInstanceId $serverInstanceId -ProjectManagerPaneId $pm -LeaderPaneId $leader -SubjectPaneId $subject
}

$replay = Copy-Actions $actions
$replay[3].requestCommandId = $replay[1].requestCommandId
Assert-Rejected -Name 'replayed request command identity fails closed' -Prefix 'DistributedRoleProvenanceReplay' -Action {
    Assert-V05DistributedRoleActionSet -Actions $replay -RunNonce $nonce -AuthorizingServerInstanceId $serverInstanceId -ProjectManagerPaneId $pm -LeaderPaneId $leader -SubjectPaneId $subject
}

$wrongNonce = Copy-Actions $actions
$wrongNonce[3].runNonce = 'B' * 64
Assert-Rejected -Name 'cross-run nonce replay fails closed' -Prefix 'DistributedRoleProvenanceReplay' -Action {
    Assert-V05DistributedRoleActionSet -Actions $wrongNonce -RunNonce $nonce -AuthorizingServerInstanceId $serverInstanceId -ProjectManagerPaneId $pm -LeaderPaneId $leader -SubjectPaneId $subject
}

$wrongServer = Copy-Actions $actions
$wrongServer[2].authorizingServerInstanceId = '20000000-0000-0000-0000-000000000099'
Assert-Rejected -Name 'wrong authorizing server instance fails closed' -Prefix 'DistributedRoleProvenanceWrongServer' -Action {
    Assert-V05DistributedRoleActionSet -Actions $wrongServer -RunNonce $nonce -AuthorizingServerInstanceId $serverInstanceId -ProjectManagerPaneId $pm -LeaderPaneId $leader -SubjectPaneId $subject
}

$equalRootStart = Copy-Actions $actions
$equalRootStart[2].paneRootProcessStartedUtc = $equalRootStart[2].clientProcessStartedUtc
Assert-Rejected -Name 'equal pane-root and client creation times fail closed' -Prefix 'DistributedRoleProvenancePidReuse' -Action {
    Assert-V05DistributedRoleActionSet -Actions $equalRootStart -RunNonce $nonce -AuthorizingServerInstanceId $serverInstanceId -ProjectManagerPaneId $pm -LeaderPaneId $leader -SubjectPaneId $subject
}

$sameRootAndClientPid = Copy-Actions $actions
$sameRootAndClientPid[1].paneRootProcessId = $sameRootAndClientPid[1].clientProcessId
$sameRootAndClientPid[1].processAncestry[0].processId = $sameRootAndClientPid[1].clientProcessId
$sameRootAndClientPid[1].processAncestrySha256 = Get-V05CanonicalAncestrySha256 -ProcessAncestry @($sameRootAndClientPid[1].processAncestry)
$sameRootAndClientPid[1].receiptSha256 = Get-V05CanonicalReceiptSha256 -Action $sameRootAndClientPid[1]
Assert-Rejected -Name 'client PID equal to pane-root PID fails closed' -Prefix 'DistributedRoleProvenanceWrongProcess' -Action {
    Assert-V05DistributedRoleActionSet -Actions $sameRootAndClientPid -RunNonce $nonce -AuthorizingServerInstanceId $serverInstanceId -ProjectManagerPaneId $pm -LeaderPaneId $leader -SubjectPaneId $subject
}

$changedReceipt = Copy-Actions $actions
$changedReceipt[1].outcome = 'CHANGED_WITHOUT_REHASH'
Assert-Rejected -Name 'changed receipt payload with unchanged hash fails closed' -Prefix 'DistributedRoleProvenanceInvalid' -Action {
    Assert-V05DistributedRoleActionSet -Actions $changedReceipt -RunNonce $nonce -AuthorizingServerInstanceId $serverInstanceId -ProjectManagerPaneId $pm -LeaderPaneId $leader -SubjectPaneId $subject
}

$changedReceiptLate = Copy-Actions $actions
$changedReceiptLate[1].observedUtc = '2026-08-22T00:00:03.500Z'
Assert-Rejected -Name 'changed valid receipt field with unchanged hash fails closed' -Prefix 'DistributedRoleProvenanceReplay' -Action {
    Assert-V05DistributedRoleActionSet -Actions $changedReceiptLate -RunNonce $nonce -AuthorizingServerInstanceId $serverInstanceId -ProjectManagerPaneId $pm -LeaderPaneId $leader -SubjectPaneId $subject
}

$ancestryHashReuse = Copy-Actions $actions
$ancestryHashReuse[1].processAncestry[0].processStartedUtc = '2026-08-21T23:58:59.000Z'
Assert-Rejected -Name 'changed ancestry chain with reused hash fails closed' -Prefix 'DistributedRoleProvenanceWrongProcess' -Action {
    Assert-V05DistributedRoleActionSet -Actions $ancestryHashReuse -RunNonce $nonce -AuthorizingServerInstanceId $serverInstanceId -ProjectManagerPaneId $pm -LeaderPaneId $leader -SubjectPaneId $subject
}

Assert-Rejected -Name 'all-zero run nonce fails closed' -Prefix 'DistributedRoleProvenanceInvalid' -Action {
    $zeroNonceActions = Copy-Actions $actions
    foreach ($item in $zeroNonceActions) { $item.runNonce = '0' * 64 }
    Assert-V05DistributedRoleActionSet -Actions $zeroNonceActions -RunNonce ('0' * 64) -AuthorizingServerInstanceId $serverInstanceId -ProjectManagerPaneId $pm -LeaderPaneId $leader -SubjectPaneId $subject
}

Assert-Rejected -Name 'empty authorizing server instance fails closed' -Prefix 'DistributedRoleProvenanceInvalid' -Action {
    Assert-V05DistributedRoleActionSet -Actions $actions -RunNonce $nonce -AuthorizingServerInstanceId '00000000-0000-0000-0000-000000000000' -ProjectManagerPaneId $pm -LeaderPaneId $leader -SubjectPaneId $subject
}

$zeroClientPid = Copy-Actions $actions
$zeroClientPid[0].clientProcessId = 0
$zeroClientPid[0].authorizedClientProcessId = 0
Assert-Rejected -Name 'zero client PID fails closed' -Prefix 'DistributedRoleProvenanceWrongProcess' -Action {
    Assert-V05DistributedRoleActionSet -Actions $zeroClientPid -RunNonce $nonce -AuthorizingServerInstanceId $serverInstanceId -ProjectManagerPaneId $pm -LeaderPaneId $leader -SubjectPaneId $subject
}

$zeroRootPid = Copy-Actions $actions
$zeroRootPid[0].paneRootProcessId = 0
Assert-Rejected -Name 'zero pane-root PID fails closed' -Prefix 'DistributedRoleProvenanceWrongProcess' -Action {
    Assert-V05DistributedRoleActionSet -Actions $zeroRootPid -RunNonce $nonce -AuthorizingServerInstanceId $serverInstanceId -ProjectManagerPaneId $pm -LeaderPaneId $leader -SubjectPaneId $subject
}

$zeroAncestryPid = Copy-Actions $actions
$zeroAncestryPid[0].processAncestry[0].processId = 0
Assert-Rejected -Name 'zero ancestry PID fails closed' -Prefix 'DistributedRoleProvenanceWrongProcess' -Action {
    Assert-V05DistributedRoleActionSet -Actions $zeroAncestryPid -RunNonce $nonce -AuthorizingServerInstanceId $serverInstanceId -ProjectManagerPaneId $pm -LeaderPaneId $leader -SubjectPaneId $subject
}

$emptyCommandId = Copy-Actions $actions
$emptyCommandId[1].requestCommandId = ''
Assert-Rejected -Name 'empty request command ID fails closed' -Prefix 'DistributedRoleProvenanceReplay' -Action {
    Assert-V05DistributedRoleActionSet -Actions $emptyCommandId -RunNonce $nonce -AuthorizingServerInstanceId $serverInstanceId -ProjectManagerPaneId $pm -LeaderPaneId $leader -SubjectPaneId $subject
}

$unknownField = Copy-Actions $actions
$unknownField[1] | Add-Member -NotePropertyName unexpected -NotePropertyValue 'forged'
Assert-Rejected -Name 'unknown action field fails closed' -Prefix 'DistributedRoleProvenanceInvalid' -Action {
    Assert-V05DistributedRoleActionSet -Actions $unknownField -RunNonce $nonce -AuthorizingServerInstanceId $serverInstanceId -ProjectManagerPaneId $pm -LeaderPaneId $leader -SubjectPaneId $subject
}

$nonMonotonicObserved = Copy-Actions $actions
$nonMonotonicObserved[2].observedUtc = '2026-08-22T00:00:02.500Z'
Assert-Rejected -Name 'non-monotonic observation time fails closed' -Prefix 'DistributedRoleProvenanceInvalid' -Action {
    Assert-V05DistributedRoleActionSet -Actions $nonMonotonicObserved -RunNonce $nonce -AuthorizingServerInstanceId $serverInstanceId -ProjectManagerPaneId $pm -LeaderPaneId $leader -SubjectPaneId $subject
}

$invalidIntermediateOrder = Copy-Actions $actions
$invalidIntermediateOrder[1].processAncestry = @(
    $invalidIntermediateOrder[1].processAncestry[0],
    [pscustomobject][ordered]@{ processId = 3502; processStartedUtc = '2026-08-22T00:00:03.000Z' },
    $invalidIntermediateOrder[1].processAncestry[1])
$invalidIntermediateOrder[1].processAncestrySha256 = Get-V05CanonicalAncestrySha256 -ProcessAncestry @($invalidIntermediateOrder[1].processAncestry)
$invalidIntermediateOrder[1].receiptSha256 = Get-V05CanonicalReceiptSha256 -Action $invalidIntermediateOrder[1]
Assert-Rejected -Name 'ancestry parent not strictly earlier than child fails closed' -Prefix 'DistributedRoleProvenancePidReuse' -Action {
    Assert-V05DistributedRoleActionSet -Actions $invalidIntermediateOrder -RunNonce $nonce -AuthorizingServerInstanceId $serverInstanceId -ProjectManagerPaneId $pm -LeaderPaneId $leader -SubjectPaneId $subject
}

$repeatedAncestryPid = Copy-Actions $actions
$repeatedAncestryPid[1].processAncestry = @(
    $repeatedAncestryPid[1].processAncestry[0],
    [pscustomobject][ordered]@{ processId = $repeatedAncestryPid[1].paneRootProcessId; processStartedUtc = '2026-08-22T00:00:01.000Z' },
    $repeatedAncestryPid[1].processAncestry[1])
$repeatedAncestryPid[1].processAncestrySha256 = Get-V05CanonicalAncestrySha256 -ProcessAncestry @($repeatedAncestryPid[1].processAncestry)
$repeatedAncestryPid[1].receiptSha256 = Get-V05CanonicalReceiptSha256 -Action $repeatedAncestryPid[1]
Assert-Rejected -Name 'repeated ancestry PID/cycle fails closed' -Prefix 'DistributedRoleProvenanceWrongProcess' -Action {
    Assert-V05DistributedRoleActionSet -Actions $repeatedAncestryPid -RunNonce $nonce -AuthorizingServerInstanceId $serverInstanceId -ProjectManagerPaneId $pm -LeaderPaneId $leader -SubjectPaneId $subject
}

$wrapperSource = Get-Content -LiteralPath $wrapperPath -Raw
$wrapperTokens = $null
$wrapperParseErrors = $null
$wrapperAst = [Management.Automation.Language.Parser]::ParseFile($wrapperPath, [ref]$wrapperTokens, [ref]$wrapperParseErrors)
Assert-Pass -Name 'legacy wrapper unconditional blocker is the first executable statement after param' -Condition (
    $wrapperParseErrors.Count -eq 0 -and $wrapperAst.EndBlock.Statements.Count -gt 0 -and
    $wrapperAst.EndBlock.Statements[0] -is [Management.Automation.Language.ThrowStatementAst])
$blockerIndex = $wrapperSource.IndexOf('DistributedRoleProvenanceRequired:', [StringComparison]::Ordinal)
$helperResolutionIndex = $wrapperSource.IndexOf('$traceOrchestrationPath =', [StringComparison]::Ordinal)
$artifactIndex = $wrapperSource.IndexOf('$repositoryRoot =', [StringComparison]::Ordinal)
Assert-Pass -Name 'legacy wrapper fail-closes before helper resolution, dot-source, repository, build, process, or artifact work' -Condition (
    $blockerIndex -ge 0 -and $helperResolutionIndex -gt $blockerIndex -and $artifactIndex -gt $blockerIndex)
$paneImpersonationPatterns = @(
    '(?im)\$env:HERDR_PANE_ID\s*=',
    '(?im)Set-Item\s+(?:-Path\s+)?["'']?Env:\\?HERDR_PANE_ID',
    '(?im)SetEnvironmentVariable\s*\(\s*["'']HERDR_PANE_ID["'']',
    '(?im)(?:Environment|EnvironmentVariables)\s*\[\s*["'']HERDR_PANE_ID["'']\s*\]\s*=')
Assert-Pass -Name 'legacy wrapper has no direct, Env provider, API, or ProcessStartInfo pane impersonation' -Condition (
    @($paneImpersonationPatterns | Where-Object { $wrapperSource -match $_ }).Count -eq 0)

$typeBefore = ('HerdrOps.Tools.V05BoundedProcessRunner' -as [type])
$probePath = Join-Path ([IO.Path]::GetTempPath()) ('v05-wrapper-no-mutation-' + [Guid]::NewGuid().ToString('N'))
Assert-Rejected -Name 'legacy wrapper invocation refuses Runtime credit before touching runtime inputs' -Prefix 'DistributedRoleProvenanceRequired' -Action {
    & $wrapperPath `
        -ProjectManagerTerminalId $pm `
        -LeaderTerminalId $leader `
        -SubjectTerminalId $subject `
        -EvidencePath $probePath `
        -ExpectedSourceCommit ('0' * 40) `
        -ExpectedSourceTree ('0' * 40)
}
Assert-Pass -Name 'executable invocation does not load helper type or create an evidence path' -Condition (
    $null -eq $typeBefore -and $null -eq ('HerdrOps.Tools.V05BoundedProcessRunner' -as [type]) -and -not (Test-Path -LiteralPath $probePath))

Assert-Rejected -Name 'legacy wrapper dot-source refuses Runtime credit before helper side effects' -Prefix 'DistributedRoleProvenanceRequired' -Action {
    . $wrapperPath `
        -ProjectManagerTerminalId $pm `
        -LeaderTerminalId $leader `
        -SubjectTerminalId $subject `
        -EvidencePath $probePath `
        -ExpectedSourceCommit ('0' * 40) `
        -ExpectedSourceTree ('0' * 40)
}
Assert-Pass -Name 'dot-source invocation does not load helper type or create an evidence path' -Condition (
    $null -eq ('HerdrOps.Tools.V05BoundedProcessRunner' -as [type]) -and -not (Test-Path -LiteralPath $probePath))

function Get-WrapperCallerPreferenceResult {
    param([switch]$DotSource)

    & {
        Set-StrictMode -Off
        $ErrorActionPreference = 'Continue'
        $PSNativeCommandUseErrorActionPreference = $true
        $undefinedBeforeSucceeded = $true
        try { $null = $v05UndefinedBefore } catch { $undefinedBeforeSucceeded = $false }
        $message = ''
        try {
            if ($DotSource) {
                . $wrapperPath -ProjectManagerTerminalId $pm -LeaderTerminalId $leader -SubjectTerminalId $subject -EvidencePath $probePath -ExpectedSourceCommit ('0' * 40) -ExpectedSourceTree ('0' * 40)
            } else {
                & $wrapperPath -ProjectManagerTerminalId $pm -LeaderTerminalId $leader -SubjectTerminalId $subject -EvidencePath $probePath -ExpectedSourceCommit ('0' * 40) -ExpectedSourceTree ('0' * 40)
            }
        } catch { $message = $_.Exception.Message }
        $undefinedAfterSucceeded = $true
        try { $null = $v05UndefinedAfter } catch { $undefinedAfterSucceeded = $false }
        [pscustomobject]@{
            ErrorActionPreference = $ErrorActionPreference
            NativePreference = $PSNativeCommandUseErrorActionPreference
            UndefinedBeforeSucceeded = $undefinedBeforeSucceeded
            UndefinedAfterSucceeded = $undefinedAfterSucceeded
            Message = $message
        }
    }
}

$callPreferences = Get-WrapperCallerPreferenceResult
Assert-Pass -Name 'executable call preserves caller preferences and strict-mode behavior' -Condition (
    $callPreferences.Message -like 'DistributedRoleProvenanceRequired*' -and
    $callPreferences.ErrorActionPreference -ceq 'Continue' -and $callPreferences.NativePreference -eq $true -and
    $callPreferences.UndefinedBeforeSucceeded -and $callPreferences.UndefinedAfterSucceeded)
$dotSourcePreferences = Get-WrapperCallerPreferenceResult -DotSource
Assert-Pass -Name 'dot-source preserves caller preferences and strict-mode behavior' -Condition (
    $dotSourcePreferences.Message -like 'DistributedRoleProvenanceRequired*' -and
    $dotSourcePreferences.ErrorActionPreference -ceq 'Continue' -and $dotSourcePreferences.NativePreference -eq $true -and
    $dotSourcePreferences.UndefinedBeforeSucceeded -and $dotSourcePreferences.UndefinedAfterSucceeded)

if ($passed -ne 32) { throw "Expected 32 distributed role-provenance checks, observed $passed." }
Write-Output 'EvidenceClass: Static plus deterministic Synthetic hostile checks'
Write-Output 'ActualHerdrRuntime: NOT OBSERVED / NOT CLAIMED'
Write-Output 'Release: NOT OBSERVED / NOT CLAIMED'
Write-Output 'v0.5 distributed role-provenance selftest passed: 32/32 checks.'
