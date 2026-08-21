#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ArchivePath,

    [Parameter(Mandatory = $false)]
    [string]$InstallRoot = "$env:LOCALAPPDATA\Programs\HerdrOps",

    [Parameter(Mandatory = $false)]
    [string]$UserDataRoot = "$env:LOCALAPPDATA\HerdrOps"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Installer.Common.ps1')

try {
    Write-Host "Starting HerdrOps installation..."
    
    $fullArchivePath = Get-SafeInstallerPath -Path $ArchivePath
    $fullInstallRoot = Get-SafeInstallerPath -Path $InstallRoot
    $fullUserDataRoot = Get-SafeInstallerPath -Path $UserDataRoot

    if (-not (Test-Path -LiteralPath $fullArchivePath -PathType Leaf)) {
        throw "Archive path does not exist or is not a file: $fullArchivePath"
    }

    # explicit retained-user-data policy marker (e.g. creating user data root)
    if (-not (Test-Path -LiteralPath $fullUserDataRoot)) {
        New-Item -ItemType Directory -Path $fullUserDataRoot -Force | Out-Null
    }
    Assert-NoReparsePath -Path $fullUserDataRoot

    # Create retained data marker if needed
    $markerPath = Join-Path $fullUserDataRoot ".herdrops-retained-data"
    if (-not (Test-Path -LiteralPath $markerPath)) {
        Set-Content -LiteralPath $markerPath -Value "HerdrOps Retained User Data Policy Marker" -Encoding UTF8
    }

    $runId = [Guid]::NewGuid().ToString('N')

    Write-Host "Invoking atomic install transition to $fullInstallRoot..."
    Invoke-AtomicInstallTransition -ArchivePath $fullArchivePath -InstallRoot $fullInstallRoot -RunId $runId

    Write-Host "Installation completed successfully."
} catch {
    Write-Error "HerdrOps installation failed: $($_.Exception.Message)"
    exit 1
}
