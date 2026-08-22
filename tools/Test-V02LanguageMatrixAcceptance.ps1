[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ThaiEvidenceDirectory,
    [Parameter(Mandatory)][string]$EnglishEvidenceDirectory,
    [Parameter(Mandatory)][string]$PackageIdentityPath,
    [Parameter(Mandatory)][string]$PackageArchivePath,
    [Parameter(Mandatory)][string]$ExtractedPackageRoot,
    [Parameter(Mandatory)][string]$RepositoryRoot,
    [Parameter(Mandatory)][string]$PackageProfilePath,
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\V02ReferenceHostProfile.ps1')

function Get-MatrixFullDirectory {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Name)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "$Name does not exist: $Path" }
    return [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Path).Path).TrimEnd('\','/')
}

function Test-MatrixPathWithin {
    param([Parameter(Mandatory)][string]$Child,[Parameter(Mandatory)][string]$Parent)
    $childFull=[IO.Path]::GetFullPath($Child);$parentFull=[IO.Path]::GetFullPath($Parent).TrimEnd('\','/')
    return $childFull.StartsWith($parentFull+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)
}

function Assert-MatrixDistinctTrees {
    param([Parameter(Mandatory)][string]$Left,[Parameter(Mandatory)][string]$Right,[Parameter(Mandatory)][string]$Context)
    if ($Left.Equals($Right,[StringComparison]::OrdinalIgnoreCase) -or
        (Test-MatrixPathWithin $Left $Right) -or (Test-MatrixPathWithin $Right $Left)) {
        throw "$Context must be distinct, non-overlapping directory trees."
    }
}

function Get-MatrixProperty {
    param([Parameter(Mandatory)]$Object,[Parameter(Mandatory)][string]$Name,[Parameter(Mandatory)][string]$Context)
    if ($null -eq $Object -or -not ($Object.PSObject.Properties.Name -ccontains $Name)) { throw "$Context omitted '$Name'." }
    return $Object.$Name
}

function Assert-MatrixSha256 {
    param([Parameter(Mandatory)]$Value,[Parameter(Mandatory)][string]$Context)
    if ($Value -isnot [string] -or [string]$Value -notmatch '^[0-9A-F]{64}$') { throw "$Context must be uppercase SHA-256." }
    return [string]$Value
}

function Read-MatrixGateReport {
    param([Parameter(Mandatory)][string]$Path)
    $values=@{};$captureDeclarations=New-Object System.Collections.Generic.List[object]
    foreach($line in [IO.File]::ReadAllLines($Path)) {
        if ($line -match '^SHA256 (?<Hash>[0-9A-F]{64}) (?<Name>.+)$') {
            $captureDeclarations.Add([pscustomobject]@{Sha256=$Matches.Hash;Name=$Matches.Name})
            continue
        }
        if ($line -match '^(?<Key>[A-Za-z][A-Za-z0-9]+): (?<Value>.*)$') {
            $key=$Matches.Key
            if ($values.ContainsKey($key)) { throw "Gate report contains duplicate field '$key'." }
            $values[$key]=$Matches.Value
        }
    }
    return [pscustomobject]@{Values=$values;CaptureDeclarations=$captureDeclarations.ToArray()}
}

function Get-MatrixGateValue {
    param([Parameter(Mandatory)]$Gate,[Parameter(Mandatory)][string]$Name,[Parameter(Mandatory)][string]$Context)
    if (-not $Gate.Values.ContainsKey($Name) -or [string]::IsNullOrWhiteSpace([string]$Gate.Values[$Name])) { throw "$Context gate report omitted '$Name'." }
    return [string]$Gate.Values[$Name]
}

function Assert-MatrixEqual {
    param([Parameter(Mandatory)]$Left,[Parameter(Mandatory)]$Right,[Parameter(Mandatory)][string]$Context)
    if ([string]$Left -cne [string]$Right) { throw "$Context mismatch. Left='$Left' Right='$Right'." }
}

function Test-MatrixNativeInteger {
    param($Value)
    if($null-eq$Value){return $false}
    return @([TypeCode]::Byte,[TypeCode]::SByte,[TypeCode]::UInt16,[TypeCode]::UInt32,[TypeCode]::UInt64,[TypeCode]::Int16,[TypeCode]::Int32,[TypeCode]::Int64)-contains[Type]::GetTypeCode($Value.GetType())
}

function Get-MatrixTextSha256 {
    param([AllowEmptyString()][string]$Text)
    $utf8=New-Object Text.UTF8Encoding($false);$sha=[Security.Cryptography.SHA256]::Create()
    try{return([BitConverter]::ToString($sha.ComputeHash($utf8.GetBytes($Text)))).Replace('-','')}finally{$sha.Dispose()}
}

function ConvertFrom-MatrixJsonText {
    param([Parameter(Mandatory)][string]$Json)
    $command=Get-Command ConvertFrom-Json -CommandType Cmdlet
    if($command.Parameters.ContainsKey('DateKind')){return $Json|ConvertFrom-Json -DateKind String}
    return $Json|ConvertFrom-Json
}

function Get-MatrixProgressCanonicalPayload {
    param($Entry)
    $culture=[Globalization.CultureInfo]::InvariantCulture
    $accepted=if($null-eq$Entry.LastAcceptedStateUtc){''}else{([DateTimeOffset]$Entry.LastAcceptedStateUtc).ToUniversalTime().ToString('O',$culture)}
    return @(([int]$Entry.Ordinal).ToString($culture),[string]$Entry.Phase,([DateTimeOffset]$Entry.ObservedUtc).ToUniversalTime().ToString('O',$culture),([long]$Entry.Sequence).ToString($culture),$(if([bool]$Entry.IsCoreConnected){'True'}else{'False'}),$(if([bool]$Entry.IsLive){'True'}else{'False'}),[string]$Entry.RuntimeStatus,([DateTimeOffset]$Entry.LastTransitionUtc).ToUniversalTime().ToString('O',$culture),$accepted,([long]$Entry.ConnectionEpoch).ToString($culture),([long]$Entry.BootstrapCount).ToString($culture),([long]$Entry.EventCount).ToString($culture),([long]$Entry.DisconnectCount).ToString($culture),([long]$Entry.ReconciliationCount).ToString($culture),[string]$Entry.StateSha256,[string]$Entry.PreviousEntrySha256)-join'|'
}

function Assert-MatrixProgressEntry {
    param($Entry,[int]$Ordinal,[string]$Previous,[string]$Context)
    foreach($name in @('Ordinal','Phase','ObservedUtc','Sequence','IsCoreConnected','IsLive','RuntimeStatus','LastTransitionUtc','LastAcceptedStateUtc','ConnectionEpoch','BootstrapCount','EventCount','DisconnectCount','ReconciliationCount','StateSha256','PreviousEntrySha256','CanonicalPayload','EntrySha256')){$null=Get-MatrixProperty $Entry $name $Context}
    if(-not(Test-MatrixNativeInteger $Entry.Ordinal)-or[long]$Entry.Ordinal-ne$Ordinal){throw "$Context has a non-native or unexpected ordinal."}
    foreach($name in @('Sequence','ConnectionEpoch','BootstrapCount','EventCount','DisconnectCount','ReconciliationCount')){if(-not(Test-MatrixNativeInteger $Entry.$name)){throw "$Context '$name' is not a native JSON integer."}}
    foreach($name in @('IsCoreConnected','IsLive')){if($Entry.$name-isnot[bool]){throw "$Context '$name' is not a native JSON boolean."}}
    $null=[DateTimeOffset]$Entry.ObservedUtc;$null=[DateTimeOffset]$Entry.LastTransitionUtc;if($null-ne$Entry.LastAcceptedStateUtc){$null=[DateTimeOffset]$Entry.LastAcceptedStateUtc}
    Assert-MatrixEqual (Assert-MatrixSha256 $Entry.StateSha256 "$Context state hash") ([string]$Entry.StateSha256).ToUpperInvariant() "$Context state hash case"
    Assert-MatrixEqual (Assert-MatrixSha256 $Entry.PreviousEntrySha256 "$Context previous hash") $Previous "$Context chain"
    $canonical=Get-MatrixProgressCanonicalPayload $Entry;Assert-MatrixEqual ([string]$Entry.CanonicalPayload) $canonical "$Context canonical payload"
    Assert-MatrixEqual (Assert-MatrixSha256 $Entry.EntrySha256 "$Context entry hash") (Get-MatrixTextSha256 $canonical) "$Context entry hash"
}

function Assert-MatrixRuntimeSemantics {
    param($App,$Core,[string]$Language)
    foreach($name in @('RuntimeObserved','SnapshotObserved','EventObserved','ReconnectObserved')){if((Get-MatrixProperty $Core $name "$Language Core report")-isnot[bool]-or-not[bool]$Core.$name){throw "$Language Core '$name' must be native true."}}
    foreach($owner in @($App,$Core)){if((Get-MatrixProperty $owner 'SessionControlInvoked' "$Language runtime report")-isnot[bool]-or[bool]$owner.SessionControlInvoked){throw "$Language runtime report SessionControlInvoked must be native false."}}
    $transitions=@(Get-MatrixProperty $Core 'Transitions' "$Language Core report");if($transitions.Count-lt 4){throw "$Language Core transition trace is incomplete."};$previousUtc=$null
    for($i=0;$i-lt$transitions.Count;$i++){$transition=$transitions[$i];foreach($name in @('IngestSequence','ConnectionEpoch','BootstrapCount','EventCount','DisconnectCount','ReconciliationCount')){if(-not(Test-MatrixNativeInteger (Get-MatrixProperty $transition $name "$Language Core transition $i"))){throw "$Language Core transition $i '$name' is not a native integer."}};$utc=[DateTimeOffset](Get-MatrixProperty $transition 'ObservedUtc' "$Language Core transition $i");if($null-ne$previousUtc-and$utc-lt$previousUtc){throw "$Language Core transition timestamps moved backward."};if($i-gt0){foreach($name in @('IngestSequence','ConnectionEpoch','BootstrapCount','EventCount','DisconnectCount','ReconciliationCount')){if([long]$transition.$name-lt[long]$transitions[$i-1].$name){throw "$Language Core transition counter '$name' moved backward."}}};$previousUtc=$utc}
    $boundIndexes=@{}
    foreach($binding in @(@('InitialSequence','InitialStateSha256'),@('PreCloseSequence','PreCloseStateSha256'),@('PostCloseSequence','PostCloseStateSha256'))){$seq=Get-MatrixProperty $App $binding[0] "$Language App report";$sha=Assert-MatrixSha256 (Get-MatrixProperty $App $binding[1] "$Language App report") "$Language $($binding[1])";if(-not(Test-MatrixNativeInteger $seq)){throw "$Language $($binding[0]) is not a native integer."};$matches=@($transitions|Where-Object{[string]$_.Status-ceq'Connected'-and[long]$_.IngestSequence-eq[long]$seq-and[string]$_.ContractStateSha256-ceq$sha});if($matches.Count-ne1){throw "$Language App/Core transition binding '$($binding[0])' is not exact."}}
    foreach($name in @('InitialSequence','PreCloseSequence','PostCloseSequence')){for($i=0;$i-lt$transitions.Count;$i++){if([long]$transitions[$i].IngestSequence-eq[long]$App.$name){$boundIndexes[$name]=$i;break}}};if($boundIndexes.InitialSequence-ge$boundIndexes.PreCloseSequence-or$boundIndexes.PreCloseSequence-ge$boundIndexes.PostCloseSequence){throw "$Language initial/Event A/Event B transition order is invalid."}
    $disconnectIndex=-1;$reconnectIndex=-1;for($i=$boundIndexes.PreCloseSequence+1;$i-lt$boundIndexes.PostCloseSequence;$i++){if($disconnectIndex-lt0-and[string]$transitions[$i].Status-ceq'Reconnecting'){$disconnectIndex=$i};if($disconnectIndex-ge0-and[string]$transitions[$i].Status-ceq'Connected'-and[long]$transitions[$i].ConnectionEpoch-gt[long]$App.PreRestartConnectionEpoch-and[long]$transitions[$i].BootstrapCount-gt[long]$App.PreRestartBootstrapCount-and[long]$transitions[$i].DisconnectCount-gt[long]$App.PreRestartDisconnectCount){$reconnectIndex=$i;break}}
    if($disconnectIndex-lt0-or$reconnectIndex-le$disconnectIndex){throw "$Language does not contain an ordered disconnect then reconnect before Event B."};foreach($name in @('PreRestartConnectionEpoch','ReconnectedConnectionEpoch','PreRestartBootstrapCount','ReconnectedBootstrapCount','PreRestartDisconnectCount','ReconnectedDisconnectCount')){if(-not(Test-MatrixNativeInteger (Get-MatrixProperty $App $name "$Language App report"))){throw "$Language '$name' is not a native integer."}};if([long]$App.ReconnectedConnectionEpoch-le[long]$App.PreRestartConnectionEpoch-or[long]$App.ReconnectedBootstrapCount-le[long]$App.PreRestartBootstrapCount-or[long]$App.ReconnectedDisconnectCount-le[long]$App.PreRestartDisconnectCount){throw "$Language App reconnect counters did not advance."};$closed=[DateTimeOffset](Get-MatrixProperty $App 'DashboardClosedUtc' "$Language App report");$disconnected=[DateTimeOffset](Get-MatrixProperty $App 'DisconnectObservedUtc' "$Language App report");$reconnected=[DateTimeOffset](Get-MatrixProperty $App 'ReconnectObservedUtc' "$Language App report");if($closed-gt$disconnected-or$disconnected-gt$reconnected){throw "$Language App disconnect/reconnect timestamps are not chronological."}
    foreach($eventName in @('EventA','EventB')){
        $event=Get-MatrixProperty $App $eventName "$Language App report";Assert-MatrixEqual (Get-MatrixProperty $event 'AcceptedEventKind' "$Language $eventName") 'pane.agent_status_changed' "$Language $eventName kind";Assert-MatrixEqual (Get-MatrixProperty $event 'AdmissionPath' "$Language $eventName") 'direct-event' "$Language $eventName admission"
        foreach($name in @('CurrentIsCoreConnected','CurrentIsLive')){if($event.$name-isnot[bool]-or-not[bool]$event.$name){throw "$Language $eventName $name must be native true."}}
        foreach($name in @('BaselineSequence','CurrentSequence','BaselineEventCount','CurrentEventCount','BaselineBootstrapCount','CurrentBootstrapCount','BaselineDisconnectCount','CurrentDisconnectCount','BaselineReconciliationCount','CurrentReconciliationCount')){if(-not(Test-MatrixNativeInteger (Get-MatrixProperty $event $name "$Language $eventName"))){throw "$Language $eventName '$name' is not a native integer."}}
        if([long]$event.CurrentSequence-ne([long]$event.BaselineSequence+1)-or[long]$event.CurrentEventCount-ne([long]$event.BaselineEventCount+1)-or[long]$event.CurrentBootstrapCount-ne[long]$event.BaselineBootstrapCount-or[long]$event.CurrentDisconnectCount-ne[long]$event.BaselineDisconnectCount-or[long]$event.CurrentReconciliationCount-ne([long]$event.BaselineReconciliationCount+1)){throw "$Language $eventName does not have exact accepted-event semantics."}
        $changes=@(Get-MatrixProperty $event 'Changes' "$Language $eventName");$changeCount=Get-MatrixProperty $event 'ChangeCount' "$Language $eventName";if(-not(Test-MatrixNativeInteger $changeCount)-or[long]$changeCount-ne1-or$changes.Count-ne1){throw "$Language $eventName must bind exactly one native Agent-status change."};$change=$changes[0]
        foreach($name in @('TerminalId','WorkspaceId','TabId','PaneId','PreviousStatus','CurrentStatus','CurrentAgentKind','CurrentAgentName')){if([string]::IsNullOrWhiteSpace([string](Get-MatrixProperty $change $name "$Language $eventName change"))){throw "$Language $eventName change '$name' is blank."}}
        if([string]$change.PreviousStatus-ceq[string]$change.CurrentStatus-or-not(Test-MatrixNativeInteger (Get-MatrixProperty $change 'PreviousStateChangeSequence' "$Language $eventName change"))-or-not(Test-MatrixNativeInteger (Get-MatrixProperty $change 'CurrentStateChangeSequence' "$Language $eventName change"))-or[long]$change.CurrentStateChangeSequence-le[long]$change.PreviousStateChangeSequence){throw "$Language $eventName does not prove a native status transition."}
        $match=@($transitions|Where-Object{[long]$_.IngestSequence-eq[long]$event.CurrentSequence-and[string]$_.ContractStateSha256-ceq[string]$event.CurrentStateSha256-and[string]$_.AcceptedEventKind-ceq'pane.agent_status_changed'});if($match.Count-ne1){throw "$Language $eventName is not bound to one accepted Core transition."};$expectedSequence=if($eventName-ceq'EventA'){$App.PreCloseSequence}else{$App.PostCloseSequence};Assert-MatrixEqual $event.CurrentSequence $expectedSequence "$Language $eventName rendered state binding";$accepted=Get-MatrixProperty $match[0] 'AcceptedAgentStatusEvent' "$Language $eventName Core transition"
        foreach($pair in @(@('WorkspaceId','WorkspaceId'),@('TabId','TabId'),@('PaneId','PaneId'),@('AgentStatus','CurrentStatus'),@('Agent','CurrentAgentKind'),@('AgentName','CurrentAgentName'))){Assert-MatrixEqual (Get-MatrixProperty $accepted $pair[0] "$Language $eventName accepted payload") $change.($pair[1]) "$Language $eventName accepted payload '$($pair[0])'"}
    }
}

function Get-MatrixValidatedPackage {
    $validator=Join-Path ([IO.Path]::GetFullPath($RepositoryRoot)) 'tools\packaging\v0.2\Test-V02PackageIdentity.ps1'
    foreach($item in @(@($PackageIdentityPath,'Leaf','package receipt'),@($PackageArchivePath,'Leaf','package archive'),@($ExtractedPackageRoot,'Container','extracted package root'),@($RepositoryRoot,'Container','repository root'),@($PackageProfilePath,'Leaf','package profile'),@($validator,'Leaf','committed package validator'))){if(-not(Test-Path -LiteralPath $item[0] -PathType $item[1])){throw "Missing $($item[2]): $($item[0])"}}
    $output=@(& $validator -IdentityPath $PackageIdentityPath -ArchivePath $PackageArchivePath -PackageRoot $ExtractedPackageRoot -RepositoryRoot $RepositoryRoot -ProfilePath $PackageProfilePath);if($output.Count-ne1){throw 'Committed package validator must return exactly one result.'};$result=$output[0]
    foreach($name in @('ReceiptSha256','ArchiveSha256','AppSha256','CoreSha256','SourceCommit','SourceTree','ProfileId','EvidenceClass')){$null=Get-MatrixProperty $result $name 'package validator result'}
    Assert-MatrixEqual $result.EvidenceClass 'Static/PackagedCompatibilityPreparation' 'package validator evidence class';foreach($name in @('ReceiptSha256','ArchiveSha256','AppSha256','CoreSha256')){$null=Assert-MatrixSha256 $result.$name "package validator $name"}
    if([string]$result.SourceCommit-cnotmatch'^[0-9a-f]{40}$'-or[string]$result.SourceTree-cnotmatch'^[0-9a-f]{40}$'){throw 'Package validator source identity is invalid.'}
    $profile=(ConvertFrom-V02StrictUtf8JsonFile $PackageProfilePath).Value;$root=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $ExtractedPackageRoot).Path);$appPath=Join-Path $root ([string](Get-MatrixProperty (Get-MatrixProperty $profile 'components' 'package profile') 'appRelativePath' 'package profile components'));$corePath=Join-Path $root ([string]$profile.components.coreRelativePath);$manifestPath=Join-Path $root ([string](Get-MatrixProperty $profile 'packageManifestFileName' 'package profile'))
    foreach($path in @($appPath,$corePath,$manifestPath)){if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw "Validated package artifact is missing: $path"}}
    Assert-MatrixEqual (Get-FileHash $appPath -Algorithm SHA256).Hash $result.AppSha256 'validated package App bytes';Assert-MatrixEqual (Get-FileHash $corePath -Algorithm SHA256).Hash $result.CoreSha256 'validated package Core bytes'
    $identityFull=[IO.Path]::GetFullPath((Resolve-Path $PackageIdentityPath).Path);return [pscustomobject]@{ReceiptSha256=[string]$result.ReceiptSha256;IdentityFileSha256=(Get-FileHash $identityFull -Algorithm SHA256).Hash;ArchiveSha256=[string]$result.ArchiveSha256;AppSha256=[string]$result.AppSha256;CoreSha256=[string]$result.CoreSha256;SourceCommit=[string]$result.SourceCommit;SourceTree=[string]$result.SourceTree;ProfileId=[string]$result.ProfileId;IdentityPath=$identityFull;ArchivePath=[IO.Path]::GetFullPath((Resolve-Path $PackageArchivePath).Path);PackageRoot=$root;ProfilePath=[IO.Path]::GetFullPath((Resolve-Path $PackageProfilePath).Path);ManifestSha256=(Get-FileHash $manifestPath -Algorithm SHA256).Hash;AppPath=$appPath;CorePath=$corePath;ManifestPath=$manifestPath}
}

