#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
    $RawObservations,

    [Parameter(Mandatory = $true)]
    [string]$DestinationPath,

    [string]$EvidenceRoot,

    [string]$RepositoryRoot,

    [object]$OwnerNumericLimits,

    [switch]$AllowThresholdBreach
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'RendererCompatibility.Common.ps1')

function Assert-PerfReceiptExactProperties {
    param([Parameter(Mandatory=$true)]$Value,[Parameter(Mandatory=$true)][string[]]$Names,[Parameter(Mandatory=$true)][string]$Context)
    if ($null -eq $Value -or $Value -isnot [psobject]) { throw "$Context is missing or not a JSON object." }
    $actual = @($Value.PSObject.Properties | ForEach-Object { $_.Name })
    if ($actual.Count -ne $Names.Count) { throw "$Context must contain exactly: $($Names -join ', ')." }
    foreach ($name in $Names) {
        $matches = @($Value.PSObject.Properties | Where-Object { [StringComparer]::Ordinal.Equals([string]$_.Name, $name) })
        if ($matches.Count -ne 1) { throw "$Context must contain exactly one case-sensitive '$name' property." }
    }
}

function Get-ApprovedLimits {
    param($InputLimits)
    if ($null -ne $InputLimits) {
        $limitNames = @(
            'cpuMaximumPercent','eventToWpfP95Milliseconds','cpuRegressionMaximumPercent',
            'cpuRegressionMaximumPercentagePoints','latencyRegressionMaximumPercent',
            'uiStallP95Milliseconds','uiStallMaximumMilliseconds','soakAcDurationMinutes',
            'soakBatteryDurationMinutes','soakBinMinutes','workingSetMaximumBytes',
            'resourceSlopeMaximumBytesPerTenMinutes'
        )
        Assert-PerfReceiptExactProperties $InputLimits (@('status','approvalReference') + $limitNames) 'Owner numeric limits'
        if ($InputLimits.status -cne 'APPROVED') {
            throw 'Owner numeric limits must be APPROVED to generate a candidate performance receipt.'
        }
        if ($InputLimits.approvalReference -cne $script:RendererAuthorizedApprovalReference) {
            throw 'Owner numeric limits do not bind REC-ALL v2.'
        }
        $expectedLimits = [ordered]@{
            cpuMaximumPercent = 1
            eventToWpfP95Milliseconds = 250
            cpuRegressionMaximumPercent = 10
            cpuRegressionMaximumPercentagePoints = 0.5
            latencyRegressionMaximumPercent = 10
            uiStallP95Milliseconds = 50
            uiStallMaximumMilliseconds = 100
            soakAcDurationMinutes = 60
            soakBatteryDurationMinutes = 60
            soakBinMinutes = 5
            workingSetMaximumBytes = 267386880
            resourceSlopeMaximumBytesPerTenMinutes = 1048576
        }
        foreach ($n in $limitNames) {
            Assert-RendererFiniteNumber $InputLimits.$n "Owner numeric limit $n" 0 ([double]::MaxValue) -ExclusiveMinimum
            if ([decimal]$InputLimits.$n -ne [decimal]($expectedLimits[$n])) {
                throw "Owner numeric limit $n does not equal REC-ALL v2."
            }
        }
        foreach ($n in @('workingSetMaximumBytes','resourceSlopeMaximumBytesPerTenMinutes')) {
            Assert-RendererPositiveInteger $InputLimits.$n "Owner numeric limit $n"
        }
        return $InputLimits
    }

    return [pscustomobject][ordered]@{
        status = 'APPROVED'
        approvalReference = $script:RendererAuthorizedApprovalReference
        cpuMaximumPercent = 1
        eventToWpfP95Milliseconds = 250
        cpuRegressionMaximumPercent = 10
        cpuRegressionMaximumPercentagePoints = 0.5
        latencyRegressionMaximumPercent = 10
        uiStallP95Milliseconds = 50
        uiStallMaximumMilliseconds = 100
        soakAcDurationMinutes = 60
        soakBatteryDurationMinutes = 60
        soakBinMinutes = 5
        workingSetMaximumBytes = 267386880
        resourceSlopeMaximumBytesPerTenMinutes = 1048576
    }
}

