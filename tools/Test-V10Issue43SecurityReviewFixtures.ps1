[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Issue43SecurityReviewPolicy.ps1')

if (-not (Test-Issue43BranchIdentityFixtures)) {
    throw 'Issue #43 branch identity fixtures failed.'
}
if (-not (Test-Issue43ScannerFixtures)) {
    throw 'Issue #43 security-review scanner fixtures failed.'
}
if (-not (Test-Issue43ProcessFixtures)) {
    throw 'Issue #43 security-review process fixtures failed.'
}
if (-not (Test-Issue43ReportWriterFixtures)) {
    throw 'Issue #43 security-review report-writer fixtures failed.'
}

Write-Output 'Issue #43 security-review scanner, process, and report-writer fixtures: PASS'
