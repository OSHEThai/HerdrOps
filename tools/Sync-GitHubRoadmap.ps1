[CmdletBinding()]
param(
    [string]$Repository = 'OSHEThai/HerdrOps',
    [string]$ManifestPath = (Join-Path $PSScriptRoot '..\Plan\github-roadmap.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw 'GitHub CLI (gh) is required.'
}

if (-not (Test-Path -LiteralPath $ManifestPath)) {
    throw "Roadmap manifest was not found: $ManifestPath"
}

$manifest = Get-Content -Raw -LiteralPath $ManifestPath | ConvertFrom-Json -Depth 100
if ($manifest.schemaVersion -ne 1) {
    throw "Unsupported roadmap schema version: $($manifest.schemaVersion)"
}

if ($manifest.repository -ne $Repository) {
    throw "Manifest repository '$($manifest.repository)' does not match requested repository '$Repository'."
}

& gh auth status | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw 'GitHub CLI is not authenticated.'
}

function Invoke-GhJson {
    param(
        [Parameter(Mandatory)] [ValidateSet('POST', 'PATCH')] [string]$Method,
        [Parameter(Mandatory)] [string]$Endpoint,
        [Parameter(Mandatory)] [hashtable]$Payload
    )

    $json = $Payload | ConvertTo-Json -Depth 100 -Compress
    $raw = $json | & gh api --method $Method $Endpoint --input -
    if ($LASTEXITCODE -ne 0) {
        throw "GitHub API request failed: $Method $Endpoint"
    }

    return $raw | ConvertFrom-Json -Depth 100
}

function Get-GhJson {
    param([Parameter(Mandatory)] [string]$Endpoint)

    $raw = & gh api $Endpoint
    if ($LASTEXITCODE -ne 0) {
        throw "GitHub API request failed: GET $Endpoint"
    }

    return $raw | ConvertFrom-Json -Depth 100
}

function New-WorkIssueBody {
    param([Parameter(Mandatory)] $Issue)

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("<!-- herdr-issue-key: $($Issue.key) -->")
    $lines.Add('')
    $lines.Add('## Outcome')
    $lines.Add('')
    $lines.Add([string]$Issue.outcome)
    $lines.Add('')
    $lines.Add('## Scope')
    $lines.Add('')
    foreach ($item in $Issue.scope) { $lines.Add("- $item") }
    $lines.Add('')
    $lines.Add('## Acceptance criteria')
    $lines.Add('')
    foreach ($item in $Issue.acceptance) { $lines.Add("- [ ] $item") }
    $lines.Add('')
    $lines.Add('## Required evidence')
    $lines.Add('')
    foreach ($item in $Issue.evidence) { $lines.Add("- [ ] $item") }
    $lines.Add('')
    $lines.Add('## Evidence boundary')
    $lines.Add('')
    $lines.Add('Static, synthetic, contract, runtime, independent-review, and release evidence must be reported separately. Closing this issue without the required evidence does not pass the version gate.')
    return $lines -join "`n"
}

