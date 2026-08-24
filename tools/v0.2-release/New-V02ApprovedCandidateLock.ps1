#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$IndependentCandidateReceiptPath,[Parameter(Mandatory=$true)][string]$PreclosureGitHubSnapshotPath,
    [Parameter(Mandatory=$true)][string]$AuthorityReferencePath,[Parameter(Mandatory=$true)][string]$RepositoryRoot,[Parameter(Mandatory=$true)][string]$EvidenceRoot,
    [Parameter(Mandatory=$true)][string]$ExternalReviewRoot,[Parameter(Mandatory=$true)][string]$OutputPath
)
Set-StrictMode -Version Latest;$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\lib\V02ReleaseArtifactProduction.ps1')
$null=Assert-V02ReleaseArtifactSafeOutput -Path $OutputPath -AllowedRoot $EvidenceRoot
Assert-V02ReleaseArtifactExistingFileWithinRoot -Path $PreclosureGitHubSnapshotPath -Root $EvidenceRoot -Context 'Preclosure GitHub snapshot'|Out-Null
$independentReceiptFull=Assert-V02ReleaseArtifactExistingFileWithinRoot -Path $IndependentCandidateReceiptPath -Root $ExternalReviewRoot -Context 'Independent Agent receipt'
Assert-V02ReleaseArtifactPathOutsideRoot -Path $independentReceiptFull -Root $RepositoryRoot -Context 'Independent Agent receipt'|Out-Null
Assert-V02ReleaseArtifactPathOutsideRoot -Path $independentReceiptFull -Root $EvidenceRoot -Context 'Independent Agent receipt'|Out-Null
$receiptLease=Open-V02ReleaseArtifactFileLease $independentReceiptFull 'Independent Agent receipt';$snapshotLease=Open-V02ReleaseArtifactFileLease $PreclosureGitHubSnapshotPath 'Preclosure GitHub snapshot';$authorityLease=Open-V02ReleaseArtifactFileLease $AuthorityReferencePath 'Authority reference'
try {
$receipt=ConvertFrom-V02ReleaseArtifactCanonicalJsonBytes $receiptLease.Bytes 'Independent Agent receipt'
if([int]$receipt.SchemaVersion-ne4-or[string]$receipt.EvidenceClass-cne'ExternalIndependentCandidateReceipt'-or[string]$receipt.Result-cne'APPROVED_CANDIDATE_ONLY'){throw 'Independent receipt is not the closable schema v4 Agent review.'}
$receiptSha=$receiptLease.Sha256;$snapshotSha=$snapshotLease.Sha256
if([string]$receipt.Candidate.PreclosureGitHubSnapshotSha256-cne$snapshotSha){throw 'Independent receipt does not bind the exact preclosure GitHub snapshot bytes.'}
$authoritySha=$authorityLease.Sha256
$reviewResultFull=Assert-V02ReleaseArtifactExistingFileWithinRoot -Path ([string]$receipt.Review.ReviewResultPath) -Root $ExternalReviewRoot -Context 'Independent Agent review result'
Assert-V02ReleaseArtifactPathOutsideRoot -Path $reviewResultFull -Root $RepositoryRoot -Context 'Independent Agent review result'|Out-Null
Assert-V02ReleaseArtifactPathOutsideRoot -Path $reviewResultFull -Root $EvidenceRoot -Context 'Independent Agent review result'|Out-Null
$reviewResultLease=Open-V02ReleaseArtifactFileLease $reviewResultFull 'Independent Agent review result'
try {
$reviewResultSha=$reviewResultLease.Sha256
if([string]$receipt.Review.ReviewResultSha256-cne$reviewResultSha){throw 'Independent Agent review-result bytes do not match the owner-authenticated receipt.'}
$structuredReview=Read-V02ReleaseArtifactAgentReviewResult -Lease $reviewResultLease -ExpectedCandidate $receipt.Candidate
if((ConvertTo-V02Jcs $structuredReview.Builder)-cne(ConvertTo-V02Jcs $receipt.Builder)-or(ConvertTo-V02Jcs $structuredReview.IndependentReviewer)-cne(ConvertTo-V02Jcs $receipt.IndependentReviewer)){throw 'Independent Agent review-result roles do not match the receipt.'}
Assert-V02ReleaseArtifactLogicalAgentRoles -Builder $receipt.Builder -IndependentReviewer $receipt.IndependentReviewer
if([string]$receipt.Review.Result-cne'APPROVED_CANDIDATE_ONLY'-or[int]$receipt.Review.OpenHighCriticalDefects-ne0){throw 'Independent Agent review result is not closable.'}
if([string]$receipt.Authentication.Method-cne'LIVE_GITHUB_OWNER_AUTHENTICATED_AGENT_REVIEW_COMMENT'-or[string]$receipt.Authentication.CommentAuthor-cne'yutthaphon'-or-not[bool]$receipt.Authentication.Authenticated){throw 'Independent Agent receipt lacks the owner-authenticated GitHub comment boundary.'}
$commentBody=New-V02ReleaseArtifactAgentReviewCommentBody -Candidate $receipt.Candidate -Builder $receipt.Builder -IndependentReviewer $receipt.IndependentReviewer -Review $receipt.Review
$commentBodySha=Get-V02ReleaseArtifactSha256Bytes ([Text.UTF8Encoding]::new($false,$true).GetBytes($commentBody))
if([string]$receipt.Authentication.CommentBodySha256-cne$commentBodySha){throw 'Independent Agent receipt comment body hash is invalid.'}
if([string]$receipt.AuthorityReferenceSha256-cne$authoritySha){throw 'Independent Agent receipt authority bytes do not match Plan/DECISIONS.md.'}
$c=$receipt.Candidate;$a=$receipt.Authentication
$lock=[pscustomobject][ordered]@{
    SchemaVersion=3;EvidenceClass='ApprovedCandidateLock';Result='APPROVED';Immutable=$true
    SourceCommit=$c.SourceCommit;SourceTree=$c.SourceTree;ProfileId=$c.ProfileId;ProfileFileSha256=$c.ProfileFileSha256;ProfileCanonicalSha256=$c.ProfileCanonicalSha256
    PackageReceiptSha256=$c.PackageReceiptSha256;PackageReceiptFileSha256=$c.PackageReceiptFileSha256;PackageArchiveSha256=$c.PackageArchiveSha256;PackageManifestSha256=$c.PackageManifestSha256;PackageAppSha256=$c.PackageAppSha256;PackageCoreSha256=$c.PackageCoreSha256
    RendererManifestSha256=$c.RendererManifestSha256;RuntimeMatrixManifestSha256=$c.RuntimeMatrixManifestSha256;Issue9CandidateSha256=$c.Issue9CandidateSha256;PreclosureGitHubSnapshotSha256=$c.PreclosureGitHubSnapshotSha256
    Authority=[pscustomobject][ordered]@{DecisionId=$receipt.DecisionId;ApprovalReference=$receipt.ApprovalReference;PayloadSha256='4958E318AF4960C5BEC8B12BA69AED384236C91570BB86F872057066939ED904';Reference='Plan/DECISIONS.md#D-026';ReferenceSha256=$authoritySha;OwnerIdentity=$receipt.Owner.Identity;OwnerRole=$receipt.Owner.Role;Authentication='TRUSTED_OWNER_PLUS_LIVE_GITHUB_AGENT_REVIEW';IndependentReceiptPath=[IO.Path]::GetFullPath($IndependentCandidateReceiptPath);IndependentReceiptSha256=$receiptSha;IndependentReceiptIdentity=$receipt.IndependentReviewer.Identity;IndependentReceiptRole=$receipt.IndependentReviewer.Role;IndependentReceiptAuthentication=$a.Method;IndependentReceiptGitHubCommentId=[long]$a.CommentId;IndependentReceiptGitHubCommentUrl=$a.HtmlUrl;IndependentReceiptCommentBodySha256=$a.CommentBodySha256;IndependentReviewResultPath=[IO.Path]::GetFullPath([string]$receipt.Review.ReviewResultPath);IndependentReviewResultSha256=$receipt.Review.ReviewResultSha256}
    Runtime='NOT_OBSERVED';Release='NOT_OBSERVED'
}
Publish-V02ReleaseArtifactJsonNoClobber -Value $lock -OutputPath $OutputPath -AllowedRoot $EvidenceRoot
} finally {Close-V02ReleaseArtifactLease $reviewResultLease}
} finally {Close-V02ReleaseArtifactLease $authorityLease;Close-V02ReleaseArtifactLease $snapshotLease;Close-V02ReleaseArtifactLease $receiptLease}
