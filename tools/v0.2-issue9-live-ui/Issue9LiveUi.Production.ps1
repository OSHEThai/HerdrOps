#requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Issue9LiveUi.Common.ps1')

function Assert-I9RunNonce {
    param($Value,[Parameter(Mandatory)][string]$Context)
    $text = Assert-I9String $Value $Context
    if ($text -cnotmatch '^[0-9a-f]{32}$') { throw "$Context must be 32 lowercase hexadecimal characters." }
    return $text
}

function New-I9DesktopSideBySideCapture {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OutputPath,
        [Parameter(Mandatory)]$Progress
    )

    if ([string]$Progress.Phase -cne 'capturing-live-dashboard-and-widgets') {
        throw 'Issue #9 desktop capture rejected: progress is outside the initial semantic capture phase.'
    }
    if ([long]$Progress.Sequence -le 0 -or [string]$Progress.StateSha256 -cnotmatch '^[0-9A-F]{64}$') {
        throw 'Issue #9 desktop capture rejected: progress lacks a native Core sequence/state hash.'
    }
    $full = Get-I9FullPath $OutputPath 'Issue #9 desktop capture output'
    $parent = [IO.Path]::GetDirectoryName($full)
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw 'Issue #9 desktop capture parent is missing.' }
    Assert-I9NoReparse $parent 'Issue #9 desktop capture parent'
    if (Test-Path -LiteralPath $full) { throw 'Issue #9 desktop capture output already exists.' }

    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    $bounds = [Windows.Forms.SystemInformation]::VirtualScreen
    if ($bounds.Width -le 0 -or $bounds.Height -le 0) { throw 'Issue #9 desktop capture found no positive virtual-screen bounds.' }
    $bitmap = [Drawing.Bitmap]::new($bounds.Width,$bounds.Height,[Drawing.Imaging.PixelFormat]::Format32bppPArgb)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen($bounds.Left,$bounds.Top,0,0,$bounds.Size,[Drawing.CopyPixelOperation]::SourceCopy)
        $bitmap.Save($full,[Drawing.Imaging.ImageFormat]::Png)
    } finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
    $observedUtc = [DateTimeOffset]::UtcNow
    $png = Assert-I9Png $full 'Issue #9 actual-Herdr/UI desktop capture'
    return [pscustomobject][ordered]@{
        Path = $png.Path
        Bytes = $png.Bytes
        Sha256 = $png.Sha256
        PixelWidth = $png.PixelWidth
        PixelHeight = $png.PixelHeight
        ObservedUtc = $observedUtc.ToString('O')
        Phase = [string]$Progress.Phase
        Sequence = [long]$Progress.Sequence
        StateSha256 = [string]$Progress.StateSha256
    }
}

function Get-I9ExactSemanticCapture {
    param([Parameter(Mandatory)]$App,[Parameter(Mandatory)][int]$Ordinal,[Parameter(Mandatory)][string]$Phase)
    $matches = @($App.SemanticStateCaptures | Where-Object { [int]$_.Ordinal -eq $Ordinal -and [string]$_.Phase -ceq $Phase })
    if ($matches.Count -ne 1) { throw "Issue #9 producer requires exactly one semantic capture ordinal=$Ordinal phase=$Phase." }
    return $matches[0]
}

function Get-I9ExactCoreTransition {
    param([Parameter(Mandatory)]$Core,[Parameter(Mandatory)][long]$Sequence,[Parameter(Mandatory)][string]$StateSha256,[Parameter(Mandatory)][string]$Context)
    $matches = @($Core.Transitions | Where-Object { [long]$_.IngestSequence -eq $Sequence -and [string]$_.ContractStateSha256 -ceq $StateSha256 })
    if ($matches.Count -ne 1) { throw "$Context is not bound to exactly one Core transition." }
    return $matches[0]
}

