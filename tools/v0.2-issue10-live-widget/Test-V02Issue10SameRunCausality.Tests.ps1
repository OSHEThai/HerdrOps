#requires -Version 5.1
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repositoryRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$gatePath=Join-Path $repositoryRoot 'tools\Test-V02LiveRuntimeAcceptance.ps1'
$appSourcePath=Join-Path $repositoryRoot 'src\HerdrOps.App\App.xaml.cs'
$gateSource=Get-Content -LiteralPath $gatePath -Raw
$appSource=Get-Content -LiteralPath $appSourcePath -Raw
$passed=0
function Pass-Test([string]$Name){$script:passed++;Write-Output "PASS: $Name"}
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw $Message}}
function Invoke-GateHostile([string[]]$ExtraArguments){
    $engine=(Get-Process -Id $PID).Path
    $arguments=@('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$gatePath,'-TargetHerdrSocketPath','missing.sock','-ExpectedSourceCommit',('a'*40),'-ExpectedSourceTree',('b'*40),'-EvidenceRunNonce',('c'*32),'-PackageIdentityPath','missing-identity.json','-PackageArchivePath','missing.zip','-ExtractedPackageRoot','missing-package','-TargetAgentSessionReference','same-run-hostile')+$ExtraArguments
    $priorPreference=$ErrorActionPreference;$ErrorActionPreference='Continue'
    try{$output=@(& $engine @arguments 2>&1);$exit=$LASTEXITCODE}finally{$ErrorActionPreference=$priorPreference}
    return [pscustomobject]@{ExitCode=$exit;Text=($output-join"`n")}
}

$gateSeal=$gateSource.IndexOf('$reportLines | Set-Content -LiteralPath $gateReportPath',[StringComparison]::Ordinal)
$bindingBuild=$gateSource.LastIndexOf('$issue10SameRunBinding=New-Issue10SameRunBindingManifest',[StringComparison]::Ordinal)
$finalizerLaunch=$gateSource.LastIndexOf("'--finalize-issue10-widget-report'",[StringComparison]::Ordinal)
Assert-True ($gateSeal-ge0-and$bindingBuild-gt$gateSeal-and$finalizerLaunch-gt$bindingBuild) 'Same-run finalization is not ordered after gate sealing.'
Assert-True ($appSource.IndexOf('Issue #10 widget evidence must be finalized by the composite gate',[StringComparison]::Ordinal)-ge0) 'Direct runtime App path does not reject premature Issue #10 finalization.'
Pass-Test 'same-run finalizer is ordered after gate sealing and direct premature production is rejected'

$missing=Invoke-GateHostile @('-Issue10WidgetReportPath','one.json','-Issue10BindingManifestPath','two.json','-Issue10PerformanceReceiptPath','three.json','-Issue10PerformanceRawSourcePath','four.json')
Assert-True ($missing.ExitCode-ne0-and$missing.Text.Contains('requires widget output, binding output, performance receipt/raw source, and soak receipt together')) 'Incomplete same-run input did not reach the exact all-or-none guard.'
Pass-Test 'incomplete same-run authority set reaches all-or-none guard'

$fixture=Join-Path ([IO.Path]::GetTempPath()) ('HerdrOps-I10Causality-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $fixture|Out-Null
try{
    $performance=Join-Path $fixture 'performance.json';$raw=Join-Path $fixture 'raw.json';$soak=Join-Path $fixture 'soak.json'
    foreach($path in @($performance,$raw,$soak)){[IO.File]::WriteAllText($path,"{}`n",(New-Object Text.UTF8Encoding($false)))}
    $outside=Invoke-GateHostile @('-Issue10WidgetReportPath',(Join-Path $fixture 'widget.json'),'-Issue10BindingManifestPath',(Join-Path $fixture 'binding.json'),'-Issue10PerformanceReceiptPath',$performance,'-Issue10PerformanceRawSourcePath',$raw,'-Issue10SoakReceiptPath',$soak)
    Assert-True ($outside.ExitCode-ne0-and$outside.Text.Contains('same-run output must be inside the v0.2 runtime evidence root')) 'Prior/outside-run output did not reach the evidence-root guard.'
    Assert-True (-not(Test-Path -LiteralPath (Join-Path $fixture 'binding.json')) -and -not(Test-Path -LiteralPath (Join-Path $fixture 'widget.json'))) 'Rejected outside-run paths were created.'
    Pass-Test 'outside or prior-run output reaches evidence-root guard before runtime'

    $runtimeRoot=Join-Path $repositoryRoot 'artifacts\runtime-evidence\v0.2\issues-7-9-10';New-Item -ItemType Directory -Path $runtimeRoot -Force|Out-Null
    $existingWidget=Join-Path $runtimeRoot ('existing-'+[guid]::NewGuid().ToString('N')+'.json');$newBinding=Join-Path $runtimeRoot ('binding-'+[guid]::NewGuid().ToString('N')+'.json');[IO.File]::WriteAllText($existingWidget,'owned-by-test')
    try{
        $clobber=Invoke-GateHostile @('-Issue10WidgetReportPath',$existingWidget,'-Issue10BindingManifestPath',$newBinding,'-Issue10PerformanceReceiptPath',$performance,'-Issue10PerformanceRawSourcePath',$raw,'-Issue10SoakReceiptPath',$soak)
        Assert-True ($clobber.ExitCode-ne0-and$clobber.Text.Contains('same-run output already exists before runtime')) 'Pre-existing output did not reach the no-clobber guard.'
        Assert-True ((Get-Content -LiteralPath $existingWidget -Raw)-ceq'owned-by-test') 'No-clobber hostile changed caller-owned output.'
        Assert-True (-not(Test-Path -LiteralPath $newBinding)) 'No-clobber hostile created a binding output.'
        Pass-Test 'pre-existing same-run output reaches no-clobber guard without mutation'
    }finally{if(Test-Path -LiteralPath $existingWidget){Remove-Item -LiteralPath $existingWidget -Force}}

    $appExecutable=Join-Path $repositoryRoot 'src\HerdrOps.App\bin\Release\net10.0-windows\win-x64\HerdrOps.App.exe'
    if(Test-Path -LiteralPath $appExecutable -PathType Leaf){
        $finalizerOutput=Join-Path $fixture 'finalizer-output.json'
        $process=Start-Process -FilePath $appExecutable -ArgumentList @('--finalize-issue10-widget-report','--issue10-widget-report',$finalizerOutput) -WindowStyle Hidden -Wait -PassThru
        Assert-True ($process.ExitCode-eq2) 'Incomplete headless finalizer CLI did not reach its exact argument guard.'
        Assert-True (-not(Test-Path -LiteralPath $finalizerOutput)) 'Rejected headless finalizer CLI created output.'
        Pass-Test 'incomplete headless finalizer reaches argument guard without publication'
    }else{throw "Build the App before this hostile CLI test: $appExecutable"}
}finally{if(Test-Path -LiteralPath $fixture){Remove-Item -LiteralPath $fixture -Recurse -Force}}
Write-Output "RESULT: $passed passed, 0 failed"
