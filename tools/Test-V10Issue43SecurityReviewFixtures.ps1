[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Issue43SecurityReviewPolicy.ps1')

if (-not (Test-Issue43ScannerFixtures)) {
    throw 'Issue #43 security-review scanner fixtures failed.'
}

Write-Output 'Issue #43 security-review scanner fixtures: PASS'
