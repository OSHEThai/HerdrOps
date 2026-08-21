[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',

    [switch]$SkipBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$artifactRoot = Join-Path $repositoryRoot 'artifacts'
$contractPath = Join-Path $repositoryRoot 'docs\protocol\v0.4-cli-self-report-contract.md'
$implementationPath = Join-Path $repositoryRoot 'docs\design\implementation\v0.4-issue-18-cli-self-report.md'
$reviewRecordPath = Join-Path $repositoryRoot 'docs\reviews\v0.4-issue-18-successor-v0.5-independent-review.md'
$reviewManifestPath = Join-Path $repositoryRoot 'docs\reviews\v0.4-issue-18-successor-v0.5-reviewed-files.sha256'
$assignmentExamplePath = Join-Path $repositoryRoot 'docs\protocol\examples\v0.4\assignment.json'

$workingTreeStatus = @(& git -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0) {
    throw 'Could not inspect the source working tree for the v0.4 self-report gate.'
}
if ($workingTreeStatus.Count -ne 0) {
    throw "The v0.4 self-report gate requires a clean committed checkout. Pending paths: $($workingTreeStatus -join ', ')"
}

if (-not $SkipBuild) {
    & (Join-Path $PSScriptRoot 'Invoke-Build.ps1') -Configuration $Configuration -VerifyFormat
    if ($LASTEXITCODE -ne 0) {
        throw "v0.4 self-report build gate failed with exit code $LASTEXITCODE."
    }
}

$runId = "$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ', [Globalization.CultureInfo]::InvariantCulture))-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
$gateDirectory = Join-Path $artifactRoot "release-gates\v0.4.0\issue-18\$runId"
$testResultDirectory = Join-Path $gateDirectory 'test-results'
New-Item -ItemType Directory -Path $testResultDirectory -Force | Out-Null

$testRuns = @(
    [pscustomobject]@{
        Project = Join-Path $repositoryRoot 'tests\HerdrOps.ContractTests\HerdrOps.ContractTests.csproj'
        Filter = 'FullyQualifiedName~SelfReportContractTests'
        Log = 'self-report-contract.trx'
    },
    [pscustomobject]@{
        Project = Join-Path $repositoryRoot 'tests\HerdrOps.IntegrationTests\HerdrOps.IntegrationTests.csproj'
        Filter = 'FullyQualifiedName~SelfReportIntegrationTests'
        Log = 'self-report-integration.trx'
    },
    [pscustomobject]@{
        Project = Join-Path $repositoryRoot 'tests\HerdrOps.UnitTests\HerdrOps.UnitTests.csproj'
        Filter = 'FullyQualifiedName~SolutionTopologyTests'
        Log = 'architecture-boundary.trx'
    }
)
foreach ($testRun in $testRuns) {
    & dotnet test $testRun.Project `
        --configuration $Configuration `
        --no-restore `
        --no-build `
        --artifacts-path $artifactRoot `
        --results-directory $testResultDirectory `
        --filter $testRun.Filter `
        --logger "trx;LogFileName=$($testRun.Log)"
    if ($LASTEXITCODE -ne 0) {
        throw "v0.4 self-report evidence tests failed: $($testRun.Project)"
    }
}

$testResults = @(Get-ChildItem -LiteralPath $testResultDirectory -Filter '*.trx' -File)
if ($testResults.Count -ne 3) {
    throw "Expected exactly 3 fresh self-report TRX files, found $($testResults.Count)."
}

$combinedTestLog = ($testResults | ForEach-Object {
    Get-Content -LiteralPath $_.FullName -Raw
}) -join "`n"
$requiredChecks = @(
    'EverySupportedCommandCreatesOneStrictVersionedSubmission',
    'DocumentedCommandExamplesMatchTheExecutableContracts',
    'UnknownJsonMemberFailsClosed',
    'EventSpecificFieldsCannotLeakAcrossCommands',
    'NonUtcOccurrenceAndWrongContractVersionFailClosed',
    'FramingRejectsPayloadOverConfiguredBound',
    'RejectedResultCannotClaimAnAcceptanceCodeOrIdentity',
    'CliSubmissionReceivesCoreSourceSequenceCorrelationAndUtc',
    'UnknownTaskReturnsStructuredNonZeroCoreRejection',
    'InvalidSchemaFailsNonZeroBeforeAnyCoreConnection',
    'CoreResponseTimeoutReturnsStructuredUnavailableError',
    'InvalidPipeNameReturnsStructuredUsageError',
    'StandardInputOverBoundFailsBeforeAnyCoreConnection',
    'IdenticalRetryIsIdempotentButChangedContentConflicts',
    'ServerRejectsUnauthorizedSourceWithStructuredResult',
    'ProductionSelfReportEndpointsRequireCurrentUserOnlyAndMatch',
    'ProductionProjectReferencesMatchApprovedArchitecture',
    'SQLiteProviderIsOwnedOnlyByInfrastructure'
)
foreach ($check in $requiredChecks) {
    if ($combinedTestLog -notmatch [Regex]::Escape($check)) {
        throw "Required v0.4 self-report check is absent from fresh test logs: $check"
    }
}

$totalTests = 0
$passedTests = 0
$failedTests = 0
foreach ($trxFile in $testResults) {
    [xml]$trx = Get-Content -LiteralPath $trxFile.FullName -Raw
    $counters = $trx.TestRun.ResultSummary.Counters
    $totalTests += [int]$counters.total
    $passedTests += [int]$counters.passed
    $failedTests += [int]$counters.failed
}
if ($totalTests -lt $requiredChecks.Count -or $failedTests -ne 0 -or $totalTests -ne $passedTests) {
    throw "Self-report test counters are not all passing: total=$totalTests passed=$passedTests failed=$failedTests"
}

foreach ($requiredFile in @($contractPath, $implementationPath, $reviewRecordPath, $assignmentExamplePath)) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
        throw "Required Issue #18 record is missing: $requiredFile"
    }
}

