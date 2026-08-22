#requires -Version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'RendererCompatibility.Common.ps1')

$script:PositiveCases = 0
$script:NegativeCases = 0
$script:DestinationIndex = 0

function Pass([string]$Name) {
    $script:PositiveCases++
    "PASS positive: $Name"
}

function Pass-Negative([string]$Name) {
    $script:NegativeCases++
    "PASS negative: $Name"
}

function Copy-TestValue($Value) {
    $json = $Value | ConvertTo-Json -Depth 80
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        $json | ConvertFrom-Json -DateKind String
    } else {
        $json | ConvertFrom-Json
    }
}

function New-SampleObject([long]$CpuBasisPoints = 50, [long]$WorkingSetBytes = 104857600, [long]$LatencyUs = 100000, [long]$StallUs = 10000) {
    [pscustomobject][ordered]@{
        cpuBasisPoints = $CpuBasisPoints
        workingSetMaximumBytes = $WorkingSetBytes
        latencyMicroseconds = @(1..20 | ForEach-Object { $LatencyUs })
        uiStallMicroseconds = @(1..20 | ForEach-Object { $StallUs })
    }
}

function New-RepetitionObject([int]$Ordinal, [string]$Timestamp, $SampleA = $null, $SampleB = $null) {
    if ($null -eq $SampleA) { $SampleA = New-SampleObject }
    if ($null -eq $SampleB) { $SampleB = New-SampleObject }
    [pscustomobject][ordered]@{
        ordinal = $Ordinal
        observedUtc = $Timestamp
        a = $SampleA
        b = $SampleB
    }
}

