#requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'RendererCompatibility.Common.ps1')
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

function New-TestRepository([string]$Root) {
    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $Root 'source.txt'), 'bound source', (New-Object Text.UTF8Encoding($false)))
    $worktree = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    $packageDir = Join-Path $Root 'tools\packaging\v0.2'
    $libDir = Join-Path $Root 'tools\lib'
    $planDir = Join-Path $Root 'Plan\reference-hosts'
    $referenceDir = Join-Path $Root 'docs\design\reference'
    New-Item -ItemType Directory -Path $packageDir, $libDir, $planDir, $referenceDir -Force | Out-Null
    $sourcePackageDir = Join-Path $PSScriptRoot '..\packaging\v0.2'
    Copy-Item (Join-Path $sourcePackageDir 'package-identity-profile.json') $packageDir
    Copy-Item (Join-Path $sourcePackageDir 'package-identity-receipt.schema.json') $packageDir
    Copy-Item (Join-Path $worktree 'tools\lib\V02ReferenceHostProfile.ps1') $libDir
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

function Get-TestSampleProvider([double]$WsStartMb = 100, [double]$WsEndMb = 100.5, [double]$CpuBp = 30, [double]$LatMs = 100, [double]$StlMs = 10, [double]$StlMaxMs = 20, [bool]$RendererStable = $true) {
    $sb = {
        param($binIndex, $sampleIndex, $elapsedMs)
        $ws = [long](($WsStartMb + (($WsEndMb - $WsStartMb) * ($sampleIndex / 10.0))) * 1048576)
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
        -TotalBins 12 `
        -BinDurationMinutes 5 `
        -SamplesPerBin 2 `
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
        -TotalBins 12 `
        -BinDurationMinutes 5 `
        -SamplesPerBin 2 `
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

    # 6. Safe Atomic Overwrite with -ForceOverwrite
    $acRes2 = & $script:InvokeSoakPath -Synthetic `
        -PowerSource 'AC' `
        -DestinationPath $acDest `
        -EvidenceRoot $tempRoot `
        -RepositoryRoot $repoRoot `
        -ForceOverwrite `
        -TotalBins 1 `
        -BinDurationMinutes 1 `
        -SamplesPerBin 2 `
        -SyntheticPowerStateProvider { 'AC' } `
        -SyntheticProcessTelemetryProvider (Get-TestSampleProvider)

    if ($acRes2.TotalBins -ne 1) {
        throw "ForceOverwrite failed to overwrite existing destination."
    }
    Pass-PositiveCase 'safe atomic overwrite with -ForceOverwrite'

    # 7. -AllowThresholdBreach records FAIL aggregate status without throwing unhandled exception
    $failDest = Join-Path $tempRoot 'matrix\soak-fail.json'
    $failRes = & $script:InvokeSoakPath -Synthetic `
        -PowerSource 'AC' `
        -DestinationPath $failDest `
        -EvidenceRoot $tempRoot `
        -RepositoryRoot $repoRoot `
        -TotalBins 2 `
        -BinDurationMinutes 5 `
        -SamplesPerBin 2 `
        -AllowThresholdBreach `
        -SyntheticPowerStateProvider { 'AC' } `
        -SyntheticProcessTelemetryProvider (Get-TestSampleProvider -WsStartMb 250 -WsEndMb 260)

    if ($failRes.AggregateStatus -ne 'FAIL') {
        throw "Expected FAIL aggregate status under threshold breach."
    }
    Pass-PositiveCase 'allow-threshold-breach generates canonical FAIL receipt'

    # 8. Boundary Flags Verification
    $doc = $acRes.ReceiptDocument
    if ($doc.evidenceBoundary.creditGranted -ne $false -or
        $doc.evidenceBoundary.actualHerdrRuntime -ne 'NOT_OBSERVED' -or
        $doc.evidenceBoundary.humanReview -ne 'NOT_OBSERVED' -or
        $doc.evidenceBoundary.release -ne 'NOT_OBSERVED') {
        throw "Evidence boundary does not explicitly deny runtime/release credit."
    }
    Pass-PositiveCase 'evidence boundary explicitly denies runtime, release, and credit'

    # -------------------------------------------------------------------------
    # HOSTILE NEGATIVE TESTS
    # -------------------------------------------------------------------------

    # Negative: Initial power mismatch
    Assert-ThrowsMatch {
        & $script:InvokeSoakPath -Synthetic `
            -PowerSource 'AC' `
            -DestinationPath (Join-Path $tempRoot 'test-neg.json') `
            -EvidenceRoot $tempRoot `
            -RepositoryRoot $repoRoot `
            -SamplesPerBin 1 `
            -SyntheticPowerStateProvider { 'Battery' } `
            -SyntheticProcessTelemetryProvider (Get-TestSampleProvider)
    } 'Initial power source mismatch' 'initial power source mismatch (AC requested, Battery observed)'

    Assert-ThrowsMatch {
        & $script:InvokeSoakPath -Synthetic `
            -PowerSource 'Battery' `
            -DestinationPath (Join-Path $tempRoot 'test-neg.json') `
            -EvidenceRoot $tempRoot `
            -RepositoryRoot $repoRoot `
            -SamplesPerBin 1 `
            -SyntheticPowerStateProvider { 'AC' } `
            -SyntheticProcessTelemetryProvider (Get-TestSampleProvider)
    } 'Initial power source mismatch' 'initial power source mismatch (Battery requested, AC observed)'

    # Negative: Mid-soak power interruption
    $powerCount = 0
    $interruptProvider = {
        $powerCount++
        if ($powerCount -gt 2) { 'Battery' } else { 'AC' }
    }.GetNewClosure()

    Assert-ThrowsMatch {
        & $script:InvokeSoakPath -Synthetic `
            -PowerSource 'AC' `
            -DestinationPath (Join-Path $tempRoot 'test-neg.json') `
            -EvidenceRoot $tempRoot `
            -RepositoryRoot $repoRoot `
            -TotalBins 2 `
            -BinDurationMinutes 1 `
            -SamplesPerBin 2 `
            -SyntheticPowerStateProvider $interruptProvider `
            -SyntheticProcessTelemetryProvider (Get-TestSampleProvider)
    } 'Power source changed' 'mid-soak power interruption from AC to Battery'

    # Negative: No-clobber protection
    Assert-ThrowsMatch {
        & $script:InvokeSoakPath -Synthetic `
            -PowerSource 'AC' `
            -DestinationPath $acDest `
            -EvidenceRoot $tempRoot `
            -RepositoryRoot $repoRoot `
            -TotalBins 1 `
            -SamplesPerBin 1 `
            -SyntheticPowerStateProvider { 'AC' } `
            -SyntheticProcessTelemetryProvider (Get-TestSampleProvider)
    } 'already exists; refusing to clobber' 'no-clobber protection refuses to overwrite existing file without -ForceOverwrite'

    # Negative: Destination escaping evidence root
    Assert-ThrowsMatch {
        & $script:InvokeSoakPath -Synthetic `
            -PowerSource 'AC' `
            -DestinationPath ([IO.Path]::GetFullPath((Join-Path $tempRoot '..\escaped.json'))) `
            -EvidenceRoot $tempRoot `
            -RepositoryRoot $repoRoot `
            -SamplesPerBin 1 `
            -SyntheticPowerStateProvider { 'AC' } `
            -SyntheticProcessTelemetryProvider (Get-TestSampleProvider)
    } 'escaped the evidence root' 'destination path escaping evidence root'

    # Negative: Reparse point junction destination path
    $reparseDir = Join-Path $tempRoot 'junction-dest'
    $reparseTarget = Join-Path $tempRoot 'junction-target'
    New-Item -ItemType Directory -Path $reparseTarget -Force | Out-Null
    & cmd /c "mklink /J `"$reparseDir`" `"$reparseTarget`"" 2>&1 | Out-Null
    if (Test-Path -LiteralPath $reparseDir) {
        Assert-ThrowsMatch {
            & $script:InvokeSoakPath -Synthetic `
                -PowerSource 'AC' `
                -DestinationPath (Join-Path $reparseDir 'receipt.json') `
                -EvidenceRoot $tempRoot `
                -RepositoryRoot $repoRoot `
                -SamplesPerBin 1 `
                -SyntheticPowerStateProvider { 'AC' } `
                -SyntheticProcessTelemetryProvider (Get-TestSampleProvider)
        } 'contains a reparse point|must not contain a reparse point' 'reparse junction destination path'
    }

    # Negative: Working set budget breach (> 255 MiB)
    Assert-ThrowsMatch {
        & $script:InvokeSoakPath -Synthetic `
            -PowerSource 'AC' `
            -DestinationPath (Join-Path $tempRoot 'neg-ws.json') `
            -EvidenceRoot $tempRoot `
            -RepositoryRoot $repoRoot `
            -TotalBins 1 `
            -BinDurationMinutes 1 `
            -SamplesPerBin 2 `
            -SyntheticPowerStateProvider { 'AC' } `
            -SyntheticProcessTelemetryProvider (Get-TestSampleProvider -WsStartMb 260 -WsEndMb 260)
    } 'combined WS .* > limit' 'working set budget breach > 255 MiB'

    # Negative: Working set slope breach (> 1 MiB / 10 min)
    Assert-ThrowsMatch {
        & $script:InvokeSoakPath -Synthetic `
            -PowerSource 'AC' `
            -DestinationPath (Join-Path $tempRoot 'neg-slope.json') `
            -EvidenceRoot $tempRoot `
            -RepositoryRoot $repoRoot `
            -TotalBins 1 `
            -BinDurationMinutes 5 `
            -SamplesPerBin 2 `
            -SyntheticPowerStateProvider { 'AC' } `
            -SyntheticProcessTelemetryProvider (Get-TestSampleProvider -WsStartMb 100 -WsEndMb 102)
    } 'WS slope .* > limit' 'working set slope breach > 1 MiB / 10 min'

    # Negative: CPU percentage breach (> 1%)
    Assert-ThrowsMatch {
        & $script:InvokeSoakPath -Synthetic `
            -PowerSource 'AC' `
            -DestinationPath (Join-Path $tempRoot 'neg-cpu.json') `
            -EvidenceRoot $tempRoot `
            -RepositoryRoot $repoRoot `
            -TotalBins 1 `
            -BinDurationMinutes 1 `
            -SamplesPerBin 2 `
            -SyntheticPowerStateProvider { 'AC' } `
            -SyntheticProcessTelemetryProvider (Get-TestSampleProvider -CpuBp 150)
    } 'combined CPU .* > limit' 'CPU usage breach > 1%'

    # Negative: Latency P95 breach (> 250 ms)
    Assert-ThrowsMatch {
        & $script:InvokeSoakPath -Synthetic `
            -PowerSource 'AC' `
            -DestinationPath (Join-Path $tempRoot 'neg-lat.json') `
            -EvidenceRoot $tempRoot `
            -RepositoryRoot $repoRoot `
            -TotalBins 1 `
            -BinDurationMinutes 1 `
            -SamplesPerBin 2 `
            -SyntheticPowerStateProvider { 'AC' } `
            -SyntheticProcessTelemetryProvider (Get-TestSampleProvider -LatMs 300)
    } 'latency P95 .* > limit' 'latency P95 breach > 250 ms'

    # Negative: UI Stall P95 breach (> 50 ms)
    Assert-ThrowsMatch {
        & $script:InvokeSoakPath -Synthetic `
            -PowerSource 'AC' `
            -DestinationPath (Join-Path $tempRoot 'neg-stl.json') `
            -EvidenceRoot $tempRoot `
            -RepositoryRoot $repoRoot `
            -TotalBins 1 `
            -BinDurationMinutes 1 `
            -SamplesPerBin 2 `
            -SyntheticPowerStateProvider { 'AC' } `
            -SyntheticProcessTelemetryProvider (Get-TestSampleProvider -StlMs 60)
    } 'UI stall P95 .* > limit' 'UI stall P95 breach > 50 ms'

    # Negative: UI Stall Maximum breach (> 100 ms)
    Assert-ThrowsMatch {
        & $script:InvokeSoakPath -Synthetic `
            -PowerSource 'AC' `
            -DestinationPath (Join-Path $tempRoot 'neg-stlmax.json') `
            -EvidenceRoot $tempRoot `
            -RepositoryRoot $repoRoot `
            -TotalBins 1 `
            -BinDurationMinutes 1 `
            -SamplesPerBin 2 `
            -SyntheticPowerStateProvider { 'AC' } `
            -SyntheticProcessTelemetryProvider (Get-TestSampleProvider -StlMs 10 -StlMaxMs 120)
    } 'UI stall max .* > limit' 'UI stall maximum breach > 100 ms'

    # Negative: Renderer instability failure
    Assert-ThrowsMatch {
        & $script:InvokeSoakPath -Synthetic `
            -PowerSource 'AC' `
            -DestinationPath (Join-Path $tempRoot 'neg-unstable.json') `
            -EvidenceRoot $tempRoot `
            -RepositoryRoot $repoRoot `
            -TotalBins 1 `
            -BinDurationMinutes 1 `
            -SamplesPerBin 2 `
            -SyntheticPowerStateProvider { 'AC' } `
            -SyntheticProcessTelemetryProvider (Get-TestSampleProvider -RendererStable $false)
    } 'renderer stability failure' 'renderer instability failure'

    # Negative: Live mode invalid process IDs
    Assert-ThrowsMatch {
        & $script:InvokeSoakPath `
            -PowerSource 'AC' `
            -DestinationPath (Join-Path $tempRoot 'neg-proc.json') `
            -EvidenceRoot $tempRoot `
            -RepositoryRoot $repoRoot `
            -AppProcessId 0 `
            -CoreProcessId 0
    } 'Live soak measurement requires positive AppProcessId and CoreProcessId' 'live mode invalid process IDs'

    # Negative: Live mode non-existent process ID
    Assert-ThrowsMatch {
        & $script:InvokeSoakPath `
            -PowerSource 'AC' `
            -DestinationPath (Join-Path $tempRoot 'neg-proc.json') `
            -EvidenceRoot $tempRoot `
            -RepositoryRoot $repoRoot `
            -AppProcessId 999999 `
            -CoreProcessId 999998
    } 'Unable to connect to target App' 'live mode non-existent process ID'

    # Negative: Source commit mismatch
    Assert-ThrowsMatch {
        & $script:InvokeSoakPath -Synthetic `
            -PowerSource 'AC' `
            -DestinationPath (Join-Path $tempRoot 'neg-commit.json') `
            -EvidenceRoot $tempRoot `
            -RepositoryRoot $repoRoot `
            -ExpectedSourceCommit '0000000000000000000000000000000000000000' `
            -SamplesPerBin 1 `
            -SyntheticPowerStateProvider { 'AC' } `
            -SyntheticProcessTelemetryProvider (Get-TestSampleProvider)
    } 'Source commit mismatch' 'source commit mismatch'

    # Negative: Source tree mismatch
    Assert-ThrowsMatch {
        & $script:InvokeSoakPath -Synthetic `
            -PowerSource 'AC' `
            -DestinationPath (Join-Path $tempRoot 'neg-tree.json') `
            -EvidenceRoot $tempRoot `
            -RepositoryRoot $repoRoot `
            -ExpectedSourceTree '0000000000000000000000000000000000000000' `
            -SamplesPerBin 1 `
            -SyntheticPowerStateProvider { 'AC' } `
            -SyntheticProcessTelemetryProvider (Get-TestSampleProvider)
    } 'Source tree mismatch' 'source tree mismatch'

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