function New-I9LiveUiObservation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RuntimeEvidenceDirectory,
        [Parameter(Mandatory)][string]$UiEvidenceDirectory,
        [Parameter(Mandatory)][string]$GateReportPath,
        [Parameter(Mandatory)][string]$AppRuntimeReportPath,
        [Parameter(Mandatory)][string]$CoreRuntimeReportPath,
        [Parameter(Mandatory)]$SideBySideCapture,
        [Parameter(Mandatory)][ValidateSet('Thai','English')][string]$Language,
        [Parameter(Mandatory)][string]$ExpectedSourceCommit,
        [Parameter(Mandatory)][string]$ExpectedSourceTree,
        [Parameter(Mandatory)][string]$RunNonce,
        [Parameter(Mandatory)][string]$ProducerScriptPath,
        [Parameter(Mandatory)]$ControlServerIdentityBefore,
        [Parameter(Mandatory)]$ControlServerIdentityAfter,
        [string]$OutputPath = ''
    )

    Assert-I9GitSha $ExpectedSourceCommit 'Issue #9 producer source commit' | Out-Null
    Assert-I9GitSha $ExpectedSourceTree 'Issue #9 producer source tree' | Out-Null
    $RunNonce = Assert-I9RunNonce $RunNonce 'Issue #9 producer RunNonce'
    $runtimeRoot = Get-I9FullPath $RuntimeEvidenceDirectory 'Issue #9 runtime evidence root'
    $uiRoot = Get-I9FullPath $UiEvidenceDirectory 'Issue #9 UI evidence root'
    if (-not (Test-I9Within $uiRoot $runtimeRoot) -or $uiRoot.Equals($runtimeRoot,[StringComparison]::OrdinalIgnoreCase)) {
        throw 'Issue #9 UI evidence root must be a strict descendant of its runtime leg.'
    }
    foreach ($root in @($runtimeRoot,$uiRoot)) { Assert-I9NoReparse $root 'Issue #9 evidence root' }

    $gatePath = Resolve-I9Path $runtimeRoot $GateReportPath 'Issue #9 runtime gate report'
    $appPath = Resolve-I9Path $runtimeRoot $AppRuntimeReportPath 'Issue #9 App runtime report'
    $corePath = Resolve-I9Path $runtimeRoot $CoreRuntimeReportPath 'Issue #9 Core runtime report'
    $gate = Get-I9GateMap $gatePath
    Assert-I9Gate $gate $Language $ExpectedSourceCommit $ExpectedSourceTree
    if ((Assert-I9RunNonce (Get-I9GateValue $gate 'RunNonce' 'Issue #9 gate') 'Issue #9 gate RunNonce') -cne $RunNonce) {
        throw 'Issue #9 producer RunNonce does not match the held runtime leg.'
    }
    $appDoc = Read-I9Json $appPath 'Issue #9 App runtime report'
    $coreDoc = Read-I9Json $corePath 'Issue #9 Core runtime report'
    if ((Get-I9GateValue $gate 'AppRuntimeReportSha256' 'Issue #9 gate') -cne $appDoc.Sha256 -or
        (Get-I9GateValue $gate 'CoreRuntimeReportSha256' 'Issue #9 gate') -cne $coreDoc.Sha256) {
        throw 'Issue #9 producer runtime report hashes are stale or cross-leg.'
    }
    $app = $appDoc.Value; $core = $coreDoc.Value
    if ([string]$app.EvidenceClassification -cne 'RuntimeCandidate' -or [string]$core.EvidenceClassification -cne 'Runtime') { throw 'Issue #9 producer requires the App RuntimeCandidate and Core Runtime reports.' }
    if ([string]$app.Language -cne $Language -or [string]$app.FinalLanguage -cne $Language -or -not [bool]$app.LanguageStableThroughFinish -or [long]$app.LanguageChangeCount -ne 0) { throw 'Issue #9 producer language leg is not stable and exact.' }

    $initial = Get-I9ExactSemanticCapture $app 1 'initial'
    $eventASemantic = Get-I9ExactSemanticCapture $app 2 'event-a-pre-close'
    $eventBSemantic = Get-I9ExactSemanticCapture $app 3 'post-close-final'
    if ([string]$initial.EventBinding -cne 'InitialLiveState' -or [string]$eventASemantic.EventBinding -cne 'EventA' -or [string]$eventBSemantic.EventBinding -cne 'EventB') { throw 'Issue #9 semantic phase/event binding is invalid.' }
    if ([long]$initial.Sequence -ne [long]$app.InitialSequence -or [string]$initial.NormalizedStateSha256 -cne [string]$app.InitialStateSha256 -or
        [long]$eventASemantic.Sequence -ne [long]$app.PreCloseSequence -or [string]$eventASemantic.NormalizedStateSha256 -cne [string]$app.PreCloseStateSha256 -or
        [long]$eventBSemantic.Sequence -ne [long]$app.PostCloseSequence -or [string]$eventBSemantic.NormalizedStateSha256 -cne [string]$app.PostCloseStateSha256) {
        throw 'Issue #9 semantic captures are not bound to the exact runtime phase states.'
    }

    $eventAChanges = @($app.EventA.Changes); $eventBChanges = @($app.EventB.Changes)
    if ($eventAChanges.Count -ne 1 -or $eventBChanges.Count -ne 1) { throw 'Issue #9 producer requires exactly one Agent-status change in Event A and Event B.' }
    $eventAChange = $eventAChanges[0]; $eventBChange = $eventBChanges[0]
    foreach ($field in @('TerminalId','WorkspaceId','TabId','PaneId','PreviousStatus','CurrentStatus')) {
        Assert-I9String $eventAChange.$field "Issue #9 Event A $field" | Out-Null
        Assert-I9String $eventBChange.$field "Issue #9 Event B $field" | Out-Null
    }
    foreach ($field in @('TerminalId','WorkspaceId','TabId','PaneId')) {
        if ([string]$eventAChange.$field -cne [string]$eventBChange.$field) { throw "Issue #9 intended Agent identity changed across reconnect ($field)." }
    }
    $selectedHash = Get-I9RedactedIdentity 'agent' ([string]$eventAChange.TerminalId)
    if ([string]$initial.SourceState.SelectedAgentIdentitySha256 -cne $selectedHash) { throw 'Issue #9 selected Agent does not match the initial semantic Core snapshot.' }
    $selectedAgents = @($initial.SourceState.Agents | Where-Object { [string]$_.AgentIdentitySha256 -ceq $selectedHash })
    if ($selectedAgents.Count -ne 1) { throw 'Issue #9 selected Agent is not unique in the initial semantic Core snapshot.' }
    $selectedAgent = $selectedAgents[0]
    $identityChecks = [ordered]@{
        WorkspaceIdentitySha256 = Get-I9RedactedIdentity 'workspace' ([string]$eventAChange.WorkspaceId)
        TabIdentitySha256 = Get-I9RedactedIdentity 'tab' ([string]$eventAChange.TabId)
        PaneIdentitySha256 = Get-I9RedactedIdentity 'pane' ([string]$eventAChange.PaneId)
    }
    foreach ($field in $identityChecks.Keys) { if ([string]$selectedAgent.$field -cne [string]$identityChecks[$field]) { throw "Issue #9 forged synchronized identifier rejected at semantic guard ($field)." } }
    if ([string]$selectedAgent.Status -cne [string]$eventAChange.PreviousStatus) { throw 'Issue #9 initial selected status does not match the exact pre-Event-A Core state.' }

    $captureRoot = Get-I9FullPath (Get-I9GateValue $gate 'CaptureDirectory' 'Issue #9 gate') 'Issue #9 capture directory'
    if (-not (Test-I9Within $captureRoot $runtimeRoot)) { throw 'Issue #9 capture directory escaped its runtime leg.' }
    Assert-I9NoReparse $captureRoot 'Issue #9 capture directory'
    $captureByName = @{}
    foreach ($capture in @($app.Captures)) {
        $name = Assert-I9String $capture.Name 'Issue #9 runtime capture name'
        if ($captureByName.ContainsKey($name)) { throw "Issue #9 runtime capture name is duplicated: $name" }
        $captureByName[$name] = $capture
    }
    $pageMap = [ordered]@{ Overview='dashboard-overview'; LiveOrganization='dashboard-live-organization'; AgentDetail='dashboard-agent-detail' }
    $pages = @()
    $initialObservedUtc = ConvertTo-I9Utc ([string]$initial.ObservedUtc) 'Issue #9 initial semantic observation'
    $startedUtc = ConvertTo-I9Utc ([string]$app.StartedUtc) 'Issue #9 App start'
    foreach ($pageName in $pageMap.Keys) {
        $captureName = $pageMap[$pageName]
        if (-not $captureByName.ContainsKey($captureName)) { throw "Issue #9 producer is missing runtime page capture '$captureName'." }
        $capture = $captureByName[$captureName]
        $capturePath = Resolve-I9Path $captureRoot ([string]$capture.Path) "Issue #9 $pageName PNG"
        if (-not [IO.Path]::GetDirectoryName($capturePath).Equals($captureRoot,[StringComparison]::OrdinalIgnoreCase)) { throw "Issue #9 $pageName capture escaped the exact capture root." }
        $png = Assert-I9Png $capturePath "Issue #9 $pageName PNG"
        if ($png.PixelWidth -ne 1672 -or $png.PixelHeight -ne 941) { throw "Issue #9 $pageName PNG must decode to exactly 1672x941." }
        $captureUtc = ConvertTo-I9Utc ([string]$capture.ObservedUtc) "Issue #9 $pageName observedUtc"
        if ([string]$capture.Sha256 -cne $png.Sha256 -or [int]$capture.PixelWidth -ne $png.PixelWidth -or [int]$capture.PixelHeight -ne $png.PixelHeight) { throw "Issue #9 $pageName PNG bytes/hash/dimensions do not match the runtime producer." }
        if ([long]$capture.StateSequence -ne [long]$initial.Sequence -or [string]$capture.StateSha256 -cne [string]$initial.NormalizedStateSha256 -or $captureUtc -lt $startedUtc -or $captureUtc -gt $initialObservedUtc) { throw "Issue #9 $pageName capture is outside the exact initial semantic state/window." }
        $binding = @($initial.BoundCaptures | Where-Object { [string]$_.FileName -ceq ([IO.Path]::GetFileName($capturePath)) })
        if ($binding.Count -ne 1 -or [string]$binding[0].Sha256 -cne $png.Sha256 -or [long]$binding[0].StateSequence -ne [long]$initial.Sequence -or [string]$binding[0].StateSha256 -cne [string]$initial.NormalizedStateSha256) { throw "Issue #9 $pageName PNG is not in the exact initial semantic binding." }
        $pages += [pscustomobject][ordered]@{
            Name=$pageName; Language=$Language; UiCapturePath=$png.Path; UiCaptureSha256=$png.Sha256; PixelWidth=$png.PixelWidth; PixelHeight=$png.PixelHeight
            ObservedUtc=$captureUtc.ToString('O'); Phase='initial'; Sequence=[long]$initial.Sequence; StateSha256=[string]$initial.NormalizedStateSha256
            WorkspaceId=[string]$eventAChange.WorkspaceId; ProjectId=[string]$eventAChange.WorkspaceId; AgentId=[string]$eventAChange.TerminalId; TaskId=[string]$eventAChange.TabId; AgentStatus=[string]$eventAChange.PreviousStatus; PaneId=[string]$eventAChange.PaneId
        }
    }

    if ([string]$SideBySideCapture.Phase -cne 'capturing-live-dashboard-and-widgets' -or [long]$SideBySideCapture.Sequence -ne [long]$initial.Sequence -or [string]$SideBySideCapture.StateSha256 -cne [string]$initial.NormalizedStateSha256) { throw 'Issue #9 side-by-side capture is bound to the wrong phase/state.' }
    $sidePath = Resolve-I9Path $uiRoot ([string]$SideBySideCapture.Path) 'Issue #9 side-by-side PNG'
    $sidePng = Assert-I9Png $sidePath 'Issue #9 side-by-side PNG'
    if ($sidePng.PixelWidth -gt 16384 -or $sidePng.PixelHeight -gt 16384 -or ([int64]$sidePng.PixelWidth * [int64]$sidePng.PixelHeight) -gt 134217728) { throw 'Issue #9 side-by-side PNG dimensions exceed the bounded capture envelope.' }
    $sideUtc = ConvertTo-I9Utc ([string]$SideBySideCapture.ObservedUtc) 'Issue #9 side-by-side observedUtc'
    $eventAPhaseUtc = ConvertTo-I9Utc ([string]$app.EventA.PhaseEnteredUtc) 'Issue #9 Event A phase entered'
    if ($sideUtc -lt $startedUtc -or $sideUtc -ge $eventAPhaseUtc) { throw 'Issue #9 side-by-side capture is stale or outside the initial semantic window.' }
    if ([string]$SideBySideCapture.Sha256 -cne $sidePng.Sha256 -or [int64]$SideBySideCapture.Bytes -ne $sidePng.Bytes -or [int]$SideBySideCapture.PixelWidth -ne $sidePng.PixelWidth -or [int]$SideBySideCapture.PixelHeight -ne $sidePng.PixelHeight) { throw 'Issue #9 side-by-side PNG bytes/hash/dimensions changed after capture.' }

    $initialTransition = Get-I9ExactCoreTransition $core ([long]$app.InitialSequence) ([string]$app.InitialStateSha256) 'Issue #9 initial lifecycle state'
    $eventATransition = Get-I9ExactCoreTransition $core ([long]$app.PreCloseSequence) ([string]$app.PreCloseStateSha256) 'Issue #9 Event A lifecycle state'
    $eventBTransition = Get-I9ExactCoreTransition $core ([long]$app.PostCloseSequence) ([string]$app.PostCloseStateSha256) 'Issue #9 Event B lifecycle state'
    $dashboardUtc = ConvertTo-I9Utc ([string]$app.DashboardClosedUtc) 'Issue #9 Dashboard close'
    $disconnectUtc = ConvertTo-I9Utc ([string]$app.DisconnectObservedUtc) 'Issue #9 disconnect'
    $reconnectUtc = ConvertTo-I9Utc ([string]$app.ReconnectObservedUtc) 'Issue #9 reconnect'
    $eventBUtc = ConvertTo-I9Utc ([string]$app.EventB.ObservedUtc) 'Issue #9 Event B'
    $finalSemanticUtc = ConvertTo-I9Utc ([string]$eventBSemantic.ObservedUtc) 'Issue #9 final semantic capture'
    $eventAUtc = ConvertTo-I9Utc ([string]$app.EventA.ObservedUtc) 'Issue #9 Event A'
    $eventASemanticUtc = ConvertTo-I9Utc ([string]$eventASemantic.ObservedUtc) 'Issue #9 Event A semantic'
    if (-not ($initialObservedUtc -lt $eventAPhaseUtc -and $eventAPhaseUtc -le $eventAUtc -and $eventAUtc -le $eventASemanticUtc -and
        $eventASemanticUtc -le $dashboardUtc -and $dashboardUtc -lt $disconnectUtc -and $disconnectUtc -lt $reconnectUtc -and $reconnectUtc -lt $eventBUtc -and $eventBUtc -le $finalSemanticUtc)) {
        throw 'Issue #9 lifecycle chronology is not initial, Event A, Dashboard close, disconnect, reconnect/reconciliation, Event B.'
    }
    $reconciliations = @($core.Transitions | Where-Object {
        [long]$_.ReconciliationCount -gt [long]$eventATransition.ReconciliationCount -and
        (ConvertTo-I9Utc ([string]$_.ObservedUtc) 'Issue #9 reconciliation transition') -ge $reconnectUtc -and
        (ConvertTo-I9Utc ([string]$_.ObservedUtc) 'Issue #9 reconciliation transition') -lt $eventBUtc
    })
    if ($reconciliations.Count -lt 1) { throw 'Issue #9 lifecycle omitted a Core reconciliation between reconnect and Event B.' }
    $reconciled = $reconciliations[$reconciliations.Count - 1]

    $controlFields = @('ProcessId','ProcessStartUtc','ExecutablePath','ExecutableSha256')
    foreach ($field in $controlFields) {
        if ([string]$ControlServerIdentityBefore.$field -cne [string]$ControlServerIdentityAfter.$field) { throw "Issue #9 Acceptance control server did not survive target restart ($field)." }
    }
    Assert-I9Sha ([string]$ControlServerIdentityBefore.ExecutableSha256) 'Issue #9 control Herdr executable hash' | Out-Null

    $producerScript = Read-I9HeldFile $ProducerScriptPath -MaximumBytes 2097152
    $output = if ([string]::IsNullOrWhiteSpace($OutputPath)) { Join-Path $uiRoot 'issue9-ui-functional.json' } else { Get-I9FullPath $OutputPath 'Issue #9 observation output' }
    if (-not (Test-I9Within $output $uiRoot)) { throw 'Issue #9 observation output escaped its UI evidence root.' }
    $selection = [pscustomobject][ordered]@{
        WorkspaceId=[string]$eventAChange.WorkspaceId; ProjectId=[string]$eventAChange.WorkspaceId; AgentId=[string]$eventAChange.TerminalId; TaskId=[string]$eventAChange.TabId; AgentStatus=[string]$eventAChange.PreviousStatus; PaneId=[string]$eventAChange.PaneId; StateSha256=[string]$initial.NormalizedStateSha256; Source='CoreSemanticSnapshot'
    }
    $receipt = [pscustomobject][ordered]@{
        SchemaVersion=2; EvidenceClassification='Issue9LiveUiObservation'; Issue=9; Language=$Language; RunNonce=$RunNonce
        Source=[pscustomobject][ordered]@{ CommitSha=$ExpectedSourceCommit; TreeSha=$ExpectedSourceTree }
        Producer=[pscustomobject][ordered]@{ Name='Test-V02LiveRuntimeAcceptance.ps1/HerdrOps.App.RuntimeEvidenceRunner'; ScriptPath=$producerScript.Path; ScriptSha256=$producerScript.Sha256; AppProcessId=[int]$app.AppProcessId; AppExecutableSha256=(Get-I9GateValue $gate 'AppSha256' 'Issue #9 gate'); GeneratedUtc=[DateTimeOffset]::UtcNow.ToString('O') }
        IdentityMapping=[pscustomobject][ordered]@{ ProjectIdSource='Core.WorkspaceId'; TaskIdSource='Core.TabId'; AgentIdSource='Core.TerminalId' }
        Bindings=[pscustomobject][ordered]@{ GateReportSha256=$gate.Sha256; AppRuntimeReportSha256=$appDoc.Sha256; CoreRuntimeReportSha256=$coreDoc.Sha256; ProgressHistorySha256=(Get-I9GateValue $gate 'ProgressHistorySha256' 'Issue #9 gate'); PackageIdentityReceiptSha256=(Get-I9GateValue $gate 'PackageIdentityReceiptSha256' 'Issue #9 gate'); PackageArchiveSha256=(Get-I9GateValue $gate 'PackageArchiveSha256' 'Issue #9 gate'); PackageManifestSha256=(Get-I9GateValue $gate 'PackageManifestSha256' 'Issue #9 gate'); AppSha256=(Get-I9GateValue $gate 'AppSha256' 'Issue #9 gate'); CoreSha256=(Get-I9GateValue $gate 'CoreSha256' 'Issue #9 gate'); HerdrExecutableSha256=(Get-I9GateValue $gate 'HerdrExecutableSha256' 'Issue #9 gate'); BundledSchemaSha256=(Get-I9GateValue $gate 'BundledSchemaSha256' 'Issue #9 gate') }
        SideBySideCapture=[pscustomobject][ordered]@{ Path=$sidePng.Path; Bytes=$sidePng.Bytes; Sha256=$sidePng.Sha256; PixelWidth=$sidePng.PixelWidth; PixelHeight=$sidePng.PixelHeight; ObservedUtc=$sideUtc.ToString('O'); Phase='initial'; Sequence=[long]$initial.Sequence; StateSha256=[string]$initial.NormalizedStateSha256; RunNonce=$RunNonce; ArtifactRole='ActualHerdrAndUiSideBySide' }
        Pages=@($pages); Selection=$selection
        Lifecycle=[pscustomobject][ordered]@{ DashboardClosed=$true; DashboardClosedUtc=$dashboardUtc.ToString('O'); CoreConnectedAfterDashboardClose=[bool]$app.CoreConnectedAfterDashboardClose; DisconnectObserved=[bool]$app.DisconnectObservedAfterDashboardClose; DisconnectObservedUtc=$disconnectUtc.ToString('O'); ReconnectObserved=[bool]$app.ReconnectObservedAfterDashboardClose; ReconnectObservedUtc=$reconnectUtc.ToString('O'); ReconciliationObserved=$true; ReconciliationCount=[long]$reconciled.ReconciliationCount; EventAStateSha256=[string]$app.PreCloseStateSha256; EventBStateSha256=[string]$app.PostCloseStateSha256; ReconciledStateSha256=[string]$reconciled.ContractStateSha256; ControlServerSurvivedTargetRestart=$true }
        EvidenceBoundary=[pscustomobject][ordered]@{ Runtime='NOT_OBSERVED'; HumanVisual='NOT_OBSERVED'; ReleaseCredit=$false }
    }
    $json = ConvertTo-V02Jcs $receipt
    $published = Publish-I9NoClobber $uiRoot $output $json
    return [pscustomobject][ordered]@{ Path=$published.Path; Sha256=$published.Sha256; Receipt=$receipt }
}
