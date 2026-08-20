[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Reconciled Issue #41 milestone verifier tests.
#
# The pre-#41 milestone verifier introduced a second pagination
# implementation in tools/lib/VersionMilestonePolicy.ps1
# (Get-GitHubPagedItems / Get-VersionMilestoneAssessment). The Issue #41
# verifier (tools/Test-VersionMilestone.ps1) supersedes it with the stricter
# bounded pagination in tools/GitHubPaginationPolicy.ps1
# (Read-BoundedGitHubJsonArrayPages), which binds every page endpoint and
# SHA-256, rejects non-strict JSON, rejects caller-supplied page parameters,
# fails closed on a full final page at the bounded limit, and validates every
# issue milestone number/title pair. The superseded duplicate policy has been
# removed; this suite validates the single surviving authoritative pagination
# implementation and the milestone assessment semantics of the merged
# verifier, which is its only consumer. No second pagination implementation
# remains.
# ---------------------------------------------------------------------------

$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$paginationPolicy = Join-Path $PSScriptRoot 'GitHubPaginationPolicy.ps1'
$milestoneVerifier = Join-Path $PSScriptRoot 'Test-VersionMilestone.ps1'
$fakeGhFixture = Join-Path $repositoryRoot 'tests\fixtures\v1.0\issue-41\fake-gh-multipage.ps1'
foreach ($path in @($paginationPolicy, $milestoneVerifier, $fakeGhFixture)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Issue #41 milestone test input is missing: $path"
    }
}
. $paginationPolicy

function Assert-Equal {
    param($Expected, $Actual, [string]$Description)
    if ($Expected -ne $Actual) {
        throw "$Description expected '$Expected' but found '$Actual'."
    }
}

function Assert-ThrowsMatching {
    param(
        [scriptblock]$Action,
        [string]$Pattern,
        [string]$Description
    )
    $threw = $false
    try {
        & $Action | Out-Null
    }
    catch {
        $threw = $true
        if ($Pattern -and $_.Exception.Message -notmatch $Pattern) {
            throw "$Description threw an unexpected message: $($_.Exception.Message)"
        }
    }
    if (-not $threw) {
        throw "$Description did not fail closed."
    }
}

function ConvertTo-TestJsonArray {
    param([object[]]$Records)
    '[' + (@($Records | ForEach-Object { $_ | ConvertTo-Json -Depth 10 -Compress }) -join ',') + ']'
}

# Mirror of the merged verifier's inline milestone assessment over the single
# surviving pagination policy. Kept in lockstep with tools/Test-VersionMilestone.ps1
# so the policy-level semantics (multi-page totals, PR exclusion, case-sensitive
# milestone identity, milestone number/title pair validation) are pinned here.
function Get-MilestoneAssessment {
    param(
        [Parameter(Mandatory)]
        [string]$Version,

        [Parameter(Mandatory)]
        [string]$Repository,

        [Parameter(Mandatory)]
        [scriptblock]$PageReader,

        [object[]]$PageReaderArguments = @(),

        [int]$PageSize = 100
    )

    $milestoneResponse = Read-BoundedGitHubJsonArrayPages `
        -BaseEndpoint "repos/$Repository/milestones?state=all&sort=due_on&direction=asc" `
        -PageSize $PageSize `
        -MaximumPages 100 `
        -PageReader $PageReader `
        -PageReaderArguments $PageReaderArguments
    $issueResponse = Read-BoundedGitHubJsonArrayPages `
        -BaseEndpoint "repos/$Repository/issues?state=all&sort=created&direction=asc" `
        -PageSize $PageSize `
        -MaximumPages 100 `
        -PageReader $PageReader `
        -PageReaderArguments $PageReaderArguments

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
        OpenIssueRecords = @($openIssues | Sort-Object number)
        MilestoneQueryPages = $milestoneResponse.PageCount
        IssueQueryPages = $issueResponse.PageCount
    }
}

