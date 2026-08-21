[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$TargetHerdrSocketPath,

    [string]$HerdrExecutable = (Join-Path $env:LOCALAPPDATA 'Programs\Herdr\bin\herdr.exe'),

    [ValidateRange(90, 900)]
    [int]$DurationSeconds = 240,

    [ValidateRange(5, 120)]
    [int]$IdleSeconds = 20,

    [ValidateSet('Thai', 'English')]
    [string]$Language = 'Thai',

    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

. (Join-Path $PSScriptRoot 'lib/V02GateProvenance.ps1')

function Get-CleanSourceCommit {
    param([Parameter(Mandatory)][string]$Root)

    $commit = (& git -C $Root rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($commit)) {
        throw 'Could not resolve the source commit for the v0.2 live runtime gate.'
    }
    $changes = @(& git -C $Root status --porcelain --untracked-files=all)
    if ($LASTEXITCODE -ne 0) { throw 'Could not inspect repository status.' }
    if ($changes.Count -ne 0) {
        throw "Runtime evidence requires a clean source checkout. Changes: $($changes -join '; ')"
    }

    return $commit
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ControlHerdrServerIdentity {
    param([Parameter(Mandatory)][string]$ExpectedExecutablePath)

    $expectedPath = (Resolve-Path -LiteralPath $ExpectedExecutablePath).Path
    $currentProcessId = [int]$PID
    for ($depth = 0; $depth -lt 32; $depth++) {
        $processInfo = @(Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $currentProcessId")
        if ($processInfo.Count -ne 1) { break }

        $candidate = $processInfo[0]
        $candidatePath = [string]$candidate.ExecutablePath
        $candidateCommandLine = [string]$candidate.CommandLine
        if (-not [string]::IsNullOrWhiteSpace($candidatePath) -and
            [IO.Path]::GetFileName($candidatePath) -eq 'herdr.exe' -and
            $candidateCommandLine -match '(?:^|\s)server(?:\s|$)') {
            $resolvedCandidatePath = (Resolve-Path -LiteralPath $candidatePath).Path
            if (-not [StringComparer]::OrdinalIgnoreCase.Equals($resolvedCandidatePath, $expectedPath)) {
                throw "The Acceptance control pane belongs to an unexpected Herdr executable: $resolvedCandidatePath"
            }

            $runtimeProcess = Get-Process -Id ([int]$candidate.ProcessId) -ErrorAction Stop
            return [pscustomobject]@{
                ProcessId = [int]$candidate.ProcessId
                ProcessStartUtc = $runtimeProcess.StartTime.ToUniversalTime()
                ExecutablePath = $resolvedCandidatePath
                ExecutableSha256 = (Get-FileHash -LiteralPath $resolvedCandidatePath -Algorithm SHA256).Hash
            }
        }

        $parentProcessId = [int]$candidate.ParentProcessId
        if ($parentProcessId -le 0 -or $parentProcessId -eq $currentProcessId) { break }
        $currentProcessId = $parentProcessId
    }

    throw 'The gate process is not descended from a live Herdr server. Run it directly in a fresh Acceptance session pane.'
}

function Test-SameHerdrServerProcess {
    param(
        [Parameter(Mandatory)]$Left,
        [Parameter(Mandatory)]$Right
    )

    $leftStart = ([DateTimeOffset]$Left.ProcessStartUtc).ToUniversalTime()
    $rightStart = ([DateTimeOffset]$Right.ProcessStartUtc).ToUniversalTime()
    return [int]$Left.ProcessId -eq [int]$Right.ProcessId -and
        $leftStart.UtcDateTime.Ticks -eq $rightStart.UtcDateTime.Ticks
}

function Get-FreshTestCounts {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][DateTime]$StartedUtc
    )

    $trxFiles = @(Get-ChildItem -LiteralPath $Directory -Filter '*.trx' -File |
        Where-Object { $_.LastWriteTimeUtc -ge $StartedUtc.AddSeconds(-2) })
    if ($trxFiles.Count -ne 4) {
        throw "Expected four fresh TRX files, found $($trxFiles.Count)."
    }

    $total = 0
    $passed = 0
    $failed = 0
    foreach ($trxFile in $trxFiles) {
        [xml]$trx = Get-Content -LiteralPath $trxFile.FullName -Raw
        $counters = $trx.TestRun.ResultSummary.Counters
        $total += [int]$counters.total
        $passed += [int]$counters.passed
        $failed += [int]$counters.failed
    }
    if ($total -le 0 -or $failed -ne 0 -or $total -ne $passed) {
        throw "Fresh test counters are not all passing: total=$total passed=$passed failed=$failed"
    }

    return [pscustomobject]@{ Total = $total; Passed = $passed; Failed = $failed }
}

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) { throw $Message }
}

function Test-FiniteNumber {
    param([Parameter(Mandatory)][double]$Value)

    return -not [double]::IsNaN($Value) -and -not [double]::IsInfinity($Value)
}

function Get-TextSha256 {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
        return ([BitConverter]::ToString($sha256.ComputeHash($bytes))).Replace('-', '').ToUpperInvariant()
    } finally {
        $sha256.Dispose()
    }
}

function Get-OptionalFileSha256 {
    param([AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or
        -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return 'MISSING'
    }

    try {
        return ((Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash).ToUpperInvariant()
    } catch {
        return 'UNAVAILABLE'
    }
}

function Write-FailureGateReport {
    param(
        [Parameter(Mandatory)][string]$GateReportPath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$FailureMessage,
        [AllowEmptyString()][string]$SourceCommit = 'UNRESOLVED',
        [AllowEmptyString()][string]$CoreReportPath = '',
        [AllowEmptyString()][string]$AppReportPath = '',
        [AllowEmptyString()][string]$ProgressHistoryPath = '',
        [AllowEmptyString()][string]$CoreExecutableHashBeforeLaunch = 'NOT_OBSERVED',
        [AllowEmptyString()][string]$CoreExecutableHashAfterRun = 'NOT_OBSERVED',
        [AllowEmptyString()][string]$AppExecutableHashBeforeLaunch = 'NOT_OBSERVED',
        [AllowEmptyString()][string]$AppExecutableHashAfterRun = 'NOT_OBSERVED',
        [AllowEmptyString()][string]$AppExitCode = 'NOT_OBSERVED',
        [AllowEmptyString()][string]$CoreExitCode = 'NOT_OBSERVED',
        [AllowEmptyString()][string]$CoreAcceptedEventKindCheck = 'NOT_EVALUATED',
        [AllowEmptyString()][string]$FailureType = 'TerminatingFailure'
    )

    try {
        $parentDirectory = Split-Path -Parent $GateReportPath
        if (-not [string]::IsNullOrWhiteSpace($parentDirectory)) {
            New-Item -ItemType Directory -Path $parentDirectory -Force -ErrorAction SilentlyContinue | Out-Null
        }

        $reportLines = @(
            'HerdrOps v0.2 Composite Actual Herdr Runtime Acceptance',
            "GeneratedUtc: $([DateTimeOffset]::UtcNow.ToString('O'))",
            "SourceCommit: $SourceCommit",
            'Result: FAIL',
            'EvidenceClass: NoRuntimeCredit',
            'SessionControlInvoked: false',
            "FailureType: $FailureType",
            "OriginalAppExitCode: $AppExitCode",
            "OriginalCoreExitCode: $CoreExitCode",
            "CoreAcceptedEventKindCheck: $CoreAcceptedEventKindCheck",
            "CoreRuntimeReportPath: $CoreReportPath",
            "CoreRuntimeReportSha256: $(Get-OptionalFileSha256 -Path $CoreReportPath)",
            "AppRuntimeReportPath: $AppReportPath",
            "AppRuntimeReportSha256: $(Get-OptionalFileSha256 -Path $AppReportPath)",
            "ProgressHistoryPath: $ProgressHistoryPath",
            "ProgressHistorySha256: $(Get-OptionalFileSha256 -Path $ProgressHistoryPath)",
            "HerdrOpsCoreExecutableSha256BeforeLaunch: $CoreExecutableHashBeforeLaunch",
            "HerdrOpsCoreExecutableSha256AfterRun: $CoreExecutableHashAfterRun",
            "HerdrOpsAppExecutableSha256BeforeLaunch: $AppExecutableHashBeforeLaunch",
            "HerdrOpsAppExecutableSha256AfterRun: $AppExecutableHashAfterRun",
            "Failure: $FailureMessage"
        )
        $reportLines | Set-Content -LiteralPath $GateReportPath -Encoding UTF8 -ErrorAction Stop
    } catch {
        # Never mask the original failure when the diagnostic report itself cannot be written.
        Write-Warning "Could not write failure gate report '$GateReportPath': $($_.Exception.Message)"
    }
}

function Test-ObjectHasProperty {
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string]$Name
    )

    return $null -ne $Object.PSObject.Properties[$Name]
}

function Get-ProgressUtcTicks {
    param([AllowNull()]$Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $null
    }
    return ([DateTimeOffset]$Value).ToUniversalTime().UtcDateTime.Ticks
}

function Assert-ProgressEntryIntegrity {
    param(
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)][int]$ExpectedOrdinal,
        [Parameter(Mandatory)][string]$ExpectedPreviousEntrySha256,
        [Parameter(Mandatory)][string]$Context
    )

    foreach ($field in @(
        'Ordinal',
        'Phase',
        'ObservedUtc',
        'Sequence',
        'IsCoreConnected',
        'IsLive',
        'RuntimeStatus',
        'LastTransitionUtc',
        'LastAcceptedStateUtc',
        'ConnectionEpoch',
        'BootstrapCount',
        'EventCount',
        'DisconnectCount',
        'ReconciliationCount',
        'StateSha256',
        'PreviousEntrySha256',
        'CanonicalPayload',
        'EntrySha256'
    )) {
        Assert-True (Test-ObjectHasProperty -Object $Entry -Name $field) "$Context omitted required field '$field'."
    }

    Assert-True ($Entry.IsCoreConnected -is [bool]) "$Context IsCoreConnected is not a JSON boolean."
    Assert-True ($Entry.IsLive -is [bool]) "$Context IsLive is not a JSON boolean."
    Assert-True ([int]$Entry.Ordinal -eq $ExpectedOrdinal) "$Context ordinal is not $ExpectedOrdinal."
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$Entry.Phase)) "$Context phase is empty."
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$Entry.RuntimeStatus)) "$Context runtime status is empty."
    Assert-True ([string]$Entry.StateSha256 -match '^[0-9A-Fa-f]{64}$') "$Context state SHA-256 is invalid."
    Assert-True ([string]$Entry.PreviousEntrySha256 -match '^[0-9A-Fa-f]{64}$') "$Context previous-entry SHA-256 is invalid."
    Assert-True ([string]$Entry.PreviousEntrySha256 -eq $ExpectedPreviousEntrySha256) "$Context previous-entry SHA-256 is not bound to the preceding record."
    Assert-True ([string]$Entry.EntrySha256 -match '^[0-9A-Fa-f]{64}$') "$Context entry SHA-256 is invalid."

    try {
        $null = [DateTimeOffset]$Entry.ObservedUtc
        $null = [DateTimeOffset]$Entry.LastTransitionUtc
        if ($null -ne $Entry.LastAcceptedStateUtc) {
            $null = [DateTimeOffset]$Entry.LastAcceptedStateUtc
        }
        $null = [long]$Entry.Sequence
        $null = [long]$Entry.ConnectionEpoch
        $null = [long]$Entry.BootstrapCount
        $null = [long]$Entry.EventCount
        $null = [long]$Entry.DisconnectCount
        $null = [long]$Entry.ReconciliationCount
    } catch {
        throw "$Context contains a non-canonical typed value: $($_.Exception.Message)"
    }

    $reconstructedPayload = Get-ProgressCanonicalPayload -Entry $Entry
    Assert-True ([string]$Entry.CanonicalPayload -eq $reconstructedPayload) "$Context canonical payload does not match all visible fields."
    $computedEntrySha256 = Get-TextSha256 -Text ([string]$Entry.CanonicalPayload)
    Assert-True ($computedEntrySha256 -eq ([string]$Entry.EntrySha256).ToUpperInvariant()) "$Context entry SHA-256 does not match its canonical payload."
}

function Assert-ProgressEntryEquals {
    param(
        [Parameter(Mandatory)]$Expected,
        [Parameter(Mandatory)]$Actual,
        [Parameter(Mandatory)][string]$Context,
        [switch]$IncludeChainFields
    )

    foreach ($field in @(
        'Ordinal',
        'Sequence',
        'ConnectionEpoch',
        'BootstrapCount',
        'EventCount',
        'DisconnectCount',
        'ReconciliationCount'
    )) {
        Assert-True ([long]$Expected.$field -eq [long]$Actual.$field) "$Context field '$field' differs."
    }
    $stringFields = @('Phase', 'RuntimeStatus', 'StateSha256', 'EntrySha256')
    if ($IncludeChainFields) {
        $stringFields += @('PreviousEntrySha256', 'CanonicalPayload')
    }
    foreach ($field in $stringFields) {
        Assert-True ([string]$Expected.$field -eq [string]$Actual.$field) "$Context field '$field' differs."
    }
    Assert-True ([bool]$Expected.IsCoreConnected -eq [bool]$Actual.IsCoreConnected) "$Context field 'IsCoreConnected' differs."
    Assert-True ([bool]$Expected.IsLive -eq [bool]$Actual.IsLive) "$Context field 'IsLive' differs."
    Assert-True ((Get-ProgressUtcTicks $Expected.ObservedUtc) -eq (Get-ProgressUtcTicks $Actual.ObservedUtc)) "$Context field 'ObservedUtc' differs."
    Assert-True ((Get-ProgressUtcTicks $Expected.LastTransitionUtc) -eq (Get-ProgressUtcTicks $Actual.LastTransitionUtc)) "$Context field 'LastTransitionUtc' differs."
    Assert-True ((Get-ProgressUtcTicks $Expected.LastAcceptedStateUtc) -eq (Get-ProgressUtcTicks $Actual.LastAcceptedStateUtc)) "$Context field 'LastAcceptedStateUtc' differs."
}

