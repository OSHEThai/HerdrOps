[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ReviewRecordPath,

    [Parameter(Mandatory)]
    [string]$RepositoryRoot,

    [Parameter(Mandatory)]
    [string]$CurrentHead,

    [Parameter(Mandatory)]
    [string[]]$RequiredReviewedPaths
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

function Throw-BindingError {
    param(
        [Parameter(Mandatory)][string]$Reason,
        [Parameter(Mandatory)][string]$Message
    )

    throw "[V04_REVIEW_BINDING:$Reason] $Message"
}

function New-PendingBinding {
    [pscustomobject]@{
        IssueAcceptance = 'PENDING INDEPENDENT REVIEW'
        LocalIndependentReviewBinding = 'PENDING (CANONICAL REVIEW FILE NOT FOUND)'
        ReviewRecordSha256 = 'NONE'
        CandidateCommit = 'NONE'
        CandidateTree = 'NONE'
        CandidateManifest = 'NONE'
        CandidateManifestSha256 = 'NONE'
        CandidateManifestEntryCount = 0
        CandidateManifestTotalLines = 0
        IssueStateRequired = 'OPEN UNTIL INDEPENDENT REVIEW'
    }
}

function Get-CanonicalField {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Pattern
    )

    $matches = [regex]::Matches($Text, "(?m)^$([regex]::Escape($Name)): ([^\r\n]+)$")
    if ($matches.Count -ne 1) {
        Throw-BindingError -Reason 'REVIEW_FIELD_COUNT' -Message "Expected exactly one $Name field; observed $($matches.Count)."
    }

    $value = $matches[0].Groups[1].Value
    if ($value -notmatch "^$Pattern$") {
        Throw-BindingError -Reason 'REVIEW_FIELD_FORMAT' -Message "$Name is not canonical: $value"
    }

    return $value
}

function Get-CanonicalRelativePath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Context
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or
        [IO.Path]::IsPathRooted($Path) -or
        $Path.Contains('\') -or
        $Path.StartsWith('/') -or
        $Path.EndsWith('/') -or
        $Path -match '(^|/)\.(\.|/|$)' -or
        $Path -match '(^|/)\.\.(\/|$)' -or
        $Path -match '(^|/)(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|/|$)') {
        Throw-BindingError -Reason 'PATH_INVALID' -Message "$Context is not a canonical repository-relative path: $Path"
    }

    return $Path
}

function Resolve-ContainedFile {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Context
    )

    try {
        $rootFull = (Resolve-Path -LiteralPath $Root).Path.TrimEnd('\', '/')
        $fileFull = [IO.Path]::GetFullPath($Path)
    } catch {
        Throw-BindingError -Reason 'PATH_INVALID' -Message "$Context could not be normalized."
    }

    if (-not $fileFull.StartsWith($rootFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        Throw-BindingError -Reason 'PATH_ESCAPE' -Message "$Context escapes RepositoryRoot: $Path"
    }
    return $fileFull
}

function Invoke-GitText {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$Reason
    )

    $output = @(& git -C $Root @Arguments)
    if ($LASTEXITCODE -ne 0 -or $output.Count -ne 1) {
        Throw-BindingError -Reason $Reason -Message "Git command failed: git -C $Root $($Arguments -join ' ')"
    }
    return ([string]$output[0]).Trim()
}

if ($CurrentHead -notmatch '^[A-Fa-f0-9]{40}$') {
    Throw-BindingError -Reason 'CURRENT_HEAD_FORMAT' -Message 'CurrentHead must be exactly 40 hexadecimal characters.'
}
if (@($RequiredReviewedPaths).Count -eq 0) {
    Throw-BindingError -Reason 'REQUIRED_SET_EMPTY' -Message 'At least one reviewed path is required.'
}

$root = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$reviewFullPath = Resolve-ContainedFile -Root $root -Path $ReviewRecordPath -Context 'ReviewRecordPath'
if (-not (Test-Path -LiteralPath $reviewFullPath -PathType Leaf)) {
    New-PendingBinding
    return
}

