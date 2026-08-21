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

    # 4.6 Windows device-name entry
    $hostileArchiveDevice = Join-Path $testRoot 'hostile-device.zip'
    $archiveDevice = [System.IO.Compression.ZipFile]::Open($hostileArchiveDevice, [System.IO.Compression.ZipArchiveMode]::Create)
    $entry = $archiveDevice.CreateEntry('NUL')
    $entry.Open().Dispose()
    $archiveDevice.Dispose()

    $caught = $false
    $deviceDestination = Join-Path $testRoot 'device-dest'
    try {
        Expand-HerdrOpsArchiveSafe -ArchivePath $hostileArchiveDevice -DestinationPath $deviceDestination
    } catch {
        if ($_.Exception.Message -match 'device-name') {
            $caught = $true
        }
    }
    if (-not $caught) { throw 'Windows device-name archive entry was not caught!' }
    if (Test-Path -LiteralPath $deviceDestination) {
        throw 'Rejected device-name archive created a destination path.'
    }

    # 4.7 Archive entry-count and expanded-byte bounds
    $oldMaxEntries = $script:MaxInstallerArchiveEntries
    $script:MaxInstallerArchiveEntries = [long]1
    try {
        $hostileArchiveCount = Join-Path $testRoot 'hostile-count.zip'
        $archiveCount = [System.IO.Compression.ZipFile]::Open($hostileArchiveCount, [System.IO.Compression.ZipArchiveMode]::Create)
        $archiveCount.CreateEntry('one.txt').Open().Dispose()
        $archiveCount.CreateEntry('two.txt').Open().Dispose()
        $archiveCount.Dispose()
        $caught = $false
        $countDestination = Join-Path $testRoot 'count-dest'
        try {
            Expand-HerdrOpsArchiveSafe -ArchivePath $hostileArchiveCount -DestinationPath $countDestination
        } catch {
            if ($_.Exception.Message -match 'too many entries') {
                $caught = $true
            }
        }
        if (-not $caught) { throw 'Archive entry-count bound was not enforced!' }
        if (Test-Path -LiteralPath $countDestination) {
            throw 'Rejected entry-count archive created a destination path.'
        }
    } finally {
        $script:MaxInstallerArchiveEntries = $oldMaxEntries
    }

    $oldMaxBytes = $script:MaxInstallerArchiveExpandedBytes
    $script:MaxInstallerArchiveExpandedBytes = [long]4
    try {
        $hostileArchiveBytes = Join-Path $testRoot 'hostile-bytes.zip'
        $archiveBytes = [System.IO.Compression.ZipFile]::Open($hostileArchiveBytes, [System.IO.Compression.ZipArchiveMode]::Create)
        $entry = $archiveBytes.CreateEntry('oversized.txt')
        $writer = New-Object System.IO.StreamWriter($entry.Open())
        $writer.Write('12345')
        $writer.Dispose()
        $archiveBytes.Dispose()
        $caught = $false
        $bytesDestination = Join-Path $testRoot 'bytes-dest'
        try {
            Expand-HerdrOpsArchiveSafe -ArchivePath $hostileArchiveBytes -DestinationPath $bytesDestination
        } catch {
            if ($_.Exception.Message -match 'expanded bytes') {
                $caught = $true
            }
        }
        if (-not $caught) { throw 'Archive expanded-byte bound was not enforced!' }
        if (Test-Path -LiteralPath $bytesDestination) {
            throw 'Rejected expanded-byte archive created a destination path.'
        }
    } finally {
        $script:MaxInstallerArchiveExpandedBytes = $oldMaxBytes
    }

    # 4.8 Reparse destination guard
    $reparseTarget = Join-Path $testRoot 'reparse-target'
    $reparseLink = Join-Path $testRoot 'reparse-link'
    New-Item -ItemType Directory -Path $reparseTarget -Force | Out-Null
    New-Item -ItemType Junction -Path $reparseLink -Target $reparseTarget -Force | Out-Null
    try {
        $caught = $false
        try {
            Expand-HerdrOpsArchiveSafe -ArchivePath $initialArchivePath -DestinationPath (Join-Path $reparseLink 'payload')
        } catch {
            if ($_.Exception.Message -match 'Reparse points are not allowed') {
                $caught = $true
            }
        }
        if (-not $caught) { throw 'Reparse destination was not rejected before extraction.' }
    } finally {
        if (Test-Path -LiteralPath $reparseLink) {
            [IO.Directory]::Delete($reparseLink)
        }
        if (Test-Path -LiteralPath $reparseTarget) {
            Remove-Item -LiteralPath $reparseTarget -Recurse -Force
        }
    }

    # 4.9 Interrupted transition recovery
    $recoveryParent = Join-Path $testRoot 'recovery-parent'
    $recoveryInstall = Join-Path $recoveryParent 'Install'
    $recoveryStage = Join-Path $recoveryParent 'HerdrOps.stage-0123456789abcdef0123456789abcdef'
    $recoveryBackup = Join-Path $recoveryParent 'HerdrOps.backup-0123456789abcdef0123456789abcdef'
    New-Item -ItemType Directory -Path $recoveryStage,$recoveryBackup -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $recoveryStage 'partial.txt') -Value 'partial'
    Set-Content -LiteralPath (Join-Path $recoveryBackup 'old.txt') -Value 'old'
    Recover-HerdrOpsTransitionState -InstallRoot $recoveryInstall -Operation Install
    if (-not (Test-Path -LiteralPath (Join-Path $recoveryInstall 'old.txt')) -or
        (Test-Path -LiteralPath $recoveryStage) -or (Test-Path -LiteralPath $recoveryBackup)) {
        throw 'Interrupted install recovery did not restore the prior package atomically.'
    }

    $uninstallRecoveryParent = Join-Path $testRoot 'uninstall-recovery-parent'
    $uninstallRecoveryInstall = Join-Path $uninstallRecoveryParent 'Install'
    $uninstallRecoveryBackup = Join-Path $uninstallRecoveryParent 'HerdrOps.backup-0123456789abcdef0123456789abcdef'
    New-Item -ItemType Directory -Path $uninstallRecoveryBackup -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $uninstallRecoveryBackup 'old.txt') -Value 'old'
    Recover-HerdrOpsTransitionState -InstallRoot $uninstallRecoveryInstall -Operation Uninstall
    if (Test-Path -LiteralPath $uninstallRecoveryBackup) {
        throw 'Interrupted uninstall recovery did not retire the backup.'
    }

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
    $jobScript = {
        param($s, $a, $i, $u)
        & $s -ArchivePath $a -InstallRoot $i -UserDataRoot $u 2>&1
        if ($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0) {
            throw "Installer child exited with code $LASTEXITCODE."
        }
        'INSTALL_JOB_SUCCESS'
    }
    $job1 = Start-Job -ScriptBlock $jobScript -ArgumentList $script, $initialArchivePath, $installRoot, $userDataRoot
    $job2 = Start-Job -ScriptBlock $jobScript -ArgumentList $script, $initialArchivePath, $installRoot, $userDataRoot
    $jobs = @($job1, $job2)
    Wait-Job $jobs | Out-Null
    $job1State = [string]$job1.State
    $job2State = [string]$job2.State
    $out1 = Receive-Job $job1 -ErrorAction SilentlyContinue 2>&1 | Out-String
    $out2 = Receive-Job $job2 -ErrorAction SilentlyContinue 2>&1 | Out-String
    if ($job1State -cne 'Completed' -or $job2State -cne 'Completed') {
        throw "Concurrent installer jobs did not complete: job1=$job1State job2=$job2State"
    }
    if ($out1 -notmatch 'INSTALL_JOB_SUCCESS' -or
        $out2 -notmatch 'INSTALL_JOB_SUCCESS') {
        throw "Concurrent installer job output did not prove successful completion. job1=$out1 job2=$out2"
    }
    Remove-Job $jobs -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path -LiteralPath (Join-Path $installRoot 'file1.txt')) -or
        -not (Test-Path -LiteralPath (Join-Path $installRoot 'file2.txt'))) {
        throw 'Concurrent installer jobs did not leave a complete package.'
    }
    $transients = @(Get-ChildItem -LiteralPath (Split-Path $installRoot -Parent) -Directory -Force |
        Where-Object { $_.Name -match '^HerdrOps\.(stage|backup)-[0-9a-fA-F]{32}$' })
    if ($transients.Count -ne 0) {
        throw "Concurrent installer jobs left transient directories: $($transients.Name -join ', ')"
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
        HostileArchiveDeviceName       = 'PASS'
        HostileArchiveEntryCount       = 'PASS'
        HostileArchiveExpandedBytes    = 'PASS'
        ReparseDestinationGuard        = 'PASS'
        InterruptedInstallRecovery     = 'PASS'
        InterruptedUninstallRecovery   = 'PASS'
        MissingLocalAppDataFallback    = 'PASS'
        ConcurrencyLockAcquisition     = 'PASS'
        ConcurrencyLockCleanup         = 'PASS'
        ConcurrencyJobStateAndOutput   = 'PASS'
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
