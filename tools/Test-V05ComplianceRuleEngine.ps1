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
$fixturePath = Join-Path $repositoryRoot 'tests\fixtures\v0.5\compliance-rule-corpus.json'
$contractPath = Join-Path $repositoryRoot 'docs\protocol\v0.5-compliance-rule-engine-contract.md'
$expectedInputSha256 = '338C0F80C48E92D585AA3CA66CDB0BA6399ED1442C10A25C7E61F2069C1DB83A'
$expectedRuleSetSha256 = '4EB8A183215D223296DBA64743EF24877F960556A723BDC4506F273183A972E4'
$expectedCorpusResultSha256 = '2E4B53B8B80908726C431EC5637B6A92B0F82C99E14BAE36E8EBF3BE3DCA0F11'
$expectedReportSha256 = '042361CFBE8764A6FC2E65FA4B4E78174A792A988ECC7FAD46D7974CFD57BF8E'
$expectedContractSha256 = '2DBDEDC827080D73CFD69CDF21EEC92E4DDCFD7A825E65E63B4D5B1DA2513C57'

$workingTreeStatus = @(& git -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0) {
    throw 'Could not inspect the source working tree for the v0.5 compliance-rule gate.'
}
if ($workingTreeStatus.Count -ne 0) {
    throw "The v0.5 compliance-rule gate requires a clean committed checkout. Pending paths: $($workingTreeStatus -join ', ')"
}

if (-not $SkipBuild) {
    & (Join-Path $PSScriptRoot 'Invoke-Build.ps1') -Configuration $Configuration -VerifyFormat
    if ($LASTEXITCODE -ne 0) {
        throw "v0.5 compliance-rule build gate failed with exit code $LASTEXITCODE."
    }
}

$runId = "$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ', [Globalization.CultureInfo]::InvariantCulture))-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
$gateDirectory = Join-Path $artifactRoot "release-gates\v0.5.0\issue-24\$runId"
$testResultDirectory = Join-Path $gateDirectory 'test-results'
New-Item -ItemType Directory -Path $testResultDirectory -Force | Out-Null

$testProjects = @(
    (Join-Path $repositoryRoot 'tests\HerdrOps.UnitTests\HerdrOps.UnitTests.csproj'),
    (Join-Path $repositoryRoot 'tests\HerdrOps.IntegrationTests\HerdrOps.IntegrationTests.csproj')
)
foreach ($testProject in $testProjects) {
    & dotnet test $testProject `
        --configuration $Configuration `
        --no-restore `
        --no-build `
        --artifacts-path $artifactRoot `
        --results-directory $testResultDirectory `
        --logger trx
    if ($LASTEXITCODE -ne 0) {
        throw "v0.5 compliance-rule evidence tests failed: $testProject"
    }
}

$testResults = @(Get-ChildItem -LiteralPath $testResultDirectory -Filter '*.trx' -File)
if ($testResults.Count -ne 2) {
    throw "Expected exactly 2 fresh compliance-rule TRX files, found $($testResults.Count)."
}

