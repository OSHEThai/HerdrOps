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

$responses = @{
    'repos/example/milestones?state=all&sort=due_on&direction=asc&per_page=2&page=1' = '[{"number":1,"title":"v0.1.0","state":"closed"}]'
    'repos/example/issues?state=all&sort=created&direction=asc&per_page=2&page=1' = '[{"number":1,"title":"First","state":"closed","html_url":"https://example.invalid/1","milestone":{"number":1}},{"number":2,"title":"Second","state":"closed","html_url":"https://example.invalid/2","milestone":{"number":1}}]'
    'repos/example/issues?state=all&sort=created&direction=asc&per_page=2&page=2' = '[{"number":3,"title":"Third","state":"closed","html_url":"https://example.invalid/3","milestone":{"number":1}}]'
}

if (-not $responses.ContainsKey($Endpoint)) {
    throw "Unexpected fake GitHub endpoint: $Endpoint"
}

Write-Output $responses[$Endpoint]
exit 0