function New-ValidRawObservations {
    $orders = @()
    foreach ($orderName in @('AB', 'BA')) {
        $warmup = New-RepetitionObject 0 '2026-08-22T12:00:00.0000000Z'
        $repetitions = @()
        for ($i = 0; $i -lt 5; $i++) {
            $offset = if ($orderName -ceq 'BA') { 10 } else { 0 }
            $repetitions += New-RepetitionObject $i (('2026-08-22T12:01:{0:00}.0000000Z' -f ($i + $offset)))
        }
        $orders += [pscustomobject][ordered]@{
            order = $orderName
            warmup = @($warmup)
            repetitions = $repetitions
        }
    }

    $bins = @()
    foreach ($power in @('AC', 'Battery')) {
        for ($i = 0; $i -lt 12; $i++) {
            $offset = if ($power -ceq 'Battery') { 12 } else { 0 }
            $bins += [pscustomobject][ordered]@{
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

    [pscustomobject][ordered]@{
        orders = $orders
        soakBins = $bins
    }
}

function New-ProvenanceFixture {
    [pscustomobject][ordered]@{
        candidate = [pscustomobject][ordered]@{
            commitSha = ('a' * 40)
            treeSha = ('b' * 40)
        }
        package = [pscustomobject][ordered]@{
            profileId = $script:RendererPackageProfileId
            receipt = [pscustomobject][ordered]@{
                relativePath = 'package/package-identity-receipt.json'
                bytes = [long]123
                fileSha256 = ('C' * 64)
                canonicalSha256 = ('D' * 64)
            }
            archive = [pscustomobject][ordered]@{
                relativePath = 'package/HerdrOps-0.2.0-win-x64.zip'
                fileName = 'HerdrOps-0.2.0-win-x64.zip'
                bytes = [long]456
                sha256 = ('E' * 64)
            }
            packageRootRelativePath = 'package'
            components = [pscustomobject][ordered]@{
                app = [pscustomobject][ordered]@{ relativePath = 'package/HerdrOps.App.exe'; bytes = [long]10; sha256 = ('F' * 64) }
                core = [pscustomobject][ordered]@{ relativePath = 'package/HerdrOps.Core.exe'; bytes = [long]11; sha256 = ('1' * 64) }
            }
        }
        profile = [pscustomobject][ordered]@{
            id = $script:RendererPackageProfileId
            relativePath = 'tools/packaging/v0.2/package-identity-profile.json'
            bytes = [long]12
            fileSha256 = ('2' * 64)
            canonicalSha256 = ('3' * 64)
        }
        referenceHost = [pscustomobject][ordered]@{
            profileId = $script:RendererProfileId
            profileSha256 = $script:RendererProfileSha256
        }
        renderer = [pscustomobject][ordered]@{
            policy = 'software-only-process-wide'
            wpfProcessRenderMode = 'SoftwareOnly'
            policySha256 = $script:RendererPolicySha256
        }
        session = [pscustomobject][ordered]@{
            kind = 'LocalConsole'
            name = 'FixtureConsole'
            sessionId = [long]1
            transport = 'SyntheticFixture'
            powerSource = 'AC'
            thermalState = 'Nominal'
            elevated = $false
            userScope = 'SingleUser'
        }
    }
}

function New-Limits {
    [pscustomobject][ordered]@{
        status = 'APPROVED'
        approvalReference = $script:RendererAuthorizedApprovalReference
        cpuMaximumPercent = 1
        eventToWpfP95Milliseconds = 250
        cpuRegressionMaximumPercent = 10
        cpuRegressionMaximumPercentagePoints = 0.5
        latencyRegressionMaximumPercent = 10
        uiStallP95Milliseconds = 50
        uiStallMaximumMilliseconds = 100
        soakAcDurationMinutes = 60
        soakBatteryDurationMinutes = 60
        soakBinMinutes = 5
        workingSetMaximumBytes = 267386880
        resourceSlopeMaximumBytesPerTenMinutes = 1048576
    }
}

function Expect-BuilderFailure([string]$Name, [scriptblock]$Action) {
    $failed = $false
    try { & $Action | Out-Null } catch { $failed = $true }
    if (-not $failed) { throw "Negative case '$Name' did not fail closed." }
    Pass-Negative $Name
}

function Expect-ReceiptFailure([string]$Name, [scriptblock]$Action) {
    $failed = $false
    try { & $Action | Out-Null } catch { $failed = $true }
    if (-not $failed) { throw "Receipt negative case '$Name' did not fail closed." }
    Pass-Negative $Name
}

function Next-Destination([string]$Stem) {
    $script:DestinationIndex++
    return "performance/$Stem-$($script:DestinationIndex)"
}

function Write-RawSource($Value) {
    $parent = Split-Path -Parent $script:RawSourceFullPath
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    Write-RendererPackageCanonicalJson $Value $script:RawSourceFullPath $script:RepoRoot
}

function Invoke-Builder($Raw, [string]$Destination, [bool]$WriteSource = $true, $Provenance = $null, $Limits = $null) {
    if ($WriteSource) { Write-RawSource $Raw }
    if ($null -eq $Provenance) { $Provenance = $script:Provenance }
    $parameters = @{
        RawObservations = $Raw
        DestinationDirectory = $Destination
        RawSourcePath = $script:RawSourceRelative
        CandidateProvenance = $Provenance
        EvidenceRoot = $script:EvidenceRoot
        RepositoryRoot = $script:RepoRoot
    }
    if ($null -ne $Limits) { $parameters.OwnerNumericLimits = $Limits }
    & $script:BuilderScript @parameters
}

function Expect-RawMutationFailure([string]$Name, [scriptblock]$Mutate) {
    $bad = Copy-TestValue $script:Raw1
    & $Mutate $bad
    Expect-BuilderFailure $Name { Invoke-Builder $bad (Next-Destination 'negative') }
}

function Expect-ThresholdFailure([string]$Name, [scriptblock]$Mutate) {
    Expect-RawMutationFailure $Name $Mutate
}

function Wait-AtomicSignal($Job, [string]$SignalPath) {
    for ($i = 0; $i -lt 240; $i++) {
        if (Test-Path -LiteralPath $SignalPath -PathType Leaf) { return $true }
        if ($Job.State -in @('Completed','Failed','Stopped')) { return $false }
        Start-Sleep -Milliseconds 25
    }
    return $false
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('herdrops-perf-receipt-test-' + [Guid]::NewGuid().ToString('N'))
$crashJob = $null
$concurrentJob = $null
try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $script:EvidenceRoot = Join-Path $tempRoot 'evidence'
    $script:RepoRoot = Join-Path $tempRoot 'repo'
    New-Item -ItemType Directory -Path $script:EvidenceRoot, $script:RepoRoot -Force | Out-Null

    $worktree = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    $packageDir = Join-Path $script:RepoRoot 'tools\packaging\v0.2'
    $libDir = Join-Path $script:RepoRoot 'tools\lib'
    $planDir = Join-Path $script:RepoRoot 'Plan\reference-hosts'
    $referenceDir = Join-Path $script:RepoRoot 'docs\design\reference'
    New-Item -ItemType Directory -Path $packageDir, $libDir, $planDir, $referenceDir -Force | Out-Null
    $sourcePackageDir = Join-Path $PSScriptRoot '..\packaging\v0.2'
    Copy-Item (Join-Path $sourcePackageDir 'package-identity-profile.json') $packageDir
    Copy-Item (Join-Path $sourcePackageDir 'package-identity-receipt.schema.json') $packageDir
    Copy-Item (Join-Path $worktree 'tools\lib\V02ReferenceHostProfile.ps1') $libDir
    Copy-Item (Join-Path $worktree 'Plan\reference-hosts\v0.2.json') $planDir
    Copy-Item (Join-Path $worktree 'Plan\reference-hosts\reference-host-profile.schema.json') $planDir
    Copy-Item (Join-Path $worktree 'docs\design\reference\*.png') $referenceDir

    $script:BuilderScript = Join-Path $PSScriptRoot 'New-V02PerformanceEvidenceReceipt.ps1'
    $script:RawSourceRelative = 'performance/raw-observations.json'
    $script:RawSourceFullPath = Join-Path $script:EvidenceRoot $script:RawSourceRelative
    $script:Raw1 = New-ValidRawObservations
    $script:Provenance = New-ProvenanceFixture
    $limits = New-Limits

    # A successful receipt is a directory containing one canonical file. Warmups
    # and measured observations are both retained in the canonical receipt.
    $out1 = Invoke-Builder $script:Raw1 'performance/receipt-1'
    if ($out1.AggregateStatus -cne 'PASS' -or $out1.EvidenceClassification -cne 'PackagedCompatibilityCandidate' -or $out1.Bytes -le 0) {
        throw 'Valid receipt returned invalid summary properties.'
    }
    if ($out1.Receipt.orders[0].warmup.Count -ne 1 -or $out1.Receipt.orders[1].warmup.Count -ne 1) {
        throw 'Canonical receipt did not preserve both warmup repetitions.'
    }
    if ($out1.Receipt.rawSource.relativePath -cne $script:RawSourceRelative.Replace('\','/')) {
        throw 'Canonical receipt did not preserve raw-source provenance binding.'
    }
    Pass 'valid canonical receipt preserves warmups and raw-source binding'

    $verified = Assert-RendererPerformanceReceipt $out1.Binding $script:EvidenceRoot $script:RepoRoot $limits $script:Provenance
    if ($verified -cne 'PASS') { throw 'Generated receipt failed independent consumer validation.' }
    Pass 'consumer recomputes receipt with exact provenance and all AB/BA evidence'

    # Every input form must bind to the same held raw-source bytes.
    $outPipeline = $script:Raw1 | & $script:BuilderScript -DestinationDirectory 'performance/receipt-pipeline' -RawSourcePath $script:RawSourceRelative -CandidateProvenance $script:Provenance -EvidenceRoot $script:EvidenceRoot -RepositoryRoot $script:RepoRoot
    if ($outPipeline.CanonicalSha256 -cne $out1.CanonicalSha256) { throw 'Pipeline receipt was not deterministic.' }
    Pass 'pipeline input uses exact held raw-source provenance'

    $rawFilePath = Join-Path $script:EvidenceRoot 'performance/raw-input.json'
    Write-RendererPackageCanonicalJson $script:Raw1 $rawFilePath $script:RepoRoot
    $outFile = & $script:BuilderScript -RawObservations $rawFilePath -DestinationDirectory 'performance/receipt-file' -RawSourcePath $script:RawSourceRelative -CandidateProvenance $script:Provenance -EvidenceRoot $script:EvidenceRoot -RepositoryRoot $script:RepoRoot
    if ($outFile.CanonicalSha256 -cne $out1.CanonicalSha256) { throw 'File receipt was not deterministic.' }
    Pass 'file input uses exact held raw-source provenance'

    $rawJson = ConvertTo-RendererCanonicalJson $script:Raw1 $script:RepoRoot
    $outString = & $script:BuilderScript -RawObservations $rawJson -DestinationDirectory 'performance/receipt-string' -RawSourcePath $script:RawSourceRelative -CandidateProvenance $script:Provenance -EvidenceRoot $script:EvidenceRoot -RepositoryRoot $script:RepoRoot
    if ($outString.CanonicalSha256 -cne $out1.CanonicalSha256) { throw 'String receipt was not deterministic.' }
    Pass 'JSON string input uses exact held raw-source provenance'

    # A final directory is no-clobber. The original bytes remain unchanged.
    $beforeBytes = [IO.File]::ReadAllBytes($out1.ReceiptPath)
    Expect-BuilderFailure 'existing destination directory no-clobber' { Invoke-Builder $script:Raw1 'performance/receipt-1' }
    $afterBytes = [IO.File]::ReadAllBytes($out1.ReceiptPath)
    if ($beforeBytes.Length -ne $afterBytes.Length) { throw 'No-clobber failure changed the existing receipt length.' }
    for ($i = 0; $i -lt $beforeBytes.Length; $i++) { if ($beforeBytes[$i] -ne $afterBytes[$i]) { throw 'No-clobber failure changed existing receipt bytes.' } }

    $waiverParameters = @((Get-Command -Name $script:BuilderScript).Parameters.Keys | Where-Object { $_ -match 'Waiver|Breach' })
    if ($waiverParameters.Count -ne 0) { throw "Receipt builder exposes forbidden waiver parameters: $($waiverParameters -join ', ')" }
    Pass 'threshold waiver parameters absent'

    # Provenance and raw-source transplant/mismatch cases fail before publish.
    $transplantedProvenance = Copy-TestValue $script:Provenance
    $transplantedProvenance.candidate.commitSha = ('c' * 40)
    Expect-ReceiptFailure 'candidate provenance transplant' { Assert-RendererPerformanceReceipt $out1.Binding $script:EvidenceRoot $script:RepoRoot $limits $transplantedProvenance }

    $mismatchedRaw = Copy-TestValue $script:Raw1
    $mismatchedRaw.orders[0].repetitions[0].a.cpuBasisPoints = 51
    Write-RawSource $script:Raw1
    Expect-BuilderFailure 'raw-source measurement mismatch' { Invoke-Builder $mismatchedRaw (Next-Destination 'raw-mismatch') $false }

    Expect-RawMutationFailure 'missing warmup' { param($v) $v.orders[0].warmup = $null }
    Expect-RawMutationFailure 'tampered warmup value' { param($v) $v.orders[0].warmup[0].a.cpuBasisPoints = -1 }
    Expect-RawMutationFailure 'warmup unknown field' { param($v) $v.orders[0].warmup[0] | Add-Member unauthorized $true }
    Expect-RawMutationFailure 'measured unknown field' { param($v) $v.orders[0].repetitions[0].a | Add-Member unauthorized $true }
    Expect-RawMutationFailure 'order unknown field' { param($v) $v.orders[0] | Add-Member unauthorized $true }
    Expect-RawMutationFailure 'soak-bin unknown field' { param($v) $v.soakBins[0] | Add-Member unauthorized $true }
    Expect-RawMutationFailure 'raw top-level unknown field' { param($v) $v | Add-Member unauthorized $true }
    Expect-RawMutationFailure 'missing measured sample' { param($v) $v.orders[1].repetitions[0].PSObject.Properties.Remove('b') }
    Expect-RawMutationFailure 'missing raw latency sample' { param($v) $v.orders[0].repetitions[0].a.latencyMicroseconds = @($v.orders[0].repetitions[0].a.latencyMicroseconds | Select-Object -First 19) }
    Expect-RawMutationFailure 'missing raw stall sample' { param($v) $v.orders[0].repetitions[0].b.uiStallMicroseconds = @($v.orders[0].repetitions[0].b.uiStallMicroseconds | Select-Object -First 19) }

    # Every approved threshold is exercised independently. No FAIL receipt is
    # publishable and no waiver switch can turn any case into a positive result.
    Expect-ThresholdFailure 'mode A CPU absolute maximum' { param($v) $v.orders[0].repetitions[0].a.cpuBasisPoints = 150 }
    Expect-ThresholdFailure 'mode B CPU absolute maximum' { param($v) $v.orders[0].repetitions[0].b.cpuBasisPoints = 150 }
    Expect-ThresholdFailure 'CPU percentage-point regression' { param($v) $v.orders[0].repetitions[0].a.cpuBasisPoints = 40; $v.orders[0].repetitions[0].b.cpuBasisPoints = 95 }
    Expect-ThresholdFailure 'CPU relative-percent regression' { param($v) $v.orders[0].repetitions[0].a.cpuBasisPoints = 50; $v.orders[0].repetitions[0].b.cpuBasisPoints = 56 }
    Expect-ThresholdFailure 'event-to-WPF latency absolute maximum' { param($v) $v.orders[0].repetitions[0].b.latencyMicroseconds[18] = 300000; $v.orders[0].repetitions[0].b.latencyMicroseconds[19] = 300000 }
    Expect-ThresholdFailure 'latency relative regression' { param($v) $v.orders[0].repetitions[0].b.latencyMicroseconds = @(1..20 | ForEach-Object { 111000 }) }
    Expect-ThresholdFailure 'UI stall p95 absolute maximum' { param($v) $v.orders[0].repetitions[0].b.uiStallMicroseconds[18] = 51000; $v.orders[0].repetitions[0].b.uiStallMicroseconds[19] = 51000 }
    Expect-ThresholdFailure 'UI stall maximum absolute maximum' { param($v) $v.orders[0].repetitions[0].b.uiStallMicroseconds[19] = 101000 }
    Expect-ThresholdFailure 'mode A working-set absolute maximum' { param($v) $v.orders[0].repetitions[0].a.workingSetMaximumBytes = 267386881 }
    Expect-ThresholdFailure 'mode B working-set absolute maximum' { param($v) $v.orders[0].repetitions[0].b.workingSetMaximumBytes = 267386881 }
    Expect-ThresholdFailure 'soak start working-set maximum' { param($v) $v.soakBins[0].workingSetStartBytes = 267386881 }
    Expect-ThresholdFailure 'soak end working-set maximum' { param($v) $v.soakBins[0].workingSetEndBytes = 267386881 }
    Expect-ThresholdFailure 'soak working-set slope maximum' { param($v) $v.soakBins[0].workingSetEndBytes = 106000000 }
    Expect-ThresholdFailure 'soak renderer stability requirement' { param($v) $v.soakBins[0].rendererStable = $false }

    $unapproved = Copy-TestValue $limits
    $unapproved.status = 'NOT_OBSERVED'
    Expect-BuilderFailure 'unapproved owner limits' { Invoke-Builder $script:Raw1 (Next-Destination 'unapproved') $true $script:Provenance $unapproved }
    $drifted = Copy-TestValue $limits
    $drifted.cpuMaximumPercent = 2
    Expect-BuilderFailure 'owner limit drift' { Invoke-Builder $script:Raw1 (Next-Destination 'limit-drift') $true $script:Provenance $drifted }

    # Consumer rejects a receipt whose warmup or provenance is altered even if
    # its new binding is internally canonical: the raw-source and expected
    # candidate bindings remain authoritative.
    $tamperedReceipt = Copy-TestValue $out1.Receipt
    $tamperedReceipt.orders[0].warmup[0].a.cpuBasisPoints = 51
    $tamperedReceiptPath = Join-Path $script:EvidenceRoot 'performance/tampered-receipt.json'
    Write-RendererPackageCanonicalJson $tamperedReceipt $tamperedReceiptPath $script:RepoRoot
    $tamperedStable = Get-RendererStableFileIdentity $script:EvidenceRoot $tamperedReceiptPath 'tampered receipt'
    $tamperedCanonical = ConvertTo-RendererCanonicalJson $tamperedReceipt $script:RepoRoot
    $tamperedBinding = [pscustomobject][ordered]@{ relativePath = 'performance/tampered-receipt.json'; bytes = $tamperedStable.Bytes; fileSha256 = $tamperedStable.Sha256; canonicalSha256 = Get-HumanDesignReviewSha256ForText $tamperedCanonical }
    Expect-ReceiptFailure 'tampered warmup does not validate against held raw source' { Assert-RendererPerformanceReceipt $tamperedBinding $script:EvidenceRoot $script:RepoRoot $limits $script:Provenance }

    $wrongExpected = Copy-TestValue $script:Provenance
    $wrongExpected.package.receipt.fileSha256 = ('6' * 64)
    Expect-ReceiptFailure 'consumer provenance mismatch' { Assert-RendererPerformanceReceipt $out1.Binding $script:EvidenceRoot $script:RepoRoot $limits $wrongExpected }

    $rawOriginal = [IO.File]::ReadAllBytes($script:RawSourceFullPath)
    try {
        $tamperedRaw = Copy-TestValue $script:Raw1
        $tamperedRaw.orders[0].warmup[0].a.cpuBasisPoints = 51
        Write-RawSource $tamperedRaw
        Expect-ReceiptFailure 'tampered held raw-source file' { Assert-RendererPerformanceReceipt $out1.Binding $script:EvidenceRoot $script:RepoRoot $limits $script:Provenance }
    } finally {
        [IO.File]::WriteAllBytes($script:RawSourceFullPath, $rawOriginal)
    }

    # Crash boundary: stop only the fixture job we created while it is paused
    # before the directory rename. A final receipt must not be visible.
    $crashSignal = Join-Path $tempRoot 'crash.signal'
    $crashDestination = 'performance/crash-boundary'
    $crashJob = Start-Job -ScriptBlock {
        param($Builder,$Raw,$Destination,$RawSource,$Provenance,$Evidence,$Repository,$Signal)
        & $Builder -RawObservations $Raw -DestinationDirectory $Destination -RawSourcePath $RawSource -CandidateProvenance $Provenance -EvidenceRoot $Evidence -RepositoryRoot $Repository -TestBeforeAtomicMoveSignalPath $Signal
    } -ArgumentList @($script:BuilderScript,$rawJson,$crashDestination,$script:RawSourceRelative,$script:Provenance,$script:EvidenceRoot,$script:RepoRoot,$crashSignal)
    if (-not (Wait-AtomicSignal $crashJob $crashSignal)) {
        $state = $crashJob.State
        $reason = $crashJob.ChildJobs[0].JobStateInfo.Reason
        $jobOutput = @(Receive-Job $crashJob -Keep -ErrorAction SilentlyContinue | Out-String)
        throw "Crash-boundary fixture did not reach the pre-rename signal; state=$state reason=$reason output=$($jobOutput -join '')"
    }
    Stop-Job -Job $crashJob -ErrorAction SilentlyContinue
    $null = Receive-Job $crashJob -ErrorAction SilentlyContinue
    Remove-Job -Job $crashJob -Force -ErrorAction SilentlyContinue
    $crashJob = $null
    if (Test-Path -LiteralPath (Join-Path $script:EvidenceRoot $crashDestination) -PathType Container) {
        throw 'Crash-boundary fixture exposed a final receipt directory.'
    }
    Pass 'crash boundary leaves no partially visible final receipt'

    # Concurrent reader boundary: while the writer is paused, the final path
    # is absent; after one directory move it is a complete valid receipt.
    $concurrentSignal = Join-Path $tempRoot 'concurrent.signal'
    $concurrentDestination = 'performance/concurrent-boundary'
    $concurrentJob = Start-Job -ScriptBlock {
        param($Builder,$Raw,$Destination,$RawSource,$Provenance,$Evidence,$Repository,$Signal)
        & $Builder -RawObservations $Raw -DestinationDirectory $Destination -RawSourcePath $RawSource -CandidateProvenance $Provenance -EvidenceRoot $Evidence -RepositoryRoot $Repository -TestBeforeAtomicMoveSignalPath $Signal
    } -ArgumentList @($script:BuilderScript,$rawJson,$concurrentDestination,$script:RawSourceRelative,$script:Provenance,$script:EvidenceRoot,$script:RepoRoot,$concurrentSignal)
    if (-not (Wait-AtomicSignal $concurrentJob $concurrentSignal)) { throw 'Concurrent-boundary fixture did not reach the pre-rename signal.' }
    if (Test-Path -LiteralPath (Join-Path $script:EvidenceRoot $concurrentDestination)) { throw 'Final receipt became visible before atomic directory rename.' }
    Remove-Item -LiteralPath $concurrentSignal -Force
    Wait-Job -Job $concurrentJob | Out-Null
    $concurrentOutput = @(Receive-Job $concurrentJob)
    Remove-Job -Job $concurrentJob -Force -ErrorAction SilentlyContinue
    $concurrentJob = $null
    if ($concurrentOutput.Count -lt 1 -or $concurrentOutput[-1].AggregateStatus -cne 'PASS') { throw 'Concurrent-boundary fixture did not publish a PASS receipt.' }
    $concurrentBinding = $concurrentOutput[-1].Binding
    if ((Assert-RendererPerformanceReceipt $concurrentBinding $script:EvidenceRoot $script:RepoRoot $limits $script:Provenance) -cne 'PASS') { throw 'Concurrent receipt failed post-rename validation.' }
    Pass 'concurrent reader sees absent-or-complete directory receipt only'

    [pscustomobject]@{
        EvidenceClassification = 'SyntheticVerifierSelftest'
        PositiveCases = $script:PositiveCases
        NegativeCases = $script:NegativeCases
        Status = 'PASS'
    }
} finally {
    if ($null -ne $crashJob) { Stop-Job -Job $crashJob -ErrorAction SilentlyContinue; Remove-Job -Job $crashJob -Force -ErrorAction SilentlyContinue }
    if ($null -ne $concurrentJob) { Remove-Job -Job $concurrentJob -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