$combinedTestLog = ($testResults | ForEach-Object {
    Get-Content -LiteralPath $_.FullName -Raw
}) -join "`n"
$requiredChecks = @(
    'VersionOneRuleSetPublishesExactSeverityMappingAndStableHash',
    'CompliantInputsPassEveryRuleWithoutCreatingIncidentCandidate',
    'PendingOutOfScopeDeviationCreatesTwoSuspectedExplainableFindings',
    'MissingEvidenceFindingRecordsRequirementAndRejectedSubmissionFacts',
    'ReviewOrderViolationRetainsOffendingReviewFact',
    'RepeatedDetectionUsesStableIdentityAndSuppressesDuplicate',
    'SameOutOfScopeTargetWithinOneRequestIsDeduplicated',
    'OrphanEvidenceSubmissionProducesObservableRuleErrorAndNoFinding',
    'ReviewTimeRegressionProducesObservableRuleErrorWithoutIncident',
    'ApprovedDeviationMustExistBeforeActionAndCoverExactPrefixBoundary',
    'ScopePrefixDoesNotMatchSiblingWithSameLeadingCharacters',
    'RequestCollectionOrderDoesNotChangeCanonicalResult',
    'ChangedRuleDefinitionAndUnsafePathFailClosed',
    'CommittedComplianceCorpusProducesByteIdenticalReportsAndExpectedHashes',
    'UnknownCorpusMemberFailsClosedWithoutReplacingReport',
    'DuplicateCorpusPropertyFailsClosedWithoutReport',
    'MismatchedExpectationFailsClosedWithoutReplacingReport',
    'NumericRuleEnumFailsClosedWithoutReport',
    'MissingRequiredCorpusReportOptionReturnsUsageFailure',
    'CorpusInputCannotBeOverwrittenByReport'
)
foreach ($check in $requiredChecks) {
    if ($combinedTestLog -notmatch [Regex]::Escape($check)) {
        throw "Required v0.5 compliance-rule check is absent from the fresh test logs: $check"
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
if ($totalTests -le 0 -or $failedTests -ne 0 -or $totalTests -ne $passedTests) {
    throw "Compliance-rule test counters are not all passing: total=$totalTests passed=$passedTests failed=$failedTests"
}

$coreDll = Join-Path $artifactRoot "bin\HerdrOps.Core\$($Configuration.ToLowerInvariant())\HerdrOps.Core.dll"
if (-not (Test-Path -LiteralPath $coreDll -PathType Leaf)) {
    throw "Built HerdrOps.Core product command was not found: $coreDll"
}
if (-not (Test-Path -LiteralPath $fixturePath -PathType Leaf)) {
    throw "Committed v0.5 compliance corpus was not found: $fixturePath"
}
if (-not (Test-Path -LiteralPath $contractPath -PathType Leaf)) {
    throw "Committed v0.5 compliance contract was not found: $contractPath"
}

$firstReportPath = Join-Path $gateDirectory 'compliance-rule-report-1.json'
$secondReportPath = Join-Path $gateDirectory 'compliance-rule-report-2.json'
& dotnet $coreDll compliance-rule-corpus --input $fixturePath --report $firstReportPath | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "First product compliance corpus failed with exit code $LASTEXITCODE."
}
& dotnet $coreDll compliance-rule-corpus --input $fixturePath --report $secondReportPath | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Second product compliance corpus failed with exit code $LASTEXITCODE."
}

$firstReportBytes = [System.IO.File]::ReadAllBytes($firstReportPath)
$secondReportBytes = [System.IO.File]::ReadAllBytes($secondReportPath)
if (-not [System.Linq.Enumerable]::SequenceEqual($firstReportBytes, $secondReportBytes)) {
    throw 'Repeated product compliance corpus reports are not byte-identical.'
}

$fixtureSha256 = (Get-FileHash -LiteralPath $fixturePath -Algorithm SHA256).Hash
$contractSha256 = (Get-FileHash -LiteralPath $contractPath -Algorithm SHA256).Hash
$reportSha256 = (Get-FileHash -LiteralPath $firstReportPath -Algorithm SHA256).Hash
if ($fixtureSha256 -ne $expectedInputSha256) {
    throw "Compliance corpus SHA-256 drifted: expected $expectedInputSha256 observed $fixtureSha256"
}
if ($contractSha256 -ne $expectedContractSha256) {
    throw "Compliance contract SHA-256 drifted: expected $expectedContractSha256 observed $contractSha256"
}
if ($reportSha256 -ne $expectedReportSha256) {
    throw "Compliance report SHA-256 drifted: expected $expectedReportSha256 observed $reportSha256"
}

$report = Get-Content -LiteralPath $firstReportPath -Raw | ConvertFrom-Json -Depth 128
if ($report.contractVersion -ne 1) { throw "Unexpected compliance report contract: $($report.contractVersion)" }
if ($report.evidenceClass -ne 'Synthetic') { throw "Unexpected evidence class: $($report.evidenceClass)" }
if ($report.runtimeObserved -ne $false) { throw 'Compliance corpus must not claim runtime observation.' }
if ($report.inputSha256 -ne $expectedInputSha256) { throw 'Compliance report does not bind the committed corpus.' }
if ($report.ruleSet.ruleSetSha256 -ne $expectedRuleSetSha256) { throw 'Compliance report does not bind the exact v1 rule set.' }
if ($report.corpusResultSha256 -ne $expectedCorpusResultSha256) { throw 'Unexpected deterministic compliance corpus result.' }

