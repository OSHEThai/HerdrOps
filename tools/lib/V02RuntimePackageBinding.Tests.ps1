#requires -Version 5.1
[CmdletBinding()] param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'V02RuntimePackageBinding.ps1')
. (Join-Path $PSScriptRoot '..\packaging\v0.2\V02PackageIdentity.Common.ps1')

$failures = New-Object 'System.Collections.Generic.List[string]'
function Test-Case([string]$Name,[scriptblock]$Body,[bool]$ShouldThrow=$false) {
    try { & $Body; if($ShouldThrow){throw 'Expected failure was not observed.'}; Write-Host "PASS: $Name" }
    catch { if($ShouldThrow){Write-Host "PASS: $Name"}else{$failures.Add("$Name`: $($_.Exception.Message)");Write-Host "FAIL: $Name" -ForegroundColor Red} }
}
function New-Result {
    $s='A'*64
    [pscustomobject][ordered]@{ EvidenceClass='Static/PackagedCompatibilityPreparation';Issue=149;ProfileId='p';ReceiptSha256=$s;SourceCommit='1'*40;SourceTree='2'*40;PreparationProfileFileSha256=$s;PreparationProfileCanonicalSha256=$s;ArchiveSha256=$s;PackageManifestSha256=$s;AppSha256=$s;CoreSha256=$s;ReferenceHostProfileSha256=$s;RendererPolicySha256=$s;Runtime='NOT OBSERVED';Release='NOT CLAIMED' }
}
function New-AgentListJson([string]$SessionValue=('1'*32),[string]$AgentName='v02-runtime-agent',[string]$PaneId='w1:p1',[int]$Count=1) {
    $agents=@();for($index=0;$index-lt$Count;$index++){$agents+=,[pscustomobject][ordered]@{agent='codex';agent_session=[pscustomobject][ordered]@{agent='codex';kind='id';source='herdr:codex';value=$(if($index-eq0){$SessionValue}else{('2'*32)})};agent_status='idle';cwd='Z:\HerdrOps';focused=$true;interactive_ready=$true;name=$(if($index-eq0){$AgentName}else{'v02-runtime-other'});pane_id=$(if($index-eq0){$PaneId}else{'w1:p2'});revision=1;state_change_seq=1;tab_id='w1:t1';terminal_id='term_fixture';terminal_title='HerdrOps';terminal_title_stripped='HerdrOps';workspace_id='w1'}}
    [pscustomobject][ordered]@{id='cli:agent:list';result=[pscustomobject][ordered]@{agents=$agents;type='agent_list'}}|ConvertTo-Json -Depth 8 -Compress
}
Test-Case 'exact validator result accepted' { Assert-V02RuntimePackageValidationResult (New-Result) ('1'*40) ('2'*40) }
Test-Case 'wrong source commit fails closed' { $r=New-Result;$r.SourceCommit='3'*40;Assert-V02RuntimePackageValidationResult $r ('1'*40) ('2'*40) } $true
Test-Case 'wrong source tree fails closed' { $r=New-Result;$r.SourceTree='3'*40;Assert-V02RuntimePackageValidationResult $r ('1'*40) ('2'*40) } $true
Test-Case 'lowercase hash fails closed' { $r=New-Result;$r.AppSha256='a'*64;Assert-V02RuntimePackageValidationResult $r ('1'*40) ('2'*40) } $true
Test-Case 'lowercase package manifest hash fails closed' { $r=New-Result;$r.PackageManifestSha256='a'*64;Assert-V02RuntimePackageValidationResult $r ('1'*40) ('2'*40) } $true
Test-Case 'runtime claim from preparation validator fails closed' { $r=New-Result;$r.Runtime='OBSERVED';Assert-V02RuntimePackageValidationResult $r ('1'*40) ('2'*40) } $true
Test-Case 'numeric-string issue fails closed' { $r=New-Result;$r.Issue='149';Assert-V02RuntimePackageValidationResult $r ('1'*40) ('2'*40) } $true
Test-Case 'unknown validator property fails closed' { $r=New-Result;$r|Add-Member Extra x;Assert-V02RuntimePackageValidationResult $r ('1'*40) ('2'*40) } $true
Test-Case 'missing validator property fails closed' { $r=New-Result;$r.PSObject.Properties.Remove('ArchiveSha256');Assert-V02RuntimePackageValidationResult $r ('1'*40) ('2'*40) } $true
Test-Case 'missing package manifest hash fails closed' { $r=New-Result;$r.PSObject.Properties.Remove('PackageManifestSha256');Assert-V02RuntimePackageValidationResult $r ('1'*40) ('2'*40) } $true
Test-Case 'Herdr CLI structured Agent session is observed without operator authority' { $a=ConvertFrom-V02HerdrAgentListObservation (New-AgentListJson) 'v02-runtime-target';if($a.EvidenceSource-cne'HerdrCliAgentMetadata'-or$a.ObservableByGate-ne$true-or$a.NativeSession.value-cne('1'*32)-or$a.Reference-cnotmatch'"source":"herdr:codex"'){throw 'Observed CLI metadata boundary is wrong.'} }
Test-Case 'same structured native session passes reconnect continuity' { $before=ConvertFrom-V02HerdrAgentListObservation (New-AgentListJson) 'v02-runtime-target';$after=ConvertFrom-V02HerdrAgentListObservation (New-AgentListJson) 'v02-runtime-target';$bound=Assert-V02TargetAgentSessionContinuity $before $after;if($bound.Reference-cne$before.Reference){throw 'Continuity did not retain the exact observed reference.'} }
Test-Case 'agentless target session fails closed' { $null=ConvertFrom-V02HerdrAgentListObservation (New-AgentListJson -Count 0) 'v02-runtime-target' } $true
Test-Case 'multiple target Agents fail closed' { $null=ConvertFrom-V02HerdrAgentListObservation (New-AgentListJson -Count 2) 'v02-runtime-target' } $true
Test-Case 'missing native session field fails closed' { $j=New-AgentListJson|ConvertFrom-Json;$j.result.agents[0].agent_session.PSObject.Properties.Remove('value');$null=ConvertFrom-V02HerdrAgentListObservation ($j|ConvertTo-Json -Depth 8 -Compress) 'v02-runtime-target' } $true
Test-Case 'unknown native session field fails closed' { $j=New-AgentListJson|ConvertFrom-Json;$j.result.agents[0].agent_session|Add-Member extra 'forged';$null=ConvertFrom-V02HerdrAgentListObservation ($j|ConvertTo-Json -Depth 8 -Compress) 'v02-runtime-target' } $true
Test-Case 'native session source transplant fails closed' { $j=New-AgentListJson|ConvertFrom-Json;$j.result.agents[0].agent_session.source='operator:codex';$null=ConvertFrom-V02HerdrAgentListObservation ($j|ConvertTo-Json -Depth 8 -Compress) 'v02-runtime-target' } $true
Test-Case 'post-restart native session transplant fails continuity' { $before=ConvertFrom-V02HerdrAgentListObservation (New-AgentListJson) 'v02-runtime-target';$after=ConvertFrom-V02HerdrAgentListObservation (New-AgentListJson -SessionValue ('2'*32)) 'v02-runtime-target';$null=Assert-V02TargetAgentSessionContinuity $before $after } $true
Test-Case 'post-restart Agent name transplant fails continuity' { $before=ConvertFrom-V02HerdrAgentListObservation (New-AgentListJson) 'v02-runtime-target';$after=ConvertFrom-V02HerdrAgentListObservation (New-AgentListJson -AgentName 'v02-runtime-replacement') 'v02-runtime-target';$null=Assert-V02TargetAgentSessionContinuity $before $after } $true
Test-Case 'post-restart pane transplant fails continuity' { $before=ConvertFrom-V02HerdrAgentListObservation (New-AgentListJson) 'v02-runtime-target';$after=ConvertFrom-V02HerdrAgentListObservation (New-AgentListJson -PaneId 'w1:p2') 'v02-runtime-target';$null=Assert-V02TargetAgentSessionContinuity $before $after } $true
Test-Case 'missing package binding inputs fail closed before validation' { Resolve-V02RuntimePackageBinding -IdentityPath 'Z:\definitely-missing-v02-receipt.json' -ArchivePath 'Z:\definitely-missing-v02.zip' -PackageRoot 'Z:\definitely-missing-v02-root' -RepositoryRoot $PSScriptRoot -ProfilePath $PSCommandPath -ExpectedSourceCommit ('1'*40) -ExpectedSourceTree ('2'*40) } $true
Test-Case 'governed passing-test count is exact current aggregate' { if($script:V02GovernedPassingTestCount-ne 926){throw "Governed passing-test count drifted: $script:V02GovernedPassingTestCount"} }

