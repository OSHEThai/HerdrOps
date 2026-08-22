#requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'RendererCompatibility.Common.ps1')
. (Join-Path $PSScriptRoot 'lib\V02PerformanceTestHarness.ps1')
$script:InvokePerfPath = Join-Path $PSScriptRoot 'Invoke-V02PerformanceMeasurement.ps1'
$script:NewReceiptPath = Join-Path $PSScriptRoot 'New-V02PerformanceEvidenceReceipt.ps1'

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
            throw "Hostile negative test leaked published raw observations at target destination '$TargetDest': $CaseName"
        }
        $parent = Split-Path -Parent $TargetDest
        if (Test-Path -LiteralPath $parent) {
            $orphans = @(Get-ChildItem -LiteralPath $parent -Filter '*.raw-perf-stage*' -Force)
            if ($orphans.Count -gt 0) {
                throw "Hostile negative test leaked staging directory in parent: $CaseName"
            }
        }
    }
    Pass-NegativeCase $CaseName
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

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("herdrops-perf-selftest-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    $repo = New-TestRepository (Join-Path $tempRoot 'repo')
    $repoRoot = $repo.Root

    # -------------------------------------------------------------------------
    # POSITIVE TESTS
    # -------------------------------------------------------------------------

    # 1. Valid synthetic raw performance observations generation in AB then BA order
    $rawDest = Join-Path $tempRoot 'perf\raw-performance-observations.json'
    $perfRes = & $script:InvokePerfPath -Synthetic `
        -DestinationPath $rawDest `
        -EvidenceRoot $tempRoot `
        -RepositoryRoot $repoRoot

    if ($perfRes.EvidenceClassification -ne 'SyntheticVerifierSelftest' -or
        $perfRes.Orders.Count -ne 2 -or
        $perfRes.Orders[0].order -ne 'AB' -or
        $perfRes.Orders[1].order -ne 'BA' -or
        $perfRes.SoakBins.Count -ne 24) {
        throw "Synthetic raw performance collector failed basic assertions."
    }
    Pass-PositiveCase 'valid synthetic raw performance observations generation in AB then BA order'

    # 2. Canonical JCS JSON File Verification without BOM ending with LF
    $rawBytes = [IO.File]::ReadAllBytes($rawDest)
    if ($rawBytes[0] -eq 0xEF -and $rawBytes[1] -eq 0xBB -and $rawBytes[2] -eq 0xBF) {
        throw "Emitted raw performance observations contain forbidden UTF-8 BOM."
    }
    if ($rawBytes[-1] -ne 0x0A) {
        throw "Emitted raw performance observations must end with exactly one newline."
    }
    Pass-PositiveCase 'emitted raw observations is valid canonical JCS without BOM ending with LF'

    # 3. Each mode sample contains at least 20 latency and 20 UI-stall observations
    foreach ($ord in $perfRes.Orders) {
        $allReps = @($ord.warmup) + @($ord.repetitions)
        foreach ($rep in $allReps) {
            foreach ($modeKey in @('a', 'b')) {
                $sample = $rep.$modeKey
                if (@($sample.latencyMicroseconds).Count -ne 20 -or @($sample.uiStallMicroseconds).Count -ne 20) {
                    throw "Sample does not contain exactly 20 latency and UI stall observations."
                }
            }
        }
    }
    Pass-PositiveCase 'each mode sample contains exactly 20 latency and 20 UI-stall observations'

    # 4. Soak bins preserved (12 AC then 12 Battery, 5-minute duration)
    for ($bi = 0; $bi -lt 24; $bi++) {
        $bin = $perfRes.SoakBins[$bi]
        $expectedPower = if ($bi -lt 12) { 'AC' } else { 'Battery' }
        $expectedOrdinal = $bi % 12
        if ($bin.powerSource -ne $expectedPower -or $bin.ordinal -ne $expectedOrdinal -or $bin.durationMinutes -ne 5 -or -not $bin.rendererStable) {
            throw "Soak bin $bi does not meet contract."
        }
    }
    Pass-PositiveCase 'soak bins preserved (12 AC then 12 Battery, 5-minute duration)'

    # 5. Direct compatibility with New-V02PerformanceEvidenceReceipt.ps1
    # Create package identity receipt fixture to supply candidate provenance
    $packageRoot = Join-Path $tempRoot 'package'
    $archiveDir = Join-Path $tempRoot 'archive'
    New-Item -ItemType Directory -Path $packageRoot, $archiveDir -Force | Out-Null
    $appPath = Join-Path $packageRoot 'HerdrOps.App.exe'
    $corePath = Join-Path $packageRoot 'HerdrOps.Core.exe'
    [IO.File]::WriteAllBytes($appPath, [Text.Encoding]::UTF8.GetBytes('app-binary'))
    [IO.File]::WriteAllBytes($corePath, [Text.Encoding]::UTF8.GetBytes('core-binary'))
    $profilePath = Join-Path $repoRoot 'tools\packaging\v0.2\package-identity-profile.json'
    $profileValue = Read-RendererPackageProfile $profilePath
    $manifestObj = New-RendererPackageManifest $profileValue $repoRoot $packageRoot
    $manifestPath = Join-Path $packageRoot 'package-manifest.json'
    Write-RendererPackageCanonicalJson $manifestObj $manifestPath $repoRoot
    $manifestStable = Get-RendererPackageStableIdentity $manifestPath
    $archivePath = Join-Path $archiveDir 'HerdrOps-0.2.0-win-x64.zip'
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
    $receiptStable = Get-RendererPackageStableIdentity $receiptPath

    $candidateProvenance = [pscustomobject][ordered]@{
        candidate = [pscustomobject][ordered]@{ commitSha = $repo.Commit; treeSha = $repo.Tree }
        package = [pscustomobject][ordered]@{
            profileId = $script:RendererPackageProfileId
            receipt = [pscustomobject][ordered]@{ relativePath = 'package-identity-receipt.json'; bytes = $receiptStable.Length; fileSha256 = $receiptStable.Sha256; canonicalSha256 = $receiptStable.Sha256 }
            archive = [pscustomobject][ordered]@{ relativePath = 'archive/HerdrOps-0.2.0-win-x64.zip'; fileName = 'HerdrOps-0.2.0-win-x64.zip'; bytes = $archiveStable.Length; sha256 = $archiveStable.Sha256 }
            packageRootRelativePath = 'package'
            components = [pscustomobject][ordered]@{
                app = [pscustomobject][ordered]@{ relativePath = 'package/HerdrOps.App.exe'; bytes = $appStable.Length; sha256 = $appStable.Sha256 }
                core = [pscustomobject][ordered]@{ relativePath = 'package/HerdrOps.Core.exe'; bytes = $coreStable.Length; sha256 = $coreStable.Sha256 }
            }
        }
        profile = [pscustomobject][ordered]@{ id = $profileIdentity.Id; relativePath = $profileIdentity.RelativePath; bytes = $profileIdentity.Bytes; fileSha256 = $profileIdentity.FileSha256; canonicalSha256 = $profileIdentity.CanonicalSha256 }
        referenceHost = [pscustomobject][ordered]@{ profileId = $script:RendererProfileId; profileSha256 = $script:RendererProfileSha256 }
        renderer = [pscustomobject][ordered]@{ policy = 'software-only-process-wide'; wpfProcessRenderMode = 'SoftwareOnly'; policySha256 = $script:RendererPolicySha256 }
        session = [pscustomobject][ordered]@{
            kind = 'LocalConsole'
            name = 'FixtureConsole'
            sessionId = 1L
            transport = 'SyntheticFixture'
            powerSource = 'AC'
            thermalState = 'Nominal'
            elevated = $false
            userScope = 'SingleUser'
        }
    }

    $receiptDestDir = Join-Path $tempRoot 'perf-receipt-out'
    $receiptRes = & $script:NewReceiptPath `
        -RawObservations $rawDest `
        -RawSourcePath $rawDest `
        -DestinationDirectory $receiptDestDir `
        -CandidateProvenance $candidateProvenance `
        -EvidenceRoot $tempRoot `
        -RepositoryRoot $repoRoot

    if ($receiptRes.AggregateStatus -ne 'PASS' -or -not (Test-Path -LiteralPath $receiptRes.ReceiptPath)) {
        throw "New-V02PerformanceEvidenceReceipt failed to consume collector raw observations."
    }
    Pass-PositiveCase 'raw performance observations are directly consumed by New-V02PerformanceEvidenceReceipt.ps1'

    # 6. Evidence boundary verification
    if ($perfRes.EvidenceClassification -ne 'SyntheticVerifierSelftest') {
        throw "Evidence classification was not SyntheticVerifierSelftest."
    }
    Pass-PositiveCase 'evidence boundary explicitly classifies SyntheticVerifierSelftest'

    # -------------------------------------------------------------------------
    # HOSTILE NEGATIVE TESTS (ALL MUST FAIL CLOSED WITH ZERO PUBLISHED OUTPUT)
    # -------------------------------------------------------------------------

    # 1. Removed switch -ForceOverwrite
    $negForceDest = Join-Path $tempRoot 'perf\neg-force.json'
    Assert-ThrowsMatchAndZeroOutput {
        & $script:InvokePerfPath -Synthetic `
            -DestinationPath $negForceDest `
            -EvidenceRoot $tempRoot `
            -RepositoryRoot $repoRoot `
            -ForceOverwrite
    } 'A parameter cannot be found that matches parameter name ''ForceOverwrite''' 'removed switch -ForceOverwrite is rejected by parameter binding' $negForceDest

    # 2. Removed switch -AllowThresholdBreach
    $negAllowDest = Join-Path $tempRoot 'perf\neg-allow.json'
    Assert-ThrowsMatchAndZeroOutput {
        & $script:InvokePerfPath -Synthetic `
            -DestinationPath $negAllowDest `
            -EvidenceRoot $tempRoot `
            -RepositoryRoot $repoRoot `
            -AllowThresholdBreach
    } 'A parameter cannot be found that matches parameter name ''AllowThresholdBreach''' 'removed switch -AllowThresholdBreach is rejected by parameter binding' $negAllowDest

    # 3. Removed switch -TestOnlyLiveAcceleration
    $negAccelDest = Join-Path $tempRoot 'perf\neg-accel.json'
    Assert-ThrowsMatchAndZeroOutput {
        & $script:InvokePerfPath `
            -DestinationPath $negAccelDest `
            -EvidenceRoot $tempRoot `
            -RepositoryRoot $repoRoot `
            -TestOnlyLiveAcceleration
    } 'A parameter cannot be found that matches parameter name ''TestOnlyLiveAcceleration''' 'removed switch -TestOnlyLiveAcceleration is rejected by parameter binding' $negAccelDest

    # 4. Removed switch -TestOnlyProcessIdentityProvider
    $negIdentProvDest = Join-Path $tempRoot 'perf\neg-ident-prov.json'
    Assert-ThrowsMatchAndZeroOutput {
        & $script:InvokePerfPath `
            -DestinationPath $negIdentProvDest `
            -EvidenceRoot $tempRoot `
            -RepositoryRoot $repoRoot `
            -TestOnlyProcessIdentityProvider { $null }
    } 'A parameter cannot be found that matches parameter name ''TestOnlyProcessIdentityProvider''' 'removed switch -TestOnlyProcessIdentityProvider is rejected by parameter binding' $negIdentProvDest

    # 5. Public API parameter dictionary omits all test acceleration and bypass switches
    $commandParams = (Get-Command $script:InvokePerfPath).Parameters
    if ($commandParams.ContainsKey('ForceOverwrite') -or
        $commandParams.ContainsKey('AllowThresholdBreach') -or
        $commandParams.ContainsKey('TestOnlyLiveAcceleration') -or
        $commandParams.ContainsKey('TestOnlyProcessIdentityProvider')) {
        throw 'Public API parameter dictionary still contains removed test or bypass switches.'
    }
    Pass-NegativeCase 'public API parameter dictionary omits all test acceleration and bypass switches'

    # 6. Environment variable bypass resistance
    $negEnvBypassDest = Join-Path $tempRoot 'perf\neg-env-bypass.json'
    [Environment]::SetEnvironmentVariable('HERDROPS_V02_PERF_SELFTEST', '1', 'Process')
    try {
        Assert-ThrowsMatchAndZeroOutput {
            & $script:InvokePerfPath `
                -DestinationPath $negEnvBypassDest `
                -EvidenceRoot $tempRoot `
                -RepositoryRoot $repoRoot `
                -AppProcessId 123 `
                -CoreProcessId 456
        } 'exact candidate source bindings|exact candidate package bindings' 'HERDROPS_V02_PERF_SELFTEST=1 cannot bypass live package binding requirements' $negEnvBypassDest
    } finally {
        [Environment]::SetEnvironmentVariable('HERDROPS_V02_PERF_SELFTEST', $null, 'Process')
    }

    # 7. Synthetic provider returning too few latency observations (< 20)
    $negTooFewLatDest = Join-Path $tempRoot 'perf\neg-few-lat.json'
    Assert-ThrowsMatchAndZeroOutput {
        & $script:InvokePerfPath -Synthetic `
            -DestinationPath $negTooFewLatDest `
            -EvidenceRoot $tempRoot `
            -RepositoryRoot $repoRoot `
            -SyntheticTelemetryProvider {
                param($o, $w, $r, $m)
                [pscustomobject][ordered]@{
                    cpuBasisPoints = 50
                    workingSetMaximumBytes = 104857600
                    latencyMicroseconds = @(1..19 | ForEach-Object { 100000L }) # 19 instead of 20
                    uiStallMicroseconds = @(1..20 | ForEach-Object { 10000L })
                }
            }
    } 'requires at least 20 latency observations' 'too few latency observations (<20) fails closed with zero output' $negTooFewLatDest

    # 8. Synthetic provider returning too few UI-stall observations (< 20)
    $negTooFewStlDest = Join-Path $tempRoot 'perf\neg-few-stl.json'
    Assert-ThrowsMatchAndZeroOutput {
        & $script:InvokePerfPath -Synthetic `
            -DestinationPath $negTooFewStlDest `
            -EvidenceRoot $tempRoot `
            -RepositoryRoot $repoRoot `
            -SyntheticTelemetryProvider {
                param($o, $w, $r, $m)
                [pscustomobject][ordered]@{
                    cpuBasisPoints = 50
                    workingSetMaximumBytes = 104857600
                    latencyMicroseconds = @(1..20 | ForEach-Object { 100000L })
                    uiStallMicroseconds = @(1..19 | ForEach-Object { 10000L }) # 19 instead of 20
                }
            }
    } 'requires at least 20 UI-stall observations' 'too few UI-stall observations (<20) fails closed with zero output' $negTooFewStlDest

    # 9. No-clobber protection refuses to overwrite preexisting destination file
    $preexistingDest = Join-Path $tempRoot 'perf\preexisting.json'
    [IO.File]::WriteAllText($preexistingDest, 'preexisting-content', (New-Object Text.UTF8Encoding($false)))
    Assert-ThrowsMatch {
        & $script:InvokePerfPath -Synthetic `
            -DestinationPath $preexistingDest `
            -EvidenceRoot $tempRoot `
            -RepositoryRoot $repoRoot
    } 'already exists; refusing to clobber' 'no-clobber protection refuses to overwrite preexisting destination file'
    if ([IO.File]::ReadAllText($preexistingDest) -cne 'preexisting-content') {
        throw "Preexisting destination file was mutated during no-clobber rejection."
    }

    # 10. Mid-publish crash during staging write rolls back cleanly
    $midWriteDest = Join-Path $tempRoot 'perf\midwrite-dest.json'
    Assert-ThrowsMatchAndZeroOutput {
        & $script:InvokePerfPath -Synthetic `
            -DestinationPath $midWriteDest `
            -EvidenceRoot $tempRoot `
            -RepositoryRoot $repoRoot `
            -TestFaultInjectionStage 'MidWrite'
    } 'Injected performance collector crash during staging write' 'mid-publish crash during staging write rolls back cleanly with zero published output' $midWriteDest

    # 11. Mid-publish crash before commit rolls back cleanly
    $beforeCommitDest = Join-Path $tempRoot 'perf\beforecommit-dest.json'
    Assert-ThrowsMatchAndZeroOutput {
        & $script:InvokePerfPath -Synthetic `
            -DestinationPath $beforeCommitDest `
            -EvidenceRoot $tempRoot `
            -RepositoryRoot $repoRoot `
            -TestFaultInjectionStage 'BeforeCommit'
    } 'Injected performance collector crash before atomic commit' 'mid-publish crash before commit rolls back cleanly with zero published output' $beforeCommitDest

    # Create dummy soak evidence file with 24 bins for live tests
    $soakBinsFixture = @()
    foreach ($power in @('AC', 'Battery')) {
        for ($i = 0; $i -lt 12; $i++) {
            $offset = if ($power -ceq 'Battery') { 12 } else { 0 }
            $soakBinsFixture += [pscustomobject][ordered]@{
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
    $soakFixturePath = Join-Path $tempRoot 'soak-fixture.json'
    $soakObj = [pscustomobject][ordered]@{ soakBins = $soakBinsFixture }
    Write-RendererPackageCanonicalJson $soakObj $soakFixturePath $repoRoot

    # 12. Live mode invalid process IDs (zero or negative)
    $negProc1Dest = Join-Path $tempRoot 'perf\neg-proc1.json'
    Assert-ThrowsMatchAndZeroOutput {
        & $script:InvokePerfPath `
            -DestinationPath $negProc1Dest `
            -EvidenceRoot $tempRoot `
            -RepositoryRoot $repoRoot `
            -PackageIdentityPath $receiptPath `
            -PackageArchivePath $archivePath `
            -ExtractedPackageRoot $packageRoot `
            -ExpectedSourceCommit $repo.Commit `
            -ExpectedSourceTree $repo.Tree `
            -LiveTelemetryProvider { $null } `
            -AppProcessId 0 `
            -CoreProcessId 0 `
            -SoakEvidencePath $soakFixturePath
    } 'Live performance measurement requires positive AppProcessId and CoreProcessId' 'live mode invalid process IDs produces zero output' $negProc1Dest

    # 13. Live mode identical process IDs
    $negProcIdentDest = Join-Path $tempRoot 'perf\neg-proc-ident.json'
    Assert-ThrowsMatchAndZeroOutput {
        & $script:InvokePerfPath `
            -DestinationPath $negProcIdentDest `
            -EvidenceRoot $tempRoot `
            -RepositoryRoot $repoRoot `
            -PackageIdentityPath $receiptPath `
            -PackageArchivePath $archivePath `
            -ExtractedPackageRoot $packageRoot `
            -ExpectedSourceCommit $repo.Commit `
            -ExpectedSourceTree $repo.Tree `
            -LiveTelemetryProvider { $null } `
            -AppProcessId 1234 `
            -CoreProcessId 1234 `
            -SoakEvidencePath $soakFixturePath
    } 'AppProcessId and CoreProcessId must be distinct processes' 'live mode identical process IDs for App and Core produces zero output' $negProcIdentDest

    # 14. Live mode non-existent process ID
    $negProc2Dest = Join-Path $tempRoot 'perf\neg-proc2.json'
    Assert-ThrowsMatchAndZeroOutput {
        & $script:InvokePerfPath `
            -DestinationPath $negProc2Dest `
            -EvidenceRoot $tempRoot `
            -RepositoryRoot $repoRoot `
            -PackageIdentityPath $receiptPath `
            -PackageArchivePath $archivePath `
            -ExtractedPackageRoot $packageRoot `
            -ExpectedSourceCommit $repo.Commit `
            -ExpectedSourceTree $repo.Tree `
            -LiveTelemetryProvider { $null } `
            -AppProcessId 999999 `
            -CoreProcessId 999998 `
            -SoakEvidencePath $soakFixturePath
    } 'Unable to connect to target App process' 'live mode non-existent process ID produces zero output' $negProc2Dest

    # 15. Live mode missing soak evidence file fails closed
    $negNoSoakDest = Join-Path $tempRoot 'perf\neg-nosoak.json'
    Assert-ThrowsMatchAndZeroOutput {
        & $script:InvokePerfPath `
            -DestinationPath $negNoSoakDest `
            -EvidenceRoot $tempRoot `
            -RepositoryRoot $repoRoot `
            -PackageIdentityPath $receiptPath `
            -PackageArchivePath $archivePath `
            -ExtractedPackageRoot $packageRoot `
            -ExpectedSourceCommit $repo.Commit `
            -ExpectedSourceTree $repo.Tree `
            -LiveTelemetryProvider { $null } `
            -AppProcessId 123 `
            -CoreProcessId 456
    } 'Live performance measurement requires separate validated soak evidence' 'live mode missing soak evidence parameter fails closed' $negNoSoakDest

    # 16. Destination escaping evidence root
    $negEscapeDest = [IO.Path]::GetFullPath((Join-Path $tempRoot '..\escaped-perf.json'))
    Assert-ThrowsMatchAndZeroOutput {
        & $script:InvokePerfPath -Synthetic `
            -DestinationPath $negEscapeDest `
            -EvidenceRoot $tempRoot `
            -RepositoryRoot $repoRoot
    } 'escaped the evidence root' 'destination path escaping evidence root produces zero output' $negEscapeDest

    # 17. Reparse junction destination path
    $reparseDir = Join-Path $tempRoot 'junction-dest'
    $reparseTarget = Join-Path $tempRoot 'junction-target'
    New-Item -ItemType Directory -Path $reparseTarget -Force | Out-Null
    & cmd /c "mklink /J `"$reparseDir`" `"$reparseTarget`"" 2>&1 | Out-Null
    if (Test-Path -LiteralPath $reparseDir) {
        $negReparseDest = Join-Path $reparseDir 'raw-perf.json'
        Assert-ThrowsMatchAndZeroOutput {
            & $script:InvokePerfPath -Synthetic `
                -DestinationPath $negReparseDest `
                -EvidenceRoot $tempRoot `
                -RepositoryRoot $repoRoot
        } 'contains a reparse point|must not contain a reparse point' 'reparse junction destination path produces zero output' $negReparseDest
    }

    # 18. Source commit mismatch
    $negCommitDest = Join-Path $tempRoot 'perf\neg-commit.json'
    Assert-ThrowsMatchAndZeroOutput {
        & $script:InvokePerfPath `
            -DestinationPath $negCommitDest `
            -EvidenceRoot $tempRoot `
            -RepositoryRoot $repoRoot `
            -PackageIdentityPath $receiptPath `
            -PackageArchivePath $archivePath `
            -ExtractedPackageRoot $packageRoot `
            -ExpectedSourceCommit '0000000000000000000000000000000000000000' `
            -ExpectedSourceTree $repo.Tree `
            -AppProcessId 123 `
            -CoreProcessId 456 `
            -SoakEvidencePath $soakFixturePath
    } 'Source commit mismatch' 'source commit mismatch produces zero output' $negCommitDest

    # 19. Source tree mismatch
    $negTreeDest = Join-Path $tempRoot 'perf\neg-tree.json'
    Assert-ThrowsMatchAndZeroOutput {
        & $script:InvokePerfPath `
            -DestinationPath $negTreeDest `
            -EvidenceRoot $tempRoot `
            -RepositoryRoot $repoRoot `
            -PackageIdentityPath $receiptPath `
            -PackageArchivePath $archivePath `
            -ExtractedPackageRoot $packageRoot `
            -ExpectedSourceCommit $repo.Commit `
            -ExpectedSourceTree '0000000000000000000000000000000000000000' `
            -AppProcessId 123 `
            -CoreProcessId 456 `
            -SoakEvidencePath $soakFixturePath
    } 'Source tree mismatch' 'source tree mismatch produces zero output' $negTreeDest

    # 20. Package component hash mismatch fails closed with zero output
    $negPkgTamperDest = Join-Path $tempRoot 'perf\neg-pkg-tamper.json'
    $tamperedAppPath = Join-Path $packageRoot 'HerdrOps.App.exe'
    [IO.File]::WriteAllBytes($tamperedAppPath, [Text.Encoding]::UTF8.GetBytes('tampered-binary'))
    Assert-ThrowsMatchAndZeroOutput {
        & $script:InvokePerfPath `
            -DestinationPath $negPkgTamperDest `
            -EvidenceRoot $tempRoot `
            -RepositoryRoot $repoRoot `
            -PackageIdentityPath $receiptPath `
            -PackageArchivePath $archivePath `
            -ExtractedPackageRoot $packageRoot `
            -ExpectedSourceCommit $repo.Commit `
            -ExpectedSourceTree $repo.Tree `
            -AppProcessId 123 `
            -CoreProcessId 456 `
            -SoakEvidencePath $soakFixturePath
    } 'Manifest/package-root inventories are not exact and coherent|Package App/Core bytes changed after package validation|hash.*mismatch' 'package component hash mismatch fails closed with zero output' $negPkgTamperDest
    # Restore app binary
    [IO.File]::WriteAllBytes($tamperedAppPath, [Text.Encoding]::UTF8.GetBytes('app-binary'))

    # -------------------------------------------------------------------------
    # LIVE PROBE TESTS VIA TEST HARNESS (REAL BOUND CHILD PROCESSES)
    # -------------------------------------------------------------------------

    # 21. Controlled live probe: unexpected child exit triggers exit guard
    try {
        Invoke-V02LivePerformanceGuardProbe -GuardMode 'UnexpectedExit' -TempRoot $tempRoot
        throw 'Expected unexpected exit probe to throw, but it succeeded.'
    } catch {
        if ($_.Exception.Message -match 'terminated unexpectedly during Order') {
            Pass-NegativeCase 'controlled live probe reaches unexpected App exit guard without publishing'
        } else {
            throw "Expected unexpected exit error, got: $($_.Exception.Message)"
        }
    }

    # 22. Controlled live probe: PID/start-time drift triggers recycle guard
    try {
        Invoke-V02LivePerformanceGuardProbe -GuardMode 'PidStartContinuity' -TempRoot $tempRoot
        throw 'Expected PID/start-time continuity probe to throw, but it succeeded.'
    } catch {
        if ($_.Exception.Message -match 'App start time drifted|was recycled') {
            Pass-NegativeCase 'controlled live probe rejects PID/start-time reuse continuity drift without publishing'
        } else {
            throw "Expected PID recycle error, got: $($_.Exception.Message)"
        }
    }

    # 23. Controlled live probe: forged renderer mode is rejected fail-closed
    try {
        Invoke-V02LivePerformanceGuardProbe -GuardMode 'ForgedRendererMode' -TempRoot $tempRoot
        throw 'Expected forged renderer mode probe to throw, but it succeeded.'
    } catch {
        if ($_.Exception.Message -match 'expected renderer mode') {
            Pass-NegativeCase 'controlled live probe rejects forged renderer mode without publishing'
        } else {
            throw "Expected forged renderer error, got: $($_.Exception.Message)"
        }
    }

    # 24. Controlled live probe: stale / non-monotonic timestamp is rejected fail-closed
    try {
        Invoke-V02LivePerformanceGuardProbe -GuardMode 'StaleTimestamp' -TempRoot $tempRoot
        throw 'Expected stale timestamp probe to throw, but it succeeded.'
    } catch {
        if ($_.Exception.Message -match 'timestamp is not strictly increasing') {
            Pass-NegativeCase 'controlled live probe rejects stale non-monotonic timestamp without publishing'
        } else {
            throw "Expected stale timestamp error, got: $($_.Exception.Message)"
        }
    }

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
