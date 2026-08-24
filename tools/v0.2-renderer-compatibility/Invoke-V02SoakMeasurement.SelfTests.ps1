#requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'RendererCompatibility.Common.ps1')
. (Join-Path $PSScriptRoot 'lib\V02SoakTestHarness.ps1')
$script:InvokeSoakPath = Join-Path $PSScriptRoot 'Invoke-V02SoakMeasurement.ps1'

$positiveCases = 0
$negativeCases = 0

function Pass-PositiveCase([string]$Name) {
    $script:positiveCases++
    Write-Host "PASS positive: $Name"
}

function Pass-NegativeCase([string]$Name) {
    $script:negativeCases++
    Write-Host "PASS negative: $Name"
}

function Assert-ThrowsMatch([scriptblock]$ScriptBlock, [string]$Pattern, [string]$CaseName) {
    try {
        & $ScriptBlock | Out-Null
        throw "Expected failure matching '$Pattern', but no exception was thrown: $CaseName"
    } catch {
        if ($_.Exception.Message -match $Pattern) {
            Pass-NegativeCase $CaseName
        } else {
            throw "Expected failure matching '$Pattern', but got '$($_.Exception.Message)': $CaseName"
        }
    }
}

function Assert-ThrowsMatchAndZeroOutput([scriptblock]$ScriptBlock, [string]$Pattern, [string]$CaseName, [string]$TargetDest = $null) {
    $caught = $false
    $caughtMsg = $null
    try {
        & $ScriptBlock | Out-Null
    } catch {
        $caught = $true
        $caughtMsg = $_.Exception.Message
    }
    if (-not $caught) {
        throw "Expected failure matching pattern '$Pattern', but no exception was thrown: $CaseName"
    }
    if ($caughtMsg -notmatch $Pattern) {
        throw "Expected failure matching pattern '$Pattern', but got: '$caughtMsg': $CaseName"
    }
    if (-not [string]::IsNullOrWhiteSpace($TargetDest)) {
        if (Test-Path -LiteralPath $TargetDest) {
            throw "Hostile negative test leaked published receipt at target destination '$TargetDest': $CaseName"
        }
        $parent = Split-Path -Parent $TargetDest
        if (Test-Path -LiteralPath $parent) {
            $orphans = @(Get-ChildItem -LiteralPath $parent -Filter '*.staging*' -Force)
            if ($orphans.Count -gt 0) {
                throw "Hostile negative test leaked staging file(s) in parent directory: $CaseName"
            }
        }
    }
    Pass-NegativeCase $CaseName
}

function Test-SelfTestProcessElevated {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-LivePreflightGuardSourceContract {
    $source = [IO.File]::ReadAllText($script:InvokeSoakPath)
    $elevationCheck = $source.IndexOf('$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)', [StringComparison]::Ordinal)
    $elevationFailure = $source.IndexOf('Live soak measurement must execute in a non-elevated user context.', [StringComparison]::Ordinal)
    $processLookup = $source.IndexOf('$appProcess = [System.Diagnostics.Process]::GetProcessById($AppProcessId)', [StringComparison]::Ordinal)
    $processFailure = $source.IndexOf('Unable to connect to target App ($AppProcessId) or Core ($CoreProcessId) process:', [StringComparison]::Ordinal)
    if ($elevationCheck -lt 0 -or $elevationFailure -le $elevationCheck -or $processLookup -le $elevationFailure -or $processFailure -le $processLookup) {
        throw 'Production live soak preflight guard order or exact failure contract drifted.'
    }
}

function Invoke-IsolatedLivePreflightGuardFixture {
    param([bool]$Elevated,[Parameter(Mandatory = $true)][scriptblock]$ResolveTargetProcesses)
    if ($Elevated) { throw 'Live soak measurement must execute in a non-elevated user context.' }
    try { & $ResolveTargetProcesses | Out-Null }
    catch { throw "Unable to connect to target App (999999) or Core (999998) process: $($_.Exception.Message)" }
}

function New-TestRepository([string]$Root) {
    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $Root 'source.txt'), 'bound source', (New-Object Text.UTF8Encoding($false)))
    $worktree = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    $basePackageDir = Join-Path $Root 'tools\packaging'
    $packageDir = Join-Path $Root 'tools\packaging\v0.2'
    $libDir = Join-Path $Root 'tools\lib'
    $planDir = Join-Path $Root 'Plan\reference-hosts'
    $referenceDir = Join-Path $Root 'docs\design\reference'
    New-Item -ItemType Directory -Path $basePackageDir, $packageDir, $libDir, $planDir, $referenceDir -Force | Out-Null
    Copy-Item (Join-Path $worktree 'tools\packaging\*.*') $basePackageDir -Force -ErrorAction SilentlyContinue
    $sourcePackageDir = Join-Path $PSScriptRoot '..\packaging\v0.2'
    Copy-Item (Join-Path $sourcePackageDir 'package-identity-profile.json') $packageDir
    Copy-Item (Join-Path $sourcePackageDir 'package-identity-receipt.schema.json') $packageDir
    Copy-Item (Join-Path $sourcePackageDir 'Test-V02PackageIdentity.ps1') $packageDir
    Copy-Item (Join-Path $sourcePackageDir 'V02PackageIdentity.Common.ps1') $packageDir
    Copy-Item (Join-Path $worktree 'tools\lib\V02ReferenceHostProfile.ps1') $libDir
    Copy-Item (Join-Path $worktree 'tools\lib\V02RuntimePackageBinding.ps1') $libDir
    Copy-Item (Join-Path $worktree 'Plan\reference-hosts\v0.2.json') $planDir
    Copy-Item (Join-Path $worktree 'Plan\reference-hosts\reference-host-profile.schema.json') $planDir
    Copy-Item (Join-Path $worktree 'docs\design\reference\*.png') $referenceDir
    & git -C $Root init --quiet
    & git -C $Root -c core.hooksPath=NUL -c user.name=RendererFixture -c user.email=renderer@example.invalid add .
    & git -C $Root -c core.hooksPath=NUL -c commit.gpgsign=false -c user.name=RendererFixture -c user.email=renderer@example.invalid commit --quiet -m fixture
    if ($LASTEXITCODE -ne 0) { throw 'Unable to create isolated Git fixture.' }
    return [pscustomobject]@{
        Root = $Root
        Commit = (& git -C $Root rev-parse HEAD).Trim()
        Tree = (& git -C $Root rev-parse 'HEAD^{tree}').Trim()
    }
}

