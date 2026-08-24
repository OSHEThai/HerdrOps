#requires -Version 5.1
Set-StrictMode -Version Latest;$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\lib\V02ReleaseArtifactProduction.ps1')

$failures=New-Object Collections.Generic.List[string]
function Case([string]$Name,[scriptblock]$Body){try{&$Body;Write-Host "PASS: $Name"}catch{[void]$failures.Add("$Name`: $($_.Exception.Message)");Write-Host "FAIL: $Name" -ForegroundColor Red}}
function Throws([scriptblock]$Body,[string]$Pattern){$caught=$null;try{&$Body}catch{$caught=$_};if($null-eq$caught){throw 'Expected fail-closed rejection.'};if($caught.Exception.Message-notmatch$Pattern){throw "Wrong guard: $($caught.Exception.Message)"}}
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
    Case 'canonical publication is atomic no-clobber' {
        $path=Join-Path $root 'receipt.json';$first=Publish-V02ReleaseArtifactJsonNoClobber -Value ([pscustomobject][ordered]@{schemaVersion=1;result='PASS'}) -OutputPath $path -AllowedRoot $root
        $before=[IO.File]::ReadAllBytes($path);Throws {Publish-V02ReleaseArtifactJsonNoClobber -Value ([pscustomobject]@{forged=$true}) -OutputPath $path -AllowedRoot $root} 'no-clobber'
        $after=[IO.File]::ReadAllBytes($path);if((Get-V02ReleaseArtifactSha256Bytes $before)-cne(Get-V02ReleaseArtifactSha256Bytes $after)){throw 'No-clobber rejection changed destination bytes.'}
        if(-not([Text.Encoding]::UTF8.GetString($before).EndsWith("`n"))){throw 'Canonical publication omitted exactly one LF.'}
    }
    Case 'production candidate-lock publisher binds review result and is no-clobber' {
        $repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'));$evidence=Join-Path $root 'lock-evidence';$external=Join-Path $root 'lock-review';[IO.Directory]::CreateDirectory($evidence)|Out-Null;[IO.Directory]::CreateDirectory($external)|Out-Null
        $pre=Publish-V02ReleaseArtifactBytesNoClobber -Bytes ([Text.Encoding]::UTF8.GetBytes('preclosure')) -OutputPath (Join-Path $evidence 'pre.json') -AllowedRoot $evidence
        $reviewResult=Publish-V02ReleaseArtifactBytesNoClobber -Bytes ([Text.Encoding]::UTF8.GetBytes('role-distinct review result')) -OutputPath (Join-Path $external 'review.txt') -AllowedRoot $external
        $candidate=[pscustomobject][ordered]@{SourceCommit=('a'*40);SourceTree=('b'*40);ProfileId='herdrops-v0.2-package-software-only-issue-149';ProfileFileSha256=('1'*64);ProfileCanonicalSha256=('2'*64);PackageReceiptSha256=('3'*64);PackageReceiptFileSha256=('4'*64);PackageArchiveSha256=('5'*64);PackageManifestSha256=('6'*64);PackageAppSha256=('7'*64);PackageCoreSha256=('8'*64);RendererManifestSha256=('9'*64);RuntimeMatrixManifestSha256=('A'*64);Issue9CandidateSha256=('B'*64);PreclosureGitHubSnapshotSha256=$pre.Sha256}
        $builder=[pscustomobject][ordered]@{Identity='builder';Task='build-task';Role='CandidateBuilder'};$reviewer=[pscustomobject][ordered]@{Identity='reviewer';Task='review-task';Role='IndependentAgentReviewer'};$review=[pscustomobject][ordered]@{Result='APPROVED_CANDIDATE_ONLY';OpenHighCriticalDefects=0;ReviewResultPath=$reviewResult.Path;ReviewResultSha256=$reviewResult.Sha256}
        $body=New-V02ReleaseArtifactAgentReviewCommentBody $candidate $builder $reviewer $review;$bodySha=Get-V02ReleaseArtifactSha256Bytes ([Text.UTF8Encoding]::new($false,$true).GetBytes($body));$authority=Join-Path $repo 'Plan\DECISIONS.md';$authoritySha=Get-V02ReleaseArtifactSha256File $authority
        $receipt=[pscustomobject][ordered]@{SchemaVersion=4;EvidenceClass='ExternalIndependentCandidateReceipt';Result='APPROVED_CANDIDATE_ONLY';DecisionId='herdrops-v0.2-release-first-v4';ApprovalReference='https://github.com/OSHEThai/HerdrOps/issues/149#issuecomment-5396694185';AuthorityReference='Plan/DECISIONS.md#D-026';AuthorityReferenceSha256=$authoritySha;Candidate=$candidate;Owner=[pscustomobject][ordered]@{Identity='@yutthaphon';Role='ProductOwner'};Builder=$builder;IndependentReviewer=$reviewer;Review=$review;Authentication=[pscustomobject][ordered]@{Method='LIVE_GITHUB_OWNER_AUTHENTICATED_AGENT_REVIEW_COMMENT';ApiUrl='https://api.github.com/repos/OSHEThai/HerdrOps/issues/comments/1';HtmlUrl='https://github.com/OSHEThai/HerdrOps/issues/149#issuecomment-1';IssueNumber=149;CommentId=[long]1;CommentAuthor='yutthaphon';AuthorAssociation='OWNER';CreatedAtUtc='2026-08-25T00:00:00Z';UpdatedAtUtc='2026-08-25T00:00:00Z';CommentBodySha256=$bodySha;Authenticated=$true};RoleDistinct=$true;Runtime='NOT_OBSERVED';Release='NOT_OBSERVED';CreditGranted=$false}
        $receiptOut=Publish-V02ReleaseArtifactJsonNoClobber -Value $receipt -OutputPath (Join-Path $external 'receipt.json') -AllowedRoot $external;$lockPath=Join-Path $evidence 'lock.json';$scriptPath=Join-Path $PSScriptRoot 'New-V02ApprovedCandidateLock.ps1'
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
    $link=Join-Path $root 'link';if([IO.Directory]::Exists($link)){[IO.Directory]::Delete($link)}
    if([IO.Directory]::Exists($root)){[IO.Directory]::Delete($root,$true)}
}
if($failures.Count-ne0){throw "Release artifact production tests failed:`n$($failures-join"`n")"}
Write-Host 'All v0.2 release artifact production tests passed.'
