#requires -Version 5.1

Set-StrictMode -Version Latest

# Static/Contract/Synthetic preparation only. This library independently re-derives and
# cross-checks the App-produced SemanticStateCaptures evidence (Issue #9, #10) against
# values the composite v0.2 runtime-acceptance gate has already established from Core's
# exact-Herdr trace and the on-disk, hash-verified capture files. It never accepts the
# App report's own self-claimed values as proof by itself.
#
# Known limitation: SourceStateSha256, SemanticProjectionSha256 and CaptureStateSha256
# are produced in HerdrOps.App by System.Text.Json compact serialization of nested C#
# records (RuntimeEvidenceRunner.ComputeSemanticSourceStateSha256 /
# ComputeSemanticProjectionSha256 / ComputeSemanticCaptureSha256), not this repo's usual
# RFC 8785 canonical-JSON or pipe-delimited canonical-payload convention. Bit-exact
# reproduction of .NET's System.Text.Json byte output in PowerShell is impractical and
# would risk false fail-closed rejections of legitimate reports on harmless formatting
# differences. For those three fields this library therefore validates format (native
# uppercase SHA-256 hex), non-degenerate content, and — where the underlying content is
# provably distinct across the three ordinals (Sequence for SourceStateSha256, per-capture
# bound-capture file hashes for CaptureStateSha256) — pairwise distinctness. Every other
# semantic field (ordinal/phase/event-binding, sequence, source-state hash, connection
# state, bound-capture cross-reference, identity format/cross-reference, projection
# arithmetic, bilingual parity, timestamp ordering) is independently recomputed and
# exactly cross-checked, not merely presence-checked.

function Test-V02SemanticSha256 {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][AllowNull()][string]$Value)
    return ($null -ne $Value) -and ($Value -cmatch '^[0-9A-F]{64}$')
}

function Get-V02SemanticNativeUtc {
    param([Parameter(Mandatory = $true)][string]$Context, [Parameter(Mandatory = $true)]$Value)

    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        throw "$Context is not a native UTC timestamp string."
    }
    $parsed = [DateTimeOffset]::MinValue
    $ok = [DateTimeOffset]::TryParse(
        [string]$Value,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::None,
        [ref]$parsed)
    if (-not $ok -or $parsed -eq [DateTimeOffset]::MinValue -or $parsed.Offset -ne [TimeSpan]::Zero) {
        throw "$Context is not a native offset-zero UTC timestamp: $Value"
    }
    return $parsed
}