# Deterministic multi-page reader used by the policy-level and assessment tests.
# It returns the exact raw text for each endpoint so the policy can bind the
# endpoint identity and SHA-256, exactly as the production reader does.
$multiPageReader = {
    param(
        [string]$Endpoint,
        [hashtable]$ResponseMap
    )
    if (-not $ResponseMap.ContainsKey($Endpoint)) {
        throw "Unexpected pagination endpoint: $Endpoint"
    }
    $raw = $ResponseMap[$Endpoint]
    $parsed = $raw | ConvertFrom-Json
    $parsedItems = if ($null -eq $parsed) { @() } else { [object[]]$parsed }
    return [pscustomobject]@{
        Value = $parsedItems
        Raw = $raw
        Sha256 = Get-GitHubPaginationRawSha256 -Raw $raw
        Endpoint = $Endpoint
    }
}

$milestonePageRaw = ConvertTo-TestJsonArray -Records @(
    [pscustomobject]@{ number = 2; title = 'v0.2.0'; state = 'open' },
    [pscustomobject]@{ number = 99; title = 'v99'; state = 'closed' }
)
$unrelatedPageRecords = for ($number = 200; $number -lt 300; $number++) {
    [pscustomobject]@{
        number = $number
        title = "unrelated-$number"
        state = 'closed'
        milestone = [pscustomobject]@{ number = 99; title = 'v99' }
    }
}
$versionPageRecords = @(
    [pscustomobject]@{ number = 7; title = 'open v0.2 blocker'; state = 'open'; milestone = [pscustomobject]@{ number = 2; title = 'v0.2.0' } },
    [pscustomobject]@{ number = 8; title = 'closed v0.2 work'; state = 'closed'; milestone = [pscustomobject]@{ number = 2; title = 'v0.2.0' } },
    [pscustomobject]@{ number = 109; title = 'PR must be excluded'; state = 'open'; milestone = [pscustomobject]@{ number = 2; title = 'v0.2.0' }; pull_request = [pscustomobject]@{} }
)

$assessment = Get-MilestoneAssessment `
    -Version 'v0.2.0' `
    -Repository 'example/project' `
    -PageReader $multiPageReader `
    -PageReaderArguments @(@{
        'repos/example/project/milestones?state=all&sort=due_on&direction=asc&per_page=100&page=1' = $milestonePageRaw
        'repos/example/project/issues?state=all&sort=created&direction=asc&per_page=100&page=1' = (ConvertTo-TestJsonArray -Records $unrelatedPageRecords)
        'repos/example/project/issues?state=all&sort=created&direction=asc&per_page=100&page=2' = (ConvertTo-TestJsonArray -Records $versionPageRecords)
    })
Assert-Equal 2 $assessment.TotalIssues 'Milestone issue total across pages'
Assert-Equal 1 $assessment.OpenIssues 'Open issue total across pages'
Assert-Equal 1 $assessment.ClosedIssues 'Closed issue total across pages'
Assert-Equal 7 $assessment.OpenIssueRecords[0].number 'Open issue identity from second page'
Assert-Equal 1 $assessment.MilestoneQueryPages 'Milestone query page count'
Assert-Equal 2 $assessment.IssueQueryPages 'Issue query page count'
if (@($assessment.OpenIssueRecords | Where-Object number -eq 109).Count -ne 0) {
    throw 'A pull request record leaked into the open issue set.'
}

