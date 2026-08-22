#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$DestinationPath,
    [Parameter(Mandatory=$true)][string]$OperatorIdentity,
    [Parameter(Mandatory=$true)][ValidateSet('EvidenceOperator')][string]$OperatorRole,
    [Parameter(Mandatory=$true)][Alias('ReviewerIdentity')][string]$ObserverIdentity,
    [Parameter(Mandatory=$true)][ValidateSet('IndependentObserver')][string]$ObserverRole,
    [Parameter(Mandatory=$false)][ValidateSet('Static','Synthetic','Contract','Runtime')][string]$EvidenceBoundary,
    [Parameter(Mandatory=$false)][hashtable]$Outcomes,
    [Parameter(Mandatory=$true)][hashtable]$RawEvidencePaths,
    [Parameter(Mandatory=$false)][string]$EvidenceRoot,
    [Parameter(Mandatory=$false)][string]$RepositoryRoot,
    [Parameter(DontShow=$true)][ValidateRange(0,25)][int]$SimulateFailureAfterReceiptCount = 0,
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

$cases = @(Get-RendererGovernedMatrixCases)
if ($cases.Count -ne 25) { throw "Governed matrix case count must be exactly 25; observed $($cases.Count)." }

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
if (Test-Path -LiteralPath $destinationFull) { throw 'DestinationPath already exists; receipt publication is no-clobber.' }

$parentLease=Open-RendererDirectoryLease $evidenceRootFull $destinationParent 'Destination parent lease'
$rawLeases=@{}
try {
    # Recover only authenticated, old transactions whose exact PID/start-time owner is dead.
    $staleStaging=@(Get-ChildItem -LiteralPath $destinationParent -Directory -Filter '.matrix-receipts-staging-*' -ErrorAction Stop)
    foreach($stale in $staleStaging){Remove-OwnedStaleMatrixStaging $stale.FullName $destinationFull $evidenceRootFull $repositoryFull ([DateTimeOffset]::UtcNow) $PauseAfterRecoveryIdentityVerifiedMilliseconds}

$rawKeys = @($RawEvidencePaths.Keys | ForEach-Object { [string]$_ })
if ($rawKeys.Count -ne $cases.Count) { throw "RawEvidencePaths must contain exactly the 25 governed case IDs; observed $($rawKeys.Count)." }
foreach ($case in $cases) {
    if (-not ($rawKeys -ccontains $case)) { throw "RawEvidencePaths omitted exact case ID '$case'." }
}

if ($null -ne $Outcomes) {
    $outcomeKeys = @($Outcomes.Keys | ForEach-Object { [string]$_ })
    if ($outcomeKeys.Count -ne $cases.Count) { throw "Outcomes must contain exactly the 25 governed case IDs; observed $($outcomeKeys.Count)." }
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
    if($null-eq$commonRunFingerprint){$commonRunFingerprint=$validated.RunFingerprint}else{if($commonRunFingerprint-cne$validated.RunFingerprint){throw "Raw evidence '$case' does not share the exact common run/session/candidate/package identity."}}
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
                finalHumanGo = 'NOT_OBSERVED'
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
    $stagedNames = @(Get-ChildItem -LiteralPath $stagingDirectory -File | Where-Object Name -cne '.owner.json' | ForEach-Object Name)
    $expectedNames = @($cases | ForEach-Object { "matrix-evidence-$_.json" })
    Assert-RendererSet $stagedNames $expectedNames 'Staged receipt files'
    foreach ($case in $cases) {
        $rawFull = Resolve-RendererBoundPath $evidenceRootFull ([string]$rawIdentities[$case].relativePath) "Pre-publication raw evidence '$case'"
        Assert-RendererStableFileLease $rawLeases[$case] $evidenceRootFull $rawFull "Pre-publication raw evidence '$case'"
    }
    Assert-RendererDirectoryLease $parentLease $evidenceRootFull $destinationParent 'Destination parent before final move'
    Assert-RendererDirectoryLease $stagingLease $evidenceRootFull $stagingDirectory 'Staging directory before final move'
    if($PauseAfterPublicationIdentityVerifiedMilliseconds-gt0){[IO.File]::WriteAllText((Join-Path $evidenceRootFull '.publication-identity-verified'),'ready',(New-Object Text.UTF8Encoding($false)));Start-Sleep -Milliseconds $PauseAfterPublicationIdentityVerifiedMilliseconds}
    try{Move-RendererLeasedDirectory $stagingLease $evidenceRootFull $stagingDirectory $destinationFull 'Receipt publication'}catch{if(Test-Path -LiteralPath $destinationFull){throw 'DestinationPath appeared during held-handle publication; receipt publication is atomic no-clobber.'};throw}
    $published = $true
} finally {
    $cleanupAttempted=$false
    if (-not $published -and $null-ne$stagingLease -and (Test-Path -LiteralPath $stagingDirectory)) {
        $ownedCleanup=$false
        try{Assert-RendererDirectoryLease $stagingLease $evidenceRootFull $stagingDirectory 'Failed transaction cleanup';$ownedCleanup=$true}catch{$ownedCleanup=$false}
        if($ownedCleanup){if($PauseAfterCleanupIdentityVerifiedMilliseconds-gt0){[IO.File]::WriteAllText((Join-Path $evidenceRootFull '.cleanup-identity-verified'),'ready',(New-Object Text.UTF8Encoding($false)));Start-Sleep -Milliseconds $PauseAfterCleanupIdentityVerifiedMilliseconds};$cleanupAttempted=$true;Remove-RendererLeasedDirectory $stagingLease $evidenceRootFull $stagingDirectory 'Failed transaction cleanup'}
    }
    if($null-ne$stagingLease){$stagingLease.Handle.Dispose()}
    if($cleanupAttempted-and(Test-Path -LiteralPath $stagingDirectory)){throw 'Failed transaction staging remained after held-handle owned deletion.'}
}
    return @($cases | ForEach-Object { Join-Path $destinationFull "matrix-evidence-$_.json" })
} finally {
    foreach($lease in @($rawLeases.Values)){if($null-ne$lease.Stream){$lease.Stream.Dispose()}}
    $parentLease.Handle.Dispose()
}
