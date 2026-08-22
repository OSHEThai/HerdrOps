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

function New-V02TestTelemetryPacket {
    param(
        [Parameter(Mandatory = $true)][string]$Nonce,
        [Parameter(Mandatory = $true)][long]$SequenceNumber,
        [Parameter(Mandatory = $true)][int]$BinIndex,
        [Parameter(Mandatory = $true)][int]$SampleIndex,
        [Parameter(Mandatory = $true)][int]$AppProcessId,
        [Parameter(Mandatory = $true)][int]$CoreProcessId,
        [Parameter(Mandatory = $true)][DateTime]$AppStartTimeUtc,
        [Parameter(Mandatory = $true)][DateTime]$CoreStartTimeUtc,
        [Parameter(Mandatory = $true)][string]$AppExecutablePath,
        [Parameter(Mandatory = $true)][string]$CoreExecutablePath,
        [Parameter(Mandatory = $true)][string]$AppExecutableSha256,
        [Parameter(Mandatory = $true)][string]$CoreExecutableSha256,
        [Parameter(Mandatory = $true)][string]$ObservedUtc,
        [Parameter(Mandatory = $false)][long[]]$LatencyMicroseconds = @(1..20 | ForEach-Object { 100000L }),
        [Parameter(Mandatory = $false)][long[]]$UiStallMicroseconds = @(1..20 | ForEach-Object { 10000L }),
        [Parameter(Mandatory = $false)][bool]$RendererStable = $true,
        [Parameter(Mandatory = $false)][string]$RepositoryRoot = $null
    )

    $raw = [pscustomobject][ordered]@{
        schemaVersion = 1
        nonce = $Nonce
        sequenceNumber = $SequenceNumber
        observedUtc = $ObservedUtc
        binIndex = $BinIndex
        sampleIndex = $SampleIndex
        producer = [pscustomobject][ordered]@{
            appProcessId = $AppProcessId
            coreProcessId = $CoreProcessId
            appStartTimeUtc = $AppStartTimeUtc.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ', [Globalization.CultureInfo]::InvariantCulture)
            coreStartTimeUtc = $CoreStartTimeUtc.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ', [Globalization.CultureInfo]::InvariantCulture)
            appExecutablePath = $AppExecutablePath
            coreExecutablePath = $CoreExecutablePath
            appExecutableSha256 = $AppExecutableSha256
            coreExecutableSha256 = $CoreExecutableSha256
        }
        metrics = [pscustomobject][ordered]@{
            latencyMicroseconds = @($LatencyMicroseconds | ForEach-Object { [long]$_ })
            uiStallMicroseconds = @($UiStallMicroseconds | ForEach-Object { [long]$_ })
            rendererStable = $RendererStable
        }
    }

    $canonicalBody = ConvertTo-RendererCanonicalJson $raw $RepositoryRoot
    $hash = Get-HumanDesignReviewSha256ForText $canonicalBody

    return [pscustomobject][ordered]@{
        schemaVersion = 1
        nonce = $Nonce
        sequenceNumber = $SequenceNumber
        observedUtc = $ObservedUtc
        binIndex = $BinIndex
        sampleIndex = $SampleIndex
        producer = $raw.producer
        metrics = $raw.metrics
        packetSha256 = $hash
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

        # Sample 0: Both alive, reaching the SHARED production Get-V02LiveProcessIdentity guard
        $null = Get-V02LiveProcessIdentity -Process $app -ExpectedProcessId $app.Id -ExpectedStartTimeUtc $appStartTimeUtc -Role 'App' -BinIndex 0 -SampleIndex 0
        $null = Get-V02LiveProcessIdentity -Process $core -ExpectedProcessId $core.Id -ExpectedStartTimeUtc $coreStartTimeUtc -Role 'Core' -BinIndex 0 -SampleIndex 0

        if ($GuardMode -eq 'UnexpectedExit') {
            # Terminate the App child
            Stop-OwnedProcessSafely $app $appStartTimeUtc
            $app.Refresh()
            if (-not $app.HasExited) {
                throw 'Controlled live probe could not terminate its owned App child.'
            }

            # Sample 1: Must reach shared production guard and throw unexpected exit
            $null = Get-V02LiveProcessIdentity -Process $app -ExpectedProcessId $app.Id -ExpectedStartTimeUtc $appStartTimeUtc -Role 'App' -BinIndex 0 -SampleIndex 1
        }
        elseif ($GuardMode -eq 'PidStartContinuity') {
            # Provide drifted expected start time (simulating PID recycle)
            $driftedStartTime = $appStartTimeUtc.AddSeconds(5)
            $null = Get-V02LiveProcessIdentity -Process $app -ExpectedProcessId $app.Id -ExpectedStartTimeUtc $driftedStartTime -Role 'App' -BinIndex 0 -SampleIndex 1
        }
    } finally {
        Stop-OwnedProcessSafely $app $appStartTimeUtc
        Stop-OwnedProcessSafely $core $coreStartTimeUtc
        if (Test-Path -LiteralPath $probeRoot) {
            Remove-Item -LiteralPath $probeRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
