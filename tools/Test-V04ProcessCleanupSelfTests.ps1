# tools/Test-V04ProcessCleanupSelfTests.ps1
#
# Deterministic behavioral selftest for Stop-CoreProcessBounded (tools/lib/V04ProcessCleanup.ps1).
# Exercises both cleanup paths with real OS processes  -  no live Herdr instance required.
#
# Compatibility: Windows PowerShell 5.1 and PowerShell 7+.
# No ternary, no null-coalescing, no JSON depth parameter, no Process.Kill(bool).
#
# Two behavioral paths tested:
#   Already-exited path: process exits on its own before cleanup is called.
#     Stop-CoreProcessBounded must skip Kill(), must complete without error,
#     and the caller must observe HasExited=true after the call.
#   Running/timeout path: process is still running when cleanup is called.
#     Stop-CoreProcessBounded must call Kill(), drain within DrainMilliseconds,
#     and the process must be observed as HasExited=true on return.
#
# Processes used: cmd.exe /c exit <N> (already-exited) and ping.exe (long-running),
# both available on every supported Windows version. No network traffic; ping targets
# loopback (127.0.0.1) and is killed before any packet is sent in the timeout path.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path

# Import the shared library under test  -  both the gate script and this selftest use the
# exact same function definition, ensuring behavioral coverage matches gate usage.
. (Join-Path $PSScriptRoot 'lib\V04ProcessCleanup.ps1')

# -------------------------------------------------------------------------------------
# Assertion helpers
# -------------------------------------------------------------------------------------

$script:failures = [Collections.Generic.List[string]]::new()
$script:passCount = 0

function Assert-True {
    param([string]$Name, [bool]$Value, [string]$Because)
    if ($Value) {
        Write-Host "PASS $Name"
        $script:passCount++
    }
    else {
        Write-Host "FAIL $Name  -  $Because"
        $script:failures.Add("$Name  -  $Because")
    }
}

function Assert-False {
    param([string]$Name, [bool]$Value, [string]$Because)
    Assert-True -Name $Name -Value (-not $Value) -Because $Because
}

function Assert-WithinMs {
    param([string]$Name, [TimeSpan]$Elapsed, [int]$MaxMs, [string]$Because)
    Assert-True -Name $Name -Value ($Elapsed.TotalMilliseconds -lt $MaxMs) -Because "$Because (elapsed $([int]$Elapsed.TotalMilliseconds) ms, limit $MaxMs ms)"
}

# -------------------------------------------------------------------------------------
# Helper: start a cmd.exe process with Start-Process (mirroring gate script usage)
# -------------------------------------------------------------------------------------

function Start-TestProcess {
    param(
        [Parameter(Mandatory)]
        [string]$Command,
        [string[]]$ArgumentList = @()
    )
    return Start-Process `
        -FilePath $Command `
        -ArgumentList $ArgumentList `
        -WindowStyle Hidden `
        -PassThru
}

# -------------------------------------------------------------------------------------
# Test 1: Already-exited path
#
# Start cmd.exe /c exit 42. Wait for it to exit (so HasExited=true before cleanup).
# Stop-CoreProcessBounded must:
#   - NOT throw
#   - skip Kill() (observable only indirectly  -  the function completes without error
#     even though the OS handle is closed)
#   - return within a short wall-clock window (no drain delay needed)
#   - leave $proc.HasExited = true
# -------------------------------------------------------------------------------------

