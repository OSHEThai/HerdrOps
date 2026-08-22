Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-V04UtcInstant {
    param([Parameter(Mandatory)][object]$Value, [Parameter(Mandatory)][string]$Name)

    $text = [string]$Value
    $parsed = [DateTimeOffset]::MinValue
    if ([string]::IsNullOrWhiteSpace($text) -or
        -not [DateTimeOffset]::TryParseExact(
            $text,
            'yyyy-MM-ddTHH:mm:ss.fffZ',
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal,
            [ref]$parsed) -or
        $parsed.Offset -ne [TimeSpan]::Zero) {
        throw "$Name must be an exact UTC instant with millisecond precision."
    }
    return $parsed
}

function Test-V04HexSha256 {
    param([AllowNull()][object]$Value)
    return ([string]$Value) -cmatch '\A[0-9A-F]{64}\z'
}

function Test-V04NativeInteger {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return $false }
    return $Value.GetType() -in @(
        [byte], [sbyte], [int16], [uint16], [int32], [uint32], [int64], [uint64])
}

function Test-V04DistributedRoleProvenance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Receipts,
        [Parameter(Mandatory)][object[]]$ExpectedActions,
        [Parameter(Mandatory)][Guid]$RunNonce,
        [Parameter(Mandatory)][string]$ServerInstanceId
    )

    $failures = [Collections.Generic.List[string]]::new()
    $requiredRoles = @('Project Manager', 'Backend Leader', 'Backend Worker', 'Reviewer')
    $requiredActions = @('assignment', 'delegation', 'handoff', 'acknowledgement')
    $expectedProperties = @('ActionId', 'ActionType', 'ActorId', 'Role', 'Sequence', 'SubmissionSha256')
    $receiptProperties = @(
        'ActionId', 'ActionType', 'AncestryBound', 'AuthorizedRole', 'ClientProcessId',
        'ClientProcessStartUtcFileTime', 'ContractVersion', 'DerivedActorId', 'IssuedUtc',
        'ObservedPaneRootIdentity', 'PaneRootProcessId', 'PaneRootProcessStartUtcFileTime',
        'RunNonce', 'Sequence', 'ServerInstanceId', 'SubmissionSha256')
    if ($ExpectedActions.Count -ne 4) {
        $failures.Add('The distributed action plan must contain exactly four actions.')
    }
    $expectedByAction = @{}
    $expectedActors = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    for ($expectedIndex = 0; $expectedIndex -lt $ExpectedActions.Count; $expectedIndex++) {
        $expected = $ExpectedActions[$expectedIndex]
        $actualExpectedProperties = @($expected.PSObject.Properties.Name | Sort-Object)
        if (($actualExpectedProperties -join '|') -cne (($expectedProperties | Sort-Object) -join '|')) {
            $failures.Add('Each expected action must contain the exact action-plan properties.')
            continue
        }
        $actionId = [string]$expected.ActionId
        if ([string]::IsNullOrWhiteSpace($actionId) -or $expectedByAction.ContainsKey($actionId)) {
            $failures.Add('Expected action identifiers must be non-blank and unique.')
            continue
        }
        if ($expectedIndex -ge 4 -or
            -not (Test-V04NativeInteger $expected.Sequence) -or
            [long]$expected.Sequence -ne ($expectedIndex + 1) -or
            [string]$expected.Role -cne $requiredRoles[$expectedIndex] -or
            [string]$expected.ActionType -cne $requiredActions[$expectedIndex]) {
            $failures.Add('The action plan must be exact ordered PM assignment, Leader delegation, Worker handoff, Reviewer acknowledgement with sequences 1 through 4.')
        }
        if ([string]::IsNullOrWhiteSpace([string]$expected.ActorId) -or
            -not $expectedActors.Add([string]$expected.ActorId)) {
            $failures.Add('The action plan must bind four distinct non-blank actor IDs.')
        }
        $expectedByAction[$actionId] = $expected
    }

    if ($Receipts.Count -ne 4) {
        $failures.Add('Exactly four server receipts are required.')
    }
    $seenActions = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $seenSequences = [Collections.Generic.HashSet[long]]::new()
    $seenActors = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $seenPaneRoots = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $seenClientIdentities = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $seenClientPids = [Collections.Generic.HashSet[long]]::new()
    for ($receiptIndex = 0; $receiptIndex -lt $Receipts.Count; $receiptIndex++) {
        $receipt = $Receipts[$receiptIndex]
        try {
            $actualReceiptProperties = @($receipt.PSObject.Properties.Name | Sort-Object)
            if (($actualReceiptProperties -join '|') -cne (($receiptProperties | Sort-Object) -join '|')) {
                throw 'receipt properties do not match the exact contract'
            }
            if (-not (Test-V04NativeInteger $receipt.ContractVersion) -or [int64]$receipt.ContractVersion -ne 1) {
                throw 'contract version must be native integer 1'
            }
            if ($RunNonce -eq [Guid]::Empty -or [Guid]$receipt.RunNonce -eq [Guid]::Empty) {
                throw 'run nonce must not be empty'
            }
            if ([Guid]$receipt.RunNonce -ne $RunNonce) { throw 'cross-run nonce mismatch' }
            if ([string]::IsNullOrWhiteSpace($ServerInstanceId) -or
                $ServerInstanceId -cnotmatch '\Acore-[0-9a-f]{32}\z' -or
                [string]$receipt.ServerInstanceId -cne $ServerInstanceId) {
                throw 'server instance must match exact core- plus 32 lowercase hex format'
            }
            if ($receipt.AncestryBound.GetType() -ne [bool] -or $receipt.AncestryBound -ne $true) {
                throw 'AncestryBound must be native boolean true'
            }

            $actionId = [string]$receipt.ActionId
            if (-not $expectedByAction.ContainsKey($actionId)) { throw 'unexpected action identifier' }
            if (-not $seenActions.Add($actionId)) { throw 'replayed action identifier' }

            if (-not (Test-V04NativeInteger $receipt.Sequence)) { throw 'sequence must be a native integer' }
            $sequence = [long]$receipt.Sequence
            if ($sequence -lt 1 -or -not $seenSequences.Add($sequence)) { throw 'invalid or replayed sequence' }
            $expected = $expectedByAction[$actionId]
            if ($receiptIndex -ge 4 -or $sequence -ne ($receiptIndex + 1)) {
                throw 'receipt sequence is not exact and monotonic'
            }
            if ($sequence -ne [long]$expected.Sequence) { throw 'action sequence mismatch' }
            if ([string]$receipt.ActionType -cne $requiredActions[$receiptIndex] -or
                [string]$receipt.ActionType -cne [string]$expected.ActionType) {
                throw 'unknown or wrong-order client action'
            }
            if (-not $seenActors.Add([string]$receipt.DerivedActorId)) {
                throw 'server receipts must contain four distinct actor IDs'
            }
            if ([string]$receipt.DerivedActorId -cne [string]$expected.ActorId) { throw 'wrong-pane actor identity' }
            if ([string]$receipt.AuthorizedRole -cne $requiredRoles[$receiptIndex] -or
                [string]$receipt.AuthorizedRole -cne [string]$expected.Role) {
                throw 'unknown or server-authorized role mismatch'
            }
            if ([string]$receipt.SubmissionSha256 -cne [string]$expected.SubmissionSha256 -or
                -not (Test-V04HexSha256 $receipt.SubmissionSha256)) { throw 'submission hash mismatch' }

            if (-not (Test-V04NativeInteger $receipt.ClientProcessId) -or
                -not (Test-V04NativeInteger $receipt.PaneRootProcessId) -or
                -not (Test-V04NativeInteger $receipt.ClientProcessStartUtcFileTime) -or
                -not (Test-V04NativeInteger $receipt.PaneRootProcessStartUtcFileTime)) {
                throw 'process PID/start fields must be native integers'
            }
            $clientPid = [long]$receipt.ClientProcessId
            $paneRootPid = [long]$receipt.PaneRootProcessId
            if ($clientPid -lt 1 -or $paneRootPid -lt 1) { throw 'process identifiers must be positive' }
            if ($clientPid -eq $paneRootPid) {
                throw 'client PID must differ from its pane-root PID regardless of process start identity'
            }
            $clientStart = [long]$receipt.ClientProcessStartUtcFileTime
            $rootStart = [long]$receipt.PaneRootProcessStartUtcFileTime
            if ($clientStart -lt 1 -or $rootStart -lt 1) { throw 'process start FILETIMEs must be positive' }
            $clientIdentity = "$clientPid@$clientStart"
            if ($clientIdentity -ceq [string]$receipt.ObservedPaneRootIdentity) {
                throw 'client PID/start identity must differ from its pane-root identity'
            }
            if ($rootStart -ge $clientStart) { throw 'pane root must start strictly before client process' }
            if ([string]$receipt.ObservedPaneRootIdentity -cne "$paneRootPid@$rootStart") {
                throw 'pane root PID/start identity mismatch'
            }
            if (-not $seenPaneRoots.Add([string]$receipt.ObservedPaneRootIdentity)) {
                throw 'server receipts must contain four distinct pane-root PID/start identities'
            }
            if (-not $seenClientIdentities.Add($clientIdentity)) {
                throw 'server receipts must contain four distinct client PID/start identities'
            }
            if (-not $seenClientPids.Add($clientPid)) {
                throw 'a client PID cannot be reused across pane roots'
            }
            $issued = ConvertTo-V04UtcInstant $receipt.IssuedUtc 'IssuedUtc'
            if ($issued.UtcDateTime.ToFileTimeUtc() -lt $clientStart) { throw 'receipt predates client process' }
        }
        catch {
            $failures.Add("Receipt rejected: $($_.Exception.Message)")
        }
    }

    foreach ($actionId in $expectedByAction.Keys) {
        if (-not $seenActions.Contains([string]$actionId)) {
            $failures.Add("Missing server receipt for action '$actionId'.")
        }
    }

    [pscustomobject]@{
        Passed = $failures.Count -eq 0
        EvidenceClass = 'Contract+Synthetic'
        RuntimeObserved = $false
        AcceptedReceiptCount = if ($failures.Count -eq 0) { $Receipts.Count } else { 0 }
        Failures = @($failures)
    }
}
