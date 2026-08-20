Set-StrictMode -Version Latest

$script:SoakRestartToken = 'SOAK_RESTART'

function Get-SoakSha256Hex {
    param([Parameter(Mandatory)][byte[]]$Bytes)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($Bytes)
    } finally {
        $sha.Dispose()
    }

    $builder = New-Object System.Text.StringBuilder
    foreach ($byte in $hash) {
        [void]$builder.Append($byte.ToString('x2'))
    }
    return $builder.ToString()
}

function Get-SoakSha256Text {
    param([Parameter(Mandatory)][string]$Text)

    $utf8 = New-Object System.Text.UTF8Encoding($false)
    return Get-SoakSha256Hex -Bytes $utf8.GetBytes($Text)
}

function Get-SoakFileSha256 {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "file is missing or is not a leaf: $Path"
    }
    return ((Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash).ToLowerInvariant()
}

function ConvertTo-SoakSha256Normalized {
    param([Parameter(Mandatory)][string]$Value)

    $normalized = $Value.Trim().ToLowerInvariant()
    if ($normalized -notmatch '^[0-9a-f]{64}$') {
        throw "SHA-256 must be an exact 64-character lowercase hex digest; received '$Value'"
    }
    return $normalized
}

function Test-SoakBoundedTelemetry {
    param(
        [Parameter(Mandatory)][object[]]$Artifacts,
        [int]$MaxArtifacts = 64,
        [long]$MaxBytesPerArtifact = 4194304,
        [int]$MaxLinesPerArtifact = 20000,
        [int]$MaxEntriesPerArtifact = 20000,
        [int]$MaxPathLength = 260
    )

    $findings = @()
    if ($Artifacts.Count -gt $MaxArtifacts) {
        $findings += "artifact-count $($Artifacts.Count) exceeds $MaxArtifacts"
    }

    foreach ($artifact in $Artifacts) {
        $name = [string]$artifact.Name
        if ([string]::IsNullOrWhiteSpace($name)) {
            $findings += 'artifact is missing a Name'
            continue
        }
        if ([long]$artifact.Bytes -gt $MaxBytesPerArtifact) {
            $findings += "artifact '$name' bytes $($artifact.Bytes) exceeds $MaxBytesPerArtifact"
        }
        if ([int]$artifact.Lines -gt $MaxLinesPerArtifact) {
            $findings += "artifact '$name' lines $($artifact.Lines) exceeds $MaxLinesPerArtifact"
        }
        if ([int]$artifact.Entries -gt $MaxEntriesPerArtifact) {
            $findings += "artifact '$name' entries $($artifact.Entries) exceeds $MaxEntriesPerArtifact"
        }
        if ([string]$artifact.Path -and [string]$artifact.Path.Length -gt $MaxPathLength) {
            $findings += "artifact '$name' path length exceeds $MaxPathLength"
        }
    }

    return [pscustomobject]@{ Pass = ($findings.Count -eq 0); Findings = $findings }
}

function Test-SoakAlertConsistency {
    param(
        [Parameter(Mandatory)][object[]]$Events,
        [Parameter(Mandatory)][object[]]$Alerts
    )

    # Event `id` and `agentId` are immutable identity fields. Event `sequence` and alert
    # `acknowledged`/`acknowledgementTime` are mutable current state and never participate
    # in identity binding or SHA-256 provenance. An unacknowledged alert normalizes both a
    # null and an empty-string acknowledgementTime to the same "no acknowledgement" value.
    # A null or missing `acknowledged` flag fails closed rather than coercing to unacknowledged.
    $findings = @()
    $eventIds = @{}
    foreach ($event in $Events) {
        $eventId = [string]$event.Id
        if ([string]::IsNullOrWhiteSpace($eventId)) {
            $findings += 'event is missing an Id'
            continue
        }
        if ($eventIds.ContainsKey($eventId)) {
            $findings += "duplicate event id '$eventId'"
        }
        $eventIds[$eventId] = [string]$event.AgentId
    }

    $alertIds = @{}
    foreach ($alert in $Alerts) {
        $alertId = [string]$alert.Id
        if ([string]::IsNullOrWhiteSpace($alertId)) {
            $findings += 'alert is missing an Id'
            continue
        }
        if ($alertIds.ContainsKey($alertId)) {
            $findings += "duplicate alert id '$alertId'"
        }
        $alertIds[$alertId] = $true

        $eventId = [string]$alert.EventId
        if (-not $eventIds.ContainsKey($eventId)) {
            $findings += "alert '$alertId' references missing event '$eventId'"
        } else {
            if ([string]$alert.AgentId -ne $eventIds[$eventId]) {
                $findings += "alert '$alertId' agent '$($alert.AgentId)' does not match event '$eventId' agent '$($eventIds[$eventId])'"
            }
        }

        $hasAcknowledged = $true
        try {
            $ackFlag = $alert.Acknowledged
        } catch {
            $hasAcknowledged = $false
        }
        if (-not $hasAcknowledged) {
            $findings += "alert '$alertId' is missing an acknowledged flag"
            continue
        }
        if ($null -eq [object]$ackFlag) {
            $findings += "alert '$alertId' has a null acknowledged flag"
            continue
        }
        $acknowledged = [bool]$ackFlag
        $acknowledgementTime = if ($null -eq $alert.AcknowledgementTime) { '' } else { [string]$alert.AcknowledgementTime }
        if ($acknowledged) {
            if ([string]::IsNullOrWhiteSpace($acknowledgementTime)) {
                $findings += "alert '$alertId' is acknowledged without an acknowledgementTime"
            }
        } else {
            if (-not [string]::IsNullOrWhiteSpace($acknowledgementTime)) {
                $findings += "alert '$alertId' is unacknowledged but carries an acknowledgementTime"
            }
        }
    }

    return [pscustomobject]@{ Pass = ($findings.Count -eq 0); Findings = $findings }
}

