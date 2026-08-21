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

    [Parameter(Mandatory = $true)]
    [string]$ExpectedHerdrExecutablePath,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F]{64}$')]
    [string]$ExpectedHerdrExecutableSha256,

    [ValidateRange(1, 3600)]
    [int]$DurationSeconds = 120,

    [ValidateRange(100, 5000)]
    [int]$IntervalMilliseconds = 500,

    [ValidateRange(1, 200)]
    [int]$MaximumLines = 80,

    [ValidateRange(2, 7200)]
    [int]$TimeoutSeconds = 300,

    [ValidateRange(65536, 67108864)]
    [long]$MaximumArtifactBytes = 33554432,

    [switch]$SkipBuild
)

# Issue #14 operator wrapper. Run only from an already authorized Herdr pane. It
# never starts Herdr and never invokes session control. Runtime credit is emitted
# only after every source, binary, identity, fresh-artifact, JSON, telemetry, exit,
# timeout, hash, and replay check succeeds.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

. (Join-Path $PSScriptRoot 'lib/V03RuntimeCaptureProvenance.ps1')
. (Join-Path $PSScriptRoot 'lib/V03Issue14RuntimeAcceptance.ps1')

$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$artifactRoot = Join-Path $repositoryRoot 'artifacts'
$issueEvidenceRoot = Join-Path $artifactRoot 'runtime-evidence\v0.3.0\issue-14'
$coreDllPath = Join-Path $repositoryRoot "src\HerdrOps.Core\bin\$Configuration\net10.0-windows\HerdrOps.Core.dll"
$ledgerPath = Join-Path $issueEvidenceRoot '.artifact-replay-ledger.txt'
$runId = "$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ', [Globalization.CultureInfo]::InvariantCulture))-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
$runDirectory = Join-Path $issueEvidenceRoot $runId
$reportPath = Join-Path $runDirectory 'terminal-process-runtime.json'
$stdoutPath = Join-Path $runDirectory 'command.stdout.log'
$stderrPath = Join-Path $runDirectory 'command.stderr.log'
$gateReportPath = Join-Path $runDirectory 'gate-report.txt'

$sourceCommit = 'UNRESOLVED'
$sourceTree = 'UNRESOLVED'
$preRunSourceCommit = 'NOT_OBSERVED'
$preRunSourceTree = 'NOT_OBSERVED'
$preRunGitTreeClean = 'NOT_OBSERVED'
$postRunSourceCommit = 'NOT_OBSERVED'
$postRunSourceTree = 'NOT_OBSERVED'
$postRunGitTreeClean = 'NOT_OBSERVED'
$preCoreDllSha256 = 'NOT_OBSERVED'
$postCoreDllSha256 = 'NOT_OBSERVED'
$reportSha256 = 'NOT_OBSERVED'
$stdoutSha256 = 'NOT_OBSERVED'
$stderrSha256 = 'NOT_OBSERVED'
$gateReportSha256 = 'NOT_OBSERVED'
$processExitCode = 'NOT_OBSERVED'
$process = $null
$runDirectoryCreated = $false
$callerHerdr = $null
$callerHerdrAfter = $null

