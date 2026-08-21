#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$InstallRoot,

    [Parameter(Mandatory = $false)]
    [string]$UserDataRoot,

    [Parameter(Mandatory = $false)]
    [switch]$RemoveUserData
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Installer.Common.ps1')

try {
    Write-Host "Starting HerdrOps uninstallation..."

    if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
        $InstallRoot = Get-DefaultHerdrOpsInstallRoot
    }
    if ([string]::IsNullOrWhiteSpace($UserDataRoot)) {
        $UserDataRoot = Get-DefaultHerdrOpsUserDataRoot
    }

    $fullInstallRoot = Get-SafeInstallerPath -Path $InstallRoot
    $fullUserDataRoot = Get-SafeInstallerPath -Path $UserDataRoot

    $runId = [Guid]::NewGuid().ToString('N')

    Write-Host "Invoking atomic uninstall transition from $fullInstallRoot..."
    Invoke-AtomicUninstallTransition -InstallRoot $fullInstallRoot -RunId $runId

    if ($RemoveUserData) {
        if (Test-Path -LiteralPath $fullUserDataRoot) {
            Write-Host "Removing user data from $fullUserDataRoot..."
            Remove-DirectoryTreeSafe -Path $fullUserDataRoot -Context "User data removal"
        }
    } else {
        Write-Host "Retained user data left intact at $fullUserDataRoot."
    }

    Write-Host "Uninstallation completed successfully."
} catch {
    Write-Error "HerdrOps uninstallation failed: $($_.Exception.Message)"
    exit 1
}
