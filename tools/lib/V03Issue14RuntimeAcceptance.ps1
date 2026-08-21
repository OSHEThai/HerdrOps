# Issue #14 runtime-wrapper helpers. Keep this file Windows PowerShell 5.1 and
# PowerShell 7 compatible. These helpers never start Herdr or invoke session control.

function Get-V03Issue14JsonProperty {
    param(
        [Parameter(Mandatory = $true)] $Object,
        [Parameter(Mandatory = $true)] [string]$Name
    )

    if ($null -eq $Object) {
        throw "StrictJson: object is missing while reading '$Name'."
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        throw "StrictJson: required property '$Name' is missing."
    }

    return ,$property.Value
}

function Get-V03Issue14OptionalJsonProperty {
    param(
        [Parameter(Mandatory = $true)] $Object,
        [Parameter(Mandatory = $true)] [string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return ,$property.Value
}

function Assert-V03Issue14ObjectShape {
    param(
        [Parameter(Mandatory = $true)] $Object,
        [Parameter(Mandatory = $true)] [string[]]$Required,
        [Parameter(Mandatory = $true)] [string[]]$Allowed,
        [Parameter(Mandatory = $true)] [string]$Context
    )

    if ($null -eq $Object -or $Object -is [System.Array] -or $Object -is [string]) {
        throw "StrictJson: $Context must be a JSON object."
    }

    $names = @($Object.PSObject.Properties | ForEach-Object { $_.Name })
    foreach ($requiredName in $Required) {
        if (-not ($names | Where-Object { [string]::Equals($_, $requiredName, [StringComparison]::OrdinalIgnoreCase) })) {
            throw "StrictJson: $Context is missing '$requiredName'."
        }
    }

    foreach ($actualName in $names) {
        if (-not ($Allowed | Where-Object { [string]::Equals($_, $actualName, [StringComparison]::OrdinalIgnoreCase) })) {
            throw "StrictJson: $Context contains unknown property '$actualName'."
        }
    }
}

function Assert-V03Issue14JsonArray {
    param(
        [Parameter(Mandatory = $true)] $Value,
        [Parameter(Mandatory = $true)] [string]$Context
    )

    if ($null -eq $Value -or -not ($Value -is [System.Array])) {
        throw "StrictJson: $Context must be an array."
    }

    return @($Value)
}

function Assert-V03Issue14JsonString {
    param(
        [Parameter(Mandatory = $true)] [AllowNull()] $Value,
        [Parameter(Mandatory = $true)] [string]$Context,
        [int]$MaximumLength = 8192,
        [switch]$AllowNull
    )

    if ($null -eq $Value -and $AllowNull) {
        return $null
    }
    if ($null -eq $Value -or -not ($Value -is [string]) -or $Value.Length -gt $MaximumLength) {
        throw "StrictJson: $Context must be a string no longer than $MaximumLength characters."
    }

    return [string]$Value
}

function Assert-V03Issue14JsonBoolean {
    param(
        [Parameter(Mandatory = $true)] [AllowNull()] $Value,
        [Parameter(Mandatory = $true)] [string]$Context
    )

    if ($Value -isnot [bool]) {
        throw "StrictJson: $Context must be a JSON boolean."
    }
    return [bool]$Value
}

function Assert-V03Issue14JsonInteger {
    param(
        [Parameter(Mandatory = $true)] [AllowNull()] $Value,
        [Parameter(Mandatory = $true)] [string]$Context,
        [long]$Minimum = [long]::MinValue,
        [long]$Maximum = [long]::MaxValue
    )

    if ($Value -is [string] -or $Value -is [bool] -or $null -eq $Value) {
        throw "StrictJson: $Context must be an integer."
    }

    try {
        $decimal = [decimal]$Value
        $integer = [long]$decimal
    }
    catch {
        throw "StrictJson: $Context must be an integer."
    }

    if ($decimal -ne [decimal]$integer -or $integer -lt $Minimum -or $integer -gt $Maximum) {
        throw "StrictJson: $Context is outside integer range $Minimum..$Maximum."
    }

    return $integer
}

function Convert-V03Issue14UtcTimestamp {
    param(
        [Parameter(Mandatory = $true)] [AllowNull()] $Value,
        [Parameter(Mandatory = $true)] [string]$Context
    )

    if ($Value -is [DateTimeOffset]) {
        if ($Value.Offset -ne [TimeSpan]::Zero) {
            throw "StrictJson: $Context must use UTC (Z/+00:00)."
        }
        return $Value.ToUniversalTime()
    }
    if ($Value -is [DateTime]) {
        return [DateTimeOffset]$Value.ToUniversalTime()
    }

    $text = Assert-V03Issue14JsonString -Value $Value -Context $Context -MaximumLength 128
    try {
        $parsed = [DateTimeOffset]::Parse(
            $text,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind)
    }
    catch {
        throw "StrictJson: $Context is not a valid timestamp."
    }

    if ($parsed.Offset -ne [TimeSpan]::Zero) {
        throw "StrictJson: $Context must use UTC (Z/+00:00)."
    }
    return $parsed.ToUniversalTime()
}

function Assert-V03Issue14Sha256 {
    param(
        [Parameter(Mandatory = $true)] [AllowNull()] $Value,
        [Parameter(Mandatory = $true)] [string]$Context
    )

    $text = Assert-V03Issue14JsonString -Value $Value -Context $Context -MaximumLength 64
    if ($text -notmatch '^[0-9A-Fa-f]{64}$') {
        throw "StrictJson: $Context is not a SHA-256 hex value."
    }
    return $text.ToUpperInvariant()
}

function Get-V03Issue14FileSha256 {
    param(
        [Parameter(Mandatory = $true)] [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "MissingArtifact: file does not exist: $Path"
    }
    return ((Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash).ToUpperInvariant()
}

function Get-V03Issue14OptionalFileSha256 {
    param(
        [Parameter(Mandatory = $true)] [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return 'MISSING'
    }
    try {
        return Get-V03Issue14FileSha256 -Path $Path
    }
    catch {
        return 'UNAVAILABLE'
    }
}

function Assert-V03Issue14FreshArtifactPaths {
    param(
        [Parameter(Mandatory = $true)] [string[]]$Paths
    )

    foreach ($path in $Paths) {
        if (Test-Path -LiteralPath $path) {
            throw "ArtifactAlreadyExists: fresh run refuses to overwrite '$path'."
        }
    }
}

function Get-V03Issue14ExpectedHerdrIdentity {
    param(
        [Parameter(Mandatory = $true)] [string]$ExpectedExecutablePath,
        [Parameter(Mandatory = $true)] [string]$ExpectedExecutableSha256
    )

    $expectedSha = Assert-V03Issue14Sha256 -Value $ExpectedExecutableSha256 -Context 'ExpectedHerdrExecutableSha256'
    if (-not (Test-Path -LiteralPath $ExpectedExecutablePath -PathType Leaf)) {
        throw "ExpectedHerdrExecutableNotFound: $ExpectedExecutablePath"
    }

    $resolvedPath = (Resolve-Path -LiteralPath $ExpectedExecutablePath -ErrorAction Stop).Path
    $actualSha = Get-V03Issue14FileSha256 -Path $resolvedPath
    if ($actualSha -cne $expectedSha) {
        throw "ExpectedHerdrExecutableHashMismatch: expected=$expectedSha observed=$actualSha"
    }

    return [pscustomobject]@{
        ExecutablePath   = $resolvedPath
        ExecutableSha256 = $actualSha
    }
}

function Assert-V03Issue14ObservedHerdrIdentity {
    param(
        [Parameter(Mandatory = $true)] $Identity,
        [Parameter(Mandatory = $true)] [string]$ExpectedExecutablePath,
        [Parameter(Mandatory = $true)] [string]$ExpectedExecutableSha256,
        [Parameter(Mandatory = $true)] [string]$Context
    )

    Assert-V03Issue14ObjectShape `
        -Object $Identity `
        -Required @('ProcessId', 'ProcessStartUtc', 'ExecutablePath', 'ExecutableSha256') `
        -Allowed @('ProcessId', 'ProcessStartUtc', 'ExecutablePath', 'ExecutableSha256') `
        -Context $Context

    $pidValue = Assert-V03Issue14JsonInteger -Value (Get-V03Issue14JsonProperty $Identity 'ProcessId') -Context "$Context.ProcessId" -Minimum 1 -Maximum 2147483647
    $startUtc = Convert-V03Issue14UtcTimestamp -Value (Get-V03Issue14JsonProperty $Identity 'ProcessStartUtc') -Context "$Context.ProcessStartUtc"
    $path = Assert-V03Issue14JsonString -Value (Get-V03Issue14JsonProperty $Identity 'ExecutablePath') -Context "$Context.ExecutablePath" -MaximumLength 4096
    $sha = Assert-V03Issue14Sha256 -Value (Get-V03Issue14JsonProperty $Identity 'ExecutableSha256') -Context "$Context.ExecutableSha256"

    $resolvedExpectedPath = (Resolve-Path -LiteralPath $ExpectedExecutablePath -ErrorAction Stop).Path
    if (-not [StringComparer]::OrdinalIgnoreCase.Equals($path, $resolvedExpectedPath)) {
        throw "HerdrIdentityMismatch: $Context path is not the expected executable."
    }
    if ($sha -cne $ExpectedExecutableSha256.ToUpperInvariant()) {
        throw "HerdrIdentityMismatch: $Context SHA-256 is not the expected executable hash."
    }

    return [pscustomobject]@{
        ProcessId       = [int]$pidValue
        ProcessStartUtc = $startUtc
        ExecutablePath  = $path
        ExecutableSha256 = $sha
    }
}

function Assert-V03Issue14StableArtifactHashes {
    param(
        [Parameter(Mandatory = $true)] [string]$ReportPath,
        [Parameter(Mandatory = $true)] [string]$StdoutPath,
        [Parameter(Mandatory = $true)] [string]$StderrPath,
        [Parameter(Mandatory = $true)] [string]$ReportSha256,
        [Parameter(Mandatory = $true)] [string]$StdoutSha256,
        [Parameter(Mandatory = $true)] [string]$StderrSha256
    )

    $reportAfter = Get-V03Issue14FileSha256 -Path $ReportPath
    $stdoutAfter = Get-V03Issue14FileSha256 -Path $StdoutPath
    $stderrAfter = Get-V03Issue14FileSha256 -Path $StderrPath
    if ($reportAfter -cne $ReportSha256 -or $stdoutAfter -cne $StdoutSha256 -or $stderrAfter -cne $StderrSha256) {
        throw 'EvidenceChanged: report, stdout, or stderr changed after validation.'
    }
}

function Assert-V03Issue14StdoutMatchesReport {
    param(
        [Parameter(Mandatory = $true)] [string]$ReportPath,
        [Parameter(Mandatory = $true)] [string]$StdoutPath,
        [Parameter(Mandatory = $true)] [string]$StderrPath
    )

    $reportBytes = [IO.File]::ReadAllBytes($ReportPath)
    $stdoutBytes = [IO.File]::ReadAllBytes($StdoutPath)
    if ($reportBytes.Length -ne $stdoutBytes.Length) {
        throw 'StrictArtifact: stdout is not the exact JSON report byte stream.'
    }
    for ($index = 0; $index -lt $reportBytes.Length; $index++) {
        if ($reportBytes[$index] -ne $stdoutBytes[$index]) {
            throw 'StrictArtifact: stdout is not the exact JSON report byte stream.'
        }
    }

    if ((Get-Item -LiteralPath $StderrPath).Length -ne 0) {
        throw 'StrictExit: successful runtime capture must have an empty stderr artifact.'
    }
}

function Stop-V03Issue14ProcessTree {
    param(
        [Parameter(Mandatory = $true)] [System.Diagnostics.Process]$Process
    )

    $running = $false
    try { $running = -not $Process.HasExited } catch { $running = $true }
    if (-not $running) {
        return
    }

    $terminated = $false
    try {
        $Process.Kill($true)
        $terminated = $true
    }
    catch {
    }

    if (-not $terminated) {
        & taskkill.exe /PID ([string]$Process.Id) /T /F *> $null
        if ($LASTEXITCODE -ne 0) {
            throw "ProcessTerminationFailed: taskkill could not terminate process tree $($Process.Id)."
        }
    }

    try {
        if (-not $Process.WaitForExit(5000)) {
            throw "ProcessTerminationFailed: process tree $($Process.Id) did not exit within 5 seconds."
        }
    }
    catch {
        throw "ProcessTerminationFailed: $($_.Exception.Message)"
    }
}

function Wait-V03Issue14Process {
    param(
        [Parameter(Mandatory = $true)] [System.Diagnostics.Process]$Process,
        [Parameter(Mandatory = $true)] [int]$TimeoutSeconds,
        [Parameter(Mandatory = $true)] [string[]]$ArtifactPaths,
        [Parameter(Mandatory = $true)] [long]$MaximumArtifactBytes
    )

    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        foreach ($path in $ArtifactPaths) {
            if ((Test-Path -LiteralPath $path -PathType Leaf) -and
                (Get-Item -LiteralPath $path).Length -gt $MaximumArtifactBytes) {
                Stop-V03Issue14ProcessTree -Process $Process
                throw "ArtifactSizeExceeded: '$path' exceeded $MaximumArtifactBytes bytes."
            }
        }

        $hasExited = $false
        try { $hasExited = $Process.HasExited } catch { $hasExited = $false }
        if ($hasExited) {
            $Process.WaitForExit()
            return [pscustomobject]@{
                ExitCode = $Process.ExitCode
                ElapsedSeconds = $watch.Elapsed.TotalSeconds
            }
        }

        if ($watch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
            Stop-V03Issue14ProcessTree -Process $Process
            throw "CaptureTimedOut: external wall-clock timeout of $TimeoutSeconds seconds expired."
        }

        $remainingMilliseconds = [int](($TimeoutSeconds * 1000) - $watch.Elapsed.TotalMilliseconds)
        $waitMilliseconds = [Math]::Max(1, [Math]::Min(250, $remainingMilliseconds))
        [void]$Process.WaitForExit($waitMilliseconds)
    }
}

function Assert-V03Issue14RuntimeReport {
    param(
        [Parameter(Mandatory = $true)] [string]$ReportPath,
        [Parameter(Mandatory = $true)] [DateTimeOffset]$NotBeforeUtc,
        [Parameter(Mandatory = $true)] [string]$ExpectedHerdrExecutablePath,
        [Parameter(Mandatory = $true)] [string]$ExpectedHerdrExecutableSha256,
        [Parameter(Mandatory = $true)] [int]$ExpectedDurationSeconds,
        [Parameter(Mandatory = $true)] [int]$ExpectedIntervalMilliseconds,
        [Parameter(Mandatory = $true)] [int]$ExpectedMaximumLines,
        [long]$MaximumReportBytes = 33554432
    )

    if (-not (Test-Path -LiteralPath $ReportPath -PathType Leaf)) {
        throw "MissingEvidence: runtime report is missing: $ReportPath"
    }
    $item = Get-Item -LiteralPath $ReportPath
    if ($item.Length -le 0 -or $item.Length -gt $MaximumReportBytes) {
        throw "StrictArtifact: runtime report size is outside 1..$MaximumReportBytes bytes."
    }
    if ($item.LastWriteTimeUtc -lt $NotBeforeUtc.UtcDateTime) {
        throw 'StaleEvidence: runtime report predates this capture.'
    }

    $raw = [IO.File]::ReadAllText($ReportPath)
    $trimmed = $raw.Trim()
    if (-not $trimmed.StartsWith('{') -or -not $trimmed.EndsWith('}')) {
        throw 'StrictJson: runtime report must contain exactly one JSON object.'
    }
    try {
        $report = ConvertFrom-Json -InputObject $raw -ErrorAction Stop
    }
    catch {
        throw 'StrictJson: runtime report is not valid JSON.'
    }

    $top = @(
        'EvidenceClassification', 'RuntimeObserved', 'PaneReadObserved', 'ProcessCorrelationObserved',
        'SessionControlInvoked', 'UnboundedTerminalReadAttemptCount', 'MaximumTerminalLines',
        'StartedUtc', 'FinishedUtc', 'RequestedDurationSeconds', 'PollIntervalMilliseconds',
        'HostName', 'OperatingSystem', 'Admission', 'MonitorServerIdentity',
        'InspectionServerIdentity', 'FinalMonitorState', 'CollectionCycleCount',
        'TerminalReadAttemptCount', 'TerminalPreviewCount', 'ProcessPollAttemptCount',
        'ProcessTelemetryCount', 'ProcessFailureCount', 'CollectionFailureCount', 'Cycles', 'Message'
    )
    Assert-V03Issue14ObjectShape -Object $report -Required $top -Allowed $top -Context 'runtime report'

    if ((Assert-V03Issue14JsonString (Get-V03Issue14JsonProperty $report 'EvidenceClassification') 'EvidenceClassification' 32) -cne 'Runtime') {
        throw 'SyntheticEvidence: runtime report is not classified as Runtime.'
    }
    foreach ($name in @('RuntimeObserved', 'PaneReadObserved', 'ProcessCorrelationObserved')) {
        if (-not (Assert-V03Issue14JsonBoolean (Get-V03Issue14JsonProperty $report $name) $name)) {
            throw "SyntheticEvidence: $name must be true."
        }
    }
    if (Assert-V03Issue14JsonBoolean (Get-V03Issue14JsonProperty $report 'SessionControlInvoked') 'SessionControlInvoked') {
        throw 'SyntheticEvidence: SessionControlInvoked must be false.'
    }
    if ((Assert-V03Issue14JsonInteger (Get-V03Issue14JsonProperty $report 'UnboundedTerminalReadAttemptCount') 'UnboundedTerminalReadAttemptCount' 0 0) -ne 0) {
        throw 'SyntheticEvidence: unbounded terminal read count must be zero.'
    }

    $startedUtc = Convert-V03Issue14UtcTimestamp (Get-V03Issue14JsonProperty $report 'StartedUtc') 'StartedUtc'
    $finishedUtc = Convert-V03Issue14UtcTimestamp (Get-V03Issue14JsonProperty $report 'FinishedUtc') 'FinishedUtc'
    $notBefore = $NotBeforeUtc.ToUniversalTime()
    if ($startedUtc -lt $notBefore -or $finishedUtc -lt $startedUtc -or $finishedUtc -gt [DateTimeOffset]::UtcNow.AddMinutes(5)) {
        throw 'StrictJson: runtime timestamps are outside the fresh capture window.'
    }
    if ((Assert-V03Issue14JsonInteger (Get-V03Issue14JsonProperty $report 'RequestedDurationSeconds') 'RequestedDurationSeconds' 1 3600) -ne $ExpectedDurationSeconds) {
        throw 'StrictIdentity: RequestedDurationSeconds does not match the invocation.'
    }
    if ((Assert-V03Issue14JsonInteger (Get-V03Issue14JsonProperty $report 'PollIntervalMilliseconds') 'PollIntervalMilliseconds' 100 5000) -ne $ExpectedIntervalMilliseconds) {
        throw 'StrictIdentity: PollIntervalMilliseconds does not match the invocation.'
    }
    if ((Assert-V03Issue14JsonInteger (Get-V03Issue14JsonProperty $report 'MaximumTerminalLines') 'MaximumTerminalLines' 1 200) -ne $ExpectedMaximumLines) {
        throw 'StrictIdentity: MaximumTerminalLines does not match the invocation.'
    }
    Assert-V03Issue14JsonString (Get-V03Issue14JsonProperty $report 'HostName') 'HostName' 256 | Out-Null
    Assert-V03Issue14JsonString (Get-V03Issue14JsonProperty $report 'OperatingSystem') 'OperatingSystem' 512 | Out-Null
    Assert-V03Issue14JsonString (Get-V03Issue14JsonProperty $report 'Message') 'Message' 4096 | Out-Null

    $expectedPath = (Resolve-Path -LiteralPath $ExpectedHerdrExecutablePath -ErrorAction Stop).Path
    $expectedSha = (Assert-V03Issue14Sha256 $ExpectedHerdrExecutableSha256 'ExpectedHerdrExecutableSha256')
    $admission = Get-V03Issue14JsonProperty $report 'Admission'
    Assert-V03Issue14ObjectShape -Object $admission -Required @('ExecutablePath', 'ReleaseId', 'ExecutableSha256', 'ProtocolContractId', 'ProtocolContractRevision', 'BundledSchemaContractId', 'BundledSchemaContractRevision', 'BundledSchemaSha256', 'Protocol', 'Endpoint') -Allowed @('ExecutablePath', 'ReleaseId', 'ExecutableSha256', 'ProtocolContractId', 'ProtocolContractRevision', 'BundledSchemaContractId', 'BundledSchemaContractRevision', 'BundledSchemaSha256', 'Protocol', 'Endpoint') -Context 'Admission'
    if (-not [StringComparer]::OrdinalIgnoreCase.Equals((Assert-V03Issue14JsonString (Get-V03Issue14JsonProperty $admission 'ExecutablePath') 'Admission.ExecutablePath' 4096), $expectedPath)) { throw 'HerdrIdentityMismatch: Admission executable path.' }
    if ((Assert-V03Issue14Sha256 (Get-V03Issue14JsonProperty $admission 'ExecutableSha256') 'Admission.ExecutableSha256') -cne $expectedSha) { throw 'HerdrIdentityMismatch: Admission executable SHA-256.' }
    foreach ($name in @('ReleaseId', 'ProtocolContractId', 'BundledSchemaContractId')) { Assert-V03Issue14JsonString (Get-V03Issue14JsonProperty $admission $name) "Admission.$name" 512 | Out-Null }
    foreach ($name in @('ProtocolContractRevision', 'BundledSchemaContractRevision', 'Protocol')) { Assert-V03Issue14JsonInteger (Get-V03Issue14JsonProperty $admission $name) "Admission.$name" 1 2147483647 | Out-Null }
    $endpoint = Get-V03Issue14JsonProperty $admission 'Endpoint'
    Assert-V03Issue14ObjectShape -Object $endpoint -Required @('SocketPath', 'PipeName') -Allowed @('SocketPath', 'PipeName') -Context 'Admission.Endpoint'
    Assert-V03Issue14JsonString (Get-V03Issue14JsonProperty $endpoint 'SocketPath') 'Admission.Endpoint.SocketPath' 4096 | Out-Null
    Assert-V03Issue14JsonString (Get-V03Issue14JsonProperty $endpoint 'PipeName') 'Admission.Endpoint.PipeName' 512 | Out-Null

    $monitor = Assert-V03Issue14ObservedHerdrIdentity (Get-V03Issue14JsonProperty $report 'MonitorServerIdentity') $expectedPath $expectedSha 'MonitorServerIdentity'
    $inspection = Assert-V03Issue14ObservedHerdrIdentity (Get-V03Issue14JsonProperty $report 'InspectionServerIdentity') $expectedPath $expectedSha 'InspectionServerIdentity'
    if ($monitor.ProcessId -ne $inspection.ProcessId -or $monitor.ProcessStartUtc -ne $inspection.ProcessStartUtc) {
        throw 'HerdrIdentityMismatch: monitor and inspection identities are not the same process instance.'
    }

    $finalState = Get-V03Issue14JsonProperty $report 'FinalMonitorState'
    Assert-V03Issue14ObjectShape -Object $finalState -Required @('Status', 'State', 'ServerIdentity', 'BootstrapCount', 'EventCount', 'DisconnectCount', 'ReconciliationCount', 'LastTransitionUtc') -Allowed @('Status', 'State', 'ServerIdentity', 'BootstrapCount', 'EventCount', 'DisconnectCount', 'ReconciliationCount', 'LastTransitionReason', 'LastTransitionUtc', 'AcceptedEventKind', 'AcceptedAgentStatusEvent', 'AllAgentsHaveLiveIdentity') -Context 'FinalMonitorState'
    if ((Assert-V03Issue14JsonString (Get-V03Issue14JsonProperty $finalState 'Status') 'FinalMonitorState.Status' 64) -cne 'Stopped') { throw 'StrictTelemetry: final monitor status must be Stopped after bounded cancellation.' }
    if ((Assert-V03Issue14JsonInteger (Get-V03Issue14JsonProperty $finalState 'BootstrapCount') 'FinalMonitorState.BootstrapCount' 1 9223372036854775807) -lt 1) { throw 'StrictTelemetry: monitor never bootstrapped.' }
    foreach ($name in @('EventCount', 'DisconnectCount', 'ReconciliationCount')) { Assert-V03Issue14JsonInteger (Get-V03Issue14JsonProperty $finalState $name) "FinalMonitorState.$name" 0 9223372036854775807 | Out-Null }
    Convert-V03Issue14UtcTimestamp (Get-V03Issue14JsonProperty $finalState 'LastTransitionUtc') 'FinalMonitorState.LastTransitionUtc' | Out-Null
    Assert-V03Issue14ObservedHerdrIdentity (Get-V03Issue14JsonProperty $finalState 'ServerIdentity') $expectedPath $expectedSha 'FinalMonitorState.ServerIdentity' | Out-Null
    if ($null -eq (Get-V03Issue14JsonProperty $finalState 'State')) {
        throw 'StrictTelemetry: FinalMonitorState.State is missing.'
    }

    $cycleCount = Assert-V03Issue14JsonInteger (Get-V03Issue14JsonProperty $report 'CollectionCycleCount') 'CollectionCycleCount' 1 4096
    $terminalReadCount = Assert-V03Issue14JsonInteger (Get-V03Issue14JsonProperty $report 'TerminalReadAttemptCount') 'TerminalReadAttemptCount' 1 1000000
    $terminalPreviewCount = Assert-V03Issue14JsonInteger (Get-V03Issue14JsonProperty $report 'TerminalPreviewCount') 'TerminalPreviewCount' 1 1000000
    $processPollCount = Assert-V03Issue14JsonInteger (Get-V03Issue14JsonProperty $report 'ProcessPollAttemptCount') 'ProcessPollAttemptCount' 1 1000000
    $processTelemetryCount = Assert-V03Issue14JsonInteger (Get-V03Issue14JsonProperty $report 'ProcessTelemetryCount') 'ProcessTelemetryCount' 1 1000000
    foreach ($name in @('ProcessFailureCount', 'CollectionFailureCount')) { Assert-V03Issue14JsonInteger (Get-V03Issue14JsonProperty $report $name) $name 0 1000000 | Out-Null }
    $cycles = Assert-V03Issue14JsonArray -Value (Get-V03Issue14JsonProperty $report 'Cycles') -Context 'Cycles'
    if ($cycles.Count -ne $cycleCount) { throw 'StrictTelemetry: CollectionCycleCount does not match Cycles length.' }

    $previewTotal = 0
    $telemetryTotal = 0
    foreach ($cycle in $cycles) {
        Assert-V03Issue14ObjectShape -Object $cycle -Required @('StartedUtc', 'FinishedUtc', 'Connected', 'AvailablePaneCount', 'InspectedPaneCount', 'SkippedPaneCount', 'TerminalReadAttemptCount', 'ProcessPollAttemptCount', 'TerminalPreviews', 'ProcessTelemetry', 'ProcessFailures', 'CollectionFailures') -Allowed @('StartedUtc', 'FinishedUtc', 'Connected', 'AvailablePaneCount', 'InspectedPaneCount', 'SkippedPaneCount', 'TerminalReadAttemptCount', 'ProcessPollAttemptCount', 'TerminalPreviews', 'ProcessTelemetry', 'ProcessFailures', 'CollectionFailures') -Context 'Cycles[]'
        $cycleStarted = Convert-V03Issue14UtcTimestamp (Get-V03Issue14JsonProperty $cycle 'StartedUtc') 'Cycles[].StartedUtc'
        $cycleFinished = Convert-V03Issue14UtcTimestamp (Get-V03Issue14JsonProperty $cycle 'FinishedUtc') 'Cycles[].FinishedUtc'
        if ($cycleFinished -lt $cycleStarted) { throw 'StrictTelemetry: a collection cycle finishes before it starts.' }
        Assert-V03Issue14JsonBoolean (Get-V03Issue14JsonProperty $cycle 'Connected') 'Cycles[].Connected' | Out-Null
        foreach ($name in @('AvailablePaneCount', 'InspectedPaneCount', 'SkippedPaneCount', 'TerminalReadAttemptCount', 'ProcessPollAttemptCount')) { Assert-V03Issue14JsonInteger (Get-V03Issue14JsonProperty $cycle $name) "Cycles[].$name" 0 1000000 | Out-Null }
        $previews = Assert-V03Issue14JsonArray (Get-V03Issue14JsonProperty $cycle 'TerminalPreviews') 'Cycles[].TerminalPreviews'
        $telemetry = Assert-V03Issue14JsonArray (Get-V03Issue14JsonProperty $cycle 'ProcessTelemetry') 'Cycles[].ProcessTelemetry'
        $failures = Assert-V03Issue14JsonArray (Get-V03Issue14JsonProperty $cycle 'ProcessFailures') 'Cycles[].ProcessFailures'
        $collectionFailures = Assert-V03Issue14JsonArray (Get-V03Issue14JsonProperty $cycle 'CollectionFailures') 'Cycles[].CollectionFailures'
        $previewTotal += $previews.Count
        $telemetryTotal += $telemetry.Count
        foreach ($preview in $previews) {
            Assert-V03Issue14ObjectShape -Object $preview -Required @('PaneId', 'AgentTerminalId', 'SignaledRevision', 'ReadRevision', 'MaximumLines', 'Source', 'Format', 'SourceTruncated', 'ObservedUtc', 'RedactedSummary', 'RawPayloadSha256', 'RedactedPayloadSha256', 'RedactionCount', 'SummaryTruncated', 'PipelineDisposition', 'EventIdentitySha256') -Allowed @('PaneId', 'AgentTerminalId', 'SignaledRevision', 'ReadRevision', 'MaximumLines', 'Source', 'Format', 'SourceTruncated', 'ObservedUtc', 'RedactedSummary', 'RawPayloadSha256', 'RedactedPayloadSha256', 'RedactionCount', 'SummaryTruncated', 'PipelineDisposition', 'EventIdentitySha256') -Context 'TerminalPreviews[]'
            Assert-V03Issue14JsonString (Get-V03Issue14JsonProperty $preview 'PaneId') 'TerminalPreviews[].PaneId' 256 | Out-Null
            Assert-V03Issue14JsonString (Get-V03Issue14JsonProperty $preview 'AgentTerminalId') 'TerminalPreviews[].AgentTerminalId' 256 -AllowNull | Out-Null
            Assert-V03Issue14JsonInteger (Get-V03Issue14JsonProperty $preview 'SignaledRevision') 'TerminalPreviews[].SignaledRevision' 0 9223372036854775807 | Out-Null
            Assert-V03Issue14JsonInteger (Get-V03Issue14JsonProperty $preview 'ReadRevision') 'TerminalPreviews[].ReadRevision' 0 9223372036854775807 | Out-Null
            if ((Assert-V03Issue14JsonInteger (Get-V03Issue14JsonProperty $preview 'MaximumLines') 'TerminalPreviews[].MaximumLines' 1 200) -ne $ExpectedMaximumLines) { throw 'StrictTelemetry: terminal preview line bound mismatch.' }
            if ((Assert-V03Issue14JsonString (Get-V03Issue14JsonProperty $preview 'Source') 'TerminalPreviews[].Source' 64) -cne 'recent_unwrapped') { throw 'StrictTelemetry: terminal preview source is not recent_unwrapped.' }
            if ((Assert-V03Issue14JsonString (Get-V03Issue14JsonProperty $preview 'Format') 'TerminalPreviews[].Format' 64) -cne 'text') { throw 'StrictTelemetry: terminal preview format is not text.' }
            Assert-V03Issue14JsonBoolean (Get-V03Issue14JsonProperty $preview 'SourceTruncated') 'TerminalPreviews[].SourceTruncated' | Out-Null
            Convert-V03Issue14UtcTimestamp (Get-V03Issue14JsonProperty $preview 'ObservedUtc') 'TerminalPreviews[].ObservedUtc' | Out-Null
            Assert-V03Issue14JsonString (Get-V03Issue14JsonProperty $preview 'RedactedSummary') 'TerminalPreviews[].RedactedSummary' 4096 | Out-Null
            Assert-V03Issue14Sha256 (Get-V03Issue14JsonProperty $preview 'RawPayloadSha256') 'TerminalPreviews[].RawPayloadSha256' | Out-Null
            Assert-V03Issue14Sha256 (Get-V03Issue14JsonProperty $preview 'RedactedPayloadSha256') 'TerminalPreviews[].RedactedPayloadSha256' | Out-Null
            Assert-V03Issue14JsonInteger (Get-V03Issue14JsonProperty $preview 'RedactionCount') 'TerminalPreviews[].RedactionCount' 0 1000000 | Out-Null
            Assert-V03Issue14JsonBoolean (Get-V03Issue14JsonProperty $preview 'SummaryTruncated') 'TerminalPreviews[].SummaryTruncated' | Out-Null
            if ((Assert-V03Issue14JsonString (Get-V03Issue14JsonProperty $preview 'PipelineDisposition') 'TerminalPreviews[].PipelineDisposition' 64) -notin @('AcceptedImmediate', 'AcceptedBuffered')) { throw 'StrictTelemetry: terminal preview was not accepted by the activity pipeline.' }
            Assert-V03Issue14Sha256 (Get-V03Issue14JsonProperty $preview 'EventIdentitySha256') 'TerminalPreviews[].EventIdentitySha256' | Out-Null
        }
        foreach ($trace in $telemetry) {
            Assert-V03Issue14ObjectShape -Object $trace -Required @('Observation', 'PipelineDisposition', 'EventIdentitySha256') -Allowed @('Observation', 'PipelineDisposition', 'EventIdentitySha256') -Context 'ProcessTelemetry[]'
            $observation = Get-V03Issue14JsonProperty $trace 'Observation'
            Assert-V03Issue14ObjectShape -Object $observation -Required @('PaneId', 'ProcessId', 'ProcessStartUtc', 'ProcessName', 'ReportedSource', 'ReportedProcessName', 'ReportedCommandSha256', 'RedactedCommandSummary', 'CommandRedactionCount', 'ObservedUtc', 'ExpiresUtc', 'CpuPercent', 'WorkingSetBytes', 'PrivateMemoryBytes') -Allowed @('PaneId', 'ProcessId', 'ProcessStartUtc', 'ProcessName', 'ReportedSource', 'ReportedProcessName', 'ReportedCommandSha256', 'RedactedCommandSummary', 'CommandRedactionCount', 'ObservedUtc', 'ExpiresUtc', 'CpuPercent', 'WorkingSetBytes', 'PrivateMemoryBytes') -Context 'ProcessTelemetry[].Observation'
            Assert-V03Issue14JsonString (Get-V03Issue14JsonProperty $observation 'PaneId') 'ProcessTelemetry[].Observation.PaneId' 256 | Out-Null
            Assert-V03Issue14JsonInteger (Get-V03Issue14JsonProperty $observation 'ProcessId') 'ProcessTelemetry[].Observation.ProcessId' 1 2147483647 | Out-Null
            $observed = Convert-V03Issue14UtcTimestamp (Get-V03Issue14JsonProperty $observation 'ObservedUtc') 'ProcessTelemetry[].Observation.ObservedUtc'
            $expires = Convert-V03Issue14UtcTimestamp (Get-V03Issue14JsonProperty $observation 'ExpiresUtc') 'ProcessTelemetry[].Observation.ExpiresUtc'
            if ($expires -le $observed -or $expires -gt $observed.AddMinutes(10)) { throw 'StrictTelemetry: process telemetry expiry is invalid.' }
            Convert-V03Issue14UtcTimestamp (Get-V03Issue14JsonProperty $observation 'ProcessStartUtc') 'ProcessTelemetry[].Observation.ProcessStartUtc' | Out-Null
            foreach ($name in @('ProcessName', 'ReportedProcessName')) { Assert-V03Issue14JsonString (Get-V03Issue14JsonProperty $observation $name) "ProcessTelemetry[].Observation.$name" 256 | Out-Null }
            if ((Assert-V03Issue14JsonString (Get-V03Issue14JsonProperty $observation 'ReportedSource') 'ProcessTelemetry[].Observation.ReportedSource' 64) -notin @('Shell', 'Foreground')) { throw 'StrictTelemetry: unknown Herdr process source.' }
            Assert-V03Issue14Sha256 (Get-V03Issue14JsonProperty $observation 'ReportedCommandSha256') 'ProcessTelemetry[].Observation.ReportedCommandSha256' | Out-Null
            Assert-V03Issue14JsonString (Get-V03Issue14JsonProperty $observation 'RedactedCommandSummary') 'ProcessTelemetry[].Observation.RedactedCommandSummary' 4096 | Out-Null
            Assert-V03Issue14JsonInteger (Get-V03Issue14JsonProperty $observation 'CommandRedactionCount') 'ProcessTelemetry[].Observation.CommandRedactionCount' 0 1000000 | Out-Null
            $cpu = Get-V03Issue14JsonProperty $observation 'CpuPercent'
            if ($null -ne $cpu) {
                try { $cpuValue = [double]$cpu } catch { throw 'StrictTelemetry: CpuPercent is invalid.' }
                if ($cpuValue -lt 0 -or $cpuValue -gt 100) { throw 'StrictTelemetry: CpuPercent is outside 0..100.' }
            }
            Assert-V03Issue14JsonInteger (Get-V03Issue14JsonProperty $observation 'WorkingSetBytes') 'ProcessTelemetry[].Observation.WorkingSetBytes' 0 9223372036854775807 | Out-Null
            Assert-V03Issue14JsonInteger (Get-V03Issue14JsonProperty $observation 'PrivateMemoryBytes') 'ProcessTelemetry[].Observation.PrivateMemoryBytes' 0 9223372036854775807 | Out-Null
            if ((Assert-V03Issue14JsonString (Get-V03Issue14JsonProperty $trace 'PipelineDisposition') 'ProcessTelemetry[].PipelineDisposition' 64) -notin @('AcceptedImmediate', 'AcceptedBuffered')) { throw 'StrictTelemetry: process telemetry was not accepted by the activity pipeline.' }
            Assert-V03Issue14Sha256 (Get-V03Issue14JsonProperty $trace 'EventIdentitySha256') 'ProcessTelemetry[].EventIdentitySha256' | Out-Null
        }
        foreach ($failure in $failures) {
            Assert-V03Issue14ObjectShape -Object $failure -Required @('PaneId', 'ReportedProcessId', 'ReportedSource', 'Failure') -Allowed @('PaneId', 'ReportedProcessId', 'ReportedSource', 'Failure') -Context 'ProcessFailures[]'
        }
        foreach ($failure in $collectionFailures) {
            Assert-V03Issue14ObjectShape -Object $failure -Required @('PaneId', 'Operation', 'FailureCode') -Allowed @('PaneId', 'Operation', 'FailureCode') -Context 'CollectionFailures[]'
        }
    }

    if ($previewTotal -ne $terminalPreviewCount -or $telemetryTotal -ne $processTelemetryCount) { throw 'StrictTelemetry: report telemetry counts do not match cycle contents.' }
    if ($terminalReadCount -lt $terminalPreviewCount -or $processPollCount -lt $processTelemetryCount) { throw 'StrictTelemetry: attempt counts are lower than observed telemetry counts.' }
    if ($terminalPreviewCount -lt 1 -or $processTelemetryCount -lt 1) { throw 'MissingEvidence: terminal preview and process telemetry are both required.' }
    return $report
}

function Get-V03Issue14ReplayKey {
    param(
        [Parameter(Mandatory = $true)] [string]$ReportSha256,
        [Parameter(Mandatory = $true)] [string]$StdoutSha256,
        [Parameter(Mandatory = $true)] [string]$StderrSha256,
        [Parameter(Mandatory = $true)] [string]$GateReportSha256
    )
    foreach ($pair in @(@('ReportSha256', $ReportSha256), @('StdoutSha256', $StdoutSha256), @('StderrSha256', $StderrSha256), @('GateReportSha256', $GateReportSha256))) {
        Assert-V03Issue14Sha256 -Value $pair[1] -Context $pair[0] | Out-Null
    }
    return "ReportSha256=$($ReportSha256.ToUpperInvariant());StdoutSha256=$($StdoutSha256.ToUpperInvariant());StderrSha256=$($StderrSha256.ToUpperInvariant());GateReportSha256=$($GateReportSha256.ToUpperInvariant())"
}

function Assert-V03Issue14NotReplayed {
    param(
        [Parameter(Mandatory = $true)] [string]$LedgerPath,
        [Parameter(Mandatory = $true)] [string]$ReportSha256
    )
    if (Test-Path -LiteralPath $LedgerPath -PathType Leaf) {
        $needle = "ReportSha256=$($ReportSha256.ToUpperInvariant());"
        foreach ($line in @(Get-Content -LiteralPath $LedgerPath -ErrorAction Stop)) {
            if ($line.Contains($needle)) {
                throw "ReplayedEvidence: report SHA-256 $ReportSha256 is already in the Issue #14 replay ledger."
            }
        }
    }
}

function Add-V03Issue14ReplayLedgerEntry {
    param(
        [Parameter(Mandatory = $true)] [string]$LedgerPath,
        [Parameter(Mandatory = $true)] [string]$ReplayKey
    )
    $parent = Split-Path -Parent $LedgerPath
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    Add-Content -LiteralPath $LedgerPath -Value ("$([DateTimeOffset]::UtcNow.ToString('O'))|$ReplayKey") -Encoding utf8
}

function Write-V03Issue14FailureReport {
    param(
        [Parameter(Mandatory = $true)] [string]$GateReportPath,
        [Parameter(Mandatory = $true)] [string]$RunId,
        [Parameter(Mandatory = $true)] [string]$RunDirectory,
        [Parameter(Mandatory = $true)] [string]$ReportPath,
        [Parameter(Mandatory = $true)] [string]$StdoutPath,
        [Parameter(Mandatory = $true)] [string]$StderrPath,
        [Parameter(Mandatory = $true)] [string]$LedgerPath,
        [Parameter(Mandatory = $true)] [string]$ExpectedSourceCommit,
        [Parameter(Mandatory = $true)] [string]$ExpectedSourceTree,
        [Parameter(Mandatory = $true)] [string]$SourceCommit,
        [Parameter(Mandatory = $true)] [string]$SourceTree,
        [Parameter(Mandatory = $true)] [string]$PreRunSourceCommit,
        [Parameter(Mandatory = $true)] [string]$PreRunSourceTree,
        [Parameter(Mandatory = $true)] [string]$PreRunGitTreeClean,
        [Parameter(Mandatory = $true)] [string]$PostRunSourceCommit,
        [Parameter(Mandatory = $true)] [string]$PostRunSourceTree,
        [Parameter(Mandatory = $true)] [string]$PostRunGitTreeClean,
        [Parameter(Mandatory = $true)] [string]$PreCoreDllSha256,
        [Parameter(Mandatory = $true)] [string]$PostCoreDllSha256,
        [Parameter(Mandatory = $true)] [string]$ExpectedHerdrExecutablePath,
        [Parameter(Mandatory = $true)] [string]$ExpectedHerdrExecutableSha256,
        [Parameter(Mandatory = $true)] [string]$ReportSha256,
        [Parameter(Mandatory = $true)] [string]$StdoutSha256,
        [Parameter(Mandatory = $true)] [string]$StderrSha256,
        [Parameter(Mandatory = $true)] [string]$ProcessExitCode,
        [Parameter(Mandatory = $true)] [string]$FailureMessage
    )
    $lines = @(
        'HerdrOps v0.3 Issue #14 Terminal/Process Runtime Acceptance',
        'Result: FAIL',
        'EvidenceClass: NoRuntimeCredit',
        'RuntimeObserved: false',
        'SessionControlInvoked: false',
        "GeneratedUtc: $([DateTimeOffset]::UtcNow.ToString('O'))",
        "RunId: $RunId",
        "ArtifactRunDirectory: $RunDirectory",
        "ExpectedSourceCommit: $ExpectedSourceCommit",
        "ExpectedSourceTree: $ExpectedSourceTree",
        "SourceCommit: $SourceCommit",
        "SourceTree: $SourceTree",
        "PreRunSourceCommit: $PreRunSourceCommit",
        "PreRunSourceTree: $PreRunSourceTree",
        "PreRunGitTreeClean: $PreRunGitTreeClean",
        "PostRunSourceCommit: $PostRunSourceCommit",
        "PostRunSourceTree: $PostRunSourceTree",
        "PostRunGitTreeClean: $PostRunGitTreeClean",
        "PreCoreDllSha256: $PreCoreDllSha256",
        "PostCoreDllSha256: $PostCoreDllSha256",
        "ExpectedHerdrExecutablePath: $ExpectedHerdrExecutablePath",
        "ExpectedHerdrExecutableSha256: $ExpectedHerdrExecutableSha256",
        "ReportPath: $ReportPath",
        "ReportSha256: $ReportSha256",
        "StdoutPath: $StdoutPath",
        "StdoutSha256: $StdoutSha256",
        "StderrPath: $StderrPath",
        "StderrSha256: $StderrSha256",
        "ReplayLedgerPath: $LedgerPath",
        "ProcessExitCode: $ProcessExitCode",
        "Failure: $FailureMessage",
        'EvidenceBoundary: no Runtime or Release credit is emitted for any failure.'
    )
    Set-Content -LiteralPath $GateReportPath -Value $lines -Encoding utf8 -ErrorAction Stop
}
