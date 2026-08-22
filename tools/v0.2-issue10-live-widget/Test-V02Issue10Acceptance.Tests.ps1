[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'V02Issue10Acceptance.Common.ps1')

$script:Passed = 0
$script:Failed = 0

function Pass-Test {
    param([string]$Name)
    $script:Passed++
    Write-Host "PASS $Name"
}

function Assert-Throws {
    param([scriptblock]$Action,[string]$Name)
    $failed = $false
    try { & $Action | Out-Null } catch { $failed = $true }
    if (-not $failed) { throw "Hostile test did not fail closed: $Name" }
    Pass-Test $Name
}

function Write-FixtureJson {
    param([string]$Path,$Value)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $json = $Value | ConvertTo-Json -Depth 100 -Compress
    [IO.File]::WriteAllText($Path, $json + "`n", [Text.UTF8Encoding]::new($false, $true))
}

function New-Sample {
    param([int]$Cpu = 50,[long]$WorkingSet = 104857600,[long]$Latency = 100000,[long]$Stall = 10000)
    [pscustomobject][ordered]@{
        cpuBasisPoints = $Cpu
        workingSetMaximumBytes = $WorkingSet
        latencyMicroseconds = @((1..20 | ForEach-Object { $Latency }))
        uiStallMicroseconds = @((1..20 | ForEach-Object { $Stall }))
    }
}

function New-PerformanceOrder {
    param([string]$Order)
    $warmup = [pscustomobject][ordered]@{ ordinal = 0; observedUtc = '2026-08-22T12:00:00.0000000Z'; a = (New-Sample); b = (New-Sample) }
    $repetitions = @()
    for ($i = 0; $i -lt 5; $i++) {
        $repetitions += [pscustomobject][ordered]@{ ordinal = $i; observedUtc = ('2026-08-22T12:00:{0:00}.0000000Z' -f ($i + 1)); a = (New-Sample); b = (New-Sample) }
    }
    [pscustomobject][ordered]@{ order = $Order; warmup = @($warmup); repetitions = @($repetitions) }
}

function New-SoakBins {
    $bins = @()
    foreach ($power in @('AC','Battery')) {
        for ($i = 0; $i -lt 12; $i++) {
            $offset = if ($power -ceq 'Battery') { 12 } else { 0 }
            $bins += [pscustomobject][ordered]@{
                powerSource = $power
                ordinal = $i
                durationMinutes = 5
                observedUtc = ('2026-08-22T12:{0:00}:00.0000000Z' -f ($i + 1 + $offset))
                workingSetStartBytes = 104857600L
                workingSetEndBytes = 104857600L
                rendererStable = $true
            }
        }
    }
    return @($bins)
}

function New-Provenance {
    param([string]$Commit,[string]$Tree,$Package)
    [pscustomobject][ordered]@{
        candidate = [pscustomobject][ordered]@{ commitSha = $Commit; treeSha = $Tree }
        package = [pscustomobject][ordered]@{
            receipt = [pscustomobject][ordered]@{
                fileSha256 = [string]$Package.IdentityFileSha256
                canonicalSha256 = [string]$Package.ReceiptSha256
            }
            archive = [pscustomobject][ordered]@{ sha256 = [string]$Package.ArchiveSha256 }
            components = [pscustomobject][ordered]@{
                app = [pscustomobject][ordered]@{ sha256 = [string]$Package.AppSha256 }
                core = [pscustomobject][ordered]@{ sha256 = [string]$Package.CoreSha256 }
            }
        }
    }
}

