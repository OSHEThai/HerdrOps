# HerdrOps v0.7 Live Performance Measurement Producer Policy
# Issue #39: Bounded fail-closed operator harness for actual-Herdr performance
# measurement (launch p95, reconnect time, widget state-delta latency, idle CPU,
# combined working set) with exact commit/artifact/session/role provenance,
# cancellation/timeouts, raw sample retention, and no synthetic-to-runtime
# promotion. Companion to docs/protocol/v0.7-performance-measurement-producer-contract.md

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -----------------------------------------------------------------------------
# Plan-Derived Budget Targets (Plan/RELEASE-GATES.md, Issue #39)
# -----------------------------------------------------------------------------
$script:V07MeasurementBudgetMaxIdleCpuAveragePercent = 1.0
$script:V07MeasurementBudgetMaxIdleWorkingSetCombinedBytes = [long](180 * 1024 * 1024)
$script:V07MeasurementBudgetMaxWidgetStateDeltaLatencyP95Ms = 250.0
$script:V07MeasurementBudgetMaxDashboardColdLaunchP95Ms = 2000.0
$script:V07MeasurementBudgetMaxHerdrReconnectReconcileSeconds = 5.0

# -----------------------------------------------------------------------------
# Producer Schema and Bound Constants
# -----------------------------------------------------------------------------
$script:V07MeasurementSchemaVersion = 'v0.7.0-measurement'
$script:V07SoakSchemaVersion = 'v0.7.0-soak'
$script:V07BudgetSchemaVersion = 'v0.7.0'
$script:V07MeasurementArtifactKind = 'PerformanceMeasurementRun'
$script:V07SoakArtifactKind = 'SoakRun'
$script:V07MeasurementMaxSamplesPerMetric = 4096
$script:V07MeasurementMinLaunchSamples = 3
$script:V07MeasurementMinLatencySamples = 3
$script:V07MeasurementMinReconnectSamples = 1
$script:V07MeasurementMinCpuSamples = 3
$script:V07MeasurementMinWorkingSetSamples = 3
$script:V07MeasurementMaxJsonBytes = 4 * 1024 * 1024
$script:V07MeasurementMaxRunSeconds = 7200
$script:V07MeasurementSoakMinHours = 8.0
$script:V07MeasurementSoakDurationToleranceSeconds = 1.0
$script:V07SoakMaxHeartbeatEntries = 10000
$script:V07SoakMaxFaultObservations = 64
$script:V07SoakMaxResourceSamples = 10000
$script:V07SoakMaxManifestEntries = 32
$script:V07SoakMaxArtifactBytes = 4 * 1024 * 1024
$script:V07MeasurementP95ToleranceMs = 0.05
$script:V07MeasurementCpuAverageTolerancePercent = 0.01
$script:V07MeasurementWorkingSetToleranceBytes = 1
$script:V07MeasurementReconnectToleranceSeconds = 0.05

$script:V07MeasurementMetrics = @(
    'DashboardColdLaunchP95Ms',
    'WidgetStateDeltaLatencyP95Ms',
    'HerdrReconnectReconcileSeconds',
    'IdleCpuAveragePercent',
    'IdleWorkingSetCombinedBytes',
    'UnboundedTerminalReads',
    'UnhandledCrashesDuringSoak',
    'SoakDurationHours',
    'AdministratorRequired'
)

$script:V07MeasurementObservedKeys = @(
    'DashboardColdLaunch',
    'WidgetStateDeltaLatency',
    'HerdrReconnectReconcile',
    'IdleCpu',
    'IdleWorkingSet'
)

$script:V07MeasurementRawSampleKeys = @(
    'DashboardColdLaunch',
    'WidgetStateDeltaLatency',
    'HerdrReconnectReconcile',
    'IdleCpu',
    'IdleWorkingSet'
)

$script:V07MeasurementMinSampleCount = @{
    DashboardColdLaunch       = $script:V07MeasurementMinLaunchSamples
    WidgetStateDeltaLatency   = $script:V07MeasurementMinLatencySamples
    HerdrReconnectReconcile   = $script:V07MeasurementMinReconnectSamples
    IdleCpu                   = $script:V07MeasurementMinCpuSamples
    IdleWorkingSet            = $script:V07MeasurementMinWorkingSetSamples
}

# -----------------------------------------------------------------------------
# Cryptographic and Path-Safety Helpers (self-contained; PS 5.1 and PS 7+)
# -----------------------------------------------------------------------------
function Get-V07Sha256Hex {
    [CmdletBinding(DefaultParameterSetName = 'Text')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Bytes', Position = 0)]
        [byte[]]$Bytes,

        [Parameter(Mandatory, ParameterSetName = 'Text', Position = 0)]
        [string]$Text,

        [Parameter(Mandatory, ParameterSetName = 'Path', Position = 0)]
        [string]$Path
    )

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        if ($PSCmdlet.ParameterSetName -eq 'Text') {
            $utf8 = New-Object System.Text.UTF8Encoding($false)
            $hashBytes = $sha256.ComputeHash($utf8.GetBytes($Text))
        } elseif ($PSCmdlet.ParameterSetName -eq 'Path') {
            if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
                throw "File not found for SHA-256 calculation: $Path"
            }
            $fileStream = [System.IO.File]::OpenRead($Path)
            try {
                $hashBytes = $sha256.ComputeHash($fileStream)
            } finally {
                $fileStream.Dispose()
            }
        } else {
            $hashBytes = $sha256.ComputeHash($Bytes)
        }

        $builder = New-Object System.Text.StringBuilder ($hashBytes.Length * 2)
        foreach ($b in $hashBytes) {
            [void]$builder.Append($b.ToString('x2', [Globalization.CultureInfo]::InvariantCulture))
        }
        return $builder.ToString()
    } finally {
        $sha256.Dispose()
    }
}

function ConvertTo-V07NormalizedSha256 {
    param([Parameter(Mandatory)][string]$Value)

    $trimmed = $Value.Trim().ToLowerInvariant()
    if ($trimmed -notmatch '^[0-9a-f]{64}$') {
        throw "SHA-256 digest must be exactly 64 lowercase hexadecimal characters; received '$Value'"
    }
    return $trimmed
}

function Assert-V07PathWithinRoot {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$AllowedRoots,
        [string]$Description = 'Path'
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "$Description cannot be null or whitespace."
    }
    if ($Path.Contains('..')) {
        throw "$Description contains disallowed relative traversal segment ('..'): $Path"
    }

    $separatorChars = [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $normalizedPath = [IO.Path]::GetFullPath($Path)
    $isAllowed = $false
    foreach ($root in $AllowedRoots) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        $normalizedRoot = [IO.Path]::GetFullPath($root).TrimEnd($separatorChars)
        $rootPrefix = $normalizedRoot + [IO.Path]::DirectorySeparatorChar
        if ($normalizedPath.Equals($normalizedRoot, [StringComparison]::OrdinalIgnoreCase) -or
            $normalizedPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            $isAllowed = $true
            break
        }
    }
    if (-not $isAllowed) {
        $rootsText = ($AllowedRoots | ForEach-Object { [IO.Path]::GetFullPath($_) }) -join '; '
        throw "$Description '$normalizedPath' resolves outside allowed roots ($rootsText)."
    }
    return $normalizedPath
}

function Assert-V07NotReparsePoint {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Description = 'Path'
    )

    $probe = [IO.Path]::GetFullPath($Path)
    while (-not [string]::IsNullOrWhiteSpace($probe)) {
        if (Test-Path -LiteralPath $probe) {
            $item = Get-Item -LiteralPath $probe -Force -ErrorAction Stop
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "$Description has a reparse-point ancestor (symlink/junction/mount): $probe"
            }
            if ($item.PSIsContainer) {
                $parent = $item.Parent
            } else {
                $parent = $item.Directory
            }
            if ($null -eq $parent) { break }
            $next = $parent.FullName
        } else {
            $next = [IO.Directory]::GetParent($probe)
        }
        if ([string]::IsNullOrWhiteSpace($next) -or $next.Equals($probe, [StringComparison]::OrdinalIgnoreCase)) { break }
        $probe = $next
    }
}

function Get-V07BoundedUtf8FileText {
    param(
        [Parameter(Mandatory)][string]$Path,
        [long]$MaxBytes = $script:V07MeasurementMaxJsonBytes,
        [string]$Description = 'File'
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Description does not exist: $Path"
    }
    Assert-V07NotReparsePoint -Path $Path -Description $Description

    $fileInfo = New-Object System.IO.FileInfo($Path)
    if ($fileInfo.Length -gt $MaxBytes) {
        throw "$Description exceeds maximum allowed size ($($fileInfo.Length) bytes > $MaxBytes bytes): $Path"
    }
    if ($fileInfo.Length -eq 0) {
        throw "$Description is unexpectedly empty (0 bytes): $Path"
    }

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false, $true)
    try {
        return $utf8NoBom.GetString($bytes)
    } catch {
        throw "$Description is not valid UTF-8 text: $Path ($($_.Exception.Message))"
    }
}

function Test-V07CleanRepositoryState {
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [switch]$SkipCleanCheck
    )

    $resolvedRoot = [IO.Path]::GetFullPath($RepositoryRoot)
    Assert-V07NotReparsePoint -Path $resolvedRoot -Description 'Repository root'

    $sourceCommitOutput = @(& git -C $resolvedRoot rev-parse --verify 'HEAD^{commit}' 2>&1)
    $sourceCommit = ($sourceCommitOutput -join '').Trim()
    if ($LASTEXITCODE -ne 0 -or $sourceCommit -notmatch '^[0-9a-f]{40}$') {
        throw "Could not resolve source commit at $resolvedRoot (exit code $LASTEXITCODE): $sourceCommit"
    }
    $pending = @(& git -C $resolvedRoot status --porcelain=v1 --untracked-files=all 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Could not inspect git status at $resolvedRoot (exit code $LASTEXITCODE)."
    }
    if ($pending.Count -ne 0 -and -not $SkipCleanCheck) {
        throw "Repository working tree is not clean at $resolvedRoot. Pending items: $($pending -join '; ')"
    }
    return $sourceCommit.ToLowerInvariant()
}

function ConvertTo-V07UtcText {
    param([Parameter(Mandatory)]$Value)

    if ($Value -is [DateTime]) {
        return ([DateTime]$Value).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Value -is [DateTimeOffset]) {
        return ([DateTimeOffset]$Value).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
    }
    return [string]$Value
}

function Test-V07UtcTimestampText {
    <#
    .SYNOPSIS
        Accepts ISO 8601 UTC text or DateTime/DateTimeOffset values (PS 5.1 keeps
        JSON timestamps as strings while PS 7.3+ converts ISO strings to DateTime)
        and verifies the UTC timestamp shape.
    #>
    param([Parameter(Mandatory)]$Text)

    if ($Text -is [DateTime] -or $Text -is [DateTimeOffset]) {
        $Text = ConvertTo-V07UtcText -Value $Text
    } else {
        $Text = [string]$Text
    }
    $parsed = [DateTimeOffset]::MinValue
    if ($Text -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$') {
        return $false
    }
    if (-not [DateTimeOffset]::TryParse(
            $Text,
            [Globalization.CultureInfo]::InvariantCulture,
            ([Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal),
            [ref]$parsed)) {
        return $false
    }
    return $parsed.Offset -eq [TimeSpan]::Zero
}

function ConvertTo-V07PositiveProcessId {
    param([Parameter(Mandatory)]$Value)

    if ($Value -isnot [System.Byte] -and $Value -isnot [System.Int16] -and $Value -isnot [System.Int32] -and
        $Value -isnot [System.Int64] -and $Value -isnot [System.UInt16] -and $Value -isnot [System.UInt32] -and
        $Value -isnot [System.UInt64]) {
        return $null
    }
    try {
        $normalized = [Convert]::ToInt64($Value, [Globalization.CultureInfo]::InvariantCulture)
    } catch {
        return $null
    }
    if ($normalized -le 0) { return $null }
    return $normalized
}

function ConvertTo-V07StrictNonNegativeInteger {
    <#
    .SYNOPSIS
        Converts a JSON number to an Int64 only when it is an integer-typed JSON
        number (never a double or a string). Returns $null otherwise so callers
        can fail closed on fractional or string-typed integers.
    #>
    param([Parameter(Mandatory)]$Value)

    if ($Value -isnot [System.Byte] -and $Value -isnot [System.Int16] -and $Value -isnot [System.Int32] -and
        $Value -isnot [System.Int64] -and $Value -isnot [System.UInt16] -and $Value -isnot [System.UInt32] -and
        $Value -isnot [System.UInt64]) {
        return $null
    }
    try {
        $normalized = [Convert]::ToInt64($Value, [Globalization.CultureInfo]::InvariantCulture)
    } catch {
        return $null
    }
    if ($normalized -lt 0) { return $null }
    return $normalized
}

function ConvertTo-V07StrictFiniteNumber {
    <# Converts a JSON numeric value to Double without accepting strings,
       booleans, NaN, or Infinity. #>
    param([Parameter(Mandatory)]$Value)

    if ($Value -is [bool] -or
        ($Value -isnot [System.Byte] -and $Value -isnot [System.SByte] -and
         $Value -isnot [System.Int16] -and $Value -isnot [System.UInt16] -and
         $Value -isnot [System.Int32] -and $Value -isnot [System.UInt32] -and
         $Value -isnot [System.Int64] -and $Value -isnot [System.UInt64] -and
         $Value -isnot [System.Single] -and $Value -isnot [System.Double] -and
         $Value -isnot [System.Decimal])) {
        return $null
    }
    try {
        $normalized = [double]$Value
    } catch {
        return $null
    }
    if ([double]::IsNaN($normalized) -or [double]::IsInfinity($normalized)) {
        return $null
    }
    return $normalized
}

function Assert-V07StrictJsonText {
    <#
    .SYNOPSIS
        Fails closed on hostile JSON: duplicate object keys, unknown/trailing
        content, NaN/Infinity literals, malformed numbers, control characters,
        and excess nesting. Uses the in-repo budget policy's strict C# parser
        (PS 5.1 and PS 7+ compatible).
    #>
    param(
        [Parameter(Mandatory)][string]$JsonText,
        [Parameter(Mandatory)][string]$SourceDescription
    )

    if ($null -eq ('HerdrOps.BudgetValidation.StrictJsonValidator' -as [type])) {
        $budgetPolicyPath = Join-Path $PSScriptRoot 'V07PerformanceBudgetPolicy.ps1'
        if (-not (Test-Path -LiteralPath $budgetPolicyPath -PathType Leaf)) {
            throw "Strict JSON validation requires the budget policy module: $budgetPolicyPath"
        }
        . $budgetPolicyPath
    }
    [void][HerdrOps.BudgetValidation.StrictJsonValidator]::ParseStrict($JsonText, $SourceDescription)
}

function Get-V07ArtifactCanonicalSha256 {
    <#
    .SYNOPSIS
        Canonical SHA-256 of a producer artifact object. The same serialization
        is used by the measurement producer, the finalizer, and the soak log so
        the cross-file run-id/hash chain is deterministic across PS 5.1 and PS 7+.
    #>
    param([Parameter(Mandatory)]$Artifact)

    $canonical = $Artifact | ConvertTo-Json -Depth 30 -Compress
    return Get-V07Sha256Hex -Text $canonical
}

function Get-V07SoakEntrySha256 {
    param([Parameter(Mandatory)]$Entry)

    $copy = ($Entry | ConvertTo-Json -Depth 20 -Compress) | ConvertFrom-Json
    if ($null -ne $copy.PSObject.Properties['EntrySha256']) {
        $copy.PSObject.Properties.Remove('EntrySha256')
    }
    return Get-V07ArtifactCanonicalSha256 -Artifact $copy
}

function Get-V07InstalledHerdrIdentitySha256 {
    param([Parameter(Mandatory)]$Identity)

    $canonical = [ordered]@{
        ProductId = [string]$Identity.ProductId
        ExecutablePath = [string]$Identity.ExecutablePath
        ExecutableSha256 = [string]$Identity.ExecutableSha256
        ReleaseId = [string]$Identity.ReleaseId
        PackageRoot = [string]$Identity.PackageRoot
    }
    return Get-V07ArtifactCanonicalSha256 -Artifact ([pscustomobject]$canonical)
}

function Test-V07AllowedProperties {
    param(
        [object]$Object,
        [Parameter(Mandatory)][string[]]$Allowed,
        [Parameter(Mandatory)][string]$Context
    )

    $failures = [System.Collections.Generic.List[string]]::new()
    if ($null -eq $Object) { return @($failures) }
    foreach ($property in $Object.PSObject.Properties) {
        if ($Allowed -notcontains $property.Name) {
            $failures.Add("$Context disallows unknown property '$($property.Name)'.")
        }
    }
    return @($failures)
}

function Get-V07P95 {
    param([Parameter(Mandatory)][double[]]$Samples)

    if ($null -eq $Samples -or $Samples.Length -eq 0) {
        throw 'P95 requires at least one sample.'
    }
    $sorted = [double[]]($Samples | Sort-Object)
    $index = [int][Math]::Ceiling(0.95 * $sorted.Length) - 1
    if ($index -lt 0) { $index = 0 }
    if ($index -ge $sorted.Length) { $index = $sorted.Length - 1 }
    return $sorted[$index]
}

# -----------------------------------------------------------------------------
# Live Session Admission (operator harness only; never invoked in self-tests)
# -----------------------------------------------------------------------------
function Test-V07LiveSessionAdmission {
    <#
    .SYNOPSIS
        Fail-closed admission of the exact candidate/Herdr session for a live
        measurement run. Throws when the current process is not running inside an
        authorized Herdr environment, when the control pane is not descended from
        the admitted Herdr server, or when the target session is not a separate,
        existing session socket.
    #>
    param(
        [Parameter(Mandatory)][string]$HerdrExecutable,
        [Parameter(Mandatory)][string]$TargetHerdrSocketPath,
        [switch]$SkipPaneCurrentCheck
    )

    if ($env:HERDR_ENV -ne '1') {
        throw 'Live performance measurement requires an authorized Herdr environment with HERDR_ENV=1.'
    }
    if ([string]::IsNullOrWhiteSpace($env:HERDR_SOCKET_PATH)) {
        throw 'Live performance measurement requires HERDR_SOCKET_PATH from the active Acceptance control pane.'
    }
    if ([string]::IsNullOrWhiteSpace($env:HERDR_PANE_ID)) {
        throw 'Live performance measurement requires HERDR_PANE_ID from the active Acceptance control pane.'
    }
    if (-not (Get-Command Get-CimInstance -ErrorAction SilentlyContinue)) {
        throw 'Get-CimInstance is required to bind the gate process to its Acceptance control Herdr server.'
    }
    if (-not (Test-Path -LiteralPath $HerdrExecutable -PathType Leaf)) {
        throw "Installed Herdr executable not found: $HerdrExecutable"
    }
    if (-not (Test-Path -LiteralPath $env:HERDR_SOCKET_PATH -PathType Leaf)) {
        throw "The Acceptance control socket does not exist: $($env:HERDR_SOCKET_PATH)"
    }
    if (-not (Test-Path -LiteralPath $TargetHerdrSocketPath -PathType Leaf)) {
        throw "The target Agent Lab socket does not exist: $TargetHerdrSocketPath"
    }

    $resolvedHerdr = (Resolve-Path -LiteralPath $HerdrExecutable).Path
    $controlSocket = (Resolve-Path -LiteralPath $env:HERDR_SOCKET_PATH).Path
    $targetSocket = (Resolve-Path -LiteralPath $TargetHerdrSocketPath).Path
    if ([StringComparer]::OrdinalIgnoreCase.Equals($controlSocket, $targetSocket)) {
        throw 'Acceptance control and target Agent Lab sockets must be different. Restarting the control session would terminate the gate process.'
    }

    # Verify the active control pane through the admitted Herdr executable.
    $observedControlPaneId = ''
    if (-not $SkipPaneCurrentCheck) {
        $controlPaneOutput = @(& $resolvedHerdr pane current --current)
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
    }

    # Walk the process ancestor chain to the live Herdr server.
    $serverIdentity = $null
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
            if (-not [StringComparer]::OrdinalIgnoreCase.Equals($resolvedCandidatePath, $resolvedHerdr)) {
                throw "The Acceptance control pane belongs to an unexpected Herdr executable: $resolvedCandidatePath"
            }
            $runtimeProcess = Get-Process -Id ([int]$candidate.ProcessId) -ErrorAction Stop
            $serverIdentity = [pscustomobject]@{
                ProcessId = [int]$candidate.ProcessId
                ProcessStartUtc = ConvertTo-V07UtcText -Value $runtimeProcess.StartTime.ToUniversalTime()
                ExecutablePath = $resolvedCandidatePath
                ExecutableSha256 = ConvertTo-V07NormalizedSha256 -Value (Get-FileHash -LiteralPath $resolvedCandidatePath -Algorithm SHA256).Hash
            }
            break
        }
        $parentProcessId = [int]$candidate.ParentProcessId
        if ($parentProcessId -le 0 -or $parentProcessId -eq $currentProcessId) { break }
        $currentProcessId = $parentProcessId
    }
    if ($null -eq $serverIdentity) {
        throw 'The gate process is not descended from a live Herdr server. Run it directly in a fresh Acceptance session pane.'
    }

    # Admitted Herdr release identification (parsed from `herdr --version`, non-fatal if unavailable).
    $herdrReleaseId = ''
    $versionOutput = @(& $resolvedHerdr --version 2>&1)
    if ($LASTEXITCODE -eq 0) {
        $herdrReleaseId = (($versionOutput -join ' ').Trim())
    }

    return [pscustomobject]@{
        ControlPaneId = [string]$env:HERDR_PANE_ID
        ObservedControlPaneId = $observedControlPaneId
        ControlHerdrSocketPath = $controlSocket
        TargetHerdrSocketPath = $targetSocket
        SeparateSessions = $true
        HerdrExecutablePath = $resolvedHerdr
        HerdrExecutableSha256 = $serverIdentity.ExecutableSha256
        HerdrReleaseId = $herdrReleaseId
        ControlHerdrServerIdentity = $serverIdentity
    }
}

