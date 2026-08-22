[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib/V02WorkingSetBudgetPolicy.ps1')

$script:caseCount = 0

function New-ValidMeasurement {
    param(
        [object]$Average = $null,
        [object]$Maximum = $null,
        [long]$MaximumBytes = (254L * 1048576L),
        [object]$Target = 255,
        [object]$TargetBytes = 267386880L,
        [object]$Statistic = 'maximum',
        [object]$Passed = $true
    )

    if($null-ne$Maximum){$MaximumBytes=[long][Math]::Round([double]$Maximum*1048576.0)}
    $roundedMaximum=[Math]::Round([double]$MaximumBytes/1048576.0,3)
    $Maximum=$roundedMaximum
    if($null-eq$Average){$Average=$roundedMaximum}
    $fingerprint=[pscustomobject]@{Sequence=1}
    $samples=@()
    for($index=0;$index-lt81;$index++){
        $app=[long][Math]::Floor($MaximumBytes*0.6);$core=$MaximumBytes-$app
        $sampleFingerprint=$fingerprint|ConvertTo-Json|ConvertFrom-Json
        $samples += [pscustomobject]@{Ordinal=$index;ObservedUtc=([datetimeoffset]'2026-08-22T00:00:00Z').AddMilliseconds(250*$index).ToString('O');ElapsedMilliseconds=[double](250*$index);AppWorkingSetBytes=$app;CoreWorkingSetBytes=$core;CombinedWorkingSetBytes=$MaximumBytes;AppPrivateMemoryBytes=[long]($app/2);CorePrivateMemoryBytes=[long]($core/2);RuntimeFingerprint=$sampleFingerprint;RendererObservation=[pscustomobject]@{Phase="idle-resource-sample:$index"}}
    }
    $appAverage=[Math]::Round([double]$samples[0].AppWorkingSetBytes/1048576,3);$coreAverage=[Math]::Round([double]$samples[0].CoreWorkingSetBytes/1048576,3)
    $appPrivate=[Math]::Round([double]$samples[0].AppPrivateMemoryBytes/1048576,3);$corePrivate=[Math]::Round([double]$samples[0].CorePrivateMemoryBytes/1048576,3)
    return [pscustomobject]@{
        DurationSeconds=20
        SampleIntervalMilliseconds=250
        SampleCount=81
        Samples=$samples
        StartFingerprint=$fingerprint
        FinishFingerprint=$fingerprint
        StateSequenceStable=$true
        RuntimeEventCountStable=$true
        RuntimeFingerprintStable=$true
        FirstFingerprintChange=$null
        HerdrConnectedThroughoutSample=$true
        IdleSampleStartRenderer=[pscustomobject]@{ObservedUtc='2026-08-22T00:00:00.0000000Z'}
        IdleSampleFinishRenderer=[pscustomobject]@{ObservedUtc='2026-08-22T00:00:20.0000000Z'}
        App=[pscustomobject]@{AverageWorkingSetMegabytes=$appAverage;MaximumWorkingSetMegabytes=$appAverage;AveragePrivateMemoryMegabytes=$appPrivate;MaximumPrivateMemoryMegabytes=$appPrivate}
        Core=[pscustomobject]@{AverageWorkingSetMegabytes=$coreAverage;MaximumWorkingSetMegabytes=$coreAverage;AveragePrivateMemoryMegabytes=$corePrivate;MaximumPrivateMemoryMegabytes=$corePrivate}
        WorkingSetTargetMegabytes = $Target
        WorkingSetTargetBytes = $TargetBytes
        WorkingSetStatistic = $Statistic
        CombinedAverageWorkingSetMegabytes = $Average
        CombinedMaximumWorkingSetMegabytes = $Maximum
        WorkingSetTargetPassed = $Passed
    }
}

function Assert-Pass {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][object]$Evidence)
    $script:caseCount++
    $result = Assert-V02WorkingSetBudgetEvidence -ResourceMeasurement $Evidence
    if (-not $result.Passed) {
        throw "$Name did not return Passed=true."
    }
    Write-Host "PASS: $Name"
}

function Assert-Fail {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][scriptblock]$Action)
    $script:caseCount++
    try {
        & $Action
    }
    catch {
        Write-Host "PASS: $Name rejected: $($_.Exception.Message)"
        return
    }
    throw "$Name unexpectedly passed."
}