function Assert-V02SemanticSourceStateValid {
    param(
        [Parameter(Mandatory = $true)]$SourceState,
        [Parameter(Mandatory = $true)][long]$ExpectedSequence,
        [Parameter(Mandatory = $true)][string]$Context
    )

    if ($null -eq $SourceState) { throw "$Context omitted SourceState." }
    foreach ($field in @('ConnectionEpoch','Sequence','WorkspaceIdentitiesSha256','TabIdentitiesSha256','Panes','Agents','SelectedAgentIdentitySha256')) {
        if ($null -eq $SourceState.PSObject.Properties[$field]) { throw "$Context SourceState omitted '$field'." }
    }
    if ([long]$SourceState.Sequence -ne $ExpectedSequence) {
        throw "$Context SourceState sequence does not match the independently-bound phase sequence."
    }
    if ([long]$SourceState.Sequence -le 0 -or [long]$SourceState.ConnectionEpoch -le 0) {
        throw "$Context SourceState sequence or connection epoch is not positive."
    }

    $workspaces = @($SourceState.WorkspaceIdentitiesSha256 | ForEach-Object { [string]$_ })
    $tabs = @($SourceState.TabIdentitiesSha256 | ForEach-Object { [string]$_ })
    $panes = @($SourceState.Panes)
    $agents = @($SourceState.Agents)

    foreach ($value in $workspaces) {
        if (-not (Test-V02SemanticSha256 $value)) { throw "$Context leaked a non-hashed workspace identity." }
    }
    foreach ($value in $tabs) {
        if (-not (Test-V02SemanticSha256 $value)) { throw "$Context leaked a non-hashed tab identity." }
    }
    if (@($workspaces | Select-Object -Unique).Count -ne $workspaces.Count) { throw "$Context workspace identities are not unique." }
    if (@($tabs | Select-Object -Unique).Count -ne $tabs.Count) { throw "$Context tab identities are not unique." }

    foreach ($pane in $panes) {
        if (-not (Test-V02SemanticSha256 ([string]$pane.PaneIdentitySha256)) -or
            -not (Test-V02SemanticSha256 ([string]$pane.TerminalIdentitySha256))) {
            throw "$Context leaked a non-hashed pane or terminal identity."
        }
    }
    $paneIds = @($panes | ForEach-Object { [string]$_.PaneIdentitySha256 })
    if (@($paneIds | Select-Object -Unique).Count -ne $paneIds.Count) { throw "$Context pane identities are not unique." }

    $agentIds = @($agents | ForEach-Object { [string]$_.AgentIdentitySha256 })
    if (@($agentIds | Select-Object -Unique).Count -ne $agentIds.Count) { throw "$Context agent identities are not unique." }

    foreach ($agent in $agents) {
        foreach ($field in @('AgentIdentitySha256','WorkspaceIdentitySha256','TabIdentitySha256','PaneIdentitySha256')) {
            if (-not (Test-V02SemanticSha256 ([string]$agent.$field))) {
                throw "$Context leaked a non-hashed agent-projection identity ('$field')."
            }
        }
        if ([string]::IsNullOrWhiteSpace([string]$agent.Status)) { throw "$Context agent omitted Status." }
        if ($workspaces -notcontains [string]$agent.WorkspaceIdentitySha256) {
            throw "$Context agent references a workspace identity absent from the bound workspace set."
        }
        if ($tabs -notcontains [string]$agent.TabIdentitySha256) {
            throw "$Context agent references a tab identity absent from the bound tab set."
        }
        if ($paneIds -notcontains [string]$agent.PaneIdentitySha256) {
            throw "$Context agent references a pane identity absent from the bound pane set."
        }
    }

    $overviewOrders = @($agents | ForEach-Object { [int]$_.OverviewOrder } | Sort-Object)
    $expectedOrders = @(0..([Math]::Max($agents.Count - 1, -1)))
    if ($agents.Count -gt 0) {
        $ordersMatch = ($overviewOrders.Count -eq $expectedOrders.Count)
        if ($ordersMatch) {
            for ($i = 0; $i -lt $overviewOrders.Count; $i++) {
                if ([int]$overviewOrders[$i] -ne [int]$expectedOrders[$i]) { $ordersMatch = $false; break }
            }
        }
        if (-not $ordersMatch) { throw "$Context agent OverviewOrder is not a dense 0-based ordering." }
    }

    $selected = [string]$SourceState.SelectedAgentIdentitySha256
    if (-not [string]::IsNullOrWhiteSpace($selected)) {
        if (-not (Test-V02SemanticSha256 $selected)) { throw "$Context leaked a non-hashed selected-agent identity." }
        if ($agentIds -notcontains $selected) { throw "$Context selected-agent identity is absent from the bound agent set." }
    }
}

