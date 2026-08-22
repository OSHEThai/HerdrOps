[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'V02ResourceStageCheckpoints.ps1')

function New-ValidV02ResourceStageReport {
    $stages = @(
        'pre-capture',
        'post-initial-captures',
        'post-dashboard-close',
        'post-final-widget-capture',
        'post-cleanup'
    )
    $checkpoints = @()
    for ($index = 0; $index -lt $stages.Count; $index++) {
        $checkpoints += [ordered]@{
            Stage                       = $stages[$index]
            ObservedUtc                 = ('2026-08-22T00:00:0{0}.0000000+00:00' -f ($index + 1))
            AppProcessId                = 4100
            AppProcessStartUtc          = '2026-08-21T23:59:00.0000000+00:00'
            AppWorkingSetMegabytes      = 120.0 + $index
            AppPrivateMemoryMegabytes   = 90.0 + $index
            AppPagedMemoryMegabytes     = 80.0 + $index
            ManagedHeapMegabytes        = 10.0 + $index
        }
    }

    $fixture = [ordered]@{
        StartedUtc = '2026-08-22T00:00:00.0000000+00:00'
        FinishedUtc = '2026-08-22T00:00:10.0000000+00:00'
        ResourceMeasurement = [ordered]@{
            App = [ordered]@{
                ProcessId = 4100
                ProcessStartUtc = '2026-08-21T23:59:00.0000000+00:00'
            }
            Preparation = [ordered]@{
                AppWorkingSetAfterMegabytes = 124.0
                AppPrivateMemoryAfterMegabytes = 94.0
                ManagedHeapAfterMegabytes = 14.0
            }
            StageCheckpoints = $checkpoints
        }
    }

    return ConvertFrom-V02CheckpointJson ($fixture | ConvertTo-Json -Depth 12)
}

function Assert-V02NegativeFixtureRejected {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Mutate
    )

    $fixture = New-ValidV02ResourceStageReport
    & $Mutate $fixture
    $rejected = $false
    try {
        $null = Assert-V02ResourceStageCheckpoints -AppReport $fixture
    }
    catch {
        $rejected = $true
    }
    if (-not $rejected) {
        throw "Hostile resource-stage fixture '$Name' was accepted."
    }
}

$positive = New-ValidV02ResourceStageReport
$accepted = @(Assert-V02ResourceStageCheckpoints -AppReport $positive)
if ($accepted.Count -ne 5) {
    throw 'The valid resource-stage JSON fixture did not return five checkpoints.'
}

$negativeCases = @(
    @('missing stage', { param($r) $r.ResourceMeasurement.StageCheckpoints = @($r.ResourceMeasurement.StageCheckpoints | Select-Object -First 4) }),
    @('extra stage', { param($r) $r.ResourceMeasurement.StageCheckpoints += $r.ResourceMeasurement.StageCheckpoints[-1] }),
    @('reordered stage', {
        param($r)
        $copy = @($r.ResourceMeasurement.StageCheckpoints)
        $temporary = $copy[1]
        $copy[1] = $copy[2]
        $copy[2] = $temporary
        $r.ResourceMeasurement.StageCheckpoints = $copy
    }),
    @('duplicate stage', { param($r) $r.ResourceMeasurement.StageCheckpoints[2].Stage = 'post-initial-captures' }),
    @('wrong PID', { param($r) $r.ResourceMeasurement.StageCheckpoints[1].AppProcessId = 4101 }),
    @('PID numeric string', { param($r) $r.ResourceMeasurement.StageCheckpoints[1].AppProcessId = '4100' }),
    @('wrong process start', { param($r) $r.ResourceMeasurement.StageCheckpoints[1].AppProcessStartUtc = '2026-08-21T23:58:00.0000000+00:00' }),
    @('invalid timestamp', { param($r) $r.ResourceMeasurement.StageCheckpoints[1].ObservedUtc = 'not-a-timestamp' }),
    @('non-UTC timestamp', { param($r) $r.ResourceMeasurement.StageCheckpoints[1].ObservedUtc = '2026-08-22T07:00:02.0000000+07:00' }),
    @('timestamp outside run window', { param($r) $r.ResourceMeasurement.StageCheckpoints[1].ObservedUtc = '2026-08-22T00:00:11.0000000+00:00' }),
    @('timestamp out of order', { param($r) $r.ResourceMeasurement.StageCheckpoints[2].ObservedUtc = '2026-08-22T00:00:01.0000000+00:00' }),
    @('NaN counter', { param($r) $r.ResourceMeasurement.StageCheckpoints[1].AppWorkingSetMegabytes = [double]::NaN }),
    @('Infinity counter', { param($r) $r.ResourceMeasurement.StageCheckpoints[1].AppPrivateMemoryMegabytes = [double]::PositiveInfinity }),
    @('negative counter', { param($r) $r.ResourceMeasurement.StageCheckpoints[1].ManagedHeapMegabytes = -0.001 }),
    @('numeric string counter', { param($r) $r.ResourceMeasurement.StageCheckpoints[1].AppPagedMemoryMegabytes = '82.0' }),
    @('post-cleanup mismatch', { param($r) $r.ResourceMeasurement.Preparation.AppWorkingSetAfterMegabytes = 150.0 })
)

foreach ($negativeCase in $negativeCases) {
    Assert-V02NegativeFixtureRejected -Name $negativeCase[0] -Mutate $negativeCase[1]
}

Write-Output "V02 resource-stage checkpoint self-tests passed: 1 positive, $($negativeCases.Count) hostile negatives."
