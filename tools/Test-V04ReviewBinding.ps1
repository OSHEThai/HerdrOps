[CmdletBinding()]
param()

# Behavioral and fail-closed selftest for Assert-V04ReviewBinding.ps1.
# Runs against temporary isolated mock fixtures in temp only.
# NOTE: This selftest does NOT validate real committed records in docs/reviews/;
# real review binding is enforced exclusively in tools/Test-V04ReleaseGate.ps1.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$assertScript = Join-Path $PSScriptRoot 'lib\Assert-V04ReviewBinding.ps1'
$scratchRoot = Join-Path ([IO.Path]::GetTempPath()) ('herdrops-v04-review-binding-' + [Guid]::NewGuid().ToString('N'))
$fixtureRoot = Join-Path $scratchRoot 'repository'
$passed = 0

function Write-Utf8Text {
    param([string]$Path, [string]$Text)
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function Get-Sha256 {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Assert-Condition {
    param([string]$Name, [bool]$Condition)
    if (-not $Condition) { throw "FAILED: $Name" }
    $script:passed++
    Write-Output "PASS: $Name"
}

function Assert-Rejected {
    param([string]$Name, [string]$Reason, [scriptblock]$Action)
    $message = ''
    try { & $Action | Out-Null } catch { $message = $_.Exception.Message }
    Assert-Condition -Name $Name -Condition ($message -match [regex]::Escape("[V04_REVIEW_BINDING:$Reason]"))
}

New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null
try {
    & git -C $fixtureRoot init --quiet
    & git -C $fixtureRoot config core.autocrlf false
    Write-Utf8Text -Path (Join-Path $fixtureRoot 'src/a.txt') -Text "alpha`n"
    Write-Utf8Text -Path (Join-Path $fixtureRoot 'tools/gate.ps1') -Text "one`ntwo`n"
    & git -C $fixtureRoot add -- src/a.txt tools/gate.ps1
    & git -C $fixtureRoot -c user.name=SelfTest -c user.email=selftest@example.invalid commit --quiet -m 'fixture source'
    $head = (& git -C $fixtureRoot rev-parse HEAD).Trim()
    $tree = (& git -C $fixtureRoot rev-parse "$head`^{tree}").Trim()
    $aHash = Get-Sha256 -Path (Join-Path $fixtureRoot 'src/a.txt')
    $gateHash = Get-Sha256 -Path (Join-Path $fixtureRoot 'tools/gate.ps1')
    $manifestText = "SHA256 $aHash src/a.txt`nSHA256 $gateHash tools/gate.ps1`n"
    $manifestPath = Join-Path $fixtureRoot 'reviews/reviewed.sha256'
    $reviewPath = Join-Path $fixtureRoot 'reviews/review.md'
    Write-Utf8Text -Path $manifestPath -Text $manifestText
    $manifestHash = Get-Sha256 -Path $manifestPath
    $reviewText = @(
        'Verdict: PASS',
        "CandidateCommit: $head",
        "CandidateTree: $tree",
        'CandidateManifest: reviews/reviewed.sha256',
        "CandidateManifestSha256: $manifestHash",
        'CandidateManifestEntryCount: 2',
        'CandidateManifestTotalLines: 3',
        '') -join "`n"
    Write-Utf8Text -Path $reviewPath -Text $reviewText

    $valid = & $assertScript -ReviewRecordPath $reviewPath -RepositoryRoot $fixtureRoot -CurrentHead $head -RequiredReviewedPaths @('src/a.txt', 'tools/gate.ps1')
    Assert-Condition -Name 'valid canonical review binds candidate tree and bytes' -Condition ($valid.LocalIndependentReviewBinding -ceq 'PASS' -and $valid.CandidateCommit -ceq $head)

    $missing = & $assertScript -ReviewRecordPath (Join-Path $fixtureRoot 'reviews/missing.md') -RepositoryRoot $fixtureRoot -CurrentHead $head -RequiredReviewedPaths @('src/a.txt')
    Assert-Condition -Name 'missing review remains pending instead of earning acceptance' -Condition ($missing.IssueAcceptance -ceq 'PENDING INDEPENDENT REVIEW')

    Write-Utf8Text -Path (Join-Path $fixtureRoot 'src/a.txt') -Text "drifted`n"
    Assert-Rejected -Name 'reviewed byte drift fails closed' -Reason 'REVIEWED_FILE_HASH_MISMATCH' -Action {
        & $assertScript -ReviewRecordPath $reviewPath -RepositoryRoot $fixtureRoot -CurrentHead $head -RequiredReviewedPaths @('src/a.txt', 'tools/gate.ps1')
    }

    Write-Utf8Text -Path (Join-Path $fixtureRoot 'src/a.txt') -Text "alpha`n"
    Write-Utf8Text -Path $manifestPath -Text ($manifestText.Replace($gateHash, ('0' * 64)))
    Assert-Rejected -Name 'manifest hash drift fails closed' -Reason 'MANIFEST_HASH_MISMATCH' -Action {
        & $assertScript -ReviewRecordPath $reviewPath -RepositoryRoot $fixtureRoot -CurrentHead $head -RequiredReviewedPaths @('src/a.txt', 'tools/gate.ps1')
    }

    # Restore valid manifest
    Write-Utf8Text -Path $manifestPath -Text $manifestText

    # 5. Non-ancestor commit fails closed
    $orphanCommit = (& git -C $fixtureRoot -c user.name=SelfTest -c user.email=selftest@example.invalid commit-tree $tree -m 'orphan commit').Trim()
    $nonAncestorReviewPath = Join-Path $fixtureRoot 'reviews/non-ancestor-review.md'
    $nonAncestorReviewText = $reviewText.Replace($head, $orphanCommit)
    Write-Utf8Text -Path $nonAncestorReviewPath -Text $nonAncestorReviewText
    Assert-Rejected -Name 'non-ancestor candidate commit fails closed' -Reason 'GIT_NOT_ANCESTOR' -Action {
        & $assertScript -ReviewRecordPath $nonAncestorReviewPath -RepositoryRoot $fixtureRoot -CurrentHead $head -RequiredReviewedPaths @('src/a.txt', 'tools/gate.ps1')
    }

    # 6. Candidate tree mismatch fails closed
    $treeMismatchReviewPath = Join-Path $fixtureRoot 'reviews/tree-mismatch-review.md'
    $treeMismatchReviewText = $reviewText.Replace($tree, ('0' * 40))
    Write-Utf8Text -Path $treeMismatchReviewPath -Text $treeMismatchReviewText
    Assert-Rejected -Name 'candidate tree mismatch fails closed' -Reason 'CANDIDATE_TREE_MISMATCH' -Action {
        & $assertScript -ReviewRecordPath $treeMismatchReviewPath -RepositoryRoot $fixtureRoot -CurrentHead $head -RequiredReviewedPaths @('src/a.txt', 'tools/gate.ps1')
    }

    # 7. Manifest exact set mismatch (extra or missing paths) fails closed
    Assert-Rejected -Name 'manifest missing required path fails closed' -Reason 'MANIFEST_EXACT_SET_MISMATCH' -Action {
        & $assertScript -ReviewRecordPath $reviewPath -RepositoryRoot $fixtureRoot -CurrentHead $head -RequiredReviewedPaths @('src/a.txt', 'tools/gate.ps1', 'src/extra.txt')
    }
    Assert-Rejected -Name 'manifest with unrequired extra path fails closed' -Reason 'MANIFEST_EXACT_SET_MISMATCH' -Action {
        & $assertScript -ReviewRecordPath $reviewPath -RepositoryRoot $fixtureRoot -CurrentHead $head -RequiredReviewedPaths @('src/a.txt')
    }

    # 8. Manifest entry count mismatch fails closed
    $entryCountMismatchReviewPath = Join-Path $fixtureRoot 'reviews/entry-count-mismatch-review.md'
    $entryCountMismatchReviewText = $reviewText.Replace('CandidateManifestEntryCount: 2', 'CandidateManifestEntryCount: 99')
    Write-Utf8Text -Path $entryCountMismatchReviewPath -Text $entryCountMismatchReviewText
    Assert-Rejected -Name 'manifest entry count mismatch fails closed' -Reason 'MANIFEST_ENTRY_COUNT_MISMATCH' -Action {
        & $assertScript -ReviewRecordPath $entryCountMismatchReviewPath -RepositoryRoot $fixtureRoot -CurrentHead $head -RequiredReviewedPaths @('src/a.txt', 'tools/gate.ps1')
    }

    # 9. Manifest total lines mismatch fails closed
    $totalLinesMismatchReviewPath = Join-Path $fixtureRoot 'reviews/total-lines-mismatch-review.md'
    $totalLinesMismatchReviewText = $reviewText.Replace('CandidateManifestTotalLines: 3', 'CandidateManifestTotalLines: 999')
    Write-Utf8Text -Path $totalLinesMismatchReviewPath -Text $totalLinesMismatchReviewText
    Assert-Rejected -Name 'manifest total lines mismatch fails closed' -Reason 'MANIFEST_TOTAL_LINES_MISMATCH' -Action {
        & $assertScript -ReviewRecordPath $totalLinesMismatchReviewPath -RepositoryRoot $fixtureRoot -CurrentHead $head -RequiredReviewedPaths @('src/a.txt', 'tools/gate.ps1')
    }

    # 10. Non-PASS verdict fails closed
    $unavailableReviewPath = Join-Path $fixtureRoot 'reviews/unavailable-review.md'
    $unavailableReviewText = $reviewText.Replace('Verdict: PASS', 'Verdict: UNAVAILABLE')
    Write-Utf8Text -Path $unavailableReviewPath -Text $unavailableReviewText
    Assert-Rejected -Name 'non-PASS verdict fails closed' -Reason 'REVIEW_FIELD_FORMAT' -Action {
        & $assertScript -ReviewRecordPath $unavailableReviewPath -RepositoryRoot $fixtureRoot -CurrentHead $head -RequiredReviewedPaths @('src/a.txt', 'tools/gate.ps1')
    }

    # 11. Missing candidate field (old review format) fails closed
    $oldFormatReviewPath = Join-Path $fixtureRoot 'reviews/old-format-review.md'
    $oldFormatReviewText = "Verdict: PASS`nManifestPath: reviews/reviewed.sha256`n"
    Write-Utf8Text -Path $oldFormatReviewPath -Text $oldFormatReviewText
    Assert-Rejected -Name 'missing CandidateCommit field in old review fails closed' -Reason 'REVIEW_FIELD_COUNT' -Action {
        & $assertScript -ReviewRecordPath $oldFormatReviewPath -RepositoryRoot $fixtureRoot -CurrentHead $head -RequiredReviewedPaths @('src/a.txt', 'tools/gate.ps1')
    }

    # 12. Path escape attempt fails closed
    Assert-Rejected -Name 'escaping path in required paths fails closed' -Reason 'PATH_INVALID' -Action {
        & $assertScript -ReviewRecordPath $reviewPath -RepositoryRoot $fixtureRoot -CurrentHead $head -RequiredReviewedPaths @('src/a.txt', '../outside.txt')
    }
    Assert-Rejected -Name 'backslash path in required paths fails closed' -Reason 'PATH_INVALID' -Action {
        & $assertScript -ReviewRecordPath $reviewPath -RepositoryRoot $fixtureRoot -CurrentHead $head -RequiredReviewedPaths @('src\a.txt', 'tools/gate.ps1')
    }

    # 13. Duplicate path in required set fails closed
    Assert-Rejected -Name 'duplicate path in required set fails closed' -Reason 'REQUIRED_SET_DUPLICATE' -Action {
        & $assertScript -ReviewRecordPath $reviewPath -RepositoryRoot $fixtureRoot -CurrentHead $head -RequiredReviewedPaths @('src/a.txt', 'src/a.txt', 'tools/gate.ps1')
    }

    # 14. Malformed manifest line fails closed
    $malformedManifestPath = Join-Path $fixtureRoot 'reviews/malformed.sha256'
    Write-Utf8Text -Path $malformedManifestPath -Text "NOT_A_VALID_MANIFEST_LINE`n"
    $malformedManifestHash = Get-Sha256 -Path $malformedManifestPath
    $malformedReviewPath = Join-Path $fixtureRoot 'reviews/malformed-manifest-review.md'
    $malformedReviewText = @(
        'Verdict: PASS',
        "CandidateCommit: $head",
        "CandidateTree: $tree",
        'CandidateManifest: reviews/malformed.sha256',
        "CandidateManifestSha256: $malformedManifestHash",
        'CandidateManifestEntryCount: 1',
        'CandidateManifestTotalLines: 3',
        '') -join "`n"
    Write-Utf8Text -Path $malformedReviewPath -Text $malformedReviewText
    Assert-Rejected -Name 'malformed manifest line fails closed' -Reason 'MANIFEST_FORMAT' -Action {
        & $assertScript -ReviewRecordPath $malformedReviewPath -RepositoryRoot $fixtureRoot -CurrentHead $head -RequiredReviewedPaths @('src/a.txt')
    }

    # 15. CurrentHead blob mismatch when worktree does not match CurrentHead commit
    Write-Utf8Text -Path (Join-Path $fixtureRoot 'src/a.txt') -Text "alpha modified`n"
    & git -C $fixtureRoot add -- src/a.txt
    & git -C $fixtureRoot -c user.name=SelfTest -c user.email=selftest@example.invalid commit --quiet -m 'modify src/a.txt'
    $newHead = (& git -C $fixtureRoot rev-parse HEAD).Trim()
    # Restore worktree to alpha (matching old review manifest), but newHead has modified blob
    Write-Utf8Text -Path (Join-Path $fixtureRoot 'src/a.txt') -Text "alpha`n"
    Assert-Rejected -Name 'current head blob mismatch fails closed' -Reason 'CURRENT_HEAD_BLOB_MISMATCH' -Action {
        & $assertScript -ReviewRecordPath $reviewPath -RepositoryRoot $fixtureRoot -CurrentHead $newHead -RequiredReviewedPaths @('src/a.txt', 'tools/gate.ps1')
    }

    # 16. Candidate blob mismatch when candidate commit contains an older blob than verified manifest
    Write-Utf8Text -Path (Join-Path $fixtureRoot 'src/a.txt') -Text "alpha modified`n"
    $modAHash = Get-Sha256 -Path (Join-Path $fixtureRoot 'src/a.txt')
    $modManifestText = "SHA256 $modAHash src/a.txt`nSHA256 $gateHash tools/gate.ps1`n"
    $modManifestPath = Join-Path $fixtureRoot 'reviews/mod-manifest.sha256'
    Write-Utf8Text -Path $modManifestPath -Text $modManifestText
    $modManifestHash = Get-Sha256 -Path $modManifestPath
    $candidateMismatchReviewPath = Join-Path $fixtureRoot 'reviews/candidate-blob-mismatch-review.md'
    # CandidateCommit is $head (where src/a.txt was 'alpha'), but manifest and worktree/newHead have 'alpha modified'
    $candidateMismatchReviewText = @(
        'Verdict: PASS',
        "CandidateCommit: $head",
        "CandidateTree: $tree",
        'CandidateManifest: reviews/mod-manifest.sha256',
        "CandidateManifestSha256: $modManifestHash",
        'CandidateManifestEntryCount: 2',
        'CandidateManifestTotalLines: 3',
        '') -join "`n"
    Write-Utf8Text -Path $candidateMismatchReviewPath -Text $candidateMismatchReviewText
    Assert-Rejected -Name 'candidate blob mismatch fails closed' -Reason 'CANDIDATE_BLOB_MISMATCH' -Action {
        & $assertScript -ReviewRecordPath $candidateMismatchReviewPath -RepositoryRoot $fixtureRoot -CurrentHead $newHead -RequiredReviewedPaths @('src/a.txt', 'tools/gate.ps1')
    }
} finally {
    if (Test-Path -LiteralPath $scratchRoot) { Remove-Item -LiteralPath $scratchRoot -Recurse -Force }
}

if ($passed -ne 18) { throw "Expected 18 review-binding checks, observed $passed." }
Write-Output 'EvidenceClass: Static plus temp-only Synthetic review-binding checks'
Write-Output 'ActualHerdrRuntime: NOT OBSERVED / NOT CLAIMED'
Write-Output "Assert-V04ReviewBinding checks passed: $passed/18."
