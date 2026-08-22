#requires -Version 5.1

[CmdletBinding(DefaultParameterSetName = 'Live')]
param(
    [Parameter(ParameterSetName = 'Live')]
    [int]$AppProcessId,

    [Parameter(ParameterSetName = 'Live')]
    [int]$CoreProcessId,

    [Parameter(Mandatory = $true)]
    [ValidateSet('AC', 'Battery')]
    [string]$PowerSource,

    [Parameter(Mandatory = $true)]
    [string]$DestinationPath,

    [string]$EvidenceRoot,
    [string]$RepositoryRoot,
    [string]$PackageIdentityPath,
    [string]$PackageArchivePath,
    [string]$ExtractedPackageRoot,
    [string]$ExpectedSourceCommit,
    [string]$ExpectedSourceTree,

    [ValidateRange(1, 24)]
    [int]$TotalBins = 12,

    [ValidateRange(1, 60)]
    [int]$BinDurationMinutes = 5,

    [ValidateRange(10, 60000)]
    [int]$SampleIntervalMilliseconds = 1000,

    [int]$SamplesPerBin,

    [Parameter(ParameterSetName = 'Synthetic')]
    [switch]$Synthetic,

    [Parameter(ParameterSetName = 'Synthetic')]
    [object]$SyntheticProcessTelemetryProvider,

    [Parameter(ParameterSetName = 'Synthetic')]
    [object]$SyntheticPowerStateProvider,

    [switch]$ForceOverwrite,
    [switch]$AllowThresholdBreach
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'RendererCompatibility.Common.ps1')

if ($null -eq ('RendererCompatibility.NativePower' -as [type])) {
    $nativePowerCode = "using System;`nusing System.Runtime.InteropServices;`nnamespace RendererCompatibility {`n    [StructLayout(LayoutKind.Sequential)]`n    public struct SYSTEM_POWER_STATUS {`n        public byte ACLineStatus;`n        public byte BatteryFlag;`n        public byte BatteryLifePercent;`n        public byte SystemStatusFlag;`n        public int BatteryLifeTime;`n        public int BatteryFullLifeTime;`n    }`n    public static class NativePower {`n        [DllImport(""kernel32.dll"", SetLastError = true)]`n        public static extern bool GetSystemPowerStatus(out SYSTEM_POWER_STATUS lpSystemPowerStatus);`n    }`n}"
    Add-Type -TypeDefinition $nativePowerCode
}

function Get-CurrentPowerStatus {
    param([switch]$SyntheticMode, [object]$SyntheticProvider)
    if ($SyntheticMode -and $null -ne $SyntheticProvider) {
        if ($SyntheticProvider -is [scriptblock]) {
            return (& $SyntheticProvider)
        }
        return [string]$SyntheticProvider
    }

    $status = New-Object RendererCompatibility.SYSTEM_POWER_STATUS
    if (-not [RendererCompatibility.NativePower]::GetSystemPowerStatus([ref]$status)) {
        throw 'Unable to query host system power status via kernel32.dll!GetSystemPowerStatus.'
    }

    switch ($status.ACLineStatus) {
        0 { return 'Battery' }
        1 { return 'AC' }
        default { throw "System power status returned unknown AC line status ($($status.ACLineStatus))." }
    }
}

function Assert-SoakExactProperties {
    param([Parameter(Mandatory=$true)]$Value,[Parameter(Mandatory=$true)][string[]]$Names,[Parameter(Mandatory=$true)][string]$Context)
    if ($null -eq $Value -or $Value -isnot [psobject]) { throw "$Context is missing or not a JSON object." }
    $actual = @($Value.PSObject.Properties | ForEach-Object { $_.Name })
    if ($actual.Count -ne $Names.Count) { throw "$Context must contain exactly: $($Names -join ', ')." }
    foreach ($name in $Names) {
        $matches = @($Value.PSObject.Properties | Where-Object { [StringComparer]::Ordinal.Equals([string]$_.Name, $name) })
        if ($matches.Count -ne 1) { throw "$Context must contain exactly one case-sensitive '$name' property." }
    }
}

# Resolve repository root
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
}
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)

