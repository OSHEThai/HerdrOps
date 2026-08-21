[CmdletBinding()]
param()

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
} finally {
    if (Test-Path -LiteralPath $scratchRoot) { Remove-Item -LiteralPath $scratchRoot -Recurse -Force }
}

if ($passed -ne 4) { throw "Expected 4 review-binding checks, observed $passed." }
Write-Output 'EvidenceClass: Static plus temp-only Synthetic review-binding checks'
Write-Output 'ActualHerdrRuntime: NOT OBSERVED / NOT CLAIMED'
Write-Output "Assert-V04ReviewBinding checks passed: $passed/4."
