[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$artifactRoot = Join-Path $repositoryRoot 'artifacts'
$aggregateScript = Join-Path $PSScriptRoot 'Test-V03ImplementationGate.ps1'
Import-Module (Join-Path $PSScriptRoot 'V03ImplementationGate.psm1') -Force

function Assert-Equal {
    param(
        [Parameter(Mandatory)]$Expected,
        [Parameter(Mandatory)]$Actual,
        [Parameter(Mandatory)][string]$Message
    )

    if ($Expected -ne $Actual) {
        throw "$Message Expected='$Expected' Actual='$Actual'"
    }
}

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Throws {
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)][string]$Message
    )

    $thrown = $false
    try {
        & $Action
    }
    catch {
        $thrown = $true
    }
    Assert-True -Condition $thrown -Message $Message
}

function Get-AggregateReportPath {
    param(
        [Parameter(Mandatory)][object[]]$Output
    )

    $line = @($Output | ForEach-Object { [string]$_ } | Where-Object {
            $_ -match '^ImplementationGateReport:\s*(?<path>.+?)\s*$'
        })
    Assert-Equal -Expected 1 -Actual $line.Count -Message 'Aggregate report path count was not deterministic.'
    $null = $line[0] -match '^ImplementationGateReport:\s*(?<path>.+?)\s*$'
    return $Matches.path.Trim()
}

