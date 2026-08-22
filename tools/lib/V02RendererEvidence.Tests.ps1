[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'V02RendererEvidence.ps1')
$script:cases=0

function Observation([string]$Phase,[int]$Second){[pscustomobject]@{Phase=$Phase;ObservedUtc=([datetimeoffset]::Parse('2026-08-22T00:00:00Z').AddSeconds($Second).ToString('O'));WpfProcessRenderMode='SoftwareOnly';RenderTier=0;SoftwareOnlyConfirmed=$true}}
function Report {
    $names=@('pre-capture','post-initial-captures','post-dashboard-close','post-final-widget-capture','post-cleanup');$checkpoints=@();$summaries=@()
    for($i=0;$i-lt$names.Count;$i++){$o=Observation "resource-stage:$($names[$i])" (3+$i);$checkpoints+=[pscustomobject]@{Stage=$names[$i];RendererObservation=$o};$summaries+=$o}
    $idleStart=Observation 'idle-resource-sample:start' 8;$idleFinish=Observation 'idle-resource-sample:finish' 9;$samples=@();for($i=0;$i-lt3;$i++){$o=Observation "idle-resource-sample:$i" 8;$o.ObservedUtc="2026-08-22T00:00:08.$($i+1)000000Z";$samples+=$o}
    $raw=@($samples|ForEach-Object{[pscustomobject]@{ObservedUtc=$_.ObservedUtc;RendererObservation=$_}})
    [pscustomobject]@{StartedUtc='2026-08-22T00:00:02.0000000Z';FinishedUtc='2026-08-22T00:00:10.0000000Z';RendererEvidence=[pscustomobject]@{PolicyId='software-only-process-wide';ExpectedWpfProcessRenderMode='SoftwareOnly';Startup=(Observation 'app-constructor-before-initialize-component' 0);PreFirstWindow=(Observation 'runtime-evidence-pre-first-window' 1);ResourceStages=$summaries;IdleSampleStart=$idleStart;IdleSamples=$samples;IdleSampleFinish=$idleFinish;SoftwareOnlyThroughout=$true};ResourceMeasurement=[pscustomobject]@{SampleCount=3;Samples=$raw;StageCheckpoints=$checkpoints;IdleSampleStartRenderer=$idleStart;IdleSampleRendererObservations=$samples;IdleSampleFinishRenderer=$idleFinish;SoftwareOnlyThroughoutIdleSample=$true}}
}
function Pass([string]$Name,[scriptblock]$Action){$script:cases++;&$Action;Write-Host "PASS: $Name"}
function Fail([string]$Name,[scriptblock]$Action){$script:cases++;try{&$Action}catch{Write-Host "PASS: $Name rejected: $($_.Exception.Message)";return};throw "$Name unexpectedly passed."}

Pass 'complete SoftwareOnly lifetime' {$null=Assert-V02RendererEvidence (Report)}
$r=Report;$r.RendererEvidence.PolicyId='other';Fail 'wrong policy ID' {$null=Assert-V02RendererEvidence $r}
$r=Report;$r.RendererEvidence.Startup.WpfProcessRenderMode='Default';Fail 'wrong startup mode' {$null=Assert-V02RendererEvidence $r}
$r=Report;$r.RendererEvidence.PreFirstWindow.SoftwareOnlyConfirmed=$false;Fail 'false before-first-window confirmation' {$null=Assert-V02RendererEvidence $r}
$r=Report;$r.ResourceMeasurement.StageCheckpoints[2].RendererObservation.SoftwareOnlyConfirmed='true';Fail 'string stage confirmation' {$null=Assert-V02RendererEvidence $r}
$r=Report;$r.RendererEvidence.ResourceStages=@($r.RendererEvidence.ResourceStages|Select-Object -First 4);Fail 'missing renderer stage' {$null=Assert-V02RendererEvidence $r}
$r=Report;$tmp=$r.RendererEvidence.ResourceStages[0];$r.RendererEvidence.ResourceStages[0]=$r.RendererEvidence.ResourceStages[1];$r.RendererEvidence.ResourceStages[1]=$tmp;Fail 'reordered renderer stages' {$null=Assert-V02RendererEvidence $r}
$r=Report;$r.RendererEvidence.ResourceStages[3].ObservedUtc='2026-08-22T00:00:07.5000000Z';Fail 'summary/checkpoint contradiction' {$null=Assert-V02RendererEvidence $r}
$r=Report;$r.ResourceMeasurement.IdleSampleFinishRenderer.ObservedUtc='2026-08-22T00:00:07.0000000Z';Fail 'idle timestamp regression' {$null=Assert-V02RendererEvidence $r}
$r=Report;$r.RendererEvidence.SoftwareOnlyThroughout=$false;Fail 'aggregate false' {$null=Assert-V02RendererEvidence $r}
$r=Report;$r.ResourceMeasurement.SoftwareOnlyThroughoutIdleSample='true';Fail 'string idle aggregate' {$null=Assert-V02RendererEvidence $r}
$r=Report;$r.RendererEvidence.IdleSampleStart.RenderTier='0';Fail 'string render tier' {$null=Assert-V02RendererEvidence $r}
$r=Report;$r.ResourceMeasurement.IdleSampleRendererObservations=@($r.ResourceMeasurement.IdleSampleRendererObservations|Select-Object -First 2);Fail 'missing per-sample renderer observation' {$null=Assert-V02RendererEvidence $r}
$r=Report;$r.ResourceMeasurement.IdleSampleRendererObservations[1].Phase='idle-resource-sample:2';Fail 'wrong per-sample ordinal' {$null=Assert-V02RendererEvidence $r}
$r=Report;$r.RendererEvidence.Startup.ObservedUtc='2026-08-22T07:00:00+07:00';Fail 'non-UTC renderer timestamp' {$null=Assert-V02RendererEvidence $r}
$r=Report;$r.RendererEvidence.Startup|Add-Member NoteProperty Unknown 1;Fail 'extra renderer observation property' {$null=Assert-V02RendererEvidence $r}
$r=Report;$r.ResourceMeasurement.Samples[1].RendererObservation.Phase='idle-resource-sample:2';Fail 'raw sample renderer contradiction' {$null=Assert-V02RendererEvidence $r}
$r=Report;$r.ResourceMeasurement.Samples[1].ObservedUtc='2026-08-22T00:00:08.9000000Z';Fail 'raw sample timestamp contradiction' {$null=Assert-V02RendererEvidence $r}

if($script:cases-ne18){throw "Unexpected renderer test count: $script:cases"}
Write-Host "All $script:cases v0.2 renderer evidence cases passed."
