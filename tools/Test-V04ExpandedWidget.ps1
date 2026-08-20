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
$referencePath = Join-Path $repositoryRoot 'docs\design\reference\11-widget-concepts.png'
$implementationPath = Join-Path $repositoryRoot 'docs\design\implementation\v0.4-issue-22-expanded-widget-runtime.md'
$runtimeContractPath = Join-Path $repositoryRoot 'docs\protocol\v0.4-runtime-lifecycle-acceptance.md'
$runtimeHarnessPath = Join-Path $repositoryRoot 'tools\Invoke-V04LifecycleRuntimeAcceptance.ps1'
$releaseGatePath = Join-Path $repositoryRoot 'tools\Test-V04ReleaseGate.ps1'
$assignmentExamplePath = Join-Path $repositoryRoot 'docs\protocol\examples\v0.4\assignment.json'
$expectedReferenceSha256 = '6AB57A967BE8C62A436A8F5C6DBB89616B210E66DD34AB851D148B4DCC1A904A'

$workingTreeStatus = @(& git -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0) {
    throw 'Could not inspect the source working tree for the v0.4 Expanded Widget gate.'
}
if ($workingTreeStatus.Count -ne 0) {
    throw "The v0.4 Expanded Widget gate requires a clean committed checkout. Pending paths: $($workingTreeStatus -join ', ')"
}

if (-not $SkipBuild) {
    & (Join-Path $PSScriptRoot 'Invoke-Build.ps1') -Configuration $Configuration -VerifyFormat
    if ($LASTEXITCODE -ne 0) {
        throw "v0.4 Expanded Widget build gate failed with exit code $LASTEXITCODE."
    }
}

$runId = "$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ', [Globalization.CultureInfo]::InvariantCulture))-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
$gateDirectory = Join-Path $artifactRoot "release-gates\v0.4.0\issue-22\$runId"
$testResultDirectory = Join-Path $gateDirectory 'test-results'
New-Item -ItemType Directory -Path $testResultDirectory -Force | Out-Null

$testRuns = @(
    [pscustomobject]@{
        Project = Join-Path $repositoryRoot 'tests\HerdrOps.IntegrationTests\HerdrOps.IntegrationTests.csproj'
        Filter = 'FullyQualifiedName~WidgetAssignmentProjectionTests|FullyQualifiedName~AssignmentLifecycleIngestionCoordinatorTests|FullyQualifiedName~UiLanguageCatalogTests'
        Log = 'expanded-widget-lifecycle-language.trx'
    },
    [pscustomobject]@{
        Project = Join-Path $repositoryRoot 'tests\HerdrOps.RuntimeTests\HerdrOps.RuntimeTests.csproj'
        Filter = 'FullyQualifiedName~ExpandedWidgetRendersExactSharedAgentTaskStateAndDeepLinkActions'
        Log = 'expanded-widget-wpf.trx'
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
        throw "v0.4 Expanded Widget evidence tests failed: $($testRun.Project)"
    }
}

$testResults = @(Get-ChildItem -LiteralPath $testResultDirectory -Filter '*.trx' -File)
if ($testResults.Count -ne 2) {
    throw "Expected exactly 2 fresh Expanded Widget TRX files, found $($testResults.Count)."
}