function New-TrackerBody {
    param(
        [Parameter(Mandatory)] $Milestone,
        [Parameter(Mandatory)] [hashtable]$IssueByKey
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("<!-- herdr-issue-key: $($Milestone.key)-TRACK -->")
    $lines.Add('')
    $lines.Add('## Release outcome')
    $lines.Add('')
    $lines.Add([string]$Milestone.outcome)
    $lines.Add('')
    $lines.Add('## Required work')
    $lines.Add('')
    foreach ($issue in $Milestone.issues) {
        $number = $IssueByKey[[string]$issue.key].number
        $lines.Add("- [ ] #$number")
    }
    $lines.Add('')
    $lines.Add('## Version-local release gates')
    $lines.Add('')
    foreach ($gate in $Milestone.releaseGates) { $lines.Add("- [ ] $gate") }
    $lines.Add('')
    $lines.Add('## Release rule')
    $lines.Add('')
    $lines.Add('Do not close this tracker, tag the version, or publish a release until every required issue is closed with matching evidence and every version-local gate is checked. Preparation for a later version does not complete this milestone.')
    return $lines -join "`n"
}

$labelDefinitions = @(
    @{ name = 'type:foundation'; color = '5319e7'; description = 'Architecture, contracts, and foundational work' },
    @{ name = 'type:feature'; color = '1d76db'; description = 'User-visible or operational feature' },
    @{ name = 'type:quality'; color = '0e8a16'; description = 'Testing, reliability, accessibility, or performance' },
    @{ name = 'type:release'; color = 'b60205'; description = 'Version gate and release work' },
    @{ name = 'area:app'; color = '0052cc'; description = 'Dashboard, tray, widget, and WPF UI' },
    @{ name = 'area:core'; color = '006b75'; description = 'Collector, IPC, event pipeline, and domain services' },
    @{ name = 'area:data'; color = 'c5def5'; description = 'SQLite, migrations, evidence, and retention' },
    @{ name = 'area:governance'; color = 'fbca04'; description = 'Assignment, compliance, evaluation, and review' },
    @{ name = 'area:tooling'; color = 'd4c5f9'; description = 'Build, verification, packaging, and developer tools' },
    @{ name = 'area:docs'; color = '0075ca'; description = 'Product, operator, and release documentation' },
    @{ name = 'evidence:runtime'; color = '7057ff'; description = 'Requires evidence from an actual running system' },
    @{ name = 'evidence:release'; color = 'b60205'; description = 'Requires exact packaged artifact evidence' },
    @{ name = 'priority:P0'; color = 'd93f0b'; description = 'Release-blocking priority' },
    @{ name = 'priority:P1'; color = 'fbca04'; description = 'Required milestone work' },
    @{ name = 'priority:P2'; color = '0e8a16'; description = 'Non-blocking improvement' }
)

$existingLabels = @(Get-GhJson "repos/$Repository/labels?per_page=100")
$existingLabelNames = @{}
foreach ($label in $existingLabels) { $existingLabelNames[[string]$label.name] = $true }

foreach ($label in $labelDefinitions) {
    if ($existingLabelNames.ContainsKey($label.name)) { continue }
    Invoke-GhJson -Method POST -Endpoint "repos/$Repository/labels" -Payload $label | Out-Null
    Write-Host "Created label $($label.name)"
}

$existingMilestones = @(Get-GhJson "repos/$Repository/milestones?state=all&per_page=100")
$milestoneByTitle = @{}
foreach ($milestone in $existingMilestones) { $milestoneByTitle[[string]$milestone.title] = $milestone }

foreach ($plannedMilestone in $manifest.milestones) {
    $title = [string]$plannedMilestone.title
    if (-not $milestoneByTitle.ContainsKey($title)) {
        $created = Invoke-GhJson -Method POST -Endpoint "repos/$Repository/milestones" -Payload @{
            title = $title
            description = [string]$plannedMilestone.description
        }
        $milestoneByTitle[$title] = $created
        Write-Host "Created milestone $title"
    }
}

$existingIssues = @(Get-GhJson "repos/$Repository/issues?state=all&per_page=100")
$issueByKey = @{}
foreach ($issue in $existingIssues) {
    if ($null -ne $issue.pull_request) { continue }
    if ([string]$issue.body -match '<!-- herdr-issue-key: ([A-Z0-9-]+) -->') {
        $issueByKey[$Matches[1]] = $issue
    }
}

foreach ($plannedMilestone in $manifest.milestones) {
    $milestoneNumber = [int]$milestoneByTitle[[string]$plannedMilestone.title].number

    foreach ($plannedIssue in $plannedMilestone.issues) {
        $key = [string]$plannedIssue.key
        if ($issueByKey.ContainsKey($key)) { continue }

        $created = Invoke-GhJson -Method POST -Endpoint "repos/$Repository/issues" -Payload @{
            title = [string]$plannedIssue.title
            body = New-WorkIssueBody -Issue $plannedIssue
            milestone = $milestoneNumber
            labels = @($plannedIssue.labels)
        }
        $issueByKey[$key] = $created
        Write-Host "Created issue #$($created.number) $key"
    }

    $trackerKey = "$($plannedMilestone.key)-TRACK"
    if (-not $issueByKey.ContainsKey($trackerKey)) {
        $tracker = Invoke-GhJson -Method POST -Endpoint "repos/$Repository/issues" -Payload @{
            title = "[$($plannedMilestone.title)] Release readiness tracker"
            body = New-TrackerBody -Milestone $plannedMilestone -IssueByKey $issueByKey
            milestone = $milestoneNumber
            labels = @('type:release', 'priority:P0')
        }
        $issueByKey[$trackerKey] = $tracker
        Write-Host "Created tracker #$($tracker.number) $trackerKey"
    }
}

$summary = foreach ($plannedMilestone in $manifest.milestones) {
    $trackerKey = "$($plannedMilestone.key)-TRACK"
    [pscustomobject]@{
        Version = [string]$plannedMilestone.title
        MilestoneNumber = [int]$milestoneByTitle[[string]$plannedMilestone.title].number
        WorkIssues = @($plannedMilestone.issues).Count
        TrackerIssue = [int]$issueByKey[$trackerKey].number
        TrackerUrl = [string]$issueByKey[$trackerKey].html_url
    }
}

$summary | Format-Table -AutoSize

