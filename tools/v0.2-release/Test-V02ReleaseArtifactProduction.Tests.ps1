#requires -Version 5.1
Set-StrictMode -Version Latest;$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\lib\V02ReleaseArtifactProduction.ps1')

$failures=New-Object Collections.Generic.List[string]
function Case([string]$Name,[scriptblock]$Body){try{&$Body;Write-Host "PASS: $Name"}catch{[void]$failures.Add("$Name`: $($_.Exception.Message)`n$($_.ScriptStackTrace)");Write-Host "FAIL: $Name" -ForegroundColor Red}}
function Throws([scriptblock]$Body,[string]$Pattern){$caught=$null;try{&$Body}catch{$caught=$_};if($null-eq$caught){throw 'Expected fail-closed rejection.'};if($caught.Exception.Message-notmatch$Pattern){throw "Wrong guard: $($caught.Exception.Message)"}}
function Write-V02ReleaseArtifactTestFile([string]$Path,[string]$Text){$parent=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path));if(-not[IO.Directory]::Exists($parent)){[IO.Directory]::CreateDirectory($parent)|Out-Null};[IO.File]::WriteAllBytes($Path,[Text.UTF8Encoding]::new($false).GetBytes($Text))}
function State([string]$MilestoneState,[int[]]$OpenIssues){
    $milestone=[pscustomobject][ordered]@{number=2;title='v0.2.0';state=$MilestoneState}
    $issues=@(6,7,8,9,10,11,54,63,149|ForEach-Object{[pscustomobject][ordered]@{number=$_;title=$(if($_-eq11){'[v0.2.0] Release readiness tracker'}else{"issue $_"});state=$(if($_-in$OpenIssues){'open'}else{'closed'});milestone=[pscustomobject][ordered]@{number=2;title='v0.2.0'}}})
    [pscustomobject][ordered]@{sourceCommit=('a'*40);check=[pscustomobject][ordered]@{name='build-test';headSha=('a'*40);conclusion='success';checkRunId=[long]1;completedAtUtc='2026-08-25T00:00:00Z';detailsUrl='https://github.com/OSHEThai/HerdrOps/actions/runs/1/job/2'};milestone=$milestone;issues=$issues}
}
$root=Join-Path ([IO.Path]::GetTempPath()) ('v02-release-artifact-tests-'+[Guid]::NewGuid().ToString('N'));[IO.Directory]::CreateDirectory($root)|Out-Null
try{
    Case 'Preclosure admits exactly tracker and authority issue open' {
        $snapshot=New-V02ReleaseArtifactGitHubSnapshotValue -Phase Preclosure -SourceCommit ('a'*40) -SourceTree ('b'*40) -LiveState (State open @(11,149))
        Assert-V02ReleaseArtifactGitHubPhaseState $snapshot Preclosure
    }
    Case 'Preclosure rejects an additional open implementation issue' {
        $snapshot=New-V02ReleaseArtifactGitHubSnapshotValue -Phase Preclosure -SourceCommit ('a'*40) -SourceTree ('b'*40) -LiveState (State open @(7,11,149))
        Throws {Assert-V02ReleaseArtifactGitHubPhaseState $snapshot Preclosure} 'open issue set'
    }
    Case 'FinalClosure binds preclosure and requires all closed' {
        $snapshot=New-V02ReleaseArtifactGitHubSnapshotValue -Phase FinalClosure -SourceCommit ('a'*40) -SourceTree ('b'*40) -LiveState (State closed @()) -PreclosureSnapshotSha256 ('C'*64)
        Assert-V02ReleaseArtifactGitHubPhaseState $snapshot FinalClosure
        if($snapshot.preclosureSnapshotSha256-cne('C'*64)){throw 'FinalClosure lost its preclosure binding.'}
    }
    Case 'FinalClosure rejects an open tracker' {
        $snapshot=New-V02ReleaseArtifactGitHubSnapshotValue -Phase FinalClosure -SourceCommit ('a'*40) -SourceTree ('b'*40) -LiveState (State open @(11)) -PreclosureSnapshotSha256 ('C'*64)
        Throws {Assert-V02ReleaseArtifactGitHubPhaseState $snapshot FinalClosure} 'open issue set'
    }
    Case 'live GitHub semantic transplant is rejected' {
        $snapshot=New-V02ReleaseArtifactGitHubSnapshotValue -Phase Preclosure -SourceCommit ('a'*40) -SourceTree ('b'*40) -LiveState (State open @(11,149))
        $drift=State open @(7,11,149)
        Throws {Assert-V02ReleaseArtifactLiveSnapshotMatch $snapshot $drift} 'issue state drifted'
    }
    Case 'owner-authenticated comment binds role-distinct logical Agents' {
        $candidate=[pscustomobject][ordered]@{SourceCommit=('a'*40)};$builder=[pscustomobject][ordered]@{Identity='builder-agent';Task='build-v02';Role='CandidateBuilder'};$reviewer=[pscustomobject][ordered]@{Identity='review-agent';Task='review-v02';Role='IndependentAgentReviewer'}
        $review=[pscustomobject][ordered]@{Result='APPROVED_CANDIDATE_ONLY';OpenHighCriticalDefects=0;ReviewResultSha256=('D'*64)}
        Assert-V02ReleaseArtifactLogicalAgentRoles $builder $reviewer;$body=New-V02ReleaseArtifactAgentReviewCommentBody $candidate $builder $reviewer $review;$script:ExpectedReviewBody=$body
        $script:V02ReleaseArtifactGitHubInvokerForTest={param($uri,$method,$requestBody)[pscustomobject]@{id=9001;url='https://api.github.com/repos/OSHEThai/HerdrOps/issues/comments/9001';html_url='https://github.com/OSHEThai/HerdrOps/issues/149#issuecomment-9001';user=[pscustomobject]@{login='yutthaphon'};author_association='OWNER';body=$script:ExpectedReviewBody;created_at='2026-08-25T00:00:00Z';updated_at='2026-08-25T00:00:00Z'}}
        $comment=Publish-V02ReleaseArtifactAgentReviewComment -Body $body -TokenEnvironmentVariable UNUSED
        if($comment.commentAuthor-cne'yutthaphon'){throw 'Authenticated comment owner was not retained.'}
    }
    Case 'wrong GitHub comment author is rejected' {
        $script:V02ReleaseArtifactGitHubInvokerForTest={param($uri,$method,$requestBody)[pscustomobject]@{id=9002;url='https://api.github.com/repos/OSHEThai/HerdrOps/issues/comments/9002';html_url='https://github.com/OSHEThai/HerdrOps/issues/149#issuecomment-9002';user=[pscustomobject]@{login='forged-user'};author_association='COLLABORATOR';body='expected';created_at='2026-08-25T00:00:00Z';updated_at='2026-08-25T00:00:00Z'}}
        Throws {Get-V02ReleaseArtifactAgentReviewComment -CommentId 9002 -ExpectedBody 'expected' -TokenEnvironmentVariable UNUSED} 'repository owner'
    }
    Case 'wrong GitHub owner association is rejected' {
        $script:V02ReleaseArtifactGitHubInvokerForTest={param($uri,$method,$requestBody)[pscustomobject]@{id=9006;url='https://api.github.com/repos/OSHEThai/HerdrOps/issues/comments/9006';html_url='https://github.com/OSHEThai/HerdrOps/issues/149#issuecomment-9006';user=[pscustomobject]@{login='yutthaphon'};author_association='COLLABORATOR';body='expected';created_at='2026-08-25T00:00:00Z';updated_at='2026-08-25T00:00:00Z'}}
        Throws {Get-V02ReleaseArtifactAgentReviewComment -CommentId 9006 -ExpectedBody 'expected' -TokenEnvironmentVariable UNUSED} 'must be OWNER'
    }
    Case 'edited stale GitHub comment is rejected' {
        $script:V02ReleaseArtifactGitHubInvokerForTest={param($uri,$method,$requestBody)[pscustomobject]@{id=9003;url='https://api.github.com/repos/OSHEThai/HerdrOps/issues/comments/9003';html_url='https://github.com/OSHEThai/HerdrOps/issues/149#issuecomment-9003';user=[pscustomobject]@{login='yutthaphon'};author_association='OWNER';body='expected';created_at='2026-08-25T00:00:00Z';updated_at='2026-08-25T00:01:00Z'}}
        Throws {Get-V02ReleaseArtifactAgentReviewComment -CommentId 9003 -ExpectedBody 'expected' -TokenEnvironmentVariable UNUSED} 'stale'
    }
    Case 'transplanted GitHub comment body is rejected' {
        $script:V02ReleaseArtifactGitHubInvokerForTest={param($uri,$method,$requestBody)[pscustomobject]@{id=9004;url='https://api.github.com/repos/OSHEThai/HerdrOps/issues/comments/9004';html_url='https://github.com/OSHEThai/HerdrOps/issues/149#issuecomment-9004';user=[pscustomobject]@{login='yutthaphon'};author_association='OWNER';body='other-candidate';created_at='2026-08-25T00:00:00Z';updated_at='2026-08-25T00:00:00Z'}}
        Throws {Get-V02ReleaseArtifactAgentReviewComment -CommentId 9004 -ExpectedBody 'expected-candidate' -TokenEnvironmentVariable UNUSED} 'does not match'
    }
    Case 'unfetched local receipt cannot substitute for live GitHub' {
        $script:V02ReleaseArtifactGitHubInvokerForTest=$null;$name='HERDROPS_TEST_MISSING_GITHUB_TOKEN';[Environment]::SetEnvironmentVariable($name,$null)
        Throws {Get-V02ReleaseArtifactAgentReviewComment -CommentId 9005 -ExpectedBody 'expected' -TokenEnvironmentVariable $name} 'token environment variable'
    }
    Case 'same Agent identity or task cannot self-review' {
        $builder=[pscustomobject][ordered]@{Identity='agent-one';Task='same-task';Role='CandidateBuilder'};$reviewer=[pscustomobject][ordered]@{Identity='agent-one';Task='same-task';Role='IndependentAgentReviewer'}
        Throws {Assert-V02ReleaseArtifactLogicalAgentRoles $builder $reviewer} 'role-distinct'
    }
    Case 'production evidence publisher is reachable and publishes only a complete governed set' {
        $publisherSource=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Invoke-V02ReleaseEvidencePublisher.ps1'));if($publisherSource.Contains("'-SkipBuild'")-or$publisherSource.Contains("'-RunToken'")){throw 'Synthetic production publisher still requests stale metadata through SkipBuild or a caller token.'}
        $fixtureRepo=Join-Path $root 'publisher-repo';$tools=Join-Path $fixtureRepo 'tools';[IO.Directory]::CreateDirectory($tools)|Out-Null
        Write-V02ReleaseArtifactTestFile -Path (Join-Path $tools 'Test-V02ProtocolContract.ps1') -Text "Write-Output 'protocol pass'`n"
        Write-V02ReleaseArtifactTestFile -Path (Join-Path $tools 'Test-V02BundledSchemaContract.ps1') -Text "Write-Output 'schema pass'`n"
        & git -C $fixtureRepo init -q;& git -C $fixtureRepo config user.name 'HerdrOps Test';& git -C $fixtureRepo config user.email 'test@herdrops.invalid';& git -C $fixtureRepo add .;& git -C $fixtureRepo commit -q -m fixture
        $commit=(&git -C $fixtureRepo rev-parse HEAD).Trim();$tree=(&git -C $fixtureRepo rev-parse 'HEAD^{tree}').Trim();$publisher=Join-Path $PSScriptRoot 'Invoke-V02ReleaseEvidencePublisher.ps1';$evidence=Join-Path $root 'publisher-evidence';[IO.Directory]::CreateDirectory($evidence)|Out-Null;$receipt=Join-Path $evidence 'contract\receipt.json'
        & $publisher -EvidenceClass Contract -ExpectedSourceCommit $commit -ExpectedSourceTree $tree -RepositoryRoot $fixtureRepo -EvidenceRoot $evidence -OutputPath $receipt|Out-Null
        if(-not(Test-Path $receipt -PathType Leaf)-or@(Get-ChildItem (Split-Path $receipt -Parent)-File).Count-ne3){throw 'Production publisher did not atomically expose the receipt plus two transcripts.'}
        $failedRepo=Join-Path $root 'publisher-failed-repo';Copy-Item -LiteralPath $fixtureRepo -Destination $failedRepo -Recurse;Write-V02ReleaseArtifactTestFile -Path (Join-Path $failedRepo 'tools\Test-V02BundledSchemaContract.ps1') -Text "exit 7`n";&git -C $failedRepo add .;&git -C $failedRepo commit -q -m failure
        $failedCommit=(&git -C $failedRepo rev-parse HEAD).Trim();$failedTree=(&git -C $failedRepo rev-parse 'HEAD^{tree}').Trim();$failedEvidence=Join-Path $root 'publisher-failed-evidence';[IO.Directory]::CreateDirectory($failedEvidence)|Out-Null;$failedReceipt=Join-Path $failedEvidence 'contract\receipt.json'
        Throws {& $publisher -EvidenceClass Contract -ExpectedSourceCommit $failedCommit -ExpectedSourceTree $failedTree -RepositoryRoot $failedRepo -EvidenceRoot $failedEvidence -OutputPath $failedReceipt|Out-Null} 'no evidence set was published'
        if(Test-Path (Split-Path $failedReceipt -Parent)){throw 'Failed governed check exposed a partial transcript set.'}
    }
    Case 'structured reviewer result rejects candidate transplant open High and role collision' {
        $receiptParameters=@((Get-Command (Join-Path $PSScriptRoot 'New-V02IndependentAgentReviewReceipt.ps1')).Parameters.Keys);foreach($removed in @('BuilderIdentity','BuilderTask','ReviewerIdentity','ReviewerTask')){if($receiptParameters-contains$removed){throw "Receipt publisher still accepts caller-supplied role string $removed."}}
        $candidate=[pscustomobject][ordered]@{SourceCommit=('a'*40)};$builder=[pscustomobject][ordered]@{Identity='builder';Task='build';Role='CandidateBuilder'};$reviewer=[pscustomobject][ordered]@{Identity='reviewer';Task='review';Role='IndependentAgentReviewer'}
        $make={param($candidateValue,$builderValue,$reviewerValue,$findings)[pscustomobject][ordered]@{SchemaVersion=1;EvidenceClass='IndependentAgentReviewResult';DecisionId='herdrops-v0.2-release-first-v4';Candidate=$candidateValue;Builder=$builderValue;IndependentReviewer=$reviewerValue;Decision='APPROVED_CANDIDATE_ONLY';Findings=$findings;EvidenceBoundary=[pscustomobject][ordered]@{Runtime='NOT_OBSERVED';Release='NOT_OBSERVED';CreditGranted=$false}}}
        $write={param($name,$value)$path=Join-Path $root $name;Publish-V02ReleaseArtifactJsonNoClobber $value $path $root|Out-Null;Open-V02ReleaseArtifactFileLease $path $name}
        $lease=&$write 'structured-ok.json' (&$make $candidate $builder $reviewer @());try{Read-V02ReleaseArtifactAgentReviewResult $lease $candidate|Out-Null}finally{Close-V02ReleaseArtifactLease $lease}
        $lease=&$write 'structured-transplant.json' (&$make ([pscustomobject]@{SourceCommit=('b'*40)}) $builder $reviewer @());try{Throws {Read-V02ReleaseArtifactAgentReviewResult $lease $candidate} 'exact expected candidate'}finally{Close-V02ReleaseArtifactLease $lease}
        $lease=&$write 'structured-high.json' (&$make $candidate $builder $reviewer @([pscustomobject][ordered]@{Id='P0';Severity='High';Status='OPEN';Summary='unresolved'}));try{Throws {Read-V02ReleaseArtifactAgentReviewResult $lease $candidate} 'open High/Critical'}finally{Close-V02ReleaseArtifactLease $lease}
        $collision=[pscustomobject][ordered]@{Identity='builder';Task='review';Role='IndependentAgentReviewer'};$lease=&$write 'structured-collision.json' (&$make $candidate $builder $collision @());try{Throws {Read-V02ReleaseArtifactAgentReviewResult $lease $candidate} 'role-distinct'}finally{Close-V02ReleaseArtifactLease $lease}
    }
    Case 'canonical publication is atomic no-clobber' {
        $path=Join-Path $root 'receipt.json';$script:V02ReleaseArtifactBeforeCommitHookForTest={param($stage,$parent,$destination);$blocked=$false;try{Move-Item -LiteralPath $stage -Destination ($stage+'.swap') -ErrorAction Stop}catch{$blocked=$true};if(-not$blocked){throw 'Held staging-file swap was admitted.'}}
        $first=Publish-V02ReleaseArtifactJsonNoClobber -Value ([pscustomobject][ordered]@{schemaVersion=1;result='PASS'}) -OutputPath $path -AllowedRoot $root;$script:V02ReleaseArtifactBeforeCommitHookForTest=$null
        $before=[IO.File]::ReadAllBytes($path);Throws {Publish-V02ReleaseArtifactJsonNoClobber -Value ([pscustomobject]@{forged=$true}) -OutputPath $path -AllowedRoot $root} 'no-clobber'
        $after=[IO.File]::ReadAllBytes($path);if((Get-V02ReleaseArtifactSha256Bytes $before)-cne(Get-V02ReleaseArtifactSha256Bytes $after)){throw 'No-clobber rejection changed destination bytes.'}
        if(-not([Text.Encoding]::UTF8.GetString($before).EndsWith("`n"))){throw 'Canonical publication omitted exactly one LF.'}
    }
    Case 'held set publication rejects staging and input swaps before root-relative commit' {
        $setRoot=Join-Path $root 'held-set';[IO.Directory]::CreateDirectory($setRoot)|Out-Null;$inputPath=Join-Path $root 'held-input.ps1';Write-V02ReleaseArtifactTestFile $inputPath "Write-Output pass`n";$inputLease=Open-V02ReleaseArtifactFileLease $inputPath 'hostile input'
        try{$script:HeldInputForSwap=$inputPath;$script:V02ReleaseArtifactBeforeCommitHookForTest={param($stage,$parent,$destination);foreach($path in @($stage,$parent,$script:HeldInputForSwap)){$blocked=$false;try{Move-Item -LiteralPath $path -Destination ($path+'.swap') -ErrorAction Stop}catch{$blocked=$true};if(-not$blocked){throw 'Held staging/root/parent/input swap was admitted.'}}};$out=Join-Path $setRoot 'contract\receipt.json';Publish-V02ReleaseArtifactSetNoClobber -AllowedRoot $setRoot -ReceiptOutputPath $out -Files @([pscustomobject]@{Name='one.txt';Bytes=[Text.Encoding]::UTF8.GetBytes('one')}) -ReceiptValue ([pscustomobject]@{SchemaVersion=2}) -InputLeases @($inputLease)|Out-Null;if(-not(Test-Path $out)){throw 'Held set was not committed.'}}finally{$script:V02ReleaseArtifactBeforeCommitHookForTest=$null;Close-V02ReleaseArtifactLease $inputLease}
    }
    Case 'production candidate-lock publisher binds review result and is no-clobber' {
        $repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'));$evidence=Join-Path $root 'lock-evidence';$external=Join-Path $root 'lock-review';[IO.Directory]::CreateDirectory($evidence)|Out-Null;[IO.Directory]::CreateDirectory($external)|Out-Null
        $pre=Publish-V02ReleaseArtifactBytesNoClobber -Bytes ([Text.Encoding]::UTF8.GetBytes('preclosure')) -OutputPath (Join-Path $evidence 'pre.json') -AllowedRoot $evidence
        $candidate=[pscustomobject][ordered]@{SourceCommit=('a'*40);SourceTree=('b'*40);ProfileId='herdrops-v0.2-package-software-only-issue-149';ProfileFileSha256=('1'*64);ProfileCanonicalSha256=('2'*64);PackageReceiptSha256=('3'*64);PackageReceiptFileSha256=('4'*64);PackageArchiveSha256=('5'*64);PackageManifestSha256=('6'*64);PackageAppSha256=('7'*64);PackageCoreSha256=('8'*64);RendererManifestSha256=('9'*64);RuntimeMatrixManifestSha256=('A'*64);Issue9CandidateSha256=('B'*64);PreclosureGitHubSnapshotSha256=$pre.Sha256}
        $builder=[pscustomobject][ordered]@{Identity='builder';Task='build-task';Role='CandidateBuilder'};$reviewer=[pscustomobject][ordered]@{Identity='reviewer';Task='review-task';Role='IndependentAgentReviewer'}
        $reviewResult=Publish-V02ReleaseArtifactJsonNoClobber -Value ([pscustomobject][ordered]@{SchemaVersion=1;EvidenceClass='IndependentAgentReviewResult';DecisionId='herdrops-v0.2-release-first-v4';Candidate=$candidate;Builder=$builder;IndependentReviewer=$reviewer;Decision='APPROVED_CANDIDATE_ONLY';Findings=@();EvidenceBoundary=[pscustomobject][ordered]@{Runtime='NOT_OBSERVED';Release='NOT_OBSERVED';CreditGranted=$false}}) -OutputPath (Join-Path $external 'review.json') -AllowedRoot $external
        $authority=Join-Path $repo 'Plan\DECISIONS.md';$receiptPath=Join-Path $external 'receipt.json';$receiptScript=Join-Path $PSScriptRoot 'New-V02IndependentAgentReviewReceipt.ps1';$script:V02ReleaseArtifactGitHubInvokerForTest={param($uri,$method,$requestBody)$posted=($requestBody|ConvertFrom-Json).body;[pscustomobject]@{id=1;url='https://api.github.com/repos/OSHEThai/HerdrOps/issues/comments/1';html_url='https://github.com/OSHEThai/HerdrOps/issues/149#issuecomment-1';user=[pscustomobject]@{login='yutthaphon'};author_association='OWNER';body=$posted;created_at='2026-08-25T00:00:00Z';updated_at='2026-08-25T00:00:00Z'}}
        . $receiptScript -ExpectedSourceCommit $candidate.SourceCommit -ExpectedSourceTree $candidate.SourceTree -ProfileFileSha256 $candidate.ProfileFileSha256 -ProfileCanonicalSha256 $candidate.ProfileCanonicalSha256 -PackageReceiptSha256 $candidate.PackageReceiptSha256 -PackageReceiptFileSha256 $candidate.PackageReceiptFileSha256 -PackageArchiveSha256 $candidate.PackageArchiveSha256 -PackageManifestSha256 $candidate.PackageManifestSha256 -PackageAppSha256 $candidate.PackageAppSha256 -PackageCoreSha256 $candidate.PackageCoreSha256 -RendererManifestSha256 $candidate.RendererManifestSha256 -RuntimeMatrixManifestSha256 $candidate.RuntimeMatrixManifestSha256 -Issue9CandidateSha256 $candidate.Issue9CandidateSha256 -PreclosureGitHubSnapshotPath $pre.Path -AuthorityReferencePath $authority -ReviewResultPath $reviewResult.Path -ExternalOutputRoot $external -OutputPath $receiptPath -RepositoryRoot $repo -EvidenceRoot $evidence -GitHubTokenEnvironmentVariable UNUSED -PublishGitHubComment|Out-Null
        $receiptOut=[pscustomobject]@{Path=$receiptPath};$lockPath=Join-Path $evidence 'lock.json';$scriptPath=Join-Path $PSScriptRoot 'New-V02ApprovedCandidateLock.ps1'
        & $scriptPath -IndependentCandidateReceiptPath $receiptOut.Path -PreclosureGitHubSnapshotPath $pre.Path -AuthorityReferencePath $authority -RepositoryRoot $repo -EvidenceRoot $evidence -ExternalReviewRoot $external -OutputPath $lockPath|Out-Null
        $lock=Get-Content -LiteralPath $lockPath -Raw|ConvertFrom-Json;if([int]$lock.SchemaVersion-ne3-or[string]$lock.Authority.IndependentReviewResultSha256-cne$reviewResult.Sha256){throw 'Production candidate lock lost the review-result binding.'}
        Throws {& $scriptPath -IndependentCandidateReceiptPath $receiptOut.Path -PreclosureGitHubSnapshotPath $pre.Path -AuthorityReferencePath $authority -RepositoryRoot $repo -EvidenceRoot $evidence -ExternalReviewRoot $external -OutputPath $lockPath|Out-Null} 'no-clobber'
    }
    Case 'reparse ancestry is rejected' {
        $outside=Join-Path $root 'outside';$link=Join-Path $root 'link';[IO.Directory]::CreateDirectory($outside)|Out-Null
        try{New-Item -ItemType Junction -Path $link -Target $outside -ErrorAction Stop|Out-Null;Throws {Publish-V02ReleaseArtifactJsonNoClobber -Value ([pscustomobject]@{x=1}) -OutputPath (Join-Path $link 'x.json') -AllowedRoot $root} 'reparse'}catch{if($_.Exception.Message-notmatch'privilege|supported|reparse'){throw}}
    }
} finally {
    $script:V02ReleaseArtifactGitHubInvokerForTest=$null
    $script:V02ReleaseArtifactCheckInvokerForTest=$null;$script:V02ReleaseArtifactBeforeCommitHookForTest=$null
    $link=Join-Path $root 'link';if([IO.Directory]::Exists($link)){[IO.Directory]::Delete($link)}
    if([IO.Directory]::Exists($root)){try{Get-ChildItem -LiteralPath $root -Force -Recurse -ErrorAction SilentlyContinue|ForEach-Object{$_.Attributes=[IO.FileAttributes]::Normal};[IO.Directory]::Delete($root,$true)}catch{[void]$failures.Add("cleanup: $($_.Exception.Message)")}}
}
if($failures.Count-ne0){throw "Release artifact production tests failed:`n$($failures-join"`n")"}
Write-Host 'All v0.2 release artifact production tests passed.'
