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

    Squash / rebase independence (PR #112 remediation)
    ---------------------------------------------------
    This verifier does NOT depend on the branch-local review commits 79363ef or
    1fcec2cf.  The two immutable manifest anchor payloads are materialised as
    current-tree review-evidence files and verified against their pinned HEAD
    blob SHA1 and content SHA-256:

      CandidateManifest anchor:
        Path:      docs/reviews/v0.7-issue-37-reviewed-files.candidate.sha256
        Blob:      33a6d4d1fa54e5162e7cd393474ea75668d819a4
        SHA-256:   E705B62697D9908DC122B9FEC892814A63B3EAA5E9ED638307DF8F317B3A304F

      RemediationManifest anchor:
        Path:      docs/reviews/v0.7-issue-37-reviewed-files.sha256
        Blob:      8bfe715043cd2a3935ac3e1b3a8abeb87c856431
        SHA-256:   633FE04B260CFABC02D19E6AB69D32E2D5E2621AFCAEDBD67691CB8ADEB3B7F7

    Per-file entry verification rule:
      - All entries except StateStoreRecoveryTests.cs are verified against the
        candidate commit 4d36e288a0d4d8791f6afb7ba90e5ee0128c06ad, which is an
        ancestor of origin/main (retained because it is guaranteed to survive a
        merge / squash / rebase).
      - StateStoreRecoveryTests.cs is verified against the current HEAD tree
        (its remediation content is committed in this branch and will be
        carried into origin/main by the merge; no branch-local commit SHA is
        required).

    Reports
    -------
    Both -SelfTest and the normal verifier write deterministic reports under:
        artifacts/release-gates/v0.7.0/issue-37
    The report is written even on failure and always records the pass/fail
    boundary.  It never claims ActualHerdrRuntime or Release evidence.

.PARAMETER RepoRoot
    Path to the working-tree root.  Defaults to the parent of the tools/ directory,
    resolved after parameter binding so Windows PowerShell 5.1 can execute the
    script (PSScriptRoot is not available during default-value evaluation in 5.1).

.PARAMETER SelfTest
    Run deterministic in-memory negative parser, anchor-identity and report-boundary
    self-tests, then write a self-test report.  No tracked repository file is read
    or written except the gitignored report under artifacts/.

.EXAMPLE
    pwsh -File tools/Test-V07Issue37ManifestIntegrity.ps1

.EXAMPLE
    powershell -NoProfile -File tools/Test-V07Issue37ManifestIntegrity.ps1 -SelfTest
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = '',
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

# RepoRoot is resolved here, after parameter binding, because Windows PowerShell
# 5.1 does not populate $PSScriptRoot while evaluating parameter default values.
if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
}

# ---------------------------------------------------------------------------
# Anchored constants (ManifestHashScheme: GitBlobSha256/v1)
# ---------------------------------------------------------------------------
$CANDIDATE_MANIFEST_PATH      = 'docs/reviews/v0.7-issue-37-reviewed-files.candidate.sha256'
$CANDIDATE_BLOB_SHA1          = '33a6d4d1fa54e5162e7cd393474ea75668d819a4'
$CANDIDATE_EXPECTED_SHA256    = 'E705B62697D9908DC122B9FEC892814A63B3EAA5E9ED638307DF8F317B3A304F'

$REMEDIATION_MANIFEST_PATH    = 'docs/reviews/v0.7-issue-37-reviewed-files.sha256'
$REMEDIATION_BLOB_SHA1        = '8bfe715043cd2a3935ac3e1b3a8abeb87c856431'
$REMEDIATION_EXPECTED_SHA256  = '633FE04B260CFABC02D19E6AB69D32E2D5E2621AFCAEDBD67691CB8ADEB3B7F7'

# The candidate commit is an ancestor of origin/main and is therefore guaranteed
# to survive a merge / squash / rebase of this branch.
$CANDIDATE_COMMIT             = '4d36e288a0d4d8791f6afb7ba90e5ee0128c06ad'

# The one file whose hash was updated by the remediation and is now verified
# against the current HEAD tree (no historical commit required).
$REMEDIATION_UPDATED_FILE     = 'tests/HerdrOps.IntegrationTests/StateStoreRecoveryTests.cs'

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