function Assert-MatrixPng {
    param([string]$Path,$Capture,[string]$Context)
    $width=Get-MatrixProperty $Capture 'PixelWidth' $Context;$height=Get-MatrixProperty $Capture 'PixelHeight' $Context;if(-not(Test-MatrixNativeInteger $width)-or-not(Test-MatrixNativeInteger $height)-or[long]$width-le0-or[long]$height-le0){throw "$Context dimensions must be positive native JSON integers."}
    $bytes=[IO.File]::ReadAllBytes($Path);$signature=[byte[]](137,80,78,71,13,10,26,10);if($bytes.Length-lt24){throw "$Context is not a complete PNG."};for($i=0;$i-lt8;$i++){if($bytes[$i]-ne$signature[$i]){throw "$Context PNG signature is invalid."}}
    Add-Type -AssemblyName System.Drawing;$stream=New-Object IO.MemoryStream(,$bytes);try{$image=[Drawing.Image]::FromStream($stream,$true,$true);try{$bitmap=New-Object Drawing.Bitmap($image);try{$null=$bitmap.GetPixel([int]$bitmap.Width-1,[int]$bitmap.Height-1);if($bitmap.Width-ne[long]$width-or$bitmap.Height-ne[long]$height){throw "$Context decoded dimensions differ from the report."}}finally{$bitmap.Dispose()}}finally{$image.Dispose()}}finally{$stream.Dispose()}
}

