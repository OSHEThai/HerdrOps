[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\VersionMilestonePolicy.ps1')

function Assert-Equal {
    param($Expected, $Actual, [string]$Description)
    if ($Expected -ne $Actual) {
        throw "$Description expected '$Expected' but found '$Actual'."
    }
}

function ConvertTo-TestJsonArray {
    param([object[]]$Records)
    '[' + (@($Records | ForEach-Object { $_ | ConvertTo-Json -Depth 10 -Compress }) -join ',') + ']'
}

$requests = New-Object System.Collections.Generic.List[string]
$invoker = {
    param([string]$Endpoint)
    [void]$requests.Add($Endpoint)

    if ($Endpoint -like 'repos/example/project/milestones*') {
        $milestoneRecords = @([pscustomobject]@{ number = 2; title = 'v0.2.0'; state = 'open' })
        return [pscustomobject]@{
            ExitCode = 0
            Content = (ConvertTo-TestJsonArray -Records $milestoneRecords)
        }
    }

    $page = if ($Endpoint -match '[?&]page=(\d+)') { [int]$Matches[1] } else { 0 }
    if ($page -eq 1) {
        $records = for ($number = 200; $number -lt 300; $number++) {
            [pscustomobject]@{
                number = $number
                title = "unrelated-$number"
                state = 'closed'
                milestone = [pscustomobject]@{ number = 99 }
            }
        }
    }
    elseif ($page -eq 2) {
        $records = @(
            [pscustomobject]@{ number = 7; title = 'open v0.2 blocker'; state = 'open'; milestone = [pscustomobject]@{ number = 2 } },
            [pscustomobject]@{ number = 8; title = 'closed v0.2 work'; state = 'closed'; milestone = [pscustomobject]@{ number = 2 } },
            [pscustomobject]@{ number = 109; title = 'PR must be excluded'; state = 'open'; milestone = [pscustomobject]@{ number = 2 }; pull_request = [pscustomobject]@{} }
        )
    }
    else {
        throw "Unexpected page request '$Endpoint'."
    }

    [pscustomobject]@{ ExitCode = 0; Content = (ConvertTo-TestJsonArray -Records @($records)) }
}

$assessment = Get-VersionMilestoneAssessment -Version 'v0.2.0' -Repository 'example/project' -ApiInvoker $invoker
Assert-Equal 2 $assessment.TotalIssues 'Milestone issue total across pages'
Assert-Equal 1 $assessment.OpenIssues 'Open issue total across pages'
Assert-Equal 1 $assessment.ClosedIssues 'Closed issue total across pages'
Assert-Equal 7 $assessment.OpenIssueRecords[0].number 'Open issue identity from second page'
Assert-Equal 3 $requests.Count 'Milestone plus two issue page requests'

$badInvoker = { param([string]$Endpoint) [pscustomobject]@{ ExitCode = 1; Content = 'failure' } }
try {
    Get-GitHubPagedItems -Endpoint 'repos/example/project/issues?state=all' -ApiInvoker $badInvoker | Out-Null
    throw 'Expected a nonzero API exit code to fail closed.'
}
catch {
    if ($_.Exception.Message -notmatch 'exit code 1') { throw }
}

$invalidJsonInvoker = { param([string]$Endpoint) [pscustomobject]@{ ExitCode = 0; Content = '[invalid]' } }
try {
    Get-GitHubPagedItems -Endpoint 'repos/example/project/issues?state=all' -ApiInvoker $invalidJsonInvoker | Out-Null
    throw 'Expected invalid JSON to fail closed.'
}
catch {
    if ($_.Exception.Message -notmatch 'not valid JSON') { throw }
}

$objectRootInvoker = { param([string]$Endpoint) [pscustomobject]@{ ExitCode = 0; Content = '{"state":"open"}' } }
try {
    Get-GitHubPagedItems -Endpoint 'repos/example/project/issues?state=all' -ApiInvoker $objectRootInvoker | Out-Null
    throw 'Expected a non-array response to fail closed.'
}
catch {
    if ($_.Exception.Message -notmatch 'not a JSON array') { throw }
}

$emptyResponseInvoker = { param([string]$Endpoint) [pscustomobject]@{} }
try {
    Get-GitHubPagedItems -Endpoint 'repos/example/project/issues?state=all' -ApiInvoker $emptyResponseInvoker | Out-Null
    throw 'Expected a response without required properties to fail closed.'
}
catch {
    if ($_.Exception.Message -notmatch 'invalid response') { throw }
}

$duplicateMilestoneInvoker = {
    param([string]$Endpoint)
    $page = if ($Endpoint -match '[?&]page=(\d+)') { [int]$Matches[1] } else { 0 }
    if ($Endpoint -like 'repos/example/project/milestones*') {
        if ($page -eq 1) {
            $records = for ($number = 1; $number -le 100; $number++) {
                $title = if ($number -eq 2) { 'v0.2.0' } else { "v$number" }
                [pscustomobject]@{ number = $number; title = $title; state = 'open' }
            }
        }
        else {
            $records = @([pscustomobject]@{ number = 202; title = 'v0.2.0'; state = 'open' })
        }
    }
    else {
        $records = @()
    }
    [pscustomobject]@{ ExitCode = 0; Content = (ConvertTo-TestJsonArray -Records @($records)) }
}
try {
    Get-VersionMilestoneAssessment -Version 'v0.2.0' -Repository 'example/project' -ApiInvoker $duplicateMilestoneInvoker | Out-Null
    throw 'Expected duplicate milestones across full pages to fail closed.'
}
catch {
    if ($_.Exception.Message -notmatch 'exactly one milestone.*found 2') { throw }
}

Write-Host 'Test-VersionMilestone.Tests: PASS'
