Set-StrictMode -Version Latest

function Get-V02LiveWidgetsSha256 {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required provenance file is missing: $Path"
    }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Get-V02LiveWidgetsSourceCommit {
    param([Parameter(Mandatory)][string]$RepositoryRoot)
    $commit = (& git -C $RepositoryRoot rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $commit -notmatch '^[0-9a-fA-F]{40}$') {
        throw 'Could not resolve the current source commit.'
    }
    return $commit.ToLowerInvariant()
}

function Get-V02LiveWidgetsRunManifestPath {
    param([Parameter(Mandatory)][string]$ArtifactRoot)
    return (Join-Path $ArtifactRoot 'release-gates\v0.2.0\issue-10\live-widget-run.json')
}

function Read-V02LiveWidgetsJson {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required provenance manifest is missing: $Path"
    }
    try {
        $value = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    } catch {
        throw "Provenance manifest is not valid JSON: $Path"
    }
    if ($null -eq $value) { throw "Provenance manifest is empty: $Path" }
    return $value
}

function Convert-ToV02UtcDateTimeOffset {
    param([Parameter(Mandatory)]$Value)

    if ($Value -is [DateTimeOffset]) {
        return $Value.ToUniversalTime()
    }
    if ($Value -is [DateTime]) {
        return ([DateTimeOffset]$Value).ToUniversalTime()
    }
    $dto = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$dto)) {
        return $dto.ToUniversalTime()
    }
    throw "Invalid date/time value: $Value"
}

function Assert-V02LiveWidgetsRunManifest {
    param(
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)][string]$ExpectedCommit,
        [Parameter(Mandatory)][string]$ExpectedToken
    )
    if ([string]$Manifest.SourceCommit -cne $ExpectedCommit) { throw 'Run manifest source commit does not match HEAD.' }
    if ([string]$Manifest.RunToken -cne $ExpectedToken) { throw 'Run manifest token does not match the requested run.' }
    try {
        $started = Convert-ToV02UtcDateTimeOffset -Value $Manifest.StartedUtc
    } catch {
        throw 'Run manifest StartedUtc is invalid.'
    }
    try {
        $finished = Convert-ToV02UtcDateTimeOffset -Value $Manifest.FinishedUtc
    } catch {
        throw 'Run manifest FinishedUtc is invalid.'
    }
    if ($finished -lt $started) { throw 'Run manifest UTC window is inverted.' }
    if (($finished - $started).TotalSeconds -le 0) { throw 'Run manifest UTC window is empty.' }
    return [pscustomobject]@{ StartedUtc = $started; FinishedUtc = $finished }
}

function Assert-V02LiveWidgetsTimestampInWindow {
    param(
        [Parameter(Mandatory)][DateTimeOffset]$Timestamp,
        [Parameter(Mandatory)][DateTimeOffset]$StartedUtc,
        [Parameter(Mandatory)][DateTimeOffset]$FinishedUtc,
        [Parameter(Mandatory)][string]$Description
    )
    $utc = $Timestamp.ToUniversalTime()
    if ($utc -lt $StartedUtc -or $utc -gt $FinishedUtc) { throw "$Description is outside the declared run window." }
}

function Assert-V02LiveWidgetsTrxSet {
    param(
        [Parameter(Mandatory)][System.IO.FileInfo[]]$Files,
        [Parameter(Mandatory)][DateTimeOffset]$StartedUtc,
        [Parameter(Mandatory)][DateTimeOffset]$FinishedUtc
    )
    if ($Files.Count -ne 4) { throw "Expected exactly four TRX files for one run, found $($Files.Count)." }
    $ids = @{}
    foreach ($file in $Files) {
        [xml]$trx = Get-Content -LiteralPath $file.FullName -Raw
        $run = $trx.TestRun
        if ($null -eq $run) { throw "TRX has no TestRun root: $($file.FullName)" }
        $id = [string]$run.id
        if ([string]::IsNullOrWhiteSpace($id)) { throw "TRX has no run id: $($file.FullName)" }
        if ($ids.ContainsKey($id)) { throw "Duplicate TRX run id detected: $id" }
        $ids[$id] = $file.FullName
        try {
            $start = Convert-ToV02UtcDateTimeOffset -Value $run.Times.start
        } catch {
            throw "TRX start time is invalid: $($file.FullName)"
        }
        try {
            $finish = Convert-ToV02UtcDateTimeOffset -Value $run.Times.finish
        } catch {
            throw "TRX finish time is invalid: $($file.FullName)"
        }
        Assert-V02LiveWidgetsTimestampInWindow -Timestamp $start -StartedUtc $StartedUtc -FinishedUtc $FinishedUtc -Description "TRX start $($file.Name)"
        Assert-V02LiveWidgetsTimestampInWindow -Timestamp $finish -StartedUtc $StartedUtc -FinishedUtc $FinishedUtc -Description "TRX finish $($file.Name)"
        if ($finish -lt $start) { throw "TRX time window is inverted: $($file.FullName)" }
    }
}