# -----------------------------------------------------------------------------
# Candidate Binding (exact commit + on-disk artifact hashes)
# -----------------------------------------------------------------------------
function New-V07CandidateBinding {
    <#
    .SYNOPSIS
        Binds the measurement run to the exact current HEAD and on-disk candidate
        binaries. Fails closed when the repository is dirty (unless -SkipCleanCheck)
        or when any required candidate binary is absent.
    #>
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$CandidateDirectory,
        [switch]$SkipCleanCheck
    )

    $resolvedRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path
    $resolvedCandidate = (Resolve-Path -LiteralPath $CandidateDirectory).Path
    Assert-V07NotReparsePoint -Path $resolvedRoot -Description 'Repository root'
    Assert-V07NotReparsePoint -Path $resolvedCandidate -Description 'Candidate directory'
    $sourceCommit = Test-V07CleanRepositoryState -RepositoryRoot $resolvedRoot -SkipCleanCheck:$SkipCleanCheck

    $requiredRelPaths = @(
        'artifacts/bin/HerdrOps.Core/release/HerdrOps.Core.dll',
        'artifacts/bin/HerdrOps.App/release/HerdrOps.App.dll'
    )
    $bindings = [System.Collections.Generic.List[object]]::new()
    foreach ($rel in $requiredRelPaths) {
        $fullPath = Join-Path $resolvedRoot ($rel.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
            throw "Candidate binary prerequisite missing -- run Invoke-Build.ps1 first: $rel"
        }
        Assert-V07NotReparsePoint -Path $fullPath -Description "Candidate binary $rel"
        $fullPathWithinRoot = Assert-V07PathWithinRoot -Path $fullPath -AllowedRoots @($resolvedRoot, $resolvedCandidate) -Description "Candidate binary $rel"
        $fi = Get-Item -LiteralPath $fullPathWithinRoot -Force -ErrorAction Stop
        $bindings.Add([pscustomobject]@{
            RelativePath = $rel
            LengthBytes  = [long]$fi.Length
            Sha256       = Get-V07Sha256Hex -Path $fullPathWithinRoot
        })
    }

    $sourceTree = (@(& git -C $resolvedRoot rev-parse 'HEAD^{tree}' 2>&1 | ForEach-Object { [string]$_ }) -join '').Trim()
    if ($LASTEXITCODE -ne 0 -or $sourceTree -notmatch '^[0-9a-f]{40}$') {
        throw "Could not resolve the exact Git tree for candidate HEAD: $sourceTree"
    }

    return [pscustomobject]@{
        SourceCommit = $sourceCommit
        SourceTree   = $sourceTree.ToLowerInvariant()
        GitTreeClean = $true
        Binaries     = @($bindings)
    }
}

# -----------------------------------------------------------------------------
# Raw Sample Extraction from App / Core Evidence Artifacts
# -----------------------------------------------------------------------------
function Get-V07DeltaLatencySamplesFromAppReport {
    <#
    .SYNOPSIS
        Extracts widget state-delta latency raw samples from an App
        runtime-evidence report (WidgetLatencyIncludedSamples,
        CoreAcceptedStateUtcToWpfStateApplied).
    #>
    param(
        [Parameter(Mandatory)]$AppReport,
        [Parameter(Mandatory)][long]$CoreProcessId,
        [Parameter(Mandatory)][long]$AppProcessId
    )

    $samples = [System.Collections.Generic.List[object]]::new()
    if ($null -eq $AppReport.PSObject.Properties['WidgetLatencyIncludedSamples']) {
        return @($samples)
    }
    $included = @($AppReport.WidgetLatencyIncludedSamples)
    foreach ($item in $included) {
        $milliseconds = $null
        if ($null -ne $item.PSObject.Properties['Milliseconds']) {
            $milliseconds = [double]$item.Milliseconds
        }
        $observedUtc = if ($null -ne $item.PSObject.Properties['ObservedUtc']) {
            ConvertTo-V07UtcText -Value $item.ObservedUtc
        } else {
            ''
        }
        $updateKind = if ($null -ne $item.PSObject.Properties['UpdateKind']) {
            [string]$item.UpdateKind
        } else {
            ''
        }
        $samples.Add([pscustomobject]@{
            ObservedUtc = $observedUtc
            Milliseconds = $milliseconds
            AppProcessId = $AppProcessId
            CoreProcessId = $CoreProcessId
            UpdateKind = $updateKind
        })
    }
    return @($samples)
}

function Get-V07ReconnectSamplesFromCoreTrace {
    <#
    .SYNOPSIS
        Computes Herdr reconnect-and-reconcile samples from a Core runtime trace
        report. A sample is the elapsed time from a transition that increments
        DisconnectCount to the next Connected transition that advances BootstrapCount
        with a fresh verified server identity.
    #>
    param(
        [Parameter(Mandatory)]$CoreTraceReport
    )

    $samples = [System.Collections.Generic.List[object]]::new()
    if ($null -eq $CoreTraceReport.PSObject.Properties['Transitions']) {
        return @($samples)
    }
    $transitions = @($CoreTraceReport.Transitions)
    $disconnectUtc = $null
    $disconnectBootstrap = 0L
    $disconnectServerPid = 0L
    for ($index = 0; $index -lt $transitions.Count; $index++) {
        $transition = $transitions[$index]
        $status = [string]$transition.Status
        $disconnectCount = if ($null -ne $transition.PSObject.Properties['DisconnectCount']) { [long]$transition.DisconnectCount } else { 0L }
        $bootstrapCount = if ($null -ne $transition.PSObject.Properties['BootstrapCount']) { [long]$transition.BootstrapCount } else { 0L }
        $observedUtc = ConvertTo-V07UtcText -Value $transition.ObservedUtc
        $serverIdentity = if ($null -ne $transition.PSObject.Properties['ServerIdentity']) { $transition.ServerIdentity } else { $null }

        if ($null -ne $disconnectUtc) {
            # Looking for the reconnect after an observed disconnect.
            if ($status -eq 'Connected' -and
                $bootstrapCount -gt $disconnectBootstrap -and
                $null -ne $serverIdentity) {
                $serverPid = ConvertTo-V07PositiveProcessId -Value $serverIdentity.ProcessId
                if ($null -ne $serverPid) {
                    $reconnectUtc = $observedUtc
                    $seconds = ([DateTimeOffset]$reconnectUtc - [DateTimeOffset]$disconnectUtc).TotalSeconds
                    $samples.Add([pscustomobject]@{
                        ObservedUtc = $reconnectUtc
                        Seconds = [Math]::Max(0.0, [double]$seconds)
                        DisconnectTransitionUtc = $disconnectUtc
                        ReconnectTransitionUtc = $reconnectUtc
                        ReconnectBootstrapCount = $bootstrapCount
                        ReconnectServerPid = $serverPid
                    })
                    $disconnectUtc = $null
                    $disconnectBootstrap = 0L
                    $disconnectServerPid = 0L
                }
            }
            continue
        }

        if ($disconnectCount -gt 0 -and $status -ne 'Connected') {
            # A disconnect boundary: remember it and watch for the fresh bootstrap.
            if ($null -eq $disconnectUtc -or $observedUtc -gt $disconnectUtc) {
                $disconnectUtc = $observedUtc
                $disconnectBootstrap = $bootstrapCount
                $disconnectServerPid = if ($null -ne $serverIdentity) {
                    [long]$serverIdentity.ProcessId
                } else { 0L }
            }
        }
    }
    return @($samples)
}

# -----------------------------------------------------------------------------
# Raw Sample Integrity
# -----------------------------------------------------------------------------
function Test-V07RawSamplesForMetric {
    <#
    .SYNOPSIS
        Validates a raw sample array for one metric. Returns a result object with
        Valid/Failures/Count. Every sample must be finite, non-negative, within
        the run window, bound to the observed role PIDs where applicable, and
        within the retention cap.
    #>
    param(
        [Parameter(Mandatory)][string]$MetricName,
        [Parameter(Mandatory)]$Samples,
        [Parameter(Mandatory)]$RunStartedUtc,
        [Parameter(Mandatory)]$RunFinishedUtc,
        [long]$CoreProcessId = 0,
        [long]$AppProcessId = 0
    )

    $failures = [System.Collections.Generic.List[string]]::new()
    $count = if ($null -eq $Samples) { 0 } else { @($Samples).Count }
    $minCount = $script:V07MeasurementMinSampleCount[$MetricName]
    if ($count -lt $minCount) {
        $failures.Add("$MetricName raw sample count $count is below the required minimum $minCount.")
    }
    if ($count -gt $script:V07MeasurementMaxSamplesPerMetric) {
        $failures.Add("$MetricName raw sample count $count exceeds the retention cap $($script:V07MeasurementMaxSamplesPerMetric).")
    }
    if ($count -eq 0) {
        return [pscustomobject]@{ Valid = ($failures.Count -eq 0); Failures = @($failures); Count = 0 }
    }

    $startOffset = [DateTimeOffset]$RunStartedUtc
    $endOffset = [DateTimeOffset]$RunFinishedUtc
    if ($startOffset -gt $endOffset) {
        $failures.Add('RunStartedUtc is later than RunFinishedUtc.')
    }

    $ordinal = 0
    foreach ($sample in @($Samples)) {
        $ordinal++
        if ($null -eq $sample -or $sample -isnot [pscustomobject]) {
            $failures.Add("$MetricName sample $ordinal is not an object.")
            continue
        }
        $observedUtc = if ($null -ne $sample.PSObject.Properties['ObservedUtc']) { $sample.ObservedUtc } else { '' }
        if (-not (Test-V07UtcTimestampText -Text $observedUtc)) {
            $failures.Add("$MetricName sample $ordinal has an invalid ObservedUtc '$observedUtc'.")
        } elseif ($startOffset -le $endOffset) {
            $sampleOffset = [DateTimeOffset]$observedUtc
            if ($sampleOffset -lt $startOffset -or $sampleOffset -gt $endOffset) {
                $failures.Add("$MetricName sample $ordinal ObservedUtc '$observedUtc' is outside the run window.")
            }
        }

        switch ($MetricName) {
            'DashboardColdLaunch' {
                $ms = if ($null -ne $sample.PSObject.Properties['Milliseconds']) { [double]$sample.Milliseconds } else { [double]::NaN }
                if ([double]::IsNaN($ms) -or [double]::IsInfinity($ms) -or $ms -lt 0.0) {
                    $failures.Add("$MetricName sample $ordinal has an invalid Milliseconds value.")
                }
                $runOrdinal = if ($null -ne $sample.PSObject.Properties['RunOrdinal']) { ConvertTo-V07StrictNonNegativeInteger -Value $sample.RunOrdinal } else { $null }
                if ($null -eq $runOrdinal -or $runOrdinal -le 0) {
                    $failures.Add("$MetricName sample $ordinal has an invalid RunOrdinal (must be a positive integer).")
                }
                $termination = if ($null -ne $sample.PSObject.Properties['Termination']) { [string]$sample.Termination } else { '' }
                if ($termination -notin @('Graceful', 'Kill', 'Completed')) {
                    $failures.Add("$MetricName sample $ordinal has an invalid Termination '$termination'.")
                }
                $appPidValue = if ($null -ne $sample.PSObject.Properties['AppProcessId']) { $sample.AppProcessId } else { $null }
                $corePidValue = if ($null -ne $sample.PSObject.Properties['CoreProcessId']) { $sample.CoreProcessId } else { $null }
                if ($null -eq $appPidValue -or $null -eq (ConvertTo-V07PositiveProcessId -Value $appPidValue) -or
                    (ConvertTo-V07PositiveProcessId -Value $appPidValue) -ne $AppProcessId) {
                    $failures.Add("$MetricName sample $ordinal AppProcessId does not match the observed App role PID.")
                }
                if ($null -eq $corePidValue -or $null -eq (ConvertTo-V07PositiveProcessId -Value $corePidValue) -or
                    (ConvertTo-V07PositiveProcessId -Value $corePidValue) -ne $CoreProcessId) {
                    $failures.Add("$MetricName sample $ordinal CoreProcessId does not match the observed Core role PID.")
                }
            }
            'WidgetStateDeltaLatency' {
                $ms = if ($null -ne $sample.PSObject.Properties['Milliseconds']) { [double]$sample.Milliseconds } else { [double]::NaN }
                if ([double]::IsNaN($ms) -or [double]::IsInfinity($ms) -or $ms -lt 0.0) {
                    $failures.Add("$MetricName sample $ordinal has an invalid Milliseconds value.")
                }
                $updateKind = if ($null -ne $sample.PSObject.Properties['UpdateKind']) { [string]$sample.UpdateKind } else { '' }
                if ($updateKind -notin @('Delta', 'Snapshot')) {
                    $failures.Add("$MetricName sample $ordinal has an invalid UpdateKind '$updateKind'.")
                }
                $appPidValue = if ($null -ne $sample.PSObject.Properties['AppProcessId']) { $sample.AppProcessId } else { $null }
                $corePidValue = if ($null -ne $sample.PSObject.Properties['CoreProcessId']) { $sample.CoreProcessId } else { $null }
                if ($null -eq $appPidValue -or $null -eq (ConvertTo-V07PositiveProcessId -Value $appPidValue) -or
                    (ConvertTo-V07PositiveProcessId -Value $appPidValue) -ne $AppProcessId) {
                    $failures.Add("$MetricName sample $ordinal AppProcessId does not match the observed App role PID.")
                }
                if ($null -eq $corePidValue -or $null -eq (ConvertTo-V07PositiveProcessId -Value $corePidValue) -or
                    (ConvertTo-V07PositiveProcessId -Value $corePidValue) -ne $CoreProcessId) {
                    $failures.Add("$MetricName sample $ordinal CoreProcessId does not match the observed Core role PID.")
                }
            }
            'HerdrReconnectReconcile' {
                $seconds = if ($null -ne $sample.PSObject.Properties['Seconds']) { [double]$sample.Seconds } else { [double]::NaN }
                if ([double]::IsNaN($seconds) -or [double]::IsInfinity($seconds) -or $seconds -lt 0.0) {
                    $failures.Add("$MetricName sample $ordinal has an invalid Seconds value.")
                }
                $disconnectUtc = if ($null -ne $sample.PSObject.Properties['DisconnectTransitionUtc']) { $sample.DisconnectTransitionUtc } else { '' }
                $reconnectUtc = if ($null -ne $sample.PSObject.Properties['ReconnectTransitionUtc']) { $sample.ReconnectTransitionUtc } else { '' }
                if (-not (Test-V07UtcTimestampText -Text $disconnectUtc) -or
                    -not (Test-V07UtcTimestampText -Text $reconnectUtc)) {
                    $failures.Add("$MetricName sample $ordinal has invalid disconnect/reconnect transition timestamps.")
                } else {
                    if (([DateTimeOffset]$disconnectUtc) -gt ([DateTimeOffset]$reconnectUtc)) {
                        $failures.Add("$MetricName sample $ordinal disconnect transition is later than reconnect transition.")
                    }
                    $elapsed = ([DateTimeOffset]$reconnectUtc - [DateTimeOffset]$disconnectUtc).TotalSeconds
                    if ([Math]::Abs($elapsed - $seconds) -gt $script:V07MeasurementReconnectToleranceSeconds) {
                        $failures.Add("$MetricName sample $ordinal Seconds does not match the transition delta.")
                    }
                }
                $bootstrapCount = if ($null -ne $sample.PSObject.Properties['ReconnectBootstrapCount']) { ConvertTo-V07StrictNonNegativeInteger -Value $sample.ReconnectBootstrapCount } else { $null }
                if ($null -eq $bootstrapCount -or $bootstrapCount -le 0) {
                    $failures.Add("$MetricName sample $ordinal has an invalid ReconnectBootstrapCount (must be a positive integer).")
                }
                $reconnectServerPid = if ($null -ne $sample.PSObject.Properties['ReconnectServerPid']) { $sample.ReconnectServerPid } else { $null }
                if ($null -eq $reconnectServerPid -or $null -eq (ConvertTo-V07PositiveProcessId -Value $reconnectServerPid)) {
                    $failures.Add("$MetricName sample $ordinal has an invalid ReconnectServerPid.")
                }
            }
            'IdleCpu' {
                $percent = if ($null -ne $sample.PSObject.Properties['Percent']) { [double]$sample.Percent } else { [double]::NaN }
                if ([double]::IsNaN($percent) -or [double]::IsInfinity($percent) -or $percent -lt 0.0 -or $percent -gt 100.0) {
                    $failures.Add("$MetricName sample $ordinal has an invalid Percent value.")
                }
                $sampleOrdinal = if ($null -ne $sample.PSObject.Properties['SampleOrdinal']) { ConvertTo-V07StrictNonNegativeInteger -Value $sample.SampleOrdinal } else { $null }
                if ($null -eq $sampleOrdinal -or $sampleOrdinal -le 0) {
                    $failures.Add("$MetricName sample $ordinal has an invalid SampleOrdinal (must be a positive integer).")
                }
            }
            'IdleWorkingSet' {
                $bytes = if ($null -ne $sample.PSObject.Properties['Bytes']) { ConvertTo-V07StrictNonNegativeInteger -Value $sample.Bytes } else { $null }
                if ($null -eq $bytes -or $bytes -gt 1TB) {
                    $failures.Add("$MetricName sample $ordinal has an invalid Bytes value (must be a non-negative integer).")
                }
                $sampleOrdinal = if ($null -ne $sample.PSObject.Properties['SampleOrdinal']) { ConvertTo-V07StrictNonNegativeInteger -Value $sample.SampleOrdinal } else { $null }
                if ($null -eq $sampleOrdinal -or $sampleOrdinal -le 0) {
                    $failures.Add("$MetricName sample $ordinal has an invalid SampleOrdinal (must be a positive integer).")
                }
            }
            default {
                $failures.Add("Unknown metric '$MetricName' cannot be validated.")
            }
        }
    }

    return [pscustomobject]@{
        Valid    = ($failures.Count -eq 0)
        Failures = @($failures)
        Count    = $count
    }
}

