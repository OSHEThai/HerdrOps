#requires -Version 5.1
[CmdletBinding()] param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'V02RuntimePackageBinding.ps1')
. (Join-Path $PSScriptRoot '..\packaging\v0.2\V02PackageIdentity.Common.ps1')

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
    $template='<?xml version="1.0"?><TestRun><ResultSummary><Counters total="{0}" passed="{0}" failed="0" /></ResultSummary></TestRun>'
    $counts=@(222,221,221,221);1..4|ForEach-Object{[IO.File]::WriteAllText((Join-Path $results "test$_.trx"),($template -f $counts[$_-1]))}
    Test-Case 'four fresh passing TRX files are preserved with receipt' { $x=Save-V02FreshTrxEvidence $results $started $evidence;if($x.Passed-ne 885-or-not(Test-Path -LiteralPath $x.ReceiptPath)){throw 'TRX receipt missing.'};foreach($f in $x.Files){Assert-V02RuntimeBindingSha256 $f.Sha256 'TRX hash'} }
    Test-Case 'existing TRX evidence directory fails closed' { Save-V02FreshTrxEvidence $results $started $evidence } $true
    Remove-Item -LiteralPath (Join-Path $evidence 'test-results') -Recurse -Force
    Remove-Item -LiteralPath (Join-Path $results 'test4.trx')
    Test-Case 'three fresh TRX files fail closed' { Save-V02FreshTrxEvidence $results $started $evidence } $true
    [IO.File]::WriteAllText((Join-Path $results 'test4.trx'),(($template -f 221).Replace('passed="221"','passed="220"').Replace('failed="0"','failed="1"')))
    Test-Case 'failed TRX counter fails closed' { Save-V02FreshTrxEvidence $results $started $evidence } $true
    if(Test-Path -LiteralPath (Join-Path $evidence 'test-results')){Remove-Item -LiteralPath (Join-Path $evidence 'test-results') -Recurse -Force}
    [IO.File]::WriteAllText((Join-Path $results 'test4.trx'),($template -f 221))
    $script:V02TrxAfterSelectionForTest={ [IO.File]::AppendAllText((Join-Path $results 'test1.trx'),' ') }
    try { Test-Case 'TRX mutation after selection fails closed' { Save-V02FreshTrxEvidence $results $started $evidence } $true }
    finally { $script:V02TrxAfterSelectionForTest=$null;[IO.File]::WriteAllText((Join-Path $results 'test1.trx'),($template -f 222)) }
    $bindingFiles=@{};foreach($name in @('identity','profile','archive','manifest','app','core')){$path=Join-Path $temp "$name.bin";[IO.File]::WriteAllText($path,"original-$name");$bindingFiles[$name]=$path}
    $binding=[pscustomobject]@{
        IdentityPath=$bindingFiles.identity;IdentityFileSha256=(Get-FileHash $bindingFiles.identity -Algorithm SHA256).Hash
        ProfilePath=$bindingFiles.profile;ProfileFileSha256=(Get-FileHash $bindingFiles.profile -Algorithm SHA256).Hash
        ArchivePath=$bindingFiles.archive;ArchiveSha256=(Get-FileHash $bindingFiles.archive -Algorithm SHA256).Hash
        ManifestPath=$bindingFiles.manifest;ManifestSha256=(Get-FileHash $bindingFiles.manifest -Algorithm SHA256).Hash
        AppPath=$bindingFiles.app;AppSha256=(Get-FileHash $bindingFiles.app -Algorithm SHA256).Hash
        CorePath=$bindingFiles.core;CoreSha256=(Get-FileHash $bindingFiles.core -Algorithm SHA256).Hash
    }
    foreach($name in @('identity','profile','archive','manifest','app','core')){
        Test-Case "mutated $name bytes fail closed" { [IO.File]::AppendAllText($bindingFiles[$name],'tamper');try{$null=Assert-V02RuntimePackageExecutablesUnchanged $binding}finally{[IO.File]::WriteAllText($bindingFiles[$name],"original-$name")} } $true
    }

    $actualRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    $fixtureRepo=Join-Path $temp 'package-repo';$fixtureRoot=Join-Path $temp 'package-root';$fixtureArchive=Join-Path $temp 'HerdrOps-0.2.0-win-x64.zip';$fixtureReceipt=Join-Path $temp 'identity.json'
    New-Item -ItemType Directory (Join-Path $fixtureRepo 'Plan\reference-hosts'),(Join-Path $fixtureRepo 'tools\lib'),(Join-Path $fixtureRepo 'tools\packaging\v0.2'),$fixtureRoot -Force|Out-Null
    foreach($pair in @(
        @('Plan\reference-hosts\v0.2.json','Plan\reference-hosts\v0.2.json'),@('Plan\reference-hosts\reference-host-profile.schema.json','Plan\reference-hosts\reference-host-profile.schema.json'),
        @('tools\lib\V02ReferenceHostProfile.ps1','tools\lib\V02ReferenceHostProfile.ps1'),@('tools\packaging\v0.2\package-identity-profile.json','tools\packaging\v0.2\package-identity-profile.json'),
        @('tools\packaging\v0.2\package-identity-receipt.schema.json','tools\packaging\v0.2\package-identity-receipt.schema.json'),@('tools\packaging\v0.2\V02PackageIdentity.Common.ps1','tools\packaging\v0.2\V02PackageIdentity.Common.ps1'),
        @('tools\packaging\v0.2\Test-V02PackageIdentity.ps1','tools\packaging\v0.2\Test-V02PackageIdentity.ps1'),@('tools\packaging\Packaging.Common.ps1','tools\packaging\Packaging.Common.ps1'))){Copy-Item (Join-Path $actualRoot $pair[0]) (Join-Path $fixtureRepo $pair[1])}
    & git -C $fixtureRepo init --quiet;& git -C $fixtureRepo -c user.name=HerdrOps-Test -c user.email=test@example.invalid add --all;& git -C $fixtureRepo -c user.name=HerdrOps-Test -c user.email=test@example.invalid commit --quiet -m fixture;if($LASTEXITCODE){throw 'fixture git commit failed'};$global:LASTEXITCODE=0
    $fixtureProfilePath=Join-Path $fixtureRepo 'tools\packaging\v0.2\package-identity-profile.json';$fixtureProfile=Read-V02PackageIdentityProfile $fixtureProfilePath
    [IO.File]::WriteAllBytes((Join-Path $fixtureRoot 'HerdrOps.App.exe'),[byte[]](1,2,3));[IO.File]::WriteAllBytes((Join-Path $fixtureRoot 'HerdrOps.Core.exe'),[byte[]](4,5,6))
    $fixtureManifest=New-V02PackageManifestObject $fixtureProfile $fixtureRepo $fixtureRoot;$fixtureManifestPath=Join-Path $fixtureRoot 'package-manifest.json';Write-V02CanonicalJsonFile $fixtureManifest $fixtureManifestPath $fixtureRepo
    $null=New-DeterministicPackageArchive -PackageRoot $fixtureRoot -ArchivePath $fixtureArchive;$gitId=Get-V02GitIdentity $fixtureRepo -RequireClean;$profileId=Get-V02PreparationProfileIdentity $fixtureProfilePath $fixtureProfile $fixtureRepo
    $inventory=Get-V02PackageRootInventory $fixtureRoot -ExcludeRelativePath @('package-manifest.json');$manifestStable=Get-V02StableFileIdentity $fixtureManifestPath;$archiveStable=Get-V02StableFileIdentity $fixtureArchive;$appEntry=@($inventory.Entries|Where-Object Path -CEQ 'HerdrOps.App.exe')[0];$coreEntry=@($inventory.Entries|Where-Object Path -CEQ 'HerdrOps.Core.exe')[0]
    $fixtureIdentity=[pscustomobject][ordered]@{schemaVersion=1;profileId=$fixtureProfile.profileId;issue=149;packageVersion='0.2.0';runtimeIdentifier='win-x64';source=[pscustomobject][ordered]@{commitSha=$gitId.CommitSha;treeSha=$gitId.TreeSha};profile=[pscustomobject][ordered]@{id=$profileId.Id;relativePath=$profileId.RelativePath;bytes=[int64]$profileId.Bytes;fileSha256=$profileId.FileSha256;canonicalSha256=$profileId.CanonicalSha256};archive=[pscustomobject][ordered]@{relativePath=$fixtureProfile.archiveFileName;fileName=$fixtureProfile.archiveFileName;bytes=[int64]$archiveStable.Length;sha256=$archiveStable.Sha256};packageManifest=[pscustomobject][ordered]@{fileName='package-manifest.json';bytes=[int64]$manifestStable.Length;sha256=$manifestStable.Sha256;contentSha256=$fixtureManifest.contentSha256;fileCount=[int]$fixtureManifest.fileCount;totalBytes=[int64]$fixtureManifest.totalBytes};components=[pscustomobject][ordered]@{app=[pscustomobject][ordered]@{relativePath='HerdrOps.App.exe';bytes=[int64]$appEntry.Length;sha256=$appEntry.Sha256};core=[pscustomobject][ordered]@{relativePath='HerdrOps.Core.exe';bytes=[int64]$coreEntry.Length;sha256=$coreEntry.Sha256}};referenceHost=[pscustomobject][ordered]@{profileId=$fixtureProfile.referenceHost.profileId;profileSha256=$fixtureProfile.referenceHost.profileSha256};renderer=[pscustomobject][ordered]@{policy=$fixtureProfile.renderer.policy;wpfProcessRenderMode=$fixtureProfile.renderer.wpfProcessRenderMode};evidenceBoundary=[pscustomobject][ordered]@{evidenceClass='PackagedCompatibilityPreparation';runtimeUse='not-used';actualHerdrUsed=$false;runtimeCredit='NOT CLAIMED';releaseCredit='NOT CLAIMED'}}
    Write-V02CanonicalJsonFile $fixtureIdentity $fixtureReceipt $fixtureRepo
    $resolveArgs=@{IdentityPath=$fixtureReceipt;ArchivePath=$fixtureArchive;PackageRoot=$fixtureRoot;RepositoryRoot=$fixtureRepo;ProfilePath=$fixtureProfilePath;ExpectedSourceCommit=$gitId.CommitSha;ExpectedSourceTree=$gitId.TreeSha}
    Test-Case 'complete package validates twice and finalizes unchanged' { $b=Resolve-V02RuntimePackageBinding @resolveArgs;$null=Assert-V02RuntimePackageExecutablesUnchanged $b }
    foreach($case in @(@{Name='identity';Path=$fixtureReceipt},@{Name='manifest';Path=$fixtureManifestPath},@{Name='profile';Path=$fixtureProfilePath})){
        $original=[IO.File]::ReadAllBytes($case.Path);$mutationPath=$case.Path;$script:V02RuntimePackageBindingAfterValidatorForTest={ [IO.File]::AppendAllText($mutationPath,' ') }
        try { Test-Case "after-validator $($case.Name) swap fails closed" { Resolve-V02RuntimePackageBinding @resolveArgs } $true }
        finally { $script:V02RuntimePackageBindingAfterValidatorForTest=$null;[IO.File]::WriteAllBytes($case.Path,$original) }
    }
} finally { if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Recurse -Force} }

if($failures.Count){$failures|ForEach-Object{Write-Host $_ -ForegroundColor Red};exit 1}
Write-Host 'All v0.2 runtime/package binding hostile tests passed.' -ForegroundColor Green
