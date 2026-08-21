#requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'installer\Installer.Common.ps1')

$testRoot = Join-Path $env:TEMP "HerdrOps.InstallerTest.$([Guid]::NewGuid().ToString('N'))"
$archivePath = Join-Path $testRoot 'test-package.zip'
$installRoot = Join-Path $testRoot 'Install'
$userDataRoot = Join-Path $testRoot 'UserData'

try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    
    # 1. Create a dummy package
    $packageSource = Join-Path $testRoot 'Source'
    New-Item -ItemType Directory -Path $packageSource -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $packageSource 'file1.txt') -Value "test1"
    Set-Content -LiteralPath (Join-Path $packageSource 'file2.txt') -Value "test2"
    
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::CreateFromDirectory($packageSource, $archivePath)

    # 2. Test Install (Positive)
    & (Join-Path $PSScriptRoot 'installer\Install-HerdrOps.ps1') -ArchivePath $archivePath -InstallRoot $installRoot -UserDataRoot $userDataRoot
    if (-not $?) {
        throw "Install-HerdrOps.ps1 failed."
    }

    if (-not (Test-Path -LiteralPath (Join-Path $installRoot 'file1.txt'))) {
        throw "Install failed: file1.txt not found."
    }
    if (-not (Test-Path -LiteralPath (Join-Path $userDataRoot '.herdrops-retained-data'))) {
        throw "Install failed: user data marker not found."
    }

    # 3. Test Hostile Zip (Zip Slip)
    $hostileArchive = Join-Path $testRoot 'hostile.zip'
    $archive = [System.IO.Compression.ZipFile]::Open($hostileArchive, [System.IO.Compression.ZipArchiveMode]::Create)
    # create entry with ../
    $entry = $archive.CreateEntry("../outside.txt")
    $stream = $entry.Open()
    $writer = New-Object System.IO.StreamWriter($stream)
    $writer.Write("hostile")
    $writer.Dispose()
    $stream.Dispose()
    $archive.Dispose()

    $hostileCaught = $false
    try {
        & (Join-Path $PSScriptRoot 'installer\Install-HerdrOps.ps1') -ArchivePath $hostileArchive -InstallRoot $installRoot -UserDataRoot $userDataRoot
    } catch {
        if ($_.Exception.Message -match 'zip-slip') {
            $hostileCaught = $true
        } else {
            throw
        }
    }
    if (-not $hostileCaught) {
        throw "Hostile zip slip was not caught!"
    }

    # 4. Test Uninstall (Positive)
    & (Join-Path $PSScriptRoot 'installer\Uninstall-HerdrOps.ps1') -InstallRoot $installRoot -UserDataRoot $userDataRoot

    if (Test-Path -LiteralPath $installRoot) {
        throw "Uninstall failed: install root still exists."
    }
    if (-not (Test-Path -LiteralPath $userDataRoot)) {
        throw "Uninstall failed: user data root was unexpectedly removed."
    }

    # 5. Test Uninstall with RemoveUserData
    # first install again
    & (Join-Path $PSScriptRoot 'installer\Install-HerdrOps.ps1') -ArchivePath $archivePath -InstallRoot $installRoot -UserDataRoot $userDataRoot
    
    & (Join-Path $PSScriptRoot 'installer\Uninstall-HerdrOps.ps1') -InstallRoot $installRoot -UserDataRoot $userDataRoot -RemoveUserData

    if (Test-Path -LiteralPath $installRoot) {
        throw "Uninstall failed: install root still exists."
    }
    if (Test-Path -LiteralPath $userDataRoot) {
        throw "Uninstall failed: user data root still exists after -RemoveUserData."
    }

    Write-Host "All installer tests passed."

} finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
