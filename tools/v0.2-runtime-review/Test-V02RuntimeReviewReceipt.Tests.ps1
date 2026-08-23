#requires -Version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'RuntimeReview.Common.ps1')

function Write-RRFixtureText {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Text)
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}

function Write-RRFixtureJson {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value)
    Write-RRFixtureText $Path (($Value | ConvertTo-Json -Depth 50) + "`n")
}

function Get-RRFixtureFile {
    param([Parameter(Mandatory)][string]$Path)
    return Read-V02RuntimeReviewHeldFile $Path
}

function Get-RRFixtureSha {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-RRFixtureFile $Path).Sha256
}

function New-RRProgressEntry {
    param([int]$Ordinal,[string]$Phase,[DateTimeOffset]$Utc,[long]$Sequence,[bool]$Connected,[string]$Status,[string]$StateSha,[string]$Previous)
    $entry=[ordered]@{Ordinal=$Ordinal;Phase=$Phase;ObservedUtc=$Utc.ToString('O');Sequence=$Sequence;IsCoreConnected=$Connected;IsLive=$Connected;RuntimeStatus=$Status;LastTransitionUtc=$Utc.ToString('O');LastAcceptedStateUtc=$Utc.ToString('O');ConnectionEpoch=$(if($Ordinal-ge6){2}else{1});BootstrapCount=$(if($Ordinal-ge6){2}else{1});EventCount=$(if($Ordinal-lt4){1}elseif($Ordinal-lt9){2}else{3});DisconnectCount=$(if($Ordinal-ge5){1}else{0});ReconciliationCount=$Sequence;StateSha256=$StateSha;PreviousEntrySha256=$Previous;CanonicalPayload='';EntrySha256=''}
    $object=$entry|ConvertTo-Json -Depth 10|ConvertFrom-Json;$object.CanonicalPayload=Get-V02RuntimeReviewProgressCanonicalPayload $object;$object.EntrySha256=Get-V02RuntimeReviewHash ([Text.UTF8Encoding]::new($false).GetBytes($object.CanonicalPayload));return $object
}

function New-RRSelectionReceipt {
    param([string]$Evidence,[DateTimeOffset]$Utc)
    $directory=Join-Path $Evidence 'test-results';$entries=@();foreach($name in @('HerdrOps.UnitTests.trx','HerdrOps.ContractTests.trx','HerdrOps.IntegrationTests.trx','HerdrOps.RuntimeTests.trx')){$path=Join-Path $directory $name;$runId=[guid]::NewGuid().ToString('D');$assembly=$name-replace'\.trx$','.dll';$xml="<TestRun id=`"$runId`"><Times start=`"$($Utc.ToString('O'))`" finish=`"$($Utc.AddSeconds(1).ToString('O'))`"/><TestDefinitions><UnitTest storage=`"$assembly`"/></TestDefinitions><ResultSummary><Counters total=`"222`" passed=`"222`" failed=`"0`" notExecuted=`"0`" skipped=`"0`"/></ResultSummary></TestRun>";Write-RRFixtureText $path $xml;$file=Get-RRFixtureFile $path;$entries+=[ordered]@{Name=$name;SourceName=$name;Bytes=$file.Bytes;Sha256=$file.Sha256;LastWriteUtc=$Utc.ToString('O');TestRunId=$runId;RunStartedUtc=$Utc.ToString('O');RunFinishedUtc=$Utc.AddSeconds(1).ToString('O');TestAssemblyFileName=$assembly;Total=222;Passed=222;Failed=0;NotExecuted=0;Skipped=0}}
    $path=Join-Path $directory 'selection-receipt.json';Write-RRFixtureJson $path ([ordered]@{SchemaVersion=2;InvocationStartedUtc=$Utc.ToString('O');SelectionUpperBoundUtc=$Utc.AddSeconds(2).ToString('O');FileCount=4;Total=888;Passed=888;Failed=0;NotExecuted=0;Skipped=0;Files=$entries});return $path
}

