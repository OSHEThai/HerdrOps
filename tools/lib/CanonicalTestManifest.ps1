# HerdrOps Canonical Test Manifest Library
# Issue #9, #10, #135: Authenticated test manifest bound to exact HEAD, tree, 4 unique projects, result-row validation, and 888/888/0 counters

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
    $seenProjectNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $seenFileHashes = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $seenFileNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    $startTimes = New-Object System.Collections.Generic.List[DateTimeOffset]
    $finishTimes = New-Object System.Collections.Generic.List[DateTimeOffset]

    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        foreach ($file in ($trxFiles | Sort-Object Name)) {
            if (-not $seenFileNames.Add($file.Name)) {
                throw "Duplicate TRX file name detected: $($file.Name)"
            }

            $bytes = [IO.File]::ReadAllBytes($file.FullName)
            $fileHash = ([BitConverter]::ToString($sha256.ComputeHash($bytes))).Replace("-", "").ToUpperInvariant()
            if (-not $seenFileHashes.Add($fileHash)) {
                throw "Duplicate TRX content hash detected: $fileHash ($($file.Name))"
            }

            $memory = New-Object IO.MemoryStream(, $bytes)
            $trx = New-Object Xml.XmlDocument
            try {
                $trx.Load($memory)
            } finally {
                $memory.Dispose()
            }

            # Parse Times for execution window
            if ($null -ne $trx.TestRun.Times) {
                if (-not [string]::IsNullOrWhiteSpace($trx.TestRun.Times.start)) {
                    $startTimes.Add([DateTimeOffset]::Parse($trx.TestRun.Times.start))
                }
                if (-not [string]::IsNullOrWhiteSpace($trx.TestRun.Times.finish)) {
                    $finishTimes.Add([DateTimeOffset]::Parse($trx.TestRun.Times.finish))
                }
            }

            $unitTests = @($trx.TestRun.TestDefinitions.UnitTest)
            if ($unitTests.Count -eq 0) {
                throw "TRX file contains zero UnitTest definitions: $($file.Name)"
            }

            $matchedProject = $null
            # Identify project from unit test definitions
            foreach ($ut in $unitTests) {
                $storage = [string]$ut.storage
                $className = if ($null -ne $ut.TestMethod) { [string]$ut.TestMethod.className } else { "" }
                foreach ($p in $expectedProjects) {
                    if ($storage -match "(?i)[\\/]?$p\.dll$" -or $storage -match "(?i)$p" -or $className.StartsWith($p, [StringComparison]::OrdinalIgnoreCase) -or $file.Name -match "(?i)$p") {
                        if ($null -eq $matchedProject) {
                            $matchedProject = $p
                        } elseif ($matchedProject -cne $p) {
                            throw "TRX file contains mixed project definitions ($matchedProject vs $p): $($file.Name)"
                        }
                    }
                }
            }

            if ($null -eq $matchedProject) {
                throw "Could not identify canonical test project for TRX file: $($file.Name)"
            }

            if (-not $seenProjectNames.Add($matchedProject)) {
                throw "Duplicate test project results detected in manifest: $matchedProject"
            }

            # Result row validation: inspect every UnitTestResult element
            $results = @($trx.TestRun.Results.UnitTestResult)
            if ($results.Count -eq 0) {
                throw "TRX file contains zero UnitTestResult rows: $($file.Name)"
            }

            $fileResultPassed = 0
            $fileResultFailed = 0
            $fileResultOther = 0

            foreach ($res in $results) {
                $outcome = [string]$res.outcome
                if ($outcome -ceq 'Passed') {
                    $fileResultPassed++
                } elseif ($outcome -ceq 'Failed') {
                    $fileResultFailed++
                } else {
                    $fileResultOther++
                }
            }

            $counters = $trx.TestRun.ResultSummary.Counters
            $fileTotal = [int]$counters.total
            $filePassed = [int]$counters.passed
            $fileFailed = [int]$counters.failed
            $fileSkipped = [int]$counters.notExecuted

            if ($results.Count -ne $fileTotal) {
                throw "Result row count ($($results.Count)) does not match Counters.total ($fileTotal) in $($file.Name)"
            }

            if ($fileResultPassed -ne $filePassed -or $fileResultFailed -ne $fileFailed -or $fileResultOther -ne $fileSkipped) {
                throw "Result row outcomes do not match Counters in $($file.Name): rowsPassed=$fileResultPassed countersPassed=$filePassed"
            }

            if ($fileFailed -ne 0 -or $fileSkipped -ne 0 -or $fileResultFailed -ne 0 -or $fileResultOther -ne 0) {
                throw "TRX file contains non-passing test results: $($file.Name) (failed=$fileFailed, skipped=$fileSkipped)"
            }

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

    foreach ($p in $expectedProjects) {
        if (-not $seenProjectNames.Contains($p)) {
            throw "Canonical test results omitted expected project: $p"
        }
    }

    if ($projectEntries.Count -ne 4) {
        throw "Canonical test results must contain exactly one TRX per expected project without duplicates."
    }

    if ($totalTests -ne 888 -or $passedTests -ne 888 -or $failedTests -ne 0 -or $skippedTests -ne 0) {
        throw "Canonical test counters are not exact 888/888/0: total=$totalTests passed=$passedTests failed=$failedTests skipped=$skippedTests"
    }

    # Sort project entries deterministically by ProjectName
    $sortedProjects = @($projectEntries | Sort-Object -Property ProjectName)

    $earliestStart = if ($startTimes.Count -gt 0) { ($startTimes | Sort-Object)[0].ToString("O") } else { [DateTimeOffset]::UtcNow.ToString("O") }
    $latestFinish = if ($finishTimes.Count -gt 0) { ($finishTimes | Sort-Object)[-1].ToString("O") } else { [DateTimeOffset]::UtcNow.ToString("O") }

    $manifest = [pscustomobject][ordered]@{
        SchemaVersion = 2
        EvidenceClass = "CanonicalTestResultsManifest"
        SourceCommit = $sourceCommit
        SourceTree = $sourceTree
        Configuration = $Configuration
        ExecutionWindow = [pscustomobject][ordered]@{
            StartUtc = $earliestStart
            EndUtc = $latestFinish
        }
        GeneratedUtc = ([DateTimeOffset]::UtcNow.ToString("O"))
        TotalTests = $totalTests
        PassedTests = $passedTests
        FailedTests = $failedTests
        SkippedTests = $skippedTests
        Projects = $sortedProjects
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

    $expectedProjects = @(
        "HerdrOps.ContractTests",
        "HerdrOps.IntegrationTests",
        "HerdrOps.RuntimeTests",
        "HerdrOps.UnitTests"
    )

    $manifestProjectNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $manifestFileNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $manifestHashes = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    foreach ($p in $projects) {
        if (-not $manifestProjectNames.Add([string]$p.ProjectName)) {
            throw "Duplicate ProjectName in manifest: $($p.ProjectName)"
        }
        if (-not $manifestFileNames.Add([string]$p.FileName)) {
            throw "Duplicate FileName in manifest: $($p.FileName)"
        }
        if (-not $manifestHashes.Add([string]$p.Sha256)) {
            throw "Duplicate Sha256 in manifest: $($p.Sha256)"
        }
    }

    foreach ($ep in $expectedProjects) {
        if (-not $manifestProjectNames.Contains($ep)) {
            throw "Manifest omitted expected project: $ep"
        }
    }

    $actualTrxFiles = @(Get-ChildItem -LiteralPath $TestResultsDirectory -Filter "*.trx" -File)
    if ($actualTrxFiles.Count -ne 4) {
        throw "Test results directory contains $($actualTrxFiles.Count) TRX files; expected exactly 4 authenticated TRX files."
    }

    $actualTotal = 0
    $actualPassed = 0

    foreach ($project in $projects) {
        $trxPath = Join-Path $TestResultsDirectory $project.FileName
        if (-not (Test-Path -LiteralPath $trxPath -PathType Leaf)) {
            throw "TRX file listed in manifest not found: $trxPath"
        }
        $actualHash = (Get-FileHash -LiteralPath $trxPath -Algorithm SHA256).Hash.ToUpperInvariant()
        if ($actualHash -cne [string]$project.Sha256) {
            throw "TRX file hash mismatch for $($project.FileName): expected=$($project.Sha256) observed=$actualHash"
        }

        # Validate actual TRX contents
        $bytes = [IO.File]::ReadAllBytes($trxPath)
        $memory = New-Object IO.MemoryStream(, $bytes)
        $trx = New-Object Xml.XmlDocument
        try {
            $trx.Load($memory)
        } finally {
            $memory.Dispose()
        }

        $results = @($trx.TestRun.Results.UnitTestResult)
        if ($results.Count -ne [int]$project.Total) {
            throw "TRX $($project.FileName) result row count ($($results.Count)) does not match manifest total ($($project.Total))"
        }
        foreach ($res in $results) {
            if ([string]$res.outcome -cne 'Passed') {
                throw "TRX $($project.FileName) contains non-passing result row outcome: $($res.outcome)"
            }
        }

        $actualTotal += [int]$project.Total
        $actualPassed += [int]$project.Passed
    }

    if ($actualTotal -ne $ExpectedTotal -or $actualPassed -ne $ExpectedPassed) {
        throw "TRX aggregate actual results mismatch: expected $ExpectedTotal/$ExpectedPassed, observed $actualTotal/$actualPassed"
    }

    return $manifest
}