# Duplicate milestones spread across full pages must fail closed.
$duplicateMilestoneRecords = for ($number = 1; $number -le 100; $number++) {
    $title = if ($number -eq 2) { 'v0.2.0' } else { "v$number" }
    [pscustomobject]@{ number = $number; title = $title; state = 'open' }
}
Assert-ThrowsMatching -Action {
    Get-MilestoneAssessment `
        -Version 'v0.2.0' `
        -Repository 'example/project' `
        -PageReader $multiPageReader `
        -PageReaderArguments @(@{
            'repos/example/project/milestones?state=all&sort=due_on&direction=asc&per_page=100&page=1' = (ConvertTo-TestJsonArray -Records $duplicateMilestoneRecords)
            'repos/example/project/milestones?state=all&sort=due_on&direction=asc&per_page=100&page=2' = (ConvertTo-TestJsonArray -Records @([pscustomobject]@{ number = 202; title = 'v0.2.0'; state = 'open' }))
            'repos/example/project/issues?state=all&sort=created&direction=asc&per_page=100&page=1' = '[]'
        })
} -Pattern 'exactly one milestone.*found 2' -Description 'Duplicate milestones across full pages'

# Milestone title matching is case-sensitive.
$caseMismatchRaw = ConvertTo-TestJsonArray -Records @(
    [pscustomobject]@{ number = 2; title = 'V0.2.0'; state = 'open' }
)
Assert-ThrowsMatching -Action {
    Get-MilestoneAssessment `
        -Version 'v0.2.0' `
        -Repository 'example/project' `
        -PageReader $multiPageReader `
        -PageReaderArguments @(@{
            'repos/example/project/milestones?state=all&sort=due_on&direction=asc&per_page=100&page=1' = $caseMismatchRaw
            'repos/example/project/issues?state=all&sort=created&direction=asc&per_page=100&page=1' = '[]'
            'repos/example/project/issues?state=all&sort=created&direction=asc&per_page=100&page=2' = '[]'
        })
} -Pattern 'Expected exactly one milestone named v0.2.0; found 0' -Description 'Case-mismatched milestone title'

# An issue milestone number/title pair that does not match the declared
# milestone must fail closed before any open/closed counting.
$pairMismatchRaw = ConvertTo-TestJsonArray -Records @(
    [pscustomobject]@{ number = 1; title = 'v0.2.0'; state = 'open'; milestone = [pscustomobject]@{ number = 1; title = 'v0.2.0' } },
    [pscustomobject]@{ number = 2; title = 'V0.2.0'; state = 'open'; milestone = [pscustomobject]@{ number = 2; title = 'V0.2.0' } }
)
Assert-ThrowsMatching -Action {
    Get-MilestoneAssessment `
        -Version 'v0.2.0' `
        -Repository 'example/project' `
        -PageReader $multiPageReader `
        -PageReaderArguments @(@{
            'repos/example/project/milestones?state=all&sort=due_on&direction=asc&per_page=100&page=1' = $milestonePageRaw
            'repos/example/project/issues?state=all&sort=created&direction=asc&per_page=100&page=1' = $pairMismatchRaw
        })
} -Pattern 'does not match the declared GitHub milestone number/title pair' -Description 'Issue milestone number/title pair mismatch'

# --- Fail-closed boundaries of the single surviving pagination policy. ---

$failureReader = {
    param([string]$Endpoint)
    throw "GitHub API request failed for '$Endpoint' with exit code 1."
}
Assert-ThrowsMatching -Action {
    Read-BoundedGitHubJsonArrayPages `
        -BaseEndpoint 'repos/example/project/issues?state=all&sort=created&direction=asc' `
        -PageSize 100 -MaximumPages 2 -PageReader $failureReader | Out-Null
} -Pattern 'exit code 1' -Description 'Nonzero GitHub API exit code'