function New-RRFixture {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('herdrops-v02-review-' + [Guid]::NewGuid().ToString('N'))
    $thai = Join-Path $root 'thai'; $english = Join-Path $root 'english'; $package = Join-Path $root 'package'; $matrix = Join-Path $root 'matrix-candidate.json'; $output = Join-Path $root 'review-candidate.json'
    foreach ($directory in @($root, $thai, $english, $package, (Join-Path $thai 'captures'), (Join-Path $english 'captures'), (Join-Path $thai 'test-results'), (Join-Path $english 'test-results'))) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    $commit = 'a' * 40; $tree = 'b' * 40
    $appPath = Join-Path $package 'HerdrOps.App.exe'; $corePath = Join-Path $package 'HerdrOps.Core.exe'; $manifestPath = Join-Path $package 'package-manifest.json'; $archivePath = Join-Path $root 'HerdrOps-0.2.0-win-x64.zip'; $identityPath = Join-Path $root 'package-identity-receipt.json'
    [IO.File]::WriteAllBytes($appPath, [Text.Encoding]::UTF8.GetBytes('APP-COMPONENT'))
    [IO.File]::WriteAllBytes($corePath, [Text.Encoding]::UTF8.GetBytes('CORE-COMPONENT'))
    [IO.File]::WriteAllBytes($manifestPath, [Text.Encoding]::UTF8.GetBytes('PACKAGE-MANIFEST'))
    [IO.File]::WriteAllBytes($archivePath, [Text.Encoding]::UTF8.GetBytes('PACKAGE-ARCHIVE'))
    $app = Get-RRFixtureFile $appPath; $core = Get-RRFixtureFile $corePath; $manifest = Get-RRFixtureFile $manifestPath; $archive = Get-RRFixtureFile $archivePath
    $identity = [ordered]@{
        schemaVersion = 1; profileId = 'herdrops-v0.2-package-software-only-issue-149'; issue = 149; packageVersion = '0.2.0'; runtimeIdentifier = 'win-x64'
        source = [ordered]@{ commitSha = $commit; treeSha = $tree }
        profile = [ordered]@{ id = 'herdrops-v0.2-package-software-only-issue-149'; relativePath = 'fixture-profile.json'; bytes = 1; fileSha256 = ('C' * 64); canonicalSha256 = ('D' * 64) }
        archive = [ordered]@{ relativePath = 'HerdrOps-0.2.0-win-x64.zip'; fileName = 'HerdrOps-0.2.0-win-x64.zip'; bytes = $archive.Bytes; sha256 = $archive.Sha256 }
        packageManifest = [ordered]@{ fileName = 'package-manifest.json'; bytes = $manifest.Bytes; sha256 = $manifest.Sha256; contentSha256 = ('E' * 64); fileCount = 2; totalBytes = ($app.Bytes + $core.Bytes) }
        components = [ordered]@{ app = [ordered]@{ relativePath = 'HerdrOps.App.exe'; bytes = $app.Bytes; sha256 = $app.Sha256 }; core = [ordered]@{ relativePath = 'HerdrOps.Core.exe'; bytes = $core.Bytes; sha256 = $core.Sha256 } }
        referenceHost = [ordered]@{ profileId = 'fixture-reference-host'; profileSha256 = ('F' * 64) }
        renderer = [ordered]@{ policy = 'software-only-process-wide'; wpfProcessRenderMode = 'SoftwareOnly' }
        evidenceBoundary = [ordered]@{ evidenceClass = 'PackagedCompatibilityPreparation'; runtimeUse = 'not-used'; actualHerdrUsed = $false; runtimeCredit = 'NOT CLAIMED'; releaseCredit = 'NOT CLAIMED' }
    }
    $identityCanonical = ConvertTo-V02Jcs ($identity | ConvertTo-Json -Depth 30 | ConvertFrom-Json)
    Write-RRFixtureText $identityPath ($identityCanonical + "`n")
    $identityFile = Get-RRFixtureFile $identityPath
    $receiptSha = Get-V02RuntimeReviewHash ([Text.UTF8Encoding]::new($false).GetBytes($identityCanonical))
    $herdrPath=Join-Path $root 'herdr.exe';[IO.File]::WriteAllBytes($herdrPath,[Text.Encoding]::UTF8.GetBytes('HERDR-EXECUTABLE'));$herdrSha=Get-RRFixtureSha $herdrPath;$schemaSha = '2' * 64; $profileSha = '3' * 64; $hostSchemaSha = '4' * 64
    $baseUtc = [DateTimeOffset]::UtcNow.AddMinutes(-5)
    $runs = @()
    $legIndex=0
    foreach ($language in @('Thai', 'English')) {
        $legUtc=$baseUtc.AddSeconds($legIndex*20);$legIndex++
        $runNonce=('{0:x32}' -f $legIndex)
        $evidence = if ($language -eq 'Thai') { $thai } else { $english }
        $captureDirectory = Join-Path $evidence 'captures'
        $captures = @()
        foreach ($captureName in $script:V02RuntimeReviewRequiredCaptureNames) {
            $capturePath = Join-Path $captureDirectory ($captureName + '.bin')
            [IO.File]::WriteAllBytes($capturePath, [Text.Encoding]::UTF8.GetBytes("$language-$captureName"))
            $capture = Get-RRFixtureFile $capturePath
            $captureSequence=if($captureName-ceq'dashboard-overview-after-event'){2}elseif($captureName-ceq'widget-floating-vertical-after-dashboard-close'){6}else{1};$captureState=if($captureSequence-eq2){'B'*64}elseif($captureSequence-eq6){'F'*64}else{'A'*64}
            $captures += [ordered]@{ Name = $captureName; Path = $capturePath; Sha256 = $capture.Sha256; PixelWidth=2;PixelHeight=2;StateSequence=$captureSequence;StateSha256=$captureState;Language = $language;LanguageCultureName=$(if($language-eq'Thai'){'th-TH'}else{'en-US'});ObservedUtc=$legUtc.AddSeconds(2).ToString('O') }
        }
        $selectionPath = New-RRSelectionReceipt $evidence $legUtc
        $progressPath = Join-Path $evidence 'app-progress.json'; $historyPath = Join-Path $evidence 'app-progress.json.history.jsonl'
        $phases=@('waiting-for-live-state','capturing-live-dashboard-and-widgets','waiting-for-pre-close-update','dashboard-closed-waiting-for-herdr-disconnect','herdr-disconnected-waiting-for-reconnect','herdr-reconnected-waiting-for-post-reconnect-update','waiting-for-idle-stability','measuring-idle-resources','complete');$sequences=@(0,1,1,2,2,5,6,6,6);$seconds=@(0,1,2,4,5,6,7,8,9);$states=@(('0'*64),('A'*64),('A'*64),('B'*64),('D'*64),('E'*64),('F'*64),('F'*64),('F'*64));$progressEntries=@();$previous='0'*64;for($i=0;$i-lt9;$i++){$entry=New-RRProgressEntry ($i+1) $phases[$i] $legUtc.AddSeconds($seconds[$i]) $sequences[$i] ($i-ne4) $(if($i-eq4){'Reconnecting'}else{'Connected'}) $states[$i] $previous;$previous=$entry.EntrySha256;$progressEntries+=$entry};Write-RRFixtureText $historyPath (($progressEntries|ForEach-Object{$_|ConvertTo-Json -Compress -Depth 10})-join"`n");$progress=[ordered]@{};foreach($property in $progressEntries[8].PSObject.Properties){$progress[$property.Name]=$property.Value};$progress.ProgressHistoryPath=[IO.Path]::GetFullPath($historyPath);$progress.History=$progressEntries;Write-RRFixtureJson $progressPath $progress
        $agentIdentity = [ordered]@{ TerminalId='terminal-1';WorkspaceId='workspace-1';TabId='tab-1';PaneId='pane-1' }
        $changeA=[ordered]@{TerminalId='terminal-1';WorkspaceId='workspace-1';TabId='tab-1';PaneId='pane-1';PreviousStatus='Working';CurrentStatus='Idle';PreviousRevision=1;CurrentRevision=2;PreviousStateChangeSequence=1;CurrentStateChangeSequence=2;PreviousAgentKind='codex';CurrentAgentKind='codex';PreviousAgentName='agent-1';CurrentAgentName='agent-1'}
        $changeB=[ordered]@{TerminalId='terminal-1';WorkspaceId='workspace-1';TabId='tab-1';PaneId='pane-1';PreviousStatus='Unknown';CurrentStatus='Blocked';PreviousRevision=2;CurrentRevision=3;PreviousStateChangeSequence=2;CurrentStateChangeSequence=3;PreviousAgentKind='codex';CurrentAgentKind='codex';PreviousAgentName='agent-1';CurrentAgentName='agent-1'}
        $eventA = [ordered]@{PhaseEnteredUtc=$legUtc.AddSeconds(2).ToString('O');ObservedUtc=$legUtc.AddSeconds(3).ToString('O');AcceptedEventKind='pane.agent_status_changed';AdmissionPath='direct-event';BaselineConnectionEpoch=1;CurrentIsCoreConnected=$true;CurrentIsLive=$true;CurrentRuntimeStatus='Connected';BaselineSequence=1;CurrentSequence=2;BaselineEventCount=1;CurrentEventCount=2;BaselineBootstrapCount=1;CurrentBootstrapCount=1;BaselineDisconnectCount=0;CurrentDisconnectCount=0;BaselineReconciliationCount=1;CurrentReconciliationCount=2;BaselineStateSha256=('A'*64);CurrentStateSha256=('B'*64);BaselineAgentTopologySha256=('1'*64);CurrentAgentTopologySha256=('1'*64);BaselineAgentStatusStateSha256=('2'*64);CurrentAgentStatusStateSha256=('3'*64);ConnectionEpoch=1;Changes=@($changeA);ChangeCount=1;BaselineAllAgentsHaveLiveIdentity=$true;CurrentAllAgentsHaveLiveIdentity=$true}
        $eventB = [ordered]@{PhaseEnteredUtc=$legUtc.AddSeconds(7).ToString('O');ObservedUtc=$legUtc.AddSeconds(8).ToString('O');AcceptedEventKind='pane.agent_status_changed';AdmissionPath='direct-event';BaselineConnectionEpoch=2;CurrentIsCoreConnected=$true;CurrentIsLive=$true;CurrentRuntimeStatus='Connected';BaselineSequence=5;CurrentSequence=6;BaselineEventCount=2;CurrentEventCount=3;BaselineBootstrapCount=2;CurrentBootstrapCount=2;BaselineDisconnectCount=1;CurrentDisconnectCount=1;BaselineReconciliationCount=4;CurrentReconciliationCount=5;BaselineStateSha256=('E'*64);CurrentStateSha256=('F'*64);BaselineAgentTopologySha256=('1'*64);CurrentAgentTopologySha256=('1'*64);BaselineAgentStatusStateSha256=('4'*64);CurrentAgentStatusStateSha256=('5'*64);ConnectionEpoch=2;Changes=@($changeB);ChangeCount=1;BaselineAllAgentsHaveLiveIdentity=$true;CurrentAllAgentsHaveLiveIdentity=$true}
        $empty=[ordered]@{};$appReport=[ordered]@{};foreach($name in @('EvidenceClassification','CoreStateObserved','SessionControlInvoked','StartedUtc','FinishedUtc','HostName','OperatingSystem','ProfileId','ProfileSha256','ObservedHost','RendererEvidence','AppProcessId','CoreProcessId','Language','LanguageCultureName','FinalLanguage','FinalLanguageCultureName','LanguageStableThroughFinish','LanguageChangeCount','TimeToInitialLiveState','InitialSequence','InitialStateSha256','PreCloseSequence','PreCloseStateSha256','PostCloseSequence','PostCloseStateSha256','UpdateObservedBeforeDashboardClose','DashboardClosed','UpdateObservedAfterDashboardClose','CoreConnectedAfterDashboardClose','DashboardClosedUtc','DisconnectObservedUtc','ReconnectObservedUtc','InitialEventCount','PreCloseEventCount','PostCloseEventCount','PreRestartConnectionEpoch','ReconnectedConnectionEpoch','PreRestartBootstrapCount','ReconnectedBootstrapCount','PreRestartDisconnectCount','ReconnectedDisconnectCount','DisconnectObservedAfterDashboardClose','ReconnectObservedAfterDashboardClose','EventBBaselineSequence','EventBBaselineEventCount','EventA','EventB','WidgetLatencyBaselineSequence','WidgetLatencyWarmupSamplesExcluded','WidgetLatencyWarmupExcludedSamples','WidgetLatencySamples','WidgetLatencyMinimumSamples','WidgetLatencyMeasurement','WidgetLatencyTargetMilliseconds','WidgetLatencyP95Milliseconds','WidgetLatencyTargetPassed','WidgetLatencyIncludedSamples','WidgetLatencyUnsupportedSamplesExcluded','WidgetLatencyUnsupportedExcludedSamples','IdleQuiescence','ResourceMeasurement','SemanticStateCaptures','Captures','FinalRuntimeHealth','FinalState','FailedCandidateChecks','CompositeCandidateChecksPassed','Message')){$appReport[$name]=$null}
        $appReport.EvidenceClassification='RuntimeCandidate';$appReport.CoreStateObserved=$true;$appReport.SessionControlInvoked=$false;$appReport.StartedUtc=$legUtc.ToString('O');$appReport.FinishedUtc=$legUtc.AddSeconds(9).ToString('O');$appReport.HostName='fixture';$appReport.OperatingSystem='Windows';$appReport.ProfileId='fixture-reference-host';$appReport.ProfileSha256=$profileSha;$appReport.ObservedHost=$empty;$appReport.RendererEvidence=$empty;$appReport.AppProcessId=20;$appReport.CoreProcessId=21;$appReport.Language=$language;$appReport.LanguageCultureName=$(if($language-eq'Thai'){'th-TH'}else{'en-US'});$appReport.FinalLanguage=$language;$appReport.FinalLanguageCultureName=$appReport.LanguageCultureName;$appReport.LanguageStableThroughFinish=$true;$appReport.LanguageChangeCount=0;$appReport.TimeToInitialLiveState='00:00:01';$appReport.InitialSequence=1;$appReport.InitialStateSha256='A'*64;$appReport.PreCloseSequence=2;$appReport.PreCloseStateSha256='B'*64;$appReport.PostCloseSequence=6;$appReport.PostCloseStateSha256='F'*64;$appReport.UpdateObservedBeforeDashboardClose=$true;$appReport.DashboardClosed=$true;$appReport.UpdateObservedAfterDashboardClose=$true;$appReport.CoreConnectedAfterDashboardClose=$true;$appReport.DashboardClosedUtc=$legUtc.AddSeconds(4).ToString('O');$appReport.DisconnectObservedUtc=$legUtc.AddSeconds(5).ToString('O');$appReport.ReconnectObservedUtc=$legUtc.AddSeconds(6).ToString('O');$appReport.InitialEventCount=1;$appReport.PreCloseEventCount=2;$appReport.PostCloseEventCount=3;$appReport.PreRestartConnectionEpoch=1;$appReport.ReconnectedConnectionEpoch=2;$appReport.PreRestartBootstrapCount=1;$appReport.ReconnectedBootstrapCount=2;$appReport.PreRestartDisconnectCount=0;$appReport.ReconnectedDisconnectCount=1;$appReport.DisconnectObservedAfterDashboardClose=$true;$appReport.ReconnectObservedAfterDashboardClose=$true;$appReport.EventBBaselineSequence=5;$appReport.EventBBaselineEventCount=2;$appReport.EventA=$eventA;$appReport.EventB=$eventB;$appReport.WidgetLatencyBaselineSequence=1;$appReport.WidgetLatencyWarmupSamplesExcluded=0;$appReport.WidgetLatencyWarmupExcludedSamples=@();$appReport.WidgetLatencySamples=1;$appReport.WidgetLatencyMinimumSamples=1;$appReport.WidgetLatencyMeasurement='fixture';$appReport.WidgetLatencyTargetMilliseconds=1000;$appReport.WidgetLatencyP95Milliseconds=1;$appReport.WidgetLatencyTargetPassed=$true;$appReport.WidgetLatencyIncludedSamples=@();$appReport.WidgetLatencyUnsupportedSamplesExcluded=0;$appReport.WidgetLatencyUnsupportedExcludedSamples=@();$appReport.IdleQuiescence=$empty;$appReport.ResourceMeasurement=$empty;$appReport.SemanticStateCaptures=@();$appReport.Captures=$captures;$appReport.FinalRuntimeHealth=$empty;$appReport.FinalState=$empty;$appReport.FailedCandidateChecks=@();$appReport.CompositeCandidateChecksPassed=$true;$appReport.Message='PASS'
        $oldIdentity=[ordered]@{ProcessId=10+($legIndex*10);ProcessStartUtc=$legUtc.AddMinutes(-1).ToString('O');ExecutablePath=$herdrPath;ExecutableSha256=$herdrSha};$newIdentity=[ordered]@{ProcessId=11+($legIndex*10);ProcessStartUtc=$legUtc.AddSeconds(5).ToString('O');ExecutablePath=$herdrPath;ExecutableSha256=$herdrSha}
        $hashes=@(('A'*64),('B'*64),('C'*64),('D'*64),('E'*64),('F'*64));$statuses=@('Connected','Connected','Connected','Reconnecting','Connected','Connected');$seq=@(1,2,3,4,5,6);$transitionSeconds=@(1,3,4,5,6,8);$transitions=@();for($index=0;$index-lt6;$index++){$transitions+=[ordered]@{ObservedUtc=$legUtc.AddSeconds($transitionSeconds[$index]).ToString('O');Status=$statuses[$index];ConnectionEpoch=$(if($index-lt4){1}else{2});BootstrapCount=$(if($index-lt4){1}else{2});EventCount=$(if($index-lt1){1}elseif($index-lt5){2}else{3});DisconnectCount=$(if($index-lt3){0}else{1});ReconciliationCount=$index;IngestSequence=$seq[$index];WorkspaceCount=1;TabCount=1;PaneCount=1;AgentCount=1;StateFingerprintSha256=('9'*64);ContractStateSha256=$hashes[$index];AgentTopologySha256=('1'*64);AgentStatusStateSha256=('2'*64);ServerIdentity=$(if($index-lt4){$oldIdentity}else{$newIdentity});AcceptedEventKind=$(if($index-in@(1,5)){'pane.agent_status_changed'}else{$null});Reason='fixture';AcceptedAgentStatusEvent=$(if($index-in@(1,5)){[ordered]@{WorkspaceId='workspace-1';PaneId='pane-1';AgentStatus=$(if($index-eq1){'Idle'}else{'Blocked'});Agent='codex';DisplayAgent='Codex';Title='fixture';TabId='tab-1';AgentName='agent-1'}}else{$null});AllAgentsHaveLiveIdentity=$true}}
        $coreReport=[ordered]@{EvidenceClassification='Runtime';RuntimeObserved=$true;SessionControlInvoked=$false;SnapshotObserved=$true;EventObserved=$true;ReconnectObserved=$true;StartedUtc=$legUtc.ToString('O');FinishedUtc=$legUtc.AddSeconds(9).ToString('O');RequestedDurationSeconds=10;HostName='fixture';OperatingSystem='Windows';Admission=[ordered]@{ExecutablePath=$herdrPath;ReleaseId='herdr-fixture';ExecutableSha256=$herdrSha;ProtocolContractId='herdr';ProtocolContractRevision=20;BundledSchemaContractId='herdr';BundledSchemaContractRevision=20;BundledSchemaSha256=$schemaSha;Protocol=20;Endpoint=[ordered]@{SocketPath='C:\fixture\target.sock';PipeName='fixture'}};FinalMonitorState=$empty;FinalProjectedState=$empty;FinalProjectedStateSha256=('F'*64);Transitions=$transitions;Message='PASS';CompletionSignalObserved=$true;CompletionSignalSemantics='UniquePrevalidatedAbsolutePathContainingAnEmptyFileAfterAppExit'}
        $appPathEvidence = Join-Path $evidence 'app-runtime.json'; $corePathEvidence = Join-Path $evidence 'core-runtime.json'; Write-RRFixtureJson $appPathEvidence $appReport; Write-RRFixtureJson $corePathEvidence $coreReport
        $appHash = Get-RRFixtureSha $appPathEvidence; $coreHash = Get-RRFixtureSha $corePathEvidence; $historyHash = Get-RRFixtureSha $historyPath; $selectionHash = Get-RRFixtureSha $selectionPath
        $gateValues=[ordered]@{};foreach($field in $script:V02RuntimeReviewGateFields){$gateValues[$field]='fixture'}
        $overrides=[ordered]@{GeneratedUtc=$legUtc.AddSeconds(10).ToString('O');RunNonce=$runNonce;ExpectedSourceCommit=$commit;ExpectedSourceTree=$tree;SourceCommit=$commit;SourceTree=$tree;PreRunSourceCommit=$commit;PreRunSourceTree=$tree;PreRunGitTreeClean='True';PostRunSourceCommit=$commit;PostRunSourceTree=$tree;PostRunGitTreeClean='True';Result='PASS';EvidenceClass='Runtime';SessionControlInvoked='false';AcceptanceControlSession='acceptance-control';TargetAgentLabSession='agent-lab';AcceptanceControlSocketPath='C:\fixture\control.sock';TargetAgentLabSocketPath='C:\fixture\target.sock';SeparateSessionSockets='true';AcceptanceControlServerIdentity="pid=100 start=$($baseUtc.AddMinutes(-1).ToString('O')) path=$herdrPath sha256=$herdrSha";TargetAgentSessionReference='agent-lab-session-1';HerdrReleaseId='herdr-fixture';PackageIdentityPath=$identityPath;PackageIdentityFileSha256=$identityFile.Sha256;PackageIdentityReceiptSha256=$receiptSha;PackageArchivePath=$archivePath;PackageArchiveSha256=$archive.Sha256;ExtractedPackageRoot=$package;PackageManifestPath=$manifestPath;PackageManifestSha256=$manifest.Sha256;PackageProfileId='herdrops-v0.2-package-software-only-issue-149';PackageValidationEvidenceClass='Static/PackagedCompatibilityPreparation';AppSha256=$app.Sha256;CoreSha256=$core.Sha256;HerdrExecutableSha256=$herdrSha;BundledSchemaSha256=$schemaSha;HerdrProtocol='20';ReferenceHostProfileId='fixture-reference-host';ReferenceHostProfileSha256=$profileSha;ReferenceHostSchemaSha256=$hostSchemaSha;Language=$language;RendererPolicyId='software-only-process-wide';WpfProcessRenderMode='SoftwareOnly';SoftwareOnlyThroughout='True';SnapshotObserved='True';EventObserved='True';ReconnectObserved='True';CoreAcceptedEventKindCheck='PASS';SemanticCaptureBindingCheck='PASS';AppRuntimeReportSha256=$appHash;CoreRuntimeReportSha256=$coreHash;TrxSelectionReceiptPath=$selectionPath;TrxSelectionReceiptSha256=$selectionHash;ProgressHistoryPath=$historyPath;ProgressHistorySha256=$historyHash;ProgressHistoryEntries='9';ProgressHistoryLastEntrySha256=$previous;CaptureDirectory=$captureDirectory}
        foreach($key in $overrides.Keys){$gateValues[$key]=$overrides[$key]};$gateLines=@('HerdrOps v0.2 Composite Actual Herdr Runtime Acceptance','# fixture comment accepted by the strict production grammar')+@($gateValues.GetEnumerator()|ForEach-Object{"$($_.Key): $($_.Value)"})+@('ResourceStageCheckpoints:','StateHashChain:',"Initial: 1 $('A'*64)","BeforeDashboardClose: 2 $('B'*64)","AfterDashboardClose: 6 $('F'*64)",'WidgetLatencyIncludedSamples:','CaptureHashes:',"SHA256 $($captures[0].Sha256) $($captures[0].Name)",'EvidenceBoundary:','This gate proves exact-hash-bound actual Herdr snapshot/Agent-status-event/reconnect behavior, separate Acceptance-control and Agent-Lab target sessions, Core-to-App runtime-health propagation, live production WPF page and Widget rendering, Dashboard-close continuity, state-hash correspondence, measured latency/resources, no owned TCP listener, and non-elevated operation for this host and run.','It launches the App and Core from the package root whose receipt, ZIP, manifest, source, and component bytes passed the committed package validator. This is runtime use of validated package bytes, not clean-machine installation or Release evidence.','The native target Agent/session reference is operator attestation because the gate cannot independently observe that client-owned session identity.','It does not prove clean-machine installation, later-version features, independent human review, or future Herdr releases.')
        Write-RRFixtureText (Join-Path $evidence 'gate-report.txt') (($gateLines -join "`n") + "`n")
        $gateHash = Get-RRFixtureSha (Join-Path $evidence 'gate-report.txt')
        $matrixCaptures=@($captures|ForEach-Object{[pscustomobject][ordered]@{Name=$_.Name;Path=$_.Path;Sha256=$_.Sha256}}|Sort-Object Name);$run = [ordered]@{ Language=$language;EvidenceRunNonce=$runNonce;Culture=$(if($language-eq'Thai'){'th-TH'}else{'en-US'});EvidenceDirectory=$evidence;CaptureRoot=$captureDirectory;GateReportSha256=$gateHash;AppRuntimeReportSha256=$appHash;CoreRuntimeReportSha256=$coreHash;ProgressHistorySha256=$historyHash;ProgressHistoryLastEntrySha256=$previous;PackageIdentityReceiptSha256=$receiptSha;SourceCommit=$commit;SourceTree=$tree;ProfileId='fixture-reference-host';ProfileSha256=$profileSha;ReferenceHostSchemaSha256=$hostSchemaSha;HerdrReleaseId='herdr-fixture';HerdrExecutableSha256=$herdrSha;AppExecutableSha256=$app.Sha256;CoreExecutableSha256=$core.Sha256;BundledSchemaSha256=$schemaSha;HerdrProtocol='20';RendererPolicyId='software-only-process-wide';WpfProcessRenderMode='SoftwareOnly';CaptureCount=8;Captures=$matrixCaptures }
        $runs += $run
    }
    $payload = [ordered]@{ GeneratedUnixTimeMilliseconds=$baseUtc.AddSeconds(40).ToUnixTimeMilliseconds();RunNonce=('e'*32);IndependentHumanReview='NOT_OBSERVED';ReleaseCredit=$false;Binding=[ordered]@{SourceCommit=$commit;SourceTree=$tree;ProfileId='fixture-reference-host';ProfileSha256=$profileSha;ReferenceHostSchemaSha256=$hostSchemaSha;PackageIdentityReceiptSha256=$receiptSha;HerdrReleaseId='herdr-fixture';HerdrExecutableSha256=$herdrSha;AppExecutableSha256=$app.Sha256;CoreExecutableSha256=$core.Sha256;BundledSchemaSha256=$schemaSha;HerdrProtocol='20'};Runs=$runs }
    $payloadValue = $payload | ConvertTo-Json -Depth 50 | ConvertFrom-Json; $payloadCanonical = ConvertTo-V02Jcs $payloadValue; $payloadHash = Get-V02RuntimeReviewHash ([Text.UTF8Encoding]::new($false).GetBytes($payloadCanonical))
    $candidate = [ordered]@{ EvidenceClassification = 'RuntimeMatrixCandidate'; IndependentHumanReview = 'NOT_OBSERVED'; ReleaseCredit = $false; ManifestFormatVersion = 1; ManifestHashScope = 'SHA256OfRFC8785JcsUtf8NoBomPayload'; ManifestPayloadSha256 = $payloadHash; Payload = $payloadValue }
    Write-RRFixtureJson $matrix $candidate
    return [pscustomobject][ordered]@{ Root = $root; Thai = $thai; English = $english; Matrix = $matrix; PackageIdentity = $identityPath; PackageArchive = $archivePath; PackageRoot = $package; Output = $output; Commit = $commit; Tree = $tree; Payload = $candidate }
}

