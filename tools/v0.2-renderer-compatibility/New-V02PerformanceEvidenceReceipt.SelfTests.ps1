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

    [pscustomobject][ordered]@{
        orders = $orders
    }
}

function New-ProvenanceFixture {
    [pscustomobject][ordered]@{
        runNonce = ('1' * 32)
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
        performanceTelemetryBinding = [pscustomobject][ordered]@{ relativePath='performance/performance-telemetry-binding.json';bytes=[long]789;fileSha256=('4'*64);canonicalSha256=('5'*64) }
        performanceTransactionCommit = [pscustomobject][ordered]@{ relativePath='performance/performance-commit.json';bytes=[long]321;fileSha256=('6'*64);canonicalSha256=('7'*64) }
    }
}

function New-Limits {
    [pscustomobject][ordered]@{
        status = 'APPROVED'
        approvalReference = $script:RendererAuthorizedApprovalReference
        scopeCorrectionReference = 'https://github.com/OSHEThai/HerdrOps/issues/149#issuecomment-5396694185'
        cpuMaximumPercent = 1
        eventToWpfP95Milliseconds = 250
        cpuRegressionMaximumPercent = 10
        cpuRegressionMaximumPercentagePoints = 0.5
        latencyRegressionMaximumPercent = 10
        uiStallP95Milliseconds = 50
        uiStallMaximumMilliseconds = 100
        workingSetMaximumBytes = 267386880
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

function New-ProvenanceAcquisitionFixture($Provenance) {
    $packagePrefix=([string]$Provenance.package.packageRootRelativePath).TrimEnd('/','\')+'/'
    $componentPaths=@{}
    foreach($name in @('app','core')){$relative=[string]$Provenance.package.components.$name.relativePath;$combined=if($relative.Replace('\','/').StartsWith($packagePrefix,[StringComparison]::OrdinalIgnoreCase)){$relative}else{Join-Path $Provenance.package.packageRootRelativePath $relative};$componentPaths[$name]=[IO.Path]::GetFullPath((Join-Path $script:EvidenceRoot $combined))}
    $serverPath=[IO.Path]::GetFullPath([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName);$base=[DateTimeOffset]::Parse('2026-08-22T10:00:00.0000000Z')
    @(0..23|ForEach-Object{$index=$_;$order=if($index-lt12){'AB'}else{'BA'};$within=$index%12;$warmup=$within-lt2;$repetition=if($warmup){0}else{[int][Math]::Floor(($within-2)/2)};$mode=if($order-ceq'AB'){if($within%2-eq0){'a'}else{'b'}}else{if($within%2-eq0){'b'}else{'a'}};$requested=if($mode-ceq'a'){'Hardware'}else{'SoftwareOnly'};$native=if($mode-ceq'a'){'Default'}else{'SoftwareOnly'};[pscustomobject][ordered]@{sequenceNumber=$index;order=$order;isWarmup=$warmup;repetitionOrdinal=$repetition;semanticMode=$mode;requestedMode=$requested;appProcessId=1000+$index;appStartUtc=$base.AddSeconds($index+1).ToString('O');appPath=$componentPaths.app;appSha256=$Provenance.package.components.app.sha256;coreProcessId=2000;coreStartUtc=$base.ToString('O');corePath=$componentPaths.core;coreSha256=$Provenance.package.components.core.sha256;serverProcessId=3000;serverStartUtc=$base.AddMinutes(-1).ToString('O');serverPath=$serverPath;serverSha256=('8'*64);nativeProcessRenderMode=$native;nativeTier=if($mode-ceq'a'){1}else{0};preFirstHwndProof=$true;observedUtc=$base.AddMinutes($index+1).ToString('O');boundary='PackagedCompatibilityPerformance-NativeTierComparator-NoPerFrameGpuOrRuntimeCredit'}})
}

function Initialize-ProvenanceEvidenceChain($Raw) {
    Write-RawSource $Raw
    $rawStable = Get-RendererStableFileIdentity $script:EvidenceRoot $script:RawSourceFullPath 'Fixture raw performance' -IncludeBytes
    $rawCanonical = ConvertTo-RendererCanonicalJson $Raw $script:RepoRoot
    $rawBinding = [pscustomobject][ordered]@{ relativePath=$script:RawSourceRelative;bytes=$rawStable.Bytes;fileSha256=$rawStable.Sha256;canonicalSha256=(Get-HumanDesignReviewSha256ForText $rawCanonical) }
    $provenance = $script:Provenance
    $sidecar = [pscustomobject][ordered]@{
        schemaVersion=2;evidenceClassification='PackagedCompatibilityPerformanceTelemetryBinding-NoRuntimeCredit';runNonce=$provenance.runNonce
        source=[pscustomobject][ordered]@{commitSha=$provenance.candidate.commitSha;treeSha=$provenance.candidate.treeSha}
        session=[pscustomobject][ordered]@{kind='LocalConsole';name='Issue10PerformanceComparator';sessionId=1;transport='Physical';powerSource='AC';thermalState='Nominal';elevated=$false;userScope='SingleUser'}
        package=[pscustomobject][ordered]@{identitySha256=$provenance.package.receipt.canonicalSha256;identityFileSha256=$provenance.package.receipt.fileSha256;profileFileSha256=$provenance.profile.fileSha256;archiveSha256=$provenance.package.archive.sha256;manifestSha256=('8'*64);appSha256=$provenance.package.components.app.sha256;coreSha256=$provenance.package.components.core.sha256}
        rawSource=$rawBinding;acquisitions=@(New-ProvenanceAcquisitionFixture $provenance)
        evidenceBoundary=[pscustomobject][ordered]@{actualHerdrRuntime='NOT_OBSERVED';release='NOT_OBSERVED';creditGranted=$false}
    }
    $sidecarPath = Join-Path $script:EvidenceRoot 'performance/performance-telemetry-binding.json'
    Write-RendererPackageCanonicalJson $sidecar $sidecarPath $script:RepoRoot
    $sidecarStable = Get-RendererStableFileIdentity $script:EvidenceRoot $sidecarPath 'Fixture performance telemetry sidecar' -IncludeBytes
    $sidecarBinding = [pscustomobject][ordered]@{relativePath='performance/performance-telemetry-binding.json';bytes=$sidecarStable.Bytes;fileSha256=$sidecarStable.Sha256;canonicalSha256=(Get-HumanDesignReviewSha256ForText (ConvertTo-RendererCanonicalJson $sidecar $script:RepoRoot))}
    $commit = [pscustomobject][ordered]@{schemaVersion=1;kind='issue10-performance-transaction-commit';runNonce=$provenance.runNonce;raw=[pscustomobject][ordered]@{fileName=[IO.Path]::GetFileName($script:RawSourceFullPath);bytes=$rawStable.Bytes;sha256=$rawStable.Sha256};binding=[pscustomobject][ordered]@{fileName=[IO.Path]::GetFileName($sidecarPath);bytes=$sidecarStable.Bytes;sha256=$sidecarStable.Sha256};creditGranted=$false}
    $commitPath = Join-Path $script:EvidenceRoot 'performance/performance-commit.json'
    Write-RendererPackageCanonicalJson $commit $commitPath $script:RepoRoot
    $commitStable = Get-RendererStableFileIdentity $script:EvidenceRoot $commitPath 'Fixture performance transaction commit' -IncludeBytes
    $provenance.performanceTelemetryBinding = $sidecarBinding
    $provenance.performanceTransactionCommit = [pscustomobject][ordered]@{relativePath='performance/performance-commit.json';bytes=$commitStable.Bytes;fileSha256=$commitStable.Sha256;canonicalSha256=(Get-HumanDesignReviewSha256ForText (ConvertTo-RendererCanonicalJson $commit $script:RepoRoot))}
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
$receiptLeaseJob = $null
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
    $script:ExpectedPackageReceipt = [pscustomobject][ordered]@{packageManifest=[pscustomobject][ordered]@{fileName='package-manifest.json';bytes=1L;sha256=('8'*64);contentSha256=('9'*64);fileCount=1;totalBytes=1L}}
    Initialize-ProvenanceEvidenceChain $script:Raw1
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

    $verified = Assert-RendererPerformanceReceipt $out1.Binding $script:EvidenceRoot $script:RepoRoot $limits $script:Provenance -ExpectedPackageReceipt $script:ExpectedPackageReceipt
    if ($verified -cne 'PASS') { throw 'Generated receipt failed independent consumer validation.' }
    Pass 'consumer recomputes receipt with exact provenance and all AB/BA evidence'

    # The consumer must retain a non-delete-sharing handle to the top-level
    # receipt until its whole authority graph and final leases are validated.
    $receiptLeaseSignal = Join-Path $tempRoot 'receipt-lease.signal'
    $receiptLeaseJob = Start-Job -ScriptBlock {
        param($Common,$Binding,$Evidence,$Repository,$Limits,$Provenance,$PackageReceipt,$Signal)
        . $Common
        Assert-RendererPerformanceReceipt $Binding $Evidence $Repository $Limits $Provenance -ExpectedPackageReceipt $PackageReceipt -TestAfterReceiptOpenSignalPath $Signal
    } -ArgumentList @((Join-Path $PSScriptRoot 'RendererCompatibility.Common.ps1'),$out1.Binding,$script:EvidenceRoot,$script:RepoRoot,$limits,$script:Provenance,$script:ExpectedPackageReceipt,$receiptLeaseSignal)
    if (-not (Wait-AtomicSignal $receiptLeaseJob $receiptLeaseSignal)) { throw 'Receipt-lease fixture did not reach the held-receipt signal.' }
    $receiptSwapPath = "$($out1.ReceiptPath).swap"
    $swapSucceeded = $false
    try {
        Move-Item -LiteralPath $out1.ReceiptPath -Destination $receiptSwapPath -ErrorAction Stop
        $swapSucceeded = $true
    } catch {
        # Expected on Windows: the held receipt handle does not share delete.
    } finally {
        Remove-Item -LiteralPath $receiptLeaseSignal -Force -ErrorAction SilentlyContinue
    }
    Wait-Job -Job $receiptLeaseJob | Out-Null
    $receiptLeaseOutput = @(Receive-Job $receiptLeaseJob)
    Remove-Job -Job $receiptLeaseJob -Force -ErrorAction SilentlyContinue
    $receiptLeaseJob = $null
    if ($swapSucceeded) {
        Move-Item -LiteralPath $receiptSwapPath -Destination $out1.ReceiptPath -ErrorAction SilentlyContinue
        throw 'Consumer allowed the top-level receipt path to be swapped while validation was active.'
    }
    if ($receiptLeaseOutput.Count -lt 1 -or $receiptLeaseOutput[-1] -cne 'PASS') { throw 'Receipt-lease consumer did not complete with PASS.' }
    Pass-Negative 'consumer prevents top-level receipt path swap during validation'

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
    Expect-ReceiptFailure 'candidate provenance transplant' { Assert-RendererPerformanceReceipt $out1.Binding $script:EvidenceRoot $script:RepoRoot $limits $transplantedProvenance -ExpectedPackageReceipt $script:ExpectedPackageReceipt }

    $mismatchedRaw = Copy-TestValue $script:Raw1
    $mismatchedRaw.orders[0].repetitions[0].a.cpuBasisPoints = 51
    Write-RawSource $script:Raw1
    Expect-BuilderFailure 'raw-source measurement mismatch' { Invoke-Builder $mismatchedRaw (Next-Destination 'raw-mismatch') $false }

    Expect-RawMutationFailure 'missing warmup' { param($v) $v.orders[0].warmup = $null }
    Expect-RawMutationFailure 'tampered warmup value' { param($v) $v.orders[0].warmup[0].a.cpuBasisPoints = -1 }
    Expect-RawMutationFailure 'warmup unknown field' { param($v) $v.orders[0].warmup[0] | Add-Member unauthorized $true }
    Expect-RawMutationFailure 'measured unknown field' { param($v) $v.orders[0].repetitions[0].a | Add-Member unauthorized $true }
    Expect-RawMutationFailure 'order unknown field' { param($v) $v.orders[0] | Add-Member unauthorized $true }
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
    Expect-ReceiptFailure 'tampered warmup does not validate against held raw source' { Assert-RendererPerformanceReceipt $tamperedBinding $script:EvidenceRoot $script:RepoRoot $limits $script:Provenance -ExpectedPackageReceipt $script:ExpectedPackageReceipt }

    $wrongExpected = Copy-TestValue $script:Provenance
    $wrongExpected.package.receipt.fileSha256 = ('6' * 64)
    Expect-ReceiptFailure 'consumer provenance mismatch' { Assert-RendererPerformanceReceipt $out1.Binding $script:EvidenceRoot $script:RepoRoot $limits $wrongExpected -ExpectedPackageReceipt $script:ExpectedPackageReceipt }

    $rawOriginal = [IO.File]::ReadAllBytes($script:RawSourceFullPath)
    try {
        $tamperedRaw = Copy-TestValue $script:Raw1
        $tamperedRaw.orders[0].warmup[0].a.cpuBasisPoints = 51
        Write-RawSource $tamperedRaw
        Expect-ReceiptFailure 'tampered held raw-source file' { Assert-RendererPerformanceReceipt $out1.Binding $script:EvidenceRoot $script:RepoRoot $limits $script:Provenance -ExpectedPackageReceipt $script:ExpectedPackageReceipt }
    } finally {
        [IO.File]::WriteAllBytes($script:RawSourceFullPath, $rawOriginal)
    }

    [pscustomobject]@{
        EvidenceClassification = 'SyntheticVerifierSelftest'
        PositiveCases = $script:PositiveCases
        NegativeCases = $script:NegativeCases
        Status = 'PASS'
    }
} finally {
    if ($null -ne $receiptLeaseJob) { Stop-Job -Job $receiptLeaseJob -ErrorAction SilentlyContinue; Remove-Job -Job $receiptLeaseJob -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
