[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'GitHubPaginationPolicy.ps1')

$responses = @{
    'repos/example/issues?state=all&sort=created&direction=asc&per_page=2&page=1' = [pscustomobject]@{
        Value = @([pscustomobject]@{ number = 1 }, [pscustomobject]@{ number = 2 })
        Raw = '[{"number":1},{"number":2}]'
        Sha256 = ('A' * 64)
        Endpoint = 'repos/example/issues?state=all&sort=created&direction=asc&per_page=2&page=1'
    }
    'repos/example/issues?state=all&sort=created&direction=asc&per_page=2&page=2' = [pscustomobject]@{
        Value = @([pscustomobject]@{ number = 3 })
        Raw = '[{"number":3}]'
        Sha256 = ('B' * 64)
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
    @($result.Value)[0].number -ne 1 -or
    @($result.Value)[2].number -ne 3) {
    throw 'Issue #41 pagination fixture did not preserve every ordered page and response identity.'
}

$fullPageReader = {
    param([string]$Endpoint)
    return [pscustomobject]@{
        Value = @([pscustomobject]@{ number = 1 })
        Raw = '[{"number":1}]'
        Sha256 = ('C' * 64)
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

Write-Output 'Issue #41 bounded pagination fixtures: PASS'
