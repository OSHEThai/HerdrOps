#requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Issue9LiveUi.Production.ps1')

function Assert-I9Test {
    param([Parameter(Mandatory)][bool]$Condition,[Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Write-I9TestText {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($false))
}

function Write-I9TestJson {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)]$Value)
    Write-I9TestText $Path (($Value | ConvertTo-Json -Depth 100 -Compress) + "`n")
}

function New-I9TestBytes {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Text)
    Write-I9TestText $Path $Text
    return Read-I9HeldFile $Path
}

function New-I9TestPng {
    param([Parameter(Mandatory)][string]$Path,[int]$Width=1672,[int]$Height=941,[byte]$Seed=17)
    Add-Type -AssemblyName PresentationCore -ErrorAction Stop
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $stride = $Width * 4
    $pixels = [byte[]]::new($stride * $Height)
    $row = [byte[]]::new($stride)
    for ($offset = 0; $offset -lt $row.Length; $offset += 4) {
        $row[$offset] = $Seed; $row[$offset + 1] = [byte](255 - $Seed); $row[$offset + 2] = [byte](($Seed + 73) % 255); $row[$offset + 3] = 255
    }
    for ($y = 0; $y -lt $Height; $y++) { [Buffer]::BlockCopy($row,0,$pixels,$y*$stride,$stride) }
    $bitmap = [Windows.Media.Imaging.BitmapSource]::Create($Width,$Height,96,96,[Windows.Media.PixelFormats]::Bgra32,$null,$pixels,$stride)
    $encoder = [Windows.Media.Imaging.PngBitmapEncoder]::new()
    $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream = [IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try { $encoder.Save($stream) } finally { $stream.Dispose() }
    return Assert-I9Png $Path 'synthetic decodable PNG'
}

function Expect-I9Failure {
    param([Parameter(Mandatory)][scriptblock]$Action,[Parameter(Mandatory)][string]$Name,[Parameter(Mandatory)][string]$Expected)
    try { & $Action; throw "$Name unexpectedly passed." } catch {
        if ($_.Exception.Message -ceq "$Name unexpectedly passed." -or $_.Exception.Message -notmatch $Expected) {
            throw "$Name did not reach its intended guard. Expected /$Expected/; got: $($_.Exception.Message)"
        }
    }
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('herdrops-issue9-production-selftest-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root -Force | Out-Null

try {
    $repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    $producerScript = Join-Path $repositoryRoot 'tools\Test-V02LiveRuntimeAcceptance.ps1'
    $commit='a'*40; $tree='b'*40; $herdrSha='C'*64; $schemaSha='D'*64; $profileSha='E'*64; $hostSchemaSha='F'*64
    $runtimeNonce='1'*32; $foreignNonce='2'*32
    $controlSocket=Join-Path $root 'control.sock'; $targetSocket=Join-Path $root 'target.sock'
    $packageRoot=Join-Path $root 'package'; $packageIdentityPath=Join-Path $root 'package-identity.json'; $packageArchivePath=Join-Path $root 'HerdrOps-0.2.0-win-x64.zip'
    $thaiRuntime=Join-Path $root 'thai-runtime'; $englishRuntime=Join-Path $root 'english-runtime'
    $thaiUi=Join-Path $thaiRuntime 'issue9-ui'; $englishUi=Join-Path $englishRuntime 'issue9-ui'
    $matrixPath=Join-Path $root 'v0.2-language-matrix-candidate.json'; $outputPath=Join-Path $root 'issue9-candidate.json'
    foreach ($directory in @($packageRoot,$thaiRuntime,$englishRuntime,$thaiUi,$englishUi)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    foreach ($runtime in @($thaiRuntime,$englishRuntime)) { New-Item -ItemType Directory -Path (Join-Path $runtime 'captures') -Force | Out-Null }
    Write-I9TestText $controlSocket 'control-fixture'; Write-I9TestText $targetSocket 'target-fixture'

    $manifestFile=New-I9TestBytes (Join-Path $packageRoot 'package-manifest.json') 'manifest-fixture'
    $appFile=New-I9TestBytes (Join-Path $packageRoot 'HerdrOps.App.exe') 'app-fixture'
    $coreFile=New-I9TestBytes (Join-Path $packageRoot 'HerdrOps.Core.exe') 'core-fixture'
    $archiveFile=New-I9TestBytes $packageArchivePath 'archive-fixture'
    $profileFileSha='1'*64
    $identity=[ordered]@{
        schemaVersion=1; profileId='herdrops-v0.2-package-software-only-issue-149'; issue=149; packageVersion='0.2.0'; runtimeIdentifier='win-x64'
        source=[ordered]@{commitSha=$commit;treeSha=$tree}
        profile=[ordered]@{id='herdrops-v0.2-package-software-only-issue-149';relativePath='tools/packaging/v0.2/package-identity-profile.json';bytes=1;fileSha256=$profileFileSha;canonicalSha256=$profileFileSha}
        archive=[ordered]@{relativePath='HerdrOps-0.2.0-win-x64.zip';fileName='HerdrOps-0.2.0-win-x64.zip';bytes=$archiveFile.Bytes;sha256=$archiveFile.Sha256}
        packageManifest=[ordered]@{fileName='package-manifest.json';bytes=$manifestFile.Bytes;sha256=$manifestFile.Sha256;contentSha256=$manifestFile.Sha256;fileCount=3;totalBytes=[int64]($manifestFile.Bytes+$appFile.Bytes+$coreFile.Bytes)}
        components=[ordered]@{app=[ordered]@{relativePath='HerdrOps.App.exe';bytes=$appFile.Bytes;sha256=$appFile.Sha256};core=[ordered]@{relativePath='HerdrOps.Core.exe';bytes=$coreFile.Bytes;sha256=$coreFile.Sha256}}
        referenceHost=[ordered]@{profileId='herdrops-v0.2-submark-nb-software-only-20260822';profileSha256=$profileSha}
        renderer=[ordered]@{policy='software-only-process-wide';wpfProcessRenderMode='SoftwareOnly'}
        evidenceBoundary=[ordered]@{evidenceClass='PackagedCompatibilityPreparation';runtimeUse='not-used';actualHerdrUsed=$false;runtimeCredit='NOT CLAIMED';releaseCredit='NOT CLAIMED'}
    }
    Write-I9TestJson $packageIdentityPath $identity
    $identityDoc=Read-I9Json $packageIdentityPath 'fixture package identity'
    $packageReceiptSha=Get-I9Hash ([Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-V02Jcs $identityDoc.Value)))

    $t0=[DateTimeOffset]::UtcNow.AddSeconds(-20); $t1=$t0.AddSeconds(1); $t2=$t0.AddSeconds(2); $t3=$t0.AddSeconds(3); $t4=$t0.AddSeconds(4); $t5=$t0.AddSeconds(5); $t6=$t0.AddSeconds(6); $t7=$t0.AddSeconds(7); $t8=$t0.AddSeconds(8); $t9=$t0.AddSeconds(9); $t10=$t0.AddSeconds(10); $t11=$t0.AddSeconds(11)
    $initial='1'*64; $pre='2'*64; $reconciled='3'*64; $post='4'*64
    $workspace='workspace-1'; $terminal='term-1'; $tab='tab-1'; $pane='pane-1'
    $eventAChange=[ordered]@{TerminalId=$terminal;WorkspaceId=$workspace;TabId=$tab;PaneId=$pane;PreviousStatus='Idle';CurrentStatus='Working'}
    $eventBChange=[ordered]@{TerminalId=$terminal;WorkspaceId=$workspace;TabId=$tab;PaneId=$pane;PreviousStatus='Working';CurrentStatus='Idle'}
    $sourceState=[ordered]@{
        SelectedAgentIdentitySha256=Get-I9RedactedIdentity 'agent' $terminal
        Agents=@([ordered]@{AgentIdentitySha256=Get-I9RedactedIdentity 'agent' $terminal;WorkspaceIdentitySha256=Get-I9RedactedIdentity 'workspace' $workspace;TabIdentitySha256=Get-I9RedactedIdentity 'tab' $tab;PaneIdentitySha256=Get-I9RedactedIdentity 'pane' $pane;Status='Idle'})
    }
    $admission=[ordered]@{ReleaseId='herdr-fixture-0.8.2';ExecutableSha256=$herdrSha;BundledSchemaSha256=$schemaSha;Protocol=20}
    $controlIdentity=[pscustomobject][ordered]@{ProcessId=42;ProcessStartUtc=$t0.ToString('O');ExecutablePath='C:\fixture\herdr.exe';ExecutableSha256=$herdrSha}

    function New-I9Gate {
        param([string]$RuntimeRoot,[ValidateSet('Thai','English')][string]$Language,[string]$Nonce,[string]$AppSha,[string]$CoreSha)
        $history=Join-Path $RuntimeRoot 'app-progress.json.history.jsonl'; $trx=Join-Path $RuntimeRoot 'selection-receipt.trx.json'; $capture=Join-Path $RuntimeRoot 'captures'
        Write-I9TestText $history 'fixture-history'; Write-I9TestText $trx 'fixture-trx'
        $historySha=(Read-I9HeldFile $history).Sha256
        $lines=@(
            'HerdrOps v0.2 Composite Actual Herdr Runtime Acceptance',"RunNonce: $Nonce","GeneratedUtc: $($t11.ToString('O'))","ExpectedSourceCommit: $commit","ExpectedSourceTree: $tree","SourceCommit: $commit","SourceTree: $tree","PreRunSourceCommit: $commit","PreRunSourceTree: $tree",'PreRunGitTreeClean: True',"PostRunSourceCommit: $commit","PostRunSourceTree: $tree",'PostRunGitTreeClean: True','Result: PASS','EvidenceClass: Runtime','SessionControlInvoked: false','AcceptanceControlSession: Acceptance-control','TargetAgentLabSession: Target-agent',"AcceptanceControlSocketPath: $controlSocket","TargetAgentLabSocketPath: $targetSocket",'SeparateSessionSockets: true','AcceptanceControlServerIdentity: herdr-fixture-control','TargetAgentSessionReference: target-reference-fixture',"PackageIdentityPath: $packageIdentityPath","PackageIdentityFileSha256: $($identityDoc.Sha256)","PackageIdentityReceiptSha256: $packageReceiptSha","PackageArchivePath: $packageArchivePath","PackageArchiveSha256: $($archiveFile.Sha256)","ExtractedPackageRoot: $packageRoot","PackageManifestPath: $(Join-Path $packageRoot 'package-manifest.json')","PackageManifestSha256: $($manifestFile.Sha256)",'PackageProfileId: herdrops-v0.2-package-software-only-issue-149','PackageValidationEvidenceClass: Static/PackagedCompatibilityPreparation',('AppSha256: '+$appFile.Sha256),('CoreSha256: '+$coreFile.Sha256),('HerdrReleaseId: '+$admission.ReleaseId),('HerdrExecutableSha256: '+$herdrSha),('BundledSchemaSha256: '+$schemaSha),'HerdrProtocol: 20','ReferenceHostProfileId: herdrops-v0.2-submark-nb-software-only-20260822',('ReferenceHostProfileSha256: '+$profileSha),('ReferenceHostSchemaSha256: '+$hostSchemaSha),"Language: $Language","AppRuntimeReportSha256: $AppSha","CoreRuntimeReportSha256: $CoreSha","TrxSelectionReceiptPath: $trx",('TrxSelectionReceiptSha256: '+('5'*64)),"ProgressHistoryPath: $history","ProgressHistorySha256: $historySha",('ProgressHistoryLastEntrySha256: '+('7'*64)),"CaptureDirectory: $capture",'CoreAcceptedEventKindCheck: PASS','SemanticCaptureBindingCheck: PASS','SnapshotObserved: True','EventObserved: True','ReconnectObserved: True'
        )
        $nativeSessionReference=[pscustomobject][ordered]@{agent='codex';kind='id';source='herdr:codex';value='fixture-native-session'}|ConvertTo-Json -Compress
        $lines=@($lines|ForEach-Object{([string]$_).Replace('TargetAgentSessionReference: target-reference-fixture',"TargetAgentSessionReference: $nativeSessionReference")})
        $lines+=@('TargetAgentSessionReferenceEvidenceSource: HerdrCliAgentMetadata','TargetAgentSessionReferenceObservableByGate: true','TargetAgentSessionReferenceBoundary: The gate directly observed and exact-bound the same structured native Agent session through Herdr CLI metadata before restart, at reconnect, and through completion.')
        $path=Join-Path $RuntimeRoot 'gate-report.txt'; Write-I9TestText $path (($lines -join "`n")+"`n"); return $path
    }

    function New-I9RuntimeLeg {
        param([string]$RuntimeRoot,[ValidateSet('Thai','English')][string]$Language,[string]$Nonce,[byte]$Seed)
        $captureRoot=Join-Path $RuntimeRoot 'captures'
        $captures=@(); $bound=@(); $ordinal=0
        foreach ($name in @('dashboard-overview','dashboard-live-organization','dashboard-agent-detail')) {
            $ordinal++; $png=New-I9TestPng (Join-Path $captureRoot ($name+'.png')) 1672 941 ([byte]($Seed+$ordinal))
            $captures += [ordered]@{Name=$name;Path=$png.Path;Sha256=$png.Sha256;PixelWidth=$png.PixelWidth;PixelHeight=$png.PixelHeight;ObservedUtc=$t2.ToString('O');StateSequence=1;StateSha256=$initial}
            $bound += [ordered]@{FileName=[IO.Path]::GetFileName($png.Path);Sha256=$png.Sha256;StateSequence=1;StateSha256=$initial}
        }
        $semantic=@(
            [ordered]@{Ordinal=1;Phase='initial';EventBinding='InitialLiveState';Sequence=1;NormalizedStateSha256=$initial;ObservedUtc=$t3.ToString('O');SourceState=$sourceState;BoundCaptures=$bound},
            [ordered]@{Ordinal=2;Phase='event-a-pre-close';EventBinding='EventA';Sequence=2;NormalizedStateSha256=$pre;ObservedUtc=$t5.ToString('O');SourceState=$sourceState;BoundCaptures=@()},
            [ordered]@{Ordinal=3;Phase='post-close-final';EventBinding='EventB';Sequence=4;NormalizedStateSha256=$post;ObservedUtc=$t11.ToString('O');SourceState=$sourceState;BoundCaptures=@()}
        )
        $app=[ordered]@{
            EvidenceClassification='RuntimeCandidate';Language=$Language;FinalLanguage=$Language;LanguageStableThroughFinish=$true;LanguageChangeCount=0;SessionControlInvoked=$false;AppProcessId=700
            StartedUtc=$t0.ToString('O');FinishedUtc=$t11.ToString('O');InitialSequence=1;InitialStateSha256=$initial;PreCloseSequence=2;PreCloseStateSha256=$pre;PostCloseSequence=4;PostCloseStateSha256=$post
            DashboardClosed=$true;DashboardClosedUtc=$t6.ToString('O');UpdateObservedAfterDashboardClose=$true;CoreConnectedAfterDashboardClose=$true;DisconnectObservedAfterDashboardClose=$true;DisconnectObservedUtc=$t7.ToString('O');ReconnectObservedAfterDashboardClose=$true;ReconnectObservedUtc=$t8.ToString('O')
            EventA=[ordered]@{PhaseEnteredUtc=$t4.ToString('O');ObservedUtc=$t5.ToString('O');CurrentStateSha256=$pre;Changes=@($eventAChange)}
            EventB=[ordered]@{PhaseEnteredUtc=$t10.ToString('O');ObservedUtc=$t10.ToString('O');CurrentStateSha256=$post;Changes=@($eventBChange)}
            SemanticStateCaptures=$semantic;Captures=$captures
        }
        $acceptedA=[ordered]@{WorkspaceId=$workspace;PaneId=$pane;AgentStatus='Working'}; $acceptedB=[ordered]@{WorkspaceId=$workspace;PaneId=$pane;AgentStatus='Idle'}
        $core=[ordered]@{
            EvidenceClassification='Runtime';RuntimeObserved=$true;SnapshotObserved=$true;EventObserved=$true;ReconnectObserved=$true;CompletionSignalObserved=$true;SessionControlInvoked=$false;Admission=$admission
            Transitions=@(
                [ordered]@{IngestSequence=1;ObservedUtc=$t3.ToString('O');ContractStateSha256=$initial;ReconciliationCount=0;AcceptedEventKind=$null;AcceptedAgentStatusEvent=$null},
                [ordered]@{IngestSequence=2;ObservedUtc=$t5.ToString('O');ContractStateSha256=$pre;ReconciliationCount=0;AcceptedEventKind='pane.agent_status_changed';AcceptedAgentStatusEvent=$acceptedA},
                [ordered]@{IngestSequence=3;ObservedUtc=$t9.ToString('O');ContractStateSha256=$reconciled;ReconciliationCount=1;AcceptedEventKind=$null;AcceptedAgentStatusEvent=$null},
                [ordered]@{IngestSequence=4;ObservedUtc=$t10.ToString('O');ContractStateSha256=$post;ReconciliationCount=0;AcceptedEventKind='pane.agent_status_changed';AcceptedAgentStatusEvent=$acceptedB}
            )
        }
        $appPath=Join-Path $RuntimeRoot 'app-runtime.json'; $corePath=Join-Path $RuntimeRoot 'core-runtime.json'
        Write-I9TestJson $appPath $app; Write-I9TestJson $corePath $core
        $appHash=(Read-I9HeldFile $appPath).Sha256; $coreHash=(Read-I9HeldFile $corePath).Sha256
        $gatePath=New-I9Gate $RuntimeRoot $Language $Nonce $appHash $coreHash
        $side=New-I9TestPng (Join-Path (Join-Path $RuntimeRoot 'issue9-ui') 'actual-herdr-ui-side-by-side.png') 1200 700 ([byte]($Seed+10))
        $sideObservation=[pscustomobject][ordered]@{Path=$side.Path;Bytes=$side.Bytes;Sha256=$side.Sha256;PixelWidth=$side.PixelWidth;PixelHeight=$side.PixelHeight;ObservedUtc=$t2.ToString('O');Phase='capturing-live-dashboard-and-widgets';Sequence=1;StateSha256=$initial}
        $receipt=New-I9LiveUiObservation -RuntimeEvidenceDirectory $RuntimeRoot -UiEvidenceDirectory (Join-Path $RuntimeRoot 'issue9-ui') -GateReportPath $gatePath -AppRuntimeReportPath $appPath -CoreRuntimeReportPath $corePath -SideBySideCapture $sideObservation -Language $Language -ExpectedSourceCommit $commit -ExpectedSourceTree $tree -RunNonce $Nonce -ProducerScriptPath $producerScript -ControlServerIdentityBefore $controlIdentity -ControlServerIdentityAfter $controlIdentity
        return [pscustomobject]@{Root=[IO.Path]::GetFullPath($RuntimeRoot);EvidenceRunNonce=$Nonce;GatePath=$gatePath;GateHash=(Read-I9HeldFile $gatePath).Sha256;AppPath=$appPath;AppHash=$appHash;CorePath=$corePath;CoreHash=$coreHash;SideObservation=$sideObservation;ReceiptPath=$receipt.Path}
    }

    $thai=New-I9RuntimeLeg $thaiRuntime 'Thai' $runtimeNonce 20
    $english=New-I9RuntimeLeg $englishRuntime 'English' $runtimeNonce 40
    Assert-I9Test ($thai.EvidenceRunNonce -ceq $english.EvidenceRunNonce) 'Synthetic language legs did not preserve the shared Issue #10 RunNonce.'
    foreach ($leg in @($thai,$english)) {
        $receiptValue=(Read-I9Json $leg.ReceiptPath 'schema-v2 production receipt').Value
        $artifactPaths=@([string]$receiptValue.SideBySideCapture.Path)+@($receiptValue.Pages|ForEach-Object{[string]$_.UiCapturePath})
        Assert-I9Test ($artifactPaths.Count -eq 4 -and @($artifactPaths|Sort-Object -Unique).Count -eq 4) 'Production receipt did not preserve exactly four distinct captures per language leg.'
    }
    Expect-I9Failure { New-I9LiveUiObservation -RuntimeEvidenceDirectory $thaiRuntime -UiEvidenceDirectory $thaiUi -GateReportPath $thai.GatePath -AppRuntimeReportPath $thai.AppPath -CoreRuntimeReportPath $thai.CorePath -SideBySideCapture $thai.SideObservation -Language Thai -ExpectedSourceCommit $commit -ExpectedSourceTree $tree -RunNonce $foreignNonce -ProducerScriptPath $producerScript -ControlServerIdentityBefore $controlIdentity -ControlServerIdentityAfter $controlIdentity -OutputPath (Join-Path $thaiUi 'foreign-nonce.json') } 'producer foreign nonce transplant' 'does not match the held runtime leg'

    $matrixPayload=[ordered]@{
        GeneratedUnixTimeMilliseconds=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds();RunNonce=('3'*32);IndependentHumanReview='NOT_OBSERVED';ReleaseCredit=$false
        Binding=[ordered]@{SourceCommit=$commit;SourceTree=$tree;ProfileId='herdrops-v0.2-package-software-only-issue-149';ProfileSha256=$profileSha;ReferenceHostSchemaSha256=$hostSchemaSha;PackageIdentityReceiptSha256=$packageReceiptSha;HerdrReleaseId=$admission.ReleaseId;HerdrExecutableSha256=$herdrSha;AppExecutableSha256=$appFile.Sha256;CoreExecutableSha256=$coreFile.Sha256;BundledSchemaSha256=$schemaSha;HerdrProtocol='20'}
        Runs=@(
            [ordered]@{Language='Thai';EvidenceRunNonce=$thai.EvidenceRunNonce;EvidenceDirectory=$thai.Root;GateReportSha256=$thai.GateHash;AppRuntimeReportSha256=$thai.AppHash;CoreRuntimeReportSha256=$thai.CoreHash;SourceCommit=$commit;SourceTree=$tree;PackageIdentityReceiptSha256=$packageReceiptSha},
            [ordered]@{Language='English';EvidenceRunNonce=$english.EvidenceRunNonce;EvidenceDirectory=$english.Root;GateReportSha256=$english.GateHash;AppRuntimeReportSha256=$english.AppHash;CoreRuntimeReportSha256=$english.CoreHash;SourceCommit=$commit;SourceTree=$tree;PackageIdentityReceiptSha256=$packageReceiptSha}
        )
    }
    $matrixCanonical=ConvertTo-V02Jcs (($matrixPayload|ConvertTo-Json -Depth 100|ConvertFrom-Json)); $matrixPayloadHash=Get-I9Hash ([Text.UTF8Encoding]::new($false).GetBytes($matrixCanonical))
    $matrix=[ordered]@{EvidenceClassification='RuntimeMatrixCandidate';IndependentHumanReview='NOT_OBSERVED';ReleaseCredit=$false;ManifestFormatVersion=1;ManifestHashScope='SHA256OfRFC8785JcsUtf8NoBomPayload';ManifestPayloadSha256=$matrixPayloadHash;Payload=$matrixPayload}
    Write-I9TestJson $matrixPath $matrix

    $invokeArgs=@{ThaiRuntimeEvidenceDirectory=$thaiRuntime;EnglishRuntimeEvidenceDirectory=$englishRuntime;ThaiUiEvidenceDirectory=$thaiUi;EnglishUiEvidenceDirectory=$englishUi;MatrixCandidatePath=$matrixPath;PackageIdentityPath=$packageIdentityPath;PackageArchivePath=$packageArchivePath;ExtractedPackageRoot=$packageRoot;RepositoryRoot=$repositoryRoot;ExpectedSourceCommit=$commit;ExpectedSourceTree=$tree;OutputPath=$outputPath;FixtureMode=$true}
    $published=Invoke-I9LiveUiVerification @invokeArgs
    $candidate=(Read-I9Json $published.Path 'published Issue #9 candidate').Value
    Assert-I9Test ([string]$candidate.EvidenceClassification -ceq 'Issue9RuntimeCandidate') 'Wrong candidate classification.'
    Assert-I9Test ([string]$candidate.EvidenceBoundary.Runtime -ceq 'NOT_OBSERVED' -and [string]$candidate.EvidenceBoundary.HumanVisual -ceq 'NOT_OBSERVED' -and -not [bool]$candidate.EvidenceBoundary.ReleaseCredit) 'Synthetic boundary was weakened.'
    foreach ($language in @($candidate.Languages)) { Assert-I9Test (@($language.Pages).Count -eq 3) 'Language did not preserve exactly three dashboard pages.' }

    $schemaPath=Join-Path $PSScriptRoot 'issue9-live-ui-candidate.schema.json'; $null=Read-I9Json $schemaPath 'Issue #9 candidate schema'
    if ($null -ne (Get-Command Test-Json -ErrorAction SilentlyContinue)) { Assert-I9Test (Test-Json -LiteralPath $published.Path -SchemaFile $schemaPath) 'Published candidate failed strict schema.' }
    $publishedCandidate=(Read-I9Json $published.Path 'published Issue #9 candidate').Value
    Assert-I9Test ([int64]$publishedCandidate.SchemaVersion-eq2) 'Published candidate did not use successor schema version 2.'
    Assert-I9Test ([string]$publishedCandidate.Sessions.Target.EvidenceSource-ceq'HerdrCliAgentMetadata'-and[bool]$publishedCandidate.Sessions.Target.ObservableByGate) 'Published candidate did not preserve gate-observed native session authority.'
    Expect-I9Failure {ConvertFrom-I9NativeSessionReference 'target-reference-fixture' 'legacy opaque session'|Out-Null} 'legacy opaque operator session reference' 'structured Herdr CLI JSON'
    Assert-I9Test (@($candidate.Languages.EvidenceRunNonce|Sort-Object -Unique).Count -eq 1 -and [string]$candidate.Languages[0].EvidenceRunNonce-ceq$runtimeNonce -and [string]$candidate.MatrixCandidate.ProducerRunNonce-ceq('3'*32)) 'Candidate did not preserve the shared bilingual runtime nonce and distinct matrix-producer nonce.'

    $englishGateOriginal=[IO.File]::ReadAllText($english.GatePath,[Text.UTF8Encoding]::new($false))
    try {
        Write-I9TestText $english.GatePath ($englishGateOriginal.Replace("RunNonce: $runtimeNonce","RunNonce: $foreignNonce"))
        $distinctNonceArgs=@{}+$invokeArgs;$distinctNonceArgs.OutputPath=Join-Path $root 'hostile-distinct-runtime-nonces.json'
        Expect-I9Failure {Invoke-I9LiveUiVerification @distinctNonceArgs|Out-Null} 'distinct Thai/English runtime nonces before matrix producer collision checks' 'values must be identical for one bilingual acceptance transaction'
    } finally {
        Write-I9TestText $english.GatePath $englishGateOriginal
    }

    function Invoke-I9ReceiptMutation {
        param([string]$Name,[string]$Expected,[scriptblock]$Mutate,[scriptblock]$Prepare,[scriptblock]$Cleanup)
        $original=[IO.File]::ReadAllText($thai.ReceiptPath,[Text.UTF8Encoding]::new($false))
        try {
            if ($null -ne $Prepare) { & $Prepare }
            $value=(Read-I9Json $thai.ReceiptPath 'Thai receipt').Value
            & $Mutate $value
            Write-I9TestJson $thai.ReceiptPath $value
            $caseArgs=@{}+$invokeArgs; $caseArgs.OutputPath=Join-Path $root ('hostile-'+[Guid]::NewGuid().ToString('N')+'.json')
            Expect-I9Failure { Invoke-I9LiveUiVerification @caseArgs } $Name $Expected
        } finally {
            Write-I9TestText $thai.ReceiptPath $original
            if ($null -ne $Cleanup) { & $Cleanup }
        }
    }

    Invoke-I9ReceiptMutation 'wrong phase/state' 'wrong semantic phase/state' { param($v) $v.Pages[0].Phase='event-a-pre-close';$v.Pages[0].Sequence=2;$v.Pages[0].StateSha256=$pre }
    Invoke-I9ReceiptMutation 'foreign receipt nonce transplant' 'RunNonce is replayed or cross-leg' { param($v) $v.RunNonce=$foreignNonce }
    Invoke-I9ReceiptMutation 'stale capture' 'stale or outside its semantic window' { param($v) $v.SideBySideCapture.ObservedUtc=$t0.AddSeconds(-1).ToString('O') }
    Invoke-I9ReceiptMutation 'forged synchronized identifiers' 'not the exact initial Core semantic snapshot' { param($v) foreach($p in @($v.Pages)){$p.WorkspaceId='forged-workspace';$p.ProjectId='forged-workspace';$p.AgentId='forged-agent';$p.TaskId='forged-task';$p.PaneId='forged-pane'};$v.Selection.WorkspaceId='forged-workspace';$v.Selection.ProjectId='forged-workspace';$v.Selection.AgentId='forged-agent';$v.Selection.TaskId='forged-task';$v.Selection.PaneId='forged-pane' }
    Invoke-I9ReceiptMutation 'producer provenance' 'producer provenance is stale or forged' { param($v) $v.Producer.ScriptSha256='8'*64 }
    Invoke-I9ReceiptMutation 'chronology violation' 'chronology is invalid' { param($v) $v.Lifecycle.DisconnectObservedUtc=$t5.ToString('O') }

    $pagePath=[string](Read-I9Json $thai.ReceiptPath 'Thai receipt').Value.Pages[0].UiCapturePath
    $originalPage=[IO.File]::ReadAllBytes($pagePath)
    try {
        [IO.File]::WriteAllText($pagePath,'not-a-png',[Text.UTF8Encoding]::new($false))
        Invoke-I9ReceiptMutation 'arbitrary non-PNG' 'not a PNG: signature mismatch' { param($v) $held=Read-I9HeldFile $pagePath;$v.Pages[0].UiCaptureSha256=$held.Sha256 }
    } finally { [IO.File]::WriteAllBytes($pagePath,$originalPage) }

    $smallPath=Join-Path (Join-Path $thaiRuntime 'captures') 'wrong-dimensions.png'; $small=New-I9TestPng $smallPath 20 20 91
    try { Invoke-I9ReceiptMutation 'wrong dashboard dimensions' 'must decode to exactly 1672x941' { param($v) $v.Pages[0].UiCapturePath=$small.Path;$v.Pages[0].UiCaptureSha256=$small.Sha256;$v.Pages[0].PixelWidth=$small.PixelWidth;$v.Pages[0].PixelHeight=$small.PixelHeight } } finally { Remove-Item -LiteralPath $smallPath -Force }

    $escapePath=Join-Path $root 'escaped.png'; $escape=New-I9TestPng $escapePath 1672 941 92
    try { Invoke-I9ReceiptMutation 'path escape' 'escaped its allowed root' { param($v) $v.Pages[0].UiCapturePath=$escape.Path;$v.Pages[0].UiCaptureSha256=$escape.Sha256 } } finally { Remove-Item -LiteralPath $escapePath -Force }

    $hardTarget=Join-Path (Join-Path $thaiRuntime 'captures') 'hard-target.png'; $hardAlias=Join-Path (Join-Path $thaiRuntime 'captures') 'hard-alias.png'; $hard=New-I9TestPng $hardTarget 1672 941 93; $null=New-Item -ItemType HardLink -Path $hardAlias -Target $hardTarget
    try { Invoke-I9ReceiptMutation 'hardlink alias' 'must have exactly one link' { param($v) $v.Pages[0].UiCapturePath=$hardAlias;$v.Pages[0].UiCaptureSha256=$hard.Sha256 } } finally { Remove-Item -LiteralPath $hardAlias -Force;Remove-Item -LiteralPath $hardTarget -Force }

    $outside=Join-Path $root 'junction-target'; $junction=Join-Path $thaiRuntime 'junction-captures'; New-Item -ItemType Directory -Path $outside | Out-Null; $junctionPng=New-I9TestPng (Join-Path $outside 'junction.png') 1672 941 94; $null=New-Item -ItemType Junction -Path $junction -Target $outside
    try { Invoke-I9ReceiptMutation 'reparse path' 'reparse point' { param($v) $v.Pages[0].UiCapturePath=Join-Path $junction 'junction.png';$v.Pages[0].UiCaptureSha256=$junctionPng.Sha256 } } finally { if (Test-Path -LiteralPath $junction) { [IO.Directory]::Delete($junction) };Remove-Item -LiteralPath $outside -Recurse -Force }

    $noClobber=Join-Path $root 'no-clobber.json'; $firstArgs=@{}+$invokeArgs;$firstArgs.OutputPath=$noClobber;$null=Invoke-I9LiveUiVerification @firstArgs
    Expect-I9Failure { Invoke-I9LiveUiVerification @firstArgs } 'duplicate output publication' 'already exists'

    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    $captureRacePath=Join-Path $root 'desktop-capture-race.png'
    $sentinelBytes=[Text.UTF8Encoding]::new($false).GetBytes('concurrent-owner-sentinel')
    $captureRaceHook={
        param([string]$DestinationPath)
        $sentinelStream=[IO.File]::Open($DestinationPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try {
            $sentinelStream.Write($sentinelBytes,0,$sentinelBytes.Length)
            $sentinelStream.Flush($true)
        } finally { $sentinelStream.Dispose() }
    }.GetNewClosure()
    $captureRaceBitmap=[Drawing.Bitmap]::new(2,2,[Drawing.Imaging.PixelFormat]::Format32bppPArgb)
    try {
        Expect-I9Failure { Publish-I9DesktopBitmapNoClobber -Bitmap $captureRaceBitmap -OutputPath $captureRacePath -BeforeAtomicMoveSelfTestHook $captureRaceHook } 'desktop capture concurrent destination' 'atomic no-clobber guard rejected'
    } finally { $captureRaceBitmap.Dispose() }
    $survivingSentinel=[IO.File]::ReadAllBytes($captureRacePath)
    Assert-I9Test ([Convert]::ToBase64String($survivingSentinel) -ceq [Convert]::ToBase64String($sentinelBytes)) 'Desktop capture race overwrote or altered the concurrently created sentinel.'
    $captureTemporaryPattern='.'+[IO.Path]::GetFileName($captureRacePath)+'.*.capture.tmp'
    Assert-I9Test (@(Get-ChildItem -LiteralPath $root -Filter $captureTemporaryPattern -Force).Count -eq 0) 'Desktop capture race left its owned temporary behind.'

    foreach ($path in @((Join-Path $PSScriptRoot 'Test-V02Issue9LiveUiAcceptance.ps1'),(Join-Path $PSScriptRoot 'Issue9LiveUi.Common.ps1'),(Join-Path $PSScriptRoot 'Issue9LiveUi.Production.ps1'))) {
        $text=[IO.File]::ReadAllText($path,[Text.UTF8Encoding]::new($false)); Assert-I9Test ($text -notmatch '(?i)Start-Process|Stop-Process|herdr session') "Issue #9 helper contains process/session control: $path"
    }
    Write-Output 'Issue #9 live UI production/schema-v2 hostile tests: PASS'
    Write-Output 'EvidenceClass: Static/Contract/Synthetic'
    Write-Output 'ActualHerdrRuntime: NOT_OBSERVED'
    Write-Output 'HumanVisual: NOT_OBSERVED'
    Write-Output 'ReleaseCredit: false'
} finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
}