# This is a separate successor-review scope. It deliberately does not alter
# either historical manifest or historical review record. A successor Agent
# must produce the actual manifest after independently reviewing these files.
$SUCCESSOR_SCOPE_TEMPLATE_PATH = 'docs/reviews/v0.7-issue-37-successor-review-scope.template.md'
$SUCCESSOR_REVIEW_SCOPE_PATHS = @(
    'docs/protocol/v0.7-diagnostic-bundle-contract.md',
    'src/HerdrOps.Domain/Diagnostics/DiagnosticBundleBuilder.cs',
    'src/HerdrOps.Domain/Diagnostics/DiagnosticBundleModels.cs',
    'src/HerdrOps.Infrastructure/Diagnostics/DiagnosticBundlePublisher.cs',
    'src/HerdrOps.Core/DiagnosticBundleCommand.cs',
    'src/HerdrOps.Core/Program.cs',
    'tests/HerdrOps.IntegrationTests/DiagnosticBundleTests.cs',
    'tests/HerdrOps.IntegrationTests/DiagnosticBundleCommandTests.cs'
)

$REPORT_DIRECTORY = Join-Path $RepoRoot 'artifacts\release-gates\v0.7.0\issue-37'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Get-GitBlobBytes {
    param(
        [Parameter(Mandatory = $true)][string]$Repo,
        [Parameter(Mandatory = $true)][string]$BlobSha1,
        [Parameter(Mandatory = $true)][string]$What
    )

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = 'git'
    $psi.Arguments = "-C `"$Repo`" cat-file blob $BlobSha1"
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false

    $proc = [System.Diagnostics.Process]::Start($psi)
    if ($null -eq $proc) {
        throw "Failed to start git for $What."
    }

    $ms = [System.IO.MemoryStream]::new()
    $proc.StandardOutput.BaseStream.CopyTo($ms)
    $proc.WaitForExit()

    if ($proc.ExitCode -ne 0) {
        $err = $proc.StandardError.ReadToEnd().Trim()
        throw "git cat-file blob $BlobSha1 ($What) failed (exit $($proc.ExitCode)): $(Get-ConciseGitError -Output $err)"
    }

    return $ms.ToArray()
}

function Get-ConciseGitError {
    param([Parameter(Mandatory = $true)][string]$Output)

    $lines = @($Output -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($lines.Count -eq 0) {
        return 'no output'
    }

    $fatalLines = @($lines | Where-Object { $_ -match '^(fatal|error):' })
    if ($fatalLines.Count -gt 0) {
        return $fatalLines[-1]
    }

    return $lines[-1]
}

function Get-TreeBlobSha1 {
    param(
        [Parameter(Mandatory = $true)][string]$Repo,
        [Parameter(Mandatory = $true)][string]$TreeIsh,
        [Parameter(Mandatory = $true)][string]$RelPath
    )

    $spec = "${TreeIsh}:$RelPath"
    $output = & git -C $Repo rev-parse $spec 2>&1
    $exitCode = $LASTEXITCODE
    $text = (($output | Out-String).Trim())

    if ($exitCode -ne 0) {
        throw "git rev-parse $spec failed (exit $exitCode): $(Get-ConciseGitError -Output $text)"
    }

    if ($text -notmatch '^[0-9a-fA-F]{40}$') {
        throw "git rev-parse $spec returned an invalid object id: '$text'"
    }

    return $text
}

function Get-GitHeadCommit {
    param([Parameter(Mandatory = $true)][string]$Repo)

    $output = & git -C $Repo rev-parse HEAD 2>&1
    $exitCode = $LASTEXITCODE
    $commit = (($output | Out-String).Trim())

    if ($exitCode -ne 0) {
        throw "git rev-parse HEAD failed (exit $exitCode): $(Get-ConciseGitError -Output $commit)"
    }

    if ($commit -notmatch '^[0-9a-fA-F]{40}$') {
        throw "git rev-parse HEAD returned an invalid commit id: '$commit'"
    }

    return $commit
}

function Compute-Sha256Hex {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $hashBytes = $sha256.ComputeHash($Bytes)
    return [BitConverter]::ToString($hashBytes).Replace('-', '')
}

function Assert-AnchorIdentity {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ActualBlobSha1,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$PinnedBlobSha1,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ActualSha256,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$PinnedSha256
    )

    if ([string]::IsNullOrWhiteSpace($ActualBlobSha1) -or
        -not [string]::Equals($ActualBlobSha1, $PinnedBlobSha1, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label blob SHA1 mismatch: actual '$ActualBlobSha1' does not match pinned '$PinnedBlobSha1'."
    }

    if ([string]::IsNullOrWhiteSpace($ActualSha256) -or
        -not [string]::Equals($ActualSha256, $PinnedSha256, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label content SHA-256 mismatch: actual '$ActualSha256' does not match pinned '$PinnedSha256'."
    }
}

function Get-EvidenceBoundaryLines {
    return @(
        'ActualHerdrRuntime: NOT OBSERVED / NOT CLAIMED',
        'ReleaseStatus: NOT CLAIMED',
        'NoRuntimeCredit: TRUE'
    )
}

function Assert-SuccessorScopeTemplateText {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $true)][string[]]$ExpectedPaths
    )

    if ($Text -match '(?im)^\s*(Verdict|ReviewVerdict|ReleaseGateAccepted)\s*:\s*(PASS|TRUE)\s*$') {
        throw 'Successor scope template contains an author-generated PASS or release acceptance.'
    }

    if ($Text -notmatch '(?m)^Status:\s*TEMPLATE / PENDING\s*$' -or
        $Text -notmatch '(?m)^ReviewVerdict:\s*PENDING\s*$' -or
        $Text -notmatch '(?m)^ReleaseGateAccepted:\s*FALSE\s*$') {
        throw 'Successor scope template must remain explicitly TEMPLATE/PENDING and not release-accepted.'
    }

    foreach ($expectedPath in $ExpectedPaths) {
        $escapedLine = [System.Text.RegularExpressions.Regex]::Escape('- `' + $expectedPath + '`')
        if ($Text -notmatch ('(?m)^' + $escapedLine + '\s*$')) {
            throw "Successor scope template is missing required path '$expectedPath'."
        }
    }
}

function Assert-SuccessorScopeTemplate {
    param(
        [Parameter(Mandatory = $true)][string]$Repo,
        [Parameter(Mandatory = $true)][string]$TemplatePath,
        [Parameter(Mandatory = $true)][string[]]$ExpectedPaths
    )

    $absolutePath = Join-Path $Repo $TemplatePath
    if (-not (Test-Path -LiteralPath $absolutePath -PathType Leaf)) {
        throw "Successor scope template is missing: $TemplatePath"
    }

    $text = Get-Content -LiteralPath $absolutePath -Raw
    Assert-SuccessorScopeTemplateText -Text $text -ExpectedPaths $ExpectedPaths
}

function Assert-SuccessorScopeFiles {
    param(
        [Parameter(Mandatory = $true)][string]$Repo,
        [Parameter(Mandatory = $true)][string[]]$RequiredPaths
    )

    foreach ($requiredPath in $RequiredPaths) {
        try {
            [void](Get-TreeBlobSha1 -Repo $Repo -TreeIsh 'HEAD' -RelPath $requiredPath)
        }
        catch {
            throw "Successor review required production/test file is missing at HEAD: $requiredPath"
        }
    }
}

function Assert-NegativeSuccessorScopeCase {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string[]]$ExpectedPaths,
        [Parameter(Mandatory = $true)][string]$ExpectedMessage
    )

    try {
        Assert-SuccessorScopeTemplateText -Text $Text -ExpectedPaths $ExpectedPaths
        Write-Host "  [FAIL] successor scope self-test '$Name' was accepted" -ForegroundColor Red
        return $false
    }
    catch {
        if ($_.Exception.Message -like "*$ExpectedMessage*") {
            Write-Host "  [PASS] successor scope self-test '$Name' rejected" -ForegroundColor Green
            return $true
        }

        Write-Host "  [FAIL] successor scope self-test '$Name' rejected for an unexpected reason" -ForegroundColor Red
        Write-Host "         Expected fragment: $ExpectedMessage"
        Write-Host "         Actual: $($_.Exception.Message)"
        return $false
    }
}

function Assert-NoRuntimeOrReleaseClaim {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string[]]$Lines)

    foreach ($line in $Lines) {
        if ($line -match '^ActualHerdrRuntime\s*:') {
            if ($line -notmatch '^ActualHerdrRuntime\s*:\s*NOT OBSERVED') {
                throw "report claims runtime evidence: $line"
            }
        }
        if ($line -match '^ReleaseStatus\s*:') {
            if ($line -notmatch '^ReleaseStatus\s*:\s*NOT CLAIMED') {
                throw "report claims release evidence: $line"
            }
        }
        if ($line -match '^\s*Release\s*:') {
            if ($line -notmatch '^\s*Release\s*:\s*(NOT CLAIMED|NOT OBSERVED|NOT REQUIRED)') {
                throw "report claims release evidence: $line"
            }
        }
    }
}

function Write-GateReport {
    param(
        [Parameter(Mandatory = $true)][string]$ReportDirectory,
        [Parameter(Mandatory = $true)][string]$ReportFileName,
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string]$Result,
        [Parameter(Mandatory = $true)][int]$Passed,
        [Parameter(Mandatory = $true)][int]$Failed,
        [Parameter(Mandatory = $false)][string[]]$DetailLines
    )

    $boundaryLines = Get-EvidenceBoundaryLines
    $lines = @(
        $Title,
        "GeneratedUtc: $([DateTime]::UtcNow.ToString('O'))",
        'Milestone: v0.7.0',
        'Issue: 37',
        "Result: $Result",
        "Passed: $Passed",
        "Failed: $Failed",
        'EvidenceClass: Static (repository review-evidence manifest/hash integrity)'
    ) + $boundaryLines

    if ($null -ne $DetailLines -and $DetailLines.Count -gt 0) {
        $lines += @('', 'Checks:') + $DetailLines
    }

    Assert-NoRuntimeOrReleaseClaim -Lines $lines

    New-Item -ItemType Directory -Path $ReportDirectory -Force | Out-Null
    $path = Join-Path $ReportDirectory $ReportFileName
    $lines | Set-Content -LiteralPath $path -Encoding utf8
    return $path
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

function Assert-NegativeAnchorCase {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$ExpectedMessage,
        [Parameter(Mandatory = $true)][string]$ActualBlobSha1,
        [Parameter(Mandatory = $true)][string]$PinnedBlobSha1,
        [Parameter(Mandatory = $true)][string]$ActualSha256,
        [Parameter(Mandatory = $true)][string]$PinnedSha256
    )

    try {
        Assert-AnchorIdentity `
            -Label $Name `
            -ActualBlobSha1 $ActualBlobSha1 `
            -PinnedBlobSha1 $PinnedBlobSha1 `
            -ActualSha256 $ActualSha256 `
            -PinnedSha256 $PinnedSha256
        Write-Host "  [FAIL] negative anchor self-test '$Name' was accepted" -ForegroundColor Red
        return $false
    }
    catch {
        if ($_.Exception.Message -like "*$ExpectedMessage*") {
            Write-Host "  [PASS] negative anchor self-test '$Name' rejected" -ForegroundColor Green
            return $true
        }

        Write-Host "  [FAIL] negative anchor self-test '$Name' rejected for an unexpected reason" -ForegroundColor Red
        Write-Host "         Expected fragment: $ExpectedMessage"
        Write-Host "         Actual: $($_.Exception.Message)"
        return $false
    }
}

