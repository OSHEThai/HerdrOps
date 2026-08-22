#requires -Version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'RendererCompatibility.Common.ps1')

$script:PositiveCases = 0
$script:NegativeCases = 0

function Pass([string]$Name) {
    $script:PositiveCases++
    "PASS positive: $Name"
}

function Pass-Negative([string]$Name) {
    $script:NegativeCases++
    "PASS negative: $Name"
}

function Copy-TestValue($Value) {
    $json = $Value | ConvertTo-Json -Depth 80
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        $json | ConvertFrom-Json -DateKind String
    } else {
        $json | ConvertFrom-Json
    }
}

function Write-TestJsonFile($Value, [string]$Path) {
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 80), (New-Object Text.UTF8Encoding($false)))
}

function New-SampleObject([long]$CpuBasisPoints = 50, [long]$WorkingSetBytes = 104857600, [long]$LatencyUs = 100000, [long]$StallUs = 10000) {
    [pscustomobject][ordered]@{
        cpuBasisPoints = $CpuBasisPoints
        workingSetMaximumBytes = $WorkingSetBytes
        latencyMicroseconds = @(1..20 | ForEach-Object { $LatencyUs })
        uiStallMicroseconds = @(1..20 | ForEach-Object { $StallUs })
    }
}

function New-RepetitionObject([int]$Ordinal, [string]$Timestamp, $SampleA, $SampleB) {
    if ($null -eq $SampleA) { $SampleA = New-SampleObject }
    if ($null -eq $SampleB) { $SampleB = New-SampleObject }
    [pscustomobject][ordered]@{
        ordinal = $Ordinal
        observedUtc = $Timestamp
        a = $SampleA
        b = $SampleB
    }
}

function New-ValidRawObservations() {
    $orders = @()
    foreach ($orderName in @('AB', 'BA')) {
        $warmupRep = New-RepetitionObject 0 "2026-08-22T12:00:00.0000000+00:00"
        $reps = @()
        for ($i = 0; $i -lt 5; $i++) {
            $offset = if ($orderName -ceq 'BA') { 10 } else { 0 }
            $ts = ('2026-08-22T12:01:{0:00}.0000000+00:00' -f ($i + $offset))
            $reps += New-RepetitionObject $i $ts
        }
        $orders += [pscustomobject][ordered]@{
            order = $orderName
            warmup = @($warmupRep)
            repetitions = $reps
        }
    }

    $bins = @()
    foreach ($power in @('AC', 'Battery')) {
        for ($i = 0; $i -lt 12; $i++) {
            $offset = if ($power -ceq 'Battery') { 12 } else { 0 }
            $ts = ('2026-08-22T12:{0:00}:00.0000000+00:00' -f ($i + 1 + $offset))
            $bins += [pscustomobject][ordered]@{
                powerSource = $power
                ordinal = $i
                durationMinutes = 5
                observedUtc = $ts
                workingSetStartBytes = 104857600
                workingSetEndBytes = 104857600
                rendererStable = $true
            }
        }
    }

    [pscustomobject][ordered]@{
        orders = $orders
        soakBins = $bins
    }
}

