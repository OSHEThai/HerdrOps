<#
Focused, build-free tests for the v0.6 technical-gate hardening fixes (Issue #34):

  1. Assert-FreshEvidence must fail closed when PNG evidence is stale (or reused
     from a prior run) instead of silently accepting whatever bytes are on disk.
  2. Get-RepositoryRelativePath must return a path that is independent of the
     checkout location, so hashed gate reports remain byte-reproducible across
     different clones/worktrees.

Run directly with PowerShell; throws (and exits non-zero) on the first failed
assertion:

    pwsh -File tools/lib/V06GateProvenance.Tests.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'V06GateProvenance.ps1')

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

function Assert-Throws {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $threw = $false
    try {
        & $ScriptBlock
    }
    catch {
        $threw = $true
    }
    Assert-True -Condition $threw -Message $Message
}

$scratchRoot = Join-Path ([IO.Path]::GetTempPath()) ("v06-gate-provenance-tests-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratchRoot -Force | Out-Null

try {
    # --- Assert-FreshEvidence: fail-closed on stale/reused PNG evidence -------

    $freshFile = Join-Path $scratchRoot 'fresh.png'
    Set-Content -LiteralPath $freshFile -Value 'not really a png' -Encoding UTF8
    $captureStartedUtc = [DateTime]::UtcNow.AddSeconds(-2)

    Assert-True `
        -Condition ((& { Assert-FreshEvidence -Path $freshFile -NotBeforeUtc $captureStartedUtc -Description 'test evidence'; $true })) `
        -Message 'Assert-FreshEvidence accepts a file written after the capture window opened'

    $staleFile = Join-Path $scratchRoot 'stale.png'
    Set-Content -LiteralPath $staleFile -Value 'leftover from a previous run' -Encoding UTF8
    $staleTimestamp = [DateTime]::UtcNow.AddMinutes(-10)
    [IO.File]::SetLastWriteTimeUtc($staleFile, $staleTimestamp)
    $currentCaptureStartedUtc = [DateTime]::UtcNow.AddSeconds(-2)

    Assert-Throws `
        -ScriptBlock { Assert-FreshEvidence -Path $staleFile -NotBeforeUtc $currentCaptureStartedUtc -Description 'test evidence' } `
        -Message 'Assert-FreshEvidence fails closed on a PNG left over from an earlier run'

    # --- Get-RepositoryRelativePath: checkout-independent, reproducible paths -

    $checkoutOne = Join-Path $scratchRoot 'checkout-one\HerdrOps'
    $checkoutTwo = Join-Path $scratchRoot 'checkout-two-with-a-longer-name\HerdrOps'
    New-Item -ItemType Directory -Path (Join-Path $checkoutOne 'artifacts\release-gates\v0.6.0\issue-32') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $checkoutTwo 'artifacts\release-gates\v0.6.0\issue-32') -Force | Out-Null

    $reportOne = Join-Path $checkoutOne 'artifacts\release-gates\v0.6.0\issue-32\gate-report.txt'
    $reportTwo = Join-Path $checkoutTwo 'artifacts\release-gates\v0.6.0\issue-32\gate-report.txt'
    Set-Content -LiteralPath $reportOne -Value 'report' -Encoding UTF8
    Set-Content -LiteralPath $reportTwo -Value 'report' -Encoding UTF8

    $relativeOne = Get-RepositoryRelativePath -RepositoryRoot $checkoutOne -Path $reportOne
    $relativeTwo = Get-RepositoryRelativePath -RepositoryRoot $checkoutTwo -Path $reportTwo

    Assert-True `
        -Condition ($relativeOne -eq 'artifacts/release-gates/v0.6.0/issue-32/gate-report.txt') `
        -Message 'Get-RepositoryRelativePath strips the repository root and normalizes separators'

    Assert-True `
        -Condition ($relativeOne -eq $relativeTwo) `
        -Message 'Get-RepositoryRelativePath produces an identical value regardless of checkout location (hash reproducibility)'

    Assert-Throws `
        -ScriptBlock { Get-RepositoryRelativePath -RepositoryRoot $checkoutOne -Path (Join-Path $scratchRoot 'outside-the-repo.txt') } `
        -Message 'Get-RepositoryRelativePath rejects a path outside the repository root'
}
finally {
    Remove-Item -LiteralPath $scratchRoot -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host "$($failures.Count) assertion(s) failed:" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}

Write-Host ''
Write-Host 'All v0.6 gate-provenance hardening assertions passed.' -ForegroundColor Green