function Assert-NegativeReportCase {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string[]]$Lines,
        [Parameter(Mandatory = $true)][string]$ExpectedMessage
    )

    try {
        Assert-NoRuntimeOrReleaseClaim -Lines $Lines
        Write-Host "  [FAIL] negative report self-test '$Name' was accepted" -ForegroundColor Red
        return $false
    }
    catch {
        if ($_.Exception.Message -like "*$ExpectedMessage*") {
            Write-Host "  [PASS] negative report self-test '$Name' rejected" -ForegroundColor Green
            return $true
        }

        Write-Host "  [FAIL] negative report self-test '$Name' rejected for an unexpected reason" -ForegroundColor Red
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
    $passed = 0

    try {
        ConvertFrom-StrictManifest `
            -Bytes ([System.Text.UTF8Encoding]::new($false).GetBytes($validManifest)) `
            -ExpectedPaths $expectedPaths `
            -ExpectedCount 3 | Out-Null
        Write-Host '  [PASS] valid fixture accepted' -ForegroundColor Green
        $passed++
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
        if (Assert-NegativeManifestCase `
                -Name $case.Name `
                -ManifestText $case.Text `
                -ExpectedPaths $expectedPaths `
                -ExpectedCount $case.Count `
                -ExpectedMessage $case.Expected) {
            $passed++
        }
        else {
            $failed++
        }
    }

    # Anchor-identity negatives: the materialised anchor is verified by BOTH its
    # HEAD blob SHA1 and its content SHA-256, independently (squash/rebase
    # independence).  Any drift in either dimension must fail closed.
    $anchorBlob = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    $anchorSha256 = ('11' * 32) -join ''

    try {
        Assert-AnchorIdentity `
            -Label 'anchor identity fixture' `
            -ActualBlobSha1 $anchorBlob `
            -PinnedBlobSha1 $anchorBlob `
            -ActualSha256 $anchorSha256 `
            -PinnedSha256 $anchorSha256
        Write-Host '  [PASS] anchor identity fixture accepted' -ForegroundColor Green
        $passed++
    }
    catch {
        Write-Host "  [FAIL] anchor identity fixture rejected: $($_.Exception.Message)" -ForegroundColor Red
        $failed++
    }

    if (Assert-NegativeAnchorCase `
            -Name 'blob SHA1 mismatch' `
            -ExpectedMessage 'blob SHA1 mismatch' `
            -ActualBlobSha1 '0000000000000000000000000000000000000000' `
            -PinnedBlobSha1 $anchorBlob `
            -ActualSha256 $anchorSha256 `
            -PinnedSha256 $anchorSha256) { $passed++ } else { $failed++ }

    if (Assert-NegativeAnchorCase `
            -Name 'content SHA-256 mismatch' `
            -ExpectedMessage 'content SHA-256 mismatch' `
            -ActualBlobSha1 $anchorBlob `
            -PinnedBlobSha1 $anchorBlob `
            -ActualSha256 (('22' * 32) -join '') `
            -PinnedSha256 $anchorSha256) { $passed++ } else { $failed++ }

    # Report-boundary negatives: the report must never claim runtime or release
    # evidence, and a boundary line that would do so must be rejected.
    $boundaryLines = Get-EvidenceBoundaryLines
    try {
        Assert-NoRuntimeOrReleaseClaim -Lines $boundaryLines
        Write-Host '  [PASS] report boundary fixture accepted' -ForegroundColor Green
        $passed++
    }
    catch {
        Write-Host "  [FAIL] report boundary fixture rejected: $($_.Exception.Message)" -ForegroundColor Red
        $failed++
    }

    if (Assert-NegativeReportCase `
            -Name 'runtime evidence claim' `
            -Lines @('ActualHerdrRuntime: OBSERVED') `
            -ExpectedMessage 'runtime evidence') { $passed++ } else { $failed++ }

    if (Assert-NegativeReportCase `
            -Name 'release evidence claim' `
            -Lines @('ReleaseStatus: CLAIMED') `
            -ExpectedMessage 'release evidence') { $passed++ } else { $failed++ }

    $validSuccessorScope = @(
        'Status: TEMPLATE / PENDING',
        'ReviewVerdict: PENDING',
        'ReleaseGateAccepted: FALSE'
    ) + ($SUCCESSOR_REVIEW_SCOPE_PATHS | ForEach-Object { '- `' + $_ + '`' }) -join "`n"
    try {
        Assert-SuccessorScopeTemplateText `
            -Text $validSuccessorScope `
            -ExpectedPaths $SUCCESSOR_REVIEW_SCOPE_PATHS
        Write-Host '  [PASS] successor required-scope template accepted' -ForegroundColor Green
        $passed++
    }
    catch {
        Write-Host "  [FAIL] successor required-scope template rejected: $($_.Exception.Message)" -ForegroundColor Red
        $failed++
    }

    $missingSuccessorPath = $SUCCESSOR_REVIEW_SCOPE_PATHS[0]
    $missingSuccessorScope = @(
        'Status: TEMPLATE / PENDING',
        'ReviewVerdict: PENDING',
        'ReleaseGateAccepted: FALSE'
    ) + ($SUCCESSOR_REVIEW_SCOPE_PATHS | Where-Object { $_ -ne $missingSuccessorPath } | ForEach-Object { '- `' + $_ + '`' }) -join "`n"
    if (Assert-NegativeSuccessorScopeCase `
            -Name 'missing required successor path' `
            -Text $missingSuccessorScope `
            -ExpectedPaths $SUCCESSOR_REVIEW_SCOPE_PATHS `
            -ExpectedMessage "missing required path '$missingSuccessorPath'") { $passed++ } else { $failed++ }

    $passSuccessorScope = $validSuccessorScope.Replace('ReviewVerdict: PENDING', 'ReviewVerdict: PASS')
    if (Assert-NegativeSuccessorScopeCase `
            -Name 'author-generated successor PASS' `
            -Text $passSuccessorScope `
            -ExpectedPaths $SUCCESSOR_REVIEW_SCOPE_PATHS `
            -ExpectedMessage 'author-generated PASS') { $passed++ } else { $failed++ }

    Write-Host ''
    if ($failed -gt 0) {
        Write-Host "Self-test result: FAIL ($failed failure(s), $passed pass(es))." -ForegroundColor Red
        return [pscustomobject]@{ Passed = $passed; Failed = $failed; Result = 'FAIL' }
    }

    Write-Host "Self-test result: PASS ($passed pass(es), $failed failure(s))." -ForegroundColor Green
    return [pscustomobject]@{ Passed = $passed; Failed = $failed; Result = 'PASS' }
}

