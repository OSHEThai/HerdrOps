Set-StrictMode -Version Latest

$script:V02RendererPolicyId = 'software-only-process-wide'
$script:V02ExpectedWpfProcessRenderMode = 'SoftwareOnly'
$script:V02RendererStageNames = @('pre-capture','post-initial-captures','post-dashboard-close','post-final-widget-capture','post-cleanup')

function Assert-V02RendererProperty {
    param([Parameter(Mandatory)]$Object,[Parameter(Mandatory)][string]$Name,[Parameter(Mandatory)][string]$Context)
    if ($null -eq $Object -or -not ($Object.PSObject.Properties.Name -contains $Name)) { throw "$Context omitted '$Name'." }
}

function Assert-V02RendererExactProperties {
    param([Parameter(Mandatory)]$Object,[Parameter(Mandatory)][string[]]$Names,[Parameter(Mandatory)][string]$Context)
    if ($null -eq $Object -or $Object -isnot [pscustomobject]) { throw "$Context must be a JSON object." }
    $actual=[string[]]@($Object.PSObject.Properties.Name);$expected=[string[]]@($Names)
    [Array]::Sort($actual,[StringComparer]::Ordinal);[Array]::Sort($expected,[StringComparer]::Ordinal)
    if(($actual-join "`n")-cne($expected-join "`n")){throw "$Context properties are not exact."}
}

function ConvertFrom-V02RendererUtc {
    param([Parameter(Mandatory)]$Value,[Parameter(Mandatory)][string]$Context)
    if ($Value -isnot [string] -or $Value -notmatch '(?:Z|\+00:00)$') { throw "$Context must be a native UTC JSON string." }
    try { return ([DateTimeOffset]::Parse($Value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)).ToUniversalTime() }
    catch { throw "$Context is not a valid round-trip timestamp." }
}

function Assert-V02SoftwareOnlyObservation {
    param(
        [Parameter(Mandatory)]$Observation,
        [Parameter(Mandatory)][string]$ExpectedPhase,
        [Parameter(Mandatory)][string]$Context
    )
    Assert-V02RendererExactProperties $Observation @('Phase','ObservedUtc','WpfProcessRenderMode','RenderTier','SoftwareOnlyConfirmed') $Context
    if ($Observation.Phase -isnot [string] -or [string]$Observation.Phase -cne $ExpectedPhase) { throw "$Context phase is not exact." }
    if ($Observation.WpfProcessRenderMode -isnot [string] -or [string]$Observation.WpfProcessRenderMode -cne $script:V02ExpectedWpfProcessRenderMode) { throw "$Context did not observe SoftwareOnly." }
    if ($Observation.SoftwareOnlyConfirmed -isnot [bool] -or -not [bool]$Observation.SoftwareOnlyConfirmed) { throw "$Context SoftwareOnlyConfirmed must be native boolean true." }
    $integerTypes = @([TypeCode]::Byte,[TypeCode]::SByte,[TypeCode]::UInt16,[TypeCode]::UInt32,[TypeCode]::UInt64,[TypeCode]::Int16,[TypeCode]::Int32,[TypeCode]::Int64)
    if ($null -eq $Observation.RenderTier -or $integerTypes -notcontains [Type]::GetTypeCode($Observation.RenderTier.GetType()) -or [int64]$Observation.RenderTier -lt 0) { throw "$Context RenderTier diagnostic must be a nonnegative native JSON integer." }
    return ConvertFrom-V02RendererUtc $Observation.ObservedUtc "$Context ObservedUtc"
}

