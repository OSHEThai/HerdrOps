[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ThaiEvidenceDirectory,
    [Parameter(Mandatory)][string]$EnglishEvidenceDirectory,
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

function Read-MatrixRun {
    param([Parameter(Mandatory)][string]$EvidenceDirectory,[Parameter(Mandatory)][ValidateSet('Thai','English')][string]$ExpectedLanguage)
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
    if ((Get-MatrixProperty $core 'RuntimeObserved' "$ExpectedLanguage core report") -isnot [bool] -or -not [bool]$core.RuntimeObserved) { throw "$ExpectedLanguage Core report did not observe Runtime." }

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
    Assert-MatrixEqual (Get-MatrixGateValue $gate 'HerdrReleaseId' $ExpectedLanguage) $herdrRelease "$ExpectedLanguage Herdr release"
    Assert-MatrixEqual (Assert-MatrixSha256 (Get-MatrixGateValue $gate 'HerdrExecutableSha256' $ExpectedLanguage) "$ExpectedLanguage gate Herdr hash") $herdrSha "$ExpectedLanguage Herdr hash"
    Assert-MatrixEqual (Assert-MatrixSha256 (Get-MatrixGateValue $gate 'BundledSchemaSha256' $ExpectedLanguage) "$ExpectedLanguage gate schema hash") $schemaSha "$ExpectedLanguage schema hash"
    Assert-MatrixEqual (Get-MatrixGateValue $gate 'HerdrProtocol' $ExpectedLanguage) $protocol "$ExpectedLanguage protocol"

    $resource=Get-MatrixProperty $app 'ResourceMeasurement' "$ExpectedLanguage app report";$appResource=Get-MatrixProperty $resource 'App' "$ExpectedLanguage resource report";$coreResource=Get-MatrixProperty $resource 'Core' "$ExpectedLanguage resource report"
    $appBinary=Assert-MatrixSha256 (Get-MatrixProperty $appResource 'ExecutableSha256' "$ExpectedLanguage App resource") "$ExpectedLanguage App report binary";$coreBinary=Assert-MatrixSha256 (Get-MatrixProperty $coreResource 'ExecutableSha256' "$ExpectedLanguage Core resource") "$ExpectedLanguage Core report binary"
    foreach($pair in @(@('HerdrOpsAppExecutableSha256BeforeLaunch',$appBinary),@('HerdrOpsAppExecutableSha256AfterRun',$appBinary),@('HerdrOpsAppExecutableSha256BoundToReports',$appBinary),@('HerdrOpsCoreExecutableSha256BeforeLaunch',$coreBinary),@('HerdrOpsCoreExecutableSha256AfterRun',$coreBinary),@('HerdrOpsCoreExecutableSha256BoundToReports',$coreBinary))) {
        Assert-MatrixEqual (Assert-MatrixSha256 (Get-MatrixGateValue $gate $pair[0] $ExpectedLanguage) "$ExpectedLanguage $($pair[0])") $pair[1] "$ExpectedLanguage $($pair[0])"
    }

    $identity=@{};foreach($name in @('ExpectedSourceCommit','SourceCommit','PreRunSourceCommit','PostRunSourceCommit')) { $value=Get-MatrixGateValue $gate $name $ExpectedLanguage;if($value -notmatch '^[0-9a-f]{40}$'){throw "$ExpectedLanguage $name is not a normalized Git commit."};$identity[$name]=$value }
    foreach($name in @('ExpectedSourceTree','SourceTree','PreRunSourceTree','PostRunSourceTree')) { $value=Get-MatrixGateValue $gate $name $ExpectedLanguage;if($value -notmatch '^[0-9a-f]{40}$'){throw "$ExpectedLanguage $name is not a normalized Git tree."};$identity[$name]=$value }
    foreach($name in @('SourceCommit','PreRunSourceCommit','PostRunSourceCommit')) { Assert-MatrixEqual $identity[$name] $identity.ExpectedSourceCommit "$ExpectedLanguage commit binding $name" }
    foreach($name in @('SourceTree','PreRunSourceTree','PostRunSourceTree')) { Assert-MatrixEqual $identity[$name] $identity.ExpectedSourceTree "$ExpectedLanguage tree binding $name" }

    $captures=@(Get-MatrixProperty $app 'Captures' "$ExpectedLanguage app report");if($captures.Count -lt 8){throw "$ExpectedLanguage capture set has fewer than eight captures."}
    $captureByName=@{};$captureRoots=@{}
    foreach($capture in $captures) {
        $name=[string](Get-MatrixProperty $capture 'Name' "$ExpectedLanguage capture");if([string]::IsNullOrWhiteSpace($name)-or$captureByName.ContainsKey($name)){throw "$ExpectedLanguage capture names must be nonempty and unique."}
        $declared=Assert-MatrixSha256 (Get-MatrixProperty $capture 'Sha256' "$ExpectedLanguage capture '$name'") "$ExpectedLanguage capture '$name' hash";$path=[string](Get-MatrixProperty $capture 'Path' "$ExpectedLanguage capture '$name'")
        if(-not [IO.Path]::IsPathRooted($path)-or-not(Test-Path -LiteralPath $path -PathType Leaf)){throw "$ExpectedLanguage capture '$name' path is missing or not absolute."}
        $resolved=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $path).Path);if(-not(Test-MatrixPathWithin $resolved $EvidenceDirectory)){throw "$ExpectedLanguage capture '$name' is outside its evidence directory."}
        Assert-MatrixEqual (Get-FileHash -LiteralPath $resolved -Algorithm SHA256).Hash.ToUpperInvariant() $declared "$ExpectedLanguage capture '$name' hash"
        $captureByName[$name]=[pscustomobject]@{Name=$name;Path=$resolved;Sha256=$declared};$captureRoots[[IO.Path]::GetDirectoryName($resolved)]=$true
    }
    if($captureRoots.Count -ne 1){throw "$ExpectedLanguage captures must have one exact capture root."}
    $gateCaptures=@($gate.CaptureDeclarations);if($gateCaptures.Count -ne $captures.Count){throw "$ExpectedLanguage gate capture declaration count differs from App report."}
    $seen=@{};foreach($decl in $gateCaptures){if($seen.ContainsKey($decl.Name)-or-not$captureByName.ContainsKey($decl.Name)){throw "$ExpectedLanguage gate capture names are duplicated or unknown."};Assert-MatrixEqual $decl.Sha256 $captureByName[$decl.Name].Sha256 "$ExpectedLanguage gate capture '$($decl.Name)'";$seen[$decl.Name]=$true}

    return [pscustomobject]@{Language=$ExpectedLanguage;EvidenceDirectory=$EvidenceDirectory;CaptureRoot=[string]@($captureRoots.Keys)[0];GateReportSha256=(Get-FileHash $gatePath -Algorithm SHA256).Hash.ToUpperInvariant();AppRuntimeReportSha256=$actualAppReportHash;CoreRuntimeReportSha256=$actualCoreReportHash;SourceCommit=$identity.ExpectedSourceCommit;SourceTree=$identity.ExpectedSourceTree;ProfileId=$profileId;ProfileSha256=$profileSha;ReferenceHostSchemaSha256=$referenceHostSchemaSha;HerdrReleaseId=$herdrRelease;HerdrExecutableSha256=$herdrSha;AppExecutableSha256=$appBinary;CoreExecutableSha256=$coreBinary;BundledSchemaSha256=$schemaSha;HerdrProtocol=$protocol;RendererPolicyId=$rendererPolicy;WpfProcessRenderMode=$renderMode;CaptureCount=$captures.Count;Captures=@($captureByName.Values|Sort-Object Name)}
}

