#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$DestinationPath,

    [string]$EvidenceRoot,

    [string]$RepositoryRoot,

    [string]$PackageIdentityPath,

    [string]$PackageArchivePath,

    [string]$ExtractedPackageRoot,

    [string]$ExpectedSourceCommit,

    [string]$ExpectedSourceTree,

    [int]$CoreProcessId = 0,

    [string]$RunNonce,

    [string]$BindingDestinationPath,

    [switch]$Synthetic,

    [scriptblock]$SyntheticTelemetryProvider,

    [string]$TestFaultInjectionStage
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'RendererCompatibility.Common.ps1')
. (Join-Path $PSScriptRoot 'lib\V02PerformanceTransaction.ps1')
$packageBindingLib = Join-Path $PSScriptRoot '..\lib\V02RuntimePackageBinding.ps1'
if (Test-Path -LiteralPath $packageBindingLib) {
    . $packageBindingLib
}

function Assert-RawExactProperties {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string[]]$Names,
        [Parameter(Mandatory = $true)][string]$Context
    )
    if ($null -eq $Value -or $Value -isnot [psobject]) { throw "$Context is missing or not a JSON object." }
    $actual = @($Value.PSObject.Properties | ForEach-Object { $_.Name })
    if ($actual.Count -ne $Names.Count) { throw "$Context must contain exactly: $($Names -join ', '); found: $($actual -join ', ')." }
    foreach ($name in $Names) {
        $matches = @($Value.PSObject.Properties | Where-Object { [StringComparer]::Ordinal.Equals([string]$_.Name, $name) })
        if ($matches.Count -ne 1) { throw "$Context must contain exactly one case-sensitive '$name' property." }
    }
}

function Get-ProcessSafeCreationTime {
    param([Parameter(Mandatory = $true)]$Process)
    try {
        return $Process.StartTime.ToUniversalTime()
    } catch {
        throw "Unable to query start time for process ID $($Process.Id): $($_.Exception.Message)"
    }
}

function Get-RunningProcessMainModulePath {
    param([Parameter(Mandatory = $true)]$Process)
    try {
        return [IO.Path]::GetFullPath($Process.MainModule.FileName)
    } catch {
        throw "Unable to query executable path for process ID $($Process.Id): $($_.Exception.Message)"
    }
}

