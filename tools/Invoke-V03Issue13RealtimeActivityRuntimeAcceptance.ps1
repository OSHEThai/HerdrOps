[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',

    [ValidateRange(30, 300)]
    [int]$DurationSeconds = 120,

    [string]$HerdrExecutable = (Join-Path $env:LOCALAPPDATA 'Programs\Herdr\bin\herdr.exe'),

    [ValidateRange(60, 900)]
    [int]$TimeoutSeconds = 300,

    [switch]$SkipBuild
)

# Bounded operator harness for the Issue #13 actual-Herdr Realtime Activity capture.
# It must be run manually from an authorized Herdr pane with HERDR_ENV=1. The harness
# never starts Herdr, changes an Agent, or invokes session control.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

. (Join-Path $PSScriptRoot 'lib/V03RuntimeCaptureProvenance.ps1')

$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$artifactRoot = Join-Path $repositoryRoot 'artifacts'
$coreExecutable = Join-Path $repositoryRoot "src\HerdrOps.Core\bin\$Configuration\net10.0-windows\HerdrOps.Core.dll"
$issueEvidenceRoot = Join-Path $artifactRoot 'runtime-evidence\v0.3.0\issue-13'
$ledgerPath = Join-Path $issueEvidenceRoot '.transcript-ledger.txt'
$runId = "$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ', [Globalization.CultureInfo]::InvariantCulture))-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
$runDirectory = Join-Path $issueEvidenceRoot $runId
$reportPath = Join-Path $runDirectory 'realtime-activity-runtime.json'
$stdoutPath = Join-Path $runDirectory 'command.stdout.log'
$stderrPath = Join-Path $runDirectory 'command.stderr.log'
$gateReportPath = Join-Path $runDirectory 'gate-report.txt'

New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null

$sourceCommit = 'UNRESOLVED'
$process = $null
try {
    if ($env:HERDR_ENV -ne '1') {
        throw 'AuthorizedHerdrEnvironmentRequired: set HERDR_ENV=1 and run this from an authorized Herdr pane.'
    }

    $sourceCommit = Get-CleanSourceCommit -RepositoryRoot $repositoryRoot
    $controlSession = Get-ControlHerdrServerIdentity -ExpectedExecutablePath $HerdrExecutable

    if (-not $SkipBuild) {
        & dotnet build (Join-Path $repositoryRoot 'src\HerdrOps.Core\HerdrOps.Core.csproj') -c $Configuration | Out-Host
        if ($LASTEXITCODE -ne 0) {
            throw "BuildFailed: HerdrOps.Core build exited with code $LASTEXITCODE."
        }
    }

    if (-not (Test-Path -LiteralPath $coreExecutable -PathType Leaf)) {
        throw "CoreExecutableMissing: $coreExecutable"
    }

    Write-Warning 'Trigger at least one real Agent status change during this capture window; the harness cannot synthesize one.'

    $notBeforeUtc = [DateTime]::UtcNow
    $processArguments = @(
        $coreExecutable,
        'trace-herdr-realtime-activity',
        '--report', $reportPath,
        '--seconds', $DurationSeconds,
        '--herdr', $HerdrExecutable
    )

    $process = Start-Process -FilePath 'dotnet' -ArgumentList $processArguments `
        -NoNewWindow -PassThru `
        -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    $completed = $process.WaitForExit($TimeoutSeconds * 1000)
    if (-not $completed) {
        try { $process.Kill($true) } catch { }
        throw "CaptureTimedOut: trace-herdr-realtime-activity did not finish within $TimeoutSeconds seconds and was cancelled."
    }

    if ($process.ExitCode -ne 0) {
        throw "CaptureFailed: trace-herdr-realtime-activity exited with code $($process.ExitCode). See $stderrPath. If no Agent status changed during the window, re-run and trigger a transition."
    }

    $reportObject = Assert-RuntimeCaptureReport `
        -ReportPath $reportPath `
        -RequiredTrueFields @('activityEventObserved', 'activityEmissionObserved') `
        -NotBeforeUtc $notBeforeUtc `
        -ExpectedExecutableSha256 $controlSession.ExecutableSha256

    $transcriptSha256 = Get-FileSha256IfExists -Path $reportPath
    Assert-NotReplayedTranscript -LedgerPath $ledgerPath -TranscriptSha256 $transcriptSha256

    $gateReport = @(
        'HerdrOps v0.3 Issue #13 Realtime Activity Runtime Acceptance',
        "GeneratedUtc: $([DateTimeOffset]::UtcNow.ToString('O'))",
        "SourceCommit: $sourceCommit",
        'Result: PASS',
        'EvidenceClass: Runtime',
        'SessionControlInvoked: false',
        "ControlSessionProcessId: $($controlSession.ProcessId)",
        "ControlSessionProcessStartUtc: $($controlSession.ProcessStartUtc.ToString('O'))",
        "ControlSessionExecutableSha256: $($controlSession.ExecutableSha256)",
        "RequestedDurationSeconds: $DurationSeconds",
        "TimeoutSeconds: $TimeoutSeconds",
        "ReportPath: $reportPath",
        "ReportSha256: $transcriptSha256",
        "RuntimeObserved: $($reportObject.runtimeObserved)",
        "ActivityEventObserved: $($reportObject.activityEventObserved)",
        "ActivityEmissionObserved: $($reportObject.activityEmissionObserved)",
        "AgentStatusTransitionCount: $($reportObject.agentStatusTransitionCount)",
        "EmissionCount: $($reportObject.emissionCount)",
        "MaximumEventLatencyMilliseconds: $($reportObject.maximumEventLatencyMilliseconds)",
        '',
        'EvidenceBoundary:',
        'This harness proves an actual accepted Herdr Agent-status transition reached the v0.3 ActivityEventPipeline and produced a bounded emission for one admitted session.',
        'It does not prove Task correlation, notification delivery, restart persistence, independent review, or v0.3 release readiness. Issue #13 acceptance remains a separate step.'
    )
    $gateReport | Set-Content -LiteralPath $gateReportPath -Encoding utf8
    Add-TranscriptLedgerEntry -LedgerPath $ledgerPath -TranscriptSha256 $transcriptSha256
    $gateReport | Write-Output
    Write-Output "GateReport: $gateReportPath"
}
catch {
    if ($null -ne $process -and -not $process.HasExited) {
        try { $process.Kill($true) } catch { }
    }

    Write-RuntimeCaptureFailureReport `
        -GateReportPath $gateReportPath `
        -SourceCommit $sourceCommit `
        -FailureMessage $_.Exception.Message
    Write-Error "The v0.3 Issue #13 runtime acceptance harness failed: $($_.Exception.Message)" -ErrorAction Continue
    exit 1
}