$thaiDirectory=Get-MatrixFullDirectory $ThaiEvidenceDirectory 'ThaiEvidenceDirectory';$englishDirectory=Get-MatrixFullDirectory $EnglishEvidenceDirectory 'EnglishEvidenceDirectory'
Assert-MatrixDistinctTrees $thaiDirectory $englishDirectory 'Thai and English evidence directories'
$thai=Read-MatrixRun $thaiDirectory 'Thai';$english=Read-MatrixRun $englishDirectory 'English'
Assert-MatrixDistinctTrees $thai.CaptureRoot $english.CaptureRoot 'Thai and English capture roots'
foreach($name in @('SourceCommit','SourceTree','ProfileId','ProfileSha256','ReferenceHostSchemaSha256','HerdrReleaseId','HerdrExecutableSha256','AppExecutableSha256','CoreExecutableSha256','BundledSchemaSha256','HerdrProtocol','RendererPolicyId','WpfProcessRenderMode')) { Assert-MatrixEqual $thai.$name $english.$name "Thai/English $name" }

if([string]::IsNullOrWhiteSpace($OutputPath)){ $OutputPath=Join-Path ([IO.Path]::GetDirectoryName($thaiDirectory)) 'v0.2-language-matrix-candidate.json' }
$outputFull=[IO.Path]::GetFullPath($OutputPath);if((Test-MatrixPathWithin $outputFull $thaiDirectory)-or(Test-MatrixPathWithin $outputFull $englishDirectory)){throw 'OutputPath must be outside both accepted evidence directory trees.'};if(Test-Path -LiteralPath $outputFull){throw "OutputPath already exists: $outputFull"}
$payload=[ordered]@{GeneratedUnixTimeMilliseconds=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds();IndependentHumanReview='NOT_OBSERVED';ReleaseCredit=$false;Binding=[ordered]@{SourceCommit=$thai.SourceCommit;SourceTree=$thai.SourceTree;ProfileId=$thai.ProfileId;ProfileSha256=$thai.ProfileSha256;ReferenceHostSchemaSha256=$thai.ReferenceHostSchemaSha256;HerdrReleaseId=$thai.HerdrReleaseId;HerdrExecutableSha256=$thai.HerdrExecutableSha256;AppExecutableSha256=$thai.AppExecutableSha256;CoreExecutableSha256=$thai.CoreExecutableSha256;BundledSchemaSha256=$thai.BundledSchemaSha256;HerdrProtocol=$thai.HerdrProtocol};Runs=@($thai,$english)}
$payloadValue=(($payload|ConvertTo-Json -Depth 20)|ConvertFrom-Json);$payloadJson=ConvertTo-V02Jcs $payloadValue;$utf8=New-Object Text.UTF8Encoding($false);$payloadSha=([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($utf8.GetBytes($payloadJson)))).Replace('-','')
$manifest=[ordered]@{EvidenceClassification='RuntimeMatrixCandidate';IndependentHumanReview='NOT_OBSERVED';ReleaseCredit=$false;ManifestFormatVersion=1;ManifestHashScope='SHA256OfRFC8785JcsUtf8NoBomPayload';ManifestPayloadSha256=$payloadSha;Payload=$payloadValue}
$json=$manifest|ConvertTo-Json -Depth 20;$parent=[IO.Path]::GetDirectoryName($outputFull);if(-not[IO.Directory]::Exists($parent)){[IO.Directory]::CreateDirectory($parent)|Out-Null}
$temporary=Join-Path $parent ('.'+[IO.Path]::GetFileName($outputFull)+'.'+[Guid]::NewGuid().ToString('N')+'.tmp')
try{[IO.File]::WriteAllText($temporary,$json,$utf8);Move-Item -LiteralPath $temporary -Destination $outputFull}catch{if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force};throw}
$fileSha=(Get-FileHash -LiteralPath $outputFull -Algorithm SHA256).Hash.ToUpperInvariant()
Write-Output 'EvidenceClass: RuntimeMatrixCandidate';Write-Output "Manifest: $outputFull";Write-Output "ManifestPayloadSha256: $payloadSha";Write-Output "ManifestFileSha256: $fileSha";Write-Output 'IndependentHumanReview: NOT_OBSERVED';Write-Output 'ReleaseCredit: false'
