[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F]{40}$')]
    [string]$ExpectedSourceCommit,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F]{40}$')]
    [string]$ExpectedSourceTree,

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
$sourceTree = 'UNRESOLVED'
$preRunSourceCommit = 'NOT_OBSERVED'
$preRunSourceTree = 'NOT_OBSERVED'
$preRunGitTreeClean = 'NOT_OBSERVED'
$postRunSourceCommit = 'NOT_OBSERVED'
$postRunSourceTree = 'NOT_OBSERVED'
$postRunGitTreeClean = 'NOT_OBSERVED'
$reportSha256 = 'NOT_OBSERVED'
$gateReportSha256 = 'NOT_OBSERVED'
$process = $null
try {
    if ($env:HERDR_ENV -ne '1') {
        throw 'AuthorizedHerdrEnvironmentRequired: set HERDR_ENV=1 and run this from an authorized Herdr pane.'
    }

    $artifactIdentity = Get-RuntimeArtifactRunIdentity `
        -IssueEvidenceRoot $issueEvidenceRoot `
        -RunId $runId `
        -RunDirectory $runDirectory `
        -ReportPath $reportPath `
        -GateReportPath $gateReportPath

    $sourceIdentity = Get-ExpectedCleanSourceIdentity `
        -RepositoryRoot $repositoryRoot `
        -ExpectedSourceCommit $ExpectedSourceCommit `
        -ExpectedSourceTree $ExpectedSourceTree
    $sourceCommit = $sourceIdentity.SourceCommit
    $sourceTree = $sourceIdentity.SourceTree
    $preRunSourceCommit = $sourceIdentity.SourceCommit
    $preRunSourceTree = $sourceIdentity.SourceTree
    $preRunGitTreeClean = [string]$sourceIdentity.GitTreeClean
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

    $reportSha256BeforeValidation = Get-FileSha256IfExists -Path $reportPath
    if ($reportSha256BeforeValidation -notmatch '^[0-9A-Fa-f]{64}$') {
        throw "MissingEvidence: runtime report hash is unavailable: $reportPath"
    }

    $reportObject = Assert-RuntimeCaptureReport `
        -ReportPath $reportPath `
        -RequiredTrueFields @('activityEventObserved', 'activityEmissionObserved') `
        -NotBeforeUtc $notBeforeUtc `
        -ExpectedExecutableSha256 $controlSession.ExecutableSha256

    $reportSha256 = Get-FileSha256IfExists -Path $reportPath
    if ($reportSha256 -notmatch '^[0-9A-Fa-f]{64}$') {
        throw "MissingEvidence: runtime report hash became unavailable: $reportPath"
    }
    if ($reportSha256 -cne $reportSha256BeforeValidation) {
        throw "EvidenceChanged: runtime report changed while it was being validated: before=$reportSha256BeforeValidation after=$reportSha256"
    }

    Assert-NotReplayedTranscript -LedgerPath $ledgerPath -TranscriptSha256 $reportSha256

    $postSourceIdentity = Get-ExpectedCleanSourceIdentity `
        -RepositoryRoot $repositoryRoot `
        -ExpectedSourceCommit $ExpectedSourceCommit `
        -ExpectedSourceTree $ExpectedSourceTree
    $postRunSourceCommit = $postSourceIdentity.SourceCommit
    $postRunSourceTree = $postSourceIdentity.SourceTree
    $postRunGitTreeClean = [string]$postSourceIdentity.GitTreeClean
    if ($postRunSourceCommit -cne $preRunSourceCommit -or $postRunSourceTree -cne $preRunSourceTree) {
        throw "SourceIdentityChanged: pre-run=$preRunSourceCommit/$preRunSourceTree post-run=$postRunSourceCommit/$postRunSourceTree"
    }

    $gateReport = @(
        'HerdrOps v0.3 Issue #13 Realtime Activity Runtime Acceptance',
        "GeneratedUtc: $([DateTimeOffset]::UtcNow.ToString('O'))",
        "RunId: $($artifactIdentity.RunId)",
        "ArtifactRunDirectory: $($artifactIdentity.RunDirectory)",
        "ExpectedSourceCommit: $($ExpectedSourceCommit.ToLowerInvariant())",
        "ExpectedSourceTree: $($ExpectedSourceTree.ToLowerInvariant())",
        "SourceCommit: $sourceCommit",
        "SourceTree: $sourceTree",
        "PreRunSourceCommit: $preRunSourceCommit",
        "PreRunSourceTree: $preRunSourceTree",
        "PreRunGitTreeClean: $preRunGitTreeClean",
        "PostRunSourceCommit: $postRunSourceCommit",
        "PostRunSourceTree: $postRunSourceTree",
        "PostRunGitTreeClean: $postRunGitTreeClean",
        'Result: PASS',
        'EvidenceClass: Runtime',
        'SessionControlInvoked: false',
        "ControlSessionProcessId: $($controlSession.ProcessId)",
        "ControlSessionProcessStartUtc: $($controlSession.ProcessStartUtc.ToString('O'))",
        "ControlSessionExecutableSha256: $($controlSession.ExecutableSha256)",
        "RequestedDurationSeconds: $DurationSeconds",
        "TimeoutSeconds: $TimeoutSeconds",
        "ReportPath: $($artifactIdentity.ReportPath)",
        "ReportSha256: $reportSha256",
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
    $gateReportSha256 = Get-FileSha256IfExists -Path $gateReportPath
    if ($gateReportSha256 -notmatch '^[0-9A-Fa-f]{64}$') {
        throw "GateReportWriteFailed: gate report hash is unavailable: $gateReportPath"
    }
    Add-TranscriptLedgerEntry -LedgerPath $ledgerPath -TranscriptSha256 $reportSha256
    $gateReport | Write-Output
    Write-Output "GateReport: $gateReportPath"
    Write-Output "GateReportSha256: $gateReportSha256"
}
catch {
    if ($null -ne $process -and -not $process.HasExited) {
        try { $process.Kill($true) } catch { }
    }

    Write-RuntimeCaptureFailureReport `
        -GateReportPath $gateReportPath `
        -SourceCommit $sourceCommit `
        -SourceTree $sourceTree `
        -ExpectedSourceCommit $ExpectedSourceCommit `
        -ExpectedSourceTree $ExpectedSourceTree `
        -PreRunSourceCommit $preRunSourceCommit `
        -PreRunSourceTree $preRunSourceTree `
        -PreRunGitTreeClean $preRunGitTreeClean `
        -PostRunSourceCommit $postRunSourceCommit `
        -PostRunSourceTree $postRunSourceTree `
        -PostRunGitTreeClean $postRunGitTreeClean `
        -RunId $runId `
        -ReportPath $reportPath `
        -ReportSha256 $reportSha256 `
        -FailureMessage $_.Exception.Message
    Write-Error "The v0.3 Issue #13 runtime acceptance harness failed: $($_.Exception.Message)" -ErrorAction Continue
    exit 1
}
