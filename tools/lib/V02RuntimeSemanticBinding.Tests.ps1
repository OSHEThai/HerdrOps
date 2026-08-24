#requires -Version 5.1
[CmdletBinding()] param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'V02RuntimeSemanticBinding.ps1')

$failures = New-Object 'System.Collections.Generic.List[string]'
function Test-Case([string]$Name,[scriptblock]$Body,[bool]$ShouldThrow=$false) {
    try { & $Body; if($ShouldThrow){throw 'Expected failure was not observed.'}; Write-Host "PASS: $Name" }
    catch { if($ShouldThrow){Write-Host "PASS: $Name"}else{$failures.Add("$Name`: $($_.Exception.Message)");Write-Host "FAIL: $Name" -ForegroundColor Red} }
}

function New-FixtureHash([string]$Seed) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Seed)))).Replace('-','').ToUpperInvariant() }
    finally { $sha.Dispose() }
}

function ConvertFrom-V02SemanticFixtureJson {
    # Mirrors tools/lib/V02ResourceStageCheckpoints.ps1's ConvertFrom-V02CheckpointJson: PowerShell
    # 7.4+'s ConvertFrom-Json auto-widens ISO-8601-looking strings to [DateTime], which would corrupt
    # the native-UTC-string contract this fixture (and the real App report) relies on. Force -DateKind
    # String where available; PS 5.1's ConvertFrom-Json has no such auto-widening to guard against.
    param([Parameter(Mandatory)][string]$Json)
    $convertCommand = Get-Command ConvertFrom-Json -CommandType Cmdlet
    if ($convertCommand.Parameters.ContainsKey('DateKind')) {
        return $Json | ConvertFrom-Json -DateKind String
    }
    return $Json | ConvertFrom-Json
}

$T0='2026-08-22T10:00:00Z';$T1='2026-08-22T10:00:01Z';$T2='2026-08-22T10:00:02Z';$T3='2026-08-22T10:00:03Z'
$T4='2026-08-22T10:00:04Z';$T5='2026-08-22T10:00:05Z';$T6='2026-08-22T10:00:06Z';$T7='2026-08-22T10:00:07Z'

$ws1 = New-FixtureHash 'workspace-1'
$tab1 = New-FixtureHash 'tab-1'
$pane1 = New-FixtureHash 'pane-1'
$pane2 = New-FixtureHash 'pane-2'
$pane3 = New-FixtureHash 'pane-3'
$agent1 = New-FixtureHash 'agent-1'
$agent2 = New-FixtureHash 'agent-2'

function New-SourceState([long]$Sequence) {
    return [ordered]@{
        ConnectionEpoch = 1
        Sequence = $Sequence
        WorkspaceIdentitiesSha256 = @($ws1)
        TabIdentitiesSha256 = @($tab1)
        Panes = @(
            [ordered]@{ PaneIdentitySha256 = $pane1; TerminalIdentitySha256 = $agent1 },
            [ordered]@{ PaneIdentitySha256 = $pane2; TerminalIdentitySha256 = $agent2 },
            [ordered]@{ PaneIdentitySha256 = $pane3; TerminalIdentitySha256 = (New-FixtureHash 'unassigned-terminal') }
        )
        Agents = @(
            [ordered]@{ AgentIdentitySha256 = $agent1; WorkspaceIdentitySha256 = $ws1; TabIdentitySha256 = $tab1; PaneIdentitySha256 = $pane1; OverviewOrder = 0; Status = 'Working'; Revision = 1; StateChangeSequence = 1; InteractiveReady = $true; LaunchPending = $false; ScreenDetectionSkipped = $false },
            [ordered]@{ AgentIdentitySha256 = $agent2; WorkspaceIdentitySha256 = $ws1; TabIdentitySha256 = $tab1; PaneIdentitySha256 = $pane2; OverviewOrder = 1; Status = 'Unknown'; Revision = 1; StateChangeSequence = 1; InteractiveReady = $false; LaunchPending = $false; ScreenDetectionSkipped = $false }
        )
        SelectedAgentIdentitySha256 = $null
    }
}

