Set-StrictMode -Version Latest

$strictJsonPolicyPath = Join-Path $PSScriptRoot 'StrictJsonPolicy.ps1'
if (-not (Test-Path -LiteralPath $strictJsonPolicyPath -PathType Leaf)) {
    throw "Strict JSON policy is missing: $strictJsonPolicyPath"
}
. $strictJsonPolicyPath

function Get-GitHubPaginationRawSha256 {
    param(
        [Parameter(Mandatory)]
        [string]$Raw
    )

    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Raw)
        return ([BitConverter]::ToString($algorithm.ComputeHash($bytes))).Replace('-', '').ToUpperInvariant()
    }
    finally {
        $algorithm.Dispose()
    }
}

function Read-BoundedGitHubJsonArrayPages {
    param(
        [Parameter(Mandatory)]
        [string]$BaseEndpoint,

        [Parameter(Mandatory)]
        [ValidateRange(1, 100)]
        [int]$PageSize,

        [Parameter(Mandatory)]
        [ValidateRange(1, 100)]
        [int]$MaximumPages,

        [Parameter(Mandatory)]
        [scriptblock]$PageReader,

        [object[]]$PageReaderArguments = @()
    )

    if ($BaseEndpoint -match '(?i)(?:^|[?&])(?:page|per_page)=') {
        throw 'The paged GitHub base endpoint must not predefine page or per_page.'
    }

    $items = New-Object System.Collections.ArrayList
    $endpoints = New-Object System.Collections.ArrayList
    $hashes = New-Object System.Collections.ArrayList
    $separator = if ($BaseEndpoint.Contains('?')) { '&' } else { '?' }

    for ($page = 1; $page -le $MaximumPages; $page++) {
        $endpoint = "${BaseEndpoint}${separator}per_page=${PageSize}&page=${page}"
        $response = & $PageReader $endpoint @PageReaderArguments
        if ($null -eq $response -or
            @($response.PSObject.Properties.Name) -notcontains 'Value' -or
            @($response.PSObject.Properties.Name) -notcontains 'Raw' -or
            @($response.PSObject.Properties.Name) -notcontains 'Sha256' -or
            @($response.PSObject.Properties.Name) -notcontains 'Endpoint') {
            throw "GitHub page reader returned an incomplete response for '$endpoint'."
        }

        $raw = [string]$response.Raw
        $trimmed = $raw.Trim()
        if (-not $trimmed.StartsWith('[', [StringComparison]::Ordinal) -or
            -not $trimmed.EndsWith(']', [StringComparison]::Ordinal)) {
            throw "GitHub paged endpoint did not return a JSON array: '$endpoint'."
        }
        $strictJsonValidator = Get-Command Assert-StrictJsonText -CommandType Function -ErrorAction Stop
        & $strictJsonValidator -Json $raw -SourceName "GitHub page '$endpoint'"

        $responseEndpoint = [string]$response.Endpoint
        if ($responseEndpoint -cne $endpoint) {
            throw "GitHub page reader endpoint mismatch: expected '$endpoint' observed '$responseEndpoint'."
        }
        $responseHash = [string]$response.Sha256
        $observedHash = Get-GitHubPaginationRawSha256 -Raw $raw
        if ($responseHash -notmatch '^[0-9a-fA-F]{64}$' -or
            $responseHash.ToUpperInvariant() -cne $observedHash) {
            throw "GitHub page reader SHA-256 mismatch for '$endpoint'."
        }

        $pageItems = @($response.Value)
        if ($pageItems.Count -gt $PageSize) {
            throw "GitHub paged endpoint returned $($pageItems.Count) items with page size ${PageSize}: '$endpoint'."
        }

        foreach ($item in $pageItems) {
            [void]$items.Add($item)
        }
        [void]$endpoints.Add($responseEndpoint)
        [void]$hashes.Add($observedHash)

        if ($pageItems.Count -lt $PageSize) {
            return [pscustomobject]@{
                Value = @($items.ToArray())
                Endpoint = @($endpoints.ToArray())
                Sha256 = @($hashes.ToArray())
                PageCount = $page
            }
        }
    }

    throw "GitHub pagination exceeded the bounded maximum of $MaximumPages pages for '$BaseEndpoint'."
}
