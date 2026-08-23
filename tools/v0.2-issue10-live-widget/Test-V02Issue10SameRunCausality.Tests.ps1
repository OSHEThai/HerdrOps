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
function Assert-Issue10AppBuildOutput([string]$OutputDirectory){
    $resolved=[IO.Path]::GetFullPath($OutputDirectory)
    if(-not(Test-Path -LiteralPath $resolved -PathType Container)){throw "Governed Issue #10 App build output is missing: $resolved"}
    Assert-Issue10NoReparseComponents -Path $resolved -Context 'Governed Issue #10 App build output'
    $paths=[ordered]@{Exe=(Join-Path $resolved 'HerdrOps.App.exe');Dll=(Join-Path $resolved 'HerdrOps.App.dll');RuntimeConfig=(Join-Path $resolved 'HerdrOps.App.runtimeconfig.json')}
    foreach($name in $paths.Keys){if(-not(Test-Path -LiteralPath $paths[$name] -PathType Leaf)){throw "Governed Issue #10 App $name prerequisite is missing: $($paths[$name])"};$item=Get-Item -LiteralPath $paths[$name] -Force -ErrorAction Stop;if($item.Length-le0-or($item.Attributes-band[IO.FileAttributes]::ReparsePoint)){throw "Governed Issue #10 App $name prerequisite is not an exact nonempty regular file: $($paths[$name])"}}
    if([Reflection.AssemblyName]::GetAssemblyName($paths.Dll).Name-cne'HerdrOps.App'){throw 'Governed Issue #10 App DLL assembly identity is invalid.'}
    $runtimeConfig=Get-Content -LiteralPath $paths.RuntimeConfig -Raw|ConvertFrom-Json
    $frameworkNames=@($runtimeConfig.runtimeOptions.frameworks|ForEach-Object{[string]$_.name})
    if([string]$runtimeConfig.runtimeOptions.tfm-cne'net10.0'-or$frameworkNames.Count-ne2-or$frameworkNames[0]-cne'Microsoft.NETCore.App'-or$frameworkNames[1]-cne'Microsoft.WindowsDesktop.App'){throw 'Governed Issue #10 App runtimeconfig identity is invalid.'}
    return [pscustomobject]@{ExecutablePath=[IO.Path]::GetFullPath($paths.Exe);ExecutableSha256=(Get-FileHash -LiteralPath $paths.Exe -Algorithm SHA256).Hash;AssemblyPath=[IO.Path]::GetFullPath($paths.Dll);AssemblySha256=(Get-FileHash -LiteralPath $paths.Dll -Algorithm SHA256).Hash;RuntimeConfigPath=[IO.Path]::GetFullPath($paths.RuntimeConfig);RuntimeConfigSha256=(Get-FileHash -LiteralPath $paths.RuntimeConfig -Algorithm SHA256).Hash}
}
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
foreach($functionName in @('Test-Issue10ContainedPath','Assert-Issue10NoReparseComponents','Get-Issue10FinalPath','Assert-Issue10HeldLeaf','New-Issue10OwnedLeafStream','Remove-Issue10OwnedLeaf','Close-Issue10OwnedLeaves','Copy-Issue10HeldAuthorityFile','New-Issue10SameRunBindingManifest','Get-Issue10HandleInformation','Open-Issue10HeldPublishedLeaf','Open-Issue10HeldPublishedParent','Get-Issue10ReceiptAuthentication','Test-Issue10FixedHexEqual','Open-Issue10PublishedBinding')){
    $definition=$gateAst.FindAll({param($node)$node-is[Management.Automation.Language.FunctionDefinitionAst]-and$node.Name-ceq$functionName},$true)|Select-Object -First 1
    Assert-True ($null-ne$definition) "Production function '$functionName' is missing."
    . ([scriptblock]::Create($definition.Extent.Text))
}

$missing=Invoke-GateHostile @('-Issue10WidgetReportPath','one.json','-Issue10BindingManifestPath','two.json','-Issue10PerformanceReceiptPath','three.json','-Issue10PerformanceRawSourcePath','four.json')
Assert-True ($missing.ExitCode-ne0-and$missing.Text.Contains('requires widget output, binding output, performance receipt/raw/binding/commit, and soak receipt together')) 'Incomplete same-run input did not reach the exact all-or-none guard.'
Pass-Test 'incomplete same-run authority set reaches all-or-none guard'

