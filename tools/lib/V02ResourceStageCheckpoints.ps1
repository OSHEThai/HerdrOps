Set-StrictMode -Version Latest

$script:V02ResourceStageNames = @(
    'pre-capture',
    'post-initial-captures',
    'post-dashboard-close',
    'post-final-widget-capture',
    'post-cleanup'
)
$script:V02ResourceStagePreparationToleranceMegabytes = 8.0

function ConvertFrom-V02CheckpointJson {
    param([Parameter(Mandatory)][string]$Json)

    $convertCommand = Get-Command ConvertFrom-Json -CommandType Cmdlet
    if ($convertCommand.Parameters.ContainsKey('DateKind')) {
        return $Json | ConvertFrom-Json -DateKind String
    }
    return $Json | ConvertFrom-Json
}

function Assert-V02CheckpointProperty {
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Context
    )

    if ($null -eq $Object -or -not ($Object.PSObject.Properties.Name -contains $Name)) {
        throw "$Context omitted required property '$Name'."
    }
}

function Test-V02FiniteNonnegativeNumber {
    param([Parameter(Mandatory)]$Value)

    if ($null -eq $Value) { return $false }
    $numericTypeCodes = @(
        [TypeCode]::Byte,
        [TypeCode]::SByte,
        [TypeCode]::UInt16,
        [TypeCode]::UInt32,
        [TypeCode]::UInt64,
        [TypeCode]::Int16,
        [TypeCode]::Int32,
        [TypeCode]::Int64,
        [TypeCode]::Decimal,
        [TypeCode]::Single,
        [TypeCode]::Double
    )
    if ($numericTypeCodes -notcontains [Type]::GetTypeCode($Value.GetType())) {
        return $false
    }

    $number = [double]$Value
    return -not [double]::IsNaN($number) -and
        -not [double]::IsInfinity($number) -and
        $number -ge 0
}

function Test-V02NativeInteger {
    param([Parameter(Mandatory)]$Value)

    if ($null -eq $Value) { return $false }
    return @(
        [TypeCode]::Byte,
        [TypeCode]::SByte,
        [TypeCode]::UInt16,
        [TypeCode]::UInt32,
        [TypeCode]::UInt64,
        [TypeCode]::Int16,
        [TypeCode]::Int32,
        [TypeCode]::Int64
    ) -contains [Type]::GetTypeCode($Value.GetType())
}