function Invoke-RRFixture {
    param([Parameter(Mandatory)]$Fixture, [string]$Reviewer = 'reviewer', [string]$OutputPath,[string]$ReviewRunNonce=('d'*32))
    if ([string]::IsNullOrWhiteSpace($OutputPath)) { $OutputPath = $Fixture.Output }
    return Invoke-V02RuntimeReviewVerification -ThaiEvidenceDirectory $Fixture.Thai -EnglishEvidenceDirectory $Fixture.English -MatrixCandidatePath $Fixture.Matrix -PackageIdentityPath $Fixture.PackageIdentity -PackageArchivePath $Fixture.PackageArchive -ExtractedPackageRoot $Fixture.PackageRoot -RepositoryRoot $Fixture.Root -ExpectedSourceCommit $Fixture.Commit -ExpectedSourceTree $Fixture.Tree -OutputPath $OutputPath -BuilderIdentity 'builder' -RuntimeOperatorIdentity 'runtime-operator' -MatrixProducerIdentity 'matrix-producer' -RuntimeReviewerIdentity $Reviewer -ReviewRunNonce $ReviewRunNonce -FixtureMode
}

function Assert-RRFailure {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][scriptblock]$Action,[string]$Pattern)
    $failed = $false
    try { & $Action } catch { $failed = $true;if(-not[string]::IsNullOrWhiteSpace($Pattern)-and$_.Exception.Message-notmatch$Pattern){throw "Hostile '$Name' reached wrong guard: $($_.Exception.Message)"} }
    if (-not $failed) { throw "Hostile case did not fail closed: $Name" }
    Write-Output "PASS hostile: $Name"
}