function Assert-SampleProperties {
    param($Sample, [string]$Context)
    Assert-PerfReceiptExactProperties $Sample @('cpuBasisPoints','workingSetMaximumBytes','latencyMicroseconds','uiStallMicroseconds') $Context
    Assert-RendererNonnegativeInteger $Sample.cpuBasisPoints "$Context cpuBasisPoints"
    Assert-RendererNonnegativeInteger $Sample.workingSetMaximumBytes "$Context workingSetMaximumBytes"
    
    $latencies = @($Sample.latencyMicroseconds)
    if ($latencies.Count -ne 20) {
        throw "$Context latencyMicroseconds must contain exactly 20 raw observations; found $($latencies.Count)."
    }
    foreach ($lat in $latencies) {
        Assert-RendererNonnegativeInteger $lat "$Context latency observation"
    }

    $stalls = @($Sample.uiStallMicroseconds)
    if ($stalls.Count -ne 20) {
        throw "$Context uiStallMicroseconds must contain exactly 20 raw observations; found $($stalls.Count)."
    }
    foreach ($stl in $stalls) {
        Assert-RendererNonnegativeInteger $stl "$Context uiStall observation"
    }
}

function Assert-RepetitionProperties {
    param($Repetition, [int]$ExpectedOrdinal, [string]$Context, [switch]$IsWarmup)
    Assert-PerfReceiptExactProperties $Repetition @('ordinal','observedUtc','a','b') $Context
    Assert-RendererNonnegativeInteger $Repetition.ordinal "$Context ordinal"
    if (-not $IsWarmup -and [long]$Repetition.ordinal -ne $ExpectedOrdinal) {
        throw "$Context ordinal must equal $ExpectedOrdinal; found $($Repetition.ordinal)."
    }
    Assert-RendererUtc $Repetition.observedUtc "$Context observedUtc"
    Assert-SampleProperties $Repetition.a "$Context mode A sample"
    Assert-SampleProperties $Repetition.b "$Context mode B sample"
}

# Resolve repository root
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
}
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)

