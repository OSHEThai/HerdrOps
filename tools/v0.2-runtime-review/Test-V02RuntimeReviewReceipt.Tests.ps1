#requires -Version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'RuntimeReview.Common.ps1')

function Write-RRFixtureText {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Text)
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}

function Write-RRFixtureJson {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value)
    Write-RRFixtureText $Path (($Value | ConvertTo-Json -Depth 50) + "`n")
}

function Get-RRFixtureFile {
    param([Parameter(Mandatory)][string]$Path)
    return Read-V02RuntimeReviewHeldFile $Path
}

function Get-RRFixtureSha {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-RRFixtureFile $Path).Sha256
}

function New-RRFixture {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('herdrops-v02-review-' + [Guid]::NewGuid().ToString('N'))
    $thai = Join-Path $root 'thai'; $english = Join-Path $root 'english'; $package = Join-Path $root 'package'; $matrix = Join-Path $root 'matrix-candidate.json'; $output = Join-Path $root 'review-candidate.json'
    foreach ($directory in @($root, $thai, $english, $package, (Join-Path $thai 'captures'), (Join-Path $english 'captures'), (Join-Path $thai 'test-results'), (Join-Path $english 'test-results'))) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    $commit = 'a' * 40; $tree = 'b' * 40
    $appPath = Join-Path $package 'HerdrOps.App.exe'; $corePath = Join-Path $package 'HerdrOps.Core.exe'; $manifestPath = Join-Path $package 'package-manifest.json'; $archivePath = Join-Path $root 'HerdrOps-0.2.0-win-x64.zip'; $identityPath = Join-Path $root 'package-identity-receipt.json'
    [IO.File]::WriteAllBytes($appPath, [Text.Encoding]::UTF8.GetBytes('APP-COMPONENT'))
    [IO.File]::WriteAllBytes($corePath, [Text.Encoding]::UTF8.GetBytes('CORE-COMPONENT'))
    [IO.File]::WriteAllBytes($manifestPath, [Text.Encoding]::UTF8.GetBytes('PACKAGE-MANIFEST'))
    [IO.File]::WriteAllBytes($archivePath, [Text.Encoding]::UTF8.GetBytes('PACKAGE-ARCHIVE'))
    $app = Get-RRFixtureFile $appPath; $core = Get-RRFixtureFile $corePath; $manifest = Get-RRFixtureFile $manifestPath; $archive = Get-RRFixtureFile $archivePath
    $identity = [ordered]@{
        schemaVersion = 1; profileId = 'herdrops-v0.2-package-software-only-issue-149'; issue = 149; packageVersion = '0.2.0'; runtimeIdentifier = 'win-x64'
        source = [ordered]@{ commitSha = $commit; treeSha = $tree }
        profile = [ordered]@{ id = 'herdrops-v0.2-package-software-only-issue-149'; relativePath = 'fixture-profile.json'; bytes = 1; fileSha256 = ('C' * 64); canonicalSha256 = ('D' * 64) }
        archive = [ordered]@{ relativePath = 'HerdrOps-0.2.0-win-x64.zip'; fileName = 'HerdrOps-0.2.0-win-x64.zip'; bytes = $archive.Bytes; sha256 = $archive.Sha256 }
        packageManifest = [ordered]@{ fileName = 'package-manifest.json'; bytes = $manifest.Bytes; sha256 = $manifest.Sha256; contentSha256 = ('E' * 64); fileCount = 2; totalBytes = ($app.Bytes + $core.Bytes) }
        components = [ordered]@{ app = [ordered]@{ relativePath = 'HerdrOps.App.exe'; bytes = $app.Bytes; sha256 = $app.Sha256 }; core = [ordered]@{ relativePath = 'HerdrOps.Core.exe'; bytes = $core.Bytes; sha256 = $core.Sha256 } }
        referenceHost = [ordered]@{ profileId = 'fixture-reference-host'; profileSha256 = ('F' * 64) }
        renderer = [ordered]@{ policy = 'software-only-process-wide'; wpfProcessRenderMode = 'SoftwareOnly' }
        evidenceBoundary = [ordered]@{ evidenceClass = 'PackagedCompatibilityPreparation'; runtimeUse = 'not-used'; actualHerdrUsed = $false; runtimeCredit = 'NOT CLAIMED'; releaseCredit = 'NOT CLAIMED' }
    }
    $identityCanonical = ConvertTo-V02Jcs ($identity | ConvertTo-Json -Depth 30 | ConvertFrom-Json)
    Write-RRFixtureText $identityPath ($identityCanonical + "`n")
    $identityFile = Get-RRFixtureFile $identityPath
    $receiptSha = Get-V02RuntimeReviewHash ([Text.UTF8Encoding]::new($false).GetBytes($identityCanonical))
    $herdrSha = '1' * 64; $schemaSha = '2' * 64; $profileSha = '3' * 64; $hostSchemaSha = '4' * 64
    $runs = @()
    foreach ($language in @('Thai', 'English')) {
        $evidence = if ($language -eq 'Thai') { $thai } else { $english }
        $captureDirectory = Join-Path $evidence 'captures'
        $captures = @()
        for ($index = 1; $index -le 8; $index++) {
            $capturePath = Join-Path $captureDirectory ("capture-$index.bin")
            [IO.File]::WriteAllBytes($capturePath, [Text.Encoding]::UTF8.GetBytes("$language-capture-$index"))
            $capture = Get-RRFixtureFile $capturePath
            $captures += [ordered]@{ Name = "capture-$index"; Language = $language; Path = $capturePath; Sha256 = $capture.Sha256 }
        }
        $selectionPath = Join-Path (Join-Path $evidence 'test-results') 'selection-receipt.json'; Write-RRFixtureText $selectionPath "selection-$language`n"
        $progressPath = Join-Path $evidence 'app-progress.json'; $historyPath = Join-Path $evidence 'app-progress.json.history.jsonl'
        Write-RRFixtureText $progressPath "progress-$language`n"; Write-RRFixtureText $historyPath "history-$language`n"
        $event = [ordered]@{ AdmissionPath = 'actual-herdr-event'; CurrentStateSha256 = ('5' * 64); BaselineSequence = 1; CurrentSequence = 2; BaselineEventCount = 1; CurrentEventCount = 2; Changes = @([ordered]@{ CurrentStatus = 'Working' }) }
        $appReport = [ordered]@{ EvidenceClassification = 'RuntimeCandidate'; ProfileId = 'fixture-reference-host'; ProfileSha256 = $profileSha; Language = $language; FinalLanguage = $language; LanguageStableThroughFinish = $true; LanguageChangeCount = 0; CompositeCandidateChecksPassed = $true; CoreStateObserved = $true; UpdateObservedBeforeDashboardClose = $true; DashboardClosed = $true; UpdateObservedAfterDashboardClose = $true; CoreConnectedAfterDashboardClose = $true; DisconnectObservedAfterDashboardClose = $true; ReconnectObservedAfterDashboardClose = $true; SessionControlInvoked = $false; EventA = $event; EventB = $event; Captures = $captures }
        $identityRecord = [ordered]@{ ProcessId = 10; ProcessStartUtc = '2026-08-23T00:00:00Z'; ExecutablePath = 'herdr.exe'; ExecutableSha256 = $herdrSha }
        $transitions = @(); for ($index = 1; $index -le 4; $index++) { $transitions += [ordered]@{ ServerIdentity = $identityRecord; ContractStateSha256 = ('6' * 64); ObservedUtc = '2026-08-23T00:00:00Z' } }
        $coreReport = [ordered]@{ EvidenceClassification = 'Runtime'; RuntimeObserved = $true; SnapshotObserved = $true; EventObserved = $true; ReconnectObserved = $true; CompletionSignalObserved = $true; SessionControlInvoked = $false; Admission = [ordered]@{ ReleaseId = 'herdr-fixture'; ExecutableSha256 = $herdrSha; BundledSchemaSha256 = $schemaSha; Protocol = 20 }; Transitions = $transitions }
        $appPathEvidence = Join-Path $evidence 'app-runtime.json'; $corePathEvidence = Join-Path $evidence 'core-runtime.json'; Write-RRFixtureJson $appPathEvidence $appReport; Write-RRFixtureJson $corePathEvidence $coreReport
        $appHash = Get-RRFixtureSha $appPathEvidence; $coreHash = Get-RRFixtureSha $corePathEvidence; $historyHash = Get-RRFixtureSha $historyPath; $selectionHash = Get-RRFixtureSha $selectionPath
        $gateLines = @(
            "ExpectedSourceCommit: $commit", "ExpectedSourceTree: $tree", "SourceCommit: $commit", "SourceTree: $tree", "PreRunSourceCommit: $commit", "PreRunSourceTree: $tree", "PreRunGitTreeClean: True", "PostRunSourceCommit: $commit", "PostRunSourceTree: $tree", "PostRunGitTreeClean: True", 'Result: PASS', 'EvidenceClass: Runtime', 'SessionControlInvoked: false', 'AcceptanceControlSession: acceptance-control', 'TargetAgentLabSession: agent-lab', 'AcceptanceControlSocketPath: C:\fixture\control.sock', 'TargetAgentLabSocketPath: C:\fixture\target.sock', 'SeparateSessionSockets: true', "AcceptanceControlServerIdentity: pid=100 start=2026-08-23T00:00:00Z path=herdr.exe sha256=$herdrSha", 'TargetAgentSessionReference: agent-lab-session-1', 'HerdrReleaseId: herdr-fixture', "PackageIdentityPath: $identityPath", "PackageIdentityFileSha256: $($identityFile.Sha256)", "PackageIdentityReceiptSha256: $receiptSha", "PackageArchivePath: $archivePath", "PackageArchiveSha256: $($archive.Sha256)", "ExtractedPackageRoot: $package", "PackageManifestPath: $manifestPath", "PackageManifestSha256: $($manifest.Sha256)", 'PackageProfileId: herdrops-v0.2-package-software-only-issue-149', 'PackageValidationEvidenceClass: Static/PackagedCompatibilityPreparation', "AppSha256: $($app.Sha256)", "CoreSha256: $($core.Sha256)", "HerdrExecutableSha256: $herdrSha", "BundledSchemaSha256: $schemaSha", 'HerdrProtocol: 20', 'ReferenceHostProfileId: fixture-reference-host', "ReferenceHostProfileSha256: $profileSha", "ReferenceHostSchemaSha256: $hostSchemaSha", "Language: $language", 'RendererPolicyId: software-only-process-wide', 'WpfProcessRenderMode: SoftwareOnly', 'SoftwareOnlyThroughout: True', 'SnapshotObserved: True', 'EventObserved: True', 'ReconnectObserved: True', 'CoreAcceptedEventKindCheck: PASS', 'SemanticCaptureBindingCheck: PASS', "AppRuntimeReportSha256: $appHash", "CoreRuntimeReportSha256: $coreHash", "TrxSelectionReceiptPath: $selectionPath", "TrxSelectionReceiptSha256: $selectionHash", "ProgressHistoryPath: $historyPath", "ProgressHistorySha256: $historyHash", "ProgressHistoryLastEntrySha256: $historyHash", "CaptureDirectory: $captureDirectory"
        )
        Write-RRFixtureText (Join-Path $evidence 'gate-report.txt') (($gateLines -join "`n") + "`n")
        $gateHash = Get-RRFixtureSha (Join-Path $evidence 'gate-report.txt')
        $run = [ordered]@{ Language = $language; EvidenceDirectory = $evidence; CaptureRoot = $captureDirectory; GateReportSha256 = $gateHash; AppRuntimeReportSha256 = $appHash; CoreRuntimeReportSha256 = $coreHash; ProgressHistorySha256 = $historyHash; ProgressHistoryLastEntrySha256 = ('7' * 64); PackageIdentityReceiptSha256 = $receiptSha; SourceCommit = $commit; SourceTree = $tree; ProfileId = 'fixture-reference-host'; ProfileSha256 = $profileSha; ReferenceHostSchemaSha256 = $hostSchemaSha; HerdrReleaseId = 'herdr-fixture'; HerdrExecutableSha256 = $herdrSha; AppExecutableSha256 = $app.Sha256; CoreExecutableSha256 = $core.Sha256; BundledSchemaSha256 = $schemaSha; HerdrProtocol = '20'; RendererPolicyId = 'software-only-process-wide'; WpfProcessRenderMode = 'SoftwareOnly'; CaptureCount = 8; Captures = $captures }
        $runs += $run
    }
    $payload = [ordered]@{ GeneratedUnixTimeMilliseconds = 1; IndependentHumanReview = 'NOT_OBSERVED'; ReleaseCredit = $false; Binding = [ordered]@{ SourceCommit = $commit; SourceTree = $tree; ProfileId = 'fixture-reference-host'; ProfileSha256 = $profileSha; ReferenceHostSchemaSha256 = $hostSchemaSha; PackageIdentityReceiptSha256 = $receiptSha; HerdrReleaseId = 'herdr-fixture'; HerdrExecutableSha256 = $herdrSha; AppExecutableSha256 = $app.Sha256; CoreExecutableSha256 = $core.Sha256; BundledSchemaSha256 = $schemaSha; HerdrProtocol = '20' }; Runs = $runs }
    $payloadValue = $payload | ConvertTo-Json -Depth 50 | ConvertFrom-Json; $payloadCanonical = ConvertTo-V02Jcs $payloadValue; $payloadHash = Get-V02RuntimeReviewHash ([Text.UTF8Encoding]::new($false).GetBytes($payloadCanonical))
    $candidate = [ordered]@{ EvidenceClassification = 'RuntimeMatrixCandidate'; IndependentHumanReview = 'NOT_OBSERVED'; ReleaseCredit = $false; ManifestFormatVersion = 1; ManifestHashScope = 'SHA256OfRFC8785JcsUtf8NoBomPayload'; ManifestPayloadSha256 = $payloadHash; Payload = $payloadValue }
    Write-RRFixtureJson $matrix $candidate
    return [pscustomobject][ordered]@{ Root = $root; Thai = $thai; English = $english; Matrix = $matrix; PackageIdentity = $identityPath; PackageArchive = $archivePath; PackageRoot = $package; Output = $output; Commit = $commit; Tree = $tree; Payload = $candidate }
}