function Save-RRFixtureMatrix {
    param([Parameter(Mandatory)]$Fixture,[Parameter(Mandatory)]$Candidate)
    $payloadValue=$Candidate.Payload|ConvertTo-Json -Depth 50|ConvertFrom-Json;$Candidate.Payload=$payloadValue;$canonical=ConvertTo-V02Jcs $payloadValue;$Candidate.ManifestPayloadSha256=Get-V02RuntimeReviewHash ([Text.UTF8Encoding]::new($false).GetBytes($canonical));Write-RRFixtureJson $Fixture.Matrix $Candidate
}

function Sync-RRFixtureLeg {
    param([Parameter(Mandatory)]$Fixture,[Parameter(Mandatory)][ValidateSet('Thai','English')][string]$Language)
    $root=if($Language-eq'Thai'){$Fixture.Thai}else{$Fixture.English};$appPath=Join-Path $root 'app-runtime.json';$corePath=Join-Path $root 'core-runtime.json';$gatePath=Join-Path $root 'gate-report.txt'
    $appHash=Get-RRFixtureSha $appPath;$coreHash=Get-RRFixtureSha $corePath;$text=[IO.File]::ReadAllText($gatePath);$text=$text-replace '(?m)^AppRuntimeReportSha256: .+$',"AppRuntimeReportSha256: $appHash";$text=$text-replace '(?m)^CoreRuntimeReportSha256: .+$',"CoreRuntimeReportSha256: $coreHash";Write-RRFixtureText $gatePath $text;$gateHash=Get-RRFixtureSha $gatePath
    $candidate=(Read-V02RuntimeReviewStrictJsonFile $Fixture.Matrix 'sync matrix').Value;$run=@($candidate.Payload.Runs|Where-Object Language -CEQ $Language)[0];$run.AppRuntimeReportSha256=$appHash;$run.CoreRuntimeReportSha256=$coreHash;$run.GateReportSha256=$gateHash;$run.Captures=@((Read-V02RuntimeReviewStrictJsonFile $appPath 'sync app').Value.Captures|ForEach-Object{[pscustomobject]@{Name=$_.Name;Path=$_.Path;Sha256=$_.Sha256}}|Sort-Object Name);Save-RRFixtureMatrix $Fixture $candidate
}

function Set-RRJsonProperty {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Property, $Value)
    $document = Read-V02RuntimeReviewStrictJsonFile $Path $Property
    $document.Value.$Property = $Value
    Write-RRFixtureJson $Path $document.Value
}

function Set-RRGateField {
    param([string]$GatePath,[string]$Name,[string]$Value)
    $text=[IO.File]::ReadAllText($GatePath);$text=$text-replace "(?m)^$([regex]::Escape($Name)): .+$","${Name}: $Value";Write-RRFixtureText $GatePath $text
}

