#requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\RendererCompatibility.Common.ps1')

function Get-OwnedProcessStartTimeUtc([System.Diagnostics.Process]$Process) {
    for ($attempt = 0; $attempt -lt 100; $attempt++) {
        try {
            $Process.Refresh()
            if (-not $Process.HasExited) {
                return $Process.StartTime.ToUniversalTime()
            }
        } catch {
            # The child may not have completed initialization yet.
        }
        Start-Sleep -Milliseconds 25
    }
    throw "Controlled child process $($Process.Id) did not expose a live start time."
}

function Stop-OwnedProcessSafely([System.Diagnostics.Process]$Process, [DateTime]$ExpectedStartTimeUtc) {
    if ($null -eq $Process) {
        return
    }
    try {
        $Process.Refresh()
        if (-not $Process.HasExited -and $Process.StartTime.ToUniversalTime() -eq $ExpectedStartTimeUtc) {
            $Process.Kill()
            $null = $Process.WaitForExit(5000)
        }
    } catch {
        # Cleanup must not mask the guard assertion; only the owned identity is eligible.
    }
}

function Test-LiveProcessIdentityGuard {
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process]$Process,

        [Parameter(Mandatory = $true)]
        [int]$ExpectedProcessId,

        [Parameter(Mandatory = $true)]
        [DateTime]$ExpectedStartTimeUtc,

        [Parameter(Mandatory = $true)]
        [ValidateSet('App', 'Core')]
        [string]$Role,

        [Parameter(Mandatory = $true)]
        [int]$BinIndex,

        [Parameter(Mandatory = $true)]
        [int]$SampleIndex
    )

    $hasExited = $false
    $observedProcessId = $ExpectedProcessId
    $observedStartTimeUtc = $null
    try {
        $Process.Refresh()
        $hasExited = [bool]$Process.HasExited
        if (-not $hasExited) {
            $observedProcessId = [int]$Process.Id
            $observedStartTimeUtc = $Process.StartTime.ToUniversalTime()
        }
    } catch {
        throw "$Role process identity observation failed during soak bin $BinIndex sample ${SampleIndex}: $($_.Exception.Message)"
    }

    if ($hasExited) {
        throw "$Role process ($ExpectedProcessId) terminated unexpectedly during soak bin $BinIndex sample $SampleIndex."
    }

    if ($observedProcessId -ne $ExpectedProcessId) {
        throw "$Role process PID continuity failed: expected PID $ExpectedProcessId, observed PID $observedProcessId during soak bin $BinIndex sample $SampleIndex."
    }

    if ($null -eq $observedStartTimeUtc -or $observedStartTimeUtc -ne $ExpectedStartTimeUtc) {
        throw "$Role process PID ($ExpectedProcessId) was recycled during soak bin $BinIndex sample $SampleIndex."
    }

    return [pscustomobject][ordered]@{
        ProcessId = [int]$observedProcessId
        HasExited = [bool]$hasExited
        StartTimeUtc = $observedStartTimeUtc
    }
}

function Invoke-V02LiveGuardProbe {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('UnexpectedExit', 'PidStartContinuity')]
        [string]$GuardMode,

        [Parameter(Mandatory = $true)]
        [string]$TempRoot
    )

    $probeRoot = Join-Path $TempRoot ('live-guard-probe-' + $GuardMode.ToLowerInvariant() + '-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $probeRoot -Force | Out-Null

    $childEnginePath = Join-Path ([Environment]::GetEnvironmentVariable('SystemRoot')) 'System32\ping.exe'
    if (-not (Test-Path -LiteralPath $childEnginePath -PathType Leaf)) {
        throw "Unable to locate the controlled child executable: $childEnginePath"
    }

    $app = $null
    $core = $null
    $appStartTimeUtc = $null
    $coreStartTimeUtc = $null

    try {
        $childArguments = @('127.0.0.1', '-n', '120')
        $app = Start-Process -FilePath $childEnginePath -ArgumentList $childArguments -PassThru -WindowStyle Hidden
        $core = Start-Process -FilePath $childEnginePath -ArgumentList $childArguments -PassThru -WindowStyle Hidden
        $appStartTimeUtc = Get-OwnedProcessStartTimeUtc $app
        $coreStartTimeUtc = Get-OwnedProcessStartTimeUtc $core
        Start-Sleep -Milliseconds 500

        # Sample 0: Both alive, valid identities
        $null = Test-LiveProcessIdentityGuard -Process $app -ExpectedProcessId $app.Id -ExpectedStartTimeUtc $appStartTimeUtc -Role 'App' -BinIndex 0 -SampleIndex 0
        $null = Test-LiveProcessIdentityGuard -Process $core -ExpectedProcessId $core.Id -ExpectedStartTimeUtc $coreStartTimeUtc -Role 'Core' -BinIndex 0 -SampleIndex 0

        if ($GuardMode -eq 'UnexpectedExit') {
            # Terminate the App child
            Stop-OwnedProcessSafely $app $appStartTimeUtc
            $app.Refresh()
            if (-not $app.HasExited) {
                throw 'Controlled live probe could not terminate its owned App child.'
            }

            # Sample 1: Must throw unexpected exit
            $null = Test-LiveProcessIdentityGuard -Process $app -ExpectedProcessId $app.Id -ExpectedStartTimeUtc $appStartTimeUtc -Role 'App' -BinIndex 0 -SampleIndex 1
        }
        elseif ($GuardMode -eq 'PidStartContinuity') {
            # Provide drifted expected start time (simulating PID recycle)
            $driftedStartTime = $appStartTimeUtc.AddSeconds(5)
            $null = Test-LiveProcessIdentityGuard -Process $app -ExpectedProcessId $app.Id -ExpectedStartTimeUtc $driftedStartTime -Role 'App' -BinIndex 0 -SampleIndex 1
        }
    } finally {
        Stop-OwnedProcessSafely $app $appStartTimeUtc
        Stop-OwnedProcessSafely $core $coreStartTimeUtc
        if (Test-Path -LiteralPath $probeRoot) {
            Remove-Item -LiteralPath $probeRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