$configurationDirectory = $Configuration.ToLowerInvariant()
$coreExecutable = Join-Path $artifactRoot "bin\HerdrOps.Core\$configurationDirectory\HerdrOps.Core.exe"
$cliExecutable = Join-Path $artifactRoot "bin\HerdrOps.Cli\$configurationDirectory\HerdrOps.Cli.exe"
foreach ($executable in @($coreExecutable, $cliExecutable)) {
    if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
        throw "Required built executable is missing: $executable"
    }
}

$pipeName = "herdrops-self-report-gate-$([Guid]::NewGuid().ToString('N'))"
$coreOutputPath = Join-Path $gateDirectory 'core.stdout.txt'
$coreErrorPath = Join-Path $gateDirectory 'core.stderr.txt'
$tracePath = Join-Path $gateDirectory 'core-acceptance-trace.json'
$acceptedOutputPath = Join-Path $gateDirectory 'accepted-result.json'
$acceptedErrorPath = Join-Path $gateDirectory 'accepted.stderr.txt'
$unknownInputPath = Join-Path $gateDirectory 'unknown-task-input.json'
$unknownOutputPath = Join-Path $gateDirectory 'unknown-task-result.json'
$unknownErrorPath = Join-Path $gateDirectory 'unknown-task.stderr.txt'
$invalidInputPath = Join-Path $gateDirectory 'invalid-schema-input.json'
$invalidOutputPath = Join-Path $gateDirectory 'invalid-schema.stdout.txt'
$invalidErrorPath = Join-Path $gateDirectory 'invalid-schema-error.json'
$utf8NoBom = [Text.UTF8Encoding]::new($false)

$unknownInput = Get-Content -LiteralPath $assignmentExamplePath -Raw | ConvertFrom-Json
$unknownInput.eventId = [Guid]::NewGuid().ToString('D')
$unknownInput.taskId = 'TASK-999'
[IO.File]::WriteAllText(
    $unknownInputPath,
    ($unknownInput | ConvertTo-Json -Depth 8),
    $utf8NoBom)
[IO.File]::WriteAllText(
    $invalidInputPath,
    '{"contractVersion":1,"unexpected":true}',
    $utf8NoBom)

function Invoke-CapturedProcess {
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,
        [Parameter(Mandatory)]
        [string[]]$ArgumentList,
        [Parameter(Mandatory)]
        [string]$StandardOutputPath,
        [Parameter(Mandatory)]
        [string]$StandardErrorPath,
        [int]$TimeoutMilliseconds = 10000
    )

    $process = Start-Process `
        -FilePath $FilePath `
        -ArgumentList $ArgumentList `
        -RedirectStandardOutput $StandardOutputPath `
        -RedirectStandardError $StandardErrorPath `
        -WindowStyle Hidden `
        -PassThru
    if ($null -eq $process) {
        throw "Could not start captured process: $FilePath"
    }
    if (-not $process.WaitForExit($TimeoutMilliseconds)) {
        $process.Kill($true)
        throw "Process timed out after $TimeoutMilliseconds milliseconds: $FilePath"
    }

    try {
        $process.Refresh()
    } catch {
        throw "Could not refresh captured process state: $($_.Exception.Message)"
    }
    if (-not $process.HasExited) {
        throw "Captured process did not report exited after its wait: $FilePath"
    }
    $exitCode = $process.ExitCode
    if ($null -eq $exitCode) {
        throw "Captured process did not expose an exit code after it exited: $FilePath"
    }
    return [int]$exitCode
}