function Test-SoakCandidateBytes {
    param(
        [Parameter(Mandatory)][string]$ArchivePath,
        [Parameter(Mandatory)][string]$ExpectedSha256,
        [Parameter(Mandatory)][long]$ExpectedBytes
    )

    if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) {
        return [pscustomobject]@{
            Valid = $false
            ObservedSha256 = 'MISSING'
            ObservedBytes = 0
            Findings = @("candidate archive is missing or is not a leaf: $ArchivePath")
        }
    }

    $observedBytes = [long](Get-Item -LiteralPath $ArchivePath -ErrorAction Stop).Length
    $observedSha256 = Get-SoakFileSha256 -Path $ArchivePath
    $expectedSha256 = ConvertTo-SoakSha256Normalized -Value $ExpectedSha256
    $findings = @()
    if ($observedBytes -ne $ExpectedBytes) {
        $findings += "byte count $observedBytes does not match expected $ExpectedBytes"
    }
    if ($observedSha256 -ne $expectedSha256) {
        $findings += 'SHA-256 does not match the expected candidate binding'
    }

    return [pscustomobject]@{
        Valid = ($findings.Count -eq 0)
        ObservedSha256 = $observedSha256
        ObservedBytes = $observedBytes
        Findings = $findings
    }
}

function Assert-SoakDatabaseIntegrity {
    param(
        [Parameter(Mandatory)][string]$QuickCheck,
        [Parameter(Mandatory)][string]$IntegrityCheck,
        [Parameter(Mandatory)][long]$UserVersion,
        [Parameter(Mandatory)][int[]]$AcceptedSchemaVersions,
        [Parameter(Mandatory)][string]$DatabaseListMain
    )

    $findings = @()
    if (-not $QuickCheck.Equals('ok', [StringComparison]::OrdinalIgnoreCase)) {
        $findings += "quick_check returned '$QuickCheck' instead of 'ok'"
    }
    if (-not $IntegrityCheck.Equals('ok', [StringComparison]::OrdinalIgnoreCase)) {
        $findings += "integrity_check returned '$IntegrityCheck' instead of 'ok'"
    }
    if ($AcceptedSchemaVersions -notcontains $UserVersion) {
        $findings += "user_version $UserVersion is outside the accepted set [$($AcceptedSchemaVersions -join ',')]"
    }
    if (-not $DatabaseListMain.Equals('main', [StringComparison]::OrdinalIgnoreCase)) {
        $findings += "database_list main file is '$DatabaseListMain' instead of 'main'"
    }

    return [pscustomobject]@{ Pass = ($findings.Count -eq 0); Findings = $findings }
}

function Assert-SoakDatabaseIdentity {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedSha256
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{
            Pass = $false
            ObservedSha256 = 'MISSING'
            Findings = @("database is missing or is not a leaf: $Path")
        }
    }

    $observedSha256 = Get-SoakFileSha256 -Path $Path
    $expectedSha256 = ConvertTo-SoakSha256Normalized -Value $ExpectedSha256
    if ($observedSha256 -ne $expectedSha256) {
        return [pscustomobject]@{
            Pass = $false
            ObservedSha256 = $observedSha256
            Findings = @('database byte identity does not match the expected SHA-256 binding')
        }
    }

    return [pscustomobject]@{ Pass = $true; ObservedSha256 = $observedSha256; Findings = @() }
}

