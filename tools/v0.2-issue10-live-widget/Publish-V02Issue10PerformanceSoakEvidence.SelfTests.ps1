#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

$path=Join-Path $PSScriptRoot 'Publish-V02Issue10PerformanceSoakEvidence.ps1'
$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$null,[ref]$errors)
if($errors){throw "Issue #10 composer does not parse: $($errors[0].Message)"}
$parameters=(Get-Command $path).Parameters
foreach($name in @('AcSoakMeasurementPath','BatterySoakMeasurementPath','RawPerformancePath','PerformanceBindingPath','RunNonce','PackageIdentityPath','PackageArchivePath','ExtractedPackageRoot','ExpectedSourceCommit','ExpectedSourceTree')){
    if(-not$parameters.ContainsKey($name)){throw "Issue #10 composer omitted mandatory governed input '$name'."}
}
foreach($name in @('TelemetryProvider','TelemetryChannel','Synthetic','RuntimeCredit','ForceOverwrite')){
    if($parameters.ContainsKey($name)){throw "Issue #10 composer exposes forbidden bypass '$name'."}
}
$source=[IO.File]::ReadAllText($path)
foreach($token in @(
    "PackagedCompatibilityPerformanceTelemetryBinding-NoRuntimeCredit",
    "Performance telemetry binding must contain exactly 24 acquisitions.",
    "PackagedCompatibilityPerformance-NativeTierComparator-NoPerFrameGpuOrRuntimeCredit",
    "value.evidenceBoundary.actualHerdrRuntime-cne'NOT_OBSERVED'",
    "Assert-PerformanceBinding `$binding `$raw `$rawPath"
)){
    if($source.IndexOf($token,[StringComparison]::Ordinal)-lt0){throw "Issue #10 composer omitted fail-closed source guard: $token"}
}
if($source -notmatch 'if\(\$order-ceq''AB''\).*''a''.*''b''.*else.*''b''.*''a''') { throw 'Issue #10 composer does not preserve semantic AB a,b then BA b,a acquisition order.' }
[pscustomobject][ordered]@{EvidenceClassification='StaticContractSelftest-NoRuntimeCredit';PositiveCases=1;NegativeCases=5;Status='PASS'}|Format-Table
