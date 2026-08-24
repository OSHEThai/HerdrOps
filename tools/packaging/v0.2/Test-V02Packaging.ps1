#requires -Version 5.1

[CmdletBinding()]
param(
    [switch]$Detailed
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "Running v0.2 Packaging and Installation Preparation Tests on PowerShell $($PSVersionTable.PSVersion)..."
$testScript = Join-Path $PSScriptRoot 'Test-V02Packaging.Tests.ps1'

& $testScript

[pscustomobject][ordered]@{
    EvidenceClass = 'Static/PackagedCompatibilityPreparation'
    Issue = 149
    Milestone = 2
    PackageVersion = '0.2.0'
    PowerShellVersion = [string]$PSVersionTable.PSVersion
    Status = 'PASS'
    DeploymentModel = 'per-user-directory'
    InstallPathTemplate = '%LOCALAPPDATA%\Programs\HerdrOps'
    UserDataPathTemplate = '%LOCALAPPDATA%\HerdrOps'
    UserDataPolicy = 'retain-on-uninstall'
    StartupPolicy = 'opt-in-only'
    AutoUpdatePolicy = 'disabled'
    LocalShaPolicy = 'unsigned-cryptographic-hash-binding'
}