function New-Overview {
    return [ordered]@{
        TotalAgents = 2
        StatusCounts = @([ordered]@{ Status = 'Unknown'; Count = 1 }, [ordered]@{ Status = 'Working'; Count = 1 })
        WorkspaceAgentCounts = @([ordered]@{ WorkspaceIdentitySha256 = $ws1; AgentCount = 2 })
        VisibleTopAgents = @(
            [ordered]@{ AgentIdentitySha256 = $agent1; WorkspaceIdentitySha256 = $ws1; TabIdentitySha256 = $tab1; PaneIdentitySha256 = $pane1; Status = 'Working'; Revision = 1; StateChangeSequence = 1; InteractiveReady = $true; LaunchPending = $false; ScreenDetectionSkipped = $false },
            [ordered]@{ AgentIdentitySha256 = $agent2; WorkspaceIdentitySha256 = $ws1; TabIdentitySha256 = $tab1; PaneIdentitySha256 = $pane2; Status = 'Unknown'; Revision = 1; StateChangeSequence = 1; InteractiveReady = $false; LaunchPending = $false; ScreenDetectionSkipped = $false }
        )
    }
}

function New-LiveOrganization([long]$Sequence) {
    return [ordered]@{
        WorkspaceCount = 1; TabCount = 1; PaneCount = 3; AgentCount = 2
        UnassignedPaneCount = 1; UnknownAgentCount = 1; ProjectedNodeCount = 5
        SelectedAgentIdentitySha256 = $null
    }
}

function New-AgentDetail([long]$Sequence) {
    return [ordered]@{
        AgentSelected = $false; AgentIdentitySha256 = $null; WorkspaceIdentitySha256 = $null
        TabIdentitySha256 = $null; PaneIdentitySha256 = $null; Status = 'UnknownMissingSource'
        Revision = $null; StateChangeSequence = $null; SessionSequence = $Sequence; ConnectionEpoch = 1
        InteractiveReady = $null; LaunchPending = $null; ScreenDetectionSkipped = $null
        Assignment = 'UnknownMissingSource'; Tasks = 'UnknownMissingSource'; Evidence = 'UnknownMissingSource'
    }
}

function New-BoundCapture([string]$FileName,[long]$Sequence,[string]$StateHash,[string]$Language,[string]$Culture,[string]$ObservedUtc) {
    return [ordered]@{
        FileName = $FileName; Sha256 = (New-FixtureHash $FileName); PixelWidth = 4; PixelHeight = 4
        StateSequence = $Sequence; StateSha256 = $StateHash; Language = $Language; LanguageCultureName = $Culture
        ObservedUtc = $ObservedUtc
    }
}

function New-RuntimeCapture([string]$FileName,[long]$Sequence,[string]$StateHash,[string]$Language,[string]$Culture,[string]$ObservedUtc) {
    return [pscustomobject]@{
        Name = [IO.Path]::GetFileNameWithoutExtension($FileName); Path = "C:\fixture\$FileName"
        Sha256 = (New-FixtureHash $FileName); PixelWidth = 4; PixelHeight = 4
        StateSequence = $Sequence; StateSha256 = $StateHash; Language = $Language; LanguageCultureName = $Culture
        ObservedUtc = $ObservedUtc
    }
}

$initialNames = @('dashboard-overview.png','dashboard-live-organization.png','dashboard-agent-detail.png','widget-compact.png','widget-normal.png','widget-floating-vertical.png')
$eventANames = @('dashboard-overview-after-event.png')
$eventBNames = @('widget-floating-vertical-after-dashboard-close.png')