function Assert-V02SemanticProjectionsMatchSource {
    param(
        [Parameter(Mandatory = $true)]$SourceState,
        [Parameter(Mandatory = $true)]$Overview,
        [Parameter(Mandatory = $true)]$LiveOrganization,
        [Parameter(Mandatory = $true)]$AgentDetail,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $agents = @($SourceState.Agents)
    $panes = @($SourceState.Panes)
    $workspaces = @($SourceState.WorkspaceIdentitiesSha256)
    $tabs = @($SourceState.TabIdentitiesSha256)
    $assignedTerminalIds = @($agents | ForEach-Object { [string]$_.AgentIdentitySha256 })
    $unassignedPaneCount = @($panes | Where-Object { $assignedTerminalIds -notcontains [string]$_.TerminalIdentitySha256 }).Count
    $unknownAgentCount = @($agents | Where-Object { [string]$_.Status -ceq 'Unknown' }).Count

    if ([int]$Overview.TotalAgents -ne $agents.Count) { throw "$Context Overview.TotalAgents does not match SourceState agent count." }
    if ([int]$LiveOrganization.WorkspaceCount -ne $workspaces.Count -or
        [int]$LiveOrganization.TabCount -ne $tabs.Count -or
        [int]$LiveOrganization.PaneCount -ne $panes.Count -or
        [int]$LiveOrganization.AgentCount -ne $agents.Count -or
        [int]$LiveOrganization.UnassignedPaneCount -ne $unassignedPaneCount -or
        [int]$LiveOrganization.UnknownAgentCount -ne $unknownAgentCount) {
        throw "$Context LiveOrganization counts do not match a fresh recomputation from SourceState."
    }
    $expectedNodeCount = $workspaces.Count + $tabs.Count + $agents.Count + $unassignedPaneCount
    if ([int]$LiveOrganization.ProjectedNodeCount -ne $expectedNodeCount) {
        throw "$Context LiveOrganization.ProjectedNodeCount is not workspaces+tabs+agents+unassignedPanes."
    }
    if ([string]$LiveOrganization.SelectedAgentIdentitySha256 -cne [string]$SourceState.SelectedAgentIdentitySha256) {
        throw "$Context LiveOrganization selected-agent identity does not match SourceState."
    }

    $statusGroups = $agents | Group-Object -Property { [string]$_.Status }
    $expectedStatusCounts = @{}
    foreach ($group in $statusGroups) { $expectedStatusCounts[[string]$group.Name] = $group.Count }
    $actualStatusCounts = @{}
    foreach ($entry in @($Overview.StatusCounts)) { $actualStatusCounts[[string]$entry.Status] = [int]$entry.Count }
    if ($expectedStatusCounts.Keys.Count -ne $actualStatusCounts.Keys.Count) {
        throw "$Context Overview.StatusCounts does not match a fresh recomputation from SourceState."
    }
    foreach ($key in $expectedStatusCounts.Keys) {
        if (-not $actualStatusCounts.ContainsKey($key) -or $actualStatusCounts[$key] -ne $expectedStatusCounts[$key]) {
            throw "$Context Overview.StatusCounts entry '$key' does not match a fresh recomputation from SourceState."
        }
    }

    $workspaceGroups = $agents | Group-Object -Property { [string]$_.WorkspaceIdentitySha256 }
    $expectedWorkspaceCounts = @{}
    foreach ($group in $workspaceGroups) { $expectedWorkspaceCounts[[string]$group.Name] = $group.Count }
    $actualWorkspaceCounts = @{}
    foreach ($entry in @($Overview.WorkspaceAgentCounts)) { $actualWorkspaceCounts[[string]$entry.WorkspaceIdentitySha256] = [int]$entry.AgentCount }
    if ($expectedWorkspaceCounts.Keys.Count -ne $actualWorkspaceCounts.Keys.Count) {
        throw "$Context Overview.WorkspaceAgentCounts does not match a fresh recomputation from SourceState."
    }
    foreach ($key in $expectedWorkspaceCounts.Keys) {
        if (-not $actualWorkspaceCounts.ContainsKey($key) -or $actualWorkspaceCounts[$key] -ne $expectedWorkspaceCounts[$key]) {
            throw "$Context Overview.WorkspaceAgentCounts entry does not match a fresh recomputation from SourceState."
        }
    }

    $expectedVisible = @($agents | Sort-Object -Property { [int]$_.OverviewOrder } | Select-Object -First 5)
    $actualVisible = @($Overview.VisibleTopAgents)
    if ($actualVisible.Count -ne $expectedVisible.Count) { throw "$Context Overview.VisibleTopAgents count does not match a fresh recomputation from SourceState." }
    for ($i = 0; $i -lt $actualVisible.Count; $i++) {
        $expectedAgent = $expectedVisible[$i]
        $actualAgent = $actualVisible[$i]
        if ([string]$actualAgent.AgentIdentitySha256 -cne [string]$expectedAgent.AgentIdentitySha256 -or
            [string]$actualAgent.WorkspaceIdentitySha256 -cne [string]$expectedAgent.WorkspaceIdentitySha256 -or
            [string]$actualAgent.TabIdentitySha256 -cne [string]$expectedAgent.TabIdentitySha256 -or
            [string]$actualAgent.PaneIdentitySha256 -cne [string]$expectedAgent.PaneIdentitySha256 -or
            [string]$actualAgent.Status -cne [string]$expectedAgent.Status) {
            throw "$Context Overview.VisibleTopAgents entry $i does not match a fresh recomputation from SourceState."
        }
    }

    $selectedIdentity = [string]$SourceState.SelectedAgentIdentitySha256
    if ([string]::IsNullOrWhiteSpace($selectedIdentity)) {
        if ([bool]$AgentDetail.AgentSelected) { throw "$Context AgentDetail claims a selection SourceState does not have." }
        if ([string]$AgentDetail.Status -cne 'UnknownMissingSource') { throw "$Context AgentDetail.Status was not the unselected sentinel." }
    } else {
        $selectedAgent = @($agents | Where-Object { [string]$_.AgentIdentitySha256 -ceq $selectedIdentity })[0]
        if ($null -eq $selectedAgent) { throw "$Context selected-agent identity is absent from SourceState agents." }
        if (-not [bool]$AgentDetail.AgentSelected -or
            [string]$AgentDetail.AgentIdentitySha256 -cne [string]$selectedAgent.AgentIdentitySha256 -or
            [string]$AgentDetail.WorkspaceIdentitySha256 -cne [string]$selectedAgent.WorkspaceIdentitySha256 -or
            [string]$AgentDetail.TabIdentitySha256 -cne [string]$selectedAgent.TabIdentitySha256 -or
            [string]$AgentDetail.PaneIdentitySha256 -cne [string]$selectedAgent.PaneIdentitySha256 -or
            [string]$AgentDetail.Status -cne [string]$selectedAgent.Status) {
            throw "$Context AgentDetail does not match the selected SourceState agent."
        }
    }
    if ([long]$AgentDetail.SessionSequence -ne [long]$SourceState.Sequence -or
        [long]$AgentDetail.ConnectionEpoch -ne [long]$SourceState.ConnectionEpoch) {
        throw "$Context AgentDetail session sequence/connection epoch does not match SourceState."
    }
    foreach ($field in @('Assignment','Tasks','Evidence')) {
        if ([string]$AgentDetail.$field -cne 'UnknownMissingSource') {
            throw "$Context AgentDetail.$field leaked non-sentinel content; this field must remain the unbound sentinel until a real source exists."
        }
    }
}

function Assert-V02SemanticVisualBindingsBound {
    param(
        [Parameter(Mandatory = $true)]$Capture,
        [Parameter(Mandatory = $true)][string[]]$ExpectedFileNames,
        [Parameter(Mandatory = $true)][array]$RuntimeCaptures,
        [Parameter(Mandatory = $true)][string]$ExpectedLanguage,
        [Parameter(Mandatory = $true)][string]$ExpectedLanguageCultureName,
        [Parameter(Mandatory = $true)][AllowNull()]$MinimumObservedUtc,
        [Parameter(Mandatory = $true)][DateTimeOffset]$MaximumObservedUtc,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $bound = @($Capture.BoundCaptures)
    $boundNames = @($bound | ForEach-Object { [string]$_.FileName })
    if ($boundNames.Count -ne $ExpectedFileNames.Count) {
        throw "$Context bound-capture count does not match the fixed catalog for this phase."
    }
    for ($i = 0; $i -lt $boundNames.Count; $i++) {
        if ($boundNames[$i] -cne $ExpectedFileNames[$i]) {
            throw "$Context bound-capture order/name does not match the fixed catalog for this phase."
        }
    }

    foreach ($binding in $bound) {
        $observedUtc = Get-V02SemanticNativeUtc "$Context bound-capture '$($binding.FileName)' ObservedUtc" $binding.ObservedUtc
        if ($observedUtc -gt $MaximumObservedUtc) {
            throw "$Context bound-capture '$($binding.FileName)' was observed after its owning phase capture."
        }
        if ($null -ne $MinimumObservedUtc -and $observedUtc -lt $MinimumObservedUtc) {
            throw "$Context bound-capture '$($binding.FileName)' predates the event it is bound to."
        }
        if ([int]$binding.PixelWidth -le 0 -or [int]$binding.PixelHeight -le 0) {
            throw "$Context bound-capture '$($binding.FileName)' has a non-positive pixel size."
        }
        if ([long]$binding.StateSequence -ne [long]$Capture.Sequence) {
            throw "$Context bound-capture '$($binding.FileName)' sequence does not match its owning semantic capture."
        }
        if ([string]$binding.StateSha256 -cne [string]$Capture.NormalizedStateSha256) {
            throw "$Context bound-capture '$($binding.FileName)' state hash does not match its owning semantic capture."
        }
        if (-not (Test-V02SemanticSha256 ([string]$binding.Sha256))) {
            throw "$Context bound-capture '$($binding.FileName)' hash is not a native SHA-256 value."
        }
        if ([string]$binding.Language -cne $ExpectedLanguage) {
            throw "$Context bound-capture '$($binding.FileName)' language '$($binding.Language)' does not match the run's requested language '$ExpectedLanguage' (cross-language leakage)."
        }
        if ([string]$binding.LanguageCultureName -cne $ExpectedLanguageCultureName) {
            throw "$Context bound-capture '$($binding.FileName)' UI culture does not match the run's requested language."
        }

        $matches = @($RuntimeCaptures | Where-Object {
            (Split-Path -Leaf ([string]$_.Path)) -ceq [string]$binding.FileName
        })
        if ($matches.Count -ne 1) {
            throw "$Context bound-capture '$($binding.FileName)' does not exactly-cross-reference one already-hash-verified top-level runtime capture."
        }
        $runtimeCapture = $matches[0]
        if ([string]$runtimeCapture.Sha256 -cne [string]$binding.Sha256 -or
            [int]$runtimeCapture.PixelWidth -ne [int]$binding.PixelWidth -or
            [int]$runtimeCapture.PixelHeight -ne [int]$binding.PixelHeight -or
            [long]$runtimeCapture.StateSequence -ne [long]$binding.StateSequence -or
            [string]$runtimeCapture.StateSha256 -cne [string]$binding.StateSha256 -or
            [string]$runtimeCapture.Language -cne [string]$binding.Language -or
            [string]$runtimeCapture.LanguageCultureName -cne [string]$binding.LanguageCultureName) {
            throw "$Context bound-capture '$($binding.FileName)' does not exactly match the corresponding top-level runtime capture."
        }
        $runtimeObservedUtc = Get-V02SemanticNativeUtc "$Context runtime capture '$($binding.FileName)' ObservedUtc" $runtimeCapture.ObservedUtc
        if ($runtimeObservedUtc -ne $observedUtc) {
            throw "$Context bound-capture '$($binding.FileName)' timestamp does not match the corresponding top-level runtime capture."
        }
    }
}

function Assert-V02RuntimeSemanticStateCaptures {
    <#
        Fail-closed cross-check of AppRuntimeEvidenceReport.SemanticStateCaptures against
        values the composite v0.2 runtime-acceptance gate has already independently bound
        (Core-trace-matched phase sequences/hashes, on-disk hash-verified captures, the
        run's requested language). Static/Contract/Synthetic preparation; establishes no
        Runtime or Release credit on its own.
    #>
    param(
        [Parameter(Mandatory = $true)]$AppReport,
        [Parameter(Mandatory = $true)][array]$RuntimeCaptures,
        [Parameter(Mandatory = $true)][ValidateSet('Thai', 'English')][string]$ExpectedLanguage,
        [Parameter(Mandatory = $true)][string]$ExpectedLanguageCultureName,
        [Parameter(Mandatory = $true)][DateTimeOffset]$ValidationUtc
    )

    if ($null -eq $AppReport.PSObject.Properties['SemanticStateCaptures']) {
        throw 'The App runtime report omitted SemanticStateCaptures.'
    }
    $captures = @($AppReport.SemanticStateCaptures)
    if ($captures.Count -ne 3) {
        throw "SemanticStateCaptures must contain exactly 3 entries; found $($captures.Count)."
    }

    foreach ($field in @('EventA','EventB')) {
        if ($null -eq $AppReport.PSObject.Properties[$field]) { throw "The App runtime report omitted $field for semantic-capture binding." }
    }
    $eventAPhaseEnteredUtc = Get-V02SemanticNativeUtc 'EventA.PhaseEnteredUtc' $AppReport.EventA.PhaseEnteredUtc
    $eventAObservedUtc = Get-V02SemanticNativeUtc 'EventA.ObservedUtc' $AppReport.EventA.ObservedUtc
    $eventBPhaseEnteredUtc = Get-V02SemanticNativeUtc 'EventB.PhaseEnteredUtc' $AppReport.EventB.PhaseEnteredUtc
    $eventBObservedUtc = Get-V02SemanticNativeUtc 'EventB.ObservedUtc' $AppReport.EventB.ObservedUtc
    if ($eventAPhaseEnteredUtc -gt $eventAObservedUtc -or $eventBPhaseEnteredUtc -gt $eventBObservedUtc) {
        throw 'Event A/B phase-entered timestamps are not ordered before their observed timestamps.'
    }

    $catalog = @(
        [pscustomobject]@{ Ordinal = 1; Phase = 'initial'; Event = 'InitialLiveState'; Sequence = [long]$AppReport.InitialSequence; Hash = [string]$AppReport.InitialStateSha256; Names = @('dashboard-overview.png','dashboard-live-organization.png','dashboard-agent-detail.png','widget-compact.png','widget-normal.png','widget-floating-vertical.png') },
        [pscustomobject]@{ Ordinal = 2; Phase = 'event-a-pre-close'; Event = 'EventA'; Sequence = [long]$AppReport.PreCloseSequence; Hash = [string]$AppReport.PreCloseStateSha256; Names = @('dashboard-overview-after-event.png') },
        [pscustomobject]@{ Ordinal = 3; Phase = 'post-close-final'; Event = 'EventB'; Sequence = [long]$AppReport.PostCloseSequence; Hash = [string]$AppReport.PostCloseStateSha256; Names = @('widget-floating-vertical-after-dashboard-close.png') }
    )

    $observedUtcs = @()
    for ($i = 0; $i -lt 3; $i++) {
        $capture = $captures[$i]
        $expected = $catalog[$i]
        $context = "SemanticStateCaptures[$i] (phase '$($expected.Phase)')"

        foreach ($field in @('Ordinal','Phase','EventBinding','BoundCaptures','ObservedUtc','Sequence','NormalizedStateSha256','SourceState','SourceStateSha256','IsCoreConnected','IsLive','Overview','LiveOrganization','AgentDetail','SemanticProjectionSha256','CaptureStateSha256')) {
            if ($null -eq $capture.PSObject.Properties[$field]) { throw "$context omitted required field '$field'." }
        }

        if ([int]$capture.Ordinal -ne $expected.Ordinal) { throw "$context ordinal does not match the fixed catalog." }
        if ([string]$capture.Phase -cne $expected.Phase) { throw "$context phase does not match the fixed catalog." }
        if ([string]$capture.EventBinding -cne $expected.Event) { throw "$context event binding does not match the fixed catalog." }
        if ([long]$capture.Sequence -ne $expected.Sequence) { throw "$context sequence does not match the independently Core-trace-bound phase sequence." }
        if ([string]$capture.NormalizedStateSha256 -cne $expected.Hash) { throw "$context state hash does not match the independently Core-trace-bound phase hash." }
        if (-not [bool]$capture.IsCoreConnected -or -not [bool]$capture.IsLive) { throw "$context was admitted while not connected/live." }

        $observedUtc = Get-V02SemanticNativeUtc "$context ObservedUtc" $capture.ObservedUtc
        if ($observedUtc -gt $ValidationUtc) { throw "$context was observed after the validation timestamp." }
        $observedUtcs += , $observedUtc

        $minimumBoundUtc = if ($expected.Ordinal -eq 2) { $eventAObservedUtc } elseif ($expected.Ordinal -eq 3) { $eventBObservedUtc } else { $null }
        Assert-V02SemanticVisualBindingsBound -Capture $capture -ExpectedFileNames $expected.Names `
            -RuntimeCaptures $RuntimeCaptures -ExpectedLanguage $ExpectedLanguage `
            -ExpectedLanguageCultureName $ExpectedLanguageCultureName `
            -MinimumObservedUtc $minimumBoundUtc -MaximumObservedUtc $observedUtc -Context $context

        Assert-V02SemanticSourceStateValid -SourceState $capture.SourceState -ExpectedSequence $expected.Sequence -Context $context
        Assert-V02SemanticProjectionsMatchSource -SourceState $capture.SourceState -Overview $capture.Overview `
            -LiveOrganization $capture.LiveOrganization -AgentDetail $capture.AgentDetail -Context $context

        if (-not (Test-V02SemanticSha256 ([string]$capture.SourceStateSha256))) { throw "$context SourceStateSha256 is not a native SHA-256 value." }
        if (-not (Test-V02SemanticSha256 ([string]$capture.SemanticProjectionSha256))) { throw "$context SemanticProjectionSha256 is not a native SHA-256 value." }
        if (-not (Test-V02SemanticSha256 ([string]$capture.CaptureStateSha256))) { throw "$context CaptureStateSha256 is not a native SHA-256 value." }
    }

    if (-not ($observedUtcs[0] -lt $eventAPhaseEnteredUtc -and
              $eventAPhaseEnteredUtc -le $eventAObservedUtc -and
              $eventAObservedUtc -le $observedUtcs[1] -and
              $observedUtcs[1] -lt $eventBPhaseEnteredUtc -and
              $eventBPhaseEnteredUtc -le $eventBObservedUtc -and
              $eventBObservedUtc -le $observedUtcs[2] -and
              $observedUtcs[2] -le $ValidationUtc)) {
        throw 'SemanticStateCaptures/EventA/EventB observed-timestamp chain is not monotonically ordered end-to-end.'
    }

    $sourceStateHashes = @($captures | ForEach-Object { [string]$_.SourceStateSha256 })
    if (@($sourceStateHashes | Select-Object -Unique).Count -ne 3) {
        throw 'SourceStateSha256 is not pairwise distinct across the three semantic captures with independently-distinct sequences.'
    }
    $captureStateHashes = @($captures | ForEach-Object { [string]$_.CaptureStateSha256 })
    if (@($captureStateHashes | Select-Object -Unique).Count -ne 3) {
        throw 'CaptureStateSha256 is not pairwise distinct across the three semantic captures with independently-distinct bound captures.'
    }
}
