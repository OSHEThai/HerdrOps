[CmdletBinding()]
param(
    [string]$HerdrExecutable = (Join-Path $env:LOCALAPPDATA 'Programs\Herdr\bin\herdr.exe'),

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
        throw 'Could not resolve the source commit for the bundled-schema gate.'
    }
    $changes = @(& git -C $Root status --porcelain --untracked-files=all)
    if ($LASTEXITCODE -ne 0) { throw 'Could not inspect repository status.' }
    if ($changes.Count -ne 0) {
        throw "Bundled-schema evidence requires a clean source checkout. Changes: $($changes -join '; ')"
    }

    return $commit
}

$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$solutionPath = Join-Path $repositoryRoot 'HerdrOps.sln'
$artifactRoot = Join-Path $repositoryRoot 'artifacts'
$runId = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
$evidenceDirectory = Join-Path $artifactRoot "protocol-evidence\v0.2\issue-54\$runId"
$testResultsDirectory = Join-Path $evidenceDirectory 'test-results'
$inspectionPath = Join-Path $evidenceDirectory 'installed-herdr-bundled-schema.json'
$schemaPath = Join-Path $evidenceDirectory 'herdr-api-v19.schema.json'
$gateReportPath = Join-Path $evidenceDirectory 'gate-report.txt'

$sourceCommit = Get-CleanSourceCommit -Root $repositoryRoot

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
    if ($LASTEXITCODE -ne 0) { throw "Bundled-schema gate tests failed: $testProject" }
}