$coreArguments = @(
    'serve-self-reports',
    '--known-task',
    'TASK-115',
    '--pipe-name',
    $pipeName,
    '--seconds',
    '8',
    '--trace',
    $tracePath
)
$coreProcess = Start-Process `
    -FilePath $coreExecutable `
    -ArgumentList $coreArguments `
    -RedirectStandardOutput $coreOutputPath `
    -RedirectStandardError $coreErrorPath `
    -WindowStyle Hidden `
    -PassThru
if ($null -eq $coreProcess) {
    throw "Could not start the built Core self-report process: $coreExecutable"
}

$readyDeadline = [DateTime]::UtcNow.AddSeconds(5)
$coreReady = $false
while ([DateTime]::UtcNow -lt $readyDeadline) {
    if ($coreProcess.HasExited) {
        break
    }
    if ((Test-Path -LiteralPath $coreOutputPath) -and
        ((Get-Content -LiteralPath $coreOutputPath -Raw) -match 'self-report service ready')) {
        $coreReady = $true
        break
    }
    Start-Sleep -Milliseconds 50
}
if (-not $coreReady) {
    if (-not $coreProcess.HasExited) {
        $coreProcess.Kill($true)
    }
    throw 'The built Core self-report process did not become ready within 5 seconds.'
}

$acceptedExitCode = Invoke-CapturedProcess `
    -FilePath $cliExecutable `
    -ArgumentList @('assignment', '--input', $assignmentExamplePath, '--pipe-name', $pipeName, '--timeout-ms', '2000') `
    -StandardOutputPath $acceptedOutputPath `
    -StandardErrorPath $acceptedErrorPath
$unknownExitCode = Invoke-CapturedProcess `
    -FilePath $cliExecutable `
    -ArgumentList @('assignment', '--input', $unknownInputPath, '--pipe-name', $pipeName, '--timeout-ms', '2000') `
    -StandardOutputPath $unknownOutputPath `
    -StandardErrorPath $unknownErrorPath
$invalidExitCode = Invoke-CapturedProcess `
    -FilePath $cliExecutable `
    -ArgumentList @('assignment', '--input', $invalidInputPath, '--pipe-name', $pipeName, '--timeout-ms', '2000') `
    -StandardOutputPath $invalidOutputPath `
    -StandardErrorPath $invalidErrorPath

if (-not $coreProcess.WaitForExit(12000)) {
    $coreProcess.Kill($true)
    throw 'The built Core self-report process did not stop after its evidence duration.'
}
try {
    $coreProcess.Refresh()
} catch {
    throw "Could not refresh the built Core self-report process state: $($_.Exception.Message)"
}
if (-not $coreProcess.HasExited) {
    throw 'The built Core self-report process did not report exited after its wait.'
}
$coreExitCode = $coreProcess.ExitCode
if ($null -eq $coreExitCode) {
    throw 'The built Core self-report process did not expose an exit code after it exited.'
}
if ([int]$coreExitCode -ne 0) {
    throw "The built Core self-report process failed with exit code $([int]$coreExitCode)."
}
if ((Get-Item -LiteralPath $coreErrorPath).Length -ne 0) {
    throw "The built Core self-report process wrote stderr: $(Get-Content -LiteralPath $coreErrorPath -Raw)"
}
if ($acceptedExitCode -ne 0 -or (Get-Item -LiteralPath $acceptedErrorPath).Length -ne 0) {
    throw "The accepted CLI example failed: exit=$acceptedExitCode stderr=$(Get-Content -LiteralPath $acceptedErrorPath -Raw)"
}
if ($unknownExitCode -ne 70 -or (Get-Item -LiteralPath $unknownErrorPath).Length -ne 0) {
    throw "The unknown-task CLI example did not return the required Core rejection: exit=$unknownExitCode"
}
if ($invalidExitCode -ne 65 -or (Get-Item -LiteralPath $invalidOutputPath).Length -ne 0) {
    throw "The invalid-schema CLI example did not fail locally as required: exit=$invalidExitCode"
}

