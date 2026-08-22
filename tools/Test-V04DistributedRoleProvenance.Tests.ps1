[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\V04DistributedRoleProvenancePolicy.ps1')

$harnessPath = Join-Path $PSScriptRoot 'Invoke-V04LifecycleRuntimeAcceptance.ps1'
$runtimeHarness = Get-Content -LiteralPath $harnessPath -Raw
$guardOffset = $runtimeHarness.IndexOf('NO_RUNTIME_CREDIT', [StringComparison]::Ordinal)
if ($guardOffset -lt 0) { throw 'The legacy runtime harness has no NO_RUNTIME_CREDIT guard.' }
foreach ($dangerousToken in @('$repositoryRoot =', 'Invoke-Build.ps1', 'New-Item -ItemType Directory', 'Start-Process')) {
    $offset = $runtimeHarness.IndexOf($dangerousToken, [StringComparison]::Ordinal)
    if ($offset -lt 0 -or $offset -lt $guardOffset) {
        throw "Potential side effect '$dangerousToken' is not positioned after the fail-closed guard."
    }
}

$probeRoot = Join-Path ([IO.Path]::GetTempPath()) "herdrops-v04-guard-$([Guid]::NewGuid().ToString('N'))"
[void][IO.Directory]::CreateDirectory($probeRoot)
$fakeHerdr = Join-Path $probeRoot 'herdr.exe'
$fakeEvidence = Join-Path $probeRoot 'evidence.txt'
[IO.File]::WriteAllText($fakeHerdr, 'not executable')
[IO.File]::WriteAllText($fakeEvidence, 'synthetic guard probe')
$savedHerdrEnv = $env:HERDR_ENV
try {
    $env:HERDR_ENV = '1'
    $parameters = @{
        ProjectManagerTerminalId='pane-pm'; LeaderTerminalId='pane-leader'
        WorkerTerminalId='pane-worker'; ReviewerTerminalId='pane-reviewer'
        EvidencePath=$fakeEvidence; HerdrExecutable=$fakeHerdr; SocketPath='guard-probe-socket'
    }
    foreach ($invocationKind in @('call', 'dot-source')) {
        $caught = $null
        try {
            if ($invocationKind -eq 'call') { & $harnessPath @parameters }
            else { . $harnessPath @parameters }
        } catch { $caught = $_ }
        if ($null -eq $caught -or $caught.Exception.Message.IndexOf('NO_RUNTIME_CREDIT', [StringComparison]::Ordinal) -lt 0) {
            throw "Harness $invocationKind invocation did not fail with NO_RUNTIME_CREDIT."
        }
    }
    if (@(Get-ChildItem -LiteralPath $probeRoot).Count -ne 2) {
        throw 'The harness guard probe created unexpected files before failing closed.'
    }
} finally {
    $env:HERDR_ENV = $savedHerdrEnv
    $resolvedProbe = [IO.Path]::GetFullPath($probeRoot)
    $resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $parent = [IO.Directory]::GetParent($resolvedProbe)
    $probeAttributes = if ([IO.Directory]::Exists($resolvedProbe)) { [IO.File]::GetAttributes($resolvedProbe) } else { $null }
    if ($null -ne $parent -and
        $parent.FullName.TrimEnd('\') -ceq $resolvedTemp.TrimEnd('\') -and
        $null -ne $probeAttributes -and
        ($probeAttributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
        foreach ($knownFile in @($fakeHerdr, $fakeEvidence)) {
            if ([IO.File]::Exists($knownFile)) {
                $knownParent = [IO.Directory]::GetParent([IO.Path]::GetFullPath($knownFile))
                $knownAttributes = [IO.File]::GetAttributes($knownFile)
                if ($null -eq $knownParent -or
                    $knownParent.FullName -cne $resolvedProbe -or
                    ($knownAttributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw 'Guard cleanup refused a non-direct or reparse-point known file.'
                }
                [IO.File]::Delete($knownFile)
            }
        }
        [IO.Directory]::Delete($resolvedProbe, $false)
    }
}
if ([IO.Directory]::Exists($probeRoot)) {
    throw 'Guard cleanup did not remove the exact probe directory.'
}
Write-Output 'PASS: call and dot-source execution fail before build, artifact, directory, or process operations'

$run = [Guid]'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
$server = 'core-0123456789abcdef0123456789abcdef'
$actions = @(
    [pscustomobject]@{ ActionId='10000000-0000-0000-0000-000000000001'; ActionType='assignment'; Sequence=1; ActorId='pane-pm'; Role='Project Manager'; SubmissionSha256=('A' * 64) },
    [pscustomobject]@{ ActionId='10000000-0000-0000-0000-000000000002'; ActionType='delegation'; Sequence=2; ActorId='pane-leader'; Role='Backend Leader'; SubmissionSha256=('B' * 64) },
    [pscustomobject]@{ ActionId='10000000-0000-0000-0000-000000000003'; ActionType='handoff'; Sequence=3; ActorId='pane-worker'; Role='Backend Worker'; SubmissionSha256=('C' * 64) },
    [pscustomobject]@{ ActionId='10000000-0000-0000-0000-000000000004'; ActionType='acknowledgement'; Sequence=4; ActorId='pane-reviewer'; Role='Reviewer'; SubmissionSha256=('D' * 64) }
)

function New-Receipt([object]$Expected, [long]$ClientPid, [long]$RootPid, [int]$Offset) {
    $rootStart = ([DateTimeOffset]'2026-08-22T01:00:00Z').AddSeconds($Offset)
    $clientStart = $rootStart.AddSeconds(1)
    $issued = $clientStart.AddSeconds(1)
    $format = 'yyyy-MM-ddTHH:mm:ss.fffZ'
    $culture = [Globalization.CultureInfo]::InvariantCulture
    $rootFileTime = [long]$rootStart.UtcDateTime.ToFileTimeUtc()
    $clientFileTime = [long]$clientStart.UtcDateTime.ToFileTimeUtc()
    [pscustomobject]@{
        ContractVersion=1; RunNonce=$run.ToString('D'); ServerInstanceId=$server
        ActionId=$Expected.ActionId; ActionType=$Expected.ActionType; Sequence=$Expected.Sequence
        DerivedActorId=$Expected.ActorId; AuthorizedRole=$Expected.Role
        SubmissionSha256=$Expected.SubmissionSha256; AncestryBound=$true
        ClientProcessId=$ClientPid; ClientProcessStartUtcFileTime=$clientFileTime
        PaneRootProcessId=$RootPid; PaneRootProcessStartUtcFileTime=$rootFileTime
        ObservedPaneRootIdentity="$RootPid@$rootFileTime"; IssuedUtc=$issued.ToString($format, $culture)
    }
}

function Copy-Receipts([object[]]$Source) { @($Source | ForEach-Object { $_.PSObject.Copy() }) }
function Assert-Rejected([string]$Name, [object[]]$Receipts, [string]$Fragment, [object[]]$Plan=$actions) {
    $result = Test-V04DistributedRoleProvenance -Receipts $Receipts -ExpectedActions $Plan -RunNonce $run -ServerInstanceId $server
    if ($result.Passed -or (($result.Failures -join ' | ').IndexOf($Fragment, [StringComparison]::OrdinalIgnoreCase) -lt 0)) {
        throw "$Name did not fail closed as expected. Failures=$($result.Failures -join ' | ')"
    }
    Write-Output "PASS: $Name"
}

$valid = @(
    New-Receipt $actions[0] 41001 40001 0
    New-Receipt $actions[1] 41002 40002 10
    New-Receipt $actions[2] 41003 40003 20
    New-Receipt $actions[3] 41004 40004 30)
$positive = Test-V04DistributedRoleProvenance -Receipts $valid -ExpectedActions $actions -RunNonce $run -ServerInstanceId $server
if (-not $positive.Passed -or $positive.RuntimeObserved -or $positive.AcceptedReceiptCount -ne 4) {
    throw "Valid synthetic receipts failed: $($positive.Failures -join ' | ')"
}
Write-Output 'PASS: exact four-role ordered receipts satisfy Contract+Synthetic policy without Runtime credit'

$wrongPane = Copy-Receipts $valid; $wrongPane[1].DerivedActorId = 'pane-other'
Assert-Rejected 'wrong-pane action' $wrongPane 'wrong-pane actor identity'
$roleSpoof = Copy-Receipts $valid; $roleSpoof[1].AuthorizedRole = 'Project Manager'
Assert-Rejected 'role spoof' $roleSpoof 'role mismatch'
$unknownRole = Copy-Receipts $valid; $unknownRole[1].AuthorizedRole = 'Unknown Role'
Assert-Rejected 'unknown client role' $unknownRole 'role mismatch'
$unknownAction = Copy-Receipts $valid; $unknownAction[1].ActionType = 'approve-everything'
Assert-Rejected 'unknown client action' $unknownAction 'client action'
$pidReuse = Copy-Receipts $valid; $pidReuse[0].PaneRootProcessStartUtcFileTime = [long]1
Assert-Rejected 'PID reuse/start mismatch' $pidReuse 'PID/start identity mismatch'
$equalStarts = Copy-Receipts $valid; $equalStarts[0].PaneRootProcessStartUtcFileTime = $equalStarts[0].ClientProcessStartUtcFileTime; $equalStarts[0].ObservedPaneRootIdentity = "$($equalStarts[0].PaneRootProcessId)@$($equalStarts[0].ClientProcessStartUtcFileTime)"
Assert-Rejected 'equal pane-root/client starts' $equalStarts 'strictly before'
$crossRun = Copy-Receipts $valid; $crossRun[0].RunNonce = [Guid]::NewGuid().ToString('D')
Assert-Rejected 'cross-run receipt' $crossRun 'cross-run nonce mismatch'
$replay = @($valid[0], $valid[0], $valid[2], $valid[3])
Assert-Rejected 'replayed action receipt' $replay 'replayed action identifier'
$reversed = @($valid[1], $valid[0], $valid[2], $valid[3])
Assert-Rejected 'reversed receipt order' $reversed 'monotonic'
$short = @($valid[0], $valid[1])
Assert-Rejected 'two-receipt corpus' $short 'Exactly four server receipts'
$duplicateActors = Copy-Receipts $valid; $duplicateActors[1].DerivedActorId = $duplicateActors[0].DerivedActorId
Assert-Rejected 'duplicate actors' $duplicateActors 'distinct actor IDs'
$duplicateRoots = Copy-Receipts $valid
$duplicateRoots[1].PaneRootProcessId = $duplicateRoots[0].PaneRootProcessId
$duplicateRoots[1].PaneRootProcessStartUtcFileTime = $duplicateRoots[0].PaneRootProcessStartUtcFileTime
$duplicateRoots[1].ObservedPaneRootIdentity = $duplicateRoots[0].ObservedPaneRootIdentity
Assert-Rejected 'duplicate pane-root identities' $duplicateRoots 'distinct pane-root PID/start identities'
$extraProperty = Copy-Receipts $valid; $extraProperty[0] | Add-Member -NotePropertyName ClaimedRole -NotePropertyValue 'Project Manager'
Assert-Rejected 'extra receipt property' $extraProperty 'exact contract'
$missingProperty = Copy-Receipts $valid; $missingProperty[0].PSObject.Properties.Remove('AuthorizedRole')
Assert-Rejected 'missing receipt property' $missingProperty 'exact contract'
$duplicateClientIdentity = Copy-Receipts $valid
$duplicateClientIdentity[1].ClientProcessId = $duplicateClientIdentity[0].ClientProcessId
$duplicateClientIdentity[1].ClientProcessStartUtcFileTime = $duplicateClientIdentity[0].ClientProcessStartUtcFileTime
$duplicateClientIdentity[1].PaneRootProcessStartUtcFileTime = [long]$duplicateClientIdentity[0].ClientProcessStartUtcFileTime - 20000000L
$duplicateClientIdentity[1].ObservedPaneRootIdentity = "$($duplicateClientIdentity[1].PaneRootProcessId)@$($duplicateClientIdentity[1].PaneRootProcessStartUtcFileTime)"
Assert-Rejected 'duplicate client PID/start identities' $duplicateClientIdentity 'distinct client PID/start identities'
$reusedClientPid = Copy-Receipts $valid; $reusedClientPid[1].ClientProcessId = $reusedClientPid[0].ClientProcessId
Assert-Rejected 'same client PID reused across roots' $reusedClientPid 'client PID cannot be reused'
$clientEqualsRoot = Copy-Receipts $valid
$clientEqualsRoot[0].ClientProcessId = $clientEqualsRoot[0].PaneRootProcessId
$clientEqualsRoot[0].ClientProcessStartUtcFileTime = $clientEqualsRoot[0].PaneRootProcessStartUtcFileTime
Assert-Rejected 'client identity equals pane-root identity' $clientEqualsRoot 'client PID must differ'
$samePidDifferentStart = Copy-Receipts $valid
$samePidDifferentStart[0].ClientProcessId = $samePidDifferentStart[0].PaneRootProcessId
Assert-Rejected 'client and pane-root share PID with different starts' $samePidDifferentStart 'regardless of process start identity'
$emptyReceiptNonce = Copy-Receipts $valid; $emptyReceiptNonce[0].RunNonce = [Guid]::Empty.ToString('D')
Assert-Rejected 'empty receipt run nonce' $emptyReceiptNonce 'must not be empty'
$emptyRunResult = Test-V04DistributedRoleProvenance -Receipts $valid -ExpectedActions $actions -RunNonce ([Guid]::Empty) -ServerInstanceId $server
if ($emptyRunResult.Passed -or (($emptyRunResult.Failures -join ' | ').IndexOf('must not be empty', [StringComparison]::OrdinalIgnoreCase) -lt 0)) {
    throw 'Empty expected run nonce did not fail closed.'
}
Write-Output 'PASS: empty expected run nonce'
$badServerResult = Test-V04DistributedRoleProvenance -Receipts $valid -ExpectedActions $actions -RunNonce $run -ServerInstanceId 'CORE INSTANCE'
if ($badServerResult.Passed -or (($badServerResult.Failures -join ' | ').IndexOf('exact core-', [StringComparison]::OrdinalIgnoreCase) -lt 0)) {
    throw 'Malformed server instance did not fail closed.'
}
Write-Output 'PASS: malformed/noncanonical server instance'
$stringBool = Copy-Receipts $valid; $stringBool[0].AncestryBound = 'true'
Assert-Rejected 'string ancestry boolean' $stringBool 'native boolean true'
foreach ($numericField in @(
    'ContractVersion', 'Sequence', 'ClientProcessId', 'ClientProcessStartUtcFileTime',
    'PaneRootProcessId', 'PaneRootProcessStartUtcFileTime')) {
    $numericString = Copy-Receipts $valid
    $numericString[0].$numericField = [string]$numericString[0].$numericField
    Assert-Rejected "numeric string $numericField" $numericString 'native integer'
}

Write-Output 'EvidenceClass: Contract+Synthetic'
Write-Output 'RuntimeObserved: false'
