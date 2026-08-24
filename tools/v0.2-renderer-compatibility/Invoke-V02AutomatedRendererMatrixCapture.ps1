#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$CaptureCandidateDirectory,
    [Parameter(Mandatory=$true)][string]$DestinationDirectory,
    [Parameter(Mandatory=$true)][string]$OperatorIdentity,
    [Parameter(Mandatory=$true)][string]$IndependentReviewerIdentity,
    [Parameter(Mandatory=$false)][string]$RepositoryRoot,
    [ValidateRange(30,300)][int]$TimeoutSeconds=120
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'RendererCompatibility.Common.ps1')
function ConvertTo-MatrixProcessArgument {param([AllowEmptyString()][string]$Argument);if($null-eq$Argument){$Argument=''};$builder=New-Object Text.StringBuilder;$null=$builder.Append('"');$slashes=0;foreach($character in $Argument.ToCharArray()){if($character-eq[char]92){$slashes++;continue};if($character-eq[char]34){$null=$builder.Append(('\'* (($slashes*2)+1)) -join '');$null=$builder.Append('"');$slashes=0;continue};if($slashes-gt0){$null=$builder.Append(('\'*$slashes)-join'');$slashes=0};$null=$builder.Append([string]$character)};if($slashes-gt0){$null=$builder.Append(('\'*($slashes*2))-join'')};$null=$builder.Append('"');$builder.ToString()}

if([string]::IsNullOrWhiteSpace($RepositoryRoot)){$RepositoryRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path}
$repo=[IO.Path]::GetFullPath($RepositoryRoot).TrimEnd('\','/')
$source=[IO.Path]::GetFullPath($CaptureCandidateDirectory).TrimEnd('\','/')
$destination=[IO.Path]::GetFullPath($DestinationDirectory).TrimEnd('\','/')
if($source-ceq$destination-or$source.StartsWith($destination+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)-or$destination.StartsWith($source+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'CaptureCandidateDirectory and DestinationDirectory must be disjoint.'}
if(-not(Test-Path -LiteralPath $source -PathType Container)){throw 'CaptureCandidateDirectory is missing.'}
if(Test-Path -LiteralPath $destination){throw 'DestinationDirectory already exists; automated matrix publication is no-clobber.'}
Assert-RendererString $OperatorIdentity 'OperatorIdentity';Assert-RendererString $IndependentReviewerIdentity 'IndependentReviewerIdentity'
if($OperatorIdentity.Trim().Equals($IndependentReviewerIdentity.Trim(),[StringComparison]::OrdinalIgnoreCase)){throw 'Operator and independent reviewer identities must be distinct.'}
Assert-RendererNonReparsePath $repo $repo 'RepositoryRoot'
Assert-RendererNonReparsePath $source $source 'CaptureCandidateDirectory'
foreach($entry in @(Get-ChildItem -LiteralPath $source -Force -Recurse)){if(($entry.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){throw "Capture candidate contains prohibited reparse entry '$($entry.FullName)'."}}

$manifestPath=Join-Path $source 'renderer-compatibility-manifest.json'
$sourceResult=Test-RendererCompatibilityManifest -ManifestPath $manifestPath -EvidenceRoot $source -RepositoryRoot $repo -ValidateBindings
if($sourceResult.ManifestVersion-ne4-or$sourceResult.ActualHerdrRuntime-cne'NOT_OBSERVED'-or[bool]$sourceResult.CreditGranted){throw 'Capture candidate is not an uncredited manifest-v4 automated packaged candidate.'}
$sourceManifestStable=Get-RendererStableFileIdentity $source $manifestPath 'Source renderer manifest' -IncludeBytes -KeepOpen
$staging=Join-Path ([IO.Path]::GetDirectoryName($destination)) ('.renderer-matrix-candidate-staging-'+[guid]::NewGuid().ToString('N'))
$published=$false;$process=$null
try{
    New-Item -ItemType Directory -Path $staging -ErrorAction Stop|Out-Null
    foreach($entry in @(Get-ChildItem -LiteralPath $source -Force)){Copy-Item -LiteralPath $entry.FullName -Destination $staging -Recurse -ErrorAction Stop}
    $stagedManifestPath=Join-Path $staging 'renderer-compatibility-manifest.json'
    $manifestJson=Get-Content -LiteralPath $stagedManifestPath -Raw
    $manifest=ConvertFrom-StrictHumanDesignReviewJson -Json $manifestJson -Description 'Staged renderer manifest'
    if($PSVersionTable.PSVersion.Major-ge7-and(Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')){$manifest=$manifestJson|ConvertFrom-Json -DateKind String}
    $appPath=Join-Path (Resolve-RendererBoundPath $staging ([string]$manifest.candidate.packageRootRelativePath) 'Packaged root') ([string]$manifest.candidate.components.app.relativePath)
    $appStable=Get-RendererStableFileIdentity $staging $appPath 'Packaged App'
    if($appStable.Bytes-ne[long]$manifest.candidate.components.app.bytes-or$appStable.Sha256-cne[string]$manifest.candidate.components.app.sha256){throw 'Packaged App bytes/hash do not equal the capture candidate.'}
    $rawDirectory=Join-Path $staging 'matrix-raw'
    $collectorError=Join-Path $staging 'matrix-collector-error.txt'
    $runId='matrix-'+[guid]::NewGuid().ToString('N')
    $sessionId='packaged-'+[guid]::NewGuid().ToString('N')
    $arguments=@(
        '--renderer-matrix-output',$rawDirectory,'--renderer-matrix-error-path',$collectorError,'--renderer-matrix-run-id',$runId,
        '--renderer-matrix-session-id',$sessionId,'--renderer-matrix-candidate-commit',[string]$manifest.candidate.source.commitSha,
        '--renderer-matrix-candidate-tree',[string]$manifest.candidate.source.treeSha,'--renderer-matrix-package-receipt-sha256',[string]$manifest.candidate.receipt.canonicalSha256,
        '--renderer-matrix-operator',$OperatorIdentity,'--renderer-matrix-observer',$IndependentReviewerIdentity)
    $process=Start-Process -FilePath $appPath -ArgumentList (($arguments|ForEach-Object{ConvertTo-MatrixProcessArgument ([string]$_)})-join' ') -PassThru -WindowStyle Hidden
    if(-not$process.WaitForExit($TimeoutSeconds*1000)){try{$process.Kill()}catch{};throw "Packaged App automated renderer collector exceeded $TimeoutSeconds seconds."}
    if($process.ExitCode-ne0){$detail=if(Test-Path -LiteralPath $collectorError){Get-Content -LiteralPath $collectorError -Raw}else{'No collector diagnostic was emitted.'};throw "Packaged App automated renderer collector exited $($process.ExitCode): $detail"}
    $rawPaths=@{};foreach($case in @(Get-RendererGovernedMatrixCases)){$rawPaths[$case]="matrix-raw/$case.json"}
    $receiptDirectory=Join-Path $staging 'matrix-receipts'
    $null=& (Join-Path $PSScriptRoot 'New-V02MatrixEvidenceReceipt.ps1') -DestinationPath $receiptDirectory -OperatorIdentity $OperatorIdentity -OperatorRole EvidenceOperator -ObserverIdentity $IndependentReviewerIdentity -ObserverRole IndependentAgentReviewer -EvidenceBoundary AutomatedPackagedRendering -RawEvidencePaths $rawPaths -EvidenceRoot $staging -RepositoryRoot $repo
    $caseGroups=@(
        @{Property='displayCases';Ids=@($script:RendererDisplayCases)},
        @{Property='accessibilityCases';Ids=@($script:RendererAccessibilityCases)},
        @{Property='supportedEnvironmentCases';Ids=@($script:RendererEnvironmentCases)})
    foreach($group in $caseGroups){
        $items=@();foreach($case in $group.Ids){
            $receiptPath=Join-Path $receiptDirectory "matrix-evidence-$case.json"
            $read=Read-RendererEvidenceReceipt ([pscustomobject][ordered]@{relativePath="matrix-receipts/matrix-evidence-$case.json";bytes=(Get-Item $receiptPath).Length;fileSha256=(Get-FileHash $receiptPath -Algorithm SHA256).Hash;canonicalSha256=(Get-HumanDesignReviewSha256ForText ((Get-Content $receiptPath -Raw).TrimEnd("`n")))}) "Matrix receipt '$case'" $staging $repo
            try{$items+=,[pscustomobject][ordered]@{id=$case;status=[string]$read.Value.outcome;evidenceReceipt=[pscustomobject][ordered]@{relativePath="matrix-receipts/matrix-evidence-$case.json";bytes=[long]$read.Stable.Bytes;fileSha256=[string]$read.Stable.Sha256;canonicalSha256=[string]$read.CanonicalSha256};notes="Automated packaged WPF collector observation; no ActualHerdr Runtime, Human, Release, or credit claimed."}}finally{if($null-ne$read.Stable.Stream){$read.Stable.Stream.Dispose()}}
        }
        $manifest.matrices.($group.Property)=@($items)
    }
    $comparisonPass=$true
    foreach($result in @($manifest.comparison.results)){
        $capture=@($manifest.captures|Where-Object{$_.language-cne$null-and$_.language-ceq$result.language-and$_.name-ceq$result.captureName})
        if($capture.Count-ne1){throw "Pixel comparison '$($result.language)|$($result.captureName)' has no exact capture."}
        $capturePath=Resolve-RendererBoundPath $staging ([string]$capture[0].relativePath) 'Observed pixel capture'
        $referencePath=Join-Path $repo ([string]$result.referenceRelativePath)
        $observed=Get-RendererPngIdentity $staging $capturePath "Observed pixel '$($result.language)|$($result.captureName)'"
        $reference=Get-RendererPngIdentity $repo $referencePath "Reference pixel '$($result.captureName)'"
        $metrics=Compare-RendererPixels $observed $reference @() "$($result.language)|$($result.captureName)"
        $passed=$metrics.DifferentPixelPercent-le[double]$manifest.comparison.tolerance.maximumDifferentPixelPercent-and$metrics.MaximumChannelDelta-le[double]$manifest.comparison.tolerance.perChannelDelta-and$metrics.NonmaskedDifferenceCount-le[long]$manifest.comparison.tolerance.maximumNonmaskedDifferences
        $result.status=if($passed){'PASS'}else{'FAIL'};$result.differentPixels=[long]$metrics.DifferentPixels;$result.differentPixelPercent=[double]$metrics.DifferentPixelPercent;$result.maximumChannelDelta=[double]$metrics.MaximumChannelDelta;$result.nonmaskedDifferenceCount=[long]$metrics.NonmaskedDifferenceCount;$result.disposition=if($passed){'Automated exact decoded-pixel comparison passed REC-ALL v2 tolerance.'}else{'Automated exact decoded-pixel comparison failed REC-ALL v2 tolerance.'}
        if(-not$passed){$comparisonPass=$false}
    }
    if(-not$comparisonPass){throw 'One or more exact decoded-pixel comparisons failed the governed tolerance; no matrix-enriched candidate was published.'}
    Write-RendererPackageCanonicalJson -Value $manifest -Path $stagedManifestPath -RepositoryRoot $repo
    $final=Test-RendererCompatibilityManifest -ManifestPath $stagedManifestPath -EvidenceRoot $staging -RepositoryRoot $repo -ValidateBindings
    if($final.AutomatedMatrixEvidence-cne'PASS'-or$final.ActualHerdrRuntime-cne'NOT_OBSERVED'-or[bool]$final.CreditGranted){throw 'Automated renderer candidate final validation did not preserve matrix/no-credit boundaries.'}
    Assert-RendererStableFileLease $sourceManifestStable $source $manifestPath 'Source renderer manifest before publication'
    $sourceFinal=Test-RendererCompatibilityManifest -ManifestPath $manifestPath -EvidenceRoot $source -RepositoryRoot $repo -ValidateBindings
    if($sourceFinal.ManifestVersion-ne$sourceResult.ManifestVersion-or$sourceFinal.AutomatedMatrixEvidence-cne$sourceResult.AutomatedMatrixEvidence){throw 'Source capture candidate changed during automated matrix collection.'}
    [IO.Directory]::Move($staging,$destination)
    $published=$true
    [pscustomobject][ordered]@{ManifestPath=(Join-Path $destination 'renderer-compatibility-manifest.json');RawDirectory=(Join-Path $destination 'matrix-raw');ReceiptDirectory=(Join-Path $destination 'matrix-receipts');MatrixEvidence='PASS';PixelComparison='PASS';ActualHerdrRuntime='NOT_OBSERVED';HumanReview='NOT_OBSERVED';Release='NOT_OBSERVED';CreditGranted=$false}
}finally{
    if($null-ne$sourceManifestStable.Stream){$sourceManifestStable.Stream.Dispose()}
    if($null-ne$process-and-not$process.HasExited){try{$process.Kill()}catch{}}
    if(-not$published-and(Test-Path -LiteralPath $staging)){Remove-Item -LiteralPath $staging -Recurse -Force}
}