function Assert-V02RendererEvidence {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$AppReport)

    foreach ($name in @('StartedUtc','FinishedUtc','RendererEvidence','ResourceMeasurement')) { Assert-V02RendererProperty $AppReport $name 'App report' }
    $runStart = ConvertFrom-V02RendererUtc $AppReport.StartedUtc 'App report StartedUtc'
    $runFinish = ConvertFrom-V02RendererUtc $AppReport.FinishedUtc 'App report FinishedUtc'
    if ($runFinish -lt $runStart) { throw 'App renderer evidence run window is inverted.' }
    $evidence = $AppReport.RendererEvidence
    Assert-V02RendererExactProperties $evidence @('PolicyId','ExpectedWpfProcessRenderMode','Startup','PreFirstWindow','ResourceStages','IdleSampleStart','IdleSamples','IdleSampleFinish','SoftwareOnlyThroughout') 'Renderer evidence'
    if ($evidence.PolicyId -isnot [string] -or [string]$evidence.PolicyId -cne $script:V02RendererPolicyId) { throw 'Renderer policy ID is not exact.' }
    if ($evidence.ExpectedWpfProcessRenderMode -isnot [string] -or [string]$evidence.ExpectedWpfProcessRenderMode -cne $script:V02ExpectedWpfProcessRenderMode) { throw 'Expected WPF process render mode is not exact.' }
    if ($evidence.SoftwareOnlyThroughout -isnot [bool] -or -not [bool]$evidence.SoftwareOnlyThroughout) { throw 'SoftwareOnlyThroughout must be native boolean true.' }

    $startup = Assert-V02SoftwareOnlyObservation $evidence.Startup 'app-constructor-before-initialize-component' 'Renderer startup'
    $preFirstWindow = Assert-V02SoftwareOnlyObservation $evidence.PreFirstWindow 'runtime-evidence-pre-first-window' 'Renderer pre-first-window'
    if ($startup -gt $preFirstWindow -or $preFirstWindow -gt $runStart) { throw 'Renderer startup/pre-first-window timestamps are not ordered before the evidence run.' }

    $measurement = $AppReport.ResourceMeasurement
    foreach ($name in @('SampleCount','Samples','StageCheckpoints','IdleSampleStartRenderer','IdleSampleRendererObservations','IdleSampleFinishRenderer','SoftwareOnlyThroughoutIdleSample')) { Assert-V02RendererProperty $measurement $name 'Resource measurement' }
    if ($measurement.SoftwareOnlyThroughoutIdleSample -isnot [bool] -or -not [bool]$measurement.SoftwareOnlyThroughoutIdleSample) { throw 'SoftwareOnlyThroughoutIdleSample must be native boolean true.' }
    $checkpoints = @($measurement.StageCheckpoints)
    $resourceStages = @($evidence.ResourceStages)
    if ($checkpoints.Count -ne $script:V02RendererStageNames.Count -or $resourceStages.Count -ne $script:V02RendererStageNames.Count) { throw 'Renderer evidence requires exactly five resource stages.' }

    $previous = $runStart
    for ($index = 0; $index -lt $script:V02RendererStageNames.Count; $index++) {
        $stage = $script:V02RendererStageNames[$index]
        if ([string]$checkpoints[$index].Stage -cne $stage) { throw "Renderer checkpoint $index has unexpected stage." }
        Assert-V02RendererProperty $checkpoints[$index] 'RendererObservation' "Renderer checkpoint $index"
        $checkpointTime = Assert-V02SoftwareOnlyObservation $checkpoints[$index].RendererObservation "resource-stage:$stage" "Renderer checkpoint $index"
        $summaryTime = Assert-V02SoftwareOnlyObservation $resourceStages[$index] "resource-stage:$stage" "Renderer summary stage $index"
        foreach ($name in @('Phase','ObservedUtc','WpfProcessRenderMode','RenderTier','SoftwareOnlyConfirmed')) {
            if ([string]$checkpoints[$index].RendererObservation.$name -cne [string]$resourceStages[$index].$name) { throw "Renderer summary stage $index contradicts its checkpoint observation." }
        }
        if ($checkpointTime -lt $previous -or $checkpointTime -gt $runFinish -or $summaryTime.UtcDateTime.Ticks -ne $checkpointTime.UtcDateTime.Ticks) { throw "Renderer stage $index timestamp is outside exact order/run window." }
        $previous = $checkpointTime
    }

    $idleStart = Assert-V02SoftwareOnlyObservation $measurement.IdleSampleStartRenderer 'idle-resource-sample:start' 'Idle renderer start'
    $idleFinish = Assert-V02SoftwareOnlyObservation $measurement.IdleSampleFinishRenderer 'idle-resource-sample:finish' 'Idle renderer finish'
    $summaryIdleStart = Assert-V02SoftwareOnlyObservation $evidence.IdleSampleStart 'idle-resource-sample:start' 'Renderer summary idle start'
    $summaryIdleFinish = Assert-V02SoftwareOnlyObservation $evidence.IdleSampleFinish 'idle-resource-sample:finish' 'Renderer summary idle finish'
    if ($idleStart -lt $previous -or $idleFinish -lt $idleStart -or $idleFinish -gt $runFinish) { throw 'Idle renderer timestamps are not ordered within the run.' }
    if ($summaryIdleStart.UtcDateTime.Ticks -ne $idleStart.UtcDateTime.Ticks -or $summaryIdleFinish.UtcDateTime.Ticks -ne $idleFinish.UtcDateTime.Ticks) { throw 'Renderer summary idle observations contradict resource measurement.' }
    $integerTypes = @([TypeCode]::Byte,[TypeCode]::SByte,[TypeCode]::UInt16,[TypeCode]::UInt32,[TypeCode]::UInt64,[TypeCode]::Int16,[TypeCode]::Int32,[TypeCode]::Int64)
    if ($null -eq $measurement.SampleCount -or $integerTypes -notcontains [Type]::GetTypeCode($measurement.SampleCount.GetType()) -or [int64]$measurement.SampleCount -le 0) { throw 'Renderer SampleCount must be a positive native JSON integer.' }
    $samples=@($measurement.IdleSampleRendererObservations);$summarySamples=@($evidence.IdleSamples);$rawSamples=@($measurement.Samples)
    if($samples.Count-ne[int64]$measurement.SampleCount -or $summarySamples.Count-ne$samples.Count -or $rawSamples.Count-ne$samples.Count){throw 'Renderer idle observation count must exactly equal resource SampleCount in all report surfaces.'}
    $previousSample=$idleStart
    for($index=0;$index-lt$samples.Count;$index++){
        $sampleTime=Assert-V02SoftwareOnlyObservation $samples[$index] "idle-resource-sample:$index" "Idle renderer sample $index"
        $summaryTime=Assert-V02SoftwareOnlyObservation $summarySamples[$index] "idle-resource-sample:$index" "Renderer summary idle sample $index"
        Assert-V02RendererProperty $rawSamples[$index] 'ObservedUtc' "Raw resource sample $index"
        Assert-V02RendererProperty $rawSamples[$index] 'RendererObservation' "Raw resource sample $index"
        $rawTime=Assert-V02SoftwareOnlyObservation $rawSamples[$index].RendererObservation "idle-resource-sample:$index" "Raw resource sample renderer $index"
        foreach($name in @('Phase','ObservedUtc','WpfProcessRenderMode','RenderTier','SoftwareOnlyConfirmed')){if([string]$samples[$index].$name-cne[string]$summarySamples[$index].$name){throw "Renderer summary idle sample $index contradicts its resource observation."}}
        foreach($name in @('Phase','ObservedUtc','WpfProcessRenderMode','RenderTier','SoftwareOnlyConfirmed')){if([string]$samples[$index].$name-cne[string]$rawSamples[$index].RendererObservation.$name){throw "Raw resource sample renderer $index contradicts its renderer list observation."}}
        if($rawSamples[$index].ObservedUtc-isnot[string] -or [string]$rawSamples[$index].ObservedUtc-cne[string]$samples[$index].ObservedUtc){throw "Raw resource sample $index timestamp contradicts its renderer observation."}
        if($sampleTime-lt$previousSample -or $sampleTime-gt$idleFinish -or $summaryTime.UtcDateTime.Ticks-ne$sampleTime.UtcDateTime.Ticks -or $rawTime.UtcDateTime.Ticks-ne$sampleTime.UtcDateTime.Ticks){throw "Renderer idle sample $index is out of order or outside its start/finish window."}
        $previousSample=$sampleTime
    }
    return $evidence
}