function Test-V07MetricAggregates {
    <#
    .SYNOPSIS
        Recomputes each declared aggregate from the retained raw samples and
        rejects forged or tampered declarations. Only metrics whose raw-sample
        integrity passed are recomputed; a failed metric already fails admission.
    #>
    param(
        [Parameter(Mandatory)]$Metrics,
        [Parameter(Mandatory)]$RawSamples,
        [System.Collections.Generic.HashSet[string]]$IntegrityPassedMetrics = $null
    )

    $failures = [System.Collections.Generic.List[string]]::new()

    $canCheck = {
        param([string]$Key)
        if ($null -eq $IntegrityPassedMetrics) { return $true }
        return $IntegrityPassedMetrics.Contains($Key)
    }

    $launchRaw = @()
    if ($null -ne $RawSamples.PSObject.Properties['DashboardColdLaunch'] -and $null -ne $RawSamples.DashboardColdLaunch) {
        $launchRaw = @($RawSamples.DashboardColdLaunch)
    }
    if ($launchRaw.Count -gt 0 -and (& $canCheck 'DashboardColdLaunch')) {
        $recomputed = Get-V07P95 -Samples ([double[]]@($launchRaw | ForEach-Object { [double]$_.Milliseconds }))
        if ([Math]::Abs($recomputed - [double]$Metrics.DashboardColdLaunchP95Ms) -gt $script:V07MeasurementP95ToleranceMs) {
            $failures.Add("DashboardColdLaunchP95Ms $($Metrics.DashboardColdLaunchP95Ms) does not recompute from raw samples (p95=$recomputed).")
        }
    }

    $latencyRaw = @()
    if ($null -ne $RawSamples.PSObject.Properties['WidgetStateDeltaLatency'] -and $null -ne $RawSamples.WidgetStateDeltaLatency) {
        $latencyRaw = @($RawSamples.WidgetStateDeltaLatency)
    }
    if ($latencyRaw.Count -gt 0 -and (& $canCheck 'WidgetStateDeltaLatency')) {
        $recomputed = Get-V07P95 -Samples ([double[]]@($latencyRaw | ForEach-Object { [double]$_.Milliseconds }))
        if ([Math]::Abs($recomputed - [double]$Metrics.WidgetStateDeltaLatencyP95Ms) -gt $script:V07MeasurementP95ToleranceMs) {
            $failures.Add("WidgetStateDeltaLatencyP95Ms $($Metrics.WidgetStateDeltaLatencyP95Ms) does not recompute from raw samples (p95=$recomputed).")
        }
    }

    $reconnectRaw = @()
    if ($null -ne $RawSamples.PSObject.Properties['HerdrReconnectReconcile'] -and $null -ne $RawSamples.HerdrReconnectReconcile) {
        $reconnectRaw = @($RawSamples.HerdrReconnectReconcile)
    }
    if ($reconnectRaw.Count -gt 0 -and (& $canCheck 'HerdrReconnectReconcile')) {
        $observedMax = ([double[]]@($reconnectRaw | ForEach-Object { [double]$_.Seconds }) | Measure-Object -Maximum).Maximum
        if ([Math]::Abs($observedMax - [double]$Metrics.HerdrReconnectReconcileSeconds) -gt $script:V07MeasurementReconnectToleranceSeconds) {
            $failures.Add("HerdrReconnectReconcileSeconds $($Metrics.HerdrReconnectReconcileSeconds) does not match the maximum raw reconnect sample ($observedMax).")
        }
    }

    $cpuRaw = @()
    if ($null -ne $RawSamples.PSObject.Properties['IdleCpu'] -and $null -ne $RawSamples.IdleCpu) {
        $cpuRaw = @($RawSamples.IdleCpu)
    }
    if ($cpuRaw.Count -gt 0 -and (& $canCheck 'IdleCpu')) {
        $recomputed = ([double[]]@($cpuRaw | ForEach-Object { [double]$_.Percent }) | Measure-Object -Average).Average
        if ([Math]::Abs($recomputed - [double]$Metrics.IdleCpuAveragePercent) -gt $script:V07MeasurementCpuAverageTolerancePercent) {
            $failures.Add("IdleCpuAveragePercent $($Metrics.IdleCpuAveragePercent) does not recompute from raw samples (mean=$recomputed).")
        }
    }

    $wsRaw = @()
    if ($null -ne $RawSamples.PSObject.Properties['IdleWorkingSet'] -and $null -ne $RawSamples.IdleWorkingSet) {
        $wsRaw = @($RawSamples.IdleWorkingSet)
    }
    if ($wsRaw.Count -gt 0 -and (& $canCheck 'IdleWorkingSet')) {
        $recomputed = ([double[]]@($wsRaw | ForEach-Object { [double]$_.Bytes }) | Measure-Object -Average).Average
        if ([Math]::Abs($recomputed - [double]$Metrics.IdleWorkingSetCombinedBytes) -gt $script:V07MeasurementWorkingSetToleranceBytes) {
            $failures.Add("IdleWorkingSetCombinedBytes $($Metrics.IdleWorkingSetCombinedBytes) does not recompute from raw samples (mean=$recomputed).")
        }
    }

    return @($failures)
}

# -----------------------------------------------------------------------------
# Measurement Artifact Assembly
# -----------------------------------------------------------------------------
function New-V07MeasurementArtifact {
    <#
    .SYNOPSIS
        Assembles the v0.7.0-measurement artifact object from the observed parts.
        Performs structural validation and fails closed on missing or malformed
        parts. Callers then run Test-V07MeasurementArtifactAdmission.
    #>
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$StartedUtc,
        [Parameter(Mandatory)][string]$FinishedUtc,
        [Parameter(Mandatory)][ValidateSet('Live', 'Synthetic')][string]$Mode,
        [switch]$Cancelled,
        [switch]$TimedOut,
        [string]$TerminationReason = '',
        [Parameter(Mandatory)]$HostEnvironment,
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)]$Candidate,
        [Parameter(Mandatory)]$Roles,
        [Parameter(Mandatory)]$Metrics,
        [Parameter(Mandatory)]$Observed,
        [Parameter(Mandatory)]$RawSamples,
        [Parameter(Mandatory)]$PhaseLog
    )

    if (-not (Test-V07UtcTimestampText -Text $StartedUtc)) {
        throw 'Measurement artifact StartedUtc must be a valid UTC timestamp.'
    }
    if (-not (Test-V07UtcTimestampText -Text $FinishedUtc)) {
        throw 'Measurement artifact FinishedUtc must be a valid UTC timestamp.'
    }
    if (([DateTimeOffset]$StartedUtc) -gt ([DateTimeOffset]$FinishedUtc)) {
        throw 'Measurement artifact StartedUtc cannot be later than FinishedUtc.'
    }
    if ($null -eq $HostEnvironment -or $null -eq $Session -or $null -eq $Candidate -or
        $null -eq $Roles -or $null -eq $Metrics -or $null -eq $Observed -or
        $null -eq $RawSamples -or $null -eq $PhaseLog) {
        throw 'Measurement artifact requires HostEnvironment, Session, Candidate, Roles, Metrics, Observed, RawSamples, and PhaseLog.'
    }

    foreach ($key in $script:V07MeasurementObservedKeys) {
        if ($null -eq $Observed.PSObject.Properties[$key]) {
            throw "Measurement artifact Observed is missing required flag '$key'."
        }
    }
    foreach ($key in $script:V07MeasurementMetrics) {
        if ($null -eq $Metrics.PSObject.Properties[$key]) {
            throw "Measurement artifact Metrics is missing required metric '$key'."
        }
    }

    return [pscustomobject]@{
        SchemaVersion    = $script:V07MeasurementSchemaVersion
        ArtifactKind     = $script:V07MeasurementArtifactKind
        RunId            = $RunId
        StartedUtc       = $StartedUtc
        FinishedUtc      = $FinishedUtc
        Mode             = $Mode
        Cancelled        = [bool]$Cancelled
        TimedOut         = [bool]$TimedOut
        TerminationReason = $TerminationReason
        HostEnvironment  = $HostEnvironment
        Session          = $Session
        Candidate        = $Candidate
        Roles            = @($Roles)
        Metrics          = $Metrics
        Observed         = $Observed
        RawSamples       = $RawSamples
        PhaseLog         = @($PhaseLog)
    }
}

# -----------------------------------------------------------------------------
# Strict Schema Property Enumeration (hostile unknown-property rejection)
# -----------------------------------------------------------------------------
function Test-V07MeasurementArtifactSchema {
    <#
    .SYNOPSIS
        Rejects unknown properties at every level of the v0.7.0-measurement
        artifact. Returns a failure array; the admission gate treats any failure
        as invalid evidence.
    #>
    param([Parameter(Mandatory)]$Artifact)

    $failures = [System.Collections.Generic.List[string]]::new()
    foreach ($failure in @(Test-V07AllowedProperties -Object $Artifact -Allowed @(
            'SchemaVersion', 'ArtifactKind', 'RunId', 'StartedUtc', 'FinishedUtc', 'Mode',
            'Cancelled', 'TimedOut', 'TerminationReason', 'HostEnvironment', 'Session',
            'Candidate', 'Roles', 'Metrics', 'Observed', 'RawSamples', 'PhaseLog') -Context 'Artifact')) {
        $failures.Add($failure)
    }

    $hostEnvironment = if ($null -ne $Artifact.PSObject.Properties['HostEnvironment']) { $Artifact.HostEnvironment } else { $null }
    foreach ($failure in @(Test-V07AllowedProperties -Object $hostEnvironment -Allowed @(
            'Os', 'Architecture', 'LogicalProcessors', 'ReferenceHostConfirmed') -Context 'HostEnvironment')) {
        $failures.Add($failure)
    }

    $session = if ($null -ne $Artifact.PSObject.Properties['Session']) { $Artifact.Session } else { $null }
    foreach ($failure in @(Test-V07AllowedProperties -Object $session -Allowed @(
            'ControlPaneId', 'ObservedControlPaneId', 'ControlHerdrSocketPath', 'TargetHerdrSocketPath',
            'SeparateSessions', 'HerdrExecutablePath', 'HerdrExecutableSha256', 'HerdrReleaseId',
            'ControlHerdrServerIdentity') -Context 'Session')) {
        $failures.Add($failure)
    }
    $serverIdentity = if ($null -ne $session -and $null -ne $session.PSObject.Properties['ControlHerdrServerIdentity']) { $session.ControlHerdrServerIdentity } else { $null }
    foreach ($failure in @(Test-V07AllowedProperties -Object $serverIdentity -Allowed @(
            'ProcessId', 'ProcessStartUtc', 'ExecutablePath', 'ExecutableSha256') -Context 'Session.ControlHerdrServerIdentity')) {
        $failures.Add($failure)
    }

    $candidate = if ($null -ne $Artifact.PSObject.Properties['Candidate']) { $Artifact.Candidate } else { $null }
    foreach ($failure in @(Test-V07AllowedProperties -Object $candidate -Allowed @(
            'SourceCommit', 'SourceTree', 'GitTreeClean', 'Binaries') -Context 'Candidate')) {
        $failures.Add($failure)
    }
    if ($null -ne $candidate -and $null -ne $candidate.PSObject.Properties['Binaries']) {
        foreach ($binary in @($candidate.Binaries)) {
            foreach ($failure in @(Test-V07AllowedProperties -Object $binary -Allowed @(
                    'RelativePath', 'LengthBytes', 'Sha256') -Context 'Candidate.Binaries[]')) {
                $failures.Add($failure)
            }
        }
    }

    if ($null -ne $Artifact.PSObject.Properties['Roles']) {
        foreach ($role in @($Artifact.Roles)) {
            foreach ($failure in @(Test-V07AllowedProperties -Object $role -Allowed @(
                    'Role', 'ProcessId', 'ProcessStartUtc', 'BinaryPath', 'BinarySha256') -Context 'Roles[]')) {
                $failures.Add($failure)
            }
        }
    }

    $metrics = if ($null -ne $Artifact.PSObject.Properties['Metrics']) { $Artifact.Metrics } else { $null }
    foreach ($failure in @(Test-V07AllowedProperties -Object $metrics -Allowed $script:V07MeasurementMetrics -Context 'Metrics')) {
        $failures.Add($failure)
    }

    $observed = if ($null -ne $Artifact.PSObject.Properties['Observed']) { $Artifact.Observed } else { $null }
    foreach ($failure in @(Test-V07AllowedProperties -Object $observed -Allowed $script:V07MeasurementObservedKeys -Context 'Observed')) {
        $failures.Add($failure)
    }

    $rawSamples = if ($null -ne $Artifact.PSObject.Properties['RawSamples']) { $Artifact.RawSamples } else { $null }
    foreach ($failure in @(Test-V07AllowedProperties -Object $rawSamples -Allowed $script:V07MeasurementRawSampleKeys -Context 'RawSamples')) {
        $failures.Add($failure)
    }
    if ($null -ne $rawSamples) {
        $sampleAllowed = @{
            'DashboardColdLaunch'     = @('RunOrdinal', 'ObservedUtc', 'Milliseconds', 'AppProcessId', 'CoreProcessId', 'Termination')
            'WidgetStateDeltaLatency' = @('ObservedUtc', 'Milliseconds', 'AppProcessId', 'CoreProcessId', 'UpdateKind')
            'HerdrReconnectReconcile' = @('ObservedUtc', 'Seconds', 'DisconnectTransitionUtc', 'ReconnectTransitionUtc', 'ReconnectBootstrapCount', 'ReconnectServerPid')
            'IdleCpu'                 = @('ObservedUtc', 'Percent', 'SampleOrdinal')
            'IdleWorkingSet'          = @('ObservedUtc', 'Bytes', 'SampleOrdinal')
        }
        foreach ($key in $script:V07MeasurementRawSampleKeys) {
            if ($null -eq $rawSamples.PSObject.Properties[$key]) { continue }
            foreach ($sample in @($rawSamples.$key)) {
                foreach ($failure in @(Test-V07AllowedProperties -Object $sample -Allowed $sampleAllowed[$key] -Context "RawSamples.$key[]")) {
                    $failures.Add($failure)
                }
            }
        }
    }

    if ($null -ne $Artifact.PSObject.Properties['PhaseLog']) {
        foreach ($entry in @($Artifact.PhaseLog)) {
            foreach ($failure in @(Test-V07AllowedProperties -Object $entry -Allowed @(
                    'Phase', 'StartedUtc', 'FinishedUtc', 'Result', 'Detail') -Context 'PhaseLog[]')) {
                $failures.Add($failure)
            }
        }
    }

    return @($failures)
}

