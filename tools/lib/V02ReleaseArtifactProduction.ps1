#requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'V02ReferenceHostProfile.ps1')

$script:V02ReleaseArtifactRepository = 'OSHEThai/HerdrOps'
$script:V02ReleaseArtifactApiBase = 'https://api.github.com'
$script:V02ReleaseArtifactMilestoneNumber = 2
$script:V02ReleaseArtifactMilestoneTitle = 'v0.2.0'
$script:V02ReleaseArtifactIssueSet = @(6,7,8,9,10,11,54,63,149)
$script:V02ReleaseArtifactPreclosureOpenIssues = @(11,149)
$script:V02ReleaseArtifactRequiredCheck = 'build-test'
$script:V02ReleaseArtifactOwnerLogin = 'yutthaphon'
$script:V02ReleaseArtifactReviewRole = 'IndependentAgentReviewer'
$script:V02ReleaseArtifactGitHubInvokerForTest = $null

function Get-V02ReleaseArtifactSha256Bytes {
    param([Parameter(Mandatory=$true)][byte[]]$Bytes)
    $sha=[Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-','').ToUpperInvariant() }
    finally { $sha.Dispose() }
}

function Get-V02ReleaseArtifactSha256File {
    param([Parameter(Mandatory=$true)][string]$Path)
    $full=[IO.Path]::GetFullPath($Path)
    if(-not [IO.File]::Exists($full)){throw "Required file is missing: $full"}
    $stream=[IO.File]::Open($full,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try{$sha=[Security.Cryptography.SHA256]::Create();try{return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToUpperInvariant()}finally{$sha.Dispose()}}
    finally{$stream.Dispose()}
}

function Assert-V02ReleaseArtifactSha256 {
    param([Parameter(Mandatory=$true)][string]$Value,[Parameter(Mandatory=$true)][string]$Context)
    if($Value -cnotmatch '^[0-9A-F]{64}$'){throw "$Context must be uppercase SHA-256."}
    return $Value
}

function Assert-V02ReleaseArtifactGitId {
    param([Parameter(Mandatory=$true)][string]$Value,[Parameter(Mandatory=$true)][string]$Context)
    if($Value -cnotmatch '^[0-9a-f]{40}$'){throw "$Context must be a lowercase 40-character Git object id."}
    return $Value
}

function Assert-V02ReleaseArtifactSafeOutput {
    param([Parameter(Mandatory=$true)][string]$Path,[Parameter(Mandatory=$true)][string]$AllowedRoot)
    $root=[IO.Path]::GetFullPath($AllowedRoot).TrimEnd([char[]]@('\','/'))
    $full=[IO.Path]::GetFullPath($Path)
    $prefix=$root+[IO.Path]::DirectorySeparatorChar
    if(-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw "Output path must be contained by AllowedRoot: $root"}
    $parent=[IO.Path]::GetDirectoryName($full)
    if(-not[IO.Directory]::Exists($root)){throw "AllowedRoot must already exist: $root"}
    if(-not[IO.Directory]::Exists($parent)){throw "Output parent must already exist and be prevalidated: $parent"}
    $cursor=$parent
    while($cursor.StartsWith($root,[StringComparison]::OrdinalIgnoreCase)){
        $item=Get-Item -LiteralPath $cursor -Force
        if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint)-ne 0){throw "Output ancestry cannot contain a reparse point: $cursor"}
        if([StringComparer]::OrdinalIgnoreCase.Equals($cursor,$root)){break}
        $cursor=[IO.Path]::GetDirectoryName($cursor)
    }
    if([IO.File]::Exists($full) -or [IO.Directory]::Exists($full)){throw "Output already exists; publication is no-clobber: $full"}
    return $full
}

function Assert-V02ReleaseArtifactPathOutsideRoot {
    param([Parameter(Mandatory=$true)][string]$Path,[Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)][string]$Context)
    $full=[IO.Path]::GetFullPath($Path);$rootFull=[IO.Path]::GetFullPath($Root).TrimEnd([char[]]@('\','/'))
    if([StringComparer]::OrdinalIgnoreCase.Equals($full,$rootFull)-or$full.StartsWith($rootFull+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw "$Context must be outside $rootFull"}
    return $full
}

function Assert-V02ReleaseArtifactExistingFileWithinRoot {
    param([Parameter(Mandatory=$true)][string]$Path,[Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)][string]$Context)
    $full=[IO.Path]::GetFullPath($Path);$rootFull=[IO.Path]::GetFullPath($Root).TrimEnd([char[]]@('\','/'))
    if(-not[IO.File]::Exists($full)){throw "$Context is missing: $full"}
    if(-not$full.StartsWith($rootFull+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw "$Context must be contained by $rootFull"}
    $cursor=[IO.Path]::GetDirectoryName($full)
    while($cursor.StartsWith($rootFull,[StringComparison]::OrdinalIgnoreCase)){$item=Get-Item -LiteralPath $cursor -Force;if(($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){throw "$Context ancestry cannot contain a reparse point: $cursor"};if([StringComparer]::OrdinalIgnoreCase.Equals($cursor,$rootFull)){break};$cursor=[IO.Path]::GetDirectoryName($cursor)}
    return $full
}

function Publish-V02ReleaseArtifactJsonNoClobber {
    param([Parameter(Mandatory=$true)]$Value,[Parameter(Mandatory=$true)][string]$OutputPath,[Parameter(Mandatory=$true)][string]$AllowedRoot)
    $full=Assert-V02ReleaseArtifactSafeOutput -Path $OutputPath -AllowedRoot $AllowedRoot
    $json=(ConvertTo-V02Jcs $Value)+"`n"
    $bytes=[Text.UTF8Encoding]::new($false,$true).GetBytes($json)
    $stage=Join-Path ([IO.Path]::GetDirectoryName($full)) ('.'+[IO.Path]::GetFileName($full)+'.staging-'+[Guid]::NewGuid().ToString('N'))
    $stream=$null
    try{
        $stream=[IO.File]::Open($stage,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $stream.Write($bytes,0,$bytes.Length);$stream.Flush($true);$stream.Dispose();$stream=$null
        [IO.File]::Move($stage,$full)
        return [pscustomobject][ordered]@{Path=$full;Bytes=[long]$bytes.Length;Sha256=(Get-V02ReleaseArtifactSha256Bytes $bytes)}
    } finally {
        if($null-ne$stream){$stream.Dispose()}
        if([IO.File]::Exists($stage)){[IO.File]::Delete($stage)}
    }
}

function Publish-V02ReleaseArtifactBytesNoClobber {
    param([Parameter(Mandatory=$true)][byte[]]$Bytes,[Parameter(Mandatory=$true)][string]$OutputPath,[Parameter(Mandatory=$true)][string]$AllowedRoot)
    $full=Assert-V02ReleaseArtifactSafeOutput -Path $OutputPath -AllowedRoot $AllowedRoot
    $stage=Join-Path ([IO.Path]::GetDirectoryName($full)) ('.'+[IO.Path]::GetFileName($full)+'.staging-'+[Guid]::NewGuid().ToString('N'))
    $stream=$null
    try{
        $stream=[IO.File]::Open($stage,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $stream.Write($Bytes,0,$Bytes.Length);$stream.Flush($true);$stream.Dispose();$stream=$null
        [IO.File]::Move($stage,$full)
        return [pscustomobject][ordered]@{Path=$full;Bytes=[long]$Bytes.Length;Sha256=(Get-V02ReleaseArtifactSha256Bytes $Bytes)}
    } finally {
        if($null-ne$stream){$stream.Dispose()}
        if([IO.File]::Exists($stage)){[IO.File]::Delete($stage)}
    }
}

function Invoke-V02ReleaseArtifactGitHubApi {
    param([Parameter(Mandatory=$true)][string]$RelativeUri,[Parameter(Mandatory=$true)][string]$TokenEnvironmentVariable,[ValidateSet('GET','POST')][string]$Method='GET',[string]$Body='')
    if($null-ne$script:V02ReleaseArtifactGitHubInvokerForTest){return & $script:V02ReleaseArtifactGitHubInvokerForTest $RelativeUri $Method $Body}
    $token=[Environment]::GetEnvironmentVariable($TokenEnvironmentVariable)
    if([string]::IsNullOrWhiteSpace($token)){throw "GitHub token environment variable '$TokenEnvironmentVariable' is missing."}
    $handler=[Net.Http.HttpClientHandler]::new();$client=[Net.Http.HttpClient]::new($handler)
    try{
        $client.BaseAddress=[Uri]$script:V02ReleaseArtifactApiBase
        $client.DefaultRequestHeaders.UserAgent.ParseAdd('HerdrOps-v0.2-release-artifact/1')
        $client.DefaultRequestHeaders.Accept.ParseAdd('application/vnd.github+json')
        $client.DefaultRequestHeaders.Authorization=[Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer',$token)
        $response=$null
        try {
            if($Method-ceq'POST'){$content=[Net.Http.StringContent]::new($Body,[Text.Encoding]::UTF8,'application/json');try{$response=$client.PostAsync($RelativeUri,$content).GetAwaiter().GetResult()}finally{$content.Dispose()}}
            else{$response=$client.GetAsync($RelativeUri).GetAwaiter().GetResult()}
            $body=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            if(-not$response.IsSuccessStatusCode){throw "GitHub API $RelativeUri failed with HTTP $([int]$response.StatusCode)."}
            try{return $body|ConvertFrom-Json}
            catch{throw "GitHub API $RelativeUri returned invalid JSON."}
        } finally {if($null-ne$response){$response.Dispose()}}
    } finally {$client.Dispose();$handler.Dispose()}
}

function Get-V02ReleaseArtifactGitHubState {
    param([Parameter(Mandatory=$true)][string]$SourceCommit,[Parameter(Mandatory=$true)][string]$TokenEnvironmentVariable)
    Assert-V02ReleaseArtifactGitId $SourceCommit 'SourceCommit'|Out-Null
    $checks=Invoke-V02ReleaseArtifactGitHubApi -RelativeUri "/repos/$($script:V02ReleaseArtifactRepository)/commits/$SourceCommit/check-runs?per_page=100" -TokenEnvironmentVariable $TokenEnvironmentVariable
    $milestone=Invoke-V02ReleaseArtifactGitHubApi -RelativeUri "/repos/$($script:V02ReleaseArtifactRepository)/milestones/$($script:V02ReleaseArtifactMilestoneNumber)" -TokenEnvironmentVariable $TokenEnvironmentVariable
    $issues=Invoke-V02ReleaseArtifactGitHubApi -RelativeUri "/repos/$($script:V02ReleaseArtifactRepository)/issues?milestone=$($script:V02ReleaseArtifactMilestoneNumber)&state=all&per_page=100" -TokenEnvironmentVariable $TokenEnvironmentVariable
    $issueRows=@($issues|Where-Object{$null-eq$_.pull_request}|ForEach-Object{
        [pscustomobject][ordered]@{number=[int]$_.number;title=[string]$_.title;state=[string]$_.state;milestone=[pscustomobject][ordered]@{number=[int]$_.milestone.number;title=[string]$_.milestone.title}}
    }|Sort-Object number)
    $matchingChecks=@($checks.check_runs|Where-Object{[string]$_.name-ceq$script:V02ReleaseArtifactRequiredCheck -and [string]$_.head_sha-ceq$SourceCommit}|Sort-Object {[long]$_.id} -Descending)
    if($matchingChecks.Count-lt1){throw "GitHub exposes no '$($script:V02ReleaseArtifactRequiredCheck)' check for $SourceCommit."}
    $selectedCheck=$matchingChecks[0]
    if([string]$selectedCheck.status-cne'completed'-or[string]$selectedCheck.conclusion-cne'success'){throw "Latest GitHub '$($script:V02ReleaseArtifactRequiredCheck)' check for $SourceCommit is not completed/success."}
    return [pscustomobject][ordered]@{
        sourceCommit=$SourceCommit
        check=[pscustomobject][ordered]@{name=$script:V02ReleaseArtifactRequiredCheck;headSha=$SourceCommit;conclusion='success';checkRunId=[long]$selectedCheck.id;completedAtUtc=[string]$selectedCheck.completed_at;detailsUrl=[string]$selectedCheck.html_url}
        milestone=[pscustomobject][ordered]@{number=[int]$milestone.number;title=[string]$milestone.title;state=[string]$milestone.state}
        issues=$issueRows
    }
}

function New-V02ReleaseArtifactGitHubSnapshotValue {
    param(
        [Parameter(Mandatory=$true)][ValidateSet('Preclosure','FinalClosure')][string]$Phase,
        [Parameter(Mandatory=$true)][string]$SourceCommit,
        [Parameter(Mandatory=$true)][string]$SourceTree,
        [Parameter(Mandatory=$true)]$LiveState,
        [string]$PreclosureSnapshotSha256=''
    )
    Assert-V02ReleaseArtifactGitId $SourceCommit 'SourceCommit'|Out-Null;Assert-V02ReleaseArtifactGitId $SourceTree 'SourceTree'|Out-Null
    if($Phase-ceq'Preclosure' -and -not[string]::IsNullOrEmpty($PreclosureSnapshotSha256)){throw 'Preclosure snapshot cannot self-reference a preclosure hash.'}
    if($Phase-ceq'FinalClosure'){Assert-V02ReleaseArtifactSha256 $PreclosureSnapshotSha256 'PreclosureSnapshotSha256'|Out-Null}
    return [pscustomobject][ordered]@{
        schemaVersion=3;evidenceClass='AuthenticatedLiveGitHubSnapshot';phase=$Phase;repository=$script:V02ReleaseArtifactRepository
        authentication=[pscustomobject][ordered]@{method='LIVE_GITHUB_API_BEARER_TLS';apiBaseUri=$script:V02ReleaseArtifactApiBase;authenticated=$true}
        preclosureSnapshotSha256=$(if($Phase-ceq'FinalClosure'){$PreclosureSnapshotSha256}else{$null})
        source=[pscustomobject][ordered]@{commitSha=$SourceCommit;treeSha=$SourceTree}
        ci=[pscustomobject][ordered]@{headSha=$SourceCommit;conclusion='success';requiredChecks=@($LiveState.check)}
        milestones=@($LiveState.milestone);issues=@($LiveState.issues)
    }
}

function Assert-V02ReleaseArtifactGitHubPhaseState {
    param([Parameter(Mandatory=$true)]$Snapshot,[Parameter(Mandatory=$true)][ValidateSet('Preclosure','FinalClosure')][string]$Phase)
    if([string]$Snapshot.phase-cne$Phase){throw "GitHub snapshot phase must be $Phase."}
    $observed=@($Snapshot.issues|ForEach-Object{[int]$_.number}|Sort-Object)
    if(($observed-join',')-cne(@($script:V02ReleaseArtifactIssueSet|Sort-Object)-join',')){throw 'GitHub snapshot v0.2 issue set is not exact.'}
    $open=@($Snapshot.issues|Where-Object{[string]$_.state-ceq'open'}|ForEach-Object{[int]$_.number}|Sort-Object)
    $expectedOpen=if($Phase-ceq'Preclosure'){@($script:V02ReleaseArtifactPreclosureOpenIssues)}else{@()}
    if(($open-join',')-cne(@($expectedOpen|Sort-Object)-join',')){throw "GitHub $Phase open issue set is not exact. Expected=$($expectedOpen-join',') Observed=$($open-join',')."}
    $milestone=@($Snapshot.milestones)
    if($milestone.Count-ne1-or[int]$milestone[0].number-ne2-or[string]$milestone[0].title-cne'v0.2.0'){throw 'GitHub snapshot milestone identity is not exact.'}
    $expectedState=if($Phase-ceq'Preclosure'){'open'}else{'closed'}
    if([string]$milestone[0].state-cne$expectedState){throw "GitHub $Phase milestone state must be $expectedState."}
}

function Assert-V02ReleaseArtifactLiveSnapshotMatch {
    param([Parameter(Mandatory=$true)]$Snapshot,[Parameter(Mandatory=$true)]$LiveState)
    if([string]$Snapshot.source.commitSha-cne[string]$LiveState.sourceCommit){throw 'Live GitHub source commit drifted from the snapshot.'}
    $live=[pscustomobject][ordered]@{milestones=@($LiveState.milestone);issues=@($LiveState.issues);check=$LiveState.check}
    if((ConvertTo-V02Jcs @($Snapshot.milestones))-cne(ConvertTo-V02Jcs @($live.milestones))){throw 'Live GitHub milestone state drifted from the snapshot.'}
    if((ConvertTo-V02Jcs @($Snapshot.issues))-cne(ConvertTo-V02Jcs @($live.issues))){throw 'Live GitHub issue state drifted from the snapshot.'}
    if((ConvertTo-V02Jcs $Snapshot.ci.requiredChecks[0])-cne(ConvertTo-V02Jcs $live.check)){throw 'Live GitHub required check drifted from the snapshot.'}
    return $true
}

function New-V02ReleaseArtifactAgentReviewCommentBody {
    param([Parameter(Mandatory=$true)]$Candidate,[Parameter(Mandatory=$true)]$Builder,[Parameter(Mandatory=$true)]$IndependentReviewer,[Parameter(Mandatory=$true)]$Review)
    $payload=[pscustomobject][ordered]@{schemaVersion=1;decisionId='herdrops-v0.2-release-first-v4';candidate=$Candidate;builder=$Builder;independentReviewer=$IndependentReviewer;review=[pscustomobject][ordered]@{result=[string]$Review.Result;openHighCriticalDefects=[int]$Review.OpenHighCriticalDefects;reviewResultSha256=[string]$Review.ReviewResultSha256}}
    return "HERDROPS-V02-INDEPENDENT-AGENT-REVIEW-V1`n$(ConvertTo-V02Jcs $payload)`n"
}

function Assert-V02ReleaseArtifactLogicalAgentRoles {
    param([Parameter(Mandatory=$true)]$Builder,[Parameter(Mandatory=$true)]$IndependentReviewer)
    foreach($pair in @(@($Builder,'Builder'),@($IndependentReviewer,'IndependentReviewer'))){
        foreach($name in @('Identity','Task','Role')){if([string]::IsNullOrWhiteSpace([string]$pair[0].$name)){throw "$($pair[1]) $name must be nonempty."}}
    }
    if([string]$IndependentReviewer.Role-cne'IndependentAgentReviewer'){throw 'IndependentReviewer Role must be IndependentAgentReviewer.'}
    if([string]$Builder.Identity-ieq[string]$IndependentReviewer.Identity-or[string]$Builder.Task-ieq[string]$IndependentReviewer.Task){throw 'Builder and IndependentReviewer identities and tasks must be role-distinct.'}
}

function Publish-V02ReleaseArtifactAgentReviewComment {
    param([Parameter(Mandatory=$true)][string]$Body,[Parameter(Mandatory=$true)][string]$TokenEnvironmentVariable)
    $request=ConvertTo-V02Jcs ([pscustomobject][ordered]@{body=$Body})
    $comment=Invoke-V02ReleaseArtifactGitHubApi -RelativeUri "/repos/$($script:V02ReleaseArtifactRepository)/issues/149/comments" -TokenEnvironmentVariable $TokenEnvironmentVariable -Method POST -Body $request
    return Assert-V02ReleaseArtifactAgentReviewComment -Comment $comment -ExpectedBody $Body
}

function Get-V02ReleaseArtifactAgentReviewComment {
    param([Parameter(Mandatory=$true)][long]$CommentId,[Parameter(Mandatory=$true)][string]$ExpectedBody,[Parameter(Mandatory=$true)][string]$TokenEnvironmentVariable)
    $comment=Invoke-V02ReleaseArtifactGitHubApi -RelativeUri "/repos/$($script:V02ReleaseArtifactRepository)/issues/comments/$CommentId" -TokenEnvironmentVariable $TokenEnvironmentVariable
    return Assert-V02ReleaseArtifactAgentReviewComment -Comment $comment -ExpectedBody $ExpectedBody
}

function Assert-V02ReleaseArtifactAgentReviewComment {
    param([Parameter(Mandatory=$true)]$Comment,[Parameter(Mandatory=$true)][string]$ExpectedBody)
    if([long]$Comment.id-le0){throw 'Agent review comment id must be positive.'}
    if([string]$Comment.user.login-cne$script:V02ReleaseArtifactOwnerLogin){throw 'Agent review comment author must be the authenticated repository owner.'}
    if([string]$Comment.author_association-cne'OWNER'){throw 'Agent review comment author association must be OWNER.'}
    if([string]$Comment.body-cne$ExpectedBody){throw 'Live Agent review comment body does not match the exact reviewed candidate.'}
    if([string]$Comment.created_at-cne[string]$Comment.updated_at){throw 'Edited Agent review comments are stale and non-closable.'}
    return [pscustomobject][ordered]@{commentId=[long]$Comment.id;apiUrl=[string]$Comment.url;htmlUrl=[string]$Comment.html_url;commentAuthor=[string]$Comment.user.login;authorAssociation=[string]$Comment.author_association;createdAtUtc=[string]$Comment.created_at;updatedAtUtc=[string]$Comment.updated_at;bodySha256=(Get-V02ReleaseArtifactSha256Bytes ([Text.UTF8Encoding]::new($false,$true).GetBytes($ExpectedBody)))}
}

function Invoke-V02ReleaseArtifactCheckProcess {
    param([Parameter(Mandatory=$true)][string]$HostPath,[Parameter(Mandatory=$true)][string]$ScriptPath,[string[]]$Arguments=@())
    $quoted=@('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$ScriptPath)+$Arguments
    $psi=[Diagnostics.ProcessStartInfo]::new();$psi.FileName=$HostPath;$psi.UseShellExecute=$false;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true;$psi.CreateNoWindow=$true
    $psi.Arguments=($quoted|ForEach-Object{'"'+($_-replace'"','\"')+'"'})-join' '
    $proc=[Diagnostics.Process]::new();$proc.StartInfo=$psi
    try{
        if(-not$proc.Start()){throw "Could not start governed check $ScriptPath."}
        $stdoutTask=$proc.StandardOutput.ReadToEndAsync();$stderrTask=$proc.StandardError.ReadToEndAsync();$proc.WaitForExit()
        return [pscustomobject][ordered]@{ExitCode=$proc.ExitCode;Output=($stdoutTask.GetAwaiter().GetResult()+$stderrTask.GetAwaiter().GetResult())}
    } finally {$proc.Dispose()}
}
