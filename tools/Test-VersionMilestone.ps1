[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('v0.1.0', 'v0.2.0', 'v0.3.0', 'v0.4.0', 'v0.5.0', 'v0.6.0', 'v0.7.0', 'v1.0.0')]
    [string]$Version,

    [string]$Repository = 'OSHEThai/HerdrOps'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\VersionMilestonePolicy.ps1')

$apiInvoker = {
    param([string]$Endpoint)
    $content = @(& gh api $Endpoint 2>&1)
    [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Content = ($content -join [Environment]::NewLine)
    }
}

$assessment = Get-VersionMilestoneAssessment -Version $Version -Repository $Repository -ApiInvoker $apiInvoker
$assessment | Select-Object Repository, Version, MilestoneState, TotalIssues, OpenIssues, ClosedIssues

if ($assessment.OpenIssues -gt 0) {
    $assessment.OpenIssueRecords | Select-Object number, title, html_url | Format-Table -AutoSize
    throw "$Version is not release-ready: $($assessment.OpenIssues) issue(s) remain open."
}

if ($assessment.MilestoneState -ne 'closed') {
    throw "$Version has no open issues but its milestone is still '$($assessment.MilestoneState)'."
}

Write-Host "$Version milestone is closed with no open issues."
