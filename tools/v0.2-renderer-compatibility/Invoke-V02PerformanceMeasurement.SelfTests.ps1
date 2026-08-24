#requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'RendererCompatibility.Common.ps1')
. (Join-Path $PSScriptRoot 'lib\V02PerformanceTestHarness.ps1')
$script:InvokePerfPath = Join-Path $PSScriptRoot 'Invoke-V02PerformanceMeasurement.ps1'
$script:NewReceiptPath = Join-Path $PSScriptRoot 'New-V02PerformanceEvidenceReceipt.ps1'
$script:PublisherPath = Join-Path $PSScriptRoot '..\v0.2-issue10-live-widget\Publish-V02Issue10PerformanceEvidence.ps1'

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
        $perfRes.Orders[1].order -ne 'BA') {
        throw "Synthetic raw performance collector failed basic assertions."
    }
    Pass-PositiveCase 'valid synthetic raw performance observations generation in AB then BA order'

    # The collector must execute BA as b,a while retaining semantic a/b fields.
    $executionTrace = New-Object Collections.Generic.List[string]
    $orderedDest = Join-Path $tempRoot 'perf\ordered-performance-observations.json'
    $orderedResult = & $script:InvokePerfPath -Synthetic `
        -DestinationPath $orderedDest `
        -EvidenceRoot $tempRoot `
        -RepositoryRoot $repoRoot `
        -SyntheticTelemetryProvider {
            param($order,$warmup,$repetition,$mode)
            $executionTrace.Add("$order|$warmup|$repetition|$mode")
            [pscustomobject][ordered]@{
                cpuBasisPoints = if ($mode -ceq 'a') { 40 } else { 41 }
                workingSetMaximumBytes = 104857600
                latencyMicroseconds = @(1..20 | ForEach-Object { if ($mode -ceq 'a') { 90000L } else { 91000L } })
                uiStallMicroseconds = @(1..20 | ForEach-Object { 10000L })
            }
        }
    $expectedTrace = @()
    foreach ($order in @('AB','BA')) {
        $modes = if ($order -ceq 'AB') { @('a','b') } else { @('b','a') }
        foreach ($mode in $modes) { $expectedTrace += "$order|True|0|$mode" }
        foreach ($rep in 0..4) { foreach ($mode in $modes) { $expectedTrace += "$order|False|$rep|$mode" } }
    }
    if ((@($executionTrace) -join "`n") -cne ($expectedTrace -join "`n")) {
        throw "Performance execution order was not exact AB=a,b then BA=b,a.`nActual: $($executionTrace -join ', ')"
    }
    if ($orderedResult.Orders[1].warmup[0].a.cpuBasisPoints -ne 40 -or
        $orderedResult.Orders[1].warmup[0].b.cpuBasisPoints -ne 41) {
        throw 'BA execution results were stored by position instead of semantic mode a/b.'
    }
    Pass-PositiveCase 'governed execution is AB a,b then BA b,a with semantic a/b storage'

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
    $receiptCanonical = Read-RendererCanonicalPackageReceipt $receiptPath $repoRoot

    $candidateProvenance = [pscustomobject][ordered]@{
        runNonce = ('1' * 32)
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
            elevated = $false
            userScope = 'SingleUser'
        }
        performanceTelemetryBinding = [pscustomobject][ordered]@{relativePath='performance/binding.json';bytes=1L;fileSha256=('4'*64);canonicalSha256=('5'*64)}
        performanceTransactionCommit = [pscustomobject][ordered]@{relativePath='performance/commit.json';bytes=1L;fileSha256=('6'*64);canonicalSha256=('7'*64)}
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

    # Exercise the production publisher against exact package/raw/telemetry/
    # transaction inputs. Each hostile writes fresh canonical inputs and must
    # fail before its no-clobber destination becomes visible.
    $rawPublisherStable=Get-RendererStableFileIdentity $tempRoot $rawDest 'Publisher raw performance' -IncludeBytes
    $rawPublisherText=(New-Object Text.UTF8Encoding($false,$true)).GetString($rawPublisherStable.Content)
    if(-not$rawPublisherText.EndsWith("`n",[StringComparison]::Ordinal)-or$rawPublisherText.EndsWith("`n`n",[StringComparison]::Ordinal)){throw 'Publisher raw fixture is not canonical JSON plus exactly one LF.'}
    $rawPublisherCanonical=Get-HumanDesignReviewSha256ForText $rawPublisherText.Substring(0,$rawPublisherText.Length-1)
    $script:PublisherSequence=0
    function Invoke-PublisherFixture([string]$Name,[scriptblock]$MutateSidecar=$null,[scriptblock]$MutateCommit=$null,[string]$ExpectedPattern=''){
        $script:PublisherSequence++
        $caseRoot=Join-Path $tempRoot ("publisher-case-$($script:PublisherSequence)")
        New-Item -ItemType Directory -Path $caseRoot -Force|Out-Null
        $bindingPath=Join-Path $caseRoot 'performance-telemetry-binding.json';$commitPath=Join-Path $caseRoot 'performance-commit.json';$destination=Join-Path $caseRoot 'published'
        $base=[DateTimeOffset]::Parse('2026-08-22T10:00:00.0000000Z');$serverPath=[IO.Path]::GetFullPath([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName);$serverSha=(Get-FileHash -LiteralPath $serverPath -Algorithm SHA256).Hash
        $acquisitions=@(0..23|ForEach-Object{$index=$_;$order=if($index-lt12){'AB'}else{'BA'};$within=$index%12;$warmup=$within-lt2;$repetition=if($warmup){0}else{[int][Math]::Floor(($within-2)/2)};$mode=if($order-ceq'AB'){if($within%2-eq0){'a'}else{'b'}}else{if($within%2-eq0){'b'}else{'a'}};$requested=if($mode-ceq'a'){'Hardware'}else{'SoftwareOnly'};$native=if($mode-ceq'a'){'Default'}else{'SoftwareOnly'};[pscustomobject][ordered]@{sequenceNumber=$index;order=$order;isWarmup=$warmup;repetitionOrdinal=$repetition;semanticMode=$mode;requestedMode=$requested;appProcessId=1000+$index;appStartUtc=$base.AddSeconds($index+1).ToString('O');appPath=[IO.Path]::GetFullPath($appPath);appSha256=$appStable.Sha256;coreProcessId=2000;coreStartUtc=$base.ToString('O');corePath=[IO.Path]::GetFullPath($corePath);coreSha256=$coreStable.Sha256;serverProcessId=$PID;serverStartUtc=$base.AddMinutes(-1).ToString('O');serverPath=$serverPath;serverSha256=$serverSha;nativeProcessRenderMode=$native;nativeTier=if($mode-ceq'a'){1}else{0};preFirstHwndProof=$true;observedUtc=$base.AddMinutes($index+1).ToString('O');boundary='PackagedCompatibilityPerformance-NativeTierComparator-NoPerFrameGpuOrRuntimeCredit'}})
        $sidecar=[pscustomobject][ordered]@{schemaVersion=3;evidenceClassification='PackagedCompatibilityPerformanceTelemetryBinding-NoRuntimeCredit';runNonce=('1'*32);source=[pscustomobject][ordered]@{commitSha=$repo.Commit;treeSha=$repo.Tree};session=[pscustomobject][ordered]@{kind='LocalConsole';name='Issue10PerformanceComparator';sessionId=1L;transport='Physical';elevated=$false;userScope='SingleUser'};package=[pscustomobject][ordered]@{identitySha256=$receiptCanonical.ReceiptSha256;identityFileSha256=$receiptStable.Sha256;profileFileSha256=$profileIdentity.FileSha256;archiveSha256=$archiveStable.Sha256;manifestSha256=$manifestStable.Sha256;appSha256=$appStable.Sha256;coreSha256=$coreStable.Sha256};rawSource=[pscustomobject][ordered]@{relativePath=([IO.Path]::GetFullPath($rawDest).Substring([IO.Path]::GetFullPath($tempRoot).TrimEnd('\','/').Length).TrimStart('\','/').Replace('\','/'));bytes=[long]$rawPublisherStable.Bytes;fileSha256=$rawPublisherStable.Sha256;canonicalSha256=$rawPublisherCanonical};acquisitions=$acquisitions;evidenceBoundary=[pscustomobject][ordered]@{actualHerdrRuntime='NOT_OBSERVED';release='NOT_OBSERVED';creditGranted=$false}}
        if($null-ne$MutateSidecar){&$MutateSidecar $sidecar}
        Write-RendererPackageCanonicalJson $sidecar $bindingPath $repoRoot;$bindingStable=Get-RendererStableFileIdentity $tempRoot $bindingPath 'Publisher binding'
        $commit=[pscustomobject][ordered]@{schemaVersion=1;kind='issue10-performance-transaction-commit';runNonce=('1'*32);raw=[pscustomobject][ordered]@{fileName=[IO.Path]::GetFileName($rawDest);bytes=[long]$rawPublisherStable.Bytes;sha256=$rawPublisherStable.Sha256};binding=[pscustomobject][ordered]@{fileName=[IO.Path]::GetFileName($bindingPath);bytes=[long]$bindingStable.Bytes;sha256=$bindingStable.Sha256};creditGranted=$false}
        if($null-ne$MutateCommit){&$MutateCommit $commit}
        Write-RendererPackageCanonicalJson $commit $commitPath $repoRoot
        $invoke={&$script:PublisherPath -RawPerformancePath $rawDest -PerformanceBindingPath $bindingPath -PerformanceCommitPath $commitPath -DestinationDirectory $destination -EvidenceRoot $tempRoot -RepositoryRoot $repoRoot -RunNonce ('1'*32) -PackageIdentityPath $receiptPath -PackageArchivePath $archivePath -ExtractedPackageRoot $packageRoot -ExpectedSourceCommit $repo.Commit -ExpectedSourceTree $repo.Tree}
        if([string]::IsNullOrWhiteSpace($ExpectedPattern)){return &$invoke}
        Assert-ThrowsMatch {&$invoke|Out-Null} $ExpectedPattern $Name
        if(Test-Path -LiteralPath $destination){throw "Publisher hostile '$Name' exposed a final destination."}
    }
    $published=Invoke-PublisherFixture 'positive'
    if($published.SchemaVersion-ne4-or$published.CreditGranted-or-not(Test-Path -LiteralPath $published.PerformanceReceiptPath -PathType Leaf)){throw 'Production publisher positive fixture did not produce an exact schema-v4 no-credit receipt.'}
    Pass-PositiveCase 'production publisher fully validates and atomically publishes exact performance evidence'
    $null=Invoke-PublisherFixture 'publisher rejects transplanted profile hash' {param($s)$s.package.profileFileSha256=('9'*64)} $null 'package binding is stale'
    $null=Invoke-PublisherFixture 'publisher rejects transplanted manifest hash' {param($s)$s.package.manifestSha256=('9'*64)} $null 'package binding is stale'
    $null=Invoke-PublisherFixture 'publisher rejects commit raw fileName transplant' $null {param($c)$c.raw.fileName='other.json'} 'exact leaf names'
    $null=Invoke-PublisherFixture 'publisher reaches shared full acquisition shape guard' {param($s)$s.acquisitions[0].PSObject.Properties.Remove('nativeTier')} $null 'must contain exactly|nativeTier'

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
        $commandParams.ContainsKey('TestOnlyProcessIdentityProvider') -or
        $commandParams.ContainsKey('LiveTelemetryProvider') -or
        $commandParams.ContainsKey('AppProcessId')) {
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

    # 12. Arbitrary caller telemetry is rejected before any process launch.
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
            -CoreProcessId 0
    } "parameter cannot be found.*LiveTelemetryProvider" 'live mode API has no arbitrary caller telemetry parameter' $negProc1Dest

    # 13. Live mode invalid Core PID
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
            -RunNonce ([Guid]::NewGuid().ToString('N')) `
            -CoreProcessId 0 `
            -BindingDestinationPath (Join-Path $tempRoot 'perf\neg-proc-ident-binding.json')
    } 'requires a positive CoreProcessId' 'live mode invalid Core PID produces zero output' $negProcIdentDest

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
            -RunNonce ([Guid]::NewGuid().ToString('N')) `
            -CoreProcessId 999998 `
            -BindingDestinationPath (Join-Path $tempRoot 'perf\neg-proc2-binding.json')
    } 'Unable to connect to target Core process' 'live mode non-existent Core process ID produces zero output' $negProc2Dest

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
            -CoreProcessId 456
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
            -CoreProcessId 456
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
            -CoreProcessId 456
    } 'Manifest/package-root inventories are not exact and coherent|Package App/Core bytes changed after package validation|hash.*mismatch' 'package component hash mismatch fails closed with zero output' $negPkgTamperDest
    # Restore app binary
    [IO.File]::WriteAllBytes($tamperedAppPath, [Text.Encoding]::UTF8.GetBytes('app-binary'))

    # Exercise the exact production CurrentUserOnly pipe and client-PID guard.
    $pipeNonce=[Guid]::NewGuid().ToString('N');$pipeName="herdrops-v02-issue10-perf-$pipeNonce-0";$pipe=New-RendererTargetObservationPipe $pipeName
    $clientScript=Join-Path $tempRoot 'pipe-client.ps1';[IO.File]::WriteAllText($clientScript,@'
param([string]$Name)
$pipe=[IO.Pipes.NamedPipeClientStream]::new('.', $Name, [IO.Pipes.PipeDirection]::InOut, [IO.Pipes.PipeOptions]::None)
try{$pipe.Connect(10000);$writer=[IO.StreamWriter]::new($pipe,[Text.UTF8Encoding]::new($false),65536,$true);$writer.AutoFlush=$true;$writer.WriteLine('{"kind":"live-production-pipe-probe"}');Start-Sleep -Milliseconds 500}finally{$pipe.Dispose()}
'@,(New-Object Text.UTF8Encoding($false)))
    $client=Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile','-File',$clientScript,$pipeName) -PassThru -WindowStyle Hidden
    try{$actualClientPid=Wait-RendererTargetObservationPipe $pipe 15;Assert-RendererPipeClientProcessId $actualClientPid $client.Id 'Performance telemetry';$reader=[IO.StreamReader]::new($pipe,(New-Object Text.UTF8Encoding($false,$true)),$false,65536,$true);$line=Read-RendererTargetPipeLine $reader 10;if($line-cne'{"kind":"live-production-pipe-probe"}'){throw 'Production pipe probe payload changed.'};Pass-PositiveCase 'real CurrentUserOnly production pipe binds the launched client PID and transports a frame';Assert-ThrowsMatch {Assert-RendererPipeClientProcessId $actualClientPid ($client.Id+1) 'Performance telemetry'} 'not connected by the launched packaged App PID' 'production pipe rejects transplanted client PID'}finally{if($null-ne$reader){$reader.Dispose()};$pipe.Dispose();if(-not$client.HasExited){Stop-Process -Id $client.Id -Force};$client.Dispose()}

    # Execute the exact production directory transaction used for raw+binding.
    . (Join-Path $PSScriptRoot 'lib\V02PerformanceTransaction.ps1')
    $transactionRoot=Join-Path $tempRoot 'transaction';New-Item -ItemType Directory -Path $transactionRoot|Out-Null
    $rawBytes=[Text.Encoding]::UTF8.GetBytes("raw`n");$bindingBytes=[Text.Encoding]::UTF8.GetBytes("binding`n");$commitBytes=[Text.Encoding]::UTF8.GetBytes("commit`n")
    $goodTransaction=Join-Path $transactionRoot 'good';$tx=Publish-V02PerformanceTransaction $goodTransaction $tempRoot 'raw.json' $rawBytes 'binding.json' $bindingBytes $commitBytes
    if(-not(Test-Path -LiteralPath $tx.RawPath -PathType Leaf)-or-not(Test-Path -LiteralPath $tx.BindingPath -PathType Leaf)-or-not(Test-Path -LiteralPath $tx.CommitPath -PathType Leaf)){throw 'Production performance transaction did not publish all three files atomically.'};Pass-PositiveCase 'production raw, binding, and commit marker publish as one directory transaction'
    Assert-ThrowsMatch {Publish-V02PerformanceTransaction $goodTransaction $tempRoot 'raw.json' $rawBytes 'binding.json' $bindingBytes $commitBytes|Out-Null} 'already exists' 'production transaction no-clobber preserves committed directory'
    foreach($fault in @('AfterRawStage','AfterBindingStage','AfterCommitMarkerStage','BeforeCommit')){$faultDest=Join-Path $transactionRoot $fault;Assert-ThrowsMatch {Publish-V02PerformanceTransaction $faultDest $tempRoot 'raw.json' $rawBytes 'binding.json' $bindingBytes $commitBytes $fault|Out-Null} 'Injected performance transaction failure' "production transaction $fault fault rolls back";if(Test-Path -LiteralPath $faultDest){throw "Production transaction $fault exposed a partial directory."};if(@(Get-ChildItem -LiteralPath $transactionRoot -Force|Where-Object Name -Like ".$fault.stage-*").Count){throw "Production transaction $fault leaked staging."}}

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
