<#
.SYNOPSIS
    Build-free parser and hostile selftests for the v0.3 Issue #14 runtime wrapper.

.DESCRIPTION
    This test creates only synthetic JSON and temporary files. It never runs dotnet,
    Herdr, a session command, or the runtime trace.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$wrapperPath = Join-Path $PSScriptRoot 'Invoke-V03Issue14TerminalProcessRuntimeAcceptance.ps1'
$helperPath = Join-Path $PSScriptRoot 'lib/V03Issue14RuntimeAcceptance.ps1'
$readmePath = Join-Path $PSScriptRoot 'README.md'
$failures = New-Object 'System.Collections.Generic.List[string]'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        $failures.Add($Message)
        Write-Host "FAIL: $Message" -ForegroundColor Red
    }
    else {
        Write-Host "PASS: $Message"
    }
}

function Assert-SourceContains {
    param([string]$Path, [string]$Text, [string]$Message)
    Assert-True -Condition ([IO.File]::ReadAllText($Path).Contains($Text)) -Message $Message
}

function Assert-Parseable {
    param([string]$Path)
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors) | Out-Null
    Assert-True -Condition ($errors.Count -eq 0) -Message "$(Split-Path -Leaf $Path) parses under PowerShell $($PSVersionTable.PSVersion)"
}

function Assert-ThrowsMatching {
    param([scriptblock]$ScriptBlock, [string]$Prefix, [string]$Message)
    $thrown = $false
    try { & $ScriptBlock } catch {
        $thrown = $true
        Assert-True -Condition ($_.Exception.Message.StartsWith($Prefix)) -Message $Message
    }
    if (-not $thrown) {
        Assert-True -Condition $false -Message "$Message (no exception)"
    }
}

Assert-Parseable -Path $wrapperPath
Assert-Parseable -Path $helperPath
foreach ($text in @(
        '[string]$ExpectedSourceCommit',
        '[string]$ExpectedSourceTree',
        '[string]$ExpectedHerdrExecutablePath',
        '[string]$ExpectedHerdrExecutableSha256',
        'HERDR_ENV',
        'Get-ControlHerdrServerIdentity',
        'Get-ExpectedCleanSourceIdentity',
        'PreCoreDllSha256',
        'PostCoreDllSha256',
        'Wait-V03Issue14Process',
        'Stop-V03Issue14ProcessTree',
        'MaximumArtifactBytes',
        'ReportSha256',
        'StdoutSha256',
        'StderrSha256',
        'GateReportSha256',
        'EvidenceClass: Runtime')) {
    Assert-SourceContains -Path $wrapperPath -Text $text -Message "wrapper contains fail-closed requirement '$text'"
}
Assert-SourceContains -Path $helperPath -Text 'taskkill.exe /PID' -Message 'timeout fallback terminates the complete process tree'
Assert-SourceContains -Path $helperPath -Text 'EvidenceClass: NoRuntimeCredit' -Message 'failure report preserves NoRuntimeCredit'
Assert-SourceContains -Path $helperPath -Text 'StrictJson: runtime report must contain exactly one JSON object' -Message 'JSON root validation is strict'
Assert-SourceContains -Path $helperPath -Text 'unknown property' -Message 'unknown JSON properties fail closed'
Assert-SourceContains -Path $readmePath -Text 'Invoke-V03Issue14TerminalProcessRuntimeAcceptance.ps1' -Message 'README documents the Issue #14 wrapper'