function Test-SoakRestartAuthorization {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Herdr', 'Core', 'App')]
        [string]$Component,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$AuthorizationToken,

        [Parameter(Mandatory)][bool]$PreparationMode
    )

    $requiredToken = $script:SoakRestartToken

    if ($PreparationMode) {
        return [pscustomobject]@{
            Authorized = $false
            Findings = @("$Component restart is refused in preparation mode; no process was controlled.")
        }
    }

    if ([string]::IsNullOrWhiteSpace($AuthorizationToken)) {
        return [pscustomobject]@{
            Authorized = $false
            Findings = @("$Component restart requires an explicit authorization token.")
        }
    }

    if ($AuthorizationToken -cne $requiredToken) {
        return [pscustomobject]@{
            Authorized = $false
            Findings = @("$Component restart authorization token does not equal the required token.")
        }
    }

    return [pscustomobject]@{
        Authorized = $true
        Findings = @()
    }
}

function Get-SoakVerdict {
    param(
        [Parameter(Mandatory)][object[]]$Checks,
        [Parameter(Mandatory)][bool]$RuntimeObserved,
        [Parameter(Mandatory)][bool]$ReleaseObserved,
        [Parameter(Mandatory)][bool]$PreparationMode
    )

    $failures = @($Checks | Where-Object { $_.Pass -eq $false })
    if ($failures.Count -gt 0) {
        return 'FAIL'
    }

    if ($PreparationMode) {
        return 'PENDING'
    }

    if ($RuntimeObserved -and $ReleaseObserved) {
        return 'PASS'
    }

    return 'PENDING'
}

function Get-SoakProvenance {
    param([Parameter(Mandatory)][object[]]$OrderedArtifacts)

    $state = ''
    $chain = @()
    foreach ($artifact in $OrderedArtifacts) {
        $state = Get-SoakSha256Text -Text ($state + '|' + [string]$artifact.Name + '|' + [string]$artifact.Sha256)
        $chain += $state
    }
    return @($chain)
}

function New-SoakCheck {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][bool]$Pass,
        [Parameter(Mandatory)][string]$EvidenceClass,
        [Parameter(Mandatory)][string]$Detail
    )

    return [pscustomobject]@{
        Id = $Id
        Pass = $Pass
        EvidenceClass = $EvidenceClass
        Detail = $Detail
    }
}

function Test-SoakFixtureJson {
    param([Parameter(Mandatory)][string]$JsonText)

    if ([string]::IsNullOrWhiteSpace($JsonText)) {
        throw 'fixture JSON is empty or whitespace'
    }

    $parsed = $JsonText | ConvertFrom-Json
    if ($null -eq $parsed) {
        throw 'fixture JSON parsed to null'
    }

    if ([int]$parsed.schemaVersion -ne 1 -or [int]$parsed.issue -ne 42) {
        throw 'fixture schemaVersion must be 1 and issue must be 42'
    }
    if (@($parsed.events).Count -eq 0 -or @($parsed.alerts).Count -eq 0) {
        throw 'fixture events or alerts are empty'
    }

    return $parsed
}

function Format-SoakGateReport {
    param(
        [Parameter(Mandatory)][string]$IssueNumber,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$Branch,
        [Parameter(Mandatory)][string]$SourceCommit,
        [Parameter(Mandatory)][string]$Verdict,
        [Parameter(Mandatory)][string]$PolicySha256,
        [Parameter(Mandatory)][string]$ContractSha256,
        [Parameter(Mandatory)][string]$FixtureSha256,
        [Parameter(Mandatory)][object[]]$Checks,
        [string]$GeneratedUtc = ''
    )

    if ([string]::IsNullOrWhiteSpace($GeneratedUtc)) {
        $GeneratedUtc = [DateTime]::UtcNow.ToString('O')
    }

    $checkLines = @($Checks | ForEach-Object {
        "$($_.Status) $($_.Id) evidence=$($_.EvidenceClass) $($_.Detail)"
    })

    $reportLines = @(
        'HerdrOps v1.0.0 Issue #42 24-Hour Soak and Fault-Injection Preparation Gate',
        "GeneratedUtc: $GeneratedUtc",
        "Issue: $IssueNumber",
        "Version: $Version",
        "Branch: $Branch",
        "SourceCommit: $SourceCommit",
        "Result: $Verdict",
        'SoakPass: false',
        'IssueAcceptance: PENDING',
        'PreparationSlice: STATIC + SYNTHETIC + CONTRACT',
        "PolicySha256: $PolicySha256",
        "ContractSha256: $ContractSha256",
        "FixtureSha256: $FixtureSha256",
        'RuntimeEvidence: NOT OBSERVED / NOT CLAIMED',
        'ReleaseEvidence: NOT OBSERVED / NOT CLAIMED',
        '',
        'Checks:',
        ($checkLines -join [Environment]::NewLine),
        '',
        'EvidenceBoundary:',
        'No 24-hour actual-Herdr soak was run.',
        'No Herdr/Core/App process was started, stopped, or restarted.',
        'No live database was opened; database integrity remains NOT OBSERVED.',
        'No packaged release candidate, clean-machine install, publication, or go/no-go was produced.',
        'This gate refuses PASS in synthetic/preparation mode and cannot close Issue #42.'
    )

    return ($reportLines -join [Environment]::NewLine)
}