# Parse raw observations input
$rawObj = $RawObservations
if ($rawObj -is [string]) {
    $rawStr = [string]$rawObj
    if (Test-Path -LiteralPath $rawStr -PathType Leaf) {
        $rawBytes = [IO.File]::ReadAllBytes([IO.Path]::GetFullPath($rawStr))
        if ($rawBytes.Length -ge 3 -and $rawBytes[0] -eq 0xEF -and $rawBytes[1] -eq 0xBB -and $rawBytes[2] -eq 0xBF) {
            throw 'Raw observations file must not contain a UTF-8 BOM.'
        }
        $rawJson = (New-Object Text.UTF8Encoding($false, $true)).GetString($rawBytes)
        $rawObj = ConvertFrom-StrictHumanDesignReviewJson -Json $rawJson -Description 'Raw performance observations file'
        if ($PSVersionTable.PSVersion.Major -ge 7 -and (Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) {
            $rawObj = $rawJson | ConvertFrom-Json -DateKind String
        }
    } elseif ($rawStr.TrimStart().StartsWith('{')) {
        $rawObj = ConvertFrom-StrictHumanDesignReviewJson -Json $rawStr -Description 'Raw performance observations JSON string'
        if ($PSVersionTable.PSVersion.Major -ge 7 -and (Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) {
            $rawObj = $rawStr | ConvertFrom-Json -DateKind String
        }
    } else {
        throw "Raw observations string is neither an existing file path nor valid JSON: $rawStr"
    }
}

if ($null -eq $rawObj -or $rawObj -isnot [psobject]) {
    throw 'Raw performance observations must be a non-null JSON object.'
}

# Validate Destination Path and Evidence Root
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

Assert-RendererNonReparsePath -Root $EvidenceRoot -Path $fullDestination -Context 'Performance evidence receipt destination'
if ($fullDestination -cne $EvidenceRoot -and -not $fullDestination.StartsWith($EvidenceRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Performance evidence receipt destination '$fullDestination' escaped the evidence root '$EvidenceRoot'."
}

$relativePath = $fullDestination.Substring($EvidenceRoot.Length).TrimStart('\','/').Replace('\','/')
Assert-RendererRelativePath $relativePath 'Performance evidence receipt relativePath'

# Validate top-level properties of raw observations
Assert-PerfReceiptExactProperties $rawObj @('orders','soakBins') 'Raw performance observations'

$limits = Get-ApprovedLimits $OwnerNumericLimits

# Process and validate orders
$rawOrders = @($rawObj.orders)
if ($rawOrders.Count -ne 2) {
    throw "Raw performance observations must contain exactly 2 orders (AB, then BA); found $($rawOrders.Count)."
}

$expectedOrders = @('AB', 'BA')
$canonicalOrders = @()
$passed = $true
$breaches = @()

for ($oi = 0; $oi -lt 2; $oi++) {
    $orderItem = $rawOrders[$oi]
    $expectedOrder = $expectedOrders[$oi]

    $orderProps = @($orderItem.PSObject.Properties | ForEach-Object { $_.Name })
    if (-not ($orderProps -ccontains 'order') -or -not ($orderProps -ccontains 'repetitions')) {
        throw "Order $oi missing 'order' or 'repetitions' property."
    }

    if ([string]$orderItem.order -cne $expectedOrder) {
        throw "Order $oi must be '$expectedOrder'; found '$($orderItem.order)'."
    }

    $warmupFound = $null
    $measuredReps = $null
    if ($orderProps -ccontains 'warmup' -and $null -ne $orderItem.warmup) {
        $wArray = @($orderItem.warmup)
        if ($wArray.Count -ne 1) {
            throw "Order $expectedOrder warmup must contain exactly 1 warmup repetition; found $($wArray.Count)."
        }
        $warmupFound = $wArray[0]
        $measuredReps = @($orderItem.repetitions)
    } elseif ($orderProps -ccontains 'warmupRepetition' -and $null -ne $orderItem.warmupRepetition) {
        $warmupFound = $orderItem.warmupRepetition
        $measuredReps = @($orderItem.repetitions)
    } elseif ($orderProps -ccontains 'warmupRepetitions' -and $null -ne $orderItem.warmupRepetitions) {
        $wArray = @($orderItem.warmupRepetitions)
        if ($wArray.Count -ne 1) {
            throw "Order $expectedOrder warmupRepetitions must contain exactly 1 warmup repetition; found $($wArray.Count)."
        }
        $warmupFound = $wArray[0]
        $measuredReps = @($orderItem.repetitions)
    } else {
        $allReps = @($orderItem.repetitions)
        if ($allReps.Count -eq 6) {
            $warmupFound = $allReps[0]
            $measuredReps = @($allReps | Select-Object -Skip 1)
        } else {
            throw "Order $expectedOrder must supply exactly 1 warmup repetition before the 5 measured repetitions."
        }
    }

    if ($null -eq $warmupFound) {
        throw "Order $expectedOrder is missing required 1 warmup repetition."
    }

    Assert-RepetitionProperties $warmupFound 0 "Order $expectedOrder warmup repetition" -IsWarmup

    $reps = $measuredReps
    if ($reps.Count -ne 5) {
        throw "Order $expectedOrder must contain exactly 5 measured raw repetitions; found $($reps.Count)."
    }

    $canonicalReps = @()
    for ($ri = 0; $ri -lt 5; $ri++) {
        $rep = $reps[$ri]
        Assert-RepetitionProperties $rep $ri "Order $expectedOrder measured repetition $ri"

        $derived = @{}
        foreach ($modeName in @('a', 'b')) {
            $sample = $rep.$modeName
            $latP95 = Get-RendererP95Microseconds $sample.latencyMicroseconds "Order $expectedOrder repetition $ri mode $modeName latency"
            $stlP95 = Get-RendererP95Microseconds $sample.uiStallMicroseconds "Order $expectedOrder repetition $ri mode $modeName UI stall"
            $stlMax = [long](@($sample.uiStallMicroseconds | Sort-Object { [long]$_ })[-1])

            $derived[$modeName] = [pscustomobject]@{
                Cpu = [double]$sample.cpuBasisPoints / 100
                WorkingSet = [long]$sample.workingSetMaximumBytes
                LatencyP95 = [double]$latP95 / 1000
                StallP95 = [double]$stlP95 / 1000
                StallMaximum = [double]$stlMax / 1000
            }
        }

        $a = $derived.a
        $b = $derived.b
        $cpuDelta = $b.Cpu - $a.Cpu
        $cpuPercent = if ($a.Cpu -gt 0) { 100 * $cpuDelta / $a.Cpu } else { [double]::PositiveInfinity }
        $latencyPercent = if ($a.LatencyP95 -gt 0) { 100 * ($b.LatencyP95 - $a.LatencyP95) / $a.LatencyP95 } else { [double]::PositiveInfinity }

        if ($b.Cpu -gt [double]$limits.cpuMaximumPercent) {
            $passed = $false
            $breaches += "Order $expectedOrder rep $ri mode B CPU ($($b.Cpu)%) > maximum ($($limits.cpuMaximumPercent)%)"
        }
        if ($cpuDelta -gt [double]$limits.cpuRegressionMaximumPercentagePoints) {
            $passed = $false
            $breaches += "Order $expectedOrder rep $ri CPU delta ($($cpuDelta) pp) > maximum ($($limits.cpuRegressionMaximumPercentagePoints) pp)"
        }
        if ($cpuPercent -gt [double]$limits.cpuRegressionMaximumPercent) {
            $passed = $false
            $breaches += "Order $expectedOrder rep $ri CPU relative regression ($($cpuPercent)%) > maximum ($($limits.cpuRegressionMaximumPercent)%)"
        }
        if ($b.LatencyP95 -gt [double]$limits.eventToWpfP95Milliseconds) {
            $passed = $false
            $breaches += "Order $expectedOrder rep $ri mode B Latency P95 ($($b.LatencyP95) ms) > maximum ($($limits.eventToWpfP95Milliseconds) ms)"
        }
        if ($latencyPercent -gt [double]$limits.latencyRegressionMaximumPercent) {
            $passed = $false
            $breaches += "Order $expectedOrder rep $ri Latency relative regression ($($latencyPercent)%) > maximum ($($limits.latencyRegressionMaximumPercent)%)"
        }
        if ($b.StallP95 -gt [double]$limits.uiStallP95Milliseconds) {
            $passed = $false
            $breaches += "Order $expectedOrder rep $ri mode B UI Stall P95 ($($b.StallP95) ms) > maximum ($($limits.uiStallP95Milliseconds) ms)"
        }
        if ($b.StallMaximum -gt [double]$limits.uiStallMaximumMilliseconds) {
            $passed = $false
            $breaches += "Order $expectedOrder rep $ri mode B UI Stall Maximum ($($b.StallMaximum) ms) > maximum ($($limits.uiStallMaximumMilliseconds) ms)"
        }
        if ($b.WorkingSet -gt [long]$limits.workingSetMaximumBytes) {
            $passed = $false
            $breaches += "Order $expectedOrder rep $ri mode B Working Set ($($b.WorkingSet) bytes) > maximum ($($limits.workingSetMaximumBytes) bytes)"
        }
        if ($a.WorkingSet -gt [long]$limits.workingSetMaximumBytes) {
            $passed = $false
            $breaches += "Order $expectedOrder rep $ri mode A Working Set ($($a.WorkingSet) bytes) > maximum ($($limits.workingSetMaximumBytes) bytes)"
        }

        $canonicalReps += [pscustomobject][ordered]@{
            ordinal = [int]$ri
            observedUtc = [string]$rep.observedUtc
            a = [pscustomobject][ordered]@{
                cpuBasisPoints = [long]$rep.a.cpuBasisPoints
                workingSetMaximumBytes = [long]$rep.a.workingSetMaximumBytes
                latencyMicroseconds = @($rep.a.latencyMicroseconds | ForEach-Object { [long]$_ })
                uiStallMicroseconds = @($rep.a.uiStallMicroseconds | ForEach-Object { [long]$_ })
            }
            b = [pscustomobject][ordered]@{
                cpuBasisPoints = [long]$rep.b.cpuBasisPoints
                workingSetMaximumBytes = [long]$rep.b.workingSetMaximumBytes
                latencyMicroseconds = @($rep.b.latencyMicroseconds | ForEach-Object { [long]$_ })
                uiStallMicroseconds = @($rep.b.uiStallMicroseconds | ForEach-Object { [long]$_ })
            }
        }
    }

    $canonicalOrders += [pscustomobject][ordered]@{
        order = $expectedOrder
        repetitions = $canonicalReps
    }
}

$rawBins = @($rawObj.soakBins)
if ($rawBins.Count -ne 24) {
    throw "Raw performance observations must contain exactly 24 five-minute soak bins (12 AC then 12 Battery); found $($rawBins.Count)."
}

$canonicalBins = @()
for ($bi = 0; $bi -lt 24; $bi++) {
    $bin = $rawBins[$bi]
    Assert-PerfReceiptExactProperties $bin @('powerSource','ordinal','durationMinutes','observedUtc','workingSetStartBytes','workingSetEndBytes','rendererStable') "Soak bin $bi"

    $expectedPower = if ($bi -lt 12) { 'AC' } else { 'Battery' }
    $expectedOrdinal = $bi % 12

    if ([string]$bin.powerSource -cne $expectedPower) {
        throw "Soak bin $bi powerSource must be '$expectedPower'; found '$($bin.powerSource)'."
    }
    Assert-RendererNonnegativeInteger $bin.ordinal "Soak bin $bi ordinal"
    if ([long]$bin.ordinal -ne $expectedOrdinal) {
        throw "Soak bin $bi ordinal must be $expectedOrdinal; found $($bin.ordinal)."
    }
    Assert-RendererPositiveInteger $bin.durationMinutes "Soak bin $bi durationMinutes"
    if ([long]$bin.durationMinutes -ne 5) {
        throw "Soak bin $bi durationMinutes must be 5; found $($bin.durationMinutes)."
    }
    Assert-RendererUtc $bin.observedUtc "Soak bin $bi observedUtc"
    Assert-RendererNonnegativeInteger $bin.workingSetStartBytes "Soak bin $bi workingSetStartBytes"
    Assert-RendererNonnegativeInteger $bin.workingSetEndBytes "Soak bin $bi workingSetEndBytes"
    Assert-RendererBoolean $bin.rendererStable "Soak bin $bi rendererStable"

    if (-not [bool]$bin.rendererStable) {
        $passed = $false
        $breaches += "Soak bin $bi renderer was not stable."
    }
    if ([long]$bin.workingSetStartBytes -gt [long]$limits.workingSetMaximumBytes) {
        $passed = $false
        $breaches += "Soak bin $bi start working set ($($bin.workingSetStartBytes) bytes) > maximum ($($limits.workingSetMaximumBytes) bytes)"
    }
    if ([long]$bin.workingSetEndBytes -gt [long]$limits.workingSetMaximumBytes) {
        $passed = $false
        $breaches += "Soak bin $bi end working set ($($bin.workingSetEndBytes) bytes) > maximum ($($limits.workingSetMaximumBytes) bytes)"
    }

    $slope = [Math]::Abs([double]$bin.workingSetEndBytes - [double]$bin.workingSetStartBytes) * 2
    if ($slope -gt [double]$limits.resourceSlopeMaximumBytesPerTenMinutes) {
        $passed = $false
        $breaches += "Soak bin $bi working set slope ($($slope) B/10m) > maximum ($($limits.resourceSlopeMaximumBytesPerTenMinutes) B/10m)"
    }

    $canonicalBins += [pscustomobject][ordered]@{
        powerSource = $expectedPower
        ordinal = [int]$expectedOrdinal
        durationMinutes = 5
        observedUtc = [string]$bin.observedUtc
        workingSetStartBytes = [long]$bin.workingSetStartBytes
        workingSetEndBytes = [long]$bin.workingSetEndBytes
        rendererStable = [bool]$bin.rendererStable
    }
}

if (-not $passed) {
    if (-not $AllowThresholdBreach) {
        throw "Performance threshold breached: $($breaches -join '; ')"
    }
    $aggregateStatus = 'FAIL'
} else {
    $aggregateStatus = 'PASS'
}

$receiptObject = [pscustomobject][ordered]@{
    orders = $canonicalOrders
    soakBins = $canonicalBins
    aggregateStatus = $aggregateStatus
}

$canonicalJson = ConvertTo-RendererCanonicalJson $receiptObject $RepositoryRoot
$canonicalSha = Get-HumanDesignReviewSha256ForText $canonicalJson

$destinationDir = Split-Path -Parent $fullDestination
if (-not (Test-Path -LiteralPath $destinationDir -PathType Container)) {
    New-Item -ItemType Directory -Path $destinationDir -Force | Out-Null
}

$stagingPath = Join-Path $destinationDir ('.performance-receipt-staging-' + [Guid]::NewGuid().ToString('N') + '.json')
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

$stableIdentity = Get-RendererStableFileIdentity $EvidenceRoot $fullDestination 'Performance evidence receipt' -IncludeBytes
if ($stableIdentity.Sha256 -ne (Get-FileHash -LiteralPath $fullDestination -Algorithm SHA256).Hash) {
    throw 'Performance evidence receipt file hash changed during stable verification.'
}

[pscustomobject][ordered]@{
    EvidenceClassification = 'PackagedCompatibilityCandidate'
    ReceiptPath = $fullDestination
    RelativePath = $relativePath
    Bytes = [long]$stableIdentity.Bytes
    FileSha256 = [string]$stableIdentity.Sha256
    CanonicalSha256 = [string]$canonicalSha
    AggregateStatus = [string]$aggregateStatus
    Binding = [pscustomobject][ordered]@{
        relativePath = $relativePath
        bytes = [long]$stableIdentity.Bytes
        fileSha256 = [string]$stableIdentity.Sha256
        canonicalSha256 = [string]$canonicalSha
    }
    Receipt = $receiptObject
}
