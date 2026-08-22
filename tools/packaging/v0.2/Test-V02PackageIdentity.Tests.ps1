#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'V02PackageIdentity.Common.ps1')
$script:Passed=0;$script:Failed=0
function Invoke-Case{param([string]$Name,[scriptblock]$Action);try{& $Action;$script:Passed++;Write-Host "PASS: $Name"}catch{$script:Failed++;Write-Host "FAIL: $Name -- $($_.Exception.Message)"}}
function Assert-Throws{param([scriptblock]$Action,[string]$Pattern='');$threw=$false;try{& $Action}catch{$threw=$true;if($Pattern -and $_.Exception.Message -notmatch $Pattern){throw "Expected '$Pattern', got: $($_.Exception.Message)"}};if(-not $threw){throw 'Expected a fail-closed rejection.'}}
function Clone($Value){ConvertFrom-V02StrictJsonText -Json ($Value|ConvertTo-Json -Depth 30 -Compress) -Description 'test clone'}
function Put([string]$Path,[byte[]]$Bytes){[IO.File]::WriteAllBytes($Path,$Bytes)}
function Write-TestZip{param([string]$Path,[object[]]$Entries);if(Test-Path -LiteralPath $Path){Remove-Item -LiteralPath $Path -Force};Add-Type -AssemblyName System.IO.Compression;$stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);try{$zip=New-Object IO.Compression.ZipArchive($stream,[IO.Compression.ZipArchiveMode]::Create,$true);try{foreach($item in $Entries){$entry=$zip.CreateEntry([string]$item.Name);$target=$entry.Open();try{$bytes=[byte[]]$item.Bytes;$target.Write($bytes,0,$bytes.Length)}finally{$target.Dispose()}}}finally{$zip.Dispose()}}finally{$stream.Dispose()}}
$worktree=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$testRoot=New-PackagingTempDirectory -Prefix 'HerdrOps-V02Identity-'
$repo=Join-Path $testRoot 'source';$rootA=Join-Path $testRoot 'package-a';$rootB=Join-Path $testRoot 'package-b'
$archive=Join-Path $testRoot 'HerdrOps-0.2.0-win-x64.zip';$receiptPath=Join-Path $testRoot 'identity.json';$lexical=Join-Path $testRoot 'lexical.json';$junction=Join-Path $testRoot 'junction'
New-Item -ItemType Directory (Join-Path $repo 'Plan\reference-hosts') -Force|Out-Null
New-Item -ItemType Directory (Join-Path $repo 'tools\lib') -Force|Out-Null
New-Item -ItemType Directory (Join-Path $repo 'tools\packaging\v0.2') -Force|Out-Null
Copy-Item (Join-Path $worktree 'Plan\reference-hosts\v0.2.json') (Join-Path $repo 'Plan\reference-hosts\v0.2.json')
Copy-Item (Join-Path $worktree 'Plan\reference-hosts\reference-host-profile.schema.json') (Join-Path $repo 'Plan\reference-hosts\reference-host-profile.schema.json')
Copy-Item (Join-Path $worktree 'tools\lib\V02ReferenceHostProfile.ps1') (Join-Path $repo 'tools\lib\V02ReferenceHostProfile.ps1')
Copy-Item (Join-Path $PSScriptRoot 'package-identity-profile.json') (Join-Path $repo 'tools\packaging\v0.2\package-identity-profile.json')
Copy-Item (Join-Path $PSScriptRoot 'package-identity-receipt.schema.json') (Join-Path $repo 'tools\packaging\v0.2\package-identity-receipt.schema.json')
& git -C $repo init --quiet;& git -C $repo -c user.name=HerdrOps-Test -c user.email=test@example.invalid add --all;& git -C $repo -c user.name=HerdrOps-Test -c user.email=test@example.invalid commit --quiet -m fixture
if($LASTEXITCODE){throw 'clean Git fixture creation failed'};$global:LASTEXITCODE=0
$profilePath=Join-Path $repo 'tools\packaging\v0.2\package-identity-profile.json';$profile=Read-V02PackageIdentityProfile $profilePath
New-Item -ItemType Directory $rootA|Out-Null;$app=Join-Path $rootA 'HerdrOps.App.exe';$core=Join-Path $rootA 'HerdrOps.Core.exe';$appBytes=[byte[]](11,12,13,14,15);$coreBytes=[byte[]](21,22,23,24,25,26);Put $app $appBytes;Put $core $coreBytes
$manifest=New-V02PackageManifestObject $profile $repo $rootA;$manifestPath=Join-Path $rootA 'package-manifest.json';Write-V02CanonicalJsonFile $manifest $manifestPath $repo
$manifestStable=Get-V02StableFileIdentity $manifestPath;$inventory=Get-V02PackageRootInventory $rootA -ExcludeRelativePath @('package-manifest.json');$appEntry=@($inventory.Entries|? Path -CEQ 'HerdrOps.App.exe')[0];$coreEntry=@($inventory.Entries|? Path -CEQ 'HerdrOps.Core.exe')[0]
$null=New-DeterministicPackageArchive -PackageRoot $rootA -ArchivePath $archive;$archiveStable=Get-V02StableFileIdentity $archive;$gitId=Get-V02GitIdentity $repo -RequireClean;$profileId=Get-V02PreparationProfileIdentity $profilePath $profile $repo
$identity=[pscustomobject][ordered]@{
 schemaVersion=1;profileId=$profile.profileId;issue=149;packageVersion='0.2.0';runtimeIdentifier='win-x64';source=[pscustomobject][ordered]@{commitSha=$gitId.CommitSha;treeSha=$gitId.TreeSha}
 profile=[pscustomobject][ordered]@{id=$profileId.Id;relativePath=$profileId.RelativePath;bytes=[int64]$profileId.Bytes;fileSha256=$profileId.FileSha256;canonicalSha256=$profileId.CanonicalSha256}
 archive=[pscustomobject][ordered]@{relativePath=$profile.archiveFileName;fileName=$profile.archiveFileName;bytes=[int64]$archiveStable.Length;sha256=$archiveStable.Sha256}
 packageManifest=[pscustomobject][ordered]@{fileName='package-manifest.json';bytes=[int64]$manifestStable.Length;sha256=$manifestStable.Sha256;contentSha256=$manifest.contentSha256;fileCount=[int]$manifest.fileCount;totalBytes=[int64]$manifest.totalBytes}
 components=[pscustomobject][ordered]@{app=[pscustomobject][ordered]@{relativePath='HerdrOps.App.exe';bytes=[int64]$appEntry.Length;sha256=$appEntry.Sha256};core=[pscustomobject][ordered]@{relativePath='HerdrOps.Core.exe';bytes=[int64]$coreEntry.Length;sha256=$coreEntry.Sha256}}
 referenceHost=[pscustomobject][ordered]@{profileId=$profile.referenceHost.profileId;profileSha256=$profile.referenceHost.profileSha256};renderer=[pscustomobject][ordered]@{policy=$profile.renderer.policy;wpfProcessRenderMode=$profile.renderer.wpfProcessRenderMode}
 evidenceBoundary=[pscustomobject][ordered]@{evidenceClass='PackagedCompatibilityPreparation';runtimeUse='not-used';actualHerdrUsed=$false;runtimeCredit='NOT CLAIMED';releaseCredit='NOT CLAIMED'}
}
Write-V02CanonicalJsonFile $identity $receiptPath $repo;$receipt=Read-V02CanonicalIdentityReceipt $receiptPath $repo
function Validate{param($Candidate=$identity,[string]$ArchivePath=$archive,[string]$PackageRoot=$rootA);$canonical=ConvertTo-V02CanonicalJson $Candidate $repo;Assert-V02PackageIdentity $Candidate $profile $repo $ArchivePath $PackageRoot $profilePath (Get-Sha256ForText $canonical) $canonical}
$manifestOriginal=[IO.File]::ReadAllBytes($manifestPath);$archiveOriginal=[IO.File]::ReadAllBytes($archive);$planProfilePath=Join-Path $repo 'Plan\reference-hosts\v0.2.json';$planSchemaPath=Join-Path $repo 'Plan\reference-hosts\reference-host-profile.schema.json';$planProfileOriginal=[IO.File]::ReadAllBytes($planProfilePath);$planSchemaOriginal=[IO.File]::ReadAllBytes($planSchemaPath)
try{
 Invoke-Case 'valid coherent receipt passes' {$r=Validate;if($r.ReceiptSha256 -cne $receipt.ReceiptSha256){throw 'receipt SHA mismatch'}}
 Invoke-Case 'CLI consumes atomic receipt' {$o=@(& (Join-Path $PSScriptRoot 'Test-V02PackageIdentity.ps1') -IdentityPath $receiptPath -ArchivePath $archive -PackageRoot $rootA -RepositoryRoot $repo -ProfilePath $profilePath);if($o.Count-ne 1-or $o[0].ReceiptSha256-cne $receipt.ReceiptSha256){throw 'CLI output mismatch'}}
 Invoke-Case 'schema/manual parity hash pinned' {$h=Assert-V02ReceiptSchema $identity $receipt.CanonicalJson $repo;if($h-cne '8C7EF64ED06C94C6589D73C0AB47EB60B7EEF7BFE337F126D8D9D3F0CC0F4C4B'){throw 'schema hash drift'}}
 Invoke-Case 'Identity B with canonical A rejected' {$x=Clone $identity;$x.issue=150;$hash=Get-Sha256ForText (ConvertTo-V02CanonicalJson $x $repo);Assert-Throws {Assert-V02PackageIdentity $x $profile $repo $archive $rootA $profilePath $hash $receipt.CanonicalJson} 'canonical receipt'}
 Invoke-Case 'wrong well-formed receipt SHA rejected' {Assert-Throws {Assert-V02PackageIdentity $identity $profile $repo $archive $rootA $profilePath ('A'*64) $receipt.CanonicalJson} 'recomputed canonical'}
 Invoke-Case 'omitted receipt SHA rejected' {Assert-Throws {Assert-V02PackageIdentity -Identity $identity -Profile $profile -RepositoryRoot $repo -ArchivePath $archive -PackageRoot $rootA -ProfilePath $profilePath -CanonicalReceiptJson $receipt.CanonicalJson} 'receipt SHA'}
 Invoke-Case 'superseded REC-ALL v1 authority rejected' {$x=Clone $profile;$x.approval.decisionId='herdrops-rec-all-v1';Assert-Throws {Assert-V02PackageIdentityProfile $x} 'v2'}
 foreach($c in @(@{N='v0.7 substitution';P='packageVersion';V='0.7.0'},@{N='RID substitution';P='runtimeIdentifier';V='win-arm64'},@{N='profile substitution';P='profileId';V='v0.7-profile'})){Invoke-Case "$($c.N) rejected" {$x=Clone $identity;$x.($c.P)=$c.V;Assert-Throws {Validate $x}}}
 Invoke-Case 'archive name rejected' {$x=Clone $identity;$x.archive.fileName='other.zip';Assert-Throws {Validate $x}}
 Invoke-Case 'archive path rejected' {$x=Clone $identity;$x.archive.relativePath='../other.zip';Assert-Throws {Validate $x}}
 Invoke-Case 'component path rejected' {$x=Clone $identity;$x.components.app.relativePath='sub/App.exe';Assert-Throws {Validate $x}}
 Invoke-Case 'renderer policy rejected' {$x=Clone $identity;$x.renderer.policy='hardware';Assert-Throws {Validate $x}}
 Invoke-Case 'renderer mode rejected' {$x=Clone $identity;$x.renderer.wpfProcessRenderMode='Default';Assert-Throws {Validate $x}}
 Invoke-Case 'Runtime overclaim rejected' {$x=Clone $identity;$x.evidenceBoundary.runtimeCredit='PASS';Assert-Throws {Validate $x}}
 Invoke-Case 'Herdr overclaim rejected' {$x=Clone $identity;$x.evidenceBoundary.actualHerdrUsed=$true;Assert-Throws {Validate $x}}
 Invoke-Case 'Release overclaim rejected' {$x=Clone $identity;$x.evidenceBoundary.releaseCredit='PASS';Assert-Throws {Validate $x}}
 Invoke-Case 'unknown root rejected' {$x=Clone $identity;$x|Add-Member unexpected 1;Assert-Throws {Validate $x}}
 Invoke-Case 'missing nested rejected' {$x=Clone $identity;$x.components.app.PSObject.Properties.Remove('bytes');Assert-Throws {Validate $x}}
 Invoke-Case 'unknown nested rejected' {$x=Clone $identity;$x.renderer|Add-Member fallback none;Assert-Throws {Validate $x}}
 Invoke-Case 'numeric string rejected' {$x=Clone $identity;$x.archive.bytes=[string]$x.archive.bytes;Assert-Throws {Validate $x}}
 Invoke-Case 'floating bytes rejected' {$x=Clone $identity;$x.components.core.bytes=[double]$x.components.core.bytes;Assert-Throws {Validate $x}}
 Invoke-Case 'cross App hash rejected' {$x=Clone $identity;$x.components.app.sha256=$x.components.core.sha256;Assert-Throws {Validate $x}}
 Invoke-Case 'cross App bytes rejected' {$x=Clone $identity;$x.components.app.bytes=$x.components.core.bytes;Assert-Throws {Validate $x}}
 Invoke-Case 'cross profile hashes rejected' {$x=Clone $identity;$x.profile.canonicalSha256=$x.profile.fileSha256;Assert-Throws {Validate $x}}
 Invoke-Case 'reference-host profile SHA substitution rejected' {$x=Clone $identity;$x.referenceHost.profileSha256='A'*64;Assert-Throws {Validate $x}}
 Invoke-Case 'wrong source rejected' {$x=Clone $identity;$x.source.commitSha='0'*40;Assert-Throws {Validate $x}}
 Invoke-Case 'source-manifest mismatch rejected' {$m=Clone $manifest;$m.source.commitSha='0'*40;Write-V02CanonicalJsonFile $m $manifestPath $repo;try{Assert-Throws {Validate}}finally{Put $manifestPath $manifestOriginal}}
 Invoke-Case 'archive A root B rejected' {New-Item -ItemType Directory $rootB|Out-Null;Put (Join-Path $rootB 'HerdrOps.App.exe') $appBytes;Put (Join-Path $rootB 'HerdrOps.Core.exe') ([byte[]](99,98));$m=New-V02PackageManifestObject $profile $repo $rootB;Write-V02CanonicalJsonFile $m (Join-Path $rootB 'package-manifest.json') $repo;Assert-Throws {Validate $identity $archive $rootB}}
 Invoke-Case 'archive replacement rejected' {Put $archive ([byte[]](1,2,3));try{Assert-Throws {Validate}}finally{Put $archive $archiveOriginal}}
 Invoke-Case 'App replacement rejected' {Put $app ([byte[]](1,2,3));try{Assert-Throws {Validate}}finally{Put $app $appBytes}}
 Invoke-Case 'missing Core rejected' {$saved=[IO.File]::ReadAllBytes($core);Remove-Item $core -Force;try{Assert-Throws {Validate}}finally{Put $core $saved}}
 Invoke-Case 'dirty source rejected' {$dirty=Join-Path $repo 'dirty.tmp';Put $dirty ([byte[]](1));try{Assert-Throws {Validate} 'clean source'}finally{Remove-Item $dirty -Force}}
 Invoke-Case 'tracked dirty source rejected' {$tracked=Join-Path $repo 'tools\lib\V02ReferenceHostProfile.ps1';$saved=[IO.File]::ReadAllBytes($tracked);[IO.File]::AppendAllText($tracked,"`n# tracked dirty hostile");try{Assert-Throws {Validate} 'clean source'}finally{Put $tracked $saved}}
 Invoke-Case 'mid-validation source transition rejected' {$tracked=Join-Path $repo 'tools\lib\V02ReferenceHostProfile.ps1';$saved=[IO.File]::ReadAllBytes($tracked);$script:V02PackageIdentityAfterSourcePreflightForTest={ [IO.File]::AppendAllText($tracked,"`n# mid-validation hostile") };try{Assert-Throws {Validate} 'clean source'}finally{$script:V02PackageIdentityAfterSourcePreflightForTest=$null;Put $tracked $saved}}
 Invoke-Case 'governed profile drift rejected' {$t=[IO.File]::ReadAllText($planProfilePath).Replace('"scalePercent":125','"scalePercent":126');[IO.File]::WriteAllText($planProfilePath,$t,(New-Object Text.UTF8Encoding($false)));try{Assert-Throws {Validate} 'profile|SHA'}finally{Put $planProfilePath $planProfileOriginal}}
 Invoke-Case 'governed schema drift rejected' {$original=[IO.File]::ReadAllText($planSchemaPath);$t=[regex]::Replace($original,'"additionalProperties"\s*:\s*false','"additionalProperties":true',1);if($t-cne $original){[IO.File]::WriteAllText($planSchemaPath,$t,(New-Object Text.UTF8Encoding($false)))}else{throw 'schema hostile could not mutate authority'};try{Assert-Throws {Validate} 'schema'}finally{Put $planSchemaPath $planSchemaOriginal}}
 Invoke-Case 'missing governed profile rejected' {Remove-Item $planProfilePath -Force;try{Assert-Throws {Validate} 'missing'}finally{Put $planProfilePath $planProfileOriginal}}
 Invoke-Case 'reparse root rejected' {New-Item -ItemType Junction -Path $junction -Target $rootA|Out-Null;try{Assert-Throws {Validate $identity $archive $junction} 'reparse'}finally{if(Test-Path -LiteralPath $junction){[IO.Directory]::Delete($junction,$false)}}}
 Invoke-Case 'nested descendant reparse rejected' {$target=Join-Path $testRoot 'reparse-target';$link=Join-Path $rootA 'nested-link';New-Item -ItemType Directory $target|Out-Null;New-Item -ItemType Junction -Path $link -Target $target|Out-Null;try{Assert-Throws {Validate} 'reparse'}finally{if(Test-Path -LiteralPath $link){[IO.Directory]::Delete($link,$false)};if(Test-Path -LiteralPath $target){[IO.Directory]::Delete($target,$false)}}}
 Invoke-Case 'missing archive rejected' {Assert-Throws {Validate $identity (Join-Path $testRoot 'missing.zip') $rootA}}
  foreach($z in @(@{N='parent traversal';Entries=@(@{Name='../evil';Bytes=[byte[]](1)})},@{N='absolute path';Entries=@(@{Name='/evil';Bytes=[byte[]](1)})},@{N='backslash path';Entries=@(@{Name='dir\evil';Bytes=[byte[]](1)})},@{N='duplicate-case path';Entries=@(@{Name='HerdrOps.App.exe';Bytes=[byte[]](1)},@{Name='herdrops.app.exe';Bytes=[byte[]](2)})})) {Invoke-Case "archive $($z.N) rejected" {Write-TestZip $archive $z.Entries;$s=Get-V02StableFileIdentity $archive;$x=Clone $identity;$x.archive.bytes=[int64]$s.Length;$x.archive.sha256=$s.Sha256;try{Assert-Throws {Validate $x}}finally{Put $archive $archiveOriginal}}}
  Invoke-Case 'archive byte ceiling rejected' {$bounds=Get-V02PackageVerifierSecurityBounds;if($bounds.MaximumArchiveBytes -le 1){throw 'production archive byte ceiling is not positive'};Assert-Throws {Get-V02ArchiveInventory -Path $archive -MaximumArchiveBytes 1} 'maximum allowed byte size'}
  Invoke-Case 'archive entry-count ceiling rejected' {Write-TestZip $archive @(@{Name='one';Bytes=[byte[]](1)},@{Name='two';Bytes=[byte[]](2)});try{Assert-Throws {Get-V02ArchiveInventory -Path $archive -MaximumEntryCount 1} 'entry count'}finally{Put $archive $archiveOriginal}}
  Invoke-Case 'archive expanded-size ceiling rejected' {Write-TestZip $archive @(@{Name='expanded';Bytes=[byte[]](1,2,3)});try{Assert-Throws {Get-V02ArchiveInventory -Path $archive -MaximumExpandedBytes 2} 'expanded byte size'}finally{Put $archive $archiveOriginal}}
  Invoke-Case 'archive compression-ratio ceiling rejected' {$bytes=New-Object byte[] 65536;for($i=0;$i -lt $bytes.Length;$i++){$bytes[$i]=65};Write-TestZip $archive @(@{Name='high-ratio';Bytes=$bytes});try{Assert-Throws {Get-V02ArchiveInventory -Path $archive -MaximumCompressionRatio 10} 'compression ratio'}finally{Put $archive $archiveOriginal}}
  Invoke-Case 'weaker archive security bounds rejected' {$bounds=Get-V02PackageVerifierSecurityBounds;Assert-Throws {Get-V02ArchiveInventory -Path $archive -MaximumArchiveBytes ($bounds.MaximumArchiveBytes + 1)} 'weaker bounds'}
  Invoke-Case 'REC-v1 approvalReference rejected' {$x=Clone $profile;$x.approval.approvalReference='https://github.com/OSHEThai/HerdrOps/issues/149#issuecomment-5380618786';Assert-Throws {Assert-V02PackageIdentityProfile $x} '5380637664'}
 Invoke-Case 'REC-v1 payload SHA rejected' {$x=Clone $profile;$x.approval.payloadSha256='DD8EB4D4BC896BE6A4765D409C5E34A16C4DBFB3D70F437EC915A50DF2FC1B1E';Assert-Throws {Assert-V02PackageIdentityProfile $x} '48474610'}
 foreach($l in @(@{N='BOM';B=([byte[]](0xEF,0xBB,0xBF)+[Text.Encoding]::UTF8.GetBytes('{}'))},@{N='trailing';B=[Text.Encoding]::UTF8.GetBytes("{}`ntrue")},@{N='comment';B=[Text.Encoding]::UTF8.GetBytes('{"x":/*no*/1}')},@{N='comma';B=[Text.Encoding]::UTF8.GetBytes('{"x":1,}')},@{N='duplicate';B=[Text.Encoding]::UTF8.GetBytes('{"x":1,"x":2}')})){Invoke-Case "$($l.N) JSON rejected" {Put $lexical $l.B;Assert-Throws {Read-V02CanonicalIdentityReceipt $lexical $repo}}}
}finally{if(Test-Path $testRoot){Remove-PackagingTempDirectory $testRoot}}
Write-Host "RESULT: $script:Passed passed, $script:Failed failed";if($script:Failed){throw "$script:Failed v0.2 package identity test(s) failed."};$global:LASTEXITCODE=0
