#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$DestinationPath,
    [Parameter(Mandatory=$true)][string]$OperatorIdentity,
    [Parameter(Mandatory=$true)][ValidateSet('EvidenceOperator')][string]$OperatorRole,
    [Parameter(Mandatory=$true)][Alias('ReviewerIdentity')][string]$ObserverIdentity,
    [Parameter(Mandatory=$true)][ValidateSet('IndependentObserver')][string]$ObserverRole,
    [Parameter(Mandatory=$true)][ValidateSet('Static','Synthetic','Contract','Runtime')][string]$EvidenceBoundary,
    [Parameter(Mandatory=$true)][hashtable]$Outcomes,
    [Parameter(Mandatory=$true)][hashtable]$RawEvidencePaths,
    [Parameter(Mandatory=$true)][string]$ObservedUtc,
    [Parameter(Mandatory=$false)][string]$EvidenceRoot,
    [Parameter(Mandatory=$false)][string]$RepositoryRoot,
    [Parameter(DontShow=$true)][ValidateRange(0,18)][int]$SimulateFailureAfterReceiptCount = 0
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'RendererCompatibility.Common.ps1')

$cases = @(
    '1920x1080-100', '1920x1080-125', '1920x1080-150',
    '1366x768-100', '1366x768-125', '1366x768-150',
    'mixed-dpi-100-to-150-primary-switch-unplug', 'mixed-dpi-150-to-100-primary-switch-unplug',
    'mixed-dpi-125-to-150-primary-switch-unplug', 'mixed-dpi-150-to-125-primary-switch-unplug',
    'keyboard-uia', 'narrator', 'high-contrast', 'text-scale-100',
    'text-scale-150', 'text-scale-200', 'reduced-motion-on', 'reduced-motion-off'
)

Assert-RendererString $OperatorIdentity 'OperatorIdentity'
Assert-RendererString $ObserverIdentity 'ObserverIdentity'
if ($OperatorIdentity -ceq $ObserverIdentity) { throw 'OperatorIdentity and ObserverIdentity must be distinct.' }
Assert-RendererUtc $ObservedUtc 'ObservedUtc'

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

foreach ($map in @(@{Name='Outcomes';Value=$Outcomes},@{Name='RawEvidencePaths';Value=$RawEvidencePaths})) {
    $keys=@($map.Value.Keys|ForEach-Object{[string]$_})
    if($keys.Count-ne$cases.Count){throw "$($map.Name) must contain exactly the 18 governed case IDs."}
    foreach($case in $cases){if(-not($keys-ccontains$case)){throw "$($map.Name) omitted exact case ID '$case'."}}
}

$rawIdentities=@{}
foreach($case in $cases){
    $outcome=$Outcomes[$case]
    if($outcome-isnot[string]-or[string]$outcome-cnotin@('PASS','FAIL')){throw "Outcome for '$case' must be exact PASS or FAIL."}
    $relativePath=$RawEvidencePaths[$case]
    Assert-RendererRelativePath $relativePath "Raw evidence '$case' relativePath"
    $rawFull=Resolve-RendererBoundPath $evidenceRootFull ([string]$relativePath) "Raw evidence '$case'"
    if(-not(Test-Path -LiteralPath $rawFull -PathType Leaf)){throw "Raw evidence '$case' is missing."}
    $identity=Get-RendererStableFileIdentity $evidenceRootFull $rawFull "Raw evidence '$case'"
    if($identity.Bytes-le0){throw "Raw evidence '$case' must be nonempty."}
    $rawIdentities[$case]=[pscustomobject][ordered]@{relativePath=([string]$relativePath-replace'\\','/');bytes=[long]$identity.Bytes;sha256=[string]$identity.Sha256}
}

$stagingDirectory=Join-Path $destinationParent ('.matrix-receipts-staging-'+[guid]::NewGuid().ToString('N'))
$published=$false
try{
    New-Item -Path $stagingDirectory -ItemType Directory -ErrorAction Stop|Out-Null
    Assert-RendererNonReparsePath $evidenceRootFull $stagingDirectory 'Staging directory'
    $written=0
    foreach($case in $cases){
        $receipt=[pscustomobject][ordered]@{
            schemaVersion=1;caseId=$case;observedUtc=$ObservedUtc;outcome=[string]$Outcomes[$case]
            operator=[pscustomobject][ordered]@{identity=$OperatorIdentity;role=$OperatorRole}
            observer=[pscustomobject][ordered]@{identity=$ObserverIdentity;role=$ObserverRole}
            evidenceBoundary=[pscustomobject][ordered]@{evidenceClass=$EvidenceBoundary;finalHumanGo='NOT_OBSERVED';release='NOT_OBSERVED';creditGranted=$false}
            rawEvidence=$rawIdentities[$case]
        }
        Write-RendererPackageCanonicalJson -Value $receipt -Path (Join-Path $stagingDirectory "matrix-evidence-$case.json") -RepositoryRoot $repositoryFull
        $written++
        if($SimulateFailureAfterReceiptCount-gt0-and$written-eq$SimulateFailureAfterReceiptCount){throw 'Simulated pre-publication interruption.'}
    }
    $stagedNames=@(Get-ChildItem -LiteralPath $stagingDirectory -File|ForEach-Object Name)
    $expectedNames=@($cases|ForEach-Object{"matrix-evidence-$_.json"})
    Assert-RendererSet $stagedNames $expectedNames 'Staged receipt files'
    foreach($case in $cases){
        $rawFull=Resolve-RendererBoundPath $evidenceRootFull ([string]$rawIdentities[$case].relativePath) "Pre-publication raw evidence '$case'"
        $current=Get-RendererStableFileIdentity $evidenceRootFull $rawFull "Pre-publication raw evidence '$case'"
        if($current.Bytes-ne[long]$rawIdentities[$case].bytes-or$current.Sha256-cne[string]$rawIdentities[$case].sha256){throw "Raw evidence '$case' changed before publication."}
    }
    [IO.Directory]::Move($stagingDirectory,$destinationFull)
    $published=$true
}finally{
    if(-not$published-and(Test-Path -LiteralPath $stagingDirectory)){Remove-Item -LiteralPath $stagingDirectory -Recurse -Force}
}
return @(Get-ChildItem -LiteralPath $destinationFull -File|Sort-Object Name|ForEach-Object FullName)
