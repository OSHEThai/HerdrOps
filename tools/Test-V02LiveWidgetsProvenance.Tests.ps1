[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\V02LiveWidgetsProvenance.ps1')

$root = Join-Path ([IO.Path]::GetTempPath()) ('herdops-v02-widget-provenance-' + [guid]::NewGuid().ToString('N'))
$trxRoot = Join-Path $root 'test-results'
$evidenceRoot = Join-Path $root 'evidence'
$artifactRoot = Join-Path $root 'artifacts'
$gateRoot = Join-Path $artifactRoot 'release-gates\v0.2.0\issue-10'
New-Item -ItemType Directory -Path $trxRoot, $evidenceRoot, $gateRoot -Force | Out-Null

function Assert-Throws {
    param([scriptblock]$Action, [string]$Name)
    $thrown = $false
    try { & $Action } catch { $thrown = $true }
    if (-not $thrown) { throw "Expected failure did not occur: $Name" }
    Write-Output "PASS $Name"
}

try {
    # 1. TRX Set Filtering and Stale Exclusion
    $started = [DateTimeOffset]::Parse('2026-08-21T00:00:00.0000000Z')
    $finished = [DateTimeOffset]::Parse('2026-08-21T00:10:00.0000000Z')
    $trxTemplate = '<TestRun id="{0}"><Times start="2026-08-21T00:01:00.0000000Z" finish="2026-08-21T00:02:00.0000000Z" /></TestRun>'
    foreach ($index in 1..4) {
        [string]::Format($trxTemplate, [guid]::NewGuid()) | Set-Content -LiteralPath (Join-Path $trxRoot ("current-$index.trx")) -Encoding utf8
    }
    '<TestRun id="old"><Times start="2026-08-20T00:01:00.0000000Z" finish="2026-08-20T00:02:00.0000000Z" /></TestRun>' | Set-Content -LiteralPath (Join-Path $trxRoot 'old.trx') -Encoding utf8
    $valid = @(Get-V02LiveWidgetsTrxSet -Directory $trxRoot -StartedUtc $started -FinishedUtc $finished)
    if ($valid.Count -ne 4) { throw "Expected four current TRX files, found $($valid.Count)." }
    Write-Output 'PASS stale TRX is excluded from a current run'

    # Duplicate TRX run ID
    $dupId = [guid]::NewGuid().ToString()
    [string]::Format($trxTemplate, $dupId) | Set-Content -LiteralPath (Join-Path $trxRoot 'dup-1.trx') -Encoding utf8
    [string]::Format($trxTemplate, $dupId) | Set-Content -LiteralPath (Join-Path $trxRoot 'dup-2.trx') -Encoding utf8
    Assert-Throws { Assert-V02LiveWidgetsTrxSet -Files @(Get-Item (Join-Path $trxRoot 'dup-*.trx'), (Join-Path $trxRoot 'current-1.trx'), (Join-Path $trxRoot 'current-2.trx')) -StartedUtc $started -FinishedUtc $finished } 'duplicate TRX run ID is rejected'
    Remove-Item -LiteralPath (Join-Path $trxRoot 'dup-1.trx'), (Join-Path $trxRoot 'dup-2.trx') -Force

    # Mixed/duplicate current run count > 4
    '<TestRun id="bad"><Times start="2026-08-21T00:01:00.0000000Z" finish="2026-08-21T00:02:00.0000000Z" /></TestRun>' | Set-Content -LiteralPath (Join-Path $trxRoot 'mixed.trx') -Encoding utf8
    Assert-Throws { Get-V02LiveWidgetsTrxSet -Directory $trxRoot -StartedUtc $started -FinishedUtc $finished } 'mixed/duplicate current run is rejected'
    Remove-Item -LiteralPath (Join-Path $trxRoot 'mixed.trx') -Force

    # Missing current TRX count < 4
    Remove-Item -LiteralPath (Join-Path $trxRoot 'current-4.trx') -Force
    Assert-Throws { Get-V02LiveWidgetsTrxSet -Directory $trxRoot -StartedUtc $started -FinishedUtc $finished } 'missing current TRX is rejected'
    Remove-Item -LiteralPath (Join-Path $trxRoot 'current-1.trx'), (Join-Path $trxRoot 'current-2.trx'), (Join-Path $trxRoot 'current-3.trx'), (Join-Path $trxRoot 'old.trx') -Force

    # 2. Evidence Metadata Verification and Negative Tests
    $capture = Join-Path $evidenceRoot 'capture.png'
    'capture-bytes-original' | Set-Content -LiteralPath $capture -Encoding utf8
    $metadata = [pscustomobject]@{
        EvidenceKind = 'captures'
        RunToken = 'run-token-01'
        SourceCommit = ('a' * 40)
        GeneratedUtc = '2026-08-21T00:03:00.0000000Z'
        Files = @([pscustomobject]@{ Name = 'capture.png'; Sha256 = Get-V02LiveWidgetsSha256 -Path $capture })
    }
    Assert-V02LiveWidgetsEvidenceMetadata -Metadata $metadata -ExpectedKind 'captures' -ExpectedCommit ('a' * 40) -ExpectedToken 'run-token-01' -EvidenceDirectory $evidenceRoot -ExpectedNames @('capture.png') -StartedUtc $started -FinishedUtc $finished
    Write-Output 'PASS current capture metadata binds token, HEAD, window and hash'

    # Stale token
    $metadataStaleToken = [pscustomobject]@{
        EvidenceKind = 'captures'
        RunToken = 'stale-token-99'
        SourceCommit = ('a' * 40)
        GeneratedUtc = '2026-08-21T00:03:00.0000000Z'
        Files = @([pscustomobject]@{ Name = 'capture.png'; Sha256 = Get-V02LiveWidgetsSha256 -Path $capture })
    }
    Assert-Throws { Assert-V02LiveWidgetsEvidenceMetadata -Metadata $metadataStaleToken -ExpectedKind 'captures' -ExpectedCommit ('a' * 40) -ExpectedToken 'run-token-01' -EvidenceDirectory $evidenceRoot -ExpectedNames @('capture.png') -StartedUtc $started -FinishedUtc $finished } 'stale capture metadata token is rejected'

    # Stale commit
    $metadataStaleCommit = [pscustomobject]@{
        EvidenceKind = 'captures'
        RunToken = 'run-token-01'
        SourceCommit = ('b' * 40)
        GeneratedUtc = '2026-08-21T00:03:00.0000000Z'
        Files = @([pscustomobject]@{ Name = 'capture.png'; Sha256 = Get-V02LiveWidgetsSha256 -Path $capture })
    }
    Assert-Throws { Assert-V02LiveWidgetsEvidenceMetadata -Metadata $metadataStaleCommit -ExpectedKind 'captures' -ExpectedCommit ('a' * 40) -ExpectedToken 'run-token-01' -EvidenceDirectory $evidenceRoot -ExpectedNames @('capture.png') -StartedUtc $started -FinishedUtc $finished } 'stale capture metadata commit is rejected'

    # Timestamp before window
    $metadataEarly = [pscustomobject]@{
        EvidenceKind = 'captures'
        RunToken = 'run-token-01'
        SourceCommit = ('a' * 40)
        GeneratedUtc = '2026-08-20T23:59:59.0000000Z'
        Files = @([pscustomobject]@{ Name = 'capture.png'; Sha256 = Get-V02LiveWidgetsSha256 -Path $capture })
    }
    Assert-Throws { Assert-V02LiveWidgetsEvidenceMetadata -Metadata $metadataEarly -ExpectedKind 'captures' -ExpectedCommit ('a' * 40) -ExpectedToken 'run-token-01' -EvidenceDirectory $evidenceRoot -ExpectedNames @('capture.png') -StartedUtc $started -FinishedUtc $finished } 'early timestamp outside run window is rejected'

    # Timestamp after window
    $metadataLate = [pscustomobject]@{
        EvidenceKind = 'captures'
        RunToken = 'run-token-01'
        SourceCommit = ('a' * 40)
        GeneratedUtc = '2026-08-21T00:10:01.0000000Z'
        Files = @([pscustomobject]@{ Name = 'capture.png'; Sha256 = Get-V02LiveWidgetsSha256 -Path $capture })
    }
    Assert-Throws { Assert-V02LiveWidgetsEvidenceMetadata -Metadata $metadataLate -ExpectedKind 'captures' -ExpectedCommit ('a' * 40) -ExpectedToken 'run-token-01' -EvidenceDirectory $evidenceRoot -ExpectedNames @('capture.png') -StartedUtc $started -FinishedUtc $finished } 'late timestamp outside run window is rejected'

    # Tampered file hash
    'tampered-bytes' | Set-Content -LiteralPath $capture -Encoding utf8
    Assert-Throws { Assert-V02LiveWidgetsEvidenceMetadata -Metadata $metadata -ExpectedKind 'captures' -ExpectedCommit ('a' * 40) -ExpectedToken 'run-token-01' -EvidenceDirectory $evidenceRoot -ExpectedNames @('capture.png') -StartedUtc $started -FinishedUtc $finished } 'tampered file hash mismatch is rejected'
    'capture-bytes-original' | Set-Content -LiteralPath $capture -Encoding utf8

    # Missing file in metadata
    $metadataMissingFile = [pscustomobject]@{
        EvidenceKind = 'captures'
        RunToken = 'run-token-01'
        SourceCommit = ('a' * 40)
        GeneratedUtc = '2026-08-21T00:03:00.0000000Z'
        Files = @()
    }
    Assert-Throws { Assert-V02LiveWidgetsEvidenceMetadata -Metadata $metadataMissingFile -ExpectedKind 'captures' -ExpectedCommit ('a' * 40) -ExpectedToken 'run-token-01' -EvidenceDirectory $evidenceRoot -ExpectedNames @('capture.png') -StartedUtc $started -FinishedUtc $finished } 'metadata missing expected file is rejected'

    # Extra/unexpected file in metadata
    $metadataExtraFile = [pscustomobject]@{
        EvidenceKind = 'captures'
        RunToken = 'run-token-01'
        SourceCommit = ('a' * 40)
        GeneratedUtc = '2026-08-21T00:03:00.0000000Z'
        Files = @(
            [pscustomobject]@{ Name = 'capture.png'; Sha256 = Get-V02LiveWidgetsSha256 -Path $capture },
            [pscustomobject]@{ Name = 'unexpected.png'; Sha256 = ('0' * 64) }
        )
    }
    Assert-Throws { Assert-V02LiveWidgetsEvidenceMetadata -Metadata $metadataExtraFile -ExpectedKind 'captures' -ExpectedCommit ('a' * 40) -ExpectedToken 'run-token-01' -EvidenceDirectory $evidenceRoot -ExpectedNames @('capture.png') -StartedUtc $started -FinishedUtc $finished } 'metadata with unexpected extra file is rejected'

    # Wrong evidence kind
    Assert-Throws { Assert-V02LiveWidgetsEvidenceMetadata -Metadata $metadata -ExpectedKind 'measurement' -ExpectedCommit ('a' * 40) -ExpectedToken 'run-token-01' -EvidenceDirectory $evidenceRoot -ExpectedNames @('capture.png') -StartedUtc $started -FinishedUtc $finished } 'wrong evidence kind is rejected'

    # 3. New-V02LiveWidgetsRunManifest and Assert-V02LiveWidgetsRunManifest
    $manifestCreated = New-V02LiveWidgetsRunManifest -ArtifactRoot $artifactRoot -SourceCommit ('a' * 40) -RunToken 'run-token-01' -StartedUtc $started -FinishedUtc $finished
    if ($manifestCreated.RunToken -ne 'run-token-01' -or $manifestCreated.SourceCommit -ne ('a' * 40)) {
        throw 'Created manifest fields do not match expected values.'
    }
    $assertedWindow = Assert-V02LiveWidgetsRunManifest -Manifest $manifestCreated -ExpectedCommit ('a' * 40) -ExpectedToken 'run-token-01'
    if ($assertedWindow.StartedUtc -ne $started.ToUniversalTime() -or $assertedWindow.FinishedUtc -ne $finished.ToUniversalTime()) {
        throw 'Asserted run window does not match manifest timestamps.'
    }
    Write-Output 'PASS New-V02LiveWidgetsRunManifest creates valid and assertable manifest'

    # Invalid token in New-V02LiveWidgetsRunManifest
    Assert-Throws { New-V02LiveWidgetsRunManifest -ArtifactRoot $artifactRoot -SourceCommit ('a' * 40) -RunToken 'short' -StartedUtc $started -FinishedUtc $finished } 'short RunToken is rejected'
    Assert-Throws { New-V02LiveWidgetsRunManifest -ArtifactRoot $artifactRoot -SourceCommit ('a' * 40) -RunToken 'unsafe token;rm' -StartedUtc $started -FinishedUtc $finished } 'unsafe RunToken is rejected'

    # Invalid commit in New-V02LiveWidgetsRunManifest
    Assert-Throws { New-V02LiveWidgetsRunManifest -ArtifactRoot $artifactRoot -SourceCommit 'not-a-sha1' -RunToken 'run-token-01' -StartedUtc $started -FinishedUtc $finished } 'invalid SourceCommit is rejected'

    # Inverted UTC window
    Assert-Throws { New-V02LiveWidgetsRunManifest -ArtifactRoot $artifactRoot -SourceCommit ('a' * 40) -RunToken 'run-token-01' -StartedUtc $finished -FinishedUtc $started } 'inverted run window is rejected'

    # Empty UTC window
    Assert-Throws { New-V02LiveWidgetsRunManifest -ArtifactRoot $artifactRoot -SourceCommit ('a' * 40) -RunToken 'run-token-01' -StartedUtc $started -FinishedUtc $started } 'empty run window is rejected'

    # 4. Get-V02LiveWidgetsInvocationWindow
    $trxSubdir = Join-Path $root 'invocation-trx'
    New-Item -ItemType Directory -Path $trxSubdir -Force | Out-Null
    $t1Start = [DateTimeOffset]::Parse('2026-08-21T01:00:00.0000000Z')
    $t1End = [DateTimeOffset]::Parse('2026-08-21T01:02:00.0000000Z')
    $t2Start = [DateTimeOffset]::Parse('2026-08-21T01:00:30.0000000Z')
    $t2End = [DateTimeOffset]::Parse('2026-08-21T01:03:00.0000000Z')
    $t3Start = [DateTimeOffset]::Parse('2026-08-21T01:01:00.0000000Z')
    $t3End = [DateTimeOffset]::Parse('2026-08-21T01:02:30.0000000Z')
    $t4Start = [DateTimeOffset]::Parse('2026-08-21T01:01:30.0000000Z')
    $t4End = [DateTimeOffset]::Parse('2026-08-21T01:04:00.0000000Z')

    ('<TestRun id="{0}"><Times start="2026-08-21T01:00:00.0000000Z" finish="2026-08-21T01:02:00.0000000Z" /></TestRun>' -f [guid]::NewGuid()) | Set-Content -LiteralPath (Join-Path $trxSubdir 'p1.trx') -Encoding utf8
    ('<TestRun id="{0}"><Times start="2026-08-21T01:00:30.0000000Z" finish="2026-08-21T01:03:00.0000000Z" /></TestRun>' -f [guid]::NewGuid()) | Set-Content -LiteralPath (Join-Path $trxSubdir 'p2.trx') -Encoding utf8
    ('<TestRun id="{0}"><Times start="2026-08-21T01:01:00.0000000Z" finish="2026-08-21T01:02:30.0000000Z" /></TestRun>' -f [guid]::NewGuid()) | Set-Content -LiteralPath (Join-Path $trxSubdir 'p3.trx') -Encoding utf8
    ('<TestRun id="{0}"><Times start="2026-08-21T01:01:30.0000000Z" finish="2026-08-21T01:04:00.0000000Z" /></TestRun>' -f [guid]::NewGuid()) | Set-Content -LiteralPath (Join-Path $trxSubdir 'p4.trx') -Encoding utf8

    $invWindow = Get-V02LiveWidgetsInvocationWindow -TestResultDirectory $trxSubdir
    if ($invWindow.StartedUtc -ne $t1Start.ToUniversalTime()) {
        throw "Expected invocation StartedUtc $t1Start, got $($invWindow.StartedUtc)"
    }
    if ($invWindow.FinishedUtc -ne $t4End.ToUniversalTime()) {
        throw "Expected invocation FinishedUtc $t4End, got $($invWindow.FinishedUtc)"
    }
    if ($invWindow.TrxFiles.Count -ne 4) {
        throw "Expected 4 TRX files in invocation window, got $($invWindow.TrxFiles.Count)"
    }
    Write-Output 'PASS Get-V02LiveWidgetsInvocationWindow resolves exact invocation boundary from TRX set'

    # Missing TRX directory / < 4 TRX files
    Assert-Throws { Get-V02LiveWidgetsInvocationWindow -TestResultDirectory (Join-Path $root 'missing-dir') } 'missing TRX directory is rejected'
    Remove-Item -LiteralPath (Join-Path $trxSubdir 'p4.trx') -Force
    Assert-Throws { Get-V02LiveWidgetsInvocationWindow -TestResultDirectory $trxSubdir } 'fewer than 4 TRX files is rejected'

    # 5. End-to-End CI -SkipBuild Simulation (reproduces CI execution where live-widget-run.json is missing initially)
    $mockArtifactRoot = Join-Path $root 'mock-ci-artifacts'
    $mockTrxDir = Join-Path $mockArtifactRoot 'test-results'
    $mockGateDir = Join-Path $mockArtifactRoot 'release-gates\v0.2.0\issue-10'
    $mockDesignDir = Join-Path $mockArtifactRoot 'design-evidence\v0.2.0\issue-10\contract-backed-wpf'
    $mockPerfDir = Join-Path $mockArtifactRoot 'performance-evidence\v0.2.0\issue-10'
    New-Item -ItemType Directory -Path $mockTrxDir, $mockGateDir, $mockDesignDir, $mockPerfDir -Force | Out-Null

    $ciCommit = ('c' * 40)
    $ciToken = 'ci-run-32447004264-1'

    # Write 4 TRX files representing the CI test run
    foreach ($i in 1..4) {
        ('<TestRun id="{0}"><Times start="2026-08-21T02:00:00.0000000Z" finish="2026-08-21T02:05:00.0000000Z" /></TestRun>' -f [guid]::NewGuid()) | Set-Content -LiteralPath (Join-Path $mockTrxDir ("test-$i.trx")) -Encoding utf8
    }

    # Write capture files and captures metadata
    foreach ($capName in @('compact.png', 'normal.png', 'floating-vertical.png')) {
        ('mock-png-content-for-' + $capName + '-' + ('X' * 5000)) | Set-Content -LiteralPath (Join-Path $mockDesignDir $capName) -Encoding utf8
    }
    $capFiles = @('compact.png', 'normal.png', 'floating-vertical.png') | ForEach-Object {
        [pscustomobject]@{ Name = $_; Sha256 = Get-V02LiveWidgetsSha256 -Path (Join-Path $mockDesignDir $_) }
    }
    [pscustomobject]@{
        EvidenceKind = 'captures'
        RunToken = $ciToken
        SourceCommit = $ciCommit
        GeneratedUtc = '2026-08-21T02:02:00.0000000Z'
        Files = $capFiles
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $mockGateDir 'live-widget-captures.json') -Encoding utf8

    # Write measurement file and measurement metadata
    $measFile = Join-Path $mockPerfDir 'contract-backed-widget-measurement.txt'
    "EvidenceClass: Synthetic`nSamples: 200`nSyntheticTargetResult: PASS`nActualHerdrRuntime: NOT OBSERVED / NOT CLAIMED`nReferenceHostLatency: PENDING`nCorePlusAppResourceBudget: PENDING`nActualRuntimeGate: PENDING`nP95Ms: 12.345`n" | Set-Content -LiteralPath $measFile -Encoding utf8
    [pscustomobject]@{
        EvidenceKind = 'measurement'
        RunToken = $ciToken
        SourceCommit = $ciCommit
        GeneratedUtc = '2026-08-21T02:03:00.0000000Z'
        Files = @([pscustomobject]@{ Name = 'contract-backed-widget-measurement.txt'; Sha256 = Get-V02LiveWidgetsSha256 -Path $measFile })
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $mockGateDir 'live-widget-measurement.json') -Encoding utf8

    # Confirm live-widget-run.json does NOT exist initially in CI SkipBuild scenario
    $runManifestPath = Get-V02LiveWidgetsRunManifestPath -ArtifactRoot $mockArtifactRoot
    if (Test-Path -LiteralPath $runManifestPath -PathType Leaf) {
        throw 'live-widget-run.json unexpectedly exists before SkipBuild binding.'
    }

    # Simulate SkipBuild binding: resolve invocation window and bind fresh manifest
    $simInvocation = Get-V02LiveWidgetsInvocationWindow -TestResultDirectory $mockTrxDir
    $null = New-V02LiveWidgetsRunManifest `
        -ArtifactRoot $mockArtifactRoot `
        -SourceCommit $ciCommit `
        -RunToken $ciToken `
        -StartedUtc $simInvocation.StartedUtc `
        -FinishedUtc $simInvocation.FinishedUtc

    # Verify live-widget-run.json was created and passes Assert-V02LiveWidgetsRunManifest
    if (-not (Test-Path -LiteralPath $runManifestPath -PathType Leaf)) {
        throw 'live-widget-run.json was not created by SkipBuild binding.'
    }
    $verifiedManifest = Read-V02LiveWidgetsJson -Path $runManifestPath
    $verifiedWindow = Assert-V02LiveWidgetsRunManifest -Manifest $verifiedManifest -ExpectedCommit $ciCommit -ExpectedToken $ciToken

    # Verify TRX set and metadata assertion against the bound window
    $simTrxSet = Get-V02LiveWidgetsTrxSet -Directory $mockTrxDir -StartedUtc $verifiedWindow.StartedUtc -FinishedUtc $verifiedWindow.FinishedUtc
    if ($simTrxSet.Count -ne 4) { throw "Expected 4 TRX files, got $($simTrxSet.Count)" }

    $simCapturesMeta = Read-V02LiveWidgetsJson -Path (Join-Path $mockGateDir 'live-widget-captures.json')
    Assert-V02LiveWidgetsEvidenceMetadata `
        -Metadata $simCapturesMeta `
        -ExpectedKind 'captures' `
        -ExpectedCommit $ciCommit `
        -ExpectedToken $ciToken `
        -EvidenceDirectory $mockDesignDir `
        -ExpectedNames @('compact.png', 'normal.png', 'floating-vertical.png') `
        -StartedUtc $verifiedWindow.StartedUtc `
        -FinishedUtc $verifiedWindow.FinishedUtc

    $simMeasMeta = Read-V02LiveWidgetsJson -Path (Join-Path $mockGateDir 'live-widget-measurement.json')
    Assert-V02LiveWidgetsEvidenceMetadata `
        -Metadata $simMeasMeta `
        -ExpectedKind 'measurement' `
        -ExpectedCommit $ciCommit `
        -ExpectedToken $ciToken `
        -EvidenceDirectory $mockPerfDir `
        -ExpectedNames @('contract-backed-widget-measurement.txt') `
        -StartedUtc $verifiedWindow.StartedUtc `
        -FinishedUtc $verifiedWindow.FinishedUtc

    Write-Output 'PASS CI SkipBuild reproduction binds fresh current-run manifest and passes all provenance checks'

    Write-Output 'Test-V02LiveWidgetsProvenance.Tests: PASS'
}
finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
