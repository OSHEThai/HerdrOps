[CmdletBinding()]
param(
    [string]$HerdrExecutable = (Join-Path $env:LOCALAPPDATA 'Programs\Herdr\bin\herdr.exe'),

    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$solutionPath = Join-Path $repositoryRoot 'HerdrOps.sln'
$artifactRoot = Join-Path $repositoryRoot 'artifacts'
$runId = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
$evidenceDirectory = Join-Path $artifactRoot "protocol-evidence\v0.2\issue-6\$runId"
$testResultsDirectory = Join-Path $evidenceDirectory 'test-results'
$inspectionPath = Join-Path $evidenceDirectory 'installed-herdr-contract.json'
$gateReportPath = Join-Path $evidenceDirectory 'gate-report.txt'

New-Item -ItemType Directory -Path $testResultsDirectory -Force | Out-Null

if (-not (Test-Path -LiteralPath $HerdrExecutable -PathType Leaf)) {
    throw "Installed Herdr executable not found: $HerdrExecutable"
}

& dotnet restore $solutionPath --locked-mode --artifacts-path $artifactRoot
if ($LASTEXITCODE -ne 0) { throw 'Locked restore failed.' }

& dotnet build $solutionPath --configuration $Configuration --no-restore --artifacts-path $artifactRoot
if ($LASTEXITCODE -ne 0) { throw 'Build failed.' }

$contractProject = Join-Path $repositoryRoot 'tests\HerdrOps.ContractTests\HerdrOps.ContractTests.csproj'
$integrationProject = Join-Path $repositoryRoot 'tests\HerdrOps.IntegrationTests\HerdrOps.IntegrationTests.csproj'
foreach ($testProject in @($contractProject, $integrationProject)) {
    & dotnet test $testProject `
        --configuration $Configuration `
        --no-restore `
        --no-build `
        --artifacts-path $artifactRoot `
        --results-directory $testResultsDirectory `
        --logger trx
    if ($LASTEXITCODE -ne 0) { throw "Protocol gate tests failed: $testProject" }
}

$coreDll = Join-Path $artifactRoot "bin\HerdrOps.Core\$($Configuration.ToLowerInvariant())\HerdrOps.Core.dll"
& dotnet $coreDll inspect-herdr-schema --herdr $HerdrExecutable --report $inspectionPath
if ($LASTEXITCODE -ne 0) { throw 'Installed Herdr protocol inspection failed.' }

$inspection = Get-Content -LiteralPath $inspectionPath -Raw | ConvertFrom-Json
if ($inspection.Status -ne 'Compatible') { throw "Unexpected compatibility status: $($inspection.Status)" }
if ($inspection.EvidenceClass -ne 'Contract') { throw "Unexpected evidence class: $($inspection.EvidenceClass)" }
if ($inspection.RuntimeObserved -ne $false) { throw 'Contract inspection must not claim runtime observation.' }
if ($inspection.MissingRpcMethods.Count -ne 0 -or
    $inspection.MissingProtocolShapes.Count -ne 0 -or
    $inspection.MissingTransportMarkers.Count -ne 0) {
    throw 'Compatible inspection unexpectedly reports missing protocol markers.'
}

$malformedExecutable = Join-Path $evidenceDirectory 'malformed-herdr.exe'
[System.IO.File]::WriteAllBytes(
    $malformedExecutable,
    [System.Text.Encoding]::ASCII.GetBytes('NOT-A-WINDOWS-PE'))
$negativeOutput = & dotnet $coreDll inspect-herdr-schema --herdr $malformedExecutable 2>&1
$negativeExitCode = $LASTEXITCODE
if ($negativeExitCode -ne 2) {
    throw "Malformed executable must fail with exit code 2; observed $negativeExitCode."
}
if (($negativeOutput -join [Environment]::NewLine) -notmatch 'InvalidPortableExecutable') {
    throw 'Malformed executable failure did not identify InvalidPortableExecutable.'
}

$trxFiles = @(Get-ChildItem -LiteralPath $testResultsDirectory -Filter '*.trx' -File)
if ($trxFiles.Count -ne 2) { throw "Expected 2 fresh TRX files, found $($trxFiles.Count)." }

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
if ($failedTests -ne 0 -or $totalTests -ne $passedTests) {
    throw "Protocol gate test counters are not all passing: total=$totalTests passed=$passedTests failed=$failedTests"
}

$reportLines = @(
    'HerdrOps v0.2 Issue #6 Protocol Contract Gate',
    "GeneratedUtc: $((Get-Date).ToUniversalTime().ToString('O'))",
    "SourceCommit: $(& git -C $repositoryRoot rev-parse HEAD)",
    'Result: PASS',
    'EvidenceClass: Contract',
    'RuntimeObserved: false',
    'SessionControlInvoked: false',
    "ContractId: $($inspection.ContractId)",
    "ContractRevision: $($inspection.ContractRevision)",
    "HerdrReleaseId: $($inspection.ReleaseId)",
    "HerdrExecutableLength: $($inspection.ExecutableLength)",
    "HerdrExecutableSha256: $($inspection.ExecutableSha256)",
    "DiscoveredSchemaSha256: $($inspection.DiscoveredSchemaSha256)",
    "ContractAndIntegrationTests: $passedTests/$totalTests PASS",
    "CompatibilityFailureExampleExitCode: $negativeExitCode",
    'CompatibilityFailureExampleStatus: InvalidPortableExecutable',
    'MissingRpcMethods: 0',
    'MissingProtocolShapes: 0',
    'MissingTransportMarkers: 0',
    '',
    'EvidenceBoundary:',
    'This gate proves exact installed-binary identity and the bounded static protocol contract markers.',
    'It does not prove a running Herdr session, Named Pipe connection, snapshot response, event delivery, or reconnect behavior.'
)
$reportLines | Set-Content -LiteralPath $gateReportPath -Encoding utf8

Get-Content -LiteralPath $gateReportPath
Write-Host "ProtocolContractJson: $inspectionPath"
Write-Host "ProtocolGateReport: $gateReportPath"