$invalidJsonReader = {
    param(
        [string]$Endpoint,
        [string]$Raw
    )
    return [pscustomobject]@{
        Value = @()
        Raw = $Raw
        Sha256 = Get-GitHubPaginationRawSha256 -Raw $Raw
        Endpoint = $Endpoint
    }
}
foreach ($malformedJson in @('[{"number":01}]', '[{"number":1},]', '[/* comment */]')) {
    Assert-ThrowsMatching -Action {
        Read-BoundedGitHubJsonArrayPages `
            -BaseEndpoint 'repos/example/project/issues?state=all&sort=created&direction=asc' `
            -PageSize 100 -MaximumPages 2 -PageReader $invalidJsonReader `
            -PageReaderArguments @($malformedJson) | Out-Null
    } -Pattern 'JSON' -Description "Non-strict JSON input $malformedJson"
}

$nonArrayReader = {
    param([string]$Endpoint)
    return [pscustomobject]@{
        Value = @()
        Raw = '{"state":"open"}'
        Sha256 = Get-GitHubPaginationRawSha256 -Raw '{"state":"open"}'
        Endpoint = $Endpoint
    }
}
Assert-ThrowsMatching -Action {
    Read-BoundedGitHubJsonArrayPages `
        -BaseEndpoint 'repos/example/project/issues?state=all&sort=created&direction=asc' `
        -PageSize 100 -MaximumPages 2 -PageReader $nonArrayReader | Out-Null
} -Pattern 'did not return a JSON array' -Description 'Non-array GitHub response'

$incompleteReader = {
    param([string]$Endpoint)
    return [pscustomobject]@{ Value = @() }
}
Assert-ThrowsMatching -Action {
    Read-BoundedGitHubJsonArrayPages `
        -BaseEndpoint 'repos/example/project/issues?state=all&sort=created&direction=asc' `
        -PageSize 100 -MaximumPages 2 -PageReader $incompleteReader | Out-Null
} -Pattern 'incomplete response' -Description 'GitHub page reader response without required properties'

$nullReader = {
    param([string]$Endpoint)
    return $null
}
Assert-ThrowsMatching -Action {
    Read-BoundedGitHubJsonArrayPages `
        -BaseEndpoint 'repos/example/project/issues?state=all&sort=created&direction=asc' `
        -PageSize 100 -MaximumPages 2 -PageReader $nullReader | Out-Null
} -Pattern 'incomplete response' -Description 'GitHub page reader returning no response'

$wrongEndpointReader = {
    param([string]$Endpoint)
    $raw = '[]'
    return [pscustomobject]@{
        Value = @()
        Raw = $raw
        Sha256 = Get-GitHubPaginationRawSha256 -Raw $raw
        Endpoint = "$Endpoint-wrong"
    }
}
Assert-ThrowsMatching -Action {
    Read-BoundedGitHubJsonArrayPages `
        -BaseEndpoint 'repos/example/project/issues?state=all&sort=created&direction=asc' `
        -PageSize 100 -MaximumPages 2 -PageReader $wrongEndpointReader | Out-Null
} -Pattern 'endpoint mismatch' -Description 'Page reader endpoint identity mismatch'

$wrongHashReader = {
    param([string]$Endpoint)
    return [pscustomobject]@{
        Value = @()
        Raw = '[]'
        Sha256 = ('0' * 64)
        Endpoint = $Endpoint
    }
}
Assert-ThrowsMatching -Action {
    Read-BoundedGitHubJsonArrayPages `
        -BaseEndpoint 'repos/example/project/issues?state=all&sort=created&direction=asc' `
        -PageSize 100 -MaximumPages 2 -PageReader $wrongHashReader | Out-Null
} -Pattern 'SHA-256 mismatch' -Description 'Page reader SHA-256 identity mismatch'

Assert-ThrowsMatching -Action {
    Read-BoundedGitHubJsonArrayPages `
        -BaseEndpoint 'repos/example/project/issues?state=all&sort=created&direction=asc&page=1' `
        -PageSize 100 -MaximumPages 2 -PageReader $multiPageReader |
        Out-Null
} -Pattern 'must not predefine page or per_page' -Description 'Caller-supplied page parameter'

$fullPageReader = {
    param([string]$Endpoint)
    return [pscustomobject]@{
        Value = @([pscustomobject]@{ number = 1 })
        Raw = '[{"number":1}]'
        Sha256 = Get-GitHubPaginationRawSha256 -Raw '[{"number":1}]'
        Endpoint = $Endpoint
    }
}
Assert-ThrowsMatching -Action {
    Read-BoundedGitHubJsonArrayPages `
        -BaseEndpoint 'repos/example/project/issues?state=all&sort=created&direction=asc' `
        -PageSize 1 -MaximumPages 2 -PageReader $fullPageReader | Out-Null
} -Pattern 'exceeded the bounded maximum' -Description 'Full final page at the bounded page limit'

$overflowReader = {
    param([string]$Endpoint)
    $records = @([pscustomobject]@{ number = 1 }, [pscustomobject]@{ number = 2 })
    $raw = ConvertTo-TestJsonArray -Records $records
    return [pscustomobject]@{
        Value = $records
        Raw = $raw
        Sha256 = Get-GitHubPaginationRawSha256 -Raw $raw
        Endpoint = $Endpoint
    }
}
Assert-ThrowsMatching -Action {
    Read-BoundedGitHubJsonArrayPages `
        -BaseEndpoint 'repos/example/project/issues?state=all&sort=created&direction=asc' `
        -PageSize 1 -MaximumPages 2 -PageReader $overflowReader | Out-Null
} -Pattern 'returned 2 items with page size 1' -Description 'Page larger than the configured page size'

# --- Real merged verifier smoke contract via the deterministic fake gh CLI. ---
# The verifier ends with an explicit exit 0 and fails closed on parity negatives;
# run it as a child process because its exit statement terminates the session.
$shells = New-Object System.Collections.ArrayList
foreach ($candidate in @('powershell', 'pwsh')) {
    $command = Get-Command $candidate -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        [void]$shells.Add([pscustomobject]@{ Name = $candidate; Path = $command.Source })
    }
}
if ($shells.Count -eq 0) {
    throw 'Neither powershell.exe nor pwsh.exe is available for the Issue #41 milestone verifier smoke tests.'
}

foreach ($shell in $shells) {
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $smokeOutput = @(& $shell.Path `
                -NoProfile `
                -NonInteractive `
                -ExecutionPolicy Bypass `
                -File $milestoneVerifier `
                -Version 'v0.1.0' `
                -Repository 'example' `
                -GhExecutable $fakeGhFixture `
                -GitHubPageSize 2 2>&1 | ForEach-Object { [string]$_ })
        $smokeExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }
    if ($smokeExitCode -ne 0) {
        throw "$($shell.Name) merged milestone verifier smoke run failed (exit $smokeExitCode): $($smokeOutput -join '; ')"
    }

    foreach ($mode in @('MILESTONE_CASE_MISMATCH', 'ISSUE_MILESTONE_TITLE_MISMATCH')) {
        $oldMode = $env:HERDR_OPS_ISSUE41_FAKE_GH_MODE
        $env:HERDR_OPS_ISSUE41_FAKE_GH_MODE = $mode
        try {
            $previousPreference = $ErrorActionPreference
            try {
                $ErrorActionPreference = 'Continue'
                $negativeOutput = @(& $shell.Path `
                        -NoProfile `
                        -NonInteractive `
                        -ExecutionPolicy Bypass `
                        -File $milestoneVerifier `
                        -Version 'v0.1.0' `
                        -Repository 'example' `
                        -GhExecutable $fakeGhFixture `
                        -GitHubPageSize 2 2>&1 | ForEach-Object { [string]$_ })
                $negativeExitCode = $LASTEXITCODE
            }
            finally {
                $ErrorActionPreference = $previousPreference
            }
        }
        finally {
            if ($null -eq $oldMode) { Remove-Item Env:HERDR_OPS_ISSUE41_FAKE_GH_MODE -ErrorAction SilentlyContinue }
            else { $env:HERDR_OPS_ISSUE41_FAKE_GH_MODE = $oldMode }
        }
        if ($negativeExitCode -eq 0) {
            throw "$($shell.Name) merged milestone verifier accepted parity negative '$mode' (exit 0)."
        }
    }
}

Write-Host 'Test-VersionMilestone.Tests: PASS'
exit 0
