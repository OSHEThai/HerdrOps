Set-StrictMode -Version Latest

$script:V02WorkingSetTargetMebibytes = 255
$script:V02WorkingSetTargetBytes = 267386880L

function Test-V02NativeJsonNumber {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) {
        return $false
    }

    return $Value -is [byte] -or
        $Value -is [sbyte] -or
        $Value -is [int16] -or
        $Value -is [uint16] -or
        $Value -is [int32] -or
        $Value -is [uint32] -or
        $Value -is [int64] -or
        $Value -is [uint64] -or
        $Value -is [single] -or
        $Value -is [double] -or
        $Value -is [decimal]
}

function Test-V02FiniteNonNegativeNumber {
    param([AllowNull()][object]$Value)

    if (-not (Test-V02NativeJsonNumber -Value $Value)) {
        return $false
    }

    $number = [double]$Value
    return -not [double]::IsNaN($number) -and
        -not [double]::IsInfinity($number) -and
        $number -ge 0
}

function Assert-V02WorkingSetBudgetEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$ResourceMeasurement
    )

    foreach ($name in @(
        'WorkingSetTargetMegabytes',
        'WorkingSetTargetBytes',
        'WorkingSetStatistic',
        'DurationSeconds',
        'SampleIntervalMilliseconds',
        'SampleCount',
        'Samples',
        'App',
        'Core',
        'StartFingerprint',
        'FinishFingerprint',
        'StateSequenceStable',
        'RuntimeEventCountStable',
        'RuntimeFingerprintStable',
        'FirstFingerprintChange',
        'HerdrConnectedThroughoutSample',
        'IdleSampleStartRenderer',
        'IdleSampleFinishRenderer',
        'CombinedAverageWorkingSetMegabytes',
        'CombinedMaximumWorkingSetMegabytes',
        'WorkingSetTargetPassed')) {
        if (-not ($ResourceMeasurement.PSObject.Properties.Name -contains $name)) {
            throw "Working-set evidence is missing required property '$name'."
        }
    }

    $reportedTarget = $ResourceMeasurement.WorkingSetTargetMegabytes
    if (-not (Test-V02NativeJsonNumber -Value $reportedTarget)) {
        throw 'WorkingSetTargetMegabytes must be a native JSON number.'
    }
    if ([double]$reportedTarget -ne [double]$script:V02WorkingSetTargetMebibytes) {
        throw "Unexpected v0.2 working-set target: $reportedTarget MiB. Expected exactly $script:V02WorkingSetTargetMebibytes MiB."
    }

    $reportedBytes = $ResourceMeasurement.WorkingSetTargetBytes
    if (-not ($reportedBytes -is [byte] -or
            $reportedBytes -is [int16] -or
            $reportedBytes -is [uint16] -or
            $reportedBytes -is [int32] -or
            $reportedBytes -is [uint32] -or
            $reportedBytes -is [int64] -or
            $reportedBytes -is [uint64])) {
        throw 'WorkingSetTargetBytes must be a native JSON integer.'
    }
    if ([decimal]$reportedBytes -ne [decimal]$script:V02WorkingSetTargetBytes) {
        throw "Unexpected v0.2 working-set target bytes: $reportedBytes. Expected exactly $script:V02WorkingSetTargetBytes."
    }
    if ($ResourceMeasurement.WorkingSetStatistic -isnot [string] -or
        [string]$ResourceMeasurement.WorkingSetStatistic -cne 'maximum') {
        throw "WorkingSetStatistic must be the native JSON string 'maximum'."
    }

    $average = $ResourceMeasurement.CombinedAverageWorkingSetMegabytes
    $maximum = $ResourceMeasurement.CombinedMaximumWorkingSetMegabytes
    if (-not (Test-V02FiniteNonNegativeNumber -Value $average)) {
        throw 'CombinedAverageWorkingSetMegabytes must be a finite nonnegative native JSON number.'
    }
    if (-not (Test-V02FiniteNonNegativeNumber -Value $maximum)) {
        throw 'CombinedMaximumWorkingSetMegabytes must be a finite nonnegative native JSON number.'
    }
    if ([double]$maximum -lt [double]$average) {
        throw 'CombinedMaximumWorkingSetMegabytes cannot be below CombinedAverageWorkingSetMegabytes.'
    }

    $integerTypes = @([TypeCode]::Byte,[TypeCode]::SByte,[TypeCode]::UInt16,[TypeCode]::UInt32,[TypeCode]::UInt64,[TypeCode]::Int16,[TypeCode]::Int32,[TypeCode]::Int64)
    if ($integerTypes -notcontains [Type]::GetTypeCode($ResourceMeasurement.DurationSeconds.GetType()) -or [int64]$ResourceMeasurement.DurationSeconds -ne 20 -or
        $integerTypes -notcontains [Type]::GetTypeCode($ResourceMeasurement.SampleIntervalMilliseconds.GetType()) -or [int64]$ResourceMeasurement.SampleIntervalMilliseconds -ne 250) {
        throw 'Raw working-set sampling must be exactly 20 seconds at 250 milliseconds.'
    }
    if ($null -eq $ResourceMeasurement.SampleCount -or
        $integerTypes -notcontains [Type]::GetTypeCode($ResourceMeasurement.SampleCount.GetType()) -or
        [int64]$ResourceMeasurement.SampleCount -ne 81) {
        throw 'SampleCount must be the native JSON integer 81 (initial sample plus 80 timed samples).'
    }
    $samples = @($ResourceMeasurement.Samples)
    if ($samples.Count -ne [int64]$ResourceMeasurement.SampleCount) {
        throw 'Samples count must exactly equal SampleCount.'
    }
    [decimal]$combinedSum = 0
    [decimal]$appSum = 0
    [decimal]$coreSum = 0
    [decimal]$appPrivateSum = 0
    [decimal]$corePrivateSum = 0
    [int64]$combinedMaximumBytes = 0
    [int64]$appMaximumBytes = 0
    [int64]$coreMaximumBytes = 0
    [int64]$appPrivateMaximumBytes = 0
    [int64]$corePrivateMaximumBytes = 0
    $previousObservedUtc = $null
    try {
        $idleStartUtc=[DateTimeOffset]::Parse([string]$ResourceMeasurement.IdleSampleStartRenderer.ObservedUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
        $idleFinishUtc=[DateTimeOffset]::Parse([string]$ResourceMeasurement.IdleSampleFinishRenderer.ObservedUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
    } catch { throw 'Idle renderer sample window timestamps are invalid.' }
    if (($idleFinishUtc - $idleStartUtc) -lt [TimeSpan]::FromSeconds(20)) { throw 'Observed idle renderer sample window must span at least 20 seconds.' }
    foreach($name in @('StateSequenceStable','RuntimeEventCountStable','RuntimeFingerprintStable','HerdrConnectedThroughoutSample')) {
        if ($ResourceMeasurement.$name -isnot [bool] -or -not [bool]$ResourceMeasurement.$name) { throw "$name must be native boolean true." }
    }
    if($null-ne$ResourceMeasurement.FirstFingerprintChange){throw 'FirstFingerprintChange must be null for the stable raw sample.'}
    $startFingerprintJson=$ResourceMeasurement.StartFingerprint|ConvertTo-Json -Depth 20 -Compress
    $finishFingerprintJson=$ResourceMeasurement.FinishFingerprint|ConvertTo-Json -Depth 20 -Compress
    if($startFingerprintJson-cne$finishFingerprintJson){throw 'StartFingerprint and FinishFingerprint contradict raw stable sampling.'}
    for ($index = 0; $index -lt $samples.Count; $index++) {
        $sample = $samples[$index]
        if ($null -eq $sample -or $sample -isnot [pscustomobject]) { throw "Resource sample $index must be a JSON object." }
        $actualNames=[string[]]@($sample.PSObject.Properties.Name)
        $expectedNames=[string[]]@('Ordinal','ObservedUtc','ElapsedMilliseconds','AppWorkingSetBytes','CoreWorkingSetBytes','CombinedWorkingSetBytes','AppPrivateMemoryBytes','CorePrivateMemoryBytes','RuntimeFingerprint','RendererObservation')
        [Array]::Sort($actualNames,[StringComparer]::Ordinal);[Array]::Sort($expectedNames,[StringComparer]::Ordinal)
        if(($actualNames-join "`n")-cne($expectedNames-join "`n")){throw "Resource sample $index properties are not exact."}
        if ($integerTypes -notcontains [Type]::GetTypeCode($sample.Ordinal.GetType()) -or [int64]$sample.Ordinal -ne $index) { throw "Resource sample $index ordinal is not exact." }
        if (-not (Test-V02FiniteNonNegativeNumber $sample.ElapsedMilliseconds)) { throw "Resource sample $index ElapsedMilliseconds must be a finite nonnegative native JSON number." }
        $elapsedDelta = if ($index -eq 0) { [double]$sample.ElapsedMilliseconds } else { [double]$sample.ElapsedMilliseconds - [double]$samples[$index-1].ElapsedMilliseconds }
        if (($index -eq 0 -and $elapsedDelta -gt 250) -or
            ($index -gt 0 -and ($elapsedDelta -lt 249 -or $elapsedDelta -gt 500))) {
            throw "Resource sample $index elapsed interval is outside the approved cadence."
        }
        if ($sample.ObservedUtc -isnot [string] -or [string]$sample.ObservedUtc -notmatch '(?:Z|\+00:00)$') { throw "Resource sample $index ObservedUtc must be a native UTC JSON string." }
        try { $observedUtc=[DateTimeOffset]::Parse([string]$sample.ObservedUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime() }
        catch { throw "Resource sample $index ObservedUtc is invalid." }
        if ($observedUtc -lt $idleStartUtc -or $observedUtc -gt $idleFinishUtc -or ($null -ne $previousObservedUtc -and $observedUtc -lt $previousObservedUtc)) { throw "Resource sample $index timestamp is outside the idle window or regressed." }
        $previousObservedUtc=$observedUtc
        foreach($name in @('AppWorkingSetBytes','CoreWorkingSetBytes','CombinedWorkingSetBytes','AppPrivateMemoryBytes','CorePrivateMemoryBytes')) {
            if ($null -eq $sample.$name -or $integerTypes -notcontains [Type]::GetTypeCode($sample.$name.GetType()) -or [decimal]$sample.$name -lt 0) { throw "Resource sample $index $name must be a nonnegative native JSON integer." }
        }
        if ([decimal]$sample.CombinedWorkingSetBytes -ne ([decimal]$sample.AppWorkingSetBytes + [decimal]$sample.CoreWorkingSetBytes)) { throw "Resource sample $index combined working set contradicts its App/Core values." }
        if ($sample.RuntimeFingerprint -isnot [pscustomobject] -or $sample.RendererObservation -isnot [pscustomobject]) { throw "Resource sample $index must carry fingerprint and renderer objects." }
        if (($sample.RuntimeFingerprint|ConvertTo-Json -Depth 20 -Compress) -cne $startFingerprintJson) { throw "Resource sample $index fingerprint contradicts the stable start/finish fingerprint." }
        $combinedSum += [decimal]$sample.CombinedWorkingSetBytes
        $appSum += [decimal]$sample.AppWorkingSetBytes
        $coreSum += [decimal]$sample.CoreWorkingSetBytes
        $appPrivateSum += [decimal]$sample.AppPrivateMemoryBytes
        $corePrivateSum += [decimal]$sample.CorePrivateMemoryBytes
        if ([int64]$sample.CombinedWorkingSetBytes -gt $combinedMaximumBytes) { $combinedMaximumBytes=[int64]$sample.CombinedWorkingSetBytes }
        if ([int64]$sample.AppWorkingSetBytes -gt $appMaximumBytes) { $appMaximumBytes=[int64]$sample.AppWorkingSetBytes }
        if ([int64]$sample.CoreWorkingSetBytes -gt $coreMaximumBytes) { $coreMaximumBytes=[int64]$sample.CoreWorkingSetBytes }
        if ([int64]$sample.AppPrivateMemoryBytes -gt $appPrivateMaximumBytes) { $appPrivateMaximumBytes=[int64]$sample.AppPrivateMemoryBytes }
        if ([int64]$sample.CorePrivateMemoryBytes -gt $corePrivateMaximumBytes) { $corePrivateMaximumBytes=[int64]$sample.CorePrivateMemoryBytes }
    }
    if ([double]$samples[-1].ElapsedMilliseconds -lt 20000 -or [double]$samples[-1].ElapsedMilliseconds -gt 20250) { throw 'Final resource sample elapsed time must be within 20000..20250 milliseconds.' }
    $recomputedAverage = [Math]::Round([double](($combinedSum / $samples.Count) / 1048576),3)
    $recomputedMaximum = [Math]::Round([double]$combinedMaximumBytes / 1048576,3)
    if ([double]$average -ne $recomputedAverage -or [double]$maximum -ne $recomputedMaximum) {
        throw 'Working-set aggregates contradict the independently recomputed raw Samples.'
    }
    foreach($summary in @(
        @($ResourceMeasurement.App,'AverageWorkingSetMegabytes',[Math]::Round([double](($appSum/$samples.Count)/1048576),3)),
        @($ResourceMeasurement.App,'MaximumWorkingSetMegabytes',[Math]::Round([double]$appMaximumBytes/1048576,3)),
        @($ResourceMeasurement.App,'AveragePrivateMemoryMegabytes',[Math]::Round([double](($appPrivateSum/$samples.Count)/1048576),3)),
        @($ResourceMeasurement.App,'MaximumPrivateMemoryMegabytes',[Math]::Round([double]$appPrivateMaximumBytes/1048576,3)),
        @($ResourceMeasurement.Core,'AverageWorkingSetMegabytes',[Math]::Round([double](($coreSum/$samples.Count)/1048576),3)),
        @($ResourceMeasurement.Core,'MaximumWorkingSetMegabytes',[Math]::Round([double]$coreMaximumBytes/1048576,3)),
        @($ResourceMeasurement.Core,'AveragePrivateMemoryMegabytes',[Math]::Round([double](($corePrivateSum/$samples.Count)/1048576),3)),
        @($ResourceMeasurement.Core,'MaximumPrivateMemoryMegabytes',[Math]::Round([double]$corePrivateMaximumBytes/1048576,3)))) {
        $value=$summary[0].PSObject.Properties[[string]$summary[1]].Value;if(-not(Test-V02FiniteNonNegativeNumber $value)-or[double]$value-ne[double]$summary[2]){throw "Process $($summary[1]) contradicts raw Samples."}
    }

    if ($ResourceMeasurement.WorkingSetTargetPassed -isnot [bool]) {
        throw 'WorkingSetTargetPassed must be a native JSON boolean.'
    }

    $independentlyPassed = $combinedMaximumBytes -le $script:V02WorkingSetTargetBytes
    if ([bool]$ResourceMeasurement.WorkingSetTargetPassed -ne $independentlyPassed) {
        throw 'WorkingSetTargetPassed contradicts the independently recomputed v0.2 working-set result.'
    }
    if (-not $independentlyPassed) {
        throw "Combined maximum working set $combinedMaximumBytes bytes exceeds the exact v0.2 limit of $script:V02WorkingSetTargetMebibytes MiB ($script:V02WorkingSetTargetBytes bytes)."
    }

    return [pscustomobject]@{
        TargetMebibytes = $script:V02WorkingSetTargetMebibytes
        TargetBytes = $script:V02WorkingSetTargetBytes
        Statistic = 'maximum'
        AverageMebibytes = [double]$average
        MaximumMebibytes = [double]$maximum
        MaximumBytes = $combinedMaximumBytes
        Passed = $true
    }
}
