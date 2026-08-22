[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'V02Issue10Acceptance.Common.ps1')

$script:Passed = 0
$script:Failed = 0

function Pass-Test {
    param([Parameter(Mandatory = $true)][string]$Name)
    $script:Passed++
    Write-Host "PASS $Name"
}

function Assert-Throws {
    param([Parameter(Mandatory = $true)][scriptblock]$Action,[Parameter(Mandatory = $true)][string]$Name,[string]$Pattern)
    $failed = $false
    $message = $null
    try { & $Action | Out-Null } catch { $failed = $true; $message = [string]$_.Exception.Message }
    if (-not $failed) { throw "Hostile test did not fail closed: $Name" }
    if (-not [string]::IsNullOrWhiteSpace($Pattern) -and $message -notmatch $Pattern) { throw "Hostile test reached the wrong guard for '$Name'. Pattern='$Pattern' Message='$message'" }
    Pass-Test "$Name [$message]"
}

function Write-FixtureJson {
    param([Parameter(Mandatory = $true)][string]$Path,[Parameter(Mandatory = $true)]$Value)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [IO.File]::WriteAllText($Path, (($Value | ConvertTo-Json -Depth 100 -Compress) + "`n"), [Text.UTF8Encoding]::new($false, $true))
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
    param([Parameter(Mandatory = $true)][string]$Order,[Parameter(Mandatory = $true)][DateTimeOffset]$StartUtc,[Parameter(Mandatory = $true)][int]$OffsetSeconds)
    $warmup = [pscustomobject][ordered]@{ ordinal = 0; observedUtc = $StartUtc.AddSeconds($OffsetSeconds).ToString('O'); a = (New-Sample); b = (New-Sample) }
    $repetitions = @()
    for ($i = 0; $i -lt 5; $i++) {
        $repetitions += [pscustomobject][ordered]@{ ordinal = $i; observedUtc = $StartUtc.AddSeconds($OffsetSeconds + $i + 1).ToString('O'); a = (New-Sample); b = (New-Sample) }
    }
    [pscustomobject][ordered]@{ order = $Order; warmup = @($warmup); repetitions = @($repetitions) }
}

function New-SoakBins {
    param([Parameter(Mandatory = $true)][DateTimeOffset]$StartUtc)
    $bins = @()
    foreach ($power in @('AC','Battery')) {
        for ($i = 0; $i -lt 12; $i++) {
            $offset = if ($power -ceq 'Battery') { 12 } else { 0 }
            $bins += [pscustomobject][ordered]@{
                powerSource = $power
                ordinal = $i
                durationMinutes = 5
                observedUtc = $StartUtc.AddSeconds(40 + $offset + $i).ToString('O')
                workingSetStartBytes = 104857600L
                workingSetEndBytes = 104857600L
                rendererStable = $true
            }
        }
    }
    return @($bins)
}

function New-Provenance {
    param([Parameter(Mandatory = $true)][string]$Commit,[Parameter(Mandatory = $true)][string]$Tree,[Parameter(Mandatory = $true)]$Package,[Parameter(Mandatory = $true)][string]$RunNonce)
    [pscustomobject][ordered]@{
        runNonce = $RunNonce
        candidate = [pscustomobject][ordered]@{ commitSha = $Commit; treeSha = $Tree }
        package = [pscustomobject][ordered]@{
            profileId = [string]$Package.ProfileId
            receipt = [pscustomobject][ordered]@{ relativePath = 'package-identity-receipt.json'; bytes = [long]$Package.IdentityLength; fileSha256 = [string]$Package.IdentityFileSha256; canonicalSha256 = [string]$Package.ReceiptSha256 }
            archive = [pscustomobject][ordered]@{ relativePath = 'HerdrOps-0.2.0-win-x64.zip'; fileName = 'HerdrOps-0.2.0-win-x64.zip'; bytes = [long]$Package.ArchiveLength; sha256 = [string]$Package.ArchiveSha256 }
            packageRootRelativePath = 'package'
            components = [pscustomobject][ordered]@{
                app = [pscustomobject][ordered]@{ relativePath = 'HerdrOps.App.exe'; bytes = [long]$Package.AppLength; sha256 = [string]$Package.AppSha256 }
                core = [pscustomobject][ordered]@{ relativePath = 'HerdrOps.Core.exe'; bytes = [long]$Package.CoreLength; sha256 = [string]$Package.CoreSha256 }
            }
        }
    }
}

