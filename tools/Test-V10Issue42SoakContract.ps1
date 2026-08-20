[CmdletBinding()]
param(
    [string]$CandidateArchivePath = '',
    [string]$CandidateArchiveSha256 = '',
    [long]$CandidateArchiveBytes = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path)
$artifactRoot = [IO.Path]::GetFullPath((Join-Path $repositoryRoot 'artifacts'))
$expectedBranch = 'codex/v10-issue-42-soak-contract'
$version = 'v1.0.0'
$issueNumber = '#42'
$contractRelativePath = 'docs/protocol/v1.0-issue-42-soak-fault-injection-contract.md'
$fixtureRelativePath = 'tests/fixtures/v1.0/issue-42/soak-alert-consistency.json'
$policyRelativePath = 'tools/SoakContractPolicy.ps1'
$runId = "$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ', [Globalization.CultureInfo]::InvariantCulture))-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
$gateDirectory = [IO.Path]::GetFullPath((Join-Path $artifactRoot "release-gates\v1.0.0\issue-42\$runId"))
$gateReportPath = [IO.Path]::GetFullPath((Join-Path $gateDirectory 'gate-report.txt'))

$policyPath = Join-Path $PSScriptRoot 'SoakContractPolicy.ps1'
if (-not (Test-Path -LiteralPath $policyPath -PathType Leaf)) {
    throw 'Issue #42 soak policy module is missing: tools/SoakContractPolicy.ps1'
}
. $policyPath

$script:checks = New-Object System.Collections.ArrayList
$script:failures = New-Object System.Collections.ArrayList

function Record-Check {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][ValidateSet('PASS', 'FAIL', 'NOT OBSERVED')][string]$Status,
        [Parameter(Mandatory)][string]$EvidenceClass,
        [Parameter(Mandatory)][string]$Detail
    )

    [void]$script:checks.Add([pscustomobject]@{
        Id = $Id
        Status = $Status
        EvidenceClass = $EvidenceClass
        Detail = $Detail
    })
    if ($Status -eq 'FAIL') {
        [void]$script:failures.Add("$Id $Detail")
    }
}

function Get-RepositoryText {
    param([Parameter(Mandatory)][string]$RelativePath)

    $path = Join-Path $repositoryRoot $RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $null
    }
    return [IO.File]::ReadAllText($path)
}

function Get-RepositoryBytes {
    param([Parameter(Mandatory)][string]$RelativePath)

    $path = Join-Path $repositoryRoot $RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $null
    }
    return [IO.File]::ReadAllBytes($path)
}

function Get-GitOutput {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $output = @(& git -C $repositoryRoot @Arguments 2>&1 | ForEach-Object { [string]$_ })
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Lines = @($output)
        Text = ($output -join '').Trim()
    }
}

New-Item -ItemType Directory -Path $gateDirectory -Force | Out-Null

$sourceCommitResult = Get-GitOutput -Arguments @('rev-parse', '--verify', 'HEAD^{commit}')
$sourceCommit = $sourceCommitResult.Text.ToLowerInvariant()
if ($sourceCommitResult.ExitCode -ne 0 -or $sourceCommit -notmatch '^[0-9a-f]{40}$') {
    $sourceCommit = 'UNRESOLVED'
    Record-Check -Id 'BOUND-01' -Status 'FAIL' -EvidenceClass 'Static' -Detail 'could not resolve exact source commit'
} else {
    Record-Check -Id 'BOUND-01' -Status 'PASS' -EvidenceClass 'Static' -Detail "source commit resolved as $sourceCommit"
}

$branchResult = Get-GitOutput -Arguments @('symbolic-ref', '--short', 'HEAD')
$branch = $branchResult.Text
if ($branchResult.ExitCode -ne 0 -or $branch -ne $expectedBranch) {
    Record-Check -Id 'BOUND-02' -Status 'FAIL' -EvidenceClass 'Static' -Detail "expected branch $expectedBranch but observed $branch"
} else {
    Record-Check -Id 'BOUND-02' -Status 'PASS' -EvidenceClass 'Static' -Detail "branch is $expectedBranch"
}

$statusResult = Get-GitOutput -Arguments @('status', '--porcelain=v1', '--untracked-files=all')
if ($statusResult.ExitCode -ne 0 -or $statusResult.Lines.Count -ne 0) {
    Record-Check -Id 'BOUND-03' -Status 'FAIL' -EvidenceClass 'Static' -Detail 'checkout is not clean and committed'
} else {
    Record-Check -Id 'BOUND-03' -Status 'PASS' -EvidenceClass 'Static' -Detail 'clean committed checkout'
}

