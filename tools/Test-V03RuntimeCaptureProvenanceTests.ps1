<#
Deterministic, build-free hostile selftests for the shared v0.3 runtime-capture provenance
library (Issues #13, #15, and #16, tools/lib/V03RuntimeCaptureProvenance.ps1). No live Herdr session,
no dotnet build, and no network access are required or permitted here: every case constructs a
synthetic report fixture on disk and asserts that Assert-RuntimeCaptureReport /
Assert-NotReplayedTranscript reject it, or accept it, for an explicit reason.

Covers the five hostile evidence classes explicitly required for this harness:
  - synthetic (evidenceClassification != Runtime, sessionControlInvoked=true, missing/false
    required-true fields, or invalid JSON)
  - missing (report file absent or empty)
  - stale (report predates the capture window / reused from a prior run)
  - wrong-session (admission or monitor identity does not match the verified control session)
  - replayed (identical transcript SHA-256 already recorded in the run ledger)

Written for both Windows PowerShell 5.1 and PowerShell 7 (no ternary, null-coalescing, or other
PS7-only operators anywhere in this file or in the library it tests). Run directly; throws (and
exits non-zero) on the first failed assertion is not fatal to the run -- failures are collected
and reported at the end so one bad case does not hide the rest:

    pwsh -File tools/Test-V03RuntimeCaptureProvenanceTests.ps1
    powershell.exe -File tools/Test-V03RuntimeCaptureProvenanceTests.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib/V03RuntimeCaptureProvenance.ps1')

$failures = New-Object 'System.Collections.Generic.List[string]'

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        $failures.Add($Message)
        Write-Host "FAIL: $Message" -ForegroundColor Red
    }
    else {
        Write-Host "PASS: $Message"
    }
}

function Assert-ThrowsMatching {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
        [Parameter(Mandatory = $true)][string]$ExpectedPrefix,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $threw = $false
    $matched = $false
    try {
        & $ScriptBlock
    }
    catch {
        $threw = $true
        if ($_.Exception.Message -like "$ExpectedPrefix*") {
            $matched = $true
        }
        else {
            Write-Host "  (threw, but message did not start with '$ExpectedPrefix': $($_.Exception.Message))" -ForegroundColor Yellow
        }
    }

    Assert-True -Condition ($threw -and $matched) -Message $Message
}

