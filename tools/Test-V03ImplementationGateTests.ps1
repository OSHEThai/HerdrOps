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

function New-StubChildGates {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$SourceCommit,
        [string]$FailIssue
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
            $scriptText = @"
[CmdletBinding()]
param([string]`$Configuration, [switch]`$SkipBuild, [switch]`$ImplementationOnly)
@(
    'HerdrOps v0.3 Issue #$($definition.Issue) Implementation Gate',
    'SourceCommit: $SourceCommit',
    'Result: PASS',
    'EvidenceClass: Contract plus Synthetic'
) | Set-Content -LiteralPath '$reportPath' -Encoding utf8
Write-Output 'GateReport: $reportPath'
"@
        }
        Set-Content -LiteralPath $scriptPath -Value $scriptText -Encoding utf8
    }
}

$sourceCommit = (& git -C $repositoryRoot rev-parse --verify 'HEAD^{commit}').Trim()
$definitions = @(Get-V03ImplementationChildGateDefinitions)
Assert-Equal -Expected '12,13,14,15,16' -Actual (($definitions | ForEach-Object Issue) -join ',') -Message 'Child issue order drifted.'
Assert-Equal -Expected 'Test-V03FileGitActivity.ps1' -Actual $definitions[3].ScriptName -Message 'Issue #15 child script drifted.'
Assert-True -Condition $definitions[3].ImplementationOnly -Message 'Issue #15 must use the implementation-only child mode.'

$testRoot = Join-Path $artifactRoot "implementation-gate-test-fixtures\$([Guid]::NewGuid().ToString('N'))"
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
    Assert-V03ImplementationChildReport -Name 'Valid' -ReportText (Get-Content -LiteralPath $resolved -Raw) -SourceCommit $sourceCommit
    Assert-Throws -Action { Resolve-V03ImplementationReportPath -Output @('GateReport: one', 'GateReport: two') -ArtifactRoot $artifactRoot } -Message 'Duplicate child report paths were accepted.'
    Assert-Throws -Action { Assert-V03ImplementationChildReport -Name 'Unsafe' -ReportText "SourceCommit: $sourceCommit`nResult: PASS`nEvidenceClass: Runtime" -SourceCommit $sourceCommit } -Message 'Runtime evidence was accepted by the implementation report validator.'

    $fixedTime = [DateTime]::new(2026, 8, 20, 0, 0, 0, [DateTimeKind]::Utc)
    $sampleResults = @(
        [pscustomobject]@{ Issue = '12'; Name = 'ActivityPipeline'; Status = 'PASS'; ReportSha256 = 'A' },
        [pscustomobject]@{ Issue = '13'; Name = 'RealtimeActivity'; Status = 'PASS'; ReportSha256 = 'B' }
    )
    $firstReport = @(New-V03ImplementationGateReport -SourceCommit $sourceCommit -ChildResults $sampleResults -Result PASS -GeneratedUtc $fixedTime) -join "`n"
    $secondReport = @(New-V03ImplementationGateReport -SourceCommit $sourceCommit -ChildResults $sampleResults -Result PASS -GeneratedUtc $fixedTime) -join "`n"
    Assert-Equal -Expected $firstReport -Actual $secondReport -Message 'Aggregate report bytes were not deterministic.'
    Assert-True -Condition ($firstReport -match 'GateKind: Implementation') -Message 'Aggregate report omitted the implementation scope.'
    Assert-True -Condition ($firstReport -match 'EvidenceClasses: Static, Contract, Synthetic') -Message 'Aggregate report omitted evidence classes.'
    Assert-True -Condition ($firstReport -notmatch '(?i)release|runtime') -Message 'Aggregate report contains a release/runtime acceptance term.'

    $passingRoot = Join-Path $testRoot 'passing-children'
    New-Item -ItemType Directory -Path $passingRoot -Force | Out-Null
    New-StubChildGates -Root $passingRoot -SourceCommit $sourceCommit
    $pwshPath = (Get-Command pwsh -ErrorAction Stop).Source
    $passingOutput = @(& $pwshPath -NoProfile -File $aggregateScript -Configuration Debug -SkipBuild -ChildGateRoot $passingRoot 2>&1)
    $passingExitCode = $LASTEXITCODE
    $passingOutputText = @($passingOutput | ForEach-Object { [string]$_ }) -join ' | '
    Assert-Equal -Expected 0 -Actual $passingExitCode -Message "Aggregate did not propagate all-child success. Output=$passingOutputText"
    $passingReportPath = Get-AggregateReportPath -Output $passingOutput
    $passingReportText = Get-Content -LiteralPath $passingReportPath -Raw
    Assert-True -Condition ($passingReportText -match '(?m)^Result: PASS$') -Message 'Passing aggregate report did not say PASS.'
    Assert-True -Condition ($passingReportText -match '(?m)^ChildGates: 5/5 PASS$') -Message 'Passing aggregate did not record all five child gates.'

    $failingRoot = Join-Path $testRoot 'failing-children'
    New-Item -ItemType Directory -Path $failingRoot -Force | Out-Null
    New-StubChildGates -Root $failingRoot -SourceCommit $sourceCommit -FailIssue '14'
    $failingOutput = @(& $pwshPath -NoProfile -File $aggregateScript -Configuration Debug -SkipBuild -ChildGateRoot $failingRoot 2>&1)
    $failingExitCode = $LASTEXITCODE
    Assert-True -Condition ($failingExitCode -ne 0) -Message 'Aggregate swallowed a child-gate failure.'
    $failingReportPath = Get-AggregateReportPath -Output $failingOutput
    $failingReportText = Get-Content -LiteralPath $failingReportPath -Raw
    Assert-True -Condition ($failingReportText -match '(?m)^Result: FAIL$') -Message 'Failed aggregate report did not say FAIL.'
    Assert-True -Condition ($failingReportText -match '(?m)^FailureCode: ChildGateFailed:14$') -Message 'Failed aggregate did not preserve the deterministic child failure code.'
    Assert-True -Condition ($failingReportText -notmatch '(?i)release|runtime') -Message 'Failed aggregate report contains a release/runtime acceptance term.'
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Output 'Test-V03ImplementationGateTests: PASS'