function Get-V02LiveWidgetsTrxSet {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][DateTimeOffset]$StartedUtc,
        [Parameter(Mandatory)][DateTimeOffset]$FinishedUtc
    )
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        throw "Test result directory is missing: $Directory"
    }
    $startBoundary = $StartedUtc.ToUniversalTime()
    $finishBoundary = $FinishedUtc.ToUniversalTime()
    $files = @(Get-ChildItem -LiteralPath $Directory -Filter '*.trx' -File | Where-Object {
        try {
            [xml]$candidate = Get-Content -LiteralPath $_.FullName -Raw
            $start = Convert-ToV02UtcDateTimeOffset -Value $candidate.TestRun.Times.start
            $finish = Convert-ToV02UtcDateTimeOffset -Value $candidate.TestRun.Times.finish
            $start -ge $startBoundary -and $finish -le $finishBoundary
        } catch { $false }
    })
    Assert-V02LiveWidgetsTrxSet -Files $files -StartedUtc $startBoundary -FinishedUtc $finishBoundary
    return $files
}

function Get-V02LiveWidgetsInvocationWindow {
    param(
        [Parameter(Mandatory)][string]$TestResultDirectory,
        [DateTimeOffset[]]$EvidenceTimestamps
    )
    if (-not (Test-Path -LiteralPath $TestResultDirectory -PathType Container)) {
        throw "Test result directory is missing: $TestResultDirectory"
    }

    $allFiles = @(Get-ChildItem -LiteralPath $TestResultDirectory -Filter '*.trx' -File)
    if ($allFiles.Count -lt 4) {
        throw "Expected TRX output from at least four test projects, found $($allFiles.Count)."
    }

    $parsedList = @()
    foreach ($file in $allFiles) {
        try {
            [xml]$trx = Get-Content -LiteralPath $file.FullName -Raw
            $run = $trx.TestRun
            if ($null -eq $run) { continue }
            $id = [string]$run.id
            if ([string]::IsNullOrWhiteSpace($id)) { continue }
            $start = Convert-ToV02UtcDateTimeOffset -Value $run.Times.start
            $finish = Convert-ToV02UtcDateTimeOffset -Value $run.Times.finish
            if ($finish -lt $start) { continue }
            $parsedList += [pscustomobject]@{
                File   = $file
                Id     = $id
                Start  = $start
                Finish = $finish
            }
        } catch { }
    }

    if ($parsedList.Count -lt 4) {
        throw "Expected at least four valid TRX files, found $($parsedList.Count)."
    }

    # Sort candidate TRX records by embedded XML Finish descending, then Start descending.
    # This strictly eliminates file-system LastWriteTimeUtc manipulation/ambiguity.
    $sorted = @($parsedList | Sort-Object -Property @{ Expression = { $_.Finish }; Descending = $true }, @{ Expression = { $_.Start }; Descending = $true }, @{ Expression = { $_.File.FullName }; Descending = $false })

    $candidateSets = @()
    for ($i = 0; $i -le $sorted.Count - 4; $i++) {
        $candidateFour = @($sorted[$i..($i + 3)])
        $ids = @{}
        $hasDuplicateId = $false
        foreach ($c in $candidateFour) {
            if ($ids.ContainsKey($c.Id)) { $hasDuplicateId = $true; break }
            $ids[$c.Id] = $true
        }
        if ($hasDuplicateId) { continue }

        $clusterMinStart = ($candidateFour.Start | Sort-Object)[0]
        $clusterMaxFinish = ($candidateFour.Finish | Sort-Object)[-1]

        # Coherence check: all 4 files must belong to a contiguous execution window (<= 3600s spread)
        if (($clusterMaxFinish - $clusterMinStart).TotalSeconds -gt 3600) { continue }

        # Check that if EvidenceTimestamps are provided, all evidence timestamps fall strictly within [$clusterMinStart, $clusterMaxFinish]
        $coversEvidence = $true
        if ($null -ne $EvidenceTimestamps -and $EvidenceTimestamps.Count -gt 0) {
            foreach ($ts in $EvidenceTimestamps) {
                $utc = $ts.ToUniversalTime()
                if ($utc -lt $clusterMinStart -or $utc -gt $clusterMaxFinish) {
                    $coversEvidence = $false
                    break
                }
            }
        }
        if (-not $coversEvidence) { continue }

        $candidateFiles = @($candidateFour | ForEach-Object { $_.File })
        try {
            Assert-V02LiveWidgetsTrxSet -Files $candidateFiles -StartedUtc $clusterMinStart -FinishedUtc $clusterMaxFinish
        } catch {
            continue
        }

        $candidateSets += [pscustomobject]@{
            StartedUtc  = $clusterMinStart
            FinishedUtc = $clusterMaxFinish
            TrxFiles    = $candidateFiles
        }
        break
    }

    if ($candidateSets.Count -eq 0) {
        throw "Could not resolve a coherent set of four TRX files matching the current test invocation."
    }

    return $candidateSets[0]
}

