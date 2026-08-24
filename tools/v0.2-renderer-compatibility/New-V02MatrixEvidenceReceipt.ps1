#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$DestinationPath,
    [Parameter(Mandatory=$true)][string]$OperatorIdentity,
    [Parameter(Mandatory=$true)][ValidateSet('EvidenceOperator')][string]$OperatorRole,
    [Parameter(Mandatory=$true)][Alias('ReviewerIdentity')][string]$ObserverIdentity,
    [Parameter(Mandatory=$true)][ValidateSet('IndependentAgentReviewer')][string]$ObserverRole,
    [Parameter(Mandatory=$false)][ValidateSet('Static','Synthetic','Contract','AutomatedPackagedRendering')][string]$EvidenceBoundary,
    [Parameter(Mandatory=$false)][hashtable]$Outcomes,
    [Parameter(Mandatory=$true)][hashtable]$RawEvidencePaths,
    [Parameter(Mandatory=$false)][string]$EvidenceRoot,
    [Parameter(Mandatory=$false)][string]$RepositoryRoot,
    [Parameter(DontShow=$true)][ValidateRange(0,14)][int]$SimulateFailureAfterReceiptCount = 0,
    [Parameter(DontShow=$true)][ValidateRange(0,120000)][int]$PauseAfterStagingReadyMilliseconds = 0,
    [Parameter(DontShow=$true)][ValidateRange(0,120000)][int]$PauseAfterRecoveryIdentityVerifiedMilliseconds = 0,
    [Parameter(DontShow=$true)][ValidateRange(0,120000)][int]$PauseAfterCleanupIdentityVerifiedMilliseconds = 0,
    [Parameter(DontShow=$true)][ValidateRange(0,120000)][int]$PauseAfterPublicationIdentityVerifiedMilliseconds = 0
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'RendererCompatibility.Common.ps1')

