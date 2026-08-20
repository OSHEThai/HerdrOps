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

.PARAMETER SelfTest
    Run deterministic in-memory negative parser and anchor self-tests without
    reading or writing repository files.

.EXAMPLE
    pwsh -File tools/Test-V07Issue37ManifestIntegrity.ps1
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path,
    [switch]$SelfTest
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
$EXPECTED_MANIFEST_ENTRY_COUNT = 35
$EXPECTED_MANIFEST_PATHS     = @(
    'src/HerdrOps.Core/HerdrOpsCoreStateServiceCommand.cs',
    'src/HerdrOps.Core/HerdrRuntimeEvidence.cs',
    'src/HerdrOps.Core/HerdrRuntimeMonitor.cs',
    'src/HerdrOps.Core/HerdrRuntimeMonitorFactory.cs',
    'src/HerdrOps.Core/HerdrRuntimeTraceCommand.cs',
    'src/HerdrOps.Core/StateStoreRestoreCommand.cs',
    'src/HerdrOps.Domain/Diagnostics/DiagnosticRedaction.cs',
    'src/HerdrOps.Infrastructure/Herdr/HerdrBundledSchemaExtractor.cs',
    'src/HerdrOps.Infrastructure/Herdr/HerdrExecutableSnapshotReader.cs',
    'src/HerdrOps.Infrastructure/Herdr/HerdrProtocolInspector.cs',
    'src/HerdrOps.Infrastructure/Herdr/HerdrProtocolJsonCodec.cs',
    'src/HerdrOps.Infrastructure/Herdr/HerdrServerIdentity.cs',
    'src/HerdrOps.Infrastructure/Storage/Recovery/StateStoreRecoveryArtifacts.cs',
    'src/HerdrOps.Infrastructure/Storage/Recovery/StateStoreRecoveryContracts.cs',
    'src/HerdrOps.Infrastructure/Storage/Recovery/StateStoreRecoveryPathPolicy.cs',
    'src/HerdrOps.Infrastructure/Storage/Recovery/StateStoreRecoveryService.cs',
    'src/HerdrOps.Contracts/HerdrBundledSchemaContract.cs',
    'src/HerdrOps.Contracts/HerdrProtocolContract.cs',
    'tests/HerdrOps.ContractTests/HerdrBundledSchemaExtractorContractTests.cs',
    'tests/HerdrOps.ContractTests/HerdrProtocolInspectorContractTests.cs',
    'tests/HerdrOps.ContractTests/HerdrProtocolJsonCodecContractTests.cs',
    'tests/HerdrOps.IntegrationTests/DiagnosticBundleTests.cs',
    'tests/HerdrOps.IntegrationTests/HerdrBundledSchemaInspectionCommandTests.cs',
    'tests/HerdrOps.IntegrationTests/HerdrNamedPipeApiClientTests.cs',
    'tests/HerdrOps.IntegrationTests/HerdrRuntimeMonitorTests.cs',
    'tests/HerdrOps.IntegrationTests/StateStoreRecoveryTests.cs',
    'tests/HerdrOps.RuntimeTests/LiveDashboardRenderingTests.cs',
    'tests/HerdrOps.RuntimeTests/MSTestSettings.cs',
    'tests/HerdrOps.RuntimeTests/RuntimeEvidenceResourceLifecycleTests.cs',
    'tests/HerdrOps.RuntimeTests/WpfTestHost.cs',
    'tools/Test-V02BundledSchemaContract.ps1',
    'tools/Test-V02HerdrRuntime.ps1',
    'tools/Test-V02LiveRuntimeAcceptance.ps1',
    'tools/Test-V05ComplianceQueue.ps1',
    'tools/Test-V06DailySummaryPage.ps1'
)

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