$expectedDefinitions = [ordered]@{
    ScopeViolation = [ordered]@{ RuleId = 'HDO-CMP-SCOPE-001'; RuleVersion = 1; Severity = 'Critical' }
    MissingEvidence = [ordered]@{ RuleId = 'HDO-CMP-EVIDENCE-001'; RuleVersion = 1; Severity = 'High' }
    UnapprovedDeviation = [ordered]@{ RuleId = 'HDO-CMP-DEVIATION-001'; RuleVersion = 1; Severity = 'Medium' }
    ReviewOrder = [ordered]@{ RuleId = 'HDO-CMP-REVIEW-001'; RuleVersion = 1; Severity = 'High' }
}
foreach ($entry in $expectedDefinitions.GetEnumerator()) {
    $definition = @($report.ruleSet.rules | Where-Object { $_.ruleKind -eq $entry.Key })
    if ($definition.Count -ne 1 -or
        $definition[0].ruleId -ne $entry.Value.RuleId -or
        [int]$definition[0].ruleVersion -ne [int]$entry.Value.RuleVersion -or
        $definition[0].severity -ne $entry.Value.Severity) {
        throw "Compliance rule definition drifted for $($entry.Key)."
    }
}

$diagnostics = $report.diagnostics
$expectedCounters = [ordered]@{
    caseCount = 5
    passedCaseCount = 5
    evaluationRunCount = 6
    firstRunFindingCount = 4
    explainabilityRecordCount = 4
    firstRunRuleErrorCount = 1
    repeatedDuplicateDetectionCount = 2
    confirmedFindingCount = 0
}
foreach ($counter in $expectedCounters.GetEnumerator()) {
    if ([int]$diagnostics.($counter.Key) -ne [int]$counter.Value) {
        throw "Unexpected compliance corpus counter $($counter.Key): expected $($counter.Value) observed $($diagnostics.($counter.Key))"
    }
}

$expectedRuleKinds = @('ScopeViolation', 'MissingEvidence', 'UnapprovedDeviation', 'ReviewOrder')
$triggeredRuleKinds = @($diagnostics.triggeredRuleKinds | Sort-Object)
$passedRuleKinds = @($diagnostics.passedRuleKinds | Sort-Object)
if (($triggeredRuleKinds -join '|') -ne (($expectedRuleKinds | Sort-Object) -join '|')) {
    throw 'The positive corpus does not trigger every required compliance rule kind.'
}
if (($passedRuleKinds -join '|') -ne (($expectedRuleKinds | Sort-Object) -join '|')) {
    throw 'The negative corpus does not pass every required compliance rule kind.'
}

$allFirstRunFindings = @($report.cases | ForEach-Object { @($_.runs)[0].findings })
if ($allFirstRunFindings.Count -ne 4) {
    throw "Expected four first-run suspected findings, found $($allFirstRunFindings.Count)."
}
foreach ($finding in $allFirstRunFindings) {
    if ($finding.state -ne 'Suspected' -or
        [int]$finding.ruleVersion -ne 1 -or
        @($finding.supportingFacts).Count -le 0 -or
        $finding.explainabilitySha256 -notmatch '^[0-9A-F]{64}$') {
        throw "Finding $($finding.findingId) is not a versioned suspected finding with hash-bound supporting facts."
    }
}

$duplicateCase = @($report.cases | Where-Object { $_.caseId -eq 'scope-and-pending-deviation' })
if ($duplicateCase.Count -ne 1 -or @($duplicateCase[0].runs).Count -ne 2) {
    throw 'The duplicate-suppression corpus case is missing or incomplete.'
}
$secondRun = @($duplicateCase[0].runs)[1]
if (@($secondRun.findings).Count -ne 0 -or
    [int]$secondRun.diagnostics.duplicateDetectionCount -ne 2 -or
    @($secondRun.ruleEvaluations | Where-Object {
        $_.outcome -eq 'DuplicateSuppressed'
    }).Count -ne 2) {
    throw 'Repeated compliance detections were not explicitly suppressed.'
}