function Expect-BuilderFailure([string]$Name, [scriptblock]$Action) {
    $failed = $false
    try {
        & $Action | Out-Null
    } catch {
        $failed = $true
    }
    if (-not $failed) {
        throw "Negative case '$Name' did not fail closed."
    }
    Pass-Negative $Name
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('herdrops-perf-receipt-test-' + [Guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $evidenceRoot = Join-Path $tempRoot 'evidence'
    $repoRoot = Join-Path $tempRoot 'repo'
    New-Item -ItemType Directory -Path $evidenceRoot, $repoRoot -Force | Out-Null

    # Copy required schema/governance files into mock repo
    $worktree = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    $packageDir = Join-Path $repoRoot 'tools\packaging\v0.2'
    $libDir = Join-Path $repoRoot 'tools\lib'
    $planDir = Join-Path $repoRoot 'Plan\reference-hosts'
    $refDir = Join-Path $repoRoot 'docs\design\reference'
    New-Item -ItemType Directory -Path $packageDir, $libDir, $planDir, $refDir -Force | Out-Null
    
    $sourcePkg = Join-Path $PSScriptRoot '..\packaging\v0.2'
    Copy-Item (Join-Path $sourcePkg 'package-identity-profile.json') $packageDir
    Copy-Item (Join-Path $sourcePkg 'package-identity-receipt.schema.json') $packageDir
    Copy-Item (Join-Path $worktree 'tools\lib\V02ReferenceHostProfile.ps1') $libDir
    Copy-Item (Join-Path $worktree 'Plan\reference-hosts\v0.2.json') $planDir
    Copy-Item (Join-Path $worktree 'Plan\reference-hosts\reference-host-profile.schema.json') $planDir
    Copy-Item (Join-Path $worktree 'docs\design\reference\*.png') $refDir

    $builderScript = Join-Path $PSScriptRoot 'New-V02PerformanceEvidenceReceipt.ps1'

    # 1. Positive: Full valid raw observations object generates canonical receipt
    $raw1 = New-ValidRawObservations
    $dest1 = 'performance/receipt.json'
    $out1 = & $builderScript -RawObservations $raw1 -DestinationPath $dest1 -EvidenceRoot $evidenceRoot -RepositoryRoot $repoRoot
    if ($out1.AggregateStatus -cne 'PASS' -or $out1.EvidenceClassification -cne 'PackagedCompatibilityCandidate' -or $out1.Bytes -le 0 -or $out1.CanonicalSha256 -cnotmatch '^[0-9A-F]{64}$') {
        throw 'Positive case 1 returned invalid summary properties.'
    }
    Pass 'valid raw observations produce atomic canonical proof receipt'

    # 2. Positive: Output binding verified by Assert-RendererPerformanceReceipt
    $limits = [ordered]@{
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
    $verified = Assert-RendererPerformanceReceipt $out1.Binding $evidenceRoot $repoRoot $limits
    if ($verified -cne 'PASS') {
        throw 'Assert-RendererPerformanceReceipt did not return PASS for positive receipt.'
    }
    Pass 'assert-renderer-performance-receipt verifies generated receipt binding'

    # 3. Positive: Accepts raw observations via Pipeline
    $destPipe = 'performance/pipeline-receipt.json'
    $outPipe = $raw1 | & $builderScript -DestinationPath $destPipe -EvidenceRoot $evidenceRoot -RepositoryRoot $repoRoot
    if ($outPipe.AggregateStatus -cne 'PASS' -or $outPipe.Bytes -ne $out1.Bytes -or $outPipe.CanonicalSha256 -cne $out1.CanonicalSha256) {
        throw 'Pipeline input did not produce identical deterministic receipt.'
    }
    Pass 'pipeline raw observations ingestion'

    # 4. Positive: Accepts file path as RawObservations
    $rawFilePath = Join-Path $evidenceRoot 'raw-input.json'
    Write-TestJsonFile $raw1 $rawFilePath
    $destFile = 'performance/file-receipt.json'
    $outFile = & $builderScript -RawObservations $rawFilePath -DestinationPath $destFile -EvidenceRoot $evidenceRoot -RepositoryRoot $repoRoot
    if ($outFile.AggregateStatus -cne 'PASS' -or $outFile.CanonicalSha256 -cne $out1.CanonicalSha256) {
        throw 'File input did not produce identical deterministic receipt.'
    }
    Pass 'file path raw observations ingestion'

    # 5. Positive: Accepts JSON text string as RawObservations
    $rawJsonStr = $raw1 | ConvertTo-Json -Depth 80
    $destStr = 'performance/str-receipt.json'
    $outStr = & $builderScript -RawObservations $rawJsonStr -DestinationPath $destStr -EvidenceRoot $evidenceRoot -RepositoryRoot $repoRoot
    if ($outStr.AggregateStatus -cne 'PASS' -or $outStr.CanonicalSha256 -cne $out1.CanonicalSha256) {
        throw 'JSON string input did not produce identical deterministic receipt.'
    }
    Pass 'json string raw observations ingestion'

    # 6. Positive: Warmup variants - warmupRepetition property and 6-repetition array
    $rawWarmupSingle = Copy-TestValue $raw1
    $rawWarmupSingle.orders[0].warmup = $null
    $rawWarmupSingle.orders[0] | Add-Member warmupRepetition (New-RepetitionObject 0 "2026-08-22T12:00:00.0000000+00:00")
    $outSingle = & $builderScript -RawObservations $rawWarmupSingle -DestinationPath 'performance/warmup-single.json' -EvidenceRoot $evidenceRoot -RepositoryRoot $repoRoot
    if ($outSingle.AggregateStatus -cne 'PASS') { throw 'warmupRepetition property failed.' }
    Pass 'warmupRepetition single object support'

    $raw6Reps = Copy-TestValue $raw1
    $raw6Reps.orders[0].warmup = $null
    $raw6Reps.orders[0].repetitions = @(New-RepetitionObject 0 "2026-08-22T12:00:00.0000000+00:00") + @($raw6Reps.orders[0].repetitions)
    $out6Reps = & $builderScript -RawObservations $raw6Reps -DestinationPath 'performance/warmup-6reps.json' -EvidenceRoot $evidenceRoot -RepositoryRoot $repoRoot
    if ($out6Reps.AggregateStatus -cne 'PASS') { throw '6 repetitions array with index 0 warmup failed.' }
    Pass '6 repetitions array with index 0 warmup support'

    # 7. Positive: Explicit AllowThresholdBreach emits canonical FAIL receipt
    $rawBreach = Copy-TestValue $raw1
    $rawBreach.orders[0].repetitions[0].b.cpuBasisPoints = 150 # 1.5% > 1.0%
    $destFail = 'performance/breach-fail.json'
    $outFail = & $builderScript -RawObservations $rawBreach -DestinationPath $destFail -EvidenceRoot $evidenceRoot -RepositoryRoot $repoRoot -AllowThresholdBreach
    if ($outFail.AggregateStatus -cne 'FAIL') {
        throw 'AllowThresholdBreach did not produce aggregateStatus FAIL.'
    }
    $verifiedFail = Assert-RendererPerformanceReceipt $outFail.Binding $evidenceRoot $repoRoot $limits
    if ($verifiedFail -cne 'FAIL') {
        throw 'Assert-RendererPerformanceReceipt did not verify FAIL receipt.'
    }
    Pass 'allow-threshold-breach generates canonical FAIL receipt verified by assert-renderer-performance-receipt'

    # 8. Positive: Overwrites existing file safely
    $outOverwrite = & $builderScript -RawObservations $raw1 -DestinationPath $dest1 -EvidenceRoot $evidenceRoot -RepositoryRoot $repoRoot
    if ($outOverwrite.CanonicalSha256 -cne $out1.CanonicalSha256) {
        throw 'Overwriting existing destination altered receipt hash.'
    }
    Pass 'safe atomic overwrite of existing destination'

    # Hostile Negative Cases
    Expect-BuilderFailure 'missing raw observations' {
        & $builderScript -RawObservations $null -DestinationPath 'performance/neg.json' -EvidenceRoot $evidenceRoot -RepositoryRoot $repoRoot
    }

    Expect-BuilderFailure 'empty object missing orders and soakBins' {
        & $builderScript -RawObservations ([pscustomobject]@{}) -DestinationPath 'performance/neg.json' -EvidenceRoot $evidenceRoot -RepositoryRoot $repoRoot
    }

    Expect-BuilderFailure 'extra top-level property' {
        $bad = Copy-TestValue $raw1
        $bad | Add-Member extra 'unauthorized'
        & $builderScript -RawObservations $bad -DestinationPath 'performance/neg.json' -EvidenceRoot $evidenceRoot -RepositoryRoot $repoRoot
    }

    Expect-BuilderFailure 'only 1 order' {
        $bad = Copy-TestValue $raw1
        $bad.orders = @($bad.orders[0])
        & $builderScript -RawObservations $bad -DestinationPath 'performance/neg.json' -EvidenceRoot $evidenceRoot -RepositoryRoot $repoRoot
    }

    Expect-BuilderFailure 'wrong order sequence BA then AB' {
        $bad = Copy-TestValue $raw1
        $bad.orders = @($bad.orders[1], $bad.orders[0])
        & $builderScript -RawObservations $bad -DestinationPath 'performance/neg.json' -EvidenceRoot $evidenceRoot -RepositoryRoot $repoRoot
    }

    Expect-BuilderFailure 'duplicate AB orders' {
        $bad = Copy-TestValue $raw1
        $bad.orders = @($bad.orders[0], $bad.orders[0])
        & $builderScript -RawObservations $bad -DestinationPath 'performance/neg.json' -EvidenceRoot $evidenceRoot -RepositoryRoot $repoRoot
    }

    Expect-BuilderFailure 'missing warmup in order AB' {
        $bad = Copy-TestValue $raw1
        $bad.orders[0].warmup = $null
        & $builderScript -RawObservations $bad -DestinationPath 'performance/neg.json' -EvidenceRoot $evidenceRoot -RepositoryRoot $repoRoot
    }

    Expect-BuilderFailure 'missing warmup in order BA' {
        $bad = Copy-TestValue $raw1
        $bad.orders[1].warmup = $null
        & $builderScript -RawObservations $bad -DestinationPath 'performance/neg.json' -EvidenceRoot $evidenceRoot -RepositoryRoot $repoRoot
    }

    Expect-BuilderFailure 'more than 1 warmup repetition' {
        $bad = Copy-TestValue $raw1
        $bad.orders[0].warmup = @(New-RepetitionObject 0 "2026-08-22T12:00:00.0000000+00:00", New-RepetitionObject 0 "2026-08-22T12:00:00.0000000+00:00")
        & $builderScript -RawObservations $bad -DestinationPath 'performance/neg.json' -EvidenceRoot $evidenceRoot -RepositoryRoot $repoRoot
    }

    Expect-BuilderFailure 'warmup missing mode A' {
        $bad = Copy-TestValue $raw1
        $bad.orders[0].warmup[0].PSObject.Properties.Remove('a')
        & $builderScript -RawObservations $bad -DestinationPath 'performance/neg.json' -EvidenceRoot $evidenceRoot -RepositoryRoot $repoRoot
    }

    Expect-BuilderFailure 'warmup latency count less than 20' {
        $bad = Copy-TestValue $raw1
        $bad.orders[0].warmup[0].a.latencyMicroseconds = @($bad.orders[0].warmup[0].a.latencyMicroseconds | Select-Object -First 19)
        & $builderScript -RawObservations $bad -DestinationPath 'performance/neg.json' -EvidenceRoot $evidenceRoot -RepositoryRoot $repoRoot
    }

    Expect-BuilderFailure 'warmup latency count greater than 20' {
        $bad = Copy-TestValue $raw1
        $bad.orders[0].warmup[0].a.latencyMicroseconds = @($bad.orders[0].warmup[0].a.latencyMicroseconds) + @(100000)
        & $builderScript -RawObservations $bad -DestinationPath 'performance/neg.json' -EvidenceRoot $evidenceRoot -RepositoryRoot $repoRoot
    }

    Expect-BuilderFailure 'warmup stall count less than 20' {
        $bad = Copy-TestValue $raw1
        $bad.orders[0].warmup[0].a.uiStallMicroseconds = @($bad.orders[0].warmup[0].a.uiStallMicroseconds | Select-Object -First 19)
        & $builderScript -RawObservations $bad -DestinationPath 'performance/neg.json' -EvidenceRoot $evidenceRoot -RepositoryRoot $repoRoot
    }

    Expect-BuilderFailure 'warmup stall count greater than 20' {
        $bad = Copy-TestValue $raw1
        $bad.orders[0].warmup[0].a.uiStallMicroseconds = @($bad.orders[0].warmup[0].a.uiStallMicroseconds) + @(10000)
        & $builderScript -RawObservations $bad -DestinationPath 'performance/neg.json' -EvidenceRoot $evidenceRoot -RepositoryRoot $repoRoot
    }

    Expect-BuilderFailure 'warmup negative CPU' {
        $bad = Copy-TestValue $raw1
        $bad.orders[0].warmup[0].a.cpuBasisPoints = -1
        & $builderScript -RawObservations $bad -DestinationPath 'performance/neg.json' -EvidenceRoot $evidenceRoot -RepositoryRoot $repoRoot
    }

    Expect-BuilderFailure 'warmup negative working set' {
        $bad = Copy-TestValue $raw1
        $bad.orders[0].warmup[0].a.workingSetMaximumBytes = -100
        & $builderScript -RawObservations $bad -DestinationPath 'performance/neg.json' -EvidenceRoot $evidenceRoot -RepositoryRoot $repoRoot
    }

    Expect-BuilderFailure 'warmup non-UTC timestamp' {
        $bad = Copy-TestValue $raw1
        $bad.orders[0].warmup[0].observedUtc = '2026-08-22T19:00:00.0000000+07:00'
        & $builderScript -RawObservations $bad -DestinationPath 'performance/neg.json' -EvidenceRoot $evidenceRoot -RepositoryRoot $repoRoot
    }

    Expect-BuilderFailure 'measured repetitions count less than 5' {
        $bad = Copy-TestValue $raw1
        $bad.orders[0].repetitions = @($bad.orders[0].repetitions | Select-Object -First 4)
        & $builderScript -RawObservations $bad -DestinationPath 'performance/neg.json' -EvidenceRoot $evidenceRoot -RepositoryRoot $repoRoot
    }

    Expect-BuilderFailure 'repetition ordinal mismatch' {
        $bad = Copy-TestValue $raw1
        $bad.orders[0].repetitions[0].ordinal = 1
        & $builderScript -RawObservations $bad -DestinationPath 'performance/neg.json' -EvidenceRoot $evidenceRoot -RepositoryRoot $repoRoot
    }

    Expect-BuilderFailure 'repetition missing mode B' {
        $bad = Copy-TestValue $raw1
        $bad.orders[0].repetitions[0].PSObject.Properties.Remove('b')
        & $builderScript -RawObservations $bad -DestinationPath 'performance/neg.json' -EvidenceRoot $evidenceRoot -RepositoryRoot $repoRoot
    }

    Expect-BuilderFailure 'repetition latency count less than 20' {
        $bad = Copy-TestValue $raw1
        $bad.orders[0].repetitions[0].b.latencyMicroseconds = @($bad.orders[0].repetitions[0].b.latencyMicroseconds | Select-Object -First 19)
        & $builderScript -RawObservations $bad -DestinationPath 'performance/neg.json' -EvidenceRoot $evidenceRoot -RepositoryRoot $repoRoot
    }

    Expect-BuilderFailure 'repetition latency count greater than 20' {
        $bad = Copy-TestValue $raw1
        $bad.orders[0].repetitions[0].b.latencyMicroseconds = @($bad.orders[0].repetitions[0].b.latencyMicroseconds) + @(100000)
        & $builderScript -RawObservations $bad -DestinationPath 'performance/neg.json' -EvidenceRoot $evidenceRoot -RepositoryRoot $repoRoot
    }

    Expect-BuilderFailure 'repetition stall count less than 20' {
        $bad = Copy-TestValue $raw1
        $bad.orders[0].repetitions[0].b.uiStallMicroseconds = @($bad.orders[0].repetitions[0].b.uiStallMicroseconds | Select-Object -First 19)
        & $builderScript -RawObservations $bad -DestinationPath 'performance/neg.json' -EvidenceRoot $evidenceRoot -RepositoryRoot $repoRoot
    }

    Expect-BuilderFailure 'repetition stall count greater than 20' {
        $bad = Copy-TestValue $raw1
        $bad.orders[0].repetitions[0].b.uiStallMicroseconds = @($bad.orders[0].repetitions[0].b.uiStallMicroseconds) + @(10000)
        & $builderScript -RawObservations $bad -DestinationPath 'performance/neg.json' -EvidenceRoot $evidenceRoot -RepositoryRoot $repoRoot
    }

    Expect-BuilderFailure 'repetition negative latency value' {
        $bad = Copy-TestValue $raw1
        $bad.orders[0].repetitions[0].a.latencyMicroseconds[0] = -50
        & $builderScript -RawObservations $bad -DestinationPath 'performance/neg.json' -EvidenceRoot $evidenceRoot -RepositoryRoot $repoRoot
    }

    Expect-BuilderFailure 'repetition negative stall value' {
        $bad = Copy-TestValue $raw1
        $bad.orders[0].repetitions[0].a.uiStallMicroseconds[0] = -10
        & $builderScript -RawObservations $bad -DestinationPath 'performance/neg.json' -EvidenceRoot $evidenceRoot -RepositoryRoot $repoRoot
    }

    Expect-BuilderFailure 'repetition string numeric' {
        $bad = Copy-TestValue $raw1
        $bad.orders[0].repetitions[0].a.cpuBasisPoints = '50'
        & $builderScript -RawObservations $bad -DestinationPath 'performance/neg.json' -EvidenceRoot $evidenceRoot -RepositoryRoot $repoRoot
    }

    Expect-BuilderFailure 'repetition extra property on sample' {
        $bad = Copy-TestValue $raw1
        $bad.orders[0].repetitions[0].a | Add-Member extra 'bad'
        & $builderScript -RawObservations $bad -DestinationPath 'performance/neg.json' -EvidenceRoot $evidenceRoot -RepositoryRoot $repoRoot
    }

    Expect-BuilderFailure 'repetition non-UTC timestamp' {
        $bad = Copy-TestValue $raw1
        $bad.orders[0].repetitions[0].observedUtc = '2026-08-22T19:00:00.0000000+07:00'
        & $builderScript -RawObservations $bad -DestinationPath 'performance/neg.json' -EvidenceRoot $evidenceRoot -RepositoryRoot $repoRoot
    }

    Expect-BuilderFailure 'soak bins count less than 24' {
        $bad = Copy-TestValue $raw1
        $bad.soakBins = @($bad.soakBins | Select-Object -First 23)
        & $builderScript -RawObservations $bad -DestinationPath 'performance/neg.json' -EvidenceRoot $evidenceRoot -RepositoryRoot $repoRoot
    }

    Expect-BuilderFailure 'soak bins count greater than 24' {
        $bad = Copy-TestValue $raw1
        $bad.soakBins = @($bad.soakBins) + @($bad.soakBins[0])
        & $builderScript -RawObservations $bad -DestinationPath 'performance/neg.json' -EvidenceRoot $evidenceRoot -RepositoryRoot $repoRoot
    }

    Expect-BuilderFailure 'soak bin power source mismatch' {
        $bad = Copy-TestValue $raw1
        $bad.soakBins[0].powerSource = 'Battery'
        & $builderScript -RawObservations $bad -DestinationPath 'performance/neg.json' -EvidenceRoot $evidenceRoot -RepositoryRoot $repoRoot
    }

    Expect-BuilderFailure 'soak bin ordinal mismatch' {
        $bad = Copy-TestValue $raw1
        $bad.soakBins[0].ordinal = 5
        & $builderScript -RawObservations $bad -DestinationPath 'performance/neg.json' -EvidenceRoot $evidenceRoot -RepositoryRoot $repoRoot
    }

    Expect-BuilderFailure 'soak bin duration mismatch' {
        $bad = Copy-TestValue $raw1
        $bad.soakBins[0].durationMinutes = 10
        & $builderScript -RawObservations $bad -DestinationPath 'performance/neg.json' -EvidenceRoot $evidenceRoot -RepositoryRoot $repoRoot
    }

    Expect-BuilderFailure 'soak bin renderer unstable' {
        $bad = Copy-TestValue $raw1
        $bad.soakBins[0].rendererStable = $false
        & $builderScript -RawObservations $bad -DestinationPath 'performance/neg.json' -EvidenceRoot $evidenceRoot -RepositoryRoot $repoRoot
    }

    Expect-BuilderFailure 'soak bin non-UTC timestamp' {
        $bad = Copy-TestValue $raw1
        $bad.soakBins[0].observedUtc = '2026-08-22T19:00:00.0000000+07:00'
        & $builderScript -RawObservations $bad -DestinationPath 'performance/neg.json' -EvidenceRoot $evidenceRoot -RepositoryRoot $repoRoot
    }

    Expect-BuilderFailure 'soak bin negative working set' {
        $bad = Copy-TestValue $raw1
        $bad.soakBins[0].workingSetStartBytes = -1
        & $builderScript -RawObservations $bad -DestinationPath 'performance/neg.json' -EvidenceRoot $evidenceRoot -RepositoryRoot $repoRoot
    }

    Expect-BuilderFailure 'threshold breach mode B CPU maximum' {
        $bad = Copy-TestValue $raw1
        $bad.orders[0].repetitions[0].b.cpuBasisPoints = 150 # 1.5% > 1.0%
        & $builderScript -RawObservations $bad -DestinationPath 'performance/neg.json' -EvidenceRoot $evidenceRoot -RepositoryRoot $repoRoot
    }

    Expect-BuilderFailure 'threshold breach CPU percentage-point delta' {
        $bad = Copy-TestValue $raw1
        $bad.orders[0].repetitions[0].a.cpuBasisPoints = 40 # 0.4%
        $bad.orders[0].repetitions[0].b.cpuBasisPoints = 95 # 0.95% (delta 0.55 pp > 0.5 pp)
        & $builderScript -RawObservations $bad -DestinationPath 'performance/neg.json' -EvidenceRoot $evidenceRoot -RepositoryRoot $repoRoot
    }

    Expect-BuilderFailure 'threshold breach CPU relative regression percent' {
        $bad = Copy-TestValue $raw1
        $bad.orders[0].repetitions[0].a.cpuBasisPoints = 50 # 0.5%
        $bad.orders[0].repetitions[0].b.cpuBasisPoints = 56 # 0.56% (delta 0.06 / 0.5 = 12% > 10%)
        & $builderScript -RawObservations $bad -DestinationPath 'performance/neg.json' -EvidenceRoot $evidenceRoot -RepositoryRoot $repoRoot
    }

    Expect-BuilderFailure 'threshold breach Latency P95' {
        $bad = Copy-TestValue $raw1
        $bad.orders[0].repetitions[0].b.latencyMicroseconds[18] = 300000
        $bad.orders[0].repetitions[0].b.latencyMicroseconds[19] = 300000 # P95 = 300 ms > 250 ms
        & $builderScript -RawObservations $bad -DestinationPath 'performance/neg.json' -EvidenceRoot $evidenceRoot -RepositoryRoot $repoRoot
    }

    Expect-BuilderFailure 'threshold breach UI stall maximum' {
        $bad = Copy-TestValue $raw1
        $bad.orders[0].repetitions[0].b.uiStallMicroseconds[19] = 105000 # 105 ms > 100 ms
        & $builderScript -RawObservations $bad -DestinationPath 'performance/neg.json' -EvidenceRoot $evidenceRoot -RepositoryRoot $repoRoot
    }

    Expect-BuilderFailure 'threshold breach working set budget' {
        $bad = Copy-TestValue $raw1
        $bad.orders[0].repetitions[0].b.workingSetMaximumBytes = 267386881 # > 255 MiB
        & $builderScript -RawObservations $bad -DestinationPath 'performance/neg.json' -EvidenceRoot $evidenceRoot -RepositoryRoot $repoRoot
    }

    Expect-BuilderFailure 'threshold breach soak bin working set slope' {
        $bad = Copy-TestValue $raw1
        $bad.soakBins[0].workingSetStartBytes = 104857600
        $bad.soakBins[0].workingSetEndBytes = 106000000 # delta 1,142,400 * 2 = 2.28 MB/10m > 1 MB/10m
        & $builderScript -RawObservations $bad -DestinationPath 'performance/neg.json' -EvidenceRoot $evidenceRoot -RepositoryRoot $repoRoot
    }

    Expect-BuilderFailure 'unapproved limits status' {
        $unapprovedLimits = Copy-TestValue $limits
        $unapprovedLimits.status = 'NOT_OBSERVED'
        & $builderScript -RawObservations $raw1 -DestinationPath 'performance/neg.json' -EvidenceRoot $evidenceRoot -RepositoryRoot $repoRoot -OwnerNumericLimits $unapprovedLimits
    }

    Expect-BuilderFailure 'limits approval reference mismatch' {
        $badLimits = Copy-TestValue $limits
        $badLimits.approvalReference = 'https://example.invalid/fake'
        & $builderScript -RawObservations $raw1 -DestinationPath 'performance/neg.json' -EvidenceRoot $evidenceRoot -RepositoryRoot $repoRoot -OwnerNumericLimits $badLimits
    }

    Expect-BuilderFailure 'limits cpuMaximumPercent drift' {
        $badLimits = Copy-TestValue $limits
        $badLimits.cpuMaximumPercent = 2
        & $builderScript -RawObservations $raw1 -DestinationPath 'performance/neg.json' -EvidenceRoot $evidenceRoot -RepositoryRoot $repoRoot -OwnerNumericLimits $badLimits
    }

    Expect-BuilderFailure 'destination path escaping evidence root' {
        & $builderScript -RawObservations $raw1 -DestinationPath '..\escaped.json' -EvidenceRoot $evidenceRoot -RepositoryRoot $repoRoot
    }

    $junctionDir = Join-Path $evidenceRoot 'junction-test'
    $externalTarget = Join-Path $tempRoot 'external-target'
    New-Item -ItemType Directory -Path $externalTarget -Force | Out-Null
    New-Item -ItemType Junction -Path $junctionDir -Target $externalTarget | Out-Null
    try {
        Expect-BuilderFailure 'reparse junction destination path' {
            & $builderScript -RawObservations $raw1 -DestinationPath 'junction-test/receipt.json' -EvidenceRoot $evidenceRoot -RepositoryRoot $repoRoot
        }
    } finally {
        if (Test-Path -LiteralPath $junctionDir) {
            [IO.Directory]::Delete($junctionDir, $false)
        }
    }

    [pscustomobject]@{
        EvidenceClassification = 'SyntheticVerifierSelftest'
        PositiveCases = $script:PositiveCases
        NegativeCases = $script:NegativeCases
        Status = 'PASS'
    }
} finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