$reviewText = Get-Content -LiteralPath $reviewFullPath -Raw -Encoding UTF8
$verdict = Get-CanonicalField -Text $reviewText -Name 'Verdict' -Pattern 'PASS'
$candidateCommit = (Get-CanonicalField -Text $reviewText -Name 'CandidateCommit' -Pattern '[A-Fa-f0-9]{40}').ToLowerInvariant()
$candidateTree = (Get-CanonicalField -Text $reviewText -Name 'CandidateTree' -Pattern '[A-Fa-f0-9]{40}').ToLowerInvariant()
$manifestRelativePath = Get-CanonicalField -Text $reviewText -Name 'CandidateManifest' -Pattern '[^\r\n]+'
$expectedManifestSha256 = (Get-CanonicalField -Text $reviewText -Name 'CandidateManifestSha256' -Pattern '[A-Fa-f0-9]{64}').ToUpperInvariant()
$expectedEntryCount = [int64](Get-CanonicalField -Text $reviewText -Name 'CandidateManifestEntryCount' -Pattern '[1-9][0-9]*')
$expectedTotalLines = [int64](Get-CanonicalField -Text $reviewText -Name 'CandidateManifestTotalLines' -Pattern '0|[1-9][0-9]*')
$manifestRelativePath = Get-CanonicalRelativePath -Path $manifestRelativePath -Context 'CandidateManifest'

$currentHead = $CurrentHead.ToLowerInvariant()
$observedTree = Invoke-GitText -Root $root -Arguments @('rev-parse', "$candidateCommit`^{tree}") -Reason 'GIT_OBJECT_INVALID'
if ($observedTree -ne $candidateTree) {
    Throw-BindingError -Reason 'CANDIDATE_TREE_MISMATCH' -Message "CandidateTree does not match CandidateCommit: $candidateTree versus $observedTree"
}

& git -C $root merge-base --is-ancestor $candidateCommit $currentHead
if ($LASTEXITCODE -ne 0) {
    Throw-BindingError -Reason 'GIT_NOT_ANCESTOR' -Message "CandidateCommit is not an ancestor of CurrentHead: $candidateCommit"
}

$manifestFullPath = Resolve-ContainedFile -Root $root -Path (Join-Path $root ($manifestRelativePath.Replace('/', [IO.Path]::DirectorySeparatorChar))) -Context 'CandidateManifest'
if (-not (Test-Path -LiteralPath $manifestFullPath -PathType Leaf)) {
    Throw-BindingError -Reason 'MANIFEST_MISSING' -Message "CandidateManifest is missing: $manifestRelativePath"
}
$manifestSha256 = (Get-FileHash -LiteralPath $manifestFullPath -Algorithm SHA256).Hash.ToUpperInvariant()
if ($manifestSha256 -ne $expectedManifestSha256) {
    Throw-BindingError -Reason 'MANIFEST_HASH_MISMATCH' -Message "CandidateManifest bytes do not match its declared hash."
}

$manifestText = Get-Content -LiteralPath $manifestFullPath -Raw -Encoding UTF8
$manifestLines = @($manifestText -split "\r\n|\n|\r")
if ($manifestLines.Count -gt 0 -and [string]::IsNullOrEmpty($manifestLines[-1])) {
    $manifestLines = @($manifestLines[0..($manifestLines.Count - 2)])
}
if ($manifestLines.Count -ne $expectedEntryCount) {
    Throw-BindingError -Reason 'MANIFEST_ENTRY_COUNT_MISMATCH' -Message "Expected $expectedEntryCount manifest entries, observed $($manifestLines.Count)."
}

