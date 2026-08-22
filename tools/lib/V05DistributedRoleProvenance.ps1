Set-StrictMode -Version Latest

function Get-V05DistributedSha256Text {
    param([Parameter(Mandatory)][string]$Text)

    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
        return ([BitConverter]::ToString($algorithm.ComputeHash($bytes))).Replace('-', '').ToUpperInvariant()
    } finally {
        $algorithm.Dispose()
    }
}

function Add-V05CanonicalField {
    param(
        [Parameter(Mandatory)][Text.StringBuilder]$Builder,
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()]$Value)

    $text = if ($null -eq $Value) {
        '<null>'
    } elseif ($Value -is [bool]) {
        if ([bool]$Value) { 'true' } else { 'false' }
    } elseif ($Value -is [IFormattable]) {
        $Value.ToString($null, [Globalization.CultureInfo]::InvariantCulture)
    } else {
        [string]$Value
    }
    [void]$Builder.Append($Name).Append(':').Append($text.Length).Append(':').Append($text).Append("`n")
}

function Get-V05CanonicalAncestrySha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$ProcessAncestry)

    $builder = [Text.StringBuilder]::new()
    Add-V05CanonicalField -Builder $builder -Name 'processAncestry.count' -Value $ProcessAncestry.Count
    for ($index = 0; $index -lt $ProcessAncestry.Count; $index++) {
        $identity = $ProcessAncestry[$index]
        foreach ($name in @('processId', 'processStartedUtc')) {
            Add-V05CanonicalField -Builder $builder -Name "processAncestry[$index].$name" -Value $identity.$name
        }
    }
    return Get-V05DistributedSha256Text -Text $builder.ToString()
}

function Get-V05CanonicalReceiptSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Action)

    $builder = [Text.StringBuilder]::new()
    foreach ($name in @(
            'schemaVersion', 'runNonce', 'sequence', 'action', 'outcome',
            'actorRole', 'actorPaneId', 'requestCommandId', 'clientProcessId',
            'clientProcessStartedUtc', 'observedUtc', 'authorizedPaneId',
            'authorizedClientProcessId', 'authorizedClientProcessStartedUtc',
            'authorizingServerInstanceId', 'paneRootProcessId',
            'paneRootProcessStartedUtc', 'serverAuthorizationObserved')) {
        Add-V05CanonicalField -Builder $builder -Name $name -Value $Action.$name
    }
    $ancestry = @($Action.processAncestry)
    Add-V05CanonicalField -Builder $builder -Name 'processAncestry.count' -Value $ancestry.Count
    for ($index = 0; $index -lt $ancestry.Count; $index++) {
        Add-V05CanonicalField -Builder $builder -Name "processAncestry[$index].processId" -Value $ancestry[$index].processId
        Add-V05CanonicalField -Builder $builder -Name "processAncestry[$index].processStartedUtc" -Value $ancestry[$index].processStartedUtc
    }
    Add-V05CanonicalField -Builder $builder -Name 'processAncestrySha256' -Value $Action.processAncestrySha256
    return Get-V05DistributedSha256Text -Text $builder.ToString()
}

function ConvertFrom-V05DistributedUtc {
    param(
        [Parameter(Mandatory)]
        [string]$Value,

        [Parameter(Mandatory)]
        [string]$FieldName
    )

    $parsed = [DateTimeOffset]::MinValue
    if ($Value -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3,7}Z$' -or
        -not [DateTimeOffset]::TryParse(
            $Value,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind,
            [ref]$parsed) -or
        $parsed.Offset -ne [TimeSpan]::Zero) {
        throw "DistributedRoleProvenanceInvalid: $FieldName must be a strict UTC timestamp."
    }

    return $parsed.ToUniversalTime()
}