function Assert-ProgressTopLevelPointer {
    param(
        [Parameter(Mandatory)]$ProgressReport,
        [Parameter(Mandatory)]$FinalEntry
    )

    $pointerFields = @(
        'Ordinal',
        'Phase',
        'ObservedUtc',
        'Sequence',
        'IsCoreConnected',
        'IsLive',
        'RuntimeStatus',
        'LastTransitionUtc',
        'LastAcceptedStateUtc',
        'ConnectionEpoch',
        'BootstrapCount',
        'EventCount',
        'DisconnectCount',
        'ReconciliationCount',
        'StateSha256',
        'PreviousEntrySha256',
        'CanonicalPayload',
        'EntrySha256'
    )
    foreach ($field in $pointerFields) {
        Assert-True (Test-ObjectHasProperty -Object $ProgressReport -Name $field) "The final App progress report omitted pointer field '$field'."
        Assert-True (Test-ObjectHasProperty -Object $FinalEntry -Name $field) "The final App progress history omitted pointer field '$field'."
    }

    Assert-ProgressEntryEquals `
        -Expected $FinalEntry `
        -Actual $ProgressReport `
        -Context 'Final App progress pointer' `
        -IncludeChainFields
}

function Get-ProgressCanonicalPayload {
    param([Parameter(Mandatory)]$Entry)

    $culture = [Globalization.CultureInfo]::InvariantCulture
    $lastAcceptedStateUtc = ''
    if ($null -ne $Entry.LastAcceptedStateUtc) {
        $lastAcceptedStateUtc = ([DateTimeOffset]$Entry.LastAcceptedStateUtc).ToUniversalTime().ToString('O', $culture)
    }
    $isCoreConnected = if ([bool]$Entry.IsCoreConnected) { 'True' } else { 'False' }
    $isLive = if ([bool]$Entry.IsLive) { 'True' } else { 'False' }
    return @(
        ([int]$Entry.Ordinal).ToString($culture),
        [string]$Entry.Phase,
        ([DateTimeOffset]$Entry.ObservedUtc).ToUniversalTime().ToString('O', $culture),
        ([long]$Entry.Sequence).ToString($culture),
        $isCoreConnected,
        $isLive,
        [string]$Entry.RuntimeStatus,
        ([DateTimeOffset]$Entry.LastTransitionUtc).ToUniversalTime().ToString('O', $culture),
        $lastAcceptedStateUtc,
        ([long]$Entry.ConnectionEpoch).ToString($culture),
        ([long]$Entry.BootstrapCount).ToString($culture),
        ([long]$Entry.EventCount).ToString($culture),
        ([long]$Entry.DisconnectCount).ToString($culture),
        ([long]$Entry.ReconciliationCount).ToString($culture),
        [string]$Entry.StateSha256,
        [string]$Entry.PreviousEntrySha256
    ) -join '|'
}

function Assert-ProgressCanonicalKnownVector {
    $entry = [pscustomobject]@{
        Ordinal = 7
        Phase = 'herdr-reconnected-waiting-for-post-reconnect-update'
        ObservedUtc = [DateTimeOffset]::Parse('2026-08-16T03:04:05.6789012Z')
        Sequence = 42L
        IsCoreConnected = $true
        IsLive = $true
        RuntimeStatus = 'Connected'
        LastTransitionUtc = [DateTimeOffset]::Parse('2026-08-16T03:04:04Z')
        LastAcceptedStateUtc = [DateTimeOffset]::Parse('2026-08-16T03:04:04.1Z')
        ConnectionEpoch = 2L
        BootstrapCount = 2L
        EventCount = 5L
        DisconnectCount = 1L
        ReconciliationCount = 4L
        StateSha256 = ('A' * 64)
        PreviousEntrySha256 = ('B' * 64)
    }
    $expectedCanonicalPayload = '7|herdr-reconnected-waiting-for-post-reconnect-update|2026-08-16T03:04:05.6789012+00:00|42|True|True|Connected|2026-08-16T03:04:04.0000000+00:00|2026-08-16T03:04:04.1000000+00:00|2|2|5|1|4|AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA|BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB'
    $expectedEntrySha256 = '611438DAE5CDE605590DF7DA1FB2B48F78F9EE3675F62588E34D849E46E9B564'
    $canonicalPayload = Get-ProgressCanonicalPayload -Entry $entry
    Assert-True ($canonicalPayload -eq $expectedCanonicalPayload) 'PowerShell 5.1 progress canonicalization differs from the C# known vector.'
    Assert-True ((Get-TextSha256 -Text $canonicalPayload) -eq $expectedEntrySha256) 'PowerShell 5.1 progress SHA-256 differs from the C# known vector.'

    $entry.EventCount = 6L
    Assert-True ((Get-ProgressCanonicalPayload -Entry $entry) -ne $expectedCanonicalPayload) 'Progress canonicalization did not expose visible-field tampering.'
}

function Assert-RuntimeFingerprintEqual {
    param(
        [Parameter(Mandatory)]$Expected,
        [Parameter(Mandatory)]$Actual,
        [Parameter(Mandatory)][string]$Context
    )

    foreach ($field in @(
        'IsCoreConnected',
        'IsLive',
        'RuntimeStatus',
        'ConnectionEpoch',
        'LastIngestSequence',
        'BootstrapCount',
        'EventCount',
        'DisconnectCount',
        'ReconciliationCount',
        'StateSha256'
    )) {
        Assert-True ($Expected.$field -eq $Actual.$field) "$Context fingerprint field '$field' differs."
    }

    $expectedTransitionUtc = ([DateTimeOffset]$Expected.LastTransitionUtc).UtcDateTime.Ticks
    $actualTransitionUtc = ([DateTimeOffset]$Actual.LastTransitionUtc).UtcDateTime.Ticks
    Assert-True ($expectedTransitionUtc -eq $actualTransitionUtc) "$Context fingerprint LastTransitionUtc differs."

    if ($null -eq $Expected.LastAcceptedStateUtc -or $null -eq $Actual.LastAcceptedStateUtc) {
        Assert-True ($null -eq $Expected.LastAcceptedStateUtc -and $null -eq $Actual.LastAcceptedStateUtc) "$Context fingerprint LastAcceptedStateUtc differs."
    } else {
        $expectedAcceptedUtc = ([DateTimeOffset]$Expected.LastAcceptedStateUtc).UtcDateTime.Ticks
        $actualAcceptedUtc = ([DateTimeOffset]$Actual.LastAcceptedStateUtc).UtcDateTime.Ticks
        Assert-True ($expectedAcceptedUtc -eq $actualAcceptedUtc) "$Context fingerprint LastAcceptedStateUtc differs."
    }

    Assert-True ([string]$Expected.StateSha256 -match '^[0-9A-Fa-f]{64}$') "$Context expected fingerprint state hash is invalid."
    Assert-True ([string]$Actual.StateSha256 -match '^[0-9A-Fa-f]{64}$') "$Context actual fingerprint state hash is invalid."
}

