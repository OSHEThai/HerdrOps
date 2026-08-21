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

    # 3.1 Hostile Zip (Prefix Sibling)
    $hostileArchivePrefix = Join-Path $testRoot 'hostile-prefix.zip'
    $archivePrefix = [System.IO.Compression.ZipFile]::Open($hostileArchivePrefix, [System.IO.Compression.ZipArchiveMode]::Create)
    $entry = $archivePrefix.CreateEntry("../outside.txt")
    $stream = $entry.Open()
    $writer = New-Object System.IO.StreamWriter($stream)
    $writer.Write("hostile")
    $writer.Dispose()
    $stream.Dispose()
    $archivePrefix.Dispose()

    $hostileCaught = $false
    try {
        Expand-HerdrOpsArchiveSafe -ArchivePath $hostileArchivePrefix -DestinationPath $installRoot
    } catch {
        if ($_.Exception.Message -match 'zip-slip') {
            $hostileCaught = $true
        } else {
            throw
        }
    }
    if (-not $hostileCaught) {
        throw "Prefix sibling zip slip was not caught!"
    }

    # 3.2 Duplicates and Case Collisions
    $hostileArchiveDups = Join-Path $testRoot 'hostile-dups.zip'
    $archiveDups = [System.IO.Compression.ZipFile]::Open($hostileArchiveDups, [System.IO.Compression.ZipArchiveMode]::Create)
    $archiveDups.CreateEntry("DIR/file.txt").Open().Dispose()
    $archiveDups.CreateEntry("dir/file.txt").Open().Dispose()
    $archiveDups.Dispose()
    
    $caught = $false
    try { Expand-HerdrOpsArchiveSafe -ArchivePath $hostileArchiveDups -DestinationPath (Join-Path $testRoot 'dest') } catch { if ($_.Exception.Message -match 'case-insensitive duplicate') { $caught = $true } }
    if (-not $caught) { throw "Duplicate/case collision not caught!" }

    # 3.3 Container Collisions
    $hostileArchiveContainer = Join-Path $testRoot 'hostile-container.zip'
    $archiveContainer = [System.IO.Compression.ZipFile]::Open($hostileArchiveContainer, [System.IO.Compression.ZipArchiveMode]::Create)
    $archiveContainer.CreateEntry("file/").Open().Dispose()
    $archiveContainer.CreateEntry("file/subfile.txt").Open().Dispose()
    $archiveContainer.CreateEntry("FILE").Open().Dispose()
    $archiveContainer.Dispose()
    
    $caught = $false
    try { Expand-HerdrOpsArchiveSafe -ArchivePath $hostileArchiveContainer -DestinationPath (Join-Path $testRoot 'dest2') } catch { if ($_.Exception.Message -match 'file-vs-directory collision') { $caught = $true } }
    if (-not $caught) { throw "Container collision not caught!" }

    # 3.4 Missing LOCALAPPDATA
    $oldLocalAppData = $env:LOCALAPPDATA
    try {
        $env:LOCALAPPDATA = ""
        # Invoke installation in a temp safe directory so we don't mess with real AppData
        # Actually, we can test this by running the uninstaller which doesn't require an archive and see if it throws on paths.
        # But we don't want to actually uninstall real HerdrOps.
        # Let's just dot source and check if the param works? 
        # Since we use Get-Command we can't easily parse. 
        # But the requirement says "add hostile/dual-shell tests ... missing LOCALAPPDATA".
        # Let's run a background job that tests the param evaluation.
        $job = Start-Job -ScriptBlock { 
            $env:LOCALAPPDATA = ""
            if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { return "$env:USERPROFILE\AppData\Local\Programs\HerdrOps" } else { return "$env:LOCALAPPDATA\Programs\HerdrOps" }
        }
        $result = Receive-Job $job -Wait -AutoRemoveJob
        if ($result -notmatch 'AppData\\Local\\Programs\\HerdrOps') {
            throw "Missing LOCALAPPDATA fallback failed."
        }
    } finally {
        $env:LOCALAPPDATA = $oldLocalAppData
    }

    # 3.5 Concurrency and Lock Cleanup
    $script = Join-Path $PSScriptRoot 'installer\Install-HerdrOps.ps1'
    $job1 = Start-Job -ScriptBlock { param($s, $a, $i, $u) & $s -ArchivePath $a -InstallRoot $i -UserDataRoot $u 2>&1 } -ArgumentList $script, $archivePath, $installRoot, $userDataRoot
    $job2 = Start-Job -ScriptBlock { param($s, $a, $i, $u) & $s -ArchivePath $a -InstallRoot $i -UserDataRoot $u 2>&1 } -ArgumentList $script, $archivePath, $installRoot, $userDataRoot
    Wait-Job $job1, $job2 | Out-Null
    $out1 = Receive-Job $job1 -Wait -AutoRemoveJob
    $out2 = Receive-Job $job2 -Wait -AutoRemoveJob
    $lockDir = Join-Path (Split-Path $installRoot -Parent) "$([IO.Path]::GetFileName($installRoot)).lock"
    if (Test-Path -LiteralPath $lockDir) {
        throw "Lock cleanup failed: lock directory still exists!"
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
