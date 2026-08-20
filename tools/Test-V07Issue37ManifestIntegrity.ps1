<#
.SYNOPSIS
    Verify the Issue #37 independent review manifest integrity.

.DESCRIPTION
    Independently reproduces and validates the CandidateManifestSha256 and
    RemediationManifestSha256 values recorded in:
        docs/reviews/v0.7-issue-37-independent-review.md

    ManifestHashScheme: GitBlobSha256/v1
    ----------------------------------------
    SHA-256 of the raw Git blob bytes output by:
        git cat-file blob <blobSha1>
    The blob bytes are the verbatim file content stored in the Git object store,
    read via the git cat-file binary stream.  No BOM stripping, no line-ending
    normalisation, no character-encoding conversion is applied.  The hash covers
    exactly the bytes returned by git cat-file blob.

    Manifest anchor 1 -- CandidateManifestSha256 (original review):
      Commit:  79363ef  (docs(review): record independent evidence review for Issue #37 (#37))
      Blob:    33a6d4d1fa54e5162e7cd393474ea75668d819a4
      SHA-256: E705B62697D9908DC122B9FEC892814A63B3EAA5E9ED638307DF8F317B3A304F
      Scope:   SHA-256 of each manifested file read from the candidate commit
               4d36e288a0d4d8791f6afb7ba90e5ee0128c06ad (head of codex/v07-issue-37-recovery
               at review time).

    Manifest anchor 2 -- RemediationManifestSha256 (after P1 remediation):
      Commit:  1fcec2cf  (test(recovery): add apostrophe-path StateStoreRecovery quarantine test (#37))
      Blob:    8bfe715043cd2a3935ac3e1b3a8abeb87c856431
      SHA-256: 633FE04B260CFABC02D19E6AB69D32E2D5E2621AFCAEDBD67691CB8ADEB3B7F7
      Scope:   Same 35 entries; only StateStoreRecoveryTests.cs hash updated to reflect
               the new apostrophe-path test added at 1fcec2cf.

    Per-file entry verification rule (Check 5):
      - All entries except StateStoreRecoveryTests.cs: verified against candidate commit
        4d36e288 (the blob each entry was originally recorded from).
      - StateStoreRecoveryTests.cs: verified against remediation commit 1fcec2cf
        (its hash was updated in the manifest by that commit).

.PARAMETER RepoRoot
    Path to the working-tree root.  Defaults to the parent of the tools/ directory.

.EXAMPLE
    pwsh -File tools/Test-V07Issue37ManifestIntegrity.ps1
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

# ---------------------------------------------------------------------------
# Anchored constants (ManifestHashScheme: GitBlobSha256/v1)
# ---------------------------------------------------------------------------
$ORIGINAL_COMMIT             = '79363ef'
$ORIGINAL_BLOB_SHA1          = '33a6d4d1fa54e5162e7cd393474ea75668d819a4'
$ORIGINAL_EXPECTED_SHA256    = 'E705B62697D9908DC122B9FEC892814A63B3EAA5E9ED638307DF8F317B3A304F'

$REMEDIATION_COMMIT          = '1fcec2cf'
$REMEDIATION_BLOB_SHA1       = '8bfe715043cd2a3935ac3e1b3a8abeb87c856431'
$REMEDIATION_EXPECTED_SHA256 = '633FE04B260CFABC02D19E6AB69D32E2D5E2621AFCAEDBD67691CB8ADEB3B7F7'

# The original candidate commit: per-file hashes in the manifest were recorded here
$CANDIDATE_COMMIT            = '4d36e288a0d4d8791f6afb7ba90e5ee0128c06ad'

# The one file whose hash was updated by the remediation commit
$REMEDIATION_UPDATED_FILE    = 'tests/HerdrOps.IntegrationTests/StateStoreRecoveryTests.cs'

$MANIFEST_PATH               = 'docs/reviews/v0.7-issue-37-reviewed-files.sha256'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Get-GitBlobBytes {
    param([string]$Repo, [string]$BlobSha1)
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = 'git'
    $psi.Arguments = "-C `"$Repo`" cat-file blob $BlobSha1"
    $psi.RedirectStandardOutput = $true
    $psi.UseShellExecute = $false
    $proc = [System.Diagnostics.Process]::Start($psi)
    $ms = [System.IO.MemoryStream]::new()
    $proc.StandardOutput.BaseStream.CopyTo($ms)
    $proc.WaitForExit()
    if ($proc.ExitCode -ne 0) { throw "git cat-file blob $BlobSha1 exited $($proc.ExitCode)" }
    return $ms.ToArray()
}

function Get-GitBlobSha1ForCommit {
    param([string]$Repo, [string]$Commit, [string]$RelPath)
    $output = & git -C $Repo ls-tree $Commit $RelPath 2>&1
    if (-not $output) { return $null }
    $parts = ($output -split '\s+')
    if ($parts.Count -lt 3) { return $null }
    return $parts[2]
}

function Compute-Sha256Hex {
    param([byte[]]$Bytes)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $hashBytes = $sha256.ComputeHash($Bytes)
    return [BitConverter]::ToString($hashBytes).Replace('-', '')
}

function Assert-Equal {
    param([string]$Label, [string]$Expected, [string]$Actual)
    if ($Expected -eq $Actual) {
        Write-Host "  [PASS] $Label" -ForegroundColor Green
        return $true
    }
    Write-Host "  [FAIL] $Label" -ForegroundColor Red
    Write-Host "         Expected: $Expected"
    Write-Host "         Actual:   $Actual"
    return $false
}

# ---------------------------------------------------------------------------
Write-Host "Git: $(& git --version 2>&1)"
Write-Host "RepoRoot: $RepoRoot"
Write-Host ''

$passed = 0
$failed = 0

# --- Check 1: Original blob SHA1 at 79363ef --------------------------------
Write-Host '=== Check 1: Original review manifest blob (79363ef) ===' -ForegroundColor Cyan
$actualBlob1 = Get-GitBlobSha1ForCommit -Repo $RepoRoot -Commit $ORIGINAL_COMMIT -RelPath $MANIFEST_PATH
$ok = Assert-Equal 'Original blob SHA1 at 79363ef' $ORIGINAL_BLOB_SHA1 $actualBlob1
if ($ok) { $passed++ } else { $failed++ }

# --- Check 2: CandidateManifestSha256 reproducibility ----------------------
Write-Host ''
Write-Host '=== Check 2: CandidateManifestSha256 reproducibility ===' -ForegroundColor Cyan
Write-Host "  Rule: SHA-256(git cat-file blob $ORIGINAL_BLOB_SHA1)"
$originalBytes = Get-GitBlobBytes -Repo $RepoRoot -BlobSha1 $ORIGINAL_BLOB_SHA1
$actualSha256_1 = Compute-Sha256Hex -Bytes $originalBytes
Write-Host "  Blob size: $($originalBytes.Length) bytes"
$ok = Assert-Equal 'CandidateManifestSha256' $ORIGINAL_EXPECTED_SHA256 $actualSha256_1
if ($ok) { $passed++ } else { $failed++ }

# --- Check 3: Remediation blob SHA1 at 1fcec2cf ----------------------------
Write-Host ''
Write-Host '=== Check 3: Remediation manifest blob (1fcec2cf) ===' -ForegroundColor Cyan
$actualBlob2 = Get-GitBlobSha1ForCommit -Repo $RepoRoot -Commit $REMEDIATION_COMMIT -RelPath $MANIFEST_PATH
$ok = Assert-Equal 'Remediation blob SHA1 at 1fcec2cf' $REMEDIATION_BLOB_SHA1 $actualBlob2
if ($ok) { $passed++ } else { $failed++ }

# --- Check 4: RemediationManifestSha256 reproducibility --------------------
Write-Host ''
Write-Host '=== Check 4: RemediationManifestSha256 reproducibility ===' -ForegroundColor Cyan
Write-Host "  Rule: SHA-256(git cat-file blob $REMEDIATION_BLOB_SHA1)"
$remediationBytes = Get-GitBlobBytes -Repo $RepoRoot -BlobSha1 $REMEDIATION_BLOB_SHA1
$actualSha256_2 = Compute-Sha256Hex -Bytes $remediationBytes
Write-Host "  Blob size: $($remediationBytes.Length) bytes"
$ok = Assert-Equal 'RemediationManifestSha256' $REMEDIATION_EXPECTED_SHA256 $actualSha256_2
if ($ok) { $passed++ } else { $failed++ }

# --- Check 5: Per-file entries using correct commit anchors ----------------
Write-Host ''
Write-Host '=== Check 5: Per-file SHA-256 entries (anchored to candidate/remediation commits) ===' -ForegroundColor Cyan
Write-Host "  Default commit: $CANDIDATE_COMMIT"
Write-Host "  Exception:      $REMEDIATION_UPDATED_FILE -> $REMEDIATION_COMMIT"

$manifestText  = [System.Text.Encoding]::UTF8.GetString($remediationBytes)
$manifestLines = $manifestText -split "`n" | Where-Object { $_.Trim() -ne '' }
$entryCount = 0
$entryFails = 0

foreach ($line in $manifestLines) {
    $line = $line.TrimEnd("`r")
    if ($line -notmatch '^SHA256 ([0-9A-Fa-f]{64}) (.+)$') {
        Write-Host "  [WARN] Unrecognised line: $line" -ForegroundColor Yellow
        continue
    }
    $recordedHash = $Matches[1].ToUpper()
    $relPath      = ($Matches[2].Trim()) -replace '\\', '/'
    $entryCount++

    # Use remediation commit for the one file updated there; candidate commit for all others
    $effectiveCommit = if ($relPath -eq $REMEDIATION_UPDATED_FILE) { $REMEDIATION_COMMIT } else { $CANDIDATE_COMMIT }

    $entryBlobSha1 = Get-GitBlobSha1ForCommit -Repo $RepoRoot -Commit $effectiveCommit -RelPath $relPath
    if (-not $entryBlobSha1) {
        Write-Host "  [FAIL] $relPath not found in tree at $effectiveCommit" -ForegroundColor Red
        $entryFails++
        $failed++
        continue
    }
    $entryBytes = Get-GitBlobBytes -Repo $RepoRoot -BlobSha1 $entryBlobSha1
    $actualHash = Compute-Sha256Hex -Bytes $entryBytes

    if ($recordedHash -eq $actualHash) {
        Write-Host "  [PASS] $relPath" -ForegroundColor Green
        $passed++
    } else {
        Write-Host "  [FAIL] $relPath" -ForegroundColor Red
        Write-Host "         Recorded: $recordedHash"
        Write-Host "         Actual:   $actualHash"
        $entryFails++
        $failed++
    }
}
Write-Host "  Entries: $entryCount  Fails: $entryFails"

# --- Summary ---------------------------------------------------------------
Write-Host ''
Write-Host '=== Summary ===' -ForegroundColor Cyan
Write-Host "  Passed: $passed  Failed: $failed"
Write-Host ''
if ($failed -gt 0) {
    Write-Host 'RESULT: FAIL' -ForegroundColor Red
    exit 1
} else {
    Write-Host 'RESULT: PASS - all manifest integrity checks reproducible from canonical Git blob bytes.' -ForegroundColor Green
    exit 0
}