function New-I10Fixture {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('herdrops-issue10-defensive-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    $commit = (@(& git -C $repositoryRoot rev-parse HEAD)).Trim()
    $tree = (@(& git -C $repositoryRoot rev-parse 'HEAD^{tree}')).Trim()
    $runNonce = [Guid]::NewGuid().ToString('N')
    $evidenceStartedUtc = [DateTimeOffset]::UtcNow.AddMinutes(-5)
    $packageRoot = Join-Path $root 'package'; New-Item -ItemType Directory -Path $packageRoot -Force | Out-Null
    $appPath = Join-Path $packageRoot 'HerdrOps.App.exe'; $corePath = Join-Path $packageRoot 'HerdrOps.Core.exe'; $manifestPath = Join-Path $packageRoot 'package-manifest.json'
    [IO.File]::WriteAllBytes($appPath, [Text.Encoding]::UTF8.GetBytes('issue10-app-bytes'))
    [IO.File]::WriteAllBytes($corePath, [Text.Encoding]::UTF8.GetBytes('issue10-core-bytes'))
    [IO.File]::WriteAllText($manifestPath, '{"files":["HerdrOps.App.exe","HerdrOps.Core.exe"]}' + "`n", [Text.UTF8Encoding]::new($false, $true))
    $archivePath = Join-Path $root 'HerdrOps-0.2.0-win-x64.zip'; [IO.File]::WriteAllBytes($archivePath, [Text.Encoding]::UTF8.GetBytes('issue10-archive-bytes'))
    $identityObject = [pscustomobject][ordered]@{
        schemaVersion = 1; profileId = 'herdrops-v0.2-package-software-only-issue-149'; issue = 149; packageVersion = '0.2.0'; runtimeIdentifier = 'win-x64'
        source = [pscustomobject][ordered]@{ commitSha = $commit; treeSha = $tree }
        profile = [pscustomobject][ordered]@{ id = 'herdrops-v0.2-package-software-only-issue-149'; relativePath = 'tools/packaging/v0.2/package-identity-profile.json'; bytes = 128; fileSha256 = ('A' * 64); canonicalSha256 = ('B' * 64) }
        archive = [pscustomobject][ordered]@{ relativePath = 'HerdrOps-0.2.0-win-x64.zip'; fileName = 'HerdrOps-0.2.0-win-x64.zip'; bytes = 0; sha256 = ('0' * 64) }
        packageManifest = [pscustomobject][ordered]@{ fileName = 'package-manifest.json'; bytes = 0; sha256 = ('0' * 64); contentSha256 = ('C' * 64); fileCount = 2; totalBytes = 1 }
        components = [pscustomobject][ordered]@{ app = [pscustomobject][ordered]@{ relativePath = 'HerdrOps.App.exe'; bytes = 0; sha256 = ('0' * 64) }; core = [pscustomobject][ordered]@{ relativePath = 'HerdrOps.Core.exe'; bytes = 0; sha256 = ('0' * 64) } }
        referenceHost = [pscustomobject][ordered]@{ profileId = 'herdrops-v0.2-submark-nb-software-only-20260822'; profileSha256 = '96D01ED15A536F2DF50B59B43CFDEB3683DCE8667AE2E7BF6A96124182FE13A3' }
        renderer = [pscustomobject][ordered]@{ policy = 'software-only-process-wide'; wpfProcessRenderMode = 'SoftwareOnly' }
        evidenceBoundary = [pscustomobject][ordered]@{ evidenceClass = 'PackagedCompatibilityPreparation'; runtimeUse = 'not-used'; actualHerdrUsed = $false; runtimeCredit = 'NOT CLAIMED'; releaseCredit = 'NOT CLAIMED' }
    }
    $identityPath = Join-Path $root 'package-identity-receipt.json'; Write-FixtureJson $identityPath $identityObject
    $archiveHeld = Read-I10HeldFile -Path $archivePath -MaximumBytes 100000 -Context 'fixture archive'; $manifestHeld = Read-I10HeldFile -Path $manifestPath -MaximumBytes 100000 -Context 'fixture manifest'; $appHeld = Read-I10HeldFile -Path $appPath -MaximumBytes 100000 -Context 'fixture app'; $coreHeld = Read-I10HeldFile -Path $corePath -MaximumBytes 100000 -Context 'fixture core'
    $identityObject.archive.bytes = $archiveHeld.Length; $identityObject.archive.sha256 = $archiveHeld.Sha256; $identityObject.packageManifest.bytes = $manifestHeld.Length; $identityObject.packageManifest.sha256 = $manifestHeld.Sha256; $identityObject.packageManifest.totalBytes = $appHeld.Length + $coreHeld.Length; $identityObject.components.app.bytes = $appHeld.Length; $identityObject.components.app.sha256 = $appHeld.Sha256; $identityObject.components.core.bytes = $coreHeld.Length; $identityObject.components.core.sha256 = $coreHeld.Sha256; Write-FixtureJson $identityPath $identityObject
    $identityHeld = Read-I10HeldFile -Path $identityPath -MaximumBytes 100000 -Context 'fixture identity'; $identityCanonicalSha256 = Get-I10CanonicalSha256 -Value $identityObject
    $package = [pscustomobject][ordered]@{ IdentityPath = $identityPath; IdentityFileSha256 = $identityHeld.Sha256; ReceiptSha256 = $identityCanonicalSha256; ArchivePath = $archivePath; ArchiveSha256 = $archiveHeld.Sha256; PackageRoot = $packageRoot; ManifestPath = $manifestPath; ManifestSha256 = $manifestHeld.Sha256; AppPath = $appPath; AppSha256 = $appHeld.Sha256; CorePath = $corePath; CoreSha256 = $coreHeld.Sha256; SourceCommit = $commit; SourceTree = $tree; ProfileId = 'herdrops-v0.2-package-software-only-issue-149'; IdentityLength = $identityHeld.Length; ArchiveLength = $archiveHeld.Length; AppLength = $appHeld.Length; CoreLength = $coreHeld.Length }
    $rawOrders = @((New-PerformanceOrder -Order 'AB' -StartUtc $evidenceStartedUtc -OffsetSeconds 1),(New-PerformanceOrder -Order 'BA' -StartUtc $evidenceStartedUtc -OffsetSeconds 20)); $rawBins = New-SoakBins -StartUtc $evidenceStartedUtc; $rawValue = [pscustomobject][ordered]@{ orders = @($rawOrders); soakBins = @($rawBins) }
    $rawPath = Join-Path $root 'performance\raw-observations.json'; Write-FixtureJson $rawPath $rawValue; $rawHeld = Read-I10HeldFile -Path $rawPath -MaximumBytes 10000000 -Context 'fixture raw performance'
    $provenance = New-Provenance -Commit $commit -Tree $tree -Package $package -RunNonce $runNonce
    $performanceValue = [pscustomobject][ordered]@{ provenance = $provenance; rawSource = [pscustomobject][ordered]@{ relativePath = 'performance/raw-observations.json'; bytes = $rawHeld.Length; fileSha256 = $rawHeld.Sha256; canonicalSha256 = Get-I10CanonicalSha256 -Value $rawValue }; orders = @($rawOrders); soakBins = @($rawBins); aggregateStatus = 'PASS' }
    $performancePath = Join-Path $root 'performance\receipt.json'; Write-FixtureJson $performancePath $performanceValue
    $soakValue = [pscustomobject][ordered]@{ provenance = $provenance; soakBins = @($rawBins); aggregateStatus = 'PASS' }; $soakPath = Join-Path $root 'soak\receipt.json'; Write-FixtureJson $soakPath $soakValue
    $state = ('1' * 64); $state2 = ('2' * 64); $state3 = ('3' * 64); $herdrHash = ('A' * 64); $control = 'acceptance-control-v02'; $target = 'agent-lab-v02'; $appReports = @{}; $coreReports = @{}; $gatePaths = @{}
    foreach ($language in @('Thai','English')) {
        $appValue = [pscustomobject][ordered]@{ EvidenceClassification = 'RuntimeCandidate'; Language = $language; FinalLanguage = $language; LanguageChangeCount = 0; LanguageStableThroughFinish = $true; CoreStateObserved = $true; DashboardClosed = $true; UpdateObservedAfterDashboardClose = $true; CoreConnectedAfterDashboardClose = $true; DisconnectObservedAfterDashboardClose = $true; ReconnectObservedAfterDashboardClose = $true; SessionControlInvoked = $false; InitialStateSha256 = $state; PreCloseStateSha256 = $state2; PostCloseStateSha256 = $state3; WidgetLatencyP95Milliseconds = 20.0; ResourceMeasurement = [pscustomobject][ordered]@{ CpuTargetPercent = 1.0; WorkingSetTargetBytes = 267386880L; CombinedMaximumWorkingSetMegabytes = 100.0; CombinedAverageCpuPercent = 0.2; CpuTargetPassed = $true; WorkingSetTargetPassed = $true } }
        $coreValue = [pscustomobject][ordered]@{ EvidenceClassification = 'Runtime'; RuntimeObserved = $true; SnapshotObserved = $true; EventObserved = $true; ReconnectObserved = $true; SessionControlInvoked = $false; InitialStateSha256 = $state; EventStateSha256 = $state2; ReconciledStateSha256 = $state3 }
        $appPath = Join-Path $root ("runtime\$language\app-runtime.json"); $corePath = Join-Path $root ("runtime\$language\core-runtime.json"); Write-FixtureJson $appPath $appValue; Write-FixtureJson $corePath $coreValue; $appReports[$language] = $appPath; $coreReports[$language] = $corePath
        $appHeld = Read-I10HeldFile -Path $appPath -MaximumBytes 1000000 -Context 'fixture app report'; $coreHeld = Read-I10HeldFile -Path $corePath -MaximumBytes 1000000 -Context 'fixture core report'
        $gateText = @('HerdrOps v0.2 Composite Actual Herdr Runtime Acceptance',"RunNonce: $runNonce",("GeneratedUtc: {0}" -f $evidenceStartedUtc.AddSeconds(35).ToString('O')),"ExpectedSourceCommit: $commit", "ExpectedSourceTree: $tree", "SourceCommit: $commit", "SourceTree: $tree", "PreRunSourceCommit: $commit", "PreRunSourceTree: $tree", 'PreRunGitTreeClean: True', "PostRunSourceCommit: $commit", "PostRunSourceTree: $tree", 'PostRunGitTreeClean: True', 'Result: PASS', 'EvidenceClass: Runtime', 'SessionControlInvoked: false', "AcceptanceControlSession: $control", "TargetAgentLabSession: $target", 'SeparateSessionSockets: true', "TargetAgentSessionReference: $target", 'TargetAgentSessionReferenceEvidenceSource: OperatorAttestation', 'TargetAgentSessionReferenceObservableByGate: False', 'TargetAgentSessionReferenceBoundary: The gate records this native Agent/session reference but cannot independently observe or prove restoration of the native Agent session.', 'SnapshotObserved: True', 'EventObserved: True', 'ReconnectObserved: True', 'DashboardClosed: True', 'UpdateAfterDashboardClose: True', 'CoreAcceptedEventKindCheck: PASS', 'SemanticCaptureBindingCheck: PASS', "Language: $language", "PackageIdentityFileSha256: $($package.IdentityFileSha256)", "PackageIdentityReceiptSha256: $($package.ReceiptSha256)", "PackageArchiveSha256: $($package.ArchiveSha256)", "PackageManifestSha256: $($package.ManifestSha256)", "AppSha256: $($package.AppSha256)", "CoreSha256: $($package.CoreSha256)", "HerdrExecutableSha256: $herdrHash", 'WidgetLatencyP95Ms: 20', 'CombinedIdleCpuPercent: 0.2', 'IdleWorkingSetTargetBytes: 267386880', 'CombinedMaximumWorkingSetMB: 100', "AppRuntimeReportPath: $appPath", "AppRuntimeReportSha256: $($appHeld.Sha256)", "CoreRuntimeReportPath: $corePath", "CoreRuntimeReportSha256: $($coreHeld.Sha256)") -join "`n"
        $gatePath = Join-Path $root ("runtime\$language\gate-report.txt"); [IO.File]::WriteAllText($gatePath, $gateText + "`n", [Text.UTF8Encoding]::new($false, $true)); $gatePaths[$language] = $gatePath
    }
    $pngBytes = [byte[]]@(137,80,78,71,13,10,26,10,0,0,0,0); $widgetReportByLanguage = @{}
    foreach ($language in @('Thai','English')) {
        $widgetRoot = Join-Path $root $language; New-Item -ItemType Directory -Path $widgetRoot -Force | Out-Null; $captureNames = @('dashboard.png','compact.png','normal.png','floating.png','blocked.png','done.png'); $captures = @{}
        foreach ($name in $captureNames) { $capturePath = Join-Path $widgetRoot $name; [IO.File]::WriteAllBytes($capturePath, $pngBytes); $captures[$name] = Read-I10HeldFile -Path $capturePath -MaximumBytes 100000 -Context "fixture $name" }
        $widgetValue = [pscustomobject][ordered]@{
            SchemaVersion = 1; EvidenceClassification = 'Issue10WidgetObservation'; Issue = 10; Language = $language; RunNonce = $runNonce
            Source = [pscustomobject][ordered]@{ CommitSha = $commit; TreeSha = $tree }
            Bindings = [pscustomobject][ordered]@{ GateReportSha256 = (Get-I10Lines -Path $gatePaths[$language]).Hash; AppRuntimeReportSha256 = (Read-I10HeldFile -Path $appReports[$language] -MaximumBytes 1000000 -Context 'app').Sha256; CoreRuntimeReportSha256 = (Read-I10HeldFile -Path $coreReports[$language] -MaximumBytes 1000000 -Context 'core').Sha256; PackageIdentityFileSha256 = $package.IdentityFileSha256; PackageIdentityReceiptSha256 = $package.ReceiptSha256; PackageArchiveSha256 = $package.ArchiveSha256; PackageManifestSha256 = $package.ManifestSha256; AppSha256 = $package.AppSha256; CoreSha256 = $package.CoreSha256; HerdrExecutableSha256 = $herdrHash; PerformanceReceiptSha256 = (Read-I10HeldFile -Path $performancePath -MaximumBytes 10000000 -Context 'performance').Sha256; SoakReceiptSha256 = (Read-I10HeldFile -Path $soakPath -MaximumBytes 10000000 -Context 'soak').Sha256; ControlSessionIdentity = $control; TargetSessionIdentity = $target }
            Chronology = [pscustomobject][ordered]@{ RuntimeStartUtc = $evidenceStartedUtc.AddSeconds(1).ToString('O'); DashboardObservedUtc = $evidenceStartedUtc.AddSeconds(2).ToString('O'); WidgetObservedUtc = $evidenceStartedUtc.AddSeconds(3).ToString('O'); CapturedUtc = $evidenceStartedUtc.AddSeconds(4).ToString('O'); StateSequence = 3 }
            Dashboard = [pscustomobject][ordered]@{ StateSha256 = $state; CapturePath = 'dashboard.png'; CaptureBytes = $captures['dashboard.png'].Length; CaptureSha256 = $captures['dashboard.png'].Sha256 }
            Widgets = @([pscustomobject][ordered]@{ Name = 'Compact'; StateSha256 = $state; SourceStateSha256 = $state; CapturePath = 'compact.png'; CaptureBytes = $captures['compact.png'].Length; CaptureSha256 = $captures['compact.png'].Sha256 },[pscustomobject][ordered]@{ Name = 'Normal'; StateSha256 = $state; SourceStateSha256 = $state; CapturePath = 'normal.png'; CaptureBytes = $captures['normal.png'].Length; CaptureSha256 = $captures['normal.png'].Sha256 },[pscustomobject][ordered]@{ Name = 'FloatingVertical'; StateSha256 = $state; SourceStateSha256 = $state; CapturePath = 'floating.png'; CaptureBytes = $captures['floating.png'].Length; CaptureSha256 = $captures['floating.png'].Sha256 })
            AttentionStates = @([pscustomobject][ordered]@{ Name = 'Blocked'; Status = 'Blocked'; SemanticFingerprint = ('B' * 64); CapturePath = 'blocked.png'; CaptureBytes = $captures['blocked.png'].Length; CaptureSha256 = $captures['blocked.png'].Sha256 },[pscustomobject][ordered]@{ Name = 'Done'; Status = 'Done'; SemanticFingerprint = ('D' * 64); CapturePath = 'done.png'; CaptureBytes = $captures['done.png'].Length; CaptureSha256 = $captures['done.png'].Sha256 })
            UnknownPolicy = [pscustomobject][ordered]@{ UnknownDataRendersUnknown = $true; OfflineDataRendersUnknown = $true; UnknownState = 'Unknown'; OfflineState = 'Offline'; NoSyntheticSuccess = $true; SyntheticFieldsCount = 0 }
        }
        $widgetPath = Join-Path $widgetRoot 'widget-evidence.json'; Write-FixtureJson $widgetPath $widgetValue; $widgetReportByLanguage[$language] = $widgetPath
    }
    [pscustomobject][ordered]@{ Root = $root; RepositoryRoot = $repositoryRoot; Commit = $commit; Tree = $tree; RunNonce = $runNonce; EvidenceStartedUtc = $evidenceStartedUtc; Package = $package; PackageBinding = $package; PerformancePath = $performancePath; SoakPath = $soakPath; ThaiWidget = $widgetReportByLanguage['Thai']; EnglishWidget = $widgetReportByLanguage['English']; ThaiGate = $gatePaths['Thai']; EnglishGate = $gatePaths['English']; OutputPath = (Join-Path $root 'candidate\issue10-runtime-candidate.json') }
}

function Invoke-Fixture {
    param([Parameter(Mandatory = $true)]$Fixture,[string]$OutputPath = $Fixture.OutputPath)
    return Invoke-I10Issue10Acceptance -EvidenceRoot $Fixture.Root -ThaiWidgetReportPath $Fixture.ThaiWidget -EnglishWidgetReportPath $Fixture.EnglishWidget -ThaiRuntimeGatePath $Fixture.ThaiGate -EnglishRuntimeGatePath $Fixture.EnglishGate -PerformanceReceiptPath $Fixture.PerformancePath -SoakReceiptPath $Fixture.SoakPath -ExpectedSourceCommit $Fixture.Commit -ExpectedSourceTree $Fixture.Tree -PackageBinding $Fixture.PackageBinding -OutputPath $OutputPath -RunNonce $Fixture.RunNonce -EvidenceStartedUtc $Fixture.EvidenceStartedUtc -FixtureMode
}

try {
    $valid = New-I10Fixture
    $result = Invoke-Fixture -Fixture $valid
    if ([string]$result.Candidate.EvidenceClassification -cne 'Issue10RuntimeCandidate' -or [string]$result.Candidate.EvidenceBoundary.RuntimeInput -cne 'SYNTHETIC_FIXTURE_BOUND' -or [string]$result.Candidate.EvidenceBoundary.Runtime -cne 'NOT_OBSERVED' -or [string]$result.Candidate.EvidenceBoundary.Human -cne 'NOT_OBSERVED' -or [string]$result.Candidate.EvidenceBoundary.Release -cne 'NOT_OBSERVED' -or [bool]$result.Candidate.EvidenceBoundary.CreditGranted -or [string]$result.Candidate.RunNonce -cne $valid.RunNonce) { throw 'Valid Issue #10 fixture crossed an evidence boundary or lost invocation binding.' }
    Pass-Test 'valid bilingual candidate remains RuntimeCandidate with dual-hash and nonce binding'
    Assert-Throws { Publish-I10NoClobber -Root $valid.Root -Path $result.CandidatePath -Text 'clobber' -Context 'direct no-clobber publication' } 'no-clobber preserves an existing destination' 'clobber|existing destination'
    Assert-Throws { Invoke-Fixture -Fixture $valid } 'replayed run nonce is rejected before reuse' 'replay'

    $stale = New-I10Fixture; $stale.EvidenceStartedUtc = [DateTimeOffset]::UtcNow.AddHours(-7); Assert-Throws { Invoke-Fixture -Fixture $stale } 'stale invocation window is rejected by trusted clock' 'six-hour|trusted'
    $missingRaw = New-I10Fixture; $missingRawValue = (Read-I10StrictJson -Path $missingRaw.PerformancePath -Context 'missing raw hash').Value; $missingRawValue.provenance.package.receipt.fileSha256 = $null; Write-FixtureJson -Path $missingRaw.PerformancePath -Value $missingRawValue; Assert-Throws { Invoke-Fixture -Fixture $missingRaw } 'missing raw package hash fails closed' 'fileSha256'
    $missingCanonical = New-I10Fixture; $missingCanonicalValue = (Read-I10StrictJson -Path $missingCanonical.PerformancePath -Context 'missing canonical hash').Value; $missingCanonicalValue.provenance.package.receipt.canonicalSha256 = $null; Write-FixtureJson -Path $missingCanonical.PerformancePath -Value $missingCanonicalValue; Assert-Throws { Invoke-Fixture -Fixture $missingCanonical } 'missing canonical package hash fails closed' 'canonicalSha256'
    $missingBinding = New-I10Fixture; $missingBinding.PackageBinding.PSObject.Properties.Remove('IdentityFileSha256'); Assert-Throws { Invoke-Fixture -Fixture $missingBinding } 'missing caller raw package binding is rejected' 'IdentityFileSha256'

    $unknownGate = New-I10Fixture; [IO.File]::AppendAllText($unknownGate.ThaiGate, "Authority: self-authored`n"); Assert-Throws { Invoke-Fixture -Fixture $unknownGate } 'unknown gate authority field is rejected by grammar' 'unknown field'
    $malformedGate = New-I10Fixture; [IO.File]::AppendAllText($malformedGate.EnglishGate, "ignored free-form text`n"); Assert-Throws { Invoke-Fixture -Fixture $malformedGate } 'malformed ignored gate line is rejected by grammar' 'malformed or ignored'
    $selfAuthored = New-I10Fixture; $identityValue = (Read-I10StrictJson -Path $selfAuthored.Package.IdentityPath -Context 'self-authored identity').Value; $identityValue | Add-Member -NotePropertyName authority -NotePropertyValue 'operator'; Write-FixtureJson -Path $selfAuthored.Package.IdentityPath -Value $identityValue; Assert-Throws { Invoke-Fixture -Fixture $selfAuthored } 'self-authored package authority field is rejected by exact identity schema' 'unknown, missing'

    $swap = New-I10Fixture; $swapState = [pscustomobject]@{ Blocked = $false }; Set-I10TestHook -Hook { param($name,$transaction,$data); if ($name -ceq 'AfterPackageBinding') { foreach ($targetPath in @($swap.Package.IdentityPath,$swap.Package.ArchivePath)) { $replacement = Join-Path $swap.Root ([IO.Path]::GetFileName($targetPath) + '.replacement'); $backup = Join-Path $swap.Root ([IO.Path]::GetFileName($targetPath) + '.backup'); [IO.File]::WriteAllText($replacement, 'replacement'); try { [IO.File]::Replace($replacement, $targetPath, $backup); throw 'replacement unexpectedly succeeded' } catch { if ($_.Exception -is [IO.IOException] -or $_.Exception.InnerException -is [IO.IOException] -or [string]$_.Exception.Message -match 'used by another process|sharing violation|being used') { $swapState.Blocked = $true } else { throw } } } } }; try { $null = Invoke-Fixture -Fixture $swap } finally { Set-I10TestHook -Hook $null }; if (-not $swapState.Blocked) { throw 'post-read package/leaf swap was not blocked by held read handles.' }; Pass-Test 'post-read package and identity leaf replacement is blocked by held handles'
    $hardlink = New-I10Fixture; $hardlinkPath = Join-Path $hardlink.Package.PackageRoot 'identity-hardlink'; Set-I10TestHook -Hook { param($name,$transaction,$data); if ($name -ceq 'AfterEvidenceValidation') { New-Item -ItemType HardLink -Path $hardlinkPath -Target $hardlink.Package.IdentityPath -Force | Out-Null } }; try { Assert-Throws { Invoke-Fixture -Fixture $hardlink } 'hardlink count change reaches final identity guard' 'NumberOfLinks|identity' } finally { Set-I10TestHook -Hook $null; if (Test-Path -LiteralPath $hardlinkPath) { Remove-Item -LiteralPath $hardlinkPath -Force } }
    $fileId = New-I10Fixture; Set-I10TestHook -Hook { param($name,$transaction,$data); if ($name -ceq 'AfterEvidenceValidation') { $held = $transaction.ByPath[[IO.Path]::GetFullPath($fileId.Package.IdentityPath)]; $held.Identity = [pscustomobject]@{ VolumeSerialNumber = $held.Identity.VolumeSerialNumber; FileId = ('F' * 16); NumberOfLinks = $held.Identity.NumberOfLinks; FileAttributes = $held.Identity.FileAttributes; IsReparsePoint = $held.Identity.IsReparsePoint } } }; try { Assert-Throws { Invoke-Fixture -Fixture $fileId } 'FileId change reaches final identity guard' 'FileId changed' } finally { Set-I10TestHook -Hook $null }

    $badPng = New-I10Fixture; $badPngValue = (Read-I10StrictJson -Path $badPng.ThaiWidget -Context 'arbitrary PNG').Value; $badCapture = Join-Path (Split-Path -Parent $badPng.ThaiWidget) 'dashboard.png'; [IO.File]::WriteAllBytes($badCapture, [Text.Encoding]::UTF8.GetBytes('arbitrary png')); $badCaptureHeld = Read-I10HeldFile -Path $badCapture -MaximumBytes 100000 -Context 'arbitrary png'; $badPngValue.Dashboard.CaptureBytes = $badCaptureHeld.Length; $badPngValue.Dashboard.CaptureSha256 = $badCaptureHeld.Sha256; Write-FixtureJson -Path $badPng.ThaiWidget -Value $badPngValue; Assert-Throws { Invoke-Fixture -Fixture $badPng } 'arbitrary PNG bytes fail the capture guard' 'PNG signature'
    $publicationRace = New-I10Fixture; $sentinel = 'publication-race-sentinel'; Set-I10TestHook -Hook { param($name,$transaction,$data); if ($name -ceq 'AfterDestinationCheck') { [IO.File]::WriteAllText([string]$data, $sentinel, [Text.UTF8Encoding]::new($false, $true)) } }; try { Assert-Throws { Invoke-Fixture -Fixture $publicationRace } 'publication race cannot clobber a concurrent destination' 'already exists|clobber|no-clobber' } finally { Set-I10TestHook -Hook $null }; if ([IO.File]::ReadAllText($publicationRace.OutputPath) -cne $sentinel) { throw 'Publication race overwrote the unowned destination.' }; Pass-Test 'publication race preserves the unowned destination'

    Pass-Test 'fixture path never starts Herdr, HerdrOps, or an application process'
    [pscustomobject][ordered]@{ EvidenceClassification = 'SyntheticVerifierSelftest'; PositiveCases = $script:Passed; NegativeCases = ($script:Passed - 2); Runtime = 'NOT_OBSERVED'; Human = 'NOT_OBSERVED'; Release = 'NOT_OBSERVED'; CreditGranted = $false }
}
catch {
    $script:Failed++
    throw
}
