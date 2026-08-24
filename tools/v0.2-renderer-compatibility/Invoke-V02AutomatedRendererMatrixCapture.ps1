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
function Copy-MatrixHeldCandidate {
    param([string]$Source,[string]$Destination,[System.Collections.ArrayList]$HeldFiles)
    $entries=@(Get-ChildItem -LiteralPath $Source -Force -Recurse -ErrorAction Stop|Sort-Object FullName)
    if($entries.Count-gt4096){throw 'Capture candidate exceeds the bounded 4096-entry copy inventory.'}
    [long]$totalBytes=0
    foreach($entry in $entries){
        if(($entry.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){throw "Capture candidate contains prohibited reparse entry '$($entry.FullName)'."}
        $relative=$entry.FullName.Substring($Source.Length).TrimStart('\','/')
        $target=Join-Path $Destination $relative
        if($entry.PSIsContainer){New-Item -ItemType Directory -Path $target -ErrorAction Stop|Out-Null;continue}
        $held=Get-RendererStableFileIdentity $Source $entry.FullName "Capture candidate '$relative'" -KeepOpen
        $null=$HeldFiles.Add([pscustomobject]@{Path=$entry.FullName;Stable=$held})
        $totalBytes+=[long]$held.Bytes;if($totalBytes-gt2147483648){throw 'Capture candidate exceeds the bounded 2 GiB copy inventory.'}
        $parent=Split-Path -Parent $target;if(-not(Test-Path -LiteralPath $parent)){New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop|Out-Null}
        $held.Stream.Position=0;$output=[IO.File]::Open($target,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try{$held.Stream.CopyTo($output);$output.Flush($true)}finally{$output.Dispose()}
        $copied=Get-RendererStableFileIdentity $Destination $target "Copied candidate '$relative'"
        if($copied.Bytes-ne$held.Bytes-or$copied.Sha256-cne$held.Sha256){throw "Copied candidate '$relative' changed from the held source bytes."}
    }
}
function Assert-MatrixObservedProcess {
    param($Payload,$Expected,[string]$ExpectedRelativePath,[string]$RunId,[string]$SessionId,[string]$Context)
    $p=$Payload.provenance.session
    if([int]$p.processId-ne[int]$Expected.pid-or[string]$p.processStartUtc-cne[string]$Expected.startTimeUtc-or[string]$p.executableRelativePath-cne$ExpectedRelativePath-or[string]$p.executableSha256-cne[string]$Expected.sha256){throw "$Context process PID/start/path/hash does not equal the independently observed launched App."}
    if([string]$Payload.run.runId-cne$RunId-or[string]$Payload.run.sessionId-cne$SessionId){throw "$Context run/session does not equal the orchestrator-owned invocation."}
}

if([string]::IsNullOrWhiteSpace($RepositoryRoot)){$RepositoryRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path}
$repo=[IO.Path]::GetFullPath($RepositoryRoot).TrimEnd('\','/')
$source=[IO.Path]::GetFullPath($CaptureCandidateDirectory).TrimEnd('\','/')
$destination=[IO.Path]::GetFullPath($DestinationDirectory).TrimEnd('\','/')
$destinationParent=[IO.Path]::GetDirectoryName($destination)
if($source-ceq$destination-or$source.StartsWith($destination+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)-or$destination.StartsWith($source+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'CaptureCandidateDirectory and DestinationDirectory must be disjoint.'}
if(-not(Test-Path -LiteralPath $source -PathType Container)){throw 'CaptureCandidateDirectory is missing.'}
if(Test-Path -LiteralPath $destination){throw 'DestinationDirectory already exists; automated matrix publication is no-clobber.'}
Assert-RendererString $OperatorIdentity 'OperatorIdentity';Assert-RendererString $IndependentReviewerIdentity 'IndependentReviewerIdentity'
if($OperatorIdentity.Trim().Equals($IndependentReviewerIdentity.Trim(),[StringComparison]::OrdinalIgnoreCase)){throw 'Operator and independent reviewer identities must be distinct.'}
Assert-RendererNonReparsePath $repo $repo 'RepositoryRoot'
Assert-RendererNonReparsePath $source $source 'CaptureCandidateDirectory'
if(-not(Test-Path -LiteralPath $destinationParent -PathType Container)){New-Item -ItemType Directory -Path $destinationParent -ErrorAction Stop|Out-Null}
Assert-RendererNonReparsePath $destinationParent $destinationParent 'Destination parent'

$manifestPath=Join-Path $source 'v0.2-renderer-compatibility-manifest.json'
$staging=Join-Path ([IO.Path]::GetDirectoryName($destination)) ('.renderer-matrix-candidate-staging-'+[guid]::NewGuid().ToString('N'))
$sourceFiles=New-Object System.Collections.ArrayList;$rawLeases=New-Object System.Collections.ArrayList
$published=$false;$process=$null;$stagingLease=$null;$appStable=$null;$sourceManifestStable=$null;$sourceLease=$null;$parentLease=$null
try{
    $sourceManifestStable=Get-RendererStableFileIdentity $source $manifestPath 'Source renderer manifest' -IncludeBytes -KeepOpen
    $sourceLease=Open-RendererDirectoryLease $source $source 'Capture candidate directory'
    $parentLease=Open-RendererDirectoryLease $destinationParent $destinationParent 'Destination parent'
    $sourceResult=Test-RendererCompatibilityManifest -ManifestPath $manifestPath -EvidenceRoot $source -RepositoryRoot $repo -ValidateBindings
    Assert-RendererStableFileLease $sourceManifestStable $source $manifestPath 'Source renderer manifest after validation'
    if($sourceResult.ManifestVersion-ne4-or$sourceResult.ActualHerdrRuntime-cne'NOT_OBSERVED'-or[bool]$sourceResult.CreditGranted){throw 'Capture candidate is not an uncredited manifest-v4 automated packaged candidate.'}
    New-Item -ItemType Directory -Path $staging -ErrorAction Stop|Out-Null
    $stagingLease=Open-RendererDirectoryLease $destinationParent $staging 'Automated matrix staging' -AllowDelete
    Copy-MatrixHeldCandidate $source $staging $sourceFiles
    $stagedManifestPath=Join-Path $staging 'v0.2-renderer-compatibility-manifest.json'
    $manifestJson=Get-Content -LiteralPath $stagedManifestPath -Raw
    $manifest=ConvertFrom-StrictHumanDesignReviewJson -Json $manifestJson -Description 'Staged renderer manifest'
    if($PSVersionTable.PSVersion.Major-ge7-and(Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')){$manifest=$manifestJson|ConvertFrom-Json -DateKind String}
    $appPath=Join-Path (Resolve-RendererBoundPath $staging ([string]$manifest.candidate.packageRootRelativePath) 'Packaged root') ([string]$manifest.candidate.components.app.relativePath)
    $appStable=Get-RendererStableFileIdentity $staging $appPath 'Packaged App' -KeepOpen
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
    $observedProcess=Get-RendererProcessIdentity $process.Id $appPath 'Automated matrix App'
    if(-not$process.WaitForExit($TimeoutSeconds*1000)){try{$process.Kill()}catch{};throw "Packaged App automated renderer collector exceeded $TimeoutSeconds seconds."}
    if($process.ExitCode-ne0){$detail=if(Test-Path -LiteralPath $collectorError){Get-Content -LiteralPath $collectorError -Raw}else{'No collector diagnostic was emitted.'};throw "Packaged App automated renderer collector exited $($process.ExitCode): $detail"}
    Assert-RendererStableFileLease $appStable $staging $appPath 'Packaged App after collector exit'
    $expectedExecutableRelative=$appPath.Substring($staging.Length).TrimStart('\','/').Replace('\','/')
    $rawPaths=@{};foreach($case in @(Get-RendererGovernedMatrixCases)){
        $relative="matrix-raw/$case.json";$rawPaths[$case]=$relative;$rawPath=Join-Path $staging $relative
        $held=Get-RendererStableFileIdentity $staging $rawPath "Matrix raw '$case'" -IncludeBytes -KeepOpen;$null=$rawLeases.Add([pscustomobject]@{Path=$rawPath;Stable=$held})
        $json=(New-Object Text.UTF8Encoding($false,$true)).GetString($held.Content);$payload=ConvertFrom-StrictHumanDesignReviewJson $json "Matrix raw '$case'";if($PSVersionTable.PSVersion.Major-ge7-and(Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')){$payload=$json|ConvertFrom-Json -DateKind String}
        Assert-MatrixObservedProcess $payload $observedProcess $expectedExecutableRelative $runId $sessionId "Matrix raw '$case'"
    }
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
    $manifestBytes=(New-Object Text.UTF8Encoding($false)).GetBytes(($manifest|ConvertTo-Json -Depth 80))
    $manifestOutput=[IO.File]::Open($stagedManifestPath,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$manifestOutput.Write($manifestBytes,0,$manifestBytes.Length);$manifestOutput.Flush($true)}finally{$manifestOutput.Dispose()}
    $final=Test-RendererCompatibilityManifest -ManifestPath $stagedManifestPath -EvidenceRoot $staging -RepositoryRoot $repo -ValidateBindings
    if($final.AutomatedMatrixEvidence-cne'PASS'-or$final.ActualHerdrRuntime-cne'NOT_OBSERVED'-or[bool]$final.CreditGranted){throw 'Automated renderer candidate final validation did not preserve matrix/no-credit boundaries.'}
    Assert-RendererStableFileLease $sourceManifestStable $source $manifestPath 'Source renderer manifest before publication'
    foreach($held in $sourceFiles){Assert-RendererStableFileLease $held.Stable $source $held.Path 'Source candidate before publication'}
    foreach($held in $rawLeases){Assert-RendererStableFileLease $held.Stable $staging $held.Path 'Matrix raw before publication'}
    $sourceFinal=Test-RendererCompatibilityManifest -ManifestPath $manifestPath -EvidenceRoot $source -RepositoryRoot $repo -ValidateBindings
    if($sourceFinal.ManifestVersion-ne$sourceResult.ManifestVersion-or$sourceFinal.AutomatedMatrixEvidence-cne$sourceResult.AutomatedMatrixEvidence){throw 'Source capture candidate changed during automated matrix collection.'}
    if(Test-Path -LiteralPath $destination){throw 'DestinationDirectory appeared concurrently; automated matrix publication is no-clobber.'}
    if($null-ne$appStable.Stream){$appStable.Stream.Dispose()}
    foreach($held in $rawLeases){if($null-ne$held.Stable.Stream){$held.Stable.Stream.Dispose()}}
    Assert-RendererDirectoryLease $parentLease $destinationParent $destinationParent 'Destination parent before publication'
    Move-RendererLeasedDirectory $stagingLease $destinationParent $staging $destination 'Automated matrix publication'
    $staging=$destination
    Assert-RendererDirectoryLease $parentLease $destinationParent $destinationParent 'Destination parent after publication'
    $publishedResult=Test-RendererCompatibilityManifest -ManifestPath (Join-Path $destination 'v0.2-renderer-compatibility-manifest.json') -EvidenceRoot $destination -RepositoryRoot $repo -ValidateBindings
    if($publishedResult.AutomatedMatrixEvidence-cne'PASS'-or[bool]$publishedResult.CreditGranted){throw 'Published automated matrix candidate failed final validation.'}
    $published=$true
    [pscustomobject][ordered]@{ManifestPath=(Join-Path $destination 'v0.2-renderer-compatibility-manifest.json');RawDirectory=(Join-Path $destination 'matrix-raw');ReceiptDirectory=(Join-Path $destination 'matrix-receipts');MatrixEvidence='PASS';PixelComparison='PASS';ActualHerdrRuntime='NOT_OBSERVED';HumanReview='NOT_OBSERVED';Release='NOT_OBSERVED';CreditGranted=$false}
}finally{
    if($null-ne$sourceManifestStable.Stream){$sourceManifestStable.Stream.Dispose()}
    if($null-ne$appStable-and$null-ne$appStable.Stream){$appStable.Stream.Dispose()}
    foreach($held in $sourceFiles){if($null-ne$held.Stable.Stream){$held.Stable.Stream.Dispose()}}
    foreach($held in $rawLeases){if($null-ne$held.Stable.Stream){$held.Stable.Stream.Dispose()}}
    if($null-ne$process-and-not$process.HasExited){try{$process.Kill()}catch{}}
    if(-not$published-and$null-ne$staging-and(Test-Path -LiteralPath $staging)-and$null-ne$stagingLease){Remove-RendererOwnedStagingTree $stagingLease $destinationParent $staging 'Failed automated matrix staging'}elseif($null-ne$stagingLease-and$null-ne$stagingLease.Handle-and-not$stagingLease.Handle.IsClosed){$stagingLease.Handle.Dispose()}
    if($null-ne$sourceLease-and$null-ne$sourceLease.Handle){$sourceLease.Handle.Dispose()}
    if($null-ne$parentLease-and$null-ne$parentLease.Handle){$parentLease.Handle.Dispose()}
}