function Test-SoakPolicyFixtures {
    $failures = @()

    try {
        $abcHash = Get-SoakSha256Text -Text 'abc'
        if ($abcHash -ne 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad') {
            throw 'abc SHA-256 vector mismatch'
        }
    } catch {
        $failures += "hashing: $($_.Exception.Message)"
    }

    try {
        $normalized = ConvertTo-SoakSha256Normalized -Value (' A' + ('b' * 63) + ' ')
        if ($normalized -ne ('a' + ('b' * 63))) {
            throw "confirmed 64-hex digest was not trimmed and lowercased: '$normalized'"
        }

        foreach ($invalid in @('', 'abc', 'zz', ('0' * 63), ('0' * 65), ('g' * 64))) {
            $threw = $false
            try {
                ConvertTo-SoakSha256Normalized -Value $invalid | Out-Null
            } catch {
                $threw = $true
            }
            if (-not $threw) { throw "invalid SHA-256 '$invalid' was accepted instead of failing closed" }
        }
    } catch {
        $failures += "sha-normalization: $($_.Exception.Message)"
    }

    try {
        $bounded = Test-SoakBoundedTelemetry -Artifacts @(
            @{ Name = 'a'; Bytes = 100; Lines = 10; Entries = 5; Path = 'p' }
        ) -MaxArtifacts 2 -MaxBytesPerArtifact 200
        if (-not $bounded.Pass) { throw "bounded case failed: $($bounded.Findings -join '; ')" }

        $oversized = Test-SoakBoundedTelemetry -Artifacts @(
            @{ Name = 'a'; Bytes = 300; Lines = 10; Entries = 5; Path = 'p' }
        ) -MaxBytesPerArtifact 200
        if ($oversized.Pass) { throw 'over-limit byte case did not fail closed' }

        $overCount = Test-SoakBoundedTelemetry -Artifacts @(
            @{ Name = 'a'; Bytes = 1; Lines = 1; Entries = 1; Path = 'p' },
            @{ Name = 'b'; Bytes = 1; Lines = 1; Entries = 1; Path = 'p' },
            @{ Name = 'c'; Bytes = 1; Lines = 1; Entries = 1; Path = 'p' }
        ) -MaxArtifacts 2
        if ($overCount.Pass) { throw 'over-count case did not fail closed' }

        $overLines = Test-SoakBoundedTelemetry -Artifacts @(
            @{ Name = 'a'; Bytes = 10; Lines = 21; Entries = 5; Path = 'p' }
        ) -MaxLinesPerArtifact 20
        if ($overLines.Pass) { throw 'over-limit line case did not fail closed' }

        $overEntries = Test-SoakBoundedTelemetry -Artifacts @(
            @{ Name = 'a'; Bytes = 10; Lines = 10; Entries = 21; Path = 'p' }
        ) -MaxEntriesPerArtifact 20
        if ($overEntries.Pass) { throw 'over-limit entry case did not fail closed' }

        $overPath = Test-SoakBoundedTelemetry -Artifacts @(
            @{ Name = 'a'; Bytes = 10; Lines = 10; Entries = 5; Path = ('p' * 6) }
        ) -MaxPathLength 5
        if ($overPath.Pass) { throw 'over-limit path-length case did not fail closed' }
    } catch {
        $failures += "telemetry: $($_.Exception.Message)"
    }

    try {
        $events = @(
            @{ Id = 'e1'; AgentId = 'agent-a' },
            @{ Id = 'e2'; AgentId = 'agent-b' }
        )
        $consistentAlerts = @(
            @{ Id = 'a1'; EventId = 'e1'; AgentId = 'agent-a'; Acknowledged = $true; AcknowledgementTime = '2026-08-20T00:00:00Z' },
            @{ Id = 'a2'; EventId = 'e2'; AgentId = 'agent-b'; Acknowledged = $false; AcknowledgementTime = '' }
        )
        $consistent = Test-SoakAlertConsistency -Events $events -Alerts $consistentAlerts
        if (-not $consistent.Pass) { throw "consistent alert set failed: $($consistent.Findings -join '; ')" }

        $orphan = Test-SoakAlertConsistency -Events $events -Alerts @(
            @{ Id = 'a1'; EventId = 'missing'; AgentId = 'agent-a'; Acknowledged = $false; AcknowledgementTime = '' }
        )
        if ($orphan.Pass) { throw 'orphan alert was not detected' }

        $agentMismatch = Test-SoakAlertConsistency -Events $events -Alerts @(
            @{ Id = 'a1'; EventId = 'e1'; AgentId = 'wrong'; Acknowledged = $false; AcknowledgementTime = '' }
        )
        if ($agentMismatch.Pass) { throw 'agent mismatch was not detected' }

        $ackMismatch = Test-SoakAlertConsistency -Events $events -Alerts @(
            @{ Id = 'a1'; EventId = 'e1'; AgentId = 'agent-a'; Acknowledged = $false; AcknowledgementTime = '2026-08-20T00:00:00Z' }
        )
        if ($ackMismatch.Pass) { throw 'acknowledgement inconsistency was not detected' }

        $nullUnacknowledged = Test-SoakAlertConsistency -Events $events -Alerts @(
            @{ Id = 'a2'; EventId = 'e2'; AgentId = 'agent-b'; Acknowledged = $false; AcknowledgementTime = $null }
        )
        if (-not $nullUnacknowledged.Pass) { throw "null acknowledgementTime on an unacknowledged alert was not normalized: $($nullUnacknowledged.Findings -join '; ')" }

        $nullAcknowledged = Test-SoakAlertConsistency -Events $events -Alerts @(
            @{ Id = 'a1'; EventId = 'e1'; AgentId = 'agent-a'; Acknowledged = $true; AcknowledgementTime = $null }
        )
        if ($nullAcknowledged.Pass) { throw 'acknowledged alert with a null acknowledgementTime was accepted' }

        $nullAcknowledgedFlag = Test-SoakAlertConsistency -Events $events -Alerts @(
            @{ Id = 'a1'; EventId = 'e1'; AgentId = 'agent-a'; Acknowledged = $null; AcknowledgementTime = '' }
        )
        if ($nullAcknowledgedFlag.Pass) { throw 'alert with a null acknowledged flag was accepted instead of failing closed' }

        $missingAcknowledgedFlag = Test-SoakAlertConsistency -Events $events -Alerts @(
            @{ Id = 'a1'; EventId = 'e1'; AgentId = 'agent-a'; AcknowledgementTime = '' }
        )
        if ($missingAcknowledgedFlag.Pass) { throw 'alert with a missing acknowledged flag was accepted instead of failing closed' }

        $duplicateAlert = Test-SoakAlertConsistency -Events $events -Alerts @(
            @{ Id = 'a1'; EventId = 'e1'; AgentId = 'agent-a'; Acknowledged = $false; AcknowledgementTime = '' },
            @{ Id = 'a1'; EventId = 'e1'; AgentId = 'agent-a'; Acknowledged = $false; AcknowledgementTime = '' }
        )
        if ($duplicateAlert.Pass) { throw 'duplicate alert id was not detected' }
    } catch {
        $failures += "alert-consistency: $($_.Exception.Message)"
    }

    try {
        $candidateContent = "HerdrOps issue 42 candidate`n"
        $candidatePath = Join-Path ([IO.Path]::GetTempPath()) ("soak-candidate-" + [Guid]::NewGuid().ToString('N') + '.bin')
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        [IO.File]::WriteAllBytes($candidatePath, $utf8.GetBytes($candidateContent))
        try {
            $candidateSha = Get-SoakFileSha256 -Path $candidatePath
            $candidateBytes = [long](Get-Item -LiteralPath $candidatePath).Length

            $valid = Test-SoakCandidateBytes -ArchivePath $candidatePath -ExpectedSha256 $candidateSha -ExpectedBytes $candidateBytes
            if (-not $valid.Valid) { throw "exact candidate admission failed: $($valid.Findings -join '; ')" }

            $tampered = Test-SoakCandidateBytes -ArchivePath $candidatePath -ExpectedSha256 ('0' * 64) -ExpectedBytes $candidateBytes
            if ($tampered.Valid) { throw 'tampered candidate SHA-256 was accepted' }

            $tamperedBytes = Test-SoakCandidateBytes -ArchivePath $candidatePath -ExpectedSha256 $candidateSha -ExpectedBytes ($candidateBytes + 1)
            if ($tamperedBytes.Valid) { throw 'tampered candidate byte count was accepted' }

            $missing = Test-SoakCandidateBytes -ArchivePath (Join-Path ([IO.Path]::GetTempPath()) 'does-not-exist.bin') -ExpectedSha256 $candidateSha -ExpectedBytes 1
            if ($missing.Valid) { throw 'missing candidate archive was accepted' }
        } finally {
            Remove-Item -LiteralPath $candidatePath -Force -ErrorAction SilentlyContinue
        }
    } catch {
        $failures += "candidate-bytes: $($_.Exception.Message)"
    }

    try {
        $good = Assert-SoakDatabaseIntegrity -QuickCheck 'ok' -IntegrityCheck 'ok' -UserVersion 4 -AcceptedSchemaVersions @(1, 2, 3, 4) -DatabaseListMain 'main'
        if (-not $good.Pass) { throw "valid probe failed: $($good.Findings -join '; ')" }

        $corrupt = Assert-SoakDatabaseIntegrity -QuickCheck 'N out of M pages' -IntegrityCheck 'ok' -UserVersion 4 -AcceptedSchemaVersions @(1, 2, 3, 4) -DatabaseListMain 'main'
        if ($corrupt.Pass) { throw 'corrupt quick_check was accepted' }

        $future = Assert-SoakDatabaseIntegrity -QuickCheck 'ok' -IntegrityCheck 'ok' -UserVersion 5 -AcceptedSchemaVersions @(1, 2, 3, 4) -DatabaseListMain 'main'
        if ($future.Pass) { throw 'future user_version was accepted' }

        $wrongMain = Assert-SoakDatabaseIntegrity -QuickCheck 'ok' -IntegrityCheck 'ok' -UserVersion 4 -AcceptedSchemaVersions @(1, 2, 3, 4) -DatabaseListMain 'temp'
        if ($wrongMain.Pass) { throw 'non-main database_list was accepted' }
    } catch {
        $failures += "database-integrity: $($_.Exception.Message)"
    }

    try {
        $prep = Test-SoakRestartAuthorization -Component 'Core' -AuthorizationToken $script:SoakRestartToken -PreparationMode $true
        if ($prep.Authorized) { throw 'preparation mode authorized a restart' }

        $empty = Test-SoakRestartAuthorization -Component 'App' -AuthorizationToken '' -PreparationMode $false
        if ($empty.Authorized) { throw 'empty token authorized a restart' }

        $mismatch = Test-SoakRestartAuthorization -Component 'Herdr' -AuthorizationToken 'wrong' -PreparationMode $false
        if ($mismatch.Authorized) { throw 'mismatched token authorized a restart' }

        $exact = Test-SoakRestartAuthorization -Component 'Core' -AuthorizationToken $script:SoakRestartToken -PreparationMode $false
        if (-not $exact.Authorized) { throw "exact token was not authorized: $($exact.Findings -join '; ')" }
    } catch {
        $failures += "restart-authorization: $($_.Exception.Message)"
    }

    try {
        $passChecks = @((New-SoakCheck -Id 'c1' -Pass $true -EvidenceClass 'Synthetic' -Detail 'ok'))

        $prepVerdict = Get-SoakVerdict -Checks $passChecks -RuntimeObserved $false -ReleaseObserved $false -PreparationMode $true
        if ($prepVerdict -ne 'PENDING') { throw "preparation mode returned '$prepVerdict' instead of PENDING" }

        $prepWithRuntime = Get-SoakVerdict -Checks $passChecks -RuntimeObserved $true -ReleaseObserved $true -PreparationMode $true
        if ($prepWithRuntime -ne 'PENDING') { throw "preparation mode returned '$prepWithRuntime' instead of PENDING even with runtime/release" }

        $failChecks = @((New-SoakCheck -Id 'c1' -Pass $false -EvidenceClass 'Synthetic' -Detail 'fail'))
        if ((Get-SoakVerdict -Checks $failChecks -RuntimeObserved $true -ReleaseObserved $true -PreparationMode $false) -ne 'FAIL') {
            throw 'failed check did not produce FAIL'
        }

        $runtimeOnly = Get-SoakVerdict -Checks $passChecks -RuntimeObserved $true -ReleaseObserved $false -PreparationMode $false
        if ($runtimeOnly -ne 'PENDING') { throw "runtime-only returned '$runtimeOnly' instead of PENDING" }

        $fullPass = Get-SoakVerdict -Checks $passChecks -RuntimeObserved $true -ReleaseObserved $true -PreparationMode $false
        if ($fullPass -ne 'PASS') { throw "full evidence returned '$fullPass' instead of PASS" }
    } catch {
        $failures += "verdict: $($_.Exception.Message)"
    }

    try {
        $chain = Get-SoakProvenance -OrderedArtifacts @(
            @{ Name = 'a'; Sha256 = 'aa' },
            @{ Name = 'b'; Sha256 = 'bb' }
        )
        if ($chain.Count -ne 2) { throw 'provenance chain length mismatch' }
        if ($chain[0] -ne (Get-SoakSha256Text -Text '|a|aa')) { throw 'provenance link 0 mismatch' }
        if ($chain[1] -ne (Get-SoakSha256Text -Text ($chain[0] + '|b|bb'))) { throw 'provenance link 1 mismatch' }
    } catch {
        $failures += "provenance: $($_.Exception.Message)"
    }

    try {
        $validFixtureJson = @'
{
  "schemaVersion": 1,
  "issue": 42,
  "fixture": "soak-alert-consistency",
  "events": [
    { "id": "e1", "agentId": "a1", "sequence": 1 }
  ],
  "alerts": [
    { "id": "al1", "eventId": "e1", "agentId": "a1", "severity": "info", "acknowledged": false, "acknowledgementTime": "" }
  ]
}
'@
        $parsedFixture = Test-SoakFixtureJson -JsonText $validFixtureJson
        if ([int]$parsedFixture.schemaVersion -ne 1 -or [int]$parsedFixture.issue -ne 42) {
            throw 'valid fixture did not parse schemaVersion or issue correctly'
        }
        if (@($parsedFixture.events).Count -ne 1 -or @($parsedFixture.alerts).Count -ne 1) {
            throw 'valid fixture event/alert counts mismatch'
        }

        # Negative fixture cases: must fail closed without Depth parameter
        foreach ($invalidFixture in @(
            '',
            '   ',
            'not-json',
            '{"schemaVersion": 2, "issue": 42, "events": [{"id":"e1"}], "alerts": [{"id":"a1"}]}',
            '{"schemaVersion": 1, "issue": 99, "events": [{"id":"e1"}], "alerts": [{"id":"a1"}]}',
            '{"schemaVersion": 1, "issue": 42, "events": [], "alerts": [{"id":"a1"}]}',
            '{"schemaVersion": 1, "issue": 42, "events": [{"id":"e1"}], "alerts": []}'
        )) {
            $threw = $false
            try {
                Test-SoakFixtureJson -JsonText $invalidFixture | Out-Null
            } catch {
                $threw = $true
            }
            if (-not $threw) {
                throw "invalid fixture JSON was accepted instead of failing closed: '$invalidFixture'"
            }
        }
    } catch {
        $failures += "fixture-json: $($_.Exception.Message)"
    }

    try {
        # Check ordering and verdict computation regression:
        # All checks including BOUND-04 must be evaluated before verdict computation and report serialization.
        $checksPass = @(
            [pscustomobject]@{ Id = 'BOUND-01'; Status = 'PASS'; EvidenceClass = 'Static'; Detail = 'source commit resolved' },
            [pscustomobject]@{ Id = 'BOUND-02'; Status = 'PASS'; EvidenceClass = 'Static'; Detail = 'branch matches' },
            [pscustomobject]@{ Id = 'BOUND-03'; Status = 'PASS'; EvidenceClass = 'Static'; Detail = 'clean checkout' },
            [pscustomobject]@{ Id = 'CONTRACT-01'; Status = 'PASS'; EvidenceClass = 'Static'; Detail = 'contract markers' },
            [pscustomobject]@{ Id = 'STATIC-01'; Status = 'PASS'; EvidenceClass = 'Static'; Detail = 'policy parses' },
            [pscustomobject]@{ Id = 'SELF-01'; Status = 'PASS'; EvidenceClass = 'Synthetic'; Detail = 'self tests pass' },
            [pscustomobject]@{ Id = 'FIXTURE-01'; Status = 'PASS'; EvidenceClass = 'Synthetic'; Detail = 'fixture passes' },
            [pscustomobject]@{ Id = 'CANDIDATE-01'; Status = 'NOT OBSERVED'; EvidenceClass = 'Static'; Detail = 'no candidate archive' },
            [pscustomobject]@{ Id = 'INTEGRITY-01'; Status = 'NOT OBSERVED'; EvidenceClass = 'Contract'; Detail = 'no db probe' },
            [pscustomobject]@{ Id = 'RESTART-HERDR'; Status = 'NOT OBSERVED'; EvidenceClass = 'Runtime'; Detail = 'refused' },
            [pscustomobject]@{ Id = 'RESTART-CORE'; Status = 'NOT OBSERVED'; EvidenceClass = 'Runtime'; Detail = 'refused' },
            [pscustomobject]@{ Id = 'RESTART-APP'; Status = 'NOT OBSERVED'; EvidenceClass = 'Runtime'; Detail = 'refused' },
            [pscustomobject]@{ Id = 'RUNTIME-01'; Status = 'NOT OBSERVED'; EvidenceClass = 'Runtime'; Detail = 'not observed' },
            [pscustomobject]@{ Id = 'RELEASE-01'; Status = 'NOT OBSERVED'; EvidenceClass = 'Release'; Detail = 'not observed' },
            [pscustomobject]@{ Id = 'BOUND-04'; Status = 'PASS'; EvidenceClass = 'Static'; Detail = 'source commit and checkout unchanged' }
        )

        $prepChecks = @($checksPass | Where-Object { $_.Status -ne 'NOT OBSERVED' } | ForEach-Object {
            New-SoakCheck -Id $_.Id -Pass ($_.Status -eq 'PASS') -EvidenceClass $_.EvidenceClass -Detail $_.Detail
        })
        $passVerdict = Get-SoakVerdict -Checks $prepChecks -RuntimeObserved $false -ReleaseObserved $false -PreparationMode $true
        if ($passVerdict -ne 'PENDING') {
            throw "expected PENDING verdict for clean preparation checks; got '$passVerdict'"
        }

        $allChecksWithVerdict = @($checksPass) + @(
            [pscustomobject]@{ Id = 'VERDICT-01'; Status = 'PASS'; EvidenceClass = 'Synthetic'; Detail = "fail-closed verdict is $passVerdict" }
        )
        $passReport = Format-SoakGateReport -IssueNumber '#42' -Version 'v1.0.0' -Branch 'codex/v10-issue-42-soak-contract' `
            -SourceCommit ('0' * 40) -Verdict $passVerdict -PolicySha256 ('a' * 64) -ContractSha256 ('b' * 64) `
            -FixtureSha256 ('c' * 64) -Checks $allChecksWithVerdict -GeneratedUtc '2026-08-20T00:00:00.0000000Z'

        if ($passReport.IndexOf('Result: PENDING', [StringComparison]::Ordinal) -lt 0) {
            throw 'passing report does not contain Result: PENDING'
        }
        if ($passReport.IndexOf('PASS BOUND-04', [StringComparison]::Ordinal) -lt 0) {
            throw 'passing report does not contain PASS BOUND-04'
        }
        if ($passReport.IndexOf('PASS VERDICT-01', [StringComparison]::Ordinal) -lt 0) {
            throw 'passing report does not contain PASS VERDICT-01'
        }

        # When BOUND-04 fails (dirty checkout or modified commit at gate end), verdict MUST be FAIL
        $checksBound04Fail = @($checksPass | ForEach-Object {
            if ($_.Id -eq 'BOUND-04') {
                [pscustomobject]@{ Id = 'BOUND-04'; Status = 'FAIL'; EvidenceClass = 'Static'; Detail = 'checkout changed' }
            } else {
                $_
            }
        })
        $prepChecksBound04Fail = @($checksBound04Fail | Where-Object { $_.Status -ne 'NOT OBSERVED' } | ForEach-Object {
            New-SoakCheck -Id $_.Id -Pass ($_.Status -eq 'PASS') -EvidenceClass $_.EvidenceClass -Detail $_.Detail
        })
        $bound04FailVerdict = Get-SoakVerdict -Checks $prepChecksBound04Fail -RuntimeObserved $false -ReleaseObserved $false -PreparationMode $true
        if ($bound04FailVerdict -ne 'FAIL') {
            throw "expected FAIL verdict when BOUND-04 fails; got '$bound04FailVerdict'"
        }

        $allChecksBound04Fail = @($checksBound04Fail) + @(
            [pscustomobject]@{ Id = 'VERDICT-01'; Status = 'PASS'; EvidenceClass = 'Synthetic'; Detail = "fail-closed verdict is $bound04FailVerdict" }
        )
        $bound04FailReport = Format-SoakGateReport -IssueNumber '#42' -Version 'v1.0.0' -Branch 'codex/v10-issue-42-soak-contract' `
            -SourceCommit ('0' * 40) -Verdict $bound04FailVerdict -PolicySha256 ('a' * 64) -ContractSha256 ('b' * 64) `
            -FixtureSha256 ('c' * 64) -Checks $allChecksBound04Fail -GeneratedUtc '2026-08-20T00:00:00.0000000Z'

        if ($bound04FailReport.IndexOf('Result: FAIL', [StringComparison]::Ordinal) -lt 0) {
            throw 'bound-04 failure report does not contain Result: FAIL'
        }
        if ($bound04FailReport.IndexOf('Result: PENDING', [StringComparison]::Ordinal) -ge 0) {
            throw 'bound-04 failure report stale Result: PENDING was not cleared'
        }
        if ($bound04FailReport.IndexOf('FAIL BOUND-04', [StringComparison]::Ordinal) -lt 0) {
            throw 'bound-04 failure report does not contain FAIL BOUND-04 check line'
        }
    } catch {
        $failures += "report-ordering-and-verdict: $($_.Exception.Message)"
    }
    if ($failures.Count -gt 0) {
        throw "Issue #42 soak policy fixtures failed: $($failures -join '; ')"
    }


    return $true
}