function New-Fixture([string]$Language) {
    $culture = if ($Language -ceq 'Thai') { 'th-TH' } else { 'en-US' }
    $hash1 = New-FixtureHash 'state-1'; $hash2 = New-FixtureHash 'state-2'; $hash3 = New-FixtureHash 'state-3'

    $captureOrdinal1 = [ordered]@{
        Ordinal = 1; Phase = 'initial'; EventBinding = 'InitialLiveState'
        BoundCaptures = @($initialNames | ForEach-Object { New-BoundCapture $_ 10 $hash1 $Language $culture $T0 })
        ObservedUtc = $T0; Sequence = 10; NormalizedStateSha256 = $hash1
        SourceState = New-SourceState 10; SourceStateSha256 = New-FixtureHash 'source-1'
        IsCoreConnected = $true; IsLive = $true
        Overview = New-Overview; LiveOrganization = New-LiveOrganization 10; AgentDetail = New-AgentDetail 10
        SemanticProjectionSha256 = New-FixtureHash 'projection-1'; CaptureStateSha256 = New-FixtureHash 'capture-1'
    }
    $captureOrdinal2 = [ordered]@{
        Ordinal = 2; Phase = 'event-a-pre-close'; EventBinding = 'EventA'
        BoundCaptures = @($eventANames | ForEach-Object { New-BoundCapture $_ 11 $hash2 $Language $culture $T2 })
        ObservedUtc = $T3; Sequence = 11; NormalizedStateSha256 = $hash2
        SourceState = New-SourceState 11; SourceStateSha256 = New-FixtureHash 'source-2'
        IsCoreConnected = $true; IsLive = $true
        Overview = New-Overview; LiveOrganization = New-LiveOrganization 11; AgentDetail = New-AgentDetail 11
        SemanticProjectionSha256 = New-FixtureHash 'projection-2'; CaptureStateSha256 = New-FixtureHash 'capture-2'
    }
    $captureOrdinal3 = [ordered]@{
        Ordinal = 3; Phase = 'post-close-final'; EventBinding = 'EventB'
        BoundCaptures = @($eventBNames | ForEach-Object { New-BoundCapture $_ 12 $hash3 $Language $culture $T5 })
        ObservedUtc = $T6; Sequence = 12; NormalizedStateSha256 = $hash3
        SourceState = New-SourceState 12; SourceStateSha256 = New-FixtureHash 'source-3'
        IsCoreConnected = $true; IsLive = $true
        Overview = New-Overview; LiveOrganization = New-LiveOrganization 12; AgentDetail = New-AgentDetail 12
        SemanticProjectionSha256 = New-FixtureHash 'projection-3'; CaptureStateSha256 = New-FixtureHash 'capture-3'
    }

    $appReportSource = [ordered]@{
        InitialSequence = 10; InitialStateSha256 = $hash1
        PreCloseSequence = 11; PreCloseStateSha256 = $hash2
        PostCloseSequence = 12; PostCloseStateSha256 = $hash3
        EventA = [ordered]@{ PhaseEnteredUtc = $T1; ObservedUtc = $T2 }
        EventB = [ordered]@{ PhaseEnteredUtc = $T4; ObservedUtc = $T5 }
        SemanticStateCaptures = @($captureOrdinal1, $captureOrdinal2, $captureOrdinal3)
    }
    $appReport = ConvertFrom-V02SemanticFixtureJson ($appReportSource | ConvertTo-Json -Depth 25)

    $runtimeCaptures = @()
    $runtimeCaptures += $initialNames | ForEach-Object { New-RuntimeCapture $_ 10 $hash1 $Language $culture $T0 }
    $runtimeCaptures += $eventANames | ForEach-Object { New-RuntimeCapture $_ 11 $hash2 $Language $culture $T2 }
    $runtimeCaptures += $eventBNames | ForEach-Object { New-RuntimeCapture $_ 12 $hash3 $Language $culture $T5 }

    return [pscustomobject]@{
        AppReport = $appReport
        RuntimeCaptures = $runtimeCaptures
        Language = $Language
        Culture = $culture
        ValidationUtc = [DateTimeOffset]::Parse($T7)
    }
}

function Copy-AppReport($AppReport) {
    return ConvertFrom-V02SemanticFixtureJson ($AppReport | ConvertTo-Json -Depth 25)
}