function Read-MatrixRun {
    param([Parameter(Mandatory)][string]$EvidenceDirectory,[Parameter(Mandatory)][ValidateSet('Thai','English')][string]$ExpectedLanguage,[Parameter(Mandatory)]$Package)
    $gatePath=Join-Path $EvidenceDirectory 'gate-report.txt';$appPath=Join-Path $EvidenceDirectory 'app-runtime.json';$corePath=Join-Path $EvidenceDirectory 'core-runtime.json'
    foreach($required in @($gatePath,$appPath,$corePath)) { if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "$ExpectedLanguage evidence omitted required file: $required" } }
    $gate=Read-MatrixGateReport $gatePath
    Assert-MatrixEqual (Get-MatrixGateValue $gate 'Result' $ExpectedLanguage) 'PASS' "$ExpectedLanguage gate result"
    Assert-MatrixEqual (Get-MatrixGateValue $gate 'EvidenceClass' $ExpectedLanguage) 'Runtime' "$ExpectedLanguage gate evidence class"
    Assert-MatrixEqual (Get-MatrixGateValue $gate 'PreRunGitTreeClean' $ExpectedLanguage) 'True' "$ExpectedLanguage pre-run clean tree"
    Assert-MatrixEqual (Get-MatrixGateValue $gate 'PostRunGitTreeClean' $ExpectedLanguage) 'True' "$ExpectedLanguage post-run clean tree"
    Assert-MatrixEqual (Get-MatrixGateValue $gate 'SessionControlInvoked' $ExpectedLanguage) 'false' "$ExpectedLanguage session-control boundary"
    Assert-MatrixEqual (Get-MatrixGateValue $gate 'Language' $ExpectedLanguage) $ExpectedLanguage "$ExpectedLanguage gate language"
    $rendererPolicy=Get-MatrixGateValue $gate 'RendererPolicyId' $ExpectedLanguage;$renderMode=Get-MatrixGateValue $gate 'WpfProcessRenderMode' $ExpectedLanguage
    Assert-MatrixEqual $rendererPolicy 'software-only-process-wide' "$ExpectedLanguage renderer policy";Assert-MatrixEqual $renderMode 'SoftwareOnly' "$ExpectedLanguage WPF render mode";Assert-MatrixEqual (Get-MatrixGateValue $gate 'SoftwareOnlyThroughout' $ExpectedLanguage) 'True' "$ExpectedLanguage renderer lifecycle"
    $app=(ConvertFrom-V02StrictUtf8JsonFile $appPath).Value;$core=(ConvertFrom-V02StrictUtf8JsonFile $corePath).Value
    Assert-MatrixEqual (Get-MatrixProperty $app 'EvidenceClassification' "$ExpectedLanguage app report") 'RuntimeCandidate' "$ExpectedLanguage app classification"
    if ((Get-MatrixProperty $app 'CompositeCandidateChecksPassed' "$ExpectedLanguage app report") -isnot [bool] -or -not [bool]$app.CompositeCandidateChecksPassed) { throw "$ExpectedLanguage App candidate checks did not pass." }
    Assert-MatrixEqual (Get-MatrixProperty $app 'Language' "$ExpectedLanguage app report") $ExpectedLanguage "$ExpectedLanguage app language"
    Assert-MatrixEqual (Get-MatrixProperty $core 'EvidenceClassification' "$ExpectedLanguage core report") 'Runtime' "$ExpectedLanguage core classification"
    $expectedCulture=if($ExpectedLanguage-ceq'Thai'){'th-TH'}else{'en-US'}
    foreach($name in @('LanguageCultureName','FinalLanguageCultureName')){Assert-MatrixEqual (Get-MatrixProperty $app $name "$ExpectedLanguage app report") $expectedCulture "$ExpectedLanguage $name"}
    Assert-MatrixEqual (Get-MatrixProperty $app 'FinalLanguage' "$ExpectedLanguage app report") $ExpectedLanguage "$ExpectedLanguage final language"
    if((Get-MatrixProperty $app 'LanguageStableThroughFinish' "$ExpectedLanguage app report")-isnot[bool]-or-not[bool]$app.LanguageStableThroughFinish){throw "$ExpectedLanguage LanguageStableThroughFinish must be native true."}
    $languageChanges=Get-MatrixProperty $app 'LanguageChangeCount' "$ExpectedLanguage app report";if(-not(Test-MatrixNativeInteger $languageChanges)-or[long]$languageChanges-ne0){throw "$ExpectedLanguage LanguageChangeCount must be native integer zero."}
    Assert-MatrixRuntimeSemantics $app $core $ExpectedLanguage

    $actualAppReportHash=(Get-FileHash -LiteralPath $appPath -Algorithm SHA256).Hash.ToUpperInvariant();$actualCoreReportHash=(Get-FileHash -LiteralPath $corePath -Algorithm SHA256).Hash.ToUpperInvariant()
    Assert-MatrixEqual (Assert-MatrixSha256 (Get-MatrixGateValue $gate 'AppRuntimeReportSha256' $ExpectedLanguage) "$ExpectedLanguage declared App report hash") $actualAppReportHash "$ExpectedLanguage App report hash"
    Assert-MatrixEqual (Assert-MatrixSha256 (Get-MatrixGateValue $gate 'CoreRuntimeReportSha256' $ExpectedLanguage) "$ExpectedLanguage declared Core report hash") $actualCoreReportHash "$ExpectedLanguage Core report hash"

    $profileId=[string](Get-MatrixProperty $app 'ProfileId' "$ExpectedLanguage app report");$profileSha=Assert-MatrixSha256 (Get-MatrixProperty $app 'ProfileSha256' "$ExpectedLanguage app report") "$ExpectedLanguage app profile hash"
    Assert-MatrixEqual (Get-MatrixGateValue $gate 'ReferenceHostProfileId' $ExpectedLanguage) $profileId "$ExpectedLanguage profile ID"
    Assert-MatrixEqual (Assert-MatrixSha256 (Get-MatrixGateValue $gate 'ReferenceHostProfileSha256' $ExpectedLanguage) "$ExpectedLanguage gate profile hash") $profileSha "$ExpectedLanguage profile hash"
    Assert-MatrixEqual $profileId $script:V02ReferenceHostProfileId "$ExpectedLanguage approved profile ID"
    Assert-MatrixEqual $profileSha $script:V02ReferenceHostProfileSha256 "$ExpectedLanguage approved profile hash"
    $referenceHostSchemaSha=Assert-MatrixSha256 (Get-MatrixGateValue $gate 'ReferenceHostSchemaSha256' $ExpectedLanguage) "$ExpectedLanguage reference-host schema hash"
    Assert-MatrixEqual $referenceHostSchemaSha $script:V02ReferenceHostSchemaSha256 "$ExpectedLanguage approved reference-host schema hash"
    $admission=Get-MatrixProperty $core 'Admission' "$ExpectedLanguage core report"
    $herdrRelease=[string](Get-MatrixProperty $admission 'ReleaseId' "$ExpectedLanguage Core Admission");$herdrSha=Assert-MatrixSha256 (Get-MatrixProperty $admission 'ExecutableSha256' "$ExpectedLanguage Core Admission") "$ExpectedLanguage Herdr hash"
    $schemaSha=Assert-MatrixSha256 (Get-MatrixProperty $admission 'BundledSchemaSha256' "$ExpectedLanguage Core Admission") "$ExpectedLanguage bundled schema hash";$protocol=[string](Get-MatrixProperty $admission 'Protocol' "$ExpectedLanguage Core Admission")
    if(-not(Test-MatrixNativeInteger $admission.Protocol)){throw "$ExpectedLanguage Core Admission Protocol is not a native integer."}
    Assert-MatrixEqual (Get-MatrixGateValue $gate 'HerdrReleaseId' $ExpectedLanguage) $herdrRelease "$ExpectedLanguage Herdr release"
    Assert-MatrixEqual (Assert-MatrixSha256 (Get-MatrixGateValue $gate 'HerdrExecutableSha256' $ExpectedLanguage) "$ExpectedLanguage gate Herdr hash") $herdrSha "$ExpectedLanguage Herdr hash"
    Assert-MatrixEqual (Assert-MatrixSha256 (Get-MatrixGateValue $gate 'BundledSchemaSha256' $ExpectedLanguage) "$ExpectedLanguage gate schema hash") $schemaSha "$ExpectedLanguage schema hash"
    Assert-MatrixEqual (Get-MatrixGateValue $gate 'HerdrProtocol' $ExpectedLanguage) $protocol "$ExpectedLanguage protocol"

    $resource=Get-MatrixProperty $app 'ResourceMeasurement' "$ExpectedLanguage app report";$appResource=Get-MatrixProperty $resource 'App' "$ExpectedLanguage resource report";$coreResource=Get-MatrixProperty $resource 'Core' "$ExpectedLanguage resource report"
    $appBinary=Assert-MatrixSha256 (Get-MatrixProperty $appResource 'ExecutableSha256' "$ExpectedLanguage App resource") "$ExpectedLanguage App report binary";$coreBinary=Assert-MatrixSha256 (Get-MatrixProperty $coreResource 'ExecutableSha256' "$ExpectedLanguage Core resource") "$ExpectedLanguage Core report binary"
    foreach($pair in @(@('HerdrOpsAppExecutableSha256BeforeLaunch',$appBinary),@('HerdrOpsAppExecutableSha256AfterRun',$appBinary),@('HerdrOpsAppExecutableSha256BoundToReports',$appBinary),@('HerdrOpsCoreExecutableSha256BeforeLaunch',$coreBinary),@('HerdrOpsCoreExecutableSha256AfterRun',$coreBinary),@('HerdrOpsCoreExecutableSha256BoundToReports',$coreBinary))) {
        Assert-MatrixEqual (Assert-MatrixSha256 (Get-MatrixGateValue $gate $pair[0] $ExpectedLanguage) "$ExpectedLanguage $($pair[0])") $pair[1] "$ExpectedLanguage $($pair[0])"
    }
    Assert-MatrixEqual (Assert-MatrixSha256 (Get-MatrixGateValue $gate 'AppSha256' $ExpectedLanguage) "$ExpectedLanguage package App hash") $appBinary "$ExpectedLanguage package App hash"
    Assert-MatrixEqual (Assert-MatrixSha256 (Get-MatrixGateValue $gate 'CoreSha256' $ExpectedLanguage) "$ExpectedLanguage package Core hash") $coreBinary "$ExpectedLanguage package Core hash"
    foreach($name in @('SnapshotObserved','EventObserved','ReconnectObserved')){Assert-MatrixEqual (Get-MatrixGateValue $gate $name $ExpectedLanguage) 'True' "$ExpectedLanguage gate $name"}

    $identity=@{};foreach($name in @('ExpectedSourceCommit','SourceCommit','PreRunSourceCommit','PostRunSourceCommit')) { $value=Get-MatrixGateValue $gate $name $ExpectedLanguage;if($value -notmatch '^[0-9a-f]{40}$'){throw "$ExpectedLanguage $name is not a normalized Git commit."};$identity[$name]=$value }
    foreach($name in @('ExpectedSourceTree','SourceTree','PreRunSourceTree','PostRunSourceTree')) { $value=Get-MatrixGateValue $gate $name $ExpectedLanguage;if($value -notmatch '^[0-9a-f]{40}$'){throw "$ExpectedLanguage $name is not a normalized Git tree."};$identity[$name]=$value }
    foreach($name in @('SourceCommit','PreRunSourceCommit','PostRunSourceCommit')) { Assert-MatrixEqual $identity[$name] $identity.ExpectedSourceCommit "$ExpectedLanguage commit binding $name" }
    foreach($name in @('SourceTree','PreRunSourceTree','PostRunSourceTree')) { Assert-MatrixEqual $identity[$name] $identity.ExpectedSourceTree "$ExpectedLanguage tree binding $name" }

    $packageReceiptSha=Assert-MatrixSha256 (Get-MatrixGateValue $gate 'PackageIdentityReceiptSha256' $ExpectedLanguage) "$ExpectedLanguage package receipt hash";Assert-MatrixEqual $packageReceiptSha $Package.ReceiptSha256 "$ExpectedLanguage independently validated receipt"
    foreach($pair in @(@('PackageArchiveSha256','ArchiveSha256'),@('PackageManifestSha256','ManifestSha256'),@('AppSha256','AppSha256'),@('CoreSha256','CoreSha256'))){Assert-MatrixEqual (Assert-MatrixSha256 (Get-MatrixGateValue $gate $pair[0] $ExpectedLanguage) "$ExpectedLanguage $($pair[0])") $Package.($pair[1]) "$ExpectedLanguage independently validated $($pair[0])"}
    foreach($pair in @(@('PackageIdentityPath','IdentityPath'),@('PackageArchivePath','ArchivePath'),@('ExtractedPackageRoot','PackageRoot'))){Assert-MatrixEqual ([IO.Path]::GetFullPath((Get-MatrixGateValue $gate $pair[0] $ExpectedLanguage))) $Package.($pair[1]) "$ExpectedLanguage $($pair[0])"}
    Assert-MatrixEqual (Get-MatrixGateValue $gate 'PackageProfileId' $ExpectedLanguage) $Package.ProfileId "$ExpectedLanguage package profile ID";Assert-MatrixEqual (Get-MatrixGateValue $gate 'PackageValidationEvidenceClass' $ExpectedLanguage) 'Static/PackagedCompatibilityPreparation' "$ExpectedLanguage package validation boundary"
    Assert-MatrixEqual $identity.ExpectedSourceCommit $Package.SourceCommit "$ExpectedLanguage package source commit";Assert-MatrixEqual $identity.ExpectedSourceTree $Package.SourceTree "$ExpectedLanguage package source tree"
    $progressPath=Join-Path $EvidenceDirectory 'app-progress.json';$progressHistoryPath=Join-Path $EvidenceDirectory 'app-progress.json.history.jsonl'
    foreach($required in @($progressPath,$progressHistoryPath)){if(-not(Test-Path -LiteralPath $required -PathType Leaf)){throw "$ExpectedLanguage evidence omitted progress artifact: $required"}}
    $declaredHistoryPath=[IO.Path]::GetFullPath((Get-MatrixGateValue $gate 'ProgressHistoryPath' $ExpectedLanguage));Assert-MatrixEqual $declaredHistoryPath ([IO.Path]::GetFullPath($progressHistoryPath)) "$ExpectedLanguage progress history path"
    $historyFileSha=(Get-FileHash -LiteralPath $progressHistoryPath -Algorithm SHA256).Hash.ToUpperInvariant();Assert-MatrixEqual (Assert-MatrixSha256 (Get-MatrixGateValue $gate 'ProgressHistorySha256' $ExpectedLanguage) "$ExpectedLanguage progress history file hash") $historyFileSha "$ExpectedLanguage progress history file hash"
    $historyLines=@([IO.File]::ReadAllLines($progressHistoryPath));$expectedPhases=@('waiting-for-live-state','capturing-live-dashboard-and-widgets','waiting-for-pre-close-update','dashboard-closed-waiting-for-herdr-disconnect','herdr-disconnected-waiting-for-reconnect','herdr-reconnected-waiting-for-post-reconnect-update','waiting-for-idle-stability','measuring-idle-resources','complete')
    if($historyLines.Count-ne$expectedPhases.Count){throw "$ExpectedLanguage progress history must contain exactly nine records."};$history=@();$previous='0'*64;$previousEntry=$null
    for($i=0;$i-lt$historyLines.Count;$i++){if([string]::IsNullOrWhiteSpace($historyLines[$i])){throw "$ExpectedLanguage progress history contains a blank record."};$entry=ConvertFrom-MatrixJsonText $historyLines[$i];Assert-MatrixProgressEntry $entry ($i+1) $previous "$ExpectedLanguage progress entry $($i+1)";Assert-MatrixEqual $entry.Phase $expectedPhases[$i] "$ExpectedLanguage progress phase $($i+1)";if($null-ne$previousEntry){if([DateTimeOffset]$entry.ObservedUtc-lt[DateTimeOffset]$previousEntry.ObservedUtc){throw "$ExpectedLanguage progress timestamps moved backward."};foreach($name in @('Sequence','ConnectionEpoch','BootstrapCount','EventCount','DisconnectCount','ReconciliationCount')){if([long]$entry.$name-lt[long]$previousEntry.$name){throw "$ExpectedLanguage progress counter '$name' moved backward."}}};$previousEntry=$entry;$previous=[string]$entry.EntrySha256;$history+=$entry}
    if([bool]$history[3].IsCoreConnected-ne$true-or[string]$history[3].RuntimeStatus-cne'Connected'-or[bool]$history[4].IsCoreConnected-ne$false-or[string]$history[4].RuntimeStatus-cne'Reconnecting'-or[bool]$history[5].IsCoreConnected-ne$true-or[string]$history[5].RuntimeStatus-cne'Connected'){throw "$ExpectedLanguage progress disconnect/reconnect phase semantics are invalid."};Assert-MatrixEqual $history[8].Sequence $app.PostCloseSequence "$ExpectedLanguage final progress sequence";Assert-MatrixEqual $history[8].StateSha256 $app.PostCloseStateSha256 "$ExpectedLanguage final progress state"
    if([int](Get-MatrixGateValue $gate 'ProgressHistoryEntries' $ExpectedLanguage)-ne9){throw "$ExpectedLanguage gate progress count is not nine."};Assert-MatrixEqual (Assert-MatrixSha256 (Get-MatrixGateValue $gate 'ProgressHistoryLastEntrySha256' $ExpectedLanguage) "$ExpectedLanguage final progress hash") $previous "$ExpectedLanguage final progress hash"
    $progress=(ConvertFrom-V02StrictUtf8JsonFile $progressPath).Value;$progressItems=@(Get-MatrixProperty $progress 'History' "$ExpectedLanguage progress report");if($progressItems.Count-ne9){throw "$ExpectedLanguage progress report history count differs."};Assert-MatrixEqual ([IO.Path]::GetFullPath([string](Get-MatrixProperty $progress 'ProgressHistoryPath' "$ExpectedLanguage progress report"))) ([IO.Path]::GetFullPath($progressHistoryPath)) "$ExpectedLanguage progress pointer path"
    for($i=0;$i-lt9;$i++){Assert-MatrixProgressEntry $progressItems[$i] ($i+1) $(if($i-eq0){'0'*64}else{[string]$progressItems[$i-1].EntrySha256}) "$ExpectedLanguage progress mirror $($i+1)";Assert-MatrixEqual $progressItems[$i].CanonicalPayload $history[$i].CanonicalPayload "$ExpectedLanguage progress report/history record $($i+1)"}
    Assert-MatrixProgressEntry $progress 9 ([string]$history[7].EntrySha256) "$ExpectedLanguage final progress pointer";Assert-MatrixEqual $progress.CanonicalPayload $history[8].CanonicalPayload "$ExpectedLanguage final progress pointer"

    $captureCatalog=[ordered]@{'dashboard-overview'=@('InitialSequence','InitialStateSha256');'dashboard-live-organization'=@('InitialSequence','InitialStateSha256');'dashboard-agent-detail'=@('InitialSequence','InitialStateSha256');'widget-compact'=@('InitialSequence','InitialStateSha256');'widget-normal'=@('InitialSequence','InitialStateSha256');'widget-floating-vertical'=@('InitialSequence','InitialStateSha256');'dashboard-overview-after-event'=@('PreCloseSequence','PreCloseStateSha256');'widget-floating-vertical-after-dashboard-close'=@('PostCloseSequence','PostCloseStateSha256')}
    $runtimeCaptureCount=Get-MatrixGateValue $gate 'RuntimeWpfCaptures' $ExpectedLanguage;if($runtimeCaptureCount-cnotmatch'^[0-9]+$'-or[int]$runtimeCaptureCount-ne8){throw "$ExpectedLanguage RuntimeWpfCaptures must be exactly 8."}
    $captures=@(Get-MatrixProperty $app 'Captures' "$ExpectedLanguage app report");if($captures.Count-ne8){throw "$ExpectedLanguage capture set must contain the exact approved eight captures."}
    $captureByName=@{};$captureRoots=@{}
    foreach($capture in $captures) {
        $name=[string](Get-MatrixProperty $capture 'Name' "$ExpectedLanguage capture");if([string]::IsNullOrWhiteSpace($name)-or$captureByName.ContainsKey($name)){throw "$ExpectedLanguage capture names must be nonempty and unique."}
        if(-not$captureCatalog.Contains($name)){throw "$ExpectedLanguage capture '$name' is not in the approved catalog."};Assert-MatrixEqual (Get-MatrixProperty $capture 'Language' "$ExpectedLanguage capture '$name'") $ExpectedLanguage "$ExpectedLanguage capture '$name' language";Assert-MatrixEqual (Get-MatrixProperty $capture 'LanguageCultureName' "$ExpectedLanguage capture '$name'") $expectedCulture "$ExpectedLanguage capture '$name' culture"
        $binding=$captureCatalog[$name];$captureSequence=Get-MatrixProperty $capture 'StateSequence' "$ExpectedLanguage capture '$name'";if(-not(Test-MatrixNativeInteger $captureSequence)){throw "$ExpectedLanguage capture '$name' StateSequence is not a native integer."};Assert-MatrixEqual $captureSequence $app.($binding[0]) "$ExpectedLanguage capture '$name' sequence";Assert-MatrixEqual (Assert-MatrixSha256 (Get-MatrixProperty $capture 'StateSha256' "$ExpectedLanguage capture '$name'") "$ExpectedLanguage capture '$name' state hash") $app.($binding[1]) "$ExpectedLanguage capture '$name' state binding"
        $declared=Assert-MatrixSha256 (Get-MatrixProperty $capture 'Sha256' "$ExpectedLanguage capture '$name'") "$ExpectedLanguage capture '$name' hash";$path=[string](Get-MatrixProperty $capture 'Path' "$ExpectedLanguage capture '$name'")
        if(-not [IO.Path]::IsPathRooted($path)-or-not(Test-Path -LiteralPath $path -PathType Leaf)){throw "$ExpectedLanguage capture '$name' path is missing or not absolute."}
        $resolved=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $path).Path);if(-not(Test-MatrixPathWithin $resolved $EvidenceDirectory)){throw "$ExpectedLanguage capture '$name' is outside its evidence directory."}
        Assert-MatrixEqual (Get-FileHash -LiteralPath $resolved -Algorithm SHA256).Hash.ToUpperInvariant() $declared "$ExpectedLanguage capture '$name' hash"
        Assert-MatrixPng $resolved $capture "$ExpectedLanguage capture '$name'"
        $captureByName[$name]=[pscustomobject]@{Name=$name;Path=$resolved;Sha256=$declared};$captureRoots[[IO.Path]::GetDirectoryName($resolved)]=$true
    }
    if($captureRoots.Count -ne 1){throw "$ExpectedLanguage captures must have one exact capture root."}
    $gateCaptures=@($gate.CaptureDeclarations);if($gateCaptures.Count -ne $captures.Count){throw "$ExpectedLanguage gate capture declaration count differs from App report."}
    $seen=@{};foreach($decl in $gateCaptures){if($seen.ContainsKey($decl.Name)-or-not$captureByName.ContainsKey($decl.Name)){throw "$ExpectedLanguage gate capture names are duplicated or unknown."};Assert-MatrixEqual $decl.Sha256 $captureByName[$decl.Name].Sha256 "$ExpectedLanguage gate capture '$($decl.Name)'";$seen[$decl.Name]=$true}

    return [pscustomobject]@{Language=$ExpectedLanguage;Culture=$expectedCulture;EvidenceDirectory=$EvidenceDirectory;CaptureRoot=[string]@($captureRoots.Keys)[0];GateReportSha256=(Get-FileHash $gatePath -Algorithm SHA256).Hash.ToUpperInvariant();AppRuntimeReportSha256=$actualAppReportHash;CoreRuntimeReportSha256=$actualCoreReportHash;ProgressHistorySha256=$historyFileSha;ProgressHistoryLastEntrySha256=$previous;PackageIdentityReceiptSha256=$packageReceiptSha;SourceCommit=$identity.ExpectedSourceCommit;SourceTree=$identity.ExpectedSourceTree;ProfileId=$profileId;ProfileSha256=$profileSha;ReferenceHostSchemaSha256=$referenceHostSchemaSha;HerdrReleaseId=$herdrRelease;HerdrExecutableSha256=$herdrSha;AppExecutableSha256=$appBinary;CoreExecutableSha256=$coreBinary;BundledSchemaSha256=$schemaSha;HerdrProtocol=$protocol;RendererPolicyId=$rendererPolicy;WpfProcessRenderMode=$renderMode;CaptureCount=$captures.Count;Captures=@($captureByName.Values|Sort-Object Name)}
}

