#requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\RendererCompatibility.Common.ps1')

function Get-OwnedProcessStartTimeUtc {
    param([Parameter(Mandatory = $true)]$Process)
    try {
        if ($Process -is [int]) {
            $p = [System.Diagnostics.Process]::GetProcessById($Process)
            return $p.StartTime.ToUniversalTime()
        } elseif ($Process -is [System.Diagnostics.Process]) {
            return $Process.StartTime.ToUniversalTime()
        } else {
            throw "Invalid process object type: $($Process.GetType().FullName)"
        }
    } catch {
        throw "Unable to obtain start time for process: $($_.Exception.Message)"
    }
}

function Stop-OwnedProcessSafely {
    param(
        [Parameter(Mandatory = $false)]$Process,
        [Parameter(Mandatory = $false)][DateTime]$ExpectedStartTimeUtc
    )
    if ($null -eq $Process) { return }
    try {
        $p = if ($Process -is [int]) { [System.Diagnostics.Process]::GetProcessById($Process) } else { $Process }
        if ($null -ne $p -and -not $p.HasExited) {
            if ($ExpectedStartTimeUtc -ne [DateTime]::MinValue) {
                if ($p.StartTime.ToUniversalTime() -eq $ExpectedStartTimeUtc) {
                    $p.Kill()
                }
            } else {
                $p.Kill()
            }
        }
    } catch {
        # Process already exited
    }
}