function Assert-V05DistributedRoleActionSet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$Actions,

        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9A-Fa-f]{64}$')]
        [string]$RunNonce,

        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$')]
        [string]$AuthorizingServerInstanceId,

        [Parameter(Mandatory)]
        [string]$ProjectManagerPaneId,

        [Parameter(Mandatory)]
        [string]$LeaderPaneId,

        [Parameter(Mandatory)]
        [string]$SubjectPaneId
    )

    if ($Actions.Count -ne 4) {
        throw "DistributedRoleProvenanceInvalid: expected exactly four role actions; found $($Actions.Count)."
    }

    $paneIds = @($ProjectManagerPaneId, $LeaderPaneId, $SubjectPaneId)
    if (@($paneIds | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -ne 0 -or
        @($paneIds | Select-Object -Unique).Count -ne 3) {
        throw 'DistributedRoleProvenanceInvalid: Project Manager, Leader, and Subject pane IDs must be three distinct non-blank values.'
    }

    $expected = @(
        [pscustomobject]@{ Action = 'self-review-denied'; Role = 'Subject'; Pane = $SubjectPaneId; Outcome = 'REJECTED_SELF_REVIEW' },
        [pscustomobject]@{ Action = 'send-to-leader'; Role = 'ProjectManager'; Pane = $ProjectManagerPaneId; Outcome = 'ACCEPTED' },
        [pscustomobject]@{ Action = 'escalate-to-project-manager'; Role = 'Leader'; Pane = $LeaderPaneId; Outcome = 'ACCEPTED' },
        [pscustomobject]@{ Action = 'confirm'; Role = 'ProjectManager'; Pane = $ProjectManagerPaneId; Outcome = 'ACCEPTED' })
    $requiredProperties = @(
        'schemaVersion', 'runNonce', 'sequence', 'action', 'outcome',
        'actorRole', 'actorPaneId', 'requestCommandId', 'clientProcessId',
        'clientProcessStartedUtc', 'observedUtc', 'authorizedPaneId',
        'authorizedClientProcessId', 'authorizedClientProcessStartedUtc',
        'authorizingServerInstanceId', 'paneRootProcessId',
        'paneRootProcessStartedUtc', 'serverAuthorizationObserved',
        'processAncestry', 'processAncestrySha256', 'receiptSha256')
    $commandIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $receiptHashes = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $pidStarts = @{}
    $clientIdentityOwners = @{}
    $paneRootOwners = @{}
    $paneRootByPane = @{}
    $previousObservedUtc = [DateTimeOffset]::MinValue

    if ($RunNonce -match '^0{64}$') {
        throw 'DistributedRoleProvenanceInvalid: run nonce must not be the all-zero sentinel.'
    }
    $serverInstanceGuid = [Guid]::Empty
    if (-not [Guid]::TryParseExact($AuthorizingServerInstanceId, 'D', [ref]$serverInstanceGuid) -or
        $serverInstanceGuid -eq [Guid]::Empty) {
        throw 'DistributedRoleProvenanceInvalid: authorizing server instance must be a non-empty GUID.'
    }

    for ($index = 0; $index -lt $Actions.Count; $index++) {
        $action = $Actions[$index]
        if ($null -eq $action) {
            throw "DistributedRoleProvenanceInvalid: action[$index] is null."
        }

        $actualProperties = @($action.PSObject.Properties.Name)
        foreach ($propertyName in $requiredProperties) {
            if ($actualProperties -notcontains $propertyName) {
                throw "DistributedRoleProvenanceInvalid: action[$index] omits $propertyName."
            }
        }
        if (@($actualProperties).Count -ne $requiredProperties.Count) {
            throw "DistributedRoleProvenanceInvalid: action[$index] contains an unknown or duplicate field."
        }

        $spec = $expected[$index]
        if (($action.schemaVersion -isnot [int] -and $action.schemaVersion -isnot [long]) -or
            [long]$action.schemaVersion -ne 1) {
            throw "DistributedRoleProvenanceInvalid: action[$index].schemaVersion must be integer 1."
        }
        if ([string]$action.runNonce -cne $RunNonce) {
            throw "DistributedRoleProvenanceReplay: action[$index] is bound to the wrong run nonce."
        }
        if (($action.sequence -isnot [int] -and $action.sequence -isnot [long]) -or
            [long]$action.sequence -ne $index) {
            throw "DistributedRoleProvenanceInvalid: action[$index] has the wrong sequence."
        }
        if ([string]$action.action -cne $spec.Action -or
            [string]$action.outcome -cne $spec.Outcome) {
            throw "DistributedRoleProvenanceInvalid: action[$index] has the wrong action or outcome."
        }
        if ([string]$action.actorRole -cne $spec.Role -or
            [string]$action.actorPaneId -cne $spec.Pane) {
            throw "DistributedRoleProvenanceRoleSpoof: action[$index] role/pane does not match the required actor."
        }
        if ([string]$action.authorizedPaneId -cne [string]$action.actorPaneId) {
            throw "DistributedRoleProvenanceWrongPane: action[$index] was not authorized for its claimed pane."
        }
        if ([string]$action.authorizingServerInstanceId -cne $AuthorizingServerInstanceId) {
            throw "DistributedRoleProvenanceWrongServer: action[$index] was authorized by the wrong server instance."
        }
        if ($action.serverAuthorizationObserved -isnot [bool] -or
            -not [bool]$action.serverAuthorizationObserved) {
            throw "DistributedRoleProvenanceUnauthorized: action[$index] lacks a positive server-side ancestry decision."
        }

        if (($action.clientProcessId -isnot [int] -and $action.clientProcessId -isnot [long]) -or
            ($action.authorizedClientProcessId -isnot [int] -and $action.authorizedClientProcessId -isnot [long]) -or
            ($action.paneRootProcessId -isnot [int] -and $action.paneRootProcessId -isnot [long])) {
            throw "DistributedRoleProvenanceWrongProcess: action[$index] process identities must be integers."
        }
        $clientProcessId = [long]$action.clientProcessId
        $authorizedClientProcessId = [long]$action.authorizedClientProcessId
        $paneRootProcessId = [long]$action.paneRootProcessId
        if ($clientProcessId -le 0 -or $clientProcessId -gt [uint32]::MaxValue -or
            $paneRootProcessId -le 0 -or $paneRootProcessId -gt [uint32]::MaxValue -or
            $authorizedClientProcessId -ne $clientProcessId -or
            $clientProcessId -eq $paneRootProcessId) {
            throw "DistributedRoleProvenanceWrongProcess: action[$index] client PID does not match the server-authorized PID."
        }

        $processStartedUtc = ConvertFrom-V05DistributedUtc -Value ([string]$action.clientProcessStartedUtc) -FieldName "action[$index].clientProcessStartedUtc"
        $authorizedStartedUtc = ConvertFrom-V05DistributedUtc -Value ([string]$action.authorizedClientProcessStartedUtc) -FieldName "action[$index].authorizedClientProcessStartedUtc"
        $paneRootStartedUtc = ConvertFrom-V05DistributedUtc -Value ([string]$action.paneRootProcessStartedUtc) -FieldName "action[$index].paneRootProcessStartedUtc"
        $observedUtc = ConvertFrom-V05DistributedUtc -Value ([string]$action.observedUtc) -FieldName "action[$index].observedUtc"
        if ($processStartedUtc -ne $authorizedStartedUtc) {
            throw "DistributedRoleProvenancePidReuse: action[$index] process start does not match the server-authorized start."
        }
        if ($processStartedUtc -gt $observedUtc -or $observedUtc -lt $previousObservedUtc) {
            throw "DistributedRoleProvenanceInvalid: action[$index] has impossible or non-monotonic timestamps."
        }
        if ($paneRootStartedUtc -ge $processStartedUtc) {
            throw "DistributedRoleProvenancePidReuse: action[$index] pane root must predate the connected client process."
        }
        $previousObservedUtc = $observedUtc

        $pidKey = [string]$clientProcessId
        $startKey = $processStartedUtc.ToString('O')
        if ($pidStarts.ContainsKey($pidKey) -and [string]$pidStarts[$pidKey] -cne $startKey) {
            throw "DistributedRoleProvenancePidReuse: PID $pidKey appears with multiple creation identities."
        }
        $pidStarts[$pidKey] = $startKey

        $clientIdentityKey = "$pidKey|$startKey"
        if ($clientIdentityOwners.ContainsKey($clientIdentityKey) -and
            [string]$clientIdentityOwners[$clientIdentityKey] -cne [string]$action.actorPaneId) {
            throw "DistributedRoleProvenanceWrongProcess: one client process identity cannot author actions for multiple panes."
        }
        $clientIdentityOwners[$clientIdentityKey] = [string]$action.actorPaneId

        $paneRootIdentityKey = "$paneRootProcessId|$($paneRootStartedUtc.ToString('O'))"
        if ($paneRootOwners.ContainsKey($paneRootIdentityKey) -and
            [string]$paneRootOwners[$paneRootIdentityKey] -cne [string]$action.actorPaneId) {
            throw "DistributedRoleProvenanceWrongPane: one pane-root identity cannot represent multiple panes."
        }
        if ($paneRootByPane.ContainsKey([string]$action.actorPaneId) -and
            [string]$paneRootByPane[[string]$action.actorPaneId] -cne $paneRootIdentityKey) {
            throw "DistributedRoleProvenancePidReuse: a pane changed root process identity during the action set."
        }
        $paneRootOwners[$paneRootIdentityKey] = [string]$action.actorPaneId
        $paneRootByPane[[string]$action.actorPaneId] = $paneRootIdentityKey

        $commandId = [Guid]::Empty
        if (-not [Guid]::TryParseExact([string]$action.requestCommandId, 'D', [ref]$commandId) -or
            $commandId -eq [Guid]::Empty -or
            -not $commandIds.Add($commandId.ToString('D'))) {
            throw "DistributedRoleProvenanceReplay: action[$index] request command identity is invalid or replayed."
        }
        $ancestry = @($action.processAncestry)
        if ($ancestry.Count -lt 2) {
            throw "DistributedRoleProvenanceWrongProcess: action[$index] process ancestry must bind at least pane-root and client identities."
        }
        $ancestryProcessIds = [Collections.Generic.HashSet[long]]::new()
        $ancestryIdentityTuples = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $previousAncestryStartFileTime = [long]::MinValue
        for ($ancestryIndex = 0; $ancestryIndex -lt $ancestry.Count; $ancestryIndex++) {
            $identity = $ancestry[$ancestryIndex]
            if ($null -eq $identity -or
                @($identity.PSObject.Properties.Name).Count -ne 2 -or
                @($identity.PSObject.Properties.Name) -notcontains 'processId' -or
                @($identity.PSObject.Properties.Name) -notcontains 'processStartedUtc' -or
                ($identity.processId -isnot [int] -and $identity.processId -isnot [long]) -or
                [long]$identity.processId -le 0 -or [long]$identity.processId -gt [uint32]::MaxValue) {
                throw "DistributedRoleProvenanceWrongProcess: action[$index] process ancestry identity[$ancestryIndex] is invalid."
            }
            $ancestryStart = ConvertFrom-V05DistributedUtc -Value ([string]$identity.processStartedUtc) -FieldName "action[$index].processAncestry[$ancestryIndex].processStartedUtc"
            $ancestryPid = [long]$identity.processId
            $ancestryStartFileTime = [long]$ancestryStart.ToFileTime()
            $ancestryTuple = "$ancestryPid|$ancestryStartFileTime"
            if (-not $ancestryProcessIds.Add($ancestryPid) -or
                -not $ancestryIdentityTuples.Add($ancestryTuple)) {
                throw "DistributedRoleProvenanceWrongProcess: action[$index] process ancestry contains a repeated PID or identity cycle."
            }
            if ($ancestryIndex -gt 0 -and $previousAncestryStartFileTime -ge $ancestryStartFileTime) {
                throw "DistributedRoleProvenancePidReuse: action[$index] each ancestry parent must start strictly earlier than its child."
            }
            $previousAncestryStartFileTime = $ancestryStartFileTime
        }
        if ([long]$ancestry[0].processId -ne $paneRootProcessId -or
            [string]$ancestry[0].processStartedUtc -cne [string]$action.paneRootProcessStartedUtc -or
            [long]$ancestry[$ancestry.Count - 1].processId -ne $clientProcessId -or
            [string]$ancestry[$ancestry.Count - 1].processStartedUtc -cne [string]$action.clientProcessStartedUtc) {
            throw "DistributedRoleProvenanceWrongProcess: action[$index] process ancestry endpoints do not bind the pane-root and client identities."
        }

        foreach ($hashField in @('processAncestrySha256', 'receiptSha256')) {
            if ([string]$action.$hashField -notmatch '^[0-9A-Fa-f]{64}$') {
                throw "DistributedRoleProvenanceInvalid: action[$index].$hashField must be SHA-256."
            }
        }
        $expectedAncestryHash = Get-V05CanonicalAncestrySha256 -ProcessAncestry $ancestry
        if ([string]$action.processAncestrySha256 -cne $expectedAncestryHash) {
            throw "DistributedRoleProvenanceWrongProcess: action[$index] ancestry hash does not bind its canonical observed process chain."
        }
        $expectedReceiptHash = Get-V05CanonicalReceiptSha256 -Action $action
        if ([string]$action.receiptSha256 -cne $expectedReceiptHash) {
            throw "DistributedRoleProvenanceReplay: action[$index] receipt hash does not bind its canonical receipt payload."
        }
        if (-not $receiptHashes.Add([string]$action.receiptSha256)) {
            throw "DistributedRoleProvenanceReplay: action[$index] reuses a receipt hash."
        }
    }

    return [pscustomobject]@{
        EvidenceClass = 'Contract plus Synthetic'
        RuntimeCredit = 'NOT GRANTED'
        RunNonce = $RunNonce
        ActionCount = $Actions.Count
        DistinctPaneCount = 3
        Valid = $true
    }
}