function Get-GitHeadCommit {
    param([string]$Repo)
    $output = & git -C $Repo rev-parse --verify HEAD 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "git rev-parse HEAD exited $LASTEXITCODE."
    }

    $commit = ($output | Out-String).Trim()
    if ($commit -notmatch '^[0-9a-fA-F]{40}$') {
        throw "git rev-parse HEAD returned an invalid commit id: $commit"
    }

    return $commit
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

function Assert-ManifestBlobAnchor {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ActualBlobSha1,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$PinnedBlobSha1
    )

    if ([string]::IsNullOrWhiteSpace($ActualBlobSha1) -or
        -not [string]::Equals($ActualBlobSha1, $PinnedBlobSha1, [StringComparison]::OrdinalIgnoreCase)) {
        throw "HEAD manifest blob '$ActualBlobSha1' does not match pinned remediation anchor '$PinnedBlobSha1'."
    }
}

function ConvertFrom-StrictManifest {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][string[]]$ExpectedPaths,
        [Parameter(Mandatory = $true)][int]$ExpectedCount
    )

    $utf8 = [System.Text.UTF8Encoding]::new($false, $true)
    try {
        $manifestText = $utf8.GetString($Bytes)
    }
    catch {
        throw "Manifest is not valid UTF-8: $($_.Exception.Message)"
    }

    $expectedSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($expectedPath in $ExpectedPaths) {
        [void]$expectedSet.Add($expectedPath)
    }

    $seenPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $entries = [System.Collections.Generic.List[object]]::new()
    $errors = [System.Collections.Generic.List[string]]::new()
    $manifestLines = $manifestText -split "`n"

    # A single final LF is canonical and does not represent an extra entry.
    if ($manifestLines.Count -gt 0 -and $manifestLines[-1] -eq '') {
        if ($manifestLines.Count -eq 1) {
            $manifestLines = @()
        }
        else {
            $manifestLines = $manifestLines[0..($manifestLines.Count - 2)]
        }
    }

    for ($index = 0; $index -lt $manifestLines.Count; $index++) {
        $lineNumber = $index + 1
        $line = [string]$manifestLines[$index]
        if ($line.EndsWith("`r", [StringComparison]::Ordinal)) {
            $line = $line.Substring(0, $line.Length - 1)
        }

        if ([string]::IsNullOrWhiteSpace($line)) {
            [void]$errors.Add("malformed blank line $lineNumber")
            continue
        }

        $match = [System.Text.RegularExpressions.Regex]::Match(
            $line,
            '^SHA256 ([0-9A-Fa-f]{64}) ([^ \t].*)\z',
            [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)
        if (-not $match.Success) {
            [void]$errors.Add("malformed line $lineNumber")
            continue
        }

        $recordedHash = $match.Groups[1].Value.ToUpperInvariant()
        $relativePath = $match.Groups[2].Value
        if (-not $expectedSet.Contains($relativePath)) {
            [void]$errors.Add("unexpected path '$relativePath'")
        }
        if (-not $seenPaths.Add($relativePath)) {
            [void]$errors.Add("duplicate path '$relativePath'")
        }

        [void]$entries.Add([pscustomobject]@{
            Hash = $recordedHash
            Path = $relativePath
        })
    }

    if ($entries.Count -ne $ExpectedCount) {
        [void]$errors.Add("expected exactly $ExpectedCount entries but found $($entries.Count)")
    }

    $missingPaths = @($ExpectedPaths | Where-Object { -not $seenPaths.Contains($_) })
    if ($missingPaths.Count -gt 0) {
        [void]$errors.Add("missing path(s): $($missingPaths -join ', ')")
    }

    if ($errors.Count -gt 0) {
        throw "Manifest validation failed: $($errors -join '; ')."
    }

    return $entries.ToArray()
}