$contractText = Get-RepositoryText -RelativePath $contractRelativePath
if ($null -eq $contractText) {
    Record-Check -Id 'CONTRACT-01' -Status 'FAIL' -EvidenceClass 'Static' -Detail "contract document is missing: $contractRelativePath"
} else {
    $markers = @(
        '24-hour',
        'fault-injection',
        'quick_check',
        'integrity_check',
        'SOAK_RESTART',
        'NOT OBSERVED / NOT CLAIMED',
        'PENDING',
        'SHA-256',
        'Core process restart',
        'App process restart',
        'Get-SoakVerdict'
    )
    $missingMarkers = @($markers | Where-Object { $contractText.IndexOf($_, [StringComparison]::Ordinal) -lt 0 })
    if ($missingMarkers.Count -eq 0) {
        Record-Check -Id 'CONTRACT-01' -Status 'PASS' -EvidenceClass 'Static' -Detail "all $($markers.Count) contract markers matched"
    } else {
        Record-Check -Id 'CONTRACT-01' -Status 'FAIL' -EvidenceClass 'Static' -Detail "missing contract markers: $($missingMarkers -join ', ')"
    }
}

try {
    $policyText = Get-RepositoryText -RelativePath $policyRelativePath
    if ($null -eq $policyText) {
        throw "policy module is missing: $policyRelativePath"
    }
    $tokens = $null
    $parseErrors = $null
    $parseResult = [System.Management.Automation.Language.Parser]::ParseInput($policyText, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -ne 0) {
        throw "policy module does not parse: $($parseErrors[0].Message)"
    }
    Record-Check -Id 'STATIC-01' -Status 'PASS' -EvidenceClass 'Static' -Detail 'soak policy module parses cleanly'
} catch {
    Record-Check -Id 'STATIC-01' -Status 'FAIL' -EvidenceClass 'Static' -Detail $_.Exception.Message
}

try {
    Test-SoakPolicyFixtures | Out-Null
    Record-Check -Id 'SELF-01' -Status 'PASS' -EvidenceClass 'Synthetic' -Detail 'deterministic policy fixtures passed without live process, listener, or database access'
} catch {
    Record-Check -Id 'SELF-01' -Status 'FAIL' -EvidenceClass 'Synthetic' -Detail $_.Exception.Message
}

$fixtureBytes = Get-RepositoryBytes -RelativePath $fixtureRelativePath
if ($null -eq $fixtureBytes) {
    Record-Check -Id 'FIXTURE-01' -Status 'FAIL' -EvidenceClass 'Synthetic' -Detail "alert-consistency fixture is missing: $fixtureRelativePath"
} else {
    try {
        $fixtureText = [IO.File]::ReadAllText((Join-Path $repositoryRoot $fixtureRelativePath))
        $fixture = Test-SoakFixtureJson -JsonText $fixtureText
        $fixtureResult = Test-SoakAlertConsistency -Events @($fixture.events) -Alerts @($fixture.alerts)
        if (-not $fixtureResult.Pass) {
            throw "committed fixture is not alert-consistent: $($fixtureResult.Findings -join '; ')"
        }
        Record-Check -Id 'FIXTURE-01' -Status 'PASS' -EvidenceClass 'Synthetic' -Detail "committed alert-consistency fixture passed ($(@($fixture.events).Count) events, $(@($fixture.alerts).Count) alerts)"
    } catch {
        Record-Check -Id 'FIXTURE-01' -Status 'FAIL' -EvidenceClass 'Synthetic' -Detail $_.Exception.Message
    }
}

$candidateSupplied = -not [string]::IsNullOrWhiteSpace($CandidateArchivePath)
if ($candidateSupplied) {
    if ([string]::IsNullOrWhiteSpace($CandidateArchiveSha256) -or $CandidateArchiveSha256 -notmatch '^[0-9a-fA-F]{64}$') {
        Record-Check -Id 'CANDIDATE-01' -Status 'FAIL' -EvidenceClass 'Static' -Detail 'a candidate archive was supplied without an exact 64-hex SHA-256'
    } else {
        try {
            $candidateResult = Test-SoakCandidateBytes -ArchivePath $CandidateArchivePath -ExpectedSha256 $CandidateArchiveSha256 -ExpectedBytes $CandidateArchiveBytes
            if (-not $candidateResult.Valid) {
                Record-Check -Id 'CANDIDATE-01' -Status 'FAIL' -EvidenceClass 'Static' -Detail ($candidateResult.Findings -join '; ')
            } else {
                Record-Check -Id 'CANDIDATE-01' -Status 'PASS' -EvidenceClass 'Static' -Detail "candidate bytes matched SHA-256=$($candidateResult.ObservedSha256) bytes=$($candidateResult.ObservedBytes)"
            }
        } catch {
            Record-Check -Id 'CANDIDATE-01' -Status 'FAIL' -EvidenceClass 'Static' -Detail $_.Exception.Message
        }
    }
} else {
    Record-Check -Id 'CANDIDATE-01' -Status 'NOT OBSERVED' -EvidenceClass 'Static' -Detail 'no exact packaged candidate archive was supplied to this preparation run'
}

