# HerdrOps Canonical Test Manifest Library
# Issue #9, #10, #135: Authenticated test manifest bound to exact HEAD, tree, and 888/888/0 counters

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function New-CanonicalTestResultsManifest {
    param(
        [Parameter(Mandatory)]
        [string]$TestResultsDirectory,

        [string]$Configuration = "Release",

        [string]$RepositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..\..")).Path
    )

    if (-not (Test-Path -LiteralPath $TestResultsDirectory -PathType Container)) {
        throw "Test results directory does not exist: $TestResultsDirectory"
    }

    $sourceCommit = (& git -C $RepositoryRoot rev-parse HEAD).Trim().ToLowerInvariant()
    if ($LASTEXITCODE -ne 0 -or $sourceCommit -notmatch "^[0-9a-f]{40}$") {
        throw "Could not resolve Git HEAD commit for canonical test manifest."
    }

    $sourceTree = (& git -C $RepositoryRoot rev-parse "HEAD^{tree}").Trim().ToLowerInvariant()
    if ($LASTEXITCODE -ne 0 -or $sourceTree -notmatch "^[0-9a-f]{40}$") {
        throw "Could not resolve Git HEAD tree for canonical test manifest."
    }

    $trxFiles = @(Get-ChildItem -LiteralPath $TestResultsDirectory -Filter "*.trx" -File)
    if ($trxFiles.Count -ne 4) {
        throw "Canonical test results must contain exactly 4 TRX files (one per test project); found $($trxFiles.Count)."
    }

    $expectedProjects = @(
        "HerdrOps.ContractTests",
        "HerdrOps.IntegrationTests",
        "HerdrOps.RuntimeTests",
        "HerdrOps.UnitTests"
    )

    $projectEntries = New-Object System.Collections.ArrayList
    $totalTests = 0
    $passedTests = 0
    $failedTests = 0
    $skippedTests = 0

    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        foreach ($file in ($trxFiles | Sort-Object Name)) {
            $bytes = [IO.File]::ReadAllBytes($file.FullName)
            $fileHash = ([BitConverter]::ToString($sha256.ComputeHash($bytes))).Replace("-", "").ToUpperInvariant()

            $memory = New-Object IO.MemoryStream(, $bytes)
            try {
                $trx = New-Object Xml.XmlDocument
                $trx.Load($memory)
            } finally {
                $memory.Dispose()
            }

            $unitTests = @($trx.TestRun.TestDefinitions.UnitTest)
            $storage = if ($unitTests.Count -gt 0) { [string]$unitTests[0].storage } else { "" }
            $matchedProject = $null
            foreach ($p in $expectedProjects) {
                if ($storage -match [Regex]::Escape($p) -or $file.Name -match [Regex]::Escape($p)) {
                    $matchedProject = $p
                    break
                }
            }

            if ($null -eq $matchedProject -and $unitTests.Count -gt 0) {
                $className = [string]$unitTests[0].TestMethod.className
                foreach ($p in $expectedProjects) {
                    if ($className.StartsWith($p, [StringComparison]::OrdinalIgnoreCase)) {
                        $matchedProject = $p
                        break
                    }
                }
            }

            if ($null -eq $matchedProject) {
                throw "Could not identify canonical test project for TRX file: $($file.Name)"
            }

            $counters = $trx.TestRun.ResultSummary.Counters
            $fileTotal = [int]$counters.total
            $filePassed = [int]$counters.passed
            $fileFailed = [int]$counters.failed
            $fileSkipped = [int]$counters.notExecuted

            $totalTests += $fileTotal
            $passedTests += $filePassed
            $failedTests += $fileFailed
            $skippedTests += $fileSkipped

            [void]$projectEntries.Add([pscustomobject][ordered]@{
                ProjectName = $matchedProject
                FileName = $file.Name
                Sha256 = $fileHash
                Bytes = [int64]$bytes.Length
                Total = $fileTotal
                Passed = $filePassed
                Failed = $fileFailed
                Skipped = $fileSkipped
            })
        }
    } finally {
        $sha256.Dispose()
    }

    $discoveredProjects = @($projectEntries | ForEach-Object { $_.ProjectName })
    foreach ($p in $expectedProjects) {
        if ($discoveredProjects -notcontains $p) {
            throw "Canonical test results omitted expected project: $p"
        }
    }

    if ($discoveredProjects.Count -ne 4 -or (@($discoveredProjects | Select-Object -Unique).Count -ne 4)) {
        throw "Canonical test results must contain exactly one TRX per expected project without duplicates."
    }

    if ($totalTests -ne 888 -or $passedTests -ne 888 -or $failedTests -ne 0 -or $skippedTests -ne 0) {
        throw "Canonical test counters are not exact 888/888/0: total=$totalTests passed=$passedTests failed=$failedTests skipped=$skippedTests"
    }

    $manifest = [pscustomobject][ordered]@{
        SchemaVersion = 1
        SourceCommit = $sourceCommit
        SourceTree = $sourceTree
        Configuration = $Configuration
        GeneratedUtc = ([DateTimeOffset]::UtcNow.ToString("O"))
        TotalTests = $totalTests
        PassedTests = $passedTests
        FailedTests = $failedTests
        SkippedTests = $skippedTests
        Projects = @($projectEntries.ToArray())
    }

    $manifestPath = Join-Path $TestResultsDirectory "test-results-manifest.json"
    $json = $manifest | ConvertTo-Json -Depth 5
    [IO.File]::WriteAllText($manifestPath, $json + "`n", (New-Object Text.UTF8Encoding($false)))

    return [pscustomobject]@{
        Manifest = $manifest
        ManifestPath = $manifestPath
        ManifestSha256 = ((Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash).ToUpperInvariant()
    }
}