$acceptedResultJson = Get-Content -LiteralPath $acceptedOutputPath -Raw
$acceptedResult = $acceptedResultJson | ConvertFrom-Json
$unknownResult = Get-Content -LiteralPath $unknownOutputPath -Raw | ConvertFrom-Json
$invalidResult = Get-Content -LiteralPath $invalidErrorPath -Raw | ConvertFrom-Json
$trace = Get-Content -LiteralPath $tracePath -Raw | ConvertFrom-Json
$acceptedResultDocument = [Text.Json.JsonDocument]::Parse($acceptedResultJson)
$acceptedUtcText = $acceptedResultDocument.RootElement.GetProperty('acceptedUtc').GetString()
$acceptedUtc = [DateTimeOffset]::Parse(
    $acceptedUtcText,
    [Globalization.CultureInfo]::InvariantCulture,
    [Globalization.DateTimeStyles]::RoundtripKind)
if (-not $acceptedResult.accepted -or
    $acceptedResult.acceptedSource -ne 'HerdrOps.Core' -or
    [long]$acceptedResult.sequence -le 0 -or
    [Guid]$acceptedResult.correlationId -eq [Guid]::Empty -or
    $acceptedUtc.Offset -ne [TimeSpan]::Zero) {
    throw 'The built CLI accepted response is missing Core source, sequence, correlation, or UTC identity.'
}
if ($unknownResult.accepted -or $unknownResult.code -ne 'unknown-task') {
    throw 'The built CLI unknown-task response is not the required structured rejection.'
}
if ($invalidResult.code -ne 'invalid-schema') {
    throw 'The built CLI invalid-schema response is not the required structured local error.'
}
if ($trace.evidenceClassification -ne 'BuiltProcessIntegration' -or
    [long]$trace.lastSequence -ne 1 -or
    @($trace.acceptedEvents).Count -ne 1 -or
    $trace.acceptedEvents[0].source -ne 'HerdrOps.Core' -or
    [Guid]$trace.acceptedEvents[0].correlationId -ne [Guid]$acceptedResult.correlationId) {
    throw 'The Core acceptance trace does not contain exactly the accepted process event and correlation.'
}

