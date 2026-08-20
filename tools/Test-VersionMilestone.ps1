[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('v0.1.0', 'v0.2.0', 'v0.3.0', 'v0.4.0', 'v0.5.0', 'v0.6.0', 'v0.7.0', 'v1.0.0')]
    [string]$Version,

    [string]$Repository = 'OSHEThai/HerdrOps',

    [string]$GhExecutable = 'gh',

    [ValidateRange(1, 100)]
    [int]$GitHubPageSize = 100
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$paginationPolicyPath = Join-Path $PSScriptRoot 'GitHubPaginationPolicy.ps1'
if (-not (Test-Path -LiteralPath $paginationPolicyPath -PathType Leaf)) {
    throw "GitHub pagination policy is missing: $paginationPolicyPath"
}
. $paginationPolicyPath

function Read-GitHubJsonArrayPage {
    param(
        [Parameter(Mandatory)]
        [string]$Endpoint,

        [Parameter(Mandatory)]
        [string]$Executable
    )

    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $rawOutput = (& $Executable api $Endpoint 2>&1 | Out-String)
        $invocationSucceeded = $?
        $exitCode = if ([IO.Path]::GetExtension($Executable) -ieq '.ps1') {
            if ($invocationSucceeded) { 0 } else { 1 }
        }
        else {
            $LASTEXITCODE
        }
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }
    if ($exitCode -ne 0) {
        throw "Unable to query GitHub endpoint '$Endpoint' (exit $exitCode): $($rawOutput.Trim())"
    }

    $trimmed = $rawOutput.Trim()
    if (-not $trimmed.StartsWith('[', [StringComparison]::Ordinal) -or
        -not $trimmed.EndsWith(']', [StringComparison]::Ordinal)) {
        throw "GitHub endpoint '$Endpoint' did not return a JSON array."
    }
    $strictJsonValidator = Get-Command Assert-StrictJsonText -CommandType Function -ErrorAction Stop
    & $strictJsonValidator -Json $trimmed -SourceName "gh api $Endpoint"

    $parsed = $trimmed | ConvertFrom-Json
    $parsedItems = if ($null -eq $parsed) { @() } else { [object[]]$parsed }
    return [pscustomobject]@{
        Value = $parsedItems
        Raw = $trimmed
        Sha256 = Get-GitHubPaginationRawSha256 -Raw $trimmed
        Endpoint = $Endpoint
    }
}

$pageReader = {
    param(
        [string]$Endpoint,
        [string]$Executable
    )

    return Read-GitHubJsonArrayPage -Endpoint $Endpoint -Executable $Executable
}

$milestoneResponse = Read-BoundedGitHubJsonArrayPages `
    -BaseEndpoint "repos/$Repository/milestones?state=all&sort=due_on&direction=asc" `
    -PageSize $GitHubPageSize `
    -MaximumPages 100 `
    -PageReader $pageReader `
    -PageReaderArguments @($GhExecutable)
$issueResponse = Read-BoundedGitHubJsonArrayPages `
    -BaseEndpoint "repos/$Repository/issues?state=all&sort=created&direction=asc" `
    -PageSize $GitHubPageSize `
    -MaximumPages 100 `
    -PageReader $pageReader `
    -PageReaderArguments @($GhExecutable)

$milestones = @($milestoneResponse.Value)
$issues = @($issueResponse.Value)

$milestone = @($milestones | Where-Object { [string]$_.title -ceq $Version })
if ($milestone.Count -ne 1) {
    throw "Expected exactly one milestone named $Version; found $($milestone.Count)."
}

$selectedMilestoneNumber = [int]$milestone[0].number
$versionIssues = New-Object System.Collections.ArrayList
foreach ($issue in $issues) {
    if ($issue.PSObject.Properties.Name -contains 'pull_request') {
        continue
    }

    $issueMilestone = $issue.milestone
    if ($null -eq $issueMilestone) {
        continue
    }

    $issueMilestoneNumber = [int]$issueMilestone.number
    $issueMilestoneTitle = [string]$issueMilestone.title
    $declaredMilestone = @($milestones | Where-Object { [int]$_.number -eq $issueMilestoneNumber })
    if ($declaredMilestone.Count -ne 1 -or
        $issueMilestoneTitle -cne [string]$declaredMilestone[0].title) {
        throw "Issue #$($issue.number) has milestone '$issueMilestoneTitle'#$issueMilestoneNumber, which does not match the declared GitHub milestone number/title pair."
    }

    if ($issueMilestoneNumber -eq $selectedMilestoneNumber -or
        $issueMilestoneTitle -ceq $Version) {
        if ($issueMilestoneNumber -ne $selectedMilestoneNumber -or
            $issueMilestoneTitle -cne $Version) {
            throw "Issue #$($issue.number) has milestone '$issueMilestoneTitle'#$issueMilestoneNumber; expected '$Version'#$selectedMilestoneNumber."
        }
        [void]$versionIssues.Add($issue)
    }
}
$versionIssues = @($versionIssues.ToArray())
$openIssues = @($versionIssues | Where-Object state -eq 'open')

[pscustomobject]@{
    Repository = $Repository
    Version = $Version
    MilestoneState = $milestone[0].state
    TotalIssues = $versionIssues.Count
    OpenIssues = $openIssues.Count
    ClosedIssues = @($versionIssues | Where-Object state -eq 'closed').Count
    MilestoneQueryPages = $milestoneResponse.PageCount
    IssueQueryPages = $issueResponse.PageCount
}

if ($openIssues.Count -gt 0) {
    $openIssues | Sort-Object number | Select-Object number, title, html_url | Format-Table -AutoSize
    throw "$Version is not release-ready: $($openIssues.Count) issue(s) remain open."
}

if ($milestone[0].state -ne 'closed') {
    throw "$Version has no open issues but its milestone is still '$($milestone[0].state)'."
}

Write-Host "$Version milestone is closed with no open issues."

exit 0