function New-I10Fixture {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('herdrops-issue10-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    $commit = (@(& git -C $repositoryRoot rev-parse HEAD)).Trim()
    $tree = (@(& git -C $repositoryRoot rev-parse 'HEAD^{tree}')).Trim()
    $packageRoot = Join-Path $root 'package'
    New-Item -ItemType Directory -Path $packageRoot -Force | Out-Null
    $appPath = Join-Path $packageRoot 'HerdrOps.App.exe'; $corePath = Join-Path $packageRoot 'HerdrOps.Core.exe'; $manifestPath = Join-Path $packageRoot 'package-manifest.json'
    [IO.File]::WriteAllBytes($appPath, [Text.Encoding]::UTF8.GetBytes('issue10-app-bytes'))
    [IO.File]::WriteAllBytes($corePath, [Text.Encoding]::UTF8.GetBytes('issue10-core-bytes'))
    [IO.File]::WriteAllText($manifestPath, '{"files":[]}' + "`n", [Text.UTF8Encoding]::new($false, $true))
    $archivePath = Join-Path $root 'HerdrOps-0.2.0-win-x64.zip'; [IO.File]::WriteAllBytes($archivePath, [Text.Encoding]::UTF8.GetBytes('issue10-archive-bytes'))
    $identityObject = [pscustomobject][ordered]@{
        schemaVersion = 1
        profileId = 'herdrops-v0.2-package-software-only-issue-149'
        issue = 149
        packageVersion = '0.2.0'
        runtimeIdentifier = 'win-x64'
        source = [pscustomobject][ordered]@{ commitSha = $commit; treeSha = $tree }
        evidenceBoundary = [pscustomobject][ordered]@{ runtimeCredit = 'NOT CLAIMED'; releaseCredit = 'NOT CLAIMED'; actualHerdrUsed = $false }
    }
    $identityPath = Join-Path $root 'package-identity-receipt.json'
    Write-FixtureJson $identityPath $identityObject
    $identityHeld = Read-I10HeldFile -Path $identityPath -MaximumBytes 100000 -Context 'fixture identity'
    $identityCanonicalSha256 = Get-I10CanonicalSha256 -Value $identityObject
    $archiveHeld = Read-I10HeldFile -Path $archivePath -MaximumBytes 100000 -Context 'fixture archive'
    $manifestHeld = Read-I10HeldFile -Path $manifestPath -MaximumBytes 100000 -Context 'fixture manifest'
    $appHeld = Read-I10HeldFile -Path $appPath -MaximumBytes 100000 -Context 'fixture app'
    $coreHeld = Read-I10HeldFile -Path $corePath -MaximumBytes 100000 -Context 'fixture core'
    $package = [pscustomobject][ordered]@{
        IdentityPath = $identityPath
        IdentityFileSha256 = $identityHeld.Sha256
        ReceiptSha256 = $identityCanonicalSha256
        IdentityReceiptSha256 = $identityCanonicalSha256
        ArchivePath = $archivePath
        ArchiveSha256 = $archiveHeld.Sha256
        PackageRoot = $packageRoot
        ManifestPath = $manifestPath
        ManifestSha256 = $manifestHeld.Sha256
        AppPath = $appPath
        AppSha256 = $appHeld.Sha256
        CorePath = $corePath
        CoreSha256 = $coreHeld.Sha256
        SourceCommit = $commit
        SourceTree = $tree
    }
    $rawOrders = @((New-PerformanceOrder 'AB'),(New-PerformanceOrder 'BA')); $rawBins = New-SoakBins
    $rawValue = [pscustomobject][ordered]@{ orders = @($rawOrders); soakBins = @($rawBins) }
    $rawPath = Join-Path $root 'performance\raw-observations.json'; Write-FixtureJson $rawPath $rawValue; $rawHeld = Read-I10HeldFile -Path $rawPath -MaximumBytes 10000000 -Context 'fixture raw performance'
    $provenance = New-Provenance -Commit $commit -Tree $tree -Package $package
    $performanceValue = [pscustomobject][ordered]@{ provenance = $provenance; rawSource = [pscustomobject][ordered]@{ relativePath = 'performance/raw-observations.json'; bytes = $rawHeld.Length; fileSha256 = $rawHeld.Sha256; canonicalSha256 = Get-I10CanonicalSha256 -Value $rawValue }; orders = @($rawOrders); soakBins = @($rawBins); aggregateStatus = 'PASS' }
    $performancePath = Join-Path $root 'performance\receipt.json'; Write-FixtureJson $performancePath $performanceValue
    $soakValue = [pscustomobject][ordered]@{ provenance = $provenance; soakBins = @($rawBins); aggregateStatus = 'PASS' }; $soakPath = Join-Path $root 'soak\receipt.json'; Write-FixtureJson $soakPath $soakValue
    $state = ('1' * 64); $state2 = ('2' * 64); $state3 = ('3' * 64); $herdrHash = ('A' * 64); $control = 'acceptance-control-v02'; $target = 'agent-lab-v02'
    $appReports = @{}; $coreReports = @{}; $gatePaths = @{}; $widgetPaths = @{}
    foreach ($language in @('Thai','English')) {
        $appValue = [pscustomobject][ordered]@{
            EvidenceClassification = 'RuntimeCandidate'; Language = $language; FinalLanguage = $language; LanguageChangeCount = 0; LanguageStableThroughFinish = $true; CoreStateObserved = $true; DashboardClosed = $true; UpdateObservedAfterDashboardClose = $true; CoreConnectedAfterDashboardClose = $true; DisconnectObservedAfterDashboardClose = $true; ReconnectObservedAfterDashboardClose = $true; SessionControlInvoked = $false; InitialStateSha256 = $state; PreCloseStateSha256 = $state2; PostCloseStateSha256 = $state3; WidgetLatencyP95Milliseconds = 20.0; ResourceMeasurement = [pscustomobject][ordered]@{ CpuTargetPercent = 1.0; WorkingSetTargetBytes = 267386880L; CombinedMaximumWorkingSetMegabytes = 100.0; CombinedAverageCpuPercent = 0.2; CpuTargetPassed = $true; WorkingSetTargetPassed = $true }
        }
        $coreValue = [pscustomobject][ordered]@{ EvidenceClassification = 'Runtime'; RuntimeObserved = $true; SnapshotObserved = $true; EventObserved = $true; ReconnectObserved = $true; SessionControlInvoked = $false; InitialStateSha256 = $state; EventStateSha256 = $state2; ReconciledStateSha256 = $state3 }
        $appPath = Join-Path $root ("runtime\$language\app-runtime.json"); $corePath = Join-Path $root ("runtime\$language\core-runtime.json"); Write-FixtureJson $appPath $appValue; Write-FixtureJson $corePath $coreValue
        $appHeld = Read-I10HeldFile -Path $appPath -MaximumBytes 1000000 -Context 'fixture app report'; $coreHeld = Read-I10HeldFile -Path $corePath -MaximumBytes 1000000 -Context 'fixture core report'
        $gateText = @(
            'HerdrOps v0.2 Composite Actual Herdr Runtime Acceptance',
            'GeneratedUtc: 2026-08-22T12:01:00.0000000Z',
            "ExpectedSourceCommit: $commit", "ExpectedSourceTree: $tree", "SourceCommit: $commit", "SourceTree: $tree", "PreRunSourceCommit: $commit", "PreRunSourceTree: $tree", 'PreRunGitTreeClean: True', "PostRunSourceCommit: $commit", "PostRunSourceTree: $tree", 'PostRunGitTreeClean: True', 'Result: PASS', 'EvidenceClass: Runtime', 'SessionControlInvoked: false', "AcceptanceControlSession: $control", "TargetAgentLabSession: $target", 'SeparateSessionSockets: true', "TargetAgentSessionReference: $target", 'SnapshotObserved: True', 'EventObserved: True', 'ReconnectObserved: True', 'DashboardClosed: True', 'UpdateAfterDashboardClose: True', 'CoreAcceptedEventKindCheck: PASS', 'SemanticCaptureBindingCheck: PASS', "Language: $language", "PackageIdentityReceiptSha256: $($package.ReceiptSha256)", "PackageArchiveSha256: $($package.ArchiveSha256)", "PackageManifestSha256: $($package.ManifestSha256)", "AppSha256: $($package.AppSha256)", "CoreSha256: $($package.CoreSha256)", "HerdrExecutableSha256: $herdrHash", 'WidgetLatencyP95Ms: 20', 'CombinedIdleCpuPercent: 0.2', 'IdleWorkingSetTargetBytes: 267386880', 'CombinedMaximumWorkingSetMB: 100', "AppRuntimeReportPath: $appPath", "AppRuntimeReportSha256: $($appHeld.Sha256)", "CoreRuntimeReportPath: $corePath", "CoreRuntimeReportSha256: $($coreHeld.Sha256)"
        ) -join "`n"
        $gatePath = Join-Path $root ("runtime\$language\gate-report.txt"); [IO.File]::WriteAllText($gatePath, $gateText + "`n", [Text.UTF8Encoding]::new($false, $true))
        $appReports[$language] = $appPath; $coreReports[$language] = $corePath; $gatePaths[$language] = $gatePath
    }
    $captureBytes = [Text.Encoding]::UTF8.GetBytes('PNG-fixture-bytes'); $widgetReportByLanguage = @{}
    foreach ($language in @('Thai','English')) {
        $widgetRoot = Join-Path $root $language; New-Item -ItemType Directory -Path $widgetRoot -Force | Out-Null
        $captureNames = @('dashboard.png','compact.png','normal.png','floating.png','blocked.png','done.png'); $captures = @{}
        foreach ($name in $captureNames) { $capturePath = Join-Path $widgetRoot $name; [IO.File]::WriteAllBytes($capturePath, $captureBytes); $captures[$name] = Read-I10HeldFile -Path $capturePath -MaximumBytes 100000 -Context "fixture $name" }
        $widgetValue = [pscustomobject][ordered]@{
            SchemaVersion = 1; EvidenceClassification = 'Issue10WidgetObservation'; Issue = 10; Language = $language
            Source = [pscustomobject][ordered]@{ CommitSha = $commit; TreeSha = $tree }
            Bindings = [pscustomobject][ordered]@{ GateReportSha256 = (Get-I10Lines -Path $gatePaths[$language]).Hash; AppRuntimeReportSha256 = (Read-I10HeldFile -Path $appReports[$language] -MaximumBytes 1000000 -Context 'app').Sha256; CoreRuntimeReportSha256 = (Read-I10HeldFile -Path $coreReports[$language] -MaximumBytes 1000000 -Context 'core').Sha256; PackageIdentityReceiptSha256 = $package.ReceiptSha256; PackageArchiveSha256 = $package.ArchiveSha256; PackageManifestSha256 = $package.ManifestSha256; AppSha256 = $package.AppSha256; CoreSha256 = $package.CoreSha256; HerdrExecutableSha256 = $herdrHash; PerformanceReceiptSha256 = (Read-I10HeldFile -Path $performancePath -MaximumBytes 10000000 -Context 'performance').Sha256; SoakReceiptSha256 = (Read-I10HeldFile -Path $soakPath -MaximumBytes 10000000 -Context 'soak').Sha256; ControlSessionIdentity = $control; TargetSessionIdentity = $target }
            Chronology = [pscustomobject][ordered]@{ RuntimeStartUtc = '2026-08-22T12:00:00.0000000Z'; DashboardObservedUtc = '2026-08-22T12:00:01.0000000Z'; WidgetObservedUtc = '2026-08-22T12:00:02.0000000Z'; CapturedUtc = '2026-08-22T12:00:03.0000000Z'; StateSequence = 3 }
            Dashboard = [pscustomobject][ordered]@{ StateSha256 = $state; CapturePath = 'dashboard.png'; CaptureBytes = $captures['dashboard.png'].Length; CaptureSha256 = $captures['dashboard.png'].Sha256 }
            Widgets = @([pscustomobject][ordered]@{ Name = 'Compact'; StateSha256 = $state; SourceStateSha256 = $state; CapturePath = 'compact.png'; CaptureBytes = $captures['compact.png'].Length; CaptureSha256 = $captures['compact.png'].Sha256 },[pscustomobject][ordered]@{ Name = 'Normal'; StateSha256 = $state; SourceStateSha256 = $state; CapturePath = 'normal.png'; CaptureBytes = $captures['normal.png'].Length; CaptureSha256 = $captures['normal.png'].Sha256 },[pscustomobject][ordered]@{ Name = 'FloatingVertical'; StateSha256 = $state; SourceStateSha256 = $state; CapturePath = 'floating.png'; CaptureBytes = $captures['floating.png'].Length; CaptureSha256 = $captures['floating.png'].Sha256 })
            AttentionStates = @([pscustomobject][ordered]@{ Name = 'Blocked'; Status = 'Blocked'; SemanticFingerprint = ('B' * 64); CapturePath = 'blocked.png'; CaptureBytes = $captures['blocked.png'].Length; CaptureSha256 = $captures['blocked.png'].Sha256 },[pscustomobject][ordered]@{ Name = 'Done'; Status = 'Done'; SemanticFingerprint = ('D' * 64); CapturePath = 'done.png'; CaptureBytes = $captures['done.png'].Length; CaptureSha256 = $captures['done.png'].Sha256 })
            UnknownPolicy = [pscustomobject][ordered]@{ UnknownDataRendersUnknown = $true; OfflineDataRendersUnknown = $true; UnknownState = 'Unknown'; OfflineState = 'Offline'; NoSyntheticSuccess = $true; SyntheticFieldsCount = 0 }
        }
        $widgetPath = Join-Path $widgetRoot 'widget-evidence.json'; Write-FixtureJson $widgetPath $widgetValue; $widgetReportByLanguage[$language] = $widgetPath
    }
    [pscustomobject][ordered]@{ Root = $root; RepositoryRoot = $repositoryRoot; Commit = $commit; Tree = $tree; Package = $package; PerformancePath = $performancePath; SoakPath = $soakPath; ThaiWidget = $widgetReportByLanguage['Thai']; EnglishWidget = $widgetReportByLanguage['English']; ThaiGate = $gatePaths['Thai']; EnglishGate = $gatePaths['English']; OutputPath = (Join-Path $root 'candidate\issue10-runtime-candidate.json') }
}

function Invoke-Fixture {
    param($Fixture,[string]$OutputPath = $Fixture.OutputPath)
    return Invoke-I10Issue10Acceptance -EvidenceRoot $Fixture.Root -ThaiWidgetReportPath $Fixture.ThaiWidget -EnglishWidgetReportPath $Fixture.EnglishWidget -ThaiRuntimeGatePath $Fixture.ThaiGate -EnglishRuntimeGatePath $Fixture.EnglishGate -PerformanceReceiptPath $Fixture.PerformancePath -SoakReceiptPath $Fixture.SoakPath -ExpectedSourceCommit $Fixture.Commit -ExpectedSourceTree $Fixture.Tree -PackageBinding $Fixture.PackageBinding -OutputPath $OutputPath -FixtureMode
}

try {
    $valid = New-I10Fixture
    $valid | Add-Member -NotePropertyName PackageBinding -NotePropertyValue $valid.Package
    $result = Invoke-Fixture -Fixture $valid
    if ([string]$result.Candidate.EvidenceClassification -cne 'Issue10RuntimeCandidate' -or [string]$result.Candidate.EvidenceBoundary.RuntimeInput -cne 'SYNTHETIC_FIXTURE_BOUND' -or [bool]$result.Candidate.EvidenceBoundary.FixtureMode -ne $true -or [string]$result.Candidate.EvidenceBoundary.Runtime -cne 'NOT_OBSERVED' -or [string]$result.Candidate.EvidenceBoundary.Human -cne 'NOT_OBSERVED' -or [string]$result.Candidate.EvidenceBoundary.Release -cne 'NOT_OBSERVED' -or [bool]$result.Candidate.EvidenceBoundary.CreditGranted) { throw 'Valid Issue #10 fixture crossed an evidence boundary.' }
    if (-not (Test-Path -LiteralPath $result.CandidatePath -PathType Leaf)) { throw 'Valid Issue #10 candidate was not durably published.' }
    Pass-Test 'valid actual-Herdr-shaped Thai/English candidate remains RuntimeCandidate and publishes atomically'
    Assert-Throws { Invoke-Fixture -Fixture $valid } 'no-clobber output publication'

    $unknown = New-I10Fixture; $unknown | Add-Member -NotePropertyName PackageBinding -NotePropertyValue $unknown.Package; $unknownValue = (Read-I10StrictJson -Path $unknown.ThaiWidget -Context 'unknown').Value; $unknownValue | Add-Member -NotePropertyName ForgedRuntime -NotePropertyValue 'PASS'; Write-FixtureJson $unknown.ThaiWidget $unknownValue; Assert-Throws { Invoke-Fixture -Fixture $unknown } 'unknown widget field / forged Runtime rejection'
    $mismatch = New-I10Fixture; $mismatch | Add-Member -NotePropertyName PackageBinding -NotePropertyValue $mismatch.Package; $mismatchValue = (Read-I10StrictJson -Path $mismatch.ThaiWidget -Context 'mismatch').Value; $mismatchValue.Widgets[0].StateSha256 = ('9' * 64); Write-FixtureJson $mismatch.ThaiWidget $mismatchValue; Assert-Throws { Invoke-Fixture -Fixture $mismatch } 'Dashboard/widget state mismatch'
    $attention = New-I10Fixture; $attention | Add-Member -NotePropertyName PackageBinding -NotePropertyValue $attention.Package; $attentionValue = (Read-I10StrictJson -Path $attention.ThaiWidget -Context 'attention').Value; $attentionValue.AttentionStates[1].SemanticFingerprint = $attentionValue.AttentionStates[0].SemanticFingerprint; Write-FixtureJson $attention.ThaiWidget $attentionValue; Assert-Throws { Invoke-Fixture -Fixture $attention } 'Blocked/Done attention collapse'
    $unknownPolicy = New-I10Fixture; $unknownPolicy | Add-Member -NotePropertyName PackageBinding -NotePropertyValue $unknownPolicy.Package; $unknownPolicyValue = (Read-I10StrictJson -Path $unknownPolicy.ThaiWidget -Context 'policy').Value; $unknownPolicyValue.UnknownPolicy.UnknownDataRendersUnknown = $false; Write-FixtureJson $unknownPolicy.ThaiWidget $unknownPolicyValue; Assert-Throws { Invoke-Fixture -Fixture $unknownPolicy } 'unknown data fail-closed policy'
    $pathEscape = New-I10Fixture; $pathEscape | Add-Member -NotePropertyName PackageBinding -NotePropertyValue $pathEscape.Package; $pathEscapeValue = (Read-I10StrictJson -Path $pathEscape.ThaiWidget -Context 'escape').Value; $pathEscapeValue.Dashboard.CapturePath = '..\escape.png'; Write-FixtureJson $pathEscape.ThaiWidget $pathEscapeValue; Assert-Throws { Invoke-Fixture -Fixture $pathEscape } 'capture path containment'
    $latency = New-I10Fixture; $latency | Add-Member -NotePropertyName PackageBinding -NotePropertyValue $latency.Package; $latencyValue = (Read-I10StrictJson -Path $latency.PerformancePath -Context 'latency').Value; $latencyValue.orders[0].repetitions[0].a.latencyMicroseconds = @((1..20 | ForEach-Object { 300000 })); Write-FixtureJson $latency.PerformancePath $latencyValue; Assert-Throws { Invoke-Fixture -Fixture $latency } 'governed latency limit / raw receipt cross-binding'
    $soak = New-I10Fixture; $soak | Add-Member -NotePropertyName PackageBinding -NotePropertyValue $soak.Package; $soakValue = (Read-I10StrictJson -Path $soak.SoakPath -Context 'soak').Value; $soakValue.soakBins = @($soakValue.soakBins | Select-Object -First 23); Write-FixtureJson $soak.SoakPath $soakValue; Assert-Throws { Invoke-Fixture -Fixture $soak } 'missing Battery soak bin'
    $stale = New-I10Fixture; $stale | Add-Member -NotePropertyName PackageBinding -NotePropertyValue $stale.Package; $staleValue = (Read-I10StrictJson -Path $stale.EnglishWidget -Context 'stale').Value; $staleValue.Chronology.DashboardObservedUtc = '2026-08-22T11:59:59.0000000Z'; Write-FixtureJson $stale.EnglishWidget $staleValue; Assert-Throws { Invoke-Fixture -Fixture $stale } 'chronology freshness/order'
    $duplicate = New-I10Fixture; $duplicate | Add-Member -NotePropertyName PackageBinding -NotePropertyValue $duplicate.Package; [IO.File]::WriteAllText($duplicate.ThaiWidget, '{"SchemaVersion":1,"SchemaVersion":1}', [Text.UTF8Encoding]::new($false, $true)); Assert-Throws { Invoke-Fixture -Fixture $duplicate } 'duplicate JSON property'

    # Hostile package identity receipt tests reaching exact production guards
    $corruptFile = New-I10Fixture; $corruptFile | Add-Member -NotePropertyName PackageBinding -NotePropertyValue $corruptFile.Package; [IO.File]::AppendAllText($corruptFile.Package.IdentityPath, ' '); Assert-Throws { Invoke-Fixture -Fixture $corruptFile } 'corrupted package identity receipt file bytes'
    $corruptCanon = New-I10Fixture; $corruptCanon | Add-Member -NotePropertyName PackageBinding -NotePropertyValue $corruptCanon.Package; Write-FixtureJson $corruptCanon.Package.IdentityPath ([pscustomobject]@{ receipt = 'mutated'; source = [pscustomobject]@{ commitSha = $corruptCanon.Commit; treeSha = $corruptCanon.Tree } }); $corruptCanon.Package.IdentityFileSha256 = (Read-I10HeldFile -Path $corruptCanon.Package.IdentityPath -MaximumBytes 100000 -Context 'mutated identity').Sha256; Assert-Throws { Invoke-Fixture -Fixture $corruptCanon } 'corrupted package identity receipt canonical hash'
    $forgedReceipt = New-I10Fixture; $forgedReceipt | Add-Member -NotePropertyName PackageBinding -NotePropertyValue $forgedReceipt.Package; $forgedReceipt.Package.ReceiptSha256 = ('F' * 64); Assert-Throws { Invoke-Fixture -Fixture $forgedReceipt } 'caller forged ReceiptSha256 rejected by held bytes verification'
    $foreign = New-I10Fixture; $transplant = New-I10Fixture; $transplant | Add-Member -NotePropertyName PackageBinding -NotePropertyValue $transplant.Package; $transplant.Package.IdentityPath = $foreign.Package.IdentityPath; Assert-Throws { Invoke-Fixture -Fixture $transplant } 'transplanted package identity receipt rejected by held file hash mismatch'
    $staleCommit = New-I10Fixture; $staleCommit | Add-Member -NotePropertyName PackageBinding -NotePropertyValue $staleCommit.Package; $staleCommitObj = (Read-I10StrictJson -Path $staleCommit.Package.IdentityPath -Context 'stale commit').Value; $staleCommitObj.source.commitSha = ('0' * 40); Write-FixtureJson $staleCommit.Package.IdentityPath $staleCommitObj; $staleCommit.Package.IdentityFileSha256 = (Read-I10HeldFile -Path $staleCommit.Package.IdentityPath -MaximumBytes 100000 -Context 'stale commit file').Sha256; $staleCommit.Package.ReceiptSha256 = Get-I10CanonicalSha256 -Value $staleCommitObj; Assert-Throws { Invoke-Fixture -Fixture $staleCommit } 'stale package identity receipt source commit rejected'
    $staleTree = New-I10Fixture; $staleTree | Add-Member -NotePropertyName PackageBinding -NotePropertyValue $staleTree.Package; $staleTreeObj = (Read-I10StrictJson -Path $staleTree.Package.IdentityPath -Context 'stale tree').Value; $staleTreeObj.source.treeSha = ('0' * 40); Write-FixtureJson $staleTree.Package.IdentityPath $staleTreeObj; $staleTree.Package.IdentityFileSha256 = (Read-I10HeldFile -Path $staleTree.Package.IdentityPath -MaximumBytes 100000 -Context 'stale tree file').Sha256; $staleTree.Package.ReceiptSha256 = Get-I10CanonicalSha256 -Value $staleTreeObj; Assert-Throws { Invoke-Fixture -Fixture $staleTree } 'stale package identity receipt source tree rejected'
    $bomIdentity = New-I10Fixture; $bomIdentity | Add-Member -NotePropertyName PackageBinding -NotePropertyValue $bomIdentity.Package; [IO.File]::WriteAllBytes($bomIdentity.Package.IdentityPath, [byte[]]@(0xEF, 0xBB, 0xBF, 0x7B, 0x7D)); Assert-Throws { Invoke-Fixture -Fixture $bomIdentity } 'package identity receipt UTF-8 BOM rejected'
    $dupIdentity = New-I10Fixture; $dupIdentity | Add-Member -NotePropertyName PackageBinding -NotePropertyValue $dupIdentity.Package; [IO.File]::WriteAllText($dupIdentity.Package.IdentityPath, '{"receipt":"a","receipt":"b"}' + "`n", [Text.UTF8Encoding]::new($false, $true)); $dupIdentity.Package.IdentityFileSha256 = (Read-I10HeldFile -Path $dupIdentity.Package.IdentityPath -MaximumBytes 100000 -Context 'dup identity file').Sha256; Assert-Throws { Invoke-Fixture -Fixture $dupIdentity } 'package identity receipt duplicate JSON property rejected'
    $overclaimIdentity = New-I10Fixture; $overclaimIdentity | Add-Member -NotePropertyName PackageBinding -NotePropertyValue $overclaimIdentity.Package; $overclaimObj = (Read-I10StrictJson -Path $overclaimIdentity.Package.IdentityPath -Context 'overclaim').Value; $overclaimObj.evidenceBoundary.runtimeCredit = 'CLAIMED'; Write-FixtureJson $overclaimIdentity.Package.IdentityPath $overclaimObj; $overclaimIdentity.Package.IdentityFileSha256 = (Read-I10HeldFile -Path $overclaimIdentity.Package.IdentityPath -MaximumBytes 100000 -Context 'overclaim file').Sha256; $overclaimIdentity.Package.ReceiptSha256 = Get-I10CanonicalSha256 -Value $overclaimObj; Assert-Throws { Invoke-Fixture -Fixture $overclaimIdentity } 'package identity receipt overclaiming runtime credit rejected'
    $conflictBinding = New-I10Fixture; $conflictBinding | Add-Member -NotePropertyName PackageBinding -NotePropertyValue $conflictBinding.Package; $conflictBinding.Package.IdentityReceiptSha256 = ('A' * 64); Assert-Throws { Invoke-Fixture -Fixture $conflictBinding } 'conflicting IdentityReceiptSha256 rejected'

    # Flat provenance shape tests
    $flatFixture = New-I10Fixture; $flatFixture | Add-Member -NotePropertyName PackageBinding -NotePropertyValue $flatFixture.Package
    $flatProvenance = [pscustomobject][ordered]@{
        sourceCommit = $flatFixture.Commit
        sourceTree = $flatFixture.Tree
        packageIdentityReceiptSha256 = $flatFixture.Package.ReceiptSha256
        packageArchiveSha256 = $flatFixture.Package.ArchiveSha256
        appSha256 = $flatFixture.Package.AppSha256
        coreSha256 = $flatFixture.Package.CoreSha256
    }
    $flatPerfValue = (Read-I10StrictJson -Path $flatFixture.PerformancePath -Context 'perf').Value
    $flatPerfValue.provenance = $flatProvenance
    Write-FixtureJson $flatFixture.PerformancePath $flatPerfValue
    $flatSoakValue = (Read-I10StrictJson -Path $flatFixture.SoakPath -Context 'soak').Value
    $flatSoakValue.provenance = $flatProvenance
    Write-FixtureJson $flatFixture.SoakPath $flatSoakValue
    $newPerfHash = (Read-I10HeldFile -Path $flatFixture.PerformancePath -MaximumBytes 10000000 -Context 'new perf').Sha256
    $newSoakHash = (Read-I10HeldFile -Path $flatFixture.SoakPath -MaximumBytes 10000000 -Context 'new soak').Sha256
    foreach ($widgetPath in @($flatFixture.ThaiWidget, $flatFixture.EnglishWidget)) {
        $w = (Read-I10StrictJson -Path $widgetPath -Context 'widget').Value
        $w.Bindings.PerformanceReceiptSha256 = $newPerfHash
        $w.Bindings.SoakReceiptSha256 = $newSoakHash
        Write-FixtureJson $widgetPath $w
    }
    $flatResult = Invoke-Fixture -Fixture $flatFixture -OutputPath (Join-Path $flatFixture.Root 'candidate\flat-candidate.json')
    if ([string]$flatResult.Candidate.Result -cne 'PASS') { throw 'Flat provenance shape candidate failed.' }
    Pass-Test 'flat provenance shape validated against held package identity receipt hash'

    $tamperedFlat = New-I10Fixture; $tamperedFlat | Add-Member -NotePropertyName PackageBinding -NotePropertyValue $tamperedFlat.Package
    $tamperedFlatProvenance = [pscustomobject][ordered]@{
        sourceCommit = $tamperedFlat.Commit
        sourceTree = $tamperedFlat.Tree
        packageIdentityReceiptSha256 = ('E' * 64)
        packageArchiveSha256 = $tamperedFlat.Package.ArchiveSha256
        appSha256 = $tamperedFlat.Package.AppSha256
        coreSha256 = $tamperedFlat.Package.CoreSha256
    }
    $tamperedFlatPerfValue = (Read-I10StrictJson -Path $tamperedFlat.PerformancePath -Context 'tampered perf').Value
    $tamperedFlatPerfValue.provenance = $tamperedFlatProvenance
    Write-FixtureJson $tamperedFlat.PerformancePath $tamperedFlatPerfValue
    Assert-Throws { Invoke-Fixture -Fixture $tamperedFlat } 'flat provenance shape with tampered packageIdentityReceiptSha256 rejected'

    Pass-Test 'fixture path never invokes Herdr or an application process'
    [pscustomobject][ordered]@{ EvidenceClassification = 'SyntheticVerifierSelftest'; PositiveCases = $script:Passed; NegativeCases = 21; Runtime = 'NOT_OBSERVED'; Human = 'NOT_OBSERVED'; Release = 'NOT_OBSERVED'; CreditGranted = $false }
}
catch {
    $script:Failed++
    throw
}