function Invoke-AggregateWithCleanTestGit {
    param(
        [Parameter(Mandatory)][string]$AggregateScript,
        [Parameter(Mandatory)][string]$ChildRoot,
        [Parameter(Mandatory)][string]$HelperRoot
    )

    $helperPath = Join-Path $HelperRoot 'aggregate-clean-git-helper.ps1'
    $realGitPath = (Get-Command git.exe -ErrorAction Stop).Source.Replace("'", "''")
    $helperText = @"
[CmdletBinding()]
param([string]`$AggregateScript, [string]`$ChildRoot)
function git {
    param([Parameter(ValueFromRemainingArguments=`$true)][string[]]`$Arguments)
    if (`$Arguments -contains 'status') {
        `$global:LASTEXITCODE = 0
        return
    }

    & '$realGitPath' @Arguments
    `$global:LASTEXITCODE = `$LASTEXITCODE
}

# This stub helper spawns its own child process to isolate the fixture run
# from whatever real Herdr session happens to be hosting this test suite.
# The production gate script's own fail-closed check (below) is untouched:
# it still reads these variables directly whenever it runs for real.
Remove-Item Env:\HERDR_ENV -ErrorAction SilentlyContinue
Remove-Item Env:\HERDR_SOCKET_PATH -ErrorAction SilentlyContinue

& `$AggregateScript -Configuration Debug -SkipBuild -ChildGateRoot `$ChildRoot
exit `$LASTEXITCODE
"@
    Set-Content -LiteralPath $helperPath -Value $helperText -Encoding utf8
    $pwshPath = (Get-Command pwsh -ErrorAction Stop).Source
    return @(& $pwshPath -NoProfile -File $helperPath -AggregateScript $AggregateScript -ChildRoot $ChildRoot 2>&1)
}

function New-StubChildGates {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$SourceCommit,
        [string]$FailIssue,
        [string]$PartialIssue
    )

    $definitions = @(Get-V03ImplementationChildGateDefinitions)
    $reportRoot = Join-Path $Root 'reports'
    New-Item -ItemType Directory -Path $reportRoot -Force | Out-Null
    foreach ($definition in $definitions) {
        $scriptPath = Join-Path $Root $definition.ScriptName
        $reportPath = Join-Path $reportRoot "issue-$($definition.Issue)-gate-report.txt"
        if ($definition.Issue -eq $FailIssue) {
            $scriptText = @"
[CmdletBinding()]
param([string]`$Configuration, [switch]`$SkipBuild, [switch]`$ImplementationOnly)
throw 'synthetic child failure'
"@
        }
        else {
            $resultValue = if ($definition.Issue -eq $PartialIssue) {
                'IMPLEMENTATION READY / PARTIAL'
            }
            else {
                'PASS'
            }
            $scriptText = @"
[CmdletBinding()]
param([string]`$Configuration, [switch]`$SkipBuild, [switch]`$ImplementationOnly)
@(
    'HerdrOps v0.3 Issue #$($definition.Issue) Implementation Gate',
    'SourceCommit: $SourceCommit',
    'Result: $resultValue',
    'EvidenceClass: Contract plus Synthetic'
) | Set-Content -LiteralPath '$reportPath' -Encoding utf8
Write-Output 'GateReport: $reportPath'
"@
        }
        Set-Content -LiteralPath $scriptPath -Value $scriptText -Encoding utf8
    }
}

function Invoke-AggregateDirectlyWithForcedHerdrEnvironment {
    param(
        [Parameter(Mandatory)][string]$AggregateScript,
        [Parameter(Mandatory)][string]$HelperRoot
    )

    $helperPath = Join-Path $HelperRoot 'aggregate-forced-herdr-helper.ps1'
    $helperText = @"
[CmdletBinding()]
param([string]`$AggregateScript)
`$env:HERDR_ENV = '1'
`$env:HERDR_SOCKET_PATH = 'X:\forced-production-check\herdr.sock'
& `$AggregateScript -SkipBuild
exit `$LASTEXITCODE
"@
    Set-Content -LiteralPath $helperPath -Value $helperText -Encoding utf8
    $pwshPath = (Get-Command pwsh -ErrorAction Stop).Source
    return @(& $pwshPath -NoProfile -File $helperPath -AggregateScript $AggregateScript 2>&1)
}

$sourceCommit = (& git -C $repositoryRoot rev-parse --verify 'HEAD^{commit}').Trim()
$definitions = @(Get-V03ImplementationChildGateDefinitions)
$aggregateSource = Get-Content -LiteralPath $aggregateScript -Raw
Assert-Equal -Expected '12,13,14,15,16' -Actual (($definitions | ForEach-Object Issue) -join ',') -Message 'Child issue order drifted.'
Assert-Equal -Expected 'Test-V03FileGitActivity.ps1' -Actual $definitions[3].ScriptName -Message 'Issue #15 child script drifted.'
Assert-True -Condition $definitions[3].ImplementationOnly -Message 'Issue #15 must use the implementation-only child mode.'
Assert-True -Condition ($aggregateSource -match '(?s)Invoke-Build\.ps1.*?-SkipTests') -Message 'Default aggregate build path must not invoke the full WPF test suite.'

$testRoot = Join-Path $artifactRoot "implementation-gate-test-fixtures\$([Guid]::NewGuid().ToString('N'))"
$passingReportPath = ''
$failingReportPath = ''
$herdrIsolationRoot = ''
$forcedHerdrReportPath = ''
$originalHerdrEnv = $env:HERDR_ENV
$originalHerdrSocketPath = $env:HERDR_SOCKET_PATH
try {
    $reportsRoot = Join-Path $testRoot 'reports'
    New-Item -ItemType Directory -Path $reportsRoot -Force | Out-Null
    $validReportPath = Join-Path $reportsRoot 'valid.txt'
    $validReport = @(
        'HerdrOps v0.3 Issue #12 Implementation Gate',
        "SourceCommit: $sourceCommit",
        'Result: PASS',
        'EvidenceClass: Contract plus Synthetic'
    )
    $validReport | Set-Content -LiteralPath $validReportPath -Encoding utf8

    $resolved = Resolve-V03ImplementationReportPath `
        -Output @("GateReport: $validReportPath") `
        -ArtifactRoot $artifactRoot
    Assert-Equal -Expected (Resolve-Path -LiteralPath $validReportPath).Path -Actual $resolved -Message 'Child report path resolution changed.'
    $validResult = Assert-V03ImplementationChildReport -Name 'Valid' -ReportText (Get-Content -LiteralPath $resolved -Raw) -SourceCommit $sourceCommit
    Assert-Equal -Expected 'PASS' -Actual $validResult -Message 'PASS child result was not returned by the validator.'
    $partialResult = Assert-V03ImplementationChildReport -Name 'Partial' -ReportText "SourceCommit: $sourceCommit`nResult: IMPLEMENTATION READY / PARTIAL`nEvidenceClass: Contract plus Synthetic" -SourceCommit $sourceCommit
    Assert-Equal -Expected 'IMPLEMENTATION READY / PARTIAL' -Actual $partialResult -Message 'Partial child result was not returned by the validator.'
    Assert-Throws -Action { Resolve-V03ImplementationReportPath -Output @('GateReport: one', 'GateReport: two') -ArtifactRoot $artifactRoot } -Message 'Duplicate child report paths were accepted.'
    Assert-Throws -Action { Assert-V03ImplementationChildReport -Name 'Unsafe' -ReportText "SourceCommit: $sourceCommit`nResult: PASS`nEvidenceClass: Runtime" -SourceCommit $sourceCommit } -Message 'Runtime evidence was accepted by the implementation report validator.'

    $fixedTime = [DateTime]::new(2026, 8, 20, 0, 0, 0, [DateTimeKind]::Utc)
    $sampleResults = @(
        [pscustomobject]@{ Issue = '12'; Name = 'ActivityPipeline'; Status = 'PASS'; Attempted = $true; ReportSha256 = 'A' },
        [pscustomobject]@{ Issue = '13'; Name = 'RealtimeActivity'; Status = 'PARTIAL'; Attempted = $true; ReportSha256 = 'B' },
        [pscustomobject]@{ Issue = '14'; Name = 'TerminalProcess'; Status = 'NOT_RUN'; Attempted = $false; ReportSha256 = '' }
    )
    $firstReport = @(New-V03ImplementationGateReport -SourceCommit $sourceCommit -ChildResults $sampleResults -Result PASS -GeneratedUtc $fixedTime -ExpectedChildGateCount 5) -join "`n"
    $secondReport = @(New-V03ImplementationGateReport -SourceCommit $sourceCommit -ChildResults $sampleResults -Result PASS -GeneratedUtc $fixedTime -ExpectedChildGateCount 5) -join "`n"
    Assert-Equal -Expected $firstReport -Actual $secondReport -Message 'Aggregate report bytes were not deterministic.'
    Assert-True -Condition ($firstReport -match 'GateKind: Implementation') -Message 'Aggregate report omitted the implementation scope.'
    Assert-True -Condition ($firstReport -match 'EvidenceClasses: Static, Contract, Synthetic') -Message 'Aggregate report omitted evidence classes.'
    Assert-True -Condition ($firstReport -match '(?m)^ChildGates: 1/5 PASS\r?$') -Message 'Aggregate report masked partial/not-run children as PASS.'
    Assert-True -Condition ($firstReport -match '(?m)^ChildGatesPartial: 1/5 PARTIAL\r?$') -Message 'Aggregate report omitted the partial child count.'
    Assert-True -Condition ($firstReport -match '(?m)^ChildGatesNotRun: 1/5 NOT_RUN\r?$') -Message 'Aggregate report omitted the not-run child count.'
    Assert-True -Condition ($firstReport -match '(?m)^ChildGatesAttempted: 2/5\r?$') -Message 'Aggregate report omitted the attempted child count.'
    Assert-True -Condition ($firstReport -match 'Contract-backed WPF rendering') -Message 'Aggregate report rejected admitted contract-backed WPF observations.'
    Assert-True -Condition ($firstReport -match 'no installed-Herdr evidence') -Message 'Aggregate report omitted the installed-Herdr boundary.'
    Assert-True -Condition ($firstReport -match 'no live File/Git evidence') -Message 'Aggregate report omitted the live File/Git boundary.'
    Assert-True -Condition ($firstReport -match 'no release evidence') -Message 'Aggregate report omitted the release boundary.'
    Assert-True -Condition ($firstReport -notmatch '(?im)^RuntimeAccepted:\s*true\s*$|^ReleaseReady:\s*true\s*$') -Message 'Aggregate report contains a positive acceptance claim.'

    $passingRoot = Join-Path $testRoot 'passing-children'
    New-Item -ItemType Directory -Path $passingRoot -Force | Out-Null
    New-StubChildGates -Root $passingRoot -SourceCommit $sourceCommit -PartialIssue '13'
    $passingOutput = @(Invoke-AggregateWithCleanTestGit -AggregateScript $aggregateScript -ChildRoot $passingRoot -HelperRoot $testRoot)
    $passingExitCode = $LASTEXITCODE
    $passingOutputText = @($passingOutput | ForEach-Object { [string]$_ }) -join ' | '
    Assert-Equal -Expected 0 -Actual $passingExitCode -Message "Aggregate did not propagate all-child success. Output=$passingOutputText"
    $passingReportPath = Get-AggregateReportPath -Output $passingOutput
    $passingReportText = Get-Content -LiteralPath $passingReportPath -Raw
    Assert-True -Condition ($passingReportText -match '(?m)^Result: PASS\r?$') -Message 'Passing aggregate report did not say PASS.'
    Assert-True -Condition ($passingReportText -match '(?m)^ChildGates: 4/5 PASS\r?$') -Message 'Passing aggregate masked a partial child as PASS.'
    Assert-True -Condition ($passingReportText -match '(?m)^ChildGatesPartial: 1/5 PARTIAL\r?$') -Message 'Passing aggregate did not preserve the partial child status.'
    Assert-True -Condition ($passingReportText -match '(?m)^ChildGatesFailed: 0/5 FAIL\r?$') -Message 'Passing aggregate reported an unexpected child failure.'
    Assert-True -Condition ($passingReportText -match '(?m)^ChildGatesAttempted: 5/5\r?$') -Message 'Passing aggregate did not attempt every child gate.'
    Assert-True -Condition ($passingReportText -match 'StdoutArtifact: child-gates/issue-12\.stdout\.txt') -Message 'Passing aggregate omitted the stdout artifact reference.'
    Assert-True -Condition ($passingReportText -match 'StderrArtifact: child-gates/issue-12\.stderr\.txt') -Message 'Passing aggregate omitted the stderr artifact reference.'
    $passingRunDirectory = Split-Path -Parent $passingReportPath
    $passingDiagnosticDirectory = Join-Path $passingRunDirectory 'child-gates'
    Assert-True -Condition (Test-Path -LiteralPath $passingDiagnosticDirectory -PathType Container) -Message 'Passing aggregate did not create its child diagnostic directory.'
    foreach ($definition in $definitions) {
        Assert-True -Condition (Test-Path -LiteralPath (Join-Path $passingDiagnosticDirectory "issue-$($definition.Issue).stdout.txt") -PathType Leaf) -Message "Missing stdout diagnostic for Issue #$($definition.Issue)."
        Assert-True -Condition (Test-Path -LiteralPath (Join-Path $passingDiagnosticDirectory "issue-$($definition.Issue).stderr.txt") -PathType Leaf) -Message "Missing stderr diagnostic for Issue #$($definition.Issue)."
        Assert-True -Condition (Test-Path -LiteralPath (Join-Path $passingDiagnosticDirectory "issue-$($definition.Issue).gate-report.txt") -PathType Leaf) -Message "Missing copied child report for Issue #$($definition.Issue)."
    }

    $failingRoot = Join-Path $testRoot 'failing-children'
    New-Item -ItemType Directory -Path $failingRoot -Force | Out-Null
    New-StubChildGates -Root $failingRoot -SourceCommit $sourceCommit -FailIssue '14' -PartialIssue '13'
    $failingOutput = @(Invoke-AggregateWithCleanTestGit -AggregateScript $aggregateScript -ChildRoot $failingRoot -HelperRoot $testRoot)
    $failingExitCode = $LASTEXITCODE
    Assert-True -Condition ($failingExitCode -ne 0) -Message 'Aggregate swallowed a child-gate failure.'
    $failingReportPath = Get-AggregateReportPath -Output $failingOutput
    $failingReportText = Get-Content -LiteralPath $failingReportPath -Raw
    Assert-True -Condition ($failingReportText -match '(?m)^Result: FAIL\r?$') -Message 'Failed aggregate report did not say FAIL.'
    Assert-True -Condition ($failingReportText -match '(?m)^FailureCode: ChildGateFailed:14\r?$') -Message 'Failed aggregate did not preserve the deterministic child failure code.'
    Assert-True -Condition ($failingReportText -match '(?m)^ChildGates: 3/5 PASS\r?$') -Message 'Failed aggregate did not preserve successful child count.'
    Assert-True -Condition ($failingReportText -match '(?m)^ChildGatesPartial: 1/5 PARTIAL\r?$') -Message 'Failed aggregate did not preserve partial child count.'
    Assert-True -Condition ($failingReportText -match '(?m)^ChildGatesFailed: 1/5 FAIL\r?$') -Message 'Failed aggregate did not preserve failed child count.'
    Assert-True -Condition ($failingReportText -match '(?m)^ChildGatesAttempted: 5/5\r?$') -Message 'Failed aggregate did not attempt children after one failure.'
    $failingRunDirectory = Split-Path -Parent $failingReportPath
    $failingDiagnosticDirectory = Join-Path $failingRunDirectory 'child-gates'
    $failingStderr = Join-Path $failingDiagnosticDirectory 'issue-14.stderr.txt'
    Assert-True -Condition (Test-Path -LiteralPath $failingStderr -PathType Leaf) -Message 'Failed aggregate did not create the failing child stderr artifact.'
    Assert-True -Condition ((Get-Content -LiteralPath $failingStderr -Raw) -match 'synthetic child failure') -Message 'Failed aggregate lost the raw child failure diagnostic.'
    Assert-True -Condition ($failingReportText -notmatch 'synthetic child failure') -Message 'Failed aggregate exposed an unstable raw child error as a FailureCode.'

    # An ambient Herdr session (HERDR_ENV / HERDR_SOCKET_PATH set in this very
    # process, e.g. because the suite is being run from inside Herdr) must not
    # leak into the stub fixture run below and make it non-deterministic.
    $env:HERDR_ENV = '1'
    $env:HERDR_SOCKET_PATH = 'X:\ambient-session\herdr.sock'
    $herdrIsolationRoot = Join-Path $testRoot 'herdr-isolation-children'
    New-Item -ItemType Directory -Path $herdrIsolationRoot -Force | Out-Null
    New-StubChildGates -Root $herdrIsolationRoot -SourceCommit $sourceCommit
    $isolationOutput = @(Invoke-AggregateWithCleanTestGit -AggregateScript $aggregateScript -ChildRoot $herdrIsolationRoot -HelperRoot $testRoot)
    $isolationExitCode = $LASTEXITCODE
    $isolationOutputText = @($isolationOutput | ForEach-Object { [string]$_ }) -join ' | '
    Assert-Equal -Expected 0 -Actual $isolationExitCode -Message "Stub fixture suite must stay deterministic under an ambient Herdr session. Output=$isolationOutputText"
    $isolationReportPath = Get-AggregateReportPath -Output $isolationOutput
    $isolationReportText = Get-Content -LiteralPath $isolationReportPath -Raw
    Assert-True -Condition ($isolationReportText -match '(?m)^Result: PASS\r?$') -Message 'Ambient Herdr session leaked into the stub fixture aggregate result.'
    $env:HERDR_ENV = $originalHerdrEnv
    $env:HERDR_SOCKET_PATH = $originalHerdrSocketPath

    # Outside the stub isolation above, the production gate must still refuse
    # to run for real under a real Herdr environment (fail-closed).
    $forcedHerdrOutput = @(Invoke-AggregateDirectlyWithForcedHerdrEnvironment -AggregateScript $aggregateScript -HelperRoot $testRoot)
    $forcedHerdrExitCode = $LASTEXITCODE
    $forcedHerdrOutputText = @($forcedHerdrOutput | ForEach-Object { [string]$_ }) -join ' | '
    Assert-True -Condition ($forcedHerdrExitCode -ne 0) -Message "The production gate must still refuse to run under a real Herdr environment. Output=$forcedHerdrOutputText"
    $forcedHerdrReportPath = Get-AggregateReportPath -Output $forcedHerdrOutput
    $forcedHerdrReportText = Get-Content -LiteralPath $forcedHerdrReportPath -Raw
    Assert-True -Condition ($forcedHerdrReportText -match '(?m)^FailureCode: AuthorizedHerdrEnvironment\r?$') -Message 'The production gate did not fail closed with AuthorizedHerdrEnvironment under a real Herdr session.'
}
finally {
    $env:HERDR_ENV = $originalHerdrEnv
    $env:HERDR_SOCKET_PATH = $originalHerdrSocketPath
    foreach ($runDirectory in @(
            $(if ([string]::IsNullOrWhiteSpace($passingReportPath)) { '' } else { Split-Path -Parent $passingReportPath }),
            $(if ([string]::IsNullOrWhiteSpace($failingReportPath)) { '' } else { Split-Path -Parent $failingReportPath }),
            $(if ([string]::IsNullOrWhiteSpace($forcedHerdrReportPath)) { '' } else { Split-Path -Parent $forcedHerdrReportPath }))) {
        if (-not [string]::IsNullOrWhiteSpace($runDirectory) -and (Test-Path -LiteralPath $runDirectory)) {
            Remove-Item -LiteralPath $runDirectory -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Output 'Test-V03ImplementationGateTests: PASS'