$combinedTestLog = ($testResults | ForEach-Object {
    Get-Content -LiteralPath $_.FullName -Raw
}) -join "`n"
$requiredChecks = @(
    'ExactTerminalAndRoleBindOneTaskWithLifecycleProvenanceAndScore',
    'MissingAgentAndRoleMismatchRemainDiagnosticOnly',
    'MultipleCurrentTasksForOneAgentFailClosed',
    'AnalysisFromAnotherLifecycleCannotSupplyWidgetScore',
    'DashboardDelegationAndExpandedWidgetShareOneLifecycleTip',
    'DurableAcceptanceRestartsWithExactIdentityAndContinuesSequence',
    'FailedDurableCommitDoesNotAdvanceAcceptanceIdentity',
    'RuntimeAcceptanceRequiresExactFourAgentIdentityAndRoleBindings',
    'ProductCommandBindsDurableLifecycleToOverlappingHerdrRuntime',
    'ProductCommandRejectsRuntimeReportThatClaimsSessionControl',
    'ProductCommandRejectsAcceptedLedgerThatDoesNotReproduceReplay',
    'ThaiIsTheDefaultAndBothCatalogsContainTheSameNonEmptyKeys',
    'ThaiCatalogUsesThaiCoreTerminologyWithoutEnglishLabel',
    'EveryV01XamlLanguageBindingExistsAndNoBilingualLiteralRemains',
    'SyntheticOverviewAndWidgetCopyRebuildsAsOneSelectedLanguage',
    'LiveDashboardCopyRebuildsFromThaiToEnglishWithoutRetainingThaiText',
    'ExpandedWidgetRendersExactSharedAgentTaskStateAndDeepLinkActions'
)
foreach ($check in $requiredChecks) {
    if ($combinedTestLog -notmatch [Regex]::Escape($check)) {
        throw "Required v0.4 Expanded Widget check is absent from fresh test logs: $check"
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
if ($totalTests -lt $requiredChecks.Count -or
    $failedTests -ne 0 -or
    $totalTests -ne $passedTests) {
    throw "Expanded Widget counters are not all passing: total=$totalTests passed=$passedTests failed=$failedTests"
}

foreach ($requiredFile in @(
        $referencePath,
        $implementationPath,
        $runtimeContractPath,
        $runtimeHarnessPath,
        $releaseGatePath,
        $assignmentExamplePath)) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
        throw "Required Issue #22 asset is missing: $requiredFile"
    }
}

$referenceSha256 = (Get-FileHash -LiteralPath $referencePath -Algorithm SHA256).Hash
if ($referenceSha256 -ne $expectedReferenceSha256) {
    throw "Expanded Widget reference SHA-256 drifted: expected $expectedReferenceSha256 observed $referenceSha256"
}

$captureDirectory = Join-Path $artifactRoot 'design-evidence\v0.4.0\issue-22\contract-backed-wpf'
$requiredCaptures = @('expanded-thai.png', 'expanded-english.png')
$captureEvidence = foreach ($captureName in $requiredCaptures) {
    $capturePath = Join-Path $captureDirectory $captureName
    if (-not (Test-Path -LiteralPath $capturePath -PathType Leaf)) {
        throw "Required actual WPF capture is missing: $capturePath"
    }
    if ((Get-Item -LiteralPath $capturePath).Length -le 4000) {
        throw "Actual WPF capture is unexpectedly small: $capturePath"
    }

    [pscustomobject]@{
        Name = $captureName
        Sha256 = (Get-FileHash -LiteralPath $capturePath -Algorithm SHA256).Hash
    }
}
if ($captureEvidence[0].Sha256 -eq $captureEvidence[1].Sha256) {
    throw 'Thai and English Expanded Widget evidence rendered identically.'
}

$configurationDirectory = $Configuration.ToLowerInvariant()
$coreExecutable = Join-Path $artifactRoot "bin\HerdrOps.Core\$configurationDirectory\HerdrOps.Core.exe"
$cliExecutable = Join-Path $artifactRoot "bin\HerdrOps.Cli\$configurationDirectory\HerdrOps.Cli.exe"
foreach ($executable in @($coreExecutable, $cliExecutable)) {
    if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
        throw "Required built Issue #22 executable is missing: $executable"
    }
}