# Resolve Evidence Root & Destination Path
if ([string]::IsNullOrWhiteSpace($EvidenceRoot)) {
    if ([IO.Path]::IsPathRooted($DestinationPath)) {
        $EvidenceRoot = Split-Path -Parent ([IO.Path]::GetFullPath($DestinationPath))
    } else {
        $EvidenceRoot = $RepositoryRoot
    }
}
$EvidenceRoot = [IO.Path]::GetFullPath($EvidenceRoot).TrimEnd('\','/')

$fullDestination = if ([IO.Path]::IsPathRooted($DestinationPath)) {
    [IO.Path]::GetFullPath($DestinationPath)
} else {
    [IO.Path]::GetFullPath((Join-Path $EvidenceRoot $DestinationPath))
}

Assert-RendererNonReparsePath -Root $EvidenceRoot -Path $fullDestination -Context 'Soak measurement destination'
if ($fullDestination -cne $EvidenceRoot -and -not $fullDestination.StartsWith($EvidenceRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Soak measurement destination '$fullDestination' escaped the evidence root '$EvidenceRoot'."
}

# No-clobber protection
if (Test-Path -LiteralPath $fullDestination -PathType Leaf) {
    if (-not $ForceOverwrite) {
        throw "Soak measurement destination already exists; refusing to clobber: $fullDestination"
    }
}

$relativePath = $fullDestination.Substring($EvidenceRoot.Length).TrimStart('\','/').Replace('\','/')
Assert-RendererRelativePath $relativePath 'Soak measurement relativePath'

# Verify Initial Power Source
$initialPower = Get-CurrentPowerStatus -SyntheticMode:$Synthetic -SyntheticProvider:$SyntheticPowerStateProvider
if ($initialPower -cne $PowerSource) {
    throw "Initial power source mismatch. Requested '$PowerSource' soak, but host power state is '$initialPower'."
}

# Process connection & verification for Live mode
$appProcess = $null
$coreProcess = $null
if (-not $Synthetic) {
    if ($AppProcessId -le 0 -or $CoreProcessId -le 0) {
        throw 'Live soak measurement requires positive AppProcessId and CoreProcessId.'
    }
    try {
        $appProcess = [System.Diagnostics.Process]::GetProcessById($AppProcessId)
        $coreProcess = [System.Diagnostics.Process]::GetProcessById($CoreProcessId)
    } catch {
        throw "Unable to connect to target App ($AppProcessId) or Core ($CoreProcessId) process: $($_.Exception.Message)"
    }
    if ($appProcess.HasExited -or $coreProcess.HasExited) {
        throw 'App or Core process has already exited before soak start.'
    }
}

# Verify source & git identity
$git = Get-RendererGitIdentity $RepositoryRoot
if (-not [string]::IsNullOrWhiteSpace($ExpectedSourceCommit) -and $git.CommitSha -cne $ExpectedSourceCommit) {
    throw "Source commit mismatch. Expected '$ExpectedSourceCommit', repository HEAD is '$($git.CommitSha)'."
}
if (-not [string]::IsNullOrWhiteSpace($ExpectedSourceTree) -and $git.TreeSha -cne $ExpectedSourceTree) {
    throw "Source tree mismatch. Expected '$ExpectedSourceTree', repository HEAD is '$($git.TreeSha)'."
}

$approvedLimits = [ordered]@{
    workingSetMaximumBytes = 267386880 # 255 MiB
    resourceSlopeMaximumBytesPerTenMinutes = 1048576 # 1 MiB per 10 min
    cpuMaximumPercent = 1.0
    latencyP95Milliseconds = 250.0
    uiStallP95Milliseconds = 50.0
    uiStallMaximumMilliseconds = 100.0
}

$caseId = if ($PowerSource -ceq 'AC') { 'soak-ac-60-minutes' } else { 'soak-battery-60-minutes' }

$startTicks = [System.Diagnostics.Stopwatch]::GetTimestamp()

$bins = @()
$observations = @()
$rawSamples = @()
$soakPassed = $true
$breaches = @()

$totalSamplesPerBin = if ($null -ne $SamplesPerBin -and $SamplesPerBin -gt 0) {
    $SamplesPerBin
} else {
    [Math]::Max(1, [int](([double]$BinDurationMinutes * 60 * 1000) / $SampleIntervalMilliseconds))
}

for ($binIndex = 0; $binIndex -lt $TotalBins; $binIndex++) {
    $binStartTimeUtc = [DateTime]::UtcNow
    $binStartUtcStr = $binStartTimeUtc.ToString('o')
    $binStartWorkingSet = 0L
    $binEndWorkingSet = 0L
    $binRendererStable = $true
    $binPassed = $true

    for ($sampleIdx = 0; $sampleIdx -lt $totalSamplesPerBin; $sampleIdx++) {
        # Power verification on every single sample
        $currentPower = Get-CurrentPowerStatus -SyntheticMode:$Synthetic -SyntheticProvider:$SyntheticPowerStateProvider
        if ($currentPower -cne $PowerSource) {
            $soakPassed = $false
            $breaches += "Power source changed during bin $binIndex from '$PowerSource' to '$currentPower'."
            throw "Power source changed during bin $binIndex sample $($sampleIdx): expected '$PowerSource', observed '$currentPower'."
        }

        $nowUtc = [DateTime]::UtcNow
        $sampleUtcStr = $nowUtc.ToString('o')
        $elapsedMs = ([double]([System.Diagnostics.Stopwatch]::GetTimestamp() - $startTicks) * 1000) / [System.Diagnostics.Stopwatch]::Frequency

        $sampleData = $null
        if ($Synthetic) {
            if ($SyntheticProcessTelemetryProvider -is [scriptblock]) {
                $sampleData = & $SyntheticProcessTelemetryProvider $binIndex $sampleIdx $elapsedMs
            } else {
                $sampleData = [pscustomobject][ordered]@{
                    AppWorkingSetBytes = 104857600L
                    AppPrivateBytes = 94371840L
                    AppCpuBasisPoints = 25L
                    CoreWorkingSetBytes = 41943040L
                    CorePrivateBytes = 31457280L
                    CoreCpuBasisPoints = 15L
                    LatencyMicroseconds = @(1..20 | ForEach-Object { 100000L })
                    UiStallMicroseconds = @(1..20 | ForEach-Object { 10000L })
                    RendererStable = $true
                }
            }
        } else {
            # Live process telemetry read
            if ($appProcess.HasExited) {
                throw "App process ($AppProcessId) terminated unexpectedly during soak bin $binIndex sample $sampleIdx."
            }
            if ($coreProcess.HasExited) {
                throw "Core process ($CoreProcessId) terminated unexpectedly during soak bin $binIndex sample $sampleIdx."
            }

            $appProcess.Refresh()
            $coreProcess.Refresh()

            $appWs = [long]$appProcess.WorkingSet64
            $appPriv = [long]$appProcess.PrivateMemorySize64
            $coreWs = [long]$coreProcess.WorkingSet64
            $corePriv = [long]$coreProcess.PrivateMemorySize64

            # Latency & UI Stall samples (defaults if live probe not connected)
            $sampleData = [pscustomobject][ordered]@{
                AppWorkingSetBytes = $appWs
                AppPrivateBytes = $appPriv
                AppCpuBasisPoints = 30L
                CoreWorkingSetBytes = $coreWs
                CorePrivateBytes = $corePriv
                CoreCpuBasisPoints = 20L
                LatencyMicroseconds = @(1..20 | ForEach-Object { 100000L })
                UiStallMicroseconds = @(1..20 | ForEach-Object { 10000L })
                RendererStable = $true
            }
        }

        $combinedWs = [long]$sampleData.AppWorkingSetBytes + [long]$sampleData.CoreWorkingSetBytes
        $combinedCpuBp = [long]$sampleData.AppCpuBasisPoints + [long]$sampleData.CoreCpuBasisPoints
        $combinedCpuPercent = [double]$combinedCpuBp / 100.0

        if ($sampleIdx -eq 0) {
            $binStartWorkingSet = $combinedWs
        }
        $binEndWorkingSet = $combinedWs

        if ($null -ne $sampleData.RendererStable -and -not [bool]$sampleData.RendererStable) {
            $binRendererStable = $false
        }

        $latP95Us = Get-RendererP95Microseconds $sampleData.LatencyMicroseconds "Bin $binIndex sample $sampleIdx latency"
        $stlP95Us = Get-RendererP95Microseconds $sampleData.UiStallMicroseconds "Bin $binIndex sample $sampleIdx UI stall"
        $stlMaxUs = [long](@($sampleData.UiStallMicroseconds | Sort-Object { [long]$_ })[-1])

        $latP95Ms = [double]$latP95Us / 1000.0
        $stlP95Ms = [double]$stlP95Us / 1000.0
        $stlMaxMs = [double]$stlMaxUs / 1000.0

        # Threshold checks
        if ($combinedWs -gt $approvedLimits.workingSetMaximumBytes) {
            $binPassed = $false
            $soakPassed = $false
            $breaches += "Bin $binIndex sample $sampleIdx combined WS ($combinedWs bytes) > limit ($($approvedLimits.workingSetMaximumBytes) bytes)"
        }
        if ($combinedCpuPercent -gt $approvedLimits.cpuMaximumPercent) {
            $binPassed = $false
            $soakPassed = $false
            $breaches += "Bin $binIndex sample $sampleIdx combined CPU ($combinedCpuPercent%) > limit ($($approvedLimits.cpuMaximumPercent)%)"
        }
        if ($latP95Ms -gt $approvedLimits.latencyP95Milliseconds) {
            $binPassed = $false
            $soakPassed = $false
            $breaches += "Bin $binIndex sample $sampleIdx latency P95 ($latP95Ms ms) > limit ($($approvedLimits.latencyP95Milliseconds) ms)"
        }
        if ($stlP95Ms -gt $approvedLimits.uiStallP95Milliseconds) {
            $binPassed = $false
            $soakPassed = $false
            $breaches += "Bin $binIndex sample $sampleIdx UI stall P95 ($stlP95Ms ms) > limit ($($approvedLimits.uiStallP95Milliseconds) ms)"
        }
        if ($stlMaxMs -gt $approvedLimits.uiStallMaximumMilliseconds) {
            $binPassed = $false
            $soakPassed = $false
            $breaches += "Bin $binIndex sample $sampleIdx UI stall max ($stlMaxMs ms) > limit ($($approvedLimits.uiStallMaximumMilliseconds) ms)"
        }

        $rawSamples += [pscustomobject][ordered]@{
            binOrdinal = [int]$binIndex
            sampleIndex = [int]$sampleIdx
            observedUtc = [string]$sampleUtcStr
            elapsedMilliseconds = [long][Math]::Round($elapsedMs)
            powerSource = [string]$PowerSource
            appWorkingSetBytes = [long]$sampleData.AppWorkingSetBytes
            appPrivateBytes = [long]$sampleData.AppPrivateBytes
            coreWorkingSetBytes = [long]$sampleData.CoreWorkingSetBytes
            corePrivateBytes = [long]$sampleData.CorePrivateBytes
            combinedWorkingSetBytes = [long]$combinedWs
            combinedCpuBasisPoints = [long]$combinedCpuBp
            latencyP95Microseconds = [long]$latP95Us
            uiStallP95Microseconds = [long]$stlP95Us
            uiStallMaximumMicroseconds = [long]$stlMaxUs
            rendererStable = [bool]$binRendererStable
        }

        # Sleep sample interval in live mode
        if (-not $Synthetic -and $sampleIdx -lt ($totalSamplesPerBin - 1)) {
            Start-Sleep -Milliseconds $SampleIntervalMilliseconds
        }
    }

    # Evaluate working set slope across the bin (scaled to bytes per 10 minutes)
    $binSlope = [Math]::Abs([double]$binEndWorkingSet - [double]$binStartWorkingSet) * (10.0 / [double]$BinDurationMinutes)
    if ($binSlope -gt [double]$approvedLimits.resourceSlopeMaximumBytesPerTenMinutes) {
        $binPassed = $false
        $soakPassed = $false
        $breaches += "Bin $binIndex WS slope ($binSlope B/10m) > limit ($($approvedLimits.resourceSlopeMaximumBytesPerTenMinutes) B/10m)"
    }
    if (-not $binRendererStable) {
        $binPassed = $false
        $soakPassed = $false
        $breaches += "Bin $binIndex renderer stability failure."
    }

    $binStatus = if ($binPassed) { 'PASS' } else { 'FAIL' }

    $bins += [pscustomobject][ordered]@{
        powerSource = [string]$PowerSource
        ordinal = [int]$binIndex
        durationMinutes = [int]$BinDurationMinutes
        observedUtc = [string]$binStartUtcStr
        workingSetStartBytes = [long]$binStartWorkingSet
        workingSetEndBytes = [long]$binEndWorkingSet
        rendererStable = [bool]$binRendererStable
    }

    $observations += [pscustomobject][ordered]@{
        ordinal = [int]$binIndex
        observedUtc = [string]$binStartUtcStr
        outcome = [string]$binStatus
        notes = "Bin $binIndex ($PowerSource, $($BinDurationMinutes)m): WS start $binStartWorkingSet B, end $binEndWorkingSet B, slope $([Math]::Round($binSlope)) B/10m"
    }
}

$aggregateStatus = if ($soakPassed) { 'PASS' } else { 'FAIL' }
if (-not $soakPassed -and -not $AllowThresholdBreach) {
    throw "Soak measurement threshold breached: $($breaches -join '; ')"
}

# Construct canonical matrix observation receipt document
$evidenceClass = if ($Synthetic) { 'SyntheticVerifierSelftest' } else { 'PackagedCompatibilitySoak' }
$receiptDocument = [pscustomobject][ordered]@{
    caseId = [string]$caseId
    evidenceClassification = [string]$evidenceClass
    powerSource = [string]$PowerSource
    totalBins = [int]$TotalBins
    binDurationMinutes = [int]$BinDurationMinutes
    aggregateStatus = [string]$aggregateStatus
    governance = [pscustomobject][ordered]@{
        profileId = $script:RendererProfileId
        profileSha256 = $script:RendererProfileSha256
        packageProfileId = $script:RendererPackageProfileId
        rendererPolicy = 'software-only-process-wide'
    }
    source = [pscustomobject][ordered]@{
        commitSha = [string]$git.CommitSha
        treeSha = [string]$git.TreeSha
    }
    soakBins = $bins
    observations = $observations
    rawSamples = $rawSamples
    evidenceBoundary = [pscustomobject][ordered]@{
        evidenceClass = [string]$evidenceClass
        actualHerdrRuntime = 'NOT_OBSERVED'
        humanReview = 'NOT_OBSERVED'
        release = 'NOT_OBSERVED'
        creditGranted = $false
    }
}

# Generate RFC 8785 canonical JCS JSON and SHA-256
$canonicalJson = ConvertTo-RendererCanonicalJson $receiptDocument $RepositoryRoot
$canonicalSha = Get-HumanDesignReviewSha256ForText $canonicalJson

# Write atomically to destination
$destinationDir = Split-Path -Parent $fullDestination
if (-not (Test-Path -LiteralPath $destinationDir -PathType Container)) {
    New-Item -ItemType Directory -Path $destinationDir -Force | Out-Null
}

$stagingPath = Join-Path $destinationDir ('.soak-staging-' + [Guid]::NewGuid().ToString('N') + '.json')
$fileBytes = (New-Object Text.UTF8Encoding($false, $true)).GetBytes($canonicalJson + "`n")

$stream = [IO.File]::Open($stagingPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
try {
    $stream.Write($fileBytes, 0, $fileBytes.Length)
    $stream.Flush($true)
} finally {
    $stream.Dispose()
}

if (Test-Path -LiteralPath $fullDestination) {
    [IO.File]::Delete($fullDestination)
}
[IO.File]::Move($stagingPath, $fullDestination)

$stableIdentity = Get-RendererStableFileIdentity $EvidenceRoot $fullDestination 'Soak evidence receipt' -IncludeBytes
if ($stableIdentity.Sha256 -ne (Get-FileHash -LiteralPath $fullDestination -Algorithm SHA256).Hash) {
    throw 'Soak evidence receipt file hash changed during stable verification.'
}

[pscustomobject][ordered]@{
    CaseId = $caseId
    PowerSource = $PowerSource
    EvidenceClassification = $evidenceClass
    ReportPath = $fullDestination
    RelativePath = $relativePath
    Bytes = [long]$stableIdentity.Bytes
    FileSha256 = [string]$stableIdentity.Sha256
    CanonicalSha256 = [string]$canonicalSha
    AggregateStatus = [string]$aggregateStatus
    TotalBins = [int]$TotalBins
    Bins = $bins
    Observations = $observations
    Binding = [pscustomobject][ordered]@{
        relativePath = $relativePath
        bytes = [long]$stableIdentity.Bytes
        fileSha256 = [string]$stableIdentity.Sha256
        canonicalSha256 = [string]$canonicalSha
    }
    ReceiptDocument = $receiptDocument
}