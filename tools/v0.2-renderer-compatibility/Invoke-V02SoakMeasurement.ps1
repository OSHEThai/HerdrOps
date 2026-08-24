#requires -Version 5.1

[CmdletBinding(DefaultParameterSetName = 'Live')]
param(
    [Parameter(ParameterSetName = 'Live')]
    [int]$CoreProcessId,

    [Parameter(ParameterSetName = 'Live')]
    [Parameter(ParameterSetName = 'Synthetic')]
    [string]$PackageIdentityPath,

    [Parameter(ParameterSetName = 'Live')]
    [Parameter(ParameterSetName = 'Synthetic')]
    [string]$PackageArchivePath,

    [Parameter(ParameterSetName = 'Live')]
    [Parameter(ParameterSetName = 'Synthetic')]
    [string]$ExtractedPackageRoot,

    [Parameter(ParameterSetName = 'Live')]
    [Parameter(ParameterSetName = 'Synthetic')]
    [string]$ExpectedSourceCommit,

    [Parameter(ParameterSetName = 'Live')]
    [Parameter(ParameterSetName = 'Synthetic')]
    [string]$ExpectedSourceTree,

    [Parameter(ParameterSetName = 'Live')]
    [string]$ChannelNonce,

    [Parameter(Mandatory = $true)]
    [ValidateSet('AC', 'Battery')]
    [string]$PowerSource,

    [Parameter(Mandatory = $true)]
    [string]$DestinationPath,

    [string]$EvidenceRoot,
    [string]$RepositoryRoot,

    [Parameter(ParameterSetName = 'Synthetic', Mandatory = $true)]
    [switch]$Synthetic,

    [Parameter(ParameterSetName = 'Synthetic')]
    [object]$SyntheticProcessTelemetryProvider,

    [Parameter(ParameterSetName = 'Synthetic')]
    [object]$SyntheticPowerStateProvider,

    [Parameter(ParameterSetName = 'Synthetic')]
    [ValidateRange(1, 24)]
    [int]$SyntheticTotalBins = 12,

    [Parameter(ParameterSetName = 'Synthetic')]
    [ValidateRange(1, 60)]
    [int]$SyntheticBinDurationMinutes = 5,

    [Parameter(ParameterSetName = 'Synthetic')]
    [ValidateRange(1, 10000)]
    [int]$SyntheticSamplesPerBin = 300,

    [Parameter(ParameterSetName = 'Synthetic')]
    [string]$TestFaultInjectionStage = 'None',

    [Parameter(ParameterSetName = 'Synthetic')]
    [switch]$TestInjectCleanupFailure
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'RendererCompatibility.Common.ps1')

if ($null -eq ('RendererCompatibility.NativePower' -as [type])) {
    $nativePowerCode = @"
using System;
using System.Runtime.InteropServices;
namespace RendererCompatibility {
    [StructLayout(LayoutKind.Sequential)]
    public struct SYSTEM_POWER_STATUS {
        public byte ACLineStatus;
        public byte BatteryFlag;
        public byte BatteryLifePercent;
        public byte SystemStatusFlag;
        public int BatteryLifeTime;
        public int BatteryFullLifeTime;
    }
    public static class NativePower {
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool GetSystemPowerStatus(out SYSTEM_POWER_STATUS lpSystemPowerStatus);
    }
}
"@
    Add-Type -TypeDefinition $nativePowerCode
}

function Get-CurrentPowerStatus {
    param([switch]$SyntheticMode, [object]$SyntheticProvider)
    if ($SyntheticMode -and $null -ne $SyntheticProvider) {
        if ($SyntheticProvider -is [scriptblock]) {
            return (& $SyntheticProvider)
        }
        return [string]$SyntheticProvider
    }

    $status = New-Object RendererCompatibility.SYSTEM_POWER_STATUS
    if (-not [RendererCompatibility.NativePower]::GetSystemPowerStatus([ref]$status)) {
        throw 'Unable to query host system power status via kernel32.dll!GetSystemPowerStatus.'
    }

    switch ($status.ACLineStatus) {
        0 { return 'Battery' }
        1 { return 'AC' }
        default { throw "System power status returned unknown AC line status ($($status.ACLineStatus))." }
    }
}

function Assert-SoakExactProperties {
    param([Parameter(Mandatory=$true)]$Value,[Parameter(Mandatory=$true)][string[]]$Names,[Parameter(Mandatory=$true)][string]$Context)
    if ($null -eq $Value -or $Value -isnot [psobject]) { throw "$Context is missing or not a JSON object." }
    $actual = @($Value.PSObject.Properties | ForEach-Object { $_.Name })
    if ($actual.Count -ne $Names.Count) { throw "$Context must contain exactly: $($Names -join ', ')." }
    foreach ($name in $Names) {
        $matches = @($Value.PSObject.Properties | Where-Object { [StringComparer]::Ordinal.Equals([string]$_.Name, $name) })
        if ($matches.Count -ne 1) { throw "$Context must contain exactly one case-sensitive '$name' property." }
    }
}