$scratchRoot = Join-Path ([IO.Path]::GetTempPath()) ("v03-runtime-capture-provenance-tests-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratchRoot -Force | Out-Null

$controlExecutableSha256 = ('A' * 64)
$wrongExecutableSha256 = ('B' * 64)

function New-ValidReportFixture {
    param(
        [string]$Path,
        [string]$ExecutableSha256 = $controlExecutableSha256,
        [string]$EvidenceClassification = 'Runtime',
        [bool]$SessionControlInvoked = $false,
        [bool]$RuntimeObserved = $true,
        [hashtable]$RequiredTrueFieldValues = @{ fileSystemWatcherObserved = $true; gitStatusObserved = $true; herdrAgentCorrelationObserved = $true },
        [switch]$OmitAdmission,
        [switch]$InvalidJson,
        [string]$MonitorServerIdentityExecutableSha256 = $controlExecutableSha256,
        [switch]$OmitMonitorIdentity
    )

    if ($InvalidJson) {
        Set-Content -LiteralPath $Path -Value '{ this is not valid json ' -Encoding utf8
        return
    }

    $reportHash = [ordered]@{
        evidenceClassification = $EvidenceClassification
        sessionControlInvoked  = $SessionControlInvoked
        runtimeObserved        = $RuntimeObserved
    }
    foreach ($key in $RequiredTrueFieldValues.Keys) {
        $reportHash[$key] = $RequiredTrueFieldValues[$key]
    }

    if (-not $OmitAdmission) {
        $reportHash['admission'] = @{ executableSha256 = $ExecutableSha256 }
    }

    if (-not $OmitMonitorIdentity) {
        # $MonitorServerIdentityExecutableSha256 may deliberately be blank or malformed
        # (never filtered out here) so hostile cases can construct a monitorServerIdentity
        # object that is present-but-invalid, distinct from an entirely omitted one.
        $reportHash['monitorServerIdentity'] = @{ executableSha256 = $MonitorServerIdentityExecutableSha256 }
    }

    ($reportHash | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $Path -Encoding utf8
}

try {
    # --- Happy path: valid Issue #15-shaped and #16-shaped evidence is accepted ---

    $validIssue15Path = Join-Path $scratchRoot 'valid-issue-15.json'
    New-ValidReportFixture -Path $validIssue15Path
    $captureStartUtc = [DateTime]::UtcNow.AddSeconds(-5)
    Start-Sleep -Milliseconds 50

    $accepted15 = Assert-RuntimeCaptureReport `
        -ReportPath $validIssue15Path `
        -RequiredTrueFields @('fileSystemWatcherObserved', 'gitStatusObserved', 'herdrAgentCorrelationObserved') `
        -NotBeforeUtc $captureStartUtc `
        -ExpectedExecutableSha256 $controlExecutableSha256
    Assert-True -Condition ($accepted15.evidenceClassification -eq 'Runtime') -Message 'Accepts a genuinely valid Issue #15-shaped Runtime report'

    $validIssue16Path = Join-Path $scratchRoot 'valid-issue-16.json'
    New-ValidReportFixture -Path $validIssue16Path -RequiredTrueFieldValues @{ notificationDeliveryObserved = $true; herdrAgentCorrelationObserved = $true }
    $accepted16 = Assert-RuntimeCaptureReport `
        -ReportPath $validIssue16Path `
        -RequiredTrueFields @('notificationDeliveryObserved', 'herdrAgentCorrelationObserved') `
        -NotBeforeUtc $captureStartUtc `
        -ExpectedExecutableSha256 $controlExecutableSha256
    Assert-True -Condition ($accepted16.evidenceClassification -eq 'Runtime') -Message 'Accepts a genuinely valid Issue #16-shaped Runtime report'

    # --- Missing evidence -----------------------------------------------------

    Assert-ThrowsMatching `
        -ScriptBlock { Assert-RuntimeCaptureReport -ReportPath (Join-Path $scratchRoot 'does-not-exist.json') -RequiredTrueFields @('herdrAgentCorrelationObserved') -NotBeforeUtc $captureStartUtc -ExpectedExecutableSha256 $controlExecutableSha256 } `
        -ExpectedPrefix 'MissingEvidence' `
        -Message 'Rejects a report path that does not exist'

    $emptyPath = Join-Path $scratchRoot 'empty.json'
    Set-Content -LiteralPath $emptyPath -Value '' -Encoding utf8
    Assert-ThrowsMatching `
        -ScriptBlock { Assert-RuntimeCaptureReport -ReportPath $emptyPath -RequiredTrueFields @('herdrAgentCorrelationObserved') -NotBeforeUtc $captureStartUtc -ExpectedExecutableSha256 $controlExecutableSha256 } `
        -ExpectedPrefix 'MissingEvidence' `
        -Message 'Rejects an empty report file'

    # --- Stale / reused evidence ------------------------------------------------

    $stalePath = Join-Path $scratchRoot 'stale.json'
    New-ValidReportFixture -Path $stalePath
    [IO.File]::SetLastWriteTimeUtc($stalePath, [DateTime]::UtcNow.AddMinutes(-10))
    $freshCaptureStartUtc = [DateTime]::UtcNow.AddSeconds(-1)
    Assert-ThrowsMatching `
        -ScriptBlock { Assert-RuntimeCaptureReport -ReportPath $stalePath -RequiredTrueFields @('fileSystemWatcherObserved', 'gitStatusObserved', 'herdrAgentCorrelationObserved') -NotBeforeUtc $freshCaptureStartUtc -ExpectedExecutableSha256 $controlExecutableSha256 } `
        -ExpectedPrefix 'StaleEvidence' `
        -Message 'Rejects a report left over from an earlier run (LastWriteTimeUtc predates this run)'

    # --- Synthetic evidence -----------------------------------------------------

    $noCreditPath = Join-Path $scratchRoot 'no-runtime-credit.json'
    New-ValidReportFixture -Path $noCreditPath -EvidenceClassification 'NoRuntimeCredit'
    Assert-ThrowsMatching `
        -ScriptBlock { Assert-RuntimeCaptureReport -ReportPath $noCreditPath -RequiredTrueFields @('fileSystemWatcherObserved', 'gitStatusObserved', 'herdrAgentCorrelationObserved') -NotBeforeUtc $captureStartUtc -ExpectedExecutableSha256 $controlExecutableSha256 } `
        -ExpectedPrefix 'SyntheticEvidence' `
        -Message 'Rejects a report whose evidenceClassification is NoRuntimeCredit'

    $sessionControlPath = Join-Path $scratchRoot 'session-control.json'
    New-ValidReportFixture -Path $sessionControlPath -SessionControlInvoked $true
    Assert-ThrowsMatching `
        -ScriptBlock { Assert-RuntimeCaptureReport -ReportPath $sessionControlPath -RequiredTrueFields @('fileSystemWatcherObserved', 'gitStatusObserved', 'herdrAgentCorrelationObserved') -NotBeforeUtc $captureStartUtc -ExpectedExecutableSha256 $controlExecutableSha256 } `
        -ExpectedPrefix 'SyntheticEvidence' `
        -Message 'Rejects a report that admits sessionControlInvoked=true'

    $missingFieldPath = Join-Path $scratchRoot 'missing-required-field.json'
    New-ValidReportFixture -Path $missingFieldPath -RequiredTrueFieldValues @{ fileSystemWatcherObserved = $true; gitStatusObserved = $true; herdrAgentCorrelationObserved = $false }
    Assert-ThrowsMatching `
        -ScriptBlock { Assert-RuntimeCaptureReport -ReportPath $missingFieldPath -RequiredTrueFields @('fileSystemWatcherObserved', 'gitStatusObserved', 'herdrAgentCorrelationObserved') -NotBeforeUtc $captureStartUtc -ExpectedExecutableSha256 $controlExecutableSha256 } `
        -ExpectedPrefix 'SyntheticEvidence' `
        -Message 'Rejects a report where a required-true field (herdrAgentCorrelationObserved) is false'

    $invalidJsonPath = Join-Path $scratchRoot 'invalid.json'
    New-ValidReportFixture -Path $invalidJsonPath -InvalidJson
    [IO.File]::SetLastWriteTimeUtc($invalidJsonPath, [DateTime]::UtcNow)
    Assert-ThrowsMatching `
        -ScriptBlock { Assert-RuntimeCaptureReport -ReportPath $invalidJsonPath -RequiredTrueFields @('herdrAgentCorrelationObserved') -NotBeforeUtc $captureStartUtc -ExpectedExecutableSha256 $controlExecutableSha256 } `
        -ExpectedPrefix 'SyntheticEvidence' `
        -Message 'Rejects a report that is not valid JSON'

    # --- Wrong-session evidence --------------------------------------------------

    $wrongSessionPath = Join-Path $scratchRoot 'wrong-session.json'
    New-ValidReportFixture -Path $wrongSessionPath -ExecutableSha256 $wrongExecutableSha256
    Assert-ThrowsMatching `
        -ScriptBlock { Assert-RuntimeCaptureReport -ReportPath $wrongSessionPath -RequiredTrueFields @('fileSystemWatcherObserved', 'gitStatusObserved', 'herdrAgentCorrelationObserved') -NotBeforeUtc $captureStartUtc -ExpectedExecutableSha256 $controlExecutableSha256 } `
        -ExpectedPrefix 'WrongSessionEvidence' `
        -Message 'Rejects a report bound to a different admitted executable than the verified control session'

    $missingAdmissionPath = Join-Path $scratchRoot 'missing-admission.json'
    New-ValidReportFixture -Path $missingAdmissionPath -OmitAdmission
    Assert-ThrowsMatching `
        -ScriptBlock { Assert-RuntimeCaptureReport -ReportPath $missingAdmissionPath -RequiredTrueFields @('fileSystemWatcherObserved', 'gitStatusObserved', 'herdrAgentCorrelationObserved') -NotBeforeUtc $captureStartUtc -ExpectedExecutableSha256 $controlExecutableSha256 } `
        -ExpectedPrefix 'MissingEvidence' `
        -Message 'Rejects a report that omits admission executableSha256 entirely'

    $wrongMonitorPath = Join-Path $scratchRoot 'wrong-monitor-identity.json'
    New-ValidReportFixture -Path $wrongMonitorPath -MonitorServerIdentityExecutableSha256 $wrongExecutableSha256
    Assert-ThrowsMatching `
        -ScriptBlock { Assert-RuntimeCaptureReport -ReportPath $wrongMonitorPath -RequiredTrueFields @('fileSystemWatcherObserved', 'gitStatusObserved', 'herdrAgentCorrelationObserved') -NotBeforeUtc $captureStartUtc -ExpectedExecutableSha256 $controlExecutableSha256 } `
        -ExpectedPrefix 'WrongSessionEvidence' `
        -Message 'Rejects a report whose monitorServerIdentity does not match the verified control session, even when admission matches'

    $omittedMonitorPath = Join-Path $scratchRoot 'omitted-monitor-identity.json'
    New-ValidReportFixture -Path $omittedMonitorPath -OmitMonitorIdentity
    Assert-ThrowsMatching `
        -ScriptBlock { Assert-RuntimeCaptureReport -ReportPath $omittedMonitorPath -RequiredTrueFields @('fileSystemWatcherObserved', 'gitStatusObserved', 'herdrAgentCorrelationObserved') -NotBeforeUtc $captureStartUtc -ExpectedExecutableSha256 $controlExecutableSha256 } `
        -ExpectedPrefix 'MissingEvidence' `
        -Message 'Rejects a report that omits monitorServerIdentity entirely, even when admission matches'

    $blankMonitorPath = Join-Path $scratchRoot 'blank-monitor-identity.json'
    New-ValidReportFixture -Path $blankMonitorPath -MonitorServerIdentityExecutableSha256 ''
    Assert-ThrowsMatching `
        -ScriptBlock { Assert-RuntimeCaptureReport -ReportPath $blankMonitorPath -RequiredTrueFields @('fileSystemWatcherObserved', 'gitStatusObserved', 'herdrAgentCorrelationObserved') -NotBeforeUtc $captureStartUtc -ExpectedExecutableSha256 $controlExecutableSha256 } `
        -ExpectedPrefix 'SyntheticEvidence' `
        -Message 'Rejects a report whose monitorServerIdentity.executableSha256 is present but blank'

    $malformedMonitorPath = Join-Path $scratchRoot 'malformed-monitor-identity.json'
    New-ValidReportFixture -Path $malformedMonitorPath -MonitorServerIdentityExecutableSha256 'not-a-64-hex-sha256'
    Assert-ThrowsMatching `
        -ScriptBlock { Assert-RuntimeCaptureReport -ReportPath $malformedMonitorPath -RequiredTrueFields @('fileSystemWatcherObserved', 'gitStatusObserved', 'herdrAgentCorrelationObserved') -NotBeforeUtc $captureStartUtc -ExpectedExecutableSha256 $controlExecutableSha256 } `
        -ExpectedPrefix 'SyntheticEvidence' `
        -Message 'Rejects a report whose monitorServerIdentity.executableSha256 is not a well-formed 64-hex SHA-256'

    # --- Replayed evidence --------------------------------------------------------

    $ledgerPath = Join-Path $scratchRoot 'ledger.txt'
    $firstHash = Get-TextSha256 -Text 'first-transcript'
    $secondHash = Get-TextSha256 -Text 'second-transcript'

    Assert-True `
        -Condition ((& { Assert-NotReplayedTranscript -LedgerPath $ledgerPath -TranscriptSha256 $firstHash; $true })) `
        -Message 'Accepts a transcript hash that has never been recorded (no ledger yet)'

    Add-TranscriptLedgerEntry -LedgerPath $ledgerPath -TranscriptSha256 $firstHash

    Assert-ThrowsMatching `
        -ScriptBlock { Assert-NotReplayedTranscript -LedgerPath $ledgerPath -TranscriptSha256 $firstHash } `
        -ExpectedPrefix 'ReplayedEvidence' `
        -Message 'Rejects a transcript hash already recorded in the ledger from a prior run'

    Assert-True `
        -Condition ((& { Assert-NotReplayedTranscript -LedgerPath $ledgerPath -TranscriptSha256 $secondHash; $true })) `
        -Message 'Accepts a different, never-before-seen transcript hash after the ledger already has an entry'

    # --- Get-ControlHerdrServerIdentity fails closed without a live Herdr session -

    Assert-ThrowsMatching `
        -ScriptBlock { Get-ControlHerdrServerIdentity -ExpectedExecutablePath (Join-Path $scratchRoot 'no-such-herdr.exe') } `
        -ExpectedPrefix 'AuthorizedHerdrExecutableNotFound' `
        -Message 'Get-ControlHerdrServerIdentity fails closed when the expected Herdr executable does not exist'

    # --- Get-CleanSourceCommit: deterministic against an isolated scratch repo,
    #     never against the real repository (whose working-tree cleanliness this
    #     selftest must not depend on) ------------------------------------------

    $scratchRepoRoot = Join-Path $scratchRoot 'scratch-repo'
    New-Item -ItemType Directory -Path $scratchRepoRoot -Force | Out-Null
    & git -C $scratchRepoRoot init --quiet | Out-Null
    & git -C $scratchRepoRoot config user.email 'selftest@example.invalid' | Out-Null
    & git -C $scratchRepoRoot config user.name 'Selftest' | Out-Null
    Set-Content -LiteralPath (Join-Path $scratchRepoRoot 'file.txt') -Value 'content' -Encoding utf8
    & git -C $scratchRepoRoot add . | Out-Null
    & git -C $scratchRepoRoot commit --quiet -m 'initial' | Out-Null

    $commit = Get-CleanSourceCommit -RepositoryRoot $scratchRepoRoot
    Assert-True -Condition ($commit -match '^[0-9a-f]{40}$') -Message 'Get-CleanSourceCommit resolves a 40-character commit hash for a clean scratch repository'

    $expectedTree = (& git -C $scratchRepoRoot rev-parse --verify 'HEAD^{tree}').Trim()
    $identity = Get-ExpectedCleanSourceIdentity `
        -RepositoryRoot $scratchRepoRoot `
        -ExpectedSourceCommit $commit `
        -ExpectedSourceTree $expectedTree
    Assert-True -Condition ($identity.SourceCommit -ceq $commit -and $identity.SourceTree -ceq $expectedTree -and $identity.GitTreeClean) -Message 'Get-ExpectedCleanSourceIdentity binds clean HEAD commit, HEAD tree, and clean status'

    Assert-ThrowsMatching `
        -ScriptBlock { Get-ExpectedCleanSourceIdentity -RepositoryRoot $scratchRepoRoot -ExpectedSourceCommit $commit -ExpectedSourceTree ('0' * 40) } `
        -ExpectedPrefix 'SourceTreeMismatch' `
        -Message 'Get-ExpectedCleanSourceIdentity rejects an unexpected HEAD tree'

    $artifactRoot = Join-Path $scratchRoot 'artifacts'
    $artifactRunId = '20260822T1234567890123Z-deadbeef'
    $artifactRunDirectory = Join-Path $artifactRoot $artifactRunId
    $artifactReportPath = Join-Path $artifactRunDirectory 'runtime.json'
    $artifactGatePath = Join-Path $artifactRunDirectory 'gate-report.txt'
    $artifactIdentity = Get-RuntimeArtifactRunIdentity `
        -IssueEvidenceRoot $artifactRoot `
        -RunId $artifactRunId `
        -RunDirectory $artifactRunDirectory `
        -ReportPath $artifactReportPath `
        -GateReportPath $artifactGatePath
    Assert-True -Condition ($artifactIdentity.RunId -ceq $artifactRunId -and $artifactIdentity.ReportPath -ceq $artifactReportPath -and $artifactIdentity.GateReportPath -ceq $artifactGatePath) -Message 'Get-RuntimeArtifactRunIdentity binds report and gate paths to one run directory'

    Assert-ThrowsMatching `
        -ScriptBlock { Get-RuntimeArtifactRunIdentity -IssueEvidenceRoot $artifactRoot -RunId $artifactRunId -RunDirectory $artifactRunDirectory -ReportPath (Join-Path $artifactRoot 'runtime.json') -GateReportPath $artifactGatePath } `
        -ExpectedPrefix 'ArtifactRunIdentityMismatch' `
        -Message 'Get-RuntimeArtifactRunIdentity rejects a report outside its artifact run'

    $failureReportPath = Join-Path $artifactRunDirectory 'failure-gate-report.txt'
    Write-RuntimeCaptureFailureReport `
        -GateReportPath $failureReportPath `
        -SourceCommit $commit `
        -SourceTree $expectedTree `
        -ExpectedSourceCommit $commit `
        -ExpectedSourceTree $expectedTree `
        -RunId $artifactRunId `
        -ReportPath $artifactReportPath `
        -ReportSha256 ('C' * 64) `
        -FailureMessage 'synthetic failure for provenance selftest'
    $failureReportText = Get-Content -LiteralPath $failureReportPath -Raw
    Assert-True -Condition ($failureReportText -match 'EvidenceClass: NoRuntimeCredit' -and
        $failureReportText -match [regex]::Escape("ExpectedSourceTree: $expectedTree") -and
        $failureReportText -match [regex]::Escape("RunId: $artifactRunId") -and
        $failureReportText -match ('ReportSha256: ' + ('C' * 64))) -Message 'Failure reports preserve NoRuntimeCredit and exact source/run/report bindings'

    Set-Content -LiteralPath (Join-Path $scratchRepoRoot 'file.txt') -Value 'modified' -Encoding utf8
    Assert-ThrowsMatching `
        -ScriptBlock { Get-CleanSourceCommit -RepositoryRoot $scratchRepoRoot } `
        -ExpectedPrefix 'WorkingTreeDirty' `
        -Message 'Get-CleanSourceCommit fails closed against a repository with uncommitted changes'

    Assert-ThrowsMatching `
        -ScriptBlock { Get-ExpectedCleanSourceIdentity -RepositoryRoot $scratchRepoRoot -ExpectedSourceCommit $commit -ExpectedSourceTree $expectedTree } `
        -ExpectedPrefix 'WorkingTreeDirty' `
        -Message 'Get-ExpectedCleanSourceIdentity fails closed against a repository with uncommitted changes'

    Assert-ThrowsMatching `
        -ScriptBlock { Get-CleanSourceCommit -RepositoryRoot $scratchRoot } `
        -ExpectedPrefix 'SourceCommitResolutionFailed' `
        -Message 'Get-CleanSourceCommit fails closed against a directory that is not a Git repository'
}
finally {
    Remove-Item -LiteralPath $scratchRoot -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host "$($failures.Count) assertion(s) failed under PowerShell $($PSVersionTable.PSVersion):" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}

$global:LASTEXITCODE = 0
Write-Host ''
Write-Host "All v0.3 runtime-capture provenance hostile selftests passed under PowerShell $($PSVersionTable.PSVersion)." -ForegroundColor Green
exit 0