if ($SelfTest) {
    $selfTestResult = Invoke-DeterministicSelfTests
    $selfTestReport = Write-GateReport `
        -ReportDirectory $REPORT_DIRECTORY `
        -ReportFileName 'selftest-report.txt' `
        -Title 'HerdrOps v0.7 Issue #37 Manifest Integrity Verifier - SelfTest' `
        -Result $selfTestResult.Result `
        -Passed $selfTestResult.Passed `
        -Failed $selfTestResult.Failed `
        -DetailLines @(
            'Scope: deterministic in-memory negative parser, anchor-identity, successor-scope, and report-boundary cases.',
            'No tracked repository file is read or written by -SelfTest.',
            'The gitignored self-test report above is the only filesystem artifact produced.'
        )
    Write-Host "GateReport: $selfTestReport"

    if ($selfTestResult.Failed -gt 0) {
        exit 1
    }
    exit 0
}

# ---------------------------------------------------------------------------
# Normal verifier
# ---------------------------------------------------------------------------
$gitVersion = ''
try {
    $gitVersion = ((& git --version 2>&1) | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        $gitVersion = "unavailable (exit $LASTEXITCODE)"
    }
}
catch {
    $gitVersion = 'unavailable'
}
Write-Host "Git: $gitVersion"
Write-Host "RepoRoot: $RepoRoot"
Write-Host ''

$passed = 0
$failed = 0
$detailLines = [System.Collections.Generic.List[string]]::new()

function Add-Pass {
    param([Parameter(Mandatory = $true)][string]$Name)
    $script:passed++
    [void]$script:detailLines.Add("PASS $Name")
}

function Add-Fail {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $false)][string]$Message
    )
    $script:failed++
    [void]$script:detailLines.Add("FAIL $Name")
    if (-not [string]::IsNullOrWhiteSpace($Message)) {
        [void]$script:detailLines.Add("     $Message")
    }
}

$headCommit = $null
try {
    $headCommit = Get-GitHeadCommit -Repo $RepoRoot
    Add-Pass "Resolve HEAD ($headCommit)"
}
catch {
    Add-Fail 'Resolve HEAD' $_.Exception.Message
}

# --- Check 1: Candidate manifest anchor (materialised, HEAD blob/content) ----
Write-Host '=== Check 1: Candidate manifest anchor (materialised current-tree file) ===' -ForegroundColor Cyan
try {
    $candidateBlob = Get-TreeBlobSha1 -Repo $RepoRoot -TreeIsh 'HEAD' -RelPath $CANDIDATE_MANIFEST_PATH
    $candidateBytes = Get-GitBlobBytes -Repo $RepoRoot -BlobSha1 $candidateBlob -What 'candidate manifest anchor'
    $candidateSha256 = Compute-Sha256Hex -Bytes $candidateBytes
    Assert-AnchorIdentity `
        -Label 'Candidate manifest anchor' `
        -ActualBlobSha1 $candidateBlob `
        -PinnedBlobSha1 $CANDIDATE_BLOB_SHA1 `
        -ActualSha256 $candidateSha256 `
        -PinnedSha256 $CANDIDATE_EXPECTED_SHA256
    Write-Host "  [PASS] HEAD blob $candidateBlob = pinned; SHA-256 $candidateSha256 = pinned ($($candidateBytes.Length) bytes)" -ForegroundColor Green
    Add-Pass 'Candidate manifest anchor (HEAD blob SHA1 + content SHA-256)'
}
catch {
    Write-Host "  [FAIL] $($_.Exception.Message)" -ForegroundColor Red
    Add-Fail 'Candidate manifest anchor (HEAD blob SHA1 + content SHA-256)' $_.Exception.Message
}