function Invoke-Fixture($Fixture, $AppReportOverride) {
    $report = if ($null -eq $AppReportOverride) { $Fixture.AppReport } else { $AppReportOverride }
    Assert-V02RuntimeSemanticStateCaptures -AppReport $report -RuntimeCaptures $Fixture.RuntimeCaptures `
        -ExpectedLanguage $Fixture.Language -ExpectedLanguageCultureName $Fixture.Culture -ValidationUtc $Fixture.ValidationUtc
}

$thaiFixture = New-Fixture 'Thai'
$englishFixture = New-Fixture 'English'

Test-Case 'valid Thai fixture is accepted (bilingual parity, positive)' { Invoke-Fixture $thaiFixture $null }
Test-Case 'valid English fixture is accepted (bilingual parity, positive)' { Invoke-Fixture $englishFixture $null }

Test-Case 'missing SemanticStateCaptures fails closed' {
    $mutated = Copy-AppReport $thaiFixture.AppReport
    $mutated.PSObject.Properties.Remove('SemanticStateCaptures')
    Invoke-Fixture $thaiFixture $mutated
} $true

Test-Case 'wrong SemanticStateCaptures count fails closed' {
    $mutated = Copy-AppReport $thaiFixture.AppReport
    $mutated.SemanticStateCaptures = @($mutated.SemanticStateCaptures[0], $mutated.SemanticStateCaptures[1])
    Invoke-Fixture $thaiFixture $mutated
} $true

Test-Case 'sequence tamper against Core-trace-bound phase sequence fails closed' {
    $mutated = Copy-AppReport $thaiFixture.AppReport
    $mutated.SemanticStateCaptures[1].Sequence = 999
    Invoke-Fixture $thaiFixture $mutated
} $true

Test-Case 'state-hash tamper against Core-trace-bound phase hash fails closed' {
    $mutated = Copy-AppReport $thaiFixture.AppReport
    $mutated.SemanticStateCaptures[1].NormalizedStateSha256 = New-FixtureHash 'tampered'
    Invoke-Fixture $thaiFixture $mutated
} $true

Test-Case 'wrong phase label against fixed catalog fails closed' {
    $mutated = Copy-AppReport $thaiFixture.AppReport
    $mutated.SemanticStateCaptures[1].Phase = 'wrong-phase'
    Invoke-Fixture $thaiFixture $mutated
} $true

Test-Case 'wrong event binding against fixed catalog fails closed' {
    $mutated = Copy-AppReport $thaiFixture.AppReport
    $mutated.SemanticStateCaptures[2].EventBinding = 'EventA'
    Invoke-Fixture $thaiFixture $mutated
} $true

Test-Case 'cross-language bound-capture leak fails closed (Thai run, English capture)' {
    $mutated = Copy-AppReport $thaiFixture.AppReport
    $mutated.SemanticStateCaptures[0].BoundCaptures[0].Language = 'English'
    $mutated.SemanticStateCaptures[0].BoundCaptures[0].LanguageCultureName = 'en-US'
    Invoke-Fixture $thaiFixture $mutated
} $true

Test-Case 'cross-language bound-capture leak fails closed (English run, Thai capture)' {
    $mutated = Copy-AppReport $englishFixture.AppReport
    $mutated.SemanticStateCaptures[0].BoundCaptures[0].Language = 'Thai'
    $mutated.SemanticStateCaptures[0].BoundCaptures[0].LanguageCultureName = 'th-TH'
    Invoke-Fixture $englishFixture $mutated
} $true

Test-Case 'out-of-order capture timestamp fails closed' {
    $mutated = Copy-AppReport $thaiFixture.AppReport
    $mutated.SemanticStateCaptures[1].ObservedUtc = $T0
    Invoke-Fixture $thaiFixture $mutated
} $true

Test-Case 'EventA observed after its bound capture fails closed' {
    $mutated = Copy-AppReport $thaiFixture.AppReport
    $mutated.EventA.ObservedUtc = $T6
    Invoke-Fixture $thaiFixture $mutated
} $true

Test-Case 'identity leak (raw non-hashed agent identity) fails closed' {
    $mutated = Copy-AppReport $thaiFixture.AppReport
    $mutated.SemanticStateCaptures[0].SourceState.Agents[0].AgentIdentitySha256 = 'w1:t1:p1'
    Invoke-Fixture $thaiFixture $mutated
} $true

Test-Case 'identity leak (lowercase hash treated as non-native) fails closed' {
    $mutated = Copy-AppReport $thaiFixture.AppReport
    $mutated.SemanticStateCaptures[0].SourceState.Panes[0].PaneIdentitySha256 = $mutated.SemanticStateCaptures[0].SourceState.Panes[0].PaneIdentitySha256.ToLowerInvariant()
    Invoke-Fixture $thaiFixture $mutated
} $true

Test-Case 'agent references workspace identity absent from bound set fails closed' {
    $mutated = Copy-AppReport $thaiFixture.AppReport
    $mutated.SemanticStateCaptures[0].SourceState.Agents[0].WorkspaceIdentitySha256 = New-FixtureHash 'unbound-workspace'
    Invoke-Fixture $thaiFixture $mutated
} $true

Test-Case 'duplicate agent identity fails closed' {
    $mutated = Copy-AppReport $thaiFixture.AppReport
    $mutated.SemanticStateCaptures[0].SourceState.Agents[1].AgentIdentitySha256 = $mutated.SemanticStateCaptures[0].SourceState.Agents[0].AgentIdentitySha256
    Invoke-Fixture $thaiFixture $mutated
} $true

Test-Case 'non-dense OverviewOrder fails closed' {
    $mutated = Copy-AppReport $thaiFixture.AppReport
    $mutated.SemanticStateCaptures[0].SourceState.Agents[1].OverviewOrder = 5
    Invoke-Fixture $thaiFixture $mutated
} $true

Test-Case 'IsCoreConnected false fails closed' {
    $mutated = Copy-AppReport $thaiFixture.AppReport
    $mutated.SemanticStateCaptures[0].IsCoreConnected = $false
    Invoke-Fixture $thaiFixture $mutated
} $true

Test-Case 'IsLive false fails closed' {
    $mutated = Copy-AppReport $thaiFixture.AppReport
    $mutated.SemanticStateCaptures[0].IsLive = $false
    Invoke-Fixture $thaiFixture $mutated
} $true

Test-Case 'bound-capture cross-reference sha256 mismatch against top-level runtime capture fails closed' {
    $mutated = Copy-AppReport $thaiFixture.AppReport
    $mutated.SemanticStateCaptures[0].BoundCaptures[0].Sha256 = New-FixtureHash 'tampered-capture'
    Invoke-Fixture $thaiFixture $mutated
} $true

Test-Case 'bound-capture referencing an unknown runtime capture file fails closed' {
    $mutated = Copy-AppReport $thaiFixture.AppReport
    $mutated.SemanticStateCaptures[0].BoundCaptures[0].FileName = 'unknown-file.png'
    Invoke-Fixture $thaiFixture $mutated
} $true

Test-Case 'bound-capture wrong order against fixed catalog fails closed' {
    $mutated = Copy-AppReport $thaiFixture.AppReport
    $first = $mutated.SemanticStateCaptures[0].BoundCaptures[0]
    $second = $mutated.SemanticStateCaptures[0].BoundCaptures[1]
    $mutated.SemanticStateCaptures[0].BoundCaptures[0] = $second
    $mutated.SemanticStateCaptures[0].BoundCaptures[1] = $first
    Invoke-Fixture $thaiFixture $mutated
} $true

Test-Case 'Overview.TotalAgents arithmetic tamper fails closed' {
    $mutated = Copy-AppReport $thaiFixture.AppReport
    $mutated.SemanticStateCaptures[0].Overview.TotalAgents = 99
    Invoke-Fixture $thaiFixture $mutated
} $true

Test-Case 'LiveOrganization.ProjectedNodeCount arithmetic tamper fails closed' {
    $mutated = Copy-AppReport $thaiFixture.AppReport
    $mutated.SemanticStateCaptures[0].LiveOrganization.ProjectedNodeCount = 99
    Invoke-Fixture $thaiFixture $mutated
} $true

Test-Case 'AgentDetail sentinel leak (real Assignment text) fails closed' {
    $mutated = Copy-AppReport $thaiFixture.AppReport
    $mutated.SemanticStateCaptures[0].AgentDetail.Assignment = 'Fix the login bug'
    Invoke-Fixture $thaiFixture $mutated
} $true

Test-Case 'hash-format tamper (lowercase SemanticProjectionSha256) fails closed' {
    $mutated = Copy-AppReport $thaiFixture.AppReport
    $mutated.SemanticStateCaptures[0].SemanticProjectionSha256 = $mutated.SemanticStateCaptures[0].SemanticProjectionSha256.ToLowerInvariant()
    Invoke-Fixture $thaiFixture $mutated
} $true

Test-Case 'hash-format tamper (short CaptureStateSha256) fails closed' {
    $mutated = Copy-AppReport $thaiFixture.AppReport
    $mutated.SemanticStateCaptures[0].CaptureStateSha256 = 'AB'
    Invoke-Fixture $thaiFixture $mutated
} $true

Test-Case 'SourceStateSha256 replayed identically across captures fails closed' {
    $mutated = Copy-AppReport $thaiFixture.AppReport
    $mutated.SemanticStateCaptures[1].SourceStateSha256 = $mutated.SemanticStateCaptures[0].SourceStateSha256
    $mutated.SemanticStateCaptures[2].SourceStateSha256 = $mutated.SemanticStateCaptures[0].SourceStateSha256
    Invoke-Fixture $thaiFixture $mutated
} $true

Test-Case 'CaptureStateSha256 replayed identically across captures fails closed' {
    $mutated = Copy-AppReport $thaiFixture.AppReport
    $mutated.SemanticStateCaptures[1].CaptureStateSha256 = $mutated.SemanticStateCaptures[0].CaptureStateSha256
    $mutated.SemanticStateCaptures[2].CaptureStateSha256 = $mutated.SemanticStateCaptures[0].CaptureStateSha256
    Invoke-Fixture $thaiFixture $mutated
} $true

if($failures.Count){$failures|ForEach-Object{Write-Host $_ -ForegroundColor Red};exit 1}
Write-Host 'All v0.2 runtime semantic-capture binding hostile tests passed.' -ForegroundColor Green
