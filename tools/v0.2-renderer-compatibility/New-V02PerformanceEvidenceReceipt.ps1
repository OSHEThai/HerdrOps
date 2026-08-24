#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
    $RawObservations,

[Parameter(Mandatory = $true)]
[string]$DestinationDirectory,

    [Parameter(Mandatory = $true)]
    [string]$RawSourcePath,

    [Parameter(Mandatory = $true)]
    [object]$CandidateProvenance,

    [string]$EvidenceRoot,

    [string]$RepositoryRoot,

    [object]$OwnerNumericLimits
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
            'uiStallP95Milliseconds','uiStallMaximumMilliseconds','workingSetMaximumBytes'
        )
        Assert-PerfReceiptExactProperties $InputLimits (@('status','approvalReference','scopeCorrectionReference') + $limitNames) 'Owner numeric limits'
        if ($InputLimits.status -cne 'APPROVED') {
            throw 'Owner numeric limits must be APPROVED to generate a candidate performance receipt.'
        }
        if ($InputLimits.approvalReference -cne $script:RendererAuthorizedApprovalReference) {
            throw 'Owner numeric limits do not bind REC-ALL v2.'
        }
        if ($InputLimits.scopeCorrectionReference -cne 'https://github.com/OSHEThai/HerdrOps/issues/149#issuecomment-5396694185') {
            throw 'Owner numeric limits do not bind the v0.2 compatibility v4 performance-only scope correction.'
        }
        $expectedLimits = [ordered]@{
            cpuMaximumPercent = 1
            eventToWpfP95Milliseconds = 250
            cpuRegressionMaximumPercent = 10
            cpuRegressionMaximumPercentagePoints = 0.5
            latencyRegressionMaximumPercent = 10
            uiStallP95Milliseconds = 50
            uiStallMaximumMilliseconds = 100
            workingSetMaximumBytes = 267386880
        }
        foreach ($n in $limitNames) {
            Assert-RendererFiniteNumber $InputLimits.$n "Owner numeric limit $n" 0 ([double]::MaxValue) -ExclusiveMinimum
            if ([decimal]$InputLimits.$n -ne [decimal]($expectedLimits[$n])) {
                throw "Owner numeric limit $n does not equal REC-ALL v2."
            }
        }
        foreach ($n in @('workingSetMaximumBytes')) {
            Assert-RendererPositiveInteger $InputLimits.$n "Owner numeric limit $n"
        }
        return $InputLimits
    }

    return [pscustomobject][ordered]@{
        status = 'APPROVED'
        approvalReference = $script:RendererAuthorizedApprovalReference
        scopeCorrectionReference = 'https://github.com/OSHEThai/HerdrOps/issues/149#issuecomment-5396694185'
        cpuMaximumPercent = 1
        eventToWpfP95Milliseconds = 250
        cpuRegressionMaximumPercent = 10
        cpuRegressionMaximumPercentagePoints = 0.5
        latencyRegressionMaximumPercent = 10
        uiStallP95Milliseconds = 50
        uiStallMaximumMilliseconds = 100
        workingSetMaximumBytes = 267386880
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
    if ([long]$Repetition.ordinal -ne $ExpectedOrdinal) {
        throw "$Context ordinal must equal $ExpectedOrdinal; found $($Repetition.ordinal)."
    }
    Assert-RendererUtc $Repetition.observedUtc "$Context observedUtc"
    Assert-SampleProperties $Repetition.a "$Context mode A sample"
    Assert-SampleProperties $Repetition.b "$Context mode B sample"
}

function ConvertTo-CanonicalPerformanceRepetition {
    param([Parameter(Mandatory=$true)]$Repetition)
    [pscustomobject][ordered]@{
        ordinal = [int]$Repetition.ordinal
        observedUtc = [string]$Repetition.observedUtc
        a = [pscustomobject][ordered]@{
            cpuBasisPoints = [long]$Repetition.a.cpuBasisPoints
            workingSetMaximumBytes = [long]$Repetition.a.workingSetMaximumBytes
            latencyMicroseconds = @($Repetition.a.latencyMicroseconds | ForEach-Object { [long]$_ })
            uiStallMicroseconds = @($Repetition.a.uiStallMicroseconds | ForEach-Object { [long]$_ })
        }
        b = [pscustomobject][ordered]@{
            cpuBasisPoints = [long]$Repetition.b.cpuBasisPoints
            workingSetMaximumBytes = [long]$Repetition.b.workingSetMaximumBytes
            latencyMicroseconds = @($Repetition.b.latencyMicroseconds | ForEach-Object { [long]$_ })
            uiStallMicroseconds = @($Repetition.b.uiStallMicroseconds | ForEach-Object { [long]$_ })
        }
    }
}