# --- Check 2: Remediation manifest anchor (materialised, HEAD blob/content) --
Write-Host ''
Write-Host '=== Check 2: Remediation manifest anchor (current-tree .sha256 file) ===' -ForegroundColor Cyan
try {
    $remediationBlob = Get-TreeBlobSha1 -Repo $RepoRoot -TreeIsh 'HEAD' -RelPath $REMEDIATION_MANIFEST_PATH
    $remediationBytes = Get-GitBlobBytes -Repo $RepoRoot -BlobSha1 $remediationBlob -What 'remediation manifest anchor'
    $remediationSha256 = Compute-Sha256Hex -Bytes $remediationBytes
    Assert-AnchorIdentity `
        -Label 'Remediation manifest anchor' `
        -ActualBlobSha1 $remediationBlob `
        -PinnedBlobSha1 $REMEDIATION_BLOB_SHA1 `
        -ActualSha256 $remediationSha256 `
        -PinnedSha256 $REMEDIATION_EXPECTED_SHA256
    Write-Host "  [PASS] HEAD blob $remediationBlob = pinned; SHA-256 $remediationSha256 = pinned ($($remediationBytes.Length) bytes)" -ForegroundColor Green
    Add-Pass 'Remediation manifest anchor (HEAD blob SHA1 + content SHA-256)'
}
catch {
    Write-Host "  [FAIL] $($_.Exception.Message)" -ForegroundColor Red
    Add-Fail 'Remediation manifest anchor (HEAD blob SHA1 + content SHA-256)' $_.Exception.Message
}

# --- Check 3: Strict manifest shape -----------------------------------------
Write-Host ''
Write-Host '=== Check 3: strict manifest shape (35 entries, ordinal allowlist) ===' -ForegroundColor Cyan
$manifestEntries = @()
$manifestShapeOk = $false
try {
    $manifestEntries = @(ConvertFrom-StrictManifest `
        -Bytes $remediationBytes `
        -ExpectedPaths $EXPECTED_MANIFEST_PATHS `
        -ExpectedCount $EXPECTED_MANIFEST_ENTRY_COUNT)
    Write-Host "  [PASS] exactly $EXPECTED_MANIFEST_ENTRY_COUNT entries; no malformed, duplicate, unexpected, or missing paths" -ForegroundColor Green
    Add-Pass 'Strict manifest shape (35 entries, ordinal allowlist)'
    $manifestShapeOk = $true
}
catch {
    Write-Host "  [FAIL] $($_.Exception.Message)" -ForegroundColor Red
    Add-Fail 'Strict manifest shape (35 entries, ordinal allowlist)' $_.Exception.Message
}