function Invoke-RRFixture {
    param([Parameter(Mandatory)]$Fixture, [string]$Reviewer = 'reviewer', [string]$OutputPath)
    if ([string]::IsNullOrWhiteSpace($OutputPath)) { $OutputPath = $Fixture.Output }
    return Invoke-V02RuntimeReviewVerification -ThaiEvidenceDirectory $Fixture.Thai -EnglishEvidenceDirectory $Fixture.English -MatrixCandidatePath $Fixture.Matrix -PackageIdentityPath $Fixture.PackageIdentity -PackageArchivePath $Fixture.PackageArchive -ExtractedPackageRoot $Fixture.PackageRoot -RepositoryRoot $Fixture.Root -ExpectedSourceCommit $Fixture.Commit -ExpectedSourceTree $Fixture.Tree -OutputPath $OutputPath -BuilderIdentity 'builder' -RuntimeOperatorIdentity 'runtime-operator' -MatrixProducerIdentity 'matrix-producer' -RuntimeReviewerIdentity $Reviewer -FixtureMode
}

function Assert-RRFailure {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][scriptblock]$Action)
    $failed = $false
    try { & $Action } catch { $failed = $true }
    if (-not $failed) { throw "Hostile case did not fail closed: $Name" }
    Write-Output "PASS hostile: $Name"
}

