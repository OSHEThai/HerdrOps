[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-StrictJsonText {
    param([string]$Json, [string]$SourceName)
    # Deliberately permissive ambient function. The production policy must replace it.
}

. (Join-Path $PSScriptRoot 'GitHubPaginationPolicy.ps1')

$responses = @{
    'repos/example/issues?state=all&sort=created&direction=asc&per_page=2&page=1' = [pscustomobject]@{
        Value = @([pscustomobject]@{ number = 1 }, [pscustomobject]@{ number = 2 })
        Raw = '[{"number":1},{"number":2}]'
        Sha256 = Get-GitHubPaginationRawSha256 -Raw '[{"number":1},{"number":2}]'
        Endpoint = 'repos/example/issues?state=all&sort=created&direction=asc&per_page=2&page=1'
    }
    'repos/example/issues?state=all&sort=created&direction=asc&per_page=2&page=2' = [pscustomobject]@{
        Value = @([pscustomobject]@{ number = 3 })
        Raw = '[{"number":3}]'
        Sha256 = Get-GitHubPaginationRawSha256 -Raw '[{"number":3}]'
        Endpoint = 'repos/example/issues?state=all&sort=created&direction=asc&per_page=2&page=2'
    }
}
$reader = {
    param(
        [string]$Endpoint,
        [hashtable]$ResponseMap
    )
    if (-not $ResponseMap.ContainsKey($Endpoint)) {
        throw "Unexpected pagination endpoint: $Endpoint"
    }
    return $ResponseMap[$Endpoint]
}

$result = Read-BoundedGitHubJsonArrayPages `
    -BaseEndpoint 'repos/example/issues?state=all&sort=created&direction=asc' `
    -PageSize 2 `
    -MaximumPages 3 `
    -PageReader $reader `
    -PageReaderArguments @($responses)
if (@($result.Value).Count -ne 3 -or
    @($result.Endpoint).Count -ne 2 -or
    @($result.Sha256).Count -ne 2 -or
    $result.PageCount -ne 2 -or
    @($result.Endpoint)[0] -cne 'repos/example/issues?state=all&sort=created&direction=asc&per_page=2&page=1' -or
    @($result.Endpoint)[1] -cne 'repos/example/issues?state=all&sort=created&direction=asc&per_page=2&page=2' -or
    @($result.Sha256)[0] -cne (Get-GitHubPaginationRawSha256 -Raw '[{"number":1},{"number":2}]') -or
    @($result.Sha256)[1] -cne (Get-GitHubPaginationRawSha256 -Raw '[{"number":3}]') -or
    @($result.Value)[0].number -ne 1 -or
    @($result.Value)[2].number -ne 3) {
    throw 'Issue #41 pagination fixture did not preserve every ordered page and response identity.'
}

$fullPageReader = {
    param([string]$Endpoint)
    return [pscustomobject]@{
        Value = @([pscustomobject]@{ number = 1 })
        Raw = '[{"number":1}]'
        Sha256 = Get-GitHubPaginationRawSha256 -Raw '[{"number":1}]'
        Endpoint = $Endpoint
    }
}
try {
    Read-BoundedGitHubJsonArrayPages `
        -BaseEndpoint 'repos/example/issues?state=all' `
        -PageSize 1 `
        -MaximumPages 2 `
        -PageReader $fullPageReader | Out-Null
    throw 'Issue #41 pagination fixture accepted an unbounded full final page.'
}
catch {
    if ($_.Exception.Message -notlike '*exceeded the bounded maximum*') {
        throw
    }
}

try {
    Read-BoundedGitHubJsonArrayPages `
        -BaseEndpoint 'repos/example/issues?state=all&page=1' `
        -PageSize 100 `
        -MaximumPages 2 `
        -PageReader $reader | Out-Null
    throw 'Issue #41 pagination fixture accepted a caller-supplied page parameter.'
}
catch {
    if ($_.Exception.Message -notlike '*must not predefine page or per_page*') {
        throw
    }
}

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
$acceptedWrongEndpoint = $false
try {
    Read-BoundedGitHubJsonArrayPages `
        -BaseEndpoint 'repos/example/issues?state=all' `
        -PageSize 2 `
        -MaximumPages 2 `
        -PageReader $wrongEndpointReader | Out-Null
    $acceptedWrongEndpoint = $true
}
catch {}
if ($acceptedWrongEndpoint) {
    throw 'Issue #41 pagination fixture accepted callback metadata for the wrong endpoint.'
}

$wrongHashReader = {
    param([string]$Endpoint)
    return [pscustomobject]@{
        Value = @()
        Raw = '[]'
        Sha256 = ('0' * 64)
        Endpoint = $Endpoint
    }
}
$acceptedWrongHash = $false
try {
    Read-BoundedGitHubJsonArrayPages `
        -BaseEndpoint 'repos/example/issues?state=all' `
        -PageSize 2 `
        -MaximumPages 2 `
        -PageReader $wrongHashReader | Out-Null
    $acceptedWrongHash = $true
}
catch {}
if ($acceptedWrongHash) {
    throw 'Issue #41 pagination fixture accepted a callback SHA-256 unrelated to the raw response.'
}

$malformedReader = {
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
foreach ($malformedJson in @(
        '[{"number":01}]',
        '[{"number":1},]',
        '[/* comment */]'
    )) {
    $acceptedMalformedJson = $false
    try {
        Read-BoundedGitHubJsonArrayPages `
            -BaseEndpoint 'repos/example/issues?state=all' `
            -PageSize 2 `
            -MaximumPages 2 `
            -PageReader $malformedReader `
            -PageReaderArguments @($malformedJson) | Out-Null
        $acceptedMalformedJson = $true
    }
    catch {}
    if ($acceptedMalformedJson) {
        throw "Issue #41 pagination fixture accepted non-strict JSON: $malformedJson"
    }
}

Write-Output 'Issue #41 bounded pagination fixtures: PASS'
