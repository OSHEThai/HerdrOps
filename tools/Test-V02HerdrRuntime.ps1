[CmdletBinding()]
param(
    [string]$HerdrExecutable = (Join-Path $env:LOCALAPPDATA 'Programs\Herdr\bin\herdr.exe'),

    [ValidateRange(10, 3600)]
    [int]$DurationSeconds = 120,

    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

function Get-CleanSourceCommit {
    param([Parameter(Mandatory)][string]$Root)

    $commit = (& git -C $Root rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($commit)) {
        throw 'Could not resolve the source commit for the Herdr runtime gate.'
    }
    $changes = @(& git -C $Root status --porcelain --untracked-files=all)
    if ($LASTEXITCODE -ne 0) { throw 'Could not inspect repository status.' }
    if ($changes.Count -ne 0) {
        throw "Herdr runtime evidence requires a clean source checkout. Changes: $($changes -join '; ')"
    }

    return $commit
}

if ($env:HERDR_ENV -ne '1') {
    throw 'Runtime gate requires an authorized Herdr environment with HERDR_ENV=1.'
}
if ([string]::IsNullOrWhiteSpace($env:HERDR_SOCKET_PATH)) {
    throw 'Runtime gate requires HERDR_SOCKET_PATH from the active Herdr environment.'
}

$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$solutionPath = Join-Path $repositoryRoot 'HerdrOps.sln'
$artifactRoot = Join-Path $repositoryRoot 'artifacts'
$runId = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
$evidenceDirectory = Join-Path $artifactRoot "runtime-evidence\v0.2\issue-7\$runId"
$testResultsDirectory = Join-Path $evidenceDirectory 'test-results'
$tracePath = Join-Path $evidenceDirectory 'actual-herdr-runtime-trace.json'
$gateReportPath = Join-Path $evidenceDirectory 'gate-report.txt'
$sourceCommit = Get-CleanSourceCommit -Root $repositoryRoot

if (-not (Test-Path -LiteralPath $HerdrExecutable -PathType Leaf)) {
    throw "Installed Herdr executable not found: $HerdrExecutable"
}
New-Item -ItemType Directory -Path $testResultsDirectory -Force | Out-Null

& dotnet restore $solutionPath --locked-mode --artifacts-path $artifactRoot
if ($LASTEXITCODE -ne 0) { throw 'Locked restore failed.' }
& dotnet build $solutionPath --configuration $Configuration --no-restore --artifacts-path $artifactRoot
if ($LASTEXITCODE -ne 0) { throw 'Build failed.' }

$testProjects = @(
    (Join-Path $repositoryRoot 'tests\HerdrOps.UnitTests\HerdrOps.UnitTests.csproj'),
    (Join-Path $repositoryRoot 'tests\HerdrOps.ContractTests\HerdrOps.ContractTests.csproj'),
    (Join-Path $repositoryRoot 'tests\HerdrOps.IntegrationTests\HerdrOps.IntegrationTests.csproj')
)
foreach ($testProject in $testProjects) {
    & dotnet test $testProject `
        --configuration $Configuration `
        --no-restore `
        --no-build `
        --artifacts-path $artifactRoot `
        --results-directory $testResultsDirectory `
        --logger trx
    if ($LASTEXITCODE -ne 0) { throw "Pre-runtime tests failed: $testProject" }
}

Write-Host 'Runtime trace started. During the trace, produce at least one real Herdr state event and perform one user-controlled Herdr disconnect/restart.'
$coreDll = Join-Path $artifactRoot "bin\HerdrOps.Core\$($Configuration.ToLowerInvariant())\HerdrOps.Core.dll"
& dotnet $coreDll trace-herdr-runtime `
    --herdr $HerdrExecutable `
    --socket-path $env:HERDR_SOCKET_PATH `
    --seconds $DurationSeconds `
    --report $tracePath
if ($LASTEXITCODE -ne 0) { throw 'Actual Herdr runtime trace command failed.' }

$trace = Get-Content -LiteralPath $tracePath -Raw | ConvertFrom-Json -Depth 128
if ($trace.EvidenceClassification -ne 'Runtime' -or $trace.RuntimeObserved -ne $true) {
    throw 'Trace did not earn actual Herdr runtime credit.'
}
if ($trace.SessionControlInvoked -ne $false) {
    throw 'HerdrOps runtime trace must not claim or invoke session control.'
}
if ($trace.SnapshotObserved -ne $true) { throw 'Actual Herdr snapshot was not observed.' }
if ($trace.EventObserved -ne $true) { throw 'Actual Herdr event was not observed.' }
if ($trace.ReconnectObserved -ne $true) {
    throw 'Actual disconnect/reconnect with a fresh snapshot was not observed.'
}
if ($trace.Admission.ReleaseId -ne '0.8.0-preview.2026-08-04-d78e3d3b5126-x86_64-pc-windows-msvc') {
    throw "Unexpected Herdr release: $($trace.Admission.ReleaseId)"
}
if ($trace.Admission.ExecutableSha256 -ne '6F470DA358D6713B6BEBAB922FFB1F5FE1D3D288CC6F374C7DCA1B4A9837A542') {
    throw "Unexpected Herdr executable SHA-256: $($trace.Admission.ExecutableSha256)"
}
if ($trace.Admission.BundledSchemaSha256 -ne '9449368D54BBECD4D4D0696EFFB9E9C002ECD63A5B8A48BBD901A305AF842982') {
    throw "Unexpected bundled schema SHA-256: $($trace.Admission.BundledSchemaSha256)"
}
if ([int]$trace.Admission.Protocol -ne 19) {
    throw "Unexpected runtime protocol: $($trace.Admission.Protocol)"
}
if ($null -eq $trace.ObservedServerIdentity -or [int]$trace.ObservedServerIdentity.ProcessId -le 0) {
    throw 'Runtime trace did not bind the Named Pipe to a server process.'
}
if ($trace.ObservedServerIdentity.ExecutableSha256 -ne $trace.Admission.ExecutableSha256) {
    throw 'Named Pipe server executable hash does not match the admitted Herdr executable hash.'
}
if ([string]::IsNullOrWhiteSpace($trace.ObservedServerIdentity.ExecutablePath)) {
    throw 'Runtime trace did not retain the verified Named Pipe server executable path.'
}
if ($null -eq $trace.ObservedServerIdentity.ProcessStartUtc) {
    throw 'Runtime trace did not retain the verified Named Pipe server process start time.'
}

$connectedBootstraps = @($trace.Transitions | Where-Object {
    $_.Status -eq 'Connected' -and [long]$_.BootstrapCount -gt 0
} | Sort-Object BootstrapCount -Unique)
if ($connectedBootstraps.Count -lt 2) {
    throw "Expected at least two connected snapshot bootstraps, found $($connectedBootstraps.Count)."
}
foreach ($connectedBootstrap in $connectedBootstraps) {
    $identity = $connectedBootstrap.ServerIdentity
    if ($null -eq $identity -or [int]$identity.ProcessId -le 0) {
        throw "Bootstrap $($connectedBootstrap.BootstrapCount) has no verified server PID."
    }
    if ($null -eq $identity.ProcessStartUtc) {
        throw "Bootstrap $($connectedBootstrap.BootstrapCount) has no verified server process start time."
    }
    if ([string]::IsNullOrWhiteSpace($identity.ExecutablePath)) {
        throw "Bootstrap $($connectedBootstrap.BootstrapCount) has no verified server executable path."
    }
    if ($identity.ExecutableSha256 -ne $trace.Admission.ExecutableSha256) {
        throw "Bootstrap $($connectedBootstrap.BootstrapCount) server hash does not match admission."
    }
}
$firstState = $connectedBootstraps[0]
$finalState = $connectedBootstraps[-1]
foreach ($stateFingerprint in @($firstState.StateFingerprintSha256, $finalState.StateFingerprintSha256)) {
    if ($stateFingerprint -notmatch '^[0-9A-F]{64}$') {
        throw "Invalid state fingerprint: $stateFingerprint"
    }
}

$trxFiles = @(Get-ChildItem -LiteralPath $testResultsDirectory -Filter '*.trx' -File)
if ($trxFiles.Count -ne 3) { throw "Expected 3 fresh TRX files, found $($trxFiles.Count)." }
$totalTests = 0
$passedTests = 0
$failedTests = 0
foreach ($trxFile in $trxFiles) {
    [xml]$trx = Get-Content -LiteralPath $trxFile.FullName -Raw
    $counters = $trx.TestRun.ResultSummary.Counters
    $totalTests += [int]$counters.total
    $passedTests += [int]$counters.passed
    $failedTests += [int]$counters.failed
}
if ($totalTests -le 0 -or $failedTests -ne 0 -or $totalTests -ne $passedTests) {
    throw "Pre-runtime test counters are not all passing: total=$totalTests passed=$passedTests failed=$failedTests"
}

$finalSourceCommit = Get-CleanSourceCommit -Root $repositoryRoot
if ($finalSourceCommit -ne $sourceCommit) {
    throw "Source commit changed during the runtime gate: $sourceCommit -> $finalSourceCommit"
}

$reportLines = @(
    'HerdrOps v0.2 Issue #7 Actual Herdr Runtime Gate',
    "GeneratedUtc: $((Get-Date).ToUniversalTime().ToString('O'))",
    "SourceCommit: $sourceCommit",
    'Result: PASS',
    'EvidenceClass: Runtime',
    'RuntimeObserved: true',
    'SessionControlInvoked: false',
    'SnapshotObserved: true',
    'EventObserved: true',
    'ReconnectObserved: true',
    "ObservedDisconnectCount: $($trace.FinalMonitorState.DisconnectCount)",
    "HerdrReleaseId: $($trace.Admission.ReleaseId)",
    "HerdrExecutableSha256: $($trace.Admission.ExecutableSha256)",
    "ObservedHerdrServerPid: $($trace.ObservedServerIdentity.ProcessId)",
    "ObservedHerdrServerProcessStartUtc: $($trace.ObservedServerIdentity.ProcessStartUtc)",
    "ObservedHerdrServerExecutablePath: $($trace.ObservedServerIdentity.ExecutablePath)",
    "ObservedHerdrServerExecutableSha256: $($trace.ObservedServerIdentity.ExecutableSha256)",
    "BundledSchemaSha256: $($trace.Admission.BundledSchemaSha256)",
    "Protocol: $($trace.Admission.Protocol)",
    "PreRuntimeTests: $passedTests/$totalTests PASS",
    "FirstBootstrapCount: $($firstState.BootstrapCount)",
    "FirstBootstrapServerIdentity: pid=$($firstState.ServerIdentity.ProcessId) start=$($firstState.ServerIdentity.ProcessStartUtc) path=$($firstState.ServerIdentity.ExecutablePath) sha256=$($firstState.ServerIdentity.ExecutableSha256)",
    "FirstStateFingerprintSha256: $($firstState.StateFingerprintSha256)",
    "FirstStateCounts: workspaces=$($firstState.WorkspaceCount) tabs=$($firstState.TabCount) panes=$($firstState.PaneCount) agents=$($firstState.AgentCount)",
    "FinalBootstrapCount: $($finalState.BootstrapCount)",
    "FinalBootstrapServerIdentity: pid=$($finalState.ServerIdentity.ProcessId) start=$($finalState.ServerIdentity.ProcessStartUtc) path=$($finalState.ServerIdentity.ExecutablePath) sha256=$($finalState.ServerIdentity.ExecutableSha256)",
    "FinalStateFingerprintSha256: $($finalState.StateFingerprintSha256)",
    "FinalStateCounts: workspaces=$($finalState.WorkspaceCount) tabs=$($finalState.TabCount) panes=$($finalState.PaneCount) agents=$($finalState.AgentCount)",
    '',
    'EvidenceBoundary:',
    'This gate proves an actual admitted Herdr snapshot, event observation, disconnect/reconnect, and fresh-snapshot reconciliation on this host and run.',
    'It does not prove package installation, release readiness, or future Herdr versions.'
)
$reportLines | Set-Content -LiteralPath $gateReportPath -Encoding utf8

Get-Content -LiteralPath $gateReportPath
Write-Host "RuntimeTraceJson: $tracePath"
Write-Host "RuntimeGateReport: $gateReportPath"
