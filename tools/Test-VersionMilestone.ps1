[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('v0.1.0', 'v0.2.0', 'v0.3.0', 'v0.4.0', 'v0.5.0', 'v0.6.0', 'v0.7.0', 'v1.0.0')]
    [string]$Version,

    [string]$Repository = 'OSHEThai/HerdrOps'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$milestones = & gh api "repos/$Repository/milestones?state=all&per_page=100" | ConvertFrom-Json -Depth 50
if ($LASTEXITCODE -ne 0) { throw 'Unable to query GitHub milestones.' }

$milestone = @($milestones | Where-Object title -eq $Version)
if ($milestone.Count -ne 1) {
    throw "Expected exactly one milestone named $Version; found $($milestone.Count)."
}

$issues = & gh api "repos/$Repository/issues?state=all&per_page=100" | ConvertFrom-Json -Depth 50
if ($LASTEXITCODE -ne 0) { throw 'Unable to query GitHub issues.' }

$versionIssues = @($issues | Where-Object {
    -not ($_.PSObject.Properties.Name -contains 'pull_request') -and
    $null -ne $_.milestone -and
    $_.milestone.number -eq $milestone[0].number
})
$openIssues = @($versionIssues | Where-Object state -eq 'open')

[pscustomobject]@{
    Repository = $Repository
    Version = $Version
    MilestoneState = $milestone[0].state
    TotalIssues = $versionIssues.Count
    OpenIssues = $openIssues.Count
    ClosedIssues = @($versionIssues | Where-Object state -eq 'closed').Count
}

if ($openIssues.Count -gt 0) {
    $openIssues | Sort-Object number | Select-Object number, title, html_url | Format-Table -AutoSize
    throw "$Version is not release-ready: $($openIssues.Count) issue(s) remain open."
}

if ($milestone[0].state -ne 'closed') {
    throw "$Version has no open issues but its milestone is still '$($milestone[0].state)'."
}

Write-Host "$Version milestone is closed with no open issues."