# --- Check 4: Per-file entries ----------------------------------------------
Write-Host ''
Write-Host '=== Check 4: strict per-file SHA-256 entries ===' -ForegroundColor Cyan
Write-Host "  Default anchor: candidate commit $CANDIDATE_COMMIT (ancestor of origin/main)"
Write-Host "  Exception:      $REMEDIATION_UPDATED_FILE -> current HEAD tree"

$entryCount = 0
$entryFails = 0

if (-not $manifestShapeOk) {
    Write-Host '  [FAIL-CLOSED] Skipping entry verification because the manifest shape is invalid.' -ForegroundColor Red
    Add-Fail 'Per-file entries' 'Skipped: manifest shape did not pass.'
}
else {
    foreach ($entry in $manifestEntries) {
        $recordedHash = $entry.Hash
        $relPath      = $entry.Path
        $entryCount++

        try {
            if ($relPath -eq $REMEDIATION_UPDATED_FILE) {
                $entryBlobSha1 = Get-TreeBlobSha1 -Repo $RepoRoot -TreeIsh 'HEAD' -RelPath $relPath
            }
            else {
                $entryBlobSha1 = Get-TreeBlobSha1 -Repo $RepoRoot -TreeIsh $CANDIDATE_COMMIT -RelPath $relPath
            }
            $entryBytes = Get-GitBlobBytes -Repo $RepoRoot -BlobSha1 $entryBlobSha1 -What "entry $relPath"
            $actualHash = Compute-Sha256Hex -Bytes $entryBytes

            if ($recordedHash -eq $actualHash) {
                Write-Host "  [PASS] $relPath" -ForegroundColor Green
                Add-Pass "entry $relPath"
            }
            else {
                Write-Host "  [FAIL] $relPath" -ForegroundColor Red
                Write-Host "         Recorded: $recordedHash"
                Write-Host "         Actual:   $actualHash"
                $entryFails++
                Add-Fail "entry $relPath" "recorded $recordedHash actual $actualHash"
            }
        }
        catch {
            Write-Host "  [FAIL] $relPath" -ForegroundColor Red
            Write-Host "         $($_.Exception.Message)"
            $entryFails++
            Add-Fail "entry $relPath" $_.Exception.Message
        }
    }
    Write-Host "  Entries: $entryCount  Fails: $entryFails"
}

