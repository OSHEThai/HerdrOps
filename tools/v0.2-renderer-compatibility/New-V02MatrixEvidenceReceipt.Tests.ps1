#requires -Version 5.1

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'RendererCompatibility.Common.ps1')

$scriptName = 'New-V02MatrixEvidenceReceipt.ps1'
$scriptPath = Join-Path $PSScriptRoot $scriptName

$tempDir = Join-Path $env:TEMP "HerdrOps-MatrixTests-$([guid]::NewGuid())"
$tempDirFail = Join-Path $env:TEMP "HerdrOps-MatrixTests-$([guid]::NewGuid())"
$tempDirPass = Join-Path $env:TEMP "HerdrOps-MatrixTests-$([guid]::NewGuid())"

New-Item -Path $tempDir -ItemType Directory | Out-Null
New-Item -Path $tempDirFail -ItemType Directory | Out-Null
New-Item -Path $tempDirPass -ItemType Directory | Out-Null

try {
    # Test 1: Fabricated PASS is forbidden (missing outcomes default to FAIL)
    $outcomes = @{}
    $result = & $scriptPath -DestinationPath $tempDir -OperatorIdentity '@yutthaphon' -ReviewerIdentity '@yutthaphon' -EvidenceBoundary 'Static' -Outcomes $outcomes -RepositoryRoot (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    if ($result.Count -ne 18) { throw "Expected 18 receipts generated." }
    
    foreach ($f in $result) {
        $json = Get-Content $f -Raw | ConvertFrom-Json
        if ($json.aggregateStatus -cne 'FAIL') {
            throw "Expected default status to be FAIL. Fabricated PASS detected in $f"
        }
        if ($json.observations[0].outcome -cne 'FAIL') {
            throw "Expected default outcome to be FAIL. Fabricated PASS detected in $f"
        }
        $notesObj = ConvertFrom-Json $json.observations[0].notes
        if ($notesObj.OperatorIdentity -cne '@yutthaphon' -or $notesObj.ReviewerIdentity -cne '@yutthaphon' -or $notesObj.EvidenceBoundary -cne 'Static') {
            throw "Identity or boundary fields missing in notes."
        }
    }

    # Test 2: Atomic creation fails if an outcome is invalid, rolling back partial writes
    $outcomesInvalid = @{
        '1920x1080-100' = 'PASS'
        '1920x1080-125' = 'INVALID_STATUS'
    }
    
    $failed = $false
    try {
        & $scriptPath -DestinationPath $tempDirFail -OperatorIdentity '@user' -ReviewerIdentity '@reviewer' -EvidenceBoundary 'Synthetic' -Outcomes $outcomesInvalid -RepositoryRoot (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    } catch {
        $failed = $true
    }
    if (-not $failed) { throw "Expected failure on invalid outcome." }
    
    if (@(Get-ChildItem -Path $tempDirFail).Count -ne 0) {
        throw "Expected atomic rollback of files on failure."
    }

    # Test 3: Explicit PASS is accepted
    $outcomesExplicit = @{}
    foreach ($case in $script:RendererDisplayCases + $script:RendererMixedDpiCases + $script:RendererAccessibilityCases) {
        $outcomesExplicit[$case] = 'PASS'
    }
    
    $resultPass = & $scriptPath -DestinationPath $tempDirPass -OperatorIdentity '@yutthaphon' -ReviewerIdentity '@yutthaphon' -EvidenceBoundary 'Synthetic' -Outcomes $outcomesExplicit -RepositoryRoot (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    
    foreach ($f in $resultPass) {
        $json = Get-Content $f -Raw | ConvertFrom-Json
        if ($json.aggregateStatus -cne 'PASS') {
            throw "Expected explicit PASS to be accepted."
        }
    }

    Write-Host "All tests passed for $($PSVersionTable.PSVersion)."
} finally {
    if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force }
    if (Test-Path $tempDirFail) { Remove-Item $tempDirFail -Recurse -Force }
    if (Test-Path $tempDirPass) { Remove-Item $tempDirPass -Recurse -Force }
}

