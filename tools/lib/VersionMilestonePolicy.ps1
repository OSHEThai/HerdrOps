Set-StrictMode -Version Latest

function Get-GitHubPagedItems {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Endpoint,

        [Parameter(Mandatory)]
        [scriptblock]$ApiInvoker,

        [ValidateRange(1, 1000)]
        [int]$PerPage = 100,

        [ValidateRange(1, 10000)]
        [int]$MaximumPages = 1000
    )

    $items = @()
    $separator = if ($Endpoint.Contains('?')) { '&' } else { '?' }

    for ($page = 1; $page -le $MaximumPages; $page++) {
        $request = '{0}{1}per_page={2}&page={3}' -f $Endpoint, $separator, $PerPage, $page
        $response = & $ApiInvoker $request
        if ($null -eq $response -or
            $response.PSObject.Properties.Name -notcontains 'ExitCode' -or
            $response.PSObject.Properties.Name -notcontains 'Content') {
            throw "GitHub API invoker returned an invalid response for '$request'."
        }
        if ([int]$response.ExitCode -ne 0) {
            throw "GitHub API request failed for '$request' with exit code $($response.ExitCode)."
        }

        $jsonText = ([string]$response.Content).Trim()
        if (-not $jsonText.StartsWith('[') -or -not $jsonText.EndsWith(']')) {
            $previewLength = [Math]::Min(40, $jsonText.Length)
            $preview = if ($previewLength -gt 0) { $jsonText.Substring(0, $previewLength) } else { '<empty>' }
            throw "GitHub API response for '$request' was not a JSON array (length $($jsonText.Length), prefix '$preview')."
        }

        try {
            $pageItems = @(($jsonText | ConvertFrom-Json))
        }
        catch {
            throw "GitHub API response for '$request' was not valid JSON: $($_.Exception.Message)"
        }

        foreach ($item in $pageItems) {
            if ($null -ne $item) {
                $items += $item
            }
        }

        if ($pageItems.Count -lt $PerPage) {
            return $items
        }
    }

    throw "GitHub API pagination exceeded the fail-closed limit of $MaximumPages pages for '$Endpoint'."
}

function Get-VersionMilestoneAssessment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Version,

        [Parameter(Mandatory)]
        [string]$Repository,

        [Parameter(Mandatory)]
        [scriptblock]$ApiInvoker
    )

    $milestones = @(Get-GitHubPagedItems -Endpoint "repos/$Repository/milestones?state=all" -ApiInvoker $ApiInvoker)
    $milestone = @($milestones | Where-Object title -eq $Version)
    if ($milestone.Count -ne 1) {
        throw "Expected exactly one milestone named $Version; found $($milestone.Count)."
    }

    $issues = @(Get-GitHubPagedItems -Endpoint "repos/$Repository/issues?state=all" -ApiInvoker $ApiInvoker)
    $versionIssues = @($issues | Where-Object {
        $_.PSObject.Properties.Name -notcontains 'pull_request' -and
        $null -ne $_.milestone -and
        $_.milestone.number -eq $milestone[0].number
    })
    $openIssues = @($versionIssues | Where-Object state -eq 'open')

    [pscustomobject]@{
        Repository = $Repository
        Version = $Version
        MilestoneState = [string]$milestone[0].state
        TotalIssues = $versionIssues.Count
        OpenIssues = $openIssues.Count
        ClosedIssues = @($versionIssues | Where-Object state -eq 'closed').Count
        OpenIssueRecords = @($openIssues | Sort-Object number)
    }
}