$proc1 = $null
try {
    $proc1 = Start-TestProcess -Command 'cmd.exe' -ArgumentList @('/c', 'exit 42')
    # Wait for the process to exit on its own before calling the helper.
    $didExit = $proc1.WaitForExit(5000)
    Assert-True 'AlreadyExited_ProcessExitedWithin5s' $didExit `
        'cmd.exe /c exit 42 must exit within 5 seconds'

    if ($didExit) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        Stop-CoreProcessBounded -Process $proc1 -DrainMilliseconds 3000
        $sw.Stop()

        Assert-True 'AlreadyExited_HasExitedAfterCleanup' $proc1.HasExited `
            'HasExited must be true after Stop-CoreProcessBounded on an already-exited process'
        Assert-WithinMs 'AlreadyExited_CompletesQuickly' $sw.Elapsed 1500 `
            'Already-exited path must not block for DrainMilliseconds  -  Kill() is skipped'
    }
}
catch {
    $script:failures.Add("AlreadyExited_PathThrew  -  $($_.Exception.Message)")
    Write-Host "FAIL AlreadyExited_PathThrew  -  $($_.Exception.Message)"
}

# -------------------------------------------------------------------------------------
# Test 2: Running / timeout-cleanup path
#
# Start ping.exe targeting loopback with a count large enough that it will not finish
# naturally within the test window (100 packets ~ 100 s). Call Stop-CoreProcessBounded
# immediately (without WaitForExit), so HasExited=false on entry. The helper must call
# Kill(), drain within DrainMilliseconds (3000 ms here), and HasExited must be true
# on return. Total wall-clock must be well under 3000 ms.
# -------------------------------------------------------------------------------------

$proc2 = $null
try {
    # ping /n 100 on 127.0.0.1 takes ~100 seconds. We kill it immediately.
    $proc2 = Start-TestProcess -Command 'ping.exe' -ArgumentList @('127.0.0.1', '-n', '100')

    # Give the process ~100 ms to start (so HasExited=false is reliable).
    Start-Sleep -Milliseconds 100

    Assert-False 'TimeoutCleanup_ProcessRunningBeforeCleanup' $proc2.HasExited `
        'ping.exe -n 100 should still be running after 100 ms'

    $sw = [Diagnostics.Stopwatch]::StartNew()
    Stop-CoreProcessBounded -Process $proc2 -DrainMilliseconds 3000
    $sw.Stop()

    $proc2.Refresh()
    Assert-True 'TimeoutCleanup_HasExitedAfterCleanup' $proc2.HasExited `
        'HasExited must be true after Stop-CoreProcessBounded kills the running process'
    Assert-WithinMs 'TimeoutCleanup_CompletesWithinDrainBound' $sw.Elapsed 3000 `
        'Stop-CoreProcessBounded must complete within DrainMilliseconds when killing a running process'
}
catch {
    $script:failures.Add("TimeoutCleanup_PathThrew  -  $($_.Exception.Message)")
    Write-Host "FAIL TimeoutCleanup_PathThrew  -  $($_.Exception.Message)"
}

# -------------------------------------------------------------------------------------
# Test 3: Idempotency  -  calling Stop-CoreProcessBounded twice on the same process
#
# After Test 2 the process is already dead. A second call must not throw.
# -------------------------------------------------------------------------------------

if ($null -ne $proc2 -and $proc2.HasExited) {
    try {
        Stop-CoreProcessBounded -Process $proc2 -DrainMilliseconds 1000
        $script:passCount++
        Write-Host 'PASS DoubleCleanup_Idempotent'
    }
    catch {
        $script:failures.Add("DoubleCleanup_Threw  -  $($_.Exception.Message)")
        Write-Host "FAIL DoubleCleanup_Threw  -  $($_.Exception.Message)"
    }
}
else {
    $script:failures.Add('DoubleCleanup_Skipped  -  proc2 not in expected state; check TimeoutCleanup tests')
    Write-Host 'SKIP DoubleCleanup_Skipped (proc2 not ready)'
}

# -------------------------------------------------------------------------------------
# Test 4: Zero-DrainMilliseconds does not hang  -  already-exited process
#
# DrainMilliseconds=0: WaitForExit(0) polls once and returns immediately. The
# subsequent blocking WaitForExit() on an already-exited process returns immediately.
# Must complete without deadlock.
# -------------------------------------------------------------------------------------

$proc4 = $null
try {
    $proc4 = Start-TestProcess -Command 'cmd.exe' -ArgumentList @('/c', 'exit 0')
    $proc4.WaitForExit(5000) | Out-Null

    $sw = [Diagnostics.Stopwatch]::StartNew()
    Stop-CoreProcessBounded -Process $proc4 -DrainMilliseconds 0
    $sw.Stop()

    Assert-True 'ZeroDrain_CompletesWithoutHang' ($sw.Elapsed.TotalMilliseconds -lt 1000) `
        'Stop-CoreProcessBounded with DrainMilliseconds=0 must complete within 1 s on an already-exited process'
}
catch {
    $script:failures.Add("ZeroDrain_Threw  -  $($_.Exception.Message)")
    Write-Host "FAIL ZeroDrain_Threw  -  $($_.Exception.Message)"
}

# -------------------------------------------------------------------------------------
# Summary
# -------------------------------------------------------------------------------------

$totalFails = $script:failures.Count
$totalPass  = $script:passCount
$totalRan   = $totalPass + $totalFails

Write-Host ''
if ($totalFails -eq 0) {
    Write-Host "All $totalPass Stop-CoreProcessBounded behavioral selftests passed under $($PSVersionTable.PSVersion) ."
    exit 0
}
else {
    Write-Host "$totalFails of $totalRan Stop-CoreProcessBounded behavioral selftests FAILED:"
    $script:failures | ForEach-Object { Write-Host "  - $_" }
    exit 1
}
