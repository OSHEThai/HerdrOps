#requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'RendererCompatibility.Common.ps1')
$scriptPath=Join-Path $PSScriptRoot 'New-V02MatrixEvidenceReceipt.ps1'
$cases=@(Get-RendererGovernedMatrixCases)
if($cases.Count-ne25){throw "Expected exactly 25 governed matrix cases; observed $($cases.Count)."}

$tempBase=Join-Path $env:TEMP "HerdrOps-MatrixTests-$([guid]::NewGuid())"

function Expect-Failure {
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][scriptblock]$Action,
        [Parameter(Mandatory=$false)][string]$ExpectedSubstring
    )
    $failed=$false
    $caughtMessage=''
    try{
        &$Action
    }catch{
        $failed=$true
        $caughtMessage=$_.Exception.Message
    }
    if(-not$failed){throw "Expected hostile '$Name' to fail."}
    if(-not[string]::IsNullOrWhiteSpace($ExpectedSubstring)){
        if($caughtMessage -notmatch [regex]::Escape($ExpectedSubstring)){
            throw "Hostile '$Name' failed with unexpected message. Expected substring: '$ExpectedSubstring', observed: '$caughtMessage'"
        }
    }
    Write-Host "PASS negative: $Name"
}

function Copy-Map($Map){$copy=@{};foreach($key in $Map.Keys){$copy[$key]=$Map[$key]};return $copy}

function Write-RawJsonPayload {
    param([string]$Path,[string]$CaseId,[string]$Outcome='PASS',[string]$EvidenceClass='Synthetic',[string]$ObservedUtc='2026-08-22T12:00:00.0000000+00:00',[hashtable]$Extra=@{})
    $payload=[pscustomobject][ordered]@{
        schemaVersion=1
        caseId=$CaseId
        observedUtc=$ObservedUtc
        evidenceClass=$EvidenceClass
        outcome=$Outcome
        details="raw observation payload for $CaseId"
    }
    if($EvidenceClass-ceq'Runtime'){
        $payload | Add-Member -NotePropertyName actualHerdrObserved -NotePropertyValue $true
        $payload | Add-Member -NotePropertyName sessionKind -NotePropertyValue 'LocalConsole'
        $payload | Add-Member -NotePropertyName elevated -NotePropertyValue $false
        $payload | Add-Member -NotePropertyName userScope -NotePropertyValue 'SingleUser'
    }
    foreach($k in $Extra.Keys){
        if($payload.PSObject.Properties.Name -ccontains $k){
            $payload.$k = $Extra[$k]
        }else{
            $payload | Add-Member -NotePropertyName $k -NotePropertyValue $Extra[$k]
        }
    }
    $repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $parent=[IO.Path]::GetDirectoryName($Path)
    if(-not[IO.Directory]::Exists($parent)){[IO.Directory]::CreateDirectory($parent)|Out-Null}
    Write-RendererPackageCanonicalJson -Value $payload -Path $Path -RepositoryRoot $repoRoot
}