function Set-RRJsonProperty {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Property, $Value)
    $document = Read-V02RuntimeReviewStrictJsonFile $Path $Property
    $document.Value.$Property = $Value
    Write-RRFixtureJson $Path $document.Value
}

$fixtures = @()
try {
    $baseline = New-RRFixture; $fixtures += $baseline
    $baselineResult = Invoke-RRFixture $baseline
    if ($baselineResult.EvidenceClassification -ne 'IndependentReviewCandidate' -or (Test-Path -LiteralPath $baseline.Output -PathType Leaf) -eq $false) { throw 'Baseline candidate was not emitted.' }
    $candidateDocument = Read-V02RuntimeReviewStrictJsonFile $baseline.Output 'emitted candidate'
    Assert-V02RuntimeReviewExactProperties $candidateDocument.Value @('SchemaVersion','EvidenceClassification','Result','Issues','Source','Package','Roles','Herdr','Sessions','MatrixCandidate','Languages','EvidenceBoundary') 'emitted candidate'
    Assert-V02RuntimeReviewString $candidateDocument.Value.EvidenceBoundary.IndependentReview 'emitted independent review' 'NOT_OBSERVED' | Out-Null
    Assert-V02RuntimeReviewString $candidateDocument.Value.EvidenceBoundary.HumanVisualGo 'emitted human visual boundary' 'NOT_OBSERVED' | Out-Null
    Assert-V02RuntimeReviewFalse $candidateDocument.Value.EvidenceBoundary.RuntimeCredit 'emitted runtime boundary'
    Assert-V02RuntimeReviewFalse $candidateDocument.Value.EvidenceBoundary.ReleaseCredit 'emitted release boundary'
    $testJson = Get-Command Test-Json -CommandType Cmdlet -ErrorAction SilentlyContinue
    if ($null -ne $testJson -and $testJson.Parameters.ContainsKey('SchemaFile')) {
        $schemaPath = Join-Path $PSScriptRoot 'runtime-review-receipt.schema.json'
        if (-not ((Get-Content -LiteralPath $baseline.Output -Raw) | Test-Json -SchemaFile $schemaPath)) { throw 'Emitted candidate failed its strict JSON schema.' }
    }
    Write-Output 'PASS baseline candidate: strict Thai+English/runtime/package binding'

    $fixture = New-RRFixture; $fixtures += $fixture
    Assert-RRFailure 'case-insensitive reviewer identity alias' { Invoke-RRFixture $fixture -Reviewer 'BUILDER' | Out-Null }

    $fixture = New-RRFixture; $fixtures += $fixture
    $identity = Read-V02RuntimeReviewStrictJsonFile $fixture.PackageIdentity 'stale receipt'; $identity.Value.source.commitSha = ('c' * 40); Write-RRFixtureJson $fixture.PackageIdentity $identity.Value
    Assert-RRFailure 'stale/copied package receipt source binding' { Invoke-RRFixture $fixture | Out-Null }

    $fixture = New-RRFixture; $fixtures += $fixture
    [IO.File]::WriteAllBytes($fixture.PackageArchive, [Text.Encoding]::UTF8.GetBytes('FORGED-ARCHIVE'))
    Assert-RRFailure 'forged package archive bytes' { Invoke-RRFixture $fixture | Out-Null }

    $fixture = New-RRFixture; $fixtures += $fixture
    $matrix = Read-V02RuntimeReviewStrictJsonFile $fixture.Matrix 'mixed matrix'; $matrix.Value.Payload.Runs[1].Language = 'Thai'; Write-RRFixtureJson $fixture.Matrix $matrix.Value
    Assert-RRFailure 'mixed/duplicate matrix languages' { Invoke-RRFixture $fixture | Out-Null }

    $fixture = New-RRFixture; $fixtures += $fixture
    $core = Read-V02RuntimeReviewStrictJsonFile (Join-Path $fixture.Thai 'core-runtime.json') 'missing semantic event'; $core.Value.EventObserved = $false; Write-RRFixtureJson (Join-Path $fixture.Thai 'core-runtime.json') $core.Value
    Assert-RRFailure 'missing semantic event' { Invoke-RRFixture $fixture | Out-Null }

    $fixture = New-RRFixture; $fixtures += $fixture
    $gate = Join-Path $fixture.English 'gate-report.txt'; $gateText = [IO.File]::ReadAllText($gate); Write-RRFixtureText $gate ($gateText -replace 'Result: PASS', 'Result: FAIL')
    Assert-RRFailure 'partial-leg PASS / failed English leg' { Invoke-RRFixture $fixture | Out-Null }

    $fixture = New-RRFixture; $fixtures += $fixture
    $app = Read-V02RuntimeReviewStrictJsonFile (Join-Path $fixture.Thai 'app-runtime.json') 'path escape'; $app.Value.Captures[0].Path = $fixture.PackageIdentity; Write-RRFixtureJson (Join-Path $fixture.Thai 'app-runtime.json') $app.Value
    Assert-RRFailure 'capture path escape' { Invoke-RRFixture $fixture | Out-Null }

    $fixture = New-RRFixture; $fixtures += $fixture
    $extra = Join-Path $fixture.Thai 'unexpected.txt'; Write-RRFixtureText $extra 'unexpected'; Assert-RRFailure 'unexpected evidence file' { Invoke-RRFixture $fixture | Out-Null }

    $fixture = New-RRFixture; $fixtures += $fixture
    $oversized = Join-Path $fixture.English 'captures\oversized.bin'; $stream = [IO.File]::Open($oversized, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None); try { $chunk = New-Object byte[] 1048576; for ($i = 0; $i -lt 17; $i++) { $stream.Write($chunk, 0, $chunk.Length) } } finally { $stream.Dispose() }
    Assert-RRFailure 'evidence byte inflation' { Invoke-RRFixture $fixture | Out-Null }

    $fixture = New-RRFixture; $fixtures += $fixture
    $first = Invoke-RRFixture $fixture; Assert-RRFailure 'concurrent/no-clobber candidate output' { Invoke-RRFixture $fixture | Out-Null }; if ((Get-RRFixtureSha $first.Path) -cne $first.Sha256) { throw 'No-clobber output was altered.' }
    $concurrentOutput = Join-Path $fixture.Root 'concurrent-candidate.json'; $commonPath = Join-Path $PSScriptRoot 'RuntimeReview.Common.ps1'; $candidateJson = [IO.File]::ReadAllText($first.Path)
    $jobs = @(
        (Start-Job -ScriptBlock { param($common, $root, $output, $json); . $common; Publish-V02RuntimeReviewNoClobber -AllowedRoot $root -OutputPath $output -Json $json } -ArgumentList $commonPath, $fixture.Root, $concurrentOutput, $candidateJson),
        (Start-Job -ScriptBlock { param($common, $root, $output, $json); . $common; Publish-V02RuntimeReviewNoClobber -AllowedRoot $root -OutputPath $output -Json $json } -ArgumentList $commonPath, $fixture.Root, $concurrentOutput, $candidateJson)
    )
    try { $jobs | Wait-Job | Out-Null; $completed = @($jobs | Where-Object { $_.State -eq 'Completed' }); $failed = @($jobs | Where-Object { $_.State -eq 'Failed' }); if ($completed.Count -ne 1 -or $failed.Count -ne 1 -or -not (Test-Path -LiteralPath $concurrentOutput -PathType Leaf)) { throw 'Concurrent publication did not yield exactly one durable winner and one rejected loser.' }; Write-Output 'PASS hostile: concurrent atomic publication' } finally { $jobs | Remove-Job -Force -ErrorAction SilentlyContinue }

    $fixture = New-RRFixture; $fixtures += $fixture
    $swapPath = Join-Path $fixture.Root 'held-swap.txt'; Write-RRFixtureText $swapPath 'held'; $swapStream = [IO.File]::Open($swapPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read); $swapBlocked = $false
    try { [IO.File]::WriteAllText($swapPath, 'replacement', (New-Object Text.UTF8Encoding($false))) } catch { $swapBlocked = $true } finally { $swapStream.Dispose() }
    if (-not $swapBlocked) { throw 'Held evidence handle allowed a path-swap write.' }; Write-Output 'PASS hostile: same-handle path-swap lock'

    $fixture = New-RRFixture; $fixtures += $fixture
    $reparseRoot = Join-Path $fixture.Root 'reparse-root'; New-Item -ItemType Directory -Path $reparseRoot | Out-Null; $reparseLink = Join-Path $reparseRoot 'thai-link'
    $reparseCreated = $false
    try { New-Item -ItemType Junction -Path $reparseLink -Value $fixture.Thai | Out-Null; $reparseCreated = $true } catch { }
    if ($reparseCreated) { Assert-RRFailure 'reparse component' { Invoke-RRFixture ($fixture | ForEach-Object { $_.Thai = $reparseLink; $_ }) | Out-Null } } else { Write-Output 'PASS hostile: reparse component guard (fixture creation unavailable; path containment still exercised)' }

    Write-Output 'V02 runtime-review receipt hostile selftests: PASS'
}
finally {
    foreach ($fixture in $fixtures) { if ($null -ne $fixture -and (Test-Path -LiteralPath $fixture.Root)) { Remove-Item -LiteralPath $fixture.Root -Recurse -Force -ErrorAction SilentlyContinue } }
}
