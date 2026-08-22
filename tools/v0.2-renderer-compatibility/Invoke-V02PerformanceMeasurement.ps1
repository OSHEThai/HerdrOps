#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$DestinationPath,

    [string]$EvidenceRoot,

    [string]$RepositoryRoot,

    [string]$PackageIdentityPath,

    [string]$PackageArchivePath,

    [string]$ExtractedPackageRoot,

    [string]$ExpectedSourceCommit,

    [string]$ExpectedSourceTree,

    [int]$AppProcessId = 0,

    [int]$CoreProcessId = 0,

    [scriptblock]$LiveTelemetryProvider,

    [string]$SoakEvidencePath,

    [switch]$Synthetic,

    [scriptblock]$SyntheticTelemetryProvider,

    [object[]]$SyntheticSoakBins,

    [string]$TestFaultInjectionStage
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'RendererCompatibility.Common.ps1')
$packageBindingLib = Join-Path $PSScriptRoot '..\lib\V02RuntimePackageBinding.ps1'
if (Test-Path -LiteralPath $packageBindingLib) {
    . $packageBindingLib
}

function Assert-RawExactProperties {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string[]]$Names,
        [Parameter(Mandatory = $true)][string]$Context
    )
    if ($null -eq $Value -or $Value -isnot [psobject]) { throw "$Context is missing or not a JSON object." }
    $actual = @($Value.PSObject.Properties | ForEach-Object { $_.Name })
    if ($actual.Count -ne $Names.Count) { throw "$Context must contain exactly: $($Names -join ', '); found: $($actual -join ', ')." }
    foreach ($name in $Names) {
        $matches = @($Value.PSObject.Properties | Where-Object { [StringComparer]::Ordinal.Equals([string]$_.Name, $name) })
        if ($matches.Count -ne 1) { throw "$Context must contain exactly one case-sensitive '$name' property." }
    }
}

function Get-ProcessSafeCreationTime {
    param([Parameter(Mandatory = $true)]$Process)
    try {
        return $Process.StartTime.ToUniversalTime()
    } catch {
        throw "Unable to query start time for process ID $($Process.Id): $($_.Exception.Message)"
    }
}

function Get-RunningProcessMainModulePath {
    param([Parameter(Mandatory = $true)]$Process)
    try {
        return [IO.Path]::GetFullPath($Process.MainModule.FileName)
    } catch {
        throw "Unable to query executable path for process ID $($Process.Id): $($_.Exception.Message)"
    }
}

# Resolve repository and evidence root
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
}
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)