$fixture=Join-Path ([IO.Path]::GetTempPath()) ('HerdrOps-I10Causality-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $fixture|Out-Null
try{
    $performance=Join-Path $fixture 'performance.json';$raw=Join-Path $fixture 'raw.json';$telemetryBinding=Join-Path $fixture 'telemetry-binding.json';$transactionCommit=Join-Path $fixture 'transaction-commit.json';$soak=Join-Path $fixture 'soak.json'
    foreach($path in @($performance,$raw,$telemetryBinding,$transactionCommit,$soak)){[IO.File]::WriteAllText($path,"{}`n",(New-Object Text.UTF8Encoding($false)))}
    $fullInputs=@('-Issue10PerformanceReceiptPath',$performance,'-Issue10PerformanceRawSourcePath',$raw,'-Issue10PerformanceTelemetryBindingPath',$telemetryBinding,'-Issue10PerformanceTransactionCommitPath',$transactionCommit,'-Issue10SoakReceiptPath',$soak)
    $ownedDirectory=Join-Path $fixture 'owned';New-Item -ItemType Directory -Path $ownedDirectory|Out-Null
    $ownedPath=Join-Path $ownedDirectory 'authority.json';$foreignPath=Join-Path $ownedDirectory 'foreign.txt';[IO.File]::WriteAllText($foreignPath,'foreign')
    $owned=Copy-Issue10HeldAuthorityFile -Source $performance -Destination $ownedPath -Context 'Issue #10 hostile owned-copy'
    $replacement=Join-Path $fixture 'replacement.json';[IO.File]::WriteAllText($replacement,'replacement')
    $swapBlocked=$false;try{Move-Item -LiteralPath $replacement -Destination $ownedPath -Force -ErrorAction Stop}catch{$swapBlocked=$true}
    Assert-True $swapBlocked 'A transaction-owned staged leaf was replaceable while its exact identity was held.'
    Remove-Issue10OwnedLeaf -Owned $owned -Context 'Issue #10 hostile exact cleanup'
    Assert-True (-not(Test-Path -LiteralPath $ownedPath)-and(Test-Path -LiteralPath $foreignPath)-and((Get-Content -LiteralPath $foreignPath -Raw)-ceq'foreign')) 'Exact cleanup deleted foreign directory contents or retained the owned leaf.'
    Pass-Test 'production held-copy cleanup removes only its exact owned leaf and preserves foreign contents'
    $outside=Invoke-GateHostile (@('-Issue10WidgetReportPath',(Join-Path $fixture 'widget.json'),'-Issue10BindingManifestPath',(Join-Path $fixture 'binding.json'))+$fullInputs)
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
            $junctionInputs=@('-Issue10PerformanceReceiptPath',$junctionReceipt,'-Issue10PerformanceRawSourcePath',$raw,'-Issue10PerformanceTelemetryBindingPath',$telemetryBinding,'-Issue10PerformanceTransactionCommitPath',$transactionCommit,'-Issue10SoakReceiptPath',$soak)
            $junctionHostile=Invoke-GateHostile (@('-Issue10WidgetReportPath',(Join-Path $runtimeRoot ('junction-widget-'+[guid]::NewGuid().ToString('N')+'.json')),'-Issue10BindingManifestPath',(Join-Path $runtimeRoot ('junction-binding-'+[guid]::NewGuid().ToString('N')+'.json')))+$junctionInputs)
            $reparseGuard=$junctionHostile.Text.Contains('contains a reparse-point component')-or$junctionHostile.Text.Contains('same-run input final path changed')
            Assert-True ($junctionHostile.ExitCode-ne0-and$reparseGuard) "Junction-backed same-run input did not reach the exact reparse/final-path guard: $($junctionHostile.Text)"
            Pass-Test 'junction-backed staged input reaches a real reparse or final-path guard before runtime'
        }else{Write-Output "SKIP: junction hostile unavailable: $junctionResult"}
    }finally{if($junctionCreated-and(Test-Path -LiteralPath $junction)){[IO.Directory]::Delete($junction)}}

    $runtimeRoot=Join-Path $repositoryRoot 'artifacts\runtime-evidence\v0.2\issues-7-9-10';New-Item -ItemType Directory -Path $runtimeRoot -Force|Out-Null
    $existingWidget=Join-Path $runtimeRoot ('existing-'+[guid]::NewGuid().ToString('N')+'.json');$newBinding=Join-Path $runtimeRoot ('binding-'+[guid]::NewGuid().ToString('N')+'.json');[IO.File]::WriteAllText($existingWidget,'owned-by-test')
    try{
        $clobber=Invoke-GateHostile (@('-Issue10WidgetReportPath',$existingWidget,'-Issue10BindingManifestPath',$newBinding)+$fullInputs)
        Assert-True ($clobber.ExitCode-ne0-and$clobber.Text.Contains('same-run output already exists before runtime')) 'Pre-existing output did not reach the no-clobber guard.'
        Assert-True ((Get-Content -LiteralPath $existingWidget -Raw)-ceq'owned-by-test') 'No-clobber hostile changed caller-owned output.'
        Assert-True (-not(Test-Path -LiteralPath $newBinding)) 'No-clobber hostile created a binding output.'
        Pass-Test 'pre-existing same-run output reaches no-clobber guard without mutation'
    }finally{if(Test-Path -LiteralPath $existingWidget){Remove-Item -LiteralPath $existingWidget -Force}}

    $scriptSource=(Get-Content -LiteralPath $PSCommandPath -Raw).Replace('/','\')
    $forbiddenSourceBin=('src'+'\HerdrOps.App'+'\bin')
    Assert-True (-not$scriptSource.Contains($forbiddenSourceBin)) 'Same-run test source retains a forbidden source-bin fallback.'
    Assert-True ($scriptSource.Contains("artifacts\bin\HerdrOps.App\release")) 'Same-run test source does not bind the governed Invoke-Build App output.'
    Pass-Test 'same-run executable source binds only governed artifacts output and forbids source-bin fallback'
    $incompleteOutput=Join-Path $fixture 'incomplete-governed-output';New-Item -ItemType Directory -Path $incompleteOutput|Out-Null;[IO.File]::WriteAllText((Join-Path $incompleteOutput 'HerdrOps.App.exe'),'stale source-bin lookalike')
    $incompleteRejected=$false;try{Assert-Issue10AppBuildOutput $incompleteOutput|Out-Null}catch{$incompleteRejected=$_.Exception.Message.Contains('prerequisite')}
    Assert-True $incompleteRejected 'An App executable lookalike without governed DLL/runtimeconfig companions masked the clean-runner prerequisite.'
    Pass-Test 'incomplete App lookalike cannot mask governed clean-runner output'
    $governedAppOutput=Join-Path $repositoryRoot 'artifacts\bin\HerdrOps.App\release'
    $governedApp=Assert-Issue10AppBuildOutput $governedAppOutput
    $appExecutable=$governedApp.ExecutablePath
    if(Test-Path -LiteralPath $appExecutable -PathType Leaf){
        $finalizerOutput=Join-Path $fixture 'finalizer-output.json'
        $process=Start-Process -FilePath $appExecutable -ArgumentList @('--finalize-issue10-widget-report','--issue10-widget-report',$finalizerOutput) -WindowStyle Hidden -Wait -PassThru
        Assert-True ($process.ExitCode-eq2) 'Incomplete headless finalizer CLI did not reach its exact argument guard.'
        Assert-True (-not(Test-Path -LiteralPath $finalizerOutput)) 'Rejected headless finalizer CLI created output.'
        Pass-Test 'incomplete headless finalizer reaches argument guard without publication'

        $runNonce='c'*32;$commit='a'*40;$tree='b'*40;$stateHash='E'*64
        $started=[DateTimeOffset]::UtcNow.AddMinutes(-1);$dashboardUtc=$started.AddSeconds(10);$widgetUtc=$started.AddSeconds(20);$finished=$started.AddSeconds(30)
        $writeUtf8={param($path,$text)[IO.File]::WriteAllText($path,$text,(New-Object Text.UTF8Encoding($false)))}
        $artifactFiles=@{};foreach($name in @('gate.txt','core.json','identity.json','archive.zip','package.json','package-app.exe','package-core.exe','performance.json','performance-raw.json','performance-telemetry-binding.json','performance-transaction-commit.json','soak.json','herdr.exe')){$path=Join-Path $fixture $name;&$writeUtf8 $path ("owned-$name`n");$artifactFiles[$name]=$path}
        $stagedRun=Join-Path $fixture 'same-run-stage';New-Item -ItemType Directory -Path $stagedRun|Out-Null;$stageGate=Join-Path $stagedRun 'gate.txt';$stageCore=Join-Path $stagedRun 'core.json';$stageApp=Join-Path $stagedRun 'app.json';foreach($pair in @(@($artifactFiles['gate.txt'],$stageGate),@($artifactFiles['core.json'],$stageCore))){Copy-Item -LiteralPath $pair[0] -Destination $pair[1]};&$writeUtf8 $stageApp "stage-app`n"
        $stagePackage=[pscustomobject]@{IdentityPath=$artifactFiles['identity.json'];IdentityFileSha256=(Get-FileHash $artifactFiles['identity.json'] -Algorithm SHA256).Hash;ReceiptSha256='9'*64;ArchivePath=$artifactFiles['archive.zip'];ArchiveSha256=(Get-FileHash $artifactFiles['archive.zip'] -Algorithm SHA256).Hash;ManifestPath=$artifactFiles['package.json'];ManifestSha256=(Get-FileHash $artifactFiles['package.json'] -Algorithm SHA256).Hash;AppPath=$artifactFiles['package-app.exe'];AppSha256=(Get-FileHash $artifactFiles['package-app.exe'] -Algorithm SHA256).Hash;CorePath=$artifactFiles['package-core.exe'];CoreSha256=(Get-FileHash $artifactFiles['package-core.exe'] -Algorithm SHA256).Hash}
        $staged=New-Issue10SameRunBindingManifest -AllowedEvidenceRoot $fixture -RunEvidenceDirectory $stagedRun -ManifestPath (Join-Path $fixture 'staged-binding.json') -WidgetOutputPath (Join-Path $fixture 'staged-widget.json') -RunNonce $runNonce -EvidenceStartedUtc $started.UtcDateTime -SourceCommit $commit -SourceTree $tree -PackageBinding $stagePackage -GateReportPath $stageGate -CoreRuntimeReportPath $stageCore -AppRuntimeReportPath $stageApp -PerformanceReceiptPath $artifactFiles['performance.json'] -PerformanceRawSourcePath $artifactFiles['performance-raw.json'] -PerformanceTelemetryBindingPath $artifactFiles['performance-telemetry-binding.json'] -PerformanceTransactionCommitPath $artifactFiles['performance-transaction-commit.json'] -SoakReceiptPath $artifactFiles['soak.json'] -HerdrExecutablePath $artifactFiles['herdr.exe'] -ControlSessionIdentity 'acceptance' -TargetSessionIdentity 'v02-agent-lab'
        try{$manifestLeaf=@($staged.OwnedLeaves|Where-Object Path -EQ $staged.ManifestPath)[0];$manifestLeaf.HeldStream.Position=0;$buffer=New-Object byte[] ([int]$manifestLeaf.HeldStream.Length);$read=$manifestLeaf.HeldStream.Read($buffer,0,$buffer.Length);if($read-ne$buffer.Length){throw 'Held staged manifest ended early.'};$stagedManifest=(New-Object Text.UTF8Encoding($false,$true)).GetString($buffer)|ConvertFrom-Json;$stagedBindingPath=[string]$stagedManifest.Performance.TelemetryBinding.Path;$stagedCommitPath=[string]$stagedManifest.Performance.TransactionCommit.Path;$heldBinding=@($staged.OwnedLeaves|Where-Object Path -EQ $stagedBindingPath)[0];$heldCommit=@($staged.OwnedLeaves|Where-Object Path -EQ $stagedCommitPath)[0];Assert-True ($heldBinding.Sha256-ceq[string]$stagedManifest.Performance.TelemetryBinding.Sha256-and$heldCommit.Sha256-ceq[string]$stagedManifest.Performance.TransactionCommit.Sha256) 'Staged sidecar/commit hashes were not exact.';$blocked=$false;try{[IO.File]::WriteAllText($stagedBindingPath,'tamper')}catch{$blocked=$true};Assert-True $blocked 'Held staged telemetry binding was writable before finalization.'}finally{Close-Issue10OwnedLeaves $staged.OwnedLeaves}
        Pass-Test 'same-run transaction stages and holds exact telemetry sidecar and commit authority'
        $captures=@();foreach($name in @('dashboard-overview','widget-compact','widget-normal','widget-floating-vertical')){$path=Join-Path $fixture ($name+'.png');&$writeUtf8 $path ("capture-$name");$captures+=,[pscustomobject][ordered]@{Name=$name;Path=$path;Sha256=(Get-FileHash $path -Algorithm SHA256).Hash;PixelWidth=1;PixelHeight=1;StateSequence=1;StateSha256=$stateHash;Language='Thai';LanguageCultureName='th-TH';ObservedUtc=($(if($name-eq'dashboard-overview'){$dashboardUtc}else{$widgetUtc})).ToString('O')}}
        $semantic=[pscustomobject][ordered]@{Ordinal=1;Phase='initial';EventBinding='InitialLiveState';BoundCaptures=@([pscustomobject]@{FileName='dashboard-overview.png'},[pscustomobject]@{FileName='widget-compact.png'});ObservedUtc=$widgetUtc.ToString('O');Sequence=1;NormalizedStateSha256=$stateHash;SourceState=[pscustomobject]@{Agents=@([pscustomobject]@{AgentIdentitySha256='1'*64;WorkspaceIdentitySha256='2'*64;TabIdentitySha256='3'*64;PaneIdentitySha256='4'*64;Status='Blocked';Revision=1;StateChangeSequence=1},[pscustomobject]@{AgentIdentitySha256='5'*64;WorkspaceIdentitySha256='6'*64;TabIdentitySha256='7'*64;PaneIdentitySha256='8'*64;Status='Done';Revision=2;StateChangeSequence=2})}}
        $appReport=[pscustomobject][ordered]@{EvidenceClassification='RuntimeCandidate';CoreStateObserved=$true;SessionControlInvoked=$false;StartedUtc=$started.ToString('O');FinishedUtc=$finished.ToString('O');RendererEvidence=[pscustomobject]@{SoftwareOnlyThroughout=$true};Language='Thai';LanguageStableThroughFinish=$true;ResourceMeasurement=[pscustomobject]@{SampleCount=1;CpuTargetPassed=$true;WorkingSetTargetPassed=$true};WidgetLatencySamples=1;WidgetLatencyMinimumSamples=1;WidgetLatencyP95Milliseconds=1.0;WidgetLatencyTargetPassed=$true;WidgetLatencyIncludedSamples=@([pscustomobject]@{});SemanticStateCaptures=@($semantic);Captures=$captures;CompositeCandidateChecksPassed=$true}
        $appReportPath=Join-Path $fixture 'complete-app-runtime.json';&$writeUtf8 $appReportPath (($appReport|ConvertTo-Json -Depth 20 -Compress)+"`n")
        $authorityFile={param($path)[pscustomobject][ordered]@{Path=[IO.Path]::GetFullPath($path);Sha256=(Get-FileHash $path -Algorithm SHA256).Hash}}
        $manifest=[pscustomobject][ordered]@{SchemaVersion=1;EvidenceClassification='Issue10ProductionBinding';Issue=10;EvidenceRoot=[IO.Path]::GetFullPath($fixture);RunNonce=$runNonce;EvidenceStartedUtc=$started.AddSeconds(-1).ToString('O');Source=[pscustomobject][ordered]@{CommitSha=$commit;TreeSha=$tree};GateReport=&$authorityFile $artifactFiles['gate.txt'];CoreRuntimeReport=&$authorityFile $artifactFiles['core.json'];Package=[pscustomobject][ordered]@{Identity=&$authorityFile $artifactFiles['identity.json'];IdentityReceiptSha256='9'*64;Archive=&$authorityFile $artifactFiles['archive.zip'];Manifest=&$authorityFile $artifactFiles['package.json'];App=&$authorityFile $artifactFiles['package-app.exe'];Core=&$authorityFile $artifactFiles['package-core.exe']};Performance=[pscustomobject][ordered]@{Receipt=&$authorityFile $artifactFiles['performance.json'];RawSource=&$authorityFile $artifactFiles['performance-raw.json'];TelemetryBinding=&$authorityFile $artifactFiles['performance-telemetry-binding.json'];TransactionCommit=&$authorityFile $artifactFiles['performance-transaction-commit.json'];RuntimeAppPath=[IO.Path]::GetFullPath($artifactFiles['package-app.exe']);RuntimeCorePath=[IO.Path]::GetFullPath($artifactFiles['package-core.exe'])};SoakReceipt=&$authorityFile $artifactFiles['soak.json'];Runtime=[pscustomobject][ordered]@{HerdrExecutable=&$authorityFile $artifactFiles['herdr.exe'];ControlSessionIdentity='acceptance';TargetSessionIdentity='v02-agent-lab'};EvidenceBoundary=[pscustomobject][ordered]@{Runtime='NOT_OBSERVED';Human='NOT_OBSERVED';Release='NOT_OBSERVED';CreditGranted=$false}}
        $manifestPath=Join-Path $fixture 'complete-binding.json';&$writeUtf8 $manifestPath (($manifest|ConvertTo-Json -Depth 20 -Compress)+"`n")
        $invokeComplete={param($widget,$receipt,$key)$args=@('--finalize-issue10-widget-report','--issue10-widget-report',$widget,'--issue10-output-receipt',$receipt,'--issue10-binding-manifest',$manifestPath,'--runtime-evidence-report',$appReportPath,'--issue10-run-nonce',$runNonce,'--issue10-source-commit',$commit,'--issue10-source-tree',$tree);$prior=[Environment]::GetEnvironmentVariable('HERDROPS_ISSUE10_OUTPUT_RECEIPT_KEY','Process');[Environment]::SetEnvironmentVariable('HERDROPS_ISSUE10_OUTPUT_RECEIPT_KEY',$key,'Process');try{Start-Process -FilePath $appExecutable -ArgumentList $args -WindowStyle Hidden -Wait -PassThru}finally{[Environment]::SetEnvironmentVariable('HERDROPS_ISSUE10_OUTPUT_RECEIPT_KEY',$prior,'Process')}}
        $completeWidget=Join-Path $fixture 'complete-widget.json';$completeReceipt=$completeWidget+'.publication.json';$completeKey='D'*64;$completeProcess=&$invokeComplete $completeWidget $completeReceipt $completeKey
        Assert-True ($completeProcess.ExitCode-eq0) "Complete packaged App finalizer failed: $($completeProcess.ExitCode)"
        $completeHeld=Open-Issue10PublishedBinding -WidgetPath $completeWidget -ReceiptPath $completeReceipt -ReceiptKey $completeKey -RunNonce $runNonce -ProducerProcessId $completeProcess.Id
        try{Assert-True ($completeHeld.Widget.Sha256-ceq(Get-FileHash $completeWidget -Algorithm SHA256).Hash) 'Parent did not hold the exact published widget bytes.'}finally{$completeHeld.Widget.HeldStream.Dispose();$completeHeld.Receipt.HeldStream.Dispose();$completeHeld.Parent.Handle.Dispose()}
        Pass-Test 'complete manifest and reports publish through packaged App and bind held parent receipt widget identities'

        $swapWidget=Join-Path $fixture 'swap-widget.json';$swapReceipt=$swapWidget+'.publication.json';$swapKey='F'*64;$swapProcess=&$invokeComplete $swapWidget $swapReceipt $swapKey
        Assert-True ($swapProcess.ExitCode-eq0) 'Swap fixture packaged App finalizer did not publish.'
        $movedOwned=Join-Path $fixture 'swap-widget-owned-moved.json';$foreign='caller-replacement';$swapFailure=$null
        try{Open-Issue10PublishedBinding -WidgetPath $swapWidget -ReceiptPath $swapReceipt -ReceiptKey $swapKey -RunNonce $runNonce -ProducerProcessId $swapProcess.Id -AfterChildExitForTest {Move-Item -LiteralPath $swapWidget -Destination $movedOwned;[IO.File]::WriteAllText($swapWidget,$foreign)}|Out-Null}catch{$swapFailure=$_}
        Assert-True ($null-ne$swapFailure-and(Test-Path $movedOwned)-and((Get-Content $swapWidget -Raw)-ceq$foreign)) 'Post-child-exit replacement did not reach held identity rejection or altered caller bytes.'
        Pass-Test 'post-child-exit replacement reaches parent held identity guard without accepting caller replacement'

        $tamperWidget=$completeWidget;$tamperReceipt=$completeReceipt;$tamperKey=$completeKey
        $tamperFailure=$null;try{Open-Issue10PublishedBinding -WidgetPath $tamperWidget -ReceiptPath $tamperReceipt -ReceiptKey $tamperKey -RunNonce $runNonce -ProducerProcessId $completeProcess.Id -AfterChildExitForTest {$value=Get-Content $tamperReceipt -Raw|ConvertFrom-Json;$value.AuthenticationSha256='0'*64;&$writeUtf8 $tamperReceipt (($value|ConvertTo-Json -Depth 20)+"`r`n")}|Out-Null}catch{$tamperFailure=$_}
        Assert-True ($null-ne$tamperFailure-and$tamperFailure.Exception.Message.Contains('authentication failed')) 'Tampered child receipt did not reach the exact parent authentication guard.'
        Pass-Test 'post-child-exit receipt tamper reaches HMAC authentication guard'
    }else{throw "Run the governed Invoke-Build.ps1 Release prerequisite before this hostile CLI test: $appExecutable"}
}finally{if(Test-Path -LiteralPath $fixture){Remove-Item -LiteralPath $fixture -Recurse -Force}}
Write-Output "RESULT: $passed passed, 0 failed"