$required = @($RequiredReviewedPaths | ForEach-Object { Get-CanonicalRelativePath -Path ([string]$_) -Context 'RequiredReviewedPath' })
$requiredSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($path in $required) {
    if (-not $requiredSet.Add($path)) {
        Throw-BindingError -Reason 'REQUIRED_SET_DUPLICATE' -Message "Required reviewed path is duplicated: $path"
    }
}
$manifestSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$manifestEntries = foreach ($line in $manifestLines) {
    if ($line -notmatch '^SHA256 ([A-Fa-f0-9]{64}) ([^\r\n]+)$') {
        Throw-BindingError -Reason 'MANIFEST_FORMAT' -Message "Manifest line is not canonical: $line"
    }
    $hash = $matches[1].ToUpperInvariant()
    $path = Get-CanonicalRelativePath -Path $matches[2] -Context 'ManifestPath'
    if (-not $manifestSet.Add($path)) {
        Throw-BindingError -Reason 'MANIFEST_PATH_DUPLICATE' -Message "Manifest path is duplicated: $path"
    }
    [pscustomobject]@{ Hash = $hash; Path = $path }
}

if ($manifestSet.Count -ne $requiredSet.Count -or
    @($required | Where-Object { -not $manifestSet.Contains($_) }).Count -ne 0 -or
    @($manifestEntries | Where-Object { -not $requiredSet.Contains($_.Path) }).Count -ne 0) {
    Throw-BindingError -Reason 'MANIFEST_EXACT_SET_MISMATCH' -Message 'CandidateManifest does not contain exactly the gate-required reviewed paths.'
}

$actualTotalLines = [int64]0
foreach ($entry in $manifestEntries) {
    $filePath = Resolve-ContainedFile -Root $root -Path (Join-Path $root ($entry.Path.Replace('/', [IO.Path]::DirectorySeparatorChar))) -Context $entry.Path
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        Throw-BindingError -Reason 'REVIEWED_FILE_MISSING' -Message "Reviewed file is missing: $($entry.Path)"
    }
    $actualHash = (Get-FileHash -LiteralPath $filePath -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($actualHash -ne $entry.Hash) {
        Throw-BindingError -Reason 'REVIEWED_FILE_HASH_MISMATCH' -Message "Reviewed file bytes do not match the manifest: $($entry.Path)"
    }
    $actualTotalLines += @([IO.File]::ReadAllLines($filePath)).Count
    $currentBlob = Invoke-GitText -Root $root -Arguments @('rev-parse', "${currentHead}:$($entry.Path)") -Reason 'CURRENT_HEAD_PATH_INVALID'
    $candidateBlob = Invoke-GitText -Root $root -Arguments @('rev-parse', "${candidateCommit}:$($entry.Path)") -Reason 'CANDIDATE_PATH_INVALID'
    $worktreeBlob = Invoke-GitText -Root $root -Arguments @('hash-object', '--', $filePath) -Reason 'WORKTREE_BLOB_INVALID'
    if ($worktreeBlob -ne $currentBlob) {
        Throw-BindingError -Reason 'CURRENT_HEAD_BLOB_MISMATCH' -Message "CurrentHead blob does not match current reviewed bytes: $($entry.Path)"
    }
    if ($candidateBlob -ne $worktreeBlob) {
        Throw-BindingError -Reason 'CANDIDATE_BLOB_MISMATCH' -Message "CandidateCommit blob does not match current reviewed bytes: $($entry.Path)"
    }
}
if ($actualTotalLines -ne $expectedTotalLines) {
    Throw-BindingError -Reason 'MANIFEST_TOTAL_LINES_MISMATCH' -Message "Expected $expectedTotalLines physical lines, observed $actualTotalLines."
}

[pscustomobject]@{
    IssueAcceptance = 'PASS (LOCAL CANONICAL REVIEW BINDING ONLY)'
    LocalIndependentReviewBinding = 'PASS'
    ReviewRecordSha256 = (Get-FileHash -LiteralPath $reviewFullPath -Algorithm SHA256).Hash.ToUpperInvariant()
    CandidateCommit = $candidateCommit
    CandidateTree = $candidateTree
    CandidateManifest = $manifestRelativePath
    CandidateManifestSha256 = $manifestSha256
    CandidateManifestEntryCount = $manifestLines.Count
    CandidateManifestTotalLines = $actualTotalLines
    IssueStateRequired = 'OPEN UNTIL INDEPENDENT REVIEW AND REQUIRED RUNTIME/RELEASE EVIDENCE'
}