$coreDll = Join-Path $artifactRoot "bin\HerdrOps.Core\$($Configuration.ToLowerInvariant())\HerdrOps.Core.dll"
& dotnet $coreDll inspect-herdr-bundled-schema `
    --herdr $HerdrExecutable `
    --schema-output $schemaPath `
    --report $inspectionPath
if ($LASTEXITCODE -ne 0) { throw 'Installed Herdr bundled-schema inspection failed.' }

$inspection = Get-Content -LiteralPath $inspectionPath -Raw | ConvertFrom-Json
if ($inspection.Status -ne 'Compatible') { throw "Unexpected schema status: $($inspection.Status)" }
if ($inspection.EvidenceClass -ne 'Contract') { throw "Unexpected evidence class: $($inspection.EvidenceClass)" }
if ($inspection.RuntimeObserved -ne $false) { throw 'Schema inspection must not claim runtime observation.' }
if ($inspection.SessionControlInvoked -ne $false) { throw 'Schema inspection must not claim session control.' }
if ($inspection.ReleaseId -ne '0.8.0-preview.2026-08-04-d78e3d3b5126-x86_64-pc-windows-msvc') {
    throw "Unexpected Herdr release: $($inspection.ReleaseId)"
}
if ($inspection.ExecutableSha256 -ne '6F470DA358D6713B6BEBAB922FFB1F5FE1D3D288CC6F374C7DCA1B4A9837A542') {
    throw "Unexpected executable SHA-256: $($inspection.ExecutableSha256)"
}
if ([long]$inspection.SchemaStartOffset -ne 16342610) {
    throw "Unexpected schema offset: $($inspection.SchemaStartOffset)"
}
if ([int]$inspection.SchemaDocumentLength -ne 261498) {
    throw "Unexpected schema length: $($inspection.SchemaDocumentLength)"
}
$expectedSchemaSha256 = '9449368D54BBECD4D4D0696EFFB9E9C002ECD63A5B8A48BBD901A305AF842982'
if ($inspection.SchemaDocumentSha256 -ne $expectedSchemaSha256) {
    throw "Unexpected schema SHA-256: $($inspection.SchemaDocumentSha256)"
}
if ($inspection.JsonSchemaDraft -ne 'https://json-schema.org/draft/2020-12/schema') {
    throw "Unexpected JSON Schema draft: $($inspection.JsonSchemaDraft)"
}
if ([int]$inspection.Protocol -ne 19 -or [int]$inspection.SchemaVersion -ne 1) {
    throw "Unexpected protocol/schema version: $($inspection.Protocol)/$($inspection.SchemaVersion)"
}

$expectedGroups = [ordered]@{
    error_response = 1
    event = 16
    request = 105
    subscription_event = 10
    success_response = 67
}
foreach ($entry in $expectedGroups.GetEnumerator()) {
    $group = @($inspection.SchemaGroups | Where-Object { $_.Name -eq $entry.Key })
    if ($group.Count -ne 1 -or [int]$group[0].DefinitionCount -ne $entry.Value) {
        throw "Unexpected definition count for $($entry.Key)."
    }
}
if ($inspection.MissingSchemaGroups.Count -ne 0 -or
    $inspection.MissingSchemaDefinitions.Count -ne 0 -or
    $inspection.DefinitionCountMismatches.Count -ne 0 -or
    $inspection.MissingRequestMethods.Count -ne 0 -or
    $inspection.MissingResponseTypes.Count -ne 0 -or
    $inspection.MissingSubscriptionEventKinds.Count -ne 0) {
    throw 'Compatible inspection unexpectedly reports missing bundled-schema surface.'
}

$schemaFile = Get-Item -LiteralPath $schemaPath
if ($schemaFile.Length -ne 261498) { throw "Exported schema length is $($schemaFile.Length)." }
$schemaFileHash = (Get-FileHash -LiteralPath $schemaPath -Algorithm SHA256).Hash
if ($schemaFileHash -ne $expectedSchemaSha256) {
    throw "Exported schema hash is $schemaFileHash."
}

$schema = Get-Content -LiteralPath $schemaPath -Raw | ConvertFrom-Json -Depth 256
if ([int]$schema.protocol -ne 19 -or [int]$schema.schema_version -ne 1) {
    throw 'Exported schema metadata is not protocol 19/schema version 1.'
}
$requestMethods = @($schema.schemas.request.oneOf | ForEach-Object { $_.properties.method.const })
foreach ($requiredMethod in @('session.snapshot', 'events.subscribe')) {
    if ($requiredMethod -notin $requestMethods) { throw "Missing request method: $requiredMethod" }
}
$responseTypes = @($schema.schemas.success_response.'$defs'.ResponseResult.oneOf |
    ForEach-Object { $_.properties.type.const })
foreach ($requiredType in @('session_snapshot', 'subscription_started')) {
    if ($requiredType -notin $responseTypes) { throw "Missing response type: $requiredType" }
}
$subscriptionKinds = @($schema.schemas.subscription_event.'$defs'.SubscriptionEventKind.enum)
if ('pane.agent_status_changed' -notin $subscriptionKinds) {
    throw 'Missing subscription event kind: pane.agent_status_changed'
}

$negativeRoot = Join-Path $evidenceDirectory 'negative'
$negativeReportPath = Join-Path $negativeRoot 'missing-executable-report.json'
$negativeSchemaPath = Join-Path $negativeRoot 'must-not-exist.schema.json'
$missingExecutablePath = Join-Path $negativeRoot 'missing-herdr.exe'
$negativeOutput = & dotnet $coreDll inspect-herdr-bundled-schema `
    --herdr $missingExecutablePath `
    --schema-output $negativeSchemaPath `
    --report $negativeReportPath 2>&1
$negativeExitCode = $LASTEXITCODE
if ($negativeExitCode -ne 2) {
    throw "Missing executable must fail with exit code 2; observed $negativeExitCode."
}
$negativeInspection = Get-Content -LiteralPath $negativeReportPath -Raw | ConvertFrom-Json
if ($negativeInspection.Status -ne 'ExecutableRejected') {
    throw "Missing executable returned unexpected status: $($negativeInspection.Status)"
}
if (Test-Path -LiteralPath $negativeSchemaPath) {
    throw 'A rejected executable must not produce a schema document.'
}

$trxFiles = @(Get-ChildItem -LiteralPath $testResultsDirectory -Filter '*.trx' -File)
if ($trxFiles.Count -ne 2) { throw "Expected 2 fresh TRX files, found $($trxFiles.Count)." }