$cliProjectPath = Join-Path $repositoryRoot 'src\HerdrOps.Cli\HerdrOps.Cli.csproj'
[xml]$cliProject = Get-Content -LiteralPath $cliProjectPath -Raw
$cliReferences = @($cliProject.Project.ItemGroup.ProjectReference | ForEach-Object { $_.Include })
if ($cliReferences.Count -ne 1 -or $cliReferences[0] -notmatch 'HerdrOps\.Contracts') {
    throw 'HerdrOps.Cli must reference only HerdrOps.Contracts.'
}
$cliSource = (Get-ChildItem -LiteralPath (Join-Path $repositoryRoot 'src\HerdrOps.Cli') -Filter '*.cs' -File -Recurse |
    ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"
foreach ($forbiddenToken in @('Microsoft.Data.Sqlite', 'SqliteConnection', 'HerdrOps.Infrastructure')) {
    if ($cliSource -match [Regex]::Escape($forbiddenToken)) {
        throw "HerdrOps.Cli contains a forbidden direct persistence dependency: $forbiddenToken"
    }
}

$reviewText = Get-Content -LiteralPath $reviewRecordPath -Raw
$reviewPassed = $reviewText -match '(?m)^Verdict: PASS\s*$'
$reviewManifestSha256 = 'UNAVAILABLE'
if ($reviewPassed) {
    $manifestPathMatch = [Regex]::Match(
        $reviewText,
        '(?m)^ManifestPath:\s*(\S+)\s*$')
    $manifestHashMatch = [Regex]::Match(
        $reviewText,
        '(?m)^ManifestSha256:\s*([0-9A-F]{64})\s*$')
    if (-not $manifestPathMatch.Success -or
        -not $manifestHashMatch.Success) {
        throw 'The PASS review record is missing its reviewed-file manifest binding.'
    }

    $expectedManifestRelativePath = 'docs/reviews/v0.4-issue-18-successor-v0.5-reviewed-files.sha256'
    if ($manifestPathMatch.Groups[1].Value -cne $expectedManifestRelativePath -or
        -not (Test-Path -LiteralPath $reviewManifestPath -PathType Leaf)) {
        throw 'The PASS review record does not bind the required Issue #18 manifest path.'
    }

    $reviewManifestSha256 = (Get-FileHash -LiteralPath $reviewManifestPath -Algorithm SHA256).Hash
    if ($reviewManifestSha256 -cne $manifestHashMatch.Groups[1].Value) {
        throw 'The Issue #18 reviewed-file manifest hash does not match the PASS review record.'
    }

    $expectedReviewedPaths = @(
        'docs/design/implementation/v0.4-issue-18-cli-self-report.md',
        'docs/protocol/examples/v0.4/acknowledgement.json',
        'docs/protocol/examples/v0.4/assignment.json',
        'docs/protocol/examples/v0.4/delegation.json',
        'docs/protocol/examples/v0.4/deviation.json',
        'docs/protocol/examples/v0.4/evidence.json',
        'docs/protocol/examples/v0.4/handoff.json',
        'docs/protocol/examples/v0.4/progress.json',
        'docs/protocol/v0.4-cli-self-report-contract.md',
        'docs/protocol/v0.4-runtime-lifecycle-acceptance.md',
        'src/HerdrOps.Cli/HerdrOps.Cli.csproj',
        'src/HerdrOps.Cli/HerdrOpsCliCommand.cs',
        'src/HerdrOps.Cli/HerdrOpsSelfReportPipeClient.cs',
        'src/HerdrOps.Cli/Program.cs',
        'src/HerdrOps.Contracts/SelfReport/HerdrOpsSelfReportContract.cs',
        'src/HerdrOps.Contracts/SelfReport/HerdrOpsSelfReportJson.cs',
        'src/HerdrOps.Contracts/SelfReport/HerdrOpsSelfReportPipeName.cs',
        'src/HerdrOps.Core/AssignmentLifecycleRuntimeAcceptanceCommand.cs',
        'src/HerdrOps.Core/HerdrOpsSelfReportAcceptanceService.cs',
        'src/HerdrOps.Core/HerdrOpsSelfReportServiceCommand.cs',
        'src/HerdrOps.Core/Program.cs',
        'src/HerdrOps.Infrastructure/StateIpc/HerdrOpsSelfReportPipeServer.cs',
        'tests/HerdrOps.ContractTests/SelfReportContractTests.cs',
        'tests/HerdrOps.IntegrationTests/AssignmentLifecycleIngestionCoordinatorTests.cs',
        'tests/HerdrOps.IntegrationTests/SelfReportIntegrationTests.cs',
        'tests/HerdrOps.UnitTests/SolutionTopologyTests.cs',
        'tools/Invoke-V04LifecycleRuntimeAcceptance.ps1',
        'tools/Test-V04SelfReportCli.ps1'
    )
    $manifestEntries = [Collections.Generic.Dictionary[string, string]]::new(
        [StringComparer]::Ordinal)
    foreach ($line in Get-Content -LiteralPath $reviewManifestPath) {
        $entryMatch = [Regex]::Match($line, '^SHA256 ([0-9A-F]{64}) (\S+)$')
        if (-not $entryMatch.Success) {
            throw "Invalid Issue #18 reviewed-file manifest line: $line"
        }

        $relativePath = $entryMatch.Groups[2].Value
        if ($manifestEntries.ContainsKey($relativePath)) {
            throw "Duplicate Issue #18 reviewed-file manifest path: $relativePath"
        }
        $manifestEntries.Add($relativePath, $entryMatch.Groups[1].Value)
    }

    if ($manifestEntries.Count -ne $expectedReviewedPaths.Count) {
        throw 'The Issue #18 reviewed-file manifest has an unexpected number of entries.'
    }
    foreach ($relativePath in $expectedReviewedPaths) {
        if (-not $manifestEntries.ContainsKey($relativePath)) {
            throw "The Issue #18 reviewed-file manifest is missing: $relativePath"
        }
        $boundPath = Join-Path $repositoryRoot $relativePath
        if (-not (Test-Path -LiteralPath $boundPath -PathType Leaf)) {
            throw "A reviewed Issue #18 file is missing: $relativePath"
        }
        $actualSha256 = (Get-FileHash -LiteralPath $boundPath -Algorithm SHA256).Hash
        if ($actualSha256 -cne $manifestEntries[$relativePath]) {
            throw "A reviewed Issue #18 file changed after independent approval: $relativePath"
        }
    }
    foreach ($relativePath in $manifestEntries.Keys) {
        if ($expectedReviewedPaths -cnotcontains $relativePath) {
            throw "The Issue #18 reviewed-file manifest contains an unexpected path: $relativePath"
        }
    }
}
$reviewVerdict = if ($reviewPassed) { 'PASS' } else { 'UNAVAILABLE OR PENDING' }
$issueAcceptance = if ($reviewPassed) { 'PASS' } else { 'PENDING' }
$issueStateRequired = if ($reviewPassed) {
    'READY TO CLOSE AFTER MERGE AND POST-MERGE CI'
} else {
    'OPEN'
}
$result = if ($reviewPassed) { 'IMPLEMENTATION READY' } else { 'IMPLEMENTATION READY / PARTIAL' }

$sourceCommit = (& git -C $repositoryRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($sourceCommit)) {
    throw 'Could not resolve the source commit for the v0.4 self-report gate.'
}
$contractSha256 = (Get-FileHash -LiteralPath $contractPath -Algorithm SHA256).Hash
$reviewRecordSha256 = (Get-FileHash -LiteralPath $reviewRecordPath -Algorithm SHA256).Hash
$traceSha256 = (Get-FileHash -LiteralPath $tracePath -Algorithm SHA256).Hash
$acceptedSha256 = (Get-FileHash -LiteralPath $acceptedOutputPath -Algorithm SHA256).Hash
$unknownSha256 = (Get-FileHash -LiteralPath $unknownOutputPath -Algorithm SHA256).Hash
$invalidSha256 = (Get-FileHash -LiteralPath $invalidErrorPath -Algorithm SHA256).Hash
$gateReportPath = Join-Path $gateDirectory 'gate-report.txt'
$gateReport = @(
    'HerdrOps v0.4 Issue #18 CLI Self-report Implementation Gate',
    "GeneratedUtc: $([DateTime]::UtcNow.ToString('O'))",
    "SourceCommit: $sourceCommit",
    "Result: $result",
    'ImplementationGate: PASS',
    "IssueAcceptance: $issueAcceptance",
    'VersionReleaseGate: PENDING',
    'ContractEvidence: PASS',
    'IntegrationEvidence: PASS',
    'TraceEvidenceClassification: BuiltProcessIntegration',
    'BuiltProcessCliToCoreTrace: OBSERVED',
    'ActualHerdrAgentRuntime: NOT OBSERVED / NOT CLAIMED',
    'DurableLifecyclePersistence: NOT ENABLED IN THIS ISSUE #18 TRACE / NOT CLAIMED',
    "IndependentReviewVerdict: $reviewVerdict",
    "IssueStateRequired: $issueStateRequired",
    "Tests: $passedTests/$totalTests PASS",
    "ContractSha256: $contractSha256",
    "ReviewManifestSha256: $reviewManifestSha256",
    "IndependentReviewRecordSha256: $reviewRecordSha256",
    "CoreAcceptanceTraceSha256: $traceSha256",
    "AcceptedResultSha256: $acceptedSha256",
    "UnknownTaskResultSha256: $unknownSha256",
    "InvalidSchemaErrorSha256: $invalidSha256",
    "AcceptedSource: $($acceptedResult.acceptedSource)",
    "AcceptedSequence: $($acceptedResult.sequence)",
    "AcceptedCorrelationId: $($acceptedResult.correlationId)",
    "AcceptedUtc: $acceptedUtcText",
    'CliProjectReferences: HerdrOps.Contracts only',
    'CliSQLiteAccess: ABSENT',
    'NativeAot: DEFERRED PENDING COMPATIBILITY AND RESOURCE MEASUREMENTS',
    '',
    'RequiredChecks:'
) + ($requiredChecks | ForEach-Object { "PASS $_" }) + @(
    '',
    'EvidenceBoundary:',
    'This gate proves strict versioned command contracts, current-user-only bounded Named Pipe transport, fail-closed schema and unknown-task handling, Core-owned source/sequence/correlation/UTC identity, idempotent retry behavior, the CLI dependency boundary, and one actual built CLI-to-Core acceptance trace on this host.',
    'It does not prove an installed Herdr agent self-report, durable lifecycle persistence, graph projection, Task Alignment UI, v0.4 runtime acceptance, or release readiness.',
    'Independent-review and Issue #18 acceptance status are derived only from the committed review record and remain separate from runtime and release evidence.'
)
$gateReport | Set-Content -LiteralPath $gateReportPath -Encoding utf8
$gateReport | Write-Output
Write-Output "GateReport: $gateReportPath"