function Get-TestSampleProvider([double]$WsStartMb = 100, [double]$WsEndMb = 100.0, [double]$CpuBp = 30, [double]$LatMs = 100, [double]$StlMs = 10, [double]$StlMaxMs = 20, [bool]$RendererStable = $true) {
    $sb = {
        param($binIndex, $sampleIndex, $elapsedMs)
        $wsMb = if ($sampleIndex -eq 0) { $WsStartMb } else { $WsEndMb }
        $ws = [long]($wsMb * 1048576)
        $stalls = @(1..19 | ForEach-Object { [long]($StlMs * 1000) }) + @([long]($StlMaxMs * 1000))
        [pscustomobject][ordered]@{
            AppWorkingSetBytes = [long]($ws * 0.7)
            AppPrivateBytes = [long]($ws * 0.6)
            AppCpuBasisPoints = [long]($CpuBp * 0.6)
            CoreWorkingSetBytes = [long]($ws * 0.3)
            CorePrivateBytes = [long]($ws * 0.25)
            CoreCpuBasisPoints = [long]($CpuBp * 0.4)
            LatencyMicroseconds = @(1..20 | ForEach-Object { [long]($LatMs * 1000) })
            UiStallMicroseconds = $stalls
            RendererStable = [bool]$RendererStable
        }
    }
    return $sb.GetNewClosure()
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("herdrops-soak-selftest-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    $repo = New-TestRepository (Join-Path $tempRoot 'repo')
    $repoRoot = $repo.Root

    $goldenPacket=New-V02TestTelemetryPacket -Nonce ('a'*32) -SequenceNumber 0 -BinIndex 0 -SampleIndex 0 -AppProcessId 101 -CoreProcessId 202 -AppStartTimeUtc ([datetime]'2026-08-24T00:00:00Z') -CoreStartTimeUtc ([datetime]'2026-08-24T00:00:00Z') -AppExecutablePath 'C:\Program Files\HerdrOps\HerdrOps.App.exe' -CoreExecutablePath 'C:\Program Files\HerdrOps\HerdrOps.Core.exe' -AppExecutableSha256 ('A'*64) -CoreExecutableSha256 ('B'*64) -ObservedUtc '2026-08-24T00:00:01.0000000+00:00' -BaselineStateSequence 10 -AfterStateSequence 10 -BaselineRecordCount 20 -AfterRecordCount 20 -LatencyUpdates @() -RepositoryRoot $repoRoot
    if($goldenPacket.packetSha256-cne'A8BD43DE995F7C62959B65F99827E55ED644918113A1E01B1032750A1F7B84D1'){throw 'Cross-language zero-update packet golden hash drifted.'}
    $goldenTransportJson=$goldenPacket|ConvertTo-Json -Depth 30 -Compress;$parsedGoldenPacket=ConvertFrom-RendererTransportJson $goldenTransportJson 'Golden soak transport packet'
    foreach($timestamp in @($parsedGoldenPacket.observedUtc,$parsedGoldenPacket.producer.appStartTimeUtc,$parsedGoldenPacket.producer.coreStartTimeUtc)){if($timestamp-isnot[string]){throw "Transport JSON timestamp was coerced to $($timestamp.GetType().FullName)."}}
    $previousUtc=[datetime]::MinValue;$baseline=[long]::MinValue;$watermark=[long]::MinValue;$baselineCount=[long]::MinValue;$recordCount=[long]::MinValue
    Assert-V02TrustedTelemetryPacket -Packet $parsedGoldenPacket -ExpectedNonce ('a'*32) -ExpectedSequenceNumber 0 -ExpectedBinIndex 0 -ExpectedSampleIndex 0 -ExpectedAppProcessId 101 -ExpectedCoreProcessId 202 -ExpectedAppStartTimeUtc ([datetime]'2026-08-24T00:00:00Z') -ExpectedCoreStartTimeUtc ([datetime]'2026-08-24T00:00:00Z') -ExpectedAppExecutablePath 'C:\Program Files\HerdrOps\HerdrOps.App.exe' -ExpectedCoreExecutablePath 'C:\Program Files\HerdrOps\HerdrOps.Core.exe' -ExpectedAppExecutableSha256 ('A'*64) -ExpectedCoreExecutableSha256 ('B'*64) -PreviousTimestampRef ([ref]$previousUtc) -LatencyBaselineRef ([ref]$baseline) -PreviousLatencyWatermarkRef ([ref]$watermark) -LatencyBaselineRecordCountRef ([ref]$baselineCount) -PreviousLatencyRecordCountRef ([ref]$recordCount) -RepositoryRoot $repoRoot
    Pass-PositiveCase 'C# and PowerShell RFC8785 zero-update packet golden is stable'
    $validateGolden={param($packet)$p=[datetime]::MinValue;$b=[long]::MinValue;$w=[long]::MinValue;$bc=[long]::MinValue;$rc=[long]::MinValue;Assert-V02TrustedTelemetryPacket -Packet $packet -ExpectedNonce ('a'*32) -ExpectedSequenceNumber 0 -ExpectedBinIndex 0 -ExpectedSampleIndex 0 -ExpectedAppProcessId 101 -ExpectedCoreProcessId 202 -ExpectedAppStartTimeUtc ([datetime]'2026-08-24T00:00:00Z') -ExpectedCoreStartTimeUtc ([datetime]'2026-08-24T00:00:00Z') -ExpectedAppExecutablePath 'C:\Program Files\HerdrOps\HerdrOps.App.exe' -ExpectedCoreExecutablePath 'C:\Program Files\HerdrOps\HerdrOps.Core.exe' -ExpectedAppExecutableSha256 ('A'*64) -ExpectedCoreExecutableSha256 ('B'*64) -PreviousTimestampRef ([ref]$p) -LatencyBaselineRef ([ref]$b) -PreviousLatencyWatermarkRef ([ref]$w) -LatencyBaselineRecordCountRef ([ref]$bc) -PreviousLatencyRecordCountRef ([ref]$rc) -RepositoryRoot $repoRoot}
    foreach($case in @('schema','sequence','pid','renderer')){$bad=ConvertFrom-RendererTransportJson $goldenTransportJson "Golden $case hostile";switch($case){'schema'{$bad.schemaVersion='2'}'sequence'{$bad.sequenceNumber='0'}'pid'{$bad.producer.appProcessId='101'}'renderer'{$bad.metrics.rendererStable='false'}};Assert-ThrowsMatch {&$validateGolden $bad} 'native integer|native boolean' "telemetry $case native JSON type confusion fails closed"}

    $timeoutServer=$null;$timeoutClient=$null;$timeoutReader=$null;$timeoutWriter=$null;$cleanupProbe=$null;$cleanupProbeId=0
    try{
        $timeoutPipeName='herdrops-soak-timeout-'+[Guid]::NewGuid().ToString('N')
        $timeoutServer=New-Object IO.Pipes.NamedPipeServerStream($timeoutPipeName,[IO.Pipes.PipeDirection]::InOut,1,[IO.Pipes.PipeTransmissionMode]::Byte,[IO.Pipes.PipeOptions]::Asynchronous)
        $timeoutClient=New-Object IO.Pipes.NamedPipeClientStream('.', $timeoutPipeName,[IO.Pipes.PipeDirection]::InOut,[IO.Pipes.PipeOptions]::Asynchronous)
        $connectTask=$timeoutServer.WaitForConnectionAsync();$timeoutClient.Connect(5000);$connectTask.GetAwaiter().GetResult()|Out-Null
        $timeoutReader=New-Object IO.StreamReader($timeoutServer,(New-Object Text.UTF8Encoding($false,$true)),$false,4096,$true)
        $timeoutWriter=New-Object IO.StreamWriter($timeoutServer,(New-Object Text.UTF8Encoding($false)),4096,$true);$timeoutWriter.AutoFlush=$true
        $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes('Start-Sleep -Seconds 60'));$cleanupProbe=Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-EncodedCommand',$encoded) -WindowStyle Hidden -PassThru;$cleanupProbeId=$cleanupProbe.Id;$cleanupProbeStart=$cleanupProbe.StartTime.ToUniversalTime()
        $primaryMessage=$null;try{Read-RendererTargetPipeLine $timeoutReader 1|Out-Null}catch{$primaryMessage=$_.Exception.Message}
        $cleanup=Close-RendererTargetPipeSession -Writer $timeoutWriter -Reader $timeoutReader -Pipe $timeoutServer -AppProcess $cleanupProbe -AppStartTimeUtc $cleanupProbeStart -GracefulWaitMilliseconds 50 -KillWaitMilliseconds 2000
        if($primaryMessage-notmatch'timed out after 1 seconds'-or-not$cleanup.WriterCleanupAttempted-or-not$cleanup.ReaderCleanupAttempted-or-not$cleanup.PipeCleanupAttempted-or-not$cleanup.AppCleanupAttempted-or-not$cleanup.AppTerminationAttempted-or$null-ne(Get-Process -Id $cleanupProbeId -ErrorAction SilentlyContinue)){throw 'Pending-read timeout did not preserve its primary error and complete independent writer/reader/pipe/App teardown.'}
        Pass-NegativeCase 'pending-read timeout preserves primary error and cannot skip writer/reader/pipe/App teardown'
    }finally{
        foreach($disposable in @($timeoutWriter,$timeoutReader,$timeoutClient,$timeoutServer)){if($null-ne$disposable){try{$disposable.Dispose()}catch{}}}
        if($cleanupProbeId-gt0){$leftover=Get-Process -Id $cleanupProbeId -ErrorAction SilentlyContinue;if($null-ne$leftover){try{$leftover.Kill();$leftover.WaitForExit(2000)|Out-Null}catch{}finally{$leftover.Dispose()}}}
    }

    # -------------------------------------------------------------------------
    # POSITIVE TESTS
    # -------------------------------------------------------------------------

    # 1. AC 60-Minute Soak Synthetic Generation
    $acDest = Join-Path $tempRoot 'matrix\soak-ac-60-minutes.json'
    $acRes = & $script:InvokeSoakPath -Synthetic `
        -PowerSource 'AC' `
        -DestinationPath $acDest `
        -EvidenceRoot $tempRoot `
        -RepositoryRoot $repoRoot `
        -SyntheticTotalBins 12 `
        -SyntheticBinDurationMinutes 5 `
        -SyntheticSamplesPerBin 2 `
        -SyntheticPowerStateProvider { 'AC' } `
        -SyntheticProcessTelemetryProvider (Get-TestSampleProvider -WsStartMb 100 -WsEndMb 100.2)

    if ($acRes.AggregateStatus -ne 'PASS' -or $acRes.TotalBins -ne 12 -or $acRes.Bins.Count -ne 12) {
        throw "AC soak result failed basic assertions."
    }
    Pass-PositiveCase 'valid AC 60-minute soak generation with 12 consecutive 5-minute bins'

    # 2. Battery 60-Minute Soak Synthetic Generation
    $batDest = Join-Path $tempRoot 'matrix\soak-battery-60-minutes.json'
    $batRes = & $script:InvokeSoakPath -Synthetic `
        -PowerSource 'Battery' `
        -DestinationPath $batDest `
        -EvidenceRoot $tempRoot `
        -RepositoryRoot $repoRoot `
        -SyntheticTotalBins 12 `
        -SyntheticBinDurationMinutes 5 `
        -SyntheticSamplesPerBin 2 `
        -SyntheticPowerStateProvider { 'Battery' } `
        -SyntheticProcessTelemetryProvider (Get-TestSampleProvider -WsStartMb 110 -WsEndMb 110.3)

    if ($batRes.AggregateStatus -ne 'PASS' -or $batRes.TotalBins -ne 12 -or $batRes.Bins.Count -ne 12) {
        throw "Battery soak result failed basic assertions."
    }
    Pass-PositiveCase 'valid Battery 60-minute soak generation with 12 consecutive 5-minute bins'

    # 3. Canonical JCS JSON File Verification
    $rawBytes = [IO.File]::ReadAllBytes($acDest)
    if ($rawBytes[0] -eq 0xEF -and $rawBytes[1] -eq 0xBB -and $rawBytes[2] -eq 0xBF) {
        throw "Emitted soak receipt contains forbidden UTF-8 BOM."
    }
    if ($rawBytes[-1] -ne 0x0A) {
        throw "Emitted soak receipt must end with exactly one newline."
    }
    Pass-PositiveCase 'emitted receipt is valid canonical JCS without BOM ending with LF'

    # 4. Matrix Observations Schema Consistency
    if ($acRes.Observations.Count -ne 12 -or $acRes.Observations[0].outcome -ne 'PASS') {
        throw "Matrix observations array malformed."
    }
    Pass-PositiveCase 'matrix observations array correctly populated for manifest inclusion'

    # 5. Soak Bins Compatibility with 19b Performance Receipt
    for ($bi = 0; $bi -lt 12; $bi++) {
        $bin = $acRes.Bins[$bi]
        if ($bin.powerSource -ne 'AC' -or $bin.ordinal -ne $bi -or $bin.durationMinutes -ne 5 -or -not $bin.rendererStable) {
            throw "Bin $bi does not meet 19b performance soak bin contract."
        }
    }
    Pass-PositiveCase 'soak bins meet 19b performance receipt contract'

    # 6. Boundary Flags Verification
    $doc = $acRes.ReceiptDocument
    if ($doc.evidenceBoundary.creditGranted -ne $false -or
        $doc.evidenceBoundary.actualHerdrRuntime -ne 'NOT_OBSERVED' -or
        $doc.evidenceBoundary.humanReview -ne 'NOT_OBSERVED' -or
        $doc.evidenceBoundary.release -ne 'NOT_OBSERVED') {
        throw "Evidence boundary does not explicitly deny runtime/release credit."
    }
    Pass-PositiveCase 'evidence boundary explicitly denies runtime, release, and credit'

    # 7. Governance, Session, Source, and Candidate Bindings Preserved
    if ($doc.governance.profileId -ne $script:RendererProfileId -or
        $doc.governance.profileSha256 -ne $script:RendererProfileSha256 -or
        $doc.governance.packageProfileId -ne $script:RendererPackageProfileId -or
        $doc.source.commitSha -ne $repo.Commit -or
        $doc.source.treeSha -ne $repo.Tree -or
        $doc.session.kind -ne 'LocalConsole' -or
        $doc.session.transport -ne 'Physical' -or
        $doc.session.elevated -ne $false) {
        throw "Candidate governance, session, or source binding mismatch."
    }
    Pass-PositiveCase 'governance, session, source, and candidate bindings preserved'

    # 8. Valid Package Identity Binding
    $packageRoot = Join-Path $tempRoot 'package'
    New-Item -ItemType Directory -Path $packageRoot -Force | Out-Null
    $appPath = Join-Path $packageRoot 'HerdrOps.App.exe'
    $corePath = Join-Path $packageRoot 'HerdrOps.Core.exe'
    [IO.File]::WriteAllBytes($appPath, [Text.Encoding]::UTF8.GetBytes('app-binary'))
    Copy-Item -LiteralPath (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -Destination $corePath
    $profilePath = Join-Path $repoRoot 'tools\packaging\v0.2\package-identity-profile.json'
    $profileValue = Read-RendererPackageProfile $profilePath
    $manifestObj = New-RendererPackageManifest $profileValue $repoRoot $packageRoot
    $manifestPath = Join-Path $packageRoot 'package-manifest.json'
    Write-RendererPackageCanonicalJson $manifestObj $manifestPath $repoRoot
    $manifestStable = Get-RendererPackageStableIdentity $manifestPath
    $archivePath = Join-Path $tempRoot 'HerdrOps-0.2.0-win-x64.zip'
    $null = New-RendererDeterministicPackageArchive $packageRoot $archivePath
    $archiveStable = Get-RendererPackageStableIdentity $archivePath
    $appStable = Get-RendererPackageStableIdentity $appPath
    $coreStable = Get-RendererPackageStableIdentity $corePath
    $profileIdentity = Get-RendererPackageProfileIdentity $profilePath $profileValue $repoRoot
    $receiptValue = [pscustomobject][ordered]@{
        schemaVersion = 1
        profileId = $script:RendererPackageProfileId
        issue = 149
        packageVersion = '0.2.0'
        runtimeIdentifier = 'win-x64'
        source = [pscustomobject][ordered]@{ commitSha = $repo.Commit; treeSha = $repo.Tree }
        profile = [pscustomobject][ordered]@{ id = $profileIdentity.Id; relativePath = $profileIdentity.RelativePath; bytes = $profileIdentity.Bytes; fileSha256 = $profileIdentity.FileSha256; canonicalSha256 = $profileIdentity.CanonicalSha256 }
        archive = [pscustomobject][ordered]@{ relativePath = 'HerdrOps-0.2.0-win-x64.zip'; fileName = 'HerdrOps-0.2.0-win-x64.zip'; bytes = $archiveStable.Length; sha256 = $archiveStable.Sha256 }
        packageManifest = [pscustomobject][ordered]@{ fileName = 'package-manifest.json'; bytes = $manifestStable.Length; sha256 = $manifestStable.Sha256; contentSha256 = $manifestObj.contentSha256; fileCount = [int]$manifestObj.fileCount; totalBytes = [long]$manifestObj.totalBytes }
        components = [pscustomobject][ordered]@{
            app = [pscustomobject][ordered]@{ relativePath = 'HerdrOps.App.exe'; bytes = $appStable.Length; sha256 = $appStable.Sha256 }
            core = [pscustomobject][ordered]@{ relativePath = 'HerdrOps.Core.exe'; bytes = $coreStable.Length; sha256 = $coreStable.Sha256 }
        }
        referenceHost = [pscustomobject][ordered]@{ profileId = $script:RendererProfileId; profileSha256 = $script:RendererProfileSha256 }
        renderer = [pscustomobject][ordered]@{ policy = 'software-only-process-wide'; wpfProcessRenderMode = 'SoftwareOnly' }
        evidenceBoundary = [pscustomobject][ordered]@{ evidenceClass = 'PackagedCompatibilityPreparation'; runtimeUse = 'not-used'; actualHerdrUsed = $false; runtimeCredit = 'NOT CLAIMED'; releaseCredit = 'NOT CLAIMED' }
    }
    $receiptPath = Join-Path $tempRoot 'package-identity-receipt.json'
    Write-RendererPackageCanonicalJson $receiptValue $receiptPath $repoRoot

    $pkgDest = Join-Path $tempRoot 'matrix\soak-with-pkg.json'
    $pkgRes = & $script:InvokeSoakPath -Synthetic `
        -PowerSource 'AC' `
        -DestinationPath $pkgDest `
        -EvidenceRoot $tempRoot `
        -RepositoryRoot $repoRoot `
        -PackageIdentityPath $receiptPath `
        -PackageArchivePath $archivePath `
        -ExtractedPackageRoot $packageRoot `
        -SyntheticTotalBins 2 `
        -SyntheticBinDurationMinutes 5 `
        -SyntheticSamplesPerBin 2 `
        -SyntheticPowerStateProvider { 'AC' } `
        -SyntheticProcessTelemetryProvider (Get-TestSampleProvider)

    if ($null -eq $pkgRes.ReceiptDocument.package -or
        $pkgRes.ReceiptDocument.package.archiveSha256 -ne $archiveStable.Sha256 -or
        $pkgRes.ReceiptDocument.package.appSha256 -ne $appStable.Sha256) {
        throw "Package binding was not recorded in the receipt document."
    }
    Pass-PositiveCase 'valid package identity binding when package parameters are supplied'

    # Exercise the actual live setup boundary: the pipe is created and the
    # exact packaged Core is live, but the invalid packaged App fails before
    # connect/hello. The outer production finally must release the pipe.
    $preHelloNonce=[Guid]::NewGuid().ToString('N');$preHelloDest=Join-Path $tempRoot 'matrix\pre-hello-failure.json';$coreProbe=$null;$preHelloFailure=$null;$reopenedPipe=$null
    try{
        $encodedSleep=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes('Start-Sleep -Seconds 60'))
        $coreProbe=Start-Process -FilePath $corePath -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-EncodedCommand',$encodedSleep) -WindowStyle Hidden -PassThru
        try{&$script:InvokeSoakPath -PowerSource AC -DestinationPath $preHelloDest -EvidenceRoot $tempRoot -RepositoryRoot $repoRoot -CoreProcessId $coreProbe.Id -PackageIdentityPath $receiptPath -PackageArchivePath $archivePath -ExtractedPackageRoot $packageRoot -ExpectedSourceCommit $repo.Commit -ExpectedSourceTree $repo.Tree -ChannelNonce $preHelloNonce|Out-Null}catch{$preHelloFailure=$_}
        $reopenedPipe=New-RendererTargetObservationPipe "herdrops-v02-issue10-perf-$preHelloNonce-0"
        if($null-eq$preHelloFailure-or(Test-Path -LiteralPath $preHelloDest)){throw 'Actual pre-hello production failure did not fail closed with zero output.'}
        Pass-NegativeCase 'actual production pre-hello App failure releases its owned pipe through outer teardown'
    }finally{
        if($null-ne$reopenedPipe){$reopenedPipe.Dispose()}
        if($null-ne$coreProbe){try{if(-not$coreProbe.HasExited){$coreProbe.Kill();$coreProbe.WaitForExit(2000)|Out-Null}}catch{}finally{$coreProbe.Dispose()}}
    }

    # -------------------------------------------------------------------------
    # HOSTILE NEGATIVE TESTS (ALL MUST FAIL CLOSED WITH ZERO PUBLISHED OUTPUT)
    # -------------------------------------------------------------------------

    # 1. Removed switch: -ForceOverwrite is rejected
    $negForceDest = Join-Path $tempRoot 'matrix\neg-force.json'
    Assert-ThrowsMatchAndZeroOutput {
        & $script:InvokeSoakPath -Synthetic `
            -PowerSource 'AC' `
            -DestinationPath $negForceDest `
            -EvidenceRoot $tempRoot `
            -RepositoryRoot $repoRoot `
            -ForceOverwrite `
            -SyntheticPowerStateProvider { 'AC' } `
            -SyntheticProcessTelemetryProvider (Get-TestSampleProvider)
    } 'A parameter cannot be found that matches parameter name ''ForceOverwrite''' 'removed switch -ForceOverwrite is rejected by parameter binding' $negForceDest

    # 2. Removed switch: -AllowThresholdBreach is rejected
    $negAllowDest = Join-Path $tempRoot 'matrix\neg-allow.json'
    Assert-ThrowsMatchAndZeroOutput {
        & $script:InvokeSoakPath -Synthetic `
            -PowerSource 'AC' `
            -DestinationPath $negAllowDest `
            -EvidenceRoot $tempRoot `
            -RepositoryRoot $repoRoot `
            -AllowThresholdBreach `
            -SyntheticPowerStateProvider { 'AC' } `
            -SyntheticProcessTelemetryProvider (Get-TestSampleProvider)
    } 'A parameter cannot be found that matches parameter name ''AllowThresholdBreach''' 'removed switch -AllowThresholdBreach is rejected by parameter binding' $negAllowDest

    # 3. Removed switch: -TestOnlyLiveAcceleration is rejected
    $negAccelDest = Join-Path $tempRoot 'matrix\neg-accel.json'
    Assert-ThrowsMatchAndZeroOutput {
        & $script:InvokeSoakPath `
            -PowerSource 'AC' `
            -DestinationPath $negAccelDest `
            -EvidenceRoot $tempRoot `
            -RepositoryRoot $repoRoot `
            -TestOnlyLiveAcceleration
    } 'A parameter cannot be found that matches parameter name ''TestOnlyLiveAcceleration''' 'removed switch -TestOnlyLiveAcceleration is rejected by parameter binding' $negAccelDest

    # 4. Removed switch: -TestOnlyProcessIdentityProvider is rejected
    $negIdentProvDest = Join-Path $tempRoot 'matrix\neg-ident-prov.json'
    Assert-ThrowsMatchAndZeroOutput {
        & $script:InvokeSoakPath `
            -PowerSource 'AC' `
            -DestinationPath $negIdentProvDest `
            -EvidenceRoot $tempRoot `
            -RepositoryRoot $repoRoot `
            -TestOnlyProcessIdentityProvider { $null }
    } 'A parameter cannot be found that matches parameter name ''TestOnlyProcessIdentityProvider''' 'removed switch -TestOnlyProcessIdentityProvider is rejected by parameter binding' $negIdentProvDest

    # 5. Parameter dictionary check for removed switches
    $commandParams = (Get-Command $script:InvokeSoakPath).Parameters
    if ($commandParams.ContainsKey('ForceOverwrite') -or
        $commandParams.ContainsKey('AllowThresholdBreach') -or
        $commandParams.ContainsKey('TestOnlyLiveAcceleration') -or
        $commandParams.ContainsKey('TestOnlyProcessIdentityProvider') -or
        $commandParams.ContainsKey('TelemetryChannel') -or
        $commandParams.ContainsKey('AppProcessId')) {
        throw 'Public API parameter dictionary still contains removed test or bypass switches.'
    }
    Pass-NegativeCase 'public API parameter dictionary omits all test acceleration and bypass switches'

    # 6. Environment variable HERDROPS_V02_SOAK_SELFTEST=1 cannot unlock acceleration or bypass live duration
    $negEnvBypassDest = Join-Path $tempRoot 'matrix\neg-env-bypass.json'
    [Environment]::SetEnvironmentVariable('HERDROPS_V02_SOAK_SELFTEST', '1', 'Process')
    try {
        Assert-ThrowsMatchAndZeroOutput {
            & $script:InvokeSoakPath `
                -PowerSource 'AC' `
                -DestinationPath $negEnvBypassDest `
                -EvidenceRoot $tempRoot `
                -RepositoryRoot $repoRoot
        } 'exact candidate source bindings|exact candidate package bindings' 'HERDROPS_V02_SOAK_SELFTEST=1 cannot bypass live package binding requirements' $negEnvBypassDest
    } finally {
        [Environment]::SetEnvironmentVariable('HERDROPS_V02_SOAK_SELFTEST', $null, 'Process')
    }

    # 7. No-clobber protection refuses to overwrite preexisting destination file
    $preexistingDest = Join-Path $tempRoot 'matrix\preexisting.json'
    [IO.File]::WriteAllText($preexistingDest, 'preexisting-content', (New-Object Text.UTF8Encoding($false)))
    Assert-ThrowsMatch {
        & $script:InvokeSoakPath -Synthetic `
            -PowerSource 'AC' `
            -DestinationPath $preexistingDest `
            -EvidenceRoot $tempRoot `
            -RepositoryRoot $repoRoot `
            -SyntheticTotalBins 1 `
            -SyntheticSamplesPerBin 1 `
            -SyntheticPowerStateProvider { 'AC' } `
            -SyntheticProcessTelemetryProvider (Get-TestSampleProvider)
    } 'already exists; refusing to clobber' 'no-clobber protection refuses to overwrite preexisting destination file'
    if ([IO.File]::ReadAllText($preexistingDest) -cne 'preexisting-content') {
        throw "Preexisting destination file was mutated during no-clobber rejection."
    }

    # 8. Mid-publish crash during staging write rolls back cleanly
    $midWriteDest = Join-Path $tempRoot 'matrix\midwrite-dest.json'
    Assert-ThrowsMatchAndZeroOutput {
        & $script:InvokeSoakPath -Synthetic `
            -PowerSource 'AC' `
            -DestinationPath $midWriteDest `
            -EvidenceRoot $tempRoot `
            -RepositoryRoot $repoRoot `
            -TestFaultInjectionStage 'MidWrite' `
            -SyntheticTotalBins 1 `
            -SyntheticSamplesPerBin 1 `
            -SyntheticPowerStateProvider { 'AC' } `
            -SyntheticProcessTelemetryProvider (Get-TestSampleProvider)
    } 'Injected soak publication crash during staging write' 'mid-publish crash during staging write rolls back cleanly with zero published output' $midWriteDest

    # 9. Mid-publish crash before commit rolls back cleanly
    $beforeCommitDest = Join-Path $tempRoot 'matrix\beforecommit-dest.json'
    Assert-ThrowsMatchAndZeroOutput {
        & $script:InvokeSoakPath -Synthetic `
            -PowerSource 'AC' `
            -DestinationPath $beforeCommitDest `
            -EvidenceRoot $tempRoot `
            -RepositoryRoot $repoRoot `
            -TestFaultInjectionStage 'BeforeCommit' `
            -SyntheticTotalBins 1 `
            -SyntheticSamplesPerBin 1 `
            -SyntheticPowerStateProvider { 'AC' } `
            -SyntheticProcessTelemetryProvider (Get-TestSampleProvider)
    } 'Injected soak publication crash before atomic commit' 'mid-publish crash before commit rolls back cleanly with zero published output' $beforeCommitDest

    # 10. Initial power mismatch: AC requested, Battery observed
    $negPwr1Dest = Join-Path $tempRoot 'matrix\neg-pwr1.json'
    Assert-ThrowsMatchAndZeroOutput {
        & $script:InvokeSoakPath -Synthetic `
            -PowerSource 'AC' `
            -DestinationPath $negPwr1Dest `
            -EvidenceRoot $tempRoot `
            -RepositoryRoot $repoRoot `
            -SyntheticSamplesPerBin 1 `
            -SyntheticPowerStateProvider { 'Battery' } `
            -SyntheticProcessTelemetryProvider (Get-TestSampleProvider)
    } 'Initial power source mismatch' 'initial power source mismatch (AC requested, Battery observed) produces zero output' $negPwr1Dest

    # 11. Initial power mismatch: Battery requested, AC observed
    $negPwr2Dest = Join-Path $tempRoot 'matrix\neg-pwr2.json'
    Assert-ThrowsMatchAndZeroOutput {
        & $script:InvokeSoakPath -Synthetic `
            -PowerSource 'Battery' `
            -DestinationPath $negPwr2Dest `
            -EvidenceRoot $tempRoot `
            -RepositoryRoot $repoRoot `
            -SyntheticSamplesPerBin 1 `
            -SyntheticPowerStateProvider { 'AC' } `
            -SyntheticProcessTelemetryProvider (Get-TestSampleProvider)
    } 'Initial power source mismatch' 'initial power source mismatch (Battery requested, AC observed) produces zero output' $negPwr2Dest

    # 12. Mid-soak power interruption
    $pwrState = [pscustomobject]@{ count = 0 }
    $interruptProvider = {
        $pwrState.count++
        if ($pwrState.count -gt 2) { 'Battery' } else { 'AC' }
    }.GetNewClosure()

    $negPwrIntDest = Join-Path $tempRoot 'matrix\neg-pwr-int.json'
    Assert-ThrowsMatchAndZeroOutput {
        & $script:InvokeSoakPath -Synthetic `
            -PowerSource 'AC' `
            -DestinationPath $negPwrIntDest `
            -EvidenceRoot $tempRoot `
            -RepositoryRoot $repoRoot `
            -SyntheticTotalBins 2 `
            -SyntheticBinDurationMinutes 1 `
            -SyntheticSamplesPerBin 2 `
            -SyntheticPowerStateProvider $interruptProvider `
            -SyntheticProcessTelemetryProvider (Get-TestSampleProvider)
    } 'Power source changed' 'mid-soak power interruption from AC to Battery produces zero output' $negPwrIntDest

    # Exercise the exact production CurrentUserOnly soak pipe and PID continuity guards.
    $pipeNonce=[Guid]::NewGuid().ToString('N');$pipeName="herdrops-v02-issue10-perf-$pipeNonce-0";$pipe=New-RendererTargetObservationPipe $pipeName
    $clientScript=Join-Path $tempRoot 'soak-pipe-client.ps1';[IO.File]::WriteAllText($clientScript,@'
param([string]$Name)
$pipe=[IO.Pipes.NamedPipeClientStream]::new('.', $Name, [IO.Pipes.PipeDirection]::InOut, [IO.Pipes.PipeOptions]::None)
try{$pipe.Connect(10000);$writer=[IO.StreamWriter]::new($pipe,[Text.UTF8Encoding]::new($false),65536,$true);$writer.AutoFlush=$true;$writer.WriteLine('{"kind":"live-soak-pipe-probe"}');Start-Sleep -Milliseconds 500}finally{$pipe.Dispose()}
'@,(New-Object Text.UTF8Encoding($false)))
    $client=Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile','-File',$clientScript,$pipeName) -PassThru -WindowStyle Hidden;$reader=$null
    try{$actualClientPid=Wait-RendererTargetObservationPipe $pipe 15;Assert-RendererPipeClientProcessId $actualClientPid $client.Id 'Soak telemetry';$reader=[IO.StreamReader]::new($pipe,(New-Object Text.UTF8Encoding($false,$true)),$false,65536,$true);$line=Read-RendererTargetPipeLine $reader 10;if($line-cne'{"kind":"live-soak-pipe-probe"}'){throw 'Soak pipe probe payload changed.'};$client.Refresh();$clientPath=[IO.Path]::GetFullPath($client.MainModule.FileName);$identity=[pscustomobject][ordered]@{role='Soak pipe client';pid=[int]$client.Id;startTimeUtc=$client.StartTime.ToUniversalTime().ToString('O');executablePath=$clientPath;executableFinalPath=$clientPath;bytes=[long](Get-Item -LiteralPath $clientPath).Length;sha256=(Get-FileHash -LiteralPath $clientPath -Algorithm SHA256).Hash;processName=$client.ProcessName};Pass-PositiveCase 'real CurrentUserOnly soak pipe binds PID/start/path/hash and transports a frame';Assert-ThrowsMatch {Assert-RendererPipeClientProcessId $actualClientPid ($client.Id+1) 'Soak telemetry'} 'not connected by the launched packaged App PID' 'soak pipe rejects PID transplant';$recycled=Copy-RendererValue $identity;$recycled.startTimeUtc=[DateTimeOffset]::Parse($identity.startTimeUtc).AddSeconds(1).ToString('O');Assert-ThrowsMatch {Assert-RendererProcessIdentityEqual $recycled $identity 'Soak recycled client'} 'PID reuse or executable replacement' 'soak process identity rejects PID/start recycle'}finally{if($null-ne$reader){$reader.Dispose()};$pipe.Dispose();if(-not$client.HasExited){Stop-Process -Id $client.Id -Force};$client.Dispose()}

    # 21. Synthetic telemetry provider exception fails closed
    $negTelExDest = Join-Path $tempRoot 'matrix\neg-tel-ex.json'
    Assert-ThrowsMatchAndZeroOutput {
        & $script:InvokeSoakPath -Synthetic `
            -PowerSource 'AC' `
            -DestinationPath $negTelExDest `
            -EvidenceRoot $tempRoot `
            -RepositoryRoot $repoRoot `
            -SyntheticTotalBins 1 `
            -SyntheticSamplesPerBin 1 `
            -SyntheticPowerStateProvider { 'AC' } `
            -SyntheticProcessTelemetryProvider { throw 'Simulated telemetry failure' }
    } 'Synthetic telemetry provider threw an exception' 'synthetic telemetry provider exception fails closed with zero published output' $negTelExDest

    # 22. Null telemetry sample fails closed
    $negNullTelDest = Join-Path $tempRoot 'matrix\neg-null-tel.json'
    Assert-ThrowsMatchAndZeroOutput {
        & $script:InvokeSoakPath -Synthetic `
            -PowerSource 'AC' `
            -DestinationPath $negNullTelDest `
            -EvidenceRoot $tempRoot `
            -RepositoryRoot $repoRoot `
            -SyntheticTotalBins 1 `
            -SyntheticSamplesPerBin 1 `
            -SyntheticPowerStateProvider { 'AC' } `
            -SyntheticProcessTelemetryProvider { return $null }
    } 'returned null or invalid object' 'null telemetry sample fails closed with zero published output' $negNullTelDest

    # 23. Working set budget breach (> 255 MiB)
    $negWsDest = Join-Path $tempRoot 'matrix\neg-ws.json'
    Assert-ThrowsMatchAndZeroOutput {
        & $script:InvokeSoakPath -Synthetic `
            -PowerSource 'AC' `
            -DestinationPath $negWsDest `
            -EvidenceRoot $tempRoot `
            -RepositoryRoot $repoRoot `
            -SyntheticTotalBins 1 `
            -SyntheticBinDurationMinutes 1 `
            -SyntheticSamplesPerBin 2 `
            -SyntheticPowerStateProvider { 'AC' } `
            -SyntheticProcessTelemetryProvider (Get-TestSampleProvider -WsStartMb 260 -WsEndMb 260)
    } 'combined WS .* > limit' 'working set budget breach > 255 MiB produces zero published output' $negWsDest

    # 24. Working set slope breach (> 1 MiB / 10 min)
    $negSlopeDest = Join-Path $tempRoot 'matrix\neg-slope.json'
    Assert-ThrowsMatchAndZeroOutput {
        & $script:InvokeSoakPath -Synthetic `
            -PowerSource 'AC' `
            -DestinationPath $negSlopeDest `
            -EvidenceRoot $tempRoot `
            -RepositoryRoot $repoRoot `
            -SyntheticTotalBins 1 `
            -SyntheticBinDurationMinutes 5 `
            -SyntheticSamplesPerBin 2 `
            -SyntheticPowerStateProvider { 'AC' } `
            -SyntheticProcessTelemetryProvider (Get-TestSampleProvider -WsStartMb 100 -WsEndMb 102)
    } 'WS slope .* > limit' 'working set slope breach > 1 MiB / 10 min produces zero published output' $negSlopeDest

    # 25. CPU usage breach (> 1%)
    $negCpuDest = Join-Path $tempRoot 'matrix\neg-cpu.json'
    Assert-ThrowsMatchAndZeroOutput {
        & $script:InvokeSoakPath -Synthetic `
            -PowerSource 'AC' `
            -DestinationPath $negCpuDest `
            -EvidenceRoot $tempRoot `
            -RepositoryRoot $repoRoot `
            -SyntheticTotalBins 1 `
            -SyntheticBinDurationMinutes 1 `
            -SyntheticSamplesPerBin 2 `
            -SyntheticPowerStateProvider { 'AC' } `
            -SyntheticProcessTelemetryProvider (Get-TestSampleProvider -CpuBp 150)
    } 'combined CPU .* > limit' 'CPU usage breach > 1% produces zero published output' $negCpuDest

    # 26. Latency P95 breach (> 250 ms)
    $negLatDest = Join-Path $tempRoot 'matrix\neg-lat.json'
    Assert-ThrowsMatchAndZeroOutput {
        & $script:InvokeSoakPath -Synthetic `
            -PowerSource 'AC' `
            -DestinationPath $negLatDest `
            -EvidenceRoot $tempRoot `
            -RepositoryRoot $repoRoot `
            -SyntheticTotalBins 1 `
            -SyntheticBinDurationMinutes 1 `
            -SyntheticSamplesPerBin 2 `
            -SyntheticPowerStateProvider { 'AC' } `
            -SyntheticProcessTelemetryProvider (Get-TestSampleProvider -LatMs 300)
    } 'latency P95 .* > limit' 'latency P95 breach > 250 ms produces zero published output' $negLatDest

    $missingBinBase=Get-TestSampleProvider;$missingBinProvider={param($binIndex,$sampleIndex,$elapsedMs);$sample=&$missingBinBase $binIndex $sampleIndex $elapsedMs;if($binIndex-eq0){$sample.LatencyMicroseconds=@()};$sample}.GetNewClosure()
    $missingBinDest=Join-Path $tempRoot 'matrix\neg-latency-bin.json'
    Assert-ThrowsMatchAndZeroOutput {
        & $script:InvokeSoakPath -Synthetic -PowerSource 'AC' -DestinationPath $missingBinDest -EvidenceRoot $tempRoot -RepositoryRoot $repoRoot -SyntheticTotalBins 12 -SyntheticSamplesPerBin 1 -SyntheticPowerStateProvider {'AC'} -SyntheticProcessTelemetryProvider $missingBinProvider
    } 'Bin 0 did not observe a fresh production Widget latency update' 'missing five-minute latency coverage fails closed' $missingBinDest

    $fewUpdatesBase=Get-TestSampleProvider;$fewUpdatesProvider={param($binIndex,$sampleIndex,$elapsedMs);$sample=&$fewUpdatesBase $binIndex $sampleIndex $elapsedMs;$sample.LatencyMicroseconds=@(100000L);$sample}.GetNewClosure()
    $fewUpdatesDest=Join-Path $tempRoot 'matrix\neg-latency-count.json'
    Assert-ThrowsMatchAndZeroOutput {
        & $script:InvokeSoakPath -Synthetic -PowerSource 'AC' -DestinationPath $fewUpdatesDest -EvidenceRoot $tempRoot -RepositoryRoot $repoRoot -SyntheticTotalBins 12 -SyntheticSamplesPerBin 1 -SyntheticPowerStateProvider {'AC'} -SyntheticProcessTelemetryProvider $fewUpdatesProvider
    } 'requires at least 20 unique fresh production Widget updates' 'fewer than twenty unique run-level latency updates fails closed' $fewUpdatesDest

    # 27. UI Stall P95 breach (> 50 ms)
    $negStlDest = Join-Path $tempRoot 'matrix\neg-stl.json'
    Assert-ThrowsMatchAndZeroOutput {
        & $script:InvokeSoakPath -Synthetic `
            -PowerSource 'AC' `
            -DestinationPath $negStlDest `
            -EvidenceRoot $tempRoot `
            -RepositoryRoot $repoRoot `
            -SyntheticTotalBins 1 `
            -SyntheticBinDurationMinutes 1 `
            -SyntheticSamplesPerBin 2 `
            -SyntheticPowerStateProvider { 'AC' } `
            -SyntheticProcessTelemetryProvider (Get-TestSampleProvider -StlMs 60)
    } 'UI stall P95 .* > limit' 'UI stall P95 breach > 50 ms produces zero published output' $negStlDest

    # 28. UI Stall Maximum breach (> 100 ms)
    $negStlMaxDest = Join-Path $tempRoot 'matrix\neg-stlmax.json'
    Assert-ThrowsMatchAndZeroOutput {
        & $script:InvokeSoakPath -Synthetic `
            -PowerSource 'AC' `
            -DestinationPath $negStlMaxDest `
            -EvidenceRoot $tempRoot `
            -RepositoryRoot $repoRoot `
            -SyntheticTotalBins 1 `
            -SyntheticBinDurationMinutes 1 `
            -SyntheticSamplesPerBin 2 `
            -SyntheticPowerStateProvider { 'AC' } `
            -SyntheticProcessTelemetryProvider (Get-TestSampleProvider -StlMs 10 -StlMaxMs 120)
    } 'UI stall max .* > limit' 'UI stall maximum breach > 100 ms produces zero published output' $negStlMaxDest

    # 29. Renderer instability failure
    $negUnstableDest = Join-Path $tempRoot 'matrix\neg-unstable.json'
    Assert-ThrowsMatchAndZeroOutput {
        & $script:InvokeSoakPath -Synthetic `
            -PowerSource 'AC' `
            -DestinationPath $negUnstableDest `
            -EvidenceRoot $tempRoot `
            -RepositoryRoot $repoRoot `
            -SyntheticTotalBins 1 `
            -SyntheticBinDurationMinutes 1 `
            -SyntheticSamplesPerBin 2 `
            -SyntheticPowerStateProvider { 'AC' } `
            -SyntheticProcessTelemetryProvider (Get-TestSampleProvider -RendererStable $false)
    } 'renderer stability failure' 'renderer instability failure produces zero published output' $negUnstableDest

    # 30. Destination escaping evidence root
    $negEscapeDest = [IO.Path]::GetFullPath((Join-Path $tempRoot '..\escaped.json'))
    Assert-ThrowsMatchAndZeroOutput {
        & $script:InvokeSoakPath -Synthetic `
            -PowerSource 'AC' `
            -DestinationPath $negEscapeDest `
            -EvidenceRoot $tempRoot `
            -RepositoryRoot $repoRoot `
            -SyntheticSamplesPerBin 1 `
            -SyntheticPowerStateProvider { 'AC' } `
            -SyntheticProcessTelemetryProvider (Get-TestSampleProvider)
    } 'escaped the evidence root' 'destination path escaping evidence root produces zero output' $negEscapeDest

    # 31. Reparse point junction destination path
    $reparseDir = Join-Path $tempRoot 'junction-dest'
    $reparseTarget = Join-Path $tempRoot 'junction-target'
    New-Item -ItemType Directory -Path $reparseTarget -Force | Out-Null
    & cmd /c "mklink /J `"$reparseDir`" `"$reparseTarget`"" 2>&1 | Out-Null
    if (Test-Path -LiteralPath $reparseDir) {
        $negReparseDest = Join-Path $reparseDir 'receipt.json'
        Assert-ThrowsMatchAndZeroOutput {
            & $script:InvokeSoakPath -Synthetic `
                -PowerSource 'AC' `
                -DestinationPath $negReparseDest `
                -EvidenceRoot $tempRoot `
                -RepositoryRoot $repoRoot `
                -SyntheticSamplesPerBin 1 `
                -SyntheticPowerStateProvider { 'AC' } `
                -SyntheticProcessTelemetryProvider (Get-TestSampleProvider)
        } 'contains a reparse point|must not contain a reparse point' 'reparse junction destination path produces zero output' $negReparseDest
    }

    # 32. Source commit mismatch
    $negCommitDest = Join-Path $tempRoot 'matrix\neg-commit.json'
    Assert-ThrowsMatchAndZeroOutput {
        & $script:InvokeSoakPath -Synthetic `
            -PowerSource 'AC' `
            -DestinationPath $negCommitDest `
            -EvidenceRoot $tempRoot `
            -RepositoryRoot $repoRoot `
            -ExpectedSourceCommit '0000000000000000000000000000000000000000' `
            -SyntheticSamplesPerBin 1 `
            -SyntheticPowerStateProvider { 'AC' } `
            -SyntheticProcessTelemetryProvider (Get-TestSampleProvider)
    } 'Source commit mismatch' 'source commit mismatch produces zero output' $negCommitDest

    # 33. Source tree mismatch
    $negTreeDest = Join-Path $tempRoot 'matrix\neg-tree.json'
    Assert-ThrowsMatchAndZeroOutput {
        & $script:InvokeSoakPath -Synthetic `
            -PowerSource 'AC' `
            -DestinationPath $negTreeDest `
            -EvidenceRoot $tempRoot `
            -RepositoryRoot $repoRoot `
            -ExpectedSourceTree '0000000000000000000000000000000000000000' `
            -SyntheticSamplesPerBin 1 `
            -SyntheticPowerStateProvider { 'AC' } `
            -SyntheticProcessTelemetryProvider (Get-TestSampleProvider)
    } 'Source tree mismatch' 'source tree mismatch produces zero output' $negTreeDest

    # 34. Package component hash mismatch fails closed with zero output
    $negPkgTamperDest = Join-Path $tempRoot 'matrix\neg-pkg-tamper.json'
    $tamperedAppPath = Join-Path $packageRoot 'HerdrOps.App.exe'
    [IO.File]::WriteAllBytes($tamperedAppPath, [Text.Encoding]::UTF8.GetBytes('tampered-binary'))
    Assert-ThrowsMatchAndZeroOutput {
        & $script:InvokeSoakPath -Synthetic `
            -PowerSource 'AC' `
            -DestinationPath $negPkgTamperDest `
            -EvidenceRoot $tempRoot `
            -RepositoryRoot $repoRoot `
            -PackageIdentityPath $receiptPath `
            -PackageArchivePath $archivePath `
            -ExtractedPackageRoot $packageRoot `
            -SyntheticTotalBins 1 `
            -SyntheticSamplesPerBin 1 `
            -SyntheticPowerStateProvider { 'AC' } `
            -SyntheticProcessTelemetryProvider (Get-TestSampleProvider)
    } 'Manifest/package-root inventories are not exact and coherent|Package App/Core bytes changed after package validation|hash.*mismatch' 'package component hash mismatch fails closed with zero output' $negPkgTamperDest
    # Restore app binary
    [IO.File]::WriteAllBytes($tamperedAppPath, [Text.Encoding]::UTF8.GetBytes('app-binary'))

    # 35. Incomplete package binding arguments in synthetic mode
    $negIncompletePkgDest = Join-Path $tempRoot 'matrix\neg-pkg-incomplete.json'
    Assert-ThrowsMatchAndZeroOutput {
        & $script:InvokeSoakPath -Synthetic `
            -PowerSource 'AC' `
            -DestinationPath $negIncompletePkgDest `
            -EvidenceRoot $tempRoot `
            -RepositoryRoot $repoRoot `
            -PackageIdentityPath $receiptPath `
            -SyntheticTotalBins 1 `
            -SyntheticSamplesPerBin 1 `
            -SyntheticPowerStateProvider { 'AC' } `
            -SyntheticProcessTelemetryProvider (Get-TestSampleProvider)
    } 'PackageIdentityPath, PackageArchivePath, and ExtractedPackageRoot must all be provided' 'missing one of package binding parameters fails closed' $negIncompletePkgDest

    # 36. Evidence classification invariant: synthetic mode cannot grant PackagedCompatibilitySoak
    $negEvClassDest = Join-Path $tempRoot 'matrix\neg-ev-class.json'
    $synRes = & $script:InvokeSoakPath -Synthetic `
        -PowerSource 'AC' `
        -DestinationPath $negEvClassDest `
        -EvidenceRoot $tempRoot `
        -RepositoryRoot $repoRoot `
        -SyntheticTotalBins 1 `
        -SyntheticBinDurationMinutes 1 `
        -SyntheticSamplesPerBin 1 `
        -SyntheticPowerStateProvider { 'AC' } `
        -SyntheticProcessTelemetryProvider (Get-TestSampleProvider)

    if ($synRes.EvidenceClassification -ne 'SyntheticVerifierSelftest' -or
        $synRes.ReceiptDocument.evidenceClassification -ne 'SyntheticVerifierSelftest' -or
        $synRes.ReceiptDocument.evidenceBoundary.evidenceClass -ne 'SyntheticVerifierSelftest') {
        throw 'Synthetic soak execution leaked PackagedCompatibilitySoak or invalid evidence classification.'
    }
    Pass-NegativeCase 'synthetic soak execution strictly emits SyntheticVerifierSelftest and cannot grant PackagedCompatibilitySoak'

    Write-Host ""
    [pscustomobject][ordered]@{
        EvidenceClassification = 'SyntheticVerifierSelftest'
        PositiveCases = $script:positiveCases
        NegativeCases = $script:negativeCases
        Status = 'PASS'
    } | Format-Table
} finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