Record-Check -Id 'INTEGRITY-01' -Status 'NOT OBSERVED' -EvidenceClass 'Contract' -Detail 'no live database-integrity probe was supplied; quick_check/integrity_check/user_version remain NOT OBSERVED'
Record-Check -Id 'RESTART-HERDR' -Status 'NOT OBSERVED' -EvidenceClass 'Runtime' -Detail 'Herdr restart was refused in preparation mode; no process was controlled'
Record-Check -Id 'RESTART-CORE' -Status 'NOT OBSERVED' -EvidenceClass 'Runtime' -Detail 'Core restart was refused in preparation mode; no process was controlled'
Record-Check -Id 'RESTART-APP' -Status 'NOT OBSERVED' -EvidenceClass 'Runtime' -Detail 'App restart was refused in preparation mode; no process was controlled'
Record-Check -Id 'RUNTIME-01' -Status 'NOT OBSERVED' -EvidenceClass 'Runtime' -Detail 'no 24-hour actual-Herdr soak or fault injection was performed'
Record-Check -Id 'RELEASE-01' -Status 'NOT OBSERVED' -EvidenceClass 'Release' -Detail 'no packaged release acceptance or publication was performed'

$finalCommitResult = Get-GitOutput -Arguments @('rev-parse', '--verify', 'HEAD^{commit}')
$finalCommit = $finalCommitResult.Text.ToLowerInvariant()
$finalStatusResult = Get-GitOutput -Arguments @('status', '--porcelain=v1', '--untracked-files=all')
if ($finalCommitResult.ExitCode -ne 0 -or $finalCommit -ne $sourceCommit -or $finalStatusResult.ExitCode -ne 0 -or $finalStatusResult.Lines.Count -ne 0) {
    Record-Check -Id 'BOUND-04' -Status 'FAIL' -EvidenceClass 'Static' -Detail 'source commit or clean checkout changed during the gate'
} else {
    Record-Check -Id 'BOUND-04' -Status 'PASS' -EvidenceClass 'Static' -Detail 'source commit and clean checkout remained unchanged'
}

$preparationChecks = @($script:checks | Where-Object { $_.Status -ne 'NOT OBSERVED' } | ForEach-Object {
    New-SoakCheck -Id $_.Id -Pass ($_.Status -eq 'PASS') -EvidenceClass $_.EvidenceClass -Detail $_.Detail
})
$verdict = Get-SoakVerdict -Checks $preparationChecks -RuntimeObserved $false -ReleaseObserved $false -PreparationMode $true
if ($verdict -eq 'PASS') {
    Record-Check -Id 'VERDICT-01' -Status 'FAIL' -EvidenceClass 'Synthetic' -Detail 'preparation mode illegally emitted a soak PASS'
} else {
    Record-Check -Id 'VERDICT-01' -Status 'PASS' -EvidenceClass 'Synthetic' -Detail "fail-closed verdict is $verdict; no soak PASS was emitted in preparation mode"
}

$policyHash = Get-SoakFileSha256 -Path $policyPath
$contractHash = Get-SoakFileSha256 -Path (Join-Path $repositoryRoot $contractRelativePath)
$fixtureHash = Get-SoakFileSha256 -Path (Join-Path $repositoryRoot $fixtureRelativePath)

$reportText = Format-SoakGateReport -IssueNumber $issueNumber -Version $version -Branch $branch `
    -SourceCommit $sourceCommit -Verdict $verdict -PolicySha256 $policyHash -ContractSha256 $contractHash `
    -FixtureSha256 $fixtureHash -Checks $script:checks

$utf8 = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText($gateReportPath, $reportText, $utf8)
$gateReportHash = Get-SoakFileSha256 -Path $gateReportPath

$provenance = Get-SoakProvenance -OrderedArtifacts @(
    @{ Name = 'policy'; Sha256 = $policyHash },
    @{ Name = 'contract'; Sha256 = $contractHash },
    @{ Name = 'fixture'; Sha256 = $fixtureHash },
    @{ Name = 'gate-report'; Sha256 = $gateReportHash }
)

Write-Output "Issue #42 soak-contract preparation gate: $verdict"
Write-Output "SourceCommit: $sourceCommit"
Write-Output "Branch: $branch"
Write-Output "GateReport: $gateReportPath"
Write-Output "GateReportSha256: $gateReportHash"
Write-Output "ProvenanceRoot: $($provenance[-1])"
Write-Output "RuntimeEvidence: NOT OBSERVED / NOT CLAIMED"
Write-Output "ReleaseEvidence: NOT OBSERVED / NOT CLAIMED"
Write-Output 'SoakPass: false'

if ($script:failures.Count -gt 0 -or $verdict -eq 'FAIL') {
    throw "Issue #42 soak-contract preparation gate FAILED: $($script:failures -join '; ')"
}

if ($verdict -eq 'PASS') {
    throw 'Issue #42 soak-contract gate illegally emitted PASS in preparation mode.'
}