function Assert-CanonicalTestResultsManifest {
    param(
        [Parameter(Mandatory)]
        [string]$TestResultsDirectory,

        [string]$RepositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..\..")).Path,

        [int]$ExpectedTotal = 888,
        [int]$ExpectedPassed = 888
    )

    if (-not (Test-Path -LiteralPath $TestResultsDirectory -PathType Container)) {
        throw "Canonical test results directory not found: $TestResultsDirectory"
    }

    $manifestPath = Join-Path $TestResultsDirectory "test-results-manifest.json"
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Canonical test results manifest missing: $manifestPath"
    }

    $sourceCommit = (& git -C $RepositoryRoot rev-parse HEAD).Trim().ToLowerInvariant()
    $sourceTree = (& git -C $RepositoryRoot rev-parse "HEAD^{tree}").Trim().ToLowerInvariant()

    $manifestRaw = Get-Content -LiteralPath $manifestPath -Raw
    $manifest = $manifestRaw | ConvertFrom-Json

    if ([string]$manifest.SourceCommit -cne $sourceCommit) {
        throw "Canonical test results manifest SourceCommit mismatch: expected=$sourceCommit observed=$($manifest.SourceCommit)"
    }

    if ([string]$manifest.SourceTree -cne $sourceTree) {
        throw "Canonical test results manifest SourceTree mismatch: expected=$sourceTree observed=$($manifest.SourceTree)"
    }

    if ([int]$manifest.TotalTests -ne $ExpectedTotal -or
        [int]$manifest.PassedTests -ne $ExpectedPassed -or
        [int]$manifest.FailedTests -ne 0 -or
        [int]$manifest.SkippedTests -ne 0) {
        throw "Canonical test results manifest counters mismatch: expected $ExpectedTotal/$ExpectedPassed/0/0, observed $($manifest.TotalTests)/$($manifest.PassedTests)/$($manifest.FailedTests)/$($manifest.SkippedTests)"
    }

    $projects = @($manifest.Projects)
    if ($projects.Count -ne 4) {
        throw "Canonical test results manifest must contain exactly 4 projects; found $($projects.Count)."
    }

    $actualTrxFiles = @(Get-ChildItem -LiteralPath $TestResultsDirectory -Filter "*.trx" -File)
    if ($actualTrxFiles.Count -ne 4) {
        throw "Test results directory contains $($actualTrxFiles.Count) TRX files; expected exactly 4 authenticated TRX files."
    }

    foreach ($project in $projects) {
        $trxPath = Join-Path $TestResultsDirectory $project.FileName
        if (-not (Test-Path -LiteralPath $trxPath -PathType Leaf)) {
            throw "TRX file listed in manifest not found: $trxPath"
        }
        $actualHash = (Get-FileHash -LiteralPath $trxPath -Algorithm SHA256).Hash.ToUpperInvariant()
        if ($actualHash -cne [string]$project.Sha256) {
            throw "TRX file hash mismatch for $($project.FileName): expected=$($project.Sha256) observed=$actualHash"
        }
    }

    return $manifest
}