function Assert-FailContains {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)][string[]]$ExpectedSubstrings
    )
    $script:caseCount++
    try {
        & $Action
    }
    catch {
        $actualMessage = $_.Exception.Message
        foreach ($expected in $ExpectedSubstrings) {
            if (-not $actualMessage.Contains($expected)) {
                throw "$Name rejected but message did not contain expected substring '$expected'. Actual message: $actualMessage"
            }
        }
        Write-Host "PASS: $Name rejected: $actualMessage"
        return
    }
    throw "$Name unexpectedly passed."
}

Assert-Pass '254 MiB is below the exact limit' (New-ValidMeasurement -Maximum 254.0)
Assert-Pass '255 MiB is exactly the limit' (New-ValidMeasurement -Maximum 255.0)
Assert-Pass 'exact 20000 ms final cadence boundary' (New-ValidMeasurement)
$m=New-ValidMeasurement;$elapsed=200.0;for($index=0;$index-lt81;$index++){if($index-gt0){$elapsed=[Math]::Max([double](250*$index),$elapsed+249.0)};$m.Samples[$index].ElapsedMilliseconds=$elapsed;$m.Samples[$index].ObservedUtc=([datetimeoffset]'2026-08-22T00:00:00Z').AddMilliseconds($elapsed).ToString('O')};$m.IdleSampleFinishRenderer.ObservedUtc='2026-08-22T00:00:20.2500000Z';Assert-Pass 'lawful delayed cadence preserves nominal and prior boundaries' $m
$m=New-ValidMeasurement;$elapsed=0.0;for($index=0;$index-lt81;$index++){if($index-eq1){$elapsed=500.0}elseif($index-gt1){$elapsed=[Math]::Max([double](250*$index),$elapsed+249.0)};$m.Samples[$index].ElapsedMilliseconds=$elapsed;$m.Samples[$index].ObservedUtc=([datetimeoffset]'2026-08-22T00:00:00Z').AddMilliseconds($elapsed).ToString('O')};$m.IdleSampleFinishRenderer.ObservedUtc='2026-08-22T00:00:20.2500000Z';Assert-Pass 'exact 500 ms delta boundary recovers lawfully' $m
$m=New-ValidMeasurement;$m.Samples[80].ElapsedMilliseconds=20250.0;$m.Samples[80].ObservedUtc='2026-08-22T00:00:20.2500000Z';$m.IdleSampleFinishRenderer.ObservedUtc='2026-08-22T00:00:20.2500000Z';Assert-Pass 'exact 20250 ms final cadence boundary' $m
Assert-Fail 'value above 255 MiB' { Assert-V02WorkingSetBudgetEvidence (New-ValidMeasurement -Maximum 255.0001 -Passed $false) }
Assert-Fail 'wrong reported MiB target' { Assert-V02WorkingSetBudgetEvidence (New-ValidMeasurement -Target 256) }
Assert-Fail 'wrong reported byte target' { Assert-V02WorkingSetBudgetEvidence (New-ValidMeasurement -TargetBytes 267386879L) }
Assert-Fail 'numeric-string target' { Assert-V02WorkingSetBudgetEvidence (New-ValidMeasurement -Target '255') }
$missingStatistic=New-ValidMeasurement;$missingStatistic.PSObject.Properties.Remove('WorkingSetStatistic')
Assert-Fail 'missing statistic' { Assert-V02WorkingSetBudgetEvidence $missingStatistic }
Assert-Fail 'wrong statistic' { Assert-V02WorkingSetBudgetEvidence (New-ValidMeasurement -Statistic 'average') }
Assert-Fail 'non-string statistic' { Assert-V02WorkingSetBudgetEvidence (New-ValidMeasurement -Statistic 1) }
Assert-Fail 'producer false below limit' { Assert-V02WorkingSetBudgetEvidence (New-ValidMeasurement -Maximum 254.0 -Passed $false) }
Assert-Fail 'producer false at limit' { Assert-V02WorkingSetBudgetEvidence (New-ValidMeasurement -Maximum 255.0 -Passed $false) }
Assert-Fail 'producer true above limit' { Assert-V02WorkingSetBudgetEvidence (New-ValidMeasurement -Maximum 256.0 -Passed $true) }
Assert-Fail 'string producer boolean' { Assert-V02WorkingSetBudgetEvidence (New-ValidMeasurement -Passed 'true') }
$m=New-ValidMeasurement;$m.CombinedAverageWorkingSetMegabytes=-1.0;Assert-Fail 'negative average' { Assert-V02WorkingSetBudgetEvidence $m }
$m=New-ValidMeasurement;$m.CombinedMaximumWorkingSetMegabytes=-1.0;Assert-Fail 'negative maximum' { Assert-V02WorkingSetBudgetEvidence $m }
$m=New-ValidMeasurement;$m.CombinedAverageWorkingSetMegabytes=255.0;$m.CombinedMaximumWorkingSetMegabytes=254.0;Assert-Fail 'maximum below average' { Assert-V02WorkingSetBudgetEvidence $m }
$m=New-ValidMeasurement;$m.CombinedAverageWorkingSetMegabytes=[double]::NaN;Assert-Fail 'NaN average' { Assert-V02WorkingSetBudgetEvidence $m }
$m=New-ValidMeasurement;$m.CombinedMaximumWorkingSetMegabytes=[double]::NaN;Assert-Fail 'NaN maximum' { Assert-V02WorkingSetBudgetEvidence $m }
$m=New-ValidMeasurement;$m.CombinedMaximumWorkingSetMegabytes=[double]::PositiveInfinity;Assert-Fail 'positive infinity maximum' { Assert-V02WorkingSetBudgetEvidence $m }
$m=New-ValidMeasurement;$m.CombinedAverageWorkingSetMegabytes=[double]::NegativeInfinity;Assert-Fail 'negative infinity average' { Assert-V02WorkingSetBudgetEvidence $m }
$m=New-ValidMeasurement;$m.CombinedMaximumWorkingSetMegabytes='254';Assert-Fail 'numeric-string maximum' { Assert-V02WorkingSetBudgetEvidence $m }
$m=New-ValidMeasurement;$m.SampleCount=80;Assert-Fail 'wrong exact sample count' { Assert-V02WorkingSetBudgetEvidence $m }
$m=New-ValidMeasurement;$m.Samples[2].Ordinal=3;Assert-Fail 'wrong sample ordinal' { Assert-V02WorkingSetBudgetEvidence $m }
$m=New-ValidMeasurement;$m.Samples[2].ObservedUtc='2026-08-21T23:59:59Z';Assert-Fail 'sample timestamp outside idle window' { Assert-V02WorkingSetBudgetEvidence $m }
$m=New-ValidMeasurement;$m.Samples[2].AppWorkingSetBytes=-1;Assert-Fail 'negative raw byte counter' { Assert-V02WorkingSetBudgetEvidence $m }
$m=New-ValidMeasurement;$m.Samples[2].CombinedWorkingSetBytes++;Assert-Fail 'contradictory combined raw bytes' { Assert-V02WorkingSetBudgetEvidence $m }
$m=New-ValidMeasurement;$m.Samples[2].RuntimeFingerprint.Sequence=2;Assert-Fail 'raw sample fingerprint drift' { Assert-V02WorkingSetBudgetEvidence $m }
$m=New-ValidMeasurement;$m.CombinedAverageWorkingSetMegabytes=253;$m.CombinedMaximumWorkingSetMegabytes=253;Assert-Fail 'aggregate contradicts raw samples' { Assert-V02WorkingSetBudgetEvidence $m }
$m=New-ValidMeasurement;$m.App.MaximumWorkingSetMegabytes++;Assert-Fail 'process summary contradicts raw samples' { Assert-V02WorkingSetBudgetEvidence $m }
Assert-Fail 'one raw byte above exact limit' { Assert-V02WorkingSetBudgetEvidence (New-ValidMeasurement -MaximumBytes 267386881L -Passed $false) }
$m=New-ValidMeasurement;$m.IdleSampleFinishRenderer.ObservedUtc='2026-08-22T00:00:19.9990000Z';Assert-Fail 'observed idle window shorter than 20 seconds' { Assert-V02WorkingSetBudgetEvidence $m }
$m=New-ValidMeasurement;$m.RuntimeFingerprintStable='false';Assert-Fail 'string stable aggregate' { Assert-V02WorkingSetBudgetEvidence $m }
$m=New-ValidMeasurement;$m.FirstFingerprintChange=[pscustomobject]@{};Assert-Fail 'non-null first fingerprint change' { Assert-V02WorkingSetBudgetEvidence $m }
$m=New-ValidMeasurement;$m.Samples[0].ElapsedMilliseconds=251.0;Assert-FailContains 'baseline elapsed sample exceeds 250 ms boundary' { Assert-V02WorkingSetBudgetEvidence $m } @(
    "Resource sample 0 failed predicate 'baseline-elapsed-at-most-250'.",
    'PreviousElapsedMilliseconds=NONE CurrentElapsedMilliseconds=251',
    'PreviousObservedUtc=NONE CurrentObservedUtc=2026-08-22T00:00:00.0000000+00:00')