. $helperPath
$scratchRoot = Join-Path ([IO.Path]::GetTempPath()) ("herdops-v03-issue14-selftest-" + [Guid]::NewGuid().ToString('N'))
$herdrPath = Join-Path $scratchRoot 'herdr.exe'
$reportPath = Join-Path $scratchRoot 'terminal-process-runtime.json'
$stdoutPath = Join-Path $scratchRoot 'command.stdout.log'
$stderrPath = Join-Path $scratchRoot 'command.stderr.log'
$ledgerPath = Join-Path $scratchRoot 'replay-ledger.txt'
New-Item -ItemType Directory -Path $scratchRoot -ErrorAction Stop | Out-Null
try {
    [IO.File]::WriteAllText($herdrPath, 'synthetic-herdr-binary')
    $herdrSha = Get-V03Issue14FileSha256 -Path $herdrPath
    $expectedPath = (Resolve-Path -LiteralPath $herdrPath).Path
    $now = [DateTimeOffset]::UtcNow
    $identity = [pscustomobject]@{
        ProcessId = 1234
        ProcessStartUtc = $now.AddHours(-1).ToString('O')
        ExecutablePath = $expectedPath
        ExecutableSha256 = $herdrSha
    }
    $observation = [pscustomobject]@{
        PaneId = 'pane-1'
        ProcessId = 2345
        ProcessStartUtc = $now.AddMinutes(-3).ToString('O')
        ProcessName = 'pwsh'
        ReportedSource = 'Shell'
        ReportedProcessName = 'pwsh'
        ReportedCommandSha256 = ('A' * 64)
        RedactedCommandSummary = 'safe command'
        CommandRedactionCount = 0
        ObservedUtc = $now.ToString('O')
        ExpiresUtc = $now.AddSeconds(15).ToString('O')
        CpuPercent = $null
        WorkingSetBytes = 100
        PrivateMemoryBytes = 200
    }
    $preview = [pscustomobject]@{
        PaneId = 'pane-1'
        AgentTerminalId = $null
        SignaledRevision = 1
        ReadRevision = 1
        MaximumLines = 80
        Source = 'recent_unwrapped'
        Format = 'text'
        SourceTruncated = $false
        ObservedUtc = $now.ToString('O')
        RedactedSummary = 'safe terminal'
        RawPayloadSha256 = ('B' * 64)
        RedactedPayloadSha256 = ('C' * 64)
        RedactionCount = 0
        SummaryTruncated = $false
        PipelineDisposition = 'AcceptedImmediate'
        EventIdentitySha256 = ('D' * 64)
    }
    $cycle = [pscustomobject]@{
        StartedUtc = $now.AddSeconds(-1).ToString('O')
        FinishedUtc = $now.ToString('O')
        Connected = $true
        AvailablePaneCount = 1
        InspectedPaneCount = 1
        SkippedPaneCount = 0
        TerminalReadAttemptCount = 1
        ProcessPollAttemptCount = 1
        TerminalPreviews = @($preview, $preview)
        ProcessTelemetry = @([pscustomobject]@{
            Observation = $observation
            PipelineDisposition = 'AcceptedImmediate'
            EventIdentitySha256 = ('E' * 64)
        }, [pscustomobject]@{
            Observation = $observation
            PipelineDisposition = 'AcceptedImmediate'
            EventIdentitySha256 = ('E' * 64)
        })
        ProcessFailures = @()
        CollectionFailures = @()
    }
    $report = [pscustomobject]@{
        EvidenceClassification = 'Runtime'
        RuntimeObserved = $true
        PaneReadObserved = $true
        ProcessCorrelationObserved = $true
        SessionControlInvoked = $false
        UnboundedTerminalReadAttemptCount = 0
        MaximumTerminalLines = 80
        StartedUtc = $now.AddSeconds(-1).ToString('O')
        FinishedUtc = $now.ToString('O')
        RequestedDurationSeconds = 120
        PollIntervalMilliseconds = 500
        HostName = 'synthetic-host'
        OperatingSystem = 'synthetic-os'
        Admission = [pscustomobject]@{
            ExecutablePath = $expectedPath
            ReleaseId = 'synthetic-release'
            ExecutableSha256 = $herdrSha
            ProtocolContractId = 'synthetic-protocol'
            ProtocolContractRevision = 1
            BundledSchemaContractId = 'synthetic-schema'
            BundledSchemaContractRevision = 1
            BundledSchemaSha256 = ('F' * 64)
            Protocol = 1
            Endpoint = [pscustomobject]@{ SocketPath = 'synthetic.sock'; PipeName = 'synthetic-pipe' }
        }
        MonitorServerIdentity = $identity
        InspectionServerIdentity = $identity
        FinalMonitorState = [pscustomobject]@{
            Status = 'Stopped'
            State = [pscustomobject]@{ Version = 'synthetic' }
            ServerIdentity = $identity
            BootstrapCount = 1
            EventCount = 0
            DisconnectCount = 0
            ReconciliationCount = 0
            LastTransitionReason = 'Monitoring was cancelled.'
            LastTransitionUtc = $now.ToString('O')
            AcceptedEventKind = $null
            AcceptedAgentStatusEvent = $null
            AllAgentsHaveLiveIdentity = $true
        }
        CollectionCycleCount = 2
        TerminalReadAttemptCount = 4
        TerminalPreviewCount = 4
        ProcessPollAttemptCount = 4
        ProcessTelemetryCount = 4
        ProcessFailureCount = 0
        CollectionFailureCount = 0
        Cycles = @($cycle, $cycle)
        Message = 'synthetic runtime fixture'
    }
    $json = ($report | ConvertTo-Json -Depth 20) + [Environment]::NewLine
    [IO.File]::WriteAllText($reportPath, $json)
    [IO.File]::WriteAllText($stdoutPath, $json)
    [IO.File]::WriteAllText($stderrPath, '')
    $result = Assert-V03Issue14RuntimeReport `
        -ReportPath $reportPath -NotBeforeUtc $now.AddMinutes(-1) `
        -ExpectedHerdrExecutablePath $expectedPath -ExpectedHerdrExecutableSha256 $herdrSha `
        -ExpectedDurationSeconds 120 -ExpectedIntervalMilliseconds 500 -ExpectedMaximumLines 80
    Assert-True -Condition ($null -ne $result) -Message 'accepts a complete fresh exact-identity synthetic report fixture'
    Assert-V03Issue14StdoutMatchesReport -ReportPath $reportPath -StdoutPath $stdoutPath -StderrPath $stderrPath
    Assert-True -Condition $true -Message 'accepts stdout byte identity and empty stderr after exit 0'

    $unknown = $report | Select-Object *
    Add-Member -InputObject $unknown -NotePropertyName Unexpected -NotePropertyValue 'reject-me'
    [IO.File]::WriteAllText($reportPath, (($unknown | ConvertTo-Json -Depth 20) + [Environment]::NewLine))
    Assert-ThrowsMatching -ScriptBlock {
        Assert-V03Issue14RuntimeReport -ReportPath $reportPath -NotBeforeUtc $now.AddMinutes(-1) -ExpectedHerdrExecutablePath $expectedPath -ExpectedHerdrExecutableSha256 $herdrSha -ExpectedDurationSeconds 120 -ExpectedIntervalMilliseconds 500 -ExpectedMaximumLines 80
    } -Prefix 'StrictJson:' -Message 'rejects an unknown top-level JSON property'

    $badIdentity = $report | Select-Object *
    $badIdentity.Admission = $report.Admission | Select-Object *
    $badIdentity.Admission.ExecutableSha256 = ('0' * 64)
    [IO.File]::WriteAllText($reportPath, (($badIdentity | ConvertTo-Json -Depth 20) + [Environment]::NewLine))
    Assert-ThrowsMatching -ScriptBlock {
        Assert-V03Issue14RuntimeReport -ReportPath $reportPath -NotBeforeUtc $now.AddMinutes(-1) -ExpectedHerdrExecutablePath $expectedPath -ExpectedHerdrExecutableSha256 $herdrSha -ExpectedDurationSeconds 120 -ExpectedIntervalMilliseconds 500 -ExpectedMaximumLines 80
    } -Prefix 'HerdrIdentityMismatch:' -Message 'rejects an admission binary hash mismatch'

    $badTelemetry = $report | Select-Object *
    $badTelemetry.Cycles = @($cycle, $cycle)
    $badTelemetry.Cycles[0].ProcessTelemetry = @($cycle.ProcessTelemetry[0], $cycle.ProcessTelemetry[1])
    $badTelemetry.Cycles[0].ProcessTelemetry[0].Observation = $observation | Select-Object *
    $badTelemetry.Cycles[0].ProcessTelemetry[0].Observation.ReportedCommandSha256 = 'bad'
    [IO.File]::WriteAllText($reportPath, (($badTelemetry | ConvertTo-Json -Depth 20) + [Environment]::NewLine))
    Assert-ThrowsMatching -ScriptBlock {
        Assert-V03Issue14RuntimeReport -ReportPath $reportPath -NotBeforeUtc $now.AddMinutes(-1) -ExpectedHerdrExecutablePath $expectedPath -ExpectedHerdrExecutableSha256 $herdrSha -ExpectedDurationSeconds 120 -ExpectedIntervalMilliseconds 500 -ExpectedMaximumLines 80
    } -Prefix 'StrictJson:' -Message 'rejects malformed process telemetry hash'

    [IO.File]::WriteAllText($reportPath, $json)
    [IO.File]::WriteAllText($stdoutPath, 'tampered stdout')
    Assert-ThrowsMatching -ScriptBlock {
        Assert-V03Issue14StdoutMatchesReport -ReportPath $reportPath -StdoutPath $stdoutPath -StderrPath $stderrPath
    } -Prefix 'StrictArtifact:' -Message 'rejects stdout that is not the exact report byte stream'

    $replayKey = Get-V03Issue14ReplayKey -ReportSha256 ('1' * 64) -StdoutSha256 ('2' * 64) -StderrSha256 ('3' * 64) -GateReportSha256 ('4' * 64)
    Add-V03Issue14ReplayLedgerEntry -LedgerPath $ledgerPath -ReplayKey $replayKey
    Assert-ThrowsMatching -ScriptBlock {
        Assert-V03Issue14NotReplayed -LedgerPath $ledgerPath -ReportSha256 ('1' * 64)
    } -Prefix 'ReplayedEvidence:' -Message 'rejects a report hash already in the replay ledger'
}
finally {
    if (Test-Path -LiteralPath $scratchRoot) {
        Remove-Item -LiteralPath $scratchRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($failures.Count -gt 0) {
    Write-Host ""
    Write-Host "$($failures.Count) Issue #14 selftest assertion(s) failed." -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}

Write-Host ""
Write-Host "All v0.3 Issue #14 runtime-wrapper parser and hostile selftests passed under PowerShell $($PSVersionTable.PSVersion)." -ForegroundColor Green
exit 0
