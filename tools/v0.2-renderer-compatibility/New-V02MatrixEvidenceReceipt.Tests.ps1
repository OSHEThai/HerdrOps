#requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'RendererCompatibility.Common.ps1')
$scriptPath=Join-Path $PSScriptRoot 'New-V02MatrixEvidenceReceipt.ps1'
$cases=@(Get-RendererGovernedMatrixCases)
if($cases.Count-ne25){throw "Expected exactly 25 governed matrix cases; observed $($cases.Count)."}
$tempBase=Join-Path $env:TEMP "HerdrOps-MatrixTests-$([guid]::NewGuid())"
$repositoryRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

function Expect-Failure {param([string]$Name,[scriptblock]$Action,[string]$ExpectedSubstring='');$failed=$false;$message='';try{&$Action}catch{$failed=$true;$message=$_.Exception.Message};if(-not$failed){throw "Expected hostile '$Name' to fail."};if($ExpectedSubstring-and$message-notmatch[regex]::Escape($ExpectedSubstring)){throw "Hostile '$Name' reached the wrong guard. Expected '$ExpectedSubstring'; observed '$message'."};Write-Host "PASS negative: $Name"}
function Copy-Map($Map){$copy=@{};foreach($key in $Map.Keys){$copy[$key]=$Map[$key]};return $copy}
function New-RawPayload {
    param([string]$CaseId,[string]$ObservedUtc,[bool]$Passed=$true,[string]$ProvenanceKind='SyntheticFixture',[hashtable]$Overrides=@{})
    $contract=Get-RendererMatrixCaseContract $CaseId
    $checks=@($contract.Checks|ForEach-Object{[pscustomobject][ordered]@{name=$_;observedValue=if($Passed){Get-RendererMatrixExpectedCheckValue $_}else{'FAIL'}}})
    $provenance=if($ProvenanceKind-ceq'ActualHerdrRuntime'){
        [pscustomobject][ordered]@{kind='ActualHerdrRuntime';collector='HerdrOpsMatrixRuntimeCollector';actualHerdrObserved=$true;candidate=[pscustomobject][ordered]@{commitSha='0'*40;treeSha='0'*40;packageReceipt=[pscustomobject][ordered]@{relativePath='missing.json';bytes=1;fileSha256='A'*64;canonicalSha256='B'*64}};session=[pscustomobject][ordered]@{kind='LocalConsole';elevated=$false;userScope='SingleUser';processId=1;processStartUtc='2026-08-22T11:59:00.0000000+00:00';executablePath='C:\HerdrOps.App.exe';executableSha256='A'*64};semanticEvent=[pscustomobject][ordered]@{caseId=$CaseId;eventName="matrix-case-observed:$CaseId";observedUtc=$ObservedUtc}}
    }else{[pscustomobject][ordered]@{kind=$ProvenanceKind;collector=switch($ProvenanceKind){'StaticInspection'{'RendererMatrixStaticInspector'};'ContractHarness'{'RendererMatrixContractHarness'};default{'RendererMatrixSyntheticFixture'}};actualHerdrObserved=$false}}
    $payload=[pscustomobject][ordered]@{schemaVersion=2;caseId=$CaseId;observedUtc=$ObservedUtc;observation=[pscustomobject][ordered]@{kind=$contract.Kind;target=$CaseId;checks=$checks};provenance=$provenance;details="typed observation for $CaseId"}
    foreach($key in $Overrides.Keys){switch($key){'ObservationKind'{$payload.observation.kind=$Overrides[$key]};'Target'{$payload.observation.target=$Overrides[$key]};'ActualHerdrObserved'{$payload.provenance.actualHerdrObserved=$Overrides[$key]};'Collector'{$payload.provenance.collector=$Overrides[$key]};default{throw "Unknown raw override '$key'."}}}
    return $payload
}
function Write-TestJson($Value,[string]$Path){$parent=[IO.Path]::GetDirectoryName($Path);if(-not[IO.Directory]::Exists($parent)){[IO.Directory]::CreateDirectory($parent)|Out-Null};Write-RendererPackageCanonicalJson -Value $Value -Path $Path -RepositoryRoot $repositoryRoot}
function New-RawSet {
    param([string]$Root,[int]$FailIndex=-1,[int]$OutOfOrderIndex=-1,[string]$ProvenanceKind='SyntheticFixture')
    New-Item -ItemType Directory -Path (Join-Path $Root 'raw') -Force|Out-Null;$paths=@{};$outcomes=@{}
    for($i=0;$i-lt$cases.Count;$i++){$case=$cases[$i];$paths[$case]="raw/$case.json";$outcomes[$case]='PASS';$second=if($i-eq$OutOfOrderIndex){0}else{$i};$utc=('2026-08-22T12:00:{0:00}.0000000+00:00'-f$second);Write-TestJson (New-RawPayload $case $utc ($i-ne$FailIndex) $ProvenanceKind) (Join-Path $Root $paths[$case])}
    return [pscustomobject]@{Paths=$paths;Outcomes=$outcomes}
}
function New-Common([string]$Root,$Set){return @{OperatorIdentity='@operator';OperatorRole='EvidenceOperator';ObserverIdentity='@observer';ObserverRole='IndependentObserver';EvidenceBoundary='Synthetic';Outcomes=$Set.Outcomes;RawEvidencePaths=$Set.Paths;ObservedUtc='2026-08-22T12:00:30.0000000+00:00';EvidenceRoot=$Root;RepositoryRoot=$repositoryRoot}}
function Start-ProducerChild {
    param([string]$Root,[string]$Destination,[int]$PauseMilliseconds)
    $runner=Join-Path $Root ('runner-'+[guid]::NewGuid().ToString('N')+'.ps1');$errorPath=$runner+'.error'
    $source=@'
param([string]$Producer,[string]$Root,[string]$Destination,[string]$Repository,[int]$Pause,[string]$ErrorPath)
$ErrorActionPreference='Stop'
. (Join-Path (Split-Path $Producer) 'RendererCompatibility.Common.ps1')
$raw=@{};$outcomes=@{};foreach($case in @(Get-RendererGovernedMatrixCases)){$raw[$case]="raw/$case.json";$outcomes[$case]='PASS'}
try{$null=& $Producer -DestinationPath $Destination -OperatorIdentity '@child-op' -OperatorRole EvidenceOperator -ObserverIdentity '@child-observer' -ObserverRole IndependentObserver -EvidenceBoundary Synthetic -Outcomes $outcomes -RawEvidencePaths $raw -ObservedUtc '2026-08-22T12:00:30.0000000+00:00' -EvidenceRoot $Root -RepositoryRoot $Repository -PauseAfterStagingReadyMilliseconds $Pause}catch{[IO.File]::WriteAllText($ErrorPath,$_.Exception.Message,(New-Object Text.UTF8Encoding($false)));exit 1}
'@
    [IO.File]::WriteAllText($runner,$source,(New-Object Text.UTF8Encoding($false)))
    $engine=(Get-Process -Id $PID).Path;$psi=New-Object Diagnostics.ProcessStartInfo;$psi.FileName=$engine;$psi.Arguments="-NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$runner`" -Producer `"$scriptPath`" -Root `"$Root`" -Destination `"$Destination`" -Repository `"$repositoryRoot`" -Pause $PauseMilliseconds -ErrorPath `"$errorPath`"";$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
    $process=[Diagnostics.Process]::Start($psi);$process|Add-Member -NotePropertyName ErrorPath -NotePropertyValue $errorPath;return $process
}
function Wait-Staging([string]$Root,[int]$TimeoutSeconds=15){$limit=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds);do{$found=@(Get-ChildItem -LiteralPath $Root -Directory -Filter '.matrix-receipts-staging-*' -ErrorAction SilentlyContinue|Where-Object{Test-Path -LiteralPath (Join-Path $_.FullName '.owner.json')});if($found.Count){return $found[0].FullName};Start-Sleep -Milliseconds 100}while([DateTime]::UtcNow-lt$limit);throw 'Timed out waiting for owned staging marker.'}

try{
    New-Item -ItemType Directory -Path $tempBase|Out-Null
    $root=Join-Path $tempBase 'positive';New-Item -ItemType Directory -Path $root|Out-Null;$set=New-RawSet $root;$common=New-Common $root $set;$destination=Join-Path $root 'receipts';$files=@(&$scriptPath -DestinationPath $destination @common)
    if($files.Count-ne25){throw 'Expected exactly 25 published receipts.'};for($i=0;$i-lt25;$i++){$receipt=Get-Content -LiteralPath $files[$i] -Raw|ConvertFrom-Json;if($receipt.caseId-cne$cases[$i]-or$receipt.outcome-cne'PASS'-or$receipt.evidenceBoundary.evidenceClass-cne'Synthetic'-or$receipt.evidenceBoundary.finalHumanGo-cne'NOT_OBSERVED'-or$receipt.evidenceBoundary.release-cne'NOT_OBSERVED'-or[bool]$receipt.evidenceBoundary.creditGranted){throw 'Receipt authority/order mismatch.'}}
    Write-Host 'PASS positive: exact typed governed 25-set derives PASS/Synthetic and preserves no-credit'

    $autoRoot=Join-Path $tempBase 'auto';New-Item -ItemType Directory -Path $autoRoot|Out-Null;$autoSet=New-RawSet $autoRoot;$auto=@{OperatorIdentity='@op';OperatorRole='EvidenceOperator';ObserverIdentity='@obs';ObserverRole='IndependentObserver';RawEvidencePaths=$autoSet.Paths;ObservedUtc='2026-08-22T12:00:30.0000000+00:00';EvidenceRoot=$autoRoot;RepositoryRoot=$repositoryRoot};$null=&$scriptPath -DestinationPath (Join-Path $autoRoot 'receipts') @auto;Write-Host 'PASS positive: outcome and evidence class are independently derived without caller assertions'

    Expect-Failure 'pre-existing destination no-clobber' {&$scriptPath -DestinationPath $destination @common} 'already exists; receipt publication is no-clobber'
    $crashRoot=Join-Path $tempBase 'rollback';New-Item -ItemType Directory -Path $crashRoot|Out-Null;$crashSet=New-RawSet $crashRoot;$crashCommon=New-Common $crashRoot $crashSet;Expect-Failure 'caught pre-publication crash rollback' {&$scriptPath -DestinationPath (Join-Path $crashRoot 'receipts') @crashCommon -SimulateFailureAfterReceiptCount 12} 'Simulated pre-publication interruption';if(@(Get-ChildItem $crashRoot -Directory -Filter '.matrix-receipts-staging-*').Count){throw 'Caught crash left staging.'}

    $failRoot=Join-Path $tempBase 'derived-fail';New-Item -ItemType Directory -Path $failRoot|Out-Null;$failSet=New-RawSet $failRoot 0;$failCommon=New-Common $failRoot $failSet;Expect-Failure 'caller PASS rejected against independently derived failed check' {&$scriptPath -DestinationPath (Join-Path $failRoot 'receipts') @failCommon} 'Synchronized forged PASS detected'
    $typedRoot=Join-Path $tempBase 'typed';New-Item -ItemType Directory -Path $typedRoot|Out-Null;$typedSet=New-RawSet $typedRoot;$first=$cases[0];Write-TestJson (New-RawPayload $first '2026-08-22T12:00:00.0000000+00:00' $true 'SyntheticFixture' @{ObservationKind='Accessibility'}) (Join-Path $typedRoot $typedSet.Paths[$first]);$typedCommon=New-Common $typedRoot $typedSet;Expect-Failure 'case-specific observation type mismatch' {&$scriptPath -DestinationPath (Join-Path $typedRoot 'receipts') @typedCommon} 'type/target does not match'

    $runtimeRoot=Join-Path $tempBase 'runtime';New-Item -ItemType Directory -Path $runtimeRoot|Out-Null;$runtimeSet=New-RawSet $runtimeRoot -1 -1 'ActualHerdrRuntime';$runtimeCommon=New-Common $runtimeRoot $runtimeSet;$runtimeCommon.EvidenceBoundary='Runtime';Expect-Failure 'self-authored Runtime lacks exact clean candidate and live Herdr provenance' {&$scriptPath -DestinationPath (Join-Path $runtimeRoot 'receipts') @runtimeCommon} 'claims unearned Runtime'

    foreach($index in @(1,2)){$chronRoot=Join-Path $tempBase "chronology-$index";New-Item -ItemType Directory -Path $chronRoot|Out-Null;$chronSet=New-RawSet $chronRoot -1 $index;$chronCommon=New-Common $chronRoot $chronSet;Expect-Failure "strict monotonic unique chronology $index" {&$scriptPath -DestinationPath (Join-Path $chronRoot 'receipts') @chronCommon} 'strictly increasing and unique'}
    $identity=Copy-Map $common;$identity.ObserverIdentity='@OPERATOR';Expect-Failure 'case-insensitive operator observer identity collision' {&$scriptPath -DestinationPath (Join-Path $root 'identity') @identity} 'must be distinct'
    $missing=Copy-Map $set.Paths;$missing.Remove($cases[0]);$hostile=Copy-Map $common;$hostile.RawEvidencePaths=$missing;Expect-Failure 'missing governed case' {&$scriptPath -DestinationPath (Join-Path $root 'missing') @hostile} 'exactly the 25 governed case IDs'

    $hardRoot=Join-Path $tempBase 'hardlink';New-Item -ItemType Directory -Path $hardRoot|Out-Null;$hardSet=New-RawSet $hardRoot;$secondPath=Join-Path $hardRoot $hardSet.Paths[$cases[1]];Remove-Item -LiteralPath $secondPath;New-Item -ItemType HardLink -Path $secondPath -Target (Join-Path $hardRoot $hardSet.Paths[$cases[0]])|Out-Null;$hardCommon=New-Common $hardRoot $hardSet;Expect-Failure 'hardlink raw identity alias' {&$scriptPath -DestinationPath (Join-Path $hardRoot 'receipts') @hardCommon} 'hardlink/identity alias'

    $linkRoot=Join-Path $root 'link-hostile';New-Item -ItemType Directory -Path $linkRoot|Out-Null;$junction=Join-Path $linkRoot 'raw-link';New-Item -ItemType Junction -Path $junction -Target (Join-Path $root 'raw')|Out-Null;$bad=Copy-Map $set.Paths;$bad[$cases[0]]='link-hostile/raw-link/'+$cases[0]+'.json';$hostile=Copy-Map $common;$hostile.RawEvidencePaths=$bad;Expect-Failure 'raw junction reaches reparse guard' {&$scriptPath -DestinationPath (Join-Path $root 'junction-receipts') @hostile} 'contains a reparse point'

    $childRoot=Join-Path $tempBase 'real-child';New-Item -ItemType Directory -Path $childRoot|Out-Null;$childSet=New-RawSet $childRoot;$childCommon=New-Common $childRoot $childSet;$childDest=Join-Path $childRoot 'receipts';$child=Start-ProducerChild $childRoot $childDest 120000;$orphan=Wait-Staging $childRoot;$child.Kill();$child.WaitForExit();Start-Sleep -Seconds 3;$null=&$scriptPath -DestinationPath $childDest @childCommon;if(Test-Path -LiteralPath $orphan){throw 'Dead child staging was not recovered.'};Write-Host 'PASS positive: real killed child recovered only after PID/start-time/age/marker/identity validation'

    $conRoot=Join-Path $tempBase 'concurrent';New-Item -ItemType Directory -Path $conRoot|Out-Null;$conSet=New-RawSet $conRoot;$conCommon=New-Common $conRoot $conSet;$conDest=Join-Path $conRoot 'receipts';$loser=Start-ProducerChild $conRoot $conDest 3000;$null=Wait-Staging $conRoot;$null=&$scriptPath -DestinationPath $conDest @conCommon;$loser.WaitForExit();$loserError=if(Test-Path $loser.ErrorPath){Get-Content $loser.ErrorPath -Raw}else{''};if($loser.ExitCode-eq0-or$loserError-notmatch'atomic no-clobber'){throw "Concurrent producer reached the wrong guard: $loserError"};Write-Host 'PASS negative: active producer staging preserved and exact atomic no-clobber guard selected one winner'

    $parentRoot=Join-Path $tempBase 'parent-lease';New-Item -ItemType Directory -Path $parentRoot|Out-Null;$null=New-RawSet $parentRoot;$parentChild=Start-ProducerChild $parentRoot (Join-Path $parentRoot 'receipts') 3000;$null=Wait-Staging $parentRoot;$movedParent=$parentRoot+'-swapped';Move-Item -LiteralPath $parentRoot -Destination $movedParent;New-Item -ItemType Junction -Path $parentRoot -Target $movedParent|Out-Null;$parentChild.WaitForExit();$parentError=if(Test-Path $parentChild.ErrorPath){Get-Content $parentChild.ErrorPath -Raw}else{''};if($parentChild.ExitCode-eq0-or$parentError-notmatch'evidence root is a reparse point|held directory identity changed'){throw "Destination parent swap reached the wrong guard: $parentError"};cmd /c rmdir "$parentRoot"|Out-Null;Move-Item -LiteralPath $movedParent -Destination $parentRoot;Write-Host 'PASS negative: destination-parent junction swap reaches exact reparse/final-path identity guard'

    $swapRoot=Join-Path $tempBase 'staging-swap';New-Item -ItemType Directory -Path $swapRoot|Out-Null;$null=New-RawSet $swapRoot;$swapChild=Start-ProducerChild $swapRoot (Join-Path $swapRoot 'receipts') 3000;$stage=Wait-Staging $swapRoot;$moved=$stage+'-original';Move-Item -LiteralPath $stage -Destination $moved;New-Item -ItemType Directory -Path (Join-Path $swapRoot 'junction-target')|Out-Null;New-Item -ItemType Junction -Path $stage -Target (Join-Path $swapRoot 'junction-target')|Out-Null;$swapChild.WaitForExit();$swapError=if(Test-Path $swapChild.ErrorPath){Get-Content $swapChild.ErrorPath -Raw}else{''};if($swapChild.ExitCode-eq0-or$swapError-notmatch'held directory identity changed'){throw "Staging swap reached the wrong guard: $swapError"};cmd /c rmdir "$stage"|Out-Null;Remove-Item -LiteralPath $moved -Recurse -Force;Write-Host 'PASS negative: staging junction swap reaches exact held final-path/FileId guard'

    Write-Host "All matrix receipt security tests passed for PowerShell $($PSVersionTable.PSVersion)."
}finally{if(Test-Path -LiteralPath $tempBase){Remove-Item -LiteralPath $tempBase -Recurse -Force}}