$m=New-ValidMeasurement;$m.Samples[2].ElapsedMilliseconds=498;Assert-FailContains 'elapsed sample precedes nominal 250 ms boundary' { Assert-V02WorkingSetBudgetEvidence $m } @(
    "Resource sample 2 failed predicate 'elapsed-at-or-after-nominal-boundary'.",
    'PreviousElapsedMilliseconds=250 CurrentElapsedMilliseconds=498',
    'PreviousObservedUtc=2026-08-22T00:00:00.2500000+00:00 CurrentObservedUtc=2026-08-22T00:00:00.5000000+00:00')
$m=New-ValidMeasurement;$m.Samples[1].ElapsedMilliseconds=500.0;$m.Samples[2].ElapsedMilliseconds=748.999;Assert-FailContains 'fractional elapsed delta below 249 ms' { Assert-V02WorkingSetBudgetEvidence $m } @(
    "Resource sample 2 failed predicate 'adjacent-elapsed-delta-at-least-249'.",
    'PreviousElapsedMilliseconds=500 CurrentElapsedMilliseconds=748.999',
    'PreviousObservedUtc=2026-08-22T00:00:00.2500000+00:00 CurrentObservedUtc=2026-08-22T00:00:00.5000000+00:00')
$m=New-ValidMeasurement;$m.Samples[2].ElapsedMilliseconds=[double]::NaN;Assert-Fail 'non-finite elapsed sample' { Assert-V02WorkingSetBudgetEvidence $m }
$m=New-ValidMeasurement;$m.Samples[2].ElapsedMilliseconds=1001;Assert-FailContains 'oversized elapsed sample gap' { Assert-V02WorkingSetBudgetEvidence $m } @(
    "Resource sample 2 failed predicate 'adjacent-elapsed-delta-at-most-500'.",
    'PreviousElapsedMilliseconds=250 CurrentElapsedMilliseconds=1001',
    'PreviousObservedUtc=2026-08-22T00:00:00.2500000+00:00 CurrentObservedUtc=2026-08-22T00:00:00.5000000+00:00')
