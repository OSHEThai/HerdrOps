[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Command,

    [Parameter(Position = 1)]
    [string]$Endpoint
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Command -cne 'api') {
    throw "Unexpected fake GitHub command: $Command"
}

$mode = [string]$env:HERDR_OPS_ISSUE41_FAKE_GH_MODE
$issueTwoMilestoneTitle = if ($mode -ceq 'ISSUE_MILESTONE_TITLE_MISMATCH') { 'V0.1.0' } else { 'v0.1.0' }
$milestoneTitle = if ($mode -ceq 'MILESTONE_CASE_MISMATCH') { 'V0.1.0' } else { 'v0.1.0' }

$responses = @{
    'repos/example/milestones?state=all&sort=due_on&direction=asc&per_page=2&page=1' = '[{"number":1,"title":"' + $milestoneTitle + '","state":"closed"}]'
    'repos/example/issues?state=all&sort=created&direction=asc&per_page=2&page=1' = '[{"number":1,"title":"First","state":"closed","html_url":"https://example.invalid/1","milestone":{"number":1,"title":"v0.1.0"}},{"number":2,"title":"Second","state":"closed","html_url":"https://example.invalid/2","milestone":{"number":1,"title":"' + $issueTwoMilestoneTitle + '"}}]'
    'repos/example/issues?state=all&sort=created&direction=asc&per_page=2&page=2' = '[{"number":3,"title":"Third","state":"closed","html_url":"https://example.invalid/3","milestone":{"number":1,"title":"v0.1.0"}}]'
}

if ($mode -notin @('', 'MILESTONE_CASE_MISMATCH', 'ISSUE_MILESTONE_TITLE_MISMATCH')) {
    throw "Unexpected Issue #41 fake GitHub mode: $mode"
}

if (-not $responses.ContainsKey($Endpoint)) {
    throw "Unexpected fake GitHub endpoint: $Endpoint"
}

Write-Output $responses[$Endpoint]
exit 0