try{
    New-Item -Path $tempBase -ItemType Directory|Out-Null
    $evidenceRoot=Join-Path $tempBase 'evidence';$rawRoot=Join-Path $evidenceRoot 'raw';New-Item -Path $rawRoot -ItemType Directory -Force|Out-Null
    $outcomes=@{};$rawPaths=@{};$rawUtcs=@{}
    for($i=0;$i-lt$cases.Count;$i++){
        $case=$cases[$i]
        $outcomes[$case]='PASS'
        $relative="raw/$case.json"
        $rawPaths[$case]=$relative
        $caseUtc=('2026-08-22T12:00:{0:00}.0000000+00:00' -f $i)
        $rawUtcs[$case]=$caseUtc
        $fullPath=Join-Path $evidenceRoot $relative
        Write-RawJsonPayload -Path $fullPath -CaseId $case -Outcome 'PASS' -EvidenceClass 'Synthetic' -ObservedUtc $caseUtc
    }
    $batchUtc='2026-08-22T12:00:30.0000000+00:00'
    $common=@{
        OperatorIdentity='@operator';OperatorRole='EvidenceOperator'
        ObserverIdentity='@observer';ObserverRole='IndependentObserver'
        EvidenceBoundary='Synthetic';Outcomes=$outcomes;RawEvidencePaths=$rawPaths
        ObservedUtc=$batchUtc
        EvidenceRoot=$evidenceRoot;RepositoryRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    }

    # 1. Positive: synthetic 25-set with ordered UTC chronology and exact receipt order
    $destination=Join-Path $evidenceRoot 'receipts';$files=@(&$scriptPath -DestinationPath $destination @common)
    if($files.Count-ne25){throw "Expected exactly 25 published receipts; observed $($files.Count)."}
    for($i=0;$i-lt$cases.Count;$i++){
        $case=$cases[$i]
        $expectedReceiptPath=Join-Path $destination "matrix-evidence-$case.json"
        if($files[$i]-cne$expectedReceiptPath){
            throw "Receipt order mismatch at index $i. Expected '$expectedReceiptPath', observed '$($files[$i])'."
        }
        $value=Get-Content -LiteralPath $files[$i] -Raw|ConvertFrom-Json
        if($value.caseId-cne$case){throw "Receipt caseId mismatch at index $i."}
        if($value.observedUtc-cne$rawUtcs[$case]){
            throw "Receipt observedUtc was not bound to raw payload for '$case'. Expected '$($rawUtcs[$case])', observed '$($value.observedUtc)'."
        }
        if($value.outcome-cne'PASS'-or$value.operator.role-cne'EvidenceOperator'-or$value.observer.role-cne'IndependentObserver'-or$value.evidenceBoundary.evidenceClass-cne'Synthetic'-or$value.evidenceBoundary.finalHumanGo-cne'NOT_OBSERVED'-or$value.evidenceBoundary.release-cne'NOT_OBSERVED'-or[bool]$value.evidenceBoundary.creditGranted){
            throw 'Published receipt inflated authority or omitted role/outcome.'
        }
        Assert-RendererFileBinding $value.rawEvidence 'Published raw evidence' $evidenceRoot -ValidateBindings
    }
    Write-Host 'PASS positive: exact atomic 25-set with held raw bindings and bound ordered UTC chronology'

    # 2. Positive: earned Runtime 25-set
    $runtimeRoot=Join-Path $tempBase 'runtime-evidence';$runtimeRawRoot=Join-Path $runtimeRoot 'raw';New-Item -Path $runtimeRawRoot -ItemType Directory -Force|Out-Null
    $runtimeRawPaths=@{}
    for($i=0;$i-lt$cases.Count;$i++){
        $case=$cases[$i]
        $relative="raw/$case.json"
        $runtimeRawPaths[$case]=$relative
        $caseUtc=('2026-08-22T12:00:{0:00}.0000000+00:00' -f $i)
        $fullPath=Join-Path $runtimeRoot $relative
        Write-RawJsonPayload -Path $fullPath -CaseId $case -Outcome 'PASS' -EvidenceClass 'Runtime' -ObservedUtc $caseUtc
    }
    $runtimeCommon=@{
        OperatorIdentity='@operator';OperatorRole='EvidenceOperator'
        ObserverIdentity='@observer';ObserverRole='IndependentObserver'
        EvidenceBoundary='Runtime';RawEvidencePaths=$runtimeRawPaths
        ObservedUtc=$batchUtc
        EvidenceRoot=$runtimeRoot;RepositoryRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    }
    $runtimeDestination=Join-Path $runtimeRoot 'receipts';$runtimeFiles=@(&$scriptPath -DestinationPath $runtimeDestination @runtimeCommon)
    if($runtimeFiles.Count-ne25){throw "Expected exactly 25 published runtime receipts; observed $($runtimeFiles.Count)."}
    for($i=0;$i-lt$cases.Count;$i++){
        $case=$cases[$i]
        $value=Get-Content -LiteralPath $runtimeFiles[$i] -Raw|ConvertFrom-Json
        if($value.evidenceBoundary.evidenceClass-cne'Runtime'){throw 'Expected Runtime evidenceClass in receipt.'}
        Assert-RendererFileBinding $value.rawEvidence 'Published runtime raw evidence' $runtimeRoot -ValidateBindings
    }
    Write-Host 'PASS positive: exact atomic 25-set with held raw bindings (Earned Runtime)'

    # 3. Positive: auto-derived outcomes & evidence boundary (no caller Outcomes or EvidenceBoundary)
    $autoRoot=Join-Path $tempBase 'auto-evidence';$autoRawRoot=Join-Path $autoRoot 'raw';New-Item -Path $autoRawRoot -ItemType Directory -Force|Out-Null
    $autoRawPaths=@{}
    for($i=0;$i-lt$cases.Count;$i++){
        $case=$cases[$i]
        $relative="raw/$case.json"
        $autoRawPaths[$case]=$relative
        $caseUtc=('2026-08-22T12:00:{0:00}.0000000+00:00' -f $i)
        $fullPath=Join-Path $autoRoot $relative
        Write-RawJsonPayload -Path $fullPath -CaseId $case -Outcome 'PASS' -EvidenceClass 'Synthetic' -ObservedUtc $caseUtc
    }
    $autoCommon=@{
        OperatorIdentity='@operator';OperatorRole='EvidenceOperator'
        ObserverIdentity='@observer';ObserverRole='IndependentObserver'
        RawEvidencePaths=$autoRawPaths
        ObservedUtc=$batchUtc
        EvidenceRoot=$autoRoot;RepositoryRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    }
    $autoDestination=Join-Path $autoRoot 'receipts';$autoFiles=@(&$scriptPath -DestinationPath $autoDestination @autoCommon)
    if($autoFiles.Count-ne25){throw "Expected exactly 25 auto-derived published receipts; observed $($autoFiles.Count)."}
    Write-Host 'PASS positive: auto-derived outcomes and evidence boundary without caller dictation'

    # Hostile / Negative tests with exact guard message assertions
    Expect-Failure 'pre-existing destination no-clobber' { &$scriptPath -DestinationPath $destination @common } 'already exists; receipt publication is no-clobber'
    $crashDestination=Join-Path $evidenceRoot 'crash';Expect-Failure 'pre-publication crash rollback' { &$scriptPath -DestinationPath $crashDestination @common -SimulateFailureAfterReceiptCount 12 } 'Simulated pre-publication interruption'
    if(Test-Path -LiteralPath $crashDestination){throw 'Crash simulation published a partial destination.'}
    if(@(Get-ChildItem -LiteralPath $evidenceRoot -Directory -Filter '.matrix-receipts-staging-*').Count-ne0){throw 'Crash simulation left a staging directory.'}

    # Real child-process termination recovery: test that an orphaned staging directory from an abruptly terminated child process is recovered
    $childRecoveryRoot=Join-Path $tempBase 'child-recovery';$childRawRoot=Join-Path $childRecoveryRoot 'raw';New-Item -Path $childRawRoot -ItemType Directory -Force|Out-Null
    $childRawPaths=@{}
    foreach($case in $cases){
        $relative="raw/$case.json"
        $childRawPaths[$case]=$relative
        Write-RawJsonPayload -Path (Join-Path $childRecoveryRoot $relative) -CaseId $case -Outcome 'PASS' -EvidenceClass 'Synthetic'
    }
    $childCommon=@{
        OperatorIdentity='@operator';OperatorRole='EvidenceOperator';ObserverIdentity='@observer';ObserverRole='IndependentObserver'
        EvidenceBoundary='Synthetic';RawEvidencePaths=$childRawPaths;ObservedUtc=$batchUtc
        EvidenceRoot=$childRecoveryRoot;RepositoryRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    }
    $childDestination=Join-Path $childRecoveryRoot 'receipts'
    # Create an orphaned staging directory simulating killed child process
    $orphanedStaging=Join-Path $childRecoveryRoot '.matrix-receipts-staging-abruptchildproc'
    New-Item -Path $orphanedStaging -ItemType Directory -Force|Out-Null
    [IO.File]::WriteAllText((Join-Path $orphanedStaging 'partial.json'),'{"partial":true}')
    # Now run generator, which must sweep orphaned staging directory and complete publication
    $recoveredFiles=@(&$scriptPath -DestinationPath $childDestination @childCommon)
    if($recoveredFiles.Count-ne25){throw 'Recovery run failed to publish 25 receipts.'}
    if(Test-Path -LiteralPath $orphanedStaging){throw 'Owned transaction recovery failed to clean orphaned staging directory.'}
    Write-Host 'PASS positive: owned transaction/staging recovery from abrupt child process termination'

    # Case ID completeness and correctness
    $bad=Copy-Map $rawPaths;$bad.Remove($cases[0]);$hostile=Copy-Map $common;$hostile.RawEvidencePaths=$bad;Expect-Failure 'missing governed case ID' { &$scriptPath -DestinationPath (Join-Path $evidenceRoot 'missing-id') @hostile } 'must contain exactly the 25 governed case IDs'
    $bad=Copy-Map $rawPaths;$bad.Remove('soak-ac-60-minutes');$hostile=Copy-Map $common;$hostile.RawEvidencePaths=$bad;Expect-Failure 'missing environment case ID' { &$scriptPath -DestinationPath (Join-Path $evidenceRoot 'missing-env-id') @hostile } 'must contain exactly the 25 governed case IDs'
    $bad=Copy-Map $rawPaths;$bad.Remove($cases[0]);$bad['WRONG-ID']="raw/$($cases[0]).json";$hostile=Copy-Map $common;$hostile.RawEvidencePaths=$bad;Expect-Failure 'wrong governed case ID' { &$scriptPath -DestinationPath (Join-Path $evidenceRoot 'wrong-id') @hostile } "omitted exact case ID '$($cases[0])'"

    # Case-insensitive identity collision
    $hostile=Copy-Map $common;$hostile.ObserverIdentity='@OPERATOR';Expect-Failure 'case-insensitive operator observer identity collision' { &$scriptPath -DestinationPath (Join-Path $evidenceRoot 'same-id-case') @hostile } 'OperatorIdentity and ObserverIdentity must be distinct'

    # Synchronized forged PASS rejection
    $forgedRoot=Join-Path $tempBase 'forged-evidence';$forgedRawRoot=Join-Path $forgedRoot 'raw';New-Item -Path $forgedRawRoot -ItemType Directory -Force|Out-Null
    $forgedRawPaths=@{}
    foreach($case in $cases){
        $relative="raw/$case.json"
        $forgedRawPaths[$case]=$relative
        $outcomeVal=if($case-ceq$cases[0]){'FAIL'}else{'PASS'}
        Write-RawJsonPayload -Path (Join-Path $forgedRoot $relative) -CaseId $case -Outcome $outcomeVal -EvidenceClass 'Synthetic'
    }
    $forgedCommon=Copy-Map $common;$forgedCommon.EvidenceRoot=$forgedRoot;$forgedCommon.RawEvidencePaths=$forgedRawPaths;$forgedCommon.Outcomes=$outcomes
    Expect-Failure 'synchronized forged PASS (caller claims PASS for FAIL raw evidence)' { &$scriptPath -DestinationPath (Join-Path $forgedRoot 'receipts') @forgedCommon } "Synchronized forged PASS detected for case '$($cases[0])'"

    # Forged PASS inside raw payload (checksPassed = false but outcome = PASS)
    $payloadForgedRoot=Join-Path $tempBase 'payload-forged';$payloadForgedRawRoot=Join-Path $payloadForgedRoot 'raw';New-Item -Path $payloadForgedRawRoot -ItemType Directory -Force|Out-Null
    $payloadForgedRawPaths=@{}
    foreach($case in $cases){
        $relative="raw/$case.json"
        $payloadForgedRawPaths[$case]=$relative
        $extra=if($case-ceq$cases[0]){@{checksPassed=$false}}else{@{}}
        Write-RawJsonPayload -Path (Join-Path $payloadForgedRoot $relative) -CaseId $case -Outcome 'PASS' -EvidenceClass 'Synthetic' -Extra $extra
    }
    $payloadForgedCommon=Copy-Map $common;$payloadForgedCommon.EvidenceRoot=$payloadForgedRoot;$payloadForgedCommon.RawEvidencePaths=$payloadForgedRawPaths
    Expect-Failure 'forged PASS in payload (checksPassed=false)' { &$scriptPath -DestinationPath (Join-Path $payloadForgedRoot 'receipts') @payloadForgedCommon } 'forged PASS: outcome is PASS but checksPassed is false'

    # Forged PASS inside raw payload (errorCount > 0 but outcome = PASS)
    $errorForgedRoot=Join-Path $tempBase 'error-forged';$errorForgedRawRoot=Join-Path $errorForgedRoot 'raw';New-Item -Path $errorForgedRoot -ItemType Directory -Force|Out-Null
    $errorForgedRawPaths=@{}
    foreach($case in $cases){
        $relative="raw/$case.json"
        $errorForgedRawPaths[$case]=$relative
        $extra=if($case-ceq$cases[0]){@{errorCount=2}}else{@{}}
        Write-RawJsonPayload -Path (Join-Path $errorForgedRoot $relative) -CaseId $case -Outcome 'PASS' -EvidenceClass 'Synthetic' -Extra $extra
    }
    $errorForgedCommon=Copy-Map $common;$errorForgedCommon.EvidenceRoot=$errorForgedRoot;$errorForgedCommon.RawEvidencePaths=$errorForgedRawPaths
    Expect-Failure 'forged PASS in payload (errorCount>0)' { &$scriptPath -DestinationPath (Join-Path $errorForgedRoot 'receipts') @errorForgedCommon } 'forged PASS: outcome is PASS but errorCount is nonzero'

    # Unearned Runtime rejection: caller claims Runtime for Synthetic evidence
    $unearnedCallerHostile=Copy-Map $common;$unearnedCallerHostile.EvidenceBoundary='Runtime'
    Expect-Failure 'unearned Runtime (caller claims Runtime on Synthetic raw payload)' { &$scriptPath -DestinationPath (Join-Path $evidenceRoot 'unearned-caller') @unearnedCallerHostile } "Evidence boundary mismatch for case '$($cases[0])'"

    # Unearned Runtime: raw payload claims Runtime but actualHerdrObserved is false
    $unearnedObsRoot=Join-Path $tempBase 'unearned-obs';$unearnedObsRawRoot=Join-Path $unearnedObsRoot 'raw';New-Item -Path $unearnedObsRawRoot -ItemType Directory -Force|Out-Null
    $unearnedObsRawPaths=@{}
    foreach($case in $cases){
        $relative="raw/$case.json"
        $unearnedObsRawPaths[$case]=$relative
        $extra=if($case-ceq$cases[0]){@{actualHerdrObserved=$false}}else{@{}}
        Write-RawJsonPayload -Path (Join-Path $unearnedObsRoot $relative) -CaseId $case -Outcome 'PASS' -EvidenceClass 'Runtime' -Extra $extra
    }
    $unearnedObsCommon=Copy-Map $runtimeCommon;$unearnedObsCommon.EvidenceRoot=$unearnedObsRoot;$unearnedObsCommon.RawEvidencePaths=$unearnedObsRawPaths
    Expect-Failure 'unearned Runtime (actualHerdrObserved=false)' { &$scriptPath -DestinationPath (Join-Path $unearnedObsRoot 'receipts') @unearnedObsCommon } 'claims unearned Runtime: actualHerdrObserved is false'

    # Unearned Runtime: raw payload claims Runtime but sessionKind is Rdp
    $unearnedRdpRoot=Join-Path $tempBase 'unearned-rdp';$unearnedRdpRawRoot=Join-Path $unearnedRdpRoot 'raw';New-Item -Path $unearnedRdpRawRoot -ItemType Directory -Force|Out-Null
    $unearnedRdpRawPaths=@{}
    foreach($case in $cases){
        $relative="raw/$case.json"
        $unearnedRdpRawPaths[$case]=$relative
        $extra=if($case-ceq$cases[0]){@{sessionKind='Rdp'}}else{@{}}
        Write-RawJsonPayload -Path (Join-Path $unearnedRdpRoot $relative) -CaseId $case -Outcome 'PASS' -EvidenceClass 'Runtime' -Extra $extra
    }
    $unearnedRdpCommon=Copy-Map $runtimeCommon;$unearnedRdpCommon.EvidenceRoot=$unearnedRdpRoot;$unearnedRdpCommon.RawEvidencePaths=$unearnedRdpRawPaths
    Expect-Failure 'unearned Runtime (sessionKind=Rdp)' { &$scriptPath -DestinationPath (Join-Path $unearnedRdpRoot 'receipts') @unearnedRdpCommon } "claims unearned Runtime: sessionKind 'Rdp' is not LocalConsole"

    # Unearned Runtime: raw payload claims Runtime but elevated is true
    $unearnedElevRoot=Join-Path $tempBase 'unearned-elev';$unearnedElevRawRoot=Join-Path $unearnedElevRoot 'raw';New-Item -Path $unearnedElevRawRoot -ItemType Directory -Force|Out-Null
    $unearnedElevRawPaths=@{}
    foreach($case in $cases){
        $relative="raw/$case.json"
        $unearnedElevRawPaths[$case]=$relative
        $extra=if($case-ceq$cases[0]){@{elevated=$true}}else{@{}}
        Write-RawJsonPayload -Path (Join-Path $unearnedElevRoot $relative) -CaseId $case -Outcome 'PASS' -EvidenceClass 'Runtime' -Extra $extra
    }
    $unearnedElevCommon=Copy-Map $runtimeCommon;$unearnedElevCommon.EvidenceRoot=$unearnedElevRoot;$unearnedElevCommon.RawEvidencePaths=$unearnedElevRawPaths
    Expect-Failure 'unearned Runtime (elevated=true)' { &$scriptPath -DestinationPath (Join-Path $unearnedElevRoot 'receipts') @unearnedElevCommon } 'claims unearned Runtime: session is elevated'

    # Unearned Runtime: raw payload claims Runtime but is marked isSynthetic=true
    $unearnedSynthRoot=Join-Path $tempBase 'unearned-synth';$unearnedSynthRawRoot=Join-Path $unearnedSynthRoot 'raw';New-Item -Path $unearnedSynthRawRoot -ItemType Directory -Force|Out-Null
    $unearnedSynthRawPaths=@{}
    foreach($case in $cases){
        $relative="raw/$case.json"
        $unearnedSynthRawPaths[$case]=$relative
        $extra=if($case-ceq$cases[0]){@{isSynthetic=$true}}else{@{}}
        Write-RawJsonPayload -Path (Join-Path $unearnedSynthRoot $relative) -CaseId $case -Outcome 'PASS' -EvidenceClass 'Runtime' -Extra $extra
    }
    $unearnedSynthCommon=Copy-Map $runtimeCommon;$unearnedSynthCommon.EvidenceRoot=$unearnedSynthRoot;$unearnedSynthCommon.RawEvidencePaths=$unearnedSynthRawPaths
    Expect-Failure 'unearned Runtime (isSynthetic=true)' { &$scriptPath -DestinationPath (Join-Path $unearnedSynthRoot 'receipts') @unearnedSynthCommon } 'claims unearned Runtime: isSynthetic is true'

    # Case ID mismatch inside raw payload
    $mismatchRoot=Join-Path $tempBase 'mismatch-root';$mismatchRawRoot=Join-Path $mismatchRoot 'raw';New-Item -Path $mismatchRawRoot -ItemType Directory -Force|Out-Null
    $mismatchRawPaths=@{}
    foreach($case in $cases){
        $relative="raw/$case.json"
        $mismatchRawPaths[$case]=$relative
        $containedCase=if($case-ceq$cases[0]){$cases[1]}else{$case}
        Write-RawJsonPayload -Path (Join-Path $mismatchRoot $relative) -CaseId $containedCase -Outcome 'PASS' -EvidenceClass 'Synthetic'
    }
    $mismatchCommon=Copy-Map $common;$mismatchCommon.EvidenceRoot=$mismatchRoot;$mismatchCommon.RawEvidencePaths=$mismatchRawPaths
    Expect-Failure 'raw payload caseId mismatch' { &$scriptPath -DestinationPath (Join-Path $mismatchRoot 'receipts') @mismatchCommon } 'does not match expected caseId'

    # ObservedUtc after batch window
    $lateRoot=Join-Path $tempBase 'late-utc-root';$lateRawRoot=Join-Path $lateRoot 'raw';New-Item -Path $lateRawRoot -ItemType Directory -Force|Out-Null
    $lateRawPaths=@{}
    foreach($case in $cases){
        $relative="raw/$case.json"
        $lateRawPaths[$case]=$relative
        $lateUtc=if($case-ceq$cases[0]){'2026-08-22T13:00:00.0000000+00:00'}else{'2026-08-22T12:00:00.0000000+00:00'}
        Write-RawJsonPayload -Path (Join-Path $lateRoot $relative) -CaseId $case -Outcome 'PASS' -EvidenceClass 'Synthetic' -ObservedUtc $lateUtc
    }
    $lateCommon=Copy-Map $common;$lateCommon.EvidenceRoot=$lateRoot;$lateCommon.RawEvidencePaths=$lateRawPaths
    Expect-Failure 'raw evidence observedUtc after caller batch window' { &$scriptPath -DestinationPath (Join-Path $lateRoot 'receipts') @lateCommon } 'is after caller batch window'

    # Release evidence boundary inflation
    $hostile=Copy-Map $common;$hostile.EvidenceBoundary='Release';Expect-Failure 'Release evidence inflation' { &$scriptPath -DestinationPath (Join-Path $evidenceRoot 'release') @hostile }

    # Caller UTC format
    $hostile=Copy-Map $common;$hostile.ObservedUtc='2026-08-22T12:00:00Z';Expect-Failure 'noncanonical caller UTC' { &$scriptPath -DestinationPath (Join-Path $evidenceRoot 'utc') @hostile } 'ObservedUtc must be canonical round-trip UTC with zero offset'

    # Traversal and missing files
    $bad=Copy-Map $rawPaths;$bad[$cases[0]]='../escape.json';$hostile=Copy-Map $common;$hostile.RawEvidencePaths=$bad;Expect-Failure 'raw traversal path' { &$scriptPath -DestinationPath (Join-Path $evidenceRoot 'traversal') @hostile } 'must be a contained relative path'
    $bad=Copy-Map $rawPaths;$bad[$cases[0]]='raw/missing.json';$hostile=Copy-Map $common;$hostile.RawEvidencePaths=$bad;Expect-Failure 'missing raw evidence' { &$scriptPath -DestinationPath (Join-Path $evidenceRoot 'missing-raw') @hostile } 'is missing'
    Expect-Failure 'destination path escape' { &$scriptPath -DestinationPath (Join-Path $tempBase 'outside') @common } 'escaped the evidence root'

    # Tampering tests
    $tamperedReceipt=Get-Content -LiteralPath $files[0] -Raw|ConvertFrom-Json;$tamperedReceipt.rawEvidence.sha256='A'*64
    Expect-Failure 'consumer rejects tampered raw hash' { Assert-RendererFileBinding $tamperedReceipt.rawEvidence 'Tampered raw evidence' $evidenceRoot -ValidateBindings } 'SHA-256 mismatch'
    [IO.File]::AppendAllText((Join-Path $evidenceRoot $rawPaths[$cases[1]]),'tamper');$tamperedBytesFile=@($files|Where-Object{(Get-Content -LiteralPath $_ -Raw|ConvertFrom-Json).caseId-ceq$cases[1]})[0];$tamperedBytesReceipt=Get-Content -LiteralPath $tamperedBytesFile -Raw|ConvertFrom-Json
    Expect-Failure 'consumer rejects changed raw bytes' { Assert-RendererFileBinding $tamperedBytesReceipt.rawEvidence 'Changed raw evidence' $evidenceRoot -ValidateBindings } 'byte count mismatch'

    # Reparse point / directory containment protection (using Junction which works without privileges on Windows PS5.1 and PS7)
    $linkRoot=Join-Path $evidenceRoot 'link-hostile';New-Item -Path $linkRoot -ItemType Directory|Out-Null;$link=Join-Path $linkRoot 'raw-link';$junctionCreated=$false
    try{New-Item -ItemType Junction -Path $link -Target $rawRoot -ErrorAction Stop|Out-Null;$junctionCreated=$true}catch{
        $cmdOutput=& cmd /c "mklink /J `"$link`" `"$rawRoot`"" 2>&1
        if($LASTEXITCODE-eq 0){$junctionCreated=$true}
        $global:LASTEXITCODE=0
    }
    if(-not$junctionCreated){throw 'Failed to create directory junction for containment hostile test.'}
    $bad=Copy-Map $rawPaths;$bad[$cases[0]]='link-hostile/raw-link/'+$cases[0]+'.json';$hostile=Copy-Map $common;$hostile.RawEvidencePaths=$bad
    Expect-Failure 'raw reparse point' { &$scriptPath -DestinationPath (Join-Path $evidenceRoot 'reparse') @hostile } 'contains a reparse point'

    Write-Host "All 25 matrix receipt tests passed for PowerShell $($PSVersionTable.PSVersion)."
}finally{if(Test-Path -LiteralPath $tempBase){Remove-Item -LiteralPath $tempBase -Recurse -Force}}