function Test-V07SoakArtifactSchema {
    <#
    .SYNOPSIS
        Rejects unknown properties in a v0.7.0-soak artifact and requires the
        cross-file run-id/hash chain fields that bind it to its measurement run.
    #>
    param([Parameter(Mandatory)]$SoakArtifact)

    $failures = [System.Collections.Generic.List[string]]::new()
    foreach ($failure in @(Test-V07AllowedProperties -Object $SoakArtifact -Allowed @(
            'SchemaVersion', 'ArtifactKind', 'RunId', 'StartedUtc', 'FinishedUtc', 'Mode',
            'Cancelled', 'TimedOut', 'Session', 'Candidate', 'Soak', 'MeasurementRunId',
            'MeasurementArtifactSha256', 'InstalledHerdr', 'Producer', 'Provenance',
            'Resources', 'Limits', 'Artifacts') -Context 'SoakArtifact')) {
        $failures.Add($failure)
    }
    $session = if ($null -ne $SoakArtifact.PSObject.Properties['Session']) { $SoakArtifact.Session } else { $null }
    foreach ($failure in @(Test-V07AllowedProperties -Object $session -Allowed @(
            'ControlPaneId', 'ObservedControlPaneId', 'ControlHerdrSocketPath', 'TargetHerdrSocketPath',
            'HerdrExecutablePath', 'HerdrExecutableSha256', 'HerdrReleaseId', 'ControlHerdrServerIdentity') -Context 'Soak.Session')) {
        $failures.Add($failure)
    }
    $sessionIdentity = if ($null -ne $session -and $null -ne $session.PSObject.Properties['ControlHerdrServerIdentity']) { $session.ControlHerdrServerIdentity } else { $null }
    foreach ($failure in @(Test-V07AllowedProperties -Object $sessionIdentity -Allowed @(
            'ProcessId', 'ProcessStartUtc', 'ExecutablePath', 'ExecutableSha256') -Context 'Soak.Session.ControlHerdrServerIdentity')) {
        $failures.Add($failure)
    }
    $candidate = if ($null -ne $SoakArtifact.PSObject.Properties['Candidate']) { $SoakArtifact.Candidate } else { $null }
    foreach ($failure in @(Test-V07AllowedProperties -Object $candidate -Allowed @(
            'SourceCommit', 'SourceTree', 'GitTreeClean', 'Binaries', 'Observer') -Context 'Soak.Candidate')) {
        $failures.Add($failure)
    }
    if ($null -ne $candidate -and $null -ne $candidate.PSObject.Properties['Binaries']) {
        foreach ($binary in @($candidate.Binaries)) {
            foreach ($failure in @(Test-V07AllowedProperties -Object $binary -Allowed @(
                    'RelativePath', 'LengthBytes', 'Sha256') -Context 'Soak.Candidate.Binaries[]')) {
                $failures.Add($failure)
            }
        }
    }
    $observerBinding = if ($null -ne $candidate -and $null -ne $candidate.PSObject.Properties['Observer']) { $candidate.Observer } else { $null }
    foreach ($failure in @(Test-V07AllowedProperties -Object $observerBinding -Allowed @(
            'RelativePath', 'LengthBytes', 'Sha256') -Context 'Soak.Candidate.Observer')) {
        $failures.Add($failure)
    }
    $soak = if ($null -ne $SoakArtifact.PSObject.Properties['Soak']) { $SoakArtifact.Soak } else { $null }
    foreach ($failure in @(Test-V07AllowedProperties -Object $soak -Allowed @(
            'DurationHours', 'UnhandledCrashes', 'UnreconciledStateCount', 'UnboundedTerminalReads',
            'RuntimeObservationCount', 'RuntimeObservationFailures', 'StateEvidenceCount',
            'ObservedEvents', 'ObservedReconnects') -Context 'Soak.Soak')) {
        $failures.Add($failure)
    }

    $installed = if ($null -ne $SoakArtifact.PSObject.Properties['InstalledHerdr']) { $SoakArtifact.InstalledHerdr } else { $null }
    foreach ($failure in @(Test-V07AllowedProperties -Object $installed -Allowed @(
            'ProductId', 'ExecutablePath', 'ExecutableSha256', 'ReleaseId', 'PackageRoot',
            'PackageIdentitySha256') -Context 'Soak.InstalledHerdr')) {
        $failures.Add($failure)
    }
    $producer = if ($null -ne $SoakArtifact.PSObject.Properties['Producer']) { $SoakArtifact.Producer } else { $null }
    foreach ($failure in @(Test-V07AllowedProperties -Object $producer -Allowed @(
            'Tool', 'Version', 'SessionControlInvoked', 'ObserverMode', 'ObserverExecutablePath',
            'ObserverExecutableSha256', 'ObserverReportPath', 'ObserverReportSha256',
            'AdmittedHerdrServerIdentity', 'AdmittedRoleIdentities', 'FaultSchedule', 'ScheduleContextPath',
            'ScheduleContextSha256') -Context 'Soak.Producer')) {
        $failures.Add($failure)
    }
    $admittedIdentity = if ($null -ne $producer -and $null -ne $producer.PSObject.Properties['AdmittedHerdrServerIdentity']) { $producer.AdmittedHerdrServerIdentity } else { $null }
    foreach ($failure in @(Test-V07AllowedProperties -Object $admittedIdentity -Allowed @(
            'ProcessId', 'ProcessStartUtc', 'ExecutablePath', 'ExecutableSha256') -Context 'Soak.Producer.AdmittedHerdrServerIdentity')) {
        $failures.Add($failure)
    }
    $admittedRoleIdentities = if ($null -ne $producer -and $null -ne $producer.PSObject.Properties['AdmittedRoleIdentities']) { $producer.AdmittedRoleIdentities } else { $null }
    foreach ($failure in @(Test-V07AllowedProperties -Object $admittedRoleIdentities -Allowed @('Core', 'App') -Context 'Soak.Producer.AdmittedRoleIdentities')) {
        $failures.Add($failure)
    }
    foreach ($roleName in @('Core', 'App')) {
        $roleIdentity = if ($null -ne $admittedRoleIdentities -and $null -ne $admittedRoleIdentities.PSObject.Properties[$roleName]) { $admittedRoleIdentities.$roleName } else { $null }
        foreach ($failure in @(Test-V07AllowedProperties -Object $roleIdentity -Allowed @(
                'ProcessId', 'ProcessStartUtc', 'ExecutablePath', 'ExecutableSha256') -Context "Soak.Producer.AdmittedRoleIdentities.$roleName")) {
            $failures.Add($failure)
        }
    }
    if ($null -ne $producer -and $null -ne $producer.PSObject.Properties['FaultSchedule']) {
        foreach ($scheduled in @($producer.FaultSchedule)) {
            foreach ($failure in @(Test-V07AllowedProperties -Object $scheduled -Allowed @(
                    'Id', 'Kind', 'OffsetSeconds', 'Instruction', 'DueUtc') -Context 'Soak.Producer.FaultSchedule[]')) {
                $failures.Add($failure)
            }
        }
    }
    $provenance = if ($null -ne $SoakArtifact.PSObject.Properties['Provenance']) { $SoakArtifact.Provenance } else { $null }
    foreach ($failure in @(Test-V07AllowedProperties -Object $provenance -Allowed @(
            'HeartbeatIntervalSeconds', 'ExpectedHeartbeatCount', 'MissingHeartbeatCount',
            'HeartbeatEntries', 'HeartbeatChainHeadSha256', 'FirstHeartbeatUtc', 'LastHeartbeatUtc',
            'ObservationCount', 'FaultObservations', 'FaultObservationChainHeadSha256') -Context 'Soak.Provenance')) {
        $failures.Add($failure)
    }
    if ($null -ne $provenance -and $null -ne $provenance.PSObject.Properties['HeartbeatEntries']) {
        foreach ($entry in @($provenance.HeartbeatEntries)) {
            foreach ($failure in @(Test-V07AllowedProperties -Object $entry -Allowed @(
                    'Ordinal', 'ObservedUtc', 'Status', 'TargetSocketPresent', 'HerdrProcessId',
                    'HerdrProcessStartUtc', 'HerdrExecutablePath', 'HerdrExecutableSha256', 'CoreProcessId',
                    'CoreProcessStartUtc', 'CoreExecutablePath', 'CoreExecutableSha256', 'AppProcessId',
                    'AppProcessStartUtc', 'AppExecutablePath', 'AppExecutableSha256',
                    'PreviousEntrySha256', 'EntrySha256') -Context 'Soak.Provenance.HeartbeatEntries[]')) {
                $failures.Add($failure)
            }
        }
    }
    if ($null -ne $provenance -and $null -ne $provenance.PSObject.Properties['FaultObservations']) {
        foreach ($entry in @($provenance.FaultObservations)) {
            foreach ($failure in @(Test-V07AllowedProperties -Object $entry -Allowed @(
                    'Id', 'Kind', 'ScheduledOffsetSeconds', 'DueUtc', 'ObservedUtc', 'Status',
                    'OperatorAcknowledged', 'EvidencePath', 'EvidenceSha256', 'Note',
                    'PreviousEntrySha256', 'EntrySha256') -Context 'Soak.Provenance.FaultObservations[]')) {
                $failures.Add($failure)
            }
        }
    }
    $resources = if ($null -ne $SoakArtifact.PSObject.Properties['Resources']) { $SoakArtifact.Resources } else { $null }
    foreach ($failure in @(Test-V07AllowedProperties -Object $resources -Allowed @(
            'MaxSamples', 'Samples', 'PeakWorkingSetBytes', 'PeakCpuPercent') -Context 'Soak.Resources')) {
        $failures.Add($failure)
    }
    if ($null -ne $resources -and $null -ne $resources.PSObject.Properties['Samples']) {
        foreach ($sample in @($resources.Samples)) {
            foreach ($failure in @(Test-V07AllowedProperties -Object $sample -Allowed @(
                    'ObservedUtc', 'HerdrProcessId', 'CoreProcessId', 'AppProcessId',
                    'CombinedWorkingSetBytes', 'CombinedCpuPercent') -Context 'Soak.Resources.Samples[]')) {
                $failures.Add($failure)
            }
        }
    }
    $limits = if ($null -ne $SoakArtifact.PSObject.Properties['Limits']) { $SoakArtifact.Limits } else { $null }
    foreach ($failure in @(Test-V07AllowedProperties -Object $limits -Allowed @(
            'MaxArtifactBytes', 'MaxHeartbeatEntries', 'MaxFaultObservations', 'MaxResourceSamples',
            'MaxManifestEntries') -Context 'Soak.Limits')) {
        $failures.Add($failure)
    }
    if ($null -ne $SoakArtifact.PSObject.Properties['Artifacts']) {
        foreach ($artifact in @($SoakArtifact.Artifacts)) {
            foreach ($failure in @(Test-V07AllowedProperties -Object $artifact -Allowed @(
                    'Name', 'RelativePath', 'LengthBytes', 'Sha256', 'Lines', 'Entries') -Context 'Soak.Artifacts[]')) {
                $failures.Add($failure)
            }
        }
    }
    return @($failures)
}