# --- Check 5: successor required scope ------------------------------------
Write-Host ''
Write-Host '=== Check 5: successor review required scope (PENDING template) ===' -ForegroundColor Cyan
try {
    Assert-SuccessorScopeTemplate `
        -Repo $RepoRoot `
        -TemplatePath $SUCCESSOR_SCOPE_TEMPLATE_PATH `
        -ExpectedPaths $SUCCESSOR_REVIEW_SCOPE_PATHS
    Assert-SuccessorScopeFiles `
        -Repo $RepoRoot `
        -RequiredPaths $SUCCESSOR_REVIEW_SCOPE_PATHS
    Write-Host "  [PASS] template is PENDING and all $($SUCCESSOR_REVIEW_SCOPE_PATHS.Count) required files exist at HEAD" -ForegroundColor Green
    Add-Pass 'Successor review required scope (PENDING template and required files)'
}
catch {
    Write-Host "  [FAIL] $($_.Exception.Message)" -ForegroundColor Red
    Add-Fail 'Successor review required scope (PENDING template and required files)' $_.Exception.Message
}

# --- Summary ---------------------------------------------------------------
Write-Host ''
Write-Host '=== Summary ===' -ForegroundColor Cyan
Write-Host "  Passed: $passed  Failed: $failed"
Write-Host ''

$result = if ($failed -gt 0) { 'FAIL' } else { 'PASS' }
$reportPath = Write-GateReport `
    -ReportDirectory $REPORT_DIRECTORY `
    -ReportFileName 'gate-report.txt' `
    -Title 'HerdrOps v0.7 Issue #37 Manifest Integrity Verifier' `
    -Result $result `
    -Passed $passed `
    -Failed $failed `
    -DetailLines $detailLines
Write-Host "GateReport: $reportPath"
Write-Host ''

if ($failed -gt 0) {
    Write-Host 'RESULT: FAIL' -ForegroundColor Red
    exit 1
}
else {
    Write-Host 'RESULT: PASS - anchors verified from materialised current-tree blobs; strict integrity checks reproducible.' -ForegroundColor Green
    exit 0
}