function Invoke-V02LivePerformanceGuardProbe {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('UnexpectedExit', 'PidStartContinuity', 'ForgedRendererMode', 'StaleTimestamp')]
        [string]$GuardMode,
        [Parameter(Mandatory = $true)][string]$TempRoot
    )

    $collectorScript = Join-Path $PSScriptRoot '..\Invoke-V02PerformanceMeasurement.ps1'
    $repoRoot = Join-Path $TempRoot 'repo'
    $probeId = [Guid]::NewGuid().ToString('N')
    $packageDir = Join-Path $TempRoot "live-pkg-probe-$probeId"
    $archiveDir = Join-Path $TempRoot "live-archive-probe-$probeId"
    New-Item -ItemType Directory -Path $packageDir, $archiveDir -Force | Out-Null

    $childExe = Join-Path ([Environment]::GetEnvironmentVariable('SystemRoot')) 'System32\ping.exe'
    $appPath = Join-Path $packageDir 'HerdrOps.App.exe'
    $corePath = Join-Path $packageDir 'HerdrOps.Core.exe'
    Copy-Item -LiteralPath $childExe -Destination $appPath -Force
    Copy-Item -LiteralPath $childExe -Destination $corePath -Force

    $profilePath = Join-Path $repoRoot 'tools\packaging\v0.2\package-identity-profile.json'
    $profileValue = Read-RendererPackageProfile $profilePath
    $profileIdentity = Get-RendererPackageProfileIdentity $profilePath $profileValue $repoRoot

    $manifestObj = New-RendererPackageManifest $profileValue $repoRoot $packageDir
    $manifestPath = Join-Path $packageDir 'package-manifest.json'
    Write-RendererPackageCanonicalJson $manifestObj $manifestPath $repoRoot
    $manifestStable = Get-RendererPackageStableIdentity $manifestPath

    $archivePath = Join-Path $archiveDir 'HerdrOps-0.2.0-win-x64.zip'
    $null = New-RendererDeterministicPackageArchive $packageDir $archivePath
    $archiveStable = Get-RendererPackageStableIdentity $archivePath
    $appStable = Get-RendererPackageStableIdentity $appPath
    $coreStable = Get-RendererPackageStableIdentity $corePath

    $repoCommit = (& git -C $repoRoot rev-parse HEAD).Trim()
    $repoTree = (& git -C $repoRoot rev-parse 'HEAD^{tree}').Trim()

    $receiptValue = [pscustomobject][ordered]@{
        schemaVersion = 1
        profileId = $script:RendererPackageProfileId
        issue = 149
        packageVersion = '0.2.0'
        runtimeIdentifier = 'win-x64'
        source = [pscustomobject][ordered]@{ commitSha = $repoCommit; treeSha = $repoTree }
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
    $receiptPath = Join-Path $TempRoot 'package-identity-receipt-probe.json'
    Write-RendererPackageCanonicalJson $receiptValue $receiptPath $repoRoot

    # Create dummy soak evidence file with 24 bins
    $soakBins = @()
    foreach ($power in @('AC', 'Battery')) {
        for ($i = 0; $i -lt 12; $i++) {
            $offset = if ($power -ceq 'Battery') { 12 } else { 0 }
            $soakBins += [pscustomobject][ordered]@{
                powerSource = $power
                ordinal = $i
                durationMinutes = 5
                observedUtc = ('2026-08-22T12:{0:00}:00.0000000Z' -f ($i + 1 + $offset))
                workingSetStartBytes = 104857600
                workingSetEndBytes = 104857600
                rendererStable = $true
            }
        }
    }
    $soakEvidencePath = Join-Path $TempRoot 'soak-evidence-probe.json'
    $soakObj = [pscustomobject][ordered]@{ soakBins = $soakBins }
    Write-RendererPackageCanonicalJson $soakObj $soakEvidencePath $repoRoot

    $appProc = $null
    $coreProc = $null
    $appStart = [DateTime]::MinValue
    $coreStart = [DateTime]::MinValue
    $destPath = Join-Path $TempRoot "probe-$GuardMode-out.json"

    try {
        $appProc = Start-Process -FilePath $appPath -ArgumentList @('127.0.0.1', '-n', '120') -PassThru -WindowStyle Hidden
        $coreProc = Start-Process -FilePath $corePath -ArgumentList @('127.0.0.1', '-n', '120') -PassThru -WindowStyle Hidden
        $appStart = Get-OwnedProcessStartTimeUtc $appProc
        $coreStart = Get-OwnedProcessStartTimeUtc $coreProc
        Start-Sleep -Milliseconds 200

        $probeState = [pscustomobject]@{
            SampleCount = 0
            BaseTime = (Get-Date).ToUniversalTime()
        }

        $telemetryProvider = {
            param($orderName, $isWarmup, $repIndex, $modeName)
            $probeState.SampleCount++

            if ($GuardMode -eq 'UnexpectedExit' -and $probeState.SampleCount -ge 2) {
                Stop-OwnedProcessSafely $appProc $appStart
                Start-Sleep -Milliseconds 100
            }

            $appStartReport = $appStart
            if ($GuardMode -eq 'PidStartContinuity' -and $probeState.SampleCount -ge 2) {
                $appStartReport = $appStart.AddSeconds(2)
            }

            $rendererReport = if ($modeName -eq 'a') { 'Hardware' } else { 'SoftwareOnly' }
            if ($GuardMode -eq 'ForgedRendererMode' -and $probeState.SampleCount -ge 2) {
                $rendererReport = 'Hardware' # Mode B forging Hardware
            }

            $obsTime = $probeState.BaseTime.AddSeconds($probeState.SampleCount)
            if ($GuardMode -eq 'StaleTimestamp' -and $probeState.SampleCount -ge 2) {
                $obsTime = $probeState.BaseTime.AddSeconds(-10) # Stale timestamp in past
            }

            [pscustomobject][ordered]@{
                Authenticated = $true
                Source = 'ProbeLiveHarness'
                AppProcessId = $appProc.Id
                CoreProcessId = $coreProc.Id
                AppStartTimeUtc = $appStartReport
                CoreStartTimeUtc = $coreStart
                ObservedUtc = $obsTime.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')
                RendererMode = $rendererReport
                CpuBasisPoints = 50
                WorkingSetMaximumBytes = 104857600
                LatencyMicroseconds = @(1..20 | ForEach-Object { 100000L })
                UiStallMicroseconds = @(1..20 | ForEach-Object { 10000L })
            }
        }.GetNewClosure()

        & $collectorScript `
            -DestinationPath $destPath `
            -EvidenceRoot $TempRoot `
            -RepositoryRoot $repoRoot `
            -PackageIdentityPath $receiptPath `
            -PackageArchivePath $archivePath `
            -ExtractedPackageRoot $packageDir `
            -ExpectedSourceCommit $repoCommit `
            -ExpectedSourceTree $repoTree `
            -AppProcessId $appProc.Id `
            -CoreProcessId $coreProc.Id `
            -LiveTelemetryProvider $telemetryProvider `
            -SoakEvidencePath $soakEvidencePath
    } finally {
        Stop-OwnedProcessSafely $appProc $appStart
        Stop-OwnedProcessSafely $coreProc $coreStart
        if (Test-Path -LiteralPath $destPath) {
            Remove-Item -LiteralPath $destPath -Force -ErrorAction SilentlyContinue
        }
    }
}
