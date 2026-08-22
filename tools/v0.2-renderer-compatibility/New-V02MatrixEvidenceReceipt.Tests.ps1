#requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'RendererCompatibility.Common.ps1')
$scriptPath=Join-Path $PSScriptRoot 'New-V02MatrixEvidenceReceipt.ps1'
$cases=@(
    '1920x1080-100','1920x1080-125','1920x1080-150','1366x768-100','1366x768-125','1366x768-150',
    'mixed-dpi-100-to-150-primary-switch-unplug','mixed-dpi-150-to-100-primary-switch-unplug','mixed-dpi-125-to-150-primary-switch-unplug','mixed-dpi-150-to-125-primary-switch-unplug',
    'keyboard-uia','narrator','high-contrast','text-scale-100','text-scale-150','text-scale-200','reduced-motion-on','reduced-motion-off'
)
$tempBase=Join-Path $env:TEMP "HerdrOps-MatrixTests-$([guid]::NewGuid())"
function Expect-Failure([string]$Name,[scriptblock]$Action){$failed=$false;try{&$Action}catch{$failed=$true};if(-not$failed){throw "Expected hostile '$Name' to fail."};Write-Host "PASS negative: $Name"}
function Copy-Map($Map){$copy=@{};foreach($key in $Map.Keys){$copy[$key]=$Map[$key]};return $copy}
try{
    New-Item -Path $tempBase -ItemType Directory|Out-Null
    $evidenceRoot=Join-Path $tempBase 'evidence';$rawRoot=Join-Path $evidenceRoot 'raw';New-Item -Path $rawRoot -ItemType Directory -Force|Out-Null
    $outcomes=@{};$rawPaths=@{}
    foreach($case in $cases){$outcomes[$case]='PASS';$relative="raw/$case.bin";$rawPaths[$case]=$relative;[IO.File]::WriteAllBytes((Join-Path $evidenceRoot $relative),[Text.Encoding]::UTF8.GetBytes("held raw evidence $case"))}
    $common=@{OperatorIdentity='@operator';OperatorRole='EvidenceOperator';ObserverIdentity='@observer';ObserverRole='IndependentObserver';EvidenceBoundary='Synthetic';Outcomes=$outcomes;RawEvidencePaths=$rawPaths;ObservedUtc='2026-08-22T12:00:00.0000000+00:00';EvidenceRoot=$evidenceRoot;RepositoryRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path}

    $destination=Join-Path $evidenceRoot 'receipts';$files=@(&$scriptPath -DestinationPath $destination @common)
    if($files.Count-ne18){throw 'Expected exactly 18 published receipts.'}
    foreach($file in $files){$value=Get-Content -LiteralPath $file -Raw|ConvertFrom-Json;if($value.outcome-cne'PASS'-or$value.operator.role-cne'EvidenceOperator'-or$value.observer.role-cne'IndependentObserver'-or$value.evidenceBoundary.finalHumanGo-cne'NOT_OBSERVED'-or$value.evidenceBoundary.release-cne'NOT_OBSERVED'-or[bool]$value.evidenceBoundary.creditGranted){throw 'Published receipt inflated authority or omitted role/outcome.'};Assert-RendererFileBinding $value.rawEvidence 'Published raw evidence' $evidenceRoot -ValidateBindings}
    Write-Host 'PASS positive: exact atomic 18-set with held raw bindings'

    Expect-Failure 'pre-existing destination no-clobber' { &$scriptPath -DestinationPath $destination @common }
    $crashDestination=Join-Path $evidenceRoot 'crash';Expect-Failure 'pre-publication crash rollback' { &$scriptPath -DestinationPath $crashDestination @common -SimulateFailureAfterReceiptCount 9 }
    if(Test-Path -LiteralPath $crashDestination){throw 'Crash simulation published a partial destination.'}
    if(@(Get-ChildItem -LiteralPath $evidenceRoot -Directory -Filter '.matrix-receipts-staging-*').Count-ne0){throw 'Crash simulation left a staging directory.'}

    $bad=Copy-Map $outcomes;$bad.Remove($cases[0]);$hostile=Copy-Map $common;$hostile.Outcomes=$bad;Expect-Failure 'missing governed case ID' { &$scriptPath -DestinationPath (Join-Path $evidenceRoot 'missing-id') @hostile }
    $bad=Copy-Map $outcomes;$bad.Remove($cases[0]);$bad['WRONG-ID']='PASS';$hostile=Copy-Map $common;$hostile.Outcomes=$bad;Expect-Failure 'wrong governed case ID' { &$scriptPath -DestinationPath (Join-Path $evidenceRoot 'wrong-id') @hostile }
    $bad=Copy-Map $outcomes;$bad[$cases[0]]='pass';$hostile=Copy-Map $common;$hostile.Outcomes=$bad;Expect-Failure 'noncanonical outcome' { &$scriptPath -DestinationPath (Join-Path $evidenceRoot 'bad-outcome') @hostile }
    $hostile=Copy-Map $common;$hostile.ObserverIdentity='@operator';Expect-Failure 'same operator observer identity' { &$scriptPath -DestinationPath (Join-Path $evidenceRoot 'same-id') @hostile }
    $hostile=Copy-Map $common;$hostile.EvidenceBoundary='Release';Expect-Failure 'Release evidence inflation' { &$scriptPath -DestinationPath (Join-Path $evidenceRoot 'release') @hostile }
    $hostile=Copy-Map $common;$hostile.ObservedUtc='2026-08-22T12:00:00Z';Expect-Failure 'noncanonical caller UTC' { &$scriptPath -DestinationPath (Join-Path $evidenceRoot 'utc') @hostile }
    $bad=Copy-Map $rawPaths;$bad[$cases[0]]='../escape.bin';$hostile=Copy-Map $common;$hostile.RawEvidencePaths=$bad;Expect-Failure 'raw traversal path' { &$scriptPath -DestinationPath (Join-Path $evidenceRoot 'traversal') @hostile }
    $bad=Copy-Map $rawPaths;$bad[$cases[0]]='raw/missing.bin';$hostile=Copy-Map $common;$hostile.RawEvidencePaths=$bad;Expect-Failure 'missing raw evidence' { &$scriptPath -DestinationPath (Join-Path $evidenceRoot 'missing-raw') @hostile }
    Expect-Failure 'destination path escape' { &$scriptPath -DestinationPath (Join-Path $tempBase 'outside') @common }

    $tamperedReceipt=Get-Content -LiteralPath $files[0] -Raw|ConvertFrom-Json;$tamperedReceipt.rawEvidence.sha256='A'*64
    Expect-Failure 'consumer rejects tampered raw hash' { Assert-RendererFileBinding $tamperedReceipt.rawEvidence 'Tampered raw evidence' $evidenceRoot -ValidateBindings }
    [IO.File]::AppendAllText((Join-Path $evidenceRoot $rawPaths[$cases[1]]),'tamper');$tamperedBytesFile=@($files|Where-Object{(Get-Content -LiteralPath $_ -Raw|ConvertFrom-Json).caseId-ceq$cases[1]})[0];$tamperedBytesReceipt=Get-Content -LiteralPath $tamperedBytesFile -Raw|ConvertFrom-Json
    Expect-Failure 'consumer rejects changed raw bytes' { Assert-RendererFileBinding $tamperedBytesReceipt.rawEvidence 'Changed raw evidence' $evidenceRoot -ValidateBindings }

    $linkRoot=Join-Path $evidenceRoot 'link-hostile';New-Item -Path $linkRoot -ItemType Directory|Out-Null;$link=Join-Path $linkRoot 'raw-link';$linkMade=$false
    try{New-Item -ItemType SymbolicLink -Path $link -Target $rawRoot -ErrorAction Stop|Out-Null;$linkMade=$true}catch{Write-Host 'INFO symbolic-link hostile unavailable on this host'}
    if($linkMade){$bad=Copy-Map $rawPaths;$bad[$cases[0]]='link-hostile/raw-link/'+$cases[0]+'.bin';$hostile=Copy-Map $common;$hostile.RawEvidencePaths=$bad;Expect-Failure 'raw reparse point' { &$scriptPath -DestinationPath (Join-Path $evidenceRoot 'reparse') @hostile }}
    Write-Host "All matrix receipt tests passed for PowerShell $($PSVersionTable.PSVersion)."
}finally{if(Test-Path -LiteralPath $tempBase){Remove-Item -LiteralPath $tempBase -Recurse -Force}}