function New-V02LiveWidgetsRunManifest {
    param(
        [Parameter(Mandatory)][string]$ArtifactRoot,
        [Parameter(Mandatory)][string]$SourceCommit,
        [Parameter(Mandatory)][string]$RunToken,
        [Parameter(Mandatory)][DateTimeOffset]$StartedUtc,
        [Parameter(Mandatory)][DateTimeOffset]$FinishedUtc
    )
    if ($RunToken -notmatch '^[A-Za-z0-9._-]{8,128}$') {
        throw 'RunToken must be an explicit safe token of 8-128 characters.'
    }
    if ($SourceCommit -notmatch '^[0-9a-fA-F]{40}$') {
        throw 'SourceCommit must be a 40-character hexadecimal SHA-1 string.'
    }
    $start = $StartedUtc.ToUniversalTime()
    $finish = $FinishedUtc.ToUniversalTime()
    if ($finish -lt $start) {
        throw 'Run manifest UTC window is inverted.'
    }
    if (($finish - $start).TotalSeconds -le 0) {
        throw 'Run manifest UTC window is empty.'
    }

    $manifestPath = Get-V02LiveWidgetsRunManifestPath -ArtifactRoot $ArtifactRoot
    $manifestDirectory = Split-Path -Parent $manifestPath
    New-Item -ItemType Directory -Path $manifestDirectory -Force | Out-Null

    $manifest = [pscustomobject]@{
        Schema       = 'v0.2.issue-10.live-widget-run.v1'
        RunToken     = $RunToken
        SourceCommit = $SourceCommit.ToLowerInvariant()
        StartedUtc   = $start.ToString('O')
        FinishedUtc  = $finish.ToString('O')
    }
    $manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $manifestPath -Encoding utf8
    return $manifest
}

function Assert-V02LiveWidgetsEvidenceMetadata {
    param(
        [Parameter(Mandatory)]$Metadata,
        [Parameter(Mandatory)][string]$ExpectedKind,
        [Parameter(Mandatory)][string]$ExpectedCommit,
        [Parameter(Mandatory)][string]$ExpectedToken,
        [Parameter(Mandatory)][string]$EvidenceDirectory,
        [Parameter(Mandatory)][string[]]$ExpectedNames,
        [Parameter(Mandatory)][DateTimeOffset]$StartedUtc,
        [Parameter(Mandatory)][DateTimeOffset]$FinishedUtc
    )
    if ([string]$Metadata.EvidenceKind -cne $ExpectedKind) { throw "Evidence metadata kind is not '$ExpectedKind'." }
    if ([string]$Metadata.SourceCommit -cne $ExpectedCommit) { throw "Evidence metadata source commit does not match HEAD: $ExpectedKind" }
    if ([string]$Metadata.RunToken -cne $ExpectedToken) { throw "Evidence metadata token does not match the requested run: $ExpectedKind" }
    try {
        $generated = Convert-ToV02UtcDateTimeOffset -Value $Metadata.GeneratedUtc
    } catch {
        throw "Evidence metadata timestamp is invalid: $ExpectedKind"
    }
    Assert-V02LiveWidgetsTimestampInWindow -Timestamp $generated -StartedUtc $StartedUtc -FinishedUtc $FinishedUtc -Description "Evidence metadata $ExpectedKind"
    $files = @($Metadata.Files)
    if ($files.Count -ne $ExpectedNames.Count) { throw "Evidence metadata file count is not exact: $ExpectedKind" }
    $seen = @{}
    foreach ($entry in $files) {
        $name = [string]$entry.Name
        if ($seen.ContainsKey($name) -or $ExpectedNames -cnotcontains $name) { throw "Evidence metadata contains an unexpected or duplicate file: $name" }
        $seen[$name] = $true
        $path = Join-Path $EvidenceDirectory $name
        $actual = Get-V02LiveWidgetsSha256 -Path $path
        if ([string]$entry.Sha256 -cne $actual) { throw "Evidence hash mismatch for $name in $ExpectedKind metadata." }
    }
    foreach ($expected in $ExpectedNames) { if (-not $seen.ContainsKey($expected)) { throw "Evidence metadata is missing: $expected" } }
}