function Assert-AgentStatusTransitionEvidence {
    param(
        [Parameter(Mandatory)]$Evidence,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][array]$CoreTransitions,
        [Parameter(Mandatory)]$BaselineProgress
    )

    Assert-True ($null -ne $Evidence) "$Name evidence is missing from the App report."
    Assert-True ([string]$Evidence.AcceptedEventKind -eq 'pane.agent_status_changed') "$Name did not declare the accepted Agent-status event kind."
    $admissionPath = [string]$Evidence.AdmissionPath
    Assert-True ($admissionPath -in @('direct-event', 'snapshot-before-event')) "$Name declared an unsupported admission path."
    $changes = @($Evidence.Changes)
    Assert-True ($changes.Count -eq 1) "$Name did not contain exactly one genuine Agent-status change."

    foreach ($change in $changes) {
        $changeIdentity = @(
            [string]$change.TerminalId,
            [string]$change.WorkspaceId,
            [string]$change.TabId,
            [string]$change.PaneId
        ) -join '|'
        Assert-True (-not [string]::IsNullOrWhiteSpace($changeIdentity.Replace('|', ''))) "$Name did not identify a concrete Agent terminal/pane."
        Assert-True (-not [string]::IsNullOrWhiteSpace([string]$change.PreviousStatus)) "$Name omitted the previous Agent status."
        Assert-True (-not [string]::IsNullOrWhiteSpace([string]$change.CurrentStatus)) "$Name omitted the current Agent status."
        Assert-True ([string]$change.PreviousStatus -ne [string]$change.CurrentStatus) "$Name did not change the Agent status."
        Assert-True (([UInt64]$change.CurrentStateChangeSequence - [UInt64]$change.PreviousStateChangeSequence) -eq 1) "$Name did not advance the Agent state-change sequence exactly once."
        Assert-True ([UInt64]$change.CurrentRevision -ge [UInt64]$change.PreviousRevision) "$Name regressed the Agent revision."
    }

    $phaseEnteredUtc = ([DateTimeOffset]$Evidence.PhaseEnteredUtc).ToUniversalTime()
    $observedUtc = ([DateTimeOffset]$Evidence.ObservedUtc).ToUniversalTime()
    Assert-True ($observedUtc -ge $phaseEnteredUtc) "$Name was observed before its phase began."
    Assert-True (([DateTimeOffset]$BaselineProgress.ObservedUtc).ToUniversalTime().UtcDateTime.Ticks -eq $phaseEnteredUtc.UtcDateTime.Ticks) "$Name phase entry is not bound to its progress record."
    Assert-True ([long]$Evidence.BaselineSequence -eq [long]$BaselineProgress.Sequence) "$Name baseline sequence is not bound to its progress record."
    Assert-True ([long]$Evidence.BaselineEventCount -eq [long]$BaselineProgress.EventCount) "$Name baseline event count is not bound to its progress record."
    Assert-True ([long]$Evidence.BaselineBootstrapCount -eq [long]$BaselineProgress.BootstrapCount) "$Name baseline bootstrap count is not bound to its progress record."
    Assert-True ([long]$Evidence.BaselineDisconnectCount -eq [long]$BaselineProgress.DisconnectCount) "$Name baseline disconnect count is not bound to its progress record."
    Assert-True ([long]$Evidence.BaselineReconciliationCount -eq [long]$BaselineProgress.ReconciliationCount) "$Name baseline reconciliation count is not bound to its progress record."
    Assert-True ([string]$Evidence.BaselineStateSha256 -eq [string]$BaselineProgress.StateSha256) "$Name baseline state hash is not bound to its progress record."
    Assert-True ([long]$Evidence.BaselineConnectionEpoch -eq [long]$BaselineProgress.ConnectionEpoch) "$Name baseline connection epoch is not bound to its progress record."
    Assert-True ([long]$Evidence.ConnectionEpoch -eq [long]$Evidence.BaselineConnectionEpoch) "$Name changed connection epoch during Event admission."
    Assert-True ([bool]$Evidence.CurrentIsCoreConnected) "$Name was admitted while the App was disconnected from Core."
    Assert-True ([bool]$Evidence.CurrentIsLive) "$Name was admitted while the App was not live."
    Assert-True ([string]$Evidence.CurrentRuntimeStatus -eq 'Connected') "$Name was admitted from a non-Connected runtime status."
    $sequenceDelta = [long]$Evidence.CurrentSequence - [long]$Evidence.BaselineSequence
    Assert-True ([long]$Evidence.CurrentEventCount -eq ([long]$Evidence.BaselineEventCount + 1)) "$Name did not advance the runtime event count by exactly one."
    Assert-True ([long]$Evidence.CurrentBootstrapCount -eq [long]$Evidence.BaselineBootstrapCount) "$Name changed BootstrapCount during the Agent-status transition."
    Assert-True ([long]$Evidence.CurrentDisconnectCount -eq [long]$Evidence.BaselineDisconnectCount) "$Name changed DisconnectCount during the Agent-status transition."
    $reconciliationDelta = [long]$Evidence.CurrentReconciliationCount - [long]$Evidence.BaselineReconciliationCount
    if ($admissionPath -eq 'direct-event') {
        Assert-True ($sequenceDelta -eq 1) "$Name direct Event did not advance the state sequence by exactly one."
        Assert-True ($reconciliationDelta -eq 1) "$Name direct Event did not reconcile exactly once."
    } else {
        Assert-True ($sequenceDelta -eq 2) "$Name snapshot-before-event path did not contain exactly one leading state sequence."
        Assert-True ($reconciliationDelta -ge 1 -and $reconciliationDelta -le 2) "$Name snapshot-before-event reconciliation delta was outside 1..2."
    }
    Assert-True ([string]$Evidence.BaselineStateSha256 -match '^[0-9A-Fa-f]{64}$') "$Name baseline state hash is invalid."
    Assert-True ([string]$Evidence.CurrentStateSha256 -match '^[0-9A-Fa-f]{64}$') "$Name current state hash is invalid."
    Assert-True ([string]$Evidence.BaselineStateSha256 -ne [string]$Evidence.CurrentStateSha256) "$Name did not change the full state hash."
    foreach ($hashField in @(
        'BaselineAgentTopologySha256',
        'CurrentAgentTopologySha256',
        'BaselineAgentStatusStateSha256',
        'CurrentAgentStatusStateSha256'
    )) {
        Assert-True ([string]$Evidence.$hashField -match '^[0-9A-Fa-f]{64}$') "$Name $hashField is invalid."
    }
    Assert-True ([string]$Evidence.BaselineAgentTopologySha256 -eq [string]$Evidence.CurrentAgentTopologySha256) "$Name changed Agent topology during Event admission."
    Assert-True ([string]$Evidence.BaselineAgentStatusStateSha256 -ne [string]$Evidence.CurrentAgentStatusStateSha256) "$Name did not change the Agent status-state fingerprint."

    $matchingBaselineTransitions = @($CoreTransitions | Where-Object {
        $_.Status -eq 'Connected' -and
        [long]$_.IngestSequence -eq [long]$Evidence.BaselineSequence -and
        [long]$_.EventCount -eq [long]$Evidence.BaselineEventCount -and
        [long]$_.ConnectionEpoch -eq [long]$Evidence.ConnectionEpoch -and
        [string]$_.ContractStateSha256 -eq [string]$Evidence.BaselineStateSha256 -and
        ([DateTimeOffset]$_.ObservedUtc).ToUniversalTime() -le $phaseEnteredUtc
    })
    Assert-True ($matchingBaselineTransitions.Count -ge 1) "$Name has no exact Core transition correlation for its progress-bound baseline."
    $baselineTransition = $matchingBaselineTransitions[$matchingBaselineTransitions.Count - 1]
    Assert-AllAgentsHaveLiveIdentity -Transition $baselineTransition -Name "$Name baseline"
    Assert-True ([long]$baselineTransition.BootstrapCount -eq [long]$Evidence.BaselineBootstrapCount) "$Name Core baseline BootstrapCount differs from App evidence."
    Assert-True ([long]$baselineTransition.DisconnectCount -eq [long]$Evidence.BaselineDisconnectCount) "$Name Core baseline DisconnectCount differs from App evidence."
    Assert-True ([long]$baselineTransition.ReconciliationCount -eq [long]$Evidence.BaselineReconciliationCount) "$Name Core baseline ReconciliationCount differs from App evidence."
    Assert-True ([string]$baselineTransition.AgentTopologySha256 -eq [string]$Evidence.BaselineAgentTopologySha256) "$Name Core baseline Agent topology differs from App evidence."
    Assert-True ([string]$baselineTransition.AgentStatusStateSha256 -eq [string]$Evidence.BaselineAgentStatusStateSha256) "$Name Core baseline Agent status-state differs from App evidence."

    $expectedTransitionCount = if ($admissionPath -eq 'direct-event') { 1 } else { 2 }
    $phaseTransitions = @($CoreTransitions | Where-Object {
        ([DateTimeOffset]$_.ObservedUtc).ToUniversalTime() -ge $phaseEnteredUtc -and
        ([DateTimeOffset]$_.ObservedUtc).ToUniversalTime() -le $observedUtc
    } | Sort-Object @{ Expression = { [long]$_.IngestSequence } }, @{ Expression = { ([DateTimeOffset]$_.ObservedUtc).UtcDateTime.Ticks } })
    Assert-True ($phaseTransitions.Count -eq $expectedTransitionCount) "$Name contained an unexpected number of Core transitions after its progress-bound baseline."
    for ($transitionIndex = 0; $transitionIndex -lt $phaseTransitions.Count; $transitionIndex++) {
        $phaseTransition = $phaseTransitions[$transitionIndex]
        Assert-True ($phaseTransition.Status -eq 'Connected') "$Name contained a non-Connected Core transition."
        Assert-True ([long]$phaseTransition.IngestSequence -eq ([long]$Evidence.BaselineSequence + $transitionIndex + 1)) "$Name Core transition sequence was not contiguous."
        Assert-True ([long]$phaseTransition.ConnectionEpoch -eq [long]$Evidence.ConnectionEpoch) "$Name Core transition changed ConnectionEpoch."
        Assert-True ([long]$phaseTransition.BootstrapCount -eq [long]$Evidence.BaselineBootstrapCount) "$Name Core transition changed BootstrapCount."
        Assert-True ([long]$phaseTransition.DisconnectCount -eq [long]$Evidence.BaselineDisconnectCount) "$Name Core transition changed DisconnectCount."
        if ($null -ne $baselineTransition.ServerIdentity -and $null -ne $phaseTransition.ServerIdentity) {
            Assert-True (Test-SameHerdrServerProcess -Left $baselineTransition.ServerIdentity -Right $phaseTransition.ServerIdentity) "$Name Core transition changed target server identity."
        }
    }

    $leadingReconciliation = $null
    if ($admissionPath -eq 'snapshot-before-event') {
        $leadingCandidates = @($CoreTransitions | Where-Object {
            $_.Status -eq 'Connected' -and
            [long]$_.IngestSequence -eq ([long]$Evidence.BaselineSequence + 1) -and
            [long]$_.EventCount -eq [long]$Evidence.BaselineEventCount -and
            [long]$_.ConnectionEpoch -eq [long]$Evidence.ConnectionEpoch -and
            ([DateTimeOffset]$_.ObservedUtc).ToUniversalTime() -ge $phaseEnteredUtc -and
            ([DateTimeOffset]$_.ObservedUtc).ToUniversalTime() -le $observedUtc
        })
        Assert-True ($leadingCandidates.Count -eq 1) "$Name did not contain exactly one Core snapshot reconciliation before the Event."
        $leadingReconciliation = $leadingCandidates[0]
        Assert-AllAgentsHaveLiveIdentity -Transition $leadingReconciliation -Name "$Name leading reconciliation"
        Assert-True ([long]$leadingReconciliation.BootstrapCount -eq [long]$Evidence.BaselineBootstrapCount) "$Name leading reconciliation changed BootstrapCount."
        Assert-True ([long]$leadingReconciliation.DisconnectCount -eq [long]$Evidence.BaselineDisconnectCount) "$Name leading reconciliation changed DisconnectCount."
        Assert-True ([long]$leadingReconciliation.ReconciliationCount -eq ([long]$Evidence.BaselineReconciliationCount + 1)) "$Name leading reconciliation did not advance ReconciliationCount exactly once."
        Assert-True ([long]$leadingReconciliation.ConnectionEpoch -eq [long]$baselineTransition.ConnectionEpoch) "$Name leading reconciliation changed ConnectionEpoch."
        Assert-True ([string]$leadingReconciliation.ContractStateSha256 -match '^[0-9A-Fa-f]{64}$') "$Name leading reconciliation state hash is invalid."
        Assert-True ([string]$leadingReconciliation.ContractStateSha256 -ne [string]$Evidence.BaselineStateSha256) "$Name leading reconciliation did not change state."
        Assert-True ([string]::IsNullOrWhiteSpace([string]$leadingReconciliation.AcceptedEventKind)) "$Name leading reconciliation was incorrectly labelled as an accepted Event."
        Assert-True ((-not (Test-ObjectHasProperty -Object $leadingReconciliation -Name 'AcceptedAgentStatusEvent')) -or $null -eq $leadingReconciliation.AcceptedAgentStatusEvent) "$Name leading reconciliation carried accepted Agent-event provenance."
        Assert-True ([string]$leadingReconciliation.AgentTopologySha256 -eq [string]$Evidence.BaselineAgentTopologySha256) "$Name leading reconciliation changed Agent topology."
        Assert-True ([string]$leadingReconciliation.AgentStatusStateSha256 -in @(
            [string]$Evidence.BaselineAgentStatusStateSha256,
            [string]$Evidence.CurrentAgentStatusStateSha256
        )) "$Name leading reconciliation contained an unrelated or collapsed Agent-status change."
    }

    $matchingTransitions = @($CoreTransitions | Where-Object {
        $_.Status -eq 'Connected' -and
        [long]$_.IngestSequence -eq [long]$Evidence.CurrentSequence -and
        [long]$_.EventCount -eq [long]$Evidence.CurrentEventCount -and
        [long]$_.ConnectionEpoch -eq [long]$Evidence.ConnectionEpoch -and
        [string]$_.ContractStateSha256 -eq [string]$Evidence.CurrentStateSha256 -and
        ([DateTimeOffset]$_.ObservedUtc).ToUniversalTime() -ge $phaseEnteredUtc -and
        ([DateTimeOffset]$_.ObservedUtc).ToUniversalTime() -le $observedUtc
    })
    Assert-True ($matchingTransitions.Count -eq 1) "$Name does not have exactly one Core transition correlation for its same-Agent status change."
    $currentTransition = $matchingTransitions[0]
    Assert-AllAgentsHaveLiveIdentity -Transition $currentTransition -Name "$Name current"
    Assert-True ([long]$currentTransition.BootstrapCount -eq [long]$Evidence.CurrentBootstrapCount) "$Name Core current BootstrapCount differs from App evidence."
    Assert-True ([long]$currentTransition.DisconnectCount -eq [long]$Evidence.CurrentDisconnectCount) "$Name Core current DisconnectCount differs from App evidence."
    Assert-True ([long]$currentTransition.ReconciliationCount -eq [long]$Evidence.CurrentReconciliationCount) "$Name Core current ReconciliationCount differs from App evidence."
    Assert-True ([long]$currentTransition.ConnectionEpoch -eq [long]$baselineTransition.ConnectionEpoch) "$Name changed ConnectionEpoch during the Agent-status transition."
    Assert-True ([string]$currentTransition.AgentTopologySha256 -eq [string]$Evidence.CurrentAgentTopologySha256) "$Name Core current Agent topology differs from App evidence."
    Assert-True ([string]$currentTransition.AgentStatusStateSha256 -eq [string]$Evidence.CurrentAgentStatusStateSha256) "$Name Core current Agent status-state differs from App evidence."
    Assert-True (Test-ObjectHasProperty -Object $currentTransition -Name 'AcceptedEventKind') "$Name Core transition omitted AcceptedEventKind."
    Assert-True ([string]$currentTransition.AcceptedEventKind -eq 'pane.agent_status_changed') "$Name Core transition AcceptedEventKind was not pane.agent_status_changed."
    Assert-True (Test-ObjectHasProperty -Object $currentTransition -Name 'AcceptedAgentStatusEvent') "$Name Core transition omitted accepted Agent-event provenance."
    Assert-True ($null -ne $currentTransition.AcceptedAgentStatusEvent) "$Name Core transition has null accepted Agent-event provenance."
    $acceptedAgentEvent = $currentTransition.AcceptedAgentStatusEvent
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$acceptedAgentEvent.WorkspaceId)) "$Name accepted Agent Event omitted WorkspaceId."
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$acceptedAgentEvent.PaneId)) "$Name accepted Agent Event omitted PaneId."
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$acceptedAgentEvent.AgentStatus)) "$Name accepted Agent Event omitted AgentStatus."
    $matchingAcceptedChanges = @($changes | Where-Object {
        [string]$_.WorkspaceId -eq [string]$acceptedAgentEvent.WorkspaceId -and
        [string]$_.PaneId -eq [string]$acceptedAgentEvent.PaneId -and
        [string]$_.CurrentStatus -eq [string]$acceptedAgentEvent.AgentStatus
    })
    Assert-True ($matchingAcceptedChanges.Count -eq 1) "$Name accepted Event provenance does not identify exactly one same-pane App Agent-status change."
    if ($null -ne $leadingReconciliation) {
        Assert-True ([long]$currentTransition.ReconciliationCount -ge [long]$leadingReconciliation.ReconciliationCount) "$Name Event regressed ReconciliationCount after the leading snapshot."
        Assert-True ([long]$currentTransition.ReconciliationCount -le ([long]$leadingReconciliation.ReconciliationCount + 1)) "$Name Event performed more than one reconciliation after the leading snapshot."
        Assert-True (([DateTimeOffset]$currentTransition.ObservedUtc).ToUniversalTime() -ge ([DateTimeOffset]$leadingReconciliation.ObservedUtc).ToUniversalTime()) "$Name Event predates its leading snapshot reconciliation."
    }
    return [pscustomobject]@{
        Baseline = $baselineTransition
        LeadingReconciliation = $leadingReconciliation
        Current = $currentTransition
        AdmissionPath = $admissionPath
        ExpectedTransitionCount = if ($admissionPath -eq 'direct-event') { 1 } else { 2 }
        ReconciliationDelta = $reconciliationDelta
    }
}

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$artifactRoot = Join-Path $repositoryRoot 'artifacts'
$configurationDirectory = $Configuration.ToLowerInvariant()
$coreExecutable = Join-Path $artifactRoot "bin\HerdrOps.Core\$configurationDirectory\HerdrOps.Core.exe"
$appExecutable = Join-Path $artifactRoot "bin\HerdrOps.App\$configurationDirectory\HerdrOps.App.exe"
$runId = [DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssZ')
$evidenceDirectory = Join-Path $artifactRoot "runtime-evidence\v0.2\issues-7-9-10\$runId"
$captureDirectory = Join-Path $evidenceDirectory 'captures'
$databasePath = Join-Path $evidenceDirectory 'herdrops-runtime.db'
$coreReportPath = Join-Path $evidenceDirectory 'core-runtime.json'
$appReportPath = Join-Path $evidenceDirectory 'app-runtime.json'
$progressPath = Join-Path $evidenceDirectory 'app-progress.json'
$progressHistoryPath = $progressPath + '.history.jsonl'
$coreOutputPath = Join-Path $evidenceDirectory 'core.stdout.log'
$coreErrorPath = Join-Path $evidenceDirectory 'core.stderr.log'
$gateReportPath = Join-Path $evidenceDirectory 'gate-report.txt'
$completionSignalPath = Join-Path $evidenceDirectory "core-completion-$([guid]::NewGuid().ToString('N')).signal"
$sourceCommit = 'UNRESOLVED'
$coreExecutableHashBeforeLaunch = 'NOT_OBSERVED'
$appExecutableHashBeforeLaunch = 'NOT_OBSERVED'
$coreExecutableHashAfterRun = 'NOT_OBSERVED'
$appExecutableHashAfterRun = 'NOT_OBSERVED'
$coreProcess = $null
$appProcess = $null
$appFailureMessage = $null
$completionSignalWriteFailure = $null
$coreWaitFailure = $null
$coreExitCode = $null
$appExitCode = $null
$tcpListeners = @{}
$coreAcceptedEventKindCheck = 'NOT_EVALUATED'

try {
    New-Item -ItemType Directory -Path $captureDirectory -Force | Out-Null
    Assert-ProgressCanonicalKnownVector
    if (Test-Path -LiteralPath $completionSignalPath) {
        throw "Completion signal path already exists: $completionSignalPath"
    }

    if ($env:HERDR_ENV -ne '1') {
    throw 'The composite runtime gate must run from an authorized Herdr pane with HERDR_ENV=1.'
}
if ([string]::IsNullOrWhiteSpace($env:HERDR_SOCKET_PATH)) {
    throw 'The composite runtime gate requires HERDR_SOCKET_PATH from the active Acceptance control pane.'
}
if ([string]::IsNullOrWhiteSpace($env:HERDR_PANE_ID)) {
    throw 'The composite runtime gate requires HERDR_PANE_ID from the active Acceptance control pane.'
}
if (Test-IsAdministrator) {
    throw 'Run the v0.2 runtime gate from a standard, non-elevated Herdr pane to prove Administrator is not required.'
}
if (-not (Test-Path -LiteralPath $HerdrExecutable -PathType Leaf)) {
    throw "Installed Herdr executable not found: $HerdrExecutable"
}
if (-not (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue)) {
    throw 'Get-NetTCPConnection is required to verify that Core and App open no TCP listener.'
}
if (-not (Get-Command Get-CimInstance -ErrorAction SilentlyContinue)) {
    throw 'Get-CimInstance is required to bind the gate process to its Acceptance control Herdr server.'
}
if (-not (Test-Path -LiteralPath $env:HERDR_SOCKET_PATH -PathType Leaf)) {
    throw "The Acceptance control socket does not exist: $($env:HERDR_SOCKET_PATH)"
}
if (-not (Test-Path -LiteralPath $TargetHerdrSocketPath -PathType Leaf)) {
    throw "The target Agent Lab socket does not exist: $TargetHerdrSocketPath"
}

$controlHerdrSocketPath = (Resolve-Path -LiteralPath $env:HERDR_SOCKET_PATH).Path
$targetHerdrSocketPath = (Resolve-Path -LiteralPath $TargetHerdrSocketPath).Path
if ([StringComparer]::OrdinalIgnoreCase.Equals($controlHerdrSocketPath, $targetHerdrSocketPath)) {
    throw 'Acceptance control and target Agent Lab sockets must be different. Restarting the control session would terminate the gate process.'
}
$sessionListOutput = @(& $HerdrExecutable session list --json)
if ($LASTEXITCODE -ne 0 -or $sessionListOutput.Count -eq 0) {
    throw 'Could not enumerate Herdr named sessions before the runtime gate.'
}
$sessionTopology = Assert-V02AcceptanceSessionTopology `
    -SessionListJson ($sessionListOutput -join [Environment]::NewLine) `
    -ControlSocketPath $controlHerdrSocketPath `
    -TargetSocketPath $targetHerdrSocketPath

$controlPaneOutput = @(& $HerdrExecutable pane current --current)
if ($LASTEXITCODE -ne 0 -or $controlPaneOutput.Count -eq 0) {
    throw 'Could not verify the active Acceptance control pane through its Herdr socket.'
}
try {
    $controlPane = ($controlPaneOutput -join [Environment]::NewLine) | ConvertFrom-Json
} catch {
    throw 'The active Acceptance control pane returned invalid JSON.'
}
$observedControlPaneId = [string]$controlPane.result.pane.pane_id
if ([string]::IsNullOrWhiteSpace($observedControlPaneId)) {
    throw 'The active Acceptance control pane response did not contain a pane ID.'
}
if ($observedControlPaneId -ne $env:HERDR_PANE_ID) {
    throw 'Use a fresh, unmoved Acceptance control pane so HERDR_PANE_ID exactly matches pane current --current.'
}
$controlServerIdentity = Get-ControlHerdrServerIdentity -ExpectedExecutablePath $HerdrExecutable

$sourceCommit = Get-CleanSourceCommit -Root $repositoryRoot
$buildStartedUtc = [DateTime]::UtcNow
& (Join-Path $PSScriptRoot 'Invoke-Build.ps1') -Configuration $Configuration -VerifyFormat
if ($LASTEXITCODE -ne 0) { throw 'Build and automated tests failed before runtime acceptance.' }
$testCounts = Get-FreshTestCounts -Directory (Join-Path $artifactRoot 'test-results') -StartedUtc $buildStartedUtc

foreach ($executable in @($coreExecutable, $appExecutable)) {
    if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
        throw "Runtime executable not found: $executable"
    }
}
$coreExecutableHashBeforeLaunch = ((Get-FileHash -LiteralPath $coreExecutable -Algorithm SHA256).Hash).ToUpperInvariant()
$appExecutableHashBeforeLaunch = ((Get-FileHash -LiteralPath $appExecutable -Algorithm SHA256).Hash).ToUpperInvariant()

$coreDurationSeconds = [Math]::Min(3600, $DurationSeconds + $IdleSeconds + 30)
$coreArguments = @(
    'serve-herdr-state',
    '--database', $databasePath,
    '--herdr', $HerdrExecutable,
    '--socket-path', $targetHerdrSocketPath,
    '--seconds', $coreDurationSeconds,
    '--report', $coreReportPath,
    '--completion-signal', $completionSignalPath
)
$appArguments = @(
    '--runtime-evidence-report', $appReportPath,
    '--capture-directory', $captureDirectory,
    '--progress-report', $progressPath,
    '--core-pid', '0',
    '--timeout-seconds', $DurationSeconds,
    '--idle-seconds', $IdleSeconds,
    '--language', $Language
)

$tcpListeners = @{}
try {
    $coreProcess = Start-Process `
        -FilePath $coreExecutable `
        -ArgumentList $coreArguments `
        -RedirectStandardOutput $coreOutputPath `
        -RedirectStandardError $coreErrorPath `
        -WindowStyle Hidden `
        -PassThru
    $appArguments[7] = $coreProcess.Id.ToString([Globalization.CultureInfo]::InvariantCulture)
    Start-Sleep -Milliseconds 750
    if ($coreProcess.HasExited) {
        throw "Core exited before the App started. See $coreErrorPath"
    }

    Write-Host "Acceptance control socket: $controlHerdrSocketPath"
    Write-Host "Target Agent Lab socket: $targetHerdrSocketPath"
    Write-Host 'Runtime acceptance started. Follow the phase instructions shown below.'
    $appProcess = Start-Process `
        -FilePath $appExecutable `
        -ArgumentList $appArguments `
        -WindowStyle Normal `
        -PassThru

    $lastPhase = ''
    $deadlineUtc = [DateTime]::UtcNow.AddSeconds($coreDurationSeconds + 20)
    while (-not $appProcess.HasExited -and [DateTime]::UtcNow -lt $deadlineUtc) {
        if (Test-Path -LiteralPath $progressPath -PathType Leaf) {
            try {
                $progress = Get-Content -LiteralPath $progressPath -Raw | ConvertFrom-Json
                if ($progress.Phase -ne $lastPhase) {
                    $lastPhase = $progress.Phase
                    switch ($lastPhase) {
                        'waiting-for-live-state' {
                            Write-Host 'Waiting for the exact admitted Agent Lab snapshot. Do not restart either Herdr session yet.'
                        }
                        'capturing-live-dashboard-and-widgets' {
                            Write-Host 'Capturing the three live pages and three live Widgets. Keep Herdr state steady.'
                        }
                        'waiting-for-pre-close-update' {
                            Write-Host 'Event A: trigger one genuine Agent-status transition in the target Agent Lab. Focus, workspace, tab, and pane changes do not count. The Dashboard will close after the status event arrives.'
                        }
                        'dashboard-closed-waiting-for-herdr-disconnect' {
                            Write-Host 'Dashboard closed; the Floating Vertical Widget remains. Restart only the target Agent Lab Herdr session now. Never restart the Acceptance control session. Do not trigger Event B yet.'
                        }
                        'herdr-disconnected-waiting-for-reconnect' {
                            Write-Host 'The target Agent Lab is disconnected. Wait for the Floating Vertical Widget to return to LIVE. Do not trigger Event B until the reconnect phase appears.'
                        }
                        'herdr-reconnected-waiting-for-post-reconnect-update' {
                            Write-Host 'The target Agent Lab has reconnected and the Widget is LIVE. Now trigger Event B with a second genuine Agent-status transition.'
                        }
                        'waiting-for-idle-stability' {
                            Write-Host 'Event B arrived. Leave Herdr, Core, and App untouched while the gate waits for five continuous seconds of stable live state.'
                        }
                        'measuring-idle-resources' {
                            Write-Host "Leave Herdr, Core, and App untouched for the $IdleSeconds-second idle measurement."
                        }
                    }
                }
            } catch {
                # The App replaces the progress file atomically; a later poll will retry.
            }
        }

        $runtimeProcessIds = @($coreProcess.Id, $appProcess.Id)
        $listeners = @(Get-NetTCPConnection -State Listen -ErrorAction Stop |
            Where-Object { $runtimeProcessIds -contains $_.OwningProcess })
        foreach ($listener in $listeners) {
            $key = "$($listener.OwningProcess)|$($listener.LocalAddress)|$($listener.LocalPort)"
            $tcpListeners[$key] = $listener
        }

        Start-Sleep -Milliseconds 500
        $appProcess.Refresh()
    }

    $appProcess.Refresh()
    if (-not $appProcess.HasExited) {
        throw 'The App runtime-evidence process exceeded the bounded gate duration.'
    }

    $appExitCode = $appProcess.ExitCode
    try {
        # The signal is created only after the App process has exited. Core observes
        # appearance only, then performs its normal graceful report-writing path.
        [System.IO.File]::WriteAllBytes($completionSignalPath, [byte[]]@())
    } catch {
        $completionSignalWriteFailure = $_.Exception.Message
    }

    $remainingSeconds = [Math]::Max(1, [int]($deadlineUtc - [DateTime]::UtcNow).TotalSeconds)
    try {
        Wait-Process -Id $coreProcess.Id -Timeout $remainingSeconds -ErrorAction Stop | Out-Null
    } catch {
        $coreWaitFailure = $_.Exception.Message
    }
    $coreProcess.Refresh()
    $coreExited = $coreProcess.HasExited
    $coreExitCode = $null
    if ($coreExited) {
        $coreExitCode = $coreProcess.ExitCode
    }

    $reportWaitDeadlineUtc = [DateTime]::UtcNow.AddSeconds(5)
    while ([DateTime]::UtcNow -lt $reportWaitDeadlineUtc -and
           (-not $coreExited -or
            -not (Test-Path -LiteralPath $coreReportPath -PathType Leaf) -or
            -not (Test-Path -LiteralPath $appReportPath -PathType Leaf))) {
        Start-Sleep -Milliseconds 100
        $coreProcess.Refresh()
        $coreExited = $coreProcess.HasExited
        if ($coreExited) {
            $coreExitCode = $coreProcess.ExitCode
        }
    }

    if ($appExitCode -ne 0) {
        $reportPresence = @(
            "AppReport=$([bool](Test-Path -LiteralPath $appReportPath -PathType Leaf))",
            "CoreReport=$([bool](Test-Path -LiteralPath $coreReportPath -PathType Leaf))",
            "ProgressHistory=$([bool](Test-Path -LiteralPath $progressHistoryPath -PathType Leaf))"
        ) -join ', '
        $appFailureMessage = "The App runtime-evidence process failed with exit code $appExitCode. Evidence paths: AppRuntimeReport=$appReportPath; CoreRuntimeReport=$coreReportPath; GateReport=$gateReportPath. ReportPresence: $reportPresence"
        if (Test-Path -LiteralPath $appReportPath -PathType Leaf) {
            try {
                $failedAppReport = Get-Content -LiteralPath $appReportPath -Raw | ConvertFrom-Json
                if (Test-ObjectHasProperty -Object $failedAppReport -Name 'FailedCandidateChecks') {
                    $failedChecks = @($failedAppReport.FailedCandidateChecks)
                    if ($failedChecks.Count -gt 0) {
                        $appFailureMessage += " FailedCandidateChecks=$($failedChecks -join ',')"
                    }
                }
                if ((Test-ObjectHasProperty -Object $failedAppReport -Name 'ErrorType') -and
                    (Test-ObjectHasProperty -Object $failedAppReport -Name 'Message')) {
                    $appFailureMessage += " AppFailure=$($failedAppReport.ErrorType): $($failedAppReport.Message)"
                }
            } catch {
                $appFailureMessage += ' App report could not be parsed for failed-check diagnostics.'
            }
        }
        if ($completionSignalWriteFailure) {
            $appFailureMessage += " Completion signal creation failed: $completionSignalWriteFailure"
        }
        if ($coreWaitFailure) {
            $appFailureMessage += " Core wait failed: $coreWaitFailure"
        }
    } elseif ($completionSignalWriteFailure) {
        throw "The completion signal could not be created after the App exited. CoreRuntimeReport=$coreReportPath; AppRuntimeReport=$appReportPath; GateReport=$gateReportPath. Error: $completionSignalWriteFailure"
    } elseif (-not $coreExited -or $coreExitCode -ne 0) {
        throw "The Core runtime-evidence process did not exit cleanly. Exit=$coreExitCode. CoreRuntimeReport=$coreReportPath; AppRuntimeReport=$appReportPath; GateReport=$gateReportPath"
    }
} finally {
    if ($appProcess -and -not $appProcess.HasExited) {
        Stop-Process -Id $appProcess.Id -Force -ErrorAction SilentlyContinue
    }
    if ($coreProcess -and -not $coreProcess.HasExited) {
        Stop-Process -Id $coreProcess.Id -Force -ErrorAction SilentlyContinue
    }
}

$coreExecutableHashAfterRun = Get-OptionalFileSha256 -Path $coreExecutable
$appExecutableHashAfterRun = Get-OptionalFileSha256 -Path $appExecutable
$executableHashMismatch = @()
if ($coreExecutableHashAfterRun -ne $coreExecutableHashBeforeLaunch) {
    $executableHashMismatch += 'HerdrOps.Core executable bytes changed during runtime acceptance.'
}
if ($appExecutableHashAfterRun -ne $appExecutableHashBeforeLaunch) {
    $executableHashMismatch += 'HerdrOps.App executable bytes changed during runtime acceptance.'
}
if ($executableHashMismatch.Count -gt 0 -and $appFailureMessage) {
    $appFailureMessage += " ExecutableHashMismatch=$($executableHashMismatch -join ',')"
} elseif ($executableHashMismatch.Count -gt 0) {
    $appFailureMessage = $executableHashMismatch -join ' '
}

if ($appFailureMessage) {
    throw "$appFailureMessage Failure gate report: $gateReportPath"
}

foreach ($requiredReport in @($coreReportPath, $appReportPath, $progressPath, $progressHistoryPath)) {
    if (-not (Test-Path -LiteralPath $requiredReport -PathType Leaf)) {
        throw "Required runtime report is missing: $requiredReport"
    }
}
$coreReport = Get-Content -LiteralPath $coreReportPath -Raw | ConvertFrom-Json
$appReport = Get-Content -LiteralPath $appReportPath -Raw | ConvertFrom-Json
$progressReport = Get-Content -LiteralPath $progressPath -Raw | ConvertFrom-Json
$coreExecutableHash = $coreExecutableHashBeforeLaunch
$appExecutableHash = $appExecutableHashBeforeLaunch

Assert-True ($coreReport.EvidenceClassification -eq 'Runtime') 'Core report did not earn Runtime classification.'
Assert-True ([bool]$coreReport.RuntimeObserved) 'Actual Herdr runtime was not observed by Core.'
Assert-True (-not [bool]$coreReport.SessionControlInvoked) 'Core must not invoke Herdr session control.'
Assert-True ([bool]$coreReport.SnapshotObserved) 'Actual Herdr snapshot was not observed.'
Assert-True ([bool]$coreReport.EventObserved) 'Actual Herdr Agent-status event was not observed.'
Assert-True ([bool]$coreReport.ReconnectObserved) 'Actual Herdr disconnect/reconnect was not observed.'
Assert-True ([bool]$coreReport.CompletionSignalObserved) 'Core did not observe the post-App completion signal.'
Assert-True ($coreReport.CompletionSignalSemantics -eq 'UniquePrevalidatedAbsolutePathContainingAnEmptyFileAfterAppExit') 'Unexpected Core completion-signal semantics.'
Assert-True ($coreReport.Admission.ReleaseId -eq '0.8.2-preview.2026-08-19-b5c4a0176e91-x86_64-pc-windows-msvc') 'Unexpected Herdr release.'
Assert-True ($coreReport.Admission.ExecutableSha256 -eq 'AFE7BAD9B77946917B509C9B638BB2A47BC1D4F19254957D15B0FAAFBEDB3E93') 'Unexpected Herdr executable hash.'
Assert-True ($coreReport.Admission.BundledSchemaSha256 -eq '3B34717C8B828FAF4E4A1D4DAC5953417712C8EB71A54237FFAD7582C7FF5679') 'Unexpected bundled schema hash.'
Assert-True ([int]$coreReport.Admission.Protocol -eq 20) 'Unexpected Herdr protocol.'

Assert-True ($appReport.EvidenceClassification -eq 'RuntimeCandidate') 'App report is not a Runtime candidate.'
Assert-True ([bool]$appReport.CoreStateObserved) 'App did not observe Core state.'
Assert-True (-not [bool]$appReport.SessionControlInvoked) 'App must not invoke Herdr session control.'
Assert-True ([bool]$appReport.UpdateObservedBeforeDashboardClose) 'No App update was observed before Dashboard close.'
Assert-True ([bool]$appReport.DashboardClosed) 'Dashboard did not close during lifecycle acceptance.'
Assert-True ([bool]$appReport.UpdateObservedAfterDashboardClose) 'No App-owned Widget update was observed after Dashboard close.'
Assert-True ([bool]$appReport.CoreConnectedAfterDashboardClose) 'Core was not connected after Dashboard close.'
Assert-True ([long]$appReport.PreCloseEventCount -gt [long]$appReport.InitialEventCount) 'The pre-close App update was not caused by a real Herdr Agent-status event.'
Assert-True ([bool]$appReport.DisconnectObservedAfterDashboardClose) 'The App did not observe the target Agent Lab disconnect after Dashboard close.'
Assert-True ([bool]$appReport.ReconnectObservedAfterDashboardClose) 'The App did not observe the target Agent Lab reconnect after Dashboard close.'
$dashboardClosedUtc = [DateTimeOffset]$appReport.DashboardClosedUtc
$disconnectObservedUtc = [DateTimeOffset]$appReport.DisconnectObservedUtc
$reconnectObservedUtc = [DateTimeOffset]$appReport.ReconnectObservedUtc
Assert-True ($disconnectObservedUtc -ge $dashboardClosedUtc) 'The App disconnect observation predates Dashboard closure.'
Assert-True ($reconnectObservedUtc -ge $disconnectObservedUtc) 'The App reconnect observation predates its disconnect observation.'
Assert-True ([long]$appReport.ReconnectedConnectionEpoch -gt [long]$appReport.PreRestartConnectionEpoch) 'The App reconnect did not advance the target connection epoch.'
Assert-True ([long]$appReport.ReconnectedBootstrapCount -gt [long]$appReport.PreRestartBootstrapCount) 'The App reconnect did not advance the target bootstrap count.'
Assert-True ([long]$appReport.ReconnectedDisconnectCount -gt [long]$appReport.PreRestartDisconnectCount) 'The App did not carry an incremented disconnect count after reconnect.'
Assert-True ([long]$appReport.EventBBaselineEventCount -ge [long]$appReport.PreCloseEventCount) 'The Event B baseline predates Event A.'
Assert-True ([long]$appReport.PostCloseEventCount -gt [long]$appReport.EventBBaselineEventCount) 'The post-close Widget update was not caused by Event B after reconnect.'
$expectedProgressPhases = @(
    'waiting-for-live-state',
    'capturing-live-dashboard-and-widgets',
    'waiting-for-pre-close-update',
    'dashboard-closed-waiting-for-herdr-disconnect',
    'herdr-disconnected-waiting-for-reconnect',
    'herdr-reconnected-waiting-for-post-reconnect-update',
    'waiting-for-idle-stability',
    'measuring-idle-resources',
    'complete'
)
$progressHistoryLines = [IO.File]::ReadAllLines($progressHistoryPath)
Assert-True ($progressHistoryLines.Count -eq $expectedProgressPhases.Count) 'The append-only App progress history does not contain every required phase exactly once.'
$progressHistoryEntries = @()
$expectedPreviousEntrySha256 = ('0' * 64)
$previousProgressUtc = $null
$lineOrdinal = 0
foreach ($line in $progressHistoryLines) {
    $lineOrdinal++
    Assert-True (-not [string]::IsNullOrWhiteSpace($line)) 'The append-only App progress history contains a blank line.'
    try {
        $entry = $line | ConvertFrom-Json
    } catch {
        throw "The append-only App progress history contains invalid JSON: $($_.Exception.Message)"
    }
    Assert-ProgressEntryIntegrity `
        -Entry $entry `
        -ExpectedOrdinal $lineOrdinal `
        -ExpectedPreviousEntrySha256 $expectedPreviousEntrySha256 `
        -Context "Append-only progress record $lineOrdinal"
    $entryUtc = ([DateTimeOffset]$entry.ObservedUtc).ToUniversalTime()
    if ($null -ne $previousProgressUtc) {
        Assert-True ($entryUtc -ge $previousProgressUtc) 'The append-only App progress history timestamps moved backward.'
    }
    $previousProgressUtc = $entryUtc
    $expectedPreviousEntrySha256 = ([string]$entry.EntrySha256).ToUpperInvariant()
    $progressHistoryEntries += $entry
}

$finalHistoryEntry = $progressHistoryEntries[$progressHistoryEntries.Count - 1]
Assert-True (Test-ObjectHasProperty -Object $progressReport -Name 'History') 'The final App progress report omitted its History collection.'
$progressHistory = @($progressReport.History)
Assert-True ($progressHistory.Count -eq $progressHistoryEntries.Count) 'The latest App progress report history does not match the append-only history line count.'
Assert-True (Test-ObjectHasProperty -Object $progressReport -Name 'ProgressHistoryPath') 'The final App progress report omitted ProgressHistoryPath.'
$reportedProgressHistoryPath = [IO.Path]::GetFullPath([string]$progressReport.ProgressHistoryPath)
$expectedProgressHistoryPath = [IO.Path]::GetFullPath($progressHistoryPath)
Assert-True ([StringComparer]::OrdinalIgnoreCase.Equals($reportedProgressHistoryPath, $expectedProgressHistoryPath)) 'The App progress report is bound to an unexpected progress history path.'
for ($index = 0; $index -lt $expectedProgressPhases.Count; $index++) {
    $item = $progressHistory[$index]
    $historyEntry = $progressHistoryEntries[$index]
    $itemExpectedPreviousEntrySha256 = if ($index -eq 0) {
        ('0' * 64)
    } else {
        ([string]$progressHistoryEntries[$index - 1].EntrySha256).ToUpperInvariant()
    }
    Assert-ProgressEntryIntegrity `
        -Entry $item `
        -ExpectedOrdinal ($index + 1) `
        -ExpectedPreviousEntrySha256 $itemExpectedPreviousEntrySha256 `
        -Context "Latest progress History record $($index + 1)"
    Assert-True ([string]$item.Phase -eq $expectedProgressPhases[$index]) 'The App progress phases occurred out of order.'
    Assert-ProgressEntryEquals `
        -Expected $historyEntry `
        -Actual $item `
        -Context "Latest progress History record $($index + 1)" `
        -IncludeChainFields
}
Assert-ProgressTopLevelPointer -ProgressReport $progressReport -FinalEntry $finalHistoryEntry
Assert-True ([string]$progressReport.Phase -eq 'complete') 'The final App progress phase is not complete.'
$progressHistoryHash = ((Get-FileHash -LiteralPath $progressHistoryPath -Algorithm SHA256).Hash).ToUpperInvariant()
Assert-True ($appReport.WidgetLatencyMeasurement -eq 'CoreAcceptedStateUtcToWpfStateApplied') 'Unexpected Widget latency measurement boundary.'
Assert-True ([int]$appReport.WidgetLatencyMinimumSamples -eq 3) 'Unexpected Widget latency minimum sample count.'
Assert-True ([double]$appReport.WidgetLatencyTargetMilliseconds -eq 250) 'Unexpected Widget latency target.'
Assert-True ([long]$appReport.WidgetLatencyBaselineSequence -eq [long]$appReport.InitialSequence) 'Widget latency measurement did not begin after the coherent initial capture.'
$warmupLatencySamples = @($appReport.WidgetLatencyWarmupExcludedSamples)
Assert-True ([int]$appReport.WidgetLatencyWarmupSamplesExcluded -eq $warmupLatencySamples.Count) 'Warm-up latency sample count does not match its provenance list.'
Assert-True ($warmupLatencySamples.Count -ge 1) 'The initial catch-up latency was not preserved as excluded diagnostic evidence.'
foreach ($sample in $warmupLatencySamples) {
    Assert-True ([long]$sample.StateSequence -le [long]$appReport.WidgetLatencyBaselineSequence) 'A post-baseline Widget latency sample was incorrectly excluded as warm-up.'
}
$includedLatencySamples = @($appReport.WidgetLatencyIncludedSamples)
Assert-True ([int]$appReport.WidgetLatencySamples -eq $includedLatencySamples.Count) 'Included Widget latency sample count does not match its provenance list.'
Assert-True ($includedLatencySamples.Count -ge [int]$appReport.WidgetLatencyMinimumSamples) 'Too few post-baseline Widget latency samples were observed.'
$includedLatencyValues = @()
foreach ($sample in $includedLatencySamples) {
    Assert-True ([long]$sample.StateSequence -gt [long]$appReport.WidgetLatencyBaselineSequence) 'An initial catch-up sample contaminated the Widget latency result.'
    Assert-True (@('Snapshot', 'Delta') -contains [string]$sample.UpdateKind) 'The Widget latency target must contain only post-baseline accepted Core snapshots or deltas.'
    Assert-True ([long]$sample.EnvelopeSequence -eq [long]$sample.StateSequence) 'A Widget latency sample is not bound to its exact state envelope sequence.'
    Assert-True ([Guid]$sample.EnvelopeCorrelationId -ne [Guid]::Empty) 'A Widget latency sample omitted its envelope correlation identity.'
    Assert-True ([string]$sample.StateSha256 -match '^[0-9A-F]{64}$') 'A Widget latency sample omitted its exact state hash.'
    $acceptedUtc = [DateTimeOffset]$sample.CoreAcceptedStateUtc
    $sentUtc = [DateTimeOffset]$sample.IpcSentUtc
    $appliedUtc = [DateTimeOffset]$sample.WpfAppliedUtc
    Assert-True ($sentUtc -ge $acceptedUtc -and $appliedUtc -ge $sentUtc) 'A Widget latency sample contains an invalid timestamp order.'
    $reportedLatency = [double]$sample.Milliseconds
    $derivedLatency = ($appliedUtc - $acceptedUtc).TotalMilliseconds
    Assert-True (Test-FiniteNumber $reportedLatency) 'A Widget latency sample is not finite.'
    Assert-True ($reportedLatency -ge 0) 'A Widget latency sample is negative.'
    Assert-True ([Math]::Abs($reportedLatency - $derivedLatency) -le 0.001) 'A Widget latency sample contradicts its timestamp provenance.'
    $includedLatencyValues += $reportedLatency
}
$unsupportedLatencySamples = @($appReport.WidgetLatencyUnsupportedExcludedSamples)
Assert-True ([int]$appReport.WidgetLatencyUnsupportedSamplesExcluded -eq $unsupportedLatencySamples.Count) 'Excluded unsupported latency count does not match its provenance list.'
$orderedLatencyValues = @($includedLatencyValues | Sort-Object)
$latencyP95Index = [Math]::Max(0, [int][Math]::Ceiling($orderedLatencyValues.Count * 0.95) - 1)
$recomputedLatencyP95 = [double]$orderedLatencyValues[$latencyP95Index]
Assert-True ([Math]::Abs($recomputedLatencyP95 - [double]$appReport.WidgetLatencyP95Milliseconds) -le 0.001) 'The reported Widget p95 does not match the included samples.'
Assert-True ($recomputedLatencyP95 -le [double]$appReport.WidgetLatencyTargetMilliseconds) 'The independently recomputed Widget p95 exceeds the target.'
Assert-True ([bool]$appReport.WidgetLatencyTargetPassed) 'Actual Widget latency target failed or had too few samples.'
$idleQuiescence = $appReport.IdleQuiescence
Assert-True ([int]$idleQuiescence.RequiredStableSeconds -eq 5) 'Unexpected pre-idle quiescence requirement.'
$quiescenceStartedUtc = [DateTimeOffset]$idleQuiescence.StartedUtc
$quiescenceStableSinceUtc = [DateTimeOffset]$idleQuiescence.StableSinceUtc
$quiescenceReachedUtc = [DateTimeOffset]$idleQuiescence.ReachedUtc
Assert-True ($quiescenceStableSinceUtc -ge $quiescenceStartedUtc) 'The quiescence stable interval began before observation.'
Assert-True ($quiescenceReachedUtc -ge $quiescenceStableSinceUtc.AddSeconds([int]$idleQuiescence.RequiredStableSeconds)) 'The gate did not observe the complete quiescence interval.'
Assert-True ([long]$idleQuiescence.StableSequence -ge [long]$idleQuiescence.InitialSequence) 'The quiescence sequence regressed.'
Assert-True ([long]$idleQuiescence.StableEventCount -ge [long]$idleQuiescence.InitialEventCount) 'The quiescence event count regressed.'
Assert-True ([int]$idleQuiescence.ResetCount -ge 0) 'The quiescence reset count is invalid.'
$quiescenceResets = @($idleQuiescence.Resets)
Assert-True ([int]$idleQuiescence.ResetCount -eq $quiescenceResets.Count) 'The quiescence reset count does not match its append-only provenance.'
foreach ($reset in $quiescenceResets) {
    Assert-True (@('LiveStateLost', 'LiveStateRestored', 'RuntimeFingerprintChanged', 'NonLiveFingerprintChanged') -contains [string]$reset.Reason) 'The quiescence history contains an unknown reset reason.'
    Assert-True ([long]$reset.CurrentSequence -ge [long]$reset.PreviousSequence) 'A quiescence reset hid a sequence regression.'
    Assert-True ([long]$reset.CurrentEventCount -ge [long]$reset.PreviousEventCount) 'A quiescence reset hid an event-count regression.'
}
Assert-True ([double]$appReport.ResourceMeasurement.CpuTargetPercent -eq 1) 'Unexpected Core + App idle CPU target.'
Assert-True ([double]$appReport.ResourceMeasurement.WorkingSetTargetMegabytes -eq 180) 'Unexpected Core + App working-set target.'
Assert-True ([int]$appReport.ResourceMeasurement.SampleIntervalMilliseconds -eq 250) 'Unexpected idle resource sampling interval.'
$expectedResourceSampleCount = [int]($IdleSeconds * 1000 / [int]$appReport.ResourceMeasurement.SampleIntervalMilliseconds) + 1
Assert-True ([int]$appReport.ResourceMeasurement.SampleCount -eq $expectedResourceSampleCount) 'Idle resource samples do not include the post-preparation baseline plus the complete measurement window.'
Assert-True ([bool]$appReport.ResourceMeasurement.StateSequenceStable) 'State changed during the idle resource sample.'
Assert-True ([bool]$appReport.ResourceMeasurement.RuntimeEventCountStable) 'A Herdr event occurred during the idle resource sample.'
Assert-True ([bool]$appReport.ResourceMeasurement.RuntimeFingerprintStable) 'The full runtime fingerprint changed during the idle resource sample.'
Assert-True ($null -eq $appReport.ResourceMeasurement.FirstFingerprintChange) 'The idle resource report recorded an unexpected runtime fingerprint change.'
Assert-True ([bool]$appReport.ResourceMeasurement.HerdrConnectedThroughoutSample) 'Herdr was not connected throughout the idle resource sample.'
$combinedCpu = [double]$appReport.ResourceMeasurement.CombinedAverageCpuPercent
$averageWorkingSet = [double]$appReport.ResourceMeasurement.CombinedAverageWorkingSetMegabytes
$maximumWorkingSet = [double]$appReport.ResourceMeasurement.CombinedMaximumWorkingSetMegabytes
Assert-True ((Test-FiniteNumber $combinedCpu) -and $combinedCpu -ge 0 -and $combinedCpu -le [double]$appReport.ResourceMeasurement.CpuTargetPercent) 'Measured Core + App idle CPU does not independently satisfy its target.'
Assert-True ((Test-FiniteNumber $averageWorkingSet) -and $averageWorkingSet -ge 0) 'Measured average Core + App working set is invalid.'
Assert-True ((Test-FiniteNumber $maximumWorkingSet) -and $maximumWorkingSet -ge $averageWorkingSet -and $maximumWorkingSet -le [double]$appReport.ResourceMeasurement.WorkingSetTargetMegabytes) 'Measured maximum Core + App working set does not independently satisfy its target.'
Assert-True ([bool]$appReport.ResourceMeasurement.CpuTargetPassed) 'Combined Core + App idle CPU target failed.'
Assert-True ([bool]$appReport.ResourceMeasurement.WorkingSetTargetPassed) 'Combined Core + App working-set target failed.'
Assert-True ([bool]$appReport.ResourceMeasurement.Preparation.DashboardResourcesReleased) 'The closed Dashboard retained its visual tree during the idle resource sample.'
Assert-True ([int]$appReport.ResourceMeasurement.Preparation.RetainedEvidenceWindows -eq 1) 'The evidence runner retained a closed Widget window during the idle sample.'
Assert-True ([int]$appReport.ResourceMeasurement.Preparation.VisibleEvidenceWindows -eq 1) 'The Floating Vertical Widget was not the sole visible evidence window during the idle sample.'
Assert-True ([bool]$appReport.ResourceMeasurement.Preparation.ManagedCaptureCleanupAttempted) 'The App did not attempt managed capture cleanup before the idle sample.'
Assert-True ([bool]$appReport.ResourceMeasurement.Preparation.ManagedCaptureCleanupCompleted) 'Managed capture cleanup did not complete before the idle sample.'
Assert-True ([int]$appReport.ResourceMeasurement.Preparation.TrackedCaptureBitmapCount -gt 0) 'The App did not track any runtime capture bitmap for managed cleanup verification.'
Assert-True ([int]$appReport.ResourceMeasurement.Preparation.ReleasedCaptureBitmapCount -eq [int]$appReport.ResourceMeasurement.Preparation.TrackedCaptureBitmapCount) 'Not every tracked runtime capture bitmap was released before the idle sample.'
Assert-True ([long]$appReport.ResourceMeasurement.StartSequence -eq [long]$idleQuiescence.StableSequence) 'State changed between quiescence and the idle resource baseline.'
Assert-True ([long]$appReport.ResourceMeasurement.StartEventCount -eq [long]$idleQuiescence.StableEventCount) 'A Herdr event occurred between quiescence and the idle resource baseline.'
Assert-True ([long]$appReport.ResourceMeasurement.StartSequence -eq [long]$appReport.ResourceMeasurement.StartFingerprint.LastIngestSequence) 'The resource start sequence is not bound to its full start fingerprint.'
Assert-True ([long]$appReport.ResourceMeasurement.FinishSequence -eq [long]$appReport.ResourceMeasurement.FinishFingerprint.LastIngestSequence) 'The resource finish sequence is not bound to its full finish fingerprint.'
Assert-True ([long]$appReport.ResourceMeasurement.StartEventCount -eq [long]$appReport.ResourceMeasurement.StartFingerprint.EventCount) 'The resource start event count is not bound to its full start fingerprint.'
Assert-True ([long]$appReport.ResourceMeasurement.FinishEventCount -eq [long]$appReport.ResourceMeasurement.FinishFingerprint.EventCount) 'The resource finish event count is not bound to its full finish fingerprint.'
Assert-RuntimeFingerprintEqual -Expected $idleQuiescence.StableFingerprint -Actual $appReport.ResourceMeasurement.StartFingerprint -Context 'Idle resource start'
Assert-RuntimeFingerprintEqual -Expected $appReport.ResourceMeasurement.StartFingerprint -Actual $appReport.ResourceMeasurement.FinishFingerprint -Context 'Idle resource sample'
Assert-True ([int]$appReport.AppProcessId -eq [int]$appProcess.Id) 'The App report is not bound to the launched App process.'
Assert-True ([int]$appReport.CoreProcessId -eq [int]$coreProcess.Id) 'The App report is not bound to the launched Core process.'
Assert-True ([int]$appReport.ResourceMeasurement.App.ProcessId -eq [int]$appProcess.Id) 'App resource samples are not bound to the launched App process.'
Assert-True ([int]$appReport.ResourceMeasurement.Core.ProcessId -eq [int]$coreProcess.Id) 'Core resource samples are not bound to the launched Core process.'
Assert-True ([bool]$appReport.ResourceMeasurement.App.IdentityStable) 'App process identity changed during resource measurement.'
Assert-True ([bool]$appReport.ResourceMeasurement.Core.IdentityStable) 'Core process identity changed during resource measurement.'
Assert-True ([StringComparer]::OrdinalIgnoreCase.Equals([IO.Path]::GetFullPath([string]$appReport.ResourceMeasurement.App.ExecutablePath), [IO.Path]::GetFullPath($appExecutable))) 'App resource samples are bound to an unexpected executable path.'
Assert-True ([StringComparer]::OrdinalIgnoreCase.Equals([IO.Path]::GetFullPath([string]$appReport.ResourceMeasurement.Core.ExecutablePath), [IO.Path]::GetFullPath($coreExecutable))) 'Core resource samples are bound to an unexpected executable path.'
Assert-True ([string]$appReport.ResourceMeasurement.App.ExecutableSha256 -eq $appExecutableHash) 'App resource samples are bound to unexpected executable bytes.'
Assert-True ([string]$appReport.ResourceMeasurement.Core.ExecutableSha256 -eq $coreExecutableHash) 'Core resource samples are bound to unexpected executable bytes.'
$reportedAppStartUtc = ([DateTimeOffset]$appReport.ResourceMeasurement.App.ProcessStartUtc).ToUniversalTime()
$reportedCoreStartUtc = ([DateTimeOffset]$appReport.ResourceMeasurement.Core.ProcessStartUtc).ToUniversalTime()
Assert-True ($reportedAppStartUtc.UtcDateTime.Ticks -eq $appProcess.StartTime.ToUniversalTime().Ticks) 'App resource samples are bound to an unexpected process lifetime.'
Assert-True ($reportedCoreStartUtc.UtcDateTime.Ticks -eq $coreProcess.StartTime.ToUniversalTime().Ticks) 'Core resource samples are bound to an unexpected process lifetime.'
Assert-True (@($appReport.FailedCandidateChecks).Count -eq 0) 'The App report contains failed candidate checks.'
Assert-True ([bool]$appReport.CompositeCandidateChecksPassed) 'App runtime candidate checks did not all pass.'
Assert-True ([long]$coreReport.FinalMonitorState.EventCount -ge 2) 'The Core trace requires at least two real Herdr events.'
Assert-True ($tcpListeners.Count -eq 0) 'Core or App opened a TCP listener during normal runtime acceptance.'

Assert-True ($controlServerIdentity.ExecutableSha256 -eq $coreReport.Admission.ExecutableSha256) 'Acceptance control server executable hash does not match the admitted Herdr executable.'
$coreTransitions = @($coreReport.Transitions)
Assert-True ($coreTransitions.Count -gt 0) 'Core runtime report contains no transitions.'
$eventABaselineProgressCandidates = @($progressHistoryEntries | Where-Object { $_.Phase -eq 'waiting-for-pre-close-update' })
Assert-True ($eventABaselineProgressCandidates.Count -eq 1) 'The App progress history does not contain exactly one Event A baseline phase.'
$eventABaselineProgress = $eventABaselineProgressCandidates[0]
$eventBBaselineProgressCandidates = @($progressHistoryEntries | Where-Object { $_.Phase -eq 'herdr-reconnected-waiting-for-post-reconnect-update' })
Assert-True ($eventBBaselineProgressCandidates.Count -eq 1) 'The App progress history does not contain exactly one Event B baseline phase.'
$eventBBaselineProgress = $eventBBaselineProgressCandidates[0]
foreach ($sample in $includedLatencySamples) {
    $matchingCoreTransitions = @($coreTransitions | Where-Object {
        [long]$_.IngestSequence -eq [long]$sample.EnvelopeSequence -and
        [long]$_.EventCount -eq [long]$sample.EventCount -and
        [string]$_.ContractStateSha256 -eq [string]$sample.StateSha256
    })
    Assert-True ($matchingCoreTransitions.Count -ge 1) "No exact Core transition matches Widget latency envelope $($sample.EnvelopeSequence) / $($sample.EnvelopeCorrelationId)."
}

$eventATransitionIndex = -1
for ($index = 0; $index -lt $coreTransitions.Count; $index++) {
    $candidate = $coreTransitions[$index]
    if ([long]$candidate.EventCount -eq [long]$appReport.PreCloseEventCount -and
        [long]$candidate.IngestSequence -eq [long]$appReport.PreCloseSequence -and
        [long]$candidate.ConnectionEpoch -eq [long]$appReport.PreRestartConnectionEpoch -and
        [string]$candidate.ContractStateSha256 -eq [string]$appReport.PreCloseStateSha256) {
        $eventATransitionIndex = $index
        break
    }
}
Assert-True ($eventATransitionIndex -ge 0) 'Core trace does not contain the exact App state rendered for Event A before Dashboard closure.'
$eventATransition = $coreTransitions[$eventATransitionIndex]
Assert-True ([long]$appReport.EventA.CurrentSequence -eq [long]$appReport.PreCloseSequence) 'Event A evidence is not bound to the App pre-close sequence.'
Assert-True ([long]$appReport.EventA.CurrentEventCount -eq [long]$appReport.PreCloseEventCount) 'Event A evidence is not bound to the App pre-close event count.'
Assert-True ([string]$appReport.EventA.CurrentStateSha256 -eq [string]$appReport.PreCloseStateSha256) 'Event A evidence is not bound to the App pre-close state hash.'
$eventACorrelation = Assert-AgentStatusTransitionEvidence `
    -Evidence $appReport.EventA `
    -Name 'Event A' `
    -CoreTransitions $coreTransitions `
    -BaselineProgress $eventABaselineProgress
$eventACorrelatedTransition = $eventACorrelation.Current
Assert-True ([long]$eventACorrelatedTransition.IngestSequence -eq [long]$eventATransition.IngestSequence) 'Event A evidence correlated to a different Core transition than the rendered pre-close state.'
Assert-True ($null -ne $eventATransition.ServerIdentity) 'Event A is not bound to a verified target server identity.'
Assert-True (-not (Test-SameHerdrServerProcess -Left $controlServerIdentity -Right $eventATransition.ServerIdentity)) 'Acceptance control and target Agent Lab resolved to the same Herdr server process.'

$initialTargetTransitionIndex = -1
for ($index = 0; $index -lt $eventATransitionIndex; $index++) {
    if ($coreTransitions[$index].Status -eq 'Connected' -and $null -ne $coreTransitions[$index].ServerIdentity) {
        $initialTargetTransitionIndex = $index
        break
    }
}
Assert-True ($initialTargetTransitionIndex -ge 0) 'Core trace has no initial connected target baseline before Event A.'
$initialTargetTransition = $coreTransitions[$initialTargetTransitionIndex]
Assert-True ([long]$eventATransition.EventCount -gt [long]$initialTargetTransition.EventCount) 'Event A did not increase EventCount from the initial target baseline.'
Assert-True ([long]$eventATransition.DisconnectCount -eq [long]$initialTargetTransition.DisconnectCount) 'Event A coincided with a target transport disconnect instead of preceding it.'
Assert-True ([long]$eventATransition.BootstrapCount -eq [long]$initialTargetTransition.BootstrapCount) 'Event A coincided with a target bootstrap instead of preceding the restart.'
Assert-True (Test-SameHerdrServerProcess -Left $initialTargetTransition.ServerIdentity -Right $eventATransition.ServerIdentity) 'Target server identity changed before Event A.'
for ($index = $initialTargetTransitionIndex + 1; $index -lt $eventATransitionIndex; $index++) {
    $candidate = $coreTransitions[$index]
    Assert-True ([long]$candidate.DisconnectCount -eq [long]$initialTargetTransition.DisconnectCount) 'A target transport disconnect occurred before Event A.'
    Assert-True ([long]$candidate.BootstrapCount -eq [long]$initialTargetTransition.BootstrapCount) 'A target bootstrap occurred before Event A.'
    if ($null -ne $candidate.ServerIdentity) {
        Assert-True (Test-SameHerdrServerProcess -Left $initialTargetTransition.ServerIdentity -Right $candidate.ServerIdentity) 'Target server identity changed before Event A.'
    }
}

$targetDisconnectTransitionIndex = -1
for ($index = $eventATransitionIndex + 1; $index -lt $coreTransitions.Count; $index++) {
    if ([long]$coreTransitions[$index].DisconnectCount -gt [long]$eventATransition.DisconnectCount) {
        $targetDisconnectTransitionIndex = $index
        break
    }
}
Assert-True ($targetDisconnectTransitionIndex -gt $eventATransitionIndex) 'No target transport disconnect occurred after Event A.'
$targetDisconnectTransition = $coreTransitions[$targetDisconnectTransitionIndex]
Assert-True ([DateTimeOffset]$targetDisconnectTransition.ObservedUtc -gt $dashboardClosedUtc) 'The target disconnect did not occur strictly after Dashboard closure.'

$targetReconnectTransitionIndex = -1
for ($index = $targetDisconnectTransitionIndex + 1; $index -lt $coreTransitions.Count; $index++) {
    $candidate = $coreTransitions[$index]
    if ($candidate.Status -eq 'Connected' -and
        [long]$candidate.BootstrapCount -gt [long]$eventATransition.BootstrapCount -and
        $null -ne $candidate.ServerIdentity -and
        -not (Test-SameHerdrServerProcess -Left $eventATransition.ServerIdentity -Right $candidate.ServerIdentity)) {
        $targetReconnectTransitionIndex = $index
        break
    }
}
Assert-True ($targetReconnectTransitionIndex -gt $targetDisconnectTransitionIndex) 'No replacement target Herdr server connected after the post-Event-A disconnect.'
$targetReconnectTransition = $coreTransitions[$targetReconnectTransitionIndex]
Assert-True ([DateTimeOffset]$targetReconnectTransition.ObservedUtc -ge [DateTimeOffset]$targetDisconnectTransition.ObservedUtc) 'The target reconnect transition predates its disconnect.'
Assert-True ([long]$targetReconnectTransition.ConnectionEpoch -eq [long]$appReport.ReconnectedConnectionEpoch) 'Core and App disagree on the reconnected target epoch.'
Assert-True ([long]$targetReconnectTransition.BootstrapCount -eq [long]$appReport.ReconnectedBootstrapCount) 'Core and App disagree on the reconnected bootstrap count.'
Assert-True ([long]$targetReconnectTransition.DisconnectCount -eq [long]$appReport.ReconnectedDisconnectCount) 'Core and App disagree on the reconnected disconnect count.'
Assert-True (-not (Test-SameHerdrServerProcess -Left $controlServerIdentity -Right $targetReconnectTransition.ServerIdentity)) 'Restarted target Agent Lab resolved to the Acceptance control server process.'

$eventBIncrementTransitionIndex = -1
for ($index = $targetReconnectTransitionIndex + 1; $index -lt $coreTransitions.Count; $index++) {
    $candidate = $coreTransitions[$index]
    if ([long]$candidate.EventCount -gt [long]$appReport.EventBBaselineEventCount -and
        $null -ne $candidate.ServerIdentity -and
        (Test-SameHerdrServerProcess -Left $targetReconnectTransition.ServerIdentity -Right $candidate.ServerIdentity)) {
        $eventBIncrementTransitionIndex = $index
        break
    }
}
Assert-True ($eventBIncrementTransitionIndex -gt $targetReconnectTransitionIndex) 'No EventCount increment from Event B was observed after the replacement target connected.'
$eventBIncrementTransition = $coreTransitions[$eventBIncrementTransitionIndex]

$eventBTransitionIndex = -1
for ($index = $eventBIncrementTransitionIndex; $index -lt $coreTransitions.Count; $index++) {
    $candidate = $coreTransitions[$index]
    if ($candidate.Status -eq 'Connected' -and
        [long]$candidate.EventCount -eq [long]$appReport.PostCloseEventCount -and
        [long]$candidate.IngestSequence -eq [long]$appReport.PostCloseSequence -and
        [long]$candidate.ConnectionEpoch -eq [long]$appReport.ReconnectedConnectionEpoch -and
        [string]$candidate.ContractStateSha256 -eq [string]$appReport.PostCloseStateSha256 -and
        $null -ne $candidate.ServerIdentity -and
        (Test-SameHerdrServerProcess -Left $targetReconnectTransition.ServerIdentity -Right $candidate.ServerIdentity)) {
        $eventBTransitionIndex = $index
        break
    }
}
Assert-True ($eventBTransitionIndex -ge $eventBIncrementTransitionIndex) 'No exact connected Core transition matches the App state rendered for Event B.'
$eventBTransition = $coreTransitions[$eventBTransitionIndex]
Assert-True ([long]$appReport.EventB.CurrentSequence -eq [long]$appReport.PostCloseSequence) 'Event B evidence is not bound to the App post-close sequence.'
Assert-True ([long]$appReport.EventB.CurrentEventCount -eq [long]$appReport.PostCloseEventCount) 'Event B evidence is not bound to the App post-close event count.'
Assert-True ([string]$appReport.EventB.CurrentStateSha256 -eq [string]$appReport.PostCloseStateSha256) 'Event B evidence is not bound to the App post-close state hash.'
$eventBCorrelation = Assert-AgentStatusTransitionEvidence `
    -Evidence $appReport.EventB `
    -Name 'Event B' `
    -CoreTransitions $coreTransitions `
    -BaselineProgress $eventBBaselineProgress
$eventBCorrelatedTransition = $eventBCorrelation.Current
Assert-True ([long]$eventBCorrelatedTransition.IngestSequence -eq [long]$eventBTransition.IngestSequence) 'Event B evidence correlated to a different Core transition than the rendered post-close state.'
$eventAChange = @($appReport.EventA.Changes)[0]
$eventBChange = @($appReport.EventB.Changes)[0]

Assert-True (Test-ObjectHasProperty -Object $eventATransition -Name 'AcceptedEventKind') 'Core Event A transition omitted AcceptedEventKind.'
Assert-True ([string]$eventATransition.AcceptedEventKind -eq 'pane.agent_status_changed') 'Core Event A transition AcceptedEventKind was not pane.agent_status_changed.'
Assert-True (Test-ObjectHasProperty -Object $eventBTransition -Name 'AcceptedEventKind') 'Core Event B transition omitted AcceptedEventKind.'
Assert-True ([string]$eventBTransition.AcceptedEventKind -eq 'pane.agent_status_changed') 'Core Event B transition AcceptedEventKind was not pane.agent_status_changed.'
$coreAcceptedEventKindCheck = 'Core report AcceptedEventKind present and validated as pane.agent_status_changed for Event A and Event B.'

$controlProcessAfter = Get-Process -Id ([int]$controlServerIdentity.ProcessId) -ErrorAction SilentlyContinue
Assert-True ($null -ne $controlProcessAfter) 'Acceptance control Herdr server did not survive the target restart.'
$controlIdentityAfter = [pscustomobject]@{
    ProcessId = [int]$controlServerIdentity.ProcessId
    ProcessStartUtc = $controlProcessAfter.StartTime.ToUniversalTime()
}
Assert-True (Test-SameHerdrServerProcess -Left $controlServerIdentity -Right $controlIdentityAfter) 'Acceptance control Herdr server identity changed during the target restart.'

$coreStateHashes = @($coreReport.Transitions | ForEach-Object { $_.ContractStateSha256 })
foreach ($appStateHash in @(
    $appReport.InitialStateSha256,
    $appReport.PreCloseStateSha256,
    $appReport.PostCloseStateSha256)) {
    Assert-True ($coreStateHashes -contains $appStateHash) "App state hash $appStateHash was not observed in the exact-Herdr Core trace."
}

$captures = @($appReport.Captures)
Assert-True ($captures.Count -ge 8) "Expected at least eight runtime WPF captures, found $($captures.Count)."
foreach ($capture in $captures) {
    Assert-True (Test-Path -LiteralPath $capture.Path -PathType Leaf) "Runtime capture is missing: $($capture.Path)"
    $actualHash = (Get-FileHash -LiteralPath $capture.Path -Algorithm SHA256).Hash
    Assert-True ($actualHash -eq $capture.Sha256) "Runtime capture hash mismatch: $($capture.Name)"
}

$finalSourceCommit = Get-CleanSourceCommit -Root $repositoryRoot
if ($finalSourceCommit -ne $sourceCommit) {
    throw "Source commit changed during runtime acceptance: $sourceCommit -> $finalSourceCommit"
}
$coreReportHash = (Get-FileHash -LiteralPath $coreReportPath -Algorithm SHA256).Hash
$appReportHash = (Get-FileHash -LiteralPath $appReportPath -Algorithm SHA256).Hash

$reportLines = @(
    'HerdrOps v0.2 Composite Actual Herdr Runtime Acceptance',
    "GeneratedUtc: $([DateTimeOffset]::UtcNow.ToString('O'))",
    "SourceCommit: $sourceCommit",
    'Result: PASS',
    'EvidenceClass: Runtime',
    'SessionControlInvoked: false',
    "AcceptanceControlPaneEnvironmentId: $($env:HERDR_PANE_ID)",
    "AcceptanceControlPaneObservedId: $observedControlPaneId",
    "AcceptanceControlSession: $($sessionTopology.ControlSessionName)",
    "TargetAgentLabSession: $($sessionTopology.TargetSessionName)",
    "AcceptanceControlSocketPath: $controlHerdrSocketPath",
    "AcceptanceControlServerIdentity: pid=$($controlServerIdentity.ProcessId) start=$($controlServerIdentity.ProcessStartUtc.ToString('O')) path=$($controlServerIdentity.ExecutablePath) sha256=$($controlServerIdentity.ExecutableSha256)",
    "TargetAgentLabSocketPath: $targetHerdrSocketPath",
    'SeparateSessionSockets: true',
    "InitialTargetTransition: index=$initialTargetTransitionIndex utc=$($initialTargetTransition.ObservedUtc) eventCount=$($initialTargetTransition.EventCount) bootstrapCount=$($initialTargetTransition.BootstrapCount) disconnectCount=$($initialTargetTransition.DisconnectCount) targetPid=$($initialTargetTransition.ServerIdentity.ProcessId) targetStart=$($initialTargetTransition.ServerIdentity.ProcessStartUtc)",
    "EventATransition: index=$eventATransitionIndex utc=$($eventATransition.ObservedUtc) eventCount=$($eventATransition.EventCount) targetPid=$($eventATransition.ServerIdentity.ProcessId) targetStart=$($eventATransition.ServerIdentity.ProcessStartUtc)",
    "TargetDisconnectTransition: index=$targetDisconnectTransitionIndex utc=$($targetDisconnectTransition.ObservedUtc) disconnectCount=$($targetDisconnectTransition.DisconnectCount)",
    "TargetReconnectTransition: index=$targetReconnectTransitionIndex utc=$($targetReconnectTransition.ObservedUtc) bootstrapCount=$($targetReconnectTransition.BootstrapCount) targetPid=$($targetReconnectTransition.ServerIdentity.ProcessId) targetStart=$($targetReconnectTransition.ServerIdentity.ProcessStartUtc)",
    "EventBIncrementTransition: index=$eventBIncrementTransitionIndex utc=$($eventBIncrementTransition.ObservedUtc) eventCount=$($eventBIncrementTransition.EventCount)",
    "EventBTransition: index=$eventBTransitionIndex utc=$($eventBTransition.ObservedUtc) eventCount=$($eventBTransition.EventCount)",
    "CoreAcceptedEventKindCheck: $coreAcceptedEventKindCheck",
    "EventAIntegrity: admissionPath=$($eventACorrelation.AdmissionPath) sequenceDelta=$($appReport.EventA.CurrentSequence - $appReport.EventA.BaselineSequence) eventCountDelta=$($appReport.EventA.CurrentEventCount - $appReport.EventA.BaselineEventCount) connectionEpoch=$($appReport.EventA.ConnectionEpoch) bootstrapDelta=$($appReport.EventA.CurrentBootstrapCount - $appReport.EventA.BaselineBootstrapCount) disconnectDelta=$($appReport.EventA.CurrentDisconnectCount - $appReport.EventA.BaselineDisconnectCount) reconciliationDelta=$($eventACorrelation.ReconciliationDelta)",
    "EventBIntegrity: admissionPath=$($eventBCorrelation.AdmissionPath) sequenceDelta=$($appReport.EventB.CurrentSequence - $appReport.EventB.BaselineSequence) eventCountDelta=$($appReport.EventB.CurrentEventCount - $appReport.EventB.BaselineEventCount) connectionEpoch=$($appReport.EventB.ConnectionEpoch) bootstrapDelta=$($appReport.EventB.CurrentBootstrapCount - $appReport.EventB.BaselineBootstrapCount) disconnectDelta=$($appReport.EventB.CurrentDisconnectCount - $appReport.EventB.BaselineDisconnectCount) reconciliationDelta=$($eventBCorrelation.ReconciliationDelta)",
    "EventAAgentStatusTransition: terminal=$($eventAChange.TerminalId) workspace=$($eventAChange.WorkspaceId) tab=$($eventAChange.TabId) pane=$($eventAChange.PaneId) previous=$($eventAChange.PreviousStatus) current=$($eventAChange.CurrentStatus) stateChangeSequence=$($eventAChange.PreviousStateChangeSequence)->$($eventAChange.CurrentStateChangeSequence)",
    "EventBAgentStatusTransition: terminal=$($eventBChange.TerminalId) workspace=$($eventBChange.WorkspaceId) tab=$($eventBChange.TabId) pane=$($eventBChange.PaneId) previous=$($eventBChange.PreviousStatus) current=$($eventBChange.CurrentStatus) stateChangeSequence=$($eventBChange.PreviousStateChangeSequence)->$($eventBChange.CurrentStateChangeSequence)",
    "AutomatedTests: $($testCounts.Passed)/$($testCounts.Total) PASS",
    "HerdrReleaseId: $($coreReport.Admission.ReleaseId)",
    "HerdrExecutableSha256: $($coreReport.Admission.ExecutableSha256)",
    "HerdrOpsCoreExecutableSha256BeforeLaunch: $coreExecutableHashBeforeLaunch",
    "HerdrOpsCoreExecutableSha256AfterRun: $coreExecutableHashAfterRun",
    "HerdrOpsAppExecutableSha256BeforeLaunch: $appExecutableHashBeforeLaunch",
    "HerdrOpsAppExecutableSha256AfterRun: $appExecutableHashAfterRun",
    "HerdrOpsCoreExecutableSha256BoundToReports: $coreExecutableHash",
    "HerdrOpsAppExecutableSha256BoundToReports: $appExecutableHash",
    "CoreRuntimeReportSha256: $coreReportHash",
    "AppRuntimeReportSha256: $appReportHash",
    "ProgressHistoryPath: $progressHistoryPath",
    "ProgressHistorySha256: $progressHistoryHash",
    "ProgressHistoryEntries: $($progressHistoryEntries.Count)",
    "ProgressHistoryLastEntrySha256: $expectedPreviousEntrySha256",
    "BundledSchemaSha256: $($coreReport.Admission.BundledSchemaSha256)",
    "HerdrProtocol: $($coreReport.Admission.Protocol)",
    "SnapshotObserved: $($coreReport.SnapshotObserved)",
    "EventObserved: $($coreReport.EventObserved)",
    "ReconnectObserved: $($coreReport.ReconnectObserved)",
    "CompletionSignalObserved: $($coreReport.CompletionSignalObserved)",
    "CompletionSignalSemantics: $($coreReport.CompletionSignalSemantics)",
    "DisconnectCount: $($coreReport.FinalMonitorState.DisconnectCount)",
    "BootstrapCount: $($coreReport.FinalMonitorState.BootstrapCount)",
    "DashboardClosed: $($appReport.DashboardClosed)",
    "DashboardClosedUtc: $($appReport.DashboardClosedUtc)",
    "DisconnectObservedUtc: $($appReport.DisconnectObservedUtc)",
    "ReconnectObservedUtc: $($appReport.ReconnectObservedUtc)",
    "UpdateAfterDashboardClose: $($appReport.UpdateObservedAfterDashboardClose)",
    "InitialEventCount: $($appReport.InitialEventCount)",
    "PreCloseEventCount: $($appReport.PreCloseEventCount)",
    "EventBBaselineEventCount: $($appReport.EventBBaselineEventCount)",
    "PostCloseEventCount: $($appReport.PostCloseEventCount)",
    "PreRestartConnectionEpoch: $($appReport.PreRestartConnectionEpoch)",
    "ReconnectedConnectionEpoch: $($appReport.ReconnectedConnectionEpoch)",
    "PreRestartBootstrapCount: $($appReport.PreRestartBootstrapCount)",
    "ReconnectedBootstrapCount: $($appReport.ReconnectedBootstrapCount)",
    "PreRestartDisconnectCount: $($appReport.PreRestartDisconnectCount)",
    "ReconnectedDisconnectCount: $($appReport.ReconnectedDisconnectCount)",
    "WidgetLatencyBaselineSequence: $($appReport.WidgetLatencyBaselineSequence)",
    "WidgetLatencyWarmupSamplesExcluded: $($appReport.WidgetLatencyWarmupSamplesExcluded)",
    "WidgetLatencyUnsupportedSamplesExcluded: $($appReport.WidgetLatencyUnsupportedSamplesExcluded)",
    "WidgetLatencySamples: $($appReport.WidgetLatencySamples)",
    "WidgetLatencyMinimumSamples: $($appReport.WidgetLatencyMinimumSamples)",
    "WidgetLatencyMeasurement: $($appReport.WidgetLatencyMeasurement)",
    "WidgetLatencyTargetMs: $($appReport.WidgetLatencyTargetMilliseconds)",
    "WidgetLatencyP95Ms: $($appReport.WidgetLatencyP95Milliseconds)",
    "IdleQuiescenceSeconds: $($appReport.IdleQuiescence.RequiredStableSeconds)",
    "IdleQuiescenceWindow: $($appReport.IdleQuiescence.StableSinceUtc) -> $($appReport.IdleQuiescence.ReachedUtc)",
    "IdleQuiescenceState: sequence=$($appReport.IdleQuiescence.StableSequence) event=$($appReport.IdleQuiescence.StableEventCount) resets=$($appReport.IdleQuiescence.ResetCount)",
    "IdleCpuTargetPercent: $($appReport.ResourceMeasurement.CpuTargetPercent)",
    "IdleWorkingSetTargetMB: $($appReport.ResourceMeasurement.WorkingSetTargetMegabytes)",
    "ResourceSampleIntervalMs: $($appReport.ResourceMeasurement.SampleIntervalMilliseconds)",
    "ResourceSampleCount: $($appReport.ResourceMeasurement.SampleCount)",
    "CombinedIdleCpuPercent: $($appReport.ResourceMeasurement.CombinedAverageCpuPercent)",
    "CombinedAverageWorkingSetMB: $($appReport.ResourceMeasurement.CombinedAverageWorkingSetMegabytes)",
    "CombinedMaximumWorkingSetMB: $($appReport.ResourceMeasurement.CombinedMaximumWorkingSetMegabytes)",
    "AppAverageCpuPercent: $($appReport.ResourceMeasurement.App.AverageCpuPercent)",
    "AppAverageWorkingSetMB: $($appReport.ResourceMeasurement.App.AverageWorkingSetMegabytes)",
    "AppMaximumWorkingSetMB: $($appReport.ResourceMeasurement.App.MaximumWorkingSetMegabytes)",
    "AppAveragePrivateMemoryMB: $($appReport.ResourceMeasurement.App.AveragePrivateMemoryMegabytes)",
    "AppResourceProcess: pid=$($appReport.ResourceMeasurement.App.ProcessId) start=$($appReport.ResourceMeasurement.App.ProcessStartUtc) path=$($appReport.ResourceMeasurement.App.ExecutablePath) sha256=$($appReport.ResourceMeasurement.App.ExecutableSha256) stable=$($appReport.ResourceMeasurement.App.IdentityStable)",
    "CoreAverageCpuPercent: $($appReport.ResourceMeasurement.Core.AverageCpuPercent)",
    "CoreAverageWorkingSetMB: $($appReport.ResourceMeasurement.Core.AverageWorkingSetMegabytes)",
    "CoreMaximumWorkingSetMB: $($appReport.ResourceMeasurement.Core.MaximumWorkingSetMegabytes)",
    "CoreAveragePrivateMemoryMB: $($appReport.ResourceMeasurement.Core.AveragePrivateMemoryMegabytes)",
    "CoreResourceProcess: pid=$($appReport.ResourceMeasurement.Core.ProcessId) start=$($appReport.ResourceMeasurement.Core.ProcessStartUtc) path=$($appReport.ResourceMeasurement.Core.ExecutablePath) sha256=$($appReport.ResourceMeasurement.Core.ExecutableSha256) stable=$($appReport.ResourceMeasurement.Core.IdentityStable)",
    "DashboardResourcesReleased: $($appReport.ResourceMeasurement.Preparation.DashboardResourcesReleased)",
    "EvidenceWindowsDuringIdle: retained=$($appReport.ResourceMeasurement.Preparation.RetainedEvidenceWindows) visible=$($appReport.ResourceMeasurement.Preparation.VisibleEvidenceWindows)",
    "ManagedCaptureCleanup: attempted=$($appReport.ResourceMeasurement.Preparation.ManagedCaptureCleanupAttempted) completed=$($appReport.ResourceMeasurement.Preparation.ManagedCaptureCleanupCompleted) tracked=$($appReport.ResourceMeasurement.Preparation.TrackedCaptureBitmapCount) released=$($appReport.ResourceMeasurement.Preparation.ReleasedCaptureBitmapCount)",
    "RuntimeFingerprintStable: $($appReport.ResourceMeasurement.RuntimeFingerprintStable)",
    "RuntimeFingerprintStart: connected=$($appReport.ResourceMeasurement.StartFingerprint.IsCoreConnected) live=$($appReport.ResourceMeasurement.StartFingerprint.IsLive) status=$($appReport.ResourceMeasurement.StartFingerprint.RuntimeStatus) epoch=$($appReport.ResourceMeasurement.StartFingerprint.ConnectionEpoch) sequence=$($appReport.ResourceMeasurement.StartFingerprint.LastIngestSequence) bootstrap=$($appReport.ResourceMeasurement.StartFingerprint.BootstrapCount) event=$($appReport.ResourceMeasurement.StartFingerprint.EventCount) disconnect=$($appReport.ResourceMeasurement.StartFingerprint.DisconnectCount) reconciliation=$($appReport.ResourceMeasurement.StartFingerprint.ReconciliationCount) stateSha256=$($appReport.ResourceMeasurement.StartFingerprint.StateSha256)",
    "RuntimeFingerprintFinish: connected=$($appReport.ResourceMeasurement.FinishFingerprint.IsCoreConnected) live=$($appReport.ResourceMeasurement.FinishFingerprint.IsLive) status=$($appReport.ResourceMeasurement.FinishFingerprint.RuntimeStatus) epoch=$($appReport.ResourceMeasurement.FinishFingerprint.ConnectionEpoch) sequence=$($appReport.ResourceMeasurement.FinishFingerprint.LastIngestSequence) bootstrap=$($appReport.ResourceMeasurement.FinishFingerprint.BootstrapCount) event=$($appReport.ResourceMeasurement.FinishFingerprint.EventCount) disconnect=$($appReport.ResourceMeasurement.FinishFingerprint.DisconnectCount) reconciliation=$($appReport.ResourceMeasurement.FinishFingerprint.ReconciliationCount) stateSha256=$($appReport.ResourceMeasurement.FinishFingerprint.StateSha256)",
    "AppWorkingSetPreparationMB: before=$($appReport.ResourceMeasurement.Preparation.AppWorkingSetBeforeMegabytes) after=$($appReport.ResourceMeasurement.Preparation.AppWorkingSetAfterMegabytes)",
    "AppPrivateMemoryPreparationMB: before=$($appReport.ResourceMeasurement.Preparation.AppPrivateMemoryBeforeMegabytes) after=$($appReport.ResourceMeasurement.Preparation.AppPrivateMemoryAfterMegabytes)",
    "ManagedHeapPreparationMB: before=$($appReport.ResourceMeasurement.Preparation.ManagedHeapBeforeMegabytes) after=$($appReport.ResourceMeasurement.Preparation.ManagedHeapAfterMegabytes)",
    "IdleStateSequence: $($appReport.ResourceMeasurement.StartSequence)",
    "IdleEventCount: $($appReport.ResourceMeasurement.StartEventCount)",
    "RuntimeWpfCaptures: $($captures.Count)",
    'TcpListenersOwnedByCoreOrApp: 0',
    'AdministratorRequired: false',
    '',
    'StateHashChain:'
    "Initial: $($appReport.InitialSequence) $($appReport.InitialStateSha256)",
    "BeforeDashboardClose: $($appReport.PreCloseSequence) $($appReport.PreCloseStateSha256)",
    "AfterDashboardClose: $($appReport.PostCloseSequence) $($appReport.PostCloseStateSha256)",
    '',
    'WidgetLatencyIncludedSamples:'
) + ($includedLatencySamples | ForEach-Object {
    "sequence=$($_.StateSequence) event=$($_.EventCount) envelope=$($_.EnvelopeSequence) correlation=$($_.EnvelopeCorrelationId) stateSha256=$($_.StateSha256) kind=$($_.UpdateKind) accepted=$($_.CoreAcceptedStateUtc) sent=$($_.IpcSentUtc) applied=$($_.WpfAppliedUtc) milliseconds=$($_.Milliseconds)"
}) + @(
    '',
    'CaptureHashes:'
) + ($captures | ForEach-Object { "SHA256 $($_.Sha256) $($_.Name)" }) + @(
    '',
    'EvidenceBoundary:',
    'This gate proves exact-hash-bound actual Herdr snapshot/Agent-status-event/reconnect behavior, separate Acceptance-control and Agent-Lab target sessions, Core-to-App runtime-health propagation, live production WPF page and Widget rendering, Dashboard-close continuity, state-hash correspondence, measured latency/resources, no owned TCP listener, and non-elevated operation for this host and run.',
    'It does not prove packaging, clean-machine installation, later-version features, independent human review, or future Herdr releases.'
)
$reportLines | Set-Content -LiteralPath $gateReportPath -Encoding utf8
$gateHash = (Get-FileHash -LiteralPath $gateReportPath -Algorithm SHA256).Hash

$reportLines | Write-Output
Write-Output "GateReport: $gateReportPath"
Write-Output "GateReportSha256: $gateHash"
Write-Output "CoreRuntimeReport: $coreReportPath"
Write-Output "AppRuntimeReport: $appReportPath"
} catch {
    $failureRecord = $_
    $failureMessage = [string]$failureRecord.Exception.Message
    if ([string]::IsNullOrWhiteSpace($failureMessage)) {
        $failureMessage = [string]$failureRecord
    }
    $failureType = $failureRecord.Exception.GetType().FullName
    $reportedAppExitCode = if ($null -eq $appExitCode) {
        'NOT_OBSERVED'
    } else {
        [string]$appExitCode
    }
    $reportedCoreExitCode = if ($null -eq $coreExitCode) {
        'NOT_OBSERVED'
    } else {
        [string]$coreExitCode
    }
    Write-FailureGateReport `
        -GateReportPath $gateReportPath `
        -FailureMessage $failureMessage `
        -SourceCommit $sourceCommit `
        -CoreReportPath $coreReportPath `
        -AppReportPath $appReportPath `
        -ProgressHistoryPath $progressHistoryPath `
        -CoreExecutableHashBeforeLaunch $coreExecutableHashBeforeLaunch `
        -CoreExecutableHashAfterRun $coreExecutableHashAfterRun `
        -AppExecutableHashBeforeLaunch $appExecutableHashBeforeLaunch `
        -AppExecutableHashAfterRun $appExecutableHashAfterRun `
        -AppExitCode $reportedAppExitCode `
        -CoreExitCode $reportedCoreExitCode `
        -CoreAcceptedEventKindCheck $coreAcceptedEventKindCheck `
        -FailureType $failureType
    throw $failureRecord
}
