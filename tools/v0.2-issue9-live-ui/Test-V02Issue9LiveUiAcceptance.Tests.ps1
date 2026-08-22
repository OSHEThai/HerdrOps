#requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Issue9LiveUi.Common.ps1')

function Assert-I9Test {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Write-I9TestText {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function Write-I9TestJson {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value)
    Write-I9TestText $Path (($Value | ConvertTo-Json -Depth 60 -Compress) + "`n")
}

function New-I9TestBytes {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Text)
    Write-I9TestText $Path $Text
    return (Read-I9HeldFile $Path)
}

function Expect-I9Failure {
    param([Parameter(Mandatory)][scriptblock]$Action, [Parameter(Mandatory)][string]$Name)
    $failed = $false
    try { & $Action } catch { $failed = $true }
    Assert-I9Test $failed "$Name unexpectedly passed."
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('herdrops-issue9-selftest-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root -Force | Out-Null

try {
    $commit = 'a' * 40
    $tree = 'b' * 40
    $herdrSha = 'C' * 64
    $schemaSha = 'D' * 64
    $profileSha = 'E' * 64
    $hostSchemaSha = 'F' * 64
    $controlSocket = Join-Path $root 'control.sock'
    $targetSocket = Join-Path $root 'target.sock'
    $packageRoot = Join-Path $root 'package'
    $packageIdentityPath = Join-Path $root 'package-identity.json'
    $packageArchivePath = Join-Path $root 'HerdrOps-0.2.0-win-x64.zip'
    $thaiRuntime = Join-Path $root 'thai-runtime'
    $englishRuntime = Join-Path $root 'english-runtime'
    $thaiUi = Join-Path $root 'thai-ui'
    $englishUi = Join-Path $root 'english-ui'
    $matrixPath = Join-Path $root 'v0.2-language-matrix-candidate.json'
    $outputPath = Join-Path $root 'issue9-candidate.json'
    foreach ($directory in @($packageRoot, $thaiRuntime, $englishRuntime, $thaiUi, $englishUi)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    New-Item -ItemType Directory -Path (Join-Path $thaiRuntime 'captures') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $englishRuntime 'captures') -Force | Out-Null
    Write-I9TestText $controlSocket 'control-fixture'; Write-I9TestText $targetSocket 'target-fixture'

    $manifestFile = New-I9TestBytes (Join-Path $packageRoot 'package-manifest.json') 'manifest-fixture'
    $appFile = New-I9TestBytes (Join-Path $packageRoot 'HerdrOps.App.exe') 'app-fixture'
    $coreFile = New-I9TestBytes (Join-Path $packageRoot 'HerdrOps.Core.exe') 'core-fixture'
    $archiveFile = New-I9TestBytes $packageArchivePath 'archive-fixture'
    $profileFileSha = '1' * 64
    $identity = [ordered]@{
        schemaVersion = 1; profileId = 'herdrops-v0.2-package-software-only-issue-149'; issue = 149; packageVersion = '0.2.0'; runtimeIdentifier = 'win-x64'
        source = [ordered]@{ commitSha = $commit; treeSha = $tree }
        profile = [ordered]@{ id = 'herdrops-v0.2-package-software-only-issue-149'; relativePath = 'tools/packaging/v0.2/package-identity-profile.json'; bytes = 1; fileSha256 = $profileFileSha; canonicalSha256 = $profileFileSha }
        archive = [ordered]@{ relativePath = 'HerdrOps-0.2.0-win-x64.zip'; fileName = 'HerdrOps-0.2.0-win-x64.zip'; bytes = $archiveFile.Bytes; sha256 = $archiveFile.Sha256 }
        packageManifest = [ordered]@{ fileName = 'package-manifest.json'; bytes = $manifestFile.Bytes; sha256 = $manifestFile.Sha256; contentSha256 = $manifestFile.Sha256; fileCount = 3; totalBytes = [int64]($manifestFile.Bytes + $appFile.Bytes + $coreFile.Bytes) }
        components = [ordered]@{ app = [ordered]@{ relativePath = 'HerdrOps.App.exe'; bytes = $appFile.Bytes; sha256 = $appFile.Sha256 }; core = [ordered]@{ relativePath = 'HerdrOps.Core.exe'; bytes = $coreFile.Bytes; sha256 = $coreFile.Sha256 } }
        referenceHost = [ordered]@{ profileId = 'herdrops-v0.2-submark-nb-software-only-20260822'; profileSha256 = $profileSha }
        renderer = [ordered]@{ policy = 'software-only-process-wide'; wpfProcessRenderMode = 'SoftwareOnly' }
        evidenceBoundary = [ordered]@{ evidenceClass = 'PackagedCompatibilityPreparation'; runtimeUse = 'not-used'; actualHerdrUsed = $false; runtimeCredit = 'NOT CLAIMED'; releaseCredit = 'NOT CLAIMED' }
    }
    Write-I9TestJson $packageIdentityPath $identity
    $identityDoc = Read-I9Json $packageIdentityPath 'fixture package identity'
    $packageReceiptSha = Get-I9Hash ([Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-V02Jcs $identityDoc.Value)))

    $initial = '1' * 64; $pre = '2' * 64; $reconciled = '3' * 64; $post = '4' * 64
    $accepted = [ordered]@{ WorkspaceId = 'workspace-1'; PaneId = 'pane-1'; AgentStatus = 'Working' }
    $transitions = @(
        [ordered]@{ ContractStateSha256 = $initial; ReconciliationCount = 0; AcceptedEventKind = $null; AcceptedAgentStatusEvent = $null },
        [ordered]@{ ContractStateSha256 = $pre; ReconciliationCount = 1; AcceptedEventKind = 'pane.agent_status_changed'; AcceptedAgentStatusEvent = $accepted },
        [ordered]@{ ContractStateSha256 = $reconciled; ReconciliationCount = 2; AcceptedEventKind = $null; AcceptedAgentStatusEvent = $null },
        [ordered]@{ ContractStateSha256 = $post; ReconciliationCount = 2; AcceptedEventKind = 'pane.agent_status_changed'; AcceptedAgentStatusEvent = $accepted },
        [ordered]@{ ContractStateSha256 = $reconciled; ReconciliationCount = 3; AcceptedEventKind = $null; AcceptedAgentStatusEvent = $null }
    )
    $admission = [ordered]@{ ReleaseId = 'herdr-fixture-0.8.2'; ExecutableSha256 = $herdrSha; BundledSchemaSha256 = $schemaSha; Protocol = 20 }
    $core = [ordered]@{
        EvidenceClassification = 'Runtime'; RuntimeObserved = $true; SnapshotObserved = $true; EventObserved = $true; ReconnectObserved = $true; CompletionSignalObserved = $true; SessionControlInvoked = $false; Admission = $admission; Transitions = $transitions
    }
    $eventA = [ordered]@{ CurrentStateSha256 = $pre }
    $eventB = [ordered]@{ CurrentStateSha256 = $post }
    $app = [ordered]@{
        EvidenceClassification = 'RuntimeCandidate'; Language = 'LANG'; FinalLanguage = 'LANG'; LanguageStableThroughFinish = $true; LanguageChangeCount = 0; SessionControlInvoked = $false
        DashboardClosed = $true; UpdateObservedAfterDashboardClose = $true; CoreConnectedAfterDashboardClose = $true; DisconnectObservedAfterDashboardClose = $true; ReconnectObservedAfterDashboardClose = $true
        PreCloseStateSha256 = $pre; PostCloseStateSha256 = $post; EventA = $eventA; EventB = $eventB; Captures = @()
    }

    function New-I9Gate {
        param([Parameter(Mandatory)][string]$RuntimeRoot, [Parameter(Mandatory)][ValidateSet('Thai','English')][string]$Language, [Parameter(Mandatory)][string]$AppSha, [Parameter(Mandatory)][string]$CoreSha,[Parameter(Mandatory)][string]$EvidenceRunNonce)
        $history = Join-Path $RuntimeRoot 'app-progress.json.history.jsonl'; $trx = Join-Path $RuntimeRoot 'selection-receipt.trx.json'; $capture = Join-Path $RuntimeRoot 'captures'
        Write-I9TestText $history 'fixture-history'; Write-I9TestText $trx 'fixture-trx'
        $lines = @(
            'HerdrOps v0.2 Composite Actual Herdr Runtime Acceptance',("GeneratedUtc: $([DateTimeOffset]::UtcNow.ToString('O'))"),"RunNonce: $EvidenceRunNonce", "ExpectedSourceCommit: $commit", "ExpectedSourceTree: $tree", "SourceCommit: $commit", "SourceTree: $tree", "PreRunSourceCommit: $commit", "PreRunSourceTree: $tree", 'PreRunGitTreeClean: True', "PostRunSourceCommit: $commit", "PostRunSourceTree: $tree", 'PostRunGitTreeClean: True', 'Result: PASS', 'EvidenceClass: Runtime', 'SessionControlInvoked: false', 'AcceptanceControlSession: Acceptance-control', 'TargetAgentLabSession: Target-agent', "AcceptanceControlSocketPath: $controlSocket", "TargetAgentLabSocketPath: $targetSocket", 'SeparateSessionSockets: true', 'AcceptanceControlServerIdentity: herdr-fixture-control', 'TargetAgentSessionReference: target-reference-fixture', "PackageIdentityPath: $packageIdentityPath", "PackageIdentityFileSha256: $($identityDoc.Sha256)", "PackageIdentityReceiptSha256: $packageReceiptSha", "PackageArchivePath: $packageArchivePath", "PackageArchiveSha256: $($archiveFile.Sha256)", "ExtractedPackageRoot: $packageRoot", "PackageManifestPath: $(Join-Path $packageRoot 'package-manifest.json')", "PackageManifestSha256: $($manifestFile.Sha256)", 'PackageProfileId: herdrops-v0.2-package-software-only-issue-149', 'PackageValidationEvidenceClass: Static/PackagedCompatibilityPreparation', ('AppSha256: ' + $appFile.Sha256), ('CoreSha256: ' + $coreFile.Sha256), ('HerdrReleaseId: ' + $admission.ReleaseId), ('HerdrExecutableSha256: ' + $herdrSha), ('BundledSchemaSha256: ' + $schemaSha), 'HerdrProtocol: 20', 'ReferenceHostProfileId: herdrops-v0.2-submark-nb-software-only-20260822', ('ReferenceHostProfileSha256: ' + $profileSha), ('ReferenceHostSchemaSha256: ' + $hostSchemaSha), "Language: $Language", "AppRuntimeReportSha256: $AppSha", "CoreRuntimeReportSha256: $CoreSha", "TrxSelectionReceiptPath: $trx", ('TrxSelectionReceiptSha256: ' + ('5' * 64)), "ProgressHistoryPath: $history", ('ProgressHistorySha256: ' + ('6' * 64)), ('ProgressHistoryLastEntrySha256: ' + ('7' * 64)), "CaptureDirectory: $capture", 'CoreAcceptedEventKindCheck: PASS', 'SemanticCaptureBindingCheck: PASS', 'SnapshotObserved: True', 'EventObserved: True', 'ReconnectObserved: True'
        )
        $path = Join-Path $RuntimeRoot 'gate-report.txt'; Write-I9TestText $path (($lines -join "`n") + "`n"); return $path
    }

    function New-I9RuntimeLeg {
        param([Parameter(Mandatory)][string]$RuntimeRoot, [Parameter(Mandatory)][ValidateSet('Thai','English')][string]$Language)
        $localApp = $app | ConvertTo-Json -Depth 50 | ConvertFrom-Json; $localApp.Language = $Language; $localApp.FinalLanguage = $Language
        Write-I9TestJson (Join-Path $RuntimeRoot 'app-runtime.json') $localApp
        Write-I9TestJson (Join-Path $RuntimeRoot 'core-runtime.json') $core
        $appHash = (Read-I9HeldFile (Join-Path $RuntimeRoot 'app-runtime.json')).Sha256; $coreHash = (Read-I9HeldFile (Join-Path $RuntimeRoot 'core-runtime.json')).Sha256
        $evidenceRunNonce=if($Language-ceq'Thai'){'1'*32}else{'2'*32};$gatePath = New-I9Gate $RuntimeRoot $Language $appHash $coreHash $evidenceRunNonce
        return [pscustomobject]@{ Root = [IO.Path]::GetFullPath($RuntimeRoot); EvidenceRunNonce=$evidenceRunNonce; GatePath = $gatePath; AppHash = $appHash; CoreHash = $coreHash; GateHash = (Read-I9HeldFile $gatePath).Sha256 }
    }

    $thai = New-I9RuntimeLeg $thaiRuntime 'Thai'; $english = New-I9RuntimeLeg $englishRuntime 'English'
    $matrixPayload = [ordered]@{
        GeneratedUnixTimeMilliseconds = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(); RunNonce=('3'*32); IndependentHumanReview = 'NOT_OBSERVED'; ReleaseCredit = $false
        Binding = [ordered]@{ SourceCommit = $commit; SourceTree = $tree; ProfileId = 'herdrops-v0.2-package-software-only-issue-149'; ProfileSha256 = $profileSha; ReferenceHostSchemaSha256 = $hostSchemaSha; PackageIdentityReceiptSha256 = $packageReceiptSha; HerdrReleaseId = $admission.ReleaseId; HerdrExecutableSha256 = $herdrSha; AppExecutableSha256 = $appFile.Sha256; CoreExecutableSha256 = $coreFile.Sha256; BundledSchemaSha256 = $schemaSha; HerdrProtocol = '20' }
        Runs = @(
            [ordered]@{ Language = 'Thai'; EvidenceRunNonce=$thai.EvidenceRunNonce; EvidenceDirectory = $thai.Root; GateReportSha256 = $thai.GateHash; AppRuntimeReportSha256 = $thai.AppHash; CoreRuntimeReportSha256 = $thai.CoreHash; SourceCommit = $commit; SourceTree = $tree; PackageIdentityReceiptSha256 = $packageReceiptSha },
            [ordered]@{ Language = 'English'; EvidenceRunNonce=$english.EvidenceRunNonce; EvidenceDirectory = $english.Root; GateReportSha256 = $english.GateHash; AppRuntimeReportSha256 = $english.AppHash; CoreRuntimeReportSha256 = $english.CoreHash; SourceCommit = $commit; SourceTree = $tree; PackageIdentityReceiptSha256 = $packageReceiptSha }
        )
    }
    $matrixCanonical = ConvertTo-V02Jcs (($matrixPayload | ConvertTo-Json -Depth 50 | ConvertFrom-Json)); $matrixPayloadHash = Get-I9Hash ([Text.UTF8Encoding]::new($false).GetBytes($matrixCanonical))
    $matrix = [ordered]@{ EvidenceClassification = 'RuntimeMatrixCandidate'; IndependentHumanReview = 'NOT_OBSERVED'; ReleaseCredit = $false; ManifestFormatVersion = 1; ManifestHashScope = 'SHA256OfRFC8785JcsUtf8NoBomPayload'; ManifestPayloadSha256 = $matrixPayloadHash; Payload = $matrixPayload }
    Write-I9TestJson $matrixPath $matrix

    function New-I9UiLeg {
        param([Parameter(Mandatory)][string]$UiRoot, [Parameter(Mandatory)][ValidateSet('Thai','English')][string]$Language, [Parameter(Mandatory)]$Runtime)
        $overview = New-I9TestBytes (Join-Path $UiRoot 'overview.capture') "$Language-overview"; $live = New-I9TestBytes (Join-Path $UiRoot 'live.capture') "$Language-live"; $agent = New-I9TestBytes (Join-Path $UiRoot 'agent.capture') "$Language-agent"; $side = New-I9TestBytes (Join-Path $UiRoot 'side-by-side.capture') "$Language-side-by-side"
        $selection = [ordered]@{ WorkspaceId = 'workspace-1'; ProjectId = 'project-1'; AgentId = 'agent-1'; TaskId = 'task-1'; AgentStatus = 'Working'; PaneId = 'pane-1'; StateSha256 = $pre; Source = 'CoreSnapshot' }
        $pages = @(
            [ordered]@{ Name = 'Overview'; Language = $Language; UiCapturePath = $overview.Path; UiCaptureSha256 = $overview.Sha256; StateSha256 = $initial; WorkspaceId = $selection.WorkspaceId; ProjectId = $selection.ProjectId; AgentId = $selection.AgentId; TaskId = $selection.TaskId; AgentStatus = $selection.AgentStatus; PaneId = $selection.PaneId },
            [ordered]@{ Name = 'LiveOrganization'; Language = $Language; UiCapturePath = $live.Path; UiCaptureSha256 = $live.Sha256; StateSha256 = $pre; WorkspaceId = $selection.WorkspaceId; ProjectId = $selection.ProjectId; AgentId = $selection.AgentId; TaskId = $selection.TaskId; AgentStatus = $selection.AgentStatus; PaneId = $selection.PaneId },
            [ordered]@{ Name = 'AgentDetail'; Language = $Language; UiCapturePath = $agent.Path; UiCaptureSha256 = $agent.Sha256; StateSha256 = $post; WorkspaceId = $selection.WorkspaceId; ProjectId = $selection.ProjectId; AgentId = $selection.AgentId; TaskId = $selection.TaskId; AgentStatus = $selection.AgentStatus; PaneId = $selection.PaneId }
        )
        $receipt = [ordered]@{
            SchemaVersion = 1; EvidenceClassification = 'Issue9LiveUiObservation'; Issue = 9; Language = $Language
            Source = [ordered]@{ CommitSha = $commit; TreeSha = $tree }
            Bindings = [ordered]@{ GateReportSha256 = $Runtime.GateHash; AppRuntimeReportSha256 = $Runtime.AppHash; CoreRuntimeReportSha256 = $Runtime.CoreHash; PackageIdentityReceiptSha256 = $packageReceiptSha; PackageArchiveSha256 = $archiveFile.Sha256; PackageManifestSha256 = $manifestFile.Sha256; AppSha256 = $appFile.Sha256; CoreSha256 = $coreFile.Sha256; HerdrExecutableSha256 = $herdrSha; BundledSchemaSha256 = $schemaSha; MatrixCandidatePayloadSha256 = $matrixPayloadHash }
            SideBySideCapture = [ordered]@{ Path = $side.Path; Bytes = $side.Bytes; Sha256 = $side.Sha256; ArtifactRole = 'ActualHerdrAndUiSideBySide' }
            Pages = $pages; Selection = $selection
            Lifecycle = [ordered]@{ DashboardClosed = $true; CoreConnectedAfterDashboardClose = $true; DisconnectObserved = $true; ReconnectObserved = $true; ReconciliationObserved = $true; EventAStateSha256 = $pre; EventBStateSha256 = $post; ReconciledStateSha256 = $reconciled; ControlServerSurvivedTargetRestart = $true }
            EvidenceBoundary = [ordered]@{ Runtime = 'NOT_OBSERVED'; HumanVisual = 'NOT_OBSERVED'; ReleaseCredit = $false }
        }
        $path = Join-Path $UiRoot 'issue9-ui-functional.json'; Write-I9TestJson $path $receipt; return $path
    }
    $thaiUiReceipt = New-I9UiLeg $thaiUi 'Thai' $thai; $englishUiReceipt = New-I9UiLeg $englishUi 'English' $english

    $invokeArgs = @{
        ThaiRuntimeEvidenceDirectory = $thaiRuntime; EnglishRuntimeEvidenceDirectory = $englishRuntime; ThaiUiEvidenceDirectory = $thaiUi; EnglishUiEvidenceDirectory = $englishUi; MatrixCandidatePath = $matrixPath; PackageIdentityPath = $packageIdentityPath; PackageArchivePath = $packageArchivePath; ExtractedPackageRoot = $packageRoot; RepositoryRoot = $root; ExpectedSourceCommit = $commit; ExpectedSourceTree = $tree; OutputPath = $outputPath; FixtureMode = $true
    }
    $published = Invoke-I9LiveUiVerification @invokeArgs
    Assert-I9Test (Test-Path -LiteralPath $published.Path -PathType Leaf) 'Synthetic candidate was not published.'
    $candidate = (Read-I9Json $published.Path 'published Issue #9 candidate').Value
    Assert-I9Test ([string]$candidate.EvidenceClassification -ceq 'Issue9RuntimeCandidate') 'Wrong Issue #9 candidate classification.'
    Assert-I9Test ([string]$candidate.EvidenceBoundary.Runtime -ceq 'NOT_OBSERVED' -and [string]$candidate.EvidenceBoundary.HumanVisual -ceq 'NOT_OBSERVED' -and -not [bool]$candidate.EvidenceBoundary.ReleaseCredit) 'Evidence boundary was weakened.'
    Assert-I9Test ($candidate.Languages.Count -eq 2) 'Candidate did not retain both language legs.'
    Assert-I9Test (@($candidate.Languages.EvidenceRunNonce|Sort-Object -Unique).Count -eq 2 -and [string]$candidate.MatrixCandidate.ProducerRunNonce-ceq('3'*32)) 'Candidate did not preserve role-distinct matrix/evidence RunNonce bindings.'

    $schemaPath = Join-Path $PSScriptRoot 'issue9-live-ui-candidate.schema.json'; $null = Read-I9Json $schemaPath 'Issue #9 candidate schema'
    if ($null -ne (Get-Command Test-Json -ErrorAction SilentlyContinue)) { Assert-I9Test (Test-Json -LiteralPath $published.Path -SchemaFile $schemaPath) 'Published candidate failed its strict schema.' }

    $originalUi = [IO.File]::ReadAllText($thaiUiReceipt, [Text.UTF8Encoding]::new($false))
    $mutations = @(
        [pscustomobject]@{ Name = 'wrong UI source'; Apply = { $v = (Read-I9Json $thaiUiReceipt 'receipt').Value; $v.Source.CommitSha = ('c' * 40); Write-I9TestJson $thaiUiReceipt $v } },
        [pscustomobject]@{ Name = 'Thai receipt uses English mode'; Apply = { $v = (Read-I9Json $thaiUiReceipt 'receipt').Value; $v.Language = 'English'; Write-I9TestJson $thaiUiReceipt $v } },
        [pscustomobject]@{ Name = 'forged TaskId mapping'; Apply = { $v = (Read-I9Json $thaiUiReceipt 'receipt').Value; $v.Pages[0].TaskId = 'task-forged'; Write-I9TestJson $thaiUiReceipt $v } },
        [pscustomobject]@{ Name = 'duplicate page'; Apply = { $v = (Read-I9Json $thaiUiReceipt 'receipt').Value; $v.Pages[1].Name = 'Overview'; Write-I9TestJson $thaiUiReceipt $v } },
        [pscustomobject]@{ Name = 'wrong archive binding'; Apply = { $v = (Read-I9Json $thaiUiReceipt 'receipt').Value; $v.Bindings.PackageArchiveSha256 = ('8' * 64); Write-I9TestJson $thaiUiReceipt $v } },
        [pscustomobject]@{ Name = 'wrong Herdr admission binding'; Apply = { $v = (Read-I9Json $thaiUiReceipt 'receipt').Value; $v.Bindings.HerdrExecutableSha256 = ('9' * 64); Write-I9TestJson $thaiUiReceipt $v } },
        [pscustomobject]@{ Name = 'wrong matrix binding'; Apply = { $v = (Read-I9Json $matrixPath 'matrix').Value; $v.Payload.Binding.SourceTree = ('c' * 40); $canonical = ConvertTo-V02Jcs (($v.Payload | ConvertTo-Json -Depth 50 | ConvertFrom-Json)); $v.ManifestPayloadSha256 = Get-I9Hash ([Text.UTF8Encoding]::new($false).GetBytes($canonical)); Write-I9TestJson $matrixPath $v } },
        [pscustomobject]@{ Name = 'missing side-by-side capture'; Apply = { $v = (Read-I9Json $thaiUiReceipt 'receipt').Value; Remove-Item -LiteralPath $v.SideBySideCapture.Path -Force; Write-I9TestJson $thaiUiReceipt $v } },
        [pscustomobject]@{ Name = 'selection project mismatch'; Apply = { $v = (Read-I9Json $thaiUiReceipt 'receipt').Value; $v.Selection.ProjectId = 'project-forged'; Write-I9TestJson $thaiUiReceipt $v } },
        [pscustomobject]@{ Name = 'lifecycle reconciliation false'; Apply = { $v = (Read-I9Json $thaiUiReceipt 'receipt').Value; $v.Lifecycle.ReconciliationObserved = $false; Write-I9TestJson $thaiUiReceipt $v } },
        [pscustomobject]@{ Name = 'forged Runtime/Release boundary'; Apply = { $v = (Read-I9Json $thaiUiReceipt 'receipt').Value; $v.EvidenceBoundary.Runtime = 'PASS'; $v.EvidenceBoundary.ReleaseCredit = $true; Write-I9TestJson $thaiUiReceipt $v } }
    )
    foreach ($mutation in $mutations) {
        try {
            & $mutation.Apply
            $caseOutput = Join-Path $root ('hostile-' + [Guid]::NewGuid().ToString('N') + '.json')
            $caseArgs = @{} + $invokeArgs; $caseArgs.OutputPath = $caseOutput
            Expect-I9Failure { Invoke-I9LiveUiVerification @caseArgs } $mutation.Name
        } finally {
            Write-I9TestText $thaiUiReceipt $originalUi
            if ($mutation.Name -eq 'missing side-by-side capture') { $null = New-I9TestBytes (Join-Path $thaiUi 'side-by-side.capture') 'Thai-side-by-side' }
            if ($mutation.Name -eq 'wrong matrix binding') { Write-I9TestJson $matrixPath $matrix }
        }
    }

    $noClobber = Join-Path $root 'no-clobber.json'; $firstArgs = @{} + $invokeArgs; $firstArgs.OutputPath = $noClobber; $null = Invoke-I9LiveUiVerification @firstArgs; Expect-I9Failure { Invoke-I9LiveUiVerification @firstArgs } 'duplicate output publication'
    $wrapper = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Test-V02Issue9LiveUiAcceptance.ps1') -Raw
    Assert-I9Test ($wrapper -notmatch '(?i)Start-Process|Stop-Process|herdr\.exe|herdr session') 'Production wrapper contains process/session control.'
    $common = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Issue9LiveUi.Common.ps1') -Raw
    Assert-I9Test ($common -notmatch '(?i)Start-Process|Stop-Process|herdr\.exe|herdr session') 'Issue #9 verifier contains process/session control.'
    Write-Output 'Issue #9 live UI acceptance synthetic hostile tests: PASS'
    Write-Output 'EvidenceClass: Synthetic'
    Write-Output 'ActualHerdrRuntime: NOT_OBSERVED'
    Write-Output 'HumanVisual: NOT_OBSERVED'
    Write-Output 'ReleaseCredit: false'
} finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
}
