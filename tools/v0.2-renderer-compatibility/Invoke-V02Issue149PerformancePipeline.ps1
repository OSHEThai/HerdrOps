#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$CaptureCandidateManifestPath,
    [Parameter(Mandatory=$true)][int]$CoreProcessId,
    [Parameter(Mandatory=$true)][string]$PerformanceOutputDirectory,
    [Parameter(Mandatory=$true)][string]$ComposedOutputDirectory,
    [Parameter(Mandatory=$true)][string]$PipelineCommitPath,
    [Parameter(Mandatory=$true)][string]$EvidenceRoot,
    [Parameter(Mandatory=$true)][string]$RepositoryRoot,
    [Parameter(Mandatory=$true)][string]$RunNonce,
    [Parameter(Mandatory=$true)][string]$PackageIdentityPath,
    [Parameter(Mandatory=$true)][string]$PackageArchivePath,
    [Parameter(Mandatory=$true)][string]$ExtractedPackageRoot,
    [Parameter(Mandatory=$true)][string]$ExpectedSourceCommit,
    [Parameter(Mandatory=$true)][string]$ExpectedSourceTree
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'RendererCompatibility.Common.ps1')
. (Join-Path $PSScriptRoot '..\lib\V02RuntimePackageBinding.ps1')

function Resolve-I149ContainedPath([string]$Root,[string]$Path,[string]$Context){
    $full=if([IO.Path]::IsPathRooted($Path)){[IO.Path]::GetFullPath($Path)}else{[IO.Path]::GetFullPath((Join-Path $Root $Path))}
    if($full-cne$Root-and-not$full.StartsWith($Root+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw "$Context escaped the evidence root."}
    Assert-RendererNonReparsePath $Root $full $Context;$full
}
function Read-I149CanonicalJson([string]$Root,[string]$Path,[string]$Context,[string]$Repo){
    $stable=Get-RendererStableFileIdentity $Root $Path $Context -IncludeBytes -KeepOpen
    try{$json=(New-Object Text.UTF8Encoding($false,$true)).GetString($stable.Content);$value=ConvertFrom-StrictHumanDesignReviewJson $json $Context;if($PSVersionTable.PSVersion.Major-ge7-and(Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')){$value=$json|ConvertFrom-Json -DateKind String};$canonical=ConvertTo-RendererCanonicalJson $value $Repo;if($json.TrimEnd("`r","`n")-cne$canonical){throw "$Context is not canonical JSON."};[pscustomobject]@{Value=$value;Stable=$stable;CanonicalSha256=(Get-HumanDesignReviewSha256ForText $canonical)}}catch{if($null-ne$stable.Stream){$stable.Stream.Dispose()};throw}
}

$root=[IO.Path]::GetFullPath($EvidenceRoot).TrimEnd('\','/');$repo=[IO.Path]::GetFullPath($RepositoryRoot)
Assert-RendererNonReparsePath $root $root 'Issue #149 evidence root'
if($RunNonce-cnotmatch'^[0-9a-f]{32}$'){throw 'RunNonce must be lowercase 32-hex.'}
$git=Get-RendererGitIdentity $repo;if($git.CommitSha-cne$ExpectedSourceCommit-or$git.TreeSha-cne$ExpectedSourceTree){throw 'Repository HEAD does not equal the requested Issue #149 candidate.'}
$package=Resolve-V02RuntimePackageBinding -IdentityPath $PackageIdentityPath -ArchivePath $PackageArchivePath -PackageRoot $ExtractedPackageRoot -RepositoryRoot $repo -ProfilePath (Join-Path $repo 'tools\packaging\v0.2\package-identity-profile.json') -ExpectedSourceCommit $ExpectedSourceCommit -ExpectedSourceTree $ExpectedSourceTree
$captureManifestPath=Resolve-I149ContainedPath $root $CaptureCandidateManifestPath 'Capture candidate manifest';$captureRoot=Split-Path -Parent $captureManifestPath
$captureStable=$null;$captureManifest=$null;$performanceCommitted=$false;$composedCommitted=$false;$pipelineLeases=@();$commitStage=$null
try{
$captureStable=Get-RendererStableFileIdentity $root $captureManifestPath 'Capture candidate manifest' -IncludeBytes -KeepOpen
$null=Test-RendererCompatibilityManifest $captureManifestPath $captureRoot $repo -ValidateBindings
$captureJson=(New-Object Text.UTF8Encoding($false,$true)).GetString($captureStable.Content);$captureManifest=ConvertFrom-StrictHumanDesignReviewJson $captureJson 'Capture candidate manifest';if($PSVersionTable.PSVersion.Major-ge7-and(Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')){$captureManifest=$captureJson|ConvertFrom-Json -DateKind String};if([long]$captureManifest.manifestVersion-ne4-or$captureManifest.performanceProtocol.samplesStatus-cne'NOT_OBSERVED'-or$null-ne$captureManifest.performanceProtocol.evidenceReceipt-or$null-ne$captureManifest.performanceProtocol.pipelineCommit-or$captureManifest.candidate.source.commitSha-cne$ExpectedSourceCommit-or$captureManifest.candidate.source.treeSha-cne$ExpectedSourceTree){throw 'Pipeline requires an exact unfinalized manifest-v4 performance-only capture candidate.'}
$performanceDir=Resolve-I149ContainedPath $root $PerformanceOutputDirectory 'Performance output directory';$composedDir=Resolve-I149ContainedPath $root $ComposedOutputDirectory 'Composed output directory'
$pipelineCommit=Resolve-I149ContainedPath $root $PipelineCommitPath 'Pipeline transaction commit'
foreach($output in @($performanceDir,$composedDir,$pipelineCommit)){if($captureRoot-ceq$output-or$captureRoot.StartsWith($output+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)-or$output.StartsWith($captureRoot+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Capture candidate root must be disjoint from every pipeline output and commit path.'}}
foreach($pair in @(@($performanceDir,$composedDir),@($performanceDir,$pipelineCommit),@($composedDir,$pipelineCommit))){$a=[string]$pair[0];$b=[string]$pair[1];if($a-cne$b-and($a.StartsWith($b+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)-or$b.StartsWith($a+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase))){throw 'Issue #149 pipeline output paths must not overlap or contain one another.'};if($a-ceq$b){throw 'Issue #149 pipeline output paths must be distinct.'}}
if(Test-Path -LiteralPath $performanceDir){throw 'Performance output directory already exists; refusing to clobber.'};if(Test-Path -LiteralPath $composedDir){throw 'Composed output directory already exists; refusing to clobber.'};if(Test-Path -LiteralPath $pipelineCommit){throw 'Pipeline transaction commit already exists; refusing to clobber.'}
    $rawPath=Join-Path $performanceDir 'raw-observations.json';$bindingPath=Join-Path $performanceDir 'performance-telemetry-binding.json'
    $measurement=& (Join-Path $PSScriptRoot 'Invoke-V02PerformanceMeasurement.ps1') -DestinationPath $rawPath -BindingDestinationPath $bindingPath -EvidenceRoot $root -RepositoryRoot $repo -PackageIdentityPath $PackageIdentityPath -PackageArchivePath $PackageArchivePath -ExtractedPackageRoot $ExtractedPackageRoot -ExpectedSourceCommit $ExpectedSourceCommit -ExpectedSourceTree $ExpectedSourceTree -CoreProcessId $CoreProcessId -RunNonce $RunNonce
    $performanceCommitted=$true
    $published=& (Join-Path $PSScriptRoot '..\v0.2-issue10-live-widget\Publish-V02Issue10PerformanceEvidence.ps1') -RawPerformancePath $rawPath -PerformanceBindingPath $bindingPath -PerformanceCommitPath (Join-Path $performanceDir 'performance-commit.json') -DestinationDirectory $composedDir -EvidenceRoot $root -RepositoryRoot $repo -RunNonce $RunNonce -PackageIdentityPath $PackageIdentityPath -PackageArchivePath $PackageArchivePath -ExtractedPackageRoot $ExtractedPackageRoot -ExpectedSourceCommit $ExpectedSourceCommit -ExpectedSourceTree $ExpectedSourceTree
    $composedCommitted=$true
    $rawRead=Read-I149CanonicalJson $root $rawPath 'Pipeline raw performance' $repo;$bindingRead=Read-I149CanonicalJson $root $bindingPath 'Pipeline performance binding' $repo;$perfCommitPath=Join-Path $performanceDir 'performance-commit.json';$perfCommitRead=Read-I149CanonicalJson $root $perfCommitPath 'Pipeline performance commit' $repo
    try{
        $bindingRelative=$bindingPath.Substring($root.Length).TrimStart('\','/').Replace('\','/');$perfCommitRelative=$perfCommitPath.Substring($root.Length).TrimStart('\','/').Replace('\','/')
        $bindingReceipt=[pscustomobject][ordered]@{relativePath=$bindingRelative;bytes=[long]$bindingRead.Stable.Bytes;fileSha256=[string]$bindingRead.Stable.Sha256;canonicalSha256=[string]$bindingRead.CanonicalSha256};$perfCommitReceipt=[pscustomobject][ordered]@{relativePath=$perfCommitRelative;bytes=[long]$perfCommitRead.Stable.Bytes;fileSha256=[string]$perfCommitRead.Stable.Sha256;canonicalSha256=[string]$perfCommitRead.CanonicalSha256}
        $selected=[pscustomobject]@{ReceiptPath=$published.PerformanceReceiptPath;FileSha256=$published.PerformanceReceiptSha256}
    }finally{$rawRead.Stable.Stream.Dispose();$bindingRead.Stable.Stream.Dispose();$perfCommitRead.Stable.Stream.Dispose()}
    $commitBindings=[ordered]@{}
    foreach($entry in @(@('raw',$rawPath),@('binding',$bindingPath),@('performanceCommit',(Join-Path $performanceDir 'performance-commit.json')),@('performanceReceipt',$selected.ReceiptPath))){ $identity=Get-RendererStableFileIdentity $root $entry[1] "Pipeline commit $($entry[0])" -IncludeBytes -KeepOpen;$pipelineLeases+=,[pscustomobject]@{Name=$entry[0];Path=$entry[1];Stable=$identity};$relative=$identity.FinalPath.Substring($root.Length).TrimStart('\','/').Replace('\','/');$commitBindings[$entry[0]]=[pscustomobject][ordered]@{relativePath=$relative;bytes=[long]$identity.Bytes;sha256=[string]$identity.Sha256}}
    $capturePackageRootPath=[IO.Path]::GetFullPath([string]$package.PackageRoot).TrimEnd('\','/');if($capturePackageRootPath-cne[string]$package.PackageRoot.TrimEnd('\','/')){throw 'Resolved capture package root is not an exact normalized path.'}
    $commitObject=[pscustomobject][ordered]@{schemaVersion=4;kind='issue149-performance-pipeline-commit';runNonce=$RunNonce;capturePackageRootPath=$capturePackageRootPath;source=[pscustomobject][ordered]@{commitSha=$ExpectedSourceCommit;treeSha=$ExpectedSourceTree};files=[pscustomobject]$commitBindings;evidenceBoundary=[pscustomobject][ordered]@{actualHerdrRuntime='NOT_OBSERVED';release='NOT_OBSERVED';creditGranted=$false}}
    $commitBytes=(New-Object Text.UTF8Encoding($false,$true)).GetBytes((ConvertTo-RendererCanonicalJson $commitObject $repo)+"`n");$commitParent=Split-Path -Parent $pipelineCommit;if(-not(Test-Path -LiteralPath $commitParent)){New-Item -ItemType Directory -Path $commitParent -Force|Out-Null};$commitStage=Join-Path $commitParent ('.issue149-pipeline-commit-'+[Guid]::NewGuid().ToString('N')+'.tmp');$commitStream=[IO.File]::Open($commitStage,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);try{$commitStream.Write($commitBytes,0,$commitBytes.Length);$commitStream.Flush($true)}finally{$commitStream.Dispose()};if(Test-Path -LiteralPath $pipelineCommit){throw 'Pipeline transaction commit appeared concurrently.'};[IO.File]::Move($commitStage,$pipelineCommit);$commitStage=$null
    $commitIdentity=Get-RendererStableFileIdentity $root $pipelineCommit 'Pipeline transaction commit';if($commitIdentity.Bytes-ne$commitBytes.Length-or$commitIdentity.Sha256-cne(Get-HumanDesignReviewSha256ForBytes $commitBytes)){throw 'Pipeline transaction commit changed during publication.'}
    foreach($lease in $pipelineLeases){Assert-RendererStableFileLease $lease.Stable $root $lease.Path "Pipeline commit $($lease.Name) after publication"}
    Assert-RendererStableFileLease $captureStable $root $captureManifestPath 'Capture candidate manifest after pipeline commit'
    [pscustomobject][ordered]@{SchemaVersion=4;EvidenceClassification='Issue149PerformanceCandidate-NoRuntimeCredit';RunNonce=$RunNonce;PerformanceOutputDirectory=$performanceDir;ComposedOutputDirectory=$composedDir;PipelineCommitPath=$pipelineCommit;PerformanceReceiptPath=$selected.ReceiptPath;ActualHerdrRuntime='NOT_OBSERVED';Release='NOT_OBSERVED';CreditGranted=$false}
}finally{
    if($null-ne$captureStable-and$null-ne$captureStable.Stream){$captureStable.Stream.Dispose()}
    foreach($lease in $pipelineLeases){if($null-ne$lease.Stable.Stream){$lease.Stable.Stream.Dispose()}}
    if($null-ne$commitStage-and(Test-Path -LiteralPath $commitStage)){[IO.File]::Delete($commitStage)}
    # A crash or failure can leave collector-owned atomic directories, but they
    # are deliberately inadmissible without the final pipeline commit. Never
    # recursively delete caller-visible evidence during recovery.
}