function Test-V07SoakProvenance {
    <#
    .SYNOPSIS
        Validates the producer-owned provenance that turns the historical compact
        v0.7 soak shape into an admissible actual-Herdr observation. This remains
        evidence validation only: it never starts, stops, or restarts a process.
    #>
    param(
        [Parameter(Mandatory)]$SoakArtifact,
        [Parameter(Mandatory)]$MeasurementArtifact,
        [string]$RepositoryRoot = '',
        [string]$EvidenceRoot = '',
        [switch]$ValidateExternalBindings
    )

    $failures = [System.Collections.Generic.List[string]]::new()
    $zeroSha = '0' * 64
    $start = $null
    $finish = $null
    if ((Test-V07UtcTimestampText -Text ([string]$SoakArtifact.StartedUtc)) -and
        (Test-V07UtcTimestampText -Text ([string]$SoakArtifact.FinishedUtc))) {
        $start = [DateTimeOffset]$SoakArtifact.StartedUtc
        $finish = [DateTimeOffset]$SoakArtifact.FinishedUtc
    }

    $requiredTop = @('InstalledHerdr', 'Producer', 'Provenance', 'Resources', 'Limits', 'Artifacts')
    foreach ($name in $requiredTop) {
        if ($null -eq $SoakArtifact.PSObject.Properties[$name] -or $null -eq $SoakArtifact.$name) {
            $failures.Add("Soak artifact is missing required provenance object '$name'.")
        }
    }
    if ($failures.Count -gt 0) { return @($failures) }

    $installed = $SoakArtifact.InstalledHerdr
    foreach ($name in @('ProductId', 'ExecutablePath', 'ExecutableSha256', 'ReleaseId', 'PackageRoot', 'PackageIdentitySha256')) {
        if ($null -eq $installed.PSObject.Properties[$name] -or [string]::IsNullOrWhiteSpace([string]$installed.$name)) {
            $failures.Add("InstalledHerdr.$name is required for package identity binding.")
        }
    }
    if ([string]$installed.ProductId -cne 'Herdr') { $failures.Add("InstalledHerdr.ProductId must be 'Herdr'.") }
    $installedSha = try { ConvertTo-V07NormalizedSha256 -Value ([string]$installed.ExecutableSha256) } catch { '' }
    $identitySha = try { ConvertTo-V07NormalizedSha256 -Value ([string]$installed.PackageIdentitySha256) } catch { '' }
    if ([string]::IsNullOrWhiteSpace($installedSha)) { $failures.Add('InstalledHerdr.ExecutableSha256 must be a valid SHA-256.') }
    if ([string]::IsNullOrWhiteSpace($identitySha)) { $failures.Add('InstalledHerdr.PackageIdentitySha256 must be a valid SHA-256.') }
    if (-not [string]::IsNullOrWhiteSpace($identitySha)) {
        try {
            $computedIdentity = Get-V07InstalledHerdrIdentitySha256 -Identity $installed
            if ($computedIdentity -ne $identitySha) { $failures.Add('InstalledHerdr.PackageIdentitySha256 does not match the canonical installed identity.') }
        } catch { $failures.Add("InstalledHerdr identity hash could not be recomputed: $($_.Exception.Message)") }
    }

    $producer = $SoakArtifact.Producer
    if ([string]$producer.Tool -cne 'Invoke-V07ActualHerdrSoak.ps1') { $failures.Add('Soak.Producer.Tool is not the authorized actual-Herdr soak producer.') }
    if ([string]::IsNullOrWhiteSpace([string]$producer.Version)) { $failures.Add('Soak.Producer.Version is required.') }
    if ([bool]$producer.SessionControlInvoked) { $failures.Add('Soak producer must never invoke Herdr/session control.') }
    if ([string]$producer.ObserverMode -cne 'ReadOnlyAttached') { $failures.Add("Soak.Producer.ObserverMode must be 'ReadOnlyAttached'.") }
    foreach ($name in @('ObserverExecutablePath', 'ObserverExecutableSha256', 'ObserverReportPath', 'ObserverReportSha256', 'AdmittedHerdrServerIdentity', 'FaultSchedule', 'ScheduleContextPath', 'ScheduleContextSha256')) {
        if ($null -eq $producer.PSObject.Properties[$name] -or $null -eq $producer.$name) {
            $failures.Add("Soak.Producer.$name is required for exact observer and schedule provenance.")
        }
    }
    $producerObserverSha = try { ConvertTo-V07NormalizedSha256 -Value ([string]$producer.ObserverExecutableSha256) } catch { '' }
    $producerReportSha = try { ConvertTo-V07NormalizedSha256 -Value ([string]$producer.ObserverReportSha256) } catch { '' }
    $contextSha = try { ConvertTo-V07NormalizedSha256 -Value ([string]$producer.ScheduleContextSha256) } catch { '' }
    if ([string]::IsNullOrWhiteSpace($producerObserverSha)) { $failures.Add('Soak.Producer.ObserverExecutableSha256 must be a valid SHA-256.') }
    if ([string]::IsNullOrWhiteSpace($producerReportSha)) { $failures.Add('Soak.Producer.ObserverReportSha256 must be a valid SHA-256.') }
    if ([string]::IsNullOrWhiteSpace($contextSha)) { $failures.Add('Soak.Producer.ScheduleContextSha256 must be a valid SHA-256.') }
    $admittedIdentity = $producer.AdmittedHerdrServerIdentity
    foreach ($name in @('ProcessId', 'ProcessStartUtc', 'ExecutablePath', 'ExecutableSha256')) {
        if ($null -eq $admittedIdentity.PSObject.Properties[$name] -or [string]::IsNullOrWhiteSpace([string]$admittedIdentity.$name)) {
            $failures.Add("Soak.Producer.AdmittedHerdrServerIdentity.$name is required.")
        }
    }
    if ($null -eq (ConvertTo-V07PositiveProcessId -Value $admittedIdentity.ProcessId)) { $failures.Add('Admitted Herdr server ProcessId must be positive.') }
    if (-not (Test-V07UtcTimestampText -Text $admittedIdentity.ProcessStartUtc)) { $failures.Add('Admitted Herdr server ProcessStartUtc is invalid.') }
    $admittedStartText = if (Test-V07UtcTimestampText -Text $admittedIdentity.ProcessStartUtc) {
        ConvertTo-V07UtcText -Value $admittedIdentity.ProcessStartUtc
    } else { [string]$admittedIdentity.ProcessStartUtc }
    $admittedSha = try { ConvertTo-V07NormalizedSha256 -Value ([string]$admittedIdentity.ExecutableSha256) } catch { '' }
    if ([string]::IsNullOrWhiteSpace($admittedSha)) { $failures.Add('Admitted Herdr server ExecutableSha256 must be a valid SHA-256.') }
    if ([string]$admittedIdentity.ExecutablePath -ine [string]$installed.ExecutablePath -or
        $admittedSha -ne $installedSha) {
        $failures.Add('Admitted Herdr server identity does not match the installed Herdr identity.')
    }

    $admittedRoleIdentities = if ($null -ne $producer.PSObject.Properties['AdmittedRoleIdentities']) { $producer.AdmittedRoleIdentities } else { $null }
    $roleIdentityByName = @{}
    foreach ($roleName in @('Core', 'App')) {
        $roleIdentity = if ($null -ne $admittedRoleIdentities -and $null -ne $admittedRoleIdentities.PSObject.Properties[$roleName]) { $admittedRoleIdentities.$roleName } else { $null }
        if ($null -eq $roleIdentity) {
            $failures.Add("Soak.Producer.AdmittedRoleIdentities.$roleName is required for every heartbeat identity binding.")
            continue
        }
        $roleIdentityByName[$roleName] = $roleIdentity
        foreach ($name in @('ProcessId', 'ProcessStartUtc', 'ExecutablePath', 'ExecutableSha256')) {
            if ($null -eq $roleIdentity.PSObject.Properties[$name] -or [string]::IsNullOrWhiteSpace([string]$roleIdentity.$name)) {
                $failures.Add("Soak.Producer.AdmittedRoleIdentities.$roleName.$name is required.")
            }
        }
        $rolePid = if ($null -ne $roleIdentity.PSObject.Properties['ProcessId']) { ConvertTo-V07PositiveProcessId -Value $roleIdentity.ProcessId } else { $null }
        if ($null -eq $rolePid) { $failures.Add("Admitted $roleName role ProcessId must be positive.") }
        $roleStartText = if ($null -ne $roleIdentity.PSObject.Properties['ProcessStartUtc']) { [string]$roleIdentity.ProcessStartUtc } else { '' }
        $rolePath = if ($null -ne $roleIdentity.PSObject.Properties['ExecutablePath']) { [string]$roleIdentity.ExecutablePath } else { '' }
        if (-not (Test-V07UtcTimestampText -Text $roleStartText)) { $failures.Add("Admitted $roleName role ProcessStartUtc is invalid.") }
        $roleSha = try { ConvertTo-V07NormalizedSha256 -Value ([string]$roleIdentity.ExecutableSha256) } catch { '' }
        if ([string]::IsNullOrWhiteSpace($roleSha)) { $failures.Add("Admitted $roleName role ExecutableSha256 must be a valid SHA-256.") }
        $measurementRole = @($MeasurementArtifact.Roles | Where-Object { [string]$_.Role -ceq $roleName })
        if ($measurementRole.Count -ne 1) {
            $failures.Add("Measurement artifact must contain exactly one admitted $roleName role identity.")
        } else {
            $measurementRoleStart = if (Test-V07UtcTimestampText -Text ([string]$measurementRole[0].ProcessStartUtc)) {
                ConvertTo-V07UtcText -Value ([DateTimeOffset]$measurementRole[0].ProcessStartUtc)
            } else { [string]$measurementRole[0].ProcessStartUtc }
            $measurementRoleSha = try { ConvertTo-V07NormalizedSha256 -Value ([string]$measurementRole[0].BinarySha256) } catch { '' }
            if ([int]$rolePid -ne [int]$measurementRole[0].ProcessId -or
                $roleStartText -cne $measurementRoleStart -or
                $rolePath -ine [string]$measurementRole[0].BinaryPath -or
                $roleSha -ne $measurementRoleSha) {
                $failures.Add("Admitted $roleName role identity does not match the measurement artifact role identity.")
            }
        }
    }
    if ([string]::IsNullOrWhiteSpace([string]$producer.ObserverExecutablePath)) {
        $failures.Add('Soak.Producer.ObserverExecutablePath must be non-empty.')
    }
    if ([string]::IsNullOrWhiteSpace([string]$producer.ObserverReportPath) -or [string]::IsNullOrWhiteSpace([string]$producer.ScheduleContextPath)) {
        $failures.Add('Soak observer report and schedule context paths must be non-empty.')
    }

    $candidate = $SoakArtifact.Candidate
    foreach ($name in @('SourceCommit', 'SourceTree', 'Binaries')) {
        if ($null -eq $candidate.PSObject.Properties[$name] -or $null -eq $candidate.$name) {
            $failures.Add("Soak.Candidate.$name is required for exact candidate binding.")
        }
    }
    if ([string]$candidate.SourceCommit -notmatch '^[0-9a-f]{40}$') { $failures.Add('Soak.Candidate.SourceCommit must be a lowercase 40-hex commit.') }
    if ([string]$candidate.SourceTree -notmatch '^[0-9a-f]{40}$') { $failures.Add('Soak.Candidate.SourceTree must be a lowercase 40-hex Git tree.') }
    if ($null -eq $candidate.PSObject.Properties['GitTreeClean'] -or -not [bool]$candidate.GitTreeClean) { $failures.Add('Soak.Candidate.GitTreeClean must be true.') }
    $candidateObserver = if ($null -ne $candidate.PSObject.Properties['Observer']) { $candidate.Observer } else { $null }
    foreach ($name in @('RelativePath', 'LengthBytes', 'Sha256')) {
        if ($null -eq $candidateObserver -or $null -eq $candidateObserver.PSObject.Properties[$name]) { $failures.Add("Soak.Candidate.Observer.$name is required.") }
    }
    $candidateObserverSha = try { ConvertTo-V07NormalizedSha256 -Value ([string]$candidateObserver.Sha256) } catch { '' }
    if ([string]::IsNullOrWhiteSpace($candidateObserverSha)) { $failures.Add('Soak.Candidate.Observer.Sha256 must be a valid SHA-256.') }
    if (-not [string]::IsNullOrWhiteSpace($producerObserverSha) -and -not [string]::IsNullOrWhiteSpace($candidateObserverSha) -and $producerObserverSha -ne $candidateObserverSha) {
        $failures.Add('Soak observer executable SHA-256 does not match the exact candidate observer binding.')
    }
    if ([string]$candidateObserver.RelativePath -match '\\' -or [string]$candidateObserver.RelativePath -match '(^|/)\.\.?(/|$)' -or [IO.Path]::IsPathRooted([string]$candidateObserver.RelativePath)) {
        $failures.Add('Soak.Candidate.Observer.RelativePath must be a forward-slash, non-rooted path without dot segments.')
    }
    $measurementCandidate = $MeasurementArtifact.Candidate
    if ([string]$candidate.SourceCommit.ToLowerInvariant() -ne [string]$measurementCandidate.SourceCommit.ToLowerInvariant()) {
        $failures.Add('Soak source commit does not match the measurement candidate.')
    }
    if ($null -ne $measurementCandidate.PSObject.Properties['SourceTree'] -and
        [string]$candidate.SourceTree.ToLowerInvariant() -ne [string]$measurementCandidate.SourceTree.ToLowerInvariant()) {
        $failures.Add('Soak source tree does not match the measurement candidate.')
    }
    if (@($candidate.Binaries).Count -lt 2) { $failures.Add('Soak.Candidate.Binaries must retain Core and App candidate bindings.') }
    if (@($measurementCandidate.Binaries).Count -gt 0) {
        foreach ($measurementBinary in @($measurementCandidate.Binaries)) {
            $matching = @($candidate.Binaries | Where-Object { [string]$_.RelativePath -ceq [string]$measurementBinary.RelativePath })
            if ($matching.Count -ne 1 -or [long]$matching[0].LengthBytes -ne [long]$measurementBinary.LengthBytes -or
                [string]$matching[0].Sha256 -ine [string]$measurementBinary.Sha256) {
                $failures.Add("Soak candidate binary binding does not match measurement binary '$($measurementBinary.RelativePath)'.")
            }
        }
    }

    $session = $SoakArtifact.Session
    $sessionIdentity = if ($null -ne $session.PSObject.Properties['ControlHerdrServerIdentity']) { $session.ControlHerdrServerIdentity } else { $null }
    $measurementSession = $MeasurementArtifact.Session
    if ([string]$session.HerdrExecutableSha256 -ine [string]$installed.ExecutableSha256 -or
        [string]$session.HerdrExecutableSha256 -ine [string]$measurementSession.HerdrExecutableSha256) {
        $failures.Add('Soak/session/installed Herdr executable SHA-256 values do not match.')
    }
    if ($null -ne $measurementSession.PSObject.Properties['ControlHerdrServerIdentity'] -and $null -ne $measurementSession.ControlHerdrServerIdentity) {
        $measurementIdentity = $measurementSession.ControlHerdrServerIdentity
        if ([int]$admittedIdentity.ProcessId -ne [int]$measurementIdentity.ProcessId -or
            $admittedStartText -cne (ConvertTo-V07UtcText -Value $measurementIdentity.ProcessStartUtc) -or
            [string]$admittedIdentity.ExecutablePath -ine [string]$measurementIdentity.ExecutablePath -or
            [string]$admittedIdentity.ExecutableSha256 -ine [string]$measurementIdentity.ExecutableSha256) {
            $failures.Add('Soak admitted Herdr server identity does not match the measurement admission server identity.')
        }
    }
    if ($null -eq $sessionIdentity) {
        $failures.Add('Soak.Session.ControlHerdrServerIdentity is required for exact server provenance.')
    } elseif ([int]$sessionIdentity.ProcessId -ne [int]$admittedIdentity.ProcessId -or
        (ConvertTo-V07UtcText -Value $sessionIdentity.ProcessStartUtc) -cne $admittedStartText -or
        [string]$sessionIdentity.ExecutablePath -ine [string]$admittedIdentity.ExecutablePath -or
        [string]$sessionIdentity.ExecutableSha256 -ine [string]$admittedIdentity.ExecutableSha256) {
        $failures.Add('Soak session server identity does not match the admitted producer server identity.')
    }
    if ([string]$session.TargetHerdrSocketPath -ieq [string]$session.ControlHerdrSocketPath) { $failures.Add('Soak control and target sockets must be distinct.') }

    $soakMetrics = $SoakArtifact.Soak
    foreach ($name in @('RuntimeObservationCount', 'RuntimeObservationFailures', 'StateEvidenceCount', 'ObservedEvents', 'ObservedReconnects')) {
        if ($null -eq $soakMetrics.PSObject.Properties[$name]) { $failures.Add("Soak.$name is required for continuous runtime observation provenance.") }
    }
    try {
        if ([int]$soakMetrics.RuntimeObservationCount -lt 3) { $failures.Add('Soak.RuntimeObservationCount must contain at least three bounded runtime observer windows.') }
        if ([int]$soakMetrics.RuntimeObservationFailures -ne 0) { $failures.Add('Soak.RuntimeObservationFailures must be zero.') }
        if ([int]$soakMetrics.StateEvidenceCount -ne [int]$soakMetrics.RuntimeObservationCount) { $failures.Add('Soak.StateEvidenceCount must equal RuntimeObservationCount.') }
        if ([int]$soakMetrics.ObservedEvents -lt 0 -or [int]$soakMetrics.ObservedReconnects -lt 0) { $failures.Add('Soak observed event/reconnect counts must be non-negative.') }
    } catch { $failures.Add('Soak runtime observation fields must be integral numbers.') }

    $provenance = $SoakArtifact.Provenance
    $heartbeatWindowFinish = if ($null -ne $finish) {
        $finish.AddSeconds($script:V07MeasurementSoakDurationToleranceSeconds)
    } else {
        $null
    }
    $interval = 0
    try { $interval = [int](ConvertTo-V07StrictNonNegativeInteger -Value $provenance.HeartbeatIntervalSeconds) } catch { $interval = 0 }
    if ($interval -lt 1 -or $interval -gt 3600) { $failures.Add('Provenance.HeartbeatIntervalSeconds must be from 1 through 3600.') }
    $heartbeatEntries = @($provenance.HeartbeatEntries)
    if ($heartbeatEntries.Count -lt 2) { $failures.Add('Provenance.HeartbeatEntries must contain at least two observations.') }
    if ($heartbeatEntries.Count -gt $script:V07SoakMaxHeartbeatEntries) { $failures.Add('Provenance.HeartbeatEntries exceeds the bounded entry limit.') }
    $declaredSoakHours = if ($null -ne $soakMetrics.PSObject.Properties['DurationHours']) {
        ConvertTo-V07StrictFiniteNumber -Value $soakMetrics.DurationHours
    } else { $null }
    if ($null -eq $declaredSoakHours -or $declaredSoakHours -lt $script:V07MeasurementSoakMinHours) {
        $failures.Add("Soak duration must be at least $($script:V07MeasurementSoakMinHours) hours before heartbeat coverage can be admitted.")
    }
    if ($interval -gt 0 -and $null -ne $declaredSoakHours) {
        $minimumHeartbeatEntries = [int][Math]::Floor(($declaredSoakHours * 3600.0) / $interval) + 1
        if ($heartbeatEntries.Count -lt $minimumHeartbeatEntries) {
            $failures.Add("HeartbeatEntries contains $($heartbeatEntries.Count) observations but a continuous $declaredSoakHours-hour run at $interval-second cadence requires at least $minimumHeartbeatEntries.")
        }
    }
    try {
        if ([int]$provenance.ExpectedHeartbeatCount -ne $heartbeatEntries.Count) { $failures.Add('ExpectedHeartbeatCount does not equal retained heartbeat entries.') }
        if ([int]$provenance.MissingHeartbeatCount -ne 0) { $failures.Add('MissingHeartbeatCount must be zero for an admitted soak.') }
    } catch { $failures.Add('Heartbeat count fields must be integral numbers.') }
    $previous = $zeroSha
    foreach ($entry in $heartbeatEntries) {
        if (-not (Test-V07UtcTimestampText -Text ([string]$entry.ObservedUtc))) { $failures.Add('Heartbeat entry has an invalid ObservedUtc.'); continue }
        $observed = [DateTimeOffset]$entry.ObservedUtc
        if ($null -ne $start -and ($observed -lt $start -or $observed -gt $heartbeatWindowFinish)) { $failures.Add('Heartbeat entry is outside the soak timestamp window.') }
        if ([string]$entry.Status -cne 'Healthy' -or -not [bool]$entry.TargetSocketPresent) { $failures.Add('Every heartbeat must be a healthy, present-target observation.') }
        if ($null -eq (ConvertTo-V07PositiveProcessId -Value $entry.HerdrProcessId)) { $failures.Add('Heartbeat HerdrProcessId must be positive.') }
        if (-not (Test-V07UtcTimestampText -Text ([string]$entry.HerdrProcessStartUtc))) { $failures.Add('Heartbeat HerdrProcessStartUtc is invalid.') }
        if ([string]::IsNullOrWhiteSpace([string]$entry.HerdrExecutablePath)) { $failures.Add('Heartbeat HerdrExecutablePath is required for exact server identity binding.') }
        if ([string]$entry.HerdrProcessId -ne [string]$admittedIdentity.ProcessId -or
            [string]$entry.HerdrProcessStartUtc -cne $admittedStartText -or
            [string]$entry.HerdrExecutablePath -ine [string]$admittedIdentity.ExecutablePath -or
            [string]$entry.HerdrExecutableSha256 -ine [string]$admittedIdentity.ExecutableSha256 -or
            [string]$entry.HerdrExecutableSha256 -ine [string]$installed.ExecutableSha256) {
            $failures.Add('Heartbeat Herdr PID/start/path/SHA does not match the admitted Herdr server identity.')
        }
        foreach ($roleBinding in @(
                [pscustomobject]@{ Name = 'Core'; Identity = if ($roleIdentityByName.ContainsKey('Core')) { $roleIdentityByName['Core'] } else { $null }; ProcessId = 'CoreProcessId'; StartUtc = 'CoreProcessStartUtc'; Path = 'CoreExecutablePath'; Sha = 'CoreExecutableSha256' },
                [pscustomobject]@{ Name = 'App'; Identity = if ($roleIdentityByName.ContainsKey('App')) { $roleIdentityByName['App'] } else { $null }; ProcessId = 'AppProcessId'; StartUtc = 'AppProcessStartUtc'; Path = 'AppExecutablePath'; Sha = 'AppExecutableSha256' }
            )) {
            $roleIdentity = $roleBinding.Identity
            $entryPid = if ($null -ne $entry.PSObject.Properties[$roleBinding.ProcessId]) { ConvertTo-V07PositiveProcessId -Value $entry.($roleBinding.ProcessId) } else { $null }
            $entryStart = if ($null -ne $entry.PSObject.Properties[$roleBinding.StartUtc]) { [string]$entry.($roleBinding.StartUtc) } else { '' }
            $entryPath = if ($null -ne $entry.PSObject.Properties[$roleBinding.Path]) { [string]$entry.($roleBinding.Path) } else { '' }
            $entrySha = if ($null -ne $entry.PSObject.Properties[$roleBinding.Sha]) { try { ConvertTo-V07NormalizedSha256 -Value ([string]$entry.($roleBinding.Sha)) } catch { '' } } else { '' }
            $expectedPid = if ($null -ne $roleIdentity -and $null -ne $roleIdentity.PSObject.Properties['ProcessId']) { ConvertTo-V07PositiveProcessId -Value $roleIdentity.ProcessId } else { $null }
            $expectedStart = if ($null -ne $roleIdentity -and $null -ne $roleIdentity.PSObject.Properties['ProcessStartUtc'] -and (Test-V07UtcTimestampText -Text ([string]$roleIdentity.ProcessStartUtc))) {
                ConvertTo-V07UtcText -Value ([DateTimeOffset]$roleIdentity.ProcessStartUtc)
            } else { '' }
            $expectedPath = if ($null -ne $roleIdentity -and $null -ne $roleIdentity.PSObject.Properties['ExecutablePath']) { [string]$roleIdentity.ExecutablePath } else { '' }
            $expectedSha = if ($null -ne $roleIdentity -and $null -ne $roleIdentity.PSObject.Properties['ExecutableSha256']) { try { ConvertTo-V07NormalizedSha256 -Value ([string]$roleIdentity.ExecutableSha256) } catch { '' } } else { '' }
            if ($null -eq $expectedPid -or $null -eq $entryPid -or $entryPid -ne $expectedPid -or
                $entryStart -cne $expectedStart -or $entryPath -ine $expectedPath -or $entrySha -ne $expectedSha) {
                $failures.Add("Heartbeat $($roleBinding.Name) PID/start/path/SHA does not match the admitted $($roleBinding.Name) role identity.")
            }
        }
        if ([string]$entry.PreviousEntrySha256 -ine $previous) { $failures.Add('Heartbeat hash chain previous entry does not match.') }
        $entrySha = try { ConvertTo-V07NormalizedSha256 -Value ([string]$entry.EntrySha256) } catch { '' }
        if ([string]::IsNullOrWhiteSpace($entrySha)) { $failures.Add('Heartbeat EntrySha256 is invalid.') } else {
            try { if ((Get-V07SoakEntrySha256 -Entry $entry) -ne $entrySha) { $failures.Add('Heartbeat EntrySha256 does not match entry content.') } } catch { $failures.Add("Heartbeat entry hash could not be recomputed: $($_.Exception.Message)") }
            $previous = $entrySha
        }
    }
    if ($heartbeatEntries.Count -gt 0) {
        if ([string]$provenance.HeartbeatChainHeadSha256 -ine $previous) { $failures.Add('HeartbeatChainHeadSha256 does not match the final heartbeat.') }
        if ([string]$provenance.FirstHeartbeatUtc -ine [string]$heartbeatEntries[0].ObservedUtc -or
            [string]$provenance.LastHeartbeatUtc -ine [string]$heartbeatEntries[-1].ObservedUtc) { $failures.Add('Heartbeat first/last timestamps do not bind to retained entries.') }
        for ($index = 1; $index -lt $heartbeatEntries.Count; $index++) {
            $delta = ([DateTimeOffset]$heartbeatEntries[$index].ObservedUtc - [DateTimeOffset]$heartbeatEntries[$index - 1].ObservedUtc).TotalSeconds
            if ($delta -lt 0 -or ($interval -gt 0 -and $delta -gt ($interval * 2 + 1))) { $failures.Add('Heartbeat cadence contains a gap larger than the bounded observation window.') }
        }
        if ($null -ne $start -and ([DateTimeOffset]$heartbeatEntries[0].ObservedUtc -gt $start.AddSeconds($interval + 1))) {
            $failures.Add('First heartbeat does not cover the beginning of the soak window.')
        }
        if ($null -ne $finish -and ([DateTimeOffset]$heartbeatEntries[-1].ObservedUtc -lt $finish.AddSeconds(-$interval - 1))) {
            $failures.Add('Last heartbeat does not cover the end of the soak window.')
        }
    }

    $faults = @($provenance.FaultObservations)
    $finalizationNowUtc = [DateTimeOffset]::UtcNow
    if ($faults.Count -lt 3) { $failures.Add('At least three scheduled restart/fault observations are required.') }
    if ($faults.Count -gt $script:V07SoakMaxFaultObservations) { $failures.Add('FaultObservations exceeds the bounded entry limit.') }
    try { if ([int]$provenance.ObservationCount -ne $faults.Count) { $failures.Add('ObservationCount does not equal retained fault observations.') } } catch { $failures.Add('ObservationCount must be an integral number.') }
    $scheduledFaults = @($producer.FaultSchedule)
    if ($scheduledFaults.Count -lt 3 -or $scheduledFaults.Count -gt $script:V07SoakMaxFaultObservations) {
        $failures.Add('Producer.FaultSchedule must retain the bounded scheduled observation set.')
    }
    $scheduledById = @{}
    foreach ($scheduled in $scheduledFaults) {
        $scheduledId = [string]$scheduled.Id
        if ([string]::IsNullOrWhiteSpace($scheduledId) -or $scheduledById.ContainsKey($scheduledId)) { $failures.Add('Producer.FaultSchedule ids must be non-empty and unique.') } else { $scheduledById[$scheduledId] = $scheduled }
        if ([string]::IsNullOrWhiteSpace([string]$scheduled.Kind) -or [int]$scheduled.OffsetSeconds -le 0) { $failures.Add("Producer.FaultSchedule '$scheduledId' has invalid kind or offset.") }
        if ($null -ne $start -and [string]$scheduled.DueUtc -cne (ConvertTo-V07SoakUtcText -Value $start.AddSeconds([int]$scheduled.OffsetSeconds))) {
            $failures.Add("Producer.FaultSchedule '$scheduledId' DueUtc is not derived from StartedUtc and OffsetSeconds.")
        }
    }
    $previous = $zeroSha
    $faultIds = @{}
    foreach ($fault in $faults) {
        $faultId = [string]$fault.Id
        if ([string]::IsNullOrWhiteSpace($faultId) -or $faultIds.ContainsKey($faultId)) { $failures.Add('Fault observation ids must be non-empty and unique.') } else { $faultIds[$faultId] = $true }
        $scheduled = if ($scheduledById.ContainsKey($faultId)) { $scheduledById[$faultId] } else { $null }
        if ($null -eq $scheduled) {
            $failures.Add("Fault observation '$faultId' is not present in the immutable producer schedule.")
        } else {
            if ([string]$fault.Kind -cne [string]$scheduled.Kind -or [int]$fault.ScheduledOffsetSeconds -ne [int]$scheduled.OffsetSeconds) {
                $failures.Add("Fault observation '$faultId' kind/offset does not match the immutable producer schedule.")
            }
            $expectedDue = if ($null -ne $start) { ConvertTo-V07SoakUtcText -Value $start.AddSeconds([int]$scheduled.OffsetSeconds) } else { '' }
            if ([string]$fault.DueUtc -cne $expectedDue) { $failures.Add("Fault observation '$faultId' DueUtc does not match its scheduled offset.") }
        }
        if ([string]$fault.Status -cne 'Observed' -or -not [bool]$fault.OperatorAcknowledged) { $failures.Add("Fault observation '$faultId' is not an operator-acknowledged observation.") }
        foreach ($timestampName in @('DueUtc', 'ObservedUtc')) { if (-not (Test-V07UtcTimestampText -Text ([string]$fault.$timestampName))) { $failures.Add("Fault observation '$faultId' has invalid $timestampName.") } }
        if ((Test-V07UtcTimestampText -Text ([string]$fault.DueUtc)) -and (Test-V07UtcTimestampText -Text ([string]$fault.ObservedUtc)) -and
            ([DateTimeOffset]$fault.ObservedUtc -lt [DateTimeOffset]$fault.DueUtc)) {
            $failures.Add("Fault observation '$faultId' is early: ObservedUtc must be at or after DueUtc.")
        }
        if ((Test-V07UtcTimestampText -Text ([string]$fault.ObservedUtc)) -and
            ([DateTimeOffset]$fault.ObservedUtc -gt $finalizationNowUtc)) {
            $failures.Add("Fault observation '$faultId' is in the future: ObservedUtc cannot exceed finalization time.")
        }
        $faultSha = try { ConvertTo-V07NormalizedSha256 -Value ([string]$fault.EvidenceSha256) } catch { '' }
        if ([string]::IsNullOrWhiteSpace([string]$fault.EvidencePath) -or [string]::IsNullOrWhiteSpace($faultSha)) { $failures.Add("Fault observation '$faultId' must bind operator evidence path and SHA-256.") }
        if ($ValidateExternalBindings -and -not [string]::IsNullOrWhiteSpace([string]$fault.EvidencePath)) {
            try {
                $evidenceFull = Assert-V07PathWithinRoot -Path ([string]$fault.EvidencePath) -AllowedRoots @($EvidenceRoot) -Description "Fault observation '$faultId' evidence"
                Assert-V07NotReparsePoint -Path $evidenceFull -Description "Fault observation '$faultId' evidence"
                if (-not (Test-Path -LiteralPath $evidenceFull -PathType Leaf)) { throw 'referenced evidence file is missing' }
                if ((Get-V07Sha256Hex -Path $evidenceFull) -ne $faultSha) { throw 'referenced evidence SHA-256 does not match final bytes' }
            } catch { $failures.Add("Fault observation '$faultId' referenced evidence finalization rehash failed: $($_.Exception.Message)") }
        }
        if ([string]$fault.PreviousEntrySha256 -ine $previous) { $failures.Add("Fault observation '$faultId' hash chain previous entry does not match.") }
        $entrySha = try { ConvertTo-V07NormalizedSha256 -Value ([string]$fault.EntrySha256) } catch { '' }
        if ([string]::IsNullOrWhiteSpace($entrySha)) { $failures.Add("Fault observation '$faultId' EntrySha256 is invalid.") } else {
            try { if ((Get-V07SoakEntrySha256 -Entry $fault) -ne $entrySha) { $failures.Add("Fault observation '$faultId' EntrySha256 does not match entry content.") } } catch { $failures.Add("Fault observation '$faultId' hash could not be recomputed: $($_.Exception.Message)") }
            $previous = $entrySha
        }
    }
    if ($faults.Count -gt 0 -and [string]$provenance.FaultObservationChainHeadSha256 -ine $previous) { $failures.Add('FaultObservationChainHeadSha256 does not match the final observation.') }

    $resources = $SoakArtifact.Resources
    $resourceSamples = @($resources.Samples)
    if ($resourceSamples.Count -lt 3) { $failures.Add('Resources.Samples must retain at least three bounded samples.') }
    try {
        if ([int]$resources.MaxSamples -lt $resourceSamples.Count -or [int]$resources.MaxSamples -gt $script:V07SoakMaxResourceSamples) { $failures.Add('Resources.MaxSamples is outside the bounded resource limit.') }
    } catch { $failures.Add('Resources.MaxSamples must be an integral number.') }
    $peakWs = 0L
    $peakCpu = 0.0
    foreach ($sample in $resourceSamples) {
        if (-not (Test-V07UtcTimestampText -Text ([string]$sample.ObservedUtc))) { $failures.Add('Resource sample has an invalid ObservedUtc.'); continue }
        if ($null -eq (ConvertTo-V07PositiveProcessId -Value $sample.HerdrProcessId)) { $failures.Add('Resource HerdrProcessId must be positive.') }
        try {
            $ws = [long]$sample.CombinedWorkingSetBytes
            $cpu = [double]$sample.CombinedCpuPercent
            if ($ws -lt 0 -or $cpu -lt 0 -or [double]::IsNaN($cpu) -or [double]::IsInfinity($cpu)) { throw 'negative or non-finite resource value' }
            if ($ws -gt $peakWs) { $peakWs = $ws }
            if ($cpu -gt $peakCpu) { $peakCpu = $cpu }
        } catch { $failures.Add("Resource sample values are invalid: $($_.Exception.Message)") }
    }
    try {
        if ([long]$resources.PeakWorkingSetBytes -ne $peakWs) { $failures.Add('PeakWorkingSetBytes does not recompute from retained resource samples.') }
        if ([Math]::Abs([double]$resources.PeakCpuPercent - $peakCpu) -gt $script:V07MeasurementCpuAverageTolerancePercent) { $failures.Add('PeakCpuPercent does not recompute from retained resource samples.') }
    } catch { $failures.Add('Resource peak fields are invalid.') }

    $limits = $SoakArtifact.Limits
    foreach ($name in @('MaxArtifactBytes', 'MaxHeartbeatEntries', 'MaxFaultObservations', 'MaxResourceSamples', 'MaxManifestEntries')) {
        try { if ([long]$limits.$name -le 0) { $failures.Add("Limits.$name must be positive.") } } catch { $failures.Add("Limits.$name must be integral.") }
    }
    if ([long]$limits.MaxArtifactBytes -gt $script:V07SoakMaxArtifactBytes -or
        [int]$limits.MaxHeartbeatEntries -gt $script:V07SoakMaxHeartbeatEntries -or
        [int]$limits.MaxFaultObservations -gt $script:V07SoakMaxFaultObservations -or
        [int]$limits.MaxResourceSamples -gt $script:V07SoakMaxResourceSamples -or
        [int]$limits.MaxManifestEntries -gt $script:V07SoakMaxManifestEntries) {
        $failures.Add('Soak limits exceed the producer safety caps.')
    }
    $manifests = @($SoakArtifact.Artifacts)
    if ($manifests.Count -lt 3 -or $manifests.Count -gt [int]$limits.MaxManifestEntries) { $failures.Add('Artifacts manifest must retain bounded heartbeat, fault, and resource logs.') }
    foreach ($manifest in $manifests) {
        $relative = [string]$manifest.RelativePath
        $sha = try { ConvertTo-V07NormalizedSha256 -Value ([string]$manifest.Sha256) } catch { '' }
        if ([string]::IsNullOrWhiteSpace([string]$manifest.Name) -or [string]::IsNullOrWhiteSpace($relative) -or $relative.Contains('..') -or [IO.Path]::IsPathRooted($relative)) { $failures.Add('Artifact manifest path is unsafe or missing.') }
        if ([long]$manifest.LengthBytes -lt 0 -or [long]$manifest.LengthBytes -gt [long]$limits.MaxArtifactBytes) { $failures.Add("Artifact '$($manifest.Name)' exceeds its bounded byte limit.") }
        if ([string]::IsNullOrWhiteSpace($sha)) { $failures.Add("Artifact '$($manifest.Name)' has an invalid SHA-256.") }
        if ($ValidateExternalBindings) {
            if ([string]::IsNullOrWhiteSpace($EvidenceRoot)) { $failures.Add('EvidenceRoot is required when validating external soak artifacts.') } else {
                try {
                    $full = Assert-V07PathWithinRoot -Path (Join-Path $EvidenceRoot $relative) -AllowedRoots @($EvidenceRoot) -Description "Soak artifact $relative"
                    Assert-V07NotReparsePoint -Path $full -Description "Soak artifact $relative"
                    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw 'manifest file is missing' }
                    $actual = Get-Item -LiteralPath $full -Force
                    if ([long]$actual.Length -ne [long]$manifest.LengthBytes -or (Get-V07Sha256Hex -Path $full) -ne $sha) { throw 'manifest length or SHA-256 does not match on-disk bytes' }
                } catch { $failures.Add("Artifact '$($manifest.Name)' external binding failed: $($_.Exception.Message)") }
            }
        }
    }

    if ($ValidateExternalBindings) {
        if ([string]::IsNullOrWhiteSpace($EvidenceRoot)) {
            $failures.Add('EvidenceRoot is required for observer report, schedule context, and referenced fault evidence rehash.')
        } else {
            foreach ($binding in @(
                    [pscustomobject]@{ Label = 'ObserverReport'; Path = [string]$producer.ObserverReportPath; Sha256 = $producerReportSha; RelativePath = 'runtime-observer-current.json' },
                    [pscustomobject]@{ Label = 'ScheduleContext'; Path = [string]$producer.ScheduleContextPath; Sha256 = $contextSha; RelativePath = 'soak-context.json' })) {
                try {
                    $resolvedBinding = Assert-V07PathWithinRoot -Path $binding.Path -AllowedRoots @($EvidenceRoot) -Description "Soak $($binding.Label)"
                    Assert-V07NotReparsePoint -Path $resolvedBinding -Description "Soak $($binding.Label)"
                    if (-not (Test-Path -LiteralPath $resolvedBinding -PathType Leaf)) { throw 'bound file is missing' }
                    if ((Get-V07Sha256Hex -Path $resolvedBinding) -ne [string]$binding.Sha256) { throw 'bound SHA-256 does not match final bytes' }
                    $matchingManifest = @($manifests | Where-Object { [string]$_.RelativePath -ceq $binding.RelativePath })
                    if ($matchingManifest.Count -ne 1) { throw "artifact manifest must contain exactly one '$($binding.RelativePath)' entry" }
                    $manifestFull = Assert-V07PathWithinRoot -Path (Join-Path $EvidenceRoot $binding.RelativePath) -AllowedRoots @($EvidenceRoot) -Description "Soak $($binding.Label) manifest"
                    if (-not [StringComparer]::OrdinalIgnoreCase.Equals($resolvedBinding, $manifestFull) -or
                        [string]$matchingManifest[0].Sha256 -ine [string]$binding.Sha256) {
                        throw 'producer path/hash and artifact manifest path/hash are not identical'
                    }
                } catch { $failures.Add("Soak $($binding.Label) external binding failed: $($_.Exception.Message)") }
            }
        }
    }

    if ($ValidateExternalBindings -and -not [string]::IsNullOrWhiteSpace($RepositoryRoot)) {
        try {
            $currentCommit = Test-V07CleanRepositoryState -RepositoryRoot $RepositoryRoot
            $currentTree = (@(& git -C $RepositoryRoot rev-parse 'HEAD^{tree}' 2>&1 | ForEach-Object { [string]$_ }) -join '').Trim().ToLowerInvariant()
            if ([string]$candidate.SourceCommit -cne $currentCommit) { $failures.Add('Soak candidate source commit does not match the current clean checkout.') }
            if ([string]$candidate.SourceTree -cne $currentTree) { $failures.Add('Soak candidate source tree does not match the current checkout tree.') }
        } catch { $failures.Add("Soak external Git binding failed: $($_.Exception.Message)") }
        try {
            if (-not (Test-Path -LiteralPath $installed.ExecutablePath -PathType Leaf)) { throw 'installed Herdr executable is missing' }
            Assert-V07NotReparsePoint -Path $installed.ExecutablePath -Description 'installed Herdr executable'
            if ((Get-V07Sha256Hex -Path $installed.ExecutablePath) -ne $installedSha) { throw 'installed Herdr executable SHA-256 does not match' }
        } catch { $failures.Add("Installed Herdr external binding failed: $($_.Exception.Message)") }
        try {
            $resolvedObserver = Assert-V07PathWithinRoot -Path ([string]$producer.ObserverExecutablePath) -AllowedRoots @($RepositoryRoot) -Description 'observer executable'
            Assert-V07NotReparsePoint -Path $resolvedObserver -Description 'observer executable'
            if (-not (Test-Path -LiteralPath $resolvedObserver -PathType Leaf)) { throw 'observer executable is missing' }
            $observerInfo = Get-Item -LiteralPath $resolvedObserver -Force -ErrorAction Stop
            $observerActualSha = Get-V07Sha256Hex -Path $resolvedObserver
            $expectedObserverPath = Assert-V07PathWithinRoot -Path (Join-Path $RepositoryRoot ([string]$candidateObserver.RelativePath).Replace('/', [IO.Path]::DirectorySeparatorChar)) -AllowedRoots @($RepositoryRoot) -Description 'candidate observer executable'
            if (-not [StringComparer]::OrdinalIgnoreCase.Equals($resolvedObserver, $expectedObserverPath) -or
                $observerActualSha -ne $producerObserverSha -or
                $observerActualSha -ne $candidateObserverSha -or
                [long]$observerInfo.Length -ne [long]$candidateObserver.LengthBytes) {
                throw 'observer executable path, length, or SHA-256 does not match the exact candidate binding'
            }
        } catch { $failures.Add("Observer executable external binding failed: $($_.Exception.Message)") }
    }

    return @($failures)
}

