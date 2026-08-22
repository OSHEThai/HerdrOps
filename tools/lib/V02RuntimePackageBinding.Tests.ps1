#requires -Version 5.1
[CmdletBinding()] param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'V02RuntimePackageBinding.ps1')

$failures = New-Object 'System.Collections.Generic.List[string]'
function Test-Case([string]$Name,[scriptblock]$Body,[bool]$ShouldThrow=$false) {
    try { & $Body; if($ShouldThrow){throw 'Expected failure was not observed.'}; Write-Host "PASS: $Name" }
    catch { if($ShouldThrow){Write-Host "PASS: $Name"}else{$failures.Add("$Name`: $($_.Exception.Message)");Write-Host "FAIL: $Name" -ForegroundColor Red} }
}
function New-Result {
    $s='A'*64
    [pscustomobject][ordered]@{ EvidenceClass='Static/PackagedCompatibilityPreparation';Issue=149;ProfileId='p';ReceiptSha256=$s;SourceCommit='1'*40;SourceTree='2'*40;PreparationProfileFileSha256=$s;PreparationProfileCanonicalSha256=$s;ArchiveSha256=$s;AppSha256=$s;CoreSha256=$s;ReferenceHostProfileSha256=$s;RendererPolicySha256=$s;Runtime='NOT OBSERVED';Release='NOT CLAIMED' }
}
Test-Case 'exact validator result accepted' { Assert-V02RuntimePackageValidationResult (New-Result) ('1'*40) ('2'*40) }
Test-Case 'wrong source commit fails closed' { $r=New-Result;$r.SourceCommit='3'*40;Assert-V02RuntimePackageValidationResult $r ('1'*40) ('2'*40) } $true
Test-Case 'wrong source tree fails closed' { $r=New-Result;$r.SourceTree='3'*40;Assert-V02RuntimePackageValidationResult $r ('1'*40) ('2'*40) } $true
Test-Case 'lowercase hash fails closed' { $r=New-Result;$r.AppSha256='a'*64;Assert-V02RuntimePackageValidationResult $r ('1'*40) ('2'*40) } $true
Test-Case 'runtime claim from preparation validator fails closed' { $r=New-Result;$r.Runtime='OBSERVED';Assert-V02RuntimePackageValidationResult $r ('1'*40) ('2'*40) } $true
Test-Case 'numeric-string issue fails closed' { $r=New-Result;$r.Issue='149';Assert-V02RuntimePackageValidationResult $r ('1'*40) ('2'*40) } $true
Test-Case 'unknown validator property fails closed' { $r=New-Result;$r|Add-Member Extra x;Assert-V02RuntimePackageValidationResult $r ('1'*40) ('2'*40) } $true
Test-Case 'missing validator property fails closed' { $r=New-Result;$r.PSObject.Properties.Remove('ArchiveSha256');Assert-V02RuntimePackageValidationResult $r ('1'*40) ('2'*40) } $true
Test-Case 'blank target Agent session attestation fails closed' { New-V02TargetAgentSessionAttestation ' ' } $true
Test-Case 'multiline target Agent session attestation fails closed' { New-V02TargetAgentSessionAttestation "a`nb" } $true
Test-Case 'operator attestation boundary is explicit' { $a=New-V02TargetAgentSessionAttestation 'opencode:session-1';if($a.EvidenceSource -cne 'OperatorAttestation' -or $a.ObservableByGate -ne $false){throw 'Attestation boundary changed.'} }
Test-Case 'missing package binding inputs fail closed before validation' { Resolve-V02RuntimePackageBinding -IdentityPath 'Z:\definitely-missing-v02-receipt.json' -ArchivePath 'Z:\definitely-missing-v02.zip' -PackageRoot 'Z:\definitely-missing-v02-root' -RepositoryRoot $PSScriptRoot -ProfilePath $PSCommandPath -ExpectedSourceCommit ('1'*40) -ExpectedSourceTree ('2'*40) } $true

$temp = Join-Path ([IO.Path]::GetTempPath()) ('v02-trx-binding-' + [guid]::NewGuid().ToString('N'))
try {
    $results=Join-Path $temp 'results';$evidence=Join-Path $temp 'evidence';New-Item -ItemType Directory $results,$evidence|Out-Null
    $started=[DateTime]::UtcNow.AddSeconds(-1)
    $template='<?xml version="1.0"?><TestRun><ResultSummary><Counters total="1" passed="1" failed="0" /></ResultSummary></TestRun>'
    1..4|ForEach-Object{[IO.File]::WriteAllText((Join-Path $results "test$_.trx"),$template)}
    Test-Case 'four fresh passing TRX files are preserved with receipt' { $x=Save-V02FreshTrxEvidence $results $started $evidence;if($x.Passed-ne 4-or-not(Test-Path -LiteralPath $x.ReceiptPath)){throw 'TRX receipt missing.'};foreach($f in $x.Files){Assert-V02RuntimeBindingSha256 $f.Sha256 'TRX hash'} }
    Test-Case 'existing TRX evidence directory fails closed' { Save-V02FreshTrxEvidence $results $started $evidence } $true
    Remove-Item -LiteralPath (Join-Path $evidence 'test-results') -Recurse -Force
    Remove-Item -LiteralPath (Join-Path $results 'test4.trx')
    Test-Case 'three fresh TRX files fail closed' { Save-V02FreshTrxEvidence $results $started $evidence } $true
    [IO.File]::WriteAllText((Join-Path $results 'test4.trx'),$template.Replace('failed="0"','failed="1"'))
    Test-Case 'failed TRX counter fails closed' { Save-V02FreshTrxEvidence $results $started $evidence } $true
    $bindingFiles=@{};foreach($name in @('identity','archive','manifest','app','core')){$path=Join-Path $temp "$name.bin";[IO.File]::WriteAllText($path,"original-$name");$bindingFiles[$name]=$path}
    $binding=[pscustomobject]@{
        IdentityPath=$bindingFiles.identity;IdentityFileSha256=(Get-FileHash $bindingFiles.identity -Algorithm SHA256).Hash
        ArchivePath=$bindingFiles.archive;ArchiveSha256=(Get-FileHash $bindingFiles.archive -Algorithm SHA256).Hash
        ManifestPath=$bindingFiles.manifest;ManifestSha256=(Get-FileHash $bindingFiles.manifest -Algorithm SHA256).Hash
        AppPath=$bindingFiles.app;AppSha256=(Get-FileHash $bindingFiles.app -Algorithm SHA256).Hash
        CorePath=$bindingFiles.core;CoreSha256=(Get-FileHash $bindingFiles.core -Algorithm SHA256).Hash
    }
    Test-Case 'unchanged receipt ZIP manifest App and Core remain admitted' { $null=Assert-V02RuntimePackageExecutablesUnchanged $binding }
    foreach($name in @('identity','archive','manifest','app','core')){
        Test-Case "mutated $name bytes fail closed" { [IO.File]::AppendAllText($bindingFiles[$name],'tamper');try{$null=Assert-V02RuntimePackageExecutablesUnchanged $binding}finally{[IO.File]::WriteAllText($bindingFiles[$name],"original-$name")} } $true
    }
} finally { if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Recurse -Force} }

if($failures.Count){$failures|ForEach-Object{Write-Host $_ -ForegroundColor Red};exit 1}
Write-Host 'All v0.2 runtime/package binding hostile tests passed.' -ForegroundColor Green