function Test-MatrixReceiptOwnerActive {
    param([int]$ProcessId,[string]$ProcessStartUtc)
    $owner=Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if($null-eq$owner){return $false}
    try{return $owner.StartTime.ToUniversalTime().ToString('O')-ceq$ProcessStartUtc}catch{return $false}
}
function Remove-OwnedStaleMatrixStaging {
    param([string]$Path,[string]$Destination,[string]$Root,[string]$Repository,[DateTimeOffset]$NowUtc,[int]$PauseBeforeDeleteMilliseconds)
    $name=[IO.Path]::GetFileName($Path)
    if($name-cnotmatch'^\.matrix-receipts-staging-([0-9a-f]{32})$'){return}
    $expectedTransactionId=[string]$Matches[1]
    Assert-RendererNonReparsePath $Root $Path 'Recovery staging directory'
    $lease=$null
    try{$lease=Open-RendererDirectoryLease $Root $Path 'Recovery staging directory' -AllowDelete}catch{return}
    try{
        $markerPath=Join-Path $Path '.owner.json'
        if(-not(Test-Path -LiteralPath $markerPath -PathType Leaf)){throw "Refusing to recover staging '$name' without an owned marker."}
        $markerIdentity=Get-RendererStableFileIdentity $Root $markerPath 'Recovery owner marker' -IncludeBytes
        $json=(New-Object Text.UTF8Encoding($false,$true)).GetString($markerIdentity.Content)
        $marker=ConvertFrom-StrictHumanDesignReviewJson -Json $json -Description 'Recovery owner marker'
        if($PSVersionTable.PSVersion.Major-ge7-and(Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')){$marker=$json|ConvertFrom-Json -DateKind String}
        Assert-RendererExactProperties $marker @('schemaVersion','transactionId','ownerPid','ownerProcessStartUtc','createdUtc','destinationPath','directoryIdentity') 'Recovery owner marker'
        Assert-RendererNonnegativeInteger $marker.schemaVersion 'Recovery marker schemaVersion';if([long]$marker.schemaVersion-ne1){throw 'Recovery marker schemaVersion must be 1.'}
        if($marker.destinationPath-cne$Destination){return}
        if($marker.transactionId-cne$expectedTransactionId-or$marker.directoryIdentity-cne$lease.Identity){throw 'Recovery marker is not bound to this transaction/directory identity.'}
        Assert-RendererPositiveInteger $marker.ownerPid 'Recovery marker ownerPid';Assert-RendererUtc $marker.ownerProcessStartUtc 'Recovery marker ownerProcessStartUtc';Assert-RendererUtc $marker.createdUtc 'Recovery marker createdUtc'
        $age=$NowUtc-[DateTimeOffset]::Parse($marker.createdUtc);if($age.TotalSeconds-lt2){return}
        if(Test-MatrixReceiptOwnerActive ([int]$marker.ownerPid) ([string]$marker.ownerProcessStartUtc)){return}
        Assert-RendererDirectoryLease $lease $Root $Path 'Recovery staging directory before delete'
        if($PauseBeforeDeleteMilliseconds-gt0){[IO.File]::WriteAllText((Join-Path $Root '.recovery-identity-verified'),'ready',(New-Object Text.UTF8Encoding($false)));Start-Sleep -Milliseconds $PauseBeforeDeleteMilliseconds}
        Remove-RendererLeasedDirectory $lease $Root $Path 'Recovery staging directory'
    }finally{$lease.Handle.Dispose()}
    if(Test-Path -LiteralPath $Path){throw 'Recovery staging directory remained after held-handle owned deletion.'}
}

function Open-MatrixReceiptReplayRegistry {
    param([string]$Root,[string]$Repository)
    $registryPath=Join-Path $Root '.matrix-receipt-replay-registry'
    $registryLease=$null
    if(-not(Test-Path -LiteralPath $registryPath)){
        $stagingPath=Join-Path $Root ('.matrix-replay-registry-staging-'+[guid]::NewGuid().ToString('N'))
        $stagingLease=$null
        $moved=$false
        try{
            New-Item -Path $stagingPath -ItemType Directory -ErrorAction Stop|Out-Null
            $stagingLease=Open-RendererDirectoryLease $Root $stagingPath 'Replay registry staging directory' -AllowDelete
            $marker=[pscustomobject][ordered]@{schemaVersion=1;registryId='HerdrOpsMatrixReceiptReplayRegistryV1'}
            Write-RendererPackageCanonicalJson -Value $marker -Path (Join-Path $stagingPath '.registry.json') -RepositoryRoot $Repository
            Assert-RendererDirectoryLease $stagingLease $Root $stagingPath 'Replay registry staging directory before publication'
            try{Move-RendererLeasedDirectory $stagingLease $Root $stagingPath $registryPath 'Replay registry publication';$moved=$true}catch{
                if(-not(Test-Path -LiteralPath $registryPath)){throw}
            }
            if($moved){$registryLease=$stagingLease;$stagingLease=$null}
        }finally{
            if($null-ne$stagingLease){
                try{if(Test-Path -LiteralPath $stagingPath){Remove-RendererLeasedDirectory $stagingLease $Root $stagingPath 'Losing replay registry initialization'}}finally{$stagingLease.Handle.Dispose()}
            }
        }
    }
    if($null-eq$registryLease){$registryLease=Open-RendererDirectoryLease $Root $registryPath 'Replay registry directory'}
    $markerLease=$null
    try{
        Assert-RendererDirectoryLease $registryLease $Root $registryPath 'Replay registry directory'
        $markerPath=Join-Path $registryPath '.registry.json'
        if(-not(Test-Path -LiteralPath $markerPath -PathType Leaf)){throw 'Replay registry is missing its fixed marker.'}
        $markerLease=Get-RendererStableFileIdentity $Root $markerPath 'Replay registry marker' -IncludeBytes -KeepOpen
        if($markerLease.LinkCount-ne1){throw 'Replay registry marker must have link count exactly 1.'}
        $json=(New-Object Text.UTF8Encoding($false,$true)).GetString($markerLease.Content)
        $marker=ConvertFrom-StrictHumanDesignReviewJson -Json $json -Description 'Replay registry marker'
        if($PSVersionTable.PSVersion.Major-ge7-and(Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')){$marker=$json|ConvertFrom-Json -DateKind String}
        Assert-RendererExactProperties $marker @('schemaVersion','registryId') 'Replay registry marker'
        if([long]$marker.schemaVersion-ne1-or$marker.registryId-cne'HerdrOpsMatrixReceiptReplayRegistryV1'){throw 'Replay registry marker identity is invalid.'}
        return [pscustomobject]@{Path=$registryPath;Lease=$registryLease;MarkerLease=$markerLease}
    }catch{
        if($null-ne$markerLease-and$null-ne$markerLease.Stream){$markerLease.Stream.Dispose()}
        $registryLease.Handle.Dispose()
        throw
    }
}

function New-MatrixReceiptReplayClaim {
    param($Registry,[string]$Root,[string]$Repository,[string]$TupleSha256,$Record)
    Assert-RendererDirectoryLease $Registry.Lease $Root $Registry.Path 'Replay registry before tuple reservation'
    Assert-RendererStableFileLease $Registry.MarkerLease $Root (Join-Path $Registry.Path '.registry.json') 'Replay registry marker before tuple reservation'
    $entryPath=Join-Path $Registry.Path ('.publication-'+$TupleSha256.ToLowerInvariant())
    if(Test-Path -LiteralPath $entryPath){throw "Replay registry already contains exact matrix publication tuple '$TupleSha256'."}
    $stagingPath=Join-Path $Registry.Path ('.claim-staging-'+[guid]::NewGuid().ToString('N'))
    $lease=$null;$committed=$false
    try{
        New-Item -Path $stagingPath -ItemType Directory -ErrorAction Stop|Out-Null
        $lease=Open-RendererDirectoryLease $Root $stagingPath 'Replay claim staging directory' -AllowDelete
        Write-RendererPackageCanonicalJson -Value $Record -Path (Join-Path $stagingPath 'publication.json') -RepositoryRoot $Repository
        Assert-RendererDirectoryLease $Registry.Lease $Root $Registry.Path 'Replay registry before atomic tuple reservation'
        Assert-RendererStableFileLease $Registry.MarkerLease $Root (Join-Path $Registry.Path '.registry.json') 'Replay registry marker before atomic tuple reservation'
        Assert-RendererDirectoryLease $lease $Root $stagingPath 'Replay claim before atomic tuple reservation'
        try{Move-RendererLeasedDirectory $lease $Root $stagingPath $entryPath 'Replay tuple reservation';$committed=$true}catch{
            if(Test-Path -LiteralPath $entryPath){throw "Replay registry already contains exact matrix publication tuple '$TupleSha256'."}
            throw
        }
        return [pscustomobject]@{Path=$entryPath;Lease=$lease;TupleSha256=$TupleSha256}
    }finally{
        if(-not$committed-and$null-ne$lease){
            try{if(Test-Path -LiteralPath $stagingPath){Remove-RendererLeasedDirectory $lease $Root $stagingPath 'Failed replay tuple reservation'}}finally{$lease.Handle.Dispose()}
        }
    }
}

$cases = @(Get-RendererGovernedMatrixCases)
if ($cases.Count -ne 14) { throw "Governed automated matrix case count must be exactly 14; observed $($cases.Count)." }

Assert-RendererString $OperatorIdentity 'OperatorIdentity'
Assert-RendererString $ObserverIdentity 'ObserverIdentity'
if ($OperatorIdentity.Trim().Equals($ObserverIdentity.Trim(), [StringComparison]::OrdinalIgnoreCase)) { throw 'OperatorIdentity and ObserverIdentity must be distinct.' }
$publicationUtc = [DateTimeOffset]::UtcNow

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) { $RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path }
$repositoryFull = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd('\','/')
if (-not (Test-Path -LiteralPath $repositoryFull -PathType Container)) { throw 'RepositoryRoot must be an existing directory.' }
Assert-RendererNonReparsePath $repositoryFull $repositoryFull 'RepositoryRoot'

$destinationFull = [IO.Path]::GetFullPath($DestinationPath).TrimEnd('\','/')
$destinationParent = [IO.Path]::GetDirectoryName($destinationFull)
if ([string]::IsNullOrWhiteSpace($EvidenceRoot)) { $EvidenceRoot = $destinationParent }
$evidenceRootFull = [IO.Path]::GetFullPath($EvidenceRoot).TrimEnd('\','/')
if (-not (Test-Path -LiteralPath $evidenceRootFull -PathType Container)) { throw 'EvidenceRoot must be an existing directory.' }
Assert-RendererNonReparsePath $evidenceRootFull $evidenceRootFull 'EvidenceRoot'
Assert-RendererNonReparsePath $evidenceRootFull $destinationParent 'Destination parent'
if ($destinationFull -cne $evidenceRootFull -and -not $destinationFull.StartsWith($evidenceRootFull + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw 'DestinationPath escaped EvidenceRoot.' }
$replayRegistryPath=Join-Path $evidenceRootFull '.matrix-receipt-replay-registry'
if($destinationFull-ceq$replayRegistryPath-or($destinationFull-cne$replayRegistryPath-and$destinationFull.StartsWith($replayRegistryPath+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase))){throw 'DestinationPath conflicts with the fixed replay registry.'}
if (Test-Path -LiteralPath $destinationFull) { throw 'DestinationPath already exists; receipt publication is no-clobber.' }

$parentLease=Open-RendererDirectoryLease $evidenceRootFull $destinationParent 'Destination parent lease'
$rawLeases=@{}
try {
    # Recover only authenticated, old transactions whose exact PID/start-time owner is dead.
    $staleStaging=@(Get-ChildItem -LiteralPath $destinationParent -Directory -Filter '.matrix-receipts-staging-*' -ErrorAction Stop)
    foreach($stale in $staleStaging){Remove-OwnedStaleMatrixStaging $stale.FullName $destinationFull $evidenceRootFull $repositoryFull ([DateTimeOffset]::UtcNow) $PauseAfterRecoveryIdentityVerifiedMilliseconds}

$rawKeys = @($RawEvidencePaths.Keys | ForEach-Object { [string]$_ })
if ($rawKeys.Count -ne $cases.Count) { throw "RawEvidencePaths must contain exactly the 14 governed case IDs; observed $($rawKeys.Count)." }
foreach ($case in $cases) {
    if (-not ($rawKeys -ccontains $case)) { throw "RawEvidencePaths omitted exact case ID '$case'." }
}

if ($null -ne $Outcomes) {
    $outcomeKeys = @($Outcomes.Keys | ForEach-Object { [string]$_ })
    if ($outcomeKeys.Count -ne $cases.Count) { throw "Outcomes must contain exactly the 14 governed case IDs; observed $($outcomeKeys.Count)." }
    foreach ($case in $cases) {
        if (-not ($outcomeKeys -ccontains $case)) { throw "Outcomes omitted exact case ID '$case'." }
        $callerOutcome = $Outcomes[$case]
        if ($callerOutcome -isnot [string] -or [string]$callerOutcome -cnotin @('PASS','FAIL')) {
            throw "Outcome for '$case' must be exact PASS or FAIL."
        }
    }
}

$rawIdentities = @{}
$derivedOutcomes = @{}
$derivedClasses = @{}
$derivedObservedUtcs = @{}
$seenRawFileIdentities = @{}
$previousRawUtc = $null
$commonRunFingerprint = $null
$commonRunEndedUtc = $null

foreach ($case in $cases) {
    $relativePath = $RawEvidencePaths[$case]
    Assert-RendererRelativePath $relativePath "Raw evidence '$case' relativePath"
    $rawFull = Resolve-RendererBoundPath $evidenceRootFull ([string]$relativePath) "Raw evidence '$case'"
    if (-not (Test-Path -LiteralPath $rawFull -PathType Leaf)) { throw "Raw evidence '$case' is missing." }
    $identity = Get-RendererStableFileIdentity $evidenceRootFull $rawFull "Raw evidence '$case'" -IncludeBytes -KeepOpen
    $rawLeases[$case]=$identity
    if ($identity.Bytes -le 0) { throw "Raw evidence '$case' must be nonempty." }
    if ($identity.LinkCount -ne 1) { throw "Raw evidence '$case' must have link count exactly 1; hardlinked raw evidence is prohibited." }
    if($seenRawFileIdentities.ContainsKey($identity.FileIdentity)){throw "Raw evidence '$case' is a hardlink/identity alias of '$($seenRawFileIdentities[$identity.FileIdentity])'."}
    $seenRawFileIdentities[$identity.FileIdentity]=$case

    $json = (New-Object Text.UTF8Encoding($false,$true)).GetString($identity.Content)
    $payload = ConvertFrom-StrictHumanDesignReviewJson -Json $json -Description "Raw evidence payload '$case'"
    if ($PSVersionTable.PSVersion.Major -ge 7 -and (Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) {
        $payload = $json | ConvertFrom-Json -DateKind String
    }

    $validated = Assert-RendererMatrixRawPayload -Payload $payload -ExpectedCaseId $case -Context "Raw evidence '$case'" -RepositoryRoot $repositoryFull -EvidenceRoot $evidenceRootFull
    if($validated.EvidenceClass-ceq'AutomatedPackagedRendering'-and($validated.OperatorIdentity-cne$OperatorIdentity-or$validated.ObserverIdentity-cne$ObserverIdentity)){throw "Raw evidence '$case' automated rendering identities do not equal the publication operator/independent Agent reviewer."}
    if($null-eq$commonRunFingerprint){$commonRunFingerprint=$validated.RunFingerprint}else{if($commonRunFingerprint-cne$validated.RunFingerprint){throw "Raw evidence '$case' does not share the exact common run/session/candidate/package identity."}}
    if($null-eq$commonRunEndedUtc){$commonRunEndedUtc=[DateTimeOffset]::Parse($validated.RunEndedUtc)}
    $runEnd=[DateTimeOffset]::Parse($validated.RunEndedUtc);if($runEnd-gt$publicationUtc-or($publicationUtc-$runEnd).TotalMinutes-gt5){throw "Raw evidence '$case' is outside the trusted current five-minute publication window."}

    $rawObsUtc = [DateTimeOffset]::Parse($validated.ObservedUtc)
    if ($rawObsUtc -gt $publicationUtc) {
        throw "Raw evidence '$case' observedUtc '$($validated.ObservedUtc)' is after the trusted publication time '$($publicationUtc.ToString('O'))'."
    }
    if($null-ne$previousRawUtc-and$rawObsUtc-le$previousRawUtc){throw "Raw evidence chronology must be strictly increasing and unique in governed case order; case '$case' is out of order."}
    $previousRawUtc=$rawObsUtc

    if ($null -ne $Outcomes) {
        $callerOutcome = [string]$Outcomes[$case]
        if ($callerOutcome -cne $validated.Outcome) {
            throw "Synchronized forged PASS detected for case '$case': caller claimed '$callerOutcome' but raw evidence derived '$($validated.Outcome)'."
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($EvidenceBoundary)) {
        if ($EvidenceBoundary -cne $validated.EvidenceClass) {
            throw "Evidence boundary mismatch for case '$case': caller claimed '$EvidenceBoundary' but raw evidence derived '$($validated.EvidenceClass)'."
        }
    }

    $derivedOutcomes[$case] = $validated.Outcome
    $derivedClasses[$case] = $validated.EvidenceClass
    $derivedObservedUtcs[$case] = $validated.ObservedUtc
    $rawIdentities[$case] = [pscustomobject][ordered]@{
        relativePath = ([string]$relativePath -replace '\\','/')
        bytes = [long]$identity.Bytes
        sha256 = [string]$identity.Sha256
    }
}

$stagingDirectory = Join-Path $destinationParent ('.matrix-receipts-staging-' + [guid]::NewGuid().ToString('N'))
$published = $false
$stagingLease = $null
$replayRegistry=$null
$replayClaim=$null
try {
    New-Item -Path $stagingDirectory -ItemType Directory -ErrorAction Stop | Out-Null
    $stagingLease=Open-RendererDirectoryLease $evidenceRootFull $stagingDirectory 'Staging directory lease' -AllowDelete
    $transactionId=[IO.Path]::GetFileName($stagingDirectory).Substring('.matrix-receipts-staging-'.Length)
    $ownerProcess=Get-Process -Id $PID -ErrorAction Stop
    $ownerMarker=[pscustomobject][ordered]@{schemaVersion=1;transactionId=$transactionId;ownerPid=[int]$PID;ownerProcessStartUtc=$ownerProcess.StartTime.ToUniversalTime().ToString('O');createdUtc=[DateTimeOffset]::UtcNow.ToString('O');destinationPath=$destinationFull;directoryIdentity=$stagingLease.Identity}
    Write-RendererPackageCanonicalJson -Value $ownerMarker -Path (Join-Path $stagingDirectory '.owner.json') -RepositoryRoot $repositoryFull
    if($PauseAfterStagingReadyMilliseconds-gt0){Start-Sleep -Milliseconds $PauseAfterStagingReadyMilliseconds}
    $written = 0
    foreach ($case in $cases) {
        $receipt = [pscustomobject][ordered]@{
            schemaVersion = 1
            caseId = $case
            observedUtc = [string]$derivedObservedUtcs[$case]
            outcome = [string]$derivedOutcomes[$case]
            operator = [pscustomobject][ordered]@{ identity = $OperatorIdentity; role = $OperatorRole }
            observer = [pscustomobject][ordered]@{ identity = $ObserverIdentity; role = $ObserverRole }
            evidenceBoundary = [pscustomobject][ordered]@{
                evidenceClass = [string]$derivedClasses[$case]
                release = 'NOT_OBSERVED'
                creditGranted = $false
            }
            rawEvidence = $rawIdentities[$case]
        }
        Write-RendererPackageCanonicalJson -Value $receipt -Path (Join-Path $stagingDirectory "matrix-evidence-$case.json") -RepositoryRoot $repositoryFull
        $written++
        if ($SimulateFailureAfterReceiptCount -gt 0 -and $written -eq $SimulateFailureAfterReceiptCount) {
            throw 'Simulated pre-publication interruption.'
        }
    }
    $rawSetLines=@($cases|ForEach-Object{"$_|$([string]$rawIdentities[$_].relativePath)|$([long]$rawIdentities[$_].bytes)|$([string]$rawIdentities[$_].sha256)"})
    $tupleSha256=Get-HumanDesignReviewSha256ForText ($commonRunFingerprint+"`n"+($rawSetLines-join"`n"))
    $replayRegistry=Open-MatrixReceiptReplayRegistry $evidenceRootFull $repositoryFull
    $replayRecord=[pscustomobject][ordered]@{schemaVersion=1;tupleSha256=$tupleSha256;runFingerprintSha256=(Get-HumanDesignReviewSha256ForText $commonRunFingerprint);rawSetSha256=(Get-HumanDesignReviewSha256ForText ($rawSetLines-join"`n"));destinationPath=$destinationFull;reservedUtc=[DateTimeOffset]::UtcNow.ToString('O')}
    $replayClaim=New-MatrixReceiptReplayClaim $replayRegistry $evidenceRootFull $repositoryFull $tupleSha256 $replayRecord
    $stagedNames = @(Get-ChildItem -LiteralPath $stagingDirectory -File | Where-Object Name -cne '.owner.json' | ForEach-Object Name)
    $expectedNames = @($cases | ForEach-Object { "matrix-evidence-$_.json" })
    Assert-RendererSet $stagedNames $expectedNames 'Staged receipt files'
    foreach ($case in $cases) {
        $rawFull = Resolve-RendererBoundPath $evidenceRootFull ([string]$rawIdentities[$case].relativePath) "Pre-publication raw evidence '$case'"
        Assert-RendererStableFileLease $rawLeases[$case] $evidenceRootFull $rawFull "Pre-publication raw evidence '$case'"
    }
    Assert-RendererDirectoryLease $parentLease $evidenceRootFull $destinationParent 'Destination parent before final move'
    Assert-RendererDirectoryLease $stagingLease $evidenceRootFull $stagingDirectory 'Staging directory before final move'
    Assert-RendererDirectoryLease $replayRegistry.Lease $evidenceRootFull $replayRegistry.Path 'Replay registry before final move'
    Assert-RendererStableFileLease $replayRegistry.MarkerLease $evidenceRootFull (Join-Path $replayRegistry.Path '.registry.json') 'Replay registry marker before final move'
    Assert-RendererDirectoryLease $replayClaim.Lease $evidenceRootFull $replayClaim.Path 'Replay claim before final move'
    if($PauseAfterPublicationIdentityVerifiedMilliseconds-gt0){[IO.File]::WriteAllText((Join-Path $evidenceRootFull '.publication-identity-verified'),'ready',(New-Object Text.UTF8Encoding($false)));Start-Sleep -Milliseconds $PauseAfterPublicationIdentityVerifiedMilliseconds}
    $publicationCommitUtc=[DateTimeOffset]::UtcNow
    if($commonRunEndedUtc-gt$publicationCommitUtc-or($publicationCommitUtc-$commonRunEndedUtc).TotalMinutes-gt5){throw 'Raw evidence is outside the trusted current five-minute publication commit window.'}
    try{Move-RendererLeasedDirectory $stagingLease $evidenceRootFull $stagingDirectory $destinationFull 'Receipt publication'}catch{if(Test-Path -LiteralPath $destinationFull){throw 'DestinationPath appeared during held-handle publication; receipt publication is atomic no-clobber.'};throw}
    $published = $true
} finally {
    try{
        $cleanupAttempted=$false
        if (-not $published -and $null-ne$stagingLease -and (Test-Path -LiteralPath $stagingDirectory)) {
            $ownedCleanup=$false
            try{Assert-RendererDirectoryLease $stagingLease $evidenceRootFull $stagingDirectory 'Failed transaction cleanup';$ownedCleanup=$true}catch{$ownedCleanup=$false}
            if($ownedCleanup){if($PauseAfterCleanupIdentityVerifiedMilliseconds-gt0){[IO.File]::WriteAllText((Join-Path $evidenceRootFull '.cleanup-identity-verified'),'ready',(New-Object Text.UTF8Encoding($false)));Start-Sleep -Milliseconds $PauseAfterCleanupIdentityVerifiedMilliseconds};$cleanupAttempted=$true;Remove-RendererLeasedDirectory $stagingLease $evidenceRootFull $stagingDirectory 'Failed transaction cleanup'}
        }
    }finally{
        try{
            if(-not$published-and$null-ne$replayClaim-and(Test-Path -LiteralPath $replayClaim.Path)){Remove-RendererLeasedDirectory $replayClaim.Lease $evidenceRootFull $replayClaim.Path 'Failed publication replay claim rollback'}
        }finally{
            if($null-ne$replayClaim){$replayClaim.Lease.Handle.Dispose()}
            if($null-ne$replayRegistry){if($null-ne$replayRegistry.MarkerLease.Stream){$replayRegistry.MarkerLease.Stream.Dispose()};$replayRegistry.Lease.Handle.Dispose()}
            if($null-ne$stagingLease){$stagingLease.Handle.Dispose()}
            if($cleanupAttempted-and(Test-Path -LiteralPath $stagingDirectory)){throw 'Failed transaction staging remained after held-handle owned deletion.'}
        }
    }
}
    return @($cases | ForEach-Object { Join-Path $destinationFull "matrix-evidence-$_.json" })
} finally {
    foreach($lease in @($rawLeases.Values)){if($null-ne$lease.Stream){$lease.Stream.Dispose()}}
    $parentLease.Handle.Dispose()
}