function ConvertTo-V02SoakNativeArgument { param([string]$Value)
    if($Value-notmatch'[\s"]'){return $Value};$b=New-Object Text.StringBuilder;[void]$b.Append('"');$n=0
    foreach($c in $Value.ToCharArray()){if($c-eq'\'){$n++;continue};if($c-eq'"'){[void]$b.Append(('\'*($n*2+1)));[void]$b.Append('"');$n=0;continue};if($n-gt0){[void]$b.Append(('\'*$n));$n=0};[void]$b.Append($c)}
    if($n-gt0){[void]$b.Append(('\'*($n*2)))};[void]$b.Append('"');$b.ToString()
}

# Resolve repository root
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
}
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)
Assert-RendererNonReparsePath -Root $RepositoryRoot -Path $RepositoryRoot -Context 'Repository root'

# Resolve Evidence Root & Destination Path
if ([string]::IsNullOrWhiteSpace($EvidenceRoot)) {
    if ([IO.Path]::IsPathRooted($DestinationPath)) {
        $EvidenceRoot = Split-Path -Parent ([IO.Path]::GetFullPath($DestinationPath))
    } else {
        $EvidenceRoot = $RepositoryRoot
    }
}
$EvidenceRoot = [IO.Path]::GetFullPath($EvidenceRoot).TrimEnd('\','/')
Assert-RendererNonReparsePath -Root $EvidenceRoot -Path $EvidenceRoot -Context 'Evidence root'

$fullDestination = if ([IO.Path]::IsPathRooted($DestinationPath)) {
    [IO.Path]::GetFullPath($DestinationPath)
} else {
    [IO.Path]::GetFullPath((Join-Path $EvidenceRoot $DestinationPath))
}

# Evidence root containment check
if ($fullDestination -cne $EvidenceRoot -and -not $fullDestination.StartsWith($EvidenceRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Soak measurement destination '$fullDestination' escaped the evidence root '$EvidenceRoot'."
}
Assert-RendererNonReparsePath -Root $EvidenceRoot -Path $fullDestination -Context 'Soak measurement destination'

# No-clobber protection: MUST ALWAYS FAIL CLOSED
if (Test-Path -LiteralPath $fullDestination) {
    throw "Soak measurement destination already exists; refusing to clobber: $fullDestination"
}

$relativePath = $fullDestination.Substring($EvidenceRoot.Length).TrimStart('\','/').Replace('\','/')
Assert-RendererRelativePath $relativePath 'Soak measurement relativePath'

# Verify source & git identity
$git = Get-RendererGitIdentity $RepositoryRoot

if (-not $Synthetic) {
    if ([string]::IsNullOrWhiteSpace($ExpectedSourceCommit) -or [string]::IsNullOrWhiteSpace($ExpectedSourceTree)) {
        throw 'Live soak measurement requires exact candidate source bindings: ExpectedSourceCommit and ExpectedSourceTree are mandatory.'
    }
    if ([string]::IsNullOrWhiteSpace($PackageIdentityPath) -or
        [string]::IsNullOrWhiteSpace($PackageArchivePath) -or
        [string]::IsNullOrWhiteSpace($ExtractedPackageRoot)) {
        throw 'Live soak measurement requires exact candidate package bindings: PackageIdentityPath, PackageArchivePath, and ExtractedPackageRoot are mandatory.'
    }
}

if (-not [string]::IsNullOrWhiteSpace($ExpectedSourceCommit) -and $git.CommitSha -cne $ExpectedSourceCommit) {
    throw "Source commit mismatch. Expected '$ExpectedSourceCommit', repository HEAD is '$($git.CommitSha)'."
}
if (-not [string]::IsNullOrWhiteSpace($ExpectedSourceTree) -and $git.TreeSha -cne $ExpectedSourceTree) {
    throw "Source tree mismatch. Expected '$ExpectedSourceTree', repository HEAD is '$($git.TreeSha)'."
}

# Package Identity Binding & Validation
$packageBinding = $null
$hasAnyPackageArg = (-not [string]::IsNullOrWhiteSpace($PackageIdentityPath) -or
    -not [string]::IsNullOrWhiteSpace($PackageArchivePath) -or
    -not [string]::IsNullOrWhiteSpace($ExtractedPackageRoot))

if ($hasAnyPackageArg) {
    if ([string]::IsNullOrWhiteSpace($PackageIdentityPath) -or
        [string]::IsNullOrWhiteSpace($PackageArchivePath) -or
        [string]::IsNullOrWhiteSpace($ExtractedPackageRoot)) {
        throw 'When validating package bindings, PackageIdentityPath, PackageArchivePath, and ExtractedPackageRoot must all be provided.'
    }

    $fullIdentityPath = if ([IO.Path]::IsPathRooted($PackageIdentityPath)) {
        [IO.Path]::GetFullPath($PackageIdentityPath)
    } else {
        Resolve-RendererBoundPath $EvidenceRoot $PackageIdentityPath 'Package identity receipt'
    }

    $fullArchivePath = if ([IO.Path]::IsPathRooted($PackageArchivePath)) {
        [IO.Path]::GetFullPath($PackageArchivePath)
    } else {
        Resolve-RendererBoundPath $EvidenceRoot $PackageArchivePath 'Package archive'
    }

    $fullPackageRoot = if ([IO.Path]::IsPathRooted($ExtractedPackageRoot)) {
        [IO.Path]::GetFullPath($ExtractedPackageRoot)
    } else {
        Resolve-RendererBoundPath $EvidenceRoot $ExtractedPackageRoot 'Extracted package root'
    }

    $profilePath = Join-Path $RepositoryRoot 'tools\packaging\v0.2\package-identity-profile.json'
    Assert-RendererNonReparsePath -Root $RepositoryRoot -Path $profilePath -Context 'Package profile'
    $profileValue = Read-RendererPackageProfile $profilePath
    Assert-RendererPackageProfile $profileValue

    . (Join-Path $RepositoryRoot 'tools\lib\V02RuntimePackageBinding.ps1')
    $packageBinding = Resolve-V02RuntimePackageBinding `
        -IdentityPath $fullIdentityPath `
        -ArchivePath $fullArchivePath `
        -PackageRoot $fullPackageRoot `
        -RepositoryRoot $RepositoryRoot `
        -ProfilePath $profilePath `
        -ExpectedSourceCommit $git.CommitSha `
        -ExpectedSourceTree $git.TreeSha
}

if (-not $Synthetic -and $null -eq $packageBinding) {
    throw 'Live soak measurement requires a validated package binding.'
}

# Live process verification & anti-PID-reuse checks
$appProcess = $null
$coreProcess = $null
$appStartTimeUtc = [DateTime]::MinValue
$coreStartTimeUtc = $null
$currentSessionId = [System.Diagnostics.Process]::GetCurrentProcess().SessionId

if (-not $Synthetic) {
    if ($CoreProcessId -le 0) { throw 'Live soak measurement requires a positive CoreProcessId.' }

    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Live soak measurement must execute in a non-elevated user context.'
    }

    try {
        $coreProcess = [System.Diagnostics.Process]::GetProcessById($CoreProcessId)
    } catch {
        throw "Unable to connect to target Core ($CoreProcessId) process: $($_.Exception.Message)"
    }

    if ($coreProcess.HasExited) {
        throw 'Core process has already exited before soak start.'
    }

    if ($coreProcess.SessionId -ne $currentSessionId) {
        throw "Process session ID mismatch: Core session ($($coreProcess.SessionId)), Current session ($currentSessionId)."
    }

    $coreStartTimeUtc = $coreProcess.StartTime.ToUniversalTime()

    # Exact binding between running processes and candidate package executables
    $coreExePath = $coreProcess.MainModule.FileName

    if ($coreExePath -cne $packageBinding.CorePath) {
        throw "Core process executable path '$coreExePath' does not match bound package Core path '$($packageBinding.CorePath)'."
    }

    $coreHash = (Get-FileHash -LiteralPath $coreExePath -Algorithm SHA256).Hash.ToUpperInvariant()

    if ($coreHash -cne $packageBinding.CoreSha256) {
        throw "Core process executable hash '$coreHash' does not match bound package Core hash '$($packageBinding.CoreSha256)'."
    }
    if ($ChannelNonce -cnotmatch '^[0-9a-f]{32}$') { throw 'Live soak measurement requires a lowercase 32-hex ChannelNonce/runNonce.' }
}

$telemetryPipe=$null;$telemetryReader=$null;$telemetryWriter=$null
try {
if(-not$Synthetic){
    $pipeName="herdrops-v02-issue10-perf-$ChannelNonce-0";$telemetryPipe=New-RendererTargetObservationPipe $pipeName
    $server=[Diagnostics.Process]::GetCurrentProcess();$serverPath=[IO.Path]::GetFullPath($server.MainModule.FileName);$serverSha=(Get-FileHash -LiteralPath $serverPath -Algorithm SHA256).Hash.ToUpperInvariant();$serverStart=$server.StartTime.ToUniversalTime()
    $args=@('--issue10-performance-telemetry-pipe',$pipeName,'--issue10-performance-run-nonce',$ChannelNonce,'--issue10-performance-source-commit',$ExpectedSourceCommit,'--issue10-performance-source-tree',$ExpectedSourceTree,'--issue10-performance-package-identity-path',$packageBinding.IdentityPath,'--issue10-performance-package-identity-sha256',$packageBinding.ReceiptSha256,'--issue10-performance-package-archive-path',$packageBinding.ArchivePath,'--issue10-performance-package-archive-sha256',$packageBinding.ArchiveSha256,'--issue10-performance-package-root',$packageBinding.PackageRoot,'--issue10-performance-package-profile-path',$packageBinding.ProfilePath,'--issue10-performance-server-pid',[string]$server.Id,'--issue10-performance-server-start-utc',$serverStart.ToString('O',[Globalization.CultureInfo]::InvariantCulture),'--issue10-performance-server-path',$serverPath,'--issue10-performance-server-sha256',$serverSha,'--issue10-performance-renderer-mode','SoftwareOnly')
    $psi=New-Object Diagnostics.ProcessStartInfo;$psi.FileName=$packageBinding.AppPath;$qa=@($args|ForEach-Object{ConvertTo-V02SoakNativeArgument ([string]$_)});$psi.Arguments=$qa-join' ';$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
    $appProcess=[Diagnostics.Process]::Start($psi);if($null-eq$appProcess){throw 'Packaged soak App did not start.'};$appStartTimeUtc=$appProcess.StartTime.ToUniversalTime()
    $clientPid=Wait-RendererTargetObservationPipe $telemetryPipe 60;Assert-RendererPipeClientProcessId ([int]$clientPid) ([int]$appProcess.Id) 'Soak telemetry'
    $telemetryReader=New-Object IO.StreamReader($telemetryPipe,(New-Object Text.UTF8Encoding($false,$true)),$false,65536,$true);$telemetryWriter=New-Object IO.StreamWriter($telemetryPipe,(New-Object Text.UTF8Encoding($false)),65536,$true);$telemetryWriter.AutoFlush=$true
    $helloJson=Read-RendererTargetPipeLine $telemetryReader 30;$hello=ConvertFrom-RendererTransportJson $helloJson 'Soak producer hello'
    Assert-SoakExactProperties $hello @('schemaVersion','kind','runNonce','sourceCommit','sourceTree','packageIdentitySha256','packageArchiveSha256','server','app','renderer') 'Soak producer hello'
    Assert-SoakExactProperties $hello.server @('pid','startUtc','path','sha256') 'Soak producer hello server'
    Assert-SoakExactProperties $hello.app @('pid','startUtc','path','sha256') 'Soak producer hello App';Assert-SoakExactProperties $hello.renderer @('requestedMode','nativeProcessRenderMode','nativeTier','hasAnyHwnd','preFirstHwnd','hardwareComparatorBoundary') 'Soak producer hello renderer'
    if([int]$hello.schemaVersion-ne1-or$hello.kind-cne'issue10-performance-hello'-or$hello.runNonce-cne$ChannelNonce-or$hello.sourceCommit-cne$ExpectedSourceCommit-or$hello.sourceTree-cne$ExpectedSourceTree-or$hello.packageIdentitySha256-cne$packageBinding.ReceiptSha256-or$hello.packageArchiveSha256-cne$packageBinding.ArchiveSha256-or[int]$hello.app.pid-ne$appProcess.Id-or$hello.app.sha256-cne$packageBinding.AppSha256-or$hello.renderer.requestedMode-cne'SoftwareOnly'-or$hello.renderer.nativeProcessRenderMode-cne'SoftwareOnly'-or-not[bool]$hello.renderer.preFirstHwnd){throw 'Soak producer hello binding is invalid.'}
    if([int]$hello.server.pid-ne$server.Id-or[DateTimeOffset]::Parse([string]$hello.server.startUtc).UtcDateTime-ne$serverStart-or-not[StringComparer]::OrdinalIgnoreCase.Equals([string]$hello.server.path,$serverPath)-or$hello.server.sha256-cne$serverSha){throw 'Soak producer hello server identity is invalid.'}
}

# Verify Initial Power Source
$initialPower = Get-CurrentPowerStatus -SyntheticMode:$Synthetic -SyntheticProvider:$SyntheticPowerStateProvider
if ($initialPower -cne $PowerSource) {
    throw "Initial power source mismatch. Requested '$PowerSource' soak, but host power state is '$initialPower'."
}

$approvedLimits = [ordered]@{
    workingSetMaximumBytes = 267386880 # 255 MiB
    resourceSlopeMaximumBytesPerTenMinutes = 1048576 # 1 MiB per 10 min
    cpuMaximumPercent = 1.0
    latencyP95Milliseconds = 250.0
    uiStallP95Milliseconds = 50.0
    uiStallMaximumMilliseconds = 100.0
}

$caseId = if ($PowerSource -ceq 'AC') { 'soak-ac-60-minutes' } else { 'soak-battery-60-minutes' }

$totalBins = if ($Synthetic) { $SyntheticTotalBins } else { 12 }
$binDurationMinutes = if ($Synthetic) { $SyntheticBinDurationMinutes } else { 5 }
$totalDurationMinutes = $totalBins * $binDurationMinutes
$sampleIntervalMs = 1000

$samplesPerBin = if ($Synthetic) {
    if ($SyntheticSamplesPerBin -gt 0) { $SyntheticSamplesPerBin } else { 300 }
} else {
    [int](($binDurationMinutes * 60 * 1000) / $sampleIntervalMs)
}

$soakStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$lastObservedTicks = [DateTime]::UtcNow.Ticks

$bins = @()
$observations = @()
$rawSamples = @()
$latencySamples = @()
$latencyStateSequences = @{}
$latencyCorrelationIds = @{}
$latencyBaselineStateSequence = [long]::MinValue
$latencyWatermarkStateSequence = [long]::MinValue
$latencyBaselineRecordCount = [long]::MinValue
$latencyRecordCount = [long]::MinValue

$prevAppCpuTime = $null
$prevCoreCpuTime = $null
$prevSampleTicks = $null

if (-not $Synthetic) {
    $prevAppCpuTime = $appProcess.TotalProcessorTime
    $prevCoreCpuTime = $coreProcess.TotalProcessorTime
    $prevSampleTicks = $soakStopwatch.ElapsedTicks
}

$globalSequenceNumber = 0
$lastObservedTelemetryUtc = [DateTime]::MinValue

for ($binIndex = 0; $binIndex -lt $totalBins; $binIndex++) {
    $binStartUtc = [DateTime]::UtcNow
    $binStartUtcStr = $binStartUtc.ToString('yyyy-MM-ddTHH:mm:ss.fffffff+00:00')
    $binStartWorkingSet = 0L
    $binEndWorkingSet = 0L
    $binRendererStable = $true
    $binLatencyUpdateCount = 0

    for ($sampleIdx = 0; $sampleIdx -lt $samplesPerBin; $sampleIdx++) {
        $packetSequenceNumber = $globalSequenceNumber
        $sampleTargetElapsedMs = ($binIndex * $binDurationMinutes * 60 * 1000) + (($sampleIdx + 1) * $sampleIntervalMs)

        if (-not $Synthetic) {
            $currentElapsedMs = $soakStopwatch.ElapsedMilliseconds
            $sleepMs = [int]($sampleTargetElapsedMs - $currentElapsedMs)
            if ($sleepMs -gt 0) {
                Start-Sleep -Milliseconds $sleepMs
            }
        }

        # Monotonic UTC timestamp calculation
        $nowTicks = [DateTime]::UtcNow.Ticks
        if ($nowTicks -le $lastObservedTicks) {
            $nowTicks = $lastObservedTicks + 10L
        }
        $lastObservedTicks = $nowTicks
        $sampleUtc = [DateTime]::new($nowTicks, [DateTimeKind]::Utc)
        $sampleUtcStr = $sampleUtc.ToString('yyyy-MM-ddTHH:mm:ss.fffffff+00:00')
        $elapsedMs = $soakStopwatch.Elapsed.TotalMilliseconds

        # Power verification on every single sample
        $currentPower = Get-CurrentPowerStatus -SyntheticMode:$Synthetic -SyntheticProvider:$SyntheticPowerStateProvider
        if ($currentPower -cne $PowerSource) {
            throw "Power source changed during bin $binIndex sample $($sampleIdx): expected '$PowerSource', observed '$currentPower'."
        }

        $sampleData = $null
        if ($Synthetic) {
            if ($null -eq $SyntheticProcessTelemetryProvider) {
                $sampleData = [pscustomobject][ordered]@{
                    AppWorkingSetBytes = 104857600L
                    AppPrivateBytes = 94371840L
                    AppCpuBasisPoints = 25L
                    CoreWorkingSetBytes = 41943040L
                    CorePrivateBytes = 31457280L
                    CoreCpuBasisPoints = 15L
                    LatencyMicroseconds = @(1..20 | ForEach-Object { 100000L })
                    UiStallMicroseconds = @(1..20 | ForEach-Object { 10000L })
                    RendererStable = $true
                }
            } elseif ($SyntheticProcessTelemetryProvider -is [scriptblock]) {
                try {
                    $sampleData = & $SyntheticProcessTelemetryProvider $binIndex $sampleIdx $elapsedMs
                } catch {
                    throw "Synthetic telemetry provider threw an exception during bin $binIndex sample $($sampleIdx): $($_.Exception.Message)"
                }
            } else {
                $sampleData = $SyntheticProcessTelemetryProvider
            }

            if ($null -eq $sampleData -or $sampleData -isnot [pscustomobject]) {
                throw "Synthetic telemetry provider returned null or invalid object during bin $binIndex sample $sampleIdx."
            }
        } else {
            # LIVE PROCESS VERIFICATION AND TELEMETRY
            $appIdentity = Get-V02LiveProcessIdentity `
                -Process $appProcess `
                -ExpectedProcessId $appProcess.Id `
                -ExpectedStartTimeUtc $appStartTimeUtc `
                -Role 'App' `
                -BinIndex $binIndex `
                -SampleIndex $sampleIdx
            $coreIdentity = Get-V02LiveProcessIdentity `
                -Process $coreProcess `
                -ExpectedProcessId $CoreProcessId `
                -ExpectedStartTimeUtc $coreStartTimeUtc `
                -Role 'Core' `
                -BinIndex $binIndex `
                -SampleIndex $sampleIdx

            $appProcess.Refresh()
            $coreProcess.Refresh()

            $appWs = [long]$appProcess.WorkingSet64
            $appPriv = [long]$appProcess.PrivateMemorySize64
            $coreWs = [long]$coreProcess.WorkingSet64
            $corePriv = [long]$coreProcess.PrivateMemorySize64

            # Real CPU measurement over interval
            $curAppCpu = $appProcess.TotalProcessorTime
            $curCoreCpu = $coreProcess.TotalProcessorTime
            $curSampleTicks = $soakStopwatch.ElapsedTicks

            $deltaWallSeconds = [double]($curSampleTicks - $prevSampleTicks) / [System.Diagnostics.Stopwatch]::Frequency
            if ($deltaWallSeconds -le 0.0) { $deltaWallSeconds = 0.001 }

            $appCpuDeltaMs = [Math]::Max(0.0, ($curAppCpu - $prevAppCpuTime).TotalMilliseconds)
            $coreCpuDeltaMs = [Math]::Max(0.0, ($curCoreCpu - $prevCoreCpuTime).TotalMilliseconds)

            $procCount = [Environment]::ProcessorCount
            $appCpuPercent = ($appCpuDeltaMs / ($deltaWallSeconds * 1000.0 * $procCount)) * 100.0
            $coreCpuPercent = ($coreCpuDeltaMs / ($deltaWallSeconds * 1000.0 * $procCount)) * 100.0

            $appCpuBp = [long][Math]::Round([Math]::Max(0.0, $appCpuPercent) * 100.0)
            $coreCpuBp = [long][Math]::Round([Math]::Max(0.0, $coreCpuPercent) * 100.0)

            $prevAppCpuTime = $curAppCpu
            $prevCoreCpuTime = $curCoreCpu
            $prevSampleTicks = $curSampleTicks

            # Authenticated live latency and UI stall source across trusted channel
            $packet = $null
            try {
                $request=[pscustomobject][ordered]@{schemaVersion=1;kind='issue10-soak-sample-request';runNonce=$ChannelNonce;sequenceNumber=$globalSequenceNumber;binIndex=$binIndex;sampleIndex=$sampleIdx;coreProcessId=$CoreProcessId;coreStartUtc=$coreStartTimeUtc.ToString('O')}
                Write-RendererTargetPipeLine $telemetryWriter (ConvertTo-RendererCanonicalJson $request $RepositoryRoot)
                $packetJson=Read-RendererTargetPipeLine $telemetryReader 45
                $packet=ConvertFrom-RendererTransportJson $packetJson "Soak telemetry packet $globalSequenceNumber"
            } catch {
                throw "Telemetry channel failed to read packet during bin $binIndex sample $($sampleIdx): $($_.Exception.Message)"
            }

            Assert-V02TrustedTelemetryPacket `
                -Packet $packet `
                -ExpectedNonce $ChannelNonce `
                -ExpectedSequenceNumber $globalSequenceNumber `
                -ExpectedBinIndex $binIndex `
                -ExpectedSampleIndex $sampleIdx `
                -ExpectedAppProcessId $appProcess.Id `
                -ExpectedCoreProcessId $CoreProcessId `
                -ExpectedAppStartTimeUtc $appStartTimeUtc `
                -ExpectedCoreStartTimeUtc $coreStartTimeUtc `
                -ExpectedAppExecutablePath $packageBinding.AppPath `
                -ExpectedCoreExecutablePath $packageBinding.CorePath `
                -ExpectedAppExecutableSha256 $packageBinding.AppSha256 `
                -ExpectedCoreExecutableSha256 $packageBinding.CoreSha256 `
                -PreviousTimestampRef ([ref]$lastObservedTelemetryUtc) `
                -LatencyBaselineRef ([ref]$latencyBaselineStateSequence) `
                -PreviousLatencyWatermarkRef ([ref]$latencyWatermarkStateSequence) `
                -LatencyBaselineRecordCountRef ([ref]$latencyBaselineRecordCount) `
                -PreviousLatencyRecordCountRef ([ref]$latencyRecordCount) `
                -RepositoryRoot $RepositoryRoot

            $null=Get-V02LiveProcessIdentity -Process $appProcess -ExpectedProcessId $appProcess.Id -ExpectedStartTimeUtc $appStartTimeUtc -Role 'App' -BinIndex $binIndex -SampleIndex $sampleIdx
            $null=Get-V02LiveProcessIdentity -Process $coreProcess -ExpectedProcessId $CoreProcessId -ExpectedStartTimeUtc $coreStartTimeUtc -Role 'Core' -BinIndex $binIndex -SampleIndex $sampleIdx
            $postAppPath=[IO.Path]::GetFullPath($appProcess.MainModule.FileName);$postCorePath=[IO.Path]::GetFullPath($coreProcess.MainModule.FileName)
            if(-not[StringComparer]::OrdinalIgnoreCase.Equals($postAppPath,$packageBinding.AppPath)-or-not[StringComparer]::OrdinalIgnoreCase.Equals($postCorePath,$packageBinding.CorePath)-or(Get-FileHash -LiteralPath $postAppPath -Algorithm SHA256).Hash-cne$packageBinding.AppSha256-or(Get-FileHash -LiteralPath $postCorePath -Algorithm SHA256).Hash-cne$packageBinding.CoreSha256){throw "App/Core executable identity changed after telemetry response during bin $binIndex sample $sampleIdx."}

            $sampleUtcStr = [string]$packet.observedUtc
            if ($sampleIdx -eq 0) {
                $binStartUtcStr = $sampleUtcStr
            }

            $liveLatencyUpdates = @($packet.metrics.latency.updates)
            $liveStall = @($packet.metrics.uiStallMicroseconds)
            $liveStable = [bool]$packet.metrics.rendererStable

            $sampleData = [pscustomobject][ordered]@{
                AppWorkingSetBytes = $appWs
                AppPrivateBytes = $appPriv
                AppCpuBasisPoints = $appCpuBp
                CoreWorkingSetBytes = $coreWs
                CorePrivateBytes = $corePriv
                CoreCpuBasisPoints = $coreCpuBp
                LatencyUpdates = $liveLatencyUpdates
                UiStallMicroseconds = $liveStall
                RendererStable = $liveStable
            }
        }

        if ($null -eq $sampleData.AppWorkingSetBytes -or $null -eq $sampleData.CoreWorkingSetBytes -or
            $null -eq $sampleData.AppCpuBasisPoints -or $null -eq $sampleData.CoreCpuBasisPoints -or
            $null -eq $sampleData.UiStallMicroseconds) {
            throw "Incomplete telemetry sample data during bin $binIndex sample $sampleIdx."
        }

        if ($Synthetic) {
            $syntheticLatencies = @()
            if ($sampleIdx -eq 0) { $syntheticLatencies = @($sampleData.LatencyMicroseconds) }
            $syntheticUpdates = @()
            for ($latencyIndex = 0; $latencyIndex -lt $syntheticLatencies.Count; $latencyIndex++) {
                $syntheticSequence = [long](($packetSequenceNumber * 100) + $latencyIndex)
                $syntheticApplied = $sampleUtc
                $syntheticAccepted = $syntheticApplied.AddTicks(-([long]$syntheticLatencies[$latencyIndex] * 10L))
                $syntheticCorrelation = ('00000000-0000-0000-0000-{0:x12}' -f ($syntheticSequence + 1))
                $syntheticUpdates += [pscustomobject][ordered]@{stateSequence=$syntheticSequence;eventCount=$syntheticSequence;envelopeSequence=$syntheticSequence;envelopeCorrelationId=$syntheticCorrelation;stateSha256=('{0:X64}' -f ($syntheticSequence + 1));updateKind='Delta';coreAcceptedStateUtc=$syntheticAccepted.ToString('O');ipcSentUtc=$syntheticAccepted.ToString('O');wpfAppliedUtc=$syntheticApplied.ToString('O');latencyMicroseconds=[long]$syntheticLatencies[$latencyIndex]}
            }
            $sampleData | Add-Member -NotePropertyName LatencyUpdates -NotePropertyValue $syntheticUpdates
            if ($latencyBaselineStateSequence -eq [long]::MinValue) { $latencyBaselineStateSequence = -1L }
            if ($latencyBaselineRecordCount -eq [long]::MinValue) { $latencyBaselineRecordCount=0L;$latencyRecordCount=0L }
            $latencyRecordCount += $syntheticUpdates.Count
            if ($syntheticUpdates.Count -gt 0) { $latencyWatermarkStateSequence = [long]$syntheticUpdates[-1].stateSequence }
        }

        $sampleLatencyUpdates = @($sampleData.LatencyUpdates)
        foreach ($update in $sampleLatencyUpdates) {
            $sequenceKey=[string][long]$update.stateSequence;$correlationKey=[string]$update.envelopeCorrelationId
            if($latencyStateSequences.ContainsKey($sequenceKey)-or$latencyCorrelationIds.ContainsKey($correlationKey)){throw "Duplicate soak latency identity during bin $binIndex sample $sampleIdx."}
            $latencyStateSequences[$sequenceKey]=$true;$latencyCorrelationIds[$correlationKey]=$true
            $latencySamples += [pscustomobject][ordered]@{binOrdinal=[int]$binIndex;sampleIndex=[int]$sampleIdx;packetSequenceNumber=[int]$packetSequenceNumber;stateSequence=[long]$update.stateSequence;eventCount=[long]$update.eventCount;envelopeSequence=[long]$update.envelopeSequence;envelopeCorrelationId=[string]$update.envelopeCorrelationId;stateSha256=[string]$update.stateSha256;updateKind=[string]$update.updateKind;coreAcceptedStateUtc=[string]$update.coreAcceptedStateUtc;ipcSentUtc=[string]$update.ipcSentUtc;wpfAppliedUtc=[string]$update.wpfAppliedUtc;latencyMicroseconds=[long]$update.latencyMicroseconds}
        }
        $binLatencyUpdateCount += $sampleLatencyUpdates.Count

        $combinedWs = [long]$sampleData.AppWorkingSetBytes + [long]$sampleData.CoreWorkingSetBytes
        $combinedCpuBp = [long]$sampleData.AppCpuBasisPoints + [long]$sampleData.CoreCpuBasisPoints
        $combinedCpuPercent = [double]$combinedCpuBp / 100.0

        if ($sampleIdx -eq 0) {
            $binStartWorkingSet = $combinedWs
        }
        $binEndWorkingSet = $combinedWs

        if ($null -ne $sampleData.RendererStable -and -not [bool]$sampleData.RendererStable) {
            $binRendererStable = $false
        }

        $stlP95Us = Get-RendererP95Microseconds $sampleData.UiStallMicroseconds "Bin $binIndex sample $sampleIdx UI stall"
        $stlMaxUs = [long](@($sampleData.UiStallMicroseconds | Sort-Object { [long]$_ })[-1])

        $stlP95Ms = [double]$stlP95Us / 1000.0
        $stlMaxMs = [double]$stlMaxUs / 1000.0

        # FAIL CLOSED IMMEDIATELY ON ANY THRESHOLD BREACH
        if ($combinedWs -gt $approvedLimits.workingSetMaximumBytes) {
            throw "Bin $binIndex sample $sampleIdx combined WS ($combinedWs bytes) > limit ($($approvedLimits.workingSetMaximumBytes) bytes)."
        }
        if ($combinedCpuPercent -gt $approvedLimits.cpuMaximumPercent) {
            throw "Bin $binIndex sample $sampleIdx combined CPU ($combinedCpuPercent%) > limit ($($approvedLimits.cpuMaximumPercent)%)."
        }
        if ($stlP95Ms -gt $approvedLimits.uiStallP95Milliseconds) {
            throw "Bin $binIndex sample $sampleIdx UI stall P95 ($stlP95Ms ms) > limit ($($approvedLimits.uiStallP95Milliseconds) ms)."
        }
        if ($stlMaxMs -gt $approvedLimits.uiStallMaximumMilliseconds) {
            throw "Bin $binIndex sample $sampleIdx UI stall max ($stlMaxMs ms) > limit ($($approvedLimits.uiStallMaximumMilliseconds) ms)."
        }

        $rawSamples += [pscustomobject][ordered]@{
            binOrdinal = [int]$binIndex
            sampleIndex = [int]$sampleIdx
            observedUtc = [string]$sampleUtcStr
            elapsedMilliseconds = [long][Math]::Round($elapsedMs)
            powerSource = [string]$PowerSource
            appWorkingSetBytes = [long]$sampleData.AppWorkingSetBytes
            appPrivateBytes = [long]$sampleData.AppPrivateBytes
            coreWorkingSetBytes = [long]$sampleData.CoreWorkingSetBytes
            corePrivateBytes = [long]$sampleData.CorePrivateBytes
            combinedWorkingSetBytes = [long]$combinedWs
            combinedCpuBasisPoints = [long]$combinedCpuBp
            latencyUpdateCount = [int]$sampleLatencyUpdates.Count
            uiStallP95Microseconds = [long]$stlP95Us
            uiStallMaximumMicroseconds = [long]$stlMaxUs
            rendererStable = [bool]$binRendererStable
        }
        $globalSequenceNumber++
    }

    # Evaluate working set slope across the bin (scaled to bytes per 10 minutes)
    $binSlope = [Math]::Abs([double]$binEndWorkingSet - [double]$binStartWorkingSet) * (10.0 / [double]$binDurationMinutes)
    if ($binSlope -gt [double]$approvedLimits.resourceSlopeMaximumBytesPerTenMinutes) {
        throw "Bin $binIndex WS slope ($binSlope B/10m) > limit ($($approvedLimits.resourceSlopeMaximumBytesPerTenMinutes) B/10m)."
    }
    if (-not $binRendererStable) {
        throw "Bin $binIndex renderer stability failure."
    }
    if ($binLatencyUpdateCount -lt 1) { throw "Bin $binIndex did not observe a fresh production Widget latency update." }

    $bins += [pscustomobject][ordered]@{
        powerSource = [string]$PowerSource
        ordinal = [int]$binIndex
        durationMinutes = [int]$binDurationMinutes
        observedUtc = [string]$binStartUtcStr
        workingSetStartBytes = [long]$binStartWorkingSet
        workingSetEndBytes = [long]$binEndWorkingSet
        rendererStable = [bool]$binRendererStable
    }

    $observations += [pscustomobject][ordered]@{
        ordinal = [int]$binIndex
        observedUtc = [string]$binStartUtcStr
        outcome = 'PASS'
        notes = "Bin $binIndex ($PowerSource, $($binDurationMinutes)m): WS start $binStartWorkingSet B, end $binEndWorkingSet B, slope $([Math]::Round($binSlope)) B/10m"
    }
}

$soakStopwatch.Stop()

# Bind the held raw timeline to the governed completion boundary. The last
# sampling instant precedes completion by up to one interval, so preserve the
# actual completion stopwatch value on the final held row.
if ($rawSamples.Count -gt 0) {
    $rawSamples[-1].elapsedMilliseconds = [long][Math]::Round($soakStopwatch.Elapsed.TotalMilliseconds)
}

if ($latencySamples.Count -lt 20) { throw "Soak latency measurement requires at least 20 unique fresh production Widget updates; found $($latencySamples.Count)." }
$orderedLatency = @($latencySamples | ForEach-Object { [long]$_.latencyMicroseconds } | Sort-Object)
$latencyP95Microseconds = [long]$orderedLatency[[Math]::Ceiling($orderedLatency.Count * 0.95) - 1]
if ($latencyP95Microseconds -gt 250000L) { throw "Soak latency P95 ($latencyP95Microseconds microseconds) > limit (250000 microseconds)." }
$latencyMeasurement = [pscustomobject][ordered]@{measurement='CoreAcceptedStateUtcToWpfAppliedUtc';baselineStateSequence=[long]$latencyBaselineStateSequence;finalStateSequence=[long]$latencyWatermarkStateSequence;baselineRecordCount=[long]$latencyBaselineRecordCount;finalRecordCount=[long]$latencyRecordCount;minimumUniqueSampleCount=20;uniqueSampleCount=[int]$latencySamples.Count;requiredCoveredBinCount=[int]$totalBins;coveredBinCount=[int]$totalBins;p95Microseconds=$latencyP95Microseconds;targetMaximumMicroseconds=250000L;status='PASS';samples=$latencySamples}

# In live mode: Enforce that total Stopwatch elapsed time is >= 60 minutes (3600 seconds)
if (-not $Synthetic) {
    if ($soakStopwatch.Elapsed.TotalMinutes -lt [double]$totalDurationMinutes) {
        throw "Live soak measurement completed in $($soakStopwatch.Elapsed.TotalMinutes) minutes; required minimum duration is $totalDurationMinutes minutes."
    }
}

# Construct canonical matrix observation receipt document
$evidenceClass = if ($Synthetic) { 'SyntheticVerifierSelftest' } else { 'PackagedCompatibilitySoak' }
$receiptDocument = [pscustomobject][ordered]@{
    schemaVersion = 2
    caseId = [string]$caseId
    evidenceClassification = [string]$evidenceClass
    powerSource = [string]$PowerSource
    totalBins = [int]$totalBins
    binDurationMinutes = [int]$binDurationMinutes
    aggregateStatus = 'PASS'
    governance = [pscustomobject][ordered]@{
        profileId = $script:RendererProfileId
        profileSha256 = $script:RendererProfileSha256
        packageProfileId = $script:RendererPackageProfileId
        rendererPolicy = 'software-only-process-wide'
        decisionId = $script:RendererDecisionId
        approvalReference = $script:RendererV3ScopeApprovalReference
        originalApprovedUtc = $script:RendererDecisionApprovedUtc
        correctedUtc = $script:RendererDecisionCorrectedUtc
        decisionPayloadSha256 = $script:RendererDecisionPayloadSha256
        supersedesDecisionId = $script:RendererSupersedesDecisionId
        supersedesPayloadSha256 = $script:RendererSupersedesPayloadSha256
    }
    source = [pscustomobject][ordered]@{
        commitSha = [string]$git.CommitSha
        treeSha = [string]$git.TreeSha
    }
    session = [pscustomobject][ordered]@{
        kind = 'LocalConsole'
        sessionId = if (-not $Synthetic) { [int]$currentSessionId } else { 1 }
        transport = 'Physical'
        powerSource = [string]$PowerSource
        thermalState = 'Nominal'
        elevated = $false
        userScope = 'SingleUser'
    }
    soakBins = $bins
    observations = $observations
    rawSamples = $rawSamples
    latencyMeasurement = $latencyMeasurement
    evidenceBoundary = [pscustomobject][ordered]@{
        evidenceClass = [string]$evidenceClass
        actualHerdrRuntime = 'NOT_OBSERVED'
        humanReview = 'NOT_OBSERVED'
        release = 'NOT_OBSERVED'
        creditGranted = $false
    }
}

if ($null -ne $packageBinding) {
    $receiptDocument | Add-Member -MemberType NoteProperty -Name 'package' -Value ([pscustomobject][ordered]@{
        receiptSha256 = [string]$packageBinding.ReceiptSha256
        archiveSha256 = [string]$packageBinding.ArchiveSha256
        appSha256 = [string]$packageBinding.AppSha256
        coreSha256 = [string]$packageBinding.CoreSha256
})
    if(-not$Synthetic){$receiptDocument | Add-Member -MemberType NoteProperty -Name 'runNonce' -Value ([string]$ChannelNonce)}
}

# Generate RFC 8785 canonical JCS JSON and SHA-256
$canonicalJson = ConvertTo-RendererCanonicalJson $receiptDocument $RepositoryRoot
$canonicalSha = Get-HumanDesignReviewSha256ForText $canonicalJson

# Destination directory resolution & no-clobber
$destinationDir = Split-Path -Parent $fullDestination
if (-not (Test-Path -LiteralPath $destinationDir -PathType Container)) {
    [IO.Directory]::CreateDirectory($destinationDir) | Out-Null
}
Assert-RendererNonReparsePath -Root $EvidenceRoot -Path $destinationDir -Context 'Soak measurement destination directory'

# No-clobber check immediately before staging
if (Test-Path -LiteralPath $fullDestination) {
    throw "Soak measurement destination already exists; refusing to clobber: $fullDestination"
}

# Staging sibling file in the same directory
$destinationFileName = [IO.Path]::GetFileName($fullDestination)
$stagingFileName = '.' + $destinationFileName + '.staging-' + [Guid]::NewGuid().ToString('N') + '.tmp'
$stagingPath = Join-Path $destinationDir $stagingFileName
Assert-RendererNonReparsePath -Root $EvidenceRoot -Path $stagingPath -Context 'Soak measurement staging file'

$committed = $false
$destinationMoved = $false
$primaryError = $null

try {
    if ($TestFaultInjectionStage -eq 'BeforeWrite') {
        throw 'Injected soak publication crash before staging write.'
    }

    $fileBytes = (New-Object Text.UTF8Encoding($false, $true)).GetBytes($canonicalJson + "`n")
    $stream = [IO.File]::Open($stagingPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        if ($TestFaultInjectionStage -eq 'MidWrite') {
            $partialBytes = [Math]::Min(16, $fileBytes.Length)
            $stream.Write($fileBytes, 0, $partialBytes)
            $stream.Flush($true)
            throw 'Injected soak publication crash during staging write.'
        }
        $stream.Write($fileBytes, 0, $fileBytes.Length)
        $stream.Flush($true)
    } finally {
        $stream.Dispose()
    }

    if (-not (Test-Path -LiteralPath $stagingPath -PathType Leaf)) {
        throw "Soak measurement staging file was not created: $stagingPath"
    }

    $stagingItem = Get-Item -LiteralPath $stagingPath -Force
    if ($stagingItem.Length -ne $fileBytes.Length) {
        throw "Soak measurement staging file size ($($stagingItem.Length) bytes) does not match expected ($($fileBytes.Length) bytes)."
    }

    if ($TestFaultInjectionStage -eq 'BeforeCommit') {
        throw 'Injected soak publication crash before atomic commit.'
    }

    # Fail closed if destination was created concurrently
    if (Test-Path -LiteralPath $fullDestination) {
        throw "Soak measurement destination already exists; refusing to clobber: $fullDestination"
    }

    [IO.File]::Move($stagingPath, $fullDestination)
    $destinationMoved = $true

    if ($TestFaultInjectionStage -eq 'AfterCommit') {
        throw 'Injected soak publication crash after atomic commit.'
    }

    $committed = $true
} catch {
    $primaryError = $_
} finally {
    # Rollback: Clean up destination if not committed and moved
    if (-not $committed -and $destinationMoved -and (Test-Path -LiteralPath $fullDestination)) {
        try { [IO.File]::Delete($fullDestination) } catch { }
    }
    # Rollback: Clean up staging file if not committed
    if (-not $committed -and (Test-Path -LiteralPath $stagingPath)) {
        try { [IO.File]::Delete($stagingPath) } catch { }
    }
}

if ($null -ne $primaryError) {
    throw $primaryError
}

# Stable identity verification of published destination
$stableIdentity = Get-RendererStableFileIdentity $EvidenceRoot $fullDestination 'Soak evidence receipt' -IncludeBytes
if ($stableIdentity.Sha256 -cne (Get-FileHash -LiteralPath $fullDestination -Algorithm SHA256).Hash) {
    throw 'Soak evidence receipt file hash changed during stable verification.'
}

[pscustomobject][ordered]@{
    CaseId = $caseId
    PowerSource = $PowerSource
    EvidenceClassification = $evidenceClass
    ReportPath = $fullDestination
    RelativePath = $relativePath
    Bytes = [long]$stableIdentity.Bytes
    FileSha256 = [string]$stableIdentity.Sha256
    CanonicalSha256 = [string]$canonicalSha
    AggregateStatus = 'PASS'
    TotalBins = [int]$totalBins
    Bins = $bins
    Observations = $observations
    Binding = [pscustomobject][ordered]@{
        relativePath = $relativePath
        bytes = [long]$stableIdentity.Bytes
        fileSha256 = [string]$stableIdentity.Sha256
        canonicalSha256 = [string]$canonicalSha
    }
    ReceiptDocument = $receiptDocument
}
} finally {
    Close-RendererTargetPipeSession -Writer $telemetryWriter -Reader $telemetryReader -Pipe $telemetryPipe -AppProcess $(if(-not$Synthetic){$appProcess}else{$null}) -AppStartTimeUtc $(if(-not$Synthetic-and$null-ne$appProcess){$appStartTimeUtc}else{[DateTime]::MinValue}) | Out-Null
}