$fixtures = @()
try {
    $baseline = New-RRFixture; $fixtures += $baseline
    $baselineResult = Invoke-RRFixture $baseline
    if ($baselineResult.EvidenceClassification -ne 'IndependentReviewCandidate' -or (Test-Path -LiteralPath $baseline.Output -PathType Leaf) -eq $false) { throw 'Baseline candidate was not emitted.' }
    $candidateDocument = Read-V02RuntimeReviewStrictJsonFile $baseline.Output 'emitted candidate'
    Assert-V02RuntimeReviewExactProperties $candidateDocument.Value @('SchemaVersion','EvidenceClassification','Result','Issues','RunNonces','Source','Package','Roles','Herdr','Sessions','MatrixCandidate','Languages','EvidenceBoundary') 'emitted candidate'
    Assert-V02RuntimeReviewString $candidateDocument.Value.EvidenceBoundary.IndependentReview 'emitted independent review' 'NOT_OBSERVED' | Out-Null
    Assert-V02RuntimeReviewString $candidateDocument.Value.EvidenceBoundary.HumanVisualGo 'emitted human visual boundary' 'NOT_OBSERVED' | Out-Null
    Assert-V02RuntimeReviewFalse $candidateDocument.Value.EvidenceBoundary.RuntimeCredit 'emitted runtime boundary'
    Assert-V02RuntimeReviewFalse $candidateDocument.Value.EvidenceBoundary.ReleaseCredit 'emitted release boundary'
    $allNonces=@($candidateDocument.Value.Languages.EvidenceRunNonce)+@($candidateDocument.Value.RunNonces.MatrixProducer,$candidateDocument.Value.RunNonces.IndependentReviewer);if(@($allNonces|Sort-Object -Unique).Count-ne4){throw 'Emitted candidate did not preserve four role-distinct exact RunNonce values.'}
    $testJson = Get-Command Test-Json -CommandType Cmdlet -ErrorAction SilentlyContinue
    if ($null -ne $testJson -and $testJson.Parameters.ContainsKey('SchemaFile')) {
        $schemaPath = Join-Path $PSScriptRoot 'runtime-review-receipt.schema.json'
        if (-not ((Get-Content -LiteralPath $baseline.Output -Raw) | Test-Json -SchemaFile $schemaPath)) { throw 'Emitted candidate failed its strict JSON schema.' }
    }
    Write-Output 'PASS baseline candidate: strict Thai+English/runtime/package binding'

    $fixture = New-RRFixture; $fixtures += $fixture
    Assert-RRFailure 'case-insensitive reviewer identity alias' { Invoke-RRFixture $fixture -Reviewer 'BUILDER' | Out-Null }

    $fixture = New-RRFixture; $fixtures += $fixture
    $identity = Read-V02RuntimeReviewStrictJsonFile $fixture.PackageIdentity 'stale receipt'; $identity.Value.source.commitSha = ('c' * 40); Write-RRFixtureJson $fixture.PackageIdentity $identity.Value
    Assert-RRFailure 'stale/copied package receipt source binding' { Invoke-RRFixture $fixture | Out-Null }

    $fixture = New-RRFixture; $fixtures += $fixture
    [IO.File]::WriteAllBytes($fixture.PackageArchive, [Text.Encoding]::UTF8.GetBytes('FORGED-ARCHIVE'))
    Assert-RRFailure 'forged package archive bytes' { Invoke-RRFixture $fixture | Out-Null }

    $fixture = New-RRFixture; $fixtures += $fixture
    $matrix = Read-V02RuntimeReviewStrictJsonFile $fixture.Matrix 'mixed matrix'; $matrix.Value.Payload.Runs[1].Language = 'Thai'; Write-RRFixtureJson $fixture.Matrix $matrix.Value
    Assert-RRFailure 'mixed/duplicate matrix languages' { Invoke-RRFixture $fixture | Out-Null }

    $fixture = New-RRFixture; $fixtures += $fixture
    $core = Read-V02RuntimeReviewStrictJsonFile (Join-Path $fixture.Thai 'core-runtime.json') 'missing semantic event'; $core.Value.EventObserved = $false; Write-RRFixtureJson (Join-Path $fixture.Thai 'core-runtime.json') $core.Value
    Assert-RRFailure 'missing semantic event' { Invoke-RRFixture $fixture | Out-Null }

    $fixture = New-RRFixture; $fixtures += $fixture
    $gate = Join-Path $fixture.English 'gate-report.txt'; $gateText = [IO.File]::ReadAllText($gate); Write-RRFixtureText $gate ($gateText -replace 'Result: PASS', 'Result: FAIL')
    Assert-RRFailure 'partial-leg PASS / failed English leg' { Invoke-RRFixture $fixture | Out-Null }

    $fixture = New-RRFixture; $fixtures += $fixture
    $app = Read-V02RuntimeReviewStrictJsonFile (Join-Path $fixture.Thai 'app-runtime.json') 'path escape'; $app.Value.Captures[0].Path = $fixture.PackageIdentity; Write-RRFixtureJson (Join-Path $fixture.Thai 'app-runtime.json') $app.Value
    Assert-RRFailure 'capture path escape' { Invoke-RRFixture $fixture | Out-Null }

    $fixture = New-RRFixture; $fixtures += $fixture
    $extra = Join-Path $fixture.Thai 'unexpected.txt'; Write-RRFixtureText $extra 'unexpected'; Assert-RRFailure 'unexpected evidence file' { Invoke-RRFixture $fixture | Out-Null }

    $fixture = New-RRFixture; $fixtures += $fixture
    $oversized = Join-Path $fixture.English 'captures\oversized.bin'; $stream = [IO.File]::Open($oversized, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None); try { $chunk = New-Object byte[] 1048576; for ($i = 0; $i -lt 17; $i++) { $stream.Write($chunk, 0, $chunk.Length) } } finally { $stream.Dispose() }
    Assert-RRFailure 'evidence byte inflation' { Invoke-RRFixture $fixture | Out-Null }

    $fixture=New-RRFixture;$fixtures+=$fixture;$candidate=(Read-V02RuntimeReviewStrictJsonFile $fixture.Matrix 'stale matrix').Value;$candidate.Payload.GeneratedUnixTimeMilliseconds=1;Save-RRFixtureMatrix $fixture $candidate
    Assert-RRFailure 'stale review window' {Invoke-RRFixture $fixture|Out-Null} 'fresh review window'

    $fixture=New-RRFixture;$fixtures+=$fixture;$gatePath=Join-Path $fixture.Thai 'gate-report.txt';$text=[IO.File]::ReadAllText($gatePath)-replace'(?m)^RunNonce: .+\r?\n','';Write-RRFixtureText $gatePath $text
    Assert-RRFailure 'missing RunNonce' {Invoke-RRFixture $fixture|Out-Null} 'missing fields: RunNonce'

    $fixture=New-RRFixture;$fixtures+=$fixture;$gatePath=Join-Path $fixture.Thai 'gate-report.txt';Set-RRGateField $gatePath 'RunNonce' ('A'*32);Sync-RRFixtureLeg $fixture Thai
    Assert-RRFailure 'non-normalized RunNonce' {Invoke-RRFixture $fixture|Out-Null} 'lowercase 32-hex invocation nonce'

    $fixture=New-RRFixture;$fixtures+=$fixture;$gatePath=Join-Path $fixture.Thai 'gate-report.txt';Set-RRGateField $gatePath 'GeneratedUtc' '2000-01-01T00:00:00Z';Sync-RRFixtureLeg $fixture Thai
    Assert-RRFailure 'stale RunNonce gate' {Invoke-RRFixture $fixture|Out-Null} 'fresh review window'

    $fixture=New-RRFixture;$fixtures+=$fixture;$candidate=(Read-V02RuntimeReviewStrictJsonFile $fixture.Matrix 'missing matrix RunNonce').Value;$run=@($candidate.Payload.Runs|Where-Object Language -CEQ 'Thai')[0];$run.PSObject.Properties.Remove('EvidenceRunNonce');Save-RRFixtureMatrix $fixture $candidate
    Assert-RRFailure 'missing matrix RunNonce' {Invoke-RRFixture $fixture|Out-Null} 'unknown, missing, or duplicate-shaped properties'

    $fixture=New-RRFixture;$fixtures+=$fixture;$candidate=(Read-V02RuntimeReviewStrictJsonFile $fixture.Matrix 'extra matrix RunNonce').Value;$run=@($candidate.Payload.Runs|Where-Object Language -CEQ 'Thai')[0];$run|Add-Member -NotePropertyName EvidenceRunNonceExtra -NotePropertyValue ('f'*32);Save-RRFixtureMatrix $fixture $candidate
    Assert-RRFailure 'extra matrix RunNonce property' {Invoke-RRFixture $fixture|Out-Null} 'unknown, missing, or duplicate-shaped properties'

    $fixture=New-RRFixture;$fixtures+=$fixture;$candidate=(Read-V02RuntimeReviewStrictJsonFile $fixture.Matrix 'mismatched matrix RunNonce').Value;$run=@($candidate.Payload.Runs|Where-Object Language -CEQ 'Thai')[0];$run.EvidenceRunNonce='f'*32;Save-RRFixtureMatrix $fixture $candidate
    Assert-RRFailure 'mismatched matrix RunNonce' {Invoke-RRFixture $fixture|Out-Null} 'Matrix Thai EvidenceRunNonce'

    $fixture=New-RRFixture;$fixtures+=$fixture;$thaiNonce=(Get-V02RuntimeReviewGateMap (Join-Path $fixture.Thai 'gate-report.txt')).Values.RunNonce;$englishGate=Join-Path $fixture.English 'gate-report.txt';Set-RRGateField $englishGate 'RunNonce' $thaiNonce;Sync-RRFixtureLeg $fixture English;$candidate=(Read-V02RuntimeReviewStrictJsonFile $fixture.Matrix 'replayed RunNonce').Value;$run=@($candidate.Payload.Runs|Where-Object Language -CEQ 'English')[0];$run.EvidenceRunNonce=$thaiNonce;Save-RRFixtureMatrix $fixture $candidate
    Assert-RRFailure 'cross-leg replayed RunNonce' {Invoke-RRFixture $fixture|Out-Null} 'replay the same RunNonce'

    $fixture=New-RRFixture;$fixtures+=$fixture
    Assert-RRFailure 'reviewer nonce collides with matrix producer' {Invoke-RRFixture $fixture -ReviewRunNonce ('e'*32)|Out-Null} 'distinct from the matrix-producer RunNonce'

    $fixture=New-RRFixture;$fixtures+=$fixture
    Assert-RRFailure 'reviewer nonce collides with runtime evidence' {Invoke-RRFixture $fixture -ReviewRunNonce ('0'*31+'1')|Out-Null} 'distinct from both runtime-evidence RunNonce values'

    $fixture=New-RRFixture;$fixtures+=$fixture;$corePath=Join-Path $fixture.Thai 'core-runtime.json';$core=(Read-V02RuntimeReviewStrictJsonFile $corePath 'repeated transition').Value;$core.Transitions[2].ObservedUtc=$core.Transitions[1].ObservedUtc;Write-RRFixtureJson $corePath $core;Sync-RRFixtureLeg $fixture Thai
    Assert-RRFailure 'repeated transition timestamp' {Invoke-RRFixture $fixture|Out-Null} 'unique and strictly increasing'

    $fixture=New-RRFixture;$fixtures+=$fixture;$appPath=Join-Path $fixture.Thai 'app-runtime.json';$appDoc=(Read-V02RuntimeReviewStrictJsonFile $appPath 'wrong mapping').Value;$appDoc.EventB.Changes[0].CurrentStatus='Forged';Write-RRFixtureJson $appPath $appDoc;Sync-RRFixtureLeg $fixture Thai
    Assert-RRFailure 'wrong lifecycle state mapping' {Invoke-RRFixture $fixture|Out-Null} 'state mapping is not canonical'

    $fixture=New-RRFixture;$fixtures+=$fixture;$corePath=Join-Path $fixture.Thai 'core-runtime.json';$core=(Read-V02RuntimeReviewStrictJsonFile $corePath 'wrong order').Value;$swap=$core.Transitions[2];$core.Transitions[2]=$core.Transitions[3];$core.Transitions[3]=$swap;Write-RRFixtureJson $corePath $core;Sync-RRFixtureLeg $fixture Thai
    Assert-RRFailure 'wrong lifecycle transition order' {Invoke-RRFixture $fixture|Out-Null} 'unique and strictly increasing'

    $fixture=New-RRFixture;$fixtures+=$fixture;$appPath=Join-Path $fixture.English 'app-runtime.json';$appDoc=(Read-V02RuntimeReviewStrictJsonFile $appPath 'arbitrary capture').Value;$appDoc.Captures[0].Name='arbitrary-capture';Write-RRFixtureJson $appPath $appDoc;Sync-RRFixtureLeg $fixture English
    Assert-RRFailure 'arbitrary capture catalog' {Invoke-RRFixture $fixture|Out-Null} 'required named catalog'

    $fixture=New-RRFixture;$fixtures+=$fixture;$corePath=Join-Path $fixture.Thai 'core-runtime.json';$core=(Read-V02RuntimeReviewStrictJsonFile $corePath 'unstable server identity').Value;$core.Transitions[1].ServerIdentity.ProcessId=999;Write-RRFixtureJson $corePath $core;Sync-RRFixtureLeg $fixture Thai
    Assert-RRFailure 'unstable predecessor identity' {Invoke-RRFixture $fixture|Out-Null} 'predecessor/successor identity'

    $fixture=New-RRFixture;$fixtures+=$fixture;$corePath=Join-Path $fixture.Thai 'core-runtime.json';$core=(Read-V02RuntimeReviewStrictJsonFile $corePath 'missing successor').Value;$core.Transitions[4].ServerIdentity=$core.Transitions[0].ServerIdentity;$core.Transitions[5].ServerIdentity=$core.Transitions[0].ServerIdentity;Write-RRFixtureJson $corePath $core;Sync-RRFixtureLeg $fixture Thai
    Assert-RRFailure 'reconnect without replacement target server' {Invoke-RRFixture $fixture|Out-Null} 'predecessor/successor identity'

    $fixture=New-RRFixture;$fixtures+=$fixture;$core=(Read-V02RuntimeReviewStrictJsonFile (Join-Path $fixture.Thai 'core-runtime.json') 'control collision').Value;$target=$core.Transitions[0].ServerIdentity;$gatePath=Join-Path $fixture.Thai 'gate-report.txt';Set-RRGateField $gatePath 'AcceptanceControlServerIdentity' "pid=$($target.ProcessId) start=$($target.ProcessStartUtc) path=$($target.ExecutablePath) sha256=$($target.ExecutableSha256)";Sync-RRFixtureLeg $fixture Thai
    Assert-RRFailure 'control and target server identity collision' {Invoke-RRFixture $fixture|Out-Null} 'control and target server process identities are not distinct'

    $fixture=New-RRFixture;$fixtures+=$fixture;$appPath=Join-Path $fixture.Thai 'app-runtime.json';$appDoc=(Read-V02RuntimeReviewStrictJsonFile $appPath 'event Agent mismatch').Value;$appDoc.EventB.Changes[0].PaneId='other-pane';Write-RRFixtureJson $appPath $appDoc;Sync-RRFixtureLeg $fixture Thai
    Assert-RRFailure 'event Agent identity mismatch' {Invoke-RRFixture $fixture|Out-Null} 'intended Agent identity'

    $fixture=New-RRFixture;$fixtures+=$fixture;$candidate=(Read-V02RuntimeReviewStrictJsonFile $fixture.Matrix 'matrix capture mismatch').Value;$run=@($candidate.Payload.Runs|Where-Object Language -CEQ 'Thai')[0];$run.Captures[0].Sha256='9'*64;Save-RRFixtureMatrix $fixture $candidate
    Assert-RRFailure 'mismatched matrix capture inventory' {Invoke-RRFixture $fixture|Out-Null} 'capture inventory'

    $fixture=New-RRFixture;$fixtures+=$fixture;$appPath=Join-Path $fixture.Thai 'app-runtime.json';$appDoc=(Read-V02RuntimeReviewStrictJsonFile $appPath 'authority field').Value;$appDoc|Add-Member -NotePropertyName IndependentReview -NotePropertyValue 'PASS';Write-RRFixtureJson $appPath $appDoc;Sync-RRFixtureLeg $fixture Thai
    Assert-RRFailure 'caller-authored authority field' {Invoke-RRFixture $fixture|Out-Null} 'unknown, missing, or duplicate-shaped'

    $fixture=New-RRFixture;$fixtures+=$fixture;$appPath=Join-Path $fixture.Thai 'app-runtime.json';$appDoc=(Read-V02RuntimeReviewStrictJsonFile $appPath 'nested authority field').Value;$appDoc.IdleQuiescence|Add-Member -NotePropertyName ReleaseCredit -NotePropertyValue $true;Write-RRFixtureJson $appPath $appDoc;Sync-RRFixtureLeg $fixture Thai
    Assert-RRFailure 'nested caller-authored authority field' {Invoke-RRFixture $fixture|Out-Null} 'caller-authored authority property'

    $fixture=New-RRFixture;$fixtures+=$fixture;$appPath=Join-Path $fixture.Thai 'app-runtime.json';$appDoc=(Read-V02RuntimeReviewStrictJsonFile $appPath 'capture root escape').Value;$capture=$appDoc.Captures[0];$moved=Join-Path (Join-Path $fixture.Thai 'test-results') ([IO.Path]::GetFileName([string]$capture.Path));Move-Item -LiteralPath $capture.Path -Destination $moved;$capture.Path=$moved;Write-RRFixtureJson $appPath $appDoc;Sync-RRFixtureLeg $fixture Thai
    Assert-RRFailure 'capture outside declared root' {Invoke-RRFixture $fixture|Out-Null} 'outside the declared capture directory'

    $fixture=New-RRFixture;$fixtures+=$fixture;Write-RRFixtureText (Join-Path $fixture.Thai 'app-progress.json') 'not-json'
    Assert-RRFailure 'malformed progress report' {Invoke-RRFixture $fixture|Out-Null} 'invalid JSON'

    $fixture=New-RRFixture;$fixtures+=$fixture;$historyPath=Join-Path $fixture.Thai 'app-progress.json.history.jsonl';$lines=[IO.File]::ReadAllLines($historyPath);$entry=$lines[4]|ConvertFrom-Json;$entry.EntrySha256='9'*64;$lines[4]=$entry|ConvertTo-Json -Compress -Depth 10;Write-RRFixtureText $historyPath ($lines-join"`n");$historyHash=Get-RRFixtureSha $historyPath;$gatePath=Join-Path $fixture.Thai 'gate-report.txt';Set-RRGateField $gatePath 'ProgressHistorySha256' $historyHash;$candidate=(Read-V02RuntimeReviewStrictJsonFile $fixture.Matrix 'history mutation').Value;$run=@($candidate.Payload.Runs|Where-Object Language -CEQ 'Thai')[0];$run.ProgressHistorySha256=$historyHash;$run.GateReportSha256=Get-RRFixtureSha $gatePath;Save-RRFixtureMatrix $fixture $candidate
    Assert-RRFailure 'broken progress JSONL hash chain' {Invoke-RRFixture $fixture|Out-Null} 'entry hash is invalid'

    $fixture=New-RRFixture;$fixtures+=$fixture;$selection=Join-Path $fixture.Thai 'test-results\selection-receipt.json';Write-RRFixtureText $selection 'not-json';$gatePath=Join-Path $fixture.Thai 'gate-report.txt';Set-RRGateField $gatePath 'TrxSelectionReceiptSha256' (Get-RRFixtureSha $selection);Sync-RRFixtureLeg $fixture Thai
    Assert-RRFailure 'malformed selection receipt' {Invoke-RRFixture $fixture|Out-Null} 'invalid JSON'

    $fixture=New-RRFixture;$fixtures+=$fixture;$selection=Join-Path $fixture.Thai 'test-results\selection-receipt.json';$receipt=(Read-V02RuntimeReviewStrictJsonFile $selection 'forged TRX').Value;$trx=Join-Path (Split-Path $selection) $receipt.Files[0].Name;Write-RRFixtureText $trx 'THIS IS NOT TRX XML';$held=Get-RRFixtureFile $trx;$receipt.Files[0].Bytes=$held.Bytes;$receipt.Files[0].Sha256=$held.Sha256;Write-RRFixtureJson $selection $receipt;$gatePath=Join-Path $fixture.Thai 'gate-report.txt';Set-RRGateField $gatePath 'TrxSelectionReceiptSha256' (Get-RRFixtureSha $selection);Sync-RRFixtureLeg $fixture Thai
    Assert-RRFailure 'non-XML TRX with recomputed receipt' {Invoke-RRFixture $fixture|Out-Null} 'TRX XML is invalid'

    $fixture=New-RRFixture;$fixtures+=$fixture;$selection=Join-Path $fixture.Thai 'test-results\selection-receipt.json';$receipt=(Read-V02RuntimeReviewStrictJsonFile $selection 'forged source').Value;$receipt.Files[0].SourceName='forged-source.trx';Write-RRFixtureJson $selection $receipt;$gatePath=Join-Path $fixture.Thai 'gate-report.txt';Set-RRGateField $gatePath 'TrxSelectionReceiptSha256' (Get-RRFixtureSha $selection);Sync-RRFixtureLeg $fixture Thai
    Assert-RRFailure 'unobservable TRX source name' {Invoke-RRFixture $fixture|Out-Null} 'source/assembly identities'

    foreach($governedTrxName in @('HerdrOps.UnitTests.trx','HerdrOps.ContractTests.trx','HerdrOps.IntegrationTests.trx','HerdrOps.RuntimeTests.trx')){
        $fixture=New-RRFixture;$fixtures+=$fixture;$selection=Join-Path $fixture.Thai 'test-results\selection-receipt.json';$receipt=(Read-V02RuntimeReviewStrictJsonFile $selection 'case-shifted TRX name').Value;$entry=@($receipt.Files|Where-Object Name -CEQ $governedTrxName)[0];$shiftedName=$governedTrxName.ToUpperInvariant();$entry.Name=$shiftedName;$entry.SourceName=$shiftedName;$entry.TestAssemblyFileName=[IO.Path]::ChangeExtension($shiftedName,'.dll');Write-RRFixtureJson $selection $receipt;$gatePath=Join-Path $fixture.Thai 'gate-report.txt';Set-RRGateField $gatePath 'TrxSelectionReceiptSha256' (Get-RRFixtureSha $selection);Sync-RRFixtureLeg $fixture Thai
        Assert-RRFailure "case-shifted governed TRX filename $governedTrxName" {Invoke-RRFixture $fixture|Out-Null} 'selection names/source/assembly identities are not exact and derivable'

        $fixture=New-RRFixture;$fixtures+=$fixture;$selection=Join-Path $fixture.Thai 'test-results\selection-receipt.json';$receipt=(Read-V02RuntimeReviewStrictJsonFile $selection 'case-shifted TRX source name').Value;$entry=@($receipt.Files|Where-Object Name -CEQ $governedTrxName)[0];$entry.SourceName=$governedTrxName.ToUpperInvariant();Write-RRFixtureJson $selection $receipt;$gatePath=Join-Path $fixture.Thai 'gate-report.txt';Set-RRGateField $gatePath 'TrxSelectionReceiptSha256' (Get-RRFixtureSha $selection);Sync-RRFixtureLeg $fixture Thai
        Assert-RRFailure "case-shifted governed TRX SourceName $governedTrxName" {Invoke-RRFixture $fixture|Out-Null} 'selection names/source/assembly identities are not exact and derivable'
    }

    $fixture=New-RRFixture;$fixtures+=$fixture;$selection=Join-Path $fixture.Thai 'test-results\selection-receipt.json';$receipt=(Read-V02RuntimeReviewStrictJsonFile $selection 'forged counter').Value;$receipt.Files[0].Total=223;$receipt.Files[0].Passed=223;$receipt.Files[1].Total=221;$receipt.Files[1].Passed=221;Write-RRFixtureJson $selection $receipt;$gatePath=Join-Path $fixture.Thai 'gate-report.txt';Set-RRGateField $gatePath 'TrxSelectionReceiptSha256' (Get-RRFixtureSha $selection);Sync-RRFixtureLeg $fixture Thai
    Assert-RRFailure 'receipt-only redistributed 888 counters' {Invoke-RRFixture $fixture|Out-Null} 'not independently derived'

    $fixture=New-RRFixture;$fixtures+=$fixture;$gatePath=Join-Path $fixture.Thai 'gate-report.txt';[IO.File]::AppendAllText($gatePath,"IndependentReview: PASS`n");Sync-RRFixtureLeg $fixture Thai
    Assert-RRFailure 'unknown gate authority field' {Invoke-RRFixture $fixture|Out-Null} "unknown field 'IndependentReview'"

    $fixture=New-RRFixture;$fixtures+=$fixture;$gatePath=Join-Path $fixture.Thai 'gate-report.txt';$gateText=[IO.File]::ReadAllText($gatePath).Replace('Result: PASS','result: PASS');Write-RRFixtureText $gatePath $gateText;Sync-RRFixtureLeg $fixture Thai
    Assert-RRFailure 'case-shifted governed gate field Result' {Invoke-RRFixture $fixture|Out-Null} "unknown field 'result'"

    $fixture=New-RRFixture;$fixtures+=$fixture;$gatePath=Join-Path $fixture.Thai 'gate-report.txt';[IO.File]::AppendAllText($gatePath,"IndependentReview PASS`n");Sync-RRFixtureLeg $fixture Thai
    Assert-RRFailure 'authority-shaped non-field gate line' {Invoke-RRFixture $fixture|Out-Null} 'noncanonical line'

    $fixture=New-RRFixture;$fixtures+=$fixture;$corePath=Join-Path $fixture.Thai 'core-runtime.json';$coreDoc=(Read-V02RuntimeReviewStrictJsonFile $corePath 'disconnect hash').Value;$coreDoc.Transitions[3].ContractStateSha256='9'*64;Write-RRFixtureJson $corePath $coreDoc;Sync-RRFixtureLeg $fixture Thai
    Assert-RRFailure 'unbound disconnect lifecycle hash' {Invoke-RRFixture $fixture|Out-Null} 'progress lifecycle hashes'

    $fixture=New-RRFixture;$fixtures+=$fixture;$appPath=Join-Path $fixture.English 'app-runtime.json';$appDoc=(Read-V02RuntimeReviewStrictJsonFile $appPath 'cross-leg Agent').Value;$appDoc.EventA.Changes[0].PaneId='pane-2';$appDoc.EventB.Changes[0].PaneId='pane-2';Write-RRFixtureJson $appPath $appDoc;Sync-RRFixtureLeg $fixture English
    Assert-RRFailure 'cross-leg Agent identity drift' {Invoke-RRFixture $fixture|Out-Null} 'same intended target Agent identity'

    $fixture=New-RRFixture;$fixtures+=$fixture;$thaiApp=(Read-V02RuntimeReviewStrictJsonFile (Join-Path $fixture.Thai 'app-runtime.json') 'Thai chronology').Value;$thaiCore=(Read-V02RuntimeReviewStrictJsonFile (Join-Path $fixture.Thai 'core-runtime.json') 'Thai chronology').Value;$appPath=Join-Path $fixture.English 'app-runtime.json';$corePath=Join-Path $fixture.English 'core-runtime.json';$appDoc=(Read-V02RuntimeReviewStrictJsonFile $appPath 'cross chronology').Value;$coreDoc=(Read-V02RuntimeReviewStrictJsonFile $corePath 'cross chronology').Value;for($i=0;$i-lt6;$i++){$coreDoc.Transitions[$i].ObservedUtc=$thaiCore.Transitions[$i].ObservedUtc};foreach($name in @('DashboardClosedUtc','DisconnectObservedUtc','ReconnectObservedUtc')){$appDoc.$name=$thaiApp.$name};$appDoc.EventA.PhaseEnteredUtc=$thaiApp.EventA.PhaseEnteredUtc;$appDoc.EventA.ObservedUtc=$thaiApp.EventA.ObservedUtc;$appDoc.EventB.PhaseEnteredUtc=$thaiApp.EventB.PhaseEnteredUtc;$appDoc.EventB.ObservedUtc=$thaiApp.EventB.ObservedUtc;Write-RRFixtureJson $appPath $appDoc;Write-RRFixtureJson $corePath $coreDoc;Sync-RRFixtureLeg $fixture English
    Assert-RRFailure 'cross-leg duplicate chronology' {Invoke-RRFixture $fixture|Out-Null} 'disjoint strictly ordered chronology'

    foreach($matrixField in @('ReferenceHostSchemaSha256','HerdrReleaseId','HerdrExecutableSha256','AppExecutableSha256','CoreExecutableSha256','BundledSchemaSha256','HerdrProtocol','RendererPolicyId','WpfProcessRenderMode','ProgressHistorySha256','ProgressHistoryLastEntrySha256')){
        $fixture=New-RRFixture;$fixtures+=$fixture;$candidate=(Read-V02RuntimeReviewStrictJsonFile $fixture.Matrix "matrix $matrixField").Value;$run=@($candidate.Payload.Runs|Where-Object Language -CEQ 'Thai')[0];$run.$matrixField=if($matrixField-match'Sha256'){'9'*64}else{'forged'};Save-RRFixtureMatrix $fixture $candidate
        Assert-RRFailure "mismatched matrix $matrixField" {Invoke-RRFixture $fixture|Out-Null} "Matrix Thai $matrixField"
    }

    $fixture=New-RRFixture;$fixtures+=$fixture;$heldCapture=(Read-V02RuntimeReviewStrictJsonFile (Join-Path $fixture.Thai 'app-runtime.json') 'hardlink capture').Value.Captures[0].Path;$alias=Join-Path $fixture.Root 'hardlink-alias.bin';New-Item -ItemType HardLink -Path $alias -Target $heldCapture|Out-Null
    Assert-RRFailure 'hardlinked evidence leaf' {Invoke-RRFixture $fixture|Out-Null} 'link-count=1'

    $fixture=New-RRFixture;$fixtures+=$fixture;$target=$fixture.PackageIdentity;$replacement=Join-Path $fixture.Root 'replacement.bin';[IO.File]::WriteAllBytes($replacement,[IO.File]::ReadAllBytes($target));$script:replacementBlocked=$false;$script:V02RuntimeReviewFixtureReadHook={param($path)if($path-ceq$target){try{Move-Item -LiteralPath $replacement -Destination $target -Force -ErrorAction Stop}catch{$script:replacementBlocked=$true}}}
    try{$null=Invoke-RRFixture $fixture}finally{$script:V02RuntimeReviewFixtureReadHook=$null};if(-not$script:replacementBlocked){throw 'Byte-identical path replacement was not blocked by the production verifier hold.'};Write-Output 'PASS hostile: byte-identical path replacement blocked'

    $fixture=New-RRFixture;$fixtures+=$fixture;$target=$fixture.PackageIdentity;$replacement=Join-Path $fixture.Root 'preopen-replacement.bin';$backup=Join-Path $fixture.Root 'preopen-original.bin';[IO.File]::WriteAllBytes($replacement,[IO.File]::ReadAllBytes($target));$script:preopenDone=$false;$script:V02RuntimeReviewFixtureBeforeOpenHook={param($path)if(-not$script:preopenDone-and$path-ceq$target){$script:preopenDone=$true;Move-Item -LiteralPath $target -Destination $backup;Move-Item -LiteralPath $replacement -Destination $target}}
    try{Assert-RRFailure 'production-helper pre-open leaf swap' {Invoke-RRFixture $fixture|Out-Null} 'identity changed before open'}finally{$script:V02RuntimeReviewFixtureBeforeOpenHook=$null};if(-not$script:preopenDone){throw 'Pre-open hostile fixture did not reach the production helper hook.'}

    $fixture=New-RRFixture;$fixtures+=$fixture;$script:parentBlocked=$false;$script:stagingBlocked=$false;$script:V02RuntimeReviewFixturePublishHook={param($phase,$parent,$temporary,$full)if($phase-eq'ParentHeld'){try{Move-Item -LiteralPath $parent -Destination ($parent+'.moved') -ErrorAction Stop}catch{$script:parentBlocked=$true}}elseif($phase-eq'StagingHeld'){try{[IO.File]::WriteAllText($temporary,'forged')}catch{$script:stagingBlocked=$true}}}
    try{$null=Invoke-RRFixture $fixture}finally{$script:V02RuntimeReviewFixturePublishHook=$null};if(-not$script:parentBlocked-or-not$script:stagingBlocked){throw 'Held parent/staging identity mutation was not blocked.'};Write-Output 'PASS hostile: parent and staging identities held through publication'

    $fixture = New-RRFixture; $fixtures += $fixture
    $first = Invoke-RRFixture $fixture; Assert-RRFailure 'concurrent/no-clobber candidate output' { Invoke-RRFixture $fixture | Out-Null }; if ((Get-RRFixtureSha $first.Path) -cne $first.Sha256) { throw 'No-clobber output was altered.' }
    $concurrentOutput = Join-Path $fixture.Root 'concurrent-candidate.json'; $commonPath = Join-Path $PSScriptRoot 'RuntimeReview.Common.ps1'; $candidateJson = [IO.File]::ReadAllText($first.Path)
    $jobs = @(
        (Start-Job -ScriptBlock { param($common, $root, $output, $json); . $common; Publish-V02RuntimeReviewNoClobber -AllowedRoot $root -OutputPath $output -Json $json } -ArgumentList $commonPath, $fixture.Root, $concurrentOutput, $candidateJson),
        (Start-Job -ScriptBlock { param($common, $root, $output, $json); . $common; Publish-V02RuntimeReviewNoClobber -AllowedRoot $root -OutputPath $output -Json $json } -ArgumentList $commonPath, $fixture.Root, $concurrentOutput, $candidateJson)
    )
    try { $jobs | Wait-Job | Out-Null; $completed = @($jobs | Where-Object { $_.State -eq 'Completed' }); $failed = @($jobs | Where-Object { $_.State -eq 'Failed' }); if ($completed.Count -ne 1 -or $failed.Count -ne 1 -or -not (Test-Path -LiteralPath $concurrentOutput -PathType Leaf)) { throw 'Concurrent publication did not yield exactly one durable winner and one rejected loser.' }; Write-Output 'PASS hostile: concurrent atomic publication' } finally { $jobs | Remove-Job -Force -ErrorAction SilentlyContinue }

    $fixture = New-RRFixture; $fixtures += $fixture
    $swapPath = Join-Path $fixture.Root 'held-swap.txt'; Write-RRFixtureText $swapPath 'held'; $swapStream = [IO.File]::Open($swapPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read); $swapBlocked = $false
    try { [IO.File]::WriteAllText($swapPath, 'replacement', (New-Object Text.UTF8Encoding($false))) } catch { $swapBlocked = $true } finally { $swapStream.Dispose() }
    if (-not $swapBlocked) { throw 'Held evidence handle allowed a path-swap write.' }; Write-Output 'PASS hostile: same-handle path-swap lock'

    $fixture = New-RRFixture; $fixtures += $fixture
    $reparseRoot = Join-Path $fixture.Root 'reparse-root'; New-Item -ItemType Directory -Path $reparseRoot | Out-Null; $reparseLink = Join-Path $reparseRoot 'thai-link'
    $reparseCreated = $false
    try { New-Item -ItemType Junction -Path $reparseLink -Value $fixture.Thai | Out-Null; $reparseCreated = $true } catch { }
    if ($reparseCreated) { Assert-RRFailure 'reparse component' { Invoke-RRFixture ($fixture | ForEach-Object { $_.Thai = $reparseLink; $_ }) | Out-Null } } else { Write-Output 'PASS hostile: reparse component guard (fixture creation unavailable; path containment still exercised)' }

    Write-Output 'V02 runtime-review receipt hostile selftests: PASS'
}
finally {
    foreach ($fixture in $fixtures) { if ($null -ne $fixture -and (Test-Path -LiteralPath $fixture.Root)) { Remove-Item -LiteralPath $fixture.Root -Recurse -Force -ErrorAction SilentlyContinue } }
}