$errorCase = @($report.cases | Where-Object { $_.caseId -eq 'orphan-evidence-rule-error' })
$errorEvaluation = @($errorCase[0].runs[0].ruleEvaluations | Where-Object {
    $_.ruleKind -eq 'MissingEvidence'
})
if ($errorCase.Count -ne 1 -or
    $errorEvaluation.Count -ne 1 -or
    $errorEvaluation[0].outcome -ne 'Error' -or
    $errorEvaluation[0].errorCode -ne 'orphan-evidence-submission' -or
    @($errorCase[0].runs[0].findings).Count -ne 0) {
    throw 'The rule-error corpus case did not fail observable without creating an incident.'
}

$sourceCommit = (& git -C $repositoryRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($sourceCommit)) {
    throw 'Could not resolve the source commit for the v0.5 compliance-rule gate.'
}
$gateReportPath = Join-Path $gateDirectory 'gate-report.txt'
$gateReport = @(
    'HerdrOps v0.5 Issue #24 Explainable Compliance Rule Engine Gate',
    "GeneratedUtc: $([DateTime]::UtcNow.ToString('O'))",
    "SourceCommit: $sourceCommit",
    'Result: IMPLEMENTATION READY',
    'ImplementationGate: PASS',
    'IssueAcceptance: PENDING INDEPENDENT REVIEW',
    'VersionReleaseGate: PENDING',
    'EvidenceClass: Contract plus Synthetic',
    'ActualHerdrRuntime: NOT OBSERVED / NOT CLAIMED',
    'RoleDistinctReviewRuntime: NOT OBSERVED / NOT CLAIMED',
    'ImmutableEvidenceStorage: NOT IMPLEMENTED IN ISSUE #24',
    'ComplianceQueueUi: NOT IMPLEMENTED IN ISSUE #24',
    "Tests: $passedTests/$totalTests PASS",
    "CorpusSha256: $fixtureSha256",
    "RuleSetSha256: $($report.ruleSet.ruleSetSha256)",
    "CorpusResultSha256: $($report.corpusResultSha256)",
    "CorpusReportSha256: $reportSha256",
    "ContractSha256: $contractSha256",
    'RepeatedCorpusReports: BYTE IDENTICAL',
    "Cases: $($diagnostics.passedCaseCount)/$($diagnostics.caseCount) PASS",
    "EvaluationRuns: $($diagnostics.evaluationRunCount)",
    "FirstRunSuspectedFindings: $($diagnostics.firstRunFindingCount)",
    "ExplainabilityRecords: $($diagnostics.explainabilityRecordCount)",
    "ObservableRuleErrors: $($diagnostics.firstRunRuleErrorCount)",
    "DuplicateDetectionsSuppressed: $($diagnostics.repeatedDuplicateDetectionCount)",
    "ConfirmedFindings: $($diagnostics.confirmedFindingCount)",
    '',
    'RequiredChecks:'
) + ($requiredChecks | ForEach-Object { "PASS $_" }) + @(
    '',
    'EvidenceBoundary:',
    'This gate proves exact versioned rule definitions and severity mapping, deterministic positive and negative evaluation, suspected-only explainable findings, visible rule errors, stable duplicate suppression, strict product-command input handling, and byte-identical synthetic corpus reports.',
    'It does not prove immutable evidence metadata or bytes, authorized Leader or Project Manager transitions, Compliance Queue rendering, retention or redaction, actual Herdr operation, a role-distinct runtime review workflow, independent acceptance, or v0.5 release readiness.'
)
$gateReport | Set-Content -LiteralPath $gateReportPath -Encoding utf8
$gateReport | Write-Output
Write-Output "CorpusReport: $firstReportPath"
Write-Output "GateReport: $gateReportPath"
