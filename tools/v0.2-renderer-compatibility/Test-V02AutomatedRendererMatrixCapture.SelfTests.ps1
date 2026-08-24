#requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'RendererCompatibility.Common.ps1')
function ConvertTo-MatrixProcessArgument {param([AllowEmptyString()][string]$Argument);if($null-eq$Argument){$Argument=''};$builder=New-Object Text.StringBuilder;$null=$builder.Append('"');$slashes=0;foreach($character in $Argument.ToCharArray()){if($character-eq[char]92){$slashes++;continue};if($character-eq[char]34){$null=$builder.Append(('\'* (($slashes*2)+1)) -join '');$null=$builder.Append('"');$slashes=0;continue};if($slashes-gt0){$null=$builder.Append(('\'*$slashes)-join'');$slashes=0};$null=$builder.Append([string]$character)};if($slashes-gt0){$null=$builder.Append(('\'*($slashes*2))-join'')};$null=$builder.Append('"');$builder.ToString()}
$repo=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$app=Join-Path $repo 'src/HerdrOps.App/bin/Release/net10.0-windows/HerdrOps.App.exe'
$temp=Join-Path $env:TEMP ('HerdrOps Automated Renderer Matrix '+[guid]::NewGuid().ToString('N'))
function Invoke-Collector([string]$Output,[string]$ErrorPath){
    $arguments=@('--renderer-matrix-output',$Output,'--renderer-matrix-error-path',$ErrorPath,'--renderer-matrix-run-id','matrix-selftest-0001','--renderer-matrix-session-id','session-selftest-0001','--renderer-matrix-candidate-commit',('2'*40),'--renderer-matrix-candidate-tree',('1'*40),'--renderer-matrix-package-receipt-sha256',('A'*64),'--renderer-matrix-operator','@operator','--renderer-matrix-observer','@reviewer')
    $process=Start-Process -FilePath $app -ArgumentList (($arguments|ForEach-Object{ConvertTo-MatrixProcessArgument ([string]$_)})-join' ') -PassThru -WindowStyle Hidden
    if(-not$process.WaitForExit(120000)){try{$process.Kill()}catch{};throw 'Collector self-test timed out.'}
    return $process.ExitCode
}
try{
    if(-not(Test-Path -LiteralPath $app -PathType Leaf)){throw "Build Release App before this focused self-test: '$app'."}
    New-Item -ItemType Directory -Path $temp|Out-Null
    $package=Join-Path $temp 'package';New-Item -ItemType Directory -Path $package|Out-Null;foreach($item in @(Get-ChildItem -LiteralPath ([IO.Path]::GetDirectoryName($app)))){Copy-Item -LiteralPath $item.FullName -Destination $package -Recurse};$app=Join-Path $package 'HerdrOps.App.exe'
    $raw=Join-Path $temp 'matrix-raw';$errorPath=Join-Path $temp 'collector-error.txt'
    $exit=Invoke-Collector $raw $errorPath;if($exit-ne0){throw "Collector exited $exit`: $(if(Test-Path $errorPath){Get-Content $errorPath -Raw}else{'no diagnostic'})"}
    $cases=@(Get-RendererGovernedMatrixCases);if($cases.Count-ne14-or@(Get-ChildItem $raw -Filter '*.json').Count-ne14-or@(Get-ChildItem $raw -Filter '*.png').Count-ne6){throw 'Collector did not emit the exact 14 raw / 6 PNG catalog.'}
    $paths=@{};foreach($case in $cases){$paths[$case]="matrix-raw/$case.json"}
    $receipts=Join-Path $temp 'matrix-receipts';$published=@(& (Join-Path $PSScriptRoot 'New-V02MatrixEvidenceReceipt.ps1') -DestinationPath $receipts -OperatorIdentity '@operator' -OperatorRole EvidenceOperator -ObserverIdentity '@reviewer' -ObserverRole IndependentAgentReviewer -EvidenceBoundary AutomatedPackagedRendering -RawEvidencePaths $paths -EvidenceRoot $temp -RepositoryRoot $repo)
    if($published.Count-ne14){throw 'Collector raw evidence did not publish exactly 14 governed receipts.'}
    $before=@(Get-ChildItem $raw|ForEach-Object{"$($_.Name)|$($_.Length)|$((Get-FileHash $_.FullName -Algorithm SHA256).Hash)"})-join"`n"
    $second=Invoke-Collector $raw (Join-Path $temp 'second-error.txt');if($second-eq0){throw 'Collector overwrote a pre-existing output directory.'}
    $after=@(Get-ChildItem $raw|ForEach-Object{"$($_.Name)|$($_.Length)|$((Get-FileHash $_.FullName -Algorithm SHA256).Hash)"})-join"`n";if($before-cne$after){throw 'Rejected no-clobber invocation mutated prior raw evidence.'}
    [pscustomobject][ordered]@{EvidenceClass='AutomatedPackagedRendering';RawCases=14;PixelArtifacts=6;Receipts=14;ActualHerdrRuntime='NOT_OBSERVED';HumanReview='NOT_OBSERVED';Release='NOT_OBSERVED';CreditGranted=$false}
}finally{if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Recurse -Force}}