if ([string]::IsNullOrWhiteSpace($EvidenceRoot)) {
    if ([IO.Path]::IsPathRooted($DestinationPath)) {
        $EvidenceRoot = Split-Path -Parent ([IO.Path]::GetFullPath($DestinationPath))
    } else {
        $EvidenceRoot = $RepositoryRoot
    }
}
$EvidenceRoot = [IO.Path]::GetFullPath($EvidenceRoot).TrimEnd('\','/')

$fullDestinationPath = if ([IO.Path]::IsPathRooted($DestinationPath)) {
    [IO.Path]::GetFullPath($DestinationPath)
} else {
    [IO.Path]::GetFullPath((Join-Path $EvidenceRoot $DestinationPath))
}

# Confinement and reparse point validation
Assert-RendererNonReparsePath -Root $EvidenceRoot -Path $fullDestinationPath -Context 'Raw performance observations destination path'
if ($fullDestinationPath -cne $EvidenceRoot -and -not $fullDestinationPath.StartsWith($EvidenceRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Raw performance observations destination path '$fullDestinationPath' escaped the evidence root '$EvidenceRoot'."
}

# No-clobber protection
if (Test-Path -LiteralPath $fullDestinationPath) {
    throw "Raw performance observations destination file already exists; refusing to clobber '$fullDestinationPath'."
}

$destinationParent = Split-Path -Parent $fullDestinationPath
if (-not (Test-Path -LiteralPath $destinationParent -PathType Container)) {
    New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
}

$destinationRelative = $fullDestinationPath.Substring($EvidenceRoot.Length).TrimStart('\','/').Replace('\','/')
Assert-RendererRelativePath $destinationRelative 'Raw performance observations destination relativePath'

$canonicalOrders = @()
$canonicalSoakBins = @()
$previousTimestamp = [DateTime]::MinValue

# -----------------------------------------------------------------------------
# LIVE MODE EXECUTION
# -----------------------------------------------------------------------------
if (-not $Synthetic) {
    # Mandatory candidate bindings in live mode
    if ([string]::IsNullOrWhiteSpace($ExpectedSourceCommit) -or [string]::IsNullOrWhiteSpace($ExpectedSourceTree)) {
        throw 'Live performance measurement requires exact candidate source bindings (-ExpectedSourceCommit and -ExpectedSourceTree).'
    }
    if ([string]::IsNullOrWhiteSpace($PackageIdentityPath) -or [string]::IsNullOrWhiteSpace($PackageArchivePath) -or [string]::IsNullOrWhiteSpace($ExtractedPackageRoot)) {
        throw 'Live performance measurement requires exact candidate package bindings (-PackageIdentityPath, -PackageArchivePath, and -ExtractedPackageRoot).'
    }

    $repoGitIdentity = Get-RendererGitIdentity $RepositoryRoot
    if ($repoGitIdentity.CommitSha -cne $ExpectedSourceCommit.ToLowerInvariant()) {
        throw "Source commit mismatch: repository HEAD is '$($repoGitIdentity.CommitSha)'; expected '$ExpectedSourceCommit'."
    }
    if ($repoGitIdentity.TreeSha -cne $ExpectedSourceTree.ToLowerInvariant()) {
        throw "Source tree mismatch: repository HEAD tree is '$($repoGitIdentity.TreeSha)'; expected '$ExpectedSourceTree'."
    }

    $profileCandidatePath = Join-Path $RepositoryRoot 'tools\packaging\v0.2\package-identity-profile.json'
    $packageBinding = Resolve-V02RuntimePackageBinding `
        -IdentityPath $PackageIdentityPath `
        -ArchivePath $PackageArchivePath `
        -PackageRoot $ExtractedPackageRoot `
        -RepositoryRoot $RepositoryRoot `
        -ProfilePath $profileCandidatePath `
        -ExpectedSourceCommit $ExpectedSourceCommit `
        -ExpectedSourceTree $ExpectedSourceTree

    if ($AppProcessId -le 0 -or $CoreProcessId -le 0) {
        throw 'Live performance measurement requires positive AppProcessId and CoreProcessId.'
    }
    if ($AppProcessId -eq $CoreProcessId) {
        throw 'AppProcessId and CoreProcessId must be distinct processes.'
    }

    if ($null -eq $LiveTelemetryProvider) {
        throw 'Live performance measurement requires an authenticated LiveTelemetryProvider scriptblock.'
    }

    # In live mode: Soak evidence must be provided separately and not simulated
    if ([string]::IsNullOrWhiteSpace($SoakEvidencePath)) {
        throw 'Live performance measurement requires separate validated soak evidence (-SoakEvidencePath); AC/Battery 60m soak remains separate and must not be simulated.'
    }
    $fullSoakPath = if ([IO.Path]::IsPathRooted($SoakEvidencePath)) {
        [IO.Path]::GetFullPath($SoakEvidencePath)
    } else {
        [IO.Path]::GetFullPath((Join-Path $EvidenceRoot $SoakEvidencePath))
    }
    Assert-RendererNonReparsePath -Root $EvidenceRoot -Path $fullSoakPath -Context 'Soak evidence path'
    if ($fullSoakPath -cne $EvidenceRoot -and -not $fullSoakPath.StartsWith($EvidenceRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Soak evidence path '$fullSoakPath' escaped the evidence root '$EvidenceRoot'."
    }
    $soakIdentity = Get-RendererStableFileIdentity $EvidenceRoot $fullSoakPath 'Soak evidence file' -IncludeBytes
    $soakJson = (New-Object Text.UTF8Encoding($false, $true)).GetString($soakIdentity.Content)
    $soakParsed = ConvertFrom-StrictHumanDesignReviewJson -Json $soakJson -Description 'Soak evidence file'
    if ($PSVersionTable.PSVersion.Major -ge 7 -and (Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) {
        $soakParsed = $soakJson | ConvertFrom-Json -DateKind String
    }
    Assert-RawExactProperties $soakParsed @('soakBins') 'Soak evidence file'
    $rawSoakList = @($soakParsed.soakBins)
    if ($rawSoakList.Count -ne 24) {
        throw "Soak evidence must contain exactly 24 five-minute bins (12 AC then 12 Battery); found $($rawSoakList.Count)."
    }
    for ($bi = 0; $bi -lt 24; $bi++) {
        $bin = $rawSoakList[$bi]
        Assert-RawExactProperties $bin @('powerSource','ordinal','durationMinutes','observedUtc','workingSetStartBytes','workingSetEndBytes','rendererStable') "Soak bin $bi"
        $expectedPower = if ($bi -lt 12) { 'AC' } else { 'Battery' }
        $expectedOrdinal = $bi % 12
        if ([string]$bin.powerSource -cne $expectedPower) {
            throw "Soak bin $bi powerSource must be '$expectedPower'; found '$($bin.powerSource)'."
        }
        if ([long]$bin.ordinal -ne $expectedOrdinal) {
            throw "Soak bin $bi ordinal must equal $expectedOrdinal; found $($bin.ordinal)."
        }
        if ([long]$bin.durationMinutes -ne 5) {
            throw "Soak bin $bi durationMinutes must be 5; found $($bin.durationMinutes)."
        }
        Assert-RendererUtc $bin.observedUtc "Soak bin $bi observedUtc"
        Assert-RendererNonnegativeInteger $bin.workingSetStartBytes "Soak bin $bi workingSetStartBytes"
        Assert-RendererNonnegativeInteger $bin.workingSetEndBytes "Soak bin $bi workingSetEndBytes"
        Assert-RendererBoolean $bin.rendererStable "Soak bin $bi rendererStable"

        $canonicalSoakBins += [pscustomobject][ordered]@{
            powerSource = $expectedPower
            ordinal = [int]$expectedOrdinal
            durationMinutes = 5
            observedUtc = [string]$bin.observedUtc
            workingSetStartBytes = [long]$bin.workingSetStartBytes
            workingSetEndBytes = [long]$bin.workingSetEndBytes
            rendererStable = [bool]$bin.rendererStable
        }
    }

    $appProcess = $null
    $coreProcess = $null
    try {
        $appProcess = [System.Diagnostics.Process]::GetProcessById($AppProcessId)
    } catch {
        throw "Unable to connect to target App process (PID $AppProcessId): $($_.Exception.Message)"
    }
    try {
        $coreProcess = [System.Diagnostics.Process]::GetProcessById($CoreProcessId)
    } catch {
        throw "Unable to connect to target Core process (PID $CoreProcessId): $($_.Exception.Message)"
    }

    if ($null -eq $appProcess -or $appProcess.HasExited) {
        throw "Target App process ($AppProcessId) has already exited."
    }
    if ($null -eq $coreProcess -or $coreProcess.HasExited) {
        throw "Target Core process ($CoreProcessId) has already exited."
    }

    $appStartTimeUtc = Get-ProcessSafeCreationTime $appProcess
    $coreStartTimeUtc = Get-ProcessSafeCreationTime $coreProcess

    $currentProcess = [System.Diagnostics.Process]::GetCurrentProcess()
    $currentSessionId = $currentProcess.SessionId
    if ($appProcess.SessionId -ne $currentSessionId -or $coreProcess.SessionId -ne $currentSessionId) {
        throw "Process session ID mismatch: current session is $currentSessionId; App session is $($appProcess.SessionId); Core session is $($coreProcess.SessionId)."
    }

    $appExePath = Get-RunningProcessMainModulePath $appProcess
    $coreExePath = Get-RunningProcessMainModulePath $coreProcess
    if ($appExePath -cne $packageBinding.AppPath) {
        throw "Running App executable path '$appExePath' does not match validated package path '$($packageBinding.AppPath)'."
    }
    if ($coreExePath -cne $packageBinding.CorePath) {
        throw "Running Core executable path '$coreExePath' does not match validated package path '$($packageBinding.CorePath)'."
    }

    $liveAppHash = ((Get-FileHash -LiteralPath $appExePath -Algorithm SHA256).Hash).ToUpperInvariant()
    $liveCoreHash = ((Get-FileHash -LiteralPath $coreExePath -Algorithm SHA256).Hash).ToUpperInvariant()
    if ($liveAppHash -cne $packageBinding.AppSha256) {
        throw "Running App executable SHA-256 hash '$liveAppHash' does not match validated package hash '$($packageBinding.AppSha256)'."
    }
    if ($liveCoreHash -cne $packageBinding.CoreSha256) {
        throw "Running Core executable SHA-256 hash '$liveCoreHash' does not match validated package hash '$($packageBinding.CoreSha256)'."
    }

    # Governed order sequence: AB then BA
    $governedOrders = @('AB', 'BA')
    for ($oi = 0; $oi -lt 2; $oi++) {
        $orderName = $governedOrders[$oi]

        # 1 Warmup repetition
        $appProcess.Refresh()
        $coreProcess.Refresh()
        if ($appProcess.HasExited) { throw "App process ($AppProcessId) terminated unexpectedly during Order $orderName warmup." }
        if ($coreProcess.HasExited) { throw "Core process ($CoreProcessId) terminated unexpectedly during Order $orderName warmup." }
        if ((Get-ProcessSafeCreationTime $appProcess) -ne $appStartTimeUtc) { throw "App process PID ($AppProcessId) was recycled during Order $orderName warmup." }
        if ((Get-ProcessSafeCreationTime $coreProcess) -ne $coreStartTimeUtc) { throw "Core process PID ($CoreProcessId) was recycled during Order $orderName warmup." }

        $warmupSampleA = $null
        $warmupSampleB = $null
        $warmupUtc = $null

        # Mode A then Mode B (for AB: Hardware then SoftwareOnly; for BA: SoftwareOnly then Hardware)
        foreach ($modeKey in @('a', 'b')) {
            $expectedRenderer = if ($modeKey -eq 'a') { 'Hardware' } else { 'SoftwareOnly' }
            $liveResult = @(& $LiveTelemetryProvider $orderName $true 0 $modeKey)
            if ($liveResult.Count -ne 1) { throw "Live telemetry provider must return exactly one sample for Order $orderName warmup mode $modeKey." }
            $sample = $liveResult[0]

            Assert-RawExactProperties $sample @(
                'Authenticated', 'Source', 'AppProcessId', 'CoreProcessId',
                'AppStartTimeUtc', 'CoreStartTimeUtc', 'ObservedUtc', 'RendererMode',
                'CpuBasisPoints', 'WorkingSetMaximumBytes', 'LatencyMicroseconds', 'UiStallMicroseconds'
            ) "Order $orderName warmup mode $modeKey sample"

            if ($sample.Authenticated -isnot [bool] -or -not $sample.Authenticated) { throw "Order $orderName warmup mode $modeKey sample is not authenticated." }
            if ([string]::IsNullOrWhiteSpace([string]$sample.Source)) { throw "Order $orderName warmup mode $modeKey sample missing source." }
            if ($sample.AppProcessId -isnot [int] -or [int]$sample.AppProcessId -ne $AppProcessId) { throw "Order $orderName warmup mode $modeKey App PID mismatch." }
            if ($sample.CoreProcessId -isnot [int] -or [int]$sample.CoreProcessId -ne $CoreProcessId) { throw "Order $orderName warmup mode $modeKey Core PID mismatch." }

            $sAppStart = if ($sample.AppStartTimeUtc -is [DateTime]) { $sample.AppStartTimeUtc.ToUniversalTime() } else { [DateTimeOffset]::Parse([string]$sample.AppStartTimeUtc, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime }
            $sCoreStart = if ($sample.CoreStartTimeUtc -is [DateTime]) { $sample.CoreStartTimeUtc.ToUniversalTime() } else { [DateTimeOffset]::Parse([string]$sample.CoreStartTimeUtc, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime }
            if ($sAppStart -ne $appStartTimeUtc) { throw "Order $orderName warmup mode $modeKey App start time drifted." }
            if ($sCoreStart -ne $coreStartTimeUtc) { throw "Order $orderName warmup mode $modeKey Core start time drifted." }

            Assert-RendererUtc $sample.ObservedUtc "Order $orderName warmup mode $modeKey ObservedUtc"
            $sampleTime = [DateTimeOffset]::Parse([string]$sample.ObservedUtc, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime
            if ($sampleTime -le $previousTimestamp) { throw "Order $orderName warmup mode $modeKey timestamp is not strictly increasing." }
            $previousTimestamp = $sampleTime
            $warmupUtc = [string]$sample.ObservedUtc

            if ([string]$sample.RendererMode -cne $expectedRenderer) {
                throw "Order $orderName warmup mode $modeKey expected renderer mode '$expectedRenderer'; found '$($sample.RendererMode)'."
            }

            $latencies = @($sample.LatencyMicroseconds)
            $stalls = @($sample.UiStallMicroseconds)
            if ($latencies.Count -lt 20) { throw "Order $orderName warmup mode $modeKey requires at least 20 latency observations; found $($latencies.Count)." }
            if ($stalls.Count -lt 20) { throw "Order $orderName warmup mode $modeKey requires at least 20 UI-stall observations; found $($stalls.Count)." }

            $boundSample = [pscustomobject][ordered]@{
                cpuBasisPoints = [long]$sample.CpuBasisPoints
                workingSetMaximumBytes = [long]$sample.WorkingSetMaximumBytes
                latencyMicroseconds = @($latencies[0..19] | ForEach-Object { [long]$_ })
                uiStallMicroseconds = @($stalls[0..19] | ForEach-Object { [long]$_ })
            }

            if ($modeKey -eq 'a') { $warmupSampleA = $boundSample } else { $warmupSampleB = $boundSample }
        }

        $canonicalWarmup = [pscustomobject][ordered]@{
            ordinal = 0
            observedUtc = $warmupUtc
            a = $warmupSampleA
            b = $warmupSampleB
        }

        # 5 Measured repetitions
        $canonicalReps = @()
        for ($ri = 0; $ri -lt 5; $ri++) {
            $appProcess.Refresh()
            $coreProcess.Refresh()
            if ($appProcess.HasExited) { throw "App process ($AppProcessId) terminated unexpectedly during Order $orderName repetition $ri." }
            if ($coreProcess.HasExited) { throw "Core process ($CoreProcessId) terminated unexpectedly during Order $orderName repetition $ri." }
            if ((Get-ProcessSafeCreationTime $appProcess) -ne $appStartTimeUtc) { throw "App process PID ($AppProcessId) was recycled during Order $orderName repetition $ri." }
            if ((Get-ProcessSafeCreationTime $coreProcess) -ne $coreStartTimeUtc) { throw "Core process PID ($CoreProcessId) was recycled during Order $orderName repetition $ri." }

            $repSampleA = $null
            $repSampleB = $null
            $repUtc = $null

            foreach ($modeKey in @('a', 'b')) {
                $expectedRenderer = if ($modeKey -eq 'a') { 'Hardware' } else { 'SoftwareOnly' }
                $liveResult = @(& $LiveTelemetryProvider $orderName $false $ri $modeKey)
                if ($liveResult.Count -ne 1) { throw "Live telemetry provider must return exactly one sample for Order $orderName repetition $ri mode $modeKey." }
                $sample = $liveResult[0]

                Assert-RawExactProperties $sample @(
                    'Authenticated', 'Source', 'AppProcessId', 'CoreProcessId',
                    'AppStartTimeUtc', 'CoreStartTimeUtc', 'ObservedUtc', 'RendererMode',
                    'CpuBasisPoints', 'WorkingSetMaximumBytes', 'LatencyMicroseconds', 'UiStallMicroseconds'
                ) "Order $orderName repetition $ri mode $modeKey sample"

                if ($sample.Authenticated -isnot [bool] -or -not $sample.Authenticated) { throw "Order $orderName repetition $ri mode $modeKey sample is not authenticated." }
                if ([string]::IsNullOrWhiteSpace([string]$sample.Source)) { throw "Order $orderName repetition $ri mode $modeKey sample missing source." }
                if ($sample.AppProcessId -isnot [int] -or [int]$sample.AppProcessId -ne $AppProcessId) { throw "Order $orderName repetition $ri mode $modeKey App PID mismatch." }
                if ($sample.CoreProcessId -isnot [int] -or [int]$sample.CoreProcessId -ne $CoreProcessId) { throw "Order $orderName repetition $ri mode $modeKey Core PID mismatch." }

                $sAppStart = if ($sample.AppStartTimeUtc -is [DateTime]) { $sample.AppStartTimeUtc.ToUniversalTime() } else { [DateTimeOffset]::Parse([string]$sample.AppStartTimeUtc, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime }
                $sCoreStart = if ($sample.CoreStartTimeUtc -is [DateTime]) { $sample.CoreStartTimeUtc.ToUniversalTime() } else { [DateTimeOffset]::Parse([string]$sample.CoreStartTimeUtc, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime }
                if ($sAppStart -ne $appStartTimeUtc) { throw "Order $orderName repetition $ri mode $modeKey App start time drifted." }
                if ($sCoreStart -ne $coreStartTimeUtc) { throw "Order $orderName repetition $ri mode $modeKey Core start time drifted." }

                Assert-RendererUtc $sample.ObservedUtc "Order $orderName repetition $ri mode $modeKey ObservedUtc"
                $sampleTime = [DateTimeOffset]::Parse([string]$sample.ObservedUtc, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime
                if ($sampleTime -le $previousTimestamp) { throw "Order $orderName repetition $ri mode $modeKey timestamp is not strictly increasing." }
                $previousTimestamp = $sampleTime
                $repUtc = [string]$sample.ObservedUtc

                if ([string]$sample.RendererMode -cne $expectedRenderer) {
                    throw "Order $orderName repetition $ri mode $modeKey expected renderer mode '$expectedRenderer'; found '$($sample.RendererMode)'."
                }

                $latencies = @($sample.LatencyMicroseconds)
                $stalls = @($sample.UiStallMicroseconds)
                if ($latencies.Count -lt 20) { throw "Order $orderName repetition $ri mode $modeKey requires at least 20 latency observations; found $($latencies.Count)." }
                if ($stalls.Count -lt 20) { throw "Order $orderName repetition $ri mode $modeKey requires at least 20 UI-stall observations; found $($stalls.Count)." }

                $boundSample = [pscustomobject][ordered]@{
                    cpuBasisPoints = [long]$sample.CpuBasisPoints
                    workingSetMaximumBytes = [long]$sample.WorkingSetMaximumBytes
                    latencyMicroseconds = @($latencies[0..19] | ForEach-Object { [long]$_ })
                    uiStallMicroseconds = @($stalls[0..19] | ForEach-Object { [long]$_ })
                }

                if ($modeKey -eq 'a') { $repSampleA = $boundSample } else { $repSampleB = $boundSample }
            }

            $canonicalReps += [pscustomobject][ordered]@{
                ordinal = [int]$ri
                observedUtc = $repUtc
                a = $repSampleA
                b = $repSampleB
            }
        }

        $canonicalOrders += [pscustomobject][ordered]@{
            order = $orderName
            warmup = @($canonicalWarmup)
            repetitions = $canonicalReps
        }
    }
}
# -----------------------------------------------------------------------------
# SYNTHETIC MODE EXECUTION
# -----------------------------------------------------------------------------
else {
    $governedOrders = @('AB', 'BA')
    $baseTime = [DateTime]::UtcNow.AddHours(-1)

    for ($oi = 0; $oi -lt 2; $oi++) {
        $orderName = $governedOrders[$oi]

        # Warmup
        $warmupUtc = $baseTime.AddMinutes($oi * 20).ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')
        $warmupSampleA = $null
        $warmupSampleB = $null

        foreach ($modeKey in @('a', 'b')) {
            $sample = if ($null -ne $SyntheticTelemetryProvider) {
                & $SyntheticTelemetryProvider $orderName $true 0 $modeKey
            } else {
                [pscustomobject][ordered]@{
                    cpuBasisPoints = 50
                    workingSetMaximumBytes = 104857600
                    latencyMicroseconds = @(1..20 | ForEach-Object { 100000L })
                    uiStallMicroseconds = @(1..20 | ForEach-Object { 10000L })
                }
            }

            Assert-RawExactProperties $sample @('cpuBasisPoints','workingSetMaximumBytes','latencyMicroseconds','uiStallMicroseconds') "Synthetic order $orderName warmup mode $modeKey"
            $latencies = @($sample.latencyMicroseconds)
            $stalls = @($sample.uiStallMicroseconds)
            if ($latencies.Count -lt 20) { throw "Synthetic order $orderName warmup mode $modeKey requires at least 20 latency observations; found $($latencies.Count)." }
            if ($stalls.Count -lt 20) { throw "Synthetic order $orderName warmup mode $modeKey requires at least 20 UI-stall observations; found $($stalls.Count)." }

            $boundSample = [pscustomobject][ordered]@{
                cpuBasisPoints = [long]$sample.cpuBasisPoints
                workingSetMaximumBytes = [long]$sample.workingSetMaximumBytes
                latencyMicroseconds = @($latencies[0..19] | ForEach-Object { [long]$_ })
                uiStallMicroseconds = @($stalls[0..19] | ForEach-Object { [long]$_ })
            }

            if ($modeKey -eq 'a') { $warmupSampleA = $boundSample } else { $warmupSampleB = $boundSample }
        }

        $canonicalWarmup = [pscustomobject][ordered]@{
            ordinal = 0
            observedUtc = $warmupUtc
            a = $warmupSampleA
            b = $warmupSampleB
        }

        # 5 Repetitions
        $canonicalReps = @()
        for ($ri = 0; $ri -lt 5; $ri++) {
            $repUtc = $baseTime.AddMinutes($oi * 20 + $ri + 1).ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')
            $repSampleA = $null
            $repSampleB = $null

            foreach ($modeKey in @('a', 'b')) {
                $sample = if ($null -ne $SyntheticTelemetryProvider) {
                    & $SyntheticTelemetryProvider $orderName $false $ri $modeKey
                } else {
                    [pscustomobject][ordered]@{
                        cpuBasisPoints = 50
                        workingSetMaximumBytes = 104857600
                        latencyMicroseconds = @(1..20 | ForEach-Object { 100000L })
                        uiStallMicroseconds = @(1..20 | ForEach-Object { 10000L })
                    }
                }

                Assert-RawExactProperties $sample @('cpuBasisPoints','workingSetMaximumBytes','latencyMicroseconds','uiStallMicroseconds') "Synthetic order $orderName rep $ri mode $modeKey"
                $latencies = @($sample.latencyMicroseconds)
                $stalls = @($sample.uiStallMicroseconds)
                if ($latencies.Count -lt 20) { throw "Synthetic order $orderName rep $ri mode $modeKey requires at least 20 latency observations; found $($latencies.Count)." }
                if ($stalls.Count -lt 20) { throw "Synthetic order $orderName rep $ri mode $modeKey requires at least 20 UI-stall observations; found $($stalls.Count)." }

                $boundSample = [pscustomobject][ordered]@{
                    cpuBasisPoints = [long]$sample.cpuBasisPoints
                    workingSetMaximumBytes = [long]$sample.workingSetMaximumBytes
                    latencyMicroseconds = @($latencies[0..19] | ForEach-Object { [long]$_ })
                    uiStallMicroseconds = @($stalls[0..19] | ForEach-Object { [long]$_ })
                }

                if ($modeKey -eq 'a') { $repSampleA = $boundSample } else { $repSampleB = $boundSample }
            }

            $canonicalReps += [pscustomobject][ordered]@{
                ordinal = [int]$ri
                observedUtc = $repUtc
                a = $repSampleA
                b = $repSampleB
            }
        }

        $canonicalOrders += [pscustomobject][ordered]@{
            order = $orderName
            warmup = @($canonicalWarmup)
            repetitions = $canonicalReps
        }
    }

    # Soak Bins (from parameter or synthetic generator)
    if ($null -ne $SyntheticSoakBins -and @($SyntheticSoakBins).Count -gt 0) {
        $rawBins = @($SyntheticSoakBins)
        if ($rawBins.Count -ne 24) {
            throw "Synthetic soak bins must contain exactly 24 bins; found $($rawBins.Count)."
        }
        for ($bi = 0; $bi -lt 24; $bi++) {
            $bin = $rawBins[$bi]
            Assert-RawExactProperties $bin @('powerSource','ordinal','durationMinutes','observedUtc','workingSetStartBytes','workingSetEndBytes','rendererStable') "Synthetic soak bin $bi"
            $canonicalSoakBins += [pscustomobject][ordered]@{
                powerSource = [string]$bin.powerSource
                ordinal = [int]$bin.ordinal
                durationMinutes = [int]$bin.durationMinutes
                observedUtc = [string]$bin.observedUtc
                workingSetStartBytes = [long]$bin.workingSetStartBytes
                workingSetEndBytes = [long]$bin.workingSetEndBytes
                rendererStable = [bool]$bin.rendererStable
            }
        }
    } else {
        foreach ($power in @('AC', 'Battery')) {
            for ($i = 0; $i -lt 12; $i++) {
                $offset = if ($power -ceq 'Battery') { 12 } else { 0 }
                $canonicalSoakBins += [pscustomobject][ordered]@{
                    powerSource = $power
                    ordinal = [int]$i
                    durationMinutes = 5
                    observedUtc = ('2026-08-22T12:{0:00}:00.0000000Z' -f ($i + 1 + $offset))
                    workingSetStartBytes = 104857600L
                    workingSetEndBytes = 104857600L
                    rendererStable = $true
                }
            }
        }
    }
}

# Construct raw observations object
$rawObservationsObject = [pscustomobject][ordered]@{
    orders = $canonicalOrders
    soakBins = $canonicalSoakBins
}

# JCS Canonicalization
$canonicalJson = ConvertTo-RendererCanonicalJson $rawObservationsObject $RepositoryRoot
$canonicalSha = Get-HumanDesignReviewSha256ForText $canonicalJson
$fileBytes = (New-Object Text.UTF8Encoding($false, $true)).GetBytes($canonicalJson + "`n")

# Atomic Write / Commit with crash rollback
$stagingDirectory = Join-Path $destinationParent ('.raw-perf-stage-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stagingDirectory | Out-Null
$stagingPath = Join-Path $stagingDirectory ([IO.Path]::GetFileName($fullDestinationPath))

try {
    $stream = [IO.File]::Open($stagingPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $stream.Write($fileBytes, 0, $fileBytes.Length)
        $stream.Flush($true)
        if ($TestFaultInjectionStage -eq 'MidWrite') {
            throw 'Injected performance collector crash during staging write.'
        }
    } finally {
        $stream.Dispose()
    }

    if ($TestFaultInjectionStage -eq 'BeforeCommit') {
        throw 'Injected performance collector crash before atomic commit.'
    }

    Assert-RendererNonReparsePath -Root $EvidenceRoot -Path $stagingPath -Context 'Staged raw performance observations'

    # Check for destination collision immediately before atomic move
    if (Test-Path -LiteralPath $fullDestinationPath) {
        throw "Raw performance observations destination file appeared during publish; refusing to clobber '$fullDestinationPath'."
    }

    [IO.File]::Move($stagingPath, $fullDestinationPath)
} finally {
    if (Test-Path -LiteralPath $stagingDirectory) {
        Remove-Item -LiteralPath $stagingDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Verify post-move stable file identity
$stableIdentity = Get-RendererStableFileIdentity $EvidenceRoot $fullDestinationPath 'Raw performance observations' -IncludeBytes
if ($stableIdentity.Bytes -ne [long]$fileBytes.Length -or $stableIdentity.Sha256 -ne (Get-HumanDesignReviewSha256ForBytes $fileBytes)) {
    throw 'Raw performance observations file identity changed during atomic publish.'
}
if ($stableIdentity.Content.Length -ne $fileBytes.Length) {
    throw 'Raw performance observations byte count changed during atomic publish.'
}
for ($i = 0; $i -lt $fileBytes.Length; $i++) {
    if ($stableIdentity.Content[$i] -ne $fileBytes[$i]) {
        throw 'Raw performance observations bytes changed during atomic publish.'
    }
}

$evidenceClass = if ($Synthetic) { 'SyntheticVerifierSelftest' } else { 'PackagedCompatibilityRawPerformance' }

[pscustomobject][ordered]@{
    EvidenceClassification = $evidenceClass
    RawSourcePath = $fullDestinationPath
    RelativePath = $destinationRelative
    Bytes = [long]$stableIdentity.Bytes
    FileSha256 = [string]$stableIdentity.Sha256
    CanonicalSha256 = [string]$canonicalSha
    Orders = $canonicalOrders
    SoakBins = $canonicalSoakBins
    RawObservations = $rawObservationsObject
}
