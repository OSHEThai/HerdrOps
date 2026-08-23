#requires -Version 5.1
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repositoryRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$gatePath=Join-Path $repositoryRoot 'tools\Test-V02LiveRuntimeAcceptance.ps1'
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

. (Join-Path $repositoryRoot 'tools\lib\V02GateProvenance.ps1')
$tokens=$null;$errors=$null;$gateAst=[Management.Automation.Language.Parser]::ParseFile($gatePath,[ref]$tokens,[ref]$errors)
Assert-True (@($errors).Count-eq0) 'Production gate could not be parsed for exact-function execution.'
foreach($functionName in @('Assert-Issue10NoReparseComponents','Get-Issue10FinalPath','Assert-Issue10HeldLeaf','New-Issue10OwnedLeafStream','Remove-Issue10OwnedLeaf','Copy-Issue10HeldAuthorityFile')){
    $definition=$gateAst.FindAll({param($node)$node-is[Management.Automation.Language.FunctionDefinitionAst]-and$node.Name-ceq$functionName},$true)|Select-Object -First 1
    Assert-True ($null-ne$definition) "Production function '$functionName' is missing."
    . ([scriptblock]::Create($definition.Extent.Text))
}

$missing=Invoke-GateHostile @('-Issue10WidgetReportPath','one.json','-Issue10BindingManifestPath','two.json','-Issue10PerformanceReceiptPath','three.json','-Issue10PerformanceRawSourcePath','four.json')
Assert-True ($missing.ExitCode-ne0-and$missing.Text.Contains('requires widget output, binding output, performance receipt/raw source, and soak receipt together')) 'Incomplete same-run input did not reach the exact all-or-none guard.'
Pass-Test 'incomplete same-run authority set reaches all-or-none guard'

$fixture=Join-Path ([IO.Path]::GetTempPath()) ('HerdrOps-I10Causality-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $fixture|Out-Null
try{
    $performance=Join-Path $fixture 'performance.json';$raw=Join-Path $fixture 'raw.json';$soak=Join-Path $fixture 'soak.json'
    foreach($path in @($performance,$raw,$soak)){[IO.File]::WriteAllText($path,"{}`n",(New-Object Text.UTF8Encoding($false)))}
    $ownedDirectory=Join-Path $fixture 'owned';New-Item -ItemType Directory -Path $ownedDirectory|Out-Null
    $ownedPath=Join-Path $ownedDirectory 'authority.json';$foreignPath=Join-Path $ownedDirectory 'foreign.txt';[IO.File]::WriteAllText($foreignPath,'foreign')
    $owned=Copy-Issue10HeldAuthorityFile -Source $performance -Destination $ownedPath -Context 'Issue #10 hostile owned-copy'
    $replacement=Join-Path $fixture 'replacement.json';[IO.File]::WriteAllText($replacement,'replacement')
    $swapBlocked=$false;try{Move-Item -LiteralPath $replacement -Destination $ownedPath -Force -ErrorAction Stop}catch{$swapBlocked=$true}
    Assert-True $swapBlocked 'A transaction-owned staged leaf was replaceable while its exact identity was held.'
    Remove-Issue10OwnedLeaf -Owned $owned -Context 'Issue #10 hostile exact cleanup'
    Assert-True (-not(Test-Path -LiteralPath $ownedPath)-and(Test-Path -LiteralPath $foreignPath)-and((Get-Content -LiteralPath $foreignPath -Raw)-ceq'foreign')) 'Exact cleanup deleted foreign directory contents or retained the owned leaf.'
    Pass-Test 'production held-copy cleanup removes only its exact owned leaf and preserves foreign contents'
    $outside=Invoke-GateHostile @('-Issue10WidgetReportPath',(Join-Path $fixture 'widget.json'),'-Issue10BindingManifestPath',(Join-Path $fixture 'binding.json'),'-Issue10PerformanceReceiptPath',$performance,'-Issue10PerformanceRawSourcePath',$raw,'-Issue10SoakReceiptPath',$soak)
    Assert-True ($outside.ExitCode-ne0-and$outside.Text.Contains('same-run output must be inside the v0.2 runtime evidence root')) 'Prior/outside-run output did not reach the evidence-root guard.'
    Assert-True (-not(Test-Path -LiteralPath (Join-Path $fixture 'binding.json')) -and -not(Test-Path -LiteralPath (Join-Path $fixture 'widget.json'))) 'Rejected outside-run paths were created.'
    Pass-Test 'outside or prior-run output reaches evidence-root guard before runtime'

    $junction=Join-Path $fixture 'junction';$outsideJunction=Join-Path $fixture 'outside-junction';New-Item -ItemType Directory -Path $outsideJunction|Out-Null
    $junctionCreated=$false
    try{
        $junctionResult=& cmd.exe /d /c mklink /J $junction $outsideJunction 2>&1
        $junctionCreated=($LASTEXITCODE-eq0)
        if($junctionCreated){
            $junctionReceipt=Join-Path $junction 'performance.json';[IO.File]::WriteAllText($junctionReceipt,"{}`n",(New-Object Text.UTF8Encoding($false)))
            $runtimeRoot=Join-Path $repositoryRoot 'artifacts\runtime-evidence\v0.2\issues-7-9-10';New-Item -ItemType Directory -Path $runtimeRoot -Force|Out-Null
            $junctionHostile=Invoke-GateHostile @('-Issue10WidgetReportPath',(Join-Path $runtimeRoot ('junction-widget-'+[guid]::NewGuid().ToString('N')+'.json')),'-Issue10BindingManifestPath',(Join-Path $runtimeRoot ('junction-binding-'+[guid]::NewGuid().ToString('N')+'.json')),'-Issue10PerformanceReceiptPath',$junctionReceipt,'-Issue10PerformanceRawSourcePath',$raw,'-Issue10SoakReceiptPath',$soak)
            $reparseGuard=$junctionHostile.Text.Contains('contains a reparse-point component')-or$junctionHostile.Text.Contains('same-run input final path changed')
            Assert-True ($junctionHostile.ExitCode-ne0-and$reparseGuard) "Junction-backed same-run input did not reach the exact reparse/final-path guard: $($junctionHostile.Text)"
            Pass-Test 'junction-backed staged input reaches a real reparse or final-path guard before runtime'
        }else{Write-Output "SKIP: junction hostile unavailable: $junctionResult"}
    }finally{if($junctionCreated-and(Test-Path -LiteralPath $junction)){[IO.Directory]::Delete($junction)}}

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