$package=Get-MatrixValidatedPackage
$thaiDirectory=Get-MatrixFullDirectory $ThaiEvidenceDirectory 'ThaiEvidenceDirectory';$englishDirectory=Get-MatrixFullDirectory $EnglishEvidenceDirectory 'EnglishEvidenceDirectory'
Assert-MatrixDistinctTrees $thaiDirectory $englishDirectory 'Thai and English evidence directories'
$thai=Read-MatrixRun $thaiDirectory 'Thai' $package;$english=Read-MatrixRun $englishDirectory 'English' $package
Assert-MatrixDistinctTrees $thai.CaptureRoot $english.CaptureRoot 'Thai and English capture roots'
foreach($name in @('SourceCommit','SourceTree','ProfileId','ProfileSha256','ReferenceHostSchemaSha256','HerdrReleaseId','HerdrExecutableSha256','AppExecutableSha256','CoreExecutableSha256','BundledSchemaSha256','HerdrProtocol','RendererPolicyId','WpfProcessRenderMode','PackageIdentityReceiptSha256')) { Assert-MatrixEqual $thai.$name $english.$name "Thai/English $name" }
Assert-MatrixEqual (Get-FileHash $package.IdentityPath -Algorithm SHA256).Hash $package.IdentityFileSha256 'package receipt stability';Assert-MatrixEqual (Get-FileHash $package.AppPath -Algorithm SHA256).Hash $package.AppSha256 'package App post-matrix stability';Assert-MatrixEqual (Get-FileHash $package.CorePath -Algorithm SHA256).Hash $package.CoreSha256 'package Core post-matrix stability';Assert-MatrixEqual (Get-FileHash $package.ManifestPath -Algorithm SHA256).Hash $package.ManifestSha256 'package manifest post-matrix stability';Assert-MatrixEqual (Get-FileHash $package.ArchivePath -Algorithm SHA256).Hash $package.ArchiveSha256 'package archive post-matrix stability'