$totalTests = 0
$passedTests = 0
$failedTests = 0
$passedTestNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($trxFile in $trxFiles) {
    [xml]$trx = Get-Content -LiteralPath $trxFile.FullName -Raw
    $counters = $trx.TestRun.ResultSummary.Counters
    $totalTests += [int]$counters.total
    $passedTests += [int]$counters.passed
    $failedTests += [int]$counters.failed
    foreach ($testResult in @($trx.TestRun.Results.UnitTestResult)) {
        if ($testResult.outcome -eq 'Passed') { [void]$passedTestNames.Add($testResult.testName) }
    }
}
if ($totalTests -le 0 -or $failedTests -ne 0 -or $totalTests -ne $passedTests) {
    throw "Bundled-schema test counters are not all passing: total=$totalTests passed=$passedTests failed=$failedTests"
}
$requiredFixtureTests = @(
    'RequestedPathRetargetBetweenReadsFailsClosed',
    'ExecutableContentMutationBetweenReadsFailsClosed',
    'BalancedExtractionIgnoresBracesAndQuoteEscapesInsideStrings',
    'SchemaSizeBoundaryAcceptsExactLimitAndRejectsOverLimit',
    'AtomicSchemaWriteFailurePreservesDestinationAndReturnsNonZero',
    'DuplicateSchemaDocumentsFailClosedBeforeParsing',
    'TruncatedSchemaFailsClosedBeforeJsonParsing',
    'BalancedMalformedJsonFailsClosed',
    'UnsupportedDraftProtocolAndVersionHaveDistinctActionableStatuses',
    'UnexpectedLengthAndHashFailClosedAfterSemanticValidation',
    'MissingRuntimeSurfaceVariantsHaveDistinctStatuses'
)
foreach ($requiredFixtureTest in $requiredFixtureTests) {
    if (-not $passedTestNames.Contains($requiredFixtureTest)) {
        throw "Required fail-closed fixture test did not pass: $requiredFixtureTest"
    }
}

$finalSourceCommit = Get-CleanSourceCommit -Root $repositoryRoot
if ($finalSourceCommit -ne $sourceCommit) {
    throw "Source commit changed during the bundled-schema gate: $sourceCommit -> $finalSourceCommit"
}

$reportLines = @(
    'HerdrOps v0.2 Issue #54 Bundled Schema Contract Gate',
    "GeneratedUtc: $((Get-Date).ToUniversalTime().ToString('O'))",
    "SourceCommit: $sourceCommit",
    'Result: PASS',
    'EvidenceClass: Contract',
    'RuntimeObserved: false',
    'SessionControlInvoked: false',
    "ContractId: $($inspection.ContractId)",
    "ContractRevision: $($inspection.ContractRevision)",
    "HerdrReleaseId: $($inspection.ReleaseId)",
    "HerdrExecutableSha256: $($inspection.ExecutableSha256)",
    "SchemaStartOffset: $($inspection.SchemaStartOffset)",
    "SchemaDocumentLength: $($inspection.SchemaDocumentLength)",
    "SchemaDocumentSha256: $($inspection.SchemaDocumentSha256)",
    "Protocol: $($inspection.Protocol)",
    "SchemaVersion: $($inspection.SchemaVersion)",
    'SchemaDefinitionCounts: error_response=1 event=16 request=105 subscription_event=10 success_response=67',
    "ContractAndIntegrationTests: $passedTests/$totalTests PASS",
    "FailClosedFixtureTests: $($requiredFixtureTests.Count)/$($requiredFixtureTests.Count) PASS",
    "RejectedExecutableExitCode: $negativeExitCode",
    "RejectedExecutableStatus: $($negativeInspection.Status)",
    '',
    'EvidenceBoundary:',
    'This gate proves exact static extraction, raw bytes, hash, metadata, and required schema paths.',
    'It does not prove a running Herdr session, Named Pipe connection, snapshot response, event delivery, or reconnect behavior.'
)
$reportLines | Set-Content -LiteralPath $gateReportPath -Encoding utf8

Get-Content -LiteralPath $gateReportPath
Write-Host "BundledSchemaJson: $schemaPath"
Write-Host "BundledSchemaInspection: $inspectionPath"
Write-Host "BundledSchemaGateReport: $gateReportPath"