try {
    if ($env:HERDR_ENV -ne '1') {
        throw 'AuthorizedHerdrEnvironmentRequired: set HERDR_ENV=1 and run from an authorized Herdr pane.'
    }
    if ($TimeoutSeconds -le $DurationSeconds) {
        throw 'TimeoutConfigurationInvalid: external TimeoutSeconds must exceed DurationSeconds.'
    }

    if (Test-Path -LiteralPath $runDirectory) {
        throw "ArtifactAlreadyExists: refusing to reuse run directory '$runDirectory'."
    }
    New-Item -ItemType Directory -Path $issueEvidenceRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $runDirectory -ErrorAction Stop | Out-Null
    $runDirectoryCreated = $true
    $artifactIdentity = Get-RuntimeArtifactRunIdentity `
        -IssueEvidenceRoot $issueEvidenceRoot `
        -RunId $runId `
        -RunDirectory $runDirectory `
        -ReportPath $reportPath `
        -GateReportPath $gateReportPath
    Assert-V03Issue14FreshArtifactPaths -Paths @($reportPath, $stdoutPath, $stderrPath, $gateReportPath)

    $sourceIdentity = Get-ExpectedCleanSourceIdentity `
        -RepositoryRoot $repositoryRoot `
        -ExpectedSourceCommit $ExpectedSourceCommit `
        -ExpectedSourceTree $ExpectedSourceTree
    $sourceCommit = $sourceIdentity.SourceCommit
    $sourceTree = $sourceIdentity.SourceTree
    $preRunSourceCommit = $sourceCommit
    $preRunSourceTree = $sourceTree
    $preRunGitTreeClean = [string]$sourceIdentity.GitTreeClean

    $expectedHerdr = Get-V03Issue14ExpectedHerdrIdentity `
        -ExpectedExecutablePath $ExpectedHerdrExecutablePath `
        -ExpectedExecutableSha256 $ExpectedHerdrExecutableSha256
    $callerHerdr = Get-ControlHerdrServerIdentity -ExpectedExecutablePath $expectedHerdr.ExecutablePath
    if (-not [StringComparer]::OrdinalIgnoreCase.Equals($callerHerdr.ExecutablePath, $expectedHerdr.ExecutablePath) -or
        $callerHerdr.ExecutableSha256 -cne $expectedHerdr.ExecutableSha256) {
        throw 'CallerAncestryIdentityMismatch: the current process ancestry is not bound to the expected Herdr executable.'
    }

    if (-not $SkipBuild) {
        & dotnet build (Join-Path $repositoryRoot 'src\HerdrOps.Core\HerdrOps.Core.csproj') -c $Configuration | Out-Host
        if ($LASTEXITCODE -ne 0) {
            throw "BuildFailed: HerdrOps.Core build exited with code $LASTEXITCODE."
        }
    }
    if (-not (Test-Path -LiteralPath $coreDllPath -PathType Leaf)) {
        throw "CoreExecutableMissing: $coreDllPath"
    }
    $preCoreDllSha256 = Get-V03Issue14FileSha256 -Path $coreDllPath

    # Recheck clean exact source immediately before launching the external trace.
    $preLaunchIdentity = Get-ExpectedCleanSourceIdentity `
        -RepositoryRoot $repositoryRoot `
        -ExpectedSourceCommit $ExpectedSourceCommit `
        -ExpectedSourceTree $ExpectedSourceTree
    if ($preLaunchIdentity.SourceCommit -cne $preRunSourceCommit -or $preLaunchIdentity.SourceTree -cne $preRunSourceTree) {
        throw 'SourceIdentityChanged: source changed during preparation.'
    }
    $preRunGitTreeClean = [string]$preLaunchIdentity.GitTreeClean
    $notBeforeUtc = [DateTimeOffset]::UtcNow
    $processArguments = @(
        $coreDllPath,
        'trace-herdr-terminal-process',
        '--report', $reportPath,
        '--seconds', $DurationSeconds,
        '--interval-ms', $IntervalMilliseconds,
        '--lines', $MaximumLines,
        '--herdr', $expectedHerdr.ExecutablePath
    )
    $process = Start-Process -FilePath 'dotnet' -ArgumentList $processArguments `
        -WorkingDirectory $repositoryRoot -NoNewWindow -PassThru `
        -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    $waitResult = Wait-V03Issue14Process `
        -Process $process `
        -TimeoutSeconds $TimeoutSeconds `
        -ArtifactPaths @($reportPath, $stdoutPath, $stderrPath) `
        -MaximumArtifactBytes $MaximumArtifactBytes
    $processExitCode = [string]$waitResult.ExitCode
    if ($waitResult.ExitCode -ne 0) {
        throw "CaptureFailed: trace-herdr-terminal-process exited with code $($waitResult.ExitCode)."
    }

    $reportShaBeforeValidation = Get-V03Issue14FileSha256 -Path $reportPath
    $stdoutShaBeforeValidation = Get-V03Issue14FileSha256 -Path $stdoutPath
    $stderrShaBeforeValidation = Get-V03Issue14FileSha256 -Path $stderrPath
    Assert-V03Issue14StdoutMatchesReport -ReportPath $reportPath -StdoutPath $stdoutPath -StderrPath $stderrPath
    $reportObject = Assert-V03Issue14RuntimeReport `
        -ReportPath $reportPath `
        -NotBeforeUtc $notBeforeUtc `
        -ExpectedHerdrExecutablePath $expectedHerdr.ExecutablePath `
        -ExpectedHerdrExecutableSha256 $expectedHerdr.ExecutableSha256 `
        -ExpectedDurationSeconds $DurationSeconds `
        -ExpectedIntervalMilliseconds $IntervalMilliseconds `
        -ExpectedMaximumLines $MaximumLines `
        -MaximumReportBytes $MaximumArtifactBytes
    $reportSha256 = Get-V03Issue14FileSha256 -Path $reportPath
    $stdoutSha256 = Get-V03Issue14FileSha256 -Path $stdoutPath
    $stderrSha256 = Get-V03Issue14FileSha256 -Path $stderrPath
    if ($reportSha256 -cne $reportShaBeforeValidation -or $stdoutSha256 -cne $stdoutShaBeforeValidation -or $stderrSha256 -cne $stderrShaBeforeValidation) {
        throw 'EvidenceChanged: report, stdout, or stderr changed while validation was in progress.'
    }
    Assert-V03Issue14StableArtifactHashes `
        -ReportPath $reportPath -StdoutPath $stdoutPath -StderrPath $stderrPath `
        -ReportSha256 $reportSha256 -StdoutSha256 $stdoutSha256 -StderrSha256 $stderrSha256
    Assert-V03Issue14NotReplayed -LedgerPath $ledgerPath -ReportSha256 $reportSha256

    $postSourceIdentity = Get-ExpectedCleanSourceIdentity `
        -RepositoryRoot $repositoryRoot `
        -ExpectedSourceCommit $ExpectedSourceCommit `
        -ExpectedSourceTree $ExpectedSourceTree
    $postRunSourceCommit = $postSourceIdentity.SourceCommit
    $postRunSourceTree = $postSourceIdentity.SourceTree
    $postRunGitTreeClean = [string]$postSourceIdentity.GitTreeClean
    $postCoreDllSha256 = Get-V03Issue14FileSha256 -Path $coreDllPath
    if ($postRunSourceCommit -cne $preRunSourceCommit -or $postRunSourceTree -cne $preRunSourceTree) {
        throw "SourceIdentityChanged: pre-run=$preRunSourceCommit/$preRunSourceTree post-run=$postRunSourceCommit/$postRunSourceTree"
    }
    if ($postCoreDllSha256 -cne $preCoreDllSha256) {
        throw "CoreBinaryChanged: pre-run=$preCoreDllSha256 post-run=$postCoreDllSha256"
    }
    $callerHerdrAfter = Get-ControlHerdrServerIdentity -ExpectedExecutablePath $expectedHerdr.ExecutablePath
    if ($callerHerdrAfter.ProcessId -ne $callerHerdr.ProcessId -or
        $callerHerdrAfter.ProcessStartUtc -ne $callerHerdr.ProcessStartUtc -or
        $callerHerdrAfter.ExecutableSha256 -cne $callerHerdr.ExecutableSha256) {
        throw 'CallerAncestryChanged: the Herdr server identity changed during capture.'
    }

    $gateReport = @(
        'HerdrOps v0.3 Issue #14 Terminal/Process Runtime Acceptance',
        'Result: PASS',
        'EvidenceClass: Runtime',
        'RuntimeObserved: true',
        'SessionControlInvoked: false',
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
        "CoreDllPath: $coreDllPath",
        "PreCoreDllSha256: $preCoreDllSha256",
        "PostCoreDllSha256: $postCoreDllSha256",
        "ExpectedHerdrExecutablePath: $($expectedHerdr.ExecutablePath)",
        "ExpectedHerdrExecutableSha256: $($expectedHerdr.ExecutableSha256)",
        "CallerHerdrProcessId: $($callerHerdr.ProcessId)",
        "CallerHerdrProcessStartUtc: $($callerHerdr.ProcessStartUtc.ToString('O'))",
        "CallerHerdrExecutablePath: $($callerHerdr.ExecutablePath)",
        "CallerHerdrExecutableSha256: $($callerHerdr.ExecutableSha256)",
        "TraceProcessExitCode: $processExitCode",
        "RequestedDurationSeconds: $DurationSeconds",
        "IntervalMilliseconds: $IntervalMilliseconds",
        "MaximumLines: $MaximumLines",
        "ExternalTimeoutSeconds: $TimeoutSeconds",
        "MaximumArtifactBytes: $MaximumArtifactBytes",
        "ReportPath: $reportPath",
        "ReportSha256: $reportSha256",
        "StdoutPath: $stdoutPath",
        "StdoutSha256: $stdoutSha256",
        "StderrPath: $stderrPath",
        "StderrSha256: $stderrSha256",
        "ReplayLedgerPath: $ledgerPath",
        "PaneReadObserved: $($reportObject.PaneReadObserved)",
        "ProcessCorrelationObserved: $($reportObject.ProcessCorrelationObserved)",
        "TerminalPreviewCount: $($reportObject.TerminalPreviewCount)",
        "ProcessTelemetryCount: $($reportObject.ProcessTelemetryCount)",
        'GateReportSha256: emitted after the gate file is finalized',
        '',
        'EvidenceBoundary:',
        'This PASS is Runtime evidence for one fresh, exact-source, exact-binary, exact-Herdr-identity terminal/process trace from an authorized Herdr pane.',
        'It does not close Issue #14, provide independent review, or claim v0.3 Release readiness until the required review and release gates pass.'
    )
    Set-Content -LiteralPath $gateReportPath -Value $gateReport -Encoding utf8 -ErrorAction Stop
    $gateReportSha256 = Get-V03Issue14FileSha256 -Path $gateReportPath
    $replayKey = Get-V03Issue14ReplayKey `
        -ReportSha256 $reportSha256 -StdoutSha256 $stdoutSha256 `
        -StderrSha256 $stderrSha256 -GateReportSha256 $gateReportSha256
    Add-V03Issue14ReplayLedgerEntry -LedgerPath $ledgerPath -ReplayKey $replayKey
    $gateReport | Write-Output
    Write-Output "GateReport: $gateReportPath"
    Write-Output "ReportSha256: $reportSha256"
    Write-Output "StdoutSha256: $stdoutSha256"
    Write-Output "StderrSha256: $stderrSha256"
    Write-Output "GateReportSha256: $gateReportSha256"
}
catch {
    $failure = $_.Exception.Message
    if ($null -ne $process) {
        try {
            Stop-V03Issue14ProcessTree -Process $process
        }
        catch {
            $failure = "$failure; $($_.Exception.Message)"
        }
    }

    $reportSha256 = Get-V03Issue14OptionalFileSha256 -Path $reportPath
    $stdoutSha256 = Get-V03Issue14OptionalFileSha256 -Path $stdoutPath
    $stderrSha256 = Get-V03Issue14OptionalFileSha256 -Path $stderrPath
    if ($runDirectoryCreated) {
        try {
            Write-V03Issue14FailureReport `
                -GateReportPath $gateReportPath `
                -RunId $runId `
                -RunDirectory $runDirectory `
                -ReportPath $reportPath `
                -StdoutPath $stdoutPath `
                -StderrPath $stderrPath `
                -LedgerPath $ledgerPath `
                -ExpectedSourceCommit $ExpectedSourceCommit `
                -ExpectedSourceTree $ExpectedSourceTree `
                -SourceCommit $sourceCommit `
                -SourceTree $sourceTree `
                -PreRunSourceCommit $preRunSourceCommit `
                -PreRunSourceTree $preRunSourceTree `
                -PreRunGitTreeClean $preRunGitTreeClean `
                -PostRunSourceCommit $postRunSourceCommit `
                -PostRunSourceTree $postRunSourceTree `
                -PostRunGitTreeClean $postRunGitTreeClean `
                -PreCoreDllSha256 $preCoreDllSha256 `
                -PostCoreDllSha256 $postCoreDllSha256 `
                -ExpectedHerdrExecutablePath $ExpectedHerdrExecutablePath `
                -ExpectedHerdrExecutableSha256 $ExpectedHerdrExecutableSha256 `
                -ReportSha256 $reportSha256 `
                -StdoutSha256 $stdoutSha256 `
                -StderrSha256 $stderrSha256 `
                -ProcessExitCode $processExitCode `
                -FailureMessage $failure
            $gateReportSha256 = Get-V03Issue14FileSha256 -Path $gateReportPath
        }
        catch {
            Write-Warning "Could not write the NoRuntimeCredit gate report: $($_.Exception.Message)"
        }
    }
    Write-Error "The v0.3 Issue #14 runtime acceptance harness failed: $failure" -ErrorAction Continue
    if ($gateReportSha256 -match '^[0-9A-Fa-f]{64}$') {
        Write-Output "GateReport: $gateReportPath"
        Write-Output "GateReportSha256: $gateReportSha256"
    }
    exit 1
}