$durableDirectory = Join-Path $gateDirectory 'durable-cli-core'
$durableDatabasePath = Join-Path $durableDirectory 'assignment-lifecycle.db'
$durableTracePath = Join-Path $durableDirectory 'lifecycle-trace.json'
$durableInputPath = Join-Path $durableDirectory 'assignment.json'
$durableResultPath = Join-Path $durableDirectory 'accepted-result.json'
$durableErrorPath = Join-Path $durableDirectory 'accepted.stderr.txt'
$durableCoreOutputPath = Join-Path $durableDirectory 'core.stdout.txt'
$durableCoreErrorPath = Join-Path $durableDirectory 'core.stderr.txt'
New-Item -ItemType Directory -Path $durableDirectory -Force | Out-Null
$durableInput = Get-Content -LiteralPath $assignmentExamplePath -Raw | ConvertFrom-Json
$durableInput.eventId = [Guid]::NewGuid().ToString('D')
$durableInput.occurredUtc = [DateTimeOffset]::UtcNow.AddSeconds(-5).ToString(
    'yyyy-MM-ddTHH:mm:ss.fffZ',
    [Globalization.CultureInfo]::InvariantCulture)
[IO.File]::WriteAllText(
    $durableInputPath,
    ($durableInput | ConvertTo-Json -Depth 8),
    [Text.UTF8Encoding]::new($false))

