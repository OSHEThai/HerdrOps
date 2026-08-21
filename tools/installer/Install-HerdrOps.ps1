#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ArchivePath,

    [Parameter(Mandatory = $false)]
    [string]$InstallRoot,

    [Parameter(Mandatory = $false)]
    [string]$UserDataRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Installer.Common.ps1')

try {
    Write-Host "Starting HerdrOps installation..."

    if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
        $InstallRoot = Get-DefaultHerdrOpsInstallRoot
    }
    if ([string]::IsNullOrWhiteSpace($UserDataRoot)) {
        $UserDataRoot = Get-DefaultHerdrOpsUserDataRoot
    }

    $fullArchivePath = Get-SafeInstallerPath -Path $ArchivePath
    $fullInstallRoot = Get-SafeInstallerPath -Path $InstallRoot
    $fullUserDataRoot = Get-SafeInstallerPath -Path $UserDataRoot

    if (-not (Test-Path -LiteralPath $fullArchivePath -PathType Leaf)) {
        throw "Archive path does not exist or is not a file: $fullArchivePath"
    }

    $runId = [Guid]::NewGuid().ToString('N')

    Write-Host "Invoking atomic install transition to $fullInstallRoot..."
    Invoke-AtomicInstallTransition `
        -ArchivePath $fullArchivePath `
        -InstallRoot $fullInstallRoot `
        -UserDataRoot $fullUserDataRoot `
        -RunId $runId

    Write-Host "Installation completed successfully."
} catch {
    Write-Error "HerdrOps installation failed: $($_.Exception.Message)"
    exit 1
}
