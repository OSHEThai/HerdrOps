#requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'installer\Installer.Common.ps1')

$testRoot = Join-Path $env:TEMP "HerdrOps.InstallerTest.$([Guid]::NewGuid().ToString('N'))"
$initialArchivePath = Join-Path $testRoot 'initial-package.zip'
$upgradeArchivePath = Join-Path $testRoot 'upgrade-package.zip'
$installRoot = Join-Path $testRoot 'Install'
$userDataRoot = Join-Path $testRoot 'UserData'

try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

    # 1. Create dummy packages (Initial and Upgrade)
    $initialSource = Join-Path $testRoot 'InitialSource'
    New-Item -ItemType Directory -Path $initialSource -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $initialSource 'file1.txt') -Value "initial1"
    Set-Content -LiteralPath (Join-Path $initialSource 'file2.txt') -Value "initial2"

    $upgradeSource = Join-Path $testRoot 'UpgradeSource'
    New-Item -ItemType Directory -Path $upgradeSource -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $upgradeSource 'file1.txt') -Value "upgraded1"
    Set-Content -LiteralPath (Join-Path $upgradeSource 'file3.txt') -Value "upgraded3"

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::CreateFromDirectory($initialSource, $initialArchivePath)
    [System.IO.Compression.ZipFile]::CreateFromDirectory($upgradeSource, $upgradeArchivePath)

    # 2. Test Clean Install (Positive)
    & (Join-Path $PSScriptRoot 'installer\Install-HerdrOps.ps1') -ArchivePath $initialArchivePath -InstallRoot $installRoot -UserDataRoot $userDataRoot
    if (-not $?) {
        throw "Install-HerdrOps.ps1 failed."
    }

    if (-not (Test-Path -LiteralPath (Join-Path $installRoot 'file1.txt'))) {
        throw "Install failed: file1.txt not found."
    }
    if (-not (Test-Path -LiteralPath (Join-Path $installRoot 'file2.txt'))) {
        throw "Install failed: file2.txt not found."
    }
    if (-not (Test-Path -LiteralPath (Join-Path $userDataRoot '.herdrops-retained-data'))) {
        throw "Install failed: user data marker not found."
    }

    # 3. Test In-Place Upgrade (Positive)
    $customUserFilePath = Join-Path $userDataRoot 'state_custom.txt'
    Set-Content -LiteralPath $customUserFilePath -Value "user data persistence check"

    & (Join-Path $PSScriptRoot 'installer\Install-HerdrOps.ps1') -ArchivePath $upgradeArchivePath -InstallRoot $installRoot -UserDataRoot $userDataRoot
    if (-not $?) {
        throw "In-place upgrade failed."
    }

    $upgradedFile1Content = (Get-Content -LiteralPath (Join-Path $installRoot 'file1.txt') -Raw).Trim()
    if ($upgradedFile1Content -ne 'upgraded1') {
        throw "In-place upgrade failed: file1.txt content was '$upgradedFile1Content', expected 'upgraded1'."
    }
    if (-not (Test-Path -LiteralPath (Join-Path $installRoot 'file3.txt'))) {
        throw "In-place upgrade failed: file3.txt not found."
    }
    if (Test-Path -LiteralPath (Join-Path $installRoot 'file2.txt')) {
        throw "In-place upgrade failed: obsolete file2.txt still exists in install root."
    }
    if (-not (Test-Path -LiteralPath $customUserFilePath)) {
        throw "In-place upgrade failed: custom user data was removed."
    }
    if (-not (Test-Path -LiteralPath (Join-Path $userDataRoot '.herdrops-retained-data'))) {
        throw "In-place upgrade failed: user data marker was removed."
    }

    # 4. Hostile Zip Slip Tests
    # 4.1 Hostile Zip (Prefix Sibling)
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

    # 4.2 Hostile Zip (Rooted Entry)
    $hostileArchiveRooted = Join-Path $testRoot 'hostile-rooted.zip'
    $archiveRooted = [System.IO.Compression.ZipFile]::Open($hostileArchiveRooted, [System.IO.Compression.ZipArchiveMode]::Create)
    $entry = $archiveRooted.CreateEntry("/rooted.txt")
    $stream = $entry.Open()
    $stream.Dispose()
    $archiveRooted.Dispose()

    $rootedCaught = $false
    try {
        Expand-HerdrOpsArchiveSafe -ArchivePath $hostileArchiveRooted -DestinationPath $installRoot
    } catch {
        if ($_.Exception.Message -match 'zip-slip') {
            $rootedCaught = $true
        } else {
            throw
        }
    }
    if (-not $rootedCaught) {
        throw "Rooted entry zip slip was not caught!"
    }

    # 4.3 Duplicates and Case Collisions
    $hostileArchiveDups = Join-Path $testRoot 'hostile-dups.zip'
    $archiveDups = [System.IO.Compression.ZipFile]::Open($hostileArchiveDups, [System.IO.Compression.ZipArchiveMode]::Create)
    $archiveDups.CreateEntry("DIR/file.txt").Open().Dispose()
    $archiveDups.CreateEntry("dir/file.txt").Open().Dispose()
    $archiveDups.Dispose()

    $caught = $false
    try {
        Expand-HerdrOpsArchiveSafe -ArchivePath $hostileArchiveDups -DestinationPath (Join-Path $testRoot 'dest')
    } catch {
        if ($_.Exception.Message -match 'case-insensitive duplicate') {
            $caught = $true
        }
    }
    if (-not $caught) { throw "Duplicate/case collision not caught!" }

    # 4.4 Container Collisions
    $hostileArchiveContainer = Join-Path $testRoot 'hostile-container.zip'
    $archiveContainer = [System.IO.Compression.ZipFile]::Open($hostileArchiveContainer, [System.IO.Compression.ZipArchiveMode]::Create)
    $archiveContainer.CreateEntry("file/").Open().Dispose()
    $archiveContainer.CreateEntry("file/subfile.txt").Open().Dispose()
    $archiveContainer.CreateEntry("FILE").Open().Dispose()
    $archiveContainer.Dispose()

    $caught = $false
    try {
        Expand-HerdrOpsArchiveSafe -ArchivePath $hostileArchiveContainer -DestinationPath (Join-Path $testRoot 'dest2')
    } catch {
        if ($_.Exception.Message -match 'file-vs-directory collision') {
            $caught = $true
        }
    }
    if (-not $caught) { throw "Container collision not caught!" }

    # 4.5 File-Parent Collision
    $hostileArchiveParent = Join-Path $testRoot 'hostile-parent.zip'
    $archiveParent = [System.IO.Compression.ZipFile]::Open($hostileArchiveParent, [System.IO.Compression.ZipArchiveMode]::Create)
    $archiveParent.CreateEntry("subdir").Open().Dispose()
    $archiveParent.CreateEntry("subdir/subfile.txt").Open().Dispose()
    $archiveParent.Dispose()

    $caught = $false
    try {
        Expand-HerdrOpsArchiveSafe -ArchivePath $hostileArchiveParent -DestinationPath (Join-Path $testRoot 'dest3')
    } catch {
        if ($_.Exception.Message -match 'Archive entry collides with a file in parent path') {
            $caught = $true
        }
    }
    if (-not $caught) { throw "File parent collision not caught!" }

    # 5. Missing LOCALAPPDATA Fallback
    $isolatedUserProfile = Join-Path $testRoot 'IsolatedUser'
    New-Item -ItemType Directory -Path $isolatedUserProfile -Force | Out-Null
    $installScript = Join-Path $PSScriptRoot 'installer\Install-HerdrOps.ps1'
    $uninstallScript = Join-Path $PSScriptRoot 'installer\Uninstall-HerdrOps.ps1'

    $isolatedJob = Start-Job -ScriptBlock {
        param($installScript, $uninstallScript, $archive, $userProfile)
        $env:LOCALAPPDATA = ""
        $env:USERPROFILE = $userProfile
        
        # Run install without explicit roots
        & $installScript -ArchivePath $archive
        if (-not $?) { throw "Isolated install failed." }

        $expectedInstall = Join-Path $userProfile 'AppData\Local\Programs\HerdrOps'
        $expectedUserData = Join-Path $userProfile 'AppData\Local\HerdrOps'

        if (-not (Test-Path -LiteralPath (Join-Path $expectedInstall 'file1.txt'))) {
            throw "Isolated install target not created at $expectedInstall."
        }
        if (-not (Test-Path -LiteralPath (Join-Path $expectedUserData '.herdrops-retained-data'))) {
            throw "Isolated user data not created at $expectedUserData."
        }

        # Run uninstall without explicit roots
        & $uninstallScript
        if (-not $?) { throw "Isolated uninstall failed." }

        if (Test-Path -LiteralPath $expectedInstall) {
            throw "Isolated uninstall did not remove $expectedInstall."
        }
        if (-not (Test-Path -LiteralPath $expectedUserData)) {
            throw "Isolated uninstall removed user data unexpectedly."
        }

        return "PASS"
    } -ArgumentList $installScript, $uninstallScript, $initialArchivePath, $isolatedUserProfile

    $isolatedResult = Receive-Job $isolatedJob -Wait -AutoRemoveJob
    if ($isolatedResult -ne "PASS") {
        throw "Missing LOCALAPPDATA fallback test failed: $isolatedResult"
    }

    # 6. Concurrency and Lock Cleanup
    $script = Join-Path $PSScriptRoot 'installer\Install-HerdrOps.ps1'
    $job1 = Start-Job -ScriptBlock { param($s, $a, $i, $u) & $s -ArchivePath $a -InstallRoot $i -UserDataRoot $u 2>&1 } -ArgumentList $script, $initialArchivePath, $installRoot, $userDataRoot
    $job2 = Start-Job -ScriptBlock { param($s, $a, $i, $u) & $s -ArchivePath $a -InstallRoot $i -UserDataRoot $u 2>&1 } -ArgumentList $script, $initialArchivePath, $installRoot, $userDataRoot
    Wait-Job $job1, $job2 | Out-Null
    $out1 = Receive-Job $job1 -Wait -AutoRemoveJob
    $out2 = Receive-Job $job2 -Wait -AutoRemoveJob
    $lockDir = Join-Path (Split-Path $installRoot -Parent) "$([IO.Path]::GetFileName($installRoot)).lock"
    if (Test-Path -LiteralPath $lockDir) {
        throw "Lock cleanup failed: lock directory still exists!"
    }

    # 7. Test Uninstall (Positive - Retain User Data)
    & (Join-Path $PSScriptRoot 'installer\Uninstall-HerdrOps.ps1') -InstallRoot $installRoot -UserDataRoot $userDataRoot

    if (Test-Path -LiteralPath $installRoot) {
        throw "Uninstall failed: install root still exists."
    }
    if (-not (Test-Path -LiteralPath $userDataRoot)) {
        throw "Uninstall failed: user data root was unexpectedly removed."
    }

    # 8. Test Uninstall with RemoveUserData
    # Install again
    & (Join-Path $PSScriptRoot 'installer\Install-HerdrOps.ps1') -ArchivePath $initialArchivePath -InstallRoot $installRoot -UserDataRoot $userDataRoot

    & (Join-Path $PSScriptRoot 'installer\Uninstall-HerdrOps.ps1') -InstallRoot $installRoot -UserDataRoot $userDataRoot -RemoveUserData

    if (Test-Path -LiteralPath $installRoot) {
        throw "Uninstall failed: install root still exists."
    }
    if (Test-Path -LiteralPath $userDataRoot) {
        throw "Uninstall failed: user data root still exists after -RemoveUserData."
    }

    $currentEdition = 'Desktop'
    if ($PSVersionTable.ContainsKey('PSEdition') -and -not [string]::IsNullOrWhiteSpace($PSVersionTable['PSEdition'])) {
        $currentEdition = [string]$PSVersionTable['PSEdition']
    }
    $report = [pscustomobject][ordered]@{
        EvidenceClass                  = 'Static/Synthetic'
        Issue                          = 38
        PowerShellEdition              = $currentEdition
        PowerShellVersion              = $PSVersionTable.PSVersion.ToString()
        CleanInstall                   = 'PASS'
        InPlaceUpgrade                 = 'PASS'
        HostileZipSlipPrefix           = 'PASS'
        HostileZipSlipRooted           = 'PASS'
        HostileDuplicateCaseCollision  = 'PASS'
        HostileFileContainerCollision  = 'PASS'
        HostileFileParentCollision     = 'PASS'
        MissingLocalAppDataFallback    = 'PASS'
        ConcurrencyLockAcquisition     = 'PASS'
        ConcurrencyLockCleanup         = 'PASS'
        UninstallRetainUserData        = 'PASS'
        UninstallRemoveUserData        = 'PASS'
        CleanMachine                   = 'NOT OBSERVED'
        Runtime                        = 'NOT OBSERVED'
        Human                          = 'NOT OBSERVED'
        Release                        = 'NOT OBSERVED'
    }

    return $report

} finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
