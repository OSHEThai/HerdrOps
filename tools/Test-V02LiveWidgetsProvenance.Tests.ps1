[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\V02LiveWidgetsProvenance.ps1')

$root = Join-Path ([IO.Path]::GetTempPath()) ('herdops-v02-widget-provenance-' + [guid]::NewGuid().ToString('N'))
$trxRoot = Join-Path $root 'test-results'
$evidenceRoot = Join-Path $root 'evidence'
New-Item -ItemType Directory -Path $trxRoot, $evidenceRoot -Force | Out-Null

function Assert-Throws {
    param([scriptblock]$Action, [string]$Name)
    $thrown = $false
    try { & $Action } catch { $thrown = $true }
    if (-not $thrown) { throw "Expected failure did not occur: $Name" }
    Write-Output "PASS $Name"
}

try {
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

    '<TestRun id="bad"><Times start="2026-08-21T00:01:00.0000000Z" finish="2026-08-21T00:02:00.0000000Z" /></TestRun>' | Set-Content -LiteralPath (Join-Path $trxRoot 'mixed.trx') -Encoding utf8
    Assert-Throws { Get-V02LiveWidgetsTrxSet -Directory $trxRoot -StartedUtc $started -FinishedUtc $finished } 'mixed/duplicate current run is rejected'
    Remove-Item -LiteralPath (Join-Path $trxRoot 'mixed.trx') -Force

    Remove-Item -LiteralPath (Join-Path $trxRoot 'current-4.trx') -Force
    Assert-Throws { Get-V02LiveWidgetsTrxSet -Directory $trxRoot -StartedUtc $started -FinishedUtc $finished } 'missing current TRX is rejected'
    Remove-Item -LiteralPath (Join-Path $trxRoot 'current-1.trx'), (Join-Path $trxRoot 'current-2.trx'), (Join-Path $trxRoot 'current-3.trx'), (Join-Path $trxRoot 'old.trx') -Force

    $capture = Join-Path $evidenceRoot 'capture.png'
    'capture-bytes' | Set-Content -LiteralPath $capture -Encoding utf8
    $metadata = [pscustomobject]@{
        EvidenceKind = 'captures'
        RunToken = 'run-token-01'
        SourceCommit = ('a' * 40)
        GeneratedUtc = '2026-08-21T00:03:00.0000000Z'
        Files = @([pscustomobject]@{ Name = 'capture.png'; Sha256 = Get-V02LiveWidgetsSha256 -Path $capture })
    }
    Assert-V02LiveWidgetsEvidenceMetadata -Metadata $metadata -ExpectedKind captures -ExpectedCommit ('a' * 40) -ExpectedToken 'run-token-01' -EvidenceDirectory $evidenceRoot -ExpectedNames @('capture.png') -StartedUtc $started -FinishedUtc $finished
    Write-Output 'PASS current capture metadata binds token, HEAD, window and hash'
    $metadata.RunToken = 'stale-token'
    Assert-Throws { Assert-V02LiveWidgetsEvidenceMetadata -Metadata $metadata -ExpectedKind captures -ExpectedCommit ('a' * 40) -ExpectedToken 'run-token-01' -EvidenceDirectory $evidenceRoot -ExpectedNames @('capture.png') -StartedUtc $started -FinishedUtc $finished } 'stale capture metadata is rejected'

    Write-Output 'Test-V02LiveWidgetsProvenance.Tests: PASS'
}
finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