function Read-CanonicalRawSource {
    param([Parameter(Mandatory=$true)][string]$Path,[Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)][string]$RepositoryRoot)
    $identity = Get-RendererStableFileIdentity $Root $Path 'Raw performance observations source' -IncludeBytes
    $json = (New-Object Text.UTF8Encoding($false, $true)).GetString($identity.Content)
    $value = ConvertFrom-StrictHumanDesignReviewJson -Json $json -Description 'Raw performance observations source'
    if ($PSVersionTable.PSVersion.Major -ge 7 -and (Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) {
        $value = $json | ConvertFrom-Json -DateKind String
    }
    $canonical = ConvertTo-RendererCanonicalJson $value $RepositoryRoot
    if ($json -cne ($canonical + "`n")) {
        throw 'Raw performance observations source must be exact canonical JSON plus one LF.'
    }
    [pscustomobject][ordered]@{
        Value = $value
        Binding = [pscustomobject][ordered]@{
            relativePath = $null
            bytes = [long]$identity.Bytes
            fileSha256 = [string]$identity.Sha256
            canonicalSha256 = [string](Get-HumanDesignReviewSha256ForText $canonical)
        }
        CanonicalJson = $canonical
    }
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

# Validate destination directory and evidence root
if ([string]::IsNullOrWhiteSpace($EvidenceRoot)) {
    if ([IO.Path]::IsPathRooted($DestinationDirectory)) {
        $EvidenceRoot = Split-Path -Parent ([IO.Path]::GetFullPath($DestinationDirectory))
    } else {
        $EvidenceRoot = $RepositoryRoot
    }
}
$EvidenceRoot = [IO.Path]::GetFullPath($EvidenceRoot).TrimEnd('\','/')

$fullDestinationDirectory = if ([IO.Path]::IsPathRooted($DestinationDirectory)) {
    [IO.Path]::GetFullPath($DestinationDirectory)
} else {
    [IO.Path]::GetFullPath((Join-Path $EvidenceRoot $DestinationDirectory))
}

Assert-RendererNonReparsePath -Root $EvidenceRoot -Path $fullDestinationDirectory -Context 'Performance evidence receipt destination directory'
if ($fullDestinationDirectory -cne $EvidenceRoot -and -not $fullDestinationDirectory.StartsWith($EvidenceRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Performance evidence receipt destination directory '$fullDestinationDirectory' escaped the evidence root '$EvidenceRoot'."
}
if (Test-Path -LiteralPath $fullDestinationDirectory) {
    throw "Performance evidence receipt destination directory already exists; refusing to clobber '$fullDestinationDirectory'."
}

$destinationDirectoryRelative = $fullDestinationDirectory.Substring($EvidenceRoot.Length).TrimStart('\','/').Replace('\','/')
Assert-RendererRelativePath $destinationDirectoryRelative 'Performance evidence receipt destination directory relativePath'
$receiptFileName = 'performance-receipt.json'
$relativePath = ($destinationDirectoryRelative.TrimEnd('/') + '/' + $receiptFileName).TrimStart('/')
Assert-RendererRelativePath $relativePath 'Performance evidence receipt relativePath'

# The raw source is a separate, canonical, held evidence file. The supplied
# object is compared to it so pipeline/object callers cannot silently diverge.
$fullRawSource = if ([IO.Path]::IsPathRooted($RawSourcePath)) {
    [IO.Path]::GetFullPath($RawSourcePath)
} else {
    [IO.Path]::GetFullPath((Join-Path $EvidenceRoot $RawSourcePath))
}
Assert-RendererNonReparsePath -Root $EvidenceRoot -Path $fullRawSource -Context 'Raw performance observations source'
if ($fullRawSource -cne $EvidenceRoot -and -not $fullRawSource.StartsWith($EvidenceRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Raw performance observations source '$fullRawSource' escaped the evidence root '$EvidenceRoot'."
}
$rawSourceRelative = $fullRawSource.Substring($EvidenceRoot.Length).TrimStart('\','/').Replace('\','/')
Assert-RendererRelativePath $rawSourceRelative 'Raw performance observations source relativePath'
$rawSourceRead = Read-CanonicalRawSource -Path $fullRawSource -Root $EvidenceRoot -RepositoryRoot $RepositoryRoot
Assert-PerfReceiptExactProperties $rawSourceRead.Value @('orders') 'Raw performance observations source'
$providedRawCanonical = ConvertTo-RendererCanonicalJson $rawObj $RepositoryRoot
if ($providedRawCanonical -cne $rawSourceRead.CanonicalJson) {
    throw 'RawObservations does not exactly match the held raw-source provenance file.'
}
$rawObj = $rawSourceRead.Value
$rawSourceRead.Binding.relativePath = $rawSourceRelative

# Validate top-level properties of raw observations
Assert-PerfReceiptExactProperties $rawObj @('orders') 'Raw performance observations'

Assert-RendererPerformanceProvenance $CandidateProvenance 'Candidate performance provenance'

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

    Assert-PerfReceiptExactProperties $orderItem @('order','warmup','repetitions') "Order $oi"

    if ([string]$orderItem.order -cne $expectedOrder) {
        throw "Order $oi must be '$expectedOrder'; found '$($orderItem.order)'."
    }

    $wArray = @($orderItem.warmup)
    if ($wArray.Count -ne 1) {
        throw "Order $expectedOrder warmup must contain exactly 1 warmup repetition; found $($wArray.Count)."
    }
    $warmupFound = $wArray[0]
    $measuredReps = @($orderItem.repetitions)

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

        foreach ($modeName in @('a','b')) {
            if ($derived[$modeName].Cpu -gt [double]$limits.cpuMaximumPercent) {
                $passed = $false
                $breaches += "Order $expectedOrder rep $ri mode $($modeName.ToUpperInvariant()) CPU ($($derived[$modeName].Cpu)%) > maximum ($($limits.cpuMaximumPercent)%)"
            }
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

        $canonicalReps += ConvertTo-CanonicalPerformanceRepetition $rep
    }

    $canonicalOrders += [pscustomobject][ordered]@{
        order = $expectedOrder
        warmup = @(ConvertTo-CanonicalPerformanceRepetition $warmupFound)
        repetitions = $canonicalReps
    }
}

if (-not $passed) {
    throw "Performance threshold breached: $($breaches -join '; ')"
}
$aggregateStatus = 'PASS'

$receiptObject = [pscustomobject][ordered]@{
    schemaVersion = 4
    provenance = $CandidateProvenance
    rawSource = $rawSourceRead.Binding
    orders = $canonicalOrders
    aggregateStatus = $aggregateStatus
}

$canonicalJson = ConvertTo-RendererCanonicalJson $receiptObject $RepositoryRoot
$canonicalSha = Get-HumanDesignReviewSha256ForText $canonicalJson

$destinationParent = Split-Path -Parent $fullDestinationDirectory
if (-not (Test-Path -LiteralPath $destinationParent -PathType Container)) {
    New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
}

$stagingDirectory = Join-Path $destinationParent ('.performance-receipt-stage-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stagingDirectory | Out-Null
$stagingPath = Join-Path $stagingDirectory $receiptFileName
$fileBytes = (New-Object Text.UTF8Encoding($false, $true)).GetBytes($canonicalJson + "`n")

$stream = [IO.File]::Open($stagingPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
try {
    $stream.Write($fileBytes, 0, $fileBytes.Length)
    $stream.Flush($true)
} finally {
    $stream.Dispose()
}

Assert-RendererNonReparsePath -Root $EvidenceRoot -Path $stagingPath -Context 'Staged performance evidence receipt'
$stagedIdentity = Get-RendererStableFileIdentity $EvidenceRoot $stagingPath 'Staged performance evidence receipt' -IncludeBytes
if ($stagedIdentity.Bytes -ne [long]$fileBytes.Length -or $stagedIdentity.Sha256 -ne (Get-HumanDesignReviewSha256ForBytes $fileBytes)) {
    throw 'Staged performance evidence receipt does not equal the intended canonical bytes.'
}

# A directory rename on one volume is atomic and refuses an existing target.
# The final destination is therefore either absent or a complete receipt
# directory; no delete-then-move replacement is permitted.
if (Test-Path -LiteralPath $fullDestinationDirectory) {
    throw "Performance evidence receipt destination directory appeared during publish; refusing to clobber '$fullDestinationDirectory'."
}
[IO.Directory]::Move($stagingDirectory, $fullDestinationDirectory)
$fullDestination = Join-Path $fullDestinationDirectory $receiptFileName

$stableIdentity = Get-RendererStableFileIdentity $EvidenceRoot $fullDestination 'Performance evidence receipt' -IncludeBytes
if ($stableIdentity.Bytes -ne [long]$fileBytes.Length -or $stableIdentity.Sha256 -ne $stagedIdentity.Sha256) {
    throw 'Performance evidence receipt file identity changed during atomic publish.'
}
if ($stableIdentity.Content.Length -ne $fileBytes.Length) {
    throw 'Performance evidence receipt byte count changed during atomic publish.'
}
for ($i = 0; $i -lt $fileBytes.Length; $i++) {
    if ($stableIdentity.Content[$i] -ne $fileBytes[$i]) {
        throw 'Performance evidence receipt bytes changed during atomic publish.'
    }
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