$durablePipeName = "herdrops-v04-expanded-$([Guid]::NewGuid().ToString('N'))"
$durableCoreProcess = $null
try {
    $durableCoreProcess = Start-Process `
        -FilePath $coreExecutable `
        -ArgumentList @(
            'serve-self-reports',
            '--known-task', 'TASK-115',
            '--pipe-name', $durablePipeName,
            '--database', $durableDatabasePath,
            '--seconds', '10',
            '--trace', $durableTracePath) `
        -RedirectStandardOutput $durableCoreOutputPath `
        -RedirectStandardError $durableCoreErrorPath `
        -WindowStyle Hidden `
        -PassThru
    $readyDeadline = [DateTime]::UtcNow.AddSeconds(5)
    $coreReady = $false
    while ([DateTime]::UtcNow -lt $readyDeadline) {
        $durableCoreProcess.Refresh()
        if ($durableCoreProcess.HasExited) {
            break
        }
        if ((Test-Path -LiteralPath $durableCoreOutputPath -PathType Leaf) -and
            ((Get-Content -LiteralPath $durableCoreOutputPath -Raw) -match 'self-report service ready')) {
            $coreReady = $true
            break
        }
        Start-Sleep -Milliseconds 50
    }
    if (-not $coreReady) {
        throw 'The durable Core self-report process did not become ready within 5 seconds.'
    }

    $acceptedLines = @(& $cliExecutable `
        'assignment' `
        '--input' $durableInputPath `
        '--pipe-name' $durablePipeName `
        '--timeout-ms' '2000' 2> $durableErrorPath)
    $acceptedExitCode = $LASTEXITCODE
    [IO.File]::WriteAllText(
        $durableResultPath,
        ($acceptedLines -join [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false))
    if ($acceptedExitCode -ne 0) {
        throw "The built CLI-to-durable-Core exchange failed with exit $acceptedExitCode."
    }
    if (-not $durableCoreProcess.WaitForExit(16000)) {
        throw 'The durable Core self-report process exceeded its bounded duration.'
    }
    $durableCoreProcess.WaitForExit()
    $durableCoreProcess.Refresh()
    $durableCoreExitCode = if ($durableCoreProcess.HasExited) { [int]$durableCoreProcess.ExitCode } else { $null }
    if ($null -eq $durableCoreExitCode -or $durableCoreExitCode -ne 0) {
        throw "The durable Core self-report process failed with exit $durableCoreExitCode. Output: $durableCoreOutputPath; Error: $durableCoreErrorPath"
    }
} finally {
    if ($null -ne $durableCoreProcess) {
        $durableCoreProcess.Refresh()
        if (-not $durableCoreProcess.HasExited) {
            Stop-Process -Id $durableCoreProcess.Id -Force -ErrorAction SilentlyContinue
        }
    }
}

foreach ($errorPath in @($durableErrorPath, $durableCoreErrorPath)) {
    if ((Test-Path -LiteralPath $errorPath -PathType Leaf) -and
        (Get-Item -LiteralPath $errorPath).Length -ne 0) {
        throw "The durable CLI-to-Core process wrote stderr: $(Get-Content -LiteralPath $errorPath -Raw)"
    }
}
if (-not (Test-Path -LiteralPath $durableTracePath -PathType Leaf)) {
    throw 'The durable CLI-to-Core process did not write its lifecycle trace.'
}
$durableResult = Get-Content -LiteralPath $durableResultPath -Raw | ConvertFrom-Json
$durableTrace = Get-Content -LiteralPath $durableTracePath -Raw | ConvertFrom-Json
if (-not [bool]$durableResult.accepted -or
    $durableResult.acceptedSource -ne 'HerdrOps.Core' -or
    -not [bool]$durableTrace.durableLifecycleEnabled -or
    [long]$durableTrace.lastSequence -ne 1 -or
    @($durableTrace.acceptedEvents).Count -ne 1 -or
    @($durableTrace.lifecycleReplay.currentTasks).Count -ne 1 -or
    [string]$durableTrace.lifecycleGraphSha256 -notmatch '^[0-9A-F]{64}$') {
    throw 'The built CLI-to-durable-Core trace is missing exact acceptance or lifecycle state.'
}
$durableTraceSha256 = (Get-FileHash -LiteralPath $durableTracePath -Algorithm SHA256).Hash

$sourceCommit = (& git -C $repositoryRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($sourceCommit)) {
    throw 'Could not resolve the source commit for the v0.4 Expanded Widget gate.'
}
$implementationSha256 = (Get-FileHash -LiteralPath $implementationPath -Algorithm SHA256).Hash
$runtimeContractSha256 = (Get-FileHash -LiteralPath $runtimeContractPath -Algorithm SHA256).Hash
$gateReportPath = Join-Path $gateDirectory 'gate-report.txt'
$gateReport = @(
    'HerdrOps v0.4 Issue #22 Expanded Widget Implementation Gate',
    "GeneratedUtc: $([DateTime]::UtcNow.ToString('O'))",
    "SourceCommit: $sourceCommit",
    'Result: IMPLEMENTATION READY',
    'ImplementationGate: PASS',
    'IssueAcceptance: PENDING ACTUAL HERDR RUNTIME',
    'VersionReleaseGate: PENDING',
    'EvidenceClass: Contract plus Synthetic plus actual WPF rendering plus local SQLite integration',
    'ActualHerdrAgentRuntime: NOT OBSERVED / NOT CLAIMED',
    'RuntimeAcceptanceHarness: IMPLEMENTED / NOT EXECUTED BY THIS GATE',
    'BuiltCliToDurableCoreProcess: OBSERVED',
    'IssueStateRequired: OPEN',
    "Tests: $passedTests/$totalTests PASS",
    "ApprovedReferenceSha256: $referenceSha256",
    "ImplementationRecordSha256: $implementationSha256",
    "RuntimeContractSha256: $runtimeContractSha256",
    "DurableLifecycleTraceSha256: $durableTraceSha256",
    "ActualWpfCaptures: $($requiredCaptures.Count)",
    'LanguageModes: Thai-only or English-only interface copy',
    'IdentityPolicy: exact terminal ID plus exact role plus one current task',
    'ScorePolicy: exact lifecycle graph provenance or unknown',
    '',
    'RequiredChecks:'
) + ($requiredChecks | ForEach-Object { "PASS $_" }) + @(
    '',
    'CaptureHashes:'
) + ($captureEvidence | ForEach-Object { "SHA256 $($_.Sha256) $($_.Name)" }) + @(
    '',
    'EvidenceBoundary:',
    'This gate proves shared lifecycle projection, exact Agent and role binding, fail-closed ambiguity and provenance handling, durable restart behavior, localized accessible deep links, approved-reference binding, and actual Thai and English WPF rendering from deterministic contract-backed state.',
    'It does not prove that four actual Herdr Agents performed the lifecycle. The authorized runtime harness must produce a passing composite report before Issue #22 or v0.4 can receive runtime or release credit.',
    'Current-user Named Pipe isolation does not authenticate which same-user process submitted an event.'
)
$gateReport | Set-Content -LiteralPath $gateReportPath -Encoding utf8
$gateReport | Write-Output
Write-Output "GateReport: $gateReportPath"
