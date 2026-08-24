#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$ExpectedSourceCommit,[Parameter(Mandatory=$true)][string]$ExpectedSourceTree,
    [Parameter(Mandatory=$true)][string]$ProfileFileSha256,[Parameter(Mandatory=$true)][string]$ProfileCanonicalSha256,
    [Parameter(Mandatory=$true)][string]$PackageReceiptSha256,[Parameter(Mandatory=$true)][string]$PackageReceiptFileSha256,
    [Parameter(Mandatory=$true)][string]$PackageArchiveSha256,[Parameter(Mandatory=$true)][string]$PackageManifestSha256,
    [Parameter(Mandatory=$true)][string]$PackageAppSha256,[Parameter(Mandatory=$true)][string]$PackageCoreSha256,
    [Parameter(Mandatory=$true)][string]$RendererManifestSha256,[Parameter(Mandatory=$true)][string]$RuntimeMatrixManifestSha256,
    [Parameter(Mandatory=$true)][string]$Issue9CandidateSha256,[Parameter(Mandatory=$true)][string]$PreclosureGitHubSnapshotPath,[Parameter(Mandatory=$true)][string]$AuthorityReferencePath,
    [Parameter(Mandatory=$true)][string]$BuilderIdentity,[Parameter(Mandatory=$true)][string]$BuilderTask,
    [Parameter(Mandatory=$true)][string]$ReviewerIdentity,[Parameter(Mandatory=$true)][string]$ReviewerTask,
    [Parameter(Mandatory=$true)][string]$ReviewResultPath,
    [Parameter(Mandatory=$true)][string]$ExternalOutputRoot,[Parameter(Mandatory=$true)][string]$OutputPath,
    [Parameter(Mandatory=$true)][string]$RepositoryRoot,[Parameter(Mandatory=$true)][string]$EvidenceRoot,
    [string]$GitHubTokenEnvironmentVariable='GH_TOKEN',[switch]$PublishGitHubComment
)
Set-StrictMode -Version Latest;$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\lib\V02ReleaseArtifactProduction.ps1')
Assert-V02ReleaseArtifactGitId $ExpectedSourceCommit 'ExpectedSourceCommit'|Out-Null
Assert-V02ReleaseArtifactGitId $ExpectedSourceTree 'ExpectedSourceTree'|Out-Null
$hashes=@($ProfileFileSha256,$ProfileCanonicalSha256,$PackageReceiptSha256,$PackageReceiptFileSha256,$PackageArchiveSha256,$PackageManifestSha256,$PackageAppSha256,$PackageCoreSha256,$RendererManifestSha256,$RuntimeMatrixManifestSha256,$Issue9CandidateSha256)
foreach($hash in $hashes){Assert-V02ReleaseArtifactSha256 $hash 'Candidate binding SHA-256'|Out-Null}
$outputFull=Assert-V02ReleaseArtifactSafeOutput -Path $OutputPath -AllowedRoot $ExternalOutputRoot
Assert-V02ReleaseArtifactPathOutsideRoot -Path $outputFull -Root $RepositoryRoot -Context 'Independent Agent receipt output'|Out-Null
Assert-V02ReleaseArtifactPathOutsideRoot -Path $outputFull -Root $EvidenceRoot -Context 'Independent Agent receipt output'|Out-Null
Assert-V02ReleaseArtifactExistingFileWithinRoot -Path $PreclosureGitHubSnapshotPath -Root $EvidenceRoot -Context 'Preclosure GitHub snapshot'|Out-Null
$reviewResultFull=Assert-V02ReleaseArtifactExistingFileWithinRoot -Path $ReviewResultPath -Root $ExternalOutputRoot -Context 'Independent Agent review result'
Assert-V02ReleaseArtifactPathOutsideRoot -Path $reviewResultFull -Root $RepositoryRoot -Context 'Independent Agent review result'|Out-Null
Assert-V02ReleaseArtifactPathOutsideRoot -Path $reviewResultFull -Root $EvidenceRoot -Context 'Independent Agent review result'|Out-Null
if([StringComparer]::OrdinalIgnoreCase.Equals($reviewResultFull,$outputFull)){throw 'Review result and receipt output paths must be distinct.'}
$reviewResultInfo=Get-Item -LiteralPath $reviewResultFull;if($reviewResultInfo.Length-le0-or$reviewResultInfo.Length-gt16777216){throw 'Independent Agent review result must be 1..16777216 bytes.'}
$reviewResultSha=Get-V02ReleaseArtifactSha256File $reviewResultFull
$snapshotSha=Get-V02ReleaseArtifactSha256File $PreclosureGitHubSnapshotPath
$authoritySha=Get-V02ReleaseArtifactSha256File $AuthorityReferencePath
$candidate=[pscustomobject][ordered]@{SourceCommit=$ExpectedSourceCommit;SourceTree=$ExpectedSourceTree;ProfileId='herdrops-v0.2-package-software-only-issue-149';ProfileFileSha256=$ProfileFileSha256;ProfileCanonicalSha256=$ProfileCanonicalSha256;PackageReceiptSha256=$PackageReceiptSha256;PackageReceiptFileSha256=$PackageReceiptFileSha256;PackageArchiveSha256=$PackageArchiveSha256;PackageManifestSha256=$PackageManifestSha256;PackageAppSha256=$PackageAppSha256;PackageCoreSha256=$PackageCoreSha256;RendererManifestSha256=$RendererManifestSha256;RuntimeMatrixManifestSha256=$RuntimeMatrixManifestSha256;Issue9CandidateSha256=$Issue9CandidateSha256;PreclosureGitHubSnapshotSha256=$snapshotSha}
$builder=[pscustomobject][ordered]@{Identity=$BuilderIdentity;Task=$BuilderTask;Role='CandidateBuilder'}
$reviewer=[pscustomobject][ordered]@{Identity=$ReviewerIdentity;Task=$ReviewerTask;Role='IndependentAgentReviewer'}
Assert-V02ReleaseArtifactLogicalAgentRoles -Builder $builder -IndependentReviewer $reviewer
$review=[pscustomobject][ordered]@{Result='APPROVED_CANDIDATE_ONLY';OpenHighCriticalDefects=0;ReviewResultPath=$reviewResultFull;ReviewResultSha256=$reviewResultSha}
$commentBody=New-V02ReleaseArtifactAgentReviewCommentBody -Candidate $candidate -Builder $builder -IndependentReviewer $reviewer -Review $review
if(-not$PublishGitHubComment){throw 'GitHub mutation is disabled. Pass -PublishGitHubComment only after the role-distinct Agent review is final.'}
$comment=Publish-V02ReleaseArtifactAgentReviewComment -Body $commentBody -TokenEnvironmentVariable $GitHubTokenEnvironmentVariable
$receipt=[pscustomobject][ordered]@{
    SchemaVersion=4;EvidenceClass='ExternalIndependentCandidateReceipt';Result='APPROVED_CANDIDATE_ONLY'
    DecisionId='herdrops-v0.2-release-first-v4';ApprovalReference='https://github.com/OSHEThai/HerdrOps/issues/149#issuecomment-5396694185';AuthorityReference='Plan/DECISIONS.md#D-026';AuthorityReferenceSha256=$authoritySha
    Candidate=$candidate;Owner=[pscustomobject][ordered]@{Identity='@yutthaphon';Role='ProductOwner'};Builder=$builder;IndependentReviewer=$reviewer
    Review=$review
    Authentication=[pscustomobject][ordered]@{Method='LIVE_GITHUB_OWNER_AUTHENTICATED_AGENT_REVIEW_COMMENT';ApiUrl=$comment.apiUrl;HtmlUrl=$comment.htmlUrl;IssueNumber=149;CommentId=$comment.commentId;CommentAuthor=$comment.commentAuthor;AuthorAssociation=$comment.authorAssociation;CreatedAtUtc=$comment.createdAtUtc;UpdatedAtUtc=$comment.updatedAtUtc;CommentBodySha256=$comment.bodySha256;Authenticated=$true}
    RoleDistinct=$true;Runtime='NOT_OBSERVED';Release='NOT_OBSERVED';CreditGranted=$false
}
Publish-V02ReleaseArtifactJsonNoClobber -Value $receipt -OutputPath $OutputPath -AllowedRoot $ExternalOutputRoot