$temp = Join-Path ([IO.Path]::GetTempPath()) ('v02-trx-binding-' + [guid]::NewGuid().ToString('N'))
try {
    $results=Join-Path $temp 'results';$evidence=Join-Path $temp 'evidence';New-Item -ItemType Directory $results,$evidence|Out-Null
    $utf8=New-Object Text.UTF8Encoding($false);$started=[DateTime]::UtcNow.AddMinutes(-2)
    $runIds=@([guid]::NewGuid(),[guid]::NewGuid(),[guid]::NewGuid(),[guid]::NewGuid())
    $governedCounts=@(191,97,484,154)
    $runStarted=[DateTimeOffset]::UtcNow.AddMinutes(-1);$runFinished=[DateTimeOffset]::UtcNow.AddSeconds(-20)
    function Write-Trx([string]$Path,[string]$Assembly,[guid]$RunId,[int]$Total=222,[int]$Passed=222,[int]$Failed=0,[int]$NotExecuted=0,[int]$Skipped=0,[DateTimeOffset]$Start=$runStarted,[DateTimeOffset]$Finish=$runFinished) {
        $xml='<?xml version="1.0"?><TestRun id="{0}" name="{1}"><Times start="{2}" finish="{3}"/><TestDefinitions><UnitTest storage="Z:\fixture\{1}"/></TestDefinitions><ResultSummary><Counters total="{4}" passed="{5}" failed="{6}" notExecuted="{7}" skipped="{8}"/></ResultSummary></TestRun>' -f $RunId.ToString('D'),$Assembly,$Start.ToString('O'),$Finish.ToString('O'),$Total,$Passed,$Failed,$NotExecuted,$Skipped
        [IO.File]::WriteAllText($Path,$xml,$utf8)
    }
    function Write-ValidTrxSet {
        0..3|ForEach-Object{Write-Trx (Join-Path $results "test$($_+1).trx") $script:V02GovernedTestAssemblyFileNames[$_] $runIds[$_] $governedCounts[$_] $governedCounts[$_]}
    }
    function Assert-RolledBack {
        if(Test-Path -LiteralPath (Join-Path $evidence 'test-results')){throw 'Invalid TRX evidence was published.'}
        if(@(Get-ChildItem -LiteralPath $evidence -Filter '.test-results.*.staging' -Force -ErrorAction SilentlyContinue).Count-ne 0){throw 'TRX staging was not rolled back.'}
    }
    function Assert-ExactTrxFailure([string]$Expected,[scriptblock]$Body) {
        $observed=$null
        try{&$Body}catch{$observed=$_.Exception.Message}
        if($null-eq$observed){throw "Expected TRX failure was not observed: $Expected"}
        if($observed-cne$Expected){throw "Wrong TRX failure. expected='$Expected' observed='$observed'"}
        Assert-RolledBack
    }
    Write-ValidTrxSet
    Test-Case 'four exact governed fresh test runs are preserved with receipt' { $x=Save-V02FreshTrxEvidence $results $started $evidence;if($x.Total-ne 926-or$x.Passed-ne 926-or$x.Failed-ne 0-or$x.NotExecuted-ne 0-or$x.Skipped-ne 0-or-not(Test-Path -LiteralPath $x.ReceiptPath)){throw 'TRX receipt missing or counters drifted.'};if(@($x.Files.TestRunId|Sort-Object -Unique).Count-ne4){throw 'TestRun ids not bound.'};$expected=@($script:V02GovernedTestAssemblyFileNames|ForEach-Object{[IO.Path]::ChangeExtension($_,'.trx')}|Sort-Object);$actual=@($x.Files.Name|Sort-Object);if(@(Compare-Object $expected $actual).Count-ne0){throw 'Canonical evidence filenames drifted.'};foreach($f in $x.Files){Assert-V02RuntimeBindingSha256 $f.Sha256 'TRX hash';if([string]$f.SourceName-cne[string]$f.Name){throw 'TRX receipt source name is not canonically derivable.'}} }
    Test-Case 'existing TRX evidence directory fails closed' { Save-V02FreshTrxEvidence $results $started $evidence } $true
    if(Test-Path -LiteralPath (Join-Path $evidence 'test-results')){Remove-Item -LiteralPath (Join-Path $evidence 'test-results') -Recurse -Force}

    Write-Trx (Join-Path $results 'test4.trx') $script:V02GovernedTestAssemblyFileNames[3] $runIds[3] 116 116
    Test-Case 'stale 888-test aggregate fails closed and rolls back' { Assert-ExactTrxFailure 'Fresh test counters are not the governed all-passing aggregate: total=888 passed=888' { Save-V02FreshTrxEvidence $results $started $evidence } }
    Write-ValidTrxSet
    Remove-Item -LiteralPath (Join-Path $results 'test4.trx')
    Test-Case 'three fresh TRX files fail closed' { Save-V02FreshTrxEvidence $results $started $evidence } $true
    Write-Trx (Join-Path $results 'test4.trx') $script:V02GovernedTestAssemblyFileNames[3] $runIds[3] 154 153 1
    Test-Case 'failed TRX counter fails closed and rolls back' { Assert-ExactTrxFailure 'Fresh test counters contain failures: failed=1' { Save-V02FreshTrxEvidence $results $started $evidence } }
    Write-Trx (Join-Path $results 'test4.trx') $script:V02GovernedTestAssemblyFileNames[3] $runIds[3] 154 154 0 1
    Test-Case 'inconsistent total=passed=926 but notExecuted=1 reaches exact skipped guard' { Assert-ExactTrxFailure 'Fresh test counters contain skipped/notExecuted tests: skipped=0 notExecuted=1' { Save-V02FreshTrxEvidence $results $started $evidence } }
    Write-Trx (Join-Path $results 'test4.trx') $script:V02GovernedTestAssemblyFileNames[3] $runIds[3] 154 154 0 0 1
    Test-Case 'inconsistent total=passed=926 but skipped=1 reaches exact skipped guard' { Assert-ExactTrxFailure 'Fresh test counters contain skipped/notExecuted tests: skipped=1 notExecuted=0' { Save-V02FreshTrxEvidence $results $started $evidence } }

    Write-ValidTrxSet
    $oldStart=[DateTimeOffset]::UtcNow.AddHours(-2);$oldFinish=$oldStart.AddMinutes(1)
    0..3|ForEach-Object{Write-Trx (Join-Path $results "test$($_+1).trx") $script:V02GovernedTestAssemblyFileNames[$_] $runIds[$_] $governedCounts[$_] $governedCounts[$_] 0 0 0 $oldStart $oldFinish}
    Test-Case 'touched old 926 TRX set fails exact run-window guard' { Assert-ExactTrxFailure 'TRX TestRun is outside the exact invocation window: test1.trx' { Save-V02FreshTrxEvidence $results $started $evidence } }
    Write-ValidTrxSet;[IO.File]::SetLastWriteTimeUtc((Join-Path $results 'test1.trx'),[DateTime]::UtcNow.AddMinutes(5))
    Test-Case 'future-dated TRX fails exact file-window guard' { Assert-ExactTrxFailure 'TRX file timestamp is outside the exact invocation window: test1.trx' { Save-V02FreshTrxEvidence $results $started $evidence } }

    Write-ValidTrxSet
    $script:mutationPath=Join-Path $results 'test1.trx';$script:mutationOldId=$runIds[0].ToString('D');$script:mutationNewId=[guid]::NewGuid().ToString('D');$script:mutationEncoding=$utf8
    $script:V02TrxAfterSelectionForTest={ $stamp=[IO.File]::GetLastWriteTimeUtc($script:mutationPath);$text=[IO.File]::ReadAllText($script:mutationPath).Replace($script:mutationOldId,$script:mutationNewId);[IO.File]::WriteAllText($script:mutationPath,$text,$script:mutationEncoding);[IO.File]::SetLastWriteTimeUtc($script:mutationPath,$stamp) }
    try { Test-Case 'same-length post-selection mutation with restored mtime fails exact hash/run guard' { Assert-ExactTrxFailure 'TRX preselection identity/hash/run binding changed: test1.trx' { Save-V02FreshTrxEvidence $results $started $evidence } } }
    finally { $script:V02TrxAfterSelectionForTest=$null;Write-ValidTrxSet }

    $script:V02TrxAfterFinalCopyForTest={param($stage);$path=Join-Path $stage 'HerdrOps.UnitTests.trx';$bytes=[IO.File]::ReadAllBytes($path);$bytes[0]=$bytes[0]-bxor 1;[IO.File]::WriteAllBytes($path,$bytes)}
    try { Test-Case 'final staged copy mutation fails exact guard and rolls back' { Assert-ExactTrxFailure 'Final staged TRX copy changed after validation: HerdrOps.UnitTests.trx' { Save-V02FreshTrxEvidence $results $started $evidence } } }
    finally { $script:V02TrxAfterFinalCopyForTest=$null }
    $script:V02TrxAfterReceiptWriteForTest={param($path);$bytes=[IO.File]::ReadAllBytes($path);$bytes[0]=$bytes[0]-bxor 1;[IO.File]::WriteAllBytes($path,$bytes)}
    try { Test-Case 'receipt mutation fails exact guard and rolls back' { Assert-ExactTrxFailure 'TRX selection receipt changed after atomic write.' { Save-V02FreshTrxEvidence $results $started $evidence } } }
    finally { $script:V02TrxAfterReceiptWriteForTest=$null }

    $script:blockedPublishWrites=0
    $script:V02TrxBeforePublishForTest={param($stage,$destination);foreach($path in @((Join-Path $stage 'HerdrOps.UnitTests.trx'),(Join-Path $stage 'selection-receipt.json'))){try{[IO.File]::AppendAllText($path,'x')}catch{$script:blockedPublishWrites++}}}
    try { Test-Case 'held handles block TRX and receipt writes through atomic publication' { $x=Save-V02FreshTrxEvidence $results $started $evidence;if($script:blockedPublishWrites-ne2-or-not(Test-Path $x.ReceiptPath)){throw 'Pre-publish held-handle guard was not observed.'} } }
    finally { $script:V02TrxBeforePublishForTest=$null;if(Test-Path (Join-Path $evidence 'test-results')){Remove-Item (Join-Path $evidence 'test-results') -Recurse -Force} }

    $script:V02TrxBeforePublishForTest={param($stage,$destination);$path=Join-Path $stage 'HerdrOps.UnitTests.trx';$bytes=[IO.File]::ReadAllBytes($path);Remove-Item $path -Force;$bytes[0]=$bytes[0]-bxor 1;[IO.File]::WriteAllBytes($path,$bytes)}
    try { Test-Case 'delete-replace during publish is detected and owned target rolls back' { Assert-ExactTrxFailure 'Held TRX evidence changed across atomic publication: HerdrOps.UnitTests.trx' { Save-V02FreshTrxEvidence $results $started $evidence } } }
    finally { $script:V02TrxBeforePublishForTest=$null }

    $script:V02TrxBeforePublishForTest={param($stage,$destination);New-Item -ItemType Directory -Path $destination|Out-Null;[IO.File]::WriteAllText((Join-Path $destination 'unowned.txt'),'unowned')}
    try { Test-Case 'destination collision preserves unowned target and rolls back only staging' { $threw=$false;try{Save-V02FreshTrxEvidence $results $started $evidence}catch{$threw=$true};if(-not$threw){throw 'Destination collision did not fail.'};if(-not(Test-Path (Join-Path $evidence 'test-results\unowned.txt'))){throw 'Unowned target was deleted.'};if(@(Get-ChildItem $evidence -Filter '.test-results.*.staging' -Force).Count-ne0){throw 'Owned staging was not rolled back.'} } }
    finally { $script:V02TrxBeforePublishForTest=$null;if(Test-Path (Join-Path $evidence 'test-results')){Remove-Item (Join-Path $evidence 'test-results') -Recurse -Force} }

    $bindingFiles=@{};foreach($name in @('identity','profile','archive','manifest','app','core')){$path=Join-Path $temp "$name.bin";[IO.File]::WriteAllText($path,"original-$name");$bindingFiles[$name]=$path}
    $binding=[pscustomobject]@{
        IdentityPath=$bindingFiles.identity;IdentityFileSha256=(Get-FileHash $bindingFiles.identity -Algorithm SHA256).Hash
        ProfilePath=$bindingFiles.profile;ProfileFileSha256=(Get-FileHash $bindingFiles.profile -Algorithm SHA256).Hash
        ArchivePath=$bindingFiles.archive;ArchiveSha256=(Get-FileHash $bindingFiles.archive -Algorithm SHA256).Hash
        ManifestPath=$bindingFiles.manifest;ManifestSha256=(Get-FileHash $bindingFiles.manifest -Algorithm SHA256).Hash
        AppPath=$bindingFiles.app;AppSha256=(Get-FileHash $bindingFiles.app -Algorithm SHA256).Hash
        CorePath=$bindingFiles.core;CoreSha256=(Get-FileHash $bindingFiles.core -Algorithm SHA256).Hash
    }
    foreach($name in @('identity','profile','archive','manifest','app','core')){
        Test-Case "mutated $name bytes fail closed" { [IO.File]::AppendAllText($bindingFiles[$name],'tamper');try{$null=Assert-V02RuntimePackageExecutablesUnchanged $binding}finally{[IO.File]::WriteAllText($bindingFiles[$name],"original-$name")} } $true
    }

    $actualRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    $fixtureRepo=Join-Path $temp 'package-repo';$fixtureRoot=Join-Path $temp 'package-root';$fixtureArchive=Join-Path $temp 'HerdrOps-0.2.0-win-x64.zip';$fixtureReceipt=Join-Path $temp 'identity.json'
    New-Item -ItemType Directory (Join-Path $fixtureRepo 'Plan\reference-hosts'),(Join-Path $fixtureRepo 'tools\lib'),(Join-Path $fixtureRepo 'tools\packaging\v0.2'),$fixtureRoot -Force|Out-Null
    foreach($pair in @(
        @('Plan\reference-hosts\v0.2.json','Plan\reference-hosts\v0.2.json'),@('Plan\reference-hosts\reference-host-profile.schema.json','Plan\reference-hosts\reference-host-profile.schema.json'),
        @('tools\lib\V02ReferenceHostProfile.ps1','tools\lib\V02ReferenceHostProfile.ps1'),@('tools\packaging\v0.2\package-identity-profile.json','tools\packaging\v0.2\package-identity-profile.json'),
        @('tools\packaging\v0.2\package-identity-receipt.schema.json','tools\packaging\v0.2\package-identity-receipt.schema.json'),@('tools\packaging\v0.2\V02PackageIdentity.Common.ps1','tools\packaging\v0.2\V02PackageIdentity.Common.ps1'),
        @('tools\packaging\v0.2\Test-V02PackageIdentity.ps1','tools\packaging\v0.2\Test-V02PackageIdentity.ps1'),@('tools\packaging\Packaging.Common.ps1','tools\packaging\Packaging.Common.ps1'))){Copy-Item (Join-Path $actualRoot $pair[0]) (Join-Path $fixtureRepo $pair[1])}
    & git -C $fixtureRepo init --quiet;& git -C $fixtureRepo -c user.name=HerdrOps-Test -c user.email=test@example.invalid add --all;& git -C $fixtureRepo -c user.name=HerdrOps-Test -c user.email=test@example.invalid commit --quiet -m fixture;if($LASTEXITCODE){throw 'fixture git commit failed'};$global:LASTEXITCODE=0
    $fixtureProfilePath=Join-Path $fixtureRepo 'tools\packaging\v0.2\package-identity-profile.json';$fixtureProfile=Read-V02PackageIdentityProfile $fixtureProfilePath
    [IO.File]::WriteAllBytes((Join-Path $fixtureRoot 'HerdrOps.App.exe'),[byte[]](1,2,3));[IO.File]::WriteAllBytes((Join-Path $fixtureRoot 'HerdrOps.Core.exe'),[byte[]](4,5,6))
    $fixtureManifest=New-V02PackageManifestObject $fixtureProfile $fixtureRepo $fixtureRoot;$fixtureManifestPath=Join-Path $fixtureRoot 'package-manifest.json';Write-V02CanonicalJsonFile $fixtureManifest $fixtureManifestPath $fixtureRepo
    $null=New-DeterministicPackageArchive -PackageRoot $fixtureRoot -ArchivePath $fixtureArchive;$gitId=Get-V02GitIdentity $fixtureRepo -RequireClean;$profileId=Get-V02PreparationProfileIdentity $fixtureProfilePath $fixtureProfile $fixtureRepo
    $inventory=Get-V02PackageRootInventory $fixtureRoot -ExcludeRelativePath @('package-manifest.json');$manifestStable=Get-V02StableFileIdentity $fixtureManifestPath;$archiveStable=Get-V02StableFileIdentity $fixtureArchive;$appEntry=@($inventory.Entries|Where-Object Path -CEQ 'HerdrOps.App.exe')[0];$coreEntry=@($inventory.Entries|Where-Object Path -CEQ 'HerdrOps.Core.exe')[0]
    $fixtureIdentity=[pscustomobject][ordered]@{schemaVersion=1;profileId=$fixtureProfile.profileId;issue=149;packageVersion='0.2.0';runtimeIdentifier='win-x64';source=[pscustomobject][ordered]@{commitSha=$gitId.CommitSha;treeSha=$gitId.TreeSha};profile=[pscustomobject][ordered]@{id=$profileId.Id;relativePath=$profileId.RelativePath;bytes=[int64]$profileId.Bytes;fileSha256=$profileId.FileSha256;canonicalSha256=$profileId.CanonicalSha256};archive=[pscustomobject][ordered]@{relativePath=$fixtureProfile.archiveFileName;fileName=$fixtureProfile.archiveFileName;bytes=[int64]$archiveStable.Length;sha256=$archiveStable.Sha256};packageManifest=[pscustomobject][ordered]@{fileName='package-manifest.json';bytes=[int64]$manifestStable.Length;sha256=$manifestStable.Sha256;contentSha256=$fixtureManifest.contentSha256;fileCount=[int]$fixtureManifest.fileCount;totalBytes=[int64]$fixtureManifest.totalBytes};components=[pscustomobject][ordered]@{app=[pscustomobject][ordered]@{relativePath='HerdrOps.App.exe';bytes=[int64]$appEntry.Length;sha256=$appEntry.Sha256};core=[pscustomobject][ordered]@{relativePath='HerdrOps.Core.exe';bytes=[int64]$coreEntry.Length;sha256=$coreEntry.Sha256}};referenceHost=[pscustomobject][ordered]@{profileId=$fixtureProfile.referenceHost.profileId;profileSha256=$fixtureProfile.referenceHost.profileSha256};renderer=[pscustomobject][ordered]@{policy=$fixtureProfile.renderer.policy;wpfProcessRenderMode=$fixtureProfile.renderer.wpfProcessRenderMode};evidenceBoundary=[pscustomobject][ordered]@{evidenceClass='PackagedCompatibilityPreparation';runtimeUse='not-used';actualHerdrUsed=$false;runtimeCredit='NOT CLAIMED';releaseCredit='NOT CLAIMED'}}
    Write-V02CanonicalJsonFile $fixtureIdentity $fixtureReceipt $fixtureRepo
    $resolveArgs=@{IdentityPath=$fixtureReceipt;ArchivePath=$fixtureArchive;PackageRoot=$fixtureRoot;RepositoryRoot=$fixtureRepo;ProfilePath=$fixtureProfilePath;ExpectedSourceCommit=$gitId.CommitSha;ExpectedSourceTree=$gitId.TreeSha}
    Test-Case 'complete package validates twice and finalizes unchanged' { $b=Resolve-V02RuntimePackageBinding @resolveArgs;if([string]$b.ManifestSha256 -cne [string]$b.ValidationResult.PackageManifestSha256){throw 'Bound manifest hash does not match the committed validator result.'};$null=Assert-V02RuntimePackageExecutablesUnchanged $b }
    $originalCommittedValidator=${function:script:Invoke-V02CommittedPackageValidator}
    $contradictoryManifestHash=if($manifestStable.Sha256-cne('0'*64)){'0'*64}else{'F'*64}
    $script:V02ContradictoryManifestValidatorProbe=@{Calls=0;Original=$originalCommittedValidator;Hash=$contradictoryManifestHash}
    try {
        Set-Item -LiteralPath Function:\script:Invoke-V02CommittedPackageValidator -Value {
            param([string]$ValidatorPath,[string]$IdentityPath,[string]$ArchivePath,[string]$PackageRoot,[string]$RepositoryRoot,[string]$ProfilePath,[string]$ExpectedSourceCommit,[string]$ExpectedSourceTree)
            $result=& $script:V02ContradictoryManifestValidatorProbe.Original @PSBoundParameters
            $script:V02ContradictoryManifestValidatorProbe.Calls++
            $result.PackageManifestSha256=$script:V02ContradictoryManifestValidatorProbe.Hash
            Assert-V02RuntimePackageValidationResult -Result $result -ExpectedSourceCommit $ExpectedSourceCommit -ExpectedSourceTree $ExpectedSourceTree
            return $result
        }
        Test-Case 'schema-valid contradictory validator manifest hash fails inside production resolver' {
            $observed=$null
            try{$null=Resolve-V02RuntimePackageBinding @resolveArgs}catch{$observed=$_.Exception.Message}
            $expected='Package manifest bytes do not match the committed validator result.'
            if($observed-cne$expected){throw "Wrong manifest contradiction failure. expected='$expected' observed='$observed'"}
            if($script:V02ContradictoryManifestValidatorProbe.Calls-ne2){throw 'Hostile validator fixture did not reach both committed-validator passes.'}
        }
    } finally {
        Set-Item -LiteralPath Function:\script:Invoke-V02CommittedPackageValidator -Value $originalCommittedValidator
        $script:V02ContradictoryManifestValidatorProbe=$null
    }
    foreach($case in @(@{Name='identity';Path=$fixtureReceipt},@{Name='manifest';Path=$fixtureManifestPath},@{Name='profile';Path=$fixtureProfilePath})){
        $original=[IO.File]::ReadAllBytes($case.Path);$mutationPath=$case.Path;$script:V02RuntimePackageBindingAfterValidatorForTest={ [IO.File]::AppendAllText($mutationPath,' ') }
        try { Test-Case "after-validator $($case.Name) swap fails closed" { Resolve-V02RuntimePackageBinding @resolveArgs } $true }
        finally { $script:V02RuntimePackageBindingAfterValidatorForTest=$null;[IO.File]::WriteAllBytes($case.Path,$original) }
    }
} finally { if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Recurse -Force} }

if($failures.Count){$failures|ForEach-Object{Write-Host $_ -ForegroundColor Red};exit 1}
Write-Host 'All v0.2 runtime/package binding hostile tests passed.' -ForegroundColor Green
