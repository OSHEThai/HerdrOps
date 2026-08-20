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

        $acknowledged = [bool]$alert.Acknowledged
        $acknowledgementTime = [string]$alert.AcknowledgementTime
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
    $findings = @()
    if ($observedBytes -ne $ExpectedBytes) {
        $findings += "byte count $observedBytes does not match expected $ExpectedBytes"
    }
    if ($observedSha256 -ne $ExpectedSha256.ToLowerInvariant()) {
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
    if ($observedSha256 -ne $ExpectedSha256.ToLowerInvariant()) {
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

    if ($failures.Count -gt 0) {
        throw "Issue #42 soak policy fixtures failed: $($failures -join '; ')"
    }

    return $true
}