# -----------------------------------------------------------------------------
# Fail-Closed Artifact Admission
# -----------------------------------------------------------------------------
function Test-V07MeasurementArtifactAdmission {
    <#
    .SYNOPSIS
        The fail-closed admission gate for measurement artifacts. Rejects missing,
        forged, stale, and wrong-session evidence. When RepositoryRoot and
        CandidateDirectory are supplied, verifies the source commit against the
        current HEAD and every declared binary (and role binary) against on-disk
        bytes. Returns a structured result; never throws for evidence problems
        (callers decide how to surface the failures).
    #>
    param(
        [Parameter(Mandatory)]$Artifact,
        [string]$RepositoryRoot = '',
        [string]$CandidateDirectory = ''
    )

    $failures = [System.Collections.Generic.List[string]]::new()

    # ---- Strict schema property enumeration (hostile unknown-property rejection) ----
    foreach ($failure in @(Test-V07MeasurementArtifactSchema -Artifact $Artifact)) {
        $failures.Add($failure)
    }

    # ---- Shape ----
    if ($null -eq $Artifact.PSObject.Properties['SchemaVersion'] -or
        [string]$Artifact.SchemaVersion -ne $script:V07MeasurementSchemaVersion) {
        $failures.Add("SchemaVersion must be exactly '$($script:V07MeasurementSchemaVersion)'.")
    }
    if ($null -eq $Artifact.PSObject.Properties['ArtifactKind'] -or
        [string]$Artifact.ArtifactKind -ne $script:V07MeasurementArtifactKind) {
        $failures.Add("ArtifactKind must be '$($script:V07MeasurementArtifactKind)'.")
    }
    if ($null -eq $Artifact.PSObject.Properties['Mode'] -or
        [string]$Artifact.Mode -notin @('Live', 'Synthetic')) {
        $failures.Add('Mode must be Live or Synthetic.')
    }
    foreach ($required in @('RunId', 'StartedUtc', 'FinishedUtc', 'HostEnvironment', 'Session', 'Candidate', 'Roles', 'Metrics', 'Observed', 'RawSamples', 'PhaseLog')) {
        if ($null -eq $Artifact.PSObject.Properties[$required] -or $null -eq $Artifact.$required) {
            $failures.Add("Artifact is missing required property '$required'.")
        }
    }
    if ($failures.Count -gt 0) {
        return [pscustomobject]@{ Valid = $false; Failures = @($failures); Metrics = $null }
    }

    $mode = [string]$Artifact.Mode
    $runStartedUtc = $Artifact.StartedUtc
    $runFinishedUtc = $Artifact.FinishedUtc
    if (-not (Test-V07UtcTimestampText -Text $runStartedUtc) -or
        -not (Test-V07UtcTimestampText -Text $runFinishedUtc)) {
        $failures.Add('Artifact StartedUtc/FinishedUtc must be valid UTC timestamps.')
    } elseif (([DateTimeOffset]$runStartedUtc) -gt ([DateTimeOffset]$runFinishedUtc)) {
        $failures.Add('Artifact StartedUtc is later than FinishedUtc.')
    }

    # ---- Run integrity ----
    $cancelled = [bool]$Artifact.Cancelled
    $timedOut = [bool]$Artifact.TimedOut
    if ($cancelled) {
        $failures.Add('Run was cancelled; observed flags cannot be admitted.')
    }
    if ($timedOut) {
        $failures.Add('Run timed out; observed flags cannot be admitted.')
    }
    if ($mode -eq 'Synthetic') {
        $failures.Add('Synthetic artifacts never admit runtime evidence.')
    }

    # ---- Session ----
    $session = $Artifact.Session
    foreach ($required in @('ControlPaneId', 'ObservedControlPaneId', 'ControlHerdrSocketPath', 'TargetHerdrSocketPath', 'HerdrExecutablePath', 'HerdrExecutableSha256', 'ControlHerdrServerIdentity')) {
        if ($null -eq $session.PSObject.Properties[$required] -or $null -eq $session.$required) {
            $failures.Add("Session is missing required property '$required'.")
        }
    }
    if ($null -ne $session.PSObject.Properties['ControlPaneId'] -and
        $null -ne $session.PSObject.Properties['ObservedControlPaneId'] -and
        [string]$session.ControlPaneId -ne [string]$session.ObservedControlPaneId) {
        $failures.Add('Recorded control pane id does not match the observed control pane id (wrong-session evidence).')
    }
    if ($null -ne $session.PSObject.Properties['ControlHerdrSocketPath'] -and
        $null -ne $session.PSObject.Properties['TargetHerdrSocketPath'] -and
        [StringComparer]::OrdinalIgnoreCase.Equals([string]$session.ControlHerdrSocketPath, [string]$session.TargetHerdrSocketPath)) {
        $failures.Add('Control and target Herdr sockets are identical (wrong-session evidence).')
    }
    $herdrSha = if ($null -ne $session.PSObject.Properties['HerdrExecutableSha256']) {
        try { ConvertTo-V07NormalizedSha256 -Value ([string]$session.HerdrExecutableSha256) } catch { '' }
    } else { '' }
    if ([string]::IsNullOrWhiteSpace($herdrSha)) {
        $failures.Add('Session HerdrExecutableSha256 must be a 64-hex SHA-256.')
    }
    $serverIdentity = $session.ControlHerdrServerIdentity
    if ($null -eq $serverIdentity.PSObject.Properties['ProcessId'] -or
        $null -eq (ConvertTo-V07PositiveProcessId -Value $serverIdentity.ProcessId)) {
        $failures.Add('Session control server identity must have a positive PID.')
    }
    $serverStartText = if ($null -ne $serverIdentity.PSObject.Properties['ProcessStartUtc']) { $serverIdentity.ProcessStartUtc } else { '' }
    if (-not (Test-V07UtcTimestampText -Text $serverStartText)) {
        $failures.Add('Session control server identity must have a valid UTC start time.')
    } elseif (([DateTimeOffset]$serverStartText).UtcDateTime -gt [DateTime]::UtcNow) {
        $failures.Add('Session control server identity start time is in the future (changed or forged start evidence).')
    }
    if ($null -eq $serverIdentity.PSObject.Properties['ExecutablePath'] -or
        [string]::IsNullOrWhiteSpace([string]$serverIdentity.ExecutablePath)) {
        $failures.Add('Session control server identity must retain the executable path.')
    }
    if ($null -ne $session.PSObject.Properties['HerdrExecutablePath'] -and
        $null -ne $serverIdentity.PSObject.Properties['ExecutablePath'] -and
        -not [StringComparer]::OrdinalIgnoreCase.Equals([string]$session.HerdrExecutablePath, [string]$serverIdentity.ExecutablePath)) {
        $failures.Add('Session control server executable path does not match the admitted Herdr executable (wrong-session evidence).')
    }
    if ($null -ne $serverIdentity.PSObject.Properties['ExecutableSha256']) {
        $serverSha = try { ConvertTo-V07NormalizedSha256 -Value ([string]$serverIdentity.ExecutableSha256) } catch { '' }
        if (-not [string]::IsNullOrWhiteSpace($herdrSha) -and -not [string]::IsNullOrWhiteSpace($serverSha) -and $herdrSha -ne $serverSha) {
            $failures.Add('Session control server executable SHA-256 does not match the admitted Herdr executable (wrong-session evidence).')
        }
    }
    # Cross-check the live environment when the harness is run inside a full
    # authorized Herdr session (HERDR_ENV, socket, and pane id all present).
    if ($env:HERDR_ENV -eq '1' -and
        -not [string]::IsNullOrWhiteSpace($env:HERDR_SOCKET_PATH) -and
        -not [string]::IsNullOrWhiteSpace($env:HERDR_PANE_ID) -and
        $null -ne $session.PSObject.Properties['ControlPaneId'] -and
        [string]$env:HERDR_PANE_ID -ne [string]$session.ControlPaneId) {
        $failures.Add('Recorded control pane id does not match the live HERDR_PANE_ID (wrong-session evidence).')
    }

    # ---- Candidate ----
    $candidate = $Artifact.Candidate
    if ($null -eq $candidate.PSObject.Properties['SourceCommit'] -or
        [string]$candidate.SourceCommit -notmatch '^[0-9a-f]{40}$') {
        $failures.Add('Candidate.SourceCommit must be a 40-hex lowercase commit hash.')
    }
    if ($null -eq $candidate.PSObject.Properties['GitTreeClean'] -or
        -not [bool]$candidate.GitTreeClean) {
        $failures.Add('Candidate.GitTreeClean must be true for runtime evidence.')
    }
    $hasBinaries = ($null -ne $candidate.PSObject.Properties['Binaries'] -and
        $null -ne $candidate.Binaries -and @($candidate.Binaries).Count -gt 0)
    if (-not $hasBinaries) {
        $failures.Add('Candidate.Binaries must declare the exact candidate binaries.')
    }

    # ---- Roles ----
    $roles = @($Artifact.Roles)
    if ($roles.Count -ne 2) {
        $failures.Add("Roles must contain exactly Core and App identities; found $($roles.Count).")
    }
    $rolePids = [System.Collections.Generic.List[long]]::new()
    $roleByName = @{}
    foreach ($role in $roles) {
        $roleName = [string]$role.Role
        if ($roleName -notin @('Core', 'App')) {
            $failures.Add("Role '$roleName' is not a supported HerdrOps role.")
            continue
        }
        $rolePidValue = ConvertTo-V07PositiveProcessId -Value $role.ProcessId
        if ($null -eq $rolePidValue) {
            $failures.Add("Role '$roleName' must have a positive PID.")
        } else {
            $rolePids.Add([long]$rolePidValue)
            $roleByName[$roleName] = $role
        }
        $roleStartText = if ($null -ne $role.PSObject.Properties['ProcessStartUtc']) { $role.ProcessStartUtc } else { '' }
        if (-not (Test-V07UtcTimestampText -Text $roleStartText)) {
            $failures.Add("Role '$roleName' must have a valid UTC process start time.")
        } elseif (([DateTimeOffset]$roleStartText).UtcDateTime -gt [DateTime]::UtcNow) {
            $failures.Add("Role '$roleName' process start time is in the future (changed or forged start evidence).")
        }
        if ($null -eq $role.PSObject.Properties['BinaryPath'] -or
            [string]::IsNullOrWhiteSpace([string]$role.BinaryPath)) {
            $failures.Add("Role '$roleName' must retain its binary path.")
        } else {
            $roleFileName = [IO.Path]::GetFileName([string]$role.BinaryPath)
            $expectedNames = @("HerdrOps.$roleName.dll", "HerdrOps.$roleName.exe")
            if ($expectedNames -inotcontains $roleFileName) {
                $failures.Add("Role '$roleName' binary '$roleFileName' does not match the expected role binary name (wrong-role evidence).")
            }
        }
        $roleShaValue = ''
        if ($null -ne $role.PSObject.Properties['BinarySha256']) {
            try {
                $roleShaValue = ConvertTo-V07NormalizedSha256 -Value ([string]$role.BinarySha256)
            } catch {
                $roleShaValue = ''
            }
        }
        if ($roleShaValue -notmatch '^[0-9a-f]{64}$') {
            $failures.Add("Role '$roleName' must declare a 64-hex binary SHA-256.")
        }
    }
    if (@($rolePids | Select-Object -Unique).Count -ne $rolePids.Count) {
        $failures.Add('Core and App roles must have distinct PIDs.')
    }

    # ---- Metrics / Observed / Raw samples ----
    $metrics = $Artifact.Metrics
    $observed = $Artifact.Observed
    $rawSamples = $Artifact.RawSamples
    foreach ($key in $script:V07MeasurementMetrics) {
        if ($null -eq $metrics.PSObject.Properties[$key]) {
            $failures.Add("Metrics is missing required metric '$key'.")
        }
    }
    $corePid = if ($roleByName.ContainsKey('Core')) { [long]$roleByName['Core'].ProcessId } else { 0L }
    $appPid = if ($roleByName.ContainsKey('App')) { [long]$roleByName['App'].ProcessId } else { 0L }

    $metricToObservedKey = @{
        'DashboardColdLaunchP95Ms'     = 'DashboardColdLaunch'
        'WidgetStateDeltaLatencyP95Ms' = 'WidgetStateDeltaLatency'
        'HerdrReconnectReconcileSeconds' = 'HerdrReconnectReconcile'
        'IdleCpuAveragePercent'        = 'IdleCpu'
        'IdleWorkingSetCombinedBytes'  = 'IdleWorkingSet'
    }
    $integrityPassedMetrics = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($metricKey in @('DashboardColdLaunchP95Ms', 'WidgetStateDeltaLatencyP95Ms', 'HerdrReconnectReconcileSeconds', 'IdleCpuAveragePercent', 'IdleWorkingSetCombinedBytes')) {
        $observedKey = $metricToObservedKey[$metricKey]
        $flag = if ($null -ne $observed.PSObject.Properties[$observedKey]) { [bool]$observed.$observedKey } else { $false }
        $sampleKey = $observedKey
        $samples = @()
        if ($null -ne $rawSamples.PSObject.Properties[$sampleKey] -and $null -ne $rawSamples.$sampleKey) {
            $samples = @($rawSamples.$sampleKey)
        }
        if ($flag -and $samples.Count -eq 0) {
            $failures.Add("Metric '$metricKey' is declared observed but retains no raw samples (forged evidence).")
        }
        $integrity = Test-V07RawSamplesForMetric -MetricName $sampleKey -Samples $samples -RunStartedUtc $runStartedUtc -RunFinishedUtc $runFinishedUtc -CoreProcessId $corePid -AppProcessId $appPid
        if (-not $integrity.Valid) {
            foreach ($failure in $integrity.Failures) { $failures.Add($failure) }
        } else {
            [void]$integrityPassedMetrics.Add($sampleKey)
        }
    }

    # Static metrics must be exactly zero / false for a healthy run.
    if ($metrics.PSObject.Properties['UnboundedTerminalReads'] -and [long]$metrics.UnboundedTerminalReads -ne 0) {
        $failures.Add('UnboundedTerminalReads must be zero for admitted runtime evidence.')
    }
    if ($metrics.PSObject.Properties['UnhandledCrashesDuringSoak'] -and [long]$metrics.UnhandledCrashesDuringSoak -ne 0) {
        $failures.Add('UnhandledCrashesDuringSoak must be zero in the measurement artifact (soak evidence is separate).')
    }
    if ($metrics.PSObject.Properties['AdministratorRequired'] -and [bool]$metrics.AdministratorRequired) {
        $failures.Add('AdministratorRequired must be false for admitted runtime evidence.')
    }

    # ---- Aggregate recomputation (forgery detection) ----
    $aggregateFailures = Test-V07MetricAggregates -Metrics $metrics -RawSamples $rawSamples -IntegrityPassedMetrics $integrityPassedMetrics
    foreach ($failure in $aggregateFailures) { $failures.Add($failure) }

    # ---- External verification (stale evidence) ----
    if (-not [string]::IsNullOrWhiteSpace($RepositoryRoot)) {
        $resolvedRoot = $null
        try {
            $resolvedRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path
            Assert-V07NotReparsePoint -Path $resolvedRoot -Description 'Repository root'
            # SkipCleanCheck is intentional: the recorded evidence was captured on a
            # clean tree at run start; post-run dirty state (e.g. this run's own
            # evidence files) must not invalidate the recorded HEAD binding.
            $currentHead = Test-V07CleanRepositoryState -RepositoryRoot $resolvedRoot -SkipCleanCheck
            if ([string]$candidate.SourceCommit -ne $currentHead) {
                $failures.Add("Candidate.SourceCommit '$($candidate.SourceCommit)' is stale; current HEAD is '$currentHead'.")
            }
        } catch {
            $failures.Add("Repository root verification failed: $($_.Exception.Message)")
            $resolvedRoot = $null
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($RepositoryRoot) -and -not [string]::IsNullOrWhiteSpace($CandidateDirectory)) {
        $allowedRoots = @($RepositoryRoot, $CandidateDirectory)
        foreach ($bin in @($candidate.Binaries)) {
            $rel = [string]$bin.RelativePath
            if ([string]::IsNullOrWhiteSpace($rel) -or $rel.Contains('..')) {
                $failures.Add("Candidate binary relative path is unsafe: '$rel'")
                continue
            }
            $fullPath = Join-Path $RepositoryRoot $rel
            try {
                $resolvedBin = Assert-V07PathWithinRoot -Path $fullPath -AllowedRoots $allowedRoots -Description "Candidate binary $rel"
                Assert-V07NotReparsePoint -Path $resolvedBin -Description "Candidate binary $rel"
                if (-not (Test-Path -LiteralPath $resolvedBin -PathType Leaf)) {
                    $failures.Add("Candidate binary does not exist on disk: $rel")
                    continue
                }
                $actualLength = (Get-Item -LiteralPath $resolvedBin -Force -ErrorAction Stop).Length
                $actualSha = Get-V07Sha256Hex -Path $resolvedBin
                $declaredSha = try { ConvertTo-V07NormalizedSha256 -Value ([string]$bin.Sha256) } catch { '' }
                if ([long]$actualLength -ne [long]$bin.LengthBytes -or $actualSha -ne $declaredSha) {
                    $failures.Add("Candidate binary '$rel' does not match declared length/hash (stale or forged evidence).")
                }
            } catch {
                $failures.Add("Candidate binary '$rel' verification failed: $($_.Exception.Message)")
            }
        }
        # Role binaries must match the exact candidate bytes for the correct role.
        foreach ($role in $roles) {
            $expectedNames = @("HerdrOps.$($role.Role).dll", "HerdrOps.$($role.Role).exe")
            $rolePath = [string]$role.BinaryPath
            $roleSha = try { ConvertTo-V07NormalizedSha256 -Value ([string]$role.BinarySha256) } catch { '' }
            $matchingCandidate = @($candidate.Binaries | Where-Object {
                $candidateName = [IO.Path]::GetFileName([string]$_.RelativePath)
                ($expectedNames -icontains $candidateName) -and
                ([string]$_.Sha256).ToLowerInvariant() -eq $roleSha
            })
            if ($matchingCandidate.Count -ne 1) {
                $failures.Add("Role '$($role.Role)' binary does not match exactly one candidate binary of the same role (wrong-role evidence).")
                continue
            }
            try {
                $resolvedRolePath = Assert-V07PathWithinRoot -Path $rolePath -AllowedRoots $allowedRoots -Description "$($role.Role) role binary"
                Assert-V07NotReparsePoint -Path $resolvedRolePath -Description "$($role.Role) role binary"
                $candidateFullPath = [IO.Path]::GetFullPath((Join-Path $RepositoryRoot $matchingCandidate[0].RelativePath))
                if (-not [StringComparer]::OrdinalIgnoreCase.Equals(
                        [IO.Path]::GetFullPath($resolvedRolePath),
                        $candidateFullPath)) {
                    $failures.Add("Role '$($role.Role)' binary path does not match the exact candidate path (wrong-role evidence).")
                }
                $actualRoleSha = Get-V07Sha256Hex -Path $resolvedRolePath
                if ($actualRoleSha -ne $roleSha) {
                    $failures.Add("Role '$($role.Role)' binary on-disk SHA-256 does not match the declared role hash (stale evidence).")
                }
            } catch {
                $failures.Add("Role '$($role.Role)' binary verification failed: $($_.Exception.Message)")
            }
        }
    }

    $metricsResult = $null
    if ($failures.Count -eq 0) {
        $metricsResult = $metrics
    }
    return [pscustomobject]@{
        Valid    = ($failures.Count -eq 0)
        Failures = @($failures)
        Metrics  = $metricsResult
    }
}

# -----------------------------------------------------------------------------
# Soak Artifact Validation (finalization prerequisite)
# -----------------------------------------------------------------------------
function Test-V07SoakArtifact {
    <#
    .SYNOPSIS
        Validates a v0.7.0-soak soak artifact against its measurement artifact.
        Requires an uninterrupted live run of at least 8 hours with zero crashes,
        zero unreconciled state, and zero unbounded terminal reads, bound to the
        same measurement run through the cross-file run-id/hash chain
        (MeasurementRunId + MeasurementArtifactSha256), the same target/control
        sessions, the same Herdr executable, and the same source commit.
    #>
    param(
        [Parameter(Mandatory)]$SoakArtifact,
        [Parameter(Mandatory)]$MeasurementArtifact,
        [string]$RepositoryRoot = '',
        [string]$EvidenceRoot = '',
        [switch]$ValidateExternalBindings
    )

    $failures = [System.Collections.Generic.List[string]]::new()

    foreach ($failure in @(Test-V07SoakArtifactSchema -SoakArtifact $SoakArtifact)) {
        $failures.Add($failure)
    }

    if ($null -eq $SoakArtifact.PSObject.Properties['SchemaVersion'] -or
        [string]$SoakArtifact.SchemaVersion -ne $script:V07SoakSchemaVersion) {
        $failures.Add("Soak SchemaVersion must be '$($script:V07SoakSchemaVersion)'.")
    }
    if ($null -eq $SoakArtifact.PSObject.Properties['ArtifactKind'] -or
        [string]$SoakArtifact.ArtifactKind -ne $script:V07SoakArtifactKind) {
        $failures.Add("Soak ArtifactKind must be '$($script:V07SoakArtifactKind)'.")
    }
    if ($null -eq $SoakArtifact.PSObject.Properties['Mode'] -or
        [string]$SoakArtifact.Mode -ne 'Live') {
        $failures.Add('Soak Mode must be Live; synthetic soak can never satisfy the 8-hour requirement.')
    }
    $soakStartedUtc = $null
    $soakFinishedUtc = $null
    $soakTimeValid = $null -ne $SoakArtifact.PSObject.Properties['StartedUtc'] -and
        $null -ne $SoakArtifact.PSObject.Properties['FinishedUtc'] -and
        (Test-V07UtcTimestampText -Text $SoakArtifact.StartedUtc) -and
        (Test-V07UtcTimestampText -Text $SoakArtifact.FinishedUtc)
    if ($soakTimeValid) {
        $soakStartedUtc = [DateTimeOffset]$SoakArtifact.StartedUtc
        $soakFinishedUtc = [DateTimeOffset]$SoakArtifact.FinishedUtc
        $soakTimeValid = $soakStartedUtc -le $soakFinishedUtc
    }
    if (-not $soakTimeValid) {
        $failures.Add('Soak StartedUtc/FinishedUtc must be valid UTC timestamps in order.')
    }
    if ([bool]$SoakArtifact.Cancelled -or [bool]$SoakArtifact.TimedOut) {
        $failures.Add('Soak run was cancelled or timed out and cannot be admitted.')
    }

    # Cross-file run-id/hash chain to the measurement artifact.
    if ($null -eq $SoakArtifact.PSObject.Properties['MeasurementRunId'] -or
        [string]$SoakArtifact.MeasurementRunId -ne [string]$MeasurementArtifact.RunId) {
        $failures.Add('Soak MeasurementRunId does not match the measurement artifact RunId (broken cross-file chain).')
    }
    if ($null -ne $SoakArtifact.PSObject.Properties['MeasurementArtifactSha256']) {
        $computed = Get-V07ArtifactCanonicalSha256 -Artifact $MeasurementArtifact
        $declared = ([string]$SoakArtifact.MeasurementArtifactSha256).ToLowerInvariant()
        if ($declared -notmatch '^[0-9a-f]{64}$' -or $computed -ne $declared) {
            $failures.Add('Soak MeasurementArtifactSha256 does not match the measurement artifact (broken or forged cross-file chain).')
        }
    } else {
        $failures.Add('Soak MeasurementArtifactSha256 is required to bind the soak log to its measurement artifact.')
    }

    $measurementSession = $MeasurementArtifact.Session
    $session = $SoakArtifact.Session
    foreach ($required in @('ControlHerdrSocketPath', 'TargetHerdrSocketPath', 'HerdrExecutableSha256')) {
        if ($null -eq $session.PSObject.Properties[$required] -or [string]::IsNullOrWhiteSpace([string]$session.$required)) {
            $failures.Add("Soak Session is missing required property '$required'.")
        }
    }
    if ($null -ne $session.PSObject.Properties['TargetHerdrSocketPath'] -and
        -not [StringComparer]::OrdinalIgnoreCase.Equals([string]$session.TargetHerdrSocketPath, [string]$measurementSession.TargetHerdrSocketPath)) {
        $failures.Add('Soak target session socket does not match the measurement session (wrong-session evidence).')
    }
    if ($null -ne $session.PSObject.Properties['ControlHerdrSocketPath'] -and
        -not [StringComparer]::OrdinalIgnoreCase.Equals([string]$session.ControlHerdrSocketPath, [string]$measurementSession.ControlHerdrSocketPath)) {
        $failures.Add('Soak control session socket does not match the measurement session (wrong-session evidence).')
    }
    if ($null -ne $session.PSObject.Properties['HerdrExecutableSha256']) {
        $soakSha = try { ConvertTo-V07NormalizedSha256 -Value ([string]$session.HerdrExecutableSha256) } catch { '' }
        $measurementSha = try { ConvertTo-V07NormalizedSha256 -Value ([string]$measurementSession.HerdrExecutableSha256) } catch { '' }
        if (-not [string]::IsNullOrWhiteSpace($soakSha) -and -not [string]::IsNullOrWhiteSpace($measurementSha) -and $soakSha -ne $measurementSha) {
            $failures.Add('Soak Herdr executable SHA-256 does not match the measurement session (wrong-session evidence).')
        }
    }
    if ($null -eq $SoakArtifact.PSObject.Properties['Candidate'] -or
        $null -eq $SoakArtifact.Candidate.PSObject.Properties['SourceCommit'] -or
        ([string]$SoakArtifact.Candidate.SourceCommit).ToLowerInvariant() -ne ([string]$MeasurementArtifact.Candidate.SourceCommit).ToLowerInvariant()) {
        $failures.Add('Soak source commit does not match the measurement candidate (stale evidence).')
    }
    $soak = $SoakArtifact.Soak
    $declaredDurationHours = $null
    if ($null -ne $soak.PSObject.Properties['DurationHours']) {
        $declaredDurationHours = ConvertTo-V07StrictFiniteNumber -Value $soak.DurationHours
    }
    if ($null -eq $declaredDurationHours -or $declaredDurationHours -lt $script:V07MeasurementSoakMinHours) {
        $failures.Add("Soak DurationHours must be at least $($script:V07MeasurementSoakMinHours) hours.")
    }
    if ($null -ne $declaredDurationHours -and $soakTimeValid) {
        $actualDurationSeconds = ($soakFinishedUtc - $soakStartedUtc).TotalSeconds
        $declaredDurationSeconds = $declaredDurationHours * 3600.0
        $allowedMinimumSeconds = $declaredDurationSeconds - $script:V07MeasurementSoakDurationToleranceSeconds
        if ($actualDurationSeconds -lt $allowedMinimumSeconds) {
            $failures.Add(
                "Soak timestamp span $actualDurationSeconds seconds is shorter than declared DurationHours $declaredDurationHours by more than the deterministic $($script:V07MeasurementSoakDurationToleranceSeconds)-second tolerance.")
        }
    }
    if ($null -eq $soak.PSObject.Properties['UnhandledCrashes'] -or
        (ConvertTo-V07StrictNonNegativeInteger -Value $soak.UnhandledCrashes) -ne 0) {
        $failures.Add('Soak UnhandledCrashes must be zero.')
    }
    if ($null -eq $soak.PSObject.Properties['UnreconciledStateCount'] -or
        (ConvertTo-V07StrictNonNegativeInteger -Value $soak.UnreconciledStateCount) -ne 0) {
        $failures.Add('Soak UnreconciledStateCount must be zero.')
    }
    if ($null -eq $soak.PSObject.Properties['UnboundedTerminalReads'] -or
        (ConvertTo-V07StrictNonNegativeInteger -Value $soak.UnboundedTerminalReads) -ne 0) {
        $failures.Add('Soak UnboundedTerminalReads must be zero.')
    }

    foreach ($failure in @(Test-V07SoakProvenance -SoakArtifact $SoakArtifact -MeasurementArtifact $MeasurementArtifact `
            -RepositoryRoot $RepositoryRoot -EvidenceRoot $EvidenceRoot -ValidateExternalBindings:$ValidateExternalBindings)) {
        $failures.Add($failure)
    }

    return [pscustomobject]@{
        Valid    = ($failures.Count -eq 0)
        Failures = @($failures)
    }
}

# -----------------------------------------------------------------------------
# Finalizer: Measurement Artifact + Soak Artifact -> v0.7.0 Budget Report
# -----------------------------------------------------------------------------
function ConvertTo-V07RuntimeBudgetReport {
    <#
    .SYNOPSIS
        Finalizes a validated live measurement artifact plus a validated matching
        soak artifact into the standard v0.7.0 budget report with EvidenceClass
        Runtime and role-bound ProcessTelemetry. Never emits Runtime credit unless
        every admission rule passes; otherwise returns CanFinalize=false with
        explicit blockers. The returned report is intended for the existing
        Test-V07PerformanceBudgets.ps1 gate.
    #>
    param(
        [Parameter(Mandatory)]$MeasurementArtifact,
        $SoakArtifact = $null,
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$CandidateDirectory,
        [string]$EvidenceRoot = '',
        [string]$RunId = '',
        [switch]$SkipDiskVerification
    )

    $blockers = [System.Collections.Generic.List[string]]::new()

    $admission = Test-V07MeasurementArtifactAdmission -Artifact $MeasurementArtifact -RepositoryRoot $RepositoryRoot -CandidateDirectory $CandidateDirectory
    foreach ($failure in $admission.Failures) { $blockers.Add($failure) }
    if (-not $admission.Valid) {
        return [pscustomobject]@{
            CanFinalize  = $false
            Reason       = 'Measurement artifact failed fail-closed admission.'
            Blockers     = @($blockers)
            BudgetReport = $null
        }
    }
    if ($null -eq $SoakArtifact) {
        return [pscustomobject]@{
            CanFinalize  = $false
            Reason       = 'Matching 8-hour soak evidence is required before Runtime credit can be finalized.'
            Blockers     = @('SoakArtifact is missing.')
            BudgetReport = $null
        }
    }
    if ([string]::IsNullOrWhiteSpace($EvidenceRoot)) {
        return [pscustomobject]@{
            CanFinalize  = $false
            Reason       = 'External soak evidence root is required before Runtime credit can be finalized.'
            Blockers     = @('EvidenceRoot is required; finalization always rehashes the retained soak logs, observer report, schedule context, and referenced operator evidence.')
            BudgetReport = $null
        }
    }

    $session = $MeasurementArtifact.Session
    $candidate = $MeasurementArtifact.Candidate
    $metrics = $MeasurementArtifact.Metrics
    $rawSamples = $MeasurementArtifact.RawSamples

    $soakCheck = Test-V07SoakArtifact -SoakArtifact $SoakArtifact -MeasurementArtifact $MeasurementArtifact `
        -RepositoryRoot $RepositoryRoot -EvidenceRoot $EvidenceRoot -ValidateExternalBindings
    foreach ($failure in $soakCheck.Failures) { $blockers.Add($failure) }
    if (-not $soakCheck.Valid) {
        return [pscustomobject]@{
            CanFinalize  = $false
            Reason       = 'Matching 8-hour soak evidence is required before Runtime credit can be finalized.'
            Blockers     = @($blockers)
            BudgetReport = $null
        }
    }

    # Build ProcessTelemetry from the exact role records.
    $telemetry = [System.Collections.Generic.List[object]]::new()
    foreach ($role in @($MeasurementArtifact.Roles)) {
        $telemetry.Add([pscustomobject]@{
            ProcessName    = "HerdrOps.$($role.Role)"
            ProcessId      = [long]$role.ProcessId
            ProcessStartUtc = ConvertTo-V07UtcText -Value $role.ProcessStartUtc
            BinaryPath     = [string]$role.BinaryPath
            BinarySha256   = ([string]$role.BinarySha256).ToLowerInvariant()
        })
    }

    $launchSamples = if ($null -ne $rawSamples.PSObject.Properties['DashboardColdLaunch']) {
        [double[]]@($rawSamples.DashboardColdLaunch | ForEach-Object { [double]$_.Milliseconds })
    } else { [double[]]@() }
    $latencySamples = if ($null -ne $rawSamples.PSObject.Properties['WidgetStateDeltaLatency']) {
        [double[]]@($rawSamples.WidgetStateDeltaLatency | ForEach-Object { [double]$_.Milliseconds })
    } else { [double[]]@() }

    $budgetReport = [pscustomobject]@{
        SchemaVersion = $script:V07BudgetSchemaVersion
        RunId         = if ([string]::IsNullOrWhiteSpace($RunId)) { [string]$MeasurementArtifact.RunId } else { $RunId }
        TimestampUtc  = ConvertTo-V07UtcText -Value $MeasurementArtifact.FinishedUtc
        EvidenceClass = 'Runtime'
        HostEnvironment = $MeasurementArtifact.HostEnvironment
        Candidate     = $candidate
        Metrics       = [pscustomobject]@{
            IdleCpuAveragePercent         = [double]$metrics.IdleCpuAveragePercent
            IdleWorkingSetCombinedBytes   = [long]$metrics.IdleWorkingSetCombinedBytes
            WidgetStateDeltaLatencyP95Ms  = [double]$metrics.WidgetStateDeltaLatencyP95Ms
            WidgetDeltaLatencySamplesMs   = $latencySamples
            DashboardColdLaunchP95Ms      = [double]$metrics.DashboardColdLaunchP95Ms
            DashboardColdLaunchSamplesMs  = $launchSamples
            HerdrReconnectReconcileSeconds = [double]$metrics.HerdrReconnectReconcileSeconds
            UnboundedTerminalReads        = [long]$metrics.UnboundedTerminalReads
            UnhandledCrashesDuringSoak    = [long]$metrics.UnhandledCrashesDuringSoak
            SoakDurationHours             = [double]$SoakArtifact.Soak.DurationHours
            AdministratorRequired         = [bool]$metrics.AdministratorRequired
        }
        Waivers       = @()
        ProcessTelemetry = @($telemetry)
        EvidenceBoundary = [pscustomobject]@{
            StaticEvidence     = 'OBSERVED'
            SyntheticEvidence  = 'NOT OBSERVED / NOT CLAIMED'
            ContractEvidence   = 'OBSERVED'
            ActualHerdrRuntime = 'OBSERVED'
            SoakExecution      = 'OBSERVED'
            HumanUatDecision   = 'NOT OBSERVED / PENDING'
            ReleaseEvidence    = 'NOT OBSERVED / NOT CLAIMED'
        }
    }

    return [pscustomobject]@{
        CanFinalize  = $true
        Reason       = 'Live measurement and matching 8-hour soak evidence admitted; Runtime budget report finalized.'
        Blockers     = @()
        BudgetReport = $budgetReport
    }
}

# -----------------------------------------------------------------------------
# Lightweight Budget Target Evaluation (harness gate report only; the budget
# gate remains the authoritative evaluator)
# -----------------------------------------------------------------------------
function Test-V07MeasurementBudgetTargets {
    param([Parameter(Mandatory)]$Metrics)

    $checks = [System.Collections.Generic.List[object]]::new()
    $cpuObs = [double]$Metrics.IdleCpuAveragePercent
    $checks.Add([pscustomobject]@{ Id = 'V07-MEASURE-CPU'; Target = "<= $($script:V07MeasurementBudgetMaxIdleCpuAveragePercent)%"; Observed = $cpuObs; Passed = ($cpuObs -le $script:V07MeasurementBudgetMaxIdleCpuAveragePercent) })
    $wsObs = [long]$Metrics.IdleWorkingSetCombinedBytes
    $checks.Add([pscustomobject]@{ Id = 'V07-MEASURE-WORKINGSET'; Target = '<= 188,743,680 bytes'; Observed = $wsObs; Passed = ($wsObs -le $script:V07MeasurementBudgetMaxIdleWorkingSetCombinedBytes) })
    $latObs = [double]$Metrics.WidgetStateDeltaLatencyP95Ms
    $checks.Add([pscustomobject]@{ Id = 'V07-MEASURE-LATENCY'; Target = 'p95 <= 250.0 ms'; Observed = $latObs; Passed = ($latObs -le $script:V07MeasurementBudgetMaxWidgetStateDeltaLatencyP95Ms) })
    $launchObs = [double]$Metrics.DashboardColdLaunchP95Ms
    $checks.Add([pscustomobject]@{ Id = 'V07-MEASURE-LAUNCH'; Target = 'p95 <= 2000.0 ms'; Observed = $launchObs; Passed = ($launchObs -le $script:V07MeasurementBudgetMaxDashboardColdLaunchP95Ms) })
    $recObs = [double]$Metrics.HerdrReconnectReconcileSeconds
    $checks.Add([pscustomobject]@{ Id = 'V07-MEASURE-RECONNECT'; Target = '<= 5.0 s'; Observed = $recObs; Passed = ($recObs -le $script:V07MeasurementBudgetMaxHerdrReconnectReconcileSeconds) })
    $termObs = [long]$Metrics.UnboundedTerminalReads
    $checks.Add([pscustomobject]@{ Id = 'V07-MEASURE-TERMINAL'; Target = '0'; Observed = $termObs; Passed = ($termObs -eq 0) })
    $crashObs = [long]$Metrics.UnhandledCrashesDuringSoak
    $checks.Add([pscustomobject]@{ Id = 'V07-MEASURE-SOAK-CRASHES'; Target = '0'; Observed = $crashObs; Passed = ($crashObs -eq 0) })
    $adminObs = [bool]$Metrics.AdministratorRequired
    $checks.Add([pscustomobject]@{ Id = 'V07-MEASURE-PRIVILEGE'; Target = 'None (false)'; Observed = $adminObs; Passed = (-not $adminObs) })
    return @($checks)
}