function ConvertFrom-V02UtcTimestamp {
    param(
        [Parameter(Mandatory)]$Value,
        [Parameter(Mandatory)][string]$Context
    )

    if ($Value -isnot [string] -or
        $Value -notmatch '(?:Z|\+00:00)$') {
        throw "$Context must be an exact UTC JSON string ending in 'Z' or '+00:00'."
    }
    try {
        return ([DateTimeOffset]::Parse(
                $Value,
                [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::RoundtripKind)).ToUniversalTime()
    }
    catch {
        throw "$Context is not a valid round-trip timestamp: $($_.Exception.Message)"
    }
}

function Assert-V02ResourceStageCheckpoints {
    param([Parameter(Mandatory)]$AppReport)

    Assert-V02CheckpointProperty -Object $AppReport -Name 'StartedUtc' -Context 'App report'
    Assert-V02CheckpointProperty -Object $AppReport -Name 'FinishedUtc' -Context 'App report'
    Assert-V02CheckpointProperty -Object $AppReport -Name 'ResourceMeasurement' -Context 'App report'
    $measurement = $AppReport.ResourceMeasurement
    Assert-V02CheckpointProperty -Object $measurement -Name 'App' -Context 'Resource measurement'
    Assert-V02CheckpointProperty -Object $measurement -Name 'Preparation' -Context 'Resource measurement'
    Assert-V02CheckpointProperty -Object $measurement -Name 'StageCheckpoints' -Context 'Resource measurement'

    $checkpoints = @($measurement.StageCheckpoints)
    if ($checkpoints.Count -ne $script:V02ResourceStageNames.Count) {
        throw "Resource diagnostics require exactly $($script:V02ResourceStageNames.Count) stage checkpoints; observed $($checkpoints.Count)."
    }

    Assert-V02CheckpointProperty -Object $measurement.App -Name 'ProcessId' -Context 'Measured App identity'
    Assert-V02CheckpointProperty -Object $measurement.App -Name 'ProcessStartUtc' -Context 'Measured App identity'
    if (-not (Test-V02NativeInteger $measurement.App.ProcessId) -or
        [long]$measurement.App.ProcessId -le 0) {
        throw 'Measured App identity PID must be a positive native JSON integer.'
    }
    $runStartedUtc = ConvertFrom-V02UtcTimestamp $AppReport.StartedUtc 'App report StartedUtc'
    $runFinishedUtc = ConvertFrom-V02UtcTimestamp $AppReport.FinishedUtc 'App report FinishedUtc'
    $expectedAppStartUtc = ConvertFrom-V02UtcTimestamp $measurement.App.ProcessStartUtc 'Measured App ProcessStartUtc'
    if ($runFinishedUtc -lt $runStartedUtc) {
        throw 'Resource diagnostic run window is time-inverted.'
    }

    $previousObservedUtc = $null
    for ($index = 0; $index -lt $checkpoints.Count; $index++) {
        $checkpoint = $checkpoints[$index]
        $context = "Resource stage checkpoint $index"
        foreach ($propertyName in @(
                'Stage',
                'ObservedUtc',
                'AppProcessId',
                'AppProcessStartUtc',
                'AppWorkingSetMegabytes',
                'AppPrivateMemoryMegabytes',
                'AppPagedMemoryMegabytes',
                'ManagedHeapMegabytes')) {
            Assert-V02CheckpointProperty -Object $checkpoint -Name $propertyName -Context $context
        }

        $expectedStage = $script:V02ResourceStageNames[$index]
        if ([string]$checkpoint.Stage -cne $expectedStage) {
            throw "$context has unexpected stage '$($checkpoint.Stage)'; expected '$expectedStage'."
        }

        $observedUtc = ConvertFrom-V02UtcTimestamp $checkpoint.ObservedUtc "$context ObservedUtc"
        $appStartUtc = ConvertFrom-V02UtcTimestamp $checkpoint.AppProcessStartUtc "$context AppProcessStartUtc"
        if ($observedUtc -lt $runStartedUtc -or $observedUtc -gt $runFinishedUtc) {
            throw "$context timestamp is outside the App report run window."
        }
        if ($null -ne $previousObservedUtc -and $observedUtc -lt $previousObservedUtc) {
            throw "$context timestamp regressed relative to the preceding checkpoint."
        }
        $previousObservedUtc = $observedUtc

        if (-not (Test-V02NativeInteger $checkpoint.AppProcessId) -or
            [long]$checkpoint.AppProcessId -le 0) {
            throw "$context App PID must be a positive native JSON integer."
        }
        if ([long]$checkpoint.AppProcessId -ne [long]$measurement.App.ProcessId) {
            throw "$context App PID does not match the measured App identity."
        }
        if ($appStartUtc.UtcDateTime.Ticks -ne $expectedAppStartUtc.UtcDateTime.Ticks) {
            throw "$context App start time does not match the measured App identity."
        }

        foreach ($counterName in @(
                'AppWorkingSetMegabytes',
                'AppPrivateMemoryMegabytes',
                'AppPagedMemoryMegabytes',
                'ManagedHeapMegabytes')) {
            if (-not (Test-V02FiniteNonnegativeNumber $checkpoint.$counterName)) {
                throw "$context counter '$counterName' must be a finite nonnegative native JSON number."
            }
        }
    }

    $postCleanup = $checkpoints[-1]
    $preparation = $measurement.Preparation
    foreach ($binding in @(
            @('AppWorkingSetMegabytes', 'AppWorkingSetAfterMegabytes'),
            @('AppPrivateMemoryMegabytes', 'AppPrivateMemoryAfterMegabytes'),
            @('ManagedHeapMegabytes', 'ManagedHeapAfterMegabytes'))) {
        $checkpointName = $binding[0]
        $preparationName = $binding[1]
        Assert-V02CheckpointProperty -Object $preparation -Name $preparationName -Context 'Resource preparation'
        if (-not (Test-V02FiniteNonnegativeNumber $preparation.$preparationName)) {
            throw "Resource preparation counter '$preparationName' must be a finite nonnegative native JSON number."
        }
        $delta = [Math]::Abs(
            [double]$postCleanup.$checkpointName - [double]$preparation.$preparationName)
        if ($delta -gt $script:V02ResourceStagePreparationToleranceMegabytes) {
            throw "Post-cleanup '$checkpointName' differs from preparation '$preparationName' by $delta MB; tolerance is $($script:V02ResourceStagePreparationToleranceMegabytes) MB."
        }
    }

    return $checkpoints
}