if([string]::IsNullOrWhiteSpace($OutputPath)){ $OutputPath=Join-Path ([IO.Path]::GetDirectoryName($thaiDirectory)) 'v0.2-language-matrix-candidate.json' }
$outputFull=[IO.Path]::GetFullPath($OutputPath);if((Test-MatrixPathWithin $outputFull $thaiDirectory)-or(Test-MatrixPathWithin $outputFull $englishDirectory)){throw 'OutputPath must be outside both accepted evidence directory trees.'};if(Test-Path -LiteralPath $outputFull){throw "OutputPath already exists: $outputFull"}
$payload=[ordered]@{GeneratedUnixTimeMilliseconds=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds();IndependentHumanReview='NOT_OBSERVED';ReleaseCredit=$false;Binding=[ordered]@{SourceCommit=$thai.SourceCommit;SourceTree=$thai.SourceTree;ProfileId=$thai.ProfileId;ProfileSha256=$thai.ProfileSha256;ReferenceHostSchemaSha256=$thai.ReferenceHostSchemaSha256;PackageIdentityReceiptSha256=$thai.PackageIdentityReceiptSha256;HerdrReleaseId=$thai.HerdrReleaseId;HerdrExecutableSha256=$thai.HerdrExecutableSha256;AppExecutableSha256=$thai.AppExecutableSha256;CoreExecutableSha256=$thai.CoreExecutableSha256;BundledSchemaSha256=$thai.BundledSchemaSha256;HerdrProtocol=$thai.HerdrProtocol};Runs=@($thai,$english)}
$payloadValue=(($payload|ConvertTo-Json -Depth 20)|ConvertFrom-Json);$payloadJson=ConvertTo-V02Jcs $payloadValue;$utf8=New-Object Text.UTF8Encoding($false);$payloadSha=([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($utf8.GetBytes($payloadJson)))).Replace('-','')
$manifest=[ordered]@{EvidenceClassification='RuntimeMatrixCandidate';IndependentHumanReview='NOT_OBSERVED';ReleaseCredit=$false;ManifestFormatVersion=1;ManifestHashScope='SHA256OfRFC8785JcsUtf8NoBomPayload';ManifestPayloadSha256=$payloadSha;Payload=$payloadValue}
$json=$manifest|ConvertTo-Json -Depth 20;$parent=[IO.Path]::GetDirectoryName($outputFull);if(-not[IO.Directory]::Exists($parent)){[IO.Directory]::CreateDirectory($parent)|Out-Null}
$temporary=Join-Path $parent ('.'+[IO.Path]::GetFileName($outputFull)+'.'+[Guid]::NewGuid().ToString('N')+'.tmp')
try{[IO.File]::WriteAllText($temporary,$json,$utf8);Move-Item -LiteralPath $temporary -Destination $outputFull}catch{if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force};throw}
$fileSha=(Get-FileHash -LiteralPath $outputFull -Algorithm SHA256).Hash.ToUpperInvariant()
Write-Output 'EvidenceClass: RuntimeMatrixCandidate';Write-Output "Manifest: $outputFull";Write-Output "ManifestPayloadSha256: $payloadSha";Write-Output "ManifestFileSha256: $fileSha";Write-Output 'IndependentHumanReview: NOT_OBSERVED';Write-Output 'ReleaseCredit: false'
