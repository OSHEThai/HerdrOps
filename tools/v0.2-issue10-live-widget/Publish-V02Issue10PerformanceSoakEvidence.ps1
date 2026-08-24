#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$AcSoakMeasurementPath,
    [Parameter(Mandatory = $true)][string]$BatterySoakMeasurementPath,
    [Parameter(Mandatory = $true)][string]$RawPerformancePath,
    [Parameter(Mandatory = $true)][string]$PerformanceBindingPath,
    [Parameter(Mandatory = $true)][string]$PerformanceCommitPath,
    [Parameter(Mandatory = $true)][string]$DestinationDirectory,
    [Parameter(Mandatory = $true)][string]$EvidenceRoot,
    [Parameter(Mandatory = $true)][string]$RepositoryRoot,
    [Parameter(Mandatory = $true)][string]$RunNonce,
    [Parameter(Mandatory = $true)][string]$PackageIdentityPath,
    [Parameter(Mandatory = $true)][string]$PackageArchivePath,
    [Parameter(Mandatory = $true)][string]$ExtractedPackageRoot,
    [Parameter(Mandatory = $true)][string]$ExpectedSourceCommit,
    [Parameter(Mandatory = $true)][string]$ExpectedSourceTree,
    [string]$TestFaultInjectionStage = 'None'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$rendererRoot = Join-Path $PSScriptRoot '..\v0.2-renderer-compatibility'
. (Join-Path $rendererRoot 'RendererCompatibility.Common.ps1')
. (Join-Path $PSScriptRoot '..\lib\V02RuntimePackageBinding.ps1')

function Assert-ExactProperties {
    param($Value,[string[]]$Names,[string]$Context)
    if ($null -eq $Value -or $Value -isnot [psobject]) { throw "$Context is not an object." }
    $actual = @($Value.PSObject.Properties.Name)
    if ($actual.Count -ne $Names.Count) { throw "$Context must contain exactly: $($Names -join ', ')." }
    foreach ($name in $Names) {
        if (@($Value.PSObject.Properties | Where-Object { [StringComparer]::Ordinal.Equals($_.Name,$name) }).Count -ne 1) {
            throw "$Context must contain one case-sensitive '$name' property."
        }
    }
}

