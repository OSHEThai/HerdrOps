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

# Bounded operator harness for the Issue #15 actual-Herdr file/Git activity runtime capture.
# Must be run manually from an authorized Herdr pane with HERDR_ENV=1. This script never starts
# Herdr and never invokes session control; it only builds, runs, times out, and validates the
# `trace-herdr-file-git-activity` capture, then writes a version-local, fail-closed gate report.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

. (Join-Path $PSScriptRoot 'lib/V03RuntimeCaptureProvenance.ps1')

$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$artifactRoot = Join-Path $repositoryRoot 'artifacts'
$coreExecutable = Join-Path $repositoryRoot "src\HerdrOps.Core\bin\$Configuration\net10.0-windows\HerdrOps.Core.dll"
$issueEvidenceRoot = Join-Path $artifactRoot 'runtime-evidence\v0.3.0\issue-15'
$ledgerPath = Join-Path $issueEvidenceRoot '.transcript-ledger.txt'
$runId = "$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ', [Globalization.CultureInfo]::InvariantCulture))-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
$runDirectory = Join-Path $issueEvidenceRoot $runId
$reportPath = Join-Path $runDirectory 'file-git-activity-runtime.json'
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

    $notBeforeUtc = [DateTime]::UtcNow
    $processArguments = @(
        $coreExecutable,
        'trace-herdr-file-git-activity',
        '--repo-root', $repositoryRoot,
        '--report', $reportPath,
        '--seconds', $DurationSeconds,
        '--herdr', $HerdrExecutable
    )

    $process = Start-Process -FilePath 'dotnet' -ArgumentList $processArguments `
        -NoNewWindow -PassThru `
        -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    $completed = $process.WaitForExit($TimeoutSeconds * 1000)
    if (-not $completed) {
        try {
            $process.Kill($true)
        }
        catch {
        }

        throw "CaptureTimedOut: trace-herdr-file-git-activity did not finish within $TimeoutSeconds seconds and was cancelled."
    }

    if ($process.ExitCode -ne 0) {
        throw "CaptureFailed: trace-herdr-file-git-activity exited with code $($process.ExitCode). See $stderrPath."
    }

    $reportObject = Assert-RuntimeCaptureReport `
        -ReportPath $reportPath `
        -RequiredTrueFields @('fileSystemWatcherObserved', 'gitStatusObserved', 'herdrAgentCorrelationObserved') `
        -NotBeforeUtc $notBeforeUtc `
        -ExpectedExecutableSha256 $controlSession.ExecutableSha256

    $transcriptSha256 = Get-FileSha256IfExists -Path $reportPath
    Assert-NotReplayedTranscript -LedgerPath $ledgerPath -TranscriptSha256 $transcriptSha256

    $gateReport = @(
        'HerdrOps v0.3 Issue #15 File/Git Activity Runtime Acceptance',
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
        "FileSystemWatcherObserved: $($reportObject.fileSystemWatcherObserved)",
        "GitStatusObserved: $($reportObject.gitStatusObserved)",
        "HerdrAgentCorrelationObserved: $($reportObject.herdrAgentCorrelationObserved)",
        '',
        'EvidenceBoundary:',
        'This harness proves actual local FileSystemWatcher/Git observation correlated against one admitted live Herdr session''s reported pane working directory (Agent-only; no Task identifier is available from the pane snapshot).',
        'It does not prove Task correlation, file-read interception, or v0.3 release readiness. Issue #15 acceptance and independent review remain a separate, later step.'
    )
    $gateReport | Set-Content -LiteralPath $gateReportPath -Encoding utf8
    Add-TranscriptLedgerEntry -LedgerPath $ledgerPath -TranscriptSha256 $transcriptSha256
    $gateReport | Write-Output
    Write-Output "GateReport: $gateReportPath"
}
catch {
    if ($null -ne $process -and -not $process.HasExited) {
        try {
            $process.Kill($true)
        }
        catch {
        }
    }

    Write-RuntimeCaptureFailureReport `
        -GateReportPath $gateReportPath `
        -SourceCommit $sourceCommit `
        -FailureMessage $_.Exception.Message
    Write-Error "The v0.3 Issue #15 runtime acceptance harness failed: $($_.Exception.Message)" -ErrorAction Continue
    exit 1
}
