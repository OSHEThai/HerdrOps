[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$buildScript = Join-Path $PSScriptRoot 'Invoke-Build.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $buildScript,
    [ref]$tokens,
    [ref]$parseErrors)

if ($parseErrors.Count -ne 0) {
    throw 'Invoke-Build.ps1 does not parse cleanly.'
}

$testCommands = @($ast.FindAll({
    param($node)

    if ($node -isnot [System.Management.Automation.Language.CommandAst] -or
        $node.GetCommandName() -cne 'dotnet' -or
        $node.CommandElements.Count -lt 2) {
        return $false
    }

    return $node.CommandElements[1].Extent.Text -ceq 'test'
}, $true))

if ($testCommands.Count -ne 1) {
    throw "Invoke-Build.ps1 must contain exactly one canonical dotnet test command; found $($testCommands.Count)."
}

$arguments = @($testCommands[0].CommandElements |
    Select-Object -Skip 2 |
    ForEach-Object { $_.Extent.Text })
$boundedSchedulers = @($arguments | Where-Object { $_ -cmatch '^(?:-m|--maxcpucount):1$' })

if ($boundedSchedulers.Count -ne 1) {
    throw 'The canonical solution test command must serialize project scheduling with exactly one -m:1 or --maxcpucount:1 argument.'
}

Write-Output 'Canonical solution test-project scheduling: PASS (max concurrency 1)'
