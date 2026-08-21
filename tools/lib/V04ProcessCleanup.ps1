# tools/lib/V04ProcessCleanup.ps1
#
# Shared bounded process-cleanup helper for v0.4 gate scripts.
# Dot-source this file to import Stop-CoreProcessBounded into the caller's scope.
#
# Compatibility: Windows PowerShell 5.1 and PowerShell 7+.
# No ternary, no null-coalescing, no ConvertFrom-Json -Depth, no Process.Kill(bool).
# Process.Kill(bool) (kill-entire-tree) requires .NET 5+ and is not available under
# Windows PowerShell 5.1 / .NET Framework 4.x. This library uses Kill() without
# arguments, which is available on all .NET versions.

# Bounded, fail-closed cleanup for a System.Diagnostics.Process object.
# Kills the process if it has not already exited (using argument-free Kill(), which is
# PS5.1-compatible). Waits up to DrainMilliseconds for the process to exit so that any
# redirected output files are fully flushed before the caller reads them.
#
# Two behavioral paths are covered:
#   Already-exited: $Process.HasExited is true on entry - Kill() is skipped; WaitForExit
#     returns immediately; function returns without error.
#   Running (timeout cleanup): $Process.HasExited is false on entry - Kill() is called,
#     then WaitForExit(DrainMilliseconds) polls the OS, then a final blocking WaitForExit()
#     ensures the handle is signalled. The process is guaranteed to exit before this
#     function returns, bounded by DrainMilliseconds + the OS kill-acknowledge latency.
function Stop-CoreProcessBounded {
    param(
        [Parameter(Mandatory)]
        [Diagnostics.Process]$Process,

        # Maximum milliseconds to wait for the process to exit after Kill().
        # Must be > 0. Default 5000 ms (5 s) is sufficient for a cooperative OS kill.
        [int]$DrainMilliseconds = 5000
    )

    if (-not $Process.HasExited) {
        $Process.Kill()
    }
    $Process.WaitForExit($DrainMilliseconds) | Out-Null
    $Process.WaitForExit()
}
