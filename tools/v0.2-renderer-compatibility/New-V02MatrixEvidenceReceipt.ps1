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
    [Parameter(Mandatory=$true)][string]$ObservedUtc,
    [Parameter(Mandatory=$false)][string]$EvidenceRoot,
    [Parameter(Mandatory=$false)][string]$RepositoryRoot,
    [Parameter(DontShow=$true)][ValidateRange(0,25)][int]$SimulateFailureAfterReceiptCount = 0
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'RendererCompatibility.Common.ps1')

$cases = @(Get-RendererGovernedMatrixCases)
if ($cases.Count -ne 25) { throw "Governed matrix case count must be exactly 25; observed $($cases.Count)." }

Assert-RendererString $OperatorIdentity 'OperatorIdentity'
Assert-RendererString $ObserverIdentity 'ObserverIdentity'
if ($OperatorIdentity.Trim().Equals($ObserverIdentity.Trim(), [StringComparison]::OrdinalIgnoreCase)) { throw 'OperatorIdentity and ObserverIdentity must be distinct.' }
Assert-RendererUtc $ObservedUtc 'ObservedUtc'
$callerBatchUtc = [DateTimeOffset]::Parse($ObservedUtc)

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

# Owned transaction / staging recovery: sweep any orphaned staging directories left by terminated child processes
if (Test-Path -LiteralPath $destinationParent -PathType Container) {
    $staleStaging = @(Get-ChildItem -LiteralPath $destinationParent -Directory -Filter '.matrix-receipts-staging-*' -ErrorAction SilentlyContinue)
    foreach ($stale in $staleStaging) {
        Remove-Item -LiteralPath $stale.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
}

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

foreach ($case in $cases) {
    $relativePath = $RawEvidencePaths[$case]
    Assert-RendererRelativePath $relativePath "Raw evidence '$case' relativePath"
    $rawFull = Resolve-RendererBoundPath $evidenceRootFull ([string]$relativePath) "Raw evidence '$case'"
    if (-not (Test-Path -LiteralPath $rawFull -PathType Leaf)) { throw "Raw evidence '$case' is missing." }
    $identity = Get-RendererStableFileIdentity $evidenceRootFull $rawFull "Raw evidence '$case'" -IncludeBytes
    if ($identity.Bytes -le 0) { throw "Raw evidence '$case' must be nonempty." }

    $json = (New-Object Text.UTF8Encoding($false,$true)).GetString($identity.Content)
    $payload = ConvertFrom-StrictHumanDesignReviewJson -Json $json -Description "Raw evidence payload '$case'"
    if ($PSVersionTable.PSVersion.Major -ge 7 -and (Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) {
        $payload = $json | ConvertFrom-Json -DateKind String
    }

    $validated = Assert-RendererMatrixRawPayload -Payload $payload -ExpectedCaseId $case -Context "Raw evidence '$case'"
    
    $rawObsUtc = [DateTimeOffset]::Parse($validated.ObservedUtc)
    if ($rawObsUtc -gt $callerBatchUtc) {
        throw "Raw evidence '$case' observedUtc '$($validated.ObservedUtc)' is after caller batch window '$ObservedUtc'."
    }

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
try {
    New-Item -Path $stagingDirectory -ItemType Directory -ErrorAction Stop | Out-Null
    Assert-RendererNonReparsePath $evidenceRootFull $stagingDirectory 'Staging directory'
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
    $stagedNames = @(Get-ChildItem -LiteralPath $stagingDirectory -File | ForEach-Object Name)
    $expectedNames = @($cases | ForEach-Object { "matrix-evidence-$_.json" })
    Assert-RendererSet $stagedNames $expectedNames 'Staged receipt files'
    foreach ($case in $cases) {
        $rawFull = Resolve-RendererBoundPath $evidenceRootFull ([string]$rawIdentities[$case].relativePath) "Pre-publication raw evidence '$case'"
        $current = Get-RendererStableFileIdentity $evidenceRootFull $rawFull "Pre-publication raw evidence '$case'"
        if ($current.Bytes -ne [long]$rawIdentities[$case].bytes -or $current.Sha256 -cne [string]$rawIdentities[$case].sha256) {
            throw "Raw evidence '$case' changed before publication."
        }
    }
    Assert-RendererNonReparsePath $evidenceRootFull $destinationParent 'Destination parent before final move'
    Assert-RendererNonReparsePath $evidenceRootFull $stagingDirectory 'Staging directory before final move'
    [IO.Directory]::Move($stagingDirectory, $destinationFull)
    $published = $true
} finally {
    if (-not $published -and (Test-Path -LiteralPath $stagingDirectory)) {
        Remove-Item -LiteralPath $stagingDirectory -Recurse -Force
    }
}
return @($cases | ForEach-Object { Join-Path $destinationFull "matrix-evidence-$_.json" })