function Assert-NegativeManifestCase {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$ManifestText,
        [Parameter(Mandatory = $true)][string[]]$ExpectedPaths,
        [Parameter(Mandatory = $true)][int]$ExpectedCount,
        [Parameter(Mandatory = $true)][string]$ExpectedMessage
    )

    $utf8 = [System.Text.UTF8Encoding]::new($false)
    try {
        ConvertFrom-StrictManifest `
            -Bytes $utf8.GetBytes($ManifestText) `
            -ExpectedPaths $ExpectedPaths `
            -ExpectedCount $ExpectedCount | Out-Null
        Write-Host "  [FAIL] negative self-test '$Name' was accepted" -ForegroundColor Red
        return $false
    }
    catch {
        if ($_.Exception.Message -like "*$ExpectedMessage*") {
            Write-Host "  [PASS] negative self-test '$Name' rejected" -ForegroundColor Green
            return $true
        }

        Write-Host "  [FAIL] negative self-test '$Name' rejected for an unexpected reason" -ForegroundColor Red
        Write-Host "         Expected fragment: $ExpectedMessage"
        Write-Host "         Actual: $($_.Exception.Message)"
        return $false
    }
}

function Invoke-DeterministicSelfTests {
    Write-Host '=== Deterministic negative self-tests ===' -ForegroundColor Cyan
    $hashA = ('A' * 64) -join ''
    $hashB = ('B' * 64) -join ''
    $hashC = ('C' * 64) -join ''
    $hashD = ('D' * 64) -join ''
    $expectedPaths = @('alpha.txt', 'beta.txt', 'gamma.txt')
    $validLines = @(
        "SHA256 $hashA alpha.txt",
        "SHA256 $hashB beta.txt",
        "SHA256 $hashC gamma.txt"
    )
    $validManifest = (($validLines -join "`n") + "`n")
    $failed = 0

    try {
        ConvertFrom-StrictManifest `
            -Bytes ([System.Text.UTF8Encoding]::new($false).GetBytes($validManifest)) `
            -ExpectedPaths $expectedPaths `
            -ExpectedCount 3 | Out-Null
        Write-Host "  [PASS] valid fixture accepted" -ForegroundColor Green
    }
    catch {
        Write-Host "  [FAIL] valid fixture rejected: $($_.Exception.Message)" -ForegroundColor Red
        $failed++
    }

    $cases = @(
        [pscustomobject]@{
            Name = 'malformed line'
            Text = ((($validLines[0], 'not a manifest record', $validLines[2]) -join "`n") + "`n")
            Expected = 'malformed line 2'
            Count = 3
        },
        [pscustomobject]@{
            Name = 'duplicate path'
            Text = (($validLines + $validLines[0]) -join "`n") + "`n"
            Expected = "duplicate path 'alpha.txt'"
            Count = 3
        },
        [pscustomobject]@{
            Name = 'unexpected path'
            Text = (($validLines[0], $validLines[1], "SHA256 $hashC delta.txt") -join "`n") + "`n"
            Expected = "unexpected path 'delta.txt'"
            Count = 3
        },
        [pscustomobject]@{
            Name = 'missing path'
            Text = (($validLines[0], $validLines[1]) -join "`n") + "`n"
            Expected = "missing path(s): gamma.txt"
            Count = 2
        },
        [pscustomobject]@{
            Name = 'wrong exact entry count'
            Text = (($validLines + "SHA256 $hashD delta.txt") -join "`n") + "`n"
            Expected = 'expected exactly 3 entries but found 4'
            Count = 3
        }
    )

    foreach ($case in $cases) {
        if (-not (Assert-NegativeManifestCase `
                -Name $case.Name `
                -ManifestText $case.Text `
                -ExpectedPaths $expectedPaths `
                -ExpectedCount $case.Count `
                -ExpectedMessage $case.Expected)) {
            $failed++
        }
    }

    try {
        Assert-ManifestBlobAnchor `
            -ActualBlobSha1 '0000000000000000000000000000000000000000' `
            -PinnedBlobSha1 '1111111111111111111111111111111111111111'
        Write-Host '  [FAIL] HEAD anchor mismatch was accepted' -ForegroundColor Red
        $failed++
    }
    catch {
        if ($_.Exception.Message -like '*does not match pinned remediation anchor*') {
            Write-Host '  [PASS] HEAD anchor mismatch rejected' -ForegroundColor Green
        }
        else {
            Write-Host "  [FAIL] HEAD anchor mismatch rejected for an unexpected reason: $($_.Exception.Message)" -ForegroundColor Red
            $failed++
        }
    }

    if ($failed -gt 0) {
        Write-Host "Self-test result: FAIL ($failed failure(s))." -ForegroundColor Red
        return $false
    }

    Write-Host 'Self-test result: PASS (valid fixture plus five deterministic negative cases and anchor mismatch).' -ForegroundColor Green
    return $true
}

if ($SelfTest) {
    if (-not (Invoke-DeterministicSelfTests)) {
        exit 1
    }
    exit 0
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

# --- Check 5: HEAD manifest blob must be the pinned remediation manifest -----
Write-Host ''
Write-Host '=== Check 5: HEAD manifest blob anchor ===' -ForegroundColor Cyan
$headCommit = $null
$headManifestBlobSha1 = $null
$headManifestAnchorOk = $false
try {
    $headCommit = Get-GitHeadCommit -Repo $RepoRoot
    $headManifestBlobSha1 = Get-GitBlobSha1ForCommit -Repo $RepoRoot -Commit $headCommit -RelPath $MANIFEST_PATH
    Assert-ManifestBlobAnchor -ActualBlobSha1 $headManifestBlobSha1 -PinnedBlobSha1 $REMEDIATION_BLOB_SHA1
    Write-Host "  [PASS] HEAD $headCommit manifest blob is pinned remediation blob $REMEDIATION_BLOB_SHA1" -ForegroundColor Green
    $headManifestAnchorOk = $true
    $passed++
}
catch {
    Write-Host '  [FAIL] HEAD manifest blob anchor' -ForegroundColor Red
    Write-Host "         $($_.Exception.Message)"
    $failed++
}

# --- Check 6: Per-file entries using correct commit anchors ----------------
Write-Host ''
Write-Host '=== Check 6: strict per-file SHA-256 entries (anchored to candidate/remediation commits) ===' -ForegroundColor Cyan
Write-Host "  Default commit: $CANDIDATE_COMMIT"
Write-Host "  Exception:      $REMEDIATION_UPDATED_FILE -> $REMEDIATION_COMMIT"

$entryCount = 0
$entryFails = 0
$manifestEntries = @()

if (-not $headManifestAnchorOk) {
    Write-Host '  [FAIL-CLOSED] Skipping entry verification because HEAD is not pinned to the remediation manifest.' -ForegroundColor Red
    $failed++
}
else {
    try {
        $headManifestBytes = Get-GitBlobBytes -Repo $RepoRoot -BlobSha1 $headManifestBlobSha1
        $manifestEntries = @(ConvertFrom-StrictManifest `
            -Bytes $headManifestBytes `
            -ExpectedPaths $EXPECTED_MANIFEST_PATHS `
            -ExpectedCount $EXPECTED_MANIFEST_ENTRY_COUNT)
        $entryCount = $manifestEntries.Count
        Write-Host "  [PASS] Manifest shape: exactly $EXPECTED_MANIFEST_ENTRY_COUNT entries; no malformed, duplicate, unexpected, or missing paths" -ForegroundColor Green
        $passed++
    }
    catch {
        Write-Host '  [FAIL] Strict manifest shape validation' -ForegroundColor Red
        Write-Host "         $($_.Exception.Message)"
        $failed++
    }
}

foreach ($entry in $manifestEntries) {
    $recordedHash = $entry.Hash
    $relPath      = $entry.Path

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
    Write-Host 'RESULT: PASS - HEAD is pinned to the canonical manifest and all strict integrity checks are reproducible from Git blob bytes.' -ForegroundColor Green
    exit 0
}