function Resolve-ContainedPath {
    param([string]$Root,[string]$Path,[string]$Context)
    $full = if ([IO.Path]::IsPathRooted($Path)) { [IO.Path]::GetFullPath($Path) } else { [IO.Path]::GetFullPath((Join-Path $Root $Path)) }
    if ($full -cne $Root -and -not $full.StartsWith($Root + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) {
        throw "$Context escaped the evidence root."
    }
    Assert-RendererNonReparsePath -Root $Root -Path $full -Context $Context
    $full
}

function Read-StrictCanonicalJson {
    param([string]$Path,[string]$Context)
    $held = Get-RendererStableFileIdentity $script:EvidenceRootFull $Path $Context -IncludeBytes -KeepOpen
    try {
        $json = (New-Object Text.UTF8Encoding($false,$true)).GetString($held.Content)
        $value = ConvertFrom-StrictHumanDesignReviewJson -Json $json -Description $Context
        if ($PSVersionTable.PSVersion.Major -ge 7 -and (Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) {
            $value = $json | ConvertFrom-Json -DateKind String
        }
        $canonical = ConvertTo-RendererCanonicalJson $value $RepositoryRoot
        if ($json.TrimEnd("`r","`n") -cne $canonical) { throw "$Context is not canonical JSON." }
        [pscustomobject]@{ Value=$value; Held=$held; CanonicalSha256=(Get-HumanDesignReviewSha256ForText $canonical) }
    } catch {
        $held.Stream.Dispose()
        throw
    }
}

function Get-RelativePath {
    param([string]$Path,[string]$Context)
    $full = Resolve-ContainedPath $script:EvidenceRootFull $Path $Context
    $relative = $full.Substring($script:EvidenceRootFull.Length).TrimStart('\','/').Replace('\','/')
    Assert-RendererRelativePath $relative "$Context relative path"
    $relative
}

function Assert-SoakMeasurement {
    param($Read,[string]$Power)
    $value = $Read.Value
    Assert-ExactProperties $value @('schemaVersion','caseId','evidenceClassification','powerSource','totalBins','binDurationMinutes','aggregateStatus','governance','source','session','soakBins','observations','rawSamples','latencyMeasurement','evidenceBoundary','package','runNonce') "$Power soak measurement"
    Assert-RendererPositiveInteger $value.schemaVersion "$Power soak schemaVersion";Assert-RendererPositiveInteger $value.totalBins "$Power soak totalBins";Assert-RendererPositiveInteger $value.binDurationMinutes "$Power soak binDurationMinutes"
    if ([int]$value.schemaVersion-ne2-or$value.evidenceClassification -cne 'PackagedCompatibilitySoak' -or $value.powerSource -cne $Power -or
        [int]$value.totalBins -ne 12 -or [int]$value.binDurationMinutes -ne 5 -or $value.aggregateStatus -cne 'PASS') {
        throw "$Power soak measurement is not a governed 60-minute PASS output."
    }
    if ([string]$value.runNonce -cne $RunNonce) { throw "$Power soak measurement runNonce is not bound to this Issue #10 invocation." }
    Assert-ExactProperties $value.source @('commitSha','treeSha') "$Power soak source"
    if ($value.source.commitSha -cne $ExpectedSourceCommit -or $value.source.treeSha -cne $ExpectedSourceTree) { throw "$Power soak source binding is not exact." }
    Assert-ExactProperties $value.package @('receiptSha256','archiveSha256','appSha256','coreSha256') "$Power soak package"
    foreach ($pair in @(@('receiptSha256',$script:Package.ReceiptSha256),@('archiveSha256',$script:Package.ArchiveSha256),@('appSha256',$script:Package.AppSha256),@('coreSha256',$script:Package.CoreSha256))) {
        if ([string]$value.package.($pair[0]) -cne [string]$pair[1]) { throw "$Power soak package $($pair[0]) binding is not exact." }
    }
    Assert-ExactProperties $value.session @('kind','sessionId','transport','powerSource','thermalState','elevated','userScope') "$Power soak session"
    Assert-RendererNonnegativeInteger $value.session.sessionId "$Power soak sessionId";Assert-RendererBoolean $value.session.elevated "$Power soak session elevated"
    if($value.session.kind-cne'LocalConsole'-or[long]$value.session.sessionId-lt0-or$value.session.transport-cne'Physical'-or$value.session.powerSource-cne$Power-or$value.session.thermalState-cne'Nominal'-or[bool]$value.session.elevated-or$value.session.userScope-cne'SingleUser'){throw "$Power soak session is not the governed local physical session."}
    Assert-ExactProperties $value.evidenceBoundary @('evidenceClass','actualHerdrRuntime','humanReview','release','creditGranted') "$Power soak evidence boundary"
    if ($value.evidenceBoundary.evidenceClass -cne 'PackagedCompatibilitySoak' -or
        $value.evidenceBoundary.actualHerdrRuntime -cne 'NOT_OBSERVED' -or
        $value.evidenceBoundary.humanReview -cne 'NOT_OBSERVED' -or
        $value.evidenceBoundary.release -cne 'NOT_OBSERVED' -or
        $value.evidenceBoundary.creditGranted -isnot [bool] -or [bool]$value.evidenceBoundary.creditGranted) { throw "$Power soak output inflated acceptance credit or changed its evidence class." }
    $bins = @($value.soakBins)
    if ($bins.Count -ne 12) { throw "$Power soak output must contain exactly 12 bins." }
    $samples = @($value.rawSamples)
    if ($samples.Count -ne 3600) { throw "$Power soak output must contain exactly 3600 one-second raw samples." }
    $observations = @($value.observations)
    if ($observations.Count -ne 12) { throw "$Power soak output must contain exactly 12 bin observations." }
    # The collector targets one sample per second. Admit at most 250 ms of
    # scheduler lateness/jitter while proving every adjacent interval and each
    # 300-row (five-minute) boundary/span; a correct final duration alone is not
    # sufficient because compressed or front/back-loaded rows are not a soak.
    $minimumCadenceMilliseconds=750.0;$maximumCadenceMilliseconds=1250.0;$maximumCrossClockJitterMilliseconds=250.0
    $minimumBinSpanMilliseconds=298750.0;$maximumBinSpanMilliseconds=299250.0
    $timeline=@();$firstObserved=[DateTimeOffset]::MinValue;$previousObserved=[DateTimeOffset]::MinValue;$previousElapsed=-1L
    for ($index=0;$index-lt12;$index++) {
        $bin=$bins[$index]
        Assert-ExactProperties $bin @('powerSource','ordinal','durationMinutes','observedUtc','workingSetStartBytes','workingSetEndBytes','rendererStable') "$Power soak bin $index"
        Assert-RendererNonnegativeInteger $bin.ordinal "$Power soak bin $index ordinal";Assert-RendererPositiveInteger $bin.durationMinutes "$Power soak bin $index durationMinutes";Assert-RendererBoolean $bin.rendererStable "$Power soak bin $index rendererStable"
        if ($bin.powerSource -cne $Power -or [int]$bin.ordinal -ne $index -or [int]$bin.durationMinutes -ne 5 -or -not [bool]$bin.rendererStable) { throw "$Power soak bin $index is invalid." }
        Assert-RendererUtc $bin.observedUtc "$Power soak bin $index observedUtc"
        Assert-RendererNonnegativeInteger $bin.workingSetStartBytes "$Power soak bin $index start"
        Assert-RendererNonnegativeInteger $bin.workingSetEndBytes "$Power soak bin $index end"
        $binSamples = @($samples | Where-Object { [int]$_.binOrdinal -eq $index })
        if ($binSamples.Count -ne 300) { throw "$Power soak bin $index must contain exactly 300 raw samples." }
        $binFirstObserved=[DateTimeOffset]::MinValue;$binLastObserved=[DateTimeOffset]::MinValue;$binFirstElapsed=-1L;$binLastElapsed=-1L
        for ($sampleIndex=0;$sampleIndex-lt300;$sampleIndex++) {
            $sample=$binSamples[$sampleIndex]
            $packetSequenceNumber=($index*300)+$sampleIndex
            if (-not [object]::ReferenceEquals($sample,$samples[$packetSequenceNumber]) -and
                ([int]$samples[$packetSequenceNumber].binOrdinal-ne$index-or[int]$samples[$packetSequenceNumber].sampleIndex-ne$sampleIndex)) { throw "$Power soak raw samples are not in strict global packet order." }
            Assert-ExactProperties $sample @('binOrdinal','sampleIndex','observedUtc','elapsedMilliseconds','powerSource','appWorkingSetBytes','appPrivateBytes','coreWorkingSetBytes','corePrivateBytes','combinedWorkingSetBytes','combinedCpuBasisPoints','latencyUpdateCount','uiStallP95Microseconds','uiStallMaximumMicroseconds','rendererStable') "$Power soak bin $index sample $sampleIndex"
            Assert-RendererNonnegativeInteger $sample.binOrdinal "$Power soak bin $index sample $sampleIndex binOrdinal";Assert-RendererNonnegativeInteger $sample.sampleIndex "$Power soak bin $index sample $sampleIndex sampleIndex";Assert-RendererBoolean $sample.rendererStable "$Power soak bin $index sample $sampleIndex rendererStable"
            if ([int]$sample.binOrdinal -ne $index -or [int]$sample.sampleIndex -ne $sampleIndex -or $sample.powerSource -cne $Power -or -not [bool]$sample.rendererStable) { throw "$Power soak bin $index sample $sampleIndex identity is invalid." }
            Assert-RendererUtc $sample.observedUtc "$Power soak bin $index sample $sampleIndex observedUtc"
            foreach ($name in @('elapsedMilliseconds','appWorkingSetBytes','appPrivateBytes','coreWorkingSetBytes','corePrivateBytes','combinedWorkingSetBytes','combinedCpuBasisPoints','latencyUpdateCount','uiStallP95Microseconds','uiStallMaximumMicroseconds')) { Assert-RendererNonnegativeInteger $sample.$name "$Power soak bin $index sample $sampleIndex $name" }
            $observed=[DateTimeOffset]::ParseExact([string]$sample.observedUtc,'O',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
            $minimumElapsed=[long](($packetSequenceNumber+1)*1000)
            $elapsed=[long]$sample.elapsedMilliseconds
            if($observed-le$previousObserved-or$elapsed-le$previousElapsed-or$elapsed-lt$minimumElapsed){throw "$Power soak raw sample chronology/cadence is invalid."}
            if($previousElapsed-ge0){
                $elapsedDelta=[double]($elapsed-$previousElapsed);$utcDelta=($observed-$previousObserved).TotalMilliseconds
                if($elapsedDelta-lt$minimumCadenceMilliseconds-or$elapsedDelta-gt$maximumCadenceMilliseconds-or$utcDelta-lt$minimumCadenceMilliseconds-or$utcDelta-gt$maximumCadenceMilliseconds-or[Math]::Abs($utcDelta-$elapsedDelta)-gt$maximumCrossClockJitterMilliseconds){throw "$Power soak raw timeline one-second adjacent cadence or five-minute bin boundary/span is invalid."}
            }
            if($firstObserved-eq[DateTimeOffset]::MinValue){$firstObserved=$observed}
            if($sampleIndex-eq0){$binFirstObserved=$observed;$binFirstElapsed=$elapsed};$binLastObserved=$observed;$binLastElapsed=$elapsed
            $previousObserved=$observed;$previousElapsed=$elapsed
            $timeline += [pscustomobject][ordered]@{
                binOrdinal=[int]$index;sampleIndex=[int]$sampleIndex;packetSequenceNumber=[int]$packetSequenceNumber
                observedUtc=[string]$sample.observedUtc;elapsedMilliseconds=[long]$sample.elapsedMilliseconds;powerSource=[string]$sample.powerSource
                appWorkingSetBytes=[long]$sample.appWorkingSetBytes;appPrivateBytes=[long]$sample.appPrivateBytes
                coreWorkingSetBytes=[long]$sample.coreWorkingSetBytes;corePrivateBytes=[long]$sample.corePrivateBytes
                combinedWorkingSetBytes=[long]$sample.combinedWorkingSetBytes;combinedCpuBasisPoints=[long]$sample.combinedCpuBasisPoints
                latencyUpdateCount=[int]$sample.latencyUpdateCount;uiStallP95Microseconds=[long]$sample.uiStallP95Microseconds
                uiStallMaximumMicroseconds=[long]$sample.uiStallMaximumMicroseconds;rendererStable=[bool]$sample.rendererStable
            }
            if ([long]$sample.combinedWorkingSetBytes -ne ([long]$sample.appWorkingSetBytes + [long]$sample.coreWorkingSetBytes) -or
                [long]$sample.combinedWorkingSetBytes -gt 267386880 -or [long]$sample.combinedCpuBasisPoints -gt 100 -or
                [long]$sample.uiStallP95Microseconds -gt 50000 -or
                [long]$sample.uiStallMaximumMicroseconds -gt 100000) { throw "$Power soak bin $index sample $sampleIndex breached a governed raw metric or aggregate identity." }
        }
        $expectedBinFirstElapsed=[long](($index*300+1)*1000);$expectedBinLastElapsed=[long](($index+1)*300*1000)
        $binElapsedSpan=[double]($binLastElapsed-$binFirstElapsed);$binUtcSpan=($binLastObserved-$binFirstObserved).TotalMilliseconds
        if($binFirstElapsed-lt$expectedBinFirstElapsed-or$binFirstElapsed-gt($expectedBinFirstElapsed+250L)-or$binLastElapsed-lt$expectedBinLastElapsed-or$binLastElapsed-gt($expectedBinLastElapsed+250L)-or$binElapsedSpan-lt$minimumBinSpanMilliseconds-or$binElapsedSpan-gt$maximumBinSpanMilliseconds-or$binUtcSpan-lt$minimumBinSpanMilliseconds-or$binUtcSpan-gt$maximumBinSpanMilliseconds-or[string]$bin.observedUtc-cne[string]$binSamples[0].observedUtc){throw "$Power soak raw timeline one-second adjacent cadence or five-minute bin boundary/span is invalid."}
        if ([long]$bin.workingSetStartBytes -ne [long]$binSamples[0].combinedWorkingSetBytes -or [long]$bin.workingSetEndBytes -ne [long]$binSamples[-1].combinedWorkingSetBytes) { throw "$Power soak bin $index is not derived from its held raw samples." }
        $observation=$observations[$index]
        Assert-ExactProperties $observation @('ordinal','observedUtc','outcome','notes') "$Power soak observation $index"
        Assert-RendererNonnegativeInteger $observation.ordinal "$Power soak observation $index ordinal"
        if ([int]$observation.ordinal -ne $index -or $observation.observedUtc -cne $bin.observedUtc -or $observation.outcome -cne 'PASS') { throw "$Power soak observation $index is not bound to its bin." }
    }
    $stopwatchSpan=[double]($previousElapsed-[long]$timeline[0].elapsedMilliseconds);$utcSpan=($previousObserved-$firstObserved).TotalMilliseconds
    if($previousElapsed-lt3600000L-or[Math]::Abs($utcSpan-$stopwatchSpan)-gt5000.0){throw "$Power soak raw timeline does not prove the governed 60-minute duration/cadence or cross-clock consistency."}
    $measurement=$value.latencyMeasurement
    Assert-ExactProperties $measurement @('measurement','baselineStateSequence','finalStateSequence','baselineRecordCount','finalRecordCount','minimumUniqueSampleCount','uniqueSampleCount','requiredCoveredBinCount','coveredBinCount','p95Microseconds','targetMaximumMicroseconds','status','samples') "$Power soak latency measurement"
    foreach($name in @('baselineStateSequence','finalStateSequence','baselineRecordCount','finalRecordCount','minimumUniqueSampleCount','uniqueSampleCount','requiredCoveredBinCount','coveredBinCount','p95Microseconds','targetMaximumMicroseconds')){if($measurement.$name-isnot[int]-and$measurement.$name-isnot[long]){throw "$Power soak latency summary $name must be a native integer."}}
    $latencyItems=@($measurement.samples)
    if([long]$measurement.baselineStateSequence-lt-1L-or[long]$measurement.finalStateSequence-lt0L-or[long]$measurement.finalStateSequence-le[long]$measurement.baselineStateSequence){throw "$Power soak latency state-sequence boundary is outside the producer domain."}
    if([long]$measurement.baselineRecordCount-lt0L-or[long]$measurement.finalRecordCount-lt[long]$measurement.baselineRecordCount){throw "$Power soak latency recorded-count boundary is outside the producer domain."}
    if($measurement.measurement-cne'CoreAcceptedStateUtcToWpfAppliedUtc'-or[long]$measurement.minimumUniqueSampleCount-ne20-or[long]$measurement.uniqueSampleCount-ne$latencyItems.Count-or$latencyItems.Count-lt20-or[long]$measurement.requiredCoveredBinCount-ne12-or[long]$measurement.coveredBinCount-ne12-or[long]$measurement.targetMaximumMicroseconds-ne250000-or$measurement.status-cne'PASS'){throw "$Power soak latency measurement summary is invalid."}
    if([long]$measurement.finalRecordCount-[long]$measurement.baselineRecordCount-ne$latencyItems.Count){throw "$Power soak latency recorded-count boundary omitted or added an update."}
    $state=@{};$correlation=@{};$covered=@{};$packetCounts=@{};$previous=[long]$measurement.baselineStateSequence;$values=@()
    foreach($item in $latencyItems){
        Assert-ExactProperties $item @('binOrdinal','sampleIndex','packetSequenceNumber','stateSequence','eventCount','envelopeSequence','envelopeCorrelationId','stateSha256','updateKind','coreAcceptedStateUtc','ipcSentUtc','wpfAppliedUtc','latencyMicroseconds') "$Power soak latency sample"
        foreach($name in @('binOrdinal','sampleIndex','packetSequenceNumber','stateSequence','eventCount','envelopeSequence','latencyMicroseconds')){Assert-RendererNonnegativeInteger $item.$name "$Power soak latency sample $name"}
        $seq=[long]$item.stateSequence;$corr=[string]$item.envelopeCorrelationId
        if($seq-le$previous-or[long]$item.envelopeSequence-ne$seq-or$state.ContainsKey([string]$seq)-or$correlation.ContainsKey($corr)-or$item.updateKind-cnotin@('Snapshot','Delta')){throw "$Power soak latency sample replay/order/identity is invalid."}
        $guid=[Guid]::Empty;if(-not[Guid]::TryParseExact($corr,'D',[ref]$guid)-or$guid-eq[Guid]::Empty){throw "$Power soak latency correlation is invalid."};Assert-RendererSha $item.stateSha256 "$Power soak latency state hash"
        foreach($name in @('coreAcceptedStateUtc','ipcSentUtc','wpfAppliedUtc')){Assert-RendererUtc $item.$name "$Power soak latency $name"}
        $accepted=[DateTimeOffset]$item.coreAcceptedStateUtc;$sent=[DateTimeOffset]$item.ipcSentUtc;$applied=[DateTimeOffset]$item.wpfAppliedUtc;$derived=[long][Math]::Round(($applied-$accepted).TotalMilliseconds*1000.0)
        $expectedPacket=([int]$item.binOrdinal*300)+[int]$item.sampleIndex
        if($sent-lt$accepted-or$applied-lt$sent-or[long]$item.latencyMicroseconds-ne$derived-or[int]$item.binOrdinal-lt0-or[int]$item.binOrdinal-ge12-or[int]$item.sampleIndex-lt0-or[int]$item.sampleIndex-ge300-or[long]$item.packetSequenceNumber-ne$expectedPacket){throw "$Power soak latency sample chronology/value/bin/packet mapping is invalid."}
        $packetKey=[string]$expectedPacket;if(-not$packetCounts.ContainsKey($packetKey)){$packetCounts[$packetKey]=0};$packetCounts[$packetKey]++
        $state[[string]$seq]=$true;$correlation[$corr]=$true;$covered[[string][int]$item.binOrdinal]=$true;$values+=[long]$item.latencyMicroseconds;$previous=$seq
    }
    foreach($row in $timeline){$key=[string]$row.packetSequenceNumber;$actual=if($packetCounts.ContainsKey($key)){[int]$packetCounts[$key]}else{0};if($actual-ne[int]$row.latencyUpdateCount){throw "$Power soak raw latencyUpdateCount is not bound to its packet latency records."}}
    if($previous-ne[long]$measurement.finalStateSequence-or$covered.Count-ne12){throw "$Power soak latency final sequence or bin coverage is invalid."}
    $sorted=@($values|Sort-Object);$p95=[long]$sorted[[Math]::Ceiling($sorted.Count*0.95)-1]
    if($p95-ne[long]$measurement.p95Microseconds-or$p95-gt250000){throw "$Power soak latency P95 is invalid or breached."}
    [pscustomobject][ordered]@{Bins=@($bins|ForEach-Object{Copy-RendererValue $_});Timeline=[pscustomobject][ordered]@{sampleIntervalMilliseconds=1000;sampleCount=3600;finalElapsedMilliseconds=[long]$previousElapsed;samples=@($timeline)};Latency=(Copy-RendererValue $measurement)}
}

function Assert-PerformanceBinding {
    param($Read,$RawRead,[string]$RawPath)
    $value=$Read.Value
    Assert-ExactProperties $value @('schemaVersion','evidenceClassification','runNonce','source','package','rawSource','acquisitions','evidenceBoundary') 'Performance telemetry binding'
    Assert-RendererPositiveInteger $value.schemaVersion 'Performance telemetry binding schemaVersion'
    if([int]$value.schemaVersion-ne1-or$value.evidenceClassification-cne'PackagedCompatibilityPerformanceTelemetryBinding-NoRuntimeCredit'-or$value.runNonce-cne$RunNonce){throw 'Performance telemetry binding identity is invalid.'}
    Assert-ExactProperties $value.source @('commitSha','treeSha') 'Performance telemetry binding source'
    if($value.source.commitSha-cne$ExpectedSourceCommit-or$value.source.treeSha-cne$ExpectedSourceTree){throw 'Performance telemetry binding source is stale.'}
    Assert-ExactProperties $value.package @('identitySha256','identityFileSha256','profileFileSha256','archiveSha256','manifestSha256','appSha256','coreSha256') 'Performance telemetry binding package'
    if($value.package.identitySha256-cne$script:Package.ReceiptSha256-or$value.package.identityFileSha256-cne$script:Package.IdentityFileSha256-or$value.package.profileFileSha256-cne$script:Package.ProfileFileSha256-or$value.package.archiveSha256-cne$script:Package.ArchiveSha256-or$value.package.manifestSha256-cne$script:Package.ManifestSha256-or$value.package.appSha256-cne$script:Package.AppSha256-or$value.package.coreSha256-cne$script:Package.CoreSha256){throw 'Performance telemetry binding package is stale.'}
    Assert-ExactProperties $value.rawSource @('relativePath','bytes','fileSha256','canonicalSha256') 'Performance telemetry binding raw source'
    Assert-RendererPositiveInteger $value.rawSource.bytes 'Performance telemetry binding raw source bytes'
    if($value.rawSource.relativePath-cne(Get-RelativePath $RawPath 'Raw performance observations')-or[long]$value.rawSource.bytes-ne[long]$RawRead.Held.Bytes-or$value.rawSource.fileSha256-cne$RawRead.Held.Sha256-or$value.rawSource.canonicalSha256-cne$RawRead.CanonicalSha256){throw 'Performance telemetry binding does not bind the held raw observations.'}
    $items=@($value.acquisitions);if($items.Count-ne24){throw 'Performance telemetry binding must contain exactly 24 acquisitions.'}
    $appIdentities=@{};$coreIdentity=$null;$serverIdentity=$null;$previousObserved=[DateTimeOffset]::MinValue
    for($i=0;$i-lt24;$i++){
        $item=$items[$i];Assert-ExactProperties $item @('sequenceNumber','order','isWarmup','repetitionOrdinal','semanticMode','requestedMode','appProcessId','appStartUtc','appPath','appSha256','coreProcessId','coreStartUtc','corePath','coreSha256','serverProcessId','serverStartUtc','serverPath','serverSha256','nativeProcessRenderMode','nativeTier','preFirstHwndProof','observedUtc','boundary') "Performance acquisition $i"
        foreach($name in @('sequenceNumber','repetitionOrdinal','nativeTier')){Assert-RendererNonnegativeInteger $item.$name "Performance acquisition $i $name"};foreach($name in @('appProcessId','coreProcessId','serverProcessId')){Assert-RendererPositiveInteger $item.$name "Performance acquisition $i $name"};Assert-RendererBoolean $item.isWarmup "Performance acquisition $i isWarmup";Assert-RendererBoolean $item.preFirstHwndProof "Performance acquisition $i preFirstHwndProof"
        $order=if($i-lt12){'AB'}else{'BA'};$within=$i%12;$pair=[int][Math]::Floor($within/2);$mode=if($order-ceq'AB'){if($within%2-eq0){'a'}else{'b'}}else{if($within%2-eq0){'b'}else{'a'}};$warm=($pair-eq0);$rep=if($warm){0}else{$pair-1};$requested=if($mode-ceq'a'){'Hardware'}else{'SoftwareOnly'};$native=if($mode-ceq'a'){'Default'}else{'SoftwareOnly'}
        if([int]$item.sequenceNumber-ne$i-or$item.order-cne$order-or[bool]$item.isWarmup-ne$warm-or[int]$item.repetitionOrdinal-ne$rep-or$item.semanticMode-cne$mode-or$item.requestedMode-cne$requested-or$item.nativeProcessRenderMode-cne$native-or($mode-ceq'a'-and[int]$item.nativeTier-le0)-or-not[bool]$item.preFirstHwndProof-or-not[StringComparer]::OrdinalIgnoreCase.Equals([string]$item.appPath,$script:Package.AppPath)-or$item.appSha256-cne$script:Package.AppSha256-or-not[StringComparer]::OrdinalIgnoreCase.Equals([string]$item.corePath,$script:Package.CorePath)-or$item.coreSha256-cne$script:Package.CoreSha256-or$item.boundary-cne'PackagedCompatibilityPerformance-NativeTierComparator-NoPerFrameGpuOrRuntimeCredit'){throw "Performance acquisition $i is not the governed exact-package AB/BA sequence."}
        Assert-RendererUtc $item.appStartUtc "Performance acquisition $i App start";Assert-RendererUtc $item.coreStartUtc "Performance acquisition $i Core start";Assert-RendererUtc $item.serverStartUtc "Performance acquisition $i server start";Assert-RendererUtc $item.observedUtc "Performance acquisition $i observation";if([int]$item.appProcessId-le0-or[int]$item.coreProcessId-le0-or[int]$item.serverProcessId-le0){throw "Performance acquisition $i process PID is invalid."}
        $appStart=[DateTimeOffset]::Parse([string]$item.appStartUtc);$coreStart=[DateTimeOffset]::Parse([string]$item.coreStartUtc);$serverStart=[DateTimeOffset]::Parse([string]$item.serverStartUtc);$observed=[DateTimeOffset]::Parse([string]$item.observedUtc)
        if($appStart-ge$observed-or$coreStart-ge$observed-or$serverStart-ge$observed-or$observed-le$previousObserved){throw "Performance acquisition $i chronology is invalid."};$previousObserved=$observed
        $appKey=([string][int]$item.appProcessId)+'|'+$appStart.ToUniversalTime().ToString('O');if($appIdentities.ContainsKey($appKey)){throw "Performance acquisition $i reused an App PID/start identity."};$appIdentities[$appKey]=$true
        $thisCore=([string][int]$item.coreProcessId)+'|'+$coreStart.ToUniversalTime().ToString('O')+'|'+[string]$item.corePath+'|'+[string]$item.coreSha256;if($null-eq$coreIdentity){$coreIdentity=$thisCore}elseif($thisCore-cne$coreIdentity){throw "Performance acquisition $i Core identity changed."}
        if([string]$item.serverSha256-cnotmatch'^[0-9A-F]{64}$'){throw "Performance acquisition $i server SHA is invalid."};$thisServer=([string][int]$item.serverProcessId)+'|'+$serverStart.ToUniversalTime().ToString('O')+'|'+[string]$item.serverPath+'|'+[string]$item.serverSha256;if($null-eq$serverIdentity){$serverIdentity=$thisServer}elseif($thisServer-cne$serverIdentity){throw "Performance acquisition $i server identity changed."}
    }
    Assert-ExactProperties $value.evidenceBoundary @('actualHerdrRuntime','humanReview','release','creditGranted') 'Performance telemetry binding boundary'
    Assert-RendererBoolean $value.evidenceBoundary.creditGranted 'Performance telemetry binding creditGranted'
    if($value.evidenceBoundary.actualHerdrRuntime-cne'NOT_OBSERVED'-or$value.evidenceBoundary.humanReview-cne'NOT_OBSERVED'-or$value.evidenceBoundary.release-cne'NOT_OBSERVED'-or[bool]$value.evidenceBoundary.creditGranted){throw 'Performance telemetry binding inflated acceptance credit.'}
}

$script:EvidenceRootFull = [IO.Path]::GetFullPath($EvidenceRoot).TrimEnd('\','/')
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)
Assert-RendererNonReparsePath $script:EvidenceRootFull $script:EvidenceRootFull 'Issue #10 evidence root'
if ($RunNonce -cnotmatch '^[0-9a-f]{32}$') { throw 'RunNonce must be lowercase 32-hex.' }
if ($ExpectedSourceCommit -cnotmatch '^[0-9a-f]{40}$' -or $ExpectedSourceTree -cnotmatch '^[0-9a-f]{40}$') { throw 'Expected source commit/tree must be lowercase 40-hex.' }
$git = Get-RendererGitIdentity $RepositoryRoot
if ($git.CommitSha -cne $ExpectedSourceCommit -or $git.TreeSha -cne $ExpectedSourceTree) { throw 'Repository HEAD does not equal the requested Issue #10 candidate.' }

$profilePath = Join-Path $RepositoryRoot 'tools\packaging\v0.2\package-identity-profile.json'
$script:Package = Resolve-V02RuntimePackageBinding -IdentityPath $PackageIdentityPath -ArchivePath $PackageArchivePath `
    -PackageRoot $ExtractedPackageRoot -RepositoryRoot $RepositoryRoot -ProfilePath $profilePath `
    -ExpectedSourceCommit $ExpectedSourceCommit -ExpectedSourceTree $ExpectedSourceTree
$packageHolds=@()

$destination = Resolve-ContainedPath $script:EvidenceRootFull $DestinationDirectory 'Issue #10 composed output directory'
if (Test-Path -LiteralPath $destination) { throw 'Issue #10 composed output directory already exists; refusing to clobber.' }
$parent = Split-Path -Parent $destination
if (-not (Test-Path -LiteralPath $parent -PathType Container)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
$stage = Join-Path $parent ('.issue10-compose-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($stage) | Out-Null

$reads = @()
try {
    foreach($leaf in @(
        @($script:Package.IdentityPath,$script:Package.IdentityFileSha256,'Package identity'),
        @($script:Package.ProfilePath,$script:Package.ProfileFileSha256,'Package profile'),
        @($script:Package.ArchivePath,$script:Package.ArchiveSha256,'Package archive'),
        @($script:Package.ManifestPath,$script:Package.ManifestSha256,'Package manifest'),
        @($script:Package.AppPath,$script:Package.AppSha256,'Package App'),
        @($script:Package.CorePath,$script:Package.CoreSha256,'Package Core'))){
        $hold=Get-RendererStableFileIdentity (Split-Path -Parent $leaf[0]) $leaf[0] $leaf[2] -KeepOpen
        if($hold.Sha256-cne$leaf[1]){$hold.Stream.Dispose();throw "$($leaf[2]) changed after committed package validation."};$packageHolds+=$hold
    }
    $acPath = Resolve-ContainedPath $script:EvidenceRootFull $AcSoakMeasurementPath 'AC soak measurement'
    $batteryPath = Resolve-ContainedPath $script:EvidenceRootFull $BatterySoakMeasurementPath 'Battery soak measurement'
    $rawPath = Resolve-ContainedPath $script:EvidenceRootFull $RawPerformancePath 'Raw performance observations'
    $bindingPath = Resolve-ContainedPath $script:EvidenceRootFull $PerformanceBindingPath 'Performance telemetry binding'
    $commitPath = Resolve-ContainedPath $script:EvidenceRootFull $PerformanceCommitPath 'Performance transaction commit'
    $ac = Read-StrictCanonicalJson $acPath 'AC soak measurement'; $reads += $ac
    $battery = Read-StrictCanonicalJson $batteryPath 'Battery soak measurement'; $reads += $battery
    $raw = Read-StrictCanonicalJson $rawPath 'Raw performance observations'; $reads += $raw
    $binding = Read-StrictCanonicalJson $bindingPath 'Performance telemetry binding'; $reads += $binding
    $commit = Read-StrictCanonicalJson $commitPath 'Performance transaction commit'; $reads += $commit
    $acSoak=Assert-SoakMeasurement $ac 'AC';$batterySoak=Assert-SoakMeasurement $battery 'Battery'
    $bins = @($acSoak.Bins) + @($batterySoak.Bins)
    if([long]$ac.Value.session.sessionId-ne[long]$battery.Value.session.sessionId){throw 'AC and Battery soak outputs do not bind the same session.'}
    Assert-ExactProperties $raw.Value @('orders','soakBins') 'Raw performance observations'
    Assert-PerformanceBinding $binding $raw $rawPath
    Assert-ExactProperties $commit.Value @('schemaVersion','kind','runNonce','raw','binding','creditGranted') 'Performance transaction commit'
    Assert-ExactProperties $commit.Value.raw @('fileName','bytes','sha256') 'Performance transaction raw leaf';Assert-ExactProperties $commit.Value.binding @('fileName','bytes','sha256') 'Performance transaction binding leaf'
    Assert-RendererPositiveInteger $commit.Value.schemaVersion 'Performance transaction commit schemaVersion';Assert-RendererBoolean $commit.Value.creditGranted 'Performance transaction commit creditGranted';Assert-RendererPositiveInteger $commit.Value.raw.bytes 'Performance transaction raw bytes';Assert-RendererPositiveInteger $commit.Value.binding.bytes 'Performance transaction binding bytes'
    if([int]$commit.Value.schemaVersion-ne1-or$commit.Value.kind-cne'issue10-performance-transaction-commit'-or$commit.Value.runNonce-cne$RunNonce-or[bool]$commit.Value.creditGranted-or$commit.Value.raw.fileName-cne[IO.Path]::GetFileName($rawPath)-or[long]$commit.Value.raw.bytes-ne[long]$raw.Held.Bytes-or$commit.Value.raw.sha256-cne$raw.Held.Sha256-or$commit.Value.binding.fileName-cne[IO.Path]::GetFileName($bindingPath)-or[long]$commit.Value.binding.bytes-ne[long]$binding.Held.Bytes-or$commit.Value.binding.sha256-cne$binding.Held.Sha256){throw 'Performance transaction commit does not bind the held raw and telemetry files.'}
    if ((ConvertTo-RendererCanonicalJson @($raw.Value.soakBins) $RepositoryRoot) -cne (ConvertTo-RendererCanonicalJson $bins $RepositoryRoot)) {
        throw 'Raw performance observations are not bound to the exact held AC and Battery soak outputs.'
    }

    $identityInfo = Get-Item -LiteralPath $script:Package.IdentityPath
    $profileInfo = Get-Item -LiteralPath $script:Package.ProfilePath
    $archiveInfo = Get-Item -LiteralPath $script:Package.ArchivePath
    $appInfo = Get-Item -LiteralPath $script:Package.AppPath
    $coreInfo = Get-Item -LiteralPath $script:Package.CorePath
    $baseProvenance = [pscustomobject][ordered]@{
        runNonce = $RunNonce
        candidate = [pscustomobject][ordered]@{ commitSha=$ExpectedSourceCommit; treeSha=$ExpectedSourceTree }
        package = [pscustomobject][ordered]@{
            profileId = $script:Package.ProfileId
            receipt = [pscustomobject][ordered]@{ relativePath=(Get-RelativePath $script:Package.IdentityPath 'Package identity'); bytes=[long]$identityInfo.Length; fileSha256=$script:Package.IdentityFileSha256; canonicalSha256=$script:Package.ReceiptSha256 }
            archive = [pscustomobject][ordered]@{ relativePath=(Get-RelativePath $script:Package.ArchivePath 'Package archive'); fileName=$archiveInfo.Name; bytes=[long]$archiveInfo.Length; sha256=$script:Package.ArchiveSha256 }
            packageRootRelativePath = (Get-RelativePath $script:Package.PackageRoot 'Package root')
            components = [pscustomobject][ordered]@{
                app = [pscustomobject][ordered]@{ relativePath=(Get-RelativePath $script:Package.AppPath 'Package App'); bytes=[long]$appInfo.Length; sha256=$script:Package.AppSha256 }
                core = [pscustomobject][ordered]@{ relativePath=(Get-RelativePath $script:Package.CorePath 'Package Core'); bytes=[long]$coreInfo.Length; sha256=$script:Package.CoreSha256 }
            }
        }
    }
    $performanceProvenance = [pscustomobject][ordered]@{
        runNonce=$baseProvenance.runNonce;candidate=$baseProvenance.candidate;package=$baseProvenance.package
        profile = [pscustomobject][ordered]@{id=$script:Package.ProfileId;relativePath='tools/packaging/v0.2/package-identity-profile.json';bytes=[long]$profileInfo.Length;fileSha256=$script:Package.ProfileFileSha256;canonicalSha256=$script:Package.ProfileCanonicalSha256}
        referenceHost = [pscustomobject][ordered]@{profileId=$script:RendererProfileId;profileSha256=$script:Package.ReferenceHostProfileSha256}
        renderer = [pscustomobject][ordered]@{policy='software-only-process-wide';wpfProcessRenderMode='SoftwareOnly';policySha256=$script:Package.RendererPolicySha256}
        session = [pscustomobject][ordered]@{kind='LocalConsole';name='Issue10PerformanceComparator';sessionId=[long]$ac.Value.session.sessionId;transport='Physical';powerSource='AC';thermalState='Nominal';elevated=$false;userScope='SingleUser'}
        performanceTelemetryBinding = [pscustomobject][ordered]@{relativePath=(Get-RelativePath $bindingPath 'Performance telemetry binding');bytes=[long]$binding.Held.Bytes;fileSha256=[string]$binding.Held.Sha256;canonicalSha256=[string]$binding.CanonicalSha256}
        performanceTransactionCommit = [pscustomobject][ordered]@{relativePath=(Get-RelativePath $commitPath 'Performance transaction commit');bytes=[long]$commit.Held.Bytes;fileSha256=[string]$commit.Held.Sha256;canonicalSha256=[string]$commit.CanonicalSha256}
    }

    if ($TestFaultInjectionStage -ceq 'BeforePerformanceReceipt') { throw 'Injected failure before performance receipt.' }
    $performance = & (Join-Path $rendererRoot 'New-V02PerformanceEvidenceReceipt.ps1') -RawObservations $raw.Value `
        -RawSourcePath $rawPath -DestinationDirectory (Join-Path $stage 'performance') -CandidateProvenance $performanceProvenance `
        -EvidenceRoot $script:EvidenceRootFull -RepositoryRoot $RepositoryRoot

    $soakObject = [pscustomobject][ordered]@{ schemaVersion=2;provenance=$baseProvenance;soakBins=$bins;latencyMeasurements=@([pscustomobject][ordered]@{powerSource='AC';resourceTimeline=$acSoak.Timeline;measurement=$acSoak.Latency},[pscustomobject][ordered]@{powerSource='Battery';resourceTimeline=$batterySoak.Timeline;measurement=$batterySoak.Latency});aggregateStatus='PASS' }
    $soakJson = ConvertTo-RendererCanonicalJson $soakObject $RepositoryRoot
    $soakPath = Join-Path $stage 'issue10-soak-receipt.json'
    $soakBytes = (New-Object Text.UTF8Encoding($false,$true)).GetBytes($soakJson + "`n")
    $stream = [IO.File]::Open($soakPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try { $stream.Write($soakBytes,0,$soakBytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
    if ($TestFaultInjectionStage -ceq 'BeforeCommit') { throw 'Injected failure before Issue #10 evidence commit.' }
    if (Test-Path -LiteralPath $destination) { throw 'Issue #10 composed output directory appeared concurrently.' }
    [IO.Directory]::Move($stage,$destination)
    $stage = $null
    [pscustomobject][ordered]@{
        EvidenceClassification='Issue10PerformanceSoakCandidate-NoRuntimeCredit'
        PerformanceReceiptPath=(Join-Path $destination 'performance\performance-receipt.json')
        PerformanceReceiptSha256=$performance.FileSha256
        RawPerformancePath=$rawPath
        RawPerformanceSha256=$raw.Held.Sha256
        PerformanceTelemetryBindingPath=$bindingPath
        PerformanceTelemetryBindingSha256=$binding.Held.Sha256
        PerformanceTransactionCommitPath=$commitPath
        PerformanceTransactionCommitSha256=$commit.Held.Sha256
        SoakReceiptPath=(Join-Path $destination 'issue10-soak-receipt.json')
        SoakReceiptSha256=(Get-FileHash -LiteralPath (Join-Path $destination 'issue10-soak-receipt.json') -Algorithm SHA256).Hash
        RunNonce=$RunNonce
        Runtime='NOT OBSERVED'
        Human='NOT OBSERVED'
        Release='NOT OBSERVED'
    }
} finally {
    foreach ($read in $reads) { if ($null -ne $read.Held.Stream) { $read.Held.Stream.Dispose() } }
    if ($null -ne $stage -and (Test-Path -LiteralPath $stage)) { Remove-Item -LiteralPath $stage -Recurse -Force }
    foreach($hold in $packageHolds){if($null-ne$hold.Stream){$hold.Stream.Dispose()}}
}