function ConvertTo-V02NativeArgument {
    param([Parameter(Mandatory=$true)][string]$Value)
    if ($Value -notmatch '[\s"]') { return $Value }
    $builder = New-Object Text.StringBuilder
    [void]$builder.Append('"'); $slashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') { $slashes++; continue }
        if ($character -eq '"') { [void]$builder.Append(('\' * ($slashes * 2 + 1))); [void]$builder.Append('"'); $slashes=0; continue }
        if ($slashes -gt 0) { [void]$builder.Append(('\' * $slashes)); $slashes=0 }
        [void]$builder.Append($character)
    }
    if ($slashes -gt 0) { [void]$builder.Append(('\' * ($slashes * 2))) }
    [void]$builder.Append('"'); $builder.ToString()
}

function Invoke-V02ProductionPerformanceSample {
    param([string]$Order,[bool]$Warmup,[int]$Repetition,[string]$Mode,[int]$Sequence,$Package,$CoreProcess,[DateTime]$CoreStartUtc)
    $rendererMode = if ($Mode -ceq 'a') { 'Hardware' } else { 'SoftwareOnly' }
    $pipeName = "herdrops-v02-issue10-perf-$RunNonce-$Sequence"
    $pipe = New-RendererTargetObservationPipe $pipeName
    $reader=$null;$writer=$null;$app=$null;$appStart=[DateTime]::MinValue
    try {
        $server = [Diagnostics.Process]::GetCurrentProcess()
        $serverPath = [IO.Path]::GetFullPath($server.MainModule.FileName)
        $serverSha = (Get-FileHash -LiteralPath $serverPath -Algorithm SHA256).Hash.ToUpperInvariant()
        $serverStart = $server.StartTime.ToUniversalTime()
        $arguments = @(
            '--issue10-performance-telemetry-pipe',$pipeName,
            '--issue10-performance-run-nonce',$RunNonce,
            '--issue10-performance-source-commit',$ExpectedSourceCommit,
            '--issue10-performance-source-tree',$ExpectedSourceTree,
            '--issue10-performance-package-identity-path',$Package.IdentityPath,
            '--issue10-performance-package-identity-sha256',$Package.ReceiptSha256,
            '--issue10-performance-package-archive-path',$Package.ArchivePath,
            '--issue10-performance-package-archive-sha256',$Package.ArchiveSha256,
            '--issue10-performance-package-root',$Package.PackageRoot,
            '--issue10-performance-package-profile-path',$Package.ProfilePath,
            '--issue10-performance-server-pid',[string]$server.Id,
            '--issue10-performance-server-start-utc',$serverStart.ToString('O',[Globalization.CultureInfo]::InvariantCulture),
            '--issue10-performance-server-path',$serverPath,
            '--issue10-performance-server-sha256',$serverSha,
            '--issue10-performance-renderer-mode',$rendererMode)
        $startInfo=New-Object Diagnostics.ProcessStartInfo
        $startInfo.FileName=$Package.AppPath
        $quotedArguments=@($arguments|ForEach-Object{ConvertTo-V02NativeArgument ([string]$_)})
        $startInfo.Arguments=($quotedArguments -join ' ')
        $startInfo.UseShellExecute=$false;$startInfo.CreateNoWindow=$true
        $app=[Diagnostics.Process]::Start($startInfo)
        if($null-eq$app){throw 'Packaged performance App did not start.'}
        $appStart=$app.StartTime.ToUniversalTime()
        $clientPid=Wait-RendererTargetObservationPipe $pipe 60
        Assert-RendererPipeClientProcessId ([int]$clientPid) ([int]$app.Id) 'Performance telemetry'
        $reader=New-Object IO.StreamReader($pipe,(New-Object Text.UTF8Encoding($false,$true)),$false,65536,$true)
        $writer=New-Object IO.StreamWriter($pipe,(New-Object Text.UTF8Encoding($false)),65536,$true);$writer.AutoFlush=$true
        $helloJson=Read-RendererTargetPipeLine $reader 30
        $hello=ConvertFrom-RendererTransportJson $helloJson 'Performance producer hello'
        Assert-RawExactProperties $hello @('schemaVersion','kind','runNonce','sourceCommit','sourceTree','packageIdentitySha256','packageArchiveSha256','server','app','renderer') 'Performance producer hello'
        Assert-RawExactProperties $hello.server @('pid','startUtc','path','sha256') 'Performance producer hello server'
        Assert-RawExactProperties $hello.app @('pid','startUtc','path','sha256') 'Performance producer hello App'
        Assert-RawExactProperties $hello.renderer @('requestedMode','nativeProcessRenderMode','nativeTier','hasAnyHwnd','preFirstHwnd','hardwareComparatorBoundary') 'Performance producer hello renderer'
        if([int]$hello.schemaVersion-ne1-or$hello.kind-cne'issue10-performance-hello'-or$hello.runNonce-cne$RunNonce-or$hello.sourceCommit-cne$ExpectedSourceCommit-or$hello.sourceTree-cne$ExpectedSourceTree-or$hello.packageIdentitySha256-cne$Package.ReceiptSha256-or$hello.packageArchiveSha256-cne$Package.ArchiveSha256){throw 'Performance producer hello top-level binding is invalid.'}
        if([int]$hello.server.pid-ne$server.Id-or[DateTimeOffset]::Parse([string]$hello.server.startUtc).UtcDateTime-ne$serverStart-or-not[StringComparer]::OrdinalIgnoreCase.Equals([string]$hello.server.path,$serverPath)-or$hello.server.sha256-cne$serverSha){throw 'Performance producer hello server process binding is invalid.'}
        if([int]$hello.app.pid-ne$app.Id-or[DateTimeOffset]::Parse([string]$hello.app.startUtc).UtcDateTime-ne$appStart-or-not[StringComparer]::OrdinalIgnoreCase.Equals([string]$hello.app.path,$Package.AppPath)-or$hello.app.sha256-cne$Package.AppSha256){throw 'Performance producer hello App process/package binding is invalid.'}
        $expectedNative=if($Mode-ceq'a'){'Default'}else{'SoftwareOnly'}
        if($hello.renderer.requestedMode-cne$rendererMode-or$hello.renderer.nativeProcessRenderMode-cne$expectedNative-or(-not[bool]$hello.renderer.preFirstHwnd)-or[bool]$hello.renderer.hasAnyHwnd-or($Mode-ceq'a'-and[int]$hello.renderer.nativeTier-le0)){throw 'Performance producer native pre-HWND renderer proof is invalid.'}
        if([string]$hello.renderer.hardwareComparatorBoundary-cne'PackagedCompatibilityPerformance-NativeTierComparator-NoPerFrameGpuOrRuntimeCredit'){throw 'Performance producer hardware boundary is invalid.'}
        $request=[pscustomobject][ordered]@{schemaVersion=1;kind='issue10-performance-sample-request';runNonce=$RunNonce;sequenceNumber=$Sequence;order=$Order;isWarmup=$Warmup;repetitionOrdinal=$Repetition;semanticMode=$Mode;coreProcessId=[int]$CoreProcess.Id;coreStartUtc=$CoreStartUtc.ToString('O')}
        Write-RendererTargetPipeLine $writer (ConvertTo-RendererCanonicalJson $request $RepositoryRoot)
        $sampleJson=Read-RendererTargetPipeLine $reader 330
        $sample=ConvertFrom-RendererTransportJson $sampleJson "Performance producer sample $Sequence"
        Assert-RawExactProperties $sample @('schemaVersion','kind','runNonce','sequenceNumber','observedUtc','app','core','renderer','cpuBasisPoints','workingSetMaximumBytes','latencyMicroseconds','uiStallMicroseconds','boundary') 'Performance producer sample'
        Assert-RawExactProperties $sample.app @('pid','startUtc','path','sha256') 'Performance producer sample App'
        Assert-RawExactProperties $sample.core @('pid','startUtc','path','sha256') 'Performance producer sample Core'
        Assert-RawExactProperties $sample.renderer @('requestedMode','nativeProcessRenderMode','nativeTier','hasAnyHwnd','preFirstHwnd') 'Performance producer sample renderer'
        if([int]$sample.schemaVersion-ne1-or$sample.kind-cne'issue10-performance-sample'-or$sample.runNonce-cne$RunNonce-or[int]$sample.sequenceNumber-ne$Sequence-or$sample.boundary-cne'PackagedCompatibilityPerformance-NativeTierComparator-NoPerFrameGpuOrRuntimeCredit'){throw 'Performance producer sample binding is invalid.'}
        if([int]$sample.app.pid-ne$app.Id-or[DateTimeOffset]::Parse([string]$sample.app.startUtc).UtcDateTime-ne$appStart-or-not[StringComparer]::OrdinalIgnoreCase.Equals([string]$sample.app.path,$Package.AppPath)-or$sample.app.sha256-cne$Package.AppSha256){throw 'Performance producer sample App identity changed.'}
        if([int]$sample.core.pid-ne$CoreProcess.Id-or[DateTimeOffset]::Parse([string]$sample.core.startUtc).UtcDateTime-ne$CoreStartUtc-or-not[StringComparer]::OrdinalIgnoreCase.Equals([string]$sample.core.path,$Package.CorePath)-or$sample.core.sha256-cne$Package.CoreSha256){throw 'Performance producer sample Core identity changed.'}
        if($sample.renderer.requestedMode-cne$rendererMode-or$sample.renderer.nativeProcessRenderMode-cne$expectedNative-or-not[bool]$sample.renderer.hasAnyHwnd-or[bool]$sample.renderer.preFirstHwnd-or($Mode-ceq'a'-and[int]$sample.renderer.nativeTier-le0)){throw 'Performance producer sample native renderer proof is invalid.'}
        $CoreProcess.Refresh();if($CoreProcess.HasExited-or(Get-ProcessSafeCreationTime $CoreProcess)-ne$CoreStartUtc){throw 'Core process changed during the performance sample.'}
        $latencies=@($sample.latencyMicroseconds);$stalls=@($sample.uiStallMicroseconds)
        $script:V02ProductionPerformanceBindings += [pscustomobject][ordered]@{
            sequenceNumber=[int]$Sequence;order=$Order;isWarmup=[bool]$Warmup;repetitionOrdinal=[int]$Repetition;semanticMode=$Mode
            requestedMode=$rendererMode;appProcessId=[int]$app.Id;appStartUtc=$appStart.ToString('O');appPath=$Package.AppPath;appSha256=$Package.AppSha256
            coreProcessId=[int]$CoreProcess.Id;coreStartUtc=$CoreStartUtc.ToString('O');corePath=$Package.CorePath;coreSha256=$Package.CoreSha256
            serverProcessId=[int]$server.Id;serverStartUtc=$serverStart.ToString('O');serverPath=$serverPath;serverSha256=$serverSha
            nativeProcessRenderMode=[string]$sample.renderer.nativeProcessRenderMode;nativeTier=[int]$sample.renderer.nativeTier
            preFirstHwndProof=[bool]$hello.renderer.preFirstHwnd;observedUtc=[string]$sample.observedUtc
            boundary='PackagedCompatibilityPerformance-NativeTierComparator-NoPerFrameGpuOrRuntimeCredit'
        }
        [pscustomobject][ordered]@{Authenticated=$true;Source='PackagedAppCurrentUserPipe';AppProcessId=[int]$app.Id;CoreProcessId=[int]$CoreProcess.Id;AppStartTimeUtc=$appStart;CoreStartTimeUtc=$CoreStartUtc;ObservedUtc=[string]$sample.observedUtc;RendererMode=$rendererMode;CpuBasisPoints=[long]$sample.cpuBasisPoints;WorkingSetMaximumBytes=[long]$sample.workingSetMaximumBytes;LatencyMicroseconds=$latencies;UiStallMicroseconds=$stalls}
    } finally {
        Close-RendererTargetPipeSession -Writer $writer -Reader $reader -Pipe $pipe -AppProcess $app -AppStartTimeUtc $(if($null-ne$app){$appStart}else{[DateTime]::MinValue}) | Out-Null
    }
}

# Resolve repository and evidence root
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
}
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)

if ([string]::IsNullOrWhiteSpace($EvidenceRoot)) {
    if ([IO.Path]::IsPathRooted($DestinationPath)) {
        $EvidenceRoot = Split-Path -Parent ([IO.Path]::GetFullPath($DestinationPath))
    } else {
        $EvidenceRoot = $RepositoryRoot
    }
}
$EvidenceRoot = [IO.Path]::GetFullPath($EvidenceRoot).TrimEnd('\','/')

$fullDestinationPath = if ([IO.Path]::IsPathRooted($DestinationPath)) {
    [IO.Path]::GetFullPath($DestinationPath)
} else {
    [IO.Path]::GetFullPath((Join-Path $EvidenceRoot $DestinationPath))
}

# Confinement and reparse point validation
Assert-RendererNonReparsePath -Root $EvidenceRoot -Path $fullDestinationPath -Context 'Raw performance observations destination path'
if ($fullDestinationPath -cne $EvidenceRoot -and -not $fullDestinationPath.StartsWith($EvidenceRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Raw performance observations destination path '$fullDestinationPath' escaped the evidence root '$EvidenceRoot'."
}

# No-clobber protection
if (Test-Path -LiteralPath $fullDestinationPath) {
    throw "Raw performance observations destination file already exists; refusing to clobber '$fullDestinationPath'."
}

$destinationParent = Split-Path -Parent $fullDestinationPath
if ($Synthetic -and -not (Test-Path -LiteralPath $destinationParent -PathType Container)) {
    New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
}

$destinationRelative = $fullDestinationPath.Substring($EvidenceRoot.Length).TrimStart('\','/').Replace('\','/')
Assert-RendererRelativePath $destinationRelative 'Raw performance observations destination relativePath'

$fullBindingDestinationPath = $null
$bindingRelative = $null
if (-not $Synthetic -and -not [string]::IsNullOrWhiteSpace($BindingDestinationPath)) {
    $fullBindingDestinationPath = if ([IO.Path]::IsPathRooted($BindingDestinationPath)) { [IO.Path]::GetFullPath($BindingDestinationPath) } else { [IO.Path]::GetFullPath((Join-Path $EvidenceRoot $BindingDestinationPath)) }
    Assert-RendererNonReparsePath -Root $EvidenceRoot -Path $fullBindingDestinationPath -Context 'Performance telemetry binding destination path'
    if ($fullBindingDestinationPath -cne $EvidenceRoot -and -not $fullBindingDestinationPath.StartsWith($EvidenceRoot + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw 'Performance telemetry binding destination escaped the evidence root.' }
    if (Test-Path -LiteralPath $fullBindingDestinationPath) { throw 'Performance telemetry binding destination already exists; refusing to clobber.' }
    if ((Split-Path -Parent $fullBindingDestinationPath) -cne $destinationParent) { throw 'Raw performance and telemetry binding outputs must share one destination directory.' }
    $bindingRelative=$fullBindingDestinationPath.Substring($EvidenceRoot.Length).TrimStart('\','/').Replace('\','/')
    Assert-RendererRelativePath $bindingRelative 'Performance telemetry binding destination relativePath'
}

$canonicalOrders = @()
$previousTimestamp = [DateTime]::MinValue
$script:V02ProductionPerformanceBindings = @()

# -----------------------------------------------------------------------------
# LIVE MODE EXECUTION
# -----------------------------------------------------------------------------
if (-not $Synthetic) {
    # Mandatory candidate bindings in live mode
    if ([string]::IsNullOrWhiteSpace($ExpectedSourceCommit) -or [string]::IsNullOrWhiteSpace($ExpectedSourceTree)) {
        throw 'Live performance measurement requires exact candidate source bindings (-ExpectedSourceCommit and -ExpectedSourceTree).'
    }
    if ([string]::IsNullOrWhiteSpace($PackageIdentityPath) -or [string]::IsNullOrWhiteSpace($PackageArchivePath) -or [string]::IsNullOrWhiteSpace($ExtractedPackageRoot)) {
        throw 'Live performance measurement requires exact candidate package bindings (-PackageIdentityPath, -PackageArchivePath, and -ExtractedPackageRoot).'
    }

    $repoGitIdentity = Get-RendererGitIdentity $RepositoryRoot
    if ($repoGitIdentity.CommitSha -cne $ExpectedSourceCommit.ToLowerInvariant()) {
        throw "Source commit mismatch: repository HEAD is '$($repoGitIdentity.CommitSha)'; expected '$ExpectedSourceCommit'."
    }
    if ($repoGitIdentity.TreeSha -cne $ExpectedSourceTree.ToLowerInvariant()) {
        throw "Source tree mismatch: repository HEAD tree is '$($repoGitIdentity.TreeSha)'; expected '$ExpectedSourceTree'."
    }

    $profileCandidatePath = Join-Path $RepositoryRoot 'tools\packaging\v0.2\package-identity-profile.json'
    $packageBinding = Resolve-V02RuntimePackageBinding `
        -IdentityPath $PackageIdentityPath `
        -ArchivePath $PackageArchivePath `
        -PackageRoot $ExtractedPackageRoot `
        -RepositoryRoot $RepositoryRoot `
        -ProfilePath $profileCandidatePath `
        -ExpectedSourceCommit $ExpectedSourceCommit `
        -ExpectedSourceTree $ExpectedSourceTree


    if ($CoreProcessId -le 0) { throw 'Live performance measurement requires a positive CoreProcessId.' }
    if ($RunNonce -cnotmatch '^[0-9a-f]{32}$') { throw 'Live performance measurement requires a lowercase 32-hex RunNonce.' }

    if ([string]::IsNullOrWhiteSpace($BindingDestinationPath)) {
        throw 'Live performance measurement requires a governed binding output (-BindingDestinationPath).'
    }
    $coreProcess = $null
    try {
        $coreProcess = [System.Diagnostics.Process]::GetProcessById($CoreProcessId)
    } catch {
        throw "Unable to connect to target Core process (PID $CoreProcessId): $($_.Exception.Message)"
    }

    if ($null -eq $coreProcess -or $coreProcess.HasExited) {
        throw "Target Core process ($CoreProcessId) has already exited."
    }
    $performanceSessionId = [int]$coreProcess.SessionId

    $coreStartTimeUtc = Get-ProcessSafeCreationTime $coreProcess

    $currentProcess = [System.Diagnostics.Process]::GetCurrentProcess()
    $currentSessionId = $currentProcess.SessionId
    if ($coreProcess.SessionId -ne $currentSessionId) {
        throw "Process session ID mismatch: current session is $currentSessionId; Core session is $($coreProcess.SessionId)."
    }

    $coreExePath = Get-RunningProcessMainModulePath $coreProcess
    if ($coreExePath -cne $packageBinding.CorePath) {
        throw "Running Core executable path '$coreExePath' does not match validated package path '$($packageBinding.CorePath)'."
    }

    $liveCoreHash = ((Get-FileHash -LiteralPath $coreExePath -Algorithm SHA256).Hash).ToUpperInvariant()
    if ($liveCoreHash -cne $packageBinding.CoreSha256) {
        throw "Running Core executable SHA-256 hash '$liveCoreHash' does not match validated package hash '$($packageBinding.CoreSha256)'."
    }
    if (Test-Path -LiteralPath $destinationParent) { throw "Live raw performance transaction directory already exists; refusing to clobber '$destinationParent'." }

    # Governed order sequence: AB then BA. Each acquisition launches the exact
    # packaged App in one explicit pre-HWND comparator mode; normal production
    # launch remains SoftwareOnly.
    $productionSequence = 0
    $governedOrders = @('AB', 'BA')
    for ($oi = 0; $oi -lt 2; $oi++) {
        $orderName = $governedOrders[$oi]

        # 1 Warmup repetition
        $coreProcess.Refresh()
        if ($coreProcess.HasExited) { throw "Core process ($CoreProcessId) terminated unexpectedly during Order $orderName warmup." }
        if ((Get-ProcessSafeCreationTime $coreProcess) -ne $coreStartTimeUtc) { throw "Core process PID ($CoreProcessId) was recycled during Order $orderName warmup." }

        $warmupSampleA = $null
        $warmupSampleB = $null
        $warmupUtc = $null

        # Execute the governed order. The result remains stored by semantic
        # mode (a/b), never by execution position.
        $executionModes = if ($orderName -ceq 'AB') { @('a', 'b') } else { @('b', 'a') }
        foreach ($modeKey in $executionModes) {
            $expectedRenderer = if ($modeKey -eq 'a') { 'Hardware' } else { 'SoftwareOnly' }
            $liveResult = @(Invoke-V02ProductionPerformanceSample $orderName $true 0 $modeKey $productionSequence $packageBinding $coreProcess $coreStartTimeUtc);$productionSequence++
            if ($liveResult.Count -ne 1) { throw "Live telemetry provider must return exactly one sample for Order $orderName warmup mode $modeKey." }
            $sample = $liveResult[0]

            Assert-RawExactProperties $sample @(
                'Authenticated', 'Source', 'AppProcessId', 'CoreProcessId',
                'AppStartTimeUtc', 'CoreStartTimeUtc', 'ObservedUtc', 'RendererMode',
                'CpuBasisPoints', 'WorkingSetMaximumBytes', 'LatencyMicroseconds', 'UiStallMicroseconds'
            ) "Order $orderName warmup mode $modeKey sample"

            if ($sample.Authenticated -isnot [bool] -or -not $sample.Authenticated) { throw "Order $orderName warmup mode $modeKey sample is not authenticated." }
            if ([string]::IsNullOrWhiteSpace([string]$sample.Source)) { throw "Order $orderName warmup mode $modeKey sample missing source." }
            if ($sample.CoreProcessId -isnot [int] -or [int]$sample.CoreProcessId -ne $CoreProcessId) { throw "Order $orderName warmup mode $modeKey Core PID mismatch." }

            $sAppStart = if ($sample.AppStartTimeUtc -is [DateTime]) { $sample.AppStartTimeUtc.ToUniversalTime() } else { [DateTimeOffset]::Parse([string]$sample.AppStartTimeUtc, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime }
            $sCoreStart = if ($sample.CoreStartTimeUtc -is [DateTime]) { $sample.CoreStartTimeUtc.ToUniversalTime() } else { [DateTimeOffset]::Parse([string]$sample.CoreStartTimeUtc, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime }
            if ($sCoreStart -ne $coreStartTimeUtc) { throw "Order $orderName warmup mode $modeKey Core start time drifted." }

            Assert-RendererUtc $sample.ObservedUtc "Order $orderName warmup mode $modeKey ObservedUtc"
            $sampleTime = [DateTimeOffset]::Parse([string]$sample.ObservedUtc, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime
            if ($sampleTime -le $previousTimestamp) { throw "Order $orderName warmup mode $modeKey timestamp is not strictly increasing." }
            $previousTimestamp = $sampleTime
            $warmupUtc = [string]$sample.ObservedUtc

            if ([string]$sample.RendererMode -cne $expectedRenderer) {
                throw "Order $orderName warmup mode $modeKey expected renderer mode '$expectedRenderer'; found '$($sample.RendererMode)'."
            }

            $latencies = @($sample.LatencyMicroseconds)
            $stalls = @($sample.UiStallMicroseconds)
            if ($latencies.Count -lt 20) { throw "Order $orderName warmup mode $modeKey requires at least 20 latency observations; found $($latencies.Count)." }
            if ($stalls.Count -lt 20) { throw "Order $orderName warmup mode $modeKey requires at least 20 UI-stall observations; found $($stalls.Count)." }

            $boundSample = [pscustomobject][ordered]@{
                cpuBasisPoints = [long]$sample.CpuBasisPoints
                workingSetMaximumBytes = [long]$sample.WorkingSetMaximumBytes
                latencyMicroseconds = @($latencies[0..19] | ForEach-Object { [long]$_ })
                uiStallMicroseconds = @($stalls[0..19] | ForEach-Object { [long]$_ })
            }

            if ($modeKey -eq 'a') { $warmupSampleA = $boundSample } else { $warmupSampleB = $boundSample }
        }

        $canonicalWarmup = [pscustomobject][ordered]@{
            ordinal = 0
            observedUtc = $warmupUtc
            a = $warmupSampleA
            b = $warmupSampleB
        }

        # 5 Measured repetitions
        $canonicalReps = @()
        for ($ri = 0; $ri -lt 5; $ri++) {
            $coreProcess.Refresh()
            if ($coreProcess.HasExited) { throw "Core process ($CoreProcessId) terminated unexpectedly during Order $orderName repetition $ri." }
            if ((Get-ProcessSafeCreationTime $coreProcess) -ne $coreStartTimeUtc) { throw "Core process PID ($CoreProcessId) was recycled during Order $orderName repetition $ri." }

            $repSampleA = $null
            $repSampleB = $null
            $repUtc = $null

            foreach ($modeKey in $executionModes) {
                $expectedRenderer = if ($modeKey -eq 'a') { 'Hardware' } else { 'SoftwareOnly' }
                $liveResult = @(Invoke-V02ProductionPerformanceSample $orderName $false $ri $modeKey $productionSequence $packageBinding $coreProcess $coreStartTimeUtc);$productionSequence++
                if ($liveResult.Count -ne 1) { throw "Live telemetry provider must return exactly one sample for Order $orderName repetition $ri mode $modeKey." }
                $sample = $liveResult[0]

                Assert-RawExactProperties $sample @(
                    'Authenticated', 'Source', 'AppProcessId', 'CoreProcessId',
                    'AppStartTimeUtc', 'CoreStartTimeUtc', 'ObservedUtc', 'RendererMode',
                    'CpuBasisPoints', 'WorkingSetMaximumBytes', 'LatencyMicroseconds', 'UiStallMicroseconds'
                ) "Order $orderName repetition $ri mode $modeKey sample"

                if ($sample.Authenticated -isnot [bool] -or -not $sample.Authenticated) { throw "Order $orderName repetition $ri mode $modeKey sample is not authenticated." }
                if ([string]::IsNullOrWhiteSpace([string]$sample.Source)) { throw "Order $orderName repetition $ri mode $modeKey sample missing source." }
                if ($sample.CoreProcessId -isnot [int] -or [int]$sample.CoreProcessId -ne $CoreProcessId) { throw "Order $orderName repetition $ri mode $modeKey Core PID mismatch." }

                $sAppStart = if ($sample.AppStartTimeUtc -is [DateTime]) { $sample.AppStartTimeUtc.ToUniversalTime() } else { [DateTimeOffset]::Parse([string]$sample.AppStartTimeUtc, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime }
                $sCoreStart = if ($sample.CoreStartTimeUtc -is [DateTime]) { $sample.CoreStartTimeUtc.ToUniversalTime() } else { [DateTimeOffset]::Parse([string]$sample.CoreStartTimeUtc, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime }
                if ($sCoreStart -ne $coreStartTimeUtc) { throw "Order $orderName repetition $ri mode $modeKey Core start time drifted." }

                Assert-RendererUtc $sample.ObservedUtc "Order $orderName repetition $ri mode $modeKey ObservedUtc"
                $sampleTime = [DateTimeOffset]::Parse([string]$sample.ObservedUtc, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime
                if ($sampleTime -le $previousTimestamp) { throw "Order $orderName repetition $ri mode $modeKey timestamp is not strictly increasing." }
                $previousTimestamp = $sampleTime
                $repUtc = [string]$sample.ObservedUtc

                if ([string]$sample.RendererMode -cne $expectedRenderer) {
                    throw "Order $orderName repetition $ri mode $modeKey expected renderer mode '$expectedRenderer'; found '$($sample.RendererMode)'."
                }

                $latencies = @($sample.LatencyMicroseconds)
                $stalls = @($sample.UiStallMicroseconds)
                if ($latencies.Count -lt 20) { throw "Order $orderName repetition $ri mode $modeKey requires at least 20 latency observations; found $($latencies.Count)." }
                if ($stalls.Count -lt 20) { throw "Order $orderName repetition $ri mode $modeKey requires at least 20 UI-stall observations; found $($stalls.Count)." }

                $boundSample = [pscustomobject][ordered]@{
                    cpuBasisPoints = [long]$sample.CpuBasisPoints
                    workingSetMaximumBytes = [long]$sample.WorkingSetMaximumBytes
                    latencyMicroseconds = @($latencies[0..19] | ForEach-Object { [long]$_ })
                    uiStallMicroseconds = @($stalls[0..19] | ForEach-Object { [long]$_ })
                }

                if ($modeKey -eq 'a') { $repSampleA = $boundSample } else { $repSampleB = $boundSample }
            }

            $canonicalReps += [pscustomobject][ordered]@{
                ordinal = [int]$ri
                observedUtc = $repUtc
                a = $repSampleA
                b = $repSampleB
            }
        }

        $canonicalOrders += [pscustomobject][ordered]@{
            order = $orderName
            warmup = @($canonicalWarmup)
            repetitions = $canonicalReps
        }
    }
}
# -----------------------------------------------------------------------------
# SYNTHETIC MODE EXECUTION
# -----------------------------------------------------------------------------
else {
    $governedOrders = @('AB', 'BA')
    $baseTime = [DateTime]::UtcNow.AddHours(-1)

    for ($oi = 0; $oi -lt 2; $oi++) {
        $orderName = $governedOrders[$oi]

        # Warmup
        $warmupUtc = $baseTime.AddMinutes($oi * 20).ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')
        $warmupSampleA = $null
        $warmupSampleB = $null

        $executionModes = if ($orderName -ceq 'AB') { @('a', 'b') } else { @('b', 'a') }
        foreach ($modeKey in $executionModes) {
            $sample = if ($null -ne $SyntheticTelemetryProvider) {
                & $SyntheticTelemetryProvider $orderName $true 0 $modeKey
            } else {
                [pscustomobject][ordered]@{
                    cpuBasisPoints = 50
                    workingSetMaximumBytes = 104857600
                    latencyMicroseconds = @(1..20 | ForEach-Object { 100000L })
                    uiStallMicroseconds = @(1..20 | ForEach-Object { 10000L })
                }
            }

            Assert-RawExactProperties $sample @('cpuBasisPoints','workingSetMaximumBytes','latencyMicroseconds','uiStallMicroseconds') "Synthetic order $orderName warmup mode $modeKey"
            $latencies = @($sample.latencyMicroseconds)
            $stalls = @($sample.uiStallMicroseconds)
            if ($latencies.Count -lt 20) { throw "Synthetic order $orderName warmup mode $modeKey requires at least 20 latency observations; found $($latencies.Count)." }
            if ($stalls.Count -lt 20) { throw "Synthetic order $orderName warmup mode $modeKey requires at least 20 UI-stall observations; found $($stalls.Count)." }

            $boundSample = [pscustomobject][ordered]@{
                cpuBasisPoints = [long]$sample.cpuBasisPoints
                workingSetMaximumBytes = [long]$sample.workingSetMaximumBytes
                latencyMicroseconds = @($latencies[0..19] | ForEach-Object { [long]$_ })
                uiStallMicroseconds = @($stalls[0..19] | ForEach-Object { [long]$_ })
            }

            if ($modeKey -eq 'a') { $warmupSampleA = $boundSample } else { $warmupSampleB = $boundSample }
        }

        $canonicalWarmup = [pscustomobject][ordered]@{
            ordinal = 0
            observedUtc = $warmupUtc
            a = $warmupSampleA
            b = $warmupSampleB
        }

        # 5 Repetitions
        $canonicalReps = @()
        for ($ri = 0; $ri -lt 5; $ri++) {
            $repUtc = $baseTime.AddMinutes($oi * 20 + $ri + 1).ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')
            $repSampleA = $null
            $repSampleB = $null

            foreach ($modeKey in $executionModes) {
                $sample = if ($null -ne $SyntheticTelemetryProvider) {
                    & $SyntheticTelemetryProvider $orderName $false $ri $modeKey
                } else {
                    [pscustomobject][ordered]@{
                        cpuBasisPoints = 50
                        workingSetMaximumBytes = 104857600
                        latencyMicroseconds = @(1..20 | ForEach-Object { 100000L })
                        uiStallMicroseconds = @(1..20 | ForEach-Object { 10000L })
                    }
                }

                Assert-RawExactProperties $sample @('cpuBasisPoints','workingSetMaximumBytes','latencyMicroseconds','uiStallMicroseconds') "Synthetic order $orderName rep $ri mode $modeKey"
                $latencies = @($sample.latencyMicroseconds)
                $stalls = @($sample.uiStallMicroseconds)
                if ($latencies.Count -lt 20) { throw "Synthetic order $orderName rep $ri mode $modeKey requires at least 20 latency observations; found $($latencies.Count)." }
                if ($stalls.Count -lt 20) { throw "Synthetic order $orderName rep $ri mode $modeKey requires at least 20 UI-stall observations; found $($stalls.Count)." }

                $boundSample = [pscustomobject][ordered]@{
                    cpuBasisPoints = [long]$sample.cpuBasisPoints
                    workingSetMaximumBytes = [long]$sample.workingSetMaximumBytes
                    latencyMicroseconds = @($latencies[0..19] | ForEach-Object { [long]$_ })
                    uiStallMicroseconds = @($stalls[0..19] | ForEach-Object { [long]$_ })
                }

                if ($modeKey -eq 'a') { $repSampleA = $boundSample } else { $repSampleB = $boundSample }
            }

            $canonicalReps += [pscustomobject][ordered]@{
                ordinal = [int]$ri
                observedUtc = $repUtc
                a = $repSampleA
                b = $repSampleB
            }
        }

        $canonicalOrders += [pscustomobject][ordered]@{
            order = $orderName
            warmup = @($canonicalWarmup)
            repetitions = $canonicalReps
        }
    }

}

# Construct raw observations object
$rawObservationsObject = [pscustomobject][ordered]@{
    orders = $canonicalOrders
}

# JCS Canonicalization
$canonicalJson = ConvertTo-RendererCanonicalJson $rawObservationsObject $RepositoryRoot
$canonicalSha = Get-HumanDesignReviewSha256ForText $canonicalJson
$fileBytes = (New-Object Text.UTF8Encoding($false, $true)).GetBytes($canonicalJson + "`n")
$bindingBytes = $null
if (-not $Synthetic) {
    if ($script:V02ProductionPerformanceBindings.Count -ne 24) { throw 'Production performance telemetry binding must contain exactly 24 authenticated acquisitions.' }
    $bindingObject=[pscustomobject][ordered]@{
        schemaVersion=3;evidenceClassification='PackagedCompatibilityPerformanceTelemetryBinding-NoRuntimeCredit';runNonce=$RunNonce
        source=[pscustomobject][ordered]@{commitSha=$ExpectedSourceCommit;treeSha=$ExpectedSourceTree}
        session=[pscustomobject][ordered]@{kind='LocalConsole';name='Issue10PerformanceComparator';sessionId=$performanceSessionId;transport='Physical';elevated=$false;userScope='SingleUser'}
        package=[pscustomobject][ordered]@{identitySha256=$packageBinding.ReceiptSha256;identityFileSha256=$packageBinding.IdentityFileSha256;profileFileSha256=$packageBinding.ProfileFileSha256;archiveSha256=$packageBinding.ArchiveSha256;manifestSha256=$packageBinding.ManifestSha256;appSha256=$packageBinding.AppSha256;coreSha256=$packageBinding.CoreSha256}
        rawSource=[pscustomobject][ordered]@{relativePath=$destinationRelative;bytes=[long]$fileBytes.Length;fileSha256=(Get-HumanDesignReviewSha256ForBytes $fileBytes);canonicalSha256=$canonicalSha}
        acquisitions=@($script:V02ProductionPerformanceBindings)
        evidenceBoundary=[pscustomobject][ordered]@{actualHerdrRuntime='NOT_OBSERVED';release='NOT_OBSERVED';creditGranted=$false}
    }
    $bindingJson=ConvertTo-RendererCanonicalJson $bindingObject $RepositoryRoot
    $bindingBytes=(New-Object Text.UTF8Encoding($false,$true)).GetBytes($bindingJson+"`n")
    $commitObject=[pscustomobject][ordered]@{schemaVersion=1;kind='issue10-performance-transaction-commit';runNonce=$RunNonce;raw=[pscustomobject][ordered]@{fileName=[IO.Path]::GetFileName($fullDestinationPath);bytes=[long]$fileBytes.Length;sha256=(Get-HumanDesignReviewSha256ForBytes $fileBytes)};binding=[pscustomobject][ordered]@{fileName=[IO.Path]::GetFileName($fullBindingDestinationPath);bytes=[long]$bindingBytes.Length;sha256=(Get-HumanDesignReviewSha256ForBytes $bindingBytes)};creditGranted=$false}
    $commitJson=ConvertTo-RendererCanonicalJson $commitObject $RepositoryRoot;$commitBytes=(New-Object Text.UTF8Encoding($false,$true)).GetBytes($commitJson+"`n")
}

# Atomic Write / Commit with crash rollback
if(-not$Synthetic){
    $transaction=Publish-V02PerformanceTransaction -DestinationDirectory $destinationParent -EvidenceRoot $EvidenceRoot -RawFileName ([IO.Path]::GetFileName($fullDestinationPath)) -RawBytes $fileBytes -BindingFileName ([IO.Path]::GetFileName($fullBindingDestinationPath)) -BindingBytes $bindingBytes -CommitBytes $commitBytes -FaultStage $TestFaultInjectionStage
}else{
    $stagingDirectory=Join-Path $destinationParent ('.raw-perf-stage-'+[Guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $stagingDirectory|Out-Null;$stagingPath=Join-Path $stagingDirectory ([IO.Path]::GetFileName($fullDestinationPath))
    try{$stream=[IO.File]::Open($stagingPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);try{$stream.Write($fileBytes,0,$fileBytes.Length);$stream.Flush($true);if($TestFaultInjectionStage-eq'MidWrite'){throw 'Injected performance collector crash during staging write.'}}finally{$stream.Dispose()};if($TestFaultInjectionStage-eq'BeforeCommit'){throw 'Injected performance collector crash before atomic commit.'};if(Test-Path -LiteralPath $fullDestinationPath){throw "Raw performance observations destination file appeared during publish; refusing to clobber '$fullDestinationPath'."};[IO.File]::Move($stagingPath,$fullDestinationPath)}finally{if(Test-Path -LiteralPath $stagingDirectory){Remove-Item -LiteralPath $stagingDirectory -Recurse -Force -ErrorAction SilentlyContinue}}
}

# Verify post-move stable file identity
$stableIdentity = Get-RendererStableFileIdentity $EvidenceRoot $fullDestinationPath 'Raw performance observations' -IncludeBytes
if ($stableIdentity.Bytes -ne [long]$fileBytes.Length -or $stableIdentity.Sha256 -ne (Get-HumanDesignReviewSha256ForBytes $fileBytes)) {
    throw 'Raw performance observations file identity changed during atomic publish.'
}
if ($stableIdentity.Content.Length -ne $fileBytes.Length) {
    throw 'Raw performance observations byte count changed during atomic publish.'
}
for ($i = 0; $i -lt $fileBytes.Length; $i++) {
    if ($stableIdentity.Content[$i] -ne $fileBytes[$i]) {
        throw 'Raw performance observations bytes changed during atomic publish.'
    }
}
if(-not$Synthetic){$bindingStable=Get-RendererStableFileIdentity $EvidenceRoot $fullBindingDestinationPath 'Performance telemetry binding' -IncludeBytes;$commitPath=Join-Path $destinationParent 'performance-commit.json';$commitStable=Get-RendererStableFileIdentity $EvidenceRoot $commitPath 'Performance transaction commit' -IncludeBytes;if($bindingStable.Sha256-cne(Get-HumanDesignReviewSha256ForBytes $bindingBytes)-or$commitStable.Sha256-cne(Get-HumanDesignReviewSha256ForBytes $commitBytes)){throw 'Live performance transaction files changed after atomic directory commit.'}}

$evidenceClass = if ($Synthetic) { 'SyntheticVerifierSelftest' } else { 'PackagedCompatibilityRawPerformance' }

[pscustomobject][ordered]@{
    EvidenceClassification = $evidenceClass
    RawSourcePath = $fullDestinationPath
    BindingPath = $fullBindingDestinationPath
    CommitMarkerPath = if($Synthetic){$null}else{Join-Path $destinationParent 'performance-commit.json'}
    RelativePath = $destinationRelative
    Bytes = [long]$stableIdentity.Bytes
    FileSha256 = [string]$stableIdentity.Sha256
    CanonicalSha256 = [string]$canonicalSha
    Orders = $canonicalOrders
    RawObservations = $rawObservationsObject
}