$m=New-ValidMeasurement;$m.Samples[2].ElapsedMilliseconds=750.001;Assert-FailContains 'fractional elapsed delta above 500 ms' { Assert-V02WorkingSetBudgetEvidence $m } @(
    "Resource sample 2 failed predicate 'adjacent-elapsed-delta-at-most-500'.",
    'PreviousElapsedMilliseconds=250 CurrentElapsedMilliseconds=750.001',
    'PreviousObservedUtc=2026-08-22T00:00:00.2500000+00:00 CurrentObservedUtc=2026-08-22T00:00:00.5000000+00:00')
$m=New-ValidMeasurement;for($index=1;$index-lt80;$index++){$m.Samples[$index].ElapsedMilliseconds=[double](249*$index);$m.Samples[$index].ObservedUtc=([datetimeoffset]'2026-08-22T00:00:00Z').AddMilliseconds(249*$index).ToString('O')};$m.Samples[80].ElapsedMilliseconds=20000.0;Assert-FailContains 'intermediate elapsed samples below nominal boundaries' { Assert-V02WorkingSetBudgetEvidence $m } @(
    "Resource sample 1 failed predicate 'elapsed-at-or-after-nominal-boundary'.",
    'PreviousElapsedMilliseconds=0 CurrentElapsedMilliseconds=249',
    'PreviousObservedUtc=2026-08-22T00:00:00.0000000+00:00 CurrentObservedUtc=2026-08-22T00:00:00.2490000+00:00')
$m=New-ValidMeasurement;$m.Samples[79].ElapsedMilliseconds=20000;$m.Samples[80].ElapsedMilliseconds=20251;Assert-FailContains 'final elapsed sample too long' { Assert-V02WorkingSetBudgetEvidence $m } @(
    "Resource sample 80 failed predicate 'final-elapsed-within-20000-20250'.",
    'PreviousElapsedMilliseconds=20000 CurrentElapsedMilliseconds=20251',
    'PreviousObservedUtc=2026-08-22T00:00:19.7500000+00:00 CurrentObservedUtc=2026-08-22T00:00:20.0000000+00:00')

if ($script:caseCount -ne 45) {
    throw "Unexpected working-set policy case count: $script:caseCount."
}

Write-Host "All $script:caseCount v0.2 working-set policy cases passed."